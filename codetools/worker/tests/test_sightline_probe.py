"""Acceptance tests for P3.2 sightline (code-probe) adapter.

Covers:
  - import proof: vendored sightline importable + basic function call
  - explore: search op + where-defined op against fixture dir
  - inspect: attach → list round-trip; status against temp dir (no crash)
  - validate: artifact_only + expected_artifact_text matching
  - every envelope passes envelope.validate
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add worker package root to sys.path so we can do relative imports the same
# way the worker does.
_WORKER_ROOT = Path(__file__).parent.parent
if str(_WORKER_ROOT) not in sys.path:
    sys.path.insert(0, str(_WORKER_ROOT))

# Inject the bundled rg binary into PATH so sightline's search.py can find it.
# The bundle is built by build-python-runtime-bundle.sh; on dev boxes where rg
# is not on PATH we fall back to the runtime-stage copy next to the worker.
def _inject_bundled_rg() -> None:
    """Put the bundled rg on PATH if it exists and isn't there already."""
    candidates = [
        # Runtime-stage bundle (built by build-python-runtime-bundle.sh)
        _WORKER_ROOT.parent / "runtime-build" / "runtime-stage" / "linux-x86_64" / "bin",
        # Extracted rg tarball (rg-inject step in build script)
        _WORKER_ROOT.parent / "runtime-build" / "rg-extract-linux-x86_64" /
        "ripgrep-15.1.0-x86_64-unknown-linux-musl",
    ]
    for candidate_dir in candidates:
        rg = candidate_dir / "rg"
        if rg.is_file() and os.access(rg, os.X_OK):
            current = os.environ.get("PATH", "")
            if str(candidate_dir) not in current.split(os.pathsep):
                os.environ["PATH"] = str(candidate_dir) + os.pathsep + current
            return

# NOTE: _inject_bundled_rg() is called in setUpClass for test classes that
# invoke rg-dependent operations. It is NOT called here at module level to
# avoid polluting PATH before test_files_grep.GrepTest computes _RG_AVAILABLE
# (that variable is evaluated at import time, and test_files_grep loads
# alphabetically before this module).

from codetools_worker import envelope
from codetools_worker import sightline_probe
from codetools_worker.sightline_probe import explore, inspect, validate

# Fixture directory with real GDScript files (used as search target).
_FIXTURES = Path(__file__).parent / "fixtures" / "godot_project"


class TestImportProof(unittest.TestCase):
    """Prove the vendored sightline library is importable via our sys.path strategy."""

    @classmethod
    def setUpClass(cls):
        _inject_bundled_rg()

    def test_import_sightline_modules(self):
        """Import each sightline sub-module and verify a key symbol is present."""
        # Trigger import via the adapter (idempotent once done above).
        sightline_probe._ensure_sightline_imports()

        self.assertIsNotNone(sightline_probe._explore)
        self.assertIsNotNone(sightline_probe._search_mod)
        self.assertIsNotNone(sightline_probe._files_mod)
        self.assertIsNotNone(sightline_probe._inspect_mod)
        self.assertIsNotNone(sightline_probe._validate_mod)
        self.assertIsNotNone(sightline_probe._models_mod)
        self.assertIsNotNone(sightline_probe._godot_plugin)

    def test_call_search_code(self):
        """Directly call a sightline function to prove the import is live."""
        sightline_probe._ensure_sightline_imports()
        search_mod = sightline_probe._search_mod
        # search_code falls back to Path.rglob when rg is not on PATH.
        results = search_mod.search_code(
            _FIXTURES, "player", mode="literal", limit=5
        )
        # The fixture dir has player.gd + references — expect at least one hit.
        self.assertIsInstance(results, list)
        # Each result has .to_dict()
        if results:
            d = results[0].to_dict()
            self.assertIn("result_id", d)
            self.assertIn("path", d)
            self.assertIn("preview", d)

    def test_call_list_repo_files(self):
        """Directly call list_repo_files to prove the files module works."""
        sightline_probe._ensure_sightline_imports()
        files_mod = sightline_probe._files_mod
        repo_files = files_mod.list_repo_files(_FIXTURES)
        self.assertIsInstance(repo_files, list)
        paths = [f.path for f in repo_files]
        # fixture dir has .gd files
        self.assertTrue(any(p.endswith(".gd") for p in paths), msg="Expected .gd files: %s" % paths)


class TestExplore(unittest.TestCase):
    """Tests for the explore() handler."""

    @classmethod
    def setUpClass(cls):
        _inject_bundled_rg()

    def _valid_envelope(self, env):
        return envelope.validate(env)

    def test_search_op_literal(self):
        env = explore({"op": "search", "query": "player", "root": str(_FIXTURES), "limit": 5})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        arts = env["artifacts"]
        self.assertEqual(len(arts), 1)
        art = arts[0]
        self.assertEqual(art["type"], "search_results")
        self.assertEqual(art["query"], "player")
        self.assertEqual(art["mode"], "literal")
        self.assertIn("results", art)
        self.assertIsInstance(art["results"], list)

    def test_search_op_regex(self):
        env = explore({"op": "search", "query": "func.*player", "root": str(_FIXTURES), "regex": True, "limit": 3})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["mode"], "regex")

    def test_where_defined(self):
        env = explore({"op": "where-defined", "query": "player", "root": str(_FIXTURES), "limit": 3})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "explore_report")
        self.assertEqual(art["command"], "where-defined")
        self.assertIn("entries", art)
        self.assertIsInstance(art["entries"], list)

    def test_where_tested(self):
        env = explore({"op": "where-tested", "query": "player", "root": str(_FIXTURES), "limit": 3})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "explore_report")

    def test_locate_edit(self):
        env = explore({"op": "locate-edit", "query": "player", "root": str(_FIXTURES)})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "explore_report")
        self.assertEqual(art["command"], "locate-edit")

    def test_trace_topic(self):
        env = explore({"op": "trace-topic", "query": "player", "root": str(_FIXTURES)})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "explore_report")
        self.assertEqual(art["command"], "trace-topic")

    def test_files_op(self):
        env = explore({"op": "files", "root": str(_FIXTURES)})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "repo_files")
        self.assertIsInstance(art["files"], list)
        self.assertGreater(art["count"], 0)

    def test_missing_query_raises_tool_error(self):
        from codetools_worker.errors import ToolError
        with self.assertRaises(ToolError):
            explore({"op": "search", "root": str(_FIXTURES)})

    def test_invalid_op_raises_tool_error(self):
        from codetools_worker.errors import ToolError
        with self.assertRaises(ToolError):
            explore({"op": "not-a-real-op", "root": str(_FIXTURES)})

    def test_bad_root_raises_tool_error(self):
        from codetools_worker.errors import ToolError
        with self.assertRaises(ToolError):
            explore({"op": "search", "query": "x", "root": "/nonexistent/path/12345"})

    def test_search_returns_non_empty_results_for_known_token(self):
        env = explore({"op": "search", "query": "player", "root": str(_FIXTURES)})
        self._valid_envelope(env)
        art = env["artifacts"][0]
        # player appears in the fixture files — expect results
        self.assertGreater(len(art["results"]), 0, msg="Expected search hits for 'player' in fixture dir")

    def test_explore_report_entry_structure(self):
        env = explore({"op": "where-defined", "query": "player", "root": str(_FIXTURES), "limit": 3})
        art = env["artifacts"][0]
        for entry in art["entries"]:
            self.assertIn("handle", entry)
            self.assertIn("context", entry)
            handle = entry["handle"]
            self.assertIn("result_id", handle)
            self.assertIn("path", handle)

    def test_default_root_uses_cwd(self):
        # Should not raise even without explicit root (uses cwd which exists).
        env = explore({"op": "files"})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")


class TestInspect(unittest.TestCase):
    """Tests for the inspect() handler — attach/list/status round-trips."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self._artifact_file = os.path.join(self.tmpdir, "evidence.json")
        with open(self._artifact_file, "w") as f:
            json.dump({"hello": "world", "status": "observed"}, f)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)
        # Reset module-level import flag so tests remain independent.
        sightline_probe._sightline_imported = False
        sightline_probe._explore = None
        sightline_probe._search_mod = None
        sightline_probe._files_mod = None
        sightline_probe._inspect_mod = None
        sightline_probe._validate_mod = None
        sightline_probe._models_mod = None
        sightline_probe._godot_plugin = None

    def _valid_envelope(self, env):
        return envelope.validate(env)

    def test_attach_creates_session(self):
        env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "surface_kind": "path",
            "surface_path": "/some/ui/path",
            "artifacts": [["screenshot", self._artifact_file]],
        })
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "inspect_result")
        self.assertIn("session_id", art)
        self.assertIn("artifacts", art)
        self.assertIsInstance(art["artifacts"], list)
        self.assertEqual(len(art["artifacts"]), 1)
        self.assertEqual(art["artifacts"][0]["kind"], "screenshot")

    def test_list_sessions_after_attach(self):
        # Attach first.
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "artifacts": [["screenshot", self._artifact_file]],
        })
        self._valid_envelope(attach_env)

        # List sessions.
        list_env = inspect({"op": "list", "root": self.tmpdir})
        self._valid_envelope(list_env)
        self.assertEqual(list_env["status"], "ok")
        art = list_env["artifacts"][0]
        self.assertEqual(art["type"], "inspect_sessions")
        self.assertGreaterEqual(art["count"], 1)

    def test_list_artifacts_for_session(self):
        attach_env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "artifacts": [["json_file", self._artifact_file]],
        })
        session_id = attach_env["artifacts"][0]["session_id"]

        list_env = inspect({"op": "list", "root": self.tmpdir, "session_id": session_id})
        self._valid_envelope(list_env)
        art = list_env["artifacts"][0]
        self.assertEqual(art["type"], "inspect_artifacts")
        self.assertEqual(art["session_id"], session_id)
        self.assertEqual(art["count"], 1)
        self.assertEqual(art["artifacts"][0]["kind"], "json_file")

    def test_status_no_crash_on_bare_dir(self):
        # A fresh tmpdir has no Godot project → probe not installed/enabled.
        env = inspect({"op": "status", "project_path": self.tmpdir})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "probe_status")
        self.assertFalse(art["installed"])
        self.assertFalse(art["enabled"])
        self.assertFalse(art["loaded"])

    def test_status_uninstalled_suggests_prepare(self):
        # P4.3: when the probe isn't installed, status emits a follow_up
        # pointing the agent at inspect op=prepare.
        env = inspect({"op": "status", "project_path": self.tmpdir})
        self._valid_envelope(env)
        self.assertEqual(len(env["follow_ups"]), 1)
        fu = env["follow_ups"][0]
        self.assertEqual(fu["tool"], "minerva_codetools_inspect")
        self.assertEqual(fu["params"]["op"], "prepare")
        self.assertIn("not installed", fu["reason"])

    def test_attach_dict_artifact_format(self):
        # Accept {kind, path} dict format as well as [kind, path] list.
        env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "artifacts": [{"kind": "screenshot", "path": self._artifact_file}],
        })
        self._valid_envelope(env)
        art = env["artifacts"][0]
        self.assertEqual(art["artifacts"][0]["kind"], "screenshot")

    def test_live_capture_op_returns_not_implemented(self):
        env = inspect({"op": "godot-debugger-issues", "root": self.tmpdir})
        self._valid_envelope(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "not_implemented")

    def test_invalid_op_raises_tool_error(self):
        from codetools_worker.errors import ToolError
        with self.assertRaises(ToolError):
            inspect({"op": "not-an-op"})


class TestValidate(unittest.TestCase):
    """Tests for the validate() handler."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        # Create an artifact file with known text content.
        self._artifact_file = os.path.join(self.tmpdir, "observation.json")
        with open(self._artifact_file, "w") as f:
            json.dump({"feature": "export-button", "visible": True, "label": "Export"}, f)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)
        # Reset sightline import state.
        sightline_probe._sightline_imported = False
        sightline_probe._explore = None
        sightline_probe._search_mod = None
        sightline_probe._files_mod = None
        sightline_probe._inspect_mod = None
        sightline_probe._validate_mod = None
        sightline_probe._models_mod = None
        sightline_probe._godot_plugin = None

    def _valid_envelope(self, env):
        return envelope.validate(env)

    def _attach_artifact(self, kind="json_file"):
        env = inspect({
            "op": "attach",
            "root": self.tmpdir,
            "artifacts": [[kind, self._artifact_file]],
        })
        art = env["artifacts"][0]
        return art["session_id"], art["artifacts"][0]["artifact_id"]

    def test_validate_artifact_only_pass(self):
        session_id, artifact_id = self._attach_artifact()

        env = validate({
            "goal": "export button is visible",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
        })
        self._valid_envelope(env)
        self.assertEqual(env["status"], "ok")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "validation_result")
        self.assertIn("status", art)
        self.assertIn("confidence", art)
        self.assertIn("checks", art)
        self.assertIsInstance(art["checks"], list)
        # artifact_only with artifact present → should pass or uncertain
        self.assertIn(art["status"], ("pass", "uncertain"))

    def test_validate_expected_artifact_text_found(self):
        session_id, artifact_id = self._attach_artifact()

        env = validate({
            "goal": "export button label is Export",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
            "expected_artifact_text": ["export-button"],
        })
        self._valid_envelope(env)
        art = env["artifacts"][0]
        # The text "export-button" appears in the JSON artifact content.
        checks_by_name = {c["name"]: c for c in art["checks"]}
        self.assertIn("expected_artifact_text", checks_by_name)
        self.assertEqual(checks_by_name["expected_artifact_text"]["status"], "pass")

    def test_validate_expected_artifact_text_missing(self):
        session_id, artifact_id = self._attach_artifact()

        env = validate({
            "goal": "export button label is Submit",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
            "expected_artifact_text": ["label-not-present-in-file"],
        })
        self._valid_envelope(env)
        art = env["artifacts"][0]
        checks_by_name = {c["name"]: c for c in art["checks"]}
        self.assertIn("expected_artifact_text", checks_by_name)
        self.assertEqual(checks_by_name["expected_artifact_text"]["status"], "fail")

    def test_validate_no_evidence_returns_fail(self):
        env = validate({
            "goal": "something happened",
            "root": self.tmpdir,
        })
        self._valid_envelope(env)
        art = env["artifacts"][0]
        self.assertEqual(art["status"], "fail")
        self.assertLessEqual(art["confidence"], 0.25)

    def test_validate_missing_goal_raises_tool_error(self):
        from codetools_worker.errors import ToolError
        with self.assertRaises(ToolError):
            validate({"root": self.tmpdir})

    def test_validate_summary_contains_goal_status_confidence(self):
        env = validate({
            "goal": "test-goal",
            "root": self.tmpdir,
            "artifact_only": True,
        })
        self._valid_envelope(env)
        summary = env["summary"]
        self.assertIn("test-goal", summary)
        # Should contain status word and confidence
        self.assertIn("confidence=", summary)

    def test_validate_result_record_fields(self):
        session_id, artifact_id = self._attach_artifact()
        env = validate({
            "goal": "check all required fields",
            "root": self.tmpdir,
            "artifact_ids": [artifact_id],
            "artifact_only": True,
        })
        art = env["artifacts"][0]
        for field in ["validation_id", "status", "confidence", "checks",
                      "reason_summary", "evidence_used", "gaps", "recommended_next_step"]:
            self.assertIn(field, art, msg="Missing field: %s" % field)


class TestEnvelopeValidation(unittest.TestCase):
    """Ensure every handler output passes envelope.validate."""

    @classmethod
    def setUpClass(cls):
        _inject_bundled_rg()

    def _roundtrip(self, handler, params):
        try:
            result = handler(params)
            envelope.validate(result)
        except Exception as e:
            from codetools_worker.errors import ToolError
            if isinstance(e, ToolError):
                pass  # ToolErrors are expected to be caught by the router, not here
            else:
                raise

    def test_explore_search_envelope_valid(self):
        env = explore({"op": "search", "query": "player", "root": str(_FIXTURES)})
        envelope.validate(env)

    def test_explore_files_envelope_valid(self):
        env = explore({"op": "files", "root": str(_FIXTURES)})
        envelope.validate(env)

    def test_inspect_status_envelope_valid(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env = inspect({"op": "status", "project_path": tmpdir})
            envelope.validate(env)

    def test_validate_envelope_valid(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env = validate({"goal": "minimal", "root": tmpdir, "artifact_only": True})
            envelope.validate(env)


if __name__ == "__main__":
    unittest.main()
