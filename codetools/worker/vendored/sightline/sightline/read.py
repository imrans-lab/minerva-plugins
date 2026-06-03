from __future__ import annotations

from pathlib import Path

from .models import ContextLine, ContextSlice


def read_context(root: Path, relative_path: str, start_line: int, end_line: int, result_id: str | None = None) -> ContextSlice:
    path = root / relative_path
    lines: list[ContextLine] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for index, text in enumerate(handle, start=1):
            if index < start_line:
                continue
            if index > end_line:
                break
            lines.append(ContextLine(line=index, text=text.rstrip("\n")))
    return ContextSlice(
        path=relative_path,
        start_line=start_line,
        end_line=end_line,
        lines=lines,
        result_id=result_id,
    )

