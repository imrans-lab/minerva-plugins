from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import subprocess

from .models import RepoFile


LANGUAGE_BY_EXTENSION = {
    ".py": "python",
    ".rs": "rust",
    ".go": "go",
    ".js": "javascript",
    ".jsx": "javascript",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".gd": "gdscript",
    ".md": "markdown",
    ".json": "json",
    ".toml": "toml",
    ".yml": "yaml",
    ".yaml": "yaml",
    ".sh": "shell",
}


def detect_language(path: Path) -> str:
    return LANGUAGE_BY_EXTENSION.get(path.suffix.lower(), "unknown")


def is_probably_binary(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            chunk = handle.read(1024)
    except OSError:
        return True
    return b"\x00" in chunk


def _normalize_extension(extension: str | None) -> str | None:
    if not extension:
        return None
    return extension if extension.startswith(".") else f".{extension}"


def _iter_candidate_paths_fallback(root: Path, extension: str | None = None) -> list[Path]:
    if extension:
        pattern = f"*{extension}"
        return sorted(path for path in root.rglob(pattern) if path.is_file())
    return sorted(path for path in root.rglob("*") if path.is_file())


def iter_candidate_paths(root: Path, extension: str | None = None, include_hidden: bool = False) -> list[Path]:
    normalized_extension = _normalize_extension(extension)
    command = ["rg", "--files"]
    if include_hidden:
        command.append("--hidden")
    if normalized_extension:
        command.extend(["-g", f"*{normalized_extension}"])
    try:
        completed = subprocess.run(
            command,
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return _iter_candidate_paths_fallback(root, extension=normalized_extension)
    if completed.returncode != 0:
        return _iter_candidate_paths_fallback(root, extension=normalized_extension)
    return sorted(root / line for line in completed.stdout.splitlines() if line)


def list_repo_files(root: Path) -> list[RepoFile]:
    results: list[RepoFile] = []
    for path in iter_candidate_paths(root):
        if is_probably_binary(path):
            continue
        stat = path.stat()
        results.append(
            RepoFile(
                path=str(path.relative_to(root)),
                size=stat.st_size,
                mtime=stat.st_mtime,
                extension=path.suffix.lower(),
                language=detect_language(path),
            )
        )
    return results


def list_repo_files_filtered(
    root: Path,
    *,
    extension: str | None = None,
    size_gt: int | None = None,
    size_lt: int | None = None,
    path_contains: str | None = None,
    include_hidden: bool = False,
    mtime_after: float | None = None,
    mtime_before: float | None = None,
) -> list[RepoFile]:
    results: list[RepoFile] = []
    for path in iter_candidate_paths(root, extension=extension, include_hidden=include_hidden):
        relative = str(path.relative_to(root))
        if not include_hidden and relative.split("/", 1)[0].startswith("."):
            continue
        if path_contains and path_contains not in relative:
            continue
        stat = path.stat()
        if size_gt is not None and stat.st_size <= size_gt:
            continue
        if size_lt is not None and stat.st_size >= size_lt:
            continue
        if mtime_after is not None and stat.st_mtime <= mtime_after:
            continue
        if mtime_before is not None and stat.st_mtime >= mtime_before:
            continue
        # For extension-filtered queries on obviously text-like files, skip binary sniffing.
        if extension is None and is_probably_binary(path):
            continue
        results.append(
            RepoFile(
                path=relative,
                size=stat.st_size,
                mtime=stat.st_mtime,
                extension=path.suffix.lower(),
                language=detect_language(path),
            )
        )
    return results


def summarize_repo_files(
    files: list[RepoFile],
    *,
    group_by: str,
    exclude: set[str] | None = None,
    require_nested: bool = False,
    exclude_hidden: bool = True,
    sort_by: str = "files",
) -> list[dict[str, object]]:
    counts: dict[str, int] = defaultdict(int)
    sizes: dict[str, int] = defaultdict(int)

    for item in files:
        parts = item.path.split("/")
        if require_nested and len(parts) < 2:
            continue

        if group_by == "topdir":
            key = parts[0]
        elif group_by == "extension":
            key = item.extension or "<none>"
        elif group_by == "language":
            key = item.language
        else:
            raise ValueError(f"unsupported group_by: {group_by}")

        if exclude_hidden and key.startswith("."):
            continue
        if exclude and key in exclude:
            continue

        counts[key] += 1
        sizes[key] += item.size

    rows = [
        {"group": key, "files": counts[key], "size": sizes[key]}
        for key in counts
    ]
    if sort_by == "files":
        rows.sort(key=lambda row: (row["files"], row["size"], row["group"]))
    elif sort_by == "size":
        rows.sort(key=lambda row: (row["size"], row["files"], row["group"]))
    elif sort_by == "name":
        rows.sort(key=lambda row: row["group"])
    else:
        raise ValueError(f"unsupported sort_by: {sort_by}")
    return rows
