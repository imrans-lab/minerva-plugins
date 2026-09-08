#!/usr/bin/env python3
"""Generate the marketplace registry from tagged release manifests.

Run after a successful release: git fetch --tags && python3 scripts/regen_registry.py
Use --check to validate the committed release selections without advancing them.
Use --published with --check to verify GitHub has every advertised asset (gh required).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


PLUGIN_DIRS = ["3d-gen", "agent-relay", "cad", "codetools", "drive", "movie-gen", "pcb", "presentation", "scansort"]  # sorted

REGISTRY_VERSION = 2

REPO_OWNER = "imrans-lab"
REPO_NAME = "minerva-plugins"
RAW_BASE = f"https://raw.githubusercontent.com/{REPO_OWNER}/{REPO_NAME}"
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


def build_plugin_entry(plugin_dir: Path, repo_root: Path, tag: str | None = None):
    manifest_path = plugin_dir / "manifest.json"
    if not manifest_path.exists():
        return None
    plugin_id = json.loads(manifest_path.read_text())["id"]
    tag = tag or latest_tag_for(plugin_id, repo_root)
    if not tag:
        return None
    if not tag.startswith(f"{plugin_id}-v") or "-branch-" in tag:
        raise ValueError(f"{plugin_id}: invalid marketplace release tag {tag!r}")
    rel_manifest = (plugin_dir / "manifest.json").relative_to(repo_root).as_posix()
    result = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"refs/tags/{tag}:{rel_manifest}"],
        check=True, capture_output=True, text=True,
    )
    manifest = json.loads(result.stdout)
    if manifest.get("id") != plugin_id:
        raise ValueError(f"{tag}: manifest id does not match {plugin_id}")

    # Tarball file naming uses the MANIFEST's version field, not the
    # version derived from the tag — the per-plugin workflows read
    # manifest.json at pack time. Track both so the client knows which
    # to use when constructing the download URL.
    manifest_version = manifest.get("version", "0.0.0")
    prefix = f"{plugin_id}-v"
    tag_version = tag[len(prefix):] if tag.startswith(prefix) else manifest_version

    if tag_version != manifest_version:
        raise ValueError(f"{tag}: manifest version is {manifest_version}, not {tag_version}")

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
        "manifest_url": f"{RAW_BASE}/{tag}/{rel_manifest}",
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


def check_registry(repo_root: Path, registry: dict, published: bool = False):
    if registry.get("registry_version") != REGISTRY_VERSION:
        raise ValueError("unsupported registry_version")
    directories = {
        json.loads((repo_root / name / "manifest.json").read_text())["id"]: repo_root / name
        for name in PLUGIN_DIRS if (repo_root / name / "manifest.json").exists()
    }
    seen = set()
    for entry in registry["plugins"]:
        plugin_id = entry["id"]
        if plugin_id not in directories or plugin_id in seen:
            raise ValueError(f"unknown or duplicate plugin: {plugin_id}")
        seen.add(plugin_id)
        expected = build_plugin_entry(directories[plugin_id], repo_root, entry["release_tag"])
        if entry != expected:
            raise ValueError(f"{plugin_id}: registry differs from its tagged manifest; regenerate after release")
        if published:
            result = subprocess.run(
                ["gh", "api", f"repos/{REPO_OWNER}/{REPO_NAME}/releases/tags/{entry['release_tag']}"],
                check=True, capture_output=True, text=True,
            )
            release = json.loads(result.stdout)
            if release.get("draft") or release.get("prerelease"):
                raise ValueError(f"{plugin_id}: release is not published for the marketplace")
            assets = {a["browser_download_url"]: a for a in release["assets"]}
            for url in entry["downloads"].values():
                asset = assets.get(url)
                if not asset or asset["size"] <= 0 or asset["state"] != "uploaded":
                    raise ValueError(f"{plugin_id}: published asset missing or incomplete: {url}")


def main(argv) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--published", action="store_true")
    args = parser.parse_args(argv[1:])
    if args.published and not args.check:
        parser.error("--published requires --check")
    repo_root = get_repo_root()
    out_path = repo_root / "registry.json"
    if args.check:
        check_registry(repo_root, json.loads(out_path.read_text()), args.published)
        print("registry release selections verified")
    else:
        registry = build_registry(repo_root)
        out_path.write_text(json.dumps(registry, indent=2) + "\n")
        print(f"wrote {out_path} ({len(registry['plugins'])} plugin(s))", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
