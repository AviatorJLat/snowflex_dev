# Feature Landscape

**Domain:** Drop-in Elixir database adapter (DBConnection-based) replacing Snowflex for local development
**Researched:** 2026-03-26

## Table Stakes

Features users expect. Missing = consuming apps break or developers reject the tool.

### DBConnection Behaviour (Full Implementation)

These callbacks are **non-negotiable** -- DBConnection calls them and crashes if they're missing or wrong.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `connect/1` | DBConnection calls this to establish a connection. Must start the Python Port process | High | Starts Python subprocess via Erlang Port, establishes stdin/stdout JSON protocol. Most complex single callback |
| `disconnect/2` | DBConnection calls this on pool shutdown or error recovery. Must cleanly kill the Python process | Low | `Port.close/1` or `System.cmd("kill", ...)` -- straightforward |
| `checkout/1` | DBConnection calls this when handing a connection to a caller | Low | Snowflex returns `{:ok, state}` unchanged. We match this |
| `ping/1` | DBConnection calls this every ~1s to verify connection liveness. Must send a probe to Python and get a response | Med | Need a lightweight JSON command like `{"action": "ping"}` over the Port. Python must respond within timeout or connection is recycled |
| `handle_prepare/3` | DBConnection calls this before execute. Snowflex is a no-op (returns query unchanged) | Low | Mirror Snowflex: `{:ok, query, state}` |
| `handle_execute/4` | Core query execution. Must send SQL + params to Python, receive results, return `Snowflex.Result`-compatible struct | High | The critical path. JSON protocol: send `{"action": "execute", "sql": "...", "params": [...]}`, Python runs it via `snowflake-connector-python`, returns JSON rows/columns/metadata |
| `handle_close/3` | DBConnection calls this to release a prepared query | Low | No-op, return empty result (mirrors Snowflex) |
| `handle_declare/4` | Required for streaming/cursors. Snowflex uses this for `Repo.stream` | Med | Must implement cursor declaration in Python. The Python connector supports `cursor.execute()` -- need to hold cursor state |
| `handle_fetch/4` | Fetches next batch from a cursor. Required for streaming | Med | Python `cursor.fetchmany(batch_size)` over the Port protocol |
| `handle_deallocate/4` | Cleans up cursor state after streaming | Low | Tell Python to close the cursor |
| `handle_begin/2` | Transaction begin. Snowflex explicitly disconnects with error "does not support transactions" | Low | **Must match Snowflex's behaviour exactly**: `{:disconnect, Error.exception("..."), state}`. Do NOT silently succeed -- consuming code that accidentally uses transactions must fail the same way |
| `handle_commit/2` | Transaction commit. Same as begin -- explicit disconnect | Low | Mirror Snowflex |
| `handle_rollback/2` | Transaction rollback. Same as begin -- explicit disconnect | Low | Mirror Snowflex |
| `handle_status/2` | Transaction status check. Snowflex disconnects | Low | Mirror Snowflex |

### DBConnection.Query Protocol

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `parse/2` | Called by DBConnection. Snowflex is a no-op | Low | Return query unchanged |
| `describe/2` | Called by DBConnection. Snowflex is a no-op | Low | Return query unchanged |
| `encode/3` | Encodes Elixir params to wire format. Snowflex converts to `%{type: ..., value: ...}` maps for REST API | Med | **We do NOT need Snowflex's REST type encoding.** Python connector handles parameter binding natively. Our encode should convert Elixir types to JSON-safe values (strings, numbers, nil) for the Port protocol |
| `decode/3` | Decodes wire results back to Elixir types. Snowflex decodes REST API strings to native types | Med | **Critical for compatibility.** Python connector returns typed values (int, float, string, datetime as string). Our decode must produce the same Elixir types Snowflex does for the same Snowflake column types. Need to match Snowflex's `Type.decode/2` output |

### Ecto Adapter Behaviours

Snowflex implements three Ecto adapter behaviours. We must implement the same three.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `Ecto.Adapter` callbacks (`init/1`, `ensure_all_started/2`, `checkout/3`, `checked_out?/1`, `loaders/2`, `dumpers/2`, `__before_compile__/1`) | Required for `use Ecto.Repo, adapter: SnowflexDev` to work | Med | Most delegate to `Ecto.Adapters.SQL.*` -- mirror Snowflex's pattern. **Loaders and dumpers must match exactly** (integer, decimal, float, date, time decode; binary encode) |
| `Ecto.Adapter.Queryable` callbacks (`prepare/2`, `execute/5`, `stream/5`) | Required for `Repo.all`, `Repo.one`, `Repo.stream` | Med | Delegates to `Ecto.Adapters.SQL.execute/6`. The SQL generation layer handles this |
| `Ecto.Adapter.Schema` callbacks (`autogenerate/1`, `insert/6`, `insert_all/8`, `update/6`, `delete/5`) | Required for `Repo.insert`, `Repo.update`, `Repo.delete` | Med | Delegates to `Ecto.Adapters.SQL.*` functions |

### Ecto.Adapters.SQL.Connection Behaviour

This is the SQL generation layer. Snowflex has a full Snowflake SQL dialect implementation.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `child_spec/1` | Starts the DBConnection pool | Low | `DBConnection.child_spec(SnowflexDev.Connection, opts)` |
| `prepare_execute/5` | Prepares and executes a query | Low | Delegates to DBConnection |
| `query/4` | Runs a raw SQL statement | Low | Delegates to DBConnection |
| `query_many/4` | Runs a multi-result statement | Low | Delegates to DBConnection |
| `stream/4` | Returns a stream for a query | Low | Delegates to DBConnection |
| `all/1` (SELECT generation) | Generates SELECT SQL from Ecto query AST | **Reuse** | **Do NOT rewrite this.** Snowflex's `Ecto.Adapter.Connection` module has ~900 lines of Snowflake SQL generation. We should reuse it directly or copy it verbatim -- it handles CTEs, joins, window functions, subqueries, QUALIFY, etc. |
| `update_all/1` | UPDATE SQL generation | **Reuse** | Same -- reuse Snowflex's implementation |
| `delete_all/1` | DELETE SQL generation | **Reuse** | Same |
| `insert/7` | INSERT SQL generation | **Reuse** | Same |
| `update/5` | Single-row UPDATE SQL | **Reuse** | Same |
| `delete/4` | Single-row DELETE SQL | **Reuse** | Same |
| `table_exists_query/1` | Check if table exists | **Reuse** | Snowflex uses `information_schema.tables` query |
| `explain_query/4` | EXPLAIN query execution | Low | Snowflex wraps query with "EXPLAIN " prefix |
| `execute_ddl/1` | DDL execution | Low | Snowflex raises "not yet implemented" -- we can match this |
| `ddl_logs/1` | DDL log output | Low | Snowflex raises "not yet implemented" |
| `to_constraints/2` | Constraint error parsing | Low | Snowflex raises the exception -- match this |

### Result Format Parity

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `Snowflex.Result` struct compatibility | Consuming code pattern-matches on result struct fields. If our struct has different field names or shapes, code breaks | High | Must return a struct with fields: `columns` (list of strings), `rows` (list of lists), `num_rows` (integer), `metadata` (list of maps), `messages`, `query`, `query_id`, `request_id`, `sql_state`. Python connector returns all of this -- we map it in the Port protocol |
| Type decode parity | `Repo.all(User)` must return the same Elixir types whether using Snowflex or SnowflexDev | High | Snowflex's `Type.decode/2` converts: FIXED -> integer/Decimal (based on scale), REAL -> float, TIMESTAMP_NTZ -> NaiveDateTime, TIMESTAMP_LTZ/TZ -> DateTime, DATE -> Date, TIME -> Time, BOOLEAN -> boolean, TEXT -> string. We must match all of these. Python connector returns similar metadata -- map `type_code` to these same Elixir types |
| Ecto loader parity | Snowflex has custom loaders for `:integer`, `:decimal`, `:float`, `:date`, `:time`, `:time_usec`, `:id` | Med | Copy Snowflex's loader implementations verbatim into our adapter module |

### Python Bridge (Erlang Port)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Long-lived Python process | Each DBConnection pool member owns one Python process. The process must stay alive across queries | High | Start Python with `Port.open({:spawn_executable, python_path}, [:binary, :use_stdio, {:line, max_line}])`. Python runs an event loop reading JSON commands from stdin, writing JSON responses to stdout |
| JSON protocol over stdin/stdout | Structured communication between Elixir and Python | Med | Define a simple protocol: `{"id": "uuid", "action": "execute", "sql": "...", "params": [...]}` -> `{"id": "uuid", "status": "ok", "columns": [...], "rows": [...], ...}`. Line-delimited JSON |
| SSO authentication (externalbrowser) | The whole reason this project exists -- browser-based auth with zero setup | Med | Python connector handles this. On first connection, it opens a browser for SSO. Token caching is built into the connector. Config: `authenticator='externalbrowser'` |
| Error propagation | Python errors must become `Snowflex.Error` exceptions in Elixir | Med | Python catches exceptions, serializes as `{"status": "error", "message": "...", "code": "...", "sql_state": "..."}`. Elixir constructs `Snowflex.Error.exception/1` |
| Process crash recovery | Python process dying must not crash the BEAM | Med | Port monitor, catch `{port, {:exit_status, code}}`, return `{:disconnect, error, state}` from any in-flight callback. DBConnection handles reconnection |

### Setup and Configuration

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `mix snowflex_dev.setup` task | Creates Python venv, installs snowflake-connector-python. Zero-friction onboarding | Med | `System.cmd("python3", ["-m", "venv", venv_path])` then `System.cmd(pip_path, ["install", "snowflake-connector-python"])` |
| Config-driven adapter swap | `config :my_app, MyApp.Repo, adapter: SnowflexDev` in dev, `adapter: Snowflex` in prod | Low | Standard Ecto pattern. No code needed -- just documentation |
| Snowflake session parameters | `account`, `warehouse`, `database`, `schema`, `role` from app config | Low | Pass through to Python connector |

## Differentiators

Features that set the product apart. Not expected, but provide competitive advantage.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Zero-admin auth | Unlike Snowflex OAuth (requires ACCOUNTADMIN to create security integration), SnowflexDev works with just a Snowflake username. No admin involvement at all | Low | This is the core value prop. Python's `externalbrowser` authenticator handles everything |
| Automatic venv management | `mix snowflex_dev.setup` creates an isolated Python environment. No "install this globally" instructions | Med | Bundled venv in `_build/` or `priv/python/` |
| Connection health logging | Logger metadata matching Snowflex's pattern (`snowflex_account_name`, `snowflex_warehouse`, etc.) | Low | Copy Snowflex's `set_base_metadata/2` pattern. Consuming apps' log filters work unchanged |
| Telemetry events | Emit the same telemetry events as Snowflex so consuming apps' dashboards/metrics work in dev | Med | Snowflex delegates to `Ecto.Adapters.SQL` which handles telemetry. If we use the same delegation pattern, we get this for free |
| MigrationGenerator compatibility | Snowflex ships a `MigrationGenerator` for creating local test DB schemas from Ecto schemas. Our adapter should work with this module if consuming apps use it | Low | No code needed -- if our adapter implements the same Ecto behaviours, MigrationGenerator works because it talks to `Ecto.Repo`, not the adapter directly |
| Graceful Python version detection | Check Python 3.8+ is available before attempting setup, with clear error messages | Low | `System.cmd("python3", ["--version"])` and parse output |
| Connection pooling | Multiple Python processes in a DBConnection pool, matching Snowflex's pool behaviour | Med | DBConnection handles the pool -- each pool slot gets its own Python process from `connect/1`. Pool size configurable via `:pool_size` (standard DBConnection opt) |

## Anti-Features

Features to explicitly NOT build.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Production use support | SnowflexDev exists solely for local development. Adding production hardening (connection pooling tuning, retry logic, rate limiting) would bloat scope and confuse purpose | Document clearly: "Add as `only: :dev` dependency. Use Snowflex for production" |
| Custom SQL generation | Snowflex has ~900 lines of Snowflake SQL dialect code. Rewriting this would be a massive, error-prone duplication | Reuse Snowflex's `Ecto.Adapter.Connection` module directly (depend on snowflex as a dep, or copy the module) |
| ODBC driver support | Python's native connector is simpler and handles auth internally. ODBC adds system-level dependencies | Use `snowflake-connector-python` exclusively |
| Token management / OAuth flows | Python's `externalbrowser` authenticator handles tokens, caching, and refresh internally. Building our own token layer would duplicate what the connector already does | Let the Python connector manage auth completely |
| Windows support (v1) | Different Python ecosystem, path handling, port behaviour. Adds testing matrix complexity | Target macOS/Linux first. Document as known limitation |
| Transaction support | Snowflake has limited transaction support and Snowflex explicitly rejects transactions. Implementing them would break the "drop-in" contract | Match Snowflex's behaviour: disconnect with error on `handle_begin/commit/rollback` |
| Async query execution | Snowflex's HTTP transport supports async polling for long-running queries. The Port-based approach is inherently synchronous per connection | DBConnection pool handles concurrency. Each Python process handles one query at a time (matches Snowflake's per-session model) |
| Binary/COPY protocol | Snowflake's bulk loading (COPY INTO) uses staged files, not a binary protocol. Python connector supports this but it's outside normal Ecto usage | Out of scope for v1. Normal INSERT/SELECT/UPDATE/DELETE covers dev workflows |
| NIFs or erlport | Higher performance but breaks process isolation. A Python crash in a NIF takes down the BEAM VM | Use Erlang Ports. Process isolation is worth the serialization overhead for a dev tool |

## Feature Dependencies

```
mix snowflex_dev.setup (venv creation)
  --> Python Bridge (Port startup needs venv python)
    --> connect/1 (starts Port)
      --> ping/1 (validates connection)
      --> handle_execute/4 (query execution)
      --> handle_declare/4 (cursor creation)
        --> handle_fetch/4 (cursor fetch)
        --> handle_deallocate/4 (cursor cleanup)

Ecto.Adapter callbacks
  --> Ecto.Adapters.SQL delegation (most callbacks delegate here)
    --> Ecto.Adapters.SQL.Connection callbacks (SQL generation + DBConnection wiring)
      --> DBConnection behaviour callbacks (actual connection management)
        --> Python Bridge (actual query execution)

Result format parity
  --> Type decode logic (must match Snowflex's Type.decode/2 output)
  --> Result struct (must have same fields as Snowflex.Result)

Config-driven swap
  --> All of the above working (adapter must be functionally complete)
```

## MVP Recommendation

Prioritize:

1. **Python Bridge + Port protocol** -- nothing works without the Elixir-Python communication channel. Start here: long-lived Python process, JSON protocol, execute/ping/error commands.

2. **DBConnection behaviour (connect, disconnect, ping, handle_execute, checkout)** -- the minimum to get `DBConnection.execute/4` working. Skip cursors/streaming initially.

3. **Result struct + type decoding** -- query results must match Snowflex's format. This is where "drop-in" lives or dies.

4. **Ecto adapter behaviours + SQL.Connection** -- wire up the Ecto layer by reusing Snowflex's SQL generation. This gives `Repo.all`, `Repo.insert`, etc.

5. **`mix snowflex_dev.setup` task** -- automated venv + pip install. Makes onboarding frictionless.

6. **Streaming (handle_declare/fetch/deallocate)** -- only needed if consuming apps use `Repo.stream`. Can defer until needed.

Defer:
- **Telemetry event parity**: Nice-to-have, not blocking. Ecto.Adapters.SQL delegation gives partial telemetry for free.
- **Connection health logging metadata**: Low complexity but not required for functional parity.
- **Graceful Python version detection**: Polish, not essential.

## Sources

- [Snowflex source code](https://github.com/pepsico-ecommerce/snowflex) -- direct codebase analysis of `lib/snowflex/connection.ex`, `lib/snowflex/query.ex`, `lib/snowflex/result.ex`, `lib/snowflex/transport.ex`, `lib/snowflex/ecto/adapter/connection.ex` -- HIGH confidence
- [DBConnection behaviour (db_connection v2.8.1)](https://hexdocs.pm/db_connection/DBConnection.html) -- callback specifications -- HIGH confidence
- [Ecto.Adapters.SQL.Connection behaviour (Ecto SQL v3.13.4)](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Connection.html) -- required SQL adapter callbacks -- HIGH confidence
- [Ecto.Adapter (Ecto v3.13.5)](https://hexdocs.pm/ecto/Ecto.Adapter.html) -- adapter behaviour callbacks -- HIGH confidence
- [Ecto.Adapters.SQL (Ecto SQL v3.13.5)](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.html) -- delegation patterns for SQL adapters -- HIGH confidence
