#!/usr/bin/env python3
"""Generate registry.json at repo root from per-plugin manifest.json files.

Walks each known plugin directory (scansort/, cad/, presentation/),
reads manifest.json, finds the latest matching git tag of the form
`<id>-v*`. Emits registry.json that Minerva's marketplace consumes
to enumerate available plugins.

Plugins without any matching git tag are SKIPPED — the marketplace
should only advertise released plugins, not in-development ones.

Usage:
  python3 scripts/regen_registry.py

  Writes registry.json at repo root. Output is stable (sorted plugin
  list, no timestamp) so drift-check workflows can `git diff` it.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


PLUGIN_DIRS = ["cad", "presentation", "scansort"]  # sorted

REGISTRY_VERSION = 1

REPO_OWNER = "imrans-lab"
REPO_NAME = "minerva-plugins"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}/main"


def get_repo_root() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(out.stdout.strip())


def latest_tag_for(plugin_id: str, repo_root: Path):
    """Return the highest semver `<plugin_id>-v*` tag, or None."""
    out = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "tag",
            "-l",
            f"{plugin_id}-v*",
            "--sort=-v:refname",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    tags = [t for t in out.stdout.strip().split("\n") if t]
    return tags[0] if tags else None


def build_plugin_entry(plugin_dir: Path, repo_root: Path):
    manifest_path = plugin_dir / "manifest.json"
    if not manifest_path.exists():
        return None
    manifest = json.loads(manifest_path.read_text())
    plugin_id = manifest.get("id")
    if not plugin_id:
        return None
    tag = latest_tag_for(plugin_id, repo_root)
    if not tag:
        # Plugin not yet released. Skip from marketplace registry —
        # users only see things they can actually install.
        return None
    prefix = f"{plugin_id}-v"
    if tag.startswith(prefix):
        version = tag[len(prefix):]
    else:
        version = manifest.get("version", "0.0.0")
    rel_manifest = manifest_path.relative_to(repo_root).as_posix()
    return {
        "id": plugin_id,
        "name": manifest.get("name", plugin_id),
        "version": version,
        "release_tag": tag,
        "manifest_url": f"{RAW_BASE}/{rel_manifest}",
    }


def build_registry(repo_root: Path):
    plugins = []
    for name in PLUGIN_DIRS:
        entry = build_plugin_entry(repo_root / name, repo_root)
        if entry is not None:
            plugins.append(entry)
    plugins.sort(key=lambda p: p["id"])
    return {
        "registry_version": REGISTRY_VERSION,
        "plugins": plugins,
    }


def main(argv) -> int:
    repo_root = get_repo_root()
    registry = build_registry(repo_root)
    out = json.dumps(registry, indent=2) + "\n"
    out_path = repo_root / "registry.json"
    out_path.write_text(out)
    print(
        f"wrote {out_path} ({len(registry['plugins'])} plugin(s))",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
