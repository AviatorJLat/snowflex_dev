# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 -- MVP

**Shipped:** 2026-03-26
**Phases:** 4 | **Plans:** 8 | **Tasks:** 14

### What Was Built
- Erlang Port bridge with `{:packet, 4}` JSON protocol and Python worker with SSO authentication
- Transport GenServer managing Port lifecycle with crash recovery and chunked result reassembly
- Full DBConnection behaviour with TypeDecoder for all 14 Snowflake type codes
- Ecto adapter with Snowflake SQL dialect generation, loaders/dumpers, and non-transactional streaming
- `mix snowflex_dev.setup` for one-command Python venv bootstrapping
- HealthCheck module with tagged error codes and actionable fix instructions

### What Worked
- Strict sequential dependency chain (Port -> Transport -> DBConnection -> Ecto -> DX) eliminated integration surprises
- Copying Snowflex's SQL generation verbatim instead of depending on it -- avoided circular dependency complexity
- Using an echo worker Python script for testing meant no Snowflake credentials needed in CI/tests
- Phase 4 UAT with live SSO caught 3 real bugs that unit tests couldn't (absolute paths, missing pip extra, GenServer timeout)
- Coarse 4-phase granularity kept planning overhead low while maintaining clear boundaries

### What Was Inefficient
- REQUIREMENTS.md checkboxes for Phase 1 requirements weren't marked until milestone audit -- documentation lag
- Traceability table initially showed all requirements as "Pending" despite phases being complete
- Some ROADMAP.md plan checkboxes inconsistent (some `[x]`, some `[ ]`) for completed plans

### Patterns Established
- `{:packet, 4}` JSON over Erlang Port as the Elixir-Python bridge pattern
- stdout isolation (redirect to stderr on Python startup) for Port safety
- PPID monitoring for zombie prevention
- `skip_health_check` option for test environments
- Tagged error codes (`SNOWFLEX_DEV_*`) for programmatic error handling
- Echo worker pattern for testing Port-based GenServers without external dependencies

### Key Lessons
1. Live UAT is essential for Port-based systems -- mocked tests passed but real SSO exposed timeout and path issues
2. Python's `venv` needs absolute paths for `System.cmd` -- relative paths cause `:enoent` that's hard to debug
3. `GenServer.start_link` has a 5-second default timeout that's too short for browser-based SSO authentication
4. Snowflake's lack of transaction support means standard `Ecto.Adapters.SQL.stream` doesn't work -- need custom stream via `DBConnection.run`
5. Empty list `[]` is truthy in Elixir -- pattern matching with `is_map` guard needed for metadata normalization

### Cost Observations
- Entire v1.0 built in a single day (all 4 phases, 8 plans, 52 commits)
- Each plan averaged ~3 minutes execution time
- Research and planning phases were lightweight due to well-defined architecture upfront

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 4 | 8 | Initial process -- strict sequential phases with coarse granularity |

### Cumulative Quality

| Milestone | Tests | Requirements | Tech Debt Items |
|-----------|-------|--------------|-----------------|
| v1.0 | 102 | 22/22 satisfied | 7 (no blockers) |

### Top Lessons (Verified Across Milestones)

1. Live UAT catches issues that mocked tests cannot -- especially for external process integration
