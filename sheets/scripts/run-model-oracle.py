#!/usr/bin/env python3
"""Build a fresh minimal project from the exact host public SDK; no private code.

Run only in an isolated container. The destination must not already exist.
Full-host source-install/R17 tests cover services absent from this model oracle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    host = args.host.resolve()
    destination = args.destination.resolve()
    destination.mkdir()  # Refuse any existing project; never overwrite or delete.
    plugin = Path(__file__).resolve().parents[1]
    sdk_relative = Path("Scripts/Services/Plugins/MinervaPluginPanel.gd")
    sdk = host / "src" / sdk_relative
    target = destination / sdk_relative
    target.parent.mkdir(parents=True)
    shutil.copyfile(sdk, target)
    atomic_relative = Path("Scripts/Services/Plugins/AtomicFile.gd")
    atomic_source = host / "src" / atomic_relative
    atomic_target = destination / atomic_relative
    shutil.copyfile(atomic_source, atomic_target)
    if atomic_source.read_bytes() != atomic_target.read_bytes():
        raise ValueError("Public AtomicFile copy differs from host")
    for filename in ("project.godot", "oracle.gd"):
        shutil.copyfile(plugin / "tests/isolation" / filename, destination / filename)
    receipt = {"public_sdk_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
               "host_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=host, text=True).strip(),
               "host_source_files": [sdk_relative.as_posix(), atomic_relative.as_posix()],
               "atomic_file_sha256": hashlib.sha256(atomic_target.read_bytes()).hexdigest(),
               "scope": "complete B0 spreadsheet model only; full-host tests cover host services"}
    if sdk.read_bytes() != target.read_bytes():
        raise ValueError("Public SDK copy differs from host")
    (destination / "sdk-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    environment = dict(os.environ, SHEETS_PLUGIN_ROOT=str(plugin),
                       SHEETS_MODEL_FIXTURES=str(host / "src/test/fixtures/spreadsheet_contract"))
    # A new profile plus no project autoloads makes host-private globals unavailable.
    environment["XDG_DATA_HOME"] = str(destination / "profile")
    imported = subprocess.run(["godot", "--headless", "--editor", "--path", str(destination), "--import"],
                              env=environment, check=False, timeout=120)
    if imported.returncode:
        return imported.returncode
    return subprocess.run(["godot", "--headless", "--path", str(destination),
                           "--script", "res://oracle.gd"], env=environment, check=False, timeout=90).returncode


if __name__ == "__main__":
    raise SystemExit(main())
