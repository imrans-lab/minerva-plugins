extends SceneTree
## Epoch UX4 station 4 (docket 019fe081a46c; DCR 019fe07523ca S4, A7):
## KIND_STAGED — staged-entity render source, pick, selection-checklist sites,
## the context-menu seam, and the panel doorways (point / get_selection).
##
## Immediate-mode rule (inherited from the candidate canvas suite): no pixel is
## asserted. The staged draw (_draw_staged_entities → _draw_zone/_draw_cutout
## ghost mode) walks store.staged_entries() under the kind toggles + layer
## filter — which is EXACTLY what the pick (_staged_at) walks — so every
## geometry assertion here is on the pick, the strongest statement available:
## rendered set == hit-test set == store's live set.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_staged_canvas.gd

const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const StagedEntities := preload("res://../../minerva-plugins/pcb/ui/model/pcb_staged_entities.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0
var _notices: Array = []
var _verbs: Array = []


class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== KIND_STAGED canvas render/selection Tests ===\n")
	await process_frame
	_run_pick_and_visibility()
	_run_ladder_rung()
	_run_checklist_refusals()
	_run_box_select_and_prune()
	_run_menu_seam()
	_run_dash_pairing()
	_run_panel_doorways()
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


const TRI := [Vector2(2, 2), Vector2(8, 2), Vector2(8, 8)]
const TRI_INSIDE := Vector2(6.0, 4.0)   # inside TRI, hand-checked
const TRI_OUTSIDE := Vector2(3.0, 7.0)  # outside TRI (below the hypotenuse)
const CUT_TRI := [Vector2(20, 20), Vector2(26, 20), Vector2(26, 26)]
const CUT_INSIDE := Vector2(24.0, 22.0)


## Board with a declared net + two layers; canvas bound to it and to a staged
## store holding one staged keepout zone (TRI, top) and one staged cutout
## (CUT_TRI). Returns {canvas, data, store, zone_id, cutout_id}.
func _rig() -> Dictionary:
	var d = PCBData.new()
	d.from_board_dict({
		"version": 1, "name": "staged-canvas", "width_mm": 40.0, "height_mm": 40.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [], "nets": [{"name": "GND", "pins": []}],
		"traces": [], "vias": [],
	})
	var canvas = PcbCanvasScript.new()
	canvas.zoom = 10.0
	canvas.data = d
	var store = StagedEntities.new()
	var zone: Dictionary = d.build_zone_payload("", "top", TRI, "keepout").get("payload", {})
	var cutout: Dictionary = d.build_cutout_payload(CUT_TRI).get("payload", {})
	store.stage("zone", zone, "ai")
	store.stage("cutout", cutout, "human")
	canvas.set_staged_store(store)
	return {"canvas": canvas, "data": d, "store": store,
		"zone_id": str(zone.get("id", "")), "cutout_id": str(cutout.get("id", ""))}


# ── 1. pick == drawn set: kind toggles + layer filter ─────────────────────────

func _run_pick_and_visibility() -> void:
	print("-- 1. _staged_at: canonical-id pick under the draw's own gates --")
	var rig := _rig()
	var canvas = rig["canvas"]

	check_eq("a click inside the staged zone picks its CANONICAL id",
		canvas._staged_at(TRI_INSIDE), rig["zone_id"])
	check_eq("…outside it picks nothing", canvas._staged_at(TRI_OUTSIDE), "")
	check_eq("inside the staged cutout picks the cutout draft",
		canvas._staged_at(CUT_INSIDE), rig["cutout_id"])

	canvas.show_zones = false
	check_eq("show_zones off hides the zone draft from the pick (pick == drawn)",
		canvas._staged_at(TRI_INSIDE), "")
	check_eq("…but the cutout draft still picks (its own toggle)",
		canvas._staged_at(CUT_INSIDE), rig["cutout_id"])
	canvas.show_zones = true
	canvas.show_cutouts = false
	check_eq("show_cutouts off hides the cutout draft",
		canvas._staged_at(CUT_INSIDE), "")
	canvas.show_cutouts = true

	canvas.trace_layer_filter = "bottom"
	check_eq("layer filter: a top-layer zone draft neither draws nor picks",
		canvas._staged_at(TRI_INSIDE), "")
	check_eq("…while the layer-less cutout draft is untouched",
		canvas._staged_at(CUT_INSIDE), rig["cutout_id"])
	canvas.trace_layer_filter = "all"

	# Terminal entries leave the drawn set, so they leave the pick.
	rig["store"].reject(rig["store"].staged_id_for_entity(rig["zone_id"]))
	check_eq("a rejected draft no longer picks", canvas._staged_at(TRI_INSIDE), "")
	canvas.free()


# ── 2. ladder rung: above board zones, below components ───────────────────────

func _run_ladder_rung() -> void:
	print("-- 2. _entity_at rung order --")
	var rig := _rig()
	var canvas = rig["canvas"]
	var d = rig["data"]

	# A committed board zone under the SAME footprint as the staged draft.
	var board_zone: Dictionary = d.create_zone("", "top", TRI, "keepout")
	check("(fixture) board zone landed", not board_zone.is_empty())
	var hit: Array = canvas._entity_at(TRI_INSIDE)
	check_eq("staged wins over the board zone it overlaps (the draft is what's under review)",
		str(hit[0]), canvas.KIND_STAGED)
	check_eq("…by canonical id", str(hit[1]), rig["zone_id"])

	# A component on top of the draft: the component keeps the click — an area
	# claim must not make parts unclickable.
	var comp = PCBComponent.new()
	comp.id = "U9"
	comp.position = TRI_INSIDE
	d.add_component(comp)
	check_eq("(fixture) the component is pickable there", canvas._component_at(TRI_INSIDE), "U9")
	var over: Array = canvas._entity_at(TRI_INSIDE)
	check_eq("a component over the draft still picks as a component", str(over[0]), canvas.KIND_COMPONENT)
	canvas.free()


# ── 3. checklist refusals: move / delete / lock / count ───────────────────────

func _run_checklist_refusals() -> void:
	print("-- 3. checklist sites: the deliberate refusals, each announced --")
	var rig := _rig()
	var canvas = rig["canvas"]
	var store = rig["store"]
	var zone_id: String = rig["zone_id"]

	canvas._add_to_selection(canvas.KIND_STAGED, zone_id)
	check("staged selects through the standard choke point",
		canvas.is_entity_selected(canvas.KIND_STAGED, zone_id))
	check_eq("…and selection_snapshot reports it under 'staged'",
		(canvas.selection_snapshot().get("staged", []) as Array).size(), 1)
	check_eq("…but selection_count() excludes it (board-batch gates untouched)",
		canvas.selection_count(), 0)

	check("staged reports unlocked (protected by refusal, not by flag)",
		not canvas._is_entity_locked(canvas.KIND_STAGED, zone_id))

	canvas._capture_drag_origins()
	check("drag captures NOTHING for a staged-only selection",
		not canvas._drag_origins.has(canvas.KIND_STAGED) and canvas._drag_origins.is_empty())

	check("_remove_entity backstop refuses staged",
		not canvas._remove_entity(canvas.KIND_STAGED, zone_id))

	# Delete: notice emitted, store untouched, entry still live.
	_notices.clear()
	canvas.component_lock_changed.connect(func(msg: String) -> void: _notices.append(msg))
	canvas._delete_selection()
	check("Delete over a staged selection ANNOUNCES the skip",
		_notices.size() >= 1 and str(_notices[0]).contains("staged draft"))
	check("…naming Reject as the real verb", str(_notices[0]).contains("Reject"))
	check_eq("…and the draft is still live in the store",
		str(store.get_entry(store.staged_id_for_entity(zone_id)).get("disposition", "")), "staged")

	# Eraser: refusal names Reject, store untouched.
	_notices.clear()
	canvas.trace_tool_message.connect(func(msg: String) -> void: _notices.append(msg))
	canvas._handle_eraser_click(TRI_INSIDE)
	check("the eraser refuses a staged draft with a notice",
		_notices.size() == 1 and str(_notices[0]).contains("staged draft"))
	check("…naming Reject", str(_notices[0]).contains("Reject"))
	check_eq("…and the store is untouched",
		str(store.get_entry(store.staged_id_for_entity(zone_id)).get("disposition", "")), "staged")

	# Anchor = payload centroid (TRI centroid = (6, 4)).
	var anchor: Vector2 = canvas._entity_anchor(canvas.KIND_STAGED, zone_id)
	check("anchor is the payload centroid",
		anchor.is_equal_approx(Vector2(6.0, 4.0)))

	# Clear drops staged with everything else.
	canvas._add_to_selection(canvas.KIND_STAGED, zone_id)
	canvas._clear_selection()
	check("clear-selection drops the staged ids too",
		not canvas.is_entity_selected(canvas.KIND_STAGED, zone_id))
	canvas.free()


# ── 4. box-select includes; store changes prune the selection ─────────────────

func _run_box_select_and_prune() -> void:
	print("-- 4. marquee inclusion (the DCR's ruled divergence) + live-set prune --")
	var rig := _rig()
	var canvas = rig["canvas"]

	# Sweep a box around TRI only (the zone draft, not the cutout at 20..26).
	canvas.box_select_start = canvas.world_to_screen(Vector2(0.0, 0.0))
	canvas.box_select_end = canvas.world_to_screen(Vector2(10.0, 10.0))
	canvas._finalize_box_selection()
	check("the marquee sweeps the staged zone in (box-select INCLUDES staged)",
		canvas.is_entity_selected(canvas.KIND_STAGED, rig["zone_id"]))
	check("…and not the draft outside the box",
		not canvas.is_entity_selected(canvas.KIND_STAGED, rig["cutout_id"]))

	# A hidden kind does not sweep (same gate as the pick).
	canvas._clear_selection()
	canvas.show_zones = false
	canvas.box_select_start = canvas.world_to_screen(Vector2(0.0, 0.0))
	canvas.box_select_end = canvas.world_to_screen(Vector2(10.0, 10.0))
	canvas._finalize_box_selection()
	check("a hidden zone draft is not swept (sweep == drawn)",
		not canvas.is_entity_selected(canvas.KIND_STAGED, rig["zone_id"]))
	canvas.show_zones = true

	# PRUNE: selection follows the live set through the store's changed signal.
	canvas._add_to_selection(canvas.KIND_STAGED, rig["zone_id"])
	rig["store"].reject(rig["store"].staged_id_for_entity(rig["zone_id"]))
	check("a rejected draft leaves the selection (store.changed prunes)",
		not canvas.is_entity_selected(canvas.KIND_STAGED, rig["zone_id"]))
	canvas.free()


# ── 5. context-menu seam: identity + the two verbs, nothing dead ──────────────

func _run_menu_seam() -> void:
	print("-- 5. staged menu seam: identity line + Accept/Reject, no Delete --")
	var rig := _rig()
	var canvas = rig["canvas"]
	canvas._create_context_menu()
	canvas._context_menu_target = canvas._entity_at(TRI_INSIDE)
	canvas.context_menu_world_pos = TRI_INSIDE
	check_eq("(fixture) the press resolved the staged draft",
		str(canvas._context_menu_target[0]), canvas.KIND_STAGED)
	canvas._update_context_menu_for_selection()

	var texts: Array = []
	var accept_idx := -1
	var reject_idx := -1
	for i in range(canvas.context_menu.item_count):
		var t: String = canvas.context_menu.get_item_text(i)
		texts.append(t)
		match canvas.context_menu.get_item_id(i):
			canvas.MENU_ID_STAGED_ACCEPT:
				accept_idx = i
			canvas.MENU_ID_STAGED_REJECT:
				reject_idx = i
	check("first item is a DISABLED identity line naming the draft",
		canvas.context_menu.item_count > 0 and canvas.context_menu.is_item_disabled(0)
		and str(texts[0]).contains(rig["zone_id"]))
	check("…which states the entity kind (keepout) and layer",
		str(texts[0]).contains("keepout") and str(texts[0]).contains("top"))
	check("Accept is offered and live", accept_idx >= 0
		and not canvas.context_menu.is_item_disabled(accept_idx))
	check("Reject is offered and live", reject_idx >= 0
		and not canvas.context_menu.is_item_disabled(reject_idx))
	var has_delete := false
	for t in texts:
		if str(t).begins_with("Delete"):
			has_delete = true
	check("NO Delete item on a draft (the dead-entry rule)", not has_delete)

	# The verbs ANNOUNCE — the canvas never touches store or board itself.
	canvas.staged_verb_requested.connect(
		func(verb: String, eid: String) -> void: _verbs.append([verb, eid]))
	canvas._on_context_menu_pressed(canvas.MENU_ID_STAGED_ACCEPT)
	canvas._on_context_menu_pressed(canvas.MENU_ID_STAGED_REJECT)
	check_eq("Accept emits staged_verb_requested('accept', canonical id)",
		str(_verbs[0]), str(["accept", rig["zone_id"]]))
	check_eq("Reject emits the reject twin",
		str(_verbs[1]), str(["reject", rig["zone_id"]]))
	check_eq("…and the store was NOT touched by either (panel owns the transactions)",
		str(rig["store"].get_entry(rig["store"].staged_id_for_entity(rig["zone_id"])).get("disposition", "")),
		"staged")
	canvas.free()


# ── 6. A7: the dash-pairing rule, pinned as numbers ───────────────────────────

func _run_dash_pairing() -> void:
	print("-- 6. A7 dash pairing: staged area dash vs stale stroke dash --")
	var canvas = PcbCanvasScript.new()
	check_eq("stale stroke dash period is 6px", float(canvas.CANDIDATE_STALE_DASH_PX), 6.0)
	check_eq("staged area outline dash period is 12px", float(canvas.STAGED_OUTLINE_DASH_PX), 12.0)
	check("the staged period is at least 2x the stale period — the two dashed meanings stay distinguishable",
		float(canvas.STAGED_OUTLINE_DASH_PX) >= 2.0 * float(canvas.CANDIDATE_STALE_DASH_PX))
	canvas.free()


# ── 7. panel doorways: point_at_entity + get_selection enrichment ─────────────

func _run_panel_doorways() -> void:
	print("-- 7. panel doorways: point kind 'staged', get_selection 'staged' entries --")
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	var data = panel.get_data()
	data.from_board_dict({
		"version": 1, "name": "doorway", "width_mm": 40.0, "height_mm": 40.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top"], "components": [], "nets": [], "traces": [], "vias": [],
	})
	var store = panel.get_staged_store()
	var zone: Dictionary = data.build_zone_payload("", "top", TRI, "keepout").get("payload", {})
	store.stage("zone", zone, "ai", 0, "keep the antenna clear")
	var zone_id := str(zone.get("id", ""))

	var pointed: Dictionary = panel.point_at_entity("staged", zone_id)
	check("minerva_pcb_point accepts kind 'staged'", bool(pointed.get("ok", false)))
	var canvas = panel._canvas
	check("…and the draft is lit on the canvas",
		canvas != null and canvas.is_entity_selected(canvas.KIND_STAGED, zone_id))

	# get_selection: the staged entry carries the store's "what's this" answer.
	var host = panel.get_annotation_host()
	var reply: Dictionary = PanelTools._get_selection(host, {})
	var found: Dictionary = {}
	var sel: Array = (reply.get("result", {}) as Dictionary).get("selection", []) \
		if reply.get("result", null) is Dictionary else reply.get("selection", [])
	for e in sel:
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "staged":
			found = e
	check("get_selection reports a 'staged' entry", not found.is_empty())
	check_eq("…with the canonical id", str(found.get("id", "")), zone_id)
	check_eq("…the entity kind", str(found.get("entity_kind", "")), "zone")
	check_eq("…the author", str(found.get("author", "")), "ai")
	check_eq("…and the note", str(found.get("note", "")), "keep the antenna clear")

	# Pointing at a TERMINAL draft refuses — nothing would light.
	store.reject(store.staged_id_for_entity(zone_id))
	var refused: Dictionary = panel.point_at_entity("staged", zone_id)
	check("pointing at a rejected draft refuses (not_found — terminal entries draw nothing)",
		not bool(refused.get("ok", false)))
	panel.free()
