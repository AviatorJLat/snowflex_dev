defmodule SnowflexDev.Transport.Port do
  @moduledoc """
  GenServer wrapping an Erlang Port to the Python worker process.

  Bridges asynchronous Port messages with synchronous GenServer.call semantics.
  Manages the full Port lifecycle: open, connect (with SSO timeout), execute,
  ping, chunked response reassembly, crash handling, and clean disconnect.
  """

  use GenServer
  @behaviour SnowflexDev.Transport

  require Logger

  alias SnowflexDev.Protocol
  alias SnowflexDev.Result
  alias SnowflexDev.Error

  defmodule State do
    @moduledoc false
    defstruct [
      :port,
      :python_path,
      :worker_path,
      :opts,
      connected: false,
      pending_request: nil
    ]
  end

  # --- Public API ---

  @impl SnowflexDev.Transport
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl SnowflexDev.Transport
  def execute(pid, sql, params \\ [], opts \\ []) do
    GenServer.call(pid, {:execute, sql, params, opts}, query_timeout(opts))
  end

  @impl SnowflexDev.Transport
  def ping(pid) do
    case GenServer.call(pid, :ping, 10_000) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl SnowflexDev.Transport
  def disconnect(pid) do
    GenServer.call(pid, :disconnect, 5_000)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    python_path =
      Keyword.get(opts, :python_path, Path.join([File.cwd!(), "_snowflex_dev", "venv", "bin", "python3"]))

    worker_path =
      Keyword.get(opts, :worker_path, Application.app_dir(:snowflex_dev, "priv/python/snowflex_dev_worker.py"))

    port =
      Port.open({:spawn_executable, String.to_charlist(python_path)}, [
        :binary,
        {:packet, 4},
        :exit_status,
        :use_stdio,
        args: ["-u", worker_path]
      ])

    id = Protocol.generate_id()
    data = Protocol.encode_connect(id, opts)
    Port.command(port, data)

    login_timeout = Keyword.get(opts, :login_timeout, 300_000)

    receive do
      {^port, {:data, response_data}} ->
        case Protocol.decode_response(response_data) do
          {:ok, ^id, _payload} ->
            {:ok, %State{port: port, python_path: python_path, worker_path: worker_path, opts: opts, connected: true}}

          {:error, _, payload} ->
            Port.close(port)
            {:stop, {:connect_failed, payload["message"]}}

          _other ->
            Port.close(port)
            {:stop, {:connect_failed, "unexpected response"}}
        end

      {^port, {:exit_status, code}} ->
        {:stop, {:python_exit, code}}
    after
      login_timeout ->
        Port.close(port)
        {:stop, :connect_timeout}
    end
  end

  @impl GenServer
  def handle_call({:execute, sql, params, _opts}, from, %State{} = state) do
    id = Protocol.generate_id()
    data = Protocol.encode_execute(id, sql, params)
    Port.command(state.port, data)
    {:noreply, %{state | pending_request: {id, from}}}
  end

  @impl GenServer
  def handle_call(:ping, from, %State{} = state) do
    id = Protocol.generate_id()
    data = Protocol.encode_ping(id)
    Port.command(state.port, data)
    {:noreply, %{state | pending_request: {id, from}}}
  end

  @impl GenServer
  def handle_call(:disconnect, from, %State{} = state) do
    id = Protocol.generate_id()
    data = Protocol.encode_disconnect(id)
    Port.command(state.port, data)
    {:noreply, %{state | pending_request: {id, from, :disconnect}}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %State{port: port, pending_request: pending} = state) do
    case {Protocol.decode_response(data), pending} do
      # Chunked start -- begin accumulating
      {{:ok, id, :chunked_start, payload}, {id, from}} ->
        acc = %{
          columns: payload["columns"],
          rows: [],
          total_rows: payload["total_rows"],
          metadata: payload["metadata"]
        }

        {:noreply, %{state | pending_request: {id, from, :chunking, acc}}}

      # Chunk data -- append rows
      {{:ok, id, :chunk, payload}, {id, from, :chunking, acc}} ->
        updated_acc = %{acc | rows: acc.rows ++ payload["rows"]}
        {:noreply, %{state | pending_request: {id, from, :chunking, updated_acc}}}

      # Chunk done -- build result and reply
      {{:ok, id, :chunk_done, _payload}, {id, from, :chunking, acc}} ->
        result = %Result{
          columns: acc.columns,
          rows: acc.rows,
          num_rows: acc.total_rows,
          metadata: acc.metadata
        }

        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_request: nil}}

      # Disconnect success -- reply :ok and stop
      {{:ok, id, _payload}, {id, from, :disconnect}} ->
        GenServer.reply(from, :ok)
        {:stop, :normal, %{state | pending_request: nil, connected: false}}

      # Non-chunked success (execute/ping result)
      {{:ok, id, payload}, {id, from}} when is_map(payload) ->
        result = %Result{
          columns: payload["columns"],
          rows: payload["rows"],
          num_rows: payload["num_rows"],
          metadata: payload["metadata"]
        }

        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_request: nil}}

      # Error response
      {{:error, id, payload}, {id, from}} ->
        error = %Error{
          message: payload["message"],
          code: payload["code"],
          sql_state: payload["sql_state"]
        }

        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_request: nil}}

      # Error response for disconnect
      {{:error, id, payload}, {id, from, :disconnect}} ->
        error = %Error{
          message: payload["message"],
          code: payload["code"],
          sql_state: payload["sql_state"]
        }

        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_request: nil}}

      # Error response during chunking
      {{:error, id, payload}, {id, from, :chunking, _acc}} ->
        error = %Error{
          message: payload["message"],
          code: payload["code"],
          sql_state: payload["sql_state"]
        }

        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_request: nil}}

      # Mismatched ID -- discard
      {_decoded, _pending} ->
        Logger.warning("Transport.Port received response with unexpected ID, discarding")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, code}}, %State{port: port, pending_request: pending} = state) do
    case pending do
      {_id, from} ->
        error = %Error{message: "Python process exited with code #{code}", code: "SNOWFLEX_DEV_EXIT"}
        GenServer.reply(from, {:error, error})

      {_id, from, :disconnect} ->
        # Port exited after disconnect -- this is expected
        GenServer.reply(from, :ok)

      {_id, from, :chunking, _acc} ->
        error = %Error{message: "Python process exited with code #{code}", code: "SNOWFLEX_DEV_EXIT"}
        GenServer.reply(from, {:error, error})

      nil ->
        :ok
    end

    {:stop, {:python_exit, code}, %{state | port: nil, pending_request: nil}}
  end

  # Handle unexpected messages
  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("Transport.Port received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %State{port: port, connected: connected}) when is_port(port) do
    try do
      if connected do
        id = Protocol.generate_id()
        data = Protocol.encode_disconnect(id)
        Port.command(port, data)
      end

      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private Helpers ---

  defp query_timeout(opts) do
    Keyword.get(opts, :timeout, 60_000)
  end
end
