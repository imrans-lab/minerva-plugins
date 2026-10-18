#!/usr/bin/env python3
"""Pack a built Sheets binary with its manifest and UI; never publish a release."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import tarfile
from pathlib import Path


def package(root: Path, binary: Path, target: str, output: Path) -> Path:
    """Build one deterministic root-layout archive without deleting staging files."""
    manifest = json.loads((root / "manifest.json").read_text())
    if target not in manifest["release_targets"]:
        raise ValueError(f"Undeclared release target: {target}")
    manifest.pop("setup", None)
    files: dict[str, bytes] = {
        "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
        "sheets-plugin": binary.read_bytes(),
        "README.md": (root / "README.md").read_bytes(),
        "LICENSE.md": (root.parent / "LICENSE.md").read_bytes(),
    }
    for directory in ("ui", "icons"):
        for path in sorted((root / directory).rglob("*")):
            if path.is_file() and path.suffix in (".gd", ".tscn", ".png"):
                if path.is_symlink():
                    raise ValueError(f"Symlink refused: {path}")
                files[path.relative_to(root).as_posix()] = path.read_bytes()
    files["SHA256SUMS"] = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n"
        for name, data in sorted(files.items())
    ).encode()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"sheets-{manifest['version']}-{target}.tar.gz"
    with (
        archive.open("xb") as stream,
        gzip.GzipFile(fileobj=stream, mode="wb", filename="", mtime=0) as compressed,
        tarfile.open(fileobj=compressed, mode="w") as tar,
    ):
        for name, data in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name == "sheets-plugin" else 0o644
            tar.addfile(info, io.BytesIO(data))
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target")
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(package(Path(__file__).resolve().parents[1], args.binary, args.target, args.output))


if __name__ == "__main__":
    main()
