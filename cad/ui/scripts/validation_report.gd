extends RefCounted
## Full evidence stays in a content-addressed file; decisions stay small on the wire.
const SCHEMA := "minerva.cad.validation-report/v1"

static func verdict(result: Dictionary) -> String:
	if result.get("stale", false) or not result.get("success", true) or not result.get("checked", true):
		return "unknown"
	if str(result.get("status", "")) in ["pending", "running"]:
		return "unknown"
	if result.has("verdict"):
		return str(result.verdict) if result.verdict in ["pass", "fail"] else "unknown"
	if not result.get("tolerance_bounded", true) or int(result.get("uncertified", 0)) > 0:
		return "unknown"
	if result.get("pass") is bool:
		return "pass" if result.pass else "fail"
	return "unknown"

static func save(report: Dictionary) -> Dictionary:
	var text := JSON.stringify(report, "\t", true)
	var digest := text.sha256_text()
	var directory := OS.get_user_data_dir().path_join("cad_validation")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"error": "Cannot create validation evidence directory"}
	var path := directory.path_join(digest + ".json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"error": "Cannot write validation evidence: " + path}
	file.store_string(text)
	file.flush()
	return {"path": path, "sha256": digest}

static func read(path: String, digest: String = "") -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 64 * 1024 * 1024:
		return {"error": "Cannot read validation evidence, or file exceeds 64 MiB"}
	var text := file.get_as_text()
	if not digest.is_empty() and text.sha256_text() != digest:
		return {"error": "Evidence digest mismatch"}
	var report = JSON.parse_string(text)
	if not report is Dictionary or report.get("schema") != SCHEMA:
		return {"error": "Not a CAD validation report"}
	if not report.get("checks") is Array or not report.get("document") is Dictionary:
		return {"error": "Malformed CAD validation report"}
	for row in report.checks:
		if not row is Dictionary or not row.get("id") is String or not row.get("kind") is String \
				or not row.get("result") is Dictionary or row.get("verdict") not in ["pass", "fail", "unknown"]:
			return {"error": "Malformed validation evidence row"}
	return {"report": report, "artifact": {"path": path, "sha256": text.sha256_text()}}

static func summarize(report: Dictionary, artifact: Dictionary) -> Dictionary:
	var counts := {"pass": 0, "fail": 0, "unknown": 0}
	var findings: Array = []
	for row: Dictionary in report.get("checks", []):
		var grade := str(row.get("verdict", "unknown"))
		counts[grade] += 1
		if grade == "pass":
			continue
		var result: Dictionary = row.get("result", {})
		findings.append({"id": row.id, "kind": row.kind, "verdict": grade,
			"selection": row.get("selection", ""), "configuration": row.get("configuration", ""),
			"reason": result.get("error", result.get("reason", result.get("pass_reason", result.get("notes", [])))),
			"measurements": _decision_fields(result),
			"view": view_hint(row, report.get("document", {}).get("provenance", {}))})
	var document: Dictionary = report.get("document", {})
	return {"success": true, "status": "completed", "units": "mm", "counts": counts,
		"verdict": "fail" if counts.fail > 0 else ("unknown" if counts.unknown > 0 or report.get("stale", false) else "pass"),
		"findings": findings, "evidence": artifact, "specification": report.get("specification", {}),
		"provenance": document.get("provenance", {}), "source_version": document.get("source_version", -1),
		"stale": report.get("stale", false)}

static func _decision_fields(result: Dictionary) -> Dictionary:
	var fields := ["required_mm", "min_mm", "bound_mm", "failing_rows", "uncertified",
		"tolerance_bounded", "coverage_limited", "reference", "node", "penetration_mm"]
	var out: Dictionary = {}
	for key in fields:
		if result.has(key):
			out[key] = result[key]
	for key in ["pairs", "clearance", "interference", "fasteners"]:
		var pairs = result.get(key, [])
		if not pairs is Array:
			continue
		for pair in pairs:
			if pair is Dictionary and not pair.get("pass", false):
				var closest: Dictionary = {}
				for field in fields:
					if pair.has(field):
						closest[field] = pair[field]
				if not closest.is_empty():
					out["first_finding"] = closest
					return out
	return out

static func view_hint(row: Dictionary, fallback: Dictionary) -> Dictionary:
	var provenance: Dictionary = row.get("result", {}).get("provenance", fallback)
	var args := {"selection": row.get("selection", ""), "configuration": row.get("configuration", ""),
		"view": "iso", "include_context": true, "require_source_digest": provenance.get("source_digest", "")}
	if not str(provenance.get("reference_digest", "")).is_empty():
		args["require_reference_digest"] = provenance.reference_digest
	var point := _location(row.get("result", {}))
	if point.size() == 3:
		args["fit"] = [[point[0]-5, point[1]-5, point[2]-5], [point[0]+5, point[1]+5, point[2]+5]]
	return {"tool": "minerva_cad_snapshot_posed", "args": args}

static func _location(value: Variant, depth: int = 0) -> Array:
	if depth > 12:
		return []
	if value is Dictionary:
		for key in ["solid_point_mm", "nearest_point_mm", "world"]:
			var point = value.get(key)
			if point is Array and point.size() == 3 and point.all(func(v): return v is float or v is int):
				return point
		for child in value.values():
			var point := _location(child, depth + 1)
			if not point.is_empty():
				return point
	elif value is Array:
		for child in value:
			var point := _location(child, depth + 1)
			if not point.is_empty():
				return point
	return []
