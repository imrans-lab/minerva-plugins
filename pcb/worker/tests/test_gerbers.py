"""Tests for the `gerbers` worker method + pcb_worker.gerber.

Structural RS-274X/X2 checks are LIFTED from the validation spike's validate.py
(pcb/spikes/gerber/validate.py) rather than rewritten, then run as pytest
assertions over the PRODUCTION compiler's output for two boards:

  * the spike board (pcb/spikes/gerber/board.yaml), and
  * a hand-authored drill-split fixture (testdata/gerber_boards/drilltest.yaml).

Coverage:
  1. Every emitted Gerber layer passes the spike's structural checks (self-
     consistent %FS, %MOMM*%, M02*, apertures-before-use, D0x usage, X2
     .FileFunction/.FilePolarity) + a pygerber round-trip parse.
  2. Excellon: M48/tool-table/METRIC/M30 + PTH/NPTH split correctness.
  3. Byte-for-byte golden comparison (goldens regenerated through this path).
  4. The `gerbers` worker method's {files, written} envelope.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

from pcb_worker import board_model, gerber
from pcb_worker.methods import handle_request
from tests.gerber_fab import build_fab, build_raw_emitter

HERE = Path(__file__).resolve().parent
SPIKE_BOARD = HERE.parents[1] / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE / "testdata" / "gerber_boards" / "drilltest.yaml"
GOLDEN_DIR = HERE / "testdata" / "gerber_golden"

BOUNDS_TOL_MM = 2.0  # slack for pad half-extents / real silk graphics past nominal extent

# (board path, golden base name, builder). The spike goes through the PRODUCTION
# fab path (compile -> IR); drilltest is the raw loose-dict drift fixture and is
# emitted DIRECTLY through the raw emitter (its non-library footprints do not
# compile) — the routing is explicit per case, not a hidden allowlist (K4
# keystone item 1). See tests/gerber_fab.py.
CASES = [
    pytest.param(SPIKE_BOARD, "board", build_fab, id="board-production"),
    pytest.param(DRILL_BOARD, "drilltest", build_raw_emitter, id="drilltest-raw"),
]


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Structural RS-274X checks (lifted from spike validate.py) as assertions.
# ---------------------------------------------------------------------------


def _assert_gerber_structural(name: str, text: str, bounds: tuple) -> None:
    min_x, min_y, max_x, max_y = bounds
    lines = text.splitlines()

    # %FSLAX_Y_*% present and self-consistent (NOT hard-required to be 4.6).
    fs = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", text)
    assert fs, f"{name}: no %FSLAX..Y..*% format spec"
    xi, xd, yi, yd = (int(g) for g in fs.groups())
    assert (xi, xd) == (yi, yd), f"{name}: asymmetric X/Y format spec"

    assert "%MOMM*%" in text, f"{name}: units not declared as mm"
    assert lines[-1].strip() == "M02*", f"{name}: M02* not the last line"

    # Every selected aperture (Dnn, n>=10) is defined via %ADDnn...% before use.
    define_pos: dict[int, int] = {}
    for i, line in enumerate(lines):
        for m in re.finditer(r"%ADD(\d+)", line):
            define_pos.setdefault(int(m.group(1)), i)
    used: set[int] = set()
    for i, line in enumerate(lines):
        m = re.match(r"D(\d+)\*$", line.strip())
        if m and int(m.group(1)) >= 10:
            dcode = int(m.group(1))
            used.add(dcode)
            assert dcode in define_pos, f"{name}: aperture D{dcode} used but never defined"
            assert define_pos[dcode] <= i, f"{name}: D{dcode} selected before its %ADD"

    # At least one plot command — EXCEPT a legend/silk layer, which is legitimately
    # EMPTY when no component authored F.SilkS graphics (K4: the procedural courtyard
    # box is retired; no resolved silk means an empty legend layer, still a valid
    # gerber with header/footer).
    if not name.endswith("F_SilkS.gbr"):
        assert re.search(r"D0[123]\*", text), f"{name}: no D01/D02/D03 plot commands"

    # X2 attributes — accept both the %TF..*% and the G04 #@! comment form.
    assert re.search(r"TF\.FileFunction,([^*]+)\*", text), f"{name}: no .FileFunction"
    assert re.search(r"TF\.FilePolarity,([^*]+)\*", text), f"{name}: no .FilePolarity"

    # Plotted coordinates within board bounds (unit = nm at ..6 fractional digits).
    if xd == 6:
        for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D0[123]\*", text):
            x_mm, y_mm = int(xs) / 1e6, int(ys) / 1e6
            assert min_x - BOUNDS_TOL_MM <= x_mm <= max_x + BOUNDS_TOL_MM, \
                f"{name}: X {x_mm} out of bounds"
            assert min_y - BOUNDS_TOL_MM <= y_mm <= max_y + BOUNDS_TOL_MM, \
                f"{name}: Y {y_mm} out of bounds"


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_gerber_layers_structural(board_path, base, builder):
    bounds = board_model.board_bounds(_load(board_path))
    files = builder(board_path, base)

    gbrs = {n: t for n, t in files.items() if n.endswith(".gbr")}
    # Exactly the six expected layers.
    suffixes = {n[len(base) + 1:-4] for n in gbrs}
    assert suffixes == {"F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS", "Edge_Cuts"}
    for name, text in gbrs.items():
        _assert_gerber_structural(name, text, bounds)


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_gerber_pygerber_round_trip(board_path, base, builder):
    pytest.importorskip("pygerber")
    from pygerber.gerberx3.api.v2 import (
        FileTypeEnum,
        GerberFile,
        OnParserErrorEnum,
    )

    files = builder(board_path, base)
    for name, text in files.items():
        if not name.endswith(".gbr"):
            continue
        gf = GerberFile.from_str(text, file_type=FileTypeEnum.INFER_FROM_ATTRIBUTES)
        parsed = gf.parse(on_parser_error=OnParserErrorEnum.Raise)
        # Round-trips without raising; a concrete file type is inferred from X2.
        assert parsed.get_file_type() is not None, f"{name}: no file type inferred"


# ---------------------------------------------------------------------------
# Excellon structural + PTH/NPTH split.
# ---------------------------------------------------------------------------


def _parse_excellon(text: str) -> dict:
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    assert lines[0] == "M48"
    assert lines[-1] == "M30"
    assert "METRIC" in lines
    tools = {}
    for line in lines:
        m = re.match(r"T(\d+)C([\d.]+)$", line)
        if m:
            tools[int(m.group(1))] = float(m.group(2))
    assert tools, "no tool table"
    current = None
    hits: list[tuple[float, float, float]] = []
    used_tools: set[int] = set()
    for line in lines:
        m = re.match(r"T(\d+)$", line)
        if m:
            current = int(m.group(1))
            used_tools.add(current)
            continue
        m = re.match(r"X(-?[\d.]+)Y(-?[\d.]+)$", line)
        if m and current is not None:
            hits.append((float(m.group(1)), float(m.group(2)), tools[current]))
    assert used_tools <= set(tools), "tool selected that was never defined"
    return {"tools": tools, "hits": hits}


def test_excellon_structural_spike():
    files = build_fab(SPIKE_BOARD, "board")
    pth = _parse_excellon(files["board-PTH.drl"])
    npth = _parse_excellon(files["board-NPTH.drl"])
    # Spike PTH: U1 TH pad (0.8) + via (0.4). NPTH: 1 mounting hole (3.2).
    assert {round(d, 3) for _, _, d in pth["hits"]} == {0.8, 0.4}
    assert [round(d, 3) for _, _, d in npth["hits"]] == [3.2]


def test_excellon_split_drilltest():
    # drilltest is the RAW loose-dict drift fixture (non-library footprints) —
    # emitted directly through the raw emitter, NOT the production fab path.
    files = build_raw_emitter(DRILL_BOARD, "drilltest")
    pth = _parse_excellon(files["drilltest-PTH.drl"])
    npth = _parse_excellon(files["drilltest-NPTH.drl"])

    # PTH: via 0.45 + two J1 pads 1.0 → 3 plated hits.
    pth_dias = sorted(round(d, 3) for _, _, d in pth["hits"])
    assert pth_dias == [0.45, 1.0, 1.0]

    # NPTH: TP1 pad (plated:false, 2.0) + two mounting holes (3.2) → 3 hits.
    npth_dias = sorted(round(d, 3) for _, _, d in npth["hits"])
    assert npth_dias == [2.0, 3.2, 3.2]

    # The plated:false pad's copper annulus is NOT drilled into PTH.
    tp1 = (15.0, 5.0)
    assert not any(abs(x - tp1[0]) < 1e-6 and abs(y - tp1[1]) < 1e-6
                   for x, y, _ in pth["hits"]), "plated:false pad leaked into PTH"


def test_build_fab_fails_closed_on_uncompilable_board():
    # bug 019f917bbe18: build_fab must FAIL CLOSED (raise) for ANY board that does
    # not compile — never silently fall back to the tolerant loose-dict emitter
    # (which would let a compiler/library/contract regression slip past goldens/
    # determinism/geometry-diff/gerbonara). K4 keystone item 1 retired the
    # _RAW_DICT_FIXTURES allowlist, so there is NO per-fixture exemption: the
    # non-library DRILL_BOARD fails closed through build_fab under its OWN name.
    # (Its raw-emitter coverage lives explicitly on build_raw_emitter instead.)
    with pytest.raises(RuntimeError, match="no raw-dict fallback"):
        build_fab(DRILL_BOARD, "drilltest")
    # Production methods._gerbers fails closed on the exact same board — the helper
    # and production AGREE (the split Codex reproduced is gone: no board reaches the
    # raw path by failing to compile).
    resp = handle_request({"id": "r1", "method": "gerbers",
                           "params": {"board": yaml.safe_load(
                               DRILL_BOARD.read_text(encoding="utf-8")), "name": "d"}})
    assert resp["ok"] is False and resp["error"]["kind"] == "compile"


def test_drill_files_omitted_when_no_holes():
    # A board with only SMD pads and no drills emits neither drill file. The SMD
    # pins carry inline pad geometry (pad_width_mm/pad_height_mm) so the emitter
    # has a real land to flash — a sizeless SMD pad now fails closed (step 4a-ii).
    board = {
        "version": 1, "name": "smdonly", "width_mm": 10, "height_mm": 10,
        "components": [
            {"ref": "R1", "footprint": "R_0402", "x_mm": 5, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -0.5, "y_mm": 0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5},
                      {"number": "2", "x_mm": 0.5, "y_mm": 0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5}]},
        ],
        "nets": [],
    }
    files = gerber.build_gerbers(board, name="smdonly")
    assert not any(n.endswith(".drl") for n in files), "unexpected drill file"


# ---------------------------------------------------------------------------
# Golden byte-comparison (production path).
#
# DRIFT-PIN ONLY — NOT A CORRECTNESS ORACLE. Mirrors the framing in
# tests/oracle/golden_emitter/README.md ("Why this is not a correctness
# oracle"): these goldens are captured FROM the emitter under test (see
# regenerate.py, which calls the same build_fab / build_raw_emitter builders
# this test does), so a byte match only proves the emitter still agrees with
# its past self — it cannot prove the past self was correct. That circularity
# is why the failure message below tells you to rerun regenerate.py: that is
# a re-bless, not evidence the new bytes are right, so a red run here is not
# something to silence by just regenerating. What this DOES buy is real drift
# protection — an unintended output change shows up as a failure here. For a
# genuinely independent correctness check (not exercised by this test), see
# tests/oracle/test_geometry_diff.py::
# test_production_matches_spike_golden_except_cosmetic_silk, which compares
# the "board" fixture's production output against the hand-built,
# structurally-validated spike-gerber-v1 golden; it does not cover
# "drilltest".
# ---------------------------------------------------------------------------


def _golden_names() -> list[str]:
    return sorted(p.name for p in GOLDEN_DIR.iterdir()
                  if p.suffix in (".gbr", ".drl"))


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_matches_goldens(board_path, base, builder):
    files = builder(board_path, base)
    for fname, content in files.items():
        golden = GOLDEN_DIR / fname
        assert golden.exists(), f"missing golden {fname} (run regenerate.py)"
        expected = golden.read_text(encoding="utf-8")
        assert content == expected, (
            f"{fname} differs from golden — DRIFT DETECTED. This golden is "
            f"captured from the emitter under test, so it pins CHANGE, not "
            f"correctness: rerunning tests/testdata/gerber_golden/regenerate.py "
            f"is a RE-BLESS, not a fix. Diff the output and establish the new "
            f"bytes are right before regenerating. See the section banner above.")
    # And no stray goldens for this base beyond what we produced.
    produced = set(files)
    for name in _golden_names():
        if name.startswith(base + "-"):
            assert name in produced, f"orphan golden {name} not produced"


# ---------------------------------------------------------------------------
# Worker method: gerbers.
# ---------------------------------------------------------------------------


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "g1", "method": method, "params": params})
    assert resp is not None and resp["id"] == "g1"
    return resp


def test_gerbers_method_returns_files():
    resp = _call("gerbers", {"yaml": SPIKE_BOARD.read_text(encoding="utf-8")})
    assert resp["ok"] is True
    files = resp["result"]["files"]
    # Six gerber layers + two drill files for the spike board.
    assert sum(1 for k in files if k.endswith(".gbr")) == 6
    assert sum(1 for k in files if k.endswith(".drl")) == 2
    assert resp["result"]["written"] == []


def test_gerbers_method_accepts_board_dict_and_name():
    # W8.2 cutover: the gerbers method now COMPILES (strict) → IR → emit, so the
    # board must fully resolve. DRILL_BOARD is authored with non-library footprint
    # refs (Conn_02x01, MountPad_M2) that only worked under the removed best-effort
    # inline-pin path — it no longer compiles. The spike board resolves and carries
    # both a plated TH pad (PTH.drl) and a non-plated mounting hole (NPTH.drl), so
    # it exercises the same {board dict + name} envelope this test asserts.
    # (DRILL_BOARD keeps its direct-emitter golden coverage via test_matches_goldens.)
    resp = _call("gerbers", {"board": _load(SPIKE_BOARD), "name": "myboard"})
    files = resp["result"]["files"]
    assert "myboard-F_Cu.gbr" in files
    assert "myboard-PTH.drl" in files and "myboard-NPTH.drl" in files


def test_gerbers_method_writes_out_dir(tmp_path):
    resp = _call("gerbers", {"yaml": SPIKE_BOARD.read_text(encoding="utf-8"),
                             "name": "board", "out_dir": str(tmp_path)})
    written = resp["result"]["written"]
    assert len(written) == 8  # 6 gerber + PTH + NPTH
    for w in written:
        assert Path(w["path"]).is_file()
        assert w["bytes_written"] > 0


def test_gerbers_method_malformed_yaml_errors():
    resp = _call("gerbers", {"yaml": "]["})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"


# ---------------------------------------------------------------------------
# F.SilkS real footprint graphics (resolve_board's component["graphics"]).
#
# Components WITHOUT 'graphics' must be untouched (covered above by
# test_matches_goldens — the spike/drilltest boards carry no 'graphics' field
# and their goldens are unchanged byte-for-byte). These tests cover the NEW
# behaviour: components WITH 'graphics' emit real silk instead of a box.
# ---------------------------------------------------------------------------

FOOTPRINTS_DIR = HERE / "testdata" / "footprints"
SMART_REMOTE_BOARD = FOOTPRINTS_DIR / "smart-remote-orig.yaml"


def _fs_scale(gbr_text: str) -> tuple[int, int]:
    fs = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", gbr_text)
    assert fs, "no %FSLAX..Y..*% format spec in gerber"
    return int(fs.group(2)), int(fs.group(4))


def _gerber_move_points(gbr_text: str) -> list[tuple[float, float]]:
    """Every D02 (move, i.e. path start) coordinate, honouring the self-declared
    coordinate format (mirrors test_rotation.py's _gerber_flash_centres)."""
    xd, yd = _fs_scale(gbr_text)
    return [(int(xs) / 10 ** xd, int(ys) / 10 ** yd)
            for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D02\*", gbr_text)]


def _gerber_flash_points(gbr_text: str) -> list[tuple[float, float]]:
    xd, yd = _fs_scale(gbr_text)
    return [(int(xs) / 10 ** xd, int(ys) / 10 ** yd)
            for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D03\*", gbr_text)]


def test_silk_real_graphics_replaces_placeholder_box():
    """A resolved board's F.SilkS carries real footprint outlines (many more
    draws than the old one-box-per-component placeholder), including a true
    ARC (MIC1's DIP-socket notch), and still round-trips through pygerber."""
    pytest.importorskip("pygerber")
    from pygerber.gerberx3.api.v2 import (
        FileTypeEnum,
        GerberFile,
        OnParserErrorEnum,
    )
    from pcb_worker.resolve import resolve_board

    board = _load(SMART_REMOTE_BOARD)
    resolved = resolve_board(board)
    n_components = len(resolved["components"])
    assert n_components > 0
    assert all(c.get("graphics") for c in resolved["components"]), \
        "fixture expected to fully resolve graphics for this assertion"

    files = gerber.build_gerbers(resolved, name="smartremote")
    silk = files["smartremote-F_SilkS.gbr"]

    # The old placeholder drew exactly 4 line segments (a box) per component;
    # real silk (line/circle/poly/arc across ~10 components) draws far more.
    draw_ops = len(re.findall(r"D0[123]\*", silk))
    assert draw_ops > 4 * n_components, \
        f"F.SilkS looks like it's still boxes ({draw_ops} draws for {n_components} components)"

    # ESP32/U1's body outline in particular (its footprint has 7 F.SilkS lines).
    assert draw_ops > 50

    # A real arc (G02/G03) is present — MIC1's DIP-6 socket notch — not just
    # straight-line polyline approximations.
    assert "G02*" in silk or "G03*" in silk, "expected a true arc (G02/G03) in F.SilkS"

    gf = GerberFile.from_str(silk, file_type=FileTypeEnum.INFER_FROM_ATTRIBUTES)
    parsed = gf.parse(on_parser_error=OnParserErrorEnum.Raise)
    assert parsed.get_file_type() is not None


def test_silk_omitted_when_component_has_no_graphics():
    """A component with no 'graphics' contributes NO F.SilkS (K4: the procedural
    courtyard-box placeholder is retired — no resolved silk means no silk). On a
    mixed board only the component that authored real silk graphics appears; the
    graphics-less one adds nothing (matching the kicad emitter, which never drew a
    box)."""
    board = {
        "version": 1, "name": "mixed", "width_mm": 40, "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "TESTFP", "x_mm": 10.0, "y_mm": 10.0,
             "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -1.0, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5},
                      {"number": "2", "x_mm": 1.0, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5}],
             "graphics": [{"layer": "F.SilkS", "kind": "line",
                          "start": [-2.0, -1.0], "end": [2.0, -1.0], "width": 0.15}]},
            {"ref": "R1", "footprint": "R_0402", "x_mm": 25.0, "y_mm": 25.0,
             "rotation_deg": 0.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -0.5, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5},
                      {"number": "2", "x_mm": 0.5, "y_mm": 0.0,
                       "pad_width_mm": 0.6, "pad_height_mm": 0.5}]},
        ],
        "nets": [],
    }
    files = gerber.build_gerbers(board, name="mixed")
    silk = files["mixed-F_SilkS.gbr"]
    moves = _gerber_move_points(silk)
    # Only U1's real silk line (1 D02 move). R1 has no graphics -> no box, no silk.
    assert len(moves) == 1, f"expected only U1's real silk-line move, got {moves}"


def test_silk_transform_matches_pad_transform():
    """A component's silk graphics must land at the SAME board-absolute point
    as a pad declared at the identical LOCAL coordinate — i.e. silk uses the
    exact same (_rotate + translate) convention as pads (docs: gerber.py's
    _rotate KiCad-clockwise convention, pinned by test_rotation.py)."""
    board = {
        "version": 1, "name": "silktest", "width_mm": 40, "height_mm": 40,
        "components": [
            {"ref": "U1", "footprint": "TESTFP", "x_mm": 15.0, "y_mm": 8.0,
             "rotation_deg": 37.0, "layer": "top",
             "pins": [{"number": "1", "x_mm": 2.0, "y_mm": 3.0, "drill_mm": 0.5,
                       "annulus_diameter_mm": 1.0}],
             "graphics": [{"layer": "F.SilkS", "kind": "line",
                          "start": [2.0, 3.0], "end": [6.0, 3.0], "width": 0.15}]},
        ],
        "nets": [],
    }
    files = gerber.build_gerbers(board, name="silktest")

    # Pin 1's TH annulus flash in F_Cu (absolute board coords).
    pad_xy = _gerber_flash_points(files["silktest-F_Cu.gbr"])
    assert len(pad_xy) == 1, pad_xy

    # The silk line's start point (local [2.0, 3.0] — identical to the pin)
    # should land on the exact same absolute point.
    silk_xy = _gerber_move_points(files["silktest-F_SilkS.gbr"])
    assert len(silk_xy) == 1, silk_xy

    dx = abs(pad_xy[0][0] - silk_xy[0][0])
    dy = abs(pad_xy[0][1] - silk_xy[0][1])
    assert dx < 1e-3 and dy < 1e-3, \
        f"silk transform {silk_xy[0]} != pad transform {pad_xy[0]}"


def _first_arc(gbr: str):
    """Parse the first modal G02/G03 arc: return (start, end, center, mode)
    in mm, mode 2=CW / 3=CCW. center = start + (I, J)."""
    xd, yd = _fs_scale(gbr)
    mode, sx, sy = 1, None, None
    for line in gbr.splitlines():
        s = line.strip()
        if s == "G02*": mode = 2; continue
        if s == "G03*": mode = 3; continue
        if s == "G01*": mode = 1; continue
        m = re.match(r"X(-?\d+)Y(-?\d+)D02\*", s)
        if m:
            sx, sy = int(m.group(1)) / 10 ** xd, int(m.group(2)) / 10 ** yd
            continue
        m = re.match(r"X(-?\d+)Y(-?\d+)I(-?\d+)J(-?\d+)D01\*", s)
        if m and mode in (2, 3) and sx is not None:
            ex, ey = int(m.group(1)) / 10 ** xd, int(m.group(2)) / 10 ** yd
            ii, jj = int(m.group(3)) / 10 ** xd, int(m.group(4)) / 10 ** yd
            return (sx, sy), (ex, ey), (sx + ii, sy + jj), mode
        m = re.match(r"X(-?\d+)Y(-?\d+)D01\*", s)
        if m:
            sx, sy = int(m.group(1)) / 10 ** xd, int(m.group(2)) / 10 ** yd
    return None


def _arc_midpoint(start, end, center, mode) -> tuple[float, float]:
    import math
    a0 = math.atan2(start[1] - center[1], start[0] - center[0])
    a1 = math.atan2(end[1] - center[1], end[0] - center[0])
    r = math.hypot(start[0] - center[0], start[1] - center[1])
    if mode == 3:  # CCW: sweep angle increasing
        while a1 <= a0: a1 += 2 * math.pi
    else:          # CW: sweep angle decreasing
        while a1 >= a0: a1 -= 2 * math.pi
    am = (a0 + a1) / 2.0
    return (center[0] + r * math.cos(am), center[1] + r * math.sin(am))


def test_legacy_arc_bulges_into_body():
    """Regression: KiCad legacy (center,start,angle) arcs must emit with the
    correct gerber chirality. The DIP-6 pin-1 notch (angle=-180) must bulge
    INTO the body, not mirror outside it. With the DIP-6 placed at rot 0 and
    +y toward the body, the emitted arc's midpoint must sit on the +y side of
    its centre. (The pre-fix code emitted G03, mirroring the notch outward.)"""
    from pcb_worker.footprints import resolve_footprint
    from pcb_worker.resolve import resolve_board

    fp = resolve_footprint("Package_DIP:DIP-6_W7.62mm_Socket")
    pins = [{"number": p["number"], "x_mm": p["x_mm"], "y_mm": p["y_mm"],
             "drill_mm": p.get("drill") or 0.8, "annulus_diameter_mm": 1.6}
            for p in fp["pads"]]
    board = {
        "version": 1, "name": "dip6", "width_mm": 20, "height_mm": 20,
        "components": [{"ref": "U1", "footprint": "Package_DIP:DIP-6_W7.62mm_Socket",
                        "x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0.0,
                        "layer": "top", "pins": pins}],
        "nets": [],
    }
    silk = gerber.build_gerbers(resolve_board(board), name="dip6")["dip6-F_SilkS.gbr"]
    arc = _first_arc(silk)
    assert arc is not None, "expected the DIP-6 pin-1 notch arc in F.SilkS"
    start, end, center, mode = arc
    mid = _arc_midpoint(start, end, center, mode)
    assert mid[1] > center[1] + 0.5, \
        f"notch bulges the WRONG way: midpoint {mid} vs centre {center} (mode {mode})"


# ---------------------------------------------------------------------------
# Rotated fully-rounded aperture: EMITTED BYTES + the upstream canary (019f9af6e899).
#
# gerber-writer collapses a fully-rounded RoundedRectangle to the standard obround
# `O,xXy`, which carries no rotation, and gates that on `angle % 90 == 0` — but an
# obround is symmetric only under 180. gerber._shape_aperture compensates by
# swapping the extents for the defect set. These tests pin the exact bytes on BOTH
# sides of that boundary: swap where upstream drops the angle, and byte-identical
# passthrough everywhere else (especially the macro branch, which carries its own
# angle and would be CORRUPTED by a swap).
# ---------------------------------------------------------------------------


def _aperture_body(shape: str, w: float, h: float, rratio, angle: float) -> str:
    """The single %ADD body a shape+angle flashes, straight out of gerber-writer."""
    from gerber_writer import DataLayer

    layer = DataLayer("Copper,L1,Top", negative=False)
    layer.add_pad(gerber._shape_aperture(shape, w, h, rratio, "SMDPad,CuDef", angle),
                  (10.0, 10.0), angle)
    bodies = re.findall(r"%ADD\d+([^*]+)\*%", layer.dumps_gerber())
    assert len(bodies) == 1, bodies
    return bodies[0]


@pytest.mark.parametrize("angle", [90.0, 270.0, -90.0, 450.0, -270.0])
def test_odd_multiple_of_90_swaps_the_obround_extents(angle):
    # The DEFECT SET. -90 and -270 pin that Python's `%` normalises negatives the way
    # the workaround assumes (-90 % 180 == 90), rather than leaving it to be believed;
    # 450 / -270 pin that it is periodic, not a hardcoded {90, 270}.
    assert _aperture_body("oval", 1.2, 2.4, None, angle) == "O,2.4X1.2"


@pytest.mark.parametrize("angle", [0.0, 180.0, 360.0, -180.0])
def test_even_multiple_of_90_leaves_the_obround_untouched(angle):
    # NON-REGRESSION: an obround is symmetric under 180, so these were always right.
    assert _aperture_body("oval", 1.2, 2.4, None, angle) == "O,1.2X2.4"


def test_square_obround_is_untouched_at_90():
    # NON-REGRESSION: w == h, so the rotation folds away and a swap is a no-op that
    # must not perturb the bytes.
    assert _aperture_body("oval", 2.0, 2.0, None, 90.0) == "O,2.0X2.0"


def test_non_multiple_of_90_still_takes_the_rotating_macro_branch():
    # NON-REGRESSION, and the sharpest edge of the fix: at 45 degrees upstream's
    # `% 90` gate fails, so it emits an aperture MACRO that already carries the
    # angle. Swapping the extents there would CORRUPT a case that was correct.
    body = _aperture_body("oval", 1.2, 2.4, None, 45.0)
    assert body.startswith("RoundedRectangle,0.6X1.2X")
    assert "X45.0X" in body


def test_near_90_angle_is_not_swapped_because_upstream_keeps_the_macro():
    # The tolerance boundary: 90.0000001 fails upstream's EXACT `angle % 90 == 0`, so
    # upstream takes the macro branch and carries the angle itself. Our correction is
    # gated on that same exact test, so it must NOT fire here — a purely tolerance-
    # based check would swap and break a working case.
    body = _aperture_body("oval", 1.2, 2.4, None, 90.0000001)
    assert body.startswith("RoundedRectangle,0.6X1.2X")


def test_rect_and_circle_apertures_are_unaffected_by_rotation_handling():
    # NON-REGRESSION: a rect always emits a macro that carries the angle, and a
    # circle has no orientation at all. Neither goes near the swap.
    assert _aperture_body("rect", 1.2, 2.4, None, 90.0) == "Rectangle,0.6X1.2X90.0"
    assert _aperture_body("circle", 2.0, 2.0, None, 90.0) == "C,2.0"


def test_partially_rounded_roundrect_keeps_its_rotating_macro():
    # NON-REGRESSION: rratio 0.25 is NOT fully rounded, so upstream emits a macro
    # carrying the angle and no correction is wanted.
    body = _aperture_body("roundrect", 1.2, 2.4, 0.25, 90.0)
    assert body.startswith("RoundedRectangle,") and "X90.0X" in body


def test_canary_gerber_writer_still_collapses_fully_rounded_to_a_rotationless_obround():
    """CANARY on the UPSTREAM behaviour gerber._obround_rotation_swap works around.

    Our fix pre-swaps w/h because gerber-writer throws the rotation away. If
    gerber-writer is ever upgraded and fixes its guard (`angle % 90` -> `angle % 180`,
    or by emitting a rotated macro / %LR), it will start honouring the angle itself —
    and OUR swap becomes the bug, double-rotating every oblong land back to wrong.
    This asserts the raw upstream contract, with no pcb_worker code in the path, so
    that upgrade fails HERE and loudly instead of silently shipping bad copper.
    """
    from gerber_writer import DataLayer, RoundedRectangle

    layer = DataLayer("Copper,L1,Top", negative=False)
    # Fully rounded (radius == min(w, h)/2) at an exact multiple of 90.
    layer.add_pad(RoundedRectangle(1.2, 2.4, 0.6, "SMDPad,CuDef"), (10.0, 10.0), 90.0)
    body = re.findall(r"%ADD\d+([^*]+)\*%", layer.dumps_gerber())[0]

    assert body == "O,1.2X2.4", (
        "UPSTREAM CHANGED: gerber-writer no longer collapses a fully-rounded "
        "RoundedRectangle at 90 degrees to the rotationless standard obround "
        f"'O,1.2X2.4' (got {body!r}). gerber._shape_aperture pre-swaps w/h to "
        "compensate for that rotation loss (docket 019f9af6e899). If gerber-writer "
        "now honours the angle itself, THAT SWAP IS NOW A BUG and will double-rotate "
        "every oblong land — delete _obround_rotation_swap and its call site in "
        "gerber._shape_aperture, then re-run the rotated-oval conformance tests.")
