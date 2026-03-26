# Technology Stack

**Project:** SnowflexDev (Elixir-Python bridge for Snowflake dev access)
**Researched:** 2026-03-26

## Recommended Stack

### Core Framework

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| Elixir | `~> 1.18` | Runtime (project minimum) | Already set in mix.exs. Matches current OTP compatibility. | HIGH |
| Erlang Port | stdlib | Elixir-to-Python IPC | Process isolation is non-negotiable. Python crash must not take down the BEAM. Ports are battle-tested, require no deps, and give true OS-process isolation. Each Port = one Python process = one DB connection, which maps cleanly to DBConnection's pool model. | HIGH |
| `db_connection` | `~> 2.7` | Connection pooling + behaviour | v2.9.0 is latest (Jan 2026). Snowflex uses `~> 2.4`. We need the same behaviour interface so Ecto.Adapters.SQL works identically. Pin `~> 2.7` to get recent fixes while staying compatible with ecto_sql 3.13.x. | HIGH |
| `ecto` | `~> 3.12` | Schema/query DSL | v3.13.5 is latest (Mar 2026). Must match Snowflex's `~> 3.12` constraint so consuming apps don't get version conflicts. | HIGH |
| `ecto_sql` | `~> 3.12` | SQL adapter integration | v3.13.5 is latest (Mar 2026). Provides `Ecto.Adapters.SQL` which our adapter delegates to (same as Snowflex). Must match Snowflex's constraint. | HIGH |
| `jason` | `~> 1.4` | JSON encode/decode for Port protocol | v1.4.4 is latest. Already a ubiquitous Elixir dep. Used on both sides of the Port: Elixir encodes commands as JSON, Python decodes and responds as JSON. Simple, debuggable, human-readable protocol. | HIGH |
| `telemetry` | `~> 0.4 or ~> 1.0` | Instrumentation events | Match Snowflex's constraint exactly. Ecto.Adapters.SQL uses telemetry internally. | HIGH |

### Python Side

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| Python | `>= 3.9` | Runtime for Snowflake connector | snowflake-connector-python 3.12+ dropped Python 3.8. Pin 3.9+ to be safe. Most dev machines have 3.10+. | HIGH |
| `snowflake-connector-python` | `>= 3.12, < 5.0` | Snowflake DB access with SSO | v4.4.0 is latest (Mar 2026). The `externalbrowser` authenticator handles the entire SSO flow internally -- opens browser, receives SAML token, caches credentials. We just call `snowflake.connector.connect(authenticator='externalbrowser')` and it works. | HIGH |
| `json` (stdlib) | stdlib | JSON protocol handling | Python's stdlib json module. No pip dependency needed for the Port protocol. Matches Jason on the Elixir side. | HIGH |

### Supporting Libraries

| Library | Version | Purpose | When to Use | Confidence |
|---------|---------|---------|-------------|------------|
| `backoff` | `~> 1.1.6` | Exponential backoff for reconnects | Optional -- use if we want Snowflex-compatible reconnect behaviour. Snowflex uses this for transport retry. Consider only if we implement automatic Port restart with backoff. | MEDIUM |
| `nimble_options` | `~> 1.0` | Config validation | Validate connection opts (account, user, warehouse, etc.) at startup with clear error messages instead of runtime crashes. Already a transitive dep via ecto. | MEDIUM |

### Development Tools

| Tool | Purpose | Notes | Confidence |
|------|---------|-------|------------|
| `dialyxir` | `~> 1.4` | Static type analysis | Add typespecs to Port protocol messages, DBConnection state, Result struct. | HIGH |
| `credo` | `~> 1.7` | Linting | Standard Elixir linting. | HIGH |
| `ex_doc` | `>= 0.0.0` | Documentation | Dev-only. Important for documenting the Port protocol and setup instructions. | HIGH |
| `mox` | `~> 1.0` | Test mocking | Mock the Python Port in tests so CI doesn't need Python/Snowflake. Define a Port behaviour and mock it. | HIGH |

## Architecture Decision: Erlang Port (not Pythonx, not ErlPort, not NIFs)

This is the most important stack decision. Three options exist for Elixir-to-Python communication:

### Why Erlang Port (RECOMMENDED)

1. **Process isolation**: Python runs in a separate OS process. A segfault, memory leak, or unhandled exception in Python cannot crash the BEAM VM. This is critical for a dev tool -- developer experience must not include random VM crashes.

2. **DBConnection pool alignment**: DBConnection manages a pool of connection processes. Each pool member can own one Port (one Python process). This is a natural 1:1 mapping -- no multiplexing complexity, no GIL contention. Pool size = number of Python processes.

3. **No compilation deps**: Ports use stdin/stdout. No C compiler, no NIF loading, no platform-specific binaries. `mix deps.get && mix compile` just works.

4. **Debuggable protocol**: JSON over stdin/stdout can be logged, inspected, and tested independently. You can run the Python script manually and paste JSON to test it.

5. **Proven pattern**: Stuart Engineering (production Elixir shop) uses this exact pattern for Python ML model serving. The Erlangelist's "Outside Elixir" guide documents the `{:packet, 4}` length-prefixed protocol in detail.

### Why NOT Pythonx

Pythonx (by Dashbit/Livebook) embeds a Python interpreter in the BEAM process via NIFs. Per the official Dashbit blog:

- **GIL blocks concurrency**: "The GIL prevents multiple threads from executing Python code at the same time, so calling Pythonx from multiple Elixir processes does not provide the concurrency you might expect." With DBConnection pool_size > 1, all Python calls would serialize through a single GIL. This defeats the purpose of connection pooling.
- **No process isolation**: A Python crash can take down the entire BEAM VM. Unacceptable for a dev tool.
- **Designed for different use case**: Pythonx is great for Livebook notebooks and one-off Python calls. It is wrong for a long-running database connection pool.

### Why NOT ErlPort

ErlPort (erlport hex package) wraps Erlang port protocol with its own data serialization:

- **Unmaintained**: Last release was years ago. No updates for recent Elixir/Python versions.
- **Unnecessary abstraction**: We need a simple JSON protocol, not Erlang External Term Format translation. ErlPort adds complexity without value for our use case.
- **Magic**: ErlPort tries to transparently call Python functions from Elixir. We want an explicit, simple request/response protocol.

### Why NOT NIFs (Rust/C bindings)

- **Overkill**: We're sending SQL strings and getting result sets back. There's no CPU-intensive hot path that justifies NIF complexity.
- **No isolation**: NIF crash = VM crash.
- **No Python connector**: There's no C/Rust Snowflake connector with externalbrowser SSO support. We need the Python connector specifically.

## Port Protocol Design

### Packet Framing: `{:packet, 4}` (4-byte length prefix)

Use Erlang's built-in length-prefixed packet mode. When opening the Port:

```elixir
Port.open({:spawn_executable, python_path}, [
  :binary,
  :exit_status,
  {:packet, 4},        # 4-byte big-endian length prefix
  {:args, [script_path]},
  {:env, env_vars}
])
```

On the Python side, read 4 bytes for message length, then read that many bytes for the JSON payload. Write responses the same way: 4-byte length + JSON bytes.

This is superior to line-delimited because:
- JSON payloads can contain newlines (in SQL strings, error messages)
- No escaping/unescaping needed
- Erlang handles framing automatically on the Elixir side

### Message Format: JSON request/response

```json
// Elixir -> Python (command)
{"type": "connect", "config": {"account": "...", "user": "...", "warehouse": "..."}}
{"type": "query", "id": "uuid", "statement": "SELECT ...", "params": [...]}
{"type": "disconnect"}

// Python -> Elixir (response)
{"type": "ok", "id": "uuid", "columns": [...], "rows": [...], "num_rows": 3}
{"type": "error", "id": "uuid", "message": "...", "code": "..."}
{"type": "connected"}
```

### Python Script Structure

The Python side is a single long-running script (~150-200 lines) that:
1. Reads length-prefixed JSON commands from stdin
2. Maintains a snowflake.connector connection
3. Executes queries via cursor
4. Writes length-prefixed JSON responses to stdout
5. Never writes to stdout for any other purpose (logging goes to stderr)

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| IPC mechanism | Erlang Port | Pythonx (NIF) | GIL serializes concurrent calls; no process isolation; wrong use case |
| IPC mechanism | Erlang Port | ErlPort | Unmaintained; unnecessary abstraction over what we can do with stdlib |
| IPC mechanism | Erlang Port | TCP socket | More complex setup (port allocation, connection management) for no benefit over stdin/stdout |
| Serialization | JSON (`jason` + Python `json`) | MessagePack | Overkill -- query payloads are small strings. JSON is human-readable and debuggable |
| Serialization | JSON (`jason` + Python `json`) | Erlang External Term Format | Python side requires erlport or custom parsing. JSON is universally supported |
| Serialization | JSON (`jason` + Python `json`) | Protocol Buffers | Massive over-engineering for a dev tool. Schema maintenance overhead |
| Packet framing | `{:packet, 4}` | Line-delimited (`\n`) | SQL strings contain newlines; would require escaping |
| Packet framing | `{:packet, 4}` | `{:packet, 2}` | 2-byte prefix limits messages to 64KB. Result sets can exceed this |
| Python env | Bundled venv via Mix task | System Python | Dependency isolation; reproducible installs |
| Python env | Bundled venv via Mix task | Docker container | Way too heavy for a dev tool convenience library |
| Connection model | 1 Port per DBConnection pool slot | Single Port with multiplexing | Complexity not warranted; pool handles concurrency |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Pythonx | GIL serializes pool; no isolation; designed for notebooks not connection pools | Erlang Port with `{:packet, 4}` |
| ErlPort (hex package) | Unmaintained, unnecessary abstraction | Raw Erlang Port |
| `erlport` (Erlang lib) | Same issues as ErlPort hex package | Raw Erlang Port |
| `System.cmd/3` | Starts a new process per call. We need a long-lived connection | `Port.open/2` for persistent process |
| Line-delimited protocol | SQL contains newlines, result sets need binary safety | `{:packet, 4}` length-prefixed |
| `{:packet, 2}` | 64KB message limit too small for result sets | `{:packet, 4}` (4GB limit) |
| `pickle` (Python) | Security risk, not cross-language | JSON |
| `ueberauth` / `oauth2` hex | Wrong paradigm entirely -- we're not doing OAuth. externalbrowser SSO is handled by the Python connector | snowflake-connector-python's `externalbrowser` authenticator |
| ODBC (`erlang :odbc`) | Requires system ODBC driver install, C compilation, platform-specific setup | Python connector via Port |

## Version Compatibility Matrix

| Package | Version | Compatible With | Notes | Confidence |
|---------|---------|-----------------|-------|------------|
| `db_connection` | `~> 2.7` | ecto_sql `~> 3.12`, elixir `~> 1.11` | v2.9.0 latest (Jan 2026) | HIGH |
| `ecto` | `~> 3.12` | elixir `~> 1.14` | v3.13.5 latest (Mar 2026). Must match Snowflex constraint | HIGH |
| `ecto_sql` | `~> 3.12` | ecto `~> 3.12`, db_connection `~> 2.0` | v3.13.5 latest (Mar 2026) | HIGH |
| `jason` | `~> 1.4` | elixir `~> 1.11` | v1.4.4 latest. Ubiquitous | HIGH |
| `telemetry` | `~> 0.4 or ~> 1.0` | All Ecto ecosystem | Match Snowflex constraint | HIGH |
| `snowflake-connector-python` | `>= 3.12` | Python 3.9+ | v4.4.0 latest (Mar 2026). 3.12+ dropped Python 3.8 | HIGH |

## Installation

```elixir
# mix.exs deps
defp deps do
  [
    # Core -- DBConnection + Ecto integration
    {:db_connection, "~> 2.7"},
    {:ecto, "~> 3.12"},
    {:ecto_sql, "~> 3.12"},

    # Serialization -- Port protocol
    {:jason, "~> 1.4"},

    # Instrumentation
    {:telemetry, "~> 0.4 or ~> 1.0"},

    # Dev/test tools
    {:dialyxir, "~> 1.4", only: :dev, runtime: false},
    {:credo, "~> 1.7", only: :dev, runtime: false},
    {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
    {:mox, "~> 1.0", only: :test},
  ]
end
```

Python dependencies (installed by `mix snowflex_dev.setup` into bundled venv):

```
snowflake-connector-python>=3.12,<5.0
```

No other Python packages needed. The Python script uses only stdlib (`json`, `sys`, `struct`) plus `snowflake.connector`.

## Sources

- [hex.pm/packages/db_connection](https://hex.pm/packages/db_connection) -- v2.9.0 (Jan 2026) -- HIGH confidence
- [hexdocs.pm/db_connection/DBConnection.html](https://hexdocs.pm/db_connection/DBConnection.html) -- Behaviour API reference -- HIGH confidence
- [hex.pm/packages/ecto](https://hex.pm/packages/ecto) -- v3.13.5 (Mar 2026) -- HIGH confidence
- [hex.pm/packages/ecto_sql](https://hex.pm/packages/ecto_sql) -- v3.13.5 (Mar 2026) -- HIGH confidence
- [hex.pm/packages/jason](https://hex.pm/packages/jason) -- v1.4.4 -- HIGH confidence
- [pypi.org/project/snowflake-connector-python](https://pypi.org/project/snowflake-connector-python/) -- v4.4.0 (Mar 2026) -- HIGH confidence
- [docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect) -- externalbrowser auth docs -- HIGH confidence
- [dashbit.co/blog/running-python-in-elixir-its-fine](https://dashbit.co/blog/running-python-in-elixir-its-fine) -- Pythonx GIL limitations documented -- HIGH confidence
- [elixir-lang.org/blog/2025/08/18/interop-and-portability](https://elixir-lang.org/blog/2025/08/18/interop-and-portability/) -- Official Elixir interop guidance 2025 -- HIGH confidence
- [tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports](https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/) -- Port GenServer patterns -- MEDIUM confidence
- [medium.com/stuart-engineering/how-we-use-python-within-elixir](https://medium.com/stuart-engineering/how-we-use-python-within-elixir-486eb4d266f9) -- Production Elixir+Python Port pattern -- MEDIUM confidence
- [dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii](https://dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii-dbconnection-integration) -- DBConnection implementation reference -- HIGH confidence
- [github.com/elixir-ecto/db_connection](https://github.com/elixir-ecto/db_connection) -- Example implementations in /examples -- HIGH confidence
- [Snowflex source code](https://github.com/pepsico-ecommerce/snowflex) -- Connection.ex, Query.ex, Result.ex interface to match -- HIGH confidence (local)
