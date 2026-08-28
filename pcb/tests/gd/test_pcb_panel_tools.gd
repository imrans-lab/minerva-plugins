extends SceneTree
## Unit tests for the PCB plugin-panel MCP surface (pcb/ui/panel_tools.gd).
## Docket: minerva 019eb47e72a7 · DCR 019dc140.
##
## Run: godot --headless --path src --script test/test_pcb_panel_tools.gd
##
## Drives EVERY panel-local tool through panel.handle_tool() (not the MCP
## transport) against a REAL PcbAnnotationHost + PCBPanel board model, registered
## in AnnotationHostRegistry headless. Asserts args-in / JSON-out / model-state
## mutation, queries, journal, CSV + trace geometry round-trips, snapshot
## null-safety, and the missing-editor error shape. Five tools (add/move/
## get_components, spatial_query, describe_component) also assert field-by-field
## GOLDEN PARITY against the legacy MCPPCBTools return shapes (encoded as
## fixtures) — the DCR acceptance is "identical from the agent's perspective".
##
## Off-tree: the plugin scripts live outside res://; every panel/host/model ref is
## duck-typed and loaded by path (never typed AS a plugin class).
##
## C2+C3 migration (docket 019f6c45f09e wave 1, 019f6c4604ba wave 2 + core
## deletion): ALL 21 tools now live in the pcb plugin's own panel_tools.gd
## (executor "panel") — Minerva core's MCPPcbPanelTools.gd module is DELETED.
## The `h()` dispatch helper routes every tool name through
## panel.handle_tool(tool_name, args) — the same plugin-side entry point
## PluginToolRegistry.handle_tool_call forwards to once it has resolved
## editor_name -> this panel (contract §2.2/§2.3). panel.handle_tool is now a
## COROUTINE end to end (minerva_pcb_apply_route_hints awaits the router
## bridge, which makes the whole function async per the Godot 4.6
## coroutine/static-typing landmine — see panel_tools.gd's class doc), so
## `h()` awaits it and every `h(...)` call site in this file is prefixed with
## `await` (mechanical edit, C3 round). The two editor_name-validation checks
## in _run_error_shapes() below are DISPATCHER-boundary behavior
## (PluginToolRegistry.handle_tool_call rejects a missing/unknown editor_name
## before ever reaching panel_tools.gd), so those two specific calls route
## through the REAL registry instead (test/helpers/panel_tool_registry_driver.gd,
## mirroring test_panel_executed_tools.gd's fixture wiring) with assertions
## adjusted to the dispatcher's structured PluginErrors shape (error_message,
## not panel_tools.gd's own _err()'s "error" key).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")
const PCB_PLUGIN_ID := "pcb"

## The 16 wave-1 tool names, used only to build the registry fixture for the
## two dispatcher-boundary error-shape checks in _run_error_shapes().
const _WAVE1_TOOLS: Array[String] = [
	"minerva_pcb_set_board_size",
	"minerva_pcb_get_components",
	"minerva_pcb_get_nets",
	"minerva_pcb_get_pin_position",
	"minerva_pcb_pin_info",
	"minerva_pcb_add_component",
	"minerva_pcb_move_component",
	"minerva_pcb_move_relative",
	"minerva_pcb_rotate_component",
	"minerva_pcb_delete_component",
	"minerva_pcb_connect_net",
	"minerva_pcb_spatial_query",
	"minerva_pcb_describe_component",
	"minerva_pcb_import_csv",
	"minerva_pcb_export_csv",
	"minerva_pcb_import_footprint_geometry",
]

const EDITOR := "PCB1"

var _pass := 0
var _fail := 0

var panel      # PCBPanel (duck-typed Node)
var host       # PcbAnnotationHost (duck-typed)
var data       # pcb_data model (duck-typed)
var registry: PluginToolRegistry = null


func _init() -> void:
	print("=== PCB Panel-Tools Tests ===\n")

	if not _setup():
		printerr("SETUP FAILED — cannot load plugin panel; aborting")
		quit(1)
		return

	await _run_queries_and_mutations()
	await _run_golden_parity()
	await _run_roundtrips()
	await _run_error_shapes()
	await _run_get_image()
	# Campaign-2 boundary block (BT-19…22, 53, 71…76). Runs LAST so it can set
	# up its own board state without disturbing the golden-parity fixtures above.
	await _run_boundary_mcp_parity()
	# LAST: this one steps the board BACKWARD (it drives a real undo), so it
	# must not run ahead of anything that reads the board it rewinds.
	await _run_board_size_undo()

	_teardown()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── setup / teardown ──────────────────────────────────────────────────────────

func _setup() -> bool:
	var driver = DRIVER.new()
	panel = driver.load_panel(PANEL_PATH)
	if panel == null:
		return false
	host = panel.get_annotation_host()
	if host == null:
		return false
	# Wire the panel as the host's data source (mount normally does this via the
	# canvas; headless we bind the panel back-reference so get_board_data works).
	host.set_panel(panel)
	data = panel.get_data()
	if data == null:
		return false
	data.clear()  # start from a known-blank board for deterministic assertions

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR, host)

	registry = REGISTRY_DRIVER.new().build(panel, PCB_PLUGIN_ID, EDITOR, _WAVE1_TOOLS)
	return registry != null


func _teardown() -> void:
	AnnotationHostRegistry._reset_for_test()
	if panel is Node:
		(panel as Node).free()


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func check_approx(desc: String, actual: float, expected: float) -> void:
	check("%s (expected ~%s, got %s)" % [desc, str(expected), str(actual)], absf(actual - expected) < 0.001)


## Assert a result's key set exactly equals `expected` (order-independent).
func check_keys(desc: String, result: Dictionary, expected: Array) -> void:
	var got := result.keys()
	got.sort()
	var want := expected.duplicate()
	want.sort()
	check("%s — keys %s == %s" % [desc, str(got), str(want)], got == want)


## Every tool now routes through panel.handle_tool — a coroutine end to end
## (see the class doc's C2+C3 migration note), so this helper awaits it.
func h(tool_name: String, args: Dictionary) -> Dictionary:
	return await panel.handle_tool(tool_name, args)


func _args(extra: Dictionary = {}) -> Dictionary:
	var a := {"editor_name": EDITOR}
	a.merge(extra, true)
	return a


# ── queries + mutations ───────────────────────────────────────────────────────

func _run_queries_and_mutations() -> void:
	print("-- set_board_size --")
	var r := await h("minerva_pcb_set_board_size", _args({"width": 100.0, "height": 80.0}))
	check("set_board_size ok", r.get("success", false))
	check_approx("board_width=100", float(r.get("board_width", 0)), 100.0)
	check_approx("model board_width mutated", data.board_width, 100.0)
	check_approx("model board_height mutated", data.board_height, 80.0)

	print("\n-- add_component (IC_DIP) --")
	var add := await h("minerva_pcb_add_component", _args({"id": "U9", "footprint": "IC_DIP", "x": 20.0, "y": 10.0}))
	check("add ok", add.get("success", false))
	check_eq("component in model", data.has_component("U9"), true)
	check("pin_count > 0", int(add.get("pin_count", 0)) > 0)

	print("\n-- add_component (RESISTOR with value) --")
	var addr := await h("minerva_pcb_add_component", _args({"id": "R7", "footprint": "RESISTOR", "x": 40.0, "y": 30.0, "value": "10K"}))
	check("add R7 ok", addr.get("success", false))
	check_eq("R7 value stored", data.get_component("R7").properties.get("value", ""), "10K")

	print("\n-- add_component invalid footprint --")
	var bad := await h("minerva_pcb_add_component", _args({"footprint": "BOGUS", "x": 1.0, "y": 1.0}))
	check("invalid footprint rejected", bad.get("success", true) == false)

	print("\n-- move_component --")
	var mv := await h("minerva_pcb_move_component", _args({"component_id": "U9", "x": 22.0, "y": 12.0}))
	check("move ok", mv.get("success", false))
	var snapped_pos: Vector2 = data.snap_to_grid(Vector2(22.0, 12.0))
	check_approx("moved x snapped", float(mv.get("x", -1)), snapped_pos.x)
	check_approx("model x mutated", data.get_component("U9").position.x, snapped_pos.x)

	print("\n-- rotate_component --")
	var rot := await h("minerva_pcb_rotate_component", _args({"component_id": "U9", "degrees": 90}))
	check("rotate ok", rot.get("success", false))
	check_approx("model rotation mutated", data.get_component("U9").rotation, 90.0)

	print("\n-- move_relative --")
	var mr := await h("minerva_pcb_move_relative", _args({"component_id": "R7", "direction": "right"}))
	check("move_relative ok", mr.get("success", false))
	check("interpreted_direction echoed", str(mr.get("interpreted_direction", "")) == "right")
	check("new_x present", mr.has("new_x"))

	print("\n-- get_pin_position --")
	var pp := await h("minerva_pcb_get_pin_position", _args({"component_id": "U9", "pin": "1"}))
	check("pin pos ok", pp.get("success", false))
	check("world_position present", pp.has("world_position"))
	check("available_pins array", pp.get("available_pins", null) is Array)
	var pp_bad := await h("minerva_pcb_get_pin_position", _args({"component_id": "U9", "pin": "ZZZ"}))
	check("bad pin rejected", pp_bad.get("success", true) == false)
	check("bad pin returns available_pins", pp_bad.get("available_pins", null) is Array)

	print("\n-- connect_net + get_nets --")
	var cn := await h("minerva_pcb_connect_net", _args({"net_name": "VCC", "pins": [
		{"component": "U9", "pin": "1"}, {"component": "R7", "pin": "1"}]}))
	check("connect ok", cn.get("success", false))
	check_eq("connected_pins count", (cn.get("connected_pins", []) as Array).size(), 2)
	check_eq("net created in model", data.has_net("VCC"), true)
	var nets := await h("minerva_pcb_get_nets", _args())
	check("get_nets ok", nets.get("success", false))
	check_eq("net_count=1", int(nets.get("net_count", 0)), 1)
	var net0: Dictionary = (nets.get("nets", []) as Array)[0]
	check_eq("net name VCC", net0.get("name", ""), "VCC")
	check("net pins are Comp.Pin strings", (net0.get("pins", []) as Array).has("U9.1"))

	print("\n-- get_change_journal reflects mutations --")
	var jr := await h("minerva_pcb_get_change_journal", _args())
	check("journal ok", jr.get("success", false))
	check("journal has entries", int(jr.get("total_entries", 0)) > 0)
	var actions: Array = []
	for e in (jr.get("entries", []) as Array):
		actions.append(str((e as Dictionary).get("action", "")))
	check("journal recorded add_component", actions.has("add_component"))
	check("journal recorded move_component", actions.has("move_component"))
	check("journal recorded connect_net", actions.has("connect_net"))

	print("\n-- delete_component --")
	var dl := await h("minerva_pcb_delete_component", _args({"component_id": "R7"}))
	check("delete ok", dl.get("success", false))
	check_eq("R7 removed from model", data.has_component("R7"), false)


# ── golden parity (5 tools, field-by-field) ───────────────────────────────────

## A board resize is ONE undo step, like every other board mutation.
##
## It was the exception: the verb mutated the outline and snapshotted nothing,
## and the model's undo codec carried no outline bucket at all — so an undo
## across a resize rewound every entity and left the board at its new size,
## and the resize itself was a step undo walked straight past.
##
## THE ORACLE IS THE MODEL AFTER THE UNDO, not the history list: a step that
## exists but restores nothing looks identical to a working one from the
## history's side.
func _run_board_size_undo() -> void:
	print("\n-- set_board_size is one undo step --")
	# undo() steps to the state BEHIND the current one, so the resize needs a
	# snapshot behind it that is not the resize.
	data.save_to_history("baseline")
	var before_width: float = data.board_width
	var before_height: float = data.board_height
	var resized := await h("minerva_pcb_set_board_size",
		_args({"width": before_width + 25.0, "height": before_height + 15.0}))
	check("resize ok", resized.get("success", false))
	check_approx("the model really resized", data.board_width, before_width + 25.0)
	check("the resize is an undoable step", data.can_undo())
	check("undo() succeeds", data.undo())
	check_approx("undo restores the previous width", data.board_width, before_width)
	check_approx("undo restores the previous height", data.board_height, before_height)


func _run_golden_parity() -> void:
	print("\n-- GOLDEN: get_components shape --")
	# Legacy MCPPCBTools._pcb_get_components → {success, component_count, components}
	# each component → {id, footprint, x, y, rotation, layer, pins} (+ value?).
	var gc := await h("minerva_pcb_get_components", _args())
	check_keys("get_components top-level", gc, ["success", "component_count", "components"])
	var comps: Array = gc.get("components", [])
	check("components non-empty", comps.size() > 0)
	if comps.size() > 0:
		var c0: Dictionary = comps[0]
		# U9 has no value → exactly the 7-key base shape.
		check_keys("component entry (no value)", c0, ["id", "footprint", "x", "y", "rotation", "layer", "pins"])
		check("footprint is a name string", str(c0.get("footprint", "")) == "IC_DIP")
		check("pins is Array", c0.get("pins", null) is Array)

	print("\n-- GOLDEN: add_component shape --")
	# Legacy → {success, component_id, x, y, pin_count}. `assembly` is the
	# work-item 019fd5fe2724 (DCR 019fd5fd9084) addition: every placement verb
	# attaches the tri-state assembly verdict after mutating (headless here →
	# {status:"indeterminate"} — the channel bridge degrades honestly, never
	# silently).
	# ON-GRID (multiples of 2.54): the UX2 station-6 snap disclosure adds
	# snapped/requested only for off-grid requests — this golden pins the
	# lean common shape (conditional keys pinned in test_workspace_tools 23f).
	var ga := await h("minerva_pcb_add_component", _args({"id": "C3", "footprint": "CAPACITOR", "x": 10.16, "y": 50.8}))
	check_keys("add_component result", ga, ["success", "component_id", "x", "y", "pin_count", "assembly"])
	check_eq("component_id echoed", ga.get("component_id", ""), "C3")
	check_eq("placement verb attaches the tri-state assembly verdict (indeterminate headless)",
		str((ga.get("assembly", {}) as Dictionary).get("status", "")), "indeterminate")

	print("\n-- GOLDEN: move_component shape --")
	var gm := await h("minerva_pcb_move_component", _args({"component_id": "C3", "x": 12.7, "y": 53.34}))
	# `pads` rides along with every move/rotate reply — the one pad-row shape
	# the selection verbs share, so a caller that just moved a part can read its
	# new pad positions without a second round trip.
	check_keys("move_component result", gm, ["success", "component_id", "x", "y", "assembly", "pads"])

	print("\n-- GOLDEN: spatial_query shape --")
	# Legacy → {success, reference, radius_mm, nearby_count, nearby:[{id, relationship}]}
	var gs := await h("minerva_pcb_spatial_query", _args({"reference_component": "U9", "radius_mm": 100.0}))
	# SHAPE DELIBERATELY EXTENDED (bug 019fa1cda337, K28): the legacy reply
	# answered "what components are near X" and had no way to say what was
	# ROUTED there, while the human's marquee over the same rectangle picked
	# copper too. The extension is nested under one "copper" key rather than
	# sprawled across the top level, so the legacy fields a caller already reads
	# are untouched in place. This golden pinned the C2/C3 MIGRATION parity,
	# which shipped long ago; extending it now is a reviewed edit, not a drift.
	check_keys("spatial_query result", gs,
		["success", "reference", "radius_mm", "nearby_count", "nearby", "copper"])
	var copper: Dictionary = gs.get("copper", {})
	check_keys("spatial_query copper block", copper,
		["region_mm", "traces", "vias", "zones", "cutouts", "count", "searched",
		 "searched_over", "note"])
	# The count must agree with the arrays beside it — a total that silently
	# excludes a kind it also returns means something other than "how many
	# things are in here".
	check_eq("count agrees with what was listed", int(copper.get("count", -1)),
		(copper.get("traces", []) as Array).size()
			+ (copper.get("vias", []) as Array).size()
			+ (copper.get("zones", []) as Array).size()
			+ (copper.get("cutouts", []) as Array).size())
	# `nearby` came from a radius CIRCLE, the copper from the square that
	# circle inscribes; listing components among "searched" would imply one
	# search where there are two, with different shapes.
	check("searched does not conflate the component radius with the region",
		not (copper.get("searched", []) as Array).has("components"))
	# The agent must be able to tell "nothing routed here" from "copper was not
	# looked for" — the first reading invites routing straight through copper
	# the query never examined.
	check("copper names what it searched",
		(copper.get("searched", []) as Array).has("traces"))
	check("…and states that view state does not filter it",
		"visibility" in str(copper.get("note", "")))
	var nearby: Array = gs.get("nearby", [])
	if nearby.size() > 0:
		check_keys("nearby entry", nearby[0], ["id", "relationship"])
		check("relationship is String", nearby[0].get("relationship", null) is String)
	# empty reference → falls back to get_components shape (legacy behaviour).
	var gs_empty := await h("minerva_pcb_spatial_query", _args())
	check_keys("spatial_query no-ref → get_components shape", gs_empty,
		["success", "component_count", "components"])

	print("\n-- GOLDEN: describe_component shape --")
	# Legacy → describe_component_context(id) + success. Base keys:
	# {id, value, position, rotation, footprint, layer, nearby, connected_to, region, pins}
	# (+ properties when the component has any; success added by the tool).
	var gd := await h("minerva_pcb_describe_component", _args({"component_id": "U9"}))
	check("describe ok", gd.get("success", false))
	for k in ["id", "position", "rotation", "footprint", "layer", "nearby", "connected_to", "region", "pins"]:
		check("describe has '%s'" % k, gd.has(k))
	check("describe position is {x,y}", (gd.get("position", {}) as Dictionary).has("x"))
	var gd_missing := await h("minerva_pcb_describe_component", _args({"component_id": "NOPE"}))
	check("describe missing component → error", gd_missing.get("success", true) == false)


# ── CSV + geometry round-trips ────────────────────────────────────────────────

func _run_roundtrips() -> void:
	print("\n-- CSV round-trip --")
	var ex := await h("minerva_pcb_export_csv", _args())
	check("export_csv ok", ex.get("success", false))
	var csv := str(ex.get("csv", ""))
	check("csv has header", csv.begins_with("id,footprint,x,y,rotation,layer,value"))
	check("csv mentions U9", csv.contains("U9"))
	# Import into a blank board and confirm the component count round-trips.
	var before_ids: Array = data.get_component_ids()
	var im := await h("minerva_pcb_import_csv", _args({"csv_content": csv}))
	check("import_csv ok", im.get("success", false))
	check_eq("import restored same count", int(im.get("component_count", -1)), before_ids.size())

	# An identity-changing import that deliberately discards extras must surface
	# that loss to the caller, not only to the model's internal journal.
	var changing = data.new_component()
	changing.load_from_board_dict({
		"ref": "R_WARN", "footprint": "R_0805", "value": "10k",
		"x_mm": 0.0, "y_mm": 0.0, "rotation_deg": 0.0, "layer": "top",
		"mpn": "OLD-PART",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
			"drill_mm": 0.6}],
	})
	data.components["R_WARN"] = changing
	var warned := await h("minerva_pcb_import_csv", _args({"csv_content":
			"id,footprint,x,y,rotation,layer,value\n"
			+ "R_WARN,R_0805,1,1,0,top,1k\n"}))
	check("identity-extra loss is returned as a warning",
			warned.get("warnings", []) is Array \
					and not (warned.get("warnings", []) as Array).is_empty())
	var surfaced_drops: Array = warned.get("dropped_identity_extras", [])
	check("tool warning identifies the component and discarded key",
			not surfaced_drops.is_empty() \
					and str((surfaced_drops[0] as Dictionary).get("ref", "")) == "R_WARN" \
					and ((surfaced_drops[0] as Dictionary).get(
							"canonical_extra_keys", []) as Array).has("mpn"))

	print("\n-- footprint geometry import --")
	var geom := {
		"board_name": "TestBoard",
		"components": {
			"U9": {
				"footprint_id": "Package_DIP:DIP-8_W7.62mm",
				"footprint_found": true,
				"bounding_box": {"width": 9.0, "height": 6.0, "center_x": 3.81, "center_y": 3.81},
				"pads": [
					{"number": "1", "type": "thru_hole", "shape": "circle",
						"position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.6, "height": 1.6}, "drill": 0.8, "layers": ["*.Cu"]},
				],
			},
		},
	}
	var fg := await h("minerva_pcb_import_footprint_geometry", _args({"geometry": geom}))
	check("footprint import ok", fg.get("success", false))
	check_eq("updated_count=1", int(fg.get("updated_count", 0)), 1)
	check("U9 has pad geometry", data.get_component("U9").has_pad_geometry)

	print("\n-- trace geometry round-trip --")
	var tin := {
		"traces": [
			{"start": {"x": 0.0, "y": 0.0}, "end": {"x": 5.0, "y": 0.0}, "width": 0.25, "layer": "F.Cu", "net_name": "GND"},
			{"start": {"x": 5.0, "y": 0.0}, "end": {"x": 10.0, "y": 0.0}, "width": 0.25, "layer": "F.Cu", "net_name": "GND"},
		],
		"vias": [
			{"position": {"x": 10.0, "y": 0.0}, "size": 0.8, "drill": 0.4, "net_name": "GND", "layers": ["F.Cu", "B.Cu"]},
		],
	}
	var ti := await h("minerva_pcb_import_trace_geometry", _args({"trace_data": tin}))
	check("trace import ok", ti.get("success", false))
	check("traces created", int(ti.get("trace_count", 0)) >= 1)
	check_eq("one via imported", int(ti.get("via_count", 0)), 1)
	check("model has traces", data.get_trace_count() >= 1)
	var te := await h("minerva_pcb_export_trace_geometry", _args())
	check("trace export ok", te.get("success", false))
	var td: Dictionary = te.get("trace_data", {})
	check("export has traces", (td.get("traces", []) as Array).size() >= 1)
	check_eq("export via count", (td.get("vias", []) as Array).size(), 1)
	# Segments round-trip: 2 collinear input segments merge into one 3-point
	# polyline, which re-expands to exactly 2 output segments.
	check_eq("segments re-expand to 2", (td.get("traces", []) as Array).size(), 2)


# ── error shapes ──────────────────────────────────────────────────────────────

func _run_error_shapes() -> void:
	print("\n-- missing editor_name --")
	# Crosses the DISPATCHER boundary now (PluginToolRegistry.handle_tool_call
	# rejects a missing/unknown editor_name before ever reaching
	# panel_tools.gd — contract §2.2), so these two checks route through the
	# REAL registry instead of the h()/panel.handle_tool shortcut the rest of
	# this suite uses. Shape is PluginErrors.editor_name_required /
	# editor_not_found, not panel_tools.gd's own _err(); success=false still
	# holds, only the message field name changed (error_message, not "error").
	var e1: Dictionary = await registry.handle_tool_call("minerva_pcb_get_components", {})
	check("no editor_name → error", e1.get("success", true) == false)
	check("no editor_name → editor_name_required", e1.get("error_code", "") == "editor_name_required")

	print("\n-- missing host (unknown editor) matches the dispatcher convention --")
	# Same "structured error naming the editor + known editors" contract the
	# old MCPCadTools-style _no_host_error UX gave, just under error_message/
	# known_editors instead of a single "error" string.
	var e2: Dictionary = await registry.handle_tool_call("minerva_pcb_get_components", {"editor_name": "GhostBoard"})
	check("unknown editor → success=false", e2.get("success", true) == false)
	check("unknown editor → editor_not_found", e2.get("error_code", "") == "editor_not_found")
	check("error names the editor", str(e2.get("error_message", "")).contains("GhostBoard"))
	check("error lists known editors", str(e2.get("error_message", "")).contains("Known editors"))

	print("\n-- component not found --")
	var e3 := await h("minerva_pcb_move_component", _args({"component_id": "NOSUCH", "x": 1.0, "y": 1.0}))
	check("missing component → error", e3.get("success", true) == false)


# ── snapshot (headless null-safety) ───────────────────────────────────────────

func _run_get_image() -> void:
	print("\n-- get_image (headless null-or-image, no crash) --")
	var gi := await h("minerva_pcb_get_image", _args())
	check("get_image returns success", gi.get("success", false))
	var img = gi.get("image_data", "SENTINEL")
	check("image_data is null or a base64 String (headless)", img == null or img is String)
	check("metadata present", gi.get("metadata", null) is Dictionary)

	# ── save_to_path (bug 019f6ea4e52a) ───────────────────────────────────────
	# Inline base64 PNGs poison LLM context (a routing agent stalled 6+ minutes
	# on one ~150KB payload). save_to_path is the context-friendly mode, mirroring
	# minerva_annotations_render_overlay's output_path fix (Minerva 4b74971c):
	# write the PNG to disk, return a path instead of bytes. Headless has no
	# rendered image either way, so both modes must degrade to a graceful null
	# envelope — no crash, no partial file.
	print("\n-- get_image save_to_path (headless null envelope) --")
	var tmp_path := "/tmp/pcb_get_image_test_%d.png" % Time.get_ticks_usec()
	var gsp := await h("minerva_pcb_get_image", _args({"save_to_path": tmp_path}))
	check("save_to_path headless returns success (%s)" % str(gsp), gsp.get("success", false))
	check("save_to_path headless saved_to is null (%s)" % str(gsp), gsp.get("saved_to", "SENTINEL") == null)
	check("save_to_path headless response has no image_data key (%s)" % str(gsp), not gsp.has("image_data"))
	check("save_to_path headless metadata present (%s)" % str(gsp), gsp.get("metadata", null) is Dictionary)
	check("save_to_path headless does not write a file", not FileAccess.file_exists(tmp_path))

	print("\n-- get_image save_to_path validation (relative path → structured error) --")
	var rel := await h("minerva_pcb_get_image", _args({"save_to_path": "relative/path.png"}))
	check("relative save_to_path is a structured error (%s)" % str(rel), rel.get("success", true) == false)
	check("relative save_to_path error names the offending path (%s)" % str(rel),
		str(rel.get("error", "")).findn("relative/path.png") != -1)

	print("\n-- get_image save_to_path validation (missing parent dir → structured error) --")
	var missing_parent := "/tmp/pcb_get_image_test_nonexistent_dir_%d/out.png" % Time.get_ticks_usec()
	var mp := await h("minerva_pcb_get_image", _args({"save_to_path": missing_parent}))
	check("missing-parent save_to_path is a structured error (%s)" % str(mp), mp.get("success", true) == false)
	check("missing-parent error names the offending parent dir (%s)" % str(mp),
		str(mp.get("error", "")).findn(missing_parent.get_base_dir()) != -1)

	print("\n-- get_image save_to_path empty string behaves like default (no arg) --")
	var empty_sp := await h("minerva_pcb_get_image", _args({"save_to_path": ""}))
	check("empty save_to_path returns success (%s)" % str(empty_sp), empty_sp.get("success", false))
	check("empty save_to_path uses default image_data shape, not saved_to (%s)" % str(empty_sp),
		empty_sp.has("image_data") and not empty_sp.has("saved_to"))


# ══════════════════════════════════════════════════════════════════════════════
# CAMPAIGN-2 BOUNDARY BLOCK — BT-19…22, BT-53, BT-71…76
#
# Seeded by the B2 cold-review probe (nudge c2-epochB key B2.review), which
# established these facts LIVE and is not re-derived here.
#
# ORACLE RULE for everything below: the tool's REPLY is never checked against
# itself. Each assertion reads a SECOND representation — the model read directly,
# a different tool's read path, the manifest file on disk, or the plugin's own
# source text — because a tool that builds its reply from its request arguments
# passes every self-consistent check ever written.
#
# ── SHARED HELPERS (plan §4) ────────────────────────────────────────────────
# Two idioms recur across five surfaces in this campaign, and the plan asked for
# ONE implementation of each rather than five:
#
#   * the JOURNAL-DELTA COUNTER (_journal_len/_history_len below) — BT-14, 20,
#     25, 52, 73. Assertions stay separate; the counter does not.
#   * the REFUSAL-STRING DRIFT DETECTOR (_check_refusal_matches_model) — BT-21,
#     29, 75. It compares the tool's message BYTE FOR BYTE to the model function
#     that owns the rule, so a reword on either side is caught from the other.
#
# NOTE FOR THE CANVAS AUTHOR: BT-52 (via delete journal/history asymmetry, in
# test_pcb_canvas_input_probe.gd) needs the same counter pair. It is duplicated
# there rather than shared because the two suites have no common base — flagged
# in the boundary report rather than solved by a cross-fence edit.
# ══════════════════════════════════════════════════════════════════════════════

const MANIFEST_PATH := "res://../../minerva-plugins/pcb/manifest.json"
const PCB_NET_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_net.gd"
const PcbLayerStack := preload("res://../../minerva-plugins/pcb/ui/model/pcb_layer_stack.gd")
const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
const PANEL_SOURCE_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"


## Journal length — the model's own append-only change log.
## SECTION REGISTRY — see test_pcb_panel_model.gd's copy for the incident that
## created it. A GDScript runtime error aborts the whole enclosing FUNCTION, so
## an oracle can contribute ZERO assertions while the suite reports clean green.
## Each boundary section declares itself; the final guard proves each one ran.
var _section_marks: Array = []


func _begin_section(label: String) -> void:
	_section_marks.append({"label": label, "at": _pass + _fail})


func _assert_every_section_ran() -> void:
	print("\n-- boundary block: every section actually ran --")
	var silent: Array = []
	for i in range(_section_marks.size()):
		var mark: Dictionary = _section_marks[i]
		var next_at: int = int(_section_marks[i + 1]["at"]) if i + 1 < _section_marks.size() \
				else _pass + _fail
		if next_at - int(mark["at"]) <= 0:
			silent.append(str(mark["label"]))
	check("no boundary section produced ZERO assertions (silent: %s)" % str(silent),
			silent.is_empty())
	check("all 9 boundary sections declared themselves (%d)" % _section_marks.size(),
			_section_marks.size() == 9)


func _journal_len() -> int:
	return data.change_journal.size()


## Undo-history depth. Deliberately a SECOND counter: several operations are
## "one journal entry, one history step" but a batch is "N journal entries, ONE
## history step", and only two counters can express that asymmetry.
func _history_len() -> int:
	if data.has_method("get_history_size"):
		return int(data.get_history_size())
	# The model stores history in an Array; read whichever member it exposes.
	for member in ["_history", "history", "_undo_stack"]:
		var v: Variant = data.get(member)
		if v is Array:
			return (v as Array).size()
	# D1 oracle-integrity review, finding 4: a lookup MISS used to return -1
	# silently, and `-1 == -1` makes every "history delta +0" assertion in this
	# file vacuously green — the counter would agree with itself forever while
	# measuring nothing. Fail loudly instead, at every call site that relied on it.
	check("history counter is readable (a -1 miss makes every delta assertion vacuous)",
			false)
	return -1


## THE REFUSAL-STRING DRIFT DETECTOR.
##
## `reply` must be a refusal whose message is BYTE-IDENTICAL to `model_message`,
## which the caller obtained by asking the MODEL the same question. Wording that
## drifts on either side of the seam fails, which is the point: the tool must not
## own a second copy of a rule the model already states.
func _check_refusal_matches_model(desc: String, reply: Dictionary,
		model_message: String) -> void:
	check("%s — the model itself refuses (fixture is a real refusal)" % desc,
			not model_message.is_empty())
	check("%s — the tool refuses too (success:false)" % desc,
			reply.get("success", true) == false)
	var tool_message := str(reply.get("error", ""))
	check("%s — verbatim: tool %s == model %s" % [desc, tool_message, model_message],
			tool_message == model_message)


## Declare a net on the board. The model's add_net takes a NET OBJECT, not a
## name — a string silently blows up on `net.name`, which is how the first draft
## of this block failed.
func _declare_net(net_name: String) -> void:
	var net = load(PCB_NET_PATH).new()
	net.name = net_name
	data.add_net(net)


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _run_boundary_mcp_parity() -> void:
	_boundary_manifest_dispatch_parity()          # BT-22
	_boundary_no_false_ok_shapes()                # BT-75 (mechanical half)
	_boundary_description_promises_are_true()     # BT-71 (reframed — see below)
	await _boundary_layout_state_is_read_only()   # BT-76
	await _boundary_zone_lifecycle()              # BT-19, 20, 21, 72, 73, 75-live
	await _boundary_group_agreement()             # BT-74
	await _boundary_via_read_paths_agree()        # BT-53
	# Campaign-2 boundary GAP block.
	await _boundary_agent_preference_surface()    # G2
	_boundary_build_stamp_tracks_schema()         # G4
	_assert_every_section_ran()


# ── BT-22. manifest ↔ handle() dispatch parity ───────────────────────────────

## The reviewer's programmatic cross-check, made standing.
##
## TWO directions, plus the executor leg. Names alone are not enough: hint
## 019fba4240 records that an entry with NO `executor` silently routes to the Go
## broker, so a panel tool that loses its executor keyword stops reaching this
## file at all while both name sets still match perfectly.
func _boundary_manifest_dispatch_parity() -> void:
	_begin_section("BT-22")
	print("\n-- BT-22: manifest <-> panel_tools.handle() dispatch parity --")
	var manifest_text := _read_text(MANIFEST_PATH)
	var parsed: Variant = JSON.parse_string(manifest_text)
	check("manifest.json parses", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var tools: Array = (parsed as Dictionary).get("tools", [])
	check("manifest declares tools", tools.size() > 0)

	var declared_panel := {}
	var declared_other := {}
	for entry in tools:
		var e: Dictionary = entry
		var name := str(e.get("name", ""))
		if str(e.get("executor", "")) == "panel":
			declared_panel[name] = true
		else:
			declared_other[name] = true

	# Dispatch branches, read out of the SOURCE TEXT — not from a list this test
	# maintains, which would just be a third place to forget.
	var source := _read_text(PANEL_TOOLS_PATH)
	var dispatched := {}
	var re := RegEx.new()
	re.compile("\"(minerva_pcb_[a-z0-9_]+)\":")
	for m in re.search_all(source):
		dispatched[m.get_string(1)] = true

	var missing_branch: Array = []
	for name in declared_panel:
		if not dispatched.has(name):
			missing_branch.append(name)
	missing_branch.sort()
	check("every executor:\"panel\" tool has a handle() branch (missing: %s)"
			% str(missing_branch), missing_branch.is_empty())

	var missing_manifest: Array = []
	for name in dispatched:
		if not declared_panel.has(name):
			missing_manifest.append(name)
	missing_manifest.sort()
	check("every dispatched name is declared executor:\"panel\" (stray: %s)"
			% str(missing_manifest), missing_manifest.is_empty())

	# THE EXECUTOR LEG. A worker tool must not be dispatched here, and a panel
	# tool must not be missing its keyword — the two failures the name-parity
	# legs above cannot tell apart.
	var wrongly_broker: Array = []
	for name in dispatched:
		if declared_other.has(name):
			wrongly_broker.append(name)
	wrongly_broker.sort()
	check("no dispatched tool is declared without executor:\"panel\" — an absent "
			+ "executor routes to the Go broker (hint 019fba4240): %s" % str(wrongly_broker),
			wrongly_broker.is_empty())
	check("the panel set is non-trivial (%d tools)" % declared_panel.size(),
			declared_panel.size() >= 40)


# ── BT-75 (mechanical half). No false-ok reply shapes ────────────────────────

## Every refusal in this file must be an _err(). A handler that returns
## `{"ok": false}` or a bare `false` produces a reply with NO "error" key and NO
## success:false — the agent reads it as a success with missing fields, which is
## the F2 class the B2 review caught by hand.
##
## Grep-level, deliberately: the live half is below, in the zone block, where
## every refusal path is actually CALLED. Neither half is sufficient — a scan
## cannot reach a runtime branch, and a runtime call cannot enumerate the ones
## nobody thought to call.
func _boundary_no_false_ok_shapes() -> void:
	_begin_section("BT-75a")
	print("\n-- BT-75a: no false-ok reply shapes in panel_tools.gd --")
	var source := _read_text(PANEL_TOOLS_PATH)
	check("panel_tools.gd source is readable", not source.is_empty())

	# The scan is scoped to REAL HANDLERS — the functions the dispatch match
	# actually routes to. panel_tools.gd also contains internal BRIDGE helpers
	# (_run_router) whose {ok, error} envelope is an input to a handler, not a
	# reply to an agent; flagging those would be a false positive that trains
	# people to weaken the scan. Handler names are read out of the dispatch
	# block itself, so a new tool is covered the day it is wired up.
	var handlers := {}
	var dispatch_re := RegEx.new()
	dispatch_re.compile("return (?:await )?(_[a-z0-9_]+)\\(host")
	for m in dispatch_re.search_all(source):
		handlers[m.get_string(1)] = true
	check("dispatch handlers were discovered (%d)" % handlers.size(), handlers.size() >= 40)

	var offenders: Array = []
	var lines := source.split("\n")
	var current := ""
	var func_re := RegEx.new()
	func_re.compile("^static func (_[a-z0-9_]+)\\(")
	for i in range(lines.size()):
		var raw := str(lines[i])
		var fm := func_re.search(raw)
		if fm != null:
			current = fm.get_string(1)
		var line := raw.strip_edges()
		if line.begins_with("#") or not handlers.has(current):
			continue
		if line.begins_with("return {\"ok\":") or line.begins_with("return false"):
			offenders.append("%s:%d %s" % [current, i + 1, line])
	check("no handler returns an {\"ok\": …} shape (offenders: %s)" % str(offenders),
			offenders.is_empty())

	# The POSITIVE half of the same claim: _err is the one refusal constructor,
	# and it emits both keys an agent branches on.
	check("_err emits an \"error\" message AND success:false",
			source.find("return {\"error\": msg, \"success\": false}") >= 0)


# ── BT-71 (reframed). The schema's own prose must be executable ──────────────

## BT-71 as planned reads "every schema example executable-valid (paste-and-
## succeed per tool)". MEASURED while writing this: the manifest carries prose
## examples for essentially one tool, so "execute every example" would be a test
## over a population of one, and would read as coverage it does not have.
##
## What the manifest DOES carry, on many tools, is `e.g.` TOKENS inside property
## descriptions — and that is precisely where the B2 review's F1 defect lived:
## create_zone's `layer` description offered "F.Cu, B.Cu" while the model accepts
## only canonical ids, so an agent's very first call, written straight off the
## schema, was refused. The durable hint is
## `pcb-plugin/manifest-schema-prose-is-agent-truth`.
##
## So the assertion is the one that would have caught F1: a layer/net token
## OFFERED by a description must be one the model would ACCEPT. Executed against
## the live model, not pattern-matched.
func _boundary_description_promises_are_true() -> void:
	_begin_section("BT-71")
	print("\n-- BT-71: layer tokens promised by the schema are tokens the model accepts --")
	var parsed: Variant = JSON.parse_string(_read_text(MANIFEST_PATH))
	if not (parsed is Dictionary):
		check("manifest parses for the prose scan", false)
		return

	# KiCad aliases are what F1 shipped — into a ZONE-authoring tool, whose
	# model accepts canonical ids only. They are not universally refused: a tool
	# that resolves its layer through PcbLayerStack takes them. So the oracle is
	# per-tool ACCEPTANCE, executed below, not the presence of the token.
	var kicad_aliases := ["F.Cu", "B.Cu", "In1.Cu", "In2.Cu"]
	# The tools whose `layer` is authored through the ZONE validator
	# (data.zone_layer_error), which is canonical-only.
	var zone_layer_tools := ["minerva_pcb_create_zone", "minerva_pcb_propose_zone",
		"minerva_pcb_set_zone_layer"]
	var offenders: Array = []
	for entry in (parsed as Dictionary).get("tools", []):
		var e: Dictionary = entry
		if str(e.get("executor", "")) != "panel":
			continue
		var schema: Dictionary = e.get("input_schema", {})
		var props: Dictionary = schema.get("properties", {})
		if not props.has("layer"):
			continue
		var tool_name := str(e.get("name", ""))
		var desc := str((props["layer"] as Dictionary).get("description", ""))
		for alias in kicad_aliases:
			# An alias may be NAMED as a counter-example ("NOT F.Cu") — that is
			# the F1 fix's own wording and must not read as a regression.
			if desc.find(alias) < 0 or desc.findn("not ") >= 0:
				continue
			# EXECUTED, per tool: offering a token the tool's own model accepts
			# is honest schema prose; offering one it refuses is F1.
			var refused: bool = not str(data.zone_layer_error(alias)).is_empty() \
				if tool_name in zone_layer_tools else not PcbLayerStack.is_copper(alias)
			if refused:
				offenders.append("%s.layer offers %s" % [tool_name, alias])
	check("no panel tool's `layer` description offers a KiCad alias the model "
			+ "refuses (offenders: %s)" % str(offenders), offenders.is_empty())

	# ... and the counter-proof, executed: the model really does refuse them, so
	# the assertion above is guarding a live failure and not a style preference.
	var alias_refusal := str(data.zone_layer_error("F.Cu"))
	check("the model refuses the alias F.Cu outright (%s)" % alias_refusal,
			not alias_refusal.is_empty())
	var canonical_refusal := str(data.zone_layer_error("top"))
	check("...and accepts the canonical id the schema now offers",
			canonical_refusal.is_empty())


# ── BT-76. get_layout_state is a read; plugin_build is not invented ──────────

func _boundary_layout_state_is_read_only() -> void:
	_begin_section("BT-76")
	print("\n-- BT-76: get_layout_state journals nothing; plugin_build tracks the source --")
	var journal_before := _journal_len()
	var history_before := _history_len()
	var last: Dictionary = {}
	for _i in range(4):
		last = await h("minerva_pcb_get_layout_state", _args())
	check("get_layout_state succeeds", last.get("success", false))
	check_eq("4 reads journalled nothing", _journal_len(), journal_before)
	check_eq("4 reads pushed no history step", _history_len(), history_before)

	# plugin_build vs the CONSTANT IN THE SOURCE FILE — two representations. A
	# hardcoded string in the reply matches until somebody bumps the const, which
	# is exactly the F4 failure mode (an operator reads a stale stamp and
	# concludes the deploy failed).
	var source := _read_text(PANEL_SOURCE_PATH)
	var re := RegEx.new()
	re.compile("const PLUGIN_BUILD\\s*:=\\s*\"([^\"]*)\"")
	var m := re.search(source)
	check("PCBPanel.gd declares PLUGIN_BUILD", m != null)
	if m != null:
		check_eq("the reply's plugin_build IS the source constant",
				str(last.get("plugin_build", "")), m.get_string(1))
		check("the stamp is non-empty (an empty stamp answers nothing)",
				not m.get_string(1).is_empty())
	# NOTE (F4, reported not authored): pinning the LITERAL so an unbumped round
	# goes red belongs in test_pcb_manifest_tool_registration.gd, which already
	# owns the plugin's count/version pins and is outside this file's fence.


# ── BT-19/20/21/72/73 + the live half of BT-75. Zone lifecycle ───────────────

func _boundary_zone_lifecycle() -> void:
	_begin_section("BT-19/20/21/72/73")
	print("\n-- BT-19/20/21/72/73: zone tools vs the model, journal deltas, refusals --")
	# Fixture: one declared net on a two-layer board.
	_declare_net("BND_NET")
	var outline := [
		{"x_mm": 5.0, "y_mm": 5.0}, {"x_mm": 25.0, "y_mm": 5.0},
		{"x_mm": 25.0, "y_mm": 20.0}, {"x_mm": 5.0, "y_mm": 20.0},
	]

	# ── BT-72 + BT-19: create, then read back through a SEPARATE path.
	var j0 := _journal_len()
	var created := await h("minerva_pcb_create_zone", _args({
		"kind": "copper_pour", "net": "BND_NET", "layer": "top", "outline": outline}))
	check("create_zone succeeds", created.get("success", false))
	var zone_id := str(created.get("zone_id", ""))
	check("create_zone minted a non-empty id", not zone_id.is_empty())
	check("create_zone journalled exactly one entry", _journal_len() - j0 == 1)

	# BT-72: the id must be present in a SEPARATE list call, not just echoed.
	var listed := await h("minerva_pcb_list_zones", _args())
	var listed_ids: Array = []
	var listed_entry: Dictionary = {}
	for z in listed.get("zones", []):
		listed_ids.append(str((z as Dictionary).get("zone_id", "")))
		if str((z as Dictionary).get("zone_id", "")) == zone_id:
			listed_entry = z
	check("the minted id appears in list_zones (%s)" % str(listed_ids),
			listed_ids.has(zone_id))
	# ... and the PAYLOAD agrees, not merely the id (the plan's own extension of
	# this leg: agreeing on an id while disagreeing on the outline is worse than
	# disagreeing outright, because it looks correct).
	check_eq("list_zones agrees on the point count",
			int(listed_entry.get("point_count", -1)), outline.size())
	check_eq("list_zones agrees on the net", str(listed_entry.get("net", "")), "BND_NET")
	check_eq("list_zones agrees on the layer", str(listed_entry.get("layer", "")), "top")

	# BT-19: the reply's claim vs the MODEL read directly. A tool that mutated a
	# copy and returned the intended value passes every reply-only check.
	var model_zone: Dictionary = data.get_zone(zone_id)
	check("the model itself holds a zone under that id", not model_zone.is_empty())
	check_eq("model net == reply net", str(model_zone.get("net", "")), "BND_NET")
	check_eq("model layer == reply layer", str(model_zone.get("layer", "")), "top")
	check_eq("model point count == reply point_count",
			data.zone_outline_points(model_zone).size(), int(created.get("point_count", -1)))

	# ── BT-20: journal deltas across the four call classes.
	var j1 := _journal_len()
	await h("minerva_pcb_list_zones", _args())
	await h("minerva_pcb_describe_zone", _args({"zone_id": zone_id}))
	check("reads journal NOTHING (+0)", _journal_len() - j1 == 0)

	var j2 := _journal_len()
	var set_net := await h("minerva_pcb_set_zone_net", _args({
			"zone_id": zone_id, "net_name": "BND_NET"}))
	check("a no-change set succeeds", set_net.get("success", false))
	check("a no-change set reports changed:false", set_net.get("changed", true) == false)
	check("a no-change set journals NOTHING (+0)", _journal_len() - j2 == 0)

	_declare_net("BND_NET2")
	var j3 := _journal_len()
	var real_set := await h("minerva_pcb_set_zone_net", _args({
			"zone_id": zone_id, "net_name": "BND_NET2"}))
	check("a real set succeeds and reports changed:true",
			real_set.get("success", false) and real_set.get("changed", false))
	check("a real set journals exactly one entry (+1)", _journal_len() - j3 == 1)
	check_eq("...and the MODEL carries the new net (not just the reply)",
			str(data.get_zone(zone_id).get("net", "")), "BND_NET2")

	# ── BT-73: outline set — journal deltas + value-wise undo restore.
	var before_points: PackedVector2Array = data.zone_outline_points(data.get_zone(zone_id))
	var j4 := _journal_len()
	var same_outline := await h("minerva_pcb_set_zone_outline", _args({
			"zone_id": zone_id, "outline": outline}))
	check("re-submitting the SAME outline is a no-change (+0 journal)",
			same_outline.get("success", false) and _journal_len() - j4 == 0)

	var moved := [
		{"x_mm": 6.0, "y_mm": 6.0}, {"x_mm": 26.0, "y_mm": 6.0},
		{"x_mm": 26.0, "y_mm": 21.0},
	]
	var j5 := _journal_len()
	var h5 := _history_len()
	var set_outline := await h("minerva_pcb_set_zone_outline", _args({
			"zone_id": zone_id, "outline": moved}))
	check("a real outline set succeeds", set_outline.get("success", false))
	check("a real outline set journals exactly one entry (+1)", _journal_len() - j5 == 1)
	check("...and pushes exactly one history step (+1)", _history_len() - h5 == 1)

	var undone: bool = data.undo()
	check("undo() reports it did something", undone)
	var restored: PackedVector2Array = data.zone_outline_points(data.get_zone(zone_id))
	# VALUE-wise, not by reference: a comparison by identity passes on the same
	# array and reds on an equal-but-new one, which is the wrong way round.
	var same_size := restored.size() == before_points.size()
	var same_values := same_size
	if same_size:
		for i in range(restored.size()):
			if not restored[i].is_equal_approx(before_points[i]):
				same_values = false
				break
	check("undo restored the outline POINT VALUES (%d pts)" % restored.size(), same_values)

	# ── BT-21 + BT-75 (live). Refusals are _err(), verbatim from the model.
	var undeclared := await h("minerva_pcb_set_zone_net", _args({
			"zone_id": zone_id, "net_name": "NO_SUCH_NET"}))
	_check_refusal_matches_model("undeclared net", undeclared,
			str(data.zone_net_error("NO_SUCH_NET", data.zone_kind(data.get_zone(zone_id)))))

	var bad_layer := await h("minerva_pcb_set_zone_layer", _args({
			"zone_id": zone_id, "layer": "F.Cu"}))
	_check_refusal_matches_model("KiCad-alias layer", bad_layer,
			str(data.zone_layer_error("F.Cu")))

	var j6 := _journal_len()
	var two_points := await h("minerva_pcb_set_zone_outline", _args({
			"zone_id": zone_id,
			"outline": [{"x_mm": 0.0, "y_mm": 0.0}, {"x_mm": 1.0, "y_mm": 1.0}]}))
	check("a 2-point outline is refused with an error key",
			two_points.get("success", true) == false and two_points.has("error"))
	check("a refused outline set journals NOTHING", _journal_len() - j6 == 0)

	# Every refusal above must carry BOTH keys. Asserted as a set so a reply that
	# is merely falsy — the false-ok shape BT-75a scans for — cannot pass.
	for pair in [["undeclared net", undeclared], ["bad layer", bad_layer],
			["two-point outline", two_points]]:
		var r: Dictionary = pair[1]
		check("%s refusal carries success:false AND a non-empty error" % str(pair[0]),
				r.get("success", true) == false and not str(r.get("error", "")).is_empty())


# ── BT-74. Group replies agree with get_components ──────────────────────────

func _boundary_group_agreement() -> void:
	_begin_section("BT-74")
	print("\n-- BT-74: group tools agree with get_components' own reporting --")
	await h("minerva_pcb_add_component", _args({
			"id": "G1", "footprint": "RESISTOR", "x": 10.0, "y": 40.0}))
	await h("minerva_pcb_add_component", _args({
			"id": "G2", "footprint": "RESISTOR", "x": 20.0, "y": 40.0}))

	var grouped := await h("minerva_pcb_group_components", _args({
			"component_ids": ["G1", "G2"]}))
	check("group_components succeeds", grouped.get("success", false))
	var gid := str(grouped.get("group_id", ""))
	check("a non-empty group id was minted", not gid.is_empty())

	# The SECOND read path: get_components' own group reporting.
	var comps := await h("minerva_pcb_get_components", _args())
	var seen := {}
	for c in comps.get("components", []):
		var cd: Dictionary = c
		# get_components keys a component by "id" (panel_tools.gd:201).
		var ref := str(cd.get("id", ""))
		if ref == "G1" or ref == "G2":
			seen[ref] = cd
	check("get_components reports both members", seen.size() == 2)
	for ref in seen:
		check_eq("get_components reports %s's group_id as the minted one" % ref,
				str((seen[ref] as Dictionary).get("group_id", "")), gid)

	# The OFFSET leg — the half a "reports membership but not offsets" mutation
	# leaves behind.
	var offset_reply := await h("minerva_pcb_set_group_member_offset", _args({
			"group_id": gid, "component_id": "G2", "dx_mm": 3.0, "dy_mm": 0.0}))
	if offset_reply.get("success", false):
		var after := await h("minerva_pcb_get_components", _args())
		var g2: Dictionary = {}
		for c in after.get("components", []):
			if str((c as Dictionary).get("id", "")) == "G2":
				g2 = c
		check("get_components reports a group_offset for the moved member",
				g2.has("group_offset"))
	else:
		# A refusal is a legitimate outcome (anchor/lock gates) — but it must be
		# an honest one, not a success-shaped nothing.
		check("a refused offset write says why",
				not str(offset_reply.get("error", "")).is_empty())


# ── BT-53. Two independent readers must agree about vias ────────────────────

func _boundary_via_read_paths_agree() -> void:
	_begin_section("BT-53")
	print("\n-- BT-53: list_vias agrees with export_trace_geometry.vias[] --")
	var made: Array = []
	for i in range(3):
		made.append(data.add_via({
			"position": Vector2(30.0 + i * 5.0, 50.0), "size": 0.8, "drill": 0.4,
			"net_name": "BND_NET"}))

	var listed := await h("minerva_pcb_list_vias", _args())
	var exported := await h("minerva_pcb_export_trace_geometry", _args())
	check("both readers succeed",
			listed.get("success", false) and exported.get("success", false))

	var export_vias: Array = (exported.get("trace_data", {}) as Dictionary).get("vias", [])
	check_eq("count agrees", int(listed.get("via_count", -1)), export_vias.size())

	var list_ids: Array = []
	for v in listed.get("vias", []):
		list_ids.append(str((v as Dictionary).get("via_id", "")))
	var export_ids: Array = []
	for v in export_vias:
		export_ids.append(str((v as Dictionary).get("id", "")))
	list_ids.sort()
	export_ids.sort()
	# ID-SET equality, not just arity: a reader that re-mints ids on read agrees
	# on the count forever and never on the identities.
	check("id sets agree (%s == %s)" % [str(list_ids), str(export_ids)],
			list_ids == export_ids)
	for made_id in made:
		check("the via just added is in BOTH readers (%s)" % str(made_id),
				list_ids.has(str(made_id)) and export_ids.has(str(made_id)))

	# POSITIONS, from the two shapes the two readers happen to use.
	var by_id_list := {}
	for v in listed.get("vias", []):
		var vd: Dictionary = v
		by_id_list[str(vd.get("via_id", ""))] = Vector2(
				float(vd.get("x_mm", 0.0)), float(vd.get("y_mm", 0.0)))
	var mismatched: Array = []
	for v in export_vias:
		var vd: Dictionary = v
		var pos: Dictionary = vd.get("position", {})
		var here := Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))
		var vid := str(vd.get("id", ""))
		if by_id_list.has(vid) and not (by_id_list[vid] as Vector2).is_equal_approx(here):
			mismatched.append(vid)
	check("positions agree for every shared id (mismatched: %s)" % str(mismatched),
			mismatched.is_empty())

	# The DELETE leg — the mutation that separates a live reader from a cached
	# one. A stale cache agrees on everything above and diverges only here.
	var victim := str(made[0])
	var deleted := await h("minerva_pcb_delete_via", _args({"via_id": victim}))
	check("delete_via succeeds", deleted.get("success", false))
	var listed2 := await h("minerva_pcb_list_vias", _args())
	var exported2 := await h("minerva_pcb_export_trace_geometry", _args())
	var ids2: Array = []
	for v in listed2.get("vias", []):
		ids2.append(str((v as Dictionary).get("via_id", "")))
	var eids2: Array = []
	for v in (exported2.get("trace_data", {}) as Dictionary).get("vias", []):
		eids2.append(str((v as Dictionary).get("id", "")))
	check("after a delete, neither reader still reports the deleted id",
			not ids2.has(victim) and not eids2.has(victim))
	ids2.sort()
	eids2.sort()
	check("...and the two readers still agree with each other", ids2 == eids2)


# ── G2. THE AGENT-FACING PREFERENCE SURFACE ─────────────────────────────────
#
# WHY THIS SECTION EXISTS. Campaign 2's third promise is "plugin-scoped
# preferences that PERSIST and are READABLE AND WRITABLE BY THE AGENT". The
# boundary carried only the UI half: BT-27/28 pin the panel's seeding order and
# the on-disk file. Nothing pinned minerva_pcb_get_preference /
# minerva_pcb_set_preference — the clause that makes the preference an agent
# surface at all (completeness critic, gap 5).
#
# ORACLE, three representations, none of them the tool's own reply:
#   1. the STORE the panel itself reads — panel.get_preferences(), the accessor
#      PCBPanel's own seeding path calls;
#   2. the panel's SEEDING READ — panel.seeded_trace_width(), a consumer that
#      knows nothing about MCP;
#   3. for the refusals, the STORE's own error text, byte-compared against the
#      tool's (the drift detector this file already applies to zone errors).
# A tool that wrote a private dictionary and read it back would satisfy the
# reply-level round trip perfectly and fail 1 and 2 — which is the FULL mutation.
#
# THE STORE IS PROCESS-WIDE AND PERSISTS TO DISK (user://plugins/data/pcb/
# preferences.json), so this section captures the pre-existing state and puts it
# back before it returns. Leaving a stored width behind would silently re-seed
# every later run of the width-preference suite.
const PREF_TRACE_WIDTH := "trace_width_mm"
## In contract (0.1 … 5.0) and deliberately NOT the registry default (0.25), so a
## tool that answered "default" for everything cannot pass.
const PREF_PROBE_VALUE := 0.37


func _boundary_agent_preference_surface() -> void:
	_begin_section("G2")
	print("\n-- G2: the MCP preference surface round-trips into the store the panel reads --")
	var prefs = panel.get_preferences()
	check("G2 fixture: the panel exposes a preference store", prefs != null)
	if prefs == null:
		return
	check("G2 fixture: %s is a declared key (a rename must red here, not go quiet)"
			% PREF_TRACE_WIDTH, prefs.is_known(PREF_TRACE_WIDTH))

	# Capture-and-restore state.
	var had_stored: bool = prefs.has_stored(PREF_TRACE_WIDTH)
	var prior_value: Variant = prefs.get_value(PREF_TRACE_WIDTH)

	# A board design rule OUTRANKS the preference in seeded_trace_width(), so the
	# seeding leg below would be blind to the preference if one were declared.
	data.design_rules.erase("trace_width_mm")
	check("G2 fixture: the board declares no trace-width rule (leg 2 is not masked)",
			data.design_rule_trace_width() <= 0.0)

	var j0 := _journal_len()
	var h0 := _history_len()

	# ── write through the AGENT surface.
	var wrote := await h("minerva_pcb_set_preference",
			_args({"key": PREF_TRACE_WIDTH, "value": PREF_PROBE_VALUE}))
	check("G2: set_preference succeeds", wrote.get("success", false))
	check_approx("G2: the reply names the STORED value", float(wrote.get("value", -1.0)),
			PREF_PROBE_VALUE)
	check_eq("G2: an in-contract value is not clamped", wrote.get("clamped", true), false)
	check_eq("G2: …and it reports a real change", wrote.get("changed", false), true)

	# ── read it back through the AGENT surface.
	var read := await h("minerva_pcb_get_preference", _args({"key": PREF_TRACE_WIDTH}))
	check("G2: get_preference succeeds", read.get("success", false))
	check_approx("G2: the agent reads back what the agent wrote",
			float(read.get("value", -1.0)), PREF_PROBE_VALUE)
	check_eq("G2: …and reports it as STORED, not defaulted",
			read.get("stored", false), true)
	check("G2: the reply still names the registry default separately "
			+ "(stored != default is observable)",
			read.has("default") and not is_equal_approx(float(read.get("default", -1.0)),
					PREF_PROBE_VALUE))

	# ── LEG 1: the store the PANEL reads, not the reply.
	check_approx("G2: the value is in the store panel.get_preferences() returns",
			prefs.get_float(PREF_TRACE_WIDTH, -1.0), PREF_PROBE_VALUE)
	check("G2: …and the store agrees it was stored, not defaulted",
			prefs.has_stored(PREF_TRACE_WIDTH))

	# ── LEG 2: the panel's own seeding read — a consumer with no idea MCP exists.
	check_approx("G2: the panel's seeded_trace_width() sees the agent's write",
			float(panel.seeded_trace_width()), PREF_PROBE_VALUE)

	check_eq("G2: writing a preference journalled NOTHING (it is not a board edit)",
			_journal_len(), j0)
	check_eq("G2: …and pushed no undo step", _history_len(), h0)

	# ── REFUSALS. Both must refuse, journal nothing, and leave the store alone.
	var bogus := await h("minerva_pcb_set_preference",
			_args({"key": "no_such_preference", "value": 1.0}))
	check_eq("G2: an unknown key is REFUSED", bogus.get("success", true), false)
	# Drift detector: the tool must not own a second copy of the store's message.
	var store_refusal: Dictionary = prefs.set_value("no_such_preference", 1.0)
	check("G2: …verbatim from the store (tool %s == store %s)"
			% [str(bogus.get("error", "")), str(store_refusal.get("error", ""))],
			str(bogus.get("error", "")) == str(store_refusal.get("error", "")))

	var wrong_type := await h("minerva_pcb_set_preference",
			_args({"key": PREF_TRACE_WIDTH, "value": "wide"}))
	check_eq("G2: a wrong-TYPE value is REFUSED", wrong_type.get("success", true), false)
	var store_type_refusal: Dictionary = prefs.set_value(PREF_TRACE_WIDTH, "wide")
	check("G2: …verbatim from the store too (tool %s == store %s)"
			% [str(wrong_type.get("error", "")), str(store_type_refusal.get("error", ""))],
			str(wrong_type.get("error", "")) == str(store_type_refusal.get("error", "")))

	check_eq("G2: neither refusal journalled anything", _journal_len(), j0)
	check_eq("G2: neither refusal pushed an undo step", _history_len(), h0)
	check_approx("G2: neither refusal disturbed the stored value",
			prefs.get_float(PREF_TRACE_WIDTH, -1.0), PREF_PROBE_VALUE)
	check("G2: the refused key was NOT silently adopted",
			not prefs.is_known("no_such_preference")
			and not (prefs.snapshot().get("stored", {}) as Dictionary).has("no_such_preference"))

	var read_bogus := await h("minerva_pcb_get_preference",
			_args({"key": "no_such_preference"}))
	check_eq("G2: reading an unknown key is refused as well",
			read_bogus.get("success", true), false)

	# ── restore.
	if had_stored:
		prefs.set_value(PREF_TRACE_WIDTH, prior_value)
	else:
		prefs.clear_value(PREF_TRACE_WIDTH)
	check("G2: the store was put back the way this section found it",
			prefs.has_stored(PREF_TRACE_WIDTH) == had_stored)


# ── G4. PLUGIN_BUILD MUST MOVE WHEN A SCHEMA_VERSION MOVES ──────────────────
#
# BT-76's orphaned half (review F4). BT-76 already pins the REPLY's plugin_build
# against the source constant; what it explicitly did not author — and what the
# completeness critic recorded as reassigned to nobody — is the ENFORCEMENT: a
# deploy stamp that never moves when the persisted schema does lets an operator
# read a familiar build string off a panel that is speaking a different schema.
#
# REPRESENTATION: all three constants are read out of SOURCE TEXT by regex, from
# three different files. Nothing here calls the running code, so a runtime that
# reported whatever it liked could not satisfy it.
#
# THE INVARIANT IS A PAIRING, NOT A LITERAL PIN. The witness below records the
# values as of authoring. The assertion is:
#
#     (any SCHEMA_VERSION moved) == (PLUGIN_BUILD moved)
#
# so a paired bump stays GREEN — that is the intended path, and asserting it
# explicitly is what stops this pin from being a tax on every legitimate schema
# change. Exactly one of them moving is RED. When you move one on purpose,
# update the witness in the same commit; the diff is then the review artifact
# that says "yes, I considered the other one".
const PREFS_SOURCE_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_prefs.gd"
const SIDECAR_SOURCE_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd"

## The witness pair, as of this test's authoring.
##
## SR2FAB re-baselined PLUGIN_BUILD and NOT the schemas, deliberately: the epoch
## changed reply shapes and added verbs, and it changed no PERSISTED shape —
## pcb_prefs and the routing sidecar both round-trip exactly what they did
## before. The workspace's new degenerate-segment counter is per-call in-memory
## state and never reaches the sidecar. This edit is the review artifact the
## block above asks for.
const WITNESS_PLUGIN_BUILD := "0.2.0+sr2fab"
const WITNESS_PREFS_SCHEMA := "1"
const WITNESS_SIDECAR_SCHEMA := "1"


## `const <name> :=` or `const <name>: <type> =` — both forms appear in these files.
func _const_in_source(source: String, const_name: String) -> String:
	var re := RegEx.new()
	re.compile("const\\s+" + const_name + "\\s*(?::\\s*\\w+\\s*)?:?=\\s*\"?([^\"\\n]*?)\"?\\s*(?:#.*)?$")
	for line in source.split("\n"):
		var m := re.search(line)
		if m != null:
			return m.get_string(1).strip_edges()
	return ""


func _boundary_build_stamp_tracks_schema() -> void:
	_begin_section("G4")
	print("\n-- G4: PLUGIN_BUILD and the persisted SCHEMA_VERSIONs move together --")
	var panel_src := _read_text(PANEL_SOURCE_PATH)
	var prefs_src := _read_text(PREFS_SOURCE_PATH)
	var sidecar_src := _read_text(SIDECAR_SOURCE_PATH)
	check("G4 fixture: all three sources were read",
			panel_src.length() > 100 and prefs_src.length() > 100
			and sidecar_src.length() > 100)

	var build := _const_in_source(panel_src, "PLUGIN_BUILD")
	var prefs_schema := _const_in_source(prefs_src, "SCHEMA_VERSION")
	var sidecar_schema := _const_in_source(sidecar_src, "SCHEMA_VERSION")
	check("G4: PCBPanel.gd declares PLUGIN_BUILD (%s)" % build, not build.is_empty())
	check("G4: pcb_prefs.gd declares SCHEMA_VERSION (%s)" % prefs_schema,
			not prefs_schema.is_empty())
	check("G4: pcb_routing_sidecar.gd declares SCHEMA_VERSION (%s)" % sidecar_schema,
			not sidecar_schema.is_empty())

	var schema_moved: bool = prefs_schema != WITNESS_PREFS_SCHEMA \
			or sidecar_schema != WITNESS_SIDECAR_SCHEMA
	var build_moved: bool = build != WITNESS_PLUGIN_BUILD
	check("G4: THE PAIRING — a moved SCHEMA_VERSION and a moved PLUGIN_BUILD "
			+ "travel together (schema_moved=%s build_moved=%s; witness %s/%s/%s)"
			% [str(schema_moved), str(build_moved), WITNESS_PLUGIN_BUILD,
				WITNESS_PREFS_SCHEMA, WITNESS_SIDECAR_SCHEMA],
			schema_moved == build_moved)
	# Stated as its own assertion so the intended path is visible in the log and
	# a future reader cannot mistake this pin for "the build string is frozen".
	check("G4: a PAIRED bump is explicitly allowed (this leg is green whenever "
			+ "both moved or neither did)",
			not (schema_moved != build_moved))

	# The convention has to be DISCOVERABLE, or the next author bumps one and
	# never learns the other exists. PCBPanel.gd's own doc block is where it is
	# written down; a rewrite that drops it reds here.
	var doc_start := panel_src.find("## B2 (MCP parity round)")
	var doc_stop := panel_src.find("const PLUGIN_BUILD")
	var doc_block := panel_src.substr(doc_start, doc_stop - doc_start) \
			if doc_start >= 0 and doc_stop > doc_start else ""
	check("G4: PLUGIN_BUILD's own doc block names the SCHEMA_VERSION convention "
			+ "it is paired with (block starts: %s)" % doc_block.left(60),
			doc_block.contains("SCHEMA_VERSION")
			and doc_block.contains("pcb_prefs.gd")
			and doc_block.contains("pcb_routing_sidecar.gd"))
