defmodule SnowflexDev.Error do
  @moduledoc "Error struct for protocol and Snowflake errors."
  defexception [:message, :code, :sql_state]

  @type t :: %__MODULE__{
          message: String.t(),
          code: String.t() | nil,
          sql_state: String.t() | nil
        }
end
