"""End-to-end smoke test for the pcb_worker subprocess.

Spawns `python -m pcb_worker`, performs the cold-start → worker.ready → init →
validate → shutdown round trip over real framed stdio. Mirrors the CAD worker's
smoke test. Requires pyyaml (the worker's one hard dep); skipped if absent.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
from pathlib import Path

import pytest

try:
    import yaml  # noqa: F401
except ImportError:
    pytest.skip("pyyaml not installed — smoke test skipped", allow_module_level=True)

from pcb_worker.framing import read_frame, write_frame

TIMEOUT_SECONDS = 30
SPIKE_BOARD = Path(__file__).resolve().parents[2] / "spikes" / "gerber" / "board.yaml"


def _make_frame(obj: dict) -> bytes:
    buf = io.BytesIO()
    write_frame(buf, json.dumps(obj).encode("utf-8"))
    return buf.getvalue()


def _read_one(proc: subprocess.Popen) -> dict:
    return json.loads(read_frame(proc.stdout))  # type: ignore[arg-type]


def test_worker_lifecycle():
    proc = subprocess.Popen(
        [sys.executable, "-m", "pcb_worker"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        # 1. init request.
        proc.stdin.write(_make_frame({"id": "req_1", "method": "init", "params": {}}))
        proc.stdin.flush()

        # 2. worker.ready notification (arrives first).
        ready = _read_one(proc)
        assert ready.get("method") == "worker.ready", f"got: {ready!r}"
        assert "cold_start_ms" in ready["params"]
        assert "circuit_synth_available" in ready["params"]

        # 3. init response.
        init_resp = _read_one(proc)
        assert init_resp.get("id") == "req_1"
        assert init_resp.get("ok") is True
        assert "worker_version" in init_resp["result"]

        # 4. validate the spike board end-to-end.
        board_yaml = SPIKE_BOARD.read_text(encoding="utf-8")
        proc.stdin.write(_make_frame(
            {"id": "req_2", "method": "validate", "params": {"yaml": board_yaml}}))
        proc.stdin.flush()
        vresp = _read_one(proc)
        assert vresp.get("id") == "req_2"
        assert vresp["ok"] is True
        assert vresp["result"]["ok"] is True, vresp["result"]["errors"]

        # 5. shutdown.
        proc.stdin.write(_make_frame({"id": "req_3", "method": "shutdown", "params": {}}))
        proc.stdin.flush()
        sresp = _read_one(proc)
        assert sresp.get("id") == "req_3"
        assert sresp.get("ok") is True

        proc.stdin.close()
        exit_code = proc.wait(timeout=TIMEOUT_SECONDS)
        assert exit_code == 0, proc.stderr.read().decode(errors="replace")
    except Exception:
        proc.kill()
        proc.wait()
        raise
