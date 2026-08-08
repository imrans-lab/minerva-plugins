"""Pure geometric copper DRC over the ResolvedBoard IR (facet 2, Round C1).

Design of record: docket 019f952306f9 (parent 019f7abf7e7b), Codex-reviewed v2.
This is a NEW IR-native check that reads real copper/hole geometry — the exact
opposite of the legacy centerline connectivity checker (:mod:`drc`), which reads
pad centers + trace centerlines only and cannot verify a clearance. The two are
reported under distinct scopes; this one carries ``scope="geometric"`` and
``verifies_geometry=True``.

SAFETY INVARIANT — never a false ``clean``
------------------------------------------
A geometric DRC that reports ``clean`` on a board that is not is worse than
useless. Two rules enforce that here:

  1. FAIL-SAFE GEOMETRY. Every modeled copper/hole shape is exact or a superset
     of the real copper, so a computed margin never exceeds the true margin (see
     :mod:`drc_geom_primitives`). Spurious violations are acceptable; missed ones
     are not.
  2. FAIL-CLOSED ON THE UNMODELED. If the kernel meets geometry it cannot model
     (a non-rectangular board outline, a copper zone/pour, an un-shapeable pad
     land), it returns the INDETERMINATE envelope — ``ok=False``,
     ``verdict="indeterminate"``, NO ``clean``/``findings``/zero-counts a caller
     could mistake for a pass. ``ok`` means "the check RAN", not "the board
     passed".

CHECK SET (C1 per-entity + hole-to-hole; C2 pairwise clearance + edge):
  * GC1 min trace width      — every trace segment width  >= its EFFECTIVE width
                                floor (global min_trace_width_mm raised by that
                                trace's net class; see PER-NET-CLASS MINIMA).
  * GC2 copper clearance     — edge-to-edge distance between every pair of copper
                                primitives on the SAME canonical layer >= that
                                PAIR's EFFECTIVE clearance floor (global
                                min_clearance_mm raised by EITHER participant's net
                                class; same-net exempt only when both carry the same
                                NON-NULL net_id). [C2]
  * GC3 drill / finished hole — every drill feature minor  >= min_drill_mm;
                                plated holes also          >= min_finished_hole_mm.
  * GC4 annular ring          — PTH pads + vias + plated board holes: copper web
                                from drill boundary to land boundary
                                >= min_annular_ring_mm.
  * GC5 copper-to-edge       — every copper primitive's inset from the RectOutline
                                boundary >= copper_to_edge_mm (copper outside the
                                outline is a violation). [C2]
  * GC6 hole-to-hole          — edge-to-edge between all drill/hole features
                                >= min_hole_to_hole_mm.

LAYER NORMALIZATION (C2) — the copper stack ids are ``top``/``bottom`` but
PlacedPad.layers carry KiCad ``F.Cu``/``B.Cu``; GC2 folds both onto one canonical
per-layer key via the single existing ``agent_router.layers.kicad_to_canon`` map
(``_canon_layer``), never a second table, so same-physical-layer pairing is exact.

NPTH (C2) — an ``np_thru_hole`` pad has no copper land/ring; it projects a
HOLE/drill primitive (GC3/GC6) but NO copper primitive (no GC2/GC4/GC5).

DRY — the copper LAND owner
---------------------------
The copper-land shape of a through-hole pad is NOT reinterpreted here. It comes
from the SAME neutral owner the CAM emitters use — ``pad_source.placed_pad_to_geom``
+ ``pad_source.th_land`` — so fabricated copper (CAM) and checked copper (DRC)
cannot drift (docket finding 019f8b7fd295, mandated by Codex #3). See
``_pad_land`` for the call site.

PER-NET-CLASS MINIMA (GC1/GC2)
------------------------------
``ManufacturingConstraints`` carries the board's BLANKET floors, but a net may
belong to a ``NetClass`` that names a STRICTER ``min_trace_width_mm`` /
``min_clearance_mm``. Reading only the global floors would certify a net whose
own class forbids its geometry — a false clean. GC1 therefore compares each trace
against ``_effective_min_trace_width`` and GC2 compares each PAIR against
``_effective_min_clearance``, both built from ``_net_class_minima``. Consequences
worth stating once:

  * The clearance floor is per PAIR, not per primitive: the two participants can
    sit on different nets with different classes, so BOTH class terms fold in.
  * Copper with no net (``net_id is None`` — e.g. plated board-hole copper)
    contributes no class term; the other participant's class still applies.
  * The class floors only ever RAISE a floor (``max``), never relax one, so the
    global manufacturing minimum stays a hard lower bound.
  * ``_broad_phase_pairs`` must be given the MAXIMUM clearance floor on the board,
    not the global one — see its docstring for why.
  * Only the ``min_``-prefixed pair is read. ``NetClass.trace_width_mm``,
    ``via_diameter_mm`` and ``via_drill_mm`` are NOMINAL routing/via sizes, not
    minima; they imply no per-class GC1/GC3/GC4 floor, exactly as
    ``methods._net_class_overrides`` reads the same two fields and no others.

HOLE-SIZE SEMANTICS (GC3)
-------------------------
The ResolvedBoard hole/drill scalar is the DRILL diameter (the tool size, pre-
plating) — the value both CAM emitters send to Excellon. ``min_drill_mm`` is a
tool-availability floor and applies to EVERY drilled feature. ``min_finished_hole_mm``
is the plated (finished) hole floor and applies to PLATED features only. The IR
carries no plating thickness, so the finished bore cannot be derived; we compare
the drill diameter against ``min_finished_hole_mm`` as a NECESSARY condition
(finished <= drill, so drill < min_finished always fails). A plated hole whose
drill clears the floor but whose post-plating bore would dip below it is not
detectable from IR data alone and is left to DFM (facet 3) — documented, not
silently claimed clean.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

from agent_router.layers import kicad_to_canon

from .drc_geom_primitives import (
    AABB,
    EPS,
    Capsule,
    OrientedRect,
    aabb_union,
    capsule_edge_distance,
    capsule_edge_witness,
    convex_edge_distance,
    convex_edge_witness,
    point_segment_distance,
    segment_segment_distance,
)
from .ir_pads import (
    IRPad,
    LandDisc,
    UnsupportedGeometry,
    iter_ir_pads,
    pad_land,
    smd_shape,
)
from .ir_projection import cutout_point_loops, outline_frame, profile_outer_rect
from .resolved_board import (
    Diagnostic,
    LayerRole,
    OvalHole,
    ProfileOutline,
    RectOutline,
    ResolutionFailure,
    ResolutionResult,
    ResolutionSuccess,
    ResolvedBoard,
    RoundHole,
    SlotHole,
    ZoneKind,
)

# EPS (threshold slack) is imported from drc_geom_primitives — ONE shared boundary
# policy for the whole engine, not a duplicated literal.


# UnsupportedGeometry, LandDisc and the pad-land/SMD shape builders moved to the
# neutral :mod:`ir_pads` owner in Round E (019f783860c8) so canonical ROUTING
# shapes its keepouts with the identical code — checked, routed and fabricated
# copper cannot drift. Re-exported here: `drc_geometric.UnsupportedGeometry` and
# `drc_geometric.LandDisc` remain valid names for existing callers and tests.
__all__ = ["UnsupportedGeometry", "LandDisc", "run_geometric_drc",
           "geometric_drc_from_resolution", "geometric_indeterminate",
           "project_board", "Projection"]


# ---------------------------------------------------------------------------
# Normalised primitive projection.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CopperPrimitive:
    """One copper feature, flattened out of the IR for the (C2) clearance/edge
    checks. C1 consumes only the trace-segment members (GC1); the rest are carried
    so the projection is complete and C2 needs no re-projection."""

    entity_id: str
    parent_id: str | None
    kind: str                      # smd_pad|pth_pad|via|trace_seg|board_hole_copper
    layers: tuple[str, ...]        # participating copper-layer ids
    net_id: str | None
    shape: Any                     # Capsule | OrientedRect
    aabb: AABB
    width_mm: float | None = None  # trace width (GC1); None for non-trace copper
    # HUMAN SOURCE ATTRIBUTION (019f9589ebb3) — added ALONGSIDE the stable hashed
    # ids above so MCP/UI/LLM consumers can name "U1.1" / net "GND" without
    # rebuilding private IR lookup tables. None where a field does not apply
    # (a trace/via has no ref/pad; an unassigned-net primitive has no net_name).
    ref: str | None = None         # component ref (pads) — ResolvedComponent.ref
    pad_number: str | None = None  # pad number (pads) — footprint source_id
    net_name: str | None = None    # net name — ResolvedNet.name


@dataclass(frozen=True)
class HolePrimitive:
    """A drilled feature (pad drill, via drill, or board hole) as one or more
    capsules (a round hole is a single degenerate/disc capsule; an oval is one
    stadium capsule; a slot is one capsule per path leg). ``minor_mm`` is the
    limiting (minor) bore dimension for GC3."""

    entity_id: str
    parent_id: str | None
    origin: str                    # pad|via|board_hole
    net_id: str | None
    plated: bool
    capsules: tuple[Capsule, ...]
    minor_mm: float
    position: tuple[float, float]
    aabb: AABB
    # HUMAN SOURCE ATTRIBUTION (019f9589ebb3) — see CopperPrimitive.
    ref: str | None = None         # component ref (pad-origin holes)
    pad_number: str | None = None  # pad number (pad-origin holes)
    net_name: str | None = None    # net name where the hole carries a net


@dataclass(frozen=True)
class DrillDisc:
    kind: str                      # round|oblong
    dia_mm: float | None = None
    major_mm: float | None = None
    minor_mm: float | None = None

    def max_reach(self) -> float:
        """Largest reach from the drill centre to its boundary. For a round drill,
        the radius; for an oblong drill, half its MAJOR axis. Using the MAX reach
        (paired with the land's MIN reach) makes the annular web an UNDER-estimate
        — the fail-safe direction (never over-states the ring)."""
        if self.kind == "round":
            return (self.dia_mm or 0.0) / 2.0
        return (self.major_mm or 0.0) / 2.0


@dataclass(frozen=True)
class AnnularEntity:
    """A drilled feature that carries a copper land — PTH pad, via, or plated
    board hole — for GC4. Carries the land PER participating copper layer (a via
    padstack may differ per layer) and the single drill."""

    entity_id: str
    parent_id: str | None
    kind: str                      # pth_pad|via|board_hole_copper
    net_id: str | None
    per_layer: tuple[tuple[str, LandDisc], ...]
    drill: DrillDisc
    position: tuple[float, float]
    # HUMAN SOURCE ATTRIBUTION (019f9589ebb3) — see CopperPrimitive.
    ref: str | None = None         # component ref (PTH pads)
    pad_number: str | None = None  # pad number (PTH pads)
    net_name: str | None = None    # net name where the entity carries a net


@dataclass(frozen=True)
class Projection:
    copper: tuple[CopperPrimitive, ...]
    holes: tuple[HolePrimitive, ...]
    annular: tuple[AnnularEntity, ...]


def _copper_layer_ids(rb: ResolvedBoard) -> tuple[str, ...]:
    return tuple(layer.id for layer in rb.layer_stack.copper)


def _drill_disc_from_size(size: tuple[float, float]) -> DrillDisc:
    dx, dy = float(size[0]), float(size[1])
    if abs(dx - dy) <= EPS:
        return DrillDisc(kind="round", dia_mm=dx)
    return DrillDisc(kind="oblong", major_mm=max(dx, dy), minor_mm=min(dx, dy))


def _via_span_layers(rb: ResolvedBoard, via) -> tuple[str, ...]:
    idx = {layer.id: layer.stack_index for layer in rb.layer_stack.copper}
    lo, hi = idx.get(via.from_layer), idx.get(via.to_layer)
    if lo is None or hi is None:
        return _copper_layer_ids(rb)
    lo, hi = min(lo, hi), max(lo, hi)
    return tuple(layer.id for layer in rb.layer_stack.copper
                 if lo <= layer.stack_index <= hi)


def project_board(rb: ResolvedBoard) -> Projection:
    """Flatten the ResolvedBoard into copper primitives, hole primitives, and
    annular entities. Reuses the neutral pad-land owner for every pad copper shape
    (DRY). Raises :class:`UnsupportedGeometry` on anything it cannot model."""
    copper: list[CopperPrimitive] = []
    holes: list[HolePrimitive] = []
    annular: list[AnnularEntity] = []
    all_copper = _copper_layer_ids(rb)
    # Human net-name lookup (019f9589ebb3): the stable hashed net_id -> the
    # authored ResolvedNet.name, so findings can name the net ("GND") without a
    # consumer rebuilding this private table.
    net_names = {net.id: net.name for net in rb.nets}

    # Pads, their human numbers and net names come from the NEUTRAL owner
    # (ir_pads.iter_ir_pads) — the same iteration canonical routing walks, so a
    # pad DRC checks and a pad the router keeps out of are the same pad
    # (019f9589ebb3 attribution, Round E 019f783860c8 DRY).
    for ir_pad in iter_ir_pads(rb):
        pad, comp = ir_pad.pad, ir_pad.component
        number, human_pad = ir_pad.source_number, ir_pad.number
        pad_net_name = ir_pad.net_name
        # A pad participates on the copper layers flagged in pad.layers; a
        # through-hole pad spans ALL copper layers regardless.
        pad_copper = tuple(
            layer.id for layer in pad.layers if layer.role is LayerRole.COPPER)
        if ir_pad.is_drilled:
            layers = all_copper
            # NPTH prerequisite (C2): an np_thru_hole pad has NO copper land/ring
            # — it is a bare mechanical hole. It contributes a HOLE/drill primitive
            # (GC3/GC6) but MUST NOT project a copper primitive (which would cause
            # spurious GC2/GC5 positives) nor an annular entity (GC4). The
            # classification lives on IRPad.carries_copper, so DRC and routing
            # agree on what a bare hole is.
            if ir_pad.carries_copper:
                land, shape = pad_land(pad, number, comp.ref)
                copper.append(CopperPrimitive(
                    entity_id=pad.id, parent_id=comp.id, kind="pth_pad",
                    layers=layers, net_id=pad.net_id, shape=shape,
                    aabb=_shape_aabb(shape),
                    ref=comp.ref, pad_number=human_pad, net_name=pad_net_name))
            drill = _drill_disc_from_size(pad.drill.size)
            holes.append(_hole_from_drill(
                pad.id, comp.id, "pad", pad.net_id, pad.drill.plated,
                pad.position, drill, pad.rotation_deg,
                ref=comp.ref, pad_number=human_pad, net_name=pad_net_name))
            # Annular ring: PLATED through-hole pads only.
            if ir_pad.carries_copper:
                annular.append(AnnularEntity(
                    entity_id=pad.id, parent_id=comp.id, kind="pth_pad",
                    net_id=pad.net_id,
                    per_layer=tuple((lid, land) for lid in layers),
                    drill=drill, position=pad.position,
                    ref=comp.ref, pad_number=human_pad, net_name=pad_net_name))
        else:
            shape = smd_shape(pad, number, comp.ref)
            copper.append(CopperPrimitive(
                entity_id=pad.id, parent_id=comp.id, kind="smd_pad",
                layers=pad_copper or all_copper[:1], net_id=pad.net_id,
                shape=shape, aabb=_shape_aabb(shape),
                ref=comp.ref, pad_number=human_pad, net_name=pad_net_name))

    for trace in rb.traces:
        trace_net_name = net_names.get(trace.net_id)
        for seg in trace.segments:
            cap = Capsule(seg.a[0], seg.a[1], seg.b[0], seg.b[1], seg.width_mm / 2.0)
            copper.append(CopperPrimitive(
                entity_id=seg.id, parent_id=trace.id, kind="trace_seg",
                layers=(seg.layer.id,), net_id=trace.net_id, shape=cap,
                aabb=cap.aabb(), width_mm=seg.width_mm, net_name=trace_net_name))

    for via in rb.vias:
        via_net_name = net_names.get(via.net_id)
        span = _via_span_layers(rb, via)
        cap = Capsule.disc(via.position[0], via.position[1], via.diameter_mm / 2.0)
        copper.append(CopperPrimitive(
            entity_id=via.id, parent_id=None, kind="via", layers=span,
            net_id=via.net_id, shape=cap, aabb=cap.aabb(), net_name=via_net_name))
        drill = DrillDisc(kind="round", dia_mm=via.drill_mm)
        holes.append(_hole_from_drill(
            via.id, None, "via", via.net_id, True, via.position, drill, 0.0,
            net_name=via_net_name))
        # Per-layer padstack land when present, else the via diameter on each
        # participating copper layer.
        per_layer = _via_per_layer_lands(via, span)
        annular.append(AnnularEntity(
            entity_id=via.id, parent_id=None, kind="via", net_id=via.net_id,
            per_layer=per_layer, drill=drill, position=via.position,
            net_name=via_net_name))

    for hole in rb.holes:
        cap_list, minor, pos = _hole_capsules(hole)
        holes.append(HolePrimitive(
            entity_id=hole.id, parent_id=None, origin="board_hole",
            net_id=None, plated=hole.plated, capsules=cap_list, minor_mm=minor,
            position=pos, aabb=aabb_union([c.aabb() for c in cap_list])))
        if hole.plated and hole.annulus_mm is not None:
            # Plated board hole copper is a round annulus (LAND diameter) on all
            # copper layers; the drill is the round bore. Only RoundHole board holes
            # currently carry an annulus in the IR.
            if not isinstance(hole.feature, RoundHole):
                raise UnsupportedGeometry(
                    f"board hole {hole.id}: plated non-round board holes are not "
                    f"modeled for annular checking")
            land = LandDisc(kind="round", dia_mm=hole.annulus_mm)
            copper.append(CopperPrimitive(
                entity_id=hole.id, parent_id=None, kind="board_hole_copper",
                layers=all_copper, net_id=None,
                shape=Capsule.disc(pos[0], pos[1], hole.annulus_mm / 2.0),
                aabb=AABB(pos[0] - hole.annulus_mm / 2, pos[1] - hole.annulus_mm / 2,
                          pos[0] + hole.annulus_mm / 2, pos[1] + hole.annulus_mm / 2)))
            annular.append(AnnularEntity(
                entity_id=hole.id, parent_id=None, kind="board_hole_copper",
                net_id=None,
                per_layer=tuple((lid, land) for lid in all_copper),
                drill=DrillDisc(kind="round", dia_mm=hole.feature.diameter_mm),
                position=pos))

    return Projection(tuple(copper), tuple(holes), tuple(annular))


def _shape_aabb(shape: Any) -> AABB:
    return shape.aabb()


def _via_per_layer_lands(via, span: tuple[str, ...]) -> tuple[tuple[str, LandDisc], ...]:
    if via.padstack is not None:
        by_layer = {lp.layer_id: lp for lp in via.padstack.per_layer}
        out = []
        for lid in span:
            lp = by_layer.get(lid)
            dia = lp.diameter_mm if lp is not None else via.diameter_mm
            out.append((lid, LandDisc(kind="round", dia_mm=dia)))
        return tuple(out)
    return tuple((lid, LandDisc(kind="round", dia_mm=via.diameter_mm)) for lid in span)


def _hole_from_drill(entity_id: str, parent_id: str | None, origin: str,
                     net_id: str | None, plated: bool,
                     position: tuple[float, float], drill: DrillDisc,
                     rotation_deg: float, *,
                     ref: str | None = None, pad_number: str | None = None,
                     net_name: str | None = None) -> HolePrimitive:
    if drill.kind == "round":
        r = (drill.dia_mm or 0.0) / 2.0
        cap = Capsule.disc(position[0], position[1], r)
        minor = drill.dia_mm or 0.0
    else:
        # Oblong drill: model as the stadium along the pad's major axis. The minor
        # axis governs GC3; the segment length is (major - minor). Orientation is
        # not carried on the pad DrillDefinition, so we align with the pad rotation
        # and, being unsure which local axis is major, over-approximate the GC6
        # envelope by a disc of the MAJOR radius (superset -> fail-safe) while
        # keeping the exact minor for GC3.
        minor = drill.minor_mm or 0.0
        cap = Capsule.disc(position[0], position[1], (drill.major_mm or 0.0) / 2.0)
    return HolePrimitive(
        entity_id=entity_id, parent_id=parent_id, origin=origin, net_id=net_id,
        plated=plated, capsules=(cap,), minor_mm=minor, position=position,
        aabb=cap.aabb(), ref=ref, pad_number=pad_number, net_name=net_name)


def _hole_capsules(hole) -> tuple[tuple[Capsule, ...], float, tuple[float, float]]:
    feat = hole.feature
    if isinstance(feat, RoundHole):
        r = feat.diameter_mm / 2.0
        return ((Capsule.disc(feat.position[0], feat.position[1], r),),
                feat.diameter_mm, feat.position)
    if isinstance(feat, OvalHole):
        w, h = feat.width_mm, feat.height_mm
        minor = min(w, h)
        major = max(w, h)
        r = minor / 2.0
        half = (major - minor) / 2.0
        # Segment along the oval's major axis, rotated by rotation_deg. When
        # width>=height the major axis is local-x; otherwise local-y.
        angle = math.radians(feat.rotation_deg) + (0.0 if w >= h else math.pi / 2.0)
        dx, dy = half * math.cos(angle), half * math.sin(angle)
        cx, cy = feat.position
        cap = Capsule(cx - dx, cy - dy, cx + dx, cy + dy, r)
        return ((cap,), minor, feat.position)
    if isinstance(feat, SlotHole):
        r = feat.width_mm / 2.0
        caps = tuple(
            Capsule(a[0], a[1], b[0], b[1], r)
            for a, b in zip(feat.path, feat.path[1:]))
        return (caps, feat.width_mm, feat.path[0])
    raise UnsupportedGeometry(f"hole {hole.id}: unsupported hole feature "
                              f"{type(feat).__name__}")


# ---------------------------------------------------------------------------
# The C1 checks.
# ---------------------------------------------------------------------------


def _violates(measured: float, required: float) -> bool:
    """Threshold predicate. A measurement AT (or within EPS of) the floor PASSES;
    a violation is a measurement short of the floor by more than float noise."""
    return measured < required - EPS


def _net_class_minima(rb: ResolvedBoard) -> dict[str, tuple[float | None, float | None]]:
    """``net_id -> (class min_trace_width_mm, class min_clearance_mm)`` for every net
    that REFERENCES a net class naming at least one of them. This is the net->class
    map the projection does not build (``project_board`` builds only the net->NAME
    map for finding attribution), and the single source of the per-net terms GC1/GC2
    raise the global minima by.

    THE SAME TWO FIELDS ROUTING READS. ``methods._net_class_overrides`` reads exactly
    ``NetClass.min_trace_width_mm`` / ``.min_clearance_mm`` and deliberately ignores
    the plain nominal ``NetClass.trace_width_mm``; so does this, so the routed width
    and the checked width floor are sourced from one rule. Routing keys its map by net
    NAME (the router speaks names); this keys by ``net_id``, because that is the
    identity a projected :class:`CopperPrimitive` carries.

    Only REFERENCED classes are read, again as routing does: a class sitting on
    ``design_rules.net_classes`` that no net points at constrains no copper.

    A dimension the class says NOTHING about stays ``None`` and contributes no term —
    that net falls through to the global floor for THAT dimension exactly as if it
    carried no class at all.

    AN UNSOURCEABLE MINIMUM FAILS CLOSED, in BOTH dimensions, through the SAME
    predicate routing uses for that dimension. Routing admits a class width through
    ``ir_candidates.positive_mm`` and a class clearance through
    ``agent_router.router.nonnegative_mm``, and raises ``UnsupportedGeometry`` on
    either miss. Geometric DRC reads the SAME two fields off the SAME class, so it
    must not reach a different conclusion about the same value: it calls those same
    two functions and raises the same way, naming the class id and the field (the
    kernel maps that to the INDETERMINATE envelope).

    What differs between the two dimensions is the PREDICATE, not the fail-closed-ness.
    Zero-width copper is not copper, so ``min_trace_width_mm: 0.0`` is rejected;
    ``0.0`` clearance is a rule a class may legitimately state, so
    ``min_clearance_mm: 0.0`` is ADMITTED and is then a no-op under ``max``. That one
    VALUE is the whole of the difference — every other unsourceable clearance
    (negative, NaN, infinite, non-numeric) fails closed exactly as an unsourceable
    width does. There are TWO fail-closed cases here, not one. That is exactly the
    split routing draws, drawn here from the same two functions.

    ``NetClass`` fields are validated with ``resolved_board._nonnegative`` (which is
    ``_finite`` plus ``>= 0``), so on a valid IR NEITHER predicate can currently fail
    except on an exact ``min_trace_width_mm`` of ``0.0``. Both are applied anyway, and
    for the same reason: if that validation is ever relaxed, a NaN clearance must not
    raise in routing while silently no-opping here (``max(0.2, nan)`` returns ``0.2``
    — a false clean). An unreachable path is not a reason to omit the predicate; it is
    the reason the predicate is the only thing keeping the two surfaces aligned.

    WHY THIS IS NOT SHARED WITH ``methods._net_class_overrides``, which it closely
    resembles (same class dict, same loop shape, same defensive ``nc is None``, the
    same two predicates, near-identical messages). The duplication is known and was
    left deliberately for now: the two live in different modules, key their results by
    different identities (``net.id`` here because that is what a
    :class:`CopperPrimitive` carries; ``net.name`` there because the router speaks
    names), and ``methods`` already imports :mod:`drc_geometric`, so factoring the
    shared body out would need a THIRD module rather than one function moving. That
    extraction is filed separately — do not re-derive this, and do not "fix" it by
    importing across the two.
    """
    # These are the SAME two predicates routing admits the same two fields through —
    # ``methods._nonnegative_mm`` is a one-line delegate to
    # ``engine_router.nonnegative_mm``, so this reaches the identical implementation
    # rather than a second copy of the rule.
    #
    # ``ir_candidates`` is imported LOCALLY because it imports THIS module at module
    # level; a top-level import would be circular. ``agent_router.router`` has no such
    # excuse and costs nothing either way — this module already imports
    # ``agent_router.layers``, and ``agent_router/__init__`` does
    # ``from .router import (...)``, so ``agent_router.router`` is in ``sys.modules``
    # before this function ever runs. It is local purely to sit beside its sibling
    # (``methods`` imports the engine the same way, for the same non-reason).
    from agent_router.router import nonnegative_mm

    from .ir_candidates import positive_mm

    classes = {nc.id: nc for nc in rb.design_rules.net_classes}
    minima: dict[str, tuple[float | None, float | None]] = {}
    for net in rb.nets:
        if not net.net_class_id:
            continue
        nc = classes.get(net.net_class_id)
        if nc is None:
            # Unreachable on a valid ResolvedBoard — its __post_init__ raises
            # "ResolvedNet references an unknown net class" at construction. Defensive
            # only; no behaviour is invented for a board that cannot exist.
            continue
        width = None
        if nc.min_trace_width_mm is not None:
            width = positive_mm(nc.min_trace_width_mm)
            if width is None:
                raise UnsupportedGeometry(
                    f"net {net.name!r} belongs to net class {nc.id!r} whose "
                    f"min_trace_width_mm={nc.min_trace_width_mm!r} is not a "
                    f"positive, finite width in mm — geometric DRC fails closed "
                    f"rather than reinterpret the class's own rule")
        clearance = None
        if nc.min_clearance_mm is not None:
            clearance = nonnegative_mm(nc.min_clearance_mm)
            if clearance is None:
                raise UnsupportedGeometry(
                    f"net {net.name!r} belongs to net class {nc.id!r} whose "
                    f"min_clearance_mm={nc.min_clearance_mm!r} is not a "
                    f"non-negative, finite clearance in mm — geometric DRC fails "
                    f"closed rather than reinterpret the class's own rule")
        if width is not None or clearance is not None:
            minima[net.id] = (width, clearance)
    return minima


def _effective_min_trace_width(global_min: float,
                               minima: dict[str, tuple[float | None, float | None]],
                               net_id: str | None) -> float:
    """The width floor copper on *net_id* must actually meet: the board's global
    ``min_trace_width_mm`` RAISED by that net's class minimum when its class names
    one. Net-less copper (``net_id is None``) carries no class and no class term."""
    entry = minima.get(net_id) if net_id is not None else None
    if entry is None or entry[0] is None:
        return global_min
    return max(global_min, entry[0])


def _effective_min_clearance(global_min: float,
                             minima: dict[str, tuple[float | None, float | None]],
                             *net_ids: str | None) -> float:
    """The clearance floor a set of participating nets must actually meet: the board's
    global ``min_clearance_mm`` RAISED by EVERY named net's class minimum. Called with
    a PAIR's two nets for the GC2 comparison (either participant's class can tighten
    the pair), and with every classed net at once to obtain the board-wide MAXIMUM the
    broad phase must sweep at. A ``None`` net contributes nothing."""
    floor = global_min
    for net_id in net_ids:
        entry = minima.get(net_id) if net_id is not None else None
        if entry is not None and entry[1] is not None:
            floor = max(floor, entry[1])
    return floor


def _check_gc1_trace_width(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    global_min = rb.design_rules.minimums.min_trace_width_mm
    minima = _net_class_minima(rb)
    findings: list[dict] = []
    for prim in proj.copper:
        if prim.kind != "trace_seg" or prim.width_mm is None:
            continue
        # PER-TRACE floor: the global minimum raised by this trace's own net class.
        # Comparing every trace against the global floor alone would clean a trace its
        # own class forbids (019f958b45b9). The finding reports the EFFECTIVE value.
        required = _effective_min_trace_width(global_min, minima, prim.net_id)
        if _violates(prim.width_mm, required):
            shape = prim.shape
            mid = ((shape.ax + shape.bx) / 2.0, (shape.ay + shape.by) / 2.0)
            findings.append(_finding(
                "gc1_trace_width", prim.entity_id, prim.parent_id, prim.kind,
                prim.net_id, prim.layers[0] if prim.layers else None,
                prim.width_mm, required,
                closest=[shape.ax, shape.ay], witness=[shape.bx, shape.by],
                midpoint=list(mid),
                ref=prim.ref, pad=prim.pad_number, net_name=prim.net_name))
    return findings


def _check_gc3_drill(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    mins = rb.design_rules.minimums
    findings: list[dict] = []
    for hole in proj.holes:
        # min_drill_mm — the tool floor — applies to every drilled feature.
        if _violates(hole.minor_mm, mins.min_drill_mm):
            findings.append(_finding(
                "gc3_drill", hole.entity_id, hole.parent_id, hole.origin,
                hole.net_id, None, hole.minor_mm, mins.min_drill_mm,
                closest=list(hole.position), witness=list(hole.position),
                ref=hole.ref, pad=hole.pad_number, net_name=hole.net_name))
        # min_finished_hole_mm — plated (finished) hole floor — plated only.
        elif hole.plated and _violates(hole.minor_mm, mins.min_finished_hole_mm):
            findings.append(_finding(
                "gc3_finished_hole", hole.entity_id, hole.parent_id, hole.origin,
                hole.net_id, None, hole.minor_mm, mins.min_finished_hole_mm,
                closest=list(hole.position), witness=list(hole.position),
                ref=hole.ref, pad=hole.pad_number, net_name=hole.net_name))
    return findings


def _check_gc4_annular(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    required = rb.design_rules.minimums.min_annular_ring_mm
    findings: list[dict] = []
    for ent in proj.annular:
        drill_reach = ent.drill.max_reach()
        for layer_id, land in ent.per_layer:
            web = land.min_reach() - drill_reach
            if _violates(web, required):
                findings.append(_finding(
                    "gc4_annular_ring", ent.entity_id, ent.parent_id, ent.kind,
                    ent.net_id, layer_id, web, required,
                    closest=list(ent.position), witness=list(ent.position),
                    ref=ent.ref, pad=ent.pad_number, net_name=ent.net_name))
    return findings


def _check_gc6_hole_to_hole(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    required = rb.design_rules.minimums.min_hole_to_hole_mm
    findings: list[dict] = []
    # Naive all-pairs is acceptable for C1 (few holes); deterministic ordering by
    # entity_id. The deterministic per-layer broad phase is C2.
    ordered = sorted(proj.holes, key=lambda h: h.entity_id)
    n = len(ordered)
    for i in range(n):
        for j in range(i + 1, n):
            h1, h2 = ordered[i], ordered[j]
            best = math.inf
            witness = None
            for c1 in h1.capsules:
                for c2 in h2.capsules:
                    d = capsule_edge_distance(c1, c2)
                    if d < best:
                        best = d
                        witness = capsule_edge_witness(c1, c2)
            if _violates(best, required):
                w1, w2 = witness if witness else (h1.position, h2.position)
                mid = ((w1[0] + w2[0]) / 2.0, (w1[1] + w2[1]) / 2.0)
                findings.append(_finding(
                    "gc6_hole_to_hole", f"{h1.entity_id}|{h2.entity_id}", None,
                    "hole_pair", None, None, best, required,
                    closest=list(w1), witness=list(w2), midpoint=list(mid),
                    extra={"entities": [h1.entity_id, h2.entity_id],
                           "origins": [h1.origin, h2.origin],
                           "participants": [
                               {"entity_id": h1.entity_id, "origin": h1.origin,
                                "ref": h1.ref, "pad": h1.pad_number,
                                "net_name": h1.net_name},
                               {"entity_id": h2.entity_id, "origin": h2.origin,
                                "ref": h2.ref, "pad": h2.pad_number,
                                "net_name": h2.net_name}]}))
    return findings


# ---------------------------------------------------------------------------
# GC2 / GC5 (C2) — pairwise clearance + copper-to-edge, with a broad phase.
# ---------------------------------------------------------------------------


def _canon_layer(layer_id: str) -> str:
    """Fold both layer namespaces onto ONE canonical per-layer key. Copper stack ids
    are ``top``/``bottom`` (agent_router.layers.STACK_INDEX) but PlacedPad.layers
    carry KiCad ids (``F.Cu``/``B.Cu``). GC2 must pair copper on the SAME PHYSICAL
    layer, so every layer id is normalized through the ONE existing worker-side
    mapping (:func:`agent_router.layers.kicad_to_canon`) rather than a second
    hand-rolled table — ``F.Cu``->``top``, ``top``->``top`` (idempotent)."""
    return kicad_to_canon(layer_id)


def _bucket_copper_by_layer(proj: Projection,
                            known_canon: frozenset[str]) -> dict[str, list[CopperPrimitive]]:
    """Bucket copper primitives per CANONICAL layer (both namespaces folded). A pad
    or via that spans several copper layers appears in each of its layers' buckets.

    FAIL-CLOSED: a copper primitive whose layer does NOT fold to one of the board's
    known copper layers (``known_canon``, derived from the stack) is UNMODELED. It
    would otherwise land in its own singleton bucket and be silently un-paired —
    uncompared copper is a potential missed short, i.e. a false clean. Raise
    UnsupportedGeometry so the kernel returns indeterminate instead. Unreachable on
    today's 2-layer boards (F.Cu/B.Cu both fold to top/bottom); this guards the
    N-layer / mixed-namespace future (Fable C2 review note a)."""
    buckets: dict[str, list[CopperPrimitive]] = {}
    for prim in proj.copper:
        for lid in prim.layers:
            canon = _canon_layer(lid)
            if canon not in known_canon:
                raise UnsupportedGeometry(
                    f"copper {prim.entity_id!r} is on layer {lid!r} (canonical "
                    f"{canon!r}), not a known board copper layer {sorted(known_canon)}")
            buckets.setdefault(canon, []).append(prim)
    return buckets


def _broad_phase_pairs(prims: list[CopperPrimitive],
                       margin: float) -> list[tuple[int, int]]:
    """Per-layer AABB broad phase — a deterministic sort-and-sweep on x that yields
    only candidate index pairs whose clearance-inflated AABBs overlap, so the exact
    (O(k^2)) narrow phase runs on a small candidate set instead of all board pairs.

    CALLER INVARIANT — ``margin`` MUST BE THE MAXIMUM REQUIRED CLEARANCE ANYWHERE IN
    ``prims``, not any one pair's threshold. The pruning argument below is only sound
    against the LARGEST threshold a surviving pair could be compared to; hand this the
    board's global ``min_clearance_mm`` while some pair's net class demands more and
    that pair is dropped before it is ever measured — a FALSE CLEAN. The single caller
    (:func:`_check_gc2_clearance`) folds every net class's ``min_clearance_mm`` into
    the margin via :func:`_effective_min_clearance` for exactly this reason.

    CORRECTNESS-EQUIVALENT TO ALL-PAIRS: it only prunes pairs that PROVABLY cannot
    violate. If two shapes have edge distance < ``margin`` (>= every pair's required
    clearance, per the invariant above) their AABBs are < margin apart, so inflating
    EACH box by ``margin`` (done here on both the x-sweep and the y-overlap test)
    leaves them overlapping — such a pair is never dropped. Pruned pairs are strictly
    farther apart than any clearance floor on the board, so the narrow phase would
    have cleared them anyway. Note a pair is only pruned once its gap exceeds
    2 x ``margin``, since BOTH boxes are inflated.

    Deterministic: primitives are swept in (inflated min_x, entity_id) order and
    every emitted pair is returned as ``(i, j)`` with ``i < j`` (indices into the
    input list), so downstream findings are stable regardless of input order."""
    n = len(prims)
    order = sorted(range(n),
                   key=lambda k: (prims[k].aabb.min_x - margin, prims[k].entity_id))
    pairs: list[tuple[int, int]] = []
    active: list[tuple[float, int]] = []  # (inflated max_x, index)
    for oi in order:
        box = prims[oi].aabb
        lo_x = box.min_x - margin
        hi_x = box.max_x + margin
        lo_y = box.min_y - margin
        hi_y = box.max_y + margin
        active = [a for a in active if a[0] >= lo_x - EPS]
        for _a_hi, aj in active:
            b2 = prims[aj].aabb
            # x already overlaps (sweep invariant); test inflated y overlap.
            if (b2.min_y - margin) <= hi_y + EPS and lo_y <= (b2.max_y + margin) + EPS:
                pairs.append((aj, oi) if aj < oi else (oi, aj))
        active.append((hi_x, oi))
    return pairs


def _same_net_exempt(a: CopperPrimitive, b: CopperPrimitive) -> bool:
    """The GC2 same-net exemption — EXACTLY "both carry the SAME NON-NULL net_id".
    Two unassigned (None) primitives, or None vs any net, are NOT a shared electrical
    net and MUST be checked. Same-trace adjacent segments are subsumed here (a trace
    always carries a non-null net, so two segments of one trace are same-net exempt);
    no broader same-net-across-different-traces exemption is added."""
    return a.net_id is not None and a.net_id == b.net_id


def _check_gc2_clearance(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    global_min = rb.design_rules.minimums.min_clearance_mm
    minima = _net_class_minima(rb)
    # BROAD-PHASE MARGIN — the board-wide MAXIMUM required clearance (the global floor
    # folded with EVERY classed net's floor), which is the invariant
    # :func:`_broad_phase_pairs` prunes against. Sweeping at the global floor while a
    # class demands more would prune a genuinely violating pair unmeasured.
    #
    # THE COST, STATED PLAINLY. This margin is BOARD-WIDE, so one high-clearance net
    # class inflates the sweep box of EVERY primitive on EVERY layer — including
    # primitives on nets that class will never be compared against — and GC2 degrades
    # toward all-pairs as the strictest class grows. That cost scales with the
    # STRICTEST class on the board, not with how many nets use it: a single net on a
    # 2mm-clearance class costs exactly what a thousand of them would. It is
    # nonetheless the right trade, because a per-pair bound is not knowable before
    # pairing — the sweep is what DECIDES which pairs exist, so it cannot be tuned by
    # the pair it has not formed yet. The alternative (sweep tighter, miss a pair) is
    # a false clean, and this kernel spends performance to avoid those every time.
    sweep_margin = _effective_min_clearance(global_min, minima, *minima)
    known = frozenset(_canon_layer(lid) for lid in _copper_layer_ids(rb))
    buckets = _bucket_copper_by_layer(proj, known)
    findings: list[dict] = []
    for layer_id in sorted(buckets):
        prims = buckets[layer_id]
        seen: set[tuple[str, str]] = set()
        for i, j in _broad_phase_pairs(prims, sweep_margin):
            a, b = prims[i], prims[j]
            if a.entity_id == b.entity_id:
                continue  # self-pair (a shape never conflicts with itself)
            lo, hi = (a, b) if a.entity_id <= b.entity_id else (b, a)
            if _same_net_exempt(lo, hi):
                continue
            key = (lo.entity_id, hi.entity_id)
            if key in seen:
                continue
            # PER-PAIR floor: the two participants can sit on different nets with
            # different classes, so BOTH class terms fold in (and a net-less
            # participant contributes none). The finding reports this effective value,
            # not the global one.
            required = _effective_min_clearance(
                global_min, minima, lo.net_id, hi.net_id)
            dist = convex_edge_distance(lo.shape, hi.shape)
            if _violates(dist, required):
                seen.add(key)
                w1, w2 = convex_edge_witness(lo.shape, hi.shape)
                mid = ((w1[0] + w2[0]) / 2.0, (w1[1] + w2[1]) / 2.0)
                findings.append(_finding(
                    "gc2_copper_clearance", f"{lo.entity_id}|{hi.entity_id}", None,
                    "copper_pair", None, layer_id, dist, required,
                    closest=list(w1), witness=list(w2), midpoint=list(mid),
                    extra={"participants": [
                        {"entity_id": lo.entity_id, "parent": lo.parent_id,
                         "kind": lo.kind, "net_id": lo.net_id,
                         "ref": lo.ref, "pad": lo.pad_number,
                         "net_name": lo.net_name},
                        {"entity_id": hi.entity_id, "parent": hi.parent_id,
                         "kind": hi.kind, "net_id": hi.net_id,
                         "ref": hi.ref, "pad": hi.pad_number,
                         "net_name": hi.net_name}]}))
    findings.sort(key=lambda f: (f["layer"], f["entity_id"]))
    return findings


def _point_in_loop(px: float, py: float, loop: list[tuple[float, float]]) -> bool:
    """Even-odd ray cast for an ARBITRARY (possibly concave) vertex loop —
    ``drc_geom_primitives._point_in_convex`` deliberately assumes convexity, and
    a cutout has no convexity guarantee."""
    inside = False
    count = len(loop)
    for index in range(count):
        x1, y1 = loop[index]
        x2, y2 = loop[(index + 1) % count]
        if (y1 > py) != (y2 > py):
            x_cross = x1 + (py - y1) * (x2 - x1) / (y2 - y1)
            if px < x_cross:
                inside = not inside
    return inside


def _aabb_loop_clearance(box, loop: list[tuple[float, float]]
                         ) -> tuple[float, tuple[float, float], tuple[float, float]]:
    """(measured, copper_point, loop_witness) between a copper AABB and a cutout
    vertex loop. Separated: exact min over (box edge x loop edge) pairs, witness
    on the closest loop edge. Overlapping (an edge crossing, a loop vertex inside
    the box, or the box swallowed by the loop): measured is the NEGATED deepest
    containment the vertex passes can prove, 0.0 for a pure edge graze —
    either way below any positive rule, so the violation still fires; the
    magnitude is witness quality, not the verdict."""
    corners = ((box.min_x, box.min_y), (box.max_x, box.min_y),
               (box.max_x, box.max_y), (box.min_x, box.max_y))
    box_edges = tuple((corners[i], corners[(i + 1) % 4]) for i in range(4))
    count = len(loop)
    loop_edges = tuple((loop[i], loop[(i + 1) % count]) for i in range(count))

    overlap_depth = 0.0
    overlapping = False
    for (lx, ly) in loop:
        if box.min_x <= lx <= box.max_x and box.min_y <= ly <= box.max_y:
            overlapping = True
            overlap_depth = max(overlap_depth,
                                min(lx - box.min_x, box.max_x - lx,
                                    ly - box.min_y, box.max_y - ly))
    for (cx, cy) in corners:
        if _point_in_loop(cx, cy, loop):
            overlapping = True
            overlap_depth = max(overlap_depth, min(
                point_segment_distance(cx, cy, a[0], a[1], b[0], b[1])
                for a, b in loop_edges))
    if not overlapping:
        for be in box_edges:
            for le in loop_edges:
                if segment_segment_distance(be[0], be[1], le[0], le[1]) == 0.0:
                    overlapping = True
                    break
            if overlapping:
                break

    centre = ((box.min_x + box.max_x) / 2.0, (box.min_y + box.max_y) / 2.0)
    best = None
    for a, b in loop_edges:
        d = min(segment_segment_distance(be[0], be[1], a, b) for be in box_edges)
        if best is None or d < best[0]:
            best = (d, a, b)
    d, a, b = best
    # Witness: the closest loop edge's nearest point to the box centre, and the
    # box boundary point clamped toward it — midpoint-quality anchors, the same
    # fidelity the outer-rim sides use.
    dx, dy = b[0] - a[0], b[1] - a[1]
    seg_len2 = dx * dx + dy * dy
    t = 0.0 if seg_len2 == 0 else max(0.0, min(1.0, (
        (centre[0] - a[0]) * dx + (centre[1] - a[1]) * dy) / seg_len2))
    witness = (a[0] + t * dx, a[1] + t * dy)
    cop_pt = (max(box.min_x, min(box.max_x, witness[0])),
              max(box.min_y, min(box.max_y, witness[1])))
    if overlapping:
        return -overlap_depth, cop_pt, witness
    return d, cop_pt, witness


def _check_gc5_copper_to_edge(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """Copper-to-board-edge clearance against the board rim AND every interior
    cutout. The rim is the rect frame (a non-rect rim is already indeterminate
    via the C1 guard). For a copper shape the inward clearance to each
    axis-aligned rim edge is EXACT from the shape's own extent (its AABB is the
    exact extent of a Capsule/OrientedRect), so the rim ``measured`` is the
    minimum of the four insets; copper OUTSIDE the outline yields a negative
    measured on the crossed side. A roundrect's bounding-rect AABB is a
    superset, so this only ever UNDER-states the inset — the fail-safe
    direction. Cutout edges reuse the same rule and the same code
    (``gc5_copper_to_edge`` — a slot edge IS a board edge to the router bit),
    measured as exact AABB-to-contour distance; the AABB superset understates
    here too, the same fail-safe direction."""
    required = rb.design_rules.minimums.copper_to_edge_mm
    ox, oy, width_mm, height_mm = outline_frame(rb.outline)
    ox2, oy2 = ox + width_mm, oy + height_mm
    cut_loops = cutout_point_loops(rb.outline)
    findings: list[dict] = []
    for prim in sorted(proj.copper, key=lambda p: p.entity_id):
        box = prim.aabb
        sides = (
            ("left", box.min_x - ox, (box.min_x, (box.min_y + box.max_y) / 2.0),
             (ox, (box.min_y + box.max_y) / 2.0)),
            ("right", ox2 - box.max_x, (box.max_x, (box.min_y + box.max_y) / 2.0),
             (ox2, (box.min_y + box.max_y) / 2.0)),
            ("bottom", box.min_y - oy, ((box.min_x + box.max_x) / 2.0, box.min_y),
             ((box.min_x + box.max_x) / 2.0, oy)),
            ("top", oy2 - box.max_y, ((box.min_x + box.max_x) / 2.0, box.max_y),
             ((box.min_x + box.max_x) / 2.0, oy2)),
        )
        _side, measured, cop_pt, edge_pt = min(sides, key=lambda s: s[1])
        if _violates(measured, required):
            layer = _canon_layer(prim.layers[0]) if prim.layers else None
            findings.append(_finding(
                "gc5_copper_to_edge", prim.entity_id, prim.parent_id, prim.kind,
                prim.net_id, layer, measured, required,
                closest=list(cop_pt), witness=list(edge_pt),
                ref=prim.ref, pad=prim.pad_number, net_name=prim.net_name))
        for cut_id, loop in cut_loops:
            cut_measured, cut_cop, cut_witness = _aabb_loop_clearance(box, loop)
            if _violates(cut_measured, required):
                layer = _canon_layer(prim.layers[0]) if prim.layers else None
                findings.append(_finding(
                    "gc5_copper_to_edge", prim.entity_id, prim.parent_id,
                    prim.kind, prim.net_id, layer, cut_measured, required,
                    closest=list(cut_cop), witness=list(cut_witness),
                    # Which edge: the rim finding above carries no extra; a
                    # cutout finding NAMES the cutout (the GC7
                    # against_entity_id pattern) — on a multi-cutout board the
                    # witness coordinates alone cannot say which slot
                    # (ResolvedCutout carries its id for exactly this).
                    extra={"against_entity_id": cut_id},
                    ref=prim.ref, pad=prim.pad_number, net_name=prim.net_name))
    return findings


# ---------------------------------------------------------------------------
# Result union.
# ---------------------------------------------------------------------------


def _check_gc7_zone_clearance(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """GC7 — POUR COPPER IS COPPER. Filled zone copper vs foreign-net copper.

    WHY THIS IS NOT GC2. GC2 measures distance between CONVEX cores
    (``drc_geom_primitives._decompose`` accepts a Capsule or an OrientedRect and
    nothing else; ``_point_in_convex`` and the GJK separation both ASSUME
    convexity). A filled pour is a fractured keyhole polygon — about as non-convex
    as a shape gets. Pushing one through that kernel would not raise; it would
    return a confidently wrong distance and report CLEAN. That is a false clean on
    the largest single piece of copper on the board, so pour copper gets its own
    check with a kernel that can actually represent it.

    WHY IT IS NOT CIRCULAR. The obvious objection to checking a fill we computed
    is that we would be asking the filler whether it obeyed itself. It is not the
    same rule on both sides: the FILLER carves by the ZONE's authored
    ``clearance_mm`` (falling back to the board minimum), while this check uses
    ``_effective_min_clearance`` — the board minimum RAISED by either net's class.
    A zone that authors a clearance BELOW what its net class demands fills happily
    and is caught here. The independent judge for the fill's SHAPE is the pcbnew
    oracle (tests/oracle/zone_fill_oracle.py), not this.

    Exact integer arithmetic via the same kernel that computed the fill: inflate
    each foreign primitive by the required clearance and intersect with the pour.
    A non-empty intersection means copper is closer than the rule allows.
    """
    zones = [z for z in rb.zones
             if z.kind is ZoneKind.COPPER_POUR and z.fill]
    if not zones:
        return []

    from .zone_fill import NM_PER_MM, _capsule_ring, _rect_ring  # noqa: PLC0415

    pyclipper = _zone_clipper()
    if pyclipper is None:  # pragma: no cover - install-time condition
        raise UnsupportedGeometry(
            "zone clearance needs pyclipper (the exact polygon kernel the fill "
            "was computed with) and it is not installed")

    minima = _net_class_minima(rb)
    global_min = rb.design_rules.minimums.min_clearance_mm
    net_names = {net.id: net.name for net in rb.nets}
    findings: list[dict] = []

    for zone in zones:
        fill_paths = [[(int(round(x * NM_PER_MM)), int(round(y * NM_PER_MM)))
                       for (x, y) in poly.points] for poly in zone.fill]
        # Simplify first: a self-touching keyhole ring is NOT a valid Clipper
        # SUBJECT (measured — the boolean returns overlapping garbage pieces and
        # the areas do not reconcile). Simplifying converts it to the equivalent
        # outer + hole ring set the kernel can operate on.
        fill_paths = pyclipper.SimplifyPolygons(fill_paths, pyclipper.PFT_NONZERO)
        zone_canon = _canon_layer(zone.layer.id)

        for prim in proj.copper:
            if zone_canon not in {_canon_layer(lid) for lid in prim.layers}:
                continue
            if prim.net_id is not None and prim.net_id == zone.net_id:
                continue  # same net: solid connect, no clearance applies
            required = _effective_min_clearance(global_min, minima,
                                                zone.net_id, prim.net_id)
            if isinstance(prim.shape, Capsule):
                ring, closed, reach = _capsule_ring(prim.shape), False, prim.shape.r + required
            elif isinstance(prim.shape, OrientedRect):
                ring, closed, reach = _rect_ring(prim.shape), True, required
            else:
                raise UnsupportedGeometry(
                    f"zone clearance cannot model copper shape "
                    f"{type(prim.shape).__name__} on {prim.entity_id!r}")

            offset = pyclipper.PyclipperOffset(2.0, 5000)
            offset.AddPath(ring, pyclipper.JT_ROUND,
                           pyclipper.ET_CLOSEDPOLYGON if closed
                           else pyclipper.ET_OPENROUND)
            inflated = offset.Execute(int(round(reach * NM_PER_MM)))
            if not inflated:
                continue

            clipper = pyclipper.Pyclipper()
            clipper.AddPaths(fill_paths, pyclipper.PT_SUBJECT, True)
            clipper.AddPaths(inflated, pyclipper.PT_CLIP, True)
            overlap = clipper.Execute(pyclipper.CT_INTERSECTION,
                                      pyclipper.PFT_NONZERO, pyclipper.PFT_NONZERO)
            if not overlap:
                continue

            centre = _overlap_centroid(overlap, NM_PER_MM)
            findings.append(_finding(
                "gc7_zone_clearance", zone.id, None, "zone_copper",
                zone.net_id, zone.layer.id,
                # The pour intrudes into the required band; how FAR in is not
                # recovered by an intersection test, so the measurement reported
                # is the honest one we have: 0 means "inside the band", not
                # "touching". `required` is the rule it broke.
                measured=0.0, required=required,
                closest=list(centre), witness=list(centre),
                extra={"against_entity_id": prim.entity_id,
                       "against_kind": prim.kind},
                ref=prim.ref, pad=prim.pad_number,
                net_name=net_names.get(zone.net_id)))
    return findings


def _zone_clipper():
    try:
        import pyclipper  # noqa: PLC0415
    except ImportError:  # pragma: no cover - install-time condition
        return None
    return pyclipper


def _overlap_centroid(paths, scale: int) -> tuple[float, float]:
    """A deterministic point inside the offending overlap, in mm — the MINIMUM
    vertex of the minimum path, so the reported location does not depend on
    Clipper's contour ordering."""
    best = min(min(path) for path in paths)
    return (best[0] / scale, best[1] / scale)


def _finding(rule: str, entity_id: str, parent: str | None, kind: str,
             net_id: str | None, layer: str | None,
             measured: float, required: float, *,
             closest: list, witness: list,
             midpoint: list | None = None, extra: dict | None = None,
             ref: str | None = None, pad: str | None = None,
             net_name: str | None = None) -> dict:
    out = {
        "type": rule,
        "entity_id": entity_id,
        "parent": parent,
        "kind": kind,
        "net_id": net_id,
        "layer": layer,
        # HUMAN SOURCE ATTRIBUTION (019f9589ebb3): added ALONGSIDE the hashed ids
        # above (ref="U1", pad="1", net_name="GND"). None where a field does not
        # apply (traces/vias have no ref/pad; unassigned copper has no net_name).
        "ref": ref,
        "pad": pad,
        "net_name": net_name,
        "measured_mm": round(measured, 6),
        "required_mm": round(required, 6),
        "closest": [round(closest[0], 6), round(closest[1], 6)],
        "witness": [round(witness[0], 6), round(witness[1], 6)],
    }
    if midpoint is not None:
        out["midpoint"] = [round(midpoint[0], 6), round(midpoint[1], 6)]
    if extra:
        out.update(extra)
    return out


_COUNT_KEYS = (
    "gc1_trace_width", "gc2_copper_clearance", "gc3_drill", "gc3_finished_hole",
    "gc4_annular_ring", "gc5_copper_to_edge", "gc6_hole_to_hole",
    "gc7_zone_clearance",
)


def _indeterminate(kind: str, message: str,
                   diagnostics: list | None = None) -> dict:
    """The INDETERMINATE envelope — the check did NOT produce a geometric verdict.
    Deliberately carries NO ``clean``/``findings``/zero-counts a caller could read
    as a pass. ``ok=False`` == "the check did not run to a verdict"."""
    return {
        "ok": False,
        "scope": "geometric",
        "verifies_geometry": False,
        "verdict": "indeterminate",
        "error": {
            "kind": kind,
            "message": message,
            "diagnostics": diagnostics or [],
        },
    }


def geometric_indeterminate(kind: str, message: str,
                            diagnostics: tuple | list = ()) -> dict:
    """PUBLIC constructor for the geometric INDETERMINATE union — the single
    discriminated failure shape at the ``drc_geometric`` method boundary
    (019f9589b232). The method layer uses this for a source that will not parse
    (``kind="parse"``) and for an unexpected compile exception (``kind="internal"``)
    so EVERY failure carries the same envelope (``ok=False``, ``scope="geometric"``,
    ``verifies_geometry=False``, ``verdict="indeterminate"``, ``error={...}``) — no
    bespoke third shape a caller must special-case, and never a ``clean``/``findings``
    a caller could read as a pass. Thin wrapper over :func:`_indeterminate`."""
    return _indeterminate(kind, message, list(diagnostics))


def _diag_dict(diag: Diagnostic) -> dict:
    return {
        "severity": diag.severity.value,
        "code": diag.code,
        "message": diag.message,
    }


def run_geometric_drc(rb: ResolvedBoard, *,
                      warnings: tuple[dict, ...] = ()) -> dict:
    """The PURE geometric-DRC kernel over an already-compiled ResolvedBoard.

    Returns the DETERMINATE union on success (``ok=True``, verdict
    ``clean``/``violations``) or the INDETERMINATE union when it meets geometry it
    cannot model (never a false clean). Does NOT call ``compile_board`` — the
    method layer (C3) compiles and passes the board + its compile warnings here.
    """
    try:
        # Fail-closed guards BEFORE any check: an unmodelable board must be
        # indeterminate, never silently skipped to a clean verdict.
        if isinstance(rb.outline, ProfileOutline):
            # A rect-outer profile (rim rectangle + interior cutouts) IS
            # modelable: GC5 measures against the rim frame and every cutout
            # contour. Any other outer shape stays indeterminate.
            if profile_outer_rect(rb.outline) is None:
                return _indeterminate(
                    "unsupported_geometry",
                    "geometric DRC models a rectangular board rim only; this "
                    "ProfileOutline's outer contour is not an axis-aligned rectangle")
        elif not isinstance(rb.outline, RectOutline):
            return _indeterminate(
                "unsupported_geometry",
                "geometric DRC v1 models a rectangular (RectOutline) board only; "
                f"got {type(rb.outline).__name__}")
        unfilled = [z.id for z in rb.zones
                    if z.kind is ZoneKind.COPPER_POUR and z.fill is None]
        if unfilled:
            # NARROWED, not relaxed (C6). This used to reject ANY zone, because no
            # zone had ever carried a computed fill and indeterminate was the only
            # honest verdict for copper whose extent was never computed. Pours are
            # filled by the compiler now, so the condition that matters is FILL
            # STATE: an UNFILLED pour is still copper we cannot check, and clean
            # would still be a false clean on geometry we know we did not evaluate
            # (spec §4). A FILLED pour is checked by GC7 below. A KEEPOUT emits no
            # copper at all, so it needs neither.
            return _indeterminate(
                "unsupported_geometry",
                f"geometric DRC cannot check {len(unfilled)} copper pour(s) whose "
                f"fill was never computed ({', '.join(unfilled)})")

        # FAIL-CLOSED GUARD (019f95893989): a via carrying a PER-LAYER PADSTACK has
        # per-layer land diameters the GC2/GC5 copper projection does not model
        # (project_board uses the single via.diameter_mm for the via CopperPrimitive
        # on every span layer while honoring the padstack only for GC4). A larger top
        # padstack land can collide while GC2/GC5 read the smaller global diameter —
        # a false clean. The compiler authors no padstacks today, so gating here is
        # the safe minimal v1 repair (Codex option B) until CAM + DRC model padstack
        # copper consistently.
        if any(via.padstack is not None for via in rb.vias):
            return _indeterminate(
                "unsupported_geometry",
                "per-layer via padstack copper is not modeled in GC2/GC5 yet; "
                "geometric DRC is indeterminate rather than risk a false clean")

        # FAIL-CLOSED GUARD (019f95897086): a COPPER board/placed graphic is copper
        # the kernel never projects (project_board reads pads/traces/vias/holes only).
        # A copper BoardGraphic or component PlacedGraphic would be silently skipped
        # and the board certified clean — a false clean over unmodeled copper. Detect
        # any copper graphic and fail closed to indeterminate.
        if any(g.layer.role is LayerRole.COPPER for g in rb.board_graphics) or any(
                g.layer.role is LayerRole.COPPER
                for comp in rb.components for g in comp.placed_graphics):
            return _indeterminate(
                "unsupported_geometry",
                "copper board/placed graphics are not modeled by geometric DRC; "
                "geometric DRC is indeterminate rather than skip unmodeled copper")

        # Per-net-class width/clearance minima are APPLIED, no longer gated: GC1
        # compares each trace against _effective_min_trace_width and GC2 each pair
        # against _effective_min_clearance, both built from _net_class_minima — which
        # fails closed, in BOTH dimensions, on a class minimum that cannot be sourced
        # (an unsourceable min_trace_width_mm OR min_clearance_mm), each through the
        # same predicate routing admits that field with. See PER-NET-CLASS MINIMA in
        # the module docstring.
        proj = project_board(rb)

        findings: list[dict] = []
        findings += _check_gc1_trace_width(proj, rb)
        findings += _check_gc2_clearance(proj, rb)
        findings += _check_gc3_drill(proj, rb)
        findings += _check_gc4_annular(proj, rb)
        findings += _check_gc5_copper_to_edge(proj, rb)
        findings += _check_gc6_hole_to_hole(proj, rb)
        findings += _check_gc7_zone_clearance(proj, rb)
    except UnsupportedGeometry as exc:
        return _indeterminate("unsupported_geometry", str(exc))
    except Exception as exc:  # noqa: BLE001 - fail-closed: a crash is NOT a clean.
        return _indeterminate("internal", f"geometric DRC raised {exc!r}")

    counts = {key: 0 for key in _COUNT_KEYS}
    for f in findings:
        counts[f["type"]] = counts.get(f["type"], 0) + 1

    profile = rb.design_rules.rule_profile
    return {
        "ok": True,
        "scope": "geometric",
        "verifies_geometry": True,
        "verdict": "violations" if findings else "clean",
        "board_id": rb.id,
        "source_digest": rb.provenance.source_digest,
        "rule_profile": {
            "id": profile.id,
            "version": profile.version,
            "digest": profile.digest,
        },
        "findings": findings,
        "counts": counts,
        "warnings": list(warnings),
    }


def geometric_drc_from_resolution(result: ResolutionResult) -> dict:
    """Thin adapter for tests / the future C3 method layer: map a compile
    ``ResolutionFailure`` to the INDETERMINATE envelope, or run the kernel on a
    ``ResolutionSuccess`` and surface its compile warnings on the determinate
    result. The kernel itself never calls the compiler."""
    if isinstance(result, ResolutionFailure):
        # A compile/resolution failure (unknown footprint, sizeless pad, …) is
        # "unresolved_geometry", NOT "parse": the board parsed fine, it could not be
        # resolved to fabricable geometry. "parse" is reserved for a source that will
        # not parse at all (surfaced by the method layer before compile).
        return _indeterminate(
            "unresolved_geometry",
            "board failed to compile to a ResolvedBoard",
            diagnostics=[_diag_dict(d) for d in result.diagnostics])
    if isinstance(result, ResolutionSuccess):
        warnings = tuple(_diag_dict(d) for d in result.diagnostics)
        return run_geometric_drc(result.board, warnings=warnings)
    return _indeterminate("internal", f"unexpected resolution result {type(result).__name__}")
