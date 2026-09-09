extends RefCounted
## Presentation choices over one completed source; never edits or forks that source.
var _owner: WeakRef
var configuration := ""
var selection := ""
const ROWS := preload("build_controls.gd").ROWS

func _init(panel: Node) -> void:
	_owner = weakref(panel)

func arguments() -> Dictionary:
	return {"configuration": configuration, "selection": selection}

func restore(value: Dictionary) -> void:
	configuration = str(value.get("configuration", ""))
	selection = str(value.get("selection", ""))

func wire() -> void:
	var panel: Node = _owner.get_ref()
	for path in ROWS:
		var row := panel.get_node_or_null(path)
		if row != null:
			var menu: OptionButton = row.get_node("Configuration")
			menu.item_selected.connect(func(index: int):
				handle({"action": "show", "configuration": menu.get_item_metadata(index)}))
	refresh()

func handle(args: Dictionary) -> Dictionary:
	var panel: Node = _owner.get_ref()
	var model: Dictionary = panel.get_evaluation_state().get("model", {})
	if str(args.get("action", "list")) == "list":
		return {"success": true, "model": model, "requested": arguments()}
	if str(args.get("action", "")) == "inspect":
		var read := preload("evaluation_state.gd")
		var before: Dictionary = read.preflight(panel, args, true)
		if not before.get("success", false):
			return before
		var request := {"source": before.document.get("source", ""), "summary": true,
			"selection": args.get("selection", model.get("selection", "")),
			"configuration": args.get("configuration", model.get("configuration", ""))}
		var inspected: Dictionary = preload("worker_reply.gd").unwrap(
			await panel.call_backend("cad.evaluate", request, 600000), "model inspection")
		inspected["success"] = not inspected.has("error")
		inspected["source_version"] = before.document.get("source_version", -1)
		inspected["document_id"] = before.document.get("document_id", "")
		inspected["evaluated_at"] = before.document.get("evaluated_at", 0.0)
		inspected["evaluation_status"] = before.freshness.get("evaluation_status", "")
		return read.finish(panel, inspected, before.freshness)
	if str(args.get("action", "")) != "show":
		return {"success": false, "error": "action must be list, inspect or show"}
	panel.verify_dependencies()
	var next := str(args.get("configuration", ""))
	if not next.is_empty():
		var found := false
		for candidate: Dictionary in model.get("configurations", []):
			found = found or str(candidate.name) == next
		if not found:
			return {"success": false, "error": "Unknown configuration: " + next}
	configuration = next
	selection = str(args.get("selection", ""))
	# Manual editing keeps its build boundary: choosing a view does not compile
	# newer source behind the user's back. Build latest will use the choice.
	var requires_build: bool = panel.build_status().build_required
	if not requires_build:
		panel._evaluate_with_request_id(panel.get_evaluation_state().get("source", ""))
	refresh()
	return {"success": true, "requested": arguments(), "build_required": requires_build}

func refresh() -> void:
	var panel: Node = _owner.get_ref()
	var model: Dictionary = panel.get_evaluation_state().get("model", {})
	for path in ROWS:
		var row := panel.get_node_or_null(path)
		if row == null:
			continue
		var menu: OptionButton = row.get_node("Configuration")
		menu.clear()
		menu.add_item("Source view")
		menu.set_item_metadata(0, "")
		for value: Dictionary in model.get("configurations", []):
			var label := str(value.name)
			if not bool(value.get("physical", true)):
				label += " (presentation)"
			menu.add_item(label)
			var index := menu.item_count - 1
			menu.set_item_metadata(index, str(value.name))
			if str(value.name) == configuration:
				menu.select(index)
		menu.visible = menu.item_count > 1


static func prepare_measurement(args: Dictionary, tool: String) -> String:
	if not tool in preload("eval_freshness.gd").MEASURING_VERBS or args.has("ticket"):
		return ""
	var document: Dictionary = args.get("_evaluated_document", {})
	var model: Dictionary = document.get("model", {})
	var active := str(model.get("configuration", ""))
	if not args.has("configuration"):
		args["configuration"] = active
	if not args.has("selection"):
		args["selection"] = str(model.get("selection", ""))
	if str(args.configuration) == active and tool.begins_with("minerva_cad_check_") and not bool(model.get("physical", true)):
		return "Presentation-only configuration cannot pass physical validation. Select a physical configuration."
	return ""
