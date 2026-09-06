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
## AND IT IS A PICTURE OF WHAT WAS ASKED FOR. The narrow layout registers every
## pane id against the ONE SubViewport on screen, so the pixels behind "top"
## there are of whatever the pane is pointed at. Answering that picture under
## the requested name is worse than answering nothing: a vision model reads the
## perspective render as the top view and reports on it with confidence. The
## stand-in target here paints the direction its camera is actually looking, so
## a capture can be told apart from a capture of another projection.
##
## AND THE PANES THE OWNER JUDGES BY ARE THE EXPENSIVE ONES. A pane showing a
## direction draws the outline of the mesh: the only work a capture of it does
## that a capture of the iso pane does not. On a rev-3-scale shell that walk is
## a hundred thousand edges, and it was redone for every pane the moment a mesh
## arrived and again on every single draw — so a burst of snapshots of top,
## front and right paid for it a dozen times over and the verb ran out of
## budget while iso, which draws no outline, answered in seconds. The walk is
## now built once per mesh, only for a pane that actually draws an outline, and
## its projection is kept until the camera or the pane moves.
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_snapshot_capture.gd

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
const SINGLE_VIEW := "ResponsiveContainer/NarrowLayout/SingleView"
const _PaneProjection: Script = preload("res://../../minerva-plugins/cad/ui/scripts/pane_projection.gd")

## Every pane id the narrow layout registers against its one SubViewport.
const NARROW_PANE_IDS: PackedStringArray = [
	"perspective", "top", "bottom", "front", "back", "left", "right", "iso",
]

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

## The panes an owner judges a wall by, and the shell they timed out on: a
## grid of this many cells is 37,249 vertices and 73,728 triangles, the size
## of the rev-3 enclosure. Four consecutive calls is what the report was made
## of. The outline used to be rebuilt for every pane on arrival AND on every
## draw; that the caches now hold is asserted as COUNTS of adjacency walks and
## projections, not as elapsed time. ORTHO_BUDGET_MS is only a ceiling on a
## hang — generous enough that a loaded CI machine cannot trip it.
const ORTHO_PANES: PackedStringArray = ["top", "front", "right"]
const ORTHO_SOLID_CELLS := 192
const ORTHO_MIN_VERTICES := 35000
const ORTHO_BURST := 4
const ORTHO_BUDGET_MS := 30000

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


## The same stand-in target, painting the direction its camera is actually
## looking, so two captures of one pane under two projections are as
## distinguishable as two real renders would be.
class _ProjectionTexture extends _StandInTexture:
	var camera: Camera3D = null

	func _init(image_size: Vector2i, view_camera: Camera3D) -> void:
		super._init(image_size)
		camera = view_camera

	func get_image() -> Image:
		reads += 1
		var look: Vector3 = -camera.global_transform.basis.z
		var img := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
		img.fill(Color(absf(look.x), absf(look.y), absf(look.z), 1.0))
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

	# ── The panes the owner judges by ─────────────────────────────────────
	var shell := _solid(ORTHO_SOLID_CELLS)
	var ortho_targets := {}
	for pane_id in ORTHO_PANES:
		var pane_viewport: SubViewport = panel.get_node(
			"%s/%sView/SubViewport" % [GRID, String(pane_id).capitalize()])
		var pane_target := _StandInViewport.new()
		pane_target.texture = _StandInTexture.new(pane_viewport.size)
		root.add_child(pane_target)
		host.set_viewport_for(pane_id, pane_target)
		ortho_targets[pane_id] = pane_target

	# Timed from the mesh arriving, because handing it to the panes used to
	# cost as much as capturing them.
	# Anything the overlays drew before the shell arrived is not this repro's;
	# the counters run for the silhouette's whole life, so the baseline is
	# taken here and subtracted below.
	var builds_before := 0
	var projections_before := 0
	for pane_id in ORTHO_PANES:
		var before: Control = panel._geometry_overlays[pane_id] as Control
		builds_before += before._silhouette.adjacency_builds()
		projections_before += before._silhouette.projections()

	var burst_started := Time.get_ticks_msec()
	panel._last_mesh_data = shell
	panel._edge_registry = []
	panel._push_mesh_to_geometry_overlays()
	var round_ms := PackedInt32Array()
	var captured := 0
	var outline_segments := 0
	for burst_round in range(ORTHO_BURST):
		var round_started := Time.get_ticks_msec()
		for pane_id in ORTHO_PANES:
			var overlay: Control = panel._geometry_overlays[pane_id] as Control
			# What the pane's own draw costs — the wait a read of its render
			# target sits behind, and the one thing iso never pays.
			var points: PackedVector2Array = overlay._silhouette.points_for(
				panel.get_view_camera(pane_id), overlay.size)
			outline_segments = maxi(outline_segments, int(points.size() / 2))
			if host.render_view_to_image(pane_id, Rect2()) != null:
				captured += 1
		round_ms.append(Time.get_ticks_msec() - round_started)
	var burst_ms := Time.get_ticks_msec() - burst_started

	var iso_overlay: Control = panel._geometry_overlays["iso"] as Control
	check("fixture: the three panes showing a direction hold the shell the "
			+ "report was made on — %d+ vertices, " % ORTHO_MIN_VERTICES
			+ "an outline of it drawn in each — while the iso pane, which "
			+ "draws no outline, has walked no edge of it",
			(shell["vertices"] as Array).size() >= ORTHO_MIN_VERTICES
				and outline_segments > 0
				and iso_overlay._silhouette.edge_count() == 0,
			"%d vertices, %d outline segments, iso walked %d edges" % [
				(shell["vertices"] as Array).size(), outline_segments,
				iso_overlay._silhouette.edge_count()])

	check("the repro: %d consecutive captures of each of top, front and right "
			% ORTHO_BURST + "all answer with an image, and the mesh arriving "
			+ "plus every one of them stays inside a %d ms ceiling — a "
			% ORTHO_BUDGET_MS + "sanity bound on a hang, not a performance "
			+ "oracle; what the work actually costs is counted below",
			captured == ORTHO_BURST * ORTHO_PANES.size()
				and burst_ms < ORTHO_BUDGET_MS,
			"%d of %d captured in %d ms" % [
				captured, ORTHO_BURST * ORTHO_PANES.size(), burst_ms])

	# WHAT THE REPEAT ROUNDS COST, COUNTED. A wall clock cannot say this: a
	# loaded machine makes the first round cheap or the last one dear, and the
	# comparison flips without anything about the panel changing. The two
	# caches have their own counters, and the claim is exact — over
	# ORTHO_BURST rounds of the same mesh, the same cameras and the same pane
	# sizes, each pane walks its adjacency ONCE and projects its edges ONCE,
	# so every round after the first walks and projects nothing at all.
	var builds := 0
	var projections := 0
	for pane_id in ORTHO_PANES:
		var overlay: Control = panel._geometry_overlays[pane_id] as Control
		builds += overlay._silhouette.adjacency_builds()
		projections += overlay._silhouette.projections()
	builds -= builds_before
	projections -= projections_before
	check("and the wait is named: over %d rounds of the same mesh, the same "
			% ORTHO_BURST + "cameras and the same pane sizes, each of the "
			+ "three panes walked its adjacency once and projected once — "
			+ "the rounds after the first drew the outline from the cache",
			round_ms.size() == ORTHO_BURST
				and builds == ORTHO_PANES.size()
				and projections == ORTHO_PANES.size(),
			"%d builds, %d projections over %d panes; rounds %s ms" % [
				builds, projections, ORTHO_PANES.size(), str(round_ms)])
	print("    ortho: %d segments, mesh + %d rounds in %d ms, %d builds, "
		% [outline_segments, ORTHO_BURST, burst_ms, builds]
		+ "%d projections, rounds %s" % [projections, str(round_ms)])

	# ── The narrow layout: one pane, one projection, one honest answer ────
	panel._apply_width_class(&"sm")
	await process_frame
	var single_viewport: SubViewport = panel.get_node("%s/SubViewport" % SINGLE_VIEW)
	var single_camera: Camera3D = panel.get_node("%s/SubViewport/OrbitCamera" % SINGLE_VIEW)
	var narrow_target := _StandInViewport.new()
	narrow_target.texture = _ProjectionTexture.new(single_viewport.size, single_camera)
	root.add_child(narrow_target)
	for pane_id in NARROW_PANE_IDS:
		host.set_viewport_for(pane_id, narrow_target)

	# Two directions the one pane can be pointed in, sampled off the stand-in
	# itself: if these were the same colour the repro below could not tell a
	# genuine capture from the wrong one.
	single_camera.set_view_preset("Top")
	var top_colour: Color = narrow_target.texture.get_image().get_pixel(0, 0)
	single_camera.set_view_preset("Perspective")
	var perspective_colour: Color = narrow_target.texture.get_image().get_pixel(0, 0)
	panel._on_projection_selected(_PaneProjection.index_of("Perspective"))
	check("fixture: narrow layout is showing its single pane, the wide grid is "
			+ "hidden, and the pane paints a different picture pointed at Top "
			+ "than at Perspective",
			panel._narrow_layout.visible and not panel._wide_layout.visible
				and host.get_active_viewport() == "perspective"
				and top_colour != perspective_colour,
			"narrow=%s wide=%s active=%s top=%s perspective=%s" % [
				str(panel._narrow_layout.visible), str(panel._wide_layout.visible),
				host.get_active_viewport(), str(top_colour), str(perspective_colour)])

	var active_shot: Image = host.render_view_to_image("perspective", Rect2())
	check("the pane that IS on screen captures, and the picture is of the "
			+ "projection it is pointed at",
			active_shot != null
				and active_shot.get_pixel(0, 0) == perspective_colour,
			"got %s" % ("null" if active_shot == null
				else str(active_shot.get_pixel(0, 0))))

	var not_on_screen: Image = host.render_view_to_image("top", Rect2())
	check("the repro: asking for Top while the pane shows Perspective is "
			+ "refused — the caller is never handed the perspective picture "
			+ "under the name it did not ask for",
			not_on_screen == null,
			"got an image, %s the perspective capture" % (
				"" if not_on_screen == null or active_shot == null
				else ("identical to"
					if not_on_screen.get_pixel(0, 0) == active_shot.get_pixel(0, 0)
					else "differing from")))

	panel._on_projection_selected(_PaneProjection.index_of("Top"))
	var top_shot: Image = host.render_view_to_image("top", Rect2())
	check("and once the pane really is pointed at Top the same request is "
			+ "answered with a Top capture, which is not the perspective one",
			top_shot != null and top_shot.get_pixel(0, 0) == top_colour
				and top_shot.get_pixel(0, 0) != perspective_colour,
			"got %s, wanted %s" % ["null" if top_shot == null
				else str(top_shot.get_pixel(0, 0)), str(top_colour)])

	var gone_from_screen: Image = host.render_view_to_image("perspective", Rect2())
	check("while Perspective, no longer on screen, is now the refused one — "
			+ "the capture taken of it a moment ago is not served for it again",
			gone_from_screen == null,
			"got an image for a projection the pane is not showing")

	narrow_target.free()
	for pane_id in ORTHO_PANES:
		(ortho_targets[pane_id] as Node).free()
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
