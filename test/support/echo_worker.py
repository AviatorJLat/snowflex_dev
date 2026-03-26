#!/usr/bin/env python3
"""Echo worker for testing Transport GenServer without Snowflake.

Speaks the same {:packet, 4} JSON protocol as the real worker but returns
canned responses. Supports connect, execute, ping, and disconnect commands.
"""
import sys
import struct
import json

# CRITICAL: Same stdout isolation as the real worker.
sys.stdout = sys.stderr

PROTO_OUT = sys.__stdout__.buffer
PROTO_IN = sys.stdin.buffer


def read_message():
    """Read a {:packet, 4} framed message from stdin."""
    header = PROTO_IN.read(4)
    if len(header) < 4:
        return None

    length = struct.unpack(">I", header)[0]
    data = b""
    while len(data) < length:
        chunk = PROTO_IN.read(length - len(data))
        if not chunk:
            return None
        data += chunk

    return json.loads(data)


def write_message(msg):
    """Write a {:packet, 4} framed message to stdout."""
    data = json.dumps(msg).encode("utf-8")
    header = struct.pack(">I", len(data))
    PROTO_OUT.write(header + data)
    PROTO_OUT.flush()


def handle_connect(request_id, _payload):
    write_message({
        "id": request_id,
        "status": "ok",
        "payload": {"message": "connected"},
    })


def handle_execute(request_id, payload):
    sql = payload.get("sql", "")

    if sql == "SELECT 1":
        write_message({
            "id": request_id,
            "status": "ok",
            "payload": {
                "columns": ["1"],
                "rows": [[1]],
                "num_rows": 1,
                "metadata": {"1": {"type_code": 0, "scale": 0, "precision": 1, "null_ok": False}},
                "query_id": "test-query-id-001",
            },
        })

    elif sql == "SELECT typed":
        write_message({
            "id": request_id,
            "status": "ok",
            "payload": {
                "columns": ["num", "name", "created", "active"],
                "rows": [["42", "Alice", "2024-01-15", "true"]],
                "num_rows": 1,
                "metadata": {
                    "num": {"type_code": 0, "scale": 0, "precision": 10, "null_ok": False},
                    "name": {"type_code": 2, "scale": 0, "precision": 0, "null_ok": True},
                    "created": {"type_code": 3, "scale": 0, "precision": 0, "null_ok": True},
                    "active": {"type_code": 13, "scale": 0, "precision": 0, "null_ok": False},
                },
                "query_id": "test-query-id-typed",
            },
        })

    elif sql == "SELECT chunked":
        # Chunked start
        write_message({
            "id": request_id,
            "status": "ok",
            "chunked": True,
            "payload": {
                "columns": ["n"],
                "total_rows": 3,
                "metadata": {"n": {"type_code": 0, "scale": 0, "precision": 10, "null_ok": False}},
                "query_id": "test-query-id-chunked",
            },
        })
        # Chunk 0
        write_message({
            "id": request_id,
            "status": "chunk",
            "payload": {
                "rows": [[1], [2]],
                "chunk_index": 0,
            },
        })
        # Chunk 1
        write_message({
            "id": request_id,
            "status": "chunk",
            "payload": {
                "rows": [[3]],
                "chunk_index": 1,
            },
        })
        # Done
        write_message({
            "id": request_id,
            "status": "done",
            "payload": {"chunks_sent": 2},
        })

    elif sql == "SELECT error":
        write_message({
            "id": request_id,
            "status": "error",
            "payload": {
                "message": "test error",
                "code": "42000",
                "sql_state": "42000",
            },
        })

    elif sql == "SELECT slow":
        # Just respond normally -- used for crash-during-pending tests
        import time
        time.sleep(10)
        write_message({
            "id": request_id,
            "status": "ok",
            "payload": {
                "columns": ["1"],
                "rows": [[1]],
                "num_rows": 1,
                "metadata": {"1": {"type_code": 0, "scale": 0, "precision": 1, "null_ok": False}},
                "query_id": "test-query-id-slow",
            },
        })

    else:
        # Default: echo back the SQL as a single-row result
        write_message({
            "id": request_id,
            "status": "ok",
            "payload": {
                "columns": ["result"],
                "rows": [[sql]],
                "num_rows": 1,
                "metadata": {"result": {"type_code": 2, "scale": 0, "precision": 0, "null_ok": True}},
                "query_id": "test-query-id-echo",
            },
        })


def handle_ping(request_id):
    write_message({
        "id": request_id,
        "status": "ok",
        "payload": {"message": "pong"},
    })


def handle_disconnect(request_id):
    write_message({
        "id": request_id,
        "status": "ok",
        "payload": {"message": "disconnected"},
    })


def main():
    while True:
        msg = read_message()
        if msg is None:
            sys.exit(0)

        request_id = msg.get("id", "unknown")
        msg_type = msg.get("type")

        if msg_type == "connect":
            handle_connect(request_id, msg.get("payload", {}))
        elif msg_type == "execute":
            handle_execute(request_id, msg.get("payload", {}))
        elif msg_type == "ping":
            handle_ping(request_id)
        elif msg_type == "disconnect":
            handle_disconnect(request_id)
        else:
            write_message({
                "id": request_id,
                "status": "error",
                "payload": {
                    "message": f"Unknown command: {msg_type}",
                    "code": "ECHO_001",
                },
            })


if __name__ == "__main__":
    main()
