from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
import re

from .handles import make_result_id
from .models import ResultHandle


CODE_EXTENSIONS = {
    ".py",
    ".rs",
    ".go",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".gd",
    ".java",
    ".kt",
    ".swift",
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".hpp",
}

CONFIG_EXTENSIONS = {
    ".json",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
    ".env",
    ".yaml",
    ".yml",
}


@dataclass
class SearchOptions:
    intent: str | None = None
    path_contains: str | None = None
    path_prefix: list[str] | None = None
    exclude_paths: list[str] | None = None
    extension: str | None = None
    include_hidden: bool = False
    prefer_code: bool = False
    prefer_tests: bool = False
    prefer_config: bool = False
    prefer_impl: bool = False
    deprioritize_docs: bool = False
    deprioritize_experiments: bool = False
    group_by_file: bool = False


def _normalize_extension(extension: str | None) -> str | None:
    if not extension:
        return None
    return extension if extension.startswith(".") else f".{extension}"


def _build_rg_command(query: str, mode: str, root: Path, options: SearchOptions) -> list[str]:
    command = ["rg", "--json", "--line-number", "--smart-case"]
    if options.include_hidden:
        command.append("--hidden")
    if mode == "literal":
        command.append("--fixed-strings")
    extension = _normalize_extension(options.extension)
    if extension:
        command.extend(["-g", f"*{extension}"])
    for prefix in options.path_prefix or []:
        cleaned = prefix.strip("/")
        if cleaned:
            command.extend(["-g", f"{cleaned}/**"])
    for excluded in options.exclude_paths or []:
        cleaned = excluded.strip("/")
        if cleaned:
            command.extend(["-g", f"!{cleaned}/**"])
    command.extend([query, str(root)])
    return command


def _intent_defaults(intent: str | None) -> dict[str, object]:
    if intent == "definition":
        return {
            "prefer_code": True,
            "prefer_impl": True,
            "deprioritize_docs": True,
            "deprioritize_experiments": True,
        }
    if intent == "config":
        return {
            "prefer_config": True,
            "deprioritize_docs": True,
            "deprioritize_experiments": True,
        }
    if intent == "tests":
        return {
            "prefer_tests": True,
            "deprioritize_docs": True,
            "deprioritize_experiments": True,
        }
    if intent == "edit":
        return {
            "prefer_code": True,
            "prefer_impl": True,
            "deprioritize_docs": True,
            "deprioritize_experiments": True,
        }
    if intent == "flow":
        return {
            "prefer_code": True,
            "prefer_impl": True,
            "deprioritize_docs": True,
        }
    if intent == "example":
        return {
            "prefer_code": True,
            "prefer_impl": True,
            "deprioritize_docs": True,
            "deprioritize_experiments": True,
        }
    return {}


def _effective_options(options: SearchOptions) -> SearchOptions:
    merged = SearchOptions(**vars(options))
    defaults = _intent_defaults(options.intent)
    for key, value in defaults.items():
        if getattr(merged, key):
            continue
        setattr(merged, key, value)
    return merged


def _categorize_path(relative_path: str) -> str:
    path = relative_path.lower()
    parts = path.split("/")
    filename = parts[-1]
    extension = Path(relative_path).suffix.lower()

    if (
        "test" in parts
        or filename.startswith("test_")
        or filename.endswith("_test.py")
        or filename.endswith("-test.py")
        or filename.endswith("_spec.ts")
        or filename.endswith(".spec.ts")
    ):
        return "test"
    if parts[0] == "docs" or extension in {".md", ".rst", ".txt"}:
        return "doc"
    if parts[0] == "experiments":
        return "experiment"
    if filename == "Dockerfile" or filename.endswith(".env") or "docker-compose" in filename or extension in CONFIG_EXTENSIONS:
        return "config"
    if extension in CODE_EXTENSIONS:
        if relative_path.startswith("infrastructure/services/") or relative_path.startswith("mobile_app/"):
            return "impl"
        return "code"
    return "other"


def _path_allowed(relative_path: str, options: SearchOptions) -> bool:
    normalized = relative_path.replace("\\", "/")
    if not options.include_hidden and normalized.split("/", 1)[0].startswith("."):
        return False
    if options.path_contains and options.path_contains not in normalized:
        return False
    if options.path_prefix:
        prefixes = [prefix.strip("/").replace("\\", "/") for prefix in options.path_prefix]
        if not any(normalized.startswith(f"{prefix}/") or normalized == prefix for prefix in prefixes):
            return False
    if options.exclude_paths:
        excluded = [prefix.strip("/").replace("\\", "/") for prefix in options.exclude_paths]
        if any(normalized.startswith(f"{prefix}/") or normalized == prefix for prefix in excluded):
            return False
    extension = _normalize_extension(options.extension)
    if extension and Path(normalized).suffix.lower() != extension:
        return False
    return True


def _content_score(query: str, preview: str, mode: str, category: str, options: SearchOptions) -> tuple[float, list[str]]:
    preview_lower = preview.lower()
    query_lower = query.lower()
    score = 1.0
    reasons: list[str] = [f"{mode} match"]
    if mode == "literal":
        assignment_patterns = [
            rf"\b{re.escape(query_lower)}\b\s*[:=]",
            rf"\bvar\s+{re.escape(query_lower)}\b",
            rf"\bconst\s+{re.escape(query_lower)}\b",
            rf"\blet\s+{re.escape(query_lower)}\b",
            rf"\bdef\s+{re.escape(query_lower)}\b",
            rf"\bclass\s+{re.escape(query_lower)}\b",
            rf"os\.environ\.get\(\s*[\"']{re.escape(query_lower)}[\"']",
        ]
        for pattern in assignment_patterns:
            if re.search(pattern, preview_lower):
                score *= 1.25
                reasons = ["definition-like match"]
                break

    if options.intent == "definition" and any(
        marker in preview_lower for marker in ["class ", "def ", "pub const ", "const ", "var ", "let "]
    ):
        score *= 1.2
        reasons.append("intent-definition")
    elif options.intent == "config" and (
        "os.environ.get" in preview_lower or "${" in preview or category == "config"
    ):
        score *= 1.2
        reasons.append("intent-config")
    elif options.intent == "tests" and category == "test":
        score *= 1.2
        reasons.append("intent-tests")
    elif options.intent == "edit" and category == "impl":
        score *= 1.25
        reasons.append("intent-edit")
    elif options.intent == "flow":
        flow_markers = [
            '"topic":',
            "topic ==",
            "target_service_id",
            "send_response",
            "send_error",
            "handle_",
            "await self.",
        ]
        if any(marker in preview_lower for marker in flow_markers):
            score *= 1.2
            reasons.append("intent-flow")
        exact_topic_markers = [
            f'"{query_lower}"',
            f"'{query_lower}'",
            f'`{query_lower}`',
        ]
        if any(marker in preview_lower for marker in exact_topic_markers):
            score *= 1.25
            reasons.append("exact-topic")
        elif query_lower in preview_lower:
            score *= 1.05
            reasons.append("partial-topic")
    elif options.intent == "example" and category in {"impl", "code"}:
        score *= 1.15
        reasons.append("intent-example")

    return score, reasons


def _path_score(relative_path: str, options: SearchOptions) -> tuple[float, list[str], str]:
    category = _categorize_path(relative_path)
    score = 1.0
    reasons: list[str] = [category]

    if category in {"impl", "code"} and options.prefer_code:
        score += 0.7
        reasons.append("prefer-code")
    if category == "test" and options.prefer_tests:
        score += 1.0
        reasons.append("prefer-tests")
    if category == "config" and options.prefer_config:
        score += 0.9
        reasons.append("prefer-config")
    if category == "impl" and options.prefer_impl:
        score += 1.1
        reasons.append("prefer-impl")
    if category == "doc" and options.deprioritize_docs:
        score -= 0.8
        reasons.append("deprioritize-docs")
    if category == "experiment" and options.deprioritize_experiments:
        score -= 0.7
        reasons.append("deprioritize-experiments")
    return score, reasons, category


def _ungrouped_results(
    root: Path,
    query: str,
    mode: str,
    limit: int,
    options: SearchOptions,
) -> list[ResultHandle]:
    effective_options = _effective_options(options)
    command = _build_rg_command(query, mode, root, effective_options)
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode not in (0, 1):
        raise RuntimeError(completed.stderr.strip() or "ripgrep search failed")

    results: list[ResultHandle] = []
    for line in completed.stdout.splitlines():
        payload = json.loads(line)
        if payload.get("type") != "match":
            continue
        data = payload["data"]
        relative_path = str(Path(data["path"]["text"]).relative_to(root))
        if not _path_allowed(relative_path, effective_options):
            continue
        line_number = data["line_number"]
        preview = data["lines"]["text"].rstrip("\n")
        path_score, path_reasons, category = _path_score(relative_path, effective_options)
        content_score, content_reasons = _content_score(query, preview, mode, category, effective_options)
        score = path_score * content_score
        reason_parts = [*content_reasons, *path_reasons]
        results.append(
            ResultHandle(
                result_id=make_result_id(query, relative_path, line_number, line_number),
                query=query,
                mode=mode,
                path=relative_path,
                start_line=line_number,
                end_line=line_number,
                preview=preview,
                score=score,
                reason=", ".join(reason_parts),
                category=category,
                grouped_hit_count=1,
                path_score=path_score,
                content_score=content_score,
            )
        )
    results.sort(key=lambda item: (-item.score, item.path, item.start_line))
    return results[:limit]


def _group_results(results: list[ResultHandle], limit: int) -> list[ResultHandle]:
    grouped: dict[str, ResultHandle] = {}
    counts: dict[str, int] = {}

    for result in results:
        counts[result.path] = counts.get(result.path, 0) + 1
        existing = grouped.get(result.path)
        if existing is None or result.score > existing.score or (
            result.score == existing.score and result.start_line < existing.start_line
        ):
            grouped[result.path] = result

    collapsed: list[ResultHandle] = []
    for path, best in grouped.items():
        collapsed.append(
            ResultHandle(
                result_id=best.result_id,
                query=best.query,
                mode=best.mode,
                path=path,
                start_line=best.start_line,
                end_line=best.end_line,
                preview=best.preview,
                score=best.score,
                reason=best.reason,
                category=best.category,
                grouped_hit_count=counts[path],
                path_score=best.path_score,
                content_score=best.content_score,
            )
        )
    collapsed.sort(
        key=lambda item: (
            -item.score,
            -(item.grouped_hit_count or 0),
            item.path,
            item.start_line,
        )
    )
    return collapsed[:limit]


def search_code(
    root: Path,
    query: str,
    mode: str = "literal",
    limit: int = 20,
    options: SearchOptions | None = None,
) -> list[ResultHandle]:
    search_options = options or SearchOptions()
    raw_limit = limit * 5 if search_options.group_by_file else limit
    results = _ungrouped_results(root, query, mode, raw_limit, search_options)
    if search_options.group_by_file:
        return _group_results(results, limit)
    return results
