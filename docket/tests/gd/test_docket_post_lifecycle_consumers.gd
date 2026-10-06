extends "res://../../minerva-plugins/docket/tests/gd/test_docket_lifecycle.gd"
## Hosted consumers against the signed child, sharing the actual install/restart fixture.
var policy_answers := 0
var approve_policy := false
var skill_id := ""
var trigger_manager
var master_records: Array[Dictionary] = []
const PROMPT_KEY := "consumer-oracle"
const PROMPT_TEXT := "Use the restored fixture project."

func install_fixture(manifest_path: String) -> Dictionary:
	if not check("consumer oracle has a display for real policy approval", DisplayServer.get_name() != "headless"):
		return {"ok": false, "error": "set MINERVA_TEST_DISPLAY=1 and provide a display"}
	var singleton = root.get_node("SingletonObject")
	singleton.plugin_manager = pm
	singleton.plugin_event_broker = load("res://Scripts/Services/Plugins/PluginEventBroker.gd").new(pm.get_db(), pm.get_audit_log())
	root.child_entered_tree.connect(_policy_dialog)
	return reuse_fixture(manifest_path)

func expected_prepare_approvals() -> int:
	return 0

func lifecycle_project_path() -> String:
	return state.path_join("consumers.dct")

func _policy_dialog(node: Node) -> void:
	if node is ConfirmationDialog and node.title == "Policy Modification — Human Approval Required":
		_answer_policy.call_deferred(node)

func _answer_policy(dialog: ConfirmationDialog) -> void:
	await process_frame
	policy_answers += 1
	if approve_policy:
		dialog.confirmed.emit()
	else:
		dialog.canceled.emit()

func exercise_consumers(project: String) -> void:
	var singleton = root.get_node("SingletonObject")
	check("C1 focuses the actual upstream child", (await singleton.open_docket_panel(lifecycle_project_path())).get("ok", false))
	var master: String = str(host.master_project().name)
	var rule := {"effect": "block", "priority": 10, "tool_pattern": "^minerva_tool_search$"}
	var policy := await call_mapped("docket_create", {"project": master, "type": "policy", "title": "Fixture search policy",
		"description": "---policy-rule---\n" + JSON.stringify(rule) + "\n---end-rule---"})
	for status in ["proposed", "active"]:
		await call_mapped("docket_transition", {"project": master, "id": policy.id, "to": status})
	var server = singleton.get_mcp_manager().minerva_server
	var blocked: Dictionary = await server.call_tool("minerva_tool_search", {"query": "docket"})
	check("real master policy blocks governed dispatch", not blocked.get("success", true) and blocked.get("blocked_by_rule", "") == policy.id)
	var retire := {"project": master, "id": policy.id, "to": "archived"}
	var denied: Dictionary = await registry.handle_tool_call("minerva_docket_transition", retire)
	var unchanged := await call_mapped("docket_get", {"project": master, "id": policy.id})
	check("real approval denial keeps policy active", policy_answers == 1 and not denied.get("success", true) and unchanged.status == "active")
	approve_policy = true
	await call_mapped("docket_transition", retire)
	var allowed: Dictionary = await server.call_tool("minerva_tool_search", {"query": "docket"})
	check("real approval permits retirement and dispatch", policy_answers == 2 and allowed.get("success", false))
	var definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new("consumer-oracle")
	definition.skills.assign([{"id": "consumer_proof", "title": "Consumer proof", "steps": "fixture-step", "tool_deps": []}])
	var seeded: Dictionary = await load("res://Scripts/Services/Plugins/PluginContentSeeding.gd").seed_install(pm, definition, true, {})
	check("real host settles one seeded skill", seeded.get("skills_seeded", 0) == 1 and not seeded.has("content_incomplete"))
	var skills := await call_mapped("docket_query", {"project": master, "filter": {"conditions": [{"field": "source", "op": "eq", "value": "plugin:consumer-oracle"}]}, "detail": "full"})
	check("seeded skill reaches the actual master", skills.get("items", []).size() == 1 and skills.items[0].steps == "fixture-step")
	if skills.get("items", []).size() == 1:
		skill_id = str(skills.items[0].id)
	var prompt := await call_mapped("docket_create", {"project": project, "type": "prompt", "title": "Consumer prompt",
		"key": PROMPT_KEY, "component": "system-prompt", "fields": {"prompt_text": PROMPT_TEXT}})
	await call_mapped("docket_transition", {"project": project, "id": prompt.id, "to": "active"})
	check("real session prompt is readable", (await host.system_prompt(PROMPT_KEY)).get("prompt", "") == PROMPT_TEXT)
	trigger_manager = load("res://../../minerva-plugins/docket/tests/gd/consumer_trigger_recorder.gd").new()
	root.add_child(trigger_manager)
	var trigger = load("res://Scripts/Services/Agents/TriggerDefinition.gd").new()
	trigger.id = "consumer-trigger"
	trigger.name = "Consumer trigger"
	trigger.enabled = true
	trigger.trigger_type = trigger.TriggerType.DOCKET_POLL
	trigger.docket_project = project
	trigger_manager.add_trigger(trigger)
	var created := await call_mapped("docket_create", {"project": project, "type": "kb", "title": "Consumer event"})
	var deadline := Time.get_ticks_msec() + 10000
	while trigger_manager.delivered.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	check("actual item_changed reaches the trigger consumer", trigger_manager.delivered.size() == 1 and str(trigger_manager.delivered[0].get("text", "")).contains(created.id))
	check("event stream remains reliable", trigger_manager.docket_feed.status(trigger.id).get("problem", "").is_empty())
	trigger_manager.remove_trigger(trigger.id)

func stop() -> void:
	await super.stop()
	master_records = _master_records()

func _master_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for line in FileAccess.get_file_as_string(host.master_path).split("\n", false):
		var row = JSON.parse_string(line)
		if not row is Dictionary:
			check("canonical master contains valid JSON records", false)
			return []
		records.append(row)
	return records

func master_survives_restart() -> bool:
	# Bootstrap and ordinary writes order JSON object keys differently. Compare
	# every record, including metadata/history, retaining record order and count.
	return not master_records.is_empty() and _master_records() == master_records

func check_restored_consumers(_project: String) -> void:
	check("prompt survives real child/session restart", (await host.system_prompt(PROMPT_KEY)).get("prompt", "") == PROMPT_TEXT)
	var skill := await call_mapped("docket_get", {"project": str(host.master_project().name), "id": skill_id})
	check("seeded skill survives real child restart", skill.get("source", "") == "plugin:consumer-oracle" and skill.get("steps", "") == "fixture-step")
	print("REAL_DOCKET_CONSUMERS_COMPLETE")
