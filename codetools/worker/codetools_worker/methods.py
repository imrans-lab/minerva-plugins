"""Tool method dispatch for the codetools worker.

P1.1 exposes only `ping`. Later phases register files / code-visualizer /
code-probe methods here, each returning the unified result envelope (P1.2).
"""

from __future__ import annotations

import platform
import sys


class MethodError(Exception):
    """A worker-side error with a structured `kind` (bridge §7)."""

    def __init__(self, kind: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind


def handle(method: str, params: dict):
    """Dispatch a worker method to its handler. Raises MethodError on unknown."""
    if method == "ping":
        return _ping(params)
    raise MethodError("internal", f"unknown method: {method}")


def _ping(params: dict) -> dict:
    """Health check — echoes input and reports the live worker/runtime."""
    return {
        "pong": True,
        "echo": params.get("echo"),
        "worker": "codetools",
        "worker_version": "0.1.0",
        "python": sys.version.split()[0],
        "platform": platform.platform(),
    }
