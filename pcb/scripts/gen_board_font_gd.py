#!/usr/bin/env python3
"""Generate the GDScript mirror of the board stroke font.

    python3 pcb/scripts/gen_board_font_gd.py

Reads ``pcb/worker/pcb_worker/board_font.py`` (the ONE authored glyph table) and
writes ``pcb/ui/model/pcb_board_font_data.gd``.

WHY A GENERATOR AND NOT A SHARED DATA FILE. The panel cannot import Python, and
it cannot reliably read a JSON asset either: ``pcb/ui/model/pcb_prefs.gd`` and
``PCBPanel.gd`` both record the reason — an off-tree plugin script's FileAccess
path is relative to wherever the script happens to be deployed, which differs
between the dev source tree, a host-owned install and a packaged release. A
``const`` in a .gd file reached by a relative ``preload()`` has none of that
fragility. So the table is authored once in Python and MIRRORED here, which is
the same arrangement ``worker/agent_router/layers.py`` and
``ui/model/pcb_layer_stack.gd`` already use for the layer contract.

The mirror is not trusted to stay in step by convention:
``worker/tests/test_board_font.py::test_gdscript_mirror_is_identical`` re-parses
the generated block and compares it glyph-for-glyph, number-for-number, against
the Python table. Drift fails that check rather than shipping a board whose
editor preview and fabricated legend are different shapes.

The emitted dictionary body is deliberately BOTH valid GDScript and valid JSON,
which is what lets the parity test compare exactly instead of approximately.
"""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "worker"))

from pcb_worker import board_font  # noqa: E402

OUT = ROOT / "ui" / "model" / "pcb_board_font_data.gd"

HEADER = '''extends RefCounted
## Board stroke-font glyph table (GDScript mirror) — GENERATED, do not hand-edit.
##
## Regenerate with:
##     python3 pcb/scripts/gen_board_font_gd.py
##
## Mirrors pcb/worker/pcb_worker/board_font.py value-for-value. That file is the
## authored source and carries the whole design rationale (the 5x7 grid, why the
## baseline is row 6, why the unknown glyph is a box, and the in-house licence
## position). Nothing here should be edited by hand: the parity test
## worker/tests/test_board_font.py::test_gdscript_mirror_is_identical re-parses
## GLYPHS below and compares it to the Python table, so a hand edit fails there
## rather than quietly making the editor draw a different shape than the fab
## receives.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd) — reached via
## a relative preload():
##     const PcbBoardFontData := preload("pcb_board_font_data.gd")
##
## Each entry is ``"<char>": [advance_in_grid_units, [stroke, ...]]`` where a
## stroke is an OPEN chain of ``[grid_x, grid_y]`` integer points. Grid: x 0..4,
## y 0..8 with the BASELINE at y=6 and the cap top at y=0.

## Grid-to-mm scale at size 1.0 — six rows from cap top to baseline, so a
## capital is exactly 1.0 mm tall at size 1.0.
const UNIT := %(unit)r
## The grid row output coordinates are measured from.
const BASELINE_ROW := %(baseline)d
## Advance of a space, in grid units.
const SPACE_ADVANCE := %(space)d
## Gap inserted between adjacent glyphs, in grid units.
const GLYPH_GAP := %(gap)d
## Key of the unknown-glyph box. Deliberately not a printable character, so no
## real glyph can be shadowed by the fallback.
const MISSING_GLYPH_CHAR := %(missing)s

const GLYPHS := '''


def _body() -> str:
    """The glyph table as a literal that parses as GDScript AND as JSON."""
    table = {
        char: [advance, [[list(pt) for pt in stroke] for stroke in strokes]]
        for char, (advance, strokes) in board_font.GLYPHS.items()
    }
    # One glyph per line: a diff of this file must show which CHARACTER moved.
    lines = ["{"]
    for char, entry in table.items():
        lines.append("\t%s: %s," % (json.dumps(char, ensure_ascii=False),
                                    json.dumps(entry, ensure_ascii=False)))
    lines.append("}")
    return "\n".join(lines)


def main() -> int:
    text = HEADER % {
        "unit": board_font.UNIT,
        "baseline": board_font.BASELINE_ROW,
        "space": board_font.SPACE_ADVANCE,
        "gap": board_font.GLYPH_GAP,
        "missing": json.dumps(board_font.MISSING_GLYPH_CHAR, ensure_ascii=False),
    } + _body() + "\n"
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT.parent)} ({len(board_font.GLYPHS)} glyphs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
