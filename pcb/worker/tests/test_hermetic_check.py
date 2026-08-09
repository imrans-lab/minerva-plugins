"""Script-behavior pins for pcb/scripts/hermetic-fab-check.sh (C9).

HEADER CORRECTED IN EPOCH CP2 (station S1). This docstring previously opened
"PARKED — ... NEVER EXECUTED this epoch (REGIME: parked python files are named
``pending_*`` so pytest's default collection never picks this file up)". That
was true of the file's ORIGINAL name and became FALSE when it was renamed to
``test_hermetic_check.py``, which is exactly the pattern default collection
DOES pick up — the header was not updated with the rename. Verified 2026-08-08:
``pytest tests/test_hermetic_check.py --collect-only`` collects the four
pre-existing pins — seven in total, counting S1's three wiring pins added below
— so they run in CI's ``test`` job like any other suite.

The stale claim mattered beyond tidiness: it is the reason CP2's station S1 was
originally written up as "the hermetic script is wired into no CI at all". The
accurate statement is narrower — no WORKFLOW FILE invokes the script (``grep -rn
hermetic .github/`` was empty until S1), so what CI exercised was the SCRIPT's
own fail-closed behavior over the tiny synthetic fixture below, never a
clean-checkout build of a REAL board. S1's ``fab-gate`` job adds that second
thing; these pins keep doing the first.

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

  5-7. test_ci_actually_invokes_the_hermetic_script /
     test_ci_gates_the_real_coupon_and_proves_the_gate_can_fail /
     test_fab_gate_is_not_downgraded_to_a_main_only_job — epoch CP2 station
     S1. These pin the WIRING rather than the script: they parse
     .github/workflows/pcb.yml and assert a `run:` step actually invokes the
     script, that it does so with --self-test and against the public coupon by
     name, and that the job keeps running on pull_request. The state they exist
     to prevent is the one S1 found — a complete, correct gate that no workflow
     file called.

This file needs no fixture in testdata/: the tiny board is inline below, and
the subprocess calls create and clean their own tmp_path output trees.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

# The script is bash; the Windows CI runner has no usable WSL distribution and
# bash.exe there prints a WSL setup banner instead of running the script.
# Platform-inapplicable, named — not a silent pass.
#
# APPLIED PER-TEST, NOT AS A MODULE-LEVEL `pytestmark`, since epoch CP2 S1: the
# three wiring pins at the bottom of this file run no bash at all (they parse a
# YAML file), and neither does the suffix-drift pin (it reads the script's TEXT)
# — so a module-wide skip suppressed four of seven tests on Windows under a
# reason that is false for them. Only the THREE subprocess-driving tests below
# carry this mark.
_needs_bash = pytest.mark.skipif(
    sys.platform == "win32",
    reason="hermetic-fab-check.sh is a bash script; Windows CI has no bash/WSL",
)

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
    # CI has no pcb/worker/.venv (a gitignored local build artifact); the
    # pytest interpreter running THIS test already carries the worker deps,
    # so hand it to the script via its documented override. Locally this is
    # the venv interpreter anyway, so behavior is identical.
    full_env.setdefault("HERMETIC_FAB_PYTHON", sys.executable)
    if env:
        full_env.update(env)
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        capture_output=True, text=True, timeout=120, env=full_env,
    )


@_needs_bash
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


@_needs_bash
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


@_needs_bash
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


WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pcb.yml"


def _workflow_run_scripts() -> list[str]:
    """Every ``run:`` body in pcb.yml, flattened across all jobs and steps.

    Plain ``import yaml``, deliberately NOT ``pytest.importorskip``: pyyaml is a
    hard runtime dependency of pcb_worker, so an environment without it is
    already red elsewhere in this suite. An importorskip here would buy nothing
    except a lane in which the UNWIRED state passes as a skip — and skips do not
    fail CI, which is the exact silent-pass this workflow's own header condemns.
    """
    import yaml

    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    bodies = []
    for job in (doc.get("jobs") or {}).values():
        for step in (job.get("steps") or []):
            run = step.get("run")
            if isinstance(run, str):
                bodies.append(run)
    return bodies


def test_ci_actually_invokes_the_hermetic_script():
    """EPOCH CP2 S1 REGRESSION GUARD — the whole finding S1 acted on was that
    this script was complete, correct, and invoked by no workflow file for an
    entire epoch. Nothing structural prevented that, and nothing would prevent
    it recurring if the job were dropped in a future workflow edit.

    So pin the WIRING, not just the script's behavior. This asserts a
    ``run:`` step somewhere in pcb.yml actually calls hermetic-fab-check.sh —
    deleting the fab-gate job fails HERE, by name, instead of silently
    restoring the unwired state.

    Structural (parse the YAML, walk jobs -> steps -> run) rather than a
    substring grep of the whole file: the script's name appears in this
    workflow's COMMENTS too, and a plain grep would keep passing on a file
    where the job had been deleted and only the prose survived.

    That is a real improvement but not an airtight one, and the limit is worth
    stating rather than overselling: the name could still appear inside a SHELL
    comment or an echo within some other step's `run:` body and satisfy this.
    Anchoring a regex to an uncommented invocation would close that; it is not
    done here because the realistic failure mode is "the job got deleted in a
    refactor", not "someone wrote a decoy echo"."""
    bodies = _workflow_run_scripts()
    assert any("hermetic-fab-check.sh" in body for body in bodies), (
        "no `run:` step in .github/workflows/pcb.yml invokes "
        "hermetic-fab-check.sh — the clean-checkout fabrication gate has been "
        "unwired. If this was deliberate, delete this pin and record WHY in "
        "the workflow; do not leave the script present and unrun, which is "
        "the state epoch CP2 station S1 existed to fix.")


def test_ci_gates_the_real_coupon_and_proves_the_gate_can_fail():
    """The companion to the pin above: wiring the script is not the same as
    wiring it USEFULLY.

    Two independent claims, both of which S1's job depends on for its value:

      1. ``--self-test`` runs. Without it, the other invocations are
         indistinguishable from a gate that exits 0 unconditionally — two
         green runs prove nothing if the harness cannot go red. This is the
         same vacuous-pass argument the script's own minimum-manifest check
         is built on, applied one level up.

      2. The PUBLIC COUPON is gated BY NAME. The synthetic fixture is a fine
         default, but the coupon is the board actually headed for a
         board-house order (K21), so its reproducibility is the claim that
         has to hold — it must not be left to a stand-in to imply."""
    bodies = _workflow_run_scripts()
    hermetic = [b for b in bodies if "hermetic-fab-check.sh" in b]
    assert hermetic, "see test_ci_actually_invokes_the_hermetic_script"

    assert any("--self-test" in body for body in hermetic), (
        "pcb.yml invokes hermetic-fab-check.sh but never with --self-test — "
        "the gate is never proven able to FAIL, so its green runs carry no "
        "information")

    assert any("coupon_jlc1.yaml" in body for body in hermetic), (
        "pcb.yml runs the hermetic gate but not against "
        "tests/testdata/coupon_jlc1.yaml — the public fab coupon is the board "
        "whose package would actually be submitted; gate it by name")


def test_fab_gate_is_not_downgraded_to_a_main_only_job():
    """The job's stated reason for running on every push AND pull_request —
    against this workflow's own cost argument for keeping `oracle` and
    `test-crossplatform` on main — is that the failure it catches is introduced
    BY A COMMIT and so must fail on the PR that makes it.

    That argument is load-bearing and is defeated silently by adding an `if:`
    guard (the shape `oracle` and `test-crossplatform` both use), which no
    other pin here would notice: the job would still exist, still invoke the
    script, still name the coupon, and simply never run on a PR again. So pin
    the trigger, not just the wiring."""
    import yaml

    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    job = (doc.get("jobs") or {}).get("fab-gate")
    assert job is not None, "the fab-gate job is gone from pcb.yml"
    assert "if" not in job, (
        f"fab-gate gained a job-level `if:` ({job.get('if')!r}) — it no longer "
        f"runs on pull_request, so a fabrication-reproducibility break lands on "
        f"main before anyone sees it. If this restriction is deliberate, update "
        f"the job's own comment (which currently argues the opposite) and this "
        f"pin together.")


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
