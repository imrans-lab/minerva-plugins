"""minerva_codetools_bash handler (P2.1).

Headless shell command execution with policy enforcement.

Policy is loaded from the plugin data directory (CODETOOLS_DATA_DIR env var,
falling back to ~/.codetools/). FAIL-SAFE: if policy.json is missing or
malformed, the safe default deny-set is applied.

The CODETOOLS_DATA_DIR env var is set by the Go shim when it launches the
worker; it resolves to the plugin's data directory which may contain a
user-placed policy.json.

Output cap: ~30 KB (merged stdout+stderr). Timeout: 120 s default, 600 s max.
"""

from __future__ import annotations

import os

from .. import envelope
from ..errors import ToolError
from .policy import get_policy
from .runner import DEFAULT_TIMEOUT_S, run_command


# Optional host-terminal exec hook (P2.2). When installed — by the Go shim's
# bidirectional host-capability client once the host.terminal.exec capability is
# granted (tracked as a P2.2 follow-up) — a policy-approved command routes
# through Minerva's visible UI terminal so the user sees it run. The hook returns
# a result dict {stdout, exit_code, timed_out, routed_through} or None to fall
# back to the local subprocess. Signature:
#     fn(command: str, cwd: str | None, timeout_s: int) -> dict | None
# Until the follow-up lands the hook stays None and bash runs locally — the
# default headless behaviour from P2.1.
_host_exec_hook = None


def set_host_exec_hook(fn) -> None:
    """Install (fn) or clear (None) the host-terminal exec hook."""
    global _host_exec_hook
    _host_exec_hook = fn


def handle_bash(params: dict) -> dict:
    """Route entry point for the 'bash' worker method."""
    command = params.get("command") or params.get("cmd") or ""
    if not command:
        raise ToolError("'command' is required", kind="parse")

    timeout_s = int(params.get("timeout", DEFAULT_TIMEOUT_S))
    cwd = params.get("cwd") or params.get("working_dir") or None

    # Resolve the plugin data dir for policy loading.
    data_dir = os.environ.get("CODETOOLS_DATA_DIR") or None

    policy = get_policy(data_dir)

    # Policy check — FAIL SAFE: deny runs unguarded.
    denial = policy.check(command)
    if denial:
        return envelope.error(
            denial,
            kind="policy_denied",
            message=denial,
        )

    # Prefer the host's visible UI terminal when a hook is installed, so the user
    # sees the (already policy-approved) command run. A None return falls back to
    # the local subprocess below.
    if _host_exec_hook is not None:
        host_res = _host_exec_hook(command, cwd, timeout_s)
        if host_res is not None:
            return envelope.ok(
                "bash: exit %s (host terminal)" % host_res.get("exit_code", "?"),
                artifacts=[{
                    "type": "bash_result",
                    "command": command,
                    "stdout": host_res.get("stdout", ""),
                    "exit_code": host_res.get("exit_code", 0),
                    "timed_out": host_res.get("timed_out", False),
                    "routed_through": host_res.get("routed_through", "terminal"),
                }],
            )

    result = run_command(command, cwd=cwd, timeout_s=timeout_s)

    if result.error and result.exit_code == -1 and not result.timed_out:
        # Start failure (OS error, not a policy issue).
        raise ToolError(result.error, kind="exec")

    summary = "bash: exit %d" % result.exit_code
    if result.timed_out:
        summary = "bash: timed out after %ds" % timeout_s

    return envelope.ok(
        summary,
        artifacts=[{
            "type": "bash_result",
            "command": command,
            "stdout": result.stdout,
            "exit_code": result.exit_code,
            "timed_out": result.timed_out,
            "routed_through": "local",
        }],
    )
