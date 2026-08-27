"""Board-level graphics: schema, compilation, fabrication, and the R7 mirror.

Board graphics are artwork the BOARD owns rather than a component. Before them
the only graphic owner was a footprint, which is why
smart-remote-v2's back-side copyright line is 65 hand-generated B.SilkS
polylines hung off TP1 — a 1206 test point at (8, 30) — with every point in
absolute board coordinates that TP1's own placement would have corrupted the
moment anyone moved it.

THE RISK THESE TESTS EXIST FOR (R7). Back-side legend must be MIRROR-WRITTEN,
and there are two places a mirror could be applied: when the text is turned into
strokes, and when the emitter buckets a primitive onto a back layer. Applying it
in both reads BACKWARDS on the fabricated board while every YAML-level check
stays green — a defect that only a fab, or an independent Gerber parser, can
see. So the mirror is asserted at BOTH levels, with negative controls, and the
Gerber half is read back with gerbonara rather than with our own emitter's
self-report.
"""
from __future__ import annotations

import warnings

import pytest

from pcb_worker import board_font, board_graphics
from pcb_worker.compile_board import compile_board
from pcb_worker.gerber import build_gerbers_ir
from pcb_worker.resolved_board import (
    LayerRole,
    PolygonGeometry,
    PolylineGeometry,
    ResolutionSuccess,
)

GRAPHIC_ID = "graphic:" + "a" * 32
OTHER_ID = "graphic:" + "b" * 32
ANCHOR_X = 10.0
ANCHOR_Y = 10.0


def _board(*graphics, **overrides):
    board = {
        "version": 1,
        "name": "boardgraphics",
        "width_mm": 40,
        "height_mm": 30,
        "components": [],
        "nets": [],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.6, "via_drill_mm": 0.3},
        "board_graphics": list(graphics),
    }
    board.update(overrides)
    return board


def _text(layer="F.SilkS", text="Minerva v2", gid=GRAPHIC_ID, **extra):
    entry = {
        "id": gid,
        "layer": layer,
        "kind": "text",
        "text": text,
        "position": {"x_mm": ANCHOR_X, "y_mm": ANCHOR_Y},
        "size_mm": 1.5,
    }
    entry.update(extra)
    return entry


def _compiled(board):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), \
        "compile failed: " + "; ".join(f"{d.code}: {d.message}" for d in result.diagnostics)
    return result.board


def _codes(board):
    result = compile_board(board)
    return [d.code for d in result.diagnostics]


# --------------------------------------------------------------------------
# The slot is real
# --------------------------------------------------------------------------

def test_board_graphics_reach_the_ir():
    """A `board_graphics` list compiles into ResolvedBoard.board_graphics.

    The negative control for everything below. `board_graphics` used to be on
    compile_board's REFUSED-key list while the IR field was hardcoded to `()`,
    so a board that declared artwork was rejected outright and the field was
    permanently empty. Every mirror and emission assertion here is vacuous if
    that is still true.
    """
    board = _compiled(_board(_text()))
    assert board.board_graphics, "board_graphics is empty — the slot is still a stub"
    assert all(isinstance(g.geometry, PolylineGeometry) for g in board.board_graphics), \
        "glyph strokes must be OPEN polylines; a closed polygon turns a C into an O"
    assert {g.layer.id for g in board.board_graphics} == {"F.SilkS"}


def test_declaring_board_graphics_is_no_longer_refused():
    """The `unsupported_board_feature` refusal is gone for this key.

    Named separately from the test above because the refusal was a DIAGNOSTIC,
    not an empty result: a board could compile "successfully" while an error
    diagnostic said the artwork could not be fabricated.
    """
    assert "unsupported_board_feature" not in _codes(_board(_text()))
    # The sibling key that did NOT graduate is still refused, so this is a
    # targeted change rather than a removed guard.
    assert "unsupported_board_feature" in _codes(
        _board(**{"keepouts": [{"outline": [{"x_mm": 1, "y_mm": 1}]}]}))


def test_text_is_stored_as_provenance_not_as_baked_strokes():
    """The board source carries the STRING; strokes are derived at compile.

    This is the difference between one readable line of YAML and the 700 lines
    the hand-authored workaround needed, and it is what stops the geometry going
    stale if the font is ever corrected. Asserted on the SOURCE dict, because
    the whole claim is about what is persisted.
    """
    entry = _text()
    assert "points" not in entry and "strokes" not in entry
    assert entry["text"] == "Minerva v2"
    # ...and yet it fabricates as many primitives as the string has strokes.
    board = _compiled(_board(entry))
    assert len(board.board_graphics) == len(board_font.render("Minerva v2", 1.5).polylines)


def test_one_source_id_expands_to_derived_per_stroke_ids():
    """A text graphic keeps ONE minted id and derives `<id>#<k>` per stroke.

    The IR needs per-primitive identity for diagnostics; the USER needs one
    object to select, delete and undo. Both, without minting ids the codec would
    then have to validate.
    """
    board = _compiled(_board(_text()))
    ids = [g.id for g in board.board_graphics]
    assert ids == [f"{GRAPHIC_ID}#{i}" for i in range(len(ids))]
    assert len(set(ids)) == len(ids), "derived ids must stay unique within the board"


# --------------------------------------------------------------------------
# R7 — the mirror, at both levels
# --------------------------------------------------------------------------

def test_back_text_is_x_mirrored_about_its_anchor_in_the_ir():
    """B.SilkS strokes are the X-reflection of F.SilkS strokes about the ANCHOR.

    THE NUMBERS: "Minerva v2" at size 1.5 anchored at x=10 spans x in
    [10.0, 21.5] on F.SilkS and [-1.5, 10.0] on B.SilkS. Those are reflections
    about x=10 (the text's own origin), NOT about the board origin x=0 —
    reflecting about x=0 would put the label at [-21.5, -10.0], off the board
    entirely, and would mean asking for text at a position MOVED it.
    """
    front = _compiled(_board(_text("F.SilkS"))).board_graphics
    back = _compiled(_board(_text("B.SilkS"))).board_graphics

    fx = [p[0] for g in front for p in g.geometry.points]
    bx = [p[0] for g in back for p in g.geometry.points]
    assert (min(fx), max(fx)) == pytest.approx((10.0, 21.5))
    assert (min(bx), max(bx)) == pytest.approx((-1.5, 10.0))

    # Point for point, not just extent for extent.
    assert len(back) == len(front)
    for f, b in zip(front, back):
        assert [(round(2 * ANCHOR_X - x, 9), y) for x, y in f.geometry.points] == \
            [(round(x, 9), y) for x, y in b.geometry.points]

    # Y is untouched: the mirror is in X only. A Y-mirror would put the legend
    # upside down, which is byte-stable and blesses perfectly.
    fy = sorted(p[1] for g in front for p in g.geometry.points)
    by = sorted(p[1] for g in back for p in g.geometry.points)
    assert fy == pytest.approx(by)


def test_back_silk_gerber_carries_the_mirrored_strokes():
    """The FABRICATED artwork is mirror-written, read back by gerbonara.

    THE POINT OF READING THE GERBER (risk R7): the emitter's own bottom-silk
    path applies a mirror for FOOTPRINT-local geometry. If board graphics went
    down that path, the strokes would be mirrored TWICE — once here at compile
    and once at emission — and would read correctly in the YAML while reading
    backwards on the board. The YAML assertions above cannot see that; only the
    emitted file can.

    THE CONVENTION VERIFIED: a Gerber is plotted as seen from the TOP, THROUGH
    the board, so back legend is mirror-written in the file and reads correctly
    once the board is flipped. B_SilkS therefore holds the SAME x coordinates
    the IR does, with only the board-frame Y negation (Y-down -> Y-up) applied,
    identically to F_SilkS. Numbers: F x in [10.0, 21.5], B x in [-1.5, 10.0],
    both y in [-10.0, -8.5], 43 segments each.
    """
    pytest.importorskip("gerbonara")
    from gerbonara import GerberFile

    def segments(layer):
        files = build_gerbers_ir(_compiled(_board(_text(layer))), name="bg")
        name = "bg-" + layer.replace(".", "_") + ".gbr"
        assert name in files, f"{name} was not emitted"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            parsed = GerberFile.from_string(files[name], filename=name)
        out = set()
        for obj in parsed.objects:
            a = (round(float(obj.x1), 6), round(float(obj.y1), 6))
            b = (round(float(obj.x2), 6), round(float(obj.y2), 6))
            out.add(tuple(sorted((a, b))))
        return out

    front = segments("F.SilkS")
    back = segments("B.SilkS")

    # The negative control FIRST: every claim below is vacuous on a blank layer,
    # and B_SilkS is emitted (empty) for every board whether or not it has
    # back-side artwork.
    assert front, "F.SilkS gerber is empty — the assertions below prove nothing"
    assert back, "B.SilkS gerber is empty — board graphics never reached the fab"
    assert len(back) == len(front), (
        f"back has {len(back)} segments, front has {len(front)} — not the same "
        "artwork, so the orientation comparison would be meaningless")

    mirror_x = {tuple(sorted(((round(2 * ANCHOR_X - p[0], 6), p[1]),
                              (round(2 * ANCHOR_X - q[0], 6), q[1]))))
                for p, q in front}
    assert back == mirror_x, (
        "back legend is not the X-mirror of the front rendering — it is the "
        "wrong way round on the fabricated board. A SECOND mirror at emission "
        "time is the likely cause (risk R7).")
    # State what it must NOT be, so symmetric artwork cannot satisfy the above.
    assert back != front, "back legend is unmirrored — it will read backwards"
    y_span = -(min(p[1] for seg in front for p in seg)
               + max(p[1] for seg in front for p in seg))
    mirror_y = {tuple(sorted(((p[0], round(y_span - p[1], 6)),
                              (q[0], round(y_span - q[1], 6)))))
                for p, q in front}
    assert back != mirror_y, "back legend is upside down (Y-mirrored)"


def test_front_and_back_gerber_x_extents_match_the_ir():
    """The emitter applies NO x transform: gerber x == board x, both sides.

    Pinned as its own fact because it is the invariant the double-mirror would
    break first, and it is checkable without a mirror comparison at all.
    """
    pytest.importorskip("gerbonara")
    from gerbonara import GerberFile

    for layer, expected in (("F.SilkS", (10.0, 21.5)), ("B.SilkS", (-1.5, 10.0))):
        files = build_gerbers_ir(_compiled(_board(_text(layer))), name="bg")
        name = "bg-" + layer.replace(".", "_") + ".gbr"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            parsed = GerberFile.from_string(files[name], filename=name)
        xs = [v for o in parsed.objects for v in (float(o.x1), float(o.x2))]
        assert (min(xs), max(xs)) == pytest.approx(expected)


# --------------------------------------------------------------------------
# Round trip
# --------------------------------------------------------------------------

def test_compilation_is_stable_across_repeats():
    """Compiling the same source twice yields identical ids and geometry.

    The Python half of the export_yaml -> load_board oracle: because text is
    stored as provenance, the strokes are re-derived on every compile, so
    "the same board produces the same artwork" is a real claim rather than a
    tautology about copied numbers.
    """
    first = _compiled(_board(_text("B.SilkS"))).board_graphics
    second = _compiled(_board(_text("B.SilkS"))).board_graphics
    assert [g.id for g in first] == [g.id for g in second]
    assert [g.geometry.points for g in first] == [g.geometry.points for g in second]


def test_authored_ids_are_honoured_not_reminted():
    """A pre-minted id survives compilation unchanged.

    The id is what the panel's undo history and delete-by-id refer to, so a
    compiler that re-derived it would silently orphan both.
    """
    board = _compiled(_board(_text(gid=OTHER_ID)))
    assert all(g.id.startswith(OTHER_ID + "#") for g in board.board_graphics)


# --------------------------------------------------------------------------
# Raw geometry and the fail-closed layer rule
# --------------------------------------------------------------------------

def test_raw_geometry_kinds_compile():
    graphics = [
        {"id": GRAPHIC_ID, "layer": "F.SilkS", "kind": "polyline", "width": 0.2,
         "points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 5, "y_mm": 1}]},
        {"id": OTHER_ID, "layer": "F.CrtYd", "kind": "rect",
         "start": {"x_mm": 2, "y_mm": 2}, "end": {"x_mm": 8, "y_mm": 6}},
    ]
    board = _compiled(_board(*graphics))
    by_id = {g.id: g for g in board.board_graphics}
    assert isinstance(by_id[GRAPHIC_ID].geometry, PolylineGeometry)
    assert by_id[GRAPHIC_ID].width_mm == pytest.approx(0.2)
    # A rect normalises to a CLOSED polygon of four corners — one shape for
    # every consumer downstream, rather than a fifth geometry case.
    rect = by_id[OTHER_ID]
    assert isinstance(rect.geometry, PolygonGeometry)
    assert len(rect.geometry.points) == 4
    assert rect.layer.role is LayerRole.COURTYARD


def test_copper_and_edge_layers_are_refused():
    """Board graphics are silk or courtyard ONLY, fail-closed.

    Copper would be unconnected metal that routing and DRC must treat as an
    obstacle with no net; Edge.Cuts would be a second answer to "how big is this
    board" beside the profile and its cutouts. Both refuse by ERROR rather than
    being dropped, because a board graphic is one object a person deliberately
    placed and its silent disappearance would be invisible.
    """
    for layer in ("top", "bottom", "F.Cu", "Edge.Cuts"):
        codes = _codes(_board(_text(layer)))
        assert "invalid_board_graphic" in codes, f"{layer} was not refused"


def test_malformed_entries_are_errors_not_silent_drops():
    cases = [
        ({"id": GRAPHIC_ID, "layer": "F.SilkS", "kind": "text"}, "no string"),
        ({"id": GRAPHIC_ID, "layer": "F.SilkS", "kind": "wobble"}, "unknown kind"),
        ({"id": GRAPHIC_ID, "layer": "F.SilkS", "kind": "polyline",
          "points": [{"x_mm": 1, "y_mm": 1}]}, "too few points"),
        ({"id": GRAPHIC_ID, "layer": "F.SilkS", "kind": "circle",
          "center": {"x_mm": 1, "y_mm": 1}, "radius": 0}, "non-positive radius"),
        ({"layer": "F.SilkS", "kind": "text", "text": "x",
          "position": {"x_mm": 1, "y_mm": 1}}, "no id"),
    ]
    for entry, why in cases:
        codes = _codes(_board(entry))
        assert any(c in ("invalid_board_graphic", "invalid_board_structure")
                   for c in codes), f"{why} was accepted: {codes}"


def test_a_non_list_container_is_refused():
    assert "invalid_board_structure" in _codes(
        _board(**{"board_graphics": {"nope": 1}}))


# --------------------------------------------------------------------------
# Unknown glyphs
# --------------------------------------------------------------------------

def test_unknown_glyphs_still_fabricate_as_boxes():
    """A character with no glyph reaches the board as a BOX, not as nothing.

    Dropping it would silently shorten a legend; the box is visible on the
    fabricated board, which is what makes the problem findable.
    """
    board = _compiled(_board(_text(text="A☃B")))
    assert len(board.board_graphics) == len(board_font.render("A☃B", 1.5).polylines)
    assert board_font.render("A☃B", 1.5).missing == ("☃",)


def test_whitespace_only_text_warns_rather_than_emitting_nothing():
    result = compile_board(_board(_text(text="   ")))
    assert isinstance(result, ResolutionSuccess)
    assert "empty_board_graphic" in [d.code for d in result.diagnostics]
    assert result.board.board_graphics == ()


# --------------------------------------------------------------------------
# Silk DRC sees board legend
# --------------------------------------------------------------------------

def test_board_graphics_are_projected_into_silk_drc():
    """Geometric DRC measures board legend, not only component legend.

    Following the value to its consumer: the emitter draws this artwork, so a
    silk rule that skipped it would clear a board whose FABRICATED legend
    violates the rule — the false clean the projection exists to prevent.
    """
    from pcb_worker.drc_geometric import _project_silk

    board = _compiled(_board(_text("B.SilkS")))
    prims, _warnings = _project_silk(board)
    board_prims = [p for p in prims if p.origin == "board_graphic"]
    assert board_prims, "board graphics are invisible to silk DRC"
    assert {p.side.value for p in board_prims} == {"bottom"}
    assert all(p.parent_id == board.id and p.ref is None for p in board_prims)


def test_courtyard_graphics_are_not_projected_as_silk():
    """Courtyard is documentation, not legend, and is skipped by name."""
    from pcb_worker.drc_geometric import _project_silk

    board = _compiled(_board({
        "id": GRAPHIC_ID, "layer": "F.CrtYd", "kind": "rect",
        "start": {"x_mm": 2, "y_mm": 2}, "end": {"x_mm": 8, "y_mm": 6}}))
    prims, _warnings = _project_silk(board)
    assert [p for p in prims if p.origin == "board_graphic"] == []


def test_courtyard_graphics_do_not_break_gerber_emission():
    """A courtyard board graphic emits no silk and raises nothing.

    Gerber carries no courtyard layer at all (it is not among KiCad's nine
    default fab layers), so the emitter skips it exactly as it skips a
    component's courtyard graphic. The guard that would have raised here is the
    one protecting against a layer that is NEITHER silk nor courtyard.
    """
    board = _compiled(_board({
        "id": GRAPHIC_ID, "layer": "B.CrtYd", "kind": "circle",
        "center": {"x_mm": 20, "y_mm": 15}, "radius": 3}))
    files = build_gerbers_ir(board, name="bg")
    assert "bg-B_SilkS.gbr" in files and "bg-F_SilkS.gbr" in files


# --------------------------------------------------------------------------
# The module's own helpers
# --------------------------------------------------------------------------

def test_point_shape_is_the_canonical_board_level_mapping():
    """Only {x_mm, y_mm} parses — never the bare [x, y] pair.

    Go's typed `Points []Point` decodes that mapping alone, so accepting a
    superset here would produce boards the worker reads and the codec that gates
    every LOAD refuses.
    """
    codes = _codes(_board({"id": GRAPHIC_ID, "layer": "F.SilkS",
                           "kind": "polyline", "points": [[1, 1], [5, 1]]}))
    assert "invalid_board_graphic" in codes


def test_text_bounds_helper_matches_the_placed_strokes():
    strokes = board_graphics.text_polylines(
        "Minerva v2", ANCHOR_X, ANCHOR_Y, size_mm=1.5)
    bounds = board_graphics.text_bounds(strokes)
    assert bounds == pytest.approx((10.0, 8.5, 21.5, 10.0))
    assert board_graphics.text_bounds([]) is None
