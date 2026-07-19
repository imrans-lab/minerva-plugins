"""GOLDEN GEOMETRY-DIFF harness (docket SB.2) — regression + teeth + registration.

This is a REAL functional test (no mocking): it runs the production emitter
``pcb_worker.gerber.build_gerbers`` to produce real bytes, parses them with real
gerbonara, and diffs at the GEOMETRY level (NOT bytes — SB.3 owns bytes).

  * ``test_regression_drift_pin`` pins the emitter output against the captured
    drift-pin snapshot (empty delta). This detects DRIFT, it does NOT assert
    correctness — the snapshot is captured from the emitter under test and is
    blessed=false by design (see golden_emitter/README.md, provenance.py).
  * ``test_teeth_*`` prove the diff DETECTS a real perturbation of a parsed
    golden (a moved pad / a removed drill) — proof the empty delta above is
    meaningful, not a diff that can't see anything.
  * ``test_current_diverges_from_spike_golden`` documents the anti-circularity
    finding: the emitter's geometry currently DIFFERS from the independent,
    structurally-validated spike golden (placeholder SMD pad geometry). The
    correctness verdict on that golden is gated by provenance (see
    test_provenance.py), not asserted here.
"""

from __future__ import annotations

import copy
from pathlib import Path

import yaml

from pcb_worker import gerber, resolve
from tests.oracle.geometry_diff import (
    diff_geometry,
    load_output_dir,
    parse_output_set,
    registration_violations,
)

HERE = Path(__file__).resolve().parent                 # pcb/worker/tests/oracle
SPIKE_BOARD = HERE.parents[2] / "spikes" / "gerber" / "board.yaml"
SPIKE_GOLDEN_DIR = HERE.parents[2] / "spikes" / "gerber" / "golden"
SNAPSHOT_DIR = HERE / "golden_emitter"                 # emitter drift-pin snapshot


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _emit() -> dict[str, str]:
    """Real emitter output for the spike board (name='board' to match goldens).

    Best-effort resolved first, as the production fab path does (step 4a-ii) —
    the raw spike fails closed (SMD pins carry no inline geometry)."""
    return gerber.build_gerbers(resolve.resolve_board_best_effort(_load(SPIKE_BOARD)),
                                name="board")


# ---------------------------------------------------------------------------
# Sanity: a set diffed against itself is empty; registration holds.
# ---------------------------------------------------------------------------


def test_diff_identical_is_empty():
    cur = parse_output_set(_emit())
    assert diff_geometry(cur, cur).is_empty


def test_current_output_registration_holds():
    """Every plated drill in the live emitter output lands on a copper flash;
    the non-plated mounting hole intentionally has none."""
    violations = registration_violations(parse_output_set(_emit()))
    assert violations == [], f"plated drill(s) with no copper annulus: {violations}"


# ---------------------------------------------------------------------------
# TASK 2 — regression / drift pin: current emitter == drift-pin snapshot.
# ---------------------------------------------------------------------------


def test_regression_drift_pin():
    """Live emitter output == captured drift-pin snapshot -> EMPTY geometry delta.

    Drift pin ONLY: proves the emitter still agrees with its frozen self, NOT
    that either is correct (the snapshot is blessed=false, captured from the
    emitter under test). If this fails, the emitter geometry changed — review
    the delta and, if intended, regenerate via scripts/capture_emitter_golden.py.
    """
    current = parse_output_set(_emit())
    golden = parse_output_set(load_output_dir(SNAPSHOT_DIR))
    diff = diff_geometry(current, golden)
    assert diff.is_empty, "emitter drifted from the snapshot:\n" + diff.describe()


# ---------------------------------------------------------------------------
# TASK 3 — teeth: the diff DETECTS a real perturbation of a PARSED golden.
# ---------------------------------------------------------------------------


def test_teeth_moved_pad_is_detected():
    """Parse the golden, MOVE one F_Cu pad on a copied model, diff -> non-empty
    delta naming both the vanished old pad and the new one."""
    golden = parse_output_set(load_output_dir(SNAPSHOT_DIR))
    perturbed = copy.deepcopy(golden)

    fcu = perturbed.layers["F_Cu"]
    flash_keys = [k for k in fcu.objects if k[0] == "flash"]
    assert flash_keys, "precondition: F_Cu has flashes to move"
    victim = flash_keys[0]
    (x, y), apsig = victim[1], victim[2]
    moved = ("flash", (round(x + 5.0, 4), y), apsig)   # shift +5mm in X
    fcu.objects[victim] -= 1
    if fcu.objects[victim] == 0:
        del fcu.objects[victim]
    fcu.objects[moved] += 1

    diff = diff_geometry(perturbed, golden)
    assert not diff.is_empty, "diff FAILED to detect a moved pad"
    flash_deltas = [d for d in diff.deltas if d.category == "flash" and d.layer == "F_Cu"]
    # One pad vanished from the old spot, one appeared at the new spot.
    assert any(d.change == "added" and str((round(x + 5.0, 4), y)) in d.detail
               for d in flash_deltas), diff.describe()
    assert any(d.change == "removed" and str((round(x, 4), round(y, 4))) in d.detail
               for d in flash_deltas), diff.describe()


def test_teeth_removed_drill_is_detected():
    """Remove one PTH drill hit on a copied parsed model; diff -> a 'removed'
    drill delta naming its diameter, plus the registration loss."""
    golden = parse_output_set(load_output_dir(SNAPSHOT_DIR))
    perturbed = copy.deepcopy(golden)

    pth = perturbed.drills["PTH"]
    victim = sorted(pth)[0]  # deterministic
    pth[victim] -= 1
    if pth[victim] == 0:
        del pth[victim]

    diff = diff_geometry(perturbed, golden)
    assert not diff.is_empty, "diff FAILED to detect a removed drill"
    drill_deltas = [d for d in diff.deltas if d.category == "drill"]
    assert any(d.change == "removed" and f"Ø{victim[2]}mm" in d.detail
               for d in drill_deltas), diff.describe()


def test_teeth_changed_pad_size_is_detected():
    """Resize one pad's aperture on a copied model; diff -> flash + aperture
    deltas (this is exactly the class of change the spike-golden divergence is)."""
    golden = parse_output_set(load_output_dir(SNAPSHOT_DIR))
    perturbed = copy.deepcopy(golden)

    fcu = perturbed.layers["F_Cu"]
    victim = next(k for k in fcu.objects if k[0] == "flash" and k[2][0] == "rectangle")
    bigger = ("flash", victim[1], ("rectangle", (("w", 9.9), ("h", 9.9))))
    fcu.objects[victim] -= 1
    if fcu.objects[victim] == 0:
        del fcu.objects[victim]
    fcu.objects[bigger] += 1
    fcu.apertures[("rectangle", (("w", 9.9), ("h", 9.9)))] += 1

    diff = diff_geometry(perturbed, golden)
    assert diff.categories() & {"flash", "aperture"}, diff.describe()


# ---------------------------------------------------------------------------
# Anti-circularity finding: the live emitter DIVERGES from the independent
# structurally-validated spike golden. Documented, not silently accepted. The
# correctness verdict is gated on provenance (see test_provenance.py).
# ---------------------------------------------------------------------------


def test_current_diverges_from_spike_golden():
    """The emitter's copper/mask/silk geometry differs from the independent
    spike golden (placeholder SMD pad defaults), but DRILLS + REGISTRATION agree.

    This is the anti-circularity signal working: an unblessed golden reveals real
    correctness drift. Kept as an assertion (not a skip) because it documents a
    KNOWN finding; if the emitter is later fixed to match, update this test.
    """
    current = parse_output_set(_emit())
    golden = parse_output_set(load_output_dir(SPIKE_GOLDEN_DIR))
    diff = diff_geometry(current, golden)

    assert not diff.is_empty, "expected the known emitter/spike-golden divergence"
    # The parts that ARE correct must match: drills and drill-to-copper reg.
    assert not any(d.category in ("drill", "registration") for d in diff.deltas), (
        "drills/registration should already agree with the spike golden:\n"
        + diff.describe()
    )
    # The divergence is confined to copper/mask/silk (pad geometry), no outline.
    assert diff.layers_changed() <= {"F_Cu", "B_Cu", "F_Mask", "B_Mask", "F_SilkS"}, (
        "divergence spread beyond copper/mask/silk:\n" + diff.describe()
    )
