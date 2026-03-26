defmodule SnowflexDev.Protocol do
  @moduledoc "Encodes commands and decodes responses for the Port JSON protocol."

  @doc "Generate a unique request ID (16 hex chars)."
  @spec generate_id() :: String.t()
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @doc "Encode a connect command with connection options."
  @spec encode_connect(String.t(), keyword()) :: binary()
  def encode_connect(id, opts) do
    Jason.encode!(%{
      id: id,
      type: "connect",
      payload: %{
        account: opts[:account],
        user: opts[:user],
        warehouse: opts[:warehouse],
        database: opts[:database],
        schema: opts[:schema],
        role: opts[:role],
        authenticator: opts[:authenticator] || "externalbrowser",
        login_timeout: opts[:login_timeout] || 300
      }
    })
  end

  @doc "Encode an execute command with SQL and params."
  @spec encode_execute(String.t(), String.t(), list() | nil) :: binary()
  def encode_execute(id, sql, params) do
    Jason.encode!(%{
      id: id,
      type: "execute",
      payload: %{sql: sql, params: params || []}
    })
  end

  @doc "Encode a ping command."
  @spec encode_ping(String.t()) :: binary()
  def encode_ping(id) do
    Jason.encode!(%{id: id, type: "ping", payload: %{}})
  end

  @doc "Encode a disconnect command."
  @spec encode_disconnect(String.t()) :: binary()
  def encode_disconnect(id) do
    Jason.encode!(%{id: id, type: "disconnect", payload: %{}})
  end

  @doc "Decode a JSON response from the Python worker into tagged tuples."
  @spec decode_response(binary()) ::
          {:ok, String.t(), map()}
          | {:ok, String.t(), :chunked_start, map()}
          | {:ok, String.t(), :chunk, map()}
          | {:ok, String.t(), :chunk_done, map()}
          | {:error, String.t() | nil, map()}
  def decode_response(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"id" => id, "status" => "ok", "chunked" => true} = resp} ->
        {:ok, id, :chunked_start, resp["payload"]}

      {:ok, %{"id" => id, "status" => "ok"} = resp} ->
        {:ok, id, resp["payload"]}

      {:ok, %{"id" => id, "status" => "chunk"} = resp} ->
        {:ok, id, :chunk, resp["payload"]}

      {:ok, %{"id" => id, "status" => "done"} = resp} ->
        {:ok, id, :chunk_done, resp["payload"]}

      {:ok, %{"id" => id, "status" => "error"} = resp} ->
        {:error, id, resp["payload"]}

      {:error, reason} ->
        {:error, nil, %{"message" => "JSON decode failed: #{inspect(reason)}"}}
    end
  end
end
