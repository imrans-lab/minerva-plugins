"""Canonical layer-stack + via-span contract (worker side).

THE single source of truth for the canonical copper-layer names, their KiCad
aliases, and via-span legality. Lives in ``agent_router`` (the LOWER, standalone
base package) precisely so BOTH sides can import it without violating the
dependency direction:

  * ``agent_router.kicad_io`` imports it (same package -- trivially fine).
  * ``pcb_worker.route_bridge`` imports it (upward: pcb_worker depends ON
    agent_router, never the reverse -- allowed).

Before T1.5 the same 2-entry map was duplicated in route_bridge._LAYER_MAP,
kicad_io._CANON_TO_KICAD_LAYER (and elsewhere), which drifted and caused the
two-emitter via bug. Both now re-export the objects defined here, so a future
edit to one physically edits the other (they are the *same* dict object).

Canonical copper-layer names (epoch 6 unit 3a)
----------------------------------------------
``top``, ``in1`` .. ``in30``, ``bottom`` -- lowercase, 1-based, aliasing the
KiCad copper names ``F.Cu``, ``In1.Cu`` .. ``In30.Cu``, ``B.Cu``. The inner
range stops at 30 because KiCad's copper stack does (32 layers: F.Cu + In1..In30
+ B.Cu); a name outside it has no alias to map to, so it fails closed here
rather than emitting an ``In31.Cu`` no KiCad tool would accept.

This module NAMES layers and maps them; it does not decide what is buildable:

  * ``CANON_TO_KICAD`` / ``KICAD_TO_CANON`` / ``STACK_INDEX`` deliberately stay
    the TWO-layer OUTER pair.  Since epoch GA-1 a board's resolved stackup is
    built from its OWN ``layers`` declaration
    (``compile_board._build_layer_stack``) using the FUNCTION-level mapping
    (:func:`inner_layer_index`, :func:`canon_to_kicad`), so these tables are no
    longer "the stack" — they are the through-via span contract and the
    absent-declaration default.  Adding inner entries to them would widen
    :func:`is_legal_via_span` into admitting blind/buried spans nobody can
    fabricate; do not.
  * Whether a DECLARED depth is fabricable is the selected manufacturer
    profile's ``max_copper_layers`` capability gate
    (``compile_board._build_design_rules``), not a rule in this module.

Direction asymmetry (deliberate)
--------------------------------
* WRITE / export side -- :func:`canon_to_kicad` FAILS CLOSED: an empty or
  unrecognised layer name raises ``ValueError`` instead of silently defaulting
  to ``F.Cu``. A wrong-but-plausible layer name in an exported artifact is
  copper on the wrong side of the board; there is no safe default.
* READ / import side -- :func:`kicad_to_canon` FAILS VISIBLE: an unrecognised
  name still passes through lower-cased (raising would make old/foreign boards
  unloadable) but emits a ``warnings.warn`` so the oddball is not silent.

Via spans remain THROUGH-HOLE ONLY: :func:`is_legal_via_span` derives legality
from ``STACK_INDEX``, which contains only top/bottom, so a span touching an
inner layer is illegal. Blind/buried vias are not modeled.
"""

from __future__ import annotations

import warnings
from typing import Any

# ---------------------------------------------------------------------------
# The one canonical map + its inverse (module-level singletons; callers alias
# these exact objects so drift is physically impossible).
#
# THESE TWO TABLES ARE THE OUTER PAIR + THROUGH-VIA SPAN CONTRACT, NOT THE
# NAMING CONTRACT AND (since GA-1) NOT THE STACK. Do not add in1..in30 here --
# see the module docstring: is_legal_via_span derives from STACK_INDEX, so an
# inner entry here would legalise blind/buried via spans nobody can fabricate.
# Inner names are handled by the functions below; a board's resolved stackup
# comes from its own declaration (compile_board._build_layer_stack).
# ---------------------------------------------------------------------------

CANON_TO_KICAD: dict[str, str] = {"top": "F.Cu", "bottom": "B.Cu"}
KICAD_TO_CANON: dict[str, str] = {v: k for k, v in CANON_TO_KICAD.items()}

# Copper-layer stack: canonical id -> physical stack index (top=0 outward).
# This table -- not a hardcoded top/bottom pair -- is what makes via-span
# legality forward-compatible with blind/buried layers.
STACK_INDEX: dict[str, int] = {"top": 0, "bottom": 1}

# KiCad's copper stack is 32 layers: F.Cu + In1.Cu..In30.Cu + B.Cu. The inner
# range is capped to match, so every canonical name this module accepts HAS a
# KiCad alias (mirrored by MaxInnerLayers in internal/board/validate.go and
# MAX_INNER_LAYERS in pcb_layer_stack.gd).
MAX_INNER_LAYERS = 30


def inner_layer_index(layer: Any) -> int:
    """Return ``k`` for the canonical inner-copper name ``"in<k>"``, else 0.

    ``k`` must be 1..:data:`MAX_INNER_LAYERS` and written without a leading zero
    ("in01" is rejected): one layer, one spelling, so a name can never compare
    unequal to itself in a set/dict of declared layers.
    """
    s = str(layer or "").strip().lower()
    if not s.startswith("in") or len(s) < 3:
        return 0
    digits = s[2:]
    if not (digits.isascii() and digits.isdigit()) or digits[0] == "0":
        return 0
    k = int(digits)
    return k if 1 <= k <= MAX_INNER_LAYERS else 0


def _kicad_inner_layer_index(low: str) -> int:
    """Return ``k`` for a lower-cased KiCad inner name ``"in<k>.cu"``, else 0."""
    if not low.startswith("in") or not low.endswith(".cu"):
        return 0
    return inner_layer_index("in" + low[2:-3])


def _kicad_name_to_canon(low: str) -> str | None:
    """Lower-cased KiCad copper name -> canonical id, or None if it is not one."""
    if low == "f.cu":
        return "top"
    if low == "b.cu":
        return "bottom"
    k = _kicad_inner_layer_index(low)
    return f"in{k}" if k else None


def is_canonical_layer(layer: Any) -> bool:
    """True iff ``layer`` is a canonical copper name: top, bottom, or in1..in30."""
    s = str(layer or "").strip().lower()
    return s in CANON_TO_KICAD or inner_layer_index(s) > 0


def _canon_or_none(layer: Any) -> str | None:
    """Normalise a canonical OR KiCad copper name to its canonical id.

    Returns None for anything else. SILENT by design -- the predicates below use
    it, and a predicate that warns is a predicate nobody can call in a loop.
    """
    low = str(layer or "").strip().lower()
    if is_canonical_layer(low):
        return low
    return _kicad_name_to_canon(low)


def canon_to_kicad(layer: Any) -> str:
    """Canonical copper id ("top"/"bottom"/"in<k>") -> KiCad copper layer name.

    Idempotent: an already-KiCad copper name is accepted and returned in its
    canonical spelling ("f.cu" -> "F.Cu"), so a value can be pushed through this
    function twice without changing.

    FAILS CLOSED. An empty string, ``None``, or any name that is neither a
    canonical copper id nor a KiCad copper name raises ``ValueError``. Until
    epoch 6 unit 3a this returned "F.Cu" for empty input and echoed an unknown
    name unchanged; both defaults are gone, because this is the WRITE side --
    a silently defaulted layer name puts copper on the wrong side of a board
    that then gets fabricated.
    """
    canon = _canon_or_none(layer)
    if canon is None:
        raise ValueError(
            f"unknown copper layer {layer!r}: expected a canonical id "
            f'("top", "bottom", "in1".."in{MAX_INNER_LAYERS}") or a KiCad copper '
            f'name ("F.Cu", "B.Cu", "In<k>.Cu")'
        )
    if canon in CANON_TO_KICAD:
        return CANON_TO_KICAD[canon]
    return f"In{inner_layer_index(canon)}.Cu"


def kicad_to_canon(layer: Any) -> str:
    """KiCad copper layer name -> canonical id ("top"/"bottom"/"in<k>").

    "F.Cu"/"B.Cu"/"In<k>.Cu" map case-insensitively; an already-canonical id is
    returned unchanged (idempotent).

    FAILS VISIBLE, not closed. This is the READ side: refusing an unrecognised
    name would make an old or foreign board unloadable, so the historical
    lower-cased passthrough (and empty -> "top") is KEPT -- but now emits a
    ``warnings.warn`` so the oddball layer name is visible instead of silent.
    """
    s = str(layer or "").strip()
    low = s.lower()
    canon = _canon_or_none(low)
    if canon is not None:
        return canon
    if not low:
        warnings.warn(
            'empty layer name mapped to "top"; the caller should name a layer '
            "explicitly (agent_router.layers.kicad_to_canon)",
            stacklevel=2,
        )
        return "top"
    warnings.warn(
        f"unknown layer name {s!r} passed through as {low!r}; it is not a "
        "canonical copper id or a KiCad copper name "
        "(agent_router.layers.kicad_to_canon)",
        stacklevel=2,
    )
    return low


def is_copper(layer: Any) -> bool:
    """True iff ``layer`` names a canonical copper layer (canonical or KiCad
    spelling), INCLUDING inner layers in1..in30.

    Copper-ness is a NAMING question, not a fabricability one: an inner layer is
    copper, and is still refused by the compiler (see the module docstring).
    ``STACK_INDEX`` membership -- not this predicate -- is the test for "a layer
    this 2-layer pipeline can route and fabricate".
    """
    return _canon_or_none(layer) is not None


def is_legal_via_span(from_id: Any, to_id: Any) -> bool:
    """True iff a via may span ``from_id`` <-> ``to_id``.

    THROUGH-HOLE ONLY: a top<->bottom span is legal; a same-layer, degenerate,
    or inner-touching span is illegal. Derived from ``STACK_INDEX``, which holds
    only the two fabricable layers, so declaring inner layers does NOT make a
    blind/buried span legal -- blind/buried vias are not modeled at all, and
    would need an explicit span-rule/adjacency table, not merely more entries in
    ``STACK_INDEX``.
    """
    a = _canon_or_none(from_id)
    b = _canon_or_none(to_id)
    if a not in STACK_INDEX or b not in STACK_INDEX:
        return False
    return STACK_INDEX[a] != STACK_INDEX[b]
