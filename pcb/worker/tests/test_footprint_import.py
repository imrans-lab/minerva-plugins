"""Arbitrary-source import (B4, docket 019ff568b56b) — where imported bytes land.

The Go side reads the bytes (network, git and zip are all Go-only in this
plugin; internal/libraries/import_test.go owns that half hermetically, including
the git-from-a-local-repo flow). This worker method is everything that happens
after, and TWO tests, deliberately few and wide (epoch rule), carry the two
properties it has to have:

1. THE WHOLE JOURNEY of an imported part, which is the tail of the same flow the
   Go test starts: import → the ref is NOT resolvable → report → a HUMAN bless →
   resolvable → promoted into the durable user layer with its provenance intact.
   One test on purpose: B4's claim is not "importing stages a file" (test_bless
   already proves staging) but that an arbitrary source lands on the FAR side of
   the bless gate and has to be walked through it by a person — which can only
   be shown by failing to resolve, then blessing, then resolving. The preserved
   ORIGINAL is checked along the way, including the thing that makes it
   insurance rather than a second library: it lives OUTSIDE the layer root, so
   no resolver can reach it, and it survives promotion.
2. THE REFUSALS, and the property they share: NOTHING is written. Notably the
   one that is not about malformed input at all — ``official_kicad`` posted
   straight at this method — because that is the only way an arbitrary source
   could reach the auto-bless tier, and the refusal is what says it cannot.

Everything runs against REAL files under ``tmp_path`` and the REAL shipped seed
library, through ``handle_request`` — the same dispatch the Go bridge calls, so
the argument names asserted here are the ones actually on the wire. The TWO_PAD
fixture is imported from test_bless so the two suites can never disagree about
what a stageable part is.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from pcb_worker import bless
from pcb_worker.footprints import USER_LAYER, WIP_LAYER
from pcb_worker.methods import handle_request

from tests.test_bless import TWO_PAD, REF, WHEN

# What the Go git importer produces for a part read out of a pinned revision:
# the provenance names the repository, the exact object id, and the path within
# it — the three things that let somebody get these bytes back.
GIT_REV = "7d1f2a9c4b6e8f0a1c3d5e7f9b0d2f4a6c8e0b13"
SOURCE_REF = f"git+https://example.invalid/vendor-lib.git@{GIT_REV}:footprints/MyLib.pretty/Part_A.kicad_mod"
LICENSE = "CC-BY-SA-4.0"
ORIGINAL_FILENAME = "Part_A.kicad_mod"

# The ref is TestLib:TWO_PAD_TEST, so this is where the original lands. Written
# out literally rather than composed: the path is a CONTRACT (a future converter
# reads it, and promotion copies it), and a literal is what notices when the
# layout changes.
ORIGINAL_REL = "originals/TestLib.pretty/TWO_PAD_TEST/Part_A.kicad_mod"


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _call(wip_root: Path, **overrides) -> dict:
    """Invoke the method exactly as the Go handler does: the seven fields the Go
    side sends, plus the host-supplied wip_root (never caller-chosen)."""
    params = {
        "ref": REF,
        "kicad_mod_text": TWO_PAD,
        "source_kind": "git",
        "source_ref": SOURCE_REF,
        "license": LICENSE,
        "fetched_sha256": _sha(TWO_PAD),
        "original_filename": ORIGINAL_FILENAME,
        "wip_root": str(wip_root),
        "retrieved_at": WHEN,
    }
    params.update(overrides)
    return handle_request({"id": "imp1", "method": "footprint_import_store",
                           "params": params})


def _tree(root: Path) -> list:
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


# ---------------------------------------------------------------------------
# 1. The whole journey: imported → unresolvable → blessed → resolvable → durable.
# ---------------------------------------------------------------------------


def test_import_stages_unblessed_and_only_a_human_makes_it_resolvable(tmp_path):
    wip_root = tmp_path / "library_wip"

    resp = _call(wip_root)
    assert resp["ok"] is True, resp
    result = resp["result"]

    assert result["ref"] == REF
    assert result["layer"] == WIP_LAYER == "wip"
    assert result["sha256"] == _sha(TWO_PAD)
    assert result["source_kind"] == "git"
    assert result["source_ref"] == SOURCE_REF
    assert result["license"] == LICENSE

    # THE DIFFERENCE FROM ACQUISITION, stated as an assertion: no bless record
    # exists, and no argument to this method could have produced one.
    assert result["bless"] is None
    assert result["entry"]["bless"] is None

    # No importer transforms anything today — the bytes are vendored verbatim —
    # so converter_version stays null rather than carrying an invented value.
    assert result["converter_version"] is None

    # The report machinery still ran: a part that cannot be rendered can never
    # be blessed, and learning that here beats learning it when a reviewer sits
    # down in front of it.
    assert result["report_summary"]["facts"]["pad_count"] == 2
    assert result["report_summary"]["facts"]["source_ref"] == SOURCE_REF

    # THE PRESERVED ORIGINAL: at the source's OWN filename (the staged copy is
    # renamed to <Part>.kicad_mod from the ref, so the source name exists
    # nowhere else), byte-identical, and recorded RELATIVE to the layer root.
    assert result["original_source_path"] == ORIGINAL_REL
    original = wip_root / ORIGINAL_REL
    assert original.read_bytes() == TWO_PAD.encode("utf-8")
    staged = bless.wip_footprint_root(wip_root) / "TestLib.pretty" / "TWO_PAD_TEST.kicad_mod"
    assert staged.read_bytes() == original.read_bytes()
    assert original.name != staged.name, (
        "the original exists to keep the SOURCE's filename, which staging drops")

    # And it is OUTSIDE the layer root, which is what makes it insurance rather
    # than a second, unpinned source of fabrication geometry: no resolver at any
    # layer can reach a path that is not under <wip_root>/footprints.
    assert bless.wip_footprint_root(wip_root) not in original.parents

    # THE GATE, uncrossed: the ref is staged, so it is NOT silently falling
    # through to a lower layer — it refuses BY NAME, saying a human has to look.
    with pytest.raises(bless.BlessError) as unblessed:
        bless.resolve_wip_footprint(REF, wip_root)
    assert REF in str(unblessed.value)

    # Only a human verdict, quoted against the artifact they actually saw, opens
    # it. (An auto-bless is refused for this source_kind by the tiering table —
    # test_bless.py owns that; what matters here is that the import left the
    # entry needing one.)
    report = bless.footprint_report(REF, wip_root=wip_root)
    entry = bless.bless_footprint(REF, wip_root, "approved", "owner", WHEN,
                                  report["artifact_sha256"])
    assert entry["bless"]["tier"] == "human"
    assert entry["bless"]["who"] == "owner"

    resolved = bless.resolve_wip_footprint(REF, wip_root)
    assert resolved.layer == "wip"
    assert len(resolved.parsed["pads"]) == 2

    # DURABILITY: promotion moves the entry whole, and the original goes with
    # it. original_source_path is layer-root-relative, so a promote that copied
    # only the footprint would leave a provenance record pointing into a WIP
    # root it had just emptied — a path that reads fine and resolves to nothing.
    user_root = tmp_path / "library_user"
    promoted = bless.promote_footprint(REF, wip_root, user_root)
    assert promoted["layer"] == USER_LAYER
    assert promoted["entry"]["original_source_path"] == ORIGINAL_REL
    assert promoted["entry"]["source_ref"] == SOURCE_REF
    assert (user_root / ORIGINAL_REL).read_bytes() == TWO_PAD.encode("utf-8")


# ---------------------------------------------------------------------------
# 2. Every refusal, and the one thing they all have in common: nothing written.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("overrides,expect_in_message", [
    # THE LOAD-BEARING ONE. official_kicad is the single source_kind that
    # auto-blesses, and this method is the only one that takes a source_kind
    # from its params at all. If posting it here worked, an arbitrary URL would
    # be one argument away from the auto tier — so it is refused by name, and
    # the refusal says where official_kicad actually comes from.
    ({"source_kind": "official_kicad"}, "not importable"),
    # The other two non-importer kinds, refused the same way: a part somebody
    # authored or generated arrives through footprint_stage, not through an
    # importer that claims it came from somewhere.
    ({"source_kind": "hand_authored"}, "not importable"),
    ({"source_kind": "generated"}, "not importable"),
    ({"source_kind": "not_a_kind"}, "not importable"),
    ({"source_kind": ""}, "source_kind is required"),
    # The original's filename becomes a path component under originals/, so it
    # is refused for the same shapes a ref is.
    ({"original_filename": "../../../../etc/passwd"}, "path separator"),
    ({"original_filename": "sub/dir.kicad_mod"}, "path separator"),
    ({"original_filename": ".."}, "path separator"),
    ({"original_filename": ""}, "original_filename is required"),
    ({"original_filename": None}, "original_filename is required"),
    # The license policy gate, restated worker-side: the Go importer refuses an
    # empty license before it reads a byte, and this refuses it again, because a
    # check that lives only on the far side of a bridge is a check this side
    # does not have.
    ({"license": ""}, "license is required"),
    # Two independent derivations of one file disagreeing: the bytes changed in
    # transit, so the lock must not be made to swear to them.
    ({"fetched_sha256": _sha(TWO_PAD + "\n; tampered\n")}, "CROSS-CHECK FAILED"),
    ({"fetched_sha256": None}, "fetched_sha256"),
    # And the shared staging refusals, which run before any write for the same
    # ordering reason. The sha travels with the text here because the
    # cross-check runs FIRST — passing it deliberately is what makes this case
    # about the parser rather than about the cross-check a second time.
    ({"kicad_mod_text": "not a footprint",
      "fetched_sha256": _sha("not a footprint")}, "s-expression"),
    ({"ref": "TestLib:../../etc/passwd"}, "path separator"),
    ({"source_ref": ""}, "source_ref is required"),
])
def test_refusals_write_nothing(tmp_path, overrides, expect_in_message):
    wip_root = tmp_path / "library_wip"
    wip_root.mkdir()

    resp = _call(wip_root, **overrides)
    assert resp["ok"] is False, resp
    assert resp["error"]["kind"] == "bless"
    assert expect_in_message in resp["error"]["message"], resp["error"]["message"]

    # The whole tree, not just the lock: a half-written original or .kicad_mod
    # with no lock entry would be invisible to a lock-only assertion, and the
    # ORDER these checks run in is what makes "nothing" true rather than a
    # cleanup path that could be forgotten.
    assert _tree(wip_root) == []
    assert not bless.wip_lock_path(wip_root).exists()
    assert REF not in (bless.load_wip_lock(wip_root).get("entries") or {})
