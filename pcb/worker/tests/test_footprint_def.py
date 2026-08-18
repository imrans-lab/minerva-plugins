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
from dataclasses import replace

import pytest

from pcb_worker import resolve
from pcb_worker.footprints import load_lockfile, parse_kicad_mod
from pcb_worker.footprint_def import (
    ArcGraphic,
    CircleGraphic,
    DrillDefinition,
    FootprintDefinition,
    LineGraphic,
    PadDefinition,
    PadShape,
    PolyGraphic,
    Provenance,
)

HERE = Path(__file__).resolve().parent
FIXTURE_LIB = HERE / "testdata" / "fixture_lib"

# The new + existing local fixtures (roundrect SMD + rect SMD).
_LOCAL_FIXTURES = [
    FIXTURE_LIB / "Resistor_SMD.pretty" / "R_0603_1608Metric.kicad_mod",
    FIXTURE_LIB / "Resistor_SMD.pretty" / "R_0805_2012Metric.kicad_mod",
    FIXTURE_LIB / "a1_footprints" / "Capacitor_SMD.pretty" / "C_0402_1005Metric.kicad_mod",
    FIXTURE_LIB / "a1_footprints" / "Package_SO.pretty" / "SOIC-8_3.9x4.9mm_P1.27mm.kicad_mod",
]


def _seed_library_parsed():
    """Yield (ref, parsed) for every footprint in the real seed library
    (``load_lockfile()``), sha-verified via resolve.

    Used to iterate EVERY footprint any board could reference, rather than only
    those a specific board's component list happens to name. This used to walk
    a real product board's (``smart_remote.yaml``) component list; that board was
    withdrawn from the corpus (docket 019fbe68c5f8, an IP concern — see
    testdata/POLICY.md), and going through the lockfile directly is not just a
    workaround but a strictly STRONGER proof: it covers every seed footprint,
    board-shaped or not, and needs no fixture at all — see
    ``test_lockfile_wide_adapter_census_is_explicit_and_nonblocking`` below, which
    already iterates the same lockfile with no board involved."""
    lock = load_lockfile()
    for ref in sorted(lock):
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


def test_roundtrip_matches_resolve_for_every_seed_footprint():
    checked = 0
    for ref, parsed in _seed_library_parsed():
        got = FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
        expected = resolve._pads_from_parsed(parsed["pads"])
        assert got == expected, f"round-trip drift for {ref}"
        checked += 1
    assert checked > 0, "no seed-library footprints resolved — proof did not run"


# ---------------------------------------------------------------------------
# Schema-shape guarantees.
# ---------------------------------------------------------------------------


def test_to_board_pad_dicts_exact_keys():
    parsed = parse_kicad_mod(_LOCAL_FIXTURES[0])
    dicts = FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
    assert dicts, "fixture produced no pads"
    for d in dicts:
        # raw_shape (D1 provenance) is present because real footprint pads all
        # AUTHOR a shape token — the signal th_land uses to shape an equal-axis land.
        assert set(d.keys()) == {
            "number", "type", "shape", "position", "size", "drill", "layers",
            "raw_shape",
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


def test_content_identity_excludes_provenance_but_tracks_geometry():
    parsed = parse_kicad_mod(_LOCAL_FIXTURES[0])
    first = FootprintDefinition.from_kicad_parsed(
        parsed, Provenance("one", "aaa", "MIT", "2026-07-19"),
    )
    second = FootprintDefinition.from_kicad_parsed(
        parsed, Provenance("two", "bbb", "Apache-2.0", "2027-01-01"),
    )
    assert first.content_id == second.content_id
    assert len(first.content_id) == 64

    changed_pad = replace(first.pads[0], position=(9.0, 9.0))
    changed = replace(first, pads=(changed_pad, *first.pads[1:]))
    assert changed.content_id != first.content_id


def test_definition_local_ids_disambiguate_duplicate_pad_numbers():
    parsed = {
        "name": "Duplicated",
        "pads": [
            {"number": "1", "type": "smd", "shape": "rect", "x_mm": 0.0,
             "y_mm": 0.0, "size": [1.0, 1.0], "drill": None, "layers": ["F.Cu"]},
            {"number": "1", "type": "smd", "shape": "rect", "x_mm": 2.0,
             "y_mm": 0.0, "size": [1.0, 1.0], "drill": None, "layers": ["F.Cu"]},
        ],
        "graphics": [],
    }
    fp = FootprintDefinition.from_kicad_parsed(parsed)
    assert [pad.source_id for pad in fp.pads] == ["pad:1:0", "pad:1:1"]


def test_sizeless_pad_stays_none_instead_of_inventing_geometry():
    parsed = {
        "name": "Sizeless",
        "pads": [{
            "number": "1", "type": "smd", "shape": "rect",
            "x_mm": 0.0, "y_mm": 0.0, "size": None,
            "drill": None, "layers": ["F.Cu"],
        }],
        "graphics": [],
    }
    fp = FootprintDefinition.from_kicad_parsed(parsed)
    assert fp.pads[0].size is None
    assert fp.to_board_pad_dicts()[0]["size"] == {"width": None, "height": None}


def test_unknown_pad_type_is_preserved_and_blocks_only_strict_new_path():
    parsed = {
        "name": "UnknownPad",
        "pads": [{
            "number": "1", "type": "future_pad", "shape": "rect",
            "x_mm": 0.0, "y_mm": 0.0, "size": [1.0, 1.0],
            "drill": None, "layers": ["F.Cu"],
        }],
        "graphics": [],
    }
    pad = FootprintDefinition.from_kicad_parsed(parsed).pads[0]
    assert pad.raw_pad_type == "future_pad"
    assert pad.pad_type == "smd"  # compatibility projection only
    marker = next(item for item in pad.unsupported if item.feature == "unknown_pad_type")
    assert marker.default_blocking is True
    assert marker.source_ref.entity_id == "pad:1:0"


def test_graphic_adapter_has_one_typed_variant_per_modeled_primitive():
    parsed = {
        "name": "Graphics",
        "pads": [],
        "graphics": [
            {"kind": "line", "layer": "B.Fab", "width": 0.1,
             "start": [0.0, 0.0], "end": [1.0, 0.0]},
            {"kind": "circle", "layer": "F.Paste", "width": 0.0,
             "center": [0.0, 0.0], "radius": 1.0},
            {"kind": "arc", "layer": "B.SilkS", "width": 0.1,
             "points": [[-1.0, 0.0], [0.0, -1.0], [1.0, 0.0]]},
            {"kind": "poly", "layer": "F.CrtYd", "width": 0.05,
             "points": [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]]},
        ],
    }
    fp = FootprintDefinition.from_kicad_parsed(parsed)
    assert [type(item) for item in fp.graphics] == [
        LineGraphic, CircleGraphic, ArcGraphic, PolyGraphic,
    ]
    assert [item.source_id for item in fp.graphics] == [
        "graphic:0", "graphic:1", "graphic:2", "graphic:3",
    ]
    assert [item.layer.id for item in fp.graphics] == [
        "B.Fab", "F.Paste", "B.SilkS", "F.CrtYd",
    ]


def test_real_dip6_legacy_arc_normalizes_center_start_sweep():
    fp = FootprintDefinition.from_kicad_parsed(
        resolve.resolve_footprint("Package_DIP:DIP-6_W7.62mm_Socket")
    )
    arc = next(item for item in fp.graphics if isinstance(item, ArcGraphic))
    assert arc.source_id == "graphic:22"
    assert arc.start == pytest.approx((2.81, -1.33))
    assert arc.mid == pytest.approx((3.81, -2.33))
    assert arc.end == pytest.approx((4.81, -1.33))


_EXPECTED_SEED_MARKERS = {
    # 019f77fd6d69: each of these seed footprints carries EXACTLY one fp_text
    # on F.SilkS — its own visible ``reference`` field — and nothing else on
    # that layer. The parser now captures that one node (see
    # footprints._is_captured_reference_fp_text / _parse_reference_text), so
    # its ``('uncaptured_graphic', 'F.SilkS', 'silk')`` marker drops OUT of
    # this census entirely (count reaches zero). Only the reference field is
    # affected — the F.Fab entries below are untouched (F.Fab stays out of
    # scope; see fab_capability.py's frozen boundary).
    "Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    # Smart-remote real-ref batch (2026-08-04): same shape as the connector
    # rows above — one visible reference on F.SilkS (captured, excluded) plus
    # one ``value`` fp_text on F.Fab (out of scope, stays a marker).
    "Adafruit:MAX98357A_I2S_1x7_P2.54mm":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Adafruit:MAX98357A_I2S_1x7_P2.54mm_WithTerminals":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "INMP441:INMP441_I2S_2x3_P2.54mm":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Diode_SMD:D_SMA":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_PinSocket_2.54mm:PinSocket_1x05_P2.54mm_Vertical":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "EVP-ASAC1A:SW_EVP-ASAC1A":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    # ESP32-S3-DevKitC is the control case: its F.SilkS carries the reference
    # field (now captured, excluded) PLUS its own ``value`` field and ~45
    # ``user`` GPIO-label fp_text nodes on the SAME layer — none of those are
    # captured (value/user stay unmodeled, docs/gerbers.md), so the
    # ('uncaptured_graphic', 'F.SilkS', 'silk') marker correctly SURVIVES
    # here (nonzero count), unlike the reference-only footprints above.
    "Espressif:ESP32-S3-DevKitC":
        (("uncaptured_graphic", "F.SilkS", "silk"), ("uncaptured_graphic", "F.Fab", "fab")),
    "MountingHole:MountingHole_3.2mm_M3": (
        ("uncaptured_graphic", "Cmts.User", "documentation"),
        ("uncaptured_graphic", "F.Fab", "fab"),
    ),
    "Package_DIP:DIP-6_W7.62mm_Socket":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    # Smart-remote v2 official KiCad seed expansion.  Their value text remains
    # an explicit nonblocking F.Fab omission.  The QFN also carries an authored
    # zone-connect preference on exposed pad 17; that existing capability marker
    # is recorded independently of its now-supported paste-only apertures.
    "Capacitor_SMD:C_0402_1005Metric":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Capacitor_SMD:C_1210_3225Metric":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_JST:JST_PH_S2B-PH-SM4-TB_1x02-1MP_P2.00mm_Horizontal":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_JST:JST_PH_S4B-PH-SM4-TB_1x04-1MP_P2.00mm_Horizontal":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_JST:JST_PH_S5B-PH-SM4-TB_1x05-1MP_P2.00mm_Horizontal":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Connector_JST:JST_XH_S4B-XH-SM4-TB_1x04-1MP_P2.50mm_Horizontal":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Fuse:Fuse_1206_3216Metric":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Inductor_SMD:L_Vishay_IFSC-1515AH_4x4x1.8mm":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.68x1.68mm": (
        ("uncaptured_graphic", "F.Fab", "fab"),
        ("zone_connect", None, "copper"),
    ),
    "Package_TO_SOT_SMD:SOT-23":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Package_TO_SOT_SMD:TSOT-23-6":
        (("uncaptured_graphic", "F.Fab", "fab"),),
    "Resistor_SMD:R_0402_1005Metric":
        (("uncaptured_graphic", "F.Fab", "fab"),),
}


def test_lockfile_wide_adapter_census_is_explicit_and_nonblocking():
    lock = load_lockfile()
    observed = {}
    for ref in sorted(lock):
        parsed = resolve.resolve_footprint(ref)
        first = FootprintDefinition.from_kicad_parsed(parsed)
        second = FootprintDefinition.from_kicad_parsed(parsed)
        assert first.content_id == second.content_id
        assert len({item.source_id for item in (*first.pads, *first.graphics)}) == (
            len(first.pads) + len(first.graphics)
        )
        markers = [*first.unsupported]
        for pad in first.pads:
            markers.extend(pad.unsupported)
        assert not any(marker.default_blocking for marker in markers), ref
        if markers:
            observed[ref] = tuple(
                (item.feature, item.affected_layer.id if item.affected_layer else None,
                 item.domain.value)
                for item in markers
            )
    assert observed == _EXPECTED_SEED_MARKERS
