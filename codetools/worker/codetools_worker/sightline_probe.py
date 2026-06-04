"""Sightline (code-probe) → unified envelope adapter (P3.2).

Wraps the vendored sightline library (vendored/sightline) and exposes exactly
three handler functions, one per op-driven MCP tool:

  explore  → minerva_codetools_explore   (search / navigation)
  inspect  → minerva_codetools_inspect   (artifact capture / list / status)
  validate → minerva_codetools_validate  (validate evidence against a goal)

Import strategy: prepend vendored/sightline to sys.path once on first import.
This satisfies the vendoring rule (no edits under vendored/) because sightline
uses absolute package-internal imports (``from sightline.x import ...``) which
resolve correctly once the package root is on sys.path.

rg on PATH: sightline's search.py and files.py invoke ``rg`` by bare name.
Before any call that may invoke rg we inject the bundled rg's directory into
os.environ["PATH"] (idempotent).  Dev fallback to system rg / Path.rglob
already exists inside sightline.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# One-time sys.path injection (vendoring seam — documented in VENDORING.md)
# ---------------------------------------------------------------------------

_VENDORED_SIGHTLINE = Path(__file__).parent.parent / "vendored" / "sightline"
_VENDORED_GODOT = _VENDORED_SIGHTLINE / "godot"

if str(_VENDORED_SIGHTLINE) not in sys.path:
    sys.path.insert(0, str(_VENDORED_SIGHTLINE))

# Lazy import — deferred until _ensure_sightline_imports() is called so that
# import-time errors surface per-call rather than crashing the worker.
_sightline_imported = False
_explore = None
_search_mod = None
_files_mod = None
_inspect_mod = None
_validate_mod = None
_models_mod = None
_godot_plugin = None


def _ensure_sightline_imports():
    global _sightline_imported, _explore, _search_mod, _files_mod
    global _inspect_mod, _validate_mod, _models_mod, _godot_plugin
    if _sightline_imported:
        return
    import sightline.explore as _e
    import sightline.search as _s
    import sightline.files as _f
    import sightline.inspect as _i
    import sightline.validate as _v
    import sightline.models as _m
    _explore = _e
    _search_mod = _s
    _files_mod = _f
    _inspect_mod = _i
    _validate_mod = _v
    _models_mod = _m

    # godot/plugin.py is not a proper package (no __init__.py in godot/);
    # load it via importlib so it can still access its own sibling modules.
    _spec = importlib.util.spec_from_file_location(
        "sightline_godot_plugin",
        str(_VENDORED_GODOT / "plugin.py"),
    )
    _gmod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_gmod)
    _godot_plugin = _gmod

    _sightline_imported = True


# ---------------------------------------------------------------------------
# Local imports from this package
# ---------------------------------------------------------------------------

from . import envelope
from .errors import ToolError
from .files.paths import expand_and_resolve, validate_dir
from .files.rg_finder import find_rg

# ---------------------------------------------------------------------------
# rg PATH injection (idempotent)
# ---------------------------------------------------------------------------

_rg_injected = False


def _ensure_rg_on_path():
    global _rg_injected
    if _rg_injected:
        return
    rg_path = find_rg()
    if rg_path:
        rg_dir = str(Path(rg_path).parent)
        current_path = os.environ.get("PATH", "")
        if rg_dir not in current_path.split(os.pathsep):
            os.environ["PATH"] = rg_dir + os.pathsep + current_path
    _rg_injected = True


# ---------------------------------------------------------------------------
# Root resolution helper (shared by all three tools)
# ---------------------------------------------------------------------------

def _resolve_root(params: dict) -> Path:
    """Resolve root param → validated Path; defaults to cwd."""
    raw = params.get("root") or params.get("path") or ""
    if raw:
        resolved = expand_and_resolve(raw)
    else:
        resolved = Path.cwd()
    p, err = validate_dir(resolved)
    if err:
        raise ToolError(err, kind="not_found")
    return p


# ---------------------------------------------------------------------------
# 1. explore — search / navigation
# ---------------------------------------------------------------------------

_EXPLORE_OPS = frozenset(
    ["search", "where-defined", "where-tested", "locate-edit", "trace-topic", "files"]
)


def explore(params: dict) -> dict:
    """Handler for minerva_codetools_explore.

    Routes by params["op"] to the appropriate sightline.explore / .search /
    .files function, returns a unified envelope.
    """
    _ensure_sightline_imports()
    _ensure_rg_on_path()

    op = params.get("op")
    if not op or op not in _EXPLORE_OPS:
        raise ToolError(
            "op must be one of: %s" % ", ".join(sorted(_EXPLORE_OPS)),
            kind="invalid_args",
        )

    root = _resolve_root(params)
    query = params.get("query", "")
    limit_raw = params.get("limit")
    limit = int(limit_raw) if isinstance(limit_raw, (int, float)) and not isinstance(limit_raw, bool) else None

    # ---- files ----
    if op == "files":
        repo_files = _files_mod.list_repo_files(root)
        FILE_CAP = 2000
        truncated = len(repo_files) > FILE_CAP
        repo_files = repo_files[:FILE_CAP]
        summary = "repo files: %d file(s)%s" % (
            len(repo_files), " (truncated to %d)" % FILE_CAP if truncated else ""
        )
        return envelope.ok(
            summary,
            artifacts=[{
                "type": "repo_files",
                "root": str(root),
                "truncated": truncated,
                "count": len(repo_files),
                "files": [f.to_dict() for f in repo_files],
            }],
        )

    # ---- ops that require query ----
    if not query or not isinstance(query, str):
        raise ToolError("query is required for op %r" % op, kind="invalid_args")

    if op == "search":
        regex = params.get("regex", False)
        mode = "regex" if regex else "literal"
        intent = params.get("intent")
        path_contains = params.get("path_contains")
        extension = params.get("extension")
        options = _search_mod.SearchOptions(
            intent=intent,
            path_contains=path_contains,
            extension=extension,
        )
        results = _search_mod.search_code(
            root, query, mode=mode,
            limit=limit or 20,
            options=options,
        )
        return envelope.ok(
            "search %r: %d result(s) (mode=%s)" % (query, len(results), mode),
            artifacts=[{
                "type": "search_results",
                "query": query,
                "mode": mode,
                "root": str(root),
                "count": len(results),
                "results": [r.to_dict() for r in results],
            }],
        )

    if op == "where-defined":
        report = _explore.where_defined(root, query, limit=limit or 5)
        return envelope.ok(
            "where-defined %r: %d entry(s)" % (query, len(report.entries)),
            artifacts=[{"type": "explore_report", **report.to_dict()}],
        )

    if op == "where-tested":
        report = _explore.where_tested(root, query, limit=limit or 5)
        return envelope.ok(
            "where-tested %r: %d entry(s)" % (query, len(report.entries)),
            artifacts=[{"type": "explore_report", **report.to_dict()}],
        )

    if op == "locate-edit":
        report = _explore.locate_edit(root, query, limit=limit or 5)
        return envelope.ok(
            "locate-edit %r: %d entry(s)" % (query, len(report.entries)),
            artifacts=[{"type": "explore_report", **report.to_dict()}],
        )

    if op == "trace-topic":
        report = _explore.trace_topic(root, query, limit=limit or 6)
        return envelope.ok(
            "trace-topic %r: %d entry(s)" % (query, len(report.entries)),
            artifacts=[{"type": "explore_report", **report.to_dict()}],
        )

    # Should be unreachable given the frozenset guard above.
    raise ToolError("unhandled op: %r" % op, kind="invalid_args")


# ---------------------------------------------------------------------------
# 2. inspect — artifact capture / list / status
# ---------------------------------------------------------------------------

_INSPECT_OPS = frozenset(["attach", "list", "status", "prepare", "remove-probe"])

# X11/visual capture ops — feature-gated to Linux + a live DISPLAY (P3.3). The
# cross-platform debugger/output JSON capture (the GDScript probe) is NOT gated.
_VISUAL_OPS = frozenset(["capture-visual"])

# Live editor-launch ops spawn a Godot editor and poll for probe output — this
# is the Option C human-in-the-loop workflow (P3.6), intentionally not wired
# through MCP (the human opens their own editor; the probe writes the JSON).
_LIVE_OPS = frozenset(["godot-debugger-issues", "godot-output-console", "launch-editor"])


def _visual_capture_available() -> tuple[bool, str]:
    """X11 window/visual capture requires Linux with a live DISPLAY."""
    import platform as _pf
    if _pf.system().lower() != "linux":
        return False, "X11 visual capture requires Linux (host is %s)" % _pf.system()
    if not os.environ.get("DISPLAY"):
        return False, "X11 visual capture requires a DISPLAY (none set — headless)"
    return True, ""


def inspect(params: dict) -> dict:
    """Handler for minerva_codetools_inspect.

    Routes by params["op"]:
      attach → create_attachment_session
      list   → InspectStore.list_sessions / list_artifacts
      status → _probe_status (read-only, no Godot launch)
    """
    _ensure_sightline_imports()

    op = params.get("op")
    if op in _LIVE_OPS:
        return envelope.error(
            "live Godot editor capture is the Option C human-in-the-loop workflow "
            "(P3.6) — open the editor with the probe installed (op=prepare) and the "
            "probe writes debugger_state.json; it is not driven through MCP",
            kind="not_implemented",
        )
    if op in _VISUAL_OPS:
        available, reason = _visual_capture_available()
        if not available:
            return envelope.error(reason, kind="capability_unavailable")
        return envelope.error(
            "X11 visual-capture target selection is not yet wired; the supported "
            "path is the cross-platform debugger/output JSON capture",
            kind="not_implemented",
        )
    if not op or op not in _INSPECT_OPS:
        raise ToolError(
            "op must be one of: %s" % ", ".join(sorted(_INSPECT_OPS)),
            kind="invalid_args",
        )

    # ---- attach ----
    if op == "attach":
        root = _resolve_root(params)
        surface_kind = params.get("surface_kind", "path")
        surface_path = params.get("surface_path", "")
        route = params.get("route")
        component_hint = params.get("component_hint")
        target = _models_mod.SurfaceTarget(
            kind=surface_kind,
            path=surface_path or None,
            route=route,
            component_hint=component_hint,
        )
        raw_artifacts = params.get("artifacts") or []
        if not isinstance(raw_artifacts, list):
            raise ToolError("artifacts must be a list of [kind, path] pairs", kind="invalid_args")
        artifact_pairs: list[tuple[str, str]] = []
        for item in raw_artifacts:
            if isinstance(item, (list, tuple)) and len(item) == 2:
                artifact_pairs.append((str(item[0]), str(item[1])))
            elif isinstance(item, dict) and "kind" in item and "path" in item:
                artifact_pairs.append((str(item["kind"]), str(item["path"])))
            else:
                raise ToolError(
                    "each artifact must be a [kind, path] pair or {kind, path} dict",
                    kind="invalid_args",
                )
        result = _inspect_mod.create_attachment_session(root, target, artifact_pairs)
        return envelope.ok(
            "inspect attach: session %s — %d artifact(s)" % (result.session_id, len(result.artifacts)),
            artifacts=[{"type": "inspect_result", **result.to_dict()}],
        )

    # ---- list ----
    if op == "list":
        root = _resolve_root(params)
        store = _inspect_mod.InspectStore(root)
        session_id = params.get("session_id")
        if session_id:
            art_handles = store.list_artifacts(session_id=session_id)
            return envelope.ok(
                "inspect list artifacts: session %s — %d artifact(s)" % (session_id, len(art_handles)),
                artifacts=[{
                    "type": "inspect_artifacts",
                    "session_id": session_id,
                    "root": str(root),
                    "count": len(art_handles),
                    "artifacts": [a.to_dict() for a in art_handles],
                }],
            )
        sessions = store.list_sessions()
        return envelope.ok(
            "inspect list sessions: %d session(s)" % len(sessions),
            artifacts=[{
                "type": "inspect_sessions",
                "root": str(root),
                "count": len(sessions),
                "sessions": [s.to_dict() for s in sessions],
            }],
        )

    # ---- status ----
    if op == "status":
        project_path_raw = params.get("project_path") or params.get("root") or params.get("path") or ""
        if project_path_raw:
            project_path = expand_and_resolve(project_path_raw)
        else:
            project_path = Path.cwd()
        status_dict = _godot_plugin._probe_status(project_path)
        return envelope.ok(
            "probe status: installed=%s enabled=%s loaded=%s" % (
                status_dict.get("installed"),
                status_dict.get("enabled"),
                status_dict.get("loaded"),
            ),
            artifacts=[{"type": "probe_status", **status_dict}],
        )

    # ---- prepare (install the editor probe into a Godot project; cross-platform) ----
    if op == "prepare":
        project_path = _resolve_project_path_param(params)
        try:
            result = _godot_plugin._ensure_editor_probe(
                {"project_path": str(project_path)},
                {"plugin_dir": str(_VENDORED_GODOT), "root": str(project_path)},
            )
        except ValueError as exc:
            return envelope.error(str(exc), kind="invalid_args")
        return envelope.ok(
            "prepare probe: %s (project.godot changed=%s)" % (
                result.get("project_path"), result.get("project_godot_changed")),
            artifacts=[{"type": "probe_prepare", **result}],
        )

    # ---- remove-probe (uninstall the editor probe; cross-platform, reversible) ----
    if op == "remove-probe":
        project_path = _resolve_project_path_param(params)
        result = _godot_plugin._remove_editor_probe({"project_path": str(project_path)})
        return envelope.ok(
            "remove probe: %s (removed=%s)" % (
                result.get("project_path"), result.get("removed")),
            artifacts=[{"type": "probe_remove", **result}],
        )

    # Unreachable.
    raise ToolError("unhandled op: %r" % op, kind="invalid_args")


def _resolve_project_path_param(params: dict) -> Path:
    """Resolve a Godot project path from params (project_path|root|path|cwd)."""
    raw = params.get("project_path") or params.get("root") or params.get("path") or ""
    return expand_and_resolve(raw) if raw else Path.cwd()


# ---------------------------------------------------------------------------
# 3. validate — validate evidence against a goal
# ---------------------------------------------------------------------------

def validate(params: dict) -> dict:
    """Handler for minerva_codetools_validate.

    Calls sightline.validate.validate_evidence and returns a validation_result
    artifact.
    """
    _ensure_sightline_imports()

    goal = params.get("goal")
    if not goal or not isinstance(goal, str):
        raise ToolError("goal must be a non-empty string", kind="invalid_args")

    root = _resolve_root(params)

    code_result_ids = params.get("code_result_ids") or []
    if not isinstance(code_result_ids, list):
        raise ToolError("code_result_ids must be a list", kind="invalid_args")

    artifact_ids = params.get("artifact_ids") or []
    if not isinstance(artifact_ids, list):
        raise ToolError("artifact_ids must be a list", kind="invalid_args")

    artifact_only = bool(params.get("artifact_only", False))
    expected_artifact_text = params.get("expected_artifact_text") or []
    if not isinstance(expected_artifact_text, list):
        raise ToolError("expected_artifact_text must be a list of strings", kind="invalid_args")

    require_no_runtime_issues = bool(params.get("require_no_runtime_issues", False))

    max_runtime_warnings_raw = params.get("max_runtime_warnings")
    max_runtime_warnings: int | None = None
    if max_runtime_warnings_raw is not None:
        if isinstance(max_runtime_warnings_raw, (int, float)) and not isinstance(max_runtime_warnings_raw, bool):
            max_runtime_warnings = int(max_runtime_warnings_raw)
        else:
            raise ToolError("max_runtime_warnings must be an integer", kind="invalid_args")

    expected_runtime_warnings_raw = params.get("expected_runtime_warnings")
    expected_runtime_warnings: int | None = None
    if expected_runtime_warnings_raw is not None:
        if isinstance(expected_runtime_warnings_raw, (int, float)) and not isinstance(expected_runtime_warnings_raw, bool):
            expected_runtime_warnings = int(expected_runtime_warnings_raw)
        else:
            raise ToolError("expected_runtime_warnings must be an integer", kind="invalid_args")

    record = _validate_mod.validate_evidence(
        root,
        goal,
        [str(i) for i in code_result_ids],
        [str(i) for i in artifact_ids],
        artifact_only=artifact_only,
        expected_artifact_text=[str(t) for t in expected_artifact_text],
        require_no_runtime_issues=require_no_runtime_issues,
        max_runtime_warnings=max_runtime_warnings,
        expected_runtime_warnings=expected_runtime_warnings,
    )

    return envelope.ok(
        "validate: %r → %s (confidence=%.2f)" % (goal, record.status, record.confidence),
        artifacts=[{"type": "validation_result", **record.to_dict()}],
    )
