"""Silk in the geometric-DRC projection (epoch CP2 station S4).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time at the boundary (S10), after the Codex round.

THE CLAIM THIS FILE DEFENDS is not "silk is projected" — it is "the checker and
the emitter see the SAME silk". Those come apart in exactly one way, and it is
the way that matters: a checker that harvests legend geometry independently can
clear a board whose fabricated legend violates the rule it just checked. That is
a false clean, and no amount of unit-testing the projection in isolation would
catch it, because both halves would be internally consistent and disagree with
each other.

So the load-bearing test here (``test_projection_and_emitter_agree_...``) drives
BOTH surfaces off the same compiled board and compares them, on a top-side board
AND on one with a component flipped to the back — the configuration where the
side/layer/mirror rules actually get exercised.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import gerber, silk_source
from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geometric import project_board, run_geometric_drc
from pcb_worker.resolved_board import ResolutionSuccess, Side

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"

# The coupon's silk-carrying fixture; flipping it is how the bottom-side paths
# get exercised without inventing a second board.
FLIPPABLE_REF = "LOGO1"


def _board(flip_logo: bool = False) -> dict:
    board = yaml.safe_load(COUPON.read_text(encoding="utf-8"))
    if flip_logo:
        for comp in board["components"]:
            if comp["ref"] == FLIPPABLE_REF:
                comp["layer"] = "bottom"
    return board


def _compiled(flip_logo: bool = False):
    result = compile_board(_board(flip_logo))
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _round_pt(pt) -> tuple:
    return (round(pt[0], 9), round(pt[1], 9))


def _emitter_silk(rb) -> dict:
    """Silk as the EMITTER will draw it, normalized for comparison.

    FRAME NOTE, because getting this wrong makes the comparison meaningless:
    ``gerber._harvest_ir`` returns AFTER ``to_gerber_frame()``, so these buckets
    are in the GERBER frame — every Y negated and every arc chirality flipped
    relative to the board frame. The projection is board-frame. `_projected_silk`
    below converts to match rather than pretending the two are already aligned.
    """
    g = gerber._harvest_ir(rb, 0.05)
    out: dict = {Side.TOP: [], Side.BOTTOM: []}
    buckets = (
        (Side.TOP, g.silk_lines, g.silk_circles, g.silk_polys, g.silk_arcs),
        (Side.BOTTOM, g.silk_lines_bot, g.silk_circles_bot, g.silk_polys_bot,
         g.silk_arcs_bot),
    )
    for side, lines, circles, polys, arcs in buckets:
        for (x1, y1, x2, y2, w) in lines:
            out[side].append(("line", _round_pt((x1, y1)), _round_pt((x2, y2)),
                              round(w, 9)))
        for (cx, cy, r, w) in circles:
            out[side].append(("circle", _round_pt((cx, cy)), round(r, 9),
                              round(w, 9)))
        for (pts, w, closed) in polys:
            out[side].append(("poly", tuple(_round_pt(q) for q in pts),
                              round(w, 9), closed))
        for (st, en, ct, orientation, w) in arcs:
            out[side].append(("arc", _round_pt(st), _round_pt(en),
                              _round_pt(ct), orientation, round(w, 9)))
    return {side: sorted(items, key=repr) for side, items in out.items()}


def _projected_silk(rb) -> dict:
    """The same silk as the CHECKER sees it, converted board frame -> gerber
    frame (negate Y; flip arc chirality, because a mirror reverses handedness)
    so it is directly comparable with :func:`_emitter_silk`."""
    out: dict = {Side.TOP: [], Side.BOTTOM: []}
    for prim in project_board(rb).silk:
        geom = prim.geometry
        if isinstance(geom, silk_source.SilkLine):
            out[prim.side].append(
                ("line", _round_pt((geom.x1, -geom.y1)),
                 _round_pt((geom.x2, -geom.y2)), round(geom.width, 9)))
        elif isinstance(geom, silk_source.SilkCircle):
            out[prim.side].append(
                ("circle", _round_pt((geom.cx, -geom.cy)),
                 round(geom.radius, 9), round(geom.width, 9)))
        elif isinstance(geom, silk_source.SilkPoly):
            out[prim.side].append(
                ("poly", tuple(_round_pt((x, -y)) for (x, y) in geom.points),
                 round(geom.width, 9), geom.closed))
        else:
            out[prim.side].append(
                ("arc", _round_pt((geom.start[0], -geom.start[1])),
                 _round_pt((geom.end[0], -geom.end[1])),
                 _round_pt((geom.center[0], -geom.center[1])),
                 "-" if geom.orientation == "+" else "+", round(geom.width, 9)))
    return {side: sorted(items, key=repr) for side, items in out.items()}


def _silk_counts(normalized: dict) -> tuple[int, int]:
    return len(normalized[Side.TOP]), len(normalized[Side.BOTTOM])


_SIDE_CASES = [
    # (pre_placed, component_top, authored_layer, expected_bucket, mirrored)
    (True,  True,  "F.SilkS", "top",    False),
    (True,  False, "B.SilkS", "bottom", False),
    # THE CASE THAT BROKE THE EMITTER. A bottom-placed footprint authoring
    # B.SilkS reaches the IR with its layer ALREADY FLIPPED to F.SilkS and its
    # geometry already mirrored. Under pre_placed the layer is authoritative, so
    # this belongs on the FRONT, unmirrored. The old heuristic read "F.SilkS +
    # bottom component" as loose labelling, mirrored it a second time and
    # bucketed it to the back — disagreeing with the DRC projection on both.
    (True,  False, "F.SilkS", "top",    False),
    # Loose path: footprint-local artwork, layer flips with the component.
    (False, True,  "F.SilkS", "top",    False),
    (False, True,  "B.SilkS", "bottom", False),
    (False, False, "F.SilkS", "bottom", True),
    (False, False, "B.SilkS", "top",    True),
]


@pytest.mark.parametrize("pre_placed,comp_top,layer,bucket,mirrored", _SIDE_CASES)
def test_emit_silk_resolves_side_from_the_declared_frame(
        pre_placed, comp_top, layer, bucket, mirrored):
    """The side/mirror rule, stated exhaustively over the inputs that decide it.

    WHY A TABLE AND NOT A HEURISTIC TEST. The rule this replaces tried to infer
    the caller's frame from the graphic's layer, which works for three of these
    seven rows and inverts on the fourth. A table makes the inversion visible:
    rows 2 and 3 have the SAME component side and DIFFERENT authored layers, and
    they must land on different buckets for opposite reasons.

    ``mirrored`` is checked as a coordinate fact, not a flag — a y-negation of
    the authored point is what the mirror does at identity placement, so the
    test can tell a real second mirror from a bookkeeping difference.
    """
    g = gerber._Geometry()
    graphic = {"layer": layer, "kind": "line",
               "start": [1.0, 2.0], "end": [3.0, 4.0], "width": 0.12}
    gerber._emit_silk(g, [graphic], 0.0, 0.0, 0.0, comp_top, "L1",
                      pre_placed=pre_placed)

    front, back = g.silk_lines, g.silk_lines_bot
    got, empty = (front, back) if bucket == "top" else (back, front)
    assert len(got) == 1, (
        f"expected the primitive on the {bucket} bucket; "
        f"front={len(front)} back={len(back)}")
    assert not empty, "the primitive was emitted onto BOTH sides"

    x1, y1, x2, y2, _w = got[0]
    expected_y = (-2.0, -4.0) if mirrored else (2.0, 4.0)
    assert (x1, x2) == (1.0, 3.0), "x must never be mirrored"
    assert (y1, y2) == expected_y, (
        "mirror applied when it should not have been" if not mirrored
        else "the local-Y mirror was not applied")


@pytest.mark.parametrize("flip_logo", [False, True],
                         ids=["all-top", "logo-on-back"])
def test_projection_and_emitter_agree_on_what_silk_is_on_the_board(flip_logo):
    """THE LOAD-BEARING TEST OF STATION S4.

    If these two ever disagree, a silk DFM check is measuring a different board
    than the fab receives — the checker clears artwork that is not what gets
    printed, or flags artwork that is never printed. Both directions are
    failures and neither is visible from inside either surface alone.

    Run on BOTH configurations on purpose. An all-top board would pass even if
    the side routing were completely broken, because everything would land in
    the one bucket both surfaces default to; the flipped case is what actually
    exercises layer-vs-side resolution and the mirror.
    """
    rb = _compiled(flip_logo)
    # FULL GEOMETRY, not cardinality: equal counts survive a
    # coordinate corruption that keeps primitives on the same side,
    # a width drift, and a flipped `closed` flag. Compare the actual
    # shapes.
    assert _projected_silk(rb) == _emitter_silk(rb)


def test_flipping_a_component_moves_silk_without_losing_any():
    """Conservation, which is a stronger statement than either side's count.

    A side-routing bug that dropped bottom geometry entirely would keep the
    two surfaces above in agreement (both would drop it) while quietly
    shrinking the board's legend. Totals catch that; per-side counts do not.

    The back-legend assertion is RELATIVE ("flipping adds back legend"), not
    absolute ("the unflipped coupon has none"). It was written absolute, which
    was true when written and is scheduled to stop being true: station S9 adds
    revision text to the coupon's own B.SilkS. An absolute zero here would fail
    at S9 for a reason having nothing to do with what this test is about, and
    the S9 author would be debugging a conservation test to land a silkscreen
    string. The relative form measures the same property and survives it.
    """
    top_only = _silk_counts(_projected_silk(_compiled(False)))
    flipped = _silk_counts(_projected_silk(_compiled(True)))
    assert flipped[1] > top_only[1], (
        f"flipping {FLIPPABLE_REF} added no back legend: "
        f"{top_only[1]} back primitives before, {flipped[1]} after")
    assert flipped[0] < top_only[0], (
        "flipping moved nothing OFF the front — the side routing is not "
        "reading the component's layer at all")
    assert sum(top_only) == sum(flipped), (
        f"silk was LOST in the flip: {sum(top_only)} primitives before, "
        f"{sum(flipped)} after — geometry should move between sides, not vanish")


def test_synthesized_designators_are_projected_not_just_authored_artwork():
    """A reference designator is in NO IR — it is generated from a stroke font
    at emission. A projection built only from PlacedGraphic would hand every
    silk rule a board with no designators on it, and silk-to-mask violations
    involving designator text (the common real case) would all read clean."""
    proj = project_board(_compiled())
    refdes = [p for p in proj.silk if p.origin == "refdes"]
    assert refdes, "no designator strokes reached the projection"
    # And they are attributed, so a finding can name the part it belongs to.
    assert all(p.ref for p in refdes)
    assert {p.ref for p in refdes} <= {c.ref for c in _compiled().components}


def test_projected_silk_carries_the_shared_owner_types_not_a_remodelled_copy():
    """The projection stores silk_source's own primitives. If this ever becomes
    a locally re-modelled shape, the two surfaces have stopped sharing a
    definition and the agreement test above degrades into a coincidence."""
    proj = project_board(_compiled())
    kinds = {silk_source.SilkLine, silk_source.SilkCircle,
             silk_source.SilkArc, silk_source.SilkPoly}
    assert proj.silk
    for prim in proj.silk:
        assert type(prim.geometry) in kinds
        assert prim.width_mm == prim.geometry.width


def test_bottom_silk_is_projected_on_the_side_the_compiler_flipped_it_to():
    """Side comes from the LAYER, which the compiler already flipped, and no
    second mirror is applied. Projecting by the component's side flag instead
    would be right here by luck and wrong for any board whose graphics the
    compiler did not flip."""
    rb = _compiled(flip_logo=True)
    proj = project_board(rb)
    logo = next(c for c in rb.components if c.ref == FLIPPABLE_REF)
    logo_silk = [p for p in proj.silk
                 if p.parent_id == logo.id and p.origin == "graphic"]
    assert logo_silk, "the flipped component contributed no legend geometry"
    assert all(p.side is Side.BOTTOM for p in logo_silk)
    # The compiler put them on B.SilkS; nothing downstream may re-decide that.
    assert all(g.layer.id == "B.SilkS" for g in logo.placed_graphics
               if silk_source.silk_side(g.layer.id) is not None)


def test_projecting_silk_did_not_disturb_the_existing_checks():
    """S4 adds a projection family and NO checks. The coupon must still compile
    to a determinately clean geometric DRC — if this moved, the station
    exceeded its contract."""
    drc = run_geometric_drc(_compiled())
    assert drc["verdict"] == "clean"
    assert not drc.get("findings")


def test_a_healthy_board_projects_no_silk_warnings():
    """NEGATIVE CONTROL ONLY, and the docstring says so because the obvious
    positive counterpart does not exist and pretending otherwise would be the
    worse outcome.

    ``Projection.silk_warnings`` carries the shared harvest's warn-and-drop
    diagnostics so a checker cannot silently inherit a narrower set of artwork
    than the emitter draws. But every warning path in silk_source is a
    MALFORMED-GEOMETRY path (non-positive radius, missing endpoints, an arc with
    too few points), and compile_board validates geometry before it ever reaches
    a ResolvedBoard — so from the IR side the field is DEFENSIVE and, as far as
    this test could establish, unreachable. The reachable-from-loose-dict half
    is covered at the owner (test_silk_source.py's degenerate parametrisation).

    What this pins is therefore only: a healthy board raises nothing, so if the
    field ever starts filling up on the coupon, something upstream changed and
    the projection is quietly dropping legend geometry.

    A genuine positive test would need a ResolvedBoard carrying geometry the
    compiler refuses to build — worth doing if the compiler's guarantees ever
    weaken, and NOT worth faking with a stub that would only prove the stub
    warns."""
    proj = project_board(_compiled())
    assert proj.silk_warnings == ()
    assert proj.silk, "negative control is vacuous on a board with no silk"


@pytest.mark.parametrize("flip_logo", [False, True],
                         ids=["all-top", "logo-on-back"])
def test_harvested_silk_reaches_the_serialized_gerber_for_its_own_side(flip_logo):
    """THE PRODUCTION BOUNDARY the agreement test above stops short of.

    Every other test in this file compares in-memory surfaces: the projection
    against ``gerber._harvest_ir``'s buckets. That pins the harvest and the
    checker to each other, but BOTH of them sit upstream of the last step that
    can lose the geometry. ``_build_gerber_layers`` is what forwards each bucket
    into its output file, and if it stopped forwarding the bottom buckets into
    B_SilkS, every in-memory test here would stay green while the fab package
    shipped a blank back legend. That is a false clean of the exact kind this
    epoch exists to prevent, so the claim gets checked against bytes.

    The invariant is stated as an EQUIVALENCE per side rather than "B_SilkS is
    non-empty", deliberately. A hardcoded expectation about which sides carry
    legend would have to be rewritten the moment the coupon gains back-silk
    revision text (station S9 does exactly that), and a test that must be
    edited to keep passing is a test that stops being read. "Whatever the
    harvest holds, the file shows, and nothing more" survives that change.

    IT COMPARES GEOMETRY, NOT APERTURE PRESENCE (CP2, Codex finding 3). The
    first version asserted only ``("%ADD" in text) == (harvested > 0)`` while
    promising the equivalence above — so it stayed green if every primitive but
    one vanished, if coordinates came out mirrored, if widths changed, or if
    arbitrary extra artwork was added. It could tell "some silk" from "no silk"
    and nothing else, which on a fabrication boundary is close to no check at
    all.

    Both directions are now asserted against the parsed bytes:

      NOTHING LOST — every (point, width) the harvest holds appears in the
      file. Catches a dropped primitive, a dropped side, a mirrored coordinate
      and a re-widthed stroke, since all four move a point out of the file's
      set.

      NOTHING INVENTED — every (point, width) in the file is either a harvest
      point or lies on a harvest CIRCLE of the same width. Circles are the one
      primitive the emitter decomposes (into arcs whose endpoints sit on the
      circle and are therefore in no bucket), and that is expressed as the
      geometric property "this point is at radius r from the centre" rather
      than by re-deriving the decomposition here — a second copy of the
      emitter's arc-splitting in the test would drift from the first, which is
      the failure mode this whole station exists to remove.

    TOLERANCE is 1e-4 mm, and it is quantization, not slack: Gerber coordinates
    are fixed-point 4.6, so the file rounds to 1e-6 and the harvest carries full
    float (a measured example is 20.799999 in the bucket, 20.8 in the file).
    1e-4 absorbs that with three orders of margin and still sits 1000x below the
    tightest floor any DFM rule in this codebase declares (0.1 mm), so no real
    geometry error can hide under it.
    """
    import math
    import warnings

    pytest.importorskip("gerbonara")
    from gerbonara import GerberFile

    Q = 4  # decimal places; see the TOLERANCE note above

    def _q(v) -> float:
        return round(float(v), Q)

    rb = _compiled(flip_logo)
    g = gerber._harvest_ir(rb, 0.05)
    files = gerber.build_gerbers_ir(rb, name="silkboundary")

    buckets = {
        "F_SilkS": (g.silk_lines, g.silk_circles, g.silk_polys, g.silk_arcs),
        "B_SilkS": (g.silk_lines_bot, g.silk_circles_bot, g.silk_polys_bot,
                    g.silk_arcs_bot),
    }
    for suffix, (lines, circles, polys, arcs) in buckets.items():
        # EXPECTED: every stroked vertex the harvest holds, tagged with the
        # width it must be drawn at. Refdes designator strokes are included
        # automatically — _emit_refdes appends them to the poly bucket, so they
        # are harvest content, not an emitter-only addition.
        expected: set = set()
        for (x1, y1, x2, y2, w) in lines:
            expected |= {(_q(x1), _q(y1), _q(w)), (_q(x2), _q(y2), _q(w))}
        for (pts, w, _closed) in polys:
            expected |= {(_q(x), _q(y), _q(w)) for (x, y) in pts}
        for (st, en, _ct, _orient, w) in arcs:
            expected |= {(_q(st[0]), _q(st[1]), _q(w)),
                         (_q(en[0]), _q(en[1]), _q(w))}
        harvest_circles = [(_q(cx), _q(cy), _q(r), _q(w))
                           for (cx, cy, r, w) in circles]

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            parsed = GerberFile.from_string(
                files[f"silkboundary-{suffix}.gbr"],
                filename=f"silkboundary-{suffix}.gbr")

        emitted: set = set()
        for obj in parsed.objects:
            # FAIL CLOSED on a primitive this canonicalization cannot read,
            # rather than skipping it. Today every silk object gerbonara hands
            # back is a stroked Line or Arc (measured on both parametrizations).
            # If a filled Region or a Flash ever appears, silently skipping it
            # would quietly shrink `emitted` — and a shrunken emitted set makes
            # the "nothing invented" half pass more easily, which is a false
            # clean. Refusing names the gap instead.
            if not all(hasattr(obj, attr) for attr in ("x1", "y1", "x2", "y2")):
                raise AssertionError(
                    f"{suffix}: {type(obj).__name__} is not a stroked segment, "
                    "so this test cannot canonicalize it — extend the "
                    "comparison rather than letting it be skipped")
            width = _q(obj.aperture.diameter)
            emitted |= {(_q(obj.x1), _q(obj.y1), width),
                        (_q(obj.x2), _q(obj.y2), width)}

        missing = expected - emitted
        assert not missing, (
            f"{suffix}: {len(missing)} harvested silk point(s) never reached "
            f"the fabricated file (first: {sorted(missing)[:3]}) — the checker "
            "measures geometry the board house will not receive")

        def _on_a_harvest_circle(point) -> bool:
            px, py, pw = point
            return any(pw == cw and abs(math.hypot(px - cx, py - cy) - r) < 1e-3
                       for (cx, cy, r, cw) in harvest_circles)

        unexplained = [p for p in (emitted - expected)
                       if not _on_a_harvest_circle(p)]
        assert not unexplained, (
            f"{suffix}: {len(unexplained)} point(s) in the fabricated file "
            f"belong to no harvested primitive (first: {sorted(unexplained)[:3]}) "
            "— the board house receives legend the checker never measured")

        # The original presence check, kept as the cheap consistency floor: an
        # empty side must produce an empty file, which the set comparisons above
        # satisfy vacuously and so cannot assert on their own.
        text = files[f"silkboundary-{suffix}.gbr"]
        assert ("%ADD" in text) == (sum(
            len(b) for b in (lines, circles, polys, arcs)) > 0), (
            f"{suffix}: aperture presence disagrees with harvest occupancy")
