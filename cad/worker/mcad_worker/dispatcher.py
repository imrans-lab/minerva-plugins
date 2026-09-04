"""Main dispatcher loop for the Go-Python bridge worker.

Startup sequence (per design §5):
  1. Import mcad package.
  2. Import build123d.
  3. Run 1 mm-cube tessellation to confirm OCCT initialised.
  4. Probe the compiled geometry backends and REPORT the outcome.
  5. Emit `worker.ready` notification.
  6. Loop: read_frame → decode JSON → dispatch → write_frame.

Errors in the loop are caught and returned as structured error responses
so the Go parent can continue rather than restarting. Fatal startup errors
propagate to stderr and cause a non-zero exit.
"""

from __future__ import annotations

import io
import json
import logging
import sys
import traceback

log = logging.getLogger(__name__)

WORKER_VERSION = "0.1.0"


def _get_version(module_name: str) -> str:
    """Return the ``__version__`` string of *module_name* or ``"unknown"``."""
    try:
        import importlib
        mod = importlib.import_module(module_name)
        return getattr(mod, "__version__", "unknown")
    except Exception:
        return "unknown"


def _get_occt_version() -> str:
    """Best-effort OCCT version string."""
    try:
        import OCP  # type: ignore[import]
        return getattr(OCP, "__version__", "unknown")
    except Exception:
        pass
    try:
        import OCC.Core.BRep  # type: ignore[import]
        return "7.x"
    except Exception:
        pass
    return "unknown"


#: Compiled geometry backends the worker expects to find in the runtime
#: bundle. Probed at startup and REPORTED — never silently worked around.
GEOMETRY_BACKENDS = ("fcl",)


def _backend_diagnosis(module_name: str, exc: BaseException) -> str:
    """A one-line diagnosis for a failed backend import.

    A bare ImportError from a compiled extension names the module, not the
    thing that is actually missing. On Windows the common cause is the
    Microsoft C++ runtime: the extension links MSVCP140.dll, which
    python-build-standalone does not ship, so a bundle whose wheel was not
    repaired at build time imports on a machine with the Visual C++
    redistributable and fails on one without it. Saying "DLL load failed"
    sends the reader nowhere; naming the DLL sends them somewhere.
    """
    text = str(exc)
    if "DLL load failed" in text or "MSVCP140" in text.upper():
        return (f"{module_name}: the compiled extension could not load its "
                f"C++ runtime (MSVCP140.dll). This bundle was built without "
                f"the Windows wheel repair — reinstall a bundle built by CI. "
                f"Underlying error: {text}")
    return f"{module_name}: {type(exc).__name__}: {text}"


def _probe_geometry_backends() -> dict:
    """Import each geometry backend; return {name: version-or-error string}.

    NEVER RAISES, and never falls back. A missing backend is reported in two
    places instead: the worker.ready notification (so the host and any later
    request can see the bundle is incomplete) and a stderr line the Go parent
    surfaces to the user. The alternative — importing lazily at first use, or
    quietly substituting a slower path — turns a broken release into a subtly
    wrong answer weeks later, on the one platform nobody built on.

    The stderr line starts with "ERROR:" deliberately: main.go's
    criticalStderrPrefixes matches on the raw line prefix, so a line the
    logging module has prefixed with "[mcad_worker]" is written to the
    activity log but never becomes a toast.
    """
    report: dict = {}
    for name in GEOMETRY_BACKENDS:
        try:
            import importlib
            mod = importlib.import_module(name)
        except BaseException as exc:  # noqa: BLE001 — a broken .so can raise anything
            diagnosis = _backend_diagnosis(name, exc)
            report[name] = f"UNAVAILABLE: {diagnosis}"
            print(f"ERROR: cad geometry backend unavailable — {diagnosis}",
                  file=sys.stderr, flush=True)
            log.critical("geometry backend unavailable: %s", diagnosis)
            continue
        report[name] = str(getattr(mod, "__version__", "unknown"))
        log.info("geometry backend %s: %s", name, report[name])
    return report


def _cold_start() -> tuple[str, str, dict]:
    """Run the cold-start sequence.

    Returns (build123d_version, occt_version, geometry_backend_report).

    Raises on import or tessellation failure — caller should treat this as
    fatal and exit non-zero after logging to stderr.
    """
    log.info("cold start: importing mcad")
    import mcad  # noqa: F401 — imported for side-effects / OCCT init

    log.info("cold start: importing build123d")
    import build123d  # type: ignore[import]
    b123d_version = getattr(build123d, "__version__", "unknown")

    log.info("cold start: running 1mm-cube tessellation smoke test")
    from build123d import Box  # type: ignore[import]
    cube = Box(1, 1, 1)
    # tessellate() is on the underlying OCCT shape; access via .wrapped or
    # call Shape.tessellate directly if available.
    try:
        # build123d Shape exposes tessellate() directly.
        cube.tessellate(0.1)
    except AttributeError:
        # Fallback: use a face's underlying compound.
        list(cube.faces())[0].tessellate(0.1)

    occt_version = _get_occt_version()

    # After build123d, because a bundle that cannot import build123d has a
    # bigger problem than a missing geometry backend and should say so first.
    backends = _probe_geometry_backends()

    log.info("cold start complete: build123d=%s occt=%s backends=%s",
             b123d_version, occt_version, backends)
    return b123d_version, occt_version, backends


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
    """Run the worker: cold-start, emit ready, then loop until shutdown.

    Args:
        stdin:  Binary stream to read framed requests from.
        stdout: Binary stream to write framed responses/notifications to.
    """
    from .framing import FramingError, read_frame
    from . import methods

    # --- Cold start ---
    try:
        b123d_version, occt_version, backends = _cold_start()
    except Exception as exc:
        log.critical("cold start failed: %s\n%s", exc, traceback.format_exc())
        sys.exit(1)

    # --- Emit worker.ready ---
    _write_notification(stdout, "worker.ready", {
        "version": WORKER_VERSION,
        "build123d": b123d_version,
        "occt": occt_version,
        # Reported on EVERY start, present or not: a key that only appears
        # when things are fine cannot distinguish a healthy bundle from an
        # older worker that never looked.
        "geometry_backends": backends,
    })
    log.info("emitted worker.ready; entering request loop")

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
            # Can't echo back an id — send a best-effort error and continue.
            _write_response(stdout, {
                "id": None,
                "ok": False,
                "error": {
                    "kind": "internal",
                    "message": f"JSON decode error: {exc}",
                },
            })
            continue

        method: str = req.get("method", "")
        req_id = req.get("id")
        log.info("dispatch: method=%s id=%s", method, req_id)

        # Handle shutdown at the dispatcher level — don't delegate to methods.
        if method == "shutdown":
            log.info("shutdown requested; exiting cleanly")
            _write_response(stdout, {
                "id": req_id,
                "ok": True,
                "result": {},
            })
            sys.exit(0)

        try:
            response = methods.handle_request(req)
        except Exception as exc:
            tb = traceback.format_exc()
            log.error("unhandled exception in handle_request: %s\n%s", exc, tb)
            response = {
                "id": req_id,
                "ok": False,
                "error": {
                    "kind": "python",
                    "message": str(exc),
                    "traceback": tb,
                },
            }

        if response is not None:
            _write_response(stdout, response)
