"""The SELECTED SERVICE: the pinned jlcpcb-economic profile, its template
goldens, and the checks selecting it turns on.

THE ORACLES, named, because each of these tests turns on a different one:

  * TEMPLATE GOLDENS come from ``testdata/jlc_templates/`` — the parsed contents
    of the two workbooks JLCPCB itself serves, beside the SHA-256 of the bytes
    that were downloaded. Nothing here is derived from help-page prose, and
    nothing asserts byte equality between an emitted CSV and an XLSX: the
    comparison is column names against column names and sample values against
    sample values.

    WHAT THIS DOES NOT ESTABLISH, stated because the alternative is a reader
    trusting it further than it goes: no test in this repo fetches anything, so
    OFFLINE these tests prove that the shipped profile and the checked-in golden
    AGREE WITH EACH OTHER — two transcriptions of one download — and not that
    either matches what JLCPCB serves today. The recorded sha256 is what makes
    the claim checkable, not what checks it: re-running
    ``testdata/jlc_templates/regenerate.py`` is the only thing that compares
    either against the manufacturer's bytes. A workbook JLCPCB changes without
    changing its URL goes undetected here until someone runs it.
  * THE FAB-PROFILE GATE turns on a board compiled against a DIFFERENT rule
    profile than the service pins. The failure it exists to catch is an export
    that succeeds anyway and quietly relabels an OSH-Park-checked (or default-
    floor) board as ready for JLCPCB.
  * THE SIDE BLOCKER turns on a populated part on a side the tier does not
    place. The failure it exists to catch is that incompatibility arriving as
    an ADVISORY — a line in a list a person can skim past — rather than a
    refusal.
  * THE UNCHECKED LIST turns on the difference between "clean" and "not looked
    at". A service export that reports no findings and names nothing it skipped
    is the same lie by omission the tri-state assembly check was built to
    remove.
"""

from __future__ import annotations

import csv
import json
import re
from pathlib import Path

import pytest

from pcb_worker import assembly_gates as ag
from pcb_worker import assembly_outputs as ao
from pcb_worker import service_profile as sp
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

SERVICE_ID = "jlcpcb-economic"
GOLDEN = (Path(__file__).resolve().parent / "testdata" / "jlc_templates"
          / "jlcpcb-economic-templates.json")
SHIPPED = (Path(__file__).resolve().parents[2] / "library" / "service-profiles"
           / f"{SERVICE_ID}.json")


# ---------------------------------------------------------------------------
# Boards. Built as dicts in-test, the same way the other assembly suites do:
# the shapes below differ from each other in ONE fact each, and a YAML fixture
# per fact would hide which one is under test.
# ---------------------------------------------------------------------------


def _service_board(**overrides) -> dict:
    """A board this service can build: two copper layers, compiled against the
    fab profile the service pins, every populated part on the top side and
    clear of the rim."""
    board = {
        "version": 1, "name": "ServiceBoard", "width_mm": 30, "height_mm": 20,
        "origin": {"x_mm": 0, "y_mm": 0}, "layers": ["top", "bottom"],
        "design_rules": {
            "rule_profile": "jlcpcb-2layer",
            "clearance_mm": 0.2, "trace_width_mm": 0.25,
            "via_diameter_mm": 0.8, "via_drill_mm": 0.4,
        },
        "components": [
            {"ref": "R1", "footprint": "R_0805", "value": "10k",
             "x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0, "layer": "top",
             "assembly": {"mpn": "C25804", "package": "0805",
                          "house_parts": {"jlcpcb": "C25804"}}},
            {"ref": "R2", "footprint": "R_0805", "value": "10k",
             "x_mm": 20.0, "y_mm": 10.0, "rotation_deg": 90, "layer": "top",
             "assembly": {"mpn": "C25804", "package": "0805",
                          "house_parts": {"jlcpcb": "C25804"}}},
        ],
    }
    board.update(overrides)
    return board


def _compiled(board: dict):
    """Fails LOUDLY rather than skipping: a board that stopped compiling would
    otherwise silently stop testing the service checks at all."""
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "board did not compile: "
            + ", ".join(f"{d.code} on {d.source_ref.entity_id if d.source_ref else '?'}"
                        for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _codes(result) -> set[str]:
    """Every advisory code an :class:`AssemblyPackage` carries. The findings ride
    on the EMISSION the package wraps, not on the package."""
    return {item["code"] for item in result.emission.advisories}


# ---------------------------------------------------------------------------
# The pinned templates: goldens parsed from the artifacts, never from prose.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def golden() -> dict:
    data = json.loads(GOLDEN.read_text(encoding="utf-8"))
    return {item["artifact"]: item for item in data["templates"]}


@pytest.fixture(scope="module")
def service() -> sp.ServiceProfile:
    return sp.load_service_profile(SERVICE_ID)


def test_template_pins_match_the_downloaded_artifacts(service, golden):
    """Every pin names the artifact the golden was parsed out of: same URL, same
    fetch date, same digest of the same bytes. A pin that drifted from its
    golden is a pin nobody could reproduce.

    Two transcriptions of ONE download agreeing, which is all an offline test
    can be. Nothing here re-fetches the workbook — see the suite docstring."""
    assert {pin.artifact for pin in service.templates} == set(golden)
    for pin in service.templates:
        parsed = golden[pin.artifact]
        assert pin.url == parsed["url"]
        assert pin.sha256 == parsed["sha256"]
        assert pin.fetched == parsed["fetched"]


def test_pinned_columns_are_the_workbooks_own_header_row(service, golden):
    """THE SEMANTIC GOLDEN. The profile's ``columns`` must be the header row
    that was READ out of the workbook — including JLCPCB's full-width
    parentheses in ``JLCPCB Part #（optional）``, which is exactly the drift a
    transcription from the help page would have flattened."""
    for pin in service.templates:
        assert list(pin.columns) == golden[pin.artifact]["rows"][0]
    bom = service.template("bom")
    assert bom.columns[3] == "JLCPCB Part #（optional）"


def test_observed_value_dialect_is_read_off_the_sample_rows(service, golden):
    """The CPL sample's Layer column carries ``T``/``B`` and its coordinates
    carry a ``mm`` suffix; both are recorded on the pin. Derived HERE from the
    golden rows rather than restated, so the pin cannot claim an observation the
    workbook does not contain."""
    rows = golden["cpl"]["rows"]
    header = rows[0]
    layer_values = {row[header.index("Layer")] for row in rows[1:]}
    assert layer_values == set(service.template("cpl").observed_layer_tokens.values())

    suffixes = {re.sub(r"^[0-9.+-]*", "", row[header.index("Mid X")])
                for row in rows[1:]}
    assert suffixes == {service.template("cpl").observed_coordinate_suffix}

    bom_rows = golden["bom"]["rows"]
    designators = bom_rows[2][bom_rows[0].index("Designator")]
    assert designators == "R5,R6"  # comma, no space — the emitted separator


def test_emitted_headers_are_the_pinned_dialect_and_the_drift_is_named(service):
    """What the emitter writes comes from the profile, and every column where it
    differs from the workbook is explained on the pin.

    This is the header-drift finding made permanent: the emitted catalogue
    column is ``LCSC Part #`` while the current template spells it
    ``JLCPCB Part #（optional）``, and only a live quote-page upload settles which
    the uploader prefers. The difference is recorded rather than silently
    resolved, and the loader refuses a profile that leaves one unexplained."""
    profile = ao.PROFILES[SERVICE_ID]
    bom = service.template("bom")
    assert profile.bom_columns == tuple(service.dialect["bom_columns"])
    assert [entry["position"] for entry in bom.drift] == [3]
    assert bom.drift[0]["template"] == "JLCPCB Part #（optional）"
    assert bom.drift[0]["emitted"] == "LCSC Part #"
    # The CPL agrees column-for-column, so it must carry NO drift entry.
    assert service.template("cpl").drift == ()
    assert any(rule["id"] == "template_column_drift_resolution"
               for rule in service.unchecked_rules)


def test_emitted_csv_header_rows_are_the_profile_columns():
    """The pin reaches the file. Reading the emitted header back through a CSV
    parser rather than comparing strings, so the claim is about columns and not
    about quoting."""
    board = _compiled(_service_board())
    package = ao.build_package(board, SERVICE_ID, name="svc")
    bom_header = next(csv.reader(package.files[package.bom_file].splitlines()))
    cpl_header = next(csv.reader(package.files[package.cpl_file].splitlines()))
    profile = ao.PROFILES[SERVICE_ID]
    assert tuple(bom_header) == profile.bom_columns
    assert tuple(cpl_header) == profile.cpl_columns


def test_the_emitted_value_dialect_comes_from_the_profile(service):
    """The CPL sample JLCPCB serves writes ``T``/``B`` and a ``mm`` suffix on
    every coordinate; this emitter writes ``Top``/``Bottom`` and bare numbers,
    which its own uploader documentation accepts. Both halves are PINNED — the
    observation on the template, the choice on the dialect — so the pair is a
    recorded decision rather than an accident of whoever wrote the renderer."""
    profile = ao.PROFILES[SERVICE_ID]
    assert profile.coordinate_suffix == ""
    assert service.template("cpl").observed_coordinate_suffix == "mm"
    assert (profile.layer_token("top"), profile.layer_token("bottom")) == ("Top", "Bottom")
    assert service.template("cpl").observed_layer_tokens == {"top": "T", "bottom": "B"}

    board = _compiled(_service_board())
    package = ao.build_package(board, SERVICE_ID, name="svc")
    rows = list(csv.reader(package.files[package.cpl_file].splitlines()))
    header, first = rows[0], rows[1]
    assert first[header.index("Mid X")] == "10.0000"          # no unit suffix
    assert first[header.index("Layer")] == "Top"


# ---------------------------------------------------------------------------
# Loader: a declared rule must exist, and a difference must be explained.
# ---------------------------------------------------------------------------


def _written(tmp_path: Path, mutate=None, profile_id: str = SERVICE_ID) -> Path:
    """The shipped profile, optionally mutated, written where the loader will
    find it. Built from the SHIPPED file so a negative test cannot pass against
    a hand-made document that is already invalid for some other reason."""
    data = json.loads(SHIPPED.read_text(encoding="utf-8"))
    if mutate is not None:
        mutate(data)
    (tmp_path / f"{profile_id}.json").write_text(
        json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return tmp_path


def test_the_shipped_profile_loads_from_its_own_directory(tmp_path):
    assert sp.load_service_profile(
        SERVICE_ID, root=_written(tmp_path)).id == SERVICE_ID


def test_an_unexplained_header_difference_refuses(tmp_path):
    """Change what the emitter writes and leave the drift note behind: the load
    fails naming the position. This is what keeps a header edit from shipping
    without anybody comparing it to the house's own file."""
    def mutate(data):
        data["dialect"]["bom_columns"][0] = "Description"
    with pytest.raises(sp.ServiceProfileError, match="drift"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_a_drift_note_for_a_column_that_agrees_refuses(tmp_path):
    """The other direction. A stale note would keep a question open that the
    house already answered."""
    def mutate(data):
        data["templates"][1]["drift"] = [
            {"position": 0, "template": "Designator", "emitted": "Designator",
             "note": "stale"}]
    with pytest.raises(sp.ServiceProfileError, match="agree"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_a_declared_rule_with_no_code_behind_it_refuses(tmp_path):
    def mutate(data):
        data["checked_rules"].append("assembly_service_component_height")
    with pytest.raises(sp.ServiceProfileError,
                       match="lies about being in force"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_an_implemented_check_cannot_be_listed_as_unchecked(tmp_path):
    def mutate(data):
        data["unchecked_rules"].append(
            {"id": sp.CODE_SIDE_UNSUPPORTED, "reason": "we did not get to it"})
    with pytest.raises(sp.ServiceProfileError, match="as unchecked"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_an_unchecked_rule_without_a_reason_refuses(tmp_path):
    def mutate(data):
        data["unchecked_rules"].append({"id": "solder_paste_volume", "reason": " "})
    with pytest.raises(sp.ServiceProfileError, match="no reason"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_an_unknown_top_level_field_refuses(tmp_path):
    def mutate(data):
        data["lead_time_days"] = 3
    with pytest.raises(sp.ServiceProfileError, match="lead_time_days"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_a_file_declaring_another_id_refuses(tmp_path):
    def mutate(data):
        data["id"] = "jlcpcb-standard"
    with pytest.raises(sp.ServiceProfileError, match="does not match"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_a_digest_that_is_not_a_sha256_refuses(tmp_path):
    """A pin whose digest was typed rather than measured is a pin that did not
    happen."""
    def mutate(data):
        data["templates"][0]["sha256"] = "not-a-digest"
    with pytest.raises(sp.ServiceProfileError, match="actually fetched"):
        sp.load_service_profile(SERVICE_ID, root=_written(tmp_path, mutate))


def test_an_unknown_service_profile_refuses_by_name(tmp_path):
    with pytest.raises(sp.ServiceProfileError, match="jlcpcb-nonexistent"):
        sp.load_service_profile("jlcpcb-nonexistent", root=tmp_path)


# ---------------------------------------------------------------------------
# Selecting the service: what refuses, and what only advises.
# ---------------------------------------------------------------------------


def test_a_board_compiled_against_another_fab_profile_refuses_by_name():
    """THE MISMATCH ORACLE. The board below is identical to the service board
    except that it takes the compiler's default floor instead of the one the
    service pins. It must not export: an order package that emits here has
    relabelled a board nobody checked against JLCPCB's numbers as ready to send
    them."""
    board = _service_board()
    del board["design_rules"]["rule_profile"]
    compiled = _compiled(board)
    with pytest.raises(ag.AssemblyGateError) as exc_info:
        ao.build_package(compiled, SERVICE_ID)
    error = exc_info.value
    assert error.code == sp.CODE_FAB_PROFILE_MISMATCH
    message = str(error)
    assert "v1-fab-conservative" in message   # what the board was compiled against
    assert "jlcpcb-2layer" in message         # what the service requires
    assert error.field == "design_rules.rule_profile"


def test_the_dialect_only_selector_claims_no_tier():
    """The same board the service refuses exports under ``jlc``, which selects
    the CSV dialect and states nothing about a manufacturer. That is the
    honest-outcome half of the pair: a mid-layout quote export is legitimate,
    and it must not be dressed up as orderable."""
    board = _service_board()
    del board["design_rules"]["rule_profile"]
    result = ao.build_package(_compiled(board), "jlc")
    assert set(result.files) == {"board-bom-jlc.csv", "board-cpl-jlc.csv"}
    assert ao.PROFILES["jlc"].service is None
    assert result.emission.unchecked == ()


def test_bottom_side_population_blocks_and_does_not_merely_advise():
    """THE BLOCKER ORACLE. Economic places on one side. A populated bottom-side
    part must REFUSE, naming the designator — not ride back in ``advisories``,
    where a person scanning an export panel can pass over it and pay."""
    board = _service_board()
    board["components"][1]["layer"] = "bottom"
    with pytest.raises(ag.AssemblyGateError) as exc_info:
        ao.build_package(_compiled(board), SERVICE_ID)
    error = exc_info.value
    assert error.code == sp.CODE_SIDE_UNSUPPORTED
    assert "R2" in str(error)
    assert error.refs == ("R2",)


def test_a_bottom_side_part_nobody_places_is_not_a_blocker():
    """Scoped to POPULATED parts. Board furniture on the underside does not make
    a single-sided tier impossible, and refusing it would make the blocker
    useless on any board with a bottom-side fiducial."""
    board = _service_board()
    board["components"].append(
        {"ref": "FID1", "footprint": "Minerva_Fixture:FID_Circle_1mm", "value": "",
         "x_mm": 5.0, "y_mm": 5.0, "rotation_deg": 0, "layer": "bottom",
         "assembly": {"populate": False}})
    result = ao.build_package(_compiled(board), SERVICE_ID)
    assert result.emission.excluded_refs == ("FID1",)


def test_a_board_under_the_tiers_minimum_size_refuses():
    board = _service_board(width_mm=8, height_mm=8)
    board["components"] = [board["components"][0]]
    board["components"][0].update({"x_mm": 4.0, "y_mm": 4.0})
    with pytest.raises(ag.AssemblyGateError) as exc_info:
        ao.build_package(_compiled(board), SERVICE_ID)
    assert exc_info.value.code == sp.CODE_BOARD_SIZE_UNSUPPORTED
    assert "8 x 8" in str(exc_info.value)


def test_a_part_near_the_rim_advises_and_still_exports():
    """JLCPCB's own verb for its 0.3 mm figure is "suggest", and the board is
    still buildable, so this reports and does not refuse. The finding names the
    component, and the export produces both files."""
    board = _service_board()
    # R_0805's lands reach 1.45 mm either side of its origin, so an origin at
    # 1.5 leaves the body 0.05 mm from the rim and still fully on the board:
    # the finding must come from the guidance figure, not from a part hanging
    # over the edge.
    board["components"][0]["x_mm"] = 1.5
    result = ao.build_package(_compiled(board), SERVICE_ID)
    assert len(result.files) == 2
    findings = [item for item in result.emission.advisories
                if item["code"] == sp.ADVISORY_COMPONENT_TO_EDGE]
    assert [item["component"] for item in findings] == ["R1"]
    assert "0.3" in findings[0]["message"]


def test_a_clear_board_raises_no_edge_advisory():
    """The negative control for the test above: without it, an advisory that
    fired on every board would look like a working check."""
    result = ao.build_package(_compiled(_service_board()), SERVICE_ID)
    assert sp.ADVISORY_COMPONENT_TO_EDGE not in _codes(result)


def test_the_tooling_hole_possibility_rides_on_every_service_export():
    """JLCPCB adds two to three NPTH tooling holes to Economic boards after
    upload. Nothing in the board says whether that will collide with anything,
    so the possibility is raised unconditionally and belongs on the checklist —
    it is a physical modification the package does not describe."""
    result = ao.build_package(_compiled(_service_board()), SERVICE_ID)
    holes = [item for item in result.emission.advisories
             if item["code"] == sp.ADVISORY_TOOLING_HOLES]
    assert len(holes) == 1
    assert "1.152" in holes[0]["message"]


def test_the_unchecked_list_reaches_the_caller_with_reasons():
    """THE UNCHECKED ORACLE. A clean export must still say what nobody looked
    at. Board thickness is the sharpest case: the tier publishes 0.8-1.6 mm and
    the compiled IR states no thickness at all, so there is nothing to compare —
    which a reader has no way to know unless the export says so."""
    result = ao.build_package(_compiled(_service_board()), SERVICE_ID)
    unchecked = {rule["id"]: rule["reason"] for rule in result.emission.unchecked}
    assert "board_thickness_0p8_to_1p6mm" in unchecked
    assert "order_quantity_2_to_50_pcs" in unchecked
    assert "quote_page_acceptance" in unchecked
    assert all(reason.strip() for reason in unchecked.values())


def test_every_published_figure_the_profile_records_is_either_checked_or_named():
    """The two lists together are the profile's coverage claim, and this is the
    seal that keeps them from drifting apart: a code may appear in exactly one
    of checked/advisory, and no id may appear in both a rule list and the
    unchecked list."""
    profile = sp.load_service_profile(SERVICE_ID)
    enforced = set(profile.checked_rules) | set(profile.advisory_rules)
    named = {rule["id"] for rule in profile.unchecked_rules}
    assert enforced <= set(sp.IMPLEMENTED_CHECKS)
    assert not (enforced & named)
    assert not (set(profile.checked_rules) & set(profile.advisory_rules))


def test_the_identity_refusal_code_matches_its_error_class():
    """``service_profile`` spells the identity refusal's code rather than
    importing it, because ``assembly_outputs`` loads its profile at import and
    the dependency has to run one way. This is the seal that keeps the two
    spellings from drifting."""
    assert sp.CODE_MISSING_IDENTITY == ao.AssemblyIdentityError.code


def test_every_gate_that_runs_for_this_service_is_claimed_as_checked():
    """The coverage claim must not understate either. Every gate the export
    lane runs for a service selection appears in ``checked_rules``, so a reader
    counting what is enforced counts the same set the code runs."""
    claimed = set(sp.load_service_profile(SERVICE_ID).checked_rules)
    running = {
        sp.CODE_FAB_PROFILE_MISMATCH, sp.CODE_SIDE_UNSUPPORTED,
        sp.CODE_BOARD_SIZE_UNSUPPORTED, sp.CODE_MISSING_IDENTITY,
        ag.CODE_REFERENCE_SET_MISMATCH, ag.CODE_DUPLICATE_DESIGNATOR,
        ag.CODE_ROW_REF_LIMIT, ag.CODE_NON_METRIC_COORDINATES,
        ag.CODE_PLACEMENTS_TOO_CLOSE, ag.CODE_EMPTY_EXPANSION,
        ag.CODE_PASTE_UNDECIDED,
    }
    assert claimed == running


def test_the_service_dialect_is_what_the_gates_compare_against():
    """The three parameters the gates read by name come from the pinned file, so
    changing a published limit is a data edit. Measured against the file rather
    than against the module defaults, which is what would hide a profile that
    silently pinned nothing."""
    profile = ao.PROFILES[SERVICE_ID]
    dialect = sp.load_service_profile(SERVICE_ID).dialect
    assert profile.max_refs_per_row == dialect["max_refs_per_row"] == 200
    assert profile.min_designator_separation_mm == 0.2
    assert profile.coordinate_unit == "mm"
    assert profile.house_part_id == "jlcpcb"
    assert profile.identity_required == ("mpn",)


def test_both_selectors_emit_the_same_files_for_a_service_ready_board():
    """The tier changes what is CLAIMED, never what is written. If the two ever
    emitted different bytes there would be two dialects again."""
    board = _compiled(_service_board())
    service_package = ao.build_package(board, SERVICE_ID, name="svc")
    dialect_package = ao.build_package(board, "jlc", name="svc")
    assert service_package.files == dialect_package.files
