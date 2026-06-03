from __future__ import annotations

from pathlib import Path

from .models import RepoMapNode


def build_repo_map(root: Path, max_depth: int = 2) -> RepoMapNode:
    def build(path: Path, depth: int) -> RepoMapNode:
        kind = "dir" if path.is_dir() else "file"
        node = RepoMapNode(path=str(path.relative_to(root)) if path != root else ".", kind=kind)
        if not path.is_dir() or depth >= max_depth:
            return node
        for child in sorted(path.iterdir(), key=lambda entry: (not entry.is_dir(), entry.name)):
            if child.name.startswith("."):
                continue
            node.children.append(build(child, depth + 1))
        return node

    return build(root, 0)

