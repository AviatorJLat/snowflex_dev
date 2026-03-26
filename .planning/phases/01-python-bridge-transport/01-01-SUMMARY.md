---
phase: 01-python-bridge-transport
plan: 01
subsystem: transport
tags: [erlang-port, python, json-protocol, packet-4, snowflake-connector]

# Dependency graph
requires: []
provides:
  - "Protocol module with encode/decode for {:packet, 4} JSON bridge"
  - "Result struct matching Snowflex.Result shape"
  - "Error exception for protocol and Snowflake errors"
  - "Python worker with stdin/stdout framing, SSO auth, chunked transfer, PPID monitoring"
affects: [01-python-bridge-transport, 02-dbconnection-behaviour]

# Tech tracking
tech-stack:
  added: [jason ~> 1.4, snowflake-connector-python >= 3.12]
  patterns: ["{:packet, 4} JSON protocol", "stdout isolation for Port safety", "PPID-based zombie prevention", "chunked transfer for large results"]

key-files:
  created:
    - lib/snowflex_dev/protocol.ex
    - lib/snowflex_dev/result.ex
    - lib/snowflex_dev/error.ex
    - priv/python/snowflex_dev_worker.py
    - test/snowflex_dev/protocol_test.exs
  modified:
    - mix.exs
    - lib/snowflex_dev.ex
    - .gitignore

key-decisions:
  - "Used PPID monitoring (os.getppid()) for zombie prevention over stdin EOF detection -- simpler and more reliable on macOS/Linux"
  - "Chunked at 1000 rows per message to stay well under 64KB pipe buffer limit"
  - "Single write(header + data) call in Python to prevent interleaving"

patterns-established:
  - "Protocol encode functions return JSON binary; decode returns tagged tuples"
  - "Python worker: redirect stdout to stderr first, use sys.__stdout__.buffer for protocol"
  - "Request correlation via 16-char hex IDs from :crypto.strong_rand_bytes/1"

requirements-completed: [PORT-01, PORT-02, PORT-03, PORT-04, PORT-05]

# Metrics
duration: 4min
completed: 2026-03-26
---

# Phase 1 Plan 1: Port Protocol & Python Worker Summary

**{:packet, 4} JSON protocol with Python worker implementing stdout isolation, PPID zombie prevention, chunked transfer, and Snowflake externalbrowser SSO**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-26T16:03:55Z
- **Completed:** 2026-03-26T16:07:51Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- Protocol module with 4 encode functions and 1 decode function handling 5 response variants
- Result struct (columns, rows, num_rows, metadata) and Error exception (message, code, sql_state)
- Python worker (314 lines) with complete {:packet, 4} framing, stdout isolation, PPID monitoring, chunked transfer, and all 4 command handlers
- 18 unit tests covering all protocol encode/decode paths including edge cases

## Task Commits

Each task was committed atomically:

1. **Task 1: Protocol module, Result/Error structs** (TDD)
   - `2f0f365` (test: add failing tests for Protocol, Result, and Error modules)
   - `9374d8f` (feat: implement Protocol module, Result/Error structs, add jason dependency)
2. **Task 2: Python worker script** - `a513583` (feat: create Python worker with {:packet, 4} protocol and SSO support)
3. **Housekeeping** - `7dedfb6` (chore: add Python __pycache__ to gitignore)

## Files Created/Modified
- `lib/snowflex_dev/protocol.ex` - Pure encode/decode functions for Port JSON protocol
- `lib/snowflex_dev/result.ex` - Query result struct matching Snowflex.Result shape
- `lib/snowflex_dev/error.ex` - Error exception for protocol and Snowflake errors
- `priv/python/snowflex_dev_worker.py` - Long-running Python worker with {:packet, 4} protocol
- `test/snowflex_dev/protocol_test.exs` - 18 unit tests for protocol encode/decode
- `mix.exs` - Added jason ~> 1.4 dependency
- `lib/snowflex_dev.ex` - Updated module doc, removed hello/0 placeholder
- `.gitignore` - Added Python __pycache__ exclusion

## Decisions Made
- Used PPID monitoring (`os.getppid()`) for zombie prevention over stdin EOF detection -- simpler and more reliable on macOS/Linux
- Chunked at 1000 rows per message to stay well under 64KB pipe buffer limit
- Single `write(header + data)` call in Python to prevent write interleaving
- `default=str` in `json.dumps` handles Decimal, datetime, date, time, bytes without explicit conversion

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Updated existing test file referencing removed hello/0**
- **Found during:** Task 1 (GREEN phase)
- **Issue:** test/snowflex_dev_test.exs referenced SnowflexDev.hello/0 which was removed per plan
- **Fix:** Removed hello test, kept doctest
- **Files modified:** test/snowflex_dev_test.exs
- **Verification:** mix test passes
- **Committed in:** 9374d8f (Task 1 commit)

**2. [Rule 3 - Blocking] Created .tool-versions for asdf version management**
- **Found during:** Task 1 (deps.get)
- **Issue:** Worktree missing .tool-versions needed by asdf to resolve mix/erl
- **Fix:** Created .tool-versions with elixir 1.18.4-otp-27 and erlang 27.2
- **Files modified:** .tool-versions
- **Committed in:** 9374d8f (Task 1 commit)

**3. [Rule 3 - Blocking] Added __pycache__ to .gitignore**
- **Found during:** Task 2 (post-verification)
- **Issue:** Python syntax check created __pycache__ directory
- **Fix:** Added __pycache__/ and *.pyc to .gitignore
- **Files modified:** .gitignore
- **Committed in:** 7dedfb6

---

**Total deviations:** 3 auto-fixed (1 bug, 2 blocking)
**Impact on plan:** All auto-fixes necessary for correctness. No scope creep.

## Issues Encountered
None -- plan executed cleanly.

## Known Stubs
None -- all modules are fully implemented with no placeholder data.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Protocol module ready for Transport GenServer (Plan 01-02) to use for Port communication
- Python worker ready to be launched via Port.open with {:spawn_executable, python3} and [-u, worker_path] args
- Result and Error structs ready for Transport to construct from decoded responses

## Self-Check: PASSED

All 5 created files verified on disk. All 4 commit hashes verified in git log.

---
*Phase: 01-python-bridge-transport*
*Completed: 2026-03-26*
