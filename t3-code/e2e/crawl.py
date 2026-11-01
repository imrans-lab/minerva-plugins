"""Owner-attended crawl E2E, experiment:01a1988d384d (not a CI test).

One file owns the driver, disposable Minerva observer, and row oracles. No
mock provider, terminal scraping, T3 database reads, or product patches.
Run --describe without prerequisites to inspect the authored trace contract.

Acceptance requires --owner-attended and --config CONFIG.json. CONFIG names:
  minerva_source: imported/build-ready Minerva repo to COPY, never execute
  profile_template: explicitly approved isolated Minerva user profile to COPY
  plugin_manifest: built local t3-code manifest (normal manifest install lane)
  godot: matching editor executable; provider: codex for acceptance
  t3_tag: exact supported upstream release tag
  settings: declared plugin values with private/workspace/minerva_mcp tokens
  codex_home: explicit owner-approved existing login path; never copied
  t3_token_file: external MCP-client credential produced by T1's auth setup
  t3_endpoint: private loopback /mcp URL, or omit to use public status result
Optional: plugin_id, entry_id, generate_tool, status_tool, deadline_sec.

The approved profile must give the runtime its existing owner-approved provider
login, exact binary/home, project-default permission mode and one read-only
Minerva MCP tool: minerva_list_chats. The observer publishes its dynamically
chosen endpoint in ready.json. The plugin's minerva_mcp_endpoint setting takes
the {minerva_mcp} placeholder and owns Codex MCP wiring, exposing only the
read-only minerva_list_chats tool. Missing setup is a prerequisite failure.
Run in an approved disposable Linux container/VM; non-Linux execution refuses
until its profile isolation is implemented. No provider credentials are copied.
Raw application/transcript evidence stays in a private retained directory.
Only allowlisted booleans, counts and statuses appear in the public JSONL.

T0 authors oracles only. As each path becomes reachable, collect its localized
red by breaking that step, then its green, on the same test. A missing plugin
does not count as per-row red. R3 approve/deny stays deferred to walk; its crawl
oracle checks a real unsupported request is visible and executes nothing.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, TypedDict, TypeVar
from urllib.parse import urlsplit


class Row(TypedDict):
    row: str
    status: str
    observed: dict[str, bool | int | str]


ROWS = {
    "R1": "real provider answer and matching completed backend run",
    "R2": "structured activity survives serialization and appears in UI nodes",
    "R2b": "read-only Minerva tool executes and its nonce reaches the answer",
    "R3": "approve/deny deferred; actual permission request visibly deferred, no write",
    "R4": "real Stop button ends the bound backend run, not a local timeout label",
    "R5": "complete settled backend assistant transcript agrees with Minerva",
    "R6": "one send, actual pending reply, automatic resume, truthful completion",
}
TERMINAL = {"completed", "failed", "cancelled", "interrupted", "rolled_back"}
T = TypeVar("T")

# This observer only drives existing public install/chat actions and reads
# model/scene/transport evidence. It never manufactures a provider response.
OBSERVER = r'''
extends Node
var folder: String = OS.get_environment("MINERVA_T3_CRAWL_PRIVATE")
var config: Dictionary = {}
var serial: int = 0
var busy: bool = false
var singleton: Node
var plugins: Object
var manager: Object
var server: Object
var connection: Object
var replies: Array[Dictionary] = []
var http_tools: Array[String] = []
var turn_events: Dictionary = {}

func _ready() -> void:
    config = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("observer-config.json")))
    _setup.call_deferred()

func _write(name_: String, value: Dictionary) -> void:
    var file := FileAccess.open(folder.path_join(name_ + ".json"), FileAccess.WRITE)
    file.store_string(JSON.stringify(value))
    file.close()

func _setup() -> void:
    singleton = get_tree().root.get_node("SingletonObject")
    var deadline: int = Time.get_ticks_msec() + 180000
    while Time.get_ticks_msec() < deadline:
        plugins = singleton.get("plugin_manager")
        manager = singleton.get("mcp_manager")
        if plugins != null and manager != null and singleton.get("Chats") != null:
            break
        await get_tree().create_timer(0.1).timeout
    if plugins == null or manager == null or singleton.get("Chats") == null:
        _write("stop", {"stage": "host_not_ready"})
        return
    manager.call("connect_minerva_server")
    server = manager.get("minerva_server")
    if server == null or int(manager.call("start_http_server", int(config.port))) != OK:
        _write("stop", {"stage": "mcp_not_ready"})
        return
    var http: Object = manager.get("http_server")
    http.connect("tool_executed", _on_http_tool)
    singleton.get("Chats").connect("chat_turn_completed", _on_turn)
    # Saved-project directory semantics, without loading any owner's project.
    singleton.set("current_project_path", str(config.project_path))
    _write("ready", {"port": manager.call("get_http_server_port")})

func _on_http_tool(tool: String, _session: String) -> void:
    http_tools.append(tool)

func _on_turn(event: Dictionary) -> void:
    turn_events[str(event.chat_id)] = event.duplicate(true)

func _on_reply(tool: String, payload: Dictionary) -> void:
    if tool != str(config.generate_tool):
        return
    var value: Dictionary = payload
    if payload.has("content"):
        for part: Variant in payload.content:
            if part is Dictionary and part.get("type") == "text":
                var parsed: Variant = JSON.parse_string(str(part.get("text", "")))
                if parsed is Dictionary:
                    value = parsed
                    break
    replies.append({"kind": str(value.get("kind", "")),
        "token": str(value.get("operation_token", "")), "activity": value.get("activity", [])})

func _process(_delta: float) -> void:
    if busy or server == null:
        return
    var path: String = folder.path_join("command.json")
    if not FileAccess.file_exists(path):
        return
    var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if request is Dictionary and int(request.get("serial", 0)) > serial:
        serial = int(request.serial)
        busy = true
        _serve.call_deferred(request)

func _history(chat_id: String) -> Object:
    for history: Variant in singleton.get("ChatList"):
        if str(history.HistoryId) == chat_id:
            return history
    return null

func _visible(node: Node, texts: Array[String]) -> void:
    if node is CanvasItem and not node.is_visible_in_tree():
        return
    if node is Label or node is RichTextLabel:
        texts.append(str(node.get("text")))
    for child: Node in node.get_children():
        _visible(child, texts)

func _snapshot(chat_id: String) -> Dictionary:
    var history: Object = _history(chat_id)
    if history == null:
        return {"error": "chat_missing"}
    var pane: Object = singleton.get("Chats")
    pane.set("current_tab", (singleton.get("ChatList") as Array).find(history))
    await get_tree().process_frame
    var persisted: Dictionary = history.call("Serialize")
    var file := FileAccess.open(folder.path_join("history.json"), FileAccess.WRITE)
    file.store_string(JSON.stringify(persisted))
    file.close()
    var restored: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("history.json")))
    var texts: Array[String] = []
    var activity_texts: Array[String] = []
    var live_reply: Dictionary = {}
    var histories: Array = history.get("HistoryItemList")
    for index: int in range(histories.size() - 1, -1, -1):
        var item: Object = histories[index]
        if int(item.get("Role")) not in [1, 2]:
            continue
        live_reply = {"id": str(item.get_instance_id()), "error": str(item.get("Error")),
            "complete": bool(item.get("Complete"))}
        var rendered: Node = item.get("rendered_node")
        if is_instance_valid(rendered):
            _visible(rendered, texts)
        for node: Node in get_tree().get_nodes_in_group("plugin_chat_activity"):
            if str(node.get_meta("reply_id", "")) == live_reply.id:
                _visible(node, activity_texts)
        break
    return {"active": bool(history.get("is_request_active")), "history": restored,
        "reply_texts": texts, "activity_texts": activity_texts, "live_reply": live_reply,
        "replies": replies.duplicate(true),
        "http_tools": http_tools.duplicate(), "termination": history.get("termination_reason"),
        "turn_event": turn_events.get(chat_id, {})}

func _serve(request: Dictionary) -> void:
    var result: Dictionary = {}
    match str(request.action):
        "install":
            result = await plugins.call("install_plugin", str(config.manifest), true)
            if result.get("ok", false):
                var store: Object = singleton.get("plugin_settings_store")
                for key: String in config.settings:
                    var value: Variant = config.settings[key]
                    if value is String:
                        value = value.replace("{minerva_mcp}", "http://127.0.0.1:%d/mcp" % manager.call("get_http_server_port"))
                    var applied: Dictionary = store.call("set_value", "plugin:" + str(config.plugin_id), key, value)
                    if not applied.get("success", false):
                        result = {"error": "invalid_plugin_setting", "key": key}
                        break
            if result.get("ok", false):
                result = await plugins.call("start_plugin", str(config.plugin_id))
                connection = plugins.call("get_connection", str(config.plugin_id))
                if connection != null:
                    connection.connect("tool_result_received", _on_reply)
        "tool":
            result = await server.call("call_tool", str(request.tool), request.arguments)
        "snapshot":
            result = await _snapshot(str(request.chat_id))
        "short_budget":
            var registry: Object = plugins.call("get_chat_provider_registry")
            var key: String = "plugin:%s:%s" % [config.plugin_id, config.entry_id]
            var entry: Dictionary = registry.call("get_entry", key)
            if not entry.is_empty():
                entry["timeout_sec"] = 11
                result = registry.call("register_entry", str(config.plugin_id), entry)
        "stop":
            var history: Object = _history(str(request.chat_id))
            var pane: Object = singleton.get("Chats")
            if history != null:
                pane.set("current_tab", (singleton.get("ChatList") as Array).find(history))
                var button: Object = pane.get("audio_stop_1")
                if button != null and not button.get("disabled"):
                    button.emit_signal("pressed")
                    result = {"pressed": true}
        "shutdown":
            result = await plugins.call("stop_plugin", str(config.plugin_id))
    _write("answer", {"serial": serial, "result": result})
    busy = false
'''


class Prerequisite(RuntimeError):
    """Environment failure, never credited as a product red."""


class Mcp:
    """External JSON-RPC payloads are dynamic; credentials never enter traces."""

    def __init__(self, endpoint: str, token: str, deadline: float) -> None:
        url = urlsplit(endpoint)
        if url.scheme != "http" or url.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise Prerequisite("T3 endpoint must be private loopback HTTP")
        self.url, self.token, self.serial = url, token, 0
        self.deadline = deadline
        self.headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        initialized = self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                   "clientInfo": {"name": "minerva-t3-crawl", "version": "1"}})
        self.headers["MCP-Protocol-Version"] = initialized.get("protocolVersion", "2025-03-26")
        connection = http.client.HTTPConnection(self.url.hostname, self.url.port, timeout=10)
        try:
            connection.request("POST", self.url.path or "/mcp", json.dumps({"jsonrpc": "2.0",
                "method": "notifications/initialized"}), {**self.headers, "Authorization": "Bearer " + self.token})
            response = connection.getresponse()
            response.read()
            if response.status not in {200, 202, 204}:
                raise Prerequisite("T3 MCP initialization notification refused")
        finally:
            connection.close()

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        self.serial += 1
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("T3 MCP exceeded the E2E deadline")
        connection = http.client.HTTPConnection(self.url.hostname, self.url.port, timeout=min(40, remaining))
        try:
            headers = {**self.headers, "Authorization": "Bearer " + self.token}
            connection.request("POST", self.url.path or "/mcp", json.dumps({"jsonrpc": "2.0",
                "id": self.serial, "method": method, "params": params}), headers)
            response = connection.getresponse()
            body = response.read().decode()
            if response.status != 200:
                raise Prerequisite("T3 MCP HTTP " + str(response.status))
            for key in ("Mcp-Session-Id", "MCP-Protocol-Version"):
                if response.getheader(key):
                    self.headers[key] = response.getheader(key)
            messages = [json.loads(line[5:].strip()) for line in body.splitlines() if line.startswith("data:")]
            if not messages:
                messages = [json.loads(body)]
            envelope = next((m for m in messages if m.get("id") == self.serial), {})
            if "error" in envelope or "result" not in envelope:
                raise Prerequisite("T3 MCP RPC failure")
            return envelope["result"]
        finally:
            connection.close()

    def tool(self, name: str, **arguments: object) -> dict[str, Any]:
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        return object_result(result)

    def settled(self, thread: str, run: str) -> dict[str, Any]:
        return self.tool("t3_thread_wait", threadId=thread, runId=run, timeoutMs=1)

    def read(self, thread: str, run: str) -> list[dict[str, Any]]:
        # Always restart settled reads. A position cursor is not an update feed.
        arguments: dict[str, Any] = {"threadId": thread, "view": "activity", "limit": 100,
                                     "runLimit": 50, "maxCharsPerItem": 50000}
        items: list[dict[str, Any]] = []
        for _ in range(100):
            page = self.tool("t3_thread_read", **arguments)
            for original in page["items"]:
                if original.get("runId") != run:
                    continue
                item = dict(original)
                offsets: set[int] = set()
                while item.get("nextTextOffset") is not None:
                    offset = item["nextTextOffset"]
                    if offset in offsets or len(offsets) >= 100:
                        raise RuntimeError("T3 item text pagination did not converge")
                    offsets.add(offset)
                    segment = self.tool("t3_thread_read", threadId=thread, itemId=item["itemId"],
                                        textOffset=item["nextTextOffset"], maxCharsPerItem=50000)
                    tail = segment["items"][0]
                    item["text"] = (item.get("text") or "") + (tail.get("text") or "")
                    item["nextTextOffset"] = tail.get("nextTextOffset")
                    item["textTruncated"] = tail.get("textTruncated", False)
                if item.get("textTruncated"):
                    raise RuntimeError("T3 item remained truncated without a continuation")
                items.append(item)
            if not page["hasMore"]:
                return items
            arguments["afterPosition"] = page["nextPosition"]
        raise RuntimeError("T3 timeline exceeded E2E bound")


class Crawl:
    def __init__(self, config: dict[str, Any], private: Path) -> None:
        self.config, self.private = config, private
        self.deadline = time.monotonic() + float(config.get("deadline_sec", 1200))
        self.sequence = 0
        self.process: subprocess.Popen[bytes] | None = None
        self.rows: dict[str, Row] = {}
        self.cleanup_failure = ""
        self.environment_failure = ""
        self.blocked_after = ""
        self.chat_id = ""
        self.active_row = ""
        self.phase = "setup"
        self.bound: tuple[str, str] | None = None
        self.reply_start = 0
        self.backend: Mcp

    def wait(self, observation: Callable[[], T], seconds: float = 180) -> T:
        end = min(self.deadline, time.monotonic() + seconds)
        while time.monotonic() < end:
            if self.process is not None and self.process.poll() is not None:
                raise Prerequisite("Owned Minerva process exited")
            if (self.private / "stop.json").exists():
                raise Prerequisite("Observer startup failed")
            value = observation()
            if value:
                return value
            time.sleep(0.1)
        raise TimeoutError("E2E observation deadline")

    def command(self, action: str, **arguments: object) -> dict[str, Any]:
        self.sequence += 1
        path = self.private / "command.json"
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"serial": self.sequence, "action": action, **arguments}))
        temporary.replace(path)

        def answer() -> dict[str, Any] | None:
            target = self.private / "answer.json"
            try:
                value = json.loads(target.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                return None
            return value["result"] if value.get("serial") == self.sequence else None

        # Empty successful results are valid; wrap them so polling terminates.
        def ready_answer() -> tuple[dict[str, Any]] | None:
            value = answer()
            return (value,) if value is not None else None

        result = self.wait(ready_answer)
        return result[0]

    def tool(self, name: str, **arguments: object) -> dict[str, Any]:
        result = object_result(self.command("tool", tool=name, arguments=arguments))
        if result.get("error") or result.get("success") is False:
            raise RuntimeError("Minerva tool refused: " + name)
        return result

    def snapshot(self) -> dict[str, Any]:
        return self.command("snapshot", chat_id=self.chat_id)

    def receipt(self) -> tuple[str, str, dict[str, Any]]:
        status = self.tool(self.config["status_tool"], chat_id=self.chat_id)
        return str(status.get("thread_id", "")), str(status.get("run_id", "")), status

    def emit(self, row: str, passed: bool, *, status: str = "", **observed: bool | int | str) -> None:
        value: Row = {"row": row, "status": status or ("pass" if passed else "fail"), "observed": observed}
        if row == "R3" and passed and not status:
            value["status"] = "deferred"  # approval support is never claimed green
        self.rows[row] = value
        print(json.dumps(value), flush=True)

    def send(self, text: str) -> tuple[str, str]:
        self.phase = "send"
        self.bound = None
        self.reply_start = len(self.snapshot()["replies"])
        previous = self.receipt()[:2] if self.chat_id else ("", "")
        self.tool("minerva_send_message", chat_id=self.chat_id, message=text)

        def accepted() -> tuple[str, str] | None:
            thread, run, _ = self.receipt()
            return (thread, run) if thread and run and (thread, run) != previous else None

        self.bound = self.wait(accepted)
        return self.bound

    def finish(self, thread: str, run: str) -> tuple[dict[str, Any], str, list[dict[str, Any]]]:
        self.phase = "chat_settle"
        self.wait(lambda: not self.snapshot()["active"], 300)
        def terminal() -> dict[str, Any] | None:
            value = self.backend.settled(thread, run)
            return value if value.get("status") in TERMINAL else None

        self.phase = "backend_terminal"
        state = self.wait(terminal)
        self.phase = "settled_snapshot"
        snapshot = self.snapshot()
        items = self.backend.read(thread, run)
        return snapshot, str(state["status"]), items

    def prepare(self) -> None:
        if sys.platform != "linux":
            raise Prerequisite("Linux isolation only; macOS profile override is not implemented")
        source = Path(self.config["minerva_source"]).resolve()
        profile = Path(self.config["profile_template"]).resolve()
        if not (source / "src/project.godot").is_file() or not profile.is_dir():
            raise Prerequisite("Build-ready Minerva and approved profile template required")
        project = self.private / "minerva"
        shutil.copytree(source / "src", project, symlinks=False,
                        ignore=shutil.ignore_patterns("target", "node_modules", "__pycache__", ".git"))
        user = self.private / "data/godot/app_userdata/Minerva"
        shutil.copytree(profile, user)
        workspace = self.private / "workspace"
        workspace.mkdir()
        (workspace / "harmless.txt").write_text("crawl fixture\n")
        self.workspace = workspace
        observer = project / "test/t3_crawl_observer.gd"
        observer.write_text(OBSERVER)
        project_file = project / "project.godot"
        original = project_file.read_text()
        if original.count("[autoload]") != 1:
            raise Prerequisite("Minerva autoload section changed")
        # Append after existing autoloads, not before SingletonObject.
        start = original.index("[autoload]") + len("[autoload]")
        end = original.find("\n[", start)
        if end < 0:
            raise Prerequisite("Minerva autoload boundary missing")
        project_file.write_text(original[:end] + '\nT3CrawlObserver="*res://test/t3_crawl_observer.gd"\n' + original[end:])
        settings = json.loads(json.dumps(self.config.get("settings", {})).replace("{private}", str(self.private))
                              .replace("{workspace}", str(workspace)))
        manifest = Path(self.config["plugin_manifest"]).resolve()
        if json.loads(manifest.read_text()).get("setup"):
            raise Prerequisite("Use a built artifact manifest; do not build in the owner's checkout")
        shutil.copytree(manifest.parent, self.private / "plugin", symlinks=False)
        observed = {**self.config, "settings": settings, "manifest": str(self.private / "plugin" / manifest.name),
                    "project_path": str(workspace / "crawl.minproj"), "port": 0}
        (self.private / "observer-config.json").write_text(json.dumps(observed))
        environment = dict(os.environ)
        for name, directory in (("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                                ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
            environment[name] = str(self.private / directory)
        environment["MINERVA_T3_CRAWL_PRIVATE"] = str(self.private)
        self.log = (self.private / "minerva.log").open("wb")
        self.process = subprocess.Popen([self.config["godot"], "--headless", "--path", str(project)],
                                        env=environment, stdout=self.log, stderr=subprocess.STDOUT)
        self.wait(lambda: (self.private / "ready.json").exists())
        installed = self.command("install")
        if installed.get("error") or not installed.get("ok"):
            raise Prerequisite("Local plugin installation/start failed")
        created = self.tool("minerva_create_chat", name="crawl-" + self.config["nonce"],
                            provider="plugin:" + self.config["plugin_id"] + ":" + self.config["entry_id"])
        self.chat_id = created["chat_id"]
        _, _, status = self.receipt()
        if status.get("provider") != self.config["provider"] or status.get("t3_tag") != self.config["t3_tag"]:
            raise Prerequisite("Runtime provider or release tag differs from acceptance inputs")
        base_dir = Path(status["base_dir"]).resolve()
        if not base_dir.is_relative_to(self.private.resolve()):
            raise Prerequisite("T3 base directory is outside the disposable root")
        if Path(status["codex_home"]).resolve() != Path(self.config["codex_home"]).expanduser().resolve():
            raise Prerequisite("Codex home differs from the owner-approved in-place login")
        token_path = Path(self.config["t3_token_file"].replace("{private}", str(self.private)))
        token = self.wait(lambda: token_path.read_text().strip() if token_path.exists() else "")
        if self.config.get("t3_endpoint", status["endpoint"]) != status["endpoint"]:
            raise Prerequisite("External observer endpoint differs from the plugin runtime")
        self.backend = Mcp(status["endpoint"], token, self.deadline)

    def answer(self, snapshot: dict[str, Any]) -> bool:
        replies = snapshot["replies"][self.reply_start:]
        item = last_item(snapshot)
        return (bool(replies) and replies[-1]["kind"] == "answer"
                and snapshot["live_reply"].get("complete") is True
                and not snapshot["live_reply"].get("error")
                and "passthrough_question_options" not in item.get("HcpData", {})
                and snapshot["turn_event"].get("outcome") == "ok"
                and snapshot["termination"] in {"", "completed"})

    def recover_bound(self) -> None:
        if self.bound is None:
            raise RuntimeError("Accepted-send identity unknown; later rows cannot safely send")
        self.phase = "fixture_cleanup"
        thread, run = self.bound
        self.backend.tool("t3_thread_interrupt", threadId=thread, runId=run)
        self.wait(lambda: self.backend.settled(thread, run).get("status") in TERMINAL, 30)
        if self.snapshot()["active"]:
            self.command("stop", chat_id=self.chat_id)
        self.wait(lambda: not self.snapshot()["active"], 30)

    def run(self) -> None:
        operations = (("R1", self.start), ("R2", self.activity), ("R2b", self.minerva_tool),
                      ("R3", self.permission), ("R4", self.interrupt),
                      ("R5", self.final_result), ("R6", self.pending))
        for row, operation in operations:
            self.active_row, self.phase = row, "start"
            try:
                operation()
            except (OSError, ValueError, KeyError, TypeError, RuntimeError,
                    TimeoutError, http.client.HTTPException) as error:
                self.emit(row, False, status="blocked" if isinstance(error, Prerequisite) else "fail",
                          phase=self.phase, failure_type=type(error).__name__)
                if isinstance(error, Prerequisite):
                    self.environment_failure = type(error).__name__
                try:
                    self.recover_bound()
                except (OSError, ValueError, KeyError, TypeError, RuntimeError,
                        TimeoutError, http.client.HTTPException) as cleanup:
                    self.cleanup_failure = type(cleanup).__name__
                    self.blocked_after = row
                    break

    def start(self) -> None:
        nonce = self.config["nonce"]
        thread, run = self.send("Reply with exactly " + nonce + "-start. Do not run tools.")
        snapshot, state, _ = self.finish(thread, run)
        answered = self.answer(snapshot)
        self.emit("R1", state == "completed" and answered and last_message(snapshot) == nonce + "-start",
                  backend_completed=state == "completed", host_answer=answered,
                  host_outcome=snapshot["turn_event"].get("outcome", ""),
                  termination=snapshot["termination"])

    def activity(self) -> None:
        thread, run = self.send("List harmless.txt in the current workspace using a filesystem tool. "
                                "Then reply exactly " + self.config["nonce"] + "-activity.")
        snapshot, state, items = self.finish(thread, run)
        activity = last_item(snapshot).get("HcpData", {}).get("activity", [])
        labels = [a.get("label", "") for a in activity if isinstance(a, dict)]
        structured = bool(activity) and all(isinstance(a, dict) and a.get("kind") and a.get("label")
                                            and a.get("status") for a in activity)
        rendered = bool(labels) and all(any(label in text for text in snapshot["activity_texts"]) for label in labels)
        native_tool = any(i["type"] in {"command_execution", "file_search"} for i in items)
        self.emit("R2", state == "completed" and self.answer(snapshot) and structured and rendered and native_tool,
                  persisted_activity=structured, visible_reply_activity=rendered, backend_activity=native_tool)

    def minerva_tool(self) -> None:
        # This witness never enters a prompt, filename, or T3 setting. A new
        # otherwise empty chat is ordinary Minerva data, not another agent run.
        witness = "TOOL-WITNESS-" + secrets.token_hex(16)
        self.phase = "fresh_tool_only_witness"
        self.tool("minerva_create_chat", name=witness,
                  provider="plugin:" + self.config["plugin_id"] + ":" + self.config["entry_id"])
        thread, run = self.send("Call the read-only Minerva MCP tool minerva_list_chats. "
                                "Find the chat name starting TOOL-WITNESS- and reply with that exact name only.")
        snapshot, state, items = self.finish(thread, run)
        native_result = False
        for item in items:
            if item["type"] == "dynamic_tool" and item["status"] == "completed":
                value = json.loads(item.get("text") or "{}")
                if (str(value.get("toolName", "")).endswith("minerva_list_chats")
                        and witness in json.dumps(value.get("output"))):
                    native_result = True
        backend_text = "\n".join(i.get("text") or "" for i in items if i["type"] == "assistant_message").strip()
        delivered = last_message(snapshot) == backend_text == witness
        self.emit("R2b", state == "completed" and self.answer(snapshot) and native_result and delivered,
                  successful_native_minerva_result=native_result, fresh_result_delivered=delivered)

    def permission(self) -> None:
        denied = self.private / "permission-sentinel"
        thread, run = self.send("Use the native permission-request mechanism to request write access to "
            + str(denied) + ". It is outside the workspace. Do not write or use a bypass unless permission "
            "is granted. The crawl controller cannot approve permissions.")
        self.phase = "unsupported_permission_deferral"
        self.wait(lambda: not self.snapshot()["active"], 90)
        snapshot = self.snapshot()
        items = self.backend.read(thread, run)
        requested = any(i["type"] == "approval_request" for i in items)
        replies = snapshot["replies"][self.reply_start:]
        native_deferral = bool(replies) and replies[-1]["kind"] == "error" and any(
            a.get("kind") == "permission_request" and a.get("status") == "deferred"
            for a in replies[-1].get("activity", []) if isinstance(a, dict))
        error = snapshot["live_reply"].get("error", "")
        visible = bool(error) and any(error in text for text in snapshot["reply_texts"])
        passed = requested and native_deferral and visible and not denied.exists()
        self.recover_bound()
        self.emit("R3", passed, native_request=requested, host_deferral=native_deferral,
                  visible_error=visible, nothing_written=not denied.exists(), approvals_supported=False)

    def interrupt(self) -> None:
        begun = self.workspace / "interrupt-begun"
        thread, run = self.send("Run a harmless long operation: create interrupt-begun in this workspace, "
                                "then wait 120 seconds. Do not finish early. Afterward reply "
                                + self.config["nonce"] + "-done.")
        self.phase = "long_operation_started"
        self.wait(begun.exists, 180)
        pressed = self.command("stop", chat_id=self.chat_id).get("pressed", False)
        snapshot, state, _ = self.finish(thread, run)
        host_cancelled = snapshot["turn_event"].get("outcome") == "cancelled"
        self.emit("R4", pressed and host_cancelled and state in {"cancelled", "interrupted"},
                  stop_button_pressed=pressed, backend_terminal=state,
                  host_cancelled=host_cancelled, termination=snapshot["termination"])

    def final_result(self) -> None:
        nonce = self.config["nonce"]
        thread, run = self.send("Reply with exactly " + nonce + "-final. Do not run tools.")
        snapshot, state, items = self.finish(thread, run)
        backend_text = "\n".join(i.get("text") or "" for i in items if i["type"] == "assistant_message").strip()
        self.emit("R5", state == "completed" and self.answer(snapshot)
                  and backend_text == last_message(snapshot) == nonce + "-final",
                  completed=state == "completed", transcript_matches=backend_text == last_message(snapshot),
                  host_answer=self.answer(snapshot))

    def pending(self) -> None:
        self.phase = "short_call_budget"
        registration = self.command("short_budget")
        if registration.get("timeout_sec") != 11 or registration.get("error"):
            raise RuntimeError("Provider registration refused R6 budget stimulus")
        thread, run = self.send("Wait at least 15 seconds using a harmless wait tool, then reply exactly "
                                + self.config["nonce"] + "-pending.")
        snapshot, state, _ = self.finish(thread, run)
        replies = snapshot["replies"][self.reply_start:]
        pending = [r for r in replies if r["kind"] == "pending" and r["token"]]
        self.emit("R6", bool(pending) and len(replies) > len(pending) and state == "completed"
                  and self.answer(snapshot) and last_message(snapshot) == self.config["nonce"] + "-pending",
                  pending_replies=len(pending), generate_replies=len(replies),
                  completed=state == "completed", host_answer=self.answer(snapshot))

    def close(self) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            try:
                self.command("shutdown")
            except (RuntimeError, TimeoutError, OSError) as error:
                self.cleanup_failure = type(error).__name__
            self.process.terminate()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(10)
        self.log.close()


def object_result(result: dict[str, Any]) -> dict[str, Any]:
    """Both plain Minerva results and MCP's JSON object envelopes are public."""
    if result.get("isError") or result.get("error"):
        raise RuntimeError("Tool returned an error")
    if isinstance(result.get("structuredContent"), dict):
        return result["structuredContent"]
    if "content" not in result:
        return result
    for part in result["content"]:
        if part.get("type") == "text":
            value = json.loads(part["text"])
            if isinstance(value, dict):
                return value
    raise RuntimeError("Tool returned no structured object")


def last_item(snapshot: dict[str, Any]) -> dict[str, Any]:
    items = snapshot["history"]["HistoryItemList"]
    return next((i for i in reversed(items) if i.get("Role") in {1, 2}), {})


def last_message(snapshot: dict[str, Any]) -> str:
    return str(last_item(snapshot).get("Message", "")).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--describe", action="store_true")
    parser.add_argument("--config", type=Path)
    parser.add_argument("--owner-attended", action="store_true")
    args = parser.parse_args()
    if args.describe:
        for row, oracle in ROWS.items():
            print(json.dumps({"row": row, "status": "authored_not_executed", "oracle": oracle}))
        return 0
    if not args.owner_attended or args.config is None:
        parser.error("Real-account execution requires --owner-attended --config")
    config = json.loads(args.config.read_text())
    required = {"minerva_source", "profile_template", "plugin_manifest", "godot", "provider", "t3_tag",
                "t3_token_file", "codex_home", "settings"}
    if required - config.keys():
        parser.error("Missing config fields: " + ", ".join(sorted(required - config.keys())))
    if config["settings"].get("minerva_mcp_endpoint") != "{minerva_mcp}":
        parser.error("Plugin must wire minerva_mcp_endpoint from {minerva_mcp}")
    config = {"plugin_id": "t3-code", "entry_id": "t3-code", "generate_tool": "minerva_t3_code_generate",
              "status_tool": "minerva_t3_code_status", **config, "nonce": secrets.token_hex(10)}
    os.umask(0o077)
    private = Path(tempfile.mkdtemp(prefix="minerva-t3-crawl-"))
    crawl = Crawl(config, private)
    failure = ""
    try:
        crawl.prepare()
        crawl.run()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, http.client.HTTPException) as error:
        failure = type(error).__name__  # No external exception text or credentials in stdout.
    finally:
        crawl.close()
    for row in ROWS:
        if row not in crawl.rows:
            value: Row = {"row": row, "status": "not_reached", "observed": {
                "failure_type": failure, "blocked_after": crawl.blocked_after, "phase": crawl.phase}}
            crawl.rows[row] = value
            print(json.dumps(value), flush=True)
    script_errors = "SCRIPT ERROR:" in (private / "minerva.log").read_text(errors="replace") if (private / "minerva.log").exists() else False
    accepted = not failure and not crawl.environment_failure and not crawl.cleanup_failure and not script_errors and config["provider"] == "codex" and all(
        row["status"] == ("deferred" if name == "R3" else "pass") for name, row in crawl.rows.items())
    receipt = {"acceptance": accepted, "provider": config["provider"], "t3_tag": config["t3_tag"],
               "failure_type": failure, "environment_failure": crawl.environment_failure,
               "cleanup_failure": crawl.cleanup_failure, "script_errors": script_errors,
               "private_evidence": str(private), "retention": "retained owner-only; raw logs/profile/history never published",
               "test_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "rows": list(crawl.rows.values())}
    (private / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: v for k, v in receipt.items() if k != "rows"}))
    return 0 if accepted else (90 if failure or crawl.environment_failure or crawl.cleanup_failure or script_errors else 1)


if __name__ == "__main__":
    raise SystemExit(main())
