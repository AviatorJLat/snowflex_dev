defmodule SnowflexDev.Connection do
  @moduledoc """
  DBConnection behaviour implementation for SnowflexDev.

  Each pool slot owns one Transport.Port process (1:1 mapping per D-07).
  Checkout/checkin are no-ops since the Transport.Port is always ready (per D-08).
  Crash recovery is handled by DBConnection's pool -- returning {:disconnect, error, state}
  tells the pool to call disconnect/2 then connect/2 for a fresh slot (per D-05).
  """

  @behaviour DBConnection

  alias SnowflexDev.{Error, Query, Result, Transport, TypeDecoder}

  defstruct [:transport_pid, :opts]

  @type t :: %__MODULE__{
          transport_pid: pid() | nil,
          opts: keyword()
        }

  # --- DBConnection Callbacks ---

  @impl DBConnection
  def connect(opts) do
    case Transport.Port.start_link(opts) do
      {:ok, pid} ->
        {:ok, %__MODULE__{transport_pid: pid, opts: opts}}

      {:error, reason} ->
        {:error,
         %Error{
           message: "Failed to connect: #{inspect(reason)}",
           code: "SNOWFLEX_DEV_CONNECT"
         }}
    end
  end

  @impl DBConnection
  def disconnect(_error, %__MODULE__{transport_pid: pid}) do
    Transport.Port.disconnect(pid)
    :ok
  end

  @impl DBConnection
  def checkout(state), do: {:ok, state}

  @impl DBConnection
  def ping(%__MODULE__{transport_pid: pid} = state) do
    case Transport.Port.ping(pid) do
      :ok -> {:ok, state}
      {:error, %Error{code: "SNOWFLEX_DEV_EXIT"} = error} -> {:disconnect, error, state}
      {:error, error} -> {:disconnect, error, state}
    end
  end

  @impl DBConnection
  def handle_prepare(%Query{} = query, _opts, state) do
    # No preparation step -- Snowflake doesn't support prepared statements via our transport
    {:ok, query, state}
  end

  @impl DBConnection
  def handle_execute(%Query{} = query, params, _opts, %__MODULE__{transport_pid: pid} = state) do
    case Transport.Port.execute(pid, query.statement, params) do
      {:ok, %Result{} = raw_result} ->
        # Extract metadata for type decoding.
        # IMPORTANT: Result.metadata defaults to [] (empty list), which is truthy in Elixir.
        # TypeDecoder.decode_result/2 guards on `when is_map(metadata)`, so we must
        # normalize non-map metadata (e.g., [] from DDL statements) to %{} to avoid
        # FunctionClauseError. Using pattern match because `[] || %{}` evaluates to `[]`.
        metadata =
          case raw_result.metadata do
            m when is_map(m) -> m
            _ -> %{}
          end

        decoded = TypeDecoder.decode_result(raw_result, metadata)

        # Enrich result with query reference
        # query_id already comes from the transport layer
        result = %{decoded | query: query}

        {:ok, query, result, state}

      {:error, %Error{code: "SNOWFLEX_DEV_EXIT"} = error} ->
        # Port crash -- tell DBConnection the connection is dead (per D-06)
        {:disconnect, error, state}

      {:error, error} ->
        # SQL error -- connection still alive
        {:error, error, state}
    end
  end

  @impl DBConnection
  def handle_close(_query, _opts, state) do
    {:ok, nil, state}
  end

  @impl DBConnection
  def handle_status(_opts, state), do: {:idle, state}

  # Transaction callbacks -- Snowflake does not support transactions
  @impl DBConnection
  def handle_begin(_opts, state) do
    {:disconnect, %Error{message: "SnowflexDev does not support transactions"}, state}
  end

  @impl DBConnection
  def handle_commit(_opts, state) do
    {:disconnect, %Error{message: "SnowflexDev does not support transactions"}, state}
  end

  @impl DBConnection
  def handle_rollback(_opts, state) do
    {:disconnect, %Error{message: "SnowflexDev does not support transactions"}, state}
  end

  @impl DBConnection
  def handle_declare(_query, _params, _opts, state) do
    {:error, %Error{message: "SnowflexDev does not support cursors"}, state}
  end

  @impl DBConnection
  def handle_fetch(_query, _cursor, _opts, state) do
    {:halt, %Result{}, state}
  end

  @impl DBConnection
  def handle_deallocate(_query, _cursor, _opts, state) do
    {:ok, nil, state}
  end
end
