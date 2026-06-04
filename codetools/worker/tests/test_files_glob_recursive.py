"""Regression: `**/` must match top-level files too (found via live HITL).

P2.1's `_glob_to_regex` compiled `**/` to `.*(/|$)`, which could not match a
path with no slash, so `**/*.gd` silently missed files directly under the base
directory. This test pins the corrected `(?:.*/)?` behavior.
"""

import shutil
import tempfile
import unittest
from pathlib import Path

from codetools_worker import envelope
from codetools_worker.files.glob_handler import handle_glob, _glob_to_regex


class GlobRecursiveTopLevelTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="ct_glob_rec_")
        Path(self.d, "top.gd").write_text("x", encoding="utf-8")
        sub = Path(self.d, "sub")
        sub.mkdir()
        (sub / "nested.gd").write_text("x", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def _files(self, pattern):
        env = handle_glob({"pattern": pattern, "path": self.d})
        envelope.validate(env)
        return env["artifacts"][0]["files"]

    def test_double_star_matches_top_level_and_nested(self):
        files = self._files("**/*.gd")
        self.assertIn("top.gd", files, "**/*.gd must match a TOP-LEVEL file")
        self.assertIn("sub/nested.gd", files, "**/*.gd must match a nested file")

    def test_regex_unit(self):
        rx = _glob_to_regex("**/*.gd")
        self.assertTrue(rx.search("top.gd"))       # the regression case
        self.assertTrue(rx.search("a/b/c.gd"))     # nested still works
        self.assertFalse(rx.search("top.py"))      # wrong extension excluded

    def test_single_star_stays_top_level_only(self):
        # `*.gd` (no `**`) is top-level only — unchanged.
        files = self._files("*.gd")
        self.assertIn("top.gd", files)
        self.assertNotIn("sub/nested.gd", files)


if __name__ == "__main__":
    unittest.main()
