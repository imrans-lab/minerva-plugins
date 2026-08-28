"""WHERE the reference designator prints — it must be clear of the part.

THE DEFECT THIS FILE PINS. A designator's anchor used to be a single constant,
``silk_source.REFDES_LOCAL_Y_MM = -1.5``: 1.5 mm above the footprint's ORIGIN,
which is inside the body of anything bigger than an 0805. A 6 x 6 mm tactile
switch got its ref printed under the switch, where it is invisible the moment
the part is soldered — silk that costs ink and tells nobody anything. The rule
is now derived from the footprint's own courtyard (``pcb_worker.refdes_anchor``)
and the constant is only the last resort for a footprint with no body at all.

WHAT MAKES THESE TESTS ORACLES rather than restatements of the rule: every
assertion measures the designator against geometry the rule does not compute —
the footprint's courtyard lines and pad lands as the COMPILED IR carries them,
an independently-applied placement transform, or the authored ``fp_text``
numbers read straight out of the parse. None of them re-derives the anchor with
the code under test and compares it to itself.

Boards are the synthetic corpus only (``testdata/POLICY.md``). The seed library's
footprints are public-origin library parts, not a board design, and are swept
directly because a board only ever exercises the handful of footprints it uses.
"""

from __future__ import annotations

import glob
import math
from pathlib import Path

import pytest
import yaml

from pcb_worker import footprints, refdes_anchor, silk_source
from pcb_worker.compile_board import compile_board
from pcb_worker.footprint_def import FootprintDefinition
from pcb_worker.geometry import PlacementTransform
from pcb_worker.resolved_board import ResolutionSuccess, Side
from pcb_worker.silk_source import (
    REFDES_LOCAL_Y_MM,
    REFDES_TEXT_SIZE_MM,
    SILK_TEXT_WIDTH_MM,
)

TESTDATA = Path(__file__).parent / "testdata"
SEED_FOOTPRINTS = sorted(
    glob.glob(str(Path(__file__).parents[2] / "library" / "footprints"
                  / "*.pretty" / "*.kicad_mod")))

#: Half a stroke: the glyph polylines are centrelines, the ink is this much
#: wider on every side. Every clearance below is measured on the INK.
HALF_STROKE = SILK_TEXT_WIDTH_MM / 2.0


# ---------------------------------------------------------------------------
# Measurement helpers — geometry only, none of them consult the anchor rule.
# ---------------------------------------------------------------------------


def _bbox(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def _overlaps(a, b) -> bool:
    """True when two axis-aligned boxes share more than a touching edge."""
    return (a[0] < b[2] and b[0] < a[2]) and (a[1] < b[3] and b[1] < a[3])


def _local_strokes(ref: str, reference_text):
    """The designator's footprint-LOCAL glyph points: the production stroke
    builder at an identity placement, which is exactly the local frame."""
    return [list(prim.points) for prim in silk_source.refdes_strokes(
        ref, 0.0, 0.0, 0.0, reference_text, Side.TOP)]


def _ink_bbox(strokes):
    box = _bbox([p for stroke in strokes for p in stroke])
    return (box[0] - HALF_STROKE, box[1] - HALF_STROKE,
            box[2] + HALF_STROKE, box[3] + HALF_STROKE)


def _definition_body_boxes(footprint) -> list[tuple]:
    """Every box the designator must stay off: the courtyard lines, the drawn
    outline, and each pad land, SEPARATELY — read off the FootprintDefinition's
    own graphics and pads rather than through the extent the anchor rule
    measures, so a bug in that extent cannot hide behind itself."""
    boxes = []
    for graphic in footprint.graphics:
        if graphic.layer.id in (refdes_anchor.COURTYARD_LAYERS
                                | refdes_anchor.OUTLINE_LAYERS):
            boxes.append(_bbox(_graphic_points(graphic)))
    for pad in footprint.pads:
        (x, y), size = pad.position, pad.size or (0.0, 0.0)
        boxes.append(_bbox(_turned_corners(
            x, y, size[0] / 2.0, size[1] / 2.0, pad.rotation_deg)))
    return boxes


def _graphic_points(graphic) -> list[tuple[float, float]]:
    for attrs in (("a", "b"), ("start", "mid", "end")):
        if all(hasattr(graphic, name) for name in attrs):
            return [getattr(graphic, name) for name in attrs]
    if hasattr(graphic, "radius_mm"):
        cx, cy = graphic.center
        r = graphic.radius_mm
        return [(cx - r, cy - r), (cx + r, cy + r)]
    return list(graphic.points)


def _turned_corners(x, y, half_w, half_h, rotation_deg):
    """A land's four corners, turned by its own rotation — KiCad's clockwise
    convention in a Y-down frame, spelled out here rather than imported so the
    measurement is independent of the code under test."""
    theta = -math.radians(rotation_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    return [(x + dx * cos_t - dy * sin_t, y + dx * sin_t + dy * cos_t)
            for dx, dy in ((-half_w, -half_h), (half_w, -half_h),
                           (half_w, half_h), (-half_w, half_h))]


def _assert_clear(ref: str, name: str, footprint) -> bool:
    """The whole contract for ONE footprint with a DERIVED anchor: its
    designator's ink touches neither its body outlines nor any of its lands.
    Returns False when the footprint prints no designator at all (an
    authored-hidden reference).

    AUTHORED anchors are deliberately NOT held to this: where a footprint's
    author put the field is the author's call and this code never moves it —
    the seed DIP-6_W7.62mm_Socket, for one, authors a reference that grazes its
    own top pad row.
    """
    assert footprint.reference_text is None, (
        f"{name}: _assert_clear is the DERIVED-anchor contract")
    reference_text = refdes_anchor.effective_reference_text(footprint)
    strokes = _local_strokes(ref, reference_text)
    if not strokes:
        return False
    ink = _ink_bbox(strokes)
    for box in _definition_body_boxes(footprint):
        assert not _overlaps(ink, box), (
            f"{ref} ({name}): the designator's ink {ink} lands on the "
            f"footprint's own body/land {box} — printed there it is under the "
            f"part once it is soldered")
    return True


def _compile_fixture(path: Path):
    result = compile_board(yaml.safe_load(path.read_text(encoding="utf-8")))
    assert isinstance(result, ResolutionSuccess), (
        f"{path.name} must compile for this test to mean anything: "
        f"{[d.code for d in result.diagnostics]}")
    return result.board


def _parsed_seed(path: str) -> dict:
    return footprints.parse_kicad_mod(Path(path).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# 1. Whole compiled boards
# ---------------------------------------------------------------------------


def test_every_compiled_designator_prints_clear_of_its_own_body():
    """The headline, on the production compile path: a component whose
    footprint authors no reference text does not print its ref on top of its
    own courtyard, outline or lands.

    Oracle: the courtyard/outline/pad geometry the COMPILED IR carries — the
    footprint's authored artwork, measured directly off the definition rather
    than through the anchor rule's own extent.
    """
    checked = 0
    for fixture in ("coupon_jlc1.yaml", "parity_corners.yaml"):
        rb = _compile_fixture(TESTDATA / fixture)
        for comp in rb.components:
            footprint = rb.footprint_for(comp)
            if footprint.reference_text is not None:
                continue  # authored — untouched, see _assert_clear
            if _assert_clear(comp.ref, footprint.name, footprint):
                checked += 1
    assert checked >= 1, (
        "no compiled component reached the DERIVED anchor — this test stopped "
        "covering the production path")


# ---------------------------------------------------------------------------
# 2. Every footprint in the seed library
# ---------------------------------------------------------------------------


def test_seed_library_derived_anchors_clear_every_footprint_body():
    """Every seed footprint that authors NO reference text gets a designator
    that clears its body — the sweep a board cannot do, because a board only
    uses the handful of footprints it happens to place.

    Oracle: as above, each footprint's own artwork; plus the ink must sit at
    least CLEARANCE_MM above the body's top edge, which is the rule stated as a
    measured distance rather than as the formula that produced it.
    """
    swept = 0
    for path in SEED_FOOTPRINTS:
        parsed = _parsed_seed(path)
        if parsed.get("reference_text") is not None:
            continue
        footprint = FootprintDefinition.from_kicad_parsed(parsed)
        name = Path(path).name
        if not _assert_clear("R99", name, footprint):
            continue
        swept += 1
        extent = refdes_anchor.occupied_extent_from_definition(footprint)
        assert extent is not None, f"{name}: a seed footprint with no body at all"
        ink = _ink_bbox(_local_strokes(
            "R99", refdes_anchor.effective_reference_text(footprint)))
        assert ink[3] <= extent.min_y - refdes_anchor.CLEARANCE_MM + 1e-9, (
            f"{name}: the designator's ink reaches y={ink[3]}, less than "
            f"{refdes_anchor.CLEARANCE_MM} mm clear of the body top "
            f"{extent.min_y}")
    assert swept >= 10, (
        f"only {swept} seed footprints exercised the DERIVED anchor — either "
        f"the library changed or the filter above stopped selecting")


# ---------------------------------------------------------------------------
# 3. The motivating shape
# ---------------------------------------------------------------------------


#: A tactile switch's proportions — two 2 x 2 mm lands 6 mm apart inside a
#: courtyard spanning y -3.3 .. +3.4 — with NO authored reference text, which
#: is the case the old fixed offset printed the ref right into the middle of.
SWITCH_SHAPED = {
    "name": "SW_SwitchShaped",
    "pads": [
        {"number": "A", "type": "smd", "shape": "rect", "x_mm": -3.0,
         "y_mm": 0.0, "size": (2.0, 2.0), "layers": ["F.Cu"]},
        {"number": "B", "type": "smd", "shape": "rect", "x_mm": 3.0,
         "y_mm": 0.0, "size": (2.0, 2.0), "layers": ["F.Cu"]},
    ],
    "graphics": [
        {"kind": "line", "layer": "F.CrtYd", "width": 0.05,
         "start": (-4.25, -3.3), "end": (4.25, -3.3)},
        {"kind": "line", "layer": "F.CrtYd", "width": 0.05,
         "start": (4.25, -3.3), "end": (4.25, 3.4)},
        {"kind": "line", "layer": "F.CrtYd", "width": 0.05,
         "start": (4.25, 3.4), "end": (-4.25, 3.4)},
        {"kind": "line", "layer": "F.CrtYd", "width": 0.05,
         "start": (-4.25, 3.4), "end": (-4.25, -3.3)},
    ],
}

COURTYARD_TOP = -3.3


def test_a_switch_shaped_courtyard_puts_the_designator_above_the_body():
    """The measured case. Every stroke lands above the courtyard's top edge,
    and the text is centred on the courtyard rather than on the origin.

    Oracle: the literal -3.3 the fixture authors, hand-read from the courtyard
    lines above — the old constant put the baseline at -1.5, 1.8 mm INSIDE it.
    """
    footprint = FootprintDefinition.from_kicad_parsed(SWITCH_SHAPED)
    reference_text = refdes_anchor.effective_reference_text(footprint)
    assert reference_text is not None
    assert reference_text.rotation_deg == 0.0
    assert reference_text.size_mm == REFDES_TEXT_SIZE_MM

    strokes = _local_strokes("SW2", reference_text)
    assert strokes, "the switch must print its designator"
    ink = _ink_bbox(strokes)
    assert ink[3] < COURTYARD_TOP, (
        f"the designator's ink reaches y={ink[3]}, at or below the courtyard "
        f"top {COURTYARD_TOP} — it would print on the switch body")
    assert ink[1] > COURTYARD_TOP - 4.0, (
        f"the designator floated {COURTYARD_TOP - ink[1]} mm off the part; "
        f"clear of the body is not the same as far away from it")
    assert (ink[0] + ink[2]) / 2.0 == pytest.approx(0.0, abs=1e-9), (
        "the text is centred on the courtyard's x centre")


def test_a_bottom_side_switch_mirrors_and_still_clears_its_courtyard():
    """The same part on the back. The anchor is footprint-local, so the mirror
    is the placement's job — and because the courtyard mirrors with it, the
    clearance survives.

    Oracle: an INDEPENDENT application of geometry.PlacementTransform to the
    local glyph points, plus the placed courtyard corners. The placement is kept
    axis-aligned so the two boxes can be compared as boxes; the rotated half of
    the transform is pinned by test_silk_designator_rotation.py.
    """
    footprint = FootprintDefinition.from_kicad_parsed(SWITCH_SHAPED)
    reference_text = refdes_anchor.effective_reference_text(footprint)
    placement = PlacementTransform(position=(17.0, 23.0), rotation_deg=0.0,
                                   side=Side.BOTTOM)

    local = _local_strokes("SW2", reference_text)
    placed = [list(prim.points) for prim in silk_source.refdes_strokes(
        "SW2", 17.0, 23.0, 0.0, reference_text, Side.BOTTOM)]
    assert len(placed) == len(local) and placed
    for got, want in zip(placed, local):
        for (gx, gy), point in zip(got, want):
            wx, wy = placement.point(point)
            assert (gx, gy) == pytest.approx((wx, wy), abs=1e-9)

    # The mirror is not a no-op: local Y flips, so the text that sits ABOVE the
    # part in the footprint frame prints BELOW the part's centre on the back.
    text_box = _bbox([p for stroke in placed for p in stroke])
    assert text_box[1] > 23.0, (
        f"the bottom-side designator stayed above the part centre "
        f"({text_box}) — the local-Y mirror was not applied")

    courtyard = _bbox([placement.point(p) for p in
                       ((-4.25, -3.3), (4.25, -3.3), (4.25, 3.4), (-4.25, 3.4))])
    assert not _overlaps((text_box[0] - HALF_STROKE, text_box[1] - HALF_STROKE,
                          text_box[2] + HALF_STROKE, text_box[3] + HALF_STROKE),
                         courtyard), (
        "the mirrored designator landed on the mirrored courtyard")


# ---------------------------------------------------------------------------
# 4. What must NOT change
# ---------------------------------------------------------------------------


def test_an_authored_anchor_is_never_touched():
    """A footprint that places its own reference fp_text keeps it exactly —
    position, rotation, size and the hidden flag — on both the wire dict the
    panel reads and the definition the emitter reads.

    Oracle: the numbers the parser read out of the .kicad_mod, compared
    field-by-field against what each surface reports.
    """
    authored = 0
    for path in SEED_FOOTPRINTS:
        parsed = _parsed_seed(path)
        raw = parsed.get("reference_text")
        if raw is None:
            continue
        authored += 1
        name = Path(path).name

        wire = refdes_anchor.anchor_dict_from_parsed(parsed)
        assert wire == {
            "x_mm": raw["x_mm"], "y_mm": raw["y_mm"],
            "rotation_deg": raw.get("rotation_deg", 0.0),
            "size_mm": raw.get("size_mm", REFDES_TEXT_SIZE_MM),
            "hidden": bool(raw.get("hidden") or False),
        }, f"{name}: the authored anchor was rewritten on the wire"

        footprint = FootprintDefinition.from_kicad_parsed(parsed)
        assert (refdes_anchor.effective_reference_text(footprint)
                is footprint.reference_text), (
            f"{name}: the emitter was handed something other than the "
            f"footprint's own authored reference text")
    assert authored >= 10, (
        f"only {authored} seed footprints author a reference text — this test "
        f"stopped covering the authored path")


def test_wire_anchor_and_emitter_anchor_agree_for_every_seed_footprint():
    """The cross-surface seal. The panel strokes the ref at the anchor the
    resolve put on the wire; the Gerber emitter and the DRC silk projection
    stroke it at the effective reference text. Those are two code paths reading
    two different footprint representations, and they must land on one place.

    Oracle: the two surfaces' own outputs compared against each other over the
    whole library — a rule that drifted in one representation and not the other
    (a layer name, a field name, a fallback order) shows up as a mismatch here
    and nowhere else.
    """
    for path in SEED_FOOTPRINTS:
        parsed = _parsed_seed(path)
        wire = refdes_anchor.anchor_dict_from_parsed(parsed)
        reference_text = refdes_anchor.effective_reference_text(
            FootprintDefinition.from_kicad_parsed(parsed))
        if reference_text is None:
            emitter = {"x_mm": 0.0, "y_mm": REFDES_LOCAL_Y_MM,
                       "rotation_deg": 0.0, "size_mm": REFDES_TEXT_SIZE_MM,
                       "hidden": False}
        else:
            emitter = {
                "x_mm": reference_text.position[0],
                "y_mm": reference_text.position[1],
                "rotation_deg": reference_text.rotation_deg,
                "size_mm": reference_text.size_mm,
                "hidden": reference_text.hidden,
            }
        assert wire == emitter, (
            f"{Path(path).name}: the panel would draw the designator at {wire} "
            f"and the fab would print it at {emitter}")


# ---------------------------------------------------------------------------
# 5. The fallback ladder
# ---------------------------------------------------------------------------


def test_the_anchor_clears_the_outermost_thing_the_footprint_draws():
    """Courtyard, drawn outline and lands are UNIONED, so the anchor clears
    whichever reaches highest — and with none of them it falls back to the
    historical constant.

    Oracle: four hand-authored footprints whose top edges are four distinct
    literal numbers, including one whose SILK pokes out of its courtyard (the
    shape ESP32-S3-DevKitC-1_SocketSet_2x22_THT really has). Which basis was
    used is readable from the answer alone.
    """
    pad = {"number": "1", "type": "smd", "shape": "rect", "x_mm": 0.0,
           "y_mm": 0.0, "size": (2.0, 1.0), "layers": ["F.Cu"]}
    courtyard = {"kind": "line", "layer": "F.CrtYd", "width": 0.05,
                 "start": (-3.0, -3.0), "end": (3.0, 3.0)}
    tucked_outline = {"kind": "line", "layer": "F.SilkS", "width": 0.12,
                      "start": (-2.0, -2.0), "end": (2.0, 2.0)}
    tall_outline = {"kind": "line", "layer": "F.SilkS", "width": 0.12,
                    "start": (-2.0, -4.0), "end": (2.0, 2.0)}
    drop = refdes_anchor.CLEARANCE_MM + HALF_STROKE

    # A stroke is centred on its geometry, so each top edge is half a width
    # above the authored centreline: 0.025 for the 0.05 courtyard, 0.06 for the
    # 0.12 outline.
    contained = {"name": "fp", "pads": [pad],
                 "graphics": [tucked_outline, courtyard]}
    assert refdes_anchor.anchor_dict_from_parsed(contained)["y_mm"] == \
        pytest.approx(-3.025 - drop), \
        "the courtyard contains the artwork, so the courtyard is the top edge"

    poking_out = {"name": "fp", "pads": [pad],
                  "graphics": [tall_outline, courtyard]}
    assert refdes_anchor.anchor_dict_from_parsed(poking_out)["y_mm"] == \
        pytest.approx(-4.06 - drop), \
        "silk drawn ABOVE the courtyard must still be cleared"

    silk_only = {"name": "fp", "pads": [pad], "graphics": [tucked_outline]}
    assert refdes_anchor.anchor_dict_from_parsed(silk_only)["y_mm"] == \
        pytest.approx(-2.06 - drop), \
        "no courtyard: the drawn outline is the top edge"

    pads_only = {"name": "fp", "pads": [pad], "graphics": []}
    assert refdes_anchor.anchor_dict_from_parsed(pads_only)["y_mm"] == \
        pytest.approx(-0.5 - drop), "a graphics-free footprint measures its lands"

    bare = {"name": "fp", "pads": [], "graphics": []}
    assert refdes_anchor.anchor_dict_from_parsed(bare) == {
        "x_mm": 0.0, "y_mm": REFDES_LOCAL_Y_MM, "rotation_deg": 0.0,
        "size_mm": REFDES_TEXT_SIZE_MM, "hidden": False}, \
        "a footprint with no body at all keeps the historical constant"


def test_the_panel_body_box_keeps_its_courtyard_first_precedence():
    """The BODY box is a different question: "how big is this part", answered
    by ONE basis (courtyard, else outline, else lands) — not the union the
    anchor uses. Sharing the point extractors must not have merged the two.

    Oracle: a footprint whose courtyard is SMALLER than its silk. The body box
    must report the courtyard's 6 mm (plus its own 0.05 stroke); the anchor must
    clear the silk's 4 mm top (plus its 0.12 stroke).
    """
    small_courtyard = {"kind": "line", "layer": "F.CrtYd", "width": 0.05,
                       "start": (-3.0, -3.0), "end": (3.0, 3.0)}
    tall_silk = {"kind": "line", "layer": "F.SilkS", "width": 0.12,
                 "start": (-2.0, -4.0), "end": (2.0, 4.0)}
    parsed = {"name": "fp", "pads": [],
              "graphics": [tall_silk, small_courtyard]}

    body = refdes_anchor.body_extent_from_parsed(parsed)
    assert (body.min_y, body.max_y) == pytest.approx((-3.025, 3.025))
    occupied = refdes_anchor.occupied_extent_from_parsed(parsed)
    assert (occupied.min_y, occupied.max_y) == pytest.approx((-4.06, 4.06))


def test_a_single_land_is_not_a_body_but_a_turned_one_is_measured_turned():
    """Two edges of the extent measurement: a zero-size pad is a point, not an
    extent (so a footprint that is only that falls through to the constant), and
    a land's own rotation widens the box it contributes.

    Oracle: (2 + 1) / sqrt(2) — the hand-derived diagonal span of a 2 x 1 mm
    land turned 45 degrees, which an axis-aligned measurement cannot produce.
    """
    point_pad = {"name": "fp", "graphics": [],
                 "pads": [{"number": "1", "type": "smd", "shape": "circle",
                           "x_mm": 1.0, "y_mm": 2.0, "layers": ["F.Cu"]}]}
    assert refdes_anchor.occupied_extent_from_parsed(point_pad) is None
    assert refdes_anchor.anchor_dict_from_parsed(point_pad)["y_mm"] == \
        REFDES_LOCAL_Y_MM

    turned = {"name": "fp", "graphics": [],
              "pads": [{"number": "1", "type": "smd", "shape": "rect",
                        "x_mm": 0.0, "y_mm": 0.0, "size": (2.0, 1.0),
                        "rotation": 45.0, "layers": ["F.Cu"]}]}
    extent = refdes_anchor.occupied_extent_from_parsed(turned)
    span = 3.0 / math.sqrt(2.0)
    assert extent.width == pytest.approx(span)
    assert extent.height == pytest.approx(span)


# ---------------------------------------------------------------------------
# 6. The ink, not the centreline
# ---------------------------------------------------------------------------


#: An arc authored ON A KNOWN CIRCLE, so this test never has to ask the code
#: under test where the arc goes. The sweep runs 200 -> 340 degrees, which
#: passes through 270 — the circle's extreme on Y, and NOT one of the three
#: control points KiCad stores. A wide stroke on top of that separates "the ink"
#: from "the geometry".
_ARC_CENTER = (0.0, 0.0)
_ARC_RADIUS = 2.0
_ARC_STROKE_MM = 0.8
_ARC_ANGLES = (200.0, 210.0, 340.0)  # start, mid, end


def _on_arc_circle(degrees: float) -> tuple[float, float]:
    return (_ARC_CENTER[0] + _ARC_RADIUS * math.cos(math.radians(degrees)),
            _ARC_CENTER[1] + _ARC_RADIUS * math.sin(math.radians(degrees)))


def _tiny_pad() -> dict:
    return {"number": "1", "type": "smd", "shape": "rect", "x_mm": 0.0,
            "y_mm": 0.0, "size": (1.0, 1.0), "layers": ["F.Cu"]}


def test_the_anchor_clears_an_arcs_true_bow_and_a_thick_strokes_ink():
    """A footprint whose body is a WIDE arc that bows past both its endpoints.

    Two understatements used to hide here and both put ink on the part: the
    extent was measured on stored control points (so the bow was invisible) and
    on centrelines (so half of every stroke was invisible).

    Oracle: the CIRCLE the arc's points were authored on — centre, radius and
    the three angles are literals above, and 270 degrees is inside the sweep, so
    the arc provably reaches ``centre_y - radius``. The clearance is measured
    from that number against the designator's real ink, and the control-point
    box is asserted to be a DIFFERENT (higher) number, so a regression to it
    cannot pass.
    """
    start, mid, end = (_on_arc_circle(angle) for angle in _ARC_ANGLES)
    arc = {"kind": "arc", "layer": "F.SilkS", "width": _ARC_STROKE_MM,
           "points": [list(start), list(mid), list(end)]}
    parsed = {"name": "ARC_BOW", "pads": [_tiny_pad()], "graphics": [arc]}

    bow_top = _ARC_CENTER[1] - _ARC_RADIUS - _ARC_STROKE_MM / 2.0
    control_top = min(p[1] for p in (start, mid, end)) - _ARC_STROKE_MM / 2.0
    assert control_top > bow_top + 0.5, (
        f"the fixture stopped separating the swept extent {bow_top} from the "
        f"control-point box {control_top}")

    for label, extent in (
            ("parsed", refdes_anchor.occupied_extent_from_parsed(parsed)),
            ("definition", refdes_anchor.occupied_extent_from_definition(
                FootprintDefinition.from_kicad_parsed(parsed)))):
        assert extent.min_y == pytest.approx(bow_top), (
            f"the {label} extent tops out at {extent.min_y}; the arc's ink "
            f"reaches {bow_top}")

    footprint = FootprintDefinition.from_kicad_parsed(parsed)
    ink = _ink_bbox(_local_strokes(
        "R7", refdes_anchor.effective_reference_text(footprint)))
    assert ink[3] <= bow_top - refdes_anchor.CLEARANCE_MM + 1e-9, (
        f"the designator's ink reaches y={ink[3]}, less than "
        f"{refdes_anchor.CLEARANCE_MM} mm clear of the arc's ink at {bow_top}")
    assert ink[3] > control_top - 10.0, (
        "the designator floated off the part; clear is not the same as far")

    # KiCad 6 authors the same arc as centre + start + a signed sweep. It must
    # measure the same, because it IS the same arc — the two forms reach the
    # extent through different code.
    legacy = {"kind": "arc", "layer": "F.SilkS", "width": _ARC_STROKE_MM,
              "points": [list(_ARC_CENTER), list(start)],
              "angle": -(_ARC_ANGLES[2] - _ARC_ANGLES[0])}
    legacy_parsed = {"name": "ARC_BOW6", "pads": [_tiny_pad()],
                     "graphics": [legacy]}
    assert refdes_anchor.occupied_extent_from_parsed(legacy_parsed).min_y == \
        pytest.approx(bow_top)

    # The stroke half alone, with no curvature to confuse it: a 0.6 mm line
    # drawn along y = -1 prints ink to -1.3, and the anchor drops from there.
    thick_line = {"name": "THICK", "pads": [_tiny_pad()], "graphics": [
        {"kind": "line", "layer": "F.SilkS", "width": 0.6,
         "start": (-2.0, -1.0), "end": (2.0, -1.0)}]}
    assert refdes_anchor.anchor_dict_from_parsed(thick_line)["y_mm"] == \
        pytest.approx(-1.3 - refdes_anchor.CLEARANCE_MM - HALF_STROKE), \
        "the anchor was measured from the line's centreline, not its ink"
