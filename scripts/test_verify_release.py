"""Exercise the public offline command with tiny real tarballs, never network mocks."""
import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).with_name("verify-release.py")
TAG = "fixture-v1.2.3"


def make_release(root: Path, corruption: str = "") -> None:
    source = {"id": "fixture", "version": "1.2.3", "host_api_version": "2",
              "description": "Café — fixture", "release_targets": ["linux-x86_64", "windows-x86_64"],
              "setup": {"command": "build"}}
    packed = {"id": "fixture", "version": "1.2.3", "host_api_version": "2",
              "description": "Café — fixture", "release_targets": ["linux-x86_64", "windows-x86_64"]}
    if corruption == "manifest":
        packed["description"] = "changed contract"
    assets = []
    for target in source["release_targets"]:
        path = root / f"fixture-1.2.3-{target}.tar.gz"
        files = {"manifest.json": json.dumps(packed, ensure_ascii=False).encode("utf-8"),
                 "payload.txt": b"abc"}
        sums = {name: hashlib.sha256(value).hexdigest() for name, value in files.items()}
        if corruption == "internal":
            sums["payload.txt"] = "0" * 64
        files["SHA256SUMS"] = "".join(f"{digest}  {name}\n" for name, digest in sums.items()).encode()
        with tarfile.open(path, "w:gz") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo("./" + name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        assets.append({"name": path.name, "size": path.stat().st_size,
                       "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()})
    if corruption == "archive":
        path.write_bytes(path.read_bytes()[:-1] + bytes([path.read_bytes()[-1] ^ 1]))
    if corruption == "targets":
        assets.pop()
    if corruption == "version":
        source["version"] = "1.2.4"
    (root / "source.json").write_text(json.dumps(source), encoding="utf-8")
    (root / "release.json").write_text(json.dumps({"tag_name": TAG, "draft": False,
                                                 "prerelease": False, "assets": assets}),
                                       encoding="utf-8")


class ReleaseVerificationTests(unittest.TestCase):
    def test_all_targets_verify_offline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_release(root)
            result = subprocess.run([sys.executable, str(CHECK), "fixture", TAG,
                                     "--local-dir", str(root)], check=False, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertTrue(receipt["qualified"])
            self.assertEqual(receipt["mode"], "offline")
            self.assertEqual({asset["name"] for asset in receipt["assets"]},
                             {"fixture-1.2.3-linux-x86_64.tar.gz", "fixture-1.2.3-windows-x86_64.tar.gz"})

    def test_tampering_and_missing_targets_are_refused(self) -> None:
        for corruption, reason in [("archive", "GitHub asset digest"),
                                   ("manifest", "packed manifest differs"),
                                   ("internal", "internal SHA256SUMS digest"),
                                   ("targets", "release target set"),
                                   ("version", "source manifest version")]:
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                make_release(root, corruption)
                result = subprocess.run([sys.executable, str(CHECK), "fixture", TAG,
                                         "--local-dir", str(root)], check=False, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(reason, result.stderr)


if __name__ == "__main__":
    unittest.main()
