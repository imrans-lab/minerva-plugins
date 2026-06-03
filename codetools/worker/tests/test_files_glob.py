"""Tests for minerva_codetools_glob (P2.1 gate).

All tests route through router.route("glob", params) and validate the returned
envelope with envelope.validate(). No stubs — uses a real on-disk fixture tree
created by conftest.build_codetools_fixture().
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

# Ensure the worker package is importable when run directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from codetools_worker import envelope, router
from conftest import build_codetools_fixture, teardown_codetools_fixture


class GlobTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build_codetools_fixture(cls, "codetools_glob_")

    @classmethod
    def tearDownClass(cls):
        teardown_codetools_fixture(cls)

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def _glob(self, pattern, **kwargs):
        params = {"pattern": pattern, "path": str(self.fixture_dir)}
        params.update(kwargs)
        env = router.route("glob", params)
        envelope.validate(env)
        return env

    def _files(self, env):
        self.assertEqual(env["status"], "ok")
        return env["artifacts"][0]["files"]

    def _art(self, env):
        self.assertEqual(env["status"], "ok")
        return env["artifacts"][0]

    # -------------------------------------------------------------------------
    # Artifact shape
    # -------------------------------------------------------------------------

    def test_artifact_type_is_glob_result(self):
        env = self._glob("**/*.py")
        self.assertEqual(env["artifacts"][0]["type"], "glob_result")

    def test_artifact_has_required_fields(self):
        art = self._art(self._glob("**/*.py"))
        for field in ("type", "pattern", "base", "files", "total_matches", "truncated"):
            self.assertIn(field, art, "missing field: %s" % field)

    # -------------------------------------------------------------------------
    # ** wildcard
    # -------------------------------------------------------------------------

    def test_double_star_finds_py_files_recursively(self):
        files = self._files(self._glob("**/*.py"))
        # Should find src/main.py, src/utils.py, tests/test_main.py
        self.assertGreaterEqual(len(files), 3)
        exts = {os.path.splitext(f)[1] for f in files}
        self.assertEqual(exts, {".py"})

    def test_double_star_at_root_finds_any_file(self):
        files = self._files(self._glob("**"))
        # txt, bin, py files — at least 5 real files excluding excluded dirs
        self.assertGreaterEqual(len(files), 5)

    def test_double_star_slash_prefix(self):
        # **/test_*.py should find tests/test_main.py
        files = self._files(self._glob("**/test_*.py"))
        self.assertTrue(any("test_main.py" in f for f in files),
                        "test_main.py not found in: %r" % files)

    # -------------------------------------------------------------------------
    # * wildcard (single directory level)
    # -------------------------------------------------------------------------

    def test_single_star_py(self):
        # src/*.py — should only find files directly in src/, not nested
        files = self._files(self._glob("src/*.py"))
        self.assertGreaterEqual(len(files), 2)
        for f in files:
            # No slash after src/ (not nested further)
            self.assertTrue(f.startswith("src/"), f)
            parts = f.split("/")
            self.assertEqual(len(parts), 2, "unexpected nesting: %s" % f)

    # -------------------------------------------------------------------------
    # ? wildcard
    # -------------------------------------------------------------------------

    def test_question_mark_wildcard(self):
        # data/sample.?xt should match sample.txt
        files = self._files(self._glob("data/sample.?xt"))
        self.assertTrue(any("sample.txt" in f for f in files),
                        "sample.txt not found: %r" % files)

    def test_question_mark_does_not_cross_slash(self):
        # src/?.py should NOT match src/main.py (4 chars before .)
        files = self._files(self._glob("src/?.py"))
        self.assertEqual(files, [], "? should not match multi-char names: %r" % files)

    # -------------------------------------------------------------------------
    # Exclusion
    # -------------------------------------------------------------------------

    def test_excludes_git_directory(self):
        files = self._files(self._glob("**"))
        git_files = [f for f in files if f.startswith(".git/")]
        self.assertEqual(git_files, [], ".git should be excluded: %r" % git_files)

    def test_excludes_node_modules(self):
        files = self._files(self._glob("**"))
        nm_files = [f for f in files if "node_modules" in f]
        self.assertEqual(nm_files, [], "node_modules should be excluded: %r" % nm_files)

    # -------------------------------------------------------------------------
    # Limit / truncation
    # -------------------------------------------------------------------------

    def test_limit_truncates_results(self):
        env = self._glob("**", limit=2)
        art = env["artifacts"][0]
        self.assertLessEqual(len(art["files"]), 2)
        # total_matches should be >= files returned (could be equal if ≤ 2 files)
        self.assertGreaterEqual(art["total_matches"], len(art["files"]))

    def test_limit_2_sets_truncated_when_more_exist(self):
        # We have > 2 real files in the fixture, so truncated must be True.
        art = self._art(self._glob("**", limit=2))
        self.assertTrue(art["truncated"], "truncated should be True when limit < total")

    def test_large_limit_not_truncated(self):
        art = self._art(self._glob("**", limit=1000))
        self.assertFalse(art["truncated"])

    # -------------------------------------------------------------------------
    # Results are sorted
    # -------------------------------------------------------------------------

    def test_results_are_sorted(self):
        files = self._files(self._glob("**/*.py"))
        self.assertEqual(files, sorted(files))

    # -------------------------------------------------------------------------
    # Error cases
    # -------------------------------------------------------------------------

    def test_missing_pattern_returns_error(self):
        env = router.route("glob", {"path": str(self.fixture_dir)})
        envelope.validate(env)
        self.assertEqual(env["status"], "error")

    def test_nonexistent_base_returns_error(self):
        env = router.route("glob", {
            "pattern": "**/*.py",
            "path": "/nonexistent/path/that/does/not/exist",
        })
        envelope.validate(env)
        self.assertEqual(env["status"], "error")

    # -------------------------------------------------------------------------
    # No-match case
    # -------------------------------------------------------------------------

    def test_no_match_returns_empty_files(self):
        art = self._art(self._glob("**/*.nonexistentextension"))
        self.assertEqual(art["files"], [])
        self.assertEqual(art["total_matches"], 0)
        self.assertFalse(art["truncated"])


if __name__ == "__main__":
    unittest.main()
