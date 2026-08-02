"""K17 — reference designators reach F.SilkS as drawn geometry.

Gerber has no text primitive (gerber_writer 0.4.3.3 confirmed to have none: it
ships only writer.py / macros.py / padmasters.py / lutils.py). A reference
designator ("R1", "U3", ...) therefore reaches the board house only if it is
drawn as stroke geometry — see pcb_worker/stroke_font.py (a small subset of
KiCad's own Newstroke font, extracted offline from the dev-only gerbonara
dependency and cited there; NOT imported at runtime) and gerber._emit_refdes.

ACCEPTANCE (the rewritten, satisfiable criterion — see the D4 brief): every
TOP-side placed component's reference designator is present in F_SilkS as
drawn geometry, positioned at that component and rotated with it — INCLUDING
components whose footprint carries no silk graphics at all. Back-side is out
of scope (B.SilkS is not an emitted layer at all — _GERBER_SUFFIXES has no
B_SilkS entry).

Coverage:
  1. stroke_font.py: glyph data is well-formed, matches its cited source
     (gerbonara's Newstroke, dev-only) to within rounding, and renders OPEN
     polylines only.
  2. gerber._emit_refdes: the unit — bottom-side / empty-ref no-ops, output is
     OPEN polylines at gerber.SILK_LINE_WIDTH_MM, transformed by the REAL
     component placement (not whatever _emit_silk happened to receive).
  3. End-to-end through BOTH emitter entry points (build_gerbers_ir — the live
     IR-native path — and build_gerbers — the loose-dict path), each proving
     the headline case revision 1 could not satisfy: a component with NO
     captured silk graphics still gets its designator.
"""

from __future__ import annotations

import re

import pytest

from pcb_worker import gerber, stroke_font
from pcb_worker.compile_board import compile_board
from pcb_worker.geometry import place_point
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

# ---------------------------------------------------------------------------
# 1. stroke_font.py — the glyph data itself.
# ---------------------------------------------------------------------------

_ALL_CHARS = [chr(c) for c in range(ord("A"), ord("Z") + 1)] + \
    [chr(c) for c in range(ord("0"), ord("9") + 1)] + ["?"]


def test_render_produces_polylines_of_at_least_two_points():
    for text in ("R1", "U10", "SW4", "J3", "C22"):
        polylines = stroke_font.render(text)
        assert polylines, f"{text!r} rendered nothing"
        for pts in polylines:
            assert len(pts) >= 2, f"{text!r}: degenerate stroke {pts}"
    # NOTE: a closed-loop-LOOKING glyph (e.g. "0", "8", "B") legitimately has a
    # single stroke whose first and last point coincide — that is the font's
    # own shape, not this code closing it. What matters is that _emit_refdes
    # (below) NEVER passes closed=True for a glyph stroke, so _add_silk_polys
    # never appends a SECOND, synthetic closing segment on top of it.


def test_unknown_character_falls_back_to_the_missing_glyph():
    # A reference designator is always upper-alpha + digits, but the renderer
    # stays total (never raises) for anything else, falling back to '?'.
    assert stroke_font.render("#") == stroke_font.render("?")
    # Lower-case folds to upper (KiCad refs are conventionally upper already).
    assert stroke_font.render("r1") == stroke_font.render("R1")


def test_glyph_table_matches_its_cited_source_newstroke():
    """Pin the ENTIRE _GLYPHS subset against gerbonara's Newstroke (the dev-only
    fabrication-verification dependency this table was extracted from and
    cites — pyproject.toml `[project.optional-dependencies].dev`). This is a
    TEST-ONLY use of gerbonara (already how this repo uses it elsewhere, e.g.
    ir_parity.tabulate_gerber / tests/oracle) — stroke_font.py itself imports
    nothing from gerbonara at runtime; only this test does, and only to prove
    the citation is accurate."""
    gerbonara = pytest.importorskip("gerbonara")
    from gerbonara.newstroke import Newstroke

    ns = Newstroke.load()
    for c in _ALL_CHARS:
        want_w, want_strokes = ns.glyphs[c]
        got_w, got_strokes = stroke_font._GLYPHS[c]
        assert got_w == pytest.approx(want_w, abs=1e-5), c
        assert len(got_strokes) == len(want_strokes), c
        for got_st, want_st in zip(got_strokes, want_strokes):
            assert len(got_st) == len(want_st), c
            for (gx, gy), (wx, wy) in zip(got_st, want_st):
                assert gx == pytest.approx(wx, abs=1e-5), c
                assert gy == pytest.approx(wy, abs=1e-5), c


def test_render_center_alignment_shifts_left_alignment_by_half_the_width():
    # h_align="center" (the default _emit_refdes uses) must be EXACTLY the
    # left-aligned render shifted by half the string's total advance width —
    # not, e.g., half of the first glyph's own bounding box (glyphs carry an
    # inherent left-side bearing baked into their coordinates, so "does the
    # leftmost point sit at -width/2" is the WRONG invariant to check).
    left = stroke_font.render("R1", size=1.0, x0=0.0, y0=0.0, h_align="left")
    center = stroke_font.render("R1", size=1.0, x0=0.0, y0=0.0, h_align="center")
    width = stroke_font.text_width("R1", size=1.0)
    assert len(left) == len(center)
    for left_st, center_st in zip(left, center):
        assert len(left_st) == len(center_st)
        for (lx, ly), (cx, cy) in zip(left_st, center_st):
            assert cx == pytest.approx(lx - width / 2.0, abs=1e-9)
            assert cy == pytest.approx(ly, abs=1e-9)


# ---------------------------------------------------------------------------
# 1b. Z5 — render() is scale-linear, and agrees with text_width(), even for
# strings containing a space.
#
# render()'s cursor `x` must accumulate in GLYPH-LOCAL (unscaled) units, same
# as the regular-glyph branch (`x += glyph_w`, no `* size`), and be scaled
# exactly once at point-emit time (`(px + x) * size`). Before the Z5 fix, the
# space branch instead did `x += SPACE_WIDTH * size` — a pre-scaled advance
# that then got scaled AGAIN at emit, i.e. an effective SPACE_WIDTH * size**2
# term. That is invisible at size=1.0 (size**2 == size — gerber.py's only
# production caller always renders at REFDES_TEXT_SIZE_MM == 1.0, so no
# shipped silk output is affected), but breaks both properties below for any
# size != 1.0 and any string containing a space.
# ---------------------------------------------------------------------------

# Tolerance rationale: every quantity on both sides of these comparisons is
# produced by the SAME primitive float operations (a handful of + and * on
# the literal glyph-table constants), just grouped/ordered slightly
# differently (e.g. `(px + x) * size` vs. `px * size + x * size`). That is
# only a rounding-mode difference, not an accumulated-error one, so a tight
# absolute tolerance is appropriate — 1e-9 is ~7 orders of magnitude looser
# than IEEE-754 double epsilon at these magnitudes (glyph coords are O(1),
# sizes tested are O(1)-O(10)).
_TOL = 1e-9

# THE discriminating fixture named in the brief: a space AND a non-unit size.
# Under the bug this displaces every glyph after the space by
# SPACE_WIDTH * (size**2 - size) = 0.6 * (4 - 2) = 1.2mm.
_DISCRIMINATING_TEXT = "R1 C2"
_DISCRIMINATING_SIZE = 2.0

# A fixture with NO space (or size == 1.0) passes under the bug too — the
# vacuous case the brief warns against. Included explicitly, at the SAME
# size as the discriminating fixture, so the two sit side by side and the
# space (not the size) is visibly what's doing the discriminating.
_NO_SPACE_CONTROL_TEXT = "R1C2"


def _scaled_polylines(polylines, s):
    return [[(px * s, py * s) for px, py in pts] for pts in polylines]


def test_render_scale_linearity_discriminating_fixture_has_a_space():
    """PRIMARY property, pinned at the exact brief fixture: render("R1 C2",
    size) must equal render("R1 C2", 1.0) with every point scaled by `size`.
    This does NOT reference text_width() at all, so a "lazy fix" that instead
    scales text_width's space term to match render's bug (making the two
    functions agree with each other while both stay non-linear) still fails
    this test — only a real fix to render()'s accumulator passes it."""
    text, size = _DISCRIMINATING_TEXT, _DISCRIMINATING_SIZE
    base = stroke_font.render(text, size=1.0, x0=0.0, y0=0.0, h_align="left")
    got = stroke_font.render(text, size=size, x0=0.0, y0=0.0, h_align="left")
    want = _scaled_polylines(base, size)
    assert len(got) == len(want)
    for got_st, want_st in zip(got, want):
        assert len(got_st) == len(want_st)
        for (gx, gy), (wx, wy) in zip(got_st, want_st):
            assert gx == pytest.approx(wx, abs=_TOL)
            assert gy == pytest.approx(wy, abs=_TOL)


def test_render_scale_linearity_no_space_control_passes_either_way():
    """The vacuous-test control: same size as the discriminating fixture
    above, but no space in the string. This passes whether or not the Z5 bug
    is present (the bug lives ONLY in the space branch), which is exactly why
    a no-space fixture would have been the wrong thing to rely on above."""
    text, size = _NO_SPACE_CONTROL_TEXT, _DISCRIMINATING_SIZE
    base = stroke_font.render(text, size=1.0, x0=0.0, y0=0.0, h_align="left")
    got = stroke_font.render(text, size=size, x0=0.0, y0=0.0, h_align="left")
    want = _scaled_polylines(base, size)
    assert len(got) == len(want)
    for got_st, want_st in zip(got, want):
        for (gx, gy), (wx, wy) in zip(got_st, want_st):
            assert gx == pytest.approx(wx, abs=_TOL)
            assert gy == pytest.approx(wy, abs=_TOL)


@pytest.mark.parametrize("text", [
    "R1 C2",
    "R1C2",
    "U10 J3 SW4",     # multiple spaces, compounding the bug if present
    " R1",            # leading space
    "R1 ",            # trailing space
    "R1  C2",         # two consecutive spaces
    "",                # empty string, degenerate case
])
@pytest.mark.parametrize("size", [1.0, 2.0, 0.35, 5.0])
def test_render_is_scale_linear_property(text, size):
    """Broader property sweep (beyond the single named fixture above) over
    strings with/without spaces, at/away from size=1.0, including edge cases
    (leading/trailing/doubled spaces, empty string). For h_align="left",
    x0=y0=0: render(t, s) == scale(render(t, 1.0), s)."""
    base = stroke_font.render(text, size=1.0, x0=0.0, y0=0.0, h_align="left")
    got = stroke_font.render(text, size=size, x0=0.0, y0=0.0, h_align="left")
    want = _scaled_polylines(base, size)
    assert len(got) == len(want), (text, size)
    for got_st, want_st in zip(got, want):
        assert len(got_st) == len(want_st), (text, size)
        for (gx, gy), (wx, wy) in zip(got_st, want_st):
            assert gx == pytest.approx(wx, abs=_TOL), (text, size)
            assert gy == pytest.approx(wy, abs=_TOL), (text, size)


# Probe character for the render/text_width agreement property below: "I"'s
# glyph is a single vertical stroke, so BOTH its points sit at the same
# known, constant glyph-local x. That constancy is what makes it usable as a
# reference mark (see the docstring of the test that uses it).
_PROBE_CHAR = "I"
_PROBE_PX = stroke_font._GLYPHS[_PROBE_CHAR][1][0][0][0]


@pytest.mark.parametrize("text", [
    "R1 C2", "R1C2", "U10 J3 SW4", " R1", "R1 ", "R1  C2", "R1", "",
])
@pytest.mark.parametrize("size", [1.0, 2.0, 0.35, 5.0])
def test_render_advance_matches_text_width(text, size):
    """SECONDARY property: the horizontal advance render() implies for `text`
    must equal text_width(text, size).

    render() does not return (or expose) its internal cursor, so "the advance
    implied by render" has to be observed indirectly. This test appends a
    PROBE character ("I") whose glyph is a single vertical stroke at a KNOWN,
    constant glyph-local x (`_PROBE_PX`, both of its points share it) and
    reads back the x-coordinate of that probe's first rendered point. With
    h_align="left" and x0=0, render's own emit-time transform is:

        rendered_x = (_PROBE_PX + cursor_before_probe) * size
                   = _PROBE_PX * size + cursor_before_probe * size

    and `cursor_before_probe * size` is, by construction (a same-units,
    scale-once accumulator), exactly the quantity text_width(text, size) is
    defined to equal — text_width sums `glyph_w * size` / `SPACE_WIDTH *
    size` per character, which is the distributed form of "sum the
    glyph-unit advances, then multiply by size once". So:

        rendered_x - _PROBE_PX * size == text_width(text, size)

    This indirect readback is deliberately used INSTEAD of two more obvious
    but unsound alternatives:
      - Reading render()'s private `x` directly: not part of the public
        contract, and the whole point is to test the public API's observable
        behaviour.
      - Using the rightmost stroke point of `text`'s own trailing character
        as a stand-in for its advance: unsound in general, because a
        glyph's ink does not always reach its own advance width (e.g. "I"
        itself has advance width 0.47619 but its stroke's own px is only
        0.238095 — using "max x of the trailing glyph" would UNDERSTATE the
        true advance for most characters in this font).
    """
    rendered = stroke_font.render(text + _PROBE_CHAR, size=size, x0=0.0, y0=0.0,
                                   h_align="left")
    probe_first_point_x = rendered[-1][0][0]
    advance = probe_first_point_x - _PROBE_PX * size
    assert advance == pytest.approx(stroke_font.text_width(text, size), abs=_TOL), (text, size)


# ---------------------------------------------------------------------------
# 2. gerber._emit_refdes — the unit.
# ---------------------------------------------------------------------------


def test_emit_refdes_bottom_side_is_a_noop():
    g = gerber._Geometry()
    gerber._emit_refdes(g, "R1", 10.0, 10.0, 0.0, top=False)
    assert g.silk_polys == []


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
    assert len(g_instance.silk_polys) == len(stroke_font.render("R7"))


def test_emit_refdes_transforms_by_the_given_placement():
    """Glyph-local points are rotated + translated by (cx, cy, rot) via the
    SAME place_point every other component-local primitive in this worker
    uses — proven by comparing _emit_refdes's output to a manual place_point
    transform of stroke_font's own raw glyph points."""
    cx, cy, rot = 12.5, -3.0, 37.0
    g = gerber._Geometry()
    gerber._emit_refdes(g, "A", cx, cy, rot, top=True)

    expected_local = stroke_font.render(
        "A", size=gerber.REFDES_TEXT_SIZE_MM, x0=0.0, y0=gerber.REFDES_LOCAL_Y_MM)
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
# 3. End-to-end through BOTH emitter entry points.
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
    expected_local = stroke_font.render(
        "MH1", size=reference_text.size_mm, x0=0.0, y0=0.0)
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


def test_bottom_side_component_gets_no_designator_and_no_bside_layer():
    """Back-side is explicitly OUT (B.SilkS is not even an emitted layer —
    _GERBER_SUFFIXES has no B_SilkS entry). A bottom-side component's ref must
    not leak into F.SilkS."""
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
    # B_SilkS is now WRITTEN (fab packages ship all of KiCad's default layers),
    # but it must stay EMPTY: there is no bottom-silk harvest, so a bottom-side
    # component contributes no legend. "File present" and "content emitted" are
    # different claims and this test guards the second one.
    files = gerber.build_gerbers(board, name="twoside")
    b_silk = next(text for name, text in files.items() if name.endswith("B_SilkS.gbr"))
    assert "%ADD" not in b_silk, (
        "B_SilkS must be an aperture-less file -- a bottom designator or outline "
        f"leaked into it:\n{b_silk}")

    g = gerber._harvest(board, gerber.DEFAULT_MASK_CLEARANCE_MM)
    expected_strokes = len(stroke_font.render("TOPREF"))
    assert len(g.silk_polys) == expected_strokes, (
        "expected ONLY the top-side component's designator strokes; "
        f"got {len(g.silk_polys)}, wanted {expected_strokes}")


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
    mh1_strokes = len(stroke_font.render("MH1"))
    r1_strokes = len(stroke_font.render("R1"))
    assert len(g.silk_polys) == mh1_strokes + r1_strokes, (
        "expected exactly R1's + MH1's designator strokes as the only silk_polys "
        "(R1's own outline silk is lines/arcs, not polys, for this footprint)")

    silk = files["mixed-F_SilkS.gbr"]
    assert re.search(r"D0[123]\*", silk)
