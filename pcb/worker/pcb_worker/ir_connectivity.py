"""Normalized CONNECTIVITY projection of a compiled ResolvedBoard.

Round E1b, docket 019f97d021a8 (blocker on Round E 019f783860c8).

Round E1 moved canonical ROUTING onto the ResolvedBoard IR but left the
connectivity DRC attached to the same reply reading pads out of the RAW board
dict's inline ``pins``. The two halves of one reply then disagreed about which
pads exist: a footprint-only board (no inline pins — a perfectly valid authoring
shape) routed successfully while every route endpoint was reported
``dangling_endpoint``. Same board, same geometry, two representations.

This module closes that split. ``connectivity_board`` projects ONE compiled board
into the small dict language the legacy connectivity kernel (:mod:`drc`) already
speaks — pad centers, net ownership, existing traces/vias — so ``route()``
compiles once and feeds BOTH halves of its reply from that single compile. There
is deliberately no raw-dict and no best-effort-resolve fallback on this path: the
compiled IR is the only pad census.

DELIBERATELY NOT GEOMETRY. The connectivity kernel reasons about pad CENTERS and
trace CENTERLINES only (see docs/drc.md); it cannot verify a clearance, width or
annular ring, and this projection does not give it the ability to. Pad EXTENTS
are not projected — geometric copper DRC (:mod:`drc_geometric`) owns that, over
the same IR. Adding geometry semantics to the legacy kernel is explicitly out of
scope (Codex E1 review, comment 773).

COORDINATE CONVENTION: components are emitted at the origin with zero rotation
and their pins carry ABSOLUTE board positions, because the IR has already placed
them. ``drc._harvest_pads`` composes ``component position + rotate(pin offset)``,
which for a zero placement is the identity — so the IR's own placement (including
bottom-side mirroring) reaches the kernel unchanged rather than being re-derived
from a rotation the kernel would apply a second time.
"""

from __future__ import annotations

import json
from collections import Counter

from agent_router.layers import kicad_to_canon

from .ir_pads import UnsupportedGeometry, iter_ir_pads
from .resolved_board import ResolvedBoard


def _pin_ref(ref: str, number: str) -> str:
    return f"{ref}.{number}"


def connectivity_board(rb: ResolvedBoard) -> dict:
    """Project a compiled board into the connectivity kernel's input dict.

    Carries pads (as zero-placement components whose pins hold absolute
    positions), net membership, and the board's EXISTING traces/vias. The caller
    layers proposed routes on top (``methods._drc_for_routes``).
    """
    components: dict[str, dict] = {}
    pin_ref_by_pad_id: dict[str, str] = {}

    for ir_pad in iter_ir_pads(rb):
        pad = ir_pad.pad
        if not ir_pad.carries_copper:
            # NPTH is a bare mechanical hole — not an ELECTRICAL entity. Including
            # it would be actively dishonest: drc._check_dangling credits an
            # endpoint that lands near ANY pad as "copper-connected", so a route
            # terminating on a mechanical hole would be reported as connected
            # (019f97eb6adf). Its geometry is owned by geometric DRC (hole
            # primitives) and by routing (an obstacle), both of which model it
            # exactly.
            continue
        if not ir_pad.is_addressable:
            # Copper with no authored pad number. The kernel's entire pad identity
            # is (ref, number) and every net ref is spelled "U1.2", so it has no
            # way to REFER to this pad. Carrying it anyway is not neutral: it would
            # earn the same dangling-endpoint CREDIT above — reporting a route as
            # connected to copper that belongs to no net. The legacy kernel has no
            # honest representation for unaddressable copper, so it is left out of
            # the ELECTRICAL census; the short it could cause is a COPPER question,
            # which geometric DRC's GC2 models exactly over this same IR. A NETTED
            # unnumbered pad is a contradiction and fails closed (routing raises on
            # the same board, so both projections agree).
            if pad.net_id is not None:
                raise UnsupportedGeometry(
                    f"component {ir_pad.ref!r}: pad {ir_pad.source_number!r} is on "
                    f"net {ir_pad.net_name!r} but has no authored pad number — a "
                    f"netted endpoint that nothing can address")
            continue
        comp = components.get(ir_pad.ref)
        if comp is None:
            comp = {"ref": ir_pad.ref, "x_mm": 0.0, "y_mm": 0.0,
                    "rotation_deg": 0.0, "pins": []}
            components[ir_pad.ref] = comp
        pin: dict = {"number": ir_pad.human_number,
                     "x_mm": float(pad.position[0]),
                     "y_mm": float(pad.position[1])}
        if ir_pad.is_drilled:
            # The kernel needs only the TH/SMD classification, which it derives
            # through the SHARED pad_source.is_through_hole predicate from this
            # drill — so it classifies exactly as the emitters do.
            pin["drill_mm"] = max(float(pad.drill.size[0]), float(pad.drill.size[1]))
        if pad.layers:
            # WHICH FACES THIS PAD HAS COPPER ON. Without it every projected pad
            # reached drc._Pad.occupies with an empty layer list and answered
            # "yes" for every layer, so a bottom-side segment ending at the
            # centre of an F.Cu-only SMD pad counted as connected to it — copper
            # on the wrong side of the board, reported as a joined net.
            #
            # VERBATIM, unlike the traces and vias below, which this module
            # folds to canonical ids. The two consumers genuinely differ:
            # segment layers are compared by raw string equality, while pad
            # layers go through kicad_to_canon on the reading side
            # (drc._harvest_pads), which filters to copper first. Folding here
            # would have to special-case the mask and paste layers a pad
            # legitimately carries — kicad_to_canon warns and passes those
            # through lowercased — for no gain, since the reader folds anyway.
            # Emitting them ALL is what lets pad_source.has_copper tell an
            # electrical land from KiCad's legal paste-only aperture node.
            pin["layers"] = [layer.id for layer in pad.layers]
        comp["pins"].append(pin)
        pin_ref_by_pad_id[pad.id] = _pin_ref(ir_pad.ref, ir_pad.human_number)

    nets: list[dict] = []
    for net in rb.nets:
        members = [pin_ref_by_pad_id[pad_ref] for pad_ref in net.pad_refs
                   if pad_ref in pin_ref_by_pad_id]
        nets.append({"name": net.name, "pins": members})

    net_name_by_id = {net.id: net.name for net in rb.nets}

    # EXISTING copper. One 2-point trace per IR segment: drc._harvest_segments
    # breaks any polyline into consecutive pairs anyway, so this is identical to a
    # merged polyline and needs no chain-adjacency re-derivation (same reasoning as
    # methods._routes_to_traces). Layers are spelled canonically ("top"/"bottom"),
    # matching what _routes_to_traces emits for proposed routes, so the kernel's
    # raw-string layer equality lines up across existing and proposed copper.
    traces: list[dict] = []
    for trace in rb.traces:
        net_name = net_name_by_id.get(trace.net_id)
        for seg in trace.segments:
            traces.append({
                "net": net_name,
                "layer": kicad_to_canon(seg.layer.id),
                "width_mm": seg.width_mm,
                "points": [{"x_mm": float(seg.a[0]), "y_mm": float(seg.a[1])},
                           {"x_mm": float(seg.b[0]), "y_mm": float(seg.b[1])}],
            })

    vias: list[dict] = [{
        "x_mm": float(via.position[0]), "y_mm": float(via.position[1]),
        "from_layer": kicad_to_canon(via.from_layer),
        "to_layer": kicad_to_canon(via.to_layer),
    } for via in rb.vias]

    return {
        "version": 1,
        "name": rb.name,
        "components": list(components.values()),
        "nets": nets,
        "traces": traces,
        "vias": vias,
        # The kernel uses clearance only as its COINCIDENCE tolerance (how close an
        # endpoint must be to a pad to count as landing on it), not as a geometric
        # rule — the IR's own minimum keeps that tolerance consistent with the
        # board's rules instead of the kernel's built-in default.
        "design_rules": {"clearance_mm": rb.design_rules.minimums.min_clearance_mm},
    }


# ---------------------------------------------------------------------------
# BASELINE VS INTRODUCED (docket 019f9cc386b6)
#
# The GEOMETRIC candidate surface already keeps a board's pre-existing violations
# apart from the ones a proposal introduces (``ir_candidates.check_candidates``,
# key ``baseline``). This is the same idea for the CONNECTIVITY surface, whose
# ``drc_summary`` used to report one flat count over base+proposal and therefore
# billed the proposal for violations that predated it.
#
# THE TWO SURFACES ARE NOT MERGED AND MUST NOT BE. ``drc_summary`` answers
# connectivity, ``drc_geometric_summary`` answers copper (see ui/panel_tools.gd
# ``_write_records_as_proposals``); this partition is computed from connectivity
# findings alone and cannot move a geometric verdict, or vice versa.
# ---------------------------------------------------------------------------


def _finding_key(finding: dict) -> str:
    """A stable identity for one connectivity finding.

    ``drc.run_drc`` findings carry NO entity id — only ``type``/``net``/``at``
    and friends — so a canonical serialization of the whole dict is the only
    identity available. ``sort_keys`` makes it insensitive to key order;
    ``default=str`` keeps an unexpected non-JSON value from raising here (the
    partition would fail closed on a TypeError otherwise, turning a reportable
    result into an engine fault).

    TWO ASSUMPTIONS THIS RELIES ON, both latent today, both load-bearing for
    correctness now that a false match CANCELS a real violation:

      * NUMERIC SPELLING IS STABLE. ``1`` and ``1.0`` serialize differently and
        would key as different findings. Safe because every coordinate a finding
        carries goes through ``round()``, which always yields a float — see
        ``drc._round_pt`` and the ``round(pt[0], 3)`` calls in each check.
      * LIST ORDER IS STABLE. ``["A","B"]`` and ``["B","A"]`` key differently.
        Safe because the only list-valued field with two interchangeable members
        is ``crossing["nets"]``, which ``drc._check_crossings`` builds from an
        already-``sorted`` key.

    A change to either — an int coordinate, an unsorted net pair — silently
    turns pre-existing findings into "introduced" ones. Normalize here if that
    ever happens; do not rely on the producer staying tidy by accident.
    """
    return json.dumps(finding, sort_keys=True, default=str)


def partition_findings(base_findings: list, post_findings: list) -> tuple[list, list]:
    """Split a post-proposal connectivity run into ``(introduced, baseline)``.

    ``baseline`` is ``base_findings`` VERBATIM — the kernel's own output over the
    board WITHOUT the proposal — so "the baseline set is exactly what a base-only
    DRC run produces" holds by construction rather than by argument.
    ``introduced`` is the MULTISET difference ``post - base``: every finding in
    the post run that the board did not already have. Multiset rather than set so
    two indistinguishable findings are not collapsed into one.

    WHY NOT THE GEOMETRIC SURFACE'S MECHANISM. ``ir_candidates.check_candidates``
    partitions by ATTRIBUTION — a finding naming at least one candidate entity is
    introduced, everything else is baseline — and argues that equals a base-only
    run because candidates only ADD copper primitives, so no base finding can
    appear or disappear. Neither half of that argument survives the move to this
    kernel:

      * connectivity findings name no entity, so there is nothing to attribute
        against (``_finding_involves_net`` matches a NET, which both a baseline
        and an introduced finding on that net satisfy equally); and
      * adding copper is NOT monotone here. ``drc._check_dangling`` computes
        per-net endpoint DEGREE over base and proposed segments TOGETHER, so a
        proposal landing on a base trace's loose end makes that base
        ``dangling_endpoint`` finding disappear from the post run;
        ``drc._check_layer_change`` only fires once a net has segments on both
        sides, which a proposal can newly cause.

    Under attribution the first case would drop a real pre-existing violation out
    of BOTH partitions — the board would silently look cleaner than it is.
    Re-running the kernel over the base board is what keeps the stated property
    true, so that is what the caller does (``methods._attach_route_drc``).

    A baseline finding the proposal happens to RESOLVE stays listed under
    ``baseline``, and is simply absent from ``introduced``. That is deliberate:
    ``baseline`` describes the board AS IT STANDS, which is the state a reader
    deciding whether to accept the proposal is weighing it against.
    """
    remaining: Counter = Counter(_finding_key(f) for f in base_findings)
    introduced: list = []
    for finding in post_findings:
        key = _finding_key(finding)
        if remaining[key] > 0:
            remaining[key] -= 1  # already on the board — not this proposal's doing
            continue
        introduced.append(finding)
    return introduced, list(base_findings)
