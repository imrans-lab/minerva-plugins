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
Optional: plugin_id, entry_id, generate_tool, status_tool, deadline_sec,
  launch_paid_turns: paid Codex turns D3/D4 may spend (default 0). Each
  spends at most one; without budget the row reports not_run, never pass.

The approved profile must give the runtime its existing owner-approved provider
login, exact binary/home, explicit approval-required mode and one read-only
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

D1-D6 (DCR minerva:01a1a2fe74de) drive the real passthrough launch dialog
through its own controls (button pressed, OptionButton select + item_selected,
Start pressed) and read control state, the chat list and public MCP results.
The fixture saves its .minproj through the real project save before install,
so the plugin pins that folder at start. Headless control state is not pixels:
the parts listed in HITL stay owner steps and are reported pending, not green.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import http.client
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
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
    "D1": "dialog offers T3 Code only while plugin:t3_code:t3-code is registered",
    "D2": "unsaved project refused inline: no chat, no launch call",
    "D3": "first-use Start registers the folder via the plugin; first turn exact text (paid)",
    "D4": "chosen non-default model/effort in status and the thread modelSelection (paid)",
    "D5": "picker lists no W1 entry; a dialog-bound chat shows its live item",
    "D6": "plugin-refused launch leaves no chat, no restorable chat, no plugin record",
}
# How each launch-dialog row goes red (localized break, same test).
RED = {
    "D1": "kind offered with the entry dropped (stop plugin), or not offered while registered",
    "D2": "saved-project check removed: Start creates a chat or calls minerva_t3_code_launch",
    "D3": "registration skipped/unreported, output hidden, chat not locked or CallerDriven, wrong answer",
    "D4": "dialog/plugin drops the choice: launch args, status or thread show the project default",
    "D5": "W1 entries appended to the default picker set, or the bound chat reads (offline)/other text",
    "D6": "chat_discarder not called on a launch error: the session chat remains listed",
}
# Owner-only steps; the crawl never marks these green.
HITL = {
    "D1": "Release build, saved project, T3 Code running: click the passthrough (horizontal arrows) "
          "button; Launch kind lists Terminal and T3 Code. Stop T3 Code in Plugins; reopen: no Launch "
          "kind selector, terminal fields only. Start T3 Code; reopen: T3 Code listed again.",
    "D2": "File > New project (unsaved); passthrough button; choose T3 Code: the form reads 'Save the "
          "current project before starting T3 Code.'; press Start: same inline text, no new chat tab.",
    "D5": "Open the model picker on an ordinary chat: no T3 Code (Codex), Council or agent-relay "
          "entries. Switch to a dialog-launched T3 tab: picker disabled, showing 'T3 Code · Codex · "
          "<model> · <effort>' without (offline).",
}
T3_KIND = "T3 Code"
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
    if server == null or (not bool(manager.call("is_http_server_running"))
            and int(manager.call("start_http_server", int(config.port))) != OK):
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

func _observe_connection() -> void:
    var current: Object = plugins.call("get_connection", str(config.plugin_id))
    if current == null:
        return
    if is_instance_valid(connection) and current == connection:
        return
    if is_instance_valid(connection) and connection.is_connected("tool_result_received", _on_reply):
        connection.disconnect("tool_result_received", _on_reply)
    connection = current
    if not connection.is_connected("tool_result_received", _on_reply):
        connection.connect("tool_result_received", _on_reply)

func _process(_delta: float) -> void:
    if server == null:
        return
    _observe_connection()
    if busy:
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
        live_reply = {"id": str(item.get_instance_id()), "message_index": index, "error": str(item.get("Error")),
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

func _find(node: Node, check: Callable) -> Node:
    if check.call(node):
        return node
    for child: Node in node.get_children():
        var found: Node = _find(child, check)
        if found != null:
            return found
    return null

func _wait_until(check: Callable, seconds: float) -> bool:
    var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
    while Time.get_ticks_msec() < deadline:
        if check.call():
            return true
        await get_tree().create_timer(0.1).timeout
    return bool(check.call())

func _chat_ids() -> Array[String]:
    var ids: Array[String] = []
    for history: Variant in singleton.get("ChatList"):
        ids.append(str(history.HistoryId))
    return ids

func _registry_keys() -> Array[String]:
    var keys: Array[String] = []
    var registry: Object = plugins.call("get_chat_provider_registry")
    for entry: Variant in registry.call("list_entries"):
        keys.append(str(entry.get("key", "")))
    return keys

# Real project menu save; "" is Minerva's unsaved project.
func _project(path_: String) -> Dictionary:
    if path_.is_empty():
        singleton.set("current_project_path", "")
    else:
        var is_menu: Callable = func(n: Node) -> bool:
            return n.has_method("save_project_as") and n.has_method("save_project")
        var menu: Node = _find(get_tree().root, is_menu)
        if menu == null:
            return {"error": "project_menu_missing"}
        menu.call("save_project_as", path_)
        var saved: Callable = func() -> bool:
            return FileAccess.file_exists(path_) and str(singleton.get("current_project_path")) == path_
        await _wait_until(saved, 30.0)
    var current: String = str(singleton.get("current_project_path"))
    return {"path": current, "exists": not current.is_empty() and FileAccess.file_exists(current)}

# Opens the dialog with its top-bar button and uses only its own controls. The
# launch callable is wrapped to RECORD the plugin call; only D6 forces a model.
func _dialog(request: Dictionary) -> Dictionary:
    var pane: Object = singleton.get("Chats")
    var is_launcher: Callable = func(n: Node) -> bool:
        return n is Button and str(n.get("tooltip_text")) == "New passthrough chat"
    var button: Node = _find(get_tree().root, is_launcher)
    if button == null:
        return {"error": "passthrough_button_missing"}
    button.emit_signal("pressed")
    var dialog: Object = pane.get("_passthrough_launch_dialog")
    if dialog == null or not bool(dialog.get("visible")):
        return {"error": "launch_dialog_missing"}
    await get_tree().process_frame
    var cancel: Button = dialog.get("_cancel_button")
    var kinds_button: OptionButton = dialog.get("_kind_dropdown")
    var kinds: Array[String] = []
    for index: int in range(kinds_button.item_count):
        kinds.append(kinds_button.get_item_text(index))
    var key: String = "plugin:%s:%s" % [config.plugin_id, config.entry_id]
    var result: Dictionary = {"kinds": kinds, "kind_visible": kinds_button.visible,
        "registered": _registry_keys().has(key), "completed": false, "error": "", "notice_before": "",
        "result_text": "", "launch_calls": [], "new_chats": []}
    var kind_index: int = kinds.find(str(request.get("kind", "")))
    if kind_index < 0:
        cancel.emit_signal("pressed")
        if not str(request.get("kind", "")).is_empty():
            result["error"] = "launch_kind_missing"
        return result
    kinds_button.select(kind_index)
    kinds_button.item_selected.emit(kind_index)
    var form: Node = dialog.get("_t3_form")
    var loaded: Callable = func() -> bool:
        return not bool(form.get("_loading"))
    await _wait_until(loaded, 120.0)
    var models: OptionButton = form.get("_models")
    var efforts: OptionButton = form.get("_efforts")
    var choices: Array = form.get("_choices")
    if not str(request.get("model", "")).is_empty():
        for index: int in range(choices.size()):
            if str(choices[index].get("id")) == str(request.model):
                models.select(index)
                models.item_selected.emit(index)
    if not str(request.get("effort", "")).is_empty():
        for index: int in range(efforts.item_count):
            if str(efforts.get_item_metadata(index)) == str(request.effort):
                efforts.select(index)
                efforts.item_selected.emit(index)
    result["notice_before"] = str((form.get("_notice") as Label).text)
    var name_edit: LineEdit = dialog.get("_name_edit")
    name_edit.text = str(request.get("name", ""))
    name_edit.text_changed.emit(name_edit.text)
    var real: Callable = dialog.get("tool_caller")
    var reader: Callable = dialog.get("project_reader")
    var calls: Array = []
    var forced_model: String = str(request.get("force_model", ""))
    var recorder: Callable = func(tool: String, arguments: Dictionary) -> Dictionary:
        var sent: Dictionary = arguments.duplicate(true)
        if tool == "minerva_t3_code_launch" and not forced_model.is_empty():
            sent["model"] = forced_model
        var reply: Dictionary = await real.call(tool, sent)
        if tool == "minerva_t3_code_launch":
            calls.append({"args": sent.duplicate(true), "reply": reply.duplicate(true)})
        return reply
    form.call("configure", recorder, reader)
    var before: Array[String] = _chat_ids()
    (dialog.get("_start_button") as Button).emit_signal("pressed")
    var settled: Callable = func() -> bool:
        return not bool(dialog.get("_launching"))
    await _wait_until(settled, 240.0)
    form.call("configure", real, reader)
    result["completed"] = bool(dialog.get("_completed"))
    result["error"] = str(dialog.call("current_error"))
    result["result_text"] = str((form.get("_result") as TextEdit).text)
    result["launch_calls"] = calls
    for history: Variant in singleton.get("ChatList"):
        if not before.has(str(history.HistoryId)):
            var provider: Variant = history.get("provider")
            var entry_key: String = ""
            if provider is Object and "entry_key" in provider:
                entry_key = str(provider.get("entry_key"))
            result["new_chats"].append({"chat_id": str(history.HistoryId), "name": str(history.get("HistoryName")),
                "passthrough": bool(history.PassthroughMode), "caller_driven": bool(history.CallerDriven),
                "badge": str(history.PassthroughName), "entry_key": entry_key})
    cancel.emit_signal("pressed")
    return result

func _picker(chat_id: String) -> Dictionary:
    var history: Object = _history(chat_id)
    if history == null:
        return {"error": "chat_missing"}
    var pane: Object = singleton.get("Chats")
    pane.set("current_tab", (singleton.get("ChatList") as Array).find(history))
    await get_tree().process_frame
    await get_tree().process_frame
    var picker: OptionButton = pane.get("_provider_option_button")
    var items: Array[Dictionary] = []
    for index: int in range(picker.item_count):
        var meta: Variant = picker.get_item_metadata(index)
        items.append({"text": picker.get_item_text(index), "meta": meta if meta is String else "",
            "disabled": picker.is_item_disabled(index), "selected": index == picker.selected})
    return {"items": items, "registry_keys": _registry_keys(), "locked": bool(picker.call("is_locked"))}

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
                _observe_connection()
        "tool":
            result = await server.call("call_tool", str(request.tool), request.arguments)
        "snapshot":
            result = await _snapshot(str(request.chat_id))
        "begin_turn":
            var turn_history: Object = _history(str(request.chat_id))
            turn_events.erase(str(request.chat_id))
            if turn_history != null:
                result = {"ok": true, "items": (turn_history.get("HistoryItemList") as Array).size()}
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
        "start_plugin":
            result = await plugins.call("start_plugin", str(config.plugin_id))
            _observe_connection()
        "registry":
            result = {"keys": _registry_keys()}
        "project":
            result = await _project(str(request.path))
        "dialog":
            result = await _dialog(request)
        "picker":
            result = await _picker(str(request.chat_id))
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
        self.history_start = 0
        self.send_attempted = False
        self.main_chat = ""
        self.project_path = ""
        self.paid_turns_left = int(config.get("launch_paid_turns", 0))
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

    def tool(self, tool_name: str, **arguments: object) -> dict[str, Any]:
        result = object_result(self.command("tool", tool=tool_name, arguments=arguments))
        if result.get("error") or result.get("success") is False:
            raise RuntimeError("Minerva tool refused: " + tool_name)
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
        begun = self.command("begin_turn", chat_id=self.chat_id)
        if not begun.get("ok"):
            raise RuntimeError("Unable to observe a fresh chat turn")
        self.history_start = int(begun["items"])
        self.send_attempted = True
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
        # The plugin pins the saved .minproj folder at start: save it first.
        self.project_path = str(workspace / "crawl.minproj")
        self.save_project()
        installed = self.command("install")
        if installed.get("error") or not installed.get("ok"):
            raise Prerequisite("Local plugin installation/start failed")
        created = self.tool("minerva_create_chat", name="crawl-" + self.config["nonce"],
                            provider="plugin:" + self.config["plugin_id"] + ":" + self.config["entry_id"])
        self.chat_id = self.main_chat = created["chat_id"]
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
                and snapshot["turn_event"].get("message_index") == snapshot["live_reply"].get("message_index")
                and snapshot["live_reply"].get("message_index", -1) >= self.history_start
                and snapshot["termination"] in {"", "completed"})

    def recover_bound(self) -> None:
        if self.bound is None:
            if self.send_attempted:
                raise RuntimeError("Accepted-send identity unknown; later rows cannot safely send")
            return
        self.phase = "fixture_cleanup"
        thread, run = self.bound
        self.backend.tool("t3_thread_interrupt", threadId=thread, runId=run)
        self.wait(lambda: self.backend.settled(thread, run).get("status") in TERMINAL, 30)
        if self.snapshot()["active"]:
            self.command("stop", chat_id=self.chat_id)
        self.wait(lambda: not self.snapshot()["active"], 30)

    def run(self) -> None:
        # D6 refuses before registration, so D3 still observes first use. D1
        # restarts the plugin and runs last; nothing after it uses the backend.
        operations = (("D2", self.unsaved), ("D6", self.failed_launch), ("D3", self.first_use),
                      ("D4", self.chosen_settings), ("D5", self.picker),
                      ("R1", self.start), ("R2", self.activity), ("R2b", self.minerva_tool),
                      ("R3", self.permission), ("R4", self.interrupt),
                      ("R5", self.final_result), ("R6", self.pending), ("D1", self.offered))
        for row, operation in operations:
            self.active_row, self.phase = row, "start"
            self.chat_id = self.main_chat
            self.bound, self.send_attempted = None, False
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

    def activity(self, stimulus: str | None = None) -> None:
        thread, run = self.send(stimulus or ("List harmless.txt in the current workspace using a filesystem tool. "
                                "Then reply exactly " + self.config["nonce"] + "-activity."))
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

    def permission(self, stimulus: str | None = None) -> None:
        denied = self.private / "permission-sentinel"
        thread, run = self.send(stimulus or ("Use the native permission-request mechanism to request write access to "
            + str(denied) + ". It is outside the workspace. Do not write or use a bypass unless permission "
            "is granted. The crawl controller cannot approve permissions."))
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
        error_visible = bool(error) and any(error in text and "permission" in text.lower()
                                            and "defer" in text.lower() for text in snapshot["reply_texts"])
        card = "\n".join(snapshot["activity_texts"]).lower()
        visible = error_visible or ("permission" in card and "defer" in card)
        passed = requested and native_deferral and visible and not denied.exists()
        self.recover_bound()
        self.emit("R3", passed, native_request=requested, host_deferral=native_deferral,
                  visible_error=visible, nothing_written=not denied.exists(), approvals_supported=False)

    def interrupt(self, *, prefill: bool = False, command_wait_sec: float = 180) -> None:
        # The controller owns this Linux fixture. Codex only reads it: cat's
        # open blocks while no writer exists, with no write/approval stimulus.
        gate = self.workspace / "interrupt-read-gate"
        os.mkfifo(gate, mode=0o600)
        stop_writer = threading.Event()
        writer_errors: list[str] = []

        def feed_fifo() -> None:
            while not stop_writer.is_set() and time.monotonic() < self.deadline:
                try:
                    descriptor = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                except OSError as error:
                    if error.errno != errno.ENXIO:
                        writer_errors.append(type(error).__name__)
                        return
                    stop_writer.wait(0.05)
                    continue
                try:
                    os.write(descriptor, b"controller-ready\n")
                except OSError as error:
                    writer_errors.append(type(error).__name__)
                finally:
                    os.close(descriptor)
                return

        writer = threading.Thread(target=feed_fifo, daemon=True) if prefill else None

        def settle_writer() -> None:
            stop_writer.set()
            if writer is not None:
                writer.join(1)
                if writer.is_alive():
                    raise Prerequisite("Controller FIFO writer did not stop")
            if writer_errors:
                raise Prerequisite("Controller FIFO writer failed")

        if writer is not None:
            writer.start()
        try:
            thread, run = self.send("Use cat to read interrupt-read-gate in the current workspace. "
                                    "It is a fixture-owned pipe with no writer, so the read should block. "
                                    "Do not create or write files, request permission, or finish early. "
                                    "Keep waiting until Stop; afterward reply " + self.config["nonce"] + "-done.")
            self.phase = "long_operation_started"

            def running_command() -> bool:
                if writer_errors:
                    raise Prerequisite("Controller FIFO writer failed")
                items = self.backend.read(thread, run)
                command = any(item["type"] == "command_execution"
                              and item["status"] in {"running", "in_progress"} for item in items)
                return command and self.backend.settled(thread, run).get("status") == "running"

            self.wait(running_command, command_wait_sec)
            pressed = self.command("stop", chat_id=self.chat_id).get("pressed", False)
            snapshot, state, _ = self.finish(thread, run)
            event_index = snapshot["turn_event"].get("message_index", -2)
            reply_index = snapshot["live_reply"].get("message_index", -1)
            current_event = (event_index == reply_index and reply_index >= self.history_start) or (
                event_index == -1 and reply_index < self.history_start)
            host_cancelled = current_event and snapshot["turn_event"].get("outcome") == "cancelled"
            settle_writer()
            self.emit("R4", pressed and host_cancelled and state in {"cancelled", "interrupted"},
                      backend_command_started=True, stop_button_pressed=pressed, backend_terminal=state,
                      host_cancelled=host_cancelled, termination=snapshot["termination"])
        finally:
            settle_writer()

    def final_result(self) -> None:
        nonce = self.config["nonce"]
        thread, run = self.send("Reply with exactly " + nonce + "-final. Do not run tools.")
        snapshot, state, items = self.finish(thread, run)
        backend_text = "\n".join(i.get("text") or "" for i in items if i["type"] == "assistant_message").strip()
        self.emit("R5", state == "completed" and self.answer(snapshot)
                  and backend_text == last_message(snapshot) == nonce + "-final",
                  completed=state == "completed", transcript_matches=backend_text == last_message(snapshot),
                  host_answer=self.answer(snapshot))

    def pending(self, stimulus: str | None = None, *, short_budget: bool = True) -> None:
        self.phase = "short_call_budget"
        if short_budget:
            registration = self.command("short_budget")
            if registration.get("timeout_sec") != 11 or registration.get("error"):
                raise RuntimeError("Provider registration refused R6 budget stimulus")
        thread, run = self.send(stimulus or ("Wait at least 15 seconds using a read-only wait tool. Do not create or write "
                                "files or request permission. Then reply exactly "
                                + self.config["nonce"] + "-pending."))
        snapshot, state, _ = self.finish(thread, run)
        replies = snapshot["replies"][self.reply_start:]
        pending = [r for r in replies if r["kind"] == "pending" and r["token"]]
        self.emit("R6", bool(pending) and len(replies) > len(pending) and state == "completed"
                  and self.answer(snapshot) and last_message(snapshot) == self.config["nonce"] + "-pending",
                  pending_replies=len(pending), generate_replies=len(replies),
                  completed=state == "completed", host_answer=self.answer(snapshot))

    # ---- Launch-dialog rows (DCR 01a1a2fe74de). Each opens its own dialog. ----

    def save_project(self) -> None:
        saved = self.command("project", path=self.project_path)
        if saved.get("path") != self.project_path or saved.get("exists") is not True:
            raise Prerequisite("Real project save did not produce the saved .minproj")

    def entry_key(self) -> str:
        return "plugin:" + self.config["plugin_id"] + ":" + self.config["entry_id"]

    def launch_options(self) -> dict[str, Any]:
        options = self.tool(self.config["status_tool"]).get("launch_options")
        if not isinstance(options, dict) or options.get("available") is not True:
            raise Prerequisite("T3 launch options unavailable")
        return options

    def dialog(self, name: str = "", **choices: str) -> dict[str, Any]:
        seen = self.command("dialog", name=name, kind=T3_KIND if name else "", **choices)
        if seen.get("error") in {"passthrough_button_missing", "launch_dialog_missing", "launch_kind_missing"}:
            raise RuntimeError("Launch dialog refused: " + str(seen["error"]))
        return seen

    def listed(self, name: str) -> bool:
        return name in json.dumps(self.tool("minerva_list_chats"))

    def paid_turn(self) -> bool:
        if self.paid_turns_left <= 0:
            return False
        self.paid_turns_left -= 1
        return True

    def one_chat(self, seen: dict[str, Any]) -> dict[str, Any]:
        chats = seen["new_chats"]
        return chats[0] if len(chats) == 1 else {}

    def attended_session(self, chat: dict[str, Any]) -> bool:
        return (chat.get("passthrough") is True and chat.get("caller_driven") is False
                and chat.get("entry_key") == self.entry_key())

    def unsaved(self) -> None:
        # Oracle: inline refusal, no chat, no plugin call. Control: D3 Start
        # with the saved project. Red: RED["D2"].
        name = "D2-" + self.config["nonce"]
        self.phase = "unsaved_project"
        try:
            if self.command("project", path="").get("path") != "":
                raise Prerequisite("Unable to clear the current project")
            seen = self.dialog(name)
        finally:
            self.phase = "restore_saved_project"
            self.save_project()
        refused = not seen["completed"] and "Save the current project" in seen["error"]
        no_chat = not seen["new_chats"] and not self.listed(name)
        self.emit("D2", refused and no_chat and not seen["launch_calls"], inline_refusal=refused,
                  no_chat=no_chat, launch_calls=len(seen["launch_calls"]))

    def failed_launch(self) -> None:
        # Stimulus: the recorder forces one unadvertised model into the real
        # plugin call; the refusal and the dialog's cleanup are real. Control:
        # the recorded chat_id proves a chat was created first. Red: RED["D6"].
        name, bogus = "D6-" + self.config["nonce"], "crawl-unadvertised-" + self.config["nonce"]
        self.phase = "forced_plugin_refusal"
        seen = self.dialog(name, force_model=bogus)
        calls = seen["launch_calls"]
        chat_id = str(calls[0]["args"].get("chat_id", "")) if len(calls) == 1 else ""
        reply = plain(calls[0]["reply"]) if chat_id else {}
        # Code placement varies by host envelope; the dialog shows the same code.
        refused = bool(chat_id) and "model_unavailable" in json.dumps(reply)
        shown = not seen["completed"] and "model_unavailable" in seen["error"]
        self.phase = "no_orphan"
        gone = (not seen["new_chats"] and not self.listed(name)
                and name not in json.dumps(self.tool("minerva_list_deleted_chats")))
        record = self.tool(self.config["status_tool"], chat_id=chat_id) if chat_id else {}
        no_record = bool(chat_id) and record.get("model_selection") is None and record.get("thread_id") == ""
        self.emit("D6", refused and shown and gone and no_record, chat_created_then_refused=refused,
                  inline_error=shown, no_chat_left=gone, no_plugin_record=no_record)

    def first_use(self) -> None:
        # Oracle: notice names the folder, Start registers it through the
        # plugin and shows the output, chat is a locked non-CallerDriven
        # passthrough; then (paid) exact first answer. Red: RED["D3"].
        self.phase = "first_use_precondition"
        if self.launch_options().get("registered") is not False:
            raise Prerequisite("Pinned folder already registered; first use is not observable")
        nonce, name = self.config["nonce"], "D3-" + self.config["nonce"]
        self.phase = "dialog_start"
        seen = self.dialog(name)
        reply = plain(seen["launch_calls"][-1]["reply"]) if seen["launch_calls"] else {}
        raw_registration = reply.get("registration")
        registration: dict[str, Any] = raw_registration if isinstance(raw_registration, dict) else {}
        output = str(registration.get("output", "")).strip()
        performed = registration.get("performed") is True and bool(output)
        named = "First use: register " + str(self.workspace) in seen["notice_before"]
        shown = performed and output in seen["result_text"]
        chat = self.one_chat(seen)
        registered = self.launch_options().get("registered") is True
        prepared = seen["completed"] and performed and named and shown and self.attended_session(chat) and registered
        observed: dict[str, Any] = {"registration_performed": performed, "folder_named": named,
            "output_shown": shown, "locked_attended_chat": self.attended_session(chat), "registered_after": registered}
        if not prepared:
            self.emit("D3", False, **observed)
            return
        if not self.paid_turn():
            self.emit("D3", False, status="not_run", paid_turn="no_budget", **observed)
            return
        self.chat_id = chat["chat_id"]
        thread, run = self.send("Reply with exactly " + nonce + "-d3. Do not run tools.")
        snapshot, state, _ = self.finish(thread, run)
        exact = last_message(snapshot) == nonce + "-d3"
        self.emit("D3", state == "completed" and self.answer(snapshot) and exact,
                  backend_completed=state == "completed", exact_answer=exact, **observed)

    def chosen_settings(self) -> None:
        # Choice is never the project default, so a dropped selection shows.
        # Oracle: launch args, reply, badge, status; then (paid) the T3
        # thread's modelSelection via read-only t3_thread_configure. Red: RED["D4"].
        options = self.launch_options()
        raw_default = options.get("default")
        default: dict[str, Any] = raw_default if isinstance(raw_default, dict) else {}
        default_pair = (default.get("model"), selection_effort(default))
        models = [m for m in options.get("models", []) if isinstance(m, dict)]
        if not any(isinstance(m.get("efforts"), list) and m["efforts"] for m in models):
            self.emit("D4", False, effort_advertised=False)
            return
        candidates = [(str(m["id"]), str(e)) for m in models if isinstance(m.get("efforts"), list)
                      for e in m["efforts"] if (m["id"], e) != default_pair and e != m.get("default_effort")]
        if not candidates:
            raise Prerequisite("No non-default advertised model/effort pair to choose")
        model, effort = sorted(candidates, key=lambda pair: pair[0] == default_pair[0])[0]
        seen = self.dialog("D4-" + self.config["nonce"], model=model, effort=effort)
        sent = seen["launch_calls"][-1]["args"] if seen["launch_calls"] else {}
        reply = plain(seen["launch_calls"][-1]["reply"]) if seen["launch_calls"] else {}
        chat = self.one_chat(seen)
        badge = "T3 Code · Codex · " + model + " · " + effort
        host_sent = sent.get("model") == model and sent.get("effort") == effort
        confirmed = (seen["completed"] and reply.get("model") == model and reply.get("effort") == effort
                     and reply.get("display_name") == badge and chat.get("badge") == badge)
        stored = self.tool(self.config["status_tool"], chat_id=chat.get("chat_id", "")).get("model_selection") \
            if chat else None
        in_status = isinstance(stored, dict) and stored.get("model") == model and selection_effort(stored) == effort
        observed: dict[str, Any] = {"dialog_sent_choice": host_sent, "confirmed_and_badge": confirmed,
            "status_selection": in_status, "model_is_default": model == default_pair[0]}
        if not (host_sent and confirmed and in_status):
            self.emit("D4", False, **observed)
            return
        if not self.paid_turn():
            self.emit("D4", False, status="not_run", paid_turn="no_budget", **observed)
            return
        self.chat_id = chat["chat_id"]
        thread, run = self.send("Reply with exactly " + self.config["nonce"] + "-d4. Do not run tools.")
        _, state, _ = self.finish(thread, run)
        snapshot = self.backend.tool("t3_thread_configure", threadId=thread).get("modelSelection")
        in_thread = (isinstance(snapshot, dict) and snapshot.get("model") == model
                     and selection_effort(snapshot) == effort
                     and snapshot.get("instanceId") == options.get("instance_id"))
        self.emit("D4", state == "completed" and in_thread, thread_selection=in_thread,
                  backend_completed=state == "completed", **observed)

    def picker(self) -> None:
        # Oracle: an ordinary core-model chat's picker holds no registered W1
        # key; a dialog-bound chat shows exactly its live item. Control: the
        # key is registered and MCP list_models still lists it. Red: RED["D5"].
        key = self.entry_key()
        self.phase = "ordinary_chat"
        providers = self.tool("minerva_list_models").get("providers", [])
        core = next((str(p["key"]) for p in providers if isinstance(p, dict) and p.get("key") not in {None, "plugin"}), "")
        rows = self.tool("minerva_list_models", provider=core).get("models", []) if core else []
        spec = next((r["model_spec"] for r in rows if isinstance(r, dict) and isinstance(r.get("model_spec"), dict)), None)
        if spec is None:
            raise Prerequisite("No core model available for an ordinary chat")
        ordinary = self.tool("minerva_create_chat", name="D5-model-" + self.config["nonce"], model_spec=spec)["chat_id"]
        plain_view = self.command("picker", chat_id=ordinary)
        keys = plain_view.get("registry_keys", [])
        leaked = [item for item in plain_view.get("items", []) if item["meta"] in keys]
        models_only = key in keys and bool(plain_view.get("items")) and not leaked
        self.phase = "bound_chat"
        seen = self.dialog("D5-" + self.config["nonce"])
        chat = self.one_chat(seen)
        bound_view = self.command("picker", chat_id=chat["chat_id"]) if chat else {}
        live = [item for item in bound_view.get("items", []) if item["meta"] == key]
        shows = (len(live) == 1 and live[0]["selected"] and bound_view.get("locked") is True
                 and live[0]["text"] == chat.get("badge") and not live[0]["text"].endswith("(offline)"))
        mcp_listed = key in json.dumps(self.tool("minerva_list_models", provider="plugin"))
        self.emit("D5", models_only and seen["completed"] and shows and mcp_listed, picker_models_only=models_only,
                  leaked_entries=len(leaked), bound_live_item=shows, mcp_lists_entry=mcp_listed)

    def offered(self) -> None:
        # Oracle and control in one row: offered while registered, absent once
        # the stopped plugin's entry drops, offered again after restart. MCP
        # list_models must agree each time. Red: RED["D1"].
        key = self.entry_key()

        def state() -> tuple[bool, bool]:
            seen = self.dialog()
            listed = key in json.dumps(self.tool("minerva_list_models", provider="plugin"))
            return T3_KIND in seen["kinds"] and seen["kind_visible"] and seen["registered"] and listed, (
                seen["kinds"] == ["Terminal"] and not seen["kind_visible"] and not seen["registered"] and not listed)

        self.phase = "registered"
        offered, _ = state()
        self.phase = "entry_dropped"
        self.command("shutdown")
        self.wait(lambda: key not in self.command("registry")["keys"], 60)
        _, hidden = state()
        self.phase = "entry_restored"
        self.command("start_plugin")
        self.wait(lambda: key in self.command("registry")["keys"], 180)
        reoffered, _ = state()
        self.emit("D1", offered and hidden and reoffered, offered_registered=offered,
                  hidden_unregistered=hidden, offered_after_restart=reoffered)

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


def plain(reply: Any) -> dict[str, Any]:
    """A recorded host tool reply, unwrapped without raising on errors."""
    if not isinstance(reply, dict):
        return {}
    if isinstance(reply.get("structuredContent"), dict):
        return reply["structuredContent"]
    for part in reply.get("content", []) if isinstance(reply.get("content"), list) else []:
        if isinstance(part, dict) and part.get("type") == "text":
            try:
                value = json.loads(part.get("text", ""))
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                return value
    return reply


def selection_effort(selection: dict[str, Any]) -> str | None:
    options = selection.get("options")
    for option in options if isinstance(options, list) else []:
        if isinstance(option, dict) and option.get("id") == "reasoningEffort":
            return str(option.get("value"))
    return None


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
            described: dict[str, str] = {"row": row, "status": "authored_not_executed", "oracle": oracle}
            if row in RED:
                described["red"] = RED[row]
            print(json.dumps(described))
        for row, steps in HITL.items():
            print(json.dumps({"row": row, "status": "hitl_manual", "steps": steps}))
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
    if not isinstance(config.get("launch_paid_turns", 0), int) or config.get("launch_paid_turns", 0) < 0:
        parser.error("launch_paid_turns must be a non-negative integer")
    config = {"plugin_id": "t3_code", "entry_id": "t3-code", "generate_tool": "minerva_t3_code_generate",
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
               "test_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "hitl_pending": sorted(HITL), "rows": list(crawl.rows.values())}
    (private / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: v for k, v in receipt.items() if k != "rows"}))
    return 0 if accepted else (90 if failure or crawl.environment_failure or crawl.cleanup_failure or script_errors else 1)


if __name__ == "__main__":
    raise SystemExit(main())
