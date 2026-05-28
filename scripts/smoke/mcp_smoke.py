#!/usr/bin/env python3
"""MCP stdio smoke test.

Launches a plugin binary, performs MCP `initialize` + `tools/list` over
stdio, and asserts the plugin speaks the protocol and exposes ≥1 tool.
Cross-platform (CPython 3.8+). No third-party deps.

Exit codes:
  0   success — initialize + tools/list both returned valid responses
  1   protocol violation (malformed JSON / missing field / no tools)
  2   timeout
  3   subprocess crashed / exited before handshake
  4   usage error
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


TIMEOUT_SECONDS = 60.0
PROTOCOL_VERSION = "2024-11-05"
# 60s default: plugins that embed a runtime (e.g. cad's PBS python bundle)
# extract on first start, which can take 20-40s on slow disks (Windows).
# Scansort + presentation start fast (<2s) and are unaffected. Override
# with PLUGIN_SMOKE_TIMEOUT_SECONDS env var if needed.
import os as _os
TIMEOUT_SECONDS = float(_os.getenv("PLUGIN_SMOKE_TIMEOUT_SECONDS", TIMEOUT_SECONDS))


def fail(code: int, msg: str) -> "None":
    print(f"SMOKE FAIL ({code}): {msg}", file=sys.stderr)
    sys.exit(code)


def send(proc: subprocess.Popen, payload: dict) -> None:
    line = json.dumps(payload) + "\n"
    assert proc.stdin is not None
    proc.stdin.write(line.encode("utf-8"))
    proc.stdin.flush()


def recv(proc: subprocess.Popen, deadline: float) -> dict:
    assert proc.stdout is not None
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail(2, "timeout waiting for response")
        line_bytes = proc.stdout.readline()
        if not line_bytes:
            rc = proc.poll()
            fail(3, f"subprocess closed stdout (exit={rc})")
        line = line_bytes.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            fail(1, f"non-JSON on stdout: {line[:200]!r} ({e})")
        if "id" in msg or "error" in msg or "result" in msg:
            return msg
        # Notification (no id) — skip, keep reading.


def kill_after(proc: subprocess.Popen, seconds: float) -> threading.Timer:
    def _kill():
        if proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
    t = threading.Timer(seconds, _kill)
    t.daemon = True
    t.start()
    return t


def main(argv: list) -> int:
    if len(argv) < 2:
        print(
            "usage: mcp_smoke.py <plugin-binary> [arg...]\n"
            "  Runs <plugin-binary> with optional args, performs MCP\n"
            "  initialize + tools/list over stdio, asserts ≥1 tool.",
            file=sys.stderr,
        )
        return 4
    binary = Path(argv[1])
    if not binary.exists():
        fail(4, f"binary not found: {binary}")
    if not os.access(binary, os.X_OK) and os.name != "nt":
        fail(4, f"binary not executable: {binary}")

    extra_args = argv[2:]
    cmd = [str(binary)] + extra_args
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    # Drain stderr concurrently into a bounded list so a chatty plugin
    # cannot deadlock by filling the pipe buffer (~64KB). On failure the
    # captured tail is printed; on success it's discarded.
    stderr_lines: list = []
    def _drain_stderr():
        assert proc.stderr is not None
        for raw in iter(proc.stderr.readline, b""):
            if len(stderr_lines) < 200:
                stderr_lines.append(raw.decode("utf-8", errors="replace").rstrip())
    drainer = threading.Thread(target=_drain_stderr, daemon=True)
    drainer.start()

    watchdog = kill_after(proc, TIMEOUT_SECONDS + 2.0)
    deadline = time.monotonic() + TIMEOUT_SECONDS

    try:
        # 1) initialize request
        send(proc, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mcp_smoke", "version": "0.0"},
            },
        })
        init_resp = recv(proc, deadline)
        if init_resp.get("id") != 1:
            fail(1, f"initialize: id mismatch ({init_resp.get('id')!r})")
        if "error" in init_resp:
            fail(1, f"initialize: server error: {init_resp['error']!r}")
        result = init_resp.get("result")
        if not isinstance(result, dict):
            fail(1, f"initialize: missing/invalid result")
        for field in ("protocolVersion", "capabilities"):
            if field not in result:
                fail(1, f"initialize: result missing {field!r}")
        # Server identity: accept either nested serverInfo (current spec) or
        # flat serverName/serverVersion (older spec). Smoke is protocol-level,
        # not field-shape police.
        server_info = result.get("serverInfo") or {
            "name": result.get("serverName"),
            "version": result.get("serverVersion"),
        }
        if not server_info.get("name"):
            fail(1, "initialize: no serverInfo.name or serverName")

        # 2) initialized notification
        send(proc, {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        })

        # 3) tools/list
        send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools_resp = recv(proc, deadline)
        if tools_resp.get("id") != 2:
            fail(1, f"tools/list: id mismatch ({tools_resp.get('id')!r})")
        if "error" in tools_resp:
            fail(1, f"tools/list: server error: {tools_resp['error']!r}")
        tools_result = tools_resp.get("result")
        if not isinstance(tools_result, dict):
            fail(1, "tools/list: missing/invalid result")
        tools = tools_result.get("tools")
        if not isinstance(tools, list):
            fail(1, "tools/list: tools is not a list")
        if len(tools) == 0:
            fail(1, "tools/list: zero tools exposed")

        elapsed = TIMEOUT_SECONDS - max(0, deadline - time.monotonic())
        server_name = server_info.get("name", "?")
        print(
            f"SMOKE OK: {binary.name} — server={server_name!r}, "
            f"tools={len(tools)}, elapsed={elapsed:.2f}s"
        )
        return 0
    finally:
        watchdog.cancel()
        if proc.poll() is None:
            try:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)
            except Exception:
                pass
        # If we failed, surface a tail of stderr — invaluable for debugging
        # CI failures where the binary printed an error before exiting.
        if sys.exc_info()[0] is SystemExit and stderr_lines:
            print("--- stderr (last 200 lines) ---", file=sys.stderr)
            for line in stderr_lines[-50:]:
                print(line, file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
