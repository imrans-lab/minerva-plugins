"""Tests for minerva_codetools_bash (P2.1 gate).

Tests policy enforcement, output cap, timeout, and fail-safe behaviour.
All tests route through router.route("bash", params) and validate the
returned envelope with envelope.validate().
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from codetools_worker import envelope, router
from codetools_worker.files import policy as policy_mod


class BashTest(unittest.TestCase):

    def setUp(self):
        # Reset singleton so each test starts with a clean policy state.
        policy_mod._reset_policy()

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def _bash(self, command, **kwargs):
        params = {"command": command}
        params.update(kwargs)
        env = router.route("bash", params)
        envelope.validate(env)
        return env

    def _art(self, env):
        self.assertEqual(env["status"], "ok", "expected ok but got: %r" % env)
        return env["artifacts"][0]

    # -------------------------------------------------------------------------
    # Artifact shape
    # -------------------------------------------------------------------------

    def test_artifact_type_is_bash_result(self):
        env = self._bash("echo hello")
        self.assertEqual(env["artifacts"][0]["type"], "bash_result")

    def test_artifact_has_required_fields(self):
        art = self._art(self._bash("echo hello"))
        for f in ("type", "command", "stdout", "exit_code", "timed_out"):
            self.assertIn(f, art, "missing field: %s" % f)

    # -------------------------------------------------------------------------
    # Basic execution
    # -------------------------------------------------------------------------

    def test_echo_exits_zero(self):
        art = self._art(self._bash("echo hello"))
        self.assertEqual(art["exit_code"], 0)
        self.assertFalse(art["timed_out"])
        self.assertIn("hello", art["stdout"])

    def test_nonzero_exit_is_still_ok_envelope(self):
        # A command that exits non-zero should still return ok envelope
        # (the call succeeded, the program just exited non-zero).
        env = self._bash("exit 42")
        envelope.validate(env)
        self.assertEqual(env["status"], "ok")
        self.assertEqual(env["artifacts"][0]["exit_code"], 42)

    def test_merged_stderr(self):
        art = self._art(self._bash("echo stderr-text >&2"))
        self.assertIn("stderr-text", art["stdout"])

    # -------------------------------------------------------------------------
    # Output cap
    # -------------------------------------------------------------------------

    def test_output_is_capped(self):
        # Generate > 30KB of output
        env = self._bash("python3 -c \"print('x' * 40000)\"")
        envelope.validate(env)
        if env["status"] == "ok":
            art = env["artifacts"][0]
            self.assertLessEqual(len(art["stdout"]), 35000,
                                 "output should be capped near 30KB")
        # Even if the command itself failed (no python3), the envelope must be valid.

    # -------------------------------------------------------------------------
    # Timeout
    # -------------------------------------------------------------------------

    def test_timeout_kills_long_running_command(self):
        env = self._bash("sleep 10", timeout=1)
        envelope.validate(env)
        # Either ok with timed_out=True, or error envelope — both are valid.
        if env["status"] == "ok":
            self.assertTrue(env["artifacts"][0]["timed_out"],
                            "should be timed_out=True for sleep 10 with 1s timeout")

    # -------------------------------------------------------------------------
    # Policy — deny patterns
    # -------------------------------------------------------------------------

    def test_baseline_policy_denies_rm_rf_root(self):
        policy_mod._reset_policy()
        env = router.route("bash", {"command": "rm -rf /"})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "policy_denied")

    def test_baseline_policy_denies_rm_rf_home(self):
        policy_mod._reset_policy()
        env = router.route("bash", {"command": "rm -rf ~"})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")

    def test_baseline_policy_denies_policy_file_access(self):
        policy_mod._reset_policy()
        env = router.route("bash", {"command": "cat ~/.codetools/policy.json"})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")

    def test_user_policy_deny_pattern_blocks_command(self):
        """A policy.json with a custom deny pattern should block matching commands."""
        policy_mod._reset_policy()
        tmpdir = tempfile.mkdtemp(prefix="ct_policy_")
        try:
            policy_json = {
                "bash": {
                    "deny": [r"rm\s+-rf\s+/tmp/sensitive"]
                }
            }
            policy_file = Path(tmpdir) / "policy.json"
            policy_file.write_text(json.dumps(policy_json), encoding="utf-8")

            # Load policy from our test dir.
            pol = policy_mod.Policy.load(tmpdir)
            policy_mod._policy = pol  # inject into singleton

            env = router.route("bash", {"command": "rm -rf /tmp/sensitive"})
            envelope.validate(env)
            self.assertEqual(env["status"], "error")
            self.assertEqual(env["error"]["kind"], "policy_denied")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            policy_mod._reset_policy()

    # -------------------------------------------------------------------------
    # Fail-safe: missing / malformed policy.json
    # -------------------------------------------------------------------------

    def test_fail_safe_missing_policy_applies_baseline(self):
        """When policy.json is absent, baseline deny-set is still active."""
        policy_mod._reset_policy()
        tmpdir = tempfile.mkdtemp(prefix="ct_no_policy_")
        try:
            # No policy.json in this dir.
            pol = policy_mod.Policy.load(tmpdir)
            self.assertTrue(pol.used_defaults, "should use defaults when file missing")
            # Baseline still active.
            denial = pol.check("rm -rf /")
            self.assertIsNotNone(denial, "rm -rf / must be denied even with no policy.json")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def test_fail_safe_malformed_json_applies_baseline(self):
        """When policy.json contains invalid JSON, baseline is still active."""
        policy_mod._reset_policy()
        tmpdir = tempfile.mkdtemp(prefix="ct_bad_policy_")
        try:
            policy_file = Path(tmpdir) / "policy.json"
            policy_file.write_text("not valid json {{{{", encoding="utf-8")

            pol = policy_mod.Policy.load(tmpdir)
            self.assertTrue(pol.used_defaults)
            denial = pol.check("rm -rf /")
            self.assertIsNotNone(denial, "baseline must deny even with bad policy.json")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def test_fail_safe_allows_safe_commands(self):
        """Non-denied commands work even when policy.json is missing."""
        policy_mod._reset_policy()
        tmpdir = tempfile.mkdtemp(prefix="ct_safe_policy_")
        try:
            pol = policy_mod.Policy.load(tmpdir)
            policy_mod._policy = pol
            env = router.route("bash", {"command": "echo hello"})
            envelope.validate(env)
            self.assertEqual(env["status"], "ok")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            policy_mod._reset_policy()

    # -------------------------------------------------------------------------
    # Missing required param
    # -------------------------------------------------------------------------

    def test_missing_command_returns_error(self):
        env = router.route("bash", {})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")


if __name__ == "__main__":
    unittest.main()
