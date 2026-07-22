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
    assert "captured_geometry_not_emitted" in codes  # F.Fab/F.CrtYd/paste are doc-only


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
    """EVERY placed pad, matched by (ref, source_id), equals an INDEPENDENT
    projection of a freshly-parsed footprint through the placement transform —
    on the COMPLETE field set: position, rotation, size, shape, full drill
    (shape/x/y/plating), corner ratio, both margins, side, and expanded layers
    (review 623 R6).  Exact equality, no rounding."""
    from pcb_worker.compile_board import _resolved_pad_layers
    from pcb_worker.footprint_def import FootprintDefinition
    from pcb_worker.footprints import resolve_footprint
    from pcb_worker.geometry import PlacementTransform

    src_by_ref = {c["ref"]: c for c in smart_remote["components"]}
    diags = _Diagnostics()
    checked = 0
    for comp in smart_remote_result.board.components:
        src = src_by_ref[comp.ref]
        fresh = FootprintDefinition.from_kicad_parsed(resolve_footprint(src["footprint"]))
        local_by_source = {p.source_id: p for p in fresh.pads}
        transform = PlacementTransform(position=comp.placement.position,
                                       rotation_deg=comp.placement.rotation_deg,
                                       side=comp.placement.side)
        for placed in comp.placed_pads:
            local = local_by_source[placed.source_id]
            assert placed.position == transform.point(local.position)
            assert placed.rotation_deg == transform.angle(local.rotation_deg)
            expected_size = (None if local.size is None
                             else (float(local.size[0]), float(local.size[1])))
            assert placed.size == expected_size
            assert placed.shape == local.shape
            assert placed.drill == local.drill            # shape + (x, y) + plating
            assert placed.corner_rratio == local.corner_rratio
            assert placed.solder_mask_margin == local.solder_mask_margin
            assert placed.solder_paste_margin == local.solder_paste_margin
            assert placed.side is comp.placement.side
            assert placed.layers == _resolved_pad_layers(local, transform, comp.ref, diags)
            checked += 1
    assert checked == 76
    assert not diags.has_error


def test_complete_graphic_projection_parity(smart_remote, smart_remote_result):
    """Every placed GRAPHIC, matched by (ref, source_id), equals an independent
    projection of a freshly-parsed footprint graphic through the placement
    transform — layer, primitive geometry, and width (review 625.5)."""
    from pcb_worker.compile_board import _to_geometry
    from pcb_worker.footprint_def import FootprintDefinition
    from pcb_worker.footprints import resolve_footprint
    from pcb_worker.geometry import PlacementTransform

    src_by_ref = {c["ref"]: c for c in smart_remote["components"]}
    checked = 0
    for comp in smart_remote_result.board.components:
        fresh = FootprintDefinition.from_kicad_parsed(
            resolve_footprint(src_by_ref[comp.ref]["footprint"]))
        local_by_source = {g.source_id: g for g in fresh.graphics}
        transform = PlacementTransform(position=comp.placement.position,
                                       rotation_deg=comp.placement.rotation_deg,
                                       side=comp.placement.side)
        for placed in comp.placed_graphics:
            local = local_by_source[placed.source_id]
            assert placed.layer == transform.layer(local.layer)
            assert placed.geometry == transform.graphic(_to_geometry(local))
            assert placed.width_mm == local.width_mm
            checked += 1
    assert checked == sum(len(c.placed_graphics) for c in smart_remote_result.board.components)
    assert checked == 207


def test_pad_position_cross_checks_the_live_path(smart_remote, smart_remote_result):
    """Independent cross-check: absolute pad centres also match the current
    resolve+place_point projection (a second algorithm)."""
    resolved = resolve_board(smart_remote)
    ref = {}
    for comp in resolved["components"]:
        cx, cy, rot = comp["x_mm"], comp["y_mm"], comp.get("rotation_deg", 0.0)
        for pad in comp.get("pads", []):
            ax, ay = place_point(cx, cy, rot, pad["position"]["x"], pad["position"]["y"])
            ref[(comp["ref"], str(pad["number"]))] = (round(ax, 6), round(ay, 6))
    index = smart_remote_result.board.footprint_index
    for comp in smart_remote_result.board.components:
        by_source = {p.source_id: p for p in index[comp.footprint_id].pads}
        for placed in comp.placed_pads:
            number = by_source[placed.source_id].number
            assert (round(placed.position[0], 6), round(placed.position[1], 6)) == ref[(comp.ref, number)]


def test_board_geometry_is_carried_faithfully(smart_remote, smart_remote_result):
    """Outline, traces, vias and holes are the authored geometry with COMPLETE
    properties — not dropped, not resampled, not partially compared."""
    board = smart_remote_result.board
    assert board.outline.width_mm == smart_remote["width_mm"]
    assert board.outline.height_mm == smart_remote["height_mm"]

    net_name = {n.id: n.name for n in board.nets}

    # Traces: full ordered polyline + width + layer + NET membership for EVERY trace.
    assert len(board.traces) == len(smart_remote["traces"])
    for src, got in zip(smart_remote["traces"], board.traces):
        pts = [(float(p["x_mm"]), float(p["y_mm"])) for p in src["points"]]
        seg_points = [got.segments[0].a] + [s.b for s in got.segments]
        assert seg_points == pts
        assert all(s.width_mm == src["width_mm"] for s in got.segments)
        assert all(s.layer.id == src["layer"] for s in got.segments)
        assert net_name[got.net_id] == src["net"]

    # Vias: position, diameter, drill, span, and net membership.
    src_vias = {(float(v["x_mm"]), float(v["y_mm"])): v for v in smart_remote["vias"]}
    assert len(board.vias) == len(src_vias)
    for via in board.vias:
        s = src_vias[(round(via.position[0], 6), round(via.position[1], 6))]
        assert via.diameter_mm == s["diameter_mm"]
        assert via.drill_mm == s["drill_mm"]
        assert {via.from_layer, via.to_layer} == {s["from_layer"], s["to_layer"]}
        assert net_name[via.net_id] == s["net"]

    # Holes: diameter, plating, and derived kind.
    src_holes = {(float(h["x_mm"]), float(h["y_mm"])): h for h in smart_remote["mounting_holes"]}
    assert len(board.holes) == len(src_holes)
    for hole in board.holes:
        s = src_holes[(round(hole.feature.position[0], 6), round(hole.feature.position[1], 6))]
        assert hole.feature.diameter_mm == s["diameter_mm"]
        assert hole.plated == s["plated"]
        assert hole.kind is (HoleKind.PTH if s["plated"] else HoleKind.NPTH)


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


def test_npth_pad_expands_declared_layers_without_synthesis():
    # The MountingHole footprint declares [*.Cu, *.Mask]; expansion must preserve
    # exactly that authored participation (review 623 R1), not drop it to ().
    result = compile_board(_one_component_board("MountingHole:MountingHole_3.2mm_M3"))
    pad = result.board.components[0].placed_pads[0]
    assert pad.pad_type == "np_thru_hole"
    assert {l.id for l in pad.layers} == {"F.Cu", "B.Cu", "F.Mask", "B.Mask"}


def test_pad_layer_expansion_never_synthesizes_absent_participation():
    # A pad authored on F.Cu only must resolve to F.Cu only — no invented mask/paste.
    from pcb_worker.compile_board import _resolved_pad_layers
    from pcb_worker.geometry import PlacementTransform
    diags = _Diagnostics()
    transform = PlacementTransform(position=(0.0, 0.0), rotation_deg=0.0, side=Side.TOP)
    pad = _synthetic_pad(layers=(Layer.from_id("F.Cu"),))
    layers = _resolved_pad_layers(pad, transform, "X1", diags)
    assert [l.id for l in layers] == ["F.Cu"]
    assert not diags.has_error


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
    """Fatal-output profile + emitter layers come from the shared authority and
    exclude unemitted paste/fab (review 623 R3/R5)."""
    from pcb_worker import fab_capability
    assert V1_FAB_OUTPUTS == fab_capability.FABRICATION_CRITICAL_OUTPUTS
    assert K3_EMITTED_LAYERS is fab_capability.EMITTED_LAYERS
    assert "paste" not in V1_FAB_OUTPUTS and "fab" not in V1_FAB_OUTPUTS
    assert "F.Paste" not in K3_EMITTED_LAYERS and "F.Fab" not in K3_EMITTED_LAYERS


def test_policy_blocks_rules_marker_when_rules_requested():
    """A dropped design-rule marker is fatal when 'rules' is requested — the IR
    feeds DRC/routing (review 623 R5)."""
    policy = DefaultCapabilityPolicy()
    marker = UnsupportedFeature(
        feature="local_clearance", domain=FeatureDomain.RULES, affected_layer=None,
        affected_outputs=("rules",), default_blocking=True, detail="local clearance",
        source_ref=SourceRef(EntityKind.PAD, "pad:1:0"))
    assert policy.is_blocking(marker, {}, ("rules",)) is True
    assert policy.is_blocking(marker, {}, V1_FAB_OUTPUTS) is True   # rules ∈ profile
    assert policy.is_blocking(marker, {}, ("copper",)) is False     # rules not requested


def test_policy_honors_affected_outputs():
    """Fatality considers the marker's explicit affected_outputs, not only its
    domain value (review 623 R5)."""
    policy = DefaultCapabilityPolicy()
    marker = UnsupportedFeature(
        feature="x", domain=FeatureDomain.DRILL, affected_layer=None,
        affected_outputs=("mask",), default_blocking=True, detail="d",
        source_ref=SourceRef(EntityKind.PAD, "pad:1:0"))
    assert policy.is_blocking(marker, {}, ("mask",)) is True     # via affected_outputs
    assert policy.is_blocking(marker, {}, ("silk",)) is False


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
    # An NPTH mechanical pad legitimately has a drill, no copper, and no size.
    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="np_thru_hole", size=None, layers=(),
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


def test_invalid_rotation_fails_closed():
    result = compile_board(_one_component_board("R_0805", rotation_deg="bad"))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_empty_zones_mapping_fails_closed():
    board = _one_component_board("R_0805")
    board["zones"] = {}  # malformed empty mapping — a declaration, not absence
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_board_feature" in _errors(result)


def test_empty_zones_list_is_allowed():
    board = _one_component_board("R_0805")
    board["zones"] = []  # explicitly nothing declared
    assert isinstance(compile_board(board), ResolutionSuccess)


def test_string_plated_fails_closed():
    board = _minimal_board(mounting_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2,
                                            "plated": "false"}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "hole_bad_plating" in _errors(result)


def test_malformed_lock_entry_fails_closed(tmp_path):
    import json
    lock = tmp_path / "bad.lock.json"
    lock.write_text(json.dumps({"R_0805": "not-a-mapping"}))
    result = compile_board(_one_component_board("R_0805"), lockfile=lock)
    assert isinstance(result, ResolutionFailure)
    assert "lock_entry_malformed" in _errors(result)


def test_net_pin_to_nonexistent_pad_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1", "NOPE.99"]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "net_pin_unresolved" in _errors(result)


def test_duplicate_pin_ownership_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]},
                     {"name": "N2", "pins": ["X1.1"]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "duplicate_pin_ownership" in _errors(result)


def test_entity_ids_are_board_namespaced():
    """The same ref/net in two different boards yields distinct ids (review 623 R4)."""
    def one(name):
        b = _one_component_board("R_0805")
        b["name"] = name
        b["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
        return compile_board(b)

    a, c = one("board-A"), one("board-B")
    assert isinstance(a, ResolutionSuccess) and isinstance(c, ResolutionSuccess)
    assert a.board.id != c.board.id
    assert a.board.components[0].id != c.board.components[0].id
    assert a.board.components[0].placed_pads[0].id != c.board.components[0].placed_pads[0].id
    assert a.board.nets[0].id != c.board.nets[0].id


def test_diff_pair_rule_loss_is_fatal_when_rules_requested():
    # Default profile requests 'rules'; dropping a known rule must fail (review 625.4).
    board = _one_component_board("R_0805")
    board["design_rules"]["diff_pair_gap_mm"] = 0.15
    board["design_rules"]["diff_pair_width_mm"] = 0.2
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_design_rule" in _errors(result)


def test_diff_pair_rule_loss_is_warned_when_cam_only():
    board = _one_component_board("R_0805")
    board["design_rules"]["diff_pair_gap_mm"] = 0.15
    result = compile_board(board, requested_outputs=("copper", "drill", "mask"))
    assert isinstance(result, ResolutionSuccess)
    assert any(d.code == "unsupported_design_rule" and d.severity is DiagnosticSeverity.WARNING
               for d in result.diagnostics)


# --- Round-4 regressions (review 625) -------------------------------------


@pytest.mark.parametrize("version", [0, 3, "1", 1.0, True])
def test_unsupported_schema_version_fails_closed(version):
    board = _one_component_board("R_0805")
    board["version"] = version   # non-int, int not in {1,2}, or float 1.0 — all rejected
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_schema_version" in _errors(result)


def test_missing_version_fails_closed():
    board = _one_component_board("R_0805")
    del board["version"]         # the integer version field is required
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_schema_version" in _errors(result)


# --- Round C1: schema-v2 fail-closed persistent identity (019f802ca3af) -------


def _mid(entity: str, n: int = 0) -> str:
    """A deterministic minted-shape id ('<entity>:<32 hex>') for tests — the
    shape the Go migration writes (migrate.go) and the v2 compiler requires."""
    return f"{entity}:{n:032x}"


def _v2_full_board() -> dict:
    """A properly-migrated v2 board: persisted minted ids on the board and every
    trace/via/hole."""
    board = _one_component_board("R_0805")
    board["version"] = 2
    board["id"] = _mid("board", 1)
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["traces"] = [{"id": _mid("trace", 1), "net": "N1", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 3, "y_mm": 3}]}]
    board["vias"] = [{"id": _mid("via", 1), "net": "N1", "x_mm": 5, "y_mm": 5,
                      "diameter_mm": 0.8, "drill_mm": 0.4, "from_layer": "top", "to_layer": "bottom"}]
    board["mounting_holes"] = [{"id": _mid("hole", 1), "x_mm": 2, "y_mm": 2, "diameter_mm": 3.0}]
    return board


def test_v2_board_with_minted_ids_compiles_and_reads_persisted_identity():
    result = compile_board(_v2_full_board())
    assert isinstance(result, ResolutionSuccess)
    codes = [d.code for d in result.diagnostics]
    assert "unminted_persistent_id" not in codes
    # v2 ids are persisted identity, so the ordinal-bridge INFO must NOT fire.
    assert "ordinal_ids" not in codes
    # The resolved IR carries the PERSISTED ids verbatim (not re-derived).
    assert result.board.id == _mid("board", 1)
    assert result.board.traces[0].id == _mid("trace", 1)
    assert result.board.vias[0].id == _mid("via", 1)
    assert result.board.holes[0].id == _mid("hole", 1)


def test_v2_board_missing_board_id_fails_closed():
    board = _v2_full_board()
    del board["id"]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unminted_persistent_id" in _errors(result)


@pytest.mark.parametrize("bad_id", [None, "", "trace_1", "trace:XYZ", "TRACE:" + "0" * 32,
                                    "trace:" + "0" * 31, "via:" + "0" * 32])
def test_v2_board_unminted_trace_id_fails_closed(bad_id):
    board = _v2_full_board()
    if bad_id is None:
        del board["traces"][0]["id"]
    else:
        board["traces"][0]["id"] = bad_id
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unminted_persistent_id" in _errors(result)


def test_v2_board_unminted_via_and_hole_ids_fail_closed():
    board = _v2_full_board()
    board["vias"][0]["id"] = "via_legacy"
    board["mounting_holes"][0]["id"] = "hole:not-hex-at-all-nope-nope-nope!!"
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unminted_persistent_id" in _errors(result)


def test_v1_board_still_emits_ordinal_bridge_not_id_requirement():
    # A v1 board with a trace keeps the permissive bridge: it does NOT require a
    # minted id and DOES emit the ordinal_ids INFO handoff diagnostic.
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 3, "y_mm": 3}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    codes = [d.code for d in result.diagnostics]
    assert "ordinal_ids" in codes
    assert "unminted_persistent_id" not in codes


def test_non_string_component_value_fails_closed():
    board = _one_component_board("R_0805")
    board["components"][0]["value"] = {"bad": 1}   # must not stringify into the IR
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_numeric_component_ref_fails_closed():
    board = _one_component_board("R_0805")
    board["components"][0]["ref"] = 123
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_non_string_trace_id_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["traces"] = [{"id": 123, "net": "N1", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 1, "y_mm": 1}, {"x_mm": 2, "y_mm": 2}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_authored_id" in _errors(result)


def test_trace_point_with_three_coords_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.3,
                        "points": [[1, 1, 999], [2, 2]]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "trace_bad_points" in _errors(result)


def test_uncanonicalizable_annotation_fails_closed():
    board = _one_component_board("R_0805")
    board["annotations"] = [{"id": "a", "big": 2 ** 60}]  # outside exactly-safe I-JSON
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "uncanonicalizable_board" in _errors(result)


def test_inline_pin_geometry_is_diagnosed(smart_remote_result):
    # smart_remote carries legacy inline drill/annulus on every pin.
    assert any(d.code == "inline_pin_geometry_ignored"
               and d.severity is DiagnosticSeverity.WARNING
               for d in smart_remote_result.diagnostics)


def test_pad_guard_rejects_smd_without_copper():
    diags = _Diagnostics()
    assert not _check_pad_capabilities(_synthetic_pad(pad_type="smd", layers=()), "X1", diags)
    assert "illegal_pad_definition" in [d.code for d in diags.tuple()]


def test_pad_guard_rejects_smd_with_drill():
    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="smd", drill=DrillDefinition(shape="round", size=(0.8, 0.8)))
    assert not _check_pad_capabilities(pad, "X1", diags)
    assert "illegal_pad_definition" in [d.code for d in diags.tuple()]


def test_pad_guard_rejects_through_hole_without_drill():
    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="thru_hole", drill=None,
                         layers=(Layer.from_id("F.Cu"), Layer.from_id("B.Cu")))
    assert not _check_pad_capabilities(pad, "X1", diags)
    assert "illegal_pad_definition" in [d.code for d in diags.tuple()]


def test_pin_partial_position_fails_closed():
    board = _one_component_board("R_0805")
    board["components"][0]["pins"] = [{"number": "1", "x_mm": 0.0}]  # y_mm missing
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "pin_partial_position" in _errors(result)


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
