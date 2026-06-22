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


PLUGIN_DIRS = ["3d-gen", "agent-relay", "cad", "codetools", "drive", "movie-gen", "presentation", "scansort"]  # sorted

REGISTRY_VERSION = 2

REPO_OWNER = "imrans-lab"
REPO_NAME = "minerva-plugins"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}/main"
RELEASES_BASE = f"https://github.com/{REPO_OWNER}/{REPO_NAME}/releases/download"

# The full set of platform targets the marketplace understands. This is the
# valid superset / default only: the targets a given plugin actually ships are
# declared per-plugin via `release_targets` in its manifest.json (the single
# source of truth, kept in sync with that plugin's matrix workflow). A plugin
# that omits `release_targets` defaults to the full set.
TARGETS = ["linux-x86_64", "linux-arm64", "macos-universal", "windows-x86_64"]


def get_repo_root() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(out.stdout.strip())


def latest_tag_for(plugin_id: str, repo_root: Path):
    """Return the highest semver `<plugin_id>-v*` tag, or None.

    Skips tags containing the `-branch-` sentinel — those are auto-tagged
    test builds from non-main branches and should NOT advertise in the
    marketplace registry. Only main pushes and explicit tag pushes
    produce clean release tags that surface to end users.
    """
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
    for t in tags:
        if "-branch-" in t:
            continue
        return t
    return None


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

    # Tarball file naming uses the MANIFEST's version field, not the
    # version derived from the tag — the per-plugin workflows read
    # manifest.json at pack time. Track both so the client knows which
    # to use when constructing the download URL.
    manifest_version = manifest.get("version", "0.0.0")
    prefix = f"{plugin_id}-v"
    tag_version = tag[len(prefix):] if tag.startswith(prefix) else manifest_version

    rel_manifest = manifest_path.relative_to(repo_root).as_posix()

    # Targets this plugin actually builds. Declared per-plugin in manifest.json
    # as `release_targets`; absent that, default to the full TARGETS set. This
    # stops the registry advertising a tarball that was never built — e.g. cad
    # ships no linux-arm64 (cadquery-ocp has no aarch64 wheels), so emitting a
    # linux-arm64 URL would 404 at install time.
    targets = manifest.get("release_targets") or TARGETS
    unknown = [t for t in targets if t not in TARGETS]
    if unknown:
        raise SystemExit(
            f"{plugin_id}: manifest release_targets has unknown target(s) "
            f"{unknown}; valid targets are {TARGETS}"
        )

    # Build per-target download URLs deterministically from tag +
    # manifest version + target. Tarball naming convention is
    # `<id>-<manifest-version>-<target>.tar.gz` (see per-plugin workflow
    # Pack step). The release lives at
    # `<RELEASES_BASE>/<release_tag>/<tarball-filename>`.
    downloads = {
        target: f"{RELEASES_BASE}/{tag}/{plugin_id}-{manifest_version}-{target}.tar.gz"
        for target in targets
    }

    return {
        "id": plugin_id,
        "name": manifest.get("name", plugin_id),
        "version": tag_version,
        "manifest_version": manifest_version,
        "release_tag": tag,
        "manifest_url": f"{RAW_BASE}/{rel_manifest}",
        "downloads": downloads,
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
