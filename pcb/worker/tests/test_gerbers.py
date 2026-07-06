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

HERE = Path(__file__).resolve().parent
SPIKE_BOARD = HERE.parents[1] / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE / "testdata" / "gerber_boards" / "drilltest.yaml"
GOLDEN_DIR = HERE / "testdata" / "gerber_golden"

BOUNDS_TOL_MM = 2.0  # slack for pad half-extents / silk courtyard margins

# (board path, golden base name)
CASES = [(SPIKE_BOARD, "board"), (DRILL_BOARD, "drilltest")]


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _build(path: Path, base: str) -> dict[str, str]:
    return gerber.build_gerbers(_load(path), name=base)


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

    # At least one plot command.
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


@pytest.mark.parametrize("board_path,base", CASES)
def test_gerber_layers_structural(board_path, base):
    board = _load(board_path)
    bounds = board_model.board_bounds(board)
    files = gerber.build_gerbers(board, name=base)

    gbrs = {n: t for n, t in files.items() if n.endswith(".gbr")}
    # Exactly the six expected layers.
    suffixes = {n[len(base) + 1:-4] for n in gbrs}
    assert suffixes == {"F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS", "Edge_Cuts"}
    for name, text in gbrs.items():
        _assert_gerber_structural(name, text, bounds)


@pytest.mark.parametrize("board_path,base", CASES)
def test_gerber_pygerber_round_trip(board_path, base):
    pytest.importorskip("pygerber")
    from pygerber.gerberx3.api.v2 import (
        FileTypeEnum,
        GerberFile,
        OnParserErrorEnum,
    )

    files = gerber.build_gerbers(_load(board_path), name=base)
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
    files = _build(SPIKE_BOARD, "board")
    pth = _parse_excellon(files["board-PTH.drl"])
    npth = _parse_excellon(files["board-NPTH.drl"])
    # Spike PTH: U1 TH pad (0.8) + via (0.4). NPTH: 1 mounting hole (3.2).
    assert {round(d, 3) for _, _, d in pth["hits"]} == {0.8, 0.4}
    assert [round(d, 3) for _, _, d in npth["hits"]] == [3.2]


def test_excellon_split_drilltest():
    files = _build(DRILL_BOARD, "drilltest")
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


def test_drill_files_omitted_when_no_holes():
    # A board with only SMD pads and no drills emits neither drill file.
    board = {
        "version": 1, "name": "smdonly", "width_mm": 10, "height_mm": 10,
        "components": [
            {"ref": "R1", "footprint": "R_0402", "x_mm": 5, "y_mm": 5,
             "rotation_deg": 0, "layer": "top",
             "pins": [{"number": "1", "x_mm": -0.5, "y_mm": 0},
                      {"number": "2", "x_mm": 0.5, "y_mm": 0}]},
        ],
        "nets": [],
    }
    files = gerber.build_gerbers(board, name="smdonly")
    assert not any(n.endswith(".drl") for n in files), "unexpected drill file"


# ---------------------------------------------------------------------------
# Golden byte-comparison (production path).
# ---------------------------------------------------------------------------


def _golden_names() -> list[str]:
    return sorted(p.name for p in GOLDEN_DIR.iterdir()
                  if p.suffix in (".gbr", ".drl"))


@pytest.mark.parametrize("board_path,base", CASES)
def test_matches_goldens(board_path, base):
    files = gerber.build_gerbers(_load(board_path), name=base)
    for fname, content in files.items():
        golden = GOLDEN_DIR / fname
        assert golden.exists(), f"missing golden {fname} (run regenerate.py)"
        expected = golden.read_text(encoding="utf-8")
        assert content == expected, (
            f"{fname} differs from golden — a deliberate change means rerun "
            f"tests/testdata/gerber_golden/regenerate.py and re-diff.")
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
    resp = _call("gerbers", {"board": _load(DRILL_BOARD), "name": "myboard"})
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
