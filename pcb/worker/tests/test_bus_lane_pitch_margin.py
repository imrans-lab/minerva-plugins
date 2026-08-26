"""The bus tool's LAID pitch must clear the geometric DRC's copper-clearance
rule outright, on coordinates that have been through float32.

THE DEFECT THIS PINS. The bus tool spaces its lanes with
``pcb_bus_geometry.gd``; the fab-facing check is ``run_geometric_drc`` here,
whose ``_violates`` allows ``EPS = 1e-9`` of slack — float64 noise, nothing
more. Godot stores every coordinate in a float32 ``Vector2``, so two lanes laid
EXACTLY one rule-pitch apart round onto the float32 grid on opposite sides and
arrive here a few micrometres short of the rule. GC2 then reports the bus
against itself while the tool's own tolerance-based check reads clean. The
tool now lays every spacing ``LANE_PITCH_MARGIN_MM`` past the rule.

THE ORACLE is this kernel, not the tool: a two-lane pair built by hand at the
laid pitch, every coordinate pushed through float32 the way a Vector2 would
store it, must raise NO gc2 row between the lanes; the same pair at the bare
rule pitch on the same spine MUST raise one — that half proves the kernel was
not loosened and that the coordinate really does fall short, so the clean half
cannot pass by luck of the coordinate. The margin is READ OUT OF THE GD SOURCE
rather than restated here, so the two languages cannot drift apart silently.
"""

from __future__ import annotations

import re
import struct
from pathlib import Path

from pcb_worker.compile_board import ResolutionSuccess, compile_board
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.resolved_board import DiagnosticSeverity

_BUS_GEOMETRY_GD = Path(__file__).resolve().parents[2] / "ui" / "model" / "pcb_bus_geometry.gd"

_WIDTH = 0.3
_CLEARANCE = 0.2
_RULE_PITCH = _WIDTH / 2 + _CLEARANCE + _WIDTH / 2  # 0.5: the kernel's own floor
# A spine coordinate on which 64.02 and 63.52 land on the float32 grid on
# opposite sides: their stored difference is 0.4999962, 3.8 micrometres short
# of the rule — the shape of the live report (0.199997 against 0.2).
_SPINE_Y = 64.02


def _lane_pitch_margin_mm() -> float:
    """``LANE_PITCH_MARGIN_MM`` as the GD module declares it."""
    text = _BUS_GEOMETRY_GD.read_text(encoding="utf-8")
    m = re.search(r"^const LANE_PITCH_MARGIN_MM := ([0-9.]+)", text, re.M)
    assert m, f"LANE_PITCH_MARGIN_MM not declared in {_BUS_GEOMETRY_GD}"
    return float(m.group(1))


def _f32(value: float) -> float:
    """``value`` after a round trip through a float32 Vector2 component."""
    return struct.unpack("f", struct.pack("f", value))[0]


def _board(pitch: float) -> dict:
    """Two parallel lanes on different nets, ``pitch`` apart about ``_SPINE_Y``,
    coordinates stored the way the panel would store them. R1's pads give each
    net a real pin so compile accepts; they sit well clear of both lanes."""
    lane_a = _f32(_SPINE_Y - pitch)
    lane_b = _f32(_SPINE_Y)
    return {
        "version": 1, "name": "bus-lane-pitch", "width_mm": 80, "height_mm": 80,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": _CLEARANCE, "trace_width_mm": _WIDTH,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 40, "y_mm": 70,
             "rotation_deg": 0, "layer": "top"},
        ],
        "nets": [{"name": "A", "pins": ["R1.1"]},
                 {"name": "B", "pins": ["R1.2"]}],
        "traces": [
            {"net": "A", "layer": "top", "width_mm": _WIDTH,
             "points": [{"x_mm": _f32(10.0), "y_mm": lane_a},
                        {"x_mm": _f32(70.0), "y_mm": lane_a}]},
            {"net": "B", "layer": "top", "width_mm": _WIDTH,
             "points": [{"x_mm": _f32(10.0), "y_mm": lane_b},
                        {"x_mm": _f32(70.0), "y_mm": lane_b}]},
        ],
    }


def _gc2_rows(pitch: float) -> list[dict]:
    result = compile_board(_board(pitch))
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    findings = run_geometric_drc(result.board)["findings"]
    return [f for f in findings if f["type"] == "gc2_copper_clearance"]


def test_the_spine_coordinate_really_falls_short_in_float32():
    """The fixture's premise, measured: at the bare rule the stored lanes are
    short of the rule by more than the kernel's EPS. If float32 happened to
    land both coordinates on the same side this whole file would prove
    nothing, so the premise is asserted before either half runs."""
    stored = _f32(_SPINE_Y) - _f32(_SPINE_Y - _RULE_PITCH)
    assert stored < _RULE_PITCH - 1e-6, stored


def test_lanes_laid_at_the_bare_rule_are_reported_by_gc2():
    """The kernel still bites: this is the defect, and it must stay red so
    the clean half below is known to be the MARGIN's doing."""
    rows = _gc2_rows(_RULE_PITCH)
    assert rows, "two lanes exactly one rule-pitch apart through float32 must raise gc2"
    assert rows[0]["required_mm"] == _CLEARANCE
    assert rows[0]["measured_mm"] < _CLEARANCE


def test_lanes_laid_at_the_gd_modules_pitch_clear_gc2_with_no_tolerance_spent():
    margin = _lane_pitch_margin_mm()
    assert margin >= 0.005, (
        "the margin has to clear float32 residue at any board magnitude by "
        f"orders, not by luck: {margin}")
    rows = _gc2_rows(_RULE_PITCH + margin)
    assert rows == [], rows
