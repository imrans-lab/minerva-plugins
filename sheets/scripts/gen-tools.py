#!/usr/bin/env python3
"""Generate the Sheets manifest catalog from the frozen B0 tool definitions.

legacy-tools.json is the one legacy-to-canonical map, also used by B4 aliases.
The immutable source catalog is copied byte-for-byte from host59d73887 B0.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
from typing import TypeAlias, TypedDict

Json: TypeAlias = dict[str, "Json"] | list["Json"] | str | int | float | bool | None

FROZEN_SHA256 = "c2e363937f739230a294e4b629bf2eb5feef3f21882b930eabd48097b6740046"


class SourceTool(TypedDict):
    name: str
    description: str
    inputSchema: dict[str, Json]


class Tool(TypedDict):
    name: str
    executor: str
    description: str
    input_schema: dict[str, Json]


def rewrite(value: Json, aliases: dict[str, str]) -> Json:
    """Only tool identifiers change inside arbitrary JSON Schema/text values."""
    if isinstance(value, str):
        return re.sub(r"\bminerva_\w+\b", lambda match: aliases.get(match[0], match[0]), value)
    if isinstance(value, dict):
        return {key: rewrite(item, aliases) for key, item in value.items()}
    if isinstance(value, list):
        return [rewrite(item, aliases) for item in value]
    return value


def source_catalog(root: Path) -> tuple[list[SourceTool], dict[str, str]]:
    frozen = (root / "scripts/frozen-tools.json").read_bytes()
    if hashlib.sha256(frozen).hexdigest() != FROZEN_SHA256:
        raise ValueError("Frozen B0 catalog changed")
    source = json.loads(frozen)
    aliases = json.loads((root / "scripts/legacy-tools.json").read_text())
    if not isinstance(aliases, dict) or set(aliases) != {tool["name"] for tool in source}:
        raise ValueError("Map must cover exactly the frozen B0 names")
    if len(set(aliases.values())) != len(source) or not all(
            isinstance(name, str) and re.fullmatch(r"minerva_sheets_\w+", name)
            for name in aliases.values()):
        raise ValueError("Map targets must be unique canonical Sheets names")
    return source, aliases


def load_tools(root: Path) -> list[Tool]:
    source, aliases = source_catalog(root)
    return [Tool(name=aliases[tool["name"]],
                 executor="backend" if aliases[tool["name"]] == "minerva_sheets_create_editor" else "panel",
                 description=rewrite(tool["description"], aliases),
                 input_schema=rewrite(tool["inputSchema"], aliases)) for tool in source]


def schema_sample(schema: dict[str, Json]) -> Json:
    if "default" in schema:
        return schema["default"]
    enum = schema.get("enum")
    if isinstance(enum, list) and enum:
        return enum[0]
    return {"string": "schema fixture", "integer": 1, "number": 1.0,
            "boolean": False, "array": [], "object": {}}[str(schema.get("type"))]


def schema_argument(schema: dict[str, Json], value: Json) -> Json:
    """Generate fixture types from B0; semantic seeds supply ranges and contents."""
    kind = schema.get("type")
    if kind == "object":
        if not isinstance(value, dict) or not isinstance(schema.get("properties"), dict):
            raise ValueError("Object fixture needs the frozen schema properties")
        properties = schema["properties"]
        required = schema.get("required", [])
        if not isinstance(required, list) or set(value) - set(properties):
            raise ValueError("Fixture names do not match the frozen object schema")
        return {key: schema_argument(properties[key], value.get(key, schema_sample(properties[key])))
                for key in sorted(set(value) | set(required))}
    if kind == "array":
        if not isinstance(value, list) or not isinstance(schema.get("items"), dict):
            raise ValueError("Array fixture needs frozen item schema")
        return [schema_argument(schema["items"], item) for item in value]
    if kind == "string":
        if not isinstance(value, (str, int, float, bool)):
            raise ValueError("String fixture seed is not a scalar")
        generated = str(value).lower() if isinstance(value, bool) else str(value)
        if "enum" in schema and generated not in schema["enum"]:
            raise ValueError("Fixture string is outside the frozen enum")
        return generated
    if kind == "integer":
        if isinstance(value, bool):
            raise ValueError("Boolean seed is not an integer")
        generated = int(value)
        if isinstance(value, (float, bool)) and generated != value:
            raise ValueError("Fixture integer seed would lose information")
        return generated
    if kind == "number":
        if isinstance(value, bool):
            raise ValueError("Boolean seed is not a number")
        generated = float(value)
        if not math.isfinite(generated):
            raise ValueError("Fixture number is not finite")
        return generated
    if kind == "boolean" and isinstance(value, bool):
        return value
    raise ValueError(f"Unsupported fixture type/seed: {kind}, {value!r}")


def load_cases(root: Path) -> dict[str, list[Json]]:
    source, _aliases = source_catalog(root)
    schemas = {tool["name"]: tool["inputSchema"] for tool in source}
    seeds = json.loads((root / "tests/fixtures/tool-case-seeds.json").read_text())
    return {group: [[name, schema_argument(schemas[name], arguments)] for name, arguments in recipes]
            for group, recipes in seeds.items()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    path = root / "manifest.json"
    manifest = json.loads(path.read_text())
    tools = load_tools(root)
    cases = load_cases(root)
    case_path = root / "tests/fixtures/tool-cases.json"
    if args.check:
        if manifest.get("tools") != tools:
            raise SystemExit("Manifest tools differ from generated frozen B0 catalog")
        if not case_path.is_file() or json.loads(case_path.read_text()) != cases:
            raise SystemExit("Fixture calls differ from frozen-schema generation")
        print(f"PASS frozen catalog: {len(tools)} tools, one backend and {len(tools) - 1} panel executors")
    else:
        manifest["tools"] = tools
        path.write_text(json.dumps(manifest, indent=2) + "\n")
        case_path.write_text(json.dumps(cases, indent=2) + "\n")


if __name__ == "__main__":
    main()
