defmodule SnowflexDev.Result do
  @moduledoc "Query result struct. Shape matches Snowflex.Result for compatibility."
  defstruct [:columns, :rows, :num_rows, :metadata]

  @type t :: %__MODULE__{
          columns: [String.t()] | nil,
          rows: [[term()]] | nil,
          num_rows: non_neg_integer() | nil,
          metadata: map() | nil
        }
end
