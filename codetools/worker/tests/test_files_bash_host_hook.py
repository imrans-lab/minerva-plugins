"""Tests for the host-terminal exec hook seam in bash_handler (P2.2).

The hook lets a policy-approved command route through the host's visible UI
terminal (wired by the Go host-capability client in a follow-up). These tests
cover the seam itself: when installed it is used; a None return falls back to
local; the default (no hook) runs locally; denied commands never reach the hook.
"""

import unittest

from codetools_worker.envelope import validate
from codetools_worker.files import bash_handler
from codetools_worker.files.policy import _reset_policy


class HostExecHookTest(unittest.TestCase):
    def setUp(self):
        _reset_policy()
        bash_handler.set_host_exec_hook(None)
        self.calls = []

    def tearDown(self):
        bash_handler.set_host_exec_hook(None)
        _reset_policy()

    def _artifact(self, env):
        validate(env)
        return env["artifacts"][0]

    def test_no_hook_runs_local(self):
        env = bash_handler.handle_bash({"command": "echo local_path"})
        art = self._artifact(env)
        self.assertEqual(art["routed_through"], "local")
        self.assertIn("local_path", art["stdout"])

    def test_hook_used_when_installed(self):
        def fake(command, cwd, timeout_s):
            self.calls.append((command, cwd, timeout_s))
            return {
                "stdout": "from host terminal",
                "exit_code": 0,
                "timed_out": False,
                "routed_through": "terminal",
            }

        bash_handler.set_host_exec_hook(fake)
        env = bash_handler.handle_bash({"command": "ls -la"})
        art = self._artifact(env)
        self.assertEqual(art["routed_through"], "terminal")
        self.assertEqual(art["stdout"], "from host terminal")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][0], "ls -la")

    def test_hook_none_return_falls_back_local(self):
        def fake(command, cwd, timeout_s):
            self.calls.append(command)
            return None  # decline → fall back

        bash_handler.set_host_exec_hook(fake)
        env = bash_handler.handle_bash({"command": "echo fellback"})
        art = self._artifact(env)
        self.assertEqual(art["routed_through"], "local")
        self.assertIn("fellback", art["stdout"])
        self.assertEqual(len(self.calls), 1)  # hook was consulted

    def test_denied_command_never_reaches_hook(self):
        def fake(command, cwd, timeout_s):
            self.calls.append(command)
            return {"stdout": "", "exit_code": 0, "timed_out": False}

        bash_handler.set_host_exec_hook(fake)
        env = bash_handler.handle_bash({"command": "rm -rf /"})
        validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(len(self.calls), 0)  # policy blocked before the hook


if __name__ == "__main__":
    unittest.main()
