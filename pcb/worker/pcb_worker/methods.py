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

from . import board_model, drc, footprints, gerber, kicad, libcheck, resolve

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

    base_name = params.get("name") if isinstance(params.get("name"), str) else None
    try:
        files = gerber.build_gerbers(board, name=base_name)
    except Exception as exc:  # geometry/library faults reported as data, not crash
        return {"ok": False, "error": {"kind": "gerber", "message": str(exc)}}

    out_dir = params.get("out_dir")
    result: dict = {"files": files, "written": []}
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
    """Geometric design-rule check over a canonical board.

    Returns {ok, findings:[{type,...}], counts:{type:n}}. A parse failure is a
    structured error (never a crash), mirroring `generate`/`gerbers`.
    """
    try:
        board = _load(params)
    except board_model.BoardParseError as exc:
        return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
    try:
        result = drc.run_drc(board)
    except Exception as exc:  # geometry faults reported as data, not a crash
        return {"ok": False, "error": {"kind": "drc", "message": str(exc)}}
    return {"ok": True, "result": result}


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

    try:
        resolved = resolve.resolve_board(board)
    except resolve.ResolveCoincidenceError as exc:
        return {"ok": False, "error": {
            "kind": "coincidence", "message": str(exc),
            "ref": exc.ref, "pin": exc.pin, "delta_mm": exc.delta_mm}}
    except (resolve.ResolveError, footprints.FootprintLookupError) as exc:
        return {"ok": False, "error": {"kind": "resolve", "message": str(exc)}}

    stats = resolve.board_graphic_stats(resolved)
    return {"ok": True, "result": {"ok": True, "board": resolved, "stats": stats}}


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
# TWO input shapes are accepted (auto-discriminated):
#
# 1. CANONICAL (this round's bridge, 019eb481ae28): the canonical board dict +
#    pcb_route_hint annotation envelopes, translated to the engine's native
#    Board + RoutingHints by pcb_worker.route_bridge. Absolute pad positions are
#    composed from component placement + rotated pin offsets using the SAME
#    convention the panel model uses (get_pin_world_position), so panel and
#    router agree.
#
#      params.yaml  = canonical board YAML source        (or)
#      params.board = canonical board dict (has "components")
#      params.route_hints = [pcb_route_hint envelope, …]  (optional)
#      params.selection   = which hints feed the run:
#                           {"mode":"open"|"all"|"ids"|"net", …} (default open)
#
# 2. NATIVE (grandchild-1, kept for back-compat): agent_router's own flat pad
#    list, fed straight through _board_from_native.
#
#      params.board = {"pads": [{component, pad|number, net, x, y, size:[w,h],
#                                shape?, type?|pad_type?, drill?, layer?, rotation?}],
#                      "width"?, "height"?, "obstacles"?: [{type,x,y,radius?}]}
#      params.hints = agent_router native routing_hints dict (see parse_hints)
#
# COMMON:
#   params.options = {single_layer?, allow_vias?, trace_width?, clearance?,
#                     order?, grid_resolution?}
#
# OUTPUT: the engine's RoutingResult, serialised to plain JSON
#   {success, via_count, routes:[{net, segments:[{start,end,layer}], vias:[[x,y]]}],
#    unrouted:[{net, from, to}], warnings?:[{id, message}], selected_hint_ids?:[…]}
# ---------------------------------------------------------------------------


def _board_from_native(spec: dict):
    """Rebuild an agent_router.Board from its native pad-list dict.

    This lives in the worker (not in agent_router) so the engine stays a clean
    standalone package with no worker/plugin coupling. The shape mirrors the
    engine's own `dump-pads` JSON, i.e. the inverse of that serialisation.
    """
    from agent_router.board import Board, Pad, Net, Obstacle

    if not isinstance(spec, dict):
        raise ValueError("board must be a mapping")
    pad_specs = spec.get("pads")
    if not isinstance(pad_specs, list) or not pad_specs:
        raise ValueError("board.pads must be a non-empty list")

    pads: list = []
    for i, p in enumerate(pad_specs):
        if not isinstance(p, dict):
            raise ValueError(f"pads[{i}] must be a mapping")
        try:
            x = float(p["x"]); y = float(p["y"])
        except (KeyError, TypeError, ValueError):
            raise ValueError(f"pads[{i}] needs numeric x and y")
        size = p.get("size") or [0.0, 0.0]
        if not isinstance(size, (list, tuple)) or len(size) < 2:
            raise ValueError(f"pads[{i}].size must be [w, h]")
        number = p.get("number", p.get("pad"))
        pad_type = p.get("pad_type", p.get("type", "smd"))
        pads.append(Pad(
            component=str(p.get("component", "")),
            number=str(number) if number is not None else "",
            net=(str(p["net"]) if p.get("net") not in (None, "") else None),
            position=(x, y),
            size=(float(size[0]), float(size[1])),
            shape=str(p.get("shape", "rect")),
            pad_type=str(pad_type),
            drill=(float(p["drill"]) if p.get("drill") not in (None, "") else None),
            layer=str(p.get("layer", "F.Cu")),
            rotation=float(p.get("rotation", 0.0)),
        ))

    # Group pads into nets (net.number assigned in first-seen order).
    nets: dict = {}
    for pad in pads:
        if not pad.net:
            continue
        net = nets.get(pad.net)
        if net is None:
            net = Net(name=pad.net, number=len(nets) + 1, pads=[])
            nets[pad.net] = net
        net.pads.append(pad)

    obstacles: list = []
    for o in spec.get("obstacles") or []:
        if not isinstance(o, dict):
            continue
        obstacles.append(Obstacle(
            position=(float(o.get("x", 0.0)), float(o.get("y", 0.0))),
            type=str(o.get("type", "keepout")),
            radius=(float(o["radius"]) if o.get("radius") not in (None, "") else None),
        ))

    return Board(
        pads=pads,
        nets=nets,
        obstacles=obstacles,
        width=float(spec.get("width", 0.0) or 0.0),
        height=float(spec.get("height", 0.0) or 0.0),
    )


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


def _is_canonical_route_input(params: dict) -> bool:
    """True if params carry a CANONICAL board (YAML source, or a board dict with
    a "components" list) rather than agent_router's native flat "pads" list."""
    if isinstance(params.get("yaml"), str):
        return True
    b = params.get("board")
    return isinstance(b, dict) and "components" in b and "pads" not in b


# ---------------------------------------------------------------------------
# DRC-at-propose (docket 019f6f1492e0): after a successful CANONICAL route,
# build the post-route board (existing traces + every returned route
# materialized as traces) and run the EXISTING drc.run_drc engine over it —
# this reuses drc.py's four checks verbatim, it does not reimplement any rule.
# Native-pad-list routing has no canonical "components"/"nets"/"traces" board
# to check against, so DRC is skipped there (no drc/drc_summary keys added;
# _route only calls this helper on the canonical branch, see below).
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
    "drc": {"clean": bool, "violations": [...]} (filtered to findings
    involving that route's net) on success, or
    "drc": {"clean": None, "error": "<msg>"} if the DRC engine itself faults.
    payload also gains a top-level "drc_summary": {"clean", "violation_count"}
    (violation_count counts EVERY finding, including ones not attributable to
    any single proposed route — e.g. a crossing between two pre-existing
    traces). A DRC-engine fault never fails the route call — routes still
    return, just without a clean determination."""
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
                r["drc"] = {"clean": None, "error": error}
        payload["drc_summary"] = {"clean": None, "violation_count": 0, "error": error}
        return

    findings = (result or {}).get("findings", [])
    for r in routes:
        if not isinstance(r, dict):
            continue
        net = r.get("net")
        violations = [f for f in findings if _finding_involves_net(f, net)]
        r["drc"] = {"clean": len(violations) == 0, "violations": violations}
    payload["drc_summary"] = {"clean": len(findings) == 0, "violation_count": len(findings)}


def _route(params: dict) -> dict:
    """Autoroute a board with the vendored agent_router engine.

    See the module-level note above for the input/output contract. Engine
    faults are returned as structured errors (never crash the loop).
    """
    bridge_warnings: list = []
    drawn_routes: list = []
    selected_hint_ids: list = []
    drc_board: dict | None = None  # set only on the CANONICAL path (see below)

    # Only pass through options the engine actually accepts.
    opts = params.get("options") or {}
    kw: dict = {}
    for key in ("allow_vias", "single_layer", "order",
                "trace_width", "clearance", "grid_resolution"):
        if key in opts and opts[key] is not None:
            kw[key] = opts[key]

    from agent_router.router import route_board, route_board_with_hints

    if _is_canonical_route_input(params):
        # --- Canonical board + pcb_route_hint envelopes -> engine (bridge) ---
        from . import route_bridge
        try:
            board_dict = board_model.load_board(params)
        except board_model.BoardParseError as exc:
            return {"ok": False, "error": {"kind": "parse", "message": str(exc)}}
        drc_board = board_dict  # DRC-at-propose runs against this canonical board
        try:
            board = route_bridge.board_to_router(board_dict)
        except Exception as exc:
            return {"ok": False, "error": {"kind": "parse",
                    "message": f"invalid board: {exc}"}}

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

        try:
            if translation.hints.net_hints or translation.hints.buses \
                    or translation.hints.chains or translation.hints.internal_bridges:
                result = route_board_with_hints(board, translation.hints, **kw)
            else:
                result = route_board(board, **kw)
        except Exception as exc:
            return {"ok": False, "error": {"kind": "route",
                    "message": str(exc), "traceback": traceback.format_exc()}}
    else:
        # --- Native agent_router pad-list path (grandchild-1 back-compat) ---
        try:
            board = _board_from_native(params.get("board"))
        except Exception as exc:
            return {"ok": False, "error": {"kind": "parse",
                    "message": f"invalid board: {exc}"}}

        hints_data = params.get("hints")
        try:
            if hints_data:
                from agent_router.hints import parse_hints
                hints = parse_hints(hints_data)
                result = route_board_with_hints(board, hints, **kw)
            else:
                result = route_board(board, **kw)
        except Exception as exc:
            return {"ok": False, "error": {"kind": "route",
                    "message": str(exc), "traceback": traceback.format_exc()}}

    payload = _serialize_routing_result(result)
    if drawn_routes:
        payload["routes"] = drawn_routes + payload["routes"]
        payload["success"] = bool(payload.get("success", False)) or not payload.get("unrouted")
    if bridge_warnings:
        payload["warnings"] = bridge_warnings
    if selected_hint_ids:
        payload["selected_hint_ids"] = selected_hint_ids

    # DRC-at-propose (docket 019f6f1492e0): only meaningful on the canonical
    # path — the native pad-list path has no "components"/"nets"/"traces"
    # board to check proposed routes against, so it is left untouched (no
    # drc/drc_summary keys added, matching its pre-existing output exactly).
    if drc_board is not None:
        _attach_route_drc(payload, drc_board)

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


def _dc_points(raw) -> list:
    """Coerce a segment's points to [(x, y), ...]. Accepts [[x,y],...] pairs and
    {x_mm,y_mm}/{x,y} dicts."""
    out: list = []
    if isinstance(raw, list):
        for p in raw:
            if isinstance(p, (list, tuple)) and len(p) >= 2:
                out.append((float(p[0]), float(p[1])))
            elif isinstance(p, dict):
                if "x_mm" in p and "y_mm" in p:
                    out.append((float(p["x_mm"]), float(p["y_mm"])))
                elif "x" in p and "y" in p:
                    out.append((float(p["x"]), float(p["y"])))
    return out


def _dc_via_pos(raw):
    """Coerce a via position to (x, y) or None. Accepts [x,y], {x_mm,y_mm},
    {x,y}, and {position:<either>}."""
    if isinstance(raw, dict):
        if "x_mm" in raw and "y_mm" in raw:
            return (float(raw["x_mm"]), float(raw["y_mm"]))
        if "x" in raw and "y" in raw:
            return (float(raw["x"]), float(raw["y"]))
        pos = raw.get("position")
        if pos is not None:
            return _dc_via_pos(pos)
        return None
    if isinstance(raw, (list, tuple)) and len(raw) >= 2:
        return (float(raw[0]), float(raw[1]))
    return None


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
    "resolve": lambda req: _resolve(req.get("params") or {}),
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
