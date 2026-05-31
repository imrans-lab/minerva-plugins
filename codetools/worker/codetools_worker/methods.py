"""Tool handlers for the Code Tools worker. Each returns a unified envelope.

P1.2 ships only `ping`. Later phases add files / code-visualizer / code-probe
handlers here and register them in router.ROUTES — every handler returns an
envelope via the envelope helpers, so the agent reads one result contract.

Raise errors.ToolError for an in-domain failure (becomes an error envelope);
let unexpected exceptions propagate (the dispatcher reports them as ok=false).
"""

from __future__ import annotations

import platform
import sys

from . import WORKER_VERSION, envelope


def ping(params):
    """Health check — round-trips through the worker and reports runtime info."""
    info = {
        "type": "worker_info",
        "pong": True,
        "echo": params.get("echo"),
        "worker": "codetools",
        "worker_version": WORKER_VERSION,
        "python": sys.version.split()[0],
        "platform": platform.platform(),
    }
    return envelope.ok(
        "codetools worker healthy (python %s)" % info["python"],
        artifacts=[info],
    )
