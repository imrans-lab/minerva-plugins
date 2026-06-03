from __future__ import annotations

import json
from pathlib import Path

from .models import ResultHandle


class SessionStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.data_dir = root / ".sightline"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.handles_path = self.data_dir / "handles.json"

    def save_handles(self, handles: list[ResultHandle]) -> None:
        payload = [handle.to_dict() for handle in handles]
        self.handles_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def load_handles(self) -> list[ResultHandle]:
        if not self.handles_path.exists():
            return []
        raw = json.loads(self.handles_path.read_text(encoding="utf-8"))
        return [ResultHandle(**item) for item in raw]

    def get_handle(self, result_id: str) -> ResultHandle | None:
        for handle in self.load_handles():
            if handle.result_id == result_id:
                return handle
        return None

