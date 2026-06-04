from __future__ import annotations

import importlib.util
import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import PluginCommandSpec, PluginManifestRecord

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - exercised on Python 3.10
    import tomli as tomllib


@dataclass
class PluginRuntimeContext:
    root: Path
    plugin_dir: Path
    manifest: PluginManifestRecord


def _builtin_plugins_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "plugins"


def _installed_plugins_dir(root: Path) -> Path:
    path = root / ".codetools" / "plugins"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _read_manifest(path: Path) -> dict[str, Any]:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def _manifest_from_dict(data: dict[str, Any], plugin_dir: Path, source: str) -> PluginManifestRecord:
    plugin = data.get("plugin", {})
    commands = [
        PluginCommandSpec(
            name=item["name"],
            description=item.get("description", ""),
            input_schema=item.get("input_schema", {}),
        )
        for item in data.get("commands", [])
    ]
    return PluginManifestRecord(
        plugin_id=plugin["id"],
        name=plugin.get("name", plugin["id"]),
        version=plugin.get("version", "0.1.0"),
        description=plugin.get("description", ""),
        entrypoint=plugin.get("entrypoint", "plugin.py:run_command"),
        platforms=plugin.get("platforms", []),
        capabilities=plugin.get("capabilities", []),
        requirements=plugin.get("requirements", []),
        instructions=plugin.get("instructions", ""),
        commands=commands,
        path=str(plugin_dir),
        source=source,
    )


def validate_plugin_dir(plugin_dir: Path) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    manifest_path = plugin_dir / "plugin.toml"
    if not manifest_path.exists():
        return {"valid": False, "errors": ["missing plugin.toml"], "warnings": []}
    data = _read_manifest(manifest_path)
    plugin = data.get("plugin")
    if not isinstance(plugin, dict):
        return {"valid": False, "errors": ["missing [plugin] table"], "warnings": []}
    for field_name in ["id", "name", "version", "description", "entrypoint"]:
        if not plugin.get(field_name):
            errors.append(f"missing plugin.{field_name}")
    entrypoint = plugin.get("entrypoint", "")
    module_path = entrypoint.split(":", 1)[0]
    if module_path and not (plugin_dir / module_path).exists():
        errors.append(f"entrypoint module missing: {module_path}")
    commands = data.get("commands", [])
    if not isinstance(commands, list) or not commands:
        warnings.append("no commands declared")
    else:
        for command in commands:
            if "name" not in command:
                errors.append("command missing name")
    return {"valid": not errors, "errors": errors, "warnings": warnings}


def _load_manifest(plugin_dir: Path, source: str) -> PluginManifestRecord:
    validation = validate_plugin_dir(plugin_dir)
    if not validation["valid"]:
        raise ValueError("; ".join(validation["errors"]))
    return _manifest_from_dict(_read_manifest(plugin_dir / "plugin.toml"), plugin_dir, source)


def list_plugins(root: Path) -> list[PluginManifestRecord]:
    manifests: dict[str, PluginManifestRecord] = {}
    for source, base in [("builtin", _builtin_plugins_dir()), ("installed", _installed_plugins_dir(root))]:
        if not base.exists():
            continue
        for child in sorted(base.iterdir()):
            if not child.is_dir():
                continue
            manifest_path = child / "plugin.toml"
            if not manifest_path.exists():
                continue
            try:
                manifest = _load_manifest(child, source)
            except Exception:
                continue
            manifests[manifest.plugin_id] = manifest
    return sorted(manifests.values(), key=lambda item: item.plugin_id)


def get_plugin(root: Path, plugin_id: str) -> PluginManifestRecord:
    for manifest in list_plugins(root):
        if manifest.plugin_id == plugin_id:
            return manifest
    raise KeyError(f"unknown plugin: {plugin_id}")


def install_plugin(root: Path, source_path: Path) -> PluginManifestRecord:
    source_dir = source_path.resolve()
    manifest = _load_manifest(source_dir, "external")
    target_dir = _installed_plugins_dir(root) / manifest.plugin_id
    if target_dir.exists():
        shutil.rmtree(target_dir)
    shutil.copytree(source_dir, target_dir)
    return _load_manifest(target_dir, "installed")


def init_plugin(target_dir: Path, plugin_id: str, name: str, description: str) -> list[Path]:
    target_dir.mkdir(parents=True, exist_ok=True)
    plugin_toml = f"""[plugin]
id = "{plugin_id}"
name = "{name}"
version = "0.1.0"
description = "{description}"
entrypoint = "plugin.py:run_command"
platforms = ["linux"]
capabilities = ["inspect"]
requirements = []
instructions = "Implement run_command in plugin.py. Declare commands in [[commands]]. Return compact JSON-serializable dicts."

[[commands]]
name = "describe"
description = "Return a basic description of this plugin."
input_schema = {{}}
"""
    plugin_py = """from __future__ import annotations

from typing import Any


def run_command(command: str, args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    if command == "describe":
        return {
            "plugin": context["manifest"]["plugin_id"],
            "command": command,
            "message": "Replace this with real plugin behavior.",
        }
    raise ValueError(f"unsupported command: {command}")
"""
    readme = f"# {name}\n\n{description}\n"
    created = [
        target_dir / "plugin.toml",
        target_dir / "plugin.py",
        target_dir / "README.md",
    ]
    created[0].write_text(plugin_toml, encoding="utf-8")
    created[1].write_text(plugin_py, encoding="utf-8")
    created[2].write_text(readme, encoding="utf-8")
    return created


def _load_entrypoint(plugin_dir: Path, entrypoint: str):
    module_part, callable_name = entrypoint.split(":", 1)
    module_path = plugin_dir / module_part
    spec = importlib.util.spec_from_file_location(f"sightline_plugin_{plugin_dir.name}", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load plugin entrypoint: {entrypoint}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        return getattr(module, callable_name)
    except AttributeError as exc:
        raise RuntimeError(f"plugin callable not found: {callable_name}") from exc


def run_plugin_command(root: Path, plugin_id: str, command: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
    manifest = get_plugin(root, plugin_id)
    plugin_dir = Path(manifest.path or "")
    callable_obj = _load_entrypoint(plugin_dir, manifest.entrypoint)
    context = {
        "root": str(root),
        "plugin_dir": str(plugin_dir),
        "manifest": manifest.to_dict(),
    }
    result = callable_obj(command, args or {}, context)
    if not isinstance(result, dict):
        return {"plugin": plugin_id, "command": command, "result": result}
    return result


def plugin_help(root: Path, plugin_id: str) -> dict[str, Any]:
    manifest = get_plugin(root, plugin_id)
    return {
        "plugin_id": manifest.plugin_id,
        "instructions": manifest.instructions,
        "commands": [command.to_dict() for command in manifest.commands],
        "requirements": manifest.requirements,
        "path": manifest.path,
        "source": manifest.source,
    }


def plugin_validate_target(root: Path, target: str) -> dict[str, Any]:
    candidate = Path(target)
    if candidate.exists():
        path = candidate.resolve()
        result = validate_plugin_dir(path)
        result["path"] = str(path)
        return result
    manifest = get_plugin(root, target)
    path = Path(manifest.path or "")
    result = validate_plugin_dir(path)
    result["path"] = str(path)
    result["plugin_id"] = manifest.plugin_id
    return result
