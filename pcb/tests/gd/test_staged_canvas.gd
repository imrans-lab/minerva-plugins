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
	_run_capture_mirrors_the_draft_layer()
	_run_fab_preview_accounting()
	_run_approximation_notice()
	_run_library_lock_round_trip()
	_run_fabrication_round_trip()
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
		"design_rules": {"clearance_mm": 0.2},
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
		"design_rules": {"clearance_mm": 0.2},
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


# ── 8. the capture copy carries EVERYTHING that decides the picture ──────────
#
# The previous version of this section claimed to catch "deleting any line of
# the mirror" and did not: it asserted about twelve of some twenty-six fields,
# so deleting most of them passed. That is the vacuous-test class, and it was
# caught by review rather than by the suite, which is luck.
#
# The mirror is now a LIST plus a loop, which creates a new trap: a test that
# simply walks the same list is circular — delete a field from the list and the
# test's own loop shrinks with it. So this section has two independent halves:
#
#   (a) a HARDCODED demand, written here and owing nothing to the
#       implementation, that specific fields are in the mirrored set; and
#   (b) a MECHANISM check that every listed field actually survives the copy.
#
# (a) catches removing a field from the list. (b) catches breaking the copy.

## Fields this suite DEMANDS are mirrored, independent of what the canvas says.
## Each earned its place by having been missing at some point: the draft layer
## (bug 019ff9d84b60), hidden_layers (the GA-1 per-layer eyes), the committed
## selections, and the honesty surfaces added with fab preview.
const MUST_MIRROR := [
	"_staged_store", "_routing_workspace", "_routing_cutover",
	"show_route_candidates", "show_drc_witnesses",
	"hidden_layers",
	"selected_components", "selected_trace_ids", "selected_zone_ids",
	"selected_via_ids", "selected_cutout_ids", "selected_candidate_ids",
	"selected_staged_ids",
	"show_fab_preview", "_fab_preview_layers", "_fab_preview_unrendered",
	"show_approximation_notice", "show_mask", "mask_openings", "mask_view_note",
	"show_zones", "show_cutouts",
]


func _run_capture_mirrors_the_draft_layer() -> void:
	print("-- 8. capture mirror: nothing that decides the picture is left behind --")
	var rig := _rig()
	var canvas = rig["canvas"]

	# (a) INDEPENDENT DEMAND — this list lives in the test, so removing a field
	# from the canvas's mirrored set fails here rather than shrinking the check.
	# ACCUMULATED into ONE assertion on purpose. A check() per field would make
	# this suite's total depend on how many fields the canvas happens to list,
	# and the runner pins that total EXACTLY — a growing mirror would then red
	# the gate for growing. The failure message names the missing fields, so
	# debuggability is better this way, not worse.
	var mirrored: Array = canvas.CAPTURE_MIRRORED_FIELDS
	var missing := []
	for field in MUST_MIRROR:
		if not (field in mirrored):
			missing.append(field)
	check("every field this suite demands is in the mirrored set (missing: %s)"
		% str(missing), missing.is_empty())

	# (b) MECHANISM — give every mirrored field a value distinguishable from a
	# fresh canvas's default, then assert each one survives the copy.
	var fresh = PcbCanvasScript.new()
	var probes := {}
	for field in mirrored:
		var current = canvas.get(field)
		var probe
		if current is bool:
			probe = not bool(fresh.get(field))
		elif current is Dictionary:
			probe = {"__probe": field}
		elif current is Array:
			# Preserve Array[String]'s runtime type. Assigning an untyped literal to
			# those properties is refused by Godot before the mirror even runs,
			# making the old test diagnose seven fake "lost" selections.
			probe = current.duplicate()
			probe.append("__probe_" + str(field))
		elif current is String:
			probe = "__probe_" + str(field)
		else:
			probe = null  # object refs: exercised explicitly below
		if probe != null:
			canvas.set(field, probe)
			probes[field] = probe

	# Object-valued state, set explicitly so the reference identity is checked.
	var workspace := {"marker": "ws"}
	var cutover := {"marker": "co"}
	canvas._routing_workspace = workspace
	canvas._routing_cutover = cutover

	var copy = PcbCanvasScript.new()
	canvas.mirror_capture_state_onto(copy)

	var lost := []
	for field in probes:
		if copy.get(field) != probes[field]:
			lost.append(field)
	check("every mirrored field survives the copy (lost: %s)" % str(lost),
		lost.is_empty())
	check("the staged store reaches the copy", copy._staged_store == rig["store"])
	check("the routing workspace reaches the copy", copy._routing_workspace == workspace)
	# The cutover gates candidate drawing ENTIRELY: a missing one reads as OFF,
	# so omitting it blanks that layer while everything else looks correct.
	check("the routing CUTOVER reaches the copy", copy._routing_cutover == cutover)

	# CONTAINERS ARE COPIES, not shares — a capture must never be able to edit
	# live selection or layer-visibility state.
	copy.selected_staged_ids.append("intruder")
	check_eq("selection is duplicated, not shared",
		canvas.selected_staged_ids.has("intruder"), false)
	copy.hidden_layers["intruder"] = true
	check_eq("hidden_layers is duplicated, not shared",
		canvas.hidden_layers.has("intruder"), false)

	check_eq("the board itself is not mirrored here (the caller sets it)",
		copy.data, null)


# ── 9. fab preview accounting (WYSIWYG G5, K27) ──────────────────────────────
#
# MUTATION THIS SECTION CATCHES: dropping a layer the ENGINE cannot rasterize
# instead of moving it to `unrendered`. The worker guarantees every emitted file
# appears in exactly one of its two lists; that guarantee dies at this boundary
# if the canvas silently discards an SVG it fails to parse, and the viewer would
# then read a short stack as the complete artifact set.

func _run_fab_preview_accounting() -> void:
	print("-- 9. fab preview: every emitted file stays accounted for --")
	var canvas = PcbCanvasScript.new()
	var good := "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\" viewBox=\"0 0 8 8\"><rect width=\"8\" height=\"8\"/></svg>"

	canvas.set_fab_preview([
		{"name": "F_Cu.gbr", "kind": "gerber", "sha256": "aa", "byte_length": 10, "svg": good},
		{"name": "B_Cu.gbr", "kind": "gerber", "sha256": "bb", "byte_length": 11, "svg": "not svg at all"},
		{"name": "PTH.drl", "kind": "drill", "sha256": "cc", "byte_length": 12, "svg": ""},
	], [{"name": "board.gbrjob", "reason": "job manifest — metadata, not artwork"}], "3 layers")

	# The worker's own skip survives the hand-off…
	var un: Array = canvas._fab_preview_unrendered
	var names := []
	for u in un:
		names.append(str((u as Dictionary).get("name", "")))
	check("the worker's skip is preserved", "board.gbrjob" in names)
	# …and the two the ENGINE could not rasterize JOIN it rather than vanishing.
	check("an unparseable SVG is reported, not dropped", "B_Cu.gbr" in names)
	check("an EMPTY SVG is reported, not dropped", "PTH.drl" in names)
	check_eq("nothing is silently lost: 1 worker skip + 2 engine failures",
		un.size(), 3)
	for u in un:
		check("…each carries a reason", not str((u as Dictionary).get("reason", "")).is_empty())

	check_eq("only the renderable layer is drawable", canvas._fab_preview_layers.size(), 1)
	check_eq("…and it keeps its file identity",
		str((canvas._fab_preview_layers[0] as Dictionary).get("sha256", "")), "aa")

	# A fresh reply REPLACES the previous accounting — a stale unrendered entry
	# would accuse the current artifacts of a failure that is not theirs.
	canvas.set_fab_preview([{"name": "F_Cu.gbr", "kind": "gerber", "sha256": "dd",
		"byte_length": 10, "svg": good}], [], "1 layer")
	check_eq("a new reply clears the previous unrendered set",
		canvas._fab_preview_unrendered.size(), 0)
	check_eq("…and the previous layers", canvas._fab_preview_layers.size(), 1)

	# THE ACTIVATION PATH (unified review finding 1). The worker method, the
	# broker channel, the round-trip and the draw path can all be correct and
	# the feature still be unreachable, because nothing turns it on. That is
	# exactly what shipped in the first cut of this work: _refresh_fab_preview
	# had zero callers and no control set show_fab_preview. A pipeline with no
	# switch is not a feature, and no other assertion in this suite notices.
	var panel: Variant = load(PANEL_PATH).new()
	var flags: Array = panel.get("_VIEW_FLAGS")
	var toggles := []
	for f in flags:
		toggles.append(str((f as Array)[1]))
	check("the View menu can turn the fab preview ON",
		"show_fab_preview" in toggles)
	check("…and the mask overlay is still reachable beside it",
		"show_mask" in toggles)

	# Capture parity: a screenshot taken in preview mode must show the ARTWORK.
	var copy = PcbCanvasScript.new()
	canvas.show_fab_preview = true
	canvas.mirror_capture_state_onto(copy)
	check_eq("preview mode reaches the capture copy", bool(copy.show_fab_preview), true)
	check_eq("…with its rasterized layers", copy._fab_preview_layers.size(), 1)


# ── 10. the approximation notice is DERIVED, not recited ─────────────────────
#
# MUTATION THIS SECTION CATCHES: replacing approximation_notes() with a fixed
# string. The DCR does not require this canvas to be pixel-exact — it requires
# an approximation to be MARKED. A notice that lists approximations the board
# does not have is worse than none: it trains the reader to ignore the one
# place the editor admits its limits, and then the real disclosure goes unread.

func _run_approximation_notice() -> void:
	print("-- 10. approximation notice: derived from what is on screen --")

	# A board with NO zones must not be told its zone fill is schematic.
	var bare = PCBData.new()
	bare.from_board_dict({
		"version": 1, "name": "bare", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"], "components": [], "nets": [],
		"traces": [], "vias": [],
	})
	var c1 = PcbCanvasScript.new()
	c1.data = bare
	c1.show_mask = true
	var bare_notes: Array = c1.approximation_notes()
	var bare_text := "\n".join(PackedStringArray(bare_notes))
	check("a zone-less board is NOT told its zone fill is approximate",
		not ("zone fill" in bare_text))
	check("a component-less board is NOT told about paste",
		not ("paste" in bare_text))
	check("with the mask overlay ON, it is not listed as hidden",
		not ("mask" in bare_text))

	# A board that HAS the geometry gets told, in the same run.
	var rich = PCBData.new()
	rich.from_board_dict({
		"version": 1, "name": "rich", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [{"ref": "R1", "footprint": "R_0805", "value": "1k",
			"x_mm": 5.0, "y_mm": 5.0, "rotation_deg": 0.0, "layer": "top",
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
				"pad_width_mm": 1.0, "pad_height_mm": 1.0}]}],
		"nets": [], "traces": [], "vias": [],
		"zones": [{"id": "zone:1", "kind": "copper_pour", "layer": "top", "net": "",
			"outline": [{"x_mm": 1.0, "y_mm": 1.0}, {"x_mm": 9.0, "y_mm": 1.0},
				{"x_mm": 9.0, "y_mm": 9.0}]}],
	})
	var c2 = PcbCanvasScript.new()
	c2.data = rich
	c2.show_mask = false
	var rich_text := "\n".join(PackedStringArray(c2.approximation_notes()))
	check("a board WITH zones is told its fill is outline-only", "zone fill" in rich_text)
	check("…and that the fab receives a carved pour", "carved" in rich_text)
	check("a board with pads is told paste is not drawn", "paste" in rich_text)
	check("a hidden mask overlay is disclosed", "mask" in rich_text)

	# Hiding zones removes the zone claim: the notice describes THIS VIEW, not
	# the board in the abstract.
	c2.show_zones = false
	check("hiding zones drops the zone-fill note",
		not ("zone fill" in "\n".join(PackedStringArray(c2.approximation_notes()))))

	# The disclosure rides along to agent screenshots.
	var copy = PcbCanvasScript.new()
	c2.mirror_capture_state_onto(copy)
	check_eq("the notice setting reaches the capture copy",
		bool(copy.show_approximation_notice), true)


# ── 11. the panel does not destroy a board's library lock (K20) ──────────────
#
# MUTATION THIS SECTION CATCHES: removing either half of the round-trip.
# to_board_dict REBUILDS the canonical dict from typed fields rather than
# editing the loaded one, so any top-level key this model does not explicitly
# carry is destroyed the first time a user opens a locked board and saves it.
# Silent, total, and indistinguishable from the board never having been locked
# — the panel would quietly un-pin every board it touched.

func _run_library_lock_round_trip() -> void:
	print("-- 11. library_lock survives open → save --")
	var d = PCBData.new()
	var lock := {"Lib:Part": {"sha256": "abc123", "layer": "seed"}}
	d.from_board_dict({
		"version": 1, "name": "locked", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"], "components": [], "nets": [],
		"traces": [], "vias": [], "library_lock": lock,
	})
	var out: Dictionary = d.to_board_dict()
	check("the lock survives the round trip", out.has("library_lock"))
	check_eq("…with its content intact",
		str((out.get("library_lock", {}) as Dictionary).get("Lib:Part", {}).get("sha256", "")),
		"abc123")

	# The model must not ADJUDICATE it — the compiler is the authority on what a
	# board consumed. Anything the panel does not understand still comes back.
	var d2 = PCBData.new()
	d2.from_board_dict({
		"version": 1, "name": "future", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"], "components": [], "nets": [],
		"traces": [], "vias": [],
		"library_lock": {"Lib:Part": {"sha256": "x", "some_future_field": 7}},
	})
	check_eq("an unrecognised pin field is carried verbatim",
		int((d2.to_board_dict().get("library_lock", {}) as Dictionary)
			.get("Lib:Part", {}).get("some_future_field", 0)), 7)

	# An UNLOCKED board must stay byte-identical to before this field existed:
	# emitting an empty block would churn every board's YAML on first open.
	var d3 = PCBData.new()
	d3.from_board_dict({
		"version": 1, "name": "plain", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"], "components": [], "nets": [],
		"traces": [], "vias": [],
	})
	check("an unlocked board emits NO library_lock key",
		not d3.to_board_dict().has("library_lock"))


# ── 12. the panel does not destroy a board's ORDERED APPEARANCE (T1) ──────────
#
# MUTATION THIS SECTION CATCHES: the same silent-drop as the lock above, one
# key over. `fabrication` records what the board was ORDERED to look like — mask
# colour, surface finish, overall thickness — and nothing in the panel edits it,
# which is exactly why it is easy to lose: to_board_dict rebuilds the canonical
# dict from typed fields, so a key this model does not carry is destroyed the
# first time someone opens the board and saves. The board would then quietly
# revert to green/HASL/1.6 with nobody told.

func _run_fabrication_round_trip() -> void:
	print("-- 12. fabrication survives open → save --")
	var d = PCBData.new()
	d.from_board_dict({
		"version": 1, "name": "black", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"], "components": [], "nets": [],
		"traces": [], "vias": [],
		"fabrication": {"mask_colour": "black", "finish": "ENIG", "thickness_mm": 1.0},
	})
	var out: Dictionary = d.to_board_dict()
	check("the appearance survives the round trip", out.has("fabrication"))
	var carried: Dictionary = out.get("fabrication", {})
	check_eq("…the chosen colour", str(carried.get("mask_colour", "")), "black")
	check_eq("…the chosen finish", str(carried.get("finish", "")), "ENIG")

	# A board that names no appearance must stay byte-identical to before the
	# block existed — an emitted empty block would churn every board's YAML on
	# first open, and the worker already reads silence as the defaults.
	var d2 = PCBData.new()
	d2.from_board_dict({
		"version": 1, "name": "plain", "width_mm": 20.0, "height_mm": 20.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"], "components": [], "nets": [],
		"traces": [], "vias": [],
	})
	check("a board naming no appearance emits NO fabrication key",
		not d2.to_board_dict().has("fabrication"))
