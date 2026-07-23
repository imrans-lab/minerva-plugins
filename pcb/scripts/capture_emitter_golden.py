#!/usr/bin/env python
"""Capture the CURRENT emitter output as the drift-pin golden snapshot.

DRIFT-PIN ONLY — NOT A CORRECTNESS ORACLE. This freezes what
``pcb_worker.gerber.build_gerbers`` emits TODAY for the spike board, so a future
change to the emitter produces a NON-EMPTY geometry delta (see
tests/oracle/geometry_diff.py). Because the snapshot is captured FROM the emitter
under test, it is inherently circular and can NEVER attest correctness — its
provenance entry (emitter-snapshot-v1) stays blessed=false by design. The
independent correctness reference is the hand-built, structurally-validated spike
golden at pcb/spikes/gerber/golden/ (provenance id spike-gerber-v1), whose bless
is deferred to a human-in-the-loop session (see golden/HOW_TO_BLESS.md).

Run from the repo root or anywhere:  python pcb/scripts/capture_emitter_golden.py
Regenerate ONLY on an intentional emitter change, and re-run the worker suite.
"""

from __future__ import annotations

import sys
from pathlib import Path

# pcb/scripts/this.py -> pcb/
PCB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PCB / "worker"))

from tests.gerber_fab import build_fab  # noqa: E402

SPIKE_BOARD = PCB / "spikes" / "gerber" / "board.yaml"
OUT_DIR = PCB / "worker" / "tests" / "oracle" / "golden_emitter"


def main() -> int:
    # Capture THROUGH THE PRODUCTION (IR) PATH, exactly as methods._gerbers runs
    # it (K4 phase 2): COMPILE (strict) -> ir_to_board_dict -> build_gerbers. The
    # raw spike would fail closed (its SMD pins carry no inline geometry), so the
    # drift pin tracks the compiled/resolved emitter output — the real production
    # input. build_fab centralizes this path (the SAME helper the emitter tests +
    # the gerber-golden regenerator use).
    files = build_fab(SPIKE_BOARD, "board")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (OUT_DIR / name).write_text(text, encoding="utf-8")
        print(f"wrote {name} ({len(text)} bytes)")
    print(f"\nEmitter drift-pin snapshot written to {OUT_DIR}")
    print("Reminder: this is DRIFT-PIN ONLY (blessed=false); it is NOT a "
          "correctness oracle.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
