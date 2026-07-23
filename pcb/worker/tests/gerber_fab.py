"""Shared PRODUCTION fab-path helper for the emitter test suites + the golden
generator (K4 phase 1).

Routes fabrication output EXACTLY the way ``methods._gerbers`` does — COMPILE
(strict) -> ``ir_adapter.ir_to_board_dict`` -> ``gerber.build_gerbers(placed=True)``
— so no emitter test or golden regenerator remains on the LEGACY
``resolve_board_best_effort`` -> ``build_gerbers(placed=False)`` path (which drops
overrides / bottom-side mirror / per-pad rotation).

A fixture whose hand-authored footprints are NOT in the seed library (the
``drilltest`` drill-split fixture) cannot compile — the strict compiler
fail-closes it — so it is emitted DIRECTLY from its raw fixture dict under the
placed emitter. That is a genuine placed dict here: every component is at
rotation 0, so a component-local pad coordinate already equals its board-absolute
one and ``placed=True`` == ``placed=False`` for it (the only thing ``placed``
changes is the per-pad aperture-rotation SOURCE, and this fixture carries no
per-pad rotation). It therefore keeps the SAME drill-split geometry it always
exercised, just off the legacy resolver.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker import gerber
from pcb_worker.compile_board import compile_board
from pcb_worker.ir_adapter import ir_to_board_dict
from pcb_worker.resolved_board import ResolutionSuccess


def load_board(path) -> dict:
    """Load a board fixture YAML into a raw board dict."""
    return yaml.safe_load(Path(path).read_text(encoding="utf-8"))


def placed_board_dict(path) -> dict:
    """The board dict fed to the PLACED emitter, mirroring ``methods._gerbers``.

    Compilable board  -> ``ir_to_board_dict(compile_board(src).board)``
                         (identity placement, board-absolute pads, per-pad rotation).
    Non-compilable    -> the raw fixture dict (strict compile fail-closes; the
                         fixture is all-through-hole at rotation 0, so the raw dict
                         IS a valid placed dict — see the module docstring).
    """
    src = load_board(path)
    result = compile_board(src)
    if isinstance(result, ResolutionSuccess):
        return ir_to_board_dict(result.board)
    return src


def build_fab(path, base: str, **kwargs) -> gerber.GerberResult:
    """Compile + emit a fixture through the production placed path."""
    return gerber.build_gerbers(placed_board_dict(path), name=base, placed=True,
                                **kwargs)
