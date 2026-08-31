"""The local assembly preview: does the drawing say what the pick-and-place
file says, and can a person see it when it does not.

THE ORACLES, named, because each test below turns on a different one:

  * ONE DERIVATION. Every coordinate, rotation and layer token on the page is
    compared against the CELL OF ``cpl.csv`` for the same designator, as a
    STRING. Not "close to" — the same characters. The failure this catches is
    the one the task exists to prevent: a preview that computes its own answer
    and agrees with the file today. A tolerance-based comparison would let that
    live for months; a string comparison cannot.
  * THE HAND-DERIVED FIXTURES. The placements come from
    ``testdata/assembly_boards/assembly_anchor*.yaml``, whose every expected
    coordinate is derived by hand in ``test_assembly_anchor.py`` from two
    measured footprint boxes and the documented placement transform. Nothing
    here asks the preview what it thinks; the numbers were settled before this
    module existed.
  * VISIBILITY OF THE ANCHOR TRAP. The override fixture with its authored
    anchors STRIPPED is the exact defect task B0b fixed: six placements whose
    anchors were measured off the wrong body, every one of which passes every
    hard gate. These tests pin what a person actually SEES — which one is
    ringed as off its own part, which are not, and the sentence that names all
    of them.
  * OPENABLE WITHOUT A TOOLCHAIN. The file must parse as XML and must reach
    nothing off the disk. A preview that needs a network or a viewer is not a
    check somebody performs at the moment they are about to pay.
  * DETERMINISM. The manifest digests this file, so two renders of one board
    must be the same bytes.
  * AN ARC'S INK IS THE SWEEP, NOT ITS THREE CONTROL POINTS. The extent an arc
    contributes decides two things that both fail quietly when it is short: a
    part sitting on the far reach of a curved body gets ringed as off its own
    part, and a non-rectangular board outline gets cropped off the page. The
    tests below drive ``_arc_ink`` directly, because a footprint whose body is
    one major arc is not something the shared fixtures contain.

The fixtures are the SHARED ones on purpose. A preview built on its own boards
would be a second opinion about a second board.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao
from pcb_worker import assembly_preview as ap
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    ANCHOR_BASIS_AUTHORED, DiagnosticSeverity, ResolutionSuccess,
)

BOARDS = Path(__file__).resolve().parent / "testdata" / "assembly_boards"
ANCHOR_FIXTURE = BOARDS / "assembly_anchor.yaml"
OVERRIDE_FIXTURE = BOARDS / "assembly_anchor_override.yaml"
PROFILE = "jlc"

SVG_NS = "{http://www.w3.org/2000/svg}"


def _compiled(path: Path):
    result = compile_board(yaml.safe_load(path.read_text(encoding="utf-8")))
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _stripped(path: Path = OVERRIDE_FIXTURE):
    """The override fixture with every ``anchor_mm`` removed and nothing else
    touched — the board task B0b's key exists to repair. Built by mutation, the
    way ``test_assembly_anchor`` builds its control arm, so the two boards
    cannot drift apart in some unrelated field."""
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    removed = 0
    for component in document["components"]:
        for placement in component["assembly"]["placements"]:
            removed += placement.pop("anchor_mm", None) is not None
    assert removed == 6, "the fixture stopped authoring the anchors under test"
    result = compile_board(document)
    assert isinstance(result, ResolutionSuccess)
    return result.board


def _half_stripped(path: Path = OVERRIDE_FIXTURE):
    """The override fixture with ONE placement's ``anchor_mm`` removed.

    The likelier authoring mistake than forgetting all of them: a two-strip
    socket whose first strip states its anchor and whose second was forgotten.
    Same mutation-of-the-shared-fixture construction as :func:`_stripped`."""
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    component = next(c for c in document["components"] if c["ref"] == "U3S")
    dropped = component["assembly"]["placements"][1].pop("anchor_mm", None)
    assert dropped is not None, "the fixture stopped authoring U3S_B's anchor"
    result = compile_board(document)
    assert isinstance(result, ResolutionSuccess)
    return result.board


def _rendered(board):
    """The preview and the CPL from ONE emission — the pairing under test, built
    through the same public entry point the order package uses. Two calls would
    be two walks, which is the very thing this file exists to rule out."""
    package = ao.build_package(board, PROFILE)
    svg = ap.render(board, package.emission)
    return svg, package.files[package.cpl_file], package.emission


def _groups(svg: str, cls: str) -> list:
    """Every ``<g class="...">`` on the page, in document order.

    A LIST, so that counting these counts ELEMENTS. Collecting them straight
    into a dict keyed by ``data-ref`` is what a count must not be taken off: two
    groups carrying one ref collapse into one entry, so a page drawing a body
    per PART rather than per component would count the same as a correct one."""
    root = ET.fromstring(svg)
    return [element for element in root.iter(f"{SVG_NS}g")
            if element.get("class") == cls]


def _by_ref(groups: list) -> dict:
    """``{data-ref: group}``, with a repeated ref an ERROR rather than a silent
    overwrite — the collapse above, refused at the one place it can happen."""
    refs = [group.get("data-ref") for group in groups]
    assert len(set(refs)) == len(refs), f"a ref is drawn twice: {refs}"
    return dict(zip(refs, groups))


def _placement_groups(svg: str) -> dict:
    """Every ``<g class="placement">`` in the drawing, by designator."""
    return _by_ref(_groups(svg, "placement"))


def _drawing_groups(svg: str) -> dict:
    """Every ``<g class="drawing">`` on the page, by component ref. A drawing is
    per COMPONENT and a placement is per PART, which is the whole distinction an
    expansion turns on, so the two are counted separately off the same page."""
    return _by_ref(_groups(svg, "drawing"))


def _cpl_cells(cpl: str) -> dict:
    """``cpl.csv`` parsed back into ``{designator: [cells]}``. Read out of the
    RENDERED FILE rather than off the row objects, because the file is what a
    house receives and what the preview has to match."""
    lines = [line for line in cpl.split("\r\n") if line]
    return {parts[0]: parts for parts in (line.split(",") for line in lines[1:])}


def _rotate_args(element) -> list:
    """The ``rotate(a, x, y)`` arguments of the placement's rotation tick — the
    crosshair's PLOTTED position and angle, read back out of the drawing."""
    for child in element.iter(f"{SVG_NS}g"):
        transform = child.get("transform") or ""
        if transform.startswith("rotate("):
            return [float(v) for v in
                    transform[len("rotate("):-1].split(",")]
    raise AssertionError("placement group carries no rotation tick")


# ---------------------------------------------------------------------------
# THE ORACLE: the page and the file are one derivation.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("fixture", [ANCHOR_FIXTURE, OVERRIDE_FIXTURE])
def test_every_drawn_placement_carries_the_cells_of_the_emitted_file(fixture):
    """THE ORACLE OF THIS TASK. For every designator, the four values the
    drawing publishes — X, Y, layer token and rotation — are the SAME STRINGS
    the CSV row carries.

    Across both fixtures this covers a part whose body centre is its origin, one
    whose origin is pin 1, a rotated part, a bottom-side part, a bottom-side
    rotated part and two synthetic expansions, including the two-row socket the
    real board uses. Every one of those coordinates was hand-derived in
    ``test_assembly_anchor.py`` before this module existed."""
    svg, cpl, emission = _rendered(_compiled(fixture))
    groups = _placement_groups(svg)
    cells = _cpl_cells(cpl)

    assert set(groups) == set(cells), (
        "the drawing and the file must name the same parts")
    assert set(groups) == {row.ref for row in emission.cpl}
    for ref, row in cells.items():
        drawn = groups[ref]
        assert [drawn.get("data-ref"), drawn.get("data-x"), drawn.get("data-y"),
                drawn.get("data-layer"), drawn.get("data-rotation")] == row


@pytest.mark.parametrize("fixture", [ANCHOR_FIXTURE, OVERRIDE_FIXTURE])
def test_the_crosshair_is_plotted_on_the_emitted_numbers(fixture):
    """The published cells could agree while the INK sat somewhere else, which
    would be the worst of both: a page that reads correct and looks wrong.

    So this reads the crosshair's own geometry back — the ``rotate(a, x, y)``
    the rotation tick is drawn inside — and compares it with the emitted cells.
    The page's frame IS the emitted frame, so those are the same numbers with no
    conversion between them."""
    svg, cpl, _ = _rendered(_compiled(fixture))
    groups = _placement_groups(svg)
    for ref, row in _cpl_cells(cpl).items():
        rotation, x, y = _rotate_args(groups[ref])
        assert x == pytest.approx(float(row[1]))
        assert y == pytest.approx(float(row[2]))
        assert rotation == pytest.approx(float(row[4]))


def test_the_bottom_side_is_drawn_where_the_file_claims_not_mirrored():
    """A house is not told a mirrored coordinate for a bottom-side part, so the
    page must not draw one either — both sides share one frame here.

    Q1 and Q3 are the same footprint at the same Y on opposite sides, and
    SOT-23's body centre IS its origin (pinned in ``test_assembly_anchor``), so
    the hand-derived answer is the placement itself: (10, -10) and (30, -10)."""
    svg, _, _ = _rendered(_compiled(ANCHOR_FIXTURE))
    groups = _placement_groups(svg)
    assert _rotate_args(groups["Q1"])[1:] == pytest.approx([10.0, -10.0])
    assert _rotate_args(groups["Q3"])[1:] == pytest.approx([30.0, -10.0])
    assert groups["Q1"].get("data-layer") == "Top"
    assert groups["Q3"].get("data-layer") == "Bottom"


# ---------------------------------------------------------------------------
# What a person SEES when the anchor is the one B0b repaired.
# ---------------------------------------------------------------------------


def test_the_worked_examples_wrong_anchor_is_ringed_off_its_own_part():
    """THE VISIBLE HALF OF THE B0b DEFECT.

    Stripped of its authored anchors, U5S carries the DCR's original worked
    example verbatim: offsets (0, 0) and (22.86, 0) with one anchor measured off
    the whole two-row body. U5S_B then claims x 52.86 while the drawing's own
    ink stops at x 42.93 — a part the order places ten millimetres past the
    thing it names — and the page rings it and draws a leader back.

    THE OTHER FIVE ARE NOT RINGED, and that is the honest result rather than a
    weak one: their anchors are wrong but land INSIDE the drawn body, which is
    a legal shape (an authored anchor may be anywhere on its part). Seeing those
    is what the lands and the note in the next test are for."""
    svg, _, _ = _rendered(_stripped())
    groups = _placement_groups(svg)
    ringed = {ref for ref, group in groups.items()
              if group.get("data-off-body") == "1"}
    assert ringed == {"U5S_B"}

    repaired = _placement_groups(_rendered(_compiled(OVERRIDE_FIXTURE))[0])
    assert not any(group.get("data-off-body")
                   for group in repaired.values())


def test_the_inherited_anchor_is_named_on_the_page():
    """The five wrong anchors no ring catches are still SAID. Every drawing that
    places more than one part and let all of them inherit one measured anchor is
    listed by name, with the key that states an anchor per placement.

    This is deliberately a sentence and not a check: the anchors were measured,
    the parts are the right distance apart, and every hard gate passes — the
    boundary the DCR draws here is a person."""
    # Phrases are asserted against the JOINED page prose, not the raw file:
    # the notes wrap, and a wrap break inside a phrase must not decide this.
    stripped = _page_prose(_rendered(_stripped())[0])
    assert "U3S_A, U3S_B" in stripped
    assert "U4S_A, U4S_B" in stripped
    assert "U5S_A, U5S_B" in stripped
    assert "anchor_mm" in stripped

    repaired = _rendered(_compiled(OVERRIDE_FIXTURE))[0]
    assert "U3S_A, U3S_B" not in _page_prose(repaired)
    for group in _placement_groups(repaired).values():
        assert group.get("data-anchor-basis") == ANCHOR_BASIS_AUTHORED


def test_a_half_authored_expansion_names_the_placement_that_inherited():
    """The QUIET half of the trap. An author who states the anchor for one strip
    of a two-strip socket and forgets the other leaves that second placement on
    the parent's whole-body centre — a shape the all-inherited sentence used to
    skip entirely, because a sibling had authored.

    The oracle is the note text: the forgotten placement is named, its authored
    sibling is not (it is not wrong), and the sentence says a sibling did state
    one, which is what tells a reader this is a half-finished expansion rather
    than an unstated one."""
    prose = _page_prose(_rendered(_half_stripped())[0])
    assert "U3S_B — one drawing, 2 parts, and a SIBLING placement" in prose
    # NOT the all-inherited sentence, and nothing at all about the two
    # components that authored every anchor.
    assert "U3S_A, U3S_B" not in prose
    assert "U4S_A, U4S_B" not in prose
    assert "U5S_A, U5S_B" not in prose


def test_an_expansion_draws_one_body_per_component_and_one_crosshair_per_part():
    """One drawn socket, two soldered strips: the shape that makes the trap
    possible in the first place. The drawing half is the PARENT's — an expansion
    child carries no geometry of its own — while the claim half is per part, so
    the page shows several crosshairs over one outline. That is the picture a
    reader has to be given in order to ask "is each cross on a strip".

    BOTH HALVES ARE COUNTED OFF THE PAGE. Counting the crosshairs and then
    asserting the compiled board has three components proves the model, not the
    drawing: a renderer that emitted a body per PART would have satisfied that
    and produced exactly the picture this test exists to rule out."""
    board = _compiled(OVERRIDE_FIXTURE)
    svg, _, _ = _rendered(board)
    crosshairs = _groups(svg, "placement")
    bodies = _groups(svg, "drawing")
    # ELEMENTS first, refs second: the count says there are three bodies and six
    # crosshairs, and _by_ref says no ref is drawn twice. A page carrying a body
    # per part would fail the first; a page repeating one body would fail the
    # second. Keyed lookups alone pass both.
    assert (len(bodies), len(crosshairs)) == (3, 6)
    assert {"U3S", "U4S", "U5S"} == set(_by_ref(bodies))
    assert {"U3S_A", "U3S_B", "U4S_A", "U4S_B",
            "U5S_A", "U5S_B"} == set(_by_ref(crosshairs))
    assert len(bodies) == len(board.components)


# ---------------------------------------------------------------------------
# What an arc's ink occupies.
# ---------------------------------------------------------------------------


def _arc_box(start, mid, end):
    """The extent ``_arc_ink`` reports for one three-point arc."""
    _path, points = ap._arc_ink(start, mid, end, cls="body-top")
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def test_a_semicircle_reports_the_half_plane_it_actually_sweeps():
    """The unit semicircle through (0,1): the sweep the emitted path selects is
    the one the mid point names, so its ink is the upper half and its extent
    stops at y = 0. Pinned because the mirror triple must NOT report the same
    box — that is the check that says the sweep is being read at all."""
    assert _arc_box((1.0, 0.0), (0.0, 1.0), (-1.0, 0.0)) == pytest.approx(
        (-1.0, 0.0, 1.0, 1.0))
    assert _arc_box((1.0, 0.0), (0.0, -1.0), (-1.0, 0.0)) == pytest.approx(
        (-1.0, -1.0, 1.0, 0.0))


def test_a_major_arc_reaches_a_full_radius_past_its_own_endpoints():
    """THE CASE THE THREE CONTROL POINTS CANNOT SEE. Both ends sit at x = 1,
    a tenth of a millimetre apart, and the sweep goes the long way round: the
    ink reaches a full radius above, below and to the left of them. Reading the
    extent off the triple reported a 0.2 mm-tall sliver for ink 2 mm tall.

    THE WHOLE BOX IS DERIVED FROM THE CIRCLE, not read off the picture. The
    three points are symmetric about y = 0, so the centre sits on that axis at
    (cx, 0) with (cx + 1)^2 = (cx - 1)^2 + 0.1^2 — cx = 0.0025 — and the radius
    is cx + 1 = 1.0025. The sweep passes the left, top and bottom of that
    circle but not its right, so the box is x from cx - r = -1.0 to the
    endpoints' own x = 1.0, and y from cy - r to cy + r = +/-1.0025."""
    box = _arc_box((1.0, -0.1), (-1.0, 0.0), (1.0, 0.1))
    assert box == pytest.approx((-1.0, -1.0025, 1.0, 1.0025), abs=1e-9)
    # Both directions round the same circle cover the same ink.
    assert _arc_box((1.0, 0.1), (-1.0, 0.0), (1.0, -0.1)) == pytest.approx(box)


def test_a_quarter_arc_claims_no_more_than_it_draws():
    """The other failure mode of a sweep-aware extent: claiming the whole
    circle. A quarter turn crosses no axis between its ends, so its box is its
    two endpoints and nothing more."""
    assert _arc_box((1.0, 0.0), (0.7071, 0.7071), (0.0, 1.0)) == pytest.approx(
        (0.0, 0.0, 1.0, 1.0))


def test_a_collinear_triple_falls_back_to_its_points():
    """An arc through three collinear points IS a line, and a line's extent is
    its points. The fallback must still report an extent rather than nothing."""
    path, points = ap._arc_ink((0.0, 0.0), (1.0, 1.0), (2.0, 2.0),
                               cls="body-top")
    assert path.startswith("<polyline")
    assert points == [(0.0, 0.0), (1.0, 1.0), (2.0, 2.0)]


def test_a_part_on_the_far_reach_of_a_curved_body_is_not_ringed():
    """THE CONSEQUENCE, at the surface that shows it. ``_Drawing.contains`` is
    what decides whether a placement gets the red off-body ring and a leader
    line, and it reads the same extent. With the extent taken off the control
    points, a part legitimately sitting on the arc's far reach was reported as
    off its own body — an alarm on a correct board, which is how a reader learns
    to ignore the alarm."""
    _path, points = ap._arc_ink((1.0, -0.1), (-1.0, 0.0), (1.0, 0.1),
                                cls="body-top")
    drawing = ap._Drawing(ref="U1", populate=True, side="top",
                          outline_basis=ap.OUTLINE_FAB, points=list(points))
    assert drawing.contains(-0.9, 0.0)
    assert drawing.contains(0.0, 0.95)
    assert not drawing.contains(0.0, 1.5)


# ---------------------------------------------------------------------------
# The pin-1 mark and what its absence is allowed to mean.
# ---------------------------------------------------------------------------


def test_pin_one_is_marked_on_the_land_the_footprint_numbers_one():
    """The mark's whole value is that it is on the REAL pin 1 after the
    placement transform, so it is compared against the placed pad the compiled
    board carries under that number — not against a re-composed position."""
    board = _compiled(ANCHOR_FIXTURE)
    definitions = {d.content_id: d for d in board.footprint_definitions}
    for component in board.components:
        numbers = {pad.source_id: pad.number
                   for pad in definitions[component.footprint_id].pads}
        expected = next(pad for pad in component.placed_pads
                        if numbers[pad.source_id] == "1")
        mark, note = ap.pin_one(board, component)
        assert note == ""
        assert mark == pytest.approx(ao.cpl_frame_point(expected.position))


def test_a_one_terminal_part_says_why_it_carries_no_mark():
    """An absent mark must never read as a part somebody checked and found
    symmetric. A test point has one pad, so there is no end to get wrong — and
    the page says exactly that rather than saying nothing.

    The same board proves the rule is NOT narrowed by guessing: R1 is a two-pad
    chip resistor, genuinely reversible, and it is marked anyway. Board data
    cannot tell it from a diode on the same land pattern, and the mark that
    fails safe is the one that is drawn."""
    board = _compiled_dict({
        "version": 1, "name": "PinOneRule", "width_mm": 30, "height_mm": 20,
        "origin": {"x_mm": 0, "y_mm": 0}, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "Resistor_SMD:R_0805_2012Metric",
             "value": "10k", "x_mm": 8.0, "y_mm": 8.0, "rotation_deg": 0,
             "layer": "top", "assembly": {"mpn": "C25804"}},
            # Bare, not "TestPoint:TH_TestPoint": this footprint is a SEED entry
            # and the lock file keys the three seeds by bare name.
            {"ref": "TP1", "footprint": "TH_TestPoint", "value": "",
             "x_mm": 20.0, "y_mm": 8.0, "rotation_deg": 0, "layer": "top",
             "assembly": {"populate": False}},
        ],
    })
    by_ref = {component.ref: component for component in board.components}
    assert ap.pin_one(board, by_ref["R1"])[0] is not None
    mark, note = ap.pin_one(board, by_ref["TP1"])
    assert mark is None
    assert "one terminal" in note

    svg, _, _ = _rendered(board)
    assert "TP1 — no pin-1 mark: one terminal" in _page_prose(svg)
    # The unpopulated part is DRAWN and labelled, but claims nothing: an empty
    # spot on a board is either deliberate or a dropped part, and those look
    # identical unless the page says which.
    assert ">DNP<" in svg
    assert set(_placement_groups(svg)) == {"R1"}


def _compiled_dict(document: dict):
    result = compile_board(document)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "board did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


# ---------------------------------------------------------------------------
# The file itself.
# ---------------------------------------------------------------------------


def test_the_page_opens_with_nothing_but_a_browser():
    """A check performed at the moment of payment cannot need a toolchain, a
    viewer or a network. The file must parse as XML on its own and must not
    reach off the disk for a script, a stylesheet, an image or a font."""
    svg, _, _ = _rendered(_compiled(ANCHOR_FIXTURE))
    root = ET.fromstring(svg)  # raises if it is not well-formed XML
    assert root.tag == f"{SVG_NS}svg"
    for forbidden in ("<script", "<image", "xlink:href", "@import",
                      "<foreignObject", "href="):
        assert forbidden not in svg
    # The namespace declaration is the only URL a self-contained page needs.
    assert svg.count("http") == 1


def test_two_renders_of_one_board_are_the_same_bytes():
    """The manifest records a digest for this file, so a clock, a set iteration
    order or a host path leaking into it would make a package unreproducible."""
    board = _compiled(OVERRIDE_FIXTURE)
    emission = ao.emit(board, PROFILE)
    assert ap.render(board, emission) == ap.render(board, ao.emit(board, PROFILE))


def test_the_page_states_the_frame_it_is_drawn_in():
    """A drawing whose conventions are unstated can be read two ways, and one of
    them is wrong. The page has to say that Y is negated, that bottom-side X is
    not mirrored, and that rotation is counter-clockwise-positive — the three
    facts a reader needs to compare it with the house's own preview."""
    svg, _, _ = _rendered(_compiled(ANCHOR_FIXTURE))
    prose = _page_prose(svg)
    assert "UNMIRRORED" in prose
    assert "counter-clockwise-positive" in prose
    assert "the board's Y negated" in prose
    assert "cpl.csv" in prose


# ---------------------------------------------------------------------------
# The page must not clip its own words, and a label must be readable.
#
# GROUND TRUTH FOR TEXT WIDTH IS NOT THE MODULE'S ESTIMATOR. The no-clipping
# property was once asserted with the same `_est_text_width` the renderer
# wraps with, which makes underestimation invisible by construction: a glyph
# the estimator buckets too narrow fits the estimate and overflows the render,
# and the test cannot see it (measured: 56 space-separated '+' estimated
# 754 px against the 760 px budget and rendered 772.9 px). So the tables below
# are the EXACT advances out of DejaVu Sans / DejaVu Sans Bold 2.37 (hmtx,
# units-per-em 2048, rounded to 4 decimals) — the first face in the page's
# stylesheet stack — sourced from the font files, not from the code under
# test. DejaVu Sans Mono advances one width for every glyph in both weights.
# ---------------------------------------------------------------------------

_DEJAVU_EM = {
    " ": 0.3179, "!": 0.4009, "\"": 0.4600, "#": 0.8379, "$": 0.6362,
    "%": 0.9502, "&": 0.7798, "'": 0.2749, "(": 0.3901, ")": 0.3901,
    "*": 0.5000, "+": 0.8379, ",": 0.3179, "-": 0.3608, ".": 0.3179,
    "/": 0.3369, "0": 0.6362, "1": 0.6362, "2": 0.6362, "3": 0.6362,
    "4": 0.6362, "5": 0.6362, "6": 0.6362, "7": 0.6362, "8": 0.6362,
    "9": 0.6362, ":": 0.3369, ";": 0.3369, "<": 0.8379, "=": 0.8379,
    ">": 0.8379, "?": 0.5308, "@": 1.0000, "A": 0.6841, "B": 0.6860,
    "C": 0.6982, "D": 0.7700, "E": 0.6318, "F": 0.5752, "G": 0.7749,
    "H": 0.7520, "I": 0.2949, "J": 0.2949, "K": 0.6558, "L": 0.5571,
    "M": 0.8628, "N": 0.7480, "O": 0.7871, "P": 0.6030, "Q": 0.7871,
    "R": 0.6948, "S": 0.6348, "T": 0.6108, "U": 0.7319, "V": 0.6841,
    "W": 0.9888, "X": 0.6851, "Y": 0.6108, "Z": 0.6851, "[": 0.3901,
    "\\": 0.3369, "]": 0.3901, "^": 0.8379, "_": 0.5000, "`": 0.5000,
    "a": 0.6128, "b": 0.6348, "c": 0.5498, "d": 0.6348, "e": 0.6152,
    "f": 0.3521, "g": 0.6348, "h": 0.6338, "i": 0.2778, "j": 0.2778,
    "k": 0.5791, "l": 0.2778, "m": 0.9741, "n": 0.6338, "o": 0.6118,
    "p": 0.6348, "q": 0.6348, "r": 0.4111, "s": 0.5210, "t": 0.3921,
    "u": 0.6338, "v": 0.5918, "w": 0.8179, "x": 0.5918, "y": 0.5918,
    "z": 0.5249, "{": 0.6362, "|": 0.3369, "}": 0.6362, "~": 0.8379,
    "°": 0.5000, "·": 0.3179, "—": 1.0000, "–": 0.5000, "’": 0.3179,
    "‘": 0.3179, "“": 0.5181, "”": 0.5181, "±": 0.8379, "×": 0.8379,
    "µ": 0.6362, "Ω": 0.7642,
}
_DEJAVU_BOLD_EM = {
    " ": 0.3481, "!": 0.4561, "\"": 0.5210, "#": 0.8379, "$": 0.6958,
    "%": 1.0020, "&": 0.8721, "'": 0.3062, "(": 0.4570, ")": 0.4570,
    "*": 0.5229, "+": 0.8379, ",": 0.3799, "-": 0.4150, ".": 0.3799,
    "/": 0.3652, "0": 0.6958, "1": 0.6958, "2": 0.6958, "3": 0.6958,
    "4": 0.6958, "5": 0.6958, "6": 0.6958, "7": 0.6958, "8": 0.6958,
    "9": 0.6958, ":": 0.3999, ";": 0.3999, "<": 0.8379, "=": 0.8379,
    ">": 0.8379, "?": 0.5801, "@": 1.0000, "A": 0.7739, "B": 0.7622,
    "C": 0.7339, "D": 0.8301, "E": 0.6831, "F": 0.6831, "G": 0.8208,
    "H": 0.8369, "I": 0.3721, "J": 0.3721, "K": 0.7749, "L": 0.6372,
    "M": 0.9951, "N": 0.8369, "O": 0.8501, "P": 0.7329, "Q": 0.8501,
    "R": 0.7700, "S": 0.7202, "T": 0.6821, "U": 0.8120, "V": 0.7739,
    "W": 1.1030, "X": 0.7710, "Y": 0.7241, "Z": 0.7251, "[": 0.4570,
    "\\": 0.3652, "]": 0.4570, "^": 0.8379, "_": 0.5000, "`": 0.5000,
    "a": 0.6748, "b": 0.7158, "c": 0.5928, "d": 0.7158, "e": 0.6782,
    "f": 0.4351, "g": 0.7158, "h": 0.7119, "i": 0.3428, "j": 0.3428,
    "k": 0.6650, "l": 0.3428, "m": 1.0420, "n": 0.7119, "o": 0.6870,
    "p": 0.7158, "q": 0.7158, "r": 0.4932, "s": 0.5952, "t": 0.4780,
    "u": 0.7119, "v": 0.6519, "w": 0.9238, "x": 0.6450, "y": 0.6519,
    "z": 0.5820, "{": 0.7119, "|": 0.3652, "}": 0.7119, "~": 0.8379,
    "°": 0.5000, "·": 0.3799, "—": 1.0000, "–": 0.5000, "’": 0.3799,
    "‘": 0.3799, "“": 0.6572, "”": 0.6572, "±": 0.8379, "×": 0.8379,
    "µ": 0.7358, "Ω": 0.8501,
}
_DEJAVU_MONO_EM = 0.6021


def _real_text_width(text: str, size: float, *, bold: bool = False,
                     mono: bool = False) -> float:
    """What the text really advances in DejaVu, from the tables above."""
    if mono:
        return len(text) * _DEJAVU_MONO_EM * size
    table = _DEJAVU_BOLD_EM if bold else _DEJAVU_EM
    missing = sorted({ch for ch in text if ch not in table})
    assert not missing, (
        f"page text carries characters outside the test's advance table — "
        f"extend the table from the font before trusting a width: {missing!r}")
    return sum(table[ch] for ch in text) * size


def _text_face(element) -> tuple[float, bool, bool]:
    """``(size, bold, mono)`` the stylesheet gives this page-space text."""
    cls = (element.get("class") or "").split()
    size = 17.0 if "title" in cls else 12.0
    bold = any(token in cls
               for token in ("title", "prose-strong", "cell-head", "cell-off"))
    return size, bold, "mono" in cls


def _page_space_texts(svg: str):
    """Every ``<text>`` drawn in PAGE pixels — title, header, legend, notes and
    table — i.e. the direct children of the root. Text inside the drawing group
    lives in board millimetres and is measured by the label test instead."""
    root = ET.fromstring(svg)
    for child in root:
        if child.tag == f"{SVG_NS}text":
            yield child


def _page_prose(svg: str) -> str:
    """All page-space text joined with spaces, in document order. Wrapping
    breaks a sentence into several ``<text>`` elements at a space, so a
    multiword phrase is asserted against THIS — where it always survives —
    rather than against the raw file, where it lives or dies on where the
    break currently falls."""
    return " ".join((element.text or "") for element in _page_space_texts(svg))


def _assert_page_texts_fit(svg: str) -> int:
    """Every page-space line REALLY fits the declared page width, measured
    with the font's own advances — and the module's estimate stays at or above
    the real width, which is the contract the wrap relies on."""
    root = ET.fromstring(svg)
    page_w = float(root.get("width"))
    checked = 0
    for element in _page_space_texts(svg):
        size, bold, mono = _text_face(element)
        x = float(element.get("x"))
        text = element.text or ""
        real = _real_text_width(text, size, bold=bold, mono=mono)
        estimate = ap._est_text_width(text, size, bold=bold, mono=mono)
        assert estimate >= real, (
            f"the estimator undercuts the font ({estimate:.1f}px < "
            f"{real:.1f}px): {text!r}")
        assert x + real <= page_w, (
            f"page text runs off the page ({x + real:.0f}px > {page_w:.0f}px): "
            f"{text!r}")
        checked += 1
    return checked


@pytest.mark.parametrize("fixture", [ANCHOR_FIXTURE, OVERRIDE_FIXTURE])
def test_no_page_text_runs_past_the_pages_own_edge(fixture):
    """The header once carried a 207-character sentence whose tail rendered
    past the page's declared width — cut off in a drawing whose entire purpose
    is being looked at. Every page-space line must fit inside the page,
    measured against the FONT's advances, not the estimator's."""
    svg, _, _ = _rendered(_compiled(fixture))
    assert _assert_page_texts_fit(svg) > 10, (
        "the page stopped emitting its own prose")


def test_the_estimator_is_an_upper_bound_for_every_tabled_glyph():
    """The wrap fits lines by estimate and the browser draws them by advance,
    so the estimate must sit at or above the real advance for EVERY glyph in
    every face the page uses — checked glyph by glyph against the font tables,
    including the ~0.84 em run ('+ = < > ^ ~') the old buckets carried at
    0.68 em. An off-table glyph must err wider than anything DejaVu has."""
    for ch, advance in _DEJAVU_EM.items():
        assert ap._est_text_width(ch, 1000.0) >= advance * 1000.0, repr(ch)
    for ch, advance in _DEJAVU_BOLD_EM.items():
        assert ap._est_text_width(ch, 1000.0, bold=True) >= advance * 1000.0, (
            repr(ch))
    for ch in _DEJAVU_EM:
        assert (ap._est_text_width(ch, 1000.0, mono=True)
                >= _DEJAVU_MONO_EM * 1000.0), repr(ch)
    # Not in the tables, not in DejaVu's repertoire at any width DejaVu has.
    assert ap._est_text_width("木", 1000.0) > 2016.0


def test_wrap_never_yields_a_line_that_renders_past_the_budget():
    """The wrap's whole guarantee, measured with the font's own advances: no
    emitted line renders past the budget and no character is dropped — for
    prose, for the '+'-row the old estimator passed straight through, and for
    a single token wider than the entire budget, which word wrapping alone
    cannot place at all."""
    cases = [
        " ".join(["+"] * 56),   # renders 772.9px; the old estimate said 754px
        "x" * 400,              # one unbreakable token
        "W" * 90 + " then ordinary words after the monster token",
        "an ordinary sentence that wraps on spaces like the header does",
    ]
    for case in cases:
        lines = ap._wrap(case, ap.PROSE_BUDGET_PX, 12.0)
        for line in lines:
            assert _real_text_width(line, 12.0) <= ap.PROSE_BUDGET_PX, (
                f"wrapped line still renders past the budget: {line!r}")
        assert "".join(lines).replace(" ", "") == case.replace(" ", ""), (
            f"wrap dropped characters from {case!r}")


def test_a_board_with_unbreakable_long_names_still_fits_its_page():
    """The guarantee end to end, on board data chosen to break it: a board
    name longer than the whole prose budget (the title line was never wrapped
    at all) and a designator far wider than its table column's minimum. Every
    page-space line still fits the declared width."""
    board = _compiled_dict({
        "version": 1, "name": "B" + "oard" * 60, "width_mm": 30,
        "height_mm": 20, "origin": {"x_mm": 0, "y_mm": 0},
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R" + "EALLYLONGDESIGNATOR" * 3,
             "footprint": "Resistor_SMD:R_0805_2012Metric", "value": "10k",
             "x_mm": 8.0, "y_mm": 8.0, "rotation_deg": 0, "layer": "top",
             "assembly": {"mpn": "C25804"}},
        ],
    })
    svg, _, _ = _rendered(board)
    assert _assert_page_texts_fit(svg) > 10


def _label_boxes(svg: str) -> dict:
    """Each placement label's REAL ink box, read back off the page (its own
    translate() and anchor) and sized with the font tables above — not with
    the module's estimator, which is part of what these tests judge."""
    boxes = {}
    for ref, group in _placement_groups(svg).items():
        label = next(el for el in group.iter(f"{SVG_NS}text")
                     if (el.get("class") or "").endswith("-label"))
        transform = label.get("transform")
        assert transform.startswith("translate(")
        bx, by = (float(v) for v in
                  transform[len("translate("):].split(")")[0].split(","))
        anchor = label.get("text-anchor") or "start"
        width = _real_text_width(label.text, ap.REF_TEXT_MM, bold=True)
        left = (bx - width if anchor == "end"
                else bx - width / 2.0 if anchor == "middle" else bx)
        boxes[ref] = (left, by - ap.REF_TEXT_MM * ap.LABEL_DESCENT,
                      left + width, by + ap.REF_TEXT_MM * ap.LABEL_ASCENT)
    return boxes


def _body_outline_segments(component) -> list:
    """Thin boxes along a component's REAL body stroke, rebuilt by this test
    from the placed graphics of the same layer ladder the page draws (fab
    first, silk second) — straight segments only, which is all the shared
    fixtures' bodies contain. Independent of the module's own band builder."""
    from pcb_worker.board_graphics import (LineGeometry, PolygonGeometry,
                                           PolylineGeometry)
    from pcb_worker.resolved_board import LayerRole
    for role in (LayerRole.FAB, LayerRole.SILK):
        segments = []
        for graphic in component.placed_graphics:
            if graphic.layer.role is not role:
                continue
            geometry = graphic.geometry
            if isinstance(geometry, LineGeometry):
                runs = [[ao.cpl_frame_point(geometry.a),
                         ao.cpl_frame_point(geometry.b)]]
            elif isinstance(geometry, (PolygonGeometry, PolylineGeometry)):
                points = [ao.cpl_frame_point(p) for p in geometry.points]
                if isinstance(geometry, PolygonGeometry):
                    points = points + points[:1]
                runs = [points]
            else:
                continue  # the shared fixtures draw no curved bodies
            for run in runs:
                for (x1, y1), (x2, y2) in zip(run, run[1:]):
                    segments.append((min(x1, x2) - 0.07, min(y1, y2) - 0.07,
                                     max(x1, x2) + 0.07, max(y1, y2) + 0.07))
        if segments:
            return segments
    return []


def test_placement_labels_cover_no_lands_no_marks_and_not_each_other():
    """A label drawn across a pad row, a body outline, a crosshair or its
    neighbour's label cannot be read, and a label that cannot be read does not
    do its job. The override fixture is the dense case that showed it: two
    bottom-side rows whose labels used to sit directly across their own lands.

    The label boxes are read back OFF THE PAGE and sized with the font tables;
    the lands, body strokes and crosshairs are rebuilt from the same board.
    The oracle is plain geometry: no intersection."""
    board = _compiled(OVERRIDE_FIXTURE)
    package = ao.build_package(board, PROFILE)
    svg = ap.render(board, package.emission)

    obstacles = []
    for component in board.components:
        obstacles.extend(ap._drawing(board, component).pad_boxes)
        obstacles.extend(_body_outline_segments(component))
    for row in package.emission.cpl:
        obstacles.extend(ap._mark_boxes(float(row.x_mm), float(row.y_mm),
                                        float(row.rotation_deg)))

    label_boxes = _label_boxes(svg)
    assert len(label_boxes) == 6, "the fixture stopped placing six parts"
    for ref, box in label_boxes.items():
        for obstacle in obstacles:
            assert ap._overlap_area(box, obstacle) == 0.0, (
                f"{ref}'s label covers board ink at {obstacle}")
        for other, other_box in label_boxes.items():
            if other != ref:
                assert ap._overlap_area(box, other_box) == 0.0, (
                    f"{ref}'s label covers {other}'s label")


def test_a_label_dodges_the_body_outline_not_the_drawings_bounds():
    """THE BOUNDS SHORTCUT, refused. Banding ``drawing.bounds()`` bands the
    combined box of pads AND body, so a part whose pads sit far outside its
    body leaves the whole span between body edge and pad un-banded — the east
    label candidate starts just past the crosshair, crosses the REAL outline
    at x = +2, meets nothing before the pads out at ±14, and is accepted
    straight through the body edge. This board is exactly that shape: a 4 mm
    square body, two pads 14 mm out, a clear centre row.

    The body edges below are HAND-STATED from the fixture (a ±2 mm square on
    a part at (30, 12), y negated into the emitted frame) — not read from any
    module geometry."""
    def pad(number: str, x: float) -> dict:
        return {"number": number, "type": "smd", "shape": "rect",
                "position": {"x": x, "y": 0.0},
                "size": {"width": 1.6, "height": 1.6},
                "layers": ["F.Cu", "F.Mask", "F.Paste"]}

    board = _compiled_dict({
        "version": 1, "name": "BodyBand", "width_mm": 60, "height_mm": 24,
        "origin": {"x_mm": 0, "y_mm": 0}, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "U1", "footprint": "Nowhere:NotAPart", "value": "",
             "x_mm": 30.0, "y_mm": 12.0, "rotation_deg": 0, "layer": "top",
             "assembly": {"mpn": "C99999"},
             "pads": [pad("1", -14.0), pad("2", 14.0)],
             "graphics": [{"kind": "poly", "layer": "F.Fab", "width": 0.1,
                           "points": [{"x": -2.0, "y": -2.0},
                                      {"x": 2.0, "y": -2.0},
                                      {"x": 2.0, "y": 2.0},
                                      {"x": -2.0, "y": 2.0}]}]},
        ],
    })
    svg, _, _ = _rendered(board)
    box = _label_boxes(svg)["U1"]
    cx, cy, half = 30.0, -12.0, 2.0
    edges = [
        (cx - half, cy - half, cx + half, cy - half),  # south
        (cx - half, cy + half, cx + half, cy + half),  # north
        (cx - half, cy - half, cx - half, cy + half),  # west
        (cx + half, cy - half, cx + half, cy + half),  # east
    ]
    for x1, y1, x2, y2 in edges:
        band = (x1 - 0.07, y1 - 0.07, x2 + 0.07, y2 + 0.07)
        assert ap._overlap_area(box, band) == 0.0, (
            f"U1's label is drawn through its body outline at {band}")
