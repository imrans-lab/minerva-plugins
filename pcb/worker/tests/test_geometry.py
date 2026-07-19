"""Safety proof for the consolidated component-placement transform.

pcb_worker.geometry is now the SINGLE source of the rotate-a-local-offset math
that gerber.py, drc.py and route_bridge.py previously each carried. These tests
prove the promoted ``rotate_local_offset`` reproduces BOTH historical forms
(gerber's ``radians(-deg)`` matrix and route_bridge's hand-written
``radians(+deg)`` matrix) bit-for-bit, and that ``place_point`` matches the
independent agent_router KiCad-reader oracle. If the three ever disagreed, the
consolidation would be unsafe — this is the teeth.
"""

from __future__ import annotations

import math
import json
from pathlib import Path

import pytest

from pcb_worker.geometry import PlacementTransform, rotate_local_offset, place_point
from pcb_worker import resolve
from pcb_worker.footprint_def import ArcGraphic, FootprintDefinition
from pcb_worker.resolved_board import ArcGeometry, Layer, LineGeometry, Side
# READ-ONLY oracle: the agent_router KiCad reader's absolute-position transform,
# derived independently from gerber/route_bridge. We match it, never modify it.
from agent_router.kicad_io import _transform_position


ANGLES = [0.0, 30.0, 37.5, 45.0, 90.0, 135.0, 180.0, -90.0, 270.0]
OFFSETS = [(1.0, 0.0), (0.0, 1.0), (2.5, -3.7), (-4.2, -1.1), (3.7, 2.1)]
ORACLE_PATH = Path(__file__).parent / "testdata" / "k1_bottom_oracle.json"


def _gerber_form(px: float, py: float, deg: float) -> tuple[float, float]:
    """gerber.py's historical rotation: radians(-deg) CCW matrix."""
    if deg == 0.0:
        return px, py
    r = math.radians(-deg)
    c, s = math.cos(r), math.sin(r)
    return px * c - py * s, px * s + py * c


def _route_bridge_form(px: float, py: float, deg: float) -> tuple[float, float]:
    """route_bridge.py's historical rotation: hand-written radians(+deg) matrix."""
    if not deg:
        return px, py
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return px * c + py * s, -px * s + py * c


@pytest.mark.parametrize("deg", ANGLES)
@pytest.mark.parametrize("px,py", OFFSETS)
def test_rotate_matches_both_historical_forms(deg, px, py):
    """(a) EQUIVALENCE: the promoted rotate agrees with BOTH prior forms."""
    got = rotate_local_offset(px, py, deg)
    gerber = _gerber_form(px, py, deg)
    route = _route_bridge_form(px, py, deg)
    assert got == pytest.approx(gerber, abs=1e-12)
    assert got == pytest.approx(route, abs=1e-12)
    # And the two historical forms agree with each other (this is WHY it is safe).
    assert gerber == pytest.approx(route, abs=1e-12)


@pytest.mark.parametrize("cx,cy,deg,lx,ly", [
    (10.0, 20.0, 0.0, 1.0, 0.0),
    (50.0, 50.0, 90.0, 1.0, 0.0),
    (50.0, 50.0, 90.0, -1.0, 0.0),
    (3.0, -7.5, 37.5, 2.0, -1.0),
    (-4.0, 8.0, 180.0, 0.5, 0.5),
])
def test_place_point_matches_kicad_oracle(cx, cy, deg, lx, ly):
    """(b) ORACLE MATCH: place_point == kicad_io._transform_position."""
    got = place_point(cx, cy, deg, lx, ly)
    # _transform_position(rel_x, rel_y, fp_x, fp_y, rotation)
    oracle = _transform_position(lx, ly, cx, cy, deg)
    assert got == pytest.approx(oracle, abs=1e-9)


def test_zero_degree_identity_is_exact():
    """(c) 0-deg short-circuit returns inputs unchanged with NO float drift."""
    assert rotate_local_offset(3.7, -2.1, 0.0) == (3.7, -2.1)


def test_bottom_placement_matches_pcbnew_oracle():
    """Pads, line, arc, angles, and layers agree with pcbnew's native flip."""
    oracle = json.loads(ORACLE_PATH.read_text(encoding="utf-8"))
    source, expected = oracle["source"], oracle["expected"]
    transform = PlacementTransform(
        tuple(source["position"]), source["rotation_deg"], Side(source["side"]),
    )

    for raw, want in zip(source["pads"], expected["pads"], strict=True):
        assert transform.point(tuple(raw["local_position"])) == pytest.approx(
            want["position"], abs=1e-6,
        )
        assert transform.angle(raw["local_rotation_deg"]) == pytest.approx(
            want["rotation_deg"], abs=1e-9,
        )
        assert [layer.id for layer in transform.layers(tuple(
            Layer.from_id(value) for value in raw["layers"]
        ))] == want["layers"]

    line = source["line"]
    placed_line = transform.graphic(LineGeometry(tuple(line["a"]), tuple(line["b"])))
    assert placed_line.a == pytest.approx(expected["line"]["a"], abs=1e-6)
    assert placed_line.b == pytest.approx(expected["line"]["b"], abs=1e-6)
    assert transform.layer(Layer.from_id(line["layer"])).id == expected["line"]["layer"]

    arc = source["arc"]
    placed_arc = transform.graphic(ArcGeometry(
        tuple(arc["start"]), tuple(arc["mid"]), tuple(arc["end"]),
    ))
    assert placed_arc.start == pytest.approx(expected["arc"]["start"], abs=1e-6)
    assert placed_arc.mid == pytest.approx(expected["arc"]["mid"], abs=1e-6)
    assert placed_arc.end == pytest.approx(expected["arc"]["end"], abs=1e-6)
    assert transform.layer(Layer.from_id(arc["layer"])).id == expected["arc"]["layer"]


def test_top_placement_is_existing_place_point_contract():
    transform = PlacementTransform((12.0, 7.0), 37.5, Side.TOP)
    assert transform.point((2.0, -1.0)) == place_point(12.0, 7.0, 37.5, 2.0, -1.0)
    assert transform.angle(22.5) == 60.0
    assert transform.layer(Layer.from_id("F.SilkS")).id == "F.SilkS"


@pytest.mark.parametrize("layer_id", ["*.Cu", "*.Mask", "Edge.Cuts", "User.1"])
def test_bottom_placement_preserves_wildcard_and_global_layers(layer_id):
    transform = PlacementTransform((0.0, 0.0), 0.0, Side.BOTTOM)
    assert transform.layer(Layer.from_id(layer_id)).id == layer_id


@pytest.mark.parametrize("layer_id, expected", [
    ("F.Cu", "B.Cu"),
    ("B.Cu", "F.Cu"),
    ("F.Fab", "B.Fab"),
    ("B.Paste", "F.Paste"),
])
def test_bottom_placement_swaps_explicit_sided_layers(layer_id, expected):
    transform = PlacementTransform((0.0, 0.0), 0.0, Side.BOTTOM)
    assert transform.layer(Layer.from_id(layer_id)).id == expected


def test_bottom_mirror_and_layer_map_are_involutions():
    mirror = PlacementTransform((0.0, 0.0), 0.0, Side.BOTTOM)
    point = (3.25, -7.5)
    assert mirror.point(mirror.point(point)) == point
    for layer_id in ("F.Cu", "B.Mask", "F.SilkS", "B.CrtYd", "*.Cu", "User.2"):
        layer = Layer.from_id(layer_id)
        assert layer.flipped().flipped() == layer


def _orientation(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def test_bottom_reflection_reverses_real_dip6_arc_winding():
    definition = FootprintDefinition.from_kicad_parsed(
        resolve.resolve_footprint("Package_DIP:DIP-6_W7.62mm_Socket")
    )
    source = next(item for item in definition.graphics if isinstance(item, ArcGraphic))
    local = ArcGeometry(source.start, source.mid, source.end)
    placed = PlacementTransform((10.0, 20.0), 31.0, Side.BOTTOM).graphic(local)
    assert _orientation(local.start, local.mid, local.end) * _orientation(
        placed.start, placed.mid, placed.end,
    ) < 0
