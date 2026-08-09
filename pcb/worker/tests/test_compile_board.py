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

import copy
import json
import re
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml

from pcb_worker.compile_board import (
    COINCIDENCE_TOL_MM,
    DEFAULT_ROUNDRECT_RRATIO,
    K3_EMITTED_LAYERS,
    V1_FAB_OUTPUTS,
    V1_ROUTING_OUTPUTS,
    V1_RULE_PROFILE,
    DefaultCapabilityPolicy,
    _Diagnostics,
    _adjudicate_footprint,
    _check_coincidence,
    _check_pad_capabilities,
    _place_component,
    _validate_pin_override,
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
def corner_board() -> dict:
    """The primary compile-board fixture (docket 019fbe68c5f8).

    Was ``testdata/smart_remote.yaml``, a REAL Turnrock product board, withdrawn
    from this public repo on 2026-07-30 (testdata/POLICY.md) because a real
    design is an IP leak. Replaced by ``testdata/parity_corners.yaml`` — a small,
    purpose-built synthetic board (4 components) deliberately authored to reach
    specific geometry classes: through-hole + SMD pads, both board sides, oblong
    (non-square) rotated lands, a plated AND an unplated board hole, a via, and a
    half-turn placement. See that file's own header comment for the full gap
    analysis. NEVER restore the deleted fixture from git history — that IS the
    IP leak the policy exists to prevent.
    """
    return yaml.safe_load((TESTDATA / "parity_corners.yaml").read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def corner_board_result(corner_board):
    return compile_board(corner_board)


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
                   size=(1.0, 1.0), drill=None, layers=(Layer.from_id("F.Cu"),),
                   unsupported=(), corner_rratio=None):
    return PadDefinition(
        source_id=source_id, number="1", pad_type=pad_type, raw_pad_type=pad_type,
        shape=shape, raw_shape=shape.value, position=(0.0, 0.0), size=size,
        drill=drill, layers=layers, unsupported=unsupported,
        corner_rratio=corner_rratio,
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


def test_smart_remote_resolves_success(corner_board_result):
    assert isinstance(corner_board_result, ResolutionSuccess)
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in corner_board_result.diagnostics)


def test_smart_remote_structure(corner_board, corner_board_result):
    board = corner_board_result.board
    assert isinstance(board, ResolvedBoard)
    # Counts are read from the SOURCE dict rather than hard-coded (docket
    # 019fbe68c5f8) so this stays correct if parity_corners.yaml is ever
    # extended, instead of drifting the way the withdrawn smart_remote.yaml's
    # hard-coded 10/16/28/4/4/7/76 did the moment the fixture changed.
    assert len(board.components) == len(corner_board["components"])
    assert len(board.nets) == len(corner_board["nets"])
    assert len(board.traces) == len(corner_board["traces"])
    assert len(board.vias) == len(corner_board["vias"])
    assert len(board.holes) == (len(corner_board.get("mounting_holes", []))
                                 + len(corner_board.get("pth_holes", []))
                                 + len(corner_board.get("npth_holes", [])))
    # Footprint definitions are interned by footprint STRING (U2 and U3 both
    # reference Package_DIP:DIP-6_W7.62mm_Socket), so this is distinct
    # footprints referenced, not component count.
    assert len(board.footprint_definitions) == len(
        {c["footprint"] for c in corner_board["components"]})
    # placed_pads is the FOOTPRINT's full pad set, not the authored `pins:`
    # override list (which may cover only a subset of a footprint's pins) —
    # not derivable from the source dict alone, so it stays a literal. Was 76
    # against the withdrawn smart_remote.yaml; parity_corners.yaml's 4
    # components (J1=4, U2=6, SW9=2, U3=6 pads) total 18.
    assert sum(len(c.placed_pads) for c in board.components) == 18


def test_smart_remote_interned_definitions_marker_free_but_provenanced(corner_board_result):
    for definition in corner_board_result.board.footprint_definitions:
        assert definition.unsupported == ()
        assert all(pad.unsupported == () for pad in definition.pads)
        # Source identity survives adjudication (review 621 MF4).
        assert definition.provenance is not None
        assert definition.provenance.source_id


def test_smart_remote_emits_omission_and_capability_warnings(corner_board_result):
    codes = {d.code for d in corner_board_result.diagnostics
             if d.severity is DiagnosticSeverity.WARNING}
    assert "feature_omitted" in codes
    assert "captured_geometry_not_emitted" in codes  # F.Fab/F.CrtYd/paste are doc-only


def test_smart_remote_holes_are_npth(corner_board_result):
    # On the withdrawn smart_remote.yaml every mounting hole was unplated, so
    # this test's property was "every hole is NPTH". parity_corners.yaml's GAP
    # 3 (see its own header) deliberately authors ONE plated hole alongside the
    # unplated one, precisely so the PTH/NPTH split is cross-checked — so the
    # property this test proves now is that a hole's KIND is correctly DERIVED
    # from its authored plating (never invented, never dropped), which is
    # actually a stronger and more faithful claim than the old blanket NPTH one.
    holes = corner_board_result.board.holes
    # Guard against VACUITY, not against a count regression — see
    # test_smart_remote_structure for where the count itself is pinned (from
    # the source dict, not a literal here).
    assert holes, "no holes emitted — the assertion below would never run"
    # ...and guard the branch coverage itself: if the fixture ever collapsed
    # back to one plating value, the loop below would still pass while
    # exercising only half of what it claims to.
    assert {h.plated for h in holes} == {True, False}, (
        "expected both a plated and an unplated hole (parity_corners.yaml GAP 3)")
    for hole in holes:
        assert hole.kind is (HoleKind.PTH if hole.plated else HoleKind.NPTH)


def test_smart_remote_vias_are_through(corner_board_result):
    vias = corner_board_result.board.vias
    # Same vacuity guard, same reasoning — see test_smart_remote_holes_are_npth.
    assert vias, "no vias emitted — the assertions below would never run"
    for via in vias:
        assert via.kind is ViaKind.THROUGH
        assert {via.from_layer, via.to_layer} == {"top", "bottom"}


def test_net_pad_membership_agrees(corner_board_result):
    # parity_corners.yaml has no GND net (its nets are N_OBL/N_BOT/N_HT), so
    # the property is proven over EVERY net rather than one hard-coded name —
    # which is a strictly stronger form of the same check (docket 019fbe68c5f8).
    board = corner_board_result.board
    assert board.nets, "no nets emitted — the assertions below would never run"
    for net in board.nets:
        assert net.pad_refs, f"net {net.name!r} owns no pads"
        assert all(board.pad_net[pad_id] == net.id for pad_id in net.pad_refs)


def test_components_carry_value(corner_board, corner_board_result):
    # Checked against EVERY component's authored value, read from the source
    # dict, rather than two hard-coded refs that only existed on the withdrawn
    # smart_remote.yaml (docket 019fbe68c5f8).
    by_ref = {c.ref: c for c in corner_board_result.board.components}
    src_value = {c["ref"]: c["value"] for c in corner_board["components"]}
    assert src_value, "no components authored — the assertion below would never run"
    for ref, value in src_value.items():
        assert by_ref[ref].value == value


# ---------------------------------------------------------------------------
# COMPLETE placed-geometry parity + board-geometry carriage (review 621 MF6).
# ---------------------------------------------------------------------------


def test_complete_pad_projection_parity(corner_board, corner_board_result):
    """EVERY placed pad, matched by (ref, source_id), equals an INDEPENDENT
    projection of a freshly-parsed footprint through the placement transform —
    on the COMPLETE field set: position, rotation, size, shape, full drill
    (shape/x/y/plating), corner ratio, both margins, side, and expanded layers
    (review 623 R6).  Exact equality, no rounding.

    parity_corners.yaml's GAP 2 deliberately authors PIN OVERRIDES (inline
    pad_width_mm/pad_height_mm/drill_mm on J1 and SW9, migrated to typed
    overrides — see test_inline_pin_geometry_is_diagnosed) that diverge from
    the locked footprint, so the "fresh footprint" baseline for size/drill must
    fold those overrides too. The withdrawn smart_remote.yaml also authored
    inline geometry on every pin, but only annulus_diameter_mm diverged there,
    which never touches PlacedPad.size/.drill (compile_board.py:1020) — so the
    plain footprint-only comparison held by coincidence, not because overrides
    don't apply. The fold is done with `_apply_pin_override`, the SAME
    function the compiler itself uses and which is independently unit-tested
    below (test_override_*) — reusing it here does not retest override
    correctness, it only supplies the right expected value so THIS test can
    stay focused on what it actually proves: the PLACEMENT TRANSFORM (position/
    rotation/shape/margins/side/layers), independent of compile_board's own
    transform code.
    """
    from pcb_worker.compile_board import _apply_pin_override, _resolved_pad_layers
    from pcb_worker.footprint_def import FootprintDefinition
    from pcb_worker.footprints import resolve_footprint
    from pcb_worker.geometry import PlacementTransform

    src_by_ref = {c["ref"]: c for c in corner_board["components"]}
    diags = _Diagnostics()
    checked = 0
    for comp in corner_board_result.board.components:
        src = src_by_ref[comp.ref]
        fresh = FootprintDefinition.from_kicad_parsed(resolve_footprint(src["footprint"]))
        local_by_source = {p.source_id: p for p in fresh.pads}
        pin_overrides = _check_coincidence(src, fresh, comp.ref, _Diagnostics())
        transform = PlacementTransform(position=comp.placement.position,
                                       rotation_deg=comp.placement.rotation_deg,
                                       side=comp.placement.side)
        for placed in comp.placed_pads:
            local = local_by_source[placed.source_id]
            assert placed.position == transform.point(local.position)
            assert placed.rotation_deg == transform.angle(local.rotation_deg)
            override = pin_overrides.get(local.number, {})
            expected_size, expected_drill, _expected_ann, _expected_type = _apply_pin_override(
                local, override, local.size, local.drill, None, local.pad_type,
                comp.ref, diags)
            expected_size = (None if expected_size is None
                             else (float(expected_size[0]), float(expected_size[1])))
            assert placed.size == expected_size
            assert placed.shape == local.shape
            assert placed.drill == expected_drill          # shape + (x, y) + plating
            assert placed.corner_rratio == local.corner_rratio
            assert placed.solder_mask_margin == local.solder_mask_margin
            assert placed.solder_paste_margin == local.solder_paste_margin
            assert placed.side is comp.placement.side
            assert placed.layers == _resolved_pad_layers(local, transform, comp.ref, diags)
            checked += 1
    # Vacuity guard on the loop actually running, not just a count check — was
    # 76 against the withdrawn smart_remote.yaml (docket 019fbe68c5f8); the 4
    # components on parity_corners.yaml place 18 pads total (see
    # test_smart_remote_structure for how that number is derived).
    assert checked == 18
    assert not diags.has_error


def test_complete_graphic_projection_parity(corner_board, corner_board_result):
    """Every placed GRAPHIC, matched by (ref, source_id), equals an independent
    projection of a freshly-parsed footprint graphic through the placement
    transform — layer, primitive geometry, and width (review 625.5)."""
    from pcb_worker.compile_board import _to_geometry
    from pcb_worker.footprint_def import FootprintDefinition
    from pcb_worker.footprints import resolve_footprint
    from pcb_worker.geometry import PlacementTransform

    src_by_ref = {c["ref"]: c for c in corner_board["components"]}
    checked = 0
    for comp in corner_board_result.board.components:
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
    assert checked == sum(len(c.placed_graphics) for c in corner_board_result.board.components)
    # Was 207 against the withdrawn smart_remote.yaml (docket 019fbe68c5f8);
    # parity_corners.yaml's 4 components place 83 graphics total.
    assert checked == 83


def test_pad_position_cross_checks_the_live_path(corner_board, corner_board_result):
    """Independent cross-check: absolute pad centres also match the current
    resolve+place_point projection (a second algorithm).

    Scoped to TOP-side components. ``place_point``/``resolve_board`` (the
    legacy path exercised here) is a plain rotate+translate with no side
    mirroring — ``geometry.place_point`` docstring vs. ``PlacementTransform``,
    which explicitly mirrors the local Y axis for a bottom-side placement
    before rotating. Every component on the withdrawn smart_remote.yaml was
    `top` (see parity_corners.yaml's own header, GAP 1), so the two algorithms
    could never actually disagree there. parity_corners.yaml deliberately adds
    a BOTTOM-side component (U2, GAP 1) so the mirror fold is cross-surface
    checked elsewhere (test_rotation.py's k1_bottom_oracle, and the ir_parity
    gate) — asserting legacy/live agreement for U2 here would fail by
    correctly-mismatched DESIGN, not by defect, so it is excluded from this
    specific two-algorithm check rather than weakening it board-wide.
    """
    resolved = resolve_board(corner_board)
    ref = {}
    for comp in resolved["components"]:
        cx, cy, rot = comp["x_mm"], comp["y_mm"], comp.get("rotation_deg", 0.0)
        for pad in comp.get("pads", []):
            ax, ay = place_point(cx, cy, rot, pad["position"]["x"], pad["position"]["y"])
            ref[(comp["ref"], str(pad["number"]))] = (round(ax, 6), round(ay, 6))
    index = corner_board_result.board.footprint_index
    checked = 0
    for comp in corner_board_result.board.components:
        if comp.placement.side is not Side.TOP:
            continue
        by_source = {p.source_id: p for p in index[comp.footprint_id].pads}
        for placed in comp.placed_pads:
            number = by_source[placed.source_id].number
            assert (round(placed.position[0], 6), round(placed.position[1], 6)) == ref[(comp.ref, number)]
            checked += 1
    assert checked, "no top-side pads checked — the assertion above would never run"


def test_board_geometry_is_carried_faithfully(corner_board, corner_board_result):
    """Outline, traces, vias and holes are the authored geometry with COMPLETE
    properties — not dropped, not resampled, not partially compared."""
    board = corner_board_result.board
    assert board.outline.width_mm == corner_board["width_mm"]
    assert board.outline.height_mm == corner_board["height_mm"]

    net_name = {n.id: n.name for n in board.nets}

    # Traces: full ordered polyline + width + layer + NET membership for EVERY trace.
    assert len(board.traces) == len(corner_board["traces"])
    for src, got in zip(corner_board["traces"], board.traces):
        pts = [(float(p["x_mm"]), float(p["y_mm"])) for p in src["points"]]
        seg_points = [got.segments[0].a] + [s.b for s in got.segments]
        assert seg_points == pts
        assert all(s.width_mm == src["width_mm"] for s in got.segments)
        assert all(s.layer.id == src["layer"] for s in got.segments)
        assert net_name[got.net_id] == src["net"]

    # Vias: position, diameter, drill, span, and net membership.
    src_vias = {(float(v["x_mm"]), float(v["y_mm"])): v for v in corner_board["vias"]}
    assert len(board.vias) == len(src_vias)
    for via in board.vias:
        s = src_vias[(round(via.position[0], 6), round(via.position[1], 6))]
        assert via.diameter_mm == s["diameter_mm"]
        assert via.drill_mm == s["drill_mm"]
        assert {via.from_layer, via.to_layer} == {s["from_layer"], s["to_layer"]}
        assert net_name[via.net_id] == s["net"]

    # Holes: diameter, plating, and derived kind. parity_corners.yaml authors
    # holes under TWO aliased keys (GAP 3: a pth_holes entry plus a
    # mounting_holes entry) whose DEFAULT plating differs per key
    # (compile_board._build_holes: mounting_holes/npth_holes default False,
    # pth_holes defaults True and the key wins over any explicit `plated`) — so
    # the source-of-truth lookup below reproduces that per-key default instead
    # of assuming every hole authors an explicit `plated` field, which is all
    # the withdrawn smart_remote.yaml (mounting_holes only) needed.
    src_holes = {}
    for key, default_plated in (("mounting_holes", False), ("npth_holes", False),
                                 ("pth_holes", True)):
        for h in corner_board.get(key, []):
            plated = h.get("plated", default_plated) if key == "mounting_holes" else default_plated
            src_holes[(float(h["x_mm"]), float(h["y_mm"]))] = (h, plated)
    assert len(board.holes) == len(src_holes)
    for hole in board.holes:
        s, plated = src_holes[(round(hole.feature.position[0], 6), round(hole.feature.position[1], 6))]
        assert hole.feature.diameter_mm == s["diameter_mm"]
        assert hole.plated == plated
        assert hole.kind is (HoleKind.PTH if plated else HoleKind.NPTH)


def test_origin_is_preserved(corner_board):
    board = dict(corner_board)
    board["origin"] = {"x_mm": 7.0, "y_mm": 9.0}
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    assert result.board.outline.origin == (7.0, 9.0)


def test_placed_geometry_materialized_once_and_recomputes(corner_board_result):
    board = corner_board_result.board
    comp = board.components[0]
    definition = board.footprint_for(comp)
    transform = PlacementTransform(position=comp.placement.position,
                                   rotation_deg=comp.placement.rotation_deg,
                                   side=comp.placement.side)
    by_source = {pad.source_id: pad for pad in definition.pads}
    for placed in comp.placed_pads:
        assert placed.position == transform.point(by_source[placed.source_id].position)


def test_placed_pad_is_immutable(corner_board_result):
    pad = corner_board_result.board.components[0].placed_pads[0]
    with pytest.raises((AttributeError, TypeError)):
        pad.position = (0.0, 0.0)  # type: ignore[misc]


def test_compile_is_deterministic(corner_board):
    a, b = compile_board(corner_board), compile_board(corner_board)
    assert isinstance(a, ResolutionSuccess) and isinstance(b, ResolutionSuccess)
    assert [p.id for c in a.board.components for p in c.placed_pads] == \
           [p.id for c in b.board.components for p in c.placed_pads]
    assert [n.id for n in a.board.nets] == [n.id for n in b.board.nets]


# ---------------------------------------------------------------------------
# Pad-layer expansion (review 621 MF2): no wildcard survives.
# ---------------------------------------------------------------------------


def test_no_placed_pad_retains_a_wildcard_layer(corner_board_result):
    for comp in corner_board_result.board.components:
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


def test_v1_requested_outputs_do_not_claim_the_fab_layer():
    """Fatal-output profile + emitter layers come from the shared authority
    (review 623 R3/R5), and the aliasing is `is`-identity so the compiler cannot
    drift from the emitter's own accept-set.

    PASTE MOVED TWICE. First into K3_EMITTED_LAYERS (real stencil apertures
    from real pad geometry, c065c2b). Then ff0544f reversed the domain
    judgement too: the paste OUTPUT is now fail-closed (in V1_FAB_OUTPUTS) —
    a lost stencil layer refuses fabrication rather than warning.

    B.SILKS MOVED IN EPOCH CP2 (station S3), and the test name still says "do
    not claim back silk" only for F.Fab's half now. B.SilkS was excluded because
    we wrote the file but harvested no bottom silk, so claiming it would silence
    a real warning without emitting real geometry. S3 added the harvest, which
    inverts the argument exactly: the warning is now false and the claim is now
    true.

    F.Fab is still excluded, and permanently: KiCad's own .gbrjob calls it
    ``AssemblyDrawing,Top``. Not fab. The two exclusions were never the same
    kind of thing — one was a missing feature, the other is a classification.
    """
    from pcb_worker import fab_capability
    assert V1_FAB_OUTPUTS == fab_capability.FABRICATION_CRITICAL_OUTPUTS
    assert K3_EMITTED_LAYERS is fab_capability.EMITTED_LAYERS
    assert "paste" in V1_FAB_OUTPUTS  # fail-closed since ff0544f
    assert "fab" not in V1_FAB_OUTPUTS
    assert {"F.Paste", "B.Paste"} <= K3_EMITTED_LAYERS
    assert "F.Fab" not in K3_EMITTED_LAYERS
    assert "B.SilkS" in K3_EMITTED_LAYERS  # CP2 S3: real bottom-silk harvest


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
# Roundrect corner-ratio default resolution (019fa73a4f88) — resolved ONCE here,
# on the IR pad (_place_component), never re-substituted by either fab emitter.
# ---------------------------------------------------------------------------


def _place_one_pad(pad: PadDefinition):
    """Run a single synthetic pad through _place_component at identity placement
    and return its one PlacedPad — the direct unit seam for the corner_rratio
    resolution point, without needing a real board / footprint-lookup round trip."""
    definition = FootprintDefinition(name="fp", pads=(pad,), graphics=())
    comp = {"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0}
    diags = _Diagnostics()
    result = _place_component(comp, "X1-0", definition, Side.TOP, {}, {}, "X1", diags)
    assert result is not None, [d.message for d in diags.tuple()]
    placed_pads, _graphics = result
    assert len(placed_pads) == 1
    return placed_pads[0]


def test_roundrect_pad_with_no_authored_rratio_resolves_default_on_ir():
    # The resolution site itself: a roundrect pad that authors no corner_rratio
    # gets the KiCad-convention default baked onto the IR pad, ONCE, here — never
    # re-substituted downstream by either emitter (acceptance #2).
    placed = _place_one_pad(_synthetic_pad(shape=PadShape.ROUNDRECT, corner_rratio=None))
    assert placed.corner_rratio == DEFAULT_ROUNDRECT_RRATIO


def test_roundrect_pad_with_authored_zero_rratio_survives_unresolved():
    # THE NAMED TRAP: an authored 0.0 is NOT None, so the default fill-in must
    # NOT overwrite it. A zero radius is shape-changing (degenerates to a plain
    # Rectangle downstream) — silently promoting it to 0.25 would corrupt
    # fabricated copper, not just cosmetics (acceptance #3).
    placed = _place_one_pad(_synthetic_pad(shape=PadShape.ROUNDRECT, corner_rratio=0.0))
    assert placed.corner_rratio == 0.0


@pytest.mark.parametrize("shape", [PadShape.RECT, PadShape.CIRCLE, PadShape.OVAL])
def test_non_roundrect_pad_corner_rratio_stays_none(shape):
    # The default fill-in is gated on shape == roundrect: a rect/circle/oval pad
    # must still carry None, never a resolved 0.25 leaking into every pad on
    # every board (the reason a non-Optional field was rejected in the design;
    # acceptance #4).
    size = (1.0, 1.0) if shape is PadShape.CIRCLE else (2.0, 1.0)
    placed = _place_one_pad(_synthetic_pad(shape=shape, size=size, corner_rratio=None))
    assert placed.corner_rratio is None


# ---------------------------------------------------------------------------
# Provenance, digests, rule profile, stackup (review 621 MF4/MF5).
# ---------------------------------------------------------------------------


def test_component_provenance_populated_from_lock(corner_board_result):
    lock = load_lockfile()
    for comp in corner_board_result.board.components:
        assert comp.provenance.source_id
        assert comp.provenance.sha256 == lock[comp.provenance.source_id]["sha256"]


def test_board_provenance_full_digests_and_transform(corner_board_result):
    prov = corner_board_result.board.provenance
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


def test_authored_clearance_above_floor_is_honored(corner_board_result):
    # parity_corners.yaml (like the withdrawn smart_remote.yaml before it)
    # authors clearance_mm: 0.2 in its design_rules block, above the 0.127
    # floor — see the fixture's own design_rules section.
    assert corner_board_result.board.design_rules.minimums.min_clearance_mm == 0.2


# ---------------------------------------------------------------------------
# K21 (docket 019f762004dc) — the manufacturing floor is a LOADABLE, PINNED,
# FAIL-CLOSED profile selected by design_rules.rule_profile, not a hardcoded
# dict. See tests/test_manufacturer_profile.py for the loader's own
# fail-closed matrix and test_drc_geometric.py::test_two_profiles_same_board_different_verdicts
# for the K21 acceptance criterion (same board, different verdicts).
# ---------------------------------------------------------------------------


def test_a_board_that_names_no_profile_gets_v1_through_the_same_loader():
    # No design_rules.rule_profile key -- resolves to DEFAULT_RULE_PROFILE_ID
    # ("v1-fab-conservative") through manufacturer_profile.load_rule_profile,
    # the identical path any other id takes. Same assertion shape as
    # test_board_provenance_full_digests_and_transform's V1_RULE_PROFILE
    # check, restated at the design_rules level.
    result = compile_board(_one_component_board("R_0805"))
    assert isinstance(result, ResolutionSuccess)
    assert result.board.design_rules.rule_profile == V1_RULE_PROFILE
    assert result.board.provenance.rule_profile_ref == V1_RULE_PROFILE


def test_a_board_can_select_a_named_board_house_profile():
    board = _one_component_board("R_0805")
    board["design_rules"]["rule_profile"] = "oshpark-2layer"
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    rules = result.board.design_rules
    assert rules.rule_profile.id == "oshpark-2layer"
    assert rules.rule_profile != V1_RULE_PROFILE
    # The SELECTED profile's floor is what actually lands in .minimums, not
    # v1's -- OSH Park's published 6 mil (0.1524mm) trace width, distinct
    # from v1's 0.127mm.
    assert rules.minimums.min_trace_width_mm == pytest.approx(0.1524)
    # provenance.rule_profile_ref tracks the SAME non-default ref (the
    # ResolvedBoard consistency check at resolved_board.py:1098-1100 would
    # already refuse construction if these two disagreed).
    assert result.board.provenance.rule_profile_ref == rules.rule_profile


def test_an_unknown_rule_profile_fails_the_whole_compile_closed():
    board = _one_component_board("R_0805")
    board["design_rules"]["rule_profile"] = "definitely-not-a-real-board-house"
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unknown_rule_profile" in _errors(result)


def test_a_non_string_rule_profile_fails_closed():
    board = _one_component_board("R_0805")
    board["design_rules"]["rule_profile"] = 42
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_design_rule" in _errors(result)


def test_a_profile_missing_a_field_fails_the_whole_compile_closed_never_merged(tmp_path):
    # THE TRAP THIS UNIT NAMES EXPLICITLY (brief R2): a loader that filled a
    # missing field from v1 would produce a hybrid whose digest still claims
    # to be "acme-fab" while quietly enforcing v1's number on the field it
    # never authored. Prove the compile fails closed instead.
    #
    # THE OMITTED FIELD CHANGED IN CP2 S5. This used to omit
    # solder_mask_expansion_mm, which was demoted to the OPTIONAL tier in that
    # station (it was the last REQUIRED floor with no production reader, and its
    # meaning differs between the two shipped profiles, so it could not be given
    # one). Omitting it is now LEGAL — see the test directly below, which pins
    # exactly that. This unit needs a still-required field to make its point, so
    # it omits min_annular_ring_mm.
    incomplete_floor = {
        "min_trace_width_mm": 0.2, "min_clearance_mm": 0.2, "min_drill_mm": 0.3,
        "min_finished_hole_mm": 0.3,
        # min_annular_ring_mm deliberately OMITTED
        "min_hole_to_hole_mm": 0.3, "min_mask_sliver_mm": 0.15,
        "solder_mask_clearance_mm": 0.08,
        "solder_mask_expansion_mm": 0.0,
        "copper_to_edge_mm": 0.4,
    }
    (tmp_path / "acme-fab.json").write_text(
        json.dumps({"id": "acme-fab", "version": "1", "floor": incomplete_floor}),
        encoding="utf-8")
    board = _one_component_board("R_0805")
    board["design_rules"]["rule_profile"] = "acme-fab"
    result = compile_board(board, profile_root=tmp_path)
    assert isinstance(result, ResolutionFailure)
    assert "unknown_rule_profile" in _errors(result)
    message = next(d.message for d in result.diagnostics if d.code == "unknown_rule_profile")
    assert "min_annular_ring_mm" in message


def test_a_profile_omitting_the_demoted_mask_expansion_field_still_compiles(tmp_path):
    """The other half of the CP2 S5 demotion, and the half that would otherwise
    go unpinned.

    Moving a field between tiers has two consequences and a test suite that only
    checks one of them will happily pass while the demotion is half-applied:
    omitting the field must stop being fatal (here), and the required tier must
    still reject everything else (the test above). Without this, a later revert
    of the tier change would break nothing.

    The floor below is complete under the NEW required tier and declares no
    expansion at all, which is the state a profile is now allowed to be in:
    "this profile said nothing about mask expansion" rather than a substituted
    number.
    """
    floor = {
        "min_trace_width_mm": 0.2, "min_clearance_mm": 0.2, "min_drill_mm": 0.3,
        "min_finished_hole_mm": 0.3, "min_annular_ring_mm": 0.2,
        "min_hole_to_hole_mm": 0.3, "min_mask_sliver_mm": 0.15,
        "solder_mask_clearance_mm": 0.08, "copper_to_edge_mm": 0.4,
    }
    (tmp_path / "acme-fab.json").write_text(
        json.dumps({"id": "acme-fab", "version": "1", "floor": floor}),
        encoding="utf-8")
    board = _one_component_board("R_0805")
    board["design_rules"]["rule_profile"] = "acme-fab"
    result = compile_board(board, profile_root=tmp_path)
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    # ABSENT is recorded as None — "said nothing" — never as a substituted 0.0,
    # which is what the jlcpcb profile means when it declares 0.0 explicitly.
    assert result.board.design_rules.minimums.solder_mask_expansion_mm is None


def test_stackup_asserts_no_invented_thickness(corner_board_result):
    for entry in corner_board_result.board.layer_stack.stackup.entries:
        assert entry.thickness_mm is None
        assert entry.material is None


def test_ordinal_id_bridge_is_diagnosed(corner_board_result):
    assert any(d.code == "ordinal_ids" and d.severity is DiagnosticSeverity.INFO
               for d in corner_board_result.diagnostics)


# ---------------------------------------------------------------------------
# Adversarial regressions — every review-621 MF1 silent-loss repro now FAILS.
# ---------------------------------------------------------------------------


def test_malformed_origin_fails_closed(corner_board):
    board = dict(corner_board)
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
    # Zones are no longer an unsupported feature: the compiler VALIDATES them
    # (invalid_zone_outline vocabulary, mirroring Go's validateZones). A zone
    # with no outline still fails closed — under the validation contract.
    board = _one_component_board("R_0805")
    board["zones"] = [{"net": "GND", "layer": "top"}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_zone_outline" in _errors(result)


def test_unknown_component_side_fails_closed():
    result = compile_board(_one_component_board("R_0805", layer="nonsense"))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_non_list_traces_fails_closed():
    board = _one_component_board("R_0805")
    board["traces"] = {"net": "N1"}
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    # A present non-list collection is a shared-boundary violation the compiler now
    # rejects up front via validate_board_v2 (findings 019f88bac172 / 019f8b7fb07e)
    # with the SAME code the Go codec + vectors use, instead of the compiler-local
    # invalid_trace it emitted after reaching its own trace parser.
    assert "invalid_board_structure" in _errors(result)


def test_invalid_rotation_fails_closed():
    result = compile_board(_one_component_board("R_0805", rotation_deg="bad"))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component" in _errors(result)


def test_empty_zones_mapping_fails_closed():
    board = _one_component_board("R_0805")
    board["zones"] = {}  # malformed empty mapping — a declaration, not absence
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    # A present non-list collection is rejected up front by validate_board_v2,
    # same shared-boundary contract as test_non_list_traces above.
    assert "invalid_board_structure" in _errors(result)


def test_empty_zones_list_is_allowed():
    board = _one_component_board("R_0805")
    board["zones"] = []  # explicitly nothing declared
    assert isinstance(compile_board(board), ResolutionSuccess)


# --- cutouts: compilable since epoch CPN1 ------------------------------------
# The campaign-2 refusal ("authorable, NOT compilable") existed to hold back
# fail-open 019fbd30f7 — outline_frame silently degrading a ProfileOutline to
# its bbox, so a compiled cutout would have shipped a SOLID board. Epoch CPN1
# (docket 019fe2faf76e) fixed that by the bug's own oracle and relaxed the
# denylist; this row is the old tripwire saying so out loud, now pinning the
# NEW contract (the full geometry rules live in tests/test_cutouts.py).


def test_declared_cutouts_compile_to_profile_outline():
    board = _one_component_board("R_0805")
    board["cutouts"] = [{"outline": [{"x_mm": 4, "y_mm": 4}, {"x_mm": 8, "y_mm": 4},
                                     {"x_mm": 8, "y_mm": 8}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    from pcb_worker.resolved_board import ProfileOutline
    assert isinstance(result.board.outline, ProfileOutline)
    assert len(result.board.outline.cutouts) == 1


def test_empty_cutouts_mapping_fails_closed():
    board = _one_component_board("R_0805")
    board["cutouts"] = {}  # malformed empty mapping — a declaration, not absence
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    # Fails closed at the SHARED BOUNDARY, one step earlier than the denylist:
    # `cutouts` is an entity-list key on both sides (entityListKeys in yaml.go,
    # the tuple in board_validate.py), so a non-list container is
    # invalid_board_structure and compile_board returns before the denylist runs.
    # Either code is a refusal; asserting the one the system actually emits is
    # what keeps this test honest about WHERE the gate is.
    assert "invalid_board_structure" in _errors(result)


def test_empty_cutouts_list_is_allowed():
    board = _one_component_board("R_0805")
    board["cutouts"] = []  # explicitly nothing declared
    assert isinstance(compile_board(board), ResolutionSuccess)


def test_string_plated_fails_closed():
    board = _minimal_board(mounting_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2,
                                            "plated": "false"}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "hole_bad_plating" in _errors(result)


def test_string_plated_on_alias_hole_fails_closed():
    # F1 (finding 019f8b7fb07e): a malformed (non-bool) plated on a pth_holes /
    # npth_holes ALIAS must fail closed too. Go's typed bool rejects it and the
    # mounting_holes branch rejects it, so silently ignoring it on the aliases was a
    # Go/Python codec divergence. The alias KEY still wins on the VALUE; only a wrong
    # TYPE is the error.
    for key in ("pth_holes", "npth_holes"):
        board = _minimal_board(**{key: [{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2,
                                         "plated": "false"}]})
        result = compile_board(board)
        assert isinstance(result, ResolutionFailure), key
        assert "hole_bad_plating" in _errors(result), key


# --- C4 (finding 019f8dbb7104): a plated board hole's copper annulus is AUTHORED,
# never invented, so both emitters emit the SAME copper. ---


def test_plated_hole_without_annulus_fails_closed():
    # No invented copper on a fabrication-critical plated hole.
    board = _minimal_board(pth_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 2.0}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "plated_hole_needs_annulus" in _errors(result)


def test_plated_hole_annulus_must_exceed_drill():
    board = _minimal_board(pth_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 2.0,
                                       "annulus_mm": 2.0}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "hole_annulus_not_bigger_than_drill" in _errors(result)


def test_unplated_hole_with_annulus_fails_closed():
    board = _minimal_board(mounting_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2,
                                            "annulus_mm": 4.0}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unplated_hole_has_annulus" in _errors(result)


def test_plated_hole_with_annulus_compiles_and_carries_it():
    board = _minimal_board(pth_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 2.0,
                                       "annulus_mm": 3.5}])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    (hole,) = result.board.holes
    assert hole.plated and hole.annulus_mm == 3.5


def test_override_annulus_on_unplated_pad_fails_closed():
    # E2 (finding 019f8fe77068): an override that AUTHORS an annulus AND plates the
    # pad OFF is contradictory — an unplated hole carries no copper ring, so the
    # annulus would be silently discarded. Validate the FOLDED state, fail closed.
    board = _one_component_board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"annulus_diameter_mm": 3.0, "plated": False}}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "override_copper_dims_on_unplated_pad" in _errors(result)


def test_override_pad_land_dims_on_unplated_pad_fails_closed():
    # F2 (finding 019f8fe77068 reopened): the invariant is FINAL-STATE, not
    # annulus-specific. Authoring a pad LAND size (pad_width_mm / pad_height_mm) while
    # plating the pad OFF is the same contradiction — an np_thru_hole carries no
    # copper land, so both emitters would silently discard the authored dimensions.
    board = _one_component_board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"pad_width_mm": 2.0, "pad_height_mm": 1.5,
                                           "plated": False}}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    errs = _errors(result)
    assert "override_copper_dims_on_unplated_pad" in errs
    # the message names ALL discarded copper dims, not just one
    msg = next(d.message for d in result.diagnostics
               if d.code == "override_copper_dims_on_unplated_pad")
    assert "pad_width_mm" in msg and "pad_height_mm" in msg


def test_override_plated_off_without_copper_dims_is_ok():
    # The complement: overriding ONLY plated:false (no authored annulus/land) is a
    # legitimate "make this a mechanical hole" — the footprint copper drops naturally,
    # no contradiction.
    board = _one_component_board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"plated": False}}])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    assert "override_copper_dims_on_unplated_pad" not in _errors(result)


def test_via_bad_tented_fails_closed():
    # D4 (finding 019f8fe7cbaf): a non-bool `tented` on a via fails closed (mirrors
    # hole_bad_plating). A string "false" must NOT coerce.
    board = _minimal_board(
        nets=[{"name": "N", "pins": []}],
        vias=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 0.8, "drill_mm": 0.4,
               "net": "N", "from_layer": "top", "to_layer": "bottom",
               "tented": "false"}])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "via_bad_tented" in _errors(result)


def test_via_tenting_defaults_tented_and_authors_untented():
    def _one_via(**extra):
        v = {"x_mm": 5, "y_mm": 5, "diameter_mm": 0.8, "drill_mm": 0.4,
             "net": "N", "from_layer": "top", "to_layer": "bottom", **extra}
        board = _one_component_board("R_0805")
        board["nets"] = [{"name": "N", "pins": ["X1.1"]}]
        board["vias"] = [v]
        return board

    (default_via,) = compile_board(_one_via()).board.vias
    assert default_via.tented_front and default_via.tented_back        # default TENTED
    (untented,) = compile_board(_one_via(tented=False)).board.vias
    assert not untented.tented_front and not untented.tented_back      # authored untented


def test_null_tented_and_plated_are_unset_default_matching_go():
    # G1 (finding 019f9123abef): an explicit `tented: null` / `plated: null` is UNSET
    # -> the DEFAULT, NOT a fail-closed error. This matches Go (Via.Tented *bool
    # decodes null to nil=unset; Hole.Plated bool decodes null to false) and the
    # shared validator (validate_board_v2 accepts both — vectors 250/260/270), so the
    # Go codec and the Python CAM compiler no longer disagree on null. A non-null
    # non-bool still fails closed (test_via_bad_tented / test_string_plated).
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N", "pins": ["X1.1"]}]
    board["vias"] = [{"x_mm": 5, "y_mm": 5, "diameter_mm": 0.8, "drill_mm": 0.4,
                      "net": "N", "from_layer": "top", "to_layer": "bottom",
                      "tented": None}]
    board["mounting_holes"] = [{"x_mm": 2, "y_mm": 2, "diameter_mm": 3.2, "plated": None}]
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    (via,) = result.board.vias
    assert via.tented_front and via.tented_back        # null -> default TENTED
    (hole,) = result.board.holes
    assert hole.plated is False                        # null -> default UNPLATED


def test_null_override_plated_is_unset_not_rejected():
    # G1 complement (vector 270): an override `plated: null` is UNSET (keep the
    # footprint's plating), matching Go's probeOverride `!!null` allowance — not the
    # invalid_pin_override a non-bool like "maybe" earns (vector 230).
    board = _one_component_board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"plated": None}}])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)


def test_pth_alias_key_overrides_explicit_plated_false():
    # D2 (Fable): the pth_holes alias KEY is authoritative for plating — a
    # contradictory explicit plated:false is overridden (folded PLATED, matching Go's
    # NormalizeHoles) and WARNED (never silent), so no path diverges on the flag.
    board = _minimal_board(pth_holes=[{"x_mm": 5, "y_mm": 5, "diameter_mm": 2.0,
                                       "annulus_mm": 3.5, "plated": False}])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    (hole,) = result.board.holes
    assert hole.plated is True
    assert "alias_plating_overridden" in [d.code for d in result.diagnostics]


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


def test_v2_board_with_only_board_id_compiles():
    # A childless v2 board needs just the persisted board id — no trace/via/hole
    # id requirement to trip, and no ordinal bridge.
    board = _one_component_board("R_0805")
    board["version"] = 2
    board["id"] = _mid("board", 1)
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    codes = [d.code for d in result.diagnostics]
    assert "unminted_persistent_id" not in codes
    assert "ordinal_ids" not in codes
    assert result.board.id == _mid("board", 1)


def test_v2_board_missing_board_id_fails_closed():
    board = _v2_full_board()
    del board["id"]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "unminted_persistent_id" in _errors(result)


def test_duplicate_trace_id_fails_closed_with_explicit_code():
    # Finding 019f88bac172: a duplicate persistent id must fail closed with the
    # EXPLICIT shared-boundary code the Go codec + vectors use, up front — NOT via
    # the late generic board_invariant ResolvedBoard construction used to raise.
    board = _v2_full_board()
    board["traces"] = board["traces"] + [
        {"id": _mid("trace", 1), "net": "N1", "layer": "top", "width_mm": 0.3,
         "points": [{"x_mm": 4, "y_mm": 4}, {"x_mm": 6, "y_mm": 6}]}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    errs = _errors(result)
    assert "duplicate_persistent_id" in errs
    assert "board_invariant" not in errs  # caught early, not by the late invariant


def test_null_component_fails_closed():
    # Finding 019f8b7fb07e: a null / identity-less component is a structural
    # violation the production compiler now rejects via the shared validator.
    board = _one_component_board("R_0805")
    board["components"] = [None]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_board_structure" in _errors(result)


@pytest.mark.parametrize("bad_id", [None, "", "trace_1", "trace:XYZ", "TRACE:" + "0" * 32,
                                    "trace:" + "0" * 31, "trace:" + "0" * 33, "via:" + "0" * 32])
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


def test_inline_pin_geometry_is_diagnosed(corner_board_result):
    # parity_corners.yaml authors legacy inline pin geometry (drill_mm /
    # pad_width_mm / pad_height_mm / annulus_diameter_mm) on every pin (see its
    # header), and on J1 and SW9 those authored values DIVERGE from the locked
    # footprint (e.g. J1 pin 1: drill 0.8 vs footprint 1.0) but are verifiable
    # → the fold auto-migrates them to typed overrides (INFO), never the
    # retired ignore-warning. Was "every pin" on the withdrawn smart_remote.yaml;
    # here it is J1 and SW9's pins specifically (U2/U3's inline geometry
    # matches their footprint and is folded away silently instead — see
    # test_inline_geometry_matching_footprint_is_dropped_silently for that
    # branch), which is enough to prove the migration path fires at all.
    codes = [d.code for d in corner_board_result.diagnostics]
    assert any(d.code == "inline_pin_geometry_migrated"
               and d.severity is DiagnosticSeverity.INFO
               for d in corner_board_result.diagnostics)
    assert "inline_pin_geometry_ignored" not in codes


# ---------------------------------------------------------------------------
# Pin-geometry authority fold (migration 019f802ca3af — Round C2). Footprint
# authoritative; typed `override` is the sanctioned v2 deviation channel; legacy
# inline geometry is folded per-compile (match → dropped, diverge → warn).
# ---------------------------------------------------------------------------


def _thru_pad(*, drill_mm=0.8, diameter_mm=1.2):
    return _synthetic_pad(
        pad_type="thru_hole", size=(diameter_mm, diameter_mm),
        drill=DrillDefinition(shape="round", size=(drill_mm, drill_mm)),
        layers=(Layer.from_id("F.Cu"), Layer.from_id("B.Cu")),
    )


def _fp(*pads):
    """A minimal footprint stand-in — _check_coincidence reads only `.pads`."""
    return SimpleNamespace(pads=pads)


def _codes(diags):
    return [d.code for d in diags.tuple()]


def test_inline_geometry_matching_footprint_is_dropped_silently():
    # Inline drill+annulus equal to the footprint pad → redundant, folded away
    # silently: no migrate INFO, no error, and no synthesized override returned.
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 1.2}]}
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert "inline_pin_geometry_ignored" not in _codes(diags)
    assert "inline_pin_geometry_migrated" not in _codes(diags)
    assert validated == {}
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags.tuple())


def test_inline_geometry_diverging_footprint_is_migrated_to_override():
    # Annulus diverges from the footprint but is verifiable → the fold synthesizes
    # a typed override capturing the authored inline geometry, returns it for the
    # IR to APPLY, and records an INFO (never the retired ignore-warning).
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0}]}
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert validated == {"1": {"drill_mm": 0.8, "annulus_diameter_mm": 2.0}}
    infos = [d for d in diags.tuple() if d.code == "inline_pin_geometry_migrated"]
    assert len(infos) == 1 and infos[0].severity is DiagnosticSeverity.INFO
    assert "override" in infos[0].message and "annulus 2.0" in infos[0].message
    assert "inline_pin_geometry_ignored" not in _codes(diags)
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags.tuple())


def test_inline_geometry_without_matching_pad_fails_closed():
    # Inline geometry present but no footprint pad to correlate it against →
    # ambiguous, cannot migrate → fail-closed ERROR (no silent drop, no warning).
    diags = _Diagnostics()
    comp = {"pins": [{"number": "9", "drill_mm": 0.8}]}  # footprint only has pad "1"
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert validated == {}
    errors = [d for d in diags.tuple() if d.severity is DiagnosticSeverity.ERROR]
    assert "inline_geometry_without_pad" in [d.code for d in errors]
    assert "inline_pin_geometry_ignored" not in _codes(diags)


def test_typed_override_is_honored_not_deprecated():
    # A typed override is the sanctioned deviation channel: no deprecation warning,
    # no error, and it is returned for the IR builder to apply (no stale
    # override_not_yet_applied INFO — the override IS applied now, 019f88a0c84f).
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "override": {"annulus_diameter_mm": 2.0}}]}
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert "inline_pin_geometry_ignored" not in _codes(diags)
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags.tuple())
    assert "override_not_yet_applied" not in _codes(diags)
    assert validated == {"1": {"annulus_diameter_mm": 2.0}}


def test_override_extra_keys_are_tolerated():
    # Unknown override keys round-trip via Go's inline Extra; the Python validator
    # must not reject them (parity), and the override is still returned/honored.
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "override": {"drill_mm": 0.9, "foo": 123}}]}
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert "invalid_pin_override" not in _codes(diags)
    assert validated == {"1": {"drill_mm": 0.9, "foo": 123}}


def test_unverifiable_inline_geometry_fails_closed():
    # A garbage inline value (wrong type) with a matching pad is present but
    # un-comparable — the fold cannot form a trustworthy override, so it fail-closes
    # with an ERROR rather than migrate or silently drop it.
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "drill_mm": "big"}]}
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert validated == {}
    errors = [d for d in diags.tuple() if d.severity is DiagnosticSeverity.ERROR]
    assert "inline_geometry_unverifiable" in [d.code for d in errors]
    assert "inline_pin_geometry_ignored" not in _codes(diags)


def test_inline_size_on_sizeless_pad_is_flagged_not_silently_redundant():
    # Fable SB3 note 1: inline size/annulus on a footprint pad with NO size must
    # register as a divergence (so the fold migrates or fail-closes it) rather than
    # classify as redundant and silently drop the authored geometry — mirroring the
    # drill-vs-no-drill case.
    from pcb_worker.compile_board import _inline_geometry_conflicts
    sizeless = _synthetic_pad(pad_type="np_thru_hole", size=None,
                              drill=DrillDefinition(shape="round", size=(0.8, 0.8)))
    assert _inline_geometry_conflicts({"pad_width_mm": 1.5}, sizeless, "1")
    assert _inline_geometry_conflicts({"annulus_diameter_mm": 2.0}, sizeless, "1")
    # A pin whose only inline value matches the footprint drill stays conflict-free.
    assert not _inline_geometry_conflicts({"drill_mm": 0.8}, sizeless, "1")


def test_inline_plated_divergence_is_migrated():
    # plated diverges from the footprint drill (pad drill is plated) → migrated to a
    # synthesized override that carries the authored plating flag.
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "plated": False}]}
    validated = _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert validated == {"1": {"plated": False}}
    infos = [d for d in diags.tuple() if d.code == "inline_pin_geometry_migrated"]
    assert len(infos) == 1 and "plated" in infos[0].message
    assert "inline_pin_geometry_ignored" not in _codes(diags)


def test_typed_override_supersedes_inline_geometry():
    # Override present alongside legacy inline that diverges from the footprint →
    # inline is folded away silently (the override is the intended value).
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "drill_mm": 0.8, "annulus_diameter_mm": 2.0,
                      "override": {"annulus_diameter_mm": 2.0}}]}
    _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert "inline_pin_geometry_ignored" not in _codes(diags)
    assert not any(d.severity is DiagnosticSeverity.ERROR for d in diags.tuple())


@pytest.mark.parametrize("override", [
    5,                                              # not a mapping
    "drill",                                        # not a mapping
    {"drill_mm": "big"},                            # numeric key, wrong type
    {"annulus_diameter_mm": True},                  # bool is not a number
    {"pad_width_mm": None, "pad_height_mm": "x"},   # one bad numeric key
    {"plated": "yes"},                              # plated must be a boolean
])
def test_malformed_override_fails_closed(override):
    diags = _Diagnostics()
    comp = {"pins": [{"number": "1", "override": override}]}
    _check_coincidence(comp, _fp(_thru_pad()), "X1", diags)
    assert "invalid_pin_override" in [d.code for d in diags.tuple()
                                      if d.severity is DiagnosticSeverity.ERROR]


def test_valid_override_types_pass_validation():
    diags = _Diagnostics()
    _validate_pin_override(
        {"drill_mm": 0.9, "annulus_diameter_mm": 1.5, "pad_width_mm": 1.0,
         "pad_height_mm": 1.0, "plated": True}, "X1", "1", diags)
    assert _codes(diags) == []


def test_override_compiles_on_real_board():
    # Functional floor: a typed override on a real resolvable component compiles
    # (footprint stays authoritative for emission) with no override/inline diags.
    board = _one_component_board("R_0805")
    board["components"][0]["pins"] = [{"number": "1", "override": {"pad_width_mm": 1.4}}]
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    assert "invalid_pin_override" not in _errors(result)
    assert "inline_pin_geometry_ignored" not in [d.code for d in result.diagnostics]


def test_malformed_override_fails_closed_on_real_board():
    # Functional floor: a malformed override hard-fails the real compile.
    board = _one_component_board("R_0805")
    board["components"][0]["pins"] = [{"number": "1", "override": {"drill_mm": "wide"}}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_pin_override" in _errors(result)


# ---------------------------------------------------------------------------
# Typed override APPLIED in the ResolvedBoard IR (019f88a0c84f). Emission-parity:
# an override changes EXACTLY the intended PlacedPad field(s), nothing else; a
# sibling pad with no override is byte-identical to the un-overridden compile.
# ---------------------------------------------------------------------------

_TH_FP = "Package_DIP:DIP-6_W7.62mm_Socket"  # a through-hole (drilled) seed


def _placed_by_number(result) -> dict:
    """Map pin number → PlacedPad for the single component, via the footprint
    definition's source_id↔number correlation (PlacedPad carries source_id)."""
    comp = result.board.components[0]
    fp = result.board.footprint_definitions[0]
    num_by_source = {p.source_id: p.number for p in fp.pads}
    return {num_by_source[p.source_id]: p for p in comp.placed_pads}


def _th_board(override=None) -> dict:
    board = _one_component_board(_TH_FP)
    if override is not None:
        board["components"][0]["pins"] = [{"number": "1", "override": override}]
    return board


def test_override_drill_mm_changes_only_drill():
    base = _placed_by_number(compile_board(_th_board()))
    over = _placed_by_number(compile_board(_th_board({"drill_mm": 1.5})))
    assert over["1"].drill.size == (1.5, 1.5)
    assert over["1"].size == base["1"].size          # size untouched
    assert over["1"].annulus == base["1"].annulus    # annulus untouched
    assert over["1"].pad_type == base["1"].pad_type  # pad_type untouched
    assert over["2"] == base["2"]                     # sibling byte-identical


def test_override_pad_width_only_keeps_footprint_height():
    base = _placed_by_number(compile_board(_th_board()))
    over = _placed_by_number(compile_board(_th_board({"pad_width_mm": 3.3})))
    assert over["1"].size[0] == 3.3
    assert over["1"].size[1] == base["1"].size[1]     # height kept from footprint
    assert over["1"].drill == base["1"].drill
    assert over["2"] == base["2"]


def test_override_annulus_sets_annulus_only():
    base = _placed_by_number(compile_board(_th_board()))
    over = _placed_by_number(compile_board(_th_board({"annulus_diameter_mm": 2.5})))
    assert base["1"].annulus is None
    assert over["1"].annulus == 2.5
    assert over["1"].size == base["1"].size
    assert over["1"].drill == base["1"].drill
    assert over["2"] == base["2"]


def test_override_plated_false_makes_np_thru_hole_true_keeps_thru_hole():
    base = _placed_by_number(compile_board(_th_board()))
    assert base["1"].pad_type == "thru_hole" and base["1"].drill.plated is True
    npth = _placed_by_number(compile_board(_th_board({"plated": False})))
    assert npth["1"].pad_type == "np_thru_hole" and npth["1"].drill.plated is False
    assert npth["1"].size == base["1"].size and npth["1"].drill.size == base["1"].drill.size
    plated = _placed_by_number(compile_board(_th_board({"plated": True})))
    assert plated["1"].pad_type == "thru_hole" and plated["1"].drill.plated is True


def test_full_override_sets_all_fields():
    # An annulus is copper, so it may only co-exist with a PLATED pad (E2 rejects
    # annulus + plated:false as contradictory); this exercises all override fields on
    # a valid plated pad. (plated:false without an annulus is covered separately.)
    over = _placed_by_number(compile_board(_th_board(
        {"drill_mm": 1.1, "pad_width_mm": 3.0, "pad_height_mm": 3.2,
         "annulus_diameter_mm": 2.0, "plated": True})))
    p = over["1"]
    assert p.drill.size == (1.1, 1.1)
    assert p.size == (3.0, 3.2)
    assert p.annulus == 2.0
    assert p.pad_type == "thru_hole" and p.drill.plated is True


def test_override_nonpositive_numeric_fails_closed_not_applied():
    result = compile_board(_th_board({"drill_mm": -1}))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_pin_override" in _errors(result)


def test_override_drill_on_smd_pad_rejected():
    # drill_mm on a drill-less SMD pad is a fail-closed rejection, not a silent
    # SMD→through-hole conversion.
    board = _one_component_board("R_0805")
    board["components"][0]["pins"] = [{"number": "1", "override": {"drill_mm": 0.9}}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "override_drill_on_drilless_pad" in _errors(result)


def test_override_plated_on_smd_pad_is_noop():
    base = _placed_by_number(compile_board(_one_component_board("R_0805")))
    board = _one_component_board("R_0805")
    board["components"][0]["pins"] = [{"number": "1", "override": {"plated": True}}]
    over = _placed_by_number(compile_board(board))
    assert over["1"].pad_type == base["1"].pad_type == "smd"
    assert over["1"].drill == base["1"].drill  # still None


def test_override_not_yet_applied_diagnostic_is_retired():
    result = compile_board(_th_board({"annulus_diameter_mm": 2.0}))
    assert isinstance(result, ResolutionSuccess)
    assert "override_not_yet_applied" not in [d.code for d in result.diagnostics]


def test_override_on_nonexistent_pin_number_fails_closed():
    # A validated override whose pin number matches NO footprint pad would apply
    # to nothing — it must not vanish silently (Fable SB1 note 1): fail closed
    # with override_without_pad rather than lose a sanctioned fab deviation.
    board = _th_board()
    board["components"][0]["pins"] = [
        {"number": "99", "override": {"annulus_diameter_mm": 2.0}}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "override_without_pad" in _errors(result)


def test_override_drill_mm_on_slot_drill_warns_and_squares():
    # A scalar drill_mm override collapsing a non-round (slot) footprint drill to a
    # round hole is a fab change — warned, never silent (Fable SB1 note 2).
    from pcb_worker.compile_board import _apply_pin_override
    diags = _Diagnostics()
    slot = DrillDefinition(shape="oval", size=(1.0, 2.0))
    _size, drill, _ann, _pt = _apply_pin_override(
        _thru_pad(), {"drill_mm": 1.5}, (1.2, 1.2), slot, None, "thru_hole", "X1", diags)
    assert "override_drill_squared_slot" in _codes(diags)
    assert drill.size == (1.5, 1.5)


def test_divergent_inline_geometry_migrated_and_applied_on_real_board():
    # Real-compile emission parity: a component pin whose inline annulus DIVERGES
    # from the footprint compiles to success, the PlacedPad reflects the AUTHORED
    # inline value (proving synthesize→apply preserves the deviation through the
    # IR), and the compile records the migrate INFO — never the retired warning.
    board = _one_component_board(_TH_FP)
    board["components"][0]["pins"] = [{"number": "1", "annulus_diameter_mm": 2.5}]
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess)
    placed = _placed_by_number(result)
    base = _placed_by_number(compile_board(_th_board()))
    assert base["1"].annulus is None          # footprint declares no annulus
    assert placed["1"].annulus == 2.5         # authored inline value applied
    assert placed["2"] == base["2"]           # untouched sibling byte-identical
    codes = [d.code for d in result.diagnostics]
    assert "inline_pin_geometry_migrated" in codes
    assert "inline_pin_geometry_ignored" not in codes


def test_divergent_inline_forming_invalid_override_fails_closed():
    # A divergent inline value that would synthesize an ILLEGAL override still
    # fail-closes through the SB1 apply guards (drill_mm on a drill-less SMD pad) —
    # no silent apply, no ResolutionSuccess.
    board = _one_component_board("R_0805")  # SMD, drill-less pads
    board["components"][0]["pins"] = [{"number": "1", "drill_mm": 0.9}]
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "override_drill_on_drilless_pad" in _errors(result)


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


# ---------------------------------------------------------------------------
# PLATED thru-hole must declare copper (docket 019f91a6cff1) — the symmetric
# partner of the SMD guard above. An EARLIER, better-named gate, not a
# correctness fix: pad_source.require_th_annulus already fail-closes downstream
# on the resulting size/annulus of None, so nothing was ever invented.
#
# THE ASYMMETRY WITH np_thru_hole IS THE POINT. Both cases are asserted, because
# guarding np_thru_hole too would reject every mounting hole on every board.
# ---------------------------------------------------------------------------


def test_pad_guard_rejects_plated_through_hole_without_copper():
    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="thru_hole", size=None, layers=(),
                         drill=DrillDefinition(shape="round", size=(0.8, 0.8)))
    assert not _check_pad_capabilities(pad, "X1", diags)
    codes = [d.code for d in diags.tuple()]
    assert "illegal_pad_definition" in codes
    assert any("no copper layer" in d.message for d in diags.tuple()), \
        [d.message for d in diags.tuple()]
    # And it is caught HERE — not left to missing_pad_size, which never fires for
    # a pad with no copper (that guard is gated on has_copper).
    assert "missing_pad_size" not in codes


def test_pad_guard_accepts_non_plated_through_hole_without_copper():
    """A mounting hole is a mechanical feature with legitimately no copper."""
    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="np_thru_hole", size=None, layers=(),
                         drill=DrillDefinition(shape="round", size=(3.2, 3.2)))
    assert _check_pad_capabilities(pad, "X1", diags)
    assert [d.code for d in diags.tuple()] == []


def test_no_seed_library_pad_trips_the_plated_through_hole_copper_guard():
    """Regression guard for the guard: every pad of every footprint in the seed
    library must still pass capability.

    MEASURED, not assumed: all 76 seed pads were enumerated before the guard was
    written and every `thru_hole` among them declares `*.Cu`, so the guard adds
    no rejection. Inverting its condition (`has_copper` instead of
    `not has_copper`) fails this test plus 7 `test_compile_census_every_seed_
    resolves` parametrizations — 44 failures in this module in total.

    WHAT THIS TEST DOES NOT CATCH, stated because it would be easy to assume
    otherwise: widening the guard to np_thru_hole does NOT fail here. The seed
    library's only NPTH pad (MountingHole_3.2mm_M3) declares `*.Cu` anyway, so
    it has copper and the widened guard would not fire on it. The np_thru_hole
    exemption is pinned by test_pad_guard_accepts_non_plated_through_hole_
    without_copper and by the pre-existing
    test_pad_guard_allows_sizeless_non_copper_hole instead — a synthetic NPTH
    pad with genuinely no layers, which is the case a real hand-authored
    mounting hole hits."""
    # The library root the worker itself resolves against — not a hand-rolled
    # path that could drift away from the one production reads.
    from pcb_worker.footprints import DEFAULT_LIBRARY_ROOT, parse_kicad_mod

    modules = sorted(DEFAULT_LIBRARY_ROOT.rglob("*.kicad_mod"))
    assert len(modules) >= 10, modules  # the library really was found

    by_type: dict[str, int] = {}
    padless = 0
    for path in modules:
        definition = FootprintDefinition.from_kicad_parsed(parse_kicad_mod(path))
        if not definition.pads:
            # A PAD-LESS footprint is legitimate since epoch CPN1: the seed
            # library now ships silk-only furniture (Minerva_Fixture's logo),
            # which is a footprint with graphics and no copper at all. It has
            # no pads to put through the capability guard, so it contributes
            # none — counted rather than skipped silently, and the floor below
            # keeps this from degenerating into "checked nothing".
            padless += 1
            assert definition.graphics, (
                f"{path}: a footprint with neither pads nor graphics is not a "
                f"footprint — it is an empty file")
            continue
        for pad in definition.pads:
            diags = _Diagnostics()
            assert _check_pad_capabilities(pad, path.stem, diags), \
                f"{path.name} pad {pad.number}: {[d.message for d in diags.tuple()]}"
            by_type[pad.pad_type] = by_type.get(pad.pad_type, 0) + 1

    # The library must actually EXERCISE both sides of the asymmetry, or this
    # test would pass on a library that contains neither kind of hole.
    assert by_type.get("thru_hole", 0) >= 1, by_type
    assert by_type.get("np_thru_hole", 0) >= 1, by_type
    assert sum(by_type.values()) >= 70, by_type  # 76 pads at the time of writing
    # The pad-less set is small and deliberate; if it ever grows to swallow the
    # library this test would be checking almost nothing.
    assert padless <= 3, f"{padless} pad-less footprints — is the library right?"


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
    # Canonical layer vocabulary is top/bottom only, so a non-two-layer stack
    # can be refused at either of two gates. Pin BOTH: a stack of valid names
    # with the wrong count hits unsupported_layer_stack; a stack naming a
    # non-canonical layer hits invalid_layer_name before the count check.
    # Every non-two-layer shape now has its own granular refusal code from
    # up-front validation, which shadows _require_two_layer's blanket
    # unsupported_layer_stack (still present as defence in depth, but not
    # reachable through compile_board's validated path). Pin the granular trio.
    result = compile_board(_minimal_board(layers=["bottom", "top"]))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_layer_stack_order" in _errors(result)

    result = compile_board(_minimal_board(layers=["top"]))
    assert isinstance(result, ResolutionFailure)
    assert "incomplete_layer_stack" in _errors(result)

    result = compile_board(_minimal_board(layers=["top", "inner1", "bottom"]))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_layer_name" in _errors(result)


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


# --- Authored net classes (design_rules.net_classes) -----------------------
#
# A class both STATES its rules and NAMES its member nets, all inside
# `design_rules`. Only the two minima both consumers read
# (`methods._net_class_overrides`, `drc_geometric._net_class_minima`) are
# authorable; everything else about a class is derived or refused. The
# membership INVERSION into `ResolvedNet.net_class_id` is what makes a class
# reach a consumer at all, and is covered end-to-end in
# `tests/test_route_rules.py` (routed width) and `tests/test_drc_geometric.py`
# (GC1 finding).


def _classed_board(entry, *, nets=None) -> dict:
    """`_one_component_board` carrying ONE authored net class.

    X1 is an R_0805, so `X1.1`/`X1.2` are real pads and TWO real nets are
    available. The default net list carries BOTH — `N1`, which the tests below
    make a class member, and `N2`, which joins nothing. A single-net fixture
    would let a compiler that assigns every net the first class id pass every
    assertion here, because with one net there is no wrong answer to tell apart
    (the campaign's identical-duplicates lesson in a new shape: one element
    catches a DROPPED value but not a MISASSIGNED one).
    """
    board = _one_component_board("R_0805")
    board["nets"] = nets if nets is not None else [{"name": "N1", "pins": ["X1.1"]},
                                                   {"name": "N2", "pins": ["X1.2"]}]
    board["design_rules"] = dict(board["design_rules"], net_classes=[entry])
    return board


def test_authored_net_class_minima_reach_the_ir_and_the_member_net():
    """Membership is asserted BY IDENTITY, net name -> class id, over a board
    carrying a classed net AND an unclassed one: `N1` must carry this class's
    derived id and `N2` must carry None. Both halves are load-bearing — the
    first fails on a compiler that never wires `net_class_id`, the second on one
    that wires it to the wrong nets."""
    result = compile_board(_classed_board(
        {"name": "Power", "members": ["N1"],
         "min_trace_width_mm": 0.6, "min_clearance_mm": 0.4}))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    nc, = result.board.design_rules.net_classes
    assert (nc.name, nc.min_trace_width_mm, nc.min_clearance_mm) == ("Power", 0.6, 0.4)
    assert {net.name: net.net_class_id for net in result.board.nets} == \
        {"N1": nc.id, "N2": None}


def test_net_class_ids_are_derived_from_the_name_and_board_namespaced():
    """Same identity rule net ids follow (`derive_id`): the id is a function of
    the class NAME and the board, never authored and never the raw name — so the
    same class name in two boards yields two distinct ids."""
    def one(board_name):
        board = _classed_board({"name": "Power", "members": ["N1"],
                                "min_trace_width_mm": 0.6})
        board["name"] = board_name
        result = compile_board(board)
        assert isinstance(result, ResolutionSuccess), _errors(result)
        return result.board.design_rules.net_classes[0].id

    a, b = one("board-A"), one("board-B")
    assert a.startswith("net-class:") and b.startswith("net-class:")
    assert a != b


def test_duplicate_net_class_name_fails_closed():
    """Mirrors `duplicate_net`: two classes cannot share a name, because the name
    IS the identity the id is derived from — admitting both would mint one id for
    two different rule sets."""
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "Power", "min_trace_width_mm": 0.6},
        {"name": "Power", "min_clearance_mm": 0.4},
    ])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "duplicate_net_class" in _errors(result)


def test_net_class_member_naming_no_net_fails_closed():
    result = compile_board(_classed_board(
        {"name": "Power", "members": ["N1", "GHOST"], "min_trace_width_mm": 0.6}))
    assert isinstance(result, ResolutionFailure)
    assert "net_class_unknown_member" in _errors(result)


def test_a_net_claimed_by_two_net_classes_fails_closed():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "Power", "members": ["N1"], "min_trace_width_mm": 0.6},
        {"name": "Fast", "members": ["N1"], "min_clearance_mm": 0.4},
    ])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "duplicate_net_class_membership" in _errors(result)


@pytest.mark.parametrize("field", ["trace_width_mm", "via_diameter_mm", "via_drill_mm"])
def test_a_net_class_field_no_consumer_reads_is_refused(field):
    """D2: routing and geometric DRC read `min_trace_width_mm`/`min_clearance_mm`
    and NOTHING else off a class. Carrying the nominal fields would put a number
    in the IR that changes no copper — a rule that lies about being in force — so
    they go through the compiler's declared-but-not-modeled policy, the same one
    the diff-pair rules use, and are FATAL because 'rules' is requested."""
    result = compile_board(_classed_board(
        {"name": "Power", "members": ["N1"], field: 0.6}))
    assert isinstance(result, ResolutionFailure)
    assert "unsupported_design_rule" in _errors(result)
    # Asserted as `declares <field>,` — the diagnostic's own phrasing for the
    # field it REJECTED — not as a bare substring. A bare `field in d.message`
    # cannot fail for the `trace_width_mm` arm: the message's fixed boilerplate
    # names `min_trace_width_mm`, which CONTAINS `trace_width_mm`, so the arm
    # would pass even if the diagnostic named an entirely different field.
    assert any(f"declares {field}," in d.message for d in result.diagnostics), \
        [d.message for d in result.diagnostics]


def test_a_net_class_field_no_consumer_reads_is_warned_when_cam_only():
    """The same policy's non-fatal branch, exactly as the diff-pair pair pins it.
    Unreachable from production (`V1_FAB_OUTPUTS` and `V1_ROUTING_OUTPUTS` both
    contain 'rules'); pinned so a future CAM-only profile degrades rather than
    inheriting a fatality argued from DRC/routing."""
    result = compile_board(
        _classed_board({"name": "Power", "members": ["N1"], "trace_width_mm": 0.6}),
        requested_outputs=("copper", "drill", "mask"))
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert any(d.code == "unsupported_design_rule" and d.severity is DiagnosticSeverity.WARNING
               for d in result.diagnostics)


@pytest.mark.parametrize("field,value", [
    ("min_trace_width_mm", 0),
    ("min_trace_width_mm", -0.1),
    ("min_trace_width_mm", "0.6"),
    ("min_clearance_mm", 0),
    ("min_clearance_mm", -0.1),
])
def test_an_inadmissible_net_class_minimum_fails_closed(field, value):
    """D3: an authored class minimum is admitted through `_is_positive_number`,
    the SAME predicate the board-level design_rules numbers go through — which is
    STRICTER than the IR's own `NetClass` validation (`_nonnegative`, which would
    take a 0). A class is a design rule authored in the same block by the same
    person; it cannot be admitted on looser terms than the blanket rule it
    overrides, and the IR is not relaxed to match."""
    result = compile_board(_classed_board(
        {"name": "Power", "members": ["N1"], field: value}))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_net_class" in _errors(result)
    assert any(field in d.message for d in result.diagnostics)


@pytest.mark.parametrize("entry", [
    pytest.param({"name": "Power", "members": ["N1"], "id": "nc:power"},
                 id="authored-id"),
    pytest.param({"members": ["N1"], "min_trace_width_mm": 0.6},
                 id="no-name-key"),
    pytest.param({"name": "Power", "members": "N1", "min_trace_width_mm": 0.6},
                 id="members-not-a-list"),
    pytest.param({"name": "Power", "members": [42], "min_trace_width_mm": 0.6},
                 id="member-not-a-string"),
    # The three branches below were reachable but unpinned: each already behaved
    # correctly, which is exactly the state in which a regression goes unnoticed.
    pytest.param(42, id="entry-not-a-mapping"),
    pytest.param({"name": "", "members": ["N1"], "min_trace_width_mm": 0.6},
                 id="empty-name"),
    pytest.param({"name": "Power", "members": [""], "min_trace_width_mm": 0.6},
                 id="empty-member"),
])
def test_a_malformed_net_class_entry_fails_closed(entry):
    """Every malformed authored class is refused with `invalid_net_class` —
    asserted on the CODE, not merely on failure, so a defect that starts failing
    for a different reason (the IR raising, or the member falling through to the
    unknown-member pass) is not mistaken for this branch still working.

    An authored `id` lands here on purpose: identity is DERIVED from the name, so
    accepting the key would silently overrule what the author wrote. An EMPTY
    name lands here rather than at `NetClass.__post_init__`'s own `_nonempty`
    guard for the same reason `duplicate_net_class` does not wait for the IR's
    `_unique_ids`: the authoring layer owes the author a diagnostic, not an
    exception out of the compiler.
    """
    result = compile_board(_classed_board(entry))
    assert isinstance(result, ResolutionFailure)
    assert "invalid_net_class" in _errors(result)


def test_an_explicitly_null_unread_net_class_field_is_ignored():
    """A DECLARATION IS A NON-NULL VALUE, not a present key. `via_diameter_mm:`
    with no value states no rule and carries no number, so there is nothing that
    could silently fail to take effect — the whole basis on which a VALUED unread
    field is refused. It is ignored, and the board compiles.

    This is the same `is not None` test the diff-pair check applies (asserted
    side by side below, because the two are one policy with two callers and must
    not drift apart). It is deliberately NOT the presence-not-truthiness rule
    `agent_router.board._refuse_authored_net_classes` applies to the
    `net_classes` key itself; see that docstring for why the two differ.
    """
    ok = compile_board(_classed_board(
        {"name": "Power", "members": ["N1"], "via_diameter_mm": None}))
    assert isinstance(ok, ResolutionSuccess), _errors(ok)
    assert "unsupported_design_rule" not in _errors(ok)

    # The sibling caller, same board shape, same rule.
    board = _classed_board({"name": "Power", "members": ["N1"]})
    board["design_rules"]["diff_pair_gap_mm"] = None
    assert isinstance(compile_board(board), ResolutionSuccess)

    # And the valued form of each still fails, so the test is about NULL only.
    assert isinstance(compile_board(_classed_board(
        {"name": "Power", "members": ["N1"], "via_diameter_mm": 0.9})),
        ResolutionFailure)


def test_a_rules_block_defect_defers_every_net_class_diagnostic():
    """ORDERING, pinned because a docstring here once overclaimed it.
    `_build_net_classes` is the LAST thing `_build_design_rules` does, behind
    four `return None` paths — so a board with BOTH a rules-block defect and a
    broken class reports the rules-block defect ALONE, and the class diagnostics
    wait for a later compile.

    That is deliberate (a rules block that cannot be built has no classes to
    speak of) and matches the diff-pair precedent. The one-pass property net
    classes DO have is across the class LIST, not across the board — see
    `test_every_broken_class_in_the_list_is_reported_in_one_pass`.
    """
    board = _classed_board({"name": "", "members": ["N1"]})   # broken class
    board["design_rules"]["diff_pair_gap_mm"] = 0.2           # broken rules block
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    codes = _errors(result)
    assert "unsupported_design_rule" in codes
    assert "invalid_net_class" not in codes, (
        "class parsing must not have run at all — if it did, the enclosing "
        "return-None ordering has changed and the docstring is now wrong")


def test_every_broken_class_in_the_list_is_reported_in_one_pass():
    """The completeness that IS real: a defect in one class does not stop the
    walk, so an author fixing three classes needs one compile, not three."""
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["design_rules"] = dict(board["design_rules"], net_classes=[
        {"name": "A", "min_trace_width_mm": 0},       # inadmissible minimum
        {"name": "B", "id": "nc:b"},                  # unknown key
        {"name": "C", "members": ["GHOST"]},          # unknown member
    ])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    codes = _errors(result)
    assert codes.count("invalid_net_class") == 2, codes
    assert "net_class_unknown_member" in codes


def test_net_classes_must_be_a_list():
    board = _one_component_board("R_0805")
    board["design_rules"] = dict(board["design_rules"], net_classes={"Power": {}})
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_net_class" in _errors(result)


def test_a_board_authoring_no_net_classes_is_unchanged(corner_board_result):
    """THE REGRESSION FLOOR — every existing board. A board that authors no
    `net_classes` block compiles to the same empty tuple and the same all-None
    `net_class_id`s it did before the authoring surface existed, and raises no
    net-class diagnostic of any kind."""
    assert isinstance(corner_board_result, ResolutionSuccess)
    assert corner_board_result.board.design_rules.net_classes == ()
    assert all(net.net_class_id is None for net in corner_board_result.board.nets)
    assert not [d for d in corner_board_result.diagnostics if "net_class" in d.code]


def test_an_explicitly_empty_net_classes_list_declares_nothing():
    board = _one_component_board("R_0805")
    board["nets"] = [{"name": "N1", "pins": ["X1.1"]}]
    board["design_rules"] = dict(board["design_rules"], net_classes=[])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert result.board.design_rules.net_classes == ()
    assert all(net.net_class_id is None for net in result.board.nets)


# --- The schema doc's examples must COMPILE ---------------------------------
#
# A schema doc whose example does not compile is worse than no doc: it teaches a
# shape the compiler rejects, and every reader who copies it starts from a broken
# board. board-yaml.md's canonical example had drifted to where it failed FIVE
# ways at once (unresolvable footprint, two dangling pin refs, an empty net, and
# a fatal diff-pair rule) while reading as authoritative. This is the gate that
# keeps it honest — the claim in that file's "Compiling the examples" section is
# this test.

_BOARD_YAML_DOC = Path(__file__).parent.parent.parent / "docs" / "board-yaml.md"


def _doc_yaml_blocks() -> list[tuple[int, object]]:
    text = _BOARD_YAML_DOC.read_text(encoding="utf-8")
    return [(text[:m.start()].count("\n") + 1, yaml.safe_load(m.group(1)))
            for m in re.finditer(r"```yaml\n(.*?)```", text, re.S)]


def _host_for_pins(frag: dict) -> dict:
    """A v2 board (the `override` sub-struct is v2-only) carrying the fragment's
    pins verbatim. Hosted on a THROUGH-HOLE footprint because the fragment
    overrides a drill, and an SMD pad has no footprint drill to deviate from."""
    return {
        "version": 2, "id": "board:" + "a" * 32, "name": "pins-host",
        "width_mm": 20, "height_mm": 20, "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [{"ref": "U1",
                        "footprint": "Package_DIP:DIP-6_W7.62mm_Socket",
                        "x_mm": 5, "y_mm": 5, "rotation_deg": 0, "layer": "top",
                        "pins": frag["pins"]}],
        "nets": [{"name": "N", "pins": ["U1.2"]}],
    }


def _host_for_design_rules(frag: dict) -> dict:
    """A board whose design_rules block IS the fragment, with the nets its
    net_classes name actually declared."""
    return {
        "version": 1, "name": "rules-host", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"], "design_rules": frag["design_rules"],
        "components": [{"ref": "R1", "footprint": "R_0805", "x_mm": 5,
                        "y_mm": 10, "rotation_deg": 0, "layer": "top"},
                       {"ref": "R2", "footprint": "R_0805", "x_mm": 15,
                        "y_mm": 10, "rotation_deg": 0, "layer": "top"}],
        "nets": [{"name": "VCC", "pins": ["R1.1"]},
                 {"name": "GND", "pins": ["R2.1"]}],
    }


def _host_for_components(frag: dict) -> dict:
    """A board hosting a doc fragment's components verbatim. Fragments written
    for prose (e.g. the grouping example) may omit footprint/layer — supply
    compiler-required fields without overwriting anything the fragment says."""
    comps = []
    for c in frag["components"]:
        comp = {"footprint": "R_0805", "rotation_deg": 0, "layer": "top"}
        comp.update(c)
        comps.append(comp)
    return {
        "version": 1, "name": "components-host", "width_mm": 60, "height_mm": 60,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": comps,
    }


_DOC_SPLICERS = {"pins": _host_for_pins, "design_rules": _host_for_design_rules,
                 "components": _host_for_components}


@pytest.mark.parametrize("outputs", [V1_FAB_OUTPUTS, V1_ROUTING_OUTPUTS],
                         ids=["fab", "routing"])
def test_every_yaml_example_in_board_yaml_md_compiles(outputs):
    """Compiles EVERY yaml block in the schema doc under BOTH production output
    profiles. A full board is compiled verbatim; a FRAGMENT is only meaningful
    inside a board, so it is spliced into a minimal host and compiled there.

    A new fragment with no splicer FAILS rather than being skipped — silently
    passing over an example is how the canonical one rotted in the first place.
    """
    blocks = _doc_yaml_blocks()
    assert len(blocks) >= 3, f"expected the doc's examples, found {len(blocks)}"
    for line, doc in blocks:
        where = f"{_BOARD_YAML_DOC.name} line {line}"
        assert isinstance(doc, dict), f"{where}: example is not a mapping"
        if "version" in doc:
            board = doc
        else:
            key = next((k for k in _DOC_SPLICERS if k in doc), None)
            assert key is not None, (
                f"{where}: fragment declares {sorted(doc)} and no splicer knows "
                f"how to host it — add one here rather than leaving the example "
                f"unchecked")
            board = _DOC_SPLICERS[key](doc)
        result = compile_board(copy.deepcopy(board), requested_outputs=outputs)
        assert isinstance(result, ResolutionSuccess), (
            f"{where} does not compile: {_errors(result)}")


def test_the_kicad_bridge_refuses_a_net_classed_board():
    """C5. The emitted `design_rules` mapping carries the board's BLANKET
    defaults only — there is no per-class channel — so a dropped class would make
    the KiCad DRC oracle UNSOUND, not merely lossy: the Python kernel checks a
    classed net at its class floors while the .kicad_pcb carries none. It refuses
    on PRESENCE, the same test its zone and board-graphic neighbours use; a
    classless board still passes through untouched."""
    from pcb_worker import kicad

    clean = compile_board(_one_component_board("R_0805"))
    assert isinstance(clean, ResolutionSuccess), _errors(clean)
    kicad._ir_board_dict(clean.board)  # the neighbour case: no class, no refusal

    classed = compile_board(_classed_board(
        {"name": "Power", "members": ["N1"], "min_trace_width_mm": 0.6}))
    assert isinstance(classed, ResolutionSuccess), _errors(classed)
    with pytest.raises(ValueError, match="net class"):
        kicad._ir_board_dict(classed.board)


def test_a_round_shaped_drill_with_unequal_axes_fails_closed():
    """CONTRADICTORY DRILL DATA must refuse, not be silently resolved.

    A DrillDefinition whose shape token says round while its two size axes
    disagree made every consumer believe something different (Codex review
    1090 finding 1, verified end to end): DRC inferred "oblong" from the
    unequal axes and measured the MINOR axis against the slot floor, while
    both fab emitters reduce a drill to a scalar by taking the FIRST axis —
    so a (1.6, 0.6) drill was checked as a 0.6 slot and fabricated as a 1.6
    round hole, with the second axis silently discarded. v1 emits round holes
    only; the honest answer is to refuse rather than pick an axis."""
    from pcb_worker.footprint_def import DrillDefinition

    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="thru_hole", size=(2.0, 2.0),
                         layers=(Layer.from_id("*.Cu"), Layer.from_id("*.Mask")),
                         drill=DrillDefinition(shape="round", size=(1.6, 0.6)))
    assert not _check_pad_capabilities(pad, "J1", diags)
    codes = [d.code for d in diags.tuple()]
    assert "unsupported_hole" in codes, codes
    assert any("axes differ" in d.message for d in diags.tuple())


def test_a_round_drill_with_equal_axes_still_passes():
    """The positive control — without it the row above would pass on a gate
    that simply refused every drilled pad."""
    from pcb_worker.footprint_def import DrillDefinition

    diags = _Diagnostics()
    pad = _synthetic_pad(pad_type="thru_hole", size=(2.0, 2.0),
                         layers=(Layer.from_id("*.Cu"), Layer.from_id("*.Mask")),
                         drill=DrillDefinition(shape="round", size=(0.8, 0.8)))
    assert _check_pad_capabilities(pad, "J1", diags), [
        d.message for d in diags.tuple()]
