"""Unified result envelope for Code Tools (DCR 019e7b6609, P1.2).

EVERY routed tool returns this one shape, so the agent reads a single contract
across all subsystems (files / code-visualizer / code-probe):

    {
      "status":           "ok" | "error",
      "summary":          str,        # one-line, agent-readable
      "artifacts":        [ ... ],    # structured outputs — EACH a dict with a
                                      #   required string "type" discriminator the
                                      #   agent dispatches on (query results, produced
                                      #   files, diagnostics). type is mandatory.
      "evidence_handles": [ ... ],    # opaque handles to fetch supporting evidence
                                      #   later (item schema lands with code-probe, P3).
      "follow_ups":       [ ... ],    # suggested next tool calls / actions. Each entry
                                      #   follows the follow_up() convention (P4.3):
                                      #   {"tool": str, "reason": str, "params": dict}.
      "error":            {"kind": str, "message": str}   # present iff status == "error"
    }

Transport note: the envelope is the worker RESULT of a successful call (worker
ok=true). Lifecycle failures (crash / framing / unknown-method) use the bridge's
ok=false path and never produce an envelope. A *handler-level* failure is still
a successful call that returns an envelope with status="error".
"""

from __future__ import annotations

STATUS_OK = "ok"
STATUS_ERROR = "error"

# Fields every envelope must carry (error is conditional).
REQUIRED_FIELDS = ("status", "summary", "artifacts", "evidence_handles", "follow_ups")
_LIST_FIELDS = ("artifacts", "evidence_handles", "follow_ups")


def make_envelope(status, summary, *, artifacts=None, evidence_handles=None,
                  follow_ups=None, error=None):
    """Build an envelope. Prefer the ok()/error() helpers for call sites."""
    if status not in (STATUS_OK, STATUS_ERROR):
        raise ValueError("status must be 'ok' or 'error', got %r" % status)
    env = {
        "status": status,
        "summary": str(summary),
        "artifacts": list(artifacts or []),
        "evidence_handles": list(evidence_handles or []),
        "follow_ups": list(follow_ups or []),
    }
    if error is not None:
        env["error"] = error
    return env


def ok(summary, *, artifacts=None, evidence_handles=None, follow_ups=None):
    """A successful result envelope."""
    return make_envelope(STATUS_OK, summary, artifacts=artifacts,
                         evidence_handles=evidence_handles, follow_ups=follow_ups)


def error(summary, *, kind="error", message=None, artifacts=None,
          evidence_handles=None, follow_ups=None):
    """A semantic-failure result envelope (the call succeeded, the work didn't).

    `summary` is the one-line agent-readable headline; `message` is the (often
    longer) error detail — defaults to summary when not given.
    """
    return make_envelope(STATUS_ERROR, summary,
                         artifacts=artifacts, evidence_handles=evidence_handles,
                         follow_ups=follow_ups,
                         error={"kind": kind,
                                "message": str(message if message is not None else summary)})


def follow_up(tool, reason, params=None):
    """A single `follow_ups` entry: a suggested next tool call for the agent.

    Convention (DCR 019e7b6609, P4.3) — every follow_up across all subsystems
    (files / code-visualizer / code-probe) shares one shape so an agent can
    dispatch on it without per-tool special-casing:

        {"tool": <mcp tool name>, "reason": <agent-readable why>, "params": {...}}

    `tool` is the fully-qualified MCP tool name the agent should consider next
    (e.g. "minerva_codetools_stale_check"); `params` are suggested arguments.
    """
    return {"tool": str(tool), "reason": str(reason), "params": dict(params or {})}


def validate(env):
    """Return env if it is a well-formed envelope; raise ValueError otherwise.

    The router calls this on every handler result so a malformed subsystem
    return is caught at the boundary, not deep in the agent.
    """
    if not isinstance(env, dict):
        raise ValueError("envelope must be a dict, got %s" % type(env).__name__)
    for field in REQUIRED_FIELDS:
        if field not in env:
            raise ValueError("envelope missing required field %r" % field)
    if env["status"] not in (STATUS_OK, STATUS_ERROR):
        raise ValueError("envelope status must be 'ok' or 'error', got %r" % env["status"])
    if not isinstance(env["summary"], str):
        raise ValueError("envelope summary must be a str")
    for field in _LIST_FIELDS:
        if not isinstance(env[field], list):
            raise ValueError("envelope field %r must be a list" % field)
    # Every artifact is a self-describing dict with a required string "type" so
    # the agent can dispatch on it (the answer vs a produced file vs diagnostics).
    for i, art in enumerate(env["artifacts"]):
        if not isinstance(art, dict):
            raise ValueError("artifacts[%d] must be a dict" % i)
        if not isinstance(art.get("type"), str) or not art["type"]:
            raise ValueError("artifacts[%d] must have a non-empty string 'type'" % i)
    # Every follow_up follows the follow_up() convention so the agent reads one
    # shape: a dict with a non-empty 'tool' name, a string 'reason', and params.
    for i, fu in enumerate(env["follow_ups"]):
        if not isinstance(fu, dict):
            raise ValueError("follow_ups[%d] must be a dict" % i)
        if not isinstance(fu.get("tool"), str) or not fu["tool"]:
            raise ValueError("follow_ups[%d] must have a non-empty string 'tool'" % i)
        if not isinstance(fu.get("reason"), str):
            raise ValueError("follow_ups[%d] must have a string 'reason'" % i)
    if env["status"] == STATUS_ERROR:
        err = env.get("error")
        if not isinstance(err, dict):
            raise ValueError("error envelope must carry an 'error' object")
        if not isinstance(err.get("kind"), str) or not isinstance(err.get("message"), str):
            raise ValueError("envelope error must have string 'kind' and 'message'")
    elif "error" in env:
        raise ValueError("ok envelope must not carry an 'error' object")
    return env
