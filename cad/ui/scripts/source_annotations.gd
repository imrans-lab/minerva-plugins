extends RefCounted
## Translate worker records into derived Minerva annotation envelopes.
const _Schema := preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")

static func prepare(host: Object, records: Variant) -> Dictionary:
	if not records is Array or records.size() > 200:
		return {"error": "Expected at most 200 source annotations"}
	var result: Array = []
	var ids: Dictionary = {}
	var schema = _Schema.new()
	for record in records:
		if not record is Dictionary or str(record.get("id", "")).is_empty():
			return {"error": "Source annotation requires an ID"}
		var point: Variant = record.get("at_mm", [])
		if not point is Array or point.size() != 3 or ids.has(str(record.id)):
			return {"error": "Invalid point or duplicate source annotation ID"}
		ids[str(record.id)] = true
		var annotation: Dictionary = host._normalize_envelope({
			"id": "source:" + str(record.get("id", "")), "kind": "cad_source_annotation",
			"anchor": {"plugin": "cad", "type": "model_point", "id": record.get("id", ""),
				"point": point, "snapshot": {"position": [point[0], point[1]]}},
			"kind_payload": {"record": record.duplicate(true), "ownership": "source"},
			"author": {"kind": "ai"}, "summary": "Source annotation: " + str(record.get("id", "")),
		})
		var checked = schema.validate_with_registry(annotation, host._registry)
		if checked.has_errors():
			return {"error": str(checked.to_error_dicts())}
		result.append(annotation)
	return {"annotations": result}

static func resolve(anchor: Dictionary) -> Variant:
	var point: Variant = anchor.get("point", [])
	if not point is Array or point.size() != 3:
		return null
	return {"position": Vector3(point[0], point[1], point[2]), "stale": false}
