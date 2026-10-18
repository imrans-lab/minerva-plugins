#!/usr/bin/env python3
"""Refuse private host dependencies in the exact UI files shipped by Sheets.

Full-host test drivers and the unshipped S4 tool copies are not product imports.
The archive packer owns the file inventory; the host owns its public SDK list.
"""
from __future__ import annotations

import argparse
import posixpath
import re
import sys
from pathlib import Path

from package import interface_files


def violations(name: str, text: str, private: set[str], public: set[str]) -> list[str]:
    """Check paths plus host-class identifiers outside strings and comments."""
    result = []
    local = set(re.findall(r"(?m)^\s*(?:const|class|class_name)\s+(\w+)", text))
    lexer = r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|#[^\n]*|\b[A-Za-z_]\w*\b'
    for number, line in enumerate(text.splitlines(), 1):
        for path in re.findall(r"(?:res|user|uid)://[^\s\"')]+", line):
            if path not in public:
                result.append(f"{name}:{number}: non-public resource {path}")
        for path in re.findall(r'(?:\b(?:preload|load)\(\s*|\bpath\s*=\s*)[\"\']([^\"\']+)', line):
            if "://" in path:
                continue # Already checked above, including the public SDK exception.
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), path))
            if path.startswith("/") or resolved == ".." or resolved.startswith("../"):
                result.append(f"{name}:{number}: resource escapes plugin {path}")
        if name.endswith(".gd"):
            for token in re.findall(lexer, line):
                if token in private and token not in local:
                    result.append(f"{name}:{number}: private host class {token}")
    return result


def host_contract(host: Path) -> tuple[set[str], set[str]]:
    owner = (host / "src/Scripts/Services/Plugins/PluginGenerationStore.gd").read_text()
    match = re.search(r"const HOST_PATHS: Array\[String\] = \[(.*?)\]", owner, re.DOTALL)
    if match is None:
        raise ValueError("Cannot read the host-owned public API path list")
    public = set(re.findall(r'"([^\"]+)"', match[1]))
    public_symbols = set()
    for path in public:
        public_symbols.update(re.findall(r"(?m)^class_name (\w+)",
                                         (host / "src" / path.removeprefix("res://")).read_text()))
    symbols = set()
    for path in (host / "src").rglob("*.gd"):
        symbols.update(re.findall(r"(?m)^class_name (\w+)", path.read_text()))
    if "Editor" not in symbols or not public:
        raise ValueError("The census requires a full Minerva checkout for its private-class inventory")
    return symbols - public_symbols, public


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", type=Path)
    parser.add_argument("--self-test", action="store_true", help="also prove private imports/classes are refused")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    private, public = host_contract(args.host.resolve())
    if args.self_test:
        for planted in ['const Bad := preload("res://Scripts/UI/Controls/Note.gd")',
                        'const Bad := preload("uid://private-probe")',
                        'var bad: Editor']:
            negative = violations("ui/planted.gd", planted, private, public)
            if not negative or not all("ui/planted.gd:1:" in finding for finding in negative):
                raise ValueError("Census failed to refuse planted private dependency: " + planted)
            print("PASS refused: " + "; ".join(negative))
    findings = []
    files = [path for path in interface_files(root) if path.suffix in (".gd", ".tscn")]
    for path in files:
        findings.extend(violations(path.relative_to(root).as_posix(), path.read_text(), private, public))
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        raise SystemExit(1)
    print(f"PASS public-API census: {len(files)} shipped resources, {len(private)} private host classes excluded")


if __name__ == "__main__":
    main()
