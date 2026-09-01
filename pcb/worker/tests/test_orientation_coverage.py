"""Is the ledger's coverage HONEST, and is the gap something a person can READ?

WHAT THIS SUITE IS FOR
----------------------
``test_orientation_ledger.py`` proves a measured offset survives. This suite
proves the thing next to it: that the set of footprints nobody has measured is
KNOWN, WRITTEN DOWN, and not quietly smaller than the truth.

Coverage has one cheap failure mode and one expensive one, and they pull in
opposite directions:

* the cheap one is an UNDER-COUNT — a footprint nobody measured stays unknown,
  an order that buys a part on it refuses by name, and somebody goes and
  measures it. Loud, recoverable, no board is harmed.
* the expensive one is a FALSE DECLARATION — a genuine purchasable package
  declared ``no_reference`` to clear the count. ``OrientationLedger.lookup``
  falls back to a footprint-wide declaration for ANY part bought on that ref,
  so such a row does not merely mis-state a number: it disarms the gate for
  every part placed on that drawing and ships the rotation unmeasured, exactly
  the silent default this whole line of work exists to stop.

So the suite is built asymmetrically ON PURPOSE. It never asserts that the
unknown list is short — it asserts that it is COMPLETE, that it is what the
emitter would actually refuse, and that every declaration standing in for a gap
is one a machine can still recognise as board furniture or an in-repo fixture
rather than a package somebody could buy.

THE ORACLES
-----------
1. **The acquisition lock.** It is the authority on what we ship, so it — not
   the ledger — decides which footprints are in scope. The report must
   PARTITION it: every shipped footprint in exactly one of measured, declared,
   unknown, with the rendered summary counting the same rows the fold does.
2. **The emitter itself.** The report claims the UNKNOWN list is the set of
   drawings an order can stop on. That claim is checked by compiling a board on
   one of them and watching ``assembly_outputs.emit`` refuse — and by compiling
   a board on a DECLARED one and watching it pass through untouched, which is
   the same fact from the dangerous side.
3. **The authored declarations file.** Every declared row in the shipped ledger
   must be present, verbatim, in ``pcb/library/part_orientation_declared.json``.
   That is what makes a declaration a thing a human wrote rather than a thing
   the artifact happens to contain.
4. **The lock's own provenance.** A declaration says nothing orderable is drawn
   like this. For every declaration but one deliberately-named piece of board
   furniture, the lock independently agrees: the drawing was SYNTHESIZED in
   this repo (``source_kind == "generated"``), so it cannot be a vendor package.

Offline and pure: the committed lock, the committed ledger, the committed
declarations, the committed report. No network, no clock. Boards are synthetic
and built from seed-library footprints; no product board appears here
(``test_corpus_policy.py`` enforces that by content).
"""

from __future__ import annotations

import importlib.util
import json

from pathlib import Path

import pytest

from pcb_worker import assembly_orientation as aor
from pcb_worker import assembly_outputs as ao
from pcb_worker import orientation_coverage as oc
from pcb_worker import orientation_ledger as ol
from pcb_worker import part_orientation as po
from pcb_worker.compile_board import compile_board
from pcb_worker.footprints import load_lockfile
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess

HERE = Path(__file__).resolve().parent
PCB = HERE.parents[1]
GEN_PATH = PCB / "scripts" / "gen_part_orientation.py"
VENDOR_DIR = HERE / "testdata" / "vendor_footprints"

HOUSE = "jlcpcb"


def _load_generator():
    """The generator is a script, not a package module — loaded the way
    ``test_orientation_ledger.py`` loads it, for the same reason: the CLI and
    the suite must derive the artifacts through ONE function."""
    spec = importlib.util.spec_from_file_location("gen_part_orientation", GEN_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def generator():
    return _load_generator()


@pytest.fixture(scope="module")
def lock() -> dict:
    return load_lockfile()


@pytest.fixture(scope="module")
def ledger() -> ol.OrientationLedger:
    """The SHIPPED ledger. Every assertion here is about the file that goes out
    with the plugin."""
    return ol.load_ledger()


@pytest.fixture(scope="module")
def report(ledger, lock) -> oc.CoverageReport:
    return oc.coverage(ledger, lock)


# ---------------------------------------------------------------------------
# Oracle 1 — the lock, and the committed rendering of the fold
# ---------------------------------------------------------------------------


def test_the_committed_coverage_report_is_byte_identical_to_a_fresh_derivation(
        generator):
    """The gap is a COMMITTED fact, not one you have to run a command to see.

    A footprint added to the acquisition lock and never measured changes this
    file, so the gap it opens arrives as a diff on the same commit that opened
    it. That is the whole point of committing the report: an absence is
    invisible, and this makes it visible in the one place a reviewer is already
    looking.

    Regenerating and committing without READING the diff defeats it. A ref
    moving into the UNKNOWN section is a drawing an order can now stop on.
    """
    derived = generator.generate_coverage()
    committed = generator.DEFAULT_COVERAGE_PATH.read_text(encoding="utf-8")
    assert derived == committed, (
        "pcb/library/part_orientation_coverage.md has drifted — regenerate with "
        f"`{generator.REGEN_COMMAND}` and READ the diff")

    # The literal invocation a release gate would run. It covers BOTH generated
    # artifacts, so neither can be regenerated without the other.
    assert generator.main(["--check"]) == 0


def test_every_shipped_footprint_is_accounted_for_exactly_once(report, lock):
    """The report PARTITIONS the acquisition lock.

    This is the completeness claim, and it is the one that makes the unknown
    count trustworthy: a footprint cannot be dropped from the fold, land in two
    states, or appear that we do not ship. Without it, "20 unknown" could just
    mean the walk stopped early.

    The rendered summary is compared against the same fold rather than against
    typed-in numbers, so the headline count and the list beneath it can never
    drift apart.
    """
    seen = [e.footprint for e in report.entries]
    assert sorted(seen) == sorted(lock), (
        "the coverage fold and the acquisition lock disagree about what we ship")
    assert len(seen) == len(set(seen)), "a footprint was folded twice"

    states = {oc.STATE_MEASURED: report.measured,
              oc.STATE_NO_REFERENCE: report.declared,
              oc.STATE_UNKNOWN: report.unknown}
    assert sum(len(v) for v in states.values()) == len(lock)
    for state, entries in states.items():
        assert all(e.state == state for e in entries)

    assert not report.orphans, (
        f"the ledger holds rows for footprints the lock does not carry: "
        f"{report.orphans}. The generator refuses to produce one, so this means "
        f"the shipped ledger was hand-edited")

    counts = report.counts()
    rendered = report.to_markdown()
    assert f"| measured | {counts[oc.STATE_MEASURED]} |" in rendered
    assert f"| declared no-reference | {counts[oc.STATE_NO_REFERENCE]} |" in rendered
    assert f"| **unknown** | **{counts[oc.STATE_UNKNOWN]}** |" in rendered
    assert f"| total in the acquisition lock | {counts['total']} |" in rendered
    for entry in report.unknown:
        assert f"`{entry.footprint}`" in rendered, (
            f"{entry.footprint} is unknown but is not named in the report a "
            f"person reads")


def test_the_folds_state_is_the_ledgers_own_state_for_every_shipped_footprint(
        report, ledger):
    """The report does not define a fourth reading of "unknown".

    Each footprint's reported state is checked against ``OrientationLedger``'s
    own three-state fold, asked the way the emitter asks it. A measured
    footprint is asked about a pair it actually holds; the other two are asked
    about a catalogue number nothing has ever measured, which is precisely the
    question an order asks.
    """
    NEVER_MEASURED_PART = "C0000000"
    for entry in report.entries:
        if entry.state == oc.STATE_MEASURED:
            for pair in entry.pairs:
                row = ledger.lookup(entry.footprint, pair.house, pair.part)
                assert row is not None and not row.declared, (
                    f"{entry.footprint} is reported measured for {pair.part}, "
                    f"but the ledger holds no measured row for that pair")
                assert row.offset_deg == pair.offset_deg
                assert row.verdict == pair.verdict
        else:
            expected = (ol.STATE_NO_REFERENCE
                        if entry.state == oc.STATE_NO_REFERENCE
                        else ol.STATE_UNKNOWN)
            assert ledger.state(entry.footprint, HOUSE, NEVER_MEASURED_PART) == \
                expected, (
                    f"{entry.footprint} is reported {entry.state} but the ledger "
                    f"answers differently for a part bought against it")


# ---------------------------------------------------------------------------
# Oracle 2 — the emitter. What the report PREDICTS is what actually happens.
# ---------------------------------------------------------------------------

#: A shipped footprint the report calls UNKNOWN, with a catalogue number nobody
#: has ever measured against it. The classification is asserted below rather
#: than assumed, so measuring this pair one day fails here loudly instead of
#: silently turning the test into a tautology.
GAP_FOOTPRINT = "Diode_SMD:D_SMA"
GAP_PART = "C2480"

#: A shipped footprint the report calls DECLARED — an in-repo synthesized
#: fixture land. Its declaration means a part bought on it is emitted VERBATIM,
#: which is the dangerous half of the same fact and the reason declarations are
#: gated so hard everywhere else in this file.
DECLARED_FOOTPRINT = "C_0805"
DECLARED_PART = "C49678"


def _one_part_board(footprint: str, part: str) -> dict:
    """A synthetic one-component board that compiles — the smallest thing that
    reaches the orientation gate."""
    return {
        "version": 1, "name": "OneCoveragePart",
        "width_mm": 20, "height_mm": 20, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{
            "ref": "U1", "footprint": footprint, "value": "part",
            "x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 30.0, "layer": "top",
            "assembly": {"mpn": part, "populate": True,
                         "house_parts": {HOUSE: part}},
        }],
    }


def _compiled(board: dict):
    """Fails LOUDLY rather than skipping: a fixture that stopped compiling
    would silently stop testing anything."""
    result = compile_board(board)
    if not isinstance(result, ResolutionSuccess):
        raise AssertionError(
            "fixture did not compile: "
            + ", ".join(d.code for d in result.diagnostics
                        if d.severity is DiagnosticSeverity.ERROR))
    return result.board


def test_a_footprint_the_report_calls_unknown_really_does_stop_an_order(report):
    """The UNKNOWN section is not a label — it is a list of refusals.

    Reading the report is only worth doing if what it lists is what an order
    actually hits. So one of its entries is put on a board with a catalogue
    number and emitted, and the refusal is matched by CODE and by the field it
    points a board author at.
    """
    assert GAP_FOOTPRINT in {e.footprint for e in report.unknown}, (
        f"{GAP_FOOTPRINT} is no longer reported as a gap — if it was measured, "
        f"point this test at another entry of the report's UNKNOWN section")

    board = _compiled(_one_part_board(GAP_FOOTPRINT, GAP_PART))
    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.build_cpl(board, "jlc")
    assert excinfo.value.code == aor.CODE_UNKNOWN
    assert excinfo.value.component == "U1"
    assert excinfo.value.field == aor.FIELD_HOUSE_PARTS
    assert GAP_PART in str(excinfo.value)


def test_a_footprint_the_report_calls_declared_emits_its_placed_rotation(report):
    """A declaration DISARMS the gate — proved, not assumed.

    This is the cost of every declaration, made visible: a part bought on a
    declared footprint is emitted at the rotation it was placed at, with
    nothing measured and nothing refused. It is correct here, because the
    drawing is an in-repo synthesized fixture land nobody sells. It would be a
    misrotated part on a real board if the same row were ever written for a
    genuine package, which is what the declaration tripwire below defends.
    """
    assert DECLARED_FOOTPRINT in {e.footprint for e in report.declared}

    board = _compiled(_one_part_board(DECLARED_FOOTPRINT, DECLARED_PART))
    rows = {row.ref: row for row in ao.build_cpl(board, "jlc").rows}
    assert rows["U1"].rotation_deg == pytest.approx(30.0), (
        "a declared footprint carries no offset, so the placed rotation is "
        "emitted unchanged")


def test_a_measured_footprint_still_refuses_every_pair_nobody_measured(report):
    """WHY THIS REPORT IS SAMPLING, AND WHY IT HAS TO SAY SO.

    The gate is keyed on the PAIR. This fold is keyed on the FOOTPRINT, and a
    footprint moves out of UNKNOWN as soon as ONE pair on it is measured — so a
    drawing sitting in the Measured section can still stop an order, for every
    other catalogue part bought against it. That is demonstrated here rather
    than argued: a measured footprint, a catalogue number nothing has measured,
    and the same `assembly_orientation_unknown` the UNKNOWN section advertises.

    A reader who takes the UNKNOWN section for the complete set of drawings an
    order can stop on is therefore wrong, and the earlier wording said exactly
    that. The rendered header now states the bound, and the assertions below
    fail if that sentence is ever dropped — a report that overstates what it
    knows is worse than no report, because it gets believed.
    """
    measured = {e.footprint: e for e in report.measured}
    footprint = "Package_TO_SOT_SMD:SOT-23"
    assert footprint in measured, (
        f"{footprint} is no longer measured — point this test at another "
        f"entry of the report's Measured section")
    unmeasured_part = "C0000001"
    assert unmeasured_part not in {p.part for p in measured[footprint].pairs}

    board = _compiled(_one_part_board(footprint, unmeasured_part))
    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.build_cpl(board, "jlc")
    assert excinfo.value.code == aor.CODE_UNKNOWN, (
        "a MEASURED footprint still refuses an unmeasured pair on it, so the "
        "report's unknown list cannot be the whole set of refusals")

    rendered = report.to_markdown()
    assert "sampling" in rendered.lower(), (
        "the report must say it is footprint-level sampling; without that "
        "sentence its counts read as exhaustive coverage of the gate")
    assert "LOWER BOUND" in rendered


def _synthetic(footprint: str, part: str, **row) -> tuple:
    """A one-row ledger and the one-entry lock to fold it against.

    Built rather than loaded: the shipped corpus holds no pair with either of
    the two verdicts below, and waiting for one would leave the two states the
    report most easily confuses untested until the day they arrive.
    """
    ledger = ol.OrientationLedger(measured=(
        ol.OrientationRecord(footprint=footprint, house=HOUSE, part=part,
                             footprint_sha256="ab" * 32,
                             vendor_sha256="cd" * 32, **row),))
    return ledger, oc.coverage(ledger, {footprint: {"assembly": {}}})


def test_a_measured_pair_with_no_vendor_drawing_is_reported_as_passing():
    """"No offset" IS NOT "refused", and the report used to say it was.

    A pair whose vendor ships no usable package drawing states no offset — and
    so does a pair whose drawings could not settle an angle. The two look
    identical if you only read ``offset_deg``, and they are opposites at the
    emitter: the first is emitted verbatim, the second stops the order. Folding
    them together listed a passing pair under "covered, and still refused",
    which sends somebody to re-measure a drawing that does not exist.

    Both halves are asserted — where the report files it, and what the emitter
    actually does with it — because the report is only worth reading if the two
    agree.
    """
    footprint, part = "Diode_SMD:D_SMA", "C2480"
    ledger, rep = _synthetic(footprint, part, verdict=po.VERDICT_NO_REFERENCE,
                             detail="the vendor ships no package drawing")

    assert rep.undecided == (), (
        "a pair with nothing to measure against is not an undecided "
        "measurement — it does not refuse")
    assert rep.mismatched == ()
    assert [(ref, p.part) for ref, p in rep.unmeasurable] == [(footprint, part)]
    rendered = rep.to_markdown()
    assert "PASSES" in rendered and f"`{part}`" in rendered

    board = _compiled(_one_part_board(footprint, part))
    rows = {r.ref: r for r in ao.build_cpl(board, "jlc",
                                           orientation=ledger).rows}
    assert rows["U1"].rotation_deg == pytest.approx(30.0), (
        "the emitter passes this pair through, which is the fact the report "
        "must not contradict")


def test_a_measured_pair_whose_lands_disagree_is_reported_as_refusing():
    """The mirror image: a pair that states an offset AND still stops the order.

    ``geometry_mismatch`` carries a number, so a report that read only
    ``offset_deg`` would print it beside the pairs that pass. It is the angle
    to a DIFFERENT part, the emitter refuses it, and a reader counting what can
    stop an order needs it listed with the refusals.
    """
    footprint, part = "Diode_SMD:D_SMA", "C2480"
    ledger, rep = _synthetic(
        footprint, part, verdict=po.VERDICT_GEOMETRY_MISMATCH,
        offset_deg=90, angle_decided=True, lands_agree=False,
        residual_mm=0.4, max_pad_error_mm=0.5,
        detail="the angle is settled at 90 deg and the lands are 0.400 mm apart")

    assert [(ref, p.part) for ref, p in rep.mismatched] == [(footprint, part)]
    assert rep.undecided == () and rep.unmeasurable == ()
    assert "THE LANDS DISAGREE" in rep.to_markdown()

    board = _compiled(_one_part_board(footprint, part))
    with pytest.raises(aor.AssemblyOrientationError) as excinfo:
        ao.build_cpl(board, "jlc", orientation=ledger)
    assert excinfo.value.code == aor.CODE_MISMATCH


# ---------------------------------------------------------------------------
# Oracles 3 and 4 — a declaration is authored, and is recognisably not a part
# ---------------------------------------------------------------------------


def test_every_declaration_in_the_shipped_ledger_is_one_a_human_authored(
        generator, ledger):
    """The ledger's declared population IS the authored declarations file.

    Declarations used to be read back out of the previous ledger, which made
    them ungated: deleting one regenerated cleanly, because the only record of
    it was the output. Authoring them outside the artifact is what lets this
    assertion exist at all — there is now a source to compare the artifact
    against.
    """
    authored = json.loads(
        generator.DEFAULT_DECLARED_PATH.read_text(encoding="utf-8"))
    assert authored["schema_version"] == generator.DECLARED_SCHEMA_VERSION
    by_ref = {row["footprint"]: row["reason"] for row in authored["declared"]}
    assert len(by_ref) == len(authored["declared"]), "a footprint is declared twice"

    shipped = {row.footprint: row.reason for row in ledger.declared}
    assert shipped == by_ref, (
        "the shipped ledger's declarations and the authored source disagree — "
        f"regenerate with `{generator.REGEN_COMMAND}`")

    for row in ledger.declared:
        assert row.house is None and row.part is None
        assert row.offset_deg is None
        assert row.reason and row.reason.strip()


#: The ONE declared drawing that the acquisition lock does not record as
#: synthesized in this repo. A plated M3 hole is acquired from KiCad's library
#: and is still not a part — nothing is ever placed in it. Adding to this list
#: is the decision point the tripwire below exists to force into the open.
DECLARED_ACQUIRED_BOARD_FURNITURE = frozenset({
    "MountingHole:MountingHole_3.2mm_M3",
})


def test_a_declaration_is_a_drawing_nobody_could_have_bought(report, lock):
    """THE TRIPWIRE, and the reason this suite exists.

    Declaring a genuine purchasable package to close a coverage gap is the one
    change here that ships a rotated part silently, and it is easy to make
    under pressure to improve a number. The lock knows something the ledger
    does not: ``source_kind`` says where the drawing came from. A drawing this
    repo SYNTHESIZED cannot be a vendor's package, so every declaration is
    required to be either synthesized or a member of the short, named list of
    acquired drawings that are board furniture.

    A new declaration for an ``official_kicad`` or ``vendor_export`` package
    therefore fails here, and closing that failure means writing the ref down
    above with a reason — which is a review, not a reflex.
    """
    for entry in report.declared:
        if entry.footprint in DECLARED_ACQUIRED_BOARD_FURNITURE:
            continue
        assert lock[entry.footprint].get("source_kind") == "generated", (
            f"{entry.footprint} is declared to have no vendor drawing, but the "
            f"acquisition lock says it was acquired "
            f"({lock[entry.footprint].get('source_kind')!r}) rather than "
            f"synthesized here. An acquired drawing is usually a package "
            f"somebody sells, and declaring one disarms the orientation gate "
            f"for every part placed on it. If it really is board furniture, "
            f"add it to DECLARED_ACQUIRED_BOARD_FURNITURE with a reason")

    assert DECLARED_ACQUIRED_BOARD_FURNITURE <= {e.footprint
                                                 for e in report.declared}, (
        "an entry of DECLARED_ACQUIRED_BOARD_FURNITURE is no longer declared — "
        "drop it rather than leaving a stale exemption standing")


# ---------------------------------------------------------------------------
# The generator refuses a declaration that would be dishonest
# ---------------------------------------------------------------------------


def _write_declarations(path: Path, rows: list) -> Path:
    path.write_text(
        json.dumps({"schema_version": 1, "declared": rows},
                   indent="\t", sort_keys=True) + "\n", encoding="utf-8")
    return path


@pytest.mark.parametrize("rows,expected", [
    pytest.param(
        [{"footprint": "Nobody:NeverShipped", "reason": "made up"}],
        "not in the acquisition lock",
        id="a-declaration-about-a-drawing-we-do-not-ship"),
    pytest.param(
        [{"footprint": "TH_TestPoint", "reason": "one"},
         {"footprint": "TH_TestPoint", "reason": "two"}],
        "declared twice",
        id="two-reasons-for-one-footprint"),
    pytest.param(
        [{"footprint": "TH_TestPoint", "reason": "a probe pad",
          "offset_deg": 90}],
        "may not carry",
        id="a-declaration-smuggling-a-number"),
    pytest.param(
        [{"footprint": "TH_TestPoint", "reason": "   "}],
        "must carry a reason",
        id="a-shrug-instead-of-a-reason"),
    pytest.param(
        [{"footprint": "Package_TO_SOT_SMD:SOT-23",
          "reason": "claiming nobody draws a SOT-23"}],
        "cannot be both",
        id="declaring-a-footprint-that-is-actually-measured"),
])
def test_the_generator_refuses_a_declaration_it_cannot_stand_behind(
        generator, tmp_path, rows, expected):
    """Every way a declaration could be wrong, refused by name.

    The last case is the load-bearing one: a footprint declared to have no
    vendor drawing while the corpus holds a vendor's drawing of a part bought
    on it is a CONTRADICTION, and resolving it by precedence would leave which
    fact a consumer sees up to ``lookup``'s fallback rule, which exists for a
    different purpose. Refusing makes somebody delete one of the two.
    """
    path = _write_declarations(tmp_path / "declared.json", rows)
    with pytest.raises(generator.GenerationError) as excinfo:
        generator.generate(declared_path=path)
    assert expected in str(excinfo.value)


def _payload_dir(tmp_path, part: str, footprint: str, source: str) -> Path:
    """A one-pairing corpus: ``index.json`` files *source*'s bytes under *part*."""
    directory = tmp_path / "payloads"
    directory.mkdir(parents=True)
    (directory / f"{part}.json").write_bytes(
        (VENDOR_DIR / f"{source}.json").read_bytes())
    (directory / "index.json").write_text(
        json.dumps({part: {"footprint": footprint, "house": HOUSE}}),
        encoding="utf-8")
    return directory


def test_the_generator_refuses_a_payload_that_is_not_the_part_it_is_filed_under(
        generator, tmp_path):
    """A ROW IS ONLY AS GOOD AS THE JOIN BETWEEN ITS KEY AND ITS BYTES.

    A measured row's key comes from ``index.json`` and the filename; its
    geometry comes from the file. Nothing else connects the two, so a payload
    saved under the wrong name — a re-fetch that answered with a substitute, a
    copy when the corpus was extended — produces a row confidently keyed on one
    catalogue part and measured against another. The ledger, the coverage
    report and the emitter all believe it, because all three read the key.

    The measurement call cannot catch this by itself: passing ``lcsc=part``
    OVERWRITES the payload's stated identity with the one we assumed, erasing
    the mismatch in the same call that would have shown it. So the check is on
    the bytes, before a row exists.

    The positive control below is what stops this test from passing for the
    wrong reason: the identical setup with the RIGHT payload must generate.
    """
    footprint, right, wrong = "Package_TO_SOT_SMD:TSOT-23-6", "C780769", "C15127"

    honest = _payload_dir(tmp_path / "ok", right, footprint, right)
    ledger = ol.OrientationLedger.from_json(
        json.loads(generator.generate(payload_dir=honest)))
    assert ledger.lookup(footprint, HOUSE, right) is not None, (
        "the positive control must generate, or the refusal below proves "
        "nothing about identity")

    swapped = _payload_dir(tmp_path / "swapped", right, footprint, wrong)
    with pytest.raises(generator.GenerationError) as excinfo:
        generator.generate(payload_dir=swapped)
    assert wrong in str(excinfo.value) and right in str(excinfo.value)


def test_the_generator_refuses_a_payload_that_will_not_say_which_part_it_is(
        generator, tmp_path):
    """Unverifiable is not fine.

    A payload with no ``result.lcsc.number`` cannot be checked against the key
    it is filed under, and accepting it would leave exactly one row in the
    ledger whose identity rests on a filename. Fail closed, the same way a
    missing ledger and a missing declarations file do.
    """
    footprint, part = "Package_TO_SOT_SMD:TSOT-23-6", "C780769"
    directory = _payload_dir(tmp_path / "anonymous", part, footprint, part)
    payload_path = directory / f"{part}.json"
    payload = json.loads(payload_path.read_text(encoding="utf-8"))
    payload["result"].pop("lcsc")
    payload_path.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(generator.GenerationError) as excinfo:
        generator.generate(payload_dir=directory)
    assert "states no" in str(excinfo.value)


def test_a_missing_declarations_file_is_an_error_not_an_empty_list(
        generator, tmp_path):
    """Absence of the source must not read as "nothing is declared".

    It would regenerate a ledger with every declaration gone: every piece of
    board furniture would become unknown, and the coverage report would gain
    eleven gaps nobody opened. Fail closed, the same way ``load_ledger``
    refuses a missing ledger.
    """
    with pytest.raises(generator.GenerationError) as excinfo:
        generator.generate(declared_path=tmp_path / "absent.json")
    assert "declarations" in str(excinfo.value)
