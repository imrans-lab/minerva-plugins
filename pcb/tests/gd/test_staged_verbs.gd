extends SceneTree
## Epoch UX4 station 5 (docket 019fe081b0b4; DCR 019fe07523ca S5, A1/A5):
## the PANEL-owned staged review transactions — stage doorway, accept (id
## passthrough + drift refusal + history coherence), reject (history-paired
## terminal stamp), all-or-nothing batch accept, and the canvas-signal wiring.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_staged_verbs.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PcbNetScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_net.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

var _pass := 0
var _fail := 0


class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== Staged verbs: stage / accept / reject / batch ===\n")
	await process_frame
	_run_stage_doorway()
	_run_accept_identity_and_history()
	_run_accept_drift_refusal()
	_run_reject_pairing()
	_run_batch_all_or_nothing()
	_run_canvas_signal_wiring()
	await _run_mcp_staging_family()
	_run_regression_census()
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
const TRI2 := [Vector2(12, 12), Vector2(18, 12), Vector2(18, 18)]


func _rig() -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	var data = panel.get_data()
	data.from_board_dict({
		"version": 1, "name": "verbs", "width_mm": 40.0, "height_mm": 40.0,
		"grid_mm": 2.54, "design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [], "nets": [{"name": "GND", "pins": []}],
		"traces": [], "vias": [],
	})
	data.save_to_history("seed")
	return {"panel": panel, "data": data, "store": panel.get_staged_store()}


func _stage_zone(rig: Dictionary, net := "", layer := "top", kind := "keepout",
		outline: Array = TRI) -> Dictionary:
	var payload: Dictionary = rig["data"].build_zone_payload(net, layer, outline, kind).get("payload", {})
	var res: Dictionary = rig["panel"].stage_built_payload("zone", payload, "ai", "test draft")
	res["payload"] = payload
	return res


# ── 1. the stage doorway ──────────────────────────────────────────────────────

func _run_stage_doorway() -> void:
	print("-- 1. stage_built_payload: the ONE stage doorway --")
	var rig := _rig()
	var res := _stage_zone(rig)
	check("stage doorway returns ok", bool(res.get("ok", false)))
	check("…with the store key", str(res.get("staged_id", "")).begins_with("staged_"))
	check_eq("…and the canonical entity id",
		str(res.get("entity_id", "")), str((res.get("payload", {}) as Dictionary).get("id", "")))
	var entry: Dictionary = rig["store"].get_entry(str(res.get("staged_id", "")))
	check_eq("base_board_revision stamped from the LIVE board",
		int(entry.get("base_board_revision", -1)), int(rig["data"].board_revision))
	check_eq("…author recorded", str(entry.get("author", "")), "ai")

	# The store's own refusal surfaces by name through the doorway.
	var dup: Dictionary = rig["panel"].stage_built_payload("zone", res.get("payload", {}))
	check("re-staging a live canonical id refuses through the doorway",
		not bool(dup.get("ok", false)))
	check_eq("…by the store's name", str(dup.get("error", "")), "staged_entity_duplicate")
	rig["panel"].free()


# ── 2. accept: A1 identity + one-history-step coherence ───────────────────────

func _run_accept_identity_and_history() -> void:
	print("-- 2. accept: byte-identical landing (incl. id), undo returns the ghost --")
	var rig := _rig()
	var res := _stage_zone(rig)
	var payload: Dictionary = res.get("payload", {})
	var eid := str(res.get("entity_id", ""))

	var out: Dictionary = rig["panel"].accept_staged(eid)
	check("accept lands", bool(out.get("ok", false)))
	var on_board: Dictionary = rig["data"].get_zone(eid)
	check("A1: the board entity is byte-identical to the staged payload, id included",
		not on_board.is_empty() and str(on_board) == str(payload))
	check_eq("the entry is stamped accepted",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "accepted")

	check("undo (one history step reverts write + stamp together)", rig["data"].undo())
	check("…the entity left the board", (rig["data"].get_zone(eid) as Dictionary).is_empty())
	check_eq("…and the ghost returned",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "staged")
	check("redo", rig["data"].redo())
	check("…restores the board write", not (rig["data"].get_zone(eid) as Dictionary).is_empty())
	check_eq("…and the accepted stamp",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "accepted")

	# A second accept of the SAME id refuses (it resolves to no LIVE entry).
	var again: Dictionary = rig["panel"].accept_staged(eid)
	check("accepting an already-accepted draft refuses", not bool(again.get("ok", false)))
	check_eq("…named", str(again.get("error", "")), "staged_entry_not_found")
	rig["panel"].free()


# ── 3. accept-after-drift: A5's named refusal, nothing stamped ────────────────

func _run_accept_drift_refusal() -> void:
	print("-- 3. accept after board drift: the direct verb's own refusal, by name --")
	var rig := _rig()
	var res := _stage_zone(rig, "GND", "top", "copper_pour")
	var eid := str(res.get("entity_id", ""))

	# Drift: the net the staged pour references leaves the board.
	rig["data"].remove_net("GND")
	var out: Dictionary = rig["panel"].accept_staged(eid)
	check("accept refuses after the net was deleted", not bool(out.get("ok", false)))
	check_eq("…as accept_refused", str(out.get("error", "")), "accept_refused")
	check("…carrying the AUTHOR refusal text (A5: the direct verb's own words)",
		str(out.get("note", "")).contains("not declared"))
	check_eq("the entry is STILL staged (no stamp over a refused write)",
		str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")), "staged")
	check("…and the board is untouched", (rig["data"].get_zone(eid) as Dictionary).is_empty())
	rig["panel"].free()


# ── 4. reject: history-paired terminal stamp ──────────────────────────────────

func _run_reject_pairing() -> void:
	print("-- 4. reject through the panel verb: paired, durable, undoable --")
	var rig := _rig()
	var res := _stage_zone(rig)
	var eid := str(res.get("entity_id", ""))
	var sid := str(res.get("staged_id", ""))

	var out: Dictionary = rig["panel"].reject_staged(eid)
	check("reject lands", bool(out.get("ok", false)))
	check_eq("…terminal", str(rig["store"].get_entry(sid).get("disposition", "")), "rejected")

	# An UNRELATED edit + undo must not un-reject (the F3 clobber, closed by
	# the verb's history pairing).
	rig["data"].create_cutout(TRI2)
	rig["data"].save_to_history("unrelated cutout")
	check("undo of the unrelated edit", rig["data"].undo())
	check_eq("…leaves the reject standing",
		str(rig["store"].get_entry(sid).get("disposition", "")), "rejected")
	check("undo of the reject itself", rig["data"].undo())
	check_eq("…revives the ghost",
		str(rig["store"].get_entry(sid).get("disposition", "")), "staged")

	# Rejecting an unknown id refuses by name.
	var missing: Dictionary = rig["panel"].reject_staged("zone:doesnotexist")
	check("rejecting an unknown entity refuses", not bool(missing.get("ok", false)))
	check_eq("…named", str(missing.get("error", "")), "staged_entry_not_found")
	rig["panel"].free()


# ── 5. batch accept: all-or-nothing, ONE history step ─────────────────────────

func _run_batch_all_or_nothing() -> void:
	print("-- 5. batch accept: refused whole by name; lands whole as one undo step --")
	var rig := _rig()
	var a := _stage_zone(rig, "", "top", "keepout", TRI)
	var b := _stage_zone(rig, "GND", "bottom", "copper_pour", TRI2)
	var a_id := str(a.get("entity_id", ""))
	var b_id := str(b.get("entity_id", ""))

	# Drift ONE of them (the pour's net) — the whole batch must refuse, naming it.
	rig["data"].remove_net("GND")
	var refused: Dictionary = rig["panel"].accept_staged_batch([a_id, b_id])
	check("a batch with one drifted draft refuses WHOLE", not bool(refused.get("ok", false)))
	var refs: Array = refused.get("refusals", [])
	check_eq("…with exactly the drifted draft named", refs.size(), 1)
	check_eq("…by id", str((refs[0] as Dictionary).get("entity_id", "")), b_id)
	check("nothing landed (all-or-nothing)",
		(rig["data"].get_zone(a_id) as Dictionary).is_empty()
		and (rig["data"].get_zone(b_id) as Dictionary).is_empty())
	check_eq("…and both drafts are still live",
		rig["store"].staged_entries().size(), 2)

	# A REPEATED member refuses at preflight (Codex UX4 F3 — the routing
	# batch's own rule): without it, [id, id] landed once, refused once
	# mid-write, and reported accepted:2.
	var dup_batch: Dictionary = rig["panel"].accept_staged_batch([a_id, a_id])
	check("a batch with a repeated member refuses whole", not bool(dup_batch.get("ok", false)))
	check("…naming duplicate_batch_member",
		str((dup_batch.get("refusals", []) as Array)[0]).contains("duplicate_batch_member"))
	check("…and nothing landed", (rig["data"].get_zone(a_id) as Dictionary).is_empty())

	# Heal the drift; the batch lands as ONE history step. (add_net takes a
	# NET OBJECT, not a name — the documented gotcha.)
	var gnd = PcbNetScript.new()
	gnd.name = "GND"
	rig["data"].add_net(gnd)
	var hist_before: int = rig["data"].history.size()
	var out: Dictionary = rig["panel"].accept_staged_batch([a_id, b_id])
	check("the healed batch accepts", bool(out.get("ok", false)))
	check_eq("…both of them", int(out.get("accepted", 0)), 2)
	check_eq("ONE history entry for the lot",
		rig["data"].history.size(), hist_before + 1)
	check("undo returns BOTH to ghosts", rig["data"].undo()
		and (rig["data"].get_zone(a_id) as Dictionary).is_empty()
		and (rig["data"].get_zone(b_id) as Dictionary).is_empty()
		and rig["store"].staged_entries().size() == 2)
	rig["panel"].free()


# ── 6. the canvas wiring: menu announcement → panel transaction ───────────────

func _run_canvas_signal_wiring() -> void:
	print("-- 6. staged_verb_requested is CONNECTED (canvas → panel) --")
	var rig := _rig()
	var res := _stage_zone(rig)
	var eid := str(res.get("entity_id", ""))
	var canvas = rig["panel"]._canvas
	check("(fixture) the panel has a canvas", canvas != null)
	if canvas != null:
		canvas.staged_verb_requested.emit("reject", eid)
		check_eq("emitting reject on the CANVAS lands the panel transaction",
			str(rig["store"].get_entry(str(res.get("staged_id", ""))).get("disposition", "")),
			"rejected")
	rig["panel"].free()


# ── 7. Epoch UX4 station 8: the MCP staging family (DCR S8) ───────────────────
# The five tools are THIN over the panel transactions sections 1-5 pinned —
# what is asserted here is the TOOL surface: arg parity with create_*, the
# reply shapes, the ai attribution, and the end-to-end loop
# propose → list → accept → list(include_terminal).

func _run_mcp_staging_family() -> void:
	print("-- 7. MCP staging family: propose/list/accept/reject --")
	var rig := _rig()
	var host = rig["panel"].get_annotation_host()
	var outline := [
		{"x_mm": 2.0, "y_mm": 2.0}, {"x_mm": 8.0, "y_mm": 2.0}, {"x_mm": 8.0, "y_mm": 8.0},
	]

	# Arg parity: the SAME refusal text create_zone gives (author refusal).
	var refused: Dictionary = PanelTools._propose_zone(host, {
		"kind": "copper_pour", "net": "NOPE", "layer": "top", "outline": outline})
	check("propose_zone refuses an undeclared pour net", not bool(refused.get("success", true)))
	check("…with the author refusal text (arg-identical twin of create_zone)",
		str(refused.get("error", "")).contains("not declared"))
	var missing: Dictionary = PanelTools._propose_zone(host, {"layer": "top"})
	check("absent outline says so by name",
		str(missing.get("error", "")).contains("outline is required"))

	# Propose lands a ghost, not a board write.
	var out: Dictionary = PanelTools._propose_zone(host, {
		"kind": "keepout", "layer": "top", "outline": outline, "note": "agent draft"})
	check("propose_zone stages", bool(out.get("success", false)))
	# Codex UX4 F5a: _ok() merges FLAT — reading a nested "result" was this
	# suite's own wrong oracle (13 cascading reds at the boundary).
	var eid := str(out.get("entity_id", ""))
	check("…reply carries the canonical entity id", eid.begins_with("zone:"))
	check("…and the store key", str(out.get("staged_id", "")).begins_with("staged_"))
	check_eq("…board untouched", rig["data"].zones.size(), 0)
	check_eq("…attributed to ai (the MCP doorway)",
		str(rig["store"].get_entry(str(out.get("staged_id", ""))).get("author", "")), "ai")

	var cut: Dictionary = PanelTools._propose_cutout(host, {"outline": [
		{"x_mm": 20.0, "y_mm": 20.0}, {"x_mm": 26.0, "y_mm": 20.0}, {"x_mm": 26.0, "y_mm": 26.0}]})
	check("propose_cutout stages", bool(cut.get("success", false)))
	var cut_eid := str(cut.get("entity_id", ""))

	# List: live rows with the store's what's-this answer.
	var listed: Dictionary = PanelTools._staged_list(host, {})
	var rows: Array = listed.get("staged", [])
	check_eq("staged_list shows both live drafts", rows.size(), 2)
	var zone_row: Dictionary = {}
	for r in rows:
		if str((r as Dictionary).get("entity_id", "")) == eid:
			zone_row = r
	check("…zone row carries kind/layer/author/note",
		str(zone_row.get("zone_kind", "")) == "keepout"
		and str(zone_row.get("layer", "")) == "top"
		and str(zone_row.get("author", "")) == "ai"
		and str(zone_row.get("note", "")) == "agent draft")

	# Accept one; reject the other; audit trail via include_terminal.
	var acc: Dictionary = await PanelTools._staged_accept(host, {"entity_id": eid})
	check("staged_accept lands", bool(acc.get("success", false)))
	check_eq("…the zone is on the board with ITS OWN id",
		str((rig["data"].get_zone(eid) as Dictionary).get("id", "")), eid)
	var rej: Dictionary = PanelTools._staged_reject(host, {"entity_id": cut_eid})
	check("staged_reject lands", bool(rej.get("success", false)))
	var live_after: Dictionary = PanelTools._staged_list(host, {})
	check_eq("live list is empty after accept+reject",
		int(live_after.get("count", -1)), 0)
	var audit: Dictionary = PanelTools._staged_list(host, {"include_terminal": true})
	check_eq("…include_terminal shows the audit trail",
		int(audit.get("count", -1)), 2)

	# Terminal re-accept refuses through the tool envelope.
	var again: Dictionary = await PanelTools._staged_accept(host, {"entity_id": eid})
	check("re-accept refuses by name", not bool(again.get("success", true))
		and str(again.get("error", "")) == "staged_entry_not_found")

	# Batch envelope: one bad member names itself, nothing lands.
	var b1: Dictionary = PanelTools._propose_zone(host, {
		"kind": "keepout", "layer": "top", "outline": outline})
	var b1_id := str(b1.get("entity_id", ""))
	var batch: Dictionary = await PanelTools._staged_accept(host, {
		"entity_ids": [b1_id, "zone:doesnotexist"]})
	check("batch with an unknown member refuses whole", not bool(batch.get("success", true)))
	check_eq("…naming exactly the bad member",
		(batch.get("refusals", []) as Array).size(), 1)
	var batch_ok: Dictionary = await PanelTools._staged_accept(host, {"entity_ids": [b1_id]})
	check("healed batch accepts", bool(batch_ok.get("success", false)))
	check_eq("…count", int(batch_ok.get("accepted", 0)), 1)
	rig["panel"].free()


# ── 8. Epoch UX4 station 9: the regression guard's copper census ──────────────
# The guard itself needs a live worker round-trip (gate before guard), so what
# is pinned headlessly is its ONE pure read: per-net copper presence, the
# census's own definition — traces ∪ zones ∪ netted vias, POURS COUNT.

func _run_regression_census() -> void:
	print("-- 8. _nets_with_copper: traces ∪ zones ∪ netted vias; pours count --")
	var panel_script = load(PANEL_PATH)
	var board := {
		"traces": [{"net": "SIG", "layer": "top", "points": []}],
		"zones": [
			{"id": "zone:a", "net": "GND", "kind": "copper_pour", "layer": "bottom"},
			{"id": "zone:b", "kind": "keepout", "layer": "top"},
		],
		"vias": [
			{"net": "V1", "x_mm": 1, "y_mm": 1},
			{"net_name": "V2", "position": {"x_mm": 2, "y_mm": 2}},
		],
	}
	var copper: Dictionary = panel_script._nets_with_copper(board)
	check("a trace's net counts", copper.has("SIG"))
	check("a POUR counts as copper (the census definition — owner ruling's own example: a promoted GND pour must protect GND)", copper.has("GND"))
	check("a netless keepout does NOT", copper.size() == 4)
	check("a canonical via's `net` counts", copper.has("V1"))
	check("…and the GD model's `net_name` spelling too", copper.has("V2"))
	check_eq("empty board → empty census",
		(panel_script._nets_with_copper({}) as Dictionary).size(), 0)

	# The guard's decision, replayed on the census (the promote() branch is
	# worker-gated; this is its exact boolean): prior has GND copper, new
	# does not → regression.
	var prior := {"traces": [{"net": "GND"}], "zones": [], "vias": []}
	var now := {"traces": [{"net": "SIG"}], "zones": [], "vias": []}
	var prior_c: Dictionary = panel_script._nets_with_copper(prior)
	var now_c: Dictionary = panel_script._nets_with_copper(now)
	var regressed: Array = []
	for n in prior_c:
		if not now_c.has(n):
			regressed.append(str(n))
	check_eq("prior-GND/new-none reads as a regression", str(regressed), str(["GND"]))
