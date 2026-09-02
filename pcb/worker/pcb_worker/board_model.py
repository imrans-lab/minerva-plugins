"""Canonical board-source model: loading, normalisation, and validation.

This module is the Python-side reader of the canonical board contract defined
in Go at pcb/internal/board/board.go and documented in pcb/docs/board-yaml.md.
It is deliberately plain Python over dicts (no circuit_synth) — the canonical
YAML is OUR schema, not circuit_synth's Circuit object graph, so validating it
is bespoke and dependency-light.

Everything here is a pure function: parse text / dict → structured result.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

from .board_schema import component_value_refusal

# Required top-level fields per the canonical contract. traces / vias / layers /
# origin / design_rules are optional (board.go marks them omitempty). There is no
# grid pitch: the editor's drawing snap is panel session state, not a board field.
REQUIRED_TOP = ("version", "name", "width_mm", "height_mm", "components", "nets")


class BoardParseError(Exception):
    """Raised when board source cannot be parsed into a mapping."""


#: The three standings a git record can have, and the whole vocabulary of
#: ``BoardOrigin.basis``. Defined here because this module is where a board's
#: arrival is known; :mod:`order_package` imports them rather than restating a
#: second list that could drift.
BASIS_WORKER_READ = "worker-read"
BASIS_CALLER_ASSERTED = "caller-asserted"
BASIS_INLINE = "inline"


@dataclass(frozen=True)
class BoardOrigin:
    """How one request's board reached this worker, decided beside the read.

    ``basis`` is minted by :func:`load_board_with_origin` and CARRIED to the
    manifest; nothing downstream re-derives it from the presence of a path.

    ``worker-read`` takes TWO independent statements about ONE file: the caller
    named it as this board's source of record (``source_path``) and this worker
    parsed the board out of that same file (``board_path``). Only a caller can
    make the first and only the loader the second. A size-capped transport that
    spills an inline board to a snapshot file makes neither — it rewrites the
    board key and nothing else — so no transport can move a record onto the
    evidence lane.

    ``path`` is the file that was read (``worker-read`` only); ``asserted_path``
    is a path a caller named that nothing here opened.
    """

    basis: str
    path: str | None = None
    asserted_path: str | None = None


def load_board(params: dict) -> dict:
    """Resolve a board dict from a request's params.

    Accepts, in priority order:
      - params["yaml"]       : canonical YAML source string.
      - params["board"]      : an already-decoded board mapping (dict).
      - params["board_path"] : path to a board snapshot file (YAML or JSON —
        JSON is YAML), verified against params["board_digest"] (sha256 hex of
        the file bytes, case-insensitive). The by-reference arm exists so an
        O(board) document never rides the host broker's capped request pipe
        (work item 01a0223ec9e271269fd664fcf90dd20b); the digest is MANDATORY
        — an unverified file read is refused, never trusted.

    Raises BoardParseError on missing input, unreadable/mismatched snapshot,
    or non-mapping source.
    """
    return load_board_with_origin(params)[0]


def load_board_with_origin(params: dict) -> tuple[dict, BoardOrigin]:
    """:func:`load_board`, plus the :class:`BoardOrigin` describing how it
    arrived — the pair a caller recording provenance needs.

    The origin is built from what THIS call did (which arm ran, and over which
    file) and from the caller's own ``source_path`` declaration, so the two
    statements ``worker-read`` requires are checked where both are known.
    """
    board, read_path = _read_board(params)
    return board, _origin_of(read_path, params)


def _read_board(params: dict) -> tuple[dict, str | None]:
    """The board, and the file it was read out of (``None`` when it arrived as
    content). One place decides which arm serves a request."""
    if isinstance(params.get("yaml"), str):
        return _parse_board_text(params["yaml"]), None
    if isinstance(params.get("board"), dict):
        return params["board"], None
    if isinstance(params.get("board_path"), str):
        import hashlib

        path = params["board_path"]
        digest = params.get("board_digest")
        if not isinstance(digest, str) or not digest:
            raise BoardParseError(
                "board_path requires board_digest (sha256 hex of the file bytes)")
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            raise BoardParseError(f"cannot read board_path {path!r}: {exc}") from exc
        actual = hashlib.sha256(raw).hexdigest()
        if actual != digest.lower():
            raise BoardParseError(
                f"board_path digest mismatch for {path!r}: "
                f"expected {digest}, file has {actual}")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise BoardParseError(
                f"board_path {path!r} is not UTF-8 text: {exc}") from exc
        return _parse_board_text(text), path
    raise BoardParseError(
        "expected params.yaml (str), params.board (object), "
        "or params.board_path (str)")


def _origin_of(read_path: str | None, params: dict) -> BoardOrigin:
    asserted = params.get("source_path")
    if not isinstance(asserted, str) or not asserted:
        asserted = None
    if read_path is not None and asserted is not None \
            and _same_file(read_path, asserted):
        return BoardOrigin(BASIS_WORKER_READ, path=read_path)
    if asserted is not None:
        return BoardOrigin(BASIS_CALLER_ASSERTED, asserted_path=asserted)
    return BoardOrigin(BASIS_INLINE)


def _same_file(a: str, b: str) -> bool:
    """Whether two path spellings name one file. Compared through ``realpath``
    so a relative and an absolute spelling of one file agree; a path that does
    not exist still compares by its normalised name."""
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except OSError:
        return False


def _parse_board_text(source: str) -> dict:
    """Parse board source text (YAML; JSON parses too) into a mapping."""
    import yaml
    try:
        data = yaml.safe_load(source)
    except yaml.YAMLError as exc:  # type: ignore[attr-defined]
        raise BoardParseError(f"invalid YAML: {exc}") from exc
    if data is None:
        raise BoardParseError("YAML source is empty")
    if not isinstance(data, dict):
        raise BoardParseError(
            f"board YAML must be a mapping at the top level, got {type(data).__name__}"
        )
    # Refused BY NAME here, not merged or preferred: see
    # board_schema.component_value_refusal. The shared code validator returns
    # invalid_board_structure for the same document, but only this boundary can
    # tell the author which component and which key to delete.
    refusal = component_value_refusal(data)
    if refusal is not None:
        raise BoardParseError(refusal)
    return data


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
    # Whether this component's pad set is KNOWN from the file alone. A `pins`
    # entry is an OVERRIDE of the like-numbered library pad, so a pins list no
    # longer rosters the component's pads and cannot refute a net's pad ref. The
    # file states the full set only for a `pads`-key component (full geometry
    # authority) or a footprint-less one that does list pins — nothing else can
    # supply its pads. Everything else is adjudicated against the RESOLVED pads
    # by compile_board._finalize_nets, which reads the library this structural
    # pass deliberately does not open.
    comp_pads_known: dict[str, bool] = {}
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
        own_pads = comp.get("pads")
        has_own_pads = isinstance(own_pads, list)
        comp_pads_known[ref] = has_own_pads or (not comp.get("footprint") and len(pins) > 0)
        # THE ROSTER — the pad numbers the FILE itself states. A `pads` key is the
        # full pad authority, so the roster is that list ALONE: a pin beside it
        # overrides one of those pads, and a pin naming a number the list lacks is
        # the defect this pass should catch, not a number it should admit. Without
        # a `pads` key, pins can roster the pads only when nothing else could
        # supply them — a component naming no footprint. The per-pin shape checks
        # below run either way.
        numset: set[str] = set()
        if has_own_pads:
            for pad in own_pads:
                if isinstance(pad, dict) and str(pad.get("number", "")) != "":
                    numset.add(str(pad.get("number")))
        for j, pin in enumerate(pins):
            if not isinstance(pin, dict):
                err(f"{cpath}.pins[{j}]", "pin must be a mapping")
                continue
            num = pin.get("number")
            if num is None or str(num) == "":
                err(f"{cpath}.pins[{j}].number", "pin is missing 'number'")
            elif not has_own_pads:
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
            if comp_pads_known.get(ref):
                if pad not in comp_pins.get(ref, set()):
                    err(ppath, f"pin ref '{pinref}' names pad '{pad}' not declared "
                               f"on component '{ref}' (declared: "
                               f"{sorted(comp_pins.get(ref, set()))})")
            else:
                warn(ppath, f"cannot verify pad '{pad}' — component '{ref}' states no "
                            f"pad set this pass can read (its pads come from the library, "
                            f"which is not opened here)")

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
