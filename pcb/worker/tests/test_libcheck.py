"""Unit tests for pcb_worker.libcheck — footprint existence + symbol scanning.

Uses the tiny hand-authored fixture library at tests/testdata/fixture_lib/
(one .kicad_sym with 2 top-level symbols + nested unit sub-symbols that must
NOT be picked up, one .pretty with 2 .kicad_mod stubs). This is a real,
minimal-but-genuine KiCAD s-expression shape — not a mock — so the paren-depth
scan is exercised against the actual format quirk it exists to handle (nested
per-unit sub-symbol defs inside a part).
"""

from __future__ import annotations

from pathlib import Path

from pcb_worker import libcheck

FIXTURE_LIB = str(Path(__file__).resolve().parent / "testdata" / "fixture_lib")


# ---------------------------------------------------------------------------
# Footprints
# ---------------------------------------------------------------------------


def test_resolve_footprint_lib_colon_name_present():
    assert libcheck.resolve_footprint(FIXTURE_LIB, "Resistor_SMD:R_0603_1608Metric") is True


def test_resolve_footprint_lib_colon_name_missing():
    assert libcheck.resolve_footprint(FIXTURE_LIB, "Resistor_SMD:R_9999_NoSuchPart") is False


def test_resolve_footprint_bare_name_scans_every_pretty():
    assert libcheck.resolve_footprint(FIXTURE_LIB, "R_0805_2012Metric") is True


def test_resolve_footprint_unknown_lib_prefix():
    assert libcheck.resolve_footprint(FIXTURE_LIB, "NoSuchLib:R_0603_1608Metric") is False


def test_list_footprint_names():
    names = set(libcheck.list_footprint_names(FIXTURE_LIB))
    assert names == {"R_0603_1608Metric", "R_0805_2012Metric"}


def test_suggest_footprints_nearest_name():
    # Close to R_0603_1608Metric but not exact (typo'd digit).
    suggestions = libcheck.suggest_footprints(FIXTURE_LIB, "Resistor_SMD:R_0603_1608Metrik")
    assert "R_0603_1608Metric" in suggestions


def test_suggest_footprints_empty_when_no_input():
    assert libcheck.suggest_footprints(FIXTURE_LIB, "") == []


def test_suggest_footprints_empty_lib_dir(tmp_path):
    assert libcheck.suggest_footprints(str(tmp_path), "R_0603_1608Metric") == []


# ---------------------------------------------------------------------------
# Symbols
# ---------------------------------------------------------------------------


def test_list_symbol_libs_top_level_only():
    libs = libcheck.list_symbol_libs(FIXTURE_LIB)
    assert libs.keys() == {"Device"}
    # Only the part-level names, never the nested unit sub-symbols.
    assert set(libs["Device"]) == {"R", "C"}
    assert "R_0_1" not in libs["Device"]
    assert "R_1_1" not in libs["Device"]
    assert "C_0_1" not in libs["Device"]


def test_resolve_symbol_lib_colon_name():
    assert libcheck.resolve_symbol(FIXTURE_LIB, "Device:R") is True
    assert libcheck.resolve_symbol(FIXTURE_LIB, "Device:NoSuchPart") is False


def test_resolve_symbol_bare_name():
    assert libcheck.resolve_symbol(FIXTURE_LIB, "C") is True
    assert libcheck.resolve_symbol(FIXTURE_LIB, "ZZZ") is False


def test_resolve_symbol_never_matches_nested_unit_subsymbol():
    # R_1_1 is a real substring in the fixture file but is a nested unit
    # sub-symbol, not a top-level part name — must not resolve.
    assert libcheck.resolve_symbol(FIXTURE_LIB, "Device:R_1_1") is False


def test_list_symbol_libs_missing_dir_returns_empty():
    assert libcheck.list_symbol_libs("/no/such/dir/at/all") == {}
