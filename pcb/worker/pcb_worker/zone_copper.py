"""A FILLED zone is copper — the one place the connectivity checks learn it.

The four checks in :mod:`drc` and the completeness census read pads, traces and
vias. A pour was invisible to all of them, so every zone-bearing net whose
trace graph left islands came back INDETERMINATE — "there is a plane here and
this kernel cannot see it". On a board whose return path IS the plane that is
most of the board's connectivity reported as unknown.

WHAT A POUR CONDUCTS AS. Its COMPILED FILL, never its authored outline. The
outline is a request; the fill is what survives clearance carving, keepouts,
cutouts and the board-edge inset, and those can cut one outline into regions
that DO NOT conduct to each other. Each filled region becomes one
``copper_contact`` node of the zone's net (``region_node``) — the same node kind
the rest of the predicate already takes, so nothing downstream grows a second
notion of what copper is.

=== THE FILL IS RECOMPUTED, NEVER READ OFF THE BOARD ===

A fill is a COMPILE OUTPUT about one exact board, not a property of the
document. This module therefore computes it from the very board being checked,
every time, and IGNORES any ``fill`` a board document happens to carry: such a
fill describes some other revision of the board, and a census that trusts it
reports a pad as already served by the plane when it is not — an error that
reaches fabrication.

That makes A STALE FILL UNREPRESENTABLE HERE rather than something to detect:
there is no cache to go stale, and nothing but the current board can supply the
copper. (The panel reaches the same place from the other side: its fill is
in-memory only, dropped by every projection that could outlive the board it
describes — see ``pcb_data.gd``'s ZONE_FILL_KEY.) The cost is one compile per
check; the fill is where the pour's copper is decided, so there is no cheaper
honest answer.

=== THE THREE STATES OF A POUR, AND WHAT EACH MEANS ===

  * FILL COMPUTED, NON-EMPTY — copper. Its regions join whatever they reach and
    the census can decide the net for real.
  * FILL COMPUTED, EMPTY — a real answer: the outline was entirely consumed by
    keepouts, clearance or the edge inset. The pour makes no copper, so it
    joins nothing, and the net is decided by its traces and vias alone.
  * FILL NOT COMPUTED — the compile refused (an arc in the outline, authored
    thermal relief, two foreign pours claiming one patch of copper) or the
    board would not compile at all. NOT copper, and not "no copper" either:
    nothing was measured. The net keeps its INDETERMINATE row, now carrying the
    reason the fill is missing rather than a bare "there is a zone here".

AN UNFILLED ZONE IS THE THIRD STATE, not a fourth: a pour is unfilled exactly
when no fill was computed for it. A keepout is never any of the three — it is a
prohibition on copper and emits none.
"""

from __future__ import annotations

from . import copper_contact
from .drc_geom_primitives import Polygon

#: Why a board's pours contributed no copper. Rides on the census's
#: ``indeterminate`` rows so a reader is told what to fix, not merely that
#: something is unknown.
NO_ZONES = ""


def pour_nodes(board: dict) -> tuple[dict[str, list], str]:
    """``({net name: [region node]}, reason)`` for this board's copper pours.

    ``reason`` is empty when every pour was filled — including a pour that
    filled to nothing, which is an answer. It carries the compile's own refusal
    when the fill could not be computed, and the map is then empty: a partial
    picture of a plane is worse than none, because half a plane credits half its
    joins and silently withholds the rest.

    Returns immediately for a board with no copper pour, so the ordinary
    zone-less board never pays for a compile.
    """
    if not _has_copper_pour(board):
        return {}, NO_ZONES

    # Imported here, not at module scope: the compiler imports the DRC's own
    # projection, and this module is reached FROM the DRC.
    from . import compile_board as _compile  # noqa: PLC0415
    from .resolved_board import ResolutionFailure, ZoneKind  # noqa: PLC0415

    try:
        # The ROUTING output profile, not the fab one: this answers a
        # connectivity question, so a missing solder-mask capability must not
        # take the plane's copper away with it, while dropped copper, drill or
        # design rules stay fatal here as everywhere.
        compiled = _compile.compile_board(
            _compilable(board), requested_outputs=_compile.V1_ROUTING_OUTPUTS)
    except Exception as exc:  # a fill fault is data, never a crashed DRC
        return {}, f"the pour fill could not be computed: {exc}"
    if isinstance(compiled, ResolutionFailure):
        return {}, f"the pour fill could not be computed: {_first_error(compiled)}"

    nodes: dict[str, list] = {}
    for zone in compiled.board.zones:
        if zone.kind is not ZoneKind.COPPER_POUR or zone.fill is None:
            continue
        net = _zone_net_name(compiled.board, zone.net_id)
        if not net:
            continue   # a netless pour is at no potential: it joins no net
        layers = frozenset({zone.layer.id})
        for polygon in zone.fill:
            if len(polygon.points) < 3:
                continue   # a degenerate ring encloses no copper
            nodes.setdefault(net, []).append(
                copper_contact.region_node(
                    (Polygon(tuple(polygon.points)),), layers))
    return nodes, NO_ZONES


def _compilable(board: dict) -> dict:
    """``board`` with the one field the compiler requires and the census does
    not: ``version``.

    The census reads the board dict directly and never asks what schema version
    it claims, so a board it happily measures can still be one the compiler
    refuses to resolve. Refusing here would report a pour as unmeasurable for a
    reason that has nothing to do with the pour — the fill path must tolerate
    exactly what the census tolerates.

    ONLY AN ABSENT KEY DEFAULTS. An absent version means v1, the schema's own
    oldest shape. A version the board STATES is never touched, whatever it says:
    rewriting a stated ``"2"`` or ``2.0`` to 1 would compile a board the schema
    gate refuses, so the plane's copper would be measured off a reading of the
    board nobody else shares. A bad stated version fails in the compiler and the
    pour reads back as indeterminate with that as its detail.
    """
    if "version" in board:
        return board
    return {**board, "version": 1}


def zone_nets(board: dict) -> set[str]:
    """The net names this board's COPPER POURS claim, from the board dict.

    Kept here beside the fill so "which nets have a pour" and "what copper does
    that pour make" are read off one module rather than two.
    """
    out: set[str] = set()
    for zone in board.get("zones") or []:
        if not isinstance(zone, dict) or not _is_copper_pour(zone):
            continue
        net = zone.get("net")
        if isinstance(net, str) and net:
            out.add(net)
    return out


def _has_copper_pour(board: dict) -> bool:
    zones = board.get("zones")
    return isinstance(zones, list) and any(
        isinstance(z, dict) and _is_copper_pour(z) for z in zones)


def _is_copper_pour(zone: dict) -> bool:
    """A zone with no stated kind is a pour — the schema's own default, and the
    same reading the census has always applied to ``zones``."""
    kind = zone.get("kind")
    return not isinstance(kind, str) or kind in ("", "copper_pour")


def _zone_net_name(resolved, net_id) -> str:
    if net_id is None:
        return ""
    for net in resolved.nets:
        if net.id == net_id:
            return net.name
    return str(net_id)


def _first_error(failure) -> str:
    """Why the compile refused, in words that name WHICH PART to fix.

    A pour that cannot be filled takes every join through it down with it, and
    the reader's next question is always "which component". Reporting only the
    first error leaves the rest of the offenders silent, so a human fixes one
    part, re-runs, and meets the same sentence about the next. Every erroring
    entity is named here instead: the first error in full, then the remaining
    offenders by id, so one read names the whole set.
    """
    lead = ""
    offenders: list = []
    for diagnostic in failure.diagnostics:
        severity = getattr(diagnostic, "severity", None)
        if str(getattr(severity, "value", severity)).lower() != "error":
            continue
        if not lead:
            lead = str(getattr(diagnostic, "message", diagnostic))
            continue
        entity = getattr(getattr(diagnostic, "source_ref", None), "entity_id", "")
        if entity and entity not in offenders:
            offenders.append(str(entity))
    if not lead:
        return "the board did not compile"
    if offenders:
        return f"{lead} (also refused: {', '.join(offenders)})"
    return lead


__all__ = ["pour_nodes", "zone_nets"]
