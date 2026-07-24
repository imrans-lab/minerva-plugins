"""CORROBORATING kicad-cli oracle for the IR-native geometric DRC (Round C3).

This is a real (non-mocked) functional floor that cross-checks
``pcb_worker.drc_geometric.run_geometric_drc`` against the EXTERNAL
``kicad-cli pcb drc`` (KiCad 9.0.x) — an independent engine — on the SAME board.
The board fed to kicad-cli is emitted through the production IR path
(``compile_board.compile_board`` -> ``kicad.generate_ir(compiled.board)``, NOT the
loose ``generate_kicad_pcb`` adapter), so the two verdicts are compared over the
same fabricated copper.

WHAT THIS PROVES (and what it does not)
---------------------------------------
This is a CORROBORATION, not a proof of geometric completeness: the kicad board is
still a PROJECTION of our own IR through our own emitter, so a shared bug in the
emitter could fool both engines. It buys us: (1) a KNOWN violation in a category
BOTH engines implement is flagged by BOTH, and (2) a clean board is clean in BOTH.
That is the banked lesson — validate against the real kicad-cli, not just text
asserts — applied to the geometric checker.

CATEGORY INTERSECTION
---------------------
kicad-cli reports many DRC categories (connectivity, silk-over-copper, courtyard,
...) that this engine deliberately does NOT model. The ``kicad flags => we flag``
corroboration is therefore restricted to the INTERSECTION of categories THIS
engine implements: clearance, track width, annular ring, hole-to-hole, and
copper-to-edge. Out-of-scope kicad categories are ignored, never asserted on.
"""

from __future__ import annotations

import pytest

from pcb_worker import compile_board, kicad
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess
from tests.oracle.kicad_drc import (
    kicad_cli_available,
    kicad_cli_version,
    run_drc_on_pcb_text,
)

pytestmark = pytest.mark.skipif(
    not kicad_cli_available(), reason="kicad-cli not on PATH (dev/CI-only oracle)"
)

# kicad-cli DRC violation ``type`` -> the geometric-DRC ``counts`` key(s) that
# model the SAME physical rule. ONLY these categories are corroborated; every
# other kicad category (connectivity, silk, courtyard, ...) is out of scope.
KICAD_TYPE_TO_GEOM = {
    "clearance": ("gc2_copper_clearance",),
    "track_width": ("gc1_trace_width",),
    "annular_width": ("gc4_annular_ring",),
    "hole_clearance": ("gc6_hole_to_hole",),
    "copper_edge_clearance": ("gc5_copper_to_edge",),
}
INTERSECTION_TYPES = frozenset(KICAD_TYPE_TO_GEOM)


def _th(ref: str, x: float, y: float, drill: float = 0.5, annulus: float = 1.6) -> dict:
    return {"ref": ref, "footprint": "TH_TestPoint", "x_mm": x, "y_mm": y,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0, "y_mm": 0,
                      "drill_mm": drill, "annulus_diameter_mm": annulus}]}


def _base(**extra) -> dict:
    board = {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
    }
    board.update(extra)
    return board


def _compile(board: dict):
    result = compile_board.compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics
        if d.severity is DiagnosticSeverity.ERROR]
    return result.board


def _pcb_text_from_ir(rb) -> str:
    """Emit the ResolvedBoard through the production IR path and return the
    ``.kicad_pcb`` text (the same call the ``generate``/``gerbers`` methods make)."""
    files = kicad.generate_ir(rb)
    return next(t for n, t in files.items() if n.endswith(".kicad_pcb"))


def _intersection_violations(drc_result) -> list:
    return [v for v in drc_result.violations
            if v.get("type") in INTERSECTION_TYPES]


# ---------------------------------------------------------------------------
# Version — read DYNAMICALLY, assert >= 9.0.x (never a hardcoded stale literal).
# ---------------------------------------------------------------------------


def test_kicad_cli_version_is_at_least_9_0():
    ver = kicad_cli_version()
    parts = ver.split(".")
    major, minor = int(parts[0]), int(parts[1])
    assert (major, minor) >= (9, 0), (
        f"oracle corroborated against kicad-cli {ver!r}; expected >= 9.0.x")
    # The environment this round runs on is 9.0.9 — record the observed value so a
    # drift is visible in the test log (informational, not a hard pin).
    print(f"[oracle] corroborating against kicad-cli {ver}")


# ---------------------------------------------------------------------------
# (a) A KNOWN clearance violation is flagged by BOTH engines.
# ---------------------------------------------------------------------------


def test_known_clearance_short_flagged_by_both_engines():
    # Two different-net TH lands (radius 0.8mm) with centres 1.7mm apart -> a
    # 0.1mm copper gap < the 0.2mm min-clearance floor. Clearance is a category
    # BOTH engines implement.
    board = _base(components=[_th("U1", 10, 10), _th("U2", 11.7, 10)],
                  nets=[{"name": "A", "pins": ["U1.1"]},
                        {"name": "B", "pins": ["U2.1"]}])
    rb = _compile(board)

    # Our IR-native engine.
    geom = run_geometric_drc(rb)
    assert geom["ok"] is True
    assert geom["verdict"] == "violations"
    assert geom["counts"]["gc2_copper_clearance"] >= 1

    # The independent kicad-cli engine over the SAME board (via the IR emit path).
    kres = run_drc_on_pcb_text(_pcb_text_from_ir(rb), name="clash")
    clearance_hits = [v for v in kres.violations if v.get("type") == "clearance"]
    assert clearance_hits, (
        "expected kicad-cli to flag a clearance violation on the shorted board; "
        f"got types {[v.get('type') for v in kres.violations]}")

    # Intersection-scoped corroboration: every kicad violation in a category THIS
    # engine implements is matched by a non-zero count in the mapped geom
    # category (kicad's out-of-scope categories are ignored).
    for v in _intersection_violations(kres):
        mapped = KICAD_TYPE_TO_GEOM[v["type"]]
        assert any(geom["counts"].get(k, 0) > 0 for k in mapped), (
            f"kicad flagged {v['type']!r} but geometric DRC has zero "
            f"{mapped} findings")


# ---------------------------------------------------------------------------
# (b) A clean board is clean in BOTH engines.
# ---------------------------------------------------------------------------


def test_clean_board_is_clean_in_both_engines():
    # Same two lands moved 20mm apart: comfortably clear on every rule.
    board = _base(components=[_th("U1", 10, 10), _th("U2", 30, 30)],
                  nets=[{"name": "A", "pins": ["U1.1"]},
                        {"name": "B", "pins": ["U2.1"]}])
    rb = _compile(board)

    geom = run_geometric_drc(rb)
    assert geom["ok"] is True
    assert geom["verdict"] == "clean", geom["findings"]

    kres = run_drc_on_pcb_text(_pcb_text_from_ir(rb), name="clean")
    # Clean within the corroborated intersection (out-of-scope kicad categories,
    # e.g. silk, are not asserted on).
    assert not _intersection_violations(kres), (
        "expected no in-scope kicad DRC violations on the clean board; got "
        f"{[v.get('type') for v in _intersection_violations(kres)]}")
    assert not kres.unconnected_items
