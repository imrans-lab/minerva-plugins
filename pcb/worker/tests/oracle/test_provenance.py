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

from tests.gerber_fab import build_fab
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
    # A valid human bless fills provenance: blessed=true with method/date/by. The
    # golden may sit in a DELIBERATE, documented "pending owner re-bless" window after
    # a correctness-affecting emitter change (here: E3's NPTH mask, docket
    # 019f901a9966) — regenerated from the emitter, blessed=false until the owner
    # re-blesses via an independent gerbv/pcbnew check. That transient state SKIPS;
    # an UNdocumented blessed=false (accidental un-bless) still fails.
    prov = _prov()
    assert SPIKE_ID in prov, "spike golden must have a provenance entry"
    entry = prov[SPIKE_ID]
    if not entry.blessed and "pending owner re-bless" in (entry.notes or ""):
        pytest.skip("spike golden UNBLESSED pending owner re-bless "
                    "(019f901a9966): re-bless via independent gerbv, then restore "
                    "blessed=true + method/date/by")
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
    # Once blessed, the spike golden IS usable as a correctness oracle. The
    # "unblessed -> not an oracle" invariant stays covered by the permanently-
    # unblessed emitter snapshot (test_unblessed_golden_is_not_a_correctness_oracle).
    # During the documented pending-re-bless window (E3, 019f901a9966) it is correctly
    # NOT usable — skip until the owner re-blesses.
    entry = _prov()[SPIKE_ID]
    if not entry.blessed and "pending owner re-bless" in (entry.notes or ""):
        pytest.skip("spike golden UNBLESSED pending owner re-bless (019f901a9966)")
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
    """Use the blessed spike golden as a real CORRECTNESS oracle: assert the
    PRODUCTION emitter's FABRICATION-CRITICAL geometry (copper/mask/drill/edge)
    matches the trusted known-good golden.

    Routed through the PRODUCTION fab path — ``build_fab`` = COMPILE (strict) ->
    ``build_gerbers_ir``, EXACTLY as ``methods._gerbers`` does — so the oracle
    certifies USER-FACING CAM, not a legacy path (K4 correctness-oracle fix, bug
    019f91f9e89c). Previously this ran the legacy ``build_gerbers(resolve_board(...))``
    path, whose default 0.1mm mask clearance matched the old golden while production
    (compile->IR) resolves the compiler's 0.05mm clearance — so a green oracle
    certified the RETIRED path, not what the user ships (24 F.Mask/B.Mask deltas).
    The independent golden is now cut at the ratified 0.05mm (owner decision;
    generate.py MASK_CLEARANCE, still gerber_writer — NOT the emitter under test, so
    anti-circularity holds), and this asserts production == golden on the fab layers.

    This is the payoff of the anti-circularity control — a byte-determinism gate
    could never make this claim. While the golden is UNBLESSED (re-cut to 0.05mm,
    pending owner gerbv/kicad-cli re-bless) this SKIPS-WITH-REASON, never a silent
    pass; once the owner sets blessed=true it is a live assertion.

    ORACLE SCOPE (Option A): silk is EXCLUDED — F.SilkS is a cosmetic legend
    layer, not fabrication-critical geometry. Production emits only REAL footprint
    silk graphics (K4: the procedural courtyard-box placeholder is retired; the
    spike board authors no silk, so production emits an EMPTY legend layer while the
    independent golden still draws courtyards — a deliberate, documented cosmetic
    divergence, see test_geometry_diff). Silk correctness is earned separately
    against real footprints that carry real silk graphics (silk-text 019f77fd6d69;
    coverage audit 019f77fd9c6c), not by pinning to this synthetic golden.
    """
    prov = _prov()
    usable, reason = correctness_oracle_status(prov, SPIKE_ID)
    if not usable:  # skips while re-cut-but-unblessed; live once re-blessed
        pytest.skip(f"spike golden not usable as correctness oracle: {reason}")

    current = parse_output_set(build_fab(SPIKE_BOARD, "board"))
    golden = parse_output_set(load_output_dir(SPIKE_GOLDEN_DIR))
    diff = diff_geometry(current, golden).excluding_layers("F_SilkS")
    assert diff.is_empty, (
        "PRODUCTION emitter output does not match the BLESSED correctness golden on "
        "the fabrication-critical layers (copper/mask/drill/edge):\n" + diff.describe()
    )
