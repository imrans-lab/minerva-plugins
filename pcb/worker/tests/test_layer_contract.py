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

def test_canon_to_kicad_basic_and_default():
    assert layers.canon_to_kicad("top") == "F.Cu"
    assert layers.canon_to_kicad("bottom") == "B.Cu"
    # empty -> F.Cu (mirrors route_bridge._canon_layer)
    assert layers.canon_to_kicad("") == "F.Cu"
    assert layers.canon_to_kicad(None) == "F.Cu"
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
