"""Tests for the autonomous Godot diagnostics sink (bug 019e93d8f1).

Parser is validated against the REAL godot 4.6.2 stderr format (including the
empirically-captured voice-capture ObjectDB warning) and engine-vs-res://
classification. The headless driver is exercised with an injected runner so no
real Godot is spawned.
"""

import unittest
from pathlib import Path

from codetools_worker import godot_diagnostics as gd

# Verbatim from the proven voice-capture headless run (godot 4.6.2).
VOICE_CAPTURE_OUTPUT = """Godot Engine v4.6.2.stable.official.71f334935 - https://godotengine.org

[VoiceCapture] Ready. Rec bus=1 vol=-80 dB mute=false
[VoiceCapture] Input=Default Output=Default
WARNING: ObjectDB instances leaked at exit (run with --verbose for details).
     at: cleanup (core/object/object.cpp:2641)
"""


class ParseTest(unittest.TestCase):
    def test_empirical_objectdb_warning(self):
        diags = gd.parse_godot_output(VOICE_CAPTURE_OUTPUT)
        self.assertEqual(len(diags), 1)
        d = diags[0]
        self.assertEqual(d["severity"], "warning")
        self.assertEqual(d["message"], "ObjectDB instances leaked at exit (run with --verbose for details).")
        self.assertEqual(d["file"], "core/object/object.cpp")
        self.assertEqual(d["line"], 2641)
        self.assertEqual(d["function"], "cleanup")
        # Engine C++ source — NOT user-fixable.
        self.assertFalse(d["user_fixable"])

    def test_app_prints_are_ignored(self):
        # The [VoiceCapture] print lines must not become diagnostics.
        diags = gd.parse_godot_output(VOICE_CAPTURE_OUTPUT)
        self.assertTrue(all("VoiceCapture" not in d["message"] for d in diags))

    def test_user_warning_in_user_script_is_fixable(self):
        text = (
            "USER WARNING: node has no parent\n"
            "   at: _ready (res://scenes/main.gd:42)\n"
        )
        diags = gd.parse_godot_output(text)
        self.assertEqual(len(diags), 1)
        self.assertEqual(diags[0]["severity"], "warning")
        self.assertEqual(diags[0]["file"], "res://scenes/main.gd")
        self.assertEqual(diags[0]["line"], 42)
        self.assertTrue(diags[0]["user_fixable"])

    def test_script_error_severity(self):
        text = (
            "SCRIPT ERROR: Invalid call. Nonexistent function 'foo'\n"
            "   at: _process (res://player.gd:17)\n"
        )
        diags = gd.parse_godot_output(text)
        self.assertEqual(diags[0]["severity"], "script_error")
        self.assertTrue(diags[0]["user_fixable"])

    def test_user_error_and_engine_error_severity(self):
        text = (
            "USER ERROR: boom\n"
            "   at: f (res://a.gd:1)\n"
            "ERROR: engine boom\n"
            "   at: g (core/x.cpp:9)\n"
        )
        diags = gd.parse_godot_output(text)
        self.assertEqual([d["severity"] for d in diags], ["error", "error"])
        self.assertTrue(diags[0]["user_fixable"])
        self.assertFalse(diags[1]["user_fixable"])

    def test_header_without_at_line(self):
        diags = gd.parse_godot_output("WARNING: standalone warning with no location\n")
        self.assertEqual(len(diags), 1)
        self.assertIsNone(diags[0]["file"])
        self.assertIsNone(diags[0]["line"])
        self.assertIsNone(diags[0]["function"])
        self.assertFalse(diags[0]["user_fixable"])

    def test_longer_prefixes_win(self):
        # "USER WARNING" must not be misread as a bare "WARNING".
        diags = gd.parse_godot_output("USER WARNING: x\n")
        self.assertEqual(diags[0]["severity"], "warning")
        self.assertEqual(diags[0]["message"], "x")


class UnprefixedParseTest(unittest.TestCase):
    """Curated unprefixed Godot diagnostics (019e988adc59) — the Unicode NUL line."""

    def test_unicode_parse_error_captured_as_warning(self):
        text = "Unicode parsing error, some characters were replaced (U+FFFD): Unexpected NUL character\n"
        diags = gd.parse_godot_output(text)
        self.assertEqual(len(diags), 1)
        self.assertEqual(diags[0]["severity"], "warning")
        self.assertIn("Unicode parsing error", diags[0]["message"])
        self.assertIsNone(diags[0]["file"])
        self.assertFalse(diags[0]["user_fixable"])

    def test_benign_lines_are_not_overmatched(self):
        # Normal engine chatter must NOT become diagnostics.
        text = (
            "Loading resource: res://assets/icons/spinner_progress.png\n"
            "[SingletonObject] Docket initialized (1 projects)\n"
            "Selected provider: gpt-5.5\n"
        )
        self.assertEqual(gd.parse_godot_output(text), [])

    def test_mixed_prefixed_and_unprefixed_real_sample(self):
        # Representative of the Minerva headless init/exit output.
        text = (
            "Loading resource: res://assets/icons/spinner_progress.png\n"
            "Unicode parsing error, some characters were replaced (U+FFFD): Unexpected NUL character\n"
            "ERROR: 29 RID allocations of type 'DummyTexture' were leaked at exit.\n"
            "WARNING: ObjectDB instances leaked at exit (run with --verbose for details).\n"
            "     at: cleanup (core/object/object.cpp:2641)\n"
        )
        diags = gd.parse_godot_output(text)
        # unicode(warning) + RID(error) + ObjectDB(warning w/ at:) = 3; "Loading" dropped.
        self.assertEqual(len(diags), 3)
        sevs = [d["severity"] for d in diags]
        self.assertEqual(sevs, ["warning", "error", "warning"])
        # The unprefixed one carries no location; the ObjectDB one does.
        self.assertIsNone(diags[0]["file"])
        self.assertEqual(diags[2]["file"], "core/object/object.cpp")
        self.assertEqual(diags[2]["line"], 2641)

    def test_record_counts_include_unprefixed(self):
        text = (
            "Unicode parsing error: Unexpected NUL character\n"
            "Unicode parsing error: Unexpected NUL character\n"
        )
        rec = gd.diagnostics_record(
            source="headless-stderr", output=text, exit_code=0, timed_out=False)
        self.assertEqual(rec["counts"]["warning"], 2)


class RecordTest(unittest.TestCase):
    def test_counts_and_shape(self):
        text = (
            "WARNING: w1\n   at: a (res://a.gd:1)\n"
            "WARNING: w2\n"
            "SCRIPT ERROR: e1\n   at: b (res://b.gd:2)\n"
        )
        rec = gd.diagnostics_record(
            source="headless-stderr", output=text, exit_code=0, timed_out=False, log_path="/tmp/x.log"
        )
        self.assertEqual(rec["type"], "godot_diagnostics")
        self.assertEqual(rec["source"], "headless-stderr")
        self.assertEqual(rec["counts"]["warning"], 2)
        self.assertEqual(rec["counts"]["script_error"], 1)
        self.assertEqual(rec["counts"]["error"], 0)
        self.assertEqual(rec["exit_code"], 0)
        self.assertFalse(rec["timed_out"])
        self.assertEqual(rec["log_path"], "/tmp/x.log")


class CommandTest(unittest.TestCase):
    def test_build_headless_command(self):
        cmd = gd.build_headless_command(
            Path("/proj"), scene=None, quit_after=150, verbose=True, godot_bin="godot"
        )
        self.assertEqual(cmd, ["godot", "--headless", "--path", "/proj", "--quit-after", "150", "--verbose"])

    def test_build_headless_command_with_scene_no_verbose(self):
        cmd = gd.build_headless_command(
            Path("/proj"), scene="res://main.tscn", quit_after=200, verbose=False, godot_bin="/usr/local/bin/godot"
        )
        self.assertEqual(
            cmd,
            ["/usr/local/bin/godot", "--headless", "--path", "/proj", "res://main.tscn", "--quit-after", "200"],
        )


class RunHeadlessTest(unittest.TestCase):
    def test_injected_runner_normalizes(self):
        def fake_runner(command, timeout_seconds):
            self.assertIn("--headless", command)
            return gd.RunResult(0, VOICE_CAPTURE_OUTPUT, False)

        rec = gd.run_headless(Path("/proj"), runner=fake_runner, quit_after=150)
        self.assertEqual(rec["source"], "headless-stderr")
        self.assertEqual(rec["counts"]["warning"], 1)
        self.assertEqual(rec["exit_code"], 0)
        self.assertFalse(rec["timed_out"])
        self.assertIn("--quit-after", rec["godot_command"])

    def test_timeout_path(self):
        def fake_runner(command, timeout_seconds):
            return gd.RunResult(None, "WARNING: partial\n", True)

        rec = gd.run_headless(Path("/proj"), runner=fake_runner)
        self.assertTrue(rec["timed_out"])
        self.assertIsNone(rec["exit_code"])
        self.assertEqual(rec["counts"]["warning"], 1)


if __name__ == "__main__":
    unittest.main()
