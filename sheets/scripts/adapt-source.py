#!/usr/bin/env python3
"""Reproduce S3a's mechanical adaptation from the immutable S2 copy commit."""
from __future__ import annotations

import argparse
import json
import posixpath
import re
import subprocess
from pathlib import Path
from typing import NotRequired, TypedDict


class Source(TypedDict):
    source: str
    destination: str
    git_blob: str
    uid: NotRequired[str]
    current_destination: NotRequired[str]


class SourceMap(TypedDict):
    base_host: str
    copy_commit: str
    files: list[Source]


def original(root: Path, revision: str, name: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"{revision}:sheets/{name}"], cwd=root, text=True,
    )


def adapt(text: str, name: str, sources: list[Source], classes: dict[str, str]) -> str:
    """Change identifiers and resource locations without rewriting algorithms."""
    for item in sources:
        target = item.get("current_destination", item["destination"])
        relative = posixpath.relpath(target, posixpath.dirname(name))
        text = text.replace('"res://' + item["source"].removeprefix("src/") + '"',
                            '"' + relative + '"')
    # Leave strings and comments intact: serialized keys and messages are data.
    tokens = r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|#[^\n]*|\b[A-Za-z_]\w*\b'
    text = re.sub(tokens, lambda match: classes.get(match[0], match[0]), text)
    if name.endswith(".tscn"):
        text = re.sub(r' uid="uid://[^"]+"', "", text)
    if name == "ui/domain/SpreadsheetAutoFilterUI.gd":
        text = text.replace('const PopupScene :=',
                            'const PopupScript := preload("SpreadsheetAutoFilterPopup.gd")\nconst PopupScene :=')
        text = re.sub(r"\bSheets_SpreadsheetAutoFilterPopup\b", "PopupScript", text)
        # Off-tree scripts cannot construct themselves through the global cache.
        text = text.replace("static func attach(", "func attach(")
        text = text.replace("var ui := Sheets_SpreadsheetAutoFilterUI.new()", "var ui := self")
    if name == "ui/domain/SpreadsheetEditor.gd":
        text = text.replace("AutoFilterUIScript.attach(", "AutoFilterUIScript.new().attach(")
        for item in sources:
            if "uid" in item:
                text = text.replace('preload("' + item["uid"] + '")',
                                    '_load_icon("' + posixpath.basename(item["destination"]) + '")')
        text += '''

## Raw PNG loading works outside the host's imported resource database.
func _load_icon(filename: String) -> Texture2D:
	var script: Script = get_script()
	var path := script.resource_path.get_base_dir().path_join("../../icons/" + filename)
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(image) if image != null else null
'''
    if name.startswith("tests/gd/"):
        for constant in ("SPREADSHEET_EDITOR_PATH", "MODULE_PATH"):
            text = text.replace(f"load({constant})",
                                f"load(get_script().resource_path.get_base_dir().path_join({constant}))")
    return text


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Apply only to pristine S2 copies")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    mapping: SourceMap = json.loads((root / "scripts/source-map.json").read_text())
    inputs = {item.get("current_destination", item["destination"]): original(root, mapping["copy_commit"], item["destination"])
              for item in mapping["files"] if item["destination"].endswith((".gd", ".tscn"))}
    classes: dict[str, str] = {}
    for text in inputs.values():
        match = re.search(r"^class_name (\w+)$", text, re.MULTILINE)
        if match:
            classes[match[1]] = "Sheets_" + match[1]
    changes = {name: adapt(text, name, mapping["files"], classes) for name, text in inputs.items()}
    # Validate every input before touching any file; never overwrite later work.
    for name, text in changes.items():
        current = (root / name).read_text()
        allowed = (inputs[name], text) if args.write else (text,)
        if current not in allowed:
            raise ValueError(f"Unexpected source contents: {name}")
    if args.write:
        for name, text in changes.items():
            (root / name).write_text(text)
    print(f"Verified {len(changes)} adapted sources and {len(classes)} class prefixes")


if __name__ == "__main__":
    main()
