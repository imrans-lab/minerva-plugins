"""ZONE SEALS — the fail-closed refusals that stand between an UNFILLED zone and
a fabrication artifact.

WHY THIS FILE EXISTS (C6 decider claim C30). Four downstream surfaces refuse a
board carrying zones. Exactly ONE of them was pinned by a test
(``test_drc_geometric.py::test_zones_present_is_indeterminate_unsupported_geometry``);
the other three — ``gerber.build_gerbers_ir``, ``kicad._ir_board_dict``,
``route_bridge._reject_unroutable_board`` — were UNPINNED. An unpinned refusal
can be narrowed, or deleted, with no test going red: the narrowing is invisible
to CI. This file makes all four visible.

WHAT A SEAL ASSERTS. Not "zones are unsupported" — that would go stale the day
zones ship. Each seal asserts the load-bearing property: **no surface may
consume a zone whose copper it cannot account for.** A zone with ``fill=None``
has INDETERMINATE copper (compile_board's ``zone_unfilled`` warning says so out
loud), and indeterminate copper must never reach a fabrication file, a DRC
oracle, or the routing grid — because in all three the consequence of guessing
is the same: copper that is there in reality and absent in the model.

So the seals are written against FILL STATE, not against the mere presence of a
zone. When a filler lands, a zone with a COMPUTED fill is allowed through and
these tests still hold; a zone with ``fill=None`` is still refused, and these
tests are what says so.

KEEPOUT is the exception that proves the rule: a keepout emits no copper by
definition, so it has nothing to compute and nothing to drop. Its constraint is
on the ROUTER (and on any pour sharing its layer), which is why the router seal
treats it differently from a pour — see ``test_keepout_still_refuses_routing``.
"""

from __future__ import annotations

import copy
from dataclasses import replace

import pytest

from pcb_worker import gerber, kicad
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    ResolutionSuccess,
    ZoneKind,
)
from pcb_worker.route_bridge import UnsupportedGeometry, _reject_unroutable_board

# --------------------------------------------------------------------------
# Fixture: the smallest board that compiles AND carries a zone.
# --------------------------------------------------------------------------

_ZONE_OUTLINE = [
    {"x_mm": 2.0, "y_mm": 2.0},
    {"x_mm": 18.0, "y_mm": 2.0},
    {"x_mm": 18.0, "y_mm": 18.0},
    {"x_mm": 2.0, "y_mm": 18.0},
]


def _board_with_zone(**zone_overrides) -> dict:
    """A minimal compilable board carrying exactly one zone.

    Synthetic, per ``testdata/POLICY.md`` — authored here rather than loaded so
    the geometry under test is readable in the assertion's own file.
    """
    zone = {"net": "GND", "layer": "top", "outline": copy.deepcopy(_ZONE_OUTLINE)}
    zone.update(zone_overrides)
    return {
        "version": 1, "name": "zone-seal", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 10,
             "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "GND", "pins": ["R1.1"]}],
        "zones": [zone],
    }


def _compile(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), (
        "seal fixture must COMPILE — a seal that never reaches the surface it "
        "guards proves nothing; errors: "
        + repr([d.code for d in result.diagnostics
                if d.severity is DiagnosticSeverity.ERROR])
    )
    return result.board


@pytest.fixture()
def filled_board():
    """A compiled board carrying ONE copper pour, WITH its computed fill."""
    return _compile(_board_with_zone())


@pytest.fixture()
def pour_board(filled_board):
    """The same board with the pour's fill STRIPPED back to ``None``.

    Constructed rather than compiled, because compile_board can no longer
    produce this state: it fills every pour or fails. That does not make the
    seals dead code — the IR is public, ``ResolvedZone.fill`` defaults to
    ``None``, and every one of these surfaces is reachable with a
    hand-constructed board (the routing and IR-parity paths build ResolvedBoards
    that never went through the filler). What the seals guard is the emitters'
    contract, not the compiler's current behaviour: whatever produced the board,
    a pour with uncomputed copper must not become fabrication.
    """
    zone = replace(filled_board.zones[0], fill=None)
    return replace(filled_board, zones=(zone,))


# --------------------------------------------------------------------------
# The fixture itself is load-bearing: assert the zone arrives UNFILLED.
# --------------------------------------------------------------------------


def test_compile_fills_the_pour(filled_board):
    """The compiler produces COMPUTED copper for an authored pour.

    The premise the whole file rests on, from the other side: if compile stopped
    filling, the "filled board is accepted" tests below would pass vacuously and
    the seals would be guarding the only state that exists.
    """
    assert len(filled_board.zones) == 1
    zone = filled_board.zones[0]
    assert zone.kind is ZoneKind.COPPER_POUR
    assert zone.fill, "an authored pour must reach the IR with computed copper"
    assert all(len(p.points) >= 3 for p in zone.fill)


def test_stripped_fixture_is_genuinely_unfilled(pour_board):
    """The seals below guard INDETERMINATE copper; assert that is what they get."""
    assert pour_board.zones[0].fill is None


# --------------------------------------------------------------------------
# SEAL 1 — gerber. A fabrication file must never silently drop copper.
# --------------------------------------------------------------------------


def test_gerber_refuses_a_board_with_unfilled_zones(pour_board):
    """``gerber.build_gerbers_ir`` RAISES on a zone whose copper is uncomputed.

    This is the last gate before bytes go to a board house. A Gerber emitted
    from a board with an unfilled pour is not "a board without a pour" — it is a
    board the fab will build WITHOUT the copper the designer drew, and nothing
    downstream can tell the difference. (gerber.py:1531)
    """
    with pytest.raises(ValueError) as excinfo:
        gerber.build_gerbers_ir(pour_board, name="zone-seal")
    message = str(excinfo.value)
    assert "zone" in message, f"refusal must NAME the dropped feature; got: {message}"


# --------------------------------------------------------------------------
# SEAL 2 — kicad. The DRC oracle must not be handed a board it will check
# without the pour.
# --------------------------------------------------------------------------


def test_kicad_refuses_a_board_with_unfilled_zones(pour_board):
    """``kicad._ir_board_dict`` RAISES on a zone whose copper is uncomputed.

    The .kicad_pcb is consumed as an INDEPENDENT DRC oracle. Omitting the pour
    makes the oracle check a different board than the one the kernel checked,
    and then agree with it — the worst possible failure for a cross-check: a
    green that means nothing. (kicad.py:1056)
    """
    with pytest.raises(ValueError) as excinfo:
        kicad._ir_board_dict(pour_board)
    message = str(excinfo.value)
    assert "zone" in message, f"refusal must NAME the dropped feature; got: {message}"


# --------------------------------------------------------------------------
# SEAL 3 — router. Absent copper in the grid is what lets a proposal cross real
# copper.
# --------------------------------------------------------------------------


def test_router_accepts_a_pour_bearing_board(pour_board):
    """A COPPER POUR does NOT make a board unroutable — DELIBERATE NARROWING.

    This seal was written first in its pre-narrowing form (reject ANY zone) and
    was GREEN against HEAD, which is what made the narrowing safe to do: the
    behaviour being changed was pinned before it changed.

    The refusal was wrong for a pour, and wrong in the direction that costs a
    user a working feature. Seven zone MCP tools and a canvas zone tool ship, so
    drawing a pour — a shipped, supported action — made routing raise. Meanwhile
    the fail-closed rationale never applied: a pour is not copper the grid
    cannot see, it is copper that YIELDS. The fill is computed from the routed
    result and carves itself back around every foreign trace by the clearance,
    so a trace cannot collide with a pour. Refusing here declined to route the
    exact region a pour exists to make routable.

    See ``test_keepout_still_refuses_routing`` for the half that stays closed.
    """
    _reject_unroutable_board(pour_board)  # must not raise


def test_keepout_still_refuses_routing():
    """A KEEPOUT still fails the router closed — the half of the seal that stays.

    This is the fail-open the narrowing above must not have caused. A keepout is
    an authored prohibition on copper; the grid does not model it; routing
    through one would put copper where the author said none may go, and — unlike
    a pour — the keepout emits no copper of its own for any later check to
    collide with. Nothing downstream would ever notice. So it is refused until
    the grid honours it.
    """
    board = _compile(_board_with_zone(kind="keepout", net=None))
    assert board.zones[0].kind is ZoneKind.KEEPOUT
    with pytest.raises(UnsupportedGeometry) as excinfo:
        _reject_unroutable_board(board)
    assert "keepout" in str(excinfo.value), (
        f"refusal must NAME the unmodeled feature; got: {excinfo.value}")


def test_netless_keepout_compiles(pour_board):
    """A netless keepout COMPILES — the validate/compile disagreement is closed.

    ``board_validate._check_zones`` and Go's ``validateZones`` both exempt a
    keepout from the net rule (owner ruling 019fb5ad6d20), but
    ``compile_board`` hardcoded ``kind=COPPER_POUR`` and then applied the POUR
    net rule to it, so a netless keepout passed validation and was rejected by
    the compiler as ``zone_unknown_net``. Two gates disagreeing about the same
    board is a defect regardless of which one is right.
    """
    board = _compile(_board_with_zone(kind="keepout", net=None))
    zone = board.zones[0]
    assert zone.kind is ZoneKind.KEEPOUT
    assert zone.net_id is None, "a keepout carries no net; it is a prohibition, not copper"


# --------------------------------------------------------------------------
# The other half of each narrowed seal: a COMPUTED fill is let through.
# A seal that refused everything would be trivially safe and useless.
# --------------------------------------------------------------------------


def test_gerber_accepts_a_filled_pour(filled_board):
    files = gerber.build_gerbers_ir(filled_board, name="zone-seal")
    f_cu = files["zone-seal-F_Cu.gbr"]
    assert f_cu.count("G36") == len(filled_board.zones[0].fill), (
        "each filled region must emit exactly one Gerber region (G36/G37)")


def test_kicad_accepts_a_filled_pour_and_writes_no_fill(filled_board):
    """The .kicad_pcb carries the zone but NOT our computed polygon.

    Load-bearing for every KiCad-based oracle: if our fill were written into the
    file, KiCad would read our answer back and agree with it.
    """
    board_dict = kicad._ir_board_dict(filled_board)
    assert len(board_dict["zones"]) == 1
    text = next(v for k, v in kicad.generate_ir(filled_board, "z").items()
                if k.endswith(".kicad_pcb"))
    assert "(zone " in text
    assert "filled_polygon" not in text, (
        "writing our own fill into the oracle's input destroys its independence")


# --------------------------------------------------------------------------
# SEAL 4 — the one that already existed, restated HERE so all four zone
# refusals are readable in one place (the DRC suite keeps its own copy).
# --------------------------------------------------------------------------


def test_geometric_drc_checks_a_filled_pour(filled_board):
    """A FILLED pour gets a real verdict, not a blanket indeterminate.

    Pour copper is copper for clearance; GC7 checks it with an exact polygon
    kernel rather than the convex-core kernel GC2 uses, because a fractured
    keyhole polygon through a convexity-assuming separation test returns a
    confident wrong answer.
    """
    from pcb_worker.drc_geometric import run_geometric_drc

    result = run_geometric_drc(filled_board)
    assert result["verdict"] == "clean", result.get("findings")
    assert "gc7_zone_clearance" in result["counts"]


def test_geometric_drc_is_indeterminate_for_unfilled_zones(pour_board):
    """Geometric DRC returns INDETERMINATE, never clean, for uncomputed copper.

    Clean would be a false clean on geometry we know we did not evaluate.
    (drc_geometric.py:997)
    """
    from pcb_worker.drc_geometric import run_geometric_drc

    result = run_geometric_drc(pour_board)
    assert result["verdict"] == "indeterminate", (
        f"unfilled zones must never produce a clean verdict; got {result['verdict']!r}")
    assert result["verifies_geometry"] is False
    assert "clean" not in result, (
        "the indeterminate envelope must carry NO field a caller could read as a pass")


# --------------------------------------------------------------------------
# SEAL 5 — the stitching-via moat. A same-net plated via must stay CONNECTED.
# --------------------------------------------------------------------------


def test_same_net_stitching_via_is_not_moated():
    """A GND via inside a GND pour must not be ringed off by its own clearance.

    KICAD-INDEPENDENT ON PURPOSE. The oracle parity suite pins this too, but it
    skips on any machine without KiCad — and this is a SILENT OPEN on the
    fabrication path, the exact failure class that must not depend on a
    developer's toolchain to be caught.

    The bug it guards: carving every drill at (radius + clearance) looks
    conservative and disconnects the pour. Measured at the clearances that
    matter, before the fix — at 0.2 the void radius landed on 0.4000 mm, exactly
    the land radius, so the via hung on by a sliver; at 0.3 the void was
    0.5000 mm and the via floated in a 0.100 mm moat. The board compiled, passed
    DRC, and emitted plausible Gerbers the whole time.

    Asserted as a VOID COUNT rather than an area, because area is what hid it:
    0.12 mm^2 out of 400 is noise, and a stitching via that stitches nothing is
    not.
    """
    pytest.importorskip("pyclipper")
    import pyclipper as pc

    from pcb_worker.zone_fill import NM_PER_MM

    for clearance in (0.2, 0.3):
        board = _board_with_zone()
        board["design_rules"]["clearance_mm"] = clearance
        board["zones"][0]["clearance_mm"] = clearance
        board["vias"] = [{"x_mm": 6.0, "y_mm": 6.0, "drill_mm": 0.4,
                          "diameter_mm": 0.8, "net": "GND",
                          "from_layer": "top", "to_layer": "bottom"}]
        compiled = _compile(board)
        pour = compiled.zones[0]
        rings = pc.SimplifyPolygons(
            [[(int(round(x * NM_PER_MM)), int(round(y * NM_PER_MM)))
              for (x, y) in poly.points] for poly in pour.fill], pc.PFT_NONZERO)
        voids = [r for r in rings if not pc.Orientation(r)]
        near_via = [r for r in voids
                    if any(abs(x / NM_PER_MM - 6.0) < 1.0 and abs(y / NM_PER_MM - 6.0) < 1.0
                           for (x, y) in r)]
        assert not near_via, (
            f"clearance {clearance}: the same-net stitching via at (6,6) has a "
            f"void carved around it — the pour is open at the via it exists to "
            f"stitch")
        assert len([r for r in rings if pc.Orientation(r)]) == 1, (
            f"clearance {clearance}: the pour fragmented")


def test_foreign_net_and_unplated_holes_are_still_carved():
    """The other half: the same-net exemption must not become "never carve".

    A FOREIGN-net barrel and an UNPLATED bore are both real hazards — the first
    is a different potential, the second has no copper barrel to connect anything
    and is a mechanical hole through whatever copper sits over it. Both keep the
    full clearance carve. Without this, the MF-1 fix could be widened into a
    filler that pours over every drill on the board.
    """
    pytest.importorskip("pyclipper")
    import pyclipper as pc

    from pcb_worker.zone_fill import NM_PER_MM

    board = _board_with_zone()
    board["nets"].append({"name": "SIG", "pins": ["R1.2"]})
    board["vias"] = [{"x_mm": 6.0, "y_mm": 6.0, "drill_mm": 0.4,
                      "diameter_mm": 0.8, "net": "SIG",
                      "from_layer": "top", "to_layer": "bottom"}]
    board["mounting_holes"] = [{"x_mm": 14.0, "y_mm": 14.0,
                                "diameter_mm": 2.0, "plated": False}]
    pour = _compile(board).zones[0]
    rings = pc.SimplifyPolygons(
        [[(int(round(x * NM_PER_MM)), int(round(y * NM_PER_MM)))
          for (x, y) in poly.points] for poly in pour.fill], pc.PFT_NONZERO)
    voids = [r for r in rings if not pc.Orientation(r)]

    def _has_void_near(cx, cy):
        return any(any(abs(x / NM_PER_MM - cx) < 1.5 and abs(y / NM_PER_MM - cy) < 1.5
                       for (x, y) in r) for r in voids)

    assert _has_void_near(6.0, 6.0), "a FOREIGN-net via must still be carved out"
    assert _has_void_near(14.0, 14.0), "an UNPLATED hole must still be carved out"


# --------------------------------------------------------------------------
# SEAL 6 — the fill's area arithmetic is EXACT. (N3)
# --------------------------------------------------------------------------


def test_ring_area_is_exact_for_an_odd_doubled_area():
    """``_ring_area2`` returns the exact doubled area as a Python int.

    THE MECHANISM, stated correctly because the first version of this fix stated
    it wrong. The problem with ``pyclipper.Area`` is NOT 2**53 overflow — Clipper
    accumulates carefully and the areas on a board this size are representable.
    It is that ``Area()`` returns the SIGNED AREA, i.e. the shoelace sum HALVED,
    so a ring whose doubled area is ODD comes back as an exact ``x.5`` float. The
    old fracture check then did ``int(Area(r))`` per ring, truncating that half
    away — and it truncated a DIFFERENT NUMBER OF TIMES on each side of the
    comparison (once per outer-plus-hole ring before fracturing, once per
    fractured ring after). The two sides then disagreed by 1 nm^2 on a real board
    and the compile failed with "fracturing changed the filled area", pointing at
    a fracture bug that did not exist.

    Doubling and staying in Python ints removes the half entirely: there is
    nothing to round, so the fracture verification is a true equality with
    one-square-nanometre resolution rather than a comparison with a hidden
    epsilon of half a unit per contour.
    """
    pytest.importorskip("pyclipper")
    import pyclipper as pc

    from pcb_worker.zone_fill import _ring_area2

    triangle = [(0, 0), (3, 0), (0, 1)]  # doubled area is exactly 3 — ODD
    assert _ring_area2(triangle) == 3

    # The float path, for the record: exact as a float, lossy the moment an
    # integer is wanted back out of it.
    assert pc.Area(triangle) == 1.5
    assert int(pc.Area(triangle)) == 1, "the half is what used to go missing"


def test_fracture_verification_detects_a_one_square_nanometre_error():
    """The fracture check must fail on the SMALLEST possible area change.

    This is what the exact arithmetic buys, and the property the whole
    fail-closed story rests on: a keyhole bridge that crosses geometry changes
    the enclosed area, and the check catches it because it compares exactly. With
    a half-unit of slack per contour, a genuine small error hides in the rounding
    — and the check would go on passing while reporting that it verified
    something.
    """
    pytest.importorskip("pyclipper")
    import pyclipper as pc

    from pcb_worker.zone_fill import ZoneFillError, _verify_fracture

    ring = [(0, 0), (10_000_000, 0), (10_000_000, 10_000_000), (0, 10_000_000)]
    exact = 2 * 10_000_000 * 10_000_000  # doubled area

    _verify_fracture(pc, "zone:ok", [ring], exact)  # must not raise

    for delta in (+2, -2):  # +/- 1 nm^2, doubled
        with pytest.raises(ZoneFillError) as excinfo:
            _verify_fracture(pc, "zone:off", [ring], exact + delta)
        assert "zone:off" in str(excinfo.value), "the refusal must name the zone"


# --------------------------------------------------------------------------
# SEAL 7 — two pours on a layer is not a conflict. (N1)
# --------------------------------------------------------------------------


def test_disjoint_different_net_pours_share_a_layer_happily():
    """A GND pour and a 5V pour side by side on the top layer must COMPILE.

    Executable rather than parked because it is the shape of the canonical
    product board, and the refusal it guards against was over-broad enough to
    make that board uncompilable. The conflict a pour pair can genuinely have is
    claiming the SAME copper; merely sharing a layer is not one.
    """
    board = _board_with_zone()
    board["nets"].append({"name": "V5", "pins": ["R1.2"]})
    board["zones"] = [
        {"net": "GND", "layer": "top",
         "outline": [{"x_mm": 2.0, "y_mm": 2.0}, {"x_mm": 8.0, "y_mm": 2.0},
                     {"x_mm": 8.0, "y_mm": 18.0}, {"x_mm": 2.0, "y_mm": 18.0}]},
        {"net": "V5", "layer": "top",
         "outline": [{"x_mm": 12.0, "y_mm": 2.0}, {"x_mm": 18.0, "y_mm": 2.0},
                     {"x_mm": 18.0, "y_mm": 18.0}, {"x_mm": 12.0, "y_mm": 18.0}]},
    ]
    compiled = _compile(board)
    assert len(compiled.zones) == 2
    assert all(z.fill for z in compiled.zones), "both pours must produce copper"


def test_overlapping_different_net_pours_are_still_refused():
    """The half that stays closed: nothing models pour-versus-pour.

    Geometric DRC projects pads, traces, vias and hole copper — never zone fill —
    so two nets filling the same region would emit a short that no check reports.
    """
    board = _board_with_zone()
    board["nets"].append({"name": "V5", "pins": ["R1.2"]})
    board["zones"] = [
        {"net": "GND", "layer": "top",
         "outline": [{"x_mm": 2.0, "y_mm": 2.0}, {"x_mm": 12.0, "y_mm": 2.0},
                     {"x_mm": 12.0, "y_mm": 12.0}, {"x_mm": 2.0, "y_mm": 12.0}]},
        {"net": "V5", "layer": "top",
         "outline": [{"x_mm": 8.0, "y_mm": 8.0}, {"x_mm": 18.0, "y_mm": 8.0},
                     {"x_mm": 18.0, "y_mm": 18.0}, {"x_mm": 8.0, "y_mm": 18.0}]},
    ]
    result = compile_board(board)
    assert not isinstance(result, ResolutionSuccess)
    assert "zone_fill_failed" in [d.code for d in result.diagnostics
                                  if d.severity is DiagnosticSeverity.ERROR]
