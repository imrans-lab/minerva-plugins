"""``FootprintDefinition`` (A1 schema) tests.

The crux is a NON-MOCKED round-trip: for every real ``.kicad_mod`` fixture,
``FootprintDefinition.from_kicad_parsed(parse_kicad_mod(fx)).to_board_pad_dicts()``
must reproduce ``resolve._pads_from_parsed(parse_kicad_mod(fx)["pads"])``
dict-for-dict — proving the new type is a faithful formalization of the live pad
DTO, so a later rewire is a no-op for existing parts. This runs the REAL parser
+ REAL resolve helper over REAL fixture files.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from pcb_worker import resolve
from pcb_worker.footprints import parse_kicad_mod
from pcb_worker.footprint_def import (
    DrillDefinition,
    FootprintDefinition,
    PadDefinition,
    PadShape,
)

HERE = Path(__file__).resolve().parent
FIXTURE_LIB = HERE / "testdata" / "fixture_lib"
SMART_REMOTE = HERE / "testdata" / "smart_remote.yaml"

# The new + existing local fixtures (roundrect SMD + rect SMD).
_LOCAL_FIXTURES = [
    FIXTURE_LIB / "Resistor_SMD.pretty" / "R_0603_1608Metric.kicad_mod",
    FIXTURE_LIB / "Resistor_SMD.pretty" / "R_0805_2012Metric.kicad_mod",
    FIXTURE_LIB / "a1_footprints" / "Capacitor_SMD.pretty" / "C_0402_1005Metric.kicad_mod",
    FIXTURE_LIB / "a1_footprints" / "Package_SO.pretty" / "SOIC-8_3.9x4.9mm_P1.27mm.kicad_mod",
]


def _smart_remote_parsed():
    """Yield (ref, parsed) for every resolvable footprint the smart-remote
    board references — the real seed library, sha-verified via resolve."""
    import yaml

    board = yaml.safe_load(SMART_REMOTE.read_text(encoding="utf-8"))
    seen = set()
    for comp in board.get("components", []):
        ref = comp.get("footprint")
        if not ref or ref in seen:
            continue
        seen.add(ref)
        try:
            parsed = resolve.resolve_footprint(ref)
        except Exception:
            continue  # unresolvable → not in scope for the round-trip proof
        yield ref, parsed


# ---------------------------------------------------------------------------
# CRUX: round-trip dict-identity over real parser + real resolve helper.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("fx", _LOCAL_FIXTURES, ids=lambda p: p.name)
def test_roundtrip_matches_resolve_pads_from_parsed_local(fx):
    parsed = parse_kicad_mod(fx)
    got = FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
    expected = resolve._pads_from_parsed(parsed["pads"])
    assert got == expected


def test_roundtrip_matches_resolve_for_smart_remote_parts():
    checked = 0
    for ref, parsed in _smart_remote_parsed():
        got = FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
        expected = resolve._pads_from_parsed(parsed["pads"])
        assert got == expected, f"round-trip drift for {ref}"
        checked += 1
    assert checked > 0, "no smart-remote footprints resolved — proof did not run"


# ---------------------------------------------------------------------------
# Schema-shape guarantees.
# ---------------------------------------------------------------------------


def test_to_board_pad_dicts_exact_keys():
    parsed = parse_kicad_mod(_LOCAL_FIXTURES[0])
    dicts = FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
    assert dicts, "fixture produced no pads"
    for d in dicts:
        assert set(d.keys()) == {
            "number", "type", "shape", "position", "size", "drill", "layers",
        }
        assert set(d["position"].keys()) == {"x", "y"}
        assert set(d["size"].keys()) == {"width", "height"}
        assert set(d["drill"].keys()) == {"x", "y"}


def test_schema_holds_exotic_shape_and_reports_unsupported():
    # RULING 2: the schema can HOLD an exotic kind from day one, marked unsupported.
    for tok in ("custom", "trapezoid", "chamfer"):
        shape = PadShape.from_token(tok)
        assert shape.value == tok
        assert shape.is_supported is False
    # a truly unknown token fails safe to CUSTOM (unsupported), still representable.
    assert PadShape.from_token("no_such_shape") is PadShape.CUSTOM
    # supported kinds report supported.
    for tok in ("rect", "roundrect", "circle", "oval"):
        assert PadShape.from_token(tok).is_supported is True


def test_roundrect_fixture_parses_and_adapter_captures_corner_rratio():
    # The roundrect fixtures parse cleanly and yield roundrect pads end-to-end.
    parsed = parse_kicad_mod(_LOCAL_FIXTURES[2])  # C_0402 (2 roundrect pads)
    fp = FootprintDefinition.from_kicad_parsed(parsed)
    assert len(fp.pads) == 2
    assert all(p.shape is PadShape.ROUNDRECT for p in fp.pads)

    # corner_rratio capture through the adapter: the current parser does not yet
    # surface roundrect_rratio (deferred fenced footprints.py enhancement), so
    # feed a parsed pad carrying it — proving the adapter captures it forward-
    # compatibly onto PadDefinition.corner_rratio.
    parsed_with_rratio = {
        "name": "RR",
        "pads": [{
            "number": "1", "type": "smd", "shape": "roundrect",
            "x_mm": -0.5, "y_mm": 0.0, "size": [0.62, 0.62],
            "drill": None, "layers": ["F.Cu", "F.Paste", "F.Mask"],
            "roundrect_rratio": 0.25,
        }],
        "graphics": [],
    }
    pad = FootprintDefinition.from_kicad_parsed(parsed_with_rratio).pads[0]
    assert pad.corner_rratio == 0.25
    assert pad.shape is PadShape.ROUNDRECT


def test_thru_hole_yields_drill_and_smd_yields_none():
    # SMD fixture → every pad drill is None.
    smd = FootprintDefinition.from_kicad_parsed(parse_kicad_mod(_LOCAL_FIXTURES[0]))
    assert smd.pads and all(p.drill is None for p in smd.pads)

    # A thru-hole footprint from the real seed library → DrillDefinition present.
    thru = FootprintDefinition.from_kicad_parsed(
        resolve.resolve_footprint("Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical")
    )
    drilled = [p for p in thru.pads if p.drill is not None]
    assert drilled, "thru-hole footprint yielded no drilled pads"
    for p in drilled:
        assert p.pad_type in ("thru_hole", "np_thru_hole")
        assert isinstance(p.drill, DrillDefinition)
        assert p.drill.shape == "round"
        assert p.drill.size[0] > 0 and p.drill.size[1] > 0


def test_np_thru_hole_drill_is_unplated():
    # MountingHole is a non-plated thru-hole → drill.plated is False.
    fp = FootprintDefinition.from_kicad_parsed(
        resolve.resolve_footprint("MountingHole:MountingHole_3.2mm_M3")
    )
    np_pads = [p for p in fp.pads if p.pad_type == "np_thru_hole"]
    assert np_pads, "expected a non-plated thru-hole pad"
    for p in np_pads:
        assert p.drill is not None and p.drill.plated is False
