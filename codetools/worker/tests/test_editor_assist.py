"""Tests for run(mode=editor-assist) — the human-driven probe sink (019e93d8f1).

The pure probe→diagnostics normalizer is tested against the committed v3
fixture; the adapter wiring is tested with a mocked editor launch (no real
display / human).
"""

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from codetools_worker import envelope
from codetools_worker import godot_diagnostics as gd
from codetools_worker import sightline_probe

sightline_probe._ensure_sightline_imports()
plugin = sightline_probe._godot_plugin

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "probe" / "debugger_state.v3.json"


class ProbeNormalizerTest(unittest.TestCase):
    def test_v3_fixture_maps_rows(self):
        state = json.loads(FIXTURE.read_text(encoding="utf-8"))
        diags = gd.probe_state_to_diagnostics(state)
        self.assertEqual(len(diags), 2)
        sevs = sorted(d["severity"] for d in diags)
        self.assertEqual(sevs, ["script_error", "warning"])
        # Severity prefix is stripped from the scraped label text.
        script_err = next(d for d in diags if d["severity"] == "script_error")
        self.assertEqual(script_err["message"], "probe_fixture_marker")

    def test_location_extracted_when_present(self):
        state = {"debugger": {"rows": [
            {"severity": "warning", "text": "res://main.gd:42 - unused variable"},
        ]}}
        diags = gd.probe_state_to_diagnostics(state)
        self.assertEqual(diags[0]["file"], "res://main.gd")
        self.assertEqual(diags[0]["line"], 42)
        self.assertTrue(diags[0]["user_fixable"])

    def test_no_location_is_not_fixable(self):
        state = json.loads(FIXTURE.read_text(encoding="utf-8"))
        diags = gd.probe_state_to_diagnostics(state)
        self.assertTrue(all(d["file"] is None for d in diags))
        self.assertTrue(all(not d["user_fixable"] for d in diags))

    def test_record_from_probe_shape(self):
        state = json.loads(FIXTURE.read_text(encoding="utf-8"))
        rec = gd.diagnostics_record_from_probe(state, log_path="/x.log")
        self.assertEqual(rec["type"], "godot_diagnostics")
        self.assertEqual(rec["source"], "editor-probe")
        self.assertEqual(rec["counts"]["warning"], 1)
        self.assertEqual(rec["counts"]["script_error"], 1)

    def test_empty_state(self):
        self.assertEqual(gd.probe_state_to_diagnostics(None), [])
        self.assertEqual(gd.probe_state_to_diagnostics({}), [])


class AdapterEditorAssistTest(unittest.TestCase):
    """Adapter branches for the 019e987e1d fix. _probe_status / _probe_output_path
    / _launch_editor_session / _pid_alive are mocked so no real editor is spawned
    and the env's real DISPLAY is irrelevant (display check is patched)."""

    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="ct_editor_assist_")
        Path(self.proj, "project.godot").write_text(
            'config_version=5\n\n[application]\n\nconfig/name="x"\n', encoding="utf-8"
        )
        out = Path(self.proj, ".codetools", "godot_probe")
        out.mkdir(parents=True, exist_ok=True)
        self.state_path = out / "debugger_state.json"
        shutil.copyfile(FIXTURE, self.state_path)

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def _run(self):
        return sightline_probe.inspect(
            {"op": "run", "mode": "editor-assist", "project_path": self.proj})

    def test_captures_when_probe_already_fresh_NO_launch(self):
        # A human already opened the editor → fresh probe output present.
        status = {"loaded": True, "output_exists": True, "output_fresh": True}
        with mock.patch.object(plugin, "_probe_status", return_value=status), \
             mock.patch.object(plugin, "_probe_output_path", return_value=self.state_path), \
             mock.patch.object(plugin, "_launch_editor_session") as launch:
            env = self._run()
        envelope.validate(env)
        art = env["artifacts"][0]
        self.assertEqual(art["source"], "editor-probe")
        self.assertTrue(art["probe_loaded"])
        self.assertEqual(art["counts"]["script_error"], 1)
        launch.assert_not_called()  # captured without launching

    def test_no_display_returns_human_launch_guidance_NO_launch(self):
        status = {"loaded": False, "output_exists": False, "output_fresh": False}
        with mock.patch.object(plugin, "_probe_status", return_value=status), \
             mock.patch.object(sightline_probe, "_editor_display_available",
                               return_value=(False, "no DISPLAY")), \
             mock.patch.object(plugin, "_launch_editor_session") as launch:
            env = self._run()
        envelope.validate(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertFalse(art["probe_loaded"])
        self.assertTrue(art["needs_human_launch"])
        self.assertTrue(env["follow_ups"])
        launch.assert_not_called()  # no doomed launch

    def test_display_launch_then_probe_loads(self):
        status = {"loaded": False, "output_exists": False, "output_fresh": False}
        launch = {"pid": 4321, "log_path": "/tmp/ed.log", "probe_loaded": True}
        with mock.patch.object(plugin, "_probe_status", return_value=status), \
             mock.patch.object(sightline_probe, "_editor_display_available", return_value=(True, "")), \
             mock.patch.object(plugin, "_launch_editor_session", return_value=launch), \
             mock.patch.object(plugin, "_probe_output_path", return_value=self.state_path):
            env = self._run()
        envelope.validate(env)
        art = env["artifacts"][0]
        self.assertTrue(art["probe_loaded"])
        self.assertEqual(art["editor_pid"], 4321)

    def test_display_launch_then_editor_dies_surfaces_error(self):
        status = {"loaded": False, "output_exists": False, "output_fresh": False}
        launch = {"pid": 4321, "log_path": str(self.state_path), "probe_loaded": False}
        # Write a fake log with the display error so the tail surfaces it.
        Path(self.proj, "ed.log").write_text(
            "ERROR: X11 Display is not available\nERROR: Unable to create DisplayServer\n",
            encoding="utf-8")
        launch["log_path"] = str(Path(self.proj, "ed.log"))
        with mock.patch.object(plugin, "_probe_status", return_value=status), \
             mock.patch.object(sightline_probe, "_editor_display_available", return_value=(True, "")), \
             mock.patch.object(plugin, "_launch_editor_session", return_value=launch), \
             mock.patch.object(plugin, "_pid_alive", return_value=False):  # editor died
            env = self._run()
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "launch_failed")
        self.assertIn("X11 Display", env["error"]["message"])

    def test_display_launch_then_still_loading_followup(self):
        status = {"loaded": False, "output_exists": False, "output_fresh": False}
        launch = {"pid": 4321, "log_path": "/tmp/ed.log", "probe_loaded": False}
        self.state_path.unlink()  # probe hasn't written yet
        with mock.patch.object(plugin, "_probe_status", return_value=status), \
             mock.patch.object(sightline_probe, "_editor_display_available", return_value=(True, "")), \
             mock.patch.object(plugin, "_launch_editor_session", return_value=launch), \
             mock.patch.object(plugin, "_pid_alive", return_value=True):  # editor still alive
            env = self._run()
        envelope.validate(env)
        self.assertEqual(env["status"], "ok")
        self.assertFalse(env["artifacts"][0]["probe_loaded"])
        self.assertTrue(env["follow_ups"])

    def test_launch_runtime_error_is_clean(self):
        status = {"loaded": False, "output_exists": False, "output_fresh": False}
        with mock.patch.object(plugin, "_probe_status", return_value=status), \
             mock.patch.object(sightline_probe, "_editor_display_available", return_value=(True, "")), \
             mock.patch.object(plugin, "_launch_editor_session",
                               side_effect=RuntimeError("probe must be installed")):
            env = self._run()
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")


if __name__ == "__main__":
    unittest.main()
