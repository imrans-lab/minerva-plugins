"""minerva_codetools_grep handler (P2.1).

Regex search over file contents using bundled ripgrep (rg).

When rg is available (via rg_finder.find_rg()), it is used for fast, accurate
search with full regex support. rg output (JSON lines format) is parsed into
structured artifacts. Binary files are detected/skipped by rg automatically.

Falls back to pure-Python if rg is not found — this supports dev boxes without
a built bundle, but is slower and the binary-detection heuristic is simpler.

Type-filter map mirrors GrepTool.gd's TYPE_EXTENSIONS.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

from .. import envelope
from ..errors import ToolError
from .paths import expand_and_resolve
from .rg_finder import find_rg
from .runner import MAX_OUTPUT_BYTES, RunResult
from .walker import EXCLUDE_DIRS, iter_files

_DEFAULT_LIMIT = 200

# Mirrors GrepTool.gd's TYPE_EXTENSIONS.
TYPE_EXTENSIONS: dict[str, list[str]] = {
    "py":       [".py", ".pyi"],
    "js":       [".js", ".mjs", ".cjs"],
    "ts":       [".ts", ".tsx"],
    "go":       [".go"],
    "rust":     [".rs"],
    "java":     [".java"],
    "c":        [".c", ".h"],
    "cpp":      [".cpp", ".cc", ".cxx", ".hpp", ".hh"],
    "gd":       [".gd"],
    "gdscript": [".gd"],
    "sh":       [".sh", ".bash"],
    "md":       [".md", ".markdown"],
    "json":     [".json"],
    "yaml":     [".yaml", ".yml"],
    "toml":     [".toml"],
    "html":     [".html", ".htm"],
    "css":      [".css", ".scss", ".sass"],
    "zig":      [".zig"],
}


def handle_grep(params: dict) -> dict:
    """Route entry point for the 'grep' worker method."""
    pattern = params.get("pattern", "")
    if not pattern:
        raise ToolError("'pattern' is required", kind="parse")

    raw_path = params.get("path") or ""
    file_glob = params.get("file_glob") or ""
    type_filter = params.get("type") or ""
    ignore_case = bool(params.get("ignore_case", False))
    context_before = int(params.get("context_before", params.get("context_lines", 0)))
    context_after = int(params.get("context_after", params.get("context_lines", 0)))
    limit = int(params.get("limit", _DEFAULT_LIMIT))

    # Resolve search path.
    if raw_path:
        search_path = expand_and_resolve(raw_path)
    else:
        search_path = Path(os.getcwd())

    if not search_path.exists():
        raise ToolError("Path does not exist: %s" % search_path, kind="not_found")

    rg_bin = find_rg()

    if rg_bin:
        return _grep_with_rg(
            rg_bin, pattern, search_path, file_glob, type_filter,
            ignore_case, context_before, context_after, limit,
        )
    else:
        return _grep_python(
            pattern, search_path, file_glob, type_filter,
            ignore_case, context_before, context_after, limit,
        )


# ---------------------------------------------------------------------------
# rg-based implementation
# ---------------------------------------------------------------------------

def _grep_with_rg(
    rg_bin: str,
    pattern: str,
    search_path: Path,
    file_glob: str,
    type_filter: str,
    ignore_case: bool,
    context_before: int,
    context_after: int,
    limit: int,
) -> dict:
    cmd = [rg_bin, "--json"]

    if ignore_case:
        cmd.append("--ignore-case")
    if context_before > 0:
        cmd += ["-B", str(context_before)]
    if context_after > 0:
        cmd += ["-A", str(context_after)]

    # Type filter: rg has built-in type aliases; for our custom map, use glob.
    if type_filter and type_filter in TYPE_EXTENSIONS:
        for ext in TYPE_EXTENSIONS[type_filter]:
            cmd += ["--glob", "*%s" % ext]
    elif file_glob:
        cmd += ["--glob", file_glob]

    # Exclude noise dirs (rg respects .gitignore already, but force these).
    for d in EXCLUDE_DIRS:
        cmd += ["--glob", "!%s" % d]

    cmd += [pattern, str(search_path)]

    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        raw_out = proc.stdout[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace")
        truncated_output = len(proc.stdout) > MAX_OUTPUT_BYTES
    except subprocess.TimeoutExpired:
        raise ToolError("grep timed out (60s)", kind="timeout")
    except OSError as exc:
        raise ToolError("Failed to run rg: %s" % exc, kind="error")

    matches, total, truncated = _parse_rg_json(raw_out, limit)
    if truncated_output and not truncated:
        truncated = True

    summary = "grep '%s': %d match%s" % (
        pattern, total, "es" if total != 1 else "")
    if truncated:
        summary += " (showing first %d)" % len(matches)

    return envelope.ok(
        summary,
        artifacts=[{
            "type": "grep_result",
            "pattern": pattern,
            "path": str(search_path),
            "matches": matches,
            "total_matches": total,
            "truncated": truncated,
            "backend": "rg",
        }],
    )


def _parse_rg_json(raw: str, limit: int) -> tuple[list[dict], int, bool]:
    """Parse rg --json output into structured match dicts.

    rg JSON lines can be: type=begin, type=match, type=context, type=end,
    type=summary. We care about type=match (and context lines for before/after).
    """
    matches: list[dict] = []
    current_file: str | None = None
    context_before: list[str] = []
    pending_match: dict | None = None
    total = 0

    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        msg_type = msg.get("type")
        data = msg.get("data", {})

        if msg_type == "begin":
            current_file = _rg_text(data.get("path"))
            context_before = []
            pending_match = None

        elif msg_type == "context":
            line_text = _rg_text(data.get("lines"))
            if pending_match is not None:
                pending_match.setdefault("context_after", []).append(
                    line_text.rstrip("\n"))
            else:
                context_before.append(line_text.rstrip("\n"))

        elif msg_type == "match":
            # Flush previous pending match now that we know its context_after.
            if pending_match is not None and len(matches) < limit:
                matches.append(pending_match)
            total += 1
            line_text = _rg_text(data.get("lines"))
            line_num = data.get("line_number", 0)
            new_match: dict = {
                "file": current_file or str(data.get("path", "")),
                "line": line_num,
                "content": line_text.rstrip("\n"),
            }
            if context_before:
                new_match["context_before"] = list(context_before)
            context_before = []
            pending_match = new_match

        elif msg_type == "end":
            if pending_match is not None and len(matches) < limit:
                matches.append(pending_match)
            pending_match = None
            context_before = []

    # summary type carries the total match count from rg
    # We compute total ourselves above.
    truncated = total > limit
    return matches, total, truncated


def _rg_text(field) -> str:
    """Extract text from an rg JSON text/bytes field."""
    if field is None:
        return ""
    if isinstance(field, str):
        return field
    if isinstance(field, dict):
        return field.get("text") or field.get("bytes") or ""
    return str(field)


# ---------------------------------------------------------------------------
# Pure-Python fallback (no rg)
# ---------------------------------------------------------------------------

def _grep_python(
    pattern: str,
    search_path: Path,
    file_glob: str,
    type_filter: str,
    ignore_case: bool,
    context_before: int,
    context_after: int,
    limit: int,
) -> dict:
    flags = re.IGNORECASE if ignore_case else 0
    try:
        rx = re.compile(pattern, flags)
    except re.error as exc:
        raise ToolError("Invalid regex: %s" % exc, kind="parse")

    # Determine allowed extensions for type filter.
    allowed_exts: list[str] | None = None
    if type_filter and type_filter in TYPE_EXTENSIONS:
        allowed_exts = TYPE_EXTENSIONS[type_filter]

    matches: list[dict] = []
    total = 0

    if search_path.is_file():
        total_ref = [0]
        _search_file_py(
            search_path, str(search_path), rx, allowed_exts, file_glob,
            context_before, context_after, limit, matches, total_ref,
        )
        total = total_ref[0]
    else:
        total_ref = [0]
        for rel in iter_files(search_path):
            fp = search_path / rel
            if not _ext_ok(rel, allowed_exts, file_glob):
                continue
            if _is_binary(fp):
                continue
            _search_file_py(
                fp, rel, rx, allowed_exts, file_glob,
                context_before, context_after, limit, matches, total_ref,
            )
        total = total_ref[0]

    truncated = total > limit
    summary = "grep '%s': %d match%s (python fallback)" % (
        pattern, total, "es" if total != 1 else "")
    if truncated:
        summary += " (showing first %d)" % limit

    return envelope.ok(
        summary,
        artifacts=[{
            "type": "grep_result",
            "pattern": pattern,
            "path": str(search_path),
            "matches": matches,
            "total_matches": total,
            "truncated": truncated,
            "backend": "python",
        }],
    )


def _search_file_py(
    fp: Path,
    display_path: str,
    rx: re.Pattern,
    allowed_exts,
    file_glob: str,
    ctx_before: int,
    ctx_after: int,
    limit: int,
    matches: list,
    total_ref: list,
) -> None:
    try:
        text = fp.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if rx.search(line):
            total_ref[0] += 1
            if len(matches) < limit:
                m: dict = {
                    "file": display_path,
                    "line": i + 1,
                    "content": line,
                }
                if ctx_before > 0:
                    m["context_before"] = lines[max(0, i - ctx_before):i]
                if ctx_after > 0:
                    m["context_after"] = lines[i + 1:i + 1 + ctx_after]
                matches.append(m)


def _ext_ok(rel: str, allowed_exts: list[str] | None, file_glob: str) -> bool:
    if allowed_exts is not None:
        if not any(rel.endswith(ext) for ext in allowed_exts):
            return False
    if file_glob:
        import fnmatch as _fn
        if not _fn.fnmatch(os.path.basename(rel), file_glob) and not _fn.fnmatch(rel, file_glob):
            return False
    return True


def _is_binary(path: Path) -> bool:
    """Heuristic: file is binary if it contains a null byte in the first 8 KB."""
    try:
        chunk = path.read_bytes()[:8192]
        return b"\x00" in chunk
    except OSError:
        return True
