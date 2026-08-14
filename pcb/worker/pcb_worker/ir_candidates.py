"""Typed CANDIDATE-COPPER overlay over a compiled ResolvedBoard.

Design of record: docket 019f952b99f2 ("typed candidate-copper overlay:
geometric collision feedback for ghost/proposed routes before acceptance").
Closes bug 019f80b5124d, where a routing proposal ran a trace straight through
the centre of a different-net pad and the DRC attached to that proposal reported
it CLEAN.

WHY THIS EXISTS
---------------
The propose path attaches ``drc.run_drc`` (``methods._drc_for_routes``), the
CENTERLINE connectivity checker. Traces are centerlines and pads are points
there, so a trace through a pad CENTRE is not even representable — the payload
honestly stamps ``scope:"connectivity"``, but a human deciding whether to accept
reads "clean". Geometric DRC (:mod:`drc_geometric`) detects that fault exactly;
the propose path simply never ran it, because geometric DRC reads a COMPILED
board and a proposal is not yet in one. This module is the missing projection.

REIMPLEMENTS NO RULE
--------------------
There is no clearance/width/annular math here. Candidates are projected into the
geometric kernel's OWN INPUT LANGUAGE — a :class:`ResolvedBoard` — as ordinary
``ResolvedTrace``/``ResolvedVia`` entities layered over the compiled base board,
and the UNCHANGED kernel (``drc_geometric.run_geometric_drc``) is run over the
result. This is the same move :mod:`ir_connectivity` makes for the connectivity
kernel: project one compiled board into the checker's language rather than teach
the checker a new concept.

WHY THE OVERLAY IS A ResolvedBoard AND NOT A HAND-BUILT ``Projection``
----------------------------------------------------------------------
The design calls for candidates "projected into the SAME normalized copper
primitives the geometric projection already produces". Building
``CopperPrimitive``/``HolePrimitive``/``AnnularEntity`` here by hand would
produce primitives that merely LOOK the same and could drift from
``drc_geometric.project_board`` at any future edit. Overlaying at the IR level
instead means ``project_board`` itself projects the candidate copper, with the
same trace-capsule and via-land construction (and therefore the same neutral
``pad_source``-owned land geometry for everything else on the board). Two
consequences that are the point of the exercise:

  * PROPOSE-TIME AND POST-ACCEPT AGREE BY CONSTRUCTION. The candidate is modeled
    by the code path that models an accepted trace, so a proposal and the same
    geometry accepted into the board cannot disagree.
  * THE KERNEL STAYS PURE AND UNTOUCHED. It is never given knowledge of
    candidates, and :mod:`drc_geometric` needed no edit at all — including its
    fail-closed guards (zones, copper graphics, per-layer via padstacks), which
    keep protecting this surface for free. Candidate copper also inherits the
    kernel's PER-NET-CLASS floors for free, and for the same reason: GC1/GC2 read
    the overlay board's own ``design_rules.net_classes``, so a candidate on a
    net-classed net is checked at that class's minima rather than the board's
    blanket ones — no clearance/width rule is reimplemented here.

FAIL-CLOSED (owner-ratified: canvas may DEGRADE; ROUTING/DRC/CAM FAIL CLOSED)
----------------------------------------------------------------------------
No approximated copper. A candidate that cannot be modeled faithfully — unknown
net, unknown/foreign copper layer, zero-length segment, no declared width, a via
with no declared diameter/drill — raises :class:`UnsupportedGeometry` and the
whole reply becomes the INDETERMINATE union. Nothing is guessed and no partial
verdict is emitted: a candidate list is checked completely or not at all. The
union NAMES the offending candidate (``error["candidate_id"]``) when the fault is
attributable to one — see :class:`UnmodelableCandidate`, including the argument
for why naming is as far as it is safe to go.

Widths and via sizes are never INVENTED here. A caller must supply either
per-candidate values or explicit defaults it can defend (``methods._route``
passes the width the engine actually routed at, read from the engine's own
signature, and the board's authored via defaults). See ``docs/routing.md``.

HONEST SCOPE (constraint: a consumer must always know which of three cases held)
-------------------------------------------------------------------------------
Every reply carries ``scope: "geometric_candidate"`` — distinguishable both from
today's connectivity DRC-at-propose (``scope:"connectivity"``) and from the
whole-board geometric union (``scope:"geometric"``), because it answers a third
question: "does this PROPOSAL introduce a geometric violation?". The three cases
are discriminated by ``verdict``:

  a. ran, candidates clean          -> ok=True,  verdict="clean"
  b. ran, candidates violate        -> ok=True,  verdict="violations"
  c. could NOT run                  -> ok=False, verdict="indeterminate"

Case (c) carries NO ``findings``/``counts``/``per_candidate`` — nothing a caller
could read as (a). ``ok`` means "the check RAN", never "the board passed".

BASELINE VS INTRODUCED
----------------------
A real board can already be geometrically dirty (smart_remote.yaml carries 12
pre-existing violations, bug 019f989d3179). Reporting those against a candidate
would be dishonest, and hiding them would be worse. So the kernel's findings are
PARTITIONED by participation: a finding naming at least one candidate entity is
``findings`` (introduced by the proposal); everything else is ``baseline``.

That partition IS the delta, exactly. Candidates only ADD copper primitives:
GC1/GC3/GC4/GC5 are per-entity, and GC2/GC6 enumerate pairs — so no base-only
finding can appear or disappear because a candidate was added. A second kernel
run over the base board alone would produce precisely ``baseline``.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any

from agent_router.layers import kicad_to_canon

from .canonical_id import derive_id
from .drc_geometric import geometric_indeterminate, run_geometric_drc
from .ir_pads import UnsupportedGeometry
from .resolved_board import (
    Layer,
    ResolvedBoard,
    ResolvedTrace,
    ResolvedTraceSegment,
    ResolvedVia,
    ViaKind,
)

# The scope token for this surface. NOT "geometric" (that is the whole-board
# union) and NOT "connectivity" (that is the centerline checker) — a consumer
# must be able to tell all three apart at a glance.
CANDIDATE_SCOPE = "geometric_candidate"

# The subject a finding names when its participant is committed board copper
# rather than a candidate. Same spelling `methods._draft_check` already uses, so
# the two candidate-aware surfaces name the board the same way.
BOARD_SUBJECT_ID = "board"


class UnmodelableCandidate(UnsupportedGeometry):
    """An :class:`UnsupportedGeometry` that knows WHICH candidate caused it.

    THE BATCH VERDICT IS STILL BATCH-WIDE (docket 019f9cc3245d) — the option
    chosen here, not the only safe one.

    WHAT IS RULED OUT is the obvious relaxation: drop the offender and score the
    survivors normally. That evaluates the survivors WITHOUT the dropped
    candidate's copper, so a collision between it and a survivor simply vanishes
    and the survivor comes back CLEAN. GC2/GC6 are pairwise, so this is not
    hypothetical — it is the normal case for two ghosts routed near each other.
    A false clean produced by malformed input is what fail-closed exists to
    prevent.

    A SAFE ALTERNATIVE DOES EXIST and is deliberately NOT implemented here: score
    the survivors but never emit ``clean`` for any of them, reporting the findings
    as SOUND BUT INCOMPLETE (every violation reported is real; absence of one
    proves nothing, because the unmodelable candidate's copper was not in the
    run). That is honest and strictly more useful than silence. It needs a
    verdict token this union does not have — "violations, possibly more" is
    neither ``clean`` nor ``indeterminate`` — so it is a design decision with a
    wire-format consequence, not a refactor to slip into a bug-fix round.

    What THIS class buys is the cheap part of that: NAMING the offender while the
    batch verdict stays indeterminate — strictly more information, no change to
    what any consumer may conclude. ``check_candidates`` puts the id in
    ``error["candidate_id"]``.

    The key is ABSENT, never null, when the fault is not attributable to one
    candidate (a candidate that is not even a mapping; the IR rejecting the
    assembled overlay). A consumer must be able to tell "this candidate is the
    offender" from "the offender is unknown", and a None that reads as a default
    would erase that difference.
    """

    def __init__(self, candidate_id: str, message: str):
        super().__init__(message)
        self.candidate_id = candidate_id


# ---------------------------------------------------------------------------
# Wire-shape coercion. Shared with `methods._draft_check` (which owned the first
# implementation) so the two candidate-consuming surfaces accept EXACTLY the same
# candidate language — a shape one accepts and the other silently drops would be
# a correctness trap, not a style problem.
# ---------------------------------------------------------------------------


def candidate_points(raw) -> list:
    """Coerce a segment's points to [(x, y), ...]. Accepts [[x,y],...] pairs and
    {x_mm,y_mm}/{x,y} dicts."""
    out: list = []
    if isinstance(raw, list):
        for p in raw:
            if isinstance(p, (list, tuple)) and len(p) >= 2:
                out.append((float(p[0]), float(p[1])))
            elif isinstance(p, dict):
                if "x_mm" in p and "y_mm" in p:
                    out.append((float(p["x_mm"]), float(p["y_mm"])))
                elif "x" in p and "y" in p:
                    out.append((float(p["x"]), float(p["y"])))
    return out


def candidate_via_position(raw):
    """Coerce a via position to (x, y) or None. Accepts [x,y], {x_mm,y_mm},
    {x,y}, and {position:<either>}."""
    if isinstance(raw, dict):
        if "x_mm" in raw and "y_mm" in raw:
            return (float(raw["x_mm"]), float(raw["y_mm"]))
        if "x" in raw and "y" in raw:
            return (float(raw["x"]), float(raw["y"]))
        pos = raw.get("position")
        if pos is not None:
            return candidate_via_position(pos)
        return None
    if isinstance(raw, (list, tuple)) and len(raw) >= 2:
        return (float(raw[0]), float(raw[1]))
    return None


def _segment_points(seg: dict) -> list:
    """A candidate segment's polyline. Accepts the draft/ghost ``points`` polyline
    AND route()'s ``start``/``end`` pair (``_serialize_routing_result``), so a
    proposal straight off the router and a hand-drawn ghost speak one language."""
    pts = candidate_points(seg.get("points"))
    if pts:
        return pts
    start, end = seg.get("start"), seg.get("end")
    if start is None and end is None:
        return []
    pair = candidate_points([start, end])
    return pair if len(pair) == 2 else []


def positive_mm(value) -> float | None:
    """A finite, strictly-positive millimetre scalar, or None. The ONE predicate
    every candidate dimension is admitted through — a non-positive or non-finite
    dimension is never modeled as copper."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    v = float(value)
    if v <= 0.0 or v != v or v in (float("inf"), float("-inf")):
        return None
    return v


def candidate_id(cand: dict, ordinal: int) -> str:
    """The one wire-id rule for every candidate consumer.

    Workspace candidates always carry an id, but ``draft_check`` is also a
    direct worker/MCP surface. Id-less inputs receive an ordinal fallback so
    connectivity verdicts, geometric verdicts and attributed subjects can
    still be joined without inventing three subtly different identities.
    """
    return str(cand.get("candidate_id", "") or f"candidate:{ordinal}")


def candidate_is_provably_empty(cand) -> bool:
    """True only when the wire value explicitly contains no candidate copper.

    Missing/null/empty arrays are safe to omit from a geometric batch: no
    primitive exists that could collide with another candidate. Any malformed
    container or non-empty value returns False and reaches ``build_overlay``,
    where it fails closed rather than being mistaken for empty geometry.
    """
    if not isinstance(cand, dict):
        return False

    def empty_collection(value) -> bool:
        return value is None or (isinstance(value, (list, tuple)) and not value)

    return empty_collection(cand.get("segments")) \
        and empty_collection(cand.get("vias"))


# ---------------------------------------------------------------------------
# The overlay.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Overlay:
    """A compiled base board with candidate copper layered on, plus the index
    that maps a projected IR entity back to the candidate that authored it."""

    board: ResolvedBoard              # base + candidate traces/vias
    subjects: dict                    # IR entity_id -> subject dict
    candidate_ids: tuple[str, ...]    # in input order
    revisions: dict                   # candidate_id -> revision (opaque, echoed)


def _copper_layer(rb: ResolvedBoard, raw_layer: Any, what: str) -> Layer:
    """Resolve a candidate's layer against the BOARD's own copper stack.

    Folded through the one canonical map (``agent_router.layers.kicad_to_canon``)
    so "F.Cu" and "top" reach the same physical layer — the same normalization
    GC2 applies — then required to be a layer this board actually has. A layer the
    board does not carry is unmodelable copper, not a layer to invent."""
    canon = kicad_to_canon(raw_layer) if raw_layer not in (None, "") else "top"
    copper_ids = {layer.id for layer in rb.layer_stack.copper}
    if canon not in copper_ids:
        raise UnsupportedGeometry(
            f"{what}: layer {raw_layer!r} (canonical {canon!r}) is not a copper "
            f"layer of this board {sorted(copper_ids)}")
    return Layer.from_id(canon)


def build_overlay(rb: ResolvedBoard, candidates: list, *,
                  default_width_mm: float | None = None,
                  default_via_diameter_mm: float | None = None,
                  default_via_drill_mm: float | None = None) -> Overlay:
    """Project candidate routes onto ``rb`` as IR traces/vias.

    Raises :class:`UnsupportedGeometry` for anything that cannot be modeled
    faithfully — the caller turns that into the INDETERMINATE union. Nothing is
    approximated: a missing width or via size is a fail-closed error, never a
    guessed dimension (owner ruling: no approximated copper).
    """
    net_id_by_name = {net.name: net.id for net in rb.nets}
    new_traces: list[ResolvedTrace] = []
    new_vias: list[ResolvedVia] = []
    subjects: dict = {}
    ordered_ids: list[str] = []
    revisions: dict = {}

    for ordinal, cand in enumerate(candidates):
        if not isinstance(cand, dict):
            raise UnsupportedGeometry(
                f"candidate[{ordinal}]: expected a mapping, got "
                f"{type(cand).__name__}")
        cid = candidate_id(cand, ordinal)
        if cid in revisions:
            raise UnmodelableCandidate(
                cid,
                f"candidate {cid!r}: duplicate candidate_id — a finding could not "
                f"be attributed to one ghost route")
        revision = cand.get("revision")
        ordered_ids.append(cid)
        revisions[cid] = revision

        # ATTRIBUTION WRAPPER. Everything below is this ONE candidate's own
        # projection, so any UnsupportedGeometry out of it names this candidate —
        # including the ones raised inside helpers (`_copper_layer`) that have no
        # idea whose geometry they are resolving. Re-raised as
        # `UnmodelableCandidate` with the message VERBATIM: callers matching on
        # the text (and `except UnsupportedGeometry`, which still catches this
        # subclass) are unaffected; they gain a machine-readable id.
        try:
            net_name = cand.get("net")
            net_id = net_id_by_name.get(net_name) if isinstance(net_name, str) else None
            if net_id is None:
                # No net => no same-net exemption and no electrical meaning. Guessing
                # (net_id=None) would make the candidate conflict with its OWN pads and
                # report a short that does not exist, so fail closed instead.
                raise UnsupportedGeometry(
                    f"candidate {cid!r}: net {net_name!r} is not a net of this board")

            # Trace segments. One IR trace per candidate segment (drc_geometric
            # projects per-segment capsules regardless of how they are grouped, and a
            # per-segment trace keeps segment identity 1:1 with the ghost's own).
            raw_segments = cand.get("segments")
            if raw_segments is None:
                raw_segments = []
            if not isinstance(raw_segments, (list, tuple)):
                raise UnsupportedGeometry(
                    f"candidate {cid!r}: segments must be an array")
            for seg_ordinal, seg in enumerate(raw_segments):
                if not isinstance(seg, dict):
                    raise UnsupportedGeometry(
                        f"candidate {cid!r} segment[{seg_ordinal}]: expected a mapping")
                what = f"candidate {cid!r} segment[{seg_ordinal}]"
                pts = _segment_points(seg)
                if len(pts) < 2:
                    raise UnsupportedGeometry(
                        f"{what}: needs at least two points, got {len(pts)}")
                width = (positive_mm(seg.get("width_mm")) or positive_mm(seg.get("width"))
                         or positive_mm(cand.get("width_mm"))
                         or positive_mm(default_width_mm))
                if width is None:
                    raise UnsupportedGeometry(
                        f"{what}: no trace width declared and none supplied by the "
                        f"caller — candidate copper is never modeled at a guessed width")
                layer = _copper_layer(rb, seg.get("layer"), what)
                sid = str(seg.get("id", "") or f"segment:{seg_ordinal}")
                trace_id = derive_id("candidate-trace", rb.id, cid, str(revision),
                                     sid, seg_ordinal)
                ir_segments: list[ResolvedTraceSegment] = []
                for leg, (a, b) in enumerate(zip(pts, pts[1:])):
                    if a == b:
                        raise UnsupportedGeometry(
                            f"{what}: zero-length leg at {a}")
                    seg_entity = derive_id("candidate-segment", trace_id, leg)
                    ir_segments.append(ResolvedTraceSegment(
                        id=seg_entity, a=a, b=b, width_mm=width, layer=layer))
                    subjects[seg_entity] = {"candidate_id": cid, "revision": revision,
                                            "segment_id": sid}
                new_traces.append(ResolvedTrace(id=trace_id, net_id=net_id,
                                                segments=tuple(ir_segments)))
                subjects[trace_id] = {"candidate_id": cid, "revision": revision,
                                      "segment_id": sid}

            # Vias.
            raw_vias = cand.get("vias")
            if raw_vias is None:
                raw_vias = []
            if not isinstance(raw_vias, (list, tuple)):
                raise UnsupportedGeometry(
                    f"candidate {cid!r}: vias must be an array")
            for via_ordinal, via in enumerate(raw_vias):
                what = f"candidate {cid!r} via[{via_ordinal}]"
                pos = candidate_via_position(via)
                if pos is None:
                    raise UnsupportedGeometry(f"{what}: has no usable position")
                via_dict = via if isinstance(via, dict) else {}
                diameter = (positive_mm(via_dict.get("diameter_mm"))
                            or positive_mm(default_via_diameter_mm))
                drill = (positive_mm(via_dict.get("drill_mm"))
                         or positive_mm(default_via_drill_mm))
                if diameter is None or drill is None:
                    raise UnsupportedGeometry(
                        f"{what}: no via diameter/drill declared and none supplied by "
                        f"the caller — candidate copper is never modeled at a guessed "
                        f"size")
                if drill >= diameter:
                    raise UnsupportedGeometry(
                        f"{what}: drill {drill} must be smaller than diameter {diameter}")
                from_layer = _copper_layer(rb, via_dict.get("from_layer", "top"), what)
                to_layer = _copper_layer(rb, via_dict.get("to_layer", "bottom"), what)
                if from_layer.id == to_layer.id:
                    raise UnsupportedGeometry(
                        f"{what}: span {from_layer.id!r}->{to_layer.id!r} does not "
                        f"change layers")
                vid = str(via_dict.get("id", "") or f"via:{via_ordinal}")
                via_entity = derive_id("candidate-via", rb.id, cid, str(revision), vid,
                                       via_ordinal)
                new_vias.append(ResolvedVia(
                    id=via_entity, position=pos, diameter_mm=diameter, drill_mm=drill,
                    net_id=net_id, kind=ViaKind.THROUGH,
                    from_layer=from_layer.id, to_layer=to_layer.id,
                    # Tenting is a MASK property; it has no effect on any GC1-GC6
                    # copper/hole rule. The IR default (tented) is used rather than
                    # inventing a mask intent for a proposal.
                    tented_front=True, tented_back=True))
                subjects[via_entity] = {"candidate_id": cid, "revision": revision,
                                        "via_id": vid}
        except UnsupportedGeometry as exc:
            raise UnmodelableCandidate(cid, str(exc)) from exc

    try:
        board = replace(rb, traces=rb.traces + tuple(new_traces),
                        vias=rb.vias + tuple(new_vias))
    except ValueError as exc:
        # ResolvedBoard's own invariants (unique ids, legal via span, allowed via
        # kind, known copper layer) reject the overlay. That is the IR refusing to
        # represent this candidate set — fail closed with its own message rather
        # than check the board into a state the compiler would never produce.
        raise UnsupportedGeometry(
            f"candidate overlay is not a representable board: {exc}") from exc

    return Overlay(board=board, subjects=subjects,
                   candidate_ids=tuple(ordered_ids), revisions=revisions)


# ---------------------------------------------------------------------------
# Attribution.
# ---------------------------------------------------------------------------


def _finding_entity_ids(finding: dict) -> list:
    """Every IR entity a geometric finding names, in a stable order.

    THREE FINDING SHAPES, and all three must be read or attribution silently
    depends on which rule fired:

      PER-ENTITY (GC1/GC3/GC4)      — a single ``entity_id``.
      PAIRWISE (GC2/GC6)            — ``"<lo>|<hi>"`` plus ``participants`` /
                                      ``entities``.
      SUBJECT + OPPOSED (GC5-cutout,
      GC7, GC9, GC10, GC11)         — one ``entity_id`` for the SUBJECT of the
                                      rule, with the other party named only in
                                      ``against_entity_id`` (or ``pad_entity``
                                      for gc9_silk_to_pad).

    THE THIRD SHAPE WAS NOT READ HERE UNTIL CP2 S8's REVIEW, and the consequence
    was a FALSE CLEAN on the surface a user actually accepts routes through.
    These rules are ASYMMETRIC on purpose — GC7's subject is the pour and GC10's
    is the bore, because that is what the rule is *about* — so when the opposing
    party is a CANDIDATE, the candidate appeared in no field this function read.
    ``finding_subjects`` then returned no candidate subject, ``check_candidates``
    partitioned the finding into ``baseline`` as a pre-existing board fault, and
    the proposal that CAUSED it was reported ``clean``. That inverts this
    module's own contract that a clean proposal must not launder a dirty board.

    Demonstrated for gc10_hole_to_copper (a candidate trace inside an unplated
    hole's floor) and reachable the same way for gc7_zone_clearance, which has
    carried this shape since long before CP2 — so this repair closes a
    pre-existing hole as well as the new checks' exposure.

    A key that names a BOARD feature rather than an entity (GC5's cutout id) is
    harmless here: it resolves to no overlay subject, and its presence correctly
    marks the finding MIXED, which is what a candidate-too-close-to-a-slot is.
    """
    out: list = []
    seen: set = set()

    def add(value):
        if isinstance(value, str) and value and value not in seen:
            seen.add(value)
            out.append(value)

    raw = finding.get("entity_id")
    if isinstance(raw, str):
        for part in raw.split("|"):
            add(part)
    for participant in finding.get("participants") or []:
        if isinstance(participant, dict):
            add(participant.get("entity_id"))
    for entity in finding.get("entities") or []:
        add(entity)
    # The opposed party of an asymmetric rule. Read from the finding dict rather
    # than from a per-rule table so a NEW asymmetric check is attributed the day
    # it is written, without a coordinated edit here that nobody would remember
    # to make — the omission is invisible until a candidate happens to be on the
    # opposed side.
    add(finding.get("against_entity_id"))
    add(finding.get("pad_entity"))
    add(finding.get("parent"))
    return out


def finding_subjects(finding: dict, overlay: Overlay) -> list:
    """The candidate (and board) subjects a finding names.

    Candidate subjects carry ``candidate_id`` + ``revision`` (+ ``segment_id`` or
    ``via_id``) so a canvas can attribute a collision to one specific ghost route
    and detect a stale result. Committed copper is named ``candidate_id:"board"``
    — the same convention ``methods._draft_check`` uses."""
    entity_ids = _finding_entity_ids(finding)
    subjects: list = []
    seen: set = set()
    for entity_id in entity_ids:
        subject = overlay.subjects.get(entity_id)
        if subject is None:
            continue
        key = (subject["candidate_id"], subject.get("segment_id"),
               subject.get("via_id"))
        if key in seen:
            continue
        seen.add(key)
        subjects.append(dict(subject))
    # Only a MIXED finding names the board side: a candidate-vs-candidate
    # collision must not claim committed copper is involved, and a board-only
    # finding is baseline (it gets no subjects at all, which is how the caller
    # partitions it out).
    if subjects and any(eid not in overlay.subjects for eid in entity_ids):
        subjects.append({"candidate_id": BOARD_SUBJECT_ID})
    return subjects


# ---------------------------------------------------------------------------
# The reply union.
# ---------------------------------------------------------------------------


def candidate_indeterminate(kind: str, message: str,
                            diagnostics: tuple | list = (),
                            *, candidate_id: str | None = None) -> dict:
    """The candidate-scoped INDETERMINATE union — case (c).

    Delegates to the geometric union's PUBLIC constructor
    (``drc_geometric.geometric_indeterminate``) so this surface cannot drift from
    the envelope every other geometric failure already uses; only ``scope`` is
    re-stamped, because the question asked was candidate-scoped. Carries no
    ``findings``/``counts``/``per_candidate``/``clean`` a caller could read as a
    pass. ``kind`` uses the shared vocabulary (docs/routing.md): ``parse`` |
    ``compile`` | ``unresolved_geometry`` | ``unsupported_geometry`` | ``route`` |
    ``internal``.

    ``candidate_id`` names the ONE candidate that could not be modeled, when the
    fault is attributable to one (see :class:`UnmodelableCandidate`). It is added
    inside ``error``, so it rides wherever that envelope already travels —
    ``methods._attach_route_geometric_drc`` copies ``error`` verbatim onto every
    route, so no consumer needs a new field to find it. The key is OMITTED when
    the offender is unknown; it is never ``None``."""
    union = geometric_indeterminate(kind, message, diagnostics)
    union["scope"] = CANDIDATE_SCOPE
    if candidate_id is not None:
        union["error"]["candidate_id"] = candidate_id
    return union


def check_candidates(rb: ResolvedBoard, candidates: list, *,
                     warnings: tuple[dict, ...] = (),
                     default_width_mm: float | None = None,
                     default_via_diameter_mm: float | None = None,
                     default_via_drill_mm: float | None = None) -> dict:
    """Run the UNCHANGED geometric kernel over base copper + candidate copper.

    Returns the candidate-scoped union. See the module docstring for the three
    cases and for why the base/candidate partition is exactly the delta a second
    base-only kernel run would produce.

    ONE UNMODELABLE CANDIDATE STILL MAKES THE WHOLE REPLY INDETERMINATE — it is
    now NAMED as well. The two ``except`` arms below are the attributable and the
    non-attributable case, kept apart deliberately rather than folded into one
    ``getattr(exc, "candidate_id", None)``: "candidate X is the offender" and "the
    offender is unknown" are different answers, and a default-valued key would
    make them read the same. See :class:`UnmodelableCandidate` for why the verdict
    stays batch-wide instead of dropping the offender and scoring the rest.
    """
    try:
        overlay = build_overlay(
            rb, candidates, default_width_mm=default_width_mm,
            default_via_diameter_mm=default_via_diameter_mm,
            default_via_drill_mm=default_via_drill_mm)
    except UnmodelableCandidate as exc:
        return candidate_indeterminate("unsupported_geometry", str(exc),
                                       candidate_id=exc.candidate_id)
    except UnsupportedGeometry as exc:
        return candidate_indeterminate("unsupported_geometry", str(exc))
    except Exception as exc:  # noqa: BLE001 - fail-closed: a crash is NOT a clean.
        return candidate_indeterminate(
            "internal", f"candidate overlay raised {exc!r}")

    try:
        union = run_geometric_drc(overlay.board, warnings=warnings)
    except Exception as exc:  # noqa: BLE001 - the kernel is fail-closed, but a
        # caller-injected fault must not escape as an exception either: this
        # surface never fails a propose call, it reports that it could not run.
        return candidate_indeterminate(
            "internal", f"geometric DRC raised {exc!r}")
    if not union.get("ok"):
        # The kernel could not reach a verdict over base+candidates (unmodelable
        # geometry, a compile-level guard, an internal fault). Re-scope its
        # verbatim envelope — case (c). NEVER downgraded to a clean.
        union = dict(union)
        union["scope"] = CANDIDATE_SCOPE
        union["verdict"] = "indeterminate"
        return union

    zero = {key: 0 for key in union.get("counts", {})}
    introduced: list = []
    baseline: list = []
    counts = dict(zero)
    baseline_counts = dict(zero)
    per_candidate = {
        cid: {"revision": overlay.revisions.get(cid), "verdict": "clean",
              "finding_count": 0}
        for cid in overlay.candidate_ids
    }

    for finding in union.get("findings", []):
        subjects = finding_subjects(finding, overlay)
        named = [s for s in subjects if s["candidate_id"] != BOARD_SUBJECT_ID]
        if not named:
            baseline.append(finding)
            baseline_counts[finding["type"]] = \
                baseline_counts.get(finding["type"], 0) + 1
            continue
        attributed = dict(finding)
        attributed["subjects"] = subjects
        introduced.append(attributed)
        counts[finding["type"]] = counts.get(finding["type"], 0) + 1
        for subject in named:
            entry = per_candidate.get(subject["candidate_id"])
            if entry is not None:
                entry["verdict"] = "violations"
                entry["finding_count"] += 1

    return {
        "ok": True,
        "scope": CANDIDATE_SCOPE,
        "verifies_geometry": True,
        # The verdict is about the CANDIDATES, not the board: "clean" means this
        # proposal introduces no geometric violation. The board's own pre-existing
        # state is reported separately under "baseline" and is never folded in —
        # a dirty board must not veto an honest proposal, and a clean proposal
        # must not launder a dirty board.
        "verdict": "violations" if introduced else "clean",
        "board_id": union.get("board_id"),
        "source_digest": union.get("source_digest"),
        "rule_profile": union.get("rule_profile"),
        "findings": introduced,
        "counts": counts,
        "per_candidate": per_candidate,
        "baseline": {
            "verdict": "violations" if baseline else "clean",
            "findings": baseline,
            "counts": baseline_counts,
        },
        "warnings": list(union.get("warnings", [])),
    }
