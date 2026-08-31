"""The order package: one action, one compilation, seven artifacts, and an
honest statement of what was established.

THE ORACLES, named, because each of these turns on a different one:

  * THE ARCHIVE ALLOWLIST. ``gerbers.zip`` may contain fabrication files and
    nothing else. The failure this catches is a document riding along inside the
    archive: a house's uploader is entitled to reject that, and entitled to do
    it after payment. Read back out of the ARCHIVE BYTES, never off the dict
    that was handed to the builder.
  * INDEPENDENT PARSING. Every Gerber and drill member is re-read with
    gerbonara — a different library from the one that wrote it. An emitter that
    validates its own output proves nothing about whether a house can read it.
    This gate does NOT skip when gerbonara is absent. It used to, and a skip
    here deletes the only opinion in this suite that did not come from the code
    under test: on a machine without the library, malformed fabrication files
    left the run green.
  * REPLAY. The digests the manifest records must reproduce when the same inputs
    are built again. The failure this catches is a manifest that describes a run
    rather than a design: a clock, a set iteration order or a host path leaking
    into an artifact.
  * READINESS. The failure this catches is the tempting one — reporting a
    package as orderable because serialization succeeded. ``order_page_verified``
    has no writer, and a blocked board produces no files at all. ``pass`` is
    also refused over a WARNING: a package whose own list records a dropped
    drill is not a complete rendering of the board.
  * PROVENANCE IS BOUND TO THE BOARD. ``source_path`` is caller input and the
    git record is evidence, so the file has to parse to the very board being
    packaged before a revision is read off its repository. The failure this
    catches is a path into an unrelated clean repository lending that
    repository's revision to this design.
  * ALL-OR-NOTHING. A half-written package is worse than none, because its
    manifest describes files that are not there and somebody can still upload
    it. Including the bytes of a file a failed write would have replaced: a new
    BOM beside yesterday's CPL is a mismatched pair that reads as fine.
  * NOTHING VANISHES. Every WARNING-channel diagnostic the one compilation and
    the one emission produced is in the manifest. The failure this catches is a
    package reporting `pass` over fabrication files the emitter dropped a
    feature from — the one artifact whose stated purpose is an honest account
    being the only surface that hides it.

A NOTE ON THE FIXTURES. Boards are built as dicts in-test, the way the other
assembly suites do it: each shape below differs from the base in ONE fact, and a
YAML file per fact would hide which one is under test.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import zipfile
from io import BytesIO

import pytest

from pcb_worker import compile_board as compile_board_module
from pcb_worker import gerber
from pcb_worker import methods
from pcb_worker import order_package as op
from pcb_worker import order_provenance as prov
from pcb_worker import order_write
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    Diagnostic, DiagnosticSeverity, EntityKind, ResolutionSuccess, SourceRef,
)

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


def _stamped_board(rev: str = "rev-a") -> dict:
    """The base board with its provenance silk stamped, which is what clears
    the absent-provenance advisory. Stamped in the two passes the projection
    exists to make safe: write the sentinel, hash, write the result back."""
    board = _board(board_graphics=[{
        "layer": "F.SilkS", "kind": "text",
        "text": prov.provenance_text(BOARD_NAME, rev, prov.DIGEST_SENTINEL),
        "position": {"x_mm": 5.0, "y_mm": 5.0}, "size_mm": 1.0}])
    board["board_graphics"][0]["text"] = prov.provenance_text(
        BOARD_NAME, rev, prov.source_digest(board))
    return board


def _git_repo(path) -> None:
    """A real repository with one commit and a clean tree."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    (path / "unrelated.txt").write_text("not a board\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.email=t@example.com",
                    "-c", "user.name=t", "commit", "-qm", "one"], check=True)


# ---------------------------------------------------------------------------
# The layout.
# ---------------------------------------------------------------------------


def test_the_package_emits_exactly_the_named_layout():
    """Seven artifacts under one directory named for the board and the profile.
    A package with a file nobody expected is a package a reader cannot check."""
    package = _package()
    assert package.directory == f"{BOARD_NAME}-{SERVICE}"
    assert set(package.files) == {
        op.GERBER_ARCHIVE, op.BOM_FILE, op.CPL_FILE, op.PREVIEW_FILE,
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
                 op.BOM_FILE, op.CPL_FILE, op.PREVIEW_FILE):
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


def test_the_archive_claim_describes_only_the_check_production_runs():
    """The package tells a reader what it did and did not establish about the
    archive, so that text has to match the code. It used to cite "the per-layer
    parse checks" beside the allowlist; ``check_archive_contents`` matches file
    suffixes and stops, and nothing on the build path re-reads a layer. The
    independent parse above is a TEST, and a package that credits itself with
    its suite's checks overstates itself exactly the way one that hides a
    finding understates itself."""
    reason = op.UNCHECKED_UPLOADER["reason"]
    assert "allowlist" in reason
    assert "parse checks" not in reason
    package = _package()
    shipped = {item["id"]: item["reason"] for item in package.unchecked}
    assert shipped[op.UNCHECKED_UPLOADER["id"]] == reason
    assert reason in package.files[op.CHECKLIST_FILE]


# ---------------------------------------------------------------------------
# Independent parsing.
# ---------------------------------------------------------------------------


def test_every_archived_layer_parses_with_an_independent_reader():
    """Each Gerber and each drill file is re-read with gerbonara — a different
    library from the gerber_writer that wrote them. An emitter that only its own
    reader understands is not a fabrication file.

    The import is UNGUARDED on purpose. A missing gerbonara fails this test; it
    does not quietly remove the only check here that the emitter did not write
    itself."""
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
    byte-identical — AND the manifest is not, which is the half that says the
    clock is really in there. Both builds pass an explicit ``generated_at`` so
    the difference is the stamp rather than a race with the wall clock: two
    builds inside one second used to produce identical manifests and this test
    would have passed over a manifest that carried no clock at all."""
    board = _board()
    first = _package(board, generated_at="2026-08-30T09:00:00Z")
    second = _package(board, generated_at="2026-08-30T09:00:01Z")
    for name in set(first.files) - {op.MANIFEST_FILE}:
        assert first.files[name] == second.files[name], name
    assert first.files[op.MANIFEST_FILE] != second.files[op.MANIFEST_FILE]
    assert first.manifest["generated_at"] != second.manifest["generated_at"]


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
# Warnings — both channels, or the package is not an honest account.
# ---------------------------------------------------------------------------

EMITTER_CODE = "synthetic_emitter_warning"


def _emitting_a_warning(monkeypatch):
    """The REAL emission, plus one diagnostic on the channel GerberResult
    carries for exactly this purpose.

    No seed footprint reaches that channel through the strict IR path today
    (test_methods_ir_fab records the same fact at the gerbers seam), so the
    collaborator is WRAPPED rather than replaced: the archive is still the
    emitter's own bytes and the only addition is the warning under test."""
    real = gerber.build_gerbers_ir

    def emitting(board, *args, **kwargs):
        result = real(board, *args, **kwargs)
        result.diagnostics.append(Diagnostic(
            DiagnosticSeverity.WARNING, EMITTER_CODE,
            "drill feature dropped: non-positive diameter",
            SourceRef(EntityKind.HOLE, "mounting_holes[0]", "(2, 20)")))
        return result

    monkeypatch.setattr(gerber, "build_gerbers_ir", emitting)


COMPILE_PROBE = {
    "severity": "warning", "code": "compile_probe",
    "message": "captured geometry was not emitted",
    "source_ref": {"entity_kind": "component", "entity_id": "R1",
                   "detail": None},
}


def test_the_manifest_records_both_warning_channels_in_the_bytes_it_ships(
        monkeypatch):
    """A FEATURE THE EMITTER DROPPED IS IN THE MANIFEST OR IT IS NOWHERE. The
    package reads its gerbers off one emission and nothing else re-emits them,
    so a silk primitive or drill feature that did not survive is recorded here
    or is lost — while a plain gerbers call on the same board reports it.

    Read out of the manifest FILE, because that is the byte string a person
    keeps. Both channels, in the order the gerbers reply merges them: what the
    emitter said, then what the compiler said."""
    _emitting_a_warning(monkeypatch)
    package = _package(compile_diagnostics=[COMPILE_PROBE])
    shipped = json.loads(package.files[op.MANIFEST_FILE])["checks"]["warnings"]
    assert [item["code"] for item in shipped] == [EMITTER_CODE, "compile_probe"]
    assert shipped[0]["source_ref"]["entity_id"] == "mounting_holes[0]"
    assert ([item["code"] for item in package.warnings]
            == [item["code"] for item in shipped])


def test_the_rpc_reply_says_what_the_manifest_says(monkeypatch, tmp_path):
    """A reply carrying less than the file it just wrote would hide the drop
    from the agent that asked for the package."""
    _emitting_a_warning(monkeypatch)
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": _board(), "profile": SERVICE,
                   "out_dir": str(tmp_path)}})
    assert reply["ok"] is True, reply
    written = json.loads(
        (tmp_path / reply["result"]["directory"] / op.MANIFEST_FILE)
        .read_text(encoding="utf-8"))
    assert reply["result"]["warnings"] == written["checks"]["warnings"]
    assert EMITTER_CODE in {item["code"] for item in reply["result"]["warnings"]}


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


def test_a_source_path_holding_another_board_lends_no_revision(tmp_path):
    """THE LAUNDERING CASE. ``source_path`` is caller input; the manifest's git
    block is evidence. Point one board at a file inside an unrelated, clean
    repository and the old code reported that repository's HEAD as this
    design's provenance — an unverifiable claim wearing the costume of a
    measurement. The path has to parse to THIS board first."""
    repo = tmp_path / "somebody-elses-repo"
    _git_repo(repo)
    package = _package(source_path=str(repo / "unrelated.txt"))
    git = package.manifest["source"]["git"]
    assert git["available"] is False
    assert "revision" not in git
    assert "different board" in git["reason"] or "does not parse" in git["reason"]


def test_a_source_path_holding_this_very_board_does_carry_the_revision(tmp_path):
    """The other half: binding the path is not a way of never reporting git.
    The board's own file, in a repository, still yields a revision — and the
    binding is the package's own projection, so a stamped file and the
    unstamped board it was stamped from bind alike."""
    import yaml

    repo = tmp_path / "this-boards-repo"
    _git_repo(repo)
    board = _board()
    source = repo / "board.yaml"
    source.write_text(yaml.safe_dump(board, sort_keys=False), encoding="utf-8")
    package = op.build(board, _compiled(board), SERVICE,
                       source_path=str(source))
    git = package.manifest["source"]["git"]
    assert git["available"] is True, git
    assert len(git["revision"]) == 40
    assert git["dirty"] is True  # board.yaml is untracked in that repo


def test_an_unreadable_source_path_says_so_rather_than_reaching_for_git(tmp_path):
    """A path nobody can read is a reason, not a silent absence."""
    package = _package(source_path=str(tmp_path / "no-such-file.yaml"))
    git = package.manifest["source"]["git"]
    assert git["available"] is False
    assert "could not be read" in git["reason"]


# ---------------------------------------------------------------------------
# What `pass` covers.
# ---------------------------------------------------------------------------


def test_a_dropped_feature_stops_the_package_reporting_pass():
    """A WARNING is the compiler or the emitter saying something about the board
    did not reach these files. Reporting `pass` beside a list that records a
    dropped drill is the one lie this whole package exists to stop telling, so
    the warning channel moves the status even though it never refuses.

    Driven off the DIALECT-ONLY profile with the provenance stamped, because
    that is the only shape whose advisory list is empty — over the tiered
    profile the house-tooling advisory already holds the status off `pass` and
    this contrast would be invisible."""
    board = _stamped_board()
    compiled = _compiled(board)
    clean = op.build(board, compiled, DIALECT_ONLY)
    assert clean.advisories == () and clean.warnings == ()
    assert clean.preflight["status"] == op.PREFLIGHT_PASS

    warned = op.build(board, compiled, DIALECT_ONLY,
                      compile_diagnostics=[COMPILE_PROBE])
    assert warned.preflight["status"] == op.PREFLIGHT_ADVISORIES
    assert warned.preflight["readiness"]["preflight_status"] == op.PREFLIGHT_ADVISORIES
    # The report has to account for the status it states, or a reader is sent
    # to look for an advisory that is not there.
    assert warned.preflight["warnings"] == [dict(COMPILE_PROBE)]


def test_pass_never_means_everything_was_checked():
    """Even `pass` ships a non-empty unchecked list — uploader acceptance and
    licence compatibility are on every package — so the status is a statement
    about the checks that ran and never about the ones that did not."""
    package = op.build(_stamped_board(), _compiled(_stamped_board()),
                       DIALECT_ONLY)
    assert package.preflight["status"] == op.PREFLIGHT_PASS
    ids = {item["id"] for item in package.preflight["unchecked"]}
    assert {op.UNCHECKED_UPLOADER["id"], op.UNCHECKED_LICENCE["id"]} <= ids


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


def test_a_publish_that_fails_part_way_puts_the_previous_bytes_back(tmp_path):
    """THE UNWIND, over CONTENT rather than names. The loose writer exists so a
    re-export cannot leave a new BOM beside yesterday's CPL — and a rename that
    fails part-way is exactly when that happens, because os.replace destroys the
    file it lands on and no unwind can conjure those bytes back.

    Provoked with a real filesystem condition, the way the package-overwrite
    test is: the second destination name is held by a non-empty DIRECTORY, which
    no rename of a file can replace."""
    (tmp_path / "bom.csv").write_text("yesterday's bom", encoding="utf-8")
    (tmp_path / "cpl.csv").mkdir()
    (tmp_path / "cpl.csv" / "occupied").write_text("x", encoding="utf-8")

    with pytest.raises(order_write.OrderWriteError):
        order_write.write_files(tmp_path, {"bom.csv": "today's bom",
                                           "cpl.csv": "today's cpl"})

    assert (tmp_path / "bom.csv").read_text(encoding="utf-8") == "yesterday's bom"
    assert (tmp_path / "cpl.csv").is_dir()
    assert not [p for p in tmp_path.iterdir() if p.name.startswith(".")]


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


def test_the_preview_is_drawn_from_the_packages_own_emission():
    """The preview is not a seventh opinion about the board: it is rendered from
    the SAME ``AssemblyEmission`` ``cpl.csv`` is written from, inside the one
    compilation the package is built on. This pins that its designators are the
    CPL's designators — the deeper oracle, cell for cell, is
    ``tests/test_assembly_preview.py``."""
    package = _package()
    preview = package.files[op.PREVIEW_FILE]
    rows = [line.split(",")[0]
            for line in package.files[op.CPL_FILE].split("\r\n")[1:] if line]
    assert rows
    for ref in rows:
        assert f'data-ref="{ref}"' in preview
    assert preview.count('class="placement"') == len(rows)


def test_the_preview_is_something_to_open_and_not_something_to_upload():
    """It is the one artifact in the package that is for us. The checklist has to
    put it BEFORE the upload step — after payment it is worth nothing — and the
    archive allowlist has to keep it out of the fabrication zip."""
    package = _package()
    text = package.files[op.CHECKLIST_FILE]
    upload_section = text.split("## Upload these")[1].split("\n## ")[0]
    assert op.PREVIEW_FILE not in upload_section
    assert "## Open this before you upload anything" in text
    assert package.digests[op.PREVIEW_FILE] in text
    with pytest.raises(op.OrderPackageError):
        op.build_archive({op.PREVIEW_FILE: "<svg/>"})


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
    and a reply naming every artifact with the digest that was written.

    EVERY artifact, order-manifest.json included. The manifest cannot record its
    own digest, but this reply is assembled after the manifest bytes are final,
    so there is nothing stopping it from hashing them — and a null here is a
    caller told to trust one file out of seven on the strength of the other
    six."""
    reply = methods.handle_request({
        "id": 1, "method": "order_package",
        "params": {"board": _board(), "profile": SERVICE,
                   "out_dir": str(tmp_path)}})
    assert reply["ok"] is True, reply
    result = reply["result"]
    directory = tmp_path / result["directory"]
    assert {p.name for p in directory.iterdir()} == {
        op.GERBER_ARCHIVE, op.BOM_FILE, op.CPL_FILE, op.PREVIEW_FILE,
        op.CHECKLIST_FILE, op.PREFLIGHT_FILE, op.MANIFEST_FILE}
    assert {item["file"] for item in result["outputs"]} == {p.name for p in directory.iterdir()}
    for item in result["outputs"]:
        assert item["sha256"], f"{item['file']} carries no digest"
        assert op.digest((directory / item["file"]).read_bytes()) == item["sha256"]
    manifest_entry = next(item for item in result["outputs"]
                          if item["file"] == op.MANIFEST_FILE)
    assert manifest_entry["sha256"] == op.digest(
        (directory / op.MANIFEST_FILE).read_bytes())
    assert len(result["written"]) == 7
    assert result["readiness"]["order_page_verified"] is None
