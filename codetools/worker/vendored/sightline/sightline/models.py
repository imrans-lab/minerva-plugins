from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass
class RepoFile:
    path: str
    size: int
    mtime: float
    extension: str
    language: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SearchHit:
    path: str
    line_number: int
    submatches: list[dict[str, Any]]
    preview: str
    score: float
    reason: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ResultHandle:
    result_id: str
    query: str
    mode: str
    path: str
    start_line: int
    end_line: int
    preview: str
    score: float
    reason: str
    category: str | None = None
    grouped_hit_count: int | None = None
    path_score: float | None = None
    content_score: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SubsystemCandidate:
    path: str
    role: str
    score: float
    evidence: list[str]
    source: str
    grouped_hit_count: int | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SubsystemReport:
    token: str
    aliases: list[str]
    files: list[SubsystemCandidate]

    def to_dict(self) -> dict[str, Any]:
        return {
            "token": self.token,
            "aliases": self.aliases,
            "files": [item.to_dict() for item in self.files],
        }


@dataclass
class ContextLine:
    line: int
    text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ContextSlice:
    path: str
    start_line: int
    end_line: int
    lines: list[ContextLine]
    result_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["lines"] = [line.to_dict() for line in self.lines]
        return data


@dataclass
class RepoMapNode:
    path: str
    kind: str
    children: list["RepoMapNode"] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "kind": self.kind,
            "children": [child.to_dict() for child in self.children],
        }


@dataclass
class SurfaceTarget:
    kind: str
    path: str | None = None
    route: str | None = None
    component_hint: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class InspectionSession:
    session_id: str
    adapter: str
    target: SurfaceTarget
    opened_at: str

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["target"] = self.target.to_dict()
        return data


@dataclass
class ArtifactHandle:
    artifact_id: str
    session_id: str
    kind: str
    path: str
    metadata: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class InspectResult:
    session_id: str
    artifacts: list[ArtifactHandle]
    focus_nodes: list[dict[str, Any]]
    summary: str
    warnings: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "artifacts": [artifact.to_dict() for artifact in self.artifacts],
            "focus_nodes": self.focus_nodes,
            "summary": self.summary,
            "warnings": self.warnings,
        }


@dataclass
class ValidationCheck:
    name: str
    status: str
    evidence: list[str]
    detail: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ValidationResultRecord:
    validation_id: str
    status: str
    confidence: float
    checks: list[ValidationCheck]
    reason_summary: str
    evidence_used: list[str]
    gaps: list[str]
    recommended_next_step: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "validation_id": self.validation_id,
            "status": self.status,
            "confidence": self.confidence,
            "checks": [check.to_dict() for check in self.checks],
            "reason_summary": self.reason_summary,
            "evidence_used": self.evidence_used,
            "gaps": self.gaps,
            "recommended_next_step": self.recommended_next_step,
        }


@dataclass
class PluginCommandSpec:
    name: str
    description: str
    input_schema: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class PluginManifestRecord:
    plugin_id: str
    name: str
    version: str
    description: str
    entrypoint: str
    platforms: list[str] = field(default_factory=list)
    capabilities: list[str] = field(default_factory=list)
    requirements: list[str] = field(default_factory=list)
    instructions: str = ""
    commands: list[PluginCommandSpec] = field(default_factory=list)
    path: str | None = None
    source: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "plugin_id": self.plugin_id,
            "name": self.name,
            "version": self.version,
            "description": self.description,
            "entrypoint": self.entrypoint,
            "platforms": self.platforms,
            "capabilities": self.capabilities,
            "requirements": self.requirements,
            "instructions": self.instructions,
            "commands": [command.to_dict() for command in self.commands],
            "path": self.path,
            "source": self.source,
        }
