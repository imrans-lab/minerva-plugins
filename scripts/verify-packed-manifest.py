"""Refuse a release whose packed manifest changes the UTF-8 source contract."""
import argparse
import json
import sys
from pathlib import Path

from packed_manifest import verify_packed_manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("packed", type=Path)
    args = parser.parse_args()
    source = json.loads(args.source.read_text(encoding="utf-8"))
    packed = json.loads(args.packed.read_text(encoding="utf-8"))
    try:
        verify_packed_manifest(source, packed)
    except ValueError as error:
        print(f"{args.packed}: {error}", file=sys.stderr)
        return 1
    print(f"{args.packed}: packed manifest matches source minus setup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
