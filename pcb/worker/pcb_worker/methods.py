"""Request handlers for the Go-Python bridge worker.

Pure (no I/O apart from the explicit file writes in `generate` when an out_dir
is supplied, and the read-only library scan in `check_libraries`) so handlers
can be unit-tested by calling handle_request(dict) -> dict directly, bypassing
stdio — the same pattern the CAD worker's tests use.

Methods are stateless pure functions over the canonical board-source YAML
contract (pcb/internal/board/board.go, pcb/docs/board-yaml.md):

  init            — version/health handshake (mirrors CAD's init).
  ping            — cheap liveness probe; reports cold-start ms.
  validate        — structural validation → {ok, errors[], warnings[]}.
  generate        — YAML → KiCad file text (.kicad_pcb/.kicad_sch/.kicad_pro).
  check_libraries — footprint existence check against a lib_dir data contract.
  check_bom       — BOM extraction + validation.
"""

from __future__ import annotations

import os
import traceback
from pathlib import Path

from . import board_model, kicad, libcheck

WORKER_VERSION = "0.2.0"  # tracks plugin manifest version

# Populated by dispatcher.run() after the (timed) cold start. Kept as a module
# global so init/ping can report it without re-measuring.
COLD_START_MS: float | None = None


def _pyyaml_version() -> str:
    try:
        import yaml
        return getattr(yaml, "__version__", "unknown")
    except Exception:
        return "unknown"


def _circuit_synth_version() -> str | None:
    """Version via metadata only — never imports the (KiCad-coupled) package."""
    try:
        from importlib import metadata
        return metadata.version("circuit-synth")
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Method implementations
# ---------------------------------------------------------------------------


def _load(params: dict) -> dict:
    """Resolve a board dict or raise board_model.BoardParseError."""
    return board_model.load_board(params or {})


def _validate(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        # A parse failure is reported as a validation error (data), not a
        # protocol error — the LLM inner loop wants it as {ok, errors}.
        return {"ok": True, "result": {
            "ok": False,
            "errors": [{"path": "", "message": str(exc)}],
            "warnings": [],
        }}
    result = board_model.validate_board(board)
    return {"ok": True, "result": result}


def _generate(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    files = kicad.generate(board, base_name=base_name)

    out_dir = params.get("out_dir")
    result: dict = {"files": files, "written": []}
    if isinstance(out_dir, str) and out_dir.strip():
        # Optional: also write to disk and report paths + byte counts (mirrors
        # CAD's export, which returns {path, bytes_written}). Contents still
        # travel inline — worker↔Go is stdio, not the 64KiB panel IPC broker.
        try:
            os.makedirs(out_dir, exist_ok=True)
            written = []
            for fname, text in files.items():
                p = Path(out_dir) / fname
                data = text.encode("utf-8")
                p.write_bytes(data)
                written.append({"path": str(p), "bytes_written": len(data)})
            result["written"] = written
        except OSError as exc:
            return {"ok": False, "error": {
                "kind": "io", "message": f"failed to write to out_dir: {exc}"}}
    return {"ok": True, "result": result}


_NO_LIBRARY_DATA_HINT = (
    "No KiCAD library data found under lib_dir. Run pcb_fetch_libraries first, "
    "then retry (see pcb_library_status to check what's already fetched)."
)


def _check_libraries(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    lib_dir = params.get("lib_dir")
    # lib_dir data is fetched by the Go-side pcb_fetch_libraries tool (see
    # pcb/internal/libraries/ + docs/libraries.md) into a directory this
    # method never writes to — it only reads whatever is already there. With
    # no lib_dir (or one that doesn't exist / isn't a directory yet) this is
    # an explicit "no data" answer — never a crash.
    if not isinstance(lib_dir, str) or lib_dir.strip() == "" or not os.path.isdir(lib_dir):
        return {"ok": True, "result": {
            "ok": True,
            "checked": 0,
            "missing": [],
            "missing_data": True,
            "hint": _NO_LIBRARY_DATA_HINT,
        }}

    checked = 0
    missing: list[dict] = []
    missing_symbols: list[dict] = []
    for i, comp in enumerate(board.get("components") or []):
        if not isinstance(comp, dict):
            continue
        fp = comp.get("footprint")
        if isinstance(fp, str) and fp != "":
            # Footprint match is REQUIRED per board-yaml's footprint field —
            # boards always reference a footprint, so this gates `ok`.
            checked += 1
            if not libcheck.resolve_footprint(lib_dir, fp):
                missing.append({"path": f"components[{i}].footprint",
                                "ref": comp.get("ref"), "footprint": fp,
                                "suggestions": libcheck.suggest_footprints(lib_dir, fp)})

        # Symbol match is OPTIONAL and informational only: the canonical
        # board-yaml schema has no first-class "symbol" field (components
        # reference footprints, not symbols — see docs/board-yaml.md), but a
        # component may carry one via the schema's Extra passthrough. When
        # present, report a resolve miss as a soft "missing_symbols" entry —
        # it never affects `ok` or `checked`.
        sym = comp.get("symbol")
        if isinstance(sym, str) and sym != "" and not libcheck.resolve_symbol(lib_dir, sym):
            missing_symbols.append({"path": f"components[{i}].symbol",
                                    "ref": comp.get("ref"), "symbol": sym})

    return {"ok": True, "result": {
        "ok": len(missing) == 0,
        "checked": checked,
        "missing": missing,
        "missing_symbols": missing_symbols,
        "missing_data": False,
        "lib_dir": lib_dir,
    }}


def _check_bom(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    lib_dir = params.get("lib_dir")
    lib_present = isinstance(lib_dir, str) and lib_dir.strip() != "" and os.path.isdir(lib_dir)
    result = board_model.extract_bom(board, lib_present=lib_present)

    # Footprint presence + nearest-name suggestions only when library data is
    # present (per contract) — mirrors check_libraries's missing_data shape so
    # callers can treat the two tools uniformly.
    if lib_present:
        for it in result["items"]:
            fp = it.get("footprint") or ""
            found = bool(fp) and libcheck.resolve_footprint(lib_dir, fp)
            it["footprint_found"] = found
            if fp and not found:
                it["suggestions"] = libcheck.suggest_footprints(lib_dir, fp)
    result["lib_present"] = lib_present
    result["missing_data"] = not lib_present
    if not lib_present:
        result["hint"] = _NO_LIBRARY_DATA_HINT
    return {"ok": True, "result": result}


def _init() -> dict:
    return {"ok": True, "result": {
        "worker_version": WORKER_VERSION,
        "pyyaml": _pyyaml_version(),
        "circuit_synth": _circuit_synth_version(),
        "circuit_synth_available": _circuit_synth_version() is not None,
        "cold_start_ms": COLD_START_MS,
    }}


def _ping(params: dict) -> dict:
    return {"ok": True, "result": {
        "pong": True,
        "worker_version": WORKER_VERSION,
        "cold_start_ms": COLD_START_MS,
        "echo": (params or {}).get("echo"),
    }}


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

_HANDLERS = {
    "validate": lambda req: _validate(req.get("params") or {}),
    "generate": lambda req: _generate(req.get("params") or {}),
    "check_libraries": lambda req: _check_libraries(req.get("params") or {}),
    "check_bom": lambda req: _check_bom(req.get("params") or {}),
    "ping": lambda req: _ping(req.get("params") or {}),
}


def handle_request(req: dict) -> dict | None:
    """Dispatch a decoded request dict and return a response dict.

    Returns None only for inbound notifications (no id, non-init/shutdown).
    """
    method: str = req.get("method", "")
    req_id = req.get("id")

    if req_id is None and method not in ("init", "shutdown"):
        return None

    if method == "init":
        result = _init()
        result["id"] = req_id
        return result

    if method == "shutdown":
        return None  # dispatcher handles the clean exit

    handler = _HANDLERS.get(method)
    if handler is not None:
        try:
            result = handler(req)
        except Exception as exc:  # defensive: never crash the loop
            return {"id": req_id, "ok": False, "error": {
                "kind": "python", "message": str(exc), "traceback": traceback.format_exc()}}
        result["id"] = req_id
        return result

    return {"id": req_id, "ok": False, "error": {
        "kind": "internal", "message": f"unknown method: {method!r}"}}
