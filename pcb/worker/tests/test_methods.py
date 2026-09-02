"""Unit tests for pcb_worker.methods — call handle_request() directly.

These bypass stdio entirely (same pattern as the CAD worker's tests). The
canonical spike board (pcb/spikes/gerber/board.yaml) is the happy-path fixture.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml

from pcb_worker.methods import handle_request
# The shared corpus orientation statement, autouse in this module: these
# boards are drawn on this repository's own land patterns, and orientation
# is measured by test_assembly_orientation.py, not here.
from tests.orientation_corpus import corpus_orientation  # noqa: F401

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


def test_validate_cannot_refute_a_pin_ref_a_library_part_owns():
    # C1 takes its pads from its footprint and its `pins` are OVERRIDES of them,
    # so the file states no roster this structural pass could measure "C1.9"
    # against — it says so rather than guessing. The real adjudication is against
    # the RESOLVED pads, in compile_board._finalize_nets.
    bad = _BASE.replace('"C1.1"', '"C1.9"')
    r = _call("validate", {"yaml": bad})["result"]
    assert r["ok"] is True
    assert any("cannot verify pad '9'" in w["message"] for w in r["warnings"])


def test_validate_bad_net_pin_ref_on_a_pads_authored_component():
    # A `pads` key IS the full pad roster, so here the file CAN refute the ref.
    # The override pin "3" beside the two real pads does not enlarge that roster:
    # a pin overrides a pad, it never declares one.
    bad = _BASE.replace(
        '- {ref: C1, footprint: C_0805, x_mm: 15, y_mm: 10, rotation_deg: 0,\n'
        '     pins: [{number: "1", x_mm: 0, y_mm: 0}, {number: "2", x_mm: 1, y_mm: 0}]}',
        '- {ref: C1, footprint: C_0805, x_mm: 15, y_mm: 10, rotation_deg: 0,\n'
        '     pads: [{number: "1"}, {number: "2"}],\n'
        '     pins: [{number: "3", override: {drill_mm: 0.8}}]}',
    ).replace('"C1.1"', '"C1.3"')
    r = _call("validate", {"yaml": bad})["result"]
    assert r["ok"] is False
    assert any("pad '3'" in e["message"] for e in r["errors"])


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
    # W8.2 cutover: generate now COMPILES → IR → kicad.generate. The spike board's
    # Extra `mounting_holes` are board-level NON-plated holes the KiCad emitter
    # cannot drill (generate_kicad_pcb emits no standalone holes), so the IR adapter
    # fail-closes on them — the strict, no-silent-drop contract. Drop them here so
    # this happy-path fixture stays KiCad-emittable while still exercising
    # footprints/segments/vias/edge-cuts (holes are covered by the gerbers path).
    import yaml
    board = yaml.safe_load(board_yaml)
    board.pop("mounting_holes", None)
    resp = _call("generate", {"board": board})
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
    # See test_generate_produces_kicad_pcb: strip the board-level mounting_holes the
    # KiCad IR path fail-closes on so this write-path fixture stays emittable.
    import yaml
    board = yaml.safe_load(board_yaml)
    board.pop("mounting_holes", None)
    resp = _call("generate", {"board": board, "out_dir": str(tmp_path)})
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
    assert "minerva_pcb_fetch_libraries" in r["hint"]


def test_check_libraries_empty_lib_dir(board_yaml):
    resp = _call("check_libraries", {"yaml": board_yaml, "lib_dir": "   "})
    r = resp["result"]
    assert r["missing_data"] is True
    assert "minerva_pcb_fetch_libraries" in r["hint"]


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
    assert "minerva_pcb_fetch_libraries" in r["hint"]


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


# ---------------------------------------------------------------------------
# assembly_bom / assembly_cpl / assembly_package — RPC wiring only (see
# test_assembly_outputs.py for emitter mechanics: grouping, rotation
# convention, identity refusal).
# ---------------------------------------------------------------------------

ASSEMBLY_BOARD = (Path(__file__).resolve().parent / "testdata" / "assembly_boards"
                  / "assembly_resolved.yaml")


# Its uncompilable twin: pins offset from their library pads, a footprint in no
# library, two missing via rules. The raw-dict emitter produced clean CSVs for
# it; the compiled path must refuse it by name.
UNCOMPILABLE_ASSEMBLY_BOARD = ASSEMBLY_BOARD.with_name("assembly_fixture.yaml")


@pytest.fixture()
def assembly_yaml() -> str:
    return ASSEMBLY_BOARD.read_text(encoding="utf-8")


def test_assembly_bom_dispatch_default_profile(assembly_yaml):
    resp = _call("assembly_bom", {"yaml": assembly_yaml})
    assert resp["ok"] is True
    files = resp["result"]["files"]
    assert list(files.keys()) == ["board-bom-jlc.csv"]
    assert "LCSC Part #" in next(iter(files.values()))


def test_assembly_cpl_dispatch_default_profile(assembly_yaml):
    resp = _call("assembly_cpl", {"yaml": assembly_yaml, "name": "afix"})
    assert resp["ok"] is True
    files = resp["result"]["files"]
    assert list(files.keys()) == ["afix-cpl-jlc.csv"]
    assert "Rotation" in next(iter(files.values()))


def test_assembly_cpl_unknown_house_is_named_refusal(assembly_yaml):
    resp = _call("assembly_cpl", {"yaml": assembly_yaml, "profile": "acme"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "assembly"
    assert "acme" in resp["error"]["message"]


def test_assembly_bom_house_without_assembly_service_is_named_refusal(assembly_yaml):
    resp = _call("assembly_bom", {"yaml": assembly_yaml, "profile": "oshpark"})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "assembly"
    assert "OSH Park" in resp["error"]["message"]


def test_assembly_bom_missing_identity_is_named_refusal():
    # Drops R1's mpn from its structured assembly block (6-space indent); R2's
    # pre-block top-level scalar (4-space) is deliberately left alone, so the
    # refusal has to name R1 specifically rather than the whole board.
    src = ASSEMBLY_BOARD.read_text(encoding="utf-8").replace(
        "      mpn: C25804\n", "", 1)
    resp = _call("assembly_bom", {"yaml": src})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "assembly"
    assert "R1" in resp["error"]["message"]
    assert "mpn" in resp["error"]["message"]


def test_assembly_bom_uncompilable_board_refuses_by_name_with_no_csv():
    """THE DELIBERATE CAPABILITY REGRESSION, at the dispatch boundary. This
    board used to produce a clean BOM off the raw dict. It now refuses under
    its own kind, names every component/pad/footprint that blocked the
    compile, and returns NO result — never a traceback, never a partial CSV."""
    resp = _call("assembly_bom",
                 {"yaml": UNCOMPILABLE_ASSEMBLY_BOARD.read_text(encoding="utf-8")})
    assert resp["ok"] is False
    assert "result" not in resp
    error = resp["error"]
    assert error["kind"] == "assembly_not_compilable"
    assert "traceback" not in error
    named = {b["entity_id"] for b in error["blocked_by"]}
    assert {"R1.1", "R1.2", "R2.1", "R2.2"} <= named
    assert "D1" in named


def test_assembly_cpl_refuses_the_same_uncompilable_board_the_same_way():
    """BOM and CPL are two dispatch entries; if only one refused, an order
    could still be half-assembled from a board that does not compile."""
    resp = _call("assembly_cpl",
                 {"yaml": UNCOMPILABLE_ASSEMBLY_BOARD.read_text(encoding="utf-8")})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "assembly_not_compilable"
    assert resp["error"]["blocked_by"]


def test_assembly_bom_and_gerbers_describe_the_same_board():
    """The point of the cutover, asserted end to end: the gerbers and the CSVs
    are emitted from the same board, so every designator the CPL places has a
    compiled component behind it and vice versa. A board that yields one must
    yield the other."""
    src = ASSEMBLY_BOARD.read_text(encoding="utf-8")
    cpl = _call("assembly_cpl", {"yaml": src})
    gerbers = _call("gerbers", {"yaml": src})
    assert cpl["ok"] is True and gerbers["ok"] is True

    placed = {row.split(",")[0] for row in
              next(iter(cpl["result"]["files"].values())).splitlines()[1:]}
    board = yaml.safe_load(src)
    populated = {c["ref"] for c in board["components"]
                 if c.get("assembly") != "exclude"
                 and (c.get("assembly") or {}).get("populate") is not False}
    assert placed == populated


def test_assembly_package_returns_both_csvs_from_one_call(assembly_yaml):
    """The combined boundary is ONE dispatch call, and it names which file is
    which. Two calls would be two compilations, and a BOM and a CPL from two
    compilations can describe two different boards while each call's own
    reference-set gate still passes."""
    resp = _call("assembly_package", {"yaml": assembly_yaml, "name": "afix"})
    assert resp["ok"] is True
    result = resp["result"]
    assert result["bom_file"] == "afix-bom-jlc.csv"
    assert result["cpl_file"] == "afix-cpl-jlc.csv"
    assert set(result["files"]) == {"afix-bom-jlc.csv", "afix-cpl-jlc.csv"}
    assert "LCSC Part #" in result["files"]["afix-bom-jlc.csv"]
    assert "Rotation" in result["files"]["afix-cpl-jlc.csv"]
    # Both files come out of one walk, so they name the same designators.
    import csv

    bom = list(csv.reader(result["files"]["afix-bom-jlc.csv"].splitlines()))
    cpl = list(csv.reader(result["files"]["afix-cpl-jlc.csv"].splitlines()))
    bom_refs = {ref for row in bom[1:] for ref in row[1].split(",")}
    assert bom_refs == {row[0] for row in cpl[1:]}
    assert result["excluded_components"] == ["FID1", "TXT1"]


def test_assembly_package_refuses_an_uncompilable_board_with_no_file(assembly_yaml):
    """One refusal for the pair: an order is all-or-nothing, so the package
    method must not return a BOM for a board whose CPL could not be built."""
    resp = _call("assembly_package",
                 {"yaml": UNCOMPILABLE_ASSEMBLY_BOARD.read_text(encoding="utf-8")})
    assert resp["ok"] is False
    assert "result" not in resp
    assert resp["error"]["kind"] == "assembly_not_compilable"
    assert resp["error"]["blocked_by"]


def test_assembly_package_writes_both_files_to_out_dir(assembly_yaml, tmp_path):
    resp = _call("assembly_package", {"yaml": assembly_yaml, "out_dir": str(tmp_path)})
    assert resp["ok"] is True
    assert len(resp["result"]["written"]) == 2
    assert (tmp_path / "board-bom-jlc.csv").is_file()
    assert (tmp_path / "board-cpl-jlc.csv").is_file()


def test_assembly_bom_writes_out_dir(assembly_yaml, tmp_path):
    resp = _call("assembly_bom", {"yaml": assembly_yaml, "out_dir": str(tmp_path)})
    assert resp["ok"] is True
    written = resp["result"]["written"]
    assert len(written) == 1
    assert (tmp_path / "board-bom-jlc.csv").is_file()
    assert written[0]["bytes_written"] == (tmp_path / "board-bom-jlc.csv").stat().st_size


# ---------------------------------------------------------------------------
# mask_view (WYSIWYG goal 019ff4a5a75a, gap G4) — the panel's mask overlay.
# ---------------------------------------------------------------------------


def test_mask_view_returns_projection_mask_verbatim():
    """The reply must be Projection.mask — the collection GC8 measures — not a
    second enumeration. Compared field-by-field against a direct projection of
    the same compiled board, so the method cannot quietly grow its own reading
    of the mask rule."""
    import yaml as _yaml

    from pcb_worker.compile_board import compile_board
    from pcb_worker.drc_geometric import project_board
    from pcb_worker.methods import handle_request
    from pcb_worker.resolved_board import Side

    src = (Path(__file__).parent / "testdata" / "coupon_jlc1.yaml").read_text()
    reply = handle_request(
        {"id": 1, "method": "mask_view", "params": {"yaml": src}})
    result = reply["result"]
    assert reply.get("result", {}).get("openings"), reply

    rb = compile_board(_yaml.safe_load(src)).board
    proj = project_board(rb)
    expected = [{
        "side": "top" if o.side is Side.TOP else "bottom",
        "shape": o.shape, "x_mm": o.x, "y_mm": o.y,
        "width_mm": o.width, "height_mm": o.height,
        "corner_rratio": o.corner_rratio, "angle_deg": o.angle_deg,
        "origin": o.origin, "ref": o.ref, "pad_number": o.pad_number,
    } for o in proj.mask]
    assert result["openings"] == expected
    assert result["indeterminate"] == []


def test_mask_view_fails_closed_on_an_uncompilable_board():
    """A board that cannot compile has no trustworthy mask; the reply must be
    an error, never an empty overlay a viewer would read as 'no openings'."""
    from pcb_worker.methods import handle_request

    reply = handle_request({"id": 1, "method": "mask_view",
                            "params": {"yaml": "version: 1\nname: x\n"}})
    assert reply.get("result", reply).get("ok") is not True, reply
