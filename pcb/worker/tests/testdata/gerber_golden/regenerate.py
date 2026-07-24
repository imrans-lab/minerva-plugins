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

HERE = Path(__file__).resolve().parent
WORKER = HERE.parents[2]  # pcb/worker
sys.path.insert(0, str(WORKER))

from tests.gerber_fab import build_fab, build_raw_emitter  # noqa: E402

SPIKE_BOARD = WORKER.parent / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE.parent / "gerber_boards" / "drilltest.yaml"

# (board path, base name, builder) — the SAME helpers the emitter tests use.
# The spike's footprints (R_0805/C_0805/TH_TestPoint) compile to their real
# lands, so it regenerates THROUGH THE PRODUCTION PATH (build_fab: COMPILE strict
# -> build_gerbers_ir). drilltest's hand-authored footprints are not in the seed
# lib, so it regenerates through the explicit raw loose-dict emitter
# (build_raw_emitter, all-TH at rotation 0 -> placed geometry == unplaced). K4
# keystone item 1 retired the _RAW_DICT_FIXTURES allowlist: routing is now
# per-case and explicit, never a compile-failure fallback.
CASES = [
    (SPIKE_BOARD, "board", build_fab),
    (DRILL_BOARD, "drilltest", build_raw_emitter),
]


def main() -> int:
    for board_path, base, builder in CASES:
        files = builder(board_path, base)
        for fname, content in files.items():
            (HERE / fname).write_text(content, encoding="utf-8", newline="\n")
            print(f"wrote {fname} ({len(content)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
