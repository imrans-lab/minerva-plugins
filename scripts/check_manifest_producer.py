#!/usr/bin/env python3
"""Build, copy and launch a real minimal Rust source-tier worker on this platform."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    builder = Path(__file__).with_name("build_plugin_from_manifest.py")
    with tempfile.TemporaryDirectory(prefix="manifest-producer-") as temporary:
        root = Path(temporary)
        (root / "src").mkdir()
        (root / "Cargo.toml").write_text('[package]\nname="producer-probe"\nversion="0.1.0"\nedition="2021"\n')
        (root / "Cargo.lock").write_text('version = 4\n[[package]]\nname = "producer-probe"\nversion = "0.1.0"\n')
        (root / "src/main.rs").write_text('fn main() { println!("SOURCE_PRODUCER_OK"); }\n')
        steps = [
            {"type": "cargo_build", "manifest_dir": ".", "profile": "release", "artifact": "target/release/producer-probe"},
            {"type": "copy", "from": "target/release/producer-probe", "to": "worker"},
            {"type": "exec", "argv": ["./worker"], "artifact": "worker"},
        ]
        (root / "manifest.json").write_text(json.dumps({"setup": {"requires": [{"tool": "cargo", "min": "1.83"}], "steps": steps}}))
        result = subprocess.run([sys.executable, str(builder), str(root)], check=True, capture_output=True, text=True, timeout=300)
        report = json.loads(result.stdout)
        suffix = ".exe" if sys.platform == "win32" else ""
        assert [s["artifact"] for s in report["steps"]] == ["target/release/producer-probe" + suffix, "worker" + suffix, "worker" + suffix]
        worker = root / ("worker" + suffix)
        assert worker.read_bytes() == (root / ("target/release/producer-probe" + suffix)).read_bytes()
        launched = subprocess.run([str(worker)], check=True, capture_output=True, text=True, timeout=30)
        assert launched.stdout.strip() == "SOURCE_PRODUCER_OK"
        print(json.dumps({"platform": sys.platform, "build_copy_exec": "PASS", "artifacts": [s["artifact"] for s in report["steps"]]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
