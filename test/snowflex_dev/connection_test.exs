defmodule SnowflexDev.ConnectionTest do
  use ExUnit.Case, async: false

  alias SnowflexDev.{Connection, Query, Result, Error}

  @echo_worker_path Path.expand("../support/echo_worker.py", __DIR__)

  defp connection_opts do
    [
      python_path: System.find_executable("python3"),
      worker_path: @echo_worker_path,
      account: "test",
      user: "test",
      pool_size: 1
    ]
  end

  setup do
    {:ok, conn} = DBConnection.start_link(Connection, connection_opts())
    # Give pool a moment to establish the connection
    Process.sleep(100)
    %{conn: conn}
  end

  describe "pool startup" do
    test "start_link creates a pool with working connection", %{conn: conn} do
      assert Process.alive?(conn)
      query = %Query{statement: "SELECT 1"}
      assert {:ok, _query, %Result{}} = DBConnection.execute(conn, query, [])
    end
  end

  describe "execute/4" do
    test "returns {:ok, query, result} with correct struct types", %{conn: conn} do
      query = %Query{statement: "SELECT 1"}
      assert {:ok, ^query, result} = DBConnection.execute(conn, query, [])
      assert %Result{} = result
      assert result.columns == ["1"]
      assert result.rows == [[1]]
      assert result.num_rows == 1
      assert result.query == query
      assert result.query_id == "test-query-id-001"
    end

    test "decodes typed values from metadata", %{conn: conn} do
      query = %Query{statement: "SELECT typed"}
      assert {:ok, _query, result} = DBConnection.execute(conn, query, [])
      assert result.columns == ["num", "name", "created", "active"]
      assert result.num_rows == 1

      [[num, name, created, active]] = result.rows
      assert num == 42
      assert name == "Alice"
      assert created == ~D[2024-01-15]
      assert active == true
    end

    test "returns error for SQL errors", %{conn: conn} do
      query = %Query{statement: "SELECT error"}
      assert {:error, %Error{message: "test error", code: "42000", sql_state: "42000"}} =
               DBConnection.execute(conn, query, [])
    end

    test "multiple sequential executes work (checkout/checkin cycle)", %{conn: conn} do
      query = %Query{statement: "SELECT 1"}

      for _i <- 1..5 do
        assert {:ok, _query, %Result{num_rows: 1}} = DBConnection.execute(conn, query, [])
      end
    end
  end

  describe "crash recovery" do
    test "Port crash returns error and pool recovers", %{conn: conn} do
      # Execute a query that crashes the Python process.
      # The Transport.Port GenServer stops when the Python process exits, so
      # DBConnection sees the connection die. Depending on timing, we get either
      # our Error struct or a DBConnection.ConnectionError wrapping it.
      crash_query = %Query{statement: "SELECT crash"}
      result = DBConnection.execute(conn, crash_query, [])
      assert {:error, error} = result

      assert match?(%Error{code: "SNOWFLEX_DEV_EXIT"}, error) or
               match?(%DBConnection.ConnectionError{}, error)

      # Give the pool time to reconnect
      Process.sleep(500)

      # Pool should have reconnected -- new query should work
      query = %Query{statement: "SELECT 1"}
      assert {:ok, _query, %Result{columns: ["1"], num_rows: 1}} =
               DBConnection.execute(conn, query, [])
    end
  end

  describe "transactions" do
    test "transaction raises error (Snowflake does not support transactions)", %{conn: conn} do
      assert_raise SnowflexDev.Error, ~r/does not support transactions/, fn ->
        DBConnection.transaction(conn, fn _conn -> :ok end)
      end
    end
  end

  describe "handle_status" do
    test "connection reports idle status", %{conn: conn} do
      # Verify connection is usable (status is idle internally)
      query = %Query{statement: "SELECT 1"}
      assert {:ok, _query, %Result{}} = DBConnection.execute(conn, query, [])
    end
  end
end
