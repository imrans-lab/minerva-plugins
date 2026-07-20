"""K2 — canonical board → ResolvedBoard compiler.

Covers the compiler's contract (keystone comment 618 + K1 Sol reconcile 608 +
K2 cold-review 621): valid-by-construction envelope; compile-census over every
locked seed; STRICT fail-closed behaviour (no silent geometry loss/alteration on
a successful compile); pad-layer expansion (no surviving wildcards); marker
adjudication with K2 as authority + the K3 emitter capability matrix; retained
source provenance + full digests; no invented stackup facts + a clearance that
never weakens the manufacturer floor; component value; and a COMPLETE
placed-geometry parity oracle against the current resolve+place_point path.

Parity is proven at the placed-geometry level (the complete projection keyed by
component ref + definition-local source id, plus the copied board geometry), NOT
the gerbonara FILE level — no emitter reads the IR until K3.  File-level parity
belongs to K3 (review 621, trap 1).
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker.compile_board import (
    COINCIDENCE_TOL_MM,
    K3_EMITTED_LAYERS,
    V1_FAB_OUTPUTS,
    V1_RULE_PROFILE,
    DefaultCapabilityPolicy,
    _Diagnostics,
    _adjudicate_footprint,
    _check_pad_capabilities,
    compile_board,
)
from pcb_worker.footprint_def import (
    DrillDefinition,
    FootprintDefinition,
    PadDefinition,
    PadShape,
)
from pcb_worker.footprints import load_lockfile
from pcb_worker.geometry import PlacementTransform, place_point
from pcb_worker.resolve import resolve_board
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    EntityKind,
    FeatureDomain,
    HoleKind,
    Layer,
    ResolutionFailure,
    ResolutionSuccess,
    ResolvedBoard,
    Side,
    SourceRef,
    UnsupportedFeature,
    ViaKind,
)

TESTDATA = Path(__file__).parent / "testdata"


# ---------------------------------------------------------------------------
# Fixtures / helpers.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def smart_remote() -> dict:
    return yaml.safe_load((TESTDATA / "smart_remote.yaml").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def smart_remote_result(smart_remote):
    return compile_board(smart_remote)


def _minimal_board(**overrides) -> dict:
    board = {
        "version": 1, "name": "mini", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
    }
    board.update(overrides)
    return board


def _one_component_board(footprint: str, layer: str = "top", **comp) -> dict:
    component = {"ref": "X1", "footprint": footprint, "x_mm": 10, "y_mm": 10,
                 "rotation_deg": 0, "layer": layer}
    component.update(comp)
    return _minimal_board(components=[component])


def _errors(result) -> list[str]:
    return [d.code for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]


def _synthetic_pad(source_id="pad:1:0", *, pad_type="smd", shape=PadShape.RECT,
                   size=(1.0, 1.0), drill=None, layers=(Layer.from_id("F.Cu"),), unsupported=()):
    return PadDefinition(
        source_id=source_id, number="1", pad_type=pad_type, raw_pad_type=pad_type,
        shape=shape, raw_shape=shape.value, position=(0.0, 0.0), size=size,
        drill=drill, layers=layers, unsupported=unsupported,
    )


def _blocking_marker(feature="custom_primitives", domain=FeatureDomain.COPPER):
    return UnsupportedFeature(
        feature=feature, domain=domain, affected_layer=None,
        affected_outputs=(domain.value,), default_blocking=True,
        detail=f"{feature} detail", source_ref=SourceRef(EntityKind.PAD, "pad:1:0"),
    )


def _hint_only_copper_marker():
    """A COPPER-loss marker the parser conservatively hinted as NON-blocking.
    K2 must still treat it as fatal when copper is requested (review 621 MF3)."""
    return UnsupportedFeature(
        feature="custom_primitives", domain=FeatureDomain.COPPER, affected_layer=None,
        affected_outputs=("copper",), default_blocking=False,
        detail="hint says non-blocking", source_ref=SourceRef(EntityKind.PAD, "pad:1:0"),
    )


def _nonblocking_marker(feature="uncaptured_graphic", domain=FeatureDomain.SILK):
    return UnsupportedFeature(
        feature=feature, domain=domain, affected_layer=Layer.from_id("F.SilkS"),
        affected_outputs=("F.SilkS",), default_blocking=False,
        detail=f"{feature} detail", source_ref=SourceRef(EntityKind.GRAPHIC, "graphic:0"),
    )


# ---------------------------------------------------------------------------
# Compile-census.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("ref", sorted(load_lockfile().keys()))
def test_compile_census_every_seed_resolves(ref):
    result = compile_board(_one_component_board(ref))
    assert isinstance(result, ResolutionSuccess), (
        f"{ref} failed: {[d.message for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]}"
        if isinstance(result, ResolutionFailure) else "")
    assert len(result.board.components) == 1
    assert len(result.board.footprint_definitions) == 1


# ---------------------------------------------------------------------------
# Smart-remote full board.
# ---------------------------------------------------------------------------


def test_smart_remote_resolves_success(smart_remote_result):
    assert isinstance(smart_remote_result, ResolutionSuccess)
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in smart_remote_result.diagnostics)


def test_smart_remote_structure(smart_remote_result):
    board = smart_remote_result.board
    assert isinstance(board, ResolvedBoard)
    assert len(board.components) == 10
    assert len(board.nets) == 16
    assert len(board.traces) == 28
    assert len(board.vias) == 4
    assert len(board.holes) == 4
    assert len(board.footprint_definitions) == 7  # SW1-4 share EVP-ASAC1A
    assert sum(len(c.placed_pads) for c in board.components) == 76


def test_smart_remote_interned_definitions_marker_free_but_provenanced(smart_remote_result):
    for definition in smart_remote_result.board.footprint_definitions:
        assert definition.unsupported == ()
        assert all(pad.unsupported == () for pad in definition.pads)
        # Source identity survives adjudication (review 621 MF4).
        assert definition.provenance is not None
        assert definition.provenance.source_id


def test_smart_remote_emits_omission_and_capability_warnings(smart_remote_result):
    codes = {d.code for d in smart_remote_result.diagnostics
             if d.severity is DiagnosticSeverity.WARNING}
    assert "feature_omitted" in codes
    assert "captured_graphic_not_emitted" in codes  # F.Fab/F.CrtYd are doc-only


def test_smart_remote_holes_are_npth(smart_remote_result):
    for hole in smart_remote_result.board.holes:
        assert hole.kind is HoleKind.NPTH and hole.plated is False


def test_smart_remote_vias_are_through(smart_remote_result):
    for via in smart_remote_result.board.vias:
        assert via.kind is ViaKind.THROUGH
        assert {via.from_layer, via.to_layer} == {"top", "bottom"}


def test_net_pad_membership_agrees(smart_remote_result):
    board = smart_remote_result.board
    gnd = next(n for n in board.nets if n.name == "GND")
    assert len(gnd.pad_refs) >= 10
    assert all(board.pad_net[pad_id] == gnd.id for pad_id in gnd.pad_refs)


def test_components_carry_value(smart_remote_result):
    by_ref = {c.ref: c for c in smart_remote_result.board.components}
    assert by_ref["U1"].value == "ESP32-S3-DevKitC-1"
    assert by_ref["BAT1"].value == "BATTERY"


# ---------------------------------------------------------------------------
# COMPLETE placed-geometry parity + board-geometry carriage (review 621 MF6).
# ---------------------------------------------------------------------------


def test_complete_pad_projection_parity(smart_remote, smart_remote_result):
    """Every placed pad, keyed by (ref, source_id), matches the current
    resolve+place_point projection on the fields BOTH represent: absolute
    position, size, shape, rotation, and the full drill (shape/x/y/plating).
    Layer expansion is asserted separately (K2 enriches wildcards)."""
    resolved = resolve_board(smart_remote)
    # Reference keyed by (ref, pad-number) — resolve keeps the footprint order.
    ref_pads: dict[tuple[str, str], dict] = {}
    for comp in resolved["components"]:
        cx, cy, rot = comp["x_mm"], comp["y_mm"], comp.get("rotation_deg", 0.0)
        for pad in comp.get("pads", []):
            ax, ay = place_point(cx, cy, rot, pad["position"]["x"], pad["position"]["y"])
            ref_pads[(comp["ref"], str(pad["number"]))] = {
                "pos": (round(ax, 5), round(ay, 5)),
                "size": (round(pad["size"]["width"], 5), round(pad["size"]["height"], 5)),
                "shape": pad["shape"],
                "drill_x": round(pad["drill"]["x"], 5),
            }

    definitions = smart_remote_result.board.footprint_index
    checked = 0
    for comp in smart_remote_result.board.components:
        by_source = {p.source_id: p for p in definitions[comp.footprint_id].pads}
        for placed in comp.placed_pads:
            number = by_source[placed.source_id].number
            ref = ref_pads[(comp.ref, number)]
            assert (round(placed.position[0], 5), round(placed.position[1], 5)) == ref["pos"]
            assert placed.size is not None
            assert (round(placed.size[0], 5), round(placed.size[1], 5)) == ref["size"]
            assert placed.shape.value == ref["shape"]
            drill_x = placed.drill.size[0] if placed.drill else 0.0
            assert round(drill_x, 5) == ref["drill_x"]
            checked += 1
    assert checked == 76


def test_board_geometry_is_carried_faithfully(smart_remote, smart_remote_result):
    """Outline, traces, vias and holes are the authored geometry — not dropped,
    not resampled."""
    board = smart_remote_result.board
    assert board.outline.width_mm == smart_remote["width_mm"]
    assert board.outline.height_mm == smart_remote["height_mm"]

    # Each authored trace's polyline survives as ordered segment endpoints.
    assert len(board.traces) == len(smart_remote["traces"])
    src = smart_remote["traces"][0]
    got = board.traces[0]
    pts = [(p["x_mm"], p["y_mm"]) for p in src["points"]]
    seg_points = [got.segments[0].a] + [s.b for s in got.segments]
    assert seg_points == pts
    assert all(s.width_mm == src["width_mm"] for s in got.segments)

    via_positions = {(round(v.position[0], 5), round(v.position[1], 5)) for v in board.vias}
    assert via_positions == {(v["x_mm"], v["y_mm"]) for v in smart_remote["vias"]}

    hole_positions = {(round(h.feature.position[0], 5), round(h.feature.position[1], 5))
                      for h in board.holes}
    assert hole_positions == {(h["x_mm"], h["y_mm"]) for h in smart_remote["mounting_holes"]}


def test_origin_is_preserved(smart_remote):
    board = dict(smart_remote)
    board["origin"] = {"x_mm": 7.0, "y_mm": 9.0}
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    assert result.board.outline.origin == (7.0, 9.0)


def test_placed_geometry_materialized_once_and_recomputes(smart_remote_result):
    board = smart_remote_result.board
    comp = board.components[0]
    definition = board.footprint_for(comp)
    transform = PlacementTransform(position=comp.placement.position,
                                   rotation_deg=comp.placement.rotation_deg,
                                   side=comp.placement.side)
    by_source = {pad.source_id: pad for pad in definition.pads}
    for placed in comp.placed_pads:
        assert placed.position == transform.point(by_source[placed.source_id].position)


def test_placed_pad_is_immutable(smart_remote_result):
    pad = smart_remote_result.board.components[0].placed_pads[0]
    with pytest.raises((AttributeError, TypeError)):
        pad.position = (0.0, 0.0)  # type: ignore[misc]


def test_compile_is_deterministic(smart_remote):
    a, b = compile_board(smart_remote), compile_board(smart_remote)
    assert isinstance(a, ResolutionSuccess) and isinstance(b, ResolutionSuccess)
    assert [p.id for c in a.board.components for p in c.placed_pads] == \
           [p.id for c in b.board.components for p in c.placed_pads]
    assert [n.id for n in a.board.nets] == [n.id for n in b.board.nets]


# ---------------------------------------------------------------------------
# Pad-layer expansion (review 621 MF2): no wildcard survives.
# ---------------------------------------------------------------------------


def test_no_placed_pad_retains_a_wildcard_layer(smart_remote_result):
    for comp in smart_remote_result.board.components:
        for pad in comp.placed_pads:
            assert all(not layer.is_wildcard for layer in pad.layers), \
                f"{comp.ref} pad {pad.source_id} kept a wildcard"


def test_through_hole_pad_expands_to_both_copper_and_mask():
    result = compile_board(_one_component_board("Package_DIP:DIP-6_W7.62mm_Socket"))
    pad = result.board.components[0].placed_pads[0]
    assert pad.pad_type == "thru_hole"
    assert {l.id for l in pad.layers} == {"F.Cu", "B.Cu", "F.Mask", "B.Mask"}


def test_smd_top_pad_expands_to_front_only():
    result = compile_board(_one_component_board("R_0805", layer="top"))
    pad = result.board.components[0].placed_pads[0]
    assert {l.id for l in pad.layers} == {"F.Cu", "F.Mask", "F.Paste"}


def test_smd_bottom_pad_mirrors_to_back():
    result = compile_board(_one_component_board("R_0805", layer="bottom"))
    comp = result.board.components[0]
    assert comp.placement.side is Side.BOTTOM
    for pad in comp.placed_pads:
        assert {l.id for l in pad.layers} == {"B.Cu", "B.Mask", "B.Paste"}
        assert pad.side is Side.BOTTOM


def test_npth_pad_has_no_copper_participation():
    result = compile_board(_one_component_board("MountingHole:MountingHole_3.2mm_M3"))
    pad = result.board.components[0].placed_pads[0]
    assert pad.pad_type == "np_thru_hole"
    assert pad.layers == ()


# ---------------------------------------------------------------------------
# CapabilityPolicy — K2 is authoritative, not the hint (review 621 MF3).
# ---------------------------------------------------------------------------


def test_policy_blocks_copper_marker_even_when_hint_says_nonblocking():
    policy = DefaultCapabilityPolicy()
    assert policy.is_blocking(_hint_only_copper_marker(), {}, ("copper",)) is True


def test_policy_does_not_block_when_output_not_requested():
    policy = DefaultCapabilityPolicy()
    assert policy.is_blocking(_blocking_marker(FeatureDomain.COPPER.value), {}, ("silk",)) is False


def test_policy_never_blocks_documentation_marker():
    policy = DefaultCapabilityPolicy()
    assert policy.is_blocking(_nonblocking_marker(domain=FeatureDomain.SILK), {}, V1_FAB_OUTPUTS) is False


def test_policy_zone_connect_is_context_sensitive():
    policy = DefaultCapabilityPolicy()
    zc = UnsupportedFeature(feature="zone_connect", domain=FeatureDomain.COPPER,
                            affected_layer=None, affected_outputs=("copper",),
                            default_blocking=False, detail="zc",
                            source_ref=SourceRef(EntityKind.PAD, "pad:1:0"))
    assert policy.is_blocking(zc, {}, V1_FAB_OUTPUTS) is False           # no zones → inert
    assert policy.is_blocking(zc, {"zones": [{}]}, V1_FAB_OUTPUTS) is True  # zones present → fatal


def test_v1_requested_outputs_do_not_claim_paste_or_fab():
    """Requested profile must match what K3 emits (review 621 MF3)."""
    assert "paste" not in V1_FAB_OUTPUTS
    assert "fab" not in V1_FAB_OUTPUTS
    assert "F.Paste" not in K3_EMITTED_LAYERS and "F.Fab" not in K3_EMITTED_LAYERS


# ---------------------------------------------------------------------------
# Marker adjudication.
# ---------------------------------------------------------------------------


def test_adjudicate_strips_nonblocking_and_warns():
    diags = _Diagnostics()
    definition = FootprintDefinition(name="fp",
                                     pads=(_synthetic_pad(unsupported=(_nonblocking_marker(),)),),
                                     graphics=())
    clean = _adjudicate_footprint(definition, "fp", DefaultCapabilityPolicy(), V1_FAB_OUTPUTS, {}, diags)
    assert clean is not None and clean.unsupported == ()
    assert all(pad.unsupported == () for pad in clean.pads)
    assert not diags.has_error
    assert any(d.severity is DiagnosticSeverity.WARNING for d in diags.tuple())


def test_adjudicate_blocks_fatal_marker():
    diags = _Diagnostics()
    definition = FootprintDefinition(name="fp",
                                     pads=(_synthetic_pad(unsupported=(_blocking_marker(),)),),
                                     graphics=())
    clean = _adjudicate_footprint(definition, "fp", DefaultCapabilityPolicy(), V1_FAB_OUTPUTS, {}, diags)
    assert clean is None and diags.has_error


# ---------------------------------------------------------------------------
# Fail-closed pad capability guards.
# ---------------------------------------------------------------------------


def test_pad_guard_rejects_unsupported_shape():
    diags = _Diagnostics()
    assert not _check_pad_capabilities(_synthetic_pad(shape=PadShape.CUSTOM), "X1", diags)
    assert "unsupported_pad_shape" in [d.code for d in diags.tuple()]


def test_pad_guard_rejects_sizeless_copper_pad():
    diags = _Diagnostics()
    assert not _check_pad_capabilities(_synthetic_pad(size=None), "X1", diags)
    assert "missing_pad_size" in [d.code for d in diags.tuple()]


def test_pad_guard_rejects_non_round_drill():
    diags = _Diagnostics()
    drill = DrillDefinition(shape="oval", size=(1.0, 2.0))
    assert not _check_pad_capabilities(_synthetic_pad(drill=drill), "X1", diags)
    assert "unsupported_hole" in [d.code for d in diags.tuple()]


def test_pad_guard_allows_sizeless_non_copper_hole():
    diags = _Diagnostics()
    pad = _synthetic_pad(size=None, layers=(),
                         drill=DrillDefinition(shape="round", size=(3.2, 3.2)))
    assert _check_pad_capabilities(pad, "X1", diags)


# ---------------------------------------------------------------------------
# Provenance, digests, rule profile, stackup (review 621 MF4/MF5).
# ---------------------------------------------------------------------------


def test_component_provenance_populated_from_lock(smart_remote_result):
    lock = load_lockfile()
    for comp in smart_remote_result.board.components:
        assert comp.provenance.source_id
        assert comp.provenance.sha256 == lock[comp.provenance.source_id]["sha256"]


def test_board_provenance_full_digests_and_transform(smart_remote_result):
    prov = smart_remote_result.board.provenance
    assert "transform/kicad-flip-v1" in prov.compiler_version
    assert len(prov.source_digest) == 64          # full SHA-256, not truncated
    assert len(prov.library_lock_ref) == 64
    assert len(V1_RULE_PROFILE.digest) == 64
    assert prov.rule_profile_ref == V1_RULE_PROFILE


def test_unreadable_lock_fails_closed(tmp_path):
    bad = tmp_path / "missing.lock.json"
    result = compile_board(_one_component_board("R_0805"), lockfile=bad)
    assert isinstance(result, ResolutionFailure)
    assert "lock_unreadable" in _errors(result)


def test_clearance_never_weakens_manufacturer_floor():
    board = _one_component_board("R_0805")
    board["design_rules"]["clearance_mm"] = 0.01  # below the 0.127 floor
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    assert result.board.design_rules.minimums.min_clearance_mm == 0.127


def test_authored_clearance_above_floor_is_honored(smart_remote_result):
    # smart_remote authors 0.2, above the 0.127 floor.
    assert smart_remote_result.board.design_rules.minimums.min_clearance_mm == 0.2


def test_stackup_asserts_no_invented_thickness(smart_remote_result):
    for entry in smart_remote_result.board.layer_stack.stackup.entries:
        assert entry.thickness_mm is None
        assert entry.material is None


def test_ordinal_id_bridge_is_diagnosed(smart_remote_result):
    assert any(d.code == "ordinal_ids" and d.severity is DiagnosticSeverity.INFO
               for d in smart_remote_result.diagnostics)


# ---------------------------------------------------------------------------
# Adversarial regressions — every review-621 MF1 silent-loss repro now FAILS.
# ---------------------------------------------------------------------------


def test_malformed_origin_fails_closed(smart_remote):
    board = dict(smart_remote)
    board["origin"] = {"x_mm": "nope"}
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_outline" in _errors(result)


def test_malformed_trace_point_is_not_stitched():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 1, "y_mm": 1}, {"bad": 2}, {"x_mm": 3, "y_mm": 3}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "trace_bad_points" in _errors(result)


def test_non_mapping_component_fails_closed():
    board = _minimal_board(components=["not-a-component"])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_declared_zones_fail_closed():
    board = _one_component_board("R_0805")
    board["zones"] = [{"net": "GND", "layer": "top"}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_board_feature" in _errors(result)


def test_unknown_component_side_fails_closed():
    result = compile_board(_one_component_board("R_0805", layer="nonsense"))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_non_list_traces_fails_closed():
    board = _one_component_board("R_0805")
    board["traces"] = {"net": "N1"}
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_trace" in _errors(result)


# ---------------------------------------------------------------------------
# Board-level fail-closed cases.
# ---------------------------------------------------------------------------


def test_unknown_footprint_fails_closed():
    result = compile_board(_one_component_board("NoSuch:Footprint"))
    assert isinstance(result, ResolutionFailure)
    assert "footprint_unresolved" in _errors(result)


def test_missing_design_rules_fails_closed():
    board = _minimal_board()
    del board["design_rules"]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "missing_design_rules" in _errors(result)


def test_non_two_layer_stack_fails_closed():
    result = compile_board(_minimal_board(layers=["top", "inner1", "bottom"]))
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_layer_stack" in _errors(result)


def test_missing_outline_fails_closed():
    board = _minimal_board()
    board["width_mm"] = 0
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_outline" in _errors(result)


def test_via_drill_not_smaller_than_diameter_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["vias"] = [{"x_mm": 5, "y_mm": 5, "drill_mm": 0.8, "diameter_mm": 0.8,
                      "net": "N1", "from_layer": "top", "to_layer": "bottom"}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "via_bad_size" in _errors(result)


def test_via_same_layer_span_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["vias"] = [{"x_mm": 5, "y_mm": 5, "drill_mm": 0.4, "diameter_mm": 0.8,
                      "net": "N1", "from_layer": "top", "to_layer": "top"}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "via_bad_span" in _errors(result)


def test_trace_unknown_net_fails_closed():
    board = _one_component_board("R_0805")
    board["traces"] = [{"net": "ghost", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 2, "y_mm": 2}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "trace_unknown_net" in _errors(result)


def test_bad_pin_ref_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["bogusref"]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_pin_ref" in _errors(result)


def test_failure_envelope_always_carries_an_error():
    result = compile_board(_minimal_board(name=""))
    assert isinstance(result, ResolutionFailure)
    assert any(d.severity is DiagnosticSeverity.ERROR for d in result.diagnostics)
