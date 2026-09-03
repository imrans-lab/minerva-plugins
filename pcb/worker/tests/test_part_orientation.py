"""Is our footprint drawn the same way round as the vendor's part?

WHAT THIS SUITE IS FOR
----------------------
``pcb_worker.part_orientation`` measures the rotation between OUR seed
footprint and the VENDOR's canonical drawing of the part we buy against it.
The consequence of getting that wrong is not a warning in a log: the
pick-and-place rotation is interpreted against the vendor's drawing, so a
footprint drawn 180 out ships a board with the connector facing backwards, and
every other check in the pipeline passes while it happens.

So this suite is not "does the function return a float". It is the record of
twenty MEASURED (seed footprint, LCSC part) pairs, and it fails the moment a
library edit, a re-fetched payload, or a sign flip in the maths moves one of
them.

THE ORACLE AND WHERE IT CAME FROM
---------------------------------
:data:`ORACLE` below is the offset for each pair. Three of the twenty —
``C265102``, ``C265104``, ``C780769`` — were read by a human off a board
house's 3D preview of an assembled board BEFORE any of these numbers were
computed, so the table is not the code grading its own homework; the rest were
measured and then checked against the same convention.

Those three are also what pins the SIGN. Offsets of 0 and 180 are unchanged by
inverting the rotation sense, so a flipped sign is invisible on seventeen of
the twenty pairs and turns 270 into 90 on only the other THREE —
:func:`test_the_rotation_sense_is_pinned_by_the_human_confirmed_pairs` is the
test that would catch it.

OFFLINE BY CONSTRUCTION
-----------------------
Vendor payloads are committed under ``testdata/vendor_footprints/`` (see the
README there for the trim and its provenance). Nothing here touches the
network; nothing here reads the ephemeral fetch cache. Our side of every
comparison is the real seed library, resolved through the real lockfile, so an
edit to a seed footprint's orientation shows up here rather than at the board
house.
"""

from __future__ import annotations

import json
import math

from pathlib import Path

import pytest

from pcb_worker import footprints
from pcb_worker import part_orientation as po

HERE = Path(__file__).resolve().parent
VENDOR_DIR = HERE / "testdata" / "vendor_footprints"

#: (seed footprint ref, LCSC part) pairs. Kept in the fixture directory rather
#: than here so the payloads and the pairing they belong to travel together.
INDEX = json.loads((VENDOR_DIR / "index.json").read_text(encoding="utf-8"))

#: The measurement, per LCSC part: the COUNTER-CLOCKWISE rotation carrying the
#: vendor's drawing onto ours. See the module docstring on provenance.
ORACLE = {
    # Chip and fuse lands — drawn the same way round by both.
    "C49678": 0,      # C_0805_2012Metric
    "C15850": 0,      # C_0805_2012Metric
    "C98190": 0,      # C_0805_2012Metric
    "C170182": 0,     # C_1206_3216Metric
    "C6120014": 0,    # C_1210_3225Metric
    "C394395": 0,     # C_1210_3225Metric — Taiyo Yuden 100u, the C6120014 stock substitute
    "C149504": 0,     # R_0805_2012Metric
    "C17414": 0,      # R_0805_2012Metric
    "C17616": 0,      # R_0805_2012Metric
    "C2803346": 0,    # Fuse_1206_3216Metric
    "C17888": 0,      # Fuse_1206_3216Metric — a 0R resistor on the fuse land
    "C2846183": 0,    # L_Sunlord_AMWPH4018 4x4x1.8mm
    "C295747": 0,     # JST_PH_S2B-PH-SM4-TB 1x02
    "C161861": 0,     # JST_XH_S4B-XH-SM4-TB 1x04
    # Drawn half a turn from the vendor.
    "C265102": 180,   # JST_PH_S4B-PH-SM4-TB 1x04  <- human-confirmed
    "C265104": 180,   # JST_PH_S5B-PH-SM4-TB 1x05  <- human-confirmed
    "C15127": 180,    # SOT-23
    "C5159510": 180,  # SPK0641HT4H-1 LGA-8
    # Drawn a quarter turn from the vendor.
    "C780769": 270,   # TSOT-23-6                  <- human-confirmed
    "C910544": 270,   # VQFN-16-1EP 3x3mm
    # The vendor draws the socket strip's row along +X; ours runs +Y. The
    # same number is re-derived from those two directions, without this
    # module, in test_assembly_child_footprint.py.
    "C41376161": 270, # PinSocket_1x22 HC-PM254-8.5H
    # 2-terminal tactile switch — datasheet land pattern, pads numbered 1/2 as the vendor drawing does.
    "C4365033": 0,    # EVP-ASAC1A:SW_EVP-ASAC1A
}

#: The subset a person verified against a physical rendering of an assembled
#: board, independently of this code.
HUMAN_CONFIRMED = ("C265102", "C265104", "C780769")


def _payload(lcsc: str) -> dict:
    return json.loads((VENDOR_DIR / f"{lcsc}.json").read_text(encoding="utf-8"))


def _measure(lcsc: str) -> po.OrientationMeasurement:
    parsed = footprints.resolve_footprint(INDEX[lcsc]["footprint"])
    return po.measure_footprint_against_part(parsed, _payload(lcsc), lcsc=lcsc)


def _repad(payload: dict, renumber) -> dict:
    """Copy ``payload`` with every PAD record's NUMBER passed through
    ``renumber``. Positions are untouched — which is the whole point: it
    produces a drawing that is geometrically identical and numbered
    differently."""
    payload = json.loads(json.dumps(payload))
    shapes = payload["result"]["packageDetail"]["dataStr"]["shape"]
    out = []
    for record in shapes:
        if record.startswith("PAD~"):
            fields = record.split("~")
            fields[po._PAD_NUMBER] = renumber(fields[po._PAD_NUMBER])
            record = "~".join(fields)
        out.append(record)
    payload["result"]["packageDetail"]["dataStr"]["shape"] = out
    return payload


# ---------------------------------------------------------------------------
# The unit the vendor draws in — derived, not assumed
# ---------------------------------------------------------------------------


def test_the_vendor_unit_is_rederived_from_pitches_we_already_know():
    """``VENDOR_UNIT_MM`` is 10 mil. That was a BELIEF about EasyEDA's canvas
    when this module was written, and a wrong scale would not fail loudly — it
    would shrink or stretch every residual and quietly move the land verdict,
    while leaving all twenty ANGLES correct (a rotation is scale-free). So the
    constant is checked against pitches the datasheets state: JST PH is 2.00 mm,
    JST XH is 2.50 mm, and the VQFN-16 is 0.50 mm.
    """
    expected = {"C265102": 2.00, "C265104": 2.00, "C295747": 2.00,
                "C161861": 2.50, "C910544": 0.50}
    for lcsc, pitch in expected.items():
        vendor = po.parse_vendor_payload(_payload(lcsc), lcsc=lcsc)
        centres = vendor.pads.centres
        numbered = sorted((n for n in centres if n.isdigit()), key=int)
        # Consecutive numbered pads on a connector/QFN are one pitch apart;
        # taking the MINIMUM adjacent spacing skips the jump from the last
        # signal pin to a mounting tab or a thermal pad.
        spacings = [math.dist(centres[a], centres[b])
                    for a, b in zip(numbered, numbered[1:])]
        assert min(spacings) == pytest.approx(pitch, abs=0.002), (
            f"{lcsc}: closest numbered-pad spacing {min(spacings):.4f} mm is "
            f"not the datasheet pitch {pitch} mm — VENDOR_UNIT_MM "
            f"({po.VENDOR_UNIT_MM}) no longer describes the payload")


# ---------------------------------------------------------------------------
# The oracle
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("lcsc", sorted(ORACLE))
def test_every_seed_pair_measures_its_oracle_offset(lcsc):
    measured = _measure(lcsc)
    assert measured.angle_decided, (
        f"{lcsc} ({INDEX[lcsc]['footprint']}): no angle could be decided — "
        f"{measured.detail}")
    assert measured.offset_deg == ORACLE[lcsc], (
        f"{lcsc} ({INDEX[lcsc]['footprint']}): measured {measured.offset_deg} "
        f"deg, oracle says {ORACLE[lcsc]} deg — {measured.detail}")


@pytest.mark.parametrize("lcsc", sorted(ORACLE))
def test_every_seed_pair_reports_the_expected_verdict(lcsc):
    """A decided angle of 0 is ``aligned``; anything else is ``rotated``. No
    seed pair is allowed to land on ``geometry_mismatch``: these ARE the parts
    we buy for these footprints, so a land disagreement here is a real defect
    in the library, not a tolerance to widen."""
    measured = _measure(lcsc)
    expected = (po.VERDICT_ALIGNED if ORACLE[lcsc] == 0
                else po.VERDICT_ROTATED)
    assert measured.verdict == expected, measured.detail
    assert measured.lands_agree is True, measured.detail


def test_the_rotation_sense_is_pinned_by_the_human_confirmed_pairs():
    """THE SIGN TEST. Inverting the rotation sense leaves 0 and 180 alone and
    swaps 90 with 270, so it is invisible on seventeen of the twenty pairs. These
    three are the ones a person checked against a board house's 3D preview
    before the code existed, and ``C780769`` is the one whose value is neither
    0 nor 180 — it is the only thing here that can tell a correct convention
    from its mirror.
    """
    for lcsc in HUMAN_CONFIRMED:
        assert _measure(lcsc).offset_deg == ORACLE[lcsc]

    inverted = (360 - ORACLE["C780769"]) % 360
    assert inverted != ORACLE["C780769"], (
        "C780769's oracle stopped being sign-sensitive, so this suite no "
        "longer detects an inverted rotation convention; pin the sense on a "
        "different 90/270 pair before relaxing this")


# ---------------------------------------------------------------------------
# The load-bearing constraint: pad NUMBERS, not pad positions
# ---------------------------------------------------------------------------


def test_a_symmetric_pad_field_cannot_be_oriented_by_positions_alone():
    """The premise behind the pad-number anchor, stated as a measurement.

    The 0805 vendor drawing's pad CENTRES map exactly onto themselves under a
    half turn. Any matcher that works from positions — nearest neighbour, a
    shape hash, ICP — therefore scores 0 and 180 identically and has no way to
    choose. It is not a weak signal; it is no signal.
    """
    centres = po.parse_vendor_payload(_payload("C49678")).pads.centres
    points = list(centres.values())
    origin = po._centroid(points)
    centred = sorted((round(x - origin[0], 6), round(y - origin[1], 6))
                     for x, y in points)
    turned = sorted(
        tuple(round(v, 6) for v in po.rotate_ccw((x - origin[0],
                                                  y - origin[1]), 180))
        for x, y in points)
    assert turned == centred


def test_swapping_two_pad_numbers_flips_the_verdict_by_half_a_turn():
    """...and this is the anchor doing its job on that same drawing.

    Nothing moves. Only the labels on the two 0805 lands are exchanged, which
    IS a half turn of the part. A position-only matcher sees an identical
    drawing and keeps saying 0; the number-anchored measurement says 180.
    """
    swapped = _repad(_payload("C49678"),
                     lambda n: {"1": "2", "2": "1"}.get(n, n))
    parsed = footprints.resolve_footprint(INDEX["C49678"]["footprint"])
    measured = po.measure_footprint_against_part(parsed, swapped,
                                                 lcsc="C49678")
    assert ORACLE["C49678"] == 0, "this test reads against the unswapped oracle"
    assert measured.offset_deg == 180, measured.detail
    assert measured.verdict == po.VERDICT_ROTATED


def test_rotating_a_quad_packages_numbering_rotates_the_measured_offset():
    """The same argument on the package where the symmetry is four-fold.

    Advancing the VQFN-16's pin numbering by one side (four pins) is a quarter
    turn of the part. The pad positions are untouched, so the measured offset
    must move by exactly one quadrant — 270 becomes 0.
    """
    stepped = _repad(
        _payload("C910544"),
        lambda n: (str((int(n) - 1 + 4) % 16 + 1)
                   if n.isdigit() and 1 <= int(n) <= 16 else n))
    parsed = footprints.resolve_footprint(INDEX["C910544"]["footprint"])
    measured = po.measure_footprint_against_part(parsed, stepped,
                                                 lcsc="C910544")
    assert ORACLE["C910544"] == 270
    assert measured.offset_deg == (ORACLE["C910544"] + 90) % 360, measured.detail


def test_a_number_appearing_twice_is_dropped_rather_than_guessed():
    """Our JST horizontals call BOTH mechanical tabs ``MP``. There is no honest
    way to say which vendor pad each one is, so ``MP`` leaves the comparison
    and is reported — rather than being paired arbitrarily and contributing a
    fabricated residual."""
    measured = _measure("C265102")
    assert "MP" in measured.duplicate_numbers
    assert "MP" not in measured.matched_pads
    # The vendor numbers its tabs 5 and 6; unmatched on both sides is normal
    # and must not stop the four signal pins from deciding the angle.
    assert measured.vendor_only == ("5", "6")
    assert measured.matched_pads == ("1", "2", "3", "4")


# ---------------------------------------------------------------------------
# The two axes: which angle, and whether the lands agree
# ---------------------------------------------------------------------------


def test_a_land_size_difference_does_not_cost_us_the_rotation_verdict():
    """SOT-23/C15127 is the trap. The vendor's land sits at x = +/-1.150 mm and
    KiCad's IPC land at +/-0.9375 mm, so the best fit leaves a real 0.28 mm on
    the worst pad. That is a LAND-SIZE difference with the orientation never in
    doubt — the runner-up angle is nearly nine times worse. A single tight
    residual threshold reports "different geometry" here and throws the 180
    away, which is the one thing this pair exists to prevent.
    """
    measured = _measure("C15127")
    assert measured.offset_deg == 180
    assert measured.verdict == po.VERDICT_ROTATED
    assert measured.max_pad_error_mm == pytest.approx(0.283, abs=0.005)
    assert measured.residual_mm == pytest.approx(0.200, abs=0.005)
    assert measured.runner_up_mm > measured.residual_mm * po.SEPARATION_RATIO


def test_the_separation_ratio_is_pinned_from_both_sides():
    """``SEPARATION_RATIO`` has to sit in a gap, and BOTH edges are derived.

    Below it lies a genuine tie at 1.0x — a symmetric pad field whose best and
    runner-up angles fit equally well, which is the case the whole pad-number
    anchor exists to catch. Above it lies the weakest separation any
    CORRECTLY-PAIRED committed pair shows: raise the constant past that and a
    true measurement starts reading as ambiguous.

    The upper bound is computed from the corpus here rather than quoted in a
    comment beside the constant, because the corpus keeps growing and a quoted
    number does not. Adding a pair whose angle is only just decided fails this
    test — which is the moment to look at the pair, NEVER to lower the
    constant.
    """
    ratios = {}
    for lcsc in ORACLE:
        # From the per-angle residuals, NOT from `runner_up_mm`: that field is
        # None once a pair stops deciding, which is precisely the failure this
        # test has to be able to describe.
        best, runner_up = sorted(
            mm for _, mm in _measure(lcsc).residuals_by_angle)[:2]
        ratios[lcsc] = math.inf if best == 0 else runner_up / best

    weakest, weakest_ratio = min(ratios.items(), key=lambda kv: kv[1])
    assert 1.0 < po.SEPARATION_RATIO < weakest_ratio, (
        f"SEPARATION_RATIO is {po.SEPARATION_RATIO} and the weakest true "
        f"separation over the {len(ratios)} committed pairs is now "
        f"{weakest_ratio:.2f}x ({weakest}) — the constant no longer sits "
        f"between a genuine tie at 1.0x and the pairs it must keep deciding")
    # And the consequence, so the bound is not merely arithmetic about floats.
    assert all(_measure(lcsc).angle_decided for lcsc in ORACLE)


def test_a_pad_centre_difference_does_not_cost_us_the_rotation_verdict():
    """The smaller sibling of the SOT-23 trap: SPK0641HT4H-1/C5159510 fits 180
    with ~0.06 mm on the worst pad, from a pad-centre difference."""
    measured = _measure("C5159510")
    assert measured.offset_deg == 180
    assert measured.verdict == po.VERDICT_ROTATED
    assert measured.max_pad_error_mm == pytest.approx(0.063, abs=0.005)


def test_the_wrong_part_number_reads_as_a_geometry_mismatch():
    """Our 1206 fuse footprint against C49678, an 0805 capacitor. Both are
    two-pad chips drawn the same way up, so the ANGLE is genuinely 0 and the
    measurement still says so — but the lands are 0.4 mm apart per pad because
    a 1206 is a bigger part, and calling that "agrees" would bless a BOM with
    the wrong LCSC number in it.
    """
    parsed = footprints.resolve_footprint("Fuse:Fuse_1206_3216Metric")
    measured = po.measure_footprint_against_part(parsed, _payload("C49678"),
                                                 lcsc="C49678")
    assert measured.verdict == po.VERDICT_GEOMETRY_MISMATCH
    assert measured.angle_decided is True
    assert measured.lands_agree is False
    # The angle survives the land disagreement — that separation is the design.
    assert measured.offset_deg == 0


def test_the_land_threshold_keeps_headroom_above_and_below():
    """``LAND_TOL_MM`` separates two measured populations that sit only
    0.2 mm apart, so it is the number in this module most likely to be
    "adjusted" into uselessness. This test says how much room it has on each
    side. If either population closes in, the threshold has stopped separating
    them and a human must re-measure — NEVER move the constant to make a
    failure go away.
    """
    legitimate = max(_measure(lcsc).residual_mm for lcsc in ORACLE)
    parsed = footprints.resolve_footprint("Fuse:Fuse_1206_3216Metric")
    wrong_part = po.measure_footprint_against_part(
        parsed, _payload("C49678"), lcsc="C49678").residual_mm

    assert legitimate <= po.LAND_TOL_MM - po.LAND_HEADROOM_MM, (
        f"the worst residual among CORRECT pairs is now {legitimate:.3f} mm, "
        f"within {po.LAND_HEADROOM_MM} mm of LAND_TOL_MM "
        f"({po.LAND_TOL_MM}) — a correct pair is about to be called a "
        f"geometry mismatch")
    assert wrong_part >= po.LAND_TOL_MM + po.LAND_HEADROOM_MM, (
        f"the 1206-footprint/0805-part mispairing now scores "
        f"{wrong_part:.3f} mm, within {po.LAND_HEADROOM_MM} mm of "
        f"LAND_TOL_MM ({po.LAND_TOL_MM}) — a wrong part is about to be "
        f"called an agreement")


def test_an_undecidable_rotation_is_reported_as_ambiguous():
    """A drawing turned 45 degrees fits 0 and 90 exactly as badly as each
    other. There is no answer, and the measurement must say so rather than
    return whichever angle sorted first."""
    diagonal = math.sqrt(0.5)
    ours = po._collect("ours", [("1", 1.0, 0.0), ("2", -1.0, 0.0),
                                ("3", 0.0, 1.0), ("4", 0.0, -1.0)])
    vendor = po._collect("vendor", [("1", diagonal, diagonal),
                                    ("2", -diagonal, -diagonal),
                                    ("3", -diagonal, diagonal),
                                    ("4", diagonal, -diagonal)])
    measured = po.measure_orientation(ours, vendor)
    assert measured.verdict == po.VERDICT_AMBIGUOUS
    assert measured.angle_decided is False
    assert measured.lands_agree is None
    # THE CONTRACT, ASSERTED DIRECTLY. `offset_deg` is stated if and only if
    # the angle was decided, so an undecided measurement carries NO number —
    # not the best-fitting angle, which is what "best" means when nothing
    # separates it from its runner-up. Asserted here rather than left to the
    # ledger's habit of discarding it: a direct consumer (a report, an MCP
    # result) reads this object, and a number beside `angle_decided=False` is
    # a guess a reader will eventually add to a rotation.
    assert measured.offset_deg is None
    assert measured.as_dict()["offset_deg"] is None
    by_angle = dict(measured.residuals_by_angle)
    assert by_angle[0] == pytest.approx(by_angle[90])


def test_a_ratio_alone_would_decide_an_angle_that_rests_on_nothing():
    """Why the separation test needs an absolute floor as well as a ratio.

    This pair fits 90 degrees PERFECTLY and every other angle within 0.06 mm,
    because the whole pad field is 0.06 mm across. The ratio is infinite, so a
    ratio-only rule declares the angle settled — on a margin narrower than the
    line width either drawing was made with. ``SEPARATION_FLOOR_MM`` is what
    turns that into "ambiguous", and it is the same guard that stops a genuine
    tie (best and runner-up both zero) from being read as a decision.
    """
    ours = po._collect("ours", [("1", 0.03, 0.0), ("2", -0.03, 0.0)])
    vendor = po._collect("vendor", [("1", 0.0, 0.03), ("2", 0.0, -0.03)])
    measured = po.measure_orientation(ours, vendor)
    by_angle = dict(measured.residuals_by_angle)
    assert by_angle[90] == 0.0, "the best fit is exact, so the ratio is infinite"
    assert max(by_angle.values()) < po.SEPARATION_FLOOR_MM + 0.01
    assert measured.verdict == po.VERDICT_AMBIGUOUS
    assert measured.angle_decided is False
    # The 90 fits EXACTLY here, so this is the case most likely to leak a
    # number: it is still not an offset, because nothing separates it.
    assert measured.offset_deg is None


# ---------------------------------------------------------------------------
# The absent-reference paths — answers, not exceptions
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("payload", [
    pytest.param(None, id="nothing-cached"),
    pytest.param({}, id="empty-document"),
    pytest.param({"result": {}}, id="no-package-detail"),
    pytest.param({"result": {"packageDetail": {"dataStr": {"head": {},
                                                           "shape": []}}}},
                 id="drawing-with-no-origin"),
])
def test_a_missing_vendor_reference_is_a_verdict_not_an_exception(payload):
    """"We have no vendor drawing for this part" is an ordinary outcome — an
    unlisted part, a house-numbered part, a cache miss. A consumer scanning a
    whole BOM must be able to tabulate it beside the real answers instead of
    catching an exception per part."""
    parsed = footprints.resolve_footprint("Capacitor_SMD:C_0805_2012Metric")
    measured = po.measure_footprint_against_part(parsed, payload)
    assert measured.verdict == po.VERDICT_NO_REFERENCE
    assert measured.offset_deg is None
    assert measured.angle_decided is False


def test_a_vendor_drawing_with_no_pads_is_also_no_reference():
    """A package document that parses but draws only an outline — silk, a
    courtyard, a 3D model reference — carries nothing to orient against."""
    payload = _payload("C49678")
    shapes = payload["result"]["packageDetail"]["dataStr"]["shape"]
    payload["result"]["packageDetail"]["dataStr"]["shape"] = [
        r for r in shapes if not r.startswith("PAD~")]
    assert po.parse_vendor_payload(payload) is None
    parsed = footprints.resolve_footprint(INDEX["C49678"]["footprint"])
    assert (po.measure_footprint_against_part(parsed, payload).verdict
            == po.VERDICT_NO_REFERENCE)


def test_sharing_fewer_than_two_pad_numbers_is_its_own_verdict():
    """Pad-less silk furniture — a logo, a revision legend — shares no pad
    number with any part. That is distinct from "no vendor drawing": the
    drawing is right there, the two just have nothing in common to compare.
    Reporting them the same way would hide a genuine numbering mismatch behind
    a missing-data excuse."""
    parsed = footprints.resolve_footprint("Minerva_Fixture:LOGO_Owl_TestCoupon")
    measured = po.measure_footprint_against_part(parsed, _payload("C49678"),
                                                 lcsc="C49678")
    assert measured.verdict == po.VERDICT_INSUFFICIENT_OVERLAP
    assert measured.offset_deg is None
    assert measured.matched_pads == ()


# ---------------------------------------------------------------------------
# Determinism and the reporting surface
# ---------------------------------------------------------------------------


def test_the_measurement_is_deterministic_and_json_clean():
    """Same inputs, same bytes out. The result crosses the worker's JSON
    boundary, so it also has to survive a round trip without a set, a tuple
    key, or a float that only reprs one way on one machine."""
    for lcsc in sorted(ORACLE):
        first = _measure(lcsc).as_dict()
        second = _measure(lcsc).as_dict()
        assert first == second
        assert json.loads(json.dumps(first)) == first


def test_an_offset_is_stated_if_and_only_if_the_angle_was_decided():
    """THE DATACLASS CONTRACT, asserted on the object rather than on a
    consumer's habit of ignoring the field.

    ``OrientationMeasurement`` promises ``offset_deg`` is a number exactly when
    ``angle_decided``. The ledger happens to discard the offset on an undecided
    row, so a leak there ships nothing wrong today — but a report, an MCP
    result, or the next consumer reads this object directly, and a number
    sitting beside ``angle_decided=False`` is a guess anyone would add to a
    rotation. Every branch the suite can reach is checked, so the invariant
    cannot be broken in one branch and left true in the others.
    """
    diagonal = math.sqrt(0.5)
    cases = [_measure(lcsc) for lcsc in sorted(ORACLE)]
    cases.append(po.measure_footprint_against_part(
        footprints.resolve_footprint("Fuse:Fuse_1206_3216Metric"),
        _payload("C49678"), lcsc="C49678"))                   # geometry_mismatch
    cases.append(po.measure_orientation(
        po._collect("ours", [("1", 1.0, 0.0), ("2", -1.0, 0.0),
                             ("3", 0.0, 1.0), ("4", 0.0, -1.0)]),
        po._collect("vendor", [("1", diagonal, diagonal),
                               ("2", -diagonal, -diagonal),
                               ("3", -diagonal, diagonal),
                               ("4", diagonal, -diagonal)])))  # ambiguous
    cases.append(po.measure_footprint_against_part(
        footprints.resolve_footprint("Minerva_Fixture:LOGO_Owl_TestCoupon"),
        _payload("C49678"), lcsc="C49678"))                   # insufficient_overlap
    cases.append(po.measure_footprint_against_part(
        footprints.resolve_footprint("Capacitor_SMD:C_0805_2012Metric"),
        None))                                                # no_reference

    verdicts = {m.verdict for m in cases}
    assert verdicts == set(po.VERDICTS), (
        "this invariant is only worth asserting over every branch; "
        f"unreached: {sorted(set(po.VERDICTS) - verdicts)}")
    for measured in cases:
        assert (measured.offset_deg is not None) is measured.angle_decided, (
            f"{measured.verdict}: offset_deg={measured.offset_deg!r} beside "
            f"angle_decided={measured.angle_decided!r} — an offset is stated "
            f"if and only if the angle was decided")
        assert (measured.as_dict()["offset_deg"] is None) is not measured.angle_decided


def test_every_verdict_the_module_declares_is_reachable():
    """A verdict nobody can produce is a comment pretending to be code. Each of
    the six is exercised somewhere above; this is the ledger that says so, and
    it fails when a seventh is added without a case to reach it."""
    exercised = {
        po.VERDICT_ALIGNED, po.VERDICT_ROTATED, po.VERDICT_GEOMETRY_MISMATCH,
        po.VERDICT_AMBIGUOUS, po.VERDICT_INSUFFICIENT_OVERLAP,
        po.VERDICT_NO_REFERENCE,
    }
    assert set(po.VERDICTS) == exercised


def test_the_datum_offset_reports_where_the_two_origins_disagree():
    """A rotation is not the only way two drawings can differ: they can agree
    on the pads and disagree on where the origin sits. The fit removes that by
    construction (centroid alignment), so it would be invisible unless
    reported. Our JST XH puts its origin 0.25 mm from the vendor's, which is a
    datum difference and NOT a rotation — the verdict is still `aligned`.
    """
    measured = _measure("C161861")
    assert measured.verdict == po.VERDICT_ALIGNED
    assert measured.datum_offset_mm is not None
    assert measured.datum_offset_mm[1] == pytest.approx(0.25, abs=0.005)
