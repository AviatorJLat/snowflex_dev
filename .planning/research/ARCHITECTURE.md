# Architecture Patterns

**Domain:** Elixir-Python bridge via Erlang Port, implementing DBConnection for Snowflake dev access
**Researched:** 2026-03-26

## Recommended Architecture

SnowflexDev is a drop-in replacement for Snowflex that swaps the HTTP/REST transport for an Erlang Port backed by a long-running Python process running `snowflake-connector-python`. The architecture has two halves with a well-defined protocol boundary between them.

```
Ecto.Repo
  |
  v
SnowflexDev (Ecto Adapter behaviours)
  |
  v
SnowflexDev.Connection (DBConnection behaviour)
  |
  v
SnowflexDev.Transport.Port (GenServer, implements Transport behaviour)
  |  -- Port.open({:spawn_executable, python_path}, [:binary, {:packet, 4}])
  |  -- Sends/receives length-prefixed JSON over stdin/stdout
  v
Python worker process (snowflex_dev_worker.py)
  |  -- snowflake.connector.connect(authenticator="externalbrowser")
  v
Snowflake
```

### Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| `SnowflexDev` | Ecto Adapter module (`Ecto.Adapter`, `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`). Delegates to `Ecto.Adapters.SQL` exactly like Snowflex does. | `SnowflexDev.Ecto.Adapter.Connection`, `Ecto.Adapters.SQL` |
| `SnowflexDev.Ecto.Adapter.Connection` | `Ecto.Adapters.SQL.Connection` behaviour. Creates `DBConnection.child_spec/2`, builds queries, calls `DBConnection.prepare_execute/4`. SQL generation layer. | `SnowflexDev.Connection`, `DBConnection` |
| `SnowflexDev.Connection` | `DBConnection` behaviour. Manages connection lifecycle: `connect/1`, `disconnect/2`, `handle_execute/4`, `ping/1`. Holds transport reference in state. | `SnowflexDev.Transport.Port` |
| `SnowflexDev.Transport.Port` | GenServer wrapping an Erlang Port. Implements `Snowflex.Transport`-equivalent behaviour. Serializes queries to JSON, sends over Port, deserializes responses. | Python worker via stdin/stdout |
| `SnowflexDev.Protocol` | Encoding/decoding module (pure functions). Encodes query requests to JSON, decodes JSON responses to `SnowflexDev.Result` structs. No side effects. | Used by `Transport.Port` |
| `SnowflexDev.Query` | `DBConnection.Query` protocol implementation. Mirrors `Snowflex.Query` struct. Handles param encoding and result decoding. | `SnowflexDev.Connection`, `SnowflexDev.Protocol` |
| `SnowflexDev.Result` | Result struct matching Snowflex's `%Result{}` shape (columns, rows, num_rows, metadata, etc.). | Everything on the Elixir side |
| `SnowflexDev.Error` | Error struct matching Snowflex's `%Error{}` shape. | Everything on the Elixir side |
| `snowflex_dev_worker.py` | Long-running Python process. Reads JSON commands from stdin, executes via `snowflake-connector-python`, writes JSON responses to stdout. Manages a single Snowflake connection. | Snowflake (via Python connector), Elixir (via stdin/stdout) |
| `Mix.Tasks.SnowflexDev.Setup` | Mix task that creates a Python venv and `pip install snowflake-connector-python`. Run once per project. | Filesystem, pip |

### Data Flow

**Query execution (happy path):**

```
1. App code:      Repo.all(MySchema)
2. Ecto:          Builds query AST, calls adapter's execute/5
3. SnowflexDev:   Delegates to Ecto.Adapters.SQL.execute/6
4. SQL module:    Calls child_spec's connection via DBConnection.prepare_execute/4
5. Connection:    handle_execute/4 calls transport.execute_statement/4
6. Transport:     Encodes {id, "execute", sql, params} as JSON
                  Sends via Port (4-byte length prefix + JSON bytes)
7. Python:        Reads 4-byte length, reads N bytes, decodes JSON
                  Executes cursor.execute(sql, params)
                  Encodes {id, "ok", columns, rows, metadata} as JSON
                  Writes 4-byte length + JSON bytes to stdout
8. Transport:     Receives {:data, binary} message from Port
                  Decodes JSON to %Result{}
                  Returns {:ok, result}
9. Connection:    Returns {:ok, query, result, state}
10. Ecto:         Decodes result via DBConnection.Query protocol
11. App code:     Receives [%MySchema{}, ...]
```

**Error flow:**

```
Python error  -->  {id, "error", message, code}  -->  Transport decodes to %Error{}
Python crash  -->  {:EXIT, port, reason}          -->  Transport GenServer terminates
                                                  -->  DBConnection detects disconnect
                                                  -->  Pool reconnects (new Port + Python)
```

**Authentication flow (first connection):**

```
1. Transport.Port.init/1 opens Port to Python worker
2. Sends {"connect", account, user, warehouse, ...} command
3. Python calls snowflake.connector.connect(authenticator="externalbrowser")
4. Python connector opens browser for SSO
5. User authenticates in browser
6. Python connector receives token, establishes session
7. Python sends {"ok", "connected"} back
8. Transport.Port transitions to :connected state
```

## Port Protocol Design

Use `{:packet, 4}` mode -- Erlang's built-in 4-byte length-prefixed framing. This is critical because raw stdin/stdout streaming has no message boundaries. With `{:packet, 4}`, Erlang automatically prepends a 4-byte big-endian unsigned integer length header on send, and delivers complete messages on receive. The Python side must mirror this: read 4 bytes, interpret as big-endian uint32, read that many bytes.

**Confidence: HIGH** -- `{:packet, 4}` is the standard approach for Port communication. Documented in `:erlang.open_port/2` and used extensively in the Elixir/Erlang ecosystem.

### Message Format (JSON)

**Request (Elixir -> Python):**
```json
{
  "id": "req-001",
  "type": "connect",
  "payload": {
    "account": "ORGNAME-ACCTNAME",
    "user": "jane@company.com",
    "warehouse": "DEV_WH",
    "database": "DEV_DB",
    "schema": "PUBLIC",
    "role": "DEV_ROLE"
  }
}
```

```json
{
  "id": "req-002",
  "type": "execute",
  "payload": {
    "sql": "SELECT id, name FROM users WHERE active = %s",
    "params": [true]
  }
}
```

**Response (Python -> Elixir):**
```json
{
  "id": "req-002",
  "status": "ok",
  "payload": {
    "columns": ["ID", "NAME"],
    "rows": [[1, "Alice"], [2, "Bob"]],
    "num_rows": 2,
    "metadata": {}
  }
}
```

```json
{
  "id": "req-002",
  "status": "error",
  "payload": {
    "message": "SQL compilation error",
    "code": "001003"
  }
}
```

**Why request IDs:** Even though the Port is synchronous (one request, one response), request IDs make debugging easier and future-proof the protocol for potential pipelining. They also guard against response mismatch if the Python process writes unexpected output (e.g., a Python library printing to stdout).

### Python Worker Structure

```python
#!/usr/bin/env python3
"""snowflex_dev_worker.py - Long-running Snowflake bridge process."""
import sys
import struct
import json
import snowflake.connector

def read_message():
    """Read a 4-byte length-prefixed message from stdin."""
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None  # EOF - port closed
    length = struct.unpack(">I", header)[0]
    data = sys.stdin.buffer.read(length)
    return json.loads(data)

def write_message(msg):
    """Write a 4-byte length-prefixed message to stdout."""
    data = json.dumps(msg).encode("utf-8")
    sys.stdout.buffer.write(struct.pack(">I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()  # Critical: flush after every write

def main():
    conn = None
    while True:
        msg = read_message()
        if msg is None:
            break  # Port closed
        # dispatch on msg["type"]: connect, execute, ping, disconnect
        ...
```

**Critical detail: stdout flushing.** The Python process MUST call `sys.stdout.buffer.flush()` after every write. Without it, the OS may buffer stdout and the Elixir side will hang waiting for data. This is the most common Port communication bug.

**Critical detail: stderr separation.** Python libraries (including `snowflake-connector-python`) may log to stderr. Use `{:spawn_executable, path}` with `[:binary, {:packet, 4}, :use_stdio, :exit_status]` -- stderr goes to the BEAM's stderr by default, which is fine. Do NOT use `:stderr_to_stdout` as it would corrupt the framed protocol.

## Patterns to Follow

### Pattern 1: Mirror Snowflex's Transport Behaviour

**What:** Define a `SnowflexDev.Transport` behaviour identical to `Snowflex.Transport`. The `Connection` module delegates to the transport, and the transport handles the actual I/O.

**Why:** This is exactly how Snowflex works. `Snowflex.Connection` calls `transport.execute_statement/4` where transport is `Snowflex.Transport.Http`. SnowflexDev replaces Http with a Port-based transport.

**Confidence: HIGH** -- Directly observed in Snowflex source code.

```elixir
defmodule SnowflexDev.Transport do
  @callback start_link(Keyword.t()) :: GenServer.on_start()
  @callback execute_statement(pid(), String.t(), any(), Keyword.t()) :: query_result()
  @callback disconnect(pid()) :: :ok
  @callback ping(pid()) :: query_result()
end
```

### Pattern 2: Transport GenServer Owns the Port

**What:** The `Transport.Port` GenServer opens the Erlang Port in `init/1` and holds it in state. All communication with Python goes through GenServer calls. When the GenServer terminates, the Port (and Python process) is automatically cleaned up.

**Why:** Ports are linked to their owner process. If the owning process dies, the Port closes and the external process receives EOF on stdin. This is the standard "let it crash" pattern -- if the Transport dies, the Port dies, and DBConnection pool handles reconnection.

**Confidence: HIGH** -- Standard Erlang/OTP Port ownership pattern.

```elixir
defmodule SnowflexDev.Transport.Port do
  use GenServer
  @behaviour SnowflexDev.Transport

  defmodule State do
    defstruct [:port, :connected, :pending_request]
  end

  def init(opts) do
    python_path = find_python(opts)
    worker_path = worker_script_path()

    port = Port.open(
      {:spawn_executable, python_path},
      [:binary, {:packet, 4}, :exit_status,
       args: [worker_path]]
    )

    # Send connect command
    send_command(port, %{type: "connect", payload: connection_params(opts)})
    {:ok, %State{port: port, connected: false}}
  end
end
```

### Pattern 3: Synchronous GenServer.call for Queries

**What:** `execute_statement/4` does a `GenServer.call(pid, {:execute, sql, params}, timeout)`. The GenServer sends the command to the Port and waits for the response in `handle_info/2` (Port messages arrive as `{port, {:data, binary}}`). Use `{:noreply, state}` from `handle_call` and `GenServer.reply/2` from `handle_info` to bridge the async Port messages with sync call semantics.

**Why:** DBConnection expects synchronous responses from transport operations. The Port is inherently async (message-based), so the GenServer bridges this gap.

```elixir
def handle_call({:execute, sql, params, opts}, from, %{port: port} = state) do
  id = generate_request_id()
  send_command(port, %{id: id, type: "execute", payload: %{sql: sql, params: params}})
  {:noreply, %{state | pending_request: {id, from}}}
end

def handle_info({port, {:data, data}}, %{port: port, pending_request: {id, from}} = state) do
  response = Jason.decode!(data)
  ^id = response["id"]  # Assert request ID matches
  result = decode_response(response)
  GenServer.reply(from, result)
  {:noreply, %{state | pending_request: nil}}
end
```

### Pattern 4: Separate Protocol Module (Pure Functions)

**What:** Keep JSON encoding/decoding in a pure `SnowflexDev.Protocol` module with no side effects. The Transport calls `Protocol.encode_request/1` and `Protocol.decode_response/1`.

**Why:** This is the pattern MyXQL uses (`MyXQL.Messages` for encoding/decoding, `MyXQL.Protocol` for side effects). Pure encoding functions are trivially testable without needing a real Port or Python process.

**Confidence: HIGH** -- Recommended pattern from Dashbit's MyXQL blog series.

### Pattern 5: Result Format Parity with Snowflex

**What:** `SnowflexDev.Result` must have the exact same struct shape as `Snowflex.Result` -- same field names, same types, same defaults. The Python worker must return data in a format that maps cleanly to this struct.

**Why:** Consuming apps expect `%{columns: [...], rows: [[...], ...], num_rows: N}`. If the shape differs, Ecto decoding breaks.

```elixir
defmodule SnowflexDev.Result do
  defstruct columns: nil,
            rows: nil,
            num_rows: 0,
            metadata: [],
            messages: [],
            query: nil,
            query_id: nil,
            request_id: nil,
            sql_state: nil
end
```

## Anti-Patterns to Avoid

### Anti-Pattern 1: Using :spawn Instead of :spawn_executable

**What:** `Port.open({:spawn, "python3 worker.py"}, opts)` uses the shell to parse the command.
**Why bad:** Shell interpretation introduces security risks, platform-dependent behavior, and breaks `{:packet, 4}` on some systems because a shell process sits between Erlang and Python.
**Instead:** Always use `{:spawn_executable, path}` with explicit `args: [...]`. This directly execs the process.

### Anti-Pattern 2: Line-Based Protocol (Newline Delimited JSON)

**What:** Using `{:line, max_length}` or manual newline splitting for message framing.
**Why bad:** JSON payloads containing newlines in string values break the framing. Max line length limits are fragile. Large result sets exceed line buffers.
**Instead:** `{:packet, 4}` gives you up to 4GB per message with zero ambiguity.

### Anti-Pattern 3: Multiple Concurrent Requests per Port

**What:** Sending multiple queries to a single Python process before the first completes.
**Why bad:** `snowflake-connector-python` cursors are not thread-safe within a single connection. Even with request IDs, the Python process would need async handling which adds complexity.
**Instead:** One Port = one Python process = one active query at a time. DBConnection's pool handles concurrency by managing multiple connections (each with its own Port/Python process).

### Anti-Pattern 4: Trapping Exits in the Transport GenServer

**What:** Using `Process.flag(:trap_exit, true)` in the Transport GenServer to catch Port crashes.
**Why bad:** DBConnection already handles worker process failures. If you trap exits, you must manually handle every exit reason and risk masking real crashes. Snowflex's `Connection` module traps exits (it's the DBConnection process), but the transport GenServer should not.
**Instead:** Let the Transport GenServer crash when the Port dies. DBConnection will detect the disconnect via `{:EXIT, ...}` and handle reconnection through its pool.

### Anti-Pattern 5: Bundling Python in the Hex Package

**What:** Shipping the Python venv or snowflake-connector-python wheel inside the Elixir package.
**Why bad:** Python packages are platform-specific (wheels for macOS vs Linux, x86 vs ARM). Hex packages have size limits. Venvs are not portable across machines.
**Instead:** Ship only the Python worker script. `mix snowflex_dev.setup` creates the venv and pip installs at setup time on the target machine.

## Supervision Tree Design

```
SnowflexDev.Application
  |
  +-- SnowflexDev.Supervisor (one_for_one)
        |
        +-- Task.Supervisor (name: SnowflexDev.TaskSupervisor)
```

**Note:** The Transport GenServer processes are NOT direct children of the application supervisor. They are managed by DBConnection's pool. Here is the full lifecycle:

1. `SnowflexDev.Ecto.Adapter.Connection.child_spec/1` returns `DBConnection.child_spec(SnowflexDev.Connection, opts)`
2. Ecto starts this child_spec under the Repo's supervision tree
3. DBConnection pool creates N connections (configurable via `pool_size`)
4. Each connection calls `SnowflexDev.Connection.connect/1`
5. `connect/1` calls `Transport.Port.start_link/1`
6. Transport GenServer opens Port to Python process

```
MyApp.Supervisor
  |
  +-- MyApp.Repo (Ecto Repo)
        |
        +-- DBConnection.ConnectionPool
              |
              +-- Connection 1 (SnowflexDev.Connection state)
              |     +-- Transport.Port GenServer (pid in state)
              |           +-- Port -> Python process 1
              |
              +-- Connection 2
              |     +-- Transport.Port GenServer
              |           +-- Port -> Python process 2
              |
              +-- Connection N ...
```

**Pool size consideration:** Each connection spawns a Python process (~50-100MB RSS for snowflake-connector-python). Default `pool_size: 2` is sensible for dev. Document that each pool connection = one Python process.

## Suggested Build Order

Components should be built in this order based on dependencies:

### Phase 1: Python Worker + Protocol Layer (Foundation)

Build the Python worker script and the Elixir Protocol module together. These are the contract between the two languages and everything else depends on them.

- `snowflex_dev_worker.py` -- stdin/stdout message loop, connect, execute, ping, disconnect commands
- `SnowflexDev.Protocol` -- JSON encode/decode (pure functions)
- `SnowflexDev.Result` -- result struct (copy from Snowflex)
- `SnowflexDev.Error` -- error struct (copy from Snowflex)

**Test strategy:** Unit test Protocol encoding/decoding. Integration test the Python worker directly by piping JSON through it.

### Phase 2: Transport GenServer (Port Management)

Wrap the Python worker in an Elixir GenServer that manages the Port lifecycle.

- `SnowflexDev.Transport` -- behaviour definition
- `SnowflexDev.Transport.Port` -- GenServer implementation
- Port open/close lifecycle
- Command send/receive with `{:packet, 4}`
- Timeout handling (GenServer.call timeout maps to query timeout)
- Port crash handling (let it crash, GenServer terminates)

**Test strategy:** Start a real Port to the Python worker, send commands, verify responses. Test crash recovery by killing the Python process.

**Depends on:** Phase 1 (Protocol, worker script)

### Phase 3: DBConnection Adapter

Implement the DBConnection behaviour, connecting the transport to Ecto's expectations.

- `SnowflexDev.Connection` -- DBConnection callbacks
- `SnowflexDev.Query` -- DBConnection.Query protocol implementation
- Connection state management
- Ping implementation (periodic health check via "SELECT 1")

**Depends on:** Phase 2 (Transport)

### Phase 4: Ecto Adapter Layer

Wire everything together so `Ecto.Repo` works.

- `SnowflexDev` -- Ecto.Adapter behaviours (copy pattern from Snowflex)
- `SnowflexDev.Ecto.Adapter.Connection` -- SQL.Connection behaviour
- SQL generation (reuse Snowflex's SQL generation if possible, or minimal Snowflake SQL dialect)
- Type loaders/dumpers matching Snowflex's

**Depends on:** Phase 3 (DBConnection)

### Phase 5: Setup Tooling + Polish

- `Mix.Tasks.SnowflexDev.Setup` -- venv creation, pip install
- `SnowflexDev.Application` -- supervision tree
- Python path discovery (venv python vs system python)
- Documentation, config examples

**Depends on:** Phases 1-4

## Key Design Decisions

### Why {:packet, 4} Over Newline-Delimited JSON

Newline-delimited JSON (NDJSON) is simpler conceptually but fails when result sets contain string values with embedded newlines. `{:packet, 4}` provides guaranteed message framing at the OS level with zero application-layer parsing. Both Erlang and Python handle the 4-byte header in ~3 lines of code. No downside.

### Why GenServer.call + reply-from-handle_info Over Synchronous Port

An alternative is blocking in `handle_call` waiting for Port data. But Port messages arrive asynchronously as Erlang messages to the owning process. Blocking in `handle_call` with `receive` would bypass the GenServer message queue and risk message ordering bugs. The `{:noreply, ...}` + `GenServer.reply/2` pattern is the idiomatic way to bridge async messages with sync calls.

### Why One Python Process Per Connection (Not Multiplexed)

DBConnection pool manages concurrency by having multiple connections. Each connection owns one Port to one Python process. This means:
- No concurrency bugs in Python (single-threaded, one cursor at a time)
- Clean crash isolation (one Python crash = one connection lost, pool replaces it)
- Simple protocol (no need for multiplexing, request queuing, etc.)
- Memory cost is acceptable for dev (2-5 Python processes at ~50-100MB each)

### Why Reuse Snowflex's SQL Generation

Snowflex's `Ecto.Adapter.Connection` module generates Snowflake-dialect SQL (e.g., `QUALIFY`, `FLATTEN`, Snowflake-specific type casting). SnowflexDev needs identical SQL generation. Options:
1. **Copy the module** -- works but creates maintenance burden
2. **Depend on Snowflex** -- adds a runtime dep on the production library
3. **Extract shared SQL module** -- cleanest but requires upstream changes

Recommendation: Start with option 1 (copy), evaluate option 3 once the adapter is proven.

## Scalability Considerations

| Concern | Dev use (1-5 users) | Notes |
|---------|---------------------|-------|
| Memory per connection | ~50-100MB (Python process) | Acceptable for dev. Document pool_size impact. |
| Connection startup time | 2-5 seconds (Python + SSO) | First connection triggers browser auth. Subsequent connections reuse cached token. |
| Query latency | ~50-200ms overhead vs direct | JSON serialization + Port roundtrip. Negligible for dev. |
| Concurrent queries | Limited by pool_size | Default pool_size: 2 is fine for dev. |
| Result set size | Limited by memory (JSON in memory) | Large result sets may need streaming in future. V1 loads full result into memory. |

## Sources

- Snowflex source code (`lib/snowflex/connection.ex`, `lib/snowflex/transport.ex`, `lib/snowflex/transport/http.ex`) -- direct inspection, HIGH confidence
- [Port documentation (Elixir)](https://hexdocs.pm/elixir/Port.html) -- `{:packet, 4}`, `:spawn_executable`, message format -- HIGH confidence
- [DBConnection behaviour (hex.pm)](https://hexdocs.pm/db_connection/DBConnection.html) -- callback requirements, pool architecture -- HIGH confidence
- [Building a new MySQL adapter for Ecto, Part III (Dashbit)](https://dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii-dbconnection-integration) -- DBConnection implementation patterns, Messages/Protocol separation -- HIGH confidence
- [Managing External Commands in Elixir with Ports](https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/) -- GenServer + Port wrapping patterns -- MEDIUM confidence
- [The Erlangelist: Outside Elixir](https://www.theerlangelist.com/article/outside_elixir) -- Port communication patterns, `{:packet, 4}` usage -- MEDIUM confidence
- [Snowflake Python Connector: Connecting](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect) -- `externalbrowser` authenticator usage -- HIGH confidence
- [Interoperability in 2025 (elixir-lang.org)](https://elixir-lang.org/blog/2025/08/18/interop-and-portability/) -- Current Elixir interop landscape -- MEDIUM confidence
