from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .models import ContextSlice, ResultHandle
from .read import read_context
from .search import SearchOptions, search_code


@dataclass
class ExploreEntry:
    handle: ResultHandle
    context: ContextSlice

    def to_dict(self) -> dict[str, object]:
        return {
            "handle": self.handle.to_dict(),
            "context": self.context.to_dict(),
        }


@dataclass
class ExploreReport:
    command: str
    query: str
    summary: str
    entries: list[ExploreEntry]

    def to_dict(self) -> dict[str, object]:
        return {
            "command": self.command,
            "query": self.query,
            "summary": self.summary,
            "entries": [entry.to_dict() for entry in self.entries],
        }


def _report(command: str, query: str, summary: str, handles: list[ResultHandle], root: Path) -> ExploreReport:
    entries: list[ExploreEntry] = []
    for handle in handles:
        context = read_context(
            root,
            handle.path,
            max(1, handle.start_line - 2),
            handle.end_line + 2,
            result_id=handle.result_id,
        )
        entries.append(ExploreEntry(handle=handle, context=context))
    return ExploreReport(command=command, query=query, summary=summary, entries=entries)


def where_defined(root: Path, symbol: str, limit: int = 5) -> ExploreReport:
    handles = search_code(
        root,
        symbol,
        limit=limit,
        options=SearchOptions(
            intent="definition",
            group_by_file=True,
            exclude_paths=["experiments/sightline/tests"],
            prefer_code=True,
            prefer_impl=True,
            deprioritize_docs=True,
            deprioritize_experiments=True,
        ),
    )
    return _report("where-defined", symbol, f"Top definition-oriented matches for {symbol}", handles, root)


def where_tested(root: Path, symbol: str, limit: int = 5) -> ExploreReport:
    handles = search_code(
        root,
        symbol,
        limit=limit,
        options=SearchOptions(
            intent="tests",
            group_by_file=True,
            path_contains="test",
            exclude_paths=["experiments"],
            prefer_tests=True,
            deprioritize_docs=True,
            deprioritize_experiments=True,
        ),
    )
    return _report("where-tested", symbol, f"Top test files mentioning {symbol}", handles, root)


def locate_edit(root: Path, query: str, limit: int = 5) -> ExploreReport:
    handles = search_code(
        root,
        query,
        limit=limit,
        options=SearchOptions(
            intent="edit",
            group_by_file=True,
            exclude_paths=["experiments/sightline/tests"],
            prefer_code=True,
            prefer_impl=True,
            deprioritize_docs=True,
            deprioritize_experiments=True,
        ),
    )
    return _report("locate-edit", query, f"Most likely edit targets for {query}", handles, root)


def trace_topic(root: Path, topic: str, limit: int = 6) -> ExploreReport:
    handles = search_code(
        root,
        topic,
        limit=limit,
        options=SearchOptions(
            intent="flow",
            group_by_file=True,
            exclude_paths=["experiments/sightline/tests"],
            prefer_code=True,
            prefer_impl=True,
            prefer_tests=True,
            deprioritize_docs=True,
            deprioritize_experiments=True,
        ),
    )
    report = _report("trace-topic", topic, f"Likely flow-related files for topic {topic}", handles, root)
    ordered = sorted(
        report.entries,
        key=lambda entry: (
            entry.handle.category != "impl",
            "exact-topic" not in entry.handle.reason,
            -entry.handle.score,
            entry.handle.path,
        ),
    )
    report.entries = ordered
    return report
