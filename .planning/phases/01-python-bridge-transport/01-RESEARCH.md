# Phase 1: Python Bridge & Transport - Research

**Researched:** 2026-03-26
**Domain:** Erlang Port IPC, Python subprocess management, JSON protocol design, GenServer transport layer
**Confidence:** HIGH

## Summary

Phase 1 establishes the foundational communication layer between Elixir and Python. This is the highest-risk phase because stdout corruption, buffer deadlocks, and zombie processes can silently break everything built on top. The core deliverables are: (1) a Python worker script that connects to Snowflake via `externalbrowser` SSO and speaks a `{:packet, 4}` length-prefixed JSON protocol over stdin/stdout, (2) a Protocol module with pure encoding/decoding functions, (3) a Transport GenServer that owns the Erlang Port and bridges async Port messages with synchronous GenServer.call semantics, and (4) chunked transfer for large result sets to prevent pipe buffer deadlocks.

All architectural decisions for this phase are locked by CLAUDE.md: Erlang Port (not Pythonx/ErlPort/NIFs), `{:packet, 4}` framing (not line-delimited), JSON serialization (not MessagePack/protobuf), one Port per connection (not multiplexed). The research focus is therefore on implementation specifics, not technology selection.

**Primary recommendation:** Build bottom-up -- Python worker first, then Protocol module, then Transport GenServer. Each layer is independently testable. Get the Python worker fully functional and tested via direct pipe communication before wrapping it in a GenServer.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PORT-01 | Elixir communicates with Python via Erlang Port using `{:packet, 4}` length-prefixed JSON protocol | Port protocol design section; Python `struct.pack('>I', len)` framing; Port.open options |
| PORT-02 | Python worker connects to Snowflake via `snowflake-connector-python` with `externalbrowser` SSO | Python worker structure; `snowflake.connector.connect(authenticator='externalbrowser')` pattern; auth timeout handling |
| PORT-03 | Python stdout redirected to stderr on startup; protocol uses `sys.__stdout__.buffer` exclusively | Stdout corruption prevention pattern; Python worker initialization code |
| PORT-04 | Python process monitors stdin for EOF and self-terminates to prevent zombie processes | Zombie process prevention; stdin-monitoring thread pattern |
| PORT-05 | Large result sets transferred in chunks to prevent memory exhaustion | Chunked transfer protocol design; pipe buffer deadlock prevention (65KB ceiling) |
| TRANS-01 | Transport GenServer manages Port lifecycle (open, monitor, restart on crash) | Transport GenServer pattern; Port ownership and crash handling |
| TRANS-02 | Synchronous command/response flow -- GenServer.call blocks until Python returns result | `{:noreply, state}` + `GenServer.reply/2` bridging pattern |
| TRANS-03 | Configurable connection parameters: account, user, warehouse, database, schema, role, authenticator | Connect command payload structure; opts passthrough |
| TRANS-04 | Connection timeout extended for SSO auth (browser popup may take 30+ seconds) | Extended login_timeout; separate auth-phase timeout from query timeout |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Erlang Port only** -- no Pythonx, ErlPort, NIFs, or TCP sockets
- **`{:packet, 4}` framing** -- no line-delimited, no `{:packet, 2}`
- **JSON serialization** -- `jason` (Elixir) + `json` stdlib (Python)
- **`:spawn_executable`** -- not `:spawn` (no shell interpretation)
- **One Port per DBConnection pool slot** -- no multiplexing
- **Python >= 3.9** -- snowflake-connector-python 3.12+ dropped 3.8
- **No `:stderr_to_stdout`** -- stderr must not corrupt the framed protocol
- **`python3 -u` flag** -- unbuffered stdout is non-negotiable
- **Process isolation** -- Python crash must not crash the BEAM

## Standard Stack

### Core (Phase 1 Only)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `jason` | ~> 1.4 (v1.4.4) | JSON encode/decode for Port protocol | Ubiquitous Elixir JSON lib. Used on both sides of the Port |
| `snowflake-connector-python` | >= 3.12, < 5.0 (v4.4.0) | Snowflake DB access with externalbrowser SSO | The entire reason this project exists |
| Python `struct` | stdlib | 4-byte length prefix read/write | Mirrors `{:packet, 4}` on the Python side |
| Python `json` | stdlib | JSON protocol handling | Matches Jason on the Elixir side |
| Python `threading` | stdlib | Stdin EOF monitoring thread | Zombie process prevention |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `nimble_options` | ~> 1.0 | Config validation for connection opts | Validate account, user, warehouse etc. at startup |

### Not Needed Yet (Phase 2+)

| Library | Phase | Purpose |
|---------|-------|---------|
| `db_connection` | Phase 2 | DBConnection behaviour |
| `ecto` / `ecto_sql` | Phase 3 | Ecto adapter layer |
| `telemetry` | Phase 4+ | Instrumentation |

## Architecture Patterns

### Recommended Project Structure (Phase 1 deliverables)

```
lib/
  snowflex_dev/
    protocol.ex          # Pure encode/decode functions (JSON <-> structs)
    result.ex            # Result struct (Snowflex-compatible shape)
    error.ex             # Error struct
    transport.ex         # Transport behaviour definition
    transport/
      port.ex            # GenServer wrapping Erlang Port
priv/
  python/
    snowflex_dev_worker.py  # Long-running Python worker
test/
  snowflex_dev/
    protocol_test.exs    # Unit tests for encode/decode
    transport/
      port_test.exs      # Integration tests with real Python process
```

### Pattern 1: Python Worker -- Stdout Capture and Protocol Isolation

**What:** On startup, the Python worker immediately redirects `sys.stdout` to `sys.stderr`, then uses `sys.__stdout__.buffer` exclusively for the binary protocol. This prevents any library (including snowflake-connector-python) from accidentally writing to the protocol channel.

**When to use:** Always. This is PORT-03.

```python
#!/usr/bin/env python3
"""snowflex_dev_worker.py"""
import sys
import struct
import json
import threading
import logging

# CRITICAL: Redirect stdout to stderr before importing anything else.
# Any library that prints to stdout would corrupt the {:packet, 4} protocol.
# After this, print() and sys.stdout.write() go to stderr (visible in BEAM logs).
# The binary protocol uses sys.__stdout__.buffer exclusively.
sys.stdout = sys.stderr

# Now safe to import libraries that might print
import snowflake.connector

# Configure snowflake connector logging to stderr (already redirected)
logging.getLogger('snowflake.connector').setLevel(logging.WARNING)

# The raw binary stdout for protocol communication
PROTO_OUT = sys.__stdout__.buffer
PROTO_IN = sys.stdin.buffer


def read_message():
    """Read a {:packet, 4} framed message from stdin."""
    header = PROTO_IN.read(4)
    if len(header) < 4:
        return None  # EOF - port closed
    length = struct.unpack(">I", header)[0]
    data = b""
    while len(data) < length:
        chunk = PROTO_IN.read(length - len(data))
        if not chunk:
            return None  # EOF mid-message
        data += chunk
    return json.loads(data)


def write_message(msg):
    """Write a {:packet, 4} framed message to stdout."""
    data = json.dumps(msg, default=str).encode("utf-8")
    PROTO_OUT.write(struct.pack(">I", len(data)))
    PROTO_OUT.write(data)
    PROTO_OUT.flush()  # CRITICAL: flush after every write
```

**Source:** Elixir Port docs, Erlang open_port/2 docs, Python buffering behavior (bugs.python.org/issue4705)

### Pattern 2: Stdin EOF Monitor Thread (Zombie Prevention)

**What:** A background thread continuously reads from stdin. When EOF is received (BEAM crashed or Port closed), it forcefully exits the Python process. This handles the case where the BEAM crashes without gracefully closing the Port.

**When to use:** Always. This is PORT-04.

```python
def stdin_monitor():
    """Monitor stdin for EOF and exit if the parent process dies."""
    # This runs in a background thread. The main thread uses PROTO_IN
    # for the message protocol. This thread detects when the pipe closes
    # unexpectedly (BEAM crash, kill -9, etc.)
    #
    # NOTE: We can't read from PROTO_IN here because the main loop does that.
    # Instead, we rely on the main loop's read_message() returning None on EOF.
    # This thread is a safety net: if the main loop is blocked on a Snowflake
    # query when EOF happens, this thread detects it.
    import select
    while True:
        # Use select to check if stdin has data/EOF without blocking the protocol
        try:
            readable, _, _ = select.select([sys.stdin.buffer], [], [], 1.0)
            if readable:
                # If select says stdin is readable but read returns empty, it's EOF
                peek = sys.stdin.buffer.read(0)  # Non-blocking check
                # On actual EOF, the main read_message will get it
                # But if main thread is blocked on Snowflake, we need a fallback
        except (ValueError, OSError):
            # stdin closed
            os._exit(1)


# Alternative simpler approach: check if parent PID has changed
import os

def stdin_monitor_ppid():
    """Exit if parent process dies (Unix-specific)."""
    original_ppid = os.getppid()
    while True:
        import time
        time.sleep(1)
        if os.getppid() != original_ppid:
            os._exit(1)
```

**Recommendation:** Use the PPID-monitoring approach for simplicity. On macOS/Linux, `os.getppid()` changes to 1 (init/launchd) when the parent dies. This is simpler and more reliable than trying to detect EOF on a shared stdin pipe.

**Source:** Elixir Forum zombie process discussions, Erlang core mailing list

### Pattern 3: Chunked Result Transfer (Pipe Buffer Safety)

**What:** For result sets exceeding a threshold (e.g., 1000 rows), Python sends results in chunks rather than one massive JSON blob. This prevents the 65KB OS pipe buffer from deadlocking.

**When to use:** When PORT-05 requires large result set support.

**Protocol:**

```json
// Single-shot response (small results, < threshold rows):
{"id": "req-1", "status": "ok", "payload": {"columns": [...], "rows": [...], "num_rows": 5, "metadata": {}}}

// Chunked response (large results):
{"id": "req-1", "status": "ok", "chunked": true, "payload": {"columns": [...], "total_rows": 50000, "metadata": {}}}
{"id": "req-1", "status": "chunk", "payload": {"rows": [[...], ...], "chunk_index": 0}}
{"id": "req-1", "status": "chunk", "payload": {"rows": [[...], ...], "chunk_index": 1}}
...
{"id": "req-1", "status": "done", "payload": {"chunks_sent": 50}}
```

**Why chunked and not streaming:** With `{:packet, 4}`, each JSON message is independently framed. The BEAM reads each framed message completely before delivering it. As long as no single message exceeds available memory, there is no deadlock. Chunking at 1000 rows per message keeps individual messages well under 1MB, far below any pipe buffer concern.

**Python side:**

```python
CHUNK_SIZE = 1000  # rows per chunk

def execute_query(conn, request_id, sql, params):
    cursor = conn.cursor()
    cursor.execute(sql, params)
    columns = [desc.name for desc in cursor.description]
    metadata = build_metadata(cursor.description)

    # Fetch all rows (for dev use, result sets are typically small)
    rows = cursor.fetchall()
    num_rows = len(rows)

    if num_rows <= CHUNK_SIZE:
        # Single-shot response
        write_message({
            "id": request_id,
            "status": "ok",
            "payload": {
                "columns": columns,
                "rows": serialize_rows(rows),
                "num_rows": num_rows,
                "metadata": metadata
            }
        })
    else:
        # Chunked response
        write_message({
            "id": request_id,
            "status": "ok",
            "chunked": True,
            "payload": {"columns": columns, "total_rows": num_rows, "metadata": metadata}
        })
        for i in range(0, num_rows, CHUNK_SIZE):
            chunk = rows[i:i + CHUNK_SIZE]
            write_message({
                "id": request_id,
                "status": "chunk",
                "payload": {"rows": serialize_rows(chunk), "chunk_index": i // CHUNK_SIZE}
            })
        write_message({
            "id": request_id,
            "status": "done",
            "payload": {"chunks_sent": (num_rows + CHUNK_SIZE - 1) // CHUNK_SIZE}
        })
    cursor.close()
```

**Elixir side (in Transport GenServer):**

```elixir
# handle_info for chunked responses
def handle_info({port, {:data, data}}, %{port: port, pending_request: {id, from, :chunking, acc}} = state) do
  response = Jason.decode!(data)
  ^id = response["id"]

  case response["status"] do
    "chunk" ->
      new_acc = %{acc | rows: acc.rows ++ response["payload"]["rows"]}
      {:noreply, %{state | pending_request: {id, from, :chunking, new_acc}}}

    "done" ->
      result = build_result(acc)
      GenServer.reply(from, {:ok, result})
      {:noreply, %{state | pending_request: nil}}
  end
end
```

**Source:** elixir-nodejs Issue #2 (65KB buffer limit), Erlang Port documentation

### Pattern 4: Transport GenServer -- Async Port with Sync Interface

**What:** The Transport GenServer owns the Port, sends commands via `Port.command/2`, and receives responses asynchronously via `handle_info/2`. It bridges this to synchronous `GenServer.call/3` using the `{:noreply, state}` + `GenServer.reply/2` pattern.

**When to use:** This IS the Transport implementation (TRANS-01, TRANS-02).

```elixir
defmodule SnowflexDev.Transport.Port do
  use GenServer

  defmodule State do
    @moduledoc false
    defstruct [:port, :python_path, :worker_path, :opts, :connected,
               :pending_request, :chunk_acc]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    python_path = resolve_python_path(opts)
    worker_path = Application.app_dir(:snowflex_dev, "priv/python/snowflex_dev_worker.py")

    port = Port.open(
      {:spawn_executable, String.to_charlist(python_path)},
      [:binary, {:packet, 4}, :exit_status, :use_stdio,
       args: ["-u", worker_path]]
    )

    # Send connect command with extended timeout for SSO
    connect_opts = Map.take(Map.new(opts), [
      :account, :user, :warehouse, :database, :schema, :role,
      :authenticator, :login_timeout
    ])

    id = generate_id()
    send_command(port, %{id: id, type: "connect", payload: connect_opts})

    # Wait for connect response synchronously in init
    # (extended timeout for SSO browser auth)
    login_timeout = Keyword.get(opts, :login_timeout, 300_000)
    receive do
      {^port, {:data, data}} ->
        response = Jason.decode!(data)
        case response["status"] do
          "ok" -> {:ok, %State{port: port, connected: true, opts: opts}}
          "error" -> {:stop, {:connect_failed, response["payload"]["message"]}}
        end

      {^port, {:exit_status, code}} ->
        {:stop, {:python_exit, code}}
    after
      login_timeout ->
        Port.close(port)
        {:stop, :connect_timeout}
    end
  end

  @impl true
  def handle_call({:execute, sql, params, opts}, from, %{port: port} = state) do
    id = generate_id()
    send_command(port, %{id: id, type: "execute", payload: %{sql: sql, params: params}})
    {:noreply, %{state | pending_request: {id, from}}}
  end

  def handle_call(:ping, from, %{port: port} = state) do
    id = generate_id()
    send_command(port, %{id: id, type: "ping", payload: %{}})
    {:noreply, %{state | pending_request: {id, from}}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, pending_request: {id, from}} = state) do
    response = Jason.decode!(data)
    ^id = response["id"]

    case response do
      %{"status" => "ok", "chunked" => true} ->
        # Start chunked accumulation
        acc = %{
          columns: response["payload"]["columns"],
          rows: [],
          total_rows: response["payload"]["total_rows"],
          metadata: response["payload"]["metadata"]
        }
        {:noreply, %{state | pending_request: {id, from, :chunking, acc}}}

      %{"status" => "ok"} ->
        result = build_result(response["payload"])
        GenServer.reply(from, {:ok, result})
        {:noreply, %{state | pending_request: nil}}

      %{"status" => "error"} ->
        error = build_error(response["payload"])
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_request: nil}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    # Python process exited. If there's a pending request, reply with error.
    if state.pending_request do
      {_id, from} = state.pending_request
      GenServer.reply(from, {:error, %SnowflexDev.Error{message: "Python process exited with code #{code}"}})
    end
    {:stop, {:python_exit, code}, %{state | port: nil, pending_request: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) when is_port(port) do
    # Send disconnect command, then close port
    send_command(port, %{id: generate_id(), type: "disconnect", payload: %{}})
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Private --

  defp send_command(port, command) do
    data = Jason.encode!(command)
    Port.command(port, data)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp resolve_python_path(opts) do
    Keyword.get_lazy(opts, :python_path, fn ->
      Path.join([File.cwd!(), "_snowflex_dev", "venv", "bin", "python3"])
    end)
  end
end
```

**Key design notes:**
- `init/1` performs connection synchronously with extended timeout (TRANS-04)
- Query execution is async Port message + sync GenServer.reply (TRANS-02)
- Port crash triggers `{:exit_status, code}` which stops the GenServer (TRANS-01)
- Connection params are passed through to Python worker (TRANS-03)

**Source:** Dashbit MyXQL blog series, tonyc Port GenServer patterns

### Pattern 5: Request/Response Correlation IDs

**What:** Every request includes a unique `id` field. Responses echo the same `id`. The GenServer asserts the ID matches before processing.

**When to use:** Always. Guards against response desync (stale data from previous queries after timeout/reconnect).

```elixir
# In handle_info, pattern match the ID
def handle_info({port, {:data, data}}, %{port: port, pending_request: {expected_id, from}} = state) do
  response = Jason.decode!(data)
  case response["id"] do
    ^expected_id ->
      # Process normally
      ...
    unexpected_id ->
      # Log warning and discard -- stale response from previous request
      Logger.warning("Discarding stale response #{unexpected_id}, expected #{expected_id}")
      {:noreply, state}
  end
end
```

### Anti-Patterns to Avoid

- **Using `:spawn` instead of `:spawn_executable`:** Shell interpretation breaks `{:packet, 4}` on some systems because a shell process sits between Erlang and Python.
- **Using `print()` or `sys.stdout.write()` in Python worker:** Corrupts the binary protocol. All output must go through `sys.__stdout__.buffer` with explicit length framing.
- **Using `:stderr_to_stdout`:** Mixes Python library logging into the protocol stream, corrupting framing.
- **Trapping exits in the Transport GenServer:** DBConnection handles worker failures. Let the Transport crash; DBConnection pool reconnects.
- **Blocking in `handle_call` with `receive`:** Bypasses the GenServer message queue. Use `{:noreply, state}` + `GenServer.reply/2`.
- **Multiple concurrent requests per Port:** Python connector cursors are not thread-safe within a single connection. One request at a time.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Message framing | Custom delimiter parsing | `{:packet, 4}` + `struct.pack('>I', len)` | Erlang handles reassembly; Python side is 3 lines |
| JSON serialization | Custom binary format | `jason` + Python `json` | Human-readable, debuggable, adequate performance for dev tool |
| SSO authentication | OAuth flow, token management | `snowflake-connector-python` `externalbrowser` | Python connector handles browser popup, SAML token, caching internally |
| Process cleanup on BEAM crash | Complex signal handling | PPID monitoring thread | `os.getppid()` changes when parent dies; 5 lines of Python |
| Connection pooling | Custom pool | DBConnection pool (Phase 2) | Battle-tested, handles checkout/checkin/reconnect |
| Request ID generation | UUID library | `:crypto.strong_rand_bytes(8) \|> Base.encode16` | Stdlib, unique enough for request correlation |

## Common Pitfalls

### Pitfall 1: Pipe Buffer Deadlock (65KB)

**What goes wrong:** Python writes a JSON response larger than the OS pipe buffer (~64KB). The write blocks. Elixir is waiting for the complete `{:packet, 4}` message. Both sides block forever.
**Why it happens:** OS pipe buffers are fixed at ~64KB. A SELECT returning hundreds of rows easily exceeds this when serialized as JSON.
**How to avoid:** Implement chunked transfer (Pattern 3). Keep individual messages under 64KB by chunking at ~1000 rows. The BEAM reassembles `{:packet, 4}` messages, but the Python side must not exceed the pipe buffer in a single `write()` call.
**Warning signs:** Small queries work, large queries hang. Python CPU at 0%.

### Pitfall 2: Python Stdout Buffering

**What goes wrong:** Python buffers stdout when not connected to a TTY (which is always the case with Ports). Responses sit in Python's buffer and never reach Elixir.
**Why it happens:** Python defaults to block-buffered stdout (~8KB) when piped.
**How to avoid:** Launch Python with `-u` flag (unbuffered). Use `sys.__stdout__.buffer` (binary mode). Call `.flush()` after every write. All three measures together.
**Warning signs:** First query works, second hangs. Adding `print()` debug statements "fixes" it.

### Pitfall 3: Zombie Python Processes

**What goes wrong:** If the BEAM crashes (OOM, kill -9), the Python process is not terminated. It becomes an orphan consuming memory and holding Snowflake sessions.
**Why it happens:** Ports close stdin on graceful shutdown only. Hard crashes leave the Python process alive.
**How to avoid:** PPID-monitoring background thread in Python. If `os.getppid()` changes from the original parent PID, call `os._exit(1)`.
**Warning signs:** `ps aux | grep snowflex_dev_worker` shows multiple processes.

### Pitfall 4: SSO Browser Auth Timeout

**What goes wrong:** `externalbrowser` SSO opens a browser and waits for the user to authenticate. Default timeouts (15s) are far too short. Connection fails, supervisor restarts, browser pops up again.
**Why it happens:** `snowflake.connector.connect()` blocks while waiting for SAML callback. Default timeout is inadequate for interactive auth.
**How to avoid:** Set `login_timeout=300` (seconds) in Python connector config. Set GenServer init timeout to match (300_000ms). Handle this in `init/1` with an explicit `receive` block and extended `after` timeout.
**Warning signs:** Multiple browser tabs opening. DBConnection errors during boot.

### Pitfall 5: Stdout Corruption from Python Libraries

**What goes wrong:** `snowflake-connector-python` or its dependencies write warnings/debug output to stdout, corrupting the `{:packet, 4}` binary protocol.
**Why it happens:** Python libraries commonly use `print()` for warnings. The connector's logging defaults may write to stdout.
**How to avoid:** Redirect `sys.stdout = sys.stderr` BEFORE importing snowflake.connector. Use `sys.__stdout__.buffer` for protocol output only. Set connector log level to WARNING or higher.
**Warning signs:** `Jason.DecodeError` on responses. Intermittent protocol failures.

## Code Examples

### Complete Python Worker Main Loop

```python
def main():
    conn = None

    while True:
        msg = read_message()
        if msg is None:
            # EOF -- port closed, exit cleanly
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
            sys.exit(0)

        request_id = msg.get("id", "unknown")
        msg_type = msg.get("type")

        try:
            if msg_type == "connect":
                payload = msg["payload"]
                conn = snowflake.connector.connect(
                    account=payload["account"],
                    user=payload["user"],
                    warehouse=payload.get("warehouse"),
                    database=payload.get("database"),
                    schema=payload.get("schema"),
                    role=payload.get("role"),
                    authenticator=payload.get("authenticator", "externalbrowser"),
                    login_timeout=payload.get("login_timeout", 300),
                    client_session_keep_alive=True,
                    client_store_temporary_credential=True,
                )
                write_message({"id": request_id, "status": "ok", "payload": {"message": "connected"}})

            elif msg_type == "execute":
                if conn is None:
                    write_message({"id": request_id, "status": "error",
                                   "payload": {"message": "Not connected", "code": "SNOWFLEX_DEV_001"}})
                    continue
                execute_query(conn, request_id, msg["payload"]["sql"], msg["payload"].get("params"))

            elif msg_type == "ping":
                if conn is None:
                    write_message({"id": request_id, "status": "error",
                                   "payload": {"message": "Not connected", "code": "SNOWFLEX_DEV_001"}})
                    continue
                cursor = conn.cursor()
                cursor.execute("SELECT 1")
                cursor.close()
                write_message({"id": request_id, "status": "ok", "payload": {"message": "pong"}})

            elif msg_type == "disconnect":
                if conn:
                    conn.close()
                    conn = None
                write_message({"id": request_id, "status": "ok", "payload": {"message": "disconnected"}})

            else:
                write_message({"id": request_id, "status": "error",
                               "payload": {"message": f"Unknown command: {msg_type}", "code": "SNOWFLEX_DEV_002"}})

        except snowflake.connector.errors.ProgrammingError as e:
            write_message({"id": request_id, "status": "error",
                           "payload": {"message": str(e), "code": str(e.errno), "sql_state": e.sqlstate}})
        except snowflake.connector.errors.DatabaseError as e:
            write_message({"id": request_id, "status": "error",
                           "payload": {"message": str(e), "code": str(e.errno), "sql_state": getattr(e, 'sqlstate', None)}})
        except Exception as e:
            write_message({"id": request_id, "status": "error",
                           "payload": {"message": str(e), "code": "SNOWFLEX_DEV_999"}})


if __name__ == "__main__":
    # Start PPID monitor thread
    monitor_thread = threading.Thread(target=stdin_monitor_ppid, daemon=True)
    monitor_thread.start()
    main()
```

### Protocol Module (Pure Functions)

```elixir
defmodule SnowflexDev.Protocol do
  @moduledoc "Encodes commands and decodes responses for the Port JSON protocol."

  def encode_connect(id, opts) do
    Jason.encode!(%{
      id: id,
      type: "connect",
      payload: %{
        account: opts[:account],
        user: opts[:user],
        warehouse: opts[:warehouse],
        database: opts[:database],
        schema: opts[:schema],
        role: opts[:role],
        authenticator: opts[:authenticator] || "externalbrowser",
        login_timeout: opts[:login_timeout] || 300
      }
    })
  end

  def encode_execute(id, sql, params) do
    Jason.encode!(%{id: id, type: "execute", payload: %{sql: sql, params: params}})
  end

  def encode_ping(id) do
    Jason.encode!(%{id: id, type: "ping", payload: %{}})
  end

  def encode_disconnect(id) do
    Jason.encode!(%{id: id, type: "disconnect", payload: %{}})
  end

  def decode_response(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"id" => id, "status" => "ok"} = resp} ->
        {:ok, id, resp["payload"]}

      {:ok, %{"id" => id, "status" => "ok", "chunked" => true} = resp} ->
        {:ok, id, :chunked_start, resp["payload"]}

      {:ok, %{"id" => id, "status" => "chunk"} = resp} ->
        {:ok, id, :chunk, resp["payload"]}

      {:ok, %{"id" => id, "status" => "done"} = resp} ->
        {:ok, id, :chunk_done, resp["payload"]}

      {:ok, %{"id" => id, "status" => "error"} = resp} ->
        {:error, id, resp["payload"]}

      {:error, reason} ->
        {:error, nil, %{"message" => "JSON decode failed: #{inspect(reason)}"}}
    end
  end
end
```

### Port.open Options Explanation

```elixir
Port.open(
  {:spawn_executable, String.to_charlist(python_path)},
  [
    :binary,        # Receive data as binaries (not charlists)
    {:packet, 4},   # 4-byte big-endian unsigned int length prefix
                    # BEAM auto-frames on send, auto-reassembles on receive
    :exit_status,   # Receive {port, {:exit_status, code}} when process exits
    :use_stdio,     # Default: use stdin/stdout for communication
    args: ["-u", worker_path]  # -u = unbuffered stdout
  ]
)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| ErlPort for Elixir-Python IPC | Raw Erlang Port (or Pythonx for non-pool use cases) | 2024-2025 | ErlPort unmaintained; raw Ports preferred |
| `{:packet, 2}` framing | `{:packet, 4}` framing | Always for non-trivial payloads | 64KB vs 4GB message limit |
| Line-delimited JSON | Length-prefixed binary framing | Standard practice | Avoids newline-in-payload bugs |
| Python 3.8 minimum | Python 3.9+ minimum | snowflake-connector-python 3.12 (2024) | 3.8 dropped from connector |

## Open Questions

1. **Exact chunk size threshold**
   - What we know: OS pipe buffer is ~64KB. Individual `{:packet, 4}` messages should stay well under this.
   - What's unclear: Optimal rows-per-chunk for typical Snowflake result sets. 1000 rows is a reasonable starting point.
   - Recommendation: Start with 1000 rows per chunk. Make it configurable via protocol options. Adjust based on testing.

2. **Python `struct.pack` atomicity with `{:packet, 4}`**
   - What we know: The BEAM's `{:packet, 4}` automatically prepends 4-byte length on sends via `Port.command/2`. On the Python side, we must manually write the 4-byte header + payload.
   - What's unclear: Whether Python's `write(header) + write(payload)` is atomic enough or if we need `write(header + payload)` as a single call.
   - Recommendation: Always concatenate header + payload and write as a single `buffer.write(header + data)` call to avoid interleaving. Follow with `flush()`.

3. **Token caching behavior across multiple Python processes**
   - What we know: snowflake-connector-python caches tokens in `~/.snowflake/`. `client_store_temporary_credential=True` enables this.
   - What's unclear: Whether a second Python process (pool_size > 1) can reuse the cached token without triggering another browser popup.
   - Recommendation: Default pool_size to 1 for this phase. Test multi-process token sharing in Phase 2.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3 | Python worker | Yes | 3.14.3 | -- |
| Elixir | Core runtime | Yes | 1.18.4-otp-27 | -- |
| Erlang/OTP | Port support | Yes | 27.2 | -- |
| pip | venv setup | Needs check | -- | `python3 -m ensurepip` |
| snowflake-connector-python | Snowflake access | Install via venv | -- | -- |

**Missing dependencies with no fallback:** None -- all core dependencies are available.

**Missing dependencies with fallback:** pip may need `ensurepip` if not bundled with Python 3.14. The `mix snowflex_dev.setup` task (Phase 4) handles this, but for Phase 1 testing, manual venv creation may be needed.

## Sources

### Primary (HIGH confidence)
- Elixir Port docs (https://hexdocs.pm/elixir/Port.html) -- Port.open options, message format
- Erlang open_port/2 (https://www.erlang.org/doc/apps/erts/erlang.html#open_port/2) -- `{:packet, 4}` framing specification
- Snowflake Python Connector API (https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-api) -- cursor.execute, cursor.description, type codes
- Snowflake Python Connector connect docs (https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect) -- externalbrowser authenticator
- Dashbit MyXQL blog series (https://dashbit.co/blog/building-a-new-mysql-adapter-for-ecto-part-iii-dbconnection-integration) -- DBConnection pattern, Messages/Protocol separation
- Project research (`.planning/research/ARCHITECTURE.md`, `PITFALLS.md`, `FEATURES.md`) -- prior domain research

### Secondary (MEDIUM confidence)
- tonyc Port GenServer patterns (https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/) -- GenServer + Port wrapping
- Stuart Engineering Elixir+Python (https://medium.com/stuart-engineering/how-we-use-python-within-elixir-486eb4d266f9) -- production Port pattern
- The Erlangelist: Outside Elixir (https://www.theerlangelist.com/article/outside_elixir) -- Port patterns

### Tertiary (LOW confidence)
- elixir-nodejs Issue #2 (https://github.com/revelrylabs/elixir-nodejs/issues/2) -- pipe buffer limit evidence (used for context, not direct API)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries/versions verified from hex.pm and pypi.org in prior research
- Architecture: HIGH -- patterns sourced from Dashbit blog, Snowflex source, Erlang/Elixir official docs
- Pitfalls: HIGH -- 5 critical pitfalls documented with reproduction steps and prevention strategies from multiple sources

**Research date:** 2026-03-26
**Valid until:** 2026-04-26 (stable domain -- Erlang Ports and Python subprocess management are mature)
