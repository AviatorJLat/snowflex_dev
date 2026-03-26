# SnowflexDev

## What This Is

A drop-in development replacement for Snowflex (Elixir Snowflake Ecto adapter) that uses Python's `snowflake-connector-python` with `externalbrowser` SSO authentication under the hood. Implements the full `DBConnection` behaviour so consuming Phoenix apps can swap between SnowflexDev (dev) and Snowflex (prod) via config — no application code changes.

SnowflexDev bridges Elixir and Python via an Erlang Port, managing a bundled Python virtualenv with `snowflake-connector-python` pre-installed. A Mix task handles venv creation automatically.

## Core Value

Developers get Snowflake access in local development using their existing SSO credentials with zero infrastructure setup — no keypairs, no OAuth security integrations, no admin involvement. Just `mix snowflex_dev.setup`, configure, and query.

## Requirements

### Validated

- [x] Python Port bridge — Elixir GenServer manages a long-running Python process via Erlang Port (Validated in Phase 1: Python Bridge & Transport)
- [x] JSON protocol over stdin/stdout between Elixir and Python (Validated in Phase 1: Python Bridge & Transport)
- [x] `externalbrowser` SSO authentication via snowflake-connector-python (Validated in Phase 1: Python Bridge & Transport)
- [x] Snowflake session parameters (warehouse, database, schema, role) configurable via app config (Validated in Phase 1: Python Bridge & Transport)
- [x] Graceful error handling — Python crashes don't take down the BEAM, Port restarts cleanly (Validated in Phase 1: Python Bridge & Transport)
- [x] Full DBConnection behaviour implementation matching Snowflex's interface (Validated in Phase 2: DBConnection Adapter)
- [x] Connection pooling compatible with DBConnection pool (multiple Python processes or multiplexed queries) (Validated in Phase 2: DBConnection Adapter)
- [x] Result set format matches Snowflex's return types so consuming code works unchanged (Validated in Phase 2: DBConnection Adapter)
- [x] Ecto.Repo integration — schemas, queries, migrations work identically to Snowflex (Validated in Phase 3: Ecto Integration)
- [x] Same query operations as Snowflex: SELECT, DDL, DML, stored procedures (Validated in Phase 3: Ecto Integration)
- [x] Bundled Python virtualenv — `mix snowflex_dev.setup` creates venv and pip installs snowflake-connector-python (Validated in Phase 4: Developer Experience)
- [x] Config-driven swap between SnowflexDev and Snowflex (only config changes, no code changes) (Validated in Phase 4: Developer Experience)
- [x] Health check on startup with clear, actionable errors for common failures (Validated in Phase 4: Developer Experience)

### Active

(No active requirements — all validated through Phase 4)

### Out of Scope

- Production use — this is explicitly a dev/test tool (Snowflex handles production via REST API + keypair JWT)
- ODBC support — we're using Python's native connector, not ODBC
- OAuth token management — `externalbrowser` handles auth internally within the Python connector
- Snowflake security integration setup — the whole point is avoiding this
- Windows support (first pass) — macOS/Linux where Python 3 is readily available

## Context

- **Companion to:** pepsico-ecommerce/snowflex — production Snowflake Ecto adapter using REST SQL API
- **Origin:** Snowflex's OAuth flow requires a Snowflake security integration (ACCOUNTADMIN access) which blocks local dev when admins are unavailable. Python's connector supports `externalbrowser` SSO natively with zero Snowflake-side setup.
- **Target user:** Elixir/Phoenix developers who use Snowflake via Snowflex in production but need frictionless local dev access
- **Python dependency:** snowflake-connector-python with `externalbrowser` authenticator — handles browser SSO, token caching, and session management internally
- **Communication pattern:** Erlang Port (stdin/stdout JSON protocol) — the Python process is long-lived, accepts query commands, returns results
- **Reference implementation:** CrewAI project at Pilotbase uses the same Python connector + externalbrowser pattern successfully with account PILOTBASE-WN74625

## Constraints

- **Interface compatibility**: Must implement DBConnection behaviour so Ecto.Repo works without code changes in consuming apps
- **Elixir version**: Must support ~> 1.14 (matching Snowflex's minimum)
- **Python version**: Require Python 3.8+ (snowflake-connector-python minimum)
- **Dev-only dependency**: SnowflexDev should be added as `only: :dev` in consuming apps
- **No BEAM instability**: Python process failures must not crash the Elixir supervision tree — restart strategy with backoff
- **Result format parity**: Query results must match Snowflex's return format exactly

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Erlang Port (not NIFs/erlport) | Simplest, most stable Elixir↔Python bridge. Process isolation means Python crashes can't corrupt BEAM memory | -- Pending |
| Bundled venv (not system Python) | Zero-setup for consuming developers. `mix snowflex_dev.setup` handles everything | -- Pending |
| JSON protocol over stdin/stdout | Human-readable, debuggable, no binary serialization complexity. Query payloads are small enough that JSON overhead is negligible | -- Pending |
| `externalbrowser` auth (not OAuth tokens) | Works without any Snowflake admin setup — the Python connector handles SSO internally | -- Pending |
| Full DBConnection behaviour (not proxy) | True drop-in replacement. Consuming app's Ecto code is completely unaware of which adapter is active | -- Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? -> Move to Out of Scope with reason
2. Requirements validated? -> Move to Validated with phase reference
3. New requirements emerged? -> Add to Active
4. Decisions to log? -> Add to Key Decisions
5. "What This Is" still accurate? -> Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-26 after Phase 4 completion (final phase — all v1.0 requirements validated)*
