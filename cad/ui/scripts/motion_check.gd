extends RefCounted
## Reuse the completed document and shared freshness/scope gates for path checks.
const Reply := preload("worker_reply.gd")
const Evaluation := preload("evaluation_state.gd")

static func check_path(panel: Object, args: Dictionary) -> Dictionary:
	var document: Dictionary = Evaluation.document(panel, args)
	var request := {"source": document.get("source", "")}
	for key in ["selection", "configuration", "against", "path_mm", "required_mm", "numeric_tolerance_mm", "max_samples"]:
		if args.has(key):
			request[key] = args[key]
	var envelope: Dictionary
	if panel.has_method("call_backend_until"):
		envelope = await panel.call_backend_until("cad.motion", request, 60000, 600000)
	else:
		envelope = await panel.call_backend("cad.motion", request, 120000)
	var result := Reply.unwrap(envelope, "motion")
	if result.has("error"):
		return {"success": false, "checked": false, "pass": null, "error": result.error}
	result["success"] = true
	return result
