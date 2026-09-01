"""The measured part-orientation offset, applied to the emitted CPL rotation —
and the refusal when nobody ever measured.

WHY THIS IS A SEPARATE STEP
---------------------------
:mod:`assembly_outputs` owns ONE piece of arithmetic — X verbatim, Y negated,
rotation verbatim — and that frame contract was derived against a real position
file and independently re-derived since. It is not what is wrong with our
position files. What is wrong is that the rotation it emits verbatim is
measured against OUR footprint drawing, while the machine reads it against the
VENDOR's. Those are two different facts, so they get two different steps: the
frame map stays untouched in ``assembly_outputs._walk``, and the per-part
correction happens here, once, over the finished rows.

THE SIGN. IT DEPENDS ON THE SIDE, AND HERE IS THE DERIVATION
------------------------------------------------------------
``offset_deg`` from :mod:`orientation_ledger` is the rotation that carries the
VENDOR's drawing onto OURS, in the sense :mod:`part_orientation` pins::

    our_drawing = rotate(vendor_drawing, offset_deg)

Write ``O`` for our drawing, ``V`` for the vendor's, ``R(a)`` for a rotation by
``a``, ``M`` for the mirror a bottom-side placement applies to local Y (which is
what ``geometry.PlacementTransform.point`` does before it rotates), and ``rho``
for the placed rotation. Then ``O = R(theta)·V`` with ``theta = offset_deg``.

TOP. Our copper on the board, and what the machine puts there for the ``R`` the
file states::

    copper  = R(rho)·O = R(rho)·R(theta)·V = R(rho + theta)·V
    machine = R(R)·V
    =>  R = rho + theta          an ADDITION

BOTTOM. The placement mirrors before it rotates, and so does the machine::

    copper  = R(rho)·M·O = R(rho)·M·R(theta)·V
    machine = R(R)·M·V

A planar mirror CONJUGATES a rotation into its inverse — ``M·R(theta) =
R(-theta)·M`` — so the copper regroups as ``R(rho - theta)·M·V`` and::

    =>  R = rho - theta          a SUBTRACTION

The mirror does NOT cancel. It cancels for a rotation stated in the BOARD frame,
which ``rho`` is; ``theta`` is stated in the footprint's LOCAL frame, inside the
mirror, and a local rotation under a mirrored placement always contributes with
the opposite sign. This is not a new convention: it is exactly the rule this
repo already applies to an expansion child's ``rotation_deg`` in
``geometry.PlacementTransform.angle`` and ``assembly_anchor`` — bottom
subtracts, top adds — and a vendor offset is a local-frame rotation just as a
child rotation is.

:func:`corrected_rotation` is the only place either sign is written, and it
takes the side rather than defaulting to one.

THE TRAP: A WRONG SIGN IS INVISIBLE ON MOST PARTS
-------------------------------------------------
``R + 180`` and ``R - 180`` are the same number modulo 360, and nine of the
eleven pairs measured so far are 0 or 180. A suite assembled only out of those
passes with EITHER sign on EITHER side, and ships every quarter-turn part a
quarter turn out. Only a 90 or a 270 can falsify it, which is why
``tests/test_assembly_orientation.py`` builds its fixture board around
``TSOT-23-6``/``C780769`` and ``VQFN-16``/``C910544`` -- the two measured 270s
-- and asserts their emitted numbers, on BOTH sides, as hand-derived literals
rather than as the expression this module computes.

THE JOIN, AND WHAT "BOUGHT AS A CATALOGUE PART" MEANS
-----------------------------------------------------
A ledger row is keyed on the PAIR ``(our footprint ref, house, catalogue
number)``, never on the footprint alone: one land pattern is bought as many
parts, and their vendors draw them differently. Both halves of that key are
values the emitter is already holding when it builds a row --
``ResolvedAssembly.footprint_ref`` and the house catalogue number the selected
profile reads out of ``assembly.house_parts`` -- so this module invents no
index of its own and reads no board.

A placement is therefore GATED when it is populated AND its component names a
catalogue number for the selected house. That is the definition of "bought as a
catalogue part": it is the same pair the ledger is keyed on, and without it
there is nothing a measurement could ever have been made against.

    KNOWN GAP, deliberately not closed here: a board may also identify a part
    by ``assembly.mpn`` alone, which the BOM's part-number column falls back
    to. Such a part is bought, is placed, and is NOT gated, because ``mpn`` is
    a MANUFACTURER's number and the ledger's key half is a HOUSE catalogue
    number -- joining the two would be inventing exactly the loose key the
    ledger refuses to have. Closing it means deciding what an mpn-only board
    means, which is a board-schema question and not this step's.

THE THREE STATES, AND WHAT EACH ONE EMITS
-----------------------------------------
``measured``, offset stated
    Apply it with the sign the placement's SIDE calls for. This is the whole
    point.

``measured``, offset ``None``
    We looked and the drawings did not settle it (``ambiguous``,
    ``insufficient_overlap``, an undecided ``geometry_mismatch``). REFUSED
    (:data:`CODE_UNDECIDED`). A measurement that could not choose is not a
    licence to emit zero.

``no_reference``
    There is nothing to measure AGAINST -- a mounting hole, a fiducial, a test
    point, a part whose vendor ships no usable package drawing. NOT a refusal:
    no correction exists, none is applied, and the placed rotation is emitted
    verbatim exactly as it was before this step existed.

``unknown`` -- no row at all
    REFUSED (:data:`CODE_UNKNOWN`), by name, naming the component and the pair.
    This is the state the whole line of work exists for. Emitting the placed
    rotation here would be treating "we do not know" as "no rotation needed",
    and that is precisely the silent default that soldered parts down turned:
    a rotationally symmetric pad field makes it invisible in a 3D preview, and
    there is no human check downstream of the file.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Sequence, Union

from . import orientation_ledger as ol

#: Stable refusal names. Same contract as ``assembly_gates``' codes: a surface
#: matches on the code and SHOWS the sentence.
CODE_UNKNOWN = "assembly_orientation_unknown"
CODE_UNDECIDED = "assembly_orientation_undecided"

#: The authored key a refusal points a person at. Both refusals are about the
#: pair, and the catalogue number is the half a board author writes.
FIELD_HOUSE_PARTS = "assembly.house_parts"

REGEN_COMMAND = "python3 pcb/scripts/gen_part_orientation.py"


class AssemblyOrientationError(ValueError):
    """One named refusal from this step.

    Carries ``code``/``component``/``field`` the same way
    ``assembly_gates.AssemblyGateError`` and ``assembly_outputs``' own errors
    do, so ``methods._assembly_refusal`` renders it without a special case."""

    def __init__(self, code: str, message: str, *,
                 component: Union[str, None] = None,
                 field: Union[str, None] = None):
        super().__init__(message)
        self.code = code
        self.component = component
        self.field = field


# ---------------------------------------------------------------------------
# The shipped ledger
# ---------------------------------------------------------------------------

_DEFAULT: Union[ol.OrientationLedger, None] = None


def default_ledger() -> ol.OrientationLedger:
    """The shipped ``pcb/library/part_orientation.json``, read ONCE.

    Cached because an order builds several artifacts off one emission and a
    per-row re-read would let the file change underneath a single package.
    A missing or malformed file raises ``OrientationLedgerError`` rather than
    reading as an empty ledger -- see :func:`orientation_ledger.load_ledger`.
    """
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = ol.load_ledger()
    return _DEFAULT


# ---------------------------------------------------------------------------
# The sum
# ---------------------------------------------------------------------------


#: The two board sides, spelled the way ``CplRow.side`` carries them.
SIDE_TOP = "top"
SIDE_BOTTOM = "bottom"


def corrected_rotation(placed_deg: float, offset_deg: int, side: str) -> float:
    """THE ONE PLACE THE OFFSET IS APPLIED, and it is SIDE-DEPENDENT::

        top     (placed + offset) mod 360
        bottom  (placed - offset) mod 360

    The offset is a rotation of our drawing in the footprint's LOCAL frame, and
    a bottom placement mirrors that frame before rotating it -- a mirror
    conjugates a rotation into its inverse, so the same offset contributes the
    other way round. The full derivation is in the module docstring; the same
    rule governs an expansion child's rotation in
    ``geometry.PlacementTransform.angle``.

    ``side`` is REQUIRED and is checked rather than defaulted: a caller that
    forgot which side it holds would otherwise silently get the top rule, which
    is exactly the half-turn error this module exists to prevent.

    Normalized into ``[0, 360)`` to match what ``PhysicalPlacement.rotation_deg``
    already guarantees, so a corrected row is indistinguishable in shape from an
    uncorrected one."""
    if side == SIDE_TOP:
        signed = float(offset_deg)
    elif side == SIDE_BOTTOM:
        signed = -float(offset_deg)
    else:
        raise ValueError(
            f"corrected_rotation needs the board side to know which way the "
            f"offset composes; got {side!r}, not {SIDE_TOP!r} or {SIDE_BOTTOM!r}")
    return (float(placed_deg) + signed) % 360.0


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def _refuse_unknown(row, house: str) -> AssemblyOrientationError:
    return AssemblyOrientationError(
        CODE_UNKNOWN,
        f"component {row.ref!r} is bought as catalogue part {row.house_part!r} "
        f"from {house!r} on footprint {row.footprint_ref!r}, and NOTHING HAS "
        f"EVER MEASURED how that drawing is oriented against the vendor's. A "
        f"pick-and-place machine reads the position file's rotation against the "
        f"VENDOR's canonical drawing, so emitting the placed rotation unchanged "
        f"would be guessing that the two agree -- the guess that solders a part "
        f"down turned, invisibly where the lands are symmetric. Measure the pair "
        f"(add its vendor payload to the corpus and run `{REGEN_COMMAND}`), or "
        f"record a declared no_reference row if the part genuinely has no vendor "
        f"drawing. Refusing to emit a position file for a rotation nobody knows",
        component=row.ref, field=FIELD_HOUSE_PARTS)


def _refuse_undecided(row, house: str, record) -> AssemblyOrientationError:
    return AssemblyOrientationError(
        CODE_UNDECIDED,
        f"component {row.ref!r} is bought as catalogue part {row.house_part!r} "
        f"from {house!r} on footprint {row.footprint_ref!r}, and the measurement "
        f"of that pair did not settle the angle (verdict {record.verdict!r}"
        + (f": {record.detail}" if record.detail else "")
        + f"). An undecided measurement states no offset, and emitting the placed "
        f"rotation unchanged would silently pick one of the angles the drawings "
        f"could not be separated on. Re-measure the pair or correct the drawing "
        f"the two disagree about; refusing to emit a rotation the measurement "
        f"declined to state",
        component=row.ref, field=FIELD_HOUSE_PARTS)


def apply(rows: Sequence, profile,
          *, ledger: Union[ol.OrientationLedger, None] = None) -> tuple:
    """Every CPL row with its measured offset added, or a NAMED refusal.

    Returns rows in the order given. A row that is not gated -- no catalogue
    number for this house -- and a row whose pair is ``no_reference`` both come
    back UNCHANGED, which is what makes this step a no-op on everything the
    ledger has nothing to say about.

    ``ledger`` defaults to the shipped one; it is a parameter so a test can
    state the facts its board rests on instead of depending on which pairs
    happen to be measured today.
    """
    book = default_ledger() if ledger is None else ledger
    house = profile.house_part_id
    out = []
    for row in rows:
        part = getattr(row, "house_part", None)
        if not part:
            out.append(row)  # not bought as a catalogue part -- see the docstring
            continue
        record = book.lookup(row.footprint_ref, house, part)
        state = ol.state_of(record)
        if state == ol.STATE_UNKNOWN:
            raise _refuse_unknown(row, house)
        if state == ol.STATE_NO_REFERENCE:
            out.append(row)  # nothing to correct against, and never will be
            continue
        if record.offset_deg is None:
            raise _refuse_undecided(row, house, record)
        out.append(replace(
            row, rotation_deg=corrected_rotation(row.rotation_deg,
                                                 record.offset_deg, row.side)))
    return tuple(out)
