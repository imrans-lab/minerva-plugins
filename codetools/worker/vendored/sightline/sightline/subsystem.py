from __future__ import annotations

from pathlib import Path

from .files import list_repo_files_filtered
from .models import SubsystemCandidate, SubsystemReport
from .search import SearchOptions, search_code


def _aliases(token: str) -> list[str]:
    variants = {
        token,
        token.replace("-", "_"),
        token.replace("_", "-"),
    }
    compact = token.replace("-", "").replace("_", "")
    if compact and compact != token:
        variants.add(compact)
    return [value for value in variants if value]


def _role_for_path(path: str) -> str:
    lowered = path.lower()
    filename = Path(path).name
    if "test" in lowered.split("/") or filename.startswith("test_") or "-test." in filename:
        return "test"
    if lowered.startswith("docs/") or lowered.endswith(".md"):
        return "doc"
    if filename == "Dockerfile" or "docker-compose" in filename or lowered.endswith((".yml", ".yaml", ".json", ".toml")):
        return "config"
    if lowered.startswith("infrastructure/services/") or lowered.startswith("mobile_app/"):
        return "impl"
    return "code"


def build_subsystem_report(root: Path, token: str, limit: int = 20) -> SubsystemReport:
    aliases = _aliases(token)
    candidates: dict[str, SubsystemCandidate] = {}

    for alias in aliases:
        for repo_file in list_repo_files_filtered(root, path_contains=alias, include_hidden=False):
            evidence = [f"path contains {alias}"]
            role = _role_for_path(repo_file.path)
            score = 1.2 if alias == token else 1.0
            if role == "impl":
                score += 0.5
            elif role == "test":
                score += 0.4
            existing = candidates.get(repo_file.path)
            if existing is None or score > existing.score:
                candidates[repo_file.path] = SubsystemCandidate(
                    path=repo_file.path,
                    role=role,
                    score=score,
                    evidence=evidence,
                    source="path",
                )

    for alias in aliases:
        hits = search_code(
            root,
            alias,
            limit=max(limit * 2, 20),
            options=SearchOptions(
                intent="flow",
                group_by_file=True,
                prefer_tests=True,
                prefer_code=True,
                prefer_impl=True,
                deprioritize_docs=True,
                deprioritize_experiments=True,
            ),
        )
        for hit in hits:
            role = _role_for_path(hit.path)
            evidence = [f"search hit for {alias}", hit.reason]
            score = hit.score + 0.2
            existing = candidates.get(hit.path)
            if existing is None:
                candidates[hit.path] = SubsystemCandidate(
                    path=hit.path,
                    role=role,
                    score=score,
                    evidence=evidence,
                    source="search",
                    grouped_hit_count=hit.grouped_hit_count,
                )
                continue
            merged_evidence = list(dict.fromkeys([*existing.evidence, *evidence]))
            merged_source = existing.source if existing.source == "path+search" else f"{existing.source}+search"
            existing.evidence = merged_evidence
            existing.source = merged_source
            existing.grouped_hit_count = max(existing.grouped_hit_count or 0, hit.grouped_hit_count or 0) or None
            existing.score = max(existing.score, score)

    files = sorted(
        candidates.values(),
        key=lambda item: (
            -item.score,
            item.role != "impl",
            item.role != "test",
            item.path,
        ),
    )[:limit]
    return SubsystemReport(token=token, aliases=aliases, files=files)
