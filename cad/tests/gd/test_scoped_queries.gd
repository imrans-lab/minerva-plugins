extends "test_eval_await.gd"

func _run() -> void:
	_document_path = OS.get_user_data_dir().path_join("cad_scoped_queries.mcad")
	var rig := _make_rig("cad_scoped_queries")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	_attach_document(rig, SOURCE)
	var answer := _worker_answer()
	answer.result["model"] = {"configuration": "exploded", "selection": "", "physical": false}
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	panel.request.connect(_answer_query.bind(rig))
	var before: Dictionary = panel.get_evaluation_state().duplicate(true)
	var reply: Dictionary = await PanelTools.handle(panel, "minerva_cad_material", {
		"configuration": "assembled", "selection": "instance:post", "at_mm": [0,0,0]})
	check("inactive physical configuration reaches the shared worker selector", reply.get("success", false) and reply.get("checked", false)
		and reply.get("model_scope", {}).get("configuration") == "assembled", str(reply))
	check("query provenance names selected geometry", reply.get("provenance", {}).get("selection") == "instance:post", str(reply))
	check("private query preserves source and displayed configuration", rig.buffer.text == SOURCE
		and panel.get_evaluation_state() == before, str(panel.get_evaluation_state()))
	check("finished query releases its context", panel.get_meta("cad_query_contexts", {}).is_empty(), str(reply))
	var unknown: Dictionary = await PanelTools.handle(panel, "minerva_cad_references", {"selection": "missing"})
	check("unknown selector is an explicit failure", unknown.get("error_code") == "selection_failed", str(unknown))
	var refused: Dictionary = await PanelTools.handle(panel, "minerva_cad_check_interference", {
		"configuration": "presentation", "selection": "binding:post"})
	check("alternate presentation configuration cannot earn a physical verdict", not refused.get("checked", true)
		and refused.get("error_code") == "configuration_context", str(refused))
	var calls: Array = rig.dispatched.filter(func(entry): return entry.channel == "cad.material")
	check("measurement keeps source bytes and selection together", calls.size() == 1 and calls[0].payload.source == SOURCE
		and calls[0].payload.selection == "instance:post" and calls[0].payload.configuration == "assembled", str(calls))
	var inspected: Dictionary = await PanelTools.handle(panel, "minerva_cad_model", {
		"action": "inspect", "selection": "instance:post", "configuration": "assembled"})
	check("object inspection preserves active view and identifies its selection", inspected.get("success", false)
		and inspected.get("model", {}).get("selection") == "instance:post" and panel.get_evaluation_state() == before, str(inspected))
	var scopes := preload("../../ui/scripts/scoped_queries.gd")
	var waiting: Dictionary = await scopes.run(panel, "minerva_cad_check_clearance", {
		"configuration": "assembled", "selection": "instance:post", "_evaluated_document": before}, _ticket_dispatch)
	check("pending job retains its private context", str(waiting.get("ticket", "")).begins_with("context:")
		and panel.get_meta("cad_query_contexts", {}).size() == 1, str(waiting))
	var collected: Dictionary = await scopes.run(panel, "minerva_cad_check_clearance", {"ticket": waiting.ticket}, _ticket_dispatch)
	check("ticket collection uses the original context and releases it", collected.get("checked", false)
		and collected.get("unwrapped", "") == "clearance1" and panel.get_meta("cad_query_contexts", {}).is_empty(), str(collected))
	await process_frame
	_teardown(rig)

func _ticket_dispatch(_panel: Node, _tool: String, args: Dictionary) -> Dictionary:
	if args.has("ticket"):
		return {"checked": true, "status": "done", "unwrapped": args.ticket}
	return {"checked": false, "status": "running", "ticket": "clearance1"}

func _answer_query(channel: String, payload: Dictionary, reply_id: String, rig: Dictionary) -> void:
	var answer := _worker_answer()
	if channel == "cad.evaluate":
		if payload.get("selection") == "missing":
			answer = {"ok": false, "error": {"kind": "translate", "message": "unknown selection 'missing'"}}
		else:
			answer.result["model"] = {"configuration": payload.get("configuration", ""),
				"selection": payload.get("selection", ""), "physical": payload.get("configuration") != "presentation"}
			answer.result["provenance"] = {"source_digest": SOURCE.sha256_text(),
				"selection": payload.get("selection", ""), "configuration": payload.get("configuration", "")}
	elif channel == "cad.material":
		answer = {"ok": true, "result": {"points": [{"inside": true}], "units": "mm"}}
	else:
		return
	_reply.call_deferred(rig, reply_id, answer)
