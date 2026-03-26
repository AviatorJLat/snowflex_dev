# Domain Pitfalls

**Domain:** Elixir-Python bridge via Erlang Port with DBConnection adapter for Snowflake
**Researched:** 2026-03-26

## Critical Pitfalls

Mistakes that cause rewrites or major issues.

### Pitfall 1: Port Pipe Buffer Deadlock (65 KB Ceiling)

**What goes wrong:** Erlang Ports communicate over OS pipes, which have a fixed buffer size (typically 64 KB on macOS/Linux). When the Python process writes a JSON response larger than the pipe buffer -- for example, a SELECT returning hundreds of rows -- the write blocks. If the Elixir side is simultaneously waiting for the Python process to finish before reading (a synchronous send-then-receive pattern), both sides block forever: classic deadlock.

**Why it happens:** The Erlang VM reads Port output as messages delivered to the owning process mailbox. If you use `{:packet, N}` framing, the BEAM accumulates bytes until the full packet arrives. But the OS pipe buffer fills up before the full message is written by Python, so Python's `sys.stdout.write()` blocks, and the BEAM never receives the complete message.

**Consequences:** The GenServer managing the Port hangs indefinitely. DBConnection's checkout timeout eventually fires and disconnects the connection. Under pool pressure, all connections can cascade into this state, making the entire adapter unresponsive. The Python process is left in a zombie-like blocked state.

**Warning signs:**
- Queries that return small result sets work; large ones hang
- DBConnection timeout errors on SELECT queries but not DDL
- Python process CPU drops to 0% (blocked on write)

**Prevention:**
1. Use `{:packet, 4}` framing on the Erlang side AND implement matching 4-byte length-prefix reading/writing on the Python side. This lets the BEAM handle reassembly correctly.
2. On the Python side, write in chunks and flush after each chunk. Use `sys.stdout.buffer.write()` (binary mode) rather than `print()` or `sys.stdout.write()` (text mode).
3. Run Python with `-u` flag (unbuffered stdout/stderr) OR set `PYTHONUNBUFFERED=1`. Without this, Python buffers stdout when it detects it is not connected to a TTY (which is always the case with Ports).
4. For very large result sets, implement pagination in the JSON protocol: Python sends results in batches (e.g., 1000 rows per message), Elixir reassembles. This caps the maximum single-message size well below pipe buffer limits.
5. Consider streaming results: Python sends a "start" message with column metadata, then row batches, then an "end" message. This avoids ever needing to serialize the entire result set into one JSON blob.

**Detection:** Load test with a query returning 1000+ rows early in development. If it hangs, this is the cause.

**Phase relevance:** Port communication protocol design (Phase 1 or equivalent). Must be solved in the initial protocol, not retrofitted.

**Confidence:** HIGH -- this is a well-documented Erlang Port limitation. The elixir-nodejs library hit this exact issue at 65,536 bytes ([GitHub Issue #2](https://github.com/revelrylabs/elixir-nodejs/issues/2)).

---

### Pitfall 2: Python Stdout Buffering Silently Breaks Protocol

**What goes wrong:** Python buffers stdout by default when it detects it is not connected to a TTY. Erlang Ports are not TTYs. This means Python can `json.dumps()` + `write()` a response, but the bytes sit in Python's internal buffer and never reach the pipe. The Elixir side waits for a response that has been "sent" but not flushed.

**Why it happens:** Python 3's default stdout is line-buffered when connected to a TTY and fully-buffered (block-buffered, typically 8 KB) when connected to a pipe. Developers test with `python script.py` in a terminal (line-buffered, works), then run via Port (block-buffered, breaks).

**Consequences:** Appears identical to Pitfall 1 (hanging), but occurs even with tiny responses if the buffer has not yet filled. The first query might work (if the buffer fills or Python happens to flush), but subsequent queries appear to randomly hang.

**Warning signs:**
- First query works, second hangs (or works intermittently)
- Adding `print()` debug statements to Python "fixes" the issue (because `print` adds a newline, which triggers line-buffer flush in some configurations)

**Prevention:**
1. ALWAYS launch Python with `-u` flag: `python3 -u script.py`. This is non-negotiable.
2. As a belt-and-suspenders measure, also call `sys.stdout.flush()` after every write in the Python protocol handler.
3. If using `{:packet, 4}` binary framing, use `sys.stdout.buffer` (the raw binary stream) instead of `sys.stdout` (the text wrapper). The text wrapper adds an encoding layer that interacts badly with binary framing.
4. Add an integration test that makes 10 sequential queries and asserts all return. Sequential is important -- concurrent queries mask the bug by filling the buffer faster.

**Detection:** Run the Port protocol handler in a subprocess (not directly in terminal) during development to catch this immediately.

**Phase relevance:** Port communication protocol design (Phase 1). This is literally the first thing to get right.

**Confidence:** HIGH -- documented in Python tracker ([Issue #4705](https://bugs.python.org/issue4705)) and Erlang mailing list archives.

---

### Pitfall 3: Zombie/Orphan Python Processes on BEAM Crash

**What goes wrong:** When the BEAM VM crashes (not a normal shutdown -- a hard crash, OOM kill, or `kill -9`), the Python child process is NOT automatically terminated. It becomes an orphan process consuming resources. On subsequent restarts, new Python processes are spawned while old ones linger.

**Why it happens:** Erlang Ports close the child's stdin when the port closes, but this only works during graceful shutdown. If the BEAM is killed, the kernel closes file descriptors, but the Python process does not receive a signal -- it just gets an EOF on stdin (eventually). If Python is blocked on a Snowflake query, it will not even notice stdin closed until the query completes.

**Consequences:** Memory leak (each orphan holds a Python interpreter + snowflake-connector-python + open Snowflake sessions). Port exhaustion on the Snowflake account (phantom sessions). Developers see "maximum number of sessions exceeded" errors with no apparent cause.

**Warning signs:**
- `ps aux | grep python` shows multiple snowflex_dev Python processes
- Snowflake web UI shows stale sessions from the same user
- Memory usage on the dev machine grows over time

**Prevention:**
1. Python process must have a stdin-monitoring thread: read stdin in a background thread, and if it receives EOF, call `os._exit(1)`. This handles the BEAM-crash case.
2. Alternatively, use a wrapper script pattern (documented in [Elixir Port docs](https://hexdocs.pm/elixir/Port.html)) that monitors stdin and kills the child on EOF.
3. Consider [MuonTrap](https://github.com/fhunleth/muontrap) (`muontrap`) as a dependency -- it wraps child processes in a cgroup (Linux) or uses a similar mechanism to ensure cleanup. Evaluate whether the dependency is worth it for a dev-only tool.
4. On the Elixir side, use `Process.flag(:trap_exit, true)` in the GenServer owning the Port, and in `terminate/2`, explicitly send a shutdown command via the protocol before closing the port.
5. Store the OS PID of the Python process and attempt `System.cmd("kill", [pid])` in terminate as a last resort.

**Detection:** In CI or dev setup docs, add a check: after running tests, assert no lingering Python processes.

**Phase relevance:** Port lifecycle management (Phase 1-2). Design the cleanup mechanism alongside the Port spawning.

**Confidence:** HIGH -- documented Elixir issue with established patterns. See [Elixir Forum discussion](https://elixirforum.com/t/debugging-stuck-zombie-process/54301) and [elixir-lang-core thread](https://groups.google.com/g/elixir-lang-core/c/yiepKrcEniU).

---

### Pitfall 4: DBConnection Checkout Timeout vs. Port Blocking

**What goes wrong:** DBConnection has a default checkout timeout of 15 seconds. When `handle_execute/4` is called, it runs in the client process with the connection checked out. If the Python Port call blocks (waiting for Snowflake, waiting for the pipe, or waiting for the browser auth popup), DBConnection's deadline fires. It then terminates the connection -- but the Python process does not know the query was cancelled. The connection state becomes inconsistent: Elixir thinks it is disconnected, Python is still executing the query.

**Why it happens:** DBConnection's timeout mechanism works by monitoring the client process. When the deadline passes, it forcefully reclaims the connection. But Erlang Ports do not support cancellation -- there is no way to interrupt a `Port.command/2` + receive cycle from outside.

**Consequences:**
- Connection pool exhaustion: timed-out connections are disconnected, reducing pool size until reconnection
- The Python process finishes the query and writes a response, but nobody reads it. The next command sent on a recycled Port reads stale data from the previous query (response desync)
- Under load, this cascades: all pool connections time out, application becomes unusable

**Warning signs:**
- `DBConnection.ConnectionError: client timed out because it checked out the connection for longer than 15000ms`
- Queries occasionally return results from a different query (response desync)
- Pool size gradually shrinks to 0

**Prevention:**
1. Set `:timeout` on the DBConnection pool to a value that accounts for Snowflake query latency (e.g., 120_000ms for dev workloads). Document this clearly.
2. Implement a request/response correlation ID in the JSON protocol. Each command gets a UUID; responses include the same UUID. If a response's UUID does not match the expected one, discard it and drain until the correct one arrives (or disconnect).
3. On disconnect, the GenServer must drain any pending Port output before spawning a new Python process. Read and discard all buffered messages.
4. Consider making the Port GenServer own its own timeout (shorter than DBConnection's) so it can respond with an error to DBConnection rather than letting DBConnection forcefully terminate the connection.

**Detection:** Send a query that takes 20+ seconds while the pool timeout is 15 seconds. Observe the behavior.

**Phase relevance:** DBConnection integration (Phase 2-3). The correlation ID should be designed into the protocol from Phase 1.

**Confidence:** HIGH -- DBConnection timeout behavior is well-documented ([db_connection docs](https://hexdocs.pm/db_connection/DBConnection.html)). The response desync consequence is specific to Port-based adapters and is the most dangerous subtle bug.

---

### Pitfall 5: Result Format Mismatch Between Python and Snowflex

**What goes wrong:** SnowflexDev must return `%Snowflex.Result{}` structs with the exact same shape as Snowflex's HTTP transport. Snowflex's Result typespec says `rows: [tuple()]`, but the actual HTTP transport stores rows as lists of lists (JSON arrays from the REST API). If SnowflexDev returns a different format -- for example, rows as lists of maps (Python `dict`), or with different type coercions -- Ecto queries silently produce wrong results or crash in the Ecto type-casting layer.

**Why it happens:** Snowflake's Python connector returns rows differently than the REST API:
- Python connector: rows are tuples of Python-native types (`datetime.datetime`, `decimal.Decimal`, `int`, `str`)
- Snowflex REST API: rows are lists of strings (all values are strings), then decoded by `Snowflex.Transport.Http.Type.decode/2` into Elixir types based on column metadata

The gap: Python `decimal.Decimal` serialized as JSON becomes `"1.23"` (string) or `1.23` (float) depending on your JSON encoder. Snowflex expects `Decimal.new("1.23")` (Elixir Decimal struct). Python `datetime` becomes an ISO string, but timezone handling differs between `TIMESTAMP_NTZ`, `TIMESTAMP_LTZ`, and `TIMESTAMP_TZ`.

**Consequences:**
- Ecto schemas with `:decimal` fields get floats, causing precision loss (financial data)
- Ecto schemas with `:naive_datetime` fields get `DateTime` structs (or vice versa), causing Ecto cast errors
- `nil` handling: Python `None` becomes JSON `null`, which is fine, but Python connector may return empty strings for some column types where Snowflex returns `nil`
- Boolean columns: Python returns `True`/`False`, JSON encodes as `true`/`false`, but Snowflex decodes from the string `"true"`/`"false"`

**Warning signs:**
- Tests pass with string/integer columns but fail with decimal or timestamp columns
- Values are "close but not exactly right" (e.g., float instead of Decimal)
- `Ecto.CastError` or `FunctionClauseError` in Ecto type casting

**Prevention:**
1. Study `Snowflex.Transport.Http.Type.decode/2` (shown above) as the authoritative reference for output types. SnowflexDev must produce identical Elixir types.
2. On the Python side, implement a type-aware serializer: convert `decimal.Decimal` to string (not float), convert `datetime` to ISO 8601 with explicit timezone info, convert `date` to ISO 8601 date string, convert `bool` to JSON boolean.
3. On the Elixir side, implement a type decoder that mirrors `Snowflex.Transport.Http.Type.decode/2`. Include column metadata (the `rowType` equivalent) in the Python response so the Elixir side knows how to decode each column.
4. Write a comprehensive type-mapping test suite covering all Snowflake types: `FIXED` (integer and decimal), `REAL`, `TEXT`, `BOOLEAN`, `DATE`, `TIME`, `TIMESTAMP_NTZ`, `TIMESTAMP_LTZ`, `TIMESTAMP_TZ`, `VARIANT`, `ARRAY`, `OBJECT`, `BINARY`.
5. Rows must be lists of lists (matching Snowflex), NOT lists of maps. The column names go in `Result.columns`, the values go in `Result.rows` as positionally-indexed lists.

**Detection:** Write a "golden test" that runs the same query through Snowflex and SnowflexDev, and asserts the Result structs match (excluding query_id and request_id).

**Phase relevance:** Type mapping (Phase 2). Must be designed after the basic protocol works but before Ecto integration testing.

**Confidence:** HIGH -- directly verified from Snowflex source code (`Snowflex.Transport.Http.Type` and `Snowflex.Result`).

---

### Pitfall 6: `externalbrowser` Auth Blocks the Port GenServer

**What goes wrong:** When `snowflake-connector-python` uses `externalbrowser` authentication, it opens a local socket server, launches the user's browser, and waits for the SSO callback. This blocks the Python process for 30-120 seconds (or indefinitely if the user does not complete SSO). During this time, the Erlang Port is unresponsive. If this happens inside `DBConnection.connect/1`, the connection timeout fires and the connection fails. On retry, the same thing happens -- the browser pops up again, confusing the user.

**Why it happens:** The `externalbrowser` authenticator in the Python connector is designed for interactive use. It calls `webbrowser.open()` and blocks on `socket.accept()`. There is no way to make this non-blocking or async from the Python connector's API.

**Consequences:**
- First connection attempt after token expiry: browser pops up, user must authenticate within DBConnection's connect timeout (default 15s -- almost certainly too short for SSO)
- If the user is slow, the connection times out, supervisor restarts, browser pops up AGAIN
- Multiple pool connections starting simultaneously: N browser popups for N pool connections
- In Docker/CI environments with no browser: the process hangs indefinitely

**Warning signs:**
- Multiple browser tabs opening for Snowflake SSO
- `DBConnection.ConnectionError` during application boot
- Application works after one manual auth but fails on restart

**Prevention:**
1. Separate the auth lifecycle from the connection lifecycle. Python should authenticate ONCE (on first use or on token expiry), cache the session token, and reuse it for subsequent connections. The `snowflake-connector-python` does internal token caching, but you need to ensure all pool connections share the same authenticated session.
2. Set `client_session_keep_alive=True` in the Python connector to prevent session expiry during development.
3. Set the DBConnection pool size to 1 initially for dev use. There is no need for connection pooling when the "database" is a single Python process. Multiple pool connections would each need their own Python process and their own auth flow.
4. Implement a "warm-up" command in the JSON protocol: the first message after Port spawn triggers authentication, with an extended timeout (e.g., 300 seconds). Only after auth succeeds does `DBConnection.connect/1` return `{:ok, state}`.
5. Use `login_timeout` parameter in the Python connector config (e.g., `login_timeout=300`) to give users enough time.
6. If token caching is available (the Python connector caches tokens in `~/.snowflake/` by default), detect cached tokens and skip the browser flow.

**Detection:** Kill the token cache, start the application, and observe the auth flow. If multiple popups appear or if the connection times out before auth completes, this pitfall is active.

**Phase relevance:** Connection lifecycle (Phase 1-2). The auth design must account for this from the start.

**Confidence:** HIGH -- documented in snowflake-connector-python issues ([#1415](https://github.com/snowflakedb/snowflake-connector-python/issues/1415), [#551 in .NET connector](https://github.com/snowflakedb/snowflake-connector-net/issues/551), [#1090](https://github.com/snowflakedb/snowflake-connector-python/issues/1090)).

---

## Moderate Pitfalls

### Pitfall 7: DBConnection `handle_status/2` and Transaction Callbacks

**What goes wrong:** DBConnection requires implementations of `handle_begin/2`, `handle_commit/2`, `handle_rollback/2`, and `handle_status/2`. Snowflex returns `{:disconnect, error, state}` for all of these (Snowflake REST API does not support transactions). If SnowflexDev copies this pattern, any Ecto code that accidentally uses `Repo.transaction/1` will disconnect the pool connection rather than returning a clear error.

**Prevention:**
1. Mirror Snowflex's behavior exactly: `{:disconnect, Error.exception("...does not support transactions"), state}`. This is what consuming apps already handle.
2. Document clearly that `Repo.transaction/1` is not supported. Ecto's `Repo.insert/2` and `Repo.update/2` work without explicit transactions.
3. Test that calling `Repo.transaction/1` produces a meaningful error, not a cryptic crash.

**Phase relevance:** DBConnection callback implementation (Phase 2).

**Confidence:** HIGH -- directly verified from Snowflex source.

---

### Pitfall 8: Python Virtualenv Portability and Path Issues

**What goes wrong:** The bundled venv (created by `mix snowflex_dev.setup`) uses absolute paths internally. If the project directory moves, the venv breaks. If the user has multiple Python versions, `pip install` may install packages for the wrong version. On macOS, system Python (`/usr/bin/python3`) may be a shim that behaves differently than a Homebrew or pyenv Python.

**Prevention:**
1. Always use `python3 -m venv` (not `virtualenv`) -- it ships with Python 3 and uses the invoking interpreter.
2. Store the venv inside the project (e.g., `_snowflex_dev/venv/`) and add it to `.gitignore`.
3. Pin `snowflake-connector-python` version in the setup task (e.g., `snowflake-connector-python==3.12.3`) to avoid breaking changes.
4. Detect the Python version at setup time and warn if < 3.8.
5. Use the venv's absolute Python path when spawning the Port (e.g., `_snowflex_dev/venv/bin/python3`), not just `python3` from PATH.

**Phase relevance:** Setup Mix task (Phase 1).

**Confidence:** MEDIUM -- standard Python packaging wisdom, not specific to this project.

---

### Pitfall 9: JSON Protocol Message Framing on Partial Reads

**What goes wrong:** If using newline-delimited JSON (NDJSON) instead of `{:packet, 4}` binary framing, a large JSON message may arrive as multiple TCP-like chunks. The Elixir side reads a partial JSON string, tries to decode it, and gets `Jason.DecodeError`. Alternatively, two small messages arrive in one read, and the Elixir side only decodes the first one, losing the second.

**Prevention:**
1. Use `{:packet, 4}` binary framing (4-byte length prefix). This is the idiomatic Erlang approach. The BEAM handles reassembly automatically -- you always receive complete messages.
2. On the Python side, implement matching framing: `struct.pack('>I', len(payload)) + payload` for writes, `struct.unpack('>I', stdin.read(4))` + `stdin.read(length)` for reads.
3. If you choose NDJSON instead (simpler to debug), you MUST handle partial reads: buffer incoming data, split on `\n`, decode only complete lines, carry over any remainder.
4. Never use `{:line, max_length}` Port mode -- if a JSON message contains a newline (e.g., in a string value), it will be split incorrectly.

**Phase relevance:** Port communication protocol design (Phase 1).

**Confidence:** HIGH -- `{:packet, 4}` behavior verified in [Elixir Port docs](https://hexdocs.pm/elixir/Port.html) and [The Erlangelist](https://www.theerlangelist.com/article/outside_elixir).

---

### Pitfall 10: DBConnection Pool Size vs. Python Process Count

**What goes wrong:** DBConnection's pool creates N connections, each calling `connect/1`. If each connection spawns its own Python process, you get N Python processes, each holding a Snowflake session, each potentially triggering a browser auth popup. This is wasteful for a dev tool and can exhaust Snowflake session limits.

**Prevention:**
1. Default pool size to 1. For a dev tool, concurrent query execution is rarely needed.
2. If pool_size > 1 is needed, all pool connections should share a single Python process. The Port GenServer becomes a singleton that multiplexes queries (with correlation IDs) rather than N separate processes.
3. Alternatively, one Python process per connection is fine IF they share the same Snowflake session token (via the connector's token cache). But each process is ~50-100 MB of memory (Python interpreter + connector), which is heavy for a dev tool.
4. Document the memory implications: `pool_size: 5` means 5 Python processes, ~500 MB RAM.

**Phase relevance:** Architecture decision (Phase 1 design, Phase 2 implementation).

**Confidence:** MEDIUM -- the memory numbers are estimates. The architectural decision depends on the final protocol design.

---

## Minor Pitfalls

### Pitfall 11: Python `stderr` Noise Pollutes Elixir Logs

**What goes wrong:** `snowflake-connector-python` writes warnings and debug info to stderr (e.g., "Initiating login request with your identity provider"). If the Port captures stderr (`:stderr_to_stdout`), these messages get mixed into the JSON protocol stream, corrupting message framing.

**Prevention:**
1. Do NOT use `:stderr_to_stdout` in Port.open options.
2. In the Python script, configure the snowflake connector's logger to write to a file or suppress it: `logging.getLogger('snowflake.connector').setLevel(logging.ERROR)`.
3. Use stderr for Python-side debug logging (it will appear in the Elixir console as `{port, {:data, ...}}` messages only if you opt into it).

**Phase relevance:** Port communication (Phase 1).

**Confidence:** HIGH.

---

### Pitfall 12: `Snowflex.Query` Struct Compatibility

**What goes wrong:** Snowflex uses a `Snowflex.Query` struct that implements `DBConnection.Query`. SnowflexDev must either use the same struct (creating a dependency on Snowflex) or implement its own compatible struct. If the struct shape differs, `Ecto.Adapters.SQL` internal calls will fail.

**Prevention:**
1. Implement a `SnowflexDev.Query` struct that implements `DBConnection.Query` with the same fields as `Snowflex.Query`. The struct module name does not matter to Ecto -- only the protocol implementation matters.
2. Ensure `encode/3` and `decode/3` protocol implementations match Snowflex's behavior.
3. Do NOT depend on the `snowflex` package -- SnowflexDev should be fully standalone.

**Phase relevance:** DBConnection implementation (Phase 2).

**Confidence:** HIGH -- verified from Snowflex source.

---

### Pitfall 13: `externalbrowser` Token Cache Location and Permissions

**What goes wrong:** The Python connector caches SSO tokens in `~/.snowflake/`. If the user's home directory is not writable (rare but possible in some corporate setups), or if the cache file gets corrupted, every connection triggers a new browser popup.

**Prevention:**
1. Check that `~/.snowflake/` exists and is writable during `mix snowflex_dev.setup`.
2. Document that deleting `~/.snowflake/credential_cache*` forces re-authentication.
3. Set `client_store_temporary_credential=True` in the Python connector config to enable token persistence explicitly.

**Phase relevance:** Setup and auth (Phase 1).

**Confidence:** MEDIUM -- based on connector documentation, not directly tested.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Port protocol design | Buffer deadlock (P1), stdout buffering (P2), message framing (P9) | Use `{:packet, 4}` + `python3 -u` + binary framing from day one |
| Python process lifecycle | Zombie processes (P3), stderr noise (P11), venv issues (P8) | Stdin-monitoring thread + wrapper script + isolated venv |
| DBConnection integration | Checkout timeout (P4), transaction callbacks (P7), pool size (P10) | Extended timeouts + pool_size: 1 + correlation IDs |
| Auth flow | Browser blocking (P6), token caching (P13) | Separate auth from connect, extended login timeout |
| Result format parity | Type mismatch (P5), Query struct (P12) | Golden tests comparing Snowflex vs SnowflexDev output |

## Sources

- [Erlang Port documentation](https://www.erlang.org/doc/system/c_port.html) -- Port communication fundamentals
- [Elixir Port module docs](https://hexdocs.pm/elixir/Port.html) -- `{:packet, 4}` framing, zombie process wrapper script
- [elixir-nodejs Issue #2](https://github.com/revelrylabs/elixir-nodejs/issues/2) -- 65,536 byte buffer limit in practice
- [The Erlangelist: Outside Elixir](https://www.theerlangelist.com/article/outside_elixir) -- Erlang Port patterns and `{:packet, 4}`
- [DBConnection docs](https://hexdocs.pm/db_connection/DBConnection.html) -- Timeout behavior, checkout lifecycle
- [Dashbit: Building a MySQL adapter](https://dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii-dbconnection-integration) -- DBConnection implementation patterns
- [DBConnection pooling deep dive](https://workos.com/blog/dbconnection-pooling-deep-dive) -- Pool mechanics and timeout handling
- [Managing External Commands with Ports](https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/) -- Zombie process prevention
- [MuonTrap](https://github.com/fhunleth/muontrap) -- External process containment library
- [snowflake-connector-python Issue #1415](https://github.com/snowflakedb/snowflake-connector-python/issues/1415) -- externalbrowser reauthentication
- [snowflake-connector-python Issue #1090](https://github.com/snowflakedb/snowflake-connector-python/issues/1090) -- Browser popup blocking
- [snowflake-connector-python Issue #1251](https://github.com/snowflakedb/snowflake-connector-python/issues/1251) -- Container/non-browser environment issues
- [Snowflake Python Connector API docs](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-api) -- Type mapping, connection parameters
- [Python Issue #4705](https://bugs.python.org/issue4705) -- `-u` unbuffered stdout behavior
- [Elixir Forum: zombie processes](https://elixirforum.com/t/debugging-stuck-zombie-process/54301) -- Community discussion on orphan processes
- [Preventing orphan processes on BEAM crash](https://groups.google.com/g/elixir-lang-core/c/yiepKrcEniU) -- Core team discussion
- Snowflex source code: `Snowflex.Connection`, `Snowflex.Result`, `Snowflex.Transport.Http.Type` -- directly inspected
