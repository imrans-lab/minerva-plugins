#!/usr/bin/env python3
"""Stale-runtime-bundle probe for the pcb worker.

WHAT GOES WRONG WITHOUT THIS. The pcb-plugin Go binary does not run the
repo's worker source. It resolves a Python interpreter through
shared/runtime.PythonPath, whose FIRST tier is the extracted PBS runtime
bundle at ~/.local/share/Minerva/plugins/pcb/runtime/<version>/. That
bundle carries its OWN copy of pcb_worker in its site-packages, and the
worker subprocess runs with cwd set to a scratch dir (bridge.workerCwd),
so the bundle copy — not `worker/pcb_worker/` — is what gets imported.
The binary still LOGS `worker dir=<repo>/worker`, which reads as though
the repo source is live. It is not. A worker method added after the
bundle was built answers `unknown method`, and reinstalling the plugin
does NOT rebuild the bundle.

The visible symptom is a real-worker GD suite whose seam falls back to
canned results, i.e. run-gd-tests.sh reporting "canned fallback engaged"
with no hint that the cause is an interpreter three directories away.
This probe names it: which interpreter, which pcb_worker copy, and
exactly which methods that copy is missing.

HOW IT MEASURES. Two sides, no side effects:

  expected — the method names registered in the REPO source's
             pcb_worker.methods._HANDLERS, read by AST-parsing the file
             (no import, so no dependency on the worker's runtime deps).

  actual   — the same _HANDLERS keys, AST-parsed out of the pcb_worker
             copy the binary's chosen interpreter would actually import.

The interpreter comes from the binary itself: it is started once, does
nothing, and its startup log line `worker dir=..., python=...` is read
off stderr. Any candidate in expected-minus-actual that has a dotted
`pcb.<method>` panel channel is then CONFIRMED end-to-end by driving the
real binary through scripts/e2e_route_stdio.py and checking for the
worker's `unknown method` reply.

Exit 0 when nothing is missing, 1 when something is, 2 on a probe/setup
error (binary or worker source not found) — matching run-gd-tests.sh's
convention that a harness problem is not a test verdict.

Usage:
  probe-worker-methods.py [--binary PATH] [--python PATH] [--quiet]

  --python  skip binary startup and probe THIS interpreter instead. The
            repo venv (worker/.venv/bin/python) is the control: it
            imports the repo source, so its missing set is empty.
"""
import argparse
import ast
import glob
import json
import os
import subprocess
import sys
import tempfile

PCB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_METHODS = os.path.join(PCB_DIR, "worker", "pcb_worker", "methods.py")
E2E_BRIDGE = os.path.join(PCB_DIR, "scripts", "e2e_route_stdio.py")


class ProbeError(Exception):
    """Setup/environment problem — exit 2, never a missing-method verdict."""


def handler_names(methods_py: str) -> set:
    """The keys of the module-level `_HANDLERS = {...}` dict, via AST.

    Parsing rather than importing keeps the probe free of the worker's
    runtime dependencies (and of MINERVA_PCB_ROOT, without which
    importing pcb_worker.methods raises RuleProfileError).
    """
    try:
        with open(methods_py, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=methods_py)
    except Exception as exc:  # noqa: BLE001
        raise ProbeError("cannot parse %s: %s" % (methods_py, exc))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if "_HANDLERS" not in targets or not isinstance(node.value, ast.Dict):
            continue
        names = {k.value for k in node.value.keys
                 if isinstance(k, ast.Constant) and isinstance(k.value, str)}
        if not names:
            raise ProbeError("_HANDLERS in %s has no literal string keys" % methods_py)
        return names
    raise ProbeError("no module-level _HANDLERS dict found in %s" % methods_py)


def default_binary() -> str:
    for name in ("pcb-plugin", "pcb-plugin.exe"):
        p = os.path.join(PCB_DIR, name)
        if os.path.isfile(p):
            return p
    raise ProbeError(
        "pcb-plugin binary not found in %s — build it (go build ./...) before "
        "running real-worker suites" % PCB_DIR)


def binary_python(binary: str) -> tuple:
    """Start the binary, close its stdin, and read `python=` off stderr.

    The binary logs "pcb-plugin: worker dir=<dir>, python=<path>" during
    startup (main.go initWorker), before it serves any request, so an
    immediate stdin close is enough — no worker is ever spawned.
    """
    try:
        proc = subprocess.run([binary], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=60)
    except Exception as exc:  # noqa: BLE001
        raise ProbeError("could not run %s: %s" % (binary, exc))
    for line in proc.stderr.splitlines():
        if "worker dir=" in line and "python=" in line:
            worker_dir = line.split("worker dir=", 1)[1].split(",", 1)[0].strip()
            return line.split("python=", 1)[1].strip(), worker_dir
    raise ProbeError(
        "%s printed no 'worker dir=..., python=...' startup line; stderr was:\n%s"
        % (binary, proc.stderr[-2000:]))


def imported_methods_py(python_path: str) -> str:
    """The pcb_worker/methods.py THIS interpreter resolves at worker start.

    Mirrors the two spawn shapes in shared/bridge (buildEnv/workerCwd):

      extracted runtime (<root>/bin/python3 beside <root>/manifest.sha256)
        — cwd is a scratch dir, so sys.path finds the bundle's own copy in
          <root>/lib/python3.X/site-packages (Windows: <root>/Lib/...).

      dev interpreter (worker/.venv or python3 on PATH)
        — cwd IS the worker dir, which precedes site-packages on sys.path,
          so the repo source wins. This is the control case.
    """
    bin_dir = os.path.dirname(python_path)
    root = os.path.dirname(bin_dir) if os.path.basename(bin_dir) == "bin" else bin_dir
    if not os.path.isfile(os.path.join(root, "manifest.sha256")):
        return REPO_METHODS
    candidates = sorted(glob.glob(os.path.join(
        root, "lib", "python3.*", "site-packages", "pcb_worker", "methods.py")))
    candidates += glob.glob(os.path.join(
        root, "Lib", "site-packages", "pcb_worker", "methods.py"))
    if not candidates:
        raise ProbeError(
            "interpreter %s is an extracted runtime bundle but carries no "
            "pcb_worker package under %s" % (python_path, root))
    return candidates[-1]


def confirm_via_binary(binary: str, method: str) -> str:
    """Ask the REAL binary for one method; report what its worker said.

    Only ever called for a method the file diff already flags as missing,
    so an empty-argument call can do nothing but bounce off the worker's
    dispatch. Methods without a dotted panel channel are unconfirmable
    this way and say so.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({}, f)
        req = f.name
    try:
        out = subprocess.run(
            [sys.executable, E2E_BRIDGE, binary, req, "pcb." + method],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=180).stdout.strip()
    except Exception as exc:  # noqa: BLE001
        return "could not drive the binary: %s" % exc
    finally:
        os.unlink(req)
    if "unknown method" in out:
        return "CONFIRMED via the binary: worker replied 'unknown method'"
    if "permission_denied" in out or "unknown tool" in out:
        return "no pcb.%s panel channel to confirm through (file evidence only)" % method
    return "binary replied: %s" % out[:200]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--binary", default=None, help="pcb-plugin binary (default: pcb/pcb-plugin)")
    ap.add_argument("--python", default=None, help="probe this interpreter instead of asking the binary")
    ap.add_argument("--quiet", action="store_true", help="print only on failure")
    args = ap.parse_args()

    try:
        binary = None
        if args.python:
            if not os.path.isfile(args.python):
                raise ProbeError("--python %s is not a file" % args.python)
            python_path, worker_dir = args.python, "(not asked — --python given)"
        else:
            binary = args.binary or default_binary()
            python_path, worker_dir = binary_python(binary)

        expected = handler_names(REPO_METHODS)
        actual_py = imported_methods_py(python_path)
        actual = handler_names(actual_py)
        missing = sorted(expected - actual)
    except ProbeError as exc:
        print("pcb worker-method probe: SETUP ERROR: %s" % exc, file=sys.stderr)
        return 2

    if not missing:
        if not args.quiet:
            print("pcb worker-method probe OK: %d methods, repo source and live "
                  "worker agree" % len(expected))
            print("  interpreter: %s" % python_path)
            print("  pcb_worker:  %s" % actual_py)
        return 0

    print("", file=sys.stderr)
    print("pcb worker-method probe FAILED: the live worker is missing %d method(s) "
          "the repo source registers" % len(missing), file=sys.stderr)
    print("  missing: %s" % ", ".join(missing), file=sys.stderr)
    print("  the binary chose interpreter: %s" % python_path, file=sys.stderr)
    print("  which imports pcb_worker from: %s" % actual_py, file=sys.stderr)
    print("  NOT from the repo source at:   %s" % REPO_METHODS, file=sys.stderr)
    print("  (the binary logs worker dir=%s, which is misleading — that dir is the"
          % worker_dir, file=sys.stderr)
    print("   cwd for DEV interpreters only; a bundled runtime shadows it)", file=sys.stderr)
    if binary:
        for method in missing:
            print("  - %s: %s" % (method, confirm_via_binary(binary, method)), file=sys.stderr)
    print("  Real-worker GD suites calling these methods will fall back to canned", file=sys.stderr)
    print("  results and cannot certify anything. Rebuild/refresh the runtime bundle", file=sys.stderr)
    print("  (a plugin reinstall does NOT do it) or point the binary at a dev", file=sys.stderr)
    print("  interpreter.", file=sys.stderr)
    print("", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
