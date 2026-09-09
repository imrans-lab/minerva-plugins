extends "test_scoped_queries.gd"
const ValidationSpec := preload("../../ui/scripts/validation_spec.gd")
const ValidationReport := preload("../../ui/scripts/validation_report.gd")

func _run() -> void:
	_document_path = OS.get_user_data_dir().path_join("validation-run.mcad")
	var rig := _make_rig("validation_run")
	if rig.is_empty():
		return
	var panel: Node = rig.panel
	_attach_document(rig, SOURCE)
	var answer := _worker_answer()
	answer.result["model"] = {"configuration": "assembled", "selection": "", "physical": true}
	_reply(rig, str(_evaluations(rig.dispatched)[-1].reply_id), answer)
	await process_frame
	panel.request.connect(_answer_query.bind(rig))
	panel.request.connect(_answer_motion.bind(rig))
	var specification := {"schema": ValidationSpec.SCHEMA, "checks": [
		{"id": "missing", "kind": "interference", "selection": "missing", "configuration": "assembled", "args": {}},
		{"id": "unmeasured", "kind": "design", "selection": "instance:post", "configuration": "assembled", "args": {"required_mm": 1}},
		{"id": "presentation", "kind": "interference", "selection": "instance:post", "configuration": "presentation", "args": {}},
		{"id": "path", "kind": "motion", "selection": "instance:post", "configuration": "assembled",
			"args": {"against": ["instance:obstacle"], "path_mm": [[0,0,0],[10,0,0]], "max_samples": 2}}]}
	# The authored artifact crosses JSON: numbers become floats on read.
	specification = JSON.parse_string(JSON.stringify(specification))
	var path := _document_path + ".checks.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(specification))
	file.close()
	var inspected: Dictionary = await PanelTools.handle(panel, "minerva_cad_validation", {"action": "inspect"})
	check("reopened specification validates against shipped tool schemas", inspected.get("success", false)
		and inspected.specification.checks.size() == 4, str(inspected))
	var started: Dictionary = await PanelTools.handle(panel, "minerva_cad_validation", {"action": "run", "wait_ms": 0})
	check("validation returns an identified pending operation", started.get("status") == "running"
		and str(started.get("ticket", "")).begins_with("validation-"), str(started))
	var finished: Dictionary = await PanelTools.handle(panel, "minerva_cad_validation", {
		"action": "collect", "ticket": started.ticket, "wait_ms": 5000})
	check("missing, unmeasured and presentation-only checks remain unknown", finished.get("status") == "completed"
		and finished.get("counts", {}).get("unknown") == 4 and finished.get("verdict") == "unknown", str(finished))
	var evidence: Dictionary = await PanelTools.handle(panel, "minerva_cad_validation", {
		"action": "report", "report_path": finished.evidence.path, "sha256": finished.evidence.sha256, "detail": "full"})
	check("evidence retains requirements, targets and source without duplicating mesh arrays", evidence.get("success", false)
		and evidence.report.specification.authored == specification and evidence.report.document.source == SOURCE
		and not evidence.report.document.has("mesh"), str(evidence.keys()))
	check("full design evidence retains engine outcomes", evidence.report.checks[1].result.has("evidence")
		and evidence.report.checks[1].result.evidence.has("interference"), str(evidence.report.checks[1]))
	check("validation leaves source and requirements untouched", rig.buffer.text == SOURCE
		and JSON.parse_string(FileAccess.get_file_as_string(path)) == specification, str(rig.buffer.text))
	var malformed: Dictionary = specification.duplicate(true)
	malformed.checks[1].args = {"required_mmm": 1}
	check("misspelled requirements fail before measuring", ValidationSpec.new().validate(malformed).contains("required_mmm"), str(malformed))
	check("evidence tampering is explicit", ValidationReport.read(finished.evidence.path, "incorrect").has("error"), str(finished.evidence))
	check("report grades retain certified passes and withhold uncertain evidence", ValidationReport.verdict({"checked": true, "pass": true}) == "pass"
		and ValidationReport.verdict({"checked": false, "pass": true}) == "unknown"
		and ValidationReport.verdict({"checked": true, "pass": false, "tolerance_bounded": false}) == "unknown", "verdict policy")
	var mismatch: Dictionary = await PanelTools.handle(panel, "minerva_cad_snapshot_posed", {
		"selection": "instance:post", "configuration": "assembled", "require_reference_digest": "different"})
	check("a reproduced view refuses mismatched imported evidence", mismatch.get("error_code") == "evidence_mismatch", str(mismatch))
	var motion_calls: Array = rig.dispatched.filter(func(entry): return entry.channel == "cad.motion")
	check("motion requirements cross the host bridge with canonical source and scope",
			motion_calls.size() == 1 and motion_calls[0].payload.source == SOURCE
			and motion_calls[0].payload.selection == "instance:post"
			and motion_calls[0].payload.against == ["instance:obstacle"]
			and motion_calls[0].payload.max_samples == 2, str(motion_calls))
	await process_frame
	_teardown(rig)


func _answer_motion(channel: String, _payload: Dictionary, reply_id: String, rig: Dictionary) -> void:
	if channel == "cad.motion":
		_reply.call_deferred(rig, reply_id, {"ok": true, "result": {
			"checked": true, "pass": null, "verdict": "unknown", "samples": 2,
			"unmeasured_intervals": [{"segment": 0}]}})
