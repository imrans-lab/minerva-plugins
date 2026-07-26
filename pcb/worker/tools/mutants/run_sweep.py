#!/usr/bin/env python3
"""Mutation-testing harness for the PCB worker's Python test suite.

WHAT IT DOES
------------
For every entry in :mod:`corpus`, build a fresh scratch copy of the tree under
``/tmp``, apply the mutant THERE, run the real pytest suite against it, and
record whether the suite goes red and exactly WHICH tests do the killing.

WHY THE SCRATCH LAYOUT IS WHAT IT IS (two traps, both observed)
---------------------------------------------------------------
1. THE EDITABLE-INSTALL TRAP. ``pcb-plugin-worker`` is installed EDITABLE into
   ``pcb/worker/.venv``; its ``.pth`` appends the REPO source directory to
   ``sys.path``. A naive "copy the tree and run pytest there" can therefore
   import ``pcb_worker`` from the ORIGINAL repo source, every mutant appears to
   survive, and the whole matrix is wrong in the reassuring direction. Two
   independent defences: ``--check-imports`` proves the resolved ``__file__`` of
   both packages sits under the scratch dir BOTH from a plain interpreter AND
   from inside a real pytest process, and the CANARY mutant must be killed (it
   cannot be, if mutation is not reaching the code under test).

2. THE PARENT-DIRECTORY TRAP. ``git ls-files pcb/worker`` returns four entries
   (agent_router, pcb_worker, tests, pyproject.toml) and a copy of those four is
   NOT a runnable tree: 15 call sites across 11 test files resolve
   ``Path(__file__).resolve().parents[2]`` — which is ``pcb/``, not
   ``pcb/worker/`` — and read from ``pcb/spikes`` and ``pcb/spec``. The scratch
   tree therefore preserves the ``pcb/`` parent and copies those siblings.

   TWO MORE ESCAPES, FOUND BY THE CLEAN CONTROL (not by reading):

   * ``pcb/library`` — this one is in PRODUCTION source, not in a test:
     ``pcb_worker/footprints.py:63`` resolves ``parents[2]`` and reads
     ``pcb/library/footprints.lock.json``. Two test modules call
     ``load_lockfile()`` at IMPORT time to parametrize, so its absence is a
     COLLECTION error, not a test failure — exactly the shape the fail-closed
     classifier refuses to score as a kill. Omitting it cost 2 collection errors
     / 0 tests collected.
   * ``pcb/ui`` — ``tests/test_kicad_cli_boundary.py`` globs ``PCB/"ui"`` for
     ``**/*.gd`` behind ``if not root.exists(): continue``. Without it that test
     still PASSES while silently scanning 18 fewer files. A control that passes
     for a weaker reason than the real run is not a control, so ``ui`` is copied
     too.

   The lesson generalises: the copy manifest is derived from what the CONTROL
   proves, never from what ``git ls-files`` suggests.

SAFETY
------
Mutants are NEVER written into the repo working tree. ``git status --porcelain``
over ``pcb_worker/``, ``agent_router/`` and ``tests/`` is asserted clean BEFORE
the sweep as well as after: a tree already dirty at the start makes the end
check meaningless.

Every pytest invocation sets ``PYTHONDONTWRITEBYTECODE=1`` and passes
``-p no:cacheprovider``; ``__pycache__`` / ``.pytest_cache`` are excluded from
the copy. A stale ``.pyc`` invalidates a mutation matrix in the reassuring
direction, which is the exact failure this round exists to prevent.

ENTRY POINTS
------------
  --check-imports            import-origin self-proof only
  --control [--repeat N]     clean-control run(s); N>1 requires identical results
  --canary                   run the canary mutant only
  --concurrency-check ID     one mutant serially vs the same one inside a batch
  --sweep -o results.json    the full baseline sweep
  --compare A.json B.json    acceptance: is the set of killed mutant ids identical?
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent           # pcb/worker/tools/mutants
WORKER = HERE.parents[1]                          # pcb/worker
PCB = WORKER.parent                               # pcb
REPO = PCB.parent                                 # repo root
VENV_PYTHON = WORKER / ".venv" / "bin" / "python"

sys.path.insert(0, str(HERE))
import corpus  # noqa: E402  (deliberate: the corpus lives beside this file)

#: Copied INTO the scratch tree as ``<tmp>/pcb/worker/<name>``.
WORKER_ENTRIES = ("agent_router", "pcb_worker", "tests", "pyproject.toml")
#: Copied INTO the scratch tree as ``<tmp>/pcb/<name>`` — the parents[2] escapes.
#: See the module docstring: spikes/spec are read by tests, library is read by
#: PRODUCTION source (footprints.py) at test-collection time, and ui is scanned
#: by the kicad-cli boundary test behind an exists() guard that silently weakens
#: it when the directory is absent.
PCB_SIBLINGS = ("spikes", "spec", "library", "ui")

COPY_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", ".pytest_cache")

#: Source dirs whose cleanliness is asserted before and after every sweep.
PROTECTED = ("pcb/worker/pcb_worker", "pcb/worker/agent_router", "pcb/worker/tests")

DEFAULT_TIMEOUT_S = 900
DEFAULT_CONCURRENCY = 6
MAX_CONCURRENCY = 8


class HarnessError(RuntimeError):
    """The harness itself is not trustworthy — never a mutation result."""


# ---------------------------------------------------------------------------
# Repo hygiene
# ---------------------------------------------------------------------------


def repo_head() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                          capture_output=True, text=True, check=True).stdout.strip()


def assert_repo_clean(when: str) -> None:
    out = subprocess.run(["git", "status", "--porcelain", "--"] + list(PROTECTED),
                         cwd=REPO, capture_output=True, text=True, check=True).stdout
    if out.strip():
        raise HarnessError(
            f"repo working tree is DIRTY under the protected source dirs {when}:\n{out}\n"
            "A mutant must never reach the repo. Refusing to continue.")


def source_digest() -> str:
    """Content hash of every .py under pcb_worker/ and agent_router/.

    The corpus is defined by exact-string matches into this source. If it moves
    between two sweeps the mutants are not the same mutants and a comparison is
    void — so the digest is recorded and enforced at comparison time.
    """
    h = hashlib.sha256()
    for pkg in ("pcb_worker", "agent_router"):
        for path in sorted((WORKER / pkg).rglob("*.py")):
            if "__pycache__" in path.parts:
                continue
            h.update(str(path.relative_to(WORKER)).encode())
            h.update(b"\0")
            h.update(path.read_bytes())
            h.update(b"\0")
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Environment pinning
# ---------------------------------------------------------------------------


def _pkg_version(name: str) -> str | None:
    code = ("import importlib.metadata as m\n"
            f"try: print(m.version({name!r}))\n"
            "except Exception: print('')\n")
    out = subprocess.run([str(VENV_PYTHON), "-c", code],
                         capture_output=True, text=True).stdout.strip()
    return out or None


def _kicad_cli() -> dict[str, Any]:
    exe = shutil.which("kicad-cli")
    if not exe:
        return {"present": False, "version": None}
    ver = subprocess.run([exe, "version"], capture_output=True, text=True).stdout.strip()
    return {"present": True, "version": ver}


def environment() -> dict[str, Any]:
    """Everything a comparison must hard-fail on if it differs.

    ~15 oracle tests are ``skipif(not kicad_cli_available())`` and A SKIPPED TEST
    KILLS NOTHING — if the before-sweep runs with kicad-cli and the after-sweep
    without it, mutants change status for reasons that have nothing to do with
    the test edits.
    """
    py = subprocess.run([str(VENV_PYTHON), "-c", "import sys; print(sys.version.split()[0])"],
                        capture_output=True, text=True, check=True).stdout.strip()
    return {
        "python": py,
        "kicad_cli": _kicad_cli(),
        "pytest": _pkg_version("pytest"),
        "pygerber": _pkg_version("pygerber"),
        "gerbonara": _pkg_version("gerbonara"),
        "gerber-writer": _pkg_version("gerber-writer"),
        "base_sha": repo_head(),
        "source_digest": source_digest(),
    }


# ---------------------------------------------------------------------------
# Scratch tree
# ---------------------------------------------------------------------------


def build_scratch(tag: str) -> tuple[Path, Path]:
    """Return ``(tmp_root, scratch_worker_dir)``. Layout: ``<tmp>/pcb/worker``."""
    tmp = Path(tempfile.mkdtemp(prefix=f"mutsweep-{tag}-"))
    pcb = tmp / "pcb"
    worker = pcb / "worker"
    worker.mkdir(parents=True)
    for name in WORKER_ENTRIES:
        src = WORKER / name
        if src.is_dir():
            shutil.copytree(src, worker / name, ignore=COPY_IGNORE)
        else:
            shutil.copy2(src, worker / name)
    for name in PCB_SIBLINGS:
        shutil.copytree(PCB / name, pcb / name, ignore=COPY_IGNORE)
    return tmp, worker


def scratch_env(worker: Path) -> dict[str, str]:
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    # Belt AND braces: sys.path[0] is already the cwd for `python -m pytest`, but
    # PYTHONPATH is inserted ahead of site-packages (and therefore ahead of the
    # editable .pth), so the scratch copy wins under both mechanisms.
    env["PYTHONPATH"] = str(worker) + os.pathsep + env.get("PYTHONPATH", "")
    env.pop("PYTEST_ADDOPTS", None)
    # Deliberately NOT pinning PYTHONHASHSEED: pinning it would MASK the
    # run-to-run nondeterminism the twice-run clean control exists to detect.
    return env


def check_import_origin(worker: Path) -> dict[str, str]:
    """Assert both packages resolve INSIDE the scratch tree. Hard-fail otherwise."""
    code = ("import pcb_worker, agent_router\n"
            "print(pcb_worker.__file__)\nprint(agent_router.__file__)\n")
    res = subprocess.run([str(VENV_PYTHON), "-c", code], cwd=str(worker),
                         env=scratch_env(worker), capture_output=True, text=True)
    if res.returncode != 0:
        raise HarnessError(f"import-origin probe failed:\n{res.stdout}\n{res.stderr}")
    lines = [ln.strip() for ln in res.stdout.strip().splitlines() if ln.strip()]
    if len(lines) != 2:
        raise HarnessError(f"import-origin probe produced {len(lines)} lines: {res.stdout!r}")
    origins = {"pcb_worker": lines[0], "agent_router": lines[1]}
    for name, path in origins.items():
        if not path.startswith(str(worker) + os.sep):
            raise HarnessError(
                f"IMPORT-ORIGIN FAILURE: {name} resolved to {path!r}, OUTSIDE the "
                f"scratch tree {worker!r}. The editable .pth has won; every result "
                f"in this sweep would be void.")
    return origins


_PYTEST_PROBE = '''\
"""Written into the SCRATCH tree only. Proves the origin check inside a real
pytest process, not merely under a bare interpreter."""
from pathlib import Path

SCRATCH = Path(__file__).resolve().parent


def test_packages_import_from_the_scratch_tree():
    import agent_router
    import pcb_worker
    for mod in (pcb_worker, agent_router):
        assert Path(mod.__file__).resolve().is_relative_to(SCRATCH), (
            f"{mod.__name__} imported from {mod.__file__}, outside {SCRATCH}")
'''


def check_import_origin_under_pytest(worker: Path) -> str:
    """The same proof, from inside a real pytest process.

    The probe file is written at the scratch WORKER ROOT, never under ``tests/``,
    and is passed to pytest explicitly — ``testpaths = ["tests"]`` only applies
    when no path argument is given, so this file is invisible to every other run.
    """
    probe = worker / "_mutharness_import_probe.py"
    probe.write_text(_PYTEST_PROBE)
    res = subprocess.run(
        [str(VENV_PYTHON), "-m", "pytest", probe.name, "-q", "-p", "no:cacheprovider",
         "--tb=short"],
        cwd=str(worker), env=scratch_env(worker), capture_output=True, text=True)
    probe.unlink()
    if res.returncode != 0:
        raise HarnessError(
            "IMPORT-ORIGIN FAILURE under pytest — the editable .pth wins inside a "
            f"real pytest process:\n{res.stdout}\n{res.stderr}")
    return res.stdout.strip().splitlines()[-1]


def apply_mutant(worker: Path, mutant: dict) -> None:
    """Exact-string substitution with a HARD exactly-once assertion.

    Zero or >=2 occurrences is a hard failure, not a warning: that is what makes
    the corpus self-invalidating when the source moves under it.
    """
    target = worker / mutant["file"]
    text = target.read_text()
    n = text.count(mutant["find"])
    if n != 1:
        raise HarnessError(
            f"mutant {mutant['id']!r}: 'find' occurs {n} time(s) in "
            f"{mutant['file']} (must be exactly 1). The corpus has drifted from "
            f"the source; fix the corpus, do not relax this check.")
    target.write_text(text.replace(mutant["find"], mutant["replace"], 1))


# ---------------------------------------------------------------------------
# Running + parsing
# ---------------------------------------------------------------------------

_TALLY_RE = re.compile(r"(\d+)\s+(failed|passed|skipped|error|errors|xfailed|xpassed|deselected)")
_TALLY_TAIL_RE = re.compile(r"\bin \d+(\.\d+)?s\b")
# Node ids are taken as everything after ``FAILED ``/``ERROR `` up to pytest's own
# " - <message>" separator. NOT ``\S+``: a parametrized id can contain spaces
# (``test_x[<lambda>-duplicate footprint content ids]``) and a ``\S+`` capture
# clips it mid-bracket, yielding an id that no longer selects the test. Observed
# on tests/test_resolved_board.py, which is in the protected set — so the clipped
# form would have been handed to the editing unit as the name of a test it must
# not touch.
_SUMMARY_LINE_RE = re.compile(r"^(FAILED|ERROR)\s+(.+)$")


def parse_pytest(out: str) -> dict[str, Any]:
    """Node ids from the ``-rfE`` short summary; counts from pytest's own tally.

    The two are cross-checked by the caller: an attribution list that disagrees
    with pytest's own count means the capture is unreliable, and an unreliable
    attribution list is the round's second deliverable being silently wrong.
    """
    failing: list[str] = []
    for line in out.splitlines():
        m = _SUMMARY_LINE_RE.match(line.strip())
        if m:
            node = m.group(2).split(" - ", 1)[0].strip()
            if node and node not in failing:
                failing.append(node)
    # The tally comes from pytest's OWN final line, identified by its shape
    # ("... in 12.34s"), not from a window of trailing lines — a short-summary
    # line can contain "3 failed" inside an assertion message and would otherwise
    # be read as the tally.
    tally: dict[str, int] = {}
    for line in reversed(out.strip().splitlines()):
        stripped = line.strip()
        if _TALLY_TAIL_RE.search(stripped) and (
                stripped[:1].isdigit() or stripped.startswith("no tests ran")):
            for count, word in _TALLY_RE.findall(stripped):
                key = "error" if word in ("error", "errors") else word
                tally[key] = int(count)
            break
    return {
        "failing": failing,
        "n_passed": tally.get("passed", 0),
        "n_skipped": tally.get("skipped", 0),
        "n_failed_tally": tally.get("failed", 0),
        "n_error_tally": tally.get("error", 0),
        "collection_error": ("during collection" in out) or ("Interrupted:" in out),
        "no_tests_ran": "no tests ran" in out,
    }


def run_suite(worker: Path, timeout: int) -> dict[str, Any]:
    cmd = [str(VENV_PYTHON), "-m", "pytest", "tests/", "-q", "-p", "no:cacheprovider",
           "--tb=no", "-rfE"]
    started = time.time()
    try:
        res = subprocess.run(cmd, cwd=str(worker), env=scratch_env(worker),
                             capture_output=True, text=True, timeout=timeout)
        out = res.stdout + "\n" + res.stderr
        rc = res.returncode
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"").decode(errors="replace") if isinstance(exc.stdout, bytes) \
            else (exc.stdout or "")
        rc = -1
        timed_out = True
    parsed = parse_pytest(out)
    parsed["returncode"] = rc
    parsed["timed_out"] = timed_out
    parsed["duration_s"] = round(time.time() - started, 2)
    parsed["raw_tail"] = "\n".join(out.strip().splitlines()[-3:])
    return parsed


def classify(mutant: dict, run: dict, control: dict) -> dict[str, Any]:
    """FAIL-CLOSED classification.

    An empty failing list with a nonzero return code is NEVER a kill — that is a
    mutant which broke COLLECTION rather than execution, and the naive rule
    ``returncode != 0 -> killed`` silently inflates the kill set. Explicitly:

      assertion        one or more real test failures. The only kind that counts.
      collection_error a DEFECTIVE mutant. HARD FAIL; never counted as a kill.
      timeout          counts as killed, but fragile evidence — flagged, and
                       excluded from the acceptance comparison unless it
                       reproduces.
      exit code 4 / 5  usage error / no tests collected: HARNESS failure.
    """
    rc = run["returncode"]
    failing = run["failing"]
    problems: list[str] = []

    if run["timed_out"]:
        verdict = ("timeout", True)
    elif run["collection_error"] or run["no_tests_ran"]:
        verdict = ("collection_error", False)
        problems.append("mutant broke COLLECTION, not execution — DEFECTIVE mutant")
    elif rc in (4, 5):
        verdict = ("harness_error", False)
        problems.append(f"pytest exit code {rc} (usage error / no tests collected)")
    elif rc == 0:
        verdict = ("survived", False)
        if failing:
            problems.append("returncode 0 but the short summary lists failures")
    elif failing:
        verdict = ("assertion", True)
    else:
        verdict = ("unclassified_nonzero", False)
        problems.append(f"returncode {rc} with an EMPTY failing list — never a kill")

    killed_by, killed = verdict

    if not run["timed_out"] and verdict[0] in ("assertion", "survived"):
        tallied = run["n_failed_tally"] + run["n_error_tally"]
        if tallied != len(failing):
            problems.append(
                f"attribution mismatch: {len(failing)} node id(s) captured vs "
                f"pytest's own tally of {tallied}")
        # A run whose passed-count collapses far below the control is usually an
        # import or environment failure wearing a kill's clothing.
        if run["n_passed"] < control["n_passed"] * 0.5:
            problems.append(
                f"passed-count collapsed to {run['n_passed']} vs control "
                f"{control['n_passed']} — suspect environment/import failure")
        # A skipped test kills nothing; a RISE in skips invalidates the result.
        if run["n_skipped"] > control["n_skipped"]:
            problems.append(
                f"skip count rose to {run['n_skipped']} vs control "
                f"{control['n_skipped']} — result-invalidating")

    return {
        "id": mutant["id"],
        "file": mutant["file"],
        "kind": mutant["kind"],
        "equivalent": bool(mutant.get("equivalent", False)),
        "killed": killed,
        "killed_by": killed_by,
        "n_failing": len(failing),
        "failing": failing,
        "n_passed": run["n_passed"],
        "n_skipped": run["n_skipped"],
        "returncode": rc,
        "problems": problems,
    }


def run_one(mutant: dict | None, control: dict | None, timeout: int,
            keep_on_failure: bool) -> tuple[dict[str, Any], dict[str, Any]]:
    """Build a scratch tree, optionally mutate it, run the suite, classify."""
    tag = (mutant["id"][:24] if mutant else "control")
    tmp, worker = build_scratch(tag)
    keep = False
    try:
        origins = check_import_origin(worker)
        if mutant is not None:
            apply_mutant(worker, mutant)
        run = run_suite(worker, timeout)
        if mutant is None:
            result = {
                "id": "__control__", "file": None, "kind": "control",
                "equivalent": False,
                "killed": run["returncode"] != 0,
                "killed_by": "n/a",
                "n_failing": len(run["failing"]), "failing": run["failing"],
                "n_passed": run["n_passed"], "n_skipped": run["n_skipped"],
                "returncode": run["returncode"], "problems": [],
            }
        else:
            result = classify(mutant, run, control or {"n_passed": 0, "n_skipped": 0})
        if result["problems"] and keep_on_failure:
            keep = True
        meta = {"duration_s": run["duration_s"], "origins": origins,
                "tail": run["raw_tail"], "tmp": str(tmp) if keep else None}
        return result, meta
    finally:
        if not keep:
            shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# Result files
# ---------------------------------------------------------------------------


def build_payload(results: list[dict]) -> dict[str, Any]:
    """The COMPARABLE block. No timestamps, temp paths or durations, and stable
    key order, so a diff of two sweeps shows only real changes."""
    ordered = sorted(results, key=lambda r: r["id"])
    return {
        "corpus_size": len(ordered),
        "killed_ids": sorted(r["id"] for r in ordered if r["killed"]),
        "survived_ids": sorted(r["id"] for r in ordered if not r["killed"]),
        "mutants": [
            {
                "id": r["id"],
                "file": r["file"],
                "kind": r["kind"],
                "equivalent": r["equivalent"],
                "killed": r["killed"],
                "killed_by": r["killed_by"],
                "returncode": r["returncode"],
                "n_failing": r["n_failing"],
                "n_passed": r["n_passed"],
                "n_skipped": r["n_skipped"],
                "failing": sorted(r["failing"]),
                "problems": r["problems"],
            }
            for r in ordered
        ],
    }


def write_results(path: Path, payload: dict, metadata: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"run_metadata": metadata, "payload": payload},
                               indent=2, sort_keys=False) + "\n")


# ---------------------------------------------------------------------------
# Comparison mode
# ---------------------------------------------------------------------------


def compare(before_path: Path, after_path: Path) -> int:
    before = json.loads(before_path.read_text())
    after = json.loads(after_path.read_text())
    b_env = before["run_metadata"]["environment"]
    a_env = after["run_metadata"]["environment"]

    fatal: list[str] = []
    for key in ("python", "kicad_cli", "pytest", "pygerber", "gerbonara", "gerber-writer"):
        if b_env.get(key) != a_env.get(key):
            fatal.append(f"environment differs on {key!r}: {b_env.get(key)!r} != {a_env.get(key)!r}")
    if b_env.get("source_digest") != a_env.get("source_digest"):
        fatal.append(
            "production source under pcb_worker/ + agent_router/ CHANGED between "
            "the two sweeps (source_digest differs). The mutants are not the same "
            "mutants; the comparison is void.")
    base = b_env.get("base_sha")
    if base:
        diff = subprocess.run(
            ["git", "diff", "--stat", base, "--",
             "pcb/worker/pcb_worker", "pcb/worker/agent_router"],
            cwd=REPO, capture_output=True, text=True)
        if diff.returncode != 0:
            fatal.append(f"git diff against the baseline SHA {base} failed: {diff.stderr.strip()}")
        elif diff.stdout.strip():
            fatal.append(
                f"git diff --stat vs baseline SHA {base} over pcb_worker/ + "
                f"agent_router/ is NOT empty:\n{diff.stdout}")
    if fatal:
        print("COMPARISON REFUSED:")
        for line in fatal:
            print(f"  - {line}")
        return 2

    b = {m["id"]: m for m in before["payload"]["mutants"]}
    a = {m["id"]: m for m in after["payload"]["mutants"]}
    if set(b) != set(a):
        print("COMPARISON REFUSED: the two runs cover different mutant ids.")
        print(f"  only in before: {sorted(set(b) - set(a))}")
        print(f"  only in after:  {sorted(set(a) - set(b))}")
        return 2

    timeout_ids = sorted(i for i in b if b[i]["killed_by"] == "timeout"
                         or a[i]["killed_by"] == "timeout")
    changed = [i for i in sorted(b) if b[i]["killed"] != a[i]["killed"] and i not in timeout_ids]
    lost = [i for i in changed if b[i]["killed"]]
    gained = [i for i in changed if not b[i]["killed"]]

    print(f"before killed: {sum(1 for m in b.values() if m['killed'])}/{len(b)}")
    print(f"after  killed: {sum(1 for m in a.values() if m['killed'])}/{len(a)}")
    if timeout_ids:
        print(f"EXCLUDED (timeout kills, fragile evidence): {timeout_ids}")
    if not changed:
        print("PASS: the set of killed mutant ids is IDENTICAL.")
        return 0
    print("FAIL: the set of killed mutant ids CHANGED. "
          "'No worse' is not the test — identical is.")
    for i in lost:
        print(f"  LOST KILL   {i}  (was killed by {b[i]['n_failing']} test(s), now survives)")
    for i in gained:
        print(f"  NEW KILL    {i}  (survived before, now killed by {a[i]['n_failing']} test(s))")
    return 1


# ---------------------------------------------------------------------------
# Attribution
# ---------------------------------------------------------------------------


def sync_corpus_fields(results_path: Path) -> int:
    """Re-derive the STATIC corpus fields (``file``, ``kind``, ``equivalent``) in a
    results file from the corpus.

    These are properties of the CORPUS, not of the run, so they can be corrected
    without re-running the suite — and they need to be, because equivalence is
    established AFTER a mutant survives, by probing it. The RUN results
    (``killed``, ``killed_by``, ``failing``, counts, returncode) are never touched
    here; a change to those requires a real sweep.
    """
    data = json.loads(results_path.read_text())
    index = corpus.by_id()
    changed: list[str] = []
    for m in data["payload"]["mutants"]:
        src = index.get(m["id"])
        if src is None:
            raise HarnessError(f"results carry unknown mutant id {m['id']!r}")
        for key, value in (("file", src["file"]), ("kind", src["kind"]),
                           ("equivalent", bool(src.get("equivalent", False)))):
            if m[key] != value:
                changed.append(f"{m['id']}.{key}: {m[key]!r} -> {value!r}")
                m[key] = value
    data["payload"]["equivalent_ids"] = sorted(
        m["id"] for m in data["payload"]["mutants"] if m["equivalent"])
    results_path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    print(f"synced {len(changed)} static field(s) in {results_path}:")
    for line in changed:
        print(f"  {line}")
    return 0


def attribution(results_path: Path) -> int:
    """Derive the two attribution lists from a results file.

    SOLE KILLERS — for every mutant killed by exactly ONE test, that test. This
    is the PROTECTED SET: the tests a later editing unit must not delete or
    loosen. Consequential and cheap once the matrix exists.

    ZERO-UNIQUE-KILL — tests that killed at least one mutant but killed no mutant
    UNIQUELY. These are DELETION CANDIDATES, and that word is doing real work:
    candidacy, not a verdict. A 30-mutant corpus is a SAMPLE of defect space, not
    a census; a test with no unique kill here is not thereby vacuous.
    """
    data = json.loads(results_path.read_text())
    mutants = data["payload"]["mutants"]
    killed_by_test: dict[str, set[str]] = {}
    sole: dict[str, str] = {}
    for m in mutants:
        if not m["killed"]:
            continue
        for node in m["failing"]:
            killed_by_test.setdefault(node, set()).add(m["id"])
        if len(m["failing"]) == 1:
            sole[m["id"]] = m["failing"][0]

    protected = sorted(set(sole.values()))
    print(f"PROTECTED SET — {len(protected)} sole-killer test(s) covering "
          f"{len(sole)} mutant(s). Do NOT delete or loosen these:")
    for node in protected:
        ids = sorted(k for k, v in sole.items() if v == node)
        print(f"  {node}")
        for i in ids:
            print(f"      sole killer of: {i}")

    zero_unique = sorted(t for t in killed_by_test if t not in set(sole.values()))
    print(f"\nDELETION CANDIDATES — {len(zero_unique)} of {len(killed_by_test)} "
          f"killing test(s) killed nothing UNIQUELY.")
    print("  CANDIDACY, NOT A VERDICT: this corpus samples 30 defect shapes across "
          "9 modules.\n  A test with no unique kill here may still be the only "
          "thing standing between\n  the suite and a defect the corpus does not "
          "contain.")
    for node in zero_unique:
        print(f"  {node}  (killed {len(killed_by_test[node])})")
    print(f"\nNEVER-KILLING TESTS ARE NOT LISTED: a test that killed zero mutants "
          f"is\nindistinguishable here from a test guarding a defect shape the "
          f"corpus omits.")
    return 0


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------


def do_control(repeat: int, timeout: int, expect_passed: int | None = None,
               expect_skipped: int | None = None) -> list[dict]:
    """The clean control: the UNMUTATED tree through the exact same copy-and-run
    path. Hard-fails on anything that would degrade the baseline.

    Three ways this refuses, all of them STOP rather than redefine the truth:
      * the control is not GREEN — the copy mechanism changed an outcome, so the
        methodology is invalid;
      * it does not reproduce the in-repo counts the orchestrator supplied;
      * two runs are not identical TEST FOR TEST — run-to-run nondeterminism
        would make every before/after diff meaningless, and it is invisible
        unless you look.
    """
    runs: list[dict] = []
    for i in range(repeat):
        result, meta = run_one(None, None, timeout, keep_on_failure=False)
        print(f"control run {i + 1}/{repeat}: rc={result['returncode']} "
              f"passed={result['n_passed']} skipped={result['n_skipped']} "
              f"failed={result['n_failing']} in {meta['duration_s']}s")
        if result["failing"]:
            print("  FAILING:")
            for node in result["failing"]:
                print(f"    {node}")
        runs.append(result)
        if result["returncode"] != 0:
            raise HarnessError(
                "CLEAN CONTROL IS NOT GREEN in the scratch tree. The copy "
                "mechanism has changed an outcome, so the methodology is invalid. "
                "Fix the scratch layout — do NOT adopt this as the new baseline.")
        if expect_passed is not None and result["n_passed"] != expect_passed:
            raise HarnessError(
                f"clean control passed={result['n_passed']}, expected "
                f"{expect_passed} (the measured in-repo baseline). STOP.")
        if expect_skipped is not None and result["n_skipped"] != expect_skipped:
            raise HarnessError(
                f"clean control skipped={result['n_skipped']}, expected "
                f"{expect_skipped}. A skipped test kills nothing; a rise in skips "
                f"is a result-invalidating event, not a curiosity. STOP.")
    if repeat > 1:
        first = runs[0]
        for i, other in enumerate(runs[1:], start=2):
            same = (first["n_passed"] == other["n_passed"]
                    and first["n_skipped"] == other["n_skipped"]
                    and sorted(first["failing"]) == sorted(other["failing"])
                    and first["returncode"] == other["returncode"])
            if not same:
                raise HarnessError(
                    f"clean control run {i} is NOT identical to run 1 — the suite is "
                    f"nondeterministic, so every before/after diff is meaningless.\n"
                    f"  run1: passed={first['n_passed']} skipped={first['n_skipped']} "
                    f"failing={sorted(first['failing'])}\n"
                    f"  run{i}: passed={other['n_passed']} skipped={other['n_skipped']} "
                    f"failing={sorted(other['failing'])}")
        print(f"control reproducible across {repeat} runs, test-for-test.")
    return runs


def do_sweep(control: dict, concurrency: int, timeout: int, out_path: Path,
             keep_on_failure: bool) -> int:
    mutants = list(corpus.MUTANTS)
    results: list[dict] = []
    durations: dict[str, float] = {}
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {pool.submit(run_one, m, control, timeout, keep_on_failure): m
                   for m in mutants}
        done = 0
        for fut in concurrent.futures.as_completed(futures):
            m = futures[fut]
            result, meta = fut.result()
            results.append(result)
            durations[result["id"]] = meta["duration_s"]
            done += 1
            flag = "KILL" if result["killed"] else "surv"
            warn = "  !! " + "; ".join(result["problems"]) if result["problems"] else ""
            print(f"[{done}/{len(mutants)}] {flag} {result['id']} "
                  f"({result['killed_by']}, {result['n_failing']} failing, "
                  f"{meta['duration_s']}s){warn}", flush=True)
    wall = round(time.time() - started, 1)

    defective = [r for r in results if r["killed_by"] in
                 ("collection_error", "harness_error", "unclassified_nonzero")]
    payload = build_payload(results)
    metadata = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "environment": environment(),
        "control": {"n_passed": control["n_passed"], "n_skipped": control["n_skipped"],
                    "returncode": control["returncode"]},
        "concurrency": concurrency,
        "timeout_s": timeout,
        "wall_clock_s": wall,
        "per_mutant_duration_s": {k: durations[k] for k in sorted(durations)},
    }
    write_results(out_path, payload, metadata)
    print(f"\nwrote {out_path}  ({wall}s wall, concurrency {concurrency})")

    if defective:
        print("\nDEFECTIVE MUTANTS (never counted as kills — fix or drop them):")
        for r in defective:
            print(f"  {r['id']}: {r['killed_by']} — {'; '.join(r['problems'])}")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check-imports", action="store_true")
    ap.add_argument("--control", action="store_true")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--canary", action="store_true")
    ap.add_argument("--one", metavar="ID", help="run a single mutant by id")
    ap.add_argument("--concurrency-check", metavar="ID",
                    help="run ID serially, then inside a concurrent batch, and "
                         "require identical killed-bool AND failing-test set")
    ap.add_argument("--sweep", action="store_true")
    ap.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    ap.add_argument("--sync-corpus-fields", metavar="RESULTS",
                    help="re-derive the STATIC corpus fields (file/kind/equivalent) "
                         "in a results file; never touches run results")
    ap.add_argument("--attribution", metavar="RESULTS",
                    help="derive the sole-killer (protected) and zero-unique-kill "
                         "(deletion-candidate) lists from a results JSON")
    ap.add_argument("-o", "--out", default=str(HERE / "results" / "baseline.json"))
    ap.add_argument("-j", "--concurrency", type=int, default=DEFAULT_CONCURRENCY)
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_S)
    ap.add_argument("--keep-on-failure", action="store_true")
    ap.add_argument("--control-passed", type=int, default=None,
                    help="known clean-control passed count (skips re-running it)")
    ap.add_argument("--control-skipped", type=int, default=None)
    # The CONTROL TARGET, measured in-repo at base SHA 58df4fc3 with kicad-cli
    # 9.0.9 on PATH: `1299 passed, 1 skipped, 0 failed`. The scratch control must
    # reproduce it exactly; it is asserted, not adopted.
    ap.add_argument("--expect-passed", type=int, default=1299)
    ap.add_argument("--expect-skipped", type=int, default=1)
    args = ap.parse_args(argv)

    corpus.validate_shape()

    if args.compare:
        return compare(Path(args.compare[0]), Path(args.compare[1]))

    if args.attribution:
        return attribution(Path(args.attribution))

    if args.sync_corpus_fields:
        return sync_corpus_fields(Path(args.sync_corpus_fields))

    if args.concurrency > MAX_CONCURRENCY:
        raise HarnessError(f"concurrency {args.concurrency} exceeds the {MAX_CONCURRENCY} cap")

    assert_repo_clean("BEFORE the run")
    try:
        if args.check_imports:
            tmp, worker = build_scratch("imports")
            try:
                origins = check_import_origin(worker)
                for name, path in origins.items():
                    print(f"  {name}: {path}")
                line = check_import_origin_under_pytest(worker)
                print(f"  under pytest: {line}")
                print("import-origin OK — both packages resolve inside the scratch tree.")
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
            return 0

        if args.control:
            do_control(args.repeat, args.timeout, args.expect_passed, args.expect_skipped)
            return 0

        control = {"n_passed": args.control_passed or 0,
                   "n_skipped": args.control_skipped or 0,
                   "returncode": 0}
        if args.control_passed is None and (args.canary or args.one or args.sweep
                                            or args.concurrency_check):
            control = do_control(1, args.timeout, args.expect_passed,
                                 args.expect_skipped)[0]

        index = corpus.by_id()

        if args.canary or args.one:
            target = args.one or next(m["id"] for m in corpus.MUTANTS
                                      if m["kind"] == "canary")
            result, meta = run_one(index[target], control, args.timeout,
                                   args.keep_on_failure)
            print(json.dumps({**result, "duration_s": meta["duration_s"]}, indent=2))
            if args.canary and not (result["killed"] and result["killed_by"] == "assertion"):
                raise HarnessError(
                    "CANARY SURVIVED (or was not killed by assertion). Mutation is "
                    "not reaching the code under test; every 'survived' result "
                    "would be indistinguishable from this failure.")
            return 0 if result["killed"] else 1

        if args.concurrency_check:
            target = index[args.concurrency_check]
            serial, _ = run_one(target, control, args.timeout, False)
            others = [m for m in corpus.MUTANTS if m["id"] != target["id"]][:args.concurrency - 1]
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
                futs = [pool.submit(run_one, m, control, args.timeout, False)
                        for m in [target] + others]
                batched = [f.result()[0] for f in futs][0]
            same = (serial["killed"] == batched["killed"]
                    and sorted(serial["failing"]) == sorted(batched["failing"]))
            print(f"serial : killed={serial['killed']} n_failing={serial['n_failing']}")
            print(f"batched: killed={batched['killed']} n_failing={batched['n_failing']}")
            if not same:
                print("CONCURRENCY IS NOT SAFE — cross-run interference detected.")
                print(f"  only serial : {sorted(set(serial['failing']) - set(batched['failing']))}")
                print(f"  only batched: {sorted(set(batched['failing']) - set(serial['failing']))}")
                return 1
            print("concurrency equivalence OK (killed-bool AND failing-test set identical).")
            return 0

        if args.sweep:
            return do_sweep(control, args.concurrency, args.timeout,
                            Path(args.out), args.keep_on_failure)

        ap.print_help()
        return 0
    finally:
        assert_repo_clean("AFTER the run")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HarnessError as exc:
        print(f"\nHARNESS ERROR: {exc}", file=sys.stderr)
        sys.exit(3)
