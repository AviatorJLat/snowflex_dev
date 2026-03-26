#!/usr/bin/env python3
"""SnowflexDev worker -- Erlang Port bridge to Snowflake via snowflake-connector-python."""
import sys
import os
import struct
import json
import threading
import logging
import time

# CRITICAL: Redirect stdout to stderr BEFORE importing snowflake.connector.
# Any library print() would corrupt the {:packet, 4} binary protocol.
sys.stdout = sys.stderr

# Now safe to import libraries that might print to stdout
import snowflake.connector
snowflake.connector.paramstyle = 'qmark'

# Configure snowflake connector logging to stderr (which stdout now points to)
logging.getLogger("snowflake.connector").setLevel(logging.WARNING)

# Protocol I/O constants
PROTO_OUT = sys.__stdout__.buffer  # Raw binary stdout for protocol
PROTO_IN = sys.stdin.buffer        # Raw binary stdin for protocol
CHUNK_SIZE = 1000                  # Rows per chunk for large result sets


def read_message():
    """Read a {:packet, 4} framed message from stdin.

    Returns parsed JSON dict, or None on EOF.
    """
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
    """Write a {:packet, 4} framed message to stdout.

    Concatenates header + data into a single write() call to avoid interleaving.
    """
    data = json.dumps(msg, default=str).encode("utf-8")
    header = struct.pack(">I", len(data))
    PROTO_OUT.write(header + data)
    PROTO_OUT.flush()


def build_metadata(description):
    """Build metadata dict from cursor.description (PEP 249 7-tuples).

    Returns dict mapping column_name -> type info.
    """
    if description is None:
        return {}

    metadata = {}
    for col in description:
        name = col[0]
        type_code = col[1]
        # Convert type_code to int if it's a custom Snowflake type object
        try:
            type_code_int = int(type_code)
        except (TypeError, ValueError):
            type_code_int = str(type_code)

        metadata[name] = {
            "type_code": type_code_int,
            "display_size": col[2],
            "internal_size": col[3],
            "precision": col[4],
            "scale": col[5],
            "null_ok": col[6],
        }
    return metadata


def serialize_rows(rows):
    """Convert list of tuples to list of lists (tuples are not JSON-serializable).

    json.dumps(default=str) in write_message handles Decimal, datetime, etc.
    """
    return [list(row) for row in rows]


def execute_query(conn, request_id, sql, params):
    """Execute a SQL query and send results back via the protocol.

    For small results (<= CHUNK_SIZE rows), sends a single response.
    For large results, sends chunked responses to prevent pipe buffer issues.
    """
    cursor = conn.cursor()
    try:
        if params:
            cursor.execute(sql, params)
        else:
            cursor.execute(sql)

        if cursor.description is None:
            # DDL/DML with no result set
            write_message({
                "id": request_id,
                "status": "ok",
                "payload": {
                    "columns": None,
                    "rows": [],
                    "num_rows": cursor.rowcount,
                    "metadata": {},
                    "query_id": cursor.sfqid,
                },
            })
            return

        columns = [desc[0] for desc in cursor.description]
        metadata = build_metadata(cursor.description)
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
                    "metadata": metadata,
                    "query_id": cursor.sfqid,
                },
            })
        else:
            # Chunked response
            write_message({
                "id": request_id,
                "status": "ok",
                "chunked": True,
                "payload": {
                    "columns": columns,
                    "total_rows": num_rows,
                    "metadata": metadata,
                    "query_id": cursor.sfqid,
                },
            })

            for i in range(0, num_rows, CHUNK_SIZE):
                chunk = rows[i : i + CHUNK_SIZE]
                write_message({
                    "id": request_id,
                    "status": "chunk",
                    "payload": {
                        "rows": serialize_rows(chunk),
                        "chunk_index": i // CHUNK_SIZE,
                    },
                })

            write_message({
                "id": request_id,
                "status": "done",
                "payload": {
                    "chunks_sent": (num_rows + CHUNK_SIZE - 1) // CHUNK_SIZE,
                },
            })
    finally:
        cursor.close()


def stdin_monitor_ppid():
    """Exit if parent process dies. Prevents zombie Python processes."""
    original_ppid = os.getppid()
    while True:
        time.sleep(1)
        if os.getppid() != original_ppid:
            os._exit(1)


def main():
    """Main command loop. Reads framed JSON commands and dispatches handlers."""
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
                write_message({
                    "id": request_id,
                    "status": "ok",
                    "payload": {"message": "connected"},
                })

            elif msg_type == "execute":
                if conn is None:
                    write_message({
                        "id": request_id,
                        "status": "error",
                        "payload": {
                            "message": "Not connected",
                            "code": "SNOWFLEX_DEV_001",
                        },
                    })
                    continue
                execute_query(
                    conn,
                    request_id,
                    msg["payload"]["sql"],
                    msg["payload"].get("params"),
                )

            elif msg_type == "ping":
                if conn is None:
                    write_message({
                        "id": request_id,
                        "status": "error",
                        "payload": {
                            "message": "Not connected",
                            "code": "SNOWFLEX_DEV_001",
                        },
                    })
                    continue
                cursor = conn.cursor()
                cursor.execute("SELECT 1")
                cursor.close()
                write_message({
                    "id": request_id,
                    "status": "ok",
                    "payload": {"message": "pong"},
                })

            elif msg_type == "disconnect":
                if conn:
                    conn.close()
                    conn = None
                write_message({
                    "id": request_id,
                    "status": "ok",
                    "payload": {"message": "disconnected"},
                })

            else:
                write_message({
                    "id": request_id,
                    "status": "error",
                    "payload": {
                        "message": f"Unknown command: {msg_type}",
                        "code": "SNOWFLEX_DEV_002",
                    },
                })

        except snowflake.connector.errors.ProgrammingError as e:
            write_message({
                "id": request_id,
                "status": "error",
                "payload": {
                    "message": str(e),
                    "code": str(e.errno),
                    "sql_state": e.sqlstate,
                },
            })
        except snowflake.connector.errors.DatabaseError as e:
            write_message({
                "id": request_id,
                "status": "error",
                "payload": {
                    "message": str(e),
                    "code": str(e.errno),
                    "sql_state": getattr(e, "sqlstate", None),
                },
            })
        except Exception as e:
            write_message({
                "id": request_id,
                "status": "error",
                "payload": {
                    "message": str(e),
                    "code": "SNOWFLEX_DEV_999",
                },
            })


if __name__ == "__main__":
    monitor = threading.Thread(target=stdin_monitor_ppid, daemon=True)
    monitor.start()
    main()
