"""Tests for the autonomous Godot diagnostics sink (bug 019e93d8f1).

Parser is validated against the REAL godot 4.6.2 stderr format (including the
empirically-captured voice-capture ObjectDB warning) and engine-vs-res://
classification. The headless driver is exercised with an injected runner so no
real Godot is spawned.
"""

import shutil
import tempfile
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


class SymbolResolutionTest(unittest.TestCase):
    """Fix 1: resolve a file:line for location-less editor-probe warnings (019e988adc59)."""

    CE_SIZE = ('The parameter "ce_size" is never used in the function '
               '"_draw_line_marker()". If this is intended, prefix it with "_ce_size".')

    def test_function_names_extracted(self):
        self.assertEqual(gd._function_names_in_message(self.CE_SIZE), ["_draw_line_marker"])
        self.assertEqual(gd._function_names_in_message('"await" keyword is unnecessary'), [])

    def test_resolution_fills_location(self):
        diags = [{"severity": "warning", "message": self.CE_SIZE, "file": None,
                  "line": None, "function": None, "user_fixable": False}]
        finder = lambda root, names: {"_draw_line_marker": ("res://x/Foo.gd", 168)}
        gd.resolve_symbol_locations(diags, "/proj", finder=finder)
        self.assertEqual(diags[0]["file"], "res://x/Foo.gd")
        self.assertEqual(diags[0]["line"], 168)
        self.assertTrue(diags[0]["user_fixable"])
        self.assertEqual(diags[0]["resolved_via"], "symbol-grep")

    def test_ambiguous_or_missing_stays_unresolved(self):
        diags = [{"severity": "warning", "message": self.CE_SIZE, "file": None,
                  "line": None, "function": None, "user_fixable": False}]
        gd.resolve_symbol_locations(diags, "/proj", finder=lambda r, n: {})  # no match
        self.assertIsNone(diags[0]["file"])
        self.assertFalse(diags[0]["user_fixable"])

    def test_already_located_is_not_touched(self):
        diags = [{"severity": "warning", "message": self.CE_SIZE,
                  "file": "res://already.gd", "line": 5, "function": None, "user_fixable": True}]
        called = {"n": 0}
        def finder(r, n):
            called["n"] += 1
            return {"_draw_line_marker": ("res://x.gd", 1)}
        gd.resolve_symbol_locations(diags, "/proj", finder=finder)
        self.assertEqual(diags[0]["file"], "res://already.gd")  # unchanged
        self.assertEqual(called["n"], 0)  # no work when nothing is unresolved

    def test_build_func_index_unique_match(self):
        d = tempfile.mkdtemp(prefix="ct_funcidx_")
        try:
            Path(d, "a.gd").write_text("extends Node\n\nfunc _draw_line_marker(x):\n\tpass\n")
            Path(d, "b.gd").write_text("func other():\n\tpass\n")
            idx = gd._build_func_index(d, {"_draw_line_marker", "other", "missing"})
            self.assertEqual(idx["_draw_line_marker"], ("res://a.gd", 3))
            self.assertEqual(idx["other"], ("res://b.gd", 1))
            self.assertNotIn("missing", idx)
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_build_func_index_ambiguous_omitted(self):
        d = tempfile.mkdtemp(prefix="ct_funcidx2_")
        try:
            Path(d, "a.gd").write_text("func dup():\n\tpass\n")
            Path(d, "b.gd").write_text("func dup():\n\tpass\n")
            idx = gd._build_func_index(d, {"dup"})
            self.assertNotIn("dup", idx)  # ambiguous → not guessed
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_script_editor_warnings_have_exact_line(self):
        state = {"script_editor": {
            "current_script": "res://Scripts/Foo.gd",
            "warnings": [
                {"line": 172, "code": "UNUSED_PARAMETER", "message": 'The parameter "ce_size" is never used.'},
                {"line": 88, "code": "UNNECESSARY_AWAIT", "message": '"await" keyword is unnecessary.'},
            ],
        }}
        diags = gd._script_editor_diagnostics(state)
        self.assertEqual(len(diags), 2)
        self.assertEqual(diags[0]["file"], "res://Scripts/Foo.gd")
        self.assertEqual(diags[0]["line"], 172)
        self.assertTrue(diags[0]["user_fixable"])
        self.assertEqual(diags[0]["source_panel"], "script_editor")
        # The un-named await warning now HAS a line (the fix-1 grep couldn't get it).
        self.assertEqual(diags[1]["line"], 88)

    def test_dedup_prefers_script_editor_line_over_debugger(self):
        # SAME warning in both panels — debugger (no line) + script-editor (line 172).
        state = {
            "debugger": {"rows": [{"severity": "warning",
                "text": '0:00:09:547 GDScript::reload: The parameter "ce_size" is never used in "_draw_line_marker()".'}]},
            "script_editor": {"current_script": "res://Foo.gd", "warnings": [
                {"line": 172, "message": 'The parameter "ce_size" is never used in "_draw_line_marker()".'}]},
        }
        diags = gd.probe_state_to_diagnostics(state)
        self.assertEqual(len(diags), 1)  # collapsed
        self.assertEqual(diags[0]["line"], 172)
        self.assertEqual(diags[0]["file"], "res://Foo.gd")

    def test_debugger_only_state_unchanged(self):
        # Backward compat: no script_editor section → debugger rows as before.
        state = {"debugger": {"rows": [{"severity": "warning", "text": "plain warning"}]}}
        diags = gd.probe_state_to_diagnostics(state)
        self.assertEqual(len(diags), 1)
        self.assertIsNone(diags[0]["file"])

    def test_sweep_yields_per_script_warnings(self):
        # The automatic open-scripts sweep: warnings for MANY scripts, each located.
        state = {"script_editor": {"current_script": "res://A.gd", "warnings": [], "sweep": {
            "nonce": "scan-1",
            "scripts": [
                {"script": "res://Autoload.gd", "warnings": [
                    {"line": 478, "code": "REDUNDANT_AWAIT", "message": '"await" keyword is unnecessary.'}]},
                {"script": "res://B.gd", "warnings": [
                    {"line": 12, "code": "UNUSED_SIGNAL", "message": 'The signal "x" is never used.'}]},
            ]}}}
        diags = gd.probe_state_to_diagnostics(state)
        self.assertEqual(len(diags), 2)
        by_file = {d["file"]: d for d in diags}
        self.assertEqual(by_file["res://Autoload.gd"]["line"], 478)
        self.assertTrue(by_file["res://Autoload.gd"]["user_fixable"])
        self.assertEqual(by_file["res://B.gd"]["line"], 12)

    def test_sweep_and_current_dedup(self):
        # Same script appears as current AND in the sweep — collapse to one.
        state = {"script_editor": {
            "current_script": "res://A.gd",
            "warnings": [{"line": 10, "message": "dup warning here"}],
            "sweep": {"nonce": "n", "scripts": [
                {"script": "res://A.gd", "warnings": [{"line": 10, "message": "dup warning here"}]}]}}}
        diags = gd.probe_state_to_diagnostics(state)
        self.assertEqual(len(diags), 1)
        self.assertEqual(diags[0]["line"], 10)

    def test_record_from_probe_resolves_with_root(self):
        d = tempfile.mkdtemp(prefix="ct_probe_resolve_")
        try:
            Path(d, "Canvas.gd").write_text("extends Node2D\n\nfunc _draw_line_marker(a, b):\n\tpass\n")
            state = {"debugger": {"rows": [{"severity": "warning", "text": self.CE_SIZE}]}}
            rec = gd.diagnostics_record_from_probe(state, root=d)
            diag = rec["diagnostics"][0]
            self.assertEqual(diag["file"], "res://Canvas.gd")
            self.assertEqual(diag["line"], 3)
            self.assertTrue(diag["user_fixable"])
        finally:
            shutil.rmtree(d, ignore_errors=True)


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
