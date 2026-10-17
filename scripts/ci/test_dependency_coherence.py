"""Exercise the actual dependency/lane guard against coherent and drifting trees."""
from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from check_dependencies import GO_MODULES, check_dependencies


class DependencyCoherenceTests(unittest.TestCase):
    def test_current_tree_and_drift_refusals(self) -> None:
        source = Path(__file__).resolve().parents[2]
        self.assertEqual(check_dependencies(source), [])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(source / ".github", root / ".github")
            shutil.copy2(source / ".go-version", root / ".go-version")
            for module in GO_MODULES:
                (root / module).mkdir()
                shutil.copy2(source / module / "go.mod", root / module / "go.mod")
            manifest = root / "docket/manifest.json"
            shutil.copy2(source / "docket/manifest.json", manifest)
            shared = root / "shared/go.mod"
            original = shared.read_text()
            shared.write_text(original.replace("v1.20.3", "v1.20.4"))
            self.assertTrue(any("requirements differ" in error for error in check_dependencies(root)))
            shared.write_text(original)
            data = json.loads(manifest.read_text())
            data["setup"]["requires"][0]["min"] = "1.23"
            manifest.write_text(json.dumps(data))
            self.assertTrue(any("source-build minimum" in error for error in check_dependencies(root)))
            shutil.copy2(source / "docket/manifest.json", manifest)
            action = root / ".github/actions/pcb-setup/action.yml"
            action.write_text(action.read_text().replace("go-version-file: .go-version", 'go-version: "1.26"'))
            self.assertTrue(any("setup-go must read" in error for error in check_dependencies(root)))


if __name__ == "__main__":
    unittest.main()
