extends Node
## A private evaluated view. Reuses CAD's measurement engines and mesh cache;
## owns its placements, colliders and optional capture world, never an editor.
const Gauge := preload("mesh_gauge.gd")
const Checks := preload("geometry_checks.gd")
const Features := preload("mesh_features.gd")
const Fasteners := preload("fastener_checks.gd")
const Cache := preload("part_cache.gd")

var owner_panel: WeakRef
var document: Dictionary
var initial_freshness: Dictionary
var library: RefCounted
var report: Dictionary
var gauge: Node
var checks: RefCounted
var features := Features.new()
var fasteners := Fasteners.new()
var reference_digest := ""
var viewport: SubViewport
var mesh_root: Node3D
var camera: Camera3D
var last_used := Time.get_ticks_msec()
var busy := false

func setup(panel: Node, snapshot: Dictionary, result: Dictionary, references: Array) -> void:
	owner_panel = weakref(panel)
	document = snapshot.duplicate(true)
	document.merge({"mesh": result.get("mesh", {}), "references": references,
		"model": result.get("model", {}), "last_eval": {"status": "ok", "shape_name": result.get("shape_name", "")}}, true)
	document["provenance"] = document.get("provenance", {}).duplicate(true)
	document.provenance.merge(result.get("provenance", {}), true)
	initial_freshness = panel.evaluation_freshness().duplicate(true)
	library = panel._reference_library.fork()
	var holder := Node3D.new()
	report = library.mount_all(references, str(document.get("path", "")), [holder])
	holder.free()
	var identities: Array = []
	for record: Dictionary in get_reference_status():
		identities.append([record.get("name", ""), record.get("resolved_path", ""), record.get("stamp", ""),
			Gauge.transform_identity(record.get("pose", Transform3D.IDENTITY))])
	reference_digest = JSON.stringify(identities)
	document.provenance["reference_digest"] = reference_digest.sha256_text()
	initial_freshness["source_version"] = document.get("source_version", -1)
	gauge = Gauge.new()
	add_child(gauge)
	checks = Checks.new()
	checks.attach(self)

func get_document_state() -> Dictionary:
	return document

func get_evaluation_state() -> Dictionary:
	return document

func evaluation_freshness() -> Dictionary:
	var panel: Node = owner_panel.get_ref()
	var state := initial_freshness.duplicate(true)
	state["provenance"] = document.get("provenance", {})
	if panel == null:
		state["stale"] = true
		state["stale_reason"] = "Owning CAD document closed"
		return state
	var current: Dictionary = panel.evaluation_freshness()
	if current.get("provenance", {}).get("source_digest", "") != document.get("provenance", {}).get("source_digest", "") or current.get("stale", false):
		state["stale"] = true
		state["stale_reason"] = "Document changed after this query context was captured"
	state["buffer_version"] = current.get("buffer_version", -1)
	return state

func get_reference_state() -> Array:
	return library.mounted_references()

func get_reference_status() -> Array:
	return library.reference_records()

func get_reference_digest() -> String:
	return reference_digest

func get_mesh_gauge() -> Node:
	return gauge

func get_mesh_features() -> RefCounted:
	return features

func get_geometry_checks() -> RefCounted:
	return checks

func ensure_gauge_built() -> int:
	return gauge.build(Gauge.bodies_from_records(get_reference_state()), reference_digest)

func check_interference(args: Dictionary = {}) -> Dictionary:
	return await checks.check(self, args)

func check_clearance(args: Dictionary = {}) -> Dictionary:
	return await checks.check_clearance(self, args)

func check_reference_pairs(args: Dictionary = {}) -> Dictionary:
	return await checks.check_reference_pairs(self, args)

func check_fasteners(args: Dictionary = {}) -> Dictionary:
	return await fasteners.check(self, args)

func call_backend(channel: String, args: Dictionary, timeout_ms: int = 30000) -> Dictionary:
	var panel: Node = owner_panel.get_ref()
	if panel == null:
		return {"success": false, "error_message": "Owning CAD document closed"}
	return await panel.call_backend(channel, args, timeout_ms)

func call_backend_until(channel: String, args: Dictionary, chunk_ms: int = 60000, give_up_ms: int = 900000) -> Dictionary:
	var panel: Node = owner_panel.get_ref()
	if panel == null:
		return {"success": false, "error_message": "Owning CAD document closed"}
	return await panel.call_backend_until(channel, args, chunk_ms, give_up_ms)

## Captures alone allocate a render world; measurement queries need no pixels.
func get_query_mesh_root() -> Node3D:
	if mesh_root != null:
		return mesh_root
	viewport = SubViewport.new()
	viewport.world_3d = World3D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.size = Vector2i(1024, 768)
	add_child(viewport)
	mesh_root = preload("mesh_display.gd").new()
	viewport.add_child(mesh_root)
	var mounted: Dictionary = library.mount_all(document.references, str(document.get("path", "")), [mesh_root])
	mesh_root.set_reference_aabb(mounted.get("world_aabb", AABB()))
	mesh_root.update_mesh(document.mesh, [])
	var panel: Node = owner_panel.get_ref()
	var source: Node3D = preload("posed_capture.gd")._mesh_root(panel)
	if source != null:
		viewport.world_3d.environment = preload("posed_capture.gd")._source_environment(source)
	return mesh_root

func get_view_camera(view: String) -> Camera3D:
	get_query_mesh_root()
	if camera != null:
		camera.free()
	var panel: Node = owner_panel.get_ref()
	var source: Camera3D = panel.get_view_camera(view)
	if source == null:
		return null
	camera = Camera3D.new()
	camera.projection = source.projection
	camera.fov = source.fov
	camera.size = source.size
	camera.keep_aspect = source.keep_aspect
	camera.near = source.near
	camera.far = source.far
	viewport.add_child(camera)
	camera.global_transform = source.global_transform
	camera.current = true
	return camera

func get_pane_preset(view: String) -> String:
	return owner_panel.get_ref().get_pane_preset(view)

func view_unavailable_reason(view: String) -> String:
	return owner_panel.get_ref().view_unavailable_reason(view)

func get_pick_ray(view: String, pixel: Vector2) -> Dictionary:
	return owner_panel.get_ref().get_pick_ray(view, pixel)

func _exit_tree() -> void:
	if checks != null:
		checks.release()
	Cache.forget(self)
