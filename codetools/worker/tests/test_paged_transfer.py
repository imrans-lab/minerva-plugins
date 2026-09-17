"""Paged transfer for callers bounded by the host's control-lane cap.

An HTML panel reaches this plugin over a bridge bounded at 65,536 UTF-8 bytes
each way with no bulk route, so a graph bigger than that must arrive in parts.

Oracle: a store seeded so that `get_graph`'s envelope MEASURES over the cap
round-trips through the paged shape — every part fits the budget the caller
asked for, and the reassembled text parses back to the unpaged envelope (hence
identical symbol and edge counts) apart from the layout positions, which move
between calls because the layout RNG advances. The seeded store is a faithful
input because get_graph only reads it.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from codetools_worker import envelope, paging, router
from vendored.code_visualizer.analyzer.store import CodeMagicStore

# The host's webview bound, in UTF-8 bytes, in both directions.
CONTROL_BYTES = 65536
# What the panel asks for: under the cap, leaving room for the host's wrapper.
PANEL_BUDGET = 48 * 1024

SYMBOL_COUNT = 40
EDGE_COUNT = 39
# Long enough that 40 symbols alone carry the envelope over the cap.
DESCRIPTION = "a symbol description that is deliberately long. " * 45


def _bytes(obj) -> int:
    return len(json.dumps(obj).encode("utf-8"))


def _wire_bytes(part_envelope) -> int:
    """What the host measures for one part.

    The envelope is marshalled by the plugin, nested as MCP text content, and
    re-serialized by the host — so it is escaped a second time on the way out.
    Modelled here independently of paging.py so the test keeps its own oracle.
    """
    text = '{"ok":true,"result":' + json.dumps(part_envelope) + "}"
    reply = {"success": True, "result": {"content": [{"type": "text",
                                                      "text": text}]},
             "id": "x" * 36}
    return _bytes(reply)


def _without_positions(env):
    """Drop layout x/y: the layout RNG advances per call, so two get_graph
    calls place the same graph differently. Everything else must match."""
    env = copy.deepcopy(env)
    for node in env["artifacts"][0]["nodes"]:
        node.pop("x", None)
        node.pop("y", None)
    return env


class PagedTransferTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="codetools_paging_")
        cls.db_path = str(Path(cls._tmp) / "code_visualizer.db")
        store = CodeMagicStore(cls.db_path)
        try:
            pid = store.upsert_project("fixture", "/tmp/fixture",
                                       language="gdscript")
            fid = store.upsert_file(pid, "big.gd", line_count=SYMBOL_COUNT * 10)
            ids = [
                store.upsert_symbol(
                    fid, "sym_%03d" % i, "function",
                    signature="func sym_%03d(x: int) -> void" % i,
                    line_start=i * 10, line_end=i * 10 + 8,
                    description=DESCRIPTION,
                    is_entry_point=(i == 0),
                    signature_hash="hash_%03d" % i)
                for i in range(SYMBOL_COUNT)
            ]
            for i in range(EDGE_COUNT):
                store.upsert_edge(ids[i], ids[i + 1], "calls", confidence=1.0)
        finally:
            store.close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)

    def _unpaged(self):
        env = router.route("get_graph", {"db_path": self.db_path})
        envelope.validate(env)
        self.assertEqual(env["status"], "ok", env)
        return env

    def test_graph_over_the_cap_round_trips_through_paging(self):
        unpaged = self._unpaged()
        size = _bytes(unpaged)
        self.assertGreater(
            size, CONTROL_BYTES,
            "fixture is only %d bytes — it no longer exercises the cap" % size)
        art = unpaged["artifacts"][0]
        self.assertEqual(len(art["nodes"]), SYMBOL_COUNT)
        self.assertEqual(len(art["edges"]), EDGE_COUNT)

        first = router.route("get_graph",
                             {"db_path": self.db_path,
                              "page": {"max_bytes": PANEL_BUDGET}})
        envelope.validate(first)
        head = first["artifacts"][0]
        self.assertEqual(head["type"], paging.ARTIFACT_TYPE)
        self.assertGreater(head["parts"], 1,
                           "an over-cap graph must need more than one part")
        text = head["chunk"]
        sizes = [_wire_bytes(first)]
        for part in range(1, head["parts"]):
            reply = router.route("get_graph",
                                 {"db_path": self.db_path,
                                  "page": {"token": head["token"],
                                           "part": part}})
            envelope.validate(reply)
            piece = reply["artifacts"][0]
            self.assertEqual(piece["part"], part)
            self.assertEqual(piece["parts"], head["parts"])
            text += piece["chunk"]
            sizes.append(_wire_bytes(reply))

        self.assertLessEqual(
            max(sizes), PANEL_BUDGET,
            "a part reaches the host as %d bytes, over the %d-byte budget the "
            "caller asked for" % (max(sizes), PANEL_BUDGET))

        self.assertEqual(head["total_bytes"], len(text.encode("utf-8")),
                         "declared transfer size does not match what arrived")

        reassembled = json.loads(text)
        self.assertEqual(_without_positions(reassembled),
                         _without_positions(unpaged),
                         "the reassembled envelope differs from the unpaged one")
        rebuilt = reassembled["artifacts"][0]
        self.assertEqual(len(rebuilt["nodes"]), len(art["nodes"]))
        self.assertEqual(len(rebuilt["edges"]), len(art["edges"]))
        for node in rebuilt["nodes"]:
            self.assertIsInstance(node["x"], (int, float))
            self.assertIsInstance(node["y"], (int, float))

    def test_unpaged_callers_see_the_unchanged_reply(self):
        """Agents over stdio never pass `page` and must see the old shape."""
        art = self._unpaged()["artifacts"][0]
        self.assertEqual(art["type"], "code_graph")
        self.assertNotIn("chunk", art)

    def test_a_lost_transfer_fails_loudly(self):
        """A stale token must error, never hand back a truncated document."""
        env = router.route("get_graph",
                           {"db_path": self.db_path,
                            "page": {"token": "0" * 32, "part": 1}})
        self.assertEqual(env["status"], "error")
        self.assertEqual(env["error"]["kind"], "paging_expired")

        first = router.route("get_graph",
                             {"db_path": self.db_path,
                              "page": {"max_bytes": PANEL_BUDGET}})
        token = first["artifacts"][0]["token"]
        beyond = router.route("get_graph",
                              {"db_path": self.db_path,
                               "page": {"token": token, "part": 10_000}})
        self.assertEqual(beyond["status"], "error")
        self.assertEqual(beyond["error"]["kind"], "invalid_args")

    def test_handler_errors_are_not_paged(self):
        """A failure is small and must arrive as itself, not as part 0."""
        os.environ.pop("CODETOOLS_DB", None)
        env = router.route("get_graph", {"page": {"max_bytes": PANEL_BUDGET}})
        self.assertEqual(env["status"], "error")
        self.assertNotEqual(
            env["artifacts"] and env["artifacts"][0].get("type"),
            paging.ARTIFACT_TYPE)


if __name__ == "__main__":
    unittest.main()
