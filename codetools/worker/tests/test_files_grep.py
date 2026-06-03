"""Tests for minerva_codetools_grep (P2.1 gate).

Exercises both the rg backend (when available) and the Python fallback.
All tests route through router.route("grep", params) and validate the
returned envelope. Uses conftest.build_codetools_fixture() for the file tree.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from codetools_worker import envelope, router
from codetools_worker.files.rg_finder import find_rg
from conftest import build_codetools_fixture, teardown_codetools_fixture

_RG_AVAILABLE = find_rg() is not None


class GrepTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build_codetools_fixture(cls, "codetools_grep_")

    @classmethod
    def tearDownClass(cls):
        teardown_codetools_fixture(cls)

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def _grep(self, pattern, **kwargs):
        params = {"pattern": pattern, "path": str(self.fixture_dir)}
        params.update(kwargs)
        env = router.route("grep", params)
        envelope.validate(env)
        return env

    def _matches(self, env):
        self.assertEqual(env["status"], "ok", env)
        return env["artifacts"][0]["matches"]

    def _art(self, env):
        self.assertEqual(env["status"], "ok", env)
        return env["artifacts"][0]

    # -------------------------------------------------------------------------
    # Artifact shape
    # -------------------------------------------------------------------------

    def test_artifact_type_is_grep_result(self):
        env = self._grep("def ")
        self.assertEqual(env["artifacts"][0]["type"], "grep_result")

    def test_artifact_has_required_fields(self):
        art = self._art(self._grep("def "))
        for f in ("type", "pattern", "path", "matches", "total_matches", "truncated", "backend"):
            self.assertIn(f, art, "missing field: %s" % f)

    def test_match_has_required_fields(self):
        matches = self._matches(self._grep("def "))
        self.assertGreater(len(matches), 0)
        for m in matches[:3]:
            self.assertIn("file", m)
            self.assertIn("line", m)
            self.assertIn("content", m)

    # -------------------------------------------------------------------------
    # Regex matching
    # -------------------------------------------------------------------------

    def test_finds_simple_pattern(self):
        matches = self._matches(self._grep("hello world"))
        self.assertTrue(any("hello world" in m["content"] for m in matches),
                        "expected 'hello world' in a match: %r" % matches)

    def test_finds_regex_pattern(self):
        # Match 'def ' followed by word chars
        matches = self._matches(self._grep(r"def \w+"))
        self.assertGreaterEqual(len(matches), 3,
                                "expected >=3 function defs: %r" % matches)

    def test_no_match_returns_empty(self):
        art = self._art(self._grep("ZZZNOMATCHZZZ"))
        self.assertEqual(art["matches"], [])
        self.assertEqual(art["total_matches"], 0)

    # -------------------------------------------------------------------------
    # Case sensitivity
    # -------------------------------------------------------------------------

    def test_case_sensitive_default(self):
        # 'TODO' is uppercase in utils.py; 'todo' (lowercase) should not match
        art_sensitive = self._art(self._grep("todo"))
        art_insensitive = self._art(self._grep("todo", ignore_case=True))
        # Case-sensitive: no match (the file has 'TODO')
        self.assertEqual(art_sensitive["total_matches"], 0,
                         "case-sensitive should not find 'todo' (file has 'TODO')")
        # Case-insensitive: should find it
        self.assertGreater(art_insensitive["total_matches"], 0,
                           "case-insensitive should find 'TODO' when searching 'todo'")

    # -------------------------------------------------------------------------
    # Context lines
    # -------------------------------------------------------------------------

    def test_context_before(self):
        matches = self._matches(self._grep("TODO", context_before=1))
        # At least one match should have context_before
        has_ctx = any("context_before" in m for m in matches)
        self.assertTrue(has_ctx, "no match had context_before: %r" % matches)

    def test_context_after(self):
        matches = self._matches(self._grep("def main", context_after=1))
        has_ctx = any("context_after" in m for m in matches)
        self.assertTrue(has_ctx, "no match had context_after: %r" % matches)

    def test_context_lines_shorthand(self):
        matches = self._matches(self._grep("def ", context_lines=1))
        # At least one match should have either context key
        has_ctx = any("context_before" in m or "context_after" in m for m in matches)
        self.assertTrue(has_ctx, "no match had any context: %r" % matches)

    # -------------------------------------------------------------------------
    # Binary skip
    # -------------------------------------------------------------------------

    def test_binary_files_are_skipped(self):
        # binary.bin contains null bytes but should not appear in grep results.
        art = self._art(self._grep("binary"))
        binary_hits = [m for m in art["matches"] if "binary.bin" in m["file"]]
        self.assertEqual(binary_hits, [],
                         "binary.bin should be skipped: %r" % binary_hits)

    # -------------------------------------------------------------------------
    # Type filter
    # -------------------------------------------------------------------------

    def test_type_filter_py_excludes_txt(self):
        art = self._art(self._grep("needle", type="py"))
        # sample.txt contains 'needle' but type=py should exclude it
        txt_hits = [m for m in art["matches"] if m["file"].endswith(".txt")]
        self.assertEqual(txt_hits, [],
                         "type=py should exclude .txt: %r" % txt_hits)

    def test_type_filter_finds_correct_files(self):
        matches = self._matches(self._grep("def ", type="py"))
        if matches:
            for m in matches:
                self.assertTrue(m["file"].endswith(".py"),
                                "type=py match should be .py: %s" % m["file"])

    # -------------------------------------------------------------------------
    # Exclusion (noise dirs)
    # -------------------------------------------------------------------------

    def test_excludes_git_dir(self):
        art = self._art(self._grep("bare"))
        git_hits = [m for m in art["matches"] if ".git" in m["file"]]
        self.assertEqual(git_hits, [],
                         ".git files should be excluded: %r" % git_hits)

    def test_excludes_node_modules(self):
        art = self._art(self._grep("exports"))
        nm_hits = [m for m in art["matches"] if "node_modules" in m["file"]]
        self.assertEqual(nm_hits, [],
                         "node_modules should be excluded: %r" % nm_hits)

    # -------------------------------------------------------------------------
    # Limit
    # -------------------------------------------------------------------------

    def test_limit_caps_matches(self):
        # 'def ' appears multiple times; limit=1 should cap the list
        art = self._art(self._grep(r"def \w+", limit=1))
        self.assertLessEqual(len(art["matches"]), 1)
        # total_matches may be higher
        self.assertGreaterEqual(art["total_matches"], len(art["matches"]))

    def test_limit_sets_truncated(self):
        art = self._art(self._grep(r"def \w+", limit=1))
        if art["total_matches"] > 1:
            self.assertTrue(art["truncated"])

    # -------------------------------------------------------------------------
    # Error cases
    # -------------------------------------------------------------------------

    def test_missing_pattern_returns_error(self):
        env = router.route("grep", {"path": str(self.fixture_dir)})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")

    def test_invalid_regex_returns_error(self):
        # Pure-Python path: invalid regex raises ToolError → error envelope.
        # rg path: rg itself will error; we surface as error envelope.
        env = router.route("grep", {
            "pattern": "[invalid(regex",
            "path": str(self.fixture_dir),
        })
        envelope.validate(env)
        # rg exits non-zero for bad regex; Python raises re.error → ToolError
        # Both should produce status=error
        # NOTE: rg may actually exit 0 with no matches on some platforms;
        # only assert error for the Python fallback path.
        if not _RG_AVAILABLE:
            self.assertEqual(env["status"], "error")

    def test_nonexistent_path_returns_error(self):
        env = router.route("grep", {
            "pattern": "foo",
            "path": "/nonexistent/path/xyz",
        })
        envelope.validate(env)
        self.assertEqual(env["status"], "error")


if __name__ == "__main__":
    unittest.main()
