import json
import tempfile
import time
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

from codetools_worker import godot_debugger_capture as capture


class ProbeCaptureTest(unittest.TestCase):
    def test_preserves_duplicates_details_and_honest_completeness(self):
        state = {"debugger": {"rows": [
            {"text": "WARNING: duplicate", "details": [
                "<GDScript Source>Thing.gd:12 @ GDScript::reload()",
                "<Stack Trace> Thing.gd:12 @ f()",
            ]},
            {"text": "WARNING: duplicate", "details": [
                "<GDScript Source>Thing.gd:12 @ GDScript::reload()",
                "<Stack Trace> Thing.gd:12 @ f()",
            ]},
        ]}}
        with tempfile.TemporaryDirectory() as tmp:
            record = capture.capture_probe_state(state, Path(tmp))
            self.assertEqual(record["raw_count"], 2)
            self.assertEqual(record["unique_count"], 1)
            self.assertEqual(record["duplicate_count"], 1)
            self.assertFalse(record["complete"])
            self.assertIn("Thing.gd:12", record["raw_entries"][0])
            self.assertIn("Stack Trace", record["raw_entries"][0])
            for artifact in record["artifact_paths"]:
                self.assertTrue(Path(artifact).is_file())
            persisted = json.loads(Path(record["artifact_paths"][0]).read_text())
            self.assertEqual(persisted["raw_entries"], record["raw_entries"])

    def test_script_sweep_does_not_claim_debugger_completeness(self):
        state = {"debugger": {"rows": []}, "script_editor": {
            "sweep": {"complete": True, "scripts": []},
        }}
        with tempfile.TemporaryDirectory() as tmp:
            record = capture.capture_probe_state(state, Path(tmp))
            self.assertFalse(record["complete"])
            self.assertEqual(record["raw_count"], 0)

    def test_probe_state_must_match_requested_project(self):
        state = {"project_path": "/different", "debugger": {"rows": []}}
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, "different Godot project"):
                capture.capture_probe_state(state, Path(tmp), Path(tmp))

    def test_stale_explicit_probe_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = {"project_path": tmp, "captured_at_unix": time.time() - 60,
                     "debugger": {"rows": []}}
            with self.assertRaisesRegex(RuntimeError, "stale"):
                capture.capture({"capture_method": "probe", "project_path": tmp},
                                Path(tmp), state)


class CalibrationTest(unittest.TestCase):
    def test_window_discovery_rejects_larger_decorated_frame(self):
        def fake_run(args, **_kwargs):
            if "search" in args:
                return CompletedProcess(args, 0, b"frame\nclient\n", b"")
            if args[0] == "xprop":
                window_id = args[2]
                value = b"Openbox\n" if window_id == "frame" else b"Godot\n"
                return CompletedProcess(args, 0, value, b"")
            return CompletedProcess(args, 0, b"MainScene - Minerva - Godot\n", b"")

        def fake_geometry(window_id):
            size = (1920, 1080) if window_id == "frame" else (1920, 1043)
            return {"x": 0, "y": 0, "width": size[0], "height": size[1]}

        with mock.patch.object(capture, "_run", side_effect=fake_run), \
                mock.patch.object(capture, "_window_geometry", side_effect=fake_geometry):
            selected = capture._window_id({"window_title_contains": "Minerva"})
        self.assertEqual(selected, "client")

    def test_region_requires_four_normalized_values(self):
        self.assertEqual(capture._normalized_rect([0.1, 0.2, 0.8, 0.5]),
                         (0.1, 0.2, 0.8, 0.5))
        with self.assertRaises(RuntimeError):
            capture._normalized_rect([0.1, 0.2, 2.0, 0.5])
        with self.assertRaises(RuntimeError):
            capture._normalized_rect([0.8, 0.2, 0.3, 0.5])
        with self.assertRaises(RuntimeError):
            capture._normalized_rect([float("nan"), 0.2, 0.3, 0.5])

    def test_compact_reply_is_bounded_without_hiding_truncation(self):
        record = {"type": "godot_debugger_capture", "raw_count": 5000,
                  "raw_entries": ["entry-%d" % i for i in range(5000)],
                  "artifact_paths": ["/tmp/full.json"]}
        compact = capture.compact_record(record)
        self.assertEqual(len(compact["preview"]), 5)
        self.assertTrue(compact["preview_truncated"])
        self.assertEqual(compact["raw_count"], 5000)
        self.assertLessEqual(sum(map(len, compact["preview"])), 8000)
        one = capture.compact_record({"raw_count": 1, "raw_entries": ["x" * 3000]})
        self.assertTrue(one["preview_truncated"])

    def test_user_plugin_source_path_is_preserved(self):
        state = {"debugger": {"rows": [{
            "text": "E failure",
            "details": ["<GDScript Source>user://plugins/cad/ui/CADPanel.gd:665"],
            "severity": "error",
        }]}}
        with tempfile.TemporaryDirectory() as tmp:
            record = capture.capture_probe_state(state, Path(tmp))
            self.assertEqual(record["diagnostics"][0]["file"],
                             "user://plugins/cad/ui/CADPanel.gd")

    def test_partial_failure_restores_clipboard_and_focus_and_persists(self):
        run_calls = []

        def fake_run(args, **_kwargs):
            run_calls.append(args)
            if args[:2] == ["xdotool", "getactivewindow"]:
                return CompletedProcess(args, 0, b"99\n", b"")
            if args[:2] == ["xdotool", "windowactivate"] and args[-1] == "99":
                raise RuntimeError("restore timeout")
            return CompletedProcess(args, 0, b"", b"")

        writes = []
        reads = iter([b"original", b"WARNING: retained\nSource.gd:2"])
        clicks = mock.Mock(side_effect=[None, None, RuntimeError("action failed")])
        params = {
            "capture_method": "x11", "window_title_contains": "Project",
            "x11_region": [0.1, 0.1, 0.5, 0.5], "x11_row_height": 20,
            "x11_copy_menu_offset": [2, 2], "max_pages": 1,
        }
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.dict("os.environ", {"DISPLAY": ":1"}), \
                mock.patch.object(capture, "_window_id", return_value="1"), \
                mock.patch.object(capture, "_window_geometry", return_value={
                    "x": 0, "y": 0, "width": 200, "height": 200}), \
                mock.patch.object(capture, "_run", side_effect=fake_run), \
                mock.patch.object(capture, "_clipboard_read", side_effect=lambda: next(reads)), \
                mock.patch.object(capture, "_clipboard_write", side_effect=writes.append), \
                mock.patch.object(capture, "_click", clicks), \
                mock.patch("time.sleep"):
            record = capture.capture_x11(params, Path(tmp))
            artifact_persisted = Path(record["artifact_paths"][0]).is_file()
        self.assertEqual(record["raw_entries"], ["WARNING: retained\nSource.gd:2"])
        self.assertIn(b"original", writes)
        self.assertTrue(any(call[-1] == "99" for call in run_calls))
        self.assertIn("action failed", record["capture_error"])
        self.assertIn("restore timeout", record["capture_error"])
        self.assertTrue(artifact_persisted)
