from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import ArtifactHandle, InspectResult, InspectionSession, SurfaceTarget
from .plugin_system import run_plugin_command


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _make_id(prefix: str, raw: str) -> str:
    return f"{prefix}_{hashlib.sha1(raw.encode('utf-8')).hexdigest()[:12]}"


def _path_metadata(root: Path, artifact_path: str) -> dict[str, Any]:
    path = Path(artifact_path)
    candidates = [path]
    if not path.is_absolute():
        candidates.append(root / path)

    metadata: dict[str, Any] = {"exists": False}
    for candidate in candidates:
        if candidate.exists():
            metadata["exists"] = True
            metadata["size"] = candidate.stat().st_size
            break
    return metadata


class InspectStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.data_dir = root / ".sightline"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.inspect_dir = self.data_dir / "inspect"
        self.inspect_dir.mkdir(parents=True, exist_ok=True)
        self.sessions_path = self.inspect_dir / "sessions.json"
        self.artifacts_path = self.inspect_dir / "artifacts.json"

    def _load_json(self, path: Path) -> list[dict[str, Any]]:
        if not path.exists():
            return []
        return json.loads(path.read_text(encoding="utf-8"))

    def _save_json(self, path: Path, payload: list[dict[str, Any]]) -> None:
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def save_session(self, session: InspectionSession) -> None:
        sessions = self._load_json(self.sessions_path)
        sessions = [item for item in sessions if item["session_id"] != session.session_id]
        sessions.append(session.to_dict())
        self._save_json(self.sessions_path, sessions)

    def list_sessions(self) -> list[InspectionSession]:
        return [
            InspectionSession(
                session_id=item["session_id"],
                adapter=item["adapter"],
                target=SurfaceTarget(**item["target"]),
                opened_at=item["opened_at"],
            )
            for item in self._load_json(self.sessions_path)
        ]

    def save_artifacts(self, artifacts: list[ArtifactHandle]) -> None:
        existing = self._load_json(self.artifacts_path)
        existing = [item for item in existing if item["artifact_id"] not in {artifact.artifact_id for artifact in artifacts}]
        existing.extend(artifact.to_dict() for artifact in artifacts)
        self._save_json(self.artifacts_path, existing)

    def list_artifacts(self, session_id: str | None = None) -> list[ArtifactHandle]:
        items = self._load_json(self.artifacts_path)
        if session_id is not None:
            items = [item for item in items if item["session_id"] == session_id]
        return [ArtifactHandle(**item) for item in items]


def create_attachment_session(root: Path, target: SurfaceTarget, artifacts: list[tuple[str, str]]) -> InspectResult:
    store = InspectStore(root)
    session_id = _make_id("s", f"{target.kind}|{target.path}|{target.route}|{_now_iso()}")
    session = InspectionSession(
        session_id=session_id,
        adapter="attachment",
        target=target,
        opened_at=_now_iso(),
    )
    store.save_session(session)

    handles: list[ArtifactHandle] = []
    warnings: list[str] = []
    for kind, artifact_path in artifacts:
        path = Path(artifact_path)
        metadata: dict[str, Any] = {"exists": path.exists()}
        if path.exists():
            metadata["size"] = path.stat().st_size
        else:
            warnings.append(f"artifact missing: {artifact_path}")
        handles.append(
            ArtifactHandle(
                artifact_id=_make_id("a", f"{session_id}|{kind}|{artifact_path}"),
                session_id=session_id,
                kind=kind,
                path=artifact_path,
                metadata=metadata,
            )
        )
    store.save_artifacts(handles)
    return InspectResult(
        session_id=session_id,
        artifacts=handles,
        focus_nodes=[],
        summary=f"attached {len(handles)} artifact(s) to inspection session",
        warnings=warnings,
    )


def _infer_artifact_kind(payload: dict[str, Any]) -> str:
    command = str(payload.get("command", ""))
    if "kind" in payload and isinstance(payload["kind"], str):
        return payload["kind"]
    if command == "capture-region-png":
        return "screenshot_region"
    if command in {"capture-window", "capture-window-png"}:
        return "screenshot"
    if command == "report-runtime-issues":
        return "runtime_issue_report"
    if command in {"tail-runtime-issues", "discover-project-logs"}:
        return "runtime_log"
    return "plugin_artifact"


def _artifact_path(payload: dict[str, Any]) -> str | None:
    for key in ["artifact_path", "path", "log_path"]:
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _extract_artifact_payloads(plugin_result: dict[str, Any]) -> list[dict[str, Any]]:
    artifacts = plugin_result.get("artifacts")
    if isinstance(artifacts, list):
        return [item for item in artifacts if isinstance(item, dict)]
    if _artifact_path(plugin_result):
        return [plugin_result]
    return []


def create_plugin_capture_session(
    root: Path,
    target: SurfaceTarget,
    plugin_id: str,
    plugin_command: str,
    plugin_args: dict[str, Any],
) -> InspectResult:
    plugin_result = run_plugin_command(root, plugin_id, plugin_command, plugin_args)
    store = InspectStore(root)
    session_id = _make_id(
        "s",
        f"plugin|{plugin_id}|{plugin_command}|{json.dumps(plugin_args, sort_keys=True)}|{_now_iso()}",
    )
    session = InspectionSession(
        session_id=session_id,
        adapter=f"plugin:{plugin_id}",
        target=target,
        opened_at=_now_iso(),
    )
    store.save_session(session)

    warnings: list[str] = []
    handles: list[ArtifactHandle] = []
    artifact_payloads = _extract_artifact_payloads(plugin_result)
    if not artifact_payloads:
        warnings.append(f"plugin command did not return an artifact path: {plugin_id} {plugin_command}")

    for index, payload in enumerate(artifact_payloads):
        path = _artifact_path(payload)
        if path is None:
            warnings.append(f"plugin artifact {index} missing artifact path")
            continue
        kind = _infer_artifact_kind(payload)
        metadata: dict[str, Any] = _path_metadata(root, path)
        payload_metadata = payload.get("metadata")
        if isinstance(payload_metadata, dict):
            metadata.update(payload_metadata)
        provenance = payload.get("provenance")
        if isinstance(provenance, dict):
            metadata["provenance"] = provenance
        else:
            metadata["provenance"] = {"adapter": "plugin", "plugin_id": plugin_id}
        metadata["plugin_id"] = plugin_id
        metadata["plugin_command"] = plugin_command
        metadata["plugin_args"] = plugin_args

        for key in [
            "source_artifact_path",
            "window_id",
            "window_title",
            "window_kind",
            "pid",
            "wm_class",
            "crop",
            "project",
            "log_path",
            "issue_count",
            "issues",
            "report",
            "summary",
        ]:
            if key in payload and key not in metadata:
                metadata[key] = payload[key]

        if not metadata.get("exists"):
            warnings.append(f"artifact missing: {path}")

        handles.append(
            ArtifactHandle(
                artifact_id=_make_id("a", f"{session_id}|{plugin_id}|{plugin_command}|{kind}|{path}|{index}"),
                session_id=session_id,
                kind=kind,
                path=path,
                metadata=metadata,
            )
        )

    store.save_artifacts(handles)
    return InspectResult(
        session_id=session_id,
        artifacts=handles,
        focus_nodes=[],
        summary=f"captured {len(handles)} artifact(s) from plugin {plugin_id}:{plugin_command}",
        warnings=warnings,
    )
