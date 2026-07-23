"""DEV-ONLY kicad-cli DRC oracle — runs green on a known-good fixture.

This is the real (non-mocked) functional floor for the DRC oracle: it renders the
spike board through the worker's own KiCad emitter and runs the external
``kicad-cli pcb drc`` (KiCad 9.0.7) over the real bytes. Skips cleanly if
kicad-cli is not installed.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

from pcb_worker import resolve
from tests.oracle.kicad_drc import (
    DrcResult,
    kicad_cli_available,
    run_drc_on_board,
    run_drc_on_pcb_text,
)

HERE = Path(__file__).resolve().parent  # pcb/worker/tests/oracle
SPIKE_BOARD = HERE.parents[2] / "spikes" / "gerber" / "board.yaml"  # pcb/spikes/...

pytestmark = pytest.mark.skipif(
    not kicad_cli_available(), reason="kicad-cli not on PATH (dev/CI-only oracle)"
)


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def test_spike_board_drc_clean():
    """The spike fixture, rendered by pcb_worker.kicad, passes kicad-cli DRC.

    Best-effort resolved first, as the production fab path does (step 4a-ii): the
    raw spike fails closed (its SMD pins carry no inline geometry)."""
    result = run_drc_on_board(resolve.resolve_board_best_effort(_load(SPIKE_BOARD)),
                              name="board")
    assert isinstance(result, DrcResult)
    assert result.clean, (
        f"expected a clean DRC on the known-good spike board, got "
        f"{len(result.violations)} violation(s), "
        f"{len(result.unconnected_items)} unconnected: "
        f"{result.violations or result.unconnected_items}"
    )


def test_drc_returns_structured_findings_on_bad_board():
    """A board with two pads of different nets overlapping at the SAME point
    produces at least one structured DRC finding — proving the oracle surfaces
    violations, not just clean passes."""
    board = {
        "version": 1, "name": "clash", "width_mm": 10, "height_mm": 10,
        "components": [
            {"ref": "U1", "footprint": "FP", "x_mm": 5.0, "y_mm": 5.0,
             "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5},
                      {"number": "2", "x_mm": 0.0, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5}]},
        ],
        "nets": [
            {"name": "A", "pins": ["U1.1"]},
            {"name": "B", "pins": ["U1.2"]},
        ],
    }
    result = run_drc_on_board(board, name="clash")
    findings = result.violations + result.unconnected_items
    assert findings, "expected kicad-cli DRC to flag the coincident different-net pads"
    # Each finding is a structured dict (has a type/description), not opaque text.
    assert all(isinstance(f, dict) for f in findings)


def test_oblong_th_pad_round_trips_through_real_pcbnew():
    """C2 (finding 019f8b7fd295): a FAITHFUL oblong through-hole land parses in the
    REAL pcbnew parser and passes kicad-cli DRC — the process lesson requires KiCad
    emission be validated against the real parser, not text assertions. A 2.0x1.5
    oval PTH land with a round 0.8 drill (annulus 0.35 on the narrow axis, above the
    0.1 minimum) must round-trip cleanly; before C2 this collapsed to a round Ø2.0
    annulus, silently dropping the 1.5 extent."""
    pad = {"number": "1", "type": "thru_hole", "shape": "oval",
           "position": {"x": 0, "y": 0}, "size": {"width": 2.0, "height": 1.5},
           "drill": {"x": 0.8, "y": 0.8}, "layers": ["F.Cu", "B.Cu"]}
    board = {
        "version": 2, "name": "oblong_th", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"trace_width_mm": 0.25, "clearance_mm": 0.2},
        "components": [{"ref": "P1", "footprint": "F", "x_mm": 10, "y_mm": 10,
                        "rotation_deg": 0, "layer": "top", "pads": [pad]}],
    }
    result = run_drc_on_board(board, name="oblong_th")
    assert result.clean, (
        f"a faithful oblong-TH board must pass real-pcbnew DRC, got "
        f"{result.violations or result.unconnected_items}")


def test_real_placement_footprints_round_trip_through_real_pcbnew():
    """C3 (finding 019f8dbb6593): the REAL-placement kicad encoding — footprints at
    ``(at px py rot)`` with footprint-local pads (was every footprint at 0,0,0 with
    board-absolute pads) — round-trips through the real pcbnew parser DRC-CLEAN, for
    ROTATED top, ROTATED bottom, and a mounting-hole footprint. This validates the
    inverse-transform math against the real parser (the banked lesson), and asserts
    the footprints now sit at their real placements (CPL / editability restored),
    not stacked at the origin. Routed through the PRODUCTION methods path
    (compile -> ir_to_kicad_board_dict -> kicad.generate)."""
    from pcb_worker.methods import handle_request
    board = {
        "version": 1, "name": "rp", "width_mm": 60, "height_mm": 60,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": "R1", "footprint": "R_0805", "x_mm": 15, "y_mm": 20,
             "rotation_deg": 90, "layer": "top"},
            {"ref": "R2", "footprint": "R_0805", "x_mm": 30, "y_mm": 35,
             "rotation_deg": 45, "layer": "bottom"},
            {"ref": "J1",
             "footprint": "Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal",
             "x_mm": 40, "y_mm": 15, "rotation_deg": 180, "layer": "top"},
        ],
        "mounting_holes": [{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2, "plated": False}],
    }
    resp = handle_request({"id": "r", "method": "generate", "params": {"board": board}})
    assert resp["ok"] is True, resp
    pcb = next(v for k, v in resp["result"]["files"].items()
               if k.endswith(".kicad_pcb"))
    # CPL fix: every footprint at its real placement + side, none stacked at 0,0,0.
    placements = re.findall(
        r'\(footprint "[^"]+" \(layer "([^"]+)"\) \(at ([^)]+)\)', pcb)
    assert len(placements) == 4                            # all 4 footprints matched
    sides = {layer for layer, _ in placements}
    assert sides == {"F.Cu", "B.Cu"}                      # both sides present
    assert all(at.strip() != "0.0 0.0 0.0" for _, at in placements)  # none at the origin
    result = run_drc_on_pcb_text(pcb, name="rp")
    assert result.clean, (
        f"real-placement board must pass real-pcbnew DRC, got "
        f"{result.violations or result.unconnected_items}")
