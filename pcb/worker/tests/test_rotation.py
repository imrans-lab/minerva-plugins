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
    """Assert got[i] lands within *tol* of expected[i], for every i — an
    ORDER-SENSITIVE (positional) check, deliberately NOT nearest-neighbour.

    Pad IDENTITY here comes from EMISSION INDEX, not from re-pairing points by
    proximity: gerber.py writes no per-pad X2 ``%TO.P`` attribute (see
    gerber.py's emitter), so the only way to know which D03 flash is which pad
    number is positional — pad k in the canonical board's ``pins`` list is the
    k-th flash `iter_pads` emits. A nearest-neighbour match (the previous form
    of this helper) treats the GOT/EXPECTED lists as unordered multisets, so it
    reports agreement for any permutation of the same position SET — including
    the exact mirrored-rotation defect this module exists to catch (see the
    docket-019f3ba0f455 note below). Positional comparison is only valid
    because callers first prove the emission-order == pin-order premise; see
    the assertion in test_gerber_pad_centres_match_kicad_ground_truth.
    """
    assert len(got) == len(expected), f"count mismatch: {got} vs {expected}"
    for i, (g, ex) in enumerate(zip(got, expected)):
        d = math.hypot(g[0] - ex[0], g[1] - ex[1])
        assert d <= tol, (
            f"flash #{i} (by emission index) at {g} is not within {tol}mm of "
            f"expected pad position {ex} (distance {d}mm) — positional identity "
            "assumed emission order still matches pin order; if that premise "
            "changed this failure is a false positive, re-verify it explicitly"
        )


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

    # PREMISE (must hold for the positional _match_within below to mean
    # anything): gerber.py carries no per-pad X2 identity attribute, so this
    # test's only handle on "which flash is pad N" is EMISSION INDEX — pad k of
    # the canonical `pins` list becomes the k-th D03 flash (pad_source.iter_pads
    # emits "in source order"). That is only a valid stand-in for pad identity
    # if the canonical pin order and the KiCad ground-truth key order are the
    # SAME sequence. Assert it explicitly, with a diagnostic message distinct
    # from a plain position mismatch, so a future reordering of either source
    # fails loudly here instead of masquerading as "pad in the wrong place".
    pin_order = [p["number"] for p in board["components"][0]["pins"]]
    ground_truth_order = list(ground_truth.keys())
    assert pin_order == ground_truth_order, (
        "emission order no longer matches pin order: this test pairs gerber "
        f"D03 flashes with KiCad ground truth BY INDEX, assuming canonical pin "
        f"order {pin_order} equals KiCad pad-read order {ground_truth_order} — "
        "they no longer match, so positional identity below would silently "
        "mispair pads (add a real per-pad X2 attribute instead of relying on "
        "this premise if that is now unavoidable)"
    )

    # The fixture pins carry no per-pad `rotation`, so the aperture angle still
    # comes from the component rotation_deg (the emitter only
    # overrides it when a pad carries its own absolute rotation) — this stays a
    # faithful check of gerber._rotate's sign against the KiCad ground truth.
    files = gerber.build_gerbers(board, name="rot")

    # SMD component on top -> flashes land on F_Cu.
    #
    # The ground truth is BOARD frame (KiCad's Y-DOWN file frame, which is what
    # the reader hands back); the emitted Gerber is Y-UP, so the expectation is
    # negated in Y — the same single conversion the emitter makes at
    # gerber._Geometry.to_gerber_frame (bug 019fa8011555). X is untouched, which
    # is what keeps this a real check of _rotate's SIGN: a mirrored rotation moves
    # x as well as y, so it cannot hide behind the frame conversion.
    f_cu = files["rot-F_Cu.gbr"]
    centres = _gerber_flash_centres(f_cu)
    expected = [(x, -y) for (x, y) in ground_truth.values()]
    _match_within(centres, expected, TOL_MM)


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


# ---------------------------------------------------------------------------
# PER-PAD IDENTITY on an ASYMMETRIC rotated footprint (docket 019f3ba0f455).
#
# WHY THIS EXISTS ALONGSIDE THE TESTS ABOVE. Triage 2026-07-25 re-introduced the
# original CCW defect (``geometry.rotate_local_offset`` -> ``math.radians(deg)``)
# in a throwaway copy of the tree and ran this module: all five tests above
# PASSED. They cannot see the defect, for two independent reasons —
#
#   1. ``rotated_component.kicad_pcb`` is a 2-pad 0603 whose lands sit at local
#      (+1,0) and (-1,0) — SYMMETRIC about the component origin. Mirroring the
#      rotation swaps the two pads but leaves the SET of absolute positions
#      unchanged, and ``_match_within`` matches by nearest neighbour, not by pad
#      number, so the swap is invisible.
#   2. ``test_kicad_pcb_pad_positions_match_ground_truth`` round-trips
#      kicad.py -> reader, and kicad.py writes footprint-LOCAL pad coordinates
#      plus ``(at cx cy rot)``. The reader re-applies the rotation itself, so
#      ``rotate_local_offset`` is never exercised on that path at all.
#
# This test closes both holes: an ASYMMETRIC 6-pad DIP whose pads are compared
# BY PAD NUMBER. Under the mirrored sign MIC1.4 moves 18.3mm (and lands at
# y=114.3 on a 110mm-tall board — the exact off-the-edge symptom in the docket).
#
# GROUND TRUTH PROVENANCE. The expected positions below are not derived from any
# Minerva code. They are KiCad 9.0.9's own placement, obtained by hand-authoring
# a .kicad_pcb containing the Package_DIP:DIP-6_W7.62mm_Socket pads copied
# VERBATIM from the shipped library .kicad_mod at ``(at 40.64 106.68 90)``, then
# reading the pad centres back out of ``kicad-cli pcb export gerbers`` X2
# ``%TO.P,MIC1,<n>*%`` records. Values below are exact, but SORTED by pad number
# for legibility — kicad-cli emits them in aperture-declaration order (1, 4, 2,
# 5, 3, 6), so this block is a re-ordering of that output, not a verbatim paste:
#
#   %TO.P,MIC1,1*%  X40640000Y-106680000D03*
#   %TO.P,MIC1,2*%  X43180000Y-106680000D03*
#   %TO.P,MIC1,3*%  X45720000Y-106680000D03*
#   %TO.P,MIC1,4*%  X45720000Y-99060000D03*
#   %TO.P,MIC1,5*%  X43180000Y-99060000D03*
#   %TO.P,MIC1,6*%  X40640000Y-99060000D03*
#
# Gerber Y is negated w.r.t. the .kicad_pcb frame, and that is the CONVENTION,
# not an oddity of this capture: the .kicad_pcb file frame grows Y DOWNWARD while
# Gerber is Y-UP, so any correct exporter negates. This note used to read as a
# passing observation, which is part of why our own emitter shipped for months
# WITHOUT that negation — the divergence had been seen and filed as benign (bug
# 019fa8011555). pcb_worker now converts at exactly one place,
# gerber._Geometry.to_gerber_frame, and matches the bytes above.
#
# The ground truth below is stated in the BOARD frame (as the reader returns it),
# so a test comparing it against emitted Gerber must negate Y. The test itself is
# hermetic — it does NOT shell out to kicad-cli.
# ---------------------------------------------------------------------------

SMART_REMOTE = HERE / "testdata" / "smart_remote.yaml"

# MIC1: Package_DIP:DIP-6_W7.62mm_Socket at (40.64, 106.68), rotation_deg 90, top.
MIC1_KICAD_GROUND_TRUTH = {
    "1": (40.64, 106.68),
    "2": (43.18, 106.68),
    "3": (45.72, 106.68),
    "4": (45.72, 99.06),
    "5": (43.18, 99.06),
    "6": (40.64, 99.06),
}


def test_rotated_dip6_pads_match_kicad_placement_by_pad_number():
    """Every pad of a 90deg-rotated ASYMMETRIC DIP must land on KiCad's own
    absolute position for that SPECIFIC pad number (docket 019f3ba0f455)."""
    import yaml

    from pcb_worker.compile_board import compile_board
    from pcb_worker.resolved_board import ResolutionSuccess

    result = compile_board(yaml.safe_load(SMART_REMOTE.read_text(encoding="utf-8")))
    assert isinstance(result, ResolutionSuccess), \
        [d.message for d in result.diagnostics if d.severity.value == "error"][:5]

    mic1 = next(c for c in result.board.components if c.ref == "MIC1")
    assert mic1.placement.rotation_deg == 90.0, "fixture MIC1 must stay at 90deg"

    got = {p.source_id.split(":")[1]: (p.position[0], p.position[1])
           for p in mic1.placed_pads}
    assert set(got) == set(MIC1_KICAD_GROUND_TRUTH)

    for num, expected in sorted(MIC1_KICAD_GROUND_TRUTH.items()):
        assert got[num] == pytest.approx(expected, abs=TOL_MM), (
            f"MIC1 pad {num}: worker placed {got[num]}, KiCad 9.0.9 ground truth "
            f"{expected} — rotation convention mirrored?"
        )
