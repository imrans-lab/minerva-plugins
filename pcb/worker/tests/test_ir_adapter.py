"""W8.1 — the GERBER IR→dict bridge (``ir_adapter.ir_to_board_dict``).

These are the W8.1 wins: the adapter + gerber ``placed=True`` mode make the three
things the LEGACY (resolve_board_best_effort) fab path drops reach the gerber/
Excellon fabrication BYTES —

  1. board-ABSOLUTE pad placement (not the emitter re-applying local geometry);
  2. a pin ``override`` (drill / annulus) — ignored by the legacy path;
  3. the bottom-side MIRROR (side + Y-fold) — the legacy path never mirrors;
  4. per-pad ROTATION — dropped by the legacy path.

Each is proven by parsing the emitted gerber/Excellon, plus adapter purity /
determinism and a legacy-path-unchanged guard.

The pipeline under test:

    compile_board(source).board  ->  ir_to_board_dict(rb)  ->  build_gerbers(dict, placed=True)
"""

from __future__ import annotations

import copy
import re

import pytest

from pcb_worker import gerber
from pcb_worker.compile_board import compile_board
from pcb_worker.ir_adapter import ir_to_board_dict
from pcb_worker.resolved_board import DiagnosticSeverity, ResolutionSuccess


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
    return gerber.build_gerbers(ir_to_board_dict(_resolve(board)), name=name, placed=True)


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
    IR; under the adapter's IDENTITY component placement the ONLY rotation source
    left is the pad's own angle. ``placed=True`` applies it (a rotation-carrying
    aperture macro); ``placed=False`` on the SAME dict drops it (a plain rect) —
    which is exactly the legacy bug this phase fixes."""
    board_dict = ir_to_board_dict(_resolve(_board("R_0805", rotation_deg=90)))
    # The bridge zeroed the component placement and baked the angle per-pad.
    comp = board_dict["components"][0]
    assert comp["x_mm"] == 0.0 and comp["y_mm"] == 0.0 and comp["rotation_deg"] == 0.0
    assert all(p["rotation"] == 90.0 for p in comp["pads"])

    placed = gerber.build_gerbers(board_dict, name="brd", placed=True)["brd-F_Cu.gbr"]
    legacy = gerber.build_gerbers(board_dict, name="brd", placed=False)["brd-F_Cu.gbr"]
    assert "%AMRectangle*" in placed                        # a rotation-carrying macro
    assert re.search(r"Rectangle,[\d.X]+X90", placed), _apertures(placed)
    assert "%AMRectangle*" not in legacy                    # rotation dropped without placed mode
    assert any(a.startswith("R,") for a in _apertures(legacy))


# ---------------------------------------------------------------------------
# Adapter purity + determinism.
# ---------------------------------------------------------------------------


def test_adapter_does_not_mutate_the_resolved_board():
    board = _resolve(_board("Package_DIP:DIP-6_W7.62mm_Socket",
                            pins=[{"number": "1", "override": {"drill_mm": 1.3}}]))
    before = copy.deepcopy(board)
    ir_to_board_dict(board)
    assert board == before  # frozen dataclasses; the adapter only reads


def test_adapter_is_deterministic():
    board = _resolve(_board("EVP-ASAC1A:SW_EVP-ASAC1A"))
    assert ir_to_board_dict(board) == ir_to_board_dict(board)


def test_adapter_carries_absolute_geometry_and_frame():
    """Shape smoke: identity placement, absolute pad positions, board frame,
    design rules, and silk graphics all carried in the emitter's expected keys."""
    board_dict = ir_to_board_dict(_resolve(_board("R_0805")))
    assert board_dict["width_mm"] == 40 and board_dict["height_mm"] == 40
    assert board_dict["origin"] == {"x_mm": 0.0, "y_mm": 0.0}
    assert set(board_dict["design_rules"]) >= {
        "trace_width_mm", "via_diameter_mm", "via_drill_mm", "solder_mask_clearance_mm"}
    comp = board_dict["components"][0]
    assert comp["layer"] == "top"
    assert comp["pads"][0]["position"] == {"x": 9.05, "y": 10.0}  # ABSOLUTE
    # R_0805 carries F.SilkS graphics — attached as absolute list-coord dicts.
    assert comp["graphics"] and all(isinstance(g.get("layer"), str) for g in comp["graphics"])


# ---------------------------------------------------------------------------
# Legacy path unchanged (placed=False is the goldens' path).
# ---------------------------------------------------------------------------


def test_legacy_placed_false_is_byte_stable_across_the_new_param():
    """Adding the ``placed`` parameter must not perturb the default path: a legacy
    (local-geometry) board built with ``placed=False`` — the goldens' path —
    equals one built with the parameter omitted entirely, byte for byte. (The
    full golden set is guarded by test_gerbers.py / test_determinism_gate.py.)"""
    legacy_board = {
        "version": 1, "name": "leg", "width_mm": 20, "height_mm": 20,
        "components": [{
            "ref": "U1", "x_mm": 10, "y_mm": 10, "rotation_deg": 30, "layer": "top",
            "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                      "pad_width_mm": 1.2, "pad_height_mm": 0.8}],
        }],
    }
    default = gerber.build_gerbers(copy.deepcopy(legacy_board), name="leg")
    explicit = gerber.build_gerbers(copy.deepcopy(legacy_board), name="leg", placed=False)
    assert dict(default) == dict(explicit)
