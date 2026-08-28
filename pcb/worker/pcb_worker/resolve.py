"""Footprint-RESOLVE step: enrich a canonical board with silk/courtyard graphics.

Canonical boards (docs/board-yaml.md) carry each component's inline pad geometry
plus a ``footprint`` ref, but NO silkscreen/courtyard graphics — so a bare render
looks like a cluster of pads with no body outlines. This step resolves each
component's footprint (via the sha-verified seed library in ``footprints.py``)
and attaches its ``F.SilkS`` + ``F.CrtYd`` graphics to the component.

Coincidence guard (fail-closed)
-------------------------------
Before attaching a footprint's graphics, we PROVE the footprint actually matches
the routed board: every declared pin's LOCAL position must equal the resolved
footprint pad's LOCAL position (matched by pad number) within 0.01mm. If they
disagree, the silkscreen we'd draw would be desynced from the copper the board
was routed against — so we FAIL with a structured error naming the component,
pin, and delta rather than silently drawing wrong silk. (Round 1's golden proved
this holds at 0.000mm for all 10 smart-remote components — same math as
``tests/test_footprints.py::test_coincidence_golden_all_components``.)

Coordinates stay footprint-LOCAL: the board-placement transform (component
position + KiCad rotation) is applied downstream by the renderer/gerber writer,
consistent with how pins are already stored.

Public API
----------
* ``resolve_board(board, library_root=None, lockfile=None, *,
  library_layers=None, wip_root=None) -> dict``  (deep copy; the keyword pair
  selects the live layer chain — see ``pcb_worker.bless.live_library_chain``)
"""

from __future__ import annotations

import copy
import math
from pathlib import Path
from typing import Union

from . import bless
from .geometry import rotation_radians
# resolve_footprint is re-exported on purpose: this module's board-level
# resolvers stopped using it at B7 (they walk a loaded chain via
# resolve_footprint_layered), but `resolve.resolve_footprint` is a de-facto
# public name — the footprint_def/geometry/resolve test suites all reach the
# single-ref resolver through this module (first testex of epoch LIB2 caught
# the dropped re-export as 7 AttributeErrors).
from .footprints import (  # noqa: F401 — resolve_footprint re-exported
    FootprintLookupError,
    resolve_footprint,
    resolve_footprint_layered,
)
from .pad_source import has_resolved_pads
from .silk_source import REFDES_LOCAL_Y_MM, REFDES_TEXT_SIZE_MM
from .pad_types import PAD_TYPE_MAP as _PAD_TYPE_MAP
from .pad_types import normalize_pad_type as _normalize_pad_type

# Coincidence tolerance in mm — same golden threshold Round 1 validated.
COINCIDENCE_TOL_MM = 0.01

# The parser now captures a broader fabrication definition, but this legacy
# preview DTO retains its established F.SilkS/F.CrtYd payload until K3 moves
# consumers to ResolvedBoard.  Keeping this filter local prevents a parser
# capability expansion from silently changing the live panel contract.
_LEGACY_GRAPHIC_LAYERS = frozenset({"F.SilkS", "F.CrtYd"})

class ResolveError(Exception):
    """Base for resolve-step faults."""


class ResolveCoincidenceError(ResolveError):
    """A component's declared pin does not sit on its footprint's pad.

    Carries the located mismatch so the caller can surface it structurally
    (ref/pin/delta) rather than as an opaque string.
    """

    def __init__(self, ref: str, pin: str, delta_mm: float,
                 pin_xy: tuple, pad_xy: Union[tuple, None]):
        self.ref = ref
        self.pin = pin
        self.delta_mm = delta_mm
        self.pin_xy = pin_xy
        self.pad_xy = pad_xy
        if pad_xy is None:
            msg = (f"component {ref!r} pin {pin!r} has no matching pad in its "
                   f"footprint (declared at {pin_xy})")
        else:
            msg = (f"component {ref!r} pin {pin!r}: declared local {pin_xy} vs "
                   f"footprint pad local {pad_xy} -> {delta_mm:.4f}mm > "
                   f"{COINCIDENCE_TOL_MM}mm (silk would desync from copper)")
        super().__init__(msg)


def _silk_count(graphics: list) -> int:
    return sum(1 for g in graphics if g.get("layer") == "F.SilkS")


def _courtyard_count(graphics: list) -> int:
    return sum(1 for g in graphics if g.get("layer") == "F.CrtYd")


def _check_coincidence(ref: str, pins: list, fp_pads: dict) -> None:
    """Raise ResolveCoincidenceError if any declared pin's LOCAL position does
    not coincide (within COINCIDENCE_TOL_MM) with the footprint pad of the same
    number. Fail-closed: an unknown pad number is also a coincidence failure."""
    for pin in pins:
        if not isinstance(pin, dict):
            continue
        num = str(pin.get("number"))
        px, py = pin.get("x_mm"), pin.get("y_mm")
        if px is None or py is None:
            continue  # a pin with no local position can't be checked; skip
        pad = fp_pads.get(num)
        if pad is None or pad[0] is None or pad[1] is None:
            raise ResolveCoincidenceError(ref, num, float("inf"), (px, py), None)
        d = math.hypot(pad[0] - px, pad[1] - py)
        if d > COINCIDENCE_TOL_MM:
            raise ResolveCoincidenceError(ref, num, d, (px, py), (pad[0], pad[1]))


def resolve_board(
    board: dict,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
    *,
    library_layers=None,
    wip_root: Union[str, Path, None] = None,
) -> dict:
    """Resolve every component's footprint and attach its silk/courtyard graphics.

    For each component: resolve the footprint ref, PROVE its pads coincide with
    the component's declared pins (fail-closed — see ResolveCoincidenceError),
    then set ``component["graphics"]`` to the footprint's ``F.SilkS`` + ``F.CrtYd``
    graphics AND ``component["pads"]`` to the footprint's real pad geometry
    (shape/size/drill/type), both in component-LOCAL coordinates, and flag
    ``component["has_pad_geometry"] = True`` so the panel's accurate pad renderer
    takes over. The input is not mutated — a deep copy is returned.

    ``library_layers``/``wip_root`` (S9/B7) select the SAME live chain
    compile_board resolves through (:func:`pcb_worker.bless.live_library_chain`);
    omitted, the chain is the shipped seed alone — the pre-B7 behaviour,
    error strings included. The chain is loaded ONCE for the whole board, so
    every component resolves against one reading of each layer's lock — and a
    chain that cannot be loaded (a configured layer's lock missing or
    malformed) refuses the resolve outright rather than degrading per
    component: a broken override layer must never quietly fall away (the
    anti-shadowing rule in footprints.py).
    """
    resolved = copy.deepcopy(board)
    components = resolved.get("components")
    if not isinstance(components, list):
        return resolved

    chain = bless.live_library_chain(
        wip_root=wip_root, layers=library_layers,
        library_root=library_root, lockfile=lockfile)
    board_lock = resolved.get("library_lock")
    for comp in components:
        if not isinstance(comp, dict):
            continue
        _resolve_component(comp, chain,
                           board_lock if isinstance(board_lock, dict) else None)

    return resolved


def resolve_board_best_effort(
    board: dict,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
    *,
    library_layers=None,
    wip_root: Union[str, Path, None] = None,
) -> dict:
    """TOLERANT resolve for the fabrication path (Stage 2 step 4a-ii, design 2).

    Same as ``resolve_board`` but a component whose footprint is UNRESOLVABLE
    (not in the library) or that declares no footprint ref is LEFT INLINE — its
    ``pins`` remain the source of truth — instead of failing the whole board. The
    downstream emitter then fail-closes only if such a component's SMD pad has no
    inline geometry either (pad_source.iter_pads(require_smd_size=True)). So the
    two controls compose: resolve what you can, and refuse to fabricate a pad you
    still have no geometry for.

    A ResolveCoincidenceError is NOT tolerated — a footprint that resolves but
    whose pads DISAGREE with the routed pins is an integrity fault (silk/copper
    would desync), so it still propagates and fails the board. The input is not
    mutated — a deep copy is returned. The standalone ``resolve`` worker action
    keeps using the STRICT ``resolve_board`` (an unresolvable footprint there IS
    an error the caller asked to surface).
    """
    resolved = copy.deepcopy(board)
    components = resolved.get("components")
    if not isinstance(components, list):
        return resolved

    # Chain load is OUTSIDE the per-component tolerance on purpose (B7): the
    # tolerance covers a COMPONENT the library cannot explain; a configured
    # LAYER whose lock will not load is a chain defect, and letting it demote
    # every component to inline would be exactly the silent fall-through the
    # anti-shadowing rule forbids. It propagates as FootprintLookupError and
    # the caller reports a structured resolve error.
    chain = bless.live_library_chain(
        wip_root=wip_root, layers=library_layers,
        library_root=library_root, lockfile=lockfile)
    board_lock = resolved.get("library_lock")
    for comp in components:
        if not isinstance(comp, dict):
            continue
        try:
            _resolve_component(comp, chain,
                               board_lock if isinstance(board_lock, dict) else None)
        except ResolveCoincidenceError:
            raise  # integrity fault: footprint pads disagree with routed pins
        except (ResolveError, FootprintLookupError):
            continue  # unresolvable / no-ref footprint — leave inline (pins win)

    return resolved


def _resolve_component(
    comp: dict,
    chain,
    lock: Union[dict, None] = None,
) -> None:
    """Resolve ONE component's footprint and attach its graphics + pad geometry.

    Mutates ``comp`` in place (sets ``graphics``/``pads``/``has_pad_geometry``).
    Raises ResolveError (no footprint ref), FootprintLookupError (not in library),
    or ResolveCoincidenceError (pads disagree with pins) — the caller decides
    whether to propagate (strict) or leave the component inline (best-effort).
    Nothing is mutated until AFTER the coincidence check passes, so a raising
    component is left pristine (inline).
    """
    ref = str(comp.get("ref", ""))
    fp_ref = comp.get("footprint")
    if not isinstance(fp_ref, str) or fp_ref == "":
        raise ResolveError(f"component {ref!r} has no footprint ref to resolve")

    supplied = resolve_footprint_layered(fp_ref, chain=chain)
    parsed = supplied.parsed

    # THE BOARD'S LOCK, ON THE DEGRADE PATH (K20; epoch GA task-3 review
    # finding 2). The compile path REFUSES a lock mismatch outright. This path
    # must not: it is the tolerant preview/DRC resolve, and the owner's standing
    # rule is that the CANVAS DEGRADES while FAB FAILS CLOSED — hard-refusing
    # here would blank the editor for a board that is merely out of date.
    #
    # But it must not be SILENT either, and it was: a locked board whose library
    # changed had the substituted graphics and pads baked straight into the
    # returned board, so the panel displayed — and persisted — copper the board
    # never approved, right up until someone happened to compile. That is the
    # one-path-enforced trap, and a lock honoured on one path and not another is
    # worse than none because it teaches a trust it cannot keep.
    #
    # So the component is MARKED and still drawn. The marker travels on the
    # component itself, which is where every other per-component honesty signal
    # in this payload already lives.
    if isinstance(lock, dict):
        pinned = lock.get(fp_ref)
        if isinstance(pinned, dict):
            expected = str(pinned.get("sha256", ""))
            actual = str((supplied.entry or {}).get("sha256", ""))
            if expected and not actual:
                # Pinned but uncheckable — the supplying layer has no sha to
                # compare. Marked, not silent, for the same reason a mismatch
                # is: the panel must not render pinned content as verified when
                # nothing verified it.
                comp["library_lock_uncheckable"] = {
                    "footprint": fp_ref,
                    "supplying_layer": supplied.layer,
                    "note": ("this footprint is pinned, but the supplying layer's lock "
                             "entry has no sha256, so the pin could not be checked"),
                }
            elif expected and actual and expected != actual:
                comp["library_lock_mismatch"] = {
                    "footprint": fp_ref,
                    "expected_sha256": expected,
                    "actual_sha256": actual,
                    "supplying_layer": supplied.layer,
                    "note": ("this board is pinned to different content than the library "
                             "now supplies; the geometry shown is the CURRENT library's, "
                             "not what the board was locked to. A compile will refuse."),
                }

    fp_pads = {str(p["number"]): (p["x_mm"], p["y_mm"]) for p in parsed["pads"]}
    _check_coincidence(ref, comp.get("pins") or [], fp_pads)

    # Attach only the wanted layers (parse already filters to GRAPHIC_LAYERS,
    # but assert the invariant so drift is caught here rather than in a render).
    graphics = [
        g for g in parsed["graphics"]
        if g.get("layer") in _LEGACY_GRAPHIC_LAYERS
    ]
    comp["graphics"] = graphics

    # Attach real pad geometry (footprint-LOCAL coords — the SAME frame the
    # graphics above are in, so silk and copper co-register). Built from the
    # SAME parsed footprint used for the coincidence check; no re-parse. The
    # coincidence guard has already run (and would have raised) before we get
    # here, so pads are only attached to a proven-coincident component.
    comp["pads"] = _pads_from_parsed(parsed["pads"])
    # ``has_pad_geometry`` is the board-dict VIEW of the one resolved-vs-fallback
    # predicate (pad_source.has_resolved_pads) — NOT an independent computation,
    # so it can never drift from what iter_pads/the emitters see. Only claims
    # geometry when pads actually resolved, else the panel would suppress its
    # fallback pin renderer and draw nothing at all (Stage 2 step 7 collapse).
    comp["has_pad_geometry"] = has_resolved_pads(comp)
    # THE COMPONENT-level resolved fact, distinct from the PAD-level one above
    # (bug 019ff4a9a0d7): a silk-only footprint (a logo, a revision text) has
    # ZERO pads, so has_pad_geometry is honestly False forever — yet the
    # footprint DID resolve and its render is complete. The panel's unresolved
    # badge used pad-resolution as a proxy for component-resolution and
    # therefore marked every such fixture "unresolved — resolve before
    # fabrication", permanently and falsely. This key states the component
    # fact directly; it is set ONLY on the success path (best-effort leaves a
    # failing component pristine, so absence still means unresolved).
    comp["footprint_resolved"] = True

    # PRINTED REFERENCE DESIGNATOR (WYSIWYG goal 019ff4a5a75a, gap G2): the
    # fab silk carries a stroke-font designator that exists NOWHERE in the
    # authored board — silk_source synthesizes it at emit time from the
    # component's ref. A panel that draws only comp["graphics"] therefore
    # shows a board with no printed designators, and clears (or misses) silk
    # collisions the fabricated board actually has.
    #
    # WHAT TRAVELS IS THE ANCHOR, NOT THE STROKES. The renderer on the far end
    # owns the same glyph table (pcb/ui/model/pcb_board_font_data.gd mirrors
    # board_font) and knows the ref, so the only fact it cannot derive is
    # WHERE the footprint wants its designator printed. Sending glyphs instead
    # would send a picture of one particular ref, and a picture goes stale the
    # moment the component is renamed or copied — which is exactly how a part
    # came to draw its neighbour's designator.
    comp["refdes_anchor"] = _refdes_anchor(parsed)


def _refdes_anchor(parsed: dict) -> dict:
    """Where this footprint wants its designator printed, footprint-LOCAL.

    ``{x_mm, y_mm, rotation_deg, size_mm, hidden}`` — the footprint's OWN
    authored reference fp_text placement when it declares one, else the
    emitter's default anchor (``silk_source.REFDES_LOCAL_Y_MM`` /
    ``REFDES_TEXT_SIZE_MM``, centred on the origin, upright). Always a
    complete anchor, so a renderer never has to guess which half was omitted.

    These are the SAME numbers ``silk_source.refdes_strokes`` places glyphs
    with, so a renderer that strokes the ref through the shared glyph table at
    this anchor reproduces the emitted silk. ``hidden`` carries the
    authored-hidden rule: a hidden reference prints nothing, so it must draw
    nothing either.
    """
    rt = parsed.get("reference_text")
    if not isinstance(rt, dict):
        return {"x_mm": 0.0, "y_mm": REFDES_LOCAL_Y_MM, "rotation_deg": 0.0,
                "size_mm": REFDES_TEXT_SIZE_MM, "hidden": False}
    return {
        "x_mm": float(rt["x_mm"]),
        "y_mm": float(rt["y_mm"]),
        "rotation_deg": float(rt.get("rotation_deg", 0.0)),
        "size_mm": float(rt.get("size_mm", REFDES_TEXT_SIZE_MM)),
        "hidden": bool(rt.get("hidden") or False),
    }


def _pads_from_parsed(fp_pads: list) -> list:
    """Map ``footprints._parse_pad`` output → the panel's board-dict pad shape.

    Emits ``{number, type, shape, position{x,y}, size{width,height},
    drill{x,y}, layers}`` plus the fab-affecting optionals the parser surfaces
    (see ``pcb_component.gd::_pads_from_list``). Pads with no local position are
    skipped — mirrors the coincidence path's null skip so we never emit a
    positionless pad.

    SB2 (019f8acfd651): the parser (``footprints._parse_pad``) already extracts
    ``roundrect_rratio`` / ``solder_mask_margin`` / ``solder_paste_margin`` /
    ``rotation``, but this projection used to DROP them, so every resolved
    roundrect fell back to the emitter's default corner ratio and every pad to
    the board-global mask clearance. Thread them through here (name-mapping
    ``roundrect_rratio`` → ``corner_rratio``, the key the gerber/kicad emitters
    read) so the LIVE emitters see the real per-pad geometry. ``rotation`` and
    ``solder_paste_margin`` are carried for losslessness; their APPLICATION
    (pad-local rotation into the placement transform; a paste layer) lands in W8.
    """
    out: list = []
    for p in fp_pads:
        x, y = p.get("x_mm"), p.get("y_mm")
        if x is None or y is None:
            continue

        # A footprint that declares no ``(size ...)`` node gets NO fabricated
        # land here (K14 / 019f9509a54c) — ``footprints._parse_pad`` already
        # sets ``size = None`` for that case, and ``footprint_def.
        # to_board_pad_dicts`` (the sibling projection, locked by
        # test_sizeless_pad_stays_none_instead_of_inventing_geometry) emits
        # ``{"width": None, "height": None}`` for it. Match that convention
        # instead of inventing a 1.0x1.0 mm pad: downstream, pad_source._opt_num
        # already turns a missing width/height into None on PadGeom, and
        # iter_pads(require_smd_size=True) is the fail-closed gate that refuses
        # a sizeless SMD pad on the fab path — this function is the tolerant
        # DRC/preview projection, not the gate, so it stays honest and lets
        # that gate do its job.
        size = p.get("size")
        if size and size[0] is not None and size[1] is not None:
            size_dict = {"width": size[0], "height": size[1]}
        else:
            size_dict = {"width": None, "height": None}

        # KiCad drill is a single float (or absent) → symmetric {x,y}; 0 == no hole.
        drill = p.get("drill")
        drill_dict = ({"x": drill, "y": drill} if drill is not None
                      else {"x": 0.0, "y": 0.0})

        pad_out = {
            "number": str(p.get("number", "")),
            "type": _normalize_pad_type(p.get("type")),
            "shape": p.get("shape") or "rect",
            "position": {"x": x, "y": y},
            "size": size_dict,
            "drill": drill_dict,
            "layers": p.get("layers") or [],
        }
        # D1 provenance: carry the FOOTPRINT-AUTHORED shape (None when the pad
        # declared none) so th_land can shape an equal-axis authored land (finding
        # 019f8b7fd295). Derived from the raw ``shape`` token exactly as
        # PadDefinition.raw_shape is (a string only), keeping the two producers in
        # parity; only present when authored, so a defaulted pad stays clean.
        raw_shape = p.get("shape") if isinstance(p.get("shape"), str) else None
        if raw_shape is not None:
            pad_out["raw_shape"] = raw_shape
        # Fab-affecting optionals — only present when the footprint carries them,
        # so a plain rect pad stays clean. corner_rratio + solder_mask_margin are
        # consumed by the emitters NOW; rotation + solder_paste_margin are carried
        # for W8.
        rratio = p.get("roundrect_rratio")
        if rratio is not None:
            pad_out["corner_rratio"] = rratio
        for key in ("solder_mask_margin", "solder_paste_margin"):
            val = p.get(key)
            if val is not None:
                pad_out[key] = val
        # A 0/absent local rotation is a no-op; omit it so this projection stays
        # byte-identical to footprint_def.to_board_pad_dicts (whose PadDefinition
        # .rotation_deg defaults to 0.0 and can't distinguish absent from zero).
        rot = p.get("rotation")
        if rot:
            pad_out["rotation"] = rot
        out.append(pad_out)
    return out


def board_graphic_stats(board: dict) -> dict:
    """Summarise attached graphics: {components, silk_graphics, courtyard_graphics}."""
    components = board.get("components") if isinstance(board.get("components"), list) else []
    silk = 0
    crtyd = 0
    for comp in components:
        if not isinstance(comp, dict):
            continue
        g = comp.get("graphics") or []
        silk += _silk_count(g)
        crtyd += _courtyard_count(g)
    return {
        "components": len(components),
        "silk_graphics": silk,
        "courtyard_graphics": crtyd,
    }


# ---------------------------------------------------------------------------
# ONE footprint's geometry, for a part that does not exist on a board yet.
# ---------------------------------------------------------------------------

#: Graphic layers a body-extent fallback may be measured from when the
#: footprint declares no courtyard. Silk is the drawn body outline; the fab
#: layer carries the assembly outline. Neither is copper, so a part whose only
#: extent is its pads still gets a box (the pad union) rather than nothing.
_EXTENT_GRAPHIC_LAYERS = frozenset({"F.SilkS", "B.SilkS", "F.Fab", "B.Fab"})
_COURTYARD_EXTENT_LAYERS = frozenset({"F.CrtYd", "B.CrtYd"})


def footprint_geometry(
    ref: str,
    *,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
    library_layers=None,
    wip_root: Union[str, Path, None] = None,
) -> dict:
    """One library ref's fabricable geometry, in the panel's own pad shape.

    The board-level resolvers above answer "does this component's footprint
    still match the pins it was routed against". This answers the question that
    comes BEFORE a component exists: "what does this library ref actually
    fabricate as". It is what lets a part be ADDED by library ref with real
    lands and real silk, through the same seed/wip/user chain
    (:func:`pcb_worker.bless.live_library_chain`) every compile-bearing call
    resolves through — so a part the panel could add is a part the worker can
    compile, by construction, and the two can never disagree about which
    library supplied it.

    Returns ``{ref, layer, sha256, footprint_name, pads, graphics,
    refdes_anchor, bounding_box, pad_count, has_pad_geometry}``. ``pads`` is
    :func:`_pads_from_parsed`'s projection — the SAME shape a resolved board
    carries, so the panel deserializes an added part and a loaded one through
    one path. ``bounding_box`` is the panel's ``{width, height, center_x,
    center_y}`` body box, measured from the courtyard when the footprint
    declares one (that IS the part's declared extent), else from its drawn
    outline, else from the union of its lands.

    ``refdes_anchor`` is where this footprint prints its designator (see
    :func:`_refdes_anchor`), so a freshly added part draws its ref where the
    fab will stroke it instead of waiting for the next board load. It does not
    depend on the refdes itself — the renderer already knows that.

    Raises :class:`~pcb_worker.footprints.FootprintLookupError` — attributed,
    naming the ref and the layers searched — when the ref does not resolve.
    There is no tolerant mode: a caller asking for geometry it cannot get must
    be told which layers were searched, not handed an empty part.
    """
    chain = bless.live_library_chain(
        wip_root=wip_root, layers=library_layers,
        library_root=library_root, lockfile=lockfile)
    supplied = resolve_footprint_layered(ref, chain=chain)
    parsed = supplied.parsed

    pads = _pads_from_parsed(parsed.get("pads") or [])
    graphics = [g for g in (parsed.get("graphics") or [])
                if g.get("layer") in _LEGACY_GRAPHIC_LAYERS]
    out = {
        "ref": ref,
        "layer": supplied.layer,
        "sha256": str((supplied.entry or {}).get("sha256", "")),
        "footprint_name": parsed.get("name"),
        "pads": pads,
        "graphics": graphics,
        "bounding_box": _body_box(parsed, pads),
        "pad_count": len(pads),
        # The board-dict VIEW of the one resolved-vs-fallback predicate, same
        # as _resolve_component's — a silk-only footprint honestly reports
        # False here and is still fully resolved.
        "has_pad_geometry": bool(pads),
        "refdes_anchor": _refdes_anchor(parsed),
    }
    return out


def _body_box(parsed: dict, pads: list) -> dict:
    """The panel's ``{width, height, center_x, center_y}`` body box for a
    footprint, in footprint-LOCAL mm.

    Courtyard first — a footprint that declares one has declared its extent,
    and that is the box the panel must hit-test and the placement checks must
    keep clear. Silk/fab outline next, then the union of the lands, so a
    footprint with no graphics at all still gets a box that contains its
    copper — measured from each land's TURNED corners (``_pad_corners``), so a
    rotated land is not understated. A footprint with neither graphics nor pads
    has no extent and gets a zero box rather than an invented one.
    """
    for wanted in (_COURTYARD_EXTENT_LAYERS, _EXTENT_GRAPHIC_LAYERS):
        points = []
        for g in (parsed.get("graphics") or []):
            if g.get("layer") in wanted:
                points.extend(_graphic_extent_points(g))
        box = _box_of(points)
        if box is not None:
            return box
    points = []
    for pad in pads:
        pos = pad.get("position") or {}
        size = pad.get("size") or {}
        x, y = pos.get("x"), pos.get("y")
        w, h = size.get("width"), size.get("height")
        if x is None or y is None:
            continue
        half_w = (float(w) / 2.0) if w is not None else 0.0
        half_h = (float(h) / 2.0) if h is not None else 0.0
        points.extend(_pad_corners(float(x), float(y), half_w, half_h,
                                   float(pad.get("rotation") or 0.0)))
    box = _box_of(points)
    return box if box is not None else {
        "width": 0.0, "height": 0.0, "center_x": 0.0, "center_y": 0.0}


def _pad_corners(x: float, y: float, half_w: float, half_h: float,
                 rotation_deg: float) -> list:
    """The four corners of one land, in footprint-LOCAL mm.

    A land's own ``rotation`` turns it about its centre, so the box must be
    measured from the TURNED corners: an axis-aligned ``+/- half_w, +/- half_h``
    understates a rotated rectangle, and a 45-degree land is
    ``(w + h) / sqrt(2)`` across rather than ``w``. The angle goes through
    :func:`geometry.rotation_radians` — the pinned clockwise-in-a-y-down-frame
    convention — so this box turns the same way the emitters flash the land.
    """
    corners = [(-half_w, -half_h), (half_w, -half_h),
               (half_w, half_h), (-half_w, half_h)]
    if not rotation_deg:
        return [(x + dx, y + dy) for dx, dy in corners]
    theta = rotation_radians(rotation_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    return [(x + dx * cos_t - dy * sin_t, y + dx * sin_t + dy * cos_t)
            for dx, dy in corners]


def _graphic_extent_points(graphic: dict) -> list:
    """Every point a parsed graphic contributes to an extent measurement.

    An arc contributes its stored points (its endpoints and, when the parser
    kept one, its midpoint) rather than its true swept extent: a courtyard is
    drawn from lines and short fillet arcs, so the understatement is bounded by
    the fillet radius, and the alternative — reconstructing swept arc extrema
    here — is a second arc implementation this box does not need.
    """
    kind = graphic.get("kind")
    if kind == "circle":
        c = graphic.get("center") or (None, None)
        if c[0] is None or c[1] is None:
            return []
        r = float(graphic.get("radius") or 0.0)
        cx, cy = float(c[0]), float(c[1])
        return [(cx - r, cy - r), (cx + r, cy + r)]
    raw = [graphic.get("start"), graphic.get("end")]
    raw.extend(graphic.get("points") or [])
    points = []
    for p in raw:
        # The parser emits None for an unparseable coordinate rather than
        # dropping the node, so a malformed graphic contributes nothing to the
        # extent instead of crashing the measurement.
        if p is None or len(p) < 2 or p[0] is None or p[1] is None:
            continue
        points.append((float(p[0]), float(p[1])))
    return points


def _box_of(points: list):
    """``{width, height, center_x, center_y}`` for a point cloud, or None when
    the cloud is empty or has no extent at all (a single point is not a body)."""
    if not points:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    width = max(xs) - min(xs)
    height = max(ys) - min(ys)
    if width <= 0.0 and height <= 0.0:
        return None
    return {"width": width, "height": height,
            "center_x": (max(xs) + min(xs)) / 2.0,
            "center_y": (max(ys) + min(ys)) / 2.0}
