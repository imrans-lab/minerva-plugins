from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .inspect import InspectStore
from .models import ArtifactHandle, ResultHandle, ValidationCheck, ValidationResultRecord
from .session_store import SessionStore


def _make_validation_id(goal: str, code_ids: list[str], artifact_ids: list[str]) -> str:
    raw = f"{goal}|{'/'.join(code_ids)}|{'/'.join(artifact_ids)}"
    return f"v_{hashlib.sha1(raw.encode('utf-8')).hexdigest()[:12]}"


def _artifact_exists(artifact: ArtifactHandle, root: Path) -> bool:
    if artifact.metadata.get("exists") is True:
        return True
    path = Path(artifact.path)
    if path.exists():
        return True
    if not path.is_absolute() and (root / path).exists():
        return True
    return False


def _metadata_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True)


def _artifact_text(artifact: ArtifactHandle, root: Path) -> str:
    parts = [_metadata_text(artifact.metadata)]
    path = Path(artifact.path)
    candidates = [path]
    if not path.is_absolute():
        candidates.append(root / path)
    for candidate in candidates:
        if not candidate.exists() or candidate.stat().st_size > 1_000_000:
            continue
        if candidate.suffix.lower() not in {".txt", ".log", ".json", ".md", ".csv", ".yaml", ".yml"}:
            continue
        parts.append(candidate.read_text(encoding="utf-8", errors="replace"))
        break
    return "\n".join(parts)


def _runtime_issue_count(artifact: ArtifactHandle) -> int | None:
    if artifact.kind != "runtime_issue_report":
        return None
    value = artifact.metadata.get("issue_count")
    if isinstance(value, int):
        return value
    issues = artifact.metadata.get("issues")
    if isinstance(issues, list):
        return len(issues)
    return None


def _runtime_warning_count(artifact: ArtifactHandle) -> int | None:
    if artifact.kind != "runtime_issue_report":
        return None
    value = artifact.metadata.get("warning_count")
    if isinstance(value, int):
        return value
    severity_counts = artifact.metadata.get("severity_counts")
    if isinstance(severity_counts, dict):
        warning_count = severity_counts.get("warning")
        if isinstance(warning_count, int):
            return warning_count
    issues = artifact.metadata.get("issues")
    if isinstance(issues, list):
        return sum(
            1
            for issue in issues
            if isinstance(issue, dict) and str(issue.get("severity", "")).lower() == "warning"
        )
    return None


def _runtime_reports(artifacts: list[ArtifactHandle]) -> list[ArtifactHandle]:
    return [artifact for artifact in artifacts if artifact.kind == "runtime_issue_report"]


def _count_check(
    *,
    name: str,
    reports: list[ArtifactHandle],
    count_fn,
    max_allowed: int,
    missing_detail: str,
    noun: str,
) -> tuple[ValidationCheck, str | None]:
    if not reports:
        return (
            ValidationCheck(
                name=name,
                status="uncertain",
                evidence=[],
                detail=missing_detail,
            ),
            missing_detail,
        )
    counts = [count_fn(artifact) for artifact in reports]
    unknown = [artifact for artifact, count in zip(reports, counts, strict=True) if count is None]
    failing = [
        artifact
        for artifact, count in zip(reports, counts, strict=True)
        if count is not None and count > max_allowed
    ]
    if failing:
        total = sum(count_fn(artifact) or 0 for artifact in failing)
        return (
            ValidationCheck(
                name=name,
                status="fail",
                evidence=[artifact.artifact_id for artifact in failing],
                detail=f"runtime reports contain {total} {noun}; max allowed is {max_allowed}",
            ),
            f"runtime {noun} exceeded threshold",
        )
    if unknown:
        return (
            ValidationCheck(
                name=name,
                status="uncertain",
                evidence=[artifact.artifact_id for artifact in unknown],
                detail=f"runtime report did not include {noun} count",
            ),
            f"runtime {noun} count is unavailable",
        )
    total = sum(count or 0 for count in counts)
    return (
        ValidationCheck(
            name=name,
            status="pass",
            evidence=[artifact.artifact_id for artifact in reports],
            detail=f"runtime reports contain {total} {noun}; max allowed is {max_allowed}",
        ),
        None,
    )


def _exact_count_check(
    *,
    name: str,
    reports: list[ArtifactHandle],
    count_fn,
    expected: int,
    missing_detail: str,
    noun: str,
) -> tuple[ValidationCheck, str | None]:
    if not reports:
        return (
            ValidationCheck(
                name=name,
                status="uncertain",
                evidence=[],
                detail=missing_detail,
            ),
            missing_detail,
        )
    counts = [count_fn(artifact) for artifact in reports]
    unknown = [artifact for artifact, count in zip(reports, counts, strict=True) if count is None]
    if unknown:
        return (
            ValidationCheck(
                name=name,
                status="uncertain",
                evidence=[artifact.artifact_id for artifact in unknown],
                detail=f"runtime report did not include {noun} count",
            ),
            f"runtime {noun} count is unavailable",
        )
    total = sum(count or 0 for count in counts)
    if total != expected:
        return (
            ValidationCheck(
                name=name,
                status="fail",
                evidence=[artifact.artifact_id for artifact in reports],
                detail=f"runtime reports contain {total} {noun}; expected {expected}",
            ),
            f"runtime {noun} count did not match expected value",
        )
    return (
        ValidationCheck(
            name=name,
            status="pass",
            evidence=[artifact.artifact_id for artifact in reports],
            detail=f"runtime reports contain exactly {expected} {noun}",
        ),
        None,
    )


def validate_evidence(
    root: Path,
    goal: str,
    code_result_ids: list[str],
    artifact_ids: list[str],
    *,
    artifact_only: bool = False,
    expected_artifact_text: list[str] | None = None,
    require_no_runtime_issues: bool = False,
    max_runtime_warnings: int | None = None,
    expected_runtime_warnings: int | None = None,
) -> ValidationResultRecord:
    session_store = SessionStore(root)
    inspect_store = InspectStore(root)

    code_handles: list[ResultHandle] = []
    for result_id in code_result_ids:
        handle = session_store.get_handle(result_id)
        if handle is not None:
            code_handles.append(handle)

    artifacts = [artifact for artifact in inspect_store.list_artifacts() if artifact.artifact_id in set(artifact_ids)]

    checks: list[ValidationCheck] = []
    gaps: list[str] = []
    evidence_used: list[str] = []

    if code_handles:
        evidence_used.extend(handle.result_id for handle in code_handles)
        checks.append(
            ValidationCheck(
                name="code_region_touched",
                status="pass",
                evidence=[handle.result_id for handle in code_handles],
                detail=f"found {len(code_handles)} code evidence handle(s)",
            )
        )
    elif artifact_only:
        checks.append(
            ValidationCheck(
                name="code_region_optional",
                status="pass",
                evidence=[],
                detail="code evidence was not required for this artifact-only validation",
            )
        )
    else:
        gaps.append("no code evidence found")
        checks.append(
            ValidationCheck(
                name="code_region_touched",
                status="fail",
                evidence=[],
                detail="no code evidence available",
            )
        )

    if artifacts:
        evidence_used.extend(artifact.artifact_id for artifact in artifacts)
        checks.append(
            ValidationCheck(
                name="expected_surface_observed",
                status="pass",
                evidence=[artifact.artifact_id for artifact in artifacts],
                detail=f"found {len(artifacts)} inspect artifact(s)",
            )
        )
        missing_artifacts = [artifact for artifact in artifacts if not _artifact_exists(artifact, root)]
        if missing_artifacts:
            gaps.append("one or more inspect artifact files are missing")
            checks.append(
                ValidationCheck(
                    name="artifact_files_exist",
                    status="fail",
                    evidence=[artifact.artifact_id for artifact in missing_artifacts],
                    detail=f"missing {len(missing_artifacts)} artifact file(s)",
                )
            )
        else:
            checks.append(
                ValidationCheck(
                    name="artifact_files_exist",
                    status="pass",
                    evidence=[artifact.artifact_id for artifact in artifacts],
                    detail=f"all {len(artifacts)} artifact file(s) are present",
                )
            )
    else:
        gaps.append("no inspect artifacts found")
        checks.append(
            ValidationCheck(
                name="expected_surface_observed",
                status="uncertain",
                evidence=[],
                detail="inspect evidence is missing",
            )
        )

    for expected_text in expected_artifact_text or []:
        matching = [artifact for artifact in artifacts if expected_text in _artifact_text(artifact, root)]
        if matching:
            checks.append(
                ValidationCheck(
                    name="expected_artifact_text",
                    status="pass",
                    evidence=[artifact.artifact_id for artifact in matching],
                    detail=f"found expected text: {expected_text}",
                )
            )
        else:
            gaps.append(f"expected artifact text not found: {expected_text}")
            checks.append(
                ValidationCheck(
                    name="expected_artifact_text",
                    status="fail",
                    evidence=[],
                    detail=f"missing expected text: {expected_text}",
                )
            )

    if require_no_runtime_issues:
        check, gap = _count_check(
            name="no_runtime_issues",
            reports=_runtime_reports(artifacts),
            count_fn=_runtime_issue_count,
            max_allowed=0,
            missing_detail="no runtime issue report artifact available",
            noun="issue(s)",
        )
        checks.append(check)
        if gap:
            gaps.append(gap)

    if max_runtime_warnings is not None:
        check, gap = _count_check(
            name="runtime_warning_threshold",
            reports=_runtime_reports(artifacts),
            count_fn=_runtime_warning_count,
            max_allowed=max_runtime_warnings,
            missing_detail="no runtime issue report artifact available",
            noun="warning(s)",
        )
        checks.append(check)
        if gap:
            gaps.append(gap)

    if expected_runtime_warnings is not None:
        check, gap = _exact_count_check(
            name="runtime_warning_count",
            reports=_runtime_reports(artifacts),
            count_fn=_runtime_warning_count,
            expected=expected_runtime_warnings,
            missing_detail="no runtime issue report artifact available",
            noun="warning(s)",
        )
        checks.append(check)
        if gap:
            gaps.append(gap)

    has_required_code_evidence = bool(code_handles) or artifact_only
    sufficiency_status = "pass" if has_required_code_evidence and artifacts else "uncertain"
    checks.append(
        ValidationCheck(
            name="evidence_sufficiency",
            status=sufficiency_status,
            evidence=evidence_used.copy(),
            detail="enough evidence for lightweight review" if sufficiency_status == "pass" else "more evidence needed",
        )
    )

    has_failures = any(check.status == "fail" for check in checks)
    has_uncertain = any(check.status == "uncertain" for check in checks)

    if has_failures:
        status = "fail"
        confidence = 0.25 if code_handles or artifacts else 0.15
        reason_summary = "One or more evidence checks failed."
        recommended_next_step = "Review failed checks and capture stronger or corrected evidence."
    elif has_required_code_evidence and artifacts and not has_uncertain:
        status = "pass"
        confidence = (
            0.85
            if (
                expected_artifact_text
                or require_no_runtime_issues
                or max_runtime_warnings is not None
                or expected_runtime_warnings is not None
            )
            else (0.75 if artifact_only and not code_handles else 0.8)
        )
        reason_summary = (
            "Inspect evidence and requested artifact-only checks are present."
            if artifact_only and not code_handles
            else "Code evidence, inspect evidence, and requested checks are present."
        )
        recommended_next_step = "Review artifact contents or add more domain-specific assertions if needed."
    elif has_required_code_evidence and artifacts:
        status = "uncertain"
        confidence = 0.6
        reason_summary = (
            "Inspect evidence is present, but some artifact-only checks remain uncertain."
            if artifact_only and not code_handles
            else "Code and inspect evidence are present, but some checks remain uncertain."
        )
        recommended_next_step = "Capture the missing artifact type or add more precise evidence."
    elif code_handles:
        status = "uncertain"
        confidence = 0.45
        reason_summary = "Code evidence exists, but no inspect evidence was provided."
        recommended_next_step = "Attach screenshot or tree artifacts for the intended surface."
    else:
        status = "fail"
        confidence = 0.15
        reason_summary = "There is not enough evidence to judge the requested change."
        recommended_next_step = "Run explore search first, then attach inspect evidence."

    return ValidationResultRecord(
        validation_id=_make_validation_id(goal, code_result_ids, artifact_ids),
        status=status,
        confidence=confidence,
        checks=checks,
        reason_summary=reason_summary,
        evidence_used=evidence_used,
        gaps=gaps,
        recommended_next_step=recommended_next_step,
    )
