extends RefCounted
## Off-tree plugin script: NO class_name
## Core data model for code-magic graph. Loads pre-computed positions from JSON.
## Used by all visualization levels.

const KIND_COLORS := {
	"function": Color(0.3, 0.67, 0.97),
	"class": Color(0.32, 0.81, 0.4),
	"signal": Color(0.99, 0.77, 0.1),
	"constant": Color(0.68, 0.71, 0.74),
	"enum": Color(0.8, 0.37, 0.91),
	"variable": Color(0.53, 0.56, 0.59),
}

const EDGE_COLORS := {
	"calls": Color(0.3, 0.67, 0.97),
	"connects": Color(0.32, 0.81, 0.4),
	"inherits": Color(1.0, 0.42, 0.42),
	"preloads": Color(1.0, 0.57, 0.17),
	"imports": Color(0.53, 0.56, 0.59),
	"contains": Color(0.33, 0.33, 0.47),
	"instances": Color(0.9, 0.6, 0.97),
	"emits": Color(1.0, 0.66, 0.3),
}

const DASHED_EDGE_TYPES := ["instances", "emits"]

var nodes: Array[Dictionary] = []
var edges: Array[Dictionary] = []
var files: Array[Dictionary] = []
var analysis: Dictionary = {}
var stats: Dictionary = {}

var _nodes_by_id: Dictionary = {}
var _nodes_by_file: Dictionary = {}
var _edges_by_source: Dictionary = {}
var _edges_by_target: Dictionary = {}

# Visibility
var hidden_symbols: Dictionary = {}
var hidden_files: Dictionary = {}
var hidden_dirs: Dictionary = {}
var active_kinds: Dictionary = {"function": true, "class": true, "signal": true}
var active_edge_types: Dictionary = {
	"calls": true, "connects": true, "inherits": true,
	"preloads": true, "contains": true, "instances": true, "emits": true,
}


func load_from_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("GraphData: file not found: %s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("GraphData: cannot open %s" % path)
		return false
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("GraphData: JSON parse error: %s" % json.get_error_message())
		return false
	var data: Dictionary = json.data
	nodes.assign(data.get("nodes", []))
	edges.assign(data.get("edges", []))
	files.assign(data.get("files", []))
	analysis = data.get("analysis", {})
	stats = data.get("stats", {})
	_build_indices()
	return true


func load_from_dict(data: Dictionary) -> bool:
	## Populate graph from an in-memory Dictionary (same fields as load_from_file).
	## Useful when data is already parsed (e.g. received via MCP tool call).
	## Returns true on success, false if data is not a valid Dictionary.
	if not data is Dictionary:
		push_error("GraphData.load_from_dict: argument is not a Dictionary")
		return false
	nodes.assign(data.get("nodes", []))
	edges.assign(data.get("edges", []))
	files.assign(data.get("files", []))
	analysis = data.get("analysis", {})
	stats = data.get("stats", {})
	_build_indices()
	return true


func _build_indices() -> void:
	_nodes_by_id.clear()
	_nodes_by_file.clear()
	_edges_by_source.clear()
	_edges_by_target.clear()
	for node: Dictionary in nodes:
		_nodes_by_id[str(node.id)] = node
		var file_path: String = str(node.file)
		if not _nodes_by_file.has(file_path):
			_nodes_by_file[file_path] = []
		_nodes_by_file[file_path].append(node)
	for edge: Dictionary in edges:
		var src: String = str(edge.source)
		var tgt: String = str(edge.target)
		if not _edges_by_source.has(src):
			_edges_by_source[src] = []
		_edges_by_source[src].append(edge)
		if not _edges_by_target.has(tgt):
			_edges_by_target[tgt] = []
		_edges_by_target[tgt].append(edge)


func get_node_by_id(id: String) -> Dictionary:
	return _nodes_by_id.get(id, {})

func get_edges_for_node(id: String) -> Dictionary:
	return {
		"incoming": _edges_by_target.get(id, []),
		"outgoing": _edges_by_source.get(id, []),
	}

func get_nodes_in_file(file_path: String) -> Array:
	return _nodes_by_file.get(file_path, [])

func get_file_paths() -> Array:
	return _nodes_by_file.keys()


# ── Visibility ──

func is_node_visible(node: Dictionary) -> bool:
	if not active_kinds.get(str(node.kind), false):
		return false
	if hidden_symbols.has(str(node.id)):
		return false
	var fp: String = str(node.file)
	if hidden_files.has(fp):
		return false
	for dir_prefix: String in hidden_dirs:
		if fp.begins_with(dir_prefix):
			return false
	return true

func is_edge_visible(edge: Dictionary) -> bool:
	if not active_edge_types.get(str(edge.type), false):
		return false
	var src: Dictionary = get_node_by_id(str(edge.source))
	var tgt: Dictionary = get_node_by_id(str(edge.target))
	if src.is_empty() or tgt.is_empty():
		return false
	return is_node_visible(src) and is_node_visible(tgt)

func get_visible_nodes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for node: Dictionary in nodes:
		if is_node_visible(node):
			result.append(node)
	return result

func get_visible_edges() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for edge: Dictionary in edges:
		if is_edge_visible(edge):
			result.append(edge)
	return result

func hide_symbol(id: String) -> void:
	hidden_symbols[id] = true

func hide_file(file_path: String) -> void:
	hidden_files[file_path] = true

func hide_dir(dir_prefix: String) -> void:
	hidden_dirs[dir_prefix] = true

func unhide_all() -> void:
	hidden_symbols.clear()
	hidden_files.clear()
	hidden_dirs.clear()

func get_hidden_count() -> int:
	return hidden_symbols.size() + hidden_files.size() + hidden_dirs.size()

func is_file_hidden(file_path: String) -> bool:
	if hidden_files.has(file_path):
		return true
	for dir_prefix: String in hidden_dirs:
		if file_path.begins_with(dir_prefix):
			return true
	return false

func is_dir_hidden(dir_prefix: String) -> bool:
	return hidden_dirs.has(dir_prefix)


# ── Analysis ──

func is_dead_code(id: String) -> bool:
	var dead_ids: Array = analysis.get("dead_code_ids", [])
	return dead_ids.has(id)

func get_dry_group(signature_hash: String) -> int:
	var groups: Dictionary = analysis.get("dry_signature_groups", {})
	if groups.has(signature_hash):
		return int(groups[signature_hash])
	return -1

func get_node_radius(node: Dictionary) -> float:
	return clampf(2.5 + float(node.get("fan_in", 0)) * 1.2, 3.0, 14.0)

func get_kind_color(kind: String) -> Color:
	return KIND_COLORS.get(kind, Color(0.5, 0.5, 0.5))

func get_edge_color(edge_type: String) -> Color:
	return EDGE_COLORS.get(edge_type, Color(0.33, 0.33, 0.33))

func is_dashed_edge(edge_type: String) -> bool:
	return edge_type in DASHED_EDGE_TYPES


# ── Boundary helpers ──

func get_boundary_for_file(file_path: String) -> String:
	## Derive boundary from directory structure.
	## e.g., "scripts/core/foo.gd" → "core", "scripts/tools/bar.gd" → "tools"
	var parts: PackedStringArray = file_path.split("/")
	if parts.size() >= 2:
		return parts[parts.size() - 2]  # parent directory name
	return "root"

func get_boundaries() -> Dictionary:
	## Returns {boundary_name: {files: [paths], nodes: [node_dicts]}}
	var boundaries: Dictionary = {}
	for file_path: String in get_file_paths():
		var boundary: String = get_boundary_for_file(file_path)
		if not boundaries.has(boundary):
			boundaries[boundary] = {"files": [], "nodes": []}
		boundaries[boundary].files.append(file_path)
		for node: Dictionary in get_nodes_in_file(file_path):
			boundaries[boundary].nodes.append(node)
	return boundaries

func get_cross_boundary_edges() -> Array[Dictionary]:
	## Edges where source and target are in different boundaries.
	var result: Array[Dictionary] = []
	for edge: Dictionary in edges:
		var src: Dictionary = get_node_by_id(str(edge.source))
		var tgt: Dictionary = get_node_by_id(str(edge.target))
		if src.is_empty() or tgt.is_empty():
			continue
		var src_boundary: String = get_boundary_for_file(str(src.file))
		var tgt_boundary: String = get_boundary_for_file(str(tgt.file))
		if src_boundary != tgt_boundary:
			result.append(edge)
	return result

func get_components_in_boundary(boundary_name: String) -> Array[Dictionary]:
	## Get class-level nodes (components) within a boundary.
	var result: Array[Dictionary] = []
	var boundaries: Dictionary = get_boundaries()
	if not boundaries.has(boundary_name):
		return result
	for node: Dictionary in boundaries[boundary_name].nodes:
		if str(node.kind) == "class":
			result.append(node)
	return result
