defmodule Mix.Tasks.SnowflexDev.Setup do
  @moduledoc """
  Creates a Python virtual environment and installs snowflake-connector-python.

  ## Usage

      mix snowflex_dev.setup

  This task:
  1. Finds Python 3.9+ on your system PATH
  2. Creates a virtual environment at `_snowflex_dev/venv/`
  3. Installs `snowflake-connector-python` into the venv
  4. Verifies the installation by importing the connector

  ## Prerequisites

  - Python 3.9 or later must be installed on your system
  - The `venv` module must be available (included with most Python installations)
  """

  @shortdoc "Set up SnowflexDev Python environment"

  use Mix.Task

  @venv_dir "_snowflex_dev/venv"
  @pip_package "snowflake-connector-python[secure-local-storage]>=3.12,<5.0"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Setting up SnowflexDev Python environment...\n")

    python = find_python!()
    verify_python_version!(python)
    create_venv!(python)
    install_deps!()
    verify_install!()

    Mix.shell().info("""

    SnowflexDev setup complete!

    Python venv: #{@venv_dir}/
    Connector:   snowflake-connector-python installed

    Add to your config/dev.exs:

        config :my_app, MyApp.Repo,
          adapter: SnowflexDev,
          account: "your-account",
          user: "your.email@company.com",
          warehouse: "YOUR_WH",
          database: "YOUR_DB",
          schema: "PUBLIC",
          role: "YOUR_ROLE"
    """)
  end

  defp find_python! do
    case System.find_executable("python3") || System.find_executable("python") do
      nil ->
        Mix.raise("""
        Python not found!

        SnowflexDev requires Python 3.9 or later.
        Install Python from https://python.org or via your package manager:

          macOS:   brew install python
          Ubuntu:  sudo apt install python3 python3-venv
          Fedora:  sudo dnf install python3
        """)

      python ->
        python
    end
  end

  defp verify_python_version!(python) do
    {output, 0} =
      System.cmd(python, ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
        stderr_to_stdout: true
      )

    version = String.trim(output)
    [major, minor] = version |> String.split(".") |> Enum.map(&String.to_integer/1)

    if major < 3 or (major == 3 and minor < 9) do
      Mix.raise("Python #{version} found, but SnowflexDev requires Python >= 3.9")
    end

    Mix.shell().info("  Found Python #{version}")
  end

  defp create_venv!(python) do
    if File.dir?(@venv_dir) do
      Mix.shell().info("  Venv already exists at #{@venv_dir}/")
      :ok
    else
      Mix.shell().info("  Creating Python venv at #{@venv_dir}/...")

      case System.cmd(python, ["-m", "venv", @venv_dir], stderr_to_stdout: true) do
        {_output, 0} ->
          Mix.shell().info("  Venv created successfully")

        {output, _code} ->
          Mix.raise("""
          Failed to create Python virtual environment:

          #{output}

          Make sure the `venv` module is available:
            Ubuntu/Debian: sudo apt install python3-venv
          """)
      end
    end
  end

  defp install_deps! do
    python = Path.join([@venv_dir, "bin", "python3"]) |> Path.expand()

    Mix.shell().info("  Installing #{@pip_package}...")

    case System.cmd(python, ["-m", "pip", "install", "--upgrade", @pip_package], stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("  Dependencies installed successfully")

      {output, _code} ->
        Mix.raise("""
        Failed to install snowflake-connector-python:

        #{output}

        If behind a corporate proxy, try:
          HTTPS_PROXY=http://proxy:port mix snowflex_dev.setup
        """)
    end
  end

  defp verify_install! do
    python = Path.join([@venv_dir, "bin", "python3"]) |> Path.expand()

    case System.cmd(python, ["-c", "import snowflake.connector; print(snowflake.connector.__version__)"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        version = String.trim(output)
        Mix.shell().info("  Verified: snowflake-connector-python #{version}")

      {output, _code} ->
        Mix.raise("snowflake-connector-python import failed after install: #{String.trim(output)}")
    end
  end
end
