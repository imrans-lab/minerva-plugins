extends SceneTree
## Every pane can be pointed anywhere, and still says where it is pointed.
##
## The narrow layout has always had a dropdown over its single pane. The wide
## layout — the one the owner inspects in — had four panes wired to fixed
## directions, so the underside of a part could only be seen by collapsing to
## one pane and back. This suite drives the SAME dropdown, now once per wide
## pane, and asks the two questions that make it useful: does the pane's camera
## actually move, and do the verbs that address panes by SLOT ("top") report
## what that slot is now looking at?
##
## ORACLE. What would show this wrong: point the "top" pane at Bottom and take
## a picture — if the picture is unchanged, or the reply still says the pane is
## looking down, the dropdown is decoration. The checks below stand in for that
## picture with the camera's own placement (below the part, looking up) and the
## pane metrics the snapshot caller reads.
##
## Run:
##   cd <minerva>/src && godot --headless -s res://../../minerva-plugins/cad/tests/gd/test_pane_projection.gd

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const PaneProjection := preload("res://../../minerva-plugins/cad/ui/scripts/pane_projection.gd")

const GRID := "ResponsiveContainer/WideLayout/VBoxContainer/GridContainer"
const PANE_NODES := {
	"top": "TopView", "front": "FrontView", "right": "RightView", "iso": "IsoView",
}
## Where each slot starts out looking from.
const DEFAULTS := {
	"top": "Top", "front": "Front", "right": "Right", "iso": "Perspective",
}
## Dropdown index of "Bottom" in the shared option list.
const BOTTOM_INDEX := 2

var _pass: int = 0
var _fail: int = 0


class _EditorStub extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== CAD Pane Projection Test (a pane looks where it is pointed) ===\n")
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
	await process_frame
	# A panel with no width measured yet starts on the smallest class; the
	# layout under test is the wide one.
	panel._apply_width_class(&"lg")
	await process_frame

	check("fixture: the panel is in WIDE layout, the one with four panes",
			not panel._narrow_layout.visible and panel._wide_layout.visible,
			"narrow layout is showing; the pane dropdowns would not be reachable")

	# ── The control itself ────────────────────────────────────────────────
	var dropdowns := {}
	for slot in PANE_NODES.keys():
		dropdowns[slot] = panel.get_node_or_null(
			"%s/%s/ProjectionRow/ProjectionDropdown" % [GRID, PANE_NODES[slot]]) as OptionButton
	check("each of the four wide panes carries a projection dropdown",
			dropdowns.values().all(func(d): return d != null),
			"found %s" % str(dropdowns))
	if dropdowns.values().any(func(d): return d == null):
		panel.free()
		return

	# The row rides ON the pane, the way a viewport label does in a CAD tool.
	# A SubViewportContainer sizes only its SubViewport children, so the row
	# keeps its own small rect instead of being stretched over the picture —
	# and the picture itself, which is what a snapshot captures, is unchanged.
	panel.size = Vector2(1400, 900)
	await process_frame
	await process_frame
	var pane: Control = panel.get_node("%s/TopView" % GRID)
	var row: Control = panel.get_node("%s/TopView/ProjectionRow" % GRID)
	var pane_viewport: SubViewport = panel.get_node("%s/TopView/SubViewport" % GRID)
	check("the row sits in the pane's corner and does not resize the pane's "
			+ "own viewport",
			pane.size.x > 100.0 and row.size.x < pane.size.x * 0.5
				and row.size.y < pane.size.y * 0.25
				and pane_viewport.size == Vector2i(pane.size),
			"pane %s, row %s at %s, viewport %s" % [
				str(pane.size), str(row.size), str(row.position), str(pane_viewport.size)])

	var narrow_dropdown: OptionButton = panel.get_node(
		"ResponsiveContainer/NarrowLayout/ProjectionRow/ProjectionDropdown")
	check("offering exactly the presets the one-pane layout offers — the same "
			+ "seven, in the same order, from the same list",
			_labels(dropdowns["top"]) == _labels(narrow_dropdown)
				and _labels(dropdowns["iso"]) == _labels(narrow_dropdown)
				and _labels(narrow_dropdown).size() == PaneProjection.OPTIONS.size(),
			"pane: %s / narrow: %s" % [str(_labels(dropdowns["top"])), str(_labels(narrow_dropdown))])

	var starts_right := true
	for slot in PANE_NODES.keys():
		if panel.get_pane_preset(String(slot)) != String(DEFAULTS[slot]):
			starts_right = false
	check("and each pane starts on the direction its slot is named for",
			starts_right, "presets = %s" % str(panel.get_pane_presets()))

	# ── The repro: the underside, in the pane called "top" ─────────────────
	var top_camera: Camera3D = panel.get_view_camera("top")
	var above := top_camera.position.z
	dropdowns["top"].select(BOTTOM_INDEX)
	dropdowns["top"].item_selected.emit(BOTTOM_INDEX)

	check("choosing Bottom in the 'top' pane applies that preset to THAT "
			+ "pane's camera",
			String(top_camera.get_debug_state().get("view_preset", "")) == "Bottom",
			"camera reports %s" % str(top_camera.get_debug_state()))
	check("and the camera really moves under the part, still orthographic — "
			+ "the same picture from above would mean the control does nothing",
			top_camera.position.z < top_camera.get_target().z
				and above > top_camera.get_target().z
				and top_camera.projection == Camera3D.PROJECTION_ORTHOGONAL,
			"z went %f -> %f, target z %f, projection %d" % [
				above, top_camera.position.z, top_camera.get_target().z,
				top_camera.projection])

	check("the SLOT keeps its id: 'top' still addresses that pane, and the "
			+ "pane metrics a snapshot caller reads report it looking from below",
			panel.get_view_camera("top") == top_camera
				and str(panel.get_view_metrics("top").get("view", "")) == "top"
				and str(panel.get_view_metrics("top").get("view_preset", "")) == "bottom",
			"metrics = %s" % str(panel.get_view_metrics("top")))

	check("no other pane moved",
			panel.get_pane_preset("front") == "Front"
				and panel.get_pane_preset("right") == "Right"
				and panel.get_pane_preset("iso") == "Perspective",
			"presets = %s" % str(panel.get_pane_presets()))

	# ── The choice is the pane's, for the session ─────────────────────────
	panel._apply_width_class(&"sm")
	await process_frame
	check("in the one-pane layout the pane that renders reports ITS own "
			+ "direction, and the named panes are refused rather than answered "
			+ "from it",
			str(panel.get_view_metrics("active").get("view_preset", "")) == "perspective"
				and panel.get_view_metrics("top").has("error"),
			"active = %s" % str(panel.get_view_metrics("active")))
	panel._apply_width_class(&"lg")
	await process_frame
	check("the choice belongs to the pane and survives a trip through the "
			+ "one-pane layout",
			panel.get_pane_preset("top") == "Bottom"
				and String(top_camera.get_debug_state().get("view_preset", "")) == "Bottom",
			"preset is %s" % panel.get_pane_preset("top"))

	# ── What each pane draws ──────────────────────────────────────────────
	_push_cube(panel)
	panel._apply_mesh_visibility()
	check("a pane showing a direction is a drawing (shaded mesh hidden) and a "
			+ "pane left on Perspective is a model (shaded mesh shown)",
			not _mesh_visible(panel, "TopView") and _mesh_visible(panel, "IsoView"),
			"top shaded=%s iso shaded=%s" % [
				str(_mesh_visible(panel, "TopView")), str(_mesh_visible(panel, "IsoView"))])

	var iso_dropdown: OptionButton = dropdowns["iso"]
	iso_dropdown.select(BOTTOM_INDEX)
	iso_dropdown.item_selected.emit(BOTTOM_INDEX)
	check("and pointing the iso pane at a direction hides its shaded mesh too "
			+ "— the rule follows the projection, not the pane's name",
			not _mesh_visible(panel, "IsoView"),
			"iso still shaded while showing %s" % panel.get_pane_preset("iso"))

	panel.free()


func _panel() -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	if packed == null:
		return null
	var panel: Node = packed.instantiate()
	root.add_child(panel)
	var editor := _EditorStub.new()
	editor.tab_title = "projection"
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"host_api_version": "1",
		"editor": editor,
	})
	return panel


func _labels(dropdown: OptionButton) -> Array:
	var out: Array = []
	for index in range(dropdown.item_count):
		out.append(dropdown.get_item_text(index))
	return out


## A cube in every pane, so mesh visibility has something to hide.
func _push_cube(panel: Node) -> void:
	var mesh_data := {
		"vertices": [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0],
			[0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10]],
		"faces": [[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6],
			[0, 4, 5], [0, 5, 1], [1, 5, 6], [1, 6, 2],
			[2, 6, 7], [2, 7, 3], [3, 7, 4], [3, 4, 0]],
	}
	for pane in PANE_NODES.values():
		var mesh_root: Node = panel.get_node_or_null("%s/%s/SubViewport/MeshRoot" % [GRID, pane])
		if mesh_root != null:
			mesh_root.call("update_mesh", mesh_data, [])


func _mesh_visible(panel: Node, pane: String) -> bool:
	var instance: Node = panel.get_node_or_null(
		"%s/%s/SubViewport/MeshRoot/MeshInstance" % [GRID, pane])
	return instance != null and instance.visible
