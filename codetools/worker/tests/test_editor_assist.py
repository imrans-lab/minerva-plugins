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
    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="ct_editor_assist_")
        Path(self.proj, "project.godot").write_text(
            'config_version=5\n\n[application]\n\nconfig/name="x"\n', encoding="utf-8"
        )
        # Plant a probe output the (mocked) launch will "produce".
        out = Path(self.proj, ".sightline", "godot_probe")
        out.mkdir(parents=True, exist_ok=True)
        self.state_path = out / "debugger_state.json"
        shutil.copyfile(FIXTURE, self.state_path)

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def test_editor_assist_normalizes_probe(self):
        launch = {"pid": 4321, "log_path": "/tmp/ed.log", "probe_loaded": True}
        with mock.patch.object(plugin, "_launch_editor_session", return_value=launch), \
             mock.patch.object(plugin, "_probe_output_path", return_value=self.state_path):
            env = sightline_probe.inspect(
                {"op": "run", "mode": "editor-assist", "project_path": self.proj}
            )
        envelope.validate(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "godot_diagnostics")
        self.assertEqual(art["source"], "editor-probe")
        self.assertEqual(art["editor_pid"], 4321)
        self.assertTrue(art["probe_loaded"])
        self.assertEqual(art["counts"]["script_error"], 1)

    def test_probe_not_loaded_emits_followup(self):
        launch = {"pid": 4321, "log_path": "/tmp/ed.log", "probe_loaded": False}
        # No probe output this time.
        self.state_path.unlink()
        with mock.patch.object(plugin, "_launch_editor_session", return_value=launch), \
             mock.patch.object(plugin, "_probe_output_path", return_value=self.state_path):
            env = sightline_probe.inspect(
                {"op": "run", "mode": "editor-assist", "project_path": self.proj}
            )
        envelope.validate(env)
        self.assertFalse(env["artifacts"][0]["probe_loaded"])
        self.assertTrue(env["follow_ups"])

    def test_launch_failure_is_clean_error(self):
        with mock.patch.object(plugin, "_launch_editor_session",
                               side_effect=RuntimeError("probe must be installed")):
            env = sightline_probe.inspect(
                {"op": "run", "mode": "editor-assist", "project_path": self.proj}
            )
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")


if __name__ == "__main__":
    unittest.main()
