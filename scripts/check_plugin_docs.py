"""Check plugin guide/ledger links and reject supported claims for retired hooks."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

RETIRED = {"_on_hot_reload"}
CONTRACTS = {"host_capability", "capability_namespace", "manifest_field",
             "panel_hook", "host_path", "plugin_capability", "sdk_method",
             "required_plugin_field"}


def sections(markdown: str) -> dict[str, str]:
    """GitHub heading fragments, including duplicate-heading suffixes."""
    result: dict[str, str] = {}
    counts: dict[str, int] = {}
    current = ""
    fenced = False
    for line in markdown.splitlines():
        if line.startswith("```"):
            fenced = not fenced
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line) if not fenced else None
        if heading:
            slug = re.sub(r"[^\w\- ]", "", heading[1].lower()).replace(" ", "-")
            number = counts.get(slug, 0)
            counts[slug] = number + 1
            current = slug + (f"-{number}" if number else "")
            result[current] = ""
        if current:
            result[current] += line + "\n"
        for anchor in re.findall(r'<a\s+(?:id|name)="([^"]+)"', line):
            result.setdefault(anchor, "")
    return result


def check_documents(documents: dict[str, str]) -> list[str]:
    errors: list[str] = []
    anchors = {name: sections(text) for name, text in documents.items()}
    for name, text in documents.items():
        for target, fragment in re.findall(r"\]\(([^)\s#]*)#([^)]*)\)", text):
            target = target.removeprefix("./") or name
            if ":" in target or "/" in target:
                continue
            if target not in anchors or fragment not in anchors[target]:
                errors.append(f"{name}: broken anchor: {target}#{fragment}")
        for line in text.splitlines():
            if line.startswith("|"):
                cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
                if len(cells) >= 2 and cells[1] in CONTRACTS:
                    reference = re.search(r"\]\((?:\./)?PLUGIN_DEVELOPER_GUIDE\.md#([^)]*)\)", line)
                    if not reference:
                        errors.append(f"{name}: contract row needs a guide anchor: {cells[0]}")
                for retired in RETIRED:
                    if retired in line and not re.search(r"\b(retired|unsupported|not called)\b", line, re.IGNORECASE):
                        errors.append(f"{name}: retired hook claimed as supported: {retired}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugins-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        documents = {name: (args.plugins_root / "docs" / name).read_text() for name in
                     ("PLUGIN_DEVELOPER_GUIDE.md", "PLUGIN_API_COVERAGE.md")}
        errors = check_documents(documents)
    except OSError as error:
        print(f"Plugin docs: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Plugin docs: {len(errors)} errors")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
