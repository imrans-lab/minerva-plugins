"""Subprocess runner for the Code Tools worker (P2.1).

Provides `run_command(cmd, ...)` — a headless subprocess executor with:
  - configurable timeout (default 120s, hard cap 600s)
  - merged stdout+stderr output
  - ~30 KB output cap with truncation notice
  - clear error surface on timeout / crash

P4 DRY-convergence candidate: pull into a shared runtime utils package when
the code-probe or another subsystem needs subprocess execution.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass

# Timeout limits (seconds).
DEFAULT_TIMEOUT_S: int = 120
MAX_TIMEOUT_S: int = 600

# Output cap: ~30 KB (matches BashTool.gd's 30 000 char cap).
MAX_OUTPUT_BYTES: int = 30_000
_TRUNCATION_NOTICE = "\n... [output truncated at %d bytes]" % MAX_OUTPUT_BYTES


@dataclass
class RunResult:
    """Outcome of a headless subprocess call."""
    stdout: str          # merged stdout+stderr (stderr redirected to stdout)
    exit_code: int       # process exit code (-1 if timed out or failed to start)
    timed_out: bool      # True iff the process was killed for exceeding timeout
    error: str | None    # Start-failure message; None on normal exit/timeout


def run_command(
    cmd: str,
    *,
    cwd: str | None = None,
    timeout_s: int = DEFAULT_TIMEOUT_S,
    env: dict[str, str] | None = None,
) -> RunResult:
    """Execute `cmd` via the shell, capturing merged stdout+stderr.

    Args:
        cmd:       Shell command string to execute.
        cwd:       Working directory for the subprocess. None = inherit caller's.
        timeout_s: Execution timeout in seconds. Clamped to MAX_TIMEOUT_S.
        env:       Optional environment dict. None = inherit caller's env.

    Returns:
        RunResult with merged output, exit code, and timed_out flag.
    """
    timeout_s = min(timeout_s, MAX_TIMEOUT_S)
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,   # merge stderr into stdout
            timeout=timeout_s,
        )
        raw = result.stdout or b""
        truncated = len(raw) > MAX_OUTPUT_BYTES
        output = raw[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace")
        if truncated:
            output += _TRUNCATION_NOTICE
        return RunResult(
            stdout=output,
            exit_code=result.returncode,
            timed_out=False,
            error=None,
        )
    except subprocess.TimeoutExpired as exc:
        raw = (exc.stdout or b"")
        truncated = len(raw) > MAX_OUTPUT_BYTES
        output = raw[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace")
        if truncated:
            output += _TRUNCATION_NOTICE
        return RunResult(
            stdout=output,
            exit_code=-1,
            timed_out=True,
            error="Command timed out after %ds" % timeout_s,
        )
    except OSError as exc:
        return RunResult(
            stdout="",
            exit_code=-1,
            timed_out=False,
            error="Failed to start command: %s" % exc,
        )
