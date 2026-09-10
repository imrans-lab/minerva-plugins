"""Exercise release selection against real git history, independent of CI timing."""
import copy
import json
import os
from pathlib import Path
import re
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


def init_repo(root):
    """A throwaway git repo, and the `git` runner for it."""
    def git(*args):
        subprocess.run(["git", "-C", str(root), *args], check=True,
                       capture_output=True, text=True)
    git("init", "-q")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "Registry test")
    return git


class CouncilReleaseTests(unittest.TestCase):
    """Hold council's tag, manifest, version and targets to one another.

    Four files have to agree for a marketplace install to work, and nothing
    else notices when they stop: the manifest's version and `release_targets`,
    the tag the workflow computes, the archive filename the pack script writes,
    and the download URL the generator advertises. Each assertion below joins
    two of them against the REAL files rather than a fixture, so a drift is a
    failure here instead of a 404 the day the registry is published.
    """

    repo = Path(__file__).resolve().parent.parent

    def setUp(self):
        self.plugin = self.repo / "council"
        self.manifest = json.loads((self.plugin / "manifest.json").read_text())
        self.workflow = (self.repo / ".github/workflows/council.yml").read_text()

    def print_archive_name(self, target):
        """The name the pack script itself computes — asking the script rather
        than restating its convention is what makes this a parity check."""
        out = subprocess.run(
            ["bash", "scripts/pack-release.sh", "--print-name", target],
            cwd=self.plugin, check=True, capture_output=True, text=True)
        return out.stdout.strip()

    def test_council_is_generated_and_the_directory_list_stays_sorted(self):
        self.assertIn("council", registry.PLUGIN_DIRS)
        self.assertEqual(registry.PLUGIN_DIRS, sorted(registry.PLUGIN_DIRS))
        self.assertEqual(self.manifest["id"], "council")

    def test_the_workflow_builds_exactly_the_targets_the_manifest_declares(self):
        declared = self.manifest["release_targets"]
        self.assertEqual(declared, ["linux-x86_64"],
                         "a further target ships only with its own validation")
        self.assertEqual([t for t in declared if t not in registry.TARGETS], [],
                         "the marketplace does not understand this target")
        built = re.findall(r"^\s*- target: (\S+)$", self.workflow, re.M)
        self.assertEqual(built, declared,
                         "the matrix and release_targets disagree: the registry would "
                         "advertise an asset nobody built, or a build nobody points at")

    def test_the_archive_gate_and_the_branch_sentinel_are_still_wired(self):
        for fragment in ("scripts/pack-release.sh", "scripts/verify-archive.py",
                         "release-publish-guard.sh"):
            self.assertIn(fragment, self.workflow)
        self.assertIn('TAG="council-v${VERSION}"', self.workflow)
        self.assertIn("-branch-", self.workflow,
                      "a branch build must tag the sentinel the generator skips")

    def test_tag_manifest_and_archive_name_agree_end_to_end(self):
        version = self.manifest["version"]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            git = init_repo(root)
            (root / "council").mkdir()
            (root / "council/manifest.json").write_text(json.dumps(self.manifest))
            git("add", ".")
            git("commit", "-qm", version)
            # The prerelease a branch build publishes, tagged first so it would
            # win a naive "newest tag" selection.
            git("tag", f"council-v{version}-branch-dcr-council")
            git("tag", f"council-v{version}")

            entry = registry.build_plugin_entry(root / "council", root)
            self.assertEqual(entry["release_tag"], f"council-v{version}")
            self.assertEqual(entry["version"], version)
            self.assertEqual(entry["manifest_version"], version)
            self.assertEqual(sorted(entry["downloads"]),
                             sorted(self.manifest["release_targets"]))
            for target, url in entry["downloads"].items():
                self.assertEqual(url.rsplit("/", 1)[1], self.print_archive_name(target),
                                 "the advertised download is not the file CI packs")
            registry.check_registry(root, {"registry_version": registry.REGISTRY_VERSION,
                                           "plugins": [entry]})

    def test_before_the_first_tag_council_is_skipped_rather_than_red(self):
        """The ordering trap: council joins PLUGIN_DIRS in the same commit that
        adds its workflow, and its first tag cannot exist until that workflow
        has run. A generator that demanded a tag for every listed directory
        would leave the committed registry permanently failing --check between
        those two moments. It skips instead, so registry.json is regenerated
        AFTER the release exists and never before it."""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            git = init_repo(root)
            (root / "council").mkdir()
            (root / "council/manifest.json").write_text(json.dumps(self.manifest))
            (root / "agent-relay").mkdir()
            (root / "agent-relay/manifest.json").write_text(json.dumps(
                {"id": "agent_relay", "name": "Relay", "version": "1.0.0",
                 "release_targets": ["linux-x86_64"]}))
            git("add", ".")
            git("commit", "-qm", "untagged council beside a released plugin")
            git("tag", "agent_relay-v1.0.0")

            selected = registry.build_registry(root)
            self.assertEqual([p["id"] for p in selected["plugins"]], ["agent_relay"])
            registry.check_registry(root, selected)


if __name__ == "__main__":
    unittest.main()
