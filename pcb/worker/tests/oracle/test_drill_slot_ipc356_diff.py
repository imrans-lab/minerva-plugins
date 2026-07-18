"""ROUTED-SLOT + IPC-356 diff harness (docket bug 019f7772eca0).

Extends the SB.2 geometry-diff harness so a slot-bearing Excellon file and an
IPC-356 netlist can be diffed. Layer-1 functional floor: every test diffs REAL
files emitted by the ratified gerbonara coupon (spikes/cam/gerbonara_coupon.py),
written to disk and read back — never a synthetic in-memory stub.

  * ``test_slot_*`` prove a routed slot round-trips through the drill diff WITHOUT
    crashing (regression for the bug) and that perturbing it is detected (teeth).
  * ``test_point_drill_removed_*`` proves point drills keep their old behaviour.
  * ``test_ipc356_*`` prove the netlist diff: identical -> empty, a changed or
    removed record -> non-empty, correctly-named delta (teeth).
"""

from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path

import pytest

from tests.oracle.geometry_diff import (
    OutputGeometry,
    diff_geometry,
    diff_ipc356_files,
    diff_netlists,
    parse_drill_file,
    parse_ipc356_file,
    parse_output_set,
    registration_violations,
)

HERE = Path(__file__).resolve().parent                       # pcb/worker/tests/oracle
SPIKE = HERE.parents[2] / "spikes" / "cam" / "gerbonara_coupon.py"


def _load_coupon():
    """Import the ratified gerbonara coupon spike (read-only) as a module."""
    spec = importlib.util.spec_from_file_location("gerbonara_coupon", SPIKE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("gerbonara_coupon", mod)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def emitted_dir(tmp_path_factory) -> Path:
    """Real coupon output written to disk (Gerbers + slot-bearing PTH + IPC-356)."""
    files = _load_coupon().build()
    d = tmp_path_factory.mktemp("coupon")
    for name, text in files.items():
        (d / name).write_text(text, encoding="utf-8")
    return d


@pytest.fixture
def pth_text(emitted_dir) -> str:
    return (emitted_dir / "board-PTH.drl").read_text(encoding="utf-8")


@pytest.fixture
def ipc356_text(emitted_dir) -> str:
    return (emitted_dir / "board.ipc356").read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# TASK 1 — routed slot support: regression + teeth.
# ---------------------------------------------------------------------------


def test_slot_roundtrips_without_crashing(pth_text):
    """The real PTH file carries a routed slot (a gerbonara Line). Parsing it no
    longer crashes, and the slot appears as its own keyed feature."""
    hits = parse_drill_file(pth_text, "board-PTH.drl")          # would crash pre-fix
    slots = [k for k in hits if k and k[0] == "slot"]
    assert slots, f"expected a routed slot key in parsed drills, got {list(hits)}"
    # Point drills coexist unchanged (3-float keys).
    points = [k for k in hits if k and k[0] != "slot"]
    assert points and all(len(k) == 3 and isinstance(k[0], float) for k in points)


def test_identical_drills_empty_delta(emitted_dir):
    """A slot-bearing output set diffed against itself -> empty delta (no crash)."""
    og = parse_output_set(
        {f.name: f.read_text(encoding="utf-8")
         for f in emitted_dir.iterdir() if f.suffix in (".gbr", ".drl")}
    )
    assert diff_geometry(og, og).is_empty
    # And the slot did not spuriously register as a plated hole missing copper.
    assert registration_violations(og) == []


def test_teeth_moved_slot_endpoint_is_detected(pth_text):
    """Move one slot endpoint on a PARSED copy -> non-empty delta naming the slot
    (both the vanished original and the moved slot)."""
    golden = parse_drill_file(pth_text, "board-PTH.drl")
    perturbed = copy.deepcopy(golden)

    victim = next(k for k in perturbed if k[0] == "slot")
    (p_lo, p_hi), width = victim[1], victim[2]
    moved_pt = (round(p_hi[0] + 5.0, 4), p_hi[1])              # shift far endpoint +5mm X
    moved = ("slot", tuple(sorted((p_lo, moved_pt))), width)
    perturbed[victim] -= 1
    if perturbed[victim] == 0:
        del perturbed[victim]
    perturbed[moved] += 1

    Out = OutputGeometry
    diff = diff_geometry(Out(drills={"PTH": perturbed}), Out(drills={"PTH": golden}))
    assert not diff.is_empty, "diff FAILED to detect a moved slot"
    slot_deltas = [d for d in diff.deltas if d.category == "slot"]
    assert any(d.change == "added" and str(moved_pt) in d.detail for d in slot_deltas), diff.describe()
    assert any(d.change == "removed" and str(p_hi) in d.detail for d in slot_deltas), diff.describe()


def test_teeth_resized_slot_width_is_detected(pth_text):
    """Change a slot's width on a parsed copy -> non-empty slot delta."""
    golden = parse_drill_file(pth_text, "board-PTH.drl")
    perturbed = copy.deepcopy(golden)

    victim = next(k for k in perturbed if k[0] == "slot")
    wider = ("slot", victim[1], round(victim[2] + 0.5, 4))
    perturbed[victim] -= 1
    if perturbed[victim] == 0:
        del perturbed[victim]
    perturbed[wider] += 1

    Out = OutputGeometry
    diff = diff_geometry(Out(drills={"PTH": perturbed}), Out(drills={"PTH": golden}))
    slot_deltas = [d for d in diff.deltas if d.category == "slot"]
    assert any(f"Ø{wider[2]}mm" in d.detail and d.change == "added" for d in slot_deltas), diff.describe()


def test_teeth_removed_point_drill_is_detected(pth_text):
    """Remove one point drill on a parsed copy -> a 'removed' drill delta (slots
    present alongside must not interfere)."""
    golden = parse_drill_file(pth_text, "board-PTH.drl")
    perturbed = copy.deepcopy(golden)

    victim = next(k for k in sorted(perturbed, key=repr) if k[0] != "slot")
    perturbed[victim] -= 1
    if perturbed[victim] == 0:
        del perturbed[victim]

    Out = OutputGeometry
    diff = diff_geometry(Out(drills={"PTH": perturbed}), Out(drills={"PTH": golden}))
    drill_deltas = [d for d in diff.deltas if d.category == "drill"]
    assert any(d.change == "removed" and f"Ø{victim[2]}mm" in d.detail
               for d in drill_deltas), diff.describe()


# ---------------------------------------------------------------------------
# TASK 2 — IPC-356 netlist diff: identical + teeth.
# ---------------------------------------------------------------------------


def test_ipc356_identical_is_empty(ipc356_text):
    """A real IPC-356 netlist diffed against itself -> empty delta."""
    assert diff_ipc356_files(ipc356_text, ipc356_text).is_empty


def test_ipc356_parses_expected_records(ipc356_text):
    """Sanity: the coupon's four test records round-trip with net + location."""
    recs = parse_ipc356_file(ipc356_text)
    assert sum(recs.values()) == 4
    nets = {k[1] for k in recs}
    assert {"VCC", "GND"} <= nets


def test_teeth_changed_net_record_is_detected(ipc356_text):
    """Rename one record's net on a parsed copy -> non-empty delta (removed old
    net record + added new one)."""
    golden = parse_ipc356_file(ipc356_text)
    perturbed = copy.deepcopy(golden)

    victim = next(k for k in perturbed if k[1] == "VCC")
    changed = ("netlist", "SIGNAL_X", *victim[2:])
    perturbed[victim] -= 1
    if perturbed[victim] == 0:
        del perturbed[victim]
    perturbed[changed] += 1

    diff = diff_netlists(perturbed, golden)
    assert not diff.is_empty, "diff FAILED to detect a changed net record"
    net_deltas = [d for d in diff.deltas if d.category == "netlist"]
    assert any(d.change == "added" and "SIGNAL_X" in d.detail for d in net_deltas), diff.describe()
    assert any(d.change == "removed" and "'VCC'" in d.detail for d in net_deltas), diff.describe()


def test_teeth_removed_net_record_is_detected(ipc356_text):
    """Remove one record on a parsed copy -> a 'removed' netlist delta naming it."""
    golden = parse_ipc356_file(ipc356_text)
    perturbed = copy.deepcopy(golden)

    victim = next(k for k in sorted(perturbed, key=repr) if k[2])
    perturbed[victim] -= 1
    if perturbed[victim] == 0:
        del perturbed[victim]

    diff = diff_netlists(perturbed, golden)
    net_deltas = [d for d in diff.deltas if d.category == "netlist"]
    assert net_deltas and all(d.change == "removed" for d in net_deltas), diff.describe()
    assert str(victim[3]) in net_deltas[0].detail, diff.describe()
