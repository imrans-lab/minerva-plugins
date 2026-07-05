"""Entrypoint for `python -m pcb_worker`.

Wires stdin.buffer / stdout.buffer into the dispatcher loop.
All logging goes to stderr only — stdout is exclusively framed JSON.
(Same entrypoint shape as the CAD worker; the two workers differ only in
their cold-start payload and method set.)
"""

import logging
import sys

# Stderr-only logging — stdout is framed protocol bytes.
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="[pcb_worker] %(levelname)s %(message)s",
)

# Ensure stdout is in raw binary mode with no extra buffering layer.
# write_frame always flushes after each frame, so disable line-buffering.
try:
    sys.stdout.reconfigure(line_buffering=False)
except AttributeError:
    pass

from .dispatcher import run  # noqa: E402

run(sys.stdin.buffer, sys.stdout.buffer)
