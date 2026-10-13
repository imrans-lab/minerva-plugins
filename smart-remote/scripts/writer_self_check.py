#!/usr/bin/env python3
"""Focused writer gate; run inside the qualification container, never the host."""
from pathlib import Path
import subprocess
import sys


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    commands = [
        ["cargo", "fmt", "--check"],
        ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"],
        ["cargo", "test", "--locked", "--test", "bridge", "--", "--nocapture"],
        [sys.executable, "protocol/tools/check_examples.py"],
    ]
    if (root / "src/resample.rs").exists():
        commands.insert(2, ["cargo", "test", "--locked", "--lib", "resample::tests", "--", "--nocapture"])
    for command in commands:
        print("CHECK", " ".join(command), flush=True)
        subprocess.run(command, cwd=root, check=True, timeout=300)
    print("Focused writer checks PASS; full qualification and physical playback remain separate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
