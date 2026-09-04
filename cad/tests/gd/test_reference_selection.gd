extends SceneTree
## Pointing at a reference mesh: the click, the selection, the sidebar, the MCP
## readback and the point anchor that follows the reference.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The fixture is BUILT here and written to a temporary GLB, so no mesh binary
## is checked in and every expected number is one the test wrote. It is
## declared units="mm" up="z" so the conversion is the identity: the frame
## conversion has its own suite (test_reference_meshes.gd) and this one is
## about WHICH node was hit and WHERE on it, which a conversion in the middle
## would only obscure.
##
## Two boxes, far enough apart that a ray hits exactly one of them:
##   Plate  40 x 30 x 4  at the origin       -> x[-20,20] y[-15,15] z[-2,2]
##   Post    6 x  6 x 20 at (12, 8, 12)      -> x[9,15]  y[5,11]  z[2,22]
## posed by rotate 90 about Z then translate (100, 200, 300), which sends the
## reference-frame point (x, y, z) to (-y + 100, x + 200, z + 300).
##
## Pixels are never hard-coded. A click pixel is derived by projecting a known
## world point through the pane's own camera, and the pick must give that same
## point back — a round trip that fails for a picker that ignores the pose, the
## part transform, or the node the triangle belonged to.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const ReferenceSelection := preload("res://../../minerva-plugins/cad/ui/scripts/reference_selection.gd")
const CadPointAnchor := preload("res://../../minerva-plugins/cad/ui/scripts/CadPointAnchor.gd")

const TOLERANCE_MM := 0.01
const TOLERANCE_PX := 1.0

## The two nodes, in the reference file's own frame (millimetres).
const PLATE_LOCAL_MIN := Vector3(-20.0, -15.0, -2.0)
const PLATE_LOCAL_MAX := Vector3(20.0, 15.0, 2.0)
const POST_LOCAL_MIN := Vector3(9.0, 5.0, 2.0)
const POST_LOCAL_MAX := Vector3(15.0, 11.0, 22.0)

## The same two, posed: (x, y, z) -> (-y + 100, x + 200, z + 300).
const PLATE_WORLD_MIN := Vector3(85.0, 180.0, 298.0)
const PLATE_WORLD_MAX := Vector3(115.0, 220.0, 302.0)
const POST_WORLD_MIN := Vector3(89.0, 209.0, 302.0)
const POST_WORLD_MAX := Vector3(95.0, 215.0, 322.0)

## The point the click is aimed at: the centre of the Post's top face.
const POST_TOP_LOCAL := Vector3(12.0, 8.0, 22.0)
const POST_TOP_WORLD := Vector3(92.0, 212.0, 322.0)
## A point on the Plate's top face, well clear of the Post.
const PLATE_TOP_LOCAL := Vector3(-10.0, -6.0, 2.0)
const PLATE_TOP_WORLD := Vector3(106.0, 190.0, 302.0)

## rotate([0, 0, 90]) then translate([100, 200, 300]), row-major, exactly as
## the worker reports it in references[].matrix.
const POSE_ROTATE_TRANSLATE := [
	[0.0, -1.0, 0.0, 100.0],
	[1.0, 0.0, 0.0, 200.0],
	[0.0, 0.0, 1.0, 300.0],
	[0.0, 0.0, 0.0, 1.0],
]

## A second pose — translate (5, 0, 0) only — so the same anchor lands
## somewhere hand-derivable: local (x, y, z) -> (x + 5, y, z).
const POSE_TRANSLATE_ONLY := [
	[1.0, 0.0, 0.0, 5.0],
	[0.0, 1.0, 0.0, 0.0],
	[0.0, 0.0, 1.0, 0.0],
	[0.0, 0.0, 0.0, 1.0],
]
const POST_TOP_WORLD_REPOSED := Vector3(17.0, 8.0, 22.0)

## A pose that ROTATES THE NORMAL: 90 degrees about X, so the reference frame's
## +Z becomes the world's +Y. The suite's other poses turn about Z or only
## translate, under which the Post's top-face normal is invariant — and a
## normal stored in the wrong frame is invisible under an invariant.
## (x, y, z) -> (x, z, -y).
const POSE_ROTATE_X := [
	[1.0, 0.0, 0.0, 0.0],
	[0.0, 0.0, 1.0, 0.0],
	[0.0, -1.0, 0.0, 0.0],
	[0.0, 0.0, 0.0, 1.0],
]

## Two branches of the fixture, each with a node named "Body". Placed well
## clear of the Plate and the Post so no click can land on them by accident,
## and given DIFFERENT sizes so merged bounds are visibly merged.
const TWIN_LEAF := "Body"
const TWIN_BRANCHES := [
	{"branch": "Left", "at": Vector3(-50.0, 0.0, 0.0), "size": Vector3(4.0, 4.0, 4.0)},
	{"branch": "Right", "at": Vector3(50.0, 0.0, 0.0), "size": Vector3(10.0, 10.0, 10.0)},
]

var _pass: int = 0
var _fail: int = 0
var _glb_path: String = ""
var _panel: Node = null
var _camera: Camera3D = null


func _init() -> void:
	print("=== CAD Reference Selection / Point Anchor Test ===\n")
	await process_frame

	_glb_path = OS.get_user_data_dir().path_join("cad_selection_fixture.glb")
	var written := _write_fixture_glb(_glb_path)
	check("setup: the fixture GLB is written", written,
			"GLTFDocument could not write %s" % _glb_path)
	if written:
		await _run()

	_cleanup()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_panel = _make_panel()
	if _panel == null:
		return
	# The panes have to have a rendered size for a pixel to mean anything.
	_panel.size = Vector2(1200.0, 800.0)
	await process_frame

	_mount(POSE_ROTATE_TRANSLATE)
	await process_frame
	_prepare_top_camera()

	_test_the_nodes_are_listed()
	await _test_two_branches_can_share_a_leaf_name()
	_test_a_click_selects_the_node_under_it()
	await _test_the_mcp_path_reads_the_click_back()
	await _test_the_click_normal_is_stored_in_the_reference_frame()
	await _test_a_point_anchor_follows_its_reference()
	_test_edge_selection_and_node_selection_do_not_fight()


# ---------------------------------------------------------------------------
# Two nodes, one leaf name
# ---------------------------------------------------------------------------

## "Left/Body" and "Right/Body" are two parts. Merging their bounds, or letting
## a filter that says "Body" mean both, is the difference between measuring the
## bracket the user meant and measuring a box that spans the whole assembly.
func _test_two_branches_can_share_a_leaf_name() -> void:
	var entries := ReferenceSelection.node_entries(_panel.get_reference_state())
	var left := _entry_by_path(entries, "Left/Body")
	var right := _entry_by_path(entries, "Right/Body")
	var left_box: AABB = left.get("local_aabb", AABB())
	var right_box: AABB = right.get("local_aabb", AABB())
	check("two nodes sharing a leaf name keep separate bounds",
			not left.is_empty() and not right.is_empty()
				and absf(left_box.size.x - 4.0) < TOLERANCE_MM
				and absf(right_box.size.x - 10.0) < TOLERANCE_MM,
			"left %s right %s" % [str(left_box), str(right_box)])
	check("and both still report the leaf name they share",
			str(left.get("node", "")) == TWIN_LEAF and str(right.get("node", "")) == TWIN_LEAF,
			"left '%s' right '%s'" % [str(left.get("node", "")), str(right.get("node", ""))])

	# The path selects exactly one of them; nothing else in the reply could.
	var chosen: Dictionary = await _panel.handle_tool(
		"minerva_cad_select_reference", {"reference": "ref1", "node": "Right/Body"})
	check("selecting by path picks the branch it names, not the first match",
			bool(chosen.get("success", false))
				and str(chosen.get("node", "")) == "Right/Body"
				and absf(float((chosen.get("size_mm", []) as Array)[0]) - 10.0) < TOLERANCE_MM,
			"got %s" % str(chosen))


# ---------------------------------------------------------------------------
# The frame the normal is stored in
# ---------------------------------------------------------------------------

## CadPointAnchor.build declares `normal` in the REFERENCE's frame. A normal
## stored in world coordinates instead is either transformed twice on resolve
## or left pointing where the mesh used to face; either way it looks right
## until the pose turns, so the re-pose here is one that actually turns it.
func _test_the_click_normal_is_stored_in_the_reference_frame() -> void:
	_click("top", _camera.unproject_position(POST_TOP_WORLD))
	var selection: Dictionary = _panel.get_reference_selection()
	check("the click's normal is stored in the reference's own frame",
			_near(selection.get("normal", Vector3.ZERO), Vector3(0.0, 0.0, 1.0))
				and _near(selection.get("normal_world", Vector3.ZERO), Vector3(0.0, 0.0, 1.0)),
			"local %s world %s" % [str(selection.get("normal", Vector3.ZERO)),
				str(selection.get("normal_world", Vector3.ZERO))])

	var anchor: Dictionary = _panel.get_annotation_host().get_current_selection_anchor("cad/point")

	# Turn the reference 90 degrees about X: the top face now looks along +Y.
	_mount(POSE_ROTATE_X)
	var reported: Dictionary = await _panel.handle_tool(
		"minerva_cad_get_selected_reference", {})
	var normal: Dictionary = reported.get("normal", {})
	check("re-posing the reference turns the normal in the world and leaves it "
			+ "alone in the file's frame",
			_near(_vec3(normal.get("local", [])), Vector3(0.0, 0.0, 1.0))
				and _near(_vec3(normal.get("world", [])), Vector3(0.0, 1.0, 0.0)),
			"got %s" % str(normal))

	var resolved: Variant = _panel.get_annotation_host().resolve_point_anchor(anchor)
	check("an anchor made before the re-pose resolves to the turned normal too",
			resolved is Dictionary
				and _near((resolved as Dictionary).get("normal", Vector3.ZERO),
					Vector3(0.0, 1.0, 0.0)),
			"got %s" % str(resolved))

	_mount(POSE_ROTATE_TRANSLATE)


# ---------------------------------------------------------------------------
# The sidebar and the node inventory
# ---------------------------------------------------------------------------

func _test_the_nodes_are_listed() -> void:
	var records: Array = _panel.get_reference_state()
	check("the reference mounts", records.size() == 1,
			"expected 1 mounted reference, got %d" % records.size())
	if records.is_empty():
		return

	var entries := ReferenceSelection.node_entries(records)
	var paths := PackedStringArray()
	for entry in entries:
		paths.append(str((entry as Dictionary)["node_path"]))
	paths.sort()
	# The node names are the vocabulary the user and the LLM share; if the glTF
	# round trip renamed them, every other verb's `node` argument is a guess.
	# The identity is the PATH from the file root — two of these nodes are both
	# called "Body" and only the path separates them.
	check("the file's node paths survive the round trip",
			Array(paths) == ["Left/Body", "Plate", "Post", "Right/Body"],
			"got %s" % str(Array(paths)))

	var post := _entry_for(entries, "Post")
	var plate := _entry_for(entries, "Plate")
	check("the Post's world bounds are its posed bounds",
			_box_matches(post.get("world_aabb", AABB()), POST_WORLD_MIN, POST_WORLD_MAX),
			"got %s" % str(post.get("world_aabb", AABB())))
	check("the Plate's world bounds are its posed bounds",
			_box_matches(plate.get("world_aabb", AABB()), PLATE_WORLD_MIN, PLATE_WORLD_MAX),
			"got %s" % str(plate.get("world_aabb", AABB())))
	check("node bounds are also reported in the reference's own frame",
			_box_matches(post.get("local_aabb", AABB()), POST_LOCAL_MIN, POST_LOCAL_MAX),
			"got %s" % str(post.get("local_aabb", AABB())))

	# The sidebar is scene-declared; this is the row the user actually reads.
	var sidebar: Node = _panel.find_child("ReferencePanel", true, false)
	check("the wide sidebar declares a reference panel", sidebar != null)
	var tree: Tree = (sidebar.get_node_or_null("ReferenceTree") as Tree) if sidebar != null else null
	var rows := _tree_rows(tree)
	check("the sidebar lists one row per node under the reference, by path",
			rows.size() == 4 and rows.has("Left/Body") and rows.has("Right/Body"),
			"got %d rows: %s" % [rows.size(), str(rows)])
	check("the sidebar shows the Plate's size in world millimetres",
			rows.get("Plate", "") == "30.0 x 40.0 x 4.0",
			"got '%s'" % str(rows.get("Plate", "")))


# ---------------------------------------------------------------------------
# The click
# ---------------------------------------------------------------------------

func _test_a_click_selects_the_node_under_it() -> void:
	var pixel := _camera.unproject_position(POST_TOP_WORLD)
	check("setup: the aimed point projects inside the top pane",
			_inside_pane(pixel), "pixel %s, pane %s" % [str(pixel), str(_pane_size())])

	var handled := _click("top", pixel)
	check("a click on the Post selects a reference node", handled)

	var selection: Dictionary = _panel.get_reference_selection()
	check("the click selects the node it landed on",
			str(selection.get("reference", "")) == "ref1"
				and str(selection.get("node", "")) == "Post",
			"got %s/%s" % [str(selection.get("reference", "")), str(selection.get("node", ""))])
	check("the click reports the surface point in the reference's own frame",
			_near(selection.get("local", Vector3.ZERO), POST_TOP_LOCAL),
			"got %s" % str(selection.get("local", Vector3.ZERO)))
	check("the click reports the same point in the posed world",
			_near(selection.get("world", Vector3.ZERO), POST_TOP_WORLD),
			"got %s" % str(selection.get("world", Vector3.ZERO)))
	check("the selection carries the node's bounds, not the whole file's",
			_box_matches(selection.get("world_aabb", AABB()), POST_WORLD_MIN, POST_WORLD_MAX),
			"got %s" % str(selection.get("world_aabb", AABB())))
	check("the selection remembers which pane the click came from",
			str(selection.get("view", "")) == "top" and str(selection.get("source", "")) == "click",
			"view=%s source=%s" % [str(selection.get("view", "")), str(selection.get("source", ""))])

	# The other body, through the same path: a picker that returns the first
	# part it meets rather than the one the ray hit passes the test above and
	# fails this one.
	var plate_pixel := _camera.unproject_position(PLATE_TOP_WORLD)
	_click("top", plate_pixel)
	var plate_selection: Dictionary = _panel.get_reference_selection()
	check("a click on the Plate selects the Plate, not the Post",
			str(plate_selection.get("node", "")) == "Plate",
			"got '%s'" % str(plate_selection.get("node", "")))
	check("its point is on the Plate's top face",
			_near(plate_selection.get("local", Vector3.ZERO), PLATE_TOP_LOCAL),
			"got %s" % str(plate_selection.get("local", Vector3.ZERO)))

	# Empty space inside the pane: nothing is hit, so nothing stays selected —
	# and the click is NOT consumed, so the camera still gets it.
	var empty_pixel := _camera.unproject_position(
		Vector3(PLATE_WORLD_MAX.x + 4.0, PLATE_WORLD_MAX.y + 4.0, 300.0))
	# handle_click's own verdict is what the click node uses to decide whether
	# to consume the event, so a miss must answer false: the camera still needs
	# that click.
	var consumed: bool = _panel._reference_selection.handle_click("top", empty_pixel)
	_click("top", empty_pixel)
	check("a click on empty space clears the selection and is not consumed",
			_inside_pane(empty_pixel) and not consumed
				and _panel.get_reference_selection().is_empty(),
			"inside_pane=%s consumed=%s selection=%s" % [
				str(_inside_pane(empty_pixel)), str(consumed),
				str(_panel.get_reference_selection())])


# ---------------------------------------------------------------------------
# The MCP readback
# ---------------------------------------------------------------------------

func _test_the_mcp_path_reads_the_click_back() -> void:
	_click("top", _camera.unproject_position(POST_TOP_WORLD))

	var result: Dictionary = await _panel.handle_tool("minerva_cad_get_selected_reference", {})
	check("minerva_cad_get_selected_reference reports the click",
			bool(result.get("success", false)) and bool(result.get("selected", false))
				and str(result.get("node", "")) == "Post",
			"got %s" % str(result))
	var point: Dictionary = result.get("point_mm", {})
	check("the verb reports the point in both frames",
			_near(_vec3(point.get("world", [])), POST_TOP_WORLD)
				and _near(_vec3(point.get("local", [])), POST_TOP_LOCAL),
			"got %s" % str(point))
	var bounds: Dictionary = result.get("bounds_mm", {}).get("world", {})
	check("the verb reports the selected node's world bounds",
			_near(_vec3(bounds.get("min", [])), POST_WORLD_MIN)
				and _near(_vec3(bounds.get("max", [])), POST_WORLD_MAX),
			"got %s" % str(bounds))
	# A box has no holes. A "nearest hole" for a flat face would mean the
	# containment test is not testing containment.
	check("a click on a plain face reports no hole",
			result.get("nearest_hole", null) == null,
			"got %s" % str(result.get("nearest_hole", null)))

	var chosen: Dictionary = await _panel.handle_tool(
		"minerva_cad_select_reference", {"reference": "ref1", "node": "Plate"})
	check("minerva_cad_select_reference selects a node by name at its centre",
			bool(chosen.get("success", false))
				and str(chosen.get("node", "")) == "Plate"
				and str(chosen.get("point_source", "")) == "bounds_centre"
				and _near(_vec3(chosen.get("point_mm", {}).get("world", [])),
						Vector3(100.0, 200.0, 300.0)),
			"got %s" % str(chosen))

	var missing: Dictionary = await _panel.handle_tool(
		"minerva_cad_select_reference", {"reference": "ref1", "node": "NoSuchNode"})
	check("selecting a node that does not exist is an error, not a guess",
			not bool(missing.get("success", true)) and missing.has("error"),
			"got %s" % str(missing))


# ---------------------------------------------------------------------------
# The point anchor
# ---------------------------------------------------------------------------

func _test_a_point_anchor_follows_its_reference() -> void:
	_click("top", _camera.unproject_position(POST_TOP_WORLD))
	var host: Object = _panel.get_annotation_host()

	var anchor: Dictionary = host.get_current_selection_anchor("cad/point")
	check("the selection offers itself as a cad/point anchor",
			str(anchor.get("plugin", "")) == "cad" and str(anchor.get("type", "")) == "point"
				and str(anchor.get("reference", "")) == "ref1"
				and str(anchor.get("node", "")) == "Post",
			"got %s" % str(anchor))

	# A callout anchored to that point. add_annotation validates against the
	# registry, so an id coming back is the schema accepting the envelope.
	var annotation_id: String = host.add_annotation({
		"kind": "callout",
		"anchor": anchor,
		"kind_payload": {"text": "this post"},
	})
	check("an annotation anchored to the point validates and is stored",
			not annotation_id.is_empty() and host.get_annotations().size() == 1,
			"id='%s' count=%d" % [annotation_id, host.get_annotations().size()])

	var resolved: Variant = host.resolve_point_anchor(anchor)
	check("the anchor resolves to the point it was made on",
			resolved is Dictionary
				and _near((resolved as Dictionary).get("position", Vector3.ZERO), POST_TOP_WORLD)
				and not bool((resolved as Dictionary).get("stale", true)),
			"got %s" % str(resolved))

	# The screen position the anchor resolves to now, used below as the
	# baseline for the re-pose. It is the projection of the assertion above,
	# not a second measurement of it.
	var screen_before: Vector2 = _camera.unproject_position(
		(resolved as Dictionary).get("position", Vector3.ZERO))

	# Re-pose the reference, exactly as an edit to the mesh() line would.
	_mount(POSE_TRANSLATE_ONLY)
	var moved: Variant = host.resolve_point_anchor(anchor)
	check("re-posing the reference moves the anchor with it",
			moved is Dictionary
				and _near((moved as Dictionary).get("position", Vector3.ZERO), POST_TOP_WORLD_REPOSED),
			"got %s" % str(moved))

	# The screen delta, derived from the orthographic projection itself rather
	# than from the code under test: pixels per millimetre times the world
	# displacement resolved on the camera's own right/up axes.
	var screen_after: Vector2 = _camera.unproject_position(
		(moved as Dictionary).get("position", Vector3.ZERO))
	var per_mm := float(_pane_size().y) / _camera.size
	var displacement := POST_TOP_WORLD_REPOSED - POST_TOP_WORLD
	var basis := _camera.global_transform.basis
	var expected_delta := Vector2(
		displacement.dot(basis.x) * per_mm,
		-displacement.dot(basis.y) * per_mm)
	check("the annotation moves on screen by the projected displacement",
			(screen_after - screen_before).distance_to(expected_delta) <= TOLERANCE_PX,
			"measured %s, expected %s" % [str(screen_after - screen_before), str(expected_delta)])

	# The reference leaves the document: the anchor is marked, not stranded and
	# not fatal.
	_mount_none()
	var stale: Variant = host.resolve_point_anchor(anchor)
	check("removing the reference marks the anchor stale",
			stale is Dictionary and bool((stale as Dictionary).get("stale", false)),
			"got %s" % str(stale))
	check("a stale anchor keeps its last known position instead of jumping to the origin",
			stale is Dictionary
				and _near((stale as Dictionary).get("position", Vector3.ZERO), POST_TOP_WORLD),
			"got %s" % str(stale))
	check("the annotation survives its reference going away",
			host.get_annotations().size() == 1,
			"got %d annotations" % host.get_annotations().size())
	var via_substrate: Dictionary = host.resolve_anchor(anchor)
	check("the substrate resolves cad/point through the registered resolver",
			bool(via_substrate.get("stale", false)) and via_substrate.get("position", null) is Vector2,
			"got %s" % str(via_substrate))
	check("a selection whose reference is gone is reported stale, not silently kept",
			bool(_panel.get_reference_selection().get("stale", false)),
			"got %s" % str(_panel.get_reference_selection()))

	# Put the reference back for the last group.
	_mount(POSE_ROTATE_TRANSLATE)


# ---------------------------------------------------------------------------
# Two selections, no fight
# ---------------------------------------------------------------------------

func _test_edge_selection_and_node_selection_do_not_fight() -> void:
	var click_node := _click_node_for("top")
	check("the node picker cannot intercept a GUI click: it is a plain Node "
			+ "that only sees unhandled input",
			click_node != null and not (click_node is Control)
				and click_node.has_method("_unhandled_input")
				and not click_node.has_method("_gui_input"))

	_click("top", _camera.unproject_position(POST_TOP_WORLD))
	var before: Dictionary = _panel.get_reference_selection()

	# The edge path, untouched: a worker edge registry pushed through the
	# panel's own wiring, then a click on the projected edge.
	var start := Vector3(90.0, 205.0, 305.0)
	var finish := Vector3(110.0, 205.0, 305.0)
	_panel._edge_registry = [{
		"id": 7,
		"kind": "straight",
		"start": [start.x, start.y, start.z],
		"end": [finish.x, finish.y, finish.z],
		"length": 20.0,
	}]
	_panel._push_mesh_to_geometry_overlays()
	var overlay: Control = _panel._geometry_overlays["top"] as Control
	var midpoint := _camera.unproject_position(start.lerp(finish, 0.5))
	overlay._gui_input(_mouse_event(midpoint))

	check("clicking an edge still selects the edge",
			_panel.get_annotation_host().get_selected_edge_id() == 7,
			"got %d" % _panel.get_annotation_host().get_selected_edge_id())
	var after: Dictionary = _panel.get_reference_selection()
	check("selecting an edge leaves the reference-node selection alone",
			str(after.get("node", "")) == str(before.get("node", ""))
				and _near(after.get("world", Vector3.ONE), before.get("world", Vector3.ZERO)),
			"before=%s after=%s" % [str(before.get("node", "")), str(after.get("node", ""))])


# ---------------------------------------------------------------------------
# Fixture and helpers
# ---------------------------------------------------------------------------

func _make_panel() -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	var panel: Node = packed.instantiate() if packed != null else null
	check("setup: the CAD panel scene instantiates", panel != null,
			"could not instantiate %s" % PANEL_SCENE_PATH)
	if panel != null:
		root.add_child(panel)
	return panel


## Mount the fixture at a pose, the way an evaluation does.
func _mount(matrix: Array) -> void:
	_panel._mount_references([{
		"name": "ref1",
		"path": _glb_path,
		"units": "mm",
		"up": "z",
		"matrix": matrix,
	}])


func _mount_none() -> void:
	_panel._mount_references([])


## Point the top pane at the fixture so the projected pixels land in it.
func _prepare_top_camera() -> void:
	_camera = _panel.get_node_or_null(
		"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/TopView/SubViewport/OrbitCamera")
	check("setup: the top pane has a camera and a rendered size",
			_camera != null and _pane_size().x > 0.0 and _pane_size().y > 0.0,
			"camera=%s pane=%s" % [str(_camera), str(_pane_size())])
	if _camera == null:
		return
	_camera.set_view_preset("Top")
	_camera.set_target(Vector3(100.0, 200.0, 300.0))
	_camera.set_distance(120.0)


func _click(view_id: String, pixel: Vector2) -> bool:
	var node := _click_node_for(view_id)
	if node == null:
		return false
	node._unhandled_input(_mouse_event(pixel))
	return not _panel.get_reference_selection().is_empty()


func _mouse_event(pixel: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pixel
	return event


func _click_node_for(view_id: String) -> Node:
	for node in _panel.find_children("ReferenceClickRoot", "", true, false):
		if str(node.view_id) == view_id:
			return node
	return null


func _pane_size() -> Vector2:
	var viewport := _camera.get_viewport() if _camera != null else null
	return Vector2(viewport.size) if viewport != null else Vector2.ZERO


func _inside_pane(pixel: Vector2) -> bool:
	var size := _pane_size()
	return pixel.x >= 0.0 and pixel.y >= 0.0 and pixel.x < size.x and pixel.y < size.y


func _entry_for(entries: Array, node_name: String) -> Dictionary:
	for entry in entries:
		if str((entry as Dictionary).get("node", "")) == node_name:
			return entry
	return {}


## node name -> the size column, read straight off the live Tree.
func _tree_rows(tree: Tree) -> Dictionary:
	var out := {}
	if tree == null:
		return out
	var root_item := tree.get_root()
	if root_item == null:
		return out
	var reference_item := root_item.get_first_child()
	while reference_item != null:
		var node_item := reference_item.get_first_child()
		while node_item != null:
			out[node_item.get_text(0)] = node_item.get_text(1)
			node_item = node_item.get_next()
		reference_item = reference_item.get_next()
	return out


func _write_fixture_glb(path: String) -> bool:
	var scene_root := Node3D.new()
	scene_root.name = "Scene"

	var plate_mesh := BoxMesh.new()
	plate_mesh.size = PLATE_LOCAL_MAX - PLATE_LOCAL_MIN
	var plate := MeshInstance3D.new()
	plate.name = "Plate"
	plate.mesh = plate_mesh
	plate.position = (PLATE_LOCAL_MIN + PLATE_LOCAL_MAX) * 0.5
	scene_root.add_child(plate)

	var post_mesh := BoxMesh.new()
	post_mesh.size = POST_LOCAL_MAX - POST_LOCAL_MIN
	var post := MeshInstance3D.new()
	post.name = "Post"
	post.mesh = post_mesh
	post.position = (POST_LOCAL_MIN + POST_LOCAL_MAX) * 0.5
	scene_root.add_child(post)

	# Two branches, each holding a node called "Body". Foreign assemblies do
	# this constantly, and a leaf name alone cannot tell the two apart.
	for side in TWIN_BRANCHES:
		var branch := Node3D.new()
		branch.name = str((side as Dictionary)["branch"])
		branch.position = (side as Dictionary)["at"]
		scene_root.add_child(branch)
		var body_mesh := BoxMesh.new()
		body_mesh.size = (side as Dictionary)["size"]
		var body := MeshInstance3D.new()
		body.name = TWIN_LEAF
		body.mesh = body_mesh
		branch.add_child(body)

	root.add_child(scene_root)
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var appended := document.append_from_scene(scene_root, state)
	var written := ERR_BUG
	if appended == OK:
		written = document.write_to_filesystem(state, path)
	root.remove_child(scene_root)
	scene_root.free()
	return appended == OK and written == OK


func _cleanup() -> void:
	if _panel != null and is_instance_valid(_panel):
		root.remove_child(_panel)
		_panel.free()
	if not _glb_path.is_empty() and FileAccess.file_exists(_glb_path):
		DirAccess.remove_absolute(_glb_path)


## The node_entries row with this path, or {}.
func _entry_by_path(entries: Array, path: String) -> Dictionary:
	for entry in entries:
		if str((entry as Dictionary).get("node_path", "")) == path:
			return entry
	return {}


func _vec3(raw: Variant) -> Vector3:
	return CadPointAnchor.vec3_from(raw)


func _near(a: Variant, b: Vector3) -> bool:
	if not (a is Vector3):
		return false
	return (a as Vector3).distance_to(b) <= TOLERANCE_MM


func _box_matches(box: AABB, expected_min: Vector3, expected_max: Vector3) -> bool:
	return box.position.distance_to(expected_min) <= TOLERANCE_MM \
		and box.end.distance_to(expected_max) <= TOLERANCE_MM


func check(desc: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
