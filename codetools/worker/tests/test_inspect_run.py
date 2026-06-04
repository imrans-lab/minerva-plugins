"""Adapter tests for inspect op=run (bug 019e93d8f1).

The headless driver is patched so CI needs no real Godot; the live
acceptance run on a real project is exercised separately.
"""

import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from codetools_worker import envelope
from codetools_worker import godot_diagnostics
from codetools_worker import sightline_probe


def _make_godot_project() -> str:
    d = tempfile.mkdtemp(prefix="ct_run_proj_")
    Path(d, "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="run_test"\n',
        encoding="utf-8",
    )
    return d


_CANNED = (
    "WARNING: ObjectDB instances leaked at exit\n"
    "     at: cleanup (core/object/object.cpp:2641)\n"
    "USER WARNING: unused var\n"
    "   at: _ready (res://main.gd:7)\n"
)


class InspectRunTest(unittest.TestCase):
    def setUp(self):
        self.proj = _make_godot_project()

    def tearDown(self):
        shutil.rmtree(self.proj, ignore_errors=True)

    def test_run_headless_returns_diagnostics(self):
        rec = godot_diagnostics.diagnostics_record(
            source="headless-stderr", output=_CANNED, exit_code=0, timed_out=False
        )
        rec["godot_command"] = ["godot", "--headless"]
        with mock.patch.object(godot_diagnostics, "run_headless", return_value=rec):
            env = sightline_probe.inspect({"op": "run", "mode": "headless", "project_path": self.proj})
        envelope.validate(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "godot_diagnostics")
        self.assertEqual(art["counts"]["warning"], 2)
        # One engine (not fixable) + one res:// (fixable).
        fixable = [d for d in art["diagnostics"] if d["user_fixable"]]
        self.assertEqual(len(fixable), 1)
        self.assertEqual(fixable[0]["file"], "res://main.gd")
        self.assertIn("user-fixable", env["summary"])

    def test_run_defaults_to_headless(self):
        rec = godot_diagnostics.diagnostics_record(
            source="headless-stderr", output="", exit_code=0, timed_out=False
        )
        with mock.patch.object(godot_diagnostics, "run_headless", return_value=rec) as m:
            sightline_probe.inspect({"op": "run", "project_path": self.proj})
        m.assert_called_once()

    def test_run_passes_params_through(self):
        captured = {}

        def fake_run_headless(project_path, **kwargs):
            captured.update(kwargs)
            return godot_diagnostics.diagnostics_record(
                source="headless-stderr", output="", exit_code=0, timed_out=False
            )

        with mock.patch.object(godot_diagnostics, "run_headless", side_effect=fake_run_headless):
            sightline_probe.inspect({
                "op": "run", "project_path": self.proj,
                "quit_after": 150, "verbose": True, "timeout_seconds": 30,
            })
        self.assertEqual(captured["quit_after"], 150)
        self.assertTrue(captured["verbose"])
        self.assertEqual(captured["timeout_seconds"], 30.0)

    def test_run_on_non_godot_dir_errors(self):
        d = tempfile.mkdtemp(prefix="ct_run_notgodot_")
        try:
            env = sightline_probe.inspect({"op": "run", "project_path": d})
            envelope.validate(env)
            self.assertEqual(env["status"], "error")
            self.assertEqual(env["error"]["kind"], "invalid_args")
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_bad_mode_errors(self):
        env = sightline_probe.inspect({"op": "run", "mode": "bogus", "project_path": self.proj})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")


if __name__ == "__main__":
    unittest.main()
