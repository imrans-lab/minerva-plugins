"""Rendered bless (S3/B2, docket 019ff5687b99) — the library trust boundary.

Deliberately few and wide (epoch LIB1 rule) — three original properties plus
the Codex 1160 repair round (artifact binding, mask discriminability, raw-WIP
injection). The originals:

1. THE WHOLE FLOW — stage a hand-authored part, report it, prove it CANNOT
   resolve while unblessed, bless it, prove it now resolves from the wip layer
   with the staged geometry. This is one test on purpose: the claim is not
   "staging works" or "blessing works" but that the GATE sits between them, and
   a gate can only be tested by crossing it.
2. TIERING + REFUSALS — the auto/human split in both directions, a recorded
   REJECTION that keeps the ref unresolvable, and the two refusals that must
   leave the filesystem untouched (unparseable text, missing provenance).
3. FACT-TABLE GOLDEN — the exact fact table for a real SEED part (R_0805),
   pinned against the known .kicad_mod geometry, plus the honesty invariant
   (``not_rendered`` empty ⇒ the picture is complete).

Everything runs against REAL files under ``tmp_path`` and the REAL shipped seed
library, through the public API only — the gate this guards is a property of
the whole resolution path, and a test that reached into the resolver's internals
would prove nothing about what a compile actually does.

NOTE ON THE SVG: no test pins ``svg_sha256`` to a literal. The render is
expected to evolve (colours, ordering, added layers) and pinning its bytes would
turn every cosmetic improvement into a golden re-bless. What IS pinned is the
sha's ROLE: the value a bless record stores must equal the value the report
produces for the same footprint at that moment (test 1).
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from pcb_worker import bless
from pcb_worker.footprints import (
    LOCK_SCHEMA_VERSION,
    WIP_LAYER,
    FootprintLookupError,
    sha256_file,
)

# A two-pad SMD part with a courtyard drawn as four fp_lines and one silk line.
# Deliberately NO fp_poly/fp_rect: a polygon carries an honest
# "polygon_fill_unknown" marker (the parser drops KiCad's (fill …) token), and
# this fixture exists to exercise the case where not_rendered is EMPTY.
TWO_PAD = """\
(footprint "TWO_PAD_TEST" (version 20221018) (generator pcb_worker_test)
  (layer "F.Cu")
  (fp_line (start -2 -1) (end 2 -1) (layer "F.CrtYd") (width 0.05))
  (fp_line (start 2 -1) (end 2 1) (layer "F.CrtYd") (width 0.05))
  (fp_line (start 2 1) (end -2 1) (layer "F.CrtYd") (width 0.05))
  (fp_line (start -2 1) (end -2 -1) (layer "F.CrtYd") (width 0.05))
  (fp_line (start -0.5 -0.8) (end 0.5 -0.8) (layer "F.SilkS") (width 0.12))
  (pad "1" smd rect (at -1 0) (size 1.2 1.6) (layers "F.Cu" "F.Paste" "F.Mask"))
  (pad "2" smd rect (at 1 0) (size 1.2 1.6) (layers "F.Cu" "F.Paste" "F.Mask"))
)
"""

REF = "TestLib:TWO_PAD_TEST"
WHEN = "2026-08-12T00:00:00Z"


def _stage(wip_root: Path, ref: str = REF, *, source_kind: str = "hand_authored",
           text: str = TWO_PAD) -> dict:
    return bless.stage_footprint(
        ref, text, wip_root,
        source_kind=source_kind,
        source_ref="authored for worker/tests/test_bless.py",
        license="LicenseRef-TurnRock-Proprietary",
        retrieved_at="2026-08-12",
    )


def _snapshot(root: Path) -> tuple:
    """Every file under *root* plus the WIP lock's exact bytes — the pair a
    refusal must leave unchanged."""
    files = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
    lock = bless.wip_lock_path(root)
    return files, (lock.read_text(encoding="utf-8") if lock.exists() else None)


# ---------------------------------------------------------------------------
# 1. The whole flow, and the gate in the middle of it.
# ---------------------------------------------------------------------------


def test_stage_report_bless_resolve_flow(tmp_path):
    wip = tmp_path / "library_wip"

    # --- STAGE ------------------------------------------------------------
    entry = _stage(wip)
    staged_file = wip / "footprints" / "TestLib.pretty" / "TWO_PAD_TEST.kicad_mod"
    assert staged_file.is_file()
    assert staged_file.read_text(encoding="utf-8") == TWO_PAD
    assert entry["path"] == "TestLib.pretty/TWO_PAD_TEST.kicad_mod"
    assert entry["sha256"] == sha256_file(staged_file)
    assert entry["size_bytes"] == staged_file.stat().st_size
    assert entry["layer"] == WIP_LAYER
    assert entry["source_kind"] == "hand_authored"
    # Staging is ACQUISITION, never approval.
    assert entry["bless"] is None
    doc = json.loads(bless.wip_lock_path(wip).read_text(encoding="utf-8"))
    assert doc["schema_version"] == LOCK_SCHEMA_VERSION
    assert set(doc["entries"]) == {REF}

    # --- REPORT (the one path that may see unblessed content) -------------
    report = bless.footprint_report(REF, wip_root=wip)
    facts = report["facts"]
    assert facts["footprint_name"] == "TWO_PAD_TEST"
    assert facts["layer"] == WIP_LAYER
    assert facts["pad_count"] == 2
    assert facts["pad_numbers"] == ["1", "2"]
    assert [(p["x_mm"], p["y_mm"], p["size"]) for p in facts["pads"]] == [
        (-1.0, 0.0, [1.2, 1.6]),
        (1.0, 0.0, [1.2, 1.6]),
    ]
    assert facts["courtyard_bbox"] == {
        "min_x_mm": -2.0, "min_y_mm": -1.0, "max_x_mm": 2.0, "max_y_mm": 1.0,
        "width_mm": 4.0, "height_mm": 2.0,
    }
    # Both pads are actually IN the picture, not merely in the table.
    assert 'data-pad="1"' in report["svg"]
    assert 'data-pad="2"' in report["svg"]
    assert report["svg"].startswith("<svg ") and report["svg"].rstrip().endswith("</svg>")
    # THE HONESTY INVARIANT: an empty not_rendered is the claim "this picture is
    # complete", which is the only condition under which comparing it to a
    # datasheet checks the whole part.
    assert report["not_rendered"] == []
    assert re.fullmatch(r"[0-9a-f]{64}", report["svg_sha256"])

    # --- THE GATE: unblessed cannot resolve, by two independent mechanisms --
    # (a) structural: the ref is not even a KEY of the resolving lock view, so
    #     no resolver branch exists that could serve it.
    assert bless.blessed_wip_layer(wip).lock == {}
    with pytest.raises(FootprintLookupError):
        bless.footprint_report(REF, chain=bless.blessed_library_chain(wip))
    # (b) attributed: this module's own resolve entry point names the state.
    with pytest.raises(bless.BlessError) as excinfo:
        bless.resolve_wip_footprint(REF, wip)
    message = str(excinfo.value)
    assert "STAGED BUT NOT BLESSED" in message
    assert REF in message

    # --- BLESS: the verdict quotes the reviewed artifact back (Codex 1160 P1)
    blessed = bless.bless_footprint(REF, wip, "approved", "owner", WHEN,
                                    report["artifact_sha256"])
    record = blessed["bless"]
    assert record["tier"] == bless.TIER_HUMAN
    assert record["verdict"] == "approved"
    assert record["who"] == "owner"
    assert record["blessed_at"] == WHEN
    # The record pins the artifact the reviewer actually looked at — the full
    # binding digest (content sha + facts + not_rendered + picture), plus the
    # staged bytes' own sha for legibility.
    assert record["artifact_sha256"] == report["artifact_sha256"]
    assert record["content_sha256"] == entry["sha256"]
    assert bless.is_blessed(blessed)

    # --- RESOLVE ------------------------------------------------------------
    resolved = bless.resolve_wip_footprint(REF, wip)
    assert resolved.layer == WIP_LAYER
    assert resolved.path == staged_file
    assert [(p["number"], p["x_mm"], p["y_mm"], p["size"])
            for p in resolved.parsed["pads"]] == [
        ("1", -1.0, 0.0, [1.2, 1.6]),
        ("2", 1.0, 0.0, [1.2, 1.6]),
    ]
    # And it is now visible to ANY resolver walking the blessed chain, not just
    # to this module's entry point.
    assert set(bless.blessed_wip_layer(wip).lock) == {REF}


# ---------------------------------------------------------------------------
# 2. Tiering, and every refusal that must leave the tree untouched.
# ---------------------------------------------------------------------------


def test_tiering_and_refusals(tmp_path):
    wip = tmp_path / "library_wip"

    # --- official_kicad AUTO-BLESSES, and refuses a manual verdict ---------
    official = "Official:TWO_PAD_TEST"
    _stage(wip, official, source_kind="official_kicad")
    with pytest.raises(bless.BlessError) as excinfo:
        # The tier refusal fires on provenance, before the artifact binding is
        # even consulted — a well-formed but irrelevant digest proves that.
        bless.bless_footprint(official, wip, "approved", "owner", WHEN, "0" * 64)
    assert "AUTO-BLESSES" in str(excinfo.value)
    # …and nothing was recorded by the refused call.
    assert not bless.is_blessed(bless.load_wip_lock(wip)["entries"][official])

    auto = bless.auto_bless_footprint(official, wip, WHEN)
    assert auto["bless"]["tier"] == bless.TIER_AUTO
    assert auto["bless"]["verdict"] == "approved"
    # The lock never carries a human's name against a decision no human made.
    assert auto["bless"]["who"] == bless.AUTO_BLESS_ATTRIBUTION
    assert auto["bless"]["artifact_sha256"]
    assert bless.resolve_wip_footprint(official, wip).layer == WIP_LAYER

    # --- the mirror refusal: hand_authored cannot take the auto path -------
    hand = "Hand:TWO_PAD_TEST"
    _stage(wip, hand, source_kind="hand_authored")
    with pytest.raises(bless.BlessError) as excinfo:
        bless.auto_bless_footprint(hand, wip, WHEN)
    assert "hand_authored" in str(excinfo.value)
    assert "human" in str(excinfo.value)

    # --- a REJECTED verdict is recorded and keeps the ref unresolvable -----
    hand_report = bless.footprint_report(hand, wip_root=wip)
    rejected_entry = bless.bless_footprint(hand, wip, "rejected", "owner", WHEN,
                                           hand_report["artifact_sha256"])
    assert rejected_entry["bless"]["verdict"] == "rejected"
    assert not bless.is_blessed(rejected_entry)
    assert hand not in bless.blessed_wip_layer(wip).lock
    with pytest.raises(bless.BlessError) as excinfo:
        bless.resolve_wip_footprint(hand, wip)
    assert "REJECTED" in str(excinfo.value)

    # --- unparseable text writes NOTHING -----------------------------------
    # Order is the contract: validation precedes every filesystem touch, so
    # "nothing was written" is structural rather than a cleanup path that could
    # itself fail. Snapshot both the file tree AND the lock bytes.
    before = _snapshot(wip)
    for bad_text in (
        "this is not a footprint",                       # not an s-expression
        '(module "X" (pad "1" smd rect (at 0 0)',        # truncated / unbalanced
        '(kicad_pcb (version 20221018))',                # wrong root node
        '(footprint "NOPADS" (layer "F.Cu"))',           # parses, but no pads
    ):
        with pytest.raises(bless.BlessError):
            _stage(wip, "Bad:PART", text=bad_text)
    assert _snapshot(wip) == before
    assert "Bad:PART" not in bless.load_wip_lock(wip)["entries"]

    # --- empty / unknown provenance refuses, also without writing ----------
    for kwargs in (
        {"source_kind": ""},
        {"source_kind": "   "},
        {"source_kind": "downloaded_from_a_forum"},  # outside LOCK_SOURCE_KINDS
        {"license": ""},
        {"source_ref": ""},
        {"retrieved_at": ""},
    ):
        args = {"source_kind": "hand_authored", "source_ref": "x",
                "license": "MIT", "retrieved_at": "2026-08-12"}
        args.update(kwargs)
        with pytest.raises(bless.BlessError):
            bless.stage_footprint("Bad:PART2", TWO_PAD, wip, **args)
    assert _snapshot(wip) == before

    # --- a ref that would escape the WIP root is refused -------------------
    for bad_ref in ("no_colon", "Lib:", ":Part", "a:b:c", "../evil:Part",
                    "Lib:../../evil"):
        with pytest.raises(bless.BlessError):
            _stage(wip, bad_ref)
    assert _snapshot(wip) == before


# ---------------------------------------------------------------------------
# 3. The fact-table golden for a real shipped part.
# ---------------------------------------------------------------------------


def test_fact_table_golden_for_seed_r_0805():
    """The exact fact table for the shipped ``R_0805``.

    Hand-derived from the vendored
    ``library/footprints/Resistor_SMD.pretty/R_0805_2012Metric.kicad_mod``: two
    smd rect pads 1×1.45 mm at x=∓0.95, and a four-line F.CrtYd rectangle
    spanning ∓1.68 × ∓0.95. Nothing here is captured from the implementation —
    if this fails, either the seed file changed (the pin is doing its job and
    the literals below must be re-derived from the NEW file) or the fact table
    stopped agreeing with the .kicad_mod, which is the defect a fact table
    exists to make impossible.

    ``courtyard_bbox`` is CENTRELINE geometry: no half-stroke is added, so the
    numbers a reviewer reads here are the numbers the file states.
    """
    report = bless.footprint_report("R_0805")

    assert report["facts"] == {
        "ref": "R_0805",
        "footprint_name": "R_0805_2012Metric",
        "layer": "seed",
        "source_kind": "generated",
        "license": "LicenseRef-TurnRock-Proprietary",
        "source_ref": "pcb_worker_seed synthesizer (baae81a 2026-07-18)",
        "pad_count": 2,
        "pad_numbers": ["1", "2"],
        "pads": [
            {"number": "1", "type": "smd", "shape": "rect",
             "x_mm": -0.95, "y_mm": 0.0, "size": [1.0, 1.45], "drill": None,
             "drill_shape": None, "drill_size": None,
             "layers": ["F.Cu", "F.Paste", "F.Mask"], "rotation": None,
             "roundrect_rratio": None, "solder_mask_margin": None,
             "solder_paste_margin": None},
            {"number": "2", "type": "smd", "shape": "rect",
             "x_mm": 0.95, "y_mm": 0.0, "size": [1.0, 1.45], "drill": None,
             "drill_shape": None, "drill_size": None,
             "layers": ["F.Cu", "F.Paste", "F.Mask"], "rotation": None,
             "roundrect_rratio": None, "solder_mask_margin": None,
             "solder_paste_margin": None},
        ],
        "courtyard_bbox": {
            "min_x_mm": -1.68, "min_y_mm": -0.95,
            "max_x_mm": 1.68, "max_y_mm": 0.95,
            "width_mm": 3.36, "height_mm": 1.9,
        },
        # The seed R_0805 carries no F.Fab geometry, so there is no body
        # outline to report. None, never an invented box.
        "body_bbox": None,
        # Package/assembly identity from the lock entry — nulls today, but the
        # ROW is part of the report contract (Codex 1160 P1).
        "assembly": {"dist_part_numbers": [], "mpn": None,
                     "orientation_convention": None, "package": None},
    }

    # A simple two-pad chip part is entirely within what the renderer models,
    # so the picture is COMPLETE. (svg_sha256 is deliberately not pinned — see
    # the module docstring.)
    assert report["not_rendered"] == []
    assert re.fullmatch(r"[0-9a-f]{64}", report["svg_sha256"])
    assert 'data-pad="1"' in report["svg"] and 'data-pad="2"' in report["svg"]


# ---------------------------------------------------------------------------
# 4. The approval binds to the artifact the reviewer saw (Codex 1160 P1).
# ---------------------------------------------------------------------------

# Revision B of the same part: pad 1 moved 0.2mm. Visually near-identical —
# exactly the change a binding-free bless would silently approve.
TWO_PAD_MOVED = TWO_PAD.replace('(at -1 0)', '(at -1.2 0)')

# The same part with ONE fab-affecting difference the picture cannot show: a
# negative mask margin on pad 1 (the Codex 1160 P1 mask scenario).
TWO_PAD_MASKED = TWO_PAD.replace(
    '(pad "1" smd rect (at -1 0) (size 1.2 1.6) (layers "F.Cu" "F.Paste" "F.Mask"))',
    '(pad "1" smd rect (at -1 0) (size 1.2 1.6) (layers "F.Cu" "F.Paste" "F.Mask") '
    '(solder_mask_margin -0.49))')


def test_bless_refuses_when_staged_content_changed_after_review(tmp_path):
    """report(A) → re-stage(B) → bless(expected=A) must refuse, leaving B
    unblessed — an approval never transfers to an artifact nobody reviewed."""
    wip = tmp_path / "library_wip"
    _stage(wip)
    reviewed = bless.footprint_report(REF, wip_root=wip)          # revision A

    _stage(wip, text=TWO_PAD_MOVED)                               # revision B
    with pytest.raises(bless.BlessError) as excinfo:
        bless.bless_footprint(REF, wip, "approved", "owner", WHEN,
                              reviewed["artifact_sha256"])
    msg = str(excinfo.value)
    assert REF in msg and "changed since" in msg
    assert not bless.is_blessed(bless.load_wip_lock(wip)["entries"][REF])
    assert REF not in bless.blessed_wip_layer(wip).lock

    # Reviewing the CURRENT artifact is the way through the refusal.
    current = bless.footprint_report(REF, wip_root=wip)
    assert current["artifact_sha256"] != reviewed["artifact_sha256"]
    blessed = bless.bless_footprint(REF, wip, "approved", "owner", WHEN,
                                    current["artifact_sha256"])
    assert bless.is_blessed(blessed)
    assert blessed["bless"]["artifact_sha256"] == current["artifact_sha256"]


def test_mask_margin_changes_facts_and_honesty_list(tmp_path):
    """Two footprints differing ONLY by a solder-mask margin must be
    discriminable in the report (Codex 1160 P1): the margin is a fact row, the
    undrawn aperture is a not_rendered entry, and the artifact digests differ
    — a reviewer can no longer approve the unsafe mask from a picture and
    table identical to the safe part's."""
    plain_root = tmp_path / "wip_plain"
    masked_root = tmp_path / "wip_masked"
    _stage(plain_root)
    _stage(masked_root, text=TWO_PAD_MASKED)

    plain = bless.footprint_report(REF, wip_root=plain_root)
    masked = bless.footprint_report(REF, wip_root=masked_root)

    assert plain["facts"]["pads"][0]["solder_mask_margin"] is None
    assert masked["facts"]["pads"][0]["solder_mask_margin"] == -0.49
    assert plain["facts"] != masked["facts"]
    # The margin-carrying report may NOT claim a complete picture.
    assert plain["not_rendered"] == []
    margin_notes = [n for n in masked["not_rendered"]
                    if isinstance(n, dict) and n.get("kind") == "pad_margin_not_drawn"]
    assert [(n["pad"], n["field"], n["value"]) for n in margin_notes] == [
        ("1", "solder_mask_margin", -0.49)]
    assert plain["artifact_sha256"] != masked["artifact_sha256"]


def test_raw_wip_chain_injection_is_refused(tmp_path):
    """A hand-built WIP layer without the capability bit cannot supply a
    footprint, even through the low-level chain= parameter (Codex 1160 P1: the
    bless gate must hold by construction, not by caller convention)."""
    from pcb_worker.footprints import (
        LibraryLayer, LoadedLibraryLayer, resolve_footprint_layered,
        normalize_library_layers)
    wip = tmp_path / "library_wip"
    _stage(wip)  # staged, UNBLESSED

    raw = LoadedLibraryLayer(
        layer=LibraryLayer(name=WIP_LAYER,
                           root=bless.wip_footprint_root(wip),
                           lockfile=bless.wip_lock_path(wip)),
        lock=dict(bless.load_wip_lock(wip)["entries"]))
    with pytest.raises(FootprintLookupError) as excinfo:
        resolve_footprint_layered(REF, chain=(raw,))
    assert "UNAUTHORIZED wip" in str(excinfo.value)

    # And the data-driven doorway refuses the NAME outright, so a plain dict
    # can never carry staged content into a compile's layer configuration.
    with pytest.raises(FootprintLookupError) as excinfo:
        normalize_library_layers([{"name": "wip",
                                   "root": str(bless.wip_footprint_root(wip)),
                                   "lockfile": str(bless.wip_lock_path(wip))}])
    assert "blessed_library_chain" in str(excinfo.value)
