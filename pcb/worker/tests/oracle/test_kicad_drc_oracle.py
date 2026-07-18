"""DEV-ONLY kicad-cli DRC oracle — runs green on a known-good fixture.

This is the real (non-mocked) functional floor for the DRC oracle: it renders the
spike board through the worker's own KiCad emitter and runs the external
``kicad-cli pcb drc`` (KiCad 9.0.7) over the real bytes. Skips cleanly if
kicad-cli is not installed.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

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
    """The spike fixture, rendered by pcb_worker.kicad, passes kicad-cli DRC."""
    result = run_drc_on_board(_load(SPIKE_BOARD), name="board")
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
             "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0},
                      {"number": "2", "x_mm": 0.0, "y_mm": 0.0}]},
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
