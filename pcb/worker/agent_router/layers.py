"""Canonical layer-stack + via-span contract (worker side).

THE single source of truth for the "top"/"bottom" <-> KiCad "F.Cu"/"B.Cu"
mapping and for via-span legality. Lives in ``agent_router`` (the LOWER,
standalone base package) precisely so BOTH sides can import it without
violating the dependency direction:

  * ``agent_router.kicad_io`` imports it (same package -- trivially fine).
  * ``pcb_worker.route_bridge`` imports it (upward: pcb_worker depends ON
    agent_router, never the reverse -- allowed).

Before T1.5 the same 2-entry map was duplicated in route_bridge._LAYER_MAP,
kicad_io._CANON_TO_KICAD_LAYER (and elsewhere), which drifted and caused the
two-emitter via bug. Both now re-export the objects defined here, so a future
edit to one physically edits the other (they are the *same* dict object).

Scope: 2-layer (through-via) boards only. ``is_legal_via_span`` is written
against a stack-index adjacency rule so blind/buried layers can be added later
by extending the stack table alone -- no caller rework. NO N-layer support is
implemented here today.
"""

from __future__ import annotations

from typing import Any

# ---------------------------------------------------------------------------
# The one canonical map + its inverse (module-level singletons; callers alias
# these exact objects so drift is physically impossible).
# ---------------------------------------------------------------------------

CANON_TO_KICAD: dict[str, str] = {"top": "F.Cu", "bottom": "B.Cu"}
KICAD_TO_CANON: dict[str, str] = {v: k for k, v in CANON_TO_KICAD.items()}

# Copper-layer stack: canonical id -> physical stack index (top=0 outward).
# This table -- not a hardcoded top/bottom pair -- is what makes via-span
# legality forward-compatible with blind/buried layers.
STACK_INDEX: dict[str, int] = {"top": 0, "bottom": 1}


def canon_to_kicad(layer: Any) -> str:
    """Canonical ("top"/"bottom") -> KiCad copper layer name.

    Mirrors the old route_bridge._canon_layer edge cases exactly: empty ->
    "F.Cu"; an already-KiCad or unknown name passes through unchanged (only a
    recognised canonical name, case-insensitively, is remapped).
    """
    s = str(layer or "").strip()
    if not s:
        return "F.Cu"
    return CANON_TO_KICAD.get(s.lower(), s)


def kicad_to_canon(layer: Any) -> str:
    """KiCad copper layer name -> canonical ("top"/"bottom").

    Mirrors the old pcb_data._canon_layer_name edge cases exactly: empty ->
    "top"; "F.Cu"/"B.Cu" (case-insensitive) -> top/bottom; anything else is
    lower-cased and passed through.
    """
    s = str(layer or "").strip()
    if not s:
        return "top"
    low = s.lower()
    if low == "f.cu":
        return "top"
    if low == "b.cu":
        return "bottom"
    return low


def is_copper(layer: Any) -> bool:
    """True iff ``layer`` (canonical id) is a routable copper layer."""
    return kicad_to_canon(layer) in STACK_INDEX


def is_legal_via_span(from_id: Any, to_id: Any) -> bool:
    """True iff a via may span ``from_id`` <-> ``to_id``.

    Today: a through-via top<->bottom is legal; a same-layer or degenerate
    span is illegal. Derived from STACK_INDEX (two distinct known copper
    layers) rather than a hardcoded pair, so adding blind/buried layers is a
    stack-table edit -- this predicate does not change shape.
    """
    a = kicad_to_canon(from_id)
    b = kicad_to_canon(to_id)
    if a not in STACK_INDEX or b not in STACK_INDEX:
        return False
    return STACK_INDEX[a] != STACK_INDEX[b]
