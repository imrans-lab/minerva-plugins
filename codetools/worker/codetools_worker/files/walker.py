"""Ignore-aware directory walker for the Code Tools worker (P2.1).

Provides `iter_files(root, ...)` which walks a directory tree and yields
relative paths, skipping common noise directories (.git, node_modules, etc.).

P4 DRY-convergence candidate: if the code-probe or future subsystems need
directory traversal, pull this into a shared runtime utils package.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterator

# Directories always excluded during traversal (matches GlobTool.gd / GrepTool.gd).
EXCLUDE_DIRS: frozenset[str] = frozenset([
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "__pycache__",
    ".venv",
    "venv",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".godot",
    ".zig-cache",
    "dist",
    "build",
    ".egg-info",
])

# Maximum recursion depth to prevent symlink loops.
_MAX_DEPTH: int = 64


def iter_files(
    root: str | Path,
    *,
    extra_exclude: frozenset[str] | None = None,
    max_depth: int = _MAX_DEPTH,
) -> Iterator[str]:
    """Yield file paths relative to `root`, skipping excluded directories.

    Args:
        root:           Root directory to walk.
        extra_exclude:  Additional dir names to skip (merged with EXCLUDE_DIRS).
        max_depth:      Maximum recursion depth. Defaults to 64.

    Yields:
        Relative POSIX path strings (e.g. "src/foo/bar.py"), sorted within
        each directory level. Binary / unreadable entries are not filtered
        here — callers decide what to do with them.
    """
    root_path = Path(root).resolve()
    exclude = EXCLUDE_DIRS
    if extra_exclude:
        exclude = exclude | extra_exclude

    def _walk(dirpath: Path, depth: int) -> Iterator[str]:
        if depth > max_depth:
            return
        try:
            entries = sorted(dirpath.iterdir(), key=lambda e: (not e.is_symlink() and e.is_dir(), e.name))
        except PermissionError:
            return
        for entry in entries:
            # Don't follow symlinks to avoid loops; use lstat-based checks.
            is_symlink = entry.is_symlink()
            if not is_symlink and entry.is_dir():
                if entry.name in exclude:
                    continue
                yield from _walk(entry, depth + 1)
            elif not is_symlink and entry.is_file():
                try:
                    rel = entry.relative_to(root_path)
                    yield str(rel)
                except ValueError:
                    pass  # Escapes root — skip.

    yield from _walk(root_path, 0)
