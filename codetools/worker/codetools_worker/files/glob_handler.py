"""minerva_codetools_glob handler (P2.1).

Finds files matching a glob pattern under a base directory, with:
  - *, **, ? wildcard support
  - Automatic exclusion of .git, node_modules, __pycache__, etc.
  - Sorted results
  - Configurable limit with truncation signalled in the envelope summary.

Returns an envelope with a single "glob_result" artifact.
"""

from __future__ import annotations

import fnmatch
import os
import re
from pathlib import Path

from .. import envelope
from ..errors import ToolError
from .paths import expand_and_resolve, validate_dir
from .walker import iter_files

_DEFAULT_LIMIT = 500


def handle_glob(params: dict) -> dict:
    """Route entry point for the 'glob' worker method."""
    pattern = params.get("pattern", "")
    if not pattern:
        raise ToolError("'pattern' is required", kind="parse")

    raw_dir = params.get("path") or params.get("base_dir") or ""
    limit = int(params.get("limit", _DEFAULT_LIMIT))
    if limit <= 0:
        limit = 0  # 0 = unlimited

    # Resolve base directory.
    if raw_dir:
        base = expand_and_resolve(raw_dir)
    else:
        base = Path(os.getcwd())

    base, err = validate_dir(str(base))
    if err:
        raise ToolError(err, kind="not_found")

    # Collect + filter.
    matches: list[str] = []
    total = 0
    for rel in iter_files(base):
        if _matches_glob(pattern, rel):
            total += 1
            if limit == 0 or len(matches) < limit:
                matches.append(rel)

    truncated = total > len(matches)
    summary = "glob '%s': %d match%s under %s" % (
        pattern, total, "es" if total != 1 else "", base)
    if truncated:
        summary += " (showing first %d)" % len(matches)

    return envelope.ok(
        summary,
        artifacts=[{
            "type": "glob_result",
            "pattern": pattern,
            "base": str(base),
            "files": sorted(matches),
            "total_matches": total,
            "truncated": truncated,
        }],
    )


# ---------------------------------------------------------------------------
# Glob → regex conversion
# ---------------------------------------------------------------------------

def _matches_glob(pattern: str, rel_path: str) -> bool:
    """Return True if `rel_path` matches `pattern` (** / * / ? semantics).

    Uses Python's fnmatch for simple patterns and a compiled regex for patterns
    containing ** (cross-directory matching).
    """
    if "**" not in pattern:
        # fnmatch doesn't traverse slashes, but for a bare *.ext pattern we
        # want to match at any depth, so use our regex approach consistently.
        pass

    rx = _glob_to_regex(pattern)
    return bool(rx.search(rel_path))


def _glob_to_regex(pattern: str) -> re.Pattern:
    """Convert a glob pattern to a compiled regex.

    Rules (matches GlobTool.gd):
      **  → .*                (any path including /)
      *   → [^/]*             (any name chars, no /)
      ?   → [^/]              (single name char, no /)
      .   → \\.               (literal dot)
      others → re.escape
    """
    result = []
    i = 0
    n = len(pattern)
    while i < n:
        ch = pattern[i]
        if ch == "*":
            if i + 1 < n and pattern[i + 1] == "*":
                result.append(".*")
                i += 2
                # Consume optional trailing slash after **
                if i < n and pattern[i] == "/":
                    result.append("(/|$)")
                    i += 1
            else:
                result.append("[^/]*")
                i += 1
        elif ch == "?":
            result.append("[^/]")
            i += 1
        elif ch == ".":
            result.append("\\.")
            i += 1
        else:
            result.append(re.escape(ch))
            i += 1
    return re.compile("^" + "".join(result) + "$")
