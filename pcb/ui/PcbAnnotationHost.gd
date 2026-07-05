extends AnnotationHost
## AnnotationHost for the PCB plugin panel (walking-skeleton form).
##
## Produces v2 annotation envelopes that pass
## AnnotationV2Schema.validate_with_registry — the envelope shape is copied from
## the ONLY conformant reference host, Minerva core's TextEditorAnnotationHost
## (NOT CadAnnotationHost, which emits `payload` instead of `kind_payload`, omits
## lifecycle/visible_in_views/summary, and never validates — gap register C-32).
##
## Anchor type handled: pcb/board.point
##   anchor.id                 = {x: mm, y: mm}   (board millimetres)
##   anchor.snapshot.position  = [x_mm, y_mm]
##
## Sidecar file: <board_path>.annotations.json (via core AnnotationSidecar).
##
## Off-tree note: lives at C:/github/minerva-plugins/pcb/ui/, OUTSIDE Minerva's
## res:// tree. It MUST NOT declare a class_name (plugin-local class_names are
## unresolvable off-tree). Extends the core AnnotationHost class (which IS in
## res:// and resolvable). Loaded via preload()/load() by PCBPanel.gd and tests.

signal annotations_changed()

const _ANN_ID_PREFIX := "ann_"
const _ANCHOR_TYPE := "pcb/board.point"
const _SCHEMA := preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const _PcbRouteHintKindScript: Script = preload("kinds/pcb_route_hint_kind.gd")

## Storage: Array of v2 envelope Dictionaries.
var _annotations: Array = []

## Monotonic id counter for generated envelope ids.
var _id_counter: int = 0

## Per-host kind registry (built-in kinds + pcb_route_hint).
var _registry: AnnotationRegistry = null

## Board document path (for sidecar resolution). Empty for anonymous editors.
var _document_path: String = ""


func _init() -> void:
	super._init()
	register_anchor_resolver(_ANCHOR_TYPE, Callable(self, "_resolve_board_point"))
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)
	_registry.register_annotation_kind(_PcbRouteHintKindScript.new())


# ── AnnotationHost overrides ──────────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


func get_capabilities() -> Dictionary:
	return {
		"kinds": ["pcb_route_hint"],
		"tools": ["select"],
		"anchor_types": [_ANCHOR_TYPE],
		"lifecycle": {
			"resolve": true,
			"reopen": true,
			"delete": true,
			"repair": false,
			"apply": false,
		},
		"authoring": {
			"add": true,
			"domain_pickers": false,
		},
		"panes": false,
		"body_views": false,
		"filters": ["all", "open", "applied", "resolved", "broken"],
	}


func get_document_identity() -> Dictionary:
	return {
		"kind": "pcb",
		"path": _document_path,
		"display_name": _document_path.get_file() if not _document_path.is_empty() else "PCB",
		"save_policy": "sidecar",
	}


func get_view_context() -> String:
	# Walking skeleton: one flat "pcb" context. Layer-aware "pcb:F.Cu" sub-context
	# is a platform gap (register C-23) deferred to a later round.
	return "pcb"


func set_document_path(path: String) -> void:
	_document_path = path


# ── Envelope authoring (conformant v2, TextEditorAnnotationHost pattern) ──────

## Add a v2 envelope. Assigns an id if missing, validates against the registry,
## stores + emits. Returns the assigned id, or "" on validation failure.
func add_annotation_v2(envelope: Dictionary) -> String:
	var stored := envelope.duplicate(true)
	var ann_id: String = str(stored.get("id", ""))
	if ann_id.is_empty():
		_id_counter += 1
		ann_id = "%s%04x" % [_ANN_ID_PREFIX, _id_counter]
		stored["id"] = ann_id
	var schema = _SCHEMA.new()
	var result = schema.validate_with_registry(stored, _registry)
	if result.has_errors():
		push_warning("[PcbAnnotationHost] add_annotation_v2: validation errors: %s" % str(result.to_error_dicts()))
		return ""
	_annotations.append(stored)
	annotations_changed.emit()
	return ann_id


## Base-API alias so callers using AnnotationHost.add_annotation() work.
func add_annotation(annotation: Dictionary) -> String:
	return add_annotation_v2(annotation)


## Build + store a conformant pcb_route_hint envelope at a board point.
## x_mm/y_mm are board millimetres. Returns the assigned id, or "" on failure.
func add_route_hint_at(
		x_mm: float,
		y_mm: float,
		text: String = "",
		layer: String = "F.Cu",
		hint_type: String = "waypoint",
		waypoints: Array = [],
		author_kind: String = "human") -> String:
	if author_kind != "ai":
		author_kind = "human"
	var now := int(Time.get_unix_time_from_system())
	var summary_text := "Route hint (%s, %s)" % [hint_type, layer]
	if not text.is_empty():
		summary_text = "%s: %s" % [summary_text, text]
	var envelope := {
		"id": "",
		"kind": "pcb_route_hint",
		"schema_version": 2,
		"anchor": {
			"plugin": "pcb",
			"type": "board.point",
			"id": {"x": x_mm, "y": y_mm},
			"snapshot": {
				"position": [x_mm, y_mm],
			},
		},
		"kind_payload": {
			"hint_type": hint_type,
			"layer": layer,
			"text": text,
			"waypoints": waypoints,
		},
		"lifecycle": "open",
		"author": {"kind": author_kind},
		"view_context": "pcb",
		"visible_in_views": ["all"],
		"summary": summary_text,
		"created_at": now,
		"updated_at": now,
	}
	return add_annotation_v2(envelope)


# ── Store adapters (used by MCPAnnotationTools) ───────────────────────────────

func get_annotations() -> Array:
	return _annotations


func get_all_annotations() -> Array:
	return _annotations


func get_all() -> Array:
	return _annotations


func get_by_id(annotation_id: String) -> Dictionary:
	for ann in _annotations:
		if ann is Dictionary and str((ann as Dictionary).get("id", "")) == annotation_id:
			return (ann as Dictionary).duplicate(true)
	return {}


func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str(_annotations[i].get("id", "")) == annotation_id:
			var updated := new_annotation.duplicate(true)
			updated["id"] = annotation_id
			_annotations[i] = updated
			annotations_changed.emit()
			return true
	return false


func update(annotation: Dictionary) -> void:
	var annotation_id := str(annotation.get("id", ""))
	if not annotation_id.is_empty():
		update_annotation(annotation_id, annotation)


func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i] is Dictionary and str(_annotations[i].get("id", "")) == annotation_id:
			_annotations.remove_at(i)
			annotations_changed.emit()
			return true
	return false


func set_annotations(list: Array) -> void:
	_annotations = []
	for ann in list:
		if ann is Dictionary:
			_annotations.append((ann as Dictionary).duplicate(true))
	annotations_changed.emit()


# ── Anchor resolver ───────────────────────────────────────────────────────────

## Board points are static in the skeleton, so a route hint is never stale.
func _resolve_board_point(anchor: Dictionary) -> Dictionary:
	var pos := Vector2.ZERO
	var id: Variant = anchor.get("id", null)
	if id is Dictionary and (id as Dictionary).has("x") and (id as Dictionary).has("y"):
		pos = Vector2(float((id as Dictionary)["x"]), float((id as Dictionary)["y"]))
	else:
		var snap: Variant = anchor.get("snapshot", {})
		if snap is Dictionary:
			var p: Variant = (snap as Dictionary).get("position", [0, 0])
			if p is Array and (p as Array).size() >= 2:
				pos = Vector2(float((p as Array)[0]), float((p as Array)[1]))
	return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": false, "view_metadata": {}}


# ── Sidecar persistence (core AnnotationSidecar) ──────────────────────────────

## Write the current annotations to <path>.annotations.json. Zero annotations
## deletes the sidecar (AnnotationSidecar contract). Returns an Error code.
func save_sidecar(path: String) -> int:
	var schema = _SCHEMA.new()
	var serialized: Array = []
	for ann in _annotations:
		if ann is Dictionary:
			serialized.append(schema.serialize(ann as Dictionary))
	var data := {
		"substrate_version": 1,
		"document": {"path": path.get_file(), "kind": "pcbskel"},
		"annotations": serialized,
		"unknown_kinds": [],
	}
	return AnnotationSidecar.write_sidecar(path, data)


## Load annotations from <path>.annotations.json, replacing the current list.
## Missing sidecar is a no-op (leaves the list empty). Returns the count loaded.
func load_sidecar(path: String) -> int:
	var data := AnnotationSidecar.read_sidecar(path)
	if data.is_empty():
		return 0
	var raw: Array = data.get("annotations", [])
	var schema = _SCHEMA.new()
	_annotations = []
	var max_seq := 0
	for ann in raw:
		if not ann is Dictionary:
			continue
		var restored := schema.deserialize(ann as Dictionary)
		_annotations.append(restored)
		var ann_id := str(restored.get("id", ""))
		if ann_id.begins_with(_ANN_ID_PREFIX):
			var hex := ann_id.substr(_ANN_ID_PREFIX.length())
			if hex.is_valid_hex_number():
				max_seq = max(max_seq, hex.hex_to_int())
	if max_seq > _id_counter:
		_id_counter = max_seq
	annotations_changed.emit()
	return _annotations.size()
