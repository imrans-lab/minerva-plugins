"""Tool router for the Code Tools worker (DCR 019e7b6609, P1.2).

Maps a method name to its handler and GUARANTEES every routed call returns a
validated unified envelope (see envelope.py):

  - handler returns an envelope            -> validated and returned as-is
  - handler raises ToolError               -> converted to an error envelope
                                              (status='error'); the call succeeds
  - method is unknown                      -> MethodError (transport ok=false)

Later phases register their subsystem handlers in ROUTES (files /
code-visualizer / code-probe). They add entries here and return envelopes via
the envelope helpers — they do NOT invent their own result shape. This is the
single dispatch + result contract the whole plugin shares.
"""

from __future__ import annotations

from . import envelope, methods
from .errors import MethodError, ToolError

# method name -> handler(params: dict) -> envelope dict
ROUTES = {
    "ping": methods.ping,
}


def route(method, params):
    """Dispatch `method` and return a validated unified envelope.

    Raises MethodError for an unknown method (a protocol fault, surfaced by the
    dispatcher as ok=false). Handler ToolError becomes an error envelope.
    """
    handler = ROUTES.get(method)
    if handler is None:
        raise MethodError("internal", "unknown method: %s" % method)
    try:
        env = handler(params or {})
    except ToolError as exc:
        return envelope.error(str(exc), kind=exc.kind)
    return envelope.validate(env)
