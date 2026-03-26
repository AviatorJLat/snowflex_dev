# Phase 2: DBConnection Adapter - Research

**Researched:** 2026-03-26
**Domain:** Elixir DBConnection behaviour implementation, Snowflake type mapping
**Confidence:** HIGH

## Summary

Phase 2 wraps the existing Transport.Port layer in a DBConnection behaviour implementation, adds a Query struct matching Snowflex.Query, extends the Result struct for full Snowflex.Result parity, and implements Snowflake-to-Elixir type decoding. The Python worker needs a minor enhancement to include `query_id` (from `cursor.sfqid`) and column type codes in its response payload.

The DBConnection behaviour is well-documented with clear callback contracts. Snowflex's own Connection.ex serves as a direct reference implementation -- most callbacks are thin wrappers around Transport calls, and transaction callbacks all return `{:disconnect, error, state}` since Snowflake does not support transactions. Crash recovery comes for free from DBConnection's pool: returning `{:disconnect, exception, state}` from any callback tells the pool the connection is dead, triggering `disconnect/2` then `connect/2` to create a fresh slot.

The type decoding challenge is moderate. The Python connector returns raw values with `cursor.description` providing type_code integers (0=FIXED, 1=REAL, 2=TEXT, etc.). The worker currently includes these type codes in metadata. Elixir-side decoding maps these codes to Elixir types, matching Snowflex's HTTP transport type module behavior. Key difference: Snowflex decodes from JSON strings (REST API), while we decode from Python's native serialization via `json.dumps(default=str)` -- meaning Decimals arrive as string representations, datetimes as ISO8601 strings, etc.

**Primary recommendation:** Implement DBConnection callbacks as thin wrappers around Transport.Port, add query_id/sfqid to Python worker responses, and build a TypeDecoder module that maps Snowflake type_code integers to Elixir types from the string representations Python's json.dumps produces.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** SnowflexDev.Result must have exact field parity with Snowflex.Result -- all the same fields. Fields that can't be populated from the Python connector (e.g., request_id from REST API) default to nil.
- **D-02:** Current Result struct (columns, rows, num_rows, metadata) needs extending with: query, query_id, request_id, sql_state, messages.
- **D-03:** Split decoding at the Python/Elixir boundary. Python returns raw JSON with type metadata from cursor.description (column types). Elixir maps those types to proper Elixir equivalents (FIXED->Decimal, REAL->float, TIMESTAMP_NTZ->NaiveDateTime, TIMESTAMP_LTZ/TZ->DateTime, DATE->Date, TIME->Time, BOOLEAN->boolean, VARCHAR->String).
- **D-04:** The Python worker needs to include column type information in its response payload so Elixir can do type-aware conversion.
- **D-05:** No custom restart logic. DBConnection's pool handles reconnection naturally -- when checkout/ping fails, pool calls disconnect/2 then connect/2 to create a fresh Transport.Port. The adapter just needs correct connect/disconnect implementations.
- **D-06:** Port crash during a query returns {:disconnect, error, state} from handle_execute so DBConnection knows the connection is dead.
- **D-07:** 1:1 mapping -- each DBConnection pool slot owns one Transport.Port process. This follows the architecture decision in CLAUDE.md.
- **D-08:** checkout/checkin are effectively no-ops since the Transport.Port connection is always ready. The GenServer IS the connection.

### Claude's Discretion
- Query struct design internals (field naming, helper functions) -- follow Snowflex.Query patterns
- Internal state struct design for the DBConnection module
- Test structure and mock strategy for unit tests

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DBC-01 | Implements DBConnection behaviour with connect/2, disconnect/2, checkout/1, checkin/1, ping/1, handle_execute/4 callbacks | Full callback contract documented below; Snowflex Connection.ex provides reference implementation pattern |
| DBC-02 | Query struct matches Snowflex.Query fields and behaviour | Snowflex.Query has 4 fields (statement, transport, name, cache) + DBConnection.Query protocol; we mirror all except transport |
| DBC-03 | Result struct matches Snowflex.Result (columns, rows, num_rows, metadata, messages, query, query_id, request_id, sql_state) | Full field list confirmed from Snowflex source; existing Result needs 5 new fields |
| DBC-04 | Type decoding maps Python connector types to identical Elixir types as Snowflex | Complete type_code mapping (0-20) documented; Snowflex Type.ex decoding patterns captured |
| DBC-05 | Port crash recovery -- Python process failure triggers clean reconnect without crashing the BEAM supervision tree | DBConnection pool handles this via disconnect/connect cycle; adapter returns {:disconnect, exception, state} on port failure |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Interface compatibility**: Must implement DBConnection behaviour so Ecto.Repo works without code changes
- **No BEAM instability**: Python process failures must not crash the Elixir supervision tree
- **Result format parity**: Query results must match Snowflex's return format exactly
- **IPC**: Erlang Port with `{:packet, 4}` JSON protocol (already implemented in Phase 1)
- **1 Port per pool slot**: Each DBConnection pool slot owns one Transport.Port process
- **db_connection version**: `~> 2.7`
- **ecto version**: `~> 3.12` (needed for Ecto type definitions used in decoding)

## Standard Stack

### Core (New Dependencies for Phase 2)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `db_connection` | `~> 2.7` | Connection pooling + behaviour contract | Required by requirements. v2.9.0 latest. Must match ecto_sql compatibility. |
| `decimal` | `~> 2.0` | Decimal type for FIXED/NUMBER columns | Snowflex returns FIXED as Decimal. Transitive dep of ecto, but needed directly for type decoding. |

### Already Present
| Library | Version | Purpose |
|---------|---------|---------|
| `jason` | `~> 1.4` | JSON encode/decode for Port protocol |

### Not Yet Needed (Phase 3)
| Library | Purpose | When |
|---------|---------|------|
| `ecto` | Schema/query DSL | Phase 3: Ecto Integration |
| `ecto_sql` | SQL adapter integration | Phase 3: Ecto Integration |

**Installation:**
```bash
# Add to mix.exs deps:
{:db_connection, "~> 2.7"},
{:decimal, "~> 2.0"}
```

## Architecture Patterns

### Recommended Project Structure (Phase 2 additions)
```
lib/snowflex_dev/
  connection.ex         # DBConnection behaviour implementation (NEW)
  query.ex              # Query struct + DBConnection.Query protocol (NEW)
  result.ex             # Extended Result struct (MODIFY)
  type_decoder.ex       # Snowflake type_code -> Elixir type mapping (NEW)
  error.ex              # Already exists
  protocol.ex           # Already exists
  transport.ex          # Already exists
  transport/
    port.ex             # Already exists

priv/python/
  snowflex_dev_worker.py  # Add query_id + type_code to responses (MODIFY)
```

### Pattern 1: DBConnection Behaviour Implementation
**What:** A module that implements all required DBConnection callbacks, delegating actual work to Transport.Port.
**When to use:** This IS the phase -- the central module.

The state struct holds a reference to the Transport.Port pid and connection options:

```elixir
defmodule SnowflexDev.Connection do
  @behaviour DBConnection

  defstruct [:transport_pid, :opts]

  @impl DBConnection
  def connect(opts) do
    case SnowflexDev.Transport.Port.start_link(opts) do
      {:ok, pid} -> {:ok, %__MODULE__{transport_pid: pid, opts: opts}}
      {:error, reason} -> {:error, wrap_error(reason)}
    end
  end

  @impl DBConnection
  def disconnect(_error, state) do
    SnowflexDev.Transport.Port.disconnect(state.transport_pid)
    :ok
  end

  @impl DBConnection
  def checkout(state), do: {:ok, state}

  @impl DBConnection
  def checkin(state), do: {:ok, state}

  @impl DBConnection
  def ping(state) do
    case SnowflexDev.Transport.Port.ping(state.transport_pid) do
      :ok -> {:ok, state}
      {:error, error} -> {:disconnect, error, state}
    end
  end

  @impl DBConnection
  def handle_execute(query, params, opts, state) do
    case SnowflexDev.Transport.Port.execute(
           state.transport_pid, query.statement, params, opts) do
      {:ok, result} ->
        decoded_result = decode_result(result, query)
        {:ok, query, decoded_result, state}
      {:error, %SnowflexDev.Error{code: "SNOWFLEX_DEV_EXIT"} = error} ->
        {:disconnect, error, state}
      {:error, error} ->
        {:error, error, state}
    end
  end

  # Transaction callbacks -- Snowflake does not support transactions
  @impl DBConnection
  def handle_begin(_opts, state) do
    {:disconnect, %SnowflexDev.Error{message: "SnowflexDev does not support transactions"}, state}
  end
  # ... same for handle_commit, handle_rollback

  @impl DBConnection
  def handle_status(_opts, state), do: {:idle, state}
end
```

**Key insight:** The Transport.Port GenServer already handles the full lifecycle (open port, send commands, receive responses, detect crashes). The DBConnection module is a thin translation layer that maps DBConnection's callback contract onto Transport's API.

### Pattern 2: DBConnection.Query Protocol
**What:** Query struct implementing the DBConnection.Query protocol for encode/decode hooks.
**When to use:** Required by DBConnection for all query operations.

```elixir
defmodule SnowflexDev.Query do
  defstruct [:statement, :name, :cache, :columns, :column_types]

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query
    def describe(query, _opts), do: query
    def encode(query, params, _opts), do: params
    def decode(query, result, _opts) do
      SnowflexDev.TypeDecoder.decode_result(result)
    end
  end
end
```

**Key points:**
- `parse/2` and `describe/2` are pass-throughs (no preparation step needed)
- `encode/3` passes params through (Python handles parameter binding)
- `decode/3` is where Snowflake type -> Elixir type conversion happens
- Snowflex.Query has fields: `statement`, `transport`, `name`, `cache`. We mirror `statement`, `name`, `cache` but replace `transport` since we don't need it (our transport is always Port)

### Pattern 3: Type Decoding at the Elixir Boundary
**What:** Decode Python's JSON string representations into proper Elixir types using column type metadata.
**When to use:** In DBConnection.Query.decode/3, after receiving results from Transport.Port.

The Python worker uses `json.dumps(default=str)` which converts:
- `Decimal` -> string like `"123.45"`
- `datetime` -> string like `"2024-01-15 10:30:00"`
- `date` -> string like `"2024-01-15"`
- `time` -> string like `"10:30:00"`
- `bool` -> JSON `true`/`false`
- `None` -> JSON `null`
- `int` -> JSON number
- `float` -> JSON number

The metadata from `cursor.description` provides `type_code` per column, which we use to know HOW to decode each string value.

### Anti-Patterns to Avoid
- **Decoding in Python:** Don't convert types in Python -- keep the boundary clean. Python sends raw strings, Elixir decodes using type metadata. This matches decision D-03.
- **Custom pool/restart logic:** Don't build reconnection logic -- DBConnection's pool handles it. This matches decision D-05.
- **Blocking in connect/2:** Transport.Port.start_link already blocks during SSO auth in init/1. This is fine -- DBConnection expects connect/2 to block until ready.
- **Storing transport module in Query:** Snowflex stores `:transport` in Query because it supports multiple transports. We only have Port, so this field is unnecessary clutter. Match field names but keep transport out of Query.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Connection pooling | Custom GenServer pool | DBConnection's built-in pool | Handles checkout/checkin/timeout/queue/reconnect automatically |
| Crash recovery | Supervisor restart logic | DBConnection disconnect/connect cycle | Pool detects dead connections, replaces them. D-05 decision. |
| Decimal parsing | Custom string-to-decimal | `Decimal.new/1` | Handles all edge cases, precision, rounding modes |
| DateTime parsing | Custom string parser | `NaiveDateTime.from_iso8601!/1`, `DateTime.from_iso8601/1` | Standard library, handles all ISO8601 variants |

## Common Pitfalls

### Pitfall 1: Transport.Port crash detection timing
**What goes wrong:** Port exits during a GenServer.call. The caller gets `{:error, %Error{code: "SNOWFLEX_DEV_EXIT"}}` from the Transport layer. If handle_execute returns `{:error, ...}` instead of `{:disconnect, ...}`, DBConnection thinks the connection is still alive and tries to reuse it.
**Why it happens:** Easy to forget the distinction between recoverable errors (bad SQL) and fatal errors (port crash).
**How to avoid:** In handle_execute, pattern match on error code. `"SNOWFLEX_DEV_EXIT"` always returns `{:disconnect, exception, state}`. Snowflake SQL errors return `{:error, exception, state}`.
**Warning signs:** Pool exhaustion after a Python crash -- all slots stuck in "dead but not disconnected" state.

### Pitfall 2: Transport.Port GenServer dying before disconnect/2
**What goes wrong:** If Transport.Port's GenServer has already stopped (port exit triggers `{:stop, ...}`), calling `Transport.Port.disconnect(pid)` in DBConnection's `disconnect/2` callback will fail with an exit.
**Why it happens:** Port exit -> Transport.Port stops -> DBConnection calls disconnect/2 -> GenServer.call to dead process.
**How to avoid:** The existing `disconnect/2` in Transport.Port already catches `:exit`. But the DBConnection disconnect/2 should also handle the case gracefully -- if the transport pid is already dead, just return `:ok`.
**Warning signs:** Log noise about failed disconnect calls.

### Pitfall 3: Python json.dumps(default=str) losing type information
**What goes wrong:** `default=str` converts everything to strings uniformly. A Decimal `123` becomes `"123"` (string), same as a VARCHAR `"123"`. Without type metadata, you cannot distinguish them.
**Why it happens:** JSON has no Decimal type. Python's json module falls back to `str()` for non-serializable types.
**How to avoid:** Decision D-04 handles this -- the metadata dict from `cursor.description` includes type_code per column. The TypeDecoder uses this to know what each column value actually IS.
**Warning signs:** All numeric values arriving as strings in Elixir results.

### Pitfall 4: Result struct field defaults
**What goes wrong:** New fields (query_id, request_id, sql_state, messages) default to nil, but Snowflex defaults messages to `[]` and metadata to `[]`.
**Why it happens:** Different defaults between implementations.
**How to avoid:** Match Snowflex's defaults exactly: `messages: []`, `metadata: []`. Check Snowflex source for each field's default.
**Warning signs:** Pattern match failures in consuming code that expects `[]` not `nil`.

### Pitfall 5: query_id not available in current Python worker
**What goes wrong:** The Python worker currently does not include `cursor.sfqid` in its response. Result.query_id will always be nil.
**Why it happens:** Phase 1 did not anticipate this field requirement.
**How to avoid:** Modify the Python worker to include `"query_id": cursor.sfqid` in execute response payloads. This is a small change to `execute_query()`.
**Warning signs:** query_id always nil when it should have a value.

### Pitfall 6: Snowflake TIMESTAMP_NTZ vs TIMESTAMP_LTZ vs TIMESTAMP_TZ confusion
**What goes wrong:** Three different timestamp types with different semantics. TIMESTAMP_NTZ has no timezone (-> NaiveDateTime), TIMESTAMP_LTZ is local timezone (-> DateTime with UTC), TIMESTAMP_TZ has explicit timezone (-> DateTime).
**Why it happens:** Snowflake has more granular timestamp types than most databases.
**How to avoid:** Map type_codes precisely: 4 (TIMESTAMP) and 8 (TIMESTAMP_NTZ) -> NaiveDateTime; 6 (TIMESTAMP_LTZ) and 7 (TIMESTAMP_TZ) -> DateTime. Match Snowflex's Type.decode behavior.
**Warning signs:** Timezone data lost or incorrect DateTime structs.

## Code Examples

### Snowflake Type Code -> Elixir Type Mapping

Based on Python connector's `constants.py` FIELD_TYPES (indices 0-20):

```elixir
defmodule SnowflexDev.TypeDecoder do
  @moduledoc "Decodes Python JSON values into Elixir types using Snowflake type_code metadata."

  # Snowflake type codes from snowflake-connector-python constants.py
  @type_fixed 0
  @type_real 1
  @type_text 2
  @type_date 3
  @type_timestamp 4
  @type_variant 5
  @type_timestamp_ltz 6
  @type_timestamp_tz 7
  @type_timestamp_ntz 8
  @type_object 9
  @type_array 10
  @type_binary 11
  @type_time 12
  @type_boolean 13

  def decode_value(nil, _type_code, _meta), do: nil

  def decode_value(value, @type_fixed, %{"scale" => scale}) when scale > 0 do
    Decimal.new(to_string(value))
  end

  def decode_value(value, @type_fixed, _meta) when is_integer(value), do: value
  def decode_value(value, @type_fixed, _meta), do: String.to_integer(to_string(value))

  def decode_value(value, @type_real, _meta) when is_float(value), do: value
  def decode_value(value, @type_real, _meta), do: String.to_float(to_string(value))

  def decode_value(value, @type_text, _meta), do: to_string(value)

  def decode_value(value, @type_date, _meta) do
    value |> to_string() |> Date.from_iso8601!()
  end

  # TIMESTAMP and TIMESTAMP_NTZ -> NaiveDateTime
  def decode_value(value, type_code, _meta)
      when type_code in [@type_timestamp, @type_timestamp_ntz] do
    value |> to_string() |> NaiveDateTime.from_iso8601!()
  end

  # TIMESTAMP_LTZ and TIMESTAMP_TZ -> DateTime
  def decode_value(value, type_code, _meta)
      when type_code in [@type_timestamp_ltz, @type_timestamp_tz] do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _offset} -> dt
      {:error, _} ->
        # Fallback: if no timezone info, assume UTC
        value |> to_string() |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    end
  end

  def decode_value(value, @type_time, _meta) do
    value |> to_string() |> Time.from_iso8601!()
  end

  def decode_value(true, @type_boolean, _meta), do: true
  def decode_value(false, @type_boolean, _meta), do: false
  def decode_value("true", @type_boolean, _meta), do: true
  def decode_value("false", @type_boolean, _meta), do: false

  # VARIANT, OBJECT, ARRAY -> pass through as-is (already decoded from JSON)
  def decode_value(value, type_code, _meta)
      when type_code in [@type_variant, @type_object, @type_array] do
    value
  end

  # BINARY -> base64 decode if string
  def decode_value(value, @type_binary, _meta) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  # Fallback: return as-is
  def decode_value(value, _type_code, _meta), do: value
end
```

Source: Snowflake connector constants.py FIELD_TYPES tuple + Snowflex Type.ex decode/2 patterns.

### Python Worker Enhancement (query_id + type metadata)

The current Python worker already includes type_code in metadata via `build_metadata()`. It needs one addition -- `cursor.sfqid` for query_id:

```python
# In execute_query(), add query_id to payload:
write_message({
    "id": request_id,
    "status": "ok",
    "payload": {
        "columns": columns,
        "rows": serialize_rows(rows),
        "num_rows": num_rows,
        "metadata": metadata,
        "query_id": cursor.sfqid,  # NEW: Snowflake query ID
    },
})
```

Source: Snowflake Python Connector API docs -- `cursor.sfqid` attribute.

### DBConnection Callback Return Patterns

```
connect/2      -> {:ok, state} | {:error, exception}
disconnect/2   -> :ok
checkout/1     -> {:ok, state} | {:disconnect, exception, state}
checkin/1      -> {:ok, state} | {:disconnect, exception, state}
ping/1         -> {:ok, state} | {:disconnect, exception, state}
handle_execute/4 -> {:ok, query, result, state} | {:error, exception, state} | {:disconnect, exception, state}
handle_prepare/3 -> {:ok, query, state} | {:error, exception, state}
handle_close/3   -> {:ok, result, state}
handle_status/2  -> {:idle | :transaction | :error, state}
handle_begin/3   -> {:disconnect, exception, state}  # no transactions
handle_commit/3  -> {:disconnect, exception, state}  # no transactions
handle_rollback/3 -> {:disconnect, exception, state} # no transactions
handle_declare/4 -> {:ok, query, cursor, state} | {:error, exception, state}
handle_fetch/4   -> {:cont | :halt, result, state}
handle_deallocate/4 -> {:ok, result, state}
```

Source: hexdocs.pm/db_connection/DBConnection.html

### Snowflex Result Struct (target parity)

```elixir
# Snowflex.Result fields to match:
defstruct [
  :columns,      # [String.t()] | nil
  :rows,         # [[term()]] | nil
  :num_rows,     # non_neg_integer() -- default 0
  :metadata,     # [map()] -- default []  (NOTE: list not map)
  :messages,     # [map()] -- default []
  :query,        # SnowflexDev.Query.t() | nil
  :query_id,     # String.t() | nil
  :request_id,   # String.t() | nil  (always nil for us -- REST API concept)
  :sql_state,    # String.t() | nil
]
```

### Snowflex Query Struct (target parity)

```elixir
# Snowflex.Query fields:
defstruct [
  :statement,    # String.t() -- the SQL
  :transport,    # module -- NOT NEEDED for us (always Port)
  name: "",      # String.t()
  cache: :reference  # atom
]
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| DBConnection 1.x callbacks | DBConnection 2.x callbacks (handle_prepare, handle_execute split) | db_connection 2.0 | Must implement both prepare and execute callbacks |
| `disconnect/1` | `disconnect/2` takes error as first arg | db_connection 2.0 | Signature difference from some older examples |
| No `handle_status` | `handle_status/2` required | db_connection 2.1+ | Must return transaction status |

## Open Questions

1. **Snowflex metadata format: list vs map**
   - What we know: Snowflex's Result has `metadata` typed as `[map()]` (list of maps), which is the raw rowType from Snowflake REST API. Our current metadata from Python is a map keyed by column name.
   - What's unclear: Whether consuming code depends on the metadata being a list-of-maps vs a map.
   - Recommendation: Store the raw column-keyed metadata map in `metadata` field. If needed for Ecto integration later, transform in Phase 3. The decode logic uses our metadata format, not Snowflex's.

2. **Python datetime string format precision**
   - What we know: Python's `str()` on datetime objects produces ISO8601-like format. Snowflake's Python connector may return datetime objects or strings depending on configuration.
   - What's unclear: Exact microsecond precision and timezone offset format in all cases.
   - Recommendation: Handle both with and without microseconds in the TypeDecoder. Test with real Snowflake data in integration tests.

3. **FIXED type: integer vs Decimal threshold**
   - What we know: Snowflex uses `scale` from metadata to decide. Scale 0 = integer, scale > 0 = Decimal.
   - What's unclear: Whether Python connector always returns integers for scale-0 FIXED or sometimes returns Decimal("123").
   - Recommendation: Handle both -- check if value is already integer, otherwise parse from string. Use scale from metadata to determine target type.

## Sources

### Primary (HIGH confidence)
- Snowflex Connection.ex (GitHub raw) -- DBConnection callback implementation reference
- Snowflex Query.ex (GitHub raw) -- Query struct fields and DBConnection.Query protocol
- Snowflex Result.ex (GitHub raw) -- Result struct field list
- Snowflex transport/http/type.ex (GitHub raw) -- Type encoding/decoding patterns
- hexdocs.pm/db_connection/DBConnection.html -- Full callback contract
- hexdocs.pm/db_connection/DBConnection.Query.html -- Protocol specification
- snowflakedb/snowflake-connector-python constants.py (GitHub raw) -- FIELD_TYPES indices 0-20
- docs.snowflake.com/en/developer-guide/python-connector/python-connector-api -- cursor.description, sfqid, type_code mapping

### Secondary (MEDIUM confidence)
- dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii -- DBConnection implementation patterns (referenced in CLAUDE.md)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- db_connection and decimal are well-established, version constraints from CLAUDE.md
- Architecture: HIGH -- Snowflex Connection.ex is a direct reference; DBConnection callback contract is stable and well-documented
- Type decoding: HIGH -- Snowflake type codes confirmed from connector source; Snowflex Type.ex provides Elixir mapping reference
- Pitfalls: HIGH -- identified from real implementation concerns (port lifecycle, JSON serialization, type ambiguity)

**Research date:** 2026-03-26
**Valid until:** 2026-04-26 (stable domain -- DBConnection and Snowflake connector APIs change infrequently)
