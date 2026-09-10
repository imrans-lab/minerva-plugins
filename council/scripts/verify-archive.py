#!/usr/bin/env python3
"""Check that a Council marketplace archive is installable and intact.

    scripts/verify-archive.py dist/council-0.1.0-linux-x86_64.tar.gz
    scripts/verify-archive.py dist/... --smoke ../scripts/smoke/mcp_smoke.py

Run from the plugin directory (the one holding manifest.json), which is the
reference the packed manifest is compared against.

This is the archive's only gate, so it carries its own falsifiers: after the
extracted tree checks out it corrupts one byte and deletes one file, and fails
if either goes undetected. A checksum step that cannot be shown to fail is not
evidence that the checksums were read.

What it decides, in order:

1. Every member extracts inside the destination, at the archive root — the host
   extracts straight into the plugin directory, so a wrapping folder or a `..`
   escape is an install that lands in the wrong place.
2. The packed manifest is the repository manifest with `setup` removed and
   nothing else changed.
3. Every path the manifest declares — the backend entrypoint, the panel's scene
   and scripts — is present, and the entrypoint is executable.
4. The page, the schemas, the shipped councils, the README, the docs and the
   licence are present, and the panel's build sources and screenshot harness
   are not.
5. SHA256SUMS names exactly the other files and every digest matches.
6. A corrupted file, a missing file and a member that walks out of the
   destination are all refused — the falsifiers for 1 and 5.
7. With --smoke, the packed binary answers MCP initialize + tools/list from a
   directory holding nothing but the archive, with no toolchain on PATH.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


class Failure(Exception):
    pass


SUMS = "SHA256SUMS"
# The panel's maintainable sources and its recorded-envelope harness. About
# 3 MB, mostly screenshots, that the panel never reads: the wrapper stages
# ui/panel.html and the manifest declares only that page, the scene and the
# four scripts.
EXCLUDED_PREFIXES = ("ui/src/", "ui/tests/")
# The only document with a reader on an installed machine.
SHIPPED_DOCS = {"docs/architecture.md"}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def archive_name(raw: str) -> str:
    """`raw` as a plugin-relative path, or raise.

    tar writes members as "./ui/panel.html". Only that one leading "./" is a
    prefix to drop — `lstrip("./")` strips CHARACTERS, so it turns "../evil"
    into "evil", which then passes any containment check while the member still
    carries its original name, and mangles a root dotfile into a different file
    entirely. Strip the prefix once, then reject anything that is absolute or
    walks upward, judged on the path's own components rather than on substrings.
    """
    if raw.startswith("/"):
        raise Failure(f"{raw!r} would extract outside the plugin directory")
    name = raw[2:] if raw.startswith("./") else raw
    name = name.rstrip("/")
    parts = PurePosixPath(name).parts if name else ()
    if not parts:
        return ""  # the archive root itself, which tar writes as "."
    if ".." in parts:
        raise Failure(f"{raw!r} would extract outside the plugin directory")
    return str(PurePosixPath(name))


def extract(archive: Path, into: Path) -> list:
    """Extract under vetted names, refusing any member that escapes `into`."""
    names = []
    wanted = []
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            name = archive_name(member.name)
            if not name:
                continue
            if not (member.isdir() or member.isfile()):
                raise Failure(f"{member.name}: archives ship regular files only")
            # Extraction uses the NAME THAT WAS VETTED, not the one in the
            # header: rewriting it here is what makes the check above binding.
            member.name = name
            wanted.append(member)
            if member.isfile():
                names.append(name)
        # Members were checked above, so the permissive filter is deliberate:
        # the "data" filter clamps modes and would strip the entrypoint's
        # executable bit, which is one of the things being verified.
        kwargs = {"filter": "fully_trusted"} if sys.version_info >= (3, 12) else {}
        tar.extractall(into, members=wanted, **kwargs)
    for name in names:
        landed = (into / name).resolve()
        if not str(landed).startswith(str(into.resolve()) + os.sep):
            raise Failure(f"{name} landed outside the plugin directory")
    return names


def declared_paths(manifest: dict) -> list:
    """The files the manifest itself names, which the host resolves at mount."""
    paths = [manifest["backend"]["entrypoint"].lstrip("./")]
    for panel in manifest.get("ui", {}).get("panels", []):
        paths.append(panel["entry_scene"])
        paths.extend(panel.get("scripts", []))
    return paths


def check_layout(root: Path, names: list, repo_manifest: dict) -> None:
    present = set(names)

    packed_path = root / "manifest.json"
    if not packed_path.exists():
        raise Failure("the archive has no manifest.json at its root")
    packed = json.loads(packed_path.read_text())
    if "setup" in packed:
        raise Failure("the packed manifest still carries the source-lane `setup` stanza")
    expected = {k: v for k, v in repo_manifest.items() if k != "setup"}
    if packed != expected:
        differing = sorted(
            k for k in set(expected) | set(packed) if expected.get(k) != packed.get(k)
        )
        raise Failure(f"the packed manifest differs from the repository manifest in {differing}")

    for path in declared_paths(packed):
        if path not in present:
            raise Failure(f"the manifest declares {path}, which the archive does not carry")

    entrypoint = root / packed["backend"]["entrypoint"].lstrip("./")
    if not os.access(entrypoint, os.X_OK):
        raise Failure(f"{entrypoint.name} is not executable; the host would fail to start it")

    for path in ("ui/panel.html", "README.md", "LICENSE.md"):
        if path not in present:
            raise Failure(f"the archive does not carry {path}")
    for directory in ("schemas", "presets"):
        if not any(n.startswith(directory + "/") for n in present):
            raise Failure(f"the archive carries nothing under {directory}/")
    # Stated exactly, not as a floor. The rest of docs/ is maintainer text —
    # a validation record, a packaging procedure — that has no reader on an
    # installed machine, so "carries something" would not be the check.
    docs = {n for n in present if n.startswith("docs/")}
    if docs != SHIPPED_DOCS:
        raise Failure(f"docs/ should be exactly {sorted(SHIPPED_DOCS)}, and is {sorted(docs)}")
    for name in sorted(present):
        if name.startswith(EXCLUDED_PREFIXES):
            raise Failure(f"{name} is a build source and must not ship")
        if name.endswith(".go"):
            raise Failure(f"{name} is backend source and must not ship")


def read_sums(root: Path) -> dict:
    sums = {}
    for line in (root / SUMS).read_text().splitlines():
        if not line.strip():
            continue
        parts = line.split("  ", 1)
        if len(parts) != 2 or len(parts[0]) != 64:
            raise Failure(f"{SUMS} line is not `<sha256>  <path>`: {line!r}")
        sums[parts[1]] = parts[0]
    return sums


def check_sums(root: Path, names: list) -> list:
    """Return the files whose digest disagrees with SHA256SUMS, or are absent."""
    if SUMS not in names:
        raise Failure(f"the archive has no {SUMS}")
    sums = read_sums(root)
    covered = set(sums)
    shipped = {n for n in names if n != SUMS}
    if covered != shipped:
        missing = sorted(shipped - covered)
        extra = sorted(covered - shipped)
        raise Failure(f"{SUMS} does not cover every file: uncovered={missing} unknown={extra}")
    bad = []
    for name, want in sorted(sums.items()):
        path = root / name
        if not path.exists() or digest(path) != want:
            bad.append(name)
    return bad


def check_falsifiers(root: Path, names: list) -> None:
    """Prove the checksum step can fail, on the two ways an asset goes wrong."""
    victim = root / sorted(n for n in names if n != SUMS)[0]
    original = victim.read_bytes()

    flipped = bytearray(original)
    flipped[0] ^= 0xFF
    victim.write_bytes(bytes(flipped))
    if not check_sums(root, names):
        raise Failure("a corrupted file passed the checksum step")

    victim.unlink()
    if not check_sums(root, names):
        raise Failure("a missing file passed the checksum step")

    victim.write_bytes(original)
    if check_sums(root, names):
        raise Failure("the restored file still fails its checksum")


def check_escape_is_refused() -> None:
    """Prove the extraction check can fail, on a member that walks upward.

    Built here rather than fixtured: an archive that escapes its destination is
    exactly the thing no committed file should be. `..` is the case a naive
    `lstrip("./")` silently rewrites into a valid-looking name, so it is the one
    worth holding.
    """
    body = b"evil"
    with tempfile.TemporaryDirectory() as temp:
        hostile = Path(temp) / "hostile.tar.gz"
        for name in ("../evil", "./../evil", "/etc/evil", "ui/../../evil"):
            # The member is built by hand rather than with tar.add, which
            # normalises an absolute arcname into a relative one and would
            # quietly turn that case into a harmless fixture.
            info = tarfile.TarInfo(name)
            info.size = len(body)
            with tarfile.open(hostile, "w:gz") as tar:
                tar.addfile(info, io.BytesIO(body))
            into = Path(temp) / "into"
            into.mkdir(exist_ok=True)
            try:
                extract(hostile, into)
            except Failure:
                continue
            raise Failure(f"a member named {name!r} was extracted instead of refused")


def check_smoke(root: Path, manifest: dict, smoke: Path) -> None:
    """Start the packed binary where a marketplace user would: an extracted
    archive, nothing else in the directory, and no Go or Node on PATH."""
    entrypoint = root / manifest["backend"]["entrypoint"].lstrip("./")
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", str(root)),
        "PLUGIN_SMOKE_TIMEOUT_SECONDS": os.environ.get("PLUGIN_SMOKE_TIMEOUT_SECONDS", "30"),
    }
    # A toolchain on the base system PATH weakens this check but does not
    # invalidate it — what the marketplace claim rests on is that the binary
    # needs no checkout and calls no compiler, and it is still being started
    # from a directory holding nothing but the extracted archive. Failing here
    # would red the package leg over a runner image's contents, which is not a
    # fact about Council, so it is reported and the smoke goes ahead.
    for tool in ("go", "node"):
        if shutil.which(tool, path=env["PATH"]):
            print(f"NOTE: {tool} is present on {env['PATH']}; the smoke still runs from an "
                  f"empty directory, but PATH is not proving toolchain independence here.",
                  file=sys.stderr)
    # The smoke is handed an ABSOLUTE path: it launches the binary without a
    # shell, and a bare relative name is not searched in the working directory.
    # Independence is carried by cwd and the reduced PATH, not by the spelling.
    result = subprocess.run(
        [sys.executable, str(smoke.resolve()), str(entrypoint.resolve())],
        cwd=root, env=env, capture_output=True, text=True,
    )
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise Failure(f"the packed binary did not answer tools/list (exit {result.returncode})")


def main(argv) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--smoke", type=Path, help="path to scripts/smoke/mcp_smoke.py")
    args = parser.parse_args(argv[1:])

    repo_manifest = json.loads(Path("manifest.json").read_text())
    try:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "plugin"
            root.mkdir()
            names = extract(args.archive.resolve(), root)
            check_layout(root, names, repo_manifest)
            bad = check_sums(root, names)
            if bad:
                raise Failure(f"checksum mismatch: {bad}")
            check_falsifiers(root, names)
            check_escape_is_refused()
            if args.smoke:
                check_smoke(root, repo_manifest, args.smoke)
    except Failure as failure:
        print(f"ARCHIVE FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"ARCHIVE OK: {args.archive.name} — {len(names)} files, checksums and extraction verified and falsified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
