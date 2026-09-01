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
   of whose eleven entries a person read off a board house's 3D preview of an
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
    a second copy of eleven numbers is a second thing to update wrongly. Three
    of those eleven were read off a board house's 3D preview by a person before
    any of this code existed, so this is not the code grading its own homework
    — and a ledger that faithfully persisted a WRONG measurement would pass
    oracle 1 and fail here.
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
