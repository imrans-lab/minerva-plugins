"""Locate the bundled `rg` (ripgrep) binary for the Code Tools worker (P2.1).

Strategy (in priority order):
  1. Bundle-relative path: <bundle_root>/bin/rg  (or rg.exe on Windows).
     The bundle root is the directory that contains the Python interpreter
     the worker is running under — resolved via sys.executable → parent[s].
  2. Logged fallback: shutil.which("rg")  — for dev boxes where rg is on PATH.
     The fallback is always logged so a production mismatch is obvious in the
     activity log.

The bundle layout (after build-python-runtime-bundle.sh places rg):

  runtime-bundle-<triple>/
    bin/
      python3          # the bundled interpreter
      rg               # ← placed here by build script (step: rg-inject)
    lib/
      python3.12/
        site-packages/
          codetools_worker/
            ...

P4 DRY-convergence candidate: generalise into a "bundled binary finder" utility
if other subsystems also vendor native binaries.
"""

from __future__ import annotations

import logging
import os
import shutil
import sys
from pathlib import Path

log = logging.getLogger(__name__)

# On Windows the binary is rg.exe; everywhere else just rg.
_RG_NAME = "rg.exe" if sys.platform == "win32" else "rg"


def find_rg() -> str | None:
    """Return an absolute path to an `rg` binary, or None if none is found.

    Checks the bundle-relative location first, then falls back to PATH.
    Both hits and misses are logged at DEBUG; the PATH fallback is additionally
    logged at INFO so it's visible in the Activity log without spamming.
    """
    # -- Bundle-relative probe -----------------------------------------------
    # sys.executable resolves to  <bundle>/bin/python3  inside the bundle.
    # Walk up from there to find a sibling `bin/rg`.
    exe = Path(sys.executable).resolve()
    # Try: <dir-of-exe>/rg  (e.g. bundle/bin/rg alongside bundle/bin/python3)
    candidate = exe.parent / _RG_NAME
    if candidate.is_file() and os.access(candidate, os.X_OK):
        log.debug("rg: found in bundle (alongside interpreter): %s", candidate)
        return str(candidate)

    # -- PATH fallback --------------------------------------------------------
    path_rg = shutil.which("rg")
    if path_rg:
        log.info(
            "rg: falling back to system PATH: %s "
            "(bundle rg not found at %s — expected after build-python-runtime-bundle.sh)",
            path_rg,
            candidate,
        )
        return path_rg

    log.warning(
        "rg: binary not found (checked %s and PATH). "
        "Run build-python-runtime-bundle.sh to inject the bundled rg.",
        candidate,
    )
    return None
