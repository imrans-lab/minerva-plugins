"""Bash command policy enforcement for the Code Tools worker (P2.1).

Policy is loaded from <plugin_data_dir>/policy.json and is FROZEN after load.
This prevents the LLM from modifying policy during a session (the file is read
once at first use, never again).

FAIL-SAFE: if the file is missing, unreadable, or malformed JSON, the safe
default deny-set is applied (never run unguarded). This matches the spirit of
Policy.gd's baseline deny patterns.

policy.json schema:
    {
        "bash": {
            "deny": ["<regex>", ...]
        }
    }

The baseline deny patterns below are always enforced, regardless of the file:
  - Any command touching the policy file itself (self-protection).
  - rm -rf with / or ~ targets (catastrophic-loss guard).
  - Fork bombs.
  - /dev/sda and raw block-device writes.

P4 DRY-convergence candidate: this policy loader mirrors Policy.gd; a future
shared config package could unify them.
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Baseline patterns — ALWAYS enforced, cannot be overridden by policy.json.
# These protect the policy mechanism itself and guard against catastrophic ops.
# ---------------------------------------------------------------------------

_BASELINE_DENY: list[tuple[str, str]] = [
    # Protect the policy file itself from LLM modification.
    (r"\.codetools/policy", "Protected path: .codetools/policy"),
    # Catastrophic rm -rf guards.
    (r"\brm\b.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+/\s*$", "Denied: rm -rf /"),
    (r"\brm\b.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+~\s*$", "Denied: rm -rf ~"),
    (r"\brm\b.*-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+~/?\s*$", "Denied: rm -rf ~/"),
    # Fork bomb.
    (r":\(\)\s*\{", "Denied: fork bomb pattern"),
    # Raw block-device writes.
    (r">\s*/dev/sd[a-z]", "Denied: raw block device write"),
    (r">\s*/dev/nvme", "Denied: raw block device write"),
]

_BASELINE_COMPILED: list[tuple[re.Pattern, str]] = [
    (re.compile(pat), msg) for pat, msg in _BASELINE_DENY
]


class Policy:
    """Immutable bash command policy, loaded once from disk.

    Attributes:
        loaded_from: Path the policy was loaded from (None if not found).
        used_defaults: True if file was missing / unparseable (fail-safe mode).
    """

    def __init__(self) -> None:
        self._deny_patterns: list[tuple[re.Pattern, str]] = []
        self.loaded_from: str | None = None
        self.used_defaults: bool = False

    # -------------------------------------------------------------------------
    # Loading
    # -------------------------------------------------------------------------

    @classmethod
    def load(cls, data_dir: str | Path | None = None) -> "Policy":
        """Load policy from `data_dir/policy.json`.

        Falls back to fail-safe defaults (empty user-deny list + baseline
        patterns) if the file is missing, unreadable, or malformed.

        Args:
            data_dir: Plugin data directory. None → look in ~/.codetools/.
        """
        pol = cls()
        if data_dir is None:
            data_dir = Path.home() / ".codetools"
        else:
            data_dir = Path(data_dir)

        policy_file = data_dir / "policy.json"

        if not policy_file.exists():
            log.info("policy.json not found at %s — applying safe defaults", policy_file)
            pol.used_defaults = True
            return pol

        try:
            text = policy_file.read_text(encoding="utf-8")
        except OSError as exc:
            log.warning("policy.json unreadable (%s) — applying safe defaults", exc)
            pol.used_defaults = True
            return pol

        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            log.warning("policy.json malformed JSON (%s) — applying safe defaults", exc)
            pol.used_defaults = True
            return pol

        if not isinstance(data, dict):
            log.warning("policy.json root must be object — applying safe defaults")
            pol.used_defaults = True
            return pol

        bash_cfg = data.get("bash", {})
        if not isinstance(bash_cfg, dict):
            log.warning("policy.json bash section must be object — applying safe defaults")
            pol.used_defaults = True
            return pol

        deny_list = bash_cfg.get("deny", [])
        if not isinstance(deny_list, list):
            log.warning("policy.json bash.deny must be array — applying safe defaults")
            pol.used_defaults = True
            return pol

        for raw in deny_list:
            if not isinstance(raw, str):
                continue
            try:
                pol._deny_patterns.append((re.compile(raw), "Pattern matched: %s" % raw))
            except re.error as exc:
                log.warning("policy.json: invalid regex %r (%s) — skipped", raw, exc)

        pol.loaded_from = str(policy_file)
        return pol

    # -------------------------------------------------------------------------
    # Checking
    # -------------------------------------------------------------------------

    def check(self, command: str) -> str | None:
        """Check whether `command` is allowed.

        Returns:
            None        if allowed.
            error_msg   (non-empty str) if denied.
        """
        # Baseline patterns are checked first and cannot be suppressed.
        for rx, msg in _BASELINE_COMPILED:
            if rx.search(command):
                return "Command not allowed by policy. %s" % msg

        # User-configured deny patterns (from policy.json).
        for rx, msg in self._deny_patterns:
            if rx.search(command):
                return "Command not allowed by policy. %s" % msg

        return None


# ---------------------------------------------------------------------------
# Module-level singleton: loaded lazily on first use.
# ---------------------------------------------------------------------------

_policy: Policy | None = None
_policy_data_dir: str | None = None


def get_policy(data_dir: str | Path | None = None) -> Policy:
    """Return the singleton Policy, loading from `data_dir` on first call.

    The data_dir is pinned on first call; subsequent calls with a different
    data_dir are ignored (policy is frozen after load).
    """
    global _policy, _policy_data_dir
    if _policy is None:
        _policy = Policy.load(data_dir)
        _policy_data_dir = str(data_dir) if data_dir else None
    return _policy


def _reset_policy() -> None:
    """Reset the singleton — for testing only."""
    global _policy, _policy_data_dir
    _policy = None
    _policy_data_dir = None
