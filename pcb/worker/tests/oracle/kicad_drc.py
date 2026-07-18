"""DEV/TEST-ONLY kicad-cli DRC oracle.

An INDEPENDENT check on the worker's board geometry: it takes a canonical board
dict, renders it to a ``.kicad_pcb`` with the worker's own emitter
(``pcb_worker.kicad.generate_kicad_pcb`` — reused, not reimplemented), then runs
the external ``kicad-cli pcb drc`` (KiCad 9.0.7) over it and parses the structured
JSON report into :class:`DrcResult`.

BOUNDARY (enforced by SB.3 lint): this module lives under ``tests/`` and shells
out to the ``kicad-cli`` binary, which is a developer/CI tool — NOT a worker
runtime dependency (no kicad on the deploy target, no FCIB). It must NEVER be
importable from ``pcb_worker`` runtime. Importing ``pcb_worker.kicad`` FROM here
is the allowed (upward) direction.

kicad-cli is discovered on PATH; :func:`kicad_cli_available` lets tests skip
cleanly when it is absent (CI without KiCad installed).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from pcb_worker import kicad

KICAD_CLI = "kicad-cli"


def kicad_cli_available() -> bool:
    """True when the external kicad-cli binary is on PATH."""
    return shutil.which(KICAD_CLI) is not None


@dataclass
class DrcResult:
    """Parsed ``kicad-cli pcb drc`` JSON report."""

    violations: list
    unconnected_items: list
    schematic_parity: list
    raw: dict

    @property
    def clean(self) -> bool:
        """No DRC violations and no unconnected items."""
        return not self.violations and not self.unconnected_items


def run_drc_on_pcb_text(pcb_text: str, name: str = "board",
                        timeout: float = 120.0) -> DrcResult:
    """Run ``kicad-cli pcb drc`` over a .kicad_pcb source string.

    Writes the board to a temp file, invokes kicad-cli with JSON output, and
    returns the parsed structured finding set. The report JSON — not the process
    return code — is the source of truth; ``--exit-code-violations`` is
    deliberately NOT passed so callers assert on the structured findings.
    """
    with tempfile.TemporaryDirectory() as td:
        pcb = Path(td) / f"{name}.kicad_pcb"
        pcb.write_text(pcb_text, encoding="utf-8")
        report = Path(td) / "drc.json"
        proc = subprocess.run(
            [KICAD_CLI, "pcb", "drc", "--format", "json",
             "--output", str(report), str(pcb)],
            capture_output=True, text=True, timeout=timeout,
        )
        if not report.exists():
            raise RuntimeError(
                f"kicad-cli pcb drc produced no report (rc={proc.returncode}): "
                f"{proc.stderr.strip() or proc.stdout.strip()}"
            )
        data = json.loads(report.read_text(encoding="utf-8"))

    return DrcResult(
        violations=list(data.get("violations", [])),
        unconnected_items=list(data.get("unconnected_items", [])),
        schematic_parity=list(data.get("schematic_parity", [])),
        raw=data,
    )


def run_drc_on_board(board: dict, name: str = "board") -> DrcResult:
    """Render a canonical board to KiCad and run the DRC oracle over it."""
    return run_drc_on_pcb_text(kicad.generate_kicad_pcb(board), name=name)
