extends SceneTree
## A picture of a big scene comes back, or says why — it never just stops.
##
## minerva_cad_snapshot asks the panel's host for a view's image. The host used
## to answer a cold call with null and BOOK a capture for the next drawn frame,
## so the verb's only recourse was to await RenderingServer.frame_post_draw and
## try again. That signal fires only while the engine is drawing: a window that
## is occluded or minimised, a paused main loop — or this very test run — draws
## no frames at all, and the caller waits on a frame that never comes until its
## budget runs out. No file, no error, nothing to retry differently.
##
## So the host reads the render target on the call itself and keeps the booking
## only as the refresh.
##
## THE CAUSE IS DEMONSTRATED, NOT ASSERTED. The suite books a one-shot on
## RenderingServer.frame_post_draw, spins the main loop, and shows the shot was
## never fired — which is precisely what the old path was waiting on.
##
## THE SCENE IS THE REAL ONE. The solid is built by the panel's own mesh
## display into a live ArrayMesh and counted off the MeshInstance3D in the
## tree, not off the dictionary it was fed; the reference is a procedural
## hundred-thousand-triangle soup mounted in the pane being captured. Both are
## measured after mounting, so a scene that quietly failed to build cannot pass
## for the one the report was made about.
##
## ORACLE. What would show this wrong: open the written PNGs. They are the
## pane, at the pane's own SubViewport size, not blank and not a stale picture
## of an empty scene. Headless has no rasteriser, so the PIXELS come from a
## stand-in render target sized from that same SubViewport — what is under test
## is that the host ASKS for them without a drawn frame, twice, and that both
## answers reach a file inside the budget.
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_snapshot_capture.gd

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"

## The scene the timeout was measured on: a two-part shell of some fourteen
## thousand vertices with a 132k-triangle board under it. The floors here are
## the item's own.
const MIN_SOLID_VERTICES := 10000
const MIN_REFERENCE_TRIANGLES := 100000

## What a snapshot may cost the caller, in milliseconds. An MCP verb's budget
## is seconds; the capture is one step of it.
const CAPTURE_BUDGET_MS := 2000

## How long the loop is spun while nothing draws, looking for the frame the old
## path was waiting on.
const IDLE_FRAMES := 60

## Filled from the pane's own SubViewport, so the stand-in target is the size
## the real one would be.
var _pane_size: Vector2i = Vector2i(400, 300)

var _pass: int = 0
var _fail: int = 0


class _EditorStub extends RefCounted:
	var tab_title: String = ""


## A render target that has content but never gets a drawn frame — the state
## every viewport is in here, and the state a real one is in behind an occluded
## window. Counts the reads so a cached answer can be told from a fresh one.
class _StandInTexture extends RefCounted:
	var reads: int = 0
	var size: Vector2i = Vector2i.ZERO

	func _init(image_size: Vector2i) -> void:
		size = image_size

	func get_image() -> Image:
		reads += 1
		var img := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.2, 0.3, 0.4, 1.0))
		return img


class _StandInViewport extends Node:
	var texture: _StandInTexture = null

	func get_texture() -> _StandInTexture:
		return texture


func _init() -> void:
	print("=== CAD Snapshot Capture Test (a picture, or a reason) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s — %s" % [label, detail])


func _run() -> void:
	var panel := _panel()
	if panel == null:
		check("setup: the CAD panel instantiates", false, PANEL_SCENE_PATH)
		return
	panel._apply_width_class(&"lg")
	await process_frame
	await process_frame
	await process_frame

	# The cause, shown rather than asserted: book the very signal the old path
	# waited on and spin the loop. A drawn frame would fire it; nothing here
	# ever draws one, which is exactly the state of an occluded or minimised
	# window, and the caller's await had no timeout.
	var fired := [false]
	var one_shot := func() -> void: fired[0] = true
	RenderingServer.frame_post_draw.connect(one_shot, CONNECT_ONE_SHOT)
	for _idle in range(IDLE_FRAMES):
		await process_frame
	if RenderingServer.frame_post_draw.is_connected(one_shot):
		RenderingServer.frame_post_draw.disconnect(one_shot)
	check("the signal the old path awaited never fires: %d main-loop " % IDLE_FRAMES
			+ "iterations produced no frame_post_draw and no drawn frame, so "
			+ "the await it hung on had nothing to resume it",
			not bool(fired[0]) and Engine.get_frames_drawn() == 0,
			"fired = %s, frames drawn = %d" % [
				str(fired[0]), Engine.get_frames_drawn()])

	# ── The scene the report was made about ───────────────────────────────
	var mesh_data := _solid(112)
	var vertex_count: int = (mesh_data["vertices"] as Array).size()
	for slot in ["TopView", "FrontView", "RightView", "IsoView"]:
		var mesh_root: Node = panel.get_node_or_null("%s/%s/SubViewport/MeshRoot" % [GRID, slot])
		if mesh_root != null:
			mesh_root.call("update_mesh", mesh_data, [])
	var reference := _reference_mesh(MIN_REFERENCE_TRIANGLES)
	var iso_root: Node3D = panel.get_node("%s/IsoView/SubViewport/MeshRoot" % GRID)
	var reference_instance := MeshInstance3D.new()
	reference_instance.mesh = reference
	iso_root.add_child(reference_instance)
	await process_frame

	# Counted off the live scene, not off the dictionary that was fed in: the
	# mesh display builds its own ArrayMesh, and a build that silently failed
	# would leave the pane empty while the input still looked big.
	var iso_viewport: SubViewport = panel.get_node("%s/IsoView/SubViewport" % GRID)
	_pane_size = iso_viewport.size
	var built_vertices := _mounted_vertices(iso_root)
	var mounted_triangles := _mounted_triangles(iso_root)
	check("fixture: the pane being captured really holds the scene — a built "
			+ "ArrayMesh of %d+ vertices " % MIN_SOLID_VERTICES
			+ "and a %d+ triangle reference, " % MIN_REFERENCE_TRIANGLES
			+ "measured off the MeshInstance3Ds in the tree",
			vertex_count >= MIN_SOLID_VERTICES
				and built_vertices >= MIN_SOLID_VERTICES
				and mounted_triangles >= MIN_REFERENCE_TRIANGLES
				and _pane_size.x > 0 and _pane_size.y > 0,
			"fed %d vertices, mounted %d vertices / %d triangles in a %s pane"
				% [vertex_count, built_vertices, mounted_triangles,
					str(_pane_size)])

	# ── The capture ───────────────────────────────────────────────────────
	var host = panel.get_annotation_host()
	var stand_in := _StandInViewport.new()
	stand_in.texture = _StandInTexture.new(_pane_size)
	root.add_child(stand_in)
	host.set_viewport_for("iso", stand_in)

	var started := Time.get_ticks_msec()
	var image: Image = host.render_view_to_image("iso", Rect2())
	var elapsed := Time.get_ticks_msec() - started

	check("the FIRST call answers with an image although no frame has been "
			+ "drawn — the booking is a refresh, not the only way to an answer",
			image != null and image.get_size() == _pane_size,
			"got %s after %d ms" % [
				"null" if image == null else str(image.get_size()), elapsed])
	check("within %d ms, so the caller's budget is spent on the picture rather "
			% CAPTURE_BUDGET_MS + "than on waiting",
			elapsed < CAPTURE_BUDGET_MS, "took %d ms" % elapsed)
	check("and it read the target to get it, rather than handing back an "
			+ "older capture of another scene",
			stand_in.texture.reads == 1, "reads = %d" % stand_in.texture.reads)

	var second_started := Time.get_ticks_msec()
	var second: Image = host.render_view_to_image("iso", Rect2())
	var second_elapsed := Time.get_ticks_msec() - second_started
	check("a second call is served from the cache while the frame counter has "
			+ "not moved — the read-back is not repeated per caller — and is "
			+ "no slower than the first",
			second != null and stand_in.texture.reads == 1
				and second_elapsed <= elapsed
				and second_elapsed < CAPTURE_BUDGET_MS,
			"reads = %d, first %d ms, second %d ms" % [
				stand_in.texture.reads, elapsed, second_elapsed])
	print("    capture: first %d ms, second %d ms, pane %s"
		% [elapsed, second_elapsed, str(_pane_size)])

	# ── The file the verb promises ────────────────────────────────────────
	var path := "user://cad_snapshots/test_snapshot_capture.png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var write_started := Time.get_ticks_msec()
	var saved: Error = image.save_png(path)
	var write_ms := Time.get_ticks_msec() - write_started
	check("the image encodes and lands on disk as a PNG inside the budget",
			saved == OK and FileAccess.file_exists(path)
				and (write_ms + elapsed) < CAPTURE_BUDGET_MS,
			"err=%d, exists=%s, %d ms" % [
				saved, str(FileAccess.file_exists(path)), write_ms])
	var written := FileAccess.open(path, FileAccess.READ)
	check("and the file really is a PNG of the pane, not an empty one",
			written != null and written.get_length() > 100
				and Image.load_from_file(path).get_size() == _pane_size,
			"size on disk = %d" % (written.get_length() if written != null else -1))
	if written != null:
		written.close()

	# The verb is called twice in a session more often than once — the item's
	# own trap — so the SECOND snapshot has to reach disk too, in budget.
	var second_path := "user://cad_snapshots/test_snapshot_capture_2.png"
	if FileAccess.file_exists(second_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(second_path))
	var second_write := Time.get_ticks_msec()
	var second_saved: Error = second.save_png(second_path)
	var second_write_ms := Time.get_ticks_msec() - second_write
	check("the second snapshot lands on disk as well, inside the same budget "
			+ "— two calls in one session both produce a file",
			second_saved == OK and FileAccess.file_exists(second_path)
				and FileAccess.file_exists(path)
				and (second_write_ms + second_elapsed) < CAPTURE_BUDGET_MS
				and Image.load_from_file(second_path).get_size() == _pane_size,
			"err=%d, %d ms encode" % [second_saved, second_write_ms])
	print("    encode: first %d ms, second %d ms"
		% [write_ms, second_write_ms])

	# ── The honest refusal ────────────────────────────────────────────────
	var unknown: Image = host.render_view_to_image("no_such_pane", Rect2())
	check("a pane the panel does not have answers null — the caller is told "
			+ "there is nothing there instead of waiting for it",
			unknown == null, "got an image for a pane that does not exist")

	var real_pane: Image = host.render_view_to_image("top", Rect2())
	check("and a real pane with a renderer that has drawn nothing answers "
			+ "null on the call rather than hanging on a frame",
			real_pane == null, "the dummy renderer produced an image")

	stand_in.free()
	reference_instance.queue_free()
	panel.free()


func _panel() -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	if packed == null:
		return null
	var panel: Node = packed.instantiate()
	root.add_child(panel)
	var editor := _EditorStub.new()
	editor.tab_title = "snapshot"
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"host_api_version": "1",
		"editor": editor,
	})
	return panel


## A displaced grid: (n+1)^2 vertices, 2n^2 triangles, in the panel's own
## {vertices, faces} shape.
func _solid(n: int) -> Dictionary:
	var vertices: Array = []
	var faces: Array = []
	for i in range(n + 1):
		for j in range(n + 1):
			vertices.append([float(i), float(j), sin(float(i) * 0.3) * 3.0])
	for i in range(n):
		for j in range(n):
			var a := i * (n + 1) + j
			faces.append([a, a + 1, a + n + 1])
			faces.append([a + 1, a + n + 2, a + n + 1])
	return {"vertices": vertices, "faces": faces}


## A board-sized triangle soup, built here so no mesh binary is needed.
func _reference_mesh(triangle_count: int) -> ArrayMesh:
	var points := PackedVector3Array()
	points.resize(triangle_count * 3)
	for t in range(triangle_count):
		var x := float(t % 300) * 0.2
		var y := float(t / 300) * 0.2
		points[t * 3] = Vector3(x, y, 0.0)
		points[t * 3 + 1] = Vector3(x + 0.15, y, 0.0)
		points[t * 3 + 2] = Vector3(x, y + 0.15, 0.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _triangles(mesh: ArrayMesh) -> int:
	var arrays: Array = mesh.surface_get_arrays(0)
	return int((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3)


## Vertices of every ArrayMesh mounted under `node`, less the reference soup:
## what the pane is actually asked to draw for the solid.
func _mounted_vertices(node: Node) -> int:
	var total := 0
	for instance in _mesh_instances(node):
		var mesh: ArrayMesh = instance.mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			var count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			if count < MIN_REFERENCE_TRIANGLES * 3:
				total += count
	return total


## Triangles of the largest ArrayMesh mounted under `node` — the reference.
func _mounted_triangles(node: Node) -> int:
	var most := 0
	for instance in _mesh_instances(node):
		var mesh: ArrayMesh = instance.mesh as ArrayMesh
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			most = maxi(most,
				int((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3))
	return most


func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		out.append_array(_mesh_instances(child))
	return out
