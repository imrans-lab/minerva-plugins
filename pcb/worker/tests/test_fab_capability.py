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

    The two constants answer two different questions: EMITTED_LAYERS is "whose
    captured geometry reaches fabrication" (the compiler's accept-set, which
    drives the ``captured_geometry_not_emitted`` warning), and
    EMITTED_GERBER_SUFFIXES is "which files we write".

    One direction must stay absolute: a layer we CLAIM to fabricate with no file
    to put it in would be a silent loss, so the subset check below is strict.

    THE OTHER DIRECTION CLOSED IN EPOCH CP2 (station S3). B_SilkS used to be the
    sole gap — a file written for fab-package completeness whose captured
    geometry no emitter harvested — and this test pinned that gap at exactly one
    member. S3 gave the Gerber emitter a real bottom-silk harvest, so the gap is
    now EMPTY and the two sets correspond one-to-one.

    The pin stays, in the same spirit and now at zero: a NEW write-but-do-not-
    fabricate layer must be a deliberate, reviewed act, not something that
    appears because someone added a suffix. Loosening this to a subset check
    would let exactly that through.
    """
    expected = {layer.replace(".", "_") for layer in fab_capability.EMITTED_LAYERS}
    assert expected <= set(fab_capability.EMITTED_GERBER_SUFFIXES)
    assert set(fab_capability.EMITTED_GERBER_SUFFIXES) - expected == set()


def test_back_silk_is_both_written_and_claimed_as_fabricated():
    """B.SilkS, stated in the direction that matters — REVERSED IN CP2 S3.

    This test previously asserted the opposite ("written but NOT claimed"), and
    the reversal is the point of the station rather than a weakening: the old
    assertion protected a real warning about geometry that genuinely went
    nowhere. Now that ``gerber._emit_silk``/``_emit_refdes`` harvest the bottom
    side, that same warning would be FALSE, and claiming the layer is what
    retires it honestly.

    Both halves must still hold together. Claiming a layer whose file we do not
    write is a silent loss; writing a file whose layer we do not claim is a
    silent gap. The pairing is the invariant, not either half alone.
    """
    assert "B_SilkS" in fab_capability.EMITTED_GERBER_SUFFIXES
    assert "B.SilkS" in fab_capability.EMITTED_LAYERS


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
    # Fab/silk are never fabrication-critical (unemitted or cosmetic). Paste
    # MOVED into the fail-closed set at ff0544f (a lost stencil layer refuses
    # fabrication) — pinned present, not absent.
    for domain in ("fab", "silk"):
        assert domain not in fab_capability.FABRICATION_CRITICAL_OUTPUTS
    assert "paste" in fab_capability.FABRICATION_CRITICAL_OUTPUTS


def test_profile_declares_geometry_capability_dimensions():
    # The profile is not just filenames/layers: it also bounds pad shapes,
    # graphic primitives, and hole shapes the IR subset may contain (review 625.2).
    assert fab_capability.SUPPORTED_PAD_SHAPES >= {"rect", "roundrect", "circle", "oval"}
    assert fab_capability.SUPPORTED_GRAPHIC_PRIMITIVES == {"line", "circle", "arc", "poly"}
    assert fab_capability.SUPPORTED_HOLE_SHAPES == {"round", "circle"}
