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
from pathlib import Path, PureWindowsPath

from package import interface_files


def logical_lines(text: str) -> list[tuple[int, str]]:
    """Join GDScript continuations while retaining their first physical line."""
    result = []
    pending = ""
    first = 1
    for number, line in enumerate(text.splitlines(), 1):
        if not pending:
            first = number
        pending += line
        if pending.endswith("\\"):
            pending = pending[:-1] + " "
        else:
            result.append((first, pending))
            pending = ""
    if pending:
        result.append((first, pending))
    return result


def violations(name: str, text: str, private: set[str], public: set[str],
               shipped: set[str] | None = None) -> list[str]:
    """Refuse nonliteral script dependencies and imports outside the shipped closure."""
    result = []
    local = set(re.findall(r"(?m)^(?:const|class|class_name)\s+(\w+)", text))
    lexer = r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|#[^\n]*|\b[A-Za-z_]\w*\b'
    literal = r'["\']([^"\']+)["\']'
    for number, line in logical_lines(text):
        paths = re.findall(r"(?:res|user|uid)://[^\s\"')]+", line)
        paths += re.findall(r'(?:\bextends\s+|\bpath\s*=\s*)' + literal, line)
        for call in re.finditer(r'\b(?:preload|load)\s*\(([^)]*)\)', line):
            quoted = re.fullmatch(r'\s*' + literal + r'\s*', call[1])
            if quoted is None:
                result.append(f"{name}:{number}: nonliteral resource dependency {call[0]}")
            else:
                paths.append(quoted[1])
        if re.search(r'\b(?:preload|load)\s*\(', line) and not re.search(r'\b(?:preload|load)\s*\([^)]*\)', line):
            result.append(f"{name}:{number}: unsupported multiline resource dependency")
        for path in set(paths):
            if path in public:
                continue
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), path.replace("\\", "/")))
            if "://" in path or PureWindowsPath(path).drive or PureWindowsPath(path).root or path.startswith("/"):
                result.append(f"{name}:{number}: non-public resource {path}")
            elif resolved == ".." or resolved.startswith("../"):
                result.append(f"{name}:{number}: resource escapes plugin {path}")
            elif shipped is None or resolved not in shipped:
                result.append(f"{name}:{number}: resource is not shipped {path}")
        if name.endswith(".gd"):
            for token in re.findall(lexer, line):
                if token == "ResourceLoader":
                    result.append(f"{name}:{number}: unsupported ResourceLoader dependency API")
                if token in private and token not in local:
                    result.append(f"{name}:{number}: private host symbol {token}")
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
    project = (host / "src/project.godot").read_text()
    autoloads = re.search(r"(?ms)^\[autoload\]\s*(.*?)(?=^\[|\Z)", project)
    if autoloads is None:
        raise ValueError("Cannot read host autoload inventory")
    symbols.update(re.findall(r"(?m)^(\w+)\s*=", autoloads[1]))
    if "SingletonObject" not in symbols or "Editor" not in symbols or not public:
        raise ValueError("The census requires a full Minerva checkout for its private-class inventory")
    return symbols - public_symbols, public


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", type=Path)
    parser.add_argument("--self-test", action="store_true", help="also prove private imports/classes are refused")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    private, public = host_contract(args.host.resolve())
    inventory = interface_files(root)
    shipped = {path.relative_to(root).as_posix() for path in inventory}
    if args.self_test:
        for planted in ['const Bad := preload("res://Scripts/UI/Controls/Note.gd")',
                        'const Bad := preload("uid://private-probe")',
                        'var bad: Editor',
                        'extends "../../../Minerva/src/Scripts/UI/Controls/Note.gd"',
                        'var bad = SingletonObject.editor_container',
                        'var bad = load("C:/Minerva/src/Scripts/UI/Controls/Note.gd")',
                        'var bad = load("../tests/helpers/staging_body.gd")',
                        'var bad = load(resource_path)',
                        'var bad = load("domain/" + resource_name)',
                        'extends \\\n"../../../Minerva/src/Scripts/UI/Controls/Note.gd"',
                        'ResourceLoader.load_threaded_request(resource_path)',
                        'ResourceLoader.load_threaded_request("../tests/helpers/staging_body.gd")',
                        'class Probe:\n    const Editor = 1\nvar bad: Editor']:
            negative = violations("ui/planted.gd", planted, private, public, shipped)
            if not negative or not all(re.match(r"ui/planted\.gd:\d+:", finding) for finding in negative):
                raise ValueError("Census failed to refuse planted private dependency: " + planted)
            print("PASS refused: " + "; ".join(negative))
    findings = []
    files = [path for path in inventory if path.suffix in (".gd", ".tscn")]
    for path in files:
        findings.extend(violations(path.relative_to(root).as_posix(), path.read_text(), private, public, shipped))
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        raise SystemExit(1)
    print(f"PASS public-API census: {len(files)} shipped resources, {len(private)} private host classes excluded")


if __name__ == "__main__":
    main()
