"""All-or-nothing writes for order artifacts.

A HALF-WRITTEN ORDER PACKAGE IS WORSE THAN NONE. The files in a package are
cross-referenced — the manifest records a digest for every other file — so a
directory holding four of six artifacts is not a partial success, it is a
package whose manifest describes files that are not there. Somebody could still
upload it.

TWO SHAPES, because two situations are genuinely different:

* :func:`publish_directory` — the WHOLE PACKAGE. Every artifact is written into
  a staging directory nobody else can see, and the directory is then moved into
  place with a single ``rename``. That call either happens or does not, so a
  reader of the destination sees the complete package or no package. This is the
  contract B2 owns.
* :func:`write_files` — LOOSE FILES into a directory that already holds other
  things, where no directory-level rename is available. Every byte is written to
  a temporary neighbour first and nothing at the destination names is touched
  until all of them are on disk; the publishing step is then a sequence of
  renames, which are metadata operations that do not fail for the reasons the
  writes do (a full disk, a bad encoding, a caller error). A rename that fails
  anyway is unwound: names that did not exist before are removed again, so the
  directory is returned to its previous CONTENT even though the operation as a
  whole was not one instruction.

Neither helper creates a destination that a reader can observe half-built, and
neither leaves a temporary behind on the failure path.
"""

from __future__ import annotations

import os
import shutil
import uuid
from pathlib import Path
from typing import Mapping


class OrderWriteError(OSError):
    """A write refused by name. Carries the same ``io`` kind the worker's other
    disk failures report, so a surface handles one shape."""

    code = "order_write"


def _encode(content) -> bytes:
    return content if isinstance(content, bytes) else str(content).encode("utf-8")


def _write_one(path: Path, content) -> int:
    data = _encode(content)
    with open(path, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    return len(data)


def _sync_dir(directory: Path) -> None:
    """Make the directory's own entries durable. Renaming a file is only half
    the story on a crash; the parent's entry has to reach the disk too."""
    try:
        fd = os.open(str(directory), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _check_names(files: Mapping[str, object]) -> None:
    """Every key must be a plain file name. A key carrying a separator would
    write outside the directory the caller named."""
    for name in files:
        if not isinstance(name, str) or not name or name in (".", ".."):
            raise OrderWriteError(f"refusing to write an artifact named {name!r}")
        if os.path.sep in name or (os.path.altsep and os.path.altsep in name):
            raise OrderWriteError(
                f"refusing to write artifact {name!r}: an artifact name is a plain "
                f"file name, not a path")


def write_files(directory, files: Mapping[str, object]) -> list[dict]:
    """Write every artifact into an EXISTING-OR-CREATED directory, or leave the
    directory's contents as they were.

    Returns ``[{path, bytes_written}]`` in the caller's key order — the same
    shape every other worker disk write reports.
    """
    _check_names(files)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex[:12]
    staged: list[tuple[Path, Path, int, bool]] = []
    try:
        for name, content in files.items():
            final = directory / name
            temp = directory / f".{name}.{token}.part"
            written = _write_one(temp, content)
            staged.append((temp, final, written, final.exists()))
    except OSError as exc:
        for temp, _, _, _ in staged:
            temp.unlink(missing_ok=True)
        raise OrderWriteError(f"failed to write to {directory}: {exc}") from exc

    published: list[tuple[Path, bool]] = []
    try:
        for temp, final, _, existed in staged:
            os.replace(temp, final)
            published.append((final, existed))
    except OSError as exc:
        for final, existed in published:
            if not existed:
                final.unlink(missing_ok=True)
        for temp, _, _, _ in staged:
            temp.unlink(missing_ok=True)
        raise OrderWriteError(f"failed to write to {directory}: {exc}") from exc
    _sync_dir(directory)
    return [{"path": str(final), "bytes_written": written}
            for _, final, written, _ in staged]


def publish_directory(parent, name: str, files: Mapping[str, object], *,
                      overwrite: bool = False) -> list[dict]:
    """Write a whole package directory into ``parent`` as one visible step.

    The destination appears complete or not at all. With ``overwrite`` the
    previous directory is moved aside first and removed only after the new one
    is in place, so a failure in between restores what was there.
    """
    _check_names(files)
    parent = Path(parent)
    parent.mkdir(parents=True, exist_ok=True)
    destination = parent / name
    if destination.exists() and not overwrite:
        raise OrderWriteError(
            f"{destination} already exists; refusing to overwrite an order "
            f"package that may already have been uploaded. Remove it, choose "
            f"another directory, or ask for an overwrite")

    token = uuid.uuid4().hex[:12]
    staging = parent / f".{name}.staging-{token}"
    displaced = parent / f".{name}.replaced-{token}"
    moved = False
    try:
        staging.mkdir(parents=True)
        written = []
        for artifact, content in files.items():
            written.append({"name": artifact,
                            "bytes_written": _write_one(staging / artifact, content)})
        _sync_dir(staging)
        if destination.exists():
            os.rename(destination, displaced)
            moved = True
        os.rename(staging, destination)
    except OSError as exc:
        shutil.rmtree(staging, ignore_errors=True)
        if moved and not destination.exists():
            try:
                os.rename(displaced, destination)
            except OSError:
                pass
        else:
            shutil.rmtree(displaced, ignore_errors=True)
        raise OrderWriteError(f"failed to write order package to {parent}: {exc}") from exc
    if moved:
        shutil.rmtree(displaced, ignore_errors=True)
    _sync_dir(parent)
    return [{"path": str(destination / item["name"]),
             "bytes_written": item["bytes_written"]} for item in written]
