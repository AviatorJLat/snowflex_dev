defmodule SnowflexDev.QueryTest do
  use ExUnit.Case, async: true

  alias SnowflexDev.Query
  alias SnowflexDev.Result

  describe "Result struct" do
    test "has all 9 fields" do
      result = %Result{}

      assert Map.has_key?(result, :columns)
      assert Map.has_key?(result, :rows)
      assert Map.has_key?(result, :num_rows)
      assert Map.has_key?(result, :metadata)
      assert Map.has_key?(result, :messages)
      assert Map.has_key?(result, :query)
      assert Map.has_key?(result, :query_id)
      assert Map.has_key?(result, :request_id)
      assert Map.has_key?(result, :sql_state)
    end

    test "defaults: num_rows is 0, metadata is [], messages is [], others are nil" do
      result = %Result{}

      assert result.num_rows == 0
      assert result.metadata == []
      assert result.messages == []
      assert result.columns == nil
      assert result.rows == nil
      assert result.query == nil
      assert result.query_id == nil
      assert result.request_id == nil
      assert result.sql_state == nil
    end
  end

  describe "Query struct" do
    test "has expected fields with defaults" do
      query = %Query{}

      assert query.statement == nil
      assert query.name == ""
      assert query.cache == :reference
      assert query.columns == nil
      assert query.column_types == nil
    end
  end

  describe "DBConnection.Query protocol" do
    test "parse/2 returns query unchanged" do
      query = %Query{statement: "SELECT 1"}
      assert DBConnection.Query.parse(query, []) == query
    end

    test "describe/2 returns query unchanged" do
      query = %Query{statement: "SELECT 1"}
      assert DBConnection.Query.describe(query, []) == query
    end

    test "encode/3 returns params unchanged" do
      query = %Query{statement: "SELECT ?"}
      params = [1, "hello"]
      assert DBConnection.Query.encode(query, params, []) == params
    end

    test "decode/3 returns result as-is" do
      query = %Query{statement: "SELECT 1"}
      result = %Result{columns: ["1"], rows: [[1]], num_rows: 1}
      assert DBConnection.Query.decode(query, result, []) == result
    end
  end

  describe "String.Chars protocol" do
    test "to_string returns statement" do
      query = %Query{statement: "SELECT 1"}
      assert to_string(query) == "SELECT 1"
    end

    test "to_string returns empty string when statement is nil" do
      query = %Query{}
      assert to_string(query) == ""
    end
  end
end
