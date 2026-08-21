extends SceneTree
## ACCEPTANCE — bug 01a022b1b7d5: the routing sidecar's zero-payload rule
## loses task-owned corridor constraints for UNANSWERED intents.
##
## Mechanism (found by the DCR 01a022ab356c design review, P5): an intent
## authored with a corridor stores its routing_constraint on the eager TASK
## (panel_tools.gd _add_route_intent leg (c)); tasks serialize durably in
## to_sidecar_dict ("Tasks ARE durable: … design intent"); but
## PcbRoutingSidecar.save_workspace's zero-payload rule deletes the sidecar
## whenever candidates AND staged entities are empty — TASKS DON'T COUNT. So
## an intent whose router run never landed a candidate loses its corridor
## across save/reload: the annotation survives in .annotations.json, the
## steering silently evaporates, and the next propose runs unguided.
##
## THE CONTRACT THIS SUITE PINS (the fix):
##   * a task carrying a routing_constraint IS payload — the sidecar is
##     written, and load restores the task with its constraint byte-faithful
##     (corridor points, revision, owner_hint_id);
##   * a bare constraint-less task is NOT payload by itself — it is fully
##     reconstructible from its hint on the next propose, so the zero-payload
##     hygiene (and test_workspace_persistence.gd's "zero candidates ⇒ sidecar
##     deleted" pin, which uses a task-free workspace) stands.
##
## RED/GREEN: group 1 MUST fail before the fix (the file is deleted today);
## group 2 must pass before AND after (unchanged-behavior invariant).
##
## Same scaffold conventions as test_workspace_persistence.gd (model-level:
## no panel, no router; plugin_panel_driver temp dirs keep writes contained).
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src --script \
##     res://../../minerva-plugins/pcb/tests/gd/test_sidecar_constraint_survival.gd

const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRoutingSidecar := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PluginPanelDriver := preload("res://test/helpers/plugin_panel_driver.gd")

var _pass := 0
var _fail := 0
var _driver = null


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func _init() -> void:
	print("=== Sidecar constraint survival (bug 01a022b1b7d5) ===\n")
	_driver = PluginPanelDriver.new()
	_run_constrained_task_survives()
	_run_bare_task_is_not_payload()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _temp_board_path(name: String) -> String:
	var dir: String = _driver.make_temp_board_dir("pcb_sidecar_constraint")
	return dir + "/" + name


func _cleanup(board_path: String) -> void:
	var sp := PcbRoutingSidecar.sidecar_path_for(board_path)
	for p in [sp, sp + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _seed_board() -> Object:
	var data = PCBData.new()
	data.set_board_size(80.0, 60.0)
	data.design_rules = {"clearance_mm": 0.2, "min_trace_mm": 0.15}
	return data


## The exact IN-MEMORY constraint shape _add_route_intent leg (c) stores:
## _parse_route_intent_corridor (panel_tools.gd:8425) converts the wire
## [{x_mm,y_mm}] into Array[Vector2] BEFORE it lands on the task (cold review
## finding 1 — a dict-shaped fixture round-trips as zeroed Vector2s and a
## size-only assertion blesses destroyed steering).
func _authored_constraint(hint_id: String, board_revision: int) -> Dictionary:
	return {
		"corridor_points": [Vector2(10.0, 5.0), Vector2(30.0, 25.0)],
		"preferred_layer": "",
		"revision": 1,
		"authored_by": "ai",
		"base_board_revision": board_revision,
		"owner_hint_id": hint_id,
	}


# ── 1. RED: a constrained, candidate-less task must survive save/reload ──────

func _run_constrained_task_survives() -> void:
	print("-- 1. unanswered intent's corridor survives save → reload --")
	var data = _seed_board()
	var board_path := _temp_board_path("constraint_survival.pcbskel")

	var ws = PcbRoutingWorkspace.new()
	var task = ws.ensure_task("VBAT|ann_x", "VBAT")
	task.routing_constraint = _authored_constraint("ann_x", int(data.board_revision))
	check_eq("fixture: zero candidates (the intent is unanswered)",
		ws.candidates.size(), 0)

	var err: int = PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(),
		int(data.board_revision))
	check_eq("1a: save_workspace OK", err, OK)
	check("1b: sidecar EXISTS — a constrained task IS payload",
		PcbRoutingSidecar.has_sidecar(board_path))

	var loaded = PcbRoutingWorkspace.new()
	var status: Dictionary = PcbRoutingSidecar.load_into_workspace(
		board_path, loaded, data.to_board_dict(), int(data.board_revision))
	check_eq("1c: load status loaded_clean", str(status.get("status", "")), "loaded_clean")
	check("1d: the task survives the round trip", loaded.tasks.has("VBAT|ann_x"))
	if loaded.tasks.has("VBAT|ann_x"):
		var rc: Dictionary = loaded.tasks["VBAT|ann_x"].routing_constraint
		# VALUES, not counts (finding 1): the bug is silent steering loss, so
		# the acceptance must prove the geometry itself survived.
		check_eq("1e: corridor point VALUES round-trip",
			rc.get("corridor_points", []), [Vector2(10.0, 5.0), Vector2(30.0, 25.0)])
		check_eq("1f: constraint revision round-trips", int(rc.get("revision", 0)), 1)
		check_eq("1g: owner hint round-trips", str(rc.get("owner_hint_id", "")), "ann_x")

	# ── quarantine (finding 3): the NEW envelope class must survive a board
	# edit between sessions — the realistic field case. Constraint loads,
	# status honestly quarantines, mark_all_stale is a no-op on zero
	# candidates.
	var data2 = _seed_board()
	data2.set_board_size(90.0, 70.0)  # fingerprint diverges from the saved one
	var quarantined = PcbRoutingWorkspace.new()
	var qstatus: Dictionary = PcbRoutingSidecar.load_into_workspace(
		board_path, quarantined, data2.to_board_dict(), int(data2.board_revision))
	check_eq("1h: mismatched board quarantines, never loads clean",
		str(qstatus.get("status", "")), "quarantine_stale")
	check("1i: the task still survives quarantine", quarantined.tasks.has("VBAT|ann_x"))
	if quarantined.tasks.has("VBAT|ann_x"):
		check_eq("1j: corridor values survive quarantine",
			quarantined.tasks["VBAT|ann_x"].routing_constraint.get("corridor_points", []),
			[Vector2(10.0, 5.0), Vector2(30.0, 25.0)])

	_cleanup(board_path)


# ── 2. GREEN invariant: bare tasks alone still mean zero payload ─────────────

func _run_bare_task_is_not_payload() -> void:
	print("\n-- 2. a constraint-less task alone does NOT keep the sidecar alive --")
	var data = _seed_board()
	var board_path := _temp_board_path("bare_task.pcbskel")

	# Pre-existing sidecar seeded via write_envelope DIRECTLY (finding 2: a
	# save_workspace seed is vacuous pre-fix — the zero-payload rule eats it —
	# and unasserted post-fix; a raw envelope write behaves identically in
	# both worlds, keeping this group green before AND after).
	PcbRoutingSidecar.write_envelope(board_path, {
		"schema_version": 1, "board_document_id": "doc_seed",
		"board_fingerprint": "seed", "fingerprint_version": 2,
		"board_revision": 0, "workspace": {"candidates": {}, "tasks": {}}})
	check("2-seed: sidecar exists before the bare-task save",
		PcbRoutingSidecar.has_sidecar(board_path))

	# Now a workspace whose only content is a BARE eager task — fully
	# reconstructible from its hint; not payload.
	var ws = PcbRoutingWorkspace.new()
	ws.ensure_task("GND|ann_y", "GND")
	var err: int = PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(), 0)
	check_eq("2a: save_workspace OK", err, OK)
	check("2b: sidecar deleted — bare tasks are reconstructible, not payload",
		not PcbRoutingSidecar.has_sidecar(board_path))

	_cleanup(board_path)
