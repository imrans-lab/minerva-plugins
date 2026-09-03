"""Parts placed in the scene by the position file's own transform.

THE ORACLES, and why each is one
--------------------------------
* THE CPL ITSELF. ``assembly_outputs.emit`` on the same fixture board the CPL
  suite uses (``assembly_orientation.yaml``), whose emitted rotations are
  hand-derived literals in that suite's header (300, 270, 270, 45). A part is
  placed here by the SAME ``PhysicalPlacement`` that row came from, so the test
  that matters is not "do they agree today" but "does perturbing the board move
  BOTH": a component moved, turned and flipped in the board dict must move,
  turn and flip in the CPL row AND in the seated model by the same amount.
* HAND-DERIVED LITERALS for the vendor frame. The model-to-canvas map was
  MEASURED against the vendor's own outline3D projections (see
  ``part_seat``'s header for the method); here it is pinned as numbers worked
  by hand from that stated map, never as the module's own expression re-run.
* THE COMMITTED CORPUS. ``C149504``'s payload really does carry a ``c_origin``
  1.41 mm from its own outline centre — the defect that made the outline the
  siting datum — so the parser's new fact is checked against real data.
* THE SEED LIBRARY, per footprint. Whether a courtyard EXISTS is asked of each
  fixture footprint before the prism basis is asserted; nothing assumes it.

NO NETWORK, NO MOCK OF ONE. The client used here serves the committed corpus
payloads and builds each model as a box of the extents the vendor's own
SVGNODE states, at a height the test chooses. It is a fixture data source
implementing the client's two-call surface, not a patched client.
"""

from __future__ import annotations

import json
import math

from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import assembly_outputs as ao
from pcb_worker import orientation_ledger as ol
from pcb_worker import part_models as pm
from pcb_worker import part_orientation as po
from pcb_worker import part_placement as pp
from pcb_worker import part_seat
from pcb_worker.compile_board import compile_board
from pcb_worker.refdes_anchor import courtyard_extent_from_definition
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess
from pcb_worker.wavefront_obj import Material, Mesh

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "testdata" / "assembly_boards" / "assembly_orientation.yaml"
VENDOR = HERE / "testdata" / "vendor_footprints"
HOUSE = "jlcpcb"

#: The fixture's emitted rotations, copied from test_assembly_orientation's
#: FIXTURE_CPL header table — literals, not the emitter's expression.
FIXTURE_ROTATION = {"U1": 300.0, "U2": 270.0, "J1": 270.0, "R1": 45.0}
#: Per-part model heights the fixture client builds, chosen so the tallest is
#: unambiguous and is NOT the first or last row.
HEIGHTS = {"C780769": 0.9, "C910544": 0.75, "C265102": 5.5, "C149504": 0.6,
           # The DevKit socket strip: 8.5 mm body above the board, 3.2 mm pins
           # below it, as the vendor's real model spans z [-3.2, 8.5].
           "C41376161": 11.7, "C4365033": 5.0}
CHILD_FIXTURE = HERE / "testdata" / "assembly_boards" / "assembly_child_footprint.yaml"


def _compiled(board: dict):
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError("fixture did not compile: " + ", ".join(
            d.code for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _board_dict(path: Path = FIXTURE) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _box_mesh(width: float, depth: float, height: float, z0: float = 0.0) -> Mesh:
    """A closed box in the MODEL frame — x in +-width/2, y in +-depth/2, z in
    [z0, z0 + height], the frame the vendor's OBJ files were measured to use —
    PLUS ONE LANDMARK: an off-centre vertex at (+width/4, +depth/4, z0 +
    height/2), inside the box so the bounding box (and so the siting) is
    unchanged, referenced by one extra triangle, and LAST in the vertex list.
    The landmark is what makes the mesh asymmetric: a reflected or wrongly
    turned part puts it somewhere else, where a symmetric box would not."""
    xs, ys = (-width / 2, width / 2), (-depth / 2, depth / 2)
    verts = tuple((x, y, z) for z in (z0, z0 + height) for y in ys for x in xs)
    faces = ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3))
    tris = tuple(t for a, b, c, d in faces for t in ((a, b, c), (a, c, d)))
    verts += ((width / 4, depth / 4, z0 + height / 2),)
    tris += ((0, 1, LANDMARK),)
    return Mesh(vertices=verts, triangles=tris, triangle_materials=("body",) * len(tris),
                materials={"body": Material(name="body", diffuse=(0.2, 0.2, 0.2))})


#: Index of the landmark vertex in every fixture mesh (eight box corners first).
LANDMARK = 8


class CorpusClient:
    """The client's two-call surface over the committed payloads."""

    def __init__(self, *, withhold=(), swap=(), renumber=(), heights=HEIGHTS):
        self.withhold, self.swap, self.heights = set(withhold), set(swap), heights
        self.renumber = set(renumber)

    def facts(self, part: str):
        path = VENDOR / f"{part}.json"
        if not path.exists():
            return pm.Absence(part, pm.REASON_NOT_FOUND, "not in the corpus")
        facts = pm.parse_component_payload(json.loads(path.read_text(encoding="utf-8")), part)
        if part in self.swap:
            facts = replace(facts, model=replace(facts.model, width_mm=facts.model.height_mm,
                                                 height_mm=facts.model.width_mm))
        if part in self.renumber:
            # The vendor's pads under numbers ours never uses: a drawing that is
            # NOT the one the ledger measured, with its geometry untouched.
            facts = replace(facts, pads=tuple(replace(p, number="X" + p.number)
                                              for p in facts.pads))
        return facts

    def model(self, facts):
        if facts.absent:
            return facts
        if facts.part in self.withhold:
            return pm.Absence(facts.part, pm.REASON_NO_MODEL, "withheld by the test")
        ref = facts.model
        return pm.PartModel(part=facts.part, uuid=ref.uuid,
                            mesh=_box_mesh(ref.width_mm, ref.height_mm,
                                           self.heights.get(facts.part, 1.0),
                                           z0=ref.z_mm))


def _place(board_dict: dict, *, client=None, ledger=None) -> tuple[dict, pp.PartPlacementReport]:
    board = _compiled(board_dict)
    emission = ao.emit(board, "jlc", orientation=ledger)
    report = pp.place_parts(board, emission, client=client or CorpusClient(), ledger=ledger)
    return {row.ref: row for row in emission.cpl}, report


def _centre_board_xy(part: pp.PlacedPart) -> tuple[float, float]:
    """The seated model's footprint centre in BOARD millimetres, read back off
    the scene through the axis convention (scene x, *, z) = board (x, y)."""
    xs = [p[0] for p in part.mesh.positions]
    zs = [p[2] for p in part.mesh.positions]
    return ((min(xs) + max(xs)) / 2.0, (min(zs) + max(zs)) / 2.0)


def _parts(report) -> dict:
    return {p.ref: p for p in report.parts}


# ---------------------------------------------------------------------------
# THE ONE-DERIVATION ORACLE
# ---------------------------------------------------------------------------


def test_a_perturbed_placement_moves_the_cpl_row_and_the_seated_model_together():
    """Move U1, turn J1 a quarter, flip R1 to the bottom — in the BOARD. Every
    change must show up in the position file AND in the scene, by the same
    amount, because both are read off one PhysicalPlacement.

    The rotation literal: a +90 in the board is counter-clockwise on a Y-down
    screen, which carries an offset (dx, dy) from the part's origin to
    (dy, -dx). Written out rather than computed with the geometry module, so a
    sign slip there would fail here instead of agreeing with itself."""
    rows0, report0 = _place(_board_dict())
    parts0 = _parts(report0)

    board = _board_dict()
    by_ref = {c["ref"]: c for c in board["components"]}
    by_ref["U1"]["x_mm"] += 3.0
    by_ref["U1"]["y_mm"] -= 2.0
    by_ref["J1"]["rotation_deg"] += 90
    by_ref["R1"]["layer"] = "bottom"
    rows1, report1 = _place(board)
    parts1 = _parts(report1)

    # U1 translated: CPL (X verbatim, Y negated) and the scene both move (3, -2).
    assert (rows1["U1"].x_mm - rows0["U1"].x_mm, rows1["U1"].y_mm - rows0["U1"].y_mm) \
        == pytest.approx((3.0, 2.0))
    c0, c1 = _centre_board_xy(parts0["U1"]), _centre_board_xy(parts1["U1"])
    assert (c1[0] - c0[0], c1[1] - c0[1]) == pytest.approx((3.0, -2.0))
    assert rows1["U1"].rotation_deg == rows0["U1"].rotation_deg

    # J1 turned: the row's rotation gains 90 and the seat centre swings about
    # the footprint origin (12, 22) by a quarter turn, (dx, dy) -> (dy, -dx).
    assert (rows1["J1"].rotation_deg - rows0["J1"].rotation_deg) % 360 == pytest.approx(90.0)
    ox, oy = 12.0, 22.0
    dx, dy = (v - o for v, o in zip(_centre_board_xy(parts0["J1"]), (ox, oy)))
    assert _centre_board_xy(parts1["J1"]) == pytest.approx((ox + dy, oy - dx), abs=1e-6)
    # ...and the CPL anchor swung the same way. The row is in the emitted
    # Y-UP frame (X verbatim, Y negated), so read it back into the board frame,
    # swing it, and negate Y again: (ox + ay, -(oy - ax)).
    ax, ay = rows0["J1"].x_mm - ox, -rows0["J1"].y_mm - oy
    assert (rows1["J1"].x_mm, rows1["J1"].y_mm) == pytest.approx((ox + ay, ax - oy), abs=1e-6)

    # R1 flipped: the row says bottom, and every vertex is below the underside.
    assert rows1["R1"].side == "bottom" and rows0["R1"].side == "top"
    assert parts1["R1"].side == "bottom"
    assert max(p[1] for p in parts1["R1"].mesh.positions) <= 0.0
    assert min(p[1] for p in parts0["R1"].mesh.positions) >= report0.board_thickness_mm


def test_the_seated_direction_is_the_cpl_rotation_on_both_sides():
    """The CPL states the rotation as a NUMBER; the scene applies it as POINTS
    (ledger offset in the local frame, then the placement transform). Turning
    the vendor's +X axis through the point chain must land on the number the
    file states — for the fixture's four top rows against their header
    literals, and for a bottom-side quarter-turn part against the literal the
    CPL suite derived by hand (TSOT-23-6 at 30 on the bottom -> 120)."""
    board = _compiled(_board_dict())
    emission = ao.emit(board, "jlc")
    ledger = ol.load_ledger()
    physicals = {p.ref: p for c in board.components for p in c.physical_placements}

    def seated_angle(row) -> float:
        offset = ledger.lookup(row.footprint_ref, HOUSE, row.house_part).offset_deg
        t = pp._transform_of(physicals[row.ref])
        o = t.point(po.rotate_ccw((0.0, 0.0), offset))
        x = t.point(po.rotate_ccw((1.0, 0.0), offset))
        # Counter-clockwise on a Y-down screen: the angle of (dx, -dy).
        return math.degrees(math.atan2(-(x[1] - o[1]), x[0] - o[0])) % 360.0

    for row in emission.cpl:
        assert row.rotation_deg == pytest.approx(FIXTURE_ROTATION[row.ref])
        assert seated_angle(row) == pytest.approx(row.rotation_deg, abs=1e-6), row.ref

    bottom = _board_dict()
    bottom["components"] = [c for c in bottom["components"] if c["ref"] == "U1"]
    bottom["components"][0]["layer"] = "bottom"
    board_b = _compiled(bottom)
    row = ao.emit(board_b, "jlc").cpl[0]
    assert row.rotation_deg == pytest.approx(120.0)
    physicals = {p.ref: p for c in board_b.components for p in c.physical_placements}
    assert seated_angle(row) == pytest.approx(120.0, abs=1e-6)


def test_a_transform_that_is_not_the_cpls_is_refused():
    """The anchor re-derivation is the runtime guard for the whole property. A
    placement whose anchor the rebuilt transform cannot reproduce is refused by
    name, not drawn."""
    board = _compiled(_board_dict())
    emission = ao.emit(board, "jlc")
    component = next(c for c in board.components if c.ref == "U1")
    physical = component.physical_placements[0]
    forged = replace(physical, anchor=(physical.anchor[0] + 0.5, physical.anchor[1]))
    forged_component = replace(component, physical_placements=(forged,))
    forged_board = replace(board, components=tuple(
        forged_component if c.ref == "U1" else c for c in board.components))
    with pytest.raises(pp.PartPlacementError, match="U1"):
        pp.place_parts(forged_board, emission, client=CorpusClient())


# ---------------------------------------------------------------------------
# THE VENDOR FRAME — hand-derived from the measured map
# ---------------------------------------------------------------------------


def _reference(**over) -> pm.ModelReference:
    base = dict(uuid="0" * 32, title="t", origin_x_mm=0.0, origin_y_mm=0.0,
                rotation_deg=(0.0, 0.0, 0.0), z_mm=0.0, width_mm=2.0, height_mm=1.0,
                outline_bbox_mm=None)
    base.update(over)
    return pm.ModelReference(**base)


def test_model_to_canvas_negates_y_then_turns_counter_clockwise_onto_the_outline():
    """An asymmetric three-vertex model at c_rotation 90 with the outline
    centred at (5, 7). By hand: (mx, my) -> (mx, -my) -> ccw 90 on a Y-down
    screen (x, y) -> (y, -x), so (2, 0) -> (0, -2) and (0, 1) -> (-1, 0). The
    mapped box is x [-1, 0], y [-2, 0], centre (-0.5, -1); moving that centre to
    (5, 7) adds (5.5, 8). Heights: z 0.3 lifts everything by 0.3."""
    mesh = Mesh(vertices=((0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 0.5)),
                triangles=((0, 1, 2), (0, 1, 3)), triangle_materials=(None, None))
    ref = _reference(rotation_deg=(0.0, 0.0, 90.0), z_mm=0.3,
                     outline_bbox_mm=(4.5, 6.0, 5.5, 8.0), origin_x_mm=5.0, origin_y_mm=7.0)
    points, notes, remap = part_seat.model_to_canvas(ref, mesh)
    assert points == pytest.approx([(5.5, 8.0, 0.3), (5.5, 6.0, 0.3), (4.5, 8.0, 0.3),
                                    (5.5, 8.0, 0.8)])
    assert remap == {0: 0, 1: 1, 2: 2, 3: 3}
    assert notes == ()

    # The wrong Y sign or the wrong sense each put (2, 0) somewhere else.
    assert (5.5, 10.0, 0.3) not in [tuple(round(v, 6) for v in p) for p in points]


def test_a_stale_c_origin_is_reported_and_the_outline_wins():
    """The committed R0805 payload (C149504) is the real case: c_origin sits
    1.41 mm from the outline's own centre. The outline places the model on the
    pads; c_origin would put a 2.0 mm resistor 1.4 mm off them."""
    facts = CorpusClient().facts("C149504")
    ref = facts.model
    assert ref.outline_bbox_mm == pytest.approx((-1.0, -0.65, 1.0, 0.65), abs=1e-3)
    assert abs(ref.origin_x_mm - (-1.413)) < 1e-3
    points, notes, _ = part_seat.model_to_canvas(ref, _box_mesh(2.0, 1.3, 0.6))
    xs = [p[0] for p in points]
    assert (min(xs) + max(xs)) / 2.0 == pytest.approx(0.0, abs=1e-6)
    assert any(part_seat.NOTE_ORIGIN_DISAGREES in n for n in notes)

    # And a payload where the two agree raises no note: the S4B connector.
    ref = CorpusClient().facts("C265102").model
    _, notes, _ = part_seat.model_to_canvas(ref, _box_mesh(ref.width_mm, ref.height_mm, 5.5))
    assert notes == ()


def test_the_model_is_seated_by_its_lowest_point_not_its_origin():
    """A model authored with its underside at z = -0.62 (the TSOT-23-6 case)
    sits ON the board, not 0.62 mm into it, and says so."""
    mesh = Mesh(vertices=((0.0, 0.0, -0.62), (1.0, 0.0, -0.62), (0.0, 1.0, 0.27)),
                triangles=((0, 1, 2),), triangle_materials=(None,))
    points, notes, _ = part_seat.model_to_canvas(_reference(), mesh)
    assert min(p[2] for p in points) == pytest.approx(0.0)
    assert max(p[2] for p in points) == pytest.approx(0.89)
    assert any(part_seat.NOTE_MODEL_NOT_AT_ZERO in n for n in notes)


# ---------------------------------------------------------------------------
# PLACEHOLDERS, MARKS, HEIGHTS, ADVISORIES
# ---------------------------------------------------------------------------


def test_a_part_with_no_model_becomes_a_prism_on_the_box_its_footprint_declares():
    """Every fixture part's model withheld. Whether each footprint DRAWS a
    courtyard is asked of the compiled definition first, and the prism basis
    must match that answer per part. FID1 is unbought and is excluded, not
    drawn. No placeholder claims a height."""
    board = _compiled(_board_dict())
    emission = ao.emit(board, "jlc")
    report = pp.place_parts(board, emission,
                            client=CorpusClient(withhold=set(HEIGHTS)))
    parts = _parts(report)
    assert set(parts) == {"U1", "U2", "J1", "R1"}
    assert report.excluded == ("FID1",)
    for component in board.components:
        if component.ref not in parts:
            continue
        has_courtyard = courtyard_extent_from_definition(board.footprint_for(component)) is not None
        part = parts[component.ref]
        assert part.kind == pp.KIND_PLACEHOLDER
        assert part.prism_basis == (pp.PRISM_BASIS_COURTYARD if has_courtyard
                                    else pp.PRISM_BASIS_LANDS), component.ref
        assert part.height_basis == pp.HEIGHT_BASIS_NOMINAL
        assert part.marker is None
        assert set(part.mesh.triangle_materials) == {pp.PLACEHOLDER_MATERIAL}
        assert len(part.mesh.triangles) == 12
    assert {f["ref"] for f in report.fallbacks} == set(parts)
    assert all(f["reason"] == pm.REASON_NO_MODEL for f in report.fallbacks)
    assert set(report.unknown_height_refs) == set(parts)
    assert report.tallest == ()
    assert report.unverified == ()


def test_an_unmeasured_pair_is_placed_raw_and_marked_while_measured_pairs_are_not():
    """Drop U1's row from the shipped ledger. The CPL carries a refusal for U1;
    here U1 is drawn at its raw rotation under a marker post and named in the
    report; the other three stand unmarked and verified."""
    shipped = ol.load_ledger()
    without_u1 = shipped.with_measured(
        r for r in shipped.measured if r.part != "C780769")
    rows, report = _place(_board_dict(), ledger=without_u1)
    parts = _parts(report)
    u1 = parts["U1"]
    assert u1.kind == pp.KIND_MODEL
    assert u1.orientation == pp.ORIENTATION_UNVERIFIED
    assert u1.marker is not None
    assert set(u1.marker.triangle_materials) == {pp.UNVERIFIED_MARKER_MATERIAL}
    # The post clears the part: taller than the model by the stated margin.
    assert max(p[1] for p in u1.marker.positions) == pytest.approx(
        report.board_thickness_mm + HEIGHTS["C780769"] + pp.MARKER_CLEARANCE_MM)
    assert rows["U1"].rotation_deg == pytest.approx(30.0)   # raw, no offset
    assert [u["ref"] for u in report.unverified] == ["U1"]
    assert any(a["code"] == pp.ADVISORY_UNVERIFIED_MODEL and a["ref"] == "U1"
               for a in report.advisories)
    for ref in ("U2", "J1", "R1"):
        assert parts[ref].orientation == pp.ORIENTATION_VERIFIED
        assert parts[ref].marker is None


def test_the_tallest_part_per_side_is_named_and_placeholders_are_left_out():
    """J1 at 5.5 mm is the tallest top part by construction. Flip U2 to the
    bottom and it is the only bottom part, so it is the bottom's tallest. A
    part with no model appears in the unknown list, never in the tallest."""
    board = _board_dict()
    next(c for c in board["components"] if c["ref"] == "U2")["layer"] = "bottom"
    _, report = _place(board, client=CorpusClient(withhold={"C149504"}))
    assert report.tallest == ({"side": "bottom", "ref": "U2", "height_mm": 0.75},
                              {"side": "top", "ref": "J1", "height_mm": 5.5})
    assert report.unknown_height_refs == ("R1",)
    parts = _parts(report)
    assert parts["J1"].height_mm == pytest.approx(5.5)
    assert min(p[1] for p in parts["U2"].mesh.positions) == pytest.approx(-0.75)


def test_a_ledger_offset_a_quarter_turn_wrong_is_indicted_by_the_crosswise_model():
    """The S4B-PH connector is 12.0 x 8.6 and its lands are wider than deep;
    its pair measures 180 in the shipped ledger. Falsify that row to 90 and the
    seated model lies across our pads — the independent check on the ledger.
    With the shipped row it does not fire. The 3 x 3 VQFN and the 2.9 x 2.8
    TSOT-23-6 package are square and are named as undetectable rather than
    passed in silence — the TSOT because its vendor box is measured WITH its
    leads, which its own fab body (1.7 x 3.0) is not."""
    shipped = ol.load_ledger()
    wrong = shipped.with_measured(
        replace(r, offset_deg=90) if r.part == "C265102" else r for r in shipped.measured)
    _, report = _place(_board_dict(), ledger=wrong)
    crosswise = [a for a in report.advisories if a["code"] == pp.ADVISORY_CROSSWISE]
    assert [a["ref"] for a in crosswise] == ["J1"]
    assert "90" in crosswise[0]["detail"]

    _, report = _place(_board_dict())
    assert not [a for a in report.advisories if a["code"] == pp.ADVISORY_CROSSWISE]
    assert sorted(a["ref"] for a in report.advisories
                  if a["code"] == pp.ADVISORY_SQUARE) == ["U1", "U2"]


def test_a_swapped_vendor_extent_is_an_advisory_and_a_square_one_cannot_be():
    """Swap the R0805 package extent (2.0 x 1.3 -> 1.3 x 2.0) against our
    R_0805 fab body: the advisory fires. Unswapped, nothing fires — including
    on J1, whose vendor box (12.0 x 8.6, leads and latch included) is 0.9 mm
    deeper than our fab body (12.0 x 7.7) along ONE axis, which is ordinary and
    is not a swap. The check functions themselves say ``indeterminate`` for a
    square box rather than agreeing with it."""
    _, report = _place(_board_dict(), client=CorpusClient(swap={"C149504"}))
    extent = [a for a in report.advisories if a["code"] == pp.ADVISORY_EXTENT]
    assert [a["ref"] for a in extent] == ["R1"]

    _, report = _place(_board_dict())
    assert not [a for a in report.advisories if a["code"] == pp.ADVISORY_EXTENT]

    assert part_seat.extent_disagreement((12.0, 8.6), (12.0, 7.7)) is None
    assert part_seat.extent_disagreement((1.3, 2.0), (2.1, 1.35)) == "disagrees"
    assert part_seat.extent_disagreement((3.0, 3.0), (2.0, 4.0)) == part_seat.INDETERMINATE
    assert part_seat.crosswise((3.0, 3.0), (6.0, 2.0)) == part_seat.INDETERMINATE
    assert part_seat.crosswise((2.0, 6.0), (6.0, 2.0)) == "crosswise"
    assert part_seat.crosswise((6.0, 2.0), (6.0, 2.0)) is None


def test_the_datum_the_seat_uses_is_the_measurements_own():
    """``datum_offset`` at the ledger's angle reproduces the ``datum_offset_mm``
    the measurement reports for the same pair, for every corpus pair the
    fixture places — one rule, read twice."""
    board = _compiled(_board_dict())
    ledger = ol.load_ledger()
    client = CorpusClient()
    for component in board.components:
        parts = dict(component.assembly.house_parts)
        if HOUSE not in parts:
            continue
        part = parts[HOUSE]
        record = ledger.lookup(component.assembly.footprint_ref, HOUSE, part)
        ours = po.pad_field_from_definition(board.footprint_for(component))
        facts = client.facts(part)
        vendor = po.pad_field_from_vendor_pads(part, facts.pads)
        measured = po.measure_orientation(ours, vendor)
        assert measured.offset_deg == record.offset_deg, component.ref
        assert po.datum_offset(ours, vendor, record.offset_deg) == measured.datum_offset_mm


def test_a_socket_set_child_is_placed_on_its_own_strip_and_its_pins_go_through():
    """The DevKit socket set: one drawing, two 1x22 strips that each NAME their
    own footprint. Each child is checked against ITS OWN drawing (no skipped
    cross-check), the two seats sit the authored 22.86 mm apart, and the
    through-hole strip's model — 8.5 mm of body over 3.2 mm of pin, seated by
    its lowest point — stands 8.5 above the top face with its pins reaching
    3.2 below it. The strip is the tallest top part."""
    rows, report = _place(_board_dict(CHILD_FIXTURE))
    parts = _parts(report)
    assert {"U1S_A", "U1S_B"} <= set(parts)
    for ref in ("U1S_A", "U1S_B"):
        part = parts[ref]
        assert part.kind == pp.KIND_MODEL
        assert part.orientation == pp.ORIENTATION_VERIFIED, part.reason
        assert not any("skipped" in n for n in part.notes), part.notes
        top = report.board_thickness_mm
        assert max(p[1] for p in part.mesh.positions) == pytest.approx(top + 8.5, abs=1e-4)
        assert min(p[1] for p in part.mesh.positions) == pytest.approx(top - 3.2, abs=1e-4)
        assert part.anchor_delta_mm < 0.5, (ref, part.anchor_delta_mm)
    a, b = _centre_board_xy(parts["U1S_A"]), _centre_board_xy(parts["U1S_B"])
    assert math.dist(a, b) == pytest.approx(22.86, abs=1e-6)
    assert report.tallest == ({"side": "top", "ref": "U1S_A", "height_mm": 8.5},)
    assert not [a for a in report.advisories if a["code"] == pp.ADVISORY_CROSSWISE]


def test_the_landmark_lands_where_the_hand_derived_chain_says_on_both_sides():
    """THE PRODUCTION PATH, read back off the produced mesh. U2 is the VQFN pair
    whose ledger offset is 270, placed at rotation 0 at (20, 8); the fixture
    mesh's landmark is the model point (0.755, 0.755, 0.375).

    By hand, link by link, from the conventions part_seat states:
      model -> canvas   negate Y: (0.755, -0.755); c_rotation 0; the outline is
                        centred on the datum and the landmark is inside the box,
                        so no shift; h = 0.375.
      canvas -> local   rotate_ccw 270 on a Y-down screen is (x, y) -> (-y, x):
                        (0.755, 0.755). The vendor's pad centroid is ~1 um off
                        its datum, hence the 2 um tolerance.
      local -> board    TOP, rotation 0: (20.755, 8.755); scene y = t + 0.375.
                        BOTTOM, rotation 0: the local Y mirror FIRST gives
                        (0.755, -0.755) -> (20.755, 7.245); scene y = -0.375.
    Applying the offset with the wrong sign puts the landmark at local
    (-0.755, -0.755) -> board (19.245, 7.245) top; dropping the bottom mirror
    leaves it at (20.755, 8.755) on the bottom. Both are 1.5 mm off and fail."""
    _, top = _place(_board_dict())
    t = top.board_thickness_mm
    x, y, z = _parts(top)["U2"].mesh.positions[LANDMARK]
    assert (x, z) == pytest.approx((20.755, 8.755), abs=2e-3)
    assert y == pytest.approx(t + 0.375)

    board = _board_dict()
    next(c for c in board["components"] if c["ref"] == "U2")["layer"] = "bottom"
    rows, bottom = _place(board)
    assert rows["U2"].rotation_deg == pytest.approx(90.0)     # 0 - 270, hand-derived
    x, y, z = _parts(bottom)["U2"].mesh.positions[LANDMARK]
    assert (x, z) == pytest.approx((20.755, 7.245), abs=2e-3)
    assert y == pytest.approx(-0.375)


def test_every_seated_model_sits_within_a_millimetre_of_the_cpl_anchor():
    """The anchor delta is the cross-check that catches a discarded datum or a
    model sited off its pads. On the fixture every vendor body centre is within
    0.5 mm of our fab body centre (J1's is 0.41: the vendor's connector box is
    deeper than our fab outline by its latch), so a millimetre is headroom, not
    a licence."""
    _, report = _place(_board_dict())
    for part in report.parts:
        assert part.kind == pp.KIND_MODEL
        assert part.anchor_delta_mm < 1.0, (part.ref, part.anchor_delta_mm)


def test_a_verified_pair_whose_pads_no_longer_match_is_downgraded_and_marked():
    """Renumber the vendor's pads for R1 so no number is shared: the ledger
    still says 'aligned, 0' and the CPL row is still emitted, but the drawing
    is demonstrably not the one that was measured. The part must not be laid on
    the origin and still called verified: it is downgraded, marked, and named
    in the report with an advisory."""
    rows, report = _place(_board_dict(), client=CorpusClient(renumber={"C149504"}))
    r1 = _parts(report)["R1"]
    assert rows["R1"].rotation_deg == pytest.approx(45.0)     # the CPL is unaffected
    assert r1.kind == pp.KIND_MODEL
    assert r1.orientation == pp.ORIENTATION_UNVERIFIED
    assert r1.marker is not None
    assert [u["ref"] for u in report.unverified] == ["R1"]
    assert [a["ref"] for a in report.advisories if a["code"] == pp.ADVISORY_NO_SHARED_PADS] == ["R1"]
    for ref in ("U1", "U2", "J1"):
        assert _parts(report)[ref].orientation == pp.ORIENTATION_VERIFIED


def test_the_report_serializes_without_geometry():
    _, report = _place(_board_dict())
    doc = report.as_dict()
    assert {p["ref"] for p in doc["parts"]} == {"U1", "U2", "J1", "R1"}
    assert all("positions" not in p for p in doc["parts"])
    assert doc["tallest"][0]["ref"] == "J1"
    json.dumps(doc)  # JSON-clean for a worker reply
