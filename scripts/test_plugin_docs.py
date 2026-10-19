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
        stale["PLUGIN_API_COVERAGE.md"] += "| `host.echo` | host_capability | no link |\n"
        self.assertIn("PLUGIN_API_COVERAGE.md: contract row needs a guide anchor: `host.echo`",
                      check_documents(stale))


if __name__ == "__main__":
    unittest.main()
