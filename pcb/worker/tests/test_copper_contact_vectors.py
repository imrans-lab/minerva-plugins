"""The worker half of the shared pad-contact vectors (pcb/spec/contact).

The GDScript suite tests/gd/test_copper_contact_vectors.gd runs the SAME
directory against the panel's implementation. Both enumerate it, so a case the
two sides answer differently cannot be added without one of them going red.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import pytest

from pcb_worker import copper_contact, drc
from pcb_worker.drc_geom_primitives import Polygon
from pcb_worker.geometry import component_transform
from pcb_worker.pad_source import PadGeom

VECTORS = Path(__file__).resolve().parents[2] / "spec" / "contact"


def _cases() -> list[tuple[str, dict]]:
    found = sorted(p for p in VECTORS.glob("*/case.json"))
    assert found, f"no contact vectors under {VECTORS}"
    return [(p.parent.name, json.loads(p.read_text())) for p in found]


def _pad_geom(spec: dict) -> PadGeom:
    """The vector's pad as the neutral pad-geometry record the real harvest
    hands the builder — no shortcut construction of a shape."""
    w, h = spec["size"]
    pad_type = spec.get("type", "smd")
    drilled = pad_type in ("thru_hole", "np_thru_hole")
    return PadGeom(
        number=spec.get("number", "1"),
        x=spec["at"][0], y=spec["at"][1],
        width=float(w), height=float(h),
        drill=(float(spec.get("drill_mm", 0.4)) if drilled else None),
        annulus=(float(w) if drilled else None),
        plated=(pad_type != "np_thru_hole"),
        shape=spec["shape"],
        corner_rratio=spec.get("corner_rratio"),
        solder_mask_margin=None,
        solder_paste_margin=None,
        pad_type=pad_type,
        layers=list(spec.get("layers") or []),
        from_resolve=True,
        rotation=float(spec.get("rotation_deg", 0.0)),
        raw_shape=spec["shape"],
    )


def _placement(spec: dict):
    """The component a vector's land is placed by, or None when it states none.

    An OPTIONAL `pad.component` block is what turns a vector from a question
    about a land into a question about a PLACED land — the only way these
    vectors can pin the flip a back-mounted part applies, since no footprint
    authors the board side it will end up on. When it is present, `pad.at`,
    `pad.rotation_deg` and `pad.layers` are FOOTPRINT-LOCAL and this is the rule
    that puts them on the board; when it is absent every one of them is already
    board-frame and nothing here moves them.

    Deliberately the production placement (geometry.component_transform), the
    same object drc._harvest_pads builds, so a case measures the harvest's own
    rule rather than a restatement of it in a test.
    """
    comp = spec.get("component")
    if comp is None:
        return None
    return component_transform({
        "x_mm": comp["at"][0],
        "y_mm": comp["at"][1],
        "rotation_deg": comp.get("rotation_deg", 0.0),
        "layer": comp.get("layer", "top"),
    })


def _pad_node(spec: dict):
    layers = spec.get("layers")
    placement = _placement(spec)
    if placement is None:
        centre = (spec["at"][0], spec["at"][1])
        angle = float(spec.get("rotation_deg", 0.0))
        canon = frozenset(layers) if layers else None
    else:
        centre = placement.point((spec["at"][0], spec["at"][1]))
        angle = placement.angle(float(spec.get("rotation_deg", 0.0)))
        canon = drc.placed_pad_layers(placement, list(layers or []))
    return copper_contact.pad_node(
        _pad_geom(spec), centre, angle, canon,
        # A vector always states a size, so the unknown-land fallback is never
        # the answer here; a number that would obviously change a verdict is
        # passed so a silent fall-through to it cannot pass unnoticed.
        1000.0)


def _region_node(spec: dict):
    """The vector's pour region as the conductor node the fill builds: one ring,
    on the zone's own layer."""
    ring = tuple((float(x), float(y)) for (x, y) in spec["ring"])
    layer = spec.get("layer")
    return copper_contact.region_node(
        (Polygon(ring),), frozenset({layer}) if layer else None)


def _trace_node(spec: dict):
    """The vector's trace as the swept copper a whole run is: what a via or a
    land is measured against when the RUN is the target rather than the probe."""
    return copper_contact.segment_node(
        (spec["a"][0], spec["a"][1]), (spec["b"][0], spec["b"][1]),
        float(spec.get("width_mm", 0.0)), spec.get("layer"))


def _target_node(case: dict):
    """The copper the vector's probe is measured AGAINST — a pad's land, a
    pour's filled region, or a trace's swept run. Three builders, ONE predicate:
    that is the whole point of the node shape, so these vectors exercise all of
    them through it."""
    if "region" in case:
        return _region_node(case["region"])
    if "trace" in case:
        return _trace_node(case["trace"])
    return _pad_node(case["pad"])


def _copper_node(spec: dict):
    a = (spec["a"][0], spec["a"][1])
    width = float(spec.get("width_mm", 0.0))
    layer = spec.get("layer")
    if spec["kind"] == "via":
        # LAYERS FROM THE CASE, not None: a vector that states a span is the
        # only way these vectors can ever pin a blind/buried barrel, and the
        # through span every board writes today says the same thing either way.
        layers = spec.get("layers")
        return copper_contact.via_node(
            a, float(spec.get("diameter_mm", 0.0)),
            frozenset(layers) if layers else None)
    if spec["kind"] == "endpoint":
        return copper_contact.endpoint_node(a, width, layer)
    b = (spec["b"][0], spec["b"][1])
    return copper_contact.segment_node(a, b, width, layer)


@pytest.mark.parametrize("name,case", _cases(), ids=lambda v: v if isinstance(v, str) else "")
def test_contact_vector(name: str, case: dict) -> None:
    target = _target_node(case)
    copper = _copper_node(case["copper"])
    got = copper_contact.nodes_touch(copper, target)
    assert got is bool(case["touches"]), (
        f"{name}: expected touches={case['touches']}, got {got}. "
        f"{case['why']} (measured gap "
        f"{copper_contact.node_gap(copper, target):.6f}mm)")


def test_the_predicate_is_symmetric() -> None:
    """Copper reaching copper is not a directed relation. Every consumer picks
    its own argument order, so an asymmetric implementation would answer
    differently for the DRC than for the trace verbs."""
    for name, case in _cases():
        target = _target_node(case)
        copper = _copper_node(case["copper"])
        assert (copper_contact.nodes_touch(copper, target)
                is copper_contact.nodes_touch(target, copper)), name


def test_a_pad_with_no_stated_size_falls_back_to_the_coincidence_disc() -> None:
    """The inline-pin fallback has no land to be exact about, so it keeps the
    credit the centreline kernel always gave it: a disc of the board's own
    coincidence tolerance. Expressed as a shape, so there is still ONE
    predicate rather than a second code path.

    THE PANEL RUNS THE SAME RULE — pcb_copper_contact.unknown_land_radius, with
    DEFAULT_UNKNOWN_LAND_RADIUS_MM equal to the default below — and
    tests/gd/test_copper_contact_vectors.gd probes these same two points. No
    vector can pin this: every vector states a size, so the fallback is never
    the answer inside one.
    """
    assert drc._board_clearance({}) == drc.DEFAULT_COINCIDENT_MM == 0.2
    sizeless = PadGeom(
        number="1", x=0.0, y=0.0, width=None, height=None, drill=None,
        annulus=None, plated=True, shape="rect", corner_rratio=None,
        solder_mask_margin=None, solder_paste_margin=None, pad_type="smd",
        layers=[], from_resolve=False)
    pad = copper_contact.pad_node(sizeless, (0.0, 0.0), 0.0, None,
                                  drc._board_clearance({}))
    inside = copper_contact.endpoint_node((0.15, 0.0), 0.0, "top")
    outside = copper_contact.endpoint_node((0.25, 0.0), 0.0, "top")
    assert copper_contact.nodes_touch(inside, pad)
    assert not copper_contact.nodes_touch(outside, pad)
    assert math.isclose(copper_contact.node_gap(outside, pad), 0.05, abs_tol=1e-9)


def test_an_unsized_via_falls_back_to_the_coincidence_disc() -> None:
    """A via that declares no diameter gets the same disc an unsized LAND gets:
    the board's own coincidence tolerance, 0.2 mm by default.

    THE PANEL RUNS THE SAME RULE — pcb_data.via_radius delegates to
    pcb_copper_contact.unknown_land_radius — and
    tests/gd/test_copper_contact_vectors.gd probes these same two points. The
    probe distance is chosen to separate the two answers the two sides used to
    give: the panel credited a fixed 0.8 mm via (radius 0.40) where the worker
    credited the coincidence disc (radius 0.20), so a run ending 0.30 mm off an
    unsized barrel read joined on one side and dangling on the other.

    No vector can pin this. Both runners hand `copper.diameter_mm` straight to
    via_node, so an unsized via inside a case is a ZERO-radius disc on both
    sides and never reaches either fallback.
    """
    assert drc._via_radius({}, drc._board_clearance({})) == 0.2
    assert drc._via_radius({"diameter_mm": 0.0}, drc._board_clearance({})) == 0.2
    # A stated diameter still wins, even a small one.
    assert drc._via_radius({"diameter_mm": 0.8}, drc._board_clearance({})) == 0.4

    barrel = copper_contact.via_node(
        (0.0, 0.0), 2.0 * drc._via_radius({}, drc._board_clearance({})), None)
    near = copper_contact.endpoint_node((0.15, 0.0), 0.0, "top")
    far = copper_contact.endpoint_node((0.30, 0.0), 0.0, "top")
    assert copper_contact.nodes_touch(near, barrel)
    assert not copper_contact.nodes_touch(far, barrel)
    assert math.isclose(copper_contact.node_gap(far, barrel), 0.10, abs_tol=1e-9)
