extends SceneTree
## ACCEPTANCE — bug 01a040f6d7 (+ its HITL finding): stable copper identity and
## HONEST ownership.
##
## TWO DEFECTS, ONE ROOT.
##
## 1. IDS DID NOT SURVIVE A RELOAD. PCBData minted ORDINAL handles for traces
##    and vias ("trace_5", "via_7"). internal/board/migrate.go's isMintedID()
##    reads that shape as UNMINTED, and MigrateV1toV2 — which runs on EVERY
##    pcb.deserialize of a v1 board, i.e. every minerva_pcb_load_board — replaces
##    an unminted id with a fresh crypto-random token. MEASURED against the real
##    binary before the fix: `via_7` came back `via:e1009bcf…`, `trace_5` came
##    back `trace:bcb0dd8b…`, while ids already shaped "via:<32hex>" passed
##    through byte-identical. So an agent holding a via id across export_yaml →
##    load_board got `missing_via_ids`, and the routing sidecar's
##    committed_via_ids went dangling on every reload.
##
## 2. "COMMITTED BY" WAS A GUESS, NOT A CHECK. A committed route candidate's
##    ownership of copper was tested by asking "does the recorded id still
##    resolve?" — sound only while an id is never re-issued, which (see 1) it
##    was. Deleting freshly drawn copper that happened to inherit a stale
##    record's id retired a stranger's commit, reopened its routing task, and
##    put "this copper was committed by 1 route candidate" on the reply.
##
## THE CONTRACT THIS SUITE PINS:
##   * every id PCBData mints satisfies PcbEntityId.is_minted — the GDScript twin
##     of isMintedID, so the deserialize migration leaves it alone (group 1);
##   * a via id held before a REAL pcb.serialize → pcb.deserialize round trip
##     still deletes that via afterwards (group 2, real worker);
##   * ownership is keyed by id AND net (candidate geometry as the tiebreak), so
##     copper drawn by hand reports NO "committed by" even when a stale record
##     names its id — while a candidate that really owns its copper still does
##     (group 3);
##   * a sidecar record whose ids resolve to copper on another net is DROPPED on
##     restore, with a named finding, and never re-attached (group 4).
##
## FAILS AGAINST THE OLD MODEL: groups 1, 2, 3a and 4 all do. Group 3b is the
## unchanged-behaviour invariant (honest attribution must still work) and passes
## before and after.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src --script \
##     res://../../minerva-plugins/pcb/tests/gd/test_copper_identity_ownership.gd

const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBTrace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_trace.gd")
const PcbNet := preload("res://../../minerva-plugins/pcb/ui/model/pcb_net.gd")
const PcbEntityId := preload("res://../../minerva-plugins/pcb/ui/model/pcb_entity_id.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbRoutingWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRoutingSidecar := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd")
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PluginPanelDriver := preload("res://test/helpers/plugin_panel_driver.gd")

var _pass := 0
var _fail := 0
var _driver = null
var _used_real_worker := false


## Duck-typed host for panel_tools' two resolvers: _resolve_data reads
## get_board_data(), _get_workspace reads get_panel().get_routing_workspace().
## Same stand-in shape test_trace_identity_delete.gd's _StubHost uses, plus the
## workspace leg the ownership pre-check needs.
class _StubPanel extends RefCounted:
	var _ws
	func _init(ws) -> void:
		_ws = ws
	func get_routing_workspace():
		return _ws


class _StubHost extends RefCounted:
	var _data
	var _panel
	func _init(d, ws = null) -> void:
		_data = d
		_panel = _StubPanel.new(ws)
	func get_board_data():
		return _data
	func get_panel():
		return _panel


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
	print("=== Copper identity + ownership (bug 01a040f6d7) ===\n")
	_driver = PluginPanelDriver.new()
	_run_minted_ids()
	_run_round_trip_keeps_ids()
	_run_attribution_is_checked()
	_run_stale_sidecar_record_dropped()
	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [
		_pass, _fail, str(_used_real_worker)])
	quit(1 if _fail > 0 else 0)


# ── fixtures ──────────────────────────────────────────────────────────────────

func _seed_board():
	var data = PCBData.new()
	data.set_board_size(80.0, 60.0)
	# layers defaults to ["top", "bottom"] — left alone (it is a typed
	# Array[String], and the default is exactly the stack these fixtures use).
	data.design_rules = {"clearance_mm": 0.2, "trace_width_mm": 0.25,
		"via_diameter_mm": 0.8, "via_drill_mm": 0.4}
	for net_name in ["GND", "SIG"]:
		var net = PcbNet.new()
		net.name = net_name
		data.add_net(net)
	return data


## Add a trace with an EXPLICIT id (the supplied-id branch), so a fixture can
## place a known handle on known geometry.
func _add_trace(data, id: String, net: String, layer: String, points: Array) -> void:
	var t = PCBTrace.new()
	t.id = id
	t.net_name = net
	t.layer = layer
	t.width = 0.25
	for p in points:
		t.add_waypoint(p)
	data.add_trace(t)


## A committed candidate on `net` whose recorded copper is `trace_ids`/`via_ids`.
## Geometry is REAL (the candidate's own segment points), because the ownership
## tiebreak reads it.
func _committed_candidate(ws, net: String, points: Array, trace_ids: Array,
		via_ids: Array = []) -> String:
	var c = PcbRouteCandidate.new()
	c.net = net
	c.task_id = "%s|t" % net
	c.add_segment(PcbRouteCandidate.make_segment("", "top", 0.25, points))
	var cid: String = ws.add_candidate(c)
	ws.mark_committed(cid, trace_ids, via_ids)
	return cid


# ── 1. every minted id is a PERSISTENT id ─────────────────────────────────────

## ORACLE: PcbEntityId.is_minted is the GDScript twin of internal/board's
## isMintedID — same prefix, same 32-char width, same lowercase-hex alphabet.
## MigrateV1toV2 re-mints exactly what that predicate rejects, so "is_minted
## returns true" IS "the deserialize migration will leave this id alone".
func _run_minted_ids() -> void:
	print("-- 1. PCBData mints PERSISTENT ids, not ordinals --")
	var data = _seed_board()

	var via_id: String = data.add_via({"position": Vector2(9, 9), "size": 0.8,
		"drill": 0.4, "net_name": "GND"})
	check("1a: an id-less add_via mints a persistent id (got %s)" % via_id,
		PcbEntityId.is_minted("via", via_id))

	var t = PCBTrace.new()
	t.net_name = "GND"
	t.layer = "top"
	t.add_waypoint(Vector2(1, 1))
	t.add_waypoint(Vector2(5, 1))
	data.add_trace(t)
	check("1b: an id-less add_trace mints a persistent id (got %s)" % t.id,
		PcbEntityId.is_minted("trace", t.id))

	var authored = data.create_trace_entity("SIG", "top", [Vector2(1, 8), Vector2(5, 8)])
	check("1c: create_trace_entity still mints a persistent id",
		authored != null and PcbEntityId.is_minted("trace", str(authored.id)))

	# The predicate has to REJECT the legacy shape, or 1a/1b prove nothing.
	check("1d: an ordinal handle reads as UNMINTED",
		not PcbEntityId.is_minted("via", "via_7"))
	check("1e: a wrong-domain prefix reads as UNMINTED",
		not PcbEntityId.is_minted("via", str(t.id)))
	check("1f: uppercase hex reads as UNMINTED",
		not PcbEntityId.is_minted("via", "via:0123456789ABCDEF0123456789abcdef"))

	# Legacy ids are still ACCEPTED — nothing about this change refuses a board
	# or an import that carries one.
	var legacy_via: String = data.add_via({"id": "via_7", "position": Vector2(12, 12),
		"size": 0.8, "drill": 0.4, "net_name": "GND"})
	check_eq("1g: a supplied ordinal id is honoured verbatim", legacy_via, "via_7")
	check("1h: and it is still deletable by that handle",
		data.find_via_index("via_7") >= 0)

	# In-memory canonical round trip: the boundary the YAML codec sits behind.
	var reloaded = PCBData.new()
	reloaded.from_board_dict(data.to_board_dict())
	check("1i: the minted via id survives to_board_dict → from_board_dict",
		reloaded.find_via_index(via_id) >= 0)
	check("1j: the minted trace id survives it too", reloaded.get_trace(t.id) != null)


# ── 2. THE REPRO: export → load_board → delete by the pre-reload via id ───────

## ORACLE: the ids the caller HELD before the round trip. The board goes through
## the REAL Go codec — pcb.serialize is what minerva_pcb_export_yaml writes with,
## pcb.deserialize is what minerva_pcb_load_board parses with — so the migration
## that used to eat ordinal ids runs for real here. Before the fix the reply came
## back `missing_via_ids: ["via_1"]` and the via was still on the board.
func _run_round_trip_keeps_ids() -> void:
	print("\n-- 2. an id held across export_yaml → load_board still names its copper --")
	var data = _seed_board()
	var via_id: String = data.add_via({"position": Vector2(9, 9), "size": 0.8,
		"drill": 0.4, "net_name": "GND", "from_layer": "top", "to_layer": "bottom"})
	var trace = data.create_trace_entity("GND", "top", [Vector2(1, 1), Vector2(5, 1)])
	var trace_id := str(trace.id) if trace != null else ""

	var yaml := _serialize_via_worker(data.to_board_dict())
	if yaml.is_empty():
		printerr("[test_copper_identity_ownership] REAL-WORKER round trip unavailable — " +
			"group 2 could not run; real_worker_used stays false and the gd runner " +
			"fails this suite. Build <minerva-plugins>/pcb/pcb-plugin.")
		return
	check("2a: export_yaml emitted the via id verbatim", yaml.find(via_id) >= 0)
	check("2b: export_yaml emitted the trace id verbatim", yaml.find(trace_id) >= 0)

	var board: Dictionary = _deserialize_via_worker(yaml)
	if board.is_empty():
		printerr("[test_copper_identity_ownership] REAL-WORKER deserialize failed — group 2 incomplete")
		return
	_used_real_worker = true

	var reloaded = _seed_board()
	reloaded.from_board_dict(board)
	check_eq("2c: the reloaded board carries one via", reloaded.vias.size(), 1)
	check("2d: it carries the SAME via id the caller held",
		reloaded.find_via_index(via_id) >= 0)
	check("2e: and the SAME trace id", reloaded.get_trace(trace_id) != null)

	# The verb the bug was reported through.
	var out: Dictionary = PanelTools._delete_traces(_StubHost.new(reloaded),
		{"via_ids": [via_id]})
	check("2f: delete_traces succeeds", bool(out.get("success", false)))
	check_eq("2g: the pre-reload via id DELETED the via",
		out.get("deleted_via_ids", []), [via_id])
	check_eq("2h: nothing was reported missing", out.get("missing_via_ids", []), [])
	check_eq("2i: the via really left the board", reloaded.vias.size(), 0)


# ── 3. "committed by" is a CHECKED claim ─────────────────────────────────────

func _run_attribution_is_checked() -> void:
	print("\n-- 3a. copper drawn by hand is never attributed to a stale record --")
	var data = _seed_board()
	# Hand-drawn copper on SIG, over on the right of the board.
	var hand = data.create_trace_entity("SIG", "top", [Vector2(60, 40), Vector2(70, 40)])
	var hand_id := str(hand.id) if hand != null else ""

	# A committed candidate on GND, routed on the LEFT, whose record names the
	# hand-drawn trace's id — the shape a re-minted id used to produce. Both the
	# net check and the bounds tiebreak refuse it.
	var ws = PcbRoutingWorkspace.new()
	var cid := _committed_candidate(ws, "GND", [Vector2(1, 1), Vector2(5, 1)], [hand_id])
	check_eq("3a-seed: the candidate is committed", str(ws.get_candidate(cid).disposition),
		"committed")

	var host = _StubHost.new(data, ws)
	var out: Dictionary = PanelTools._delete_traces(host, {"trace_ids": [hand_id]})
	check("3a-1: the delete succeeds", bool(out.get("success", false)))
	check_eq("3a-2: the trace was deleted", out.get("deleted_trace_ids", []), [hand_id])
	check("3a-3: NO candidate is reported as having committed it",
		not out.has("reopened_candidate_ids"))
	check("3a-4: and no 'committed by' note rides the reply", not out.has("note"))
	check_eq("3a-5: the stranger's candidate is untouched, still committed",
		str(ws.get_candidate(cid).disposition), "committed")
	check_eq("3a-6: and its lying claim on that id was dropped, not kept",
		ws.committed_copper_ids(cid).get("trace_ids", []), [])

	print("\n-- 3b. a candidate that REALLY owns its copper is still reported --")
	var data2 = _seed_board()
	var owned = data2.create_trace_entity("GND", "top", [Vector2(1, 1), Vector2(5, 1)])
	var owned_id := str(owned.id) if owned != null else ""
	var ws2 = PcbRoutingWorkspace.new()
	var cid2 := _committed_candidate(ws2, "GND", [Vector2(1, 1), Vector2(5, 1)], [owned_id])

	var out2: Dictionary = PanelTools._delete_traces(_StubHost.new(data2, ws2),
		{"trace_ids": [owned_id]})
	check_eq("3b-1: the owned trace was deleted", out2.get("deleted_trace_ids", []), [owned_id])
	check_eq("3b-2: its candidate IS named on the reply",
		out2.get("reopened_candidate_ids", []), [cid2])
	check("3b-3: with the 'committed by' note", out2.has("note"))
	check("3b-4: and the commit was retired",
		str(ws2.get_candidate(cid2).disposition) != "committed")


# ── 4. a stale sidecar record is dropped on restore, with a finding ──────────

## ORACLE: the finding list load_into_workspace returns, plus the workspace's own
## post-restore state. Before the fix the record loaded verbatim and the
## candidate stayed committed over copper it did not own.
func _run_stale_sidecar_record_dropped() -> void:
	print("\n-- 4. a hand-corrupted sidecar ownership record is dropped on restore --")
	var data = _seed_board()
	# SIG copper on the right — what the corrupt record will point at.
	_add_trace(data, "trace:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "SIG", "top",
		[Vector2(60, 40), Vector2(70, 40)])
	var board_path := _temp_board_path("stale_ownership.pcbskel")

	var ws = PcbRoutingWorkspace.new()
	# The candidate is on GND and routed on the LEFT, but claims the SIG trace.
	var cid := _committed_candidate(ws, "GND", [Vector2(1, 1), Vector2(5, 1)],
		["trace:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
	var err: int = PcbRoutingSidecar.save_workspace(board_path, ws,
		data.to_board_dict(), int(data.board_revision))
	check_eq("4-seed: sidecar written", err, OK)

	var loaded = PcbRoutingWorkspace.new()
	var status: Dictionary = PcbRoutingSidecar.load_into_workspace(
		board_path, loaded, data.to_board_dict(), int(data.board_revision))
	check_eq("4a: the envelope itself loads clean (the BOARD is coherent)",
		str(status.get("status", "")), "loaded_clean")
	check("4b: the restore REPORTS the stale ownership record",
		status.has("stale_ownership"))
	var findings: Array = status.get("stale_ownership", [])
	check_eq("4c: one finding, for one candidate", findings.size(), 1)
	if findings.size() == 1:
		var f: Dictionary = findings[0]
		check_eq("4d: it names the candidate", str(f.get("candidate_id", "")), cid)
		check_eq("4e: and its net", str(f.get("net", "")), "GND")
		check_eq("4f: and the id it dropped", f.get("dropped_trace_ids", []),
			["trace:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
		check("4g: the commit was retired (nothing provable was left)",
			bool(f.get("uncommitted", false)))
	check("4h: the candidate is no longer committed over copper it does not own",
		loaded.get_candidate(cid) != null
			and str(loaded.get_candidate(cid).disposition) != "committed")
	check_eq("4i: and the claim is gone, not re-attached",
		loaded.committed_copper_ids(cid).get("trace_ids", []), [])
	# THE DISCRIMINATING FACT: the SIG trace itself is untouched — a dropped
	# record is bookkeeping, never a copper edit.
	check("4j: the SIG copper the record pointed at is still on the board",
		data.get_trace("trace:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null)

	_cleanup(board_path)


# ── real-worker bridge (same shape as test_pcb_single_trace_tool.gd) ─────────

## Drives the REAL pcb-plugin Go binary through pcb/scripts/e2e_route_stdio.py
## (Godot's OS.execute cannot pipe stdin — see that script's header). Returns ""
## when the binary genuinely is not built, so the caller can say so loudly.
func _serialize_via_worker(board_dict: Dictionary) -> String:
	var reply: Dictionary = _call_worker("pcb.serialize", {"board": board_dict})
	return str(reply.get("yaml", ""))


func _deserialize_via_worker(yaml_text: String) -> Dictionary:
	var reply: Dictionary = _call_worker("pcb.deserialize", {"yaml": yaml_text})
	var board: Variant = reply.get("board", {})
	return board if board is Dictionary else {}


func _call_worker(tool_name: String, args: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		return {}
	var req_uri := "user://copper_identity_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		printerr("[test_copper_identity_ownership] cannot write %s" % req_uri)
		return {}
	f.store_string(JSON.stringify(args))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)

	var output: Array = []
	var exit_code := OS.execute("python3", [wrapper_path, binary_path, req_abs, tool_name],
		output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code != 0 or not (parsed is Dictionary) \
			or not bool((parsed as Dictionary).get("ok", false)):
		printerr("[test_copper_identity_ownership] REAL-WORKER %s FAILED (exit %d): %s"
			% [tool_name, exit_code, str(output)])
		return {}
	var res: Variant = (parsed as Dictionary).get("result", {})
	return res if res is Dictionary else {}


# ── temp-file plumbing (plugin_panel_driver keeps writes contained) ──────────

func _temp_board_path(name: String) -> String:
	var dir: String = _driver.make_temp_board_dir("pcb_copper_identity")
	return dir + "/" + name


func _cleanup(board_path: String) -> void:
	var sp := PcbRoutingSidecar.sidecar_path_for(board_path)
	for p in [sp, sp + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
