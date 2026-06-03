from __future__ import annotations


def render_compact(payload: dict[str, object]) -> str:
    if isinstance(payload, dict) and payload.get("workflow") in {"godot-debugger-issues", "godot-output-console"}:
        workflow = payload.get("workflow")
        lines = [
            f"{workflow}: {payload.get('status', 'unknown')}",
            f"project: {payload.get('project_path', '')}",
        ]
        if payload.get("status") == "captured" and workflow == "godot-debugger-issues":
            lines.append(
                "issues: "
                f"{payload.get('issue_count', 0)} total, "
                f"{payload.get('warning_count', 0)} warning(s), "
                f"{payload.get('error_count', 0)} error(s)"
            )
            for summary in payload.get("artifact_summaries", []):
                lines.append(f"artifact: {summary.get('artifact_id')} {summary.get('artifact_path')}")
                for issue in summary.get("issues", []):
                    lines.append(f"- {issue.get('severity', 'issue')}: {issue.get('text', '')}")
                if summary.get("extraction_status"):
                    lines.append(f"extraction: {summary['extraction_status']}")
        elif payload.get("status") == "captured" and workflow == "godot-output-console":
            lines.append(f"lines: {payload.get('line_count', 0)}")
            for summary in payload.get("artifact_summaries", []):
                lines.append(f"artifact: {summary.get('artifact_id')} {summary.get('artifact_path')}")
                for line in summary.get("lines", [])[:12]:
                    lines.append(f"- {line}")
                if summary.get("extraction_status"):
                    lines.append(f"extraction: {summary['extraction_status']}")
        else:
            probe_status = payload.get("probe_status", {})
            if isinstance(probe_status, dict):
                lines.append(
                    "probe: "
                    f"installed={probe_status.get('installed')} "
                    f"enabled={probe_status.get('enabled')} "
                    f"loaded={probe_status.get('loaded')} "
                    f"fresh={probe_status.get('output_fresh')}"
                )
            if payload.get("probe_loaded") is not None:
                lines.append(f"probe_loaded: {payload['probe_loaded']}")
        if payload.get("next_action"):
            lines.append(f"next: {payload['next_action']}")
        if payload.get("next_command"):
            lines.append(f"command: {payload['next_command']}")
        return "\n".join(str(line) for line in lines if line).strip()

    if "plugin_id" in payload and "commands" in payload:
        lines = [f"plugin: {payload['plugin_id']}"]
        if payload.get("instructions"):
            lines.append(str(payload["instructions"]))
        for command in payload["commands"]:
            lines.append(f"- {command['name']}: {command['description']}")
        return "\n".join(lines)

    if "entries" in payload:
        lines: list[str] = [f"{payload['command']}: {payload['query']}", str(payload.get("summary", ""))]
        for index, entry in enumerate(payload["entries"], start=1):
            handle = entry["handle"]
            context = entry["context"]
            lines.append(
                f"{index}. {handle['path']}:{handle['start_line']} [{handle.get('category', 'unknown')}] {handle['preview']}"
            )
            context_lines = context.get("lines", [])
            for line in context_lines:
                lines.append(f"   {line['line']}: {line['text']}")
        return "\n".join(lines).strip()

    if "files" in payload and "aliases" in payload:
        lines = [f"subsystem: {payload['token']}", f"aliases: {', '.join(payload['aliases'])}"]
        for index, item in enumerate(payload["files"], start=1):
            evidence = "; ".join(item.get("evidence", [])[:2])
            lines.append(f"{index}. {item['path']} [{item['role']}] via {item['source']} :: {evidence}")
        return "\n".join(lines)

    if "windows" in payload:
        lines = [f"{payload.get('plugin', 'plugin')}: {payload.get('command', 'command')}"]
        for index, item in enumerate(payload["windows"], start=1):
            lines.append(
                f"{index}. {item['title']} [{item.get('kind', 'window')}] id={item['window_id']} pid={item.get('pid', '?')}"
            )
        return "\n".join(lines)

    if "sessions" in payload and "artifacts" in payload:
        lines = [f"inspect: {len(payload['sessions'])} session(s), {len(payload['artifacts'])} artifact(s)"]
        for item in payload["artifacts"]:
            metadata = item.get("metadata", {})
            plugin = metadata.get("plugin_id") or metadata.get("provenance", {}).get("plugin_id")
            source = f" plugin={plugin}" if plugin else ""
            details: list[str] = []
            if metadata.get("window_title"):
                details.append(str(metadata["window_title"]))
            if metadata.get("window_id"):
                details.append(f"window={metadata['window_id']}")
            if metadata.get("crop"):
                crop = metadata["crop"]
                details.append(f"crop={crop.get('x')},{crop.get('y')},{crop.get('width')}x{crop.get('height')}")
            if metadata.get("project"):
                details.append(f"project={metadata['project']}")
            suffix = f" :: {'; '.join(details)}" if details else ""
            lines.append(f"- {item['artifact_id']} [{item['kind']}]{source} {item['path']}{suffix}")
        return "\n".join(lines)

    if "session_id" in payload and "artifacts" in payload:
        lines = [f"inspect session: {payload['session_id']}", str(payload.get("summary", ""))]
        for item in payload["artifacts"]:
            metadata = item.get("metadata", {})
            plugin = metadata.get("plugin_id") or metadata.get("provenance", {}).get("plugin_id")
            source = f" plugin={plugin}" if plugin else ""
            lines.append(f"- {item['artifact_id']} [{item['kind']}]{source} {item['path']}")
        for warning in payload.get("warnings", []):
            lines.append(f"! {warning}")
        return "\n".join(line for line in lines if line).strip()

    if "validation_id" in payload and "checks" in payload:
        lines = [
            f"validation: {payload['validation_id']} [{payload['status']}] confidence={payload['confidence']}",
            str(payload.get("reason_summary", "")),
        ]
        for check in payload["checks"]:
            evidence = f" evidence={','.join(check.get('evidence', []))}" if check.get("evidence") else ""
            lines.append(f"- {check['name']}: {check['status']}{evidence} :: {check['detail']}")
        if payload.get("gaps"):
            lines.append("gaps:")
            for gap in payload["gaps"]:
                lines.append(f"- {gap}")
        if payload.get("recommended_next_step"):
            lines.append(f"next: {payload['recommended_next_step']}")
        return "\n".join(line for line in lines if line).strip()

    if isinstance(payload, list):
        if payload and isinstance(payload[0], dict) and "plugin_id" in payload[0]:
            lines = []
            for item in payload:
                lines.append(f"{item['plugin_id']} {item['version']} [{item.get('source', 'unknown')}]")
            return "\n".join(lines)
        if payload and isinstance(payload[0], dict) and "group" in payload[0]:
            lines = []
            for item in payload:
                lines.append(f"{item['group']}: files={item.get('files', '?')} size={item.get('size', '?')}")
            return "\n".join(lines)
        lines = []
        for index, item in enumerate(payload, start=1):
            prefix = f"{item['path']}:{item['start_line']}"
            grouped = f" hits={item['grouped_hit_count']}" if item.get("grouped_hit_count") else ""
            lines.append(f"{index}. {prefix}{grouped} [{item.get('category', 'unknown')}] {item['preview']}")
        return "\n".join(lines)

    return str(payload)
