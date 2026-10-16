extends RefCounted
## Live solid inspection and edge annotations belong to the panel that owns them.
const EdgeAnchor := preload("CadEdgeAnchor.gd")
const TOOL_NAMES: Array[String] = [
	"minerva_cad_get_mesh_info", "minerva_cad_list_edges", "minerva_cad_get_edge",
	"minerva_cad_get_selected_edge", "minerva_cad_annotate_edges",
	"minerva_cad_clear_edge_annotations", "minerva_cad_list_user_labels", "minerva_cad_export",
]
var _panel: Object

func _init(panel: Object) -> void:
	_panel = panel

func handle(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_cad_get_mesh_info":
			return _cad_get_mesh_info(args)
		"minerva_cad_list_edges":
			return _cad_list_edges(args)
		"minerva_cad_get_edge":
			return _cad_get_edge(args)
		"minerva_cad_get_selected_edge":
			return _cad_get_selected_edge(args)
		"minerva_cad_annotate_edges":
			return _cad_annotate_edges(args)
		"minerva_cad_clear_edge_annotations":
			return _cad_clear_edge_annotations(args)
		"minerva_cad_list_user_labels":
			return _cad_list_user_labels(args)
		"minerva_cad_export":
			return await _cad_export(args)
	return _err("Unknown CAD tool: " + tool_name)

func _resolve_host(_args: Dictionary) -> AnnotationHost:
	return _panel.call("get_annotation_host") if is_instance_valid(_panel) else null

func _no_host_error(args: Dictionary) -> Dictionary:
	return _err("The CAD panel has no live annotation host for '%s'" % str(args.get("editor_name", "")))

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result

static func _err(message: String) -> Dictionary:
	return {"success": false, "error": message}

func _cad_export(args: Dictionary) -> Dictionary:
	var backend_args: Dictionary
	if not str(args.get("job_id", "")).is_empty():
		backend_args = {"job_id": args.job_id}
	else:
		backend_args = export_document_args(args)
		if backend_args.has("error"):
			return _err(str(backend_args.error))
	if args.has("wait_ms"):
		backend_args["wait_ms"] = args.wait_ms
	var envelope: Dictionary = await _panel.call("call_backend", "cad.export", backend_args)
	if not envelope.get("success", false):
		envelope["error"] = envelope.get("error", envelope.get("error_message", "CAD export IPC failed"))
		return envelope
	var reply: Dictionary = envelope.get("result", {})
	if reply.has("error"): return {"success": false, "error": reply.error}
	if not reply.get("ok", false): return _err("cad_export_failed: " + JSON.stringify(reply))
	var payload: Variant = reply.get("result", reply)
	if not payload is Dictionary: return _err("cad_export_failed: unexpected payload")
	var result: Dictionary = payload
	return _ok(result)

static func _source_version(value: Variant) -> int:
	if value is int: return value
	if value is float:
		var number: float = value
		return int(number)
	return -1

static func export_document_args(args: Dictionary) -> Dictionary:
	var fmt := str(args.get("format", "")).strip_edges().to_lower()
	if fmt not in ["stl", "step", "stp", "3mf", "glb"]:
		return {"error": "unsupported export format: " + fmt}
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return {"error": "path is required"}
	var document: Dictionary = args.get("_evaluated_document", {})
	var source := str(document.get("source", ""))
	if source.is_empty():
		return {"error": "No source is available to export"}
	var version := _source_version(document.get("source_version", -1))
	if args.has("require_source_version") and _source_version(args.require_source_version) != version:
		return {"error": "Export source does not match require_source_version"}
	if args.has("require_source_digest") and str(args.require_source_digest) != source.sha256_text():
		return {"error": "Export source does not match require_source_digest"}
	var model: Dictionary = document.get("model", {})
	return {"source": source, "source_version": version,
		"document_id": document.get("document_id", ""),
		"evaluation_provenance": document.get("provenance", {}), "part": args.get("part", ""),
		"selection": args.get("selection", args.get("part", model.get("selection", ""))),
		"configuration": args.get("configuration", model.get("configuration", "")),
		"format": fmt, "path": path}

func _cad_get_mesh_info(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_mesh_data"):
		return _err(
			("cad_get_mesh_info: host for '%s' does not expose get_mesh_data — "
			+ "plugin version may not support MCP introspection.")
			% str(args.get("editor_name", ""))
		)

	var mesh: Dictionary = host.call("get_mesh_data")
	var vertices: Array = mesh.get("vertices", []) if mesh is Dictionary else []
	var faces: Array = mesh.get("faces", []) if mesh is Dictionary else []
	var has_geometry: bool = vertices.size() > 0

	var bbox: Variant = null
	if has_geometry:
		bbox = _compute_bbox(vertices)

	return _ok({
		"has_geometry": has_geometry,
		"vertex_count": vertices.size(),
		"face_count": faces.size(),
		"bounding_box": bbox,
		"units": "mm",
	})


func _cad_list_edges(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_edge_registry"):
		return _err(
			"cad_list_edges: host for '%s' does not expose get_edge_registry."
			% str(args.get("editor_name", ""))
		)

	var edges: Array = host.call("get_edge_registry")
	return _ok({"edges": edges})


func _cad_get_edge(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_edge_registry"):
		return _err(
			"cad_get_edge: host for '%s' does not expose get_edge_registry."
			% str(args.get("editor_name", ""))
		)

	var edge_id_variant: Variant = args.get("edge_id", null)
	if edge_id_variant == null:
		return _err("edge_id is required")
	var edge_id: int = int(edge_id_variant)

	var edges: Array = host.call("get_edge_registry")
	var found: Variant = null
	for edge in edges:
		if edge is Dictionary and int(edge.get("id", -1)) == edge_id:
			found = edge
			break

	return _ok({"edge": found})


func _cad_get_selected_edge(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_selected_edge_id"):
		return _err(
			"cad_get_selected_edge: host for '%s' does not expose get_selected_edge_id."
			% str(args.get("editor_name", ""))
		)

	var selected_id: int = host.call("get_selected_edge_id")

	# Look up the full edge dict if there is a selection.
	var edge_dict: Variant = null
	if selected_id != -1 and host.has_method("get_edge_registry"):
		var edges: Array = host.call("get_edge_registry")
		for edge in edges:
			if edge is Dictionary and int(edge.get("id", -1)) == selected_id:
				edge_dict = edge
				break

	return _ok({
		"selected_edge_id": selected_id,
		"edge": edge_dict,
	})


func _cad_annotate_edges(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	# Validate that the host exposes the edge registry.
	if not host.has_method("get_edge_registry"):
		return _err(
			"cad_annotate_edges: host for '%s' does not expose get_edge_registry."
			% str(args.get("editor_name", ""))
		)

	# ── Selector validation ───────────────────────────────────────────────────
	var has_edge_ids: bool = args.has("edge_ids") and args["edge_ids"] != null
	var has_tags_any: bool = args.has("tags_any") and args["tags_any"] != null

	if has_edge_ids and has_tags_any:
		return _err(
			"cad_annotate_edges: provide exactly one selector: edge_ids or tags_any, not both."
		)
	if not has_edge_ids and not has_tags_any:
		return _err(
			"cad_annotate_edges: exactly one selector is required: edge_ids or tags_any."
		)

	# ── Build edge id list from selector ──────────────────────────────────────
	var all_edges: Array = host.call("get_edge_registry")

	# Build a lookup for fast validation: edge_id (int) → edge dict.
	var edge_lookup: Dictionary = {}
	for edge_info in all_edges:
		if edge_info is Dictionary:
			edge_lookup[int(edge_info.get("id", -1))] = edge_info

	var target_ids: Array = []

	if has_edge_ids:
		var raw_ids: Variant = args["edge_ids"]
		if raw_ids is Array:
			for raw_id in (raw_ids as Array):
				target_ids.append(int(raw_id))
		else:
			return _err("cad_annotate_edges: edge_ids must be an array of integers.")
	else:
		# tags_any filter: collect edges whose tags intersect with tags_any.
		var filter_tags: Array = []
		var raw_tags: Variant = args["tags_any"]
		if raw_tags is Array:
			for t in (raw_tags as Array):
				filter_tags.append(str(t))
		else:
			return _err("cad_annotate_edges: tags_any must be an array of strings.")

		for edge_info in all_edges:
			if not (edge_info is Dictionary):
				continue
			var edge_tags: Variant = (edge_info as Dictionary).get("tags", [])
			var tags_arr: Array = edge_tags as Array if edge_tags is Array else []
			for edge_tag in tags_arr:
				if filter_tags.has(str(edge_tag)):
					target_ids.append(int((edge_info as Dictionary).get("id", -1)))
					break

	# ── Mint or use group_id ──────────────────────────────────────────────────
	var group_id: String = str(args.get("group_id", ""))
	if group_id.is_empty():
		# Mint: "cad_edge_grp_" + 8 random hex digits.
		group_id = "cad_edge_grp_%08x" % (randi() & 0xFFFFFFFF)

	var label_format_override: Variant = args.get("label_format", null)

	# Validate geometry before writing any labels; an evaluation-local id cannot
	# identify a newly authored label across topology changes.
	var anchors: Dictionary = {}
	for edge_id: int in target_ids:
		if edge_lookup.has(edge_id):
			var anchor := EdgeAnchor.build(edge_id, all_edges)
			if anchor.is_empty():
				return _err("cad_annotate_edges: edge %d has no usable registry geometry. Re-evaluate the model before labelling it." % edge_id)
			anchors[edge_id] = anchor

	# ── Create annotations ────────────────────────────────────────────────────
	var created_ids: Array = []
	var skipped_unknown: Array = []

	for edge_id in target_ids:
		if not edge_lookup.has(edge_id):
			skipped_unknown.append(edge_id)
			push_warning(
				"[CAD panel tools] cad_annotate_edges: edge_id %d not found in registry — skipped."
				% edge_id
			)
			continue

		# Build label.
		var label: String = ""
		if label_format_override != null and str(label_format_override) != "":
			label = str(label_format_override)
		else:
			label = str(edge_id)

		var view_context := ""
		if host.has_method("get_view_context"):
			view_context = str(host.call("get_view_context"))

		# Build a v2 live edge-anchor annotation. The CAD renderer resolves the
		# current midpoint from this anchor each draw; primitive-only v1 edge
		# annotations are kept as a renderer compatibility path only.
		var annotation: Dictionary = {
			"kind": "cad_edge_number",
			"schema_version": 2,
			"author": {"kind": "ai"},
			"view_context": view_context,
			"anchor": anchors[edge_id],
			"payload": {
				"text": label,
				"group_id": group_id,
				"box_offset": [0.0, 0.0, 0.0],
			},
		}

		host.call("add_annotation", annotation)
		created_ids.append(edge_id)

	return _ok({
		"group_id": group_id,
		"created_edge_ids": created_ids,
		"skipped_unknown_ids": skipped_unknown,
	})


func _cad_clear_edge_annotations(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	# Validate predicate.
	var has_group_id: bool = args.has("group_id") and args["group_id"] != null and str(args["group_id"]) != ""
	var clear_all: bool = bool(args.get("all", false))

	if has_group_id and clear_all:
		return _err(
			"cad_clear_edge_annotations: provide exactly one predicate: group_id or all=true, not both."
		)
	if not has_group_id and not clear_all:
		return _err(
			"cad_clear_edge_annotations: a predicate is required: group_id or all=true."
		)

	if not host.has_method("get_annotations"):
		return _err(
			"cad_clear_edge_annotations: host for '%s' does not expose get_annotations."
			% str(args.get("editor_name", ""))
		)

	if not host.has_method("remove_annotation"):
		return _err(
			"cad_clear_edge_annotations: host for '%s' does not expose remove_annotation."
			% str(args.get("editor_name", ""))
		)

	var filter_group: String = str(args.get("group_id", ""))
	var annotations: Array = host.call("get_annotations")

	# Collect ids to remove first (can't mutate while iterating).
	var to_remove: Array = []
	for ann in annotations:
		if not (ann is Dictionary):
			continue
		var ann_dict: Dictionary = ann as Dictionary
		var kind: String = str(ann_dict.get("kind", ""))
		if kind != "cad_edge_number":
			continue
		if clear_all:
			to_remove.append(str(ann_dict.get("id", "")))
		else:
			# Match by group_id in payload.
			var payload: Variant = ann_dict.get("kind_payload", ann_dict.get("payload", {}))
			if payload is Dictionary:
				var ann_group: String = str((payload as Dictionary).get("group_id", ""))
				if ann_group == filter_group:
					to_remove.append(str(ann_dict.get("id", "")))

	for ann_id in to_remove:
		if ann_id != "":
			host.call("remove_annotation", ann_id)

	return _ok({"cleared_count": to_remove.size()})


func _cad_list_user_labels(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)

	if not host.has_method("get_annotations"):
		return _err(
			"cad_list_user_labels: host for '%s' does not expose get_annotations."
			% str(args.get("editor_name", ""))
		)

	var annotations: Array = host.call("get_annotations")
	var labels: Array = []
	for ann in annotations:
		if not (ann is Dictionary):
			continue
		var ann_dict: Dictionary = ann as Dictionary
		# Filter to cad_edge_number kind authored by the user. The cad_edge_number
		# tool stamps author="human"; agent-minted annotations from
		# minerva_cad_annotate_edges stamp author="ai". The exclusion is deliberate:
		# agent labels are bookkeeping, not user intent the agent should act on.
		if str(ann_dict.get("kind", "")) != "cad_edge_number":
			continue
		if AnnotationAuthor.kind_of(ann_dict.get("author", "")) != "human":
			continue

		var anchor: Variant = ann_dict.get("anchor", {})
		if not (anchor is Dictionary):
			continue
		var anchor_d: Dictionary = anchor as Dictionary
		if not anchor_d.has("id"):
			continue
		var resolved_value: Variant = host.call("_resolve_edge_anchor", anchor_d)
		if not resolved_value is Dictionary:
			continue
		var resolved: Dictionary = resolved_value
		var stale: bool = resolved.get("stale", true) == true
		var edge_id: int = -1 if stale else int(resolved.get("edge_id", -1))
		var midpoint_value: Variant = resolved.get("position", Vector3.ZERO)
		var midpoint: Vector3 = Vector3.ZERO
		if midpoint_value is Vector3:
			midpoint = midpoint_value

		var payload: Dictionary = ann_dict.get("kind_payload", ann_dict.get("payload", {})) as Dictionary
		var text: String = str(payload.get("text", ""))

		labels.append({
			"edge_id": edge_id,
			"stale": stale,
			"midpoint": [midpoint.x, midpoint.y, midpoint.z],
			"text": text,
			"annotation_id": str(ann_dict.get("id", "")),
			"view_context": str(ann_dict.get("view_context", "")),
		})

	return _ok({
		"labels": labels,
		"count": labels.size(),
	})

static func _compute_bbox(vertices: Array) -> Variant:
	if vertices.is_empty():
		return null

	var min_x: float = INF
	var min_y: float = INF
	var min_z: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	var max_z: float = -INF

	for v in vertices:
		if not (v is Array) or (v as Array).size() < 3:
			continue
		var va: Array = v as Array
		var vx: float = float(va[0])
		var vy: float = float(va[1])
		var vz: float = float(va[2])
		if vx < min_x: min_x = vx
		if vy < min_y: min_y = vy
		if vz < min_z: min_z = vz
		if vx > max_x: max_x = vx
		if vy > max_y: max_y = vy
		if vz > max_z: max_z = vz

	# If no valid vertex was processed (e.g. all malformed), return null.
	if min_x == INF:
		return null

	return {
		"min": [min_x, min_y, min_z],
		"max": [max_x, max_y, max_z],
	}
