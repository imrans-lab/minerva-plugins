"""Unit tests for pcb_worker.methods — call handle_request() directly.

These bypass stdio entirely (same pattern as the CAD worker's tests). The
canonical spike board (pcb/spikes/gerber/board.yaml) is the happy-path fixture.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from pcb_worker.methods import handle_request

SPIKE_BOARD = Path(__file__).resolve().parents[2] / "spikes" / "gerber" / "board.yaml"
FIXTURE_LIB = str(Path(__file__).resolve().parent / "testdata" / "fixture_lib")


@pytest.fixture()
def board_yaml() -> str:
    return SPIKE_BOARD.read_text(encoding="utf-8")


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None
    assert resp["id"] == "r1"
    return resp


# ---------------------------------------------------------------------------
# init / ping
# ---------------------------------------------------------------------------


def test_init_reports_versions():
    resp = _call("init", {})
    assert resp["ok"] is True
    r = resp["result"]
    assert r["worker_version"]
    assert r["pyyaml"] != "unknown"
    assert "circuit_synth_available" in r


def test_ping_pongs():
    resp = _call("ping", {"echo": "hi"})
    assert resp["ok"] is True
    assert resp["result"]["pong"] is True
    assert resp["result"]["echo"] == "hi"


def test_unknown_method():
    resp = _call("frobnicate", {})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "internal"


# ---------------------------------------------------------------------------
# validate — happy path
# ---------------------------------------------------------------------------


def test_validate_spike_board_ok(board_yaml):
    resp = _call("validate", {"yaml": board_yaml})
    assert resp["ok"] is True  # protocol-level
    r = resp["result"]
    assert r["ok"] is True, f"expected clean board, got errors: {r['errors']}"
    assert r["errors"] == []


def test_validate_accepts_board_dict(board_yaml):
    import yaml
    board = yaml.safe_load(board_yaml)
    resp = _call("validate", {"board": board})
    assert resp["result"]["ok"] is True


# ---------------------------------------------------------------------------
# validate — malformed YAML
# ---------------------------------------------------------------------------


def test_validate_malformed_yaml():
    resp = _call("validate", {"yaml": "name: [unterminated"})
    assert resp["ok"] is True
    r = resp["result"]
    assert r["ok"] is False
    assert any("YAML" in e["message"] or "invalid" in e["message"] for e in r["errors"])


def test_validate_missing_required_fields():
    resp = _call("validate", {"yaml": "name: X\n"})
    r = resp["result"]
    assert r["ok"] is False
    paths = {e["path"] for e in r["errors"]}
    assert "width_mm" in paths and "components" in paths and "nets" in paths


# ---------------------------------------------------------------------------
# validate — seeded structural errors
# ---------------------------------------------------------------------------

_BASE = """
version: 1
name: T
width_mm: 40
height_mm: 30
design_rules: {trace_width_mm: 0.25}
components:
  - {ref: R1, footprint: R_0805, x_mm: 10, y_mm: 10, rotation_deg: 0,
     pins: [{number: "1", x_mm: 0, y_mm: 0}, {number: "2", x_mm: 1, y_mm: 0}]}
  - {ref: C1, footprint: C_0805, x_mm: 15, y_mm: 10, rotation_deg: 0,
     pins: [{number: "1", x_mm: 0, y_mm: 0}, {number: "2", x_mm: 1, y_mm: 0}]}
nets:
  - {name: VCC, pins: ["R1.2", "C1.1"]}
traces:
  - {net: VCC, width_mm: 0.25, points: [{x_mm: 10, y_mm: 10}, {x_mm: 15, y_mm: 10}]}
"""


def test_validate_duplicate_ref():
    bad = _BASE.replace("ref: C1", "ref: R1")
    r = _call("validate", {"yaml": bad})["result"]
    assert r["ok"] is False
    assert any("duplicate" in e["message"] for e in r["errors"])


def test_validate_bad_net_pin_ref():
    bad = _BASE.replace('"C1.1"', '"C1.9"')  # C1 has no pad 9
    r = _call("validate", {"yaml": bad})["result"]
    assert r["ok"] is False
    assert any("pad '9'" in e["message"] for e in r["errors"])


def test_validate_net_ref_unknown_component():
    bad = _BASE.replace('"C1.1"', '"Q7.1"')  # no component Q7
    r = _call("validate", {"yaml": bad})["result"]
    assert r["ok"] is False
    assert any("unknown component 'Q7'" in e["message"] for e in r["errors"])


def test_validate_trace_unknown_net():
    bad = _BASE.replace("net: VCC, width_mm", "net: GND, width_mm")
    r = _call("validate", {"yaml": bad})["result"]
    assert r["ok"] is False
    assert any("unknown net 'GND'" in e["message"] for e in r["errors"])


def test_validate_out_of_bounds_trace_is_warning():
    bad = _BASE.replace("{x_mm: 15, y_mm: 10}", "{x_mm: 500, y_mm: 10}")
    r = _call("validate", {"yaml": bad})["result"]
    # Out-of-bounds is a soft warning, not a hard error.
    assert r["ok"] is True
    assert any("outside the board outline" in w["message"] for w in r["warnings"])


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------


def test_generate_produces_kicad_pcb(board_yaml):
    resp = _call("generate", {"yaml": board_yaml})
    assert resp["ok"] is True
    files = resp["result"]["files"]
    assert any(k.endswith(".kicad_pcb") for k in files)
    assert any(k.endswith(".kicad_sch") for k in files)
    assert any(k.endswith(".kicad_pro") for k in files)
    pcb = next(v for k, v in files.items() if k.endswith(".kicad_pcb"))
    assert pcb.startswith("(kicad_pcb")
    assert "(footprint" in pcb  # components rendered
    assert "(segment" in pcb    # traces rendered
    assert "Edge.Cuts" in pcb   # outline rendered
    assert "(via" in pcb        # via rendered


def test_generate_writes_out_dir(board_yaml, tmp_path):
    resp = _call("generate", {"yaml": board_yaml, "out_dir": str(tmp_path)})
    written = resp["result"]["written"]
    assert len(written) == 3
    for w in written:
        assert Path(w["path"]).is_file()
        assert w["bytes_written"] > 0


def test_generate_malformed_yaml_errors():
    resp = _call("generate", {"yaml": "]["})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"


# ---------------------------------------------------------------------------
# check_libraries — no-data contract
# ---------------------------------------------------------------------------


def test_check_libraries_no_lib_dir(board_yaml):
    resp = _call("check_libraries", {"yaml": board_yaml})
    assert resp["ok"] is True
    r = resp["result"]
    assert r["ok"] is True
    assert r["checked"] == 0
    assert r["missing"] == []
    assert r["missing_data"] is True
    assert "pcb_fetch_libraries" in r["hint"]


def test_check_libraries_empty_lib_dir(board_yaml):
    resp = _call("check_libraries", {"yaml": board_yaml, "lib_dir": "   "})
    r = resp["result"]
    assert r["missing_data"] is True
    assert "pcb_fetch_libraries" in r["hint"]


def test_check_libraries_with_data(board_yaml, tmp_path):
    # Seed a KiCAD .pretty tree so one footprint resolves and others miss.
    pretty = tmp_path / "R_SMD.pretty"
    pretty.mkdir()
    (pretty / "R_0805.kicad_mod").write_text("(footprint)")
    resp = _call("check_libraries", {"yaml": board_yaml, "lib_dir": str(tmp_path)})
    r = resp["result"]
    assert r["missing_data"] is False
    assert r["checked"] >= 1
    # R_0805 resolves (bare-name scan finds it); C_0805 / TH_TestPoint miss.
    missing_fps = {m["footprint"] for m in r["missing"]}
    assert "C_0805" in missing_fps
    # missing_symbols is always present (symbol match is optional/informal —
    # board-yaml components have no first-class symbol field this round).
    assert r["missing_symbols"] == []


def test_check_libraries_against_real_fixture_lib(board_yaml):
    # Real curated fixture (the same shape libraries.lock.json fetches into):
    # R_0805/C_0805 (spike board's bare footprint names) do NOT match the
    # fixture's actual KiCad-conventioned names (R_0603_1608Metric etc) —
    # this documents that the spike board uses placeholder names, not real
    # KiCad footprint IDs, so a "required, real" check correctly flags them.
    resp = _call("check_libraries", {"yaml": board_yaml, "lib_dir": FIXTURE_LIB})
    r = resp["result"]
    assert r["missing_data"] is False
    assert r["checked"] == 3  # R1, C1, U1 all declare a footprint
    missing_fps = {m["footprint"] for m in r["missing"]}
    assert missing_fps == {"R_0805", "C_0805", "TH_TestPoint"}
    # Nearest-name suggestions surface for the resistor (close to a real name).
    r1_entry = next(m for m in r["missing"] if m["footprint"] == "R_0805")
    assert isinstance(r1_entry["suggestions"], list)


def test_check_libraries_symbol_is_optional_soft_signal():
    # A component carrying an (unmodeled) "symbol" field via Extra passthrough
    # (no "footprint" field at all here, isolating the symbol-only path) — a
    # symbol miss lands in missing_symbols, never in "missing" (footprints),
    # and never flips `ok`.
    yaml_src = (
        "version: 1\nname: T\nwidth_mm: 10\nheight_mm: 10\n"
        "components:\n"
        "  - {ref: X1, symbol: NoSuchSymbol, x_mm: 1, y_mm: 1, rotation_deg: 0}\n"
        "nets: []\n"
    )
    resp = _call("check_libraries", {"yaml": yaml_src, "lib_dir": FIXTURE_LIB})
    r = resp["result"]
    assert r["ok"] is True  # no footprint declared -> nothing gates ok here
    assert r["missing"] == []
    assert any(m["symbol"] == "NoSuchSymbol" and m["ref"] == "X1" for m in r["missing_symbols"])

    # And the mirror-image: a resolvable symbol produces no miss entry.
    yaml_ok = yaml_src.replace("NoSuchSymbol", "Device:R")
    resp2 = _call("check_libraries", {"yaml": yaml_ok, "lib_dir": FIXTURE_LIB})
    assert resp2["result"]["missing_symbols"] == []


# ---------------------------------------------------------------------------
# check_bom
# ---------------------------------------------------------------------------


def test_check_bom_extracts_items(board_yaml):
    resp = _call("check_bom", {"yaml": board_yaml})
    assert resp["ok"] is True
    r = resp["result"]
    assert r["part_count"] == 3  # R1, C1, U1
    refs = {ref for it in r["items"] for ref in it["refs"]}
    assert refs == {"R1", "C1", "U1"}
    # No lib_dir supplied -> the check_libraries-mirroring no-data contract.
    assert r["lib_present"] is False
    assert r["missing_data"] is True
    assert "pcb_fetch_libraries" in r["hint"]


def test_check_bom_warns_missing_value():
    yaml_src = _BASE.replace("footprint: C_0805,", "footprint: C_0805, value: '',")
    # Remove R1 value implicitly absent already; assert warnings surface.
    resp = _call("check_bom", {"yaml": _BASE})
    r = resp["result"]
    assert any("no value" in w["message"] for w in r["warnings"])


def test_check_bom_footprint_found_and_suggestions_with_lib_dir(board_yaml):
    resp = _call("check_bom", {"yaml": board_yaml, "lib_dir": FIXTURE_LIB})
    r = resp["result"]
    assert r["lib_present"] is True
    assert r["missing_data"] is False
    assert "hint" not in r
    items_by_fp = {it["footprint"]: it for it in r["items"]}
    # R_0805 (spike board's placeholder name) doesn't match the real fixture
    # lib's R_0805_2012Metric — flagged not-found, with a nearest-name
    # suggestion offered from the present library.
    assert items_by_fp["R_0805"]["footprint_found"] is False
    assert "R_0805_2012Metric" in items_by_fp["R_0805"]["suggestions"]
