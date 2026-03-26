defmodule SnowflexDev.HealthCheckTest do
  use ExUnit.Case, async: true

  alias SnowflexDev.HealthCheck
  alias SnowflexDev.Error

  describe "validate/1" do
    test "returns error with PYTHON_NOT_FOUND when python_path does not exist" do
      opts = [python_path: "/nonexistent/path/to/python3"]

      assert {:error, %Error{code: "SNOWFLEX_DEV_PYTHON_NOT_FOUND"} = error} =
               HealthCheck.validate(opts)

      assert error.message =~ "Python not found"
      assert error.message =~ "mix snowflex_dev.setup"
    end

    test "error message contains actionable fix instructions" do
      opts = [python_path: "/nonexistent/path/to/python3"]

      {:error, %Error{} = error} = HealthCheck.validate(opts)

      assert error.message =~ "mix snowflex_dev.setup"
      assert error.message =~ ":python_path"
    end

    test "returns error with CONNECTOR_MISSING when python exists but connector not importable" do
      python = System.find_executable("python3") || System.find_executable("python")

      if python do
        opts = [python_path: python]

        assert {:error, %Error{code: "SNOWFLEX_DEV_CONNECTOR_MISSING"} = error} =
                 HealthCheck.validate(opts)

        assert error.message =~ "mix snowflex_dev.setup"
      end
    end

    test "uses default path when no :python_path in opts" do
      # Default path is _snowflex_dev/venv/bin/python3 relative to cwd
      # which won't exist in test, so should get PYTHON_NOT_FOUND
      assert {:error, %Error{code: "SNOWFLEX_DEV_PYTHON_NOT_FOUND"}} =
               HealthCheck.validate([])
    end
  end
end
