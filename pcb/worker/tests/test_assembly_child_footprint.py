"""AN EXPANSION CHILD THAT NAMES THE DRAWING IT IS.

A child of ``assembly.placements`` carries no copper -- the parent draws all
of it -- so on its own it is a rotation and an offset with no identity. Its
CPL row used to be gated on the PARENT's footprint, which for a socket set is
the pair (a 44-pad two-row drawing, jlcpcb, a 22-pad strip): not a measurable
comparison, so the ledger could never learn it and the order refused forever.
The only escape was to smuggle the vendor's convention into the child's
``rotation_deg`` -- a design field -- which rotates a hand-authored anchor off
the part and double-applies the moment the ledger does learn the pair.

``assembly.placements[].footprint`` is the identity. A child that names the
1x22 strip it is bought as is a PART with that drawing for everything about
the part: its orientation pair, its body centre, its BOM footprint. This suite
is the proof, on ``testdata/assembly_boards/assembly_child_footprint.yaml``,
against five oracles that are each independent of the code they check:

  (a) the ledger row for the strip pair exists, is decided, and states the
      offset that the two DRAWINGS give by hand -- pad 1 to pad 22 in each;
  (b) the two measured child anchors equal the numbers the previous shape of
      the board wrote down by hand, months apart;
  (c) the child-lands gate refuses a turned child, a shifted child, a shorter
      strip and two children on one strip, and passes the true placement;
  (d) every one of those on BOTH sides of the board, because a sign error in
      the bottom-side composition is a physically wrong board that no
      top-side-only test can distinguish;
  (e) the emission carries the ledger's correction on the children's rows,
      with no refusal about U1S left, while a pair nobody measured (the
      switches) still refuses.

EVERY EXPECTATION IS HAND-DERIVED from the fixture's authored numbers, the two
footprint files' own pad grids, and the transform ``geometry.py`` documents --
``board = position + R_cw(rot) . mirror(local)``, with ``R_cw(d).(x, y) =
(x.cos d + y.sin d, -x.sin d + y.cos d)`` and ``mirror`` negating local Y on
the bottom side. Nothing below asks the worker what it thinks the answer is.

  TOP. The parent sits at (45, 62.797), rotation 180, so ``R_cw(180).(x, y) =
  (-x, -y)`` and no mirror::

    origins   A  offset (-11.43, 0) -> ( 11.43, 0) -> (56.43, 62.797)
              B  offset ( 11.43, 0) -> (-11.43, 0) -> (33.57, 62.797)
    composed  180 + 0 = 180
    strip pad k, local (0, 2.54(k-1))  -> (0, -2.54(k-1))
              A  (56.43, 62.797 - 2.54(k-1))   pad 22 at (56.43, 9.457)
    strip body centre (0, 26.67)       -> (0, -26.67)
              A  (56.43, 36.127)   B  (33.57, 36.127)

  and the parent's own row pads, local (-11.43, 2.54(k-1)), land on exactly
  the same points as A's strip -- which is what the gate checks.

  BOTTOM. The suite moves the parent to (45, 20) on the bottom side and
  changes nothing else. Local Y is negated BEFORE the same ``R_cw(180)``::

    origins   A  (-11.43, 0) -> mirror (-11.43, 0) -> (11.43, 0) -> (56.43, 20)
              B                                                  -> (33.57, 20)
    composed  180 - 0 = 180
    strip pad k  (0, 2.54(k-1)) -> (0, -2.54(k-1)) -> (0, 2.54(k-1))
              A  (56.43, 20 + 2.54(k-1))         pad 22 at (56.43, 73.34)
    body centre  (0, 26.67) -> (0, -26.67) -> (0, 26.67)
              A  (56.43, 46.67)   B  (33.57, 46.67)

  A composition that forgot the mirror would put every land and the anchor
  at ``20 - ...`` instead: off the parent's copper, and refused.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_gates as ag
from pcb_worker import assembly_orientation as aor
from pcb_worker import assembly_outputs as ao
from pcb_worker import footprints
from pcb_worker import orientation_ledger as ol
from pcb_worker import part_orientation as po
from pcb_worker import refdes_anchor as ra
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    ANCHOR_BASIS_AUTHORED, ANCHOR_BASIS_FAB, DiagnosticSeverity,
    ResolutionFailure, ResolutionSuccess,
)

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "testdata" / "assembly_boards" / "assembly_child_footprint.yaml"
SIBLING_FIXTURE = HERE / "testdata" / "assembly_boards" / "assembly_anchor_off_lands.yaml"
VENDOR_PAYLOAD = HERE / "testdata" / "vendor_footprints" / "C41376161.json"
COVERAGE = HERE.parents[1] / "library" / "part_orientation_coverage.md"

STRIP = "Connector_PinSocket_2.54mm:PinSocket_1x22_P2.54mm_Vertical_HC-PM254-8.5H"
#: A shipped drawing the library resolves that draws NO pads (silk artwork).
NO_PAD_DRAWING = "Minerva_Fixture:LOGO_Owl_TestCoupon"
SHORTER_STRIP = "Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical"
PARENT = "Espressif:ESP32-S3-DevKitC-1_SocketSet_2x22_THT"
HOUSE, PART = "jlcpcb", "C41376161"

PITCH = 2.54
PINS = 22
#: Where the suite puts the parent for the bottom-side arm.
BOTTOM_PARENT_Y = 20.0

#: Written as literals; see the module docstring for each derivation. The
#: top-side anchors are also what the board's previous shape wrote down by
#: hand for the two strips, (56.43, 36.13) and (33.57, 36.13) — two derivations
#: of one number, months apart, agreeing to the rounding then quoted.
TOP_ORIGINS = {"U1S_A": (56.43, 62.797), "U1S_B": (33.57, 62.797)}
TOP_ANCHORS = {"U1S_A": (56.43, 36.127), "U1S_B": (33.57, 36.127)}
BOTTOM_ORIGINS = {"U1S_A": (56.43, 20.0), "U1S_B": (33.57, 20.0)}
BOTTOM_ANCHORS = {"U1S_A": (56.43, 46.67), "U1S_B": (33.57, 46.67)}
COMPOSED_ROTATION = 180.0

#: Each defect, as the ONE edit applied to the parsed document. The distance
#: the refusal must report for the two subset misses is a pitch: a quarter
#: turn puts pad 2 a pitch beside the row, and a one-pitch shift puts pad 22
#: a pitch past the row's end.
DEFECT_ROTATION = 90.0
DEFECT_DISTANCE_MM = PITCH


# ---------------------------------------------------------------------------
# Documents, on either side
# ---------------------------------------------------------------------------


def _document(*, bottom: bool = False, edit=None) -> dict:
    """The fixture as authored, on the top side, or moved to the bottom, with
    ONE further edit applied to the U1S expansion if given -- so no second
    copy of the board can drift from the first."""
    document = yaml.safe_load(FIXTURE.read_text(encoding="utf-8"))
    expansion = _expansion(document)
    if bottom:
        expansion["layer"] = "bottom"
        expansion["y_mm"] = BOTTOM_PARENT_Y
    if edit is not None:
        edit(expansion)
    return document


def _expansion(document: dict) -> dict:
    for component in document["components"]:
        if component["ref"] == "U1S":
            return component
    raise AssertionError("the fixture no longer authors the U1S expansion")


def _children(expansion: dict) -> list:
    return expansion["assembly"]["placements"]


def _compiled(document: dict):
    """Fails LOUDLY rather than skipping: a fixture that stopped compiling
    would silently stop testing anything here."""
    result = compile_board(document)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(f"{d.code}: {d.message}" for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _placements(board) -> dict:
    return {item.ref: item
            for component in board.components
            for item in component.physical_placements}


def _component(board, ref: str):
    for component in board.components:
        if component.ref == ref:
            return component
    raise AssertionError(f"the fixture no longer places {ref}")


def _close(actual, expected, tolerance=1e-9) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def _sorted_points(points) -> list:
    return sorted((round(x, 6), round(y, 6)) for x, y in points)


#: The shipped ledger, read once and passed EXPLICITLY to every emission, so
#: no other suite's substitution of the module cache can reach these claims.
@pytest.fixture(scope="module")
def ledger() -> ol.OrientationLedger:
    return ol.load_ledger()


def _emit(board, ledger):
    return ao.emit(board, "jlc", orientation=ledger)


# ---------------------------------------------------------------------------
# The two drawings, read without the measurement code
# ---------------------------------------------------------------------------


def _vendor_row_vector() -> tuple[float, float]:
    """Pad 1 to pad 22 in the VENDOR's drawing, read straight off the payload's
    ``PAD~`` records (field 2/3 the centre, field 8 the number) in the vendor's
    own units -- a direction needs no scale."""
    payload = json.loads(VENDOR_PAYLOAD.read_text(encoding="utf-8"))
    centres = {}
    for record in payload["result"]["packageDetail"]["dataStr"]["shape"]:
        if record.startswith("PAD~"):
            fields = record.split("~")
            centres[fields[8]] = (float(fields[2]), float(fields[3]))
    (x1, y1), (x22, y22) = centres["1"], centres[str(PINS)]
    return (x22 - x1, y22 - y1)


def _our_row_vector() -> tuple[float, float]:
    """Pad 1 to pad 22 in OUR strip, off the parsed ``.kicad_mod``."""
    parsed = footprints.resolve_footprint(STRIP)
    centres = {str(p["number"]): (float(p["x_mm"]), float(p["y_mm"]))
               for p in parsed["pads"]}
    (x1, y1), (x22, y22) = centres["1"], centres[str(PINS)]
    return (x22 - x1, y22 - y1)


def _ccw_on_screen_y_down(vector, degrees):
    """A counter-clockwise turn AS SEEN ON SCREEN, in a frame whose Y grows
    downward -- the frame both the vendor's canvas and a ``.kicad_mod`` use.
    Written out here rather than borrowed, because it is the convention the
    ledger's sign rests on: ``our = rotate(vendor, offset)``."""
    radians = math.radians(degrees)
    x, y = vector
    return (x * math.cos(radians) + y * math.sin(radians),
            -x * math.sin(radians) + y * math.cos(radians))


def _ccw_y_up(vector, degrees):
    """A counter-clockwise turn in the EMITTED frame, whose Y grows upward --
    the frame a position file's rotation is read in."""
    radians = math.radians(degrees)
    x, y = vector
    return (x * math.cos(radians) - y * math.sin(radians),
            x * math.sin(radians) + y * math.cos(radians))


def _parallel(a, b) -> bool:
    cross = a[0] * b[1] - a[1] * b[0]
    dot = a[0] * b[0] + a[1] * b[1]
    return abs(cross) <= 1e-6 * math.hypot(*a) * math.hypot(*b) and dot > 0


def _the_one_angle(predicate) -> int:
    """The single orderable angle satisfying ``predicate`` -- and it must be
    single, or the oracle is not an oracle."""
    hits = [angle for angle in po.CANDIDATE_ANGLES if predicate(angle)]
    assert len(hits) == 1, f"the drawings do not settle one angle: {hits}"
    return hits[0]


def _hand_offset() -> int:
    """ORACLE (a): the rotation carrying the vendor's row onto ours, from the
    two pad-1-to-pad-22 directions alone."""
    vendor, ours = _vendor_row_vector(), _our_row_vector()
    return _the_one_angle(
        lambda angle: _parallel(_ccw_on_screen_y_down(vendor, angle), ours))


# ---------------------------------------------------------------------------
# The premise. This suite is worth nothing while the fixture stops authoring
# the shape it was built to author.
# ---------------------------------------------------------------------------


def test_the_fixture_authors_children_that_name_their_drawing_and_nothing_by_hand():
    """Both children name the strip, neither authors an anchor, both are at
    rotation 0, and the parent is bought as the pair the ledger has measured
    against THE STRIP. Take any of those away and the claims below are about a
    different board."""
    expansion = _expansion(_document())
    assert expansion["footprint"] == PARENT
    assert (expansion["x_mm"], expansion["y_mm"]) == (45.0, 62.797)
    assert expansion["rotation_deg"] == 180.0 and expansion["layer"] == "top"
    assert expansion["assembly"]["house_parts"] == {HOUSE: PART}

    children = _children(expansion)
    assert [c["ref"] for c in children] == ["U1S_A", "U1S_B"]
    for child, offset_x in zip(children, (-11.43, 11.43)):
        assert child["footprint"] == STRIP
        assert child["offset_mm"] == {"x": offset_x, "y": 0}
        assert child["rotation_deg"] == 0
        assert "anchor_mm" not in child

    # The switches are on a pair nothing has measured, so their refusal is
    # the control that a refusal about U1S would have hidden behind.
    switches = [c for c in _document()["components"] if c["ref"].startswith("SW")]
    assert len(switches) == 4
    assert all(c["assembly"]["house_parts"] == {HOUSE: "C4365033"} for c in switches)


# ---------------------------------------------------------------------------
# (a) The ledger learned the pair, and the number is the drawings' own
# ---------------------------------------------------------------------------


def test_the_ledger_measured_the_strip_pair_and_the_drawings_agree_on_the_number(ledger):
    """The row for (the strip, jlcpcb, C41376161) exists, is DECIDED with the
    lands agreeing -- the one shape the emitter applies -- and its offset is
    the angle the two drawings give by hand: the vendor draws the row along
    +X, ours runs along +Y, and exactly one quarter-turn carries the first
    onto the second. The parent's own pair is still unknown, as it must be:
    a two-row drawing is not a strip and no measurement can say it is."""
    record = ledger.lookup(STRIP, HOUSE, PART)
    assert ol.state_of(record) == ol.STATE_MEASURED
    assert record.verdict in po.DECIDED_VERDICTS
    assert record.angle_decided and record.lands_agree is True
    assert record.matched_pad_count == PINS
    assert ol.applies_offset(record.offset_deg is not None, record.lands_agree)

    expected = _hand_offset()
    assert record.offset_deg == expected
    # A pair drawn a quarter turn apart is `rotated`, never `aligned`.
    assert record.verdict == (po.VERDICT_ALIGNED if expected == 0
                              else po.VERDICT_ROTATED)
    # The committed coverage report names the pair with that number.
    assert f"- jlcpcb `{PART}` — {expected} deg" in COVERAGE.read_text(encoding="utf-8")

    assert ol.state_of(ledger.lookup(PARENT, HOUSE, PART)) == ol.STATE_UNKNOWN


# ---------------------------------------------------------------------------
# (b) + (d) The anchor is MEASURED off the child's own drawing, on both sides
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bottom, origins, anchors", [
    (False, TOP_ORIGINS, TOP_ANCHORS),
    (True, BOTTOM_ORIGINS, BOTTOM_ANCHORS),
], ids=["top", "bottom"])
def test_a_child_that_names_its_drawing_is_anchored_on_its_own_strip(
        bottom, origins, anchors):
    """No anchor is written and both children resolve onto their own strips:
    the measured basis is the strip's fab outline, the lands are the strip's
    pads placed through the child's transform, and each child's lands are
    exactly the parent pads of its own row.

    On the top side the two anchors are the numbers the earlier board wrote
    by hand (oracle b). On the bottom the lands run +y from the origin, which
    is the mirror composed correctly; a composition without it would run -y
    and every assertion here would miss by tens of millimetres."""
    board = _compiled(_document(bottom=bottom))
    placements = _placements(board)
    parent_pads = _sorted_points(p.position for p in _component(board, "U1S").placed_pads)

    for ref in ("U1S_A", "U1S_B"):
        item = placements[ref]
        assert item.footprint_ref == STRIP
        assert item.anchor_basis == ANCHOR_BASIS_FAB
        assert item.rotation_deg == COMPOSED_ROTATION
        assert item.side.value == ("bottom" if bottom else "top")
        assert _close(item.origin, origins[ref])
        assert _close(item.anchor, anchors[ref])
        assert len(item.lands) == PINS

        # The row, hand-composed: origin, then one pitch per pin AWAY from the
        # origin along -y on top and +y on the bottom.
        step = PITCH if bottom else -PITCH
        ox, oy = origins[ref]
        expected_row = [(ox, oy + step * k) for k in range(PINS)]
        assert _sorted_points(item.lands) == _sorted_points(expected_row)
        # ...and every one of them is one of the parent's own pads.
        assert all(land in parent_pads for land in _sorted_points(item.lands))

    # The two rows partition the parent's copper between them.
    assert sorted(_sorted_points(placements["U1S_A"].lands)
                  + _sorted_points(placements["U1S_B"].lands)) == parent_pads


def test_an_authored_anchor_is_an_override_and_only_that():
    """A child that names its drawing AND writes an anchor gets the anchor it
    wrote, recorded as ``authored`` -- composed through the same transform, so
    (0, 10) on the top-side parent at 180 lands 10 mm ABOVE the origin, not
    on the strip's body centre. Its lands are still the strip's."""
    def author(expansion):
        _children(expansion)[0]["anchor_mm"] = {"x": 0, "y": 10}
    placements = _placements(_compiled(_document(edit=author)))
    a, b = placements["U1S_A"], placements["U1S_B"]
    assert a.anchor_basis == ANCHOR_BASIS_AUTHORED
    assert _close(a.anchor, (56.43, 52.797))
    assert a.footprint_ref == STRIP and len(a.lands) == PINS
    assert b.anchor_basis == ANCHOR_BASIS_FAB
    assert _close(b.anchor, TOP_ANCHORS["U1S_B"])


#: U1S_A's anchor, in its own frame, that the composed 180 about A's origin
#: puts exactly on U1S_B's strip centre: (56.43 - 22.86, 62.797 - 26.67) =
#: (33.57, 36.127).
ANCHOR_ONTO_SIBLING = {"x": 22.86, "y": 26.67}
#: How far that is from A's OWN lands: A's row is the parent's pads at x 56.43,
#: 1.7 mm across, so its box starts at 55.58, and 55.58 - 33.57 = 22.01. The
#: box itself is that row's extent, (55.58, 8.607) .. (57.28, 63.647).
SIBLING_ANCHOR_DISTANCE_MM = 22.01
OWN_ROW_BOX = (55.58, 8.607, 57.28, 63.647)


def test_a_named_childs_authored_anchor_on_its_siblings_strip_is_refused(ledger):
    """A child that names its drawing is held to ITS OWN lands. An authored
    anchor that resolves onto the SIBLING's strip is inside the parent's
    44-pad box -- the approximation an unnamed child is tested against, which
    passes it -- and 22.01 mm off the row the child's own lands pick out, so
    the anchor gate refuses it by name, with the box it was tested against
    being that row and not the parent's."""
    def onto_sibling(expansion):
        _children(expansion)[0]["anchor_mm"] = ANCHOR_ONTO_SIBLING
    board = _compiled(_document(edit=onto_sibling))
    a = _placements(board)["U1S_A"]
    assert a.anchor_basis == ANCHOR_BASIS_AUTHORED
    assert a.footprint_ref == STRIP and len(a.lands) == PINS
    assert _close(a.anchor, TOP_ANCHORS["U1S_B"])

    # The parent's box, measured here off the resolved pads, contains it:
    # only the child's own row can tell this anchor is wrong.
    parent_box = ra.placed_land_extent(_component(board, "U1S").placed_pads)
    assert parent_box.min_x <= a.anchor[0] <= parent_box.max_x
    assert parent_box.min_y <= a.anchor[1] <= parent_box.max_y

    with pytest.raises(ag.AssemblyGateError) as raised:
        _emit(board, ledger)
    error = raised.value
    assert error.code == ag.CODE_ANCHOR_OFF_LANDS
    assert error.component == "U1S"
    assert error.field == "assembly.placements[].anchor_mm"
    assert error.refs == ("U1S_A",)

    message = str(error)
    named = TOP_ANCHORS["U1S_B"]
    assert f"({named[0]:.4f}, {named[1]:.4f})" in message
    assert f"{SIBLING_ANCHOR_DISTANCE_MM:.4f} mm outside" in message
    assert (f"({OWN_ROW_BOX[0]:.4f}, {OWN_ROW_BOX[1]:.4f}) to "
            f"({OWN_ROW_BOX[2]:.4f}, {OWN_ROW_BOX[3]:.4f})") in message
    # The sibling, whose anchor is measured, is not named.
    assert "'U1S_B'" not in message


# ---------------------------------------------------------------------------
# (c) + (d) The pad-subset gate, on both sides
# ---------------------------------------------------------------------------


def _turn(expansion):
    for child in _children(expansion):
        child["rotation_deg"] = DEFECT_ROTATION


def _shift_a_pitch(expansion):
    # One pitch ALONG the row, in the parent's frame: pads 1..21 land on the
    # row's pads 2..22 and pad 22 lands a pitch past its end.
    _children(expansion)[0]["offset_mm"] = {"x": -11.43, "y": PITCH}


def _shorter_strip(expansion):
    for child in _children(expansion):
        child["footprint"] = SHORTER_STRIP


def _both_on_one_strip(expansion):
    _children(expansion)[1]["offset_mm"] = {"x": -11.43, "y": 0}


@pytest.mark.parametrize("bottom", [False, True], ids=["top", "bottom"])
def test_the_gate_refuses_a_turned_shifted_or_wrong_length_child_and_passes_the_truth(
        bottom, ledger):
    """THE ORACLE THAT THE CHILD NAMES THE RIGHT DRAWING AND SITS RIGHT. The
    true placement emits; one key away, the same board refuses by name with
    the component, the field and the offending placement carried
    structurally:

    * a quarter turn puts pad 2 a pitch beside the row -- a SUBSET miss;
    * a one-pitch shift puts pad 22 a pitch past the row -- a SUBSET miss,
      reported with that distance;
    * a 1x07 strip sits entirely on the first seven pads of each row and
      leaves thirty unaccounted for -- a COVER miss, which the subset rule
      alone can never see;
    * both children on one row claim the same pads -- a DISJOINT miss.

    Every arm runs on both sides: a wrong bottom-side composition passes the
    defects or refuses the truth, and either is visible here."""
    good = _compiled(_document(bottom=bottom))
    emission = _emit(good, ledger)
    assert {"U1S_A", "U1S_B"} <= {row.ref for row in emission.cpl}
    assert not [r for r in emission.orientation_refusals
                if r.component in ("U1S_A", "U1S_B")]

    def refusal(edit):
        with pytest.raises(ag.AssemblyGateError) as raised:
            _emit(_compiled(_document(bottom=bottom, edit=edit)), ledger)
        error = raised.value
        assert error.code == ag.CODE_CHILD_LANDS_MISMATCH
        assert error.component == "U1S"
        return error

    turned = refusal(_turn)
    assert turned.field == "assembly.placements[].footprint"
    assert turned.refs == ("U1S_A",)
    assert "from the nearest pad" in str(turned)
    assert f"{DEFECT_DISTANCE_MM:.4f} mm from the nearest pad" in str(turned)

    shifted = refusal(_shift_a_pitch)
    assert shifted.refs == ("U1S_A",)
    assert f"{DEFECT_DISTANCE_MM:.4f} mm from the nearest pad" in str(shifted)
    # Pad 22, a pitch past the row's end: (56.43, 9.457 - 2.54) on top and
    # (56.43, 73.34 + 2.54) on the bottom.
    end = (56.43, 73.34 + PITCH) if bottom else (56.43, 9.457 - PITCH)
    assert f"({end[0]:.4f}, {end[1]:.4f}) mm" in str(shifted)

    shorter = refusal(_shorter_strip)
    assert shorter.field == "assembly.placements[].footprint"
    assert shorter.refs == ("U1S_A", "U1S_B")
    assert "account for only 14" in str(shorter) and "44 pads" in str(shorter)

    doubled = refusal(_both_on_one_strip)
    assert doubled.field == "assembly.placements[].offset_mm"
    assert doubled.refs == ("U1S_A", "U1S_B")


def test_a_child_that_names_no_drawing_leaves_the_cover_half_unasked():
    """With one child unnamed nothing is known about which pads are its, so
    only the named child is held to the copper -- and the unnamed one keeps
    exactly the parent-measured anchor it always had: the parent's fab box
    centre (0, 30.8485), composed to (33.57, 62.797 - 30.8485)."""
    def unname_b(expansion):
        del _children(expansion)[1]["footprint"]
    board = _compiled(_document(edit=unname_b))
    placements = _placements(board)
    assert placements["U1S_A"].footprint_ref == STRIP
    assert placements["U1S_B"].footprint_ref is None
    assert placements["U1S_B"].lands == ()
    assert placements["U1S_B"].anchor_basis == ANCHOR_BASIS_FAB
    assert _close(placements["U1S_B"].anchor, (33.57, 31.9485))
    ag.check_child_lands(board)  # passes: the cover half is not asked


def test_a_child_that_names_a_drawing_with_no_pads_is_refused_not_skipped(ledger):
    """A child that names a drawing is NAMED whether or not that drawing has
    pads. Read off its lands instead, a resolvable pad-less drawing (silk
    artwork) looks unnamed: with both children on it the gate skipped the
    component outright, and with one child on it the other's cover half went
    unasked. Both shapes refuse now, naming the pad-less placement and why."""
    def name_no_pads(*indices):
        def edit(expansion):
            for index in indices:
                _children(expansion)[index]["footprint"] = NO_PAD_DRAWING
        return edit

    # Both children: the compile resolves the drawing, so each child carries a
    # footprint_ref and no lands -- the shape that used to pass as unnamed.
    board = _compiled(_document(edit=name_no_pads(0, 1)))
    placements = _placements(board)
    for ref in ("U1S_A", "U1S_B"):
        assert placements[ref].footprint_ref == NO_PAD_DRAWING
        assert placements[ref].lands == ()
    with pytest.raises(ag.AssemblyGateError) as raised:
        ag.check_child_lands(board)
    error = raised.value
    assert error.code == ag.CODE_CHILD_LANDS_MISMATCH
    assert error.component == "U1S"
    assert error.field == "assembly.placements[].footprint"
    assert error.refs == ("U1S_A",)
    assert "draws no pads" in str(error) and NO_PAD_DRAWING in str(error)

    # Mixed: the strip child is fine on its own, and the pad-less sibling is
    # refused rather than silently excusing the strip from the cover half --
    # on the emission path, the way an order would meet it.
    with pytest.raises(ag.AssemblyGateError) as raised:
        _emit(_compiled(_document(edit=name_no_pads(1))), ledger)
    assert raised.value.code == ag.CODE_CHILD_LANDS_MISMATCH
    assert raised.value.refs == ("U1S_B",)
    assert "draws no pads" in str(raised.value)


# ---------------------------------------------------------------------------
# (e) What the house is sent
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bottom", [False, True], ids=["top", "bottom"])
def test_the_emission_orients_the_children_on_the_strip_pair(bottom, ledger):
    """THE CONSUMER, and the whole point. Each child's row is keyed on the
    STRIP and the catalogue number, so the ledger's row is found and applied;
    the only refusals left are the switches', on a pair nothing measured.

    The emitted rotation is checked against the DRAWINGS, not against the
    ledger's number: a machine reads the row's rotation against the vendor's
    drawing in the emitted frame -- Y negated, counter-clockwise positive, a
    bottom part mirrored in local Y before it turns (``assembly-outputs.md``)
    -- so the vendor's pad-1-to-pad-22 vector, put through that, must land on
    the direction the parent's copper row actually runs. That is a different
    derivation from the ledger's offset and from the emitter's sum, and it
    settles one angle per side. (It comes out at 90 on top and 270 on the
    bottom for this board; the two differ, which is the sign the bottom rule
    has to get right and a top-only test cannot see.)"""
    board = _compiled(_document(bottom=bottom))
    emission = _emit(board, ledger)
    rows = {row.ref: row for row in emission.cpl}
    placements = _placements(board)

    for ref in ("U1S_A", "U1S_B"):
        assert rows[ref].footprint_ref == STRIP
        assert rows[ref].house_part == PART
    assert {r.component for r in emission.orientation_refusals} == {
        "SW1", "SW2", "SW3", "SW4"}
    assert all(r.code == aor.CODE_UNKNOWN for r in emission.orientation_refusals)

    # The row's direction in the emitted frame, from the child's own placed
    # pads -- the same points the gate just proved are the parent's copper.
    vendor = _vendor_row_vector()
    pose0 = (vendor[0], vendor[1] if bottom else -vendor[1])
    for ref in ("U1S_A", "U1S_B"):
        first, last = placements[ref].lands[0], placements[ref].lands[-1]
        (fx, fy), (lx, ly) = ao.cpl_frame_point(first), ao.cpl_frame_point(last)
        expected = _the_one_angle(
            lambda angle: _parallel(_ccw_y_up(pose0, angle), (lx - fx, ly - fy)))
        assert rows[ref].rotation_deg == pytest.approx(expected)
        # Hand-derived: the row runs +y on top (pad 22 at 9.457, negated to
        # -9.457, above pad 1's -62.797) and -y on the bottom.
        assert (ly - fy > 0) != bottom
        # The correction was APPLIED: the row states an angle other than the
        # composed placement angle whenever the ledger's offset is a turn.
        if ledger.lookup(STRIP, HOUSE, PART).offset_deg % 360:
            assert rows[ref].rotation_deg != pytest.approx(placements[ref].rotation_deg)

    # The BOM buys two STRIPS, listed under the strip's own drawing.
    strips = [row for row in emission.bom if row.refs == ("U1S_A", "U1S_B")]
    assert len(strips) == 1
    assert strips[0].footprint == STRIP
    assert strips[0].part_number == PART and strips[0].qty == 2


# ---------------------------------------------------------------------------
# Compatibility and refusals at the reader
# ---------------------------------------------------------------------------


def test_a_child_that_names_no_drawing_behaves_exactly_as_before(ledger):
    """The sibling fixture -- the same socket set with hand anchors and no
    child footprints -- is unchanged by this feature: authored anchors, no
    own drawing, no lands, the parent's footprint on the rows and one grouped
    BOM line under the parent's drawing."""
    board = _compiled(yaml.safe_load(SIBLING_FIXTURE.read_text(encoding="utf-8")))
    placements = _placements(board)
    for ref in ("U1S_A", "U1S_B"):
        assert placements[ref].anchor_basis == ANCHOR_BASIS_AUTHORED
        assert placements[ref].footprint_ref is None
        assert placements[ref].lands == ()
    assert _close(placements["U1S_A"].anchor, (56.43, 36.127))
    emission = _emit(board, ledger)
    rows = {row.ref: row for row in emission.cpl}
    assert rows["U1S_A"].footprint_ref == PARENT
    assert [row.footprint for row in emission.bom
            if row.refs == ("U1S_A", "U1S_B")] == [PARENT]


def test_a_drawing_the_library_does_not_ship_refuses_at_compile_by_placement():
    """Naming a drawing is a library lookup, and it fails the way the parent's
    does -- ``footprint_unresolved`` -- naming the PLACEMENT so the author is
    not sent to look at the parent's footprint. A blank name refuses in the
    reader instead: falling through to the parent's drawing would quietly
    gate the part on the pair the author was trying to leave."""
    def unknown(expansion):
        _children(expansion)[0]["footprint"] = "Nowhere:NotAShippedDrawing"
    result = compile_board(_document(edit=unknown))
    assert isinstance(result, ResolutionFailure)
    errors = [d for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]
    assert [d.code for d in errors] == ["footprint_unresolved"]
    assert "'U1S_A'" in errors[0].message

    def blank(expansion):
        _children(expansion)[0]["footprint"] = "   "
    result = compile_board(_document(edit=blank))
    assert isinstance(result, ResolutionFailure)
    assert [d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR] == ["invalid_component_assembly"]
