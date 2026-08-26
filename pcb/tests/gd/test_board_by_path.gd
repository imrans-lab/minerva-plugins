extends SceneTree
## Regression: board-by-path + digest — the PANEL-SENDER half (work item
## 01a0223ec9e271269fd664fcf90dd20b).
##
## The host broker caps panel→plugin requests at 64 KiB
## (PluginScenePanelBroker.MAX_PAYLOAD_BYTES) and the senders in this panel
## inlined O(board) payloads straight into that pipe:
##   * route_board (plain AND draft_request) → pcb.route  {"board": …}
##   * _on_export_yaml_pressed + the promote flow → pcb.serialize {"board": …}
##   * load_board_from_yaml + promote's prior-file census → pcb.deserialize
##     {"yaml": …}
## On smart-remote-v2 (705 KB expanded) all of them die payload_too_large —
## routing ONE 2-pin hint fails identically to routing everything. Go's
## HandleSerialize additionally refuses OUTBOUND yaml over MaxPayloadBytes,
## so the panel must also CONSUME a {yaml_path, yaml_digest} reply.
##
## The fix: an over-limit payload swaps its board document for
## {board_path, board_digest} — an OS-native snapshot file + sha256 — via ONE
## panel_tools helper, and serialize consumers read oversized replies back
## through ONE result helper.
##
## RED/GREEN contract (cold review, finding 3): the NEW-ARM checks (helper
## presence, by-ref shapes, consumption) must FAIL before the fix exists;
## the UNCHANGED-BEHAVIOR invariants (small payloads pass through inline —
## Section 2 and check 0b) must PASS before AND after. The red-baseline run
## is deliberately partial, never zero.
##
## HITL-4 lesson (test_production_seam.gd): the request-assembly functions ARE
## the production path, so Section 1 drives the REAL senders with a
## capture-only fake IPC — never a double of the sender itself.
##
## Handler-side twins: pcb/worker/tests/test_board_by_path.py (Python route
## arm), pcb/internal/tools/board_by_path_test.go (Go codec arms).
##
## Run: godot --headless --path src --script \
##   res://../../minerva-plugins/pcb/tests/gd/test_board_by_path.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"

const HELPER := "board_payload_by_ref_if_large"
const YAML_RESULT_HELPER := "yaml_from_serialize_result"
## Snapshot retention the prune policy must respect (see 0j).
const PRUNE_KEEP := 8

## Untyped on purpose: a const-typed preload gets static-only analysis, so
## dynamic .call()/introspection on the script resource must go through an
## untyped reference (same idiom as test_dict_guard.gd's Script-typed params).
var PanelTools: Variant = load("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

## The cap is read from the broker script that owns it (cold review, finding
## 10) — this suite runs under --path src, so the host const is loadable.
var BROKER_CAP: int = load(BROKER_PATH).MAX_PAYLOAD_BYTES

var _fail := 0
var _passed := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, ("" if detail == "" else " — " + detail)])


class FakeEditor extends RefCounted:
	var tab_title: String = ""


## Capture-only IPC: records every (channel, payload) the panel emits and
## answers with a canned success so the sender under test runs to completion.
## Same seam idiom as test_draft_composer.gd's FakeGateIPC.
class CaptureIPC extends Node:
	var captured: Array = []  # [{channel, payload}]
	## Optional per-channel inner-result override, wrapped in the LIVE reply
	## envelope ({success, result:{ok, result:<override>}}) — the shape the
	## broker + Go actually produce, so consumer-level tests exercise the
	## real unwrap depth.
	var overrides: Dictionary = {}
	var _reply_id := ""
	var _last_channel := ""

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_reply_id = reply_id
		_last_channel = channel

	func last_payload(channel: String) -> Dictionary:
		for i in range(captured.size() - 1, -1, -1):
			if str(captured[i]["channel"]) == channel:
				return captured[i]["payload"]
		return {}

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		if overrides.has(_last_channel):
			return {"success": true,
				"result": {"ok": true, "result": overrides[_last_channel]}}
		return {"success": true, "result": {"ok": true, "result": {
			"success": true, "routes": [], "unrouted": [], "yaml": "name: canned",
			"board": {"version": 1, "name": "canned", "width_mm": 1.0,
				"height_mm": 1.0, "components": [], "nets": []},
			"warnings": []}}}


## A canonical board dict big enough that JSON.stringify(board) far exceeds
## the broker cap — the smart-remote-v2 class, synthesized.
func _oversized_board() -> Dictionary:
	var comps: Array = []
	for i in range(700):
		comps.append({
			"ref": "R%d" % i,
			"footprint": "Resistor_SMD:R_0402_1005Metric",
			"x_mm": float(i % 80) + 0.5, "y_mm": float(i % 90) + 0.25,
			"rotation_deg": 0.0, "layer": "top",
			"pins": [
				{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
					"pad_width_mm": 0.6, "pad_height_mm": 0.5},
				{"number": "2", "x_mm": 1.0, "y_mm": 0.0,
					"pad_width_mm": 0.6, "pad_height_mm": 0.5},
			],
		})
	return {"version": 1, "name": "big-by-path", "width_mm": 90.0,
		"height_mm": 100.0, "layers": ["top", "bottom"],
		"components": comps, "nets": []}


func _tiny_board() -> Dictionary:
	return {"version": 1, "name": "tiny", "width_mm": 30.0, "height_mm": 30.0,
		"layers": ["top", "bottom"], "components": [],
		"nets": [{"name": "GND", "pins": []}]}


func _rig(board: Dictionary) -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(board)
	var ipc := CaptureIPC.new()
	ipc.bind(panel)
	return {"panel": panel, "ipc": ipc}


func _has_method_named(script: Variant, method_name: String) -> bool:
	for m in script.get_script_method_list():
		if str(m.get("name", "")) == method_name:
			return true
	return false


## Fresh, empty snapshot dir per run (cold review, finding 11: never let the
## host project's user dir accumulate multi-hundred-KB snapshots).
func _snapshot_dir() -> String:
	var dir := "user://test_board_by_path_snapshots"
	var abs := ProjectSettings.globalize_path(dir)
	var d := DirAccess.open(ProjectSettings.globalize_path("user://"))
	if d != null and d.dir_exists("test_board_by_path_snapshots"):
		for f in DirAccess.get_files_at(abs):
			DirAccess.remove_absolute(abs.path_join(f))
	DirAccess.make_dir_recursive_absolute(abs)
	return dir


func _dir_file_count(dir: String) -> int:
	return DirAccess.get_files_at(ProjectSettings.globalize_path(dir)).size()


## Shared assertions for a payload that must have gone by-ref.
func _check_by_ref(tag: String, payload: Dictionary, inlined_key: String) -> void:
	check("%s: inline '%s' left the payload" % [tag, inlined_key],
		not payload.has(inlined_key))
	check("%s: payload carries board_path + board_digest" % tag,
		payload.has("board_path") and payload.has("board_digest"),
		"keys=%s" % str(payload.keys()))
	var wire := JSON.stringify(payload)
	check("%s: request fits the broker cap" % tag, wire.length() < BROKER_CAP,
		"%d bytes" % wire.length())
	var path := str(payload.get("board_path", ""))
	# Finding 5: the worker is a SEPARATE OS process — a user://-style path
	# goes green in this suite's own FileAccess checks yet is unreadable by
	# Python's open() / Go's os.ReadFile, defeating the entire fix.
	check("%s: board_path is OS-native absolute (no user:// or res://)" % tag,
		path.is_absolute_path() and not path.begins_with("user://")
		and not path.begins_with("res://"), path)
	check("%s: snapshot file exists" % tag, FileAccess.file_exists(path), path)
	if FileAccess.file_exists(path):
		var digest := str(payload.get("board_digest", ""))
		check("%s: digest matches snapshot bytes" % tag,
			FileAccess.get_sha256(path).to_lower() == digest.to_lower())


func _init() -> void:
	print("=== board-by-path: panel senders + snapshot helper ===\n")

	# ── Section 0: the snapshot + consumption helpers (panel_tools statics) ──
	print("-- 0: panel_tools.%s contract --" % HELPER)
	check("0a: helper exists on panel_tools", _has_method_named(PanelTools, HELPER),
		"panel senders still inline O(board) payloads")
	if _has_method_named(PanelTools, HELPER):
		var dir := _snapshot_dir()
		# Small payload: IDENTITY — an unchanged-behavior invariant, green
		# before AND after the fix.
		var small := {"board": _tiny_board(), "selection": {}}
		var small_out: Dictionary = PanelTools.call(HELPER, small, "board", dir)
		check("0b: under-limit payload passes through unchanged", small_out == small)
		# Large dict payload (route/serialize shape).
		var big := {"board": _oversized_board(), "route_hints": [], "selection": {}}
		check("0c: fixture really exceeds the cap",
			JSON.stringify(big).length() > BROKER_CAP)
		var big_out: Dictionary = PanelTools.call(HELPER, big, "board", dir)
		_check_by_ref("0d (dict)", big_out, "board")
		var f := FileAccess.open(str(big_out.get("board_path", "")), FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			check("0e: snapshot parses back to the same board",
				parsed is Dictionary
				and str((parsed as Dictionary).get("name", "")) == "big-by-path"
				and ((parsed as Dictionary).get("components", []) as Array).size() == 700)
		# Large string payload (deserialize shape).
		var big_text := "# padding\n".repeat(12000)
		var text_out: Dictionary = PanelTools.call(
			HELPER, {"yaml": big_text}, "yaml", dir)
		_check_by_ref("0f (text)", text_out, "yaml")
		var f2 := FileAccess.open(str(text_out.get("board_path", "")), FileAccess.READ)
		if f2 != null:
			check("0g: text snapshot is byte-identical", f2.get_as_text() == big_text)
		# Finding 4: non-mutation is LOAD-BEARING — _request_with_backend_
		# ensure's retry re-emits the SAME payload dict, so in-place stripping
		# would break the retry (and made the old uniqueness check vacuous).
		check("0h1: helper does not mutate its input", big.has("board"))
		var again: Dictionary = PanelTools.call(HELPER, big, "board", dir)
		check("0h2: second call goes by-ref too", again.has("board_path"),
			"keys=%s" % str(again.keys()))
		check("0h3: successive snapshots get distinct paths",
			str(again.get("board_path", "")) != str(big_out.get("board_path", "")))
		# Finding 8: snapshot lifetime. The helper must NOT delete the file it
		# just wrote (the ensure-retry re-reads it) but must not accumulate
		# forever either — a count-bounded prune.
		var last_ref: Dictionary = {}
		for i in range(12):
			last_ref = PanelTools.call(HELPER, big, "board", dir)
		check("0j1: newest snapshot survives its own call (retry safety)",
			FileAccess.file_exists(str(last_ref.get("board_path", ""))))
		check("0j2: snapshot dir is prune-bounded (≤ %d files)" % PRUNE_KEEP,
			_dir_file_count(dir) <= PRUNE_KEEP,
			"%d files" % _dir_file_count(dir))

	# Finding 7: serialize CONSUMERS must read the oversized reply shape —
	# Go answers {yaml_path, yaml_digest} above MaxPayloadBytes, and a promote
	# that only reads .yaml reports "empty document" exactly on large boards.
	print("\n-- 0i: panel_tools.%s contract --" % YAML_RESULT_HELPER)
	check("0i1: consumption helper exists on panel_tools",
		_has_method_named(PanelTools, YAML_RESULT_HELPER))
	if _has_method_named(PanelTools, YAML_RESULT_HELPER):
		var inline: Dictionary = PanelTools.call(
			YAML_RESULT_HELPER, {"yaml": "name: inline"})
		check("0i2: inline yaml passes through",
			bool(inline.get("ok", false)) and str(inline.get("yaml", "")) == "name: inline")
		var ydir := ProjectSettings.globalize_path("user://test_board_by_path_snapshots")
		var ypath := ydir.path_join("reply.yaml")
		var yf := FileAccess.open(ypath, FileAccess.WRITE)
		yf.store_string("name: from-file")
		yf.close()
		# Refusals FIRST — a successful read CONSUMES the file (see 0i6), and
		# a failed read must leave it in place for diagnosis.
		var bad_ref: Dictionary = PanelTools.call(YAML_RESULT_HELPER,
			{"yaml_path": ypath, "yaml_digest": "0".repeat(64)})
		check("0i3: digest mismatch is refused, never trusted",
			not bool(bad_ref.get("ok", true))
			and str(bad_ref.get("error", "")).findn("digest") != -1
			and FileAccess.file_exists(ypath))
		var ghost_ref: Dictionary = PanelTools.call(YAML_RESULT_HELPER,
			{"yaml_path": ydir.path_join("ghost.yaml"), "yaml_digest": "0".repeat(64)})
		check("0i4: missing file is refused", not bool(ghost_ref.get("ok", true)))
		var ok_ref: Dictionary = PanelTools.call(YAML_RESULT_HELPER,
			{"yaml_path": ypath, "yaml_digest": FileAccess.get_sha256(ypath)})
		check("0i5: yaml_path reply reads the file",
			bool(ok_ref.get("ok", false)) and str(ok_ref.get("yaml", "")) == "name: from-file")
		check("0i6: reply document is consumed on successful read",
			not FileAccess.file_exists(ypath))

	# ── Section 1: the REAL senders, oversized board ─────────────────────────
	print("\n-- 1: live senders (route / draft route / serialize / deserialize) --")
	var rig := _rig(_oversized_board())
	var panel = rig["panel"]
	var ipc: CaptureIPC = rig["ipc"]
	check("1a: rig board really exceeds the cap",
		JSON.stringify(panel.get_data().to_board_dict()).length() > BROKER_CAP)

	await panel.route_board({"mode": "open"})
	_check_by_ref("1b route_board", ipc.last_payload("pcb.route"), "board")

	# Finding 6: the draft_request COMPOSED-board branch backs workspace
	# propose/reroute — the exact smart-remote-v2 failure. A fix wrapping only
	# the plain to_board_dict() call site must fail here.
	ipc.captured.clear()
	await panel.route_board({"mode": "open"}, {"draft_request": true})
	_check_by_ref("1c route_board (draft_request)", ipc.last_payload("pcb.route"), "board")

	await panel._on_export_yaml_pressed()
	_check_by_ref("1d export→serialize", ipc.last_payload("pcb.serialize"), "board")

	var big_yaml := "# canonical source stand-in\n".repeat(6000)
	await panel.load_board_from_yaml(big_yaml)
	_check_by_ref("1e load→deserialize", ipc.last_payload("pcb.deserialize"), "yaml")

	# Fix cold review F1: the promote GATE rides the same capped pipe one hop
	# before promote's serialize — an unwired gate refuses exactly the boards
	# the by-ref serialize exists for. Passed a fresh oversized dict: 1e's
	# canned deserialize reply has just REPLACED the panel's live board with
	# the tiny canned one, so get_data() here would gate a small board.
	await panel.run_promote_gate(_oversized_board())
	_check_by_ref("1f promote gate", ipc.last_payload("pcb.promote_check"), "board")

	# Fix cold review F2: the export CONSUMER must read the worker's over-cap
	# {yaml_path, yaml_digest} reply at the LIVE envelope depth — the canned
	# override below is wrapped exactly as broker + Go wrap it.
	var reply_dir := ProjectSettings.globalize_path("user://test_board_by_path_snapshots")
	var reply_path := reply_dir.path_join("serialize_reply.yaml")
	var rf := FileAccess.open(reply_path, FileAccess.WRITE)
	rf.store_string("# oversized stand-in\n".repeat(40))
	rf.close()
	ipc.overrides["pcb.serialize"] = {"yaml_path": reply_path,
		"yaml_digest": FileAccess.get_sha256(reply_path), "bytes": 840}
	await panel._on_export_yaml_pressed()
	check("1g1: export consumed the by-path reply (status reports bytes)",
		str(panel._status_label.text).begins_with("YAML exported ("),
		str(panel._status_label.text))
	check("1g2: reply document consumed after the successful read",
		not FileAccess.file_exists(reply_path))
	ipc.overrides.clear()

	# ── Section 2: small board keeps today's inline wire shape ───────────────
	# Unchanged-behavior invariants: green before AND after the fix.
	print("\n-- 2: small board unchanged --")
	var rig2 := _rig(_tiny_board())
	var panel2 = rig2["panel"]
	var ipc2: CaptureIPC = rig2["ipc"]
	await panel2.route_board({"mode": "open"})
	var small_route := ipc2.last_payload("pcb.route")
	check("2a: small board still inlines 'board'", small_route.has("board"))
	check("2b: small board carries no board_path", not small_route.has("board_path"))

	# ── Section 3: minerva_pcb_board_drc, the live-board DRC verb ────────────
	# {editor_name} checks the LIVE board through the backend DRC tools, by
	# reference over the cap, and the reply is the worker's findings payload
	# with no board echo. ORACLE: the captured channel request (its shape and
	# its by-ref file, through _check_by_ref) and the reply against the canned
	# worker result the fake IPC answers with — the worker's own by-path arms
	# are pinned by pcb/worker/tests/test_board_by_path.py::
	# test_drc_methods_accept_board_path.
	print("\n-- 3: minerva_pcb_board_drc by editor_name --")
	# Section 1's load→deserialize replaced the live board with the fake IPC's
	# canned (tiny) one; put the oversized board back so this verb's own
	# to_board_dict is over the cap.
	panel.get_data().from_board_dict(_oversized_board())
	var host = panel._annotation_host
	var canned_findings: Array = [{"type": "dangling_endpoint", "net": "GND", "at": [1.0, 2.0]}]
	ipc.overrides["minerva_pcb_drc"] = {"ok": true, "scope": "connectivity",
		"findings": canned_findings, "counts": {"dangling_endpoint": 1}}
	var drc: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_drc", {"editor_name": "PCB1"})
	var drc_req: Dictionary = ipc.last_payload("minerva_pcb_drc")
	check("3a: the default check sends the live board over the backend drc tool", not drc_req.is_empty())
	_check_by_ref("3b (board_drc, oversized)", drc_req, "board")
	check("3c: the reply is the worker's findings payload, no board echo",
		bool(drc.get("success", false)) and drc.get("findings", []) == canned_findings
			and str(drc.get("scope", "")) == "connectivity"
			and str(drc.get("check", "")) == "connectivity"
			and not drc.has("board") and not drc.has("yaml")
			and str(drc.get("board_source", "")) == "editor", str(drc))

	ipc.overrides["minerva_pcb_drc_geometric"] = {"ok": true, "scope": "geometric",
		"verifies_geometry": true, "verdict": "clean", "findings": [], "advisories": [],
		"counts": {}}
	var geo: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_drc",
		{"editor_name": "PCB1", "geometric": true, "verbose_warnings": true})
	var geo_req: Dictionary = ipc.last_payload("minerva_pcb_drc_geometric")
	_check_by_ref("3d (board_drc geometric, oversized)", geo_req, "board")
	check("3e: verbose_warnings rides the geometric request", bool(geo_req.get("verbose_warnings", false)))
	check("3f: the geometric union comes back as the reply",
		bool(geo.get("success", false)) and str(geo.get("verdict", "")) == "clean"
			and str(geo.get("check", "")) == "geometric"
			and str(geo.get("board_source", "")) == "editor", str(geo))
	check("3g: no request went out on the connectivity tool for a geometric check",
		ipc.captured[ipc.captured.size() - 1]["channel"] == "minerva_pcb_drc_geometric")

	# The worker's INDETERMINATE union — {ok:false, verdict, error:{kind,...}}
	# INSIDE a successful method envelope, exactly as methods.py returns it —
	# must reach the caller intact: verdict and structured cause, never a
	# generic worker_error.
	ipc.overrides["minerva_pcb_drc_geometric"] = {"ok": false, "scope": "geometric",
		"verifies_geometry": false, "verdict": "indeterminate",
		"error": {"kind": "compile", "message": "unmodelable land on R3"}}
	var indeterminate: Dictionary = await PanelTools.handle(host, "minerva_pcb_board_drc",
		{"editor_name": "PCB1", "geometric": true})
	check("3j: an indeterminate geometric union arrives verbatim — verdict and error object",
		bool(indeterminate.get("success", false))
			and str(indeterminate.get("verdict", "")) == "indeterminate"
			and indeterminate.get("error", null) is Dictionary
			and str((indeterminate.get("error", {}) as Dictionary).get("kind", "")) == "compile"
			and str(indeterminate.get("check", "")) == "geometric", str(indeterminate))
	ipc.overrides.clear()

	# A small live board keeps today's inline wire shape.
	ipc2.overrides["minerva_pcb_drc"] = {"ok": true, "scope": "connectivity", "findings": [], "counts": {}}
	var small: Dictionary = await PanelTools.handle(panel2._annotation_host, "minerva_pcb_board_drc",
		{"editor_name": "PCB1"})
	var small_req: Dictionary = ipc2.last_payload("minerva_pcb_drc")
	check("3h: a small live board is sent inline as the panel's own to_board_dict",
		small_req.get("board", {}) == panel2.get_data().to_board_dict()
			and not small_req.has("board_path"))
	check("3i: ...and the reply is its findings", bool(small.get("success", false))
		and (small.get("findings", ["x"]) as Array).is_empty())
	ipc2.overrides.clear()

	panel.free()
	panel2.free()
	print("\n=== Results: %d passed, %d failed ===" % [_passed, _fail])
	quit(1 if _fail > 0 else 0)
