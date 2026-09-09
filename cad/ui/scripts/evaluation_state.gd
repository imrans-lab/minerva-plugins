extends RefCounted
## Canonical source remains editable; completed holds only what actually painted.
var document_id := ""
var completed: Dictionary = {}
var _pending: Dictionary = {}

func capture(panel: Node, source: String, version: int) -> Dictionary:
	_pending = {"source": source, "path": panel._document_path,
		"document_id": document_id, "source_version": version}
	return _pending

func attach(payload: Dictionary) -> void:
	document_id = str(payload.get("document_id", ""))
	# Host open delivers the same source first through load, then buffer attach.
	# Bind that exact snapshot to its buffer without paying for another build.
	for snapshot in [_pending, completed]:
		if snapshot.is_empty() or not str(snapshot.get("document_id", "")).is_empty():
			continue
		if str(snapshot.get("source", "")) != str(payload.get("text", "")):
			continue
		var path: String = str(snapshot.get("path", ""))
		if not path.is_empty() and path != str(payload.get("path", "")):
			continue
		snapshot["document_id"] = document_id
		snapshot["source_version"] = int(payload.get("version", 0))
		if snapshot.has("provenance"):
			snapshot.provenance["document_id"] = document_id
			snapshot.provenance["source_version"] = snapshot.source_version

func painted(panel: Node, snapshot: Dictionary, result: Dictionary) -> void:
	completed = snapshot.duplicate(true)
	completed["mesh"] = result.get("mesh", {})
	completed["model"] = result.get("model", {})
	completed["dependencies"] = panel._dependencies.snapshot()
	completed["references"] = result.get("references", [])
	completed["last_eval"] = {"status": "ok", "shape_name": result.get("shape_name", "")}
	completed["evaluated_at"] = Time.get_unix_time_from_system()
	var metadata: Dictionary = result.get("provenance", {}).duplicate(true)
	metadata["source_digest"] = str(snapshot.source).sha256_text()
	metadata["source_version"] = snapshot.source_version
	metadata["document_id"] = snapshot.document_id
	metadata["reference_digest"] = str(panel.get_reference_digest()).sha256_text()
	completed["provenance"] = metadata

func freshness(panel: Node) -> Dictionary:
	var status: String = str(panel._last_eval_result.get("status", ""))
	var out := {
		"known": true,
		"buffer_version": panel._buffer_version,
		"source_version": int(completed.get("source_version", -1)),
		"evaluated_at": float(completed.get("evaluated_at", 0.0)),
		"document_id": document_id,
		"provenance": completed.get("provenance", {}).duplicate(true),
		"evaluation_status": status,
		"stale": false,
		"stale_reason": "",
	}
	if not out.provenance.is_empty():
		out.provenance["reference_digest"] = str(panel.get_reference_digest()).sha256_text()
	if panel._dependencies.is_stale():
		out["stale"] = true
		out["dependency_changes"] = panel._dependencies.changed_paths.duplicate()
		out["stale_reason"] = "Document path or imported dependencies changed. Build latest to update the displayed model."
		return out
	if panel._build.mode == "manual" and panel._build.state().build_required:
		out["stale"] = true
		out["stale_reason"] = "Source differs from the displayed model. Call minerva_cad_build with action=build_latest, then await evaluation."
		return out

	# A REFUSED EVALUATION IS A STALE PANEL. It painted nothing, so the
	# colliders are still the previous evaluation's while every version number
	# in the document has moved past them.
	if (status == "error" or status == "timeout") \
			and panel._eval_buffer_version > panel._painted_buffer_version:
		out["stale"] = true
		out["stale_reason"] = ("the evaluation of version %d %s (%s), so it "
			+ "painted nothing: the geometry standing now is the evaluation "
			+ "of version %d. Fix the document, then call "
			+ "minerva_cad_await_eval and ask again.") % [panel._eval_buffer_version,
			"failed" if status == "error" else "was given up on",
			str(panel._last_eval_result.get("error_kind", status)),
			panel._painted_buffer_version]
		return out
	# Nothing has ever been painted, so there is no evaluation for the
	# buffer to be ahead of; a check refuses such a panel on its own terms.
	if panel._painted_buffer_version >= 0 and panel._buffer_version > panel._painted_buffer_version:
		out["stale"] = true
		out["stale_reason"] = ("buffer newer than evaluation: the document is "
			+ "at version %d and the geometry on screen is the evaluation of "
			+ "version %d. Call minerva_cad_await_eval, then ask again.") 			% [panel._buffer_version, panel._painted_buffer_version]
		return out
	if not completed.is_empty() and str(completed.get("source", "")) != panel._current_source():
		out["stale"] = true
		out["stale_reason"] = "The current source differs from the completed model. Build latest and await evaluation."
		return out
	if panel._evaluation_is_unsettled():
		out["stale"] = true
		out["stale_reason"] = ("the evaluation of version %d has not been "
			+ "painted yet — it is queued behind the edit debounce or still "
			+ "with the worker, and the geometry standing now is the previous "
			+ "one. Call minerva_cad_await_eval, then ask again.") 			% panel._buffer_version
	return out


## Consumers receive one captured document for the whole operation. Text/note
## tools keep using get_document_state(), which always describes editable source.
static func document(panel: Object, args: Dictionary = {}) -> Dictionary:
	if args.has("_evaluated_document"):
		return args["_evaluated_document"]
	if panel.has_method("get_evaluation_state"):
		return panel.get_evaluation_state()
	return panel.get_document_state() if panel.has_method("get_document_state") else {}

static func preflight(panel: Node, args: Dictionary, require_current: bool) -> Dictionary:
	if require_current and panel.has_method("verify_dependencies"):
		panel.verify_dependencies()
	var freshness: Dictionary = panel.evaluation_freshness()
	var gate = preload("eval_freshness.gd")
	var error: String = gate.requirement_error(args, freshness)
	if not error.is_empty():
		return gate.stamp({"success": false, "checked": false,
			"error": error, "error_code": "evaluation_requirement"}, freshness)
	if require_current and freshness.get("stale", false) and not gate.accepts_stale(args):
		var refused: Dictionary = gate.refusal(freshness)
		refused["success"] = false
		return refused
	return {"success": true, "freshness": freshness, "document": document(panel)}

static func finish(panel: Node, reply: Dictionary, before: Dictionary) -> Dictionary:
	var gate = preload("eval_freshness.gd")
	var after: Dictionary = panel.evaluation_freshness()
	if gate.outrun("", before, after):
		return gate.stamp_moved(reply, before, after)
	return gate.stamp(reply, after)
