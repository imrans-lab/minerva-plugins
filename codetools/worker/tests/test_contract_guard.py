"""codetools' CONTRACT GUARD — six domain-defined cases through the real router.

WHY THIS SUITE EXISTS

codetools' panel is an HTML page on the host's webview bridge, which is bounded
at 65,536 UTF-8 bytes each way and has NO bulk route. A code graph of any real
project is an order of magnitude past that, so the whole surface rests on the
paging protocol: the answer arrives in parts and the caller reassembles it.

test_paged_transfer.py pins that protocol for one clean graph. This guard
weighs the plugin at BOTH sizes and in both moods, because the failures cluster
where those axes cross — the document that carries the graph is the big one,
and the FINDINGS about a graph grow with it too, along a different axis the
happy path never touches.

  1. null / empty document   — an empty store answers an explicit empty graph,
                               not an error and not an absence
  2. small happy             — three symbols, unpaged, in the shape an agent
                               over stdio still sees
  3. small unhappy           — a malformed call is refused `invalid_args`, and
                               the store is exactly as it was
  4. large happy             — 120 symbols: a third of a megabyte of graph
                               delivered in parts that each fit the caller's
                               budget, and reassembled identically
  5. large unhappy           — the same transfer with its token lost: refused
                               `paging_expired`, never a truncated document
  6. large-with-errors reply — the same 120 symbols with every one of them dead
                               and every signature duplicated: the FINDINGS
                               block is 2,461 bytes against 49 for the clean
                               graph of the same size, and it still pages

codetools' own definitions of LARGE are SYMBOL COUNT and EDGE COUNT. Measured
against the real router and a real store, 400 symbols with 399 edges weigh
1,031,190 bytes unpaged — 15.7x the bridge's cap — and the analysis block of
the same 400 with no edges and one shared signature hash is 8,061 bytes against
49 for the clean graph. The fixture here is 120 symbols, which still clears the
cap several times over — 309,630 bytes in 13 parts, findings 2,461 bytes against
49 — at a fraction of the layout cost: the whole guard runs in 14 seconds, and a
guard has to be cheap enough to run on every host change. The whole envelope is a poor comparison for case 6
(the clean graph carries the edges the dead one cannot have), so it weighs THE
FINDINGS PAYLOAD, which is the part that is about to be wrong.

NOTHING IS MOCKED: the real router, the real store, the real paging cache, the
real envelope validator. The store is seeded rather than analysed from source
because get_graph only reads it — a seeded store is a faithful input, and it is
the same fixture idiom test_paged_transfer.py uses.

ORACLE: drop paging from get_graph (return the unpaged envelope when `page` is
asked for) and cases 4 and 6 go red — a part then reaches the host over the
budget the caller asked for. Break the lost-token refusal into a truncated
success and case 5 goes red. Cases 1, 2 and 3 stay green: they are small
enough that paging never engages.
"""

from __future__ import annotations

import copy
import json
import os
import pathlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "scripts"))

from contract_guard import ContractGuard, bytes_of  # noqa: E402

from codetools_worker import envelope, router  # noqa: E402
from vendored.code_visualizer.analyzer.store import CodeMagicStore  # noqa: E402

#: The host's webview bound, in UTF-8 bytes, in both directions. There is no
#: bulk route on this bridge: paging is the only way past it.
CONTROL_BYTES = 65536
#: What the panel asks for — under the cap, leaving room for the host's wrapper.
PANEL_BUDGET = 48 * 1024

#: codetools' unit of large, and the count both large moods share.
LARGE_SYMBOLS = 120
SMALL_SYMBOLS = 3
#: Long enough that a few hundred symbols carry the graph far past the cap.
DESCRIPTION = "a symbol description that is deliberately long. " * 45


def _wire_bytes(part_envelope) -> int:
    """What the host measures for one part.

    The envelope is marshalled by the plugin, nested as MCP text content and
    re-serialized by the host — so it is escaped a second time on the way out.
    Modelled here independently of paging.py so this guard keeps its own oracle,
    exactly as test_paged_transfer.py does.
    """
    text = '{"ok":true,"result":' + json.dumps(part_envelope) + "}"
    reply = {"success": True,
             "result": {"content": [{"type": "text", "text": text}]},
             "id": "x" * 36}
    return bytes_of(reply)


def _without_positions(env):
    """Drop layout x/y: the layout RNG advances per call, so two get_graph calls
    place the same graph differently. Everything else must match."""
    env = copy.deepcopy(env)
    for node in env["artifacts"][0]["nodes"]:
        node.pop("x", None)
        node.pop("y", None)
    return env


class ContractGuardTest(unittest.TestCase):
    """The six cases. Each reads a store of its own, so no case depends on the
    order the others ran in — the state a refusal must not damage is re-read
    from the store rather than remembered."""

    WEIGHED: list = []

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="codetools_contract_guard_")
        cls.empty_db = cls._seed("empty", 0, healthy=True)
        cls.small_db = cls._seed("small", SMALL_SYMBOLS, healthy=True)
        cls.large_db = cls._seed("large", LARGE_SYMBOLS, healthy=True)
        cls.findings_db = cls._seed("findings", LARGE_SYMBOLS, healthy=False)

    @classmethod
    def tearDownClass(cls):
        ContractGuard(cls, sink=cls.WEIGHED).report(
            "codetools contract guard measurements")
        shutil.rmtree(cls._tmp, ignore_errors=True)

    @classmethod
    def _seed(cls, name: str, symbols: int, healthy: bool) -> str:
        """One store of `symbols` symbols.

        `healthy` decides which of the two large moods this is: a healthy graph
        chains each symbol to the next (so only the entry point has no caller)
        and gives every symbol its own signature hash. An unhealthy one has no
        edges at all and one shared hash, so EVERY symbol is dead code and every
        symbol is a DRY candidate — the graph whose findings are the answer.
        """
        path = os.path.join(cls._tmp, "%s.db" % name)
        store = CodeMagicStore(path)
        try:
            if symbols:
                pid = store.upsert_project("fixture", "/tmp/fixture",
                                           language="gdscript")
                fid = store.upsert_file(pid, "big.gd", line_count=symbols * 10)
                ids = [
                    store.upsert_symbol(
                        fid, "sym_%03d" % i, "function",
                        signature="func sym_%03d(x: int) -> void" % i,
                        line_start=i * 10, line_end=i * 10 + 8,
                        description=DESCRIPTION,
                        is_entry_point=(healthy and i == 0),
                        signature_hash=("hash_%03d" % i) if healthy else "same_hash")
                    for i in range(symbols)
                ]
                if healthy:
                    for i in range(symbols - 1):
                        store.upsert_edge(ids[i], ids[i + 1], "calls", confidence=1.0)
        finally:
            store.close()
        return path

    # -- helpers -----------------------------------------------------------

    def _guard(self) -> ContractGuard:
        return ContractGuard(self, sink=self.WEIGHED)

    def _graph(self, db_path: str, page: dict | None = None) -> dict:
        params = {"db_path": db_path}
        if page is not None:
            params["page"] = page
        reply = router.route("get_graph", params)
        envelope.validate(reply)
        return reply

    def _walk(self, guard: ContractGuard, case: str, db_path: str) -> tuple[str, list[int]]:
        """Run a whole paged transfer. Returns the reassembled text and the wire
        size of every part, so the caller can judge both what arrived and what
        it cost."""
        head_reply = self._graph(db_path, {"max_bytes": PANEL_BUDGET})
        head = head_reply["artifacts"][0]
        self.assertGreater(head["parts"], 1,
                           "%s: an over-cap graph must need more than one part" % case)
        text = head["chunk"]
        sizes = [_wire_bytes(head_reply)]
        for part in range(1, head["parts"]):
            reply = self._graph(db_path, {"token": head["token"], "part": part})
            piece = reply["artifacts"][0]
            self.assertEqual(piece["part"], part)
            text += piece["chunk"]
            sizes.append(_wire_bytes(reply))
        guard.weigh(case, {"db_path": db_path, "page": {"max_bytes": PANEL_BUDGET}},
                    json.loads(text),
                    "%d parts, largest %d B of a %d B budget"
                    % (head["parts"], max(sizes), PANEL_BUDGET))
        return text, sizes

    # -- the six cases -----------------------------------------------------

    def test_1_null_document(self):
        """An empty store is a real answer, not a failure and not an absence:
        the reply is a graph artifact carrying no nodes, which a reader can tell
        apart from a call that did not run."""
        guard = self._guard()
        reply = self._graph(self.empty_db)
        guard.expect_success("null-document", reply)
        artifact = reply["artifacts"][0]
        self.assertEqual(artifact["type"], "code_graph",
                         "an empty store must still answer with a graph")
        self.assertEqual(len(artifact["nodes"]), 0)
        self.assertEqual(len(artifact["edges"]), 0)

    def test_2_small_happy(self):
        """Three symbols, in the unpaged shape an agent over stdio still gets:
        no chunking, the nodes themselves."""
        guard = self._guard()
        reply = self._graph(self.small_db)
        guard.expect_success("small-happy", reply)
        artifact = reply["artifacts"][0]
        guard.expect_document("small-happy", "the nodes in the graph",
                              len(artifact["nodes"]))
        self.assertEqual(len(artifact["nodes"]), SMALL_SYMBOLS)
        self.assertNotIn("chunk", artifact,
                         "a graph that fits must not arrive paged")

    def test_3_small_unhappy(self):
        """A malformed call, refused by its own code — and the store it named is
        exactly as it was, because a refused read must not write."""
        guard = self._guard()
        reply = router.route("undescribed", {"db_path": self.small_db, "limit": -3})
        envelope.validate(reply)
        code = guard.expect_refusal("small-unhappy", reply)
        self.assertEqual(code, "invalid_args")
        guard.expect_unchanged(
            "small-unhappy", "the symbols in the store",
            len(self._graph(self.small_db)["artifacts"][0]["nodes"]), SMALL_SYMBOLS)

    def test_4_large_happy(self):
        """A megabyte of graph across a bridge that carries 64 KiB: every part
        fits the budget the caller asked for, and what arrives is the document,
        not a summary of it."""
        guard = self._guard()
        unpaged = self._graph(self.large_db)
        size = bytes_of(unpaged)
        guard.weigh("large-happy(unpaged)", {"db_path": self.large_db}, unpaged,
                    "bridge cap %d B, no bulk route" % CONTROL_BYTES)
        self.assertGreater(
            size, CONTROL_BYTES,
            "the fixture is only %d bytes — it no longer exercises the cap" % size)

        text, sizes = self._walk(guard, "large-happy", self.large_db)
        self.assertLessEqual(
            max(sizes), PANEL_BUDGET,
            "a part reaches the host as %d bytes, over the %d-byte budget the "
            "caller asked for" % (max(sizes), PANEL_BUDGET))
        reassembled = json.loads(text)
        self.assertEqual(_without_positions(reassembled), _without_positions(unpaged),
                         "the reassembled envelope differs from the unpaged one")
        self.assertEqual(len(reassembled["artifacts"][0]["nodes"]), LARGE_SYMBOLS)
        self.assertEqual(len(reassembled["artifacts"][0]["edges"]), LARGE_SYMBOLS - 1)

    def test_5_large_unhappy(self):
        """The transfer whose token is gone. The refusal is the whole point: a
        caller that asked for part 1 of a document it can no longer have must be
        told so, never handed a chunk that would reassemble into a graph missing
        everything after part 0."""
        guard = self._guard()
        head = self._graph(self.large_db, {"max_bytes": PANEL_BUDGET})["artifacts"][0]
        self.assertGreater(head["parts"], 1)
        reply = self._graph(self.large_db, {"token": "0" * 32, "part": 1})
        guard.weigh("large-unhappy", {"db_path": self.large_db,
                                      "page": {"token": "0" * 32, "part": 1}}, reply)
        code = guard.expect_refusal("large-unhappy", reply)
        self.assertEqual(code, "paging_expired")
        for artifact in reply.get("artifacts", []):
            self.assertNotIn("chunk", artifact,
                             "a lost transfer answered with a fragment anyway")

    def test_6_large_error_reply(self):
        """The same 120 symbols, every one of them dead and every signature
        duplicated. What grows is the FINDINGS block — the part of the reply
        that says what is wrong — and it grows on an axis the clean graph never
        exercises, while the transfer still has to page within budget."""
        guard = self._guard()
        clean = self._graph(self.large_db)["artifacts"][0]["analysis"]
        findings = self._graph(self.findings_db)["artifacts"][0]

        guard.weigh("large-errors(findings)", {"db_path": self.findings_db},
                    findings["analysis"],
                    "the clean graph's findings weigh %d B" % bytes_of(clean))
        self.assertEqual(len(findings["nodes"]), LARGE_SYMBOLS,
                         "both moods must describe the same number of symbols")
        self.assertEqual(sorted(findings["analysis"]["dead_code_ids"]),
                         sorted(n["id"] for n in findings["nodes"]),
                         "every symbol is unreachable here; the findings must "
                         "name every one of them")
        self.assertGreater(
            bytes_of(findings["analysis"]), bytes_of(clean),
            "the findings payload for a graph where everything is wrong is no "
            "bigger than for one where nothing is")

        text, sizes = self._walk(guard, "large-errors", self.findings_db)
        self.assertLessEqual(
            max(sizes), PANEL_BUDGET,
            "a findings-bearing part reaches the host as %d bytes, over the "
            "%d-byte budget" % (max(sizes), PANEL_BUDGET))
        self.assertEqual(
            len(json.loads(text)["artifacts"][0]["analysis"]["dead_code_ids"]),
            LARGE_SYMBOLS,
            "the reassembled document lost findings on the way through paging")


if __name__ == "__main__":
    unittest.main()
