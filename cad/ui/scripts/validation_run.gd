extends RefCounted
## One bounded validation job per document, using the ordinary panel tool path.
const Spec := preload("validation_spec.gd")
const Report := preload("validation_report.gd")
const Freshness := preload("eval_freshness.gd")
const Evaluation := preload("evaluation_state.gd")
const META := "cad_validation_run"
const MAX_MS := 900000

static func handle(panel: Node, args: Dictionary, dispatch: Callable) -> Dictionary:
	var action := str(args.get("action", "run"))
	if action == "report":
		var loaded := Report.read(str(args.get("report_path", "")), str(args.get("sha256", "")))
		if loaded.has("error"):
			return {"success": false, "error": loaded.error}
		if str(args.get("detail", "")) == "full":
			return {"success": true, "report": loaded.report, "evidence": loaded.artifact, "historical": true,
				"source_version": loaded.report.get("document", {}).get("source_version", -1),
				"provenance": loaded.report.get("document", {}).get("provenance", {})}
		var summary := Report.summarize(loaded.report, loaded.artifact)
		summary["historical"] = true
		return summary
	var job: Dictionary = panel.get_meta(META, {})
	if action in ["collect", "cancel"]:
		if job.is_empty() or str(args.get("ticket", "")) != str(job.ticket):
			return {"success": false, "error": "Unknown validation ticket for this document"}
		if action == "cancel":
			job["cancelled"] = true
		return await _wait(panel, job, args)
	if action not in ["run", "inspect"]:
		return {"success": false, "error": "action must be run, inspect, collect, cancel or report"}
	var before := Evaluation.preflight(panel, args, true)
	if not before.get("success", false):
		return before
	var path := str(args.get("path", ""))
	var document_path := str(before.document.get("path", ""))
	if path.is_empty():
		if document_path.is_empty():
			return {"success": false, "error": "Supply a specification path for an unsaved CAD document"}
		path = document_path + ".checks.json"
	elif not path.is_absolute_path():
		path = document_path.get_base_dir().path_join(path).simplify_path()
	var loaded := Spec.new().read(path)
	if loaded.has("error"):
		return {"success": false, "error": loaded.error}
	if action == "inspect":
		return {"success": true, "specification": loaded.specification, "path": path, "sha256": loaded.digest}
	var key := JSON.stringify([loaded.digest, before.freshness]).sha256_text()
	if not job.is_empty() and (str(job.key) == key or job.reply.is_empty()):
		return await _wait(panel, job, args)
	job = {"key": key, "ticket": "validation-" + key.left(24), "started": Time.get_ticks_msec(),
		"completed_checks": 0, "total_checks": loaded.specification.checks.size(), "reply": {}, "cancelled": false}
	panel.set_meta(META, job)
	_execute(panel, job, loaded, before, dispatch)
	return await _wait(panel, job, args)

static func _wait(panel: Node, job: Dictionary, args: Dictionary) -> Dictionary:
	var deadline := Time.get_ticks_msec() + clampi(int(args.get("wait_ms", 1000)), 0, 20000)
	while job.reply.is_empty() and Time.get_ticks_msec() < deadline and is_instance_valid(panel):
		await panel.get_tree().process_frame
	if not job.reply.is_empty():
		return job.reply
	return {"success": true, "status": "running", "checked": false, "ticket": job.ticket,
		"completed_checks": job.completed_checks, "total_checks": job.total_checks}

static func _execute(panel: Node, job: Dictionary, loaded: Dictionary, before: Dictionary, dispatch: Callable) -> void:
	var document: Dictionary = before.document.duplicate()
	document.erase("mesh")
	var report := {"schema": Report.SCHEMA, "specification": {"path": loaded.path, "sha256": loaded.digest,
		"authored": loaded.specification}, "document": document, "checks": [], "stale": false}
	for check: Dictionary in loaded.specification.checks:
		if not is_instance_valid(panel):
			return
		panel.verify_dependencies()
		var current: Dictionary = panel.evaluation_freshness()
		var moved := Freshness.outrun("", before.freshness, current) or bool(current.get("stale", false))
		var result: Dictionary
		if moved or job.cancelled or Time.get_ticks_msec() - int(job.started) >= MAX_MS:
			result = {"checked": false, "reason": "Document changed" if moved else "Validation cancelled or timed out", "stale": moved}
		else:
			var requested: Dictionary = check.get("args", {}).duplicate(true)
			requested.merge({"selection": check.selection, "configuration": check.configuration,
				"require_source_digest": before.document.get("provenance", {}).get("source_digest", ""),
				"detail": "full", "wait_ms": 1000}, true)
			var tool: String = Spec.KINDS[check.kind]
			result = await dispatch.call(panel, tool, requested)
			while str(result.get("status", "")) in ["running", "pending"] and not str(result.get("ticket", "")).is_empty():
				if job.cancelled or Time.get_ticks_msec() - int(job.started) >= MAX_MS or not is_instance_valid(panel):
					break
				requested["ticket"] = result.ticket
				await panel.get_tree().create_timer(0.05).timeout
				result = await dispatch.call(panel, tool, requested)
		var row := check.duplicate(true)
		row["result"] = result
		row["verdict"] = Report.verdict(result)
		report.checks.append(row)
		report.stale = report.stale or result.get("stale", false)
		job.completed_checks += 1
	var artifact := Report.save(report)
	job.reply = {"success": false, "error": artifact.error} if artifact.has("error") else Report.summarize(report, artifact)
