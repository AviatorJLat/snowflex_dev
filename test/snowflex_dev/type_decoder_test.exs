defmodule SnowflexDev.TypeDecoderTest do
  use ExUnit.Case, async: true

  alias SnowflexDev.TypeDecoder
  alias SnowflexDev.Result

  describe "decode_value/3 - nil handling" do
    test "nil value returns nil regardless of type_code" do
      assert TypeDecoder.decode_value(nil, 0, %{}) == nil
      assert TypeDecoder.decode_value(nil, 2, %{}) == nil
      assert TypeDecoder.decode_value(nil, 13, %{}) == nil
    end
  end

  describe "decode_value/3 - FIXED (type_code 0)" do
    test "decimal with scale > 0" do
      result = TypeDecoder.decode_value("123.45", 0, %{"scale" => 2})
      assert %Decimal{} = result
      assert Decimal.equal?(result, Decimal.new("123.45"))
    end

    test "integer with scale 0 (already integer)" do
      assert TypeDecoder.decode_value(42, 0, %{"scale" => 0}) == 42
    end

    test "integer with scale 0 (from string)" do
      assert TypeDecoder.decode_value("42", 0, %{"scale" => 0}) == 42
    end
  end

  describe "decode_value/3 - REAL (type_code 1)" do
    test "float value passes through" do
      assert TypeDecoder.decode_value(3.14, 1, %{}) == 3.14
    end

    test "float from string" do
      assert TypeDecoder.decode_value("3.14", 1, %{}) == 3.14
    end
  end

  describe "decode_value/3 - TEXT (type_code 2)" do
    test "string passes through" do
      assert TypeDecoder.decode_value("hello", 2, %{}) == "hello"
    end
  end

  describe "decode_value/3 - DATE (type_code 3)" do
    test "parses ISO date string" do
      assert TypeDecoder.decode_value("2024-01-15", 3, %{}) == ~D[2024-01-15]
    end
  end

  describe "decode_value/3 - TIMESTAMP_NTZ (type_code 8)" do
    test "parses naive datetime string" do
      assert TypeDecoder.decode_value("2024-01-15 10:30:00", 8, %{}) ==
               ~N[2024-01-15 10:30:00]
    end
  end

  describe "decode_value/3 - TIMESTAMP (type_code 4)" do
    test "parses naive datetime string" do
      assert TypeDecoder.decode_value("2024-01-15 10:30:00", 4, %{}) ==
               ~N[2024-01-15 10:30:00]
    end
  end

  describe "decode_value/3 - TIMESTAMP_LTZ (type_code 6)" do
    test "parses ISO8601 with timezone" do
      result = TypeDecoder.decode_value("2024-01-15T10:30:00Z", 6, %{})
      assert %DateTime{} = result
      assert result.year == 2024
      assert result.month == 1
      assert result.day == 15
      assert result.hour == 10
      assert result.minute == 30
    end

    test "fallback: datetime without timezone assumes UTC" do
      result = TypeDecoder.decode_value("2024-01-15 10:30:00", 6, %{})
      assert %DateTime{} = result
      assert result.time_zone == "Etc/UTC"
    end
  end

  describe "decode_value/3 - TIMESTAMP_TZ (type_code 7)" do
    test "parses ISO8601 with offset" do
      result = TypeDecoder.decode_value("2024-01-15T10:30:00+05:00", 7, %{})
      assert %DateTime{} = result
    end
  end

  describe "decode_value/3 - TIME (type_code 12)" do
    test "parses time string" do
      assert TypeDecoder.decode_value("10:30:00", 12, %{}) == ~T[10:30:00]
    end
  end

  describe "decode_value/3 - BOOLEAN (type_code 13)" do
    test "native true" do
      assert TypeDecoder.decode_value(true, 13, %{}) == true
    end

    test "string true" do
      assert TypeDecoder.decode_value("true", 13, %{}) == true
    end

    test "native false" do
      assert TypeDecoder.decode_value(false, 13, %{}) == false
    end

    test "string false" do
      assert TypeDecoder.decode_value("false", 13, %{}) == false
    end
  end

  describe "decode_value/3 - VARIANT/OBJECT/ARRAY (type_codes 5, 9, 10)" do
    test "variant map passes through" do
      assert TypeDecoder.decode_value(%{"key" => "val"}, 5, %{}) == %{"key" => "val"}
    end

    test "array passes through" do
      assert TypeDecoder.decode_value([1, 2], 10, %{}) == [1, 2]
    end

    test "object passes through" do
      assert TypeDecoder.decode_value(%{"a" => 1}, 9, %{}) == %{"a" => 1}
    end
  end

  describe "decode_value/3 - BINARY (type_code 11)" do
    test "decodes base64 string to binary" do
      encoded = Base.encode64("hello binary")
      assert TypeDecoder.decode_value(encoded, 11, %{}) == "hello binary"
    end
  end

  describe "decode_value/3 - fallback" do
    test "unknown type code returns value as-is" do
      assert TypeDecoder.decode_value("unknown", 99, %{}) == "unknown"
    end
  end

  describe "decode_result/2" do
    test "decodes a full Result with metadata" do
      result = %Result{
        columns: ["num", "name"],
        rows: [["42", "Alice"], ["7", "Bob"]],
        num_rows: 2,
        metadata: %{
          "num" => %{"type_code" => 0, "scale" => 0},
          "name" => %{"type_code" => 2}
        }
      }

      decoded = TypeDecoder.decode_result(result, result.metadata)

      assert decoded.rows == [[42, "Alice"], [7, "Bob"]]
      assert decoded.columns == ["num", "name"]
      assert decoded.num_rows == 2
    end

    test "handles empty rows" do
      result = %Result{
        columns: ["id"],
        rows: [],
        num_rows: 0,
        metadata: %{"id" => %{"type_code" => 0, "scale" => 0}}
      }

      decoded = TypeDecoder.decode_result(result, result.metadata)
      assert decoded.rows == []
    end

    test "handles nil rows" do
      result = %Result{
        columns: ["id"],
        rows: nil,
        num_rows: 0,
        metadata: %{"id" => %{"type_code" => 0, "scale" => 0}}
      }

      decoded = TypeDecoder.decode_result(result, result.metadata)
      assert decoded.rows == []
    end
  end
end
