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


# A bare GDScript file:line as the debugger error tree's detail rows render it,
# e.g. "<GDScript Source>MCPEditorTools.gd:344" or a stack frame "Core.gd:645".
_GD_FILE_LINE_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*\.gd):(\d+)")


def _looks_like_warning(blob: str) -> bool:
    """True for debugger error-tree rows that are real warnings/errors (vs profiler
    or other tree noise that the error-tree scrape may also pick up)."""
    low = blob.lower()
    return (
        "gdscript::reload" in low
        or low.startswith("warning")
        or low.startswith("error")
        or "script error" in low
        or _GD_FILE_LINE_RE.search(blob) is not None
        or _LOC_RE.search(blob) is not None
    )


def _debugger_rows_to_diagnostics(state: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Debugger error-tree rows → diagnostics. Each row may carry `details` (its
    child rows: <GDScript Source>file.gd:line, stack frames). Pull the location
    from the row text OR its details — res://…:NN if present, else a bare X.gd:NN
    (resolved to res:// later by resolve_file_locations)."""
    diagnostics: list[dict[str, Any]] = []
    debugger = (state or {}).get("debugger") or {}
    for row in debugger.get("rows") or []:
        text = str(row.get("text") or "").strip()
        details = row.get("details") or []
        blob = text + " " + " ".join(str(d) for d in details)
        if not _looks_like_warning(blob):
            continue  # skip non-warning tree noise
        severity = row.get("severity")
        if severity not in ("warning", "error", "script_error"):
            severity = "warning"
        message = _PREFIX_RE.sub("", text).strip() or text
        file_: str | None = None
        line_: int | None = None
        loc = _LOC_RE.search(blob)  # prefer a full res://…:NN
        if loc:
            file_ = loc.group(1)
            line_ = int(loc.group(2))
        else:
            bare = _GD_FILE_LINE_RE.search(blob)  # else the first bare X.gd:NN
            if bare:
                file_ = bare.group(1)
                line_ = int(bare.group(2))
        diag: dict[str, Any] = {
            "severity": severity,
            "message": message,
            "file": file_,
            "line": line_,
            "function": None,
            "user_fixable": bool(file_ and str(file_).startswith("res://")),
        }
        if details:
            diag["details"] = [str(d) for d in details]
        diagnostics.append(diag)
    return diagnostics


def _warning_entry_to_diag(warning: dict, script) -> dict[str, Any] | None:
    """One script-editor warnings-panel entry ({line, code, message}) → diagnostic
    with the exact res:// file:line (file = the script it belongs to)."""
    message = str(warning.get("message") or "").strip()
    if not message:
        return None
    raw_line = warning.get("line")
    line_ = int(raw_line) if isinstance(raw_line, (int, float)) else None
    return {
        "severity": "warning",
        "message": message,
        "file": script,
        "line": line_,
        "function": None,
        "user_fixable": bool(script and str(script).startswith("res://")),
        "source_panel": "script_editor",
    }


def _script_editor_diagnostics(state: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Script-editor warnings (fix 2) → diagnostics WITH exact res:// file:line.
    Covers the current active script AND the automatic open-scripts sweep (each
    {script, warnings:[…]}). Dedup in probe_state_to_diagnostics collapses overlap."""
    se = (state or {}).get("script_editor") or {}
    diagnostics: list[dict[str, Any]] = []
    current = se.get("current_script") or None
    for warning in se.get("warnings") or []:
        diag = _warning_entry_to_diag(warning, current)
        if diag:
            diagnostics.append(diag)
    sweep = se.get("sweep") or {}
    for entry in sweep.get("scripts") or []:
        path = entry.get("script") or None
        for warning in entry.get("warnings") or []:
            diag = _warning_entry_to_diag(warning, path)
            if diag:
                diagnostics.append(diag)
    return diagnostics


def _dedup_key(message: str) -> str:
    """Normalize a warning message so the same warning from the Debugger panel and
    the Script-editor panel collapses to one key (strip timestamp/reload prefix)."""
    s = message.lower()
    s = re.sub(r"\d+:\d+:\d+:\d+", "", s)
    s = re.sub(r"gdscript::reload:\s*", "", s)
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    return s[:80]


def probe_state_to_diagnostics(state: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Map a probe debugger_state.json into diagnostics, merging the Script-editor
    Warnings panel (exact file:line — fix 2) with the Debugger rows, deduped so the
    same warning collapses to its best-located copy (script-editor > resolved > none)."""
    # Script-editor diags first so they WIN ties (they carry the exact line).
    merged = _script_editor_diagnostics(state) + _debugger_rows_to_diagnostics(state)
    by_key: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for diag in merged:
        key = _dedup_key(diag["message"])
        if key not in by_key:
            by_key[key] = diag
            order.append(key)
        elif by_key[key].get("line") is None and diag.get("line") is not None:
            by_key[key] = diag  # upgrade to the located copy
    return [by_key[key] for key in order]


# ── Symbol-resolution (fix 1) ──────────────────────────────────────────────
# Editor-reload GDScript warnings reach the probe with NO res:// file:line (Godot
# emits them with only the C++ `GDScript::reload` source). But the message usually
# NAMES a function ("…in the function \"_draw_line_marker()\""), so we resolve the
# location by grepping `func <name>(` under the project root. Only unique matches
# are accepted — ambiguous names are left unresolved rather than guessed.
_FUNC_IN_MSG_RE = re.compile(r'(?:function|method)\s+"(\w+)\(?\)?"')
_BARE_FUNC_RE = re.compile(r'"(\w+)\(\)"')


def _function_names_in_message(message: str) -> list[str]:
    names: list[str] = []
    for match in _FUNC_IN_MSG_RE.finditer(message):
        if match.group(1) not in names:
            names.append(match.group(1))
    for match in _BARE_FUNC_RE.finditer(message):
        if match.group(1) not in names:
            names.append(match.group(1))
    return names


def _build_func_index(root: str, names: set[str]) -> dict[str, tuple[str, int]]:
    """Single walk of *.gd under root → {name: (res://path, line)} for each name
    with EXACTLY ONE `func <name>(` definition (ambiguous → omitted, never guessed)."""
    if not names:
        return {}
    patterns = {
        name: re.compile(r"^\s*(?:static\s+)?func\s+" + re.escape(name) + r"\s*\(")
        for name in names
    }
    found: dict[str, list[tuple[str, int]]] = {name: [] for name in names}
    root_path = Path(root)
    for gd in root_path.rglob("*.gd"):
        try:
            text = gd.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = "res://" + gd.relative_to(root_path).as_posix()
        for lineno, line in enumerate(text.splitlines(), 1):
            for name, pattern in patterns.items():
                if pattern.match(line):
                    found[name].append((rel, lineno))
    return {name: locs[0] for name, locs in found.items() if len(locs) == 1}


def resolve_symbol_locations(diagnostics, root, *, finder=None):
    """Fill file/line for location-less diagnostics by resolving a named function
    to its `func <name>(` definition under root. finder(root, names) ->
    {name: (res_path, line)}, injectable for tests. Mutates + returns diagnostics."""
    unresolved = [d for d in diagnostics if not d.get("file")]
    if not unresolved:
        return diagnostics
    name_to_diags: dict[str, list] = {}
    for diag in unresolved:
        for name in _function_names_in_message(str(diag.get("message", ""))):
            name_to_diags.setdefault(name, []).append(diag)
    if not name_to_diags:
        return diagnostics
    finder = finder or _build_func_index
    locations = finder(root, set(name_to_diags))
    for name, diags in name_to_diags.items():
        loc = locations.get(name)
        if not loc:
            continue
        for diag in diags:
            if diag.get("file"):
                continue
            diag["file"], diag["line"] = loc[0], loc[1]
            diag["function"] = name
            diag["user_fixable"] = str(loc[0]).startswith("res://")
            diag["resolved_via"] = "symbol-grep"
    return diagnostics


def _build_file_index(root: str, filenames: set[str]) -> dict[str, str]:
    """{bare filename: res://path} for each filename with EXACTLY ONE match under
    root (ambiguous → omitted, never guessed)."""
    if not filenames:
        return {}
    found: dict[str, list[str]] = {}
    root_path = Path(root)
    for gd in root_path.rglob("*.gd"):
        if gd.name in filenames:
            found.setdefault(gd.name, []).append(
                "res://" + gd.relative_to(root_path).as_posix())
    return {name: paths[0] for name, paths in found.items() if len(paths) == 1}


def resolve_file_locations(diagnostics, root, *, finder=None):
    """Turn a bare ``X.gd`` file (from a debugger detail row) into its res:// path
    under root. Mutates + returns diagnostics."""
    bare: dict[str, list] = {}
    for diag in diagnostics:
        file_ = diag.get("file")
        if isinstance(file_, str) and file_.endswith(".gd") and not file_.startswith("res://"):
            bare.setdefault(file_, []).append(diag)
    if not bare:
        return diagnostics
    finder = finder or _build_file_index
    locations = finder(root, set(bare))
    for filename, diags in bare.items():
        res = locations.get(filename)
        if not res:
            continue
        for diag in diags:
            diag["file"] = res
            diag["user_fixable"] = True
            diag.setdefault("resolved_via", "file-grep")
    return diagnostics


def diagnostics_record_from_probe(
    state: dict[str, Any] | None,
    *,
    exit_code: int | None = None,
    timed_out: bool = False,
    log_path: str | None = None,
    root: str | None = None,
    finder=None,
) -> dict[str, Any]:
    """Normalized record from a probe debugger_state.json (editor-assist sink).

    If ``root`` is given, diagnostics are located: bare ``X.gd`` files from the
    debugger detail rows → res:// paths (resolve_file_locations), and any still
    location-less warning that names a function → its def via symbol-grep (fix 1)."""
    diagnostics = probe_state_to_diagnostics(state)
    if root:
        resolve_file_locations(diagnostics, root)
        resolve_symbol_locations(diagnostics, root, finder=finder)
    return _record("editor-probe", diagnostics, exit_code, timed_out, log_path)


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
