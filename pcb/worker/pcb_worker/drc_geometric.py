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
  * GC7 zone clearance       — FILLED pour copper vs every foreign-net copper
                                primitive, in the exact polygon kernel the fill
                                was computed with (a pour is non-convex and the
                                convex kernel would answer confidently wrong).
  * GC8 mask sliver          — the WEB of solder mask left between two openings
                                on the SAME side >= min_mask_sliver_mm. A BAND,
                                not a floor: openings that MERGE (web <= 0) have
                                no web between them and are not violations, so
                                only 0 < web < floor is flagged. [CP2 S5]
  * GC9 silkscreen DFM       — legend stroke width >= min_silk_width_mm and
                                legend-to-pad >= min_silk_to_pad_mm. ADVISORY:
                                reported in the separate ``advisories`` key and
                                counted, but NOT in ``findings``, so it never
                                moves ``verdict``. [CP2 S6]
  * GC10 hole-to-copper      — every drilled bore to every FOREIGN copper
                                primitive >= min_hole_to_copper_mm ("how far can
                                the drill wander", not "how close may two
                                potentials sit" — that is GC2). [CP2 S7]
  * GC11 hole-to-edge        — TWO faults. CONTAINMENT (unconditional): a bore
                                must not cross the rim or enter a cutout.
                                PROXIMITY: bore-to-edge >= min_hole_to_edge_mm,
                                an OPTIONAL floor that no shipped profile
                                declares, so that half does not run on any
                                fixture in the corpus. [CP2 S8]

  The GC7 and GC9 lines were MISSING from this list until CP2 S7 added GC10
  beside them — GC7 since it shipped (pre-epoch), GC9 since S6 wrote it. Noted
  rather than silently corrected: a check set that lists 8 of 10 checks reads as
  a complete inventory, which is the shape of doc defect this epoch keeps
  finding.

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
    RoundedRect,
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
from . import mask_source, refdes_anchor, silk_source
from .geometry import rotate_local_offset, rotation_radians
from .mask_source import MaskOpening
from .pad_source import placed_pad_to_geom
from .ir_projection import (
    board_graphic_to_dict,
    cutout_point_loops,
    graphic_to_dict,
    outline_frame,
    profile_outer_rect,
)
from .resolved_board import (
    Diagnostic,
    LayerRole,
    Side,
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
    # IS THIS BORE A SLOT (oblong/routed) RATHER THAN A ROUND DRILL?
    #
    # Carried as a FACT from the source geometry, never inferred from
    # ``capsules``. The first attempt at the feature-specific drill floors did
    # infer it (a degenerate capsule reads as round) and produced a FALSE CLEAN:
    # ``_hole_from_drill`` deliberately models an oblong PAD drill as a
    # degenerate disc of the MAJOR radius — a documented GC6 over-approximation
    # — so an oblong pad drill looked round and skipped the slot floor
    # entirely. Reading a semantic property off a geometry that is documented
    # as an approximation is the bug; this field is the fix.
    is_slot: bool = False


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
class SilkPrimitive:
    """One piece of legend geometry, board frame, as the EMITTER will draw it.

    Carries the neutral :mod:`silk_source` primitive rather than a re-modelled
    copy, because the whole point of projecting silk is that the checker and the
    emitter agree about what is on the board. ``geometry`` is a SilkLine /
    SilkCircle / SilkArc / SilkPoly.

    ``origin`` distinguishes authored footprint artwork ("graphic") from a
    SYNTHESIZED reference designator ("refdes") and from BOARD-level artwork
    that belongs to no component ("board_graphic", whose ``parent_id`` is the
    board and whose ``ref`` is None). A designator exists in no IR —
    it is generated at emission — so a checker that projected only authored
    graphics would measure a board with no designators on it and clear silk
    rules the fabricated board violates.
    """
    entity_id: str
    parent_id: str | None
    side: Side
    geometry: Any
    width_mm: float
    origin: str                    # "graphic" | "refdes" | "board_graphic"
    ref: str | None = None         # owning component ref, when there is one


@dataclass(frozen=True)
class Projection:
    copper: tuple[CopperPrimitive, ...]
    holes: tuple[HolePrimitive, ...]
    annular: tuple[AnnularEntity, ...]
    # Legend geometry (epoch CP2 S4). Default-empty so every existing
    # constructor call and every consumer that predates silk keeps working —
    # `Projection(copper, holes, annular)` is still valid.
    silk: tuple[SilkPrimitive, ...] = ()
    # Diagnostics raised while projecting silk (a malformed primitive the shared
    # harvest warned about and dropped). Carried rather than discarded: the
    # emitter surfaces the same warnings, and a checker that silently ignored
    # them would be quietly narrower than the artwork it is checking.
    silk_warnings: tuple[tuple[str, str, str | None], ...] = ()
    # Solder-mask openings (epoch CP2 S4), from the same owner the emitter
    # adopted. These are :class:`mask_source.MaskOpening` values verbatim, not a
    # re-modelled copy — a checker holding its own idea of where mask opens is
    # the false clean this station exists to prevent, and it is worse here than
    # for silk: a MISSED aperture in a mask-sliver check reports no sliver at
    # all, which reads as a pass.
    #
    # APPENDED, not inserted next to `silk` where it would read better. Every
    # field here is positional-capable and `project_board` used to construct
    # this tuple positionally; slotting a new field into the middle would have
    # silently rebound `silk_warnings` to the mask tuple at every existing call
    # site. The constructor now passes keywords (below) so the next person is
    # free to reorder, but the ordering stays append-only regardless.
    mask: tuple[MaskOpening, ...] = ()
    # Entities whose mask coverage could NOT be determined, as (entity_id,
    # reason). Non-empty means the `mask` tuple above is INCOMPLETE, and any
    # check that consumes mask must refuse to report a mask verdict rather than
    # reporting one computed from a partial aperture set — a sliver check that
    # silently skipped an entity would report fewer slivers, which reads as a
    # healthier board.
    #
    # WHY DATA AND NOT A RAISE. _project_mask first raised UnsupportedGeometry
    # on a non-round board hole, which run_geometric_drc turns into a WHOLESALE
    # indeterminate. That took down gc1-gc7 — checks that model slots perfectly
    # well and had real findings on such boards — on behalf of a mask family
    # that no check consumes yet. Fail-closed, but scoped far wider than the
    # thing that was actually unknown, and it converted determinate findings
    # into silence. The unknown is per-entity, so it is carried per-entity.
    mask_indeterminate: tuple[tuple[str, str], ...] = ()


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
        elif ir_pad.carries_copper:
            shape = smd_shape(pad, number, comp.ref)
            copper.append(CopperPrimitive(
                entity_id=pad.id, parent_id=comp.id, kind="smd_pad",
                layers=pad_copper, net_id=pad.net_id,
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
            position=pos, aabb=aabb_union([c.aabb() for c in cap_list]),
            is_slot=not isinstance(hole.feature, RoundHole)))
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

    silk, silk_warnings = _project_silk(rb)
    # KEYWORDS from here on. Projection has grown two optional families in this
    # station alone; positional construction makes every future field addition a
    # chance to silently rebind an existing one.
    mask, mask_indeterminate = _project_mask(rb)
    return Projection(copper=tuple(copper), holes=tuple(holes),
                      annular=tuple(annular), silk=silk,
                      silk_warnings=silk_warnings, mask=mask,
                      mask_indeterminate=mask_indeterminate)


def _project_silk(rb: ResolvedBoard) -> tuple[tuple[SilkPrimitive, ...],
                                              tuple[tuple[str, str, str | None], ...]]:
    """Project LEGEND geometry through the same owner the emitters harvest with.

    THE ONLY CORRECT WAY TO DO THIS is to call :mod:`silk_source`, not to walk
    PlacedGraphic here and model lines/arcs again. A second harvest would let
    DRC measure geometry the emitter never draws (or clear geometry it does),
    which is the false-clean this whole substrate exists to prevent — the
    reason silk_source was extracted in S2 rather than DRC growing its own
    reader.

    TWO SOURCES, and missing either one is a silent under-check:

      * authored footprint artwork (``PlacedGraphic``), and
      * SYNTHESIZED reference designators, which are in NO IR at all — they are
        generated from a stroke font at emission time. Projecting only the
        first would hand every silk rule a board with no designators on it.

    Placement here is IDENTITY: the compiler already resolved PlacedGraphic to
    board-absolute coordinates and already flipped a bottom component's layer to
    B.SilkS (geometry.PlacementTransform, pinned by the pcbnew oracle). So the
    LAYER is authoritative for side and no further mirror may be applied —
    exactly the rule ``gerber._emit_silk`` follows on its IR branch. Designators
    are different: glyphs are synthesized in text-local coordinates on every
    path, so they take the component's real placement and its side.
    """
    prims: list[SilkPrimitive] = []
    warnings: list[tuple[str, str, str | None]] = []

    for comp in rb.components:
        placement = comp.placement
        for graphic in comp.placed_graphics:
            side = silk_source.silk_side(graphic.layer.id)
            if side is None:
                continue  # courtyard / fab / copper — not legend
            harvest = silk_source.harvest_graphic(
                0.0, 0.0, 0.0, graphic_to_dict(graphic))
            for warning in harvest.warnings:
                warnings.append((warning.code, warning.message, comp.ref))
            for prim in harvest.primitives:
                prims.append(SilkPrimitive(
                    entity_id=graphic.id, parent_id=comp.id, side=side,
                    geometry=prim, width_mm=prim.width, origin="graphic",
                    ref=comp.ref))

        refdes_side = placement.side
        # rb.footprint_for, NOT a hand-rolled scan of footprint_definitions.
        # The emitter uses footprint_for (gerber._harvest_ir) and so does
        # _project_mask forty lines below; a local `next(..., None)` here is a
        # third reading of one datum with a DIFFERENT failure mode — it yields
        # None where footprint_for raises, so a missing definition would make
        # the emitter refuse while this surface quietly drew the designator at
        # the default anchor. Unreachable today (construction validates the id),
        # which is exactly when divergences get written down and forgotten.
        # The EFFECTIVE anchor, not the raw authored field: a footprint that
        # authors none gets the courtyard-derived anchor the emitter uses
        # (refdes_anchor.effective_reference_text), so this projection measures
        # the designator where the fab will actually print it.
        reference_text = refdes_anchor.effective_reference_text(
            rb.footprint_for(comp))
        for idx, prim in enumerate(silk_source.refdes_strokes(
                comp.ref, placement.position[0], placement.position[1],
                placement.rotation_deg, reference_text, refdes_side)):
            prims.append(SilkPrimitive(
                entity_id=f"{comp.id}:refdes[{idx}]", parent_id=comp.id,
                side=refdes_side, geometry=prim, width_mm=prim.width,
                origin="refdes", ref=comp.ref))

    # BOARD-LEVEL legend — artwork with no owning component.
    # It MUST be projected here: the emitter draws it, so silk rules that skipped
    # it would clear a board whose fabricated legend violates them, which is the
    # false clean this whole projection exists to prevent. Board graphics are
    # board-absolute and their layer is authoritative for side, so the harvest
    # runs at identity with no mirror — the same rule the placed-graphic loop
    # above follows and the same one gerber._emit_board_graphics follows.
    for graphic in rb.board_graphics:
        side = silk_source.silk_side(graphic.layer.id)
        if side is None:
            continue  # courtyard — documentation, not legend
        harvest = silk_source.harvest_graphic(
            0.0, 0.0, 0.0, board_graphic_to_dict(graphic))
        for warning in harvest.warnings:
            warnings.append((warning.code, warning.message, None))
        for prim in harvest.primitives:
            prims.append(SilkPrimitive(
                entity_id=graphic.id, parent_id=rb.id, side=side,
                geometry=prim, width_mm=prim.width, origin="board_graphic",
                ref=None))

    return tuple(prims), tuple(warnings)


def _project_mask(rb: ResolvedBoard) -> tuple[tuple[MaskOpening, ...],
                                              tuple[tuple[str, str], ...]]:
    """Project SOLDER-MASK openings through the owner the emitter adopted.

    Same rule as :func:`_project_silk`, enforced harder. Every opening here comes
    from :mod:`mask_source`; nothing in this function decides a dimension, a
    side, or whether an entity opens mask at all. If it did, DRC could measure
    apertures the fab never receives — and for mask specifically the dangerous
    direction is the missing one: a sliver check that never sees two openings
    reports no sliver between them, which is indistinguishable from a pass.

    THE THREE SOURCES, matching ``gerber._harvest_ir``'s three loops exactly:
    component pads, vias (per-side tenting), and board-level holes. A fourth
    would be a bug in one of the two surfaces.

    Pads go through ``placed_pad_to_geom`` — the SAME conversion the IR-native
    emitter harvest uses — rather than reading PlacedPad fields directly here.
    The conversion is where drilled/plated/shape semantics are settled, and two
    readings of it is exactly the drift this station removed. Placement is
    already baked into PlacedPad (board-absolute position, absolute rotation),
    which is why the coordinates pass through unchanged.
    """
    openings: list[MaskOpening] = []
    indeterminate: list[tuple[str, str]] = []
    clearance = mask_source.resolve_ir_mask_clearance(rb)

    for comp in rb.components:
        side = comp.placement.side
        number_of = {p.source_id: p.number for p in rb.footprint_for(comp).pads}
        for placed in comp.placed_pads:
            pad = placed_pad_to_geom(placed, number_of.get(placed.source_id, ""))
            # POSITION AND ANGLE ARE READ OFF THE PadGeom, not off the PlacedPad
            # beside it. They carry the same values today — placed_pad_to_geom
            # copies both across — but reading the PlacedPad here while the
            # emitter reads the converted PadGeom would be two parallel accesses
            # of the same datum, and the conversion is exactly where a future
            # normalisation would land. The `rotation is None` fallback mirrors
            # gerber._emit_pads, whose component rotation is 0 on the IR path
            # because PlacedPad geometry is already board-absolute.
            openings.extend(mask_source.pad_openings(
                pad, pad.x, pad.y,
                pad.rotation if pad.rotation is not None else 0.0,
                side, comp.ref, clearance,
                # The STABLE pad id, which only this path has (Codex finding
                # 4). It is the same id the COPPER projection keys pads on a
                # few hundred lines up (`entity_id=pad.id`), so a GC8 mask
                # finding and a GC2 clearance finding about the same pad now
                # join on one key instead of one saying "U1 pad 2" and the
                # other saying "2".
                entity_id=placed.id))

    for via in rb.vias:
        openings.extend(mask_source.via_openings(
            via.position[0], via.position[1], via.diameter_mm,
            via.tented_front, via.tented_back, clearance, via.id))

    for hole in rb.holes:
        if not isinstance(hole.feature, RoundHole):
            # NON-ROUND (oval / slot).
            #
            # UNPLATED is modeled EXACTLY. Such a hole opens mask to its own
            # drill with no margin — the same NPTH rule a round hole follows,
            # differing only in aperture shape. The decomposition into capsules
            # is REUSED from _hole_capsules rather than rewritten: it is the
            # same geometry the hole projection already walks, and a second
            # decomposition of one feature is how two surfaces start disagreeing
            # about where a slot is.
            #
            # PLATED non-round stays undetermined — but NOT for the reason this
            # comment used to give, and the branch is CURRENTLY UNREACHABLE.
            #
            # CORRECTED IN THE CP2 S8 REVIEW ROUND (Fable MEDIUM-2). The old text
            # claimed "only RoundHole carries an annulus in the IR, so there is
            # no land for an opening to follow". That is FALSE, and measurably
            # so: ResolvedHole.__post_init__ REFUSES a plated hole with
            # annulus_mm=None ("a plated hole must carry an authored copper
            # annulus"), so every plated hole — round or not — has a land. The
            # real limitation is ours, not the IR's: nothing here models what a
            # mask opening around an oblong or routed land should look like.
            #
            # UNREACHABLE, ALSO MEASURED: project_board's annular block raises
            # UnsupportedGeometry on a plated non-round board hole BEFORE this
            # function is ever called, so no board reaches this line and the
            # run-level GC8 refusal that consumes `mask_indeterminate` has never
            # fired. The S4 redesign's stated payoff (keeping gc1-gc7 alive on
            # such boards) is therefore real only for UNPLATED non-round holes,
            # which do flow through the branch below.
            #
            # KEPT RATHER THAN DELETED, deliberately: it is the fail-closed
            # backstop for the day the annular raise is narrowed, and deleting it
            # would make that future change silently produce a partial aperture
            # set — a false clean. What it must NOT keep is a false explanation.
            # The open design question (model plated-slot mask openings, and
            # narrow the wholesale GC8 refusal that would then go live) is filed
            # rather than answered here.
            if hole.plated:
                indeterminate.append((
                    hole.id,
                    "a plated non-round board hole has an authored annulus, but "
                    "this projection does not model the mask opening around a "
                    "non-round land, so mask coverage for this hole is "
                    "undetermined"))
                continue
            caps, _minor, _pos = _hole_capsules(hole)
            for cap in caps:
                length = math.hypot(cap.bx - cap.ax, cap.by - cap.ay)
                openings.extend(mask_source.npth_feature_openings(
                    (cap.ax + cap.bx) / 2.0, (cap.ay + cap.by) / 2.0,
                    length + 2.0 * cap.r, 2.0 * cap.r,
                    math.degrees(math.atan2(cap.by - cap.ay, cap.bx - cap.ax)),
                    hole.id))
            continue
        # POSITION LIVES ON THE FEATURE, not the hole (`hole.feature.position`)
        # — the same field `_hole_capsules` reads. `hole.position` does not
        # exist, and reaching for it is the obvious wrong guess here.
        openings.extend(mask_source.board_hole_openings(
            hole.feature.position[0], hole.feature.position[1],
            hole.feature.diameter_mm, hole.plated, hole.annulus_mm,
            clearance, hole.id))

    return tuple(openings), tuple(indeterminate)


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
        aabb=cap.aabb(), ref=ref, pad_number=pad_number, net_name=net_name,
        # SLOT-NESS FOR A PAD DRILL, and the dependency that makes it sound.
        #
        # DrillDisc.kind is itself DERIVED (from whether the two authored size
        # axes differ), so this is not the authored shape token — an earlier
        # revision of this code claimed it was, and that claim was wrong
        # (Codex review 1090 finding 1). It is nonetheless CORRECT here, but
        # only because compile_board's capability gate now REFUSES a drill
        # whose shape says round while its axes disagree: with contradictory
        # data rejected upstream, "axes differ" and "the author declared a
        # non-round hole" are the same fact. If that gate is ever relaxed,
        # this line silently starts lying again — the two must move together.
        is_slot=drill.kind != "round")


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
        # Half the oval's major axis as a BOARD-frame offset, through the ONE
        # rotation this worker has (geometry.rotate_local_offset). The axis is
        # local-x when width>=height, otherwise local-y.
        #
        # Composing a matrix here from a raw math.radians() would turn the
        # feature the wrong way: the angle is clockwise in a Y-down frame and
        # must be negated first, which is precisely what the shared helper does.
        # Every multiple of 90 hides the difference under the oval's own
        # symmetry, so only an off-axis slot exposes it.
        dx, dy = rotate_local_offset(*((half, 0.0) if w >= h else (0.0, half)),
                                     feat.rotation_deg)
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


def _exceeds(measured: float, ceiling: float) -> bool:
    """Ceiling predicate — the mirror of :func:`_violates`, which is a FLOOR.

    Every other rule in this module asks "is this at least X". GC12 asks "is
    this at most X", and spelling that as ``_violates(ceiling, measured)`` is
    arithmetically identical while reading inside-out — which is exactly how a
    later edit swaps two arguments and silently inverts a check. A measurement
    AT the ceiling passes, symmetrically with _violates."""
    return measured > ceiling + EPS


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

    SHARED WITH ``methods._net_class_overrides`` since epoch GA-6 (chore
    019fa20b11): the loop, the referenced-only rule, the defensive lookup and
    the two fail-closed raises live ONCE in :mod:`.net_class_policy` (the
    third, dependency-free module the old note here predicted), and both
    sides delegate — keying by their own identities (``net.id`` here, what a
    :class:`CopperPrimitive` carries; ``net.name`` there, what the router
    speaks) and passing the same two predicates. Relax the admission there
    and both the routing and DRC suites go red.
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
    from .net_class_policy import referenced_class_minima

    # ONE admission policy (019fa20b11, epoch GA-6): the loop this function
    # used to carry — the near-clone of methods._net_class_overrides whose
    # "why not shared" note above predicted a third module — now lives in
    # net_class_policy, and both sides delegate. This side supplies its own
    # identity (net_id, what a projected CopperPrimitive carries) and the
    # SAME two predicates routing admits the same two fields through.
    return referenced_class_minima(
        rb,
        key_of=lambda net: net.id,
        width_admit=positive_mm,
        clearance_admit=nonnegative_mm,
        fail=UnsupportedGeometry,
        context="geometric DRC")


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
        # min_drill_mm is the general TOOL floor and applies to every drilled
        # feature — but a board house publishes SEPARATE, coarser minima for
        # non-plated holes and for slot widths (JLCPCB: 0.15 general vs 0.50
        # NPTH, 0.50 plated slot, 1.0 NPTH slot). Checking every hole against
        # the general floor alone reported a 0.20mm NPTH as CLEAN while it sat
        # outside the documented process (Codex review 1086 finding 2).
        #
        # The applicable floor is therefore the STRICTER of the general one and
        # whichever feature-specific floor this hole's KIND selects — when the
        # profile declares one. An absent (None) feature floor means the
        # profile said nothing about that feature, and the general floor
        # governs exactly as it did before these fields existed.
        if hole.is_slot:
            specific = (mins.min_plated_slot_mm if hole.plated
                        else mins.min_npth_slot_mm)
        else:
            specific = None if hole.plated else mins.min_npth_mm
        drill_floor = mins.min_drill_mm
        if specific is not None:
            drill_floor = max(drill_floor, specific)
        if _violates(hole.minor_mm, drill_floor):
            findings.append(_finding(
                "gc3_drill", hole.entity_id, hole.parent_id, hole.origin,
                hole.net_id, None, hole.minor_mm, drill_floor,
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


# THE DOCUMENTED PARTICIPANT ORDER for pairwise findings (bug 019f98b26f76,
# fixed epoch GA-6; the contract statement lives in pcb/docs/drc.md). The old
# order was the opaque entity_id comparison, a content-derived token — so the
# SAME physical collision could present as (pad, trace) on one board and
# (trace, pad) on another, and any consumer assuming participants[0] is the
# pad would draw reversed arrows on some boards only. Order is now by KIND
# RANK — pads, then vias, then board-hole copper, then trace segments, then
# zone copper — with entity_id only as the tiebreak within a rank. The same
# table serves GC6's hole pairs (HolePrimitive.origin uses the same
# vocabulary for its pad/via/board_hole origins). Unknown kinds sort last,
# so a future primitive class degrades to the old id order instead of
# crashing or landing first.
_PARTICIPANT_KIND_RANK = {
    "smd_pad": 0, "pth_pad": 0,
    "via": 1,
    "board_hole_copper": 2, "board_hole": 2,
    "trace_seg": 3,
    "zone_copper": 4,
}


def _ordered_pair(a, b, kind_of):
    ka = (_PARTICIPANT_KIND_RANK.get(kind_of(a), 99), a.entity_id)
    kb = (_PARTICIPANT_KIND_RANK.get(kind_of(b), 99), b.entity_id)
    return (a, b) if ka <= kb else (b, a)


def _check_gc6_hole_to_hole(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    required = rb.design_rules.minimums.min_hole_to_hole_mm
    findings: list[dict] = []
    # Naive all-pairs is acceptable for C1 (few holes); deterministic ordering by
    # entity_id. The deterministic per-layer broad phase is C2.
    ordered = sorted(proj.holes, key=lambda h: h.entity_id)
    n = len(ordered)
    for i in range(n):
        for j in range(i + 1, n):
            # Kind-ranked participant order (019f98b26f76) — see the table
            # above; witness/closest swap WITH the pair so they stay attached
            # to the participant they describe.
            h1, h2 = _ordered_pair(ordered[i], ordered[j], lambda h: h.origin)
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


def _hole_copper_exempt(hole: HolePrimitive, prim: CopperPrimitive) -> bool:
    """Is this (hole, copper) pair outside GC10's rule? Two exemptions, and each
    one is load-bearing for a different reason.

    1. SAME ENTITY — a drilled feature versus its OWN land. A PTH pad, a via and
       a plated board hole each project a hole AND the copper ring around it
       under the SAME ``entity_id``; the gap between them is the annular web,
       which is governed by GC4 (``min_annular_ring_mm``, 0.18 on JLCPCB) and is
       by construction far below any hole-to-copper floor (0.28). Without this,
       GC10 would flag every plated hole on every board against its own ring.

       AND IT MUST BE THE ENTITY, NOT THE NET. The obvious formulation —
       "exempt same-net copper" — is INSUFFICIENT here, and quietly so. GC2's
       :func:`_same_net_exempt` requires BOTH net_ids non-null, but a plated
       board hole carries ``net_id=None`` on the hole AND on its own
       ``board_hole_copper`` primitive (``project_board``), and an unconnected
       PTH pad carries None on both halves of itself. A net-only exemption
       therefore fires on neither, and self-flags both.

       AND IT MUST NOT BE THE PARENT. Exempting a shared ``parent_id`` would
       exempt one pad's drill from a DIFFERENT pad's copper on the same
       component — two distinct potentials a hair apart, which is exactly the
       failure this check exists to catch.

    2. SAME-NET PLATED — a barrel that IS this copper, electrically. This
       MIRRORS ``zone_fill``'s carve-skip predicate verbatim
       (``hole.net_id is not None and hole.net_id == zone.net_id and
       hole.plated``) rather than inventing a second rule, so the pour and the
       checker exempt the same set. The two halves of it:
         * PLATED matters. An unplated bore has no copper barrel, so it connects
           nothing; a matching net field on it is a coincidence and the drill is
           a mechanical hazard to that net like any other. ``zone_fill`` says
           this in as many words ("NON-plated holes keep the full carve however
           their net field reads").
         * NON-NULL matters. Two unassigned (None) features are not a shared
           electrical net, the same reading GC2 takes.
       Without this, the trace that LANDS on a through-hole pad flags against
       that pad's own barrel on every board that routes anything.
    """
    if hole.entity_id == prim.entity_id:
        return True
    return hole.plated and hole.net_id is not None and hole.net_id == prim.net_id


def _check_gc10_hole_to_copper(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """GC10 — how far the drill may wander before it eats FOREIGN copper.

    Edge-to-edge distance from every drilled bore to every copper primitive it is
    not exempt from (:func:`_hole_copper_exempt`) >= ``min_hole_to_copper_mm``.

    OPTIONAL-TIER FLOOR. ``None`` means the profile published no hole-to-copper
    figure, and this returns no findings — "the profile said nothing", not
    "checked and clean". The count key still exists and stays 0, which is the
    same contract GC3's feature-specific drill floors and GC9's silk floors use.

    WHY IT IS NOT GC2. GC2 answers "how close may two POTENTIALS sit" and
    compares copper to copper. This answers "how far can the DRILL wander", a
    different physical failure with a different published number
    (JLCPCB: 0.10 mm spacing versus 0.28 mm PTH-to-track). ``zone_fill``'s
    ``_hole_clearance_mm`` already draws that distinction for the pour and
    explains it at length; this is the same rule applied to the copper the
    filler does not produce.

    WHERE THE MARGINAL VALUE ACTUALLY IS, measured rather than assumed, because
    it is not where the station brief expected. For a PLATED hole, GC2 already
    measures its LAND against foreign copper at ``min_clearance_mm`` while this
    measures its BORE at ``min_hole_to_copper_mm``; the bore is smaller than the
    land by exactly the annular ring, so GC2 is the STRICTER of the two whenever
    ``ring >= min_hole_to_copper_mm - min_clearance_mm`` — 0.18 on JLCPCB, which
    is precisely the ring GC4 already refuses to go below. Every plated hole this
    profile admits is therefore covered by GC2 before it reaches here. The gap
    this check actually closes is the UNPLATED bore: it projects no copper
    primitive at all (``project_board`` gives an NPTH pad no land, and a
    non-plated board hole no annulus), so GC2 can form no pair and a track may
    run arbitrarily close to a mounting hole with every other check silent. That
    is a real board JLCPCB would reject, and it passed clean until this station.
    Consequence worth carrying: on a profile whose annular floor is LOWER than
    the hole/copper floor delta, this check starts adding coverage for plated
    holes too — so it is not dead weight, it is currently redundant by an
    arithmetic accident of one profile's numbers.

    NO LAYER FILTER, deliberately. ``HolePrimitive`` carries no layer span
    because every drilled feature this schema can express is a THROUGH feature
    (``compile_board`` hardcodes ``ViaKind.THROUGH`` and the schema cannot author
    blind/buried), so a bore is present on every copper layer and comparing it to
    copper on any layer is exact today. If blind/buried drills ever become
    expressible, this comparison becomes a SUPERSET — it would over-report
    against layers the bore never reaches, which is the fail-safe direction — but
    the honest repair then is to give ``HolePrimitive`` a span, not to relax this.

    POUR COPPER IS OUT OF SCOPE, and this is a ruling rather than an oversight.
    ``proj.copper`` holds pads/traces/vias/board-hole annuli; filled zone copper
    is checked separately by GC7 with the polygon kernel. A GC10 arm over pours
    WOULD be expressible with GC7's inflate-and-intersect idiom, but it would be
    genuinely circular: ``zone_fill`` carves every hole it does not skip at
    ``max(copper clearance, min_hole_to_copper_mm)`` and skips exactly the holes
    this function exempts, so the answer is fixed before the question is asked.
    (GC7 escapes that objection because the filler carves by the ZONE's authored
    clearance while GC7 measures against the NET CLASS's — genuinely two rules.
    There is no second rule here.) THE RESIDUAL, so nobody has to re-derive it:
    that argument holds only because ``ResolvedZone.fill`` is produced by
    ``zone_fill.fill_board_zones`` and nothing else (``compile_board`` sets it
    explicitly to None). The day a fill can arrive from deserialization, a
    freeze, or an import, the circularity lapses and this needs the pour arm.
    """
    required = rb.design_rules.minimums.min_hole_to_copper_mm
    if required is None:
        return []
    findings: list[dict] = []
    # Deterministic ordering by entity_id on both sides, so findings are stable
    # regardless of projection order. The AABB gate below is an O(holes x copper)
    # REJECT test (four comparisons), not a sweep: it exists to keep the exact
    # convex kernel off pairs that provably cannot violate, the same argument
    # _broad_phase_pairs makes, without the sweep's per-layer bucketing (which
    # does not apply — see NO LAYER FILTER above). If hole counts ever make this
    # the hot loop, the upgrade is a sweep, not a tighter margin.
    copper = sorted(proj.copper, key=lambda p: p.entity_id)
    for hole in sorted(proj.holes, key=lambda h: h.entity_id):
        hbox = hole.aabb
        for prim in copper:
            if _hole_copper_exempt(hole, prim):
                continue
            box = prim.aabb
            if (box.min_x - required > hbox.max_x + EPS
                    or box.max_x + required < hbox.min_x - EPS
                    or box.min_y - required > hbox.max_y + EPS
                    or box.max_y + required < hbox.min_y - EPS):
                continue
            best = math.inf
            witness = None
            for cap in hole.capsules:
                dist = convex_edge_distance(cap, prim.shape)
                if dist < best:
                    best = dist
                    witness = convex_edge_witness(cap, prim.shape)
            if _violates(best, required):
                w1, w2 = witness if witness else (hole.position, hole.position)
                mid = ((w1[0] + w2[0]) / 2.0, (w1[1] + w2[1]) / 2.0)
                # THE HOLE IS THE SUBJECT and the copper is named via
                # `against_entity_id` — the GC5-cutout / GC7-zone idiom, not
                # GC6's `a|b` pair idiom. The rule is ASYMMETRIC (it is about
                # where the drill may go), unlike hole-to-hole, and keying the
                # finding on the hole lets it carry the hole's own ref/pad
                # attribution in the standard fields.
                findings.append(_finding(
                    "gc10_hole_to_copper", hole.entity_id, hole.parent_id,
                    hole.origin, hole.net_id, None, best, required,
                    closest=list(w1), witness=list(w2), midpoint=list(mid),
                    extra={"against_entity_id": prim.entity_id,
                           "against_kind": prim.kind,
                           "against_net_id": prim.net_id,
                           "against_ref": prim.ref,
                           "against_pad": prim.pad_number,
                           "against_net_name": prim.net_name,
                           "plated": hole.plated},
                    ref=hole.ref, pad=hole.pad_number,
                    net_name=hole.net_name))
    return findings


def _mask_shape(opening: MaskOpening):
    """One mask opening as a convex distance primitive, in the board frame.

    EXACT for every aperture family the profile admits, and that exactness is
    load-bearing rather than fastidious — see :class:`RoundedRect` for why an
    oversized approximation can hide a sliver instead of over-reporting one.

      circle    -> a degenerate-segment Capsule (a disc)
      oval      -> a Capsule (stadium): a segment along the MAJOR axis of length
                   (major - minor), swept by minor/2
      rect      -> an OrientedRect
      roundrect -> a RoundedRect, corner radius ``rratio * min(w, h)``, which is
                   the SAME rule the gerber emitter uses to build the aperture
                   macro (``gerber._smd_aperture``). If those two ever diverge,
                   the checker is measuring a differently-shaped hole in the mask
                   than the fab cuts.
    """
    x, y = opening.x, opening.y
    w, h = opening.width, opening.height
    # Same y-down convention the land itself is shaped with
    # (geometry.rotation_radians): a mask opening measured with the opposite
    # sign would sit mirrored over the copper it is supposed to expose.
    angle = rotation_radians(opening.angle_deg)

    if opening.shape == "circle":
        return Capsule.disc(x, y, w / 2.0)

    if opening.shape == "oval":
        minor, major = min(w, h), max(w, h)
        r = minor / 2.0
        half = (major - minor) / 2.0
        # The major axis is local-x when w >= h, else local-y — the same
        # convention `_hole_capsules` applies to an OvalHole.
        theta = angle + (0.0 if w >= h else math.pi / 2.0)
        dx, dy = half * math.cos(theta), half * math.sin(theta)
        return Capsule(x - dx, y - dy, x + dx, y + dy, r)

    if opening.shape == "roundrect":
        rratio = opening.corner_rratio
        radius = (rratio * min(w, h)) if rratio else 0.0
        return RoundedRect(x, y, w / 2.0, h / 2.0, radius, angle)

    if opening.shape == "rect":
        return OrientedRect(x, y, w / 2.0, h / 2.0, angle)

    # Fail closed. An aperture family this function cannot model is one whose
    # slivers cannot be measured, and silently skipping it would remove
    # candidate pairs from the check — fewer findings, healthier-looking board.
    raise UnsupportedGeometry(
        f"mask opening {opening.entity_id or '<unknown>'}: aperture shape "
        f"{opening.shape!r} has no modelable primitive, so mask slivers "
        f"involving it cannot be measured")


def _silk_anchor(prim: SilkPrimitive) -> tuple[float, float]:
    """A representative point ON the primitive, for a finding a human can find.

    Used only where the violation is a property of the primitive ITSELF (its
    stroke width) rather than of a pair, so there is no closest-approach line to
    report and any point on the artwork is the honest answer. Pair findings use
    real witness points from the distance kernel instead.
    """
    geom = prim.geometry
    if isinstance(geom, silk_source.SilkLine):
        return (geom.x1, geom.y1)
    if isinstance(geom, silk_source.SilkCircle):
        return (geom.cx, geom.cy)
    if isinstance(geom, silk_source.SilkPoly):
        return tuple(geom.points[0]) if geom.points else (0.0, 0.0)
    return tuple(geom.start)


def _silk_capsules(prim: SilkPrimitive) -> tuple[Capsule, ...]:
    """One silk primitive as swept-segment capsules, in the board frame.

    Silk is DRAWN geometry — every primitive is a stroked path, so its physical
    extent is the centreline swept by half the stroke width. That is exactly a
    Capsule, which is why no new primitive is needed here (contrast GC8, where
    mask apertures are filled regions and a roundrect needed exact modelling).

    A CIRCLE and an ARC are approximated by an inscribed polyline, and the
    approximation direction is chosen deliberately: chord midpoints sit INSIDE
    the true curve, so the polyline under-states how far the stroke reaches
    outward. For a silk-to-pad clearance that makes the measured distance
    LARGER than the truth — the wrong way for fail-safety. The segment count is
    therefore chosen so the sagitta (max radial error) stays under a tenth of
    the stroke half-width, and the capsule radius is then inflated by that
    residual, so the modelled body always CONTAINS the true stroke.
    """
    half = prim.width_mm / 2.0
    geom = prim.geometry

    if isinstance(geom, silk_source.SilkLine):
        return (Capsule(geom.x1, geom.y1, geom.x2, geom.y2, half),)

    if isinstance(geom, silk_source.SilkPoly):
        pts = list(geom.points)
        if len(pts) < 2:
            return (Capsule(pts[0][0], pts[0][1], pts[0][0], pts[0][1], half),) if pts else ()
        pairs = list(zip(pts, pts[1:]))
        if geom.closed and len(pts) > 2:
            pairs.append((pts[-1], pts[0]))
        return tuple(Capsule(a[0], a[1], b[0], b[1], half) for a, b in pairs)

    # Circle / arc -> polyline. Both carry a centre and a radius; an arc also
    # carries a sweep, and a circle is the full-turn case.
    if isinstance(geom, silk_source.SilkCircle):
        cx, cy, radius = geom.cx, geom.cy, geom.radius
        start_ang, sweep = 0.0, 2.0 * math.pi
    else:
        cx, cy = geom.center
        radius = math.hypot(geom.start[0] - cx, geom.start[1] - cy)
        start_ang = math.atan2(geom.start[1] - cy, geom.start[0] - cx)
        end_ang = math.atan2(geom.end[1] - cy, geom.end[0] - cx)
        sweep = end_ang - start_ang
        # Orientation "+" is counter-clockwise in the board frame; normalise the
        # sweep into that direction so a wrap does not silently become a tiny arc.
        if geom.orientation == "+":
            while sweep <= 0:
                sweep += 2.0 * math.pi
        else:
            while sweep >= 0:
                sweep -= 2.0 * math.pi

    if radius <= EPS:
        return (Capsule(cx, cy, cx, cy, half),)

    # sagitta = r * (1 - cos(step/2)); solve for step given the error budget.
    budget = max(half * 0.1, EPS)
    if budget >= radius:
        segments = 4
    else:
        step = 2.0 * math.acos(max(-1.0, min(1.0, 1.0 - budget / radius)))
        segments = max(4, int(math.ceil(abs(sweep) / step)))
    step = sweep / segments
    residual = radius * (1.0 - math.cos(abs(step) / 2.0))

    caps = []
    for i in range(segments):
        a0, a1 = start_ang + i * step, start_ang + (i + 1) * step
        caps.append(Capsule(
            cx + radius * math.cos(a0), cy + radius * math.sin(a0),
            cx + radius * math.cos(a1), cy + radius * math.sin(a1),
            half + residual))
    return tuple(caps)


#: GC9's rows are ADVISORIES, not violations, and this is where that is decided.
#:
#: MEASURED JUSTIFICATION, not a judgement call. JLCPCB publishes a 0.15mm
#: minimum silkscreen line width. KiCad's shipped library — which is what the
#: seed library vendors and what every real board is authored from — draws silk
#: at 0.12: of the 21 seed footprints, 17 carry silk GRAPHICS and 15 of those 17
#: draw below 0.15 — 94 of 202 silk graphic primitives — including R_0805,
#: C_0805, every PinHeader/PinSocket, and the ESP32 devkit. Enforcing this floor
#: as a blocking violation would refuse essentially every real board, which is
#: not a DFM check, it is an outage.
#:
#: THE COUNTING METHOD, recorded because the first version of this number was
#: WRONG and nothing in the text said how to reproduce it. Parse every
#: `library/footprints/**/*.kicad_mod` with the production
#: `footprints.parse_kicad_mod`, keep the graphics whose layer
#: `silk_source.silk_side()` accepts, and measure each with the production
#: `silk_source.graphic_width()`. This comment previously read "15 of 18 ... 84
#: of 203 primitives" under the banner "MEASURED JUSTIFICATION": the footprint
#: ratio was right only by counting a footprint whose sole silk is its reference
#: TEXT, and the primitive counts were simply wrong. Corrected in the CP2 S8
#: review round (Fable MEDIUM-3) after re-measuring by the method above. The
#: decision does not change; the number it rests on now reproduces.
#:
#: AND THE DOCTRINE ALREADY SAID SO. `fab_capability.FABRICATION_CRITICAL_OUTPUTS`
#: deliberately excludes silk, with the ratified rule that "silk/fab/documentation
#: losses are cosmetic-or-unemitted and are warned, never fatal". Copper, drill,
#: mask and paste block; legend does not. GC9 applies that existing rule to a new
#: check rather than inventing a severity tier for it.
#:
#: WHAT ADVISORY DOES NOT MEAN: it does not mean hidden. Advisories are returned
#: on the result and counted in `counts` exactly like findings, so a thin legend
#: is always reportable. What they do not do is flip `verdict` to "violations".
GC9_ADVISORY_TYPES: frozenset[str] = frozenset({
    "gc9_silk_width", "gc9_silk_to_pad", "gc9_silk_indeterminate",
})


def _check_gc9_silk(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """GC9 — silkscreen DFM: legend stroke WIDTH, and legend-to-PAD clearance.

    Returns ADVISORY rows (see :data:`GC9_ADVISORY_TYPES`): reported and counted,
    but they do not make a board fail. Silk is cosmetic by this codebase's own
    ratified output-criticality rule.

    BOTH HALVES ARE FLOOR-GATED on optional profile fields, so a profile that
    publishes no silkscreen rule enforces none of this ("said nothing" is not
    "zero"). JLCPCB publishes both figures; OSH Park publishes neither, so this
    check is silent under that profile by design rather than by omission.

    SILK IS COSMETIC, AND THAT IS WHY THE SECOND HALF MEASURES AGAINST COPPER
    PADS rather than against everything on the board. Legend over a trace is
    ugly; legend over a PAD contaminates a solderable surface, which is the
    failure the published figure is about.

    THE WARN-AND-DROP INHERITANCE, discharged here. ``Projection.silk_warnings``
    carries primitives the shared harvest could not build and dropped. Until
    this station nothing read it, so the guarantee it exists for was
    aspirational. A dropped primitive is NOT silently cleared now: it is
    surfaced as a finding of its own, because a checker that inherited a
    narrower artwork set than the emitter draws would clear legend it never
    measured.
    """
    minimums = rb.design_rules.minimums
    # DIRECT ATTRIBUTE ACCESS, not getattr-with-default. Both fields exist on
    # ManufacturingConstraints, so a default could only ever mask a RENAME — and
    # it would mask it as "this profile declared no silk rule", i.e. the check
    # would silently stop running while reporting the same zero counts it
    # reports on a profile that legitimately said nothing. Every other check
    # reads its floor directly; an AttributeError is the correct outcome for a
    # field that no longer exists. (CP2 S8 review, Fable LOW-1.)
    min_width = minimums.min_silk_width_mm
    min_to_pad = minimums.min_silk_to_pad_mm
    findings: list[dict] = []

    # Dropped-primitive surfacing, unconditional: it is not gated on a floor,
    # because "the checker could not see this artwork" is true whatever numbers
    # the profile publishes.
    #
    # BUILT AS AN EXPLICIT DICT, not through _finding, and the reason is not
    # style: _finding rounds `measured`/`required` and requires `closest`/
    # `witness` points, none of which EXIST for this row. There is no
    # measurement — that is the entire content of the row. Passing 0.0 to
    # satisfy the signature would put a number where the honest value is "none",
    # and a consumer reading measured_mm=0.0 would see a catastrophic violation
    # rather than an unanswered question.
    for code, message, ref in proj.silk_warnings:
        findings.append({
            "type": "gc9_silk_indeterminate",
            "entity_id": ref or "<unknown>",
            "parent": None, "kind": "silk", "net_id": None, "layer": None,
            "ref": ref, "pad": None, "net_name": None,
            "measured_mm": None, "required_mm": None,
            "code": code, "detail": message,
            "note": ("silk geometry the shared harvest dropped; it is NOT "
                     "measured by the silk rules below"),
        })

    if min_width is not None:
        for prim in proj.silk:
            if _violates(prim.width_mm, min_width):
                anchor = _silk_anchor(prim)
                findings.append(_finding(
                    "gc9_silk_width", prim.entity_id, prim.parent_id, "silk",
                    None, "F.SilkS" if prim.side is Side.TOP else "B.SilkS",
                    prim.width_mm, min_width,
                    closest=list(anchor), witness=list(anchor),
                    ref=prim.ref,
                    extra={"origin": prim.origin}))

    if min_to_pad is not None:
        # Pads only, and only on the side the legend is printed on. Legend on
        # the front cannot contaminate a pad that is only on the back.
        pads_by_side: dict[Side, list[CopperPrimitive]] = {Side.TOP: [], Side.BOTTOM: []}
        for cp in proj.copper:
            if cp.kind not in ("smd_pad", "pth_pad"):
                continue
            canon = {_canon_layer(lid) for lid in cp.layers}
            if "top" in canon:
                pads_by_side[Side.TOP].append(cp)
            if "bottom" in canon:
                pads_by_side[Side.BOTTOM].append(cp)

        for prim in proj.silk:
            pads = pads_by_side[prim.side]
            if not pads:
                continue
            caps = _silk_capsules(prim)
            for cp in pads:
                best = math.inf
                best_cap = None
                for cap in caps:
                    d = convex_edge_distance(cap, cp.shape)
                    if d < best:
                        best, best_cap = d, cap
                if best_cap is None or not _violates(best, min_to_pad):
                    continue
                # Witness points from the SAME kernel that produced the
                # distance, so a human opening the board at those coordinates
                # sees the pair the number came from.
                w_silk, w_pad = convex_edge_witness(best_cap, cp.shape)
                findings.append(_finding(
                    "gc9_silk_to_pad",
                    f"{prim.entity_id}|{cp.entity_id}", prim.parent_id, "silk",
                    None, "F.SilkS" if prim.side is Side.TOP else "B.SilkS",
                    best, min_to_pad,
                    closest=list(w_silk), witness=list(w_pad),
                    midpoint=[(w_silk[0] + w_pad[0]) / 2.0,
                              (w_silk[1] + w_pad[1]) / 2.0],
                    ref=prim.ref, pad=cp.pad_number,
                    extra={"origin": prim.origin, "pad_entity": cp.entity_id}))
    return findings


def _check_gc8_mask_sliver(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """GC8 — the minimum web of SOLDER MASK left standing between two openings.

    THE FLOOR THIS GIVES ITS FIRST READER. ``min_mask_sliver_mm`` is one of the
    REQUIRED profile fields and, until this station, had ZERO production
    readers: every appearance outside tests was a declaration or a validation of
    the declaration. The required tier exists because those fields are supposed
    to be load-bearing, and a doctrine that makes a MISSING required field a hard
    failure is hollow while a PRESENT one is never read.

    With this check in place, EVERY required floor has at least one production
    reader — measured field by field, not asserted. The one that could not be
    given a reader (``solder_mask_expansion_mm``, whose two shipped profiles use
    it for opposite ends of the process) was demoted to the optional tier in the
    same station rather than left standing as a required floor nothing enforces.

    THE THREE REGIMES, and the middle one is the whole check:

      web >= floor    the mask between the openings is thick enough to survive
                      processing. Clean.
      0 < web < floor a SLIVER — a ribbon of mask too thin to adhere. It lifts
                      during processing and lands somewhere else on the board,
                      or bridges two pads it was supposed to separate. This is
                      the violation.
      web <= 0        the openings MERGE. There is no ribbon, because there is no
                      mask between them at all — one continuous opening. NOT a
                      violation of this rule. Flagging it would be wrong twice
                      over: it is not a sliver, and merged openings are a normal,
                      deliberate authoring outcome (a row of fine-pitch pads under
                      one opening).

    That third regime is why the sliver test is a BAND rather than a floor
    comparison, and it is the reason ``_mask_shape`` models every aperture
    exactly instead of conservatively: an oversized approximation shrinks the
    measured web, which is harmless near the floor but silently moves a real
    sliver into the merged regime, where nothing is reported.

    PER SIDE, never across. F.Mask and B.Mask are different physical films;
    a front opening and a back opening have no mask between them to speak of.
    """
    required = rb.design_rules.minimums.min_mask_sliver_mm
    findings: list[dict] = []

    by_side: dict[Side, list[MaskOpening]] = {Side.TOP: [], Side.BOTTOM: []}
    for opening in proj.mask:
        by_side[opening.side].append(opening)

    for side in (Side.TOP, Side.BOTTOM):
        # Deterministic ordering so a finding's participant order is stable
        # across runs. entity_id is now the STABLE id and so is unique per
        # opening SOURCE, but the position tiebreak stays: one pad contributes
        # openings to BOTH sides, a slot decomposes into several capsules under
        # one hole id, and any opening may still arrive with entity_id=None
        # from a caller that has no id to give. Ordering must be total, not
        # merely usually-total.
        ordered = sorted(by_side[side],
                         key=lambda o: (o.entity_id or "", o.ref or "", o.x, o.y))
        shapes = [_mask_shape(o) for o in ordered]
        # BROAD PHASE (epoch CP2 S11). GC8 was all-pairs while GC10 next door had
        # an AABB gate, so a dense board paid the exact convex kernel on every
        # opening pair on a side, including openings at opposite corners.
        #
        # CORRECTNESS-EQUIVALENT, and the margin is the reason: the only pairs
        # this check can report sit in the band 0 < web < required, so a pair
        # whose boxes are farther apart than `required` provably cannot violate
        # and the narrow phase would have cleared it. `required` is a single
        # board-wide floor here — GC8 has no per-net-class term to fold in — so
        # the maximum-threshold invariant _sweep_pairs prunes against is
        # satisfied trivially, which is NOT the case for GC2 (see its margin
        # note). Pinned against all-pairs on near-threshold geometry in
        # tests/test_gc8_mask_sliver.py, alongside a NON-VACUITY test that the
        # sweep really prunes — an equivalence test passes trivially against a
        # broad phase that returns every pair, which is what a broken margin
        # does in the safe direction.
        #
        # Candidate pairs are re-SORTED so the emitted findings keep the exact
        # order the all-pairs double loop produced. The sweep's natural order is
        # x-sweep order, and letting that through would churn every downstream
        # expectation for no gain.
        for i, j in sorted(_sweep_pairs(
                [s.aabb() for s in shapes],
                [f"{o.entity_id or ''}|{o.ref or ''}|{o.x}|{o.y}" for o in ordered],
                required)):
            a, b = ordered[i], ordered[j]
            web = convex_edge_distance(shapes[i], shapes[j])
            if web <= EPS:
                continue  # merged openings — no mask web exists here
            if not _violates(web, required):
                continue
            mid = ((a.x + b.x) / 2.0, (a.y + b.y) / 2.0)
            findings.append(_finding(
                "gc8_mask_sliver",
                f"{a.entity_id or '?'}|{b.entity_id or '?'}", None,
                "mask_opening_pair", None,
                "F.Mask" if side is Side.TOP else "B.Mask",
                web, required,
                closest=[a.x, a.y], witness=[b.x, b.y], midpoint=list(mid),
                extra={"origins": [a.origin, b.origin],
                       "participants": [
                           {"entity_id": a.entity_id, "origin": a.origin,
                            "ref": a.ref, "pad_number": a.pad_number},
                           {"entity_id": b.entity_id, "origin": b.origin,
                            "ref": b.ref, "pad_number": b.pad_number}]}))
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
    return _sweep_pairs([p.aabb for p in prims], [p.entity_id for p in prims],
                        margin)


def _sweep_pairs(boxes: list[AABB], keys: list[str],
                 margin: float) -> list[tuple[int, int]]:
    """The sweep itself, over bare boxes — the shared kernel behind every broad
    phase in this module.

    Split out of :func:`_broad_phase_pairs` (epoch CP2 S11) so GC8's mask-opening
    broad phase runs the SAME pruning code the copper one has been proved against,
    rather than a second implementation of an argument that is easy to get subtly
    wrong. Everything the caller's docstring says about soundness — in particular
    that ``margin`` must be the MAXIMUM threshold any surviving pair could be
    compared against — is a property of THIS function and applies to every caller.

    ``keys`` is the deterministic tiebreak for boxes that start at the same
    inflated x; it needs only to be total, not meaningful.
    """
    order = sorted(range(len(boxes)),
                   key=lambda k: (boxes[k].min_x - margin, keys[k]))
    pairs: list[tuple[int, int]] = []
    active: list[tuple[float, int]] = []  # (inflated max_x, index)
    for oi in order:
        box = boxes[oi]
        lo_x = box.min_x - margin
        hi_x = box.max_x + margin
        lo_y = box.min_y - margin
        hi_y = box.max_y + margin
        active = [a for a in active if a[0] >= lo_x - EPS]
        for _a_hi, aj in active:
            b2 = boxes[aj]
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
            # Kind-ranked participant order (019f98b26f76): participants[0]
            # is the pad when a pad is involved, then via/hole/trace/zone —
            # never a coin-flip on two opaque content hashes. The dedupe key
            # and the lo|hi entity_id string ride the same order, so they
            # stay deterministic too.
            lo, hi = _ordered_pair(a, b, lambda p: p.kind)
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
                    # width_mm rides each participant (None for anything that
                    # is not a trace segment) so a clearance finding says what
                    # width the copper was modeled at. A clearance violation
                    # that is really a width mix-up — copper checked at the
                    # run's baseline instead of the width it was authored at —
                    # is otherwise indistinguishable from a real one, and
                    # diagnosing it meant re-deriving the overlay by hand.
                    extra={"participants": [
                        {"entity_id": lo.entity_id, "parent": lo.parent_id,
                         "kind": lo.kind, "net_id": lo.net_id,
                         "ref": lo.ref, "pad": lo.pad_number,
                         "net_name": lo.net_name, "width_mm": lo.width_mm},
                        {"entity_id": hi.entity_id, "parent": hi.parent_id,
                         "kind": hi.kind, "net_id": hi.net_id,
                         "ref": hi.ref, "pad": hi.pad_number,
                         "net_name": hi.net_name, "width_mm": hi.width_mm}]}))
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


def _hole_loop_clearance(cap: Capsule, loop: list[tuple[float, float]]
                         ) -> tuple[float, tuple[float, float], tuple[float, float]]:
    """(measured, hole_point, edge_point) between one bore capsule and a cutout
    vertex loop, SIGNED: negative means the bore has entered the opening.

    EXACT, and deliberately not the AABB treatment ``_aabb_loop_clearance``
    gives copper. A round bore's bounding square pokes out past the disc at every
    corner by r(sqrt2 - 1) — about 0.62 mm on a 3 mm mounting hole — so an AABB
    test near a cutout corner would report the bore inside the opening when it is
    not. For a CLEARANCE that is merely a conservative over-report, which is the
    fail-safe direction and why GC5 accepts it. For a CONTAINMENT refusal it is
    not acceptable in the same way: the finding asserts "this hole is drilled
    through air", and being wrong about that on a legal board is a bad enough
    claim to be worth the exact kernel. The capsule spine gives it for free —
    distance from the spine to the contour, minus the bore radius.

    The witness pair is midpoint-quality (the closest loop edge's nearest point
    to the spine's midpoint, and the bore-surface point facing it), the same
    fidelity GC5's rim and cutout witnesses carry. Only the MEASUREMENT has to
    be exact; the anchors are for rendering.
    """
    count = len(loop)
    spine_a, spine_b = (cap.ax, cap.ay), (cap.bx, cap.by)
    edges = tuple((loop[i], loop[(i + 1) % count]) for i in range(count))
    best_d, best_edge = None, edges[0]
    for edge in edges:
        d = segment_segment_distance(spine_a, spine_b, edge[0], edge[1])
        if best_d is None or d < best_d:
            best_d, best_edge = d, edge
    # INSIDE-NESS IS TESTED ON THE SPINE, not on the surface: a bore whose centre
    # line lies within the opening is inside it however small the bore is, and
    # the distance-to-contour then measures how DEEP it sits, which is the wrong
    # sign. Testing both endpoints covers a slot that enters the opening at one
    # end only.
    inside = (_point_in_loop(spine_a[0], spine_a[1], loop)
              or _point_in_loop(spine_b[0], spine_b[1], loop))
    signed = -best_d if inside else best_d
    centre = ((spine_a[0] + spine_b[0]) / 2.0, (spine_a[1] + spine_b[1]) / 2.0)
    (ax, ay), (bx, by) = best_edge
    dx, dy = bx - ax, by - ay
    seg_len2 = dx * dx + dy * dy
    t = 0.0 if seg_len2 == 0 else max(0.0, min(1.0, (
        (centre[0] - ax) * dx + (centre[1] - ay) * dy) / seg_len2))
    edge_pt = (ax + t * dx, ay + t * dy)
    span = math.hypot(edge_pt[0] - centre[0], edge_pt[1] - centre[1])
    if span <= EPS:
        hole_pt = centre
    else:
        hole_pt = (centre[0] + (edge_pt[0] - centre[0]) / span * cap.r,
                   centre[1] + (edge_pt[1] - centre[1]) / span * cap.r)
    return signed - cap.r, hole_pt, edge_pt


# GC11's two faults share one check but not one authority, and the count keys
# keep them apart so a consumer can tell a refusal from a tolerance.
GC11_CONTAINMENT = "gc11_hole_outside_board"
GC11_PROXIMITY = "gc11_hole_to_edge"


def _gc11_rows(hole: HolePrimitive, measured: float,
               hole_pt: tuple[float, float], edge_pt: tuple[float, float],
               floor: float | None, edge: str,
               against: str | None) -> list[dict]:
    """One measurement -> at most ONE finding, containment taking precedence.

    Never both: a bore that has left the board material has also, trivially,
    broken any proximity floor, and reporting the same geometry twice under two
    rule names makes a fault look like two faults."""
    extra = {"edge": edge}
    if against is not None:
        extra["against_entity_id"] = against
    if measured < -EPS:
        return [_finding(
            GC11_CONTAINMENT, hole.entity_id, hole.parent_id, hole.origin,
            hole.net_id, None, measured, 0.0,
            closest=list(hole_pt), witness=list(edge_pt), extra=extra,
            ref=hole.ref, pad=hole.pad_number, net_name=hole.net_name)]
    if floor is not None and _violates(measured, floor):
        return [_finding(
            GC11_PROXIMITY, hole.entity_id, hole.parent_id, hole.origin,
            hole.net_id, None, measured, floor,
            closest=list(hole_pt), witness=list(edge_pt), extra=extra,
            ref=hole.ref, pad=hole.pad_number, net_name=hole.net_name)]
    return []


def _check_gc11_hole_to_edge(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """GC11 — a drilled bore against the board rim and every cutout opening.

    SPLIT IN TWO, because the halves have different authority and collapsing
    them would have made the useful half hostage to a number nobody publishes:

      CONTAINMENT (``gc11_hole_outside_board``) — UNCONDITIONAL. A bore that
        crosses the outline or enters a cutout is nonsense at any floor value
        and needs no published figure to refuse. ``required`` is reported as 0.0,
        which is the literal rule: the bore must not leave the material.
      PROXIMITY (``gc11_hole_to_edge``) — gated on the OPTIONAL
        ``min_hole_to_edge_mm``. NO SHIPPED PROFILE DECLARES IT (JLCPCB's 2-layer
        page publishes no hole-to-edge minimum, and neither do the other two), so
        this half DOES NOT RUN on any fixture in the corpus. Stated here because
        a check that silently never fires reads exactly like one that always
        passes — the count key stays 0 and that 0 means "the profile said
        nothing", not "checked and clean".

    WHAT WAS FAIL-OPEN BEFORE THIS. Geometric DRC had no hole-to-edge class at
    all: GC5 measures COPPER to the edge, GC6 measures holes against each other,
    and the pour carve measures holes against copper. A drill placed inside a
    slot opening, or half off the rim, compiled, passed DRC clean, and emitted a
    drill file the fab would run.

    THE RULING THIS ENCODES, recorded so nobody later "fixes" it as a bug:
    CONTAINMENT PERMANENTLY FORECLOSES CASTELLATED AND MOUSE-BITE EDGE HOLES —
    the half-holes on a module's rim that are deliberately drilled ON the
    outline. Those are legitimate, common, and refused here. The justification is
    that the schema cannot express them: a hole is a bore at a point, with no
    field saying "this one is meant to be cut through", so an edge-crossing bore
    is indistinguishable from a misplaced one and the fail-closed reading is the
    only safe one. If castellations ever become authorable, they arrive as an
    explicit hole KIND and this check learns to exempt that kind — it must not
    be repaired by relaxing the geometry test, which would re-open the fault for
    every genuinely misplaced hole.

    RIM VS CUTOUT USE DIFFERENT KERNELS, and that asymmetry is deliberate. The
    rim is an axis-aligned rectangle, so a capsule's AABB is its EXACT extent and
    the four side insets are exact. A cutout is an arbitrary loop, where an AABB
    would over-report near corners; see :func:`_hole_loop_clearance`.
    """
    floor = rb.design_rules.minimums.min_hole_to_edge_mm
    ox, oy, width_mm, height_mm = outline_frame(rb.outline)
    ox2, oy2 = ox + width_mm, oy + height_mm
    cut_loops = cutout_point_loops(rb.outline)
    findings: list[dict] = []
    for hole in sorted(proj.holes, key=lambda h: h.entity_id):
        box = hole.aabb
        mid_y = (box.min_y + box.max_y) / 2.0
        mid_x = (box.min_x + box.max_x) / 2.0
        sides = (
            (box.min_x - ox, (box.min_x, mid_y), (ox, mid_y)),
            (ox2 - box.max_x, (box.max_x, mid_y), (ox2, mid_y)),
            (box.min_y - oy, (mid_x, box.min_y), (mid_x, oy)),
            (oy2 - box.max_y, (mid_x, box.max_y), (mid_x, oy2)),
        )
        measured, hole_pt, edge_pt = min(sides, key=lambda s: s[0])
        findings += _gc11_rows(hole, measured, hole_pt, edge_pt, floor,
                               "rim", None)
        for cut_id, loop in cut_loops:
            # WORST CAPSULE WINS. A routed slot is several capsules; taking the
            # first, or the centre, would clear a slot whose far leg runs into
            # the opening.
            best = None
            for cap in hole.capsules:
                row = _hole_loop_clearance(cap, loop)
                if best is None or row[0] < best[0]:
                    best = row
            if best is None:
                continue
            findings += _gc11_rows(hole, best[0], best[1], best[2], floor,
                                   "cutout", cut_id)
    return findings


# ---------------------------------------------------------------------------
# Result union.
# ---------------------------------------------------------------------------


## The narrowest overlap GC7 will call a violation, in nanometres.
##
## Narrower than this, an intersection is kernel noise rather than copper. In the
## COMMON case — a pour that authors no ``clearance_mm`` at all — the filler's
## carve and this check's requirement resolve to the identical number, so the two
## boundaries are mathematically coincident and the only thing separating them is
## integer rounding. The filler carves with ONE ``CT_DIFFERENCE`` against every
## inflated obstacle at once (``zone_fill._fill_one``), so wherever two obstacles'
## inflated bands overlap each other Clipper mints intersection vertices snapped
## to the 1 nm grid; this check intersects one obstacle at a time against a
## ``SimplifyPolygons``'d fill, which snaps again, as do ``_fracture``'s keyhole
## slits. MEASURED on smart-remote-v2: slivers of 1,858 to 24,927 nm^2 along one
## via-plus-trace run, reported as three clearance violations that do not exist
## and blocking promote on a correctly carved board (docket 01a02873cad3).
##
## TWICE THE WIDEST PHANTOM EVER MEASURED, which is not the same as twice the
## coordinate quantum, and the difference matters. The tempting derivation is
## that a vertex snapped to the 1 nm grid moves either boundary by at most half a
## quantum, so coincident boundaries separate by at most 1 nm. THAT BOUND IS
## FALSE, and it was in this comment until measurement contradicted it: there is
## more than one rounding stage (the filler's ``CT_DIFFERENCE``, the float-mm
## round trip through ``PolygonGeometry``, ``SimplifyPolygons``, ``_fracture``'s
## keyhole slits, then this check's own ``CT_INTERSECTION``) and they do not
## cancel.
##
## WHAT WAS ACTUALLY MEASURED. Phantom width reaches 2 nm. A bend-only sweep of
## 60 arrangements (trace widths 0.15-1.2 mm; orthogonal bends, chevrons,
## zigzags, U-turns, sawtooth, with and without vias) never exceeded 1 nm and
## made the false bound look confirmed; ROTATED PADS, the arrangement class that
## sweep omitted, reach 2 nm routinely — found across ~800 further boards of
## grazing pad pairs at odd rotations, sub-micrometre jitter, and coordinates out
## to 70 mm. Bends mint the phantoms where two obstacles' inflated bands overlap
## each other; a via AT a bend swallows the join region and yields nothing.
##
## SO 4, NOT 2. At 2 the guard sat exactly on the measured maximum: it worked
## only because ``_is_sliver``'s predicate is strictly-wider-than (a band of
## width exactly W is annihilated by deflating W/2 from each side), leaving no
## headroom at all — one more rounding stage in some future kernel or fill path
## and the promote-blocking phantoms return. 4 buys one full quantum of margin
## and costs nothing: the smallest genuine under-carve under test is 50 nm, still
## 12.5x above it, and the threshold kill-mutations above it still hold.
##
## NOT derived from the arc tolerance, which was the first proposal. Arc
## tolerance CANCELS: both sides flatten round joins through the same
## ``ARC_TOLERANCE_NM``, so it says nothing about how far the boundaries drift.
## A 5,000 nm guard would swallow both nanometre-scale under-carves pinned here
## (50 nm and 100 nm) and leave only 30x under the 0.15 mm one — which does still
## fire at that threshold, so the coarse case alone never discriminated. It would
## also HIDE those constants drifting apart, the one change that WOULD
## reintroduce genuine approximation error.
GC7_SLIVER_WIDTH_NM = 4


def _is_sliver(pyclipper, overlap) -> bool:
    """True when ``overlap`` is nowhere WIDER than ``GC7_SLIVER_WIDTH_NM``.

    Strictly wider, and the boundary case is worth naming because the threshold's
    margin depends on it: deflating ``W/2`` from every side annihilates a band of
    width exactly ``W``, so a band of exactly the threshold is culled, not kept.

    A WIDTH test, not an area test, because a real under-carve is a long thin
    band too: area alone cannot separate a 10 mm run of 1 nm noise from a 10 um
    run of 100 nm copper, and any area threshold that killed the first would
    have to be tuned against the second. Width is the same question at every
    length.

    Asked the way the filler already asks it (``zone_fill._survives_deflation``):
    deflate by half the floor from every side and see whether anything survives.
    The whole solution goes in with its orientations intact, so a ring of overlap
    around a void deflates from both boundaries and is not mistaken for solid.
    """
    from .zone_fill import ARC_TOLERANCE_NM, MITER_LIMIT  # noqa: PLC0415

    offset = pyclipper.PyclipperOffset()
    offset.MiterLimit = MITER_LIMIT
    offset.ArcTolerance = ARC_TOLERANCE_NM
    offset.AddPaths(overlap, pyclipper.JT_ROUND, pyclipper.ET_CLOSEDPOLYGON)
    return not offset.Execute(-GC7_SLIVER_WIDTH_NM / 2.0)


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

    IT IS LARGELY CIRCULAR, AND THAT IS WHY THE SLIVER GUARD EXISTS. The obvious
    objection to checking a fill we computed is that we would be asking the
    filler whether it obeyed itself, and mostly we are: ``zone_fill._clearance_mm``
    resolves the SAME max() of the zone's authored clearance, the board minimum
    and both nets' class minima that ``_effective_min_clearance`` resolves here,
    and says so in its own docstring. An earlier version of this paragraph
    claimed a zone authoring below what its net class demands would fill happily
    and be caught here. It cannot — the filler folds the class minima in too, so
    that case never reaches this check. The claim was false when written and is
    recorded here rather than deleted, because believing it is what let the
    coincident-boundary bug (docket 01a02873cad3) ship.

    WHAT IS GENUINELY LEFT TO CATCH, none of it nothing: a zone that authors a
    clearance below the GLOBAL minimum with no class to rescue it, where the
    filler honours the author's number and this check does not; a fill handed to
    us by a foreign tool, since ``ResolvedZone.fill`` is public IR that nothing
    forces us to have computed; and any future filler bug that carves less than
    it resolved, the documented layer-namespace fail-open in
    ``zone_fill._obstacle_paths`` being the one we have already seen. In practice
    every one of those is MACROSCOPIC — a band as wide as the deficit, or a whole
    pad — which is what makes a nanometre-scale guard safe.

    WHERE THAT ARGUMENT THINS, stated rather than glossed. It rests on the
    encroachment being as WIDE as it is deep, which holds for anything the filler
    produces and for any deficit an author can plausibly write, but is not a
    theorem: a spike 4 nm across at its base and micrometres deep would be culled,
    because nothing here guards penetration DEPTH. Two cases can reach that shape.
    A foreign tool's fill is arbitrary geometry and is not width-screened —
    ``zone_fill._cull_or_refuse_unfabricable_regions`` runs inside our filler only. And an
    author may write a deficit that is itself sub-threshold (``0.199998`` against
    a 0.2 mm minimum is a representable 2 nm breach, and is masked). Neither is
    worth widening the check for — sub-grid copper is not fabricable and a 2 nm
    deficit is not a rule anyone is relying on — but neither is covered by the
    word "macroscopic", so it does not stand unqualified.

    Exact integer arithmetic via the same kernel that computed the fill: inflate
    each foreign primitive by the required clearance and intersect with the pour.
    An intersection anywhere WIDER than ``GC7_SLIVER_WIDTH_NM`` means copper is
    closer than the rule allows.

    The independent judge for the fill's SHAPE is the pcbnew oracle
    (tests/oracle/zone_fill_oracle.py), not this.
    """
    zones = [z for z in rb.zones
             if z.kind is ZoneKind.COPPER_POUR and z.fill]
    if not zones:
        return []

    # The OFFSET CONSTANTS COME FROM THE FILLER, they are not restated here.
    # This check inflates foreign copper with the same flattening the filler used
    # to carve around it; if the two ever differed, the boundaries would separate
    # by approximation error and every default pour would report violations. They
    # were hardcoded as a literal ``(2.0, 5000)`` until docket 01a02873cad3.
    from .zone_fill import (  # noqa: PLC0415
        ARC_TOLERANCE_NM,
        MITER_LIMIT,
        NM_PER_MM,
        _capsule_ring,
        _rect_ring,
    )

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

            offset = pyclipper.PyclipperOffset(MITER_LIMIT, ARC_TOLERANCE_NM)
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
            if not overlap or _is_sliver(pyclipper, overlap):
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


# GC12 — trace DIRECTION. Absent by default; see _check_gc12_trace_direction.
GC12_DIRECTION = "gc12_trace_direction"

## How far off-axis a segment may sit, measured as the PERPENDICULAR DEVIATION
## of its far end from the allowed direction through its near end, in mm.
##
## A perpendicular distance rather than an angle, deliberately. An angular
## tolerance is scale-dependent: the same 0.1 um of coordinate quantization is
## 0.0036 deg across a 1.6 mm run and 0.057 deg across a 0.1 mm one, so any
## single angle either fails short conforming segments or passes long
## near-diagonal ones. A distance is the same rule at every length, and it is
## the quantity a fab cares about anyway.
##
## The value is the coincidence epsilon the connectivity kernel already uses
## (drc.COPPER_COINCIDENT_EPS_MM), for one derivation and because it sits an
## order of magnitude above the 0.1 um emit grid: a segment authored on-axis
## and round-tripped through float32 cannot drift into a finding.
GC12_AXIS_TOLERANCE_MM = 1e-3


def _check_gc12_trace_direction(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    """GC12 — every trace segment runs in one of the directions the board allows.

    ABSENT BY DEFAULT, and gated on BOARD state
    (``design_rules.allowed_trace_angles_deg``) rather than on a rule profile.
    A profile records what a board HOUSE publishes; no house requires
    orthogonal routing. Manhattan is a design style its author chose, and
    asserting it as a fab capability would be inventing a rule.

    WHAT IT CATCHES, and why nothing else did. smart-remote-v2 is routed
    Manhattan by an external router, and no rule in this module expresses
    direction: a 45-degree stub and a 0.9-degree-off-vertical segment both pass
    GC1-GC11 completely clean. The 0.9-degree case is the one that matters —
    0.025 mm of drift over a 1.6 mm run, invisible at any zoom, and it reached
    the board.

    FAIL DIRECTION, per this module's cardinal rule: a borderline segment
    produces a SPURIOUS FINDING, never a missed diagonal. The tolerance is
    tight enough (1 um perpendicular) that no real diagonal can hide under it,
    and an author who dislikes a marginal finding can move the segment; an
    author who never learns about a diagonal cannot do anything at all.

    NOTE ON THE FINDING SHAPE: this is the module's only CEILING rule, so
    ``required_mm`` here is the maximum allowed deviation, not a minimum. The
    angles in ``measured_angle_deg`` / ``nearest_allowed_angle_deg`` are the
    legible half and the reason the finding carries them.

    THE FRAME THE ANGLES ARE IN. An allowed entry is a direction measured from
    +X toward +Y in the BOARD's own millimetre frame, which is y-DOWN -- the
    frame every ``x_mm``/``y_mm`` in the source uses. On screen the angle
    therefore sweeps clockwise, and 45 names the down-and-right diagonal.

    Both sides of the comparison below are taken in that one frame and folded
    the same way: the allowed direction becomes ``u = (cos a, sin a)`` straight
    off the stored degrees, and the segment's own heading is
    ``atan2(dy, dx) mod 180`` off the raw deltas. NEITHER IS NEGATED, and the
    check is self-consistent for an asymmetric set as much as for a symmetric
    one -- a board declaring only 30 passes a run heading 30 and flags one
    heading 150. Manhattan and octilinear happen to be closed under the y-flip,
    so for them the frame is invisible; this paragraph is what tells a reader
    which way an asymmetric set leans. The panel's Trace-tool snap folds
    identically (``pcb/ui/model/pcb_trace_angles.gd``), on this same tolerance,
    so a run the tool draws is a run this check passes.
    """
    allowed = rb.design_rules.allowed_trace_angles_deg
    if not allowed:
        return []
    findings: list[dict] = []
    for prim in proj.copper:
        if prim.kind != "trace_seg":
            continue
        shape = prim.shape
        ax, ay, bx, by = shape.ax, shape.ay, shape.bx, shape.by
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        if length <= GC12_AXIS_TOLERANCE_MM:
            # Shorter than the tolerance in every direction at once, so it has
            # no direction to be wrong about. A segment this short is GC1/S7's
            # problem, not this rule's.
            continue
        best_dev = None
        best_angle = 0.0
        for angle in allowed:
            radians = math.radians(angle)
            # Perpendicular deviation of the far end from the allowed direction
            # through the near end: |d x u|, u a unit vector along the axis.
            deviation = abs(dx * math.sin(radians) - dy * math.cos(radians))
            if best_dev is None or deviation < best_dev:
                best_dev = deviation
                best_angle = angle
        if best_dev is not None and _exceeds(best_dev, GC12_AXIS_TOLERANCE_MM):
            # The segment's own heading, folded to [0, 180) the same way the
            # allowed set is, so the two are directly comparable by eye.
            measured_angle = math.degrees(math.atan2(dy, dx)) % 180.0
            findings.append(_finding(
                GC12_DIRECTION, prim.entity_id, prim.parent_id, prim.kind,
                prim.net_id, prim.layers[0] if prim.layers else None,
                best_dev, GC12_AXIS_TOLERANCE_MM,
                closest=[ax, ay], witness=[bx, by],
                midpoint=[(ax + bx) / 2.0, (ay + by) / 2.0],
                extra={
                    "measured_angle_deg": round(measured_angle, 6),
                    "nearest_allowed_angle_deg": round(best_angle, 6),
                    "allowed_angles_deg": list(allowed),
                },
                ref=prim.ref, pad=prim.pad_number, net_name=prim.net_name))
    return findings


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


# The zero-initialised keys of the result's ``counts`` map. EVERY check must be
# listed here, including one that finds nothing.
#
# WHY THAT IS LOAD-BEARING AND NOT BOOKKEEPING (swept once in epoch CP2 S4, on
# behalf of stations S5-S8, which add gc8..gc11 between them):
#
# The counting loop below is `counts[f["type"]] = counts.get(f["type"], 0) + 1`.
# That `.get` fallback means a check MISSING from this tuple still counts its
# findings correctly — so the omission is invisible on a violating board and
# shows up only on a CLEAN one, where the key is absent instead of zero. A
# consumer then cannot distinguish "this check ran and found nothing" from
# "this check did not run", which is the cardinal rule's false-clean shape
# wearing a different hat. Adding a check without adding its key here is
# therefore a real defect, not a cosmetic one, and it is one that a clean-board
# test would pass straight through.
#
# THE CONSUMER SWEEP the S4 brief asked for, done once here rather than four
# times later. Result: NOTHING outside this module enumerates gc keys.
#   * The Go bridge (pcb/internal/tools/worker_tools.go) forwards the worker's
#     JSON VERBATIM; its only mention of counts is prose in a tool description.
#   * pcb/main_test.go touches counts solely to DISCRIMINATE the connectivity
#     shape (wrong_net_pad) from the geometric one — it does not enumerate gc
#     keys and is unaffected by new ones.
#   * The Godot UI (pcb/ui/*.gd) references no gc key at all.
#   * The GD surface test (pcb/tests/gd/test_geometric_drc_surface.gd) uses
#     synthetic counts payloads, not real key names.
# So S5-S8 need to touch exactly ONE place — this tuple — and no downstream
# consumer requires a coordinated change.
_COUNT_KEYS = (
    "gc1_trace_width", "gc2_copper_clearance", "gc3_drill", "gc3_finished_hole",
    "gc4_annular_ring", "gc5_copper_to_edge", "gc6_hole_to_hole",
    "gc7_zone_clearance",
    "gc8_mask_sliver",          # CP2 S5 — min_mask_sliver_mm's first reader
    # CP2 S6 — silkscreen DFM. Both floors are OPTIONAL-tier, so these stay 0
    # under a profile that publishes no silk rule; that is "the profile said
    # nothing", not "checked and clean". `gc9_silk_indeterminate` is the
    # dropped-artwork row and carries NO measurement by design.
    "gc9_silk_width",
    "gc9_silk_to_pad",
    "gc9_silk_indeterminate",
    # CP2 S7 — hole-to-copper. OPTIONAL-tier floor, so this stays 0 under a
    # profile that publishes no PTH-to-track figure; that is "the profile said
    # nothing", not "checked and clean".
    "gc10_hole_to_copper",
    # CP2 S8 — hole-to-edge, in TWO keys because the two faults have different
    # authority. Containment is unconditional; proximity is gated on the
    # OPTIONAL min_hole_to_edge_mm, which NO shipped profile declares, so that
    # key stays 0 on every board in the corpus — "the profile said nothing".
    GC11_CONTAINMENT,
    GC11_PROXIMITY,
    # SR2FAB S11 — trace direction. Gated on BOARD state, not on a profile, and
    # absent by default, so this key stays 0 unless the board asked for it. The
    # `not_evaluated` list says which of those two a 0 means.
    GC12_DIRECTION,
)


# Which count keys are governed by an OPTIONAL-tier profile floor, and by which
# field. A floor the selected profile does not declare means its rule was NOT
# EVALUATED on this board — and the count key for it stays 0, which is
# indistinguishable from "checked and clean" to anything reading the result.
# Three separate comments in this module already say so in prose that a
# result-reader never sees (GC9's, GC10's and GC11's docstrings); this is the
# same fact where the reader is.
#
# ``scope`` is present when the floor gates only PART of the named check. GC3
# still runs on every hole against the general drill floor; what an absent
# feature-specific floor means there is that one FEATURE CLASS went unmeasured,
# which is a narrower claim than "the check did not run".
#
# solder_mask_expansion_mm is deliberately absent from this table. It has no
# reader at all (it was demoted out of the required tier for exactly that
# reason), so listing it would imply a check that does not exist — the same
# false impression this table is here to remove, pointed the other way.
_OPTIONAL_FLOOR_READERS: tuple[tuple[str, str, str], ...] = (
    ("gc9_silk_width", "min_silk_width_mm", ""),
    ("gc9_silk_to_pad", "min_silk_to_pad_mm", ""),
    ("gc10_hole_to_copper", "min_hole_to_copper_mm", ""),
    (GC11_PROXIMITY, "min_hole_to_edge_mm", ""),
    ("gc3_drill", "min_npth_mm", "non-plated round holes"),
    ("gc3_drill", "min_plated_slot_mm", "plated slots"),
    ("gc3_drill", "min_npth_slot_mm", "non-plated slots"),
)


def _not_evaluated(rb: ResolvedBoard) -> list[dict]:
    """The rules the selected profile published no floor for, named.

    Without this a caller sees a count of 0 and cannot tell a rule that was
    measured and found clean from one that was never measured. Both of the
    shipped non-JLCPCB profiles are silent about silk and hole-to-copper, and
    oshpark-2layer is silent BY DESIGN (OSH Park publishes no such figure), so
    the ambiguity is permanent for them rather than a gap to be filled in later
    by declaring more numbers.
    """
    minimums = rb.design_rules.minimums
    rows: list[dict] = []
    for check, floor_field, scope in _OPTIONAL_FLOOR_READERS:
        if getattr(minimums, floor_field, None) is not None:
            continue
        row = {"check": check, "floor": floor_field,
               "reason": f"the selected rule profile declares no {floor_field}"}
        if scope:
            row["scope"] = scope
        rows.append(row)
    # GC12 is gated on BOARD state rather than on a profile floor, but its zero
    # is ambiguous in exactly the same way, so it belongs in the same list.
    if not rb.design_rules.allowed_trace_angles_deg:
        rows.append({
            "check": GC12_DIRECTION,
            "floor": "design_rules.allowed_trace_angles_deg",
            # The reason names the FULL path, matching `floor`: a reader has to
            # be able to go and look at the thing that is missing, and
            # "allowed_trace_angles_deg" alone does not say where it lives.
            "reason": "this board declares no design_rules.allowed_trace_angles_deg, "
                      "so it asked for no direction constraint",
        })
    return rows


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
        # Ordered with the copper/hole checks rather than in numeric position:
        # it consumes only `copper` + `holes`, so it must not sit behind the
        # mask-projection refusal below, which is about a different family.
        findings += _check_gc10_hole_to_copper(proj, rb)
        findings += _check_gc11_hole_to_edge(proj, rb)
        # Copper-only like the two above, so it runs before the mask-projection
        # refusal below rather than behind it.
        findings += _check_gc12_trace_direction(proj, rb)

        # GC8 CONSUMES THE MASK PROJECTION, so it must first refuse to run on a
        # KNOWN-INCOMPLETE aperture set. `mask_indeterminate` names entities
        # whose openings could not be determined (S4); computing a sliver
        # verdict without them would search fewer pairs and report fewer
        # slivers, which reads as a healthier board — the false clean this
        # field was added to prevent.
        #
        # The refusal is WHOLESALE here rather than mask-scoped, and that is a
        # deliberate, narrow reading of the S4 obligation: this result envelope
        # has one `verdict` for all checks and no per-check scoping, so there is
        # no way to say "gc1-gc7 ran, gc8 did not" without inventing a shape the
        # Go bridge and the panel do not consume. Refusing everything is honest
        # and safe; claiming a clean board while one check silently sat out is
        # neither. If per-check scoping ever exists, narrow this.
        if proj.mask_indeterminate:
            entity, reason = proj.mask_indeterminate[0]
            return _indeterminate(
                "unsupported_geometry",
                f"mask coverage is undetermined for {len(proj.mask_indeterminate)} "
                f"entity/entities (first: {entity} — {reason}), so the mask "
                f"sliver check (GC8) cannot run and no geometric verdict is given")
        findings += _check_gc8_mask_sliver(proj, rb)
        # ADVISORY channel, kept OUT of `findings` so `verdict` keeps meaning
        # exactly what it means today: blocking violations only. Silk is
        # cosmetic (fab_capability's ratified rule), and a legend rule that
        # refused 15 of the 17 silk-carrying stock footprints would be an
        # outage, not a check.
        #
        # SCOPED TRY, added in CP2 (Codex finding 5). GC9 used to run inside the
        # broad try below, so a crash while measuring COSMETIC legend artwork
        # returned a whole-run indeterminate and threw away GC1-GC8/GC10/GC11
        # findings that had already been computed correctly. That is fail-closed
        # in the sense that it never claims clean — but it directly contradicts
        # the "silk is warned, never fatal" rule this check was built under, and
        # it loses real blocking violations to a cosmetic bug.
        #
        # A crash therefore becomes a check-scoped advisory instead. The row is
        # the SAME `gc9_silk_indeterminate` type the per-graphic drop path
        # already emits, because a consumer's question is identical in both
        # cases: which legend artwork went unmeasured, and why.
        #
        # WHAT THIS MUST NOT DO, and does not: manufacture a clean GC9 result.
        # gc9_silk_width / gc9_silk_to_pad simply do not appear, and the
        # indeterminate row is the positive statement that they did not run.
        # Reading a zero count as "checked and clean" was already wrong under
        # the optional-floor semantics recorded at _COUNT_KEYS; this row makes
        # the distinction visible rather than inferable.
        try:
            advisories = _check_gc9_silk(proj, rb)
        except Exception as exc:  # noqa: BLE001 - cosmetic check, never fatal.
            advisories = [{
                "type": "gc9_silk_indeterminate",
                "entity_id": "<gc9>",
                "parent": None, "kind": "silk", "net_id": None, "layer": None,
                "ref": None, "pad": None, "net_name": None,
                "measured_mm": None, "required_mm": None,
                "code": "gc9_raised",
                "detail": f"silkscreen DFM check raised {exc!r}",
                "note": ("GC9 did not run, so NO silk width or silk-to-pad "
                         "measurement was made on this board — a zero count "
                         "for those rules here means 'not checked', not "
                         "'clean'. The blocking verdict beside this row is "
                         "unaffected: it comes from GC1-GC8/GC10/GC11, which "
                         "completed."),
            }]
    except UnsupportedGeometry as exc:
        return _indeterminate("unsupported_geometry", str(exc))
    except Exception as exc:  # noqa: BLE001 - fail-closed: a crash is NOT a clean.
        return _indeterminate("internal", f"geometric DRC raised {exc!r}")

    # Advisories are COUNTED like findings (so a thin legend is never invisible)
    # but excluded from `findings` and therefore from `verdict`.
    counts = {key: 0 for key in _COUNT_KEYS}
    for f in findings + advisories:
        counts[f["type"]] = counts.get(f["type"], 0) + 1

    profile = rb.design_rules.rule_profile
    return {
        "ok": True,
        "scope": "geometric",
        "verifies_geometry": True,
        # UNCHANGED SEMANTICS, deliberately: `verdict` still reflects blocking
        # violations only. Adding cosmetic silk rows to it would have flipped
        # essentially every real board to "violations" (15 of the 17 stock seed
        # footprints draw silk below JLCPCB's published 0.15 minimum), which is
        # an outage dressed as a DFM check.
        "verdict": "violations" if findings else "clean",
        "board_id": rb.id,
        "source_digest": rb.provenance.source_digest,
        "rule_profile": {
            "id": profile.id,
            "version": profile.version,
            "digest": profile.digest,
        },
        "findings": findings,
        # NEW KEY (epoch CP2 S6), and additive on purpose. A consumer that does
        # not know about it behaves exactly as it did before — no false
        # blocking, no mis-rendered severity. That is why the cosmetic rows went
        # into a new key rather than into `findings` with a severity flag: the
        # Go bridge forwards this JSON verbatim and the panel renders findings
        # as problems, so a flag would have had to be understood everywhere to
        # avoid harm, whereas an unknown key is simply ignored.
        "advisories": advisories,
        "counts": counts,
        # ADDITIVE, same reasoning as `advisories` above: a consumer that does
        # not know the key behaves exactly as before. Every row here names a
        # count in `counts` whose 0 means "not measured" rather than "clean" —
        # the one thing a reader could not previously tell.
        "not_evaluated": _not_evaluated(rb),
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
