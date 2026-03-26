defmodule Mix.Tasks.SnowflexDev.SetupTest do
  use ExUnit.Case, async: true

  describe "module metadata" do
    test "module is loadable and has @shortdoc" do
      assert Code.ensure_loaded?(Mix.Tasks.SnowflexDev.Setup)

      shortdoc = Mix.Task.shortdoc(Mix.Tasks.SnowflexDev.Setup)
      assert is_binary(shortdoc)
      assert shortdoc =~ "Python"
    end

    test "module uses Mix.Task" do
      assert function_exported?(Mix.Tasks.SnowflexDev.Setup, :run, 1)
    end
  end

  describe "error handling" do
    test "raises Mix.Error when python not found on PATH" do
      # Temporarily override PATH to ensure python can't be found
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        assert_raise Mix.Error, ~r/Python not found/, fn ->
          Mix.Tasks.SnowflexDev.Setup.run([])
        end
      after
        System.put_env("PATH", original_path)
      end
    end
  end
end
