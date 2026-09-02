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
const StagedEntities := preload("res://../../minerva-plugins/pcb/ui/model/pcb_staged_entities.gd")

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
	_run_freeze_settles_the_pose()
	_run_draft_check_board_seam()
	_run_freeze_doorway()
	_run_compose_provenance()
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
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25},
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


# ── 9. freeze settles the pose (epoch GA, K7 019fa6ed3f60) ────────────────────
#
# ORACLE NOTE. None of these assertions asks the store whether it thinks an
# entry is frozen — that would be the code grading itself with the same field
# it just wrote. Each one reads a DIFFERENT representation:
#   * the PAYLOAD's target pose  (did the refused drag actually not land?)
#   * the COMPOSED BOARD dict    (does a frozen ghost still reach consumers?)
#   * the SERIALIZED sidecar     (does frozen survive a round trip and still
#                                 reserve its canonical id?)
# The composed-board assertions are the ones that would have caught the
# tempting-but-wrong implementation of this feature: leaving staged_entries()
# filtering on the literal "staged" makes a frozen ghost vanish from the
# composer, the canvas and the MCP list, and every disposition-field assertion
# would still pass.

func _run_freeze_settles_the_pose() -> void:
	print("\n-- 9. freeze: the pose is settled, the ghost stays in play --")
	var rig := _rig()
	var store = rig["store"]
	var staged: Dictionary = _stage_move(rig, "R1", 14.0, 8.0, 0.0)
	var sid := str(staged.get("staged_id", ""))
	check("a move is staged to freeze", not sid.is_empty())

	check("freeze a live placement", store.freeze(sid))

	# ORACLE 1 — the refusal has teeth: the PAYLOAD is unchanged. A verb that
	# returns false while still writing the pose would pass a return-value
	# assertion and fail this one.
	check("a frozen pose refuses revision", not store.update_placement_target(sid, 30.0, 20.0, 90.0))
	check_eq("…and names the refusal",
		str(store.last_error.get("error", "")), StagedEntities.ERR_FROZEN)
	var held: Dictionary = store.get_entry(sid).get("payload", {}).get("to", {})
	check_eq("…the target x is UNCHANGED by the refused drag", float(held.get("x_mm", -1.0)), 14.0)
	check_eq("…the target rotation is UNCHANGED by the refused drag",
		float(held.get("rotation_deg", -1.0)), 0.0)

	# ORACLE 2 — a frozen ghost is still LIVE: it must still reach the one
	# composer, or freezing would silently withdraw the proposal from draft DRC
	# and routing preview. Asserted on the composed board, not on the store.
	var canonical: Dictionary = rig["data"].to_board_dict()
	for purpose in ["route", "geometric"]:
		var composed: Dictionary = StagedEntities.effective_draft_board(canonical, store, purpose)
		var moved := _comp_x(composed, "R1")
		check_eq("frozen placement still composes for '%s'" % purpose, moved, 14.0)
	check_eq("…and the canonical board was NOT mutated by composing",
		_comp_x(canonical, "R1"), 10.0)
	check_eq("…the ghost is still listed as live", store.staged_entries().size(), 1)
	check_eq("…and is reported as frozen in the split view", store.frozen_entries().size(), 1)

	# ORACLE 3 — serialisation round trip. A frozen entry must come back frozen
	# AND must still reserve its canonical id, or a reload could seat a live
	# twin beside it.
	var reloaded = StagedEntities.from_dict(store.to_dict())
	check_eq("frozen survives a sidecar round trip",
		str(reloaded.get_entry(sid).get("disposition", "")), "frozen")
	check_eq("…and still occupies its canonical id after reload",
		reloaded.staged_id_for_entity(str(staged.get("payload", {}).get("id", ""))), sid)

	# UNFREEZE returns the pose to scratch.
	check("unfreeze a frozen placement", store.unfreeze(sid))
	check("…the pose is editable again", store.update_placement_target(sid, 16.0, 9.0, 0.0))
	check_eq("…and the revision landed",
		float(store.get_entry(sid).get("payload", {}).get("to", {}).get("x_mm", -1.0)), 16.0)

	# REFUSALS, each by name.
	check("freeze refuses an unknown entry", not store.freeze("staged_999"))
	check_eq("…names it", str(store.last_error.get("error", "")), StagedEntities.ERR_UNKNOWN_ENTRY)
	check("unfreeze refuses an entry that is not frozen", not store.unfreeze(sid))
	check_eq("…refuses the no-op by name",
		str(store.last_error.get("error", "")), StagedEntities.ERR_BAD_DISPOSITION)

	# Freeze is PLACEMENT-ONLY: a zone has no regenerating consumer, so the
	# vocabulary would be a word without meaning there.
	var zone_payload: Dictionary = rig["data"].build_zone_payload(
		"", "bottom", [Vector2(2, 2), Vector2(6, 2), Vector2(6, 6)], "keepout").get("payload", {})
	var zsid := str(store.stage("zone", zone_payload))
	check("a zone stages", not zsid.is_empty())
	check("freeze refuses a zone", not store.freeze(zsid))
	check_eq("…names the kind refusal",
		str(store.last_error.get("error", "")), StagedEntities.ERR_NOT_FREEZABLE)

	# A terminal entry cannot be frozen — freeze is a live-state verb.
	check("reject the placement", store.reject(sid))
	check("freeze refuses a terminal entry", not store.freeze(sid))
	check_eq("…names the terminal refusal",
		str(store.last_error.get("error", "")), StagedEntities.ERR_TERMINAL)

	# ACCEPT DIRECTLY FROM FROZEN — freeze settles the pose, it does not add a
	# ceremony before landing. Fresh rig: the entry above is terminal now.
	var rig2 := _rig()
	var store2 = rig2["store"]
	var staged2: Dictionary = _stage_move(rig2, "R2", 24.0, 8.0, 0.0)
	var sid2 := str(staged2.get("staged_id", ""))
	check("freeze the second move", store2.freeze(sid2))
	var accepted: Dictionary = rig2["panel"].accept_staged(str(staged2.get("entity_id", "")))
	check("a FROZEN placement accepts without unfreezing first",
		bool(accepted.get("ok", false)))
	check_eq("…and the part actually moved on the board",
		_comp_x(rig2["data"].to_board_dict(), "R2"), 24.0)


## The x of a component in a board dict — the composed-board oracle's reader.
func _comp_x(board: Dictionary, ref: String) -> float:
	for c in board.get("components", []):
		if c is Dictionary and str((c as Dictionary).get("ref", "")) == ref:
			return float((c as Dictionary).get("x_mm", -1.0))
	return -1.0


# ── 10. the K9 wiring itself (epoch GA cold review, finding 4) ────────────────
#
# Composing correctly and actually SENDING the composition are two different
# claims, and before this suite only the first had a test. draft_check_board()
# is the named seam check_draft hands to the worker, so asserting on it pins
# the wiring without needing the IPC hop (which does not run headless).

func _run_draft_check_board_seam() -> void:
	print("\n-- 10. draft DRC scores the materialized board, not the canonical one --")
	var rig := _rig()
	var staged: Dictionary = _stage_move(rig, "R1", 14.0, 8.0, 0.0)
	check("a move is staged for the seam", not str(staged.get("staged_id", "")).is_empty())

	var canonical: Dictionary = rig["data"].to_board_dict()
	var scored: Dictionary = rig["panel"].draft_check_board()
	check_eq("the board draft DRC scores carries the GHOST pose", _comp_x(scored, "R1"), 14.0)
	check_eq("…while the canonical board still carries the real pose",
		_comp_x(canonical, "R1"), 10.0)
	# The regression this pins: check_draft used to send to_board_dict(), so a
	# staged placement could not produce a finding however badly it violated.
	check("the scored board is NOT the canonical board",
		_comp_x(scored, "R1") != _comp_x(canonical, "R1"))

	check("freeze the ghost", rig["store"].freeze(str(staged.get("staged_id", ""))))
	check_eq("a FROZEN placement is still scored by draft DRC",
		_comp_x(rig["panel"].draft_check_board(), "R1"), 14.0)


# ── 11. the freeze DOORWAY and its history transaction (epoch GA round 2) ─────
#
# Round 1 shipped freeze() on the store with no caller, and the round-1 cold
# review's first finding was that the verb writes a disposition BARE — which
# the store's own stamp() docstring calls a latent clobber, because every later
# board snapshot carries the full disposition map, so undoing an unrelated edit
# would restore the pre-freeze value and silently THAW a settled pose. The
# clobber assertion below is the reason this suite exists; it fails against any
# doorway that calls the store without pairing attach_staged_snapshot with
# save_to_history.

func _run_freeze_doorway() -> void:
	print("\n-- 11. freeze doorway: both hands, and the history pairing --")
	var rig := _rig()
	var staged: Dictionary = _stage_move(rig, "R1", 14.0, 8.0, 0.0)
	var eid := str(staged.get("entity_id", ""))
	var sid := str(staged.get("staged_id", ""))

	# A CHECKPOINT BETWEEN STAGE AND FREEZE. Without it this whole section is
	# vacuous (epoch GA round-2 re-review, finding 2): the only earlier history
	# entry is the seed, taken before anything was staged, so its bucket-9 map
	# is EMPTY — and restoring an empty map touches nothing, which means the
	# clobber assertion below would pass even with the history pairing ripped
	# out. This entry carries {sid: "staged"}, so undoing back past an unpaired
	# freeze really would thaw the pose, and the assertion has teeth.
	rig["data"].create_cutout([Vector2(2, 20), Vector2(6, 20), Vector2(6, 23)])
	rig["data"].save_to_history("pre-freeze checkpoint")

	var out: Dictionary = rig["panel"].freeze_staged(eid)
	check("the panel doorway freezes", bool(out.get("ok", false)))
	check_eq("…and reports the state it reached", bool(out.get("frozen", false)), true)
	check_eq("…the store agrees", str(rig["store"].get_entry(sid).get("disposition", "")), "frozen")

	# THE CLOBBER TEST. An unrelated board edit, then undo of THAT edit: the
	# freeze must survive, because it carries its own history entry.
	rig["data"].create_cutout([Vector2(30, 18), Vector2(34, 18), Vector2(34, 22)])
	rig["data"].save_to_history("unrelated cutout")
	check("undo of the UNRELATED edit", rig["data"].undo())
	# The teeth: the entry this lands on is the freeze's OWN, so the pose stays
	# settled. Strip the pairing and it lands on the pre-freeze checkpoint
	# instead, whose map says "staged", and the freeze silently evaporates.
	check_eq("…leaves the freeze STANDING (no silent thaw)",
		str(rig["store"].get_entry(sid).get("disposition", "")), "frozen")
	# …and undoing the freeze itself DOES thaw it, which is what makes the
	# pairing correct rather than merely present.
	check("undo of the freeze entry itself", rig["data"].undo())
	check_eq("…thaws the pose back to staged",
		str(rig["store"].get_entry(sid).get("disposition", "")), "staged")

	# PARITY: the agent doorway reaches the same implementation, with the same
	# vocabulary and the same named refusals.
	var host = rig["panel"].get_annotation_host()
	var mcp: Dictionary = PanelTools._staged_freeze(host, {"entity_id": eid})
	check("the MCP doorway freezes", bool(mcp.get("success", false)))
	check_eq("…and the two doorways agree on the store state",
		str(rig["store"].get_entry(sid).get("disposition", "")), "frozen")
	var refuse_update: Dictionary = PanelTools._placement_update(host, {
		"entity_id": eid, "x_mm": 30.0, "y_mm": 20.0})
	check("a frozen pose refuses revision through MCP too",
		not bool(refuse_update.get("success", true)))
	check_eq("…by the store's own name",
		str(refuse_update.get("error", "")), StagedEntities.ERR_FROZEN)

	var mcp_thaw: Dictionary = PanelTools._staged_unfreeze(host, {"entity_id": eid})
	check("the MCP doorway unfreezes", bool(mcp_thaw.get("success", false)))
	check_eq("…and reports the state it reached", bool(mcp_thaw.get("frozen", true)), false)
	var again: Dictionary = PanelTools._staged_unfreeze(host, {"entity_id": eid})
	check("unfreezing a thawed entry refuses rather than silently succeeding",
		not bool(again.get("success", true)))

	# Kind gate through the doorway, not just the store.
	var zpay: Dictionary = rig["data"].build_zone_payload(
		"", "bottom", [Vector2(2, 2), Vector2(6, 2), Vector2(6, 6)], "keepout").get("payload", {})
	var zres: Dictionary = rig["panel"].stage_built_payload("zone", zpay, "ai", "z")
	var zfreeze: Dictionary = PanelTools._staged_freeze(host, {"entity_id": str(zres.get("entity_id", ""))})
	check("MCP freeze refuses a zone", not bool(zfreeze.get("success", true)))
	check_eq("…naming the kind refusal",
		str(zfreeze.get("error", "")), StagedEntities.ERR_NOT_FREEZABLE)
	check("MCP freeze requires an entity_id",
		not bool(PanelTools._staged_freeze(host, {}).get("success", true)))


# ── 12. composer provenance (epoch GA round 2, DCR 019ffc52a541) ─────────────
#
# "One source/provenance record per materialized entity … unsupported judgment
# is explicit indeterminate, never omission." The assertions that carry weight
# are the NEGATIVE ones: an entity the composer skips must be VISIBLE as a skip
# with a named reason, because a silently absent entity is indistinguishable
# from one that was never staged.

func _run_compose_provenance() -> void:
	print("\n-- 12. compose_draft: one record per live entity, skips named --")
	var rig := _rig()
	var store = rig["store"]

	var moved: Dictionary = _stage_move(rig, "R1", 14.0, 8.0, 0.0)
	var cut_payload: Dictionary = rig["data"].build_cutout_payload(
		[Vector2(30, 18), Vector2(34, 18), Vector2(34, 22)]).get("payload", {})
	var cut_sid := str(store.stage("cutout", cut_payload))
	check("a cutout stages beside the placement", not cut_sid.is_empty())

	var pair: Dictionary = StagedEntities.compose_draft(
		rig["data"].to_board_dict(), store, "geometric")
	check("compose_draft returns a board", pair.get("board", null) is Dictionary)
	var prov: Array = pair.get("provenance", [])
	check_eq("one record per LIVE entity", prov.size(), 2)

	var by_kind := {}
	for r in prov:
		by_kind[str((r as Dictionary).get("kind", ""))] = r
	var prec: Dictionary = by_kind.get("placement", {})
	var crec: Dictionary = by_kind.get("cutout", {})

	check_eq("the placement reached the board", bool(prec.get("materialized", false)), true)
	check_eq("…and records the store it came from", str(prec.get("source", "")), "staged_entities")
	check_eq("…and its staged id", str(prec.get("staged_id", "")), str(moved.get("staged_id", "")))
	check_eq("…and its disposition", str(prec.get("disposition", "")), "staged")

	# THE NEGATIVE HALF: a deliberate exclusion is recorded, not omitted.
	check_eq("the cutout did NOT reach the board", bool(crec.get("materialized", true)), false)
	check("…and says why, by name", not str(crec.get("reason", "")).is_empty())

	# A placement naming a component that is gone must be a NAMED skip, not a
	# silent absence — the two-store-drift case.
	var rig2 := _rig()
	var orphan: Dictionary = _stage_move(rig2, "R2", 24.0, 8.0, 0.0)
	rig2["data"].remove_component("R2")
	var prov2: Array = StagedEntities.compose_draft(
		rig2["data"].to_board_dict(), rig2["store"], "geometric").get("provenance", [])
	check_eq("the orphaned ghost still gets a record", prov2.size(), 1)
	check_eq("…marked not materialized", bool((prov2[0] as Dictionary).get("materialized", true)), false)
	check("…naming the missing component",
		"R2" in str((prov2[0] as Dictionary).get("reason", "")))
	check_eq("…and it is the ghost we staged", str((prov2[0] as Dictionary).get("staged_id", "")),
		str(orphan.get("staged_id", "")))

	# A FROZEN entity is live, so it is composed AND recorded as frozen.
	check("freeze the placement", store.freeze(str(moved.get("staged_id", ""))))
	var prov3: Array = StagedEntities.compose_draft(
		rig["data"].to_board_dict(), store, "geometric").get("provenance", [])
	var froze_rec := {}
	for r in prov3:
		if str((r as Dictionary).get("kind", "")) == "placement":
			froze_rec = r
	check_eq("a frozen entity is still materialized", bool(froze_rec.get("materialized", false)), true)
	check_eq("…and its disposition is recorded honestly",
		str(froze_rec.get("disposition", "")), "frozen")

	# Back-compat: the old accessor still returns the board alone.
	check_eq("effective_draft_board still returns the board",
		_comp_x(StagedEntities.effective_draft_board(
			rig["data"].to_board_dict(), store, "geometric"), "R1"), 14.0)
