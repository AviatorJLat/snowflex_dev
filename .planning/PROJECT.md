# SnowflexDev

## What This Is

A drop-in development replacement for Snowflex (Elixir Snowflake Ecto adapter) that uses Python's `snowflake-connector-python` with `externalbrowser` SSO authentication under the hood. Implements the full `DBConnection` behaviour and Ecto adapter interface so consuming Phoenix apps can swap between SnowflexDev (dev) and Snowflex (prod) via config -- no application code changes.

SnowflexDev bridges Elixir and Python via an Erlang Port, managing a bundled Python virtualenv with `snowflake-connector-python` pre-installed. A Mix task handles venv creation automatically.

## Core Value

Developers get Snowflake access in local development using their existing SSO credentials with zero infrastructure setup -- no keypairs, no security integrations, no admin involvement. Just `mix snowflex_dev.setup`, configure, and query.

## Current State

**Shipped:** v1.0 MVP (2026-03-26)
**Codebase:** ~12,300 lines across 71 files (Elixir + Python)
**Tests:** 102 tests across 4 phases
**Stack:** Elixir 1.18, Python 3.9+, DBConnection 2.7+, Ecto 3.12+, snowflake-connector-python 3.12+

All 22 v1.0 requirements satisfied. Verified with live SSO testing against real Snowflake instance.

## Requirements

### Validated

- ✓ Erlang Port bridge with `{:packet, 4}` JSON protocol -- v1.0
- ✓ Python worker with stdout isolation and PPID zombie prevention -- v1.0
- ✓ `externalbrowser` SSO authentication via snowflake-connector-python -- v1.0
- ✓ Configurable connection parameters (account, warehouse, database, schema, role) -- v1.0
- ✓ Chunked transfer for large result sets -- v1.0
- ✓ Transport GenServer managing Port lifecycle with crash recovery -- v1.0
- ✓ Full DBConnection behaviour matching Snowflex's interface -- v1.0
- ✓ Type decoding for all 14 Snowflake type codes to Elixir equivalents -- v1.0
- ✓ Result format parity with Snowflex (columns, rows, num_rows, metadata, query_id) -- v1.0
- ✓ Ecto adapter (Adapter, Queryable, Schema behaviours) -- v1.0
- ✓ Snowflake SQL dialect generation (SELECT, INSERT, UPDATE, DELETE, CTEs, QUALIFY) -- v1.0
- ✓ Type loaders/dumpers matching Snowflex -- v1.0
- ✓ `mix snowflex_dev.setup` for automated Python venv bootstrapping -- v1.0
- ✓ Health check on startup with actionable error messages -- v1.0
- ✓ Config-only swap between SnowflexDev and Snowflex -- v1.0

### Active

(No active requirements -- next milestone not yet planned)

### Out of Scope

- Production use -- this is explicitly a dev/test tool (Snowflex handles production via REST API + keypair JWT)
- ODBC support -- using Python's native connector, not ODBC
- Token management -- `externalbrowser` handles auth internally within the Python connector
- Snowflake security integration setup -- the whole point is avoiding this
- Transaction support -- Snowflake doesn't support traditional transactions; matches Snowflex's behaviour

## Context

- **Companion to:** pepsico-ecommerce/snowflex -- production Snowflake Ecto adapter using REST SQL API
- **Origin:** Snowflex's keypair authentication requires a Snowflake security integration (ACCOUNTADMIN access) which blocks local dev when admins are unavailable. Python's connector supports `externalbrowser` SSO natively with zero Snowflake-side setup.
- **Target user:** Elixir/Phoenix developers who use Snowflake via Snowflex in production but need frictionless local dev access
- **Reference implementation:** CrewAI project at Pilotbase uses the same Python connector + externalbrowser pattern successfully with account PILOTBASE-WN74625

## Constraints

- **Interface compatibility**: Must implement DBConnection behaviour so Ecto.Repo works without code changes in consuming apps
- **Elixir version**: Must support ~> 1.14 (matching Snowflex's minimum)
- **Python version**: Require Python 3.9+ (snowflake-connector-python minimum)
- **Dev-only dependency**: SnowflexDev should be added as `only: :dev` in consuming apps
- **No BEAM instability**: Python process failures must not crash the Elixir supervision tree -- restart strategy with backoff
- **Result format parity**: Query results must match Snowflex's return format exactly

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Erlang Port (not NIFs/erlport) | Simplest, most stable Elixir-Python bridge. Process isolation means Python crashes can't corrupt BEAM memory | ✓ Good -- zero BEAM crashes during testing |
| Bundled venv (not system Python) | Zero-setup for consuming developers. `mix snowflex_dev.setup` handles everything | ✓ Good -- one command to working setup |
| JSON protocol over stdin/stdout | Human-readable, debuggable, no binary serialization complexity | ✓ Good -- simplified debugging during development |
| `externalbrowser` auth (not keypair) | Works without any Snowflake admin setup | ✓ Good -- core value validated with live SSO |
| Full DBConnection behaviour (not proxy) | True drop-in replacement. Consuming app's Ecto code is completely unaware of which adapter is active | ✓ Good -- config-only swap verified |
| Copy Snowflex SQL generation (not depend on it) | Avoid runtime dependency on Snowflex in dev environments | ✓ Good -- ~900 lines copied, module refs renamed |
| `qmark` paramstyle in Python worker | Ecto uses `?` placeholders; `qmark` tells snowflake-connector-python to accept them | ✓ Good -- seamless Ecto parameter passing |
| Non-transactional streaming via DBConnection.run | Snowflake doesn't support transactions; standard Ecto.Adapters.SQL.stream requires them | ✓ Good -- stream works without transaction wrapper |
| HealthCheck validates local env only | Checking Snowflake connectivity at startup would require SSO; health check catches the common failures (missing Python, missing connector) | ✓ Good -- fast startup, catches 90% of issues |

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
2. Core Value check -- still the right priority?
3. Audit Out of Scope -- reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-26 after v1.0 milestone completion*
