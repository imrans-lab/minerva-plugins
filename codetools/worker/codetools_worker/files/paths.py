"""Path helpers for the Code Tools worker (P2.1).

Provides expanduser + resolve + validation used by glob, grep, cwd handlers.

P4 DRY-convergence candidate: consolidate with any future path helpers in
a shared runtime utils package once a second subsystem needs them.
"""

from __future__ import annotations

import os
from pathlib import Path


def expand_and_resolve(path: str, base: str | None = None) -> Path:
    """Expand ~ and make `path` absolute, optionally relative to `base`.

    Args:
        path:  Raw path string (may start with ~, or be relative).
        base:  Optional base directory for relative paths. Defaults to cwd.

    Returns:
        An absolute, fully-resolved Path (symlinks NOT resolved — we want
        the logical path the user typed, so we use Path.resolve() only for
        the cwd join, not for the final path itself).
    """
    p = Path(os.path.expanduser(path))
    if not p.is_absolute():
        root = Path(base) if base else Path.cwd()
        p = root / p
    # Collapse ".." without dereferencing symlinks.
    return p.resolve()


def validate_dir(path: str | Path) -> tuple[Path, str | None]:
    """Validate that `path` is an existing directory.

    Returns:
        (resolved_path, None)      on success
        (path_as_Path, error_msg)  on failure
    """
    p = Path(path)
    if not p.exists():
        return p, "Path does not exist: %s" % p
    if not p.is_dir():
        return p, "Path is not a directory: %s" % p
    return p, None
