"""codetools_worker — the Python worker behind the Code Tools plugin.

P1.1 substrate: a stdio length-prefixed MCP bridge loop exposing a single
`ping` health method. Later phases register the files / code-visualizer /
code-probe subsystems against the same dispatcher + result envelope.
"""

# Single source of truth for the worker version (reported in worker.ready and
# in the ping artifact). Bump in lockstep with manifest.json / serverVersion.
WORKER_VERSION = "0.2.0"
