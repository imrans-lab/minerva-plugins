"""The board as a solid: is it closed, is it the right size, and are the holes
REAL holes?

Every oracle here is geometric and independent of how the mesh is built. That
matters more than usual for this piece: a slab whose normals are inverted, whose
bottom face is mirrored the wrong way, or whose bores are painted rather than cut
all LOOK like a board in a thumbnail. The defects only appear from an angle, or
on a viewer that culls back faces, which is nowhere near where they were made.

So the four questions asked below are asked the way a person with a mesh and no
source would ask them:

  * FIRE A RAY. Down a mounting hole it must hit nothing at all; through solid
    board it must hit exactly two surfaces, one going in and one coming out.
    Painting a hole onto the texture passes every colour test ever written and
    fails this one immediately.
  * WELD BY POSITION AND LOOK AT THE EDGES. A closed solid traverses every
    directed edge as often as its reverse, and — the part that balance alone
    does not say — joins exactly two triangles along each undirected edge. A
    missing bore wall, a face triangulated over a hole, a wall wound inside out,
    a rim split on one side of a seam and not the other break the first; a
    doubled skin, a coincident pair of opposite-facing triangles and two solids
    welded along one line all satisfy the first and break the second. The one
    licensed exception is a PINCH COLUMN: where a bore is exactly tangent to the
    outline the material closes to zero width, and the wall standing on that
    point really does carry four skins.
  * MEASURE THE AREA against the board DOCUMENT — 24 x 18 mm, one 3 x 6 mm
    cutout — minus the analytic area of the circles that were drilled.
  * MEASURE A SLOT'S OPENING. It has to come out 7 x 2 mm, not round.

THE FIXTURE is the shipped coupon (``testdata/coupon_jlc1.yaml``) with one
mounting hole added, because the coupon already carries an off-centre cutout,
five vias and five through-hole pad drills, and the mounting hole is the case
the export exists for — the one a person checks an enclosure boss against. The
slot and oval cases are built by replacing the compiled board's holes directly:
``compile_board`` refuses a non-round drill today (its v1 round-hole subset), so
the IR is the only place those shapes can currently come from.
"""

from __future__ import annotations

import copy
import math
from dataclasses import replace
from pathlib import Path

import pytest
import yaml

from pcb_worker import texture_bake
from pcb_worker.board_drills import DrillOrigin, drill_openings
from pcb_worker.board_region import (board_regions, cutout_rings, drill_rings,
                                     outline_ring)
from pcb_worker.compile_board import compile_board
from pcb_worker.earcut import signed_area
from pcb_worker.resolved_board import (
    HoleKind,
    OvalHole,
    ResolutionSuccess,
    ResolvedHole,
    SlotHole,
)
from pcb_worker.substrate_mesh import (SubstrateMeshError, _check_closed,
                                       build_substrate_mesh)

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"

BOARD_W_MM, BOARD_H_MM = 24.0, 18.0        # the coupon's own outline
CUTOUT_AREA_MM2 = 3.0 * 6.0                # x 10.8..13.8 by y 5..11
# The coupon states NO fabrication block, so this is the compiler's default
# finished thickness — written as a literal rather than imported, so a
# changed default shows up here as a failure instead of following along.
ORDERED_THICKNESS_MM = 1.6

#: The mounting hole this suite adds — 3.2 mm, in the clear corner at (21, 15).
MOUNT_MM = (21.0, 15.0)
MOUNT_DIAMETER_MM = 3.2
MOUNT_ID = "hole:0123456789abcdef0123456789abcdef"

#: Board points that are solid on the coupon: FID1's land, and empty laminate
#: away from every drill, cutout and the mounting hole.
SOLID_MM = ((2.0, 2.0), (6.0, 15.0))

#: A pyclipper round join is INSCRIBED in the true circle, so a cut bore is
#: always a shade smaller than the nominal drill and never larger. At the 0.005
#: mm arc tolerance the region uses, the coupon's ten bores come out 0.9% under
#: their analytic area; 1.5% is that with room, and the ONE-SIDED assertion
#: below is the part that matters — over-cutting would remove board that is
#: really there.
BORE_AREA_UNDERCUT_LIMIT = 0.015


def _compiled(board: dict):
    result = compile_board(copy.deepcopy(board))
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _coupon_with_mounting_hole():
    board = yaml.safe_load(COUPON.read_text(encoding="utf-8"))
    board["mounting_holes"] = [{
        "id": MOUNT_ID,
        "x_mm": MOUNT_MM[0], "y_mm": MOUNT_MM[1],
        "diameter_mm": MOUNT_DIAMETER_MM, "plated": False,
    }]
    return _compiled(board)


# ---------------------------------------------------------------------------
# Oracles. Deliberately written against the mesh alone — positions and index
# triples — so none of them can inherit a mistake from the builder.
# ---------------------------------------------------------------------------


def _triangle(mesh, tri):
    return tuple(mesh.positions[i] for i in tri)


def _directed_edges(mesh) -> dict[tuple, int]:
    """Directed edges of the whole mesh, welded by exact position.

    Welding by POSITION rather than by index is the point: faces and walls
    deliberately keep separate vertices so their normals stay flat, so index
    topology is open by construction while the SOLID is closed.
    """
    counts: dict[tuple, int] = {}
    for tri in mesh.triangles:
        a, b, c = _triangle(mesh, tri)
        for edge in ((a, b), (b, c), (c, a)):
            counts[edge] = counts.get(edge, 0) + 1
    return counts


def _pinch_columns(mesh) -> list[tuple]:
    """Undirected edges carrying MORE than two triangles, welded by position.

    On a legitimate board every one of these is a wall column standing where the
    material closes to zero width, so the oracle also insists on the shape: both
    ends over the same board point, and spanning the whole thickness.
    """
    counts: dict[tuple, int] = {}
    for edge, n in _directed_edges(mesh).items():
        key = tuple(sorted(edge))
        counts[key] = counts.get(key, 0) + n
    crowded = [edge for edge, n in counts.items() if n > 2]
    for (ax, ay, az), (bx, by, bz) in crowded:
        assert (ax, az) == (bx, bz), "a crowded edge that is not a column"
        assert {ay, by} == {0.0, ORDERED_THICKNESS_MM}, "not the full thickness"
    return crowded


def _signed_volume(mesh) -> float:
    """Divergence-theorem volume. Positive iff the surface faces outward."""
    total = 0.0
    for tri in mesh.triangles:
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = _triangle(mesh, tri)
        total += (ax * (by * cz - bz * cy)
                  - ay * (bx * cz - bz * cx)
                  + az * (bx * cy - by * cx))
    return total / 6.0


def _area(mesh, triangles) -> float:
    total = 0.0
    for tri in triangles:
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = _triangle(mesh, tri)
        ux, uy, uz = bx - ax, by - ay, bz - az
        vx, vy, vz = cx - ax, cy - ay, cz - az
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        total += 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz)
    return total


def _hits_along_the_bore_axis(mesh, x_mm: float, y_mm: float) -> int:
    """Triangles a ray fired UP through board point ``(x, y)`` crosses.

    The ray starts below the board and runs along +Y, which is a drill's axis:
    Moller-Trumbore, counting every crossing rather than stopping at the first,
    because "meets two surfaces" is the assertion.
    """
    origin = (x_mm, -1.0, y_mm)
    direction = (0.0, 1.0, 0.0)
    hits = 0
    for tri in mesh.triangles:
        p0, p1, p2 = _triangle(mesh, tri)
        e1 = tuple(p1[i] - p0[i] for i in range(3))
        e2 = tuple(p2[i] - p0[i] for i in range(3))
        h = (direction[1] * e2[2] - direction[2] * e2[1],
             direction[2] * e2[0] - direction[0] * e2[2],
             direction[0] * e2[1] - direction[1] * e2[0])
        det = sum(e1[i] * h[i] for i in range(3))
        if abs(det) < 1e-12:
            continue
        inv = 1.0 / det
        s = tuple(origin[i] - p0[i] for i in range(3))
        u = inv * sum(s[i] * h[i] for i in range(3))
        if u < 0.0 or u > 1.0:
            continue
        q = (s[1] * e1[2] - s[2] * e1[1],
             s[2] * e1[0] - s[0] * e1[2],
             s[0] * e1[1] - s[1] * e1[0])
        v = inv * sum(direction[i] * q[i] for i in range(3))
        if v < 0.0 or u + v > 1.0:
            continue
        if inv * sum(e2[i] * q[i] for i in range(3)) > 1e-9:
            hits += 1
    return hits


# ---------------------------------------------------------------------------


def test_the_slab_is_closed_and_holds_the_volume_it_kept_at_the_ordered_thickness():
    """MUTATION THIS CATCHES: a missing bore wall, a face triangulated straight
    over a hole, a wall wound inside out, an inverted normal, or a thickness
    taken from anywhere but the board's ordered fabrication block.

    ORACLE: a closed orientable solid has every directed edge exactly once with
    its reverse present, and its divergence-theorem volume is positive and equal
    to the area of one face times the distance between the faces — 1.6 mm here,
    the default the compiler resolves for a board that ordered no thickness.
    The second half of the test orders a different one and checks the slab
    followed, which is what proves the value is read rather than assumed.
    """
    mesh = build_substrate_mesh(_coupon_with_mounting_hole())
    assert mesh.thickness_mm == ORDERED_THICKNESS_MM

    edges = _directed_edges(mesh)
    assert [edge for edge, count in edges.items() if count != 1] == []
    assert [edge for edge in edges if (edge[1], edge[0]) not in edges] == []
    assert _pinch_columns(mesh) == []     # nothing on this board touches itself

    face_area = _area(mesh, mesh.top_triangles)
    assert abs(_area(mesh, mesh.bottom_triangles) - face_area) < 1e-9 * face_area
    volume = _signed_volume(mesh)
    assert volume > 0.0                       # outward, not inside out
    assert abs(volume - face_area * ORDERED_THICKNESS_MM) < 1e-6 * volume

    # The faces sit ON the ordered thickness, and a different order moves them.
    def face_heights(triangles) -> set[float]:
        return {mesh.positions[i][1] for tri in triangles for i in tri}

    assert face_heights(mesh.top_triangles) == {ORDERED_THICKNESS_MM}
    assert face_heights(mesh.bottom_triangles) == {0.0}

    board = _coupon_with_mounting_hole()
    thinner = build_substrate_mesh(
        replace(board, fabrication=replace(board.fabrication, thickness_mm=0.8)))
    assert thinner.thickness_mm == 0.8
    assert abs(_signed_volume(thinner) - volume / 2.0) < 1e-6 * volume


def test_the_faces_keep_the_outline_less_exactly_what_was_drilled():
    """MUTATION THIS CATCHES: a hole that is drawn but not cut, a hole cut at the
    wrong radius, a cutout ignored, a millimetre/inch or radius/diameter slip.

    ORACLE: the coupon's document says 24 x 18 mm with one 3 x 6 mm cutout, and
    every drill in it is round, so the material left is
    ``432 - 18 - sum(pi r^2)``. The bores are inscribed polygons, so the measured
    cut must come in UNDER that analytic figure — never over — and by less than
    a percent and a half.
    """
    board = _coupon_with_mounting_hole()
    mesh = build_substrate_mesh(board)

    assert abs(signed_area(outline_ring(board))) == BOARD_W_MM * BOARD_H_MM
    assert sum(abs(signed_area(ring)) for ring in cutout_rings(board)) == CUTOUT_AREA_MM2

    openings = drill_openings(board)
    assert all(opening.is_round for opening in openings)
    analytic_bores = sum(math.pi * opening.radius_mm ** 2 for opening in openings)

    cut = BOARD_W_MM * BOARD_H_MM - CUTOUT_AREA_MM2 - _area(mesh, mesh.top_triangles)
    assert cut <= analytic_bores
    assert cut >= analytic_bores * (1.0 - BORE_AREA_UNDERCUT_LIMIT)


def test_a_ray_down_a_bore_meets_nothing_and_a_ray_through_the_board_meets_two_faces():
    """MUTATION THIS CATCHES: the whole "paint the holes instead" failure mode —
    a slab with the holes only in its texture passes every other check here.

    ORACLE: a drill is a hole through the material. Fire along its axis and
    there is nothing to hit; fire 0.05 mm outside its rim, or anywhere solid, and
    you cross the two faces exactly. The cutout is the same statement for an
    opening that is not drilled.
    """
    board = _coupon_with_mounting_hole()
    mesh = build_substrate_mesh(board)

    for (x, y) in SOLID_MM:
        assert _hits_along_the_bore_axis(mesh, x, y) == 2

    assert _hits_along_the_bore_axis(mesh, *MOUNT_MM) == 0
    assert _hits_along_the_bore_axis(mesh, 12.3, 8.0) == 0        # inside the cutout

    openings = drill_openings(board)
    assert {o.origin for o in openings} == {DrillOrigin.BOARD_HOLE, DrillOrigin.PAD,
                                            DrillOrigin.VIA}
    for opening in openings:
        cx, cy = opening.core[0]
        assert _hits_along_the_bore_axis(mesh, cx, cy) == 0, opening.id
        # Just outside the same bore the board is back — so the hole is the size
        # of the drill and not an arbitrary crater.
        assert _hits_along_the_bore_axis(mesh, cx + opening.radius_mm + 0.05, cy) == 2, \
            opening.id


def test_a_slot_is_cut_as_a_slot_and_a_rotated_oval_turns_the_way_the_worker_turns():
    """MUTATION THIS CATCHES: an oval or slot approximated by a circle, an oval
    laid along the wrong local axis, or a rotation applied with the wrong sign —
    which every multiple of 90 degrees hides under the shape's own symmetry.

    ORACLE: a 5 mm slot path swept by a 2 mm width is a 7 x 2 mm stadium, and a
    ray through the middle of it misses while a ray 0.05 mm outside its flank
    hits. A 4 x 1 oval turned 90 degrees measures 1 x 4. Turned 45, its far end
    must move UP the board (toward smaller Y), because this worker rotates
    counter-clockwise on a Y-down canvas — the convention
    ``geometry.rotate_local_offset`` owns and every consumer shares.
    """
    board = _coupon_with_mounting_hole()

    slot = ResolvedHole(id="hole:slot", plated=False, kind=HoleKind.NPTH,
                        feature=SlotHole(path=((4.0, 15.0), (9.0, 15.0)), width_mm=2.0))
    mesh = build_substrate_mesh(replace(board, holes=(slot,)))
    for x in (4.0, 6.5, 9.0):                      # along the slot: open
        assert _hits_along_the_bore_axis(mesh, x, 15.0) == 0
    for y in (15.0 - 1.05, 15.0 + 1.05):           # just outside its flanks: solid
        assert _hits_along_the_bore_axis(mesh, 6.5, y) == 2
    assert _hits_along_the_bore_axis(mesh, 9.0 + 1.05, 15.0) == 2   # past its end

    def ring_of(feature) -> tuple:
        hole = ResolvedHole(id="hole:oval", plated=False, kind=HoleKind.NPTH,
                            feature=feature)
        one = replace(board, holes=(hole,))
        rings = drill_rings(one, tuple(o for o in drill_openings(one)
                                       if o.origin is DrillOrigin.BOARD_HOLE))
        assert len(rings) == 1
        return rings[0]

    def extent(ring) -> tuple[float, float]:
        xs = [p[0] for p in ring]
        ys = [p[1] for p in ring]
        return (max(xs) - min(xs), max(ys) - min(ys))

    slot_ring = ring_of(SlotHole(path=((4.0, 15.0), (9.0, 15.0)), width_mm=2.0))
    width, height = extent(slot_ring)
    assert abs(width - 7.0) < 0.02 and abs(height - 2.0) < 0.02
    assert abs(abs(signed_area(slot_ring)) - (5.0 * 2.0 + math.pi)) < 0.05

    flat = extent(ring_of(OvalHole(position=(12.0, 9.0), width_mm=4.0, height_mm=1.0,
                                   rotation_deg=0.0)))
    turned = extent(ring_of(OvalHole(position=(12.0, 9.0), width_mm=4.0, height_mm=1.0,
                                     rotation_deg=90.0)))
    assert abs(flat[0] - 4.0) < 0.02 and abs(flat[1] - 1.0) < 0.02
    assert abs(turned[0] - 1.0) < 0.02 and abs(turned[1] - 4.0) < 0.02

    diagonal = ring_of(OvalHole(position=(12.0, 9.0), width_mm=4.0, height_mm=1.0,
                                rotation_deg=45.0))
    assert max(diagonal, key=lambda p: p[0])[1] < 9.0


def test_the_two_faces_are_registered_where_the_bake_paints_them():
    """MUTATION THIS CATCHES: a UV flip, a bottom face mirrored on Y instead of
    X (or not mirrored at all), a scale mismatch between mesh and texture — the
    class of defect that produces a perfectly plausible, BACKWARDS board.

    ORACLE: the bake is an independent consumer of the same registration, and it
    punches every bore out of the image's ALPHA. So the UV this mesh gives a
    drill's centre must land on a TRANSPARENT texel of that side's baked image,
    and a known solid point on an opaque one. If either the mesh or the texture
    moved, the two stop agreeing. The corners are checked outright: the board's
    top-left is u=0 on the top face and u=1 on the bottom, mirrored on X only.
    """
    board = _coupon_with_mounting_hole()
    mesh = build_substrate_mesh(board)
    baked = texture_bake.bake_board(board)

    assert mesh.top_frame == baked["top"].frame
    assert mesh.bottom_frame == baked["bottom"].frame

    assert mesh.top_frame.uv(0.0, 0.0) == (0.0, 0.0)
    assert mesh.bottom_frame.uv(0.0, 0.0) == (1.0, 0.0)
    assert mesh.top_frame.uv(BOARD_W_MM, 0.0) == (1.0, 0.0)
    assert mesh.bottom_frame.uv(BOARD_W_MM, 0.0) == (0.0, 0.0)
    assert mesh.top_frame.uv(0.0, BOARD_H_MM) == (0.0, 1.0)
    assert mesh.bottom_frame.uv(0.0, BOARD_H_MM) == (1.0, 1.0)

    def alpha_at(side: str, x_mm: float, y_mm: float) -> int:
        frame = mesh.frame_for(side)
        u, v = frame.uv(x_mm, y_mm)
        column = min(frame.width_px - 1, int(u * frame.width_px))
        row = min(frame.height_px - 1, int(v * frame.height_px))
        return baked[side].image.getchannel("A").getpixel((column, row))

    for side in ("top", "bottom"):
        for opening in drill_openings(board):
            cx, cy = opening.core[0]
            assert alpha_at(side, cx, cy) == 0, (side, opening.id)
        for (x, y) in SOLID_MM:
            assert alpha_at(side, x, y) == 255, (side, x, y)


# ---------------------------------------------------------------------------
# The shapes that are LEAST like the coupon. Every case below is a board whose
# openings interact with each other or with the outline, which is where a
# region stops being "a rectangle with discs punched out of it" and where the
# builder's postconditions have to earn their place.
# ---------------------------------------------------------------------------


def _with_mounting_holes(*holes) -> object:
    """The coupon plus arbitrary mounting holes, compiled."""
    board = yaml.safe_load(COUPON.read_text(encoding="utf-8"))
    board["mounting_holes"] = [
        {"id": f"hole:{index:032x}", "x_mm": x, "y_mm": y,
         "diameter_mm": diameter, "plated": False}
        for index, (x, y, diameter) in enumerate(holes, start=1)]
    return _compiled(board)


def _closed_and_solid(mesh, board, *, pinch_columns: int = 0) -> float:
    """Assert the mesh bounds the material the boolean says is left, and return
    that area. The oracle is :mod:`board_region`, which is a different
    computation on the same document — an exact integer boolean, not a
    triangulation — so agreement is evidence rather than a tautology.

    ``pinch_columns`` is how many places the board is expected to close to zero
    width. Stating the number rather than tolerating any is the point: those are
    the only edges allowed to carry more than two triangles, so an unexpected one
    is a doubled wall wearing a legitimate board's clothes.
    """
    edges = _directed_edges(mesh)
    assert [e for e, n in edges.items() if edges.get((e[1], e[0]), 0) != n] == [], \
        "the surface does not bound a solid"
    assert len(_pinch_columns(mesh)) == pinch_columns, \
        "the surface meets itself somewhere the material does not pinch"

    expected = sum(region.area_mm2() for region in board_regions(board))
    face = _area(mesh, mesh.top_triangles)
    assert abs(face - expected) <= 1e-9 * expected, \
        f"the faces cover {face} mm^2 of the {expected} mm^2 the board kept"
    volume = _signed_volume(mesh)
    assert volume > 0.0
    assert abs(volume - expected * ORDERED_THICKNESS_MM) <= 1e-9 * volume
    return expected


def test_a_bore_tangent_to_the_outline_still_closes_the_skin():
    """THE DEFECT THIS CAUGHT, and the reason it is worth its own case: a bore
    that touches the board edge at EXACTLY one point puts a vertex in the middle
    of an outline edge. The face is then triangulated to two half-edges there
    while the outline RING still describes one long one, so a wall raised on the
    ring spanned a seam the face had already split — a hairline crack down the
    side of the board, in a mesh that renders perfectly and holds no volume.
    Walls are read off the triangulation now, which cannot make that mistake.

    ORACLE: 1.59963 mm is where the INSCRIBED bore polygon of a 3.2 mm hole puts
    its leftmost vertex exactly on x = 0 (the offset is exact integer nanometres,
    so this is a construction, not a coincidence). The board is pinched to zero
    width there — a real, legal shape — so ONE wall column carries four skins
    instead of two, and its volume must still be the kept area times the ordered
    thickness. Exactly one: the licence is for the place the rim closes on
    itself, not a general relaxation, and the sliver case 0.4 um away has none.

    The 0.4 um sliver case is the same geometry one nanometre either side of the
    pinch, and it must come out just as solid.
    """
    for centre_x, pinches in ((1.59963, 1), (1.6, 0)):
        board = _with_mounting_holes((centre_x, 9.0, MOUNT_DIAMETER_MM))
        mesh = build_substrate_mesh(board)
        _closed_and_solid(mesh, board, pinch_columns=pinches)

        # It is a HOLE, not a bite out of the rim: the board is still there on
        # the far side of the bore, and gone at its centre. (5, 9) is clear of
        # every other drill on the coupon.
        assert _hits_along_the_bore_axis(mesh, centre_x, 9.0) == 0
        assert _hits_along_the_bore_axis(mesh, 5.0, 9.0) == 2


def test_two_overlapping_bores_are_cut_as_the_one_opening_they_make():
    """MUTATION THIS CATCHES: rings fed to the triangulator without the boolean
    — two overlapping hole rings are undefined input to ear clipping, and the
    plausible-looking output is a web of material across the middle of an
    opening that is not there on the real board.

    ORACLE: two 3.2 mm bores 1.5 mm apart overlap, so what is left is ONE
    opening 4.7 mm wide, and the material between the two centres is gone. The
    region count says the boolean merged them; the ray says the merge reached
    the geometry.
    """
    board = _with_mounting_holes((6.0, 9.0, MOUNT_DIAMETER_MM),
                                 (7.5, 9.0, MOUNT_DIAMETER_MM))
    mesh = build_substrate_mesh(board)
    _closed_and_solid(mesh, board)

    merged = [hole for region in board_regions(board) for hole in region.holes
              if min(p[0] for p in hole) < 5.0 < max(p[0] for p in hole)]
    assert len(merged) == 1, "the two bores were not merged into one opening"
    span = max(p[0] for p in merged[0]) - min(p[0] for p in merged[0])
    assert abs(span - (1.5 + MOUNT_DIAMETER_MM)) < 0.02, f"the opening is {span} mm wide"

    for x in (6.0, 6.75, 7.5):                 # both centres AND the waist
        assert _hits_along_the_bore_axis(mesh, x, 9.0) == 0, x
    assert _hits_along_the_bore_axis(mesh, 7.5 + 1.7, 9.0) == 2


#: A tetrahedron's four outward faces, as indices into ``(v0, v1, v2, v3)``.
#: Every undirected edge appears exactly twice, once each way — so a tetra on
#: its own is closed, balanced AND a proper skin, and any misbehaviour below
#: comes from how two of them are put together rather than from the shape.
TETRAHEDRON = ((0, 1, 2), (0, 2, 3), (0, 3, 1), (1, 3, 2))


def _surface(mesh, positions, triangles):
    """``mesh`` re-skinned with a hand-built surface, parallel arrays intact."""
    return replace(mesh,
                   positions=tuple(positions),
                   normals=tuple((0.0, 1.0, 0.0) for _ in positions),
                   uvs=tuple((0.0, 0.0) for _ in positions),
                   top_triangles=(), bottom_triangles=(),
                   edge_triangles=tuple(triangles))


def test_a_surface_that_balances_but_is_not_a_skin_is_refused():
    """THE FINDING THIS CLOSES, and the reason it is the important one: "every
    directed edge is traversed as often as its reverse" was accepted as the
    closure rule, and it is necessary but NOT sufficient. It is a count, and a
    broken mesh can make counts agree.

    ORACLE: two surfaces that pass balance and are not solids anybody can make.

      * A DOUBLED SKIN — the real coupon slab with every triangle drawn twice.
        Every count doubles, reverses included, so balance is perfect. The
        material is described twice; a volume computed from it is twice the
        board.
      * TWO SOLIDS WELDED ALONG ONE LINE — two tetrahedra sharing one edge and
        nothing else. Each is closed and correctly wound, so every directed edge
        still matches its reverse; the shared edge carries four triangles, which
        is a non-manifold join and not a board.

    Both are asserted to PASS the old balance rule first, so the test cannot
    quietly stop demonstrating what it was written for. The tangent-bore case
    above is the other half of the statement: the licensed pinch still passes.
    """
    slab = build_substrate_mesh(_coupon_with_mounting_hole())

    doubled = replace(slab,
                      top_triangles=slab.top_triangles * 2,
                      bottom_triangles=slab.bottom_triangles * 2,
                      edge_triangles=slab.edge_triangles * 2)
    edges = _directed_edges(doubled)
    assert [e for e, n in edges.items() if edges.get((e[1], e[0]), 0) != n] == [], \
        "the doubled skin was supposed to BALANCE — otherwise it proves nothing"
    assert abs(_signed_volume(doubled) - 2.0 * _signed_volume(slab)) < 1e-9
    with pytest.raises(SubstrateMeshError) as refusal:
        _check_closed(doubled)
    assert "same skin more than once" in str(refusal.value)

    # (0,0,0)-(1,0,0) is the shared edge; the two apex pairs sit on opposite
    # sides of the y = z = 0 line, so the tetrahedra meet along it and nowhere
    # else. The edge is horizontal, so it is not a wall column under any
    # pinch licence.
    points = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0),
              (0.0, 1.0, 0.0), (0.0, 0.0, 1.0),        # tetra A apexes
              (0.0, -1.0, 0.0), (0.0, 0.0, -1.0)]      # tetra B apexes
    welded = _surface(slab, points, [
        tuple((0, 1, 2, 3)[i] for i in face) for face in TETRAHEDRON
    ] + [
        tuple((0, 1, 4, 5)[i] for i in face) for face in TETRAHEDRON
    ])
    edges = _directed_edges(welded)
    assert [e for e, n in edges.items() if edges.get((e[1], e[0]), 0) != n] == [], \
        "the welded pair was supposed to BALANCE — otherwise it proves nothing"
    assert edges[(points[0], points[1])] == 2      # four skins on one edge
    with pytest.raises(SubstrateMeshError) as refusal:
        _check_closed(welded)
    assert "join more than two triangles" in str(refusal.value)

    # And the rule is not vacuous: one tetrahedron alone is a fine little solid.
    _check_closed(_surface(slab, points[:4], TETRAHEDRON))


def test_an_opening_that_consumes_the_whole_board_is_refused_not_exported():
    """MUTATION THIS CATCHES: the empty mesh. Subtracting an opening larger than
    the outline leaves NO region, and a builder that loops over regions and
    returns what it has produces a mesh with no triangles — which a writer
    happily turns into a valid, empty model file that a person opens and sees
    nothing in. "There is no board" is a refusal, not an export.
    """
    with pytest.raises(SubstrateMeshError) as refusal:
        build_substrate_mesh(_with_mounting_holes((12.0, 9.0, 60.0)))
    assert "no material left" in str(refusal.value)
