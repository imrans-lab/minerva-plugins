"""Promotion out of WIP + the live layer chain (B7, docket 019ff7c02fd6).

Deliberately few and wide (epoch rule) — two tests:

1. THE WHOLE JOURNEY a real override takes: stage a hand-authored part, bless
   it against its rendered artifact, PROMOTE it into the user layer, then prove
   the part resolves from ``user`` through the SAME live chain every
   compile-bearing worker method now builds from its host-injected params
   (``wip_root`` + ``library_layers`` → ``bless.live_library_chain`` →
   ``resolve.resolve_board``). One test on purpose: B7's claim is not "promote
   moves files" but that a blessed part SURVIVES its staging slot — visible to
   a live resolve before promotion (wip), after promotion (user), and after the
   WIP layer is gone entirely (durability).
2. EVERY promote refusal, and the property they share: nothing on EITHER side
   changes. Unstaged, unblessed, rejected, disk-vs-lock sha drift, an existing
   destination entry without overwrite (then WITH it), and a v1 destination
   lock — each refusal leaves both trees byte-identical.

Everything runs against REAL files under ``tmp_path`` through the public API,
same discipline as worker/tests/test_bless.py (whose TWO_PAD fixture this
reuses so the two suites can never disagree about what a stageable part is).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pcb_worker import bless, resolve
from pcb_worker.footprints import (
    LOCK_SCHEMA_VERSION,
    USER_LAYER,
    FootprintLookupError,
    sha256_file,
)

from tests.test_bless import REF, WHEN, _snapshot, _stage


def _user_layer_mapping(user_root: Path) -> dict:
    """The user layer EXACTLY as the Go broker's withLibraryChain injects it:
    a plain mapping (the bridge form normalize_library_layers documents), root
    at <user_root>/footprints, lock at <user_root>/footprints.lock.json."""
    return {
        "name": USER_LAYER,
        "root": str(user_root / "footprints"),
        "lockfile": str(user_root / "footprints.lock.json"),
    }


def _stage_and_bless(wip: Path, ref: str = REF) -> dict:
    _stage(wip, ref)
    report = bless.footprint_report(ref, wip_root=wip)
    return bless.bless_footprint(ref, wip, "approved", "owner", WHEN,
                                 report["artifact_sha256"])


# A one-component board whose declared pins coincide exactly with TWO_PAD's
# pads (±1, 0) — the strict resolve path proves the LIVE footprint supplied
# the geometry, and the coincidence guard proves it is the RIGHT geometry.
def _board_using(ref: str) -> dict:
    return {
        "name": "b7-live-chain",
        "components": [{
            "ref": "D1",
            "footprint": ref,
            "pins": [
                {"number": "1", "x_mm": -1.0, "y_mm": 0.0},
                {"number": "2", "x_mm": 1.0, "y_mm": 0.0},
            ],
        }],
    }


def test_promote_flow_and_live_chain(tmp_path):
    wip = tmp_path / "library_wip"
    user = tmp_path / "library_user"

    _stage_and_bless(wip)
    staged_file = wip / "footprints" / "TestLib.pretty" / "TWO_PAD_TEST.kicad_mod"
    staged_sha = sha256_file(staged_file)

    # --- BEFORE promotion: the live chain serves the ref from WIP ----------
    # (the user layer does not exist yet, exactly the state withLibraryChain
    # injects as library_layers=[] — an absent layer is decided host-side).
    before = resolve.resolve_board(_board_using(REF), wip_root=str(wip))
    comp = before["components"][0]
    assert comp["has_pad_geometry"] is True
    assert {(p["number"]) for p in comp["pads"]} == {"1", "2"}

    # --- PROMOTE -----------------------------------------------------------
    result = bless.promote_footprint(REF, wip, user)
    assert result["ref"] == REF
    assert result["layer"] == USER_LAYER

    dest_file = user / "footprints" / "TestLib.pretty" / "TWO_PAD_TEST.kicad_mod"
    assert dest_file.is_file()
    assert sha256_file(dest_file) == staged_sha
    dest_doc = json.loads((user / "footprints.lock.json").read_text(encoding="utf-8"))
    assert dest_doc["schema_version"] == LOCK_SCHEMA_VERSION
    promoted = dest_doc["entries"][REF]
    # The entry moved WHOLE: the bless record that approved these bytes is the
    # thing promotion durably records, with only the layer name rewritten.
    assert promoted["layer"] == USER_LAYER
    assert promoted["sha256"] == staged_sha
    assert promoted["bless"]["verdict"] == "approved"
    assert promoted["bless"]["who"] == "owner"
    assert promoted["bless"]["content_sha256"] == staged_sha
    # The staging slot is FREE: entry gone from the WIP lock, file gone.
    assert REF not in (bless.load_wip_lock(wip).get("entries") or {})
    assert not staged_file.exists()

    # --- AFTER promotion: the SAME live-chain call now serves it from user --
    layers = [_user_layer_mapping(user)]
    after = resolve.resolve_board(_board_using(REF), wip_root=str(wip),
                                  library_layers=layers)
    comp = after["components"][0]
    assert comp["has_pad_geometry"] is True
    assert [(p["number"], p["position"]["x"], p["position"]["y"])
            for p in comp["pads"]] == [("1", -1.0, 0.0), ("2", 1.0, 0.0)]
    # ...and the chain itself attributes it to the user layer, not wip.
    chain = bless.live_library_chain(wip_root=str(wip), layers=layers)
    from pcb_worker.footprints import resolve_footprint_layered
    supplied = resolve_footprint_layered(REF, chain=chain)
    assert supplied.layer == USER_LAYER
    assert supplied.path == dest_file

    # --- DURABILITY: no wip_root at all (a fresh session, staging cleared) --
    durable = bless.live_library_chain(layers=layers)
    assert resolve_footprint_layered(REF, chain=durable).layer == USER_LAYER
    # The seed-only default (no layers, no wip) does NOT know the ref — the
    # part lives in the user layer and only there.
    with pytest.raises(FootprintLookupError):
        resolve_footprint_layered(REF, chain=bless.live_library_chain())

    # --- ANTI-SHADOWING survives promotion: rot the promoted file and the
    # SAME chain refuses the ref by name instead of falling through to seed.
    dest_file.write_bytes(dest_file.read_bytes() + b"\n; rotted\n")
    with pytest.raises(FootprintLookupError) as excinfo:
        resolve_footprint_layered(REF, chain=bless.live_library_chain(layers=layers))
    assert "sha" in str(excinfo.value).lower() or "mismatch" in str(excinfo.value)


def test_promote_refusals_leave_both_libraries_untouched(tmp_path):
    wip = tmp_path / "library_wip"
    user = tmp_path / "library_user"

    def both():
        return (_snapshot(wip) if wip.exists() else None,
                _snapshot(user) if user.exists() else None)

    # --- unstaged ref -------------------------------------------------------
    with pytest.raises(bless.BlessError, match="not staged"):
        bless.promote_footprint("TestLib:NOPE", wip, user)
    assert not user.exists()

    # --- staged but never reviewed -----------------------------------------
    _stage(wip)
    frozen = both()
    with pytest.raises(bless.BlessError, match="NOT BLESSED"):
        bless.promote_footprint(REF, wip, user)
    assert both() == frozen
    assert not user.exists()

    # --- a recorded REJECTION does not promote -----------------------------
    report = bless.footprint_report(REF, wip_root=wip)
    bless.bless_footprint(REF, wip, "rejected", "owner", WHEN,
                          report["artifact_sha256"])
    frozen = both()
    with pytest.raises(bless.BlessError, match="REJECTED"):
        bless.promote_footprint(REF, wip, user)
    assert both() == frozen

    # --- blessed, but the bytes on disk drifted from the pin ---------------
    report = bless.footprint_report(REF, wip_root=wip)
    bless.bless_footprint(REF, wip, "approved", "owner", WHEN,
                          report["artifact_sha256"])
    staged_file = wip / "footprints" / "TestLib.pretty" / "TWO_PAD_TEST.kicad_mod"
    pinned = staged_file.read_bytes()
    staged_file.write_bytes(pinned + b"\n; drift\n")
    with pytest.raises(bless.BlessError, match="not the bytes that were blessed"):
        bless.promote_footprint(REF, wip, user)
    assert not user.exists()
    staged_file.write_bytes(pinned)  # restore the pinned bytes

    # --- happy promote, then: same ref again refuses without overwrite -----
    bless.promote_footprint(REF, wip, user)
    _stage(wip)  # re-stage (a NEW candidate for the same ref)
    report = bless.footprint_report(REF, wip_root=wip)
    bless.bless_footprint(REF, wip, "approved", "owner", WHEN,
                          report["artifact_sha256"])
    frozen = both()
    with pytest.raises(bless.BlessError, match="overwrite"):
        bless.promote_footprint(REF, wip, user)
    assert both() == frozen
    # ...and WITH overwrite it replaces the durable entry (a stated intention).
    result = bless.promote_footprint(REF, wip, user, overwrite=True)
    assert result["layer"] == USER_LAYER
    assert REF not in (bless.load_wip_lock(wip).get("entries") or {})

    # --- a v1 destination lock is never silently rewritten -----------------
    _stage(wip)
    report = bless.footprint_report(REF, wip_root=wip)
    bless.bless_footprint(REF, wip, "approved", "owner", WHEN,
                          report["artifact_sha256"])
    v1_user = tmp_path / "library_user_v1"
    v1_user.mkdir()
    (v1_user / "footprints.lock.json").write_text(
        json.dumps({"Some:Ref": {"path": "x", "sha256": "y"}}), encoding="utf-8")
    v1_bytes = (v1_user / "footprints.lock.json").read_bytes()
    with pytest.raises(bless.BlessError, match="schema_version"):
        bless.promote_footprint(REF, wip, v1_user)
    assert (v1_user / "footprints.lock.json").read_bytes() == v1_bytes
    assert not (v1_user / "footprints").exists()
