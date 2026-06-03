"""minerva_codetools_cwd handler (P2.1).

Get or set the worker process's current working directory.

Unlike CwdTool.gd (which tracks a virtual cwd because GDScript has no
os.chdir()), the Python worker performs a real os.chdir() so that subsequent
bash and glob calls that default to cwd() see the correct directory.

Supports:
  - get:  returns current cwd (no 'path' param needed)
  - set:  'path' param with ~ expansion, relative-path resolution, existence
          validation, and real os.chdir().
"""

from __future__ import annotations

import os
from pathlib import Path

from .. import envelope
from ..errors import ToolError


def handle_cwd(params: dict) -> dict:
    """Route entry point for the 'cwd' worker method.

    If params contains 'path', it is a set-cwd operation; otherwise get-cwd.
    """
    raw_path = params.get("path")

    if raw_path is None:
        # GET cwd
        current = str(Path.cwd().resolve())
        return envelope.ok(
            "cwd: %s" % current,
            artifacts=[{
                "type": "cwd_result",
                "action": "get",
                "directory": current,
            }],
        )

    # SET cwd
    expanded = os.path.expanduser(str(raw_path))
    # Make absolute (relative → resolved against current cwd).
    if not os.path.isabs(expanded):
        expanded = os.path.join(os.getcwd(), expanded)
    resolved = str(Path(expanded).resolve())

    if not os.path.exists(resolved):
        raise ToolError("Directory does not exist: %s" % resolved, kind="not_found")
    if not os.path.isdir(resolved):
        raise ToolError("Path is not a directory: %s" % resolved, kind="not_found")

    try:
        os.chdir(resolved)
    except OSError as exc:
        raise ToolError("Cannot chdir to %s: %s" % (resolved, exc), kind="error")

    return envelope.ok(
        "cwd: changed to %s" % resolved,
        artifacts=[{
            "type": "cwd_result",
            "action": "set",
            "directory": resolved,
        }],
    )
