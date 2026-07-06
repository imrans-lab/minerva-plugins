#!/usr/bin/env python
"""Regenerate the pinned gerber goldens THROUGH THE PRODUCTION PATH.

Unlike the spike's golden/ (built by a hand-coded generate.py), these goldens
come from pcb_worker.gerber.build_gerbers — the exact code the `gerbers` worker
method runs — so a golden diff is a real regression signal for the production
compiler, not for a throwaway script.

Run from the worker/ directory:

    python -m pytest tests/test_gerbers.py        # verifies against these goldens
    python tests/testdata/gerber_golden/regenerate.py   # rewrites them

Only rewrite when a deliberate output change is intended, and re-diff by hand.
Byte-stability holds only at gerber-writer==0.4.3.3 (its coordinate-format
self-selection is board-extent-dependent — see ../../../docs/gerbers.md).
"""
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
WORKER = HERE.parents[2]  # pcb/worker
sys.path.insert(0, str(WORKER))

from pcb_worker import gerber  # noqa: E402

SPIKE_BOARD = WORKER.parent / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE.parent / "gerber_boards" / "drilltest.yaml"

CASES = [(SPIKE_BOARD, "board"), (DRILL_BOARD, "drilltest")]


def main() -> int:
    for board_path, base in CASES:
        board = yaml.safe_load(board_path.read_text(encoding="utf-8"))
        files = gerber.build_gerbers(board, name=base)
        for fname, content in files.items():
            (HERE / fname).write_text(content, encoding="utf-8", newline="\n")
            print(f"wrote {fname} ({len(content)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
