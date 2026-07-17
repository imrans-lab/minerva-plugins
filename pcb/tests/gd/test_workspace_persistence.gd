extends SceneTree
## T2a — routing-workspace PERSISTENCE + board-coherence tests.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_workspace_persistence.gd
## The preloads resolve res:// against the scaffold's src/ root, so
## ../../minerva-plugins reaches this plugin checkout beside it (same convention
## as test_routing_workspace_model.gd / test_workspace_ingest.gd). On-disk cases
## use plugin_panel_driver's temp_root so writes stay inside the temp workspace.
##
## Coverage (7 groups):
##   1. ROUND-TRIP: candidates (multi-pad net + via) + a pinned candidate save
##      → new workspace → load; candidates/pinned/counters equal; active/selected
##      NOT persisted (fresh after load).
##   2. FINGERPRINT MATCH: same board (incl. a JSON-round-tripped copy, proving
##      int↔float stability) → candidates load clean.
##   3. FINGERPRINT MISMATCH: mutate the board → all candidates stale. ABA:
##      change→revert (revision advances, fingerprint equal) → NOT stale.
##   4. CRASH-SAFE: no ".tmp" left after save; a stray ".tmp" is inert on load;
##      zero candidates ⇒ sidecar deleted.
##   5. VERSION/CORRUPT: future schema_version → quarantine-stale; garbage file
##      → empty; neither crashes.
##   6. EXPORT ISOLATION: to_board_dict() carries NO routing-candidate keys.
##   7. PER-NET ATTRIBUTION (folded T2 fix): a multi-net re-propose changing only
##      net B's hints leaves net A superseded exactly once (no stale duplicate).

const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRoutingSidecar := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PluginPanelDriver := preload("res://test/helpers/plugin_panel_driver.gd")

var _pass := 0
var _fail := 0
var _driver = null


func _init() -> void:
	print("=== RoutingWorkspace Persistence (T2a) Tests ===\n")
	_driver = PluginPanelDriver.new()
	_run_round_trip()
	_run_fingerprint_match()
	_run_fingerprint_mismatch()
	_run_crash_safe()
	_run_version_and_corrupt()
	_run_export_isolation()
	_run_per_net_attribution()
	_run_mounting_hole_keepout()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


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


# ── fixtures ──────────────────────────────────────────────────────────────────

## Router reply: a multi-pad net (3 segments, >=2 DISCONNECTED paths) + a via.
func _multipad_reply() -> Dictionary:
	return {
		"routes": [{
			"net": "N1",
			"segments": [
				{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
				{"start": [5.0, 0.0], "end": [5.0, 5.0], "layer": "B.Cu"},
				{"start": [50.0, 50.0], "end": [60.0, 50.0], "layer": "F.Cu"},
			],
			"vias": [[5.0, 0.0]],
		}],
	}


func _hint(id: String, net: String) -> Dictionary:
	return {"id": id, "kind_payload": {"net_names": [net], "width_mm": 0.3}}


func _simple_reply(net: String) -> Dictionary:
	return {"routes": [{"net": net, "segments": [
		{"start": [0.0, 0.0], "end": [1.0, 0.0], "layer": "F.Cu"}], "vias": []}]}


## A workspace with two candidates (multi-pad N1 + simple N2), N2 pinned, plus a
## transient active + selected finding (which must NOT survive a save/load).
func _seed_workspace() -> Object:
	var ws = PcbRoutingWorkspace.new()
	var n1_ids := ws.ingest_routing_result(_multipad_reply(), [_hint("hint_1", "N1")], 42)
	var n2_ids := ws.ingest_routing_result(_simple_reply("N2"), [_hint("hint_2", "N2")], 42)
	ws.pin(str(n2_ids[0]))
	ws.set_active(str(n1_ids[0]))
	ws.selected_finding_id = "finding_99"
	return ws


## A real PCBData board: 2 traces (top+bottom) + a via + design rules.
func _seed_board() -> Object:
	var data = PCBData.new()
	data.set_board_size(80.0, 60.0)
	data.design_rules = {"clearance_mm": 0.2, "min_trace_mm": 0.15}
	var t_top = data.new_trace()
	t_top.id = "t_top"; t_top.net_name = "N1"; t_top.layer = "top"; t_top.width = 0.3
	t_top.waypoints.append(Vector2(0, 0)); t_top.waypoints.append(Vector2(5, 0))
	data.add_trace(t_top)
	var t_bot = data.new_trace()
	t_bot.id = "t_bot"; t_bot.net_name = "N1"; t_bot.layer = "bottom"; t_bot.width = 0.3
	t_bot.waypoints.append(Vector2(10, 0)); t_bot.waypoints.append(Vector2(15, 0))
	data.add_trace(t_bot)
	data.add_via({
		"position": Vector2(5, 0), "size": 0.8, "drill": 0.4,
		"net_name": "N1", "from_layer": "top", "to_layer": "bottom",
	})
	return data


func _temp_board_path(name: String) -> String:
	var dir: String = _driver.make_temp_board_dir("pcb_t2a_persist")
	return dir + "/" + name


func _cleanup(board_path: String) -> void:
	var sp := PcbRoutingSidecar.sidecar_path_for(board_path)
	for p in [sp, sp + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


# ── 1. round-trip ─────────────────────────────────────────────────────────────

func _run_round_trip() -> void:
	print("-- 1. round-trip: candidates + pinned + counters; active/selected dropped --")
	var ws = _seed_workspace()
	var data = _seed_board()
	var board_path := _temp_board_path("roundtrip.pcbskel")

	var err: int = PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(), 3)
	check_eq("save_workspace OK", err, OK)
	check("sidecar written", PcbRoutingSidecar.has_sidecar(board_path))

	var loaded = PcbRoutingWorkspace.new()
	var status: Dictionary = PcbRoutingSidecar.load_into_workspace(
		board_path, loaded, data.to_board_dict(), 3)
	check_eq("load status loaded_clean", str(status.get("status", "")), "loaded_clean")

	# Candidate ids equal (as a set).
	var before_ids: Array = ws.candidates.keys(); before_ids.sort()
	var after_ids: Array = loaded.candidates.keys(); after_ids.sort()
	check_eq("candidate id set preserved", after_ids, before_ids)

	# Multi-pad geometry preserved exactly (3 disconnected segments + 1 via).
	var multipad = null
	for id in loaded.candidates:
		if loaded.candidates[id].net == "N1":
			multipad = loaded.candidates[id]
	check("N1 candidate present after load", multipad != null)
	check_eq("N1 keeps 3 segments (no chain merge)", multipad.segments.size(), 3)
	check_eq("N1 keeps its via", multipad.vias.size(), 1)

	# Pinned set + pinned disposition preserved.
	check_eq("pinned set size preserved", loaded.pinned.size(), ws.pinned.size())
	var pinned_id := str(ws.pinned.keys()[0])
	check("pinned id round-trips", loaded.is_pinned(pinned_id))
	check_eq("pinned candidate disposition preserved", loaded.get_candidate(pinned_id).disposition, "pinned")

	# Counters preserved (high-water).
	check_eq("counters round-trip", loaded.to_sidecar_dict()["counters"], ws.to_sidecar_dict()["counters"])

	# Transient selection NOT persisted.
	check_eq("active_candidate_id NOT persisted (fresh)", loaded.active_candidate_id, "")
	check_eq("selected_finding_id NOT persisted (fresh)", loaded.selected_finding_id, "")

	# to_sidecar_dict itself must omit the two transient keys.
	var durable: Dictionary = ws.to_sidecar_dict()
	check("to_sidecar_dict omits active_candidate_id", not durable.has("active_candidate_id"))
	check("to_sidecar_dict omits selected_finding_id", not durable.has("selected_finding_id"))

	_cleanup(board_path)


# ── 2. fingerprint match ──────────────────────────────────────────────────────

func _run_fingerprint_match() -> void:
	print("-- 2. fingerprint match: same board (+ JSON round-trip) loads clean --")
	var ws = _seed_workspace()
	var data = _seed_board()
	var board_dict: Dictionary = data.to_board_dict()
	var board_path := _temp_board_path("match.pcbskel")
	PcbRoutingSidecar.save_workspace(board_path, ws, board_dict, 1)

	# Load with the SAME board.
	var loaded = PcbRoutingWorkspace.new()
	var s1: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded, board_dict, 1)
	check_eq("same board loads clean", str(s1.get("status", "")), "loaded_clean")
	check("no candidate marked stale (same board)", not _any_stale(loaded))

	# Load with a JSON-round-tripped board dict — proves the fingerprint is stable
	# across the GDScript int↔float coercion (disk read reserialises numbers).
	var rtripped: Variant = JSON.parse_string(JSON.stringify(board_dict))
	check("board dict JSON-round-trips to a Dictionary", rtripped is Dictionary)
	var loaded2 = PcbRoutingWorkspace.new()
	var s2: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded2, rtripped, 1)
	check_eq("JSON-round-tripped board still loads clean (float-stable)", str(s2.get("status", "")), "loaded_clean")
	check("no candidate stale after JSON round-trip", not _any_stale(loaded2))

	_cleanup(board_path)


# ── 3. fingerprint mismatch + ABA ─────────────────────────────────────────────

func _run_fingerprint_mismatch() -> void:
	print("-- 3. fingerprint mismatch marks all stale; ABA (change→revert) stays clean --")
	var ws = _seed_workspace()
	var data = _seed_board()
	var board_path := _temp_board_path("mismatch.pcbskel")
	PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(), 1)

	# Mutate the board AFTER save: change a design rule (a fingerprint input).
	var data_b = _seed_board()
	data_b.design_rules = {"clearance_mm": 0.35, "min_trace_mm": 0.15}
	var loaded = PcbRoutingWorkspace.new()
	var s: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded, data_b.to_board_dict(), 1)
	check_eq("changed board → quarantine_stale", str(s.get("status", "")), "quarantine_stale")
	check_eq("mismatch reason is fingerprint", str(s.get("reason", "")), "board_fingerprint mismatch")
	check("ALL candidates marked stale on mismatch", _all_stale(loaded))
	# Disposition axis preserved through the quarantine (only validation changed).
	var pinned_id := str(ws.pinned.keys()[0])
	check_eq("mismatch preserves pinned disposition", loaded.get_candidate(pinned_id).disposition, "pinned")

	# ABA: mutate then revert. board_revision advances (never rolls back) but the
	# CONTENT — hence the fingerprint — returns to the original.
	var data_c = _seed_board()
	var rev0: int = data_c.board_revision
	var fp0 := PcbRoutingSidecar.compute_board_fingerprint(data_c.to_board_dict())
	data_c.add_via({"position": Vector2(20, 20), "size": 0.8, "drill": 0.4,
		"net_name": "N1", "from_layer": "top", "to_layer": "bottom"})
	var fp_mut := PcbRoutingSidecar.compute_board_fingerprint(data_c.to_board_dict())
	check("mutation (add via) changes the fingerprint", fp_mut != fp0)
	data_c.remove_via(data_c.vias.size() - 1)  # revert content
	var fp_rev := PcbRoutingSidecar.compute_board_fingerprint(data_c.to_board_dict())
	check("revert restores the fingerprint (content-equal)", fp_rev == fp0)
	check("board_revision advanced despite revert (counter != coherence)", data_c.board_revision > rev0)

	# Save under fp0's board, then load with the ABA board (revision advanced,
	# content reverted) → clean, proving the FINGERPRINT (not the counter) gates.
	var aba_path := _temp_board_path("aba.pcbskel")
	var data_orig = _seed_board()
	PcbRoutingSidecar.save_workspace(aba_path, _seed_workspace(), data_orig.to_board_dict(), rev0)
	var loaded_aba = PcbRoutingWorkspace.new()
	var s_aba: Dictionary = PcbRoutingSidecar.load_into_workspace(
		aba_path, loaded_aba, data_c.to_board_dict(), data_c.board_revision)
	check_eq("ABA board loads clean (fingerprint equal, revision advanced)", str(s_aba.get("status", "")), "loaded_clean")
	check("ABA leaves no candidate stale", not _any_stale(loaded_aba))

	_cleanup(board_path)
	_cleanup(aba_path)


# ── 4. crash-safe ─────────────────────────────────────────────────────────────

func _run_crash_safe() -> void:
	print("-- 4. crash-safe: atomic write (no stray .tmp); zero candidates deletes --")
	var ws = _seed_workspace()
	var data = _seed_board()
	var board_path := _temp_board_path("atomic.pcbskel")
	var sp := PcbRoutingSidecar.sidecar_path_for(board_path)

	PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(), 1)
	check("sidecar exists after save", FileAccess.file_exists(sp))
	check("no .tmp left behind after save", not FileAccess.file_exists(sp + ".tmp"))

	# A pre-existing stray .tmp must not corrupt the load (only <sidecar> is read).
	var stray := FileAccess.open(sp + ".tmp", FileAccess.WRITE)
	stray.store_string("garbage-not-json"); stray.close()
	var loaded = PcbRoutingWorkspace.new()
	var s: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded, data.to_board_dict(), 1)
	check_eq("stray .tmp ignored; load still clean", str(s.get("status", "")), "loaded_clean")
	DirAccess.remove_absolute(sp + ".tmp")

	# Zero candidates ⇒ the sidecar is DELETED (never written empty).
	var empty_ws = PcbRoutingWorkspace.new()
	var err2: int = PcbRoutingSidecar.save_workspace(board_path, empty_ws, data.to_board_dict(), 1)
	check_eq("zero-candidate save returns OK", err2, OK)
	check("zero-candidate save deleted the sidecar", not PcbRoutingSidecar.has_sidecar(board_path))

	_cleanup(board_path)


# ── 5. version / corrupt ──────────────────────────────────────────────────────

func _run_version_and_corrupt() -> void:
	print("-- 5. version/corrupt: future schema quarantines, garbage → empty, no crash --")
	var ws = _seed_workspace()
	var data = _seed_board()
	var board_path := _temp_board_path("version.pcbskel")
	var sp := PcbRoutingSidecar.sidecar_path_for(board_path)

	# Future schema_version — must NOT be trusted as current.
	PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(), 1)
	var env := PcbRoutingSidecar.read_envelope(board_path)
	env["schema_version"] = 999
	PcbRoutingSidecar.write_envelope(board_path, env)
	var loaded = PcbRoutingWorkspace.new()
	var s: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded, data.to_board_dict(), 1)
	check_eq("future schema_version → quarantine_stale", str(s.get("status", "")), "quarantine_stale")
	check("future-version candidates surfaced but ALL stale", loaded.candidates.size() > 0 and _all_stale(loaded))

	# Garbage / truncated file — empty, backed up, never crashes.
	var f := FileAccess.open(sp, FileAccess.WRITE)
	f.store_string("{ this is not valid json"); f.close()
	var loaded2 = PcbRoutingWorkspace.new()
	var s2: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded2, data.to_board_dict(), 1)
	check_eq("garbage sidecar → empty", str(s2.get("status", "")), "empty")
	check("garbage load loaded no candidates", loaded2.candidates.is_empty())

	# Clean up the corrupt-backup the read produced.
	var dir: DirAccess = DirAccess.open(sp.get_base_dir())
	if dir != null:
		for entry in dir.get_files():
			if entry.begins_with(sp.get_file() + ".corrupt-"):
				DirAccess.remove_absolute(sp.get_base_dir() + "/" + entry)
	_cleanup(board_path)


# ── 6. export isolation ───────────────────────────────────────────────────────

func _run_export_isolation() -> void:
	print("-- 6. export isolation: to_board_dict carries NO routing state --")
	var data = _seed_board()
	# Routing lives only in the workspace; the fabrication doc must never see it.
	var board_dict: Dictionary = data.to_board_dict()
	for forbidden in ["candidates", "routing", "route_candidates", "routing_workspace", "pinned"]:
		check("to_board_dict has no '%s' key" % forbidden, not board_dict.has(forbidden))
	# Sanity: it DOES carry the real fabrication inputs.
	check("to_board_dict carries traces", board_dict.has("traces"))
	check("to_board_dict carries vias", board_dict.has("vias"))


# ── 7. per-net attribution (folded T2 #555 fix) ───────────────────────────────

func _run_per_net_attribution() -> void:
	print("-- 7. per-net attribution: change only net B's hints; net A untouched --")
	var ws = PcbRoutingWorkspace.new()

	# Two nets, each with its OWN hint. Propose both together.
	var reply1 := {"routes": [
		{"net": "A", "segments": [{"start": [0, 0], "end": [1, 0], "layer": "F.Cu"}], "vias": []},
		{"net": "B", "segments": [{"start": [0, 0], "end": [2, 0], "layer": "F.Cu"}], "vias": []},
	]}
	var hints1 := [_hint("hintA", "A"), _hint("hintB", "B")]
	var ids1 := ws.ingest_routing_result(reply1, hints1, 1)
	check_eq("first propose → 2 candidates", ids1.size(), 2)
	var a1_key := ""
	for id in ids1:
		if ws.get_candidate(id).net == "A":
			a1_key = str(ws.get_candidate(id).task_id)
	check("net A got a task_key", not a1_key.is_empty())

	# Re-propose BOTH nets, changing ONLY net B's hint id (hintB → hintB2). Under
	# the OLD global-hint keying this would shift net A's task_key too, leaving a
	# stale duplicate A. Per-net keying must leave A superseded EXACTLY once.
	var hints2 := [_hint("hintA", "A"), _hint("hintB2", "B")]
	ws.ingest_routing_result(reply1, hints2, 2)

	check_eq("net A key unchanged by net-B hint change", _live_task_key_for_net(ws, "A"), a1_key)
	check_eq("net A: exactly 1 LIVE candidate (superseded once, not duplicated)", _count_net(ws, "A", false), 1)
	check_eq("net A: exactly 1 SUPERSEDED candidate (the prior generation)", _count_net(ws, "A", true), 1)
	check_eq("net A live candidate generation bumped to 2", _live_candidate_for_net(ws, "A").generation, 2)


# ── 8. mounting-hole keepout (fingerprint coverage) ───────────────────────────

func _hole(x: float, y: float) -> Dictionary:
	return {"position": Vector2(x, y), "diameter": 3.2, "plated": false}


func _run_mounting_hole_keepout() -> void:
	print("-- 8. mounting holes are keepouts: any hole change stales candidates --")
	var ws = _seed_workspace()
	var data = _seed_board()
	data.mounting_holes.append(_hole(2.0, 2.0))
	var board_path := _temp_board_path("holes.pcbskel")
	PcbRoutingSidecar.save_workspace(board_path, ws, data.to_board_dict(), 1)

	# MOVE the hole into a candidate's path → hash must change → all stale.
	var moved = _seed_board()
	moved.mounting_holes.append(_hole(5.0, 0.0))
	var loaded = PcbRoutingWorkspace.new()
	var s: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded, moved.to_board_dict(), 1)
	check_eq("moved mounting hole → quarantine_stale", str(s.get("status", "")), "quarantine_stale")
	check("moved hole marks ALL candidates stale", _all_stale(loaded))

	# ADD an extra, far-away hole (global keepout) → hash still changes → stale.
	var added = _seed_board()
	added.mounting_holes.append(_hole(2.0, 2.0))
	added.mounting_holes.append(_hole(999.0, 999.0))
	var loaded2 = PcbRoutingWorkspace.new()
	var s2: Dictionary = PcbRoutingSidecar.load_into_workspace(board_path, loaded2, added.to_board_dict(), 1)
	check_eq("added far-away hole → quarantine_stale", str(s2.get("status", "")), "quarantine_stale")

	# Direct hash proof: the far-away hole change alters the fingerprint, and a
	# hole-free board differs from the with-hole board.
	var fp_orig := PcbRoutingSidecar.compute_board_fingerprint(data.to_board_dict())
	var fp_added := PcbRoutingSidecar.compute_board_fingerprint(added.to_board_dict())
	var fp_none := PcbRoutingSidecar.compute_board_fingerprint(_seed_board().to_board_dict())
	check("far-away hole changes the fingerprint", fp_orig != fp_added)
	check("presence of a hole changes the fingerprint", fp_orig != fp_none)
	# Same board (same hole) still matches — no spurious churn.
	var same = _seed_board()
	same.mounting_holes.append(_hole(2.0, 2.0))
	check("identical hole set → fingerprint stable", fp_orig == PcbRoutingSidecar.compute_board_fingerprint(same.to_board_dict()))

	_cleanup(board_path)


# ── small workspace inspectors ────────────────────────────────────────────────

func _any_stale(ws) -> bool:
	for id in ws.candidates:
		if ws.candidates[id].validation == "stale":
			return true
	return false


func _all_stale(ws) -> bool:
	if ws.candidates.is_empty():
		return false
	for id in ws.candidates:
		if ws.candidates[id].validation != "stale":
			return false
	return true


## Count candidates for a net; superseded=true counts only superseded, false
## counts only non-superseded (live).
func _count_net(ws, net: String, superseded: bool) -> int:
	var n := 0
	for id in ws.candidates:
		var c = ws.candidates[id]
		if c.net != net:
			continue
		if (c.disposition == "superseded") == superseded:
			n += 1
	return n


func _live_candidate_for_net(ws, net: String):
	for id in ws.candidates:
		var c = ws.candidates[id]
		if c.net == net and c.disposition != "superseded":
			return c
	return null


func _live_task_key_for_net(ws, net: String) -> String:
	var c = _live_candidate_for_net(ws, net)
	return str(c.task_id) if c != null else ""
