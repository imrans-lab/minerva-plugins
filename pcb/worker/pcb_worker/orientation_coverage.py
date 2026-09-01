"""Which shipped footprints the orientation ledger actually accounts for — and,
the part that matters, which ones it does NOT.

WHY THIS EXISTS
---------------
``assembly_orientation`` refuses to emit a position file for a part bought as a
catalogue number whose pair nobody ever measured. That refusal is correct and
it is loud, but it arrives at the WORST MOMENT: a person finds out the ledger
has a hole when an order package they were trying to send stops.

The hole is knowable long before that. The acquisition lock states every
footprint we ship; the ledger states every footprint we have something to say
about. The difference between those two sets is the coverage gap, and it is a
pure function of two committed files. This module is that difference, computed
and rendered, so the gap is a thing you can READ instead of a thing you
discover.

    This module answers a question about the LIBRARY, not about a board. It
    never refuses anything and nothing on the order path calls it. A gap is not
    an error — it is a fact about how far the measuring has got.

THIS IS FOOTPRINT-LEVEL SAMPLING. IT IS NOT EXHAUSTIVE REFUSAL COVERAGE
------------------------------------------------------------------------
Read this before quoting a number out of the report.

The GATE is keyed on the PAIR — our drawing and one house catalogue number.
This fold is keyed on the FOOTPRINT, and a footprint counts as measured as soon
as ONE pair on it has been. Those are different questions, and only one of them
is answerable from the tree: nothing here knows which catalogue parts a future
board will buy, so the set of pairs an order could hit cannot be enumerated at
all. A measured SOT-23 still refuses for every OTHER SOT-23 catalogue part, and
that refusal cannot appear in this file.

So the UNKNOWN list is a LOWER BOUND on what an order can stop on — drawings
where not even one pair has been done — and never the complete set. The measured
list says which PAIRS have been done, which is the honest claim and the reason
the pairs are printed rather than counted.

WHAT "ACCOUNTED FOR" MEANS, AND THE ONE THING IT MUST NOT MEAN
---------------------------------------------------------------
A footprint is accounted for when it either

* has at least one MEASURED row — somebody put our drawing beside a vendor's
  drawing of a real catalogue part and wrote down what came of it, or
* carries a DECLARED footprint-wide ``no_reference`` — a human stating that no
  vendor sells an oriented part drawn as this land pattern at all.

"Accounted for" is not "will pass". A measured row can still refuse: an
``ambiguous`` one states no offset, and a ``geometry_mismatch`` states one
measured against a drawing of a different part. Both are listed in their own
sections, because a reader looking for what can stop an order needs them beside
the unknowns rather than folded into the measured count.

Everything else is UNKNOWN, and unknown is reported as unknown. A coverage
number is only worth having if it is honest, and the one way to make this
report worthless is to close a gap by declaring a footprint that IS a
purchasable package. ``lookup`` falls back to the footprint-wide declaration
for ANY part bought on that ref, so such a declaration does not merely
mis-state the count — it silently disarms the gate for every part placed on
that drawing, and ships the rotation unmeasured. An absent row refuses loudly;
a wrong declaration ships quietly. The count is the cheaper thing to be wrong
about, so this module counts and never fixes.

WHAT THE REPORT CAN SAY ABOUT A GAP WITHOUT INVENTING ONE
----------------------------------------------------------
The acquisition lock's ``assembly.dist_part_numbers``/``assembly.mpn`` already
name, for a few entries, the catalogue part that entry was drawn for. Where
they do, the report repeats them beside the gap — not as a pairing (nothing
here writes a ledger row) but as the next payload somebody could fetch. Where
the lock names nothing, the report says so, which is the honest shape of "we do
not even know what this would be bought as".
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Union

from . import orientation_ledger as ol
from . import part_orientation as po

#: The three per-footprint states. Deliberately the ledger's own names: a
#: footprint's coverage state is the state of what the ledger holds about it,
#: and a second vocabulary would be a second definition of "unknown".
STATE_MEASURED = ol.STATE_MEASURED
STATE_NO_REFERENCE = ol.STATE_NO_REFERENCE
STATE_UNKNOWN = ol.STATE_UNKNOWN

REGEN_COMMAND = "python3 pcb/scripts/gen_part_orientation.py"


@dataclass(frozen=True)
class PairCoverage:
    """One MEASURED row, read as what it means for an order.

    The verdict rides along beside the offset because the two together decide
    what the emitter does, and neither alone does. An absent offset is a
    refusal under ``ambiguous`` and a PASS under ``no_reference``; a stated
    offset is applied under ``rotated`` and REFUSED under ``geometry_mismatch``.
    A report that carried only the offset would have to guess, and it guessed
    wrong in both directions before this field existed.
    """

    house: str
    part: str
    offset_deg: Union[int, None]
    verdict: str

    @property
    def emits(self) -> bool:
        """Does an order carrying this pair get a position file?

        The same fold ``assembly_orientation.correct`` performs, stated once here
        so the report cannot describe a different emitter than the one that
        runs. Only two shapes emit: a decided offset whose lands agree, and a
        pair with nothing to measure against.
        """
        if self.verdict == po.VERDICT_NO_REFERENCE:
            return True
        return (self.offset_deg is not None
                and self.verdict != po.VERDICT_GEOMETRY_MISMATCH)


@dataclass(frozen=True)
class FootprintCoverage:
    """What the ledger holds about ONE footprint in the acquisition lock."""

    footprint: str
    state: str
    #: Measured rows for this footprint, as :class:`PairCoverage`, sorted.
    pairs: tuple = ()
    #: Declared rows only: the human's stated reason.
    reason: Union[str, None] = None
    #: Catalogue numbers the LOCK already names for this footprint. A lead, not
    #: a pairing — see the module docstring.
    lock_parts: tuple = ()

    @property
    def undecided(self) -> tuple:
        """Measured pairs whose angle the drawings did not settle.

        NOT simply "no offset stated": a ``no_reference`` pair states no offset
        either, and it EMITS — there was nothing to measure against, so there
        is no correction and the placed rotation goes out verbatim. Folding the
        two together reported a passing pair as a refusing one, which is the
        opposite of the mistake this report exists to avoid but a lie all the
        same.
        """
        return tuple(p for p in self.pairs
                     if p.offset_deg is None
                     and p.verdict != po.VERDICT_NO_REFERENCE)

    @property
    def mismatched(self) -> tuple:
        """Measured pairs whose angle came out and whose LANDS DISAGREE.

        These carry an offset and still refuse: it is the angle between our
        drawing and a drawing of something else. A third quiet gap, and the one
        that most often means a wrong catalogue number.
        """
        return tuple(p for p in self.pairs
                     if p.verdict == po.VERDICT_GEOMETRY_MISMATCH)

    @property
    def unmeasurable(self) -> tuple:
        """Measured pairs that found nothing to measure against, and PASS."""
        return tuple(p for p in self.pairs
                     if p.verdict == po.VERDICT_NO_REFERENCE)


@dataclass(frozen=True)
class CoverageReport:
    """The whole lock, folded against the whole ledger."""

    entries: tuple = ()
    #: Ledger footprints the lock does not carry — a row about a drawing we no
    #: longer ship. The generator refuses to produce one, so this should always
    #: be empty; it is reported rather than asserted because an empty list a
    #: reader can see beats an invariant they cannot.
    orphans: tuple = ()

    def _in(self, state: str) -> tuple:
        return tuple(e for e in self.entries if e.state == state)

    @property
    def measured(self) -> tuple:
        return self._in(STATE_MEASURED)

    @property
    def declared(self) -> tuple:
        return self._in(STATE_NO_REFERENCE)

    @property
    def unknown(self) -> tuple:
        return self._in(STATE_UNKNOWN)

    def _pairs(self, name: str) -> tuple:
        return tuple((e.footprint, p)
                     for e in self.entries for p in getattr(e, name))

    @property
    def undecided(self) -> tuple:
        """``(footprint, pair)`` for every measured pair that could not settle
        an angle — covered, and still refused."""
        return self._pairs("undecided")

    @property
    def mismatched(self) -> tuple:
        """``(footprint, pair)`` for every measured pair whose lands disagree —
        covered, carrying a number, and still refused."""
        return self._pairs("mismatched")

    @property
    def unmeasurable(self) -> tuple:
        """``(footprint, pair)`` for every measured pair with no vendor drawing
        behind it. These PASS; they are listed so "no offset" is never read as
        "refused"."""
        return self._pairs("unmeasurable")

    def counts(self) -> dict:
        return {
            STATE_MEASURED: len(self.measured),
            STATE_NO_REFERENCE: len(self.declared),
            STATE_UNKNOWN: len(self.unknown),
            "total": len(self.entries),
        }

    def to_markdown(self) -> str:
        return _render(self)


def coverage(ledger: ol.OrientationLedger,
             lock: Mapping) -> CoverageReport:
    """Fold *ledger* against the acquisition *lock* — the whole question, once.

    *lock* is the mapping ``pcb_worker.footprints.load_lockfile`` returns: ref
    -> entry. The lock is the authority on what we SHIP, so it and not the
    ledger decides which footprints are in scope; a footprint the ledger has
    never heard of is exactly the case this report is for.
    """
    measured_by_ref: dict = {}
    for row in ledger.measured:
        measured_by_ref.setdefault(row.footprint, []).append(PairCoverage(
            house=row.house, part=row.part, offset_deg=row.offset_deg,
            verdict=row.verdict))
    declared_by_ref = {row.footprint: row for row in ledger.declared}

    entries = []
    for ref in sorted(lock):
        # Sorted on the KEY alone. The ledger guarantees one row per pair, so
        # this is a total order, and it never compares an offset against a
        # `None` one.
        pairs = tuple(sorted(measured_by_ref.get(ref, ()),
                             key=lambda p: (p.house, p.part)))
        declaration = declared_by_ref.get(ref)
        if pairs:
            state = STATE_MEASURED
        elif declaration is not None:
            state = STATE_NO_REFERENCE
        else:
            state = STATE_UNKNOWN
        entries.append(FootprintCoverage(
            footprint=ref,
            state=state,
            pairs=pairs,
            reason=declaration.reason if declaration is not None else None,
            lock_parts=_lock_parts(lock[ref]),
        ))

    known = set(lock)
    orphans = tuple(sorted({row.footprint for row in ledger.rows} - known))
    return CoverageReport(entries=tuple(entries), orphans=orphans)


def _lock_parts(entry: Mapping) -> tuple:
    """Catalogue/manufacturer numbers the lock entry already names, sorted.

    Read straight off the lock and never combined with anything: this is a
    lead for whoever fetches the next vendor payload, not a claim that the
    footprint is bought as these.
    """
    assembly = entry.get("assembly") if isinstance(entry, Mapping) else None
    if not isinstance(assembly, Mapping):
        return ()
    out = set()
    dist = assembly.get("dist_part_numbers")
    if isinstance(dist, (list, tuple)):
        out.update(str(p).strip() for p in dist if str(p).strip())
    mpn = assembly.get("mpn")
    if isinstance(mpn, str) and mpn.strip():
        out.add(mpn.strip())
    return tuple(sorted(out))


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

_HEADER = """# Part-orientation coverage

**This file is GENERATED. Do not hand-edit it.**

Regenerate with:

    {command}

Every footprint in the acquisition lock (`pcb/library/footprints.lock.json`),
folded against the part-orientation ledger (`pcb/library/part_orientation.json`).

A pick-and-place machine reads a position file's rotation against the VENDOR's
drawing of the part, not against our `.kicad_mod`. `pcb_worker.assembly_orientation`
therefore REFUSES to emit a rotation for a PAIR — our drawing and one house
catalogue number — that nobody has measured.

## This report is footprint-level SAMPLING, not exhaustive refusal coverage

Read this before quoting a number out of it. The gate is keyed on the PAIR;
this fold is keyed on the FOOTPRINT, and a footprint counts as measured as soon
as ONE pair on it has been. A measured `SOT-23` still refuses for every other
`SOT-23` catalogue part, and that refusal cannot be listed here: nothing in the
tree knows which catalogue parts a future board will buy, so the set of pairs an
order could hit is not enumerable at all.

So the **UNKNOWN** section is a LOWER BOUND on what an order can stop on —
drawings where not even one pair has been done. It is not the whole set. The
**Measured** section is the honest claim: it lists the PAIRS that have been
measured, one line each, which is why they are printed rather than counted.

"Measured" is also not "passes". A measured pair still refuses when the
drawings could not settle an angle, and when they settled one against a land
pattern that is not ours. Both have their own sections below.

An unknown footprint is not a defect. It is a drawing nobody has yet paired
with a real vendor drawing of a real catalogue part, and it stays unknown until
somebody does — closing it by declaring "no vendor drawing exists" for a
genuine purchasable package would disarm the gate for every part placed on that
drawing, which is far worse than the gap.
"""


def _render(report: CoverageReport) -> str:
    counts = report.counts()
    out = [_HEADER.format(command=REGEN_COMMAND)]

    out.append("## Summary\n")
    out.append("| state | footprints |")
    out.append("| --- | --- |")
    out.append(f"| measured | {counts[STATE_MEASURED]} |")
    out.append(f"| declared no-reference | {counts[STATE_NO_REFERENCE]} |")
    out.append(f"| **unknown** | **{counts[STATE_UNKNOWN]}** |")
    out.append(f"| total in the acquisition lock | {counts['total']} |")
    out.append("")

    out.append("## UNKNOWN — nothing has ever measured this drawing\n")
    out.append(
        "An order that buys a catalogue part on one of these refuses with "
        "`assembly_orientation_unknown`. So does a catalogue part nobody has "
        "measured on a drawing listed as MEASURED below — this section is the "
        "lower bound, not the whole set of refusals. To close one, add the "
        "vendor's package payload for the part it is bought as to "
        "`pcb/worker/tests/testdata/vendor_footprints/`, pair it in that "
        "directory's `index.json`, and regenerate. Where the lock already names "
        "a catalogue number it is repeated below as a LEAD — it is not a pairing "
        "and nothing has been measured against it.\n")
    if report.unknown:
        for entry in report.unknown:
            lead = (f" — the lock names {_join(entry.lock_parts)}"
                    if entry.lock_parts else
                    " — the lock names no catalogue part for it")
            out.append(f"- `{entry.footprint}`{lead}")
    else:
        out.append("_None. Every shipped footprint is measured or declared._")
    out.append("")

    out.append("## Measured — compared against a vendor's drawing\n")
    out.append(
        "One line per PAIR, because the pair is what the gate is keyed on. A "
        "footprint appears here as soon as one of its pairs has been measured; "
        "any OTHER catalogue part on the same drawing is still unknown and "
        "still refuses.\n")
    if report.measured:
        for entry in report.measured:
            out.append(f"- `{entry.footprint}`")
            for pair in entry.pairs:
                out.append(f"  - {pair.house} `{pair.part}` — {_pair_state(pair)}")
    else:
        out.append("_None._")
    out.append("")

    out.append("## Declared no-reference — nothing orderable is drawn like this\n")
    out.append(
        "A human statement that no vendor sells an oriented part drawn as this "
        "land pattern, for ANY catalogue number. These carry no offset and the "
        "emitter passes such a part's placed rotation through untouched, so the "
        "bar for adding one is that the drawing is genuinely not a purchasable "
        "package — a mounting hole, a fiducial, a test point, silk artwork, a "
        "DRC coupon fixture, or an in-repo synthesized fixture land. A drawing "
        "that stands for several physical parts is NOT one of them: the parts "
        "are bought, so the land is measurable pair by pair, and a "
        "footprint-wide declaration would emit every one of them unchecked.\n")
    if report.declared:
        for entry in report.declared:
            out.append(f"- `{entry.footprint}` — {entry.reason}")
    else:
        out.append("_None._")
    out.append("")

    out.append("## Measured but undecided — covered, and still refused\n")
    out.append(
        "A pair somebody measured where the drawings did not separate one angle "
        "from the next. It states no offset, so the emitter refuses it with "
        "`assembly_orientation_undecided`. Listed apart from the measured count "
        "because a reader looking for what can stop an order needs both.\n")
    _list_pairs(out, report.undecided)

    out.append("## Measured, and the lands DISAGREE — covered, and still refused\n")
    out.append(
        "A pair whose angle came out and whose pads do not sit where the "
        "vendor's do. It carries an offset and the emitter still refuses it "
        "(`assembly_orientation_geometry_mismatch`): that offset is the angle "
        "between our drawing and a drawing of a DIFFERENT part, and applying it "
        "would turn a detected mispairing into a trusted production rotation. "
        "The commonest cause is a wrong catalogue number, so check the part "
        "before either drawing.\n")
    _list_pairs(out, report.mismatched)

    out.append("## Measured, and there was nothing to measure against — PASSES\n")
    out.append(
        "The vendor ships no usable package drawing for this particular part. "
        "That is a finding, not a failure to look: no correction exists, none "
        "is applied, and the placed rotation is emitted verbatim. Listed so "
        "that a pair with no offset is never read as a refusal — unlike the two "
        "sections above, these do not stop an order.\n")
    _list_pairs(out, report.unmeasurable)

    out.append("## Rows about footprints the lock no longer carries\n")
    if report.orphans:
        for ref in report.orphans:
            out.append(f"- `{ref}`")
    else:
        out.append("_None._")
    out.append("")

    return "\n".join(out)


def _pair_state(pair: PairCoverage) -> str:
    """One pair's line: the number if it has one, and what happens either way.

    Every branch says whether an order STOPS, because an offset alone does not
    tell a reader that — a stated offset refuses under a geometry mismatch and
    an absent one passes under no_reference.
    """
    if pair.verdict == po.VERDICT_NO_REFERENCE:
        return ("no vendor drawing for this part — no correction exists, and "
                "the placed rotation is emitted verbatim")
    if pair.verdict == po.VERDICT_GEOMETRY_MISMATCH:
        # A mismatch states an offset only where the angle came out. Where it
        # did not, the lands disagree at every candidate angle and there is no
        # number to print — "None deg" would read as a measurement.
        if pair.offset_deg is None:
            return ("THE LANDS DISAGREE at every angle, and none of them "
                    "settled — refused; these are not the same land pattern")
        return (f"{pair.offset_deg} deg, but THE LANDS DISAGREE — refused; "
                f"this is the angle to a different part")
    if pair.offset_deg is None:
        return "NO OFFSET — the drawings did not settle the angle; refused"
    return f"{pair.offset_deg} deg"


def _list_pairs(out: list, pairs: tuple) -> None:
    if pairs:
        for ref, pair in pairs:
            out.append(f"- `{ref}` — {pair.house} `{pair.part}`")
    else:
        out.append("_None._")
    out.append("")


def _join(parts: tuple) -> str:
    return ", ".join(f"`{p}`" for p in parts)
