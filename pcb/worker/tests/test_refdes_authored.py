"""A designator placement somebody SET reaches the fab.

WHAT THIS FILE PINS. An anchor a caller sets is board SOURCE, not a canvas
decoration: a component carries an optional ``refdes_placement`` block, and one
precedence rule reads it everywhere —

    authored placement  >  the footprint's own reference fp_text  >  derived

— resolved once at compile onto ``ResolvedComponent.refdes``.

WHAT MAKES THESE ORACLES rather than restatements of that rule. Each expected
placement is stated INDEPENDENTLY of the code under test: the literal numbers
the board authored, or the ``reference_text`` numbers read straight out of the
``.kicad_mod`` parse. Every consumer is then measured against that one number —
the anchor on the resolve wire, the strokes the geometric DRC projects, the ink
in the emitted F.SilkS Gerber, and the ``fp_text reference`` in the emitted
.kicad_pcb. Four surfaces, one expectation: a change that moves the designator
on one of them fails here rather than shipping a board whose editor and whose
fab disagree.

TWO BOARDS, because the two arms of the geometry rule are different cases.
``_library_board`` is PARTIAL (the footprint library is the geometry authority,
so rule 2 exists at all) and uses seed parts whose authored/unauthored state is
asserted, not assumed. ``_inline_board`` is FULL (the board owns the geometry,
the library is never read, so the rule there is 1-else-3) and its parts draw a
COURTYARD ONLY — no silk of their own — which is what lets the emitted F.SilkS
be read as designator ink and nothing else.
"""

from __future__ import annotations

import copy
import math
import re
from pathlib import Path

import pytest

from pcb_worker import (board_font, footprints, gerber, kicad, refdes_anchor,
                        silk_source)
from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geometric import project_board
from pcb_worker.resolve import resolve_board
from pcb_worker.resolved_board import ResolutionSuccess

LIBRARY = Path(__file__).parents[2] / "library" / "footprints"

#: Half a stroke: glyph polylines are centrelines and the ink is this much wider
#: on every side.
HALF_STROKE = silk_source.SILK_TEXT_WIDTH_MM / 2.0

#: A footprint that authors NO reference fp_text — rule 2 is unavailable, so
#: rules 1 and 3 are the only two answers and they are told apart cleanly.
PLAIN_FP = "Resistor_SMD:R_0805_2012Metric"
#: A footprint that DOES author one, at a placement the derived rule does not
#: produce (asserted below, so the test cannot go vacuous).
AUTHORED_FP = "Diode_SMD:D_SMA"

#: What the board authors for U1/V1. Far enough below the part that no body
#: geometry and no derived anchor can land near it by accident.
AUTHORED = {"x_mm": 0.0, "y_mm": -6.0, "rotation_deg": 0.0,
            "size_mm": 1.4, "hidden": False}


def _parsed(lib_ref: str) -> dict:
    lib, name = lib_ref.split(":")
    return footprints.parse_kicad_mod(
        (LIBRARY / f"{lib}.pretty" / f"{name}.kicad_mod").read_text(
            encoding="utf-8"))


# ---------------------------------------------------------------------------
# The boards
# ---------------------------------------------------------------------------


def _board(components: list[dict], name: str) -> dict:
    return {"version": 1, "name": name, "width_mm": 70, "height_mm": 70,
            "layers": ["top", "bottom"],
            "design_rules": {"clearance_mm": 0.15, "trace_width_mm": 0.25,
                             "via_diameter_mm": 0.6, "via_drill_mm": 0.3,
                             "rule_profile": "jlcpcb-2layer"},
            "components": components, "nets": []}


def _library_board() -> dict:
    """PARTIAL components — the library is the geometry authority, so all three
    precedence rules are reachable on one board."""
    return _board([
        # Rule 1: the board authored a placement over a footprint that has none.
        {"ref": "U1", "footprint": PLAIN_FP, "x_mm": 12.0, "y_mm": 12.0,
         "rotation_deg": 0, "layer": "top",
         "refdes_placement": dict(AUTHORED)},
        # Rule 2: the footprint's own fp_text, nothing authored over it.
        {"ref": "U2", "footprint": AUTHORED_FP, "x_mm": 35.0, "y_mm": 12.0,
         "rotation_deg": 0, "layer": "top"},
        # Rule 3: neither — the anchor derived from the body.
        {"ref": "U3", "footprint": PLAIN_FP, "x_mm": 58.0, "y_mm": 12.0,
         "rotation_deg": 0, "layer": "top"},
    ], "refdes-library")


def _rect(layer: str, x0: float, y0: float, x1: float, y1: float,
          width: float = 0.05) -> list[dict]:
    corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    return [{"layer": layer, "kind": "line", "width": width,
             "start": list(corners[i]), "end": list(corners[(i + 1) % 4])}
            for i in range(4)]


#: A 4 x 4 keep-out with two lands and NO silk of its own, so every F.SilkS
#: stroke this board emits is a designator.
_SILENT_BODY = {
    "pads": [{"number": n, "type": "smd", "shape": "rect",
              "position": {"x": x, "y": 0.0},
              "size": {"width": 1.0, "height": 1.0}, "layers": ["F.Cu"]}
             for n, x in (("1", -1.5), ("2", 1.5))],
    "graphics": _rect("F.CrtYd", -2.0, -2.0, 2.0, 2.0),
}


def _inline(ref: str, x: float, y: float, placement: dict | None) -> dict:
    comp = {"ref": ref, "footprint": f"SILENT:{ref}", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": p["number"], "x_mm": p["position"]["x"],
                      "y_mm": p["position"]["y"]}
                     for p in _SILENT_BODY["pads"]]}
    comp.update(copy.deepcopy(_SILENT_BODY))
    if placement is not None:
        comp["refdes_placement"] = dict(placement)
    return comp


def _inline_board() -> dict:
    """FULL components — the board owns the geometry and the library is never
    read, which is exactly the case where authoring the placement is the ONLY
    way to state one."""
    return _board([
        _inline("V1", 15.0, 20.0, AUTHORED),          # authored
        _inline("V2", 40.0, 20.0, None),              # derived
        _inline("V3", 15.0, 50.0, {"hidden": True}),  # partial overlay: hide
    ], "refdes-inline")


def _compiled(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _by_ref(rb, ref: str):
    return next(c for c in rb.components if c.ref == ref)


# ---------------------------------------------------------------------------
# Measurement — none of it re-derives the placement rule
# ---------------------------------------------------------------------------


def _bbox(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def _projected_refdes_ink(rb, ref: str):
    """The BOARD-frame ink box of one component's designator, as the geometric
    DRC's silk projection carries it, or None when it projects none."""
    points = [pt
              for prim in project_board(rb).silk
              if prim.origin == "refdes" and prim.ref == ref
              for pt in prim.geometry.points]
    if not points:
        return None
    x0, y0, x1, y1 = _bbox(points)
    return (x0 - HALF_STROKE, y0 - HALF_STROKE,
            x1 + HALF_STROKE, y1 + HALF_STROKE)


def _fs_scale(gbr: str) -> tuple[int, int]:
    fs = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", gbr)
    assert fs, "no %FSLAX..Y..*% format spec in the gerber"
    return int(fs.group(2)), int(fs.group(4))


def _gerber_stroke_points(gbr: str) -> list[tuple[float, float]]:
    """Every draw/move coordinate in a Gerber, back in BOARD mm.

    Gerber space negates Y (docs/gerbers.md), so the sign is put back here — the
    emitter's own convention, applied by the reader rather than assumed away.
    """
    xd, yd = _fs_scale(gbr)
    return [(int(xs) / 10 ** xd, -int(ys) / 10 ** yd)
            for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D0[12]\*", gbr)]


def _kicad_reference(pcb_text: str, ref: str) -> tuple[float, float, bool]:
    """``(x, y, hidden)`` of one component's fp_text reference in a .kicad_pcb."""
    match = re.search(
        r'\(fp_text reference "%s" \(at (-?[\d.]+) (-?[\d.]+)(?: (-?[\d.]+))?\)'
        r' \(layer "[BF]\.Fab"\)( hide)?' % re.escape(ref), pcb_text)
    assert match, f"no fp_text reference for {ref} in the emitted .kicad_pcb"
    return float(match.group(1)), float(match.group(2)), bool(match.group(4))


def _expected_ink(cx: float, cy: float, ref: str, anchor: dict):
    """The board-frame box the designator's ink must occupy for *anchor*.

    Independent of the placement rule: it is the font's own metrics (glyphs are
    centred on x and grow UPWARD from the baseline) applied to numbers stated by
    the board or read out of the .kicad_mod, at an un-rotated top-side part.
    """
    assert anchor["rotation_deg"] == 0.0, "only the un-rotated cases are boxed"
    half_w = _text_half_width(ref, anchor["size_mm"]) + HALF_STROKE
    x = cx + anchor["x_mm"]
    y = cy + anchor["y_mm"]
    return (x - half_w, y - anchor["size_mm"] - HALF_STROKE,
            x + half_w, y + HALF_STROKE)


def _text_half_width(ref: str, size_mm: float) -> float:
    """Half the glyph advance, measured off the font's own rendering at the
    origin rather than from a stride constant."""
    polylines = board_font.render(
        ref, size=size_mm, h_align="center").polylines
    x0, _, x1, _ = _bbox([p for line in polylines for p in line])
    return max(abs(x0), abs(x1))


def _contains(outer, inner, slack: float = 0.05) -> bool:
    return (inner[0] >= outer[0] - slack and inner[1] >= outer[1] - slack
            and inner[2] <= outer[2] + slack and inner[3] <= outer[3] + slack)


# ---------------------------------------------------------------------------
# 1. The precedence rule, across four consumers
# ---------------------------------------------------------------------------


def test_the_authored_placement_outranks_the_footprint_and_the_derived_rule():
    """One board, three components, one rule — checked on the resolve wire, the
    compiled IR, the DRC silk projection and the KiCad export.

    Oracle: for U1 the literal numbers the BOARD authored; for U2 the
    ``reference_text`` numbers read out of D_SMA's own .kicad_mod. Neither is
    computed by the code under test, and the two are asserted to differ from
    each other and from the derived answer, so no single wrong rule can satisfy
    both rows.
    """
    board = _library_board()
    library_anchor = _parsed(AUTHORED_FP)["reference_text"]
    # parse_kicad_mod omits the key entirely for a footprint that authors no
    # qualifying reference fp_text (see footprints.parse_kicad_mod), so this
    # reads it the way every consumer does.
    assert _parsed(PLAIN_FP).get("reference_text") is None, (
        f"{PLAIN_FP} started authoring a reference fp_text — U1/U3 no longer "
        f"isolate rules 1 and 3")

    # The wire the panel reads.
    resolved = resolve_board(copy.deepcopy(board))
    wire = {c["ref"]: c["refdes_anchor"] for c in resolved["components"]}
    for key, value in AUTHORED.items():
        assert wire["U1"][key] == (value if isinstance(value, bool)
                                   else pytest.approx(value)), (
            f"the resolve wire ignored the board's authored {key}: {wire['U1']}")
    for key in ("x_mm", "y_mm", "rotation_deg", "size_mm"):
        assert wire["U2"][key] == pytest.approx(library_anchor[key]), (
            f"the resolve wire moved D_SMA's own authored {key}: {wire['U2']}")

    # The compiled IR, and the three surfaces that read it.
    rb = _compiled(board)
    derived_u3 = _by_ref(rb, "U3").refdes
    assert derived_u3 is not None
    assert derived_u3.position[1] != pytest.approx(AUTHORED["y_mm"]), (
        "the derived anchor happens to equal the authored one — this board no "
        "longer distinguishes rule 1 from rule 3")
    assert derived_u3.position[1] != pytest.approx(library_anchor["y_mm"]), (
        "the derived anchor happens to equal D_SMA's authored one — this board "
        "no longer distinguishes rule 2 from rule 3")

    pcb_text = kicad.generate_ir(rb, base_name="lib")["lib.kicad_pcb"]

    for ref, cx, cy, anchor in (
            ("U1", 12.0, 12.0, AUTHORED),
            ("U2", 35.0, 12.0, library_anchor)):
        comp = _by_ref(rb, ref)
        assert comp.refdes is not None, f"{ref} compiled with no placement"
        assert comp.refdes.position == pytest.approx(
            (anchor["x_mm"], anchor["y_mm"])), (
            f"{ref}: the compiled IR does not carry the expected placement")
        assert comp.refdes.size_mm == pytest.approx(anchor["size_mm"])

        want = _expected_ink(cx, cy, ref, anchor)
        ink = _projected_refdes_ink(rb, ref)
        assert ink is not None, f"{ref} projects no designator at all"
        assert _contains(want, ink), (
            f"{ref}: the DRC projects the designator at {ink}, not at the "
            f"expected {want} — the check would clear silk the fab prints "
            f"somewhere else")

        kx, ky, hidden = _kicad_reference(pcb_text, ref)
        assert (kx, ky) == pytest.approx(
            (anchor["x_mm"], anchor["y_mm"])), (
            f"{ref}: the .kicad_pcb reference is at ({kx}, {ky}), not at the "
            f"placement the Gerber prints")
        assert hidden is False

    # U3 keeps following its footprint: its designator sits ABOVE its own body,
    # which is the derived rule stated as a measured fact rather than a formula.
    u3_ink = _projected_refdes_ink(rb, "U3")
    body = _bbox([pt for pad in _by_ref(rb, "U3").placed_pads
                  for pt in _pad_corners(pad)])
    assert u3_ink is not None and u3_ink[3] < body[1], (
        f"U3's derived designator ink {u3_ink} is not clear of its lands "
        f"{body} — the unset component stopped following its footprint")


def _pad_corners(pad) -> list[tuple[float, float]]:
    """A placed land's four corners, board-absolute. Written out here so the
    body box is measured off the IR rather than through any anchor helper."""
    (x, y) = pad.position
    w, h = pad.size if pad.size is not None else (0.0, 0.0)
    theta = math.radians(pad.rotation_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    return [(x + dx * cos_t - dy * sin_t, y + dx * sin_t + dy * cos_t)
            for dx, dy in ((-w / 2, -h / 2), (w / 2, -h / 2),
                           (w / 2, h / 2), (-w / 2, h / 2))]


# ---------------------------------------------------------------------------
# 2. The emitted Gerber
# ---------------------------------------------------------------------------


def test_the_gerber_prints_the_designator_where_the_board_authored_it():
    """The fab file itself, on the FULL-geometry arm — the case where the
    library is never consulted and the board's own placement is the only one
    there is.

    Oracle: the ink coordinates read back out of the emitted F.SilkS, in board
    mm, against the box the authored numbers and the font's own metrics predict.
    The parts draw a courtyard and no silk, so every stroke in that file is a
    designator and nothing can hide in the footprint's own artwork.
    """
    rb = _compiled(_inline_board())
    silk = gerber.build_gerbers_ir(rb, name="inl")["inl-F_SilkS.gbr"]
    points = _gerber_stroke_points(silk)
    assert points, "the emitted F.SilkS carries no strokes at all"

    want_v1 = _expected_ink(15.0, 20.0, "V1", AUTHORED)
    in_v1 = [p for p in points if _inside(want_v1, p)]
    assert in_v1, (
        f"nothing was printed in the box the board authored for V1 {want_v1} — "
        f"the Gerber ignored refdes_placement; ink is at {_bbox(points)}")
    # And nothing of V1's designator stayed behind at the derived anchor.
    derived = _by_ref(rb, "V2").refdes           # same body, so the same rule
    assert derived is not None
    stale = _expected_ink(15.0, 20.0, "V1",
                          {"x_mm": derived.position[0],
                           "y_mm": derived.position[1],
                           "rotation_deg": 0.0,
                           "size_mm": derived.size_mm})
    assert not [p for p in points if _inside(stale, p)], (
        f"V1's designator is ALSO printed at the derived anchor {stale} — the "
        f"authored placement added ink instead of moving it")

    # V2 is unset and still follows the derived rule: its ink is above its body.
    want_v2 = _expected_ink(40.0, 20.0, "V2",
                            {"x_mm": derived.position[0],
                             "y_mm": derived.position[1],
                             "rotation_deg": 0.0, "size_mm": derived.size_mm})
    assert [p for p in points if _inside(want_v2, p)], (
        f"V2's derived designator is not at {want_v2} — an unset component "
        f"stopped following its footprint; ink is at {_bbox(points)}")

    # V3 authored `hidden` and prints nothing, anywhere on the layer.
    assert _projected_refdes_ink(rb, "V3") is None, \
        "the DRC still projects a designator the board hid"
    v3_box = (15.0 - 6.0, 50.0 - 12.0, 15.0 + 6.0, 50.0 + 6.0)
    assert not [p for p in points if _inside(v3_box, p)], (
        "the Gerber printed ink around a component whose designator the board "
        "hid — and that part draws no silk of its own, so it can only be the "
        "designator")


def _inside(box, point) -> bool:
    return (box[0] <= point[0] <= box[2]) and (box[1] <= point[1] <= box[3])


# ---------------------------------------------------------------------------
# 3. The overlay is per field
# ---------------------------------------------------------------------------


def test_a_partial_placement_moves_only_what_it_states():
    """``refdes_placement`` is an overlay, not a replacement: a block that names
    one field keeps the footprint's answer for the other four.

    Oracle: D_SMA's own authored size/rotation, read out of the .kicad_mod, must
    survive a board that authors only ``y_mm`` — and the hidden flag alone must
    suppress the designator without disturbing where it would have gone.
    """
    library_anchor = _parsed(AUTHORED_FP)["reference_text"]
    board = _board([
        {"ref": "P1", "footprint": AUTHORED_FP, "x_mm": 20.0, "y_mm": 20.0,
         "rotation_deg": 0, "layer": "top",
         "refdes_placement": {"y_mm": -7.5}},
        {"ref": "P2", "footprint": AUTHORED_FP, "x_mm": 45.0, "y_mm": 20.0,
         "rotation_deg": 0, "layer": "top",
         "refdes_placement": {"hidden": True}},
    ], "refdes-overlay")

    rb = _compiled(board)
    p1 = _by_ref(rb, "P1").refdes
    assert p1 is not None
    assert p1.position[1] == pytest.approx(-7.5), "the stated field did not move"
    assert p1.position[0] == pytest.approx(library_anchor["x_mm"]), \
        "an unstated x_mm was overwritten instead of inherited"
    assert p1.size_mm == pytest.approx(library_anchor["size_mm"]), \
        "an unstated size_mm was overwritten instead of inherited"
    assert p1.hidden is False

    p2 = _by_ref(rb, "P2").refdes
    assert p2 is not None and p2.hidden is True
    assert p2.position == pytest.approx(
        (library_anchor["x_mm"], library_anchor["y_mm"])), \
        "hiding a designator also moved it"
    assert _projected_refdes_ink(rb, "P2") is None, \
        "a hidden designator still projects ink"

    # The same rule on the loose-dict surface the KiCad export reads.
    pcb_text = kicad.generate_ir(rb, base_name="ovl")["ovl.kicad_pcb"]
    _x, y, hidden = _kicad_reference(pcb_text, "P1")
    assert y == pytest.approx(-7.5) and hidden is False
    assert _kicad_reference(pcb_text, "P2")[2] is True, \
        "the .kicad_pcb reference of a hidden designator is not hidden"


# ---------------------------------------------------------------------------
# 4. The board is the authority, and it is the ONLY authored one
# ---------------------------------------------------------------------------


def test_an_unset_component_states_no_placement_of_its_own():
    """The other half of the contract: the derived answer is never written back
    as if somebody had chosen it.

    Oracle: the component dicts themselves, before and after a resolve. A board
    that learned to persist the derived anchor would freeze one machine's
    library into the document and stop following a footprint that changed.
    """
    board = _library_board()
    resolved = resolve_board(copy.deepcopy(board))
    for comp in resolved["components"]:
        if comp["ref"] == "U1":
            assert comp[refdes_anchor.COMPONENT_REFDES_KEY]["y_mm"] == \
                pytest.approx(AUTHORED["y_mm"]), \
                "the resolve rewrote the board's own authored placement"
        else:
            assert refdes_anchor.COMPONENT_REFDES_KEY not in comp, (
                f"{comp['ref']} came back from the resolve claiming an authored "
                f"placement nobody set")
