# SnowflexDev Requirements

## v1 Requirements

### Python Bridge
- [ ] **PORT-01**: Elixir communicates with Python via Erlang Port using `{:packet, 4}` length-prefixed JSON protocol
- [ ] **PORT-02**: Python worker script connects to Snowflake via `snowflake-connector-python` with `externalbrowser` SSO
- [ ] **PORT-03**: Python stdout redirected to stderr on startup; protocol uses `sys.__stdout__.buffer` exclusively to prevent corruption
- [ ] **PORT-04**: Python process monitors stdin for EOF and self-terminates to prevent zombie processes
- [ ] **PORT-05**: Large result sets transferred in chunks to prevent memory exhaustion on both sides

### DBConnection Adapter
- [ ] **DBC-01**: Implements `DBConnection` behaviour with `connect/2`, `disconnect/2`, `checkout/1`, `checkin/1`, `ping/1`, `handle_execute/4` callbacks
- [ ] **DBC-02**: Query struct matches Snowflex.Query fields and behaviour
- [ ] **DBC-03**: Result struct matches Snowflex.Result (columns, rows, num_rows, metadata, messages, query, query_id, request_id, sql_state)
- [ ] **DBC-04**: Type decoding maps Python connector types to identical Elixir types as Snowflex (FIXED→Decimal, REAL→float, TIMESTAMP→NaiveDateTime/DateTime, DATE→Date, TIME→Time, BOOLEAN→boolean)
- [ ] **DBC-05**: Port crash recovery — Python process failure triggers clean reconnect without crashing the BEAM supervision tree

### Ecto Integration
- [ ] **ECTO-01**: Implements `Ecto.Adapter`, `Ecto.Adapter.Queryable`, and `Ecto.Adapter.Schema` behaviours
- [ ] **ECTO-02**: Reuses Snowflex's SQL generation module (Snowflake dialect: SELECT, INSERT, UPDATE, DELETE, CTEs, window functions, QUALIFY)
- [ ] **ECTO-03**: Loaders and dumpers convert between Elixir types and Snowflake column types
- [ ] **ECTO-04**: Consuming app can use `Repo.all/1`, `Repo.insert/2`, `Repo.update/2`, `Repo.delete/2` identically to Snowflex

### Transport Layer
- [ ] **TRANS-01**: Transport GenServer manages Port lifecycle (open, monitor, restart on crash)
- [ ] **TRANS-02**: Synchronous command/response flow — GenServer.call blocks until Python returns result
- [ ] **TRANS-03**: Configurable connection parameters: account, user, warehouse, database, schema, role, authenticator
- [ ] **TRANS-04**: Connection timeout extended for SSO auth (browser popup may take 30+ seconds)

### Developer Experience
- [ ] **DX-01**: `mix snowflex_dev.setup` creates Python virtualenv and installs snowflake-connector-python automatically
- [ ] **DX-02**: Connection health check on startup verifies Snowflake connectivity and reports clear errors
- [ ] **DX-03**: Detailed error messages for common failure modes (Python not found, venv missing, pip install failed, Snowflake unreachable)
- [ ] **DX-04**: Config-only swap — consuming app switches between SnowflexDev and Snowflex by changing adapter in config, zero code changes

## v2 Requirements (Deferred)

- [ ] Migration support (Ecto.Adapter.Migration behaviour)
- [ ] Telemetry events for query timing and connection lifecycle
- [ ] MuonTrap for more robust process management
- [ ] Windows support
- [ ] Pool size > 1 with SSO token sharing between Python processes
- [ ] Streaming results for very large datasets

## Out of Scope

- Production use — SnowflexDev is explicitly a dev/test tool
- ODBC support — using Python's native connector
- OAuth token management — externalbrowser handles auth internally
- Snowflake security integration setup — avoiding this is the core value
- Transaction support — Snowflake doesn't support traditional transactions; match Snowflex's disconnect-on-transaction-attempt behaviour

## Traceability

| Requirement | Phase | Plan | Status |
|-------------|-------|------|--------|
| PORT-01 | Phase 1 | | Pending |
| PORT-02 | Phase 1 | | Pending |
| PORT-03 | Phase 1 | | Pending |
| PORT-04 | Phase 1 | | Pending |
| PORT-05 | Phase 1 | | Pending |
| TRANS-01 | Phase 1 | | Pending |
| TRANS-02 | Phase 1 | | Pending |
| TRANS-03 | Phase 1 | | Pending |
| TRANS-04 | Phase 1 | | Pending |
| DBC-01 | Phase 2 | | Pending |
| DBC-02 | Phase 2 | | Pending |
| DBC-03 | Phase 2 | | Pending |
| DBC-04 | Phase 2 | | Pending |
| DBC-05 | Phase 2 | | Pending |
| ECTO-01 | Phase 3 | | Pending |
| ECTO-02 | Phase 3 | | Pending |
| ECTO-03 | Phase 3 | | Pending |
| ECTO-04 | Phase 3 | | Pending |
| DX-01 | Phase 4 | | Pending |
| DX-02 | Phase 4 | | Pending |
| DX-03 | Phase 4 | | Pending |
| DX-04 | Phase 4 | | Pending |
