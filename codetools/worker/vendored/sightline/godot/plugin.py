from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Callable


WINDOW_RE = re.compile(
    r'^\s*(0x[0-9a-f]+)\s+"(?P<title>[^"]*)":\s+\("(?P<class1>[^"]*)" "(?P<class2>[^"]*)"\)\s+'
    r'(?P<width>\d+)x(?P<height>\d+)\+(?P<x>-?\d+)\+(?P<y>-?\d+)'
)
ISSUE_RE = re.compile(r"^\s*(SCRIPT ERROR|ERROR|WARNING|DEBUGGER)\s*:", re.IGNORECASE)
PROJECT_NAME_RE = re.compile(r'^\s*config/name\s*=\s*"(?P<name>[^"]+)"\s*$', re.MULTILINE)
PROBE_FRESH_SECONDS = 3.0


def _run(command: list[str]) -> str:
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or f"command failed: {' '.join(command)}")
    return completed.stdout


def _run_optional(command: list[str]) -> tuple[int, str, str]:
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    return completed.returncode, completed.stdout, completed.stderr


def _host_platform() -> str:
    system = platform.system().lower()
    if system == "darwin":
        return "macos"
    if system.startswith("windows") or system == "cygwin":
        return "windows"
    return system or "unknown"


def _command_available(command: str) -> bool:
    return shutil.which(command) is not None


def _artifact_dir(context: dict[str, Any]) -> Path:
    root = Path(context["root"])
    path = root / ".sightline" / "plugin_artifacts" / "godot"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _probe_source_dir(context: dict[str, Any]) -> Path:
    return Path(context["plugin_dir"]) / "probe" / "addons" / "sightline_probe"


def _probe_target_dir(project_path: Path) -> Path:
    return project_path / "addons" / "sightline_probe"


def _probe_output_path(project_path: Path) -> Path:
    return project_path / ".sightline" / "godot_probe" / "debugger_state.json"


def _probe_plugin_cfg(project_path: Path) -> Path:
    return _probe_target_dir(project_path) / "plugin.cfg"


def _managed_probe_manifest(project_path: Path) -> Path:
    return _probe_target_dir(project_path) / ".sightline-managed.json"


def _resolve_project_path(
    *,
    project_path: str | None,
    surface_id: str | None = None,
    pid: int | None = None,
) -> Path:
    if project_path:
        return Path(project_path).expanduser().resolve()
    surface: dict[str, Any] | None = None
    if surface_id:
        surface = _surface_for_id(surface_id)
    elif pid is not None:
        surface = _surface_for_pid(pid)
    if surface is not None:
        candidate = surface.get("project_path") or surface.get("cwd")
        if isinstance(candidate, str) and candidate:
            return Path(candidate).expanduser().resolve()
    raise ValueError("project_path, surface_id with project_path, or pid with project_path is required")


def _project_godot_path(project_path: Path) -> Path:
    return project_path / "project.godot"


def _enabled_plugins(text: str) -> list[str]:
    match = re.search(r'(?m)^enabled\s*=\s*PackedStringArray\((?P<body>.*)\)\s*$', text)
    if not match:
        return []
    return re.findall(r'"([^"]+)"', match.group("body"))


def _format_enabled_plugins(paths: list[str]) -> str:
    quoted = ", ".join(f'"{path}"' for path in paths)
    return f"enabled=PackedStringArray({quoted})"


def _is_probe_enabled(project_path: Path) -> bool:
    project_file = _project_godot_path(project_path)
    if not project_file.exists():
        return False
    return "res://addons/sightline_probe/plugin.cfg" in _enabled_plugins(
        project_file.read_text(encoding="utf-8", errors="replace")
    )


def _set_probe_enabled(project_path: Path, enabled: bool) -> bool:
    project_file = _project_godot_path(project_path)
    if not project_file.exists():
        raise ValueError(f"missing Godot project file: {project_file}")
    text = project_file.read_text(encoding="utf-8", errors="replace")
    probe_path = "res://addons/sightline_probe/plugin.cfg"
    plugins = _enabled_plugins(text)
    changed = False
    if enabled and probe_path not in plugins:
        plugins.append(probe_path)
        changed = True
    if not enabled and probe_path in plugins:
        plugins = [path for path in plugins if path != probe_path]
        changed = True
    if not changed:
        return False
    original_endswith_single_newline = text.endswith("\n") and not text.endswith("\n\n")
    original_endswith_no_newline = not text.endswith("\n")
    enabled_line = _format_enabled_plugins(plugins)
    has_editor_plugins = re.search(r"(?m)^\[editor_plugins\]\s*$", text)
    if has_editor_plugins:
        if not enabled and not plugins:
            text = re.sub(
                r"(?ms)^\[editor_plugins\]\s*\n(?:enabled\s*=\s*PackedStringArray\(.*\)\s*\n?)?(?=\n?\[|\Z)",
                "",
                text,
                count=1,
            )
        elif re.search(r"(?m)^enabled\s*=\s*PackedStringArray\(.*\)\s*$", text):
            text = re.sub(r"(?m)^enabled\s*=\s*PackedStringArray\(.*\)\s*$", enabled_line, text, count=1)
        else:
            text = re.sub(r"(?m)^(\[editor_plugins\]\s*)$", f"\\1\n{enabled_line}", text, count=1)
    else:
        if not text.endswith("\n"):
            text += "\n"
        text += f"\n[editor_plugins]\n{enabled_line}\n"
    if original_endswith_no_newline:
        text = text.rstrip("\n")
    elif original_endswith_single_newline:
        text = text.rstrip("\n") + "\n"
    project_file.write_text(text, encoding="utf-8")
    return True


def _probe_status(project_path: Path) -> dict[str, Any]:
    output_path = _probe_output_path(project_path)
    installed = _probe_plugin_cfg(project_path).exists()
    enabled = _is_probe_enabled(project_path)
    status: dict[str, Any] = {
        "project_path": str(project_path),
        "installed": installed,
        "enabled": enabled,
        "loaded": False,
        "plugin_cfg": str(_probe_plugin_cfg(project_path)),
        "output_path": str(output_path),
        "output_exists": output_path.exists(),
        "output_fresh": False,
        "diagnostics": [],
    }
    if not _project_godot_path(project_path).exists():
        status["diagnostics"].append(f"missing project.godot at {_project_godot_path(project_path)}")
    if output_path.exists():
        output_stat = output_path.stat()
        output_age_seconds = max(0.0, time.time() - output_stat.st_mtime)
        status["output_mtime"] = output_stat.st_mtime
        status["output_age_seconds"] = output_age_seconds
        status["output_fresh"] = output_age_seconds <= PROBE_FRESH_SECONDS
        status["loaded"] = installed and enabled and status["output_fresh"]
        status["output_size"] = output_stat.st_size
    return status


def _clear_probe_output(project_path: Path) -> bool:
    output_dir = project_path / ".sightline" / "godot_probe"
    if not output_dir.exists():
        return False
    shutil.rmtree(output_dir)
    return True


def _ensure_editor_probe(args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    project_path = _resolve_project_path(
        project_path=args.get("project_path"),
        surface_id=args.get("surface_id"),
        pid=args.get("pid"),
    )
    if not _project_godot_path(project_path).exists():
        raise ValueError(f"not a Godot project path: {project_path}")
    source_dir = _probe_source_dir(context)
    target_dir = _probe_target_dir(project_path)
    output_removed = _clear_probe_output(project_path)
    target_dir.parent.mkdir(parents=True, exist_ok=True)
    files: list[str] = []
    if target_dir.exists():
        shutil.rmtree(target_dir)
    shutil.copytree(source_dir, target_dir)
    for path in sorted(target_dir.rglob("*")):
        if path.is_file():
            files.append(str(path.relative_to(project_path)))
    _managed_probe_manifest(project_path).write_text(
        json.dumps(
            {
                "installed_by": "sightline",
                "purpose": "editor/debugger inspection",
                "reversible": True,
                "files": files,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    project_changed = _set_probe_enabled(project_path, True)
    status = _probe_status(project_path)
    return {
        "plugin": "godot",
        "command": "ensure-editor-probe",
        "project_path": str(project_path),
        "installed_files": files,
        "project_godot_changed": project_changed,
        "stale_output_removed": output_removed,
        "status": status,
        "next_step": "Start or restart the Godot editor after installing the probe; running editors do not reliably hot-load it.",
    }


def _remove_editor_probe(args: dict[str, Any]) -> dict[str, Any]:
    project_path = _resolve_project_path(
        project_path=args.get("project_path"),
        surface_id=args.get("surface_id"),
        pid=args.get("pid"),
    )
    target_dir = _probe_target_dir(project_path)
    project_changed = _set_probe_enabled(project_path, False)
    removed = False
    if target_dir.exists():
        shutil.rmtree(target_dir)
        removed = True
    output_removed = _clear_probe_output(project_path)
    return {
        "plugin": "godot",
        "command": "remove-editor-probe",
        "project_path": str(project_path),
        "removed": removed,
        "output_removed": output_removed,
        "project_godot_changed": project_changed,
        "status": _probe_status(project_path),
    }


def _probe_status_command(args: dict[str, Any]) -> dict[str, Any]:
    project_path = _resolve_project_path(
        project_path=args.get("project_path"),
        surface_id=args.get("surface_id"),
        pid=args.get("pid"),
    )
    return {"plugin": "godot", "command": "probe-status", "status": _probe_status(project_path)}


def _numeric_arg(args: dict[str, Any], name: str, default: float, *, minimum: float = 0.0) -> float:
    value = args.get(name, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a number")
    value = float(value)
    if value < minimum:
        raise ValueError(f"{name} must be at least {minimum}")
    return value


def _bool_arg(args: dict[str, Any], name: str, default: bool) -> bool:
    value = args.get(name, default)
    if not isinstance(value, bool):
        raise ValueError(f"{name} must be a boolean")
    return value


def _wait_for_probe_output(project_path: Path, timeout_seconds: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    status = _probe_status(project_path)
    while not status["loaded"] and time.monotonic() < deadline:
        time.sleep(0.25)
        status = _probe_status(project_path)
    return status


def _prepare_editor_session(args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    ensure_result = _ensure_editor_probe(args, context)
    return {
        "plugin": "godot",
        "command": "prepare-editor-session",
        "project_path": ensure_result["project_path"],
        "installed_files": ensure_result["installed_files"],
        "project_godot_changed": ensure_result["project_godot_changed"],
        "stale_output_removed": ensure_result["stale_output_removed"],
        "status": ensure_result["status"],
        "ready_to_launch": ensure_result["status"]["installed"] and ensure_result["status"]["enabled"],
        "next_step": "Launch the editor through launch-editor-session, or restart any already-running editor for this project.",
    }


def _launch_editor_session(args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    project_path = _resolve_project_path(
        project_path=args.get("project_path"),
        surface_id=args.get("surface_id"),
        pid=args.get("pid"),
    )
    if not _project_godot_path(project_path).exists():
        raise ValueError(f"not a Godot project path: {project_path}")
    ensure_probe = _bool_arg(args, "ensure_probe", True)
    ensure_result: dict[str, Any] | None = None
    if ensure_probe:
        ensure_result = _ensure_editor_probe({"project_path": str(project_path)}, context)
    status_before = _probe_status(project_path)
    if not status_before["installed"] or not status_before["enabled"]:
        raise RuntimeError("Sightline editor probe must be installed and enabled before launching Godot")
    godot_bin = args.get("godot_bin", "godot")
    if not isinstance(godot_bin, str) or not godot_bin:
        raise ValueError("godot_bin must be a non-empty string")
    timeout_seconds = _numeric_arg(args, "timeout_seconds", 15.0, minimum=0.0)
    command = [godot_bin, "--path", str(project_path), "--editor"]
    artifact_dir = _artifact_dir(context)
    log_key = hashlib.sha1(f"{project_path}|{time.time()}".encode("utf-8")).hexdigest()[:12]
    log_path = artifact_dir / f"godot_editor_{log_key}.log"
    with log_path.open("ab") as log_file:
        process = subprocess.Popen(
            command,
            cwd=str(project_path),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    status_after = _wait_for_probe_output(project_path, timeout_seconds)
    return {
        "plugin": "godot",
        "command": "launch-editor-session",
        "project_path": str(project_path),
        "pid": process.pid,
        "godot_command": command,
        "log_path": str(log_path),
        "probe_loaded": status_after["loaded"],
        "status": status_after,
        "prepare_result": ensure_result,
        "next_step": "Run the scene from this editor, then capture report-editor-debugger-warnings.",
    }


def _cleanup_editor_session(args: dict[str, Any]) -> dict[str, Any]:
    result = _remove_editor_probe(args)
    result["command"] = "cleanup-editor-session"
    result["next_step"] = "The project no longer has the managed Sightline editor probe installed."
    return result


def _surface_id(*parts: object) -> str:
    raw = "|".join("" if part is None else str(part) for part in parts)
    return f"godot_surface_{hashlib.sha1(raw.encode('utf-8')).hexdigest()[:12]}"


def _read_project_name(project_dir: Path | None) -> str | None:
    if project_dir is None:
        return None
    project_file = project_dir / "project.godot"
    if not project_file.exists():
        return None
    text = project_file.read_text(encoding="utf-8", errors="replace")
    match = PROJECT_NAME_RE.search(text)
    if match:
        return match.group("name")
    return project_dir.name


def _project_dir_from_cmdline(cmdline: list[str]) -> Path | None:
    for index, value in enumerate(cmdline):
        if value == "--path" and index + 1 < len(cmdline):
            return Path(cmdline[index + 1]).expanduser()
        if value.startswith("--path="):
            return Path(value.split("=", 1)[1]).expanduser()
    return None


def _project_from_title(title: str) -> str | None:
    if " - " in title and "godot engine" in title.lower():
        parts = [part.strip() for part in title.split(" - ")]
        if len(parts) >= 2 and parts[-1].lower() == "godot engine":
            return parts[-2] or None
    debug_suffix = " (DEBUG)"
    if title.endswith(debug_suffix):
        return title[: -len(debug_suffix)].strip() or None
    return None


def _app_userdata_projects() -> set[str]:
    root = _logs_root()
    if not root.exists():
        return set()
    return {path.name for path in root.iterdir() if path.is_dir()}


def _linux_process_start_time(pid: int) -> float | None:
    stat_path = Path("/proc") / str(pid) / "stat"
    proc_stat = Path("/proc/stat")
    try:
        fields = stat_path.read_text(encoding="utf-8", errors="replace").split()
        start_ticks = int(fields[21])
        btime = None
        for line in proc_stat.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("btime "):
                btime = int(line.split()[1])
                break
        if btime is None:
            return None
        ticks_per_second = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
        return btime + (start_ticks / ticks_per_second)
    except (OSError, IndexError, KeyError, ValueError):
        return None


def _linux_process(pid: int) -> dict[str, Any] | None:
    proc = Path("/proc") / str(pid)
    if not proc.exists():
        return None
    try:
        raw_cmdline = (proc / "cmdline").read_bytes()
    except OSError:
        raw_cmdline = b""
    cmdline = [part.decode("utf-8", errors="replace") for part in raw_cmdline.split(b"\0") if part]
    try:
        name = (proc / "comm").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        name = Path(cmdline[0]).name if cmdline else ""
    try:
        cwd = str((proc / "cwd").resolve())
    except OSError:
        cwd = None
    try:
        executable = str((proc / "exe").resolve())
    except OSError:
        executable = cmdline[0] if cmdline else None
    project_dir = _project_dir_from_cmdline(cmdline)
    if project_dir is None and cwd:
        cwd_path = Path(cwd)
        if (cwd_path / "project.godot").exists():
            project_dir = cwd_path
    return {
        "pid": pid,
        "process_name": name,
        "executable": executable,
        "cmdline": cmdline,
        "cwd": cwd,
        "project_path": str(project_dir) if project_dir else None,
        "project": _read_project_name(project_dir),
        "start_time": _linux_process_start_time(pid),
    }


def _linux_processes() -> list[dict[str, Any]]:
    proc_root = Path("/proc")
    rows: list[dict[str, Any]] = []
    if not proc_root.exists():
        return rows
    for child in proc_root.iterdir():
        if not child.name.isdigit():
            continue
        process = _linux_process(int(child.name))
        if process is not None:
            rows.append(process)
    return rows


def _macos_processes() -> list[dict[str, Any]]:
    if not _command_available("ps"):
        return []
    code, stdout, _stderr = _run_optional(["ps", "-axo", "pid=,comm=,args="])
    if code != 0:
        return []
    rows: list[dict[str, Any]] = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        pid = int(parts[0])
        executable = parts[1]
        args = shlex.split(parts[2]) if len(parts) > 2 else [executable]
        project_dir = _project_dir_from_cmdline(args)
        rows.append(
            {
                "pid": pid,
                "process_name": Path(executable).name,
                "executable": executable,
                "cmdline": args,
                "cwd": None,
                "project_path": str(project_dir) if project_dir else None,
                "project": _read_project_name(project_dir),
                "start_time": None,
            }
        )
    return rows


def _windows_processes() -> list[dict[str, Any]]:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if powershell is None:
        return []
    command = (
        "Get-CimInstance Win32_Process | "
        "Select-Object ProcessId,Name,ExecutablePath,CommandLine | "
        "ConvertTo-Json -Depth 2"
    )
    code, stdout, _stderr = _run_optional([powershell, "-NoProfile", "-Command", command])
    if code != 0 or not stdout.strip():
        return []
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return []
    if isinstance(payload, dict):
        payload = [payload]
    rows: list[dict[str, Any]] = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        pid = item.get("ProcessId")
        if not isinstance(pid, int):
            continue
        command_line = item.get("CommandLine") or item.get("ExecutablePath") or ""
        try:
            cmdline = shlex.split(command_line, posix=False)
        except ValueError:
            cmdline = [command_line] if command_line else []
        project_dir = _project_dir_from_cmdline(cmdline)
        rows.append(
            {
                "pid": pid,
                "process_name": item.get("Name") or "",
                "executable": item.get("ExecutablePath"),
                "cmdline": cmdline,
                "cwd": None,
                "project_path": str(project_dir) if project_dir else None,
                "project": _read_project_name(project_dir),
                "start_time": None,
            }
        )
    return rows


def _processes_for_platform(platform_name: str) -> list[dict[str, Any]]:
    if platform_name == "linux":
        return _linux_processes()
    if platform_name == "macos":
        return _macos_processes()
    if platform_name == "windows":
        return _windows_processes()
    return []


def _is_godot_process(process: dict[str, Any]) -> bool:
    process_name = str(process.get("process_name") or "").lower()
    executable_name = Path(str(process.get("executable") or "")).name.lower()
    cmdline = process.get("cmdline") or []
    launcher = Path(str(cmdline[0])).name.lower() if cmdline else ""
    if "godot" in process_name or "godot" in executable_name or "godot" in launcher:
        return True
    return False


def _surface_kind(title: str | None, process: dict[str, Any] | None) -> str:
    title_lower = (title or "").lower()
    cmdline = process.get("cmdline") if process else []
    cmd_text = " ".join(cmdline or []).lower()
    if "(debug)" in title_lower or "--remote-debug" in cmd_text:
        return "debug_game"
    if "godot engine" in title_lower or "--editor" in cmd_text:
        return "editor"
    if process and _is_godot_process(process):
        return "runtime"
    return "unknown"


# ---------------------------------------------------------------------------
# Running-process detection + termination for a specific project (bug 019e93d8f1).
# Detection is cross-platform and DISPLAY-independent — it reuses the same
# _processes_for_platform scan as surface discovery, NOT the X11 path. Used by
# inspect op=stop and by remove-probe's editor-clobber guard. All side-effecting
# collaborators are injectable so the escalation logic is unit-testable.
# ---------------------------------------------------------------------------


def running_godot_for_project(
    project_path: Any,
    *,
    editor_only: bool = False,
    processes: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Return running Godot processes whose --path resolves to project_path.

    `processes` is injectable for tests; it defaults to a live cross-platform
    scan. `editor_only` restricts to editor instances (cmdline carries --editor).
    """
    try:
        target = Path(str(project_path)).expanduser().resolve()
    except OSError:
        return []
    rows = processes if processes is not None else _processes_for_platform(_host_platform())
    matches: list[dict[str, Any]] = []
    for proc in rows:
        if not _is_godot_process(proc):
            continue
        proc_project = proc.get("project_path")
        if not proc_project:
            continue
        try:
            if Path(str(proc_project)).expanduser().resolve() != target:
                continue
        except OSError:
            continue
        kind = _surface_kind(None, proc)
        is_editor = kind == "editor"
        if editor_only and not is_editor:
            continue
        matches.append({
            "pid": proc.get("pid"),
            "is_editor": is_editor,
            "kind": kind,
            "project_path": str(proc_project),
        })
    return matches


def _pid_alive(pid: int) -> bool:
    """POSIX liveness probe (signal 0). PermissionError ⇒ exists but not ours."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def stop_godot_for_project(
    project_path: Any,
    *,
    editor_only: bool = False,
    processes: list[dict[str, Any]] | None = None,
    killer: Callable[[int, int], None] | None = None,
    is_alive: Callable[[int], bool] | None = None,
    sleep: Callable[[float], None] | None = None,
    grace_seconds: float = 5.0,
    poll_interval: float = 0.25,
) -> dict[str, Any]:
    """SIGTERM (then SIGKILL after a grace period) every Godot for project_path.

    killer/is_alive/sleep are injectable so the SIGTERM→poll→SIGKILL escalation
    is testable without real processes. On Windows os.kill maps SIGTERM/SIGKILL
    to TerminateProcess (a hard stop) — acceptable for an explicit user action.
    """
    import signal

    do_kill = killer or os.kill
    alive = is_alive or _pid_alive
    nap = sleep or time.sleep
    procs = running_godot_for_project(
        project_path, editor_only=editor_only, processes=processes
    )
    stopped: list[int] = []
    sigkilled: list[int] = []
    failed: list[dict[str, Any]] = []
    for entry in procs:
        pid = entry.get("pid")
        if pid is None:
            continue
        try:
            do_kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            stopped.append(pid)  # already gone
            continue
        except OSError as exc:
            failed.append({"pid": pid, "error": str(exc)})
            continue
        waited = 0.0
        while waited < grace_seconds and alive(pid):
            nap(poll_interval)
            waited += poll_interval
        if alive(pid):
            try:
                do_kill(pid, signal.SIGKILL)
                sigkilled.append(pid)
                stopped.append(pid)
            except OSError as exc:
                failed.append({"pid": pid, "error": str(exc)})
        else:
            stopped.append(pid)
    return {
        "stopped": stopped,
        "sigkilled": sigkilled,
        "failed": failed,
        "matched": [e.get("pid") for e in procs],
    }


def _process_surface(process: dict[str, Any], platform_name: str, diagnostics: list[str] | None = None) -> dict[str, Any]:
    project = process.get("project")
    surface_id = _surface_id(platform_name, "process", process.get("pid"), process.get("executable"), project)
    capabilities = {
        "capture": False,
        "crop": False,
        "focus": False,
        "input": False,
        "logs": bool(project),
    }
    return {
        "surface_id": surface_id,
        "platform": platform_name,
        "provider": f"{platform_name}_process",
        "kind": _surface_kind(None, process),
        "title": process.get("process_name") or process.get("executable") or f"pid {process.get('pid')}",
        "pid": process.get("pid"),
        "process_name": process.get("process_name"),
        "executable": process.get("executable"),
        "cmdline": process.get("cmdline") or [],
        "cwd": process.get("cwd"),
        "project": project,
        "project_path": process.get("project_path"),
        "bounds": None,
        "window_id": None,
        "capture_supported": False,
        "focus_supported": False,
        "capabilities": capabilities,
        "evidence": ["process"] + (["logs"] if project else []),
        "diagnostics": diagnostics or [],
        "process_start_time": process.get("start_time"),
    }


def _window_props(window_id: int) -> dict[str, Any]:
    prop_text = _run(["xprop", "-id", str(window_id), "WM_CLASS", "_NET_WM_PID"])
    props: dict[str, Any] = {}
    class_match = re.search(r'WM_CLASS\(STRING\) = "([^"]+)", "([^"]+)"', prop_text)
    if class_match:
        props["wm_class"] = [class_match.group(1), class_match.group(2)]
    pid_match = re.search(r"_NET_WM_PID\(CARDINAL\) = (\d+)", prop_text)
    if pid_match:
        props["pid"] = int(pid_match.group(1))
    return props


def _window_is_godot_surface(
    *,
    title: str,
    class_names: list[str],
    props: dict[str, Any],
    process: dict[str, Any] | None,
) -> bool:
    lowered = " ".join([title, *class_names, *[str(item) for item in props.get("wm_class", [])]]).lower()
    if "godot" in lowered or "godot engine" in lowered:
        return True
    if process and _is_godot_process(process):
        return True
    title_project = _project_from_title(title)
    if "(debug)" in title.lower() and title_project in _app_userdata_projects():
        return True
    return False


def _window_surface(
    *,
    window_id: int,
    window_hex: str,
    title: str,
    x: int,
    y: int,
    width: int,
    height: int,
    props: dict[str, Any],
    process: dict[str, Any] | None,
    platform_name: str,
) -> dict[str, Any]:
    title_project = _project_from_title(title)
    project = (process or {}).get("project") or title_project
    kind = _surface_kind(title, process)
    capabilities = {
        "capture": platform_name == "linux",
        "crop": platform_name == "linux",
        "focus": platform_name == "linux",
        "input": platform_name == "linux",
        "logs": bool(project),
    }
    evidence = ["window"]
    if process:
        evidence.append("process")
    if project:
        evidence.append("logs")
    return {
        "surface_id": _surface_id(platform_name, "window", window_id, props.get("pid"), title, project),
        "platform": platform_name,
        "provider": "linux_x11",
        "kind": kind,
        "title": title,
        "pid": props.get("pid"),
        "process_name": (process or {}).get("process_name"),
        "executable": (process or {}).get("executable"),
        "cmdline": (process or {}).get("cmdline") or [],
        "cwd": (process or {}).get("cwd"),
        "project": project,
        "project_path": (process or {}).get("project_path"),
        "bounds": {"x": x, "y": y, "width": width, "height": height},
        "window_id": window_id,
        "window_hex": window_hex,
        "window_title": title,
        "wm_class": props.get("wm_class"),
        "capture_supported": capabilities["capture"],
        "focus_supported": capabilities["focus"],
        "capabilities": capabilities,
        "evidence": evidence,
        "diagnostics": [],
        "process_start_time": (process or {}).get("start_time"),
    }


def _x11_available() -> bool:
    return bool(os.environ.get("DISPLAY")) and all(
        _command_available(command) for command in ["xwininfo", "xprop"]
    )


def _parse_windows() -> list[dict[str, Any]]:
    return [
        {
            "window_id": surface["window_id"],
            "window_hex": surface["window_hex"],
            "title": surface["title"],
            "kind": "debug" if surface["kind"] == "debug_game" else surface["kind"],
            "x": surface["bounds"]["x"],
            "y": surface["bounds"]["y"],
            "width": surface["bounds"]["width"],
            "height": surface["bounds"]["height"],
            "pid": surface.get("pid"),
            "wm_class": surface.get("wm_class"),
            "surface_id": surface["surface_id"],
            "project": surface.get("project"),
        }
        for surface in _discover_surfaces()["surfaces"]
        if surface.get("window_id") is not None
    ]


def _parse_x11_surfaces(platform_name: str, processes_by_pid: dict[int, dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    if not _x11_available():
        return [], ["Linux X11 discovery unavailable: DISPLAY, xwininfo, or xprop is missing."]
    tree = _run(["xwininfo", "-root", "-tree"])
    surfaces: list[dict[str, Any]] = []
    diagnostics: list[str] = []
    for line in tree.splitlines():
        match = WINDOW_RE.match(line)
        if not match:
            continue
        title = match.group("title")
        class_names = [match.group("class1"), match.group("class2")]
        window_hex = match.group(1)
        window_id = int(window_hex, 16)
        try:
            props = _window_props(window_id)
        except RuntimeError as error:
            diagnostics.append(f"Unable to read X11 properties for window {window_hex}: {error}")
            props = {}
        process = processes_by_pid.get(props.get("pid"))
        prop_class_text = " ".join([*class_names, *[str(item) for item in props.get("wm_class", [])]]).lower()
        if process is not None and not _is_godot_process(process) and "godot" not in prop_class_text:
            process = None
            props.pop("pid", None)
        if not _window_is_godot_surface(title=title, class_names=class_names, props=props, process=process):
            continue
        surfaces.append(
            _window_surface(
                window_id=window_id,
                window_hex=window_hex,
                title=title,
                x=int(match.group("x")),
                y=int(match.group("y")),
                width=int(match.group("width")),
                height=int(match.group("height")),
                props=props,
                process=process,
                platform_name=platform_name,
            )
        )
    surfaces.sort(key=lambda item: (item["kind"] != "debug_game", item["title"]))
    return surfaces, diagnostics


def _dedupe_surfaces(surfaces: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[object, object, object]] = set()
    rows: list[dict[str, Any]] = []
    for surface in surfaces:
        key = (surface.get("window_id"), surface.get("pid"), surface.get("surface_id"))
        if key in seen:
            continue
        seen.add(key)
        rows.append(surface)
    return rows


def _discover_surfaces() -> dict[str, Any]:
    platform_name = _host_platform()
    diagnostics: list[str] = []
    processes = _processes_for_platform(platform_name)
    processes_by_pid = {
        process["pid"]: process for process in processes if isinstance(process.get("pid"), int)
    }
    surfaces: list[dict[str, Any]] = []
    window_pids: set[int] = set()

    if platform_name == "linux":
        x11_surfaces, x11_diagnostics = _parse_x11_surfaces(platform_name, processes_by_pid)
        surfaces.extend(x11_surfaces)
        diagnostics.extend(x11_diagnostics)
        window_pids = {surface["pid"] for surface in x11_surfaces if isinstance(surface.get("pid"), int)}
    elif platform_name in {"macos", "windows"}:
        diagnostics.append(
            f"{platform_name} window capture provider is not implemented yet; using process/log discovery only."
        )
    else:
        diagnostics.append(f"Unsupported platform for Godot window discovery: {platform_name}")

    for process in processes:
        if process.get("pid") in window_pids:
            continue
        if _is_godot_process(process):
            surfaces.append(
                _process_surface(
                    process,
                    platform_name,
                    diagnostics=[
                        "Process-only surface; focus and screenshot capture require a platform window provider."
                    ],
                )
            )

    surfaces = _dedupe_surfaces(surfaces)
    surfaces.sort(key=lambda item: (item["kind"] != "debug_game", item.get("project") or "", item["title"]))
    return {
        "plugin": "godot",
        "command": "discover-surfaces",
        "platform": platform_name,
        "surfaces": surfaces,
        "diagnostics": diagnostics,
    }


def _window_summary(window_id: int) -> dict[str, Any]:
    try:
        for window in _parse_windows():
            if window["window_id"] == window_id:
                return {
                    "window_id": window["window_id"],
                    "window_title": window["title"],
                    "window_kind": window["kind"],
                    "pid": window.get("pid"),
                    "wm_class": window.get("wm_class"),
                    "bounds": {
                        "x": window["x"],
                        "y": window["y"],
                        "width": window["width"],
                        "height": window["height"],
                    },
                }
    except Exception:
        pass
    props = _window_props(window_id)
    return {
        "window_id": window_id,
        "pid": props.get("pid"),
        "wm_class": props.get("wm_class"),
    }


def _artifact_record(
    *,
    command: str,
    kind: str,
    artifact_path: Path,
    metadata: dict[str, Any],
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "plugin": "godot",
        "command": command,
        "kind": kind,
        "artifact_path": str(artifact_path),
        "metadata": metadata,
        "provenance": {
            "adapter": "plugin",
            "plugin_id": "godot",
        },
    }
    if artifact_path.exists():
        payload["size"] = artifact_path.stat().st_size
        payload["metadata"]["size"] = artifact_path.stat().st_size
    if extra:
        payload.update(extra)
    return payload


def _issue_severity(text: str) -> str:
    lowered = text.lower()
    if "script error" in lowered:
        return "script_error"
    if "error" in lowered:
        return "error"
    if "warning" in lowered:
        return "warning"
    if "debugger" in lowered:
        return "debugger"
    return "issue"


def _severity_counts(issues: list[dict[str, Any]]) -> dict[str, int]:
    counts = {
        "warning": 0,
        "error": 0,
        "script_error": 0,
        "debugger": 0,
        "issue": 0,
    }
    for issue in issues:
        severity = str(issue.get("severity", "issue"))
        counts[severity] = counts.get(severity, 0) + 1
    return counts


def _capture_window(window_id: int, context: dict[str, Any]) -> dict[str, Any]:
    artifact_dir = _artifact_dir(context)
    artifact_id = hashlib.sha1(f"{window_id}".encode("utf-8")).hexdigest()[:12]
    output_path = artifact_dir / f"{window_id}_{artifact_id}.xwd"
    subprocess.run(["xwd", "-id", str(window_id), "-silent", "-out", str(output_path)], check=True)
    props = _window_props(window_id)
    metadata = {**_window_summary(window_id), **props}
    return _artifact_record(
        command="capture-window",
        kind="screenshot",
        artifact_path=output_path,
        metadata=metadata,
        extra={"window_id": window_id, **props},
    )


def _capture_window_png(window_id: int, context: dict[str, Any]) -> dict[str, Any]:
    raw = _capture_window(window_id, context)
    raw_path = Path(raw["artifact_path"])
    png_path = raw_path.with_suffix(".png")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw_path), str(png_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    metadata = {
        **_window_summary(window_id),
        "source_artifact_path": str(raw_path),
    }
    return _artifact_record(
        command="capture-window-png",
        kind="screenshot",
        artifact_path=png_path,
        metadata=metadata,
        extra={
            "window_id": window_id,
            "source_artifact_path": str(raw_path),
            "wm_class": raw.get("wm_class"),
            "pid": raw.get("pid"),
        },
    )


def _capture_region_png(window_id: int, x: int, y: int, width: int, height: int, context: dict[str, Any]) -> dict[str, Any]:
    if min(x, y, width, height) < 0:
        raise ValueError("capture-region-png requires non-negative coordinates and sizes")
    if width <= 0 or height <= 0:
        raise ValueError("capture-region-png requires positive width and height")
    full = _capture_window_png(window_id, context)
    full_path = Path(full["artifact_path"])
    crop_path = full_path.with_name(f"{full_path.stem}_crop_{x}_{y}_{width}_{height}.png")
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(full_path),
            "-vf",
            f"crop={width}:{height}:{x}:{y}",
            str(crop_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    crop = {
        "x": x,
        "y": y,
        "width": width,
        "height": height,
    }
    metadata = {
        **_window_summary(window_id),
        "source_artifact_path": str(full_path),
        "crop": crop,
    }
    return _artifact_record(
        command="capture-region-png",
        kind="screenshot_region",
        artifact_path=crop_path,
        metadata=metadata,
        extra={
            "window_id": window_id,
            "source_artifact_path": str(full_path),
            "crop": crop,
            "wm_class": full.get("wm_class"),
            "pid": full.get("pid"),
        },
    )


def _focus_window(window_id: int) -> dict[str, Any]:
    subprocess.run(["xdotool", "windowactivate", "--sync", str(window_id)], check=True)
    return {"plugin": "godot", "command": "focus-window", "window_id": window_id, "status": "focused"}


def _send_key(window_id: int, key: str) -> dict[str, Any]:
    subprocess.run(["xdotool", "windowactivate", "--sync", str(window_id)], check=True)
    subprocess.run(["xdotool", "key", "--window", str(window_id), key], check=True)
    return {"plugin": "godot", "command": "send-key", "window_id": window_id, "key": key, "status": "sent"}


def _click(window_id: int, x: int, y: int, button: int = 1) -> dict[str, Any]:
    subprocess.run(["xdotool", "windowactivate", "--sync", str(window_id)], check=True)
    subprocess.run(["xdotool", "mousemove", "--window", str(window_id), str(x), str(y)], check=True)
    subprocess.run(["xdotool", "click", "--window", str(window_id), str(button)], check=True)
    return {
        "plugin": "godot",
        "command": "click",
        "window_id": window_id,
        "x": x,
        "y": y,
        "button": button,
        "status": "clicked",
    }


def _logs_root() -> Path:
    return Path.home() / ".local" / "share" / "godot" / "app_userdata"


def _discover_project_logs(project: str | None = None, limit: int = 20) -> dict[str, Any]:
    root = _logs_root()
    rows: list[dict[str, Any]] = []
    if not root.exists():
        return {"plugin": "godot", "command": "discover-project-logs", "logs": []}
    for project_dir in sorted(root.iterdir()):
        if not project_dir.is_dir():
            continue
        if project and project.lower() not in project_dir.name.lower():
            continue
        logs_dir = project_dir / "logs"
        if not logs_dir.exists():
            continue
        for log_path in sorted(logs_dir.glob("*.log"), key=lambda path: path.stat().st_mtime, reverse=True):
            rows.append(
                {
                    "project": project_dir.name,
                    "path": str(log_path),
                    "mtime": log_path.stat().st_mtime,
                    "mtime_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(log_path.stat().st_mtime)),
                    "size": log_path.stat().st_size,
                }
            )
    rows.sort(key=lambda item: item["mtime"], reverse=True)
    return {"plugin": "godot", "command": "discover-project-logs", "logs": rows[:limit]}


def _surface_for_id(surface_id: str) -> dict[str, Any] | None:
    for surface in _discover_surfaces()["surfaces"]:
        if surface.get("surface_id") == surface_id:
            return surface
    return None


def _surface_for_pid(pid: int) -> dict[str, Any] | None:
    for surface in _discover_surfaces()["surfaces"]:
        if surface.get("pid") == pid:
            return surface
    return None


def _resolve_runtime_target(
    *,
    project: str | None,
    surface_id: str | None = None,
    pid: int | None = None,
) -> tuple[str, dict[str, Any] | None, list[str]]:
    diagnostics: list[str] = []
    surface: dict[str, Any] | None = None
    if surface_id:
        surface = _surface_for_id(surface_id)
        if surface is None:
            raise ValueError(f"unknown Godot surface_id: {surface_id}")
    elif pid is not None:
        surface = _surface_for_pid(pid)
        if surface is None:
            raise ValueError(f"unknown Godot process pid: {pid}")

    if project is None and surface is not None:
        candidate = surface.get("project")
        if isinstance(candidate, str) and candidate:
            project = candidate
        else:
            diagnostics.append("Selected surface has no project identity; project must be supplied explicitly.")

    if project is None:
        discovered = _discover_surfaces()
        projects = sorted(
            {
                str(item["project"])
                for item in discovered["surfaces"]
                if isinstance(item.get("project"), str) and item.get("project")
            }
        )
        if len(projects) == 1:
            project = projects[0]
            diagnostics.append(f"Using the only discovered Godot project: {project}")
        elif not projects:
            raise ValueError("report-runtime-issues requires project, surface_id, or a discoverable running Godot project")
        else:
            raise ValueError(
                "report-runtime-issues requires project or surface_id because multiple Godot projects are running: "
                + ", ".join(projects)
            )

    return project, surface, diagnostics


def _parse_issues_from_log(log_path: Path) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    with log_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, text in enumerate(handle, start=1):
            if ISSUE_RE.search(text):
                stripped = text.rstrip("\n")
                issues.append(
                    {
                        "line": line_number,
                        "text": stripped,
                        "severity": _issue_severity(stripped),
                    }
                )
    return issues


def _choose_runtime_log(
    project: str,
    surface: dict[str, Any] | None,
) -> tuple[Path | None, list[dict[str, Any]], list[str]]:
    discovered = _discover_project_logs(project=project, limit=20)
    logs = discovered["logs"]
    if not logs:
        return None, [], [f"No Godot logs found for project {project}."]
    diagnostics: list[str] = []
    process_start_time = surface.get("process_start_time") if surface else None
    if isinstance(process_start_time, (int, float)):
        fresh_logs = [row for row in logs if row["mtime"] >= process_start_time - 2]
        if fresh_logs:
            logs = fresh_logs
        else:
            diagnostics.append(
                "No log file is newer than the selected process start time; selected evidence may be stale."
            )
    chosen_log: Path | None = None
    issues: list[dict[str, Any]] = []
    for row in logs:
        candidate = Path(row["path"])
        candidate_issues = _parse_issues_from_log(candidate)
        if candidate_issues:
            chosen_log = candidate
            issues = candidate_issues
            break
    if chosen_log is None:
        chosen_log = Path(logs[0]["path"])
    return chosen_log, issues, diagnostics


def _tail_runtime_issues(
    project: str | None = None,
    limit: int = 100,
    *,
    surface_id: str | None = None,
    pid: int | None = None,
) -> dict[str, Any]:
    project, surface, diagnostics = _resolve_runtime_target(project=project, surface_id=surface_id, pid=pid)
    chosen_log, all_issues, log_diagnostics = _choose_runtime_log(project, surface)
    diagnostics.extend(log_diagnostics)
    if chosen_log is None:
        return {
            "plugin": "godot",
            "command": "tail-runtime-issues",
            "project": project,
            "surface": surface,
            "issues": [],
            "issue_count": 0,
            "diagnostics": diagnostics,
        }
    issues = all_issues[-limit:] if limit > 0 else all_issues
    return {
        "plugin": "godot",
        "command": "tail-runtime-issues",
        "project": project,
        "log_path": str(chosen_log),
        "issue_count": len(all_issues),
        "issues": issues,
        "severity_counts": _severity_counts(all_issues),
        "truncated": len(issues) < len(all_issues),
        "surface": surface,
        "diagnostics": diagnostics,
    }


def _report_runtime_issues(
    project: str | None = None,
    limit: int = 100,
    *,
    surface_id: str | None = None,
    pid: int | None = None,
) -> dict[str, Any]:
    payload = _tail_runtime_issues(project, limit=limit, surface_id=surface_id, pid=pid)
    issues = payload["issues"]
    severity_counts = payload.get("severity_counts") or _severity_counts(issues)
    summary_lines = [
        f"Project: {payload['project']}",
        f"Log: {payload.get('log_path', '<missing>')}",
        f"Issue count surfaced: {payload['issue_count']}",
        f"Warning count surfaced: {severity_counts.get('warning', 0)}",
    ]
    if payload.get("surface"):
        surface = payload["surface"]
        summary_lines.append(
            f"Surface: {surface.get('surface_id')} {surface.get('kind')} {surface.get('title')}"
        )
    for diagnostic in payload.get("diagnostics", []):
        summary_lines.append(f"Diagnostic: {diagnostic}")
    if issues:
        summary_lines.append("Recent issues:")
        for issue in issues:
            summary_lines.append(f"- {issue['severity']} line {issue['line']}: {issue['text']}")
    else:
        summary_lines.append("No issues found in recent logs.")
    payload["command"] = "report-runtime-issues"
    payload["report"] = "\n".join(summary_lines)
    payload["kind"] = "runtime_issue_report"
    payload["artifact_path"] = payload.get("log_path") or str(_logs_root())
    payload["severity_counts"] = severity_counts
    payload["warning_count"] = severity_counts.get("warning", 0)
    payload["error_count"] = severity_counts.get("error", 0) + severity_counts.get("script_error", 0)
    payload["metadata"] = {
        "project": payload["project"],
        "source_log_path": payload.get("log_path"),
        "issue_count": payload["issue_count"],
        "severity_counts": severity_counts,
        "warning_count": payload["warning_count"],
        "error_count": payload["error_count"],
        "line_range": [issues[0]["line"], issues[-1]["line"]] if issues else None,
        "issues": issues,
        "report": payload["report"],
        "surface": payload.get("surface"),
        "surface_id": (payload.get("surface") or {}).get("surface_id"),
        "platform": (payload.get("surface") or {}).get("platform") or _host_platform(),
        "provider": (payload.get("surface") or {}).get("provider"),
        "diagnostics": payload.get("diagnostics", []),
        "truncated": payload.get("truncated", False),
    }
    payload["provenance"] = {
        "adapter": "plugin",
        "plugin_id": "godot",
    }
    return payload


def _probe_rows_to_issues(rows: list[Any]) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    for index, row in enumerate(rows, start=1):
        if not isinstance(row, dict):
            continue
        text = str(row.get("text", "")).strip()
        if not text:
            continue
        severity = str(row.get("severity") or _issue_severity(text))
        if severity == "issue":
            lowered = text.lower()
            if "gdscript::reload" in lowered or "warning" in lowered or "shadowing" in lowered:
                severity = "warning"
        issues.append(
            {
                "line": index,
                "text": text,
                "severity": severity,
                "source": row.get("source") or row.get("kind", "editor_debugger"),
                "node_path": row.get("node_path"),
            }
        )
    return issues


def _read_fresh_probe_state(
    args: dict[str, Any],
    context: dict[str, Any],
    *,
    command_name: str,
) -> tuple[Path, dict[str, Any], Path, dict[str, Any]]:
    install_if_missing = args.get("install_if_missing", False)
    if not isinstance(install_if_missing, bool):
        raise ValueError("install_if_missing must be a boolean")
    allow_stale = args.get("allow_stale", False)
    if not isinstance(allow_stale, bool):
        raise ValueError("allow_stale must be a boolean")
    project_path = _resolve_project_path(
        project_path=args.get("project_path"),
        surface_id=args.get("surface_id"),
        pid=args.get("pid"),
    )
    status = _probe_status(project_path)
    if install_if_missing and (not status["installed"] or not status["enabled"]):
        _ensure_editor_probe({"project_path": str(project_path)}, context)
        status = _probe_status(project_path)
    output_path = _probe_output_path(project_path)
    if not output_path.exists():
        raise FileNotFoundError(
            f"probe output not found: {output_path}; run prepare-editor-session, start or restart the editor, and wait for loaded=true"
        )
    if not allow_stale and not status["loaded"]:
        age = status.get("output_age_seconds")
        age_text = f" age={age:.1f}s" if isinstance(age, (int, float)) else ""
        raise RuntimeError(
            f"probe output is stale or the editor probe is not loaded:{age_text}; "
            f"start or restart the editor before {command_name}"
        )
    state = json.loads(output_path.read_text(encoding="utf-8"))
    if not isinstance(state, dict):
        state = {}
    return project_path, status, output_path, state


def _report_editor_debugger_warnings(args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    project_path, status, output_path, state = _read_fresh_probe_state(
        args,
        context,
        command_name="report-editor-debugger-warnings",
    )
    debugger = state.get("debugger") if isinstance(state, dict) else {}
    if not isinstance(debugger, dict):
        debugger = {}
    rows = debugger.get("rows", [])
    if not isinstance(rows, list):
        rows = []
    issues = _probe_rows_to_issues(rows)
    warning_count = debugger.get("warning_count")
    if not isinstance(warning_count, int) or warning_count < 0:
        warning_count = sum(1 for issue in issues if issue["severity"] == "warning")
    error_count = debugger.get("error_count")
    if not isinstance(error_count, int) or error_count < 0:
        error_count = sum(1 for issue in issues if issue["severity"] in {"error", "script_error"})
    severity_counts = _severity_counts(issues)
    severity_counts["warning"] = warning_count
    severity_counts["error"] = error_count
    diagnostics = []
    row_warning_count = sum(1 for issue in issues if issue["severity"] == "warning")
    extraction_status = debugger.get("extraction_status")
    if isinstance(extraction_status, str) and extraction_status != "scoped_debugger_region":
        diagnostics.append(f"probe extraction status is {extraction_status}")
    if row_warning_count != warning_count:
        diagnostics.append(
            f"probe warning_count is {warning_count}, but {row_warning_count} warning row(s) were extracted"
        )
    project = str(state.get("project") or _read_project_name(project_path) or project_path.name)
    summary_lines = [
        f"Project: {project}",
        f"Probe output: {output_path}",
        f"Debugger tab: {debugger.get('tab_text', '')}",
        f"Warning count surfaced: {warning_count}",
    ]
    if issues:
        summary_lines.append("Visible debugger rows:")
        for issue in issues:
            summary_lines.append(f"- {issue['severity']} {issue['line']}: {issue['text']}")
    for diagnostic in diagnostics:
        summary_lines.append(f"Diagnostic: {diagnostic}")
    report = "\n".join(summary_lines)
    artifact_dir = _artifact_dir(context)
    artifact_key = hashlib.sha1(f"{project_path}|{output_path}|{output_path.stat().st_mtime}".encode("utf-8")).hexdigest()[:12]
    report_path = artifact_dir / f"editor_debugger_warnings_{artifact_key}.json"
    artifact_payload = {
        "schema": "sightline.godot.editor_debugger_warning_report.v1",
        "project": project,
        "project_path": str(project_path),
        "source_probe_output_path": str(output_path),
        "warning_count": warning_count,
        "error_count": error_count,
        "issue_count": warning_count + error_count,
        "severity_counts": severity_counts,
        "issues": issues,
        "debugger": debugger,
        "probe_state": state,
        "report": report,
        "status": status,
        "diagnostics": diagnostics,
    }
    report_path.write_text(json.dumps(artifact_payload, indent=2), encoding="utf-8")
    return {
        "plugin": "godot",
        "command": "report-editor-debugger-warnings",
        "kind": "runtime_issue_report",
        "artifact_path": str(report_path),
        "project": project,
        "project_path": str(project_path),
        "source_probe_output_path": str(output_path),
        "issue_count": warning_count + error_count,
        "warning_count": warning_count,
        "error_count": error_count,
        "severity_counts": severity_counts,
        "issues": issues,
        "report": report,
        "metadata": {
            "project": project,
            "project_path": str(project_path),
            "source_probe_output_path": str(output_path),
            "issue_count": warning_count + error_count,
            "warning_count": warning_count,
            "error_count": error_count,
            "severity_counts": severity_counts,
            "issues": issues,
            "report": report,
            "debugger": debugger,
            "probe_status": status,
            "diagnostics": diagnostics,
            "extraction_status": extraction_status,
            "evidence_source": "godot_editor_probe",
        },
        "provenance": {
            "adapter": "plugin",
            "plugin_id": "godot",
            "probe_id": "sightline_probe",
        },
    }


def _output_lines(text: str) -> list[str]:
    if not text:
        return []
    return text.splitlines()


def _report_editor_output_console(args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    project_path, status, output_path, state = _read_fresh_probe_state(
        args,
        context,
        command_name="report-editor-output-console",
    )
    output_console = state.get("output_console") if isinstance(state, dict) else {}
    if not isinstance(output_console, dict):
        output_console = {}
    text = str(output_console.get("text") or "")
    lines = _output_lines(text)
    line_count = output_console.get("line_count")
    if not isinstance(line_count, int) or line_count < 0:
        line_count = len(lines)
    counters = output_console.get("counters")
    if not isinstance(counters, list):
        counters = []
    extraction_status = output_console.get("extraction_status")
    diagnostics = []
    if isinstance(extraction_status, str) and extraction_status != "output_text_found":
        diagnostics.append(f"probe output extraction status is {extraction_status}")
    project = str(state.get("project") or _read_project_name(project_path) or project_path.name)
    summary_lines = [
        f"Project: {project}",
        f"Probe output: {output_path}",
        f"Output line count: {line_count}",
    ]
    if lines:
        summary_lines.append("Output lines:")
        for line in lines[:20]:
            summary_lines.append(f"- {line}")
    else:
        summary_lines.append("No output text found.")
    for diagnostic in diagnostics:
        summary_lines.append(f"Diagnostic: {diagnostic}")
    report = "\n".join(summary_lines)
    artifact_dir = _artifact_dir(context)
    artifact_key = hashlib.sha1(
        f"output|{project_path}|{output_path}|{output_path.stat().st_mtime}".encode("utf-8")
    ).hexdigest()[:12]
    report_path = artifact_dir / f"editor_output_console_{artifact_key}.json"
    artifact_payload = {
        "schema": "sightline.godot.output_console_report.v1",
        "project": project,
        "project_path": str(project_path),
        "source_probe_output_path": str(output_path),
        "line_count": line_count,
        "text": text,
        "lines": lines,
        "counters": counters,
        "output_console": output_console,
        "probe_state": state,
        "report": report,
        "status": status,
        "diagnostics": diagnostics,
    }
    report_path.write_text(json.dumps(artifact_payload, indent=2), encoding="utf-8")
    return {
        "plugin": "godot",
        "command": "report-editor-output-console",
        "kind": "output_console",
        "artifact_path": str(report_path),
        "project": project,
        "project_path": str(project_path),
        "source_probe_output_path": str(output_path),
        "line_count": line_count,
        "text": text,
        "lines": lines,
        "counters": counters,
        "report": report,
        "metadata": {
            "project": project,
            "project_path": str(project_path),
            "source_probe_output_path": str(output_path),
            "line_count": line_count,
            "text": text,
            "lines": lines,
            "counters": counters,
            "output_console": output_console,
            "probe_status": status,
            "diagnostics": diagnostics,
            "extraction_status": extraction_status,
            "evidence_source": "godot_editor_probe",
        },
        "provenance": {
            "adapter": "plugin",
            "plugin_id": "godot",
            "probe_id": "sightline_probe",
        },
    }


def _capture_debugger_panel_png(
    window_id: int,
    x: int,
    y: int,
    width: int,
    height: int,
    context: dict[str, Any],
) -> dict[str, Any]:
    payload = _capture_region_png(window_id, x, y, width, height, context)
    payload["command"] = "capture-debugger-panel-png"
    payload["kind"] = "debugger_snapshot"
    payload["metadata"]["evidence_source"] = "debugger_panel_screenshot"
    return payload


def run_command(command: str, args: dict[str, Any], context: dict[str, Any]) -> dict[str, Any]:
    if command == "discover-windows":
        return {
            "plugin": "godot",
            "command": command,
            "windows": _parse_windows(),
        }
    if command == "discover-surfaces":
        return _discover_surfaces()
    if command == "ensure-editor-probe":
        return _ensure_editor_probe(args, context)
    if command == "probe-status":
        return _probe_status_command(args)
    if command == "remove-editor-probe":
        return _remove_editor_probe(args)
    if command == "prepare-editor-session":
        return _prepare_editor_session(args, context)
    if command == "launch-editor-session":
        return _launch_editor_session(args, context)
    if command == "cleanup-editor-session":
        return _cleanup_editor_session(args)
    if command == "report-editor-debugger-warnings":
        project_path = args.get("project_path")
        surface_id = args.get("surface_id")
        pid = args.get("pid")
        if project_path is not None and not isinstance(project_path, str):
            raise ValueError("report-editor-debugger-warnings project_path must be a string")
        if surface_id is not None and not isinstance(surface_id, str):
            raise ValueError("report-editor-debugger-warnings surface_id must be a string")
        if pid is not None and not isinstance(pid, int):
            raise ValueError("report-editor-debugger-warnings pid must be an integer")
        return _report_editor_debugger_warnings(args, context)
    if command == "report-editor-output-console":
        project_path = args.get("project_path")
        surface_id = args.get("surface_id")
        pid = args.get("pid")
        if project_path is not None and not isinstance(project_path, str):
            raise ValueError("report-editor-output-console project_path must be a string")
        if surface_id is not None and not isinstance(surface_id, str):
            raise ValueError("report-editor-output-console surface_id must be a string")
        if pid is not None and not isinstance(pid, int):
            raise ValueError("report-editor-output-console pid must be an integer")
        return _report_editor_output_console(args, context)
    if command == "capture-window":
        window_id = args.get("window_id")
        if not isinstance(window_id, int):
            raise ValueError("capture-window requires integer window_id")
        return _capture_window(window_id, context)
    if command == "capture-window-png":
        window_id = args.get("window_id")
        if not isinstance(window_id, int):
            raise ValueError("capture-window-png requires integer window_id")
        return _capture_window_png(window_id, context)
    if command == "capture-region-png":
        window_id = args.get("window_id")
        x = args.get("x")
        y = args.get("y")
        width = args.get("width")
        height = args.get("height")
        if not all(isinstance(value, int) for value in [window_id, x, y, width, height]):
            raise ValueError("capture-region-png requires integer window_id, x, y, width, and height")
        return _capture_region_png(window_id, x, y, width, height, context)
    if command == "capture-debugger-panel-png":
        window_id = args.get("window_id")
        x = args.get("x")
        y = args.get("y")
        width = args.get("width")
        height = args.get("height")
        if not all(isinstance(value, int) for value in [window_id, x, y, width, height]):
            raise ValueError("capture-debugger-panel-png requires integer window_id, x, y, width, and height")
        return _capture_debugger_panel_png(window_id, x, y, width, height, context)
    if command == "focus-window":
        window_id = args.get("window_id")
        if not isinstance(window_id, int):
            raise ValueError("focus-window requires integer window_id")
        return _focus_window(window_id)
    if command == "send-key":
        window_id = args.get("window_id")
        key = args.get("key")
        if not isinstance(window_id, int) or not isinstance(key, str):
            raise ValueError("send-key requires integer window_id and string key")
        return _send_key(window_id, key)
    if command == "click":
        window_id = args.get("window_id")
        x = args.get("x")
        y = args.get("y")
        button = args.get("button", 1)
        if not all(isinstance(value, int) for value in [window_id, x, y, button]):
            raise ValueError("click requires integer window_id, x, y, and button")
        return _click(window_id, x, y, button)
    if command == "discover-project-logs":
        project = args.get("project")
        if project is not None and not isinstance(project, str):
            raise ValueError("discover-project-logs project must be a string")
        return _discover_project_logs(project=project)
    if command == "tail-runtime-issues":
        project = args.get("project")
        surface_id = args.get("surface_id")
        pid = args.get("pid")
        limit = args.get("limit", 100)
        if project is not None and not isinstance(project, str):
            raise ValueError("tail-runtime-issues project must be a string")
        if surface_id is not None and not isinstance(surface_id, str):
            raise ValueError("tail-runtime-issues surface_id must be a string")
        if pid is not None and not isinstance(pid, int):
            raise ValueError("tail-runtime-issues pid must be an integer")
        if not isinstance(limit, int):
            raise ValueError("tail-runtime-issues limit must be an integer")
        return _tail_runtime_issues(project, limit=limit, surface_id=surface_id, pid=pid)
    if command == "report-runtime-issues":
        project = args.get("project")
        surface_id = args.get("surface_id")
        pid = args.get("pid")
        limit = args.get("limit", 100)
        if project is not None and not isinstance(project, str):
            raise ValueError("report-runtime-issues project must be a string")
        if surface_id is not None and not isinstance(surface_id, str):
            raise ValueError("report-runtime-issues surface_id must be a string")
        if pid is not None and not isinstance(pid, int):
            raise ValueError("report-runtime-issues pid must be an integer")
        if not isinstance(limit, int):
            raise ValueError("report-runtime-issues limit must be an integer")
        return _report_runtime_issues(project, limit=limit, surface_id=surface_id, pid=pid)
    raise ValueError(f"unsupported command: {command}")
