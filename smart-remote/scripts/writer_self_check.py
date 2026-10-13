#!/usr/bin/env python3
"""P2b checks in the isolated qualification container; inventory is read-only."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    if sys.argv[1:] == ["--inventory"]:
        subprocess.run([sys.executable, "-B", str(root / "scripts/check-writer.py"),
                        "--repo", str(root.parent), "--card", "smart-remote/scripts/p2b-writer-card.json", "--head", "HEAD"], check=True)
        return 0
    if len(sys.argv) != 1:
        raise SystemExit("usage: writer_self_check.py [--inventory]")
    for command in (["cargo", "fmt", "--check"],
                    ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"],
                    ["cargo", "test", "--locked", "--", "--nocapture"],
                    [sys.executable, "protocol/tools/check_examples.py"],
                    [sys.executable, "scripts/check_protocol_sync.py", "protocol"]):
        print("CHECK", " ".join(command), flush=True)
        subprocess.run(command, cwd=root, check=True, timeout=300)
    # P2b qualifies the canonical tree itself. F2 adopts it before private sync.
    with tempfile.TemporaryDirectory() as directory:
        copied = Path(directory) / "protocol"
        shutil.copytree(root / "protocol", copied)
        changed = copied / "schema/device/log_delete_all.json"
        changed.write_bytes(changed.read_bytes() + b" ")
        negative = subprocess.run([sys.executable, "scripts/check_protocol_sync.py", str(copied)], cwd=root, check=False, timeout=30)
        if negative.returncode != 1:
            raise RuntimeError("Protocol drift negative must fail with exit1")
    print("PASS: full Rust, canonical examples/self-sync and drift negative; actual Minerva/F2 runtime is separate.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
