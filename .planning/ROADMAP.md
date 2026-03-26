# Roadmap: SnowflexDev

## Overview

SnowflexDev delivers a drop-in development replacement for Snowflex by building up from the Python/Erlang Port foundation through DBConnection and Ecto adapter layers, ending with developer experience tooling. Each phase completes one layer of the stack and is fully verifiable before the next begins. The dependency chain is strictly sequential: the Port protocol must be bulletproof before the Transport GenServer can manage it, DBConnection needs a working transport, Ecto needs a working adapter, and tooling polishes the whole thing.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Python Bridge & Transport** - Erlang Port protocol, Python worker, and Transport GenServer managing the full Port lifecycle
- [ ] **Phase 2: DBConnection Adapter** - DBConnection behaviour implementation with Query/Result structs, type decoding, and crash recovery
- [ ] **Phase 3: Ecto Integration** - Ecto adapter behaviours, SQL generation, loaders/dumpers enabling Repo operations
- [ ] **Phase 4: Developer Experience** - Setup tooling, health checks, error messages, and config-only swap

## Phase Details

### Phase 1: Python Bridge & Transport
**Goal**: Elixir can send queries to a long-running Python process over an Erlang Port and receive structured results back reliably
**Depends on**: Nothing (first phase)
**Requirements**: PORT-01, PORT-02, PORT-03, PORT-04, PORT-05, TRANS-01, TRANS-02, TRANS-03, TRANS-04
**Success Criteria** (what must be TRUE):
  1. A Python worker process starts, connects to Snowflake via externalbrowser SSO, and stays alive accepting commands over stdin/stdout JSON protocol
  2. An Elixir GenServer can send a SQL query string and receive back structured column/row data through the Port
  3. Large result sets transfer without memory exhaustion or protocol corruption (chunked transfer works)
  4. Killing the Python process causes the GenServer to detect the failure and cleanly restart the Port (no BEAM crash, no zombie processes)
  5. Connection parameters (account, warehouse, database, schema, role) are configurable and passed through to the Python worker
**Plans:** 2 plans

Plans:
- [ ] 01-01-PLAN.md -- Python worker script, Protocol module, Result/Error structs
- [ ] 01-02-PLAN.md -- Transport GenServer and integration tests

### Phase 2: DBConnection Adapter
**Goal**: SnowflexDev participates in DBConnection's pool and lifecycle, returning results in the exact same format as Snowflex
**Depends on**: Phase 1
**Requirements**: DBC-01, DBC-02, DBC-03, DBC-04, DBC-05
**Success Criteria** (what must be TRUE):
  1. DBConnection.execute/4 with a SnowflexDev.Query succeeds against a live Snowflake instance and returns a SnowflexDev.Result
  2. Result struct fields (columns, rows, num_rows, metadata, query_id) match Snowflex.Result for the same query
  3. Snowflake types (FIXED, REAL, TIMESTAMP_NTZ, TIMESTAMP_LTZ, TIMESTAMP_TZ, DATE, TIME, BOOLEAN, VARCHAR) decode to identical Elixir types as Snowflex
  4. A Python crash mid-query returns an error to the caller and the pool recovers the connection slot automatically
**Plans:** 2 plans

Plans:
- [x] 02-01-PLAN.md -- Query/Result structs, TypeDecoder, Python worker query_id enhancement
- [ ] 02-02-PLAN.md -- DBConnection behaviour implementation and integration tests

### Phase 3: Ecto Integration
**Goal**: Consuming apps can use Ecto.Repo operations (all, insert, update, delete) with SnowflexDev identically to Snowflex
**Depends on**: Phase 2
**Requirements**: ECTO-01, ECTO-02, ECTO-03, ECTO-04
**Success Criteria** (what must be TRUE):
  1. A consuming app's Repo module configured with SnowflexDev adapter can execute Repo.all(from u in User, where: u.active == true) and return schema structs
  2. Repo.insert/2, Repo.update/2, and Repo.delete/2 execute the expected SQL against Snowflake
  3. Ecto type conversions (loaders/dumpers) round-trip correctly between Elixir schema types and Snowflake column types
  4. SQL generation produces valid Snowflake dialect (CTEs, QUALIFY, window functions work)
**Plans:** 2 plans

Plans:
- [ ] 03-01-PLAN.md -- SQL.Connection module with Snowflake SQL generation, ecto/ecto_sql deps, Python qmark paramstyle
- [ ] 03-02-PLAN.md -- Main Ecto adapter module with behaviours, loaders/dumpers, stream, and tests

### Phase 4: Developer Experience
**Goal**: A new developer can go from zero to running Snowflake queries with one mix task and a config change
**Depends on**: Phase 3
**Requirements**: DX-01, DX-02, DX-03, DX-04
**Success Criteria** (what must be TRUE):
  1. Running `mix snowflex_dev.setup` on a clean machine creates a Python virtualenv and installs snowflake-connector-python without manual intervention
  2. On startup, SnowflexDev verifies Snowflake connectivity and prints clear, actionable errors for common failures (Python not found, venv missing, Snowflake unreachable)
  3. A consuming app can switch between SnowflexDev (dev) and Snowflex (prod) by changing only config values -- zero application code changes
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Python Bridge & Transport | 0/2 | Planning complete | - |
| 2. DBConnection Adapter | 0/2 | Planning complete | - |
| 3. Ecto Integration | 0/2 | Planning complete | - |
| 4. Developer Experience | 0/? | Not started | - |
