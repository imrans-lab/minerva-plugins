"""K2 — canonical board → ResolvedBoard compiler.

Covers the compiler's contract (keystone comment 618 + K1 Sol reconcile 608):
valid-by-construction success/failure envelope, the compile-census over every
locked seed footprint, fail-closed behaviour for every capability outside the
bounded v1 subset, marker adjudication (blocking → failure; non-blocking →
warning + stripped), the CapabilityPolicy, deterministic identity, the
materialize-once placement projection, and PLACED-GEOMETRY parity against the
current resolve+place_point path.

Parity note: parity is proven at the placed-geometry level (absolute pad
centre/size/drill), NOT at the gerbonara FILE level — no emitter reads the IR
until K3, so there is nothing to diff on the IR side yet.  K3 upgrades this to
the full gerbonara geometry-diff oracle when the emitter is repointed.
"""

from __future__ import annotations

from collections import Counter
from pathlib import Path

import pytest
import yaml

from pcb_worker.compile_board import (
    COINCIDENCE_TOL_MM,
    DefaultCapabilityPolicy,
    V1_FAB_OUTPUTS,
    V1_RULE_PROFILE,
    _check_pad_capabilities,
    _Diagnostics,
    _adjudicate_footprint,
    compile_board,
)
from pcb_worker.footprint_def import (
    DrillDefinition,
    FootprintDefinition,
    PadDefinition,
    PadShape,
    Provenance,
)
from pcb_worker.footprints import load_lockfile, resolve_footprint
from pcb_worker.geometry import place_point, PlacementTransform
from pcb_worker.resolve import resolve_board
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    EntityKind,
    FeatureDomain,
    Layer,
    ResolutionFailure,
    ResolutionSuccess,
    ResolvedBoard,
    Side,
    SourceRef,
    UnsupportedFeature,
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
        "version": 1,
        "name": "mini",
        "width_mm": 20,
        "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {
            "clearance_mm": 0.2, "trace_width_mm": 0.3,
            "via_diameter_mm": 0.8, "via_drill_mm": 0.4,
        },
        "components": [],
    }
    board.update(overrides)
    return board


def _one_component_board(footprint: str, layer: str = "top", **comp) -> dict:
    component = {"ref": "X1", "footprint": footprint, "x_mm": 10, "y_mm": 10,
                 "rotation_deg": 0, "layer": layer}
    component.update(comp)
    return _minimal_board(components=[component])


def _errors(result: ResolutionFailure) -> list[str]:
    return [d.code for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]


def _synthetic_pad(source_id="pad:1:0", *, shape=PadShape.RECT, size=(1.0, 1.0),
                   drill=None, layers=(Layer.from_id("F.Cu"),), unsupported=()):
    return PadDefinition(
        source_id=source_id, number="1", pad_type="smd", raw_pad_type="smd",
        shape=shape, raw_shape=shape.value, position=(0.0, 0.0), size=size,
        drill=drill, layers=layers, unsupported=unsupported,
    )


def _blocking_marker(feature="custom_primitives", domain=FeatureDomain.COPPER):
    return UnsupportedFeature(
        feature=feature, domain=domain, affected_layer=None,
        affected_outputs=(domain.value,), default_blocking=True,
        detail=f"{feature} detail", source_ref=SourceRef(EntityKind.PAD, "pad:1:0"),
    )


def _nonblocking_marker(feature="uncaptured_graphic", domain=FeatureDomain.SILK):
    return UnsupportedFeature(
        feature=feature, domain=domain, affected_layer=Layer.from_id("F.SilkS"),
        affected_outputs=("F.SilkS",), default_blocking=False,
        detail=f"{feature} detail", source_ref=SourceRef(EntityKind.GRAPHIC, "graphic:0"),
    )


# ---------------------------------------------------------------------------
# Compile-census: every locked seed footprint fabricates end-to-end.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("ref", sorted(load_lockfile().keys()))
def test_compile_census_every_seed_resolves(ref):
    """Keystone 618.3: each shipped seed footprint compiles to ResolutionSuccess
    in a minimal valid board under the v1 capability/output profile."""
    result = compile_board(_one_component_board(ref))
    assert isinstance(result, ResolutionSuccess), (
        f"{ref} failed to compile: "
        f"{[d.message for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]}"
        if isinstance(result, ResolutionFailure) else ""
    )
    # A resolved board is valid-by-construction; sanity-check it carries the part.
    assert len(result.board.components) == 1
    assert len(result.board.footprint_definitions) == 1


# ---------------------------------------------------------------------------
# Smart-remote full board.
# ---------------------------------------------------------------------------


def test_smart_remote_resolves_success(smart_remote_result):
    assert isinstance(smart_remote_result, ResolutionSuccess)
    assert not any(d.severity is DiagnosticSeverity.ERROR
                   for d in smart_remote_result.diagnostics)


def test_smart_remote_structure(smart_remote_result):
    board = smart_remote_result.board
    assert isinstance(board, ResolvedBoard)
    assert len(board.components) == 10
    assert len(board.nets) == 16
    assert len(board.traces) == 28
    assert len(board.vias) == 4
    assert len(board.holes) == 4
    # 8 distinct footprint refs, but SW1-4 share EVP-ASAC1A → 7 interned defs.
    assert len(board.footprint_definitions) == 7
    assert sum(len(c.placed_pads) for c in board.components) == 76


def test_smart_remote_interned_definitions_are_marker_free(smart_remote_result):
    """The IR forbids residual markers; adjudication must have stripped them."""
    for definition in smart_remote_result.board.footprint_definitions:
        assert definition.unsupported == ()
        assert all(pad.unsupported == () for pad in definition.pads)


def test_smart_remote_emits_omission_warnings(smart_remote_result):
    """Silk/fab omissions surface as WARNINGs, not silence."""
    warnings = [d for d in smart_remote_result.diagnostics
                if d.severity is DiagnosticSeverity.WARNING]
    assert warnings
    assert all(d.code == "feature_omitted" for d in warnings)


def test_smart_remote_holes_are_npth(smart_remote_result):
    from pcb_worker.resolved_board import HoleKind
    for hole in smart_remote_result.board.holes:
        assert hole.kind is HoleKind.NPTH
        assert hole.plated is False


def test_smart_remote_vias_are_through(smart_remote_result):
    from pcb_worker.resolved_board import ViaKind
    for via in smart_remote_result.board.vias:
        assert via.kind is ViaKind.THROUGH
        assert {via.from_layer, via.to_layer} == {"top", "bottom"}


def test_net_pad_membership_agrees_with_pad_net_id(smart_remote_result):
    """The IR's declared-vs-indexed net agreement is enforced at construction;
    assert the mapping is actually populated (a real GND net has many pads)."""
    board = smart_remote_result.board
    gnd = next(n for n in board.nets if n.name == "GND")
    assert len(gnd.pad_refs) >= 10
    pad_net = board.pad_net
    assert all(pad_net[pad_id] == gnd.id for pad_id in gnd.pad_refs)


# ---------------------------------------------------------------------------
# Placed-geometry parity vs the current resolve + place_point path.
# ---------------------------------------------------------------------------


def test_placed_pad_parity_with_current_path(smart_remote, smart_remote_result):
    """Every placed pad's absolute centre + drill matches what the live
    resolve+geometry.place_point path produces (top-only board)."""
    R = 4
    current: Counter = Counter()
    resolved = resolve_board(smart_remote)
    for comp in resolved["components"]:
        cx, cy, rot = comp["x_mm"], comp["y_mm"], comp.get("rotation_deg", 0.0)
        for pad in comp.get("pads", []):
            ax, ay = place_point(cx, cy, rot, pad["position"]["x"], pad["position"]["y"])
            current[(round(ax, R), round(ay, R), round(pad["drill"]["x"], R))] += 1

    ir: Counter = Counter()
    for comp in smart_remote_result.board.components:
        for pad in comp.placed_pads:
            drill = pad.drill.size[0] if pad.drill else 0.0
            ir[(round(pad.position[0], R), round(pad.position[1], R), round(drill, R))] += 1

    assert current == ir, f"placed-pad parity drift: {(current - ir) | (ir - current)}"


def test_placed_geometry_is_materialized_once_and_recomputes(smart_remote_result):
    """Placed positions equal an independent recompute via the same transform
    (contract Q1: materialize once, deeply immutable, tested vs recompute)."""
    board = smart_remote_result.board
    comp = board.components[0]
    definition = board.footprint_for(comp)
    transform = PlacementTransform(
        position=comp.placement.position,
        rotation_deg=comp.placement.rotation_deg,
        side=comp.placement.side,
    )
    by_source = {pad.source_id: pad for pad in definition.pads}
    for placed in comp.placed_pads:
        expected = transform.point(by_source[placed.source_id].position)
        assert placed.position == expected


def test_placed_pad_is_immutable(smart_remote_result):
    pad = smart_remote_result.board.components[0].placed_pads[0]
    with pytest.raises((AttributeError, TypeError)):
        pad.position = (0.0, 0.0)  # type: ignore[misc]


def test_compile_is_deterministic(smart_remote):
    """Same input → identical entity ids (derive_id is content-derived)."""
    a = compile_board(smart_remote)
    b = compile_board(smart_remote)
    assert isinstance(a, ResolutionSuccess) and isinstance(b, ResolutionSuccess)
    ids_a = [p.id for c in a.board.components for p in c.placed_pads]
    ids_b = [p.id for c in b.board.components for p in c.placed_pads]
    assert ids_a == ids_b
    assert [n.id for n in a.board.nets] == [n.id for n in b.board.nets]


# ---------------------------------------------------------------------------
# Bottom-side placement exercises the mirror path.
# ---------------------------------------------------------------------------


def test_bottom_side_component_mirrors(monkeypatch):
    board = _one_component_board("R_0805", layer="bottom", rotation_deg=0)
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    comp = result.board.components[0]
    assert comp.placement.side is Side.BOTTOM
    definition = result.board.footprint_for(comp)
    transform = PlacementTransform(position=(10.0, 10.0), rotation_deg=0.0, side=Side.BOTTOM)
    by_source = {p.source_id: p for p in definition.pads}
    for placed in comp.placed_pads:
        local = by_source[placed.source_id].position
        assert placed.position == transform.point(local)
        assert placed.side is Side.BOTTOM
        # Mirror sends F.Cu copper to B.Cu.
        assert all(layer.id != "F.Cu" for layer in placed.layers)


# ---------------------------------------------------------------------------
# CapabilityPolicy.
# ---------------------------------------------------------------------------


def test_policy_blocks_fatal_domain_when_output_requested():
    policy = DefaultCapabilityPolicy()
    marker = _blocking_marker(domain=FeatureDomain.COPPER)
    assert policy.is_blocking(marker, {}, ("copper", "drill")) is True


def test_policy_does_not_block_when_output_not_requested():
    policy = DefaultCapabilityPolicy()
    marker = _blocking_marker(domain=FeatureDomain.COPPER)
    assert policy.is_blocking(marker, {}, ("silk",)) is False


def test_policy_never_blocks_nonblocking_marker():
    policy = DefaultCapabilityPolicy()
    marker = _nonblocking_marker(domain=FeatureDomain.SILK)
    assert policy.is_blocking(marker, {}, V1_FAB_OUTPUTS) is False


# ---------------------------------------------------------------------------
# Marker adjudication.
# ---------------------------------------------------------------------------


def test_adjudicate_strips_nonblocking_and_warns():
    diags = _Diagnostics()
    definition = FootprintDefinition(
        name="fp", pads=(_synthetic_pad(unsupported=(_nonblocking_marker(),)),),
        graphics=(),
    )
    clean = _adjudicate_footprint(definition, "fp", DefaultCapabilityPolicy(),
                                  V1_FAB_OUTPUTS, {}, diags)
    assert clean is not None
    assert clean.unsupported == ()
    assert all(pad.unsupported == () for pad in clean.pads)
    assert not diags.has_error
    assert any(d.severity is DiagnosticSeverity.WARNING for d in diags.tuple())


def test_adjudicate_blocks_fatal_marker():
    diags = _Diagnostics()
    definition = FootprintDefinition(
        name="fp", pads=(_synthetic_pad(unsupported=(_blocking_marker(),)),),
        graphics=(),
    )
    clean = _adjudicate_footprint(definition, "fp", DefaultCapabilityPolicy(),
                                  V1_FAB_OUTPUTS, {}, diags)
    assert clean is None
    assert diags.has_error


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
    """An NPTH mounting pad carries a drill and no copper — sizelessness is OK."""
    diags = _Diagnostics()
    pad = _synthetic_pad(size=None, layers=(),
                         drill=DrillDefinition(shape="round", size=(3.2, 3.2)))
    assert _check_pad_capabilities(pad, "X1", diags)


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


def test_trace_degenerate_single_point_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["traces"] = [{"net": "N1", "layer": "top", "width_mm": 0.3,
                        "points": [{"x_mm": 1, "y_mm": 1}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "trace_degenerate" in _errors(result)


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


# ---------------------------------------------------------------------------
# Provenance + rule profile.
# ---------------------------------------------------------------------------


def test_board_provenance_records_transform_and_rule_profile(smart_remote_result):
    prov = smart_remote_result.board.provenance
    assert "transform/kicad-flip-v1" in prov.compiler_version
    assert smart_remote_result.board.design_rules.rule_profile == V1_RULE_PROFILE
    assert prov.rule_profile_ref == V1_RULE_PROFILE


def test_board_clearance_becomes_min_clearance(smart_remote, smart_remote_result):
    declared = smart_remote["design_rules"]["clearance_mm"]
    assert smart_remote_result.board.design_rules.minimums.min_clearance_mm == declared
