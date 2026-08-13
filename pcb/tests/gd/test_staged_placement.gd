extends SceneTree
## Epoch P1 (docket 019ff8b16124; ratified sheet on 019ff8615fbe, comments
## 1179-1181): the PLACEMENT staged kind — build/add pair, the scratch-pose
## update rule (D1), accept-applies-the-move with the C2 parity sweep
## (dangling copper), the C5 collision advisory, and bucket-9 history
## coherence (undo of an accept revives the ghost AND returns the part).
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_staged_placement.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

var _pass := 0
var _fail := 0


class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== Staged placement: build / stage / update / accept / parity ===\n")
	await process_frame
	_run_build_pair()
	_run_stage_and_standing_ghost()
	_run_update_rule()
	_run_accept_applies_move()
	_run_accept_history_coherence()
	_run_accept_drift_refusal()
	_run_dangling_parity_sweep()
	_run_collision_advisory()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


## Two SMD parts on one routed net (N1: R1.2 — R2.1, trace endpoints ON the
## pads) plus one unrouted net — the smallest board where a move can strand
## copper and where the routed flag differs per net.
func _rig() -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	var data = panel.get_data()
	data.from_board_dict({
		"version": 1, "name": "placement", "width_mm": 40.0, "height_mm": 25.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25},
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "R1", "footprint": "R_0805", "value": "1k",
				"x_mm": 10.0, "y_mm": 8.0, "rotation_deg": 0.0, "layer": "top",
				"pins": [
					{"number": "1", "x_mm": -0.95, "y_mm": 0.0, "pad_width_mm": 1.0, "pad_height_mm": 1.45},
					{"number": "2", "x_mm": 0.95, "y_mm": 0.0, "pad_width_mm": 1.0, "pad_height_mm": 1.45},
				]},
			{"ref": "R2", "footprint": "R_0805", "value": "10k",
				"x_mm": 20.0, "y_mm": 8.0, "rotation_deg": 0.0, "layer": "top",
				"pins": [
					{"number": "1", "x_mm": -0.95, "y_mm": 0.0, "pad_width_mm": 1.0, "pad_height_mm": 1.45},
					{"number": "2", "x_mm": 0.95, "y_mm": 0.0, "pad_width_mm": 1.0, "pad_height_mm": 1.45},
				]},
		],
		"nets": [
			{"name": "N1", "pins": ["R1.2", "R2.1"]},
			{"name": "N9", "pins": ["R1.1"]},
		],
		"traces": [
			{"net": "N1", "layer": "top", "width_mm": 0.25,
				"points": [{"x_mm": 10.95, "y_mm": 8.0}, {"x_mm": 19.05, "y_mm": 8.0}]},
		],
		"vias": [],
	})
	data.save_to_history("seed")
	return {"panel": panel, "data": data, "store": panel.get_staged_store()}


func _stage_move(rig: Dictionary, ref: String, x: float, y: float, rot: float,
		author := "ai") -> Dictionary:
	var built: Dictionary = rig["data"].build_placement_payload(ref, x, y, rot)
	if not bool(built.get("ok", false)):
		return built
	var res: Dictionary = rig["panel"].stage_built_payload("placement",
		built.get("payload", {}), author, "test move")
	res["payload"] = built.get("payload", {})
	return res


# ── 1. the build/add pair ─────────────────────────────────────────────────────

func _run_build_pair() -> void:
	print("-- 1. build_placement_payload: shape + refusals --")
	var rig := _rig()
	var built: Dictionary = rig["data"].build_placement_payload("R1", 5.0, 15.0, 90.0)
	check("build ok for a known part", bool(built.get("ok", false)))
	var p: Dictionary = built.get("payload", {})
	check("payload id is a minted placement id", str(p.get("id", "")).begins_with("placement:"))
	check_eq("from captures the CURRENT pose x", float((p.get("from", {}) as Dictionary).get("x_mm", -1.0)), 10.0)
	check_eq("from captures the CURRENT rotation", float((p.get("from", {}) as Dictionary).get("rotation_deg", -1.0)), 0.0)
	check_eq("to carries the proposed pose", float((p.get("to", {}) as Dictionary).get("rotation_deg", -1.0)), 90.0)
	# affected_nets: N1 is routed (a trace exists), N9 is not.
	var routed := {}
	for n in (p.get("affected_nets", []) as Array):
		routed[str((n as Dictionary).get("net", ""))] = bool((n as Dictionary).get("routed", false))
	check_eq("affected_nets flags the ROUTED net", routed.get("N1"), true)
	check_eq("…and the unrouted net honestly", routed.get("N9"), false)

	check("unknown component refuses",
		not bool(rig["data"].build_placement_payload("R9", 1.0, 1.0, 0.0).get("ok", true)))
	rig["data"].get_component("R1").locked = true
	var locked: Dictionary = rig["data"].build_placement_payload("R1", 1.0, 1.0, 0.0)
	check("locked component refuses by name",
		not bool(locked.get("ok", true)) and "locked" in str(locked.get("error", "")))
	rig["data"].get_component("R1").locked = false

	# add half refuses a foreign id and a to-less payload.
	check("add refuses an unminted id",
		(rig["data"].add_placement_payload({"id": "zone:abc", "component_id": "R1",
			"to": {"x_mm": 1.0, "y_mm": 1.0}}) as Dictionary).is_empty())
	check("add refuses a payload without a target pose",
		(rig["data"].add_placement_payload({"id": "placement:abc", "component_id": "R1"}) as Dictionary).is_empty())


# ── 2. staging + the one-live-ghost rule's query ──────────────────────────────

func _run_stage_and_standing_ghost() -> void:
	print("-- 2. stage + live_placement_for_component --")
	var rig := _rig()
	var res := _stage_move(rig, "R1", 5.0, 15.0, 0.0)
	check("placement stages through the one doorway", bool(res.get("ok", false)))
	var sid := str(res.get("staged_id", ""))
	check_eq("live_placement_for_component finds the standing ghost",
		str(rig["store"].live_placement_for_component("R1")), sid)
	check_eq("…and reports none for an unproposed part",
		str(rig["store"].live_placement_for_component("R2")), "")
	rig["panel"].reject_staged(str(res.get("entity_id", "")))
	check_eq("a rejected ghost no longer counts as standing",
		str(rig["store"].live_placement_for_component("R1")), "")


# ── 3. the scratch-pose update rule (D1) ──────────────────────────────────────

func _run_update_rule() -> void:
	print("-- 3. update_placement_target: scratch until verdict --")
	var rig := _rig()
	var res := _stage_move(rig, "R1", 5.0, 15.0, 0.0)
	var sid := str(res.get("staged_id", ""))
	check("a live ghost's target revises", rig["store"].update_placement_target(sid, 7.0, 15.0, 90.0))
	var entry: Dictionary = rig["store"].get_entry(sid)
	var to: Dictionary = (entry.get("payload", {}) as Dictionary).get("to", {})
	check_eq("…and the stored pose moved", [float(to.get("x_mm", 0)), float(to.get("rotation_deg", 0))], [7.0, 90.0])
	check("unknown staged id refuses", not rig["store"].update_placement_target("staged_99", 1.0, 1.0, 0.0))
	check_eq("…by name", str(rig["store"].last_error.get("error", "")), "staged_entry_not_found")
	# Kind gate: a zone draft cannot be pose-updated.
	var z: Dictionary = rig["data"].build_zone_payload("", "top",
		[Vector2(2, 2), Vector2(8, 2), Vector2(8, 8)], "keepout")
	var z_res: Dictionary = rig["panel"].stage_built_payload("zone", z.get("payload", {}), "ai", "")
	check("a zone draft refuses the placement update",
		not rig["store"].update_placement_target(str(z_res.get("staged_id", "")), 1.0, 1.0, 0.0))
	# Terminal gate: accept, then try to revise.
	rig["panel"].accept_staged(str(res.get("entity_id", "")))
	check("a terminal ghost refuses revision", not rig["store"].update_placement_target(sid, 9.0, 9.0, 0.0))
	check_eq("…by name", str(rig["store"].last_error.get("error", "")), "staged_entry_terminal")


# ── 4. accept APPLIES the move ────────────────────────────────────────────────

func _run_accept_applies_move() -> void:
	print("-- 4. accept: the move lands, journalled --")
	var rig := _rig()
	var res := _stage_move(rig, "R2", 30.0, 15.0, 90.0)
	var out: Dictionary = rig["panel"].accept_staged(str(res.get("entity_id", "")))
	check("accept ok", bool(out.get("ok", false)))
	var comp = rig["data"].get_component("R2")
	check_eq("part is AT the target", comp.position, Vector2(30.0, 15.0))
	check_eq("…with the target rotation", float(comp.rotation), 90.0)
	check_eq("entry stamped accepted",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "accepted")


# ── 5. bucket-9 coherence: one undo returns part AND ghost ────────────────────

func _run_accept_history_coherence() -> void:
	print("-- 5. undo of an accept: part back, ghost revived --")
	var rig := _rig()
	var res := _stage_move(rig, "R2", 30.0, 15.0, 0.0)
	rig["panel"].accept_staged(str(res.get("entity_id", "")))
	rig["data"].undo()
	var comp = rig["data"].get_component("R2")
	check_eq("undo returns the part to its pre-accept pose", comp.position, Vector2(20.0, 8.0))
	check_eq("…and revives the ghost",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "staged")
	check_eq("…which live_placement_for_component sees again",
		str(rig["store"].live_placement_for_component("R2")), str(res.get("staged_id", "")))


# ── 6. drift refusal: the board moved on under the draft ──────────────────────

func _run_accept_drift_refusal() -> void:
	print("-- 6. accept re-validates against the CURRENT board --")
	var rig := _rig()
	var res := _stage_move(rig, "R2", 30.0, 15.0, 0.0)
	rig["data"].remove_component("R2")
	var out: Dictionary = rig["panel"].accept_staged(str(res.get("entity_id", "")))
	check("accepting a move of a deleted part refuses", not bool(out.get("ok", true)))
	check("…naming the component", "R2" in str(out.get("note", "")))
	check_eq("…and the draft stays live",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "staged")


# ── 7. C2 parity: the accept reply reports stranded copper ────────────────────

func _run_dangling_parity_sweep() -> void:
	print("-- 7. dangling-copper sweep on placement accepts --")
	var rig := _rig()
	# R2.1 holds one end of N1's trace; moving R2 strands that endpoint.
	var res := _stage_move(rig, "R2", 30.0, 20.0, 0.0)
	var out: Dictionary = rig["panel"].accept_staged(str(res.get("entity_id", "")))
	check("accept ok", bool(out.get("ok", false)))
	var warnings: Array = out.get("dangling_copper", [])
	check("the reply carries the dangling sweep", not warnings.is_empty())
	if not warnings.is_empty():
		var w: Dictionary = warnings[0]
		check_eq("…naming the net", str(w.get("net", "")), "N1")
		var at: Array = w.get("at", [])
		check("…at the OLD pad coordinate (19.05, 8)",
			at.size() == 2 and absf(float(at[0]) - 19.05) < 0.01 and absf(float(at[1]) - 8.0) < 0.01)
	# The sweep keys off the MOVED part's own pins: moving R1 (whose pin 2
	# holds N1's OTHER end) names R1's old pad, not R2's.
	var rig2 := _rig()
	var res2 := _stage_move(rig2, "R1", 5.0, 20.0, 0.0)
	var out2: Dictionary = rig2["panel"].accept_staged(str(res2.get("entity_id", "")))
	var warnings2: Array = out2.get("dangling_copper", [])
	check("moving the other routed part also sweeps", not warnings2.is_empty())
	if not warnings2.is_empty():
		var at2: Array = (warnings2[0] as Dictionary).get("at", [])
		check("…at R1's old pad (10.95, 8)",
			at2.size() == 2 and absf(float(at2[0]) - 10.95) < 0.01)


# ── 8. C5: the collision advisory ─────────────────────────────────────────────

func _run_collision_advisory() -> void:
	print("-- 8. placement_collisions: parts, ghosts, self-exclusion --")
	var rig := _rig()
	# R1 proposed ONTO R2's body: collision with ref R2.
	var hits: Array = rig["data"].placement_collisions("R1", 20.0, 8.0, 0.0, [])
	check("overlapping a placed part is reported", hits.size() == 1)
	if hits.size() == 1:
		check_eq("…naming the part", str((hits[0] as Dictionary).get("ref", "")), "R2")
		check("…with a positive overlap area", float((hits[0] as Dictionary).get("overlap_mm2", 0.0)) > 0.0)
	# A clear pose reports nothing.
	check("a clear pose reports no collisions",
		(rig["data"].placement_collisions("R1", 5.0, 20.0, 0.0, []) as Array).is_empty())
	# Ghost-vs-ghost: R1's proposal collides with R2's TARGET even though
	# R2's body is elsewhere.
	var ghost_hits: Array = rig["data"].placement_collisions("R1", 30.0, 20.0, 0.0,
		[{"component_id": "R2", "x_mm": 30.0, "y_mm": 20.0, "rotation_deg": 0.0}])
	check("a collision with another ghost's TARGET is reported", ghost_hits.size() == 1)
	if ghost_hits.size() == 1:
		check_eq("…flagged as a ghost", bool((ghost_hits[0] as Dictionary).get("ghost", false)), true)
	# Self-exclusion: extras naming the moving part are ignored.
	check("the moving part's own extra body is ignored",
		(rig["data"].placement_collisions("R1", 5.0, 20.0, 0.0,
			[{"component_id": "R1", "x_mm": 5.0, "y_mm": 20.0, "rotation_deg": 0.0}]) as Array).is_empty())
