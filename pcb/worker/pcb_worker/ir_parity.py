"""CROSS-SURFACE GEOMETRY PARITY HARNESS — the Stage-4 acceptance check, runnable NOW.

Stage-4 acceptance is "for the smart-remote fixture, each surface reports/uses
identical pad centres/shapes, trace/via/hole geometry, outline, layer identity,
and net ownership". Nothing checked that. A check that only exists at the END of
the migration discovers drift many rounds after the round that introduced it;
this one fails inside the round that breaks it, where the implementer can still
fix it inside their own scope fence.

FOUR SURFACES, FOUR SEAMS
-------------------------
Each surface is tabulated at the seam CLOSEST TO WHAT IT ACTUALLY EMITS OR USES,
not at a convenient shared intermediate. Tabulating all four from one helper
would make them agree by construction and prove nothing.

  ``ir``      REFERENCE. :func:`compile_board.compile_board` -> ``ResolvedBoard``,
              read FIELD-BY-FIELD off the frozen dataclasses. Deliberately does
              NOT go through :mod:`ir_pads` / :mod:`pad_source`: those are what
              the other three surfaces use, so routing the reference through them
              would hide a change of mind inside the shared land owner.
  ``drc``     :func:`drc_geometric.project_board` -> ``Projection``. The copper
              the geometric DRC literally collision-checks (CopperPrimitive /
              HolePrimitive), not a re-derivation of it.
  ``kicad``   The EMITTED ``.kicad_pcb`` TEXT from :func:`kicad.generate_ir`,
              parsed back. Not ``_ir_board_dict``: the whole hazard on this path
              is the board-absolute -> footprint-LOCAL inversion in
              ``kicad._to_footprint_local`` plus KiCad's load transform, and a
              dict-level seam sits upstream of both.
  ``gerber``  The EMITTED Gerber + Excellon BYTES from
              :func:`gerber.build_gerbers_ir`, parsed back with gerbonara. Not
              ``gerber._Geometry``: the flash/aperture/coordinate-format pipeline
              downstream of it is exactly where a fab file loses a rotation or a
              land extent.

HONEST LIMIT — WHAT THIS HARNESS CANNOT CATCH (read before trusting a green run)
-------------------------------------------------------------------------------
``drc``, ``kicad`` and ``gerber`` all resolve a through-hole pad's copper LAND
through the same neutral owner, ``pad_source.th_land`` + ``placed_pad_to_geom``
(drc via ir_pads.py:38, gerber at gerber.py:64/419, kicad at kicad.py:43/539).
Those three therefore AGREE BY CONSTRUCTION on whether a land is a round annulus
or a shaped rectangle, and this harness can never report a disagreement about
that decision. What it does prove is everything downstream and around it:
coordinate transforms, per-pad rotation survival, copper-layer assignment, net
ownership, drill routing (PTH vs NPTH), outline framing, and whether the decision
reaches the emitted BYTES at all. The ``ir`` surface is the one seam independent
of ``pad_source``, so a change of mind inside the shared owner shows up as an
``ir``-vs-everyone delta — which is precisely the signal the reference exists for.

The SOLDER MASK has the same shape of limit and the same escape from it: ``drc``
and ``gerber`` both enumerate openings through ``mask_source``, so those two
agree by construction about WHICH entities open the mask. ``ir`` does not — see
:func:`_ir_mask_openings`, which re-walks the board and re-derives the
enlargement rule from IR fields for exactly this reason. Do not "simplify" either
of those two functions by calling the shared owner: the rule is the same one that
governs ``pad_source`` above, and tests/test_ir_parity.py enforces it with an AST
scan plus a behavioural half that detonates the owner and demands the reference
still tabulate.

ROW FORMAT (the part a sibling GDScript implementation must mirror)
------------------------------------------------------------------
Every surface produces a :class:`SurfaceTable` of :class:`ParityRow`. A row is
``(family, key, fields)``:

  * ``family`` — which comparison bucket the row lives in (see FAMILIES below).
  * ``key`` — identity WITHIN the family. It is GEOMETRIC (quantized position +
    canonical layer token), never an IR id, because gerbonara hands back an
    anonymous flash with no ref, no pad number and no net: an id-based key would
    be unproducible by the gerber surface and the harness would degrade to
    "gerber has rows, nobody can join them".
  * ``fields`` — named values, compared only between surfaces that can express
    them. A surface that genuinely cannot express a field reports :data:`NA`,
    which NEVER reads as a disagreement.

A surface that cannot express a whole FAMILY declares non-participation
(``SurfaceTable.families``) rather than emitting zero rows — otherwise "gerber
carries no nets" would read as "gerber lost every net".

Ordering is deterministic (rows sort by ``(family, key, ...)``) so a diff is a
signal rather than noise; nothing here reads the clock, a set iteration order, or
a PYTHONHASHSEED-sensitive hash. See tests/test_determinism_gate.py.

DEPENDENCY NOTE — gerbonara is imported LAZILY inside :func:`tabulate_gerber`.
It is a ``dev`` extra (pyproject.toml), not a worker runtime dependency, and the
same lazy-import discipline gerber-writer uses applies: a machine without it
loses one surface, never the module.

TRAP: this module must NEVER import the dev-only oracle package under
``tests/oracle`` — anything under ``pcb_worker/`` that does is a standing CI
failure (tests/test_kicad_cli_boundary.py FORBIDDEN list). That lint is a TEXT
scan, so even naming the package in dotted form inside a comment trips it; write
the path form, as here. (Found the hard way while writing this file.)
"""

from __future__ import annotations

import collections
import math
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, NamedTuple

from .fab_capability import EDGE_CUTS_WIDTH_MM
from .resolved_board import LayerRole, ResolvedBoard, RoundHole, Side

__all__ = [
    "PARITY_TOLERANCE_MM",
    "NA",
    "ParityRow",
    "SurfaceTable",
    "Delta",
    "KnownDelta",
    "ParityReport",
    "FAMILIES",
    "SURFACES",
    "tabulate_ir",
    "tabulate_drc",
    "tabulate_kicad",
    "tabulate_gerber",
    "tabulate_all",
    "diff_against_reference",
    "check_parity",
    "format_report",
    "SMART_REMOTE_BASELINE",
    "PARITY_CORNERS_BASELINE",
    "ParitySurfaceUnavailable",
    "ParityCanonicalizationUnsupported",
]


# ---------------------------------------------------------------------------
# Tolerance — ONE constant, used for BOTH key quantization and field comparison.
# ---------------------------------------------------------------------------

#: The single geometric tolerance of this harness, in millimetres.
#:
#: 1e-4 mm is 0.1 micron. Justification, in both directions:
#:
#:   * COARSE ENOUGH: the four surfaces reach the same coordinate by different
#:     arithmetic — the IR reads a float straight off a frozen dataclass, DRC
#:     halves a size, kicad round-trips through a footprint-local inversion and a
#:     decimal text encoding, gerber quantizes onto its fixed coordinate grid.
#:     Their disagreement is float noise on the order of 1e-12 mm plus the
#:     emitters' own decimal truncation. 0.1 micron swallows all of it.
#:   * FINE ENOUGH: the tightest thing any fab house quotes is ~25 micron
#:     (1 mil) registration. A real geometry defect is hundreds of times larger
#:     than this tolerance, so nothing that matters hides under it.
#:
#: Deliberately ONE constant rather than scattered ``round()`` calls: a per-call
#: rounding choice is invisible drift, and a harness whose sensitivity varies by
#: field cannot be reasoned about.
PARITY_TOLERANCE_MM = 1e-4

# Angles are compared in DEGREES with their own tolerance, because an angle is
# not a length: 1e-4 mm has no meaning for a rotation. 1e-3 deg over a 100 mm
# board displaces a point by ~1.7 micron — below the length tolerance's own
# fab-relevance argument, so the two thresholds are consistent.
_ANGLE_TOLERANCE_DEG = 1e-3


#: The grid a coordinate is bucketed onto to form a row KEY — 0.01 mm (10 micron),
#: deliberately ~100x COARSER than :data:`PARITY_TOLERANCE_MM`.
#:
#: The two numbers answer DIFFERENT QUESTIONS and must not be the same number:
#:
#:   * the KEY quantum answers "are these two rows the SAME ENTITY?" — it wants
#:     to be as coarse as it can be without ever merging two genuinely distinct
#:     features, so that rows CORRELATE and a disagreement can be reported as a
#:     legible field diff;
#:   * :data:`PARITY_TOLERANCE_MM` answers "do these two VALUES agree?" — it wants
#:     to be as tight as fab relevance allows.
#:
#: Making them equal was a design error (found in review). It meant any
#: disagreement larger than the epsilon also broke the JOIN, so the rows never
#: correlated and the harness reported a missing row plus an unrelated extra row
#: instead of "this pad is 0.3 micron out". Every real difference was reported in
#: the least legible form available.
#:
#: 10 micron is safe as an identity bucket: the tightest feature spacing anywhere
#: in these fixtures is a 0.4 mm via drill and a 2.54 mm pad pitch, so two
#: distinct features are never within 40x this quantum of each other. A
#: displacement large enough to matter now shows up as a POSITION FIELD delta
#: (``x_mm``/``y_mm``, compared at the tight epsilon) while the rows still join.
PARITY_KEY_QUANTUM_MM = 1e-2

_KEY_QUANT_DECIMALS = int(round(-math.log10(PARITY_KEY_QUANTUM_MM)))


def _q(value: float) -> float:
    """Bucket a coordinate onto the KEY grid (:data:`PARITY_KEY_QUANTUM_MM`).

    Used ONLY to build row keys — never for a field value, which is stored raw and
    compared at :data:`PARITY_TOLERANCE_MM`.

    TRAP (reduced, not eliminated): this is grid BUCKETING, not fuzzy matching, so
    two surfaces whose value straddles a bucket boundary still get different keys
    and read as a missing+extra pair rather than a field delta. At 10 micron that
    needs a true coordinate within ~1e-12 of a 0.01 mm boundary AND a real
    disagreement across it, which no fixture here produces. If it ever happens the
    failure is loud (missing/extra row), never silent.
    """
    return round(float(value) + 0.0, _KEY_QUANT_DECIMALS)  # +0.0 normalizes -0.0


# ---------------------------------------------------------------------------
# "Not applicable" — structurally distinct from "disagrees" and from None.
# ---------------------------------------------------------------------------


class _NotApplicable:
    """Sentinel for a field a surface genuinely cannot express.

    NOT ``None``: ``None`` is a real, comparable value in this domain (a pad with
    no net has ``net_name=None``, and "one surface says GND, the other says no
    net" IS a disagreement worth failing on). Conflating the two would make every
    unassigned pad look like a parity break, and — worse — would let a genuinely
    dropped net hide behind "well, that surface can't say".
    """

    _instance: "_NotApplicable | None" = None

    def __new__(cls) -> "_NotApplicable":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "n/a"


#: The single "this surface cannot express this field" value.
NA = _NotApplicable()


# ---------------------------------------------------------------------------
# Families and surfaces
# ---------------------------------------------------------------------------

#: Comparison buckets. A row's family fixes the shape of its key and the set of
#: fields it may carry.
FAMILIES = (
    # One discrete copper land on ONE copper layer. A through-hole pad or a via
    # therefore produces one row PER copper layer it occupies — that is what the
    # fab file physically contains, and it is what makes "the land vanished from
    # B.Cu" a nameable failure instead of an invisible one.
    "copper_flash",
    # One trace segment on one copper layer.
    "copper_trace",
    # One drilled feature. Not split per layer: a drill is a single physical bore.
    "drill",
    # The board frame.
    "outline",
    # One interior board cutout, keyed by its axis-aligned bbox (identity-free
    # on purpose: canonical cutout ids do not survive into a Gerber). Added in
    # epoch CPN1 because the outline family alone is bbox-of-everything and an
    # interior contour does not move the bbox — an emitter silently dropping a
    # cutout was invisible to parity, which is the exact silent-discard class
    # bug 019fbd30f7 documents on this surface.
    "cutout",
    # NO SILK FAMILY — a RULING (epoch CP2 S4), not an omission, and it comes
    # with an expiry condition. Read it before adding a silk check anywhere.
    #
    # S4 put legend geometry into the DRC projection (Projection.silk), so this
    # module's DRC surface now has silk available to it. It is deliberately not
    # tabulated, because parity's job is to catch an emitter SILENTLY DROPPING
    # geometry that some other surface accounted for — and until a silk CHECK
    # exists, nothing has been cleared, so there is nothing to drop silently.
    # Adding rows now would only assert that two harvests which are literally
    # the same function call agree with each other (both surfaces go through
    # silk_source), which is a tautology, not a guard.
    #
    # THE EXPIRY: station S6 introduces the first real silk DFM checks. At that
    # point silk becomes a checked subject on two surfaces and an emitter that
    # dropped silk the checker had cleared WOULD be invisible here — exactly the
    # hole the `cutout` family above was added to close (see its own note). So
    # S6 must land a silk family across ir/drc/gerber, or record why not. This
    # comment is the obligation; do not let it lapse quietly.
    #
    # S6 OWES ONE MORE THING, bundled here so it cannot be forgotten separately:
    # `Projection.silk_warnings` currently has NO consumer. It carries the shared
    # harvest's warn-and-drop diagnostics precisely so a checker cannot silently
    # inherit a narrower set of artwork than the emitter draws — but nothing
    # reads it, so today that guarantee is aspirational. The first silk check
    # must surface those warnings (at minimum as INFO on the DRC result), or the
    # field is decoration.
    #
    # ---- S6 DISCHARGED BOTH OF THE ABOVE. Answers, in order. ----
    #
    # silk_warnings: DONE. GC9 emits a `gc9_silk_indeterminate` finding for every
    # dropped primitive. A drop is no longer cleared silently — it is reported as
    # artwork the checker could not measure, carrying no measurement (the row's
    # measured_mm/required_mm are None, because there is no number to give).
    #
    # SILK FAMILY: NOT LANDED, and the reason is structural rather than the
    # tautology argument used for mask above. Read this before assuming it was
    # skipped for convenience — it is the SECOND declined family in this module
    # and that pattern deserves scrutiny.
    #
    # The obligation was "a silk family across ir/drc/gerber". Those three
    # columns cannot share one row key:
    #
    #   * For the IR column to be INDEPENDENT it must be keyed PER GRAPHIC —
    #     straight off PlacedGraphic, without running the shared harvest.
    #     (Running silk_source to build IR rows would make the ir and drc
    #     columns the same function call, which is exactly the mask tautology.)
    #   * For the GERBER column to exist at all it must be keyed PER STROKE
    #     SEGMENT. Emitted silk is anonymous drawn geometry; a graphic's identity
    #     does not survive into the file, and grouping parsed strokes back into
    #     the graphic that produced them is not recoverable (the `cutout` family
    #     hit the same wall and solved it with an identity-free bbox key, which
    #     works there because a cutout IS one closed loop — a silk graphic is
    #     not).
    #
    # One family cannot be keyed both ways, so the choice is a two-column family
    # (ir/drc) or a two-column family (drc/gerber) wearing a three-column name.
    #
    # AND THE HOLE THAT MOTIVATED IT IS CLOSED BY A MORE DIRECT ROUTE. The S4
    # reasoning was: once silk is checked, "an emitter dropping silk the checker
    # CLEARED becomes invisible". GC9 makes every drop VISIBLE as its own
    # finding, so the checker never clears dropped artwork — it reports it. A
    # parity row would restate that, later and less precisely.
    #
    # WHAT IS GENUINELY LEFT UNGUARDED, stated so it is not discovered as a
    # surprise: a graphic the harvest drops WITHOUT warning. Nothing today can do
    # that (every drop path in silk_source emits a SilkWarning), but nothing
    # structurally prevents a future one, and parity is what would have caught
    # it. That is the residual risk of this decision.
    #
    # REVIVAL TRIGGERS: a silk_source drop path that does not warn; a second silk
    # harvest anywhere; or the IR gaining stroke-level silk (at which point the
    # per-graphic/per-stroke conflict dissolves and the family becomes buildable
    # as originally specified).
    #
    # One SOLDER-MASK APERTURE on one outer mask layer — the opening that decides
    # whether a piece of copper is solderable. Added in epoch CP2 S11, which
    # OVERTURNS S4/S5's ruling that this family would be a tautology.
    #
    # WHAT S5 ARGUED, and what was right about it: Projection.mask and the gerber
    # emitter's mask buckets both come from mask_source, so tabulating those two
    # asserts that one function call agrees with itself. That much is still true,
    # and both columns are kept anyway — a family's value is the contrast it
    # enables, and a shared owner is a legitimate thing to hold two independent
    # readings up against.
    #
    # WHERE IT WENT WRONG, twice reviewed (Fable, then Codex on question
    # 019fe66eff55, before any code was written): it said "there is no third
    # surface holding an independent opinion", and that the IR "has no mask
    # concept at all". Both are false, and the second is the load-bearing one.
    #
    #   * GERBER is a genuinely independent column, because this module's own
    #     docstring defines that surface as the EMITTED BYTES parsed back with
    #     gerbonara. Between mask_source's answer and the F_Mask/B_Mask bytes sit
    #     _adopt_mask_openings' side-to-bucket routing, to_gerber_frame's Y
    #     negation, aperture construction, and serialization. Comparing two
    #     in-memory harvests covers none of it.
    #   * IR is independent too — because this module FORBIDS the reference from
    #     borrowing the shared owner (see the honest-limit section of the module
    #     docstring, and _ir_pad_land, which restates the copper land rule for
    #     exactly this reason). "Mask openings are derived" is not an argument
    #     that the reference cannot hold them; it is the instruction for how:
    #     _ir_mask_openings re-derives the ENUMERATION and the ENLARGEMENT from
    #     ResolvedBoard fields, so a change of mind inside mask_source shows up
    #     as an ir-vs-everyone delta instead of propagating silently.
    #
    # The family is therefore TWO independent derivations (ir, gerber) against
    # one shared owner (drc), which is a stronger check than the overturn itself
    # contemplated. KiCad does not participate: it writes per-pad
    # solder_mask_margin and never an aperture, so it structurally cannot answer
    # (see _KICAD_FAMILIES).
    #
    # STILL TRUE AND STILL LOAD-BEARING, from the old ruling: a dropped mask
    # aperture is fabrication-critical (fab_capability.FABRICATION_CRITICAL_
    # OUTPUTS lists mask) and GC8's failure mode is a FALSE CLEAN — fewer
    # apertures seen means fewer slivers found, which reads as a healthier board.
    # That is why this family fails closed on every unreadable object rather than
    # skipping it, and why its rows COUNT (see _mask_rows) instead of collapsing
    # duplicates.
    #
    # tests/test_mask_projection.py still guards emitter-vs-projection at full
    # geometry and still asserts gerber.py owns no mask enumeration. This family
    # does not replace it; it adds the two readings that module cannot make.
    #
    # THE INDETERMINATE OBLIGATION IS DISCHARGED, recorded here because this note
    # used to carry it as outstanding. S5 owed a consumer for
    # `Projection.mask_indeterminate` — the field naming entities whose openings
    # could not be determined — because a sliver check run on a KNOWN-INCOMPLETE
    # aperture set finds fewer slivers and reports a healthier board. It now has
    # one: drc_geometric refuses the whole geometric verdict when the field is
    # non-empty, ahead of GC8. The refusal is wholesale rather than mask-scoped
    # because the result envelope carries one verdict for all checks; that
    # narrowing is still open, and the reason is stated at the call site.
    "mask_opening",
    # Copper-layer identity + stack order.
    "copper_layer",
    # Which net owns which pad. Split out of copper_flash so a dropped net
    # assignment is named as itself rather than as one field of a geometry row.
    "net_ownership",
)

#: Surface names. ``ir`` is the reference every other surface is diffed against.
SURFACES = ("ir", "drc", "kicad", "gerber")

REFERENCE_SURFACE = "ir"


@dataclass(frozen=True)
class ParityRow:
    family: str
    key: tuple
    #: Sorted ``((name, value), ...)`` — a tuple, not a dict, so a row is
    #: hashable and its ordering is fixed by construction rather than by dict
    #: insertion order.
    fields: tuple[tuple[str, Any], ...]

    @classmethod
    def make(cls, family: str, key: tuple, **fields: Any) -> "ParityRow":
        return cls(family, tuple(key), tuple(sorted(fields.items())))

    def field_map(self) -> dict[str, Any]:
        return dict(self.fields)

    def describe(self) -> str:
        """Human entity name for a failure message.

        Prefers the AUTHORED identity a person can act on ("U1.2 on F.Cu") and
        falls back to the geometric key, which is all an anonymous gerber flash
        can offer.
        """
        f = self.field_map()
        ref, num = f.get("ref"), f.get("pad_number")
        who = None
        if isinstance(ref, str) and ref:
            who = f"{ref}.{num}" if isinstance(num, str) and num else ref
        where = " ".join(str(part) for part in self.key)
        return f"{who} @ {where}" if who else where


@dataclass(frozen=True)
class SurfaceTable:
    surface: str
    #: Families this surface can express AT ALL. A family absent here is skipped
    #: for this surface entirely — see the module docstring on why zero rows and
    #: "cannot participate" must not be the same thing.
    families: frozenset[str]
    rows: tuple[ParityRow, ...]

    def by_family(self, family: str) -> dict[tuple, ParityRow]:
        return {row.key: row for row in self.rows if row.family == family}


@dataclass(frozen=True)
class Delta:
    """One named disagreement. Carries enough to act on from CI output alone."""

    surface: str
    family: str
    #: ``missing_row`` (reference has it, surface does not), ``extra_row``
    #: (surface invented it), or ``field`` (both have the row, one field differs).
    kind: str
    key: tuple
    field: str | None
    reference_value: Any
    surface_value: Any
    entity: str

    def signature(self) -> tuple[str, str, str, str | None]:
        """The coarse class a baseline entry matches on."""
        return (self.surface, self.family, self.kind, self.field)

    def render(self) -> str:
        if self.kind == "field":
            return (f"[{self.surface}] {self.family}: {self.entity}: field "
                    f"{self.field!r} — ir={self.reference_value!r} "
                    f"{self.surface}={self.surface_value!r}")
        if self.kind == "missing_row":
            return (f"[{self.surface}] {self.family}: {self.entity} — present in "
                    f"ir, ABSENT from {self.surface}")
        return (f"[{self.surface}] {self.family}: {self.entity} — present in "
                f"{self.surface}, ABSENT from ir")


@dataclass(frozen=True)
class KnownDelta:
    """One ENUMERATED, EXPLAINED delta that is expected to be present today.

    Matched on ``(surface, family, kind, field)`` AND on the exact ROW KEYS it
    explains. Identity, not arity.

    WHY THE KEYS ARE HERE (a review finding, and the single most important
    property of the design): an earlier revision matched on the signature plus a
    COUNT. That silently swallowed regressions. Displacing one baselined drill hit
    by 80 mm kept the count at 3 and the gate passed clean — zero unexplained,
    zero stale — because the class had "room" for it. A baseline that suppresses
    more than it names is worse than no baseline at all. With the keys pinned, a
    delta whose signature matches but whose ROW does not is unexplained, and
    fails.

    Teeth in both directions still hold, now per-row:

      * a NEW delta of an already-listed class carries an UNLISTED key -> it is
        unexplained -> FAIL;
      * a FIXED delta leaves a listed key unmatched -> the entry is stale ->
        FAIL, forcing the baseline to shrink with the code rather than rot into a
        list of things that used to be true.

    The visible exit condition for the migration is this list reaching length 0.
    """

    surface: str
    family: str
    kind: str
    field: str | None
    #: The EXACT row keys this entry explains. Written out rather than hashed so
    #: that a staleness failure can name which row appeared or disappeared.
    keys: tuple[tuple, ...]
    #: WHY these disagree, in enough detail to decide whether it is acceptable.
    reason: str
    #: Docket id if one can be attributed from existing code/comments, else the
    #: literal "unattributed" — never a fabricated id.
    docket: str

    @property
    def count(self) -> int:
        return len(self.keys)

    def signature(self) -> tuple[str, str, str, str | None]:
        return (self.surface, self.family, self.kind, self.field)

    def matches(self, delta: Delta) -> bool:
        return delta.signature() == self.signature() and delta.key in set(self.keys)


@dataclass(frozen=True)
class ParityReport:
    deltas: tuple[Delta, ...]
    #: Deltas no baseline entry explains. Non-empty == the gate FAILS.
    unexplained: tuple[Delta, ...]
    #: Baseline entries whose matched ROW KEYS no longer equal their declared
    #: ones — paired with what was actually matched. Non-empty == the gate FAILS.
    stale: tuple[tuple[KnownDelta, tuple[tuple, ...]], ...]
    #: Families skipped per surface, for the report header.
    skipped: tuple[tuple[str, str], ...] = ()

    @property
    def ok(self) -> bool:
        return not self.unexplained and not self.stale


# ---------------------------------------------------------------------------
# Canonical value normalization, shared by every tabulator.
# ---------------------------------------------------------------------------

# Canonical land-shape vocabulary. Every surface maps its own spelling into this
# set so "circle" vs "Circle" vs CircleAperture is never mistaken for a defect.
_SHAPE_CIRCLE = "circle"
_SHAPE_RECT = "rect"
_SHAPE_OVAL = "oval"
_SHAPE_ROUNDRECT = "roundrect"


def _canonical_rotation(shape: str, w: float, h: float, rot_deg: float) -> float | Any:
    """The rotation of a land, folded by the land's own SYMMETRY.

    A 2x2 square land at 180 deg is the SAME COPPER as one at 0 deg, and the
    surfaces legitimately disagree about which number to carry: the gerber
    emitter folds a rect's rotation into its aperture (a rect aperture at 180 is
    emitted unrotated), while the IR keeps the authored ``rotation_deg``. Without
    this fold, every rotated square pad in the fixture is a false positive, and a
    harness that cries wolf on 20 pads gets ignored on the 21st, which is real.

    Folding by symmetry is not the same as ignoring rotation: an OBLONG land's
    90-degree error survives (a 2x1 rect folds mod 180, so 90 != 0) — which is
    the case that actually changes copper.
    """
    if shape == _SHAPE_CIRCLE:
        # A disc has no orientation to disagree about.
        return NA
    period = 90.0 if abs(w - h) <= PARITY_TOLERANCE_MM else 180.0
    folded = float(rot_deg) % period
    # Fold the top of the range back to 0 so 179.9999 and 0.0001 do not read as
    # a 180-degree disagreement.
    if period - folded < _ANGLE_TOLERANCE_DEG:
        folded = 0.0
    return round(folded, 6)


# Shapes for which the transposition identity below is VALID. The identity
# "a land of (w, h) at 90 deg is the same copper as a land of (h, w) at 0 deg"
# requires the shape to be symmetric about BOTH of its own axes: a 90-degree turn
# maps the outline onto its transpose only if reflecting across either axis is a
# no-op. rect, oval and roundrect all are. An asymmetric shape is NOT — rotating a
# trapezoid or a chamfered pad 90 degrees does NOT give you the transposed
# trapezoid, it gives you one pointing a different way — so transposing it would
# manufacture a false agreement between two genuinely different lands. Circle never
# reaches here (_canonical_rotation returns NA for it: a disc has no orientation).
_TRANSPOSABLE_SHAPES = frozenset({_SHAPE_RECT, _SHAPE_OVAL, _SHAPE_ROUNDRECT})


def _values_agree(name: str, a: Any, b: Any) -> bool:
    """Field comparison. NA on EITHER side is never a disagreement."""
    if a is NA or b is NA:
        return True
    if isinstance(a, bool) or isinstance(b, bool):
        return a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        tol = _ANGLE_TOLERANCE_DEG if name.endswith("_deg") else PARITY_TOLERANCE_MM
        return abs(float(a) - float(b)) <= tol
    return a == b


def _layer_tokens(rb: ResolvedBoard) -> dict[str, str]:
    """Every spelling of a copper layer -> ONE canonical token.

    The four surfaces name the same physical copper three different ways: the IR
    stack says ``top``, ``PlacedPad.layers`` and the .kicad_pcb say ``F.Cu``, and
    a gerber file says ``F_Cu`` in its filename. The KiCad alias is chosen as
    canonical because it is the only spelling THREE of the four surfaces already
    use; normalizing to it means a genuine layer-assignment bug still shows as
    one, while a naming convention never does.
    """
    tokens: dict[str, str] = {}
    for layer in rb.layer_stack.copper:
        alias = layer.kicad_alias
        tokens[layer.id] = alias
        tokens[alias] = alias
        tokens[alias.replace(".", "_")] = alias
    return tokens


def _copper_stack(rb: ResolvedBoard) -> tuple[str, ...]:
    """Canonical copper tokens in STACK ORDER (F.Cu first)."""
    return tuple(layer.kicad_alias
                 for layer in sorted(rb.layer_stack.copper, key=lambda l: l.stack_index))


# ---------------------------------------------------------------------------
# SURFACE 1 (REFERENCE) — the compiled IR, read field-by-field.
# ---------------------------------------------------------------------------

_IR_FAMILIES = frozenset(FAMILIES)


# NOTE ON THE ``cutout`` FAMILY AND WHY IT IS DECLARED UNCONDITIONALLY.
#
# A surface's family set means "this surface CAN speak to this family", not
# "this surface has rows here" — that is what lets the diff skip families a
# surface structurally cannot answer (a Gerber file carries no net list, so
# `net_ownership` is genuinely unanswerable there). All three surfaces CAN
# speak to cutouts; a board simply may not have any.
#
# Making the declaration board-conditional was tried and is WRONG in BOTH
# directions, recorded here so it is not re-attempted:
#   * conditional on the surface's own ROWS, an emitter that DROPS every
#     cutout stops declaring the family, the diff skips it, and the
#     regression the family exists to catch disappears;
#   * conditional on the BOARD, an emitter that INVENTS an interior Edge.Cuts
#     loop on a cutout-less board emits rows the REFERENCE does not declare —
#     and the diff compares only families BOTH tables participate in, so the
#     phantom is skipped too.
# Declaring it always keeps a dropped cutout visible as `missing_row` and an
# invented one as `extra_row`. A legitimately empty family is accommodated by
# the harness guard, not by the declaration — see
# test_ir_parity.test_every_surface_actually_produced_rows.


# A through-hole land only takes a SHAPE in these families; anything else has no
# faithful non-round aperture. Restated here from the IR contract rather than
# imported from pad_source — importing it would make the reference agree with the
# other three surfaces by construction, which is the one thing it must not do.
_TH_SHAPEABLE = ("oval", "roundrect", "rect")
_TH_CORNERED = ("rect", "roundrect")
# Oblongness threshold of the IR land contract. Distinct from PARITY_TOLERANCE_MM
# on purpose: this is not a comparison tolerance, it is a CLASSIFICATION boundary
# the IR contract defines (pad_source.th_land ``_TH_OBLONG_TOL_MM``), and the
# reference must sit on the same boundary or it disagrees about squares.
_TH_OBLONG_TOL_MM = 1e-6


def _ir_pad_land(pad) -> tuple[str, float, float, float | None]:
    """``(shape, w_mm, h_mm, corner_rratio)`` of one placed pad's copper land,
    re-derived from the IR's OWN fields.

    This is the one place the harness INTERPRETS rather than copies, and it is
    deliberately NOT delegated to ``pad_source.th_land`` — see the module
    docstring's honest-limit section. It re-implements the land rule the IR
    documents, so a change of mind inside the shared owner shows up as an
    ir-vs-everyone delta instead of silently propagating to all three consumers:

      * an OVERRIDE ``annulus`` wins and is ROUND (kicad.py:694-706);
      * otherwise a land is SHAPED when its shape is shapeable AND it is either
        genuinely OBLONG or an AUTHORED cornered shape (``raw_shape`` in
        rect/roundrect) — finding 019f8b7fd295 and its comment 688;
      * everything else is the historical ROUND ANNULUS, whose diameter is the
        pad WIDTH (an equal-axis authored OVAL is geometrically a circle, so it
        stays round rather than becoming a spurious obround).
    """
    if pad.drill is None:
        w, h = pad.size if pad.size else (0.0, 0.0)
        return _canonical_shape_token(pad.shape.value), w, h, pad.corner_rratio
    if pad.annulus is not None:
        return _SHAPE_CIRCLE, pad.annulus, pad.annulus, None
    w, h = pad.size if pad.size else (0.0, 0.0)
    shapeable = pad.shape.value in _TH_SHAPEABLE
    oblong = abs(w - h) > _TH_OBLONG_TOL_MM
    if shapeable and (oblong or pad.raw_shape in _TH_CORNERED):
        return _canonical_shape_token(pad.shape.value), w, h, pad.corner_rratio
    return _SHAPE_CIRCLE, w, w, None


def _canonical_shape_token(raw: str) -> str:
    low = str(raw).lower()
    if low in ("circle", "round"):
        return _SHAPE_CIRCLE
    if low in ("oval", "obround", "stadium"):
        return _SHAPE_OVAL
    if low == "roundrect":
        return _SHAPE_ROUNDRECT
    return _SHAPE_RECT


def _canonical_land(shape: str, w: float, h: float,
                    rot_deg: Any) -> tuple[float, float, Any]:
    """``(w, h, rot)`` folded to ONE representative of the land's orientation.

    Shared by :func:`_flash_row` and :func:`_mask_row` so copper and mask cannot
    drift on what "the same land, described the other legal way" means.

    Surfaces legitimately carry DIFFERENT but EQUIVALENT descriptions of one
    quarter-turned land: the IR keeps the authored (w, h, rot=90), while gerber
    folds the turn into the aperture's extents and emits (h, w, rot=0) — it has
    no choice, the standard obround aperture ``O,xXy`` has no rotation parameter
    at all (see ``gerber._obround_rotation_swap``). Without a single canonical
    form, that pure REPRESENTATION difference reads as three field defects on a
    land that is fabricated correctly.

    This folds both to the axis-aligned representative. It is NOT a suppression:
    it only ever equates two descriptions of the SAME outline, so a land that is
    genuinely the wrong way round still disagrees — it disagrees on w_mm/h_mm
    instead of on rot_deg (pinned by
    test_canonicalization_does_not_mask_a_genuinely_transposed_land).
    """
    rot = _canonical_rotation(shape, w, h, rot_deg) if rot_deg is not NA else NA
    if rot is not NA and abs(rot - 90.0) <= _ANGLE_TOLERANCE_DEG:
        if shape not in _TRANSPOSABLE_SHAPES:
            # Fail LOUDLY rather than transpose an outline the identity does not
            # hold for. A new asymmetric pad shape must extend the set CONSCIOUSLY.
            raise ParityCanonicalizationUnsupported(
                f"ir_parity: shape {shape!r} is at 90 deg but is not in "
                f"_TRANSPOSABLE_SHAPES, so (w, h, 90) -> (h, w, 0) is not a valid "
                f"canonicalisation for it — a 90-degree turn maps an outline onto "
                f"its transpose only when the outline is symmetric about BOTH axes. "
                f"Add it to _TRANSPOSABLE_SHAPES only after confirming that, or give "
                f"it its own canonical form; do NOT transpose it by default.")
        return h, w, 0.0
    return w, h, rot


def _flash_row(layer_token: str, x: float, y: float, *, shape: str, w: float,
               h: float, rot_deg: float, entity: Any, ref: Any, pad_number: Any,
               net_name: Any) -> ParityRow:
    """The ONE constructor for a ``copper_flash`` row. Every surface goes through
    it so the key shape and field set cannot drift per tabulator.

    The centre appears TWICE and on purpose: BUCKETED in the key (identity) and
    RAW in ``x_mm``/``y_mm`` (a compared value). Without the raw copy a displaced
    pad inside the same bucket would be invisible, and one outside it would be an
    illegible missing/extra pair — position would never actually be CHECKED."""
    w, h, rot = _canonical_land(shape, w, h, rot_deg)
    return ParityRow.make(
        "copper_flash", (layer_token, _q(x), _q(y)),
        x_mm=float(x), y_mm=float(y),
        shape=shape, w_mm=w, h_mm=h,
        rot_deg=rot,
        entity=entity, ref=ref, pad_number=pad_number, net_name=net_name)


# ---------------------------------------------------------------------------
# SOLDER-MASK openings (epoch CP2 S11). See the "mask_opening" entry in FAMILIES
# for why this family exists after S4/S5 declined it.
# ---------------------------------------------------------------------------


class _MaskAperture(NamedTuple):
    """One mask opening as ANY surface can state it, before rows are built.

    A neutral intermediate on purpose: the three participating surfaces derive
    their openings by three genuinely different routes (the IR re-derives from
    ResolvedBoard fields, DRC reads the projection, gerber parses emitted
    bytes), and this is the one shape they are required to meet in. Only the
    occurrence NUMBERING is shared — see :func:`_mask_rows`.
    """

    side_token: str                 # "F.Mask" | "B.Mask"
    x: float
    y: float
    shape: str
    w: float
    h: float
    rot_deg: float
    #: ABSOLUTE corner radius in mm (never a ratio — gerber has no concept of
    #: one), or NA where the shape has no corner to round.
    corner_radius_mm: Any
    #: "dark" = mask OPENED here, "clear" = mask closed. Carried because
    #: geometry alone does not decide it: a clear flash has the same extents as
    #: a dark one and the opposite fabrication meaning.
    polarity: str
    entity: Any = NA
    ref: Any = NA


def _mask_corner_radius(shape: str, w: float, h: float, rratio: Any) -> Any:
    """A land's corner radius in MILLIMETRES, from its shape and KiCad ratio.

    The ratio convention is the IR's (``corner_rratio`` x the SHORT side), and
    it is restated here rather than imported for the same reason
    :func:`_ir_pad_land` restates the land rule.

    A circle has no corner, so NA — not 0.0, which would assert "square
    corners" against a surface that correctly declines to say.
    """
    if shape == _SHAPE_CIRCLE:
        return NA
    if shape == _SHAPE_OVAL:
        # An obround IS fully rounded on its short axis by definition; the
        # radius is not a free parameter and no ratio is consulted.
        return min(float(w), float(h)) / 2.0
    if shape == _SHAPE_ROUNDRECT:
        if rratio is None or rratio is NA:
            return NA
        return float(rratio) * min(float(w), float(h))
    return 0.0


def _fold_degenerate_roundrect(shape: str, w: float, h: float,
                               radius: Any) -> str:
    """A roundrect at either END of its radius range IS another shape, and the
    emitter says so in the bytes.

    ``gerber._shape_aperture`` degenerates an authored-zero radius to a plain
    ``Rectangle``, and gerber-writer collapses a FULLY rounded one to the
    standard obround ``O,`` aperture. So the emitted file names those two lands
    "rect" and "oval" while the IR still calls them "roundrect" — a pure
    representation difference on identical outlines, exactly like the
    quarter-turn fold in :func:`_canonical_land`.

    Folding both ends here keeps that from reading as a shape defect. It is not
    a suppression: it fires ONLY at the two radii where the outlines are
    provably identical, so a roundrect whose radius is merely WRONG still
    disagrees on ``corner_radius_mm`` (pinned by the negative controls in
    tests/test_ir_parity.py).
    """
    if shape != _SHAPE_ROUNDRECT or radius is NA:
        return shape
    if abs(float(radius)) <= PARITY_TOLERANCE_MM:
        return _SHAPE_RECT
    if abs(float(radius) - min(float(w), float(h)) / 2.0) <= PARITY_TOLERANCE_MM:
        return _SHAPE_OVAL
    return shape


class _MaskCanonical(NamedTuple):
    """One aperture reduced to the form that is actually COMPARED.

    Every surface's own way of describing a land — the IR's authored roundrect,
    the obround gerber-writer collapses it to, a quarter-turn folded into the
    extents — has already been folded out here. Both the row FIELDS and the
    occurrence ORDER are derived from this and only this.
    """

    shape: str
    w: float
    h: float
    rot: Any
    corner_radius_mm: Any
    polarity: str


def _mask_canonical(a: _MaskAperture) -> _MaskCanonical:
    """Fold one aperture to its canonical form — the SINGLE place the two folds
    are applied, so ordering and comparison can never see different geometry."""
    shape = _fold_degenerate_roundrect(a.shape, a.w, a.h, a.corner_radius_mm)
    w, h, rot = _canonical_land(shape, a.w, a.h, a.rot_deg)
    return _MaskCanonical(shape, w, h, rot, a.corner_radius_mm, a.polarity)


def _mask_sort_key(canon: _MaskCanonical) -> tuple:
    """Deterministic order for apertures that share one POSITION bucket.

    THE INPUT IS ALREADY CANONICAL, and that is load-bearing rather than tidy.
    This function used to take the raw :class:`_MaskAperture` and sort on its
    authored shape/extents while the ROW was built from the folded ones — so two
    surfaces describing the SAME multiset the two legal ways numbered it
    differently and parity failed on a correct board. Measured (Codex cold
    review of 6360a90, finding 1): a rect beside a fully-rounded roundrect at one
    position sorts rect-then-roundrect on the IR and oval-then-rect on the
    gerber, because "oval" < "rect" < "roundrect" as strings — eight false field
    deltas from an identical multiset.

    Ordering on GEOMETRY rather than on any id is what lets the three surfaces
    agree on which coincident aperture is which at all: the gerber column has no
    entity to sort by, so a numbering keyed on identity could never line up.
    """
    radius = canon.corner_radius_mm
    return (canon.shape, round(canon.w, 6), round(canon.h, 6),
            (0, 0.0) if canon.rot is NA else (1, round(float(canon.rot), 6)),
            (0, 0.0) if radius is NA else (1, round(float(radius), 6)),
            canon.polarity)


def _mask_rows(apertures: Iterable[_MaskAperture]) -> list[ParityRow]:
    """Apertures -> ``mask_opening`` rows, with an OCCURRENCE ORDINAL in the key.

    THE ORDINAL IS THE POINT, and it is what makes this family able to COUNT.
    ``SurfaceTable.by_family`` is a ``{row.key: row}`` dict comprehension, so two
    rows sharing a key collapse into one and a dropped duplicate becomes
    invisible. Two coincident identical apertures are two real flash operations
    in the file; losing one is precisely the silent discard this family exists to
    catch, and under a collapsing key it would read as a clean board.

    Rows are grouped by POSITION BUCKET and numbered within the group in
    CANONICAL-geometry order (:func:`_mask_canonical`, applied once here and
    reused for the row's fields).

    WHAT THE ORDINAL DOES AND DOES NOT PROMISE — stated because the first version
    of this docstring over-claimed. It guarantees MULTIPLICITY: n coincident
    apertures produce n rows, so a dropped duplicate is a missing_row rather than
    a silent collapse. It does NOT guarantee that an arbitrary change to one of
    several coincident apertures is reported as a field delta rather than a
    missing+extra pair: a change large enough to move that aperture PAST a
    neighbour in the canonical order renumbers both. The diff stays correct and
    still fails — it is the legibility of the report that degrades, not the
    verdict. Ordinals are chosen over a ``Counter`` because a Counter gives up
    field-level diffs for EVERY difference, not just the order-crossing ones.
    """
    grouped: dict[tuple, list[tuple[_MaskAperture, _MaskCanonical]]] = \
        collections.defaultdict(list)
    for aperture in apertures:
        grouped[(aperture.side_token, _q(aperture.x), _q(aperture.y))].append(
            (aperture, _mask_canonical(aperture)))
    rows: list[ParityRow] = []
    for members in grouped.values():
        ordered = sorted(members, key=lambda pair: _mask_sort_key(pair[1]))
        for occurrence, (aperture, canon) in enumerate(ordered):
            rows.append(_mask_row(aperture, canon, occurrence))
    return rows


def _mask_row(a: _MaskAperture, canon: _MaskCanonical,
              occurrence: int) -> ParityRow:
    """The ONE constructor for a ``mask_opening`` row.

    Same discipline as :func:`_flash_row`: the centre is BUCKETED in the key and
    RAW in the fields, so an opening displaced inside its own bucket is a field
    delta rather than an invisible pass.

    ``canon`` is passed in rather than recomputed, so the geometry that decided
    this row's ORDINAL and the geometry it REPORTS are the same object by
    construction — the divergence between those two was finding 1 of the cold
    review on 6360a90.
    """
    return ParityRow.make(
        "mask_opening", (a.side_token, _q(a.x), _q(a.y), occurrence),
        x_mm=float(a.x), y_mm=float(a.y),
        shape=canon.shape, w_mm=canon.w, h_mm=canon.h, rot_deg=canon.rot,
        corner_radius_mm=canon.corner_radius_mm, polarity=canon.polarity,
        entity=a.entity, ref=a.ref)


def _mask_side_token(side: Side) -> str:
    return "F.Mask" if side is Side.TOP else "B.Mask"


def _trace_row(layer_token: str, a: tuple[float, float], b: tuple[float, float],
               width_mm: float, net_name: Any) -> ParityRow:
    # Endpoints SORTED: a segment emitted b->a is the same copper as a->b, and no
    # surface promises an orientation. Sorting here rather than per-tabulator
    # means a future surface cannot forget to. The RAW endpoints are carried as
    # fields in the SAME order the bucketed key sorted them, so a segment whose
    # endpoint moved within its bucket is still compared (see _flash_row).
    ends = sorted(((_q(p[0]), _q(p[1])), (float(p[0]), float(p[1]))) for p in (a, b))
    (ka, ra), (kb, rb) = ends
    return ParityRow.make("copper_trace", (layer_token, ka, kb),
                          a_x_mm=ra[0], a_y_mm=ra[1], b_x_mm=rb[0], b_y_mm=rb[1],
                          width_mm=width_mm, net_name=net_name)


def _drill_row(x: float, y: float, dia_mm: float, plated: Any,
               entity: Any = NA) -> ParityRow:
    return ParityRow.make("drill", (_q(x), _q(y)),
                          x_mm=float(x), y_mm=float(y),
                          dia_mm=dia_mm, plated=plated, entity=entity)


def tabulate_ir(rb: ResolvedBoard) -> SurfaceTable:
    """REFERENCE table, read straight off the ``ResolvedBoard`` dataclasses."""
    tokens = _layer_tokens(rb)
    stack = _copper_stack(rb)
    net_name_of = {net.id: net.name for net in rb.nets}
    rows: list[ParityRow] = []

    for comp in rb.components:
        numbers = {p.source_id: p.number for p in rb.footprint_for(comp).pads}
        for pad in comp.placed_pads:
            number = numbers.get(pad.source_id) or pad.source_id
            net_name = net_name_of.get(pad.net_id) if pad.net_id else None
            drilled = pad.drill is not None
            # NPTH carries no copper land at all — a bare mechanical hole. Emitting
            # a flash row for it would put phantom copper in the reference and make
            # every other surface look like it LOST copper.
            carries_copper = pad.pad_type != "np_thru_hole"
            if carries_copper:
                shape, w, h, _rr = _ir_pad_land(pad)
                layers = [tokens[layer.id] for layer in pad.layers
                          if layer.role is LayerRole.COPPER and layer.id in tokens]
                for token in layers:
                    rows.append(_flash_row(
                        token, pad.position[0], pad.position[1], shape=shape,
                        w=w, h=h, rot_deg=pad.rotation_deg, entity="pad",
                        ref=comp.ref, pad_number=number, net_name=net_name))
            if drilled:
                rows.append(_drill_row(pad.position[0], pad.position[1],
                                       pad.drill.size[0], pad.drill.plated,
                                       entity="pad"))
            rows.append(ParityRow.make("net_ownership", (comp.ref, number),
                                       net_name=net_name, ref=comp.ref,
                                       pad_number=number))

    for trace in rb.traces:
        name = net_name_of.get(trace.net_id)
        for seg in trace.segments:
            rows.append(_trace_row(tokens[seg.layer.id], seg.a, seg.b,
                                   seg.width_mm, name))

    for via in rb.vias:
        name = net_name_of.get(via.net_id)
        for token in _via_span_tokens(rb, via, tokens, stack):
            rows.append(_flash_row(
                token, via.position[0], via.position[1], shape=_SHAPE_CIRCLE,
                w=via.diameter_mm, h=via.diameter_mm, rot_deg=0.0, entity="via",
                ref=NA, pad_number=NA, net_name=name))
        rows.append(_drill_row(via.position[0], via.position[1], via.drill_mm,
                               True, entity="via"))

    for hole in rb.holes:
        feature = hole.feature
        if not isinstance(feature, RoundHole):
            # The fabrication path is round-only and RAISES on anything else
            # (gerber.py:_harvest_ir). Mirror that rather than inventing a row.
            raise ValueError(
                f"ir_parity: hole {hole.id!r} has a non-round feature "
                f"{type(feature).__name__} the parity harness cannot tabulate")
        x, y = feature.position
        rows.append(_drill_row(x, y, feature.diameter_mm, hole.plated,
                               entity="board_hole"))
        if hole.plated and hole.annulus_mm:
            for token in stack:
                rows.append(_flash_row(
                    token, x, y, shape=_SHAPE_CIRCLE, w=hole.annulus_mm,
                    h=hole.annulus_mm, rot_deg=0.0, entity="board_hole",
                    ref=NA, pad_number=NA, net_name=NA))

    # The IR carries no authored outline stroke — the frame is derived from board
    # bounds — so the CONTRACT value stands in for it. Both emitters import this
    # same constant, so this row is what a drifted emitter is measured against.
    rows.append(_outline_row(*_ir_outline(rb), EDGE_CUTS_WIDTH_MM))
    rows.extend(_ir_cutout_rows(rb))
    for index, token in enumerate(stack):
        rows.append(ParityRow.make("copper_layer", (token,), stack_index=index))
    rows.extend(_mask_rows(_ir_mask_openings(rb)))

    return SurfaceTable("ir", _IR_FAMILIES, _sorted(rows))


# Restated, NOT imported from ``pad_source`` — same rule as _TH_OBLONG_TOL_MM
# above, and for the same reason: the reference must not reach the owner the
# other three surfaces already share. Production never falls back to it (the
# compiler bakes the v1 manufacturing floor into the IR), so a board reaching
# this default has authored nothing and neither has the emitter.
_DEFAULT_MASK_CLEARANCE_MM = 0.1


def _ir_mask_clearance(rb: ResolvedBoard) -> float:
    """The board-global per-side mask clearance, off the IR's design rules.

    A missing or NEGATIVE authored value falls back to the default rather than
    raising: a negative clearance at BOARD scope has no defensible meaning,
    unlike a per-pad margin, which is a real KiCad feature and is honoured.
    """
    clearance = rb.design_rules.minimums.solder_mask_clearance_mm
    if clearance is not None and clearance >= 0:
        return float(clearance)
    return _DEFAULT_MASK_CLEARANCE_MM


def _ir_mask_dim(base: float, margin: float, what: str) -> float:
    """Enlarge a copper dimension by the per-side margin, FAILING CLOSED unless
    the opening stays a finite positive dimension.

    The boundary matters as much as the arithmetic: a merely-negative margin
    whose opening survives is a legitimate KiCad mask-sliver feature and is
    accepted; one that collapses the opening is not a manufacturable window and
    must not be tabulated as though it were.
    """
    dim = float(base) + 2.0 * float(margin)
    if not (math.isfinite(dim) and dim > 0):
        raise ValueError(
            f"ir_parity: {what}'s mask opening collapses to {dim} mm at margin "
            f"{margin} — not a manufacturable window, so the reference refuses "
            f"to state one")
    return dim


def _ir_pad_mask_openings(pad, ref: Any, number: Any,
                          clearance: float) -> list[_MaskAperture]:
    """Every mask opening ONE placed pad contributes, re-derived from IR fields.

    This is the reference's own reading of the ENUMERATION rule — which entities
    open the mask, on which sides, at what size — restated from the IR contract
    rather than delegated to ``mask_source``. That is the whole reason the family
    has teeth on this column: ``mask_source`` is what the DRC projection and the
    Gerber emitter both call, so a reference that called it too would agree by
    construction and could never report a change of mind inside it.

    The land itself comes from :func:`_ir_pad_land`, which the copper family
    already uses — so the two families cannot disagree about what the land IS,
    only about what covering it means.

    The branches, each a ratified fabrication rule:

      * SMD -> ONE opening, on the pad's own side, in the pad's own aperture
        family, enlarged by the effective margin (the pad's own
        ``solder_mask_margin`` override if it authored one, else the board
        clearance).
      * UNPLATED through-hole (or any ``np_thru_hole``) -> BOTH sides, at the
        DRILL size, with NO margin. A bare mechanical hole has no copper ring
        (finding 019f8fe77068).
      * PLATED through-hole -> BOTH sides, following the land, plus the margin.
    """
    plated_th = (pad.drill is not None and pad.drill.plated
                 and pad.pad_type != "np_thru_hole")
    who = f"{ref}.{number}"

    if pad.drill is not None and not plated_th:
        drill = float(pad.drill.size[0])
        return [_MaskAperture(_mask_side_token(side), pad.position[0],
                              pad.position[1], _SHAPE_CIRCLE, drill, drill, 0.0,
                              NA, "dark", entity="pad", ref=ref)
                for side in (Side.TOP, Side.BOTTOM)]

    margin = (float(pad.solder_mask_margin)
              if pad.solder_mask_margin is not None else clearance)
    shape, land_w, land_h, rratio = _ir_pad_land(pad)
    w = _ir_mask_dim(land_w, margin, who)
    h = _ir_mask_dim(land_h, margin, who)
    # The corner radius follows the OPENING, not the land: the emitter builds one
    # aperture from the enlarged dimensions and the same ratio, so a roundrect's
    # rounding grows with its window.
    radius = _mask_corner_radius(shape, w, h, rratio)
    sides = (pad.side,) if pad.drill is None else (Side.TOP, Side.BOTTOM)
    return [_MaskAperture(_mask_side_token(side), pad.position[0],
                          pad.position[1], shape, w, h, pad.rotation_deg,
                          radius, "dark", entity="pad", ref=ref)
            for side in sides]


def _ir_mask_openings(rb: ResolvedBoard) -> list[_MaskAperture]:
    """Every mask opening the board carries, walked from the IR itself.

    THE WALK IS PART OF THE CHECK. ``mask_source`` owns the enumeration for the
    other two surfaces; this one re-walks components -> placed pads, vias and
    board holes independently, so an entity class that stops opening the mask
    over there shows up here as a missing row rather than as silence.
    """
    clearance = _ir_mask_clearance(rb)
    out: list[_MaskAperture] = []

    for comp in rb.components:
        numbers = {p.source_id: p.number for p in rb.footprint_for(comp).pads}
        for pad in comp.placed_pads:
            number = numbers.get(pad.source_id) or pad.source_id
            out.extend(_ir_pad_mask_openings(pad, comp.ref, number, clearance))

    for via in rb.vias:
        # THE TENTING ASYMMETRY: a via is the one entity whose copper being
        # present on a side does NOT imply an opening there. Tented is the
        # default and means no window over a perfectly real annulus, so this is
        # a first-class per-side question rather than a filter (019f8fe7cbaf).
        if via.tented_front and via.tented_back:
            continue
        diameter = _ir_mask_dim(via.diameter_mm, clearance, f"via {via.id}")
        for side, tented in ((Side.TOP, via.tented_front),
                             (Side.BOTTOM, via.tented_back)):
            if not tented:
                out.append(_MaskAperture(
                    _mask_side_token(side), via.position[0], via.position[1],
                    _SHAPE_CIRCLE, diameter, diameter, 0.0, NA, "dark",
                    entity="via", ref=NA))

    for hole in rb.holes:
        if not isinstance(hole.feature, RoundHole):
            # Unreachable: tabulate_ir's copper walk raises on a non-round hole
            # before this runs. Restated rather than assumed, because reading
            # `.diameter_mm` off an OvalHole would be an AttributeError at some
            # later, less legible point — and because the two walks are separate
            # loops that a later edit could reorder.
            raise ValueError(
                f"ir_parity: hole {hole.id!r} has a non-round feature "
                f"{type(hole.feature).__name__} the mask family cannot tabulate")
        x, y = hole.feature.position
        if hole.plated:
            # A plated hole with NO authored annulus has no copper ring for an
            # opening to follow, so it contributes nothing — inventing a window
            # would put the reference ahead of the board (finding 019f8dbb7104).
            #
            # DEFENSIVE OVER AN IMPOSSIBLE STATE, not a live rule: ResolvedHole
            # REFUSES to construct plated-without-annulus ("a plated hole must
            # carry an authored copper annulus"), so no board that compiles can
            # reach this. Kept as a fail-safe, and the invariant that makes it
            # dead is pinned by
            # test_a_plated_hole_with_no_annulus_is_UNREPRESENTABLE_not_merely_untested
            # — if the IR ever relaxes it, that test fails and this branch
            # becomes load-bearing and needs a control of its own.
            if not hole.annulus_mm:
                continue
            diameter = _ir_mask_dim(hole.annulus_mm, clearance,
                                    f"hole {hole.id}")
        else:
            diameter = float(hole.feature.diameter_mm)
        for side in (Side.TOP, Side.BOTTOM):
            out.append(_MaskAperture(
                _mask_side_token(side), x, y, _SHAPE_CIRCLE, diameter,
                diameter, 0.0, NA, "dark", entity="board_hole", ref=NA))

    return out


def _via_span_tokens(rb: ResolvedBoard, via, tokens: Mapping[str, str],
                     stack: tuple[str, ...]) -> tuple[str, ...]:
    """Copper layers a via's land occupies, in stack order.

    A THROUGH via spans the whole stack; a blind/buried one spans its endpoints
    inclusive. Derived from ``stack_index`` rather than from the two endpoint
    names alone so a 4-layer board gets its inner lands too.
    """
    index_of = {layer.kicad_alias: layer.stack_index for layer in rb.layer_stack.copper}
    a = index_of.get(tokens.get(via.from_layer, ""), 0)
    b = index_of.get(tokens.get(via.to_layer, ""), len(stack) - 1)
    lo, hi = min(a, b), max(a, b)
    return tuple(stack[i] for i in range(lo, hi + 1))


def _outline_row(ox: float, oy: float, w: float, h: float,
                 stroke_width_mm: Any) -> ParityRow:
    """One board-outline row.

    ``stroke_width_mm`` is a COMPARED FIELD, not part of the key: the outline's
    identity is "the board", and two surfaces disagreeing about how thick its
    edge is must show up as a value delta on one row, not as a missing+extra
    pair of differently-keyed rows.

    Why the stroke belongs here at all: origin/width/height alone are blind to a
    whole class. The edge is ONE physical feature drawn by two emitters, and they
    carried two different widths for it (kicad 0.15, gerber 0.1) with no test
    able to see it — the outline family compared the rectangle and never the pen.
    The IR has no authored outline stroke (the frame is derived from bounds), so
    the IR side reports the CONTRACT (``fab_capability.EDGE_CUTS_WIDTH_MM``) and
    each emitter side reports what it actually WROTE. That makes this row a real
    three-way check: an emitter that stops reading the shared constant, or writes
    a literal beside it, diverges from the IR row and fails.
    """
    return ParityRow.make("outline", ("board",), origin_x_mm=ox,
                          origin_y_mm=oy, width_mm=w, height_mm=h,
                          stroke_width_mm=stroke_width_mm)


_KICAD_EDGE_STROKE_RE = re.compile(
    r'\(gr_line\b[^\n]*?\(layer\s+"Edge\.Cuts"\)[^\n]*?\(width\s+([0-9.eE+-]+)\)')


def _canonical_loop(points) -> tuple:
    """A vertex loop reduced to a START- and ORIENTATION-INVARIANT form.

    Two surfaces may legitimately emit the same opening beginning at a
    different vertex, or winding the other way — those are not divergences.
    Everything else about the shape is. Canonicalising by taking the
    lexicographically smallest rotation of the loop and of its reversal makes
    the comparison exact without making it brittle.
    """
    pts = [(round(float(x), 6), round(float(y), 6)) for (x, y) in points]
    n = len(pts)
    if n == 0:
        return ()
    candidates = []
    for seq in (pts, list(reversed(pts))):
        for i in range(n):
            candidates.append(tuple(seq[i:] + seq[:i]))
    return min(candidates)


def _loop_from_segments(segs) -> list:
    """Walk a cutout's grouped segments into a connected vertex loop.

    The grouping that produced ``segs`` is by endpoint connectivity, so the
    segments form one ring but arrive in emission order, not walk order. Chain
    them by matching endpoints (rounded to the same 1e-6 the canonical form
    uses) so the loop compared across surfaces is the real ring rather than an
    artifact of how the emitter happened to order its lines. Malformed topology
    is refused: inventing a coarse contour can alias a different valid opening
    and would turn an unreadable emitted surface into a false clean parity gate.
    """
    if not segs:
        return []

    def key(p):
        return (round(float(p[0]), 6), round(float(p[1]), 6))

    degree = collections.Counter()
    for a, b in segs:
        ka, kb = key(a), key(b)
        if ka == kb:
            raise ParityCanonicalizationUnsupported(
                "cutout contour contains a zero-length segment")
        degree[ka] += 1
        degree[kb] += 1
    if len(degree) < 3 or any(count != 2 for count in degree.values()):
        raise ParityCanonicalizationUnsupported(
            "cutout contour is not a simple closed ring")

    remaining = list(segs)
    first = remaining.pop(0)
    loop = [first[0], first[1]]
    while remaining:
        tail = key(loop[-1])
        for index, (a, b) in enumerate(remaining):
            if key(a) == tail:
                loop.append(b)
                remaining.pop(index)
                break
            if key(b) == tail:
                loop.append(a)
                remaining.pop(index)
                break
        else:
            raise ParityCanonicalizationUnsupported(
                "cutout contour segments do not form one connected ring")
    if len(loop) <= 1 or key(loop[0]) != key(loop[-1]):
        raise ParityCanonicalizationUnsupported(
            "cutout contour is open")
    loop.pop()  # drop the closing repeat; the ring is implicit
    return loop


def _cutout_row(min_x: float, min_y: float, max_x: float, max_y: float,
                segment_count: int, contour=()) -> ParityRow:
    """One interior-cutout row: keyed by rounded bbox, COMPARED on the exact
    canonical contour.

    THE BBOX IS NOT AN IDENTITY, and treating it as one made this family
    report clean on materially different openings: a rectangle
    [(2,2),(8,2),(8,8),(2,8)] and a diamond [(5,2),(8,5),(5,8),(2,5)] share a
    bounding box and an edge count, so their rows were byte-identical and an
    emitter could reshape the milled opening undetected (Codex review 1090
    finding 3, reproduced). Geometric DRC does not compensate — it checks the
    IR contour, never the emitted one — so this row is the only thing standing
    between a reshaped cutout and a clean gate.

    The bbox stays as the KEY (it is what lets two surfaces' rows for the same
    opening find each other), and the canonical contour rides as a COMPARED
    FIELD, so a mismatch surfaces as a field delta on one row rather than as a
    missing+extra pair that reads like two unrelated cutouts.
    """
    key = tuple(round(v, 6) for v in (min_x, min_y, max_x, max_y))
    return ParityRow.make("cutout", key, segment_count=segment_count,
                          contour=_canonical_loop(contour))


def _cutout_rows_from_segments(
        segments: list[tuple[tuple[float, float], tuple[float, float]]]
) -> list[ParityRow]:
    """Interior-cutout rows from a surface's FULL Edge.Cuts segment set.

    Groups segments into closed loops by endpoint connectivity (union-find on
    endpoints rounded to 1e-6 mm), computes each loop's bbox, and drops the
    loop whose bbox equals the union bbox — that one is the rim, which the
    ``outline`` family already owns. Everything left is an interior cutout.
    Shared by the kicad and gerber harvests so both surfaces read their own
    bytes through ONE grouping convention."""
    if not segments:
        return []

    def _key(point: tuple[float, float]) -> tuple[float, float]:
        return (round(point[0], 6), round(point[1], 6))

    parent: dict[tuple[float, float], tuple[float, float]] = {}

    def _find(node):
        while parent[node] is not node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    def _union(a, b):
        for node in (a, b):
            parent.setdefault(node, node)
        ra, rb = _find(a), _find(b)
        if ra is not rb:
            parent[ra] = rb

    for a, b in segments:
        _union(_key(a), _key(b))

    groups: dict[tuple[float, float], list] = {}
    for a, b in segments:
        groups.setdefault(_find(_key(a)), []).append((a, b))

    def _bbox(segs):
        xs = [c[0] for s in segs for c in s]
        ys = [c[1] for s in segs for c in s]
        return min(xs), min(ys), max(xs), max(ys)

    union_box = _bbox(segments)
    rows = []
    for segs in groups.values():
        box = _bbox(segs)
        contour = _loop_from_segments(segs)
        if tuple(round(v, 6) for v in box) == tuple(round(v, 6) for v in union_box):
            continue  # the rim — the outline family's row
        # Chain the grouped segments into a vertex loop for the canonical
        # contour: each segment contributes its start point, walked in
        # connection order so the loop is the real ring, not an arbitrary
        # segment ordering.
        rows.append(_cutout_row(*box, segment_count=len(segs),
                                contour=contour))
    return rows


_KICAD_EDGE_LINE_RE = re.compile(
    r'\(gr_line \(start ([\-0-9.eE+]+) ([\-0-9.eE+]+)\) '
    r'\(end ([\-0-9.eE+]+) ([\-0-9.eE+]+)\) \(layer "Edge\.Cuts"\)')


def _kicad_cutout_rows(text: str) -> list[ParityRow]:
    """Interior cutouts as kicad.py ACTUALLY wrote them — an independent
    re-reading of the emitted gr_line set, same doctrine as
    :func:`_kicad_outline_stroke`."""
    segments = [((float(x1), float(y1)), (float(x2), float(y2)))
                for x1, y1, x2, y2 in _KICAD_EDGE_LINE_RE.findall(text)]
    return _cutout_rows_from_segments(segments)


def _gerber_cutout_rows(parsed) -> list[ParityRow]:
    """Interior cutouts from the parsed Edge_Cuts stream, in the BOARD frame
    (per-ordinate Y negation undone by :func:`_board_y`)."""
    segments = []
    for obj in parsed.objects:
        x1, y1 = getattr(obj, "x1", None), getattr(obj, "y1", None)
        x2, y2 = getattr(obj, "x2", None), getattr(obj, "y2", None)
        if None not in (x1, y1, x2, y2):
            segments.append(((float(x1), _board_y(y1)),
                             (float(x2), _board_y(y2))))
    return _cutout_rows_from_segments(segments)


def _ir_cutout_rows(rb: ResolvedBoard) -> list[ParityRow]:
    """The IR's cutouts, through the same shared projection the emitters read
    (``cutout_point_loops``) — like :func:`_ir_outline`, the check is that the
    cutouts SURVIVE emission, not that they are derived twice."""
    from .ir_projection import cutout_point_loops
    rows = []
    for _cut_id, points in cutout_point_loops(rb.outline):
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        rows.append(_cutout_row(min(xs), min(ys), max(xs), max(ys),
                                segment_count=len(points), contour=points))
    return rows


def _kicad_outline_stroke(text: str) -> Any:
    """The stroke width kicad.py ACTUALLY wrote on the Edge.Cuts outline.

    Re-read from the emitted text here rather than taken from
    ``agent_router.kicad_io._parse_board_outline`` (which returns geometry only)
    — and deliberately so: an independent reading of the bytes is the whole point
    of a parity surface. Every outline segment must agree; a board whose four
    edges somehow carried different widths is itself the divergence, so a mixed
    set reports as a set and fails the comparison against the single IR value.
    """
    widths = {float(m) for m in _KICAD_EDGE_STROKE_RE.findall(text)}
    if not widths:
        return NA
    if len(widths) > 1:
        return tuple(sorted(widths))
    return widths.pop()


def _gerber_outline_stroke(parsed) -> Any:
    """The aperture diameter the Gerber Edge_Cuts strokes were drawn with.

    The outline is a traced path, so its "stroke" IS its aperture diameter. Same
    all-segments-agree rule as the kicad reader above.
    """
    widths = set()
    for obj in parsed.objects:
        aperture = getattr(obj, "aperture", None)
        diameter = getattr(aperture, "diameter", None)
        if diameter is not None:
            widths.add(round(float(diameter), 6))
    if not widths:
        return NA
    if len(widths) > 1:
        return tuple(sorted(widths))
    return widths.pop()


def _ir_outline(rb: ResolvedBoard) -> tuple[float, float, float, float]:
    """The IR board frame.

    This DOES route through ``ir_projection.outline_frame`` — the shared helper
    both emitters use — because unlike a pad land there is no second reading of a
    rectangle to be had, and re-deriving one here would be duplication rather
    than independence. The outline family therefore checks that the frame
    SURVIVES emission, not that the frame is computed twice.
    """
    from .ir_projection import outline_frame
    return outline_frame(rb.outline)


def _sorted(rows: Iterable[ParityRow]) -> tuple[ParityRow, ...]:
    """Deterministic row order: family, then key, rendered as strings.

    String rendering because a key mixes floats, strings and nested tuples, and
    Python will not order those against each other. This is a presentation order
    only — joins are by key — so the stringification cannot affect a verdict.
    """
    return tuple(sorted(rows, key=lambda r: (r.family, str(r.key), str(r.fields))))


# ---------------------------------------------------------------------------
# SURFACE 2 — geometric DRC, at the Projection it actually collision-checks.
# ---------------------------------------------------------------------------

# DRC models copper and drills, and knows the copper stack; it has no
# representation of the board OUTLINE as an entity (GC5 reads rb.outline inline
# at check time, which would be the IR itself and therefore tautological).
_DRC_FAMILIES = frozenset({"copper_flash", "copper_trace", "drill",
                           "copper_layer", "net_ownership", "mask_opening"})

#: mask_source ORIGIN tokens -> the coarse entity kind the other families use.
#: Restated here rather than imported, like every other cross-surface vocabulary
#: in this module. An origin missing from this map falls back to "board_hole",
#: which is the only kind that carries no ref and so cannot mis-attribute.
_MASK_ORIGIN_ENTITY = {
    "smd_pad": "pad", "th_pad": "pad", "npth_pad": "pad", "via": "via",
    "board_hole": "board_hole", "npth_board_hole": "board_hole",
}


def tabulate_drc(rb: ResolvedBoard) -> SurfaceTable:
    from .drc_geometric import project_board
    from .drc_geom_primitives import Capsule, OrientedRect

    tokens = _layer_tokens(rb)
    projection = project_board(rb)
    rows: list[ParityRow] = []
    seen_pads: set[tuple[str, str]] = set()

    for prim in projection.copper:
        shape = prim.shape
        if prim.kind == "trace_seg":
            if not isinstance(shape, Capsule):  # pragma: no cover - closed union
                raise TypeError(f"ir_parity: DRC trace {prim.entity_id} is not a Capsule")
            token = tokens.get(prim.layers[0], prim.layers[0])
            rows.append(_trace_row(token, (shape.ax, shape.ay), (shape.bx, shape.by),
                                   prim.width_mm, prim.net_name))
            continue
        if isinstance(shape, Capsule):
            kind, w, h, rot = _SHAPE_CIRCLE, shape.r * 2.0, shape.r * 2.0, 0.0
        elif isinstance(shape, OrientedRect):
            # DRC models a roundrect AND an oval land by their bounding rectangle
            # (a deliberate fail-safe SUPERSET, drc_geom_primitives OrientedRect
            # docstring). So DRC cannot distinguish those from a plain rect — a
            # real and EXPECTED shape delta, carried in the baseline, not hidden.
            kind = _SHAPE_RECT
            w, h, rot = shape.hw * 2.0, shape.hh * 2.0, math.degrees(shape.angle)
        else:  # pragma: no cover - closed union
            raise TypeError(f"ir_parity: unknown DRC shape {type(shape).__name__}")
        entity = {"smd_pad": "pad", "pth_pad": "pad", "via": "via"}.get(
            prim.kind, "board_hole")
        cx = shape.ax if isinstance(shape, Capsule) else shape.cx
        cy = shape.ay if isinstance(shape, Capsule) else shape.cy
        for layer_id in prim.layers:
            rows.append(_flash_row(
                tokens.get(layer_id, layer_id), cx, cy, shape=kind, w=w, h=h,
                rot_deg=rot, entity=entity,
                ref=prim.ref if prim.ref is not None else NA,
                pad_number=prim.pad_number if prim.pad_number is not None else NA,
                net_name=prim.net_name))
        if entity == "pad" and prim.ref and prim.pad_number:
            seen_pads.add((prim.ref, prim.pad_number))
            rows.append(ParityRow.make("net_ownership", (prim.ref, prim.pad_number),
                                       net_name=prim.net_name, ref=prim.ref,
                                       pad_number=prim.pad_number))

    for hole in projection.holes:
        # ``minor_mm`` is the limiting bore dimension; for the round drills this
        # fabrication path supports it IS the diameter (drc_geometric._hole_from_drill).
        rows.append(_drill_row(hole.position[0], hole.position[1], hole.minor_mm,
                               hole.plated,
                               entity={"pad": "pad", "via": "via"}.get(hole.origin,
                                                                       "board_hole")))
        # An NPTH pad reaches DRC as a hole with NO copper primitive, so its net
        # ownership row would otherwise be missing entirely rather than NA.
        if hole.origin == "pad" and hole.ref and hole.pad_number:
            if (hole.ref, hole.pad_number) not in seen_pads:
                seen_pads.add((hole.ref, hole.pad_number))
                rows.append(ParityRow.make(
                    "net_ownership", (hole.ref, hole.pad_number),
                    net_name=hole.net_name, ref=hole.ref,
                    pad_number=hole.pad_number))

    from .drc_geometric import _copper_layer_ids
    for index, layer_id in enumerate(_copper_layer_ids(rb)):
        rows.append(ParityRow.make("copper_layer", (tokens.get(layer_id, layer_id),),
                                   stack_index=index))

    # MASK OPENINGS AS THE CHECKER SEES THEM. `Projection.mask` is the exact
    # collection GC8 measures slivers on, so a disagreement here means the
    # sliver verdict was computed against geometry the fab will not receive —
    # and GC8's failure direction is a FALSE CLEAN (fewer apertures searched,
    # fewer slivers found, a healthier-looking board).
    #
    # This column DOES share mask_source with the Gerber emitter, and that was
    # S5's argument for declining the family. It is kept anyway because the
    # other two columns are independent of it and of each other: this is the
    # shared owner they are held up against, not a third opinion.
    rows.extend(_mask_rows(
        _MaskAperture(
            _mask_side_token(opening.side), opening.x, opening.y,
            _canonical_shape_token(opening.shape), opening.width, opening.height,
            opening.angle_deg,
            _mask_corner_radius(_canonical_shape_token(opening.shape),
                                opening.width, opening.height,
                                opening.corner_rratio),
            "dark",
            # The KIND token every other family uses here, derived from the
            # opening's ORIGIN — not `entity_id`, which is a board-wide unique
            # id no other surface can produce.
            entity=_MASK_ORIGIN_ENTITY.get(opening.origin, "board_hole"),
            ref=opening.ref if opening.ref is not None else NA)
        for opening in projection.mask))

    return SurfaceTable("drc", _DRC_FAMILIES, _sorted(rows))


# ---------------------------------------------------------------------------
# SURFACE 3 — the EMITTED .kicad_pcb text, parsed back.
# ---------------------------------------------------------------------------

# EXCLUDES mask_opening (epoch CP2 S11). Every other family is declared. The
# KiCad emitter never writes a mask APERTURE — it writes a per-pad
# `solder_mask_margin` and leaves the consumer to derive the opening — so there
# is nothing here to read back. Declaring the family anyway would turn
# "structurally cannot answer" into a stream of missing rows, which is exactly
# the distinction a surface's family set exists to keep.
_KICAD_FAMILIES = frozenset(FAMILIES) - {"mask_opening"}

# Segments and vias, read straight off the emitted s-expression. agent_router's
# kicad_io parses footprints/pads/nets/outline (reused below) but NOT these —
# ``load_kicad_pcb`` only fills nets and dimensions, and ``write_kicad_pcb`` is
# write-only. These two regexes are the missing readers, kept deliberately
# narrow: they match exactly what ``kicad.generate_kicad_pcb`` emits.
_SEGMENT_RE = re.compile(
    r'\(segment\s+\(start\s+([-\d.eE]+)\s+([-\d.eE]+)\)\s+'
    r'\(end\s+([-\d.eE]+)\s+([-\d.eE]+)\)\s+\(width\s+([-\d.eE]+)\)\s+'
    r'\(layer\s+"([^"]+)"\)\s+\(net\s+(\d+)\)\)')
_VIA_RE = re.compile(
    r'\(via\s+\(at\s+([-\d.eE]+)\s+([-\d.eE]+)\)\s+\(size\s+([-\d.eE]+)\)\s+'
    r'\(drill\s+([-\d.eE]+)\)\s+\(layers\s+"([^"]+)"\s+"([^"]+)"\)'
    r'(?:\s+\(tenting[^)]*\))?\s+\(net\s+(\d+)\)\)')
_SIGNAL_LAYER_RE = re.compile(r'\(\d+\s+"([^"]+)"\s+signal\)')

# UNNUMBERED pads — the board-level mounting holes. kicad_io's ``_parse_pad``
# requires a non-empty pad number (its regex is ``"?([^"\s]+)"?`` and it returns
# None when the number is absent), so every synthetic MountingHole footprint the
# emitter writes as ``(pad "" np_thru_hole ...)`` (kicad.py:854-882) is DROPPED by
# the reused reader. Without this recovery the harness would be blind to four
# drilled holes going missing from a fabrication-bound file, which is exactly the
# class of defect it exists to catch — so this covers a documented GAP in the
# existing parser rather than duplicating it.
#
# The tempered ``(?:(?!\(footprint).)*?`` cannot run past the next footprint, so a
# footprint carrying no unnumbered pad never borrows the following one's.
_UNNUMBERED_PAD_RE = re.compile(
    r'\(footprint\s+"[^"]*"\s+\(layer\s+"[^"]*"\)\s+'
    r'\(at\s+([-\d.eE]+)\s+([-\d.eE]+)(?:\s+([-\d.eE]+))?\)'
    r'(?:(?!\(footprint).)*?'
    r'\(pad\s+""\s+(\S+)\s+(\S+)\s+\(at\s+([-\d.eE]+)\s+([-\d.eE]+)(?:\s+[-\d.eE]+)?\)\s+'
    r'\(size\s+([-\d.eE]+)\s+([-\d.eE]+)\)\s+\(drill\s+([-\d.eE]+)\)',
    re.DOTALL)


def tabulate_kicad(rb: ResolvedBoard) -> SurfaceTable:
    """Emit the .kicad_pcb through the production IR path, then read it back.

    Pads/nets/outline are recovered with ``agent_router.kicad_io`` — the repo's
    existing KiCad reader, which applies KiCad's REAL load transform (translate +
    rotate, no flip) and is itself pinned against the pcbnew ``k1_bottom`` oracle
    (tests/test_ir_fab.py::_assert_pads_roundtrip). Reusing it means this harness
    measures what KiCad would load, not what a second hand-rolled parser guesses.

    ONE deliberate exception: the pad ANGLE is taken from the pad's own ``(at)``
    third value, NOT from ``kicad_io``'s ``Pad.rotation``. That field ADDS the
    footprint rotation to an already-absolute stored angle and so double-counts —
    a known agent_router bug recorded at tests/test_ir_fab.py:355-357. Using it
    would inject a READER defect into an EMITTER parity report.
    """
    from .kicad import generate_ir
    from agent_router.kicad_io import (  # first-party; not a dev-only dependency
        _parse_board_outline, _parse_footprints, _transform_position,
    )

    tokens = _layer_tokens(rb)
    stack = _copper_stack(rb)
    text = generate_ir(rb, base_name="parity")["parity.kicad_pcb"]

    net_of: dict[int, str] = {int(n): name for n, name in
                              re.findall(r'\(net\s+(\d+)\s+"([^"]*)"\)', text)}
    rows: list[ParityRow] = []

    for fp in _parse_footprints(text):
        ref = fp.get("reference", "")
        fx, fy = fp.get("position", (0.0, 0.0))
        frot = fp.get("rotation", 0.0)
        for pad in fp.get("pads", []):
            number = pad.get("number", "")
            lx, ly = pad.get("position", (0.0, 0.0))
            x, y = _transform_position(lx, ly, fx, fy, frot)
            pad_type = pad.get("type", "smd")
            shape = _canonical_shape_token(pad.get("shape", "rect"))
            w, h = pad.get("size", (0.0, 0.0))
            # ABSOLUTE angle straight off the pad (at) — see the docstring.
            rot = float(pad.get("rotation", 0.0))
            net_num = pad.get("net")
            net_name = net_of.get(net_num) if isinstance(net_num, int) else None
            if net_name == "":
                net_name = None
            drill = pad.get("drill")

            if pad_type != "np_thru_hole":
                # `(layers "*.Cu" ...)` is KiCad's "every copper layer" wildcard —
                # a through-hole pad. A sided SMD pad names its one layer.
                raw_layer = pad.get("layer", "F.Cu")
                layers = (stack if raw_layer.startswith("*")
                          else (tokens.get(raw_layer, raw_layer),))
                for token in layers:
                    rows.append(_flash_row(
                        token, x, y, shape=shape, w=w, h=h, rot_deg=rot,
                        entity="pad", ref=ref, pad_number=number,
                        net_name=net_name))
            if drill:
                rows.append(_drill_row(x, y, drill, pad_type != "np_thru_hole",
                                       entity="pad"))
            rows.append(ParityRow.make("net_ownership", (ref, number),
                                       net_name=net_name, ref=ref,
                                       pad_number=number))

    for m in _UNNUMBERED_PAD_RE.finditer(text):
        fx, fy, frot, pad_type, shape, lx, ly, sw, _sh, drill = m.groups()
        x, y = _transform_position(float(lx), float(ly), float(fx), float(fy),
                                   float(frot or 0.0))
        plated = pad_type != "np_thru_hole"
        rows.append(_drill_row(x, y, float(drill), plated, entity="board_hole"))
        if plated:
            # A PLATED board hole carries a copper ring whose diameter is the
            # emitted pad SIZE (the authored annulus, finding 019f8dbb7104).
            for token in stack:
                rows.append(_flash_row(
                    token, x, y, shape=_canonical_shape_token(shape),
                    w=float(sw), h=float(sw), rot_deg=0.0, entity="board_hole",
                    ref=NA, pad_number=NA, net_name=NA))

    for m in _SEGMENT_RE.finditer(text):
        x1, y1, x2, y2, width, layer, net_num = m.groups()
        rows.append(_trace_row(tokens.get(layer, layer),
                               (float(x1), float(y1)), (float(x2), float(y2)),
                               float(width), net_of.get(int(net_num)) or None))

    for m in _VIA_RE.finditer(text):
        x, y, size, drill, la, lb, net_num = m.groups()
        name = net_of.get(int(net_num)) or None
        lo = tokens.get(la, la)
        hi = tokens.get(lb, lb)
        span = stack[min(stack.index(lo), stack.index(hi)):
                     max(stack.index(lo), stack.index(hi)) + 1]
        for token in span:
            rows.append(_flash_row(token, float(x), float(y), shape=_SHAPE_CIRCLE,
                                   w=float(size), h=float(size), rot_deg=0.0,
                                   entity="via", ref=NA, pad_number=NA,
                                   net_name=name))
        rows.append(_drill_row(float(x), float(y), float(drill), True, entity="via"))

    width, height, ox, oy = _parse_board_outline(text)
    rows.append(_outline_row(ox, oy, width, height, _kicad_outline_stroke(text)))
    rows.extend(_kicad_cutout_rows(text))

    # KiCad's own layer ORDINALS (0, 2, ...) are its internal numbering, not a
    # stack index. The stack order is the order the signal layers are listed.
    for index, name in enumerate(_SIGNAL_LAYER_RE.findall(text)):
        rows.append(ParityRow.make("copper_layer", (tokens.get(name, name),),
                                   stack_index=index))

    return SurfaceTable("kicad", _KICAD_FAMILIES, _sorted(rows))


# ---------------------------------------------------------------------------
# SURFACE 4 — the EMITTED Gerber + Excellon bytes, parsed back with gerbonara.
# ---------------------------------------------------------------------------

# A Gerber file carries copper and an outline; it carries NO net list and no
# component identity by construction, so ``net_ownership`` is a family this
# surface cannot participate in at all. (Aperture .AperFunction attributes WOULD
# distinguish a ComponentPad from a ViaPad, but gerbonara 1.6.3 drops them on
# parse — verified: every parsed aperture comes back with ``attrs=()`` — so even
# the pad/via distinction is NA here, not merely unnamed.)
_GERBER_FAMILIES = frozenset({"copper_flash", "copper_trace", "drill",
                              "outline", "cutout", "copper_layer",
                              "mask_opening"})


class ParitySurfaceUnavailable(RuntimeError):
    """A surface cannot be tabulated ON THIS MACHINE — and nothing more.

    STRICTLY AN ENVIRONMENT CONDITION: a dev-only reader that is not installed.
    That is the whole extent of it, because a caller may legitimately convert
    this into "skip this surface", and anything else raised through it would
    become skippable too.

    IF THE DATA IS THE PROBLEM, RAISE
    :class:`ParityCanonicalizationUnsupported` INSTEAD. An unknown aperture, a
    macro whose parameters do not match its contract, an object kind a family
    cannot tabulate — none of those get better on another machine, and a
    caller's environment-skip path must never be able to swallow one. (Cold
    review of 6360a90, finding 2: the mask family's fail-closed raises were
    filed under this class and were therefore skippable in principle. Fixed;
    the boundary is pinned by test_the_two_refusal_classes_stay_distinct.)
    """


class ParityCanonicalizationUnsupported(RuntimeError):
    """A value cannot be reduced to a comparable canonical row.

    Covers the WHOLE read-to-canonical-row path, not only orientation folding:

      * a shape the orientation canonicaliser does not know how to fold;
      * an aperture form or macro this module has no decoding for, or one whose
        parameter list does not match the contract it is decoded against;
      * a graphic object kind a family cannot tabulate (a stroked line in a mask
        file, a routed slot in a round-only drill family).

    DELIBERATELY NOT a subclass of :class:`ParitySurfaceUnavailable`, and this is
    load-bearing. That one reports an ENVIRONMENT condition — a reader missing on
    this machine — which a caller may quite reasonably convert into "skip this
    surface". This one reports UNSUPPORTED OR CORRUPT FABRICATION DATA, or a gap
    in this module. Folding the two together would let a caller's environment-skip
    path silently disable the gate for a newly-added asymmetric pad shape or an
    unrecognised aperture, which is exactly the class of silent degradation the
    fail-closed rule exists to prevent. Fix the reader; never skip past this.
    """


class _FlashShape(NamedTuple):
    """One parsed aperture's canonical geometry, in the BOARD's terms.

    ``corner_radius_mm`` is ``None`` where the shape has no corner to round (a
    circle) and 0.0 where it has square corners — those are different facts and
    are not collapsed.
    """

    shape: str
    w_mm: float
    h_mm: float
    rot_deg: float
    corner_radius_mm: float | None


#: gerber-writer's aperture MACROS, each with an EXACT parameter contract, read
#: off the macro SOURCE it emits (``gerber_writer/macros.py``) rather than
#: inferred from a sample:
#:
#:   ``Rectangle``         $1 xsize/2  $2 ysize/2  $3 rotation
#:   ``RoundedRectangle``  $1 xsize/2  $2 ysize/2  $3 xsize/2-r  $4 ysize/2-r
#:                         $5 rotation  $6 2r  $7..$10 corner-circle centres
#:
#: The COUNT is part of the contract, which is why these are pinned as numbers
#: and checked exactly. See :func:`_gerbonara_shape` for why.
_MACRO_PARAM_COUNTS = {"Rectangle": 3, "RoundedRectangle": 10}

#: Slack for re-deriving one macro parameter from the others. gerber-writer
#: rounds every calculated AD parameter to 6 decimals (``DECIMALS = 6`` in its
#: writer), so each carries up to 5e-7 mm of error. The identity checked below —
#: ``half_extent - corner_offset == diameter / 2`` — COMBINES THREE ROUNDED
#: VALUES, so its worst case is 5e-7 + 5e-7 + 2.5e-7 = 1.25e-6 mm, not the 5e-7
#: an earlier version of this comment claimed. 1e-5 is ~8x that, and still 10x
#: below :data:`PARITY_TOLERANCE_MM`, so it cannot mask a real geometry
#: difference.
_MACRO_PARAM_TOLERANCE_MM = 1e-5

#: Slack for the INDEPENDENT rotation cross-check below.
#:
#: DERIVATION, corrected (cold review of 6360a90, finding 4 — the earlier
#: version of this comment claimed ~3x margin and had it about 1.2x). BOTH
#: vectors are rounded, not one: the corner-circle centre carries up to
#: sqrt(2) * 5e-7 mm of error in the worst direction, and so does the unrotated
#: offset it is compared against. Each contributes up to
#: ``asin(sqrt(2) * 5e-7 / offset)``, so at the smallest offset this check runs
#: on (:data:`_MACRO_MIN_CHECKABLE_OFFSET_MM` = 1e-2 mm) the difference can
#: approach 2 * 0.00405 = 0.0081 deg. 5e-2 leaves ~6x margin on that bound; a
#: two-million-sample probe by the reviewer found a 0.00726 deg maximum.
#:
#: WHY LOOSE IS RIGHT HERE, and why this is not a weakened geometry check: this
#: is a DECODING guard, not an accuracy one. It asks "is the parameter I am
#: treating as the rotation actually the rotation", and a slot that is not the
#: rotation holds a value with no relation to the true angle — the defect that
#: motivated it read 0.11 deg on a pad authored at 0, thirteen times this
#: threshold. REAL rotation error is caught by the cross-surface field
#: comparison at :data:`_ANGLE_TOLERANCE_DEG` (1e-3 deg), fifty times tighter.
#: Trading sensitivity this check does not need for margin against a
#: false-positive — which would take the whole gerber surface down — is the
#: right way round.
_MACRO_ANGLE_CROSSCHECK_TOL_DEG = 5e-2

#: Below this, a corner-circle centre is too close to the aperture's own centre
#: for its angle to be recoverable at all — the derived angle becomes
#: ill-conditioned, the error bound above diverges, and the outline is within
#: rounding of rotation-invariant anyway. The cross-check is skipped rather than
#: run on noise. It is the offset the tolerance above is derived AT, so the two
#: constants move together: raising this floor buys margin, lowering it spends
#: margin, and neither may be changed without redoing that arithmetic.
_MACRO_MIN_CHECKABLE_OFFSET_MM = 1e-2


def _gerbonara_shape(aperture) -> _FlashShape:
    """One parsed gerbonara aperture -> its canonical :class:`_FlashShape`.

    Mirrors ``gerber._shape_aperture`` in reverse. Circle/rect/obround are
    standard apertures and map directly. A land the standard apertures cannot
    express — a rotated rectangle, or any roundrect that is not a
    quarter-turned obround — is emitted as an aperture MACRO, and each macro is
    decoded through :data:`_MACRO_PARAM_COUNTS` by NAME and EXACT arity.

    BUG 019ff3696d95, and why the decoding looks paranoid. This function used to
    read the rotation as ``params[-1]`` for every macro, on a docstring that
    asserted the rotation was "the trailing parameter". That is true of
    ``Rectangle`` (3 params) and false of ``RoundedRectangle``, which emits TEN:
    its tail is a list of CORNER-CIRCLE CENTRES, so a pad authored at exactly 0
    degrees was reported rotated by whatever its last corner ordinate happened
    to be (measured: 0.11 deg on the seed coupon's C1 pad 1). That is worse than
    a wrong number on a surface whose entire job is to be the INDEPENDENT
    witness: a genuinely rotated land would have been compared against garbage
    rather than against nothing, so the fabricated error the family exists to
    catch could pass. Hence:

      * dispatch on the macro's exact NAME, never a substring — ``"rect" in
        macro`` also matches ``ChamferedRectangle``, which this reader has never
        been checked against and whose chamfer it would silently flatten;
      * require the exact parameter COUNT, so a gerber-writer that reshapes a
        macro fails closed here instead of being re-misread by position; and
      * re-derive the corner radius from BOTH extents and the rotation from the
        corner-circle geometry, and fail closed when the re-derivations
        disagree. Any of those three checks alone would have caught this bug.
    """
    name = type(aperture).__name__
    if name == "CircleAperture":
        d = float(aperture.diameter)
        return _FlashShape(_SHAPE_CIRCLE, d, d, 0.0, None)
    if name == "RectangleAperture":
        return _FlashShape(_SHAPE_RECT, float(aperture.w), float(aperture.h),
                           0.0, 0.0)
    if name == "ObroundAperture":
        # A standard obround IS fully rounded on its short axis, by definition
        # of the `O,` aperture — the radius is not a free parameter.
        w, h = float(aperture.w), float(aperture.h)
        return _FlashShape(_SHAPE_OVAL, w, h, 0.0, min(w, h) / 2.0)
    if name == "ApertureMacroInstance":
        macro = (getattr(aperture.macro, "name", "") or "").strip()
        params = [float(p) for p in aperture.parameters]
        expected = _MACRO_PARAM_COUNTS.get(macro)
        if expected is None:
            raise ParityCanonicalizationUnsupported(
                f"ir_parity: gerber aperture macro {macro!r} has no canonical "
                f"shape mapping — add its parameter contract to "
                f"_MACRO_PARAM_COUNTS after reading the macro source, rather "
                f"than decoding it by position")
        if len(params) != expected:
            raise ParityCanonicalizationUnsupported(
                f"ir_parity: gerber aperture macro {macro!r} carries "
                f"{len(params)} parameters, not the {expected} this reader's "
                f"decoding is pinned to — the writer's macro changed shape and "
                f"reading it by position would now report false geometry "
                f"(this is exactly bug 019ff3696d95); re-read the macro source")

        w, h = params[0] * 2.0, params[1] * 2.0
        if macro == "Rectangle":
            return _FlashShape(_SHAPE_RECT, w, h, params[2], 0.0)

        # RoundedRectangle. Radius appears three times over ($6 = 2r, and both
        # extents minus their corner-circle offset); require all three to agree.
        xc, yc, rot, diameter = params[2], params[3], params[4], params[5]
        radius = diameter / 2.0
        for half, offset, axis in ((params[0], xc, "x"), (params[1], yc, "y")):
            if abs((half - offset) - radius) > _MACRO_PARAM_TOLERANCE_MM:
                raise ParityCanonicalizationUnsupported(
                    f"ir_parity: RoundedRectangle macro is self-inconsistent on "
                    f"{axis}: half-extent {half} minus corner offset {offset} is "
                    f"{half - offset}, but $6/2 says the radius is {radius} — "
                    f"the parameter ORDER is not what this reader assumes")

        # ROTATION, re-derived independently of $5. $7/$8 is the first-quadrant
        # corner circle's centre AFTER rotation; (xc, yc) is the same point
        # before it. The angle between them IS the aperture's rotation, computed
        # from geometry rather than trusted from a slot index — which is the one
        # check that could not have been fooled by the bug above.
        offset_mag = math.hypot(xc, yc)
        if offset_mag >= _MACRO_MIN_CHECKABLE_OFFSET_MM:
            derived = math.degrees(math.atan2(params[7], params[6])
                                   - math.atan2(yc, xc))
            skew = abs((derived - rot + 180.0) % 360.0 - 180.0)
            if skew > _MACRO_ANGLE_CROSSCHECK_TOL_DEG:
                raise ParityCanonicalizationUnsupported(
                    f"ir_parity: RoundedRectangle macro says rotation {rot} deg "
                    f"($5), but its rotated corner-circle centre implies "
                    f"{derived} deg — the parameter this reader takes as the "
                    f"rotation is not the rotation")
        return _FlashShape(_SHAPE_ROUNDRECT, w, h, rot, radius)
    raise ParityCanonicalizationUnsupported(
        f"ir_parity: gerbonara aperture {name} has no canonical shape mapping")


def _board_y(y: Any) -> float:
    """One parsed GERBER (Y-UP) ordinate -> the BOARD (Y-DOWN) frame every other
    surface in this harness tabulates in.

    This is the read-side counterpart of ``gerber._Geometry.to_gerber_frame``, and
    it is a CORRECTION, not a convention (bug 019fa8011555). Before that fix the
    emitter wrote board-frame Y straight into the Gerber, so this harness compared
    the emitter's Y against the IR's Y and agreed — with BOTH surfaces read in the
    same wrong frame. That is precisely why a global vertical mirror was invisible
    to parity: a comparison between two parties who share an assumption cannot test
    the assumption. Converting HERE keeps the reference frame of the harness the
    IR's, which is the only frame the other three surfaces can speak.

    Kept as a named function, applied at every gerber ordinate read below, so a
    row type added later cannot quietly tabulate a raw gerber Y.
    """
    return -float(y)


def tabulate_gerber(rb: ResolvedBoard) -> SurfaceTable:
    """Emit the fabrication set through the production IR path, then parse the
    BYTES back with gerbonara — the independent reader the repo already pins for
    fabrication verification (pyproject ``dev`` extra, gerbonara==1.6.3).

    Y is converted back to the BOARD frame on read (see :func:`_board_y`) — the
    emitted file is Y-UP, every other surface here is Y-DOWN.

    Reuses the parse idioms of tests/oracle/geometry_diff.py (``from_string``
    under a warnings guard) but NOT its canonical-key model: that module collapses
    every graphic into an anonymous ``Counter`` key for a two-output-set set-diff,
    which is the wrong shape for per-entity, per-FIELD cross-surface rows. The
    parser being reused here is gerbonara itself; no second Gerber reader exists
    in this repo and none is written.
    """
    try:
        from gerbonara import ExcellonFile, GerberFile
    except ImportError as exc:  # pragma: no cover - environment-dependent
        raise ParitySurfaceUnavailable(
            "ir_parity: the gerber surface needs the dev-only reader gerbonara "
            "(pip install -e '.[dev]')") from exc
    import warnings

    from .gerber import build_gerbers_ir

    tokens = _layer_tokens(rb)
    files = build_gerbers_ir(rb, name="parity")
    rows: list[ParityRow] = []
    copper_suffixes: list[str] = []

    for filename, text in sorted(files.items()):
        suffix = filename.rsplit("-", 1)[-1].rsplit(".", 1)[0]
        if filename.endswith(".gbr"):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                parsed = GerberFile.from_string(text, filename=filename)
            if suffix.endswith("_Cu"):
                token = tokens.get(suffix, suffix.replace("_", "."))
                copper_suffixes.append(token)
                for obj in parsed.objects:
                    kind = type(obj).__name__
                    if kind == "Flash":
                        geom = _gerbonara_shape(obj.aperture)
                        rows.append(_flash_row(
                            token, float(obj.x), _board_y(obj.y),
                            shape=geom.shape, w=geom.w_mm, h=geom.h_mm,
                            rot_deg=geom.rot_deg,
                            # A Gerber flash is anonymous: no component ref, no
                            # pad number, no net, and (gerbonara drops
                            # .AperFunction) not even pad-vs-via.
                            entity=NA, ref=NA, pad_number=NA, net_name=NA))
                    elif kind == "Line":
                        rows.append(_trace_row(
                            token, (float(obj.x1), _board_y(obj.y1)),
                            (float(obj.x2), _board_y(obj.y2)),
                            float(obj.aperture.diameter), NA))
            elif suffix.endswith("_Mask"):
                # THE COLUMN WITH TEETH (epoch CP2 S11). Everything between
                # mask_source's answer and these bytes is untouched by the IR
                # and DRC columns: _adopt_mask_openings' side-to-bucket routing,
                # to_gerber_frame's Y negation, aperture construction, and
                # serialization. A comparison of two in-memory harvests cannot
                # reach any of it.
                #
                # FAIL CLOSED on anything that is not a Flash. Skipping an
                # object would SHRINK this surface's row set, and a shrunken set
                # makes "no extra rows" pass more easily — a false clean in the
                # direction a reader is least likely to check.
                side_token = "F.Mask" if suffix.startswith("F") else "B.Mask"
                apertures = []
                for obj in parsed.objects:
                    if type(obj).__name__ != "Flash":
                        raise ParityCanonicalizationUnsupported(
                            f"ir_parity: {filename} carries a "
                            f"{type(obj).__name__}, which the mask family cannot "
                            f"tabulate — mask output is flashes only; extend "
                            f"this reader rather than skipping the object")
                    geom = _gerbonara_shape(obj.aperture)
                    apertures.append(_MaskAperture(
                        side_token, float(obj.x), _board_y(obj.y),
                        geom.shape, geom.w_mm, geom.h_mm, geom.rot_deg,
                        NA if geom.corner_radius_mm is None
                        else geom.corner_radius_mm,
                        # POLARITY read from the file, not assumed. A clear
                        # flash has identical extents and the opposite meaning;
                        # an emitter that inverted one would otherwise be
                        # geometrically indistinguishable from a correct board.
                        "dark" if obj.polarity_dark else "clear",
                        # A mask flash is as anonymous as a copper one:
                        # gerbonara drops .AperFunction, so there is no ref, no
                        # pad number, and no pad-vs-via.
                        entity=NA, ref=NA))
                rows.extend(_mask_rows(apertures))
            elif suffix == "Edge_Cuts":
                rows.append(_outline_row(*_gerber_outline(parsed),
                                         _gerber_outline_stroke(parsed)))
                rows.extend(_gerber_cutout_rows(parsed))
        elif filename.endswith(".drl"):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                parsed = ExcellonFile.from_string(text, filename=filename)
            # PLATING is carried by the FILE SPLIT, not by the hit — which is the
            # only place gerber says it, and therefore the right place to read it.
            plated = suffix.upper() == "PTH"
            for obj in parsed.objects:
                if type(obj).__name__ != "Flash":
                    raise ParityCanonicalizationUnsupported(
                        f"ir_parity: {filename} carries a routed slot the parity "
                        f"harness's round-only drill family cannot tabulate")
                rows.append(_drill_row(float(obj.x), _board_y(obj.y),
                                       float(obj.tool.diameter), plated))

    # Stack index is NA: a Gerber output set is a bag of named files with no
    # stackup datum. The layer's IDENTITY is still checked.
    for token in sorted(set(copper_suffixes)):
        rows.append(ParityRow.make("copper_layer", (token,), stack_index=NA))

    return SurfaceTable("gerber", _GERBER_FAMILIES, _sorted(rows))


def _gerber_outline(parsed) -> tuple[float, float, float, float]:
    """Board frame as the axis-aligned bounds of the Edge.Cuts graphics.

    Ordinates are converted to the BOARD frame on read (:func:`_board_y`), so the
    ORIGIN reported here is the board-frame minimum — which is the negated gerber
    MAXIMUM, not the negated minimum. Width/height are frame-invariant."""
    xs: list[float] = []
    ys: list[float] = []
    for obj in parsed.objects:
        for attr_x, attr_y in (("x1", "y1"), ("x2", "y2"), ("x", "y")):
            x, y = getattr(obj, attr_x, None), getattr(obj, attr_y, None)
            if x is not None and y is not None:
                xs.append(float(x))
                ys.append(_board_y(y))
    if not xs:
        raise ParityCanonicalizationUnsupported("ir_parity: Edge_Cuts carries no geometry")
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


# ---------------------------------------------------------------------------
# Diff + baseline
# ---------------------------------------------------------------------------


def tabulate_all(rb: ResolvedBoard) -> dict[str, SurfaceTable]:
    return {
        "ir": tabulate_ir(rb),
        "drc": tabulate_drc(rb),
        "kicad": tabulate_kicad(rb),
        "gerber": tabulate_gerber(rb),
    }


def diff_against_reference(reference: SurfaceTable,
                           surface: SurfaceTable) -> list[Delta]:
    """Every disagreement between ``surface`` and the reference table.

    Compared PER FAMILY, and only for families BOTH tables participate in. Row
    joins are by key; within a joined row, only fields the reference actually
    carries are compared, and :data:`NA` on either side is silence, not assent to
    a wrong value — it means "this surface has nothing to say here".

    A row appearing MORE THAN ONCE under the same key (two pads stacked at one
    coordinate on one layer) collapses: the harness compares row IDENTITY, not
    multiplicity. That is a deliberate limit — the fixtures carry no coincident
    copper — and it is stated here rather than discovered later.

    ``mask_opening`` IS EXEMPT, and it is the one family that is. Its key carries
    an OCCURRENCE ORDINAL (see :func:`_mask_rows`), precisely so coincident
    apertures cannot collapse: a mask window is fabrication-critical and losing
    one duplicate would read as a clean board. Any family added later that can
    carry coincident geometry should do the same rather than inherit the limit
    above by default.
    """
    deltas: list[Delta] = []
    for family in FAMILIES:
        if family not in reference.families or family not in surface.families:
            continue
        ref_rows = reference.by_family(family)
        got_rows = surface.by_family(family)
        for key in sorted(ref_rows, key=str):
            ref_row = ref_rows[key]
            got_row = got_rows.get(key)
            if got_row is None:
                deltas.append(Delta(surface.surface, family, "missing_row", key,
                                    None, "present", "absent", ref_row.describe()))
                continue
            got_fields = got_row.field_map()
            for name, ref_value in sorted(ref_row.field_map().items()):
                got_value = got_fields.get(name, NA)
                if not _values_agree(name, ref_value, got_value):
                    deltas.append(Delta(surface.surface, family, "field", key,
                                        name, ref_value, got_value,
                                        ref_row.describe()))
        for key in sorted(set(got_rows) - set(ref_rows), key=str):
            deltas.append(Delta(surface.surface, family, "extra_row", key, None,
                                "absent", "present", got_rows[key].describe()))
    return deltas


def check_parity(rb: ResolvedBoard | None,
                 baseline: Iterable[KnownDelta] = (),
                 *, tables: Mapping[str, SurfaceTable] | None = None) -> ParityReport:
    """Tabulate every surface, diff each against the IR, and subtract the baseline.

    ``tables`` is an injection point for the teeth tests: they hand in a table
    set with ONE surface perturbed, so the perturbation is proven to be REPORTED
    rather than merely believed to be. When ``tables`` is supplied, ``rb`` is
    unused and may be ``None`` — the tables ARE the input.
    """
    if tables is None and rb is None:
        raise ValueError("check_parity needs either a ResolvedBoard or tables=")
    tables = dict(tables) if tables is not None else tabulate_all(rb)
    reference = tables[REFERENCE_SURFACE]
    deltas: list[Delta] = []
    skipped: list[tuple[str, str]] = []
    for name in SURFACES:
        table = tables.get(name)
        if table is None or name == REFERENCE_SURFACE:
            continue
        deltas.extend(diff_against_reference(reference, table))
        for family in FAMILIES:
            if family in reference.families and family not in table.families:
                skipped.append((name, family))

    entries = list(baseline)
    matched: dict[int, list[tuple]] = {index: [] for index in range(len(entries))}
    unexplained: list[Delta] = []
    for delta in deltas:
        for index, entry in enumerate(entries):
            if entry.matches(delta):
                matched[index].append(delta.key)
                break
        else:
            # Includes a delta whose SIGNATURE matches a listed entry but whose
            # ROW does not. That is the displaced-member case, and it must land
            # here rather than being absorbed by the class it resembles.
            unexplained.append(delta)

    stale = tuple((entry, tuple(sorted(matched[index], key=str)))
                  for index, entry in enumerate(entries)
                  if sorted(matched[index], key=str) != sorted(entry.keys, key=str))
    return ParityReport(tuple(deltas), tuple(unexplained), stale, tuple(skipped))


#: How many individual deltas a failure message prints per class before eliding.
#: A run that breaks one pad prints that pad; a run that breaks the coordinate
#: system prints enough to recognize the pattern without burying CI in 4000 lines.
_MAX_SHOWN_PER_CLASS = 8


def format_report(report: ParityReport) -> str:
    """The CI-legible failure message.

    Written so that somebody reading ONLY the CI log can act: it names the
    SURFACE, the ENTITY and the FIELD with both values, groups by class so a
    systematic break reads as one problem rather than N, and states explicitly
    what a stale baseline entry means (which direction it drifted, and what to do).
    """
    lines: list[str] = []
    if report.unexplained:
        grouped: dict[tuple, list[Delta]] = {}
        for delta in report.unexplained:
            grouped.setdefault(delta.signature(), []).append(delta)
        lines.append(f"UNEXPLAINED PARITY DELTAS: {len(report.unexplained)} "
                     f"in {len(grouped)} class(es). Each is a surface disagreeing "
                     f"with the compiled IR.")
        for signature in sorted(grouped, key=str):
            found = grouped[signature]
            surface, family, kind, name = signature
            lines.append("")
            lines.append(f"  {surface} / {family} / {kind}"
                         + (f" / field {name!r}" if name else "")
                         + f"  x{len(found)}")
            for delta in found[:_MAX_SHOWN_PER_CLASS]:
                lines.append(f"    {delta.render()}")
            if len(found) > _MAX_SHOWN_PER_CLASS:
                lines.append(f"    ... and {len(found) - _MAX_SHOWN_PER_CLASS} more")
        lines.append("")
        lines.append("  If a delta is CORRECT-BUT-NOT-YET-MIGRATED, add a "
                     "KnownDelta to the baseline with a reason and a docket id. "
                     "If it is a DEFECT, fix the surface — do not baseline it.")
    for entry, actual in report.stale:
        declared = set(entry.keys)
        found = set(actual)
        lines.append("")
        lines.append(
            f"STALE BASELINE: {entry.surface}/{entry.family}/{entry.kind}"
            + (f"/{entry.field}" if entry.field else "")
            + f" declares {entry.count} row(s), matched {len(actual)}.")
        lines.append(f"    reason: {entry.reason}")
        lines.append(f"    docket: {entry.docket}")
        for key in sorted(declared - found, key=str):
            lines.append(f"    NO LONGER PRESENT: {key} — the surface was FIXED "
                         f"for this row; drop it from the entry. The baseline "
                         f"reaching zero is the migration's exit condition.")
        for key in sorted(found - declared, key=str):  # pragma: no cover - see note
            # Unreachable while `matches()` gates on the key: an unlisted row
            # cannot be matched, so it becomes `unexplained` instead. Kept so the
            # report stays correct if matching is ever loosened.
            lines.append(f"    UNEXPECTED ROW: {key} — matched this entry but is "
                         f"not declared by it.")
    if report.skipped:
        lines.append("")
        lines.append("  (families skipped as not-applicable: "
                     + ", ".join(f"{s}:{f}" for s, f in report.skipped) + ")")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# THE KNOWN-DELTA BASELINE for tests/testdata/smart_remote.yaml.
#
# Each entry is a delta that EXISTS TODAY and is explained. It is not a
# suppression list: the count makes a new delta of the same class fail, and a
# fixed one fail too. This list reaching length 0 is the visible exit condition
# for the surface migration.
#
# ATTRIBUTION RULE: ``docket`` cites an id only where one is recoverable from an
# existing code comment. Where none is, it says "unattributed" and the reason
# describes the delta precisely enough to act on. No id is ever invented.
# ---------------------------------------------------------------------------

SMART_REMOTE_BASELINE: tuple[KnownDelta, ...] = (
    # The Excellon writer emits metric 3.3 decimal — X{:.3f}, a 1-micron grid
    # (gerber.py:_excellon, ";FORMAT={3:3/ absolute / metric / decimal}"). Three
    # U1 pads are authored at x_mm: -0.00368, so under the component's 180-degree
    # placement BOTH their absolute coordinates land off the micron grid
    # (60.96368 -> 60.964, and 10.16272 / 12.70272 / 15.24272 -> .163/.703/.243).
    # The drill file cannot say it more precisely; the IR-side value is exact.
    #
    # ACCEPTED, not a defect: 0.3 micron is two orders of magnitude finer than any
    # drill-position tolerance a fab quotes, and the 3.3 format is the one the CAM
    # spike ratified. It stays enumerated so that if Excellon precision ever
    # changes — in either direction — these rows move and somebody looks.
    #
    # HISTORY: before the key quantum was decoupled from the comparison epsilon,
    # this same fact surfaced as three missing rows plus three unrelated extra
    # rows, because the 0.3-micron difference also broke the row JOIN. It is the
    # worked example for why those two numbers must differ.
    KnownDelta(
        surface="gerber", family="drill", kind="field", field="x_mm",
        keys=((60.96, 10.16), (60.96, 12.7), (60.96, 15.24)),
        reason="Excellon 3.3 decimal (1-micron) coordinate grid rounds the three "
               "U1 pads authored at x_mm -0.00368: absolute x 60.96368 -> 60.964.",
        docket="unattributed"),
    KnownDelta(
        surface="gerber", family="drill", kind="field", field="y_mm",
        keys=((60.96, 10.16), (60.96, 12.7), (60.96, 15.24)),
        reason="The y axis of the same three hits, rounded by the same Excellon "
               "1-micron grid: 10.16272 / 12.70272 / 15.24272 -> .163 / .703 / .243.",
        docket="unattributed"),
)


PARITY_CORNERS_BASELINE: tuple[KnownDelta, ...] = (
    # The geometric DRC deliberately models an OVAL (obround) land by its bounding
    # ORIENTED RECTANGLE — an exact-or-SUPERSET primitive, never an under-statement
    # (drc_geom_primitives module docstring, docket 019f952306f9). Reporting "rect"
    # where the IR says "oval" is that policy working, not drift: DRC may raise a
    # false clearance violation, and must never miss a real one.
    #
    # This entry should NOT go to zero by "fixing DRC" — it goes to zero only if
    # DRC ever gains a true obround primitive. Until then it documents a KNOWN,
    # INTENTIONAL conservatism at the one seam where it is visible.
    KnownDelta(
        surface="drc", family="copper_flash", kind="field", field="shape",
        keys=(("B.Cu", 10.54, 8.0), ("F.Cu", 10.54, 8.0)),
        reason="J1.2's oblong OVAL through-hole land: geometric DRC models an oval "
               "by its bounding OrientedRect (fail-safe SUPERSET), so it reports "
               "'rect' where the IR reports 'oval'. Centre, size and rotation agree.",
        docket="019f952306f9"),

    # ---------------------------------------------------------------------
    # REMOVED — the gerber rotated-oval defect (docket 019f9af6e899) that this
    # harness found on its first corner-fixture run is FIXED, so its baseline entry
    # is gone rather than relaxed. J1.2's 90-degree oblong OVAL land now flashes
    # '%ADD..O,2.4X1.2*%' (swapped extents) on both copper layers and on the mask,
    # agreeing with the IR, KiCad and DRC. See gerber._obround_rotation_swap for the
    # workaround and the canary test that pins the upstream behaviour it relies on.
    # The baseline shrinking from 4 entries to 3 IS the proof; do not re-add.
)
