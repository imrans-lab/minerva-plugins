"""The part-orientation correction on the emitted CPL, and the refusal that
stops an unmeasured part from shipping with a guessed rotation.

WHAT IS ACTUALLY BEING PROVED, and why it needs a particular fixture
--------------------------------------------------------------------
A pick-and-place machine reads the position file's rotation against the
VENDOR's canonical drawing of the part. Our footprint may be drawn turned
relative to that drawing, and the emitted rotation therefore has to carry the
measured offset between the two. The sum DEPENDS ON THE SIDE, because the
offset is a rotation of our drawing in the footprint's LOCAL frame and a bottom
placement mirrors that frame before rotating it::

    our_drawing = R(offset)·vendor              (part_orientation's convention)

    TOP     copper = R(placed)·our = R(placed + offset)·vendor
            machine puts R(emitted)·vendor   =>  emitted = placed + offset

    BOTTOM  copper = R(placed)·M·our = R(placed)·M·R(offset)·vendor
            and M·R(offset) = R(-offset)·M     (a mirror inverts a rotation)
                           = R(placed - offset)·M·vendor
            machine puts R(emitted)·M·vendor =>  emitted = placed - offset

The mirror does not cancel: it cancels for ``placed``, which is a BOARD-frame
angle, and inverts ``offset``, which is not. The same rule already governs an
expansion child's rotation in ``geometry.PlacementTransform.angle`` and in
``assembly_anchor`` — bottom subtracts.

THE TRAP THIS FILE IS BUILT AROUND. An inverted sign is INVISIBLE on every part
whose offset is 0 or 180, because ``R + 180`` and ``R - 180`` are the same
number modulo 360 — and seventeen of the twenty pairs the shipped ledger
has measured are exactly 0 or 180. A suite assembled only out of those passes with
the correction SUBTRACTING where it should add, or adding where it should
subtract, and ships every quarter-turn part a quarter turn out.

AND AN ASSERTION SPELLED AS THE CODE'S OWN EXPRESSION CANNOT FALSIFY EITHER
SIGN. ``assert emitted == (placed + offset) % 360`` re-runs the arithmetic
under test; it agrees with whatever the module does. So every side-sensitive
number below is a HAND-DERIVED LITERAL, with the numbers the mis-compositions
would have produced written down beside it.

So the fixture is built around two of the measured 270s — ``TSOT-23-6``/``C780769``
and ``VQFN-16-1EP_3x3mm``/``C910544`` — and two tests assert their emitted
numbers against the arithmetic AND against the value the opposite sign would
have produced. :func:`test_the_ledger_still_states_the_two_quarter_turns_this_suite_rests_on`
guards that premise: if either pair is ever re-measured to 0 or 180, this file
stops being able to falsify anything, and that must fail loudly rather than go
green.

THE ORACLES
-----------
* The SIGN — the composition above, worked through from
  ``part_orientation``'s stated convention (``offset_deg`` is the rotation
  carrying the vendor's drawing onto ours) and the emitted frame's own
  counter-clockwise-positive reading. Each assertion states both the number the
  addition gives and the number the subtraction would have given.
* The OFFSETS — the shipped ledger ``pcb/library/part_orientation.json``, read,
  not retyped. A hand-copied 270 here would drift the day the drawing changes.
* The FRAME — ``assembly_outputs.cpl_frame_point``, so the test that the
  correction did not disturb X/Y compares against the module's own map rather
  than a second copy of it.
* The REFUSALS — the three states ``orientation_ledger`` defines. UNKNOWN is an
  ABSENT row, which is why the unknown-part board names a catalogue number
  nothing has ever measured rather than writing a row that says "unknown".

Boards are SYNTHETIC and built from seed-library footprints; no product board
appears here (``test_corpus_policy.py`` enforces that by content).
"""

from __future__ import annotations

import json

from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_orientation as aor
from pcb_worker import assembly_outputs as ao
from pcb_worker import footprints
from pcb_worker import orientation_ledger as ol
from pcb_worker import part_orientation as po
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

BOARDS = Path(__file__).resolve().parent / "testdata" / "assembly_boards"
VENDOR = Path(__file__).resolve().parent / "testdata" / "vendor_footprints"
FIXTURE = BOARDS / "assembly_orientation.yaml"

HOUSE = "jlcpcb"

#: The two measured quarter turns the sign rests on, as
#: ``(footprint, catalogue number)``. Named here and checked against the
#: shipped ledger below; the ANGLES are never written down in this file.
QUARTER_TURN_PAIRS = (
    ("Package_TO_SOT_SMD:TSOT-23-6", "C780769"),
    ("Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.68x1.68mm", "C910544"),
)

#: THE ONE PLACE the fixture's emitted position file is written down. Every
#: number in it is the placed rotation plus the ledger's offset — the table in
#: the fixture's own header derives each row.
FIXTURE_CPL = (
    "Designator,Mid X,Mid Y,Layer,Rotation\r\n"
    "J1,12.6000,-22.0000,Top,270.0000\r\n"
    "R1,30.0000,-20.0000,Top,45.0000\r\n"
    "U1,8.0000,-8.0000,Top,300.0000\r\n"
    "U2,20.0000,-8.0000,Top,270.0000\r\n"
)


def _compiled(board: dict):
    """The board the emitters read. Fails LOUDLY rather than skipping: a
    fixture that stopped compiling would silently stop testing anything."""
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


@pytest.fixture(scope="module")
def fixture_board():
    return _compiled(yaml.safe_load(FIXTURE.read_text(encoding="utf-8")))


@pytest.fixture(scope="module")
def shipped() -> ol.OrientationLedger:
    return ol.load_ledger()


def _rows(board, *, orientation=None) -> dict:
    """``{ref: CplRow}`` for one emission, through the SHIPPING BOUNDARY.

    ``require_shippable`` rather than a bare ``emit`` on purpose: every caller
    of this helper is asserting that a board is emitted WITHOUT a refusal, and
    ``emit`` alone now carries its refusals instead of raising them. Reading
    the rows off the walk would let an accidental refusal pass unnoticed while
    the rotation assertion still held.
    """
    emission = ao.require_shippable(
        ao.emit(board, "jlc", orientation=orientation))
    return {row.ref: row for row in emission.cpl}


def _one_part_board(footprint: str, part: str | None, *,
                    rotation_deg: float = 30, layer: str = "top",
                    mpn: str = "C780769", populate: bool = True) -> dict:
    """A one-component board that compiles, for the cases that vary ONE fact.

    ``part`` is the house catalogue number — the half of the orientation key a
    board author writes. ``None`` authors none at all, which is the ungated
    shape."""
    assembly: dict = {"mpn": mpn, "populate": populate}
    if part is not None:
        assembly["house_parts"] = {HOUSE: part}
    return {
        "version": 1, "name": "OneOrientationPart",
        "width_mm": 20, "height_mm": 20, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{
            "ref": "U1", "footprint": footprint, "value": "part",
            "x_mm": 10.0, "y_mm": 10.0, "rotation_deg": rotation_deg,
            "layer": layer, "assembly": assembly,
        }],
    }


def _ledger(footprint: str, part: str, **row) -> ol.OrientationLedger:
    """A ledger holding exactly one MEASURED row for one pair.

    Built rather than loaded because the shipped ledger cannot hold the states
    these tests need to reach — an undecided measurement, and a pair-keyed
    no-reference — without somebody first buying a part that has them."""
    return ol.OrientationLedger(measured=(
        ol.OrientationRecord(footprint=footprint, house=HOUSE, part=part, **row),))


# ---------------------------------------------------------------------------
# THE PREMISE. Without this, nothing below can falsify the sign.
# ---------------------------------------------------------------------------


def test_the_ledger_still_states_the_two_quarter_turns_this_suite_rests_on(shipped):
    """The sign is only falsifiable by a 90 or a 270.

    Every other assertion in this file about the SIGN reads its offset from the
    ledger, so if these two pairs were ever re-measured to 0 or 180 the suite
    would keep passing while proving nothing — the exact failure the whole file
    is arranged against. Fail here instead, and say why."""
    for footprint, part in QUARTER_TURN_PAIRS:
        record = shipped.lookup(footprint, HOUSE, part)
        assert record is not None, (
            f"{footprint}/{part} has no ledger row; this suite needs it to "
            f"falsify the correction's SIGN")
        assert record.offset_deg in (90, 270), (
            f"{footprint}/{part} now measures {record.offset_deg}. Only a 90 or "
            f"a 270 can tell an added offset from a subtracted one — at 0 or "
            f"180 both signs emit the same number. Re-point this suite at a "
            f"pair that still turns a quarter, or it is no longer testing the "
            f"sign at all")


# ---------------------------------------------------------------------------
# THE SIGN
# ---------------------------------------------------------------------------


def test_a_quarter_turn_part_is_emitted_at_the_placed_rotation_plus_the_offset(
        fixture_board, shipped):
    """U1: our TSOT-23-6 drawing is a quarter turn off the vendor's, and the
    board places it at 30.

    The two candidate answers are 30 + 270 = 300 and 30 - 270 = -240 = 120, and
    they are different numbers — which is the whole reason this part is in the
    fixture. The addition is what the composition in the module docstring
    gives."""
    footprint, part = QUARTER_TURN_PAIRS[0]
    offset = shipped.lookup(footprint, HOUSE, part).offset_deg
    row = _rows(fixture_board)["U1"]
    placed = 30.0
    assert row.rotation_deg == pytest.approx((placed + offset) % 360)
    assert row.rotation_deg == pytest.approx(300.0)
    assert row.rotation_deg != pytest.approx((placed - offset) % 360), (
        "the emitted rotation is the SUBTRACTION of the measured offset; a "
        "part drawn a quarter turn off will be assembled a half turn from "
        "where it belongs")


def test_the_second_quarter_turn_part_confirms_the_sign_independently(
        fixture_board, shipped):
    """U2 is the same claim on a different package at a different placed angle.

    Its pad field is rotationally symmetric, so a wrong answer here is
    invisible in a 3D preview and there is no human check downstream — which is
    precisely why it is asserted in the file rather than looked at."""
    footprint, part = QUARTER_TURN_PAIRS[1]
    offset = shipped.lookup(footprint, HOUSE, part).offset_deg
    row = _rows(fixture_board)["U2"]
    placed = 0.0
    assert row.rotation_deg == pytest.approx((placed + offset) % 360)
    assert row.rotation_deg == pytest.approx(270.0)
    assert row.rotation_deg != pytest.approx((placed - offset) % 360)


#: The bottom-side oracle, DERIVED BY HAND from the composition in this file's
#: header and written down as literals — never as the expression the module
#: evaluates. Each row is ``(pair index, placed, expected, {name: what that
#: mis-composition would have emitted})``.
#:
#: Both pairs measure 270, and both placed angles are chosen so that all four
#: candidate compositions land on four DIFFERENT numbers. At a placed 0, 90 or
#: 180 two of them collide and the case stops separating them.
BOTTOM_CASES = (
    # TSOT-23-6/C780769, offset 270, placed 30:  30 - 270 = -240 = 120
    (0, 30.0, 120.0, {"placed + offset": 300.0,
                      "offset - placed": 240.0,
                      "-(placed + offset)": 60.0}),
    # VQFN-16/C910544, offset 270, placed 45:    45 - 270 = -225 = 135
    (1, 45.0, 135.0, {"placed + offset": 315.0,
                      "offset - placed": 225.0,
                      "-(placed + offset)": 45.0}),
)


@pytest.mark.parametrize("index,placed,expected,wrong", BOTTOM_CASES)
def test_a_bottom_side_quarter_turn_is_the_placed_rotation_MINUS_the_offset(
        shipped, index, placed, expected, wrong):
    """A bottom placement mirrors the footprint's local frame before rotating
    it, and a mirror conjugates a rotation into its inverse — so the LOCAL
    rotation the vendor offset is contributes with the opposite sign. The
    board-frame ``placed`` angle is unaffected; only the offset flips.

    The expected number is hand-derived and written as a literal, and every
    mis-composition's number is written beside it and asserted DIFFERENT. An
    assertion spelled ``(placed + offset) % 360`` would have been the module's
    own arithmetic and would have agreed with an inverted sign — which is how
    the addition survived on this side to begin with."""
    footprint, part = QUARTER_TURN_PAIRS[index]
    board = _compiled(_one_part_board(footprint, part, rotation_deg=placed,
                                      layer="bottom"))
    row = _rows(board)["U1"]
    assert row.side == "bottom"
    assert row.rotation_deg == pytest.approx(expected), (
        f"a bottom-side {footprint} placed at {placed} must be emitted at "
        f"{expected}; got {row.rotation_deg}")
    for name, number in wrong.items():
        assert row.rotation_deg != pytest.approx(number), (
            f"the emitted rotation is `{name}` — a part drawn a quarter turn "
            f"off the vendor's drawing will be assembled turned")


def test_the_two_sides_do_not_emit_the_same_number_for_the_same_placement(
        shipped):
    """THE PAIR THAT PROVES THE SIDE IS READ AT ALL.

    Same footprint, same catalogue number, same placed 30 — only the side
    differs. Top emits 300 and bottom emits 120, both hand-derived above. A
    module that ignored ``side`` would emit one number twice, and no single
    one-sided assertion can see that."""
    footprint, part = QUARTER_TURN_PAIRS[0]
    emitted = {}
    for layer in ("top", "bottom"):
        board = _compiled(_one_part_board(footprint, part, rotation_deg=30,
                                          layer=layer))
        emitted[layer] = _rows(board)["U1"].rotation_deg
    assert emitted["top"] == pytest.approx(300.0)
    assert emitted["bottom"] == pytest.approx(120.0)


def test_a_flat_offset_is_the_one_case_where_the_two_sides_agree():
    """The reason the sign hid for so long, pinned so it reads as a KNOWN
    blind spot rather than as evidence.

    At an offset of 0 both sides emit the placed angle, and at 180 both emit
    the same number because ``+180`` and ``-180`` are congruent mod 360.
    Seventeen of the twenty measured pairs are exactly 0 or 180, so a corpus
    built only out of them proves nothing about the side at all."""
    for offset in (0, 180):
        assert (aor.corrected_rotation(30, offset, aor.SIDE_TOP)
                == pytest.approx(aor.corrected_rotation(30, offset,
                                                        aor.SIDE_BOTTOM)))
    assert aor.corrected_rotation(30, 90, aor.SIDE_TOP) == pytest.approx(120.0)
    assert aor.corrected_rotation(30, 90, aor.SIDE_BOTTOM) == pytest.approx(300.0)


def test_the_correction_refuses_a_side_it_does_not_recognise():
    """``side`` is required and checked rather than defaulted. A caller that
    lost track of which side it holds must stop, not silently take the top
    rule — that default is the half-turn this module exists to prevent."""
    with pytest.raises(ValueError) as excinfo:
        aor.corrected_rotation(30, 270, "Bottom")
    assert "side" in str(excinfo.value)


def test_the_sum_wraps_rather_than_running_past_a_full_turn():
    """``corrected_rotation`` is the ONE place either sign is written, and the
    emitted angle stays in [0, 360) the way ``PhysicalPlacement`` guarantees
    the placed one does — so a corrected row is indistinguishable in shape from
    an uncorrected one."""
    assert aor.corrected_rotation(180, 270, aor.SIDE_TOP) == pytest.approx(90.0)
    assert aor.corrected_rotation(0, 0, aor.SIDE_TOP) == pytest.approx(0.0)
    assert 0.0 <= aor.corrected_rotation(359.5, 270, aor.SIDE_TOP) < 360.0
    # The bottom rule underflows instead of overflowing, and wraps the same way.
    assert aor.corrected_rotation(30, 270, aor.SIDE_BOTTOM) == pytest.approx(120.0)
    assert 0.0 <= aor.corrected_rotation(0.5, 270, aor.SIDE_BOTTOM) < 360.0


# ---------------------------------------------------------------------------
# THE WHOLE FILE
# ---------------------------------------------------------------------------


def test_the_position_file_is_the_hand_derived_bytes(fixture_board):
    """The seal. Every row is derived in the fixture's own header table, and
    the bytes are asserted through the RENDERER — a correction that only
    reached the row objects and not the CSV would be a correction nobody
    ships."""
    package = ao.build_package(fixture_board, "jlc")
    assert package.files[package.cpl_file] == FIXTURE_CPL


def test_the_correction_moves_the_rotation_and_nothing_else(fixture_board):
    """The frame contract is untouched. X is the anchor's X verbatim and Y is
    its Y negated, compared against ``assembly_outputs``' own map rather than a
    second copy of it, for the part whose rotation moved the most."""
    board = fixture_board
    anchor = {c.ref: c.physical_placements[0].anchor for c in board.components}["U1"]
    row = _rows(board)["U1"]
    assert (row.x_mm, row.y_mm) == ao.cpl_frame_point(anchor)


def test_a_measured_zero_is_applied_as_a_zero(fixture_board, shipped):
    """R1's pair was measured and the answer was 0. A measured zero is a fact,
    not an absence: the row must be found, and the emitted rotation must be the
    placed one — which is also what an UNMEASURED part would have emitted, and
    is why the two states can never be allowed to collapse into one."""
    record = shipped.lookup("Resistor_SMD:R_0805_2012Metric", HOUSE, "C149504")
    assert record.offset_deg == 0
    assert ol.state_of(record) == ol.STATE_MEASURED
    assert _rows(fixture_board)["R1"].rotation_deg == pytest.approx(45.0)


# ---------------------------------------------------------------------------
# THE REFUSAL
# ---------------------------------------------------------------------------


def test_an_unmeasured_catalogue_part_refuses_by_name(shipped):
    """UNKNOWN is an ABSENT row, and it must stop the file.

    The board buys a real seed footprint under a catalogue number nothing has
    ever measured. Emitting the placed rotation here is the defect this unit
    exists to close, so the refusal names the component, the pair and the
    field, the way every other assembly refusal does."""
    footprint = QUARTER_TURN_PAIRS[0][0]
    unmeasured = "C000000"
    assert shipped.lookup(footprint, HOUSE, unmeasured) is None
    board = _compiled(_one_part_board(footprint, unmeasured))
    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.build_cpl(board, "jlc")
    error = excinfo.value
    assert error.code == aor.CODE_UNKNOWN
    assert error.component == "U1"
    assert error.field == aor.FIELD_HOUSE_PARTS
    assert unmeasured in str(error) and footprint in str(error)


def test_the_refusal_reaches_the_bom_and_the_whole_order_package_too(shipped):
    """ONE EMISSION, so a caller asking for only the BOM refuses as well.

    That is not pedantry: the BOM and the CPL are ordered together, and a house
    that receives a buyable BOM whose CPL was refused has been told to buy
    parts nobody could place correctly."""
    board = _compiled(_one_part_board(QUARTER_TURN_PAIRS[0][0], "C000000"))
    for build in (ao.build_bom, ao.build_cpl, ao.build_package):
        with pytest.raises(aor.AssemblyOrientationError) as excinfo:
            build(board, "jlc")
        assert excinfo.value.code == aor.CODE_UNKNOWN


#: The MISPAIRING the corpus can reproduce: our 1206 fuse land against C49678,
#: an 0805 capacitor. Both are two-pad chips drawn the same way up, so the
#: ANGLE comes out decided — and the lands sit 0.4 mm apart per pad, because it
#: is a different part. This is the shape of a BOM with the wrong catalogue
#: number in it, and it is measured here rather than typed so the refusal is
#: pinned to a real measurement and not to a fixture's opinion of one.
MISPAIRED = ("Fuse:Fuse_1206_3216Metric", "C49678")


def test_a_geometry_mismatch_refuses_instead_of_trusting_its_own_angle():
    """A DECIDED angle between our drawing and a drawing of SOMETHING ELSE.

    ``geometry_mismatch`` is the verdict that says "these are not the same land
    pattern, so check the part number before trusting the pairing", and it
    still carries an offset — deliberately, because the angle and the land test
    are two axes and a wrong land tolerance must not destroy a correct angle.
    That offset is nevertheless the angle to a part we are not buying. Applying
    it would take a mispairing the measurement DETECTED and promote it into a
    trusted production rotation, which is strictly worse than the unmeasured
    pair this module was written for: there, nobody claimed to know.

    So the row stays in the ledger for a reader, and the ORDER stops.
    """
    footprint, part = MISPAIRED
    payload = json.loads((VENDOR / f"{part}.json").read_text(encoding="utf-8"))
    measurement = po.measure_footprint_against_part(
        footprints.resolve_footprint(footprint), payload, lcsc=part)
    assert measurement.verdict == po.VERDICT_GEOMETRY_MISMATCH
    assert measurement.lands_agree is False
    assert measurement.offset_deg is not None, (
        "the premise: this verdict CARRIES an offset, which is what makes it "
        "reachable by the emitter at all")

    ledger = ol.OrientationLedger(measured=(ol.record_from_measurement(
        footprint, HOUSE, part, measurement,
        footprint_sha256="ab" * 32, vendor_sha256="cd" * 32),))
    record = ledger.lookup(footprint, HOUSE, part)
    assert ol.state_of(record) == ol.STATE_MEASURED
    assert record.offset_deg is not None

    board = _compiled(_one_part_board(footprint, part))
    for build in (ao.build_cpl, ao.build_bom, ao.build_package):
        with pytest.raises(aor.AssemblyOrientationError) as excinfo:
            build(board, "jlc", orientation=ledger)
        assert excinfo.value.code == aor.CODE_MISMATCH
    error = excinfo.value
    assert error.component == "U1"
    assert error.field == aor.FIELD_HOUSE_PARTS
    assert part in str(error) and footprint in str(error)


def test_a_mismatched_quarter_turn_never_reaches_the_position_file():
    """The same refusal where the number it would have written is VISIBLE.

    The measured mispairing above happens to come out at 0, so letting it
    through would have changed no digit — the defect there is the trust, not
    the arithmetic. This row states 90 beside the same disagreeing lands, which
    is what a mispairing between two differently-drawn packages looks like, and
    it must not turn the part a quarter of the way round on the strength of a
    comparison against the wrong drawing.
    """
    footprint, part = QUARTER_TURN_PAIRS[0]
    ledger = _ledger(footprint, part, verdict=po.VERDICT_GEOMETRY_MISMATCH,
                     offset_deg=90, angle_decided=True, lands_agree=False,
                     residual_mm=0.4, max_pad_error_mm=0.5,
                     detail="the angle is settled at 90 deg, and the shared "
                            "pads still sit 0.400 mm RMS apart")
    board = _compiled(_one_part_board(footprint, part, rotation_deg=30))
    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.build_cpl(board, "jlc", orientation=ledger)
    assert excinfo.value.code == aor.CODE_MISMATCH


def test_an_undecided_geometry_mismatch_refuses_on_the_land_axis(shipped):
    """A MISMATCH REFUSES AS A MISMATCH EVEN WHEN NO ANGLE CAME OUT.

    Two facts at once: the pads do not sit on top of each other at ANY angle,
    and no angle separated itself from its runner-up either. That is what a
    symmetric part paired with the wrong catalogue number looks like.

    WHICH REFUSAL IS THE POINT, not merely that one happens. Routed on
    ``offset_deg is None`` this lands on ``undecided``, whose sentence tells
    the reader to re-measure the pair — sending them to a symmetry problem when
    the pair is a wrong catalogue number. A refusal that misdirects its reader
    is worse than a terse one, so the LAND axis is asked first and this refuses
    as :data:`CODE_MISMATCH`, naming the part number as the first check.

    Every builder is asserted inside the loop: an assertion after it only ever
    sees the last builder's message.
    """
    footprint, part = QUARTER_TURN_PAIRS[0]
    detail = ("every candidate angle leaves the shared pads ~0.9 mm apart, and "
              "none of them separates from its runner-up")
    ledger = _ledger(footprint, part, verdict=po.VERDICT_GEOMETRY_MISMATCH,
                     offset_deg=None, angle_decided=False, lands_agree=False,
                     residual_mm=0.9, max_pad_error_mm=1.4, detail=detail)
    board = _compiled(_one_part_board(footprint, part, rotation_deg=30))
    for build in (ao.build_bom, ao.build_cpl, ao.build_package):
        with pytest.raises(aor.AssemblyOrientationError) as excinfo:
            build(board, "jlc", orientation=ledger)
        name = build.__name__
        assert excinfo.value.code == aor.CODE_MISMATCH, name
        message = str(excinfo.value)
        assert po.VERDICT_GEOMETRY_MISMATCH in message, name
        assert detail in message, name
        # The sentence a mismatch exists to say, and the one it must NOT say.
        assert "catalogue" in message, name
        assert "Re-measure the pair" not in message, name


def test_an_undecided_measurement_refuses_rather_than_emitting_the_placed_angle():
    """We looked, and the drawings did not separate the angles.

    ``orientation_ledger`` stores that as a MEASURED row with no offset — a
    state distinct from both "aligned" and "never looked at" — and a gate must
    refuse it on ``offset_deg is None`` rather than on the state, because a
    decided ``geometry_mismatch`` still carries a usable angle."""
    footprint, part = QUARTER_TURN_PAIRS[0]
    board = _compiled(_one_part_board(footprint, part))
    ledger = _ledger(footprint, part, verdict=po.VERDICT_AMBIGUOUS,
                     offset_deg=None, angle_decided=False,
                     detail="0 and 180 fit within the separation floor")
    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.build_cpl(board, "jlc", orientation=ledger)
    assert excinfo.value.code == aor.CODE_UNDECIDED
    assert excinfo.value.component == "U1"


# ---------------------------------------------------------------------------
# WHAT MUST NOT REFUSE
# ---------------------------------------------------------------------------


def test_a_part_with_no_vendor_drawing_is_emitted_verbatim(shipped):
    """NO_REFERENCE is not a failure to measure — it is the finding that there
    is nothing to measure AGAINST. There is no correction to apply and there
    never will be, so the placed rotation is emitted exactly as it was before
    this step existed."""
    footprint, part = QUARTER_TURN_PAIRS[0]
    board = _compiled(_one_part_board(footprint, part, rotation_deg=30))
    ledger = _ledger(footprint, part, verdict=po.VERDICT_NO_REFERENCE,
                     detail="the vendor payload carries no package drawing")
    row = _rows(board, orientation=ledger)["U1"]
    assert ol.state_of(ledger.lookup(footprint, HOUSE, part)) == ol.STATE_NO_REFERENCE
    assert row.rotation_deg == pytest.approx(30.0)


def test_a_footprint_wide_declaration_answers_for_whatever_is_bought_against_it():
    """A mounting hole has no vendor drawing for ANY part, so its declaration
    is keyed on the footprint alone and the pair lookup falls back to it.

    Safe in one direction only, and it is the safe one: a footprint-wide row is
    validated to be a declared no-reference carrying no numbers, so the
    fallback can never substitute an offset for a measurement."""
    footprint = "MountingHole:MountingHole_3.2mm_M3"
    board = _compiled(_one_part_board(footprint, "C000000", rotation_deg=30,
                                      mpn="C000000"))
    declared = ol.OrientationLedger(declared=(
        ol.OrientationRecord(footprint=footprint, house=None, part=None,
                             verdict=po.VERDICT_NO_REFERENCE, declared=True,
                             reason="a plated hole, not a part"),))
    assert _rows(board, orientation=declared)["U1"].rotation_deg == pytest.approx(30.0)


def test_board_furniture_never_reaches_the_gate(fixture_board):
    """FID1 is fabricated copper nobody buys: not populated, no catalogue
    number, no CPL row. It must not be asked for an orientation it could never
    have — a gate that refused it would refuse every board with a fiducial."""
    assert "FID1" not in _rows(fixture_board)
    assert "FID1" in ao.emit(fixture_board, "jlc").excluded_refs


def test_a_part_identified_only_by_mpn_is_not_gated(shipped):
    """A STATED GAP, asserted so it is a decision and not an oversight.

    The orientation key's second half is a HOUSE catalogue number, because that
    is what the ledger is keyed on and what the measurement corpus pairs. A
    board that names only ``assembly.mpn`` — a MANUFACTURER's number — offers
    nothing to join on, and inventing that join would be inventing exactly the
    loose key the ledger refuses to have. Such a part is bought and placed and
    is NOT corrected; closing that is a board-schema question, tracked
    separately."""
    footprint = QUARTER_TURN_PAIRS[0][0]
    board = _compiled(_one_part_board(footprint, None, rotation_deg=30,
                                      mpn="C000000"))
    row = _rows(board)["U1"]
    assert row.house_part is None
    assert row.rotation_deg == pytest.approx(30.0)


# ---------------------------------------------------------------------------
# THE SHIPPING BOUNDARY — which artifacts the refusal is spent at
# ---------------------------------------------------------------------------


def test_the_walk_carries_the_refusal_instead_of_raising_it(shipped):
    """``emit`` is the WALK, not an artifact, and it no longer refuses.

    Every order artifact is built from one emission, and so are the things
    nobody orders: the local assembly preview, the anchor checks, the paste
    matrix. Refusing inside the walk put an order-time stop in front of all of
    them. The refusal now rides on the emission and is spent by
    ``require_shippable`` at each file-producing entry point.

    THE ROW IS NOT A RESULT. Its rotation comes back as the PLACED angle, the
    uncorrected number — which is exactly why the refusal must travel with it
    and why every artifact that leaves this machine spends it. Both halves are
    asserted here: an emission that came back quietly with a corrected-looking
    number and no refusal would be the silent zero this whole unit exists to
    stop.
    """
    footprint, part = QUARTER_TURN_PAIRS[0]
    unmeasured = "C000000"
    assert shipped.lookup(footprint, HOUSE, unmeasured) is None
    board = _compiled(_one_part_board(footprint, unmeasured, rotation_deg=30))

    emission = ao.emit(board, "jlc")
    assert len(emission.orientation_refusals) == 1
    refusal = emission.orientation_refusals[0]
    assert refusal.code == aor.CODE_UNKNOWN and refusal.component == "U1"
    assert {row.ref: row.rotation_deg for row in emission.cpl}["U1"] == pytest.approx(30.0)

    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.require_shippable(emission)
    assert excinfo.value is refusal


def test_every_artifact_a_board_house_can_act_on_refuses(shipped):
    """THE SET, ENUMERATED. These four are everything this worker hands out as
    order data — the BOM CSV, the position file, the pair, and the order
    package envelope that carries all of them plus the gerbers.

    Each is asserted separately rather than through the one they share, because
    the claim under test is about the BOUNDARY: delete ``require_shippable``
    from any single entry point and exactly that call stops raising while the
    others still do, so a hole cannot hide behind its neighbours.

    The BOM is in this set on purpose even though it has no rotation column;
    why it belongs there is stated at ``assembly_outputs.require_shippable``,
    and the consequence is pinned by the column assertion below.
    """
    from pcb_worker import order_package as op

    source = _one_part_board(QUARTER_TURN_PAIRS[0][0], "C000000")
    board = _compiled(source)
    builders = (
        ("build_bom", lambda: ao.build_bom(board, "jlc")),
        ("build_cpl", lambda: ao.build_cpl(board, "jlc")),
        ("build_package", lambda: ao.build_package(board, "jlc")),
        ("order_package.build", lambda: op.build(source, board, "jlc")),
    )
    for name, build in builders:
        with pytest.raises(aor.AssemblyOrientationError) as excinfo:
            build()
        assert excinfo.value.code == aor.CODE_UNKNOWN, name
        assert excinfo.value.component == "U1", name


def test_the_bom_states_no_rotation_anywhere(fixture_board):
    """WHY THE BOM'S PLACE IN THAT SET IS OVER-REFUSAL, PINNED SO IT STAYS SO.

    The BOM is refused for an unmeasured rotation even though it cannot
    express one: its row carries designators, comment, footprint and part
    numbers, and its emitted columns carry no rotation, side or coordinate.
    That is a deliberate over-refusal, and this is the assertion that keeps the
    reasoning honest — the day a rotation column appears in the BOM the comment
    justifying the refusal becomes wrong, and this test says so out loud rather
    than letting the refusal quietly become load-bearing for a reason nobody
    re-checked.
    """
    result = ao.build_bom(fixture_board, "jlc")
    profile = ao.emit(fixture_board, "jlc").profile
    fields = set(ao.BomRow.__dataclass_fields__)
    assert "rotation_deg" not in fields and "side" not in fields
    assert not (fields & {"x_mm", "y_mm"})
    for column in profile.bom_columns:
        assert "rotation" not in column.lower(), column
    # And the emitted bytes: the CPL's rotations are hand-derived in
    # FIXTURE_CPL, so a BOM that leaked one would show it here.
    text = next(iter(result.values()))
    for line in FIXTURE_CPL.splitlines()[1:]:
        assert line.split(",")[-1] not in text
