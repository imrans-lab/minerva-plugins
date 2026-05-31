"""Worker request loop: cold-start, emit worker.ready, serve framed requests.

Wire protocol (bridge §4), one JSON object per length-prefixed frame:
  request:      {"id": "...", "method": "...", "params": {...}, "deadline_ms": N}
  response:     {"id": "...", "ok": true,  "result": {...}}
                {"id": "...", "ok": false, "error": {"kind": "...", "message": "..."}}
  notification: {"method": "worker.ready", "params": {...}}   (no id)

P1.1 cold-start is trivial (stdlib only). Later phases add subsystem imports
here and surface import failures as a critical-exit so the Go shim toasts them.
"""

from __future__ import annotations

import json
import logging
import sys
import traceback

from . import methods
from .framing import FramingError, read_frame, write_frame

log = logging.getLogger(__name__)

WORKER_VERSION = "0.1.0"


def _write_response(stdout, resp: dict) -> None:
    write_frame(stdout, json.dumps(resp).encode("utf-8"))


def _write_notification(stdout, method: str, params: dict) -> None:
    write_frame(stdout, json.dumps({"method": method, "params": params}).encode("utf-8"))


def run(stdin, stdout) -> None:
    """Serve framed requests until `shutdown` or stdin closes."""
    # Cold start: nothing heavy to import in the P1.1 substrate. Kept as an
    # explicit, fail-fast hook so later phases add subsystem warm-up here.
    try:
        pass
    except Exception:  # pragma: no cover - defensive cold-start guard
        log.critical("cold start failed:\n%s", traceback.format_exc())
        sys.exit(1)

    _write_notification(stdout, "worker.ready", {"version": WORKER_VERSION})
    log.info("emitted worker.ready; entering request loop")

    while True:
        try:
            raw = read_frame(stdin)
        except FramingError as exc:
            log.error("framing error (fatal): %s", exc)
            sys.exit(1)

        try:
            req = json.loads(raw)
        except json.JSONDecodeError as exc:
            log.error("malformed request JSON (fatal): %s", exc)
            sys.exit(1)

        method = req.get("method", "")
        req_id = req.get("id")

        if method == "shutdown":
            if req_id is not None:
                _write_response(stdout, {"id": req_id, "ok": True, "result": {}})
            log.info("shutdown received; exiting")
            sys.exit(0)

        try:
            result = methods.handle(method, req.get("params") or {})
            resp = {"id": req_id, "ok": True, "result": result}
        except methods.MethodError as exc:
            resp = {"id": req_id, "ok": False,
                    "error": {"kind": exc.kind, "message": str(exc)}}
        except Exception as exc:  # noqa: BLE001 - any worker bug becomes a structured error
            resp = {"id": req_id, "ok": False,
                    "error": {"kind": "python", "message": str(exc),
                              "traceback": traceback.format_exc()}}

        # Notifications (no id) get no response; everything else does.
        if req_id is not None:
            _write_response(stdout, resp)
