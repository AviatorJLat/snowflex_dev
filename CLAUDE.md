<!-- GSD:project-start source:PROJECT.md -->
## Project

**SnowflexDev**

A drop-in development replacement for Snowflex (Elixir Snowflake Ecto adapter) that uses Python's `snowflake-connector-python` with `externalbrowser` SSO authentication under the hood. Implements the full `DBConnection` behaviour so consuming Phoenix apps can swap between SnowflexDev (dev) and Snowflex (prod) via config — no application code changes.

SnowflexDev bridges Elixir and Python via an Erlang Port, managing a bundled Python virtualenv with `snowflake-connector-python` pre-installed. A Mix task handles venv creation automatically.

**Core Value:** Developers get Snowflake access in local development using their existing SSO credentials with zero infrastructure setup — no keypairs, no security integrations, no admin involvement. Just `mix snowflex_dev.setup`, configure, and query.

### Constraints

- **Interface compatibility**: Must implement DBConnection behaviour so Ecto.Repo works without code changes in consuming apps
- **Elixir version**: Must support ~> 1.14 (matching Snowflex's minimum)
- **Python version**: Require Python 3.8+ (snowflake-connector-python minimum)
- **Dev-only dependency**: SnowflexDev should be added as `only: :dev` in consuming apps
- **No BEAM instability**: Python process failures must not crash the Elixir supervision tree — restart strategy with backoff
- **Result format parity**: Query results must match Snowflex's return format exactly
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

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
### Why Erlang Port (RECOMMENDED)
### Why NOT Pythonx
- **GIL blocks concurrency**: "The GIL prevents multiple threads from executing Python code at the same time, so calling Pythonx from multiple Elixir processes does not provide the concurrency you might expect." With DBConnection pool_size > 1, all Python calls would serialize through a single GIL. This defeats the purpose of connection pooling.
- **No process isolation**: A Python crash can take down the entire BEAM VM. Unacceptable for a dev tool.
- **Designed for different use case**: Pythonx is great for Livebook notebooks and one-off Python calls. It is wrong for a long-running database connection pool.
### Why NOT ErlPort
- **Unmaintained**: Last release was years ago. No updates for recent Elixir/Python versions.
- **Unnecessary abstraction**: We need a simple JSON protocol, not Erlang External Term Format translation. ErlPort adds complexity without value for our use case.
- **Magic**: ErlPort tries to transparently call Python functions from Elixir. We want an explicit, simple request/response protocol.
### Why NOT NIFs (Rust/C bindings)
- **Overkill**: We're sending SQL strings and getting result sets back. There's no CPU-intensive hot path that justifies NIF complexity.
- **No isolation**: NIF crash = VM crash.
- **No Python connector**: There's no C/Rust Snowflake connector with externalbrowser SSO support. We need the Python connector specifically.
## Port Protocol Design
### Packet Framing: `{:packet, 4}` (4-byte length prefix)
- JSON payloads can contain newlines (in SQL strings, error messages)
- No escaping/unescaping needed
- Erlang handles framing automatically on the Elixir side
### Message Format: JSON request/response
### Python Script Structure
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
# mix.exs deps
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
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
