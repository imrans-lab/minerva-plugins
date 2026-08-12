"""Acquisition-lock v2 (DCR 019ff567f66b B0): provenance census + loader contract.

Few-and-wide by design (epoch LIB1 rule): one census walk covers provenance
completeness AND vendored-text integrity for every shipped entry; one test
pins the v1 read-only compatibility; one pins the fail-closed refusal.
"""

import json

import pytest

from pcb_worker.footprints import (
    DEFAULT_LIBRARY_ROOT,
    LOCK_SCHEMA_VERSION,
    LOCK_SOURCE_KINDS,
    FootprintLookupError,
    load_lock_document,
    load_lockfile,
    sha256_file,
)


def test_shipped_lock_census_provenance_and_integrity():
    """Every shipped entry is fully provenanced and its vendored text intact.

    This walk is the core predicate the B6 release gate wires up: an entry
    missing source_kind/license/source_ref, carrying an unknown source_kind,
    or whose vendored file drifted from its sha pin fails HERE with the ref
    named — not at the marketplace release.
    """
    doc = load_lock_document()
    assert doc["schema_version"] == LOCK_SCHEMA_VERSION
    entries = doc["entries"]
    assert entries, "shipped lock must not be empty"

    for ref, e in sorted(entries.items()):
        # Provenance completeness (the retrofit promise).
        assert e.get("source_kind") in LOCK_SOURCE_KINDS, (ref, e.get("source_kind"))
        assert e.get("license"), f"{ref}: empty license"
        assert e.get("source_ref"), f"{ref}: empty source_ref"
        assert e.get("retrieved_at"), f"{ref}: empty retrieved_at"
        assert e.get("layer") == "seed", (ref, e.get("layer"))
        # Reserved slots exist explicitly (schema is declared, not implied).
        for slot in ("original_source_path", "converter_version", "model3d_ref",
                     "assembly", "bless"):
            assert slot in e, f"{ref}: missing reserved slot {slot}"
        # Vendored-text integrity: the pin matches the bytes on disk.
        p = DEFAULT_LIBRARY_ROOT / e["path"]
        assert p.is_file(), f"{ref}: vendored file missing at {p}"
        assert sha256_file(p) == e["sha256"], f"{ref}: sha drift at {p}"
        assert p.stat().st_size == e["size_bytes"], f"{ref}: size drift at {p}"


def test_v1_flat_lockfile_still_loads_read_only(tmp_path):
    """A v1 flat lock loads unchanged through both accessors (transition contract)."""
    v1 = {"Lib:Part": {"path": "Lib.pretty/Part.kicad_mod", "sha256": "ab" * 32,
                       "size_bytes": 7}}
    lf = tmp_path / "footprints.lock.json"
    lf.write_text(json.dumps(v1), encoding="utf-8")

    doc = load_lock_document(lf)
    assert doc["schema_version"] == 1
    assert doc["entries"] == v1
    assert load_lockfile(lf) == v1


def test_unreadable_or_future_lock_refuses(tmp_path):
    """Fail-closed: a lock this reader cannot understand must never resolve."""
    lf = tmp_path / "footprints.lock.json"

    lf.write_text(json.dumps({"schema_version": 3, "entries": {}}), encoding="utf-8")
    with pytest.raises(FootprintLookupError):
        load_lock_document(lf)

    lf.write_text(json.dumps({"schema_version": LOCK_SCHEMA_VERSION}), encoding="utf-8")
    with pytest.raises(FootprintLookupError):
        load_lock_document(lf)

    lf.write_text(json.dumps(["not", "an", "object"]), encoding="utf-8")
    with pytest.raises(FootprintLookupError):
        load_lock_document(lf)
