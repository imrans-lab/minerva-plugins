"""Exercise release selection against real git history, independent of CI timing."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import regen_registry as registry


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Registry test")
        self.directory = self.root / "agent-relay"
        self.directory.mkdir()
        self.manifest = {"id": "agent_relay", "name": "Relay", "version": "1.0.0",
                         "release_targets": ["linux-x86_64"]}
        self.commit_manifest()
        self.git("tag", "agent_relay-v1.0.0")
        self.selected = registry.build_registry(self.root)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True,
                              capture_output=True, text=True)

    def commit_manifest(self):
        (self.directory / "manifest.json").write_text(json.dumps(self.manifest))
        self.git("add", ".")
        self.git("commit", "-qm", self.manifest["version"])

    def test_release_selection_survives_manifest_and_tag_changes(self):
        entry = self.selected["plugins"][0]
        self.assertEqual(entry["id"], "agent_relay")
        self.assertIn("/agent_relay-v1.0.0/agent-relay/manifest.json", entry["manifest_url"])
        self.manifest.update(version="2.0.0", release_targets=["windows-x86_64"])
        self.commit_manifest()
        # A manifest bump must neither break checks nor combine old tags/new filenames.
        self.assertEqual(registry.build_registry(self.root), self.selected)
        registry.check_registry(self.root, self.selected)
        self.git("tag", "agent_relay-v2.0.0")
        registry.check_registry(self.root, self.selected)
        latest = registry.build_registry(self.root)["plugins"][0]
        self.assertEqual(latest["version"], "2.0.0")
        self.assertEqual(list(latest["downloads"]), ["windows-x86_64"])

    def test_rejects_broken_release_metadata(self):
        for field, value in [("manifest_version", "2.0.0"), ("downloads", {}),
                             ("release_tag", "agent_relay-v1.0.0-branch-test")]:
            with self.subTest(field=field):
                bad = copy.deepcopy(self.selected)
                bad["plugins"][0][field] = value
                with self.assertRaises(ValueError):
                    registry.check_registry(self.root, bad)
        self.git("tag", "agent_relay-v9.0.0")
        with self.assertRaisesRegex(ValueError, "manifest version"):
            registry.build_registry(self.root)

    def test_release_guard_preserves_existing_stable_tags(self):
        script = Path(__file__).with_name("release-publish-guard.sh")
        for tag, prerelease, expected in [
            ("agent_relay-v1.0.0", "false", "false"),
            ("agent_relay-v2.0.0", "false", "true"),
            ("agent_relay-v1.0.0", "true", "true"),
        ]:
            with self.subTest(tag=tag, prerelease=prerelease):
                output = self.root / "output"
                output.write_text("")
                env = {**os.environ, "GITHUB_OUTPUT": str(output),
                       "GITHUB_STEP_SUMMARY": str(self.root / "summary")}
                subprocess.run(["bash", str(script.resolve()), tag, prerelease],
                               cwd=self.root, env=env, check=True, capture_output=True)
                self.assertEqual(output.read_text(), f"publish={expected}\n")

    def test_published_check_rejects_missing_empty_or_draft_assets(self):
        # Git reads stay real; only the external GitHub response is supplied.
        run = subprocess.run
        url = next(iter(self.selected["plugins"][0]["downloads"].values()))
        good = {"draft": False, "prerelease": False, "assets": [
            {"browser_download_url": url, "size": 42, "state": "uploaded"}]}
        responses = [good, {**good, "assets": []}, {**good, "draft": True},
                     {**good, "assets": [{**good["assets"][0], "size": 0}]}]
        for index, response in enumerate(responses):
            def invoke(args, **kwargs):
                if args[0] == "gh":
                    return subprocess.CompletedProcess(args, 0, json.dumps(response))
                return run(args, **kwargs)
            with self.subTest(index=index), patch.object(subprocess, "run", side_effect=invoke):
                if index == 0:
                    registry.check_registry(self.root, self.selected, published=True)
                else:
                    with self.assertRaises(ValueError):
                        registry.check_registry(self.root, self.selected, published=True)


if __name__ == "__main__":
    unittest.main()
