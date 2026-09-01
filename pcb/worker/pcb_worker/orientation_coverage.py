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

WHAT "ACCOUNTED FOR" MEANS, AND THE ONE THING IT MUST NOT MEAN
---------------------------------------------------------------
A footprint is accounted for when it either

* has at least one MEASURED pair — somebody compared our drawing with a
  vendor's drawing of a real catalogue part, or
* carries a DECLARED footprint-wide ``no_reference`` — a human stating that no
  vendor sells an oriented part drawn as this land pattern at all.

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

#: The three per-footprint states. Deliberately the ledger's own names: a
#: footprint's coverage state is the state of what the ledger holds about it,
#: and a second vocabulary would be a second definition of "unknown".
STATE_MEASURED = ol.STATE_MEASURED
STATE_NO_REFERENCE = ol.STATE_NO_REFERENCE
STATE_UNKNOWN = ol.STATE_UNKNOWN

REGEN_COMMAND = "python3 pcb/scripts/gen_part_orientation.py"


@dataclass(frozen=True)
class FootprintCoverage:
    """What the ledger holds about ONE footprint in the acquisition lock."""

    footprint: str
    state: str
    #: Measured pairs, ``(house, part, offset_deg or None)``, sorted.
    pairs: tuple = ()
    #: Declared rows only: the human's stated reason.
    reason: Union[str, None] = None
    #: Catalogue numbers the LOCK already names for this footprint. A lead, not
    #: a pairing — see the module docstring.
    lock_parts: tuple = ()

    @property
    def undecided(self) -> tuple:
        """Measured pairs whose angle the drawings did not settle.

        These are covered — somebody looked — but the gate still refuses them,
        so they are a second, quieter kind of gap and the report names them
        separately rather than hiding them inside the measured count.
        """
        return tuple(p for p in self.pairs if p[2] is None)


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

    @property
    def undecided(self) -> tuple:
        """Every measured pair, across all footprints, that states no offset."""
        return tuple((e.footprint,) + p
                     for e in self.entries for p in e.undecided)

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
        measured_by_ref.setdefault(row.footprint, []).append(
            (row.house, row.part, row.offset_deg))
    declared_by_ref = {row.footprint: row for row in ledger.declared}

    entries = []
    for ref in sorted(lock):
        pairs = tuple(sorted(measured_by_ref.get(ref, ())))
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
therefore REFUSES to emit a rotation for a part bought as a catalogue number
whose pair nobody has measured. This file is that refusal's contents, listed
ahead of time: the **UNKNOWN** section below is the set of drawings an order
could still stop on.

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
        "`assembly_orientation_unknown`. To close one, add the vendor's package "
        "payload for the part it is bought as to "
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
    if report.measured:
        for entry in report.measured:
            out.append(f"- `{entry.footprint}`")
            for house, part, offset in entry.pairs:
                stated = (f"{offset} deg" if offset is not None
                          else "NO OFFSET — the drawings did not settle the angle")
                out.append(f"  - {house} `{part}` — {stated}")
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
        "DRC coupon fixture, an in-repo synthesized fixture land, or a synthetic "
        "composite standing for several physical parts.\n")
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
    if report.undecided:
        for ref, house, part, _ in report.undecided:
            out.append(f"- `{ref}` — {house} `{part}`")
    else:
        out.append("_None._")
    out.append("")

    out.append("## Rows about footprints the lock no longer carries\n")
    if report.orphans:
        for ref in report.orphans:
            out.append(f"- `{ref}`")
    else:
        out.append("_None._")
    out.append("")

    return "\n".join(out)


def _join(parts: tuple) -> str:
    return ", ".join(f"`{p}`" for p in parts)
