"""Exercise stable annotated-tag admission against real temporary Git history."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("release-publish-guard.sh").resolve()


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


class ReleaseTagGuardTest(unittest.TestCase):
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
