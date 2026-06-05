"""Godot runtime-diagnostics capture + normalization (bug 019e93d8f1).

The AUTONOMOUS sink of the dual-mode probe: run a Godot project headless and
parse the engine's stderr into a normalized ``godot_diagnostics`` record that an
agent can consume identically to the human-assist (editor-scrape) sink.

Proven on godot 4.6.2 (see nudge codetools/probe.godot-headless-diagnostics):
``godot --headless --path <proj> --quit-after <N> [--verbose]`` runs with no
display / audio device / human and prints diagnostics in a two-line shape::

    WARNING: <message>
         at: <function> (<file>:<line>)

Severity prefixes seen in the wild: ``WARNING`` / ``ERROR`` (engine),
``USER WARNING`` / ``USER ERROR`` (push_warning/push_error from GDScript),
``SCRIPT ERROR`` (runtime script faults). ``file`` may be engine C++
(``core/object/object.cpp``) rather than user script — callers fix only
``user_fixable`` (``res://…``) diagnostics and leave engine-internal noise.

This module is first-party (sightline is de-vendored; see VENDORING.md). The
subprocess runner is injectable so the parser + driver are unit-testable without
spawning a real Godot.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Any, Callable, NamedTuple

# Header line: "SEVERITY: message". Longer prefixes first so "USER WARNING"
# wins over "WARNING" and "SCRIPT ERROR" over "ERROR".
_HEADER_RE = re.compile(
    r"^(?P<sev>USER WARNING|USER ERROR|SCRIPT ERROR|WARNING|ERROR):\s?(?P<msg>.*)$"
)
# Continuation line: "   at: <function> (<file>:<line>)".
_AT_RE = re.compile(
    r"^\s*at:\s*(?P<func>.*?)\s*\((?P<file>.+):(?P<line>\d+)\)\s*$"
)

# Normalized severities.
_SEVERITY = {
    "WARNING": "warning",
    "USER WARNING": "warning",
    "ERROR": "error",
    "USER ERROR": "error",
    "SCRIPT ERROR": "script_error",
}

# Curated Godot diagnostics that print WITHOUT a SEVERITY: prefix and so are
# missed by _HEADER_RE (019e988adc59). Each entry is (regex, severity). These
# have no `at:` location, so file/line stay None and user_fixable is False
# (they're engine-level, not attributable to a res:// script). Keep this list
# tight + observed — speculative patterns risk false positives. Extend as new
# unprefixed lines are seen in the wild.
_UNPREFIXED_PATTERNS = [
    # Resource loader hits embedded NUL bytes while parsing text (seen 4x in the
    # Minerva headless probe 2026-06-05).
    (re.compile(r"^Unicode parsing error\b"), "warning"),
]


class RunResult(NamedTuple):
    """What a runner returns: combined output + how the process ended."""

    exit_code: int | None
    output: str
    timed_out: bool


# A runner takes (command, timeout_seconds) and returns a RunResult. Injectable
# so tests drive the parser/driver without a real Godot subprocess.
Runner = Callable[[list[str], float], RunResult]


def parse_godot_output(text: str) -> list[dict[str, Any]]:
    """Parse Godot stdout+stderr into a list of diagnostic dicts.

    Each diagnostic: {severity, message, file, line, function, user_fixable}.
    A header with no following ``at:`` line yields file/line/function = None.
    """
    diagnostics: list[dict[str, Any]] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        header = _HEADER_RE.match(lines[i])
        if not header:
            # Not a SEVERITY:-prefixed line — check the curated unprefixed set.
            for pattern, severity in _UNPREFIXED_PATTERNS:
                if pattern.search(lines[i]):
                    diagnostics.append({
                        "severity": severity,
                        "message": lines[i].strip(),
                        "file": None,
                        "line": None,
                        "function": None,
                        "user_fixable": False,
                    })
                    break
            i += 1
            continue
        sev_raw = header.group("sev")
        diag: dict[str, Any] = {
            "severity": _SEVERITY[sev_raw],
            "message": header.group("msg").strip(),
            "file": None,
            "line": None,
            "function": None,
            "user_fixable": False,
        }
        # The location is on the immediately following line, if present.
        if i + 1 < len(lines):
            at = _AT_RE.match(lines[i + 1])
            if at:
                file_ = at.group("file").strip()
                diag["file"] = file_
                diag["line"] = int(at.group("line"))
                diag["function"] = at.group("func").strip() or None
                diag["user_fixable"] = file_.startswith("res://")
                i += 1  # consume the at: line
        diagnostics.append(diag)
        i += 1
    return diagnostics


# Location embedded in a probe-scraped debugger row, e.g. "res://main.gd:42".
_LOC_RE = re.compile(r"(res://[^\s:()]+):(\d+)")
# Leading severity prefix on a scraped debugger label, stripped for the message.
_PREFIX_RE = re.compile(
    r"^(SCRIPT ERROR|USER ERROR|USER WARNING|ERROR|WARNING)\s*:\s*", re.IGNORECASE
)


def _counts(diagnostics: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"warning": 0, "error": 0, "script_error": 0}
    for diag in diagnostics:
        counts[diag["severity"]] = counts.get(diag["severity"], 0) + 1
    return counts


def _record(
    source: str,
    diagnostics: list[dict[str, Any]],
    exit_code: int | None,
    timed_out: bool,
    log_path: str | None,
) -> dict[str, Any]:
    """Assemble the normalized godot_diagnostics record (shared by both sinks)."""
    record: dict[str, Any] = {
        "type": "godot_diagnostics",
        "source": source,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "diagnostics": diagnostics,
        "counts": _counts(diagnostics),
    }
    if log_path is not None:
        record["log_path"] = log_path
    return record


def diagnostics_record(
    *,
    source: str,
    output: str,
    exit_code: int | None,
    timed_out: bool,
    log_path: str | None = None,
) -> dict[str, Any]:
    """Normalized record from raw stdout+stderr text (headless sink)."""
    return _record(source, parse_godot_output(output), exit_code, timed_out, log_path)


def probe_state_to_diagnostics(state: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Map a sightline editor-probe debugger_state.json into diagnostics.

    The probe scrapes the editor's Debugger panel labels, which carry a
    pre-classified ``severity`` + raw ``text``. There is usually no structured
    file:line (it's UI text), so location is best-effort (parse a ``res://…:NN``
    out of the text when present).
    """
    diagnostics: list[dict[str, Any]] = []
    debugger = (state or {}).get("debugger") or {}
    for row in debugger.get("rows") or []:
        severity = row.get("severity")
        if severity not in ("warning", "error", "script_error"):
            severity = "warning"
        text = str(row.get("text") or "").strip()
        message = _PREFIX_RE.sub("", text).strip() or text
        file_: str | None = None
        line_: int | None = None
        loc = _LOC_RE.search(text)
        if loc:
            file_ = loc.group(1)
            line_ = int(loc.group(2))
        diagnostics.append({
            "severity": severity,
            "message": message,
            "file": file_,
            "line": line_,
            "function": None,
            "user_fixable": bool(file_ and file_.startswith("res://")),
        })
    return diagnostics


def diagnostics_record_from_probe(
    state: dict[str, Any] | None,
    *,
    exit_code: int | None = None,
    timed_out: bool = False,
    log_path: str | None = None,
) -> dict[str, Any]:
    """Normalized record from a probe debugger_state.json (editor-assist sink)."""
    return _record(
        "editor-probe", probe_state_to_diagnostics(state), exit_code, timed_out, log_path
    )


def _default_runner(command: list[str], timeout_seconds: float) -> RunResult:
    """Run a command, combine stdout+stderr, honor a wall-clock timeout."""
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
        return RunResult(completed.returncode, completed.stdout or "", False)
    except subprocess.TimeoutExpired as exc:
        partial = exc.output or ""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", errors="replace")
        return RunResult(None, partial, True)


def build_headless_command(
    project_path: Path,
    *,
    scene: str | None,
    quit_after: int,
    verbose: bool,
    godot_bin: str,
) -> list[str]:
    """Compose the headless invocation. Pure — unit-testable in isolation."""
    command = [godot_bin, "--headless", "--path", str(project_path)]
    if scene:
        command.append(scene)
    command += ["--quit-after", str(int(quit_after))]
    if verbose:
        command.append("--verbose")
    return command


def run_headless(
    project_path: Path,
    *,
    scene: str | None = None,
    quit_after: int = 200,
    verbose: bool = False,
    timeout_seconds: float = 60.0,
    godot_bin: str = "godot",
    runner: Runner | None = None,
    log_path: str | None = None,
) -> dict[str, Any]:
    """Drive Godot headless and return a normalized godot_diagnostics record.

    ``runner`` defaults to a real subprocess; inject a fake in tests. No probe,
    no display, no human — structurally immune to the editor-clobber bug.
    """
    command = build_headless_command(
        project_path,
        scene=scene,
        quit_after=quit_after,
        verbose=verbose,
        godot_bin=godot_bin,
    )
    run = runner or _default_runner
    result = run(command, timeout_seconds)
    record = diagnostics_record(
        source="headless-stderr",
        output=result.output,
        exit_code=result.exit_code,
        timed_out=result.timed_out,
        log_path=log_path,
    )
    record["godot_command"] = command
    return record
