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

from pcb_worker import board_model, gerber, stroke_font
from pcb_worker.fab_capability import EMITTED_GERBER_SUFFIXES

# Layers that may legitimately carry no plot commands on a given board. See the
# per-suffix reasoning in _assert_gerber_structural.
_MAY_BE_EMPTY = ("F_SilkS", "B_SilkS", "F_Paste", "B_Paste")
from pcb_worker.methods import handle_request
from tests.gerber_fab import build_fab, build_raw_emitter

try:  # dev/CI-only kicad-cli oracle (skips cleanly when absent).
    from tests.oracle.kicad_drc import kicad_cli_available as _kicad_cli_available
except Exception:  # pragma: no cover - oracle package optional
    def _kicad_cli_available() -> bool:
        return False

HERE = Path(__file__).resolve().parent
SPIKE_BOARD = HERE.parents[1] / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE / "testdata" / "gerber_boards" / "drilltest.yaml"
COUPON_BOARD = HERE / "testdata" / "coupon_jlc1.yaml"
QUAD_BOARD = HERE / "testdata" / "gerber_boards" / "quadlayer.yaml"
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
    # jlc-coupon-1 (epoch CPN1) — the PROMOTED public fab coupon, production
    # path. The other two cases certify the emitter against boards authored to
    # exercise it; this one certifies it against a board authored to be
    # FABRICATED (K18): interior cutout on Edge.Cuts, filled pour, the
    # roundrect/oval/circle SMD aperture families, real silk, profile-pinned
    # rules. Its goldens were blessed layer-by-layer in station S8 — see the
    # bless record on docket 019fe2fb843b and testdata/coupon_jlc1.README.md.
    pytest.param(COUPON_BOARD, "coupon_jlc1", build_fab, id="coupon-production"),
    # QuadLayer (epoch GA-3) — the first FOUR-copper-layer corpus board:
    # traces on all four planes, an INNER pour, through vias, the
    # jlcpcb-4layer profile. Certifies the N-layer emission paths (In1_Cu/
    # In2_Cu files, L1..L4 .gbrjob rows) the 2-layer corpus cannot reach.
    # Goldens are blessed per the CPN1 method at the GA epoch's testex/HITL —
    # until that bless lands, the golden byte-compare for this row is EXPECTED
    # to fail with missing goldens (regenerate.py + the layer walk is the
    # bless, not a fix).
    pytest.param(QUAD_BOARD, "quadlayer", build_fab, id="quadlayer-production"),
]


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _declared_layers(board_path: Path) -> list:
    """The board's declared copper stack (absent key = the 2-layer default)."""
    return _load(board_path).get("layers") or ["top", "bottom"]


def _declared_copper_suffixes(board_path: Path) -> set:
    """The gerber suffix set THIS board emits: the 9-suffix baseline plus one
    In{k}_Cu per declared inner layer (epoch GA-3 — the fixed baseline
    constant is deliberately not the whole story for deeper stacks)."""
    n = len(_declared_layers(board_path))
    return set(EMITTED_GERBER_SUFFIXES) | {f"In{k}_Cu" for k in range(1, n - 1)}


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

    # At least one plot command — EXCEPT the layers whose emptiness is a real
    # board fact rather than a lost layer. An empty layer here is NOT an excused
    # failure: it is a header/footer-complete, aperture-less, parseable Gerber,
    # which is exactly the artifact KiCad 10.0.5 itself emits for a side with no
    # content. Every fabrication-bearing copper/mask/edge layer must still plot.
    #
    #   F_SilkS  — no resolved OUTLINE silk (K4: the procedural courtyard box is
    #              retired). Since K17 this is rare — F.SilkS carries every
    #              top-side component's designator strokes — but the exemption
    #              stays for the genuinely component-less/bottom-only case.
    #   B_SilkS  — ALWAYS empty; there is no bottom-silk harvest at all.
    #   F/B_Paste— empty when no pad on that side declares paste participation.
    if not any(name.endswith(f"{suffix}.gbr") for suffix in _MAY_BE_EMPTY):
        assert re.search(r"D0[123]\*", text), f"{name}: no D01/D02/D03 plot commands"

    # X2 attributes — accept both the %TF..*% and the G04 #@! comment form.
    assert re.search(r"TF\.FileFunction,([^*]+)\*", text), f"{name}: no .FileFunction"
    assert re.search(r"TF\.FilePolarity,([^*]+)\*", text), f"{name}: no .FilePolarity"

    # Plotted coordinates within board bounds (unit = nm at ..6 fractional digits).
    #
    # THE Y BOUND IS NEGATED, AND THAT IS THE POINT (bug 019fa8011555). `bounds`
    # is the BOARD frame, which grows Y DOWNWARD (KiCad's file frame); the emitted
    # Gerber is Y-UP, so a board spanning y in [min_y, max_y] plots into
    # [-max_y, -min_y]. This assertion previously compared the emitted Y against
    # the board bounds UNNEGATED and passed — which is exactly how it PINNED the
    # missing conversion as correct, and why every layer shipped vertically
    # mirrored. Inverted rather than deleted: a deleted assertion proves nothing,
    # and this one still has teeth — an emitter that stopped converting fails here.
    if xd == 6:
        for xs, ys in re.findall(r"X(-?\d+)Y(-?\d+)D0[123]\*", text):
            x_mm, y_mm = int(xs) / 1e6, int(ys) / 1e6
            assert min_x - BOUNDS_TOL_MM <= x_mm <= max_x + BOUNDS_TOL_MM, \
                f"{name}: X {x_mm} out of bounds"
            assert -max_y - BOUNDS_TOL_MM <= y_mm <= -min_y + BOUNDS_TOL_MM, \
                f"{name}: Y {y_mm} out of gerber-frame bounds " \
                f"[{-max_y}, {-min_y}] (board bounds [{min_y}, {max_y}] negated)"


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_gerber_layers_structural(board_path, base, builder):
    bounds = board_model.board_bounds(_load(board_path))
    files = builder(board_path, base)

    gbrs = {n: t for n, t in files.items() if n.endswith(".gbr")}
    # Exactly the capability profile's layer set -- read from the shared authority
    # rather than restated, so adding a layer in one place cannot leave this
    # assertion behind as the stale definition of "all of them". Epoch GA-3:
    # "all of them" is per-board now — baseline plus the declared inner
    # copper (quadlayer adds In1_Cu/In2_Cu; the 2-layer rows are unchanged).
    suffixes = {n[len(base) + 1:-4] for n in gbrs}
    assert suffixes == _declared_copper_suffixes(board_path)
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
    # The full plotted layer set + two drill files for the spike board.
    assert sum(1 for k in files if k.endswith(".gbr")) == len(EMITTED_GERBER_SUFFIXES)
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
    # every gerber layer + PTH + NPTH + the .gbrjob manifest
    assert len(written) == len(EMITTED_GERBER_SUFFIXES) + 3
    assert any(w["path"].endswith("board-job.gbrjob") for w in written), written
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

# FIXTURE (docket 019fbe68c5f8, testdata/POLICY.md): this used to be
# ``smart-remote-orig.yaml``, a REAL Turnrock product board, withdrawn from the
# corpus on 2026-07-30 because a real design (netlist + placement) in a public
# repo is an IP leak. ``resolve_corners.yaml`` uses the SAME real, public-origin
# KiCad library parts at new, synthetic refs/positions/nets — see its header
# for the full rationale. NEVER repair this by restoring the deleted fixture
# from git history.
FOOTPRINTS_DIR = HERE / "testdata" / "footprints"
RESOLVE_CORNERS_BOARD = FOOTPRINTS_DIR / "resolve_corners.yaml"


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

    board = _load(RESOLVE_CORNERS_BOARD)
    resolved = resolve_board(board)
    n_components = len(resolved["components"])
    assert n_components > 0
    assert all(c.get("graphics") for c in resolved["components"]), \
        "fixture expected to fully resolve graphics for this assertion"

    files = gerber.build_gerbers(resolved, name="smartremote")
    silk = files["smartremote-F_SilkS.gbr"]

    # The old placeholder drew exactly 4 line segments (a box) per component;
    # real silk (line/circle/poly/arc across 5 components) draws far more.
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
    """[K17] A component with no 'graphics' contributes NO OUTLINE F.SilkS (K4:
    the procedural courtyard-box placeholder is retired — no resolved silk
    graphics means no resolved outline silk), but it STILL gets its own
    reference-designator TEXT: K17 requires every top-side component's "R1" to
    reach F.SilkS, including one whose footprint carries no silk graphics at
    all (gerber._emit_refdes runs outside _emit_silk's graphics-present guard).
    So on a mixed board, R1 (no authored graphics) contributes ONLY its own
    designator strokes; U1 (authored a real silk line) contributes that line
    PLUS its own designator strokes."""
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
    g = gerber._harvest(board, gerber.DEFAULT_MASK_CLEARANCE_MM)

    # U1 authored exactly one real silk LINE; neither component authored a
    # circle/arc, and (K4) no procedural box exists for R1 to have contributed.
    assert len(g.silk_lines) == 1, g.silk_lines
    assert g.silk_circles == [] and g.silk_arcs == []

    # g.silk_polys now holds ONLY reference-designator strokes for this fixture
    # (neither component authored a poly) — one open-polyline run per ref, and
    # it must be non-empty for R1 even though R1 authored no graphics at all.
    assert g.silk_polys, "expected reference-designator strokes for both components"
    assert all(closed is False for (_pts, _w, closed) in g.silk_polys), \
        "a glyph stroke must be OPEN, never closed back to its first point"
    expected_strokes = len(stroke_font.render("U1")) + len(stroke_font.render("R1"))
    assert len(g.silk_polys) == expected_strokes, (
        f"expected {expected_strokes} designator strokes (U1 + R1), got "
        f"{len(g.silk_polys)}")

    # Also confirmed at the gerber-BYTES level: F.SilkS is non-empty for BOTH
    # components even though R1 authored no graphics.
    files = gerber.build_gerbers(board, name="mixed")
    silk = files["mixed-F_SilkS.gbr"]
    moves = _gerber_move_points(silk)
    assert len(moves) == expected_strokes + 1, (
        f"expected U1's real silk-line move plus every designator stroke's own "
        f"move, got {moves}")


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
    # should land on the exact same absolute point. F.SilkS now ALSO carries
    # U1's own reference-designator strokes (K17, additive), so there is more
    # than one move in the layer — search all of them for the authored line's
    # move rather than assuming it is the only (or first) one.
    silk_xy = _gerber_move_points(files["silktest-F_SilkS.gbr"])
    assert len(silk_xy) >= 1, silk_xy

    assert any(abs(px - pad_xy[0][0]) < 1e-3 and abs(py - pad_xy[0][1]) < 1e-3
              for px, py in silk_xy), \
        f"no silk move matches pad transform {pad_xy[0]} (got {silk_xy})"


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
    INTO the body, not mirror outside it.

    With the DIP-6 placed at rot 0, the body is at +y in the BOARD frame — and
    therefore at -y in the emitted GERBER frame, which is Y-UP (bug 019fa8011555,
    _Geometry.to_gerber_frame). So the emitted arc's midpoint must sit BELOW its
    centre in the file. The sense of this assertion flipped with the frame
    conversion, not the geometry: the notch bulges into the body in both
    statements. It still has teeth in both directions — an emitter that converted
    the coordinates but NOT the chirality (or vice versa) mirrors the notch back
    outside the body and fails here."""
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
    assert mid[1] < center[1] - 0.5, \
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


# ---------------------------------------------------------------------------
# COORDINATE FRAME (bug 019fa8011555) — the assertion whose ABSENCE let a
# systemic vertical mirror ship past 1556 tests, the parity harness and 24
# goldens.
#
# The emitter harvests in the BOARD frame (KiCad's file frame, Y-DOWN) and
# converts once, in gerber._Geometry.to_gerber_frame. Before that conversion
# existed, pad CENTRES were written in the board frame while each pad's aperture
# ROTATION was already a gerber-frame angle. Positions mirrored, rotations did
# not — so for any pad turned off a multiple of 90 degrees the copper rectangle
# was fabricated at the WRONG ANGLE (up to 60 degrees out), not merely drawn
# upside down.
#
# WHY THE FIXTURE ANGLES ARE WHAT THEY ARE: a rectangle folds under 180-degree
# symmetry, so a pad at 0/90/180/270 is emitted identically whether or not Y is
# converted. A fixture built from those angles alone PASSES UNDER THE BUG. Every
# rotation below is deliberately NOT a multiple of 90.
# ---------------------------------------------------------------------------

# Rotations chosen so that (a) none is a multiple of 90, and (b) they are not all
# each other's supplements — under the bug a bearing theta reads back as
# 180 - theta, which is a genuinely different angle for each of these.
_OFF_AXIS_ROTATIONS = [30.0, 45.0, 60.0, 135.0]

# Slack for the bearing/rotation comparison. Gerber ordinates are quantised to
# the file's own coordinate format (nm at 3.6), which perturbs a bearing computed
# from two flash centres by ~1e-5 degrees on a 0805 pad pitch. Far below the
# ~60-degree error the bug produces, and far below the 90-degree fold that would
# hide one.
_BEARING_TOL_DEG = 0.01


def _rotated_pad_board(name: str = "rotframe") -> dict:
    """Five R_0805 (two rectangular lands each, on a 1.9 mm pitch) at rotations
    spanning the off-axis set plus an axis-aligned control."""
    rots = [0.0] + _OFF_AXIS_ROTATIONS
    return {
        "version": 1, "name": name, "width_mm": 70, "height_mm": 50,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [
            {"ref": f"R{i + 1}", "footprint": "R_0805",
             "x_mm": 8.0 + 12.0 * i, "y_mm": 9.0 + 6.0 * i,
             "rotation_deg": rot, "layer": "top"}
            for i, rot in enumerate(rots)
        ],
        "nets": [],
    }


def _compile_board_ir(board: dict):
    from pcb_worker.compile_board import compile_board

    return compile_board(board).board


def _flash_pairs(gbr_text: str) -> list[tuple[tuple[float, float], tuple[float, float]]]:
    """Group a copper layer's flashes into the two-pad clusters of each component.

    Purely geometric (single-link clustering at a radius well between the 1.9 mm
    intra-component pad pitch and the >=12 mm inter-component spacing), so it needs
    no ref/pad metadata — which a Gerber flash does not carry anyway."""
    import math

    remaining = _gerber_flash_points(gbr_text)
    pairs = []
    while remaining:
        group = [remaining.pop()]
        grew = True
        while grew:
            grew = False
            for pt in list(remaining):
                if any(math.hypot(pt[0] - q[0], pt[1] - q[1]) <= 4.0 for q in group):
                    group.append(pt)
                    remaining.remove(pt)
                    grew = True
        assert len(group) == 2, f"expected 2-pad clusters, got {len(group)}: {group}"
        pairs.append(tuple(sorted(group)))
    return sorted(pairs)


def _aperture_angle_of(gbr_text: str, flash: tuple[float, float]) -> float:
    """The rotation of the aperture the given flash was plotted with, read back
    out of the emitted BYTES with gerbonara (the repo's independent reader)."""
    import warnings

    from gerbonara import GerberFile

    from pcb_worker.ir_parity import _gerbonara_shape

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        parsed = GerberFile.from_string(gbr_text, filename="rotframe-F_Cu.gbr")
    for obj in parsed.objects:
        if type(obj).__name__ != "Flash":
            continue
        if abs(float(obj.x) - flash[0]) < 1e-6 and abs(float(obj.y) - flash[1]) < 1e-6:
            return _gerbonara_shape(obj.aperture)[3]
    raise AssertionError(f"no flash at {flash}")


def test_aperture_rotation_agrees_with_pad_pair_bearing():
    """THE STANDING FRAME ASSERTION. A two-pad footprint's copper must be TURNED
    the way it is PLACED: the bearing of the line joining its two pad centres must
    equal the rotation of the aperture those pads are flashed with, both read out
    of the emitted Gerber, in the Gerber's own frame.

    This is an INTERNAL SELF-CONSISTENCY check — it appeals to no oracle, no
    golden and no other emitter, because the defect it catches is a
    self-contradiction: positions in one frame, rotations in another. It is the
    check that would have caught bug 019fa8011555 on the day it was written, and
    its absence is why the defect shipped.

    Compared modulo 180 because a rectangular land is symmetric under a half turn
    (the pair (a, b) and (b, a) describe the same copper), which is a genuine
    symmetry of the geometry — NOT the 180-degree fold that hides the bug. That
    fold only rescues rotations which are multiples of 90; see _OFF_AXIS_ROTATIONS.
    """
    import math

    pytest.importorskip("gerbonara")
    files = gerber.build_gerbers_ir(_compile_board_ir(_rotated_pad_board()),
                                    name="rotframe")
    f_cu = files["rotframe-F_Cu.gbr"]

    pairs = _flash_pairs(f_cu)
    assert len(pairs) == len(_OFF_AXIS_ROTATIONS) + 1, pairs

    seen: list[float] = []
    for a, b in pairs:
        bearing = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180.0
        rot = _aperture_angle_of(f_cu, a) % 180.0
        assert _aperture_angle_of(f_cu, b) % 180.0 == rot, \
            "both pads of one component must share an aperture rotation"
        # Circular distance mod 180, so 0.0 and 179.99 are one hundredth apart.
        delta = abs(((bearing - rot + 90.0) % 180.0) - 90.0)
        assert delta <= _BEARING_TOL_DEG, (
            f"copper is turned the WRONG WAY relative to where it sits: pad pair "
            f"{a} -> {b} has bearing {bearing:.4f} deg but its aperture is rotated "
            f"{rot:.4f} deg ({delta:.4f} deg apart). This is the signature of the "
            f"board frame (Y-DOWN) reaching the Gerber unconverted while the "
            f"aperture angle is already gerber-frame — see "
            f"gerber._Geometry.to_gerber_frame (bug 019fa8011555).")
        seen.append(rot)

    # The fixture actually exercised off-90 rotations (guards against a future
    # edit quietly reducing it to the symmetric angles the bug survives).
    off_axis = [r for r in seen if abs((r % 90.0)) > _BEARING_TOL_DEG]
    assert len(off_axis) == len(_OFF_AXIS_ROTATIONS), (
        f"the fixture must exercise rotations that are NOT multiples of 90 — a "
        f"pad at 0/90/180/270 passes this test even under the bug. Got {seen}")


def test_gerber_and_excellon_share_one_frame():
    """The drill hits must move with the copper. A through-hole pad's Excellon
    coordinate and its copper annulus are the SAME physical feature, so a frame
    conversion applied to one path and not the other splits a board in half —
    holes drilled at the mirror of the pads they belong to. Pinned as its own
    assertion because copper and drill leave the emitter through two different
    builders (_build_gerber_layers / _build_drill_files)."""
    board = {
        "version": 1, "name": "frm", "width_mm": 40, "height_mm": 30,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        # Deliberately OFF-CENTRE in y so a sign error cannot land on itself.
        "components": [{"ref": "U1", "footprint": "TH_TestPoint",
                        "x_mm": 12.0, "y_mm": 7.0, "rotation_deg": 0.0,
                        "layer": "top",
                        "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                                  "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}],
        "nets": [],
    }
    files = gerber.build_gerbers_ir(_compile_board_ir(board), name="frm")

    flashes = _gerber_flash_points(files["frm-F_Cu.gbr"])
    hits = _parse_excellon(files["frm-PTH.drl"])["hits"]
    assert len(flashes) == 1 and len(hits) == 1, (flashes, hits)

    assert abs(hits[0][0] - flashes[0][0]) < 1e-3, "drill X left its copper"
    assert abs(hits[0][1] - flashes[0][1]) < 1e-3, (
        f"drill Y {hits[0][1]} does not sit on its copper annulus at "
        f"{flashes[0][1]} — the copper and drill paths are in DIFFERENT frames")
    # And both are in the GERBER frame, not the board frame: the board places this
    # pad at y=+7, so a correctly converted file plots it at -7.
    assert abs(flashes[0][1] + 7.0) < 1e-3, flashes
    assert abs(hits[0][1] + 7.0) < 1e-3, hits


def test_refdes_sits_above_its_component_and_reads_upright():
    """The silk corollary. REFDES_LOCAL_Y_MM = -1.5 places a designator ABOVE its
    component in the board frame (Y-DOWN); it must therefore land above it in the
    emitted Gerber too, which is Y-UP — i.e. at a GREATER Gerber y than the part.

    And it must read the right way up. stroke_font's glyph data is Y-DOWN like the
    rest of the worker (cap top at the more NEGATIVE local y, baseline near 0), so
    emitted unconverted the characters render mirrored top-to-bottom. Checked as
    the 'A' glyph's own span: the ratio of ink above vs below the anchor tells
    which way the glyph is standing, independently of where it was placed.
    """
    # The component authors NO graphics, so F.SilkS carries the designator strokes
    # and NOTHING else — every seed-library footprint ships its own silk outline,
    # which would otherwise be mixed into the same coordinate stream and mask the
    # designator's placement (K4: no procedural box is invented for it either).
    board = {
        "version": 1, "name": "refdes", "width_mm": 40, "height_mm": 30,
        "components": [{"ref": "A1", "footprint": "NOSILK",
                        "x_mm": 20.0, "y_mm": 10.0, "rotation_deg": 0.0,
                        "layer": "top",
                        "pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
                                  "drill_mm": 0.8, "annulus_diameter_mm": 1.6}]}],
        "nets": [],
    }
    files = gerber.build_gerbers(board, name="refdes")
    silk = files["refdes-F_SilkS.gbr"]

    # The part's OWN emitted position, read out of the copper — never a literal.
    # Everything below is relative to it, so the test asks "where is the text
    # relative to the part it labels", which is the question, rather than "is the
    # text at these coordinates", which a mirrored board can satisfy by accident.
    pad = _gerber_flash_points(files["refdes-F_Cu.gbr"])
    assert len(pad) == 1, pad
    part_y = pad[0][1]

    xd, yd = _fs_scale(silk)
    ys = [int(v) / 10 ** yd
          for _x, v in re.findall(r"X(-?\d+)Y(-?\d+)D0[12]\*", silk)]
    assert ys, "expected designator strokes on F.SilkS"

    assert min(ys) > part_y, (
        f"the designator spans Gerber y in [{min(ys)}, {max(ys)}], which is BELOW "
        f"the part at {part_y} — REFDES_LOCAL_Y_MM = {gerber.REFDES_LOCAL_Y_MM} "
        f"means ABOVE the part, and above is GREATER y in the Y-UP Gerber frame")

    # Upright, not mirrored: the glyph baseline sits at the anchor and the caps
    # rise ~1 mm ABOVE it. Emitted unconverted the same glyph hangs below it,
    # because stroke_font draws cap height at NEGATIVE local y (Y-DOWN, like the
    # board) — so this is the assertion that catches the upside-down designator.
    anchor_y = part_y - gerber.REFDES_LOCAL_Y_MM   # y0 placed into the gerber frame
    above = [y for y in ys if y > anchor_y + 1e-6]
    below = [y for y in ys if y < anchor_y - 1e-6]
    assert len(above) > len(below), (
        f"the designator renders UPSIDE-DOWN: {len(above)} stroke points above "
        f"its baseline at {anchor_y} vs {len(below)} below (span "
        f"[{min(ys)}, {max(ys)}], part at {part_y}).")
    assert max(ys) > anchor_y + 0.5 * gerber.REFDES_TEXT_SIZE_MM, (
        f"expected roughly a cap height of ink above the baseline, got "
        f"{max(ys) - anchor_y}")


@pytest.mark.skipif(not _kicad_cli_available(),
                    reason="kicad-cli not on PATH (dev/CI oracle)")
def test_flash_positions_match_kicad_cli_export():
    """INDEPENDENT CONFIRMATION that the frame we converted TO is the right one.

    The self-consistency test above proves our output stopped contradicting
    ITSELF; it cannot, on its own, prove we did not make both halves consistently
    wrong. kicad-cli is the one authority in this repo that is not built from our
    emitter, our goldens or gerber-writer, so its export of the SAME board is the
    check that our flashes land where a real toolchain puts them — in X and, the
    whole point here, in Y.

    This is the falsifier described in docket 019fa8011555: it FAILED before the
    conversion existed (every Y exactly negated) and passes after it."""
    from pcb_worker import kicad
    from tests.oracle.kicad_drc import export_gerbers_on_pcb_text

    rb = _compile_board_ir(_rotated_pad_board(name="oracle"))

    ours = sorted((round(x, 4), round(y, 4)) for x, y in _gerber_flash_points(
        gerber.build_gerbers_ir(rb, name="oracle")["oracle-F_Cu.gbr"]))

    pcb = kicad.generate_ir(rb, base_name="oracle")["oracle.kicad_pcb"]
    exported = export_gerbers_on_pcb_text(pcb, ["F.Cu", "B.Cu", "Edge.Cuts"],
                                          name="oracle")
    theirs_text = next(v for k, v in exported.items() if "F_Cu" in k)
    theirs = sorted((round(x, 4), round(y, 4))
                    for x, y in _gerber_flash_points(theirs_text))

    assert ours == theirs, (
        "our flash positions disagree with kicad-cli's for the same board.\n"
        f"  ours  : {ours}\n  kicad : {theirs}\n"
        + ("EVERY Y IS EXACTLY NEGATED — the board frame is reaching the Gerber "
           "unconverted (bug 019fa8011555)."
           if sorted((x, -y) for x, y in ours) == theirs else ""))


# ---------------------------------------------------------------------------
# Gerber X2 JOB FILE (.gbrjob) — the fabrication manifest (F1).
#
# Every structural expectation below was MEASURED from a real KiCad 10.0.5
# `kicad-cli pcb export gerbers` of this repo's own spike board, not invented from
# the Gerber X2 spec: the key set, the file naming, the ProjectId GUID, the
# FileFunction vocabulary, the Size convention and the default stackup numbers.
# ---------------------------------------------------------------------------

import json as _json

# Captured from KiCad 10.0.5's own export of a project named `board.kicad_pcb`.
# The GUID is a pure function of the project FILE name, so this is a stable,
# externally-sourced fixture — the anti-circularity anchor for _project_guid.
_KICAD_GUID_FOR_BOARD = "626f6172-642e-46b6-9963-61645f706362"
_KICAD_JOB_TOP_LEVEL_KEYS = ["Header", "GeneralSpecs", "DesignRules",
                             "FilesAttributes", "MaterialStackup"]


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_job_file_is_emitted_and_named_like_kicads(board_path, base, builder):
    """KiCad writes `<base>-job.gbrjob`, NOT `<base>.gbrjob`."""
    files = builder(board_path, base)
    assert f"{base}-job.gbrjob" in files, sorted(files)
    assert sum(1 for k in files if k.endswith(".gbrjob")) == 1


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_job_file_structure_matches_kicads(board_path, base, builder):
    job = _json.loads(builder(board_path, base)[f"{base}-job.gbrjob"])
    assert list(job) == _KICAD_JOB_TOP_LEVEL_KEYS
    assert list(job["GeneralSpecs"]) == ["ProjectId", "Size", "LayerNumber",
                                         "BoardThickness", "Finish"]
    assert list(job["GeneralSpecs"]["ProjectId"]) == ["Name", "GUID", "Revision"]
    assert list(job["DesignRules"][0]) == ["Layers", "PadToPad", "PadToTrack",
                                           "TrackToTrack", "MinLineWidth"]
    assert job["GeneralSpecs"]["LayerNumber"] == len(_declared_layers(board_path))
    assert job["GeneralSpecs"]["Finish"] == "None"
    assert job["GeneralSpecs"]["ProjectId"]["Name"] == base


def test_job_file_project_guid_reproduces_kicads_exactly():
    """The GUID derivation is KiCad's, verified against KiCad's own output.

    A plausible-but-wrong reimplementation (REPLACING the version/variant nibbles
    instead of INSERTING them, or padding with NUL instead of 'X') produces a
    different GUID and fails here."""
    files = build_fab(SPIKE_BOARD, "board")
    job = _json.loads(files["board-job.gbrjob"])
    assert job["GeneralSpecs"]["ProjectId"]["GUID"] == _KICAD_GUID_FOR_BOARD
    # Pinned at the unit level too, across the pad / exact-fit / truncate cases.
    assert gerber._project_guid("a.kicad_pcb") == "612e6b69-6361-4645-9f70-636258585858"
    assert gerber._project_guid("zz.kicad_pcb") == "7a7a2e6b-6963-4616-945f-706362585858"
    assert gerber._project_guid("abcdefghijklmnopqrstuvwxyz.kicad_pcb") == \
        "61626364-6566-4676-9869-6a6b6c6d6e6f"


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_job_manifest_lists_exactly_the_emitted_gerber_layers(board_path, base, builder):
    """THE load-bearing property: the manifest describes the package that was
    actually produced. A job file advertising a layer the fab house will not find
    — or omitting one it will — is worse than no job file at all.

    This is also what makes the manifest survive adding B.SilkS/F.Paste/B.Paste
    later without an edit: it is built from the emitted file set, so the table of
    known layer functions can name layers nobody emits yet without inventing rows.
    """
    files = builder(board_path, base)
    job = _json.loads(files[f"{base}-job.gbrjob"])
    listed = [f["Path"] for f in job["FilesAttributes"]]
    emitted = sorted(k for k in files if k.endswith(".gbr"))
    assert sorted(listed) == emitted, (listed, emitted)
    assert len(listed) == len(set(listed)), "duplicate manifest rows"


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_job_manifest_declares_solder_mask_negative_and_the_rest_positive(
        board_path, base, builder):
    """Solder mask is the ONE negative-polarity layer — the file draws OPENINGS.
    Get this wrong and the mask fabricates inverted."""
    job = _json.loads(builder(board_path, base)[f"{base}-job.gbrjob"])
    for entry in job["FilesAttributes"]:
        expected = "Negative" if "_Mask" in entry["Path"] else "Positive"
        assert entry["FilePolarity"] == expected, entry


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_job_manifest_uses_the_job_files_own_filefunction_vocabulary(
        board_path, base, builder):
    """The .gbrjob FileFunction tokens are NOT the in-file TF.FileFunction tokens.
    Measured on the same KiCad export: job `SolderMask,Top` vs file
    `Soldermask,Top`; job `Profile` vs file `Profile,NP`. Deriving the manifest
    value from the emitted layer's own function string yields the wrong words."""
    files = builder(board_path, base)
    job = _json.loads(files[f"{base}-job.gbrjob"])
    by_path = {f["Path"]: f["FileFunction"] for f in job["FilesAttributes"]}
    assert by_path[f"{base}-F_Mask.gbr"] == "SolderMask,Top"
    assert by_path[f"{base}-B_Mask.gbr"] == "SolderMask,Bot"
    assert by_path[f"{base}-Edge_Cuts.gbr"] == "Profile"
    assert by_path[f"{base}-F_Cu.gbr"] == "Copper,L1,Top"
    # B.Cu's L-number is the STACK DEPTH (L2 on 2-layer, L4 on quadlayer).
    n = len(_declared_layers(board_path))
    assert by_path[f"{base}-B_Cu.gbr"] == f"Copper,L{n},Bot"
    assert by_path[f"{base}-F_SilkS.gbr"] == "Legend,Top"
    # ... and the emitted LAYER still carries its own, different token.
    assert "TF.FileFunction,Soldermask,Top" in files[f"{base}-F_Mask.gbr"]
    assert "TF.FileFunction,Profile,NP" in files[f"{base}-Edge_Cuts.gbr"]


def test_job_size_is_the_outline_grown_by_the_edge_cuts_stroke():
    """KiCad's Size convention: the profile line straddles the nominal edge, so the
    plotted extent is the outline PLUS the stroke width (KiCad reported 40.15 x
    30.15 for this 40 x 30 board at a 0.15 stroke). Derived from the constant, so
    it tracks the Edge.Cuts width instead of restating it."""
    job = _json.loads(build_fab(SPIKE_BOARD, "board")["board-job.gbrjob"])
    board = _load(SPIKE_BOARD)
    assert job["GeneralSpecs"]["Size"]["X"] == pytest.approx(
        board["width_mm"] + gerber.EDGE_CUTS_WIDTH_MM)
    assert job["GeneralSpecs"]["Size"]["Y"] == pytest.approx(
        board["height_mm"] + gerber.EDGE_CUTS_WIDTH_MM)


def test_job_material_stackup_sums_to_the_declared_board_thickness():
    """The stackup is a physical claim, not decoration: its thicknesses must add up
    to the BoardThickness the same file declares, or the fab house is handed two
    contradictory numbers. (KiCad's own 2-layer output: 1.6 = 2x0.035 copper +
    2x0.01 mask + 1.51 dielectric — which is what this reproduces.)"""
    job = _json.loads(build_fab(SPIKE_BOARD, "board")["board-job.gbrjob"])
    total = sum(e.get("Thickness", 0.0) for e in job["MaterialStackup"])
    assert total == pytest.approx(job["GeneralSpecs"]["BoardThickness"])
    kinds = [e["Type"] for e in job["MaterialStackup"]]
    assert kinds[0] == "Legend" and kinds[-1] == "Legend"
    assert kinds.count("Copper") == job["GeneralSpecs"]["LayerNumber"]


def test_job_file_is_byte_reproducible():
    """Same board twice -> identical manifest bytes (the CreationDate stamp is
    pinned and the GUID is a pure function of the name), so the job file cannot
    break the determinism gate."""
    a = build_fab(SPIKE_BOARD, "board")["board-job.gbrjob"]
    b = build_fab(SPIKE_BOARD, "board")["board-job.gbrjob"]
    assert a == b


def test_job_file_is_not_mistaken_for_a_gerber_layer():
    """`.gbrjob` must not be counted as a plotted layer by anything that filters on
    `.gbr` — including the geometry-diff harness, which suffix-matches. Guards the
    exact trap that `"x.gbrjob".endswith(".gbr")` is False but `.startswith` /
    `in` tests would say otherwise."""
    files = build_fab(SPIKE_BOARD, "board")
    assert sum(1 for k in files if k.endswith(".gbr")) == len(EMITTED_GERBER_SUFFIXES)
    assert sum(1 for k in files if k.endswith(".drl")) == 2
    assert not any(k.endswith(".gbr") for k in files if k.endswith(".gbrjob"))


# ---------------------------------------------------------------------------
# Mask polarity self-consistency (bug 019fb0c348f2, fixed epoch CPN1)
# ---------------------------------------------------------------------------


def test_mask_polarity_agrees_between_gbr_and_job_manifest():
    """The package must never contradict itself about mask polarity: the mask
    .gbr files declare TF.FilePolarity,Negative (mask features are OPENINGS —
    absence of material; KiCad 10.0.5 and 7.0.6 both emit Negative), the body
    stays %LPD, the job manifest says Negative for the same files, and every
    NON-mask layer stays Positive on both sides of the package. Before the
    fix the .gbr said Positive while the manifest said Negative — a house
    trusting the file attribute fabricated the mask inverted."""
    import json

    from pcb_worker.gerber import build_gerbers

    board = yaml.safe_load(
        (Path(__file__).resolve().parent / "testdata" / "gerber_boards"
         / "drilltest.yaml").read_text(encoding="utf-8"))
    files = build_gerbers(board)
    job = json.loads(next(t for n, t in files.items() if n.endswith(".gbrjob")))
    job_polarity = {f["Path"]: f["FilePolarity"]
                    for f in job["FilesAttributes"]}

    for name, text in files.items():
        if not name.endswith(".gbr"):
            continue
        declared = [ln for ln in text.splitlines() if "FilePolarity" in ln]
        assert declared, name
        is_mask = "F_Mask" in name or "B_Mask" in name
        expected = "Negative" if is_mask else "Positive"
        assert expected in declared[0], (name, declared[0])
        assert job_polarity[name] == expected, (name, job_polarity[name])
        if is_mask and "%LPD*%" in text:
            # The flag changes the FILE attribute only — bodies stay dark.
            assert "%LPC*%" not in text.split("%LPD*%")[0]


# ---------------------------------------------------------------------------
# N-layer emission (epoch GA-3; this section held the GA-1 fail-closed seals
# until the per-layer emitter landed). The IR path now fabricates the declared
# stack completely; the LOOSE-dict gerber entry keeps its seal PERMANENTLY —
# that path has no compiler and no profile capability ceiling in front of it,
# so deep boards must go through compile + build_gerbers_ir.
# ---------------------------------------------------------------------------


def _four_layer_board_dict() -> dict:
    return {
        "version": 1, "name": "quad", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "in1", "in2", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4,
                         "rule_profile": "jlcpcb-4layer"},
        "components": [],
    }


def test_build_gerbers_ir_emits_every_declared_copper_layer():
    """FLIPPED at GA-3 (was ..._refuses_a_deeper_stack): a 4-layer board's file
    set carries all four copper Gerbers in stack order, and the .gbrjob
    manifest renumbers B.Cu to L4 with the two inner rows between."""
    import json

    ir = _compile_board_ir(_four_layer_board_dict())
    assert len(ir.layer_stack.copper) == 4
    files = gerber.build_gerbers_ir(ir)
    for suffix in ("F_Cu", "In1_Cu", "In2_Cu", "B_Cu"):
        assert f"quad-{suffix}.gbr" in files, sorted(files)
    # Per-layer .gbrjob truth: L-numbers renumbered, inner rows present.
    job = json.loads(files["quad-job.gbrjob"])
    assert job["GeneralSpecs"]["LayerNumber"] == 4
    copper_rows = {f["Path"]: f["FileFunction"]
                   for f in job["FilesAttributes"]
                   if f["FileFunction"].startswith("Copper")}
    assert copper_rows == {
        "quad-F_Cu.gbr": "Copper,L1,Top",
        "quad-In1_Cu.gbr": "Copper,L2,Inr",
        "quad-In2_Cu.gbr": "Copper,L3,Inr",
        "quad-B_Cu.gbr": "Copper,L4,Bot",
    }
    # Stack order in the manifest: copper first, F -> inner -> B.
    paths = [f["Path"] for f in job["FilesAttributes"]]
    assert paths[:4] == ["quad-F_Cu.gbr", "quad-In1_Cu.gbr",
                        "quad-In2_Cu.gbr", "quad-B_Cu.gbr"]
    # The inner copper files carry the Inr copper attribute, not Top/Bot.
    assert "Copper,L2,Inr" in files["quad-In1_Cu.gbr"]
    assert "Copper,L3,Inr" in files["quad-In2_Cu.gbr"]
    assert "Copper,L4,Bot" in files["quad-B_Cu.gbr"]


def test_a_two_layer_board_gains_no_new_files_from_the_nlayer_emitter():
    """The other half of the flip: the generalized loop emits EXACTLY the
    nine baseline suffixes for a 2-layer board — byte-identity with the old
    straight-line blocks is the goldens' job, file-SET identity is this
    one's."""
    board = _load(SPIKE_BOARD)
    ir = _compile_board_ir(board)
    files = gerber.build_gerbers_ir(ir, name="board")
    gbr_suffixes = {n[len("board-"):-len(".gbr")]
                    for n in files if n.endswith(".gbr")}
    assert gbr_suffixes == set(gerber._GERBER_SUFFIXES)


def test_build_gerbers_loose_dict_still_refuses_a_declared_deeper_stack():
    """PERMANENT seal (GA-3 decision, comment 1198 D2): the loose path has no
    compiler and no capability ceiling, so it never emits deep stacks."""
    with pytest.raises(ValueError, match="silently drops inner copper"):
        gerber.build_gerbers({"name": "quad", "width_mm": 20, "height_mm": 20,
                              "layers": ["top", "in1", "in2", "bottom"],
                              "components": []})


def test_generate_kicad_pcb_emits_a_stack_driven_layer_table_and_via_spans():
    """FLIPPED at GA-3 (was ..._refuses_a_declared_deeper_stack): the KiCad-9
    layer table carries the declared stack on the even copper ids (F=0,
    In1=4, In2=6, B=2) and a via writes its own span."""
    from pcb_worker import kicad

    text = kicad.generate_kicad_pcb(
        {"name": "quad", "width_mm": 20, "height_mm": 20,
         "layers": ["top", "in1", "in2", "bottom"],
         "components": [], "nets": [], "traces": [
             {"net": "", "layer": "in1", "width_mm": 0.3,
              "points": [{"x_mm": 2, "y_mm": 2}, {"x_mm": 8, "y_mm": 2}]}],
         "vias": [{"x_mm": 5, "y_mm": 5, "diameter_mm": 0.8, "drill_mm": 0.4,
                   "from_layer": "top", "to_layer": "bottom"}]})
    assert '(0 "F.Cu" signal)' in text
    assert '(4 "In1.Cu" signal)' in text
    assert '(6 "In2.Cu" signal)' in text
    assert '(2 "B.Cu" signal)' in text
    # Inner trace emits its KiCad alias, never the canonical id verbatim.
    assert '(layer "In1.Cu")' in text
    assert '(layer "in1")' not in text
    # U5: the via span is the via's own (through) span.
    assert '(layers "F.Cu" "B.Cu")' in text


def test_harvested_copper_outside_the_declared_stack_fails_closed():
    """The stray-layer guard that replaced the GA-1 seal: copper bucketed for
    a layer the stack does not declare must raise, never silently miss every
    file (the K4 discards clause, one level deeper)."""
    g = gerber._Geometry()
    g.traces_inner["in3"] = [(1.0, 1.0, 2.0, 1.0, 0.3)]
    with pytest.raises(ValueError, match="outside the declared stack"):
        gerber._build_gerber_layers({"width_mm": 10, "height_mm": 10}, g,
                                    "2024-01-01T00:00:00+00:00",
                                    copper_ids=("top", "in1", "in2", "bottom"))


def test_generate_kicad_pcb_refuses_a_malformed_stack_shape():
    from pcb_worker import kicad

    with pytest.raises(ValueError, match="inner entry 1 must be 'in1'"):
        kicad.generate_kicad_pcb({"name": "bad", "width_mm": 20, "height_mm": 20,
                                  "layers": ["top", "in2", "bottom"],
                                  "components": [], "nets": [], "traces": [],
                                  "vias": []})


def test_two_layer_declarations_still_emit():
    # The seal is depth-scoped, not declaration-scoped: an explicit
    # ["top","bottom"] (and the absent-key default other suites cover) emits
    # exactly as ever.
    board = {"name": "duo", "width_mm": 20, "height_mm": 20,
             "layers": ["top", "bottom"], "components": []}
    files = gerber.build_gerbers(board)
    assert any(name.endswith("-F_Cu.gbr") for name in files)
