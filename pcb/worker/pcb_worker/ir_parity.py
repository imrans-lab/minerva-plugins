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

import math
import re
from dataclasses import dataclass
from typing import Any, Iterable, Mapping

from .resolved_board import LayerRole, ResolvedBoard, RoundHole

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


def _flash_row(layer_token: str, x: float, y: float, *, shape: str, w: float,
               h: float, rot_deg: float, entity: Any, ref: Any, pad_number: Any,
               net_name: Any) -> ParityRow:
    """The ONE constructor for a ``copper_flash`` row. Every surface goes through
    it so the key shape and field set cannot drift per tabulator.

    The centre appears TWICE and on purpose: BUCKETED in the key (identity) and
    RAW in ``x_mm``/``y_mm`` (a compared value). Without the raw copy a displaced
    pad inside the same bucket would be invisible, and one outside it would be an
    illegible missing/extra pair — position would never actually be CHECKED."""
    return ParityRow.make(
        "copper_flash", (layer_token, _q(x), _q(y)),
        x_mm=float(x), y_mm=float(y),
        shape=shape, w_mm=w, h_mm=h,
        rot_deg=_canonical_rotation(shape, w, h, rot_deg) if rot_deg is not NA else NA,
        entity=entity, ref=ref, pad_number=pad_number, net_name=net_name)


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

    rows.append(_outline_row(*_ir_outline(rb)))
    for index, token in enumerate(stack):
        rows.append(ParityRow.make("copper_layer", (token,), stack_index=index))

    return SurfaceTable("ir", _IR_FAMILIES, _sorted(rows))


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


def _outline_row(ox: float, oy: float, w: float, h: float) -> ParityRow:
    return ParityRow.make("outline", ("board",), origin_x_mm=ox,
                          origin_y_mm=oy, width_mm=w, height_mm=h)


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
                           "copper_layer", "net_ownership"})


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

    return SurfaceTable("drc", _DRC_FAMILIES, _sorted(rows))


# ---------------------------------------------------------------------------
# SURFACE 3 — the EMITTED .kicad_pcb text, parsed back.
# ---------------------------------------------------------------------------

_KICAD_FAMILIES = frozenset(FAMILIES)

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
    rows.append(_outline_row(ox, oy, width, height))

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
                              "outline", "copper_layer"})


class ParitySurfaceUnavailable(RuntimeError):
    """A surface cannot be tabulated on this machine (missing dev-only reader)."""


def _gerbonara_shape(aperture) -> tuple[str, float, float, float]:
    """One parsed gerbonara aperture -> ``(shape, w_mm, h_mm, rot_deg)``.

    Mirrors ``gerber._shape_aperture`` in reverse — circle/rect/obround map
    directly; a ROTATED land is emitted as an aperture MACRO whose trailing
    parameter is the rotation and whose leading parameters are HALF-extents
    (gerber-writer's Rectangle/RoundRect macro convention, confirmed against
    emitted bytes for the smart-remote fixture).
    """
    name = type(aperture).__name__
    if name == "CircleAperture":
        d = float(aperture.diameter)
        return _SHAPE_CIRCLE, d, d, 0.0
    if name == "RectangleAperture":
        return _SHAPE_RECT, float(aperture.w), float(aperture.h), 0.0
    if name == "ObroundAperture":
        return _SHAPE_OVAL, float(aperture.w), float(aperture.h), 0.0
    if name == "ApertureMacroInstance":
        params = [float(p) for p in aperture.parameters]
        macro = (getattr(aperture.macro, "name", "") or "").lower()
        rot = params[-1] if len(params) >= 3 else 0.0
        w, h = params[0] * 2.0, params[1] * 2.0
        if "round" in macro and "rect" in macro:
            return _SHAPE_ROUNDRECT, w, h, rot
        if "rect" in macro:
            return _SHAPE_RECT, w, h, rot
        raise ParitySurfaceUnavailable(
            f"ir_parity: gerber aperture macro {macro!r} has no canonical shape "
            f"mapping — extend _gerbonara_shape rather than guessing")
    raise ParitySurfaceUnavailable(
        f"ir_parity: gerbonara aperture {name} has no canonical shape mapping")


def tabulate_gerber(rb: ResolvedBoard) -> SurfaceTable:
    """Emit the fabrication set through the production IR path, then parse the
    BYTES back with gerbonara — the independent reader the repo already pins for
    fabrication verification (pyproject ``dev`` extra, gerbonara==1.6.3).

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
                        shape, w, h, rot = _gerbonara_shape(obj.aperture)
                        rows.append(_flash_row(
                            token, float(obj.x), float(obj.y), shape=shape, w=w,
                            h=h, rot_deg=rot,
                            # A Gerber flash is anonymous: no component ref, no
                            # pad number, no net, and (gerbonara drops
                            # .AperFunction) not even pad-vs-via.
                            entity=NA, ref=NA, pad_number=NA, net_name=NA))
                    elif kind == "Line":
                        rows.append(_trace_row(
                            token, (float(obj.x1), float(obj.y1)),
                            (float(obj.x2), float(obj.y2)),
                            float(obj.aperture.diameter), NA))
            elif suffix == "Edge_Cuts":
                rows.append(_outline_row(*_gerber_outline(parsed)))
        elif filename.endswith(".drl"):
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                parsed = ExcellonFile.from_string(text, filename=filename)
            # PLATING is carried by the FILE SPLIT, not by the hit — which is the
            # only place gerber says it, and therefore the right place to read it.
            plated = suffix.upper() == "PTH"
            for obj in parsed.objects:
                if type(obj).__name__ != "Flash":
                    raise ParitySurfaceUnavailable(
                        f"ir_parity: {filename} carries a routed slot the parity "
                        f"harness's round-only drill family cannot tabulate")
                rows.append(_drill_row(float(obj.x), float(obj.y),
                                       float(obj.tool.diameter), plated))

    # Stack index is NA: a Gerber output set is a bag of named files with no
    # stackup datum. The layer's IDENTITY is still checked.
    for token in sorted(set(copper_suffixes)):
        rows.append(ParityRow.make("copper_layer", (token,), stack_index=NA))

    return SurfaceTable("gerber", _GERBER_FAMILIES, _sorted(rows))


def _gerber_outline(parsed) -> tuple[float, float, float, float]:
    """Board frame as the axis-aligned bounds of the Edge.Cuts graphics."""
    xs: list[float] = []
    ys: list[float] = []
    for obj in parsed.objects:
        for attr_x, attr_y in (("x1", "y1"), ("x2", "y2"), ("x", "y")):
            x, y = getattr(obj, attr_x, None), getattr(obj, attr_y, None)
            if x is not None and y is not None:
                xs.append(float(x))
                ys.append(float(y))
    if not xs:
        raise ParitySurfaceUnavailable("ir_parity: Edge_Cuts carries no geometry")
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
    # DEFECT, NOT A POLICY — found by this harness on its first corner-fixture
    # run, and left here as a baseline entry ONLY because this round is
    # report-only. This one SHOULD go to zero, and doing so is a fix in
    # pcb_worker/gerber.py.
    #
    # gerber._shape_aperture (gerber.py:645-672) maps an `oval` land to
    # gerber-writer's RoundedRectangle(w, h, min(w,h)/2) — fully rounded on the
    # short axis. gerber-writer optimizes that degenerate case down to the
    # STANDARD Gerber obround primitive, and a standard aperture has no rotation
    # parameter. The emitted bytes for J1.2 are:
    #
    #     G04 #@! TAShape,RoundedRectangle,1.2,2.4,0.6,90.0*
    #     %ADD16O,1.2X2.4*%
    #
    # The 90 degrees survives only in the X2 ATTRIBUTE COMMENT, which is metadata;
    # the aperture a CAM tool actually flashes is an axis-aligned 1.2 x 2.4
    # obround. No %LR rotation command is emitted anywhere in the file (verified).
    # So the fabricated land is 1.2 wide and 2.4 tall where the IR, the KiCad
    # export and the DRC all say 2.4 wide and 1.2 tall.
    #
    # Contrast the rect family two apertures earlier — `%ADD15Rectangle,0.6X1.2X90.0*%`
    # — an aperture MACRO, which does carry rotation. The loss is specific to the
    # fully-rounded (oval/obround) case; roundrect with a smaller radius still
    # emits a macro and keeps its angle.
    #
    # Not fixed in this round (scope fence: no existing worker module modified).
    KnownDelta(
        surface="gerber", family="copper_flash", kind="field", field="rot_deg",
        keys=(("B.Cu", 10.54, 8.0), ("F.Cu", 10.54, 8.0)),
        reason="DEFECT: an oblong OVAL land loses its rotation in Gerber. "
               "_shape_aperture maps oval -> fully-rounded RoundedRectangle, which "
               "gerber-writer collapses to the standard obround aperture "
               "'%ADD16O,1.2X2.4*%'; standard apertures carry no rotation and no "
               "%LR is emitted, so J1.2's 90-degree land is fabricated "
               "axis-aligned. KiCad and DRC both keep the 90. Fix belongs in "
               "pcb_worker/gerber.py (emit a rotated macro, or an %LR, for a "
               "rotated oval land).",
        docket="unattributed"),
)
