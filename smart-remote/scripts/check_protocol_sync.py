"""Compare the retained firmware snapshot with the canonical remote contracts."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


def contract_files(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file() and "__pycache__" not in path.relative_to(root).parts
        and path.relative_to(root) != Path("README.md")
    }


def main() -> int:
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        print("Usage: check_protocol_sync.py /path/to/ccsandbox/smart-remote-v2/protocol", file=sys.stderr)
        return 2
    scripts = Path(__file__).resolve().parent
    canonical = contract_files(scripts.parent / "protocol")
    snapshot = contract_files(Path(sys.argv[1]))
    amendment = json.loads((scripts / "protocol-owner-amendment.json").read_text())
    mismatches = []
    for name in sorted(canonical.keys() | snapshot.keys()):
        current, retained = canonical.get(name), snapshot.get(name)
        if current == retained:
            continue
        if name == "protocol.md" and current is not None and retained is not None:
            if (hashlib.sha256(current).hexdigest() == amendment["canonical_protocol_md_sha256"]
                    and hashlib.sha256(retained).hexdigest() == amendment["source_protocol_md_sha256"]):
                print("Retained protocol.md differs only by the exact approved voice ownership amendment: "
                      + amendment["ruling"])
                continue
        mismatches.append(name)
    if mismatches:
        print("Protocol drift: " + ", ".join(mismatches), file=sys.stderr)
        return 1
    print("Protocol contracts match, including any explicitly pinned ownership amendment")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
