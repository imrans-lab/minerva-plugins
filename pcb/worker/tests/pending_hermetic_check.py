"""PARKED — script-behavior pins for pcb/scripts/hermetic-fab-check.sh (C9).

NEVER EXECUTED this epoch (REGIME: parked python files are named ``pending_*``
so pytest's default ``test_*.py``/``*_test.py`` collection never picks this
file up — verified against pcb/worker/pyproject.toml's ``testpaths`` and no
``python_files`` override, same mechanism every other ``pending_*.py`` in this
directory already relies on).

These do NOT re-test the fabrication emitters (that is
``tests/test_determinism_gate.py``, STANDING GUARD 1, which already runs in
every CI). These pin the SCRIPT's own three fail-closed behaviors by driving
it as an actual subprocess — bash included — over a TINY fixture (a
componentless board plus one unplated mounting hole, just enough to clear the
script's minimum-manifest bar: 9 Gerber layers + job file + at least one
drill file + BOM + CPL, all always-written regardless of component count).
Kept intentionally small and self-contained so this file's own py_compile /
review does not require reading the full zone-fill fixture.

  1. test_min_manifest_fails_on_sub_minimum_tree — ``--self-test`` mode:
     asserts the script's own internal PASS-then-deliberately-break-then-FAIL
     proof (see hermetic-fab-check.sh's SELF-TEST section) actually runs and
     both directions succeed, via subprocess (not by reading the script).

  2. test_divergence_naming_identifies_first_offending_file — uses the
     script's TEST-ONLY ``HERMETIC_FAB_INJECT_DIVERGENCE`` env var (see the
     script's real-run section, right after the second compile) to force one
     named file to differ between the two runs, and asserts the script exits
     1 and NAMES that exact file in its output — never a bare "files differ"
     with no culprit identified.

  3. test_identical_tree_success — a plain, uninjected real run: asserts exit
     0 and a "GREEN" marker, proving the happy path is reachable at all (a
     suite that pins only the two failure modes could pass by accident if the
     happy path were broken).

  4. test_script_gerber_suffix_list_matches_fab_capability_authority — N3
     (review round 1): the script hardcodes its 9 Gerber suffixes rather
     than importing fab_capability.EMITTED_GERBER_SUFFIXES (deliberately —
     see the script's own comment at the GERBER_SUFFIXES= line: no
     import-time dependency on the worktree existing yet). That hardcode has
     no other guard against drift, so this pin reads the SCRIPT'S OWN TEXT
     (the same literal-anchor discipline pcb/tests/gd/EXPECTED_SUITES uses
     against run-gd-tests.sh's glob) and asserts the parsed set equals the
     authority's set — a 10th emitted layer added to fab_capability.py
     without a matching script edit fails HERE, not as a silent
     under-check in the real gate.

When this file is un-parked (renamed to test_hermetic_check.py) at the epoch
boundary, it needs no fixture file added to testdata/ — the tiny board is
inline below, and the subprocess calls create/clean their own tmp_path output
trees.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent  # pcb/worker/tests
REPO_ROOT = HERE.parents[2]  # pcb/worker/tests -> pcb/worker -> pcb -> repo root
SCRIPT = REPO_ROOT / "pcb" / "scripts" / "hermetic-fab-check.sh"

# Deliberately TINY and componentless: proves the script's minimum-manifest
# bar (9 Gerber suffixes + job + >=1 drill + BOM + CPL) is met by structure
# alone, not by this board carrying interesting geometry — that is what
# zone_fill.yaml (the DEFAULT board, extended by C9) is for. The one
# mounting hole exists ONLY to give the board a drill file to write (a truly
# empty board emits zero .drl files and would legitimately fail the
# script's own minimum-manifest check — a different, already-covered case,
# not what these three tests are pinning).
TINY_BOARD_YAML = """\
version: 1
name: hermetic-pin-fixture
width_mm: 10
height_mm: 10
layers: [top, bottom]
design_rules:
  clearance_mm: 0.2
  trace_width_mm: 0.25
  via_diameter_mm: 0.6
  via_drill_mm: 0.3
components: []
nets: []
mounting_holes:
- x_mm: 5.0
  y_mm: 5.0
  diameter_mm: 1.0
  plated: false
"""


@pytest.fixture
def tiny_board(tmp_path: Path) -> Path:
    board = tmp_path / "tiny.yaml"
    board.write_text(TINY_BOARD_YAML, encoding="utf-8")
    return board


def _run(args: list[str], env: dict | None = None) -> subprocess.CompletedProcess:
    import os
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        capture_output=True, text=True, timeout=120, env=full_env,
    )


def test_min_manifest_fails_on_sub_minimum_tree(tiny_board):
    """--self-test proves BOTH directions via a real subprocess: the manifest
    check passes on an honest tree, then correctly FAILS once one required
    file is deliberately deleted from it. This is the C9 adjudicated
    fail-closed fix: a sha256 tree-compare must not go green on an empty or
    sub-minimum output tree, and this is that claim exercised, not asserted.
    """
    result = _run(["--self-test", str(tiny_board)])
    assert result.returncode == 0, (
        f"self-test should exit 0 (both proof directions correct); "
        f"stdout={result.stdout!r} stderr={result.stderr!r}")
    combined = result.stdout + result.stderr
    assert "manifest check correctly PASSES on the honest tree" in combined
    assert "manifest check correctly FAILS on the mutated" in combined
    assert "MINIMUM-MANIFEST FAIL" in combined


def test_divergence_naming_identifies_first_offending_file(tiny_board):
    """A forced single-file corruption between run 1 and run 2 must be
    reported by NAME, never as an undifferentiated "trees differ"."""
    injected = "hermetic-F_Cu.gbr"
    result = _run(
        [str(tiny_board)],
        env={"HERMETIC_FAB_INJECT_DIVERGENCE": injected},
    )
    assert result.returncode == 1, (
        f"divergent output should be a real (exit 1) failure, not a harness "
        f"error or a false green; stdout={result.stdout!r} stderr={result.stderr!r}")
    assert injected in result.stderr, (
        f"the corrupted file must be NAMED in the failure — got: {result.stderr!r}")
    assert "first divergent file" in result.stderr


def test_identical_tree_success(tiny_board):
    """The uninjected happy path must actually reach GREEN — pinned
    separately from the two failure-mode tests above so a broken happy path
    can't hide behind two passing failure-mode assertions."""
    result = _run([str(tiny_board)])
    assert result.returncode == 0, (
        f"stdout={result.stdout!r} stderr={result.stderr!r}")
    assert "GREEN" in result.stderr


def test_script_gerber_suffix_list_matches_fab_capability_authority():
    """N3 (review round 1): the script's hardcoded 9-suffix GERBER_SUFFIXES=
    literal must equal fab_capability.EMITTED_GERBER_SUFFIXES, the authority
    it is deliberately NOT imported from. Reads the script's own source text
    rather than re-running it, so this pin does not need a subprocess or a
    board at all — a pure drift check."""
    text = SCRIPT.read_text(encoding="utf-8")
    m = re.search(r"^GERBER_SUFFIXES=\(([^)]*)\)", text, re.MULTILINE)
    assert m, (
        "GERBER_SUFFIXES=(...) literal not found in hermetic-fab-check.sh — "
        "the anchor this pin greps for has drifted; update the regex to match "
        "the script's current form, don't just delete this pin")
    script_suffixes = set(m.group(1).split())

    from pcb_worker import fab_capability
    authority = set(fab_capability.EMITTED_GERBER_SUFFIXES)
    assert script_suffixes == authority, (
        f"script GERBER_SUFFIXES {sorted(script_suffixes)} != "
        f"fab_capability.EMITTED_GERBER_SUFFIXES {sorted(authority)} — a layer "
        f"was added/removed on one side without the other")


if __name__ == "__main__":  # pragma: no cover - parked, never collected by CI
    sys.exit(pytest.main([__file__, "-v"]))
