# Research Summary: SnowflexDev

**Domain:** Drop-in Elixir database adapter (DBConnection-based) bridging to Python for Snowflake dev access via SSO
**Researched:** 2026-03-26
**Overall confidence:** HIGH

## Executive Summary

SnowflexDev is an Elixir library that implements the full DBConnection behaviour and Ecto adapter interfaces, matching Snowflex's API exactly, but routes queries through an Erlang Port to a long-running Python process instead of Snowflex's HTTP/REST transport. The Python process uses `snowflake-connector-python` with `externalbrowser` SSO authentication, giving developers zero-setup Snowflake access without keypairs, OAuth security integrations, or admin involvement.

The technology stack is deliberately conservative. The Elixir side uses `db_connection`, `ecto`, `ecto_sql`, `jason`, and `telemetry` -- all standard Ecto ecosystem libraries at current versions. The Python side uses only `snowflake-connector-python` plus stdlib modules (`json`, `sys`, `struct`). The bridge between them is a raw Erlang Port with `{:packet, 4}` length-prefixed JSON framing -- no additional IPC libraries.

The architecture has a clean layered structure: Ecto adapter (delegates to Ecto.Adapters.SQL) -> DBConnection behaviour (manages connection lifecycle) -> Transport GenServer (owns the Port) -> Python worker (owns the Snowflake connection). Each layer has a single responsibility and well-defined boundaries. The 1:1 mapping between DBConnection pool slots and Python processes is the simplest correct design.

The biggest risks are (1) stdout corruption from Python libraries writing to stdout and breaking the `{:packet, 4}` protocol, (2) type decode mismatches between Python connector's native types and Snowflex's REST-API-derived types, (3) SSO browser auth blocking connection pool startup, and (4) zombie Python processes when the BEAM crashes. All have documented mitigations.

## Key Findings

**Stack:** Erlang Port + `{:packet, 4}` JSON protocol. `db_connection ~> 2.7`, `ecto ~> 3.12`, `ecto_sql ~> 3.12`, `jason ~> 1.4`. Python: `snowflake-connector-python >= 3.12`. No exotic dependencies.

**Architecture:** Layered: Ecto adapter -> DBConnection -> Transport GenServer -> Erlang Port -> Python worker. One Python process per pool connection. Pool size defaults to 1.

**Critical pitfall:** Python stdout buffering and corruption silently breaks the Port protocol. Must launch Python with `-u` flag AND redirect `sys.stdout` to stderr on first line of worker script, using `sys.__stdout__.buffer` exclusively for protocol messages.

## Implications for Roadmap

Based on research, suggested phase structure:

1. **Python Worker + Protocol Layer** - Foundation that everything depends on
   - Addresses: Port protocol, JSON framing, Python worker script, Result/Error structs
   - Avoids: Stdout buffering pitfall (solve immediately), zombie process pitfall (build cleanup from the start)

2. **Transport GenServer + Port Lifecycle** - Bridge between Elixir and Python
   - Addresses: Port management, command/response flow, crash recovery
   - Avoids: Buffer deadlock (test with large results early), checkout timeout mismatch

3. **DBConnection Adapter** - The core Ecto integration layer
   - Addresses: connect/disconnect/execute/ping callbacks, Query struct, type decoding
   - Avoids: Type decode mismatch (build golden comparison tests), transaction callback errors (mirror Snowflex exactly)

4. **Ecto Adapter + SQL Generation** - Final layer for Repo.all/insert/update/delete
   - Addresses: Ecto.Adapter behaviours, SQL generation (reuse from Snowflex), loaders/dumpers
   - Avoids: SQL generation drift (copy with clear provenance)

5. **Setup Tooling + Polish** - Developer experience
   - Addresses: mix snowflex_dev.setup (venv creation), Python path discovery, documentation
   - Avoids: Venv path issues (make configurable, test with spaces)

**Phase ordering rationale:**
- Each phase depends on the previous one (Python worker -> Transport -> DBConnection -> Ecto -> Tooling)
- The Port protocol must be bulletproof before building anything on top of it
- DBConnection and Ecto layers can leverage Snowflex's patterns closely, reducing risk
- Setup tooling is last because it's not needed for development/testing (you can manually create a venv)

**Research flags for phases:**
- Phase 1: Needs careful implementation research for `{:packet, 4}` Python-side handling -- must get framing exactly right
- Phase 3: Needs deeper investigation of Snowflex's Type.decode/2 to build comprehensive type mapping
- Phase 4: May need phase-specific research on Snowflex's SQL generation module (~900 lines) to decide copy vs. depend
- Phase 2, 5: Standard patterns, unlikely to need additional research

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All libraries verified on hex.pm/pypi with current versions. Erlang Port is stdlib. |
| Features | HIGH | Based on direct inspection of Snowflex source code. DBConnection behaviour is well-documented. |
| Architecture | HIGH | Layered adapter pattern proven by Postgrex, MyXQL, Snowflex. Port GenServer pattern documented by multiple sources. |
| Pitfalls | HIGH | Most pitfalls verified from community issues, library docs, and Snowflex source. Buffer/stdout issues confirmed by elixir-nodejs project. |

## Gaps to Address

- **Snowflex SQL generation reuse strategy**: Need to decide during Phase 4 whether to copy the ~900 line SQL generation module or depend on Snowflex as a library. This requires evaluating whether Snowflex can be cleanly separated.
- **Exact type mapping**: Phase 3 needs a comprehensive mapping from Python connector type codes to Snowflex's `Type.decode/2` output types. This requires testing with a real Snowflake instance.
- **MuonTrap evaluation**: The zombie process mitigation might benefit from MuonTrap, but adding a dep for a dev tool needs evaluation against the simpler stdin-monitoring-thread approach.
- **Elixir version minimum**: The project currently specifies `~> 1.18` but should consider lowering to `~> 1.14` to match Snowflex's constraint. No 1.18-specific features are needed.
