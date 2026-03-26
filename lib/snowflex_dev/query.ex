defmodule SnowflexDev.Query do
  @moduledoc "Query struct for SnowflexDev. Implements DBConnection.Query protocol."

  defstruct [:statement, :columns, :column_types, name: "", cache: :reference]

  @type t :: %__MODULE__{
          statement: String.t() | nil,
          name: String.t(),
          cache: atom(),
          columns: [String.t()] | nil,
          column_types: map() | nil
        }

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query
    def describe(query, _opts), do: query
    def encode(_query, params, _opts), do: params
    def decode(_query, result, _opts), do: result
  end

  defimpl String.Chars do
    def to_string(%{statement: statement}), do: statement || ""
  end
end
