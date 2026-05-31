"""Functional tests for the code-visualizer adapter (P1.3 Gate A).

No stubs anywhere: indexes the REAL fixture Godot project at
tests/fixtures/godot_project/ into a REAL temporary SQLite store, then exercises
each of the 9 routed minerva_codetools_* tools through the worker router and
asserts envelope shape + typed-artifact contracts + content correctness.

SKIPs the whole module if tree-sitter or tree-sitter-gdscript is unavailable
(matches the bundle's runtime — those wheels ship in the embedded bundle, but a
dev box without them shouldn't fail). The Gate-A signal is that this file runs
GREEN when the deps ARE available.
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
    # Imported lazily so a missing-dep environment can still load this module
    # and emit the skipTest message cleanly.
    from codetools_worker import envelope, router
    from vendored.code_visualizer.analyzer.index import index_repo


FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "godot_project"


@unittest.skipUnless(HAVE_TS, "tree-sitter / tree-sitter-gdscript not installed")
class CodeVisualizerFunctionalTest(unittest.TestCase):
    """Real fixture + real SQLite + every routed tool — no stubs."""

    @classmethod
    def setUpClass(cls):
        # One temp dir holds the SQLite store for the whole class so we index
        # the fixture exactly once (fast — three .gd files).
        cls._tmp = tempfile.mkdtemp(prefix="codetools_funcs_")
        cls.db_path = os.path.join(cls._tmp, "code_visualizer.db")
        # Index the real fixture into the real SQLite store.
        index_repo(FIXTURE_DIR, Path(cls.db_path), "fixture")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)

    # ----- helpers --------------------------------------------------------

    def _call(self, method, **params):
        params["db_path"] = self.db_path
        env = router.route(method, params)
        envelope.validate(env)
        return env

    def _first_artifact(self, env, expected_type):
        self.assertEqual(env["status"], "ok", "envelope: %r" % env)
        self.assertGreaterEqual(len(env["artifacts"]), 1, "no artifacts")
        art = env["artifacts"][0]
        self.assertEqual(art["type"], expected_type)
        return art

    # ----- index sanity ---------------------------------------------------

    def test_index_populated_the_store(self):
        # Cheap sanity: analyze:stats says we indexed something real.
        env = self._call("analyze", analysis="stats")
        art = self._first_artifact(env, "analysis")
        self.assertEqual(art["analysis"], "stats")
        # 3 .gd files, each with >= 1 class + method. Symbols should be ≥ ~10.
        self.assertGreaterEqual(art.get("files", 0), 3)
        self.assertGreaterEqual(art.get("symbols", 0), 10)

    # ----- tool 1: query --------------------------------------------------

    def test_query_finds_a_known_symbol_by_name(self):
        env = self._call("query", query="take_damage", scope="symbols")
        art = self._first_artifact(env, "query_results")
        self.assertEqual(art["query"], "take_damage")
        self.assertEqual(art["scope"], "symbols")
        self.assertGreaterEqual(art["count"], 1)
        names = [r.get("name") for r in art["results"]]
        self.assertIn("take_damage", names)

    def test_query_invalid_args_returns_error_envelope(self):
        env = router.route("query", {"db_path": self.db_path, "query": ""})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")

    # ----- tool 2: get_context -------------------------------------------

    def test_get_context_by_symbol_name(self):
        env = self._call("get_context", identifier="take_damage")
        art = self._first_artifact(env, "code_context")
        self.assertEqual(art["kind"], "symbol")
        self.assertEqual(art["symbol"]["name"], "take_damage")
        self.assertEqual(art["symbol"]["kind"], "function")

    def test_get_context_by_file_path(self):
        env = self._call("get_context", identifier="player.gd")
        art = self._first_artifact(env, "code_context")
        self.assertEqual(art["kind"], "file")
        self.assertEqual(art["file"]["path"], "player.gd")
        sym_names = [s["name"] for s in art["symbols"]]
        self.assertIn("take_damage", sym_names)
        self.assertIn("Player", sym_names)

    def test_get_context_unknown_identifier_returns_error_envelope(self):
        env = router.route("get_context",
                           {"db_path": self.db_path, "identifier": "nope_xyz"})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "not_found")

    # ----- tool 3: stale_check -------------------------------------------

    def test_stale_check_runs_with_no_git_treats_missing_hash_gracefully(self):
        # Fixture isn't a git repo — stale_check should still produce an
        # envelope. Files may show as unknown/modified; what matters is the
        # call succeeds and emits the typed artifact.
        env = self._call("stale_check")
        art = self._first_artifact(env, "stale_check")
        self.assertIn("stale_count", art)
        self.assertIsInstance(art["files"], list)

    # ----- tool 4: get_diff ----------------------------------------------

    def test_get_diff_against_git_repo(self):
        # Build a tiny throwaway git repo so the diff actually has structure.
        repo = tempfile.mkdtemp(prefix="codetools_diff_")
        try:
            subprocess.run(["git", "init", "-q", "-b", "main", repo],
                           check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "config", "user.email", "t@t"],
                           check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "config", "user.name", "test"],
                           check=True, capture_output=True)
            f = Path(repo) / "a.gd"
            f.write_text("class_name A\nfunc one():\n\tpass\n")
            subprocess.run(["git", "-C", repo, "add", "a.gd"], check=True,
                           capture_output=True)
            subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "init"],
                           check=True, capture_output=True)
            f.write_text("class_name A\nfunc one():\n\tpass\nfunc two():\n\tpass\n")
            env = self._call("get_diff", repo_path=repo, base="HEAD")
            art = self._first_artifact(env, "diff")
            self.assertEqual(art["base"], "HEAD")
            self.assertEqual(art["head"], "working tree")
            paths = [f["path"] for f in art["files"]]
            self.assertIn("a.gd", paths)
        finally:
            shutil.rmtree(repo, ignore_errors=True)

    # ----- tool 5: analyze (4 sub-kinds) ---------------------------------

    def test_analyze_dead_code_surfaces_unreferenced_classes(self):
        env = self._call("analyze", analysis="dead_code")
        art = self._first_artifact(env, "analysis")
        self.assertEqual(art["analysis"], "dead_code")
        # Methods always have an incoming class-contains-member edge from
        # Phase 1c, so the indexer never flags them as dead. The dead-code set
        # is the top-level CLASSES that nothing else references by name — in
        # this fixture, all 3 (Enemy, GameManager, Player).
        flat_names = [s["name"]
                      for syms in art["by_file"].values() for s in syms]
        self.assertIn("Player", flat_names)
        self.assertIn("Enemy", flat_names)
        self.assertIn("GameManager", flat_names)
        # Total candidates should equal the file count for a closed fixture.
        self.assertEqual(art["total_candidates"], 3)

    def test_analyze_dry_candidates(self):
        env = self._call("analyze", analysis="dry_candidates")
        art = self._first_artifact(env, "analysis")
        self.assertEqual(art["analysis"], "dry_candidates")
        # The two unused_* helpers share signature shape (no params, void return).
        # Whether they group depends on the signature hash implementation, but
        # the call must succeed and return the right shape.
        self.assertIsInstance(art["groups"], list)

    def test_analyze_coupling_hotspots(self):
        env = self._call("analyze", analysis="coupling_hotspots")
        art = self._first_artifact(env, "analysis")
        self.assertEqual(art["analysis"], "coupling_hotspots")
        self.assertIsInstance(art["hotspots"], list)

    def test_analyze_invalid_kind_returns_error_envelope(self):
        env = router.route("analyze", {"db_path": self.db_path, "analysis": "nope"})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")

    # ----- tool 6: set_description ---------------------------------------

    def test_set_description_on_known_symbol(self):
        ctx = self._call("get_context", identifier="take_damage")
        sym_id = self._first_artifact(ctx, "code_context")["symbol"]["id"]
        env = self._call("set_description", id=sym_id,
                         description="Subtracts damage from current_health.")
        art = self._first_artifact(env, "description_set")
        self.assertEqual(art["entity_type"], "symbol")
        self.assertEqual(art["name"], "take_damage")

    def test_set_description_unknown_id_returns_error_envelope(self):
        env = router.route("set_description",
                           {"db_path": self.db_path, "id": "not-a-real-id",
                            "description": "x", "entity_type": "symbol"})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "not_found")

    # ----- tool 7: describe_symbol ---------------------------------------

    def test_describe_symbol_with_tags(self):
        ctx = self._call("get_context", identifier="heal")
        sym_id = self._first_artifact(ctx, "code_context")["symbol"]["id"]
        env = self._call("describe_symbol", id=sym_id,
                         description="Restores health up to max.",
                         tags="mutates_state,health")
        art = self._first_artifact(env, "symbol_described")
        self.assertEqual(art["name"], "heal")
        self.assertEqual(sorted(art["tags_added"]), ["health", "mutates_state"])

    # ----- tool 8: set_tags ----------------------------------------------

    def test_set_tags_on_symbol(self):
        ctx = self._call("get_context", identifier="is_alive")
        sym_id = self._first_artifact(ctx, "code_context")["symbol"]["id"]
        env = self._call("set_tags", id=sym_id, tags="pure,query",
                         entity_type="symbol")
        art = self._first_artifact(env, "tags_set")
        self.assertEqual(art["entity_type"], "symbol")
        self.assertEqual(sorted(art["tags_added"]), ["pure", "query"])

    # ----- tool 9: undescribed -------------------------------------------

    def test_undescribed_lists_items(self):
        env = self._call("undescribed", entity_type="symbol", limit=5)
        art = self._first_artifact(env, "undescribed_items")
        self.assertEqual(art["entity_type"], "symbol")
        self.assertLessEqual(len(art["items"]), 5)

    def test_undescribed_invalid_limit_returns_error_envelope(self):
        env = router.route("undescribed",
                           {"db_path": self.db_path, "entity_type": "symbol",
                            "limit": 0})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")

    # ----- envelope contract enforced across all tools -------------------

    def test_db_path_unset_returns_error_envelope(self):
        # Probe every adapter: missing db_path AND missing env should fail
        # uniformly with an invalid_args error envelope.
        os.environ.pop("CODETOOLS_DB", None)
        method_args = [
            ("query", {"query": "x"}),
            ("get_context", {"identifier": "x"}),
            ("stale_check", {}),
            ("get_diff", {}),
            ("analyze", {"analysis": "stats"}),
            ("set_description", {"id": "x", "description": "x"}),
            ("describe_symbol", {"id": "x", "description": "x"}),
            ("set_tags", {"id": "x", "tags": "x"}),
            ("undescribed", {}),
        ]
        for method, args in method_args:
            with self.subTest(method=method):
                env = router.route(method, args)
                self.assertEqual(env["status"], "error",
                                 "%s: expected error, got %r" % (method, env))
                self.assertEqual(env["error"]["kind"], "invalid_args",
                                 "%s: expected invalid_args" % method)


if __name__ == "__main__":
    unittest.main()
