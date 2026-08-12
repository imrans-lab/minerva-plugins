"""pcb/scripts/gen_notice.py — the marketplace-release NOTICE gate (epoch
LIB1, DCR 019ff568e203 station S5/B6).

Few-and-wide by design (epoch LIB1 rule, matching test_library_lock.py's own
docstring): ONE test drives every release-gate violation class plus the
determinism and ``--check`` drift contracts against a synthetic tmp lock, and
ONE test pins the generator against the REAL shipped lock, so a drift between
``pcb/NOTICE.md`` and ``pcb/library/footprints.lock.json`` fails here even in
an environment (or a review pass) that skips CI's ``fab-gate`` job.

``gen_notice.py`` is a standalone script under ``pcb/scripts/``, not a
package member of ``pcb_worker`` — it is loaded by file path via
``importlib.util``, the standard way to import a script that was never meant
to be ``import``-ed by name (its own header documents WHY it lives outside
the worker package: it is the release gate, not runtime code the worker
loads).
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

# tests/ -> worker/ -> pcb/ (repo layout: pcb/worker/tests/this_file.py)
WORKER = Path(__file__).resolve().parents[1]
PCB = WORKER.parent
GEN_NOTICE_PATH = PCB / "scripts" / "gen_notice.py"


def _load_gen_notice():
    """Import gen_notice.py by file path (it is a standalone script under
    pcb/scripts/, not an importable package member — see the module's own
    header for why it lives there)."""
    spec = importlib.util.spec_from_file_location("gen_notice", GEN_NOTICE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _compliant_entry(ref_suffix: str = "", **overrides) -> dict:
    """A minimal acquisition-lock v2 entry that passes every release-gate
    axis (source_kind in vocabulary, non-empty license/source_ref). Reserved
    slots are included so a caller building a full lock document mirrors the
    shape ``load_lock_document`` hands back for a real entry, even though
    ``render_notice`` itself only reads source_kind/license/source_ref/
    provenance_note."""
    base = {
        "path": f"Fake.pretty/Fake{ref_suffix}.kicad_mod",
        "sha256": "ab" * 32,
        "size_bytes": 100,
        "source_kind": "hand_authored",
        "source_ref": f"authored in-repo for test{ref_suffix}",
        "license": "LicenseRef-TurnRock-Proprietary",
        "retrieved_at": "2026-08-12",
        "layer": "seed",
        "original_source_path": None,
        "converter_version": None,
        "model3d_ref": None,
        "assembly": {},
        "bless": None,
    }
    base.update(overrides)
    return base


def _write_lock(tmp_path: Path, entries: dict) -> Path:
    lf = tmp_path / "footprints.lock.json"
    lf.write_text(json.dumps({"schema_version": 2, "entries": entries}), encoding="utf-8")
    return lf


def test_release_gate_refuses_every_violation_class_and_is_deterministic(tmp_path):
    """The B6 release gate: every one of the four documented violation axes
    refuses generation by naming the offending ref, a fully-compliant lock
    generates byte-identical output on repeated runs, and ``--check`` catches
    both drift against a committed NOTICE and a gate refusal.
    """
    module = _load_gen_notice()

    # --- Deterministic happy path -----------------------------------------
    good_entries = {
        "Fake:One": _compliant_entry("One"),
        "Fake:Two": _compliant_entry(
            "Two", license="Apache-2.0", provenance_note="a provenance detail",
        ),
    }
    lock_path = _write_lock(tmp_path, good_entries)
    first = module.generate(lock_path)
    second = module.generate(lock_path)
    assert first == second, "generator must be a pure function of the lock document"
    assert "Fake:One" in first and "Fake:Two" in first
    assert "a provenance detail" in first  # provenance_note surfaced
    assert "Total entries: 2" in first

    # --- Violation axis 1: empty license -----------------------------------
    bad_license_entries = dict(good_entries)
    bad_license_entries["Fake:BadLicense"] = _compliant_entry("BadLicense", license="")
    with pytest.raises(module.NoticeGateError, match="Fake:BadLicense"):
        module.generate(_write_lock(tmp_path, bad_license_entries))

    # --- Violation axis 2: empty source_ref --------------------------------
    bad_source_ref_entries = dict(good_entries)
    bad_source_ref_entries["Fake:BadSourceRef"] = _compliant_entry(
        "BadSourceRef", source_ref="",
    )
    with pytest.raises(module.NoticeGateError, match="Fake:BadSourceRef"):
        module.generate(_write_lock(tmp_path, bad_source_ref_entries))

    # --- Violation axis 3: source_kind outside LOCK_SOURCE_KINDS -----------
    bad_kind_entries = dict(good_entries)
    bad_kind_entries["Fake:BadKind"] = _compliant_entry(
        "BadKind", source_kind="scraped_from_a_forum_post",
    )
    with pytest.raises(module.NoticeGateError, match="Fake:BadKind"):
        module.generate(_write_lock(tmp_path, bad_kind_entries))

    # --- Violation axis 4: license contains "UNKNOWN" (case-insensitive) --
    # This is the axis dev CI's census test (test_library_lock.py) does NOT
    # enforce — it only requires a non-empty license, by design, so an
    # in-progress attribution question does not block unrelated PRs. The
    # release gate is what stops that same entry from ever reaching a
    # shipped NOTICE.
    for unknown_license in ("UNKNOWN", "unknown", "License UNKNOWN pending review"):
        unknown_entries = dict(good_entries)
        unknown_entries["Fake:BadUnknown"] = _compliant_entry(
            "BadUnknown", license=unknown_license,
        )
        with pytest.raises(module.NoticeGateError, match="Fake:BadUnknown"):
            module.generate(_write_lock(tmp_path, unknown_entries))

    # --- A single entry can fail more than one axis at once, and every -----
    # violation is named, not just the first.
    multi_bad_entries = {"Fake:MultiBad": _compliant_entry(
        "MultiBad", license="", source_ref="", source_kind="not_a_real_kind",
    )}
    with pytest.raises(module.NoticeGateError) as excinfo:
        module.generate(_write_lock(tmp_path, multi_bad_entries))
    message = str(excinfo.value)
    assert "missing/empty license" in message
    assert "missing/empty source_ref" in message
    assert "outside LOCK_SOURCE_KINDS" in message

    # --- --check: drift against a committed NOTICE refuses -----------------
    clean_lock = _write_lock(tmp_path, good_entries)
    notice_path = tmp_path / "NOTICE.md"
    notice_path.write_text("stale content that does not match generation\n", encoding="utf-8")
    exit_code = module.main([
        "--check", "--lockfile", str(clean_lock), "--out", str(notice_path),
    ])
    assert exit_code == 1
    assert notice_path.read_text(encoding="utf-8") == "stale content that does not match generation\n", (
        "--check must write nothing"
    )

    # --check succeeds once the committed file matches generation exactly.
    notice_path.write_text(module.generate(clean_lock), encoding="utf-8")
    exit_code = module.main([
        "--check", "--lockfile", str(clean_lock), "--out", str(notice_path),
    ])
    assert exit_code == 0

    # --- --check: a gate refusal also exits 1, even with a matching-shaped -
    # NOTICE already on disk (the gate is checked before the diff).
    bad_lock = _write_lock(tmp_path, bad_license_entries)
    exit_code = module.main([
        "--check", "--lockfile", str(bad_lock), "--out", str(notice_path),
    ])
    assert exit_code == 1


def test_shipped_lock_generates_notice_byte_identical_to_committed_file():
    """The same drift gate CI's ``fab-gate`` job runs (``gen_notice.py
    --check``), pinned as a test so a drift between the shipped
    ``pcb/library/footprints.lock.json`` and the committed ``pcb/NOTICE.md``
    is caught here too — including in any environment or review pass that
    skips CI. Also proves the generator succeeds (does not refuse) over the
    REAL shipped lock, not just a synthetic compliant one.
    """
    module = _load_gen_notice()

    generated = module.generate()  # default: the shipped pcb/library/footprints.lock.json
    assert module.DEFAULT_NOTICE_PATH.is_file(), (
        "pcb/NOTICE.md must be committed (generated once by running "
        "gen_notice.py, per station S5)"
    )
    committed = module.DEFAULT_NOTICE_PATH.read_text(encoding="utf-8")
    assert generated == committed, (
        "pcb/NOTICE.md has drifted from pcb/library/footprints.lock.json — "
        "regenerate with `python3 pcb/scripts/gen_notice.py` and commit the result"
    )

    # main() in --check mode against the real shipped files must also
    # succeed — this is the literal invocation CI's fab-gate job runs.
    exit_code = module.main(["--check"])
    assert exit_code == 0


# ---------------------------------------------------------------------------
# 3. UNMAPPED THIRD-PARTY LICENSE: refuse, never mislabel (Codex 1160 P2).
# ---------------------------------------------------------------------------


def test_unmapped_third_party_license_refuses_instead_of_mislabeling(tmp_path):
    """A third-party license with no attribution mapping (e.g. MIT) is a GATE
    VIOLATION. Before this rule, the generator fell back to the proprietary
    "no third-party obligation" paragraph for it — a NOTICE that is materially
    FALSE for a redistributed MIT part, certified by the release gate itself.
    The only license the proprietary text may ever cover is the explicit
    internal LicenseRef."""
    module = _load_gen_notice()

    entries = {
        "Fake:Mit": _compliant_entry("Mit", source_kind="git", license="MIT"),
    }
    with pytest.raises(module.NoticeGateError) as excinfo:
        module.generate(_write_lock(tmp_path, entries))
    message = str(excinfo.value)
    assert "Fake:Mit" in message
    assert "MIT" in message
    assert "THIRD_PARTY_ATTRIBUTION" in message  # the fix is named, not implied

    # The two legitimate classes still render: a MAPPED third-party license
    # under its own attribution text, and the internal LicenseRef under the
    # proprietary note — never the other way around.
    ok = module.generate(_write_lock(tmp_path, {
        "Fake:Apache": _compliant_entry("Apache", license="Apache-2.0"),
        "Fake:Ours": _compliant_entry(
            "Ours", license="LicenseRef-TurnRock-Proprietary"),
    }))
    apache_section = ok.split("## Apache-2.0", 1)[1].split("## ", 1)[0]
    proprietary_section = ok.split("## LicenseRef-TurnRock-Proprietary", 1)[1]
    assert "Fake:Apache" in apache_section
    assert "no third-party attribution" not in apache_section.lower()
    assert "Fake:Ours" in proprietary_section
