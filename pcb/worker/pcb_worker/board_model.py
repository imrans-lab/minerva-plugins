"""Canonical board-source model: loading, normalisation, and validation.

This module is the Python-side reader of the canonical board contract defined
in Go at pcb/internal/board/board.go and documented in pcb/docs/board-yaml.md.
It is deliberately plain Python over dicts (no circuit_synth) — the canonical
YAML is OUR schema, not circuit_synth's Circuit object graph, so validating it
is bespoke and dependency-light.

Everything here is a pure function: parse text / dict → structured result.
"""

from __future__ import annotations

from typing import Any

# Required top-level fields per the canonical contract. traces / vias / grid_mm /
# layers / origin / design_rules are optional (board.go marks them omitempty).
REQUIRED_TOP = ("version", "name", "width_mm", "height_mm", "components", "nets")


class BoardParseError(Exception):
    """Raised when board source cannot be parsed into a mapping."""


def load_board(params: dict) -> dict:
    """Resolve a board dict from a request's params.

    Accepts, in priority order:
      - params["yaml"]  : canonical YAML source string.
      - params["board"] : an already-decoded board mapping (dict).

    Raises BoardParseError on missing input or non-mapping YAML.
    """
    if isinstance(params.get("yaml"), str):
        import yaml
        try:
            data = yaml.safe_load(params["yaml"])
        except yaml.YAMLError as exc:  # type: ignore[attr-defined]
            raise BoardParseError(f"invalid YAML: {exc}") from exc
        if data is None:
            raise BoardParseError("YAML source is empty")
        if not isinstance(data, dict):
            raise BoardParseError(
                f"board YAML must be a mapping at the top level, got {type(data).__name__}"
            )
        return data
    if isinstance(params.get("board"), dict):
        return params["board"]
    raise BoardParseError("expected params.yaml (str) or params.board (object)")


def _is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _as_list(v: Any) -> list:
    return v if isinstance(v, list) else []


def board_bounds(board: dict) -> tuple[float, float, float, float]:
    """Return (min_x, min_y, max_x, max_y) of the board outline in mm.

    Outline is the axis-aligned rectangle implied by origin + width_mm/height_mm
    (per the spike board.yaml: "outline is implied by width_mm/height_mm").
    """
    origin = board.get("origin") or {}
    ox = origin.get("x_mm", 0.0) if isinstance(origin, dict) else 0.0
    oy = origin.get("y_mm", 0.0) if isinstance(origin, dict) else 0.0
    ox = ox if _is_number(ox) else 0.0
    oy = oy if _is_number(oy) else 0.0
    w = board.get("width_mm", 0.0)
    h = board.get("height_mm", 0.0)
    w = w if _is_number(w) else 0.0
    h = h if _is_number(h) else 0.0
    return (ox, oy, ox + w, oy + h)


def validate_board(board: dict) -> dict:
    """Structurally validate a canonical board mapping.

    Returns {"ok": bool, "errors": [...], "warnings": [...]} where each entry is
    {"path": "<field path>", "message": "..."}. ok is True iff errors is empty.

    Checks (per the board-yaml contract):
      - required top-level fields present + correct scalar types;
      - component ref uniqueness + required component fields;
      - net pin refs ("Ref.Pad") resolve to an existing component, and to a
        declared pin when the component declares pins;
      - traces reference an existing net;
      - coordinates within the board outline (soft → warning);
      - trace width vs design_rules.trace_width_mm, via drill vs diameter.
    """
    errors: list[dict] = []
    warnings: list[dict] = []

    def err(path: str, msg: str) -> None:
        errors.append({"path": path, "message": msg})

    def warn(path: str, msg: str) -> None:
        warnings.append({"path": path, "message": msg})

    # --- Required top-level fields ---
    for field in REQUIRED_TOP:
        if field not in board:
            err(field, f"missing required field '{field}'")

    if "width_mm" in board and not _is_number(board["width_mm"]):
        err("width_mm", "width_mm must be a number")
    if "height_mm" in board and not _is_number(board["height_mm"]):
        err("height_mm", "height_mm must be a number")
    if "version" in board and not isinstance(board["version"], int):
        warn("version", "version should be an integer (contract/schema version)")
    if "name" in board and not isinstance(board.get("name"), str):
        err("name", "name must be a string")

    min_x, min_y, max_x, max_y = board_bounds(board)
    in_bounds_ok = _is_number(board.get("width_mm")) and _is_number(board.get("height_mm"))

    def check_point(path: str, x: Any, y: Any) -> None:
        if not in_bounds_ok:
            return
        if not (_is_number(x) and _is_number(y)):
            return
        if not (min_x <= x <= max_x and min_y <= y <= max_y):
            warn(path, f"coordinate ({x}, {y}) is outside the board outline "
                       f"[{min_x},{min_y}]–[{max_x},{max_y}]")

    # --- Components ---
    components = _as_list(board.get("components"))
    refs: dict[str, int] = {}
    comp_pins: dict[str, set[str]] = {}
    comp_has_pins: dict[str, bool] = {}
    for i, comp in enumerate(components):
        cpath = f"components[{i}]"
        if not isinstance(comp, dict):
            err(cpath, "component must be a mapping")
            continue
        ref = comp.get("ref")
        if not isinstance(ref, str) or ref == "":
            err(f"{cpath}.ref", "component is missing a non-empty 'ref'")
        else:
            if ref in refs:
                err(f"{cpath}.ref", f"duplicate component ref '{ref}' "
                                    f"(also at components[{refs[ref]}])")
            else:
                refs[ref] = i
        if not comp.get("footprint"):
            warn(f"{cpath}.footprint", "component has no footprint")
        check_point(f"{cpath}.position", comp.get("x_mm"), comp.get("y_mm"))

        # Index this component's pin numbers for net-ref resolution.
        pins = _as_list(comp.get("pins"))
        comp_has_pins[ref] = len(pins) > 0
        numset: set[str] = set()
        for j, pin in enumerate(pins):
            if not isinstance(pin, dict):
                err(f"{cpath}.pins[{j}]", "pin must be a mapping")
                continue
            num = pin.get("number")
            if num is None or str(num) == "":
                err(f"{cpath}.pins[{j}].number", "pin is missing 'number'")
            else:
                numset.add(str(num))
        if isinstance(ref, str) and ref != "":
            comp_pins[ref] = numset

    # --- Nets ---
    nets = _as_list(board.get("nets"))
    net_names: set[str] = set()
    for i, net in enumerate(nets):
        npath = f"nets[{i}]"
        if not isinstance(net, dict):
            err(npath, "net must be a mapping")
            continue
        name = net.get("name")
        if not isinstance(name, str) or name == "":
            err(f"{npath}.name", "net is missing a non-empty 'name'")
        else:
            net_names.add(name)
        for j, pinref in enumerate(_as_list(net.get("pins"))):
            ppath = f"{npath}.pins[{j}]"
            if not isinstance(pinref, str) or "." not in pinref:
                err(ppath, f"pin ref {pinref!r} must be a 'Ref.Pad' string")
                continue
            ref, _, pad = pinref.rpartition(".")
            if ref not in refs:
                err(ppath, f"pin ref '{pinref}' names unknown component '{ref}'")
                continue
            if comp_has_pins.get(ref):
                if pad not in comp_pins.get(ref, set()):
                    err(ppath, f"pin ref '{pinref}' names pad '{pad}' not declared "
                               f"on component '{ref}' (declared: "
                               f"{sorted(comp_pins.get(ref, set()))})")
            else:
                warn(ppath, f"cannot verify pad '{pad}' — component '{ref}' "
                            f"declares no pins")

    # --- Traces ---
    dr = board.get("design_rules") or {}
    dr_trace_w = dr.get("trace_width_mm") if isinstance(dr, dict) else None
    for i, tr in enumerate(_as_list(board.get("traces"))):
        tpath = f"traces[{i}]"
        if not isinstance(tr, dict):
            err(tpath, "trace must be a mapping")
            continue
        tnet = tr.get("net")
        if not isinstance(tnet, str) or tnet == "":
            err(f"{tpath}.net", "trace is missing a 'net'")
        elif tnet not in net_names:
            err(f"{tpath}.net", f"trace references unknown net '{tnet}'")
        w = tr.get("width_mm")
        if w is not None:
            if not _is_number(w) or w <= 0:
                err(f"{tpath}.width_mm", f"trace width must be a positive number, got {w!r}")
            elif _is_number(dr_trace_w) and w < dr_trace_w:
                warn(f"{tpath}.width_mm", f"trace width {w} is narrower than "
                                         f"design_rules.trace_width_mm ({dr_trace_w})")
        pts = _as_list(tr.get("points"))
        if len(pts) < 2:
            err(f"{tpath}.points", f"trace needs >=2 points to form a segment, got {len(pts)}")
        for j, pt in enumerate(pts):
            if isinstance(pt, dict):
                check_point(f"{tpath}.points[{j}]", pt.get("x_mm"), pt.get("y_mm"))

    # --- Vias ---
    for i, via in enumerate(_as_list(board.get("vias"))):
        vpath = f"vias[{i}]"
        if not isinstance(via, dict):
            err(vpath, "via must be a mapping")
            continue
        check_point(vpath, via.get("x_mm"), via.get("y_mm"))
        drill = via.get("drill_mm")
        dia = via.get("diameter_mm")
        if _is_number(drill) and _is_number(dia) and drill >= dia:
            err(f"{vpath}.drill_mm", f"via drill ({drill}) must be smaller than "
                                     f"its diameter ({dia})")
        vnet = via.get("net")
        if isinstance(vnet, str) and vnet != "" and vnet not in net_names:
            warn(f"{vpath}.net", f"via references unknown net '{vnet}'")

    return {"ok": len(errors) == 0, "errors": errors, "warnings": warnings}


def extract_bom(board: dict, lib_present: bool = False) -> dict:
    """Extract + validate a bill of materials from a canonical board.

    Returns {"ok", "errors", "warnings", "items", "line_count", "part_count"}.
    items are grouped by (footprint, value): each has refs[], footprint, value,
    qty. Missing values / footprints raise warnings (not errors) — an
    unpopulated position is a legitimate DNP. Footprint suggestions are only
    offered when library data is present (lib_present).
    """
    errors: list[dict] = []
    warnings: list[dict] = []
    groups: dict[tuple, dict] = {}

    for i, comp in enumerate(_as_list(board.get("components"))):
        cpath = f"components[{i}]"
        if not isinstance(comp, dict):
            errors.append({"path": cpath, "message": "component must be a mapping"})
            continue
        ref = comp.get("ref")
        if not isinstance(ref, str) or ref == "":
            errors.append({"path": f"{cpath}.ref", "message": "component missing 'ref'"})
            continue
        value = comp.get("value") or ""
        footprint = comp.get("footprint") or ""
        if value == "":
            warnings.append({"path": f"{cpath}.value",
                             "message": f"component '{ref}' has no value"})
        if footprint == "":
            warnings.append({"path": f"{cpath}.footprint",
                             "message": f"component '{ref}' has no footprint"})
            if not lib_present:
                # Only a hint that suggestions need library data (next child).
                pass
        key = (footprint, value)
        grp = groups.setdefault(key, {"refs": [], "footprint": footprint, "value": value, "qty": 0})
        grp["refs"].append(ref)
        grp["qty"] += 1

    items = sorted(groups.values(), key=lambda g: (g["footprint"], g["value"], g["refs"][0] if g["refs"] else ""))
    for it in items:
        it["refs"].sort()

    return {
        "ok": len(errors) == 0,
        "errors": errors,
        "warnings": warnings,
        "items": items,
        "line_count": len(items),
        "part_count": sum(it["qty"] for it in items),
    }
