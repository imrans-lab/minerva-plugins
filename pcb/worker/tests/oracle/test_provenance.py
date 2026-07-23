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


def test_spike_golden_blessed():
    # RE-BLESSED by the owner 2026-07-19 via an independent gerbv walkthrough
    # after regeneration to the real 0805 land — NOT self-blessed. A valid human
    # bless fills provenance: blessed=true with method/date/by all recorded.
    prov = _prov()
    assert SPIKE_ID in prov, "spike golden must have a provenance entry"
    entry = prov[SPIKE_ID]
    assert entry.blessed is True, (
        "spike golden was re-blessed by the owner via independent gerbv walkthrough"
    )
    assert entry.method and entry.date and entry.by, (
        "a blessed golden must record HOW/WHEN/WHO blessed it (method/date/by)"
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


def test_blessed_spike_golden_is_a_correctness_oracle():
    # Post-re-bless: the spike golden IS usable as a correctness oracle. The
    # "unblessed -> not an oracle" invariant stays covered by the permanently-
    # unblessed emitter snapshot (test_unblessed_golden_is_not_a_correctness_oracle).
    usable, reason = correctness_oracle_status(_prov(), SPIKE_ID)
    assert usable is True
    assert reason == ""


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
    # placed=True is a no-op here (resolve_board pads carry no per-pad `rotation`),
    # so this stays byte-matched to the owner-blessed spike golden while satisfying
    # the K4 "every build_gerbers call passes placed=True" rule. NOTE: this uses the
    # STRICT resolve_board (not the IR path) DELIBERATELY — the blessed golden was
    # cut at the 0.1mm default mask clearance, whereas the compile->IR path carries
    # the compiler's resolved 0.05mm clearance; routing this oracle through the IR
    # would (correctly) diverge on the mask layer and break the bless comparison.
    current = parse_output_set(gerber.build_gerbers(board, name="board", placed=True))
    golden = parse_output_set(load_output_dir(SPIKE_GOLDEN_DIR))
    diff = diff_geometry(current, golden).excluding_layers("F_SilkS")
    assert diff.is_empty, (
        "emitter output does not match the BLESSED correctness golden on the "
        "fabrication-critical layers (copper/mask/drill/edge):\n" + diff.describe()
    )
