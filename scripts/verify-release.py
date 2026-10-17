#!/usr/bin/env python3
"""Verify a published plugin release without extracting or executing its payloads.

Use --local-dir for an offline folder containing source.json, release.json and
the archives. Docket's separate repository, sidecars and manifest transform
are outside this verifier's v1 contract.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from packed_manifest import verify_packed_manifest
from regen_registry import REPO_NAME, REPO_OWNER, TARGETS


@dataclass(frozen=True)
class Asset:
    name: str
    size: int
    digest: str


@dataclass(frozen=True)
class Release:
    tag: str
    assets: list[Asset]


@dataclass(frozen=True)
class AssetReceipt:
    name: str
    sha256: str
    size: int
    checksummed_files: int


def read_object(path: Path) -> dict[str, Any]:
    """Manifests and GitHub JSON are open schemas; validate used fields below."""
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path.name}: expected a JSON object")
    return value


def read_release(path: Path) -> Release:
    data = read_object(path)
    if data.get("draft") is not False or data.get("prerelease") is not False:
        raise ValueError("release must be published and stable")
    if not isinstance(data.get("tag_name"), str) or not isinstance(data.get("assets"), list):
        raise TypeError("release.json: expected tag_name and assets")
    assets = []
    for item in data["assets"]:
        if (not isinstance(item, dict) or not isinstance(item.get("name"), str)
                or type(item.get("size")) is not int or item["size"] <= 0
                or not isinstance(item.get("digest"), str)):
            raise ValueError("release.json: each asset needs name, positive size and GitHub digest")
        assets.append(Asset(item["name"], item["size"], item["digest"]))
    return Release(data["tag_name"], assets)


def expected_assets(plugin_id: str, tag: str, source: dict[str, Any]) -> set[str]:
    if plugin_id == "docket":
        raise ValueError("Docket uses a separate release lane; it is out of scope for v1")
    if (source.get("id") != plugin_id or not isinstance(source.get("version"), str)
            or tag != f"{plugin_id}-v{source['version']}"):
        raise ValueError("tag, plugin id and source manifest version must agree")
    if not isinstance(source.get("host_api_version"), str) or not source["host_api_version"]:
        raise ValueError("source manifest must declare host_api_version")
    targets = source.get("release_targets") or TARGETS
    if (not isinstance(targets, list) or any(target not in TARGETS for target in targets)
            or len(targets) != len(set(targets))):
        raise ValueError("source manifest has invalid release_targets")
    return {f"{plugin_id}-{source['version']}-{target}.tar.gz" for target in targets}


def check_asset_set(release: Release, tag: str, expected: set[str]) -> None:
    names = [asset.name for asset in release.assets]
    if release.tag != tag:
        raise ValueError(f"release tag is {release.tag}, expected {tag}")
    if set(names) != expected or len(names) != len(expected):
        raise ValueError(f"release target set differs: expected {sorted(expected)}, got {sorted(names)}")


def verify_archive(path: Path, asset: Asset, source: dict[str, Any]) -> AssetReceipt:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if asset.digest != "sha256:" + digest or path.stat().st_size != asset.size:
        raise ValueError(f"{asset.name}: GitHub asset digest or size mismatch")
    hashes: dict[str, str] = {}
    payload: dict[str, bytes] = {}
    # Match the packers' find -type f inventory. Links/directories are never extracted.
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            name = member.name.removeprefix("./")
            if name in hashes:
                raise ValueError(f"{asset.name}: duplicate file {name}")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError(f"{asset.name}: cannot read {name}")
            hasher = hashlib.sha256()
            retained = []
            while block := stream.read(1024 * 1024):
                hasher.update(block)
                if name in ("manifest.json", "SHA256SUMS"):
                    retained.append(block)
            hashes[name] = hasher.hexdigest()
            if retained:
                payload[name] = b"".join(retained)
    if not {"manifest.json", "SHA256SUMS"} <= payload.keys():
        raise ValueError(f"{asset.name}: missing manifest.json or SHA256SUMS")
    sums: dict[str, str] = {}
    for line in payload["SHA256SUMS"].decode("utf-8").splitlines():
        expected, name = line.split(maxsplit=1)
        name = name.lstrip(" *").removeprefix("./")
        if name in sums:
            raise ValueError(f"{asset.name}: duplicate SHA256SUMS entry {name}")
        sums[name] = expected
    if set(sums) != set(hashes) - {"SHA256SUMS"}:
        raise ValueError(f"{asset.name}: SHA256SUMS inventory mismatch")
    if any(hashes[name] != expected for name, expected in sums.items()):
        raise ValueError(f"{asset.name}: internal SHA256SUMS digest mismatch")
    packed = json.loads(payload["manifest.json"].decode("utf-8"))
    verify_packed_manifest(source, packed)
    return AssetReceipt(asset.name, digest, asset.size, len(sums))


def verify_release(plugin_id: str, tag: str, directory: Path) -> list[AssetReceipt]:
    source = read_object(directory / "source.json")
    release = read_release(directory / "release.json")
    check_asset_set(release, tag, expected_assets(plugin_id, tag, source))
    return [verify_archive(directory / asset.name, asset, source) for asset in release.assets]


def fetch_release(root: Path, plugin_id: str, tag: str, directory: Path) -> str:
    if plugin_id == "docket":
        raise ValueError("Docket uses a separate release lane; it is out of scope for v1")
    paths = [path for path in root.glob("*/manifest.json")
             if read_object(path).get("id") == plugin_id]
    if len(paths) != 1:
        raise ValueError(f"expected one plugin directory for id {plugin_id!r}, found {len(paths)}")
    source_path = paths[0].relative_to(root).as_posix()
    source = subprocess.check_output(
        ["git", "-C", str(root), "show", f"refs/tags/{tag}:{source_path}"], encoding="utf-8")
    commit = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", f"refs/tags/{tag}^{{commit}}"], encoding="utf-8").strip()
    repository = f"{REPO_OWNER}/{REPO_NAME}"
    remote = json.loads(subprocess.check_output(
        ["gh", "api", f"repos/{repository}/git/ref/tags/{tag}"], encoding="utf-8"))["object"]
    while remote["type"] == "tag":
        remote = json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{repository}/git/tags/{remote['sha']}"], encoding="utf-8"))["object"]
    if remote["type"] != "commit" or remote["sha"] != commit:
        raise ValueError("local tag and GitHub tag commits differ; fetch the correct tag first")
    metadata = subprocess.check_output(
        ["gh", "api", f"repos/{repository}/releases/tags/{tag}"], encoding="utf-8")
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "source.json").write_text(source, encoding="utf-8")
    (directory / "release.json").write_text(metadata, encoding="utf-8")
    release = read_release(directory / "release.json")
    check_asset_set(release, tag, expected_assets(plugin_id, tag, json.loads(source)))
    for asset in release.assets:
        subprocess.run(["gh", "release", "download", tag, "--repo", repository,
                        "--pattern", asset.name, "--dir", str(directory), "--skip-existing"],
                       check=True)
    return commit


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin_id")
    parser.add_argument("tag")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--local-dir", type=Path, help="verify saved inputs; no network or Git calls")
    modes.add_argument("--download-dir", type=Path, help="retain fetched inputs here (default: temporary)")
    args = parser.parse_args()
    try:
        # TemporaryDirectory owns only its newly-created directory, never the caller's files.
        with tempfile.TemporaryDirectory(prefix="minerva-verify-release-") as temporary:
            directory = args.local_dir or args.download_dir or Path(temporary)
            commit = None
            if args.local_dir is None:
                commit = fetch_release(Path(__file__).resolve().parents[1],
                                       args.plugin_id, args.tag, directory)
            receipts = verify_release(args.plugin_id, args.tag, directory)
        print(json.dumps({"plugin_id": args.plugin_id, "tag": args.tag, "commit": commit,
                          "mode": "offline" if args.local_dir else "github", "qualified": True,
                          "assets": [asdict(receipt) for receipt in receipts]}, indent=2))
        return 0
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError,
            subprocess.CalledProcessError) as error:
        print(f"FAIL {args.plugin_id} {args.tag}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
