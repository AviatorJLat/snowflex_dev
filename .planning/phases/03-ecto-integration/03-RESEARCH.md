# Phase 3: Ecto Integration - Research

**Researched:** 2026-03-26
**Domain:** Ecto adapter behaviours, SQL generation for Snowflake dialect, Ecto type loaders/dumpers
**Confidence:** HIGH

## Summary

Phase 3 builds the Ecto adapter layer on top of the existing DBConnection implementation from Phase 2. The adapter has three major components: (1) the main adapter module implementing `Ecto.Adapter`, `Ecto.Adapter.Queryable`, and `Ecto.Adapter.Schema` behaviours, (2) an `Ecto.Adapters.SQL.Connection` module that bridges Ecto's SQL layer to our DBConnection and generates Snowflake-dialect SQL, and (3) loaders/dumpers that convert between Ecto schema types and the values our TypeDecoder produces.

The critical architectural decision for this phase is whether to copy Snowflex's ~900-line SQL generation module (`Snowflex.Ecto.Adapter.Connection`) or depend on Snowflex as a library. Analysis shows copying is the correct approach: Snowflex is the production adapter we are replacing, so depending on it creates a circular relationship. The SQL generation code is self-contained (no imports from other Snowflex modules) and handles Snowflake-specific dialect (QUALIFY, no RETURNING, no SERIAL, variant types, count(*)::number casting). We copy it, rename the module, and adapt the connection/query plumbing to our SnowflexDev types. The SQL generation itself stays unchanged since it targets the same Snowflake dialect.

The adapter module should NOT use `use Ecto.Adapters.SQL` (the macro approach) because Snowflex does not, and we need exact interface compatibility. Snowflex manually delegates to `Ecto.Adapters.SQL` function calls (e.g., `SQL.init/3`, `SQL.execute/6`, `SQL.struct/10`). We must follow this same pattern for compatibility. The macro approach auto-implements `Ecto.Adapter.Transaction` which we explicitly do not want (Snowflake has no transaction support).

**Primary recommendation:** Copy Snowflex's adapter structure exactly -- a main `SnowflexDev` module delegating to `Ecto.Adapters.SQL` functions, plus `SnowflexDev.Ecto.Adapter.Connection` containing the full SQL generation module adapted for our types. Match Snowflex's loaders/dumpers. This gives consuming apps identical Repo behavior.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ECTO-01 | Implements Ecto.Adapter, Ecto.Adapter.Queryable, and Ecto.Adapter.Schema behaviours | Full callback list documented; Snowflex.ex serves as direct reference; manual delegation to Ecto.Adapters.SQL functions (not `use` macro) |
| ECTO-02 | Reuses Snowflex's SQL generation module (Snowflake dialect) | Copy Snowflex.Ecto.Adapter.Connection (~900 lines), rename module, adapt Query/Connection references to SnowflexDev types |
| ECTO-03 | Loaders and dumpers convert between Elixir types and Snowflake column types | Snowflex loaders documented below; our TypeDecoder already produces the right types, loaders handle edge cases from Ecto side |
| ECTO-04 | Consuming app can use Repo.all/1, Repo.insert/2, Repo.update/2, Repo.delete/2 identically to Snowflex | Full adapter + SQL.Connection + loaders gives Repo operations; parameter binding via `?` placeholders needs Python-side `%s` conversion |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Interface compatibility**: Must implement DBConnection behaviour so Ecto.Repo works without code changes in consuming apps
- **Result format parity**: Query results must match Snowflex's return format exactly
- **ecto version**: `~> 3.12` (matching Snowflex constraint)
- **ecto_sql version**: `~> 3.12` (matching Snowflex constraint)
- **Dev-only dependency**: SnowflexDev should be added as `only: :dev` in consuming apps
- **No transactions**: Snowflake does not support traditional transactions; match Snowflex's disconnect-on-transaction-attempt behaviour
- **Config-only swap**: Consuming apps switch adapters via config, zero code changes

## Standard Stack

### Core (New Dependencies for Phase 3)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `ecto` | `~> 3.12` | Schema/query DSL, Ecto.Adapter behaviour | Required for Ecto.Repo operations. v3.13.5 latest (Mar 2026). Must match Snowflex constraint. |
| `ecto_sql` | `~> 3.12` | SQL adapter integration, Ecto.Adapters.SQL module | v3.13.5 latest (Mar 2026). Provides SQL.init/3, SQL.execute/6, SQL.struct/10 that the adapter delegates to. |

### Already Present
| Library | Version | Purpose |
|---------|---------|---------|
| `db_connection` | `~> 2.7` | Connection pooling + behaviour (Phase 2) |
| `jason` | `~> 1.4` | JSON protocol (Phase 1) |
| `decimal` | `~> 2.0` | Decimal type for FIXED columns (Phase 2) |

**Installation:**
```bash
# Add to mix.exs deps:
{:ecto, "~> 3.12"},
{:ecto_sql, "~> 3.12"}
```

## Architecture Patterns

### Recommended Project Structure (Phase 3 additions)
```
lib/
  snowflex_dev.ex                      # Main Ecto adapter module (NEW)
  snowflex_dev/
    ecto/
      adapter/
        connection.ex                  # Ecto.Adapters.SQL.Connection impl + SQL generation (NEW)
        stream.ex                      # Enumerable/Collectable stream wrapper (NEW)
    connection.ex                      # DBConnection impl (Phase 2, unchanged)
    query.ex                           # Query struct (Phase 2, minor update)
    result.ex                          # Result struct (Phase 2, unchanged)
    type_decoder.ex                    # Type decoder (Phase 2, unchanged)
    transport.ex                       # Transport behaviour (Phase 1, unchanged)
    transport/port.ex                  # Transport GenServer (Phase 1, unchanged)
    protocol.ex                        # Port protocol (Phase 1, unchanged)
    error.ex                           # Error struct (Phase 1, unchanged)
    application.ex                     # Application supervisor (existing)
```

### Pattern 1: Manual Delegation to Ecto.Adapters.SQL

**What:** The main adapter module declares Ecto behaviours and delegates to `Ecto.Adapters.SQL` module functions rather than using the `use` macro.

**Why this pattern:** Snowflex uses this approach, and we must match its interface exactly. The `use Ecto.Adapters.SQL` macro auto-implements `Ecto.Adapter.Transaction`, which we do NOT want. Manual delegation gives precise control over which behaviours are implemented.

```elixir
defmodule SnowflexDev do
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Schema

  alias Ecto.Adapters.SQL

  @conn __MODULE__.Ecto.Adapter.Connection

  @impl Ecto.Adapter
  defmacro __before_compile__(env) do
    SQL.__before_compile__(:snowflex_dev, env)
  end

  @impl Ecto.Adapter
  def ensure_all_started(config, type) do
    SQL.ensure_all_started(:snowflex_dev, config, type)
  end

  @impl Ecto.Adapter
  def init(config) do
    SQL.init(@conn, :snowflex_dev, config)
  end

  # ... remaining callbacks delegate similarly
end
```

**Key insight:** The `:snowflex_dev` atom passed to SQL functions is the OTP application name. `@conn` points to the SQL.Connection implementation module.

### Pattern 2: SQL.Connection with Snowflake SQL Generation

**What:** A module implementing `Ecto.Adapters.SQL.Connection` that provides both the DBConnection bridge (child_spec, prepare_execute, query) and SQL generation (all, insert, update, delete, etc.).

**Why:** This is where Ecto asks "how do I build a SELECT for this query?" and "how do I talk to the database?". The SQL generation portion is Snowflake-dialect-specific and is copied from Snowflex.

```elixir
defmodule SnowflexDev.Ecto.Adapter.Connection do
  @behaviour Ecto.Adapters.SQL.Connection

  @impl true
  def child_spec(opts) do
    DBConnection.child_spec(SnowflexDev.Connection, opts)
  end

  @impl true
  def prepare_execute(connection, name, statement, params, opts) do
    query = %SnowflexDev.Query{name: name, statement: statement}
    DBConnection.prepare_execute(connection, query, params, opts)
  end

  @impl true
  def query(conn, sql, params, opts) do
    query = %SnowflexDev.Query{statement: sql}
    case DBConnection.execute(conn, query, params, opts) do
      {:ok, _query, result} -> {:ok, result}
      any -> any
    end
  end

  # ... plus all SQL generation functions (all/1, insert/7, update/5, delete/4, etc.)
end
```

### Pattern 3: Loaders and Dumpers

**What:** Type conversion callbacks on the adapter module that tell Ecto how to convert between database values and Elixir types.

**Loaders** (DB -> Elixir): Called AFTER our TypeDecoder has already converted raw Python values. They handle edge cases where Ecto needs further normalization.

**Dumpers** (Elixir -> DB): Called BEFORE sending values as parameters. Handle encoding Elixir values for Snowflake.

```elixir
# In SnowflexDev main module:

@impl Ecto.Adapter
def loaders(:integer, type), do: [&int_decode/1, type]
def loaders(:decimal, type), do: [&decimal_decode/1, type]
def loaders(:float, type), do: [&float_decode/1, type]
def loaders(:date, type), do: [&date_decode/1, type]
def loaders(:id, type), do: [&int_decode/1, type]
def loaders(:time, type), do: [&time_decode/1, type]
def loaders(:time_usec, type), do: [&time_decode/1, type]
def loaders(_, type), do: [type]

@impl Ecto.Adapter
def dumpers(:binary, type), do: [type, &binary_encode/1]
def dumpers(_, type), do: [type]
```

**Key insight:** Snowflex's loaders handle cases where values may still be strings (from the HTTP/REST transport). Our TypeDecoder already converts to proper types in Phase 2, but loaders must still handle edge cases for robustness -- and they MUST match Snowflex's loader definitions for compatibility.

### Pattern 4: Stream Implementation (Enumerable + Collectable)

**What:** A struct implementing Enumerable and Collectable protocols for Ecto's streaming query support.

```elixir
defmodule SnowflexDev.Ecto.Adapter.Stream do
  defstruct [:meta, :statement, :params, :opts]

  def build(meta, statement, params, opts) do
    %__MODULE__{meta: meta, statement: statement, params: params, opts: opts}
  end
end

defimpl Enumerable, for: SnowflexDev.Ecto.Adapter.Stream do
  def reduce(stream, acc, fun) do
    SnowflexDev.reduce(stream.meta, stream.statement, stream.params, stream.opts, acc, fun)
  end
  # count/1, member?/2, slice/1 return {:error, __MODULE__}
end
```

### Anti-Patterns to Avoid

- **Using `use Ecto.Adapters.SQL`**: This auto-implements Transaction behaviour which Snowflake does not support. Snowflex uses manual delegation -- we must too.
- **Modifying the SQL generation logic**: The ~900 line SQL module generates valid Snowflake dialect. Do NOT modify the SQL output -- only change module references and imports.
- **Adding RETURNING support**: Snowflake does not support RETURNING clauses. Snowflex explicitly errors on this. Do not attempt to add it.
- **Custom parameter binding**: Ecto generates SQL with `?` placeholders. The Python connector expects `%s` (pyformat) or positional params. Convert at the transport boundary, not in SQL generation.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SQL generation for Snowflake | Custom SQL builder | Copy Snowflex.Ecto.Adapter.Connection | 900+ lines covering CTEs, QUALIFY, window functions, joins, subqueries, type casts, combination queries. Battle-tested. |
| Ecto adapter boilerplate | Manual callback implementations | Delegate to `Ecto.Adapters.SQL` module functions | SQL.init/3, SQL.execute/6, SQL.struct/10, SQL.insert_all/9 handle caching, telemetry, error conversion |
| Result -> Ecto row mapping | Custom row transformer | Ecto.Adapters.SQL handles this | SQL.execute returns rows in the format Ecto.Repo expects |
| Query caching | Custom cache | Ecto.Adapters.SQL prepare/execute flow | Built-in query plan caching with unique integer IDs |

## Common Pitfalls

### Pitfall 1: Parameter Placeholder Mismatch
**What goes wrong:** Ecto's SQL generation produces `?` as parameter placeholders. The Snowflake Python connector uses `%s` (pyformat) by default. Queries with parameters fail with syntax errors.
**Why it happens:** Different databases use different placeholder styles. MySQL uses `?`, Postgres uses `$1`, Python DB-API uses `%s`.
**How to avoid:** In the Python worker, convert `?` placeholders to `%s` before executing, OR set `snowflake.connector.paramstyle = 'qmark'` globally at worker startup. The qmark approach is simpler and avoids string manipulation.
**Warning signs:** "Syntax error" from Snowflake on any parameterized query.

### Pitfall 2: Ecto.Adapters.SQL.execute Expects Specific Result Shape
**What goes wrong:** `Ecto.Adapters.SQL.execute/6` and `SQL.struct/10` expect results with specific fields: `columns`, `rows`, `num_rows`. If the Result struct shape doesn't match, Ecto crashes internally.
**Why it happens:** Ecto.Adapters.SQL accesses result struct fields directly.
**How to avoid:** Our Result struct already has these fields from Phase 2. Verify that the DBConnection.Query.decode protocol produces results in the expected shape. The Result struct needs `%{columns: [...], rows: [[...]], num_rows: N}`.
**Warning signs:** KeyError or MatchError deep in Ecto.Adapters.SQL code.

### Pitfall 3: Query.new vs Query Struct Literal
**What goes wrong:** Snowflex uses `Query.new(statement: ...)` constructor function. Our Phase 2 Query uses struct literals `%Query{statement: ...}`. The SQL.Connection module must use whichever approach the Query module provides.
**Why it happens:** Snowflex.Query has a `new/1` constructor; our SnowflexDev.Query uses defstruct directly.
**How to avoid:** Either add a `new/1` constructor to SnowflexDev.Query or use struct literals in the Connection module. Struct literals are simpler and idiomatic.
**Warning signs:** UndefinedFunctionError on `SnowflexDev.Query.new/1`.

### Pitfall 4: Module Naming for @conn Reference
**What goes wrong:** The adapter uses `@conn __MODULE__.Ecto.Adapter.Connection` which expands to `SnowflexDev.Ecto.Adapter.Connection`. If the file is placed in the wrong path or the module name doesn't match, compilation fails.
**Why it happens:** Elixir module names must match file paths by convention.
**How to avoid:** File at `lib/snowflex_dev/ecto/adapter/connection.ex`, module name `SnowflexDev.Ecto.Adapter.Connection`. Double-check the `@conn` attribute resolves correctly.
**Warning signs:** Compilation errors about missing module.

### Pitfall 5: execute(:named, ...) Parameter Binding Mode
**What goes wrong:** Snowflex calls `SQL.execute(:named, adapter_meta, query_meta, query, params, opts)`. The `:named` atom is the parameter binding mode. If we use the wrong mode, parameters are not substituted correctly.
**Why it happens:** Ecto.Adapters.SQL supports different parameter binding modes for different databases.
**How to avoid:** Use `:named` exactly as Snowflex does. This tells Ecto.Adapters.SQL to use named parameter binding style, which works with `?` placeholder SQL.
**Warning signs:** Parameters not being substituted in queries, or wrong parameter order.

### Pitfall 6: insert/6 Returning Clause
**What goes wrong:** Snowflake does not support RETURNING in INSERT/UPDATE/DELETE. If Ecto tries to use returning clauses, the SQL generation must error explicitly.
**Why it happens:** Ecto.Adapter.Schema callbacks receive `returning` parameter. Some schemas expect auto-generated IDs to be returned.
**How to avoid:** The copied SQL generation already errors on RETURNING clauses. For autogeneration, `autogenerate(:id)` returns `nil` (no auto-increment in Snowflake). `autogenerate(:embed_id)` and `autogenerate(:binary_id)` generate UUIDs client-side.
**Warning signs:** "RETURNING is not supported" errors when using schemas with auto-generated IDs.

### Pitfall 7: Existing lib/snowflex_dev.ex Module Name Conflict
**What goes wrong:** The main Ecto adapter module is `SnowflexDev` (in `lib/snowflex_dev.ex`). If a `lib/snowflex_dev.ex` already exists with `SnowflexDev.Application` or other content, there's a conflict.
**Why it happens:** Elixir convention maps `SnowflexDev` to `lib/snowflex_dev.ex`.
**How to avoid:** Check current `lib/snowflex_dev.ex` contents. It likely doesn't exist or is minimal. The adapter becomes the main module. `SnowflexDev.Application` stays in `lib/snowflex_dev/application.ex`.
**Warning signs:** Module redefinition warnings at compile time.

## Code Examples

### Complete Adapter Module Structure (from Snowflex reference)

The main adapter module implements these Ecto callbacks:

```elixir
# Ecto.Adapter callbacks:
__before_compile__/1  -> SQL.__before_compile__(:snowflex_dev, env)
ensure_all_started/2  -> SQL.ensure_all_started(:snowflex_dev, config, type)
init/1                -> SQL.init(@conn, :snowflex_dev, config)
checkout/3            -> SQL.checkout(meta, opts, fun)
checked_out?/1        -> SQL.checked_out?(meta)
loaders/2             -> type-specific decode pipelines
dumpers/2             -> type-specific encode pipelines

# Ecto.Adapter.Queryable callbacks:
prepare/2             -> {:cache, {unique_id, IO.iodata_to_binary(@conn.all/update_all/delete_all(query))}}
execute/5             -> SQL.execute(:named, adapter_meta, query_meta, query, params, opts)
stream/5              -> builds AdapterStream struct

# Ecto.Adapter.Schema callbacks:
autogenerate/1        -> nil for :id, UUID.generate() for :embed_id, UUID.bingenerate() for :binary_id
insert_all/8          -> SQL.insert_all(adapter_meta, schema_meta, @conn, ...)
insert/6              -> SQL.struct(adapter_meta, @conn, sql, :insert, ...)
update/6              -> SQL.struct(adapter_meta, @conn, sql, :update, ...)
delete/5              -> SQL.struct(adapter_meta, @conn, sql, :delete, ...)
```

### SQL.Connection Required Callbacks

```elixir
# Connection management (bridge to DBConnection):
child_spec/1          -> DBConnection.child_spec(SnowflexDev.Connection, opts)
prepare_execute/5     -> DBConnection.prepare_execute(conn, query, params, opts)
query/4               -> DBConnection.execute(conn, query, params, opts)
query_many/4          -> wraps query/4 in List.wrap
execute/4             -> DBConnection.execute(conn, query, params, opts)
stream/4              -> DBConnection.prepare_stream(conn, query, params, opts)

# SQL generation (Snowflake dialect -- copied from Snowflex):
all/1                 -> SELECT statement from Ecto.Query
update_all/1          -> UPDATE statement from Ecto.Query
delete_all/1          -> DELETE statement from Ecto.Query
insert/7              -> INSERT statement
update/5              -> UPDATE statement
delete/4              -> DELETE statement

# Utility:
explain_query/4       -> EXPLAIN query
to_constraints/2      -> error -> constraint mapping
table_exists_query/1  -> information_schema query
ddl_logs/1            -> raise "not yet implemented"
execute_ddl/1         -> raise "not yet implemented"
```

### Snowflex Loader Functions (to replicate exactly)

```elixir
defp decimal_decode(nil), do: {:ok, nil}
defp decimal_decode(dec) when is_binary(dec), do: {:ok, Decimal.new(dec)}
defp decimal_decode(dec) when is_float(dec), do: {:ok, Decimal.from_float(dec)}

defp int_decode(nil), do: {:ok, nil}
defp int_decode(int) when is_binary(int), do: {:ok, String.to_integer(int)}
defp int_decode(int), do: {:ok, int}

defp time_decode(nil), do: {:ok, nil}
defp time_decode(time), do: Time.from_iso8601(time)

defp float_decode(nil), do: {:ok, nil}
defp float_decode(float) when is_float(float), do: float  # NOTE: missing {:ok, ...} wrapper
defp float_decode(%Decimal{} = decimal), do: {:ok, Decimal.to_float(decimal)}
defp float_decode(float) do
  {val, _} = Float.parse(float)
  {:ok, val}
end

defp date_decode(nil), do: {:ok, nil}
defp date_decode(%Date{} = date), do: {:ok, date}
defp date_decode(date), do: Date.from_iso8601(date)

defp binary_encode(raw), do: {:ok, Base.encode16(raw)}
```

### Parameter Placeholder Fix in Python Worker

```python
# At top of worker, set paramstyle for Snowflake connector:
import snowflake.connector
snowflake.connector.paramstyle = 'qmark'

# This makes cursor.execute(sql, params) accept ? placeholders
# instead of the default %s (pyformat) style.
# Ecto's SQL generation produces ? placeholders.
```

Source: Snowflake Python connector docs -- paramstyle configuration.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Ecto 2.x adapter callbacks | Ecto 3.x adapter callbacks with SQL module delegation | ecto 3.0 | Different callback arities, SQL module helper functions |
| `Ecto.Adapters.SQL.Connection.stream/4` optional | `stream/4` required callback | ecto_sql 3.10+ | Must implement even if basic |
| No `query_many/4` | `query_many/4` required | ecto_sql 3.11+ | Must implement (can wrap query/4) |
| No `explain_query/4` | `explain_query/4` required | ecto_sql 3.x | Must implement |

## Open Questions

1. **Python paramstyle: qmark vs manual conversion**
   - What we know: Snowflake Python connector defaults to `pyformat` (`%s`). Setting `snowflake.connector.paramstyle = 'qmark'` enables `?` placeholder support.
   - What's unclear: Whether setting paramstyle globally has side effects on the Snowflake connector's internal behavior.
   - Recommendation: Use `paramstyle = 'qmark'` -- it's documented and supported. Test with parameterized queries.

2. **SQL.execute parameter binding mode**
   - What we know: Snowflex uses `SQL.execute(:named, ...)`. The first atom controls how Ecto.Adapters.SQL binds parameters.
   - What's unclear: Whether `:named` is correct for `?` placeholder SQL, or whether `:positional` would be better.
   - Recommendation: Copy Snowflex's `:named` exactly. It works with `?` placeholders.

3. **Telemetry events**
   - What we know: Snowflex implements custom `log/4` and telemetry event emission. REQUIREMENTS.md defers telemetry to v2.
   - What's unclear: Whether Ecto.Adapters.SQL.execute handles basic telemetry automatically.
   - Recommendation: For Phase 3, rely on Ecto.Adapters.SQL's built-in telemetry. Copy Snowflex's `log/4` function for query logging compatibility. Full custom telemetry is v2 scope.

4. **Snowflex float_decode bug**
   - What we know: Snowflex's `float_decode/1` when matching `float when is_float(float)` returns `float` bare instead of `{:ok, float}`. This is inconsistent with the loader contract.
   - What's unclear: Whether this is a bug that works by accident or intentional.
   - Recommendation: Fix in our implementation -- return `{:ok, float}` consistently. This is a minor incompatibility that should not affect consuming apps.

## Sources

### Primary (HIGH confidence)
- Snowflex source (pepsico-ecommerce/snowflex) -- `lib/snowflex.ex` (main adapter, all callbacks), `lib/snowflex/ecto/adapter/connection.ex` (SQL.Connection + SQL generation, ~900 lines), `lib/snowflex/ecto/adapter/stream.ex` (streaming)
- hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.html -- Module function API (init/3, execute/6, struct/10)
- hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Connection.html -- All 17 required callback signatures
- hexdocs.pm/ecto/Ecto.Adapter.html -- Ecto.Adapter, Ecto.Adapter.Queryable, Ecto.Adapter.Schema behaviour docs
- dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iv-ecto-integration -- Ecto adapter implementation guide

### Secondary (MEDIUM confidence)
- Snowflake Python connector docs -- paramstyle configuration for qmark placeholder support
- hex.pm/packages/ecto_sql v3.13.5 (Mar 2026) -- version confirmation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- ecto and ecto_sql versions confirmed from hex.pm, matching Snowflex constraints
- Architecture: HIGH -- Snowflex source code directly analyzed, all callbacks mapped, SQL generation module reviewed line-by-line
- Loaders/dumpers: HIGH -- Snowflex loader implementations captured verbatim from source
- SQL generation: HIGH -- Snowflex's 900-line module reviewed, all Snowflake dialect specifics documented
- Parameter binding: MEDIUM -- qmark paramstyle approach documented in Snowflake connector, but needs integration testing
- Pitfalls: HIGH -- identified from real code analysis (paramstyle mismatch, module naming, RETURNING limitation)

**Research date:** 2026-03-26
**Valid until:** 2026-04-26 (stable domain -- Ecto adapter interfaces change infrequently)
