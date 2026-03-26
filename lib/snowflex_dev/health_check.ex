defmodule SnowflexDev.HealthCheck do
  @moduledoc "Validates Python environment before attempting Snowflake connection."

  alias SnowflexDev.Error

  @default_python_path Path.join([File.cwd!(), "_snowflex_dev", "venv", "bin", "python3"])

  @spec validate(keyword()) :: :ok | {:error, Error.t()}
  def validate(opts) do
    python_path = Keyword.get(opts, :python_path, @default_python_path)

    with :ok <- check_python_exists(python_path),
         :ok <- check_connector_importable(python_path) do
      :ok
    end
  end

  defp check_python_exists(python_path) do
    if File.exists?(python_path) do
      :ok
    else
      {:error,
       %Error{
         message:
           "Python not found at: #{python_path}\n\n" <>
             "To fix: run `mix snowflex_dev.setup` to create the Python environment,\n" <>
             "or set :python_path in your config to point to an existing Python 3.9+ binary.",
         code: "SNOWFLEX_DEV_PYTHON_NOT_FOUND"
       }}
    end
  end

  defp check_connector_importable(python_path) do
    case System.cmd(python_path, ["-c", "import snowflake.connector"],
           stderr_to_stdout: true,
           env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
         ) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error,
         %Error{
           message:
             "snowflake-connector-python not importable:\n#{String.trim(output)}\n\n" <>
               "Run: mix snowflex_dev.setup",
           code: "SNOWFLEX_DEV_CONNECTOR_MISSING"
         }}
    end
  end
end
