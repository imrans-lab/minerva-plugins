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

C1 CHECK SET (per-entity + hole-to-hole):
  * GC1 min trace width      — every trace segment width  >= min_trace_width_mm.
  * GC3 drill / finished hole — every drill feature minor  >= min_drill_mm;
                                plated holes also          >= min_finished_hole_mm.
  * GC4 annular ring          — PTH pads + vias + plated board holes: copper web
                                from drill boundary to land boundary
                                >= min_annular_ring_mm.
  * GC6 hole-to-hole          — edge-to-edge between all drill/hole features
                                >= min_hole_to_hole_mm.
GC2 (copper-copper clearance) and GC5 (copper-to-edge) are DEFERRED to C2 — see
the TODO hooks in :func:`run_geometric_drc`. They are NOT implemented here and
this result must not be read as certifying them.

DRY — the copper LAND owner
---------------------------
The copper-land shape of a through-hole pad is NOT reinterpreted here. It comes
from the SAME neutral owner the CAM emitters use — ``pad_source.placed_pad_to_geom``
+ ``pad_source.th_land`` — so fabricated copper (CAM) and checked copper (DRC)
cannot drift (docket finding 019f8b7fd295, mandated by Codex #3). See
``_pad_land`` for the call site.

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

from .drc_geom_primitives import (
    AABB,
    Capsule,
    OrientedRect,
    aabb_union,
    capsule_edge_distance,
    capsule_edge_witness,
)
from .pad_source import placed_pad_to_geom, th_land
from .resolved_board import (
    Diagnostic,
    LayerRole,
    OvalHole,
    RectOutline,
    ResolutionFailure,
    ResolutionResult,
    ResolutionSuccess,
    ResolvedBoard,
    RoundHole,
    SlotHole,
)

# Numerical slack for threshold comparisons (mm). A measurement within EPS of a
# floor PASSES (exact-at-threshold is compliant) — the geometry is already biased
# conservative, so this is float-noise slack only. See drc_geom_primitives.EPS.
EPS = 1e-9


class UnsupportedGeometry(Exception):
    """Raised inside the projection when the kernel meets geometry it cannot model
    faithfully — caught by :func:`run_geometric_drc` and turned into the
    INDETERMINATE envelope rather than a (potentially false) clean."""


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


@dataclass(frozen=True)
class LandDisc:
    kind: str                      # round|rect
    dia_mm: float | None = None    # round land diameter
    w_mm: float | None = None      # rect land width
    h_mm: float | None = None      # rect land height

    def min_reach(self) -> float:
        """Smallest copper reach from the land centre to its boundary — the nearest
        edge. For a round land, the radius; for a rectangle, half its MINOR side
        (a roundrect's mid-edge is unaffected by its corners, so this stays exact
        for the nearest edge, and conservative elsewhere)."""
        if self.kind == "round":
            return (self.dia_mm or 0.0) / 2.0
        return min(self.w_mm or 0.0, self.h_mm or 0.0) / 2.0


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


def _pad_land(pad, number: str, ref: str) -> tuple[LandDisc, Any]:
    """The copper LAND of a through-hole pad — resolved through the NEUTRAL OWNER
    (``placed_pad_to_geom`` + ``th_land``), NOT reinterpreted here. This is the DRY
    call site mandated by Codex #3: the CAM emitters shape the exact same land, so
    fabricated and checked copper cannot drift.

    Returns ``(LandDisc, shape)`` where ``shape`` is the exact/superset geometry
    primitive for the (C2) clearance checks. Raises :class:`UnsupportedGeometry`
    for a land the owner cannot classify into a modelable family — fail-closed
    rather than guess."""
    geom = placed_pad_to_geom(pad, number)
    shaped, shape_token, w, h, _rr = th_land(geom)
    angle = math.radians(pad.rotation_deg)
    if not shaped:
        # Round annulus: the neutral owner exposes the land DIAMETER as PadGeom.annulus.
        dia = geom.annulus
        if dia is None or not math.isfinite(dia) or dia <= 0:
            raise UnsupportedGeometry(
                f"pad {ref}.{number}: through-hole land has no usable round-annulus "
                f"diameter from the neutral owner (annulus={dia!r})")
        land = LandDisc(kind="round", dia_mm=float(dia))
        shape = Capsule.disc(pad.position[0], pad.position[1], float(dia) / 2.0)
        return land, shape
    # Shaped land (oblong / authored-cornered rect / roundrect). rect + roundrect
    # are modeled by the bounding oriented rectangle (superset of copper);
    # anything else the owner would have failed upstream.
    if shape_token not in ("rect", "roundrect", "oval"):
        raise UnsupportedGeometry(
            f"pad {ref}.{number}: through-hole land shape {shape_token!r} has no "
            f"modelable copper primitive")
    land = LandDisc(kind="rect", w_mm=float(w), h_mm=float(h))
    shape = OrientedRect(pad.position[0], pad.position[1],
                         float(w) / 2.0, float(h) / 2.0, angle)
    return land, shape


def _smd_shape(pad, number: str, ref: str) -> Any:
    geom = placed_pad_to_geom(pad, number)
    w, h = geom.width, geom.height
    if w is None or h is None:
        # A sizeless SMD pad should never reach the IR (compiler fail-closes), but
        # be defensive rather than emit copper we cannot model.
        raise UnsupportedGeometry(
            f"pad {ref}.{number}: SMD pad has no copper size in the IR")
    angle = math.radians(pad.rotation_deg)
    if geom.shape == "circle":
        return Capsule.disc(pad.position[0], pad.position[1], float(w) / 2.0)
    return OrientedRect(pad.position[0], pad.position[1],
                        float(w) / 2.0, float(h) / 2.0, angle)


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

    for comp in rb.components:
        for pad in comp.placed_pads:
            number = pad.source_id
            is_drilled = pad.drill is not None
            # A pad participates on the copper layers flagged in pad.layers; a
            # through-hole pad spans ALL copper layers regardless.
            pad_copper = tuple(
                layer.id for layer in pad.layers if layer.role is LayerRole.COPPER)
            if is_drilled:
                layers = all_copper
                land, shape = _pad_land(pad, number, comp.ref)
                copper.append(CopperPrimitive(
                    entity_id=pad.id, parent_id=comp.id, kind="pth_pad",
                    layers=layers, net_id=pad.net_id, shape=shape,
                    aabb=_shape_aabb(shape)))
                drill = _drill_disc_from_size(pad.drill.size)
                holes.append(_hole_from_drill(
                    pad.id, comp.id, "pad", pad.net_id, pad.drill.plated,
                    pad.position, drill, pad.rotation_deg))
                # Annular ring: PLATED through-hole pads only.
                if pad.pad_type != "np_thru_hole":
                    annular.append(AnnularEntity(
                        entity_id=pad.id, parent_id=comp.id, kind="pth_pad",
                        net_id=pad.net_id,
                        per_layer=tuple((lid, land) for lid in layers),
                        drill=drill, position=pad.position))
            else:
                shape = _smd_shape(pad, number, comp.ref)
                copper.append(CopperPrimitive(
                    entity_id=pad.id, parent_id=comp.id, kind="smd_pad",
                    layers=pad_copper or all_copper[:1], net_id=pad.net_id,
                    shape=shape, aabb=_shape_aabb(shape)))

    for trace in rb.traces:
        for seg in trace.segments:
            cap = Capsule(seg.a[0], seg.a[1], seg.b[0], seg.b[1], seg.width_mm / 2.0)
            copper.append(CopperPrimitive(
                entity_id=seg.id, parent_id=trace.id, kind="trace_seg",
                layers=(seg.layer.id,), net_id=trace.net_id, shape=cap,
                aabb=cap.aabb(), width_mm=seg.width_mm))

    for via in rb.vias:
        span = _via_span_layers(rb, via)
        cap = Capsule.disc(via.position[0], via.position[1], via.diameter_mm / 2.0)
        copper.append(CopperPrimitive(
            entity_id=via.id, parent_id=None, kind="via", layers=span,
            net_id=via.net_id, shape=cap, aabb=cap.aabb()))
        drill = DrillDisc(kind="round", dia_mm=via.drill_mm)
        holes.append(_hole_from_drill(
            via.id, None, "via", via.net_id, True, via.position, drill, 0.0))
        # Per-layer padstack land when present, else the via diameter on each
        # participating copper layer.
        per_layer = _via_per_layer_lands(via, span)
        annular.append(AnnularEntity(
            entity_id=via.id, parent_id=None, kind="via", net_id=via.net_id,
            per_layer=per_layer, drill=drill, position=via.position))

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
                     rotation_deg: float) -> HolePrimitive:
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
        aabb=cap.aabb())


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


def _check_gc1_trace_width(proj: Projection, rb: ResolvedBoard) -> list[dict]:
    required = rb.design_rules.minimums.min_trace_width_mm
    findings: list[dict] = []
    for prim in proj.copper:
        if prim.kind != "trace_seg" or prim.width_mm is None:
            continue
        if _violates(prim.width_mm, required):
            shape = prim.shape
            mid = ((shape.ax + shape.bx) / 2.0, (shape.ay + shape.by) / 2.0)
            findings.append(_finding(
                "gc1_trace_width", prim.entity_id, prim.parent_id, prim.kind,
                prim.net_id, prim.layers[0] if prim.layers else None,
                prim.width_mm, required,
                closest=[shape.ax, shape.ay], witness=[shape.bx, shape.by],
                midpoint=list(mid)))
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
                closest=list(hole.position), witness=list(hole.position)))
        # min_finished_hole_mm — plated (finished) hole floor — plated only.
        elif hole.plated and _violates(hole.minor_mm, mins.min_finished_hole_mm):
            findings.append(_finding(
                "gc3_finished_hole", hole.entity_id, hole.parent_id, hole.origin,
                hole.net_id, None, hole.minor_mm, mins.min_finished_hole_mm,
                closest=list(hole.position), witness=list(hole.position)))
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
                    closest=list(ent.position), witness=list(ent.position)))
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
                           "origins": [h1.origin, h2.origin]}))
    return findings


# ---------------------------------------------------------------------------
# Result union.
# ---------------------------------------------------------------------------


def _finding(rule: str, entity_id: str, parent: str | None, kind: str,
             net_id: str | None, layer: str | None,
             measured: float, required: float, *,
             closest: list, witness: list,
             midpoint: list | None = None, extra: dict | None = None) -> dict:
    out = {
        "type": rule,
        "entity_id": entity_id,
        "parent": parent,
        "kind": kind,
        "net_id": net_id,
        "layer": layer,
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
    "gc1_trace_width", "gc3_drill", "gc3_finished_hole",
    "gc4_annular_ring", "gc6_hole_to_hole",
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
        if not isinstance(rb.outline, RectOutline):
            return _indeterminate(
                "unsupported_geometry",
                "geometric DRC v1 models a rectangular (RectOutline) board only; "
                f"got {type(rb.outline).__name__}")
        if rb.zones:
            # The compiler rejects non-empty zones today; if a future IR carries an
            # (unfilled) copper zone, geometric DRC must be indeterminate, not
            # ignore it (spec §4).
            return _indeterminate(
                "unsupported_geometry",
                "geometric DRC v1 does not model copper zones/pours")

        proj = project_board(rb)

        findings: list[dict] = []
        findings += _check_gc1_trace_width(proj, rb)
        findings += _check_gc3_drill(proj, rb)
        findings += _check_gc4_annular(proj, rb)
        findings += _check_gc6_hole_to_hole(proj, rb)
        # TODO(C2): GC2 copper-copper same-layer clearance (needs the per-layer
        #           spatial broad phase + rect/capsule edge distances).
        # TODO(C2): GC5 copper-to-edge clearance against the RectOutline.
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
        return _indeterminate(
            "parse",
            "board failed to compile to a ResolvedBoard",
            diagnostics=[_diag_dict(d) for d in result.diagnostics])
    if isinstance(result, ResolutionSuccess):
        warnings = tuple(_diag_dict(d) for d in result.diagnostics)
        return run_geometric_drc(result.board, warnings=warnings)
    return _indeterminate("internal", f"unexpected resolution result {type(result).__name__}")
