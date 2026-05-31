"""Worker error types (kept in their own module to avoid an import cycle
between router.py and methods.py)."""

from __future__ import annotations


class ToolError(Exception):
    """A handler-level failure that becomes an ERROR ENVELOPE (status='error').

    The call still succeeds at the transport level — the agent gets a normal
    envelope whose status is 'error'. Use this for expected, in-domain failures
    (bad input, target not found, validation failed).
    """

    def __init__(self, message, kind="error"):
        super().__init__(message)
        self.kind = kind


class MethodError(Exception):
    """An unknown method / protocol fault → transport-level worker error (ok=false).

    Reserved for faults that are NOT a tool result: an unrecognised tool name,
    a dispatch bug. The dispatcher surfaces these as the bridge's ok=false path.
    """

    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind
