"""K17 — reference designators reach F.SilkS as drawn geometry.

Gerber has no text primitive (gerber_writer 0.4.3.3 confirmed to have none: it
ships only writer.py / macros.py / padmasters.py / lutils.py). A reference
designator ("R1", "U3", ...) therefore reaches the board house only if it is
drawn as stroke geometry — see pcb_worker/board_font.py (the ONE in-house
typeface this project draws with, shared with board legend),
silk_source.refdes_strokes and gerber._emit_refdes.

ACCEPTANCE (the rewritten, satisfiable criterion — see the D4 brief): every
placed component's reference designator is present as drawn geometry on ITS OWN
side's silk layer, positioned at that component and rotated with it — INCLUDING
components whose footprint carries no silk graphics at all.

BACK SIDE CAME IN SCOPE IN EPOCH CP2 (station S3). This header used to end
"Back-side is out of scope (B.SilkS is not an emitted layer at all —
_GERBER_SUFFIXES has no B_SilkS entry)", which was wrong on both counts by the
time anyone read it: B_SilkS had been in _GERBER_SUFFIXES since the fab-package
completeness change (the file was written, just always empty), and S3 gave it
real content. Corrected rather than deleted because a reader who remembers the
old rule needs to see it retired, not silently absent.

Coverage:
  1. gerber._emit_refdes: the unit — per-side bucketing, empty-ref no-ops,
     output is OPEN polylines at gerber.SILK_LINE_WIDTH_MM, transformed by the
     REAL component placement (not whatever _emit_silk happened to receive).
  2. End-to-end through BOTH emitter entry points (build_gerbers_ir — the live
     IR-native path — and build_gerbers — the loose-dict path), each proving
     the headline case revision 1 could not satisfy: a component with NO
     captured silk graphics still gets its designator.
"""

from __future__ import annotations

import re

import pytest

from pcb_worker import board_font, gerber, silk_source
from pcb_worker.compile_board import compile_board
from pcb_worker.geometry import place_point
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

# ---------------------------------------------------------------------------
# The glyph oracle.
#
# Designator glyphs come from board_font — the ONE in-house typeface this
# project draws with, shared with board legend. It used to be a separate
# 26-glyph refdes font whose coordinates were a GPL-2.0-or-later subset; the
# font's own tests live in test_board_font.py, so nothing here re-tests glyph
# data. What these tests need is the LOCAL strokes the emitter is expected to
# place, which is font render + the local Y anchor silk_source applies.
# ---------------------------------------------------------------------------


def _refdes_local(text, size=silk_source.REFDES_TEXT_SIZE_MM,
                  y0=silk_source.REFDES_LOCAL_Y_MM):
    """The glyph-LOCAL (unplaced) strokes ``silk_source.refdes_strokes``
    renders for *text* — centred on the anchor, offset by the local Y anchor.
    Pass ``y0=0.0`` for the authored-reference_text path, which anchors the
    text itself instead of using the default offset."""
    return [[(x, y + y0) for x, y in stroke]
            for stroke in board_font.render(text, size=size,
                                            h_align="center").polylines]


# ---------------------------------------------------------------------------
# 1. gerber._emit_refdes — the unit.
# ---------------------------------------------------------------------------


def test_emit_refdes_bottom_side_fills_the_bottom_bucket_only():
    """A bottom-side designator lands in the BOTTOM bucket and nowhere else.

    THIS TEST WAS A FALSE PASS and is worth describing, because nothing failed to
    reveal it. It was ``test_emit_refdes_bottom_side_is_a_noop``, asserting
    ``g.silk_polys == []`` back when a bottom-side designator was simply dropped.
    CP2 S3 made it emit — into ``silk_polys_bot`` — so the old assertion stayed
    true for a completely different reason, and a test named "bottom side is a
    no-op" went on quietly certifying a contract the code had reversed.

    An empty top bucket proves nothing on its own; it is only meaningful next to
    a non-empty bottom one. Both are asserted here for that reason.
    """
    g = gerber._Geometry()
    gerber._emit_refdes(g, "R1", 10.0, 10.0, 0.0, top=False)
    assert g.silk_polys == [], "a bottom designator must not leak onto F.SilkS"
    assert len(g.silk_polys_bot) == len(_refdes_local("R1")), \
        "the bottom designator did not reach the B.SilkS bucket"


@pytest.mark.parametrize("ref", [None, "", "   ", 42])
def test_emit_refdes_empty_or_non_string_ref_is_a_noop(ref):
    g = gerber._Geometry()
    gerber._emit_refdes(g, ref, 10.0, 10.0, 0.0, top=True)
    assert g.silk_polys == []


def test_emit_refdes_appends_open_polylines_at_the_silk_line_width():
    g = gerber._Geometry()
    gerber._emit_refdes(g, "R1", 10.0, 10.0, 0.0, top=True)
    assert g.silk_polys, "expected designator strokes"
    for (pts, width, closed) in g.silk_polys:
        assert closed is False, "a glyph stroke must be OPEN, never closed"
        assert width == gerber.SILK_LINE_WIDTH_MM
        assert len(pts) >= 2


def test_emit_refdes_uses_the_real_placement_not_a_template():
    """The board-INSTANCE ref ("R7"), never the footprint's raw template
    ("REF**"), drives the emitted glyphs — _emit_refdes has no idea what a
    footprint template even looks like; it only ever sees comp.ref /
    comp.get('ref')."""
    g_instance = gerber._Geometry()
    gerber._emit_refdes(g_instance, "R7", 0.0, 0.0, 0.0, top=True)

    g_template = gerber._Geometry()
    gerber._emit_refdes(g_template, "REF**", 0.0, 0.0, 0.0, top=True)

    assert g_instance.silk_polys != g_template.silk_polys
    assert len(g_instance.silk_polys) == len(_refdes_local("R7"))


def test_emit_refdes_transforms_by_the_given_placement():
    """Glyph-local points are rotated + translated by (cx, cy, rot) via the
    SAME place_point every other component-local primitive in this worker
    uses — proven by comparing _emit_refdes's output to a manual place_point
    transform of the font's own raw glyph points."""
    cx, cy, rot = 12.5, -3.0, 37.0
    g = gerber._Geometry()
    gerber._emit_refdes(g, "A", cx, cy, rot, top=True)

    expected_local = _refdes_local("A", size=gerber.REFDES_TEXT_SIZE_MM,
                                   y0=gerber.REFDES_LOCAL_Y_MM)
    expected = [
        [place_point(cx, cy, rot, lx, ly) for lx, ly in stroke]
        for stroke in expected_local
    ]
    got = [pts for (pts, _w, _closed) in g.silk_polys]
    assert len(got) == len(expected)
    for got_pts, want_pts in zip(got, expected):
        assert len(got_pts) == len(want_pts)
        for (gx, gy), (wx, wy) in zip(got_pts, want_pts):
            assert gx == pytest.approx(wx, abs=1e-9)
            assert gy == pytest.approx(wy, abs=1e-9)


def test_emit_refdes_rotation_actually_rotates_the_glyphs():
    """A sanity check that rotation is not silently a no-op: the same
    designator placed at rot=0 vs rot=90 must land at DIFFERENT board
    coordinates (guards against a future edit that drops the rot argument)."""
    g0 = gerber._Geometry()
    gerber._emit_refdes(g0, "H", 0.0, 0.0, 0.0, top=True)
    g90 = gerber._Geometry()
    gerber._emit_refdes(g90, "H", 0.0, 0.0, 90.0, top=True)

    pts0 = [p for (pts, _w, _c) in g0.silk_polys for p in pts]
    pts90 = [p for (pts, _w, _c) in g90.silk_polys for p in pts]
    assert pts0 != pts90


# ---------------------------------------------------------------------------
# 2. End-to-end through BOTH emitter entry points.
# ---------------------------------------------------------------------------


def _one_component_board(footprint: str, *, ref: str = "X1", layer: str = "top",
                         x: float = 10.0, y: float = 10.0,
                         rotation_deg: float = 0.0) -> dict:
    return {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": ref, "footprint": footprint, "x_mm": x, "y_mm": y,
                        "rotation_deg": rotation_deg, "layer": layer}],
    }


def _resolve(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), (
        [d.code for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR])
    return result.board


def test_ir_native_path_emits_designator_for_a_footprint_with_no_silk_graphics():
    """The headline K17 case, through build_gerbers_ir (the LIVE production
    path): MountingHole_3.2mm_M3's only F.SilkS content in the .kicad_mod is an
    UNCAPTURED fp_text template (_EXPECTED_SEED_MARKERS in
    test_footprint_def.py pins this) — footprints.py's _CAPTURED_GRAPHIC_TAGS
    has no 'fp_text', so this footprint resolves with ZERO F.SilkS graphics.
    Revision 1's acceptance criterion could not even be stated for this case;
    the rewritten one requires it to still carry a designator."""
    rb = _resolve(_one_component_board("MountingHole:MountingHole_3.2mm_M3",
                                       ref="MH1"))
    comp = rb.components[0]
    assert not any(g.layer.id == "F.SilkS" for g in comp.placed_graphics), \
        "fixture expected to have NO resolved F.SilkS graphics"

    files = gerber.build_gerbers_ir(rb, name="mh")
    silk = files["mh-F_SilkS.gbr"]
    assert re.search(r"D0[123]\*", silk), \
        "F.SilkS must carry MH1's designator even though its footprint has no silk graphics"


def _fs_scale(text: str) -> tuple[int, int]:
    m = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", text)
    assert m, "no %FS coordinate-format spec"
    return int(m.group(2)), int(m.group(4))


def _move_points(text: str) -> list[tuple[float, float]]:
    xd, yd = _fs_scale(text)
    return [(int(xs) / 10 ** xd, int(ys) / 10 ** yd)
            for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D02\*", text)]


def test_ir_native_path_positions_designator_at_the_real_component_placement():
    """Direct, non-golden proof that the IR-native call site transforms the
    designator by the component's REAL placement (comp.placement), not by
    whatever _emit_silk happened to receive (identity, on this path) — the
    exact [R2] point-3 trap the brief warns about ("reuse the existing
    transform" is a no-op on the IR path). Uses a ROTATED, off-origin
    component so an identity-transform regression cannot coincidentally still
    match, and this test does not rely on the golden/oracle byte snapshots to
    catch it."""
    rb = _resolve(_one_component_board("MountingHole:MountingHole_3.2mm_M3",
                                       ref="MH1", x=17.0, y=23.0, rotation_deg=45.0))
    comp = rb.components[0]
    files = gerber.build_gerbers_ir(rb, name="mh")
    silk = files["mh-F_SilkS.gbr"]
    moves = _move_points(silk)
    assert moves, "expected at least one move in F.SilkS"

    # 019f77fd6d69: MountingHole_3.2mm_M3 carries its OWN authored reference
    # fp_text on F.SilkS (`(at 0 -4.2)`, no rotation) — the IR-native path now
    # places the designator there instead of the generic REFDES_LOCAL_Y_MM
    # default, so the expectation is derived from the SAME captured
    # reference_text the emitter itself reads (board.footprint_for(comp)
    # .reference_text), not the old hand-picked default offset.
    reference_text = rb.footprint_for(comp).reference_text
    assert reference_text is not None, (
        "MountingHole_3.2mm_M3 is expected to carry an authored reference "
        "fp_text on F.SilkS — if this footprint ever loses it, this test's "
        "premise (proving the AUTHORED-position path) is gone")
    # LITERAL anchor pin (review note: everything below derives its expectation
    # from the SAME captured object the emitter reads, so a mis-parsed `at`
    # index would pass green. These literals come from the .kicad_mod source
    # itself: `(at 0 -4.2)`, no rotation, square (size 1 1) captured as the
    # scalar cap-height 1.0 — the assertions the capture cannot launder.
    # (Non-square fonts are refused at capture — see footprints.py — because
    # the height/width index order would become load-bearing; this literal
    # also pins that the SQUARE path yields the authored value.)
    assert reference_text.position == (0.0, -4.2), reference_text.position
    assert reference_text.rotation_deg == 0.0
    assert reference_text.size_mm == 1.0, reference_text.size_mm
    expected_local = _refdes_local("MH1", size=reference_text.size_mm, y0=0.0)
    footprint_local_first = place_point(
        reference_text.position[0], reference_text.position[1],
        reference_text.rotation_deg, *expected_local[0][0])
    placed = place_point(
        comp.placement.position[0], comp.placement.position[1],
        comp.placement.rotation_deg, *footprint_local_first)
    # place_point works in the BOARD frame; the emitted file is in the GERBER
    # frame, so the expectation is negated in Y exactly once, at the same boundary
    # the emitter crosses (gerber._Geometry.to_gerber_frame, bug 019fa8011555).
    expected_first_point = (placed[0], -placed[1])

    assert any(abs(px - expected_first_point[0]) < 1e-3
              and abs(py - expected_first_point[1]) < 1e-3
              for px, py in moves), (
        f"no F.SilkS move matches the designator's expected placed position "
        f"{expected_first_point} (got {moves}) — the component's REAL "
        f"placement (17, 23, rot 45) must drive the transform, not identity")

    # Negative control: NOT anywhere near the origin (what an identity
    # (0, 0, 0) transform regression would have produced instead).
    assert not any(abs(px) < 5.0 and abs(py) < 5.0 for px, py in moves), (
        "a move landed near the origin — looks like an identity-transform "
        "regression (comp.placement not applied)")


def test_raw_loose_dict_path_emits_designator_for_a_component_with_no_graphics_key():
    """The same headline case through build_gerbers (the loose-dict path): a
    component dict with no 'graphics' key at all (the drilltest fixture's own
    J1/TP1 shape) must still get its designator."""
    board = {
        "version": 1, "name": "raw", "width_mm": 20, "height_mm": 20,
        "components": [
            {"ref": "J7", "footprint": "Conn", "x_mm": 5.0, "y_mm": 5.0,
             "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "drill_mm": 1.0, "annulus_diameter_mm": 1.8}]},
        ],
    }
    files = gerber.build_gerbers(board, name="raw")
    silk = files["raw-F_SilkS.gbr"]
    assert re.search(r"D0[123]\*", silk), \
        "F.SilkS must carry J7's designator even with no 'graphics' key at all"


def test_bottom_designator_reaches_the_serialized_b_silks_and_does_not_leak():
    """A bottom-side designator reaches the SERIALIZED B_SilkS bytes, and the two
    sides do not cross-contaminate.

    REVERSED IN EPOCH CP2 (station S3). This test used to assert the opposite —
    that B_SilkS is aperture-less, because back-side silk was "explicitly OUT"
    and there was no bottom harvest at all. S3 added one, so the old assertion
    now describes a gap that has been closed, and the honest replacement is the
    positive form: prove the legend actually lands.

    IT DELIBERATELY GOES THROUGH ``build_gerbers`` TO BYTES rather than
    inspecting the in-memory ``_Geometry`` buckets. The buckets being right is
    necessary but not sufficient: every intermediate stage could be correct while
    ``_build_gerber_layers`` fails to forward the bottom buckets into the
    B_SilkS output, and a bucket-level test would stay green through exactly that
    regression while the fab package shipped a blank back legend. The apertures
    in the file are the claim a board house can act on.

    Both directions are asserted because a mirror bug fails them asymmetrically:
    geometry sent to the wrong side leaves one layer over-full and the other
    empty, and only checking the layer you expect content on would miss half of
    that.
    """
    board = {
        "version": 1, "name": "twoside", "width_mm": 40, "height_mm": 40,
        "components": [
            {"ref": "TOPREF", "footprint": "F1", "x_mm": 10.0, "y_mm": 10.0,
             "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5}]},
            {"ref": "BOTREF", "footprint": "F2", "x_mm": 30.0, "y_mm": 30.0,
             "rotation_deg": 0.0, "layer": "bottom",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5}]},
        ],
    }
    files = gerber.build_gerbers(board, name="twoside")
    b_silk = next(text for name, text in files.items() if name.endswith("B_SilkS.gbr"))
    f_silk = next(text for name, text in files.items() if name.endswith("F_SilkS.gbr"))

    assert "%ADD" in b_silk, (
        "B_SilkS must carry BOTREF's designator apertures -- the bottom legend "
        f"never reached the emitted file:\n{b_silk}")

    # STROKE COUNT, not just "non-empty": an aperture-present assertion alone
    # survives a regression that emits one stroke of the designator. Each glyph
    # stroke is a separate D02/D01 draw pair, so the D01 count is the number of
    # segments actually drawn.
    for text, ref, other_ref in ((b_silk, "BOTREF", "TOPREF"),
                                 (f_silk, "TOPREF", "BOTREF")):
        drawn = len(re.findall(r"D01\*", text))
        expected = sum(len(stroke) - 1 for stroke in _refdes_local(ref))
        assert drawn >= expected, (
            f"{ref}'s designator is under-drawn: {drawn} D01 draws, expected at "
            f"least {expected} for the glyph strokes alone")

    # And the leak direction, on the in-memory buckets where sidedness is
    # unambiguous: each side's bucket holds ONLY its own component's strokes.
    g = gerber._harvest(board, gerber.DEFAULT_MASK_CLEARANCE_MM)
    assert len(g.silk_polys) == len(_refdes_local("TOPREF")), \
        f"F.SilkS bucket must hold only TOPREF's strokes; got {len(g.silk_polys)}"
    assert len(g.silk_polys_bot) == len(_refdes_local("BOTREF")), \
        f"B.SilkS bucket must hold only BOTREF's strokes; got {len(g.silk_polys_bot)}"


def test_every_top_side_component_gets_a_designator_on_a_mixed_board():
    """A board mixing a with-graphics and a without-graphics top-side seed
    footprint: BOTH designators must be present (K17's actual acceptance
    wording: "every top-side placed component", not just the ones that happen
    to have outline silk already)."""
    board = {
        "version": 1, "name": "mixed", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805",
             "x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top"},
            {"ref": "MH1", "footprint": "MountingHole:MountingHole_3.2mm_M3",
             "x_mm": 25.0, "y_mm": 25.0, "rotation_deg": 0.0, "layer": "top"},
        ],
    }
    rb = _resolve(board)
    r1 = next(c for c in rb.components if c.ref == "R1")
    mh1 = next(c for c in rb.components if c.ref == "MH1")
    assert any(g.layer.id == "F.SilkS" for g in r1.placed_graphics)
    assert not any(g.layer.id == "F.SilkS" for g in mh1.placed_graphics)

    files = gerber.build_gerbers_ir(rb, name="mixed")
    g = gerber._harvest_ir(rb, gerber.DEFAULT_MASK_CLEARANCE_MM)

    # MH1 contributes ONLY its designator's own strokes (no outline silk).
    mh1_strokes = len(_refdes_local("MH1"))
    r1_strokes = len(_refdes_local("R1"))
    assert len(g.silk_polys) == mh1_strokes + r1_strokes, (
        "expected exactly R1's + MH1's designator strokes as the only silk_polys "
        "(R1's own outline silk is lines/arcs, not polys, for this footprint)")

    silk = files["mixed-F_SilkS.gbr"]
    assert re.search(r"D0[123]\*", silk)
