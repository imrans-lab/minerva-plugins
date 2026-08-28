extends SceneTree
## SR2FAB S6: the draft-check seam — board-by-reference, and one name per fault.
##
## check_draft returned a bare {} for three unrelated faults: a panel with no
## worker bridge, a staged ghost dragged while the worker was scoring, and a
## broker refusal or timeout. All three arrived at minerva_pcb_workspace_check
## as "draft_check_no_reply" — one message for three problems with three
## different fixes, and the one the user causes (dragging a ghost) blamed the
## worker.
##
## It also sent the composed draft board INLINE while every other board-carrying
## sender goes by reference (work item 01a0223ec9e271269fd664fcf90dd20b). The
## draft board is the canonical board PLUS the staged overlay, so it is the
## largest payload any channel sends, and on a real board it died at the
## broker's 64KiB cap — arriving, of course, as an empty reply.
##
## RED/GREEN: every assertion in sections 1 and 2 fails against pre-station
## code, which returned {} (no `error` key) and emitted an inline board.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_draft_check_seam.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const BROKER_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PcbWorkspace := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("res://../../minerva-plugins/pcb/ui/model/pcb_route_candidate.gd")
const PcbSidecar := preload("res://../../minerva-plugins/pcb/ui/model/pcb_routing_sidecar.gd")

## A scratch board path for section 5: the sidecar writes beside it, and the
## file is removed again when the section ends.
const PROBE_BOARD_PATH := "user://draft_check_token_probe.pcb.yaml"

var BROKER_CAP: int = load(BROKER_PATH).MAX_PAYLOAD_BYTES

var _pass := 0
var _fail := 0


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


class FakeEditor extends RefCounted:
	var tab_title: String = ""


## Capture-and-canned IPC. `mutate_board` is the drift seam: the board "edits
## itself" while the worker is replying, which is what a user dragging a ghost
## looks like from here.
class DraftIPC extends Node:
	var captured: Array = []
	var reply: Dictionary = {}
	var mutate_board = null
	var _reply_id := ""

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_reply_id = reply_id

	func last(channel: String) -> Dictionary:
		for i in range(captured.size() - 1, -1, -1):
			if str(captured[i]["channel"]) == channel:
				return captured[i]["payload"]
		return {}

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		if mutate_board != null:
			mutate_board.board_width = float(mutate_board.board_width) + 1.0
		return reply.duplicate(true)


func _tiny_board() -> Dictionary:
	return {"version": 1, "name": "s6", "width_mm": 30.0, "height_mm": 30.0,
		"layers": ["top", "bottom"], "components": [],
		"nets": [{"name": "GND", "pins": []}]}


func _oversized_board() -> Dictionary:
	var comps: Array = []
	for i in range(700):
		comps.append({"ref": "R%d" % i, "footprint": "Resistor_SMD:R_0805_2012Metric",
			"x_mm": float(i % 80) + 0.5, "y_mm": float(i % 90) + 0.25,
			"rotation_deg": 0.0, "layer": "top",
			"pins": [
				{"number": "1", "x_mm": 0.0, "y_mm": 0.0,
					"pad_width_mm": 0.6, "pad_height_mm": 0.5},
				{"number": "2", "x_mm": 1.0, "y_mm": 0.0,
					"pad_width_mm": 0.6, "pad_height_mm": 0.5}]})
	return {"version": 1, "name": "s6-oversized", "width_mm": 90.0,
		"height_mm": 100.0, "layers": ["top", "bottom"],
		"components": comps, "nets": []}


func _panel(board: Dictionary):
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(board)
	return panel


## A canned reply in the shape the broker + worker really produce.
static func _worker_reply(inner: Dictionary) -> Dictionary:
	return {"success": true, "result": {"ok": true, "result": inner}}


func _init() -> void:
	print("=== S6: draft-check seam ===\n")
	await process_frame
	await _run_by_ref()
	await _run_named_faults()
	await _run_success_unchanged()
	_run_state_wedge()
	await _run_token_agreement()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1: the composed draft board travels by reference ────────────────────────

func _run_by_ref() -> void:
	print("-- 1: oversized draft board goes by-ref --")
	var panel = _panel(_oversized_board())
	var ipc := DraftIPC.new()
	ipc.bind(panel)
	ipc.reply = _worker_reply({"per_candidate": {}, "findings": [],
		"board_token": "", "workspace_generation": 0})

	check("the composed draft board really exceeds the broker cap",
		JSON.stringify(panel.draft_check_board()).length() > BROKER_CAP)
	await panel.check_draft([])
	var payload: Dictionary = ipc.last("pcb.draft_check")
	check("the request reached the channel", not payload.is_empty())
	check("the inline board left the payload", not payload.has("board"))
	check("…replaced by board_path + board_digest",
		payload.has("board_path") and payload.has("board_digest"),
		str(payload.keys()))
	check("…and the whole request now fits the broker cap",
		JSON.stringify(payload).length() < BROKER_CAP,
		"%d bytes" % JSON.stringify(payload).length())
	var snap := str(payload.get("board_path", ""))
	check("…at an OS-native absolute path the worker process can open",
		snap.is_absolute_path() and not snap.begins_with("user://")
		and not snap.begins_with("res://"), snap)
	check("…whose digest matches the snapshot bytes",
		FileAccess.file_exists(snap)
		and FileAccess.get_sha256(snap).to_lower()
			== str(payload.get("board_digest", "")).to_lower())
	# draft_provenance rides BESIDE the board and must not have been swept into
	# the snapshot along with it.
	check("draft_provenance still rides the request itself",
		payload.has("draft_provenance"))


# ── 2: one name per fault ───────────────────────────────────────────────────

func _run_named_faults() -> void:
	print("\n-- 2: each fault names itself --")

	# 2a: no worker bridge at all. This is the panel's own state, not the
	# worker's silence, and the fix is to mount/start the plugin.
	var unmounted = _panel(_tiny_board())
	var no_bridge: Dictionary = await unmounted.check_draft([])
	check_eq("2a: no IPC bridge names itself",
		str(no_bridge.get("error", "")), "draft_check_unavailable")
	check("2a: …and carries no per_candidate a caller could read as a verdict",
		not no_bridge.has("per_candidate"))

	# 2b: the broker refused the request. The fix is on the worker side.
	var refused_panel = _panel(_tiny_board())
	var refused_ipc := DraftIPC.new()
	refused_ipc.bind(refused_panel)
	refused_ipc.reply = {"success": false, "error_code": "worker_crashed",
		"error_message": "pcb worker exited 137"}
	var refused: Dictionary = await refused_panel.check_draft([])
	check_eq("2b: a refusal names itself",
		str(refused.get("error", "")), "draft_check_refused")
	check("2b: …carrying the worker's own message",
		str(refused.get("error_message", "")).contains("exited 137"))

	# 2c: the request timed out. Same channel, different fault, different fix.
	var slow_panel = _panel(_tiny_board())
	var slow_ipc := DraftIPC.new()
	slow_ipc.bind(slow_panel)
	slow_ipc.reply = {"success": false, "error_code": "timeout",
		"error_message": "no reply within 30000ms"}
	var timed_out: Dictionary = await slow_panel.check_draft([])
	check_eq("2c: a timeout names itself",
		str(timed_out.get("error", "")), "draft_check_timeout")

	# 2d: a ghost moved while the worker was scoring. THE USER caused this, and
	# it used to be reported as the worker failing to answer.
	var drift_panel = _panel(_tiny_board())
	var drift_ipc := DraftIPC.new()
	drift_ipc.bind(drift_panel)
	drift_ipc.reply = _worker_reply({"per_candidate": {}, "findings": [],
		"board_token": "", "workspace_generation": 0})
	drift_ipc.mutate_board = drift_panel.get_data()
	var drifted: Dictionary = await drift_panel.check_draft([])
	check_eq("2d: a mid-flight edit names itself",
		str(drifted.get("error", "")), "draft_overlay_drifted")
	check("2d: …and the note blames the edit, not the worker",
		not str(drifted.get("note", "")).contains("did not answer"),
		str(drifted.get("note", "")))

	# 2e: all four are DISTINCT. A de-conflation that produced two names for
	# four faults would satisfy every assertion above and still be the bug.
	var names := [str(no_bridge.get("error", "")), str(refused.get("error", "")),
		str(timed_out.get("error", "")), str(drifted.get("error", ""))]
	var unique := {}
	for n in names:
		unique[n] = true
	check_eq("2e: four faults, four distinct names", unique.size(), 4)


# ── 3: the success path is untouched ────────────────────────────────────────

func _run_success_unchanged() -> void:
	print("\n-- 3: a real verdict still comes back verbatim --")
	var panel = _panel(_tiny_board())
	var ipc := DraftIPC.new()
	ipc.bind(panel)
	ipc.reply = _worker_reply({
		"per_candidate": {"cand_1": "clean"},
		"findings": [{"type": "gc2_copper_clearance"}],
		"board_token": "tok", "workspace_generation": 3})
	var out: Dictionary = await panel.check_draft([])
	check("3: the inner result comes back", out.has("per_candidate"))
	check_eq("3: …with the worker's findings", (out.get("findings", []) as Array).size(), 1)
	check_eq("3: …and its generation", int(out.get("workspace_generation", -1)), 3)
	check("3: …and carries no error key", not out.has("error"))


# ── 4: a coherent reply that answers for nothing must not wedge the state ───
#
# THE FAILURE THIS PREVENTS. The worker's fail-closed refusal (an unreadable
# board snapshot) returns a COHERENT board_token and workspace_generation with
# an EMPTY per_candidate, because the panel's coherence guard has to recognise
# the reply as its own. apply_check_result's whole-reply guards therefore pass
# it, its per-candidate loop has nothing to iterate, and it then clears
# _pending_check — leaving every candidate this check flipped to "checking"
# stuck there. Nothing else in the model ever clears that, and the NEXT check
# snapshots "checking" as their prior value, making it permanent.
#
# Sections 1-3 above cannot see this: they call check_draft([]) with no live
# candidates, so nothing is ever flipped and there is nothing to leave stuck.

func _run_state_wedge() -> void:
	print("\n-- 4: an unanswered candidate is reverted, not left checking --")
	var ws = PcbWorkspace.new()
	var c = PcbRouteCandidate.new()
	c.net = "N1"
	c.task_id = "N1|"
	c.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3,
		[Vector2(0, 0), Vector2(5, 0)]))
	var cid := str(ws.add_candidate(c))
	ws.set_validation(cid, "clean")

	var payload: Dictionary = ws.begin_check([cid])
	check_eq("the check flipped the candidate to checking",
		str(ws.get_candidate(cid).validation), "checking")

	# The worker's refusal shape, verbatim: coherent identity, no verdicts, an
	# error saying the verdict could not be reached.
	ws.apply_check_result({
		"board_token": payload.get("board_token", ""),
		"workspace_generation": payload.get("workspace_generation", -1),
		"per_candidate": {},
		"findings": [],
		"error": "draft_check board_path unreadable: digest mismatch",
	})
	check_eq("a coherent reply that answered for nothing reverts it",
		str(ws.get_candidate(cid).validation), "clean")

	# ...and the state is genuinely released, not merely repainted: a SECOND
	# check must be able to snapshot the real prior value. This is where the
	# wedge became permanent — the next begin_check would record "checking".
	var second: Dictionary = ws.begin_check([cid])
	ws.apply_check_result({
		"board_token": second.get("board_token", ""),
		"workspace_generation": second.get("workspace_generation", -1),
		"per_candidate": {},
		"findings": [],
	})
	check_eq("…and a second unanswered check still reverts to the real prior",
		str(ws.get_candidate(cid).validation), "clean")

	# A reply that DOES answer is untouched by the new guard.
	var third: Dictionary = ws.begin_check([cid])
	ws.apply_check_result({
		"board_token": third.get("board_token", ""),
		"workspace_generation": third.get("workspace_generation", -1),
		"per_candidate": {cid: "violating"},
		"findings": [],
	})
	check_eq("an answered candidate still takes its verdict",
		str(ws.get_candidate(cid).validation), "violating")


# ── 5: the draft check and the durable sidecar agree on "the same board" ────
#
# Both answer ONE question — "is the board still the one this was written
# for" — and they were answering it with two DIFFERENT hashes. check_draft
# stamped the v1 whole-dict fingerprint while the sidecar has written v2 (the
# canonical-survivor projection) ever since a promotion's serialize round trip
# started orphaning v1 sidecars. So a board the sidecar loads CLEAN carried a
# coherence token no draft reply could ever be checked against, and a GD-only
# session key — which v1 hashes and v2 does not — moved one token without
# moving the other.
#
# THE ORACLE IS THE FILE, not the hash function: what check_draft stamps on the
# workspace is compared with the board_fingerprint save_workspace really WROTE
# for the same board, read back off disk. Recomputing the fingerprint here
# would only prove the test can call the function the panel calls.

func _run_token_agreement() -> void:
	print("\n-- 5: the draft token IS the sidecar's board_fingerprint --")
	var panel = _panel(_tiny_board())
	var ipc := DraftIPC.new()
	ipc.bind(panel)
	ipc.reply = _worker_reply({"per_candidate": {}, "findings": [],
		"board_token": "", "workspace_generation": 0})
	# save_workspace DELETES the sidecar for an empty workspace, so give it one
	# candidate to carry — the section is about the envelope's token, not its
	# contents.
	var c = PcbRouteCandidate.new()
	c.net = "N1"
	c.task_id = "N1|"
	c.add_segment(PcbRouteCandidate.make_segment("", "top", 0.3,
		[Vector2(0, 0), Vector2(5, 0)]))
	panel.get_routing_workspace().add_candidate(c)

	var first: Array = await _token_pair(panel)
	check("the draft check stamped a coherence token", not str(first[0]).is_empty())
	check("the sidecar wrote a board_fingerprint", not str(first[1]).is_empty())
	check_eq("the draft token IS the sidecar's fingerprint", first[0], first[1])

	# One field of the board moves. BOTH owners must notice it, and they must
	# still be describing the same board afterwards.
	panel.get_data().set_board_size(41.0, 31.0)
	var second: Array = await _token_pair(panel)
	check("a board edit moved the draft token", second[0] != first[0])
	check_eq("…and the sidecar moved with it", second[0], second[1])

	PcbSidecar.delete_sidecar(PROBE_BOARD_PATH)


## [what check_draft stamps, what the sidecar writes] for the panel's CURRENT
## board — both taken from the production paths, neither recomputed here.
func _token_pair(panel) -> Array:
	await panel.check_draft([])
	PcbSidecar.save_workspace(PROBE_BOARD_PATH, panel.get_routing_workspace(),
		panel.get_data().to_saved_board_dict(),
		int(panel.get_data().board_revision), null)
	var envelope: Dictionary = PcbSidecar.read_envelope(PROBE_BOARD_PATH)
	return [str(panel.get_routing_workspace().board_token),
		str(envelope.get("board_fingerprint", ""))]
