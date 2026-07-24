"""gerbonara round-trip of the CURRENT exporter output — Gerber + Excellon.

Complements ``tests/test_gerbers.py``'s pygerber round-trip. pygerber reads only
RS-274X Gerber; it does NOT parse Excellon drill files. gerbonara is the ADDITIVE
reader whose whole justification here is the Excellon drill parse (needed later
for drill-to-copper registration). This is a REAL functional test: it runs the
production ``pcb_worker.gerber.build_gerbers`` emitter to produce real bytes, then
reads every Gerber layer AND both drill files back with gerbonara.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tests.gerber_fab import build_fab, build_raw_emitter

gerbonara = pytest.importorskip("gerbonara")
from gerbonara import ExcellonFile, GerberFile  # noqa: E402

HERE = Path(__file__).resolve().parent  # pcb/worker/tests/oracle
SPIKE_BOARD = HERE.parents[2] / "spikes" / "gerber" / "board.yaml"  # pcb/spikes/...
DRILL_BOARD = HERE.parent / "testdata" / "gerber_boards" / "drilltest.yaml"

# (board path, base name, expected total drill-hit count across PTH+NPTH, builder).
# Spike -> PRODUCTION fab path (compile -> IR); drilltest -> raw loose-dict emitter
# (explicit drift fixture, non-library footprints), NOT a production oracle.
CASES = [
    pytest.param(SPIKE_BOARD, "board", 3, build_fab, id="board-production"),
    pytest.param(DRILL_BOARD, "drilltest", 6, build_raw_emitter, id="drilltest-raw"),
]


@pytest.mark.parametrize("board_path,base,expected_drills,builder", CASES)
def test_gerbonara_reads_current_exporter_output(board_path, base, expected_drills, builder):
    files = builder(board_path, base)

    gbrs = {n: t for n, t in files.items() if n.endswith(".gbr")}
    drls = {n: t for n, t in files.items() if n.endswith(".drl")}

    # --- Gerber layers: gerbonara reads each back without error. ---
    assert len(gbrs) == 6, f"expected six gerber layers, got {sorted(gbrs)}"
    total_apertures = 0
    for name, text in gbrs.items():
        gf = GerberFile.from_string(text, filename=name)
        # A legend/silk layer is legitimately EMPTY when no component authored F.SilkS
        # graphics (K4: the procedural courtyard box is retired). It must still PARSE
        # cleanly; it just carries no apertures. Every fabrication-bearing layer
        # (copper/mask/edge) is still required non-empty.
        if name.endswith("F_SilkS.gbr") and gf.is_empty:
            continue
        assert not gf.is_empty, f"{name}: gerbonara read an empty layer"
        apertures = list(gf.apertures())
        assert apertures, f"{name}: no apertures/pads parsed"
        total_apertures += len(apertures)
    assert total_apertures > 0, "no apertures across any layer"

    # --- Excellon drills: THE gerbonara justification (pygerber can't do this).
    assert drls, f"{base}: exporter emitted no drill files to round-trip"
    total_hits = 0
    for name, text in drls.items():
        ef = ExcellonFile.from_string(text, filename=name)
        assert not ef.is_empty, f"{name}: gerbonara read an empty drill file"
        sizes = ef.drill_sizes()
        assert sizes, f"{name}: no tool/drill sizes parsed"
        assert all(d > 0 for d in sizes), f"{name}: non-positive drill diameter"
        hits = ef.hit_count()
        total_hits += sum(hits.values())

    # Drill hole count > 0 is the load-bearing assertion for this reader.
    assert total_hits > 0, f"{base}: gerbonara parsed zero drill hits"
    assert total_hits == expected_drills, (
        f"{base}: expected {expected_drills} drill hits, gerbonara read {total_hits}"
    )


def test_gerbonara_excellon_reads_plated_and_nonplated_split():
    """The exporter's PTH/NPTH split both round-trip through gerbonara's Excellon
    parser with the expected per-file hole counts (spike board: 2 plated, 1 non-
    plated)."""
    files = build_fab(SPIKE_BOARD, "board")

    pth = ExcellonFile.from_string(files["board-PTH.drl"], filename="board-PTH.drl")
    npth = ExcellonFile.from_string(files["board-NPTH.drl"], filename="board-NPTH.drl")

    assert sum(pth.hit_count().values()) == 2, "spike PTH: expected 2 plated holes"
    assert sum(npth.hit_count().values()) == 1, "spike NPTH: expected 1 non-plated hole"
    # Diameters read back at the emitted precision.
    assert sorted(round(d, 3) for d in pth.drill_sizes()) == [0.4, 0.8]
    assert sorted(round(d, 3) for d in npth.drill_sizes()) == [3.2]
