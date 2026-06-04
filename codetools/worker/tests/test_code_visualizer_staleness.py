"""P4.3 — dependency-staleness follow_ups + the follow_up() convention.

Covers `envelope.follow_up()` (shape + validate enforcement) and the cheap,
best-effort `_staleness_follow_ups` probe / `_staleness_aware` decorator in the
code-visualizer adapter. A fake store keeps these unit-level (no sqlite / no
vendored schema coupling).
"""

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from codetools_worker import envelope
from codetools_worker import code_visualizer as cv


class FakeStore:
    """Minimal stand-in exposing only what the probe touches."""

    def __init__(self, projects, files_by_pid):
        self._projects = projects
        self._files = files_by_pid

    def list_projects(self):
        return self._projects

    def list_files(self, pid):
        return self._files.get(pid, [])


def _iso(dt):
    return dt.isoformat()


class FollowUpConventionTest(unittest.TestCase):
    def test_shape(self):
        fu = envelope.follow_up("minerva_codetools_stale_check", "because",
                                params={"project": "p"})
        self.assertEqual(fu["tool"], "minerva_codetools_stale_check")
        self.assertEqual(fu["reason"], "because")
        self.assertEqual(fu["params"], {"project": "p"})

    def test_params_default_empty_dict(self):
        fu = envelope.follow_up("t", "r")
        self.assertEqual(fu["params"], {})

    def test_validate_accepts_well_formed_follow_up(self):
        env = envelope.ok("ok", follow_ups=[envelope.follow_up("t", "r")])
        envelope.validate(env)  # must not raise

    def test_validate_rejects_follow_up_without_tool(self):
        env = envelope.ok("ok")
        env["follow_ups"] = [{"reason": "r", "params": {}}]
        with self.assertRaises(ValueError):
            envelope.validate(env)

    def test_validate_rejects_non_dict_follow_up(self):
        env = envelope.ok("ok")
        env["follow_ups"] = ["just a string"]
        with self.assertRaises(ValueError):
            envelope.validate(env)


class StalenessProbeTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="ct_stale_")
        self.file = Path(self.d, "a.gd")
        self.file.write_text("x", encoding="utf-8")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.d, ignore_errors=True)

    def _store(self, last_indexed_at):
        return FakeStore(
            projects=[{"id": "p1", "name": "proj", "path": self.d,
                       "last_indexed_at": last_indexed_at}],
            files_by_pid={"p1": [{"relative_path": "a.gd"}]},
        )

    def test_modified_since_index_emits_follow_up(self):
        past = _iso(datetime.now(timezone.utc) - timedelta(days=1))
        fus = cv._staleness_follow_ups(self._store(past), {"db_path": "/x.db"})
        self.assertEqual(len(fus), 1)
        self.assertEqual(fus[0]["tool"], "minerva_codetools_stale_check")
        self.assertEqual(fus[0]["params"]["project"], "proj")
        self.assertEqual(fus[0]["params"]["db_path"], "/x.db")
        self.assertIn("a.gd", fus[0]["reason"])

    def test_fresh_index_emits_nothing(self):
        future = _iso(datetime.now(timezone.utc) + timedelta(days=1))
        fus = cv._staleness_follow_ups(self._store(future), {})
        self.assertEqual(fus, [])

    def test_deleted_file_emits_follow_up(self):
        self.file.unlink()
        future = _iso(datetime.now(timezone.utc) + timedelta(days=1))
        fus = cv._staleness_follow_ups(self._store(future), {})
        self.assertEqual(len(fus), 1)
        self.assertIn("deleted", fus[0]["reason"])

    def test_empty_index_timestamp_emits_follow_up(self):
        fus = cv._staleness_follow_ups(self._store(""), {})
        self.assertEqual(len(fus), 1)
        self.assertIn("index time unknown", fus[0]["reason"])

    def test_project_filter_skips_other_projects(self):
        past = _iso(datetime.now(timezone.utc) - timedelta(days=1))
        store = self._store(past)
        fus = cv._staleness_follow_ups(store, {"project": "other"})
        self.assertEqual(fus, [])

    def test_probe_never_raises_on_bad_store(self):
        class Boom:
            def list_projects(self):
                raise RuntimeError("db gone")
        self.assertEqual(cv._staleness_follow_ups(Boom(), {}), [])


class StalenessDecoratorTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="ct_stale_dec_")
        Path(self.d, "a.gd").write_text("x", encoding="utf-8")
        self.past = _iso(datetime.now(timezone.utc) - timedelta(days=1))
        self._orig_open = cv._open_store
        cv._open_store = lambda params: FakeStore(
            projects=[{"id": "p1", "name": "proj", "path": self.d,
                       "last_indexed_at": self.past}],
            files_by_pid={"p1": [{"relative_path": "a.gd"}]},
        )

    def tearDown(self):
        cv._open_store = self._orig_open
        import shutil
        shutil.rmtree(self.d, ignore_errors=True)

    def test_decorator_appends_follow_ups_on_ok(self):
        @cv._staleness_aware
        def handler(params):
            return envelope.ok("done")
        env = handler({"db_path": "/x.db"})
        self.assertEqual(len(env["follow_ups"]), 1)
        self.assertEqual(env["follow_ups"][0]["tool"], "minerva_codetools_stale_check")

    def test_opt_out_leaves_envelope_untouched(self):
        @cv._staleness_aware
        def handler(params):
            return envelope.ok("done")
        env = handler({"db_path": "/x.db", "staleness": False})
        self.assertEqual(env["follow_ups"], [])

    def test_error_envelope_not_augmented(self):
        @cv._staleness_aware
        def handler(params):
            return envelope.error("nope")
        env = handler({"db_path": "/x.db"})
        self.assertEqual(env["follow_ups"], [])


if __name__ == "__main__":
    unittest.main()
