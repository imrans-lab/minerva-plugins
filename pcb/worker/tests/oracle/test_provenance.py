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

from pcb_worker import gerber, resolve
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
# Registry loads; the spike golden was BLESSED by the owner (2026-07-18) via an
# independent gerbv layer-by-layer walkthrough — NOT self-blessed by the
# implementer. The bless must be well-formed: blessed=true with method/date/by
# all filled in by a human. (The anti-self-bless regression is preserved by the
# permanently-unblessed emitter-snapshot entry, exercised below.)
# ---------------------------------------------------------------------------


def test_spike_golden_regenerated_pending_rebless():
    # The spike golden was REGENERATED 2026-07-19 to the real 0805 land
    # (1.0x1.45, sourced by resolving vendored footprints) as part of Stage 2
    # pad-bug closure. A changed golden is UNBLESSED until the owner independently
    # re-confirms it in gerbv — blessed=false is the honest interim state, and it
    # must record that it awaits re-bless (and why).
    prov = _prov()
    assert SPIKE_ID in prov, "spike golden must have a provenance entry"
    entry = prov[SPIKE_ID]
    assert entry.blessed is False, (
        "a regenerated golden must be UNBLESSED until the owner re-blesses it"
    )
    notes = entry.notes.upper()
    assert "PENDING" in notes and "RE-BLESS" in notes, (
        "an unblessed-pending golden must record that it awaits re-bless + why"
    )


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


def test_unblessed_golden_is_not_a_correctness_oracle():
    # Anchored on the emitter snapshot, which is blessed=false PERMANENTLY by
    # design (circular drift-pin) — so this "unblessed -> not an oracle" guard
    # keeps live coverage even though the spike golden is now blessed.
    usable, reason = correctness_oracle_status(_prov(), SNAPSHOT_ID)
    assert usable is False
    assert reason and "blessed" in reason.lower()


def test_regenerated_spike_golden_is_not_yet_a_correctness_oracle():
    # While blessed=false (regenerated, pending re-bless), the spike golden is
    # NOT usable as a correctness oracle — the correctness test skips-with-reason
    # until the owner re-blesses. The gate's TRUE branch stays covered by
    # test_blessed_entry_would_be_a_correctness_oracle below.
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


def test_spike_golden_correctness_oracle_matches_emitter():
    """Use the blessed spike golden as a real CORRECTNESS oracle: assert the live
    emitter's FABRICATION-CRITICAL geometry (copper/mask/drill/edge) matches the
    trusted known-good golden — over the RESOLVED board, because Stage 2's whole
    point is that pad geometry comes from RESOLVING the footprint, not a
    placeholder (pad bug 019f7736b236).

    This is the payoff of the anti-circularity control — a byte-determinism gate
    could never make this claim. While the golden is UNBLESSED (regenerated to
    the real 0805 land, pending owner gerbv re-bless) this SKIPS-WITH-REASON,
    never a silent pass; once the owner sets blessed=true it is a live assertion
    and pad bug 019f7736b236 is CLOSED.

    ORACLE SCOPE (Option A): silk is EXCLUDED — the emitter draws courtyards
    procedurally, legitimately differently from this synthetic golden's
    hand-drawn ones. Silk correctness is earned separately against real
    footprints that carry real silk graphics (silk-text 019f77fd6d69; coverage
    audit 019f77fd9c6c), not by pinning to a synthetic golden's courtyard boxes.
    """
    prov = _prov()
    usable, reason = correctness_oracle_status(prov, SPIKE_ID)
    if not usable:  # skips while regenerated-but-unblessed; live once re-blessed
        pytest.skip(f"spike golden not usable as correctness oracle: {reason}")

    board = resolve.resolve_board(yaml.safe_load(SPIKE_BOARD.read_text(encoding="utf-8")))
    current = parse_output_set(gerber.build_gerbers(board, name="board"))
    golden = parse_output_set(load_output_dir(SPIKE_GOLDEN_DIR))
    diff = diff_geometry(current, golden).excluding_layers("F_SilkS")
    assert diff.is_empty, (
        "emitter output does not match the BLESSED correctness golden on the "
        "fabrication-critical layers (copper/mask/drill/edge):\n" + diff.describe()
    )
