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
    # Every emitted canonical layer corresponds to one produced Gerber suffix.
    expected = {layer.replace(".", "_") for layer in fab_capability.EMITTED_LAYERS}
    assert expected == set(fab_capability.EMITTED_GERBER_SUFFIXES)


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
