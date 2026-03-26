defmodule SnowflexDev.Transport.PortTest do
  use ExUnit.Case, async: false

  alias SnowflexDev.Transport.Port, as: PortTransport
  alias SnowflexDev.Result
  alias SnowflexDev.Error

  @echo_worker Path.expand("../../support/echo_worker.py", __DIR__)

  defp start_transport(_context) do
    {:ok, pid} =
      PortTransport.start_link(
        python_path: System.find_executable("python3"),
        worker_path: @echo_worker,
        account: "test_account",
        user: "test_user"
      )

    %{pid: pid}
  end

  describe "execute/4" do
    setup [:start_transport]

    test "executes a simple query and returns Result struct", %{pid: pid} do
      assert {:ok, %Result{columns: ["1"], rows: [[1]], num_rows: 1}} =
               PortTransport.execute(pid, "SELECT 1")
    end

    test "handles chunked responses", %{pid: pid} do
      assert {:ok, %Result{columns: ["n"], rows: [[1], [2], [3]], num_rows: 3}} =
               PortTransport.execute(pid, "SELECT chunked")
    end

    test "returns error for failed queries", %{pid: pid} do
      assert {:error, %Error{message: "test error", code: "42000", sql_state: "42000"}} =
               PortTransport.execute(pid, "SELECT error")
    end
  end

  describe "ping/1" do
    setup [:start_transport]

    test "returns :ok", %{pid: pid} do
      assert :ok = PortTransport.ping(pid)
    end
  end

  describe "disconnect/1" do
    setup [:start_transport]

    test "stops the GenServer cleanly", %{pid: pid} do
      ref = Process.monitor(pid)
      assert :ok = PortTransport.disconnect(pid)

      # The GenServer should stop after disconnect since the Port closes
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  describe "Port crash handling" do
    test "GenServer stops when Port process exits" do
      {:ok, pid} =
        PortTransport.start_link(
          python_path: System.find_executable("python3"),
          worker_path: @echo_worker,
          account: "test_account",
          user: "test_user"
        )

      ref = Process.monitor(pid)

      # Unlink so the GenServer stopping doesn't kill the test
      Process.unlink(pid)

      # Kill the GenServer -- this will close the Port which triggers cleanup
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
      refute Process.alive?(pid)
    end
  end
end
