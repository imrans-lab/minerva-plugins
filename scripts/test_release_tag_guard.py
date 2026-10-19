"""Exercise stable annotated-tag admission against real temporary Git history."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("release-publish-guard.sh").resolve()


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


class ReleaseTagGuardTest(unittest.TestCase):
    def test_checkout_flattened_tag_restores_remote_identity(self) -> None:
        for plugin in ("sheets", "multimeter"):
            workflow = SCRIPT.parent.parent / ".github/workflows" / f"{plugin}.yml"
            restoration = 'git fetch --force origin "refs/tags/${TAG}:refs/tags/${TAG}"'
            source = workflow.read_text()
            self.assertLess(source.index(restoration), source.index(
                'bash scripts/release-publish-guard.sh "$TAG" "$PRE" ' + plugin))
            for annotated in (True, False):
                with self.subTest(plugin=plugin, annotated=annotated), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    remote = root / "remote"
                    local = root / "local"
                    remote.mkdir()
                    git(remote, "init", "-q")
                    git(remote, "config", "user.email", "fixture@example.invalid")
                    git(remote, "config", "user.name", "Release fixture")
                    (remote / plugin).mkdir()
                    (remote / plugin / "manifest.json").write_text(json.dumps({"version": "0.1.2"}))
                    git(remote, "add", ".")
                    git(remote, "commit", "-qm", "source")
                    tag = f"{plugin}-v0.1.2"
                    tag_args = ["-a", tag, "-m", "release"] if annotated else [tag]
                    git(remote, "tag", *tag_args)
                    git(root, "clone", "-q", str(remote), str(local))
                    # Reproduce checkout's forced commit-to-tag refspec without changing origin.
                    git(local, "update-ref", "refs/tags/" + tag, "HEAD")
                    output = root / "output"
                    env = {**os.environ, "TAG": tag, "GITHUB_OUTPUT": str(output),
                           "GITHUB_STEP_SUMMARY": str(root / "summary"),
                           "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/tags/" + tag}
                    subprocess.run(["bash", "-c", restoration], cwd=local, env=env,
                                   check=True, capture_output=True, text=True)
                    result = subprocess.run(["bash", str(SCRIPT), tag, "false", plugin],
                                            cwd=local, env=env, capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode == 0, annotated, result.stdout + result.stderr)
                    if annotated:
                        self.assertEqual(output.read_text(), "publish=true\n")
                    else:
                        self.assertIn("An annotated tag is required", result.stdout)

    def test_annotated_identity_and_legacy_manual_behavior(self) -> None:
        for case in ["annotated", "lightweight", "other-commit", "manifest-mismatch", "manual-existing", "manual-new", "branch-preview"]:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                git(root, "init", "-q")
                git(root, "config", "user.email", "fixture@example.invalid")
                git(root, "config", "user.name", "Release fixture")
                git(root, "config", "gc.auto", "0")
                (root / "drive").mkdir()
                (root / "drive/manifest.json").write_text(json.dumps({"version": "1.0.0"}))
                git(root, "add", ".")
                git(root, "commit", "-qm", "source")
                tag = "drive-v1.0.0"
                if case not in ["manual-new", "branch-preview"]:
                    if case == "lightweight":
                        git(root, "tag", tag)
                    else:
                        git(root, "tag", "-a", tag, "-m", "release")
                if case == "other-commit":
                    (root / "next").write_text("next source")
                    git(root, "add", ".")
                    git(root, "commit", "-qm", "next")
                if case == "manifest-mismatch":
                    (root / "drive/manifest.json").write_text(json.dumps({"version": "2.0.0"}))
                preview = case == "branch-preview"
                manual = case.startswith("manual") or preview
                if preview:
                    tag += "-branch-fixture"
                output = root / "output"
                env = {**os.environ, "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(root / "summary"),
                       "GITHUB_EVENT_NAME": "workflow_dispatch" if manual else "push",
                       "GITHUB_REF": "refs/heads/main" if manual else "refs/tags/" + tag}
                result = subprocess.run(["bash", str(SCRIPT), tag, "true" if preview else "false", "drive"],
                                        cwd=root, env=env, capture_output=True, text=True, check=False)
                accepted = case in ["annotated", "manual-existing", "branch-preview"]
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                if accepted:
                    expected = "false" if case == "manual-existing" else "true"
                    self.assertEqual(output.read_text(), f"publish={expected}\n")


if __name__ == "__main__":
    unittest.main()
