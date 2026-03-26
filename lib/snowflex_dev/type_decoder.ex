defmodule SnowflexDev.TypeDecoder do
  @moduledoc """
  Decodes Python JSON values into Elixir types using Snowflake type_code metadata.

  The Python worker sends raw values via `json.dumps(default=str)`, which converts
  Decimals and datetimes to strings. This module maps those string representations
  back to proper Elixir types using the type_code from `cursor.description`.
  """

  alias SnowflexDev.Result

  # Snowflake type codes from snowflake-connector-python constants.py
  @type_fixed 0
  @type_real 1
  @type_text 2
  @type_date 3
  @type_timestamp 4
  @type_variant 5
  @type_timestamp_ltz 6
  @type_timestamp_tz 7
  @type_timestamp_ntz 8
  @type_object 9
  @type_array 10
  @type_binary 11
  @type_time 12
  @type_boolean 13

  @doc "Decode a single value given its Snowflake type_code and column metadata."
  @spec decode_value(term(), non_neg_integer() | nil, map()) :: term()

  def decode_value(nil, _type_code, _meta), do: nil

  # FIXED: scale > 0 -> Decimal, scale 0 -> integer
  def decode_value(value, @type_fixed, %{"scale" => scale}) when is_integer(scale) and scale > 0 do
    Decimal.new(to_string(value))
  end

  def decode_value(value, @type_fixed, _meta) when is_integer(value), do: value
  def decode_value(value, @type_fixed, _meta), do: String.to_integer(to_string(value))

  # REAL -> float
  def decode_value(value, @type_real, _meta) when is_float(value), do: value
  def decode_value(value, @type_real, _meta), do: String.to_float(to_string(value))

  # TEXT -> string
  def decode_value(value, @type_text, _meta), do: to_string(value)

  # DATE -> Date
  def decode_value(value, @type_date, _meta) do
    value |> to_string() |> Date.from_iso8601!()
  end

  # TIMESTAMP and TIMESTAMP_NTZ -> NaiveDateTime
  def decode_value(value, type_code, _meta)
      when type_code in [@type_timestamp, @type_timestamp_ntz] do
    value |> to_string() |> NaiveDateTime.from_iso8601!()
  end

  # TIMESTAMP_LTZ and TIMESTAMP_TZ -> DateTime
  def decode_value(value, type_code, _meta)
      when type_code in [@type_timestamp_ltz, @type_timestamp_tz] do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _offset} ->
        dt

      {:error, _} ->
        # Fallback: if no timezone info, assume UTC
        value
        |> to_string()
        |> NaiveDateTime.from_iso8601!()
        |> DateTime.from_naive!("Etc/UTC")
    end
  end

  # TIME -> Time
  def decode_value(value, @type_time, _meta) do
    value |> to_string() |> Time.from_iso8601!()
  end

  # BOOLEAN
  def decode_value(true, @type_boolean, _meta), do: true
  def decode_value(false, @type_boolean, _meta), do: false
  def decode_value("true", @type_boolean, _meta), do: true
  def decode_value("false", @type_boolean, _meta), do: false

  # VARIANT, OBJECT, ARRAY -> pass through (already decoded from JSON)
  def decode_value(value, type_code, _meta)
      when type_code in [@type_variant, @type_object, @type_array] do
    value
  end

  # BINARY -> base64 decode
  def decode_value(value, @type_binary, _meta) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  # Fallback: return as-is for unknown type codes
  def decode_value(value, _type_code, _meta), do: value

  @doc """
  Decode all rows in a Result struct using column metadata for type conversion.

  Takes a Result and a metadata map (column_name -> %{"type_code" => int, ...}),
  returns the Result with decoded rows.
  """
  @spec decode_result(Result.t(), map()) :: Result.t()
  def decode_result(%Result{} = result, metadata) when is_map(metadata) do
    columns = result.columns || []
    column_metas = Enum.map(columns, fn col -> Map.get(metadata, col, %{}) end)

    decoded_rows =
      (result.rows || [])
      |> Enum.map(fn row ->
        row
        |> Enum.zip(column_metas)
        |> Enum.map(fn {value, meta} ->
          type_code = Map.get(meta, "type_code")
          decode_value(value, type_code, meta)
        end)
      end)

    %{result | rows: decoded_rows}
  end
end
