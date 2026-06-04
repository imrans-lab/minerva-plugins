"""P3.3 — cross-platform probe management + X11 visual-capture gating.

prepare/remove-probe install/uninstall the GDScript editor probe into a Godot
project (pure file ops, cross-platform). Visual (X11) capture is feature-gated
to Linux + DISPLAY; live editor-launch is the Option C HITL (not_implemented).
"""

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from codetools_worker import envelope
from codetools_worker import sightline_probe


def _make_godot_project() -> str:
    d = tempfile.mkdtemp(prefix="ct_p33_proj_")
    Path(d, "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="probe_test"\n',
        encoding="utf-8",
    )
    return d


class PrepareRemoveTest(unittest.TestCase):
    def setUp(self):
        self.proj = _make_godot_project()

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def _art(self, env):
        envelope.validate(env)
        return env["artifacts"][0]

    def test_prepare_installs_probe(self):
        env = sightline_probe.inspect({"op": "prepare", "project_path": self.proj})
        art = self._art(env)
        self.assertEqual(art["type"], "probe_prepare")
        # Probe addon copied into the project.
        self.assertTrue(Path(self.proj, "addons", "codetools_probe", "plugin.cfg").is_file())
        self.assertTrue(art["installed_files"])

    def test_prepare_then_remove(self):
        sightline_probe.inspect({"op": "prepare", "project_path": self.proj})
        env = sightline_probe.inspect({"op": "remove-probe", "project_path": self.proj})
        art = self._art(env)
        self.assertEqual(art["type"], "probe_remove")
        self.assertTrue(art["removed"])
        self.assertFalse(Path(self.proj, "addons", "codetools_probe").exists())

    def test_prepare_on_non_godot_dir_errors_cleanly(self):
        d = tempfile.mkdtemp(prefix="ct_p33_notgodot_")
        try:
            env = sightline_probe.inspect({"op": "prepare", "project_path": d})
            envelope.validate(env)
            self.assertEqual(env["status"], "error")
            self.assertEqual(env["error"]["kind"], "invalid_args")
        finally:
            shutil.rmtree(d, ignore_errors=True)


class GatingTest(unittest.TestCase):
    def test_visual_capture_gated_without_display(self):
        saved = os.environ.pop("DISPLAY", None)
        try:
            env = sightline_probe.inspect({"op": "capture-visual"})
            envelope.validate(env)
            self.assertEqual(env["status"], "error")
            self.assertEqual(env["error"]["kind"], "capability_unavailable")
        finally:
            if saved is not None:
                os.environ["DISPLAY"] = saved

    def test_live_launch_is_not_implemented(self):
        env = sightline_probe.inspect({"op": "launch-editor"})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "not_implemented")


if __name__ == "__main__":
    unittest.main()
