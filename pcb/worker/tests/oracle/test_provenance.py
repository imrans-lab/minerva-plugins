"""GOLDEN PROVENANCE protocol tests (docket SB.2).

Enforces the anti-circularity rule: a golden may be used as a CORRECTNESS ORACLE
only if the provenance registry blesses it (blessed=true, set by a human after an
INDEPENDENT external check — see golden/HOW_TO_BLESS.md). A golden that is
blessed=false, or has no entry, is UNTRUSTED: usable as a drift pin, but the
correctness assertion must be SKIPPED-WITH-REASON, never silently passed.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import gerber
from tests.oracle.geometry_diff import diff_geometry, load_output_dir, parse_output_set
from tests.oracle.provenance import (
    ProvenanceEntry,
    correctness_oracle_status,
    load_provenance,
)

HERE = Path(__file__).resolve().parent                 # pcb/worker/tests/oracle
SPIKE_GOLDEN_DIR = HERE.parents[2] / "spikes" / "gerber" / "golden"
PROV_PATH = SPIKE_GOLDEN_DIR / "PROVENANCE.json"
SPIKE_BOARD = HERE.parents[2] / "spikes" / "gerber" / "board.yaml"

SPIKE_ID = "spike-gerber-v1"
SNAPSHOT_ID = "emitter-snapshot-v1"


def _prov() -> dict[str, ProvenanceEntry]:
    return load_provenance(PROV_PATH)


# ---------------------------------------------------------------------------
# Registry loads; the spike golden is a CANDIDATE (blessed=false), not self-blessed.
# ---------------------------------------------------------------------------


def test_provenance_loads_and_spike_is_unblessed_candidate():
    prov = _prov()
    assert SPIKE_ID in prov, "spike golden must have a provenance entry"
    entry = prov[SPIKE_ID]
    assert entry.blessed is False, (
        "the spike golden MUST NOT be self-blessed by the implementer — it is a "
        "candidate awaiting an external human bless"
    )
    assert "AWAITING" in entry.notes.upper()
    assert entry.method is None and entry.by is None


def test_snapshot_golden_is_permanent_drift_pin():
    """The emitter-captured snapshot is blessed=false BY DESIGN (circular)."""
    entry = _prov()[SNAPSHOT_ID]
    assert entry.blessed is False
    assert entry.role == "drift-pin-only"
    assert "DRIFT-PIN ONLY" in entry.notes.upper() or "DRIFT PIN" in entry.notes.upper()


# ---------------------------------------------------------------------------
# The gate: unblessed / missing goldens are NOT correctness oracles; a blessed
# one IS (proving the gate isn't trivially always-false).
# ---------------------------------------------------------------------------


def test_unblessed_spike_golden_is_not_a_correctness_oracle():
    usable, reason = correctness_oracle_status(_prov(), SPIKE_ID)
    assert usable is False
    assert reason and "blessed" in reason.lower()


def test_missing_golden_is_untrusted():
    usable, reason = correctness_oracle_status(_prov(), "does-not-exist")
    assert usable is False
    assert "no provenance entry" in reason.lower()


def test_blessed_entry_would_be_a_correctness_oracle():
    """A synthetic blessed=true entry IS usable — proves the gate has a true
    branch and isn't rejecting everything unconditionally."""
    synthetic = {
        "blessed-example": ProvenanceEntry(
            golden_id="blessed-example", blessed=True, method="gerbv visual",
            date="2026-07-18", by="owner", notes="externally confirmed",
            path=None, role="correctness-reference", raw={},
        )
    }
    usable, reason = correctness_oracle_status(synthetic, "blessed-example")
    assert usable is True
    assert reason == ""


# ---------------------------------------------------------------------------
# The correctness-ORACLE use of the spike golden: gated, skipped-with-reason
# while unblessed — NEVER silently passed.
# ---------------------------------------------------------------------------


def test_spike_golden_correctness_oracle_is_gated():
    """Treat the spike golden as a CORRECTNESS oracle (assert the live emitter
    matches known-good geometry) ONLY if provenance blesses it. Unblessed ->
    skip-with-reason. This is the load-bearing anti-circularity assertion: the
    correctness claim is never made against an untrusted golden.
    """
    prov = _prov()
    usable, reason = correctness_oracle_status(prov, SPIKE_ID)
    if not usable:
        pytest.skip(f"spike golden not usable as correctness oracle: {reason}")

    # Only reached once a human blesses spike-gerber-v1 (blessed=true).
    board = yaml.safe_load(SPIKE_BOARD.read_text(encoding="utf-8"))
    current = parse_output_set(gerber.build_gerbers(board, name="board"))
    golden = parse_output_set(load_output_dir(SPIKE_GOLDEN_DIR))
    diff = diff_geometry(current, golden)
    assert diff.is_empty, (
        "emitter output does not match the BLESSED correctness golden:\n"
        + diff.describe()
    )
