#!/usr/bin/env python3
"""Build ONE plugin from the producer its own manifest.json declares.

The `setup` stanza in a plugin's manifest.json is the plugin's documented
producer -- it is what Minerva's own install pipeline
(src/Scripts/Services/Plugins/Setup/SetupSteps.gd) executes to turn a checkout
into a runnable binary. This script executes the same stanza so that a CI
runner builds the EXACT worker the plugin declares, instead of a second,
hand-maintained build recipe that drifts from it.

Step types mirror SetupSteps.gd: go_build, cargo_build, python_venv, copy,
exec. Two deliberate differences, both toward determinism:
  * cargo_build adds --locked, so a build that would need to rewrite
    Cargo.lock fails instead of silently resolving new dependency versions.
  * the manifest's `setup.requires` minimum versions are ENFORCED before any
    step runs. `python -m venv` on an EXISTING .venv silently leaves the old
    interpreter in place, so a too-old python3 on PATH produces a venv that
    looks fine and a worker that cannot import its dependencies. The python
    interpreter used for a venv is chosen to satisfy the declared minimum
    (this interpreter first, then python3.<minor> on PATH), not assumed.

Usage:  build_plugin_from_manifest.py <plugin-dir>
Prints a JSON report on stdout; step output goes to stderr. Exit 0 only if
every step succeeded and produced its declared artifact.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

DEFAULT_TIMEOUT_S = 300

# How to ask each declared tool for its version, and where the version sits in
# the answer. `python` is resolved separately (see python_for).
VERSION_PROBE = {
    "go": (["go", "version"], 2),        # "go version go1.22.3 linux/amd64"
    "cargo": (["cargo", "--version"], 1),  # "cargo 1.79.0 (...)"
}


def fail(msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(2)


def version_tuple(text: str) -> tuple:
    """The leading dotted-number run of a version string, as ints."""
    digits = []
    for part in text.strip().lstrip("go").split("."):
        head = ""
        for ch in part:
            if not ch.isdigit():
                break
            head += ch
        if not head:
            break
        digits.append(int(head))
    return tuple(digits)


def python_for(minimum: str) -> str:
    """An interpreter satisfying `minimum`, or fail closed naming what is missing."""
    want = version_tuple(minimum)
    candidates = [sys.executable]
    if len(want) >= 2:
        candidates += [f"python{want[0]}.{minor}" for minor in range(want[1], want[1] + 10)]
    candidates.append("python3")
    for candidate in candidates:
        try:
            out = subprocess.run([candidate, "--version"], capture_output=True,
                                 text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            continue
        got = version_tuple((out.stdout + out.stderr).replace("Python", "").strip())
        if got >= want:
            return candidate
    fail(f"no python >= {minimum} found (tried: {', '.join(candidates)}) -- "
         "a venv built by an older interpreter would import nothing the "
         "worker needs, so this refuses rather than build one")
    return ""


def check_requires(manifest: dict) -> dict:
    """Enforce setup.requires. Returns resolved tool paths for the callers that need one."""
    resolved = {}
    for req in manifest.get("setup", {}).get("requires", []):
        tool = str(req.get("tool", ""))
        minimum = str(req.get("min", "0"))
        if tool == "python":
            resolved["python"] = python_for(minimum)
            continue
        probe = VERSION_PROBE.get(tool)
        if probe is None:
            fail(f"manifest requires unknown tool '{tool}' -- refusing to "
                 "assume it is present")
        argv, field = probe
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            fail(f"'{tool}' (>= {minimum}) is not installed, but this plugin's "
                 "manifest requires it to build")
            continue
        words = out.stdout.split()
        got = version_tuple(words[field]) if len(words) > field else ()
        if got < version_tuple(minimum):
            fail(f"{tool} {'.'.join(map(str, got)) or '?'} is older than the "
                 f"manifest's required {minimum}")
        resolved[tool] = tool
    return resolved


def phases_for(step: dict, plugin_dir: str, tools: dict) -> list[dict]:
    """One phase per subprocess a step spawns (python_venv has two).

    Each phase: {"label", "argv" ([] = no subprocess), "artifact"
    (plugin-relative expected artifact, "" = nothing to check)}.
    """
    kind = str(step.get("type", ""))

    if kind == "go_build":
        output = str(step.get("output", ""))
        return [{
            "label": "go build",
            "argv": ["go", "build", "-C", plugin_dir, "-o", output,
                     str(step.get("package", ""))],
            "artifact": output,
        }]

    if kind == "cargo_build":
        manifest_dir = str(step.get("manifest_dir", ""))
        profile = str(step.get("profile", "release"))
        argv = ["cargo", "build", "--locked", "--manifest-path",
                os.path.join(plugin_dir, manifest_dir, "Cargo.toml")]
        if profile == "release":
            argv.append("--release")
        elif profile != "debug":
            argv += ["--profile", profile]
        return [{"label": "cargo build", "argv": argv,
                 "artifact": str(step.get("artifact", ""))}]

    if kind == "python_venv":
        dir_field = str(step.get("dir", ""))
        dir_abs = os.path.join(plugin_dir, dir_field)
        venv_abs = os.path.join(dir_abs, ".venv")
        marker = os.path.join(dir_field, ".venv", "pyvenv.cfg")
        venv_python = os.path.join(
            venv_abs, "Scripts/python.exe" if os.name == "nt" else "bin/python")
        install = [venv_python, "-m", "pip", "install"]
        if str(step.get("install", "")) == "editable":
            install += ["-e", dir_abs]
        else:
            install += ["-r", os.path.join(
                dir_abs, str(step.get("requirements_file", "requirements.txt")))]
        return [
            {"label": "venv create",
             "argv": [tools.get("python", sys.executable), "-m", "venv", venv_abs],
             "artifact": marker},
            {"label": "pip install", "argv": install, "artifact": marker},
        ]

    if kind == "copy":
        return [{"label": "copy", "argv": [],
                 "copy": (str(step.get("from", "")), str(step.get("to", ""))),
                 "artifact": str(step.get("to", ""))}]

    if kind == "exec":
        argv = []
        for i, raw in enumerate(step.get("argv", [])):
            arg = str(raw)
            # Only argv[0] gets the "./" resolution; everything after is
            # passed verbatim -- no path rewriting, no expansion of any kind.
            if i == 0 and arg.startswith("./"):
                arg = os.path.join(plugin_dir, arg[2:])
            argv.append(arg)
        return [{"label": "exec", "argv": argv,
                 "artifact": str(step.get("artifact", ""))}]

    fail(f"unknown setup step type '{kind}' -- refusing to guess a build")
    return []


def timeout_of(step: dict) -> int:
    raw = step.get("timeout_s", DEFAULT_TIMEOUT_S)
    if isinstance(raw, (int, float)) and raw > 0:
        return int(round(raw))
    return DEFAULT_TIMEOUT_S


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: build_plugin_from_manifest.py <plugin-dir>")
    plugin_dir = os.path.realpath(sys.argv[1])
    manifest_path = os.path.join(plugin_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        fail(f"no manifest.json in {plugin_dir}")
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)

    tools = check_requires(manifest)
    steps = manifest.get("setup", {}).get("steps", [])
    if not steps:
        fail(f"{manifest_path} declares no setup.steps -- there is no "
             "documented producer to run, so the binary under test cannot be "
             "proven to come from this revision")

    report = {"plugin_dir": plugin_dir, "tools": tools, "steps": []}
    for step in steps:
        budget = timeout_of(step)
        for phase in phases_for(step, plugin_dir, tools):
            started = time.time()
            label = f"{step.get('type')}/{phase['label']}"
            if "copy" in phase:
                src, dst = phase["copy"]
                src_abs = os.path.join(plugin_dir, src)
                dst_abs = os.path.join(plugin_dir, dst)
                if not os.path.isfile(src_abs):
                    fail(f"{label}: source '{src_abs}' does not exist")
                shutil.copy2(src_abs, dst_abs)
                rc = 0
            else:
                print(f"--- {label}: {' '.join(phase['argv'])}", file=sys.stderr)
                try:
                    rc = subprocess.call(phase["argv"], cwd=plugin_dir,
                                         stdout=sys.stderr, timeout=budget)
                except FileNotFoundError as exc:
                    fail(f"{label}: {exc} -- the toolchain this plugin's "
                         "manifest requires is not installed")
                    rc = 127
                except subprocess.TimeoutExpired:
                    fail(f"{label}: exceeded the manifest's {budget}s budget")
                    rc = 124
            if rc != 0:
                fail(f"{label}: exited {rc}")
            artifact = phase.get("artifact", "")
            if artifact and not os.path.exists(
                    os.path.join(plugin_dir, artifact)):
                fail(f"{label}: declared artifact '{artifact}' does not exist "
                     "after the step succeeded")
            report["steps"].append({
                "step": label,
                "artifact": artifact,
                "seconds": round(time.time() - started, 2),
            })

    json.dump(report, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
