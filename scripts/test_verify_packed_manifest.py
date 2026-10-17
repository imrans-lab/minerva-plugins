"""The shared release gate rejects parsed JSON corruption, independent of encoding."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).with_name("verify-packed-manifest.py")


class PackedManifestTests(unittest.TestCase):
    def test_rejects_mojibake_extra_and_missing_fields(self) -> None:
        source = {"id": "fixture", "version": "1.0.0", "description": "Café — Unicode",
                  "setup": {"command": "build"}}
        valid = {key: value for key, value in source.items() if key != "setup"}
        mojibake = json.loads(json.dumps(valid, ensure_ascii=False).encode("utf-8").decode("cp1252"))
        missing = {key: value for key, value in valid.items() if key != "description"}
        for name, packed in [("mojibake", mojibake), ("extra", {**valid, "extra": True}),
                             ("missing", missing)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as work:
                src, dest = Path(work) / "source.json", Path(work) / "packed.json"
                src.write_text(json.dumps(source, ensure_ascii=False), encoding="utf-8")
                dest.write_text(json.dumps(packed), encoding="utf-8")
                result = subprocess.run([sys.executable, str(CHECK), str(src), str(dest)],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
