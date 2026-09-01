"""Where a measured part-orientation offset LIVES, and how "unknown" stays loud.

WHY THIS EXISTS
---------------
``part_orientation`` measures, for one (our footprint, vendor part) pair, the
rotation between our drawing and the vendor's. That measurement is worthless
the moment it is forgotten: a pick-and-place rotation is interpreted against
the VENDOR's drawing, so a pair nobody ever measured is a pair whose emitted
rotation is a guess. The defect this whole line of work exists to stop is not
"we measured wrong" — it is **"we never measured, and shipped 0 anyway"**.

So the one property this module owns is:

    NEVER MEASURED and MEASURED, AND THE ANSWER WAS ZERO must be different
    things, and a consumer must not be able to read one as the other.

THREE STATES, ONE FOLD
----------------------
:func:`state_of` is the ONLY place that answers "what do we know about this
pair?", so no consumer can invent a fourth reading:

``unknown`` (:data:`STATE_UNKNOWN`)
    There is no record. Not a stored verdict — an ABSENCE. This is deliberate:
    a stored ``"unknown"`` is a row somebody has to remember to write, and the
    failure mode here is precisely the pair nobody thought about. Absence is
    the automatic default for every pair no human ever touched, so the store
    cannot fail to have this state. :func:`OrientationLedger.lookup` returns
    ``None`` and ``state_of(None)`` says ``unknown``. Nothing in this module
    converts that to a number.

    Absence is invisible by construction, so a SECOND artifact makes the set of
    unknowns readable: ``pcb/library/part_orientation_coverage.md`` folds this
    ledger against the acquisition lock and lists every shipped footprint
    nothing has measured. See :mod:`pcb_worker.orientation_coverage`. Nothing
    on the order path reads it — a gap is a fact about how far the measuring
    has got, not an error.

``measured`` (:data:`STATE_MEASURED`)
    A row derived mechanically from the two drawings. "Aligned, offset 0" is
    a PRESENT row carrying ``offset_deg = 0``; it is distinguishable from
    unknown by the row existing at all, and from no-reference by
    ``offset_deg`` being an int rather than ``None``. The undecided verdicts
    (``ambiguous``, ``insufficient_overlap``) are also ``measured`` — we
    looked, and the honest answer is "the drawings do not settle it". A gate
    refuses those on ``offset_deg is None``, not on the state.

    ``measured`` DOES NOT MEAN "SAFE TO EMIT", and the reader is not the one
    who gets to decide which. ``geometry_mismatch`` is a measured row that
    carries an offset and must still stop an order: the angle came out, and it
    came out against a drawing that is not the same land pattern as ours. So
    a consumer reads BOTH numbers — ``offset_deg`` for the angle and
    ``lands_agree`` for whether it is the angle to the right part —
    and ``assembly_orientation.apply`` is the one place that fold is written.

``no_reference`` (:data:`STATE_NO_REFERENCE`)
    A row that says there is nothing to measure AGAINST. Two ways to earn it:
    the vendor has the part but ships no usable package drawing (measured —
    ``part_orientation`` returns that verdict), or the footprint names a thing
    nobody buys as an oriented part at all: a mounting hole, a test point, a
    fiducial, a silk logo, a DRC coupon fixture, a synthetic composite
    (declared — see DECLARED ROWS). Either way ``offset_deg`` is ``None``, so
    it can never be mistaken for a measured zero, and the row carries a
    ``reason`` or a ``detail`` saying why.

THE KEY IS THE PAIR, NEVER THE FOOTPRINT ALONE
----------------------------------------------
A row is keyed by ``(footprint ref, house, catalogue number)`` — the same
three values a board already states, so this store needs no pairing index of
its own (see THE JOIN below).

Keying on the footprint alone is wrong by construction, not by bad luck. A
footprint is a LAND PATTERN, and the generic ones are shared by thousands of
parts: ``Package_TO_SOT_SMD:SOT-23`` is bought as an AO3401A here and could be
bought as any other SOT-23 part tomorrow, drawn by a different vendor to a
different convention. Nor is the fact a property of a part FAMILY: within one
manufacturer, one connector series and one mounting style, ``S2B-PH-SM4-TB``
measures 0 while ``S4B``/``S5B`` measure 180. There is no coarser key than the
pair that is safe, which is why the ``assembly.orientation_convention`` slot
this store replaces was retired rather than filled in.

DECLARED ROWS — the one footprint-wide fact, and its muzzle
-----------------------------------------------------------
A mounting hole has no part number, so it has no pair. "This drawing has no
orientable vendor counterpart, for ANY part" genuinely IS a property of the
footprint alone, and it is a fact worth recording rather than leaving as
silence. Such a row sets ``house``/``part`` to ``None``.

That reopens exactly the door the retired field walked through, so it is
nailed shut by validation rather than by intent: **a footprint-wide row must
be DECLARED, must have verdict ``no_reference``, must carry a ``reason``, and
must carry no numbers at all.** A footprint-wide row therefore CANNOT hold an
offset, so :meth:`OrientationLedger.lookup` preferring the pair row over the
footprint-wide row can never hide one.

The ledger's two populations have two writers that cannot overlap:

* ``measured`` rows are machine-derived and are rewritten WHOLESALE by
  ``pcb/scripts/gen_part_orientation.py``. Hand-editing one is drift, and the
  regeneration test catches it.
* ``declared`` rows are human-authored in
  ``pcb/library/part_orientation_declared.json`` and rendered into the ledger
  from there. They carry no numbers — there is nothing in them for a machine to
  converge on — and they are authored OUTSIDE the artifact so that deleting one
  is drift the regeneration test can see, rather than a change the generator
  quietly agrees with.

DETERMINISM
-----------
The file is a single JSON document, sorted by key, written with the same
formatting as ``footprints.lock.json`` so the two library files diff alike. It
carries no timestamp and no generator version: a clock value would make every
regeneration a diff, which is the opposite of the property wanted here. Re-run
the generator with nothing changed and the file is byte-identical; re-run it
after a seed footprint is edited and exactly that footprint's rows change.
When it was measured is a git question, and git answers it better.

STALENESS WITHOUT THE VENDOR PAYLOAD
------------------------------------
Each measured row pins ``footprint_sha256`` (our side, from the acquisition
lock) and ``vendor_sha256`` (the payload bytes measured). The vendor payloads
are dev-only test-corpus data and do not ship, so a shipped consumer cannot
re-measure — but it CAN compare ``footprint_sha256`` against the lock and
learn that OUR drawing changed since the measurement, which is the half of
staleness that our own edits cause.

THE JOIN — where (footprint, part) comes from for a real board
--------------------------------------------------------------
It comes from the board, and it already exists. ``resolve_assembly`` produces
``ResolvedAssembly.footprint_ref`` and ``ResolvedAssembly.house_parts``, a
sorted ``(house id, catalogue number)`` mapping authored as
``assembly.house_parts: {jlcpcb: C265102}``; the house profile already states
which key it reads (``assembly_outputs``: the ``jlc`` profile reads
``house_parts.jlcpcb``). A gate therefore looks a component up with values it
is already holding at emit time. This module deliberately does NOT carry a
footprint-to-part index: a second one would be a second source of truth for a
fact the board already owns, and the two would disagree the first time a board
switched suppliers.
"""

from __future__ import annotations

import json

from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Iterable, Mapping, Union

from . import part_orientation as po
from . import plugin_root as _plugin_root

_PCB_ROOT = _plugin_root.PCB_ROOT

#: Beside ``footprints.lock.json``, because it is a fact about the seed library
#: and has to ship with it.
DEFAULT_LEDGER_PATH = _PCB_ROOT / "library" / "part_orientation.json"

SCHEMA_VERSION = 1

#: The three states, and the only three. See the module docstring.
STATE_UNKNOWN = "unknown"
STATE_MEASURED = "measured"
STATE_NO_REFERENCE = "no_reference"

STATES = (STATE_UNKNOWN, STATE_MEASURED, STATE_NO_REFERENCE)

#: Keys a MEASURED row serializes. Fixed and explicit: a row is written from
#: this list, and read back by it, so a field added to the dataclass without a
#: decision about persistence cannot silently start or stop being stored.
_MEASURED_KEYS = (
    "footprint", "house", "part", "verdict", "offset_deg", "angle_decided",
    "lands_agree", "residual_mm", "max_pad_error_mm", "runner_up_deg",
    "runner_up_mm", "matched_pad_count", "footprint_sha256", "vendor_sha256",
    "detail",
)

#: Keys a DECLARED row serializes. Short on purpose — a declared row is a
#: human saying "there is nothing to measure here", and every field beyond the
#: identity and the reason would be a number it must not have.
_DECLARED_KEYS = ("footprint", "house", "part", "verdict", "reason")

#: ``declared`` is NOT among either key list: which population a row belongs to
#: is stated by the array it sits in, and storing it twice would let the two
#: disagree.

#: WHAT EACH VERDICT MUST SAY ABOUT ITSELF:
#: ``verdict -> (angle_decided, states an offset, lands_agree)``.
#:
#: This is the table ``part_orientation.measure_orientation`` can actually
#: produce, written down where the LOADER can check it. It exists because
#: "offset implies decided" leaves the converse open, and the converse is where
#: a self-inconsistent row hides: an ``ambiguous`` verdict carrying
#: ``angle_decided=true`` and an offset reads to ``assembly_orientation`` as a
#: measurement and emits its guess. A row is loaded only if the verdict and the
#: numbers beside it tell the same story.
_CONSISTENT = {
    po.VERDICT_ALIGNED: (True, True, True),
    po.VERDICT_ROTATED: (True, True, True),
    # The angle IS settled here; it is the LANDS that disagree. That is the
    # whole reason the two axes are reported separately.
    po.VERDICT_GEOMETRY_MISMATCH: (True, True, False),
    po.VERDICT_AMBIGUOUS: (False, False, None),
    po.VERDICT_INSUFFICIENT_OVERLAP: (False, False, None),
    po.VERDICT_NO_REFERENCE: (False, False, None),
}


class OrientationLedgerError(ValueError):
    """The ledger, or a row in it, is not something this reader will trust.

    Every path here fails CLOSED. A ledger that cannot be read is not an empty
    ledger — an empty ledger reads as "everything is unknown", which a gate
    refuses loudly, whereas a silently-dropped malformed row reads as
    "unknown" for that one pair while every other pair passes. The first is a
    stopped line; the second is a board at the assembly house.
    """


# ---------------------------------------------------------------------------
# One row
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OrientationRecord:
    """What is known about one pair (or, declared-only, one footprint).

    ``offset_deg`` is the CCW rotation carrying the VENDOR's drawing onto OURS,
    the sense ``part_orientation`` pins. It is a rotation in the footprint's
    LOCAL frame, so a consumer ADDS it to a top-side placed rotation and
    SUBTRACTS it from a bottom-side one — see
    ``assembly_orientation.corrected_rotation``, which is the only place either
    sign is written. It is an int only where the angle was decided; ``None``
    everywhere else, including for every ``no_reference`` row. Nothing in this
    module ever defaults it to 0.
    """

    footprint: str
    house: Union[str, None]
    part: Union[str, None]
    verdict: str
    #: True = human-authored, carries no numbers. False = machine-measured.
    declared: bool = False
    #: Declared rows only: why there is nothing to measure against.
    reason: Union[str, None] = None
    offset_deg: Union[int, None] = None
    angle_decided: bool = False
    lands_agree: Union[bool, None] = None
    residual_mm: Union[float, None] = None
    max_pad_error_mm: Union[float, None] = None
    runner_up_deg: Union[int, None] = None
    runner_up_mm: Union[float, None] = None
    matched_pad_count: Union[int, None] = None
    #: Our side's pin at measurement time, from the acquisition lock.
    footprint_sha256: Union[str, None] = None
    #: The vendor payload bytes the measurement read.
    vendor_sha256: Union[str, None] = None
    #: The measurement's own sentence about this pair.
    detail: Union[str, None] = None

    def __post_init__(self) -> None:
        if not isinstance(self.footprint, str) or not self.footprint.strip():
            raise OrientationLedgerError(
                f"a row needs a non-empty footprint ref; got {self.footprint!r}")
        if (self.house is None) != (self.part is None):
            raise OrientationLedgerError(
                f"{self.footprint}: house and part name ONE catalogue entry and "
                f"are stated together or not at all; got house={self.house!r} "
                f"part={self.part!r}. A catalogue number is only unique inside "
                f"its house, so a part without one names nothing")
        for field in ("house", "part"):
            value = getattr(self, field)
            if value is not None and (not isinstance(value, str) or not value.strip()):
                raise OrientationLedgerError(
                    f"{self.footprint}: {field} must be a non-empty string or "
                    f"None; got {value!r}")
        if self.verdict not in po.VERDICTS:
            raise OrientationLedgerError(
                f"{self.footprint}: unknown verdict {self.verdict!r}; "
                f"part_orientation states {'/'.join(po.VERDICTS)}")

        # THE MUZZLE. A footprint-wide row is the one shape that could grow
        # back into the footprint-keyed offset slot this store replaced, so it
        # is confined to a declared no-reference statement carrying no numbers.
        if self.part is None and not self.declared:
            raise OrientationLedgerError(
                f"{self.footprint}: a row with no part is a footprint-wide "
                f"statement and can only be DECLARED. There is no such thing as "
                f"a measurement of a footprint against nothing, and a "
                f"footprint-keyed offset is the exact mistake this store exists "
                f"to stop: one land pattern is bought as many parts whose "
                f"vendors draw them differently")

        if self.declared:
            if self.verdict != po.VERDICT_NO_REFERENCE:
                raise OrientationLedgerError(
                    f"{self.footprint}: a declared row may only say "
                    f"{po.VERDICT_NO_REFERENCE!r} — a human asserting any other "
                    f"verdict is asserting a measurement they did not make; "
                    f"got {self.verdict!r}")
            if not isinstance(self.reason, str) or not self.reason.strip():
                raise OrientationLedgerError(
                    f"{self.footprint}: a declared row must carry a reason. "
                    f"'No vendor drawing' is a claim about the world, and an "
                    f"unexplained claim is indistinguishable from a shrug")
            numbers = {
                "offset_deg": self.offset_deg,
                "residual_mm": self.residual_mm,
                "max_pad_error_mm": self.max_pad_error_mm,
                "runner_up_deg": self.runner_up_deg,
                "runner_up_mm": self.runner_up_mm,
                "matched_pad_count": self.matched_pad_count,
                "lands_agree": self.lands_agree,
                "vendor_sha256": self.vendor_sha256,
                "detail": self.detail,
            }
            stated = sorted(k for k, v in numbers.items() if v is not None)
            if stated or self.angle_decided:
                raise OrientationLedgerError(
                    f"{self.footprint}: a declared row states that there is "
                    f"nothing to measure, so it must carry no measurement; "
                    f"found {'/'.join(stated) or 'angle_decided'}")
        else:
            if self.reason is not None:
                raise OrientationLedgerError(
                    f"{self.footprint}: `reason` belongs to a declared row. A "
                    f"measured row explains itself in `detail`, which the "
                    f"measurement wrote and a human did not")

        if self.offset_deg is not None:
            if self.offset_deg not in po.CANDIDATE_ANGLES:
                raise OrientationLedgerError(
                    f"{self.footprint}: offset_deg {self.offset_deg!r} is not "
                    f"one of {po.CANDIDATE_ANGLES}. Nothing between them is "
                    f"physically orderable")
            if not self.angle_decided:
                raise OrientationLedgerError(
                    f"{self.footprint}: offset_deg {self.offset_deg} is stated "
                    f"but the angle was not decided. An offset nobody could "
                    f"separate from its runner-up is a guess wearing a number")
            if self.verdict == po.VERDICT_NO_REFERENCE:
                raise OrientationLedgerError(
                    f"{self.footprint}: a {po.VERDICT_NO_REFERENCE!r} row "
                    f"cannot carry an offset — there was no drawing to measure "
                    f"it against")

        self._check_verdict_agrees_with_its_numbers()

    def _check_verdict_agrees_with_its_numbers(self) -> None:
        """THE VERDICT AND THE NUMBERS BESIDE IT MUST BE THE SAME STORY.

        "offset implies decided" is only half the invariant, and the other half
        is the dangerous one. A row saying ``verdict="ambiguous"`` with
        ``angle_decided=true`` and ``offset_deg=90`` satisfies the first half
        and is nonsense: the verdict says the drawings did not separate the
        angles and the fields say one of them won. ``assembly_orientation``
        reads ``offset_deg``, so such a row EMITS its guess — and the loader's
        fail-closed claim would not hold for the one shape a hand edit most
        easily produces.

        So the whole table :mod:`part_orientation` can actually produce is
        stated here and nothing outside it loads. Read it as: the verdict is a
        FOLD of the two axes, and a fold that disagrees with its own inputs is
        a corrupt row, not a row with an opinion.
        """
        want = _CONSISTENT.get(self.verdict)
        if want is None:  # a verdict with no table entry would load unchecked
            raise OrientationLedgerError(
                f"{self.footprint}: verdict {self.verdict!r} has no consistency "
                f"rule; every verdict states what its fields must say")
        decided, offset, lands = want
        if self.angle_decided is not decided:
            raise OrientationLedgerError(
                f"{self.footprint}: verdict {self.verdict!r} means the angle "
                f"was {'' if decided else 'NOT '}decided, but angle_decided is "
                f"{self.angle_decided!r}. The verdict is a fold of the two axes "
                f"and cannot disagree with them")
        stated = self.offset_deg is not None
        if stated is not offset:
            raise OrientationLedgerError(
                f"{self.footprint}: verdict {self.verdict!r} "
                f"{'requires' if offset else 'forbids'} an offset, but "
                f"offset_deg is {self.offset_deg!r}")
        if self.lands_agree is not lands:
            raise OrientationLedgerError(
                f"{self.footprint}: verdict {self.verdict!r} means lands_agree "
                f"is {lands!r}, not {self.lands_agree!r}. The land test is the "
                f"axis this verdict reports, so a row that states the other "
                f"answer was not written by the measurement")
        if self.verdict == po.VERDICT_ALIGNED and self.offset_deg != 0:
            raise OrientationLedgerError(
                f"{self.footprint}: {po.VERDICT_ALIGNED!r} means our drawing "
                f"and the vendor's point the same way, so its offset is 0, not "
                f"{self.offset_deg}")
        if self.verdict == po.VERDICT_ROTATED and self.offset_deg == 0:
            raise OrientationLedgerError(
                f"{self.footprint}: {po.VERDICT_ROTATED!r} with an offset of 0 "
                f"is {po.VERDICT_ALIGNED!r}; one drawing state, one verdict")

    # -- identity ----------------------------------------------------------

    @property
    def key(self) -> tuple:
        """The pair this row is about. ``(footprint, None, None)`` when the row
        is a footprint-wide declaration."""
        return (self.footprint, self.house, self.part)

    @property
    def state(self) -> str:
        """This row's state — never ``unknown``, because the row exists."""
        return (STATE_NO_REFERENCE if self.verdict == po.VERDICT_NO_REFERENCE
                else STATE_MEASURED)

    # -- serialization -----------------------------------------------------

    def to_json(self) -> dict:
        keys = _DECLARED_KEYS if self.declared else _MEASURED_KEYS
        return {k: getattr(self, k) for k in keys}

    @classmethod
    def from_json(cls, raw: Any, *, declared: bool) -> "OrientationRecord":
        if not isinstance(raw, Mapping):
            raise OrientationLedgerError(
                f"a ledger row must be an object; got {type(raw).__name__}")
        allowed = set(_DECLARED_KEYS if declared else _MEASURED_KEYS)
        unknown = sorted(set(raw) - allowed)
        if unknown:
            raise OrientationLedgerError(
                f"ledger row {raw.get('footprint')!r} has unknown key(s) "
                f"{'/'.join(unknown)}; a {'declared' if declared else 'measured'} "
                f"row takes {'/'.join(sorted(allowed))}. Refused rather than "
                f"ignored: a field this reader drops is a field a writer thinks "
                f"it stored")
        missing = sorted(allowed - set(raw))
        if missing:
            raise OrientationLedgerError(
                f"ledger row {raw.get('footprint')!r} is missing "
                f"{'/'.join(missing)}; every key is written explicitly so an "
                f"absent one means the file was hand-edited, not that the value "
                f"defaults")
        return cls(declared=declared, **dict(raw))


def state_of(record: Union[OrientationRecord, None]) -> str:
    """The three-state fold, and the only one.

    ``None`` — what :meth:`OrientationLedger.lookup` returns for a pair with no
    row — is :data:`STATE_UNKNOWN`. Read that way ONCE, here, so no consumer
    gets to decide for itself that a missing row means "no rotation needed".
    """
    return STATE_UNKNOWN if record is None else record.state


# ---------------------------------------------------------------------------
# The ledger
# ---------------------------------------------------------------------------


def _sorted(rows: Iterable[OrientationRecord]) -> tuple:
    return tuple(sorted(rows, key=lambda r: (r.footprint, r.house or "",
                                             r.part or "")))


@dataclass(frozen=True)
class OrientationLedger:
    """Every part-orientation fact we hold, and nothing we do not.

    Two populations, kept apart because they have different writers — see the
    module docstring's DECLARED ROWS section.
    """

    declared: tuple = ()
    measured: tuple = ()

    def __post_init__(self) -> None:
        object.__setattr__(self, "declared", _sorted(self.declared))
        object.__setattr__(self, "measured", _sorted(self.measured))
        seen: dict = {}
        for row in self.rows:
            if row.key in seen:
                raise OrientationLedgerError(
                    f"{row.footprint}: two rows for the same key {row.key}. One "
                    f"pair, one answer — a duplicate makes which answer wins a "
                    f"question about file order")
            seen[row.key] = row
        object.__setattr__(self, "_index", seen)

    @property
    def rows(self) -> tuple:
        return self.declared + self.measured

    def lookup(self,
               footprint: str,
               house: Union[str, None] = None,
               part: Union[str, None] = None,
               ) -> Union[OrientationRecord, None]:
        """The row for this pair, or ``None`` — which means UNKNOWN.

        The exact pair wins; failing that, the footprint's own declaration is
        consulted, because "this drawing has no orientable vendor counterpart"
        holds for whatever part is bought against it. That precedence is safe
        in one direction only, and it is the safe one: a footprint-wide row is
        validated to be a declared ``no_reference`` carrying no numbers, so
        falling back to it can never substitute an offset for a measurement.

        ``None`` back is NOT an answer about rotation. Pass it through
        :func:`state_of`; do not read it as zero.
        """
        index = getattr(self, "_index")
        if house is not None and part is not None:
            hit = index.get((footprint, house, part))
            if hit is not None:
                return hit
        return index.get((footprint, None, None))

    def state(self, footprint: str,
              house: Union[str, None] = None,
              part: Union[str, None] = None) -> str:
        """:func:`state_of` applied to :meth:`lookup` — the whole question in
        one call, for a consumer that only needs the state."""
        return state_of(self.lookup(footprint, house, part))

    # -- serialization -----------------------------------------------------

    def to_json(self) -> dict:
        return {
            "schema_version": SCHEMA_VERSION,
            "declared": [r.to_json() for r in self.declared],
            "measured": [r.to_json() for r in self.measured],
        }

    def to_text(self) -> str:
        """The canonical bytes. Same formatting as ``footprints.lock.json`` —
        tab indent, sorted keys, ASCII-escaped, one trailing newline — so the
        two library files read alike in a diff and neither reformats the other
        by habit."""
        return json.dumps(self.to_json(), indent="\t", sort_keys=True) + "\n"

    @classmethod
    def from_json(cls, doc: Any) -> "OrientationLedger":
        if not isinstance(doc, Mapping):
            raise OrientationLedgerError(
                f"the ledger must be an object; got {type(doc).__name__}")
        version = doc.get("schema_version")
        if version != SCHEMA_VERSION:
            raise OrientationLedgerError(
                f"ledger schema_version {version!r} is not {SCHEMA_VERSION}; "
                f"refusing rather than guessing which fields still mean what "
                f"they used to")
        unknown = sorted(set(doc) - {"schema_version", "declared", "measured"})
        if unknown:
            raise OrientationLedgerError(
                f"ledger has unknown top-level key(s) {'/'.join(unknown)}")
        out = {}
        for name, declared in (("declared", True), ("measured", False)):
            rows = doc.get(name)
            if not isinstance(rows, list):
                raise OrientationLedgerError(
                    f"ledger `{name}` must be a list; got "
                    f"{type(rows).__name__}. Both arrays are written even when "
                    f"empty, so an absent one means a truncated file")
            out[name] = tuple(OrientationRecord.from_json(r, declared=declared)
                              for r in rows)
        return cls(**out)

    def with_measured(self, rows: Iterable[OrientationRecord]) -> "OrientationLedger":
        """This ledger's declared rows plus a fresh measured population.

        The regeneration step: measured rows are REPLACED wholesale rather than
        merged, so a pair dropped from the corpus leaves no orphan behind and a
        re-run converges instead of accumulating.
        """
        return replace(self, measured=tuple(rows))


# ---------------------------------------------------------------------------
# Loading, and building a row from a measurement
# ---------------------------------------------------------------------------


def load_ledger(path: Union[str, Path, None] = None) -> OrientationLedger:
    """Read the ledger. A missing file is an ERROR, not an empty ledger.

    An empty ledger and a missing one differ: the first says "nothing has been
    measured", which is a claim someone made; the second says the shipped data
    is not there, which is a broken install. Reading the second as the first
    would make every pair quietly unknown at exactly the moment nothing is
    verifiable.
    """
    p = Path(path) if path is not None else DEFAULT_LEDGER_PATH
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise OrientationLedgerError(
            f"cannot read the part-orientation ledger at {p}: {exc}") from exc
    try:
        doc = json.loads(text)
    except ValueError as exc:
        raise OrientationLedgerError(
            f"{p} is not valid JSON: {exc}") from exc
    return OrientationLedger.from_json(doc)


def record_from_measurement(footprint: str,
                            house: str,
                            part: str,
                            measurement: po.OrientationMeasurement,
                            *,
                            footprint_sha256: str,
                            vendor_sha256: str,
                            ) -> OrientationRecord:
    """Project one :class:`~pcb_worker.part_orientation.OrientationMeasurement`
    onto a measured row.

    ``offset_deg`` is carried ONLY where the measurement decided the angle —
    including under a ``geometry_mismatch`` verdict, where the rotation is
    settled even though the lands disagree. The verdict and ``lands_agree``
    ride along with it, and they are not decoration: ``assembly_orientation``
    REFUSES a mismatched pair rather than applying its offset, because that
    offset is the angle to a different part. Storing the number keeps the
    finding readable for whoever has to work out which of the two drawings is
    wrong; the gate is what stops it shipping.

    Where the angle was not decided the offset is dropped rather than stored
    with a caveat, because a stored number is a number somebody will eventually
    add to a rotation.
    """
    decided = bool(measurement.angle_decided)
    return OrientationRecord(
        footprint=footprint,
        house=house,
        part=part,
        verdict=measurement.verdict,
        declared=False,
        offset_deg=measurement.offset_deg if decided else None,
        angle_decided=decided,
        lands_agree=measurement.lands_agree,
        residual_mm=measurement.residual_mm,
        max_pad_error_mm=measurement.max_pad_error_mm,
        runner_up_deg=measurement.runner_up_deg,
        runner_up_mm=measurement.runner_up_mm,
        matched_pad_count=len(measurement.matched_pads) or None,
        footprint_sha256=footprint_sha256,
        vendor_sha256=vendor_sha256,
        detail=measurement.detail,
    )
