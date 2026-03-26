defmodule SnowflexDev.ProtocolTest do
  use ExUnit.Case, async: true

  alias SnowflexDev.Protocol
  alias SnowflexDev.Result
  alias SnowflexDev.Error

  describe "encode_connect/2" do
    test "produces valid JSON with connect type and payload" do
      id = "abc123"

      opts = [
        account: "my_account",
        user: "my_user",
        warehouse: "my_wh",
        database: "my_db",
        schema: "my_schema",
        role: "my_role"
      ]

      json = Protocol.encode_connect(id, opts)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "abc123"
      assert decoded["type"] == "connect"
      assert decoded["payload"]["account"] == "my_account"
      assert decoded["payload"]["user"] == "my_user"
      assert decoded["payload"]["warehouse"] == "my_wh"
      assert decoded["payload"]["database"] == "my_db"
      assert decoded["payload"]["schema"] == "my_schema"
      assert decoded["payload"]["role"] == "my_role"
      assert decoded["payload"]["authenticator"] == "externalbrowser"
      assert decoded["payload"]["login_timeout"] == 300
    end

    test "uses custom authenticator and login_timeout when provided" do
      json = Protocol.encode_connect("id1", authenticator: "snowflake", login_timeout: 60)
      decoded = Jason.decode!(json)

      assert decoded["payload"]["authenticator"] == "snowflake"
      assert decoded["payload"]["login_timeout"] == 60
    end
  end

  describe "encode_execute/3" do
    test "produces valid JSON with execute type and payload" do
      json = Protocol.encode_execute("exec1", "SELECT * FROM users", ["param1"])
      decoded = Jason.decode!(json)

      assert decoded["id"] == "exec1"
      assert decoded["type"] == "execute"
      assert decoded["payload"]["sql"] == "SELECT * FROM users"
      assert decoded["payload"]["params"] == ["param1"]
    end

    test "defaults params to empty list when nil" do
      json = Protocol.encode_execute("exec2", "SELECT 1", nil)
      decoded = Jason.decode!(json)

      assert decoded["payload"]["params"] == []
    end
  end

  describe "encode_ping/1" do
    test "produces valid JSON with ping type and empty payload" do
      json = Protocol.encode_ping("ping1")
      decoded = Jason.decode!(json)

      assert decoded["id"] == "ping1"
      assert decoded["type"] == "ping"
      assert decoded["payload"] == %{}
    end
  end

  describe "encode_disconnect/1" do
    test "produces valid JSON with disconnect type and empty payload" do
      json = Protocol.encode_disconnect("disc1")
      decoded = Jason.decode!(json)

      assert decoded["id"] == "disc1"
      assert decoded["type"] == "disconnect"
      assert decoded["payload"] == %{}
    end
  end

  describe "decode_response/1" do
    test "decodes ok status" do
      data = Jason.encode!(%{"id" => "r1", "status" => "ok", "payload" => %{"message" => "connected"}})
      assert {:ok, "r1", %{"message" => "connected"}} = Protocol.decode_response(data)
    end

    test "decodes chunked ok status" do
      data =
        Jason.encode!(%{
          "id" => "r2",
          "status" => "ok",
          "chunked" => true,
          "payload" => %{"columns" => ["a", "b"], "total_rows" => 5000, "metadata" => %{}}
        })

      assert {:ok, "r2", :chunked_start, payload} = Protocol.decode_response(data)
      assert payload["columns"] == ["a", "b"]
      assert payload["total_rows"] == 5000
    end

    test "decodes chunk status" do
      data =
        Jason.encode!(%{
          "id" => "r3",
          "status" => "chunk",
          "payload" => %{"rows" => [[1, 2], [3, 4]], "chunk_index" => 0}
        })

      assert {:ok, "r3", :chunk, payload} = Protocol.decode_response(data)
      assert payload["rows"] == [[1, 2], [3, 4]]
    end

    test "decodes done status" do
      data =
        Jason.encode!(%{
          "id" => "r4",
          "status" => "done",
          "payload" => %{"chunks_sent" => 5}
        })

      assert {:ok, "r4", :chunk_done, payload} = Protocol.decode_response(data)
      assert payload["chunks_sent"] == 5
    end

    test "decodes error status" do
      data =
        Jason.encode!(%{
          "id" => "r5",
          "status" => "error",
          "payload" => %{"message" => "boom", "code" => "42000", "sql_state" => "HY000"}
        })

      assert {:error, "r5", payload} = Protocol.decode_response(data)
      assert payload["message"] == "boom"
      assert payload["code"] == "42000"
    end

    test "handles invalid JSON gracefully" do
      assert {:error, nil, %{"message" => msg}} = Protocol.decode_response("not json{{{")
      assert msg =~ "JSON decode failed"
    end
  end

  describe "generate_id/0" do
    test "returns a 16-char hex string" do
      id = Protocol.generate_id()
      assert is_binary(id)
      assert byte_size(id) == 16
      assert Regex.match?(~r/^[0-9a-f]{16}$/, id)
    end

    test "returns unique values" do
      ids = for _ <- 1..10, do: Protocol.generate_id()
      assert length(Enum.uniq(ids)) == 10
    end
  end

  describe "Result struct" do
    test "has expected fields with nil defaults" do
      result = %Result{}
      assert result.columns == nil
      assert result.rows == nil
      assert result.num_rows == nil
      assert result.metadata == nil
    end

    test "can be constructed with values" do
      result = %Result{columns: ["a"], rows: [[1]], num_rows: 1, metadata: %{}}
      assert result.columns == ["a"]
      assert result.num_rows == 1
    end
  end

  describe "Error struct" do
    test "is an exception with expected fields" do
      error = %Error{message: "test error", code: "123", sql_state: "HY000"}
      assert Exception.message(error) == "test error"
      assert error.code == "123"
      assert error.sql_state == "HY000"
    end

    test "has nil defaults for code and sql_state" do
      error = %Error{message: "simple"}
      assert error.code == nil
      assert error.sql_state == nil
    end
  end
end
