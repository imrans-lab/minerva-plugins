use std::{
    fs,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[test]
#[ignore = "requires the official Godot 4.6.2 binary in SMART_REMOTE_GODOT"]
fn native_panel_controls_json_receipts_and_teardown() {
    let godot = std::env::var_os("SMART_REMOTE_GODOT").expect("SMART_REMOTE_GODOT");
    let project = tempfile::tempdir().unwrap();
    fs::create_dir(project.path().join("ui")).unwrap();
    fs::write(
        project.path().join("project.godot"),
        "[application]\nconfig/name=\"Pairing panel public fixture\"\n",
    )
    .unwrap();
    fs::write(
        project.path().join("ui/PairingPanel.tscn"),
        include_str!("../ui/PairingPanel.tscn"),
    )
    .unwrap();
    fs::write(
        project.path().join("ui/pairing_panel.gd"),
        include_str!("../ui/pairing_panel.gd"),
    )
    .unwrap();
    fs::write(project.path().join("fixture.gd"), FIXTURE).unwrap();
    let mut child = Command::new(godot)
        .args(["--headless", "--path"])
        .arg(project.path())
        .args(["--script", "res://fixture.gd"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while child.try_wait().unwrap().is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    if child.try_wait().unwrap().is_none() {
        child.kill().unwrap();
    }
    let output = child.wait_with_output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success()
            && stdout.contains("PAIRING_PANEL_PASS")
            && !stderr.contains("ERROR"),
        "{stdout}\n{stderr}"
    );
}

const FIXTURE: &str = r#"extends SceneTree
class Gate:
	extends RefCounted
	signal settled(value: Dictionary)
class IPC:
	extends Node
	var pending: Dictionary = {}
	func await_reply(id: String, _timeout: int) -> Dictionary:
		var gate := Gate.new()
		pending[id] = gate
		var value: Dictionary = await gate.settled
		pending.erase(id)
		return value
	func reply(id: String, value: Dictionary) -> void:
		if pending.has(id):
			pending[id].settled.emit(value)
	func close_registration() -> void:
		for gate: Gate in pending.values().duplicate():
			gate.settled.emit({"success": false, "error_code": "panel_unloading"})
var failed: bool = false
var calls: Array[Dictionary] = []
var held: Array[Dictionary] = []
var operation: Dictionary = {}
var default_host: Variant = "192.0.2.1"
var next_id: int = 6
var hold_start: bool = false
var hold_poll: bool = false
var hold_apply: bool = false
func _initialize() -> void:
	_run.call_deferred()
func check(condition: bool, label: String) -> void:
	if not condition:
		failed = true
		printerr("ASSERT: " + label)
func ticks() -> void:
	for _i: int in range(3):
		await process_frame
func status(stage: String, id: int) -> Dictionary:
	return {"ok": true, "operation_id": id, "stage": "authenticating", "error": null,
		"pairing": {"stage": stage, "networks": [{"ssid": "_05ldA", "label": "Test network"}],
		"device_id": null, "host": null, "port": null, "error": null,
		"save_possible": false, "persistence": "none"}}
func envelope(body: Dictionary) -> Dictionary:
	# Exact scene envelope for a successful worker payload, including its ok marker.
	return JSON.parse_string(JSON.stringify({"success": true, "result": body}))
func receive(channel: String, payload: Dictionary, id: String, helper: IPC) -> void:
	check(channel == "minerva_smart_remote_pairing", "shared MCP verb")
	calls.append(payload.duplicate(true))
	var body: Dictionary
	var delayed: bool = false
	match str(payload.action):
		"describe":
			body = {"host": default_host, "port": 47821, "operation": operation.duplicate(true)}
			delayed = hold_poll
		"start":
			next_id += 1
			operation = status("scanning_wifi", next_id)
			body = operation.duplicate(true)
			delayed = hold_start
		"apply":
			operation = status("applying_wifi", int(payload.operation_id))
			operation.pairing.save_possible = true
			body = operation.duplicate(true)
			delayed = hold_apply
		"cancel":
			if int(payload.operation_id) != int(operation.get("operation_id", 0)):
				helper.reply(id, {"success": false, "error_code": "mcp_tool_error"})
				return
			operation = status("cancelled", int(payload.operation_id))
			operation.stage = "cancelled"
			body = operation.duplicate(true)
		_:
			check(false, "known action")
	if delayed:
		held.append({"id": id, "helper": helper, "body": body})
	else:
		helper.reply(id, envelope(body))
func release_one() -> void:
	var item: Dictionary = held.pop_front()
	item.helper.reply(item.id, envelope(item.body))
func panel() -> Control:
	var packed: PackedScene = load("res://ui/PairingPanel.tscn")
	var view: Control = packed.instantiate()
	var helper := IPC.new()
	helper.name = "_MinervaIPC"
	view.add_child(helper)
	view.connect("request", func(channel: String, payload: Dictionary, id: String) -> void:
		receive.call_deferred(channel, payload, id, helper))
	root.add_child(view)
	view.call("_on_panel_loaded", {})
	return view
func _run() -> void:
	var view: Control = panel()
	await ticks()
	var code: LineEdit = view.get_node("Code")
	var password: LineEdit = view.get_node("Password")
	var host: LineEdit = view.get_node("Host")
	var start: Button = view.get_node("Start")
	var apply: Button = view.get_node("Apply")
	var cancel: Button = view.get_node("Cancel")
	var notice: Label = view.get_node("Notice")
	var text: Label = view.get_node("Status")
	check(not code.secret and password.secret, "visible setup code and secret WiFi password")
	check(view.get_node_or_null("Name") == null, "code alone identifies the remote")
	check(not host.visible and host.text == "192.0.2.1", "automatic host hidden")
	check(notice.text.contains("doesn’t stop pairing"), "honest close notice")
	var before: int = calls.size()
	code.text = "12345x"
	code.text_submitted.emit(code.text)
	await ticks()
	check(calls.size() == before and text.text.contains("six-digit"), "invalid code stays local")
	code.text = "654321"
	hold_start = true
	code.text_submitted.emit(code.text)
	code.text_submitted.emit("654321")
	check(code.text.is_empty(), "code cleared before deferred IPC")
	check(not cancel.disabled, "cancel available before start receipt")
	cancel.pressed.emit()
	await ticks()
	check(calls.back().action == "start" and not calls.back().has("name") and calls.size() == before + 1, "Enter starts once with code alone; pending cancel retained")
	release_one()
	await ticks()
	check(calls.back().action == "cancel" and calls.back().operation_id == next_id, "cancel pending start")
	check(text.text.contains("cancelled"), "cancel receipt rendered")
	hold_start = false
	for empty: bool in [false, true]:
		operation = {} if empty else status("cancelled", next_id)
		hold_start = true
		hold_poll = true
		view.call("_poll")
		await ticks()
		code.text = "654321"
		start.pressed.emit()
		cancel.pressed.emit()
		await ticks()
		release_one() # Old describe arrives BEFORE the new Start receipt.
		await ticks()
		check(int(view.get("_operation")) == 0 and bool(view.get("_cancel_requested")), "old poll preserves unknown-ID cancellation")
		check(start.disabled and not cancel.disabled, "old poll preserves new-operation controls")
		release_one()
		await ticks()
		check(calls.back().action == "cancel" and calls.back().operation_id == next_id, "cancel targets NEW operation after old poll")
		check(operation.stage == "cancelled", "new operation actually cancelled")
		hold_start = false
		hold_poll = false
	hold_poll = true
	view.call("_poll")
	await ticks()
	code.text = "654321"
	start.pressed.emit()
	await ticks()
	check(not cancel.disabled and start.disabled, "active controls before stale startup poll")
	release_one()
	await ticks()
	check(not cancel.disabled and start.disabled, "stale poll cannot change active controls")
	hold_poll = false
	operation = status("awaiting_wifi", next_id + 1)
	view.call("_render", JSON.parse_string(JSON.stringify(operation)))
	var networks: OptionButton = view.get_node("Networks")
	check(networks.item_count == 1 and networks.get_item_metadata(0) == "_05ldA", "raw SSID selection")
	password.text = "public-fixture-password"
	hold_apply = true
	apply.pressed.emit()
	check(password.text.is_empty(), "password cleared before deferred IPC")
	await ticks()
	check(calls.back().ssid == "_05ldA" and calls.back().port == 47821, "SSID bytes and JSON integer port")
	check(calls.back().host == "192.0.2.1", "actual default used")
	cancel.pressed.emit()
	await ticks()
	var cancelled_text: String = text.text
	release_one()
	await ticks()
	check(text.text == cancelled_text, "stale apply receipt ignored")
	hold_apply = false
	hold_poll = true
	view.call("_poll")
	await ticks()
	cancel.pressed.emit()
	await ticks()
	cancelled_text = text.text
	release_one()
	await ticks()
	check(text.text == cancelled_text, "cancel while poll pending and stale poll ignored")
	hold_poll = false
	var good: Dictionary = status("awaiting_wifi", next_id + 2)
	good.pairing.error = "wrong_password"
	view.call("_render", JSON.parse_string(JSON.stringify(good)))
	check(text.text.contains("Wrong WiFi password"), "password failure label")
	good.pairing.error = "network_not_found"
	view.call("_render", JSON.parse_string(JSON.stringify(good)))
	check(text.text.contains("network not found"), "network failure label")
	good.pairing.error = null
	good.pairing.host = "192.0.2.99"
	good.pairing.port = 45678
	good.pairing.device_id = "aabbccddeeff"
	view.call("_render", JSON.parse_string(JSON.stringify(good)))
	check(host.text == "192.0.2.99" and not host.editable, "staged address restored")
	for bad_port: Variant in [45678.5, 0, 65536, "45678"]:
		good.pairing.port = bad_port
		view.call("_render", JSON.parse_string(JSON.stringify(good)))
		check(text.text == "Invalid staged port." and apply.disabled, "invalid JSON staged port refused")
		check(int(view.get("_port")) == 45678, "staged port is not truncated or replaced")
	good.pairing.port = 45678
	good.pairing.persistence = "pending"
	view.call("_render", envelope(good).result)
	check(text.text.contains("Saving pairing") and start.disabled, "pending store ownership")
	good.pairing.persistence = "stored"
	good.pairing.stage = ""
	good.stage = "cancelled"
	good.error = "cancelled"
	view.call("_render", envelope(good).result)
	check(text.text.contains("saved, not yet confirmed"), "saved cancelled operation")
	good.pairing.stage = "confirmed"
	view.call("_render", envelope(good).result)
	check(text.text.contains("Paired and connected"), "late confirmation")
	good.pairing.persistence = "none"
	good.pairing.stage = ""
	good.stage = "failed"
	good.error = "transport"
	good.pairing.save_possible = true
	view.call("_render", envelope(good).result)
	check(text.text.contains("confirmation is unknown"), "uncertain device save")
	good.error = "not_found"
	view.call("_render", envelope(good).result)
	check(text.text.contains("No remote in setup"), "remote absent label")
	good.error = "input_timeout"
	good.pairing.save_possible = false
	view.call("_render", envelope(good).result)
	check(text.text.contains("Timed out waiting for input"), "input expiry label")
	var remembered: String = text.text
	view.call("_render", envelope(status("scanning", 1)).result)
	check(text.text == remembered, "stale operation ID ignored")
	good.operation_id = 10.5
	view.call("_render", envelope(good).result)
	check(text.text == "Invalid pairing operation.", "fractional JSON ID rejected")
	code.text = "654321"
	password.text = "public-fixture-password"
	check(view.call("_on_panel_save_request", {}).is_empty(), "save none")
	view.call("_on_panel_load_request", {"code": "654321", "password": "public-fixture-password"})
	check(code.text.is_empty() and password.text.is_empty(), "restore cannot populate secrets")
	hold_start = true
	code.text = "654321"
	start.pressed.emit()
	await ticks()
	var count: int = calls.size()
	view.call("_on_panel_unload")
	view.get_node("_MinervaIPC").call("close_registration")
	await ticks()
	check(calls.size() == count, "unload emits no rejected IPC")
	check(code.text.is_empty() and password.text.is_empty() and view.get_node("Poll").is_stopped(), "unload clears fields and timer")
	release_one()
	await ticks()
	view.queue_free()
	default_host = null
	hold_start = false
	var reopened: Control = panel()
	await ticks()
	check(reopened.get_node("Host").visible, "optional host without default")
	check(int(reopened.get("_operation")) == next_id, "reopen recovers unknown start ID")
	reopened.get_node("Cancel").pressed.emit()
	await ticks()
	check(calls.back().action == "cancel" and calls.back().operation_id == next_id, "reopened working cancel")
	reopened.call("_on_panel_unload")
	reopened.queue_free()
	await ticks()
	if not failed:
		print("PAIRING_PANEL_PASS: controls, JSON, pending cancellation, stale replies, saved state, close/reopen")
	quit(1 if failed else 0)
"#;
