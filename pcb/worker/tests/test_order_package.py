"""The order package: one action, one compilation, six artifacts, and an honest
statement of what was established.

THE ORACLES, named, because each of these turns on a different one:

  * THE ARCHIVE ALLOWLIST. ``gerbers.zip`` may contain fabrication files and
    nothing else. The failure this catches is a document riding along inside the
    archive: a house's uploader is entitled to reject that, and entitled to do
    it after payment. Read back out of the ARCHIVE BYTES, never off the dict
    that was handed to the builder.
  * INDEPENDENT PARSING. Every Gerber and drill member is re-read with
    gerbonara — a different library from the one that wrote it. An emitter that
    validates its own output proves nothing about whether a house can read it.
  * REPLAY. The digests the manifest records must reproduce when the same inputs
    are built again. The failure this catches is a manifest that describes a run
    rather than a design: a clock, a set iteration order or a host path leaking
    into an artifact.
  * READINESS. The failure this catches is the tempting one — reporting a
    package as orderable because serialization succeeded. ``order_page_verified``
    has no writer, and a blocked board produces no files at all.
  * ALL-OR-NOTHING. A half-written package is worse than none, because its
    manifest describes files that are not there and somebody can still upload
    it.

A NOTE ON THE FIXTURES. Boards are built as dicts in-test, the way the other
assembly suites do it: each shape below differs from the base in ONE fact, and a
YAML file per fact would hide which one is under test.
"""

from __future__ import annotations

import json
import os
import stat
import zipfile
from io import BytesIO

import pytest

from pcb_worker import compile_board as compile_board_module
from pcb_worker import methods
from pcb_worker import order_package as op
from pcb_worker import order_provenance as prov
from pcb_worker import order_write
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

SERVICE = "jlcpcb-economic"
DIALECT_ONLY = "jlc"
BOARD_NAME = "OrderPkg"


def _board(**overrides) -> dict:
    """A board the Economic tier can build: two copper layers, compiled against
    the fabrication profile the service pins, both parts populated on the top
    side and clear of the rim."""
    board = {
        "version": 1, "name": BOARD_NAME, "width_mm": 30, "height_mm": 20,
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
    silently stop testing the package at all."""
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "board did not compile: "
            + ", ".join(f"{d.code} on {d.source_ref.entity_id if d.source_ref else '?'}"
                        for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def _package(board: dict | None = None, profile: str = SERVICE, **kwargs):
    source = _board() if board is None else board
    return op.build(source, _compiled(source), profile, **kwargs)


def _members(package) -> tuple[str, ...]:
    return op.archive_members(package.files[op.GERBER_ARCHIVE])


# ---------------------------------------------------------------------------
# The layout.
# ---------------------------------------------------------------------------


def test_the_package_emits_exactly_the_named_layout():
    """Six artifacts under one directory named for the board and the profile.
    A package with a file nobody expected is a package a reader cannot check."""
    package = _package()
    assert package.directory == f"{BOARD_NAME}-{SERVICE}"
    assert set(package.files) == {
        op.GERBER_ARCHIVE, op.BOM_FILE, op.CPL_FILE,
        op.CHECKLIST_FILE, op.PREFLIGHT_FILE, op.MANIFEST_FILE}


def test_every_output_but_the_manifest_carries_a_digest():
    """A file cannot record its own hash, and pretending otherwise would put a
    value in the manifest that no reader could ever reproduce. Every other
    artifact is digested, and the manifest says out loud why it is not."""
    package = _package()
    recorded = {item["file"]: item["sha256"]
                for item in package.manifest["package"]["outputs"]}
    assert set(recorded) == set(package.files) - {op.MANIFEST_FILE}
    for name, sha in recorded.items():
        assert sha == op.digest(package.files[name]), name
    assert package.manifest["package"]["self"]["sha256"] is None


# ---------------------------------------------------------------------------
# The archive allowlist.
# ---------------------------------------------------------------------------


def test_the_archive_holds_fabrication_files_and_nothing_else():
    """THE ALLOWLIST ORACLE, read back out of the archive bytes."""
    package = _package()
    members = _members(package)
    assert members, "the archive is empty"
    for name in members:
        assert name.endswith(op.ARCHIVE_ALLOWED_SUFFIXES), name
    assert any(name.endswith(".gbr") for name in members)
    assert any(name.endswith(".gbrjob") for name in members)


def test_the_package_documents_sit_beside_the_archive_not_inside_it():
    """The manifest, the checklist and the preflight report are for a person,
    and a house's ordering guidance says non-Gerber statements inside a
    fabrication archive are ignored."""
    package = _package()
    members = set(_members(package))
    for name in (op.MANIFEST_FILE, op.PREFLIGHT_FILE, op.CHECKLIST_FILE,
                 op.BOM_FILE, op.CPL_FILE):
        assert name not in members


def test_a_file_outside_the_allowlist_refuses_the_package_by_name():
    """The contract, not the convention: an artifact that is not a fabrication
    file stops the archive rather than riding along inside it."""
    with pytest.raises(op.OrderPackageError) as caught:
        op.build_archive({"board-F_Cu.gbr": "%FS%", "README.md": "hello"})
    assert caught.value.code == op.CODE_ARCHIVE_CONTENT
    assert "README.md" in str(caught.value)


def test_an_archive_member_may_not_be_a_path():
    """A member name carrying a separator would unpack outside the directory a
    house extracts into."""
    with pytest.raises(op.OrderPackageError) as caught:
        op.build_archive({"nested/board-F_Cu.gbr": "%FS%"})
    assert caught.value.code == op.CODE_ARCHIVE_CONTENT


def test_an_empty_archive_refuses_rather_than_shipping_nothing():
    """A zip with no layers in it is a fabrication order for no board."""
    with pytest.raises(op.OrderPackageError) as caught:
        op.build_archive({})
    assert caught.value.code == op.CODE_ARCHIVE_INCOMPLETE


def test_the_archive_carries_every_emitted_fabrication_file():
    """The allowlist must not become a silent filter. Every file the emitter
    produced is in the archive; the check refuses extras, it does not drop
    them."""
    from pcb_worker import gerber
    board = _board()
    emitted = set(gerber.build_gerbers_ir(_compiled(board)))
    assert set(_members(_package(board))) == emitted


# ---------------------------------------------------------------------------
# Independent parsing.
# ---------------------------------------------------------------------------


def test_every_archived_layer_parses_with_an_independent_reader():
    """Each Gerber and each drill file is re-read with gerbonara — a different
    library from the gerber_writer that wrote them. An emitter that only its own
    reader understands is not a fabrication file."""
    pytest.importorskip("gerbonara")
    from gerbonara import ExcellonFile, GerberFile

    package = _package()
    with zipfile.ZipFile(BytesIO(package.files[op.GERBER_ARCHIVE])) as archive:
        contents = {name: archive.read(name).decode("utf-8")
                    for name in archive.namelist()}
    for name, text in contents.items():
        if name.endswith(".gbr"):
            parsed = GerberFile.from_string(text, filename=name)
            assert parsed is not None, name
        elif name.endswith(".drl"):
            parsed = ExcellonFile.from_string(text, filename=name)
            assert parsed is not None, name


# ---------------------------------------------------------------------------
# Replay.
# ---------------------------------------------------------------------------


def test_the_recorded_digests_reproduce_on_a_second_build():
    """THE REPLAY ORACLE. Build the same inputs again and the digests the first
    manifest recorded must still be the digests of the files. A clock, a set
    iteration order or a host path leaking into an artifact fails here."""
    board = _board()
    first = _package(board)
    second = _package(board)
    recorded = {item["file"]: item["sha256"]
                for item in first.manifest["package"]["outputs"]}
    for name, sha in recorded.items():
        assert op.digest(second.files[name]) == sha, name


def test_only_the_manifest_differs_between_two_builds():
    """The manifest carries the export time, and it is the ONLY artifact that
    carries a clock. Everything a house is sent, and everything digested, is
    byte-identical."""
    board = _board()
    first = _package(board)
    second = _package(board)
    for name in set(first.files) - {op.MANIFEST_FILE}:
        assert first.files[name] == second.files[name], name


def test_the_archive_is_byte_identical_across_builds():
    """Zip metadata is the classic determinism leak: member order, timestamps
    and host permissions all come from the machine unless they are pinned."""
    board = _board()
    assert (_package(board).files[op.GERBER_ARCHIVE]
            == _package(board).files[op.GERBER_ARCHIVE])


# ---------------------------------------------------------------------------
# One compilation.
# ---------------------------------------------------------------------------


def test_a_package_build_compiles_the_board_once(monkeypatch, tmp_path):
    """ONE COMPILATION FEEDS EVERY ARTIFACT. Two compilations could describe two
    boards — a library layer or a blessed footprint moving in between is enough
    — while every gate inside each one still passed.

    Counted by wrapping the real compiler rather than replacing it: the board
    still compiles for real, and what is measured is how many times."""
    calls = []
    real = compile_board_module.compile_board

    def counting(*args, **kwargs):
        calls.append(1)
        return real(*args, **kwargs)

    monkeypatch.setattr(compile_board_module, "compile_board", counting)
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": _board(), "profile": SERVICE,
                   "out_dir": str(tmp_path)}})
    assert reply["ok"] is True, reply
    assert len(calls) == 1, f"the board compiled {len(calls)} times"


# ---------------------------------------------------------------------------
# Readiness.
# ---------------------------------------------------------------------------


def test_order_page_verified_is_never_set_by_an_export():
    """THE THIRD STATE IS NOT INFERABLE. It records that a person uploaded these
    files and read the quote page; nothing offline can establish it. The reply
    below asks for it explicitly, which is the shape of the mistake this
    guards."""
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": _board(), "profile": SERVICE,
                   "order_page_verified": True,
                   "readiness": {"order_page_verified": True}}})
    assert reply["ok"] is True, reply
    result = reply["result"]
    assert result["readiness"]["order_page_verified"] is None
    assert result["preflight"]["readiness"]["order_page_verified"] is None

    package = _package()
    assert package.manifest["readiness"]["order_page_verified"] is None
    assert package.preflight["readiness"]["order_page_verified"] is None
    assert json.loads(package.files[op.PREFLIGHT_FILE])["readiness"][
        "order_page_verified"] is None


def test_a_generated_package_claims_generation_and_nothing_more():
    """``package_generated`` is what serialization proves. It is not
    ``orderable``, and the preflight status beside it is about the checks that
    ran, not about a house's opinion."""
    package = _package()
    readiness = package.preflight["readiness"]
    assert readiness["package_generated"] is True
    assert readiness["preflight_status"] in (op.PREFLIGHT_PASS,
                                             op.PREFLIGHT_ADVISORIES)
    assert "order_page_verified" in readiness["order_page_verified_note"]


def test_absent_provenance_is_an_advisory_and_still_produces_a_package():
    """The board carries no design revision, which is the state EVERY board is
    in until the authoring pass runs. Advisory, package produced."""
    package = _package()
    codes = {item["code"] for item in package.advisories}
    assert prov.ADVISORY_ABSENT in codes
    assert package.preflight["status"] == op.PREFLIGHT_ADVISORIES
    assert package.preflight["readiness"]["package_generated"] is True


def test_a_stale_design_revision_blocks_the_package():
    """The one provenance refusal: the silkscreen names a design these files are
    not. Reported as a BLOCKED preflight with nothing generated."""
    board = _board(board_graphics=[{
        "layer": "F.SilkS", "kind": "text",
        "text": prov.provenance_text(BOARD_NAME, "rev-b", "deadbeef"),
        "position": {"x_mm": 5.0, "y_mm": 5.0}, "size_mm": 1.0}])
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": board, "profile": SERVICE}})
    assert reply["ok"] is False
    error = reply["error"]
    assert error["code"] == "assembly_provenance_mismatch"
    assert error["preflight"]["status"] == op.PREFLIGHT_BLOCKED
    assert error["preflight"]["readiness"]["package_generated"] is False
    assert error["preflight"]["readiness"]["order_page_verified"] is None


def test_a_service_blocker_produces_no_files_at_all(tmp_path):
    """A populated part on a side the Economic tier does not place. The tier
    will not build the board, so there is nothing to write — and the refusal
    must not leave a directory behind for somebody to upload."""
    board = _board()
    board["components"][1]["layer"] = "bottom"
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": board, "profile": SERVICE,
                   "out_dir": str(tmp_path)}})
    assert reply["ok"] is False
    assert reply["error"]["preflight"]["status"] == op.PREFLIGHT_BLOCKED
    assert list(tmp_path.iterdir()) == []


def test_an_uncompilable_board_blocks_before_anything_is_emitted(tmp_path):
    """The package is derived from a strict compilation, so a board that does
    not compile yields no package — named, with the blockers listed."""
    board = _board()
    board["components"][0]["footprint"] = "NoSuchLib:NoSuchPart"
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": board, "profile": SERVICE,
                   "out_dir": str(tmp_path)}})
    assert reply["ok"] is False
    assert reply["error"]["kind"] == "assembly_not_compilable"
    assert reply["error"]["preflight"]["status"] == op.PREFLIGHT_BLOCKED
    assert list(tmp_path.iterdir()) == []


def test_the_package_names_what_nothing_looked_at():
    """A clean export that names nothing it skipped is a lie by omission. The
    service profile's own unchecked list rides along, and so do the two this
    package adds: nobody proved a house's uploader accepts the archive, and
    nobody formed an opinion about a licence."""
    package = _package()
    rules = {item.get("id") for item in package.unchecked}
    assert op.UNCHECKED_UPLOADER["id"] in rules
    assert op.UNCHECKED_LICENCE["id"] in rules
    assert all(item.get("id") and item.get("reason")
               for item in package.unchecked), "one shape, one reader"
    assert len(package.unchecked) > 2, "the service profile's own list is missing"


# ---------------------------------------------------------------------------
# The manifest's own consistency.
# ---------------------------------------------------------------------------


def test_the_placement_map_and_the_cpl_name_the_same_parts():
    """The manifest's logical-to-physical map is what a reader uses to explain
    a CPL row. If the two disagree, one of them is describing a different
    walk of the board."""
    package = _package()
    cpl = package.files[op.CPL_FILE].strip().splitlines()[1:]
    emitted = {line.split(",")[0] for line in cpl}
    mapped = {physical["ref"]
              for entry in package.manifest["placements"] if entry["populate"]
              for physical in entry["physical"]}
    assert mapped == emitted


def test_the_manifest_records_the_pins_the_profile_was_selected_for():
    """A package that does not say which profile, which fabrication rules and
    which pinned templates produced it cannot be reproduced a month later."""
    package = _package()
    record = package.manifest["profile"]
    assert record["selector"] == SERVICE
    assert record["service"]["fab_profile"] == "jlcpcb-2layer"
    assert {pin["artifact"] for pin in record["service"]["templates"]} == {"bom", "cpl"}
    assert all(pin["sha256"] for pin in record["service"]["templates"])
    assert package.manifest["tools"]["worker"]


def test_a_dialect_only_export_says_it_claims_no_tier():
    """The honest shape for a mid-layout quote export: the same CSV dialect with
    no manufacturer claim. A package that looked identical to a tier-checked one
    would be the lie the readiness states exist to prevent."""
    package = _package(profile=DIALECT_ONLY)
    assert package.manifest["profile"]["service"] is None
    assert "no manufacturing tier" in package.manifest["profile"]["service_note"]
    assert package.directory == f"{BOARD_NAME}-{DIALECT_ONLY}"


def test_git_state_is_unavailable_rather_than_guessed_for_an_inline_board():
    """A board handed over inline has no repository. Saying so by name is the
    honest answer; a blank field reads as "clean"."""
    package = _package()
    assert package.manifest["source"]["git"]["available"] is False
    assert package.manifest["source"]["git"]["reason"]


# ---------------------------------------------------------------------------
# All-or-nothing writes.
# ---------------------------------------------------------------------------


def test_a_written_package_is_whole(tmp_path):
    """Every artifact lands, under the package directory, with the bytes the
    manifest digested."""
    package = _package()
    written = package.write(tmp_path)
    directory = tmp_path / package.directory
    assert {p.name for p in directory.iterdir()} == set(package.files)
    assert len(written) == len(package.files)
    recorded = {item["file"]: item["sha256"]
                for item in package.manifest["package"]["outputs"]}
    for name, sha in recorded.items():
        data = (directory / name).read_bytes()
        assert op.digest(data) == sha, name


def test_writing_over_an_existing_package_refuses_unless_asked(tmp_path):
    """An existing package may already have been uploaded. Replacing it silently
    would leave a person holding files that no longer match what they sent."""
    package = _package()
    package.write(tmp_path)
    with pytest.raises(order_write.OrderWriteError):
        package.write(tmp_path)
    package.write(tmp_path, overwrite=True)
    assert (tmp_path / package.directory / op.MANIFEST_FILE).exists()


def test_an_overwrite_that_cannot_start_leaves_the_previous_package_intact(tmp_path):
    """The package is staged in a sibling directory and moved into place in ONE
    step, so a failure before that step cannot disturb what is already there.
    Provoked with a real filesystem condition — a parent nobody may write to —
    rather than by standing in for one."""
    if os.geteuid() == 0:
        pytest.skip("root ignores directory permissions, so nothing can fail here")
    package = _package()
    package.write(tmp_path)
    marker = tmp_path / package.directory / "already-uploaded.txt"
    marker.write_text("keep me", encoding="utf-8")

    mode = stat.S_IMODE(os.stat(tmp_path).st_mode)
    os.chmod(tmp_path, 0o500)
    try:
        with pytest.raises(order_write.OrderWriteError):
            package.write(tmp_path, overwrite=True)
    finally:
        os.chmod(tmp_path, mode)
    assert marker.read_text(encoding="utf-8") == "keep me"
    assert {p.name for p in (tmp_path / package.directory).iterdir()} == (
        set(package.files) | {"already-uploaded.txt"})


def test_no_staging_directory_survives_a_successful_write(tmp_path):
    """A leftover staging directory beside the package is another thing a person
    could pick up by mistake."""
    package = _package()
    package.write(tmp_path)
    assert [p.name for p in tmp_path.iterdir()] == [package.directory]


def test_a_refused_artifact_name_touches_nothing(tmp_path):
    """The loose-file writer used by the two-CSV path checks every name before
    any byte is written, so a caller error cannot leave one file of a pair."""
    with pytest.raises(order_write.OrderWriteError):
        order_write.write_files(tmp_path, {"bom.csv": "a", "sub/cpl.csv": "b"})
    assert list(tmp_path.iterdir()) == []


def test_the_loose_writer_publishes_every_file_or_none(tmp_path):
    """The ordinary path still works: both files land, with their bytes."""
    written = order_write.write_files(tmp_path, {"bom.csv": "a", "cpl.csv": "bb"})
    assert [item["bytes_written"] for item in written] == [1, 2]
    assert (tmp_path / "bom.csv").read_text(encoding="utf-8") == "a"
    assert not [p for p in tmp_path.iterdir() if p.name.endswith(".part")]


# ---------------------------------------------------------------------------
# The checklist.
# ---------------------------------------------------------------------------


def test_the_checklist_carries_the_choices_no_uploaded_file_encodes():
    """Gerbers describe copper. Quantity, finish, colour, tier and consent to a
    house drilling extra holes are chosen on a web form, and an order nobody
    wrote those down for cannot be repeated."""
    text = _package().files[op.CHECKLIST_FILE]
    for prompt in ("Quantity", "Surface finish", "Solder-mask colour",
                   "PCBA tier and side", "Confirm production file",
                   "Tooling holes reviewed"):
        assert prompt in text, prompt


def test_the_checklist_is_the_only_place_the_quote_page_result_is_recorded():
    """The third readiness state is a form a person fills in. That is the whole
    mechanism: there is no field for it anywhere a program writes."""
    text = _package().files[op.CHECKLIST_FILE]
    assert "Quote-page record (a person fills this in)" in text
    assert "Order number" in text
    assert op.ORDER_PAGE_NOTE.split(".")[0] in text


def test_the_checklist_digests_are_the_files_a_person_uploads():
    """A person checking what they sent needs the three upload artifacts by
    digest — and needs to be told the archive is not a place for documents."""
    package = _package()
    text = package.files[op.CHECKLIST_FILE]
    for name in (op.GERBER_ARCHIVE, op.BOM_FILE, op.CPL_FILE):
        assert package.digests[name] in text, name
    upload_section = text.split("## Upload these")[1].split("\n## ")[0]
    assert op.MANIFEST_FILE not in upload_section
    assert "fabrication files only" in upload_section


# ---------------------------------------------------------------------------
# IP questions.
# ---------------------------------------------------------------------------


def test_an_undeclared_licence_is_one_question_naming_the_footprints():
    """The exporter surfaces licence questions rather than shipping past them,
    and it surfaces ONE: the answer is a single decision about where the library
    came from, and forty identical lines is a list nobody reads."""
    package = _package()
    assert len(package.ip_questions) <= 1
    if package.ip_questions:
        question = package.ip_questions[0]
        assert question["code"] == "ip_licence_undeclared"
        assert question["footprints"]
        assert package.preflight["status"] == op.PREFLIGHT_ADVISORIES
        assert question["message"] in package.files[op.CHECKLIST_FILE]
    assert "licences" in package.manifest


# ---------------------------------------------------------------------------
# The RPC.
# ---------------------------------------------------------------------------


def test_the_rpc_writes_the_package_and_reports_a_digest_per_output(tmp_path):
    """The single action, end to end: one call produces the directory on disk
    and a reply naming every artifact with the digest that was written."""
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": _board(), "profile": SERVICE,
                   "out_dir": str(tmp_path)}})
    assert reply["ok"] is True, reply
    result = reply["result"]
    directory = tmp_path / result["directory"]
    assert {p.name for p in directory.iterdir()} == {
        op.GERBER_ARCHIVE, op.BOM_FILE, op.CPL_FILE,
        op.CHECKLIST_FILE, op.PREFLIGHT_FILE, op.MANIFEST_FILE}
    assert {item["file"] for item in result["outputs"]} == {p.name for p in directory.iterdir()}
    for item in result["outputs"]:
        if item["sha256"] is None:
            assert item["file"] == op.MANIFEST_FILE
            continue
        assert op.digest((directory / item["file"]).read_bytes()) == item["sha256"]
    assert len(result["written"]) == 6
    assert result["readiness"]["order_page_verified"] is None
