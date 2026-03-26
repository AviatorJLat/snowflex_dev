defmodule SnowflexDev.Result do
  @moduledoc "Query result struct. Shape matches Snowflex.Result for compatibility."

  defstruct [
    :columns,
    :rows,
    :query,
    :query_id,
    :request_id,
    :sql_state,
    num_rows: 0,
    metadata: [],
    messages: []
  ]

  @type t :: %__MODULE__{
          columns: [String.t()] | nil,
          rows: [[term()]] | nil,
          num_rows: non_neg_integer(),
          metadata: [map()] | map(),
          messages: [map()],
          query: struct() | nil,
          query_id: String.t() | nil,
          request_id: String.t() | nil,
          sql_state: String.t() | nil
        }
end
