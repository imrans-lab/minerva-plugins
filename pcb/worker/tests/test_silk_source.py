"""Unit pins for pcb_worker.silk_source — the shared silk owner (epoch CP2 S2).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time at the boundary (S10), after the Codex round.

WHAT THESE ARE FOR, given the emitters already have deep silk coverage
(test_cam_conformance.py, test_silk_text.py, test_gerbers.py, and the byte
goldens). Those all test silk THROUGH gerber.py. They would keep passing if the
extraction were correct-but-useless — e.g. if silk_source secretly imported
gerber_writer, or if its API only worked when driven by an emitter. These pin
the properties that make the module usable by a THIRD consumer (geometric DRC,
station S4), which is the entire reason it exists:

  * it is importable with no CAM dependency at all (test 1 — the load-bearing
    one; every other guarantee here is worthless if this fails),
  * its harvest returns neutral primitives in the BOARD frame, so a consumer
    that never converts to the gerber frame still gets correct geometry,
  * degenerate input warns and drops rather than raising, per the module's own
    written ruling, and the warning is returned as DATA rather than pushed into
    some emitter's diagnostic list,
  * designator glyphs are synthesizable WITHOUT an emitter — the property that
    stops a silk checker from measuring a board with no refdes on it.
"""

from __future__ import annotations

import ast
import inspect
import subprocess
import sys
import textwrap

import pytest

from pcb_worker import silk_source
from pcb_worker.footprint_def import ReferenceTextDefinition
from pcb_worker.geometry import PlacementTransform
from pcb_worker.resolved_board import Side


def _loaded_names(function) -> set[str]:
    """Names executably loaded by one function; comments/docstrings earn no credit.

    SCOPE LIMIT, and it matters most in the direction this file uses it. Only
    BARE ``Name`` loads are seen — an attribute access like
    ``silk_source.SILK_TEXT_WIDTH_MM`` is an ``ast.Attribute`` and does not
    appear here. That is correct for functions defined INSIDE silk_source,
    which reference these constants as bare module globals, and it is the only
    way this helper is used below.

    Point it at a function in another module and the ``assert X not in loads``
    half goes VACUOUS: the name is absent because the helper cannot see
    attribute access, not because the function declined to read it. A guard
    that passes when it cannot look is the exact failure class this epoch keeps
    finding, so extend this to walk ``ast.Attribute`` before reusing it across
    a module boundary (CP2-S11 is the likely first caller).
    """
    tree = ast.parse(textwrap.dedent(inspect.getsource(function)))
    return {
        node.id for node in ast.walk(tree)
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)
    }


# ---------------------------------------------------------------------------
# 1. The load-bearing structural pin.
# ---------------------------------------------------------------------------

def test_silk_source_imports_without_pulling_in_any_cam_dependency():
    """THE REASON THIS MODULE EXISTS AT ALL.

    The silk constants were duplicated into kicad.py for years with an explicit
    comment saying why: "gerber.py imports gerber_writer at module level, and
    kicad.py must stay free of that runtime dependency." silk_source removes the
    duplication ONLY IF it is genuinely free of that dependency — otherwise it
    has just moved the problem and geometric DRC (S4) cannot read it either.

    Covers gerber_writer (gerber.py's module-level dep), pyclipper (the
    geometry/pour dep) and agent_router (kicad.py's) — 'any CAM dependency'
    has to mean more than the one module that prompted the extraction.

    Run in a SUBPROCESS deliberately: by the time the rest of this suite has
    run, gerber_writer is already in sys.modules via other imports, so an
    in-process check would pass vacuously no matter what silk_source imports.
    """
    code = (
        "import sys; "
        "import pcb_worker.silk_source; "
        "bad = [m for m in ('gerber_writer', 'pyclipper', 'agent_router') "
        "         if m in sys.modules]; "
        "print(','.join(bad))"
    )
    result = subprocess.run([sys.executable, "-c", code],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    leaked = result.stdout.strip()
    assert leaked == "", (
        f"importing pcb_worker.silk_source dragged in {leaked!r} — the module's "
        f"whole purpose is to be readable by a consumer that must not depend on "
        f"a CAM writer. Whatever new import introduced this belongs in the "
        f"emitter, not here.")


# ---------------------------------------------------------------------------
# 2. Harvest — neutral primitives, board frame.
# ---------------------------------------------------------------------------

def test_line_is_placed_by_the_component_transform_not_left_local():
    """Authored coordinates are component-LOCAL; the harvest must return them
    board-absolute, or a consumer reading them directly measures the geometry
    at the origin."""
    graphic = {"kind": "line", "start": [-1.0, 0.0], "end": [1.0, 0.0],
               "width": 0.2}
    out = silk_source.harvest_graphic(10.0, 5.0, 0.0, graphic)
    assert out.warnings == ()
    (prim,) = out.primitives
    assert isinstance(prim, silk_source.SilkLine)
    assert (prim.x1, prim.y1) == (9.0, 5.0)
    assert (prim.x2, prim.y2) == (11.0, 5.0)
    assert prim.width == 0.2


def test_authored_width_wins_and_a_widthless_graphic_takes_the_graphic_default():
    authored = silk_source.graphic_width({"width": 0.3})
    assert authored == 0.3
    for widthless in ({}, {"width": None}, {"width": 0}, {"width": -1}):
        assert silk_source.graphic_width(widthless) == \
            silk_source.SILK_GRAPHIC_WIDTH_MM
    # RETARGETED IN CP2 (Codex finding 1). This used to assert the two
    # constants held DIFFERENT values, which was the R4 property. S6 raised the
    # graphic fallback to the declared 0.15 floor, so they are equal now and
    # that assertion could not pass.
    #
    # The surviving property is the one that mattered all along: a width-less
    # graphic resolves through the GRAPHIC authority. Asserting the value 0.15
    # directly would pass even if graphic_width were re-pointed at the text
    # constant, so this reads the fallback back out of the function against the
    # name it must consult — equal values make the name the only witness.
    assert silk_source.graphic_width({}) == silk_source.SILK_GRAPHIC_WIDTH_MM == 0.15
    loads = _loaded_names(silk_source.graphic_width)
    assert "SILK_GRAPHIC_WIDTH_MM" in loads
    assert "SILK_TEXT_WIDTH_MM" not in loads


def test_circle_radius_is_not_scaled_by_placement():
    """Component placement is a rigid motion — it rotates and translates but
    cannot scale, so a transformed radius would be a bug, not a refinement."""
    graphic = {"kind": "circle", "center": [0.0, 0.0], "radius": 1.25}
    out = silk_source.harvest_graphic(3.0, 4.0, 90.0, graphic)
    (prim,) = out.primitives
    assert isinstance(prim, silk_source.SilkCircle)
    assert prim.radius == 1.25


def test_authored_poly_is_closed_but_an_approximated_arc_chord_is_not():
    """``closed`` is not cosmetic: an fp_poly outline closes back to its first
    point, a chord approximating an arc must NOT gain that extra segment."""
    poly = silk_source.harvest_graphic(0.0, 0.0, 0.0, {
        "kind": "poly", "points": [[0, 0], [1, 0], [1, 1]]})
    (poly_prim,) = poly.primitives
    assert isinstance(poly_prim, silk_source.SilkPoly)
    assert poly_prim.closed is True

    # Three COLLINEAR points -> infinite circumradius -> chord fallback.
    arc = silk_source.harvest_graphic(0.0, 0.0, 0.0, {
        "kind": "arc", "points": [[0, 0], [1, 0], [2, 0]]})
    (arc_prim,) = arc.primitives
    assert isinstance(arc_prim, silk_source.SilkPoly)
    assert arc_prim.closed is False
    assert [w.code for w in arc.warnings] == ["silk_arc_approximated"]


def test_three_point_arc_resolves_to_a_true_arc_through_the_circumcircle():
    """(0,-1) -> (1,0) -> (0,1) lies on the unit circle centred at the origin;
    a consumer measuring silk clearance needs the real centre, not a chord."""
    out = silk_source.harvest_graphic(0.0, 0.0, 0.0, {
        "kind": "arc", "points": [[0, -1], [1, 0], [0, 1]]})
    assert out.warnings == ()
    (prim,) = out.primitives
    assert isinstance(prim, silk_source.SilkArc)
    assert prim.center == pytest.approx((0.0, 0.0), abs=1e-9)
    assert prim.start == pytest.approx((0.0, -1.0), abs=1e-9)
    assert prim.end == pytest.approx((0.0, 1.0), abs=1e-9)
    # SIGN, not just membership: for a->b->c = (0,-1)->(1,0)->(0,1) the signed
    # area d is POSITIVE, so the board-frame chirality is '+'. DRC consumes this
    # value as-is without ever entering the gerber frame, so an inverted sign
    # here would be caught by no emitter byte test.
    assert prim.orientation == "+"


def test_legacy_arc_chirality_is_board_frame_and_follows_the_sweep_sign():
    """The board-frame chirality convention, pinned here at the OWNER rather
    than only through the emitter (where test_legacy_arc_bulges_into_body pins
    the physical consequence). A consumer staying in the board frame — DRC —
    reads this value as-is, so it has to mean something on its own."""
    common = {"kind": "arc", "points": [[0, 0], [1, 0]]}
    neg = silk_source.harvest_graphic(0.0, 0.0, 0.0, {**common, "angle": -180.0})
    pos = silk_source.harvest_graphic(0.0, 0.0, 0.0, {**common, "angle": 180.0})
    assert neg.primitives[0].orientation == "-"
    assert pos.primitives[0].orientation == "+"


# ---------------------------------------------------------------------------
# 3. Degenerate input — the written ruling, exercised.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("graphic,expected_code", [
    ({"kind": "line", "start": [0, 0]}, "silk_primitive_unemitted"),
    ({"kind": "line", "start": "nope", "end": [1, 1]}, "silk_primitive_unemitted"),
    ({"kind": "circle", "center": [0, 0], "radius": 0}, "silk_primitive_unemitted"),
    ({"kind": "circle", "center": [0, 0]}, "silk_primitive_unemitted"),
    ({"kind": "poly", "points": [[0, 0]]}, "silk_primitive_unemitted"),
    ({"kind": "arc", "points": [[0, 0], [0, 0]], "angle": 90.0},
     "silk_primitive_unemitted"),
    ({"kind": "arc", "points": [[0, 0], [1, 1]]}, "silk_arc_approximated"),
])
def test_degenerate_silk_warns_as_data_and_never_raises(graphic, expected_code):
    """Silk is cosmetic, so a malformed primitive warns and drops rather than
    failing closed (contrast copper/mask). Two properties matter to a checker:
    it does not raise, and the drop is REPORTED — a silent drop would be
    unmeasured geometry.

    The warning comes back as DATA on the result, carrying no SourceRef,
    because ref shape differs per consumer. That is what lets DRC attach its
    own entity id instead of inheriting the emitter's GRAPHIC ref.
    """
    out = silk_source.harvest_graphic(0.0, 0.0, 0.0, graphic)
    assert [w.code for w in out.warnings] == [expected_code]
    assert all(isinstance(w, silk_source.SilkWarning) for w in out.warnings)
    assert all(w.message for w in out.warnings)


def test_unknown_graphic_kind_is_silently_ignored_not_an_error():
    """A footprint carrying, say, an F.Fab-only construct must not blow up the
    silk harvest. Non-silk kinds are filtered by the CALLER (which knows which
    layer it asked for); this is the belt."""
    out = silk_source.harvest_graphic(0.0, 0.0, 0.0, {"kind": "bezier"})
    assert out.primitives == ()
    assert out.warnings == ()


# ---------------------------------------------------------------------------
# 4. Designators — synthesizable without an emitter.
# ---------------------------------------------------------------------------

def test_refdes_strokes_are_open_polylines_at_the_text_width():
    """A glyph stroke must never close back on itself, and it takes the TEXT
    authority rather than the GRAPHIC authority. Both happen to hold 0.15 after
    CP2 S6, so the executable-name check is the part that distinguishes them."""
    strokes = silk_source.refdes_strokes("R1", 10.0, 10.0, 0.0)
    assert strokes, "R1 produced no glyph geometry"
    for prim in strokes:
        assert isinstance(prim, silk_source.SilkPoly)
        assert prim.closed is False
        assert prim.width == silk_source.SILK_TEXT_WIDTH_MM
        assert len(prim.points) >= 2
    loads = _loaded_names(silk_source.refdes_strokes)
    assert "SILK_TEXT_WIDTH_MM" in loads
    assert "SILK_GRAPHIC_WIDTH_MM" not in loads


@pytest.mark.parametrize("ref", [None, "", "   ", 42, [], {}])
def test_refdes_strokes_no_ops_on_a_missing_or_non_string_ref(ref):
    assert silk_source.refdes_strokes(ref, 0.0, 0.0, 0.0) == ()


def test_refdes_geometry_follows_the_component_placement():
    """The designator is placed by the component's REAL transform. Without
    this, every checker would measure every designator at the origin."""
    at_origin = silk_source.refdes_strokes("A", 0.0, 0.0, 0.0)
    moved = silk_source.refdes_strokes("A", 100.0, 50.0, 0.0)
    assert len(at_origin) == len(moved)
    for a, b in zip(at_origin, moved):
        for (ax, ay), (bx, by) in zip(a.points, b.points):
            assert bx == pytest.approx(ax + 100.0)
            assert by == pytest.approx(ay + 50.0)


def test_rotation_actually_rotates_the_designator_glyphs():
    zero = silk_source.refdes_strokes("H", 0.0, 0.0, 0.0)
    ninety = silk_source.refdes_strokes("H", 0.0, 0.0, 90.0)
    assert len(zero) == len(ninety)
    flat = [p for prim in zero for p in prim.points]
    turned = [p for prim in ninety for p in prim.points]
    assert flat != turned, "rotation=90 produced identical glyph geometry"
    # DIRECTION, not just difference: `flat != turned` also passes for a
    # rotation applied with the wrong SIGN, which is the actual historical bug
    # class here (docket 019f3ba0f455 — a +deg/-deg flip mirrored placements).
    #
    # KiCad applies a footprint angle CLOCKWISE in the Y-DOWN file frame, which
    # geometry.rotate_local_offset implements as radians(-deg). At +90 that
    # sends (x, y) -> (y, -x); measured directly off place_point rather than
    # derived, because the sign of this convention is exactly what gets talked
    # into being backwards.
    for (fx, fy), (tx, ty) in zip(flat, turned):
        assert tx == pytest.approx(fy, abs=1e-9)
        assert ty == pytest.approx(-fx, abs=1e-9)


def test_a_designator_exists_with_no_footprint_graphics_at_all():
    """THE POINT OF OWNING GLYPH SYNTHESIS HERE. A component with zero authored
    silk still carries a fabricated designator, so a silk checker fed only
    authored PlacedGraphic geometry would clear a board whose real silk it
    never looked at. Harvest returns nothing; refdes still returns strokes."""
    harvested = silk_source.harvest_graphic(0.0, 0.0, 0.0, {})
    assert harvested.primitives == ()
    assert silk_source.refdes_strokes("U7", 0.0, 0.0, 0.0) != ()


# ---------------------------------------------------------------------------
# 5. Bottom side (epoch CP2 station S3).
# ---------------------------------------------------------------------------

def test_layer_ownership_names_both_silk_layers_and_rejects_everything_else():
    """Which layers are silk is owned HERE, not re-spelled per consumer.

    Before S3, gerber.py and kicad.py's IR bridge each spelled the rule
    themselves, with DRC about to add a third. That is the same drift class the
    geometry extraction closed, one level up: a checker harvesting B.SilkS while
    the emitter harvested only F.SilkS would measure geometry that is never
    fabricated.

    kicad's `_footprint_graphics` deliberately keeps its own `!= "F.SilkS"`
    test — that asks which silk layers THAT emitter can render, not which
    layers are silk, and its answer really is F-only."""
    assert silk_source.silk_side("F.SilkS") is Side.TOP
    assert silk_source.silk_side("B.SilkS") is Side.BOTTOM
    # Not silk -> None, which callers skip. None means "not silk", NOT
    # "unknown", so this is a classification, not a fail-open.
    for other in ("F.CrtYd", "B.CrtYd", "F.Fab", "F.Cu", "B.Cu", "Edge.Cuts",
                  "", "f.silks", None, 7):
        assert silk_source.silk_side(other) is None


def test_bottom_placement_mirrors_local_y_matching_the_pcbnew_oracle():
    """The bottom-side convention is pcbnew's: mirror the LOCAL Y axis, then
    rotate. Pinned against the same PlacementTransform that k1_bottom_oracle
    (pcbnew 9.0.9, native FOOTPRINT.Flip) certifies, so a hand-rolled X-flip or
    a mirror-after-rotate cannot creep in here.

    An X-flip would agree with this for symmetric artwork and disagree for
    everything else, which is the worst failure shape a legend can have."""
    graphic = {"kind": "line", "start": [1.0, 2.0], "end": [3.0, 4.0]}
    top = silk_source.harvest_graphic(10.0, 10.0, 0.0, graphic, Side.TOP)
    bot = silk_source.harvest_graphic(10.0, 10.0, 0.0, graphic, Side.BOTTOM)
    t, b = top.primitives[0], bot.primitives[0]
    # X is untouched; Y reflects about the component origin.
    assert (b.x1, b.x2) == (t.x1, t.x2)
    assert b.y1 == pytest.approx(20.0 - t.y1)
    assert b.y2 == pytest.approx(20.0 - t.y2)

    expected = PlacementTransform(position=(10.0, 10.0), rotation_deg=0.0,
                                  side=Side.BOTTOM)
    assert (b.x1, b.y1) == pytest.approx(expected.point((1.0, 2.0)))
    assert (b.x2, b.y2) == pytest.approx(expected.point((3.0, 4.0)))


def test_side_defaults_to_top_so_no_existing_caller_moves():
    """S3 added a parameter to a function every emitter already called. The
    default has to reproduce pre-S3 output exactly or every top-side golden
    shifts — which is why the goldens are the real gate, and this is the unit
    statement of the same claim."""
    graphic = {"kind": "line", "start": [1.0, 2.0], "end": [3.0, 4.0]}
    implicit = silk_source.harvest_graphic(5.0, 6.0, 30.0, graphic)
    explicit = silk_source.harvest_graphic(5.0, 6.0, 30.0, graphic, Side.TOP)
    assert implicit == explicit
    assert silk_source.refdes_strokes("R1", 5.0, 6.0, 30.0) == \
        silk_source.refdes_strokes("R1", 5.0, 6.0, 30.0, None, Side.TOP)


def test_legacy_arc_chirality_inverts_on_the_bottom_side():
    """A mirror reverses handedness, so the SAME authored sweep sign describes
    the opposite bulge once the footprint is flipped.

    This branch needs the flip explicitly while the 3-point branch does not,
    and that asymmetry is the thing most likely to be "tidied" into a bug: here
    chirality is read off the authored local `angle`, which no placement
    touches; there it is computed from the signed area of already-PLACED points,
    so the mirror is already baked in."""
    graphic = {"kind": "arc", "points": [[0, 0], [1, 0]], "angle": -180.0}
    top = silk_source.harvest_graphic(0.0, 0.0, 0.0, graphic, Side.TOP)
    bot = silk_source.harvest_graphic(0.0, 0.0, 0.0, graphic, Side.BOTTOM)
    assert top.primitives[0].orientation == "-"
    assert bot.primitives[0].orientation == "+"


def test_three_point_arc_chirality_is_not_double_corrected_on_the_bottom():
    """The companion to the test above: because the 3-point form derives
    chirality from the placed points, the mirror must NOT be applied a second
    time. A defensive `if bottom: flip` added here would cancel the mirror
    rather than compose with it."""
    graphic = {"kind": "arc", "points": [[0, -1], [1, 0], [0, 1]]}
    bot = silk_source.harvest_graphic(0.0, 0.0, 0.0, graphic, Side.BOTTOM)
    prim = bot.primitives[0]
    # Mirroring local Y maps the sampled points to (0,1)->(1,0)->(0,-1), whose
    # a->b->c turn is the opposite of the top-side triple's — so '-' here is the
    # mirror showing through the geometry, not a second correction.
    assert prim.orientation == "-"
    assert prim.center == pytest.approx((0.0, 0.0), abs=1e-9)


def test_bottom_designators_are_mirrored_not_merely_relabelled():
    """A back-side designator must be MIRRORED, so it reads correctly when the
    board is viewed from the back. Emitting the same glyph geometry on B.SilkS
    would produce a legend that is readable only in a mirror — which looks
    plausible in a viewer and is wrong on the physical board."""
    top = silk_source.refdes_strokes("R1", 10.0, 10.0, 0.0, None, Side.TOP)
    bot = silk_source.refdes_strokes("R1", 10.0, 10.0, 0.0, None, Side.BOTTOM)
    assert len(top) == len(bot) and top != bot
    for a, b in zip(top, bot):
        for (ax, ay), (bx, by) in zip(a.points, b.points):
            assert bx == pytest.approx(ax)
            assert by == pytest.approx(20.0 - ay)


def test_authored_reference_text_anchor_is_honored_and_mirrors_once():
    """The two-step nested transform (text-local -> footprint-local -> board)
    had NO unit pin before S3 — only emitter goldens — so its bottom-side
    behaviour was unproven at the owner, which is where DRC will read it.

    Step 1 is footprint-LOCAL and must stay side-agnostic; only step 2 mirrors.
    Applying the flip in both steps would cancel it and silently place a back
    designator as if it were on the front."""
    rt = ReferenceTextDefinition(position=(2.0, -1.0), rotation_deg=0.0,
                                 size_mm=1.0)
    top = silk_source.refdes_strokes("I", 10.0, 5.0, 0.0, rt, Side.TOP)
    bot = silk_source.refdes_strokes("I", 10.0, 5.0, 0.0, rt, Side.BOTTOM)
    assert top and bot and top != bot
    # Exactly one reflection about the component's y: applied twice, or not at
    # all, this equality fails.
    for a, b in zip(top, bot):
        for (ax, ay), (bx, by) in zip(a.points, b.points):
            assert bx == pytest.approx(ax)
            assert by == pytest.approx(10.0 - ay)
    # And the authored anchor is actually used rather than REFDES_LOCAL_Y_MM.
    default = silk_source.refdes_strokes("I", 10.0, 5.0, 0.0, None, Side.TOP)
    assert [p.points for p in top] != [p.points for p in default]
