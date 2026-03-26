# Phase 4: Developer Experience - Research

**Researched:** 2026-03-26
**Domain:** Elixir Mix tasks, Python venv management, connection health checks, config-driven adapter swap
**Confidence:** HIGH

## Summary

Phase 4 delivers the "last mile" developer experience: a Mix task that bootstraps the Python environment, startup health checks with actionable error messages, and documentation/config patterns that enable zero-code-change adapter swap between SnowflexDev (dev) and Snowflex (prod).

The codebase already has all the infrastructure -- Transport.Port, Connection, Ecto adapter -- but currently assumes the Python venv exists at `_snowflex_dev/venv/bin/python3` (hardcoded default in Transport.Port.init/1). There is no Mix task, no health check module, and no documentation for consuming apps. The config keys between Snowflex (account_name, username, private_key_path, transport) and SnowflexDev (account, user, authenticator) differ, so the "config-only swap" requires careful key mapping or documentation.

**Primary recommendation:** Build two new modules (Mix task + health check), add startup validation to Connection.connect/1, and provide clear config examples showing the per-environment adapter swap pattern. Keep it simple -- no new dependencies needed.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DX-01 | `mix snowflex_dev.setup` creates Python virtualenv and installs snowflake-connector-python automatically | Mix task at `lib/mix/tasks/snowflex_dev.setup.ex` using System.cmd for python3/pip; venv at `_snowflex_dev/venv/` |
| DX-02 | Connection health check on startup verifies Snowflake connectivity and reports clear errors | Add pre-flight checks in Connection.connect/1 before Port.start_link -- verify python binary, venv, then use existing ping after connect |
| DX-03 | Detailed error messages for common failure modes (Python not found, venv missing, pip install failed, Snowflake unreachable) | HealthCheck module with specific check functions, each returning tagged {:error, %Error{}} with actionable fix instructions |
| DX-04 | Config-only swap -- consuming app switches between SnowflexDev and Snowflex by changing adapter in config, zero code changes | Document per-env config pattern; Snowflex uses `account_name`/`username`, SnowflexDev uses `account`/`user` -- keys differ but Repo module stays the same |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- Must implement DBConnection behaviour (already done)
- Elixir ~> 1.18, Python >= 3.9
- Dev-only dependency -- SnowflexDev should be `only: :dev`
- No BEAM instability from Python failures
- Result format parity with Snowflex
- Erlang Port (not Pythonx, ErlPort, NIFs)
- JSON protocol with `{:packet, 4}` framing
- `snowflake-connector-python` with `externalbrowser` SSO

## Standard Stack

### Core (already present -- no new deps)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Mix.Task | stdlib | Custom mix task framework | Built into Elixir, no dependencies needed |
| System.cmd/3 | stdlib | Shell out to python3/pip for venv setup | Safe for one-shot setup commands (not long-lived like Port) |
| File | stdlib | Directory existence checks, path operations | Stdlib |
| Logger | stdlib | Startup diagnostic messages | Already used in Transport.Port |

### No new Hex dependencies required

This phase adds no new dependencies to mix.exs. Everything uses Elixir/Erlang stdlib.

## Architecture Patterns

### Recommended Project Structure
```
lib/
  mix/
    tasks/
      snowflex_dev.setup.ex     # DX-01: Mix task for venv setup
  snowflex_dev/
    health_check.ex             # DX-02/DX-03: Pre-flight validation module
    connection.ex               # Modified: call HealthCheck before Port.start_link
    transport/
      port.ex                   # Existing: minor changes to default paths
```

### Pattern 1: Mix Task with Shell-Out for Python Setup
**What:** A Mix task that creates a Python virtualenv and installs snowflake-connector-python using System.cmd/3
**When to use:** One-time setup, not performance-critical
**Why System.cmd, not Port:** System.cmd is the right choice for one-shot commands that run and exit. Port.open is for long-lived processes. The Mix task runs `python3 -m venv` and `pip install` -- both short-lived.

```elixir
defmodule Mix.Tasks.SnowflexDev.Setup do
  @moduledoc "Creates Python virtualenv and installs snowflake-connector-python."
  @shortdoc "Set up SnowflexDev Python environment"

  use Mix.Task

  @venv_dir "_snowflex_dev/venv"
  @requirements ["snowflake-connector-python>=3.12,<5.0"]

  @impl Mix.Task
  def run(_args) do
    python = find_python!()
    create_venv!(python)
    install_deps!()
    Mix.shell().info("SnowflexDev setup complete.")
  end

  defp find_python! do
    # Try python3 first, then python, check version >= 3.9
    ...
  end
end
```

**File naming convention:** Elixir Mix tasks use dot-separated names. `mix snowflex_dev.setup` maps to `Mix.Tasks.SnowflexDev.Setup` in `lib/mix/tasks/snowflex_dev.setup.ex`.

### Pattern 2: Pre-Flight Health Check Module
**What:** A module that validates the environment before attempting a Port connection
**When to use:** Called from Connection.connect/1 before Port.start_link
**Why separate module:** Keeps Connection clean; health checks are independently testable

```elixir
defmodule SnowflexDev.HealthCheck do
  @moduledoc "Pre-flight environment validation for SnowflexDev connections."

  alias SnowflexDev.Error

  @spec validate(keyword()) :: :ok | {:error, Error.t()}
  def validate(opts) do
    with :ok <- check_python(opts),
         :ok <- check_venv(opts),
         :ok <- check_snowflake_connector(opts) do
      :ok
    end
  end

  defp check_python(opts) do
    python_path = Keyword.get(opts, :python_path, default_python_path())
    if File.exists?(python_path) do
      :ok
    else
      {:error, %Error{
        message: """
        Python not found at: #{python_path}

        To fix: run `mix snowflex_dev.setup` to create the Python environment,
        or set :python_path in your config to point to an existing Python 3.9+ binary.
        """,
        code: "SNOWFLEX_DEV_PYTHON_NOT_FOUND"
      }}
    end
  end
end
```

### Pattern 3: Config-Only Adapter Swap
**What:** Consuming app defines Repo once, switches adapter via per-environment config
**When to use:** The primary integration pattern for SnowflexDev

```elixir
# lib/my_app/repo.ex -- NO changes between dev and prod
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app
end

# config/dev.exs
config :my_app, MyApp.Repo,
  adapter: SnowflexDev,
  account: "my-account",
  user: "my.email@company.com",
  warehouse: "MY_WH",
  database: "MY_DB",
  schema: "PUBLIC",
  role: "MY_ROLE"

# config/prod.exs
config :my_app, MyApp.Repo,
  adapter: Snowflex,
  transport: Snowflex.Transport.Http,
  account_name: "my-account",
  username: "service_account",
  private_key_path: "/path/to/key.pem",
  public_key_fingerprint: "SHA256:..."
```

**Key insight:** The Repo module does NOT specify adapter in `use Ecto.Repo` -- it only specifies `otp_app`. The adapter comes from runtime config. This is the standard Ecto pattern for swapping adapters.

### Anti-Patterns to Avoid
- **Hardcoding adapter in Repo module:** `use Ecto.Repo, adapter: SnowflexDev` prevents config-only swap. Must be config-driven.
- **Starting the application in the Mix task:** `mix snowflex_dev.setup` should NOT call `Mix.Task.run("app.start")` -- it only needs python3 on the system PATH, not a running Elixir app.
- **Blocking on health check failures:** Health checks should return errors to DBConnection (which handles retry/backoff), not raise or halt the VM.
- **Checking Snowflake connectivity in health check:** The health check should only verify LOCAL prerequisites (python, venv, connector). Snowflake connectivity is verified by the existing `ping` mechanism in DBConnection pool. SSO auth happens during Port connect, not in pre-flight.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Python version detection | Custom version parser | `System.cmd("python3", ["-c", "import sys; print(sys.version_info[:2])"])` | Reliable, handles all Python version formats |
| Venv creation | Custom virtualenv logic | `System.cmd(python, ["-m", "venv", path])` | Python's built-in venv module handles all platform differences |
| Pip install | Custom package management | `System.cmd(venv_pip, ["install", "snowflake-connector-python>=3.12,<5.0"])` | pip handles dependency resolution, wheels, platform specifics |
| Connector presence check | Import test in subprocess | `System.cmd(venv_python, ["-c", "import snowflake.connector"])` | Direct, fast, authoritative |

## Common Pitfalls

### Pitfall 1: Python Binary Name Varies by Platform
**What goes wrong:** `python3` exists on macOS/Linux but might be `python` on some systems. Windows uses `python.exe`.
**Why it happens:** Different OS packaging conventions.
**How to avoid:** Try `python3` first, fall back to `python`, verify version >= 3.9. Document in error messages.
**Warning signs:** "command not found" errors during setup.

### Pitfall 2: Venv Path Must Be Relative to Project Root
**What goes wrong:** If venv path is relative and Mix task runs from a different CWD, venv is created in wrong location.
**Why it happens:** Mix tasks typically run from project root, but not guaranteed.
**How to avoid:** Use `Mix.Project.deps_path()` parent or `File.cwd!()` to anchor paths. The current Transport.Port already uses `File.cwd!()` for the default path.
**Warning signs:** "venv missing" errors after successful setup.

### Pitfall 3: Config Key Mismatch Between Snowflex and SnowflexDev
**What goes wrong:** Developer copies Snowflex config, changes adapter to SnowflexDev, gets cryptic errors because keys differ.
**Why it happens:** Snowflex uses `account_name`/`username`, SnowflexDev uses `account`/`user` (matching Python connector's parameter names).
**How to avoid:** Clear documentation. Optionally support both key names with fallback in Protocol.encode_connect.
**Warning signs:** Nil values for required Snowflake connection params.

### Pitfall 4: SSO Login Timeout During Health Check
**What goes wrong:** Pre-flight checks pass, but Connection.connect blocks for 5 minutes waiting for browser SSO.
**Why it happens:** `externalbrowser` auth opens a browser popup; user might not notice or might be AFK.
**How to avoid:** This is already handled -- Transport.Port has a `login_timeout` of 300_000ms (5 min). Connection.connect returns an error if it times out. Log a clear message when SSO auth starts: "Waiting for browser SSO authentication..."
**Warning signs:** Hanging startup with no output.

### Pitfall 5: Pip Install Fails Behind Corporate Proxy
**What goes wrong:** `pip install snowflake-connector-python` fails with SSL or network errors.
**Why it happens:** Corporate environments often require proxy config or custom CA certificates.
**How to avoid:** Print pip's stderr output in the Mix task error message. Suggest `PIP_CERT`, `HTTPS_PROXY` environment variables.
**Warning signs:** SSL certificate verification errors during setup.

### Pitfall 6: Gitignoring the Venv Directory
**What goes wrong:** `_snowflex_dev/` gets committed to git, adding hundreds of MB.
**Why it happens:** Developer forgets to add to .gitignore.
**How to avoid:** Mix task should check/add `_snowflex_dev/` to .gitignore automatically, or at minimum print a warning.
**Warning signs:** Slow git operations, large repo size.

## Code Examples

### Mix Task: Full Implementation Pattern

```elixir
defmodule Mix.Tasks.SnowflexDev.Setup do
  @moduledoc """
  Creates a Python virtual environment and installs snowflake-connector-python.

  ## Usage

      mix snowflex_dev.setup

  Creates `_snowflex_dev/venv/` in the project root with Python 3.9+
  and the snowflake-connector-python package installed.
  """
  @shortdoc "Set up SnowflexDev Python environment"

  use Mix.Task

  @venv_dir "_snowflex_dev/venv"
  @pip_package "snowflake-connector-python>=3.12,<5.0"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Setting up SnowflexDev Python environment...")

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
    cond do
      System.find_executable("python3") -> "python3"
      System.find_executable("python") -> "python"
      true ->
        Mix.raise("""
        Python not found!

        SnowflexDev requires Python 3.9 or later.
        Install Python from https://python.org or via your package manager:

          macOS:   brew install python
          Ubuntu:  sudo apt install python3 python3-venv
          Fedora:  sudo dnf install python3
        """)
    end
  end

  defp verify_python_version!(python) do
    {output, 0} = System.cmd(python, ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"])
    version = String.trim(output)
    [major, minor] = String.split(version, ".") |> Enum.map(&String.to_integer/1)

    if major < 3 or (major == 3 and minor < 9) do
      Mix.raise("Python #{version} found, but SnowflexDev requires Python >= 3.9")
    end

    Mix.shell().info("  Found Python #{version}")
  end

  defp create_venv!(python) do
    if File.dir?(@venv_dir) do
      Mix.shell().info("  Venv already exists at #{@venv_dir}")
    else
      Mix.shell().info("  Creating virtual environment...")
      case System.cmd(python, ["-m", "venv", @venv_dir], stderr_to_stdout: true) do
        {_, 0} -> :ok
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
    pip = Path.join([@venv_dir, "bin", "pip"])

    Mix.shell().info("  Installing snowflake-connector-python (this may take a minute)...")
    case System.cmd(pip, ["install", "--upgrade", @pip_package], stderr_to_stdout: true) do
      {_, 0} -> :ok
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
    python = Path.join([@venv_dir, "bin", "python3"])
    case System.cmd(python, ["-c", "import snowflake.connector; print(snowflake.connector.__version__)"], stderr_to_stdout: true) do
      {version, 0} ->
        Mix.shell().info("  Verified snowflake-connector-python #{String.trim(version)}")
      {output, _} ->
        Mix.raise("snowflake-connector-python import failed after install: #{output}")
    end
  end
end
```

### Health Check: Pre-Flight Validation

```elixir
defmodule SnowflexDev.HealthCheck do
  @moduledoc "Validates Python environment before attempting Snowflake connection."

  alias SnowflexDev.Error
  require Logger

  @spec validate(keyword()) :: :ok | {:error, Error.t()}
  def validate(opts) do
    python_path = Keyword.get(opts, :python_path, default_python_path())

    with :ok <- check_python_exists(python_path),
         :ok <- check_connector_importable(python_path) do
      :ok
    end
  end

  defp check_python_exists(python_path) do
    if File.exists?(python_path) do
      :ok
    else
      {:error, %Error{
        message: "Python not found at #{python_path}. Run: mix snowflex_dev.setup",
        code: "SNOWFLEX_DEV_PYTHON_NOT_FOUND"
      }}
    end
  end

  defp check_connector_importable(python_path) do
    case System.cmd(python_path, ["-c", "import snowflake.connector"],
           stderr_to_stdout: true, env: [{"PYTHONDONTWRITEBYTECODE", "1"}]) do
      {_, 0} -> :ok
      {output, _} ->
        {:error, %Error{
          message: """
          snowflake-connector-python not importable:
          #{String.trim(output)}

          Run: mix snowflex_dev.setup
          """,
          code: "SNOWFLEX_DEV_CONNECTOR_MISSING"
        }}
    end
  end

  defp default_python_path do
    Path.join([File.cwd!(), "_snowflex_dev", "venv", "bin", "python3"])
  end
end
```

### Connection.connect/1 with Health Check

```elixir
# In Connection.connect/1, add health check before Port.start_link:
def connect(opts) do
  case SnowflexDev.HealthCheck.validate(opts) do
    :ok ->
      Logger.info("SnowflexDev: Starting Python worker, SSO auth may open browser...")
      case Transport.Port.start_link(opts) do
        {:ok, pid} -> {:ok, %__MODULE__{transport_pid: pid, opts: opts}}
        {:error, reason} -> {:error, %Error{message: "Failed to connect: #{inspect(reason)}", code: "SNOWFLEX_DEV_CONNECT"}}
      end

    {:error, %Error{} = error} ->
      {:error, error}
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `virtualenv` package | `python3 -m venv` | Python 3.3+ | No need for separate virtualenv install; venv is stdlib |
| Hard-coded adapter in Repo | Config-driven adapter | Ecto 3.x | `use Ecto.Repo, otp_app: :my_app` without adapter key enables per-env config |
| Manual pip install | Mix task automation | N/A | One command instead of multi-step instructions |

## Open Questions

1. **Should SnowflexDev accept Snowflex config keys as aliases?**
   - What we know: Snowflex uses `account_name`/`username`, SnowflexDev uses `account`/`user` (matching Python connector params)
   - What's unclear: Whether supporting both key names reduces friction enough to justify the complexity
   - Recommendation: Support both with fallback (e.g., `Keyword.get(opts, :account) || Keyword.get(opts, :account_name)`) in Protocol.encode_connect. Low cost, high friction reduction.

2. **Should the Mix task auto-add `_snowflex_dev/` to .gitignore?**
   - What we know: The venv directory is large (200+ MB) and should never be committed
   - What's unclear: Whether modifying .gitignore is too presumptuous for a setup task
   - Recommendation: Print a warning if not in .gitignore, but don't auto-modify. Keep the task simple.

3. **Windows path differences**
   - What we know: Windows uses `Scripts\python.exe` instead of `bin/python3` in venvs. Windows support is deferred to v2.
   - What's unclear: N/A -- documented as out of scope
   - Recommendation: Use `bin/python3` only. Document macOS/Linux only for v1.

## Sources

### Primary (HIGH confidence)
- Snowflex source code -- https://github.com/pepsico-ecommerce/snowflex -- config patterns, Ecto adapter structure
- Existing SnowflexDev codebase -- Transport.Port default paths, Connection.connect/1, Protocol.encode_connect
- Mix.Task docs -- https://hexdocs.pm/mix/Mix.Task.html -- task definition patterns
- Python venv docs -- https://docs.python.org/3/library/venv.html -- stdlib venv module

### Secondary (MEDIUM confidence)
- Snowflex README -- https://github.com/pepsico-ecommerce/snowflex/blob/master/README.md -- config key names
- Elixir School Mix Tasks -- https://elixirschool.com/en/lessons/intermediate/mix_tasks -- task conventions

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - no new dependencies, all stdlib
- Architecture: HIGH - patterns are straightforward Elixir (Mix task + module)
- Pitfalls: HIGH - based on direct codebase inspection and known Python packaging issues
- Config swap: HIGH - standard Ecto per-env config pattern, verified against Snowflex source

**Research date:** 2026-03-26
**Valid until:** 2026-04-25 (stable -- no fast-moving dependencies)
