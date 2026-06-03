from __future__ import annotations

import hashlib


def make_result_id(query: str, path: str, start_line: int, end_line: int) -> str:
    raw = f"{query}|{path}|{start_line}|{end_line}".encode("utf-8")
    return f"r_{hashlib.sha1(raw).hexdigest()[:12]}"

