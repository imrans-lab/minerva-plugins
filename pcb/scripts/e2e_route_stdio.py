#!/usr/bin/env python3
"""Real-worker subprocess bridge for Godot E2E tests (WC-3, docket 019f6a894a37).

Godot's OS.execute cannot pipe stdin to a child process, but the pcb-plugin Go
binary's MCP server speaks newline-delimited JSON-RPC over stdio and forwards
"pcb.route" tool calls to the real Python pcb_worker subprocess (see
pcb/main.go dispatch / initWorker). This script is the missing stdin-capable
hop: it drives the two-message handshake (initialize, tools/call pcb.route)
against the REAL binary + REAL worker, and prints ONLY the worker's route
result envelope (one JSON line) to its own stdout — which Godot's
OS.execute(..., output, true) captures painlessly (no piping needed on the
Godot side).

Usage: python3 e2e_route_stdio.py <pcb-plugin-binary-path> <request-json-path> [tool-name]
  request-json-path is a JSON file whose contents become the tool's arguments
  verbatim -- for the default "pcb.route" tool, {"board": {...},
  "route_hints": [...], "selection": {...}}.
  tool-name defaults to "pcb.route"; any other registered dotted panel-IPC
  channel (e.g. "pcb.zone_fill") is driven through the same handshake.

Prints to stdout: {"ok": true, "result": {success, routes, unrouted, via_count, ...}}
               or: {"ok": false, "error": "<message>"}
Exit code 0 always (the ok/false shape carries failure — matches the worker's
own envelope convention so the Godot caller has one shape to branch on).
"""
import json
import subprocess
import sys


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(json.dumps({"ok": False, "error": "usage: e2e_route_stdio.py <binary> <request.json> [tool]"}))
        return 0

    binary_path, request_path = sys.argv[1], sys.argv[2]
    tool_name = sys.argv[3] if len(sys.argv) == 4 else "pcb.route"
    try:
        with open(request_path, "r", encoding="utf-8") as f:
            request = json.load(f)
    except Exception as exc:  # noqa: BLE001 - report, never crash the caller
        print(json.dumps({"ok": False, "error": "bad request json: %s" % exc}))
        return 0

    try:
        proc = subprocess.Popen(
            [binary_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": "binary spawn failed: %s" % exc}))
        return 0

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv_id(want):
        # The binary's stdout interleaves JSON-RPC replies with unsolicited
        # host.notify frames (main.go emitHostNotify — e.g. worker startup
        # progress), which carry a "method" but no "id" (see main.go
        # hostNotify / notifyParams and main_test.go's readID, the Go side's
        # own harness for this exact framing). A single readline() can land
        # on one of those instead of the reply, desyncing every message after
        # it. Loop until a frame's own "id" matches the request we're
        # waiting on, discarding notification frames along the way.
        while True:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("pcb-plugin closed stdout unexpectedly (stderr: %s)" % proc.stderr.read()[-4000:])
            msg = json.loads(line)
            if msg.get("id") == want:
                return msg
            # notification frame (no id, or an id from an unrelated message) — skip.

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        recv_id(1)
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": tool_name, "arguments": request}})
        reply = recv_id(2)
        proc.stdin.close()
        proc.wait(timeout=15)

        if "error" in reply:
            print(json.dumps({"ok": False, "error": str(reply["error"]),
                              "stderr_tail": proc.stderr.read()[-4000:]}))
            return 0
        content = reply.get("result", {}).get("content", [])
        text = content[0].get("text", "{}") if content else "{}"
        envelope = json.loads(text)  # {"ok": bool, "result"|"error": ...}
        if not envelope.get("ok"):
            # The binary relays the worker's stderr ([worker] lines) on its
            # own stderr; a failed call is unreadable without it.
            envelope["stderr_tail"] = proc.stderr.read()[-4000:]
        print(json.dumps(envelope))
        return 0
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": "%s call failed: %s" % (tool_name, exc)}))
        return 0


if __name__ == "__main__":
    sys.exit(main())
