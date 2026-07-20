"""Construction-time invariants for the fabrication-complete PCB IR."""

from __future__ import annotations

from dataclasses import replace
from types import MappingProxyType

import pytest

from agent_router.layers import CANON_TO_KICAD, STACK_INDEX
from pcb_worker.canonical_id import derive_id
from pcb_worker.footprint_def import FootprintDefinition, PadDefinition, PadShape, Provenance
from pcb_worker.resolved_board import (
    BoardProvenance,
    Diagnostic,
    DiagnosticSeverity,
    EntityKind,
    Layer,
    LayerStack,
    ManufacturingConstraints,
    PhysicalStackup,
    Placement,
    PlacedPad,
    PreviewBoard,
    RectOutline,
    ResolvedBoard,
    ResolvedComponent,
    ResolvedDesignRules,
    ResolvedLayer,
    ResolvedNet,
    ResolvedTrace,
    ResolvedTraceSegment,
    ResolvedVia,
    ResolutionFailure,
    ResolutionSuccess,
    RoutingDefaults,
    RuleProfileRef,
    Side,
    SourceRef,
    StackupEntry,
    StackupKind,
    UnsupportedFeature,
    FeatureDomain,
    ViaKind,
)


def _rules() -> ResolvedDesignRules:
    return ResolvedDesignRules(
        defaults=RoutingDefaults(0.25, 0.8, 0.4),
        minimums=ManufacturingConstraints(
            min_trace_width_mm=0.15,
            min_clearance_mm=0.15,
            min_drill_mm=0.2,
            min_finished_hole_mm=0.2,
            min_annular_ring_mm=0.1,
            min_hole_to_hole_mm=0.25,
            min_mask_sliver_mm=0.08,
            solder_mask_clearance_mm=0.05,
            solder_mask_expansion_mm=0.0,
            copper_to_edge_mm=0.3,
        ),
        allowed_via_kinds=(ViaKind.THROUGH,),
        net_classes=(),
        rule_profile=RuleProfileRef("house-a", "1", "sha256:rules"),
    )


def _stack() -> LayerStack:
    copper = tuple(
        ResolvedLayer(canon, CANON_TO_KICAD[canon], STACK_INDEX[canon])
        for canon in sorted(STACK_INDEX, key=STACK_INDEX.get)
    )
    return LayerStack(
        copper=copper,
        stackup=PhysicalStackup((
            StackupEntry("stack:top", 0, StackupKind.COPPER, 0.035, copper_layer_id="top"),
            StackupEntry("stack:core", 1, StackupKind.DIELECTRIC, 1.53, material="FR4"),
            StackupEntry("stack:bottom", 2, StackupKind.COPPER, 0.035, copper_layer_id="bottom"),
        )),
        technical=(Layer.from_id("F.Mask"), Layer.from_id("B.Mask"),
                   Layer.from_id("Edge.Cuts")),
    )


def _definition(*, unsupported=()) -> FootprintDefinition:
    return FootprintDefinition(
        name="Test:OnePad",
        pads=(PadDefinition(
            source_id="pad:1:0",
            number="1",
            pad_type="smd",
            raw_pad_type="smd",
            shape=PadShape.RECT,
            raw_shape="rect",
            position=(0.0, 0.0),
            size=(1.2, 0.8),
            layers=(Layer.from_id("F.Cu"), Layer.from_id("F.Mask")),
        ),),
        provenance=Provenance("seed:Test:OnePad", "abc", "MIT", "2026-07-19"),
        unsupported=unsupported,
    )


def _board() -> ResolvedBoard:
    board_id = "board:example"
    component_id = "U1"
    pad_id = derive_id("placed-pad", board_id, component_id, "pad:1:0")
    net_id = "net:vcc"
    definition = _definition()
    component = ResolvedComponent(
        id=component_id,
        ref="U1",
        footprint_id=definition.content_id,
        placement=Placement((5.0, 6.0), 0.0, Side.TOP),
        placed_pads=(PlacedPad(
            id=pad_id,
            component_id=component_id,
            source_id="pad:1:0",
            net_id=net_id,
            pad_type="smd",
            shape=PadShape.RECT,
            position=(5.0, 6.0),
            size=(1.2, 0.8),
            rotation_deg=0.0,
            corner_rratio=None,
            drill=None,
            annulus=None,
            solder_mask_margin=None,
            solder_paste_margin=None,
            layers=(Layer.from_id("top"), Layer.from_id("F.Mask")),
            side=Side.TOP,
        ),),
        placed_graphics=(),
        provenance=definition.provenance,
    )
    net = ResolvedNet(net_id, "VCC", 1, (pad_id,))
    trace = ResolvedTrace(
        "trace:vcc-1", net_id,
        (ResolvedTraceSegment(
            "segment:vcc-1", (5.0, 6.0), (8.0, 6.0), 0.25,
            Layer.from_id("top"),
        ),),
    )
    via = ResolvedVia(
        "via:vcc-1", (8.0, 6.0), 0.8, 0.4, net_id,
        ViaKind.THROUGH, "top", "bottom", False, False,
    )
    rules = _rules()
    return ResolvedBoard(
        id=board_id,
        name="example",
        outline=RectOutline((0.0, 0.0), 20.0, 10.0),
        layer_stack=_stack(),
        design_rules=rules,
        footprint_definitions=(definition,),
        nets=(net,),
        components=(component,),
        traces=(trace,),
        vias=(via,),
        holes=(),
        zones=(),
        board_graphics=(),
        provenance=BoardProvenance(
            "k2-test", "sha256:board", "lock:v1", rules.rule_profile,
        ),
    )


def test_valid_board_has_immutable_derived_indexes():
    board = _board()
    component = board.components[0]
    pad = component.placed_pads[0]
    assert board.footprint_for(component) is board.footprint_definitions[0]
    assert board.net_index == {"net:vcc": 1}
    assert board.pad_net == {pad.id: "net:vcc"}
    assert isinstance(board.footprint_index, MappingProxyType)
    with pytest.raises(TypeError):
        board.net_index["net:other"] = 2


def test_layer_stack_matches_existing_worker_authority():
    stack = _stack()
    assert {layer.id: layer.kicad_alias for layer in stack.copper} == CANON_TO_KICAD
    assert {layer.id: layer.stack_index for layer in stack.copper} == STACK_INDEX


@pytest.mark.parametrize("mutation, match", [
    (lambda board: replace(board, nets=(board.nets[0], board.nets[0])), "duplicate ids"),
    (lambda board: replace(
        board,
        components=(replace(board.components[0], footprint_id="missing"),),
    ), "unknown footprint"),
    (lambda board: replace(
        board,
        nets=(replace(board.nets[0], pad_refs=()),),
    ), "pad_refs disagree"),
    (lambda board: replace(
        board,
        traces=(replace(
            board.traces[0],
            segments=(replace(
                board.traces[0].segments[0], layer=Layer.from_id("In99.Cu"),
            ),),
        ),),
    ), "unknown copper layer"),
    (lambda board: replace(
        board,
        vias=(replace(board.vias[0], kind=ViaKind.BLIND),),
    ), "disallowed via kind"),
])
def test_board_rejects_dangling_or_inconsistent_relations(mutation, match):
    with pytest.raises(ValueError, match=match):
        mutation(_board())


def test_resolved_board_rejects_unsupported_placeholders():
    marker = UnsupportedFeature(
        "fp_text", FeatureDomain.SILK, Layer.from_id("F.SilkS"),
        ("F.SilkS",), False, "unmodeled text",
        SourceRef(EntityKind.FOOTPRINT, "Test:OnePad"),
    )
    board = _board()
    marked = _definition(unsupported=(marker,))
    with pytest.raises(ValueError, match="unresolved footprint feature"):
        replace(
            board,
            footprint_definitions=(marked,),
            components=(replace(board.components[0], footprint_id=marked.content_id),),
        )


def test_resolution_envelope_separates_success_warnings_and_failure():
    warning = Diagnostic(
        DiagnosticSeverity.WARNING, "footprint.text_omitted", "text omitted",
        SourceRef(EntityKind.COMPONENT, "U1"),
    )
    success = ResolutionSuccess(_board(), (warning,))
    assert success.board.name == "example"
    assert success.diagnostics == (warning,)

    error = replace(warning, severity=DiagnosticSeverity.ERROR,
                    code="footprint.pad_missing", message="pad missing")
    assert ResolutionFailure((error,)).diagnostics == (error,)
    with pytest.raises(ValueError, match="cannot carry error"):
        ResolutionSuccess(_board(), (error,))
    with pytest.raises(ValueError, match="at least one error"):
        ResolutionFailure((warning,))


def test_preview_board_is_separate_and_may_be_partial():
    preview = PreviewBoard("yaml:board", "partial", None, None, (), ())
    assert preview.outline is None
    assert preview.components == ()


@pytest.mark.parametrize("bad", [float("nan"), float("inf"), -float("inf")])
def test_geometry_rejects_nonfinite_values(bad):
    with pytest.raises(ValueError, match="finite"):
        RectOutline((bad, 0.0), 1.0, 1.0)


def test_component_value_defaults_empty_and_accepts_string():
    # value is additive (K2 review 621 MF7); the KiCad exporter consumes it.
    assert _board().components[0].value == ""
    component = replace(_board().components[0], value="NE555")
    assert component.value == "NE555"


def test_component_value_must_be_string():
    with pytest.raises(TypeError, match="value"):
        replace(_board().components[0], value=555)
