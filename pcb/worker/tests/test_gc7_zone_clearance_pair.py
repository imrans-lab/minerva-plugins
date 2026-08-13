"""DEFERRED TEST Z3 (docket 019fb06e7415, authored at epoch GA-5) — the GC7
zone-clearance DISCRIMINATING PAIR the triage found missing.

Nothing anywhere drove an actual GC7 violation: the one real-kernel test
(test_zone_seals.test_geometric_drc_checks_a_filled_pour) asserts a CLEAN
verdict, which a GC7 that never fires also passes. And the same-net
exemption (drc_geometric's INLINE site, distinct from the shared GC2
helper) was entirely unpinned — the corpus half-mutant
gc7_same_net_exemption_treats_unassigned_as_shared targets exactly it.

THE FIXTURE IS DOCTORED, and the docstring must say so out loud (same
doctrine as test_route_rules' stand-in board): a normally-compiled board
cannot violate GC7, because zone_fill carves at the SAME resolved rule GC7
judges — the filler and the judge share one clearance derivation by design.
The violating state is real nonetheless: ResolvedZone.fill is public IR, a
foreign tool (or a future filler bug — which is what GC7 exists to catch)
can hand DRC a fill that encroaches. dataclasses.replace substitutes the
computed fill with the pour's own UNCARVED outline rectangle, i.e. copper
laid straight over the trace the filler would have avoided.

The PAIR is the point: identical geometry, only the trace's NET differs —
foreign fires, same-net is exempt. A check that fires on both (exemption
lost) or neither (kernel dead) fails one half.
"""

from __future__ import annotations

import copy
import dataclasses

from pcb_worker.compile_board import ResolutionSuccess, compile_board
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.resolved_board import DiagnosticSeverity, PolygonGeometry


_OUTLINE = [{"x_mm": 4.0, "y_mm": 4.0}, {"x_mm": 16.0, "y_mm": 4.0},
            {"x_mm": 16.0, "y_mm": 16.0}, {"x_mm": 4.0, "y_mm": 16.0}]


def _board(trace_net: str) -> dict:
    """GND pour over the board middle; one trace straight through it on
    ``trace_net``. R1 pins give both nets a real pad so compile accepts."""
    return {
        "version": 1, "name": "gc7-pair", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 18,
             "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "GND", "pins": ["R1.1"]},
                 {"name": "SIG", "pins": ["R1.2"]}],
        "traces": [{"net": trace_net, "layer": "top", "width_mm": 0.3,
                    "points": [{"x_mm": 5.0, "y_mm": 10.0},
                               {"x_mm": 15.0, "y_mm": 10.0}]}],
        "zones": [{"net": "GND", "layer": "top", "clearance_mm": 0.2,
                   "outline": copy.deepcopy(_OUTLINE)}],
    }


def _doctored(board: dict):
    """Compile, then replace the pour's carved fill with its UNCARVED outline
    rectangle — copper laid straight over the trace."""
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    rb = result.board
    zone = rb.zones[0]
    solid = PolygonGeometry(points=tuple(
        (p["x_mm"], p["y_mm"]) for p in _OUTLINE))
    return dataclasses.replace(
        rb, zones=(dataclasses.replace(zone, fill=(solid,)),))


def test_a_foreign_net_encroachment_fires_gc7_naming_both_parties():
    rb = _doctored(_board(trace_net="SIG"))
    result = run_geometric_drc(rb)
    gc7 = [f for f in result["findings"] if f["type"] == "gc7_zone_clearance"]
    assert gc7, ("uncarved pour copper over a FOREIGN trace must fire GC7 — "
                 "a clean here means the kernel never ran or never bites")
    f = gc7[0]
    assert f["entity_id"] == rb.zones[0].id, "the finding names the ZONE"
    assert f.get("against_entity_id"), (
        "the asymmetric rule attributes the opposed party (the trace)")
    assert result["verdict"] != "clean"


def test_the_same_net_trace_in_the_same_position_is_exempt():
    """Identical copper, trace on the pour's OWN net: solid connect is the
    contract, no clearance applies, no finding. Losing the exemption's
    non-null guard (the corpus half-mutant) or the exemption itself makes
    this half red."""
    rb = _doctored(_board(trace_net="GND"))
    result = run_geometric_drc(rb)
    gc7 = [f for f in result["findings"] if f["type"] == "gc7_zone_clearance"]
    assert gc7 == [], (
        "same-net copper under a pour is the CONNECTION, not a violation")
