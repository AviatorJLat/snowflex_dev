# Phase 2: DBConnection Adapter - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-26
**Phase:** 02-dbconnection-adapter
**Areas discussed:** Result struct compatibility, Type decoding strategy, Crash recovery approach, Connection state model
**Mode:** --auto (all decisions auto-selected with recommended defaults)

---

## Result Struct Compatibility

| Option | Description | Selected |
|--------|-------------|----------|
| Exact field match | Mirror all Snowflex.Result fields, nil for unpopulable ones | ✓ |
| Minimal fields | Only fields the Python connector can populate | |
| Superset | Add extra SnowflexDev-specific fields beyond Snowflex | |

**User's choice:** [auto] Exact field match (recommended default)
**Notes:** Drop-in replacement requires identical struct shape. Nil defaults for REST-API-specific fields like request_id.

---

## Type Decoding Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Python returns typed JSON, Elixir converts | Python includes type metadata, Elixir maps to Elixir types | ✓ |
| Python does full conversion | Python returns Elixir-compatible types as strings | |
| Elixir infers types | No type metadata, Elixir guesses from values | |

**User's choice:** [auto] Python returns typed JSON, Elixir converts (recommended default)
**Notes:** Natural boundary split. Python connector has cursor.description with type info. Elixir has the type system knowledge (Decimal, NaiveDateTime, etc.).

---

## Crash Recovery Approach

| Option | Description | Selected |
|--------|-------------|----------|
| DBConnection handles reconnection | Use pool's native disconnect→connect lifecycle | ✓ |
| Custom supervisor restart | Wrap Transport.Port in a Supervisor with restart strategy | |
| Manual reconnect in adapter | Adapter detects crash and manually restarts Port | |

**User's choice:** [auto] DBConnection handles reconnection (recommended default)
**Notes:** DBConnection's pool already has this lifecycle. Return {:disconnect, error, state} from callbacks on Port crash, pool creates fresh connection.

---

## Connection State Model

| Option | Description | Selected |
|--------|-------------|----------|
| 1:1 mapping (Port per pool slot) | Each DBConnection slot owns one Transport.Port | ✓ |
| Shared Port with multiplexing | Single Port process handles multiple pool slots | |
| Port pool separate from DBConnection pool | Two pool layers | |

**User's choice:** [auto] 1:1 mapping (recommended default)
**Notes:** Matches CLAUDE.md architecture decision. checkout/checkin are no-ops. Transport.Port GenServer IS the connection.

---

## Claude's Discretion

- Query struct design internals
- Internal state struct for DBConnection module
- Test structure and mock strategy

## Deferred Ideas

None — discussion stayed within phase scope
