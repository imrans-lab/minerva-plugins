"""The neutral fabrication-capability profile must equal the emitter's ACTUAL
artifact set (K2 review 623, decision a).

This is the drift guard: if gerber.py adds or drops a layer, this test fails
until fab_capability is updated to match, so neither the compiler nor the
emitter can silently diverge from the shared authority.
"""

from __future__ import annotations

from pcb_worker import fab_capability, gerber


def test_profile_matches_the_emitter_gerber_suffixes():
    assert set(gerber._GERBER_SUFFIXES) == set(fab_capability.EMITTED_GERBER_SUFFIXES)


def test_emitted_layers_map_to_the_gerber_suffixes():
    """Every FABRICATED layer has a file — but not every file fabricates a layer.

    This used to be an equality. It is deliberately a SUBSET now, because the two
    constants answer two different questions: EMITTED_LAYERS is "whose captured
    geometry reaches fabrication" (the compiler's accept-set, which drives the
    ``captured_geometry_not_emitted`` warning), and EMITTED_GERBER_SUFFIXES is
    "which files we write".

    One direction must stay absolute: a layer we CLAIM to fabricate with no file
    to put it in would be a silent loss, so the subset check below is strict.
    The other direction is where B_SilkS lives — a file written for fab-package
    completeness whose captured geometry we do NOT yet emit (no bottom-silk
    harvest exists). Keeping B.SilkS out of EMITTED_LAYERS is what preserves the
    warning for a bottom-side component's silk.
    """
    expected = {layer.replace(".", "_") for layer in fab_capability.EMITTED_LAYERS}
    assert expected <= set(fab_capability.EMITTED_GERBER_SUFFIXES)
    # The gap is EXACTLY the known write-but-do-not-fabricate case. Pinned so a
    # future layer cannot join it silently: adding one here is a deliberate act.
    assert set(fab_capability.EMITTED_GERBER_SUFFIXES) - expected == {"B_SilkS"}


def test_back_silk_is_written_but_not_claimed_as_fabricated():
    """The B.SilkS asymmetry, stated once, in the direction that matters.

    A file is present so the fab package has all nine of KiCad's default layers;
    the layer is absent from the accept-set so the compiler still warns that a
    bottom component's silk is not fabricated. Both halves must hold, or the gap
    goes silent.
    """
    assert "B_SilkS" in fab_capability.EMITTED_GERBER_SUFFIXES
    assert "B.SilkS" not in fab_capability.EMITTED_LAYERS


def test_paste_is_fabricated_and_fab_layer_is_not():
    """F.Paste/B.Paste ARE fabricated now (real stencil apertures from real pad
    geometry). F.Fab is not, and must never be: KiCad's own .gbrjob classifies it
    ``AssemblyDrawing,Top`` — KiCad itself says it is not a fabrication layer."""
    assert {"F.Paste", "B.Paste"} <= fab_capability.EMITTED_LAYERS
    assert {"F_Paste", "B_Paste"} <= fab_capability.EMITTED_GERBER_SUFFIXES
    assert "F.Fab" not in fab_capability.EMITTED_LAYERS
    assert "F_Fab" not in fab_capability.EMITTED_GERBER_SUFFIXES
    assert "B_Fab" not in fab_capability.EMITTED_GERBER_SUFFIXES


def test_edge_cuts_width_is_the_single_source_both_emitters_read():
    """One constant governs the board-outline stroke, and BOTH emitters read THIS
    one — not a mirrored literal each. The value is KiCad's own default (0.05,
    measured off BOARD_DESIGN_SETTINGS.GetLineThickness(Edge_Cuts) in 10.0.5).

    The identity checks are the load-bearing part: an emitter that reintroduces a
    literal stops being `is`-identical to the authority and fails here.
    """
    from pcb_worker import kicad

    assert fab_capability.EDGE_CUTS_WIDTH_MM == 0.05
    assert gerber.EDGE_CUTS_WIDTH_MM is fab_capability.EDGE_CUTS_WIDTH_MM
    assert kicad.EDGE_CUTS_WIDTH_MM is fab_capability.EDGE_CUTS_WIDTH_MM


def test_fabrication_critical_outputs_exclude_unemitted_domains():
    # Paste/fab/silk are never fabrication-critical (unemitted or cosmetic).
    for domain in ("paste", "fab", "silk"):
        assert domain not in fab_capability.FABRICATION_CRITICAL_OUTPUTS


def test_profile_declares_geometry_capability_dimensions():
    # The profile is not just filenames/layers: it also bounds pad shapes,
    # graphic primitives, and hole shapes the IR subset may contain (review 625.2).
    assert fab_capability.SUPPORTED_PAD_SHAPES >= {"rect", "roundrect", "circle", "oval"}
    assert fab_capability.SUPPORTED_GRAPHIC_PRIMITIVES == {"line", "circle", "arc", "poly"}
    assert fab_capability.SUPPORTED_HOLE_SHAPES == {"round", "circle"}
