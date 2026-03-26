# Phase 2: DBConnection Adapter - Context

**Gathered:** 2026-03-26
**Status:** Ready for planning

<domain>
## Phase Boundary

Implement the DBConnection behaviour that wraps the existing Transport.Port layer. This phase delivers Query/Result structs matching Snowflex's interface, Snowflake type decoding, and crash recovery — enabling DBConnection.execute/4 to work against a live Snowflake instance through the Python Port bridge.

</domain>

<decisions>
## Implementation Decisions

### Result Struct Compatibility
- **D-01:** SnowflexDev.Result must have exact field parity with Snowflex.Result — all the same fields. Fields that can't be populated from the Python connector (e.g., request_id from REST API) default to nil.
- **D-02:** Current Result struct (columns, rows, num_rows, metadata) needs extending with: query, query_id, request_id, sql_state, messages.

### Type Decoding Strategy
- **D-03:** Split decoding at the Python/Elixir boundary. Python returns raw JSON with type metadata from cursor.description (column types). Elixir maps those types to proper Elixir equivalents (FIXED→Decimal, REAL→float, TIMESTAMP_NTZ→NaiveDateTime, TIMESTAMP_LTZ/TZ→DateTime, DATE→Date, TIME→Time, BOOLEAN→boolean, VARCHAR→String).
- **D-04:** The Python worker needs to include column type information in its response payload so Elixir can do type-aware conversion.

### Crash Recovery Approach
- **D-05:** No custom restart logic. DBConnection's pool handles reconnection naturally — when checkout/ping fails, pool calls disconnect/2 then connect/2 to create a fresh Transport.Port. The adapter just needs correct connect/disconnect implementations.
- **D-06:** Port crash during a query returns {:disconnect, error, state} from handle_execute so DBConnection knows the connection is dead.

### Connection State Model
- **D-07:** 1:1 mapping — each DBConnection pool slot owns one Transport.Port process. This follows the architecture decision in CLAUDE.md.
- **D-08:** checkout/checkin are effectively no-ops since the Transport.Port connection is always ready. The GenServer IS the connection.

### Claude's Discretion
- Query struct design internals (field naming, helper functions) — follow Snowflex.Query patterns
- Internal state struct design for the DBConnection module
- Test structure and mock strategy for unit tests

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Snowflex Reference
- `CLAUDE.md` §Port Protocol Design — JSON protocol format and framing decisions
- `CLAUDE.md` §Architecture Decision — why Erlang Port, 1 Port per pool slot

### Requirements
- `.planning/REQUIREMENTS.md` §DBConnection Adapter — DBC-01 through DBC-05
- `.planning/REQUIREMENTS.md` §Transport Layer — TRANS-01 through TRANS-04 (already implemented, context for how transport works)

### Phase 1 Implementation (existing code to build on)
- `lib/snowflex_dev/transport.ex` — Transport behaviour definition
- `lib/snowflex_dev/transport/port.ex` — Transport GenServer implementation
- `lib/snowflex_dev/protocol.ex` — JSON protocol encode/decode
- `lib/snowflex_dev/result.ex` — Current Result struct (needs extending)
- `lib/snowflex_dev/error.ex` — Error exception struct

### External References
- Snowflex source (pepsico-ecommerce/snowflex) — Connection.ex, Query.ex, Result.ex interfaces to match
- hexdocs.pm/db_connection/DBConnection.html — DBConnection behaviour API reference
- dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii — DBConnection implementation patterns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `SnowflexDev.Transport` behaviour — already defines start_link, execute, ping, disconnect interface
- `SnowflexDev.Transport.Port` — fully implemented GenServer with lifecycle management, chunked response assembly, crash detection
- `SnowflexDev.Protocol` — JSON encode/decode for connect, execute, ping, disconnect commands
- `SnowflexDev.Result` — needs extending but foundation exists
- `SnowflexDev.Error` — exception struct ready to use

### Established Patterns
- GenServer + behaviour abstraction for transport layer
- Synchronous GenServer.call for command/response flow
- State struct pattern (defmodule State inside GenServer module)
- Port exit handling returns errors to pending callers

### Integration Points
- DBConnection callbacks wrap Transport.Port calls (execute→Transport.execute, ping→Transport.ping)
- connect/2 starts a new Transport.Port process; disconnect/2 stops it
- mix.exs needs `{:db_connection, "~> 2.7"}` added to deps
- Result struct needs additional fields for Snowflex compatibility
- Python worker may need to include column type info in response payload for type decoding

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. Follow Snowflex's interface patterns and DBConnection's documented behaviour contract.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-dbconnection-adapter*
*Context gathered: 2026-03-26*
