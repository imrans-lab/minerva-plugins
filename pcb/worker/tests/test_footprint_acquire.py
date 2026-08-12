"""Acquisition storage (S4/B3, docket 019ff5689732) — where a fetched official
footprint lands.

The Go side fetches the bytes (network code is Go-only in this plugin); this
worker method is everything that happens after. TWO tests, deliberately few and
wide (epoch LIB1 rule), one per property the method has to have:

1. THE WHOLE STORE — one call stages, auto-blesses, and leaves the ref RESOLVING
   from the wip layer at tier "auto". This is one test on purpose: the method's
   claim is not "staging works" (test_bless.py already proves that) but that a
   single call crosses the gate, which can only be shown by resolving the ref
   afterwards. It also pins the thing that makes the auto-bless safe: the
   source_kind is fixed by the method, so a caller passing one is IGNORED rather
   than obeyed.
2. THE CROSS-CHECK — the sha the fetcher reported and the sha of the text that
   arrived are two independent derivations of one file, and a disagreement
   refuses with NOTHING written. That "nothing" is checked against the whole
   directory tree, not just the lock, because a half-staged file with no lock
   entry would be invisible to a lock-only assertion.

Everything runs against REAL files under ``tmp_path`` and the REAL shipped seed
library, through ``handle_request`` — the same dispatch the Go bridge calls, so
the argument names asserted here are the ones actually on the wire.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from pcb_worker import bless
from pcb_worker.footprints import WIP_LAYER
from pcb_worker.methods import handle_request

# A real-shaped two-pad SMD part: what gitlab.com would serve for this ref.
KICAD_MOD = """\
(footprint "R_0402_1005Metric" (version 20221018) (generator pcb_worker_test)
  (layer "F.Cu")
  (fp_line (start -0.93 -0.47) (end 0.93 -0.47) (layer "F.CrtYd") (width 0.05))
  (fp_line (start 0.93 -0.47) (end 0.93 0.47) (layer "F.CrtYd") (width 0.05))
  (fp_line (start 0.93 0.47) (end -0.93 0.47) (layer "F.CrtYd") (width 0.05))
  (fp_line (start -0.93 0.47) (end -0.93 -0.47) (layer "F.CrtYd") (width 0.05))
  (pad "1" smd roundrect (at -0.51 0) (size 0.54 0.64) (layers "F.Cu" "F.Paste" "F.Mask"))
  (pad "2" smd roundrect (at 0.51 0) (size 0.54 0.64) (layers "F.Cu" "F.Paste" "F.Mask"))
)
"""

REF = "Resistor_SMD:R_0402_1005Metric_ACQ_TEST"
TAG = "9.0.9.1"
SOURCE_REF = f"kicad-footprints@{TAG}/Resistor_SMD.pretty/R_0402_1005Metric_ACQ_TEST.kicad_mod"
LICENSE = "CC-BY-SA-4.0 WITH KiCad-libraries-exception"
WHEN = "2026-08-12T00:00:00Z"


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _call(wip_root: Path, **overrides) -> dict:
    """Invoke the method exactly as the Go handler does: the five fields the Go
    side sends, plus the host-supplied wip_root (never caller-chosen)."""
    params = {
        "ref": REF,
        "kicad_mod_text": KICAD_MOD,
        "source_ref": SOURCE_REF,
        "license": LICENSE,
        "fetched_sha256": _sha(KICAD_MOD),
        "wip_root": str(wip_root),
        "retrieved_at": WHEN,
        "blessed_at": WHEN,
    }
    params.update(overrides)
    return handle_request({"id": "acq1", "method": "footprint_acquire_store",
                           "params": params})


def _tree(root: Path) -> list:
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


# ---------------------------------------------------------------------------
# 1. One call: stage + auto-bless, and the ref resolves afterwards.
# ---------------------------------------------------------------------------


def test_acquire_store_stages_auto_blesses_and_resolves(tmp_path):
    wip_root = tmp_path / "library_wip"

    # A caller that tries to choose its own provenance is IGNORED, not obeyed:
    # this method exists to store bytes fetched from the pinned OFFICIAL release,
    # and honouring a source_kind would make it a general auto-bless doorway.
    resp = _call(wip_root, source_kind="hand_authored")
    assert resp["ok"] is True, resp
    result = resp["result"]

    assert result["ref"] == REF
    assert result["layer"] == WIP_LAYER == "wip"
    assert result["sha256"] == _sha(KICAD_MOD)
    assert result["source_ref"] == SOURCE_REF
    assert result["license"] == LICENSE
    assert result["entry"]["source_kind"] == "official_kicad"

    # Auto tier, approved, attributed to policy rather than to a human — the
    # lock must never carry a person's name against a decision no person made.
    blessed = result["bless"]
    assert blessed["tier"] == "auto"
    assert blessed["verdict"] == "approved"
    assert blessed["who"] == bless.AUTO_BLESS_ATTRIBUTION
    assert blessed["blessed_at"] == WHEN
    # The record pins the full binding digest (content sha + facts +
    # not_rendered + picture), not the svg sha alone (Codex 1160 P1).
    assert blessed["artifact_sha256"] == result["report_summary"]["artifact_sha256"]
    assert blessed["artifact_sha256"] != result["report_summary"]["svg_sha256"]

    # The report machinery ran: the fact table describes the part that was stored.
    facts = result["report_summary"]["facts"]
    assert facts["pad_count"] == 2
    assert facts["pad_numbers"] == ["1", "2"]
    assert facts["layer"] == "wip"
    assert facts["source_ref"] == SOURCE_REF

    # THE GATE, crossed: the ref resolves from the wip layer through the BLESSED
    # chain. This is the whole point of fusing stage and bless into one call —
    # the caller is never left holding an unresolvable entry.
    resolved = bless.resolve_wip_footprint(REF, wip_root)
    assert resolved.layer == "wip"
    assert len(resolved.parsed["pads"]) == 2
    assert bless.is_blessed(bless.load_wip_lock(wip_root)["entries"][REF])

    # Idempotent in the way that matters: re-acquiring the same bytes lands the
    # same sha and the same blessed state (re-staging resets bless to null, and
    # this method re-blesses in the same call, so there is no window where a
    # previously-usable part becomes unusable).
    again = _call(wip_root)
    assert again["ok"] is True, again
    assert again["result"]["sha256"] == result["sha256"]
    assert again["result"]["bless"]["verdict"] == "approved"


# ---------------------------------------------------------------------------
# 2. The cross-check: two derivations of one file must agree.
# ---------------------------------------------------------------------------


def test_sha_mismatch_refuses_and_writes_nothing(tmp_path):
    wip_root = tmp_path / "library_wip"
    wip_root.mkdir()

    # The fetcher reported a sha for the bytes it downloaded; the text that
    # arrived hashes to something else. Either the transfer corrupted it or the
    # two sides are looking at different files — both mean the lock must not be
    # made to swear to bytes nobody served.
    resp = _call(wip_root, fetched_sha256=_sha(KICAD_MOD + "\n; tampered\n"))
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "bless"
    assert "CROSS-CHECK FAILED" in resp["error"]["message"]

    assert _tree(wip_root) == [], (
        "a cross-check failure must write NOTHING — not the .kicad_mod, not the "
        "lock; the check runs before staging precisely so this is a consequence "
        "of the order rather than of a cleanup path")
    assert not bless.wip_lock_path(wip_root).exists()

    # A missing sha is refused the same way: acquisition without a reported hash
    # has no second derivation to compare against, which is the entire control.
    missing = _call(wip_root, fetched_sha256=None)
    assert missing["ok"] is False
    assert missing["error"]["kind"] == "bless"
    assert "fetched_sha256" in missing["error"]["message"]
    assert _tree(wip_root) == []

    # And the ref stays unresolvable: nothing was staged, so nothing shadows a
    # lower layer's part.
    entries = bless.load_wip_lock(wip_root).get("entries") or {}
    assert REF not in entries
