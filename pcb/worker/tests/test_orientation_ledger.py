"""Does a measured rotation SURVIVE, and does "we never measured" stay loud?

WHAT THIS SUITE IS FOR
----------------------
``test_part_orientation.py`` proves we can MEASURE the rotation between our
footprint and the vendor's drawing. This suite proves the measurement has a
durable home that cannot lose it, and — the load-bearing half — that

    NEVER MEASURED and MEASURED, AND THE ANSWER WAS ZERO

are different things in the file and stay different through every read. A store
that collapses them ships 0 for a pair nobody ever looked at, which is exactly
how a misrotated connector reaches a board house with every other check green.

THE FOUR ORACLES, AND WHY THEY ARE FOUR
---------------------------------------
1. **The drawings themselves.** The committed ledger's measured rows must be
   byte-identical to what regenerating from the real seed library and the
   committed vendor payloads produces. Catches a hand-edited offset, a library
   edit, a refreshed payload, a sign flip in the maths, a formatting drift.
2. **The human-confirmed offset table** in ``test_part_orientation.py``, three
   of whose twenty entries a person read off a board house's 3D preview of an
   assembled board before any of this code existed. Independent of (1): the
   regeneration could be perfectly self-consistent and still be measuring the
   wrong thing. Cross-suite on purpose.
3. **The three-state definition itself**, exercised against the shipped file
   rather than a fixture, so the states are proven to be distinguishable in the
   data we actually ship.
4. **The invariant that retired ``assembly.orientation_convention``** — that no
   rotation may be keyed on a footprint alone. That field was inert, so nothing
   would have failed had it grown a value; these tests are what make its
   successor's key non-optional.

Offline and pure: the seed library, the committed payloads, and the committed
ledger. No network, no clock.
"""

from __future__ import annotations

import json

from pathlib import Path

import pytest

from pcb_worker import orientation_ledger as ol
from pcb_worker import part_orientation as po
from pcb_worker.footprints import DEFAULT_LOCKFILE, load_lockfile

# The generator is a script, not a package module — loaded the way
# test_notice.py loads gen_notice.py, for the same reason: the CLI and the
# suite must derive the artifact through ONE function.
import importlib.util

HERE = Path(__file__).resolve().parent
PCB = HERE.parents[1]
GEN_PATH = PCB / "scripts" / "gen_part_orientation.py"


def _load_generator():
    spec = importlib.util.spec_from_file_location("gen_part_orientation", GEN_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


#: A pair the measurement settled at ZERO. This one is the whole point of the
#: suite: its stored answer is numerically identical to the answer a store that
#: had never heard of it would invent.
MEASURED_ZERO = ("Capacitor_SMD:C_0805_2012Metric", "jlcpcb", "C49678")

#: A pair the measurement settled at 180 — the defect shape, kept beside the
#: zero so "we store something" is not mistaken for "we store zero".
MEASURED_ROTATED = ("Connector_JST:JST_PH_S4B-PH-SM4-TB_1x04-1MP_P2.00mm_Horizontal",
                    "jlcpcb", "C265102")

#: A footprint we ship that is not an orientable purchasable part at all.
DECLARED_NO_REFERENCE = "MountingHole:MountingHole_3.2mm_M3"

#: A footprint we ship, a plausible catalogue number, and NOBODY has ever
#: measured the pair. ``D_SMA`` is in the seed lock; the part number is a real
#: LCSC diode we have never paired with it.
NEVER_MEASURED = ("Diode_SMD:D_SMA", "jlcpcb", "C2480")


@pytest.fixture(scope="module")
def ledger() -> ol.OrientationLedger:
    """The SHIPPED ledger, not a fixture. Every assertion below is about the
    file that goes out with the plugin."""
    return ol.load_ledger()


# ---------------------------------------------------------------------------
# Oracle 1 — the drawings themselves
# ---------------------------------------------------------------------------


def test_the_shipped_ledger_is_byte_identical_to_a_fresh_derivation():
    """Regenerating from the real library + the committed payloads reproduces
    the committed file exactly.

    This is the determinism property stated as an assertion: the ledger is
    verifiable by ``git diff``, not by reading it. It also proves CONVERGENCE —
    a second run over unchanged inputs adds nothing and drops nothing — and it
    proves the declared rows survive a regeneration, which is the one thing a
    wholesale rewrite of the measured population could plausibly destroy.

    A failure here is NEVER fixed by re-running the generator and committing
    the result without reading the diff. A changed offset means the supplier
    redrew the package or our footprint moved, and both need a human to look at
    a board before the next order goes out.
    """
    module = _load_generator()
    derived = module.generate()
    committed = ol.DEFAULT_LEDGER_PATH.read_text(encoding="utf-8")
    assert derived == committed, (
        "pcb/library/part_orientation.json has drifted from the drawings it is "
        f"derived from — regenerate with `{module.REGEN_COMMAND}` and READ the "
        "diff before committing")

    # The literal invocation a release gate would run.
    assert module.main(["--check"]) == 0


def test_every_measured_row_pins_the_footprint_bytes_the_lock_pins():
    """Each measured row's ``footprint_sha256`` is the acquisition lock's pin
    for that ref — so a consumer with no vendor payload (i.e. every shipped
    install) can still tell that OUR drawing changed since the measurement.

    The oracle is the lock, which the census suite independently proves matches
    the bytes on disk. Without this the store would carry offsets with no way
    to know they had gone stale on the half we control.
    """
    lock = load_lockfile(DEFAULT_LOCKFILE)
    ledger = ol.load_ledger()
    assert ledger.measured, "the shipped ledger must carry measured rows"
    for row in ledger.measured:
        assert row.footprint in lock, (
            f"{row.footprint}: measured against a footprint the lock does not "
            f"carry")
        assert row.footprint_sha256 == lock[row.footprint]["sha256"], (
            f"{row.footprint}: the row pins {row.footprint_sha256} but the lock "
            f"pins {lock[row.footprint]['sha256']} — the measurement is stale, "
            f"or the row was hand-edited")
        assert row.vendor_sha256, f"{row.footprint}: no vendor payload pinned"


# ---------------------------------------------------------------------------
# Oracle 2 — the human-confirmed table, cross-suite
# ---------------------------------------------------------------------------


def test_the_ledger_carries_the_offsets_the_human_confirmed_table_states(ledger):
    """Every stored offset equals the sibling suite's ORACLE for that part.

    Deliberately imported from ``test_part_orientation`` rather than restated:
    a second copy of twenty numbers is a second thing to update wrongly.
    Three of those twenty were read off a board house's 3D preview by a
    person before any of this code existed, so this is not the code grading its
    own homework — and a ledger that faithfully persisted a WRONG measurement
    would pass oracle 1 and fail here.
    """
    # ``tests`` is a package (tests/__init__.py), so the sibling suite is
    # imported by its package path. Imported here rather than at module scope
    # to keep the cross-suite coupling visible at the assertion that needs it.
    from tests.test_part_orientation import HUMAN_CONFIRMED, INDEX, ORACLE

    stored = {r.part: r for r in ledger.measured}
    assert set(stored) == set(ORACLE), (
        "the ledger's measured parts and the orientation oracle's parts have "
        f"diverged: ledger-only {sorted(set(stored) - set(ORACLE))}, "
        f"oracle-only {sorted(set(ORACLE) - set(stored))}")

    for part, expected in sorted(ORACLE.items()):
        row = stored[part]
        assert row.offset_deg == expected, (
            f"{part}: the ledger stores {row.offset_deg} deg but the measured "
            f"oracle says {expected} deg")
        assert row.footprint == INDEX[part]["footprint"], (
            f"{part}: the ledger pairs it with {row.footprint}, the corpus "
            f"with {INDEX[part]['footprint']}")
        assert row.house == INDEX[part]["house"]

    # The three a human verified are the ones that pin the SIGN: 0 and 180 are
    # unchanged by inverting the rotation sense, so only these turn 270 into 90.
    for part in HUMAN_CONFIRMED:
        assert stored[part].offset_deg == ORACLE[part]


# ---------------------------------------------------------------------------
# Oracle 3 — the three states, in the file we ship
# ---------------------------------------------------------------------------


def test_the_three_states_are_distinct_in_the_shipped_ledger(ledger):
    """Unknown, measured-as-zero, and no-reference read differently.

    The reason this is one test and not three: the property is that the three
    are MUTUALLY distinguishable, and a test per state would let two of them
    quietly become the same thing while each still passed on its own.
    """
    zero = ledger.lookup(*MEASURED_ZERO)
    rotated = ledger.lookup(*MEASURED_ROTATED)
    none_ref = ledger.lookup(DECLARED_NO_REFERENCE)
    unknown = ledger.lookup(*NEVER_MEASURED)

    # 1. MEASURED, and the answer was zero. A row EXISTS and states 0.
    assert ol.state_of(zero) == ol.STATE_MEASURED
    assert zero is not None and zero.offset_deg == 0
    assert zero.verdict == po.VERDICT_ALIGNED

    # 2. NEVER MEASURED. No row at all — not a stored "unknown" verdict.
    assert unknown is None
    assert ol.state_of(unknown) == ol.STATE_UNKNOWN
    assert ledger.state(*NEVER_MEASURED) == ol.STATE_UNKNOWN

    # THE DEFECT THIS WHOLE STORE EXISTS TO STOP. Both of the above would be
    # "0" to a consumer that read a missing row as no-rotation-needed; the
    # states must not be equal, and the unknown must not carry a number.
    assert ol.state_of(unknown) != ol.state_of(zero)
    assert not hasattr(unknown, "offset_deg")

    # 3. NO VENDOR REFERENCE. A row exists — so it is not unknown — but it
    # carries no number, so it is not a measured zero either.
    assert ol.state_of(none_ref) == ol.STATE_NO_REFERENCE
    assert none_ref is not None and none_ref.offset_deg is None
    assert none_ref.reason, "a no-reference row must say why"
    assert none_ref.part is None and none_ref.house is None

    # All three readings differ from each other.
    assert len({ol.state_of(zero), ol.state_of(unknown),
                ol.state_of(none_ref)}) == 3

    # And a nonzero measurement is still plainly a measurement, so "a row
    # exists" has not quietly come to mean "the answer is zero".
    assert ol.state_of(rotated) == ol.STATE_MEASURED
    assert rotated.offset_deg == 180


def test_a_no_reference_declaration_never_hides_a_measured_offset(ledger):
    """Lookup precedence: the pair beats the footprint-wide declaration.

    The fallback is safe in exactly one direction, and this is the test that
    says so. A footprint-wide row is validated to be a declared
    ``no_reference`` carrying no numbers, so consulting it when a pair has no
    row of its own can never substitute a rotation for a measurement — while a
    pair row, when one exists, always wins.
    """
    footprint = DECLARED_NO_REFERENCE
    declaration = ledger.lookup(footprint)
    assert declaration is not None and declaration.declared

    # Any part looked up against that footprint inherits the declaration...
    inherited = ledger.lookup(footprint, "jlcpcb", "C99999")
    assert inherited is declaration

    # ...until a real measurement for that pair exists, which then wins.
    measured = ol.OrientationRecord(
        footprint=footprint, house="jlcpcb", part="C99999",
        verdict=po.VERDICT_ROTATED, offset_deg=90, angle_decided=True,
        lands_agree=True, residual_mm=0.01, max_pad_error_mm=0.02,
        runner_up_deg=0, runner_up_mm=1.5, matched_pad_count=4,
        footprint_sha256="ab" * 32, vendor_sha256="cd" * 32, detail="synthetic")
    widened = ol.OrientationLedger(declared=ledger.declared,
                                   measured=ledger.measured + (measured,))
    assert widened.lookup(footprint, "jlcpcb", "C99999") is measured
    # ...and every OTHER part on that footprint still reads no-reference.
    assert widened.lookup(footprint, "jlcpcb", "C11111") is declaration

    # No shipped declaration carries a number, which is what makes the
    # precedence above safe rather than merely convenient.
    for row in ledger.declared:
        assert row.offset_deg is None and row.verdict == po.VERDICT_NO_REFERENCE


# ---------------------------------------------------------------------------
# Oracle 4 — the invariant that retired orientation_convention
# ---------------------------------------------------------------------------


def test_no_rotation_can_ever_be_keyed_on_a_footprint_alone(ledger):
    """A footprint-wide row may only DECLARE that there is nothing to measure.

    This is the muzzle on the one shape that could grow back into the
    footprint-keyed slot this store replaced. It is not hypothetical: one land
    pattern is bought as many parts whose vendors draw them differently, so a
    footprint-keyed offset is guaranteed wrong somewhere — silently, since the
    copper stays self-consistent either way.
    """
    common = dict(footprint="Diode_SMD:D_SMA", house=None, part=None)

    # A footprint-wide row that is a measurement: refused.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(verdict=po.VERDICT_ALIGNED, declared=False, **common)

    # A footprint-wide row smuggling a rotation in beside its reason: refused.
    # This is the one that matters — it is the retired field's exact shape.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(verdict=po.VERDICT_NO_REFERENCE, declared=True,
                             reason="no vendor drawing, but trust me: 180",
                             offset_deg=180, angle_decided=True, **common)

    # A declared row asserting any verdict other than no_reference: refused —
    # a human stating a verdict they did not measure.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(verdict=po.VERDICT_ALIGNED, declared=True,
                             reason="looks fine to me", **common)

    # A declared row with no reason: refused. An unexplained "no vendor
    # drawing" is indistinguishable from a shrug.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(verdict=po.VERDICT_NO_REFERENCE, declared=True,
                             **common)

    # Half a key names nothing: a catalogue number is unique only in its house.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(footprint="Diode_SMD:D_SMA", house="jlcpcb",
                             part=None, verdict=po.VERDICT_ALIGNED)

    # An offset nobody could separate from its runner-up is a guess wearing a
    # number, and a no_reference row has nothing to have measured an offset
    # against.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(footprint="Diode_SMD:D_SMA", house="jlcpcb",
                             part="C1", verdict=po.VERDICT_AMBIGUOUS,
                             offset_deg=90, angle_decided=False)
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationRecord(footprint="Diode_SMD:D_SMA", house="jlcpcb",
                             part="C1", verdict=po.VERDICT_NO_REFERENCE,
                             offset_deg=0, angle_decided=True)

    # And the same rule holds through the file, not just the constructor.
    assert all(r.declared and r.verdict == po.VERDICT_NO_REFERENCE
               for r in ledger.rows if r.part is None)


def test_the_retired_orientation_convention_slot_stays_retired():
    """``assembly.orientation_convention`` is gone from the lock and from the
    staging helper that wrote it.

    The field was inert — written null on all 42 entries, read by nothing — so
    its return would break no test that existed before this one. That is
    precisely why it needs a test: an inert slot is invisible until someone
    fills it in with a footprint-keyed answer, which is the wrong answer by
    construction.
    """
    from pcb_worker import bless

    doc = json.loads(DEFAULT_LOCKFILE.read_text(encoding="utf-8"))
    offenders = sorted(ref for ref, e in doc["entries"].items()
                       if "orientation_convention" in (e.get("assembly") or {}))
    assert not offenders, (
        "orientation_convention is back in the acquisition lock for "
        f"{offenders} — a rotation cannot be keyed on a footprint alone; it "
        "belongs in pcb/library/part_orientation.json, keyed on the "
        "(footprint, part) pair")
    assert "orientation_convention" not in bless._blank_assembly()

    # The reserved `assembly` slot itself is still declared explicitly on every
    # entry — the removal took the field, not the census predicate's subject.
    assert all("assembly" in e for e in doc["entries"].values())


# ---------------------------------------------------------------------------
# The file format itself
# ---------------------------------------------------------------------------


def test_the_ledger_round_trips_and_refuses_what_it_cannot_trust(ledger, tmp_path):
    """Both populations survive a write/read cycle, and a file this reader
    cannot fully understand is REFUSED rather than read as empty.

    Fail-closed matters more here than usual. An unreadable ledger read as
    empty makes every pair unknown, which a gate refuses loudly; a malformed
    row silently dropped makes ONE pair unknown while every other pair sails
    through, and that pair is the one nobody is looking at.
    """
    path = tmp_path / "part_orientation.json"
    path.write_text(ledger.to_text(), encoding="utf-8")
    assert ol.load_ledger(path) == ledger
    # Canonical bytes: writing what was read reproduces it exactly.
    assert path.read_text(encoding="utf-8") == ol.load_ledger(path).to_text()

    doc = json.loads(ledger.to_text())

    for name, mutate in (
        ("future schema", lambda d: d.__setitem__("schema_version", 99)),
        ("unknown top-level key", lambda d: d.__setitem__("orientation", {})),
        ("missing measured array", lambda d: d.pop("measured")),
        ("unknown row key", lambda d: d["measured"][0].__setitem__("tilt", 3)),
        ("missing row key", lambda d: d["measured"][0].pop("offset_deg")),
        ("measurement on a declared row",
         lambda d: d["declared"][0].__setitem__("offset_deg", 0)),
    ):
        broken = json.loads(json.dumps(doc))
        mutate(broken)
        path.write_text(json.dumps(broken), encoding="utf-8")
        with pytest.raises(ol.OrientationLedgerError):
            ol.load_ledger(path)

    # A missing file is a broken install, not an empty ledger.
    with pytest.raises(ol.OrientationLedgerError):
        ol.load_ledger(tmp_path / "nope.json")

    # Two rows for one pair: which answer wins must never be a question about
    # file order.
    with pytest.raises(ol.OrientationLedgerError):
        ol.OrientationLedger(measured=ledger.measured + (ledger.measured[0],))


def test_a_row_whose_verdict_and_numbers_disagree_does_not_load(ledger, tmp_path):
    """THE CONVERSE OF "an offset implies a decided angle", which is the half
    that ships something.

    ``verdict="ambiguous"`` beside ``angle_decided=true`` and ``offset_deg=90``
    passes every rule stated in terms of the offset — there IS an offset and the
    angle IS marked decided — and it is nonsense: the verdict says the drawings
    could not be separated and the fields say one angle won.
    ``assembly_orientation`` reads ``offset_deg`` and would ADD that 90 to a
    real placement, so this is not a tidiness rule. The loader's fail-closed
    claim only holds if a row that disagrees with itself never becomes a
    record.

    Each mutation below is ONE field away from the shipped row it starts from,
    so nothing here can pass by accident, and every one of them must raise.
    """
    path = tmp_path / "part_orientation.json"
    doc = json.loads(ledger.to_text())
    row = doc["measured"][0]
    assert row["angle_decided"] is True and row["offset_deg"] is not None, (
        "this test starts from a DECIDED shipped row; pick another if the "
        "ledger's first measured row stops being one")

    def _mutate(**fields):
        broken = json.loads(json.dumps(doc))
        broken["measured"][0].update(fields)
        return broken

    for name, broken in (
        # The reviewer's exact shape: a guessed offset wearing a decided flag
        # under a verdict that says nothing was decided.
        ("ambiguous, yet decided, with an offset",
         _mutate(verdict=po.VERDICT_AMBIGUOUS, angle_decided=True,
                 offset_deg=90, lands_agree=None)),
        # ...and the same contradiction with the offset dropped: the verdict
        # still claims a decision the flag denies.
        ("ambiguous, yet decided",
         _mutate(verdict=po.VERDICT_AMBIGUOUS, angle_decided=True,
                 offset_deg=None, lands_agree=None)),
        ("rotated, yet undecided",
         _mutate(angle_decided=False, offset_deg=None,
                 verdict=po.VERDICT_ROTATED, lands_agree=True)),
        # The land axis is what the verdict REPORTS, so a row stating the other
        # answer was not written by the measurement.
        ("rotated, yet the lands disagree",
         _mutate(verdict=po.VERDICT_ROTATED, angle_decided=True,
                 offset_deg=90, lands_agree=False)),
        ("a geometry mismatch whose lands agree",
         _mutate(verdict=po.VERDICT_GEOMETRY_MISMATCH, angle_decided=True,
                 offset_deg=90, lands_agree=True)),
        # ...and one that declines to answer the axis it exists to report. A
        # mismatch is a statement ABOUT the lands; a row that omits it is not
        # a milder mismatch, it is a row nobody wrote.
        ("a geometry mismatch that says nothing about the lands",
         _mutate(verdict=po.VERDICT_GEOMETRY_MISMATCH, angle_decided=True,
                 offset_deg=90, lands_agree=None)),
        # THE ONE THAT WOULD HIDE A MISPAIRING UNDER A MILDER NAME. "the
        # drawings did not separate the angle" AND "the lands disagree" is a
        # geometry_mismatch; letting it wear `ambiguous` reports a wrong part
        # as a symmetry problem.
        ("an ambiguity that says the lands disagree",
         _mutate(verdict=po.VERDICT_AMBIGUOUS, angle_decided=False,
                 offset_deg=None, lands_agree=False)),
        # Nothing was fitted, so there is no land comparison to report.
        ("insufficient overlap that answers the land test anyway",
         _mutate(verdict=po.VERDICT_INSUFFICIENT_OVERLAP, angle_decided=False,
                 offset_deg=None, lands_agree=True)),
        ("no reference that answers the land test anyway",
         _mutate(verdict=po.VERDICT_NO_REFERENCE, angle_decided=False,
                 offset_deg=None, lands_agree=False)),
        # One drawing state, one verdict: "aligned" is the 0 and nothing else.
        ("aligned at a quarter turn",
         _mutate(verdict=po.VERDICT_ALIGNED, angle_decided=True,
                 offset_deg=90, lands_agree=True)),
        ("rotated by nothing",
         _mutate(verdict=po.VERDICT_ROTATED, angle_decided=True,
                 offset_deg=0, lands_agree=True)),
    ):
        path.write_text(json.dumps(broken), encoding="utf-8")
        try:
            loaded = ol.load_ledger(path)
        except ol.OrientationLedgerError:
            continue
        raise AssertionError(
            f"a row that is {name} LOADED: "
            f"{loaded.measured[0]}. assembly_orientation reads offset_deg, so "
            f"this row would be applied to a real placement as a measurement")


# ---------------------------------------------------------------------------
# THE WHOLE TABLE, BOTH DIRECTIONS
# ---------------------------------------------------------------------------


def _shape(verdict: str, decided: bool, offset_stated: bool, lands) -> dict:
    """One measured row of a given SHAPE, with every other field neutral.

    The offset VALUE is chosen per verdict so that this scan tests the
    verdict/number consistency table and not the separate "aligned is the 0"
    rule: an ``aligned`` row states 0 and everything else states 90.
    """
    return dict(
        footprint="Shape:UnderTest", house="jlcpcb", part="C1", verdict=verdict,
        declared=False,
        offset_deg=((0 if verdict == po.VERDICT_ALIGNED else 90)
                    if offset_stated else None),
        angle_decided=decided, lands_agree=lands)


#: THE ORACLE, HAND-WRITTEN. ``verdict -> every (angle_decided, offset stated,
#: lands_agree) that verdict may carry``, retyped here on purpose: reading
#: ``ol._CONSISTENT`` as the oracle asks the table whether it agrees with
#: itself, which it always does, and a widened table would then license
#: whatever it had just been widened to.
#:
#: Each entry is derived from what the VERDICT asserts, not from the code:
#:
#: * ``aligned``/``rotated`` -- the drawings are the same land pattern at a
#:   settled angle. Both axes answered, both positively.
#: * ``geometry_mismatch`` -- asserts the LANDS only. The angle is free: the
#:   pads may miss at a settled angle, or miss at every angle with nothing to
#:   separate them (a symmetric part paired with the wrong catalogue number).
#: * ``ambiguous`` -- asserts the ANGLE only: nothing separated it, so no
#:   offset. The lands may be unanswered or may agree -- a symmetric pad field
#:   fits at two angles, which is WHY the angle did not settle -- but may not
#:   DISAGREE, because that row is a geometry_mismatch wearing a milder name.
#: * ``insufficient_overlap``/``no_reference`` -- nothing was fitted at all, so
#:   both axes are silent and ``lands_agree`` is not an answer anybody has.
_EXPECTED_SHAPES = {
    po.VERDICT_ALIGNED: {(True, True, True)},
    po.VERDICT_ROTATED: {(True, True, True)},
    po.VERDICT_GEOMETRY_MISMATCH: {(True, True, False), (False, False, False)},
    po.VERDICT_AMBIGUOUS: {(False, False, None), (False, False, True)},
    po.VERDICT_INSUFFICIENT_OVERLAP: {(False, False, None)},
    po.VERDICT_NO_REFERENCE: {(False, False, None)},
}


def test_the_consistency_table_admits_exactly_the_combinations_it_states():
    """EVERY SHAPE A ROW CAN HAVE, SCANNED — 72 of them, both directions.

    Six verdicts x decided/not x offset stated/absent x lands True/False/None,
    against :data:`_EXPECTED_SHAPES`. The scan is what the hand list alone
    cannot do: the list says which shapes are legal, and only enumerating all
    72 says that NOTHING ELSE loads.

    BOTH DIRECTIONS MATTER.

    * A shape the oracle admits that the loader REFUSES makes a real finding
      unrecordable — an undecided ``geometry_mismatch`` is a measurement that
      happens in the world, and a loader that will not hold it fails closed on
      the truth.
    * A shape the oracle forbids that LOADS is the dangerous one: a row whose
      verdict and numbers tell different stories reaches
      ``assembly_orientation`` as a measurement and its guess is applied.
    """
    assert set(_EXPECTED_SHAPES) == set(po.VERDICTS), (
        "the hand-written oracle has stopped covering every verdict; a verdict "
        "missing from it would be scanned against nothing")
    seen = set()
    for verdict in po.VERDICTS:
        allowed = _EXPECTED_SHAPES[verdict]
        for decided in (True, False):
            for offset_stated in (True, False):
                for lands in (True, False, None):
                    shape = (decided, offset_stated, lands)
                    # IDENTITY, not `in`: `1 == True` in Python, and the loader
                    # checks identity too.
                    legal = any(shape[0] is a and shape[1] is b and shape[2] is c
                                for a, b, c in allowed)
                    seen.add((verdict, shape))
                    if legal:
                        record = ol.OrientationRecord(**_shape(verdict, *shape))
                        assert record.verdict == verdict
                        assert (record.offset_deg is not None) is offset_stated
                    else:
                        with pytest.raises(ol.OrientationLedgerError):
                            ol.OrientationRecord(**_shape(verdict, *shape))
    assert len(seen) == 6 * 2 * 2 * 3, "the scan stopped covering every shape"

    # And the table itself is exhaustive over the verdicts: a verdict with no
    # entry would load unchecked, which is the hole the table was added to fill.
    assert set(ol._CONSISTENT) == set(po.VERDICTS)


def test_no_verdict_but_a_decided_one_may_admit_a_shape_the_emitter_APPLIES():
    """THE TABLE CANNOT BE WIDENED INTO THE ROTATION ARITHMETIC.

    ``_CONSISTENT`` decides which rows LOAD and ``applies_offset`` decides
    which loaded rows are ADDED to a placed rotation, and nothing but this
    check joins them. Widening the table is a two-line edit that reads as
    "record one more honest measurement"; a widening of the wrong SHAPE
    silently promotes that verdict into production rotations instead.

    Demonstrated rather than argued: an ``insufficient_overlap`` row with an
    offset and agreeing lands passes every other rule in the loader, and
    ``assembly_orientation`` turns a placed 30 into a 120 for it — no refusal
    anywhere. The bound comes from ``part_orientation.DECIDED_VERDICTS``, the
    measurement side's own statement of which verdicts carry an actionable
    offset, so it is not a second list to keep in step by hand.
    """
    # The shipped table passes, and so does the module's import-time call.
    ol._check_consistency_table(ol._CONSISTENT)

    for verdict in po.VERDICTS:
        if verdict in po.DECIDED_VERDICTS:
            continue
        widened = dict(ol._CONSISTENT)
        widened[verdict] = tuple(widened[verdict]) + ((True, True, True),)
        with pytest.raises(ol.OrientationLedgerError) as excinfo:
            ol._check_consistency_table(widened)
        assert verdict in str(excinfo.value)

    # ...and the other way: a decided verdict narrowed to a shape the emitter
    # does NOT apply stops correcting the parts this step exists to correct.
    for verdict in po.DECIDED_VERDICTS:
        narrowed = dict(ol._CONSISTENT)
        narrowed[verdict] = ((False, False, None),)
        with pytest.raises(ol.OrientationLedgerError):
            ol._check_consistency_table(narrowed)


def test_the_shape_the_guard_forbids_is_the_shape_that_would_be_applied():
    """WHY THAT GUARD IS THE RIGHT ONE — the arithmetic, run on the shape.

    :func:`orientation_ledger.applies_offset` is a claim about what
    ``assembly_orientation.correct`` does, and a claim is only worth the check
    that falsifies it. So this builds a record of the guarded shape under a
    verdict that IS allowed to carry it (``rotated``), and shows the emitter
    reaching ``corrected_rotation``: 30 + 90 = 120. That is the number an
    ``insufficient_overlap`` row of the same shape would produce, which is what
    the guard above stops from ever loading.
    """
    from dataclasses import dataclass

    from pcb_worker import assembly_orientation as aor

    @dataclass(frozen=True)
    class _Row:
        ref: str
        footprint_ref: str
        house_part: str
        side: str
        rotation_deg: float

    class _Profile:
        house_part_id = "jlcpcb"

    applied = ol.OrientationRecord(
        footprint="Shape:UnderTest", house="jlcpcb", part="C1",
        verdict=po.VERDICT_ROTATED, angle_decided=True, offset_deg=90,
        lands_agree=True)
    assert ol.applies_offset(applied.offset_deg is not None,
                             applied.lands_agree)

    rows, refusals = aor.correct(
        (_Row("U1", "Shape:UnderTest", "C1", "top", 30.0),), _Profile(),
        ledger=ol.OrientationLedger(measured=(applied,), declared=()))
    assert refusals == ()
    assert rows[0].rotation_deg == 120.0


def test_an_ambiguity_may_report_that_the_lands_do_agree(tmp_path):
    """THE OTHER COMBINATION THE OLD TABLE FORBADE, and why it is a real one.

    A two-pad chip drawn symmetrically fits its vendor's drawing at 0 AND at
    180, to the same fraction of a millimetre. Nothing separates the angle —
    that is the ``ambiguous`` verdict — and the very reason nothing separates
    it is that the pads DO land on each other. "We cannot tell which way round"
    and "these are the same land pattern" are both true, and the second is
    worth recording: it tells whoever picks this up that the part number is
    fine and only the orientation is open.

    It states no offset, so it still refuses at the emitter. What it must not
    be able to say is that the lands DISAGREE — that row is a
    ``geometry_mismatch``, and the loader refuses it wearing this verdict (see
    the disagreement list above).
    """
    row = ol.OrientationRecord(
        footprint="Shape:UnderTest", house="jlcpcb", part="C1",
        verdict=po.VERDICT_AMBIGUOUS, declared=False,
        offset_deg=None, angle_decided=False, lands_agree=True,
        residual_mm=0.01, max_pad_error_mm=0.02, runner_up_deg=180,
        runner_up_mm=0.01, matched_pad_count=2,
        footprint_sha256="ab" * 32, vendor_sha256="cd" * 32,
        detail="0 deg and 180 deg both fit at 0.010 mm — a symmetric pad field")

    path = tmp_path / "part_orientation.json"
    path.write_text(ol.OrientationLedger(measured=(row,)).to_text(),
                    encoding="utf-8")
    loaded = ol.load_ledger(path).lookup("Shape:UnderTest", "jlcpcb", "C1")

    assert loaded == row
    assert loaded.lands_agree is True and loaded.offset_deg is None


def test_an_undecided_geometry_mismatch_survives_a_file_round_trip(tmp_path):
    """THE ROW THAT COULD NOT BE WRITTEN DOWN, written down and read back.

    The dataclass scan above builds records directly. This one goes through the
    bytes — serialize, write, ``load_ledger`` — because that is the path a
    regenerated ledger actually takes, and it is the path that was refusing.

    The finding it carries: at the best-fitting angle the shared pads are
    nowhere near each other, and no angle separated itself from its runner-up
    either. Both halves are true at once on a symmetric part paired with the
    wrong catalogue number, and neither is a reason to place it.
    """
    row = ol.OrientationRecord(
        footprint="Shape:UnderTest", house="jlcpcb", part="C1",
        verdict=po.VERDICT_GEOMETRY_MISMATCH, declared=False,
        offset_deg=None, angle_decided=False, lands_agree=False,
        residual_mm=0.9, max_pad_error_mm=1.4, runner_up_deg=180,
        runner_up_mm=0.91, matched_pad_count=2,
        footprint_sha256="ab" * 32, vendor_sha256="cd" * 32,
        detail="every candidate angle leaves the shared pads ~0.9 mm apart, "
               "and none of them separates from its runner-up")

    path = tmp_path / "part_orientation.json"
    path.write_text(ol.OrientationLedger(measured=(row,)).to_text(),
                    encoding="utf-8")
    loaded = ol.load_ledger(path).lookup("Shape:UnderTest", "jlcpcb", "C1")

    assert loaded == row
    assert ol.state_of(loaded) == ol.STATE_MEASURED
    assert loaded.offset_deg is None and loaded.lands_agree is False
