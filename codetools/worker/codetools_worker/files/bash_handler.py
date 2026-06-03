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
        }],
    )
