"""Ground-truth rotation + SMD pad-geometry tests (docket 019f3ba0f455).

The crux: KiCad's own placement of a rotated footprint's pads is the ground
truth for what ``rotation_deg`` MUST mean in the canonical board contract. We
read a real KiCad-authored file (tests/agent_router/fixtures/rotated_component
.kicad_pcb) with the agent_router KiCad reader (reused, not reimplemented — it
encodes KiCad's clockwise footprint-angle convention in
``kicad_io._transform_position``), build the equivalent canonical board dict, and
assert that BOTH fabrication paths land pads on KiCad's absolute pad positions
within 1µm:

  * gerber.py  — flashed D03 pad centres in the emitted F_Cu.gbr, and
  * kicad.py   — pads of the generated .kicad_pcb, read back through the reader.

This pins the sign of gerber._rotate against ground truth (the old +deg/CCW form
mirrored pads about the component centre) and guards kicad.py from silently using
a different sign than gerber.py.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

import pytest

from agent_router.kicad_io import read_kicad_pcb, _parse_footprints
from pcb_worker import gerber, kicad

HERE = Path(__file__).resolve().parent
ROTATED_FIXTURE = HERE / "agent_router" / "fixtures" / "rotated_component.kicad_pcb"

TOL_MM = 1e-3  # 1 micrometre


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _canonical_from_fixture() -> tuple[dict, dict[str, tuple[float, float]]]:
    """Build a canonical board dict for the fixture's component, plus the KiCad
    ground-truth absolute pad positions keyed by pad number.

    Component-LOCAL pad offsets come from the footprint definition (via the
    reused agent_router parser); ground-truth ABSOLUTE positions come from the
    reader's full transform (footprint pos + KiCad-convention rotation).
    """
    content = ROTATED_FIXTURE.read_text()
    fps = _parse_footprints(content)
    assert fps, "fixture has no footprints"
    fp = fps[0]
    fx, fy = fp["position"]
    rot = fp["rotation"]

    pins = []
    for pad in fp["pads"]:
        lx, ly = pad["position"]
        # Nominal inline pad size so the SMD lands flash — this test asserts pad
        # CENTRES only, and a sizeless SMD pad now fails closed (step 4a-ii).
        pins.append({"number": pad["number"], "x_mm": lx, "y_mm": ly,
                     "pad_width_mm": 1.0, "pad_height_mm": 1.0})

    comp = {
        "ref": fp.get("reference", "U1"),
        "footprint": fp.get("name", "unknown"),
        "x_mm": fx,
        "y_mm": fy,
        "rotation_deg": rot,
        "layer": "top",
        "pins": pins,
    }
    board = {
        "version": 1, "name": "rot", "width_mm": 100, "height_mm": 100,
        "components": [comp], "nets": [],
    }

    ground_truth = {p.number: (p.position[0], p.position[1])
                    for p in read_kicad_pcb(ROTATED_FIXTURE).pads}
    return board, ground_truth


def _gerber_flash_centres(gbr_text: str) -> list[tuple[float, float]]:
    """Extract D03 flash centres from a Gerber layer, honouring its self-declared
    %FSLAX_Y_*% coordinate format (do NOT assume 4.6)."""
    fs = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", gbr_text)
    assert fs, "no %FSLAX..Y..*% format spec in gerber"
    xd, yd = int(fs.group(2)), int(fs.group(4))
    centres = []
    for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D03\*", gbr_text):
        centres.append((int(xs) / 10 ** xd, int(ys) / 10 ** yd))
    return centres


def _match_within(got: list[tuple[float, float]],
                  expected: list[tuple[float, float]], tol: float) -> None:
    """Assert a 1:1 correspondence: every expected point has a distinct got point
    within *tol* (Euclidean, mm)."""
    assert len(got) == len(expected), f"count mismatch: {got} vs {expected}"
    remaining = list(got)
    for ex in expected:
        best = min(remaining, key=lambda g: math.hypot(g[0] - ex[0], g[1] - ex[1]))
        d = math.hypot(best[0] - ex[0], best[1] - ex[1])
        assert d <= tol, f"pad {ex} has no gerber flash within {tol}mm (nearest {best}, {d}mm)"
        remaining.remove(best)


# ---------------------------------------------------------------------------
# Sanity: the fixture really is rotated, and KiCad places pads as expected.
# ---------------------------------------------------------------------------


def test_fixture_is_rotated_ground_truth():
    board, ground_truth = _canonical_from_fixture()
    comp = board["components"][0]
    assert comp["rotation_deg"] == 90, "fixture component should be at 90 deg"
    # KiCad's clockwise convention: local (1,0) at 90deg -> (0,-1) from centre.
    # Fixture centre is (50,50) -> pad '1' at (50,49), pad '2' at (50,51).
    assert ground_truth["1"] == pytest.approx((50.0, 49.0), abs=TOL_MM)
    assert ground_truth["2"] == pytest.approx((50.0, 51.0), abs=TOL_MM)


# ---------------------------------------------------------------------------
# gerber.py pad centres == KiCad ground truth.
# ---------------------------------------------------------------------------


def test_gerber_pad_centres_match_kicad_ground_truth():
    board, ground_truth = _canonical_from_fixture()
    files = gerber.build_gerbers(board, name="rot")

    # SMD component on top -> flashes land on F_Cu.
    f_cu = files["rot-F_Cu.gbr"]
    centres = _gerber_flash_centres(f_cu)
    _match_within(centres, list(ground_truth.values()), TOL_MM)


# ---------------------------------------------------------------------------
# kicad.py output, round-tripped through the reader, == KiCad ground truth.
# (Catches kicad.py using a different rotation sign than gerber.py.)
# ---------------------------------------------------------------------------


def test_kicad_pcb_pad_positions_match_ground_truth(tmp_path):
    board, ground_truth = _canonical_from_fixture()
    pcb_text = kicad.generate_kicad_pcb(board)
    out = tmp_path / "rot.kicad_pcb"
    out.write_text(pcb_text)

    reloaded = read_kicad_pcb(out)
    got = {p.number: (p.position[0], p.position[1]) for p in reloaded.pads}
    assert set(got) == set(ground_truth)
    for num, exp in ground_truth.items():
        assert got[num] == pytest.approx(exp, abs=TOL_MM), \
            f"pad {num}: kicad.py placed {got[num]}, KiCad ground truth {exp}"


# ---------------------------------------------------------------------------
# SMD pad geometry: kicad.py must honour pad_width_mm / pad_height_mm.
# ---------------------------------------------------------------------------


def test_kicad_smd_pad_honours_declared_size():
    board = {
        "version": 1, "name": "smd", "width_mm": 10, "height_mm": 10,
        "components": [
            {"ref": "U1", "footprint": "QFN", "x_mm": 5, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -1, "y_mm": 0,
                       "pad_width_mm": 2.0, "pad_height_mm": 2.0}]},
        ],
        "nets": [],
    }
    pcb = kicad.generate_kicad_pcb(board)
    assert "(size 2.0 2.0)" in pcb, pcb


def test_kicad_smd_pad_without_size_fails_closed():
    """Step 4a-ii: the kicad emitter NO LONGER falls back to a 1x0.6 nominal for a
    sizeless SMD pad — it fails closed (PadGeometryError), same as gerber, rather
    than writing a placeholder land (bug 019f7736b236)."""
    from pcb_worker.pad_source import PadGeometryError
    board = {
        "version": 1, "name": "smd", "width_mm": 10, "height_mm": 10,
        "components": [
            {"ref": "U1", "footprint": "R", "x_mm": 5, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -0.5, "y_mm": 0}]},
        ],
        "nets": [],
    }
    with pytest.raises(PadGeometryError):
        kicad.generate_kicad_pcb(board)
