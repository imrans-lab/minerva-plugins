extends SceneTree
## SR2FAB S1: minerva_pcb_export_yaml — the live board as canonical YAML TEXT.
##
## Before this station the Export YAML button (PCBPanel._on_export_yaml_pressed)
## serialized the board and threw the document away, rendering only a byte count
## to the status line. The only verb that produced YAML from the live board was
## minerva_pcb_promote, which refuses any board with a correctness finding — so
## a board the gate blocked could not be read out at all, not even to diff it
## against the file on disk.
##
## THE SHAPE THIS PINS (the design decision, so a later change has to argue with
## a failing test rather than an absent one): export_yaml returns the document
## and writes NOTHING. promote() stays the only verb in this panel that puts
## bytes in a .yaml file. A `path` argument is refused BY NAME rather than
## ignored, because an ignored path returns a success the caller reads as a file
## having been written.
##
## RED/GREEN contract (the convention test_board_by_path.gd established):
## Section 1's checks must FAIL against pre-station code — the dispatch arm
## returns {} for an unknown tool name, so every shape assertion here reds.
## Section 2's are UNCHANGED-BEHAVIOUR invariants, green before AND after: the
## button's status strings and promote's path guards must survive the extraction
## of export_yaml_text() out of the button body. They are deliberately not
## red-first, and the section says so.
##
## Section 5 pins the collapse onto ONE serializer: export and promote produce
## the same bytes for the same board. It reds against any world where the two
## doorways build their own board dict or read the reply at their own depth.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_export_yaml_verb.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")

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


## Capture-and-canned IPC. `reply` is the FULL envelope handed back to
## await_reply, so a test can pose a broker failure, a worker refusal or a
## success at the real nesting depth ({success, result:{ok, result:{…}}}). The
## depth is the point: a reply posed one level shallow passes a test that the
## real envelope would fail.
class FakeIPC extends Node:
	var captured: Array = []
	var reply: Dictionary = {}
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
		return reply.duplicate(true)


static func _ok_envelope(inner: Dictionary) -> Dictionary:
	return {"success": true, "result": {"ok": true, "result": inner}}


func _tiny_board() -> Dictionary:
	return {"version": 1, "name": "s1-export", "width_mm": 20.0, "height_mm": 20.0,
		"layers": ["top", "bottom"],
		"components": [{"ref": "R1", "footprint": "", "x_mm": 5.0, "y_mm": 5.0,
			"rotation_deg": 0, "layer": "top",
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]}],
		"nets": [{"name": "GND", "pins": ["R1.1"]}]}


## A board whose JSON far exceeds the broker's 64 KiB request cap, so the
## by-ref swap must engage (same synthesis idea as test_board_by_path.gd).
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
	return {"version": 1, "name": "s1-oversized", "width_mm": 90.0, "height_mm": 100.0,
		"layers": ["top", "bottom"], "components": comps, "nets": []}


## `resolved` is THIS host's resolve of the board, keyed by ref — the map a
## pcb.deserialize reply carries. Section 5 needs it to put a live session fact
## on the model.
func _rig(board: Dictionary, resolved: Dictionary = {}) -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(board, resolved)
	return {"panel": panel, "host": panel.get_annotation_host()}


func _scratch_dir() -> String:
	var abs := ProjectSettings.globalize_path("user://test_export_yaml_verb")
	if DirAccess.dir_exists_absolute(abs):
		for f in DirAccess.get_files_at(abs):
			DirAccess.remove_absolute(abs.path_join(f))
	DirAccess.make_dir_recursive_absolute(abs)
	return abs


func _init() -> void:
	print("=== S1: minerva_pcb_export_yaml ===\n")
	await process_frame
	await _run_dispatch_and_shape()
	await _run_refusals()
	await _run_by_ref()
	await _run_unchanged_behaviour()
	await _run_one_serializer()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── Section 1: dispatch + reply shape (RED before the station) ───────────────

func _run_dispatch_and_shape() -> void:
	print("-- 1: dispatch and reply shape --")
	var rig := _rig(_tiny_board())
	var panel = rig["panel"]

	# 1a: reachable by name, and honest without a backend. Pre-station the
	# match arm does not exist and handle() returns {}, so both of these red.
	var no_ipc: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("1a: without a backend the export refuses",
		bool(no_ipc.get("success", true)), false)
	check_eq("1a: …by name", str(no_ipc.get("error", "")), "worker_unavailable")

	# 1b: the document comes back, with the byte count and the draft label.
	var ipc := FakeIPC.new()
	ipc.bind(panel)
	ipc.reply = _ok_envelope({"yaml": "name: s1-export\nwidth_mm: 20.0\n"})
	var out: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("1b: the export succeeds", bool(out.get("success", false)), true)
	check_eq("1b: …carrying the document verbatim",
		str(out.get("yaml", "")), "name: s1-export\nwidth_mm: 20.0\n")
	check_eq("1b: …with bytes matching the document length",
		int(out.get("bytes", -1)), str(out.get("yaml", "")).length())
	check_eq("1b: …labelled a draft", bool(out.get("draft", false)), true)
	check("1b: …and the note says nothing was written",
		str(out.get("note", "")).contains("writes nothing")
		or str(out.get("note", "")).contains("nothing was written"),
		str(out.get("note", "")))

	# 1c: it goes through the SAME worker channel the button uses. A future
	# refactor onto a private channel would silently un-share the two doorways.
	check_eq("1c: the worker channel is pcb.serialize",
		str((ipc.captured[ipc.captured.size() - 1] as Dictionary).get("channel", "")),
		"pcb.serialize")

	# 1d: THE DESIGN DECISION. A path is refused by name and no file appears;
	# promote stays the only writer. An ignored path would return a success the
	# caller reads as "the file is on disk".
	var target := _scratch_dir().path_join("must_not_appear.yaml")
	var pathed: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {"path": target})
	check_eq("1d: a path argument is refused",
		bool(pathed.get("success", true)), false)
	check_eq("1d: …by name", str(pathed.get("error", "")), "path_not_supported")
	check("1d: …naming promote as the writer that gates",
		str(pathed.get("note", "")).contains("minerva_pcb_promote"),
		str(pathed.get("note", "")))
	check("1d: …and nothing was written to it",
		not FileAccess.file_exists(target), target)
	check_eq("1d: …the refusal happens before any worker round trip",
		ipc.captured.size(), 1)


# ── Section 2: refusal shapes (RED before the station) ──────────────────────

func _run_refusals() -> void:
	print("\n-- 2: refusals by name --")

	# 2a: no live panel at all.
	var orphan: Dictionary = await PanelTools.handle(
		null, "minerva_pcb_export_yaml", {})
	check_eq("2a: no live panel refuses", bool(orphan.get("success", true)), false)

	# 2b: the no-board guard. PCBPanel._init() builds _data eagerly and seeds a
	# default board, so a fresh .new() panel is NOT this state — the first
	# version of this test assumed it was and got worker_unavailable, because it
	# was measuring the guard one line further down.
	#
	# The state is still worth guarding: promote() and board_check() both open
	# with the same check, and every one of the three dereferences _data
	# immediately after. Forcing it is how a defensive guard gets tested at all.
	var bare: Variant = load(PANEL_PATH).new()
	bare._data = null
	var bare_out: Dictionary = await bare.export_yaml_text()
	check_eq("2b: a panel with no board refuses by name",
		str(bare_out.get("error", "")), "no_board")

	# 2c: the broker's own failure envelope, classified as the cap case. The
	# button classified this inline; the extraction must not lose it.
	var rig := _rig(_tiny_board())
	var ipc := FakeIPC.new()
	ipc.bind(rig["panel"])
	ipc.reply = {"success": false, "error_code": "payload_too_large",
		"error_message": "request exceeds broker cap"}
	var too_big: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("2c: an over-cap request refuses by name",
		str(too_big.get("error", "")), "payload_too_large")

	# 2d: any other broker failure is serialize_failed, carrying the worker's
	# own message rather than a generic sentence.
	ipc.reply = {"success": false, "error_code": "worker_crashed",
		"error_message": "pcb worker exited 137"}
	var failed: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("2d: a worker failure refuses by name",
		str(failed.get("error", "")), "serialize_failed")
	check("2d: …carrying the worker's message",
		str(failed.get("note", "")).contains("exited 137"),
		str(failed.get("note", "")))

	# 2e: an over-cap REPLY whose digest does not match its file is refused as
	# a read failure — never returned as an empty document, and never trusted.
	var scratch := _scratch_dir()
	var reply_path := scratch.path_join("reply.yaml")
	var f := FileAccess.open(reply_path, FileAccess.WRITE)
	f.store_string("# oversized stand-in\n".repeat(40))
	f.close()
	ipc.reply = _ok_envelope({"yaml_path": reply_path,
		"yaml_digest": "0".repeat(64), "bytes": 840})
	var bad_digest: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("2e: a digest mismatch refuses by name",
		str(bad_digest.get("error", "")), "serialize_read_failed")
	check("2e: …and leaves the document for diagnosis",
		FileAccess.file_exists(reply_path))

	# 2f: the same by-path reply with a TRUE digest is read back and consumed.
	ipc.reply = _ok_envelope({"yaml_path": reply_path,
		"yaml_digest": FileAccess.get_sha256(reply_path), "bytes": 840})
	var by_path: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("2f: a verified by-path reply succeeds",
		bool(by_path.get("success", false)), true)
	check("2f: …returning the file's bytes",
		str(by_path.get("yaml", "")).begins_with("# oversized stand-in"),
		str(by_path.get("yaml", "")).substr(0, 40))
	check("2f: …and consuming the reply document",
		not FileAccess.file_exists(reply_path))


# ── Section 3: by-ref request path (RED before the station) ─────────────────

func _run_by_ref() -> void:
	print("\n-- 3: oversized board goes by-ref --")
	var rig := _rig(_oversized_board())
	var ipc := FakeIPC.new()
	ipc.bind(rig["panel"])
	ipc.reply = _ok_envelope({"yaml": "name: s1-oversized\n"})
	check("3: the rig board really exceeds the broker cap",
		JSON.stringify(rig["panel"].get_data().to_board_dict()).length() > 65536)
	var out: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("3: the export still succeeds on an over-cap board",
		bool(out.get("success", false)), true)
	var payload: Dictionary = ipc.last("pcb.serialize")
	check("3: the inline board left the payload", not payload.has("board"))
	check("3: …replaced by board_path + board_digest",
		payload.has("board_path") and payload.has("board_digest"),
		str(payload.keys()))
	var snap := str(payload.get("board_path", ""))
	check("3: …at an OS-native absolute path the worker process can open",
		snap.is_absolute_path() and not snap.begins_with("user://")
		and not snap.begins_with("res://"), snap)
	check("3: …whose digest matches the snapshot bytes",
		FileAccess.file_exists(snap)
		and FileAccess.get_sha256(snap).to_lower()
			== str(payload.get("board_digest", "")).to_lower())


# ── Section 4: UNCHANGED behaviour — green BEFORE and after ─────────────────
#
# Not red-first, deliberately. Extracting export_yaml_text() out of the button
# body is a refactor, and these are what say the refactor kept its promises.

## The ONE-SHOT half of the status line — what THIS gesture said.
##
## _set_status writes `_status_lead() + message`, and a lead is a STANDING
## condition of the board that every later message is prefixed with. This rig's
## R1 carries no footprint, so "1 part have no fabricable geometry" leads every
## line here, exactly as it would on screen. The gesture's own words are the
## suffix; asserting the whole label would be asserting the standing lead too,
## and would break whenever an unrelated board condition gained a lead.
func _status_message(panel) -> String:
	var full := str(panel._status_label.text)
	var lead := str(panel._status_lead())
	return full.substr(lead.length()) if full.begins_with(lead) else full


func _run_unchanged_behaviour() -> void:
	print("\n-- 4: unchanged behaviour (green both sides) --")
	var rig := _rig(_tiny_board())
	var panel = rig["panel"]

	# 4a: the button with no IPC at all still says so, in its own words.
	await panel._on_export_yaml_pressed()
	check_eq("4a: the button reports a missing backend",
		_status_message(panel),
		"YAML export unavailable — plugin IPC not ready.")

	# 4b: a successful export still renders the byte count. test_board_by_path
	# asserts this same prefix through the by-path branch; here it is the
	# inline branch, so the two together cover both.
	var ipc := FakeIPC.new()
	ipc.bind(panel)
	ipc.reply = _ok_envelope({"yaml": "name: s1-export\n"})
	await panel._on_export_yaml_pressed()
	check("4b: the button reports the byte count",
		_status_message(panel).begins_with("YAML exported ("),
		str(panel._status_label.text))

	# 4c: a failed export still says failed, with the reason on the line.
	ipc.reply = {"success": false, "error_code": "worker_crashed",
		"error_message": "pcb worker exited 137"}
	await panel._on_export_yaml_pressed()
	check("4c: the button reports a failure by reason",
		_status_message(panel).begins_with("YAML export failed:")
		and _status_message(panel).contains("exited 137"),
		str(panel._status_label.text))

	# 4d: promote's path guards are untouched — adding an ungated reader must
	# not have loosened the gated writer. Both guards answer before any worker
	# hop, so this holds with the fake IPC bound.
	var skel: Dictionary = await panel.promote("/tmp/not-a-board.pcbskel")
	check_eq("4d: promote still refuses a .pcbskel target",
		str(skel.get("error", "")), "pcbskel_target")
	var no_target: Dictionary = await panel.promote("")
	check_eq("4d: …and still refuses with no adopted canonical path",
		str(no_target.get("error", "")), "no_target_path")


# ── Section 5: export and promote are ONE serializer ────────────────────────
#
# THE SHAPE THIS PINS: the Export YAML doorway and the promote write go through
# the same serialize call over the same canonical dict, so an agent diffing the
# export against the file on disk sees design differences only. Two doorways
# that each built their own board dict, or read the reply at their own depth,
# could drift — and drift reads as design change.
#
# TWO ORACLES, because byte equality alone is not one. The fake worker ECHOES
# the board it was handed back as the document, so the two texts are equal only
# if both doorways sent the same bytes AND read the reply the same way — R1
# carries a live footprint_resolved (this session's resolve of it), the fact a
# re-introduced second "saved shape" would strip from one side and not the
# other. But equal bytes are also what two SEPARATE implementations sending the
# same dict produce, so the second oracle is STRUCTURAL: each doorway makes
# exactly one serialize request, and the panel source carries exactly one
# `"pcb.serialize"` request literal. A doorway that regrew its own round-trip
# and its own refusal handling moves that count, whatever bytes it emits.

## An IPC that answers PER CHANNEL, and whose serialize reply is a function of
## the request. FakeIPC's single canned reply cannot serve promote, which hops
## the gate before the serializer.
class EchoIPC extends Node:
	var captured: Array = []
	var _replies: Dictionary = {}

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_replies[reply_id] = _answer(channel, payload)

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if not _replies.has(reply_id):
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		return (_replies[reply_id] as Dictionary).duplicate(true)

	func last(channel: String) -> Dictionary:
		for i in range(captured.size() - 1, -1, -1):
			if str(captured[i]["channel"]) == channel:
				return captured[i]["payload"]
		return {}

	func count(channel: String) -> int:
		var n := 0
		for entry in captured:
			if str((entry as Dictionary)["channel"]) == channel:
				n += 1
		return n

	func _answer(channel: String, payload: Dictionary) -> Dictionary:
		match channel:
			"pcb.promote_check":
				return {"success": true, "result": {"ok": true, "result": {
					"promotable": true, "refusals": [],
					"connectivity": {}, "geometric": {}, "assembly": {}}}}
			"pcb.serialize":
				return {"success": true, "result": {"ok": true, "result": {
					"yaml": "# echo\n%s\n" % JSON.stringify(payload.get("board", {}))}}}
		return {"success": false, "error_code": "unexpected_channel",
			"error_message": channel}


func _run_one_serializer() -> void:
	print("\n-- 5: export and promote are one serializer --")
	var rig := _rig(_tiny_board(), {"R1": {"footprint_resolved": true}})
	var panel = rig["panel"]
	check("5: the rig's R1 really carries this session's resolve",
		bool(panel.get_data().get_component("R1").footprint_resolved))
	var ipc := EchoIPC.new()
	ipc.bind(panel)

	var exported: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_export_yaml", {})
	check_eq("5: the export succeeds", bool(exported.get("success", false)), true)
	check_eq("5: …making exactly one serialize request",
		ipc.count("pcb.serialize"), 1)
	var export_payload: Dictionary = ipc.last("pcb.serialize")

	var target := _scratch_dir().path_join("promoted.yaml")
	var promoted: Dictionary = await panel.promote(target)
	check_eq("5: the promote succeeds (%s)" % str(promoted.get("error", "")),
		bool(promoted.get("success", false)), true)
	check_eq("5: …making exactly one more, not one of its own besides",
		ipc.count("pcb.serialize"), 2)
	var promote_payload: Dictionary = ipc.last("pcb.serialize")

	check("5: both doorways hand the serializer the same board",
		JSON.stringify(export_payload.get("board", {}))
			== JSON.stringify(promote_payload.get("board", {})))
	check_eq("5: …so the promoted file is the exported text, byte for byte",
		FileAccess.get_file_as_string(target), str(exported.get("yaml", "")))
	check("5: …and the promote digest is taken over those same bytes",
		str(promoted.get("digest_sha256", ""))
			== str(exported.get("yaml", "")).sha256_text())
	check_eq("5: the panel asks the serialize channel in exactly one place",
		_serialize_request_sites(), 1)


## How many places in the panel SOURCE ask the serialize channel. Comment
## mentions do not count: only a non-comment line carrying the quoted channel
## literal is a request site. -1 when the source cannot be read at all.
func _serialize_request_sites() -> int:
	var f := FileAccess.open(PANEL_PATH, FileAccess.READ)
	if f == null:
		return -1
	var text := f.get_as_text()
	f.close()
	var sites := 0
	for line in text.split("\n"):
		var trimmed := str(line).strip_edges()
		if not trimmed.begins_with("#") and trimmed.contains("\"pcb.serialize\""):
			sites += 1
	return sites
