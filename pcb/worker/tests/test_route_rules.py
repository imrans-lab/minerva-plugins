"""Round E2 — the run's EFFECTIVE design rules, and the keepouts they size.

Two halves that only make sense together, and are therefore pinned together:

  1. WIDTH/CLEARANCE COME FROM THE BOARD. Before this round the engine applied
     its own signature defaults (``trace_width=0.25``, ``clearance=0.2``), so a
     board authoring a 0.35mm floor was routed at 0.25 unless the caller passed
     options. The compiled IR carries the real numbers
     (``design_rules.defaults.trace_width_mm`` /
     ``design_rules.minimums.min_clearance_mm``) and they now win.

  2. KEEPOUTS ARE INFLATED BY ``clearance + trace_width / 2``. Plumbing (1)
     without (2) would be worse than neither: the router would path a 0.35mm
     trace against keepouts reserved for 0.25mm, so the proposed copper would be
     wider than the space held for it. The grid marks CENTERLINE-addressed
     cells, so the half-width term is what keeps a legal centerline from putting
     copper inside a clearance ring.

The safety direction is the same one every other surface in this campaign
documents, restated once more for keepouts:

    the modeled keepout must be a SUPERSET of the fabricated copper.
    Over-blocking is legal; under-blocking never is.

MANDATORY FIXTURES (standing gate 019f70f76c2f — an entire class of via bugs hid
behind 2-pin single-path fixtures):

  * a 3-pin net whose route is TWO DISCONNECTED copper paths plus a
    layer-changing via — ``_three_pin_route_reply`` / ``_three_pin_board``;
  * an undo-AFTER-commit scenario — ``test_commit_then_undo_...`` below. The
    worker is stateless, so "undo" is expressed the only honest way it can be
    here: the SAME board, before a commit, with the commit's copper accepted onto
    it, and after that copper is taken back off again.
"""

from __future__ import annotations

import dataclasses
import math

import pytest

from agent_router.grid import RoutingGrid
from agent_router import router as engine_router

from pcb_worker import compile_board as cb
from pcb_worker import drc_geometric, ir_candidates, ir_pads, methods, route_bridge
from pcb_worker.methods import handle_request
from pcb_worker.resolved_board import NetClass


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------

# Deliberately NEITHER of the engine's own signature defaults (0.25 / 0.2): a
# board routed at these numbers can only have got them from its own rules.
BOARD_WIDTH_MM = 0.35
BOARD_CLEARANCE_MM = 0.3


def _tp(ref: str, x: float, y: float) -> dict:
    """A through-hole test point: one numbered pad, drilled, on every layer.

    Through-hole keeps the fixture layer-agnostic, so a route that changes layer
    (the mandatory via case) can land on either side of the board.
    """
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                      "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}


def _three_pin_board(**extra) -> dict:
    """THE mandatory multi-pad fixture: a THREE-pin net (SIG: P1/P2/P3).

    A 3-pin net is what makes the round's two halves observable at all: its MST
    is two connections, so one route legitimately carries two disconnected copper
    paths, and a route reply that carries a via has somewhere for the via to sit
    between them. X1 is a foreign-net pad parked between P1 and P2 so an
    under-sized keepout has something real to under-block.
    """
    board = {
        "version": 1, "name": "e2-rules", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": BOARD_CLEARANCE_MM,
                         "trace_width_mm": BOARD_WIDTH_MM,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [_tp("P1", 10, 20), _tp("P2", 50, 20), _tp("P3", 30, 34),
                       _tp("X1", 30, 8), _tp("X2", 50, 34)],
        "nets": [{"name": "SIG", "pins": ["P1.1", "P2.1", "P3.1"]},
                 {"name": "OTHER", "pins": ["X1.1", "X2.1"]}],
    }
    board.update(extra)
    return board


def _three_pin_route_reply() -> list:
    """The mandatory route SHAPE, as route() serialises it: one 3-pin net whose
    copper is TWO DISCONNECTED paths — {P1->corner, corner->P3} on top and
    {P2->via} on bottom — joined by a layer-changing via, with no shared endpoint
    between the two groups.

    STAGED, not engine-produced, and deliberately so: the point is to pin what the
    OVERLAY does with that shape, which needs the shape to be exact rather than
    whatever the router happens to emit today. It is therefore NOT end-to-end
    engine coverage of via production — ``test_the_three_pin_fixture_routes_end_
    to_end_at_its_own_rules`` is the run that exercises the real engine, and it
    asserts only what the engine actually guarantees.
    """
    return [{
        "net": "SIG",
        "segments": [
            {"start": [10.0, 20.0], "end": [10.0, 28.0], "layer": "F.Cu"},
            {"start": [10.0, 28.0], "end": [22.0, 28.0], "layer": "F.Cu"},
            {"start": [40.0, 20.0], "end": [50.0, 20.0], "layer": "B.Cu"},
        ],
        "vias": [[40.0, 20.0]],
    }]


def _compile(board: dict):
    result = cb.compile_board(board, requested_outputs=cb.V1_ROUTING_OUTPUTS)
    assert isinstance(result, cb.ResolutionSuccess), getattr(result, "diagnostics", None)
    return result.board


def _call_route(params: dict) -> dict:
    resp = handle_request({"id": "e2", "method": "route", "params": params})
    assert resp is not None and resp["id"] == "e2"
    return resp


class _RecordingGrid(RoutingGrid):
    """A RoutingGrid that remembers how it was constructed. Used to prove the
    ENGINE hands the run's own width to the grid — the seam where half (1) of
    this round becomes half (2)."""

    built: list = []

    def __post_init__(self):  # noqa: D105 - see class docstring
        _RecordingGrid.built.append(self)
        super().__post_init__()


@pytest.fixture
def recorded_grids(monkeypatch):
    _RecordingGrid.built = []
    monkeypatch.setattr(engine_router, "RoutingGrid", _RecordingGrid)
    return _RecordingGrid.built


@pytest.fixture
def routed_with(monkeypatch):
    """Record the trace_width the ENGINE was called with and the width the
    candidate OVERLAY was checked at, on the same run. Returns a dict that gains
    ``engine`` and ``overlay`` keys once route() has run."""
    seen: dict = {}
    real_route_board = engine_router.route_board
    real_with_hints = engine_router.route_board_with_hints
    real_check = ir_candidates.check_candidates

    def spy_route_board(board, **kw):
        seen["engine"] = kw.get("trace_width")
        seen["engine_clearance"] = kw.get("clearance")
        return real_route_board(board, **kw)

    def spy_with_hints(board, hints, **kw):
        seen["engine"] = kw.get("trace_width")
        seen["engine_clearance"] = kw.get("clearance")
        return real_with_hints(board, hints, **kw)

    def spy_check(rb, candidates, **kw):
        seen["overlay"] = kw.get("default_width_mm")
        return real_check(rb, candidates, **kw)

    # _route imports the entry points from the MODULE at call time
    # (`from agent_router.router import route_board, ...` inside the function),
    # so the module attributes are the seam to patch.
    monkeypatch.setattr(engine_router, "route_board", spy_route_board)
    monkeypatch.setattr(engine_router, "route_board_with_hints", spy_with_hints)
    monkeypatch.setattr(ir_candidates, "check_candidates", spy_check)
    return seen


# ---------------------------------------------------------------------------
# 1. Where the numbers come from — the precedence chain.
# ---------------------------------------------------------------------------


def test_the_ir_carries_the_fields_the_precedence_chain_reads():
    """Pin the FIELD NAMES, not just the behaviour. These two are what step 3 of
    the chain reads; a rename that silently dropped routing back to the engine
    defaults would otherwise only show up as a number nobody asserted on."""
    rb = _compile(_three_pin_board())
    assert rb.design_rules.defaults.trace_width_mm == pytest.approx(BOARD_WIDTH_MM)
    assert rb.design_rules.minimums.min_clearance_mm == pytest.approx(BOARD_CLEARANCE_MM)


def test_board_design_rules_beat_the_engine_defaults():
    """THE regression this round closes: a board authoring 0.35/0.3 is routed at
    0.35/0.3, not at the engine's own 0.25/0.2."""
    rb = _compile(_three_pin_board())
    width, clearance = methods._effective_routing_rules({}, rb)
    assert width == pytest.approx(BOARD_WIDTH_MM)
    assert clearance == pytest.approx(BOARD_CLEARANCE_MM)
    # ... and they really are different from what the engine would have applied.
    assert width != methods._engine_default_mm("trace_width")
    assert clearance != methods._engine_default_mm("clearance")


def test_an_explicit_caller_option_still_outranks_the_board():
    """Step 1 of the chain is unchanged in meaning by this round."""
    rb = _compile(_three_pin_board())
    assert methods._effective_routing_rules(
        {"trace_width": 0.6, "clearance": 0.45}, rb) == pytest.approx((0.6, 0.45))


def test_an_explicit_zero_clearance_is_honoured_not_promoted():
    """Clearance differs from a copper dimension: ZERO is a legal request. Had it
    been admitted through ``positive_mm`` it would have been discarded and the
    board's rule used instead — silently changing what the option MEANS."""
    rb = _compile(_three_pin_board())
    _, clearance = methods._effective_routing_rules({"clearance": 0}, rb)
    assert clearance == 0.0


def test_a_hint_width_outranks_the_board_but_not_the_caller(routed_with):
    """Step 2 sits between them. `kw` reaching _effective_routing_rules already
    has the hint merged (that merge is _route's, and it is unchanged), so this
    exercises the real ordering end to end."""
    board = _three_pin_board()
    hint = {"id": "h1", "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
                             "net_names": ["SIG"], "waypoints": [],
                             "width_mm": 0.5}}
    resp = _call_route({"board": board, "route_hints": [hint]})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == pytest.approx(0.5)   # hint beat the board
    assert routed_with["engine_clearance"] == pytest.approx(BOARD_CLEARANCE_MM)

    resp = _call_route({"board": board, "route_hints": [hint],
                        "options": {"trace_width": 0.7}})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == pytest.approx(0.7)   # caller beat the hint


def test_an_inadmissible_caller_option_fails_closed_rather_than_being_reinterpreted():
    """0 / NaN / a string is not a trace width, and routing at one would lay
    zero-width copper while the overlay — which admits dimensions through
    ``positive_mm`` — checked at something else. But quietly substituting the
    board's rule is the SAME dishonesty the round removed from the engine
    default: the caller asked for something specific and got something else with
    no diagnostic. It is rejected by name instead.

    Same policy for both dimensions; only the PREDICATE differs (see the
    zero-clearance test above — asking for no clearance is coherent, asking for
    zero-width copper is not).
    """
    rb = _compile(_three_pin_board())
    for bad in (0, -1.0, float("nan"), float("inf"), "0.3", True, None):
        with pytest.raises(route_bridge.UnsupportedGeometry, match="trace_width"):
            methods._effective_routing_rules({"trace_width": bad}, rb)
    for bad in (-1.0, float("nan"), float("inf"), "0.3", True, None):
        with pytest.raises(route_bridge.UnsupportedGeometry, match="clearance"):
            methods._effective_routing_rules({"clearance": bad}, rb)

    # ABSENT is not the same as inadmissible: silence still falls through.
    assert methods._effective_routing_rules({}, rb) == \
        pytest.approx((BOARD_WIDTH_MM, BOARD_CLEARANCE_MM))


def test_a_zero_engine_default_would_still_be_sourced_not_skipped(monkeypatch):
    """The latent `or`-chain hole. With an `or` chain a step yielding 0.0 reads as
    'absent' and falls through — the run would route at one number while the
    overlay (positive_mm) saw another. Every step is an explicit `is None` test
    and every value goes through an admission predicate, so a zero engine default
    is REJECTED as a width (0 is not copper) and HONOURED as a clearance."""
    monkeypatch.setattr(engine_router, "_board_rule_mm", lambda *a, **k: None)
    monkeypatch.setattr(engine_router, "engine_default_mm", lambda _p: 0.0)

    rb = _compile(_three_pin_board())
    with pytest.raises(route_bridge.UnsupportedGeometry, match="trace width"):
        methods._effective_routing_rules({}, rb)
    _, clearance = methods._effective_routing_rules({"trace_width": 0.3}, rb)
    assert clearance == 0.0


def test_a_rule_that_cannot_be_sourced_fails_closed(monkeypatch):
    """No source left => no route. NOT an invented default: inventing geometry is
    the class of bug this campaign removes (E1 deleted a nominal 1.0x1.0 land,
    A5 deleted a 0x0 pad size). Only the two SOURCES are neutralised here; the
    resolver and _route itself run for real."""
    monkeypatch.setattr(engine_router, "_board_rule_mm", lambda *a, **k: None)
    monkeypatch.setattr(engine_router, "engine_default_mm", lambda _p: None)

    rb = _compile(_three_pin_board())
    with pytest.raises(route_bridge.UnsupportedGeometry, match="trace width"):
        methods._effective_routing_rules({}, rb)
    with pytest.raises(route_bridge.UnsupportedGeometry, match="clearance"):
        methods._effective_routing_rules({"trace_width": 0.3}, rb)

    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "unsupported_geometry"
    assert "fails closed" in resp["error"]["message"]
    # Same vocabulary as every other unroutable-geometry reply, and zero routes.
    assert "routes" not in resp.get("result", {})


def test_the_engine_default_is_still_read_from_the_engines_signature():
    """The no-drifting-literal property, now for BOTH parameters. A duplicated
    default that drifted would under- or over-state a keepout as easily as a
    candidate width."""
    import inspect

    sig = inspect.signature(engine_router.route_board).parameters
    assert methods._engine_default_mm("trace_width") == sig["trace_width"].default
    assert methods._engine_default_mm("clearance") == sig["clearance"].default
    # The named trace-width accessor is a thin alias, not a second copy.
    assert methods._engine_default_trace_width_mm() == \
        methods._engine_default_mm("trace_width")
    assert methods._engine_default_mm("no_such_parameter") is None


# ---------------------------------------------------------------------------
# 2. Keepout inflation — the half that makes half (1) safe.
# ---------------------------------------------------------------------------


def test_keepout_margin_is_clearance_plus_half_the_trace_width():
    grid = RoutingGrid(width=10, height=10, resolution=0.1,
                       clearance=0.3, trace_width=0.5)
    assert grid.keepout_margin == pytest.approx(0.3 + 0.25)
    # A negative input can never shrink a keepout below the copper itself.
    assert RoutingGrid(width=10, height=10, resolution=0.1,
                       clearance=-1.0, trace_width=-1.0).keepout_margin == 0.0


def test_a_pad_keepout_is_inflated_for_foreign_nets_and_open_to_its_own():
    """The ring blocks everyone else out to `clearance + w/2` past the copper,
    and stops there — over-blocking is legal, but blocking the whole board is
    not useful. The pad's OWN net may cross it: no clearance is owed to
    yourself, and a net has to be able to reach its own land."""
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_pad(x=10.0, y=10.0, size=(1.0, 1.0), net="SIG")
    margin = grid.keepout_margin           # 0.55
    edge = 0.5                             # half the pad

    inside_ring = 10.0 + edge + margin / 2.0
    assert grid.can_route_through(inside_ring, 10.0, net="OTHER") is False
    assert grid.can_route_through(inside_ring, 10.0, net="SIG") is True
    # Copper itself is still copper, and still the pad's own net.
    assert grid.get_cell(10.0, 10.0).obstacle_type == "pad"
    assert grid.get_cell(inside_ring, 10.0).obstacle_type == "pad_clearance"
    # Beyond copper + margin the board is free again (one cell of grid slack).
    assert grid.get_cell(10.0 + edge + margin + 0.15, 10.0).occupied is False


def test_a_clearance_ring_never_overwrites_a_neighbours_copper():
    """THE ordering trap the ring introduces. Pads are marked in board order, so
    pad A's ring reaches cells pad B already claimed as copper. Overwriting them
    with A's net would let net A route straight through pad B's real land — an
    under-block, and precisely the failure this round exists to prevent."""
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_pad(x=10.0, y=10.0, size=(1.0, 1.0), net="B")   # marked FIRST
    grid.mark_pad(x=11.2, y=10.0, size=(1.0, 1.0), net="A")   # its ring reaches B

    cell = grid.get_cell(10.0, 10.0)
    assert cell.obstacle_type == "pad" and cell.net == "B"
    assert grid.can_route_through(10.0, 10.0, net="A") is False
    assert grid.can_route_through(10.0, 10.0, net="B") is True


def test_a_cell_two_rings_want_belongs_to_neither_net():
    """First-writer-wins would let that one net route within `clearance` of the
    OTHER pad. Nobody gets it."""
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_pad(x=10.0, y=10.0, size=(0.5, 0.5), net="A")
    grid.mark_pad(x=11.0, y=10.0, size=(0.5, 0.5), net="B")

    cell = grid.get_cell(10.5, 10.0)     # midway: inside both rings, neither pad
    assert cell.occupied is True and cell.obstacle_type == "pad_clearance"
    assert cell.net is None
    assert grid.can_route_through(10.5, 10.0, net="A") is False
    assert grid.can_route_through(10.5, 10.0, net="B") is False


def test_an_obstacle_grows_by_the_same_margin_and_owns_no_net():
    """One margin, every marker (grid.keepout_margin is its single owner) — and a
    hole belongs to NO net, so it must not inherit one from a pad ring it lands
    on. `can_route_through` lets a net cross its own cells, so an inherited net
    would be a licence to route through a mounting hole."""
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_pad(x=10.0, y=10.0, size=(0.5, 0.5), net="SIG")
    grid.mark_obstacle(x=10.0, y=10.0, radius=1.0)

    assert grid.get_cell(10.0, 10.0).obstacle_type == "hole"
    assert grid.get_cell(10.0, 10.0).net is None
    assert grid.can_route_through(10.0, 10.0, net="SIG") is False
    # radius + clearance alone (1.3) would have left this cell free.
    probe = 1.0 + 0.3 + 0.25 / 2.0
    assert grid.is_blocked(10.0 + probe, 10.0) is True
    assert grid.is_blocked(10.0 + 1.0 + grid.keepout_margin + 0.15, 10.0) is False


def test_a_routed_trace_reserves_its_own_half_width_too():
    """The keepout a routed trace leaves behind is the third marker, and it was
    the last one still under-blocking. The engine used to hand ``mark_trace`` a
    pre-inflated ``trace_width + 2 * clearance`` — half-extent ``w/2 +
    clearance``, which is short by the NEWCOMER's own half-width. The grid is
    addressed by centerline, so a foreign trace centred there lays half its copper
    inside the clearance gap.
    """
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_trace(start=(5.0, 10.0), end=(15.0, 10.0), width=0.5, net="SIG")

    edge = 0.25                       # the trace's own half-width
    old_half_extent = edge + 0.3      # what `w + 2c` reserved: 0.55
    correct = edge + grid.keepout_margin              # 0.25 + 0.55 = 0.80

    # The band the old inflation left open, and which a foreign centerline could
    # legally occupy, is now blocked.
    probe = 10.0 + (old_half_extent + correct) / 2.0
    assert grid.can_route_through(10.0, probe, net="OTHER") is False
    assert grid.can_route_through(10.0, probe, net="SIG") is True
    # Copper is still copper, and the reservation still stops somewhere.
    assert grid.get_cell(10.0, 10.0).obstacle_type == "trace"
    assert grid.get_cell(10.0, 10.0 + correct - 0.05).obstacle_type == "trace_clearance"
    assert grid.get_cell(10.0, 10.0 + correct + 0.15).occupied is False


def _point_to_segment_mm(px: float, py: float, a, b) -> float:
    """Distance from a point to a segment's CENTERLINE, in mm."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    t = 0.0 if span == 0.0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / span))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def test_route_board_reserves_the_full_margin_around_the_copper_it_lays(recorded_grids):
    """THE behavioural guard for this round's headline fix, driven through
    ``route_board`` itself rather than through ``mark_trace``.

    The band between ``w/2 + clearance`` (what the old hand-inflated
    ``trace_width + 2 * clearance`` reserved) and ``w/2 + clearance + w/2`` (what
    a foreign CENTERLINE actually needs) is precisely the region the old code left
    open. A test that probes that band fails on the old behaviour and passes on
    the new one no matter how the width term is spelled at the call site — which
    the source scanner below cannot do, and which the direct-``mark_trace`` test
    above does not do either, because it never reaches a call site at all.

    Deliberately generous geometry: a 1.2mm trace makes the band 0.6mm wide, and
    a 0.05mm grid keeps ``_cell_range``'s one-cell over-claim (see its note) an
    order of magnitude smaller than the effect being measured.
    """
    width_mm, clearance_mm, resolution_mm = 1.2, 0.2, 0.05
    old_reach = width_mm / 2.0 + clearance_mm                    # 0.80
    new_reach = old_reach + width_mm / 2.0                       # 1.40
    slop = 3 * resolution_mm                                     # quantisation

    board = route_bridge.resolved_board_to_router(_compile(_three_pin_board()))
    result = engine_router.route_board(board, trace_width=width_mm,
                                       clearance=clearance_mm,
                                       grid_resolution=resolution_mm)
    assert result.routes, "the fixture must actually route"
    grid = recorded_grids[0]

    copper = [(s.start, s.end, s.layer)
              for route in result.routes for s in route.segments]
    assert copper, "the run must have laid down some copper"

    # Probe points strictly inside the contested band, far enough from every PAD
    # that a pad's own ring cannot be what blocks them (a pad reserves at most
    # half its diagonal + the margin).
    pad_reach = max(math.hypot(*p.size) / 2.0 for p in board.pads) \
        + clearance_mm + width_mm / 2.0 + slop
    probes: list = []
    for a, b, layer in copper:
        dx, dy = b[0] - a[0], b[1] - a[1]
        span = math.hypot(dx, dy)
        if span < resolution_mm:
            continue
        nx, ny = -dy / span, dx / span              # unit perpendicular
        mx, my = (a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0
        for sign in (1.0, -1.0):
            for reach in (old_reach + slop + 0.05, new_reach - slop - 0.05):
                px, py = mx + sign * nx * reach, my + sign * ny * reach
                # The probe must sit in the band relative to ALL routed copper
                # (a neighbouring segment of the same polyline is closer than the
                # one it was derived from, and would block it for free).
                nearest = min(_point_to_segment_mm(px, py, s, e)
                              for s, e, lyr in copper if lyr == layer)
                if not (old_reach + slop < nearest < new_reach - slop):
                    continue
                if min(math.hypot(px - p.position[0], py - p.position[1])
                       for p in board.pads) < pad_reach:
                    continue
                probes.append((px, py, layer))

    assert len(probes) >= 8, (
        f"need probe points in the contested band; found {len(probes)}")
    for px, py, layer in probes:
        assert grid.can_route_through(px, py, net="NO_SUCH_NET", layer=layer) \
            is False, f"({px:.3f}, {py:.3f}) on {layer} is inside the band a " \
                      f"foreign centerline must not enter"


def test_a_traces_ring_never_overwrites_a_pads_copper():
    """The ordering trap again, on the marker that just grew. ``_mark_trace_point``
    used to write its net over every cell it touched, so a trace passing a foreign
    pad handed that pad's land to the trace's net."""
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_pad(x=10.0, y=10.0, size=(1.0, 1.0), net="PADNET")
    grid.mark_trace(start=(5.0, 11.2), end=(15.0, 11.2), width=0.5, net="SIG")

    cell = grid.get_cell(10.0, 10.0)
    assert cell.obstacle_type == "pad" and cell.net == "PADNET"
    assert grid.can_route_through(10.0, 10.0, net="SIG") is False


def test_every_keepout_marker_goes_through_the_one_margin(monkeypatch):
    """The single-owner claim routing.md and route_bridge.py both make. If any
    marker re-derived its own inflation, changing the owner would leave it behind.

    A SUPPLEMENT to the behavioural test above, never the primary guard. What it
    adds: a call site that re-inflates on top of the grid's margin
    (``trace_width + 2 * clearance`` while the grid also adds its own) OVER-blocks
    rather than under-blocks, so no probe can see it — legal by the invariant, but
    still a duplicated term that would drift. What it cannot do is prove the
    reserved distance is right; only the probes can. The width argument is
    compared as an AST node rather than as text, because a substring scan is
    defeated by aliasing the clearance term (``_c = clearance``).
    """
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    seen: list = []
    monkeypatch.setattr(type(grid), "keepout_margin",
                        property(lambda self: seen.append(1) or 0.55))
    grid.mark_pad(x=5.0, y=5.0, size=(0.5, 0.5), net="A")
    grid.mark_obstacle(x=8.0, y=5.0, radius=0.5)
    grid.mark_trace(start=(11.0, 5.0), end=(13.0, 5.0), width=0.5, net="A")
    grid.mark_via(x=16.0, y=5.0, diameter=0.8, net="A")
    assert len(seen) >= 4, \
        "pad, obstacle, trace and via must each consult the owner"

    # Every mark_trace / mark_via call site must hand over the BARE copper
    # dimension — the run's baseline ("trace_width"), THIS net's own
    # class-or-baseline width ("net_width" — the net-class round's only change to
    # these call sites), or, for copper the board ALREADY carries (T7
    # 019f70ebc9ed), that copper's own authored dimension ("seg.width" /
    # "via.diameter"). The grid still owns ONE, board-wide, margin. Parsed, so
    # `trace_width + 2 * clearance`, `trace_width + 2 * _c`, `via.diameter +
    # 2 * clearance` and every other re-inflation are rejected as the arithmetic
    # nodes they are — a hand-inflated second path is exactly the defect an
    # earlier round shipped and had to undo.
    import ast
    import inspect

    tree = ast.parse(inspect.getsource(engine_router))
    _ALLOWED = {"width": {"trace_width", "net_width", "seg.width"},
                "diameter": {"via.diameter"}}
    for attr, arg_name in (("mark_trace", "width"), ("mark_via", "diameter")):
        calls = [node for node in ast.walk(tree)
                 if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute)
                 and node.func.attr == attr]
        expected = 4 if attr == "mark_trace" else 1
        assert len(calls) == expected, \
            f"expected {expected} {attr} call sites, found {len(calls)}"
        for call in calls:
            supplied = {k.arg: k.value for k in call.keywords}.get(arg_name)
            assert supplied is not None and \
                ast.unparse(supplied) in _ALLOWED[arg_name], \
                f"{attr} {arg_name} must be a bare (never re-inflated) copper " \
                f"dimension, got {ast.unparse(supplied) if supplied else None}"


def test_the_engine_hands_the_grid_the_runs_own_width(recorded_grids):
    """The seam where half (1) becomes half (2). If the grid were left on its own
    default the router would path a 0.35mm trace against 0.25mm-sized keepouts —
    proposed copper wider than the space reserved for it."""
    board = route_bridge.resolved_board_to_router(_compile(_three_pin_board()))
    engine_router.route_board(board, trace_width=BOARD_WIDTH_MM,
                              clearance=BOARD_CLEARANCE_MM)
    assert recorded_grids, "route_board must build a grid"
    grid = recorded_grids[0]
    assert grid.trace_width == pytest.approx(BOARD_WIDTH_MM)
    assert grid.clearance == pytest.approx(BOARD_CLEARANCE_MM)
    assert grid.keepout_margin == pytest.approx(
        BOARD_CLEARANCE_MM + BOARD_WIDTH_MM / 2.0)


def test_inflation_composes_with_the_rotation_superset_it_does_not_replace_it():
    """``mark_pad`` discards rotation, so route_bridge hands it the land's
    axis-aligned BOUNDING BOX — a superset chosen for rotation. The ring grows
    that superset; it does not stand in for it. A box that already contains the
    rotated copper still contains it after growing, so the two over-blocks stack.

    Checked on a rotated DIP land, where a truthful w/h would under-block.
    """
    board = {
        "version": 1, "name": "e2-rot", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": BOARD_CLEARANCE_MM,
                         "trace_width_mm": BOARD_WIDTH_MM,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "U1", "x_mm": 20, "y_mm": 20, "rotation_deg": 37,
                        "layer": "top",
                        "footprint": "Package_DIP:DIP-6_W7.62mm_Socket"}],
    }
    rb = _compile(board)
    rendered = route_bridge.resolved_board_to_router(rb)
    margin = BOARD_CLEARANCE_MM + BOARD_WIDTH_MM / 2.0

    by_id = {p.ref + "." + p.number: p for p in ir_pads.iter_ir_pads(rb)}
    for pad in rendered.pads:
        land = ir_pads.pad_copper_shape(by_id[pad.component + "." + pad.number]).aabb()
        # (a) the projection's box already CONTAINS the real rotated land ...
        assert pad.position[0] - pad.size[0] / 2.0 <= land.min_x + 1e-9
        assert pad.position[0] + pad.size[0] / 2.0 >= land.max_x - 1e-9
        assert pad.position[1] - pad.size[1] / 2.0 <= land.min_y + 1e-9
        assert pad.position[1] + pad.size[1] / 2.0 >= land.max_y - 1e-9

        # (b) ... and the marked keepout contains that box grown by the margin,
        # i.e. real copper + clearance + half a trace, on every side.
        grid = RoutingGrid(width=40, height=40, resolution=0.05,
                           clearance=BOARD_CLEARANCE_MM, trace_width=BOARD_WIDTH_MM,
                           layers=["F.Cu", "B.Cu"])
        grid.mark_pad(x=pad.position[0], y=pad.position[1], size=pad.size,
                      net="SIG", layer="F.Cu", rotation=0.0)
        for px, py in ((land.min_x - margin + 0.05, land.min_y - margin + 0.05),
                       (land.max_x + margin - 0.05, land.max_y + margin - 0.05),
                       (land.min_x - margin + 0.05, land.max_y + margin - 0.05),
                       (land.max_x + margin - 0.05, land.min_y - margin + 0.05)):
            assert grid.can_route_through(px, py, net="OTHER", layer="F.Cu") is False


def test_the_routed_keepout_is_a_superset_of_the_copper_geometric_drc_checks():
    """The invariant in one line, over the whole mandatory fixture: every piece
    of copper the geometric DRC will collision-check is inside a cell the router
    refuses to hand to a foreign net."""
    rb = _compile(_three_pin_board())
    rendered = route_bridge.resolved_board_to_router(rb)
    grid = RoutingGrid(width=60, height=40, resolution=0.1,
                       clearance=BOARD_CLEARANCE_MM, trace_width=BOARD_WIDTH_MM,
                       layers=["F.Cu", "B.Cu"])
    for pad in rendered.pads:
        for layer in ("F.Cu", "B.Cu"):
            grid.mark_pad(x=pad.position[0], y=pad.position[1], size=pad.size,
                          net=pad.net, layer=layer, rotation=0.0)

    for copper in drc_geometric.project_board(rb).copper:
        box = copper.shape.aabb()
        for px, py in ((box.min_x, box.min_y), (box.max_x, box.max_y),
                       ((box.min_x + box.max_x) / 2.0, (box.min_y + box.max_y) / 2.0)):
            assert grid.can_route_through(px, py, net="NO_SUCH_NET") is False


# ---------------------------------------------------------------------------
# 3. The candidate overlay is still checked at the width the run routed at.
# ---------------------------------------------------------------------------


def test_the_overlay_is_checked_at_the_width_the_engine_routed_at(routed_with):
    """A proposal checked at a different width than it was routed at is a FALSE
    CLEAN — the failure this whole campaign exists to remove. Since E2 both come
    from one resolved value, so this is a shared variable rather than two
    derivations that happen to agree."""
    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == pytest.approx(BOARD_WIDTH_MM)
    assert routed_with["overlay"] == pytest.approx(routed_with["engine"])


def test_the_overlay_width_follows_an_explicit_caller_option_too(routed_with):
    """The two must track each other at EVERY step of the precedence chain, not
    only where the board's rule happens to win."""
    resp = _call_route({"board": _three_pin_board(),
                        "options": {"trace_width": 0.55}})
    assert resp["ok"] is True, resp
    assert routed_with["engine"] == pytest.approx(0.55)
    assert routed_with["overlay"] == pytest.approx(0.55)


def test_a_three_pin_two_path_route_with_a_via_is_projected_at_the_run_width():
    """MANDATORY FIXTURE, at the seam that consumes it. The reply carries a 3-pin
    net whose copper is two disconnected paths plus a layer-changing via; every
    projected candidate segment must carry the run's width, and the via must
    become real copper on both layers rather than a marker.

    A 2-pin single-path reply cannot express this: the second path has no shared
    endpoint with the first, which is exactly the shape the via bugs hid in.
    """
    rb = _compile(_three_pin_board())
    payload = {"routes": _three_pin_route_reply()}
    methods._attach_route_geometric_drc(payload, rb, trace_width_mm=BOARD_WIDTH_MM)

    verdict = payload["routes"][0]["drc_geometric"]
    assert verdict["verifies_geometry"] is True
    assert verdict["verdict"] in ("clean", "violations")   # never indeterminate

    candidates, empty = methods._routes_to_candidates(payload["routes"])
    assert empty == [] and len(candidates) == 1
    assert len(candidates[0]["segments"]) == 3 and len(candidates[0]["vias"]) == 1
    overlay = ir_candidates.build_overlay(
        rb, candidates, default_width_mm=BOARD_WIDTH_MM,
        default_via_diameter_mm=rb.design_rules.defaults.via_diameter_mm,
        default_via_drill_mm=rb.design_rules.defaults.via_drill_mm)
    projected = [t for t in overlay.board.traces if t.id not in
                 {b.id for b in rb.traces}]
    assert projected, "the three-pin proposal must reach the overlay as copper"
    for trace in projected:
        for seg in trace.segments:
            assert seg.width_mm == pytest.approx(BOARD_WIDTH_MM)
    # The two paths really are disconnected: one group on F.Cu, one on B.Cu.
    layers = {seg.layer.id for t in projected for seg in t.segments}
    assert layers == {"top", "bottom"}
    assert len(overlay.board.vias) == len(rb.vias) + 1


def test_the_three_pin_fixture_routes_end_to_end_at_its_own_rules(routed_with):
    """And the same fixture through the real method, so the mandatory shape is
    not only checked in isolation."""
    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    sig = [r for r in resp["result"]["routes"] if r["net"] == "SIG"]
    assert sig, resp["result"]
    # A 3-pin net's MST is two connections, so its route carries >1 path worth of
    # segments — the multi-path shape, produced by the engine rather than staged.
    assert len(sig[0]["segments"]) >= 2
    assert routed_with["engine"] == pytest.approx(BOARD_WIDTH_MM)


# ---------------------------------------------------------------------------
# 4. MANDATORY: undo AFTER commit.
# ---------------------------------------------------------------------------


def _committed(board: dict) -> dict:
    """The same board with the proposal ACCEPTED onto it — traces + via written
    at the board's own authored dimensions, which is what acceptance does."""
    out = dict(board)
    out["traces"] = [
        {"net": "SIG", "layer": "top", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 10.0, "y_mm": 20.0}, {"x_mm": 10.0, "y_mm": 28.0},
                    {"x_mm": 22.0, "y_mm": 28.0}]},
        {"net": "SIG", "layer": "bottom", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 40.0, "y_mm": 20.0}, {"x_mm": 50.0, "y_mm": 20.0}]},
    ]
    out["vias"] = [{"net": "SIG", "x_mm": 40.0, "y_mm": 20.0,
                    "diameter_mm": 0.8, "drill_mm": 0.4,
                    "from_layer": "top", "to_layer": "bottom"}]
    return out


def _undone(board: dict) -> dict:
    """...and the same board after the commit is undone. F1 (019f70f76c2f) is the
    reason traces and vias come back off TOGETHER: an undo that dropped only the
    traces would leave an orphaned via behind."""
    out = dict(board)
    out.pop("traces", None)
    out.pop("vias", None)
    return out


def test_commit_then_undo_leaves_the_board_routing_at_its_own_rules(routed_with):
    """MANDATORY undo-after-commit scenario, in the only honest worker-side form:
    the worker holds no state, so "undo" is the board itself losing the copper a
    commit added.

    What must hold across the round trip is that the run's effective rules are a
    pure function of the board's OWN design rules — a commit and its undo change
    the copper census, never the width the next run reserves space for. (An
    implementation that cached the resolved pair, or derived it from what was
    already routed, would drift here and nowhere else.)
    """
    board = _three_pin_board()

    # Pre-commit: routes, at the board's rules.
    before = _call_route({"board": board})
    assert before["ok"] is True, before
    width_before = routed_with["engine"]
    clearance_before = routed_with["engine_clearance"]
    assert width_before == pytest.approx(BOARD_WIDTH_MM)

    # Committed: since T7 (019f70ebc9ed) the grid MODELS accepted copper, so the
    # board is routable again — this is the whole point of the item, because
    # before it the first accepted proposal ended the iterative workflow. The
    # rules it routes at are still the board's own.
    committed = _call_route({"board": _committed(board)})
    assert committed["ok"] is True, committed
    assert routed_with["engine"] == pytest.approx(width_before)
    assert routed_with["engine_clearance"] == pytest.approx(clearance_before)

    # Undone: the copper is gone, and the board routes again at the SAME rules.
    after = _call_route({"board": _undone(_committed(board))})
    assert after["ok"] is True, after
    assert routed_with["engine"] == pytest.approx(width_before)
    assert routed_with["engine_clearance"] == pytest.approx(clearance_before)

    rb_before = _compile(board)
    rb_after = _compile(_undone(_committed(board)))
    assert methods._effective_routing_rules({}, rb_before) == \
        methods._effective_routing_rules({}, rb_after)

    # The proposal itself is the same one, still checked at the width it was
    # routed at — an undo must not quietly relax the geometric gate.
    assert routed_with["overlay"] == pytest.approx(routed_with["engine"])
    assert [r["net"] for r in after["result"]["routes"]] == \
        [r["net"] for r in before["result"]["routes"]]


def test_undo_after_commit_over_a_board_whose_rules_changed_uses_the_new_rules():
    """The other half of "pure function of the board": if the undone board's own
    rules differ, the next run must follow the BOARD, not whatever the previous
    run used."""
    board = _undone(_committed(_three_pin_board()))
    board = dict(board)
    board["design_rules"] = dict(board["design_rules"], trace_width_mm=0.45,
                                 clearance_mm=0.4)
    rb = _compile(board)
    assert methods._effective_routing_rules({}, rb) == pytest.approx((0.45, 0.4))


def test_the_via_the_commit_wrote_comes_from_the_boards_own_routing_defaults():
    """Vias are the other authored dimension in play (routing.md: via diameter and
    drill come from ``design_rules``, the engine's vias being positional only), so
    the mandatory via fixture pins that they survive the compile unchanged."""
    rb = _compile(_three_pin_board())
    assert rb.design_rules.defaults.via_diameter_mm == pytest.approx(0.8)
    assert rb.design_rules.defaults.via_drill_mm == pytest.approx(0.4)
    assert math.isclose(rb.design_rules.defaults.via_drill_mm, 0.4)


# ---------------------------------------------------------------------------
# 4b. EXISTING (already-accepted) copper in the grid — T7, docket 019f70ebc9ed.
#
# Everything below reuses the MANDATORY fixtures above rather than inventing new
# ones, because the shape the gate demands is exactly the shape this feature
# needs: a 3-pin net whose copper is two DISCONNECTED paths joined by a
# layer-changing via is the only shape that can tell "the grid models a via's
# layer span" apart from "the grid models copper on one layer".
#
# `_committed` is the gate's own accepted-copper board and stays exactly as it
# was; `_committed_joined` below is the SAME copper extended so it actually
# lands on P1 and P2, which is what makes the already-connected half observable.
# ---------------------------------------------------------------------------


def _committed_joined(board: dict, *, with_via: bool = True) -> dict:
    """`_committed`'s copper, extended so it genuinely JOINS P1 and P2.

    The gate's own `_committed` copper is a pair of stubs: the top run stops at
    (22,28), nowhere near a pad, and the bottom run reaches P2 only. That is the
    right fixture for "does the board still route at its own rules", and the
    wrong one for "does the router know this net is partly done" — nothing is
    joined, so there is nothing to notice.

    Here the top run continues to (40,20) and the bottom run leaves from there,
    so the electrical chain is P1 -> top copper -> VIA -> bottom copper -> P2.
    Still two disconnected copper paths on two layers plus one layer-changing
    via, exactly as gate 019f70f76c2f requires — the via is now the only thing
    holding the two halves together, which is what `with_via=False` takes away.
    """
    out = dict(board)
    out["traces"] = [
        {"net": "SIG", "layer": "top", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 10.0, "y_mm": 20.0}, {"x_mm": 10.0, "y_mm": 28.0},
                    {"x_mm": 40.0, "y_mm": 28.0}, {"x_mm": 40.0, "y_mm": 20.0}]},
        {"net": "SIG", "layer": "bottom", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 40.0, "y_mm": 20.0}, {"x_mm": 50.0, "y_mm": 20.0}]},
    ]
    if with_via:
        out["vias"] = [{"net": "SIG", "x_mm": 40.0, "y_mm": 20.0,
                        "diameter_mm": 0.8, "drill_mm": 0.4,
                        "from_layer": "top", "to_layer": "bottom"}]
    return out


def _engine_run(board_dict: dict):
    """Compile a board and route it through the ENGINE entry point, with the
    accepted copper the bridge projects for it.

    `_call_route` cannot answer the questions below: `_serialize_routing_result`
    FLATTENS a route's paths into one segment list, so how many CONNECTIONS the
    router decided it still needed is not recoverable from the reply. `route_board`
    is a real entry point (it is what `methods._route` calls), and `Route.paths`
    is one entry per connection — which is the number this feature changes.
    """
    rb = _compile(board_dict)
    engine_board = route_bridge.resolved_board_to_router(rb)
    existing_traces, existing_vias = \
        route_bridge.resolved_board_existing_copper(rb)
    width, clearance = methods._effective_routing_rules({}, rb)
    return engine_router.route_board(
        engine_board, trace_width=width, clearance=clearance,
        existing_traces=existing_traces, existing_vias=existing_vias)


def test_a_board_carrying_accepted_copper_is_routable_again():
    """The headline of T7 (019f70ebc9ed), at the real entry point.

    Before this, `_reject_unroutable_board` raised on `rb.traces or rb.vias`, so
    accepting ONE proposal made the board permanently unroutable — the exact
    opposite of the incremental workflow the plugin exists for. The board here is
    the mandatory gate fixture with its commit applied.
    """
    resp = _call_route({"board": _committed(_three_pin_board())})
    assert resp["ok"] is True, resp
    assert resp["result"]["routes"], resp["result"]


def test_the_via_is_what_joins_the_two_halves_of_an_accepted_net():
    """MANDATORY FIXTURE SHAPE (gate 019f70f76c2f), used as the discriminator.

    P1 is joined to the accepted TOP copper, P2 to the accepted BOTTOM copper,
    and NOTHING but the via connects the two. So:

      * with the via, SIG's remaining work is ONE connection (P3 into the joined
        group);
      * take the via away and the same copper leaves THREE separate groups
        {P1..top}, {P2..bottom}, {P3} — TWO connections.

    That difference is only visible if the grid models a via's LAYER SPAN. A via
    modeled on one layer, or not modeled at all, gives the two-connection answer
    with the via present, which is what this pins.

    Honest note on engine via PRODUCTION: the run still emits ZERO vias of its own
    on this fixture (verified — `Route.vias` is empty on both runs). The via here
    is one the board ALREADY CARRIES, which is what this item is about; the reply
    shape carrying an engine-produced via remains STAGED, in
    `_three_pin_route_reply`, and says so.
    """
    joined = _engine_run(_committed_joined(_three_pin_board()))
    split = _engine_run(_committed_joined(_three_pin_board(), with_via=False))

    sig_joined = joined.get_route("SIG")
    sig_split = split.get_route("SIG")
    assert sig_joined is not None and sig_split is not None
    assert len(sig_joined.paths) == 1, \
        "P1 and P2 are already joined THROUGH the via; only P3 is still loose"
    assert len(sig_split.paths) == 2, \
        "without the via the accepted copper leaves three groups, not two"
    assert not joined.unrouted and not split.unrouted


def test_a_net_wholly_joined_by_accepted_copper_gets_no_proposal_at_all():
    """The degenerate end of the same rule, and the one that would silently
    duplicate copper if `_build_spanning_tree`'s two-pad short-circuit had been
    left asking the old question. OTHER (X1/X2) is a 2-pad net, so it never
    reaches the Prim loop at all — it takes the `len(pads) == 2` branch, which had
    to learn the same question the loop asks."""
    board = _committed_joined(_three_pin_board())
    board["traces"] = list(board["traces"]) + [
        {"net": "OTHER", "layer": "top", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 30.0, "y_mm": 8.0}, {"x_mm": 56.0, "y_mm": 8.0},
                    {"x_mm": 56.0, "y_mm": 34.0}, {"x_mm": 50.0, "y_mm": 34.0}]},
    ]
    result = _engine_run(board)
    assert result.get_route("OTHER") is None, \
        "OTHER's pads are already joined by accepted copper — nothing to propose"
    assert not result.unrouted
    # ...and the net that is NOT finished still gets its proposal.
    assert result.get_route("SIG") is not None


def test_accepted_foreign_copper_reserves_the_same_margin_as_copper_just_routed():
    """Other-net copper is an OBSTACLE, inflated through the SAME single owner
    (`RoutingGrid.keepout_margin`) as the copper this run lays — never through a
    second, hand-inflated path. A previous round shipped exactly that second path
    and it had to be undone, so this probes the DISTANCE rather than the spelling:
    the reserved half-extent must be the accepted copper's own half-width plus
    the margin, which is strictly more than the `w/2 + clearance` a hand-rolled
    inflation reaches for.

    Driven through `route_board` with real projected copper, so it exercises the
    call site rather than `mark_trace` in isolation.
    """
    width_mm, clearance_mm, resolution_mm = 1.2, 0.2, 0.05
    rb = _compile(_committed_joined(_three_pin_board()))
    engine_board = route_bridge.resolved_board_to_router(rb)
    existing_traces, existing_vias = \
        route_bridge.resolved_board_existing_copper(rb)

    grid = RoutingGrid(width=engine_board.width, height=engine_board.height,
                       resolution=resolution_mm, clearance=clearance_mm,
                       origin=engine_board.origin, trace_width=width_mm)
    engine_router._mark_existing_copper(
        grid, existing_traces, existing_vias, grid.layers)

    seg = next(s for s in existing_traces
               if s.layer == "F.Cu" and s.start[1] == s.end[1] == 28.0)
    half = seg.width / 2.0
    old_reach = half + clearance_mm                  # a hand-inflated `w + 2c`
    new_reach = half + grid.keepout_margin           # what the one owner reserves
    assert new_reach > old_reach + 3 * resolution_mm, "probe band must be real"

    mid_x = (seg.start[0] + seg.end[0]) / 2.0
    band = 28.0 + (old_reach + new_reach) / 2.0
    assert grid.can_route_through(mid_x, band, net="OTHER", layer="F.Cu") is False
    # ...and its OWN net is not kept out of its own copper.
    assert grid.can_route_through(mid_x, band, net="SIG", layer="F.Cu") is True
    assert grid.get_cell(mid_x, 28.0, "F.Cu").obstacle_type == "trace"
    assert grid.get_cell(mid_x, 28.0, "F.Cu").net == "SIG"

    # The accepted VIA came through the same call, and reserves the same margin
    # around its annulus — on BOTH layers, which is the half a single-layer
    # model would leave open.
    via = existing_vias[0]
    via_reach = via.diameter / 2.0 + grid.keepout_margin
    for layer in ("F.Cu", "B.Cu"):
        assert grid.get_cell(via.position[0], via.position[1],
                             layer).net == "SIG"
        assert grid.can_route_through(via.position[0] + via_reach - 0.05,
                                      via.position[1], net="OTHER",
                                      layer=layer) is False


def test_an_accepted_via_is_its_nets_copper_on_both_layers_not_a_hole():
    """A via is the one copper primitive that is not confined to a layer, and the
    grid's other disc marker (`mark_obstacle`) would model it WRONGLY in two ways
    at once: an obstacle owns no net, so the via's own net would be locked out of
    its own copper, and it is only ever marked as a keepout, never as something a
    net may route to."""
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_via(x=10.0, y=10.0, diameter=0.8, net="SIG")

    for layer in ("F.Cu", "B.Cu"):
        assert grid.get_cell(10.0, 10.0, layer).obstacle_type == "via"
        assert grid.get_cell(10.0, 10.0, layer).net == "SIG"
        assert grid.can_route_through(10.0, 10.0, net="SIG", layer=layer) is True
        assert grid.can_route_through(10.0, 10.0, net="OTHER", layer=layer) is False
        # The ring is the same single owner's, on both layers.
        probe = 0.4 + grid.keepout_margin - 0.05
        assert grid.can_route_through(10.0 + probe, 10.0, net="OTHER",
                                      layer=layer) is False
        assert grid.can_route_through(10.0 + 0.4 + grid.keepout_margin + 0.15,
                                      10.0, net="OTHER", layer=layer) is True


def _walled_board(*, with_copper: bool) -> dict:
    """SIG's two pads with a foreign net's accepted copper SEALING the board
    between them — a wall at x=30 on BOTH layers, pad to pad, so there is no gap
    and no via can get under it.

    Built as an explicit before/after pair rather than as one board, because the
    point is the COUNTERFACTUAL: `with_copper=False` is the same geometry with
    the wall's copper never accepted, which is also exactly what the board looks
    like to a router that cannot see accepted copper.
    """
    def _tp(ref: str, x: float, y: float) -> dict:
        return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
                "rotation_deg": 0, "layer": "top",
                "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                          "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}

    board = {
        "version": 1, "name": "sealed-wall", "width_mm": 60, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": BOARD_CLEARANCE_MM,
                         "trace_width_mm": BOARD_WIDTH_MM,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [_tp("S1", 10, 20), _tp("S2", 50, 20),
                       _tp("B1", 30, 1), _tp("B2", 30, 39)],
        "nets": [{"name": "SIG", "pins": ["S1.1", "S2.1"]},
                 {"name": "BLK", "pins": ["B1.1", "B2.1"]}],
    }
    if with_copper:
        board["traces"] = [
            {"net": "BLK", "layer": layer, "width_mm": BOARD_WIDTH_MM,
             "points": [{"x_mm": 30, "y_mm": 1}, {"x_mm": 30, "y_mm": 39}]}
            for layer in ("top", "bottom")]
    return board


def test_invisible_foreign_copper_would_short_and_visible_copper_does_not():
    """END-TO-END SHORT DETECTION through `route()`, with both sides asserted.

    The wall seals the board on both layers, so with the accepted copper VISIBLE
    the only honest answer is "I cannot route this": SIG comes back UNROUTED with
    ZERO proposals, and the geometric overlay is clean because nothing was
    proposed to be unclean about.

    The same board with that copper never accepted — which is precisely what the
    board looked like to the pre-T7 router — routes SIG straight through where
    the wall would be, and the GEOMETRIC overlay (the real short detector, not
    the centerline-only connectivity kernel) reports `violations`. That is the
    short this item exists to prevent, demonstrated rather than asserted about.

    WHY THIS FIXTURE AND NOT A DETOUR ONE: a fully-sealed board has no detour to
    simplify, so it isolates exactly the behaviour under test — whether the
    accepted copper was SEEN — from anything the path simplifier does with a
    curve. That separation was originally forced: `_simplify_path` used to
    collapse an A* detour into a chord through cells the grid correctly blocked,
    so any detour fixture reported geometric violations for an unrelated reason.
    That defect is fixed (019f9bd5f2f2), and the detour case now carries its own
    geometric assertion — see
    tests/test_route_drc.py::test_the_detour_that_exposed_the_bug_is_geometrically_clean.
    This fixture stays as-is regardless: one test, one variable.
    """
    sealed = _call_route({"board": _walled_board(with_copper=True)})
    assert sealed["ok"] is True, sealed
    result = sealed["result"]
    assert result["routes"] == [], \
        "with the wall visible there is no honest proposal to make"
    assert [u["net"] for u in result["unrouted"]] == ["SIG"]
    assert result["success"] is False
    assert result["drc_geometric_summary"]["verdict"] == "clean"

    # The counterfactual: the same geometry with that copper unseen.
    open_board = _call_route({"board": _walled_board(with_copper=False)})
    assert open_board["ok"] is True, open_board
    unsealed = open_board["result"]
    assert sorted(r["net"] for r in unsealed["routes"]) == ["BLK", "SIG"]
    assert unsealed["success"] is True
    assert unsealed["drc_geometric_summary"]["verdict"] == "violations", \
        "routing as if the wall were not there is exactly the short T7 prevents"


def _stubbed(board: dict, gap_mm: float) -> dict:
    """SIG with TWO accepted stubs that do NOT meet: one out of P1, one out of
    P2, separated by a real air gap of ``gap_mm`` on the same layer.

    The gap is genuine copper-to-copper separation — at BOARD_WIDTH_MM (0.35) the
    two runs' copper reaches 0.175mm past each endpoint, so anything wider than
    0.35mm between the endpoints is air. P1 and P2 therefore still need a route.
    """
    out = dict(board)
    meet = 30.0
    out["traces"] = [
        {"net": "SIG", "layer": "top", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": 10.0, "y_mm": 20.0},
                    {"x_mm": meet - gap_mm, "y_mm": 20.0}]},
        {"net": "SIG", "layer": "top", "width_mm": BOARD_WIDTH_MM,
         "points": [{"x_mm": meet, "y_mm": 20.0}, {"x_mm": 50.0, "y_mm": 20.0}]},
    ]
    out.pop("vias", None)
    return out


@pytest.mark.parametrize("resolution_mm", [0.1, 0.5])
def test_a_coarse_caller_grid_cannot_merge_two_genuinely_separate_stubs(
        resolution_mm):
    """The coincidence tolerance is capped in MILLIMETRES, not in cells.

    ``grid_resolution`` is a CALLER OPTION — ``methods._route`` passes
    ``options.grid_resolution`` straight through to the engine — so a tolerance
    of "one cell" is a tolerance the caller can inflate. At 0.5mm a 0.4mm air gap
    between two same-net stubs is under one cell, and the two stubs would merge
    into one pre-connected group. The router would then skip the P1<->P2
    connection and the reply would report SIG as routed while it is OPEN: the
    over-count `_preconnected_groups` exists to prevent, reached not through bad
    copper but through a caller's choice of grid.

    The cap is the narrowest copper involved (half of 0.35mm = 0.175mm), which is
    smaller than the gap at BOTH resolutions — so the answer must not depend on
    the resolution at all. Driven through ``route_board`` because the count that
    changes is the number of CONNECTIONS, which the serialized reply flattens
    away.
    """
    gap_mm = 0.4
    rb = _compile(_stubbed(_three_pin_board(), gap_mm))
    engine_board = route_bridge.resolved_board_to_router(rb)
    existing_traces, existing_vias = \
        route_bridge.resolved_board_existing_copper(rb)
    width, clearance = methods._effective_routing_rules({}, rb)

    assert gap_mm > width, "the gap must be real air, not touching copper"

    result = engine_router.route_board(
        engine_board, trace_width=width, clearance=clearance,
        grid_resolution=resolution_mm,
        existing_traces=existing_traces, existing_vias=existing_vias)

    sig = result.get_route("SIG")
    assert sig is not None, "SIG is not finished — it must still be proposed"
    # Three groups ({P1..stub}, {stub..P2}, {P3}) => two connections. A merged
    # pair would give one, and would leave the air gap unrouted.
    assert len(sig.paths) == 2, \
        f"at {resolution_mm}mm the stubs must stay separate, got " \
        f"{len(sig.paths)} connection(s)"


def test_the_tolerance_cap_is_the_narrowest_copper_not_the_grid():
    """The cap itself, stated as the arithmetic rather than only its effect: it
    is the SMALLER of the quantisation term and the narrowest copper's own
    half-extent, so neither a coarse grid nor a wide trace can grow it."""
    seg = engine_router.ExistingSegment(net="SIG", start=(0.0, 0.0),
                                        end=(10.0, 0.0), width=0.35,
                                        layer="F.Cu")
    via = engine_router.ExistingVia(net="SIG", position=(10.0, 0.0),
                                    diameter=0.8, layers=("F.Cu", "B.Cu"))
    # Coarse grid: copper wins.
    assert engine_router._coincidence_tolerance(0.5, [seg], [via]) == \
        pytest.approx(0.175)
    # Fine grid: quantisation wins, which is the pre-existing behaviour.
    assert engine_router._coincidence_tolerance(0.1, [seg], [via]) == \
        pytest.approx(0.1)
    # The NARROWEST piece sets it, not the average or the widest.
    wide = dataclasses.replace(seg, width=2.0)
    assert engine_router._coincidence_tolerance(0.5, [wide], [via]) == \
        pytest.approx(0.4)


def test_a_copper_mark_can_never_re_net_a_hole():
    """A hole is an ABSOLUTE veto and the guard must be the marker's, not the
    caller's ordering (cold review note 3). ``mark_trace``/``mark_via`` are
    public, and the engine's own routed traces are marked AFTER obstacles, where
    `_cell_range`'s one-cell over-claim can touch a hole cell no route ever
    entered. If a copper mark could re-net it, `can_route_through` — which lets a
    net cross its own cells — would hand that net a path through a mounting hole.
    """
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_obstacle(x=10.0, y=10.0, radius=0.5)

    for mark in (
        lambda: grid.mark_trace(start=(5.0, 10.0), end=(15.0, 10.0),
                                width=0.5, net="SIG"),
        lambda: grid.mark_via(x=10.0, y=10.0, diameter=0.8, net="SIG"),
    ):
        mark()
        cell = grid.get_cell(10.0, 10.0)
        assert cell.obstacle_type == "hole" and cell.net is None
        assert grid.can_route_through(10.0, 10.0, net="SIG") is False


def test_marked_copper_never_steals_another_owners_copper():
    """The guard T7 needed in `_mark_copper_cell`.

    Every copper mark used to come from the ENGINE — a pad from the board census,
    or a trace the pathfinder had just been PERMITTED to lay — so an unconditional
    overwrite was unreachable. Importing the board's own accepted copper marks
    geometry the grid never approved: an accepted trace overlapping a foreign (or
    unconnected) pad, i.e. a board that is ALREADY shorted, would hand that pad's
    land to the trace's net, and `can_route_through` lets a net cross its own
    cells. Describing the board more completely would then have LICENSED routing
    through real copper.

    Probed at the marker, honestly: on a well-formed board the two never overlap,
    so there is no end-to-end route this changes. Its whole job is to keep an
    already-broken board from making the router worse.
    """
    grid = RoutingGrid(width=20, height=20, resolution=0.05,
                       clearance=0.3, trace_width=0.5)
    grid.mark_pad(x=10.0, y=10.0, size=(1.0, 1.0), net="PADNET")
    grid.mark_pad(x=14.0, y=10.0, size=(1.0, 1.0), net=None)
    # Accepted copper laid straight over both — the shorted-board case.
    grid.mark_trace(start=(5.0, 10.0), end=(16.0, 10.0), width=0.5, net="SIG")

    assert grid.get_cell(10.0, 10.0).net == "PADNET"
    assert grid.can_route_through(10.0, 10.0, net="SIG") is False
    assert grid.get_cell(14.0, 10.0).net is None
    assert grid.can_route_through(14.0, 10.0, net="SIG") is False
    # Copper the mark legitimately owns is still written.
    assert grid.get_cell(7.0, 10.0).obstacle_type == "trace"
    assert grid.get_cell(7.0, 10.0).net == "SIG"


def test_accepted_copper_on_an_unmodelable_via_span_still_fails_closed():
    """Narrowing a fail-closed reason is right; deleting it while a sub-case is
    still unmodelable is not. A via that reaches a layer the 2-layer grid does not
    carry would be modeled as half copper and half nothing — worse than not
    routing — so it keeps failing closed with the same `unsupported_geometry`
    vocabulary.

    UNREACHABLE ON A REAL BOARD TODAY, and the fixture has to say so out loud:
    `compile_board._build_vias` rejects any span outside [top, bottom], and
    `ResolvedBoard.__post_init__` rejects it a second time via
    `layer_stack.is_legal_via_span` — so `dataclasses.replace(rb, vias=...)`
    cannot even build the board this needs. What is passed in is therefore a
    stand-in carrying a real `ResolvedVia` (which permits the span; only the
    BOARD forbids it) on a real layer stack. It exercises the guard, not a
    scenario the compiler can produce — which is exactly what a defence-in-depth
    guard is, and pretending otherwise would be the coverage claim this file's
    header warns against."""
    rb = _compile(_committed_joined(_three_pin_board()))

    class _BoardWithAnInnerLayerVia:
        layer_stack = rb.layer_stack
        nets = rb.nets
        traces = ()
        vias = (dataclasses.replace(rb.vias[0], to_layer="In1.Cu"),)

    with pytest.raises(route_bridge.UnsupportedGeometry) as exc:
        route_bridge.resolved_board_existing_copper(_BoardWithAnInnerLayerVia())
    assert "In1.Cu" in str(exc.value)


# ---------------------------------------------------------------------------
# 5. Per-net-class minima — the NEW precedence step this round adds.
#
# The v1 compiler emits NO net classes at all (compile_board.py hardcodes
# `net_classes=()`; verified below) and sets no net's `net_class_id` — so the
# only way to drive this feature through the REAL `route()` entry point is to
# monkeypatch the compile step itself, exactly the way the existing
# drc_geometric fail-closed guard (docket 019f958b45b9) is only reachable via
# `dataclasses.replace` in a test. `net_classed_compile` below does that for
# the FULL `_call_route` path rather than for an internal helper, so a
# reverted call site (not just a reverted resolver function) is what these
# tests actually exercise.
#
# TWO DIFFERENT SHAPES, on purpose (Codex must-fix on this round's first cut):
#   * COPPER WIDTH is genuinely per-net — `net_widths` in router.py, sourced
#     from `_net_class_overrides` below. A net's own class draws ITS OWN
#     copper wider or narrower; nobody else is affected.
#   * The KEEPOUT MARGIN is NOT per-net — a ring sized to one net's own
#     requirement cannot also satisfy a STRICTER class net that approaches
#     that copper later (an under-block; routing.md's superset invariant has
#     no net-class exception). So the grid's own clearance/trace_width are
#     the board-wide WORST CASE any present class demands, applied to EVERY
#     marking uniformly — see `_widen_for_net_classes` in methods.py.
# ---------------------------------------------------------------------------

CLASS_WIDTH_MM = 0.6       # wider than BOARD_WIDTH_MM (0.35)
CLASS_CLEARANCE_MM = 0.5   # wider than BOARD_CLEARANCE_MM (0.3)


def _apply_net_class_to(rb, net_name: str, nc: NetClass):
    """Same `dataclasses.replace` shape test_drc_geometric.py's
    `_apply_net_class` uses, narrowed to ONE net rather than every net on the
    board — so a fixture with two nets can pin that the class WIDTH affects
    ONLY the net it is assigned to (even though the keepout margin, being
    board-wide, ends up affecting both — see below)."""
    dr = dataclasses.replace(rb.design_rules, net_classes=(nc,))
    nets = tuple(
        dataclasses.replace(n, net_class_id=nc.id) if n.name == net_name else n
        for n in rb.nets)
    return dataclasses.replace(rb, design_rules=dr, nets=nets)


@pytest.fixture
def net_classed_compile(monkeypatch):
    """Patch the compiler `_route` actually calls so its ResolvedBoard carries
    ONE net class, assigned to ONE net — set ``state["nc"]``/``state["net"]``
    before calling `_call_route`/`handle_request`, and every compile for the
    rest of the test sees it. Returns the mutable state dict.
    """
    real_compile = cb.compile_board
    state: dict = {"nc": None, "net": None}

    def spy(board, **kw):
        result = real_compile(board, **kw)
        if state["nc"] is not None and isinstance(result, cb.ResolutionSuccess):
            rb2 = _apply_net_class_to(result.board, state["net"], state["nc"])
            result = dataclasses.replace(result, board=rb2)
        return result

    monkeypatch.setattr(cb, "compile_board", spy)
    return state


# ---------------------------------------------------------------------------
# 5a. Provenance source coverage (note from Codex review: `hint` and
# `engine_default` were the two of the five source labels no test named).
# ---------------------------------------------------------------------------


def test_the_reply_names_a_hint_authored_width_as_its_own_source():
    """`source: "hint"` is the ONE non-trivial refinement in `_route` (it is
    the only label `_effective_routing_rules_detailed` cannot itself produce
    — see its docstring — because by the time it runs, an explicit caller
    option and a merged hint width are indistinguishable; only `_route`,
    which still has both pieces of information, can tell them apart). No
    prior test named it."""
    board = _three_pin_board()
    hint = {"id": "h1", "kind": "pcb_route_hint", "lifecycle": "open",
            "author": {"kind": "human"},
            "kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
                             "net_names": ["SIG"], "waypoints": [],
                             "width_mm": 0.5}}
    resp = _call_route({"board": board, "route_hints": [hint]})
    assert resp["ok"] is True, resp
    assert resp["result"]["effective_routing_rules"]["trace_width_mm"] == \
        {"value": pytest.approx(0.5), "source": "hint"}


def test_the_reply_names_the_engines_own_default_as_its_source(monkeypatch):
    """`source: "engine_default"` — the last-resort step, unreachable on any
    board this fixture set can author (the board always carries
    `design_rules.defaults.trace_width_mm`/`minimums.min_clearance_mm`), so
    pinned the same way `test_a_zero_engine_default_would_still_be_sourced_
    not_skipped` already forces that step: neutralise the board-rules reader
    so only the engine's signature default is left."""
    monkeypatch.setattr(engine_router, "_board_rule_mm", lambda *a, **k: None)
    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    rules = resp["result"]["effective_routing_rules"]
    assert rules["trace_width_mm"]["source"] == "engine_default"
    assert rules["clearance_mm"]["source"] == "engine_default"
    assert rules["trace_width_mm"]["value"] == \
        pytest.approx(methods._engine_default_mm("trace_width"))
    assert rules["clearance_mm"]["value"] == \
        pytest.approx(methods._engine_default_mm("clearance"))


def test_the_v1_compiler_emits_no_net_classes_and_no_net_class_id():
    """Verifies the finding this round's report leads with: the IR carries the
    slot (design_rules.net_classes, ResolvedNet.net_class_id) but nothing in
    the v1 compiler ever populates either one from board input — a real
    compile always has an empty tuple and every net's id is None, regardless
    of what a caller puts in the board dict. Everything below this point is
    therefore DORMANT on any board the compiler can actually produce today;
    it is exercised only via `_apply_net_class_to` / `net_classed_compile`.
    """
    board = _three_pin_board()
    board["design_rules"] = dict(
        board["design_rules"],
        net_classes=[{"id": "nc:power", "name": "Power", "min_trace_width_mm": 0.6}])
    for net in board["nets"]:
        net["net_class"] = "nc:power"  # not a field the compiler reads either
    rb = _compile(board)
    assert rb.design_rules.net_classes == ()
    assert all(net.net_class_id is None for net in rb.nets)


def test_net_class_overrides_reads_only_the_min_prefixed_fields():
    """Routing sources the class's MINIMA (min_trace_width_mm/min_clearance_mm)
    — the same two fields drc_geometric's existing guard watches — never the
    plain `trace_width_mm` (that mirrors RoutingDefaults' nominal default, a
    different concept). A class carrying only the nominal field contributes
    NOTHING to either dimension."""
    rb = _compile(_three_pin_board())

    rb_min = _apply_net_class_to(rb, "SIG", NetClass(
        id="nc:power", name="Power",
        min_trace_width_mm=CLASS_WIDTH_MM, min_clearance_mm=CLASS_CLEARANCE_MM))
    overrides = methods._net_class_overrides(rb_min)
    assert overrides == {"SIG": (pytest.approx(CLASS_WIDTH_MM),
                                 pytest.approx(CLASS_CLEARANCE_MM))}
    assert "OTHER" not in overrides   # unassigned net: untouched

    rb_nominal = _apply_net_class_to(rb, "SIG", NetClass(
        id="nc:nominal", name="Nominal", trace_width_mm=0.9))
    assert methods._net_class_overrides(rb_nominal) == {}


def test_net_class_with_no_relevant_minima_does_not_override():
    """A class naming only an UNRELATED field (via sizing) must not trip an
    override for either dimension — mirrors drc_geometric's own
    `test_net_class_without_relevant_minima_does_not_trip`."""
    rb = _compile(_three_pin_board())
    rb2 = _apply_net_class_to(rb, "SIG", NetClass(
        id="nc:route", name="Route", via_diameter_mm=0.9))
    assert methods._net_class_overrides(rb2) == {}


def test_a_net_classes_inadmissible_minimum_fails_closed_not_reinterpreted():
    """Same posture as an inadmissible explicit caller option (E1's nominal
    land, A5's 0x0 pad, this chain's non-positive explicit width): a class
    that NAMES a rule it cannot source fails the whole run rather than being
    quietly treated as if the class had said nothing.

    ``NetClass.__post_init__`` (resolved_board.py) already rejects a negative/
    NaN/inf value for either field at CONSTRUCTION time (``_nonnegative`` /
    ``_finite``), so ``0`` is the ONLY inadmissible-but-constructible width —
    zero is a legal ``NetClass.min_trace_width_mm`` (non-negative) but not a
    legal routing width (zero-width copper is not copper), exactly the gap
    ``_explicit_mm`` already closes for an explicit caller option. There is no
    equivalent reachable case for clearance: zero IS a legal clearance both at
    the IR level and for routing, and anything else is unconstructable — the
    second assertion below pins that this class of bug (an inadmissible float
    reaching the resolver at all) is closed one layer up, at the dataclass.
    """
    rb = _compile(_three_pin_board())
    rb2 = _apply_net_class_to(rb, "SIG", NetClass(
        id="nc:bad", name="Bad", min_trace_width_mm=0))
    with pytest.raises(route_bridge.UnsupportedGeometry, match="min_trace_width_mm"):
        methods._net_class_overrides(rb2)

    for bad in (-1.0, float("nan"), float("inf"), True):
        with pytest.raises(ValueError):
            NetClass(id="nc:bad", name="Bad", min_clearance_mm=bad)
        with pytest.raises(ValueError):
            NetClass(id="nc:bad", name="Bad", min_trace_width_mm=bad)


def test_a_net_classes_inadmissible_minimum_fails_the_real_route_call(net_classed_compile):
    """The SAME rule, reached through the REAL entry point rather than by
    calling the resolver directly — zero routes, structured error, same
    vocabulary as every other unsourceable rule in the chain."""
    net_classed_compile["nc"] = NetClass(id="nc:bad", name="Bad", min_trace_width_mm=0)
    net_classed_compile["net"] = "SIG"

    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is False, resp
    assert resp["error"]["kind"] == "unsupported_geometry"
    assert "min_trace_width_mm" in resp["error"]["message"]
    assert "routes" not in resp.get("result", {})


def test_net_class_width_widens_only_that_nets_own_copper(recorded_grids):
    """COPPER WIDTH is per-net: SIG (net-classed) draws at CLASS_WIDTH_MM,
    OTHER (no class) still draws at the board's own baseline. Driven through
    `route_board` itself (not `_net_class_overrides`), which is the real call
    site that decides what width a segment is marked at.

    Probes a band strictly between the baseline's half-width and the class's:
    a point there is COPPER only if the net's ACTUAL drawn width is the wider
    class one — reverting `net_widths` back to a no-op would leave that point
    as a bare clearance ring (or free space) instead.
    """
    rb = _compile(_three_pin_board())
    rb2 = _apply_net_class_to(rb, "SIG", NetClass(
        id="nc:power", name="Power", min_trace_width_mm=CLASS_WIDTH_MM))
    board = route_bridge.resolved_board_to_router(rb2)
    net_widths = {"SIG": CLASS_WIDTH_MM}

    result = engine_router.route_board(
        board, trace_width=BOARD_WIDTH_MM, clearance=BOARD_CLEARANCE_MM,
        grid_resolution=0.02, net_widths=net_widths)
    grid = recorded_grids[0]
    sig = next(r for r in result.routes if r.net == "SIG")

    probed = 0
    probe = (BOARD_WIDTH_MM / 2.0 + CLASS_WIDTH_MM / 2.0) / 2.0
    for s in sig.segments:
        dx, dy = s.end[0] - s.start[0], s.end[1] - s.start[1]
        span = math.hypot(dx, dy)
        if span < 0.3:
            continue
        mx, my = (s.start[0] + s.end[0]) / 2.0, (s.start[1] + s.end[1]) / 2.0
        nx, ny = -dy / span, dx / span
        for sign in (1.0, -1.0):
            px, py = mx + sign * nx * probe, my + sign * ny * probe
            assert grid.get_cell(px, py, layer=s.layer).obstacle_type == "trace", (
                f"({px:.3f},{py:.3f}) is inside SIG's class-width copper "
                f"({CLASS_WIDTH_MM}mm) but outside the board baseline "
                f"({BOARD_WIDTH_MM}mm) — must be copper, not ring/free space")
            probed += 1
    assert probed >= 2, "need probe points along a real SIG segment"


def test_bus_routing_honours_net_class_width_not_just_the_bus_baseline():
    """MUST-FIX (Codex review): before this fix, ``route_bus`` never consulted
    ``net_widths`` at all, so a bus-routed net-classed net's COPPER was always
    laid at the run's baseline width while the reply's provenance (this
    round's ``_attach_effective_routing_rules``) still stamped it
    ``{"source": "net_class", "value": <class width>}`` — a LYING provenance
    field (worse than none), and a false clean in the candidate overlay
    (``ir_candidates.build_overlay`` reads a segment's own ``width_mm`` first,
    so it would have checked the proposal at a width it was never routed at).

    Driven directly through ``route_bus`` — the real call site
    ``route_board_with_hints`` delegates to for every bus — mirroring
    ``TestBusRouting.test_route_bus_creates_parallel_traces`` in
    ``tests/agent_router/test_router.py``. SIG_A carries a class override,
    SIG_B does not; both are members of the SAME bus.

    The grid is constructed with ``trace_width=CLASS_WIDTH_MM`` (simulating
    the board-wide worst-case ``keepout_trace_width`` ``methods._route`` would
    compute, since SIG_A's class is present on this board), so BOTH nets'
    RINGS reach the class distance — that part is intentional (see
    docs/routing.md, "Keepout margin"). What must differ is the COPPER core:
    only SIG_A's actually reaches it.
    """
    from agent_router.board import Board as _Board, Pad as _Pad, Net as _Net
    from agent_router.hints import BusHint, Waypoint

    board = _Board(width=40, height=20)
    board.pads = [
        _Pad("U1", "1", "SIG_A", (5, 10), (1, 1)),
        _Pad("U1", "2", "SIG_B", (5, 12), (1, 1)),
        _Pad("U2", "1", "SIG_A", (35, 10), (1, 1)),
        _Pad("U2", "2", "SIG_B", (35, 12), (1, 1)),
    ]
    board.nets = {
        "SIG_A": _Net("SIG_A", 1, [board.pads[0], board.pads[2]]),
        "SIG_B": _Net("SIG_B", 2, [board.pads[1], board.pads[3]]),
    }

    grid = RoutingGrid(width=40, height=20, resolution=0.02,
                       clearance=BOARD_CLEARANCE_MM, trace_width=CLASS_WIDTH_MM)
    bus_hint = BusHint(name="Bus", nets=["SIG_A", "SIG_B"], spacing=2.0,
                       waypoints=[Waypoint(10, 11), Waypoint(30, 11)])

    net_widths = {"SIG_A": CLASS_WIDTH_MM}   # SIG_B: no override, stays baseline
    routes = engine_router.route_bus(
        grid, board, bus_hint, trace_width=BOARD_WIDTH_MM, net_widths=net_widths)
    assert {r.net for r in routes} == {"SIG_A", "SIG_B"}

    sig_a = next(r for r in routes if r.net == "SIG_A")
    sig_b = next(r for r in routes if r.net == "SIG_B")

    # Strictly between the baseline's half-width and the class's.
    probe = (BOARD_WIDTH_MM / 2.0 + CLASS_WIDTH_MM / 2.0) / 2.0
    probed_a = 0
    for s in sig_a.segments:
        dx, dy = s.end[0] - s.start[0], s.end[1] - s.start[1]
        span = math.hypot(dx, dy)
        if span < 3.0:
            continue
        mx, my = (s.start[0] + s.end[0]) / 2.0, (s.start[1] + s.end[1]) / 2.0
        nx, ny = -dy / span, dx / span
        for sign in (1.0, -1.0):
            px, py = mx + sign * nx * probe, my + sign * ny * probe
            assert grid.get_cell(px, py, layer=s.layer).obstacle_type == "trace", (
                f"SIG_A (net_widths override): ({px:.3f},{py:.3f}) must be "
                f"its OWN class-width copper")
            probed_a += 1
    assert probed_a >= 2

    probed_b = 0
    for s in sig_b.segments:
        dx, dy = s.end[0] - s.start[0], s.end[1] - s.start[1]
        span = math.hypot(dx, dy)
        if span < 3.0:
            continue
        mx, my = (s.start[0] + s.end[0]) / 2.0, (s.start[1] + s.end[1]) / 2.0
        nx, ny = -dy / span, dx / span
        px, py = mx + nx * probe, my + ny * probe
        cell = grid.get_cell(px, py, layer=s.layer)
        # SIG_B never got a width override — this point is past its OWN
        # (baseline) copper. It is still inside the board-wide RING (the
        # must-fix from the earlier round), never bare copper.
        assert cell.obstacle_type != "trace", (
            f"SIG_B (no override): ({px:.3f},{py:.3f}) must NOT be copper — "
            f"the bus must not draw a net wider than its own effective width")
        probed_b += 1
    assert probed_b >= 1


def test_a_strict_class_elsewhere_widens_the_keepout_around_an_unclassed_nets_own_copper(
        net_classed_compile, recorded_grids):
    """MUST-FIX (Codex review of this round's first cut): the pairwise gap. A
    ring sized to ONE net's own requirement cannot also satisfy a STRICTER
    class net that approaches the same copper later, so a per-net margin is
    an under-block. The fix is board-wide worst-case sizing: SIG (net-classed,
    wider minima) and OTHER (no class, board baseline) sit on the SAME board,
    and a foreign net must be kept out to SIG's class-driven distance from
    ANY copper on the board — including OTHER's own, UNCLASSED pads and
    traces — because the keepout margin is now a board-wide value, not a
    per-net one (docs/routing.md, "Per-net-class minima" -> "Keepout margin").

    Driven through the REAL entry point (`_call_route`), not through
    `_widen_for_net_classes` or the margin directly: reverting the fix back to
    a per-net-only margin (net_widths feeding BOTH copper width and the ring)
    makes THIS test fail while every per-net-copper-width test above stays
    green — it targets exactly the direction those cannot see.
    """
    net_classed_compile["nc"] = NetClass(
        id="nc:power", name="Power",
        min_trace_width_mm=CLASS_WIDTH_MM, min_clearance_mm=CLASS_CLEARANCE_MM)
    net_classed_compile["net"] = "SIG"

    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    grid = recorded_grids[0]

    board = route_bridge.resolved_board_to_router(_compile(_three_pin_board()))
    x1 = next(p for p in board.pads if p.component == "X1")  # OTHER net, unclassed

    board_reach = BOARD_CLEARANCE_MM + BOARD_WIDTH_MM / 2.0     # the OLD (per-net) reach
    class_reach = CLASS_CLEARANCE_MM + CLASS_WIDTH_MM / 2.0     # what SIG's class demands
    assert class_reach > board_reach

    # A point strictly inside the band a per-net-only fix would have left
    # open (beyond OTHER's own margin, but still inside SIG's class margin).
    # Probed on the LEFT of X1 (away from X2 at (50, 34), i.e. away from the
    # direction OTHER's own route actually travels), so the point cannot be
    # confused with OTHER's own routed copper.
    probe_x = x1.position[0] - x1.size[0] / 2.0 - (board_reach + class_reach) / 2.0
    assert grid.can_route_through(probe_x, x1.position[1], net="NO_SUCH_NET") is False, (
        "OTHER's own (unclassed) pad must still be protected out to the "
        "board's WORST-CASE class distance, not just its own baseline — "
        "a per-net-only margin would leave this point routable")

    # Sanity: well outside even the class reach (same side), the board is
    # free again — this is real free space, not an artifact of the widened
    # margin swallowing the whole board.
    far_x = x1.position[0] - x1.size[0] / 2.0 - class_reach - 0.3
    assert grid.can_route_through(far_x, x1.position[1], net="NO_SUCH_NET") is True


def test_an_explicit_run_wide_clearance_is_never_widened_by_a_net_class(
        net_classed_compile, routed_with):
    """The OTHER half of "admitted or rejected, never reinterpreted": an
    explicit caller clearance fixes the WHOLE RUN's value, full stop — even
    the coordinator-mandated worst-case widening must not touch it, or an
    explicit `clearance: 0.1` would silently become something else."""
    net_classed_compile["nc"] = NetClass(
        id="nc:power", name="Power", min_clearance_mm=CLASS_CLEARANCE_MM)
    net_classed_compile["net"] = "SIG"

    resp = _call_route({"board": _three_pin_board(),
                        "options": {"clearance": 0.1}})
    assert resp["ok"] is True, resp
    assert routed_with["engine_clearance"] == pytest.approx(0.1)
    assert resp["result"]["effective_routing_rules"]["clearance_mm"] == \
        {"value": pytest.approx(0.1), "source": "caller_option"}


def test_the_three_pin_fixture_routes_a_net_classed_net_end_to_end(
        net_classed_compile, routed_with):
    """The 3-pin fixture, driven through the REAL entry point with a net
    class on SIG. WHAT THIS COVERS: a genuine multi-segment reply out of the
    real engine, and that the provenance/stamping mechanism (source labels,
    per-segment width_mm, the candidate overlay) is correct on it.

    WHAT THIS DOES NOT COVER: gate 019f70f76c2f's two-disconnected-paths +
    layer-changing-via shape. Verified (both with and without a net class):
    the real pathfinder on THIS geometry needs no via and produces ONE
    connected F.Cu polyline of exactly 6 segments, 0 vias — nothing in this
    fixture forces a layer change, so the engine never chooses one. That
    shape is a property of the geometry, not of net classing, so a
    net-class-specific fixture cannot make the real engine produce it either
    without changing the geometry (out of scope for what this test pins).
    The mandatory via/disconnected-path shape for THIS round is instead
    covered on the reused STAGED fixture (`_three_pin_route_reply`, same one
    the pre-existing `test_a_three_pin_two_path_route_with_a_via_is_
    projected_at_the_run_width` uses) by
    `test_the_staged_via_fixture_is_projected_at_a_net_classed_nets_own_width`
    below — proving the stamping mechanism this round adds is correct on
    exactly the shape the gate cares about, per "reuse rather than rebuild".
    """
    net_classed_compile["nc"] = NetClass(
        id="nc:power", name="Power",
        min_trace_width_mm=CLASS_WIDTH_MM, min_clearance_mm=CLASS_CLEARANCE_MM)
    net_classed_compile["net"] = "SIG"

    resp = _call_route({"board": _three_pin_board()})
    assert resp["ok"] is True, resp
    sig = next(r for r in resp["result"]["routes"] if r["net"] == "SIG")
    other = [r for r in resp["result"]["routes"] if r["net"] == "OTHER"]
    # The real engine's actual shape for this geometry (pinned so a future
    # change to the geometry or the engine that DOES start needing a via is
    # noticed here, rather than this test silently keeping stale numbers).
    #
    # WAS 4 BEFORE 019f9bd5f2f2, AND THE OLD 4 WAS NOT A BUG. Stated plainly
    # because "the expected value moved" usually means a test had encoded a
    # defect, and this one had not: the pre-fix 4-segment polyline was probed
    # against the routing grid and had ZERO blocked points, i.e. it was a legal
    # simplification that happened to be safe. The count rose because the
    # simplifier now REFUSES any drop whose replacement chord it has not proved
    # clear, and it decides incrementally — when an intermediate chord is
    # blocked it anchors at the last verified point, even in cases where some
    # longer chord past it would have been clear. That is the deliberate trade
    # (see pathfinder._simplify_path): the failure mode is extra vertices, never
    # copper through a keepout. Both shapes are clean; only one is *proved* so.
    assert len(sig["segments"]) == 6
    assert sig["vias"] == []
    assert {s["layer"] for s in sig["segments"]} == {"F.Cu"}

    # The run's WIDTH baseline is still the board's own rule (width is
    # per-net, so an unrelated class never touches the fallback other nets
    # use); the run's CLEARANCE is the board-wide worst case, widened by
    # SIG's class even though SIG is only ONE of the board's nets.
    assert resp["result"]["effective_routing_rules"] == {
        "trace_width_mm": {"value": pytest.approx(BOARD_WIDTH_MM), "source": "board_rules"},
        "clearance_mm": {"value": pytest.approx(CLASS_CLEARANCE_MM), "source": "net_class"},
    }
    assert sig["effective_routing_rules"] == {
        "trace_width_mm": {"value": pytest.approx(CLASS_WIDTH_MM), "source": "net_class"},
        "clearance_mm": {"value": pytest.approx(CLASS_CLEARANCE_MM), "source": "net_class"},
    }
    for seg in sig["segments"]:
        assert seg["width_mm"] == pytest.approx(CLASS_WIDTH_MM)
    if other:
        # OTHER's own copper width is unaffected (still the board's baseline)
        # but its CLEARANCE reports the same board-wide worst case as SIG's —
        # that is what the grid actually reserved around OTHER's copper too.
        assert other[0]["effective_routing_rules"] == {
            "trace_width_mm": {"value": pytest.approx(BOARD_WIDTH_MM), "source": "board_rules"},
            "clearance_mm": {"value": pytest.approx(CLASS_CLEARANCE_MM), "source": "net_class"},
        }
        for seg in other[0]["segments"]:
            assert seg["width_mm"] == pytest.approx(BOARD_WIDTH_MM)

    # Task 3: the candidate overlay must check SIG at the width it actually got
    # (the class width), never the run's baseline — a false clean otherwise.
    candidates, _empty = methods._routes_to_candidates(resp["result"]["routes"])
    sig_candidate = next(c for c in candidates if c["net"] == "SIG")
    assert all(seg["width_mm"] == pytest.approx(CLASS_WIDTH_MM)
              for seg in sig_candidate["segments"])

    # drc_geometric's OWN pre-existing guard (019f958b45b9) still fires for a
    # net-classed board — this round does not (and must not) paper over it;
    # geometric DRC stays honestly indeterminate until IT learns to apply
    # per-class minima too (docs/routing.md, "Not yet done").
    assert sig["drc_geometric"]["verdict"] == "indeterminate"


def test_the_staged_via_fixture_is_projected_at_a_net_classed_nets_own_width():
    """MANDATORY FIXTURE (gate 019f70f76c2f), for the net-class path — reusing
    the SAME staged reply `test_a_three_pin_two_path_route_with_a_via_is_
    projected_at_the_run_width` uses, per the round's own instruction to reuse
    rather than rebuild it. The real engine does not need a via for this
    fixture's geometry (see the test above), so this is the only way to
    exercise "a net-classed net's disconnected-paths-plus-via reply is stamped
    and checked at ITS OWN width" at all — the STAGED shape stands in for
    whatever geometry a real board eventually forces a via on, and pins that
    this round's stamping mechanism (`_attach_effective_routing_rules`) and
    the candidate overlay agree on that shape exactly as they do on the
    simpler one.
    """
    rb = _compile(_three_pin_board())
    rb2 = _apply_net_class_to(rb, "SIG", NetClass(
        id="nc:power", name="Power", min_trace_width_mm=CLASS_WIDTH_MM))

    payload = {"routes": _three_pin_route_reply()}
    # The SAME stamping _route calls, standing in for what it would have
    # computed for this net-classed run (baseline width/board_rules for the
    # run, SIG's own class width for its one route).
    methods._attach_effective_routing_rules(
        payload, baseline_width=BOARD_WIDTH_MM, width_source="board_rules",
        keepout_clearance=BOARD_CLEARANCE_MM, keepout_clearance_source="board_rules",
        net_widths={"SIG": CLASS_WIDTH_MM})

    sig = payload["routes"][0]
    assert sig["effective_routing_rules"]["trace_width_mm"] == \
        {"value": pytest.approx(CLASS_WIDTH_MM), "source": "net_class"}
    for seg in sig["segments"]:
        assert seg["width_mm"] == pytest.approx(CLASS_WIDTH_MM)

    # The geometric candidate overlay: passing BOARD_WIDTH_MM as the fallback
    # `trace_width_mm` default proves the class width WON on its own — a
    # segment's own width_mm (just stamped above) outranks the fallback in
    # ir_candidates.build_overlay, so if the class width did not win here the
    # overlay would be checking this proposal at a width it was not routed
    # at (the false clean task 3 exists to prevent).
    # NOTE: `_attach_route_geometric_drc` runs the FULL geometric kernel
    # (`run_geometric_drc`), which carries drc_geometric's own pre-existing
    # net-class guard (019f958b45b9, fires whenever EITHER min_trace_width_mm
    # OR min_clearance_mm is set) — so THIS verdict is "indeterminate", same
    # as the end-to-end test above, and for the same reason (this round does
    # not, and must not, paper over that guard). It says nothing about
    # whether the width the OVERLAY used was correct — `build_overlay` below
    # (which `check_candidates`/`run_geometric_drc` call internally, but which
    # itself does not consult net_classes at all) is what actually proves that.
    methods._attach_route_geometric_drc(payload, rb2, trace_width_mm=BOARD_WIDTH_MM)
    verdict = payload["routes"][0]["drc_geometric"]
    assert verdict["verifies_geometry"] is False
    assert verdict["verdict"] == "indeterminate"

    candidates, empty = methods._routes_to_candidates(payload["routes"])
    assert empty == [] and len(candidates) == 1
    assert len(candidates[0]["segments"]) == 3 and len(candidates[0]["vias"]) == 1
    overlay = ir_candidates.build_overlay(
        rb2, candidates, default_width_mm=BOARD_WIDTH_MM,
        default_via_diameter_mm=rb2.design_rules.defaults.via_diameter_mm,
        default_via_drill_mm=rb2.design_rules.defaults.via_drill_mm)
    projected = [t for t in overlay.board.traces if t.id not in
                 {b.id for b in rb2.traces}]
    assert projected, "the three-pin proposal must reach the overlay as copper"
    for trace in projected:
        for seg in trace.segments:
            # THE must-fix's proof: CLASS_WIDTH_MM, not BOARD_WIDTH_MM — a
            # net-classed proposal is checked at what it actually got.
            assert seg.width_mm == pytest.approx(CLASS_WIDTH_MM)
    # The mandatory shape itself, preserved through net-class stamping: two
    # disconnected paths (one per layer) joined by a layer-changing via.
    layers = {seg.layer.id for t in projected for seg in t.segments}
    assert layers == {"top", "bottom"}
    assert len(overlay.board.vias) == len(rb2.vias) + 1


def test_undo_after_commit_preserves_the_net_classed_nets_own_width(
        net_classed_compile, routed_with):
    """MANDATORY undo-after-commit, with a net class in play: the class
    assignment (like the board's own rules) is a pure function of the
    compiled board, so SIG routes at its class width before a commit, WITH the
    commit's copper accepted onto it (routable since T7 019f70ebc9ed), and at
    the SAME class width — and the SAME board-wide clearance — again once
    undone. The class minima are read from the board, never from what happens
    to be routed already."""
    net_classed_compile["nc"] = NetClass(id="nc:power", name="Power",
                                        min_trace_width_mm=CLASS_WIDTH_MM,
                                        min_clearance_mm=CLASS_CLEARANCE_MM)
    net_classed_compile["net"] = "SIG"
    board = _three_pin_board()

    before = _call_route({"board": board})
    assert before["ok"] is True, before
    sig_before = next(r for r in before["result"]["routes"] if r["net"] == "SIG")
    assert sig_before["effective_routing_rules"] == {
        "trace_width_mm": {"value": pytest.approx(CLASS_WIDTH_MM), "source": "net_class"},
        "clearance_mm": {"value": pytest.approx(CLASS_CLEARANCE_MM), "source": "net_class"},
    }

    committed = _call_route({"board": _committed(board)})
    assert committed["ok"] is True, committed
    sig_committed = next(r for r in committed["result"]["routes"]
                         if r["net"] == "SIG")
    assert sig_committed["effective_routing_rules"] == \
        sig_before["effective_routing_rules"]

    after = _call_route({"board": _undone(_committed(board))})
    assert after["ok"] is True, after
    sig_after = next(r for r in after["result"]["routes"] if r["net"] == "SIG")
    assert sig_after["effective_routing_rules"] == sig_before["effective_routing_rules"]
    for seg in sig_after["segments"]:
        assert seg["width_mm"] == pytest.approx(CLASS_WIDTH_MM)
