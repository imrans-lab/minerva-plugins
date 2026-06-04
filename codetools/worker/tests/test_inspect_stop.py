"""Tests for op=stop + editor-aware remove-probe (bug 019e93d8f1).

Process detection + SIGTERM→SIGKILL escalation are exercised with injected
process lists / killer / liveness so no real processes are spawned or signalled.
"""

import shutil
import signal
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from codetools_worker import envelope
from codetools_worker import sightline_probe

sightline_probe._ensure_sightline_imports()
plugin = sightline_probe._godot_plugin


def _godot_editor_row(pid, project_path, editor=True):
    cmd = ["godot", "--path", str(project_path)]
    if editor:
        cmd.append("--editor")
    return {
        "pid": pid, "process_name": "godot", "executable": "/usr/local/bin/godot",
        "cmdline": cmd, "cwd": str(project_path), "project_path": str(project_path),
        "project": "x", "start_time": None,
    }


class DetectionTest(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="ct_detect_")
        self.other = tempfile.mkdtemp(prefix="ct_detect_other_")

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)
        shutil.rmtree(self.other, ignore_errors=True)

    def test_matches_editor_for_project(self):
        rows = [_godot_editor_row(111, self.proj)]
        found = plugin.running_godot_for_project(self.proj, processes=rows)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["pid"], 111)
        self.assertTrue(found[0]["is_editor"])

    def test_ignores_other_projects(self):
        rows = [_godot_editor_row(111, self.other)]
        found = plugin.running_godot_for_project(self.proj, processes=rows)
        self.assertEqual(found, [])

    def test_ignores_non_godot(self):
        rows = [{
            "pid": 9, "process_name": "python", "executable": "/usr/bin/python",
            "cmdline": ["python", "--path", str(self.proj)],
            "project_path": str(self.proj), "project": None, "cwd": None, "start_time": None,
        }]
        found = plugin.running_godot_for_project(self.proj, processes=rows)
        self.assertEqual(found, [])

    def test_editor_only_excludes_runtime(self):
        rows = [_godot_editor_row(222, self.proj, editor=False)]  # running game, not editor
        # editor_only=True excludes it; editor_only=False (default) includes it.
        only = plugin.running_godot_for_project(self.proj, processes=rows, editor_only=True)
        self.assertEqual(only, [])
        anykind = plugin.running_godot_for_project(self.proj, processes=rows, editor_only=False)
        self.assertEqual(len(anykind), 1)
        self.assertFalse(anykind[0]["is_editor"])


class StopEscalationTest(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="ct_stop_")

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def test_graceful_sigterm(self):
        rows = [_godot_editor_row(111, self.proj)]
        sent = []
        result = plugin.stop_godot_for_project(
            self.proj, processes=rows,
            killer=lambda pid, sig: sent.append((pid, sig)),
            is_alive=lambda pid: False,  # dies immediately after SIGTERM
            sleep=lambda _s: None,
        )
        self.assertEqual(result["stopped"], [111])
        self.assertEqual(result["sigkilled"], [])
        self.assertEqual(sent, [(111, signal.SIGTERM)])

    def test_escalates_to_sigkill(self):
        rows = [_godot_editor_row(111, self.proj)]
        sent = []
        result = plugin.stop_godot_for_project(
            self.proj, processes=rows,
            killer=lambda pid, sig: sent.append((pid, sig)),
            is_alive=lambda pid: True,  # never dies on SIGTERM
            sleep=lambda _s: None,
            grace_seconds=0.5, poll_interval=0.25,
        )
        self.assertEqual(result["stopped"], [111])
        self.assertEqual(result["sigkilled"], [111])
        self.assertIn((111, signal.SIGKILL), sent)

    def test_already_gone_counts_stopped(self):
        rows = [_godot_editor_row(111, self.proj)]

        def boom(pid, sig):
            raise ProcessLookupError()

        result = plugin.stop_godot_for_project(
            self.proj, processes=rows, killer=boom, is_alive=lambda pid: False, sleep=lambda _s: None
        )
        self.assertEqual(result["stopped"], [111])
        self.assertEqual(result["failed"], [])

    def test_no_matches_empty(self):
        result = plugin.stop_godot_for_project(self.proj, processes=[], sleep=lambda _s: None)
        self.assertEqual(result["stopped"], [])
        self.assertEqual(result["matched"], [])


class AdapterStopTest(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="ct_adapter_stop_")
        Path(self.proj, "project.godot").write_text("config_version=5\n", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def test_op_stop_envelope(self):
        fake = {"stopped": [5], "sigkilled": [], "failed": [], "matched": [5]}
        with mock.patch.object(plugin, "stop_godot_for_project", return_value=fake):
            env = sightline_probe.inspect({"op": "stop", "project_path": self.proj})
        envelope.validate(env)
        self.assertEqual(env["status"], "ok")
        self.assertEqual(env["artifacts"][0]["type"], "godot_stop")
        self.assertEqual(env["artifacts"][0]["stopped"], [5])


class EditorAwareRemoveTest(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="ct_rmaware_")
        Path(self.proj, "project.godot").write_text(
            'config_version=5\n\n[application]\n\nconfig/name="x"\n', encoding="utf-8"
        )
        # Install the probe so there's something to remove.
        sightline_probe.inspect({"op": "prepare", "project_path": self.proj})

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def _addon_exists(self):
        return Path(self.proj, "addons", "sightline_probe").exists()

    def test_editor_running_no_stop_refuses(self):
        with mock.patch.object(plugin, "running_godot_for_project",
                               return_value=[{"pid": 777, "is_editor": True}]):
            env = sightline_probe.inspect({"op": "remove-probe", "project_path": self.proj})
        envelope.validate(env)
        art = env["artifacts"][0]
        self.assertFalse(art["removed"])
        self.assertEqual(art["reason"], "editor_running")
        self.assertEqual(art["editor_pids"], [777])
        self.assertTrue(env["follow_ups"])
        self.assertTrue(env["follow_ups"][0]["params"]["stop_editor"])
        # Destructive edit was refused — addon still present.
        self.assertTrue(self._addon_exists())

    def test_editor_running_with_stop_removes(self):
        stop_called = {}

        def fake_stop(project_path, **kw):
            stop_called["yes"] = True
            return {"stopped": [777], "sigkilled": [], "failed": [], "matched": [777]}

        with mock.patch.object(plugin, "running_godot_for_project",
                               return_value=[{"pid": 777, "is_editor": True}]), \
             mock.patch.object(plugin, "stop_godot_for_project", side_effect=fake_stop):
            env = sightline_probe.inspect(
                {"op": "remove-probe", "project_path": self.proj, "stop_editor": True}
            )
        envelope.validate(env)
        art = env["artifacts"][0]
        self.assertTrue(stop_called.get("yes"))
        self.assertTrue(art["removed"])
        self.assertIn("stopped_editor", art)
        self.assertFalse(self._addon_exists())

    def test_no_editor_normal_removal(self):
        with mock.patch.object(plugin, "running_godot_for_project", return_value=[]):
            env = sightline_probe.inspect({"op": "remove-probe", "project_path": self.proj})
        envelope.validate(env)
        art = env["artifacts"][0]
        self.assertTrue(art["removed"])
        self.assertIn("next_step", art)
        self.assertFalse(self._addon_exists())


if __name__ == "__main__":
    unittest.main()
