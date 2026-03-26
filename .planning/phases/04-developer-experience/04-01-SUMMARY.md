---
phase: 04-developer-experience
plan: 01
subsystem: developer-experience
tags: [mix-task, python-venv, health-check, setup-automation]

# Dependency graph
requires:
  - phase: 01-python-bridge
    provides: Transport.Port with default python_path convention
provides:
  - "Mix task `mix snowflex_dev.setup` for Python venv bootstrapping"
  - "HealthCheck module for pre-flight environment validation"
  - "Error codes SNOWFLEX_DEV_PYTHON_NOT_FOUND and SNOWFLEX_DEV_CONNECTOR_MISSING"
affects: [04-developer-experience]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Mix task with System.cmd for one-shot Python operations"
    - "Pre-flight health check returning tagged Error structs"

key-files:
  created:
    - lib/mix/tasks/snowflex_dev.setup.ex
    - lib/snowflex_dev/health_check.ex
    - test/snowflex_dev/health_check_test.exs
    - test/mix/tasks/snowflex_dev_setup_test.exs
  modified: []

key-decisions:
  - "HealthCheck checks only local prerequisites (python binary, connector import), not Snowflake connectivity"
  - "Default python path uses @default_python_path module attribute matching Transport.Port convention"

patterns-established:
  - "Actionable error messages: every error includes the fix command (mix snowflex_dev.setup)"
  - "Platform-aware help: brew/apt/dnf install instructions in error messages"

requirements-completed: [DX-01, DX-02, DX-03]

# Metrics
duration: 3min
completed: 2026-03-26
---

# Phase 4 Plan 1: Setup & Health Check Summary

**Mix setup task bootstrapping Python venv with snowflake-connector-python, plus HealthCheck module returning tagged errors with actionable fix instructions**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-26T18:45:11Z
- **Completed:** 2026-03-26T18:48:13Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- HealthCheck.validate/1 returns :ok for valid environments and {:error, %Error{}} with specific codes for failures
- Mix.Tasks.SnowflexDev.Setup finds Python 3.9+, creates venv, installs snowflake-connector-python, verifies import
- All error messages include actionable fix instructions (mix snowflex_dev.setup, platform install commands, proxy hints)

## Task Commits

Each task was committed atomically:

1. **Task 1: HealthCheck module with pre-flight validation** - `49b3ae1` (test: RED), `93ac9e6` (feat: GREEN)
2. **Task 2: Mix setup task for Python venv bootstrapping** - `5b63ef1` (test: RED), `ffa6861` (feat: GREEN)

_Note: TDD tasks have test + implementation commits._

## Files Created/Modified
- `lib/snowflex_dev/health_check.ex` - Pre-flight validation: checks python exists and snowflake.connector importable
- `lib/mix/tasks/snowflex_dev.setup.ex` - Mix task: finds python, verifies version, creates venv, installs deps, prints config example
- `test/snowflex_dev/health_check_test.exs` - 4 tests covering all error paths and default path behavior
- `test/mix/tasks/snowflex_dev_setup_test.exs` - 3 tests covering module metadata and error handling

## Decisions Made
- HealthCheck checks only local prerequisites (python binary, connector import), not Snowflake connectivity -- SSO happens during Port connect
- Default python path uses module attribute matching Transport.Port convention (_snowflex_dev/venv/bin/python3)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed shortdoc test to use Mix.Task.shortdoc/1**
- **Found during:** Task 2 (GREEN phase)
- **Issue:** Test called `Mix.Tasks.SnowflexDev.Setup.shortdoc()` but @shortdoc is not exposed as a public function
- **Fix:** Changed to `Mix.Task.shortdoc(Mix.Tasks.SnowflexDev.Setup)` which is the correct API
- **Files modified:** test/mix/tasks/snowflex_dev_setup_test.exs
- **Committed in:** ffa6861 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Minor test API correction. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Setup task and health check ready for integration into Connection.connect/1 (future plan)
- Config-only adapter swap documentation (DX-04) ready for next plan

---
*Phase: 04-developer-experience*
*Completed: 2026-03-26*
