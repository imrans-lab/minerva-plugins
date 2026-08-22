"""Round E1 — the STRICT IR router projection (docket 019f783860c8).

Canonical routing consumes real compiled copper or it does not route. These tests
pin the two halves of that contract:

  1. TRUTH — every pad the engine sees comes from the ResolvedBoard IR: position,
     side/mirror, layer participation, net ownership, and an extent that CONTAINS
     the fabricated land. The cross-check against ``drc_geometric.project_board``
     is the important one: the router's keepout is compared against the copper the
     geometric DRC checks and the CAM emitters fabricate, so all three can be
     shown to agree by construction rather than by assertion-matching constants.

  2. FAIL-CLOSED — anything the routing grid cannot model faithfully yields ZERO
     routes plus a reason, never a proposal over guessed copper. The headline
     regression is the one that named this round: a pad with no authored geometry
     used to get a nominal 1.0x1.0 land, so the router computed keepouts around
     copper the board does not have and could route a trace straight through the
     real package land.

The safety direction is the same one the geometric DRC kernel documents, restated
for keepouts: the modeled keepout must be a SUPERSET of the fabricated copper.
Over-blocking is legal; under-blocking never is.
"""

from __future__ import annotations

import math
from collections import defaultdict

import pytest

from pcb_worker import compile_board as cb
from pcb_worker import drc, drc_geometric, ir_pads, route_bridge
from pcb_worker.footprints import load_lockfile
from pcb_worker.methods import handle_request


# ---------------------------------------------------------------------------
# Fixtures — boards that really compile against the seed library.
# ---------------------------------------------------------------------------


def _board(components: list, **extra) -> dict:
    board = {
        "version": 1, "name": "route-ir", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": components,
    }
    board.update(extra)
    return board


def _comp(ref: str, fp: str, x: float, y: float, *, rot: float = 0.0,
          layer: str = "top") -> dict:
    return {"ref": ref, "footprint": fp, "x_mm": x, "y_mm": y,
            "rotation_deg": rot, "layer": layer}


def _compile(board: dict):
    """Compile with the ROUTING capability profile, as route() does."""
    result = cb.compile_board(board, requested_outputs=cb.V1_ROUTING_OUTPUTS)
    assert isinstance(result, cb.ResolutionSuccess), getattr(result, "diagnostics", None)
    return result.board


def _project(board: dict):
    return route_bridge.resolved_board_to_router(_compile(board))


def _call_route(params: dict) -> dict:
    resp = handle_request({"id": "e1", "method": "route", "params": params})
    assert resp is not None and resp["id"] == "e1"
    return resp


# ---------------------------------------------------------------------------
# 1. TRUTH — the projection matches the IR, pad for pad.
# ---------------------------------------------------------------------------


def test_pad_census_matches_the_ir_exactly():
    """Every IR pad appears once, with the IR's own identity and net."""
    board = _board([_comp("R1", "R_0805", 10, 10), _comp("R2", "R_0805", 20, 10)],
                   nets=[{"name": "N1", "pins": ["R1.2", "R2.1"]}])
    rb = _compile(board)
    rendered = route_bridge.resolved_board_to_router(rb)

    ir = {(p.ref, p.number): p for p in ir_pads.iter_ir_pads(rb)}
    assert len(rendered.pads) == len(ir), "pad count must match the IR census"
    for pad in rendered.pads:
        source = ir[(pad.component, pad.number)]
        # Position is the IR's placed position (top-side: no mirroring involved).
        assert pad.position == pytest.approx(source.pad.position)
        # Net ownership comes from the IR net, not from a re-parsed "Ref.Pad".
        assert pad.net == source.net_name
    assert rendered.nets["N1"].pads and all(
        p.net == "N1" for p in rendered.nets["N1"].pads)
    assert {(p.component, p.number) for p in rendered.nets["N1"].pads} == {
        ("R1", "2"), ("R2", "1")}


@pytest.mark.parametrize("ref", sorted(load_lockfile().keys()))
def test_locked_seed_census_projects_every_pad_faithfully(ref):
    """THE locked seed census (Codex E1 review): every footprint in the lockfile,
    not a hand-picked pair.

    For each locked seed, the router projection must agree with the shared IR/DRC
    projection on WHICH pads exist and WHERE, and each router keepout must CONTAIN
    the copper the geometric DRC checks. The footprint list comes from the
    lockfile itself, so a new seed is covered the moment it is locked."""
    rb = _compile(_board([_comp("X1", ref, 20, 20)]))
    rendered = route_bridge.resolved_board_to_router(rb)

    census = list(ir_pads.iter_ir_pads(rb))
    copper = {c.entity_id: c for c in drc_geometric.project_board(rb).copper}
    copper_bearing = [p for p in census if p.carries_copper]

    # Identity: exactly the copper-bearing pads become router pads; NPTH pads
    # become obstacles instead (never routable endpoints).
    assert {(p.component, p.number) for p in rendered.pads} == \
        {(p.ref, p.number) for p in copper_bearing}
    assert len(rendered.pads) == len(copper_bearing)

    # A human pad number is an ELECTRICAL identity, not a physical-occurrence
    # identity: KiCad legitimately gives both copper mounting lands on a JST
    # connector the number ``MP``.  Preserve every occurrence instead of using a
    # dict whose last ``MP`` silently overwrites the first and looks like an X
    # mirror when the left IR land is compared with the right router land.
    by_human_id = defaultdict(list)
    for pad in rendered.pads:
        by_human_id[(pad.component, pad.number)].append(pad)
    for ir_pad in copper_bearing:
        candidates = by_human_id[(ir_pad.ref, ir_pad.number)]
        match = next((candidate for candidate in candidates
                      if candidate.position == pytest.approx(
                          ir_pad.pad.position, abs=1e-9)), None)
        assert match is not None, (
            ir_pad.ref, ir_pad.number, ir_pad.pad.position,
            [candidate.position for candidate in candidates])
        candidates.remove(match)
        pad = match
        box = copper[ir_pad.pad.id].aabb
        # Position + layer are the IR's own.
        assert pad.position == pytest.approx(ir_pad.pad.position, abs=1e-9)
        if ir_pad.is_drilled:
            assert pad.layer == "*.Cu" and pad.pad_type == "thru_hole"
        else:
            assert pad.layer in ("F.Cu", "B.Cu") and pad.pad_type == "smd"
        # Containment: the keepout is a SUPERSET of the fabricated copper.
        half_w, half_h = pad.size[0] / 2.0, pad.size[1] / 2.0
        assert pad.position[0] - half_w <= box.min_x + 1e-9
        assert pad.position[0] + half_w >= box.max_x - 1e-9
        assert pad.position[1] - half_h <= box.min_y + 1e-9
        assert pad.position[1] + half_h >= box.max_y - 1e-9
    assert not any(by_human_id.values()), by_human_id


def test_qfn_paste_only_apertures_are_absent_from_copper_drc_and_routing():
    ref = "Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.68x1.68mm"
    rb = _compile(_board([_comp("U1", ref, 20, 20)]))
    census = list(ir_pads.iter_ir_pads(rb))

    assert len(census) == 21
    assert sum(p.carries_copper for p in census) == 17
    assert sum(not p.carries_copper and not p.is_npth for p in census) == 4
    assert len(drc_geometric.project_board(rb).copper) == 17
    assert len(route_bridge.resolved_board_to_router(rb).pads) == 17


def test_pad_extent_contains_the_copper_geometric_drc_checks():
    """THE safety property, cross-checked against the DRC/CAM copper owner.

    A rotated elongated land is the case that breaks naive sizing: the engine's
    ``mark_pad`` discards the rotation it is handed (grid.py:313), so handing it
    the raw 1.0 x 1.45 land of a 45-degree 0805 pad would leave real copper
    outside the keepout. The projection hands it the land's axis-aligned bounding
    box instead — proved here to CONTAIN every copper primitive the geometric DRC
    projects for the same board."""
    board = _board([_comp("R1", "R_0805", 20, 20, rot=45)])
    rb = _compile(board)
    rendered = route_bridge.resolved_board_to_router(rb)
    copper = {c.entity_id: c for c in drc_geometric.project_board(rb).copper}

    by_number = {(p.component, p.number): p for p in rendered.pads}
    for ir_pad in ir_pads.iter_ir_pads(rb):
        pad = by_number[(ir_pad.ref, ir_pad.number)]
        box = copper[ir_pad.pad.id].aabb          # what DRC/CAM call this copper
        half_w, half_h = pad.size[0] / 2.0, pad.size[1] / 2.0
        lo_x, hi_x = pad.position[0] - half_w, pad.position[0] + half_w
        lo_y, hi_y = pad.position[1] - half_h, pad.position[1] + half_h
        assert lo_x <= box.min_x + 1e-9 and hi_x >= box.max_x - 1e-9
        assert lo_y <= box.min_y + 1e-9 and hi_y >= box.max_y - 1e-9

    # And it is a REAL rotation, not a no-op fixture: a 45-degree 1.0 x 1.45 land
    # has a strictly wider envelope than the unrotated land.
    pad = by_number[("R1", "1")]
    assert pad.size[0] > 1.0 and pad.size[1] > 1.0
    assert pad.rotation == 0.0, "size is the axis-aligned envelope; rotation must not double-count"


def test_bottom_side_component_is_mirrored_and_lands_on_b_cu():
    """IR-authoritative side handling (Codex ruling 1). The raw path never
    mirrored a bottom-side footprint; the IR does, pinned to pcbnew's own Flip."""
    # A footprint whose pads are OFF the local X axis — an 0805's two pads both
    # sit at local y=0, where a Y mirror is invisible.
    fp = "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical"
    top = _project(_board([_comp("J1", fp, 10, 10)]))
    bottom = _project(_board([_comp("J1", fp, 10, 10, layer="bottom")]))

    # A through-hole pad spans both sides, so side shows up in the GEOMETRY here.
    t2 = next(p for p in top.pads if p.number == "2")
    b2 = next(p for p in bottom.pads if p.number == "2")
    assert t2.position == pytest.approx((10.0, 12.54))    # local (0, +2.54)
    assert b2.position == pytest.approx((10.0, 7.46))     # mirrored to (0, -2.54)

    # And a SURFACE pad follows its side onto B.Cu.
    smd_top = _project(_board([_comp("R1", "R_0805", 10, 10)]))
    smd_bottom = _project(_board([_comp("R1", "R_0805", 10, 10, layer="bottom")]))
    assert {p.layer for p in smd_top.pads} == {"F.Cu"}
    assert {p.layer for p in smd_bottom.pads} == {"B.Cu"}


def test_through_hole_pad_spans_layers_and_carries_its_drill():
    board = _board([_comp("J1", "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical",
                          10, 10)])
    rendered = _project(board)
    pad = next(p for p in rendered.pads if p.number == "1")
    assert pad.pad_type == "thru_hole"
    assert pad.layer == "*.Cu"                     # engine marks every copper layer
    assert pad.drill == pytest.approx(1.0)
    # The land (1.7 square) is what keeps other nets out, not the 1.0 drill.
    assert pad.size == pytest.approx((1.7, 1.7))


def test_outline_extent_and_origin_come_from_the_ir():
    rendered = _project(_board([_comp("R1", "R_0805", 10, 10)]))
    assert rendered.width == pytest.approx(40.0)
    assert rendered.height == pytest.approx(40.0)
    assert rendered.origin == pytest.approx((0.0, 0.0))

    offset = _project(_board([_comp("R1", "R_0805", 110, 110)],
                             origin={"x_mm": 100.0, "y_mm": 100.0}))
    assert offset.origin == pytest.approx((100.0, 100.0))


def test_board_with_a_nonzero_origin_routes_inside_its_own_outline():
    """E2 gap C, end to end. The grid used to index from zero regardless of the
    board's origin, so every pad on an offset board landed in the wrong cell. The
    grid is now anchored at the outline's origin and world coordinates are
    preserved at the boundary — a route on an offset board must come back INSIDE
    that board, not translated toward (0, 0)."""
    board = _board([_comp("R1", "R_0805", 110, 120), _comp("R2", "R_0805", 125, 120)],
                   origin={"x_mm": 100.0, "y_mm": 100.0},
                   nets=[{"name": "N1", "pins": ["R1.2", "R2.1"]}])
    resp = _call_route({"board": board})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["success"] is True, result

    points = [p for route in result["routes"] for seg in route["segments"]
              for p in (seg["start"], seg["end"])]
    assert points
    for x, y in points:
        assert 100.0 <= x <= 140.0, f"routed off-board in x: {x}"
        assert 100.0 <= y <= 140.0, f"routed off-board in y: {y}"


# ---------------------------------------------------------------------------
# 2. HOLE SEMANTICS (Codex gap D)
# ---------------------------------------------------------------------------


def test_npth_pad_is_an_obstacle_not_a_routable_pad():
    """A bare mechanical hole has no land: it must block, and must NOT become a
    pad the router can terminate a net on."""
    board = _board([_comp("H1", "MountingHole:MountingHole_3.2mm_M3", 20, 20)])
    rendered = route_bridge.resolved_board_to_router(_compile(board))

    assert rendered.pads == [], "an NPTH pad is not routable copper"
    assert len(rendered.obstacles) == 1
    obs = rendered.obstacles[0]
    assert obs.type == "npth_pad"
    assert obs.position == pytest.approx((20.0, 20.0))
    assert obs.radius == pytest.approx(1.6)        # 3.2mm drill


def test_plated_board_hole_blocks_its_copper_annulus_not_just_its_drill():
    board = _board([_comp("R1", "R_0805", 10, 10)],
                   pth_holes=[{"x_mm": 30, "y_mm": 30, "drill_mm": 1.0,
                               "annulus_mm": 2.4}])
    rendered = route_bridge.resolved_board_to_router(_compile(board))
    holes = [o for o in rendered.obstacles if o.type == "mounting_hole"]
    assert len(holes) == 1
    # 1.2 (annulus radius), NOT 0.5 (drill radius): copper is what a trace must
    # not cross.
    assert holes[0].radius == pytest.approx(1.2)


def test_unplated_board_hole_blocks_its_drill():
    board = _board([_comp("R1", "R_0805", 10, 10)],
                   mounting_holes=[{"x_mm": 30, "y_mm": 30, "diameter_mm": 3.2}])
    rendered = route_bridge.resolved_board_to_router(_compile(board))
    holes = [o for o in rendered.obstacles if o.type == "mounting_hole"]
    assert holes[0].radius == pytest.approx(1.6)


# ---------------------------------------------------------------------------
# 3. FAIL-CLOSED — zero routes, with a reason.
# ---------------------------------------------------------------------------


def test_unresolvable_footprint_returns_diagnostics_and_no_routes():
    resp = _call_route({"board": _board([_comp("U1", "NOPE_NOT_REAL", 10, 10)])})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "compile"
    assert resp["error"]["diagnostics"]           # attributed, not a bare message
    assert "result" not in resp                   # and NOTHING is proposed


def test_inner_copper_projects_on_a_declaring_stack_and_refuses_otherwise():
    """FLIPPED at epoch GA-2 (was test_inner_copper_layers_fail_closed: "the
    vendored engine is 2-layer"). The engine now models the board's own
    declared stack, so inner copper PROJECTS — provided the manufacturer
    profile's capabilities ceiling admits the depth. Both halves pinned: the
    declaring profile projects every plane in stack order, and the silent
    default profile still refuses the whole compile (ceiling 2, absence never
    widens), so inner copper is never silently absent from any grid."""
    board = _board([_comp("R1", "R_0805", 10, 10)],
                   layers=["top", "in1", "in2", "bottom"])
    board["design_rules"]["rule_profile"] = "jlcpcb-4layer"
    rb = _compile(board)
    rendered = route_bridge.resolved_board_to_router(rb)
    assert rendered.pads
    assert route_bridge._routing_layer_ids(rb) == (
        "F.Cu", "In1.Cu", "In2.Cu", "B.Cu")

    undeclared = _board([_comp("R1", "R_0805", 10, 10)],
                        layers=["top", "in1", "in2", "bottom"])
    result = cb.compile_board(undeclared, requested_outputs=cb.V1_ROUTING_OUTPUTS)
    assert not isinstance(result, cb.ResolutionSuccess)
    assert any(d.code == "unsupported_layer_stack" for d in result.diagnostics)


def test_sizeless_smd_pad_can_never_be_given_a_nominal_land():
    """THE round-E regression, at the seam that used to invent copper.

    ``_pad_size_for`` returned (1.0, 1.0) for a pad with no authored geometry.
    That nominal land is smaller than most real packages, so a router that
    believed it would happily lay a trace through the actual copper. There is no
    honest size to invent: the call now fails closed."""
    with pytest.raises(ir_pads.UnsupportedGeometry, match="fails closed"):
        route_bridge._pad_size_for({"number": "1"}, {})

    # And the nominal constant is gone entirely — not merely unreferenced.
    assert not hasattr(route_bridge, "_DEFAULT_PAD_SIZE")


def test_authored_pin_size_is_used_rather_than_invented():
    """The honest half of the same seam: an AUTHORED size is real data and is
    used. (pad_source._from_pin always read these keys; this builder did not, so
    a pin that authored its own copper still got the nominal land.)"""
    assert route_bridge._pad_size_for(
        {"number": "1", "pad_width_mm": 2.0, "pad_height_mm": 0.6}, {}
    ) == pytest.approx((2.0, 0.6))


def test_routed_keepout_covers_the_real_land_that_a_nominal_land_would_miss():
    """End-to-end statement of the bug this round closes.

    A DIP-6 land is 1.6mm square. The old nominal land was 1.0mm square, so a
    keepout built from it left a 0.3mm ring of REAL copper unprotected on every
    side. The IR projection's extent covers the whole land."""
    board = _board([_comp("U1", "Package_DIP:DIP-6_W7.62mm_Socket", 15, 15)])
    rendered = _project(board)
    pad = next(p for p in rendered.pads if p.number == "1")
    assert pad.size[0] >= 1.6 - 1e-9 and pad.size[1] >= 1.6 - 1e-9
    assert pad.size[0] > 1.0 and pad.size[1] > 1.0   # strictly bigger than nominal


def _unnumber_pads(rb, ref: str):
    """Rebuild ``rb`` with component ``ref``'s footprint pads carrying number "".

    KiCad legitimately leaves mechanical pads unnumbered and PadDefinition permits
    number="" — but no LOCKED seed does, so the only way to cover the case is to
    construct it (Codex's own repro, 019f97eb6adf). The PlacedPad/source_id
    correlation is left intact, so the result is a fully valid ResolvedBoard."""
    import dataclasses

    comp = next(c for c in rb.components if c.ref == ref)
    definitions, rebound = [], {}
    for definition in rb.footprint_definitions:
        if definition.content_id == comp.footprint_id:
            replaced = dataclasses.replace(definition, pads=tuple(
                dataclasses.replace(p, number="") for p in definition.pads))
            # content_id is CONTENT-derived, so editing a pad re-mints it; every
            # component pointing at the old definition has to follow.
            rebound[definition.content_id] = replaced.content_id
            definition = replaced
        definitions.append(definition)
    components = tuple(
        dataclasses.replace(c, footprint_id=rebound[c.footprint_id])
        if c.footprint_id in rebound else c
        for c in rb.components)
    return dataclasses.replace(rb, footprint_definitions=tuple(definitions),
                               components=components)


def test_unnumbered_npth_is_modeled_not_rejected():
    """REGRESSION 019f97eb6adf. An unnumbered NPTH mechanical pad is ordinary,
    fully-modelable geometry: it must become a routing obstacle and a DRC hole
    primitive, NOT a fail-closed rejection. Requiring endpoint identity of every
    pad made both IR projections reject a hole they model exactly."""
    rb = _unnumber_pads(
        _compile(_board([_comp("H1", "MountingHole:MountingHole_3.2mm_M3", 20, 20)])),
        "H1")

    # The neutral iterator stays permissive: the pad is yielded, with its missing
    # identity reported honestly rather than invented.
    census = list(ir_pads.iter_ir_pads(rb))
    assert len(census) == 1
    assert census[0].human_number is None and census[0].is_addressable is False
    assert census[0].is_npth is True

    # Routing: an obstacle, and NOT a routable endpoint.
    rendered = route_bridge.resolved_board_to_router(rb)
    assert rendered.pads == []
    assert [o.type for o in rendered.obstacles] == ["npth_pad"]

    # Geometric DRC: models the hole exactly — no indeterminate verdict.
    verdict = drc_geometric.run_geometric_drc(rb)
    assert verdict["ok"] is True and verdict["verdict"] in ("clean", "violations")

    # Connectivity: a mechanical hole is not an electrical entity at all.
    from pcb_worker import ir_connectivity
    assert ir_connectivity.connectivity_board(rb)["components"] == []


def test_unnumbered_unnetted_copper_becomes_an_obstacle_not_an_endpoint():
    """Real copper that nothing can NAME still has to block. It cannot be a routed
    endpoint (no net ref, hint or panel label could address it), so it degrades to
    a conservative keepout rather than failing the whole board."""
    rb = _unnumber_pads(_compile(_board([_comp("R1", "R_0805", 10, 10)])), "R1")
    rendered = route_bridge.resolved_board_to_router(rb)

    assert rendered.pads == [], "unaddressable copper must never be an endpoint"
    obstacles = [o for o in rendered.obstacles if o.type == "unaddressable_pad"]
    assert len(obstacles) == 2                       # both 0805 lands
    # The disc CONTAINS the land it stands for (fail-safe direction).
    copper = {c.entity_id: c for c in drc_geometric.project_board(rb).copper}
    for ir_pad, obstacle in zip(ir_pads.iter_ir_pads(rb), obstacles):
        box = copper[ir_pad.pad.id].aabb
        for corner in ((box.min_x, box.min_y), (box.max_x, box.max_y),
                       (box.min_x, box.max_y), (box.max_x, box.min_y)):
            reach = math.hypot(corner[0] - obstacle.position[0],
                               corner[1] - obstacle.position[1])
            assert reach <= obstacle.radius + 1e-9


def test_netted_but_unnumbered_pad_fails_closed():
    """A net claiming an endpoint that nothing can address is a contradiction —
    degrading it to a keepout would silently drop a connection the netlist asked
    for. Both projections agree, so the reply is the same whichever runs first."""
    from pcb_worker import ir_connectivity

    rb = _unnumber_pads(
        _compile(_board([_comp("R1", "R_0805", 10, 10), _comp("R2", "R_0805", 20, 10)],
                        nets=[{"name": "N1", "pins": ["R1.2", "R2.1"]}])),
        "R1")
    for project in (route_bridge.resolved_board_to_router,
                    ir_connectivity.connectivity_board):
        with pytest.raises(ir_pads.UnsupportedGeometry, match="nothing can address"):
            project(rb)


def test_connectivity_projection_failure_stays_inside_the_route_envelope(monkeypatch):
    """REGRESSION 019f97eb6adf (second defect): the connectivity projection ran
    BEFORE the guard that turns UnsupportedGeometry into the structured
    zero-route reply, so its failure escaped the route error envelope. Both
    projections now sit under one boundary."""
    from pcb_worker import ir_connectivity

    def _boom(_rb):
        raise ir_pads.UnsupportedGeometry("synthetic connectivity projection fault")

    monkeypatch.setattr(ir_connectivity, "connectivity_board", _boom)
    resp = _call_route({"board": _board(
        [_comp("R1", "R_0805", 10, 20), _comp("R2", "R_0805", 25, 20)],
        nets=[{"name": "N1", "pins": ["R1.2", "R2.1"]}])})

    assert resp["ok"] is False
    assert resp["error"]["kind"] == "unsupported_geometry"
    assert "synthetic connectivity projection fault" in resp["error"]["message"]
    assert "result" not in resp


def test_a_pad_outside_the_outline_is_unrouted_not_routed_off_board():
    """E2 gap C, the other half. The grid used to GROW to cover any pad outside
    the outline (+2mm), which quietly made off-board space routable. The outline
    is the legal area: a net reaching a pad outside it comes back UNROUTED, with
    no route laid down where no board exists."""
    board = _board([_comp("R1", "R_0805", 10, 20),
                    _comp("R2", "R_0805", 60, 20)],      # x=60 on a 40mm board
                   nets=[{"name": "N1", "pins": ["R1.2", "R2.1"]}])
    resp = _call_route({"board": board})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["success"] is False
    assert result["routes"] == []
    assert [u["net"] for u in result["unrouted"]] == ["N1"]


def test_footprint_only_board_routes_AND_reports_connectivity_clean():
    """REGRESSION 019f97d021a8 — the two halves of one reply must agree.

    E1 moved routing onto the IR but left DRC-at-propose reading the raw dict's
    inline ``pins``. A footprint-only board (a perfectly valid authoring shape,
    and what the panel produces) then routed SUCCESSFULLY while every endpoint was
    reported dangling: same board, same geometry, two pad censuses. One compile now
    feeds both halves."""
    board = _board([_comp("U1", "TH_TestPoint", 10, 20),
                    _comp("J1", "TH_TestPoint", 30, 20)],
                   nets=[{"name": "SIG", "pins": ["U1.1", "J1.1"]}])
    # No component carries inline `pins` — pads exist only in the footprint.
    assert all("pins" not in c for c in board["components"])

    resp = _call_route({"board": board})
    assert resp["ok"] is True, resp
    result = resp["result"]
    assert result["success"] is True
    # BASELINE PARTITION (019f9cc386b6): a clean board's baseline is itself clean
    # and empty, so the whole summary is still assertable byte-for-byte.
    # HITL-4 (docs/llm-ergonomics.md F2): + the completeness half — a fully
    # routed board is complete with nothing missing (no `partial`/
    # `indeterminate` key; `approximate` is the census's standing
    # centerline-basis label, DCR 019fd5fd9084).
    assert result["drc_summary"] == {
        "scope": "connectivity", "clean": True, "violation_count": 0,
        "complete": True, "missing_copper": [], "approximate": True,
        "baseline": {"clean": True, "violation_count": 0, "findings": []}}
    for route in result["routes"]:
        assert route["drc"]["clean"] is True, route["drc"]


def test_connectivity_projection_comes_from_the_compiled_ir():
    """The projection carries the IR's own pad census — absolute placement, human
    pad numbers, net membership — in the connectivity kernel's input language."""
    from pcb_worker import ir_connectivity

    rb = _compile(_board([_comp("R1", "R_0805", 10, 10, rot=90)],
                         nets=[{"name": "N1", "pins": ["R1.2"]}]))
    projected = ir_connectivity.connectivity_board(rb)

    comp = next(c for c in projected["components"] if c["ref"] == "R1")
    # Components are emitted at the ORIGIN with the placement already applied, so
    # the kernel's own "component + rotate(offset)" composition is the identity and
    # cannot re-apply a rotation the IR already applied.
    assert (comp["x_mm"], comp["y_mm"], comp["rotation_deg"]) == (0.0, 0.0, 0.0)
    by_number = {p["number"]: p for p in comp["pins"]}
    assert set(by_number) == {"1", "2"}
    ir = {p.number: p for p in ir_pads.iter_ir_pads(rb)}
    for number, pin in by_number.items():
        assert (pin["x_mm"], pin["y_mm"]) == pytest.approx(ir[number].pad.position)
    assert {"R1.2"} == set(next(n for n in projected["nets"]
                                if n["name"] == "N1")["pins"])


def test_connectivity_projection_carries_pad_layers():
    """SR2FAB S3. The IR knows exactly which faces each pad has copper on, and
    the projection used to drop it — so every projected pad reached
    drc._Pad.occupies with an empty layer list and answered "yes" for every
    layer. Copper on the wrong side of the board then read as a joined net.

    Spellings ride VERBATIM: drc._harvest_pads folds them through kicad_to_canon
    after filtering to copper, so folding here would only have to special-case
    the mask and paste layers a pad legitimately carries."""
    from pcb_worker import ir_connectivity

    rb = _compile(_board([_comp("R1", "R_0805", 10, 10)],
                         nets=[{"name": "N1", "pins": ["R1.2"]}]))
    projected = ir_connectivity.connectivity_board(rb)
    comp = next(c for c in projected["components"] if c["ref"] == "R1")

    ir = {p.number: p for p in ir_pads.iter_ir_pads(rb)}
    for pin in comp["pins"]:
        expected = [layer.id for layer in ir[pin["number"]].pad.layers]
        assert pin["layers"] == expected, pin["number"]
        # An 0805 is a surface part: copper on one face only, and the projection
        # says which. This is the fact that was missing.
        copper = [layer for layer in pin["layers"] if layer.endswith(".Cu")]
        assert copper == ["F.Cu"], pin["layers"]

    # ...and it survives the trip back through the pad-source fallback, which is
    # the only reader the connectivity kernel has for a projected board (these
    # components carry `pins`, never `pads`).
    pads = {(pad.ref, pad.pin): pad for pad in drc._harvest_pads(projected)}
    assert pads[("R1", "2")].occupies("top") is True
    assert pads[("R1", "2")].occupies("bottom") is False


def test_routing_capability_profile_ignores_mask_but_not_copper():
    """A mask-only limitation must not disable ROUTING; copper/drill/rules must.

    The routing profile is a strict subset of the fabrication profile, so anything
    that blocks routing also blocks fabrication — never the reverse."""
    from pcb_worker.resolved_board import (EntityKind, FeatureDomain, SourceRef,
                                           UnsupportedFeature)

    def marker(domain: FeatureDomain, output: str) -> UnsupportedFeature:
        return UnsupportedFeature(
            feature="synthetic", domain=domain, affected_layer=None,
            affected_outputs=(output,), default_blocking=False,
            detail="test marker", source_ref=SourceRef(EntityKind.PAD, "pad:1:0"))

    policy = cb.DefaultCapabilityPolicy()
    mask = marker(FeatureDomain.MASK, "mask")
    assert policy.is_blocking(mask, {}, cb.V1_FAB_OUTPUTS) is True
    assert policy.is_blocking(mask, {}, cb.V1_ROUTING_OUTPUTS) is False

    for domain, output in ((FeatureDomain.COPPER, "copper"),
                           (FeatureDomain.DRILL, "drill"),
                           (FeatureDomain.RULES, "rules")):
        assert policy.is_blocking(marker(domain, output), {},
                                  cb.V1_ROUTING_OUTPUTS) is True

    assert set(cb.V1_ROUTING_OUTPUTS) < set(cb.V1_FAB_OUTPUTS)


def test_route_method_routes_a_compiling_board_end_to_end():
    """The happy path still works through the real method: compile -> IR -> engine."""
    board = _board([_comp("R1", "R_0805", 10, 20), _comp("R2", "R_0805", 25, 20)],
                   nets=[{"name": "N1", "pins": ["R1.2", "R2.1"]}])
    resp = _call_route({"board": board})
    assert resp["ok"] is True, resp
    assert resp["result"]["success"] is True
    assert any(rt["net"] == "N1" for rt in resp["result"]["routes"])


# ---------------------------------------------------------------------------
# 4. The neutral owner itself (ir_pads) — one correlation, two consumers.
# ---------------------------------------------------------------------------


def test_ir_pads_correlates_human_numbers_and_classifies_npth():
    board = _board([_comp("R1", "R_0805", 10, 10),
                    _comp("H1", "MountingHole:MountingHole_3.2mm_M3", 30, 30)])
    rb = _compile(board)
    by_ref = {(p.ref, p.number): p for p in ir_pads.iter_ir_pads(rb)}

    # Human numbers, not the "pad:1:0" source ids a PlacedPad carries.
    assert ("R1", "1") in by_ref and ("R1", "2") in by_ref
    assert by_ref[("R1", "1")].source_number != "1"

    smd, npth = by_ref[("R1", "1")], by_ref[("H1", "1")]
    assert smd.carries_copper and not smd.is_drilled
    assert npth.is_npth and not npth.carries_copper
    with pytest.raises(ir_pads.UnsupportedGeometry, match="no copper land"):
        ir_pads.pad_copper_shape(npth)


def test_drc_and_routing_shape_the_same_land():
    """DRY proof: the two consumers do not merely agree numerically — they call
    the same builder, so a change to one is a change to both."""
    board = _board([_comp("J1", "Package_DIP:DIP-6_W7.62mm_Socket", 12, 12, rot=17)])
    rb = _compile(board)
    drc_copper = {c.entity_id: c.shape for c in drc_geometric.project_board(rb).copper}
    for ir_pad in ir_pads.iter_ir_pads(rb):
        assert ir_pads.pad_copper_shape(ir_pad) == drc_copper[ir_pad.pad.id]


def test_slot_and_oval_holes_get_a_containing_disc():
    """The grid consumes discs only (Obstacle.polygon is declared but read
    nowhere), so a non-round hole is blocked by a disc that CONTAINS it."""
    from pcb_worker.resolved_board import OvalHole, ResolvedHole, SlotHole

    oval = route_bridge._hole_obstacle(ResolvedHole(
        id="h1", feature=OvalHole(position=(5.0, 5.0), width_mm=4.0,
                                  height_mm=2.0, rotation_deg=30.0),
        plated=False, kind=_hole_kind_npth()))
    # Half-diagonal contains the oval at ANY rotation.
    assert oval.radius == pytest.approx(math.hypot(4.0, 2.0) / 2.0)

    slot = route_bridge._hole_obstacle(ResolvedHole(
        id="h2", feature=SlotHole(path=((0.0, 0.0), (6.0, 0.0)), width_mm=2.0),
        plated=False, kind=_hole_kind_npth()))
    assert slot.position == pytest.approx((3.0, 0.0))
    assert slot.radius == pytest.approx(3.0 + 1.0)


def _hole_kind_npth():
    from pcb_worker.resolved_board import HoleKind
    return HoleKind.NPTH
