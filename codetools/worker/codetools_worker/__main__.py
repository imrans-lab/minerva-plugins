"""Entrypoint: `python -m codetools_worker`.

Logging goes to stderr (stdout is reserved for length-prefixed frames). The
Go shim spawns this module and bridges stdio between Minerva and the worker.
"""

from __future__ import annotations

import logging
import sys

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="[codetools_worker] %(levelname)s %(message)s",
)

from .dispatcher import run

run(sys.stdin.buffer, sys.stdout.buffer)
