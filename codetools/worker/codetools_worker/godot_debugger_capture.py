"""Durable capture of Godot editor debugger entries.

The editor probe is the portable source.  A calibrated X11 fallback exists for
an already-running editor when installing/restarting the probe would destroy the
evidence being collected.  Raw entries retain duplicates; normalized diagnostics
are a separate convenience view.
"""

from __future__ import annotations

import json
import math
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import godot_diagnostics


def _capture_dir(root: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    path = root / ".codetools" / "inspect" / "debugger-captures" / stamp
    path.mkdir(parents=True, exist_ok=False)
    return path


def _write_capture(root: Path, record: dict[str, Any], out: Path | None = None) -> dict[str, Any]:
    out = out or _capture_dir(root)
    json_path = out / "debugger-capture.json"
    text_path = out / "debugger-capture.txt"
    json_path.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")
    text_path.write_text("\n\n".join(record.get("raw_entries") or []), encoding="utf-8")
    record["artifact_paths"] = [str(json_path), str(text_path)] + record.pop("_extra_paths", [])
    # Rewrite once so the JSON points at every sibling artifact.
    json_path.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")
    return record


def capture_probe_state(
    state: dict[str, Any], root: Path, expected_project: Path | None = None,
    probe_age_seconds: float | None = None,
) -> dict[str, Any]:
    recorded_project = str(state.get("project_path") or "").strip()
    if expected_project is not None:
        if not recorded_project:
            raise RuntimeError("probe state has no project_path; project identity is unverified")
        if Path(recorded_project).expanduser().resolve() != expected_project.resolve():
            raise RuntimeError("probe state belongs to a different Godot project")
    rows = ((state.get("debugger") or {}).get("rows") or [])
    raw = []
    for row in rows:
        text = str(row.get("text") or "")
        details = [str(item) for item in (row.get("details") or [])]
        raw.append("\n".join([text] + details).strip())
    unique = list(dict.fromkeys(raw))
    normalized = godot_diagnostics.probe_state_to_diagnostics(state)
    reason = (
        "probe rows have no independent debugger-entry total; script warning "
        "sweep status does not establish debugger-list completeness"
    )
    return _write_capture(root, {
        "type": "godot_debugger_capture",
        "schema": "codetools.godot.debugger_capture.v1",
        "method": "editor-probe",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "complete": False,
        "completeness_reason": reason,
        "raw_count": len(raw),
        "count_semantics": "raw debugger row samples present in probe state",
        "unique_count": len(unique),
        "duplicate_count": len(raw) - len(unique),
        "raw_entries": raw,
        "diagnostics": normalized,
        "probe_state": state,
        "probe_age_seconds": probe_age_seconds,
    })


def _run(args: list[str], *, data: bytes | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            args, input=data, capture_output=True, check=False, timeout=5.0)
    except FileNotFoundError as exc:
        raise RuntimeError("required desktop command is unavailable: %s" % args[0]) from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("desktop command timed out: %s" % args[0]) from exc


def _checked_run(args: list[str]) -> subprocess.CompletedProcess:
    result = _run(args)
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError("desktop command failed: %s%s" % (
            args[0], ": " + detail if detail else ""))
    return result


def _clipboard_read() -> bytes:
    result = _run(["xclip", "-selection", "clipboard", "-o"])
    if result.returncode != 0:
        raise RuntimeError("could not read X11 clipboard; refusing capture to avoid data loss")
    return result.stdout


def _clipboard_write(data: bytes) -> None:
    process = subprocess.Popen(
        ["xclip", "-selection", "clipboard"], stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        process.communicate(data, timeout=5.0)
    except subprocess.TimeoutExpired as exc:
        process.kill()
        process.wait()
        raise RuntimeError("X11 clipboard write timed out") from exc
    if process.returncode != 0:
        raise RuntimeError("could not write X11 clipboard")


def _window_id(params: dict[str, Any]) -> str:
    if params.get("window_id"):
        ids = [str(params["window_id"])]
    else:
        result = _checked_run([
            "xdotool", "search", "--onlyvisible", "--class", "Godot"])
        ids = [line.strip() for line in result.stdout.decode().splitlines() if line.strip()]
        if not ids:
            raise RuntimeError("no visible Godot editor window found")
    expected = str(params.get("window_title_contains") or "").strip()
    if not expected:
        raise RuntimeError(
            "window_title_contains is required for X11 capture to prove project/editor identity"
        )
    try:
        title_pattern = re.compile(
            str(params.get("window_name") or "Godot"), re.IGNORECASE)
    except re.error as exc:
        raise RuntimeError("window_name is not a valid regular expression") from exc
    candidates: list[tuple[int, str]] = []
    for window_id in ids:
        window_class = _checked_run(
            ["xprop", "-id", window_id, "WM_CLASS"]
        ).stdout.decode(errors="replace").strip()
        title = _checked_run(
            ["xdotool", "getwindowname", window_id]
        ).stdout.decode(errors="replace").strip()
        if ("godot" not in window_class.lower()
                or expected.lower() not in title.lower()
                or not title_pattern.search(title)):
            continue
        geo = _window_geometry(window_id)
        candidates.append((geo["width"] * geo["height"], window_id))
    if not candidates:
        raise RuntimeError("discovered window does not match the requested Godot project title")
    return max(candidates)[1]


def _window_geometry(window_id: str) -> dict[str, int]:
    result = _run(["xwininfo", "-id", window_id])
    if result.returncode != 0:
        raise RuntimeError("could not read Godot window geometry")
    values: dict[str, int] = {}
    for line in result.stdout.decode().splitlines():
        label, _, value = line.strip().partition(":")
        value = value.strip()
        if not value.lstrip("-").isdigit():
            continue
        keys = {
            "Absolute upper-left X": "x", "Absolute upper-left Y": "y",
            "Width": "width", "Height": "height",
        }
        if label in keys:
            values[keys[label]] = int(value)
    required = {"x", "y", "width", "height"}
    if not required.issubset(values):
        raise RuntimeError("Godot window geometry was incomplete")
    return values


def _normalized_rect(value: Any) -> tuple[float, float, float, float]:
    if not isinstance(value, list) or len(value) != 4:
        raise RuntimeError("x11_region must be [x, y, width, height] normalized to the Godot window")
    rect = tuple(float(v) for v in value)
    if (not all(math.isfinite(v) for v in rect)
            or any(v < 0.0 or v > 1.0 for v in rect)
            or rect[2] <= 0 or rect[3] <= 0
            or rect[0] + rect[2] > 1.0 or rect[1] + rect[3] > 1.0):
        raise RuntimeError("x11_region values must be within 0..1 and have positive size")
    return rect


def _click(window_id: str, x: int, y: int, button: int = 1) -> None:
    _checked_run([
        "xdotool", "mousemove", "--window", window_id, str(x), str(y),
        "click", str(button),
    ])


def capture_x11(params: dict[str, Any], root: Path) -> dict[str, Any]:
    """Capture Copy Error entries using bounded, window-relative calibration.

    Required calibration is explicit because Godot exposes no stable X11 widget
    tree for the debugger rows. Coordinates are relative to the discovered editor
    window, never the desktop.
    """
    if not os.environ.get("DISPLAY"):
        raise RuntimeError("X11 fallback requires DISPLAY")
    region = _normalized_rect(params.get("x11_region"))
    row_height = int(params.get("x11_row_height") or 22)
    menu_offset = params.get("x11_copy_menu_offset")
    if not isinstance(menu_offset, list) or len(menu_offset) != 2:
        raise RuntimeError("x11_copy_menu_offset must be [dx, dy] from the selected row")
    max_rows = max(1, min(int(params.get("max_rows") or 250), 2000))
    max_pages = max(1, min(int(params.get("max_pages") or 20), 100))
    settle = max(0.02, min(float(params.get("settle_seconds") or 0.08), 1.0))

    window_id = _window_id(params)
    geo = _window_geometry(window_id)
    rx, ry, rw, rh = region
    left, top = int(rx * geo["width"]), int(ry * geo["height"])
    width, height = int(rw * geo["width"]), int(rh * geo["height"])
    if row_height <= 0 or row_height > height:
        raise RuntimeError("x11_row_height must fit inside x11_region")
    menu_x = left + width // 2 + int(menu_offset[0])
    first_menu_y = top + row_height // 2 + int(menu_offset[1])
    last_menu_y = first_menu_y + (max(1, height // row_height) - 1) * row_height
    if not (0 <= menu_x < geo["width"]
            and 0 <= first_menu_y < geo["height"]
            and 0 <= last_menu_y < geo["height"]):
        raise RuntimeError("x11_copy_menu_offset targets outside the Godot window")
    first_y = top + row_height // 2
    rows_per_page = max(1, height // row_height)
    active_result = _run(["xdotool", "getactivewindow"])
    if active_result.returncode != 0 or not active_result.stdout.decode().strip():
        raise RuntimeError("could not capture the previously active window; refusing capture")
    original_window = active_result.stdout.decode().strip()
    original = _clipboard_read()
    out = _capture_dir(root)
    entries: list[str] = []
    screenshots: list[str] = []
    page_signatures: set[tuple[str, ...]] = set()
    pages_attempted = 0
    stop_reason = "max_pages reached"
    capture_error = ""
    screenshot_errors: list[str] = []
    deadline = time.monotonic() + 60.0
    try:
        _checked_run(["xdotool", "windowactivate", "--sync", window_id])
        for page in range(max_pages):
            if time.monotonic() >= deadline:
                stop_reason = "capture deadline reached"
                break
            pages_attempted += 1
            try:
                from PIL import ImageGrab
                image = ImageGrab.grab(
                    xdisplay=os.environ.get("DISPLAY"),
                    bbox=(geo["x"] + left, geo["y"] + top,
                          geo["x"] + left + width, geo["y"] + top + height),
                )
                path = out / ("debugger-page-%02d.png" % page)
                image.save(path)
                screenshots.append(str(path))
            except Exception as exc:
                screenshot_errors.append(str(exc))
            page_entries: list[str] = []
            if params.get("expected_count") == 0:
                stop_reason = "caller reported zero visible debugger entries"
                break
            for row in range(rows_per_page):
                if time.monotonic() >= deadline:
                    stop_reason = "capture deadline reached"
                    break
                if len(entries) >= max_rows:
                    stop_reason = "max_rows reached"
                    break
                x = left + width // 2
                y = first_y + row * row_height
                sentinel = ("CODETOOLS_CLIPBOARD_SENTINEL_%d_%d" % (page, row)).encode()
                _clipboard_write(sentinel)
                _click(window_id, x, y, 3)
                time.sleep(settle)
                _click(window_id, x + int(menu_offset[0]), y + int(menu_offset[1]), 1)
                time.sleep(settle)
                copied = _clipboard_read()
                if copied == sentinel:
                    continue
                text = copied.decode("utf-8", errors="replace").strip()
                if text.startswith(("W ", "E ", "WARNING", "ERROR", "SCRIPT ERROR")):
                    entries.append(text)
                    page_entries.append(text)
            if len(entries) >= max_rows:
                break
            signature = tuple(page_entries)
            if not page_entries:
                stop_reason = "page produced no new Copy Error entries"
                break
            if signature in page_signatures:
                stop_reason = "page signature repeated"
                break
            page_signatures.add(signature)
            _click(window_id, left + width // 2, top + height // 2)
            _checked_run(["xdotool", "key", "--window", window_id, "Next"])
            time.sleep(settle)
    except Exception as exc:
        capture_error = str(exc)
        stop_reason = "capture interrupted: %s" % capture_error
    finally:
        try:
            _clipboard_write(original)
        except Exception as exc:
            capture_error = (capture_error + "; " if capture_error else "") + str(exc)
        if original_window:
            try:
                result = _run(["xdotool", "windowactivate", original_window])
            except Exception as exc:
                result = None
                capture_error = ((capture_error + "; " if capture_error else "")
                                 + "focus restore failed: " + str(exc))
            if result is not None and result.returncode != 0:
                capture_error = (
                    (capture_error + "; " if capture_error else "")
                    + "could not restore the previously active window"
                )

    unique = list(dict.fromkeys(entries))
    rows = []
    for text in entries:
        rows.append({
            "text": text.splitlines()[0],
            "details": text.splitlines()[1:],
            "severity": "warning" if text.startswith(("W ", "WARNING")) else "error",
        })
    state = {"debugger": {"rows": rows}}
    complete = False
    record = {
        "type": "godot_debugger_capture",
        "schema": "codetools.godot.debugger_capture.v1",
        "method": "x11-copy-error",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "complete": complete,
        "completeness_reason": (
            stop_reason + "; Godot exposes no independent visible-row total, so "
            "collapsed or inaccessible rows may still be omitted"
        ),
        "window_id": window_id,
        "window_geometry": geo,
        "raw_count": len(entries),
        "count_semantics": "Copy Error row samples; page overlap may repeat rows",
        "unique_count": len(unique),
        "duplicate_count": len(entries) - len(unique),
        "raw_entries": entries,
        "diagnostics": godot_diagnostics.probe_state_to_diagnostics(state),
        "pages_attempted": pages_attempted,
        "screenshot_count": len(screenshots),
        "screenshot_errors": screenshot_errors,
        "rows_per_page": rows_per_page,
        "expected_count": params.get("expected_count"),
        "expected_count_match": (
            len(entries) == int(params["expected_count"])
            if params.get("expected_count") is not None else None
        ),
        "capture_error": capture_error or None,
        "_extra_paths": screenshots,
    }
    return _write_capture(root, record, out)


def capture(params: dict[str, Any], root: Path, probe_state: dict[str, Any] | None) -> dict[str, Any]:
    method = str(params.get("capture_method") or "auto")
    if method in ("auto", "probe") and probe_state:
        expected_project = Path(str(params.get("project_path") or root)).expanduser()
        captured = float(probe_state.get("captured_at_unix") or 0.0)
        age = time.time() - captured
        if captured > 0 and -5.0 <= age <= 10.0:
            return capture_probe_state(
                probe_state, root, expected_project, probe_age_seconds=age)
        if method == "probe":
            raise RuntimeError("editor probe state is stale; refresh the probe before capture")
    if method == "probe":
        raise RuntimeError("editor probe state is unavailable")
    return capture_x11(params, root)


def compact_record(record: dict[str, Any], preview_limit: int = 5) -> dict[str, Any]:
    """Bounded MCP representation; full evidence remains in artifact files."""
    compact = {key: value for key, value in record.items() if key in {
        "type", "schema", "method", "captured_at", "complete",
        "completeness_reason", "count_semantics", "raw_count", "unique_count",
        "duplicate_count", "pages_attempted", "rows_per_page",
        "screenshot_count", "screenshot_errors", "expected_count", "expected_count_match",
        "probe_age_seconds",
        "artifact_paths", "window_id", "window_geometry", "capture_error",
    }}
    preview = []
    remaining = 8000
    for entry in (record.get("raw_entries") or [])[:preview_limit]:
        clipped = str(entry)[:min(2000, remaining)]
        preview.append(clipped)
        remaining -= len(clipped)
        if remaining <= 0:
            break
    compact["preview"] = preview
    compact["screenshot_errors"] = [
        str(item)[:500] for item in (record.get("screenshot_errors") or [])[:5]
    ]
    compact["preview_count"] = len(compact["preview"])
    source_preview = (record.get("raw_entries") or [])[:preview_limit]
    compact["preview_truncated"] = (
        record.get("raw_count", 0) > len(compact["preview"])
        or any(str(source) != shown for source, shown in zip(source_preview, preview))
    )
    return compact
