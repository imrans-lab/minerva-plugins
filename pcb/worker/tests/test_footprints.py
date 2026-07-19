"""Footprint parser + seed-library tests (offline).

Covers:
  (a) parse all 8 seed footprints -> expected pad counts + silk/courtyard graphics,
  (b) COINCIDENCE golden -- resolved-footprint pad LOCAL positions equal the
      smart-remote board's declared pin LOCAL positions within 0.01mm (the
      validated prototype measured 0.000mm for all 10 components),
  (c) lockfile sha256 integrity.

All fixtures are vendored in-repo (pcb/library/footprints + tests/testdata);
no network access.
"""

from __future__ import annotations

import math
from pathlib import Path

import pytest
import yaml

from pcb_worker import footprints
from pcb_worker.footprints import (
    DEFAULT_LIBRARY_ROOT,
    DEFAULT_LOCKFILE,
    load_lockfile,
    parse_kicad_mod,
    resolve_footprint,
    sha256_file,
)

HERE = Path(__file__).resolve().parent
BOARD_YAML = HERE / "testdata" / "footprints" / "smart-remote-orig.yaml"

# Expected pad count per footprint ref. From the real KiCad footprints.
EXPECTED_PAD_COUNTS = {
    "Espressif:ESP32-S3-DevKitC": 44,
    "Package_DIP:DIP-6_W7.62mm_Socket": 6,
    "Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical": 4,
    "Connector_PinSocket_2.54mm:PinSocket_1x05_P2.54mm_Vertical": 5,
    "Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical": 7,
    "Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal": 2,
    "MountingHole:MountingHole_3.2mm_M3": 1,
    "EVP-ASAC1A:SW_EVP-ASAC1A": 2,
    "R_0805": 2,
    "C_0805": 2,
    "TH_TestPoint": 1,
}

# MountingHole is a purely-mechanical footprint: it carries NO F.SilkS graphics
# (only an F.CrtYd courtyard circle + an F.Fab/Cmts marker). Every other seed
# footprint has a real silkscreen body outline.
NO_SILK_REFS = {"MountingHole:MountingHole_3.2mm_M3"}


def _silk_graphics(parsed: dict) -> list[dict]:
    return [g for g in parsed["graphics"] if g["layer"] == "F.SilkS"]


def _courtyard_graphics(parsed: dict) -> list[dict]:
    return [g for g in parsed["graphics"] if g["layer"] == "F.CrtYd"]


# ---------------------------------------------------------------------------
# (a) Parse all 8 -> pad counts + graphics present.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("ref, expected_pads", sorted(EXPECTED_PAD_COUNTS.items()))
def test_parse_seed_footprint_pad_counts(ref, expected_pads):
    parsed = resolve_footprint(ref)
    assert parsed["name"], f"{ref}: parsed footprint has no name"
    assert len(parsed["pads"]) == expected_pads, (
        f"{ref}: got {len(parsed['pads'])} pads, expected {expected_pads}"
    )
    # Every pad has a resolvable local position and a size.
    for pad in parsed["pads"]:
        assert pad["x_mm"] is not None and pad["y_mm"] is not None, pad
        assert pad["size"] and pad["size"][0] is not None, pad


@pytest.mark.parametrize("ref", sorted(EXPECTED_PAD_COUNTS))
def test_seed_footprint_has_graphics(ref):
    parsed = resolve_footprint(ref)
    silk = _silk_graphics(parsed)
    crtyd = _courtyard_graphics(parsed)
    # Only F.SilkS / F.CrtYd graphics are extracted.
    assert all(g["layer"] in {"F.SilkS", "F.CrtYd"} for g in parsed["graphics"])
    if ref in NO_SILK_REFS:
        # Mechanical footprint: no silkscreen, but it must have a courtyard.
        assert silk == [], f"{ref}: unexpectedly has silk graphics"
        assert len(crtyd) >= 1, f"{ref}: expected >=1 courtyard graphic"
    else:
        assert len(silk) >= 1, f"{ref}: expected >=1 F.SilkS graphic"


def test_esp32_has_rich_silkscreen_body_outline():
    """The ESP32 module carries many silk segments (its body outline + pin-1
    marker), not just a stray line."""
    parsed = resolve_footprint("Espressif:ESP32-S3-DevKitC")
    silk = _silk_graphics(parsed)
    assert len(silk) >= 5, f"ESP32 silk graphics too few: {len(silk)}"


def test_parse_accepts_raw_text_and_path():
    """parse_kicad_mod accepts a Path and equivalent raw text identically."""
    ref = "Package_DIP:DIP-6_W7.62mm_Socket"
    entry = load_lockfile()[ref]
    path = DEFAULT_LIBRARY_ROOT / entry["path"]
    from_path = parse_kicad_mod(path)
    from_text = parse_kicad_mod(path.read_text(encoding="utf-8"))
    assert from_path == from_text
    assert from_path["name"] == "DIP-6_W7.62mm_Socket"


def test_pad_shapes_and_drill_parsed():
    """Sanity on field extraction: DIP-6 pads are through-hole with a drill;
    the surface-mount switch pads have no drill."""
    dip = resolve_footprint("Package_DIP:DIP-6_W7.62mm_Socket")
    assert all(p["drill"] == pytest.approx(0.8) for p in dip["pads"])
    assert {p["shape"] for p in dip["pads"]} <= {"rect", "oval", "circle", "roundrect"}

    sw = resolve_footprint("EVP-ASAC1A:SW_EVP-ASAC1A")
    assert {p["number"] for p in sw["pads"]} == {"A", "B"}
    assert all(p["drill"] is None for p in sw["pads"])


# ---------------------------------------------------------------------------
# (b) COINCIDENCE golden: resolved footprint local pads == board declared pins.
# ---------------------------------------------------------------------------


def _load_board() -> dict:
    return yaml.safe_load(BOARD_YAML.read_text(encoding="utf-8"))


def test_coincidence_golden_all_components():
    """For every smart-remote component, the resolved footprint's pad LOCAL
    positions must equal the board's declared pin LOCAL positions within
    0.01mm. The validated prototype measured 0.000mm for all 10 components."""
    board = _load_board()
    tol = 0.01
    overall_worst = 0.0
    checked = 0

    for comp in board["components"]:
        ref = comp["ref"]
        parsed = resolve_footprint(comp["footprint"])
        fp_pads = {p["number"]: (p["x_mm"], p["y_mm"]) for p in parsed["pads"]}

        for pin in comp["pins"]:
            num = str(pin["number"])
            assert num in fp_pads, (
                f"{ref}: pin {num} not found in footprint {comp['footprint']}"
            )
            fx, fy = fp_pads[num]
            d = math.hypot(fx - pin["x_mm"], fy - pin["y_mm"])
            overall_worst = max(overall_worst, d)
            assert d <= tol, (
                f"{ref} pin {num}: footprint-local ({fx},{fy}) vs board-local "
                f"({pin['x_mm']},{pin['y_mm']}) -> {d:.4f}mm > {tol}mm"
            )
            checked += 1

    assert checked > 0
    # Prototype baseline: 0.000mm. Keep the golden tight.
    assert overall_worst < tol


def test_all_board_footprints_resolvable():
    board = _load_board()
    refs = {c["footprint"] for c in board["components"]}
    for ref in refs:
        parsed = resolve_footprint(ref)
        assert parsed["pads"], f"{ref}: resolved to zero pads"


# ---------------------------------------------------------------------------
# (d) Modern KiCad 7/8 format branches. The 8 vendored fixtures are all the
#     legacy `(width ..)` form, so the `(stroke (width ..))` and 3-point-arc
#     `(mid ..)` paths are untested by them — yet current KiCad libraries emit
#     exactly those. Exercise both on synthetic text (the branch real on-demand
#     fetches will hit first).
# ---------------------------------------------------------------------------

_KICAD7_FP = """(footprint "TEST7" (layer "F.Cu")
  (fp_line (start -1 -1) (end 1 -1) (stroke (width 0.15) (type solid)) (layer "F.SilkS"))
  (fp_arc (start -1 0) (mid 0 1) (end 1 0) (stroke (width 0.12) (type solid)) (layer "F.SilkS"))
  (fp_circle (center 0 0) (end 0.5 0) (stroke (width 0.1) (type solid)) (layer "F.CrtYd"))
  (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu"))
)
"""


def test_kicad7_stroke_and_arc_mid(tmp_path):
    p = tmp_path / "TEST7.kicad_mod"
    p.write_text(_KICAD7_FP, encoding="utf-8")
    fp = parse_kicad_mod(p)
    by_kind: dict[str, list] = {}
    for g in fp["graphics"]:
        by_kind.setdefault(g["kind"], []).append(g)

    # (stroke (width 0.15)) parsed off an F.SilkS line
    line = by_kind["line"][0]
    assert line["layer"] == "F.SilkS"
    assert line["width"] == pytest.approx(0.15)
    assert line["start"] == [-1.0, -1.0] and line["end"] == [1.0, -1.0]

    # 3-point (mid) arc: start, mid, end all captured
    arc = by_kind["arc"][0]
    assert arc["points"] == [[-1.0, 0.0], [0.0, 1.0], [1.0, 0.0]]
    assert arc["width"] == pytest.approx(0.12)

    # stroke width also read on a circle (F.CrtYd)
    circ = by_kind["circle"][0]
    assert circ["width"] == pytest.approx(0.1)
    assert circ["radius"] == pytest.approx(0.5)


# ---------------------------------------------------------------------------
# (c) Lockfile sha256 integrity.
# ---------------------------------------------------------------------------


def test_lockfile_covers_every_seed_footprint():
    lock = load_lockfile()
    assert set(lock) == set(EXPECTED_PAD_COUNTS), (
        "lockfile refs drifted from the expected seed set"
    )


def test_lockfile_sha256_matches_disk():
    lock = load_lockfile()
    for ref, entry in lock.items():
        path = DEFAULT_LIBRARY_ROOT / entry["path"]
        assert path.exists(), f"{ref}: seed file missing at {path}"
        actual = sha256_file(path)
        assert actual == entry["sha256"], (
            f"{ref}: sha256 mismatch lock={entry['sha256']} disk={actual}"
        )


def test_resolve_footprint_rejects_tampered_file(tmp_path):
    """sha verification must fail closed if a seed file's bytes change."""
    lock = load_lockfile()
    ref = "MountingHole:MountingHole_3.2mm_M3"
    entry = lock[ref]

    # Build a shadow library with a tampered copy + the real lockfile.
    lib = tmp_path / "footprints"
    (lib / Path(entry["path"]).parent).mkdir(parents=True, exist_ok=True)
    src = DEFAULT_LIBRARY_ROOT / entry["path"]
    (lib / entry["path"]).write_text(
        src.read_text(encoding="utf-8") + "\n; tampered\n", encoding="utf-8"
    )

    with pytest.raises(footprints.FootprintLookupError):
        resolve_footprint(ref, library_root=lib, lockfile=DEFAULT_LOCKFILE)


def test_resolve_footprint_unknown_ref():
    with pytest.raises(footprints.FootprintLookupError):
        resolve_footprint("Nope:DoesNotExist")


def test_default_lockfile_and_library_exist():
    assert DEFAULT_LOCKFILE.exists(), DEFAULT_LOCKFILE
    assert DEFAULT_LIBRARY_ROOT.is_dir(), DEFAULT_LIBRARY_ROOT
