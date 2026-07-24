"""W8.1 — the IR-native GERBER fab path (``gerber.build_gerbers_ir``).

These are the W8.1 wins: emitting straight from the ResolvedBoard IR makes the
three things the LEGACY (resolve_board_best_effort) fab path drops reach the
gerber/Excellon fabrication BYTES —

  1. board-ABSOLUTE pad placement (not the emitter re-applying local geometry);
  2. a pin ``override`` (drill / annulus) — ignored by the legacy path;
  3. the bottom-side MIRROR (side + Y-fold) — the legacy path never mirrors;
  4. per-pad ROTATION — dropped by the legacy path.

Each is proven by parsing the emitted gerber/Excellon, plus emission purity /
determinism and a legacy-path-unchanged guard.

The pipeline under test:

    compile_board(source).board  ->  gerber.build_gerbers_ir(rb)
"""

from __future__ import annotations

import copy
import re

import pytest

from agent_router.kicad_io import read_kicad_pcb
from pcb_worker import gerber, kicad
from pcb_worker.compile_board import compile_board
from pcb_worker.geometry import place_point
from pcb_worker.kicad import _kicad_mounting_hole_component
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    HoleKind,
    OvalHole,
    ResolutionSuccess,
    ResolvedHole,
)

try:  # dev/CI-only kicad-cli DRC oracle (skips cleanly when absent).
    from tests.oracle.kicad_drc import kicad_cli_available, run_drc_on_pcb_text
except Exception:  # pragma: no cover - oracle package optional
    kicad_cli_available = lambda: False  # noqa: E731
    run_drc_on_pcb_text = None


# ---------------------------------------------------------------------------
# Board builders (mirror the SB1 helpers in test_compile_board.py).
# ---------------------------------------------------------------------------


def _board(fp: str, *, layer: str = "top", x: float = 10.0, y: float = 10.0,
           rotation_deg: float = 0.0, pins=None) -> dict:
    comp = {"ref": "X1", "footprint": fp, "x_mm": x, "y_mm": y,
            "rotation_deg": rotation_deg, "layer": layer}
    if pins is not None:
        comp["pins"] = pins
    return {
        "version": 1, "name": "brd", "width_mm": 40, "height_mm": 40,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [comp],
    }


def _resolve(board: dict):
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), [
        d.code for d in result.diagnostics if d.severity is DiagnosticSeverity.ERROR]
    return result.board


def _placed_gerbers(board: dict, name: str = "brd"):
    return gerber.build_gerbers_ir(_resolve(board), name=name)


# ---------------------------------------------------------------------------
# Gerber / Excellon parse helpers.
# ---------------------------------------------------------------------------


def _decimals(text: str) -> int:
    """Decimal digit count from the self-declared ``%FSLAX_Y_*%`` coordinate format."""
    m = re.search(r"%FSLAX\d(\d)Y\d\d", text)
    assert m, "no %FS coordinate-format line"
    return int(m.group(1))


def _flashes(text: str) -> list[tuple[float, float]]:
    """(x_mm, y_mm) of every D03 flash in a gerber layer."""
    d = _decimals(text)
    return [(int(x) / 10 ** d, int(y) / 10 ** d)
            for x, y in re.findall(r"X(-?\d+)Y(-?\d+)D03\*", text)]


def _flash_count(text: str) -> int:
    return text.count("D03*")


def _apertures(text: str) -> set[str]:
    return set(re.findall(r"%ADD\d+(.*?)\*%", text))


def _excellon_tools(text: str) -> set[str]:
    return set(re.findall(r"T\d+C([\d.]+)", text))


def _excellon_ys(text: str) -> set[float]:
    return {float(y) for _x, y in re.findall(r"X([\d.]+)Y([\d.]+)", text)}


def _near(points, target, tol: float = 1e-3) -> bool:
    return any(abs(px - target[0]) < tol and abs(py - target[1]) < tol
              for px, py in points)


# ---------------------------------------------------------------------------
# WIN 1 — board-ABSOLUTE placement reaches copper.
# ---------------------------------------------------------------------------


def test_absolute_position_reaches_copper():
    """An R_0805 placed at board (10, 10) flashes its copper at the ABSOLUTE pad
    coordinate, NOT the footprint-local one (~±0.95 about the origin)."""
    files = _placed_gerbers(_board("R_0805", x=10.0, y=10.0))
    flashes = _flashes(files["brd-F_Cu.gbr"])
    assert _near(flashes, (9.05, 10.0)) and _near(flashes, (10.95, 10.0)), flashes
    # Never the raw local coords (would mean the emitter re-placed instead of
    # passing the IR's absolute geometry through under identity placement).
    assert not _near(flashes, (-0.95, 0.0)) and not _near(flashes, (0.95, 0.0))


# ---------------------------------------------------------------------------
# WIN 2 — a pin `override` reaches the fab bytes (the W8 core win).
# ---------------------------------------------------------------------------


def test_override_drill_reaches_excellon():
    """A pin `override` of ``drill_mm`` reaches the Excellon PTH tool table — the
    legacy path ignores pin overrides, so this is the geometry the IR unlocks."""
    baseline = _placed_gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket"))
    assert _excellon_tools(baseline["brd-PTH.drl"]) == {"0.800"}  # footprint drill

    overridden = _placed_gerbers(_board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"drill_mm": 1.3}}]))
    tools = _excellon_tools(overridden["brd-PTH.drl"])
    assert "1.300" in tools, tools           # the OVERRIDDEN pin-1 hole
    assert "0.800" in tools                  # the other five pins keep the footprint drill


def test_override_annulus_reaches_copper():
    """A pin `override` of ``annulus_diameter_mm`` reaches the F.Cu copper annulus.
    A resolved TH pad's copper width doubles as its annulus, so the override lands
    as a new circular aperture diameter."""
    files = _placed_gerbers(_board(
        "Package_DIP:DIP-6_W7.62mm_Socket",
        pins=[{"number": "1", "override": {"annulus_diameter_mm": 3.0}}]))
    apertures = _apertures(files["brd-F_Cu.gbr"])
    assert "C,3.0" in apertures, apertures   # the OVERRIDDEN pin-1 annulus
    assert "C,1.6" in apertures              # the other pins keep the footprint annulus


# ---------------------------------------------------------------------------
# WIN 3 — the bottom-side MIRROR reaches the fab (the folded W5).
# ---------------------------------------------------------------------------


def test_bottom_side_component_lands_on_back_copper():
    """A bottom-side SMD component emits its copper on B.Cu (and nothing on F.Cu);
    a top placement of the same footprint is the exact reverse. The legacy path
    never mirrors sides."""
    top = _placed_gerbers(_board("EVP-ASAC1A:SW_EVP-ASAC1A", layer="top"))
    bot = _placed_gerbers(_board("EVP-ASAC1A:SW_EVP-ASAC1A", layer="bottom"))

    assert _flash_count(top["brd-F_Cu.gbr"]) > 0
    assert _flash_count(top["brd-B_Cu.gbr"]) == 0
    assert _flash_count(bot["brd-F_Cu.gbr"]) == 0
    assert _flash_count(bot["brd-B_Cu.gbr"]) > 0


def test_bottom_side_mirror_folds_the_coordinate():
    """The bottom placement Y-mirrors each pad about the component origin (the
    PlacementTransform fold). A DIP-6 (Y-asymmetric pads) placed at y=10 emits its
    drill hits at the mirror {20 - y} of the top placement's."""
    top = _placed_gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket", layer="top"))
    bot = _placed_gerbers(_board("Package_DIP:DIP-6_W7.62mm_Socket", layer="bottom"))

    top_ys = _excellon_ys(top["brd-PTH.drl"])
    bot_ys = _excellon_ys(bot["brd-PTH.drl"])
    assert top_ys == {10.0, 12.54, 15.08}, top_ys
    assert bot_ys == {round(20.0 - y, 3) for y in top_ys}, bot_ys
    assert bot_ys != top_ys  # a genuine fold, not a no-op


# ---------------------------------------------------------------------------
# WIN 4 — per-pad ROTATION reaches the aperture (Codex 2b).
# ---------------------------------------------------------------------------


def test_per_pad_rotation_reaches_the_aperture():
    """An R_0805 placed at rotation 90 bakes a per-pad absolute rotation into the
    IR; the IR-native gerber emitter sources the aperture rotation from the pad's
    own absolute angle, so a rotation-carrying aperture macro reaches fab (the
    legacy bug this phase closed dropped it)."""
    placed = gerber.build_gerbers_ir(
        _resolve(_board("R_0805", rotation_deg=90)), name="brd")["brd-F_Cu.gbr"]
    assert "%AMRectangle*" in placed                        # a rotation-carrying macro
    assert re.search(r"Rectangle,[\d.X]+X90", placed), _apertures(placed)


# ---------------------------------------------------------------------------
# Gerber emission purity + determinism.
# ---------------------------------------------------------------------------


def test_gerber_ir_emit_does_not_mutate_the_resolved_board():
    board = _resolve(_board("Package_DIP:DIP-6_W7.62mm_Socket",
                            pins=[{"number": "1", "override": {"drill_mm": 1.3}}]))
    before = copy.deepcopy(board)
    gerber.build_gerbers_ir(board, name="brd")
    assert board == before  # frozen dataclasses; the emitter only reads


def test_gerber_ir_emit_is_deterministic():
    board = _resolve(_board("EVP-ASAC1A:SW_EVP-ASAC1A"))
    assert dict(gerber.build_gerbers_ir(board, name="brd")) == \
        dict(gerber.build_gerbers_ir(board, name="brd"))


def test_gerber_ir_carries_absolute_geometry_and_frame():
    """Shape smoke on the EMITTED gerber: the board frame lands on Edge.Cuts, the
    ABSOLUTE pad copper flashes (not the footprint-local coord), and R_0805's
    F.SilkS graphics reach the silk layer."""
    files = gerber.build_gerbers_ir(_resolve(_board("R_0805")), name="brd")
    # Board frame (40x40 at origin 0,0) drawn on Edge.Cuts.
    edge = files["brd-Edge_Cuts.gbr"]
    assert "%MOMM*%" in edge
    corners = set(re.findall(r"X(-?\d+)Y(-?\d+)D0[12]\*", edge))
    d = _decimals(edge)
    got = {(int(x) / 10 ** d, int(y) / 10 ** d) for x, y in corners}
    assert {(0.0, 0.0), (40.0, 0.0), (40.0, 40.0), (0.0, 40.0)} <= got, got
    # ABSOLUTE pad copper (9.05,10.0), never the footprint-local coord.
    flashes = _flashes(files["brd-F_Cu.gbr"])
    assert _near(flashes, (9.05, 10.0)), flashes
    assert not _near(flashes, (-0.95, 0.0))
    # R_0805 carries F.SilkS graphics — they reach the silk layer.
    assert files["brd-F_SilkS.gbr"].count("D01*") > 0


# ===========================================================================
# W8.1b — the IR-native KICAD fab path (``kicad.generate_ir``).
#
# GROUND TRUTH (pcbnew 9.0.9): KiCad applies TRANSLATE + ROTATE ONLY on load (no
# native footprint flip), and the pad ``(at px py ANGLE)`` third value is the
# ABSOLUTE angle. So the bridge emits each footprint at its REAL placement
# ``(at px py rot)`` with pad POSITIONS in footprint-LOCAL coords but the pad ANGLE
# absolute (finding 019f8dbb6593): overrides, per-pad rotation, and the bottom
# mirror are baked into each PlacedPad, and KiCad's load translate+rotate
# reconstructs the identical absolute geometry (placement/editability preserved).
#
# These wins are proven by a REAL ROUND-TRIP ORACLE — the emitted .kicad_pcb is
# parsed back through KiCad's load transform (agent_router.kicad_io.read_kicad_pcb,
# translate+rotate, the SAME reader test_rotation.py trusts as ground truth) and
# every pad's PARSED absolute position, absolute angle, and copper layer is checked
# against the IR truth (PlacedPad.position / rotation_deg / side). Plain-text
# assertions MISSED the mirror + fp-relative-angle bugs; the parse-back catches
# them because a mis-mirrored/local-rotated pad lands at the WRONG absolute spot.
# The external kicad-cli DRC is the independent second oracle.
#
#   compile_board(src).board -> kicad.generate_ir -> parse
# ===========================================================================


def _emit_kicad(board: dict, name: str = "brd") -> str:
    """Compile + emit the .kicad_pcb text for a raw board dict."""
    return kicad.generate_ir(_resolve(board), base_name=name)[
        f"{name}.kicad_pcb"]


def _export_drills(pcb_text: str, tmp_path, name: str = "brd") -> tuple[str, str]:
    """Round-trip the emitted board through KiCad's OWN drill exporter (the
    independent oracle) and return the (NPTH.drl, PTH.drl) Excellon text — the
    plating-split KiCad itself computes. read_kicad_pcb drops empty-number mounting
    pads, so the drill export is the parse-back that actually sees them."""
    import subprocess

    src = tmp_path / f"{name}.kicad_pcb"
    src.write_text(pcb_text, encoding="utf-8")
    outd = tmp_path / "drl"
    outd.mkdir(exist_ok=True)
    proc = subprocess.run(
        ["kicad-cli", "pcb", "export", "drill", "--format", "excellon",
         "--excellon-separate-th", "-o", f"{outd}/", str(src)],
        capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    npth = (outd / f"{name}-NPTH.drl")
    pth = (outd / f"{name}-PTH.drl")
    return (npth.read_text() if npth.exists() else "",
            pth.read_text() if pth.exists() else "")


def _drill_hits(excellon: str) -> list[tuple[str, float, float]]:
    """[(tool_diameter, x, y), ...] for every drilled coordinate in an Excellon
    file — the tool the coordinate is under (KiCad emits X/Y in mm)."""
    tool_dia: dict[str, str] = dict(re.findall(r"(T\d+)C([\d.]+)", excellon))
    hits: list[tuple[str, float, float]] = []
    current = None
    for line in excellon.splitlines():
        tm = re.fullmatch(r"(T\d+)", line.strip())
        if tm:
            current = tm.group(1)
            continue
        cm = re.match(r"X(-?[\d.]+)Y(-?[\d.]+)", line.strip())
        if cm and current in tool_dia:
            hits.append((tool_dia[current], float(cm.group(1)), float(cm.group(2))))
    return hits


def _ir_pad_truth(resolved) -> dict:
    """``{ 'REF.NUMBER': (abs_position, abs_rotation_deg, Side) }`` — the IR's
    board-absolute ground truth for every placed pad, joined to its footprint pad
    NUMBER by source_id (the same join the emitted ``REF.NUMBER`` uses)."""
    truth: dict = {}
    for comp in resolved.components:
        number_of = {p.source_id: p.number for p in resolved.footprint_for(comp).pads}
        for pad in comp.placed_pads:
            truth[f"{comp.ref}.{number_of[pad.source_id]}"] = (
                pad.position, pad.rotation_deg, pad.side)
    return truth


def _roundtrip_pads(pcb_text: str, tmp_path) -> dict:
    """Parse the emitted board back through KiCad's load transform (translate +
    rotate, NO flip — real KiCad behavior) and return ``{'REF.NUMBER': Pad}``."""
    path = tmp_path / "rt.kicad_pcb"
    path.write_text(pcb_text, encoding="utf-8")
    board = read_kicad_pcb(str(path))
    return {f"{p.component}.{p.number}": p for p in board.pads}


def _assert_pads_roundtrip(board: dict, tmp_path, *, name: str = "brd") -> None:
    """The core oracle: under the REAL-placement encoding, every pad's reconstructed
    absolute POSITION + copper LAYER matches the IR truth, and the emitted pad
    ``(at)`` ANGLE is the IR's absolute angle. Catches the mirror bug (wrong
    position / wrong side) AND a dropped/mangled pad angle.

    POSITION + LAYER come from ``read_kicad_pcb`` applying KiCad's real translate +
    rotate (verified vs the pcbnew k1_bottom oracle). The ANGLE is asserted on the
    emitted ``(at)`` value: KiCad reads a placed pad's ``(at)`` third value as the
    ABSOLUTE board angle (pinned by the k1_bottom oracle), so the emitted absolute
    angle is the faithful check. (read_kicad_pcb DOUBLES it — adds the footprint
    rotation to the already-absolute stored angle; agent_router bug, filed — so its
    ``.rotation`` is not used here. End-to-end angle correctness is covered by the
    kicad-cli DRC oracle in tests/oracle.)"""
    resolved = _resolve(board)
    d = kicad._ir_board_dict(resolved)
    pcb = kicad.generate(d, base_name=name)[f"{name}.kicad_pcb"]
    parsed = _roundtrip_pads(pcb, tmp_path)
    truth = _ir_pad_truth(resolved)
    emitted_angle = {f"{c['ref']}.{p['number']}": p.get("rotation", 0.0)
                     for c in d["components"] for p in c["pads"]}
    assert set(parsed) == set(truth), (set(truth) - set(parsed), set(parsed) - set(truth))
    for key, (pos, rot, side) in truth.items():
        p = parsed[key]
        assert abs(p.position[0] - pos[0]) < 1e-3 and abs(p.position[1] - pos[1]) < 1e-3, (
            f"{key}: parsed pos {p.position} != IR {pos}")
        assert abs(((emitted_angle[key] - rot + 180) % 360) - 180) < 1e-3, (
            f"{key}: emitted pad (at) angle {emitted_angle[key]} != IR absolute {rot}")
        if p.pad_type == "smd":
            want = "B.Cu" if side.value == "bottom" else "F.Cu"
            assert p.layer == want, f"{key}: parsed layer {p.layer} != {want} (side {side.value})"
        else:
            assert p.layer == "*.Cu", f"{key}: TH pad layer {p.layer} != *.Cu"
    # And the pad angles must reach the emitted .kicad_pcb BYTES as the IR absolute
    # angle (KiCad reads the pad (at) third value as absolute; _pad_at omits it when
    # 0). Multiset over the text so an emitter drop/mangle is caught, not just the
    # adapter dict (these boards carry no mounting holes, so every pad is a component
    # pad in `truth`).
    text_angles = sorted(
        round(float(m.group(1)) if m.group(1) else 0.0, 3) % 360
        for m in re.finditer(
            r'\(pad "[^"]*"[^(]*\(at [-\d.eE]+ [-\d.eE]+(?: ([-\d.eE]+))?\)', pcb))
    truth_angles = sorted(round(rot, 3) % 360 for (_, rot, _) in truth.values())
    assert text_angles == truth_angles, (text_angles, truth_angles)


# ---------------------------------------------------------------------------
# WIN 1 — a component at non-zero rotation with a rotated pad: ABSOLUTE angle.
# ---------------------------------------------------------------------------


def test_kicad_component_rotation_roundtrips_absolute(tmp_path):
    """An R_0805 at component rotation 90: each pad round-trips to its IR-absolute
    position AND absolute angle. The bug this kills: feeding a footprint-relative
    angle would parse WRONG (KiCad reads the pad `(at)` third value as absolute)."""
    _assert_pads_roundtrip(_board("R_0805", x=30.0, y=30.0, rotation_deg=90.0), tmp_path)


def test_kicad_pad_local_rotation_roundtrips_absolute(tmp_path):
    """ESP32-S3-DevKitC has pads at LOCAL rotation 270; at component rotation 0 the
    IR combined angle is 270. The emitted pad `(at)` carries 270 and round-trips to
    270 — proving per-pad rotation reaches the .kicad_pcb (Codex 2b) as the ABSOLUTE
    angle, not a dropped or fp-relative value."""
    _assert_pads_roundtrip(
        _board("Espressif:ESP32-S3-DevKitC", x=40.0, y=50.0), tmp_path)
    # And the emitted angle is literally the IR combined angle on the pad (at).
    resolved = _resolve(_board("Espressif:ESP32-S3-DevKitC", x=40.0, y=50.0))
    d = kicad._ir_board_dict(resolved)
    assert d["components"][0]["rotation_deg"] == 0.0  # real placement, authored comp rot 0
    assert all(p.get("rotation") == 270.0 for p in d["components"][0]["pads"])


# ---------------------------------------------------------------------------
# WIN 2 — a BOTTOM asymmetric component: the mirror is in the COORDINATE, and
# there is NO double-mirror (the earlier y=0 test could not see a swap).
# ---------------------------------------------------------------------------


def test_kicad_bottom_asymmetric_component_roundtrips_mirrored(tmp_path):
    """A BOTTOM DIP-6 (pads NOT at y=0, so a mirror error is detectable): every pin
    round-trips to the IR's mirror-folded absolute position. The bug this kills:
    emitting a `(layer B.Cu)` footprint with LOCAL un-mirrored pads is NOT flipped
    on load, so pins 2/3 would swap onto the wrong nets. Here the coordinate is
    pre-mirrored under an identity footprint, so it lands right — no double-mirror."""
    _assert_pads_roundtrip(
        _board("Package_DIP:DIP-6_W7.62mm_Socket", layer="bottom", x=40.0, y=40.0),
        tmp_path)


def test_kicad_bottom_placement_is_real_with_local_pads(tmp_path):
    """A BOTTOM DIP-6 is emitted at its REAL placement (40, 40, 0 / bottom) with
    footprint-LOCAL pad coords, and reconstructing each local pad through the
    placement transform recovers the IR's absolute mirror-folded truth. Kills two
    bugs at once: the identity encoding that put every footprint at 0,0,0 and lost
    component placement / CPL (finding 019f8dbb6593), and the earlier
    component-relative encoding whose un-mirrored pads landed on the wrong nets."""
    resolved = _resolve(_board("Package_DIP:DIP-6_W7.62mm_Socket", layer="bottom",
                               x=40.0, y=40.0))
    d = kicad._ir_board_dict(resolved)
    comp = d["components"][0]
    assert (comp["x_mm"], comp["y_mm"], comp["rotation_deg"]) == (40.0, 40.0, 0.0)
    assert comp["layer"] == "bottom"
    truth = {(round(p.position[0], 3), round(p.position[1], 3))
             for p in resolved.components[0].placed_pads}
    recon = {
        tuple(round(v, 3) for v in place_point(40.0, 40.0, 0.0,
                                               p["position"]["x"], p["position"]["y"]))
        for p in comp["pads"]
    }
    assert recon == truth, (recon, truth)


def test_kicad_bottom_smd_pad_is_layer_consistent(tmp_path):
    """A BOTTOM SMD component: copper AND paste/mask land on the SAME (back) side.
    Round-trip confirms B.Cu copper; the DRC oracle (below) confirms the padstack
    is no longer 'copper and mask on different sides' (the pre-existing bug the
    absolute-identity + side-derived tech layers fix)."""
    _assert_pads_roundtrip(
        _board("EVP-ASAC1A:SW_EVP-ASAC1A", layer="bottom", x=50.0, y=50.0,
               ), tmp_path)


# ---------------------------------------------------------------------------
# WIN 3 — a pin `override` reaches the emitted pad geometry.
# ---------------------------------------------------------------------------


def test_kicad_override_reaches_pad_geometry(tmp_path):
    """A pin `override` (drill + annulus) reaches the emitted through-hole pad while
    the other pins keep the footprint geometry — the legacy kicad path drops
    overrides. Asserted on the emitted pad dict AND round-tripped for position."""
    board = _board("Package_DIP:DIP-6_W7.62mm_Socket",
                   pins=[{"number": "1", "override": {"drill_mm": 1.3,
                                                      "annulus_diameter_mm": 3.0}}])
    pcb = _emit_kicad(board)
    fp = pcb[pcb.index('(footprint "DIP-6'):]
    fp = fp[:fp.index("\n  )")]

    def pad_line(num):
        return next(l for l in fp.splitlines() if l.lstrip().startswith(f'(pad "{num}"'))

    assert "(drill 1.3)" in pad_line("1") and "(size 3.0 3.0)" in pad_line("1")
    assert "(drill 0.8)" in pad_line("2") and "(size 1.6 1.6)" in pad_line("2")
    _assert_pads_roundtrip(board, tmp_path)


# ---------------------------------------------------------------------------
# WIN 4 — the emitted board parses + DRCs clean (independent KiCad-engine oracle).
# ---------------------------------------------------------------------------


@pytest.mark.skipif(not kicad_cli_available(),
                    reason="kicad-cli not on PATH (dev/CI-only oracle)")
@pytest.mark.parametrize("board", [
    {"footprint": "R_0805", "layer": "top", "rotation_deg": 90.0},        # rotation
    {"footprint": "Package_DIP:DIP-6_W7.62mm_Socket", "layer": "bottom"},  # bottom TH mirror
    {"footprint": "EVP-ASAC1A:SW_EVP-ASAC1A", "layer": "bottom"},          # bottom SMD layers
])
def test_kicad_emitted_board_is_drc_clean(board):
    """Each geometry class (rotation / bottom mirror / bottom SMD) DRCs clean under
    the external kicad-cli — the independent second oracle that the emission is
    valid KiCad, on a board large enough that edge clearance is not at issue."""
    raw = {"version": 1, "name": "brd", "width_mm": 100, "height_mm": 100,
           "layers": ["top", "bottom"],
           "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                            "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
           "components": [{"ref": "X1", "footprint": board["footprint"],
                           "x_mm": 50.0, "y_mm": 50.0,
                           "rotation_deg": board.get("rotation_deg", 0.0),
                           "layer": board["layer"]}]}
    pcb = kicad.generate_ir(_resolve(raw), base_name="brd")[
        "brd.kicad_pcb"]
    result = run_drc_on_pcb_text(pcb, name="brd")
    assert result.clean, (result.violations, result.unconnected_items)


# ---------------------------------------------------------------------------
# Direct kicad.py emission unit-checks (targeted, no IR).
# ---------------------------------------------------------------------------


def test_kicad_footprint_emits_absolute_rotation_only_when_present():
    """kicad._footprint's pad `(at)` gains a third value ONLY for a pad carrying a
    non-zero `rotation`; a pad with no/zero rotation stays `(at px py)` — the
    backward-compat seal that keeps the legacy resolve goldens byte-identical."""
    def comp(rot):
        pad = {"number": "1", "type": "smd", "shape": "rect",
               "position": {"x": 0.5, "y": -0.5}, "size": {"width": 1.0, "height": 0.6},
               "drill": {"x": 0.0, "y": 0.0}, "layers": ["F.Cu"]}
        if rot is not None:
            pad["rotation"] = rot
        return {"version": 1, "name": "b", "width_mm": 10, "height_mm": 10,
                "components": [{"ref": "U1", "footprint": "FP", "x_mm": 5, "y_mm": 5,
                                "rotation_deg": 0, "layer": "top", "pads": [pad]}]}

    assert re.search(r'\(pad "1" smd rect \(at 0.5 -0.5 45(\.0)?\)',
                     kicad.generate_kicad_pcb(comp(45))), "rotated pad missing angle"
    assert '(pad "1" smd rect (at 0.5 -0.5)' in kicad.generate_kicad_pcb(comp(None))
    assert '(pad "1" smd rect (at 0.5 -0.5)' in kicad.generate_kicad_pcb(comp(0.0))


def test_kicad_smd_tech_layers_follow_copper_side():
    """A BOTTOM SMD pad emits paste/mask on the BACK (B.Paste/B.Mask), a FRONT pad
    on F.* — the side-consistency fix. A front pad is byte-identical to before."""
    def one(layer):
        pad = {"number": "1", "type": "smd", "shape": "rect",
               "position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.0, "height": 0.6},
               "drill": {"x": 0.0, "y": 0.0}, "layers": ["F.Cu"]}
        return kicad.generate_kicad_pcb({
            "version": 1, "name": "b", "width_mm": 10, "height_mm": 10,
            "components": [{"ref": "U1", "footprint": "FP", "x_mm": 5, "y_mm": 5,
                            "rotation_deg": 0, "layer": layer, "pads": [pad]}]})

    assert '(layers "F.Cu" "F.Paste" "F.Mask")' in one("top")
    assert '(layers "B.Cu" "B.Paste" "B.Mask")' in one("bottom")


# ---------------------------------------------------------------------------
# Fail-closed seals + adapter purity/determinism.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# W8.2b — the kicad bridge now EMITS board-level mounting holes faithfully
# (owner decision): each round ResolvedHole becomes a synthetic MountingHole
# footprint with one bare drilled pad at its ABSOLUTE position — np_thru_hole
# (no copper) when unplated, thru_hole (copper annulus) when plated. Proven by
# the kicad-cli drill-export oracle (position + drill diameter + NPTH/PTH plating
# split) and a DRC-clean check; a non-round hole still RAISES (round-only seal).
# ---------------------------------------------------------------------------


def test_kicad_adapter_emits_mounting_hole_component():
    """A board-level (NPTH) mounting hole projects to a synthetic MountingHole
    component at the hole's REAL position carrying ONE np_thru_hole pad at
    footprint-LOCAL origin — empty pad number, size == drill (no copper),
    *.Cu/*.Mask, no net."""
    board = _board("R_0805")
    board["mounting_holes"] = [{"x_mm": 2.0, "y_mm": 7.0, "diameter_mm": 3.2}]
    resolved = _resolve(board)
    assert resolved.holes  # the compiler captured the hole
    d = kicad._ir_board_dict(resolved)
    mh = [c for c in d["components"] if c["footprint"] == "MountingHole"]
    assert len(mh) == 1
    (pad,) = mh[0]["pads"]
    assert pad["number"] == ""
    assert pad["type"] == "np_thru_hole"
    assert pad["shape"] == "circle"
    assert pad["position"] == {"x": 0.0, "y": 0.0}     # footprint-LOCAL origin
    assert pad["drill"] == {"x": 3.2, "y": 3.2}
    assert pad["size"] == {"width": 3.2, "height": 3.2}  # size == drill (no copper)
    assert pad["layers"] == ["*.Cu", "*.Mask"]
    # Real placement: the footprint sits on the drill (finding 019f8dbb6593).
    assert (mh[0]["x_mm"], mh[0]["y_mm"], mh[0]["rotation_deg"]) == (2.0, 7.0, 0.0)


def test_kicad_adapter_plated_mounting_hole_is_thru_hole():
    """A PLATED (PTH) board hole projects to a thru_hole pad whose copper size is the
    hole's AUTHORED annulus (finding 019f8dbb7104) — NOT an invented 2x-drill nominal
    — and the footprint sits at the hole's real position."""
    board = _board("R_0805")
    board["pth_holes"] = [{"x_mm": 3.0, "y_mm": 4.0, "diameter_mm": 2.0, "annulus_mm": 3.0}]
    resolved = _resolve(board)
    d = kicad._ir_board_dict(resolved)
    (mh,) = [c for c in d["components"] if c["footprint"] == "MountingHole"]
    (pad,) = mh["pads"]
    assert pad["type"] == "thru_hole"
    assert pad["position"] == {"x": 0.0, "y": 0.0}          # footprint-LOCAL origin
    assert (mh["x_mm"], mh["y_mm"]) == (3.0, 4.0)           # footprint at the hole
    assert pad["drill"] == {"x": 2.0, "y": 2.0}
    assert pad["size"] == {"width": 3.0, "height": 3.0}     # the AUTHORED annulus


def test_kicad_adapter_mounting_holes_are_ordered_and_multiple():
    """Every board hole is emitted, in board.holes order (deterministic), with
    non-colliding H-refs."""
    board = _board("R_0805")
    board["mounting_holes"] = [
        {"x_mm": 2.0, "y_mm": 2.0, "diameter_mm": 3.2},
        {"x_mm": 8.0, "y_mm": 8.0, "diameter_mm": 3.2},
    ]
    d = kicad._ir_board_dict(_resolve(board))
    mh = [c for c in d["components"] if c["footprint"] == "MountingHole"]
    assert [c["ref"] for c in mh] == ["H1", "H2"]
    # Each MountingHole footprint sits at its hole; the pad is at local origin.
    assert [(c["x_mm"], c["y_mm"]) for c in mh] == [(2.0, 2.0), (8.0, 8.0)]
    assert all(c["pads"][0]["position"] == {"x": 0.0, "y": 0.0} for c in mh)


def _th_comp(pad: dict) -> dict:
    """A minimal single-pad component for driving kicad._footprint directly."""
    return {"ref": "H1", "value": "", "footprint": "MountingHole",
            "x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0, "layer": "top",
            "pads": [pad], "graphics": []}


def test_kicad_footprint_non_plated_th_emits_np_thru_hole():
    """UNIT: a non-plated through-hole pad emits `np_thru_hole` with size == drill
    (no copper annulus) on *.Cu/*.Mask and NO net."""
    pad = {"number": "", "type": "np_thru_hole", "shape": "circle",
           "position": {"x": 5.0, "y": 6.0}, "size": {"width": 3.2, "height": 3.2},
           "drill": {"x": 3.2, "y": 3.2}, "layers": ["*.Cu", "*.Mask"]}
    fp = kicad._footprint(_th_comp(pad), {}, {})
    assert ('(pad "" np_thru_hole circle (at 5.0 6.0) (size 3.2 3.2) '
            '(drill 3.2) (layers "*.Cu" "*.Mask") (solder_mask_margin 0.0))') in fp
    assert "thru_hole circle" not in fp.replace("np_thru_hole circle", "")


def test_kicad_footprint_plated_th_is_masked_thru_hole():
    """UNIT: a plated through-hole pad emits a `thru_hole`
    line — a plated thru_hole (never np_thru_hole). It now carries "*.Mask" so its
    annulus is exposed, matching the gerber emitter + kicad-standard (verified vs
    pcbnew: a plated thru_hole pad IS on F.Mask) — E3 finding 019f901a9966."""
    pad = {"number": "1", "type": "thru_hole", "shape": "circle",
           "position": {"x": 5.0, "y": 5.0}, "size": {"width": 1.6, "height": 1.6},
           "drill": {"x": 0.8, "y": 0.8}, "layers": ["*.Cu"]}
    fp = kicad._footprint(_th_comp(pad), {}, {})
    assert ('(pad "1" thru_hole circle (at 5.0 5.0) (size 1.6 1.6) '
            '(drill 0.8) (layers "*.Cu" "*.Mask") (solder_mask_margin 0.1))') in fp
    assert "np_thru_hole" not in fp


def _smd_mask_pad(margin: float) -> dict:
    """A 1.0x1.0 SMD pad carrying a per-pad solder_mask_margin (drives the SMD gate)."""
    return {"number": "1", "type": "smd", "shape": "rect",
            "position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.0, "height": 1.0},
            "layers": ["F.Cu"], "solder_mask_margin": margin}


def _plated_th_mask_pad(margin: float) -> dict:
    """A round plated-TH pad (annulus 1.0) carrying a per-pad solder_mask_margin
    (drives the round-annulus gate)."""
    return {"number": "1", "type": "thru_hole", "shape": "circle",
            "position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.0, "height": 1.0},
            "drill": {"x": 0.8, "y": 0.8}, "layers": ["*.Cu"],
            "solder_mask_margin": margin}


def _oblong_th_mask_pad(margin: float) -> dict:
    """An OBLONG (2.0x1.0) plated-TH pad with a shapeable `oval` land — drives the
    shaped-TH gate (lw & lh), where the smaller axis (1.0) collapses first."""
    return {"number": "1", "type": "thru_hole", "shape": "oval",
            "position": {"x": 0.0, "y": 0.0}, "size": {"width": 2.0, "height": 1.0},
            "drill": {"x": 0.8, "y": 0.8}, "layers": ["*.Cu"],
            "solder_mask_margin": margin}


@pytest.mark.parametrize("make_pad", [_smd_mask_pad, _plated_th_mask_pad,
                                      _oblong_th_mask_pad],
                         ids=["smd", "round-th", "oblong-th"])
@pytest.mark.parametrize("margin", [-5.0, -0.5])
def test_kicad_footprint_collapsing_negative_mask_margin_fails_closed(make_pad, margin):
    """SYMMETRY with gerber (bug 019f929b1416): a per-pad solder_mask_margin large
    enough to collapse the mask opening to <= 0 fails CLOSED in the KiCad emitter too,
    rather than emitting a degenerate `(solder_mask_margin)` on a zero/negative
    opening. -0.5 on a 1.0 copper dim pins the exact-zero boundary (dim 0.0 fails, not
    just dim < 0). Both emitters route the per-pad margin through the SHARED
    pad_source.mask_opening_dim, so they fail at the IDENTICAL boundary."""
    with pytest.raises(ValueError, match="H1"):
        kicad._footprint(_th_comp(make_pad(margin)), {}, {})


def test_kicad_footprint_negative_mask_margin_that_stays_positive_is_accepted():
    """COMPLEMENT (symmetric to the gerber test): a merely-negative margin whose
    opening stays > 0 is a legitimate KiCad mask-sliver feature and emits without
    error — a 2.0x1.0 land with margin -0.1 keeps openings 1.8x0.8 (both > 0)."""
    fp = kicad._footprint(_th_comp({
        "number": "1", "type": "smd", "shape": "rect",
        "position": {"x": 0.0, "y": 0.0}, "size": {"width": 2.0, "height": 1.0},
        "layers": ["F.Cu"], "solder_mask_margin": -0.1}), {}, {})
    assert "(solder_mask_margin -0.1)" in fp


def test_kicad_adapter_fails_closed_on_non_round_hole():
    """The round-only drill seal stays intact: a non-round hole feature (a future
    oval/slot IR) RAISES rather than silently dropping a fab-critical drill."""
    hole = ResolvedHole(
        id="hole:oval:0",
        feature=OvalHole(position=(1.0, 1.0), width_mm=2.0, height_mm=3.0,
                         rotation_deg=0.0),
        plated=False, kind=HoleKind.NPTH)
    with pytest.raises(ValueError, match="non-round"):
        _kicad_mounting_hole_component(hole, 0)


@pytest.mark.skipif(not kicad_cli_available(), reason="kicad-cli not on PATH")
def test_kicad_npth_mounting_hole_roundtrips_through_drill_export(tmp_path):
    """ORACLE: an NPTH mounting hole emits a valid, DRC-clean .kicad_pcb whose
    kicad-cli drill export places the drill in the NON-plated file at the hole's
    ABSOLUTE position with the correct diameter (KiCad flips Y: y_mm -> -y_mm)."""
    board = _board("R_0805")
    board["mounting_holes"] = [{"x_mm": 25.0, "y_mm": 30.0, "diameter_mm": 3.2}]
    pcb = _emit_kicad(board)
    npth, pth = _export_drills(pcb, tmp_path)
    assert _drill_hits(npth) == [("3.200", 25.0, -30.0)]
    assert _drill_hits(pth) == []
    assert run_drc_on_pcb_text(pcb, name="brd").clean


@pytest.mark.skipif(not kicad_cli_available(), reason="kicad-cli not on PATH")
def test_kicad_pth_mounting_hole_roundtrips_through_drill_export(tmp_path):
    """ORACLE: a PLATED board hole lands in the PLATED drill file (thru_hole),
    correct diameter + absolute position, DRC-clean."""
    board = _board("R_0805")
    board["pth_holes"] = [{"x_mm": 12.0, "y_mm": 20.0, "diameter_mm": 2.5,
                           "annulus_mm": 3.5}]
    pcb = _emit_kicad(board)
    npth, pth = _export_drills(pcb, tmp_path)
    assert _drill_hits(pth) == [("2.500", 12.0, -20.0)]
    assert _drill_hits(npth) == []
    assert run_drc_on_pcb_text(pcb, name="brd").clean


def test_unplated_board_hole_gets_drill_size_mask_both_emitters():
    # E3 (finding 019f901a9966): the ratified NPTH mask rule — an unplated board-level
    # hole gets a DRILL-size mask opening on both sides in gerber, UNIFORM with a
    # footprint np_thru_hole pad and kicad's np_thru_hole (which declares *.Mask).
    board = {"version": 1, "name": "h", "width_mm": 20, "height_mm": 20,
             "layers": ["top", "bottom"],
             "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                              "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
             "components": [{"ref": "X1", "footprint": "R_0805", "x_mm": 5, "y_mm": 5,
                             "rotation_deg": 0, "layer": "top"}],
             "mounting_holes": [{"x_mm": 12, "y_mm": 12, "diameter_mm": 3.2, "plated": False}]}
    resolved = _resolve(board)
    g = gerber.build_gerbers_ir(resolved, name="h")
    for layer in ("h-F_Mask.gbr", "h-B_Mask.gbr"):
        assert re.search(r"%ADD\d+C,3\.2\*%", g[layer]), f"{layer} missing the NPTH drill mask"
        assert re.search(r"X12000000Y12000000D03", g[layer]), f"{layer} missing the mask flash"
    # kicad emits the bare np_thru_hole (which carries *.Mask) for the board hole.
    pcb = kicad.generate_ir(resolved, base_name="h")["h.kicad_pcb"]
    assert '(pad "" np_thru_hole circle' in pcb and '"*.Cu" "*.Mask"' in pcb


def test_via_tenting_gerber_mask():
    # D4 (finding 019f8fe7cbaf): via mask tenting is authored + DEFAULTS TENTED. A
    # tented via (default or explicit) has NO mask opening; an untented via exposes
    # its annulus with a mask opening on BOTH sides. Only the `tented` flag differs.
    def _via_board(tented):
        v = {"x_mm": 20, "y_mm": 20, "diameter_mm": 0.8, "drill_mm": 0.4,
             "net": "N", "from_layer": "top", "to_layer": "bottom"}
        if tented is not None:
            v["tented"] = tented
        return {"version": 1, "name": "v", "width_mm": 40, "height_mm": 40,
                "layers": ["top", "bottom"],
                "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                                 "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
                "components": [{"ref": "X1", "footprint": "R_0805", "x_mm": 10,
                                "y_mm": 10, "rotation_deg": 0, "layer": "top"}],
                "nets": [{"name": "N", "pins": ["X1.1"]}], "vias": [v]}

    via_flash = r"X20000000Y20000000D03"
    for tented in (None, True):   # default + explicit tented -> no via mask
        g = gerber.build_gerbers_ir(_resolve(_via_board(tented)), name="v")
        assert not re.search(via_flash, g["v-F_Mask.gbr"]), f"tented={tented} leaked a via mask"
    g = gerber.build_gerbers_ir(_resolve(_via_board(False)), name="v")   # untented -> mask
    assert re.search(via_flash, g["v-F_Mask.gbr"]) and re.search(via_flash, g["v-B_Mask.gbr"])


def _one_via_kicad_board():
    """A minimal resolvable board carrying exactly one via, projected into the
    kicad emitter board_dict. Callers set d['vias'][0]['tented_front'/'back']."""
    board = {"version": 1, "name": "v", "width_mm": 40, "height_mm": 40,
             "layers": ["top", "bottom"],
             "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                              "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
             "components": [{"ref": "X1", "footprint": "R_0805", "x_mm": 10,
                             "y_mm": 10, "rotation_deg": 0, "layer": "top"}],
             "nets": [{"name": "N", "pins": ["X1.1"]}],
             "vias": [{"net": "N", "x_mm": 20, "y_mm": 20, "diameter_mm": 0.8,
                       "drill_mm": 0.4, "from_layer": "top", "to_layer": "bottom"}]}
    return kicad._ir_board_dict(_resolve(board))


def test_kicad_via_tenting_token_matches_pcbnew():
    # E4 (finding 019f9022facc): KiCad export must HONOR the canonical per-side via
    # tenting instead of deferring to the board's design-rule default. The
    # `(tenting ...)` token names the sides that ARE tented (mask covers the via);
    # an untented side is exposed. The exact token vocabulary is verified against
    # pcbnew 9.0.9 SetFront/BackTentingMode -> SaveBoard round-trip: both tented ->
    # "front back", front-only -> "front", back-only -> "back", neither -> "none".
    # It is emitted EXPLICITLY in every case (never omitted/FROM_RULES) so the kicad
    # and gerber emitters cannot silently diverge on which vias are exposed.
    def _kpcb(tf, tb):
        d = _one_via_kicad_board()
        d["vias"][0]["tented_front"] = tf
        d["vias"][0]["tented_back"] = tb
        return kicad.generate(d, base_name="v")["v.kicad_pcb"]

    assert "(tenting front back)" in _kpcb(True, True)
    assert "(tenting none)" in _kpcb(False, False)
    assert "(tenting front)" in _kpcb(True, False)
    assert "(tenting back)" in _kpcb(False, True)


def test_kicad_via_tenting_defaults_tented_and_agrees_with_gerber():
    # The IR default is TENTED (both sides), matching gerber._emit_via's
    # via.get("tented_front", True). A DEFAULT via: kicad tents both sides AND gerber
    # emits NO mask opening. An UNTENTED via: kicad exposes both sides AND gerber
    # flashes a mask opening on both — the two emitters agree on exposure (the whole
    # point of finding 019f9022facc). Uses the source-level `tented` bool (symmetric).
    def _board(tented):
        v = {"net": "N", "x_mm": 20, "y_mm": 20, "diameter_mm": 0.8, "drill_mm": 0.4,
             "from_layer": "top", "to_layer": "bottom"}
        if tented is not None:
            v["tented"] = tented
        return {"version": 1, "name": "v", "width_mm": 40, "height_mm": 40,
                "layers": ["top", "bottom"],
                "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                                 "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
                "components": [{"ref": "X1", "footprint": "R_0805", "x_mm": 10,
                                "y_mm": 10, "rotation_deg": 0, "layer": "top"}],
                "nets": [{"name": "N", "pins": ["X1.1"]}], "vias": [v]}

    via_flash = r"X20000000Y20000000D03"
    for tented in (None, True):        # default + explicit tented: kicad tents, gerber bare
        resolved = _resolve(_board(tented))
        pcb = kicad.generate_ir(resolved, base_name="v")["v.kicad_pcb"]
        g = gerber.build_gerbers_ir(resolved, name="v")
        assert "(tenting front back)" in pcb, f"tented={tented}: kicad did not tent"
        assert not re.search(via_flash, g["v-F_Mask.gbr"]), f"tented={tented}: gerber leaked a via mask"

    resolved = _resolve(_board(False))  # untented: kicad exposes, gerber opens mask
    pcb = kicad.generate_ir(resolved, base_name="v")["v.kicad_pcb"]
    g = gerber.build_gerbers_ir(resolved, name="v")
    assert "(tenting none)" in pcb
    assert re.search(via_flash, g["v-F_Mask.gbr"]) and re.search(via_flash, g["v-B_Mask.gbr"])


def _declared_kicad_layers(pcb: str) -> set[str]:
    """Canonical layer names declared in the board's top `(layers ...)` table."""
    m = re.search(r"  \(layers\n(.*?)\n  \)", pcb, re.S)
    assert m, "no (layers ...) table found in the emitted board"
    return set(re.findall(r'\(\d+ "([^"]+)"', m.group(1)))


def _referenced_kicad_layers(pcb: str) -> set[str]:
    """Every layer the emitter WRITES outside the table: pad `(layers "A" "B")`
    lists and node `(layer "X")` refs, with `*.Cu`/`*.Mask` wildcards expanded to
    their front+back members."""
    tbl = re.search(r"  \(layers\n.*?\n  \)", pcb, re.S)
    body = (pcb[:tbl.start()] + pcb[tbl.end():]) if tbl else pcb
    refs: set[str] = set()
    for grp in re.findall(r'\(layers ((?:"[^"]+"\s*)+)\)', body):
        refs.update(re.findall(r'"([^"]+)"', grp))
    refs.update(re.findall(r'\(layer "([^"]+)"\)', body))
    out: set[str] = set()
    for r in refs:
        # `*.Cu`/`*.Mask` expand to FRONT+BACK only — correct for the bounded 2-layer
        # v1 contract; revisit if inner copper layers ever ship.
        out.update({"F." + r[2:], "B." + r[2:]} if r.startswith("*.") else {r})
    return out


def test_every_referenced_kicad_layer_is_declared():
    # G2 (finding 019f90c5c962): EXHAUSTIVE declared-vs-referenced gate, not just
    # F.Mask. Every layer the emitter writes — pad `(layers ...)`, footprint/text/
    # graphic `(layer ...)`, wildcards expanded — MUST be declared in the top
    # `(layers ...)` table, or KiCad silently drops that layer's export. Exercises a
    # TOP and a BOTTOM footprint (so F/B paste+mask+fab all appear) plus a TH pad,
    # via, NPTH mount, and traces.
    board = {"version": 1, "name": "b", "width_mm": 40, "height_mm": 30,
             "layers": ["top", "bottom"],
             "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                              "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
             "components": [
                 {"ref": "R1", "footprint": "R_0805", "x_mm": 10, "y_mm": 10,
                  "rotation_deg": 0, "layer": "top"},
                 {"ref": "R2", "footprint": "R_0805", "x_mm": 25, "y_mm": 15,
                  "rotation_deg": 0, "layer": "bottom"},
                 {"ref": "U1", "footprint": "TH_TestPoint", "x_mm": 30, "y_mm": 20,
                  "rotation_deg": 0, "layer": "top",
                  "pins": [{"number": "1", "x_mm": 0, "y_mm": 0, "drill_mm": 0.8,
                            "annulus_diameter_mm": 1.6}]}],
             "nets": [{"name": "N", "pins": ["R1.1", "U1.1"]}],
             "vias": [{"net": "N", "x_mm": 18, "y_mm": 12, "diameter_mm": 0.8,
                       "drill_mm": 0.4, "from_layer": "top", "to_layer": "bottom"}],
             "mounting_holes": [{"x_mm": 5, "y_mm": 5, "diameter_mm": 3.2, "plated": False}]}
    pcb = _emit_kicad(board, name="b")
    declared = _declared_kicad_layers(pcb)
    referenced = _referenced_kicad_layers(pcb)
    missing = referenced - declared
    assert not missing, (
        f"emitter references undeclared KiCad layers {sorted(missing)} "
        f"(KiCad would silently drop their export); declared={sorted(declared)}")
    # Teeth: the scan actually SAW the technical layers on both sides — otherwise a
    # trivially-empty reference set would pass vacuously.
    assert {"F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.Paste", "B.Paste", "F.Fab",
            "F.SilkS", "Edge.Cuts"} <= referenced, sorted(referenced)


def test_footprint_fab_text_is_own_side_and_back_is_mirrored():
    # C5b fold-in (finding 019f8b715ca6): reference/value fp_text goes on the
    # component's OWN-SIDE Fab layer — F.Fab for a top footprint, B.Fab for a bottom
    # one (was hardcoded F.Fab, leaving B.Fab empty). Back-layer text must be
    # MIRRORED or KiCad DRC raises nonmirrored_text_on_back_layer.
    top = _emit_kicad(_board("R_0805", layer="top"), name="t")
    bot = _emit_kicad(_board("R_0805", layer="bottom"), name="b")
    # Top: on F.Fab, NO mirror effects.
    assert '(fp_text reference "X1" (at 0 -1.5) (layer "F.Fab"))' in top
    assert '(fp_text value "" (at 0 1.5) (layer "F.Fab"))' in top
    # Bottom: on B.Fab WITH (effects (justify mirror)); NO fp_text left on F.Fab.
    assert '(fp_text reference "X1" (at 0 -1.5) (layer "B.Fab") (effects (justify mirror)))' in bot
    assert '(fp_text value "" (at 0 1.5) (layer "B.Fab") (effects (justify mirror)))' in bot
    assert '(layer "F.Fab")' not in bot   # the layer TABLE uses (35 "F.Fab" user), not (layer ...)


def test_plated_board_hole_annulus_agrees_across_emitters():
    """finding 019f8dbb7104: a plated board hole's AUTHORED annulus reaches BOTH
    emitters as the SAME copper — gerber flashes a copper annulus of that diameter on
    F.Cu AND B.Cu, kicad emits a thru_hole of the same size. No emitter invents (the
    old divergence: kicad 2x-drill copper vs gerber drill-only)."""
    board = _board("R_0805")
    board["pth_holes"] = [{"x_mm": 10.0, "y_mm": 10.0, "diameter_mm": 2.0,
                           "annulus_mm": 3.4}]
    resolved = _resolve(board)
    kd = kicad._ir_board_dict(resolved)
    (mh,) = [c for c in kd["components"] if c["footprint"] == "MountingHole"]
    assert mh["pads"][0]["size"] == {"width": 3.4, "height": 3.4}   # kicad annulus
    g = gerber.build_gerbers_ir(resolved, name="brd")
    for layer in ("brd-F_Cu.gbr", "brd-B_Cu.gbr"):
        assert re.search(r"%ADD\d+C,3\.4\b", g[layer]), (
            f"{layer} missing the authored 3.4 copper annulus on the plated hole")


def test_kicad_adapter_does_not_mutate_the_resolved_board():
    board = _resolve(_board("Package_DIP:DIP-6_W7.62mm_Socket",
                            pins=[{"number": "1", "override": {"drill_mm": 1.3}}]))
    before = copy.deepcopy(board)
    kicad._ir_board_dict(board)
    assert board == before


def test_kicad_adapter_is_deterministic():
    board = _resolve(_board("Espressif:ESP32-S3-DevKitC"))
    assert kicad._ir_board_dict(board) == kicad._ir_board_dict(board)


def test_kicad_and_gerber_bridges_agree_on_absolute_pad_position():
    """The kicad REAL-placement encoding and the gerber ABSOLUTE encoding describe
    the SAME absolute copper: reconstructing each kicad footprint-LOCAL pad through
    its component placement recovers the IR's board-absolute pad position (the same
    board-absolute geometry the gerber emitter consumes). The geometric-equivalence
    guard for the real-placement cutover — fabrication is unchanged; only the kicad
    footprint origin moved (finding 019f8dbb6593)."""
    resolved = _resolve(_board("Package_DIP:DIP-6_W7.62mm_Socket", layer="bottom"))
    # Gerber-side truth: PlacedPad.position IS board-absolute — exactly what the
    # IR-native gerber emitter flashes.
    kcomp = kicad._ir_board_dict(resolved)["components"][0]
    px, py, rot = kcomp["x_mm"], kcomp["y_mm"], kcomp["rotation_deg"]
    gpos = sorted((round(p.position[0], 6), round(p.position[1], 6))
                  for p in resolved.components[0].placed_pads)
    kpos = sorted(
        tuple(round(v, 6) for v in place_point(px, py, rot, p["position"]["x"], p["position"]["y"]))
        for p in kcomp["pads"])
    assert kpos == gpos, (kpos, gpos)


def test_mounting_hole_refs_skip_existing_component_refs():
    # Fable W8.2b: a synthetic MountingHole ref must not duplicate a real
    # component ref (a user component named "H1" would otherwise collide in the
    # .kicad_pcb — a duplicate reference KiCad flags).
    from pcb_worker.kicad import _mounting_hole_refs
    assert _mounting_hole_refs(set(), 3) == ["H1", "H2", "H3"]
    refs = _mounting_hole_refs({"R1", "H1", "H3"}, 3)
    assert refs == ["H2", "H4", "H5"]
    assert not set(refs) & {"R1", "H1", "H3"}
