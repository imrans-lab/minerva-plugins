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
  gerbers         — YAML → Gerber (RS-274X/X2) layers + Excellon drill files.
  check_libraries — footprint existence check against a lib_dir data contract.
  check_bom       — BOM extraction + validation.
"""

from __future__ import annotations

import os
import traceback
from pathlib import Path
from typing import Any

from . import (board_model, compile_board, drc, footprints, gerber,
               ir_candidates, ir_connectivity, kicad, libcheck, resolve)
from .drc_geometric import geometric_drc_from_resolution, geometric_indeterminate

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


# --- Resolve-into-fab gate (bug 019f7736b236) -----------------------------
# The fab compilers (gerber/kicad/drc via pad_source) prefer real footprint pad
# geometry attached by resolve to comp["pads"]. Stage 2 step 4a-ii FLIPPED this
# ON (design 2): the fab path resolves by default so pads come from the library,
# not a placeholder. The resolve is BEST-EFFORT (see _maybe_resolve) — a
# component with an unresolvable footprint is left inline rather than failing the
# board; the emitter then fail-closes only on a genuinely sizeless SMD pad.
# Grep this name to find the switch. Per-call override: params["resolve_geometry"].
RESOLVE_FAB_GEOMETRY_DEFAULT = True


def _is_error_reply(x: Any) -> bool:
    """True for a structured error reply {ok: False, error: {...}} (a real board
    dict never carries an "ok" key, so this cleanly discriminates the two)."""
    return isinstance(x, dict) and x.get("ok") is False and "error" in x


def _maybe_resolve(board: dict, params: dict) -> dict:
    """Return the board to compile for the FAB path: unchanged when the resolve
    gate is OFF, or a BEST-EFFORT resolve when ON — attaching comp["pads"] real
    geometry that pad_source prefers, while leaving any component with an
    unresolvable footprint inline (its pins win) rather than failing the board.

    Gate = RESOLVE_FAB_GEOMETRY_DEFAULT (default ON since step 4a-ii), overridable
    per-call via params["resolve_geometry"]. A coincidence failure (footprint
    resolves but disagrees with the routed pins) is NOT tolerated — it returns a
    structured error reply so callers pass it through (detect with
    _is_error_reply()). The standalone `resolve` action uses the STRICT variant
    below instead (an unresolvable footprint there IS an error to surface).
    """
    want = params.get("resolve_geometry")
    if want is None:
        want = RESOLVE_FAB_GEOMETRY_DEFAULT
    if not want:
        return board
    return _resolve_mapped(board, tolerant=True)


def _resolve_mapped(board: dict, *, tolerant: bool) -> dict:
    """Run resolve (tolerant=best-effort for fab, strict for the resolve action)
    and map its faults to structured error replies (never raise). Single owner of
    the coincidence/resolve error shape shared by _maybe_resolve and _resolve."""
    try:
        if tolerant:
            return resolve.resolve_board_best_effort(board)
        return resolve.resolve_board(board)
    except resolve.ResolveCoincidenceError as exc:
        return {"ok": False, "error": {
            "kind": "coincidence", "message": str(exc),
            "ref": exc.ref, "pin": exc.pin, "delta_mm": exc.delta_mm}}
    except (resolve.ResolveError, footprints.FootprintLookupError) as exc:
        return {"ok": False, "error": {"kind": "resolve", "message": str(exc)}}


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


def _compile_or_fail(board: dict, *,
                     requested_outputs: tuple[str, ...] = compile_board.V1_FAB_OUTPUTS):
    """The SHARED strict-compile prologue: COMPILE → ResolvedBoard IR, or a
    structured fail-closed error reply.

    Used by ``_gerbers`` + ``_generate`` with the FAB capability profile (the
    default) and by ``_route`` with the narrower ROUTING profile
    (``V1_ROUTING_OUTPUTS``, Round E 019f783860c8) — so a solder-mask capability
    loss cannot disable routing while any dropped copper/drill/rule stays fatal
    everywhere. ``requested_outputs`` is the ONLY thing that varies; the failure
    reply shape is identical for every caller.

    Returns the ``ResolutionSuccess`` (carrying ``.board`` + ``.diagnostics`` the
    caller forwards as warnings) on success, or a ``{kind:"compile"}`` error reply
    (detect with :func:`_is_error_reply`) on failure — NO fallback to the legacy
    best-effort emitter (W9 deletes the dead best-effort fab path). Uses the SAME
    seed library the legacy resolve used (library_root=lockfile=None, i.e.
    footprints.DEFAULT_LIBRARY_ROOT/LOCKFILE). ``params["resolve_geometry"]`` is
    moot on the fab path now (compile ALWAYS resolves): accepted-and-ignored by the
    callers, not consulted here."""
    compiled = compile_board.compile_board(board, requested_outputs=requested_outputs)
    if isinstance(compiled, compile_board.ResolutionFailure):
        return _compile_failure_reply(compiled)
    return compiled


def _generate(params: dict) -> dict:
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    # W8.2 CUTOVER: same shape as _gerbers — COMPILE (strict) → ResolvedBoard IR →
    # kicad.generate, replacing the legacy best-effort _maybe_resolve (shared
    # prologue in _compile_or_fail).
    compiled = _compile_or_fail(board)
    if _is_error_reply(compiled):
        return compiled

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        # C5b: emit straight from the ResolvedBoard IR — no IR->loose-dict adapter
        # (mirrors _gerbers' build_gerbers_ir at the gerber cutover).
        files = kicad.generate_ir(compiled.board, base_name=base_name)
    except Exception as exc:  # geometry/library faults (incl. fail-closed) as data
        return {"ok": False, "error": {"kind": "generate", "message": str(exc)}}

    # Surface WARNING-channel diagnostics so nothing vanishes silently: the KiCad
    # emitter's own (a captured footprint graphic dropped/unsupported) PLUS the
    # compile diagnostics (INFO/WARNING). Both via the SAME _diagnostic_to_payload
    # shape the gerbers handler uses. Non-breaking: only the "warnings" key changes.
    out_dir = params.get("out_dir")
    warnings = [_diagnostic_to_payload(d) for d in getattr(files, "diagnostics", [])]
    warnings += [_diagnostic_to_payload(d) for d in compiled.diagnostics]
    result: dict = {"files": files, "written": [], "warnings": warnings}
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


def _diagnostic_to_payload(d) -> dict:
    """Serialise a resolved_board.Diagnostic to a reply dict. The source_ref shape
    mirrors footprint_def._unsupported_to_payload (the one place that already turns
    a SourceRef into JSON) so callers see one uniform diagnostic shape."""
    return {
        "severity": d.severity.value,
        "code": d.code,
        "message": d.message,
        "source_ref": {
            "entity_kind": d.source_ref.entity_kind.value,
            "entity_id": d.source_ref.entity_id,
            "detail": d.source_ref.detail,
        },
    }


def _compile_failure_reply(failure) -> dict:
    """Map a compile_board.ResolutionFailure to the STRICT fail-closed fab reply
    (W8.2). No fallback to the legacy best-effort emitter — an uncompilable board
    never yields fabrication. `message` summarises the FIRST ERROR diagnostic;
    every diagnostic is serialized (same _diagnostic_to_payload shape as warnings)
    so the caller sees exactly what blocked the compile."""
    payloads = [_diagnostic_to_payload(d) for d in failure.diagnostics]
    first_error = next((p for p in payloads if p.get("severity") == "error"), None)
    message = first_error["message"] if first_error else "board could not be compiled"
    return {"ok": False, "error": {
        "kind": "compile", "message": message, "diagnostics": payloads}}


def _gerbers(params: dict) -> dict:
    """Generate Gerber (RS-274X/X2) + Excellon fabrication files from a board.

    Return convention mirrors `generate` exactly: {files:{name:content},
    written:[{path,bytes_written}]}, with the files also written to disk when
    out_dir is supplied. Six Gerber layers (F_Cu/B_Cu/F_Mask/B_Mask/F_SilkS/
    Edge_Cuts) plus PTH.drl/NPTH.drl (each drill file only when the board has
    holes of that class).
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    # W8.2 CUTOVER: the LIVE fab path now COMPILES (strict) → ResolvedBoard IR →
    # emit, replacing the legacy best-effort _maybe_resolve (shared prologue in
    # _compile_or_fail — fail-closed, NO fallback to the legacy emitter).
    compiled = _compile_or_fail(board)
    if _is_error_reply(compiled):
        return compiled

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        # C5: emit straight from the ResolvedBoard IR — no IR->loose-dict adapter.
        files = gerber.build_gerbers_ir(compiled.board, name=base_name)
    except Exception as exc:  # geometry/library faults reported as data, not crash
        return {"ok": False, "error": {"kind": "gerber", "message": str(exc)}}

    # Surface WARNING-channel diagnostics so nothing vanishes silently: the
    # emitter's own (a captured fab feature dropped/approximated) PLUS the compile
    # diagnostics (INFO/WARNING — inline_pin_geometry_migrated,
    # captured_geometry_not_emitted, ordinal_ids). Both via the same
    # _diagnostic_to_payload shape. Non-breaking: only the "warnings" key changes.
    out_dir = params.get("out_dir")
    warnings = [_diagnostic_to_payload(d) for d in getattr(files, "diagnostics", [])]
    warnings += [_diagnostic_to_payload(d) for d in compiled.diagnostics]
    result: dict = {"files": files, "written": [], "warnings": warnings}
    if isinstance(out_dir, str) and out_dir.strip():
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


def _drc(params: dict) -> dict:
    """CONNECTIVITY / topology design-rule check over a canonical board.

    Runs the legacy CENTERLINE checker (`drc.run_drc`, via `_maybe_resolve`): it
    reasons about pad CENTERS and trace CENTERLINES only. It is NOT geometric and
    canNOT verify a clearance, trace width, or annular ring — a zero-finding result
    here is a connectivity/topology pass, NOT a proof that the copper is
    geometrically clean. For real geometric copper DRC (GC1-GC6 over the
    ResolvedBoard IR, fail-closed, never a false clean) use the `drc_geometric`
    method (`_drc_geometric`).

    Returns {ok, findings:[{type,...}], counts:{type:n}}. A parse failure is a
    structured error (never a crash), mirroring `generate`/`gerbers`.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    board = _maybe_resolve(board, params)
    if _is_error_reply(board):
        return board
    try:
        result = drc.run_drc(board)
    except Exception as exc:  # geometry faults reported as data, not a crash
        return {"ok": False, "error": {"kind": "drc", "message": str(exc)}}
    return {"ok": True, "result": result}


def _drc_geometric(params: dict) -> dict:
    """Geometric copper DRC over the ResolvedBoard IR (GC1-GC6): reads REAL copper
    and hole geometry, fail-closed, and NEVER emits a false ``clean``. This is the
    geometric counterpart to :func:`_drc` (the connectivity/centerline checker,
    which cannot verify a clearance).

    Parse (via ``_load``) → compile (``compile_board.compile_board``) → hand the
    ``ResolutionResult`` straight to
    :func:`drc_geometric.geometric_drc_from_resolution`. That union dict is this
    method's PAYLOAD — returned as the ``result`` of the standard worker envelope
    (``{ok:True, result:<union>}``). The geometric result union:

      * DETERMINATE (compile succeeded): ``{ok:True, scope:"geometric",
        verifies_geometry:True, verdict:"clean"|"violations", findings, counts,
        warnings, ...}``.
      * INDETERMINATE (compile failed, or the kernel met un-modelable geometry):
        ``{ok:False, scope:"geometric", verifies_geometry:False,
        verdict:"indeterminate", error:{...}}`` — deliberately carries NO
        ``clean``/``findings`` a caller could read as a pass.

    The union is the ``result`` payload of the standard worker envelope (every
    worker method returns ``{ok:True, result:<payload>}``; the dispatcher and Go
    bridge unwrap ``result`` — a bare top-level union surfaces as ``result:null``).
    EVERY failure at
    this boundary — parse, compile exception, or unmodeled geometry — returns the
    SAME geometric indeterminate union (019f9589b232): a source that will not parse
    is ``kind="parse"``, an unexpected ``compile_board`` exception is
    ``kind="internal"``, and a compile ``ResolutionFailure`` /
    kernel-unmodeled-geometry flows through
    :func:`drc_geometric.geometric_drc_from_resolution`. No consumer maintains a
    bespoke branch for parse anymore, and the union never carries a ``clean`` a
    caller could mistake for a pass.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        union = geometric_indeterminate("parse", str(exc))
    else:
        try:
            result = compile_board.compile_board(board)
        except Exception as exc:  # noqa: BLE001 - fail-closed: a compile crash is NOT a clean.
            union = geometric_indeterminate("internal", f"compile_board raised {exc!r}")
        else:
            union = geometric_drc_from_resolution(result)
    # WORKER ENVELOPE: the geometric UNION is the payload, wrapped under ``result``
    # exactly like every other worker method — the dispatcher and the Go bridge
    # unwrap ``result``, so a BARE top-level union (no ``result`` key) surfaces as
    # ``result: null`` over the bridge (the live regression this fixes). The envelope
    # ``ok`` is always True: the method RAN and produced a structured discriminated
    # union; clean / violations / indeterminate are conveyed INSIDE the union
    # (``result.ok`` / ``result.verdict``), so every failure still returns the SAME
    # union (019f9589b232) and no consumer needs a bespoke branch.
    return {"ok": True, "result": union}


def _resolve(params: dict) -> dict:
    """Enrich a canonical board with footprint silk/courtyard graphics.

    For each component, resolve its footprint from the sha-verified seed library
    and attach its F.SilkS + F.CrtYd graphics (component-LOCAL coords), after a
    fail-closed coincidence guard that proves the footprint's pads match the
    declared pins. Returns {ok, board:<resolved>, stats:{components,
    silk_graphics, courtyard_graphics}}. A parse failure, an unresolvable
    footprint, or a coincidence mismatch is reported as a structured error
    (never a crash), mirroring generate/gerbers/drc.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    # This method IS resolve, and it is STRICT: an unresolvable footprint is an
    # error the caller asked to surface (unlike the fab path, which tolerates it
    # and falls back to inline pins). Reuse _resolve_mapped's shared structured
    # error handling — one place owns the coincidence/lookup error shape.
    resolved = _resolve_mapped(board, tolerant=False)
    if _is_error_reply(resolved):
        return resolved

    stats = resolve.board_graphic_stats(resolved)
    return {"ok": True, "result": {"ok": True, "board": resolved, "stats": stats}}


def _normalize(params: dict) -> dict:
    """Rewrite a canonical SOURCE board to its normalized v2 shape (the sync-back
    the compile fold never persists): legacy inline per-pin fabrication geometry is
    dropped when redundant, migrated to a typed `override` when it diverges, and
    fail-closes the WHOLE normalize when ambiguous.

    PURE — returns the normalized board for the host to persist; NEVER writes to
    disk. Mirrors _resolve/_gerbers: a parse failure or a fail-closed (ambiguous)
    normalize is a structured {ok:False, error} reply, never a crash. On success the
    reply carries the normalized board plus the diagnostics as `warnings` (same
    _diagnostic_to_payload shape the gerbers/kicad handlers use)."""
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}

    normalized, diagnostics = compile_board.normalize_board(board)
    payloads = [_diagnostic_to_payload(d) for d in diagnostics]
    if normalized is None:
        # Fail-closed: an ambiguous pin makes the WHOLE normalize a failure. Surface
        # it with the same {ok:False, error} shape _resolve uses, carrying the
        # serialized fail-closed diagnostics so the caller sees exactly what blocked.
        errors = [p for p in payloads if p.get("severity") == "error"]
        message = "; ".join(p["message"] for p in errors) or "board could not be normalized"
        return {"ok": False, "error": {
            "kind": "normalize", "message": message, "diagnostics": errors or payloads}}
    return {"ok": True, "result": {
        "ok": True, "board": normalized, "warnings": payloads}}


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


# ---------------------------------------------------------------------------
# route — autoroute a board with the vendored agent_router engine.
#
# ONE input shape is accepted: the CANONICAL board (this round's bridge,
# 019eb481ae28), translated to the engine's native Board + RoutingHints by
# pcb_worker.route_bridge. Absolute pad positions are composed from component
# placement + rotated pin offsets using the SAME convention the panel model
# uses (get_pin_world_position), so panel and router agree.
#
#      params.yaml  = canonical board YAML source        (or)
#      params.board = canonical board dict (has "components")
#      params.route_hints = [pcb_route_hint envelope, …]  (optional)
#      params.selection   = which hints feed the run:
#                           {"mode":"open"|"all"|"ids"|"net", …} (default open)
#
# The NATIVE shape (grandchild-1's flat pad list, formerly fed through
# _board_from_native) was RETIRED this round: it had no compile, no IR, no
# connectivity DRC, no geometric DRC, and accepted a missing pad size as
# `0x0` — the same class of approximated copper Round E1 removed from the
# canonical path (see pcb/docs/routing.md, "Not yet done"). Zero in-repo
# callers construct it; anything still sending it now gets a structured
# {"kind": "parse"} rejection instead of a silent route over invented
# geometry (see _route, below).
#
# COMMON:
#   params.options = {single_layer?, allow_vias?, trace_width?, clearance?,
#                     order?, grid_resolution?}
#
# OUTPUT: the engine's RoutingResult, serialised to plain JSON
#   {success, via_count, routes:[{net, segments:[{start,end,layer}], vias:[[x,y]]}],
#    unrouted:[{net, from, to}], warnings?:[{id, message}], selected_hint_ids?:[…]}
# ---------------------------------------------------------------------------


def _serialize_routing_result(result) -> dict:
    """Serialise an agent_router.RoutingResult to plain JSON-safe dict."""
    return {
        "success": bool(result.success),
        "via_count": int(result.via_count),
        "routes": [
            {
                "net": r.net,
                "segments": [
                    {"start": [s.start[0], s.start[1]],
                     "end": [s.end[0], s.end[1]],
                     "layer": s.layer}
                    for s in r.segments
                ],
                "vias": [[v[0], v[1]] for v in r.vias],
            }
            for r in result.routes
        ],
        "unrouted": [
            {"net": net, "from": f"{p1.component}.{p1.number}",
             "to": f"{p2.component}.{p2.number}"}
            for net, p1, p2 in result.unrouted
        ],
    }


# NOTE: there is deliberately NO `_is_canonical_route_input` discriminator any
# more. It existed to choose between two input shapes; round A5 retired one of
# them, so there is nothing left to choose. `route` now has a single shape,
# board_model.load_board is its only parser, and the retired shape gets a named
# rejection in _route rather than a branch.


# ---------------------------------------------------------------------------
# DRC-at-propose (docket 019f6f1492e0): after a successful CANONICAL route,
# build the post-route board (existing traces + every returned route
# materialized as traces) and run the EXISTING drc.run_drc engine over it —
# this reuses drc.py's four checks verbatim, it does not reimplement any rule.
# Anything that is not a loadable canonical board is rejected by load_board
# before reaching this point, so every call that gets here has a canonical
# "components"/"nets"/"traces" board to check against.
# ---------------------------------------------------------------------------

# agent_router segment layers are always "F.Cu"/"B.Cu" (route_bridge._LAYER_MAP,
# agent_router/router.py literals). The canonical board's OWN traces use
# "top"/"bottom" (pcb/docs/board-yaml.md). drc.py's crossing/layer-change checks
# compare `seg.layer` by raw string equality, so a route segment must be
# normalized to the canonical spelling before merge — otherwise a same-layer
# collision between a new route and an existing "top" trace would be missed
# because "F.Cu" != "top" as strings, even though both mean the top layer.


def _canonical_drc_layer(layer: Any) -> str:
    from . import route_bridge
    reverse = {v: k for k, v in route_bridge._LAYER_MAP.items()}
    s = str(layer or "")
    return reverse.get(s, s.lower() if s else "top")


def _routes_to_traces(routes: list) -> list:
    """One 2-point trace per route segment. drc._harvest_segments already
    breaks any traces[].points polyline into consecutive (a, b) pairs, so a
    2-point trace per segment is geometrically identical to a merged
    per-layer polyline — simpler and avoids re-deriving chain adjacency."""
    traces: list = []
    for r in routes:
        if not isinstance(r, dict):
            continue
        net = r.get("net")
        for seg in r.get("segments") or []:
            if not isinstance(seg, dict):
                continue
            start = seg.get("start")
            end = seg.get("end")
            if not (isinstance(start, (list, tuple)) and len(start) >= 2
                    and isinstance(end, (list, tuple)) and len(end) >= 2):
                continue
            traces.append({
                "net": net,
                "layer": _canonical_drc_layer(seg.get("layer")),
                "points": [
                    {"x_mm": float(start[0]), "y_mm": float(start[1])},
                    {"x_mm": float(end[0]), "y_mm": float(end[1])},
                ],
            })
    return traces


def _routes_to_vias(routes: list) -> list:
    """Materialize proposed-route vias for DRC-at-propose (see _drc_for_routes).

    Each via dict carries first-class from_layer/to_layer (canonical
    top/bottom — see pcb_data.gd / board-yaml.md) so it matches the shape of
    a canonical board via. agent_router.router.Route.vias is positional
    ((x, y) only, no layer span — see agent_router/router.py's Route
    dataclass) and on a 2-layer board a via always bridges the full
    top<->bottom span, so that is the default here. This does NOT change the
    public route() JSON contract (routes[].vias stays [[x, y], ...] — see
    _serialize_routing_result); this dict shape is internal to DRC harvesting
    only. If the engine ever reports a real per-via layer span, thread it
    through here instead of the hardcoded default.
    """
    vias: list = []
    for r in routes:
        if not isinstance(r, dict):
            continue
        for v in r.get("vias") or []:
            if isinstance(v, (list, tuple)) and len(v) >= 2:
                vias.append({"x_mm": float(v[0]), "y_mm": float(v[1]),
                             "from_layer": "top", "to_layer": "bottom"})
    return vias


def _finding_involves_net(finding: dict, net: Any) -> bool:
    """True if a drc.py finding dict 'involves' the given net name — either
    as the offending trace's own net, one of a crossing's two nets, or the
    net of a pad a trace wrongly landed on (a wrong_net_pad finding involves
    BOTH the trespassing net and the victim pad's net)."""
    if not isinstance(finding, dict) or net is None:
        return False
    if finding.get("net") == net:
        return True
    nets = finding.get("nets")
    if isinstance(nets, list) and net in nets:
        return True
    pad = finding.get("pad")
    if isinstance(pad, dict) and pad.get("net") == net:
        return True
    return False


def _drc_for_routes(board_dict: dict, routes: list) -> dict:
    """Run drc.run_drc over (board_dict's existing traces/vias + every
    proposed route materialized as traces/vias). Shallow-copies board_dict
    and replaces only "traces"/"vias" with new lists — the input's own lists
    are never mutated, and no other board field (components/nets/design_rules/
    revision bookkeeping — board_dict is the canonical board, which never
    carries per-hint revision_stack in the first place; that's stripped from
    the route_hints ANNOTATION envelopes upstream by PcbAnnotationHost.
    strip_hint_history, not from this board) is touched."""
    post_board = dict(board_dict)
    existing_traces = post_board.get("traces")
    post_board["traces"] = (list(existing_traces) if isinstance(existing_traces, list) else []) \
        + _routes_to_traces(routes)
    existing_vias = post_board.get("vias")
    post_board["vias"] = (list(existing_vias) if isinstance(existing_vias, list) else []) \
        + _routes_to_vias(routes)
    return drc.run_drc(post_board)


def _attach_route_drc(payload: dict, board_dict: dict) -> None:
    """Mutate payload in place: each route dict gains
    "drc": {"scope": "connectivity", "clean": bool, "violations": [...]} (filtered
    to findings involving that route's net) on success, or
    "drc": {"scope": "connectivity", "clean": None, "error": "<msg>"} if the DRC
    engine itself faults. payload also gains a top-level "drc_summary":
    {"scope": "connectivity", "clean", "violation_count"} (violation_count counts
    EVERY finding, including ones not attributable to any single proposed route —
    e.g. a crossing between two pre-existing traces). A DRC-engine fault never
    fails the route call — routes still return, just without a clean determination.

    SCOPE (019f958aa6db): this is CONNECTIVITY/topology only — it runs the legacy
    centerline `drc.run_drc`, which cannot verify a clearance/width/annular ring.
    Every payload carries scope:"connectivity" so no consumer (PCBPanel.gd's status
    chip) can render it as a generic/geometric "DRC clean". It is NOT the
    fail-closed geometric union (drc_geometric)."""
    routes = payload.get("routes")
    if not isinstance(routes, list):
        return
    try:
        result = _drc_for_routes(board_dict, routes)
        error: str | None = None
    except Exception as exc:  # geometry faults reported as data, mirrors _drc()
        result = None
        error = str(exc)

    if error is not None:
        for r in routes:
            if isinstance(r, dict):
                r["drc"] = {"scope": "connectivity", "clean": None, "error": error}
        payload["drc_summary"] = {"scope": "connectivity", "clean": None,
                                  "violation_count": 0, "error": error}
        return

    findings = (result or {}).get("findings", [])
    for r in routes:
        if not isinstance(r, dict):
            continue
        net = r.get("net")
        violations = [f for f in findings if _finding_involves_net(f, net)]
        r["drc"] = {"scope": "connectivity", "clean": len(violations) == 0,
                    "violations": violations}
    payload["drc_summary"] = {"scope": "connectivity", "clean": len(findings) == 0,
                              "violation_count": len(findings)}


# ---------------------------------------------------------------------------
# GEOMETRIC DRC-at-propose (docket 019f952b99f2) — the COMPLEMENT to the
# connectivity attach above, not a replacement for it.
#
# `_attach_route_drc` answers "is the net topology sane?" over centerlines and
# pad centers. It cannot represent a trace running through the CENTRE of a
# different-net pad, which is how bug 019f80b5124d shipped a shorting proposal
# under a "clean" label. `_attach_route_geometric_drc` answers the copper
# question, by projecting the proposal onto the compiled ResolvedBoard
# (`ir_candidates`) and running the UNCHANGED geometric kernel. Both payloads
# are attached; neither is authoritative for the other's question.
# ---------------------------------------------------------------------------


def _engine_default_mm(param: str) -> float | None:
    """A millimetre default the ROUTER applies when the caller sets none.

    Read from ``agent_router.router.route_board``'s own signature rather than
    re-spelled as a literal here: every consumer must model what the engine
    ACTUALLY does, and a duplicated default that drifted would silently under- or
    over-state copper (or a keepout). Returns None if it cannot be read, which
    makes the caller fail closed rather than guess.

    Round E2 generalised this from the trace-width-only reader — ``clearance``
    needs exactly the same no-drifting-literal treatment, and two hand-copied
    ``inspect`` blocks would be the drift all over again."""
    import inspect
    from agent_router.router import route_board
    try:
        default = inspect.signature(route_board).parameters[param].default
    except (KeyError, TypeError, ValueError):
        return None
    if isinstance(default, bool) or not isinstance(default, (int, float)):
        return None
    return float(default)


def _engine_default_trace_width_mm() -> float | None:
    """The width the ROUTER routes at when the caller sets none (see
    :func:`_engine_default_mm`). Kept as a named accessor because the candidate
    overlay's contract is specifically about the TRACE WIDTH."""
    return _engine_default_mm("trace_width")


def _nonnegative_mm(value) -> float | None:
    """A finite, non-negative millimetre scalar, or None.

    The clearance sibling of :func:`ir_candidates.positive_mm`. Clearance differs
    from a copper dimension in one way that matters: **zero is a legal value**. A
    caller who explicitly asks for ``clearance: 0`` is asking for no clearance,
    and silently promoting that to the board's rule would change what an explicit
    option MEANS. positive_mm would do exactly that, so it is not reused here."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    v = float(value)
    if v < 0.0 or v != v or v in (float("inf"), float("-inf")):
        return None
    return v


def _ir_rule_mm(rb, *path: str, predicate) -> float | None:
    """One design-rule scalar off the compiled IR, or None if it cannot be read.

    ``rb.design_rules`` is validated at IR construction (resolved_board.py:463 /
    :484), so on a real ResolvedBoard these always resolve; the tolerant read is
    for the boundary, not for the happy path. None means "this board could not
    tell us", which the precedence chain turns into the next source and,
    ultimately, into a fail-closed reply — never into an invented number."""
    node = rb
    for name in path:
        node = getattr(node, name, None)
        if node is None:
            return None
    return predicate(node)


# PRECEDENCE — the run's EFFECTIVE design rules (Round E2; the "Not yet done"
# entry of pcb/docs/routing.md, which is where this order is documented for
# consumers). Highest first:
#
#   1. an explicit caller option   (params.options.trace_width / .clearance)
#   2. a hint-authored width       (route hints; TRACE WIDTH ONLY — a route hint
#                                   has no clearance field to author)
#   3. the compiled board's own design rules
#        width     <- design_rules.defaults.trace_width_mm   (what the board
#                     authors as its routing default, and what acceptance writes)
#        clearance <- design_rules.minimums.min_clearance_mm  (the board's
#                     authored clearance already raised to the versioned fab
#                     floor by compile_board._floor_with_clearance; the SAME
#                     field ir_connectivity publishes as design_rules.clearance_mm
#                     and drc_geometric enforces, so routing cannot reserve less
#                     space than DRC will demand)
#   4. the engine's own signature default (_engine_default_mm)
#
# Steps 1 and 2 keep their meaning — this round only inserts step 3 ahead of what
# used to be the sole fallback. Before it, a board authoring a 0.35mm floor was
# routed at the engine's 0.25 unless the caller passed options.
#
# An explicit step-1 option is ADMITTED OR REJECTED, never reinterpreted (see
# _explicit_mm): absent falls through, present-but-inadmissible fails closed
# naming the value. The two dimensions differ only in their predicate —
# `clearance: 0` is a coherent request and is honoured, `trace_width: 0` is not
# copper and is refused.
#
# If NOTHING in the chain yields a usable number the route FAILS CLOSED
# (unsupported_geometry). There is no invented default: routing at a made-up
# width would reserve space that has nothing to do with the copper the board
# will actually be fabricated with, which is the class of bug this campaign has
# been removing one round at a time.


def _first_sourced(*steps) -> float | None:
    """The first precedence step that yields a value, or None if none does.

    Exists so a step yielding ``0.0`` counts as SOURCED. An ``or`` chain would
    skip past it — see the note in :func:`_effective_routing_rules`."""
    for step in steps:
        value = step()
        if value is not None:
            return value
    return None


def _explicit_mm(kw: dict, key: str, predicate, expected: str) -> float | None:
    """An explicitly-supplied option, admitted or REJECTED — never reinterpreted.

    None means "the caller said nothing", so the next precedence step applies. A
    key that is PRESENT but inadmissible (0 or -1 for a width, NaN, a string)
    raises instead of silently falling through to the board's rule: quietly
    routing at a different number than the caller asked for is the same class of
    dishonesty as quietly routing at the engine's default, which is what this
    round removed. Rejecting it names the value in the reply.

    Note the two dimensions differ only in their PREDICATE, not in this policy:
    ``clearance: 0`` is admissible (asking for no clearance is a coherent
    request) while ``trace_width: 0`` is not (zero-width copper is not copper).
    """
    if key not in kw:
        return None
    value = predicate(kw[key])
    if value is None:
        from .route_bridge import UnsupportedGeometry
        raise UnsupportedGeometry(
            f"option {key!r}={kw[key]!r} is not {expected}; routing fails closed "
            f"rather than silently substitute a different value for the one the "
            f"caller asked for")
    return value


def _effective_routing_rules(kw: dict, rb) -> tuple[float, float]:
    """(trace_width_mm, clearance_mm) for this run, or raise UnsupportedGeometry.

    ``kw`` carries steps 1 and 2 already merged by ``_route`` (the caller option
    wins there, exactly as before). This resolves steps 3 and 4 behind them and
    returns the pair the ENGINE, the GRID's keepout inflation and the candidate
    overlay all consume — one value, three consumers, so they cannot disagree.
    """
    from .route_bridge import UnsupportedGeometry

    # DELIBERATELY NOT AN `or` CHAIN. `or` treats 0.0 as "absent", which is the
    # one value that differs between the two dimensions: a zero clearance is a
    # legal request, and a zero engine default would have fallen THROUGH to the
    # next term while still passing an `is None` guard — the run and the overlay
    # would then have disagreed about the width, which is what this round exists
    # to prevent. Every step below is an explicit `is None` test, and every value
    # (including step 4's) goes through the same admission predicate.
    width = _first_sourced(
        # 1 + 2. An explicit caller option or a merged hint width. A value that is
        # PRESENT but inadmissible raises rather than falling through — see
        # _explicit_mm. Only the caller can put an inadmissible value here: a hint
        # width reaches kw only via `if translation.trace_width_mm`, already > 0.
        lambda: _explicit_mm(kw, "trace_width", ir_candidates.positive_mm,
                             "a positive, finite trace width in mm"),
        # 3. The board's own authored routing default.
        lambda: _ir_rule_mm(rb, "design_rules", "defaults", "trace_width_mm",
                            predicate=ir_candidates.positive_mm),
        # 4. What the engine would have applied, read from its signature.
        lambda: ir_candidates.positive_mm(_engine_default_trace_width_mm()),
    )
    if width is None:
        raise UnsupportedGeometry(
            "no trace width could be sourced for this run (no caller option, no "
            "hint width, no design_rules.defaults.trace_width_mm on the compiled "
            "board, and the engine's own default is unreadable) — routing fails "
            "closed rather than route at an invented width")

    clearance = _first_sourced(
        lambda: _explicit_mm(kw, "clearance", _nonnegative_mm,
                             "a non-negative, finite clearance in mm"),
        lambda: _ir_rule_mm(rb, "design_rules", "minimums", "min_clearance_mm",
                            predicate=_nonnegative_mm),
        lambda: _nonnegative_mm(_engine_default_mm("clearance")),
    )
    if clearance is None:
        raise UnsupportedGeometry(
            "no clearance could be sourced for this run (no caller option, no "
            "design_rules.minimums.min_clearance_mm on the compiled board, and "
            "the engine's own default is unreadable) — routing fails closed "
            "rather than reserve an invented keepout")

    return (width, clearance)


def _routes_to_candidates(routes: list) -> tuple[list, list]:
    """Split proposed routes into checkable CANDIDATES and the ones with no
    geometry to check. Each route becomes one candidate identified by its index +
    net, because a route reply carries no id of its own; the index is what a
    canvas already uses to address a ghost. Returns (candidates, empty_indices)."""
    candidates: list = []
    empty: list = []
    for index, r in enumerate(routes):
        if not isinstance(r, dict):
            empty.append(index)
            continue
        segments = [s for s in (r.get("segments") or []) if isinstance(s, dict)]
        vias = [v for v in (r.get("vias") or []) if v is not None]
        if not segments and not vias:
            empty.append(index)
            continue
        candidates.append({
            "candidate_id": f"route[{index}]",
            # A route reply carries no revision; the union's `source_digest`
            # (the compiled board's) is what makes a stale result detectable here.
            "revision": None,
            "net": r.get("net"),
            "segments": [dict(s, id=str(s.get("id", "") or f"segment:{i}"))
                         for i, s in enumerate(segments)],
            # Span is top<->bottom because the vendored engine is 2-layer only
            # (see _ROUTABLE_KICAD_LAYERS in route_bridge); a route reply carries
            # no span of its own. IF THIS IS COPIED to a board with inner copper,
            # this hardcode would silently UNDER-model the span and the overlay
            # would miss collisions on the layers it skipped. Read the span from
            # the route when the engine learns to emit one.
            "vias": [{"id": f"via:{i}", "position": v, "from_layer": "top",
                      "to_layer": "bottom"} for i, v in enumerate(vias)],
        })
    return candidates, empty


def _attach_route_geometric_drc(payload: dict, rb, *,
                                trace_width_mm: float | None = None) -> None:
    """Mutate payload in place with the GEOMETRIC candidate verdict.

    Each route gains ``"drc_geometric"`` and the payload gains
    ``"drc_geometric_summary"`` (the full candidate union — findings, per-candidate
    verdicts, and the board's own pre-existing ``baseline``).

    DELIBERATELY NOT SPELLED ``clean``. The connectivity attach uses
    ``clean: bool|None``; this one uses ``verdict: "clean"|"violations"|
    "indeterminate"`` so the two can never be confused by a consumer reading a
    truthy field, and so "the check could not run" cannot be read as "the check
    passed". A geometric fault never fails the route call — the proposal still
    returns, with an honest indeterminate verdict.

    Candidate via geometry comes from the board's OWN authored routing defaults
    (``design_rules.via_diameter_mm``/``via_drill_mm``), which is what acceptance
    writes; the trace width is the width the engine routed at. Nothing is
    invented — a value the overlay cannot source makes it fail closed.
    """
    routes = payload.get("routes")
    if not isinstance(routes, list):
        return

    candidates, empty = _routes_to_candidates(routes)
    try:
        defaults = rb.design_rules.defaults
        union = ir_candidates.check_candidates(
            rb, candidates,
            default_width_mm=trace_width_mm,
            default_via_diameter_mm=defaults.via_diameter_mm,
            default_via_drill_mm=defaults.via_drill_mm)
    except Exception as exc:  # noqa: BLE001 - a fault is NOT a clean.
        union = ir_candidates.candidate_indeterminate(
            "internal", f"geometric candidate DRC raised {exc!r}")

    payload["drc_geometric_summary"] = union

    if not union.get("ok"):
        shared = {"scope": union.get("scope"), "verifies_geometry": False,
                  "verdict": "indeterminate", "error": union.get("error")}
        for r in routes:
            if isinstance(r, dict):
                r["drc_geometric"] = dict(shared)
        return

    # An empty route never reaches the overlay (there is no copper to project),
    # so per_candidate would omit it and a caller reading ONLY the summary would
    # see an all-clean verdict with no sign that a route went unchecked. Record
    # them explicitly, for the same reason the per-route branch below refuses to
    # say "clean": silence about copper that was not checked is the dishonesty
    # this surface exists to remove.
    for index in empty:
        union.setdefault("per_candidate", {})[f"route[{index}]"] = {
            "revision": None, "verdict": "indeterminate", "finding_count": 0,
            "reason": "route carries no segments or vias to check"}

    by_candidate: dict = {}
    for finding in union.get("findings", []):
        for subject in finding.get("subjects", []):
            cid = subject.get("candidate_id")
            if cid and cid != ir_candidates.BOARD_SUBJECT_ID:
                by_candidate.setdefault(cid, []).append(finding)

    for index, r in enumerate(routes):
        if not isinstance(r, dict):
            continue
        if index in empty:
            # Nothing to model. Saying "clean" about copper that does not exist
            # would be the exact dishonesty this surface was built to remove.
            r["drc_geometric"] = {
                "scope": union["scope"], "verifies_geometry": False,
                "verdict": "indeterminate",
                "error": {"kind": "unsupported_geometry",
                          "message": "route carries no segments or vias to check",
                          "diagnostics": []}}
            continue
        violations = by_candidate.get(f"route[{index}]", [])
        r["drc_geometric"] = {
            "scope": union["scope"], "verifies_geometry": True,
            "verdict": "violations" if violations else "clean",
            "violations": violations}


def _route(params: dict) -> dict:
    """Autoroute a board with the vendored agent_router engine.

    See the module-level note above for the input/output contract. Engine
    faults are returned as structured errors (never crash the loop).
    """
    bridge_warnings: list = []
    compile_warnings: list = []  # non-fatal compile diagnostics (canonical path)
    drawn_routes: list = []
    selected_hint_ids: list = []
    drc_board: dict | None = None  # set only on the CANONICAL path (see below)
    # The COMPILED board the router consumed — the base the geometric candidate
    # overlay layers proposals onto (019f952b99f2). Same single compile as the
    # other two consumers; canonical path only, like drc_board.
    geometric_board = None

    # Only pass through options the engine actually accepts.
    opts = params.get("options") or {}
    kw: dict = {}
    for key in ("allow_vias", "single_layer", "order",
                "trace_width", "clearance", "grid_resolution"):
        if key in opts and opts[key] is not None:
            kw[key] = opts[key]

    from agent_router.router import route_board, route_board_with_hints

    _board = params.get("board")
    if isinstance(_board, dict) and "pads" in _board \
            and "components" not in _board:
        # Native pad-list shape retired this round (module note above, and
        # pcb/docs/routing.md "Not yet done"): no compile, no IR, no DRC of
        # any kind, and a missing pad size silently became `0x0` — the same
        # class of fictional copper Round E1 removed from the canonical path.
        # Reject it BY NAME here rather than falling through to
        # board_model.load_board below, which rejects it too but with a
        # message that never names what to send instead.
        #
        # Deliberately narrow, in two directions.
        #
        # It fires ONLY on a board that actually carries "pads". Every other
        # malformed input — {}, a non-dict board, a bad yaml type, a dict with
        # neither key — falls through to load_board, whose message accurately
        # describes what IS wrong with it. Gating on "is this not canonical?"
        # instead would have been shorter and would have told a caller who
        # sent {} that the pads shape was retired: a misdiagnosis of an input
        # that never used that shape.
        #
        # And it requires "components" to be ABSENT. A board carrying BOTH
        # keys is treated as canonical, not as an ambiguous shape needing its
        # own error. Before this round the opposite held — any "pads" key
        # vetoed "components" — so a structurally canonical board fell through
        # to the unsafe uncompiled branch on nothing more than a leftover key.
        # No legitimate canonical producer emits a top-level "pads" (canonical
        # pads live under each component's "pins", see docs/board-yaml.md), so
        # treating it as inert is the same "unknown fields survive" tolerance
        # the rest of the canonical contract already extends.
        return {"ok": False, "error": {"kind": "parse", "message": (
            "the flat \"pads\" list board shape was retired; send a "
            "canonical board dict with a \"components\" list, or \"yaml\" "
            "source (see pcb/docs/board-yaml.md).")}}

    # --- Canonical board + pcb_route_hint envelopes -> engine (bridge) ---
    from . import route_bridge
    try:
        board_dict = board_model.load_board(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    # DRC-at-propose runs against the projection of the SAME compiled board the
    # router consumes (set below, once the compile succeeds) — never the raw
    # dict. See ir_connectivity: one compile feeds both halves of the reply.
    drc_board = None
    # ROUND E CUTOVER (019f783860c8): canonical routing consumes the compiled
    # ResolvedBoard IR or it does not route. Before this, the router was handed
    # the RAW board and invented a nominal 1.0x1.0 land for any pad without
    # authored geometry — keepouts around fictional copper, so an accepted
    # proposal could cross the real package land. The owner-ratified Step-4
    # ruling puts ROUTING in the fail-closed bucket ("No approximated copper"),
    # so an uncompilable board now returns its compile diagnostics and ZERO
    # routes. Compiled against the narrower ROUTING capability profile: a
    # mask-only limitation must not disable routing, but any dropped
    # copper/drill/rule is still fatal.
    compiled = _compile_or_fail(
        board_dict, requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    if _is_error_reply(compiled):
        return compiled
    compile_warnings = [_diagnostic_to_payload(d) for d in compiled.diagnostics]
    # ONE compile, BOTH halves of the reply (019f97d021a8), under ONE error
    # boundary (019f97eb6adf). Routing consumes the IR; connectivity DRC
    # consumes the connectivity projection of that same compiled board. Both
    # projections sit inside this try, so EITHER one meeting geometry it cannot
    # model faithfully produces the same structured zero-route reply — the
    # connectivity projection used to run ahead of the guard, where its failure
    # would have escaped the route error envelope entirely.
    try:
        board = route_bridge.resolved_board_to_router(compiled.board)
        drc_board = ir_connectivity.connectivity_board(compiled.board)
        geometric_board = compiled.board
    except route_bridge.UnsupportedGeometry as exc:
        # Compiled fine, but carries geometry the routing grid cannot model
        # faithfully (inner copper, accepted traces/vias, zones, a copper
        # graphic, a non-rectangular outline). Fail closed with its own kind so
        # a consumer can tell "this board will not compile" from "this board
        # compiles but is not routable yet".
        return {"ok": False, "error": {
            "kind": "unsupported_geometry", "message": str(exc),
            "diagnostics": compile_warnings}}
    except Exception as exc:
        return {"ok": False, "error": {"kind": "route",
                "message": f"invalid board: {exc}",
                "traceback": traceback.format_exc()}}

    envelopes = params.get("route_hints") or []
    if not isinstance(envelopes, list):
        return {"ok": False, "error": {"kind": "parse",
                "message": "route_hints must be a list of envelopes"}}
    # Route-as-drawn (HITL-2): 'detailed' single-trace hints ARE the route.
    # Materialize them directly, consume their nets so the engine neither
    # re-routes nor duplicates them, and keep everything else on the
    # engine-guided path.
    drawn_routes, consumed_nets, drawn_warnings, consumed_ids = \
        route_bridge.materialize_detailed_hints(
            envelopes, board, params.get("selection"))
    for net_name in consumed_nets:
        board.nets.pop(net_name, None)
    remaining = [e for e in envelopes
                 if str((e or {}).get("id", "")) not in consumed_ids] \
        if consumed_ids else envelopes
    translation = route_bridge.hints_to_router(
        remaining, board, params.get("selection"))
    bridge_warnings = drawn_warnings + translation.warnings
    selected_hint_ids = consumed_ids + [
        i for i in translation.selected_ids if i not in consumed_ids]
    # A hint-authored width becomes the run's trace_width unless the caller
    # set one explicitly (per-hint width has no RoutingHints slot).
    if translation.trace_width_mm and "trace_width" not in kw:
        kw["trace_width"] = translation.trace_width_mm

    # EFFECTIVE DESIGN RULES (Round E2) — see the precedence note above
    # _effective_routing_rules. Both values are now ALWAYS passed explicitly, so
    # the engine's signature defaults are no longer what a board gets routed at,
    # and the grid inflates its keepouts by `clearance + trace_width / 2` using
    # this exact pair (agent_router/grid.py::keepout_margin). Plumbing the width
    # WITHOUT the matching inflation would be worse than neither: the router
    # would path a 0.35mm trace against keepouts reserved for 0.25mm, so the
    # proposed copper would be wider than the space held for it.
    try:
        kw["trace_width"], kw["clearance"] = _effective_routing_rules(
            kw, compiled.board)
    except route_bridge.UnsupportedGeometry as exc:
        return {"ok": False, "error": {
            "kind": "unsupported_geometry", "message": str(exc),
            "diagnostics": compile_warnings}}

    try:
        if translation.hints.net_hints or translation.hints.buses \
                or translation.hints.chains or translation.hints.internal_bridges:
            result = route_board_with_hints(board, translation.hints, **kw)
        else:
            result = route_board(board, **kw)
    except Exception as exc:
        return {"ok": False, "error": {"kind": "route",
                "message": str(exc), "traceback": traceback.format_exc()}}

    payload = _serialize_routing_result(result)
    if drawn_routes:
        payload["routes"] = drawn_routes + payload["routes"]
        payload["success"] = bool(payload.get("success", False)) or not payload.get("unrouted")
    # Non-fatal COMPILE diagnostics travel with the proposal too (Codex ruling 2):
    # a route computed over a board that compiled with warnings must not look
    # indistinguishable from one that compiled clean.
    if bridge_warnings or compile_warnings:
        payload["warnings"] = bridge_warnings + compile_warnings
    if selected_hint_ids:
        payload["selected_hint_ids"] = selected_hint_ids

    # DRC-at-propose (docket 019f6f1492e0): every call reaching here is on the
    # canonical path (the native pad-list shape is rejected at the top of
    # _route, everything else by load_board), so drc_board is always set below.
    if drc_board is not None:
        _attach_route_drc(payload, drc_board)
    # GEOMETRIC DRC-at-propose (019f952b99f2) — the copper complement, attached
    # ALONGSIDE the connectivity result above (never instead of it). The overlay
    # is checked at the width the run ACTUALLY routed at: since E2 that is
    # `kw["trace_width"]` itself, the one value _effective_routing_rules resolved
    # and handed to the engine, so a proposal can no longer be geometrically
    # cleared at a width it was not routed at (a false clean). This USED to be a
    # parallel re-derivation of the same precedence, which agreed by coincidence
    # rather than by construction; the coincidence is now a shared variable.
    if geometric_board is not None:
        _attach_route_geometric_drc(
            payload, geometric_board,
            trace_width_mm=ir_candidates.positive_mm(kw.get("trace_width")))

    return {"ok": True, "result": payload}


# ---------------------------------------------------------------------------
# draft_check (T2.4) — honest DRC over the COMPLETE effective candidate set.
#
# The reusable NATIVE draft-check seam T5 (verbs) depends on. Unlike route()'s
# DRC-at-propose (which checks the ONE route it just computed), draft_check is
# SET-SCOPED: it runs the EXISTING drc.run_drc primitives (drc.py's four checks,
# reused verbatim — this reimplements no rule) over the UNION of the board's
# committed copper AND every candidate's draft segments/vias. A verdict for a
# candidate therefore depends on the whole effective set — a collision between
# two candidates, or between a candidate and committed copper, is found.
#
# ON-DEMAND ONLY. Debounce/coalescing/cancellation/auto-recheck are T6 and are
# NOT built here — draft_check is a pure function of its params.
#
# params = {
#   board: <canonical board dict>,
#   candidates: [{candidate_id, net, revision, segments:[{id,layer,width,points}],
#                 vias:[{id,position,from_layer,to_layer,...}]}],
#   board_token: <opaque str — the GD board-coherence fingerprint>,
#   workspace_generation: <opaque int — the GD workspace generation>,
# }
# Segment points and via positions travel as [[x,y], ...] / [x,y] (JSON-friendly,
# mirroring route()'s segment coordinate style); {x_mm,y_mm}/{x,y} dicts are also
# accepted defensively. Candidate layers are canonical "top"/"bottom" (same
# spelling as committed board traces) so drc's raw-string layer equality lines
# up; F.Cu/B.Cu are normalized defensively.
#
# reply = {ok, result: {board_token, workspace_generation, findings:[...],
#          per_candidate:{candidate_id: "clean"/"violating"/"error"}}}
# board_token + workspace_generation are ECHOED VERBATIM (never coerced) so the
# GD side can discard a stale reply. Each finding names SUBJECT IDENTITY —
# subjects:[{candidate_id, segment_id?/via_id?}] — not net-only; a violation
# between two candidates names BOTH subjects (candidate-vs-committed names the
# candidate + a {candidate_id:"board"} subject).
# ---------------------------------------------------------------------------


def _dc_dist(a, b) -> float:
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


# The candidate wire-shape coercion moved to the neutral :mod:`ir_candidates`
# owner (019f952b99f2) so the CONNECTIVITY candidate surface (draft_check) and the
# GEOMETRIC one accept exactly the same candidate language. A shape one accepts
# and the other silently drops would be a correctness trap. Aliased, not
# re-implemented; the local names are kept for existing callers/tests.
_dc_points = ir_candidates.candidate_points
_dc_via_pos = ir_candidates.candidate_via_position


def _dc_pt_touches_seg(pt, a, b, eps: float) -> bool:
    """True if pt lies within eps of segment a-b (endpoints included)."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    if seg_len2 <= 1e-18:
        return _dc_dist(pt, a) <= eps
    t = ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / seg_len2
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    proj = (ax + t * dx, ay + t * dy)
    return _dc_dist(pt, proj) <= eps


def _dc_clearance(board) -> float:
    """Same clearance derivation drc.run_drc uses — the attribution tolerance."""
    clr = drc.DEFAULT_COINCIDENT_MM
    dr = (board or {}).get("design_rules") if isinstance(board, dict) else None
    if isinstance(dr, dict):
        c = dr.get("clearance_mm")
        if isinstance(c, (int, float)) and not isinstance(c, bool) and c > 0:
            clr = float(c)
    return clr


def _dc_attribute(finding: dict, seg_subjects: list, via_subjects: list,
                  eps: float) -> list:
    """Map a drc.py finding back to the candidate/board subjects it names.

    A finding carries only net(s) + an `at` point (drc is net-scoped); this
    re-derives WHICH candidate segment/via that point falls on so the seam can
    surface subject identity. crossing names both crossing nets' segments;
    the endpoint checks (wrong_net_pad / dangling / layer_change_no_via) name
    the offending net's segments (and any candidate via coincident with `at`,
    e.g. the layer-change meeting point)."""
    at = finding.get("at")
    if not (isinstance(at, (list, tuple)) and len(at) >= 2):
        return []
    pt = (float(at[0]), float(at[1]))
    kind = finding.get("type")
    subjects: list = []
    seen: set = set()

    if kind == "crossing":
        nets = {str(n) for n in (finding.get("nets") or [])}
        layer = finding.get("layer")
        for s in seg_subjects:
            if s["net"] in nets and s["layer"] == layer \
                    and _dc_pt_touches_seg(pt, s["a"], s["b"], eps):
                key = ("seg", s["candidate_id"], s["segment_id"])
                if key not in seen:
                    seen.add(key)
                    subjects.append({"candidate_id": s["candidate_id"],
                                     "segment_id": s["segment_id"]})
    else:
        net = str(finding.get("net"))
        for s in seg_subjects:
            if s["net"] == net and _dc_pt_touches_seg(pt, s["a"], s["b"], eps):
                key = ("seg", s["candidate_id"], s["segment_id"])
                if key not in seen:
                    seen.add(key)
                    subjects.append({"candidate_id": s["candidate_id"],
                                     "segment_id": s["segment_id"]})
        for v in via_subjects:
            if _dc_dist(pt, v["pos"]) <= eps:
                key = ("via", v["candidate_id"], v["via_id"])
                if key not in seen:
                    seen.add(key)
                    subjects.append({"candidate_id": v["candidate_id"],
                                     "via_id": v["via_id"]})
    return subjects


def _draft_check(params: dict) -> dict:
    board = params.get("board")
    candidates = params.get("candidates") or []
    # Echoed VERBATIM (no int/str coercion) so the GD guard can compare exactly.
    board_token = params.get("board_token")
    workspace_generation = params.get("workspace_generation")

    def _reply(findings, per_candidate, error=None):
        result = {
            "board_token": board_token,
            "workspace_generation": workspace_generation,
            "findings": findings,
            "per_candidate": per_candidate,
        }
        if error is not None:
            result["error"] = error
        return {"ok": True, "result": result}

    per_candidate: dict = {}
    seg_subjects: list = []  # {candidate_id, segment_id, net, layer, a, b}
    via_subjects: list = []  # {candidate_id, via_id, pos}

    # Committed board copper as SUBJECTS (candidate_id="board") so a
    # candidate-vs-committed collision can name the board side too. Traces on
    # disk are canonical top/bottom {x_mm,y_mm} polylines.
    base_traces: list = []
    base_vias: list = []
    if isinstance(board, dict):
        base_traces = list(board.get("traces")) if isinstance(board.get("traces"), list) else []
        base_vias = list(board.get("vias")) if isinstance(board.get("vias"), list) else []
        for tr in base_traces:
            if not isinstance(tr, dict):
                continue
            net = str(tr.get("net", ""))
            layer = _canonical_drc_layer(tr.get("layer"))
            pts = [(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0)))
                   for p in (tr.get("points") or []) if isinstance(p, dict)]
            for a, b in zip(pts, pts[1:]):
                seg_subjects.append({"candidate_id": "board", "segment_id": "",
                                     "net": net, "layer": layer, "a": a, "b": b})

    new_traces: list = []
    new_vias: list = []
    for cand in candidates:
        if not isinstance(cand, dict):
            continue
        cid = str(cand.get("candidate_id", ""))
        net = str(cand.get("net", ""))
        per_candidate.setdefault(cid, "clean")
        had_geometry = False
        for seg in cand.get("segments") or []:
            if not isinstance(seg, dict):
                continue
            pts = _dc_points(seg.get("points"))
            if len(pts) < 2:
                continue
            had_geometry = True
            sid = str(seg.get("id", ""))
            layer = _canonical_drc_layer(seg.get("layer"))
            width = float(seg.get("width", 0.25) or 0.25)
            new_traces.append({
                "net": net, "layer": layer, "width_mm": width,
                "points": [{"x_mm": p[0], "y_mm": p[1]} for p in pts],
            })
            for a, b in zip(pts, pts[1:]):
                seg_subjects.append({"candidate_id": cid, "segment_id": sid,
                                     "net": net, "layer": layer, "a": a, "b": b})
        for via in cand.get("vias") or []:
            if not isinstance(via, dict):
                continue
            pos = _dc_via_pos(via)
            if pos is None:
                continue
            had_geometry = True
            vid = str(via.get("id", ""))
            new_vias.append({"x_mm": pos[0], "y_mm": pos[1],
                             "from_layer": _canonical_drc_layer(via.get("from_layer", "top")),
                             "to_layer": _canonical_drc_layer(via.get("to_layer", "bottom"))})
            via_subjects.append({"candidate_id": cid, "via_id": vid, "pos": pos})
        if not had_geometry:
            # A candidate with no usable geometry can't be checked → error verdict.
            per_candidate[cid] = "error"

    # Effective board = committed copper ∪ every candidate's draft copper.
    effective: dict = dict(board) if isinstance(board, dict) else {}
    effective["traces"] = base_traces + new_traces
    effective["vias"] = base_vias + new_vias

    try:
        drc_result = drc.run_drc(effective)
    except Exception as exc:  # geometry faults reported as data, mirrors _drc()
        for cid in per_candidate:
            per_candidate[cid] = "error"
        return _reply([], per_candidate, error=str(exc))

    eps = _dc_clearance(board)
    findings_out: list = []
    for f in drc_result.get("findings", []):
        if not isinstance(f, dict):
            continue
        subjects = _dc_attribute(f, seg_subjects, via_subjects, eps)
        finding: dict = {"kind": f.get("type"), "subjects": subjects,
                         "at": f.get("at")}
        if f.get("type") == "crossing":
            finding["nets"] = f.get("nets")
            finding["layer"] = f.get("layer")
        else:
            finding["net"] = f.get("net")
        if f.get("type") == "wrong_net_pad":
            finding["pad"] = f.get("pad")
        findings_out.append(finding)
        for s in subjects:
            scid = str(s.get("candidate_id", ""))
            # Only a real candidate flips to violating; "board" and error
            # candidates are untouched (an error candidate has no subjects).
            if scid in per_candidate and per_candidate[scid] != "error":
                per_candidate[scid] = "violating"

    return _reply(findings_out, per_candidate)


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
    "gerbers": lambda req: _gerbers(req.get("params") or {}),
    "drc": lambda req: _drc(req.get("params") or {}),
    "drc_geometric": lambda req: _drc_geometric(req.get("params") or {}),
    "resolve": lambda req: _resolve(req.get("params") or {}),
    "normalize": lambda req: _normalize(req.get("params") or {}),
    "check_libraries": lambda req: _check_libraries(req.get("params") or {}),
    "check_bom": lambda req: _check_bom(req.get("params") or {}),
    "route": lambda req: _route(req.get("params") or {}),
    "draft_check": lambda req: _draft_check(req.get("params") or {}),
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
