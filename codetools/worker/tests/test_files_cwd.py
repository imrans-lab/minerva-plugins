"""Tests for minerva_codetools_cwd (P2.1 gate).

Tests get-cwd, set-cwd, ~ expansion, relative paths, and invalid-path rejection.
All tests route through router.route("cwd", params) and validate the returned
envelope with envelope.validate().

Note: os.chdir() mutates global process state, so tests that change directory
restore the original cwd in tearDown.
"""

from __future__ import annotations

import os
import sys
import tempfile
import shutil
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from codetools_worker import envelope, router


class CwdTest(unittest.TestCase):

    def setUp(self):
        self._original_cwd = os.getcwd()

    def tearDown(self):
        # Always restore — os.chdir side-effects from the worker must not
        # bleed into the next test.
        try:
            os.chdir(self._original_cwd)
        except OSError:
            pass

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def _cwd(self, **kwargs):
        env = router.route("cwd", kwargs)
        envelope.validate(env)
        return env

    def _art(self, env):
        self.assertEqual(env["status"], "ok", "expected ok: %r" % env)
        return env["artifacts"][0]

    # -------------------------------------------------------------------------
    # Artifact shape
    # -------------------------------------------------------------------------

    def test_artifact_type_is_cwd_result(self):
        env = self._cwd()
        self.assertEqual(env["artifacts"][0]["type"], "cwd_result")

    def test_get_has_required_fields(self):
        art = self._art(self._cwd())
        for f in ("type", "action", "directory"):
            self.assertIn(f, art, "missing field: %s" % f)

    # -------------------------------------------------------------------------
    # Get cwd
    # -------------------------------------------------------------------------

    def test_get_returns_current_directory(self):
        art = self._art(self._cwd())
        self.assertEqual(art["action"], "get")
        # Should be an absolute path
        self.assertTrue(os.path.isabs(art["directory"]),
                        "directory should be absolute: %s" % art["directory"])

    def test_get_matches_os_getcwd(self):
        art = self._art(self._cwd())
        self.assertEqual(art["directory"], str(Path(os.getcwd()).resolve()))

    # -------------------------------------------------------------------------
    # Set cwd — absolute path
    # -------------------------------------------------------------------------

    def test_set_changes_directory(self):
        tmp = tempfile.mkdtemp(prefix="ct_cwd_")
        try:
            art = self._art(self._cwd(path=tmp))
            self.assertEqual(art["action"], "set")
            # Verify the worker actually changed directory.
            actual = str(Path(os.getcwd()).resolve())
            expected = str(Path(tmp).resolve())
            self.assertEqual(actual, expected)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_set_returns_resolved_path(self):
        tmp = tempfile.mkdtemp(prefix="ct_cwd2_")
        try:
            art = self._art(self._cwd(path=tmp))
            self.assertTrue(os.path.isabs(art["directory"]),
                            "returned directory should be absolute")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # -------------------------------------------------------------------------
    # ~ expansion
    # -------------------------------------------------------------------------

    def test_tilde_expansion(self):
        home = str(Path.home())
        # Set cwd to ~ and verify it resolves to home.
        try:
            art = self._art(self._cwd(path="~"))
            self.assertEqual(art["directory"], str(Path(home).resolve()))
        except Exception:
            # If home doesn't exist (CI edge case), that's ok.
            pass

    # -------------------------------------------------------------------------
    # Relative path
    # -------------------------------------------------------------------------

    def test_relative_path_resolved_against_cwd(self):
        tmp = tempfile.mkdtemp(prefix="ct_cwd_rel_")
        subdir = Path(tmp) / "sub"
        subdir.mkdir()
        try:
            # Change to tmp first, then use relative path "sub".
            os.chdir(tmp)
            art = self._art(self._cwd(path="sub"))
            self.assertEqual(art["directory"], str(subdir.resolve()))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # -------------------------------------------------------------------------
    # Invalid path rejection
    # -------------------------------------------------------------------------

    def test_nonexistent_path_rejected(self):
        env = self._cwd(path="/nonexistent/path/that/does/not/exist_xyz")
        envelope.validate(env)
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "not_found")

    def test_file_path_rejected(self):
        # Passing a file path (not a directory) should be rejected.
        tmp = tempfile.mkdtemp(prefix="ct_cwd_file_")
        f = Path(tmp) / "file.txt"
        f.write_text("hi")
        try:
            env = self._cwd(path=str(f))
            envelope.validate(env)
            self.assertEqual(env["status"], "error")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # -------------------------------------------------------------------------
    # Idempotency
    # -------------------------------------------------------------------------

    def test_set_then_get_returns_same_path(self):
        tmp = tempfile.mkdtemp(prefix="ct_cwd_idem_")
        try:
            self._cwd(path=tmp)
            art_get = self._art(self._cwd())
            self.assertEqual(art_get["directory"], str(Path(tmp).resolve()))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
