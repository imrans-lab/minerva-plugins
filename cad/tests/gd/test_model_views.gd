extends "test_eval_await.gd"
const EXPORT_ADAPTER_PATH := "res://Scripts/Services/MCP/Modules/MCPCadEvaluation.gd"

func _run() -> void:
	_document_path = OS.get_user_data_dir().path_join("cad_model_views.mcad")
	var rig := _make_rig("cad_model_views")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	_attach_document(rig, SOURCE)
	var answer := _worker_answer()
	answer.result["model"] = {"configuration": "assembled", "selection": "", "physical": true,
		"configurations": [{"name": "assembled", "physical": true}, {"name": "exploded", "physical": false}]}
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	var listed: Dictionary = await PanelTools.handle(panel, "minerva_cad_model", {})
	check("model lists completed configurations", listed.model.configurations.size() == 2, str(listed))
	var menu: OptionButton = panel.get_node("ResponsiveContainer/WideLayout/WideSidebar/BuildControls/Configuration")
	check("human menu shares the completed configuration list", menu.item_count == 3, str(menu.item_count))
	menu.item_selected.emit(2)
	var dispatch: Dictionary = _evaluations(rig.dispatched)[-1].payload
	check("human configuration switch selects cached source without rewriting", dispatch.source == SOURCE
		and dispatch.configuration == "exploded" and rig.buffer.text == SOURCE, str(dispatch))
	answer.result.model.configuration = "exploded"
	answer.result.model.physical = false
	answer.result["provenance"] = {"configuration": "exploded", "selection": ""}
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	var refused: Dictionary = await PanelTools.handle(panel, "minerva_cad_check_design", {"required_mm": 1})
	check("presentation configuration cannot pass physical validation", not refused.checked
		and refused.reason.contains("Presentation-only"), str(refused))
	var export_args: Dictionary = load(EXPORT_ADAPTER_PATH).export_document_args({"_evaluated_document": panel.get_evaluation_state(),
		"format": "step", "path": "/tmp/assembly.step"})
	check("host exports the displayed configuration by default", export_args.configuration == "exploded"
		and export_args.source == SOURCE, str(export_args))
	var explicitly_selected: Dictionary = load(EXPORT_ADAPTER_PATH).export_document_args({"_evaluated_document": panel.get_evaluation_state(),
		"format": "step", "path": "/tmp/assembly.step", "selection": "instance:left", "configuration": "assembled"})
	check("host preserves explicit export selection and configuration", explicitly_selected.configuration == "assembled"
		and explicitly_selected.selection == "instance:left", str(explicitly_selected))
	await PanelTools.handle(panel, "minerva_cad_build", {"action": "set_mode", "mode": "manual"})
	rig.buffer.apply_edit(EDITED_SOURCE)
	var before := _evaluations(rig.dispatched).size()
	var chosen: Dictionary = await PanelTools.handle(panel, "minerva_cad_model", {"action": "show", "configuration": "assembled"})
	check("choosing a configuration preserves the manual build boundary", chosen.build_required
		and _evaluations(rig.dispatched).size() == before and rig.buffer.text == EDITED_SOURCE, str(chosen))
	panel.build_latest()
	dispatch = _evaluations(rig.dispatched)[-1].payload
	check("next explicit build uses the selected configuration", dispatch.source == EDITED_SOURCE
		and dispatch.configuration == "assembled", str(dispatch))
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	_teardown(rig)
