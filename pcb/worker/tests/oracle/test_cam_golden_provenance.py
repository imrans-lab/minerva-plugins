"""GOLDEN PROVENANCE + structural pin for the CAM Excellon/slots/IPC-356 golden
candidate `cam-excellon-ipc356-v1` (docket 019f777e9206).

Two honestly-separated concerns:

  * The CORRECTNESS-ORACLE use of the golden is GATED and SKIPS-WITH-REASON while
    EITHER (a) the golden is unblessed OR (b) no Stage-5 production consumer exists
    to compare against. It is NEVER a silent pass, and it is NEVER a coupon-vs-its-
    own-output comparison dressed up as correctness (that would be circular).

  * The STRUCTURAL / reproducibility pin is NON-gated: it proves the COMMITTED
    golden files parse cleanly through the slot + IPC-356-aware diff harness and
    still match a fresh re-emit of the ratified coupon. This is explicitly a
    drift/round-trip pin, NOT a correctness claim.

Layer-1 functional floor: the structural tests read the REAL committed golden
files and (for the reproducibility check) the REAL coupon build() output — no
synthetic in-memory stub.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

from tests.oracle.geometry_diff import (
    diff_geometry,
    diff_ipc356_files,
    parse_drill_file,
    parse_ipc356_file,
    parse_output_set,
)
from tests.oracle.provenance import (
    ProvenanceEntry,
    correctness_oracle_status,
    load_provenance,
)

HERE = Path(__file__).resolve().parent                      # pcb/worker/tests/oracle
PROV_PATH = HERE.parents[2] / "spikes" / "gerber" / "golden" / "PROVENANCE.json"
CAM_GOLDEN_DIR = HERE.parents[2] / "spikes" / "cam" / "golden"
COUPON = HERE.parents[2] / "spikes" / "cam" / "gerbonara_coupon.py"

CAM_ID = "cam-excellon-ipc356-v1"

# The correctness CONSUMER for this golden is the Stage-5 production
# Excellon/slots/IPC-356 emitter (docket 019f761fefae). It does NOT exist yet, so
# there is nothing to compare the golden against — a coupon-vs-coupon check would
# be circular. Flip to True (and wire the comparison below) when Stage 5 lands.
STAGE5_CONSUMER_ID = "019f761fefae"
STAGE5_PRODUCTION_EMITTER_AVAILABLE = False


def _prov() -> dict[str, ProvenanceEntry]:
    return load_provenance(PROV_PATH)


def _load_coupon():
    spec = importlib.util.spec_from_file_location("gerbonara_coupon", COUPON)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("gerbonara_coupon", mod)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# Registry: the candidate is registered as an UNBLESSED correctness-reference
# candidate — not self-blessed by the implementer, and honest about its caveats.
# ---------------------------------------------------------------------------


def test_cam_golden_blessed_with_recorded_caveat():
    # Blessed by the OWNER 2026-07-18 via independent gerbv confirmation of the
    # drills+slot, and a symbolic net-membership review of the IPC-356 — NOT
    # self-blessed. The IPC-356 verification CAVEAT (checked as net-membership vs
    # board.yaml, not as scalable geometry — no viewer tool exists yet) must be
    # recorded honestly, naming the missing-tool follow-up.
    prov = _prov()
    assert CAM_ID in prov, "cam golden must have a provenance entry"
    entry = prov[CAM_ID]
    assert entry.blessed is True, "cam golden was blessed by the owner"
    assert entry.role == "correctness-reference"
    assert entry.method and entry.date and entry.by, (
        "a blessed golden must record HOW/WHEN/WHO blessed it"
    )
    assert entry.path == "pcb/spikes/cam/golden"
    notes = entry.notes.upper()
    assert "CAVEAT" in notes, "the IPC-356 verification caveat must be recorded"
    assert "019F77AA012E" in notes, (
        "notes must name the IPC-356 visual-verification-tool follow-up that would "
        "close the caveat"
    )


def test_cam_golden_is_a_correctness_oracle_once_blessed():
    # Post-bless, gate (a) opens: the golden IS usable as a correctness oracle.
    # (Gate (b), the Stage-5 consumer, still defers the actual comparison — see the
    # gated test below.) The "unblessed -> not an oracle" invariant keeps live
    # coverage via the permanently-unblessed emitter snapshot in test_provenance.py.
    usable, reason = correctness_oracle_status(_prov(), CAM_ID)
    assert usable is True
    assert reason == ""


# ---------------------------------------------------------------------------
# GATED correctness-oracle use — skips-with-reason, never a silent (or circular)
# pass.
# ---------------------------------------------------------------------------


def test_cam_golden_correctness_oracle_is_gated():
    """Use the golden as a real CORRECTNESS oracle ONLY when both preconditions
    hold; otherwise skip-with-reason. Two independent gates:

      (a) the golden must be BLESSED (owner confirmed it in gerbv + IPC-356 review);
      (b) a production consumer (Stage-5 emitter 019f761fefae) must EXIST to compare
          against — comparing the coupon to its own output would be circular.
    """
    prov = _prov()
    usable, reason = correctness_oracle_status(prov, CAM_ID)
    if not usable:
        pytest.skip(f"cam golden not usable as correctness oracle: {reason}")
    if not STAGE5_PRODUCTION_EMITTER_AVAILABLE:
        pytest.skip(
            f"no production consumer yet: Stage-5 emitter {STAGE5_CONSUMER_ID} does "
            f"not exist — a coupon-vs-its-own-output comparison would be circular, "
            f"so the correctness assertion is deferred (honest skip, not a pass)"
        )
    # Both gates open: assert the PRODUCTION emitter's Excellon/slots/IPC-356
    # output matches this blessed golden. Not wired yet because the consumer does
    # not exist; fail loudly so it cannot silently pass before the real
    # comparison is implemented (forcing function, like an xfail(strict) flip).
    pytest.fail(
        "cam golden is blessed AND a Stage-5 consumer is flagged available, but the "
        "production-emitter-vs-golden comparison is not wired — implement it here "
        "instead of leaving a stub"
    )


# ---------------------------------------------------------------------------
# NON-gated STRUCTURAL / reproducibility pin — proves the COMMITTED golden parses
# through the slot + IPC-356-aware harness. NOT a correctness claim.
# ---------------------------------------------------------------------------


def test_committed_golden_files_exist():
    for name in ("board-PTH.drl", "board-NPTH.drl", "board.ipc356"):
        assert (CAM_GOLDEN_DIR / name).is_file(), f"missing committed golden file {name}"


def test_committed_golden_drills_parse_and_carry_slot():
    """The committed PTH file parses through the (slot-aware) drill harness: the
    routed slot appears as its own key and coexists with point drills."""
    pth = (CAM_GOLDEN_DIR / "board-PTH.drl").read_text(encoding="utf-8")
    hits = parse_drill_file(pth, "board-PTH.drl")
    slots = [k for k in hits if k and k[0] == "slot"]
    points = [k for k in hits if k and k[0] != "slot"]
    assert slots, f"committed golden PTH must carry a routed slot, got {list(hits)}"
    assert points and all(len(k) == 3 and isinstance(k[0], float) for k in points)


def test_committed_golden_roundtrips_cleanly_through_diff():
    """The committed golden diffed against itself -> empty delta (structural pin,
    NOT a correctness assertion). NOTE: drill-to-copper registration is NOT checked
    here — this golden deliberately excludes the copper layers (they are the
    blessed spike-gerber-v1 golden), so there is no copper for plated holes to
    register against; registration is verified over there."""
    files = {f.name: f.read_text(encoding="utf-8")
             for f in CAM_GOLDEN_DIR.iterdir() if f.suffix in (".gbr", ".drl")}
    og = parse_output_set(files)
    assert diff_geometry(og, og).is_empty

    ipc = (CAM_GOLDEN_DIR / "board.ipc356").read_text(encoding="utf-8")
    assert diff_ipc356_files(ipc, ipc).is_empty


def test_committed_golden_ipc356_has_expected_nets():
    """Structural sanity: the committed netlist round-trips its 4 records with the
    intended nets (a shape check, not an independent-correctness bless)."""
    recs = parse_ipc356_file((CAM_GOLDEN_DIR / "board.ipc356").read_text(encoding="utf-8"))
    assert sum(recs.values()) == 4
    assert {"VCC", "GND"} <= {k[1] for k in recs}


def test_committed_golden_matches_fresh_coupon_reemit():
    """Reproducibility drift pin: the committed golden is byte-identical to a fresh
    re-emit of the ratified coupon (gerbonara has no timestamp). Catches a stale
    committed golden. Explicitly a drift pin — same code path, so NOT correctness."""
    fresh = _load_coupon().build()
    for name in ("board-PTH.drl", "board-NPTH.drl", "board.ipc356"):
        committed = (CAM_GOLDEN_DIR / name).read_text(encoding="utf-8")
        assert committed == fresh[name], (
            f"committed golden {name} is STALE vs a fresh coupon re-emit — "
            f"regenerate via spikes/cam/emit_golden.py"
        )
