"""Shared emitter-test build helpers (K4 phase 1).

Two DISTINCT, explicitly-named entry points — the routing a fixture takes is a
property of WHICH helper a test hands it to, never a hidden per-name allowlist:

* :func:`build_fab` — the PRODUCTION fab path. Routes fabrication output EXACTLY
  the way ``methods._gerbers`` does: COMPILE (strict) -> ``gerber.build_gerbers_ir``
  (board-absolute pads, per-pad rotation, bottom-side mirror). It FAILS CLOSED —
  a board that does not compile RAISES, never a silent reroute onto the tolerant
  loose-dict emitter (bug 019f917bbe18). Every production board, golden-as-
  production-oracle, determinism gate, and gerbonara production case uses this.

* :func:`build_raw_emitter` — the RAW loose-dict emitter ``gerber.build_gerbers``,
  which is NOT a production path. It is the honest entry point for the
  ``drilltest`` drift fixture, whose hand-authored footprints (``Conn_02x01`` /
  ``MountPad_M2``) are deliberately NOT in the seed library so it exercises the
  raw drill split (2 plated TH + 1 pad-level ``plated:false`` NPTH + board
  mounting holes + via) that the compiled production path does not carry.

A raw fixture reaches the loose-dict emitter ONLY by being handed to
:func:`build_raw_emitter` BY NAME — it can never get there by merely failing to
compile through :func:`build_fab`. That is the whole point of the split (K4
keystone item 1, retiring the ``_RAW_DICT_FIXTURES`` allowlist seam): the
production helper no longer knows about, or exempts, any fixture.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from pcb_worker import gerber
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess


def load_board(path) -> dict:
    """Load a board fixture YAML into a raw board dict."""
    return yaml.safe_load(Path(path).read_text(encoding="utf-8"))


def build_fab(path, base: str, **kwargs) -> gerber.GerberResult:
    """Compile + emit a fixture through the PRODUCTION IR-native fab path,
    mirroring ``methods._gerbers``: ``build_gerbers_ir(compile_board(src).board)``
    (board-absolute pads, per-pad rotation, bottom-mirror).

    FAIL-CLOSED (bug 019f917bbe18): a board that does NOT compile RAISES — there
    is NO raw-dict fallback and NO per-fixture allowlist. A raw loose-dict fixture
    that legitimately cannot compile (e.g. ``drilltest``) is emitted via the
    explicitly-named :func:`build_raw_emitter`, never by reaching this function
    and silently rerouting a golden / determinism / geometry-diff / gerbonara
    oracle onto the tolerant emitter while production correctly fails.
    """
    src = load_board(path)
    result = compile_board(src)
    if not isinstance(result, ResolutionSuccess):
        codes = [d.code for d in result.diagnostics
                 if d.severity is DiagnosticSeverity.ERROR]
        raise RuntimeError(
            f"build_fab: production compile FAILED for {base!r} — failing CLOSED "
            f"with no raw-dict fallback (bug 019f917bbe18); error codes: {codes}")
    return gerber.build_gerbers_ir(result.board, name=base, **kwargs)


def build_raw_emitter(path, base: str, **kwargs) -> gerber.GerberResult:
    """Emit a fixture DIRECTLY through the raw loose-dict emitter
    ``gerber.build_gerbers`` — this is NOT the production fab path.

    The honest entry point for the ``drilltest`` drift fixture (see module
    docstring): its non-library footprints exercise the raw drill split the
    compiled path does not carry. Every component is placed at rotation 0, so a
    component-local pad coordinate already equals its board-absolute one and the
    fixture carries no per-pad rotation — the raw emit is geometry-faithful, so
    its pinned goldens are byte-stable.

    This helper exists so that a raw fixture's routing is EXPLICIT at the call
    site (paired with this name) rather than exempted by a hidden allowlist inside
    :func:`build_fab`.
    """
    return gerber.build_gerbers(load_board(path), name=base, **kwargs)
