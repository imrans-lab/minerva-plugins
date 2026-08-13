"""Chore 019fa20b11 (epoch GA-6) — ONE owner of the net-class minima
admission policy.

The acceptance, made executable: methods._net_class_overrides (routing,
keyed by net NAME) and drc_geometric._net_class_minima (GC1/GC2, keyed by
net_id) both delegate to net_class_policy.referenced_class_minima, so the
same board yields the same values through both and the same defect fails
both closed — the drift C4a produced on day one (one leg guarded, the other
not) is structurally impossible. The corpus mutants
drcgeo_class_*_admission_predicate_dropped now target the SHARED body, so
the sweep proves a relaxed predicate reddens both suites.
"""

from __future__ import annotations

import dataclasses

import pytest

from pcb_worker.compile_board import ResolutionSuccess, compile_board
from pcb_worker.drc_geometric import _net_class_minima
from pcb_worker.methods import _net_class_overrides
from pcb_worker.route_bridge import UnsupportedGeometry


def _classed_rb():
    board = {
        "version": 1, "name": "ncp", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4,
                         "net_classes": [
                             {"name": "Power", "members": ["N1"],
                              "min_trace_width_mm": 0.6,
                              "min_clearance_mm": 0.35}]},
        "components": [{"ref": "X1", "footprint": "R_0805", "x_mm": 10,
                        "y_mm": 10, "rotation_deg": 0, "layer": "top"}],
        "nets": [{"name": "N1", "pins": ["X1.1"]},
                 {"name": "N2", "pins": ["X1.2"]}],
    }
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics]
    return result.board


def test_both_consumers_read_the_same_values_through_one_body():
    rb = _classed_rb()
    by_name = _net_class_overrides(rb)
    by_id = _net_class_minima(rb)
    n1 = next(net for net in rb.nets if net.name == "N1")
    assert by_name["N1"] == (0.6, 0.35)
    assert by_id[n1.id] == (0.6, 0.35)
    assert by_name["N1"] == by_id[n1.id], (
        "the routed width and the checked floor must be ONE value")
    # The classless net appears in neither — referenced classes only.
    n2 = next(net for net in rb.nets if net.name == "N2")
    assert "N2" not in by_name and n2.id not in by_id


def test_an_unsourceable_minimum_fails_both_consumers_closed():
    """The shared raise: doctor the compiled class (the compiler refuses
    authored zeros, so the IR is edited directly — defence-in-depth, stated
    per the stand-in doctrine) and BOTH consumers must refuse it with the
    same sentence, differing only in whose name is on it."""
    rb = _classed_rb()
    bad_class = dataclasses.replace(
        rb.design_rules.net_classes[0], min_trace_width_mm=0.0)
    bad_rules = dataclasses.replace(rb.design_rules, net_classes=(bad_class,))
    bad = dataclasses.replace(rb, design_rules=bad_rules)

    with pytest.raises(UnsupportedGeometry, match="routing fails closed") as e1:
        _net_class_overrides(bad)
    with pytest.raises(UnsupportedGeometry,
                       match="geometric DRC fails closed") as e2:
        _net_class_minima(bad)
    assert str(e1.value).replace("routing", "geometric DRC") == str(e2.value), (
        "one policy, one message — only the context word may differ")
