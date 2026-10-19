"""Documentation guard anti-cases use ordinary Markdown, without a host checkout."""
from __future__ import annotations

import unittest

from check_plugin_docs import check_documents


class PluginDocsTest(unittest.TestCase):
    def test_links_and_retired_claim(self) -> None:
        guide = "# Guide\n## Live reload\nOpt in with live_reload.\n"
        ledger = "# Ledger\n| `_on_panel_loaded` | [guide](PLUGIN_DEVELOPER_GUIDE.md#live-reload) |\n"
        documents = {"PLUGIN_DEVELOPER_GUIDE.md": guide, "PLUGIN_API_COVERAGE.md": ledger}
        self.assertEqual(check_documents(documents), [])
        broken = dict(documents)
        broken["PLUGIN_API_COVERAGE.md"] = ledger.replace("#live-reload", "#missing")
        self.assertIn("PLUGIN_API_COVERAGE.md: broken anchor: PLUGIN_DEVELOPER_GUIDE.md#missing",
                      check_documents(broken))
        stale = dict(documents)
        stale["PLUGIN_DEVELOPER_GUIDE.md"] += "| `_on_hot_reload()` | Automatically called after source edits. |\n"
        self.assertIn("PLUGIN_DEVELOPER_GUIDE.md: retired hook claimed as supported: _on_hot_reload",
                      check_documents(stale))
        stale["PLUGIN_DEVELOPER_GUIDE.md"] = guide + "| `_on_hot_reload` | Retired; not called. |\n"
        self.assertEqual(check_documents(stale), [])
        stale["PLUGIN_DEVELOPER_GUIDE.md"] += "The host calls `_on_hot_reload()` automatically after every source edit.\n"
        self.assertIn("PLUGIN_DEVELOPER_GUIDE.md: retired hook claimed as supported: _on_hot_reload",
                      check_documents(stale))
        stale["PLUGIN_API_COVERAGE.md"] += "| `host.echo` | host_capability | no link |\n"
        self.assertIn("PLUGIN_API_COVERAGE.md: contract row needs a guide anchor: `host.echo`",
                      check_documents(stale))
        stale["PLUGIN_API_COVERAGE.md"] = ledger + "| `host.undocumented` | host_capability | [guide](PLUGIN_DEVELOPER_GUIDE.md#live-reload) |\n"
        self.assertIn("PLUGIN_API_COVERAGE.md: contract has no guide description: `host.undocumented`",
                      check_documents(stale))
        row = "| `host.echo` | host_capability | [guide](PLUGIN_DEVELOPER_GUIDE.md#live-reload) |\n"
        indexed = {"PLUGIN_DEVELOPER_GUIDE.md": guide + "Use `host.echo` for an echo request.\n",
                   "PLUGIN_API_COVERAGE.md": ledger + row}
        self.assertEqual(check_documents(indexed), [])
        self.assertIn("host guide: broken anchor: PLUGIN_DEVELOPER_GUIDE.md#missing",
                      check_documents(documents, "[guide](https://github.com/imrans-lab/minerva-plugins/blob/main/docs/PLUGIN_DEVELOPER_GUIDE.md#missing)"))
        indexed["PLUGIN_API_COVERAGE.md"] += row.replace("host.echo", "id")
        indexed["PLUGIN_DEVELOPER_GUIDE.md"] += "identity is a word containing id.\n"
        self.assertIn("PLUGIN_API_COVERAGE.md: contract has no guide description: `id`",
                      check_documents(indexed))


if __name__ == "__main__":
    unittest.main()
