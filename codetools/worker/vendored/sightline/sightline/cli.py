from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

from .explore import locate_edit, trace_topic, where_defined, where_tested
from .files import list_repo_files, list_repo_files_filtered, summarize_repo_files
from .inspect import InspectStore, create_attachment_session, create_plugin_capture_session
from .models import SurfaceTarget
from .plugin_system import (
    get_plugin,
    init_plugin,
    install_plugin,
    list_plugins,
    plugin_help,
    plugin_validate_target,
    run_plugin_command,
)
from .read import read_context
from .render import render_compact
from .repo_map import build_repo_map
from .search import SearchOptions, search_code
from .session_store import SessionStore
from .subsystem import build_subsystem_report
from .validate import validate_evidence


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sightline")
    parser.add_argument("--root", default=".", help="Repo root to inspect")
    parser.add_argument("--format", choices=["json", "compact"], default="json")
    subparsers = parser.add_subparsers(dest="command", required=True)

    files_parser = subparsers.add_parser("files")
    files_parser.add_argument("--summary-by", choices=["topdir", "extension", "language"])
    files_parser.add_argument("--limit", type=int, default=0)
    files_parser.add_argument("--exclude", action="append", default=[])
    files_parser.add_argument("--require-nested", action="store_true")
    files_parser.add_argument("--include-hidden", action="store_true")
    files_parser.add_argument("--sort-by", choices=["files", "size", "name"], default="files")
    files_parser.add_argument("--extension")
    files_parser.add_argument("--size-gt", type=int)
    files_parser.add_argument("--size-lt", type=int)
    files_parser.add_argument("--path-contains")
    files_parser.add_argument("--sort-files-by", choices=["path", "size", "mtime", "language"], default="path")
    files_parser.add_argument("--sort-order", choices=["asc", "desc"], default="asc")
    files_parser.add_argument("--mtime-after-days", type=float)
    files_parser.add_argument("--mtime-before-days", type=float)

    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("query")
    search_parser.add_argument("--mode", choices=["literal", "regex"], default="literal")
    search_parser.add_argument("--limit", type=int, default=20)
    search_parser.add_argument("--intent", choices=["definition", "config", "tests", "edit", "flow", "example"])
    search_parser.add_argument("--path-contains")
    search_parser.add_argument("--path-prefix", action="append", default=[])
    search_parser.add_argument("--exclude-path", action="append", default=[])
    search_parser.add_argument("--extension")
    search_parser.add_argument("--include-hidden", action="store_true")
    search_parser.add_argument("--prefer-code", action="store_true")
    search_parser.add_argument("--prefer-tests", action="store_true")
    search_parser.add_argument("--prefer-config", action="store_true")
    search_parser.add_argument("--prefer-impl", action="store_true")
    search_parser.add_argument("--deprioritize-docs", action="store_true")
    search_parser.add_argument("--deprioritize-experiments", action="store_true")
    search_parser.add_argument("--group-by-file", action="store_true")

    read_parser = subparsers.add_parser("read")
    read_parser.add_argument("result_id")
    read_parser.add_argument("--before", type=int, default=5)
    read_parser.add_argument("--after", type=int, default=5)

    read_path_parser = subparsers.add_parser("read-path")
    read_path_parser.add_argument("path")
    read_path_parser.add_argument("--start", type=int, required=True)
    read_path_parser.add_argument("--end", type=int, required=True)

    subparsers.add_parser("handles")

    subsystem_parser = subparsers.add_parser("subsystem")
    subsystem_parser.add_argument("token")
    subsystem_parser.add_argument("--limit", type=int, default=20)

    subparsers.add_parser("plugin-list")

    plugin_info_parser = subparsers.add_parser("plugin-info")
    plugin_info_parser.add_argument("plugin_id")

    plugin_help_parser = subparsers.add_parser("plugin-help")
    plugin_help_parser.add_argument("plugin_id")

    plugin_validate_parser = subparsers.add_parser("plugin-validate")
    plugin_validate_parser.add_argument("target")

    plugin_install_parser = subparsers.add_parser("plugin-install")
    plugin_install_parser.add_argument("source_path")

    plugin_init_parser = subparsers.add_parser("plugin-init")
    plugin_init_parser.add_argument("target_dir")
    plugin_init_parser.add_argument("--id", required=True)
    plugin_init_parser.add_argument("--name", required=True)
    plugin_init_parser.add_argument("--description", default="Sightline plugin")

    plugin_run_parser = subparsers.add_parser("plugin-run")
    plugin_run_parser.add_argument("plugin_id")
    plugin_run_parser.add_argument("plugin_command")
    plugin_run_parser.add_argument("--args", default="{}")

    where_defined_parser = subparsers.add_parser("where-defined")
    where_defined_parser.add_argument("symbol")
    where_defined_parser.add_argument("--limit", type=int, default=5)

    where_tested_parser = subparsers.add_parser("where-tested")
    where_tested_parser.add_argument("symbol")
    where_tested_parser.add_argument("--limit", type=int, default=5)

    locate_edit_parser = subparsers.add_parser("locate-edit")
    locate_edit_parser.add_argument("query")
    locate_edit_parser.add_argument("--limit", type=int, default=5)

    trace_topic_parser = subparsers.add_parser("trace-topic")
    trace_topic_parser.add_argument("topic")
    trace_topic_parser.add_argument("--limit", type=int, default=6)

    map_parser = subparsers.add_parser("map")
    map_parser.add_argument("--max-depth", type=int, default=2)

    inspect_parser = subparsers.add_parser("inspect-attach")
    inspect_parser.add_argument("--surface-kind", default="path")
    inspect_parser.add_argument("--surface-path")
    inspect_parser.add_argument("--route")
    inspect_parser.add_argument("--component-hint")
    inspect_parser.add_argument(
        "--artifact",
        action="append",
        default=[],
        help="Artifact spec as kind:path, e.g. screenshot:examples/example.png",
    )

    inspect_list_parser = subparsers.add_parser("inspect-list")
    inspect_list_parser.add_argument("--session-id")

    inspect_capture_plugin_parser = subparsers.add_parser("inspect-capture-plugin")
    inspect_capture_plugin_parser.add_argument("plugin_id")
    inspect_capture_plugin_parser.add_argument("plugin_command")
    inspect_capture_plugin_parser.add_argument("--args", default="{}")
    inspect_capture_plugin_parser.add_argument("--surface-kind", default="plugin")
    inspect_capture_plugin_parser.add_argument("--surface-path")
    inspect_capture_plugin_parser.add_argument("--route")
    inspect_capture_plugin_parser.add_argument("--component-hint")

    godot_debugger_parser = subparsers.add_parser(
        "godot-debugger-issues",
        aliases=["godot-debugger-warnings"],
        help="Guided Godot editor-debugger warning/error capture.",
    )
    godot_debugger_parser.add_argument("project_path", help="Path to the Godot project directory.")
    godot_debugger_parser.add_argument(
        "--no-prepare",
        action="store_true",
        help="Do not install/enable the managed probe when it is missing.",
    )
    godot_debugger_parser.add_argument(
        "--launch-editor",
        action="store_true",
        help="Launch the Godot editor with the managed probe installed, then rerun after starting the scene.",
    )
    godot_debugger_parser.add_argument("--godot-bin", default="godot")
    godot_debugger_parser.add_argument("--timeout-seconds", type=float, default=15.0)
    godot_debugger_parser.add_argument("--surface-path")
    godot_debugger_parser.add_argument(
        "--cleanup",
        action="store_true",
        help="Remove the managed probe and stale probe output for this project.",
    )

    godot_output_parser = subparsers.add_parser(
        "godot-output-console",
        help="Guided Godot editor Output console capture.",
    )
    godot_output_parser.add_argument("project_path", help="Path to the Godot project directory.")
    godot_output_parser.add_argument(
        "--no-prepare",
        action="store_true",
        help="Do not install/enable the managed probe when it is missing.",
    )
    godot_output_parser.add_argument(
        "--launch-editor",
        action="store_true",
        help="Launch the Godot editor with the managed probe installed, then rerun after starting the scene.",
    )
    godot_output_parser.add_argument("--godot-bin", default="godot")
    godot_output_parser.add_argument("--timeout-seconds", type=float, default=15.0)
    godot_output_parser.add_argument("--surface-path")
    godot_output_parser.add_argument(
        "--cleanup",
        action="store_true",
        help="Remove the managed probe and stale probe output for this project.",
    )

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--goal", required=True)
    validate_parser.add_argument("--code", action="append", default=[])
    validate_parser.add_argument("--artifact", action="append", default=[])
    validate_parser.add_argument(
        "--artifact-only",
        action="store_true",
        help="Validate inspect artifacts without requiring a code evidence handle.",
    )
    validate_parser.add_argument("--expect-artifact-text", action="append", default=[])
    validate_parser.add_argument("--no-runtime-issues", action="store_true")
    validate_parser.add_argument("--no-runtime-warnings", action="store_true")
    validate_parser.add_argument("--max-runtime-warnings", type=int)
    validate_parser.add_argument("--expect-runtime-warnings", type=int)
    return parser


def _command_for_project(
    root: Path,
    project_path: Path,
    *,
    workflow_command: str = "godot-debugger-issues",
    launch: bool = False,
) -> str:
    command = [
        "PYTHONPATH=src",
        "python",
        "src/sightline_main.py",
        "--root",
        str(root),
        "--format",
        "compact",
        workflow_command,
        str(project_path),
    ]
    if launch:
        command.append("--launch-editor")
    return " ".join(command)


def _artifact_issue_summary(artifact: dict[str, object]) -> dict[str, object]:
    metadata = artifact.get("metadata", {})
    if not isinstance(metadata, dict):
        metadata = {}
    return {
        "artifact_id": artifact.get("artifact_id"),
        "artifact_path": artifact.get("path"),
        "issue_count": metadata.get("issue_count", 0),
        "warning_count": metadata.get("warning_count", 0),
        "error_count": metadata.get("error_count", 0),
        "issues": metadata.get("issues", []),
        "extraction_status": metadata.get("extraction_status"),
        "diagnostics": metadata.get("diagnostics", []),
    }


def _artifact_output_summary(artifact: dict[str, object]) -> dict[str, object]:
    metadata = artifact.get("metadata", {})
    if not isinstance(metadata, dict):
        metadata = {}
    return {
        "artifact_id": artifact.get("artifact_id"),
        "artifact_path": artifact.get("path"),
        "line_count": metadata.get("line_count", 0),
        "text": metadata.get("text", ""),
        "lines": metadata.get("lines", []),
        "extraction_status": metadata.get("extraction_status"),
        "diagnostics": metadata.get("diagnostics", []),
    }


def _godot_probe_workflow(
    root: Path,
    project_path: Path,
    *,
    workflow_name: str,
    plugin_command: str,
    surface_kind: str,
    prepare: bool,
    launch_editor: bool,
    godot_bin: str,
    timeout_seconds: float,
    surface_path: str | None,
    cleanup: bool,
) -> tuple[Path, dict[str, object], list[dict[str, object]] | None]:
    project_path = project_path.expanduser().resolve()
    common_args = {"project_path": str(project_path)}
    if cleanup:
        cleanup_result = run_plugin_command(root, "godot", "cleanup-editor-session", common_args)
        return project_path, {
            "workflow": workflow_name,
            "status": "cleanup_done",
            "project_path": str(project_path),
            "cleanup_result": cleanup_result,
            "next_action": f"Probe removed. Run {workflow_name} again to prepare a new probe-backed session.",
        }, None

    status_result = run_plugin_command(root, "godot", "probe-status", common_args)
    probe_status = status_result.get("status", {}) if isinstance(status_result, dict) else {}
    steps: list[dict[str, object]] = [{"name": "probe-status", "result": status_result}]
    if (not probe_status.get("installed") or not probe_status.get("enabled")) and prepare:
        prepare_result = run_plugin_command(root, "godot", "prepare-editor-session", common_args)
        steps.append({"name": "prepare-editor-session", "result": prepare_result})
        probe_status = prepare_result.get("status", {}) if isinstance(prepare_result, dict) else {}

    if not probe_status.get("installed") or not probe_status.get("enabled"):
        return project_path, {
            "workflow": workflow_name,
            "status": "prepare_required",
            "project_path": str(project_path),
            "probe_status": probe_status,
            "steps": steps,
            "next_action": "Run without --no-prepare so Sightline can install and enable the managed editor probe.",
            "next_command": _command_for_project(root, project_path, workflow_command=workflow_name),
        }, None

    if not probe_status.get("loaded"):
        if launch_editor:
            launch_result = run_plugin_command(
                root,
                "godot",
                "launch-editor-session",
                {
                    "project_path": str(project_path),
                    "godot_bin": godot_bin,
                    "timeout_seconds": timeout_seconds,
                    "ensure_probe": False,
                },
            )
            steps.append({"name": "launch-editor-session", "result": launch_result})
            return project_path, {
                "workflow": workflow_name,
                "status": "editor_launched",
                "project_path": str(project_path),
                "probe_loaded": launch_result.get("probe_loaded"),
                "probe_status": launch_result.get("status"),
                "steps": steps,
                "next_action": f"Run the scene/app from this editor, then rerun {workflow_name} to capture semantic editor evidence.",
                "next_command": _command_for_project(root, project_path, workflow_command=workflow_name),
            }, None
        return project_path, {
            "workflow": workflow_name,
            "status": "restart_required",
            "project_path": str(project_path),
            "probe_status": probe_status,
            "steps": steps,
            "next_action": "Start or restart the Godot editor after probe preparation, then run the scene/app and rerun this command.",
            "next_command": _command_for_project(root, project_path, workflow_command=workflow_name, launch=True),
        }, None

    inspect_result = create_plugin_capture_session(
        root,
        SurfaceTarget(kind=surface_kind, path=surface_path or str(project_path)),
        "godot",
        plugin_command,
        {"project_path": str(project_path)},
    )
    inspect_payload = inspect_result.to_dict()
    return project_path, {
        "workflow": workflow_name,
        "status": "captured",
        "project_path": str(project_path),
        "probe_status": probe_status,
        "session_id": inspect_payload["session_id"],
        "artifacts": inspect_payload["artifacts"],
        "steps": steps + [{"name": plugin_command, "result": inspect_payload}],
    }, inspect_payload["artifacts"]


def _godot_debugger_issues_workflow(
    root: Path,
    project_path: Path,
    *,
    prepare: bool,
    launch_editor: bool,
    godot_bin: str,
    timeout_seconds: float,
    surface_path: str | None,
    cleanup: bool,
) -> dict[str, object]:
    project_path, result, artifacts = _godot_probe_workflow(
        root,
        project_path,
        workflow_name="godot-debugger-issues",
        plugin_command="report-editor-debugger-warnings",
        surface_kind="godot-editor-debugger",
        prepare=prepare,
        launch_editor=launch_editor,
        godot_bin=godot_bin,
        timeout_seconds=timeout_seconds,
        surface_path=surface_path,
        cleanup=cleanup,
    )
    if result["status"] != "captured" or artifacts is None:
        return result
    artifact_summaries = [_artifact_issue_summary(item) for item in artifacts]
    issue_count = sum(int(item.get("issue_count") or 0) for item in artifact_summaries)
    warning_count = sum(int(item.get("warning_count") or 0) for item in artifact_summaries)
    error_count = sum(int(item.get("error_count") or 0) for item in artifact_summaries)
    result.update(
        {
            "artifact_summaries": artifact_summaries,
            "issue_count": issue_count,
            "warning_count": warning_count,
            "error_count": error_count,
            "next_action": "Use the artifact_id in validation or inspect-list; debugger warning/error text is in artifact_summaries[].issues.",
        }
    )
    return result


def _godot_output_console_workflow(
    root: Path,
    project_path: Path,
    *,
    prepare: bool,
    launch_editor: bool,
    godot_bin: str,
    timeout_seconds: float,
    surface_path: str | None,
    cleanup: bool,
) -> dict[str, object]:
    _, result, artifacts = _godot_probe_workflow(
        root,
        project_path,
        workflow_name="godot-output-console",
        plugin_command="report-editor-output-console",
        surface_kind="godot-output-console",
        prepare=prepare,
        launch_editor=launch_editor,
        godot_bin=godot_bin,
        timeout_seconds=timeout_seconds,
        surface_path=surface_path,
        cleanup=cleanup,
    )
    if result["status"] != "captured" or artifacts is None:
        return result
    artifact_summaries = [_artifact_output_summary(item) for item in artifacts]
    line_count = sum(int(item.get("line_count") or 0) for item in artifact_summaries)
    result.update(
        {
            "artifact_summaries": artifact_summaries,
            "line_count": line_count,
            "next_action": "Use the artifact_id in validation or inspect-list; output text is in artifact_summaries[].text.",
        }
    )
    return result


def main() -> int:
    args = _parser().parse_args()
    root = Path(args.root).resolve()
    store = SessionStore(root)

    def emit(payload: object) -> None:
        if args.format == "compact":
            print(render_compact(payload))
            return
        print(json.dumps(payload, indent=2))

    if args.command == "files":
        if (
            args.extension
            or args.size_gt is not None
            or args.size_lt is not None
            or args.path_contains
            or args.mtime_after_days is not None
            or args.mtime_before_days is not None
        ):
            now = time.time()
            files = list_repo_files_filtered(
                root,
                extension=args.extension,
                size_gt=args.size_gt,
                size_lt=args.size_lt,
                path_contains=args.path_contains,
                include_hidden=args.include_hidden,
                mtime_after=(now - args.mtime_after_days * 86400) if args.mtime_after_days is not None else None,
                mtime_before=(now - args.mtime_before_days * 86400) if args.mtime_before_days is not None else None,
            )
        else:
            files = list_repo_files(root)
            if not args.include_hidden:
                files = [item for item in files if not item.path.split("/", 1)[0].startswith(".")]
        if args.summary_by:
            rows = summarize_repo_files(
                files,
                group_by=args.summary_by,
                exclude=set(args.exclude),
                require_nested=args.require_nested,
                exclude_hidden=not args.include_hidden,
                sort_by=args.sort_by,
            )
            if args.limit > 0:
                rows = rows[: args.limit]
            emit(rows)
            return 0
        if args.sort_files_by == "path":
            files.sort(key=lambda item: item.path)
        elif args.sort_files_by == "size":
            files.sort(key=lambda item: (item.size, item.path))
        elif args.sort_files_by == "mtime":
            files.sort(key=lambda item: (item.mtime, item.path))
        elif args.sort_files_by == "language":
            files.sort(key=lambda item: (item.language, item.path))
        if args.sort_order == "desc":
            files.reverse()
        if args.limit > 0:
            files = files[: args.limit]
        emit([item.to_dict() for item in files])
        return 0

    if args.command == "search":
        handles = search_code(
            root,
            args.query,
            mode=args.mode,
            limit=args.limit,
            options=SearchOptions(
                path_contains=args.path_contains,
                path_prefix=args.path_prefix,
                exclude_paths=args.exclude_path,
                extension=args.extension,
                include_hidden=args.include_hidden,
                intent=args.intent,
                prefer_code=args.prefer_code,
                prefer_tests=args.prefer_tests,
                prefer_config=args.prefer_config,
                prefer_impl=args.prefer_impl,
                deprioritize_docs=args.deprioritize_docs,
                deprioritize_experiments=args.deprioritize_experiments,
                group_by_file=args.group_by_file,
            ),
        )
        store.save_handles(handles)
        emit([handle.to_dict() for handle in handles])
        return 0

    if args.command == "plugin-list":
        emit([manifest.to_dict() for manifest in list_plugins(root)])
        return 0

    if args.command == "plugin-info":
        emit(get_plugin(root, args.plugin_id).to_dict())
        return 0

    if args.command == "plugin-help":
        emit(plugin_help(root, args.plugin_id))
        return 0

    if args.command == "plugin-validate":
        emit(plugin_validate_target(root, args.target))
        return 0

    if args.command == "plugin-install":
        manifest = install_plugin(root, Path(args.source_path))
        emit(manifest.to_dict())
        return 0

    if args.command == "plugin-init":
        created = init_plugin(Path(args.target_dir), args.id, args.name, args.description)
        emit({"created": [str(path) for path in created], "plugin_id": args.id})
        return 0

    if args.command == "plugin-run":
        parsed_args = json.loads(args.args)
        emit(run_plugin_command(root, args.plugin_id, args.plugin_command, parsed_args))
        return 0

    if args.command == "subsystem":
        report = build_subsystem_report(root, args.token, limit=args.limit)
        emit(report.to_dict())
        return 0

    if args.command == "where-defined":
        report = where_defined(root, args.symbol, limit=args.limit)
        store.save_handles([entry.handle for entry in report.entries])
        emit(report.to_dict())
        return 0

    if args.command == "where-tested":
        report = where_tested(root, args.symbol, limit=args.limit)
        store.save_handles([entry.handle for entry in report.entries])
        emit(report.to_dict())
        return 0

    if args.command == "locate-edit":
        report = locate_edit(root, args.query, limit=args.limit)
        store.save_handles([entry.handle for entry in report.entries])
        emit(report.to_dict())
        return 0

    if args.command == "trace-topic":
        report = trace_topic(root, args.topic, limit=args.limit)
        store.save_handles([entry.handle for entry in report.entries])
        emit(report.to_dict())
        return 0

    if args.command == "read":
        handle = store.get_handle(args.result_id)
        if handle is None:
            raise SystemExit(f"unknown result_id: {args.result_id}")
        context = read_context(
            root,
            handle.path,
            max(1, handle.start_line - args.before),
            handle.end_line + args.after,
            result_id=handle.result_id,
        )
        emit(context.to_dict())
        return 0

    if args.command == "read-path":
        context = read_context(root, args.path, args.start, args.end)
        emit(context.to_dict())
        return 0

    if args.command == "handles":
        emit([handle.to_dict() for handle in store.load_handles()])
        return 0

    if args.command == "map":
        emit(build_repo_map(root, max_depth=args.max_depth).to_dict())
        return 0

    if args.command == "inspect-attach":
        target = SurfaceTarget(
            kind=args.surface_kind,
            path=args.surface_path,
            route=args.route,
            component_hint=args.component_hint,
        )
        artifacts: list[tuple[str, str]] = []
        for artifact in args.artifact:
            if ":" not in artifact:
                raise SystemExit(f"invalid artifact spec: {artifact}")
            kind, path = artifact.split(":", 1)
            artifacts.append((kind, path))
        result = create_attachment_session(root, target, artifacts)
        emit(result.to_dict())
        return 0

    if args.command == "inspect-list":
        inspect_store = InspectStore(root)
        payload = {
            "sessions": [session.to_dict() for session in inspect_store.list_sessions()],
            "artifacts": [artifact.to_dict() for artifact in inspect_store.list_artifacts(args.session_id)],
        }
        emit(payload)
        return 0

    if args.command == "inspect-capture-plugin":
        target = SurfaceTarget(
            kind=args.surface_kind,
            path=args.surface_path,
            route=args.route,
            component_hint=args.component_hint,
        )
        parsed_args = json.loads(args.args)
        result = create_plugin_capture_session(root, target, args.plugin_id, args.plugin_command, parsed_args)
        emit(result.to_dict())
        return 0

    if args.command in {"godot-debugger-issues", "godot-debugger-warnings"}:
        result = _godot_debugger_issues_workflow(
            root,
            Path(args.project_path),
            prepare=not args.no_prepare,
            launch_editor=args.launch_editor,
            godot_bin=args.godot_bin,
            timeout_seconds=args.timeout_seconds,
            surface_path=args.surface_path,
            cleanup=args.cleanup,
        )
        emit(result)
        return 0

    if args.command == "godot-output-console":
        result = _godot_output_console_workflow(
            root,
            Path(args.project_path),
            prepare=not args.no_prepare,
            launch_editor=args.launch_editor,
            godot_bin=args.godot_bin,
            timeout_seconds=args.timeout_seconds,
            surface_path=args.surface_path,
            cleanup=args.cleanup,
        )
        emit(result)
        return 0

    if args.command == "validate":
        result = validate_evidence(
            root,
            args.goal,
            args.code,
            args.artifact,
            artifact_only=args.artifact_only,
            expected_artifact_text=args.expect_artifact_text,
            require_no_runtime_issues=args.no_runtime_issues,
            max_runtime_warnings=0 if args.no_runtime_warnings else args.max_runtime_warnings,
            expected_runtime_warnings=args.expect_runtime_warnings,
        )
        emit(result.to_dict())
        return 0

    raise SystemExit(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
