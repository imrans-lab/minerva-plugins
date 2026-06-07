"""Integration tests for git-scoped get_diff + content-hash stale_check.

Covers two bugs found while validating diff-visualization on a project that is
a SUB-DIRECTORY of a larger git repo (the common real-world case):

  * 019e9aa059… get_diff must be project-scoped: it returned the WHOLE repo's
    changes with repo-root-relative paths that don't match the store's
    project-relative file paths. Fix: `git diff --relative` run from repo_path.

  * 019e9aa093… stale_check must detect UNCOMMITTED working-tree edits, not just
    new commits. Fix: index + stale_check both hash working-tree content via
    `git hash-object` instead of the last-commit hash (`git log -1`).

No stubs: builds a REAL temp git repo with a project subdir + an unrelated file
at the repo root, indexes the subdir into a REAL SQLite store, and drives the
real worker functions. SKIPs without tree-sitter / tree-sitter-gdscript or git.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    import tree_sitter  # noqa: F401
    import tree_sitter_gdscript  # noqa: F401
    HAVE_TS = True
except ImportError:
    HAVE_TS = False

if HAVE_TS:
    from codetools_worker import code_visualizer as cv, envelope
    from vendored.code_visualizer.analyzer.index import index_repo


def _have_git() -> bool:
    try:
        subprocess.run(["git", "--version"], capture_output=True, timeout=5)
        return True
    except Exception:
        return False


_MAIN_GD = """extends Node

var _count := 0

func foo() -> void:
	bar()

func bar() -> void:
	_count += 1
"""


@unittest.skipUnless(HAVE_TS, "tree-sitter / tree-sitter-gdscript not installed")
@unittest.skipUnless(_have_git(), "git not available")
class GitScopeTest(unittest.TestCase):
    """Project = a subdir of a larger git repo, with unrelated repo-root files."""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="codetools_gitscope_")
        self.root = Path(self._tmp)
        self.proj = self.root / "experiments" / "proj"
        (self.proj / "scripts").mkdir(parents=True)
        self.main_gd = self.proj / "scripts" / "main.gd"
        self.main_gd.write_text(_MAIN_GD, encoding="utf-8")
        # An UNRELATED file elsewhere in the same repo — must never leak into a
        # project-scoped diff.
        self.unrelated = self.root / "notes" / "other.txt"
        self.unrelated.parent.mkdir(parents=True)
        self.unrelated.write_text("unrelated\n", encoding="utf-8")

        self._git("init", "-q")
        self._git("config", "user.email", "t@t")
        self._git("config", "user.name", "t")
        self._git("add", "-A")
        self._git("commit", "-qm", "baseline")

        self.db_path = str(self.root / "cg.db")
        index_repo(self.proj, Path(self.db_path), "proj")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args],
                       capture_output=True, text=True, check=True, timeout=15)

    def _diff(self, **params):
        params["db_path"] = self.db_path
        env = cv.get_diff(params)
        envelope.validate(env)
        return env["artifacts"][0]["files"]

    def _stale(self):
        env = cv.stale_check({"db_path": self.db_path})
        envelope.validate(env)
        return env["artifacts"][0]

    # ----- G1: get_diff is project-scoped --------------------------------

    def test_get_diff_clean_tree_is_empty(self):
        self.assertEqual(self._diff(), [])

    def test_get_diff_scopes_to_project_and_uses_relative_paths(self):
        # Edit a file IN the project AND an unrelated file elsewhere in the repo.
        self.main_gd.write_text(_MAIN_GD + "\nfunc baz() -> void:\n\tpass\n",
                                encoding="utf-8")
        self.unrelated.write_text("changed\n", encoding="utf-8")

        files = self._diff()
        paths = [f["path"] for f in files]
        # Exactly the project file, project-relative — NOT repo-root-relative,
        # and the unrelated repo file must NOT appear.
        self.assertEqual(paths, ["scripts/main.gd"])
        self.assertNotIn("notes/other.txt", paths)
        self.assertNotIn("experiments/proj/scripts/main.gd", paths)

    def test_get_diff_returns_before_and_after_content(self):
        self.main_gd.write_text(_MAIN_GD + "\nfunc baz() -> void:\n\tpass\n",
                                encoding="utf-8")
        f = self._diff()[0]
        self.assertEqual(f["status"], "modified")
        self.assertIn("func bar", f["before_content"])
        self.assertNotIn("func baz", f["before_content"])
        self.assertIn("func baz", f["after_content"])
        # P5a single-diff-source: unified_diff + adds/dels accompany the content
        # (panel reads these instead of computing diffs client-side).
        self.assertIn("@@", f["unified_diff"])
        self.assertIn("+func baz", f["unified_diff"])
        self.assertGreaterEqual(f["adds"], 2)
        self.assertEqual(f["dels"], 0)

    def test_get_diff_file_filter_is_project_relative(self):
        self.main_gd.write_text(_MAIN_GD + "\n# touched\n", encoding="utf-8")
        files = self._diff(file="scripts/main.gd")
        self.assertEqual([f["path"] for f in files], ["scripts/main.gd"])

    # ----- G5: stale_check sees uncommitted edits ------------------------

    def test_stale_check_clean_after_index(self):
        art = self._stale()
        self.assertEqual(art["stale_count"], 0, art)

    def test_stale_check_flags_uncommitted_edit(self):
        self.main_gd.write_text(_MAIN_GD + "\n# uncommitted\n", encoding="utf-8")
        art = self._stale()
        self.assertEqual(art["stale_count"], 1, art)
        entry = art["files"][0]
        self.assertEqual(entry["file"], "scripts/main.gd")
        self.assertEqual(entry["status"], "modified")
        self.assertNotEqual(entry["indexed_hash"], entry["current_hash"])

    def test_stale_check_flags_deleted_file(self):
        self.main_gd.unlink()
        art = self._stale()
        self.assertEqual(art["stale_count"], 1, art)
        self.assertEqual(art["files"][0]["status"], "deleted")


@unittest.skipUnless(HAVE_TS, "tree-sitter / tree-sitter-gdscript not installed")
@unittest.skipUnless(_have_git(), "git not available")
class WholeRepoScopeTest(unittest.TestCase):
    """Project == git root (case 1): paths already root==project-relative."""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="codetools_wholerepo_")
        self.root = Path(self._tmp)
        (self.root / "scripts").mkdir(parents=True)
        self.main_gd = self.root / "scripts" / "main.gd"
        self.main_gd.write_text(_MAIN_GD, encoding="utf-8")
        for a in (["init", "-q"], ["config", "user.email", "t@t"],
                  ["config", "user.name", "t"], ["add", "-A"],
                  ["commit", "-qm", "baseline"]):
            subprocess.run(["git", "-C", str(self.root), *a],
                           capture_output=True, text=True, check=True, timeout=15)
        self.db_path = str(self.root / "cg.db")
        index_repo(self.root, Path(self.db_path), "proj")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_get_diff_root_project_unchanged_behavior(self):
        self.main_gd.write_text(_MAIN_GD + "\n# x\n", encoding="utf-8")
        env = cv.get_diff({"db_path": self.db_path})
        envelope.validate(env)
        paths = [f["path"] for f in env["artifacts"][0]["files"]]
        self.assertEqual(paths, ["scripts/main.gd"])


if __name__ == "__main__":
    unittest.main()
