defmodule SnowflexDev.Ecto.Adapter.Stream do
  @moduledoc "Streaming query result wrapper for Ecto."

  defstruct [:meta, :statement, :params, :opts]

  @type t :: %__MODULE__{
          meta: map(),
          statement: String.t(),
          params: [term()],
          opts: keyword()
        }

  def build(meta, statement, params, opts) do
    %__MODULE__{meta: meta, statement: statement, params: params, opts: opts}
  end
end

defimpl Enumerable, for: SnowflexDev.Ecto.Adapter.Stream do
  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}

  def reduce(stream, acc, fun) do
    %{meta: %{pid: pool}, statement: statement, params: params, opts: opts} = stream
    opts = Keyword.put(opts, :max_rows, opts[:max_rows] || 500)
    query = %SnowflexDev.Query{statement: statement}

    # Use DBConnection.run to check out a connection, then execute within it.
    # This mirrors Snowflex's streaming pattern without requiring transactions
    # (which Snowflake does not support).
    DBConnection.run(
      pool,
      fn conn ->
        case DBConnection.execute(conn, query, params, opts) do
          {:ok, _query, %{rows: rows}} when is_list(rows) ->
            Enum.reduce(rows, acc, fn row, acc ->
              case acc do
                {:cont, inner_acc} -> fun.(row, {:cont, inner_acc})
                {:halt, _} = halted -> halted
                {:suspend, _} = suspended -> suspended
              end
            end)

          {:ok, _query, _result} ->
            acc

          {:error, err} ->
            raise err
        end
      end,
      opts
    )
  end
end

defimpl Collectable, for: SnowflexDev.Ecto.Adapter.Stream do
  def into(stream) do
    fun = fn
      acc, {:cont, value} -> [value | acc]
      acc, :done -> {stream, Enum.reverse(acc)}
      _acc, :halt -> :ok
    end

    {[], fun}
  end
end
