## reference_report.gd — what the panel is TOLD about the references it named,
## and what it SEES where one of them could not be read.
##
## Every mounted reference produces a record: a status from the STATUS_* set, a
## reason in prose, the size it turned out to be and the bounds it ended up
## occupying. A reference that failed still gets a record and still gets drawn —
## as a placeholder marker at the pose the document asked for — because a body
## that is simply absent leaves the reader with no evidence at all.
##
## The library that owns this reporter resolves paths, reads files and does the
## frame maths; it is held untyped because typing it would mean preloading
## reference_meshes.gd, which preloads this file.
extends RefCounted

const _Reader := preload("reference_reader.gd")
const LoadedFile = _Reader.LoadedFile

## Colour of the placeholder drawn where a reference could not be loaded.
## Warm, saturated and nothing like the reference outline, because the whole
## point of the marker is that it is not mistaken for geometry.
const MISSING_REFERENCE_COLOR: Color = Color(0.90, 0.45, 0.10, 1.0)
## Edge length of that placeholder, in millimetres. A fixed size rather than a
## proportional one: the body it stands in for has no size, and 20 mm is
## visible at the zoom a board is looked at without swamping it.
const MARKER_SIZE_MM: float = 20.0

## What happened to one reference. Reported per reference, so the LLM asking
## about the scene gets a reason rather than a shorter list than it expected.
const STATUS_OK: String = "ok"
const STATUS_UNRESOLVED: String = "unresolved"
const STATUS_MISSING: String = "missing"
const STATUS_UNSUPPORTED: String = "unsupported"
const STATUS_UNREADABLE: String = "unreadable"
const STATUS_EMPTY: String = "empty"
const STATUS_OVERSIZE: String = "oversize"

## Child of a MeshRoot that holds every mounted reference.
const LAYER_NODE_NAME: String = "ReferenceRoot"
## Per-reference containers inside a reference node.
const SHADED_NODE_NAME: String = "Shaded"
const OUTLINE_NODE_NAME: String = "Outline"
## Container for the placeholder of a reference that failed to load.
const MARKER_NODE_NAME: String = "Missing"


## The ReferenceMeshes these records are reported for.
var _library: Variant = null

## What the last mount actually put on screen: one record per reference that
## loaded, in the order the evaluation named them. This is what the
## measurement surface reads — it is the only place that knows which file each
## posed body came from and where it ended up.
var _mounted: Array = []


func _init(library: Variant) -> void:
	_library = library


## Drop the records of the previous mount, at the start of a new one.
func begin_mount() -> void:
	_mounted = []


## Records for the references the last mount actually put geometry on screen
## for: {name, path, resolved_path, units, up, status, reason, warning, stamp, pose,
## local_aabb, world_aabb, triangle_count, bytes, load_ms, outlines_skipped,
## parts, node_bounds}. `parts` is the cached, converted geometry — shared, not
## copied — so a caller that wants colliders or a segmentation reads it
## straight from here.
func mounted_references() -> Array:
	var out: Array = []
	for entry in _mounted:
		if str((entry as Dictionary).get("status", STATUS_OK)) == STATUS_OK:
			out.append(entry)
	return out


## The same records for EVERY reference the last evaluation named, in that
## order, whether or not its file could be read. A reference that failed is
## still a fact about the document — it has a name, a path, a pose and a
## marker in the world — and a caller that only ever sees the ones that
## worked gets a shorter list with no explanation for it.
func reference_records() -> Array:
	return _mounted


func mount_under(
	references: Array,
	document_path: String,
	parent: Node3D,
	record: bool
) -> Dictionary:
	var warnings := PackedStringArray()
	var errors := PackedStringArray()
	var lines := PackedStringArray()
	var statuses: Array = []
	var mounted := 0
	var marked := 0
	var bounds := AABB()
	var have_bounds := false

	if parent != null:
		var layer := _layer(parent, true)
		for child in layer.get_children():
			layer.remove_child(child)
			child.free()

		for entry in references:
			if not (entry is Dictionary):
				continue
			var reference: Dictionary = entry
			var reference_name := str(reference.get("name", ""))
			var pose: Transform3D = _library.transform_from_matrix(reference.get("matrix", []))
			var state := {
				"name": reference_name,
				"path": str(reference.get("path", "")),
				"resolved_path": "",
				# units and up are baked into parts[].transform, so anything
				# keyed on the geometry has to key on them as well.
				"units": str(reference.get("units", "")).to_lower(),
				"up": str(reference.get("up", "")).to_lower(),
				"status": STATUS_OK,
				"reason": "",
				"warning": "",
				"stamp": "",
				"pose": pose,
				"local_aabb": AABB(),
				"world_aabb": AABB(),
				"triangle_count": 0,
				"bytes": 0,
				"load_ms": 0,
				"outlines_skipped": false,
				"parts": [],
				"node_bounds": [],
			}

			var resolved: Dictionary = _library.resolve(str(reference.get("path", "")), document_path)
			if not str(resolved["warning"]).is_empty():
				warnings.append(str(resolved["warning"]))
				state["warning"] = str(resolved["warning"])
			var loaded: LoadedFile = null
			if str(resolved["error"]).is_empty():
				state["resolved_path"] = str(resolved["path"])
				# The unit and up-axis conversion is baked into the cached
				# parts, so what is left to apply per evaluation is the pose,
				# nothing else.
				# The worker always resolves units to a concrete value, so
				# `units_declared` is the only thing that says whether the
				# author chose it. Passing "" through when they did not lets the
				# library apply — and, for a format that carries no units,
				# report — its own default.
				var declared_units := ""
				if bool(reference.get("units_declared", true)):
					declared_units = str(reference.get("units", ""))
				loaded = _library.load_file(
					str(resolved["path"]),
					declared_units,
					str(reference.get("up", ""))
				)
				state["stamp"] = loaded.stamp
				state["triangle_count"] = loaded.triangle_count
				state["bytes"] = loaded.byte_size
				state["load_ms"] = loaded.load_ms
				state["outlines_skipped"] = loaded.outlines_skipped
			else:
				state["status"] = STATUS_UNRESOLVED
				state["reason"] = str(resolved["error"])

			if loaded != null and not loaded.is_ok():
				state["status"] = loaded.status
				state["reason"] = loaded.error

			var world := AABB()
			if str(state["status"]) == STATUS_OK:
				layer.add_child(_build_reference_node(loaded, pose, reference_name))
				world = _library.transform_aabb(pose, loaded.local_aabb)
				state["local_aabb"] = loaded.local_aabb
				state["parts"] = loaded.parts
				state["node_bounds"] = loaded.node_bounds()
				if not loaded.warning.is_empty():
					# A resolution warning (absolute path) and a size warning
					# can both apply; keep both.
					var prior := str(state.get("warning", ""))
					state["warning"] = loaded.warning if prior.is_empty() else prior + " " + loaded.warning
					warnings.append(loaded.warning)
					lines.append("%s — %s" % [_label(reference_name), loaded.warning])
				mounted += 1
			else:
				# A failed reference is still drawn: a placeholder at the pose
				# the document asked for. Without it the body is simply absent
				# and the only evidence is a line of text somewhere else.
				layer.add_child(_build_marker_node(pose, reference_name))
				world = _library.transform_aabb(pose, _marker_bounds())
				errors.append(str(state["reason"]))
				lines.append("%s — %s" % [_label(reference_name), str(state["reason"])])
				marked += 1

			state["world_aabb"] = world
			bounds = world if not have_bounds else bounds.merge(world)
			have_bounds = true

			statuses.append({
				"name": state["name"],
				"path": state["path"],
				"resolved_path": state["resolved_path"],
				"status": state["status"],
				"reason": state["reason"],
				"warning": state["warning"],
				"triangle_count": state["triangle_count"],
				"bytes": state["bytes"],
				"load_ms": state["load_ms"],
				"outlines_skipped": state["outlines_skipped"],
			})
			if record:
				_mounted.append(state)

	return {
		"world_aabb": bounds,
		"warnings": warnings,
		"errors": errors,
		"mounted": mounted,
		"marked": marked,
		"statuses": statuses,
		"status_lines": lines,
	}


## How a reference is named in a message: its own name when the document gave
## it one, and the word otherwise — never an empty string, which reads as a
## broken message rather than as an unnamed reference.
static func _label(reference_name: String) -> String:
	return reference_name if not reference_name.is_empty() else "reference"


## Bounds of the placeholder, centred on the pose origin.
static func _marker_bounds() -> AABB:
	var half := MARKER_SIZE_MM * 0.5
	return AABB(Vector3(-half, -half, -half), Vector3.ONE * MARKER_SIZE_MM)


## The placeholder for a reference that could not be loaded: a wireframe cube
## with an axis cross through it, at the pose the document asked for. Lines
## rather than a solid, so it reads as a marker in the ortho x-ray panes and in
## the shaded one alike, and so it cannot be mistaken for the missing body.
func _build_marker_node(pose: Transform3D, reference_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = "Reference_%s" % _label(reference_name)
	node.transform = pose

	var marker := Node3D.new()
	marker.name = MARKER_NODE_NAME
	node.add_child(marker)

	var half := MARKER_SIZE_MM * 0.5
	var segments := PackedVector3Array()
	for axis in range(3):
		for corner in range(4):
			var a := Vector3.ZERO
			var b := Vector3.ZERO
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			a[axis] = -half
			b[axis] = half
			a[u] = half if (corner & 1) != 0 else -half
			b[u] = a[u]
			a[v] = half if (corner & 2) != 0 else -half
			b[v] = a[v]
			segments.append(a)
			segments.append(b)
	for axis in range(3):
		var a := Vector3.ZERO
		var b := Vector3.ZERO
		a[axis] = -half
		b[axis] = half
		segments.append(a)
		segments.append(b)

	var lines := MeshInstance3D.new()
	lines.mesh = _library.line_mesh_from_segments(segments, MISSING_REFERENCE_COLOR)
	marker.add_child(lines)
	return node


## Show or hide the shaded reference geometry under `parent`. The ortho panes
## are outline x-rays: the outlines stay, the shaded bodies go.
func set_shaded_visible(parent: Node3D, shaded_visible: bool) -> void:
	var layer := _layer(parent, false)
	if layer == null:
		return
	for reference_node in layer.get_children():
		var shaded := reference_node.get_node_or_null(SHADED_NODE_NAME)
		if shaded != null:
			shaded.visible = shaded_visible


## Record a failure on `loaded`, cache it and hand it back. Failures are cached
## like successes so a missing file is not re-stat-ed on every keystroke.
func fail(
	cache: Dictionary,
	key: String,
	loaded: LoadedFile,
	started: int,
	status: String,
	reason: String
) -> LoadedFile:
	loaded.status = status
	loaded.error = reason
	loaded.parts = []
	loaded.outlines = []
	loaded.load_ms = Time.get_ticks_msec() - started
	cache[key] = loaded
	return loaded


## One reference: a posed node holding the shaded bodies and the outline.
func _build_reference_node(loaded: LoadedFile, pose: Transform3D, reference_name: String) -> Node3D:
	var node := Node3D.new()
	node.name = "Reference_%s" % _label(reference_name)
	node.transform = pose

	var shaded := Node3D.new()
	shaded.name = SHADED_NODE_NAME
	node.add_child(shaded)
	for part in loaded.parts:
		var instance := MeshInstance3D.new()
		instance.mesh = part["mesh"]
		instance.transform = part["transform"]
		shaded.add_child(instance)

	var outline := Node3D.new()
	outline.name = OUTLINE_NODE_NAME
	node.add_child(outline)
	for line_mesh in loaded.outlines:
		var lines := MeshInstance3D.new()
		lines.mesh = line_mesh
		outline.add_child(lines)

	return node


func _layer(parent: Node3D, create: bool) -> Node3D:
	var existing := parent.get_node_or_null(LAYER_NODE_NAME)
	if existing != null:
		return existing as Node3D
	if not create:
		return null
	var layer := Node3D.new()
	layer.name = LAYER_NODE_NAME
	parent.add_child(layer)
	return layer
