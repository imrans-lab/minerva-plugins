"""Unit/functional tests for the P1.4 get_graph adapter.

Two fixtures exercise the SAME contract assertions (shared via
_GetGraphContractMixin):

  * GetGraphTest — full-stack, indexes a real Godot fixture with tree-sitter.
    Skips when tree-sitter is unavailable (matches the bundle runtime; a dev
    box without those wheels shouldn't fail the whole suite).

  * GetGraphStoreFixtureTest — builds the SQLite store directly via the
    store.upsert_* write API (pure stdlib, NO tree-sitter), so get_graph is
    genuinely exercised in CI on every box.  get_graph only READS the store,
    so a hand-seeded store is a faithful input.

Contract assertions (criterion 2):
  - artifact type  == "code_graph"
  - nodes:  each has {id, file, kind, fan_in, signature_hash, x, y}  (numeric x/y)
  - edges:  each has {source, target, type, confidence}
  - analysis: {dead_code_ids: list, dry_signature_groups: dict}
"""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

# envelope/router/CodeMagicStore do NOT need tree-sitter (get_graph reads the
# store only); only the indexer (index_repo) does.
from codetools_worker import envelope, router
from vendored.code_visualizer.analyzer.store import CodeMagicStore

try:
    import tree_sitter  # noqa: F401
    import tree_sitter_gdscript  # noqa: F401
    HAVE_TS = True
except ImportError:
    HAVE_TS = False

if HAVE_TS:
    from vendored.code_visualizer.analyzer.index import index_repo


FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "godot_project"

# Required node keys per contract (criterion 2).
NODE_REQUIRED_KEYS = {"id", "file", "kind", "fan_in", "signature_hash", "x", "y"}
# Required edge keys per contract.
EDGE_REQUIRED_KEYS = {"source", "target", "type", "confidence"}
# Required analysis keys per contract.
ANALYSIS_REQUIRED_KEYS = {"dead_code_ids", "dry_signature_groups"}


class _GetGraphContractMixin:
    """Contract assertions shared by every get_graph fixture.

    Subclasses must set `self.db_path` (an indexed/seeded SQLite store) in
    setUpClass and also inherit unittest.TestCase.
    """

    # ── helpers ──────────────────────────────────────────────────────────────

    def _call_get_graph(self):
        env = router.route("get_graph", {"db_path": self.db_path})
        envelope.validate(env)
        return env

    def _first_artifact(self, env):
        self.assertEqual(env["status"], "ok", "envelope: %r" % env)
        self.assertGreaterEqual(len(env["artifacts"]), 1)
        art = env["artifacts"][0]
        self.assertEqual(art["type"], "code_graph")
        return art

    # ── envelope contract ─────────────────────────────────────────────────────

    def test_status_ok(self):
        env = self._call_get_graph()
        self.assertEqual(env["status"], "ok")

    def test_single_artifact_with_correct_type(self):
        env = self._call_get_graph()
        self.assertEqual(len(env["artifacts"]), 1)
        self.assertEqual(env["artifacts"][0]["type"], "code_graph")

    # ── non-empty nodes and edges ─────────────────────────────────────────────

    def test_nodes_non_empty(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIsInstance(art["nodes"], list)
        self.assertGreater(len(art["nodes"]), 0,
                           "expected at least one node from the fixture")

    def test_edges_non_empty(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIsInstance(art["edges"], list)
        self.assertGreater(len(art["edges"]), 0,
                           "expected at least one edge from the fixture")

    # ── node field contract (criterion 2) ────────────────────────────────────

    def test_every_node_has_required_keys(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for i, node in enumerate(art["nodes"]):
            missing = NODE_REQUIRED_KEYS - set(node.keys())
            self.assertFalse(
                missing,
                "node[%d] (id=%r) is missing required keys: %s" % (
                    i, node.get("id"), missing),
            )

    def test_every_node_has_numeric_x_and_y(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for i, node in enumerate(art["nodes"]):
            self.assertIsInstance(
                node.get("x"), (int, float),
                "node[%d] x must be numeric, got %r" % (i, node.get("x")),
            )
            self.assertIsInstance(
                node.get("y"), (int, float),
                "node[%d] y must be numeric, got %r" % (i, node.get("y")),
            )

    def test_node_fan_in_is_non_negative_int(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for i, node in enumerate(art["nodes"]):
            self.assertIsInstance(node.get("fan_in"), int,
                                  "node[%d] fan_in must be int" % i)
            self.assertGreaterEqual(node["fan_in"], 0)

    def test_node_kind_is_string(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for node in art["nodes"]:
            self.assertIsInstance(node.get("kind"), str)
            self.assertTrue(node["kind"], "kind must be non-empty")

    # ── edge field contract (criterion 2) ────────────────────────────────────

    def test_every_edge_has_required_keys(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for i, edge in enumerate(art["edges"]):
            missing = EDGE_REQUIRED_KEYS - set(edge.keys())
            self.assertFalse(
                missing,
                "edge[%d] is missing required keys: %s" % (i, missing),
            )

    def test_edge_uses_source_target_not_incoming_outgoing(self):
        """The GDScript consumer uses source/target — NOT incoming/outgoing."""
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for i, edge in enumerate(art["edges"]):
            self.assertIn("source", edge,
                          "edge[%d] must have 'source', not 'incoming'" % i)
            self.assertIn("target", edge,
                          "edge[%d] must have 'target', not 'outgoing'" % i)
            self.assertNotIn("incoming", edge,
                             "edge[%d] must NOT use 'incoming'" % i)
            self.assertNotIn("outgoing", edge,
                             "edge[%d] must NOT use 'outgoing'" % i)

    def test_edge_confidence_is_numeric(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        for i, edge in enumerate(art["edges"]):
            self.assertIsInstance(edge.get("confidence"), (int, float),
                                  "edge[%d] confidence must be numeric" % i)

    # ── analysis field contract (criterion 2) ────────────────────────────────

    def test_analysis_has_required_keys(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        analysis = art.get("analysis", {})
        missing = ANALYSIS_REQUIRED_KEYS - set(analysis.keys())
        self.assertFalse(missing,
                         "analysis missing required keys: %s" % missing)

    def test_dead_code_ids_is_list(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIsInstance(art["analysis"]["dead_code_ids"], list)

    def test_dry_signature_groups_is_dict(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIsInstance(art["analysis"]["dry_signature_groups"], dict)

    # ── files and stats ───────────────────────────────────────────────────────

    def test_files_list_non_empty(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIsInstance(art["files"], list)
        self.assertGreater(len(art["files"]), 0)

    def test_stats_dict_present(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIsInstance(art["stats"], dict)
        self.assertIn("symbols", art["stats"])
        self.assertIn("edges", art["stats"])
        # project_name is surfaced so the panel titles the Level-0 splash with
        # the real project rather than the literal "Project" fallback.
        self.assertIn("project_name", art["stats"])
        self.assertIsInstance(art["stats"]["project_name"], str)
        self.assertNotEqual(art["stats"]["project_name"], "")

    # ── db_path missing → error envelope (not a crash) ───────────────────────

    def test_missing_db_path_returns_error_envelope(self):
        os.environ.pop("CODETOOLS_DB", None)
        env = router.route("get_graph", {})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "invalid_args")

    # ── layout positions spread across canvas (sanity) ────────────────────────

    def test_layout_spreads_nodes_not_all_at_origin(self):
        """All nodes at (0,0) would indicate a layout bug."""
        env = self._call_get_graph()
        art = self._first_artifact(env)
        xs = [n["x"] for n in art["nodes"]]
        ys = [n["y"] for n in art["nodes"]]
        # With ≥2 nodes the layout must produce some spread.
        if len(xs) >= 2:
            self.assertGreater(max(xs) - min(xs), 0,
                               "all nodes have the same x — layout not running")
            self.assertGreater(max(ys) - min(ys), 0,
                               "all nodes have the same y — layout not running")


@unittest.skipUnless(HAVE_TS, "tree-sitter / tree-sitter-gdscript not installed")
class GetGraphTest(_GetGraphContractMixin, unittest.TestCase):
    """Full-stack get_graph tests — real fixture, real SQLite store."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="codetools_getgraph_")
        cls.db_path = os.path.join(cls._tmp, "code_visualizer.db")
        index_repo(FIXTURE_DIR, Path(cls.db_path), "fixture")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)


class GetGraphStoreFixtureTest(_GetGraphContractMixin, unittest.TestCase):
    """get_graph against a hand-seeded store — NO tree-sitter, runs everywhere.

    Seeds via the store.upsert_* write API (pure stdlib). get_graph only reads
    the store, so this is a faithful input that exercises the full adapter +
    layout + analysis path on any box, including CI without the grammar wheels.
    """

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="codetools_getgraph_seed_")
        cls.db_path = os.path.join(cls._tmp, "code_visualizer.db")
        store = CodeMagicStore(cls.db_path)
        try:
            pid = store.upsert_project("fixture", "/tmp/fixture",
                                       language="gdscript")
            fid_a = store.upsert_file(pid, "a.gd", line_count=50)
            fid_b = store.upsert_file(pid, "b.gd", line_count=30)

            # main: entry point, no incoming edge (alive via is_entry_point).
            s_main = store.upsert_symbol(
                fid_a, "main", "function", signature="func main() -> void",
                line_start=1, line_end=10, is_entry_point=True,
                signature_hash="hash_main")
            # helper + util share a signature_hash → a DRY group.
            s_helper = store.upsert_symbol(
                fid_a, "helper", "function", signature="func helper(x: int)",
                line_start=12, line_end=20, signature_hash="hash_dup")
            s_util = store.upsert_symbol(
                fid_b, "util", "function", signature="func util(y: int)",
                line_start=1, line_end=8, signature_hash="hash_dup")
            # unused: no incoming edge and not an entry point → dead-code candidate.
            store.upsert_symbol(
                fid_b, "unused", "function", signature="func unused() -> void",
                line_start=10, line_end=15, signature_hash="hash_dead")
            # a class symbol, to vary node kinds.
            store.upsert_symbol(
                fid_a, "Thing", "class", signature="class Thing",
                line_start=22, line_end=40, signature_hash="hash_thing")

            # edges: main→helper, main→util, helper→util (util fan_in=2).
            store.upsert_edge(s_main, s_helper, "calls", confidence=1.0)
            store.upsert_edge(s_main, s_util, "calls", confidence=0.9)
            store.upsert_edge(s_helper, s_util, "calls", confidence=0.8)
        finally:
            store.close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)

    # Extra assertions that a hand-seeded fixture can make precisely.

    def test_seeded_node_and_edge_counts(self):
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertEqual(len(art["nodes"]), 5)
        self.assertEqual(len(art["edges"]), 3)

    def test_seeded_dry_group_detected(self):
        """helper + util share signature_hash 'hash_dup' → a DRY group exists."""
        env = self._call_get_graph()
        art = self._first_artifact(env)
        self.assertIn("hash_dup", art["analysis"]["dry_signature_groups"])


if __name__ == "__main__":
    unittest.main()
