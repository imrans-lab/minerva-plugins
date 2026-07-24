"""Shared PRODUCTION fab-path helper for the emitter test suites + the golden
generator (K4 phase 1).

Routes fabrication output EXACTLY the way ``methods._gerbers`` does — COMPILE
(strict) -> ``gerber.build_gerbers_ir`` — so no emitter test or golden
regenerator remains on the LEGACY ``resolve_board_best_effort`` path (which
dropped overrides / bottom-side mirror / per-pad rotation).

FAIL-CLOSED (bug 019f917bbe18): a board that does NOT compile fails CLOSED here
by RAISING — exactly like production ``methods._gerbers`` — so a compiler /
library / source-contract regression can NEVER silently reroute the golden,
determinism, geometry-diff, or gerbonara oracles onto the tolerant loose-dict
emitter while production correctly fails.

The one deliberate exception is the ``drilltest`` drill-split fixture, whose
hand-authored footprints (``Conn_02x01`` / ``MountPad_M2``) are intentionally
NOT in the seed library so it exercises the raw loose-dict drill emitter. It —
and ONLY it, by EXPLICIT NAME in :data:`_RAW_DICT_FIXTURES` — is emitted directly
from its raw fixture dict through ``gerber.build_gerbers``. That is a genuine
placed dict: every component is at rotation 0, so a component-local pad
coordinate already equals its board-absolute one and the fixture carries no
per-pad rotation, so it keeps the SAME drill-split geometry it always exercised.
A future non-library fixture must be added to the set EXPLICITLY — it can never
reach the raw path by merely failing to compile.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker import gerber
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

# Fixtures (by base name) that legitimately CANNOT compile — non-library
# footprints, emitted through the raw loose-dict path ON PURPOSE. An EXPLICIT
# allowlist, never a compile-failure fallback (bug 019f917bbe18).
_RAW_DICT_FIXTURES = frozenset({"drilltest"})


def load_board(path) -> dict:
    """Load a board fixture YAML into a raw board dict."""
    return yaml.safe_load(Path(path).read_text(encoding="utf-8"))


def build_fab(path, base: str, **kwargs) -> gerber.GerberResult:
    """Compile + emit a fixture through the production IR-native fab path,
    mirroring ``methods._gerbers``.

    Compilable board -> ``gerber.build_gerbers_ir(compile_board(src).board)``
    (board-absolute pads, per-pad rotation, bottom-mirror). A compile FAILURE on
    any board NOT in :data:`_RAW_DICT_FIXTURES` RAISES (production fail-closed) —
    never a silent raw-dict fallback. The named non-library fixtures use
    ``gerber.build_gerbers`` on their raw placed dict (see module docstring).
    """
    src = load_board(path)
    if base in _RAW_DICT_FIXTURES:
        return gerber.build_gerbers(src, name=base, **kwargs)
    result = compile_board(src)
    if not isinstance(result, ResolutionSuccess):
        codes = [d.code for d in result.diagnostics
                 if d.severity is DiagnosticSeverity.ERROR]
        raise RuntimeError(
            f"build_fab: production compile FAILED for {base!r} — failing CLOSED "
            f"with no raw-dict fallback (bug 019f917bbe18); error codes: {codes}")
    return gerber.build_gerbers_ir(result.board, name=base, **kwargs)
