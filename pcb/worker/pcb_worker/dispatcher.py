"""Main dispatcher loop for the Go-Python bridge worker.

Mirrors the CAD worker's dispatcher (cad/worker/mcad_worker/dispatcher.py):

Startup sequence:
  1. Import pyyaml (the one hard runtime dependency).
  2. Probe circuit_synth availability WITHOUT importing it (importlib.metadata
     reads the installed distribution's metadata; it does not run the package).
     circuit_synth is an OPTIONAL, lazily-imported helper — a missing or broken
     install must never stop the worker, because validate / generate /
     check_bom / check_libraries all run in plain Python over the YAML.
  3. Emit `worker.ready` notification (carrying measured cold-start ms).
  4. Loop: read_frame → decode JSON → dispatch → write_frame.

The PCB worker's cold start is cheap (pyyaml import only) — unlike CAD, there
is no OCCT kernel to warm — so cold start is typically well under a second.
Errors in the request loop are caught and returned as structured error
responses so the Go parent can continue rather than restarting.
"""

from __future__ import annotations

import io
import json
import logging
import sys
import time
import traceback

log = logging.getLogger(__name__)

WORKER_VERSION = "0.2.0"  # tracks plugin manifest version


def _dist_version(dist_name: str) -> str | None:
    """Return an installed distribution's version WITHOUT importing it.

    Uses importlib.metadata so probing circuit_synth costs microseconds and
    cannot trigger the package's (potentially heavy / KiCad-coupled) import
    side effects. Returns None if the distribution is not installed.
    """
    try:
        from importlib import metadata
        return metadata.version(dist_name)
    except Exception:
        return None


def _cold_start() -> dict:
    """Run the cold-start sequence and return an env dict for worker.ready.

    Raises only if pyyaml (the hard dependency) is unavailable — the caller
    treats that as fatal and exits non-zero after logging to stderr.
    """
    log.info("cold start: importing pyyaml")
    import yaml  # noqa: F401 — required hard dependency
    pyyaml_version = getattr(yaml, "__version__", "unknown")

    # circuit_synth: metadata probe only. Package name on PyPI is
    # "circuit-synth"; the import name is "circuit_synth".
    cs_version = _dist_version("circuit-synth")
    log.info(
        "cold start complete: pyyaml=%s circuit_synth=%s",
        pyyaml_version, cs_version or "not-installed",
    )
    return {
        "pyyaml": pyyaml_version,
        "circuit_synth": cs_version,
        "circuit_synth_available": cs_version is not None,
    }


def _write_notification(stream: io.RawIOBase, method: str, params: dict) -> None:
    """Write a framed notification (no id) to *stream*."""
    from .framing import write_frame
    body = json.dumps({"method": method, "params": params}).encode("utf-8")
    write_frame(stream, body)


def _write_response(stream: io.RawIOBase, response: dict) -> None:
    """Write a framed response dict to *stream*."""
    from .framing import write_frame
    body = json.dumps(response).encode("utf-8")
    write_frame(stream, body)


def run(stdin: io.RawIOBase, stdout: io.RawIOBase) -> None:
    """Run the worker: cold-start, emit ready, then loop until shutdown."""
    from .framing import FramingError, read_frame
    from . import methods

    # --- Cold start (timed) ---
    t0 = time.monotonic()
    try:
        env = _cold_start()
    except Exception as exc:
        log.critical("cold start failed: %s\n%s", exc, traceback.format_exc())
        sys.exit(1)
    cold_start_ms = round((time.monotonic() - t0) * 1000.0, 3)

    # Publish the measured cold start to the methods module so init/ping can
    # report it without re-measuring.
    methods.COLD_START_MS = cold_start_ms

    # --- Emit worker.ready ---
    _write_notification(stdout, "worker.ready", {
        "version": WORKER_VERSION,
        "pyyaml": env["pyyaml"],
        "circuit_synth": env["circuit_synth"],
        "circuit_synth_available": env["circuit_synth_available"],
        "cold_start_ms": cold_start_ms,
    })
    log.info("emitted worker.ready (cold_start_ms=%s); entering request loop", cold_start_ms)

    # --- Request loop ---
    while True:
        try:
            raw = read_frame(stdin)
        except FramingError as exc:
            log.error("framing error (fatal): %s", exc)
            sys.exit(1)

        try:
            req = json.loads(raw)
        except json.JSONDecodeError as exc:
            log.error("JSON decode error: %s", exc)
            _write_response(stdout, {
                "id": None,
                "ok": False,
                "error": {"kind": "internal", "message": f"JSON decode error: {exc}"},
            })
            continue

        method: str = req.get("method", "")
        req_id = req.get("id")
        log.info("dispatch: method=%s id=%s", method, req_id)

        # Handle shutdown at the dispatcher level — don't delegate to methods.
        if method == "shutdown":
            log.info("shutdown requested; exiting cleanly")
            _write_response(stdout, {"id": req_id, "ok": True, "result": {}})
            sys.exit(0)

        try:
            response = methods.handle_request(req)
        except Exception as exc:
            tb = traceback.format_exc()
            log.error("unhandled exception in handle_request: %s\n%s", exc, tb)
            response = {
                "id": req_id,
                "ok": False,
                "error": {"kind": "python", "message": str(exc), "traceback": tb},
            }

        if response is not None:
            _write_response(stdout, response)
