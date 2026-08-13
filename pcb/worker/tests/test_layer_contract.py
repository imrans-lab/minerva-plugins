"""T1.5 — the ONE canonical layer-stack + via-span contract (worker side).

Locks the drift that caused the two-emitter via bug: route_bridge and kicad_io
must resolve the SAME mapping via agent_router.layers, not private copies.
"""

from __future__ import annotations

from agent_router import layers
from agent_router import kicad_io
from agent_router.kicad_io import Via
from pcb_worker import route_bridge
from pcb_worker import kicad


# ---------------------------------------------------------------------------
# Round-trip + empty-string defaults
# ---------------------------------------------------------------------------

import pytest


def test_canon_to_kicad_basic_and_default():
    assert layers.canon_to_kicad("top") == "F.Cu"
    assert layers.canon_to_kicad("bottom") == "B.Cu"
    # empty/None now FAIL CLOSED (ValueError) — the silent F.Cu default was
    # killed with the epoch-6 contract change; mirrors the GD-side pin in
    # pcb/tests/gd/test_layer_stack.gd (chore 019fb59164b6).
    import pytest
    with pytest.raises(ValueError):
        layers.canon_to_kicad("")
    with pytest.raises(ValueError):
        layers.canon_to_kicad(None)
    # unknown / already-KiCad passes through
    assert layers.canon_to_kicad("F.Cu") == "F.Cu"


def test_kicad_to_canon_basic_and_default():
    assert layers.kicad_to_canon("F.Cu") == "top"
    assert layers.kicad_to_canon("B.Cu") == "bottom"
    # empty -> top (mirrors pcb_data._canon_layer_name)
    assert layers.kicad_to_canon("") == "top"
    assert layers.kicad_to_canon(None) == "top"
    # case-insensitive
    assert layers.kicad_to_canon("f.cu") == "top"


def test_round_trip():
    for canon in ("top", "bottom"):
        assert layers.kicad_to_canon(layers.canon_to_kicad(canon)) == canon
    for kicad in ("F.Cu", "B.Cu"):
        assert layers.canon_to_kicad(layers.kicad_to_canon(kicad)) == kicad


# ---------------------------------------------------------------------------
# Drift regression — both emitters share ONE map object
# ---------------------------------------------------------------------------

def test_no_drift_between_emitters():
    # Same map object -> future edits to one physically edit the other. All
    # THREE worker copper-layer emitters share the one agent_router.layers dict.
    assert route_bridge._LAYER_MAP is layers.CANON_TO_KICAD
    assert kicad_io._CANON_TO_KICAD_LAYER is layers.CANON_TO_KICAD
    assert kicad._LAYER_MAP is layers.CANON_TO_KICAD
    assert route_bridge._LAYER_MAP is kicad_io._CANON_TO_KICAD_LAYER is kicad._LAYER_MAP
    # And they resolve identically for every canonical layer.
    for canon in ("top", "bottom"):
        assert route_bridge._canon_layer(canon) == layers.canon_to_kicad(canon)
        assert kicad._copper_layer(canon) == layers.canon_to_kicad(canon)
        assert kicad_io._CANON_TO_KICAD_LAYER[canon] == layers.CANON_TO_KICAD[canon]


def test_kicad_copper_layer_behaviour_locked():
    # kicad._copper_layer's EXACT contract, pinned so the dropped "" map key
    # (now handled by the function's fallthrough) can never silently regress.
    assert kicad._copper_layer("top") == "F.Cu"
    assert kicad._copper_layer("bottom") == "B.Cu"
    # empty -> F.Cu (was the "" map entry; now the final fallthrough)
    assert kicad._copper_layer("") == "F.Cu"
    # already-KiCad / unknown non-empty string passes through UNCHANGED,
    # WITHOUT case-folding
    assert kicad._copper_layer("F.Cu") == "F.Cu"
    assert kicad._copper_layer("Edge.Cuts") == "Edge.Cuts"
    assert kicad._copper_layer("In1.Cu") == "In1.Cu"
    # non-string (None etc.) -> F.Cu
    assert kicad._copper_layer(None) == "F.Cu"
    assert kicad._copper_layer(42) == "F.Cu"


# ---------------------------------------------------------------------------
# Via.from_canonical — canonical span -> KiCad, legacy span -> default
# ---------------------------------------------------------------------------

def test_via_from_canonical_spanned():
    via = Via.from_canonical(
        {"x_mm": 5.0, "y_mm": 6.0, "diameter_mm": 0.8, "drill_mm": 0.4,
         "from_layer": "top", "to_layer": "bottom"},
        net_number=3,
    )
    assert via.layers == ("F.Cu", "B.Cu")
    assert via.position == (5.0, 6.0)
    assert via.net == 3


def test_via_from_canonical_legacy_no_span_defaults():
    via = Via.from_canonical(
        {"x_mm": 1.0, "y_mm": 2.0, "diameter_mm": 0.8, "drill_mm": 0.4},
    )
    # No from/to -> dataclass default through-span.
    assert via.layers == ("F.Cu", "B.Cu")


# ---------------------------------------------------------------------------
# Via-span legality
# ---------------------------------------------------------------------------

def test_is_legal_via_span():
    assert layers.is_legal_via_span("top", "bottom") is True
    assert layers.is_legal_via_span("bottom", "top") is True
    # same-layer / degenerate is illegal
    assert layers.is_legal_via_span("top", "top") is False
    assert layers.is_legal_via_span("bottom", "bottom") is False
    # unknown layer -> illegal
    assert layers.is_legal_via_span("top", "inner1") is False
    # accepts KiCad names too (normalises first)
    assert layers.is_legal_via_span("F.Cu", "B.Cu") is True


def test_is_copper():
    assert layers.is_copper("top") is True
    assert layers.is_copper("B.Cu") is True
    assert layers.is_copper("inner1") is False


# ---------------------------------------------------------------------------
# Inner-layer naming (epoch GA-1). The FUNCTION-level mapping is what
# _build_layer_stack now aliases a declared stack through, so the in<k>
# round-trips graduate from incidental to load-bearing — and the through-only
# via rule must hold in its CANONICAL spelling (the pre-GA-1 test above pins
# only the non-canonical "inner1").
# ---------------------------------------------------------------------------


def test_inner_layer_canonical_round_trips():
    assert layers.canon_to_kicad("in1") == "In1.Cu"
    assert layers.canon_to_kicad("in30") == "In30.Cu"
    assert layers.canon_to_kicad("In7.Cu") == "In7.Cu"   # idempotent
    assert layers.kicad_to_canon("In1.Cu") == "in1"
    assert layers.kicad_to_canon("IN30.CU") == "in30"    # case-insensitive
    assert layers.kicad_to_canon("in7") == "in7"         # idempotent
    for k in (1, 7, 30):
        canon = f"in{k}"
        assert layers.kicad_to_canon(layers.canon_to_kicad(canon)) == canon
    assert layers.is_copper("in1") is True
    assert layers.is_copper("In30.Cu") is True


def test_inner_layer_rejects_off_by_one_spellings():
    for bad in ("in0", "in01", "in31", "In0.Cu", "In31.Cu"):
        with pytest.raises(ValueError):
            layers.canon_to_kicad(bad)
        assert layers.is_copper(bad) is False


def test_via_span_touching_a_canonical_inner_layer_is_illegal():
    # THE through-only rule, canonical spelling: declaring in<k> in a board's
    # stack must never make a partial span legal, because legality derives
    # from the deliberately-unwidened outer-pair table — blind/buried is
    # structurally unrepresentable, not policy-refused.
    assert layers.is_legal_via_span("top", "in1") is False
    assert layers.is_legal_via_span("in1", "bottom") is False
    assert layers.is_legal_via_span("in1", "in2") is False
    assert layers.is_legal_via_span("In1.Cu", "B.Cu") is False
    # And the full-stack span stays legal at any declared depth.
    assert layers.is_legal_via_span("top", "bottom") is True
