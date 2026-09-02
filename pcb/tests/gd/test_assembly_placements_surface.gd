extends SceneTree
## THE COMPONENT-READING TOOLS CARRY ASSEMBLY IDENTITY AND RESOLVED PLACEMENT.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_assembly_placements_surface.gd
##
## WHAT IS AT STAKE. `minerva_pcb_get_components` and
## `minerva_pcb_describe_component` are how an agent learns what is on a board.
## Until now they said where a DRAWING sits and nothing about the PART: not
## which one to buy, and not — for a component that stands for several soldered
## parts — where any of them actually gets placed. The only clue that a part was
## synthetic was prose somebody typed into `value`.
##
## THE TWO FACTS, and the reason each is tested where it is:
##
##   `assembly` is the board's own block, verbatim out of the component's
##     canonical passthrough. Its oracle is the board dict that went in, and it
##     lives here.
##   `physical_placements` is the COMPILER's answer, arriving over the
##     pcb.assembly_placements channel. Whether those numbers are right is the
##     worker's oracle and is proven against the CPL writer in
##     worker/tests/test_assembly_placements_surface.py. What is proven HERE is
##     the other half: that the panel reports them and does not touch them — no
##     rounding, no re-composition, no quantization to the `_mm` grid every
##     other coordinate in these replies goes through. A surface that did its
##     own arithmetic would be free to disagree with the file the house reads.
##
## THE CANNED REPLY IS A RECORDING, not an invention: it is what the worker's
## `assembly_placements` method returns for smart-remote-v2 rev B's U1S and C1
## (parent at (45, 62.797) turned 180, two strips authored at ±11.43 with an
## anchor of (0, 26.67) turned 270). The channel itself is inherently
## unavailable in a headless suite, so it is the one thing stubbed.
##
## FAILS AGAINST OLD: neither key existed, so section A's first check goes red.

const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
const DATA_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_data.gd"
const SPATIAL_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_spatial_index.gd"

## The rev B socket set's authored block, copied field for field.
const U1S_ASSEMBLY := {
	"mpn": "HC-PM254-8.5H-1x22P",
	"package": "THT 2.54mm 1x22 socket",
	"comment": "ESP32-S3-DevKitC-1 socket row",
	"house_parts": {"jlcpcb": "C41376161"},
	"placements": [
		{"ref": "U1S_A", "offset_mm": {"x": -11.43, "y": 0.0},
			"anchor_mm": {"x": 0.0, "y": 26.67}, "rotation_deg": 270.0},
		{"ref": "U1S_B", "offset_mm": {"x": 11.43, "y": 0.0},
			"anchor_mm": {"x": 0.0, "y": 26.67}, "rotation_deg": 270.0},
	],
}
const C1_ASSEMBLY := {
	"manufacturer": "YAGEO",
	"mpn": "CC0805KRX7R9BB104",
	"package": "0805",
	"comment": "100nF 50V X7R",
	"house_parts": {"jlcpcb": "C49678"},
}

const PARENT_FOOTPRINT := "Espressif:ESP32-S3-DevKitC-1_SocketSet_2x22_THT"
## The board Y the parent and both strips share. Written out in full because
## the point of the check is that NOTHING rounds it on the way through.
const SOCKET_Y := 62.7970008850098

var _pass := 0
var _fail := 0

var _tools: Script = null
var _data = null
var _host = null
var _panel = null


## Stub of the panel's pcb.assembly_placements round trip. Answers with
## whatever `reply` holds and records which board model it was asked about.
class StubPanel:
	extends RefCounted
	var reply: Dictionary = {}
	var calls: int = 0
	var seen_revision: int = -1
	var seen_component_count: int = -1

	func assembly_placements(data) -> Dictionary:
		calls += 1
		seen_revision = int(data.board_revision)
		seen_component_count = int(data.get_component_count())
		return reply


## The three duck-typed accessors panel_tools reaches through a host.
## `panel` is nulled in section F to stand for a host with no live panel.
class StubHost:
	extends RefCounted
	var data = null
	var spatial = null
	var panel = null

	func get_board_data():
		return data

	func get_spatial_index():
		return spatial

	func get_panel():
		return panel


func _init() -> void:
	print("=== Assembly identity + resolved placement on the component tools ===\n")
	if not _setup():
		printerr("SETUP FAILED — cannot load the plugin model; aborting")
		quit(1)
		return
	await _run_resolved_passthrough()
	await _run_authored_identity()
	await _run_describe_component()
	await _run_channel_unavailable()
	await _run_board_does_not_compile()
	await _run_no_panel_bound()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("PASS: %s" % desc)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [desc, "" if detail.is_empty() else "  (%s)" % detail])


func _setup() -> bool:
	_tools = load(PANEL_TOOLS_PATH)
	var data_script: Script = load(DATA_PATH)
	var spatial_script: Script = load(SPATIAL_PATH)
	if _tools == null or data_script == null or spatial_script == null:
		return false
	_data = data_script.new()
	_data.from_board_dict(_board_dict())
	_panel = StubPanel.new()
	_panel.reply = _resolved_reply()
	_host = StubHost.new()
	_host.data = _data
	_host.spatial = spatial_script.new(_data)
	_host.panel = _panel
	return _data.get_component_count() == 3


## Three components: the socket set that expands, an ordinary part, and one
## that authors no assembly block at all.
func _board_dict() -> Dictionary:
	return {
		"name": "AssemblySurface", "width_mm": 100.0, "height_mm": 80.0,
		"layers": ["top", "bottom"],
		"components": [
			{"ref": "U1S", "footprint": PARENT_FOOTPRINT,
				"x_mm": 45.0, "y_mm": SOCKET_Y, "rotation_deg": 180.0,
				"layer": "top", "pins": [], "assembly": U1S_ASSEMBLY},
			{"ref": "C1", "footprint": "Capacitor_SMD:C_0805_2012Metric",
				"x_mm": 68.5, "y_mm": 31.0, "rotation_deg": 0.0,
				"layer": "top", "pins": [], "assembly": C1_ASSEMBLY},
			{"ref": "R1", "footprint": "Resistor_SMD:R_0805_2012Metric",
				"x_mm": 20.0, "y_mm": 20.0, "rotation_deg": 0.0,
				"layer": "top", "pins": []},
		],
	}


## The worker's own answer for that board, recorded (see the class doc).
func _resolved_reply() -> Dictionary:
	return {"ok": true, "result": {"resolved": true, "components": [
		{"component": "U1S", "footprint": PARENT_FOOTPRINT,
			"populate": true, "paste": "auto",
			"physical": [
				{"ref": "U1S_A",
					"origin": {"x_mm": 56.43, "y_mm": SOCKET_Y},
					"anchor": {"x_mm": 83.1, "y_mm": SOCKET_Y},
					"anchor_basis": "authored", "rotation_deg": 90.0,
					"side": "top", "footprint": PARENT_FOOTPRINT},
				{"ref": "U1S_B",
					"origin": {"x_mm": 33.57, "y_mm": SOCKET_Y},
					"anchor": {"x_mm": 60.24, "y_mm": SOCKET_Y},
					"anchor_basis": "authored", "rotation_deg": 90.0,
					"side": "top", "footprint": PARENT_FOOTPRINT},
			]},
		{"component": "C1", "footprint": "Capacitor_SMD:C_0805_2012Metric",
			"populate": true, "paste": "auto",
			"physical": [
				{"ref": "C1",
					"origin": {"x_mm": 68.5, "y_mm": 31.0},
					"anchor": {"x_mm": 68.5, "y_mm": 31.0},
					"anchor_basis": "fab_outline", "rotation_deg": 0.0,
					"side": "top",
					"footprint": "Capacitor_SMD:C_0805_2012Metric"},
			]},
		{"component": "R1", "footprint": "Resistor_SMD:R_0805_2012Metric",
			"populate": true, "paste": "auto",
			"physical": [
				{"ref": "R1",
					"origin": {"x_mm": 20.0, "y_mm": 20.0},
					"anchor": {"x_mm": 20.0, "y_mm": 20.0},
					"anchor_basis": "fab_outline", "rotation_deg": 0.0,
					"side": "top",
					"footprint": "Resistor_SMD:R_0805_2012Metric"},
			]},
	]}}


func _by_ref(reply: Dictionary) -> Dictionary:
	var out := {}
	for entry in reply.get("components", []):
		out[str((entry as Dictionary).get("id", ""))] = entry
	return out


# ── A. the compiler's numbers, untouched ─────────────────────────────────────

func _run_resolved_passthrough() -> void:
	print("\n-- A. the resolved placements arrive verbatim --")
	var reply: Dictionary = await _tools._get_components(_host, {})
	var comps := _by_ref(reply)
	var socket: Dictionary = comps.get("U1S", {})
	var places: Array = socket.get("physical_placements", [])

	check("get_components carries physical_placements on the socket set",
		places.size() == 2, "got %d" % places.size())
	check("both authored designators are named, in order",
		places.size() == 2
			and str((places[0] as Dictionary).get("ref", "")) == "U1S_A"
			and str((places[1] as Dictionary).get("ref", "")) == "U1S_B")

	var a: Dictionary = places[0] if places.size() == 2 else {}
	var anchor: Dictionary = a.get("anchor", {})
	check("U1S_A's anchor is the compiler's number, unrounded",
		float(anchor.get("x_mm", 0.0)) == 83.1
			and float(anchor.get("y_mm", 0.0)) == SOCKET_Y,
		JSON.stringify(anchor))
	check("U1S_A's origin is carried beside the anchor",
		float((a.get("origin", {}) as Dictionary).get("x_mm", 0.0)) == 56.43)
	check("U1S_A carries the composed rotation, side and basis",
		float(a.get("rotation_deg", -1.0)) == 90.0
			and str(a.get("side", "")) == "top"
			and str(a.get("anchor_basis", "")) == "authored")
	check("the placement names the drawing it is described by",
		str(a.get("footprint", "")) == PARENT_FOOTPRINT)

	var ordinary: Array = (comps.get("C1", {}) as Dictionary).get("physical_placements", [])
	check("an ordinary part surfaces exactly one placement under its own ref",
		ordinary.size() == 1
			and str((ordinary[0] as Dictionary).get("ref", "")) == "C1")

	check("the channel was asked about THIS board revision",
		_panel.seen_revision == int(_data.board_revision)
			and _panel.seen_component_count == 3)
	check("a resolved reply states no unavailability",
		not reply.has("physical_placements_unavailable"))


# ── B. what the board authored ───────────────────────────────────────────────

func _run_authored_identity() -> void:
	print("\n-- B. the authored assembly block, verbatim --")
	var comps := _by_ref(await _tools._get_components(_host, {}))
	var socket: Dictionary = (comps.get("U1S", {}) as Dictionary).get("assembly", {})
	var cap: Dictionary = (comps.get("C1", {}) as Dictionary).get("assembly", {})

	check("the socket set's part identity survives",
		str(socket.get("mpn", "")) == "HC-PM254-8.5H-1x22P"
			and str(socket.get("package", "")) == "THT 2.54mm 1x22 socket")
	check("the house catalogue number survives",
		str((socket.get("house_parts", {}) as Dictionary).get("jlcpcb", ""))
			== "C41376161")
	check("the AUTHORED expansion survives beside the resolved one",
		(socket.get("placements", []) as Array).size() == 2
			and float((((socket["placements"] as Array)[0] as Dictionary)
				.get("offset_mm", {}) as Dictionary).get("x", 0.0)) == -11.43)
	check("an ordinary part's manufacturer and package survive",
		str(cap.get("manufacturer", "")) == "YAGEO"
			and str(cap.get("package", "")) == "0805")
	check("a component that authors no block grows no assembly key",
		not (comps.get("R1", {}) as Dictionary).has("assembly"))

	# The reply hands out a COPY: an agent-facing dict that aliased the model
	# would let one reader edit another's board.
	socket["mpn"] = "MUTATED"
	var again := _by_ref(await _tools._get_components(_host, {}))
	check("the reply's assembly block is a copy, not the model's own",
		str(((again.get("U1S", {}) as Dictionary).get("assembly", {}) as Dictionary)
			.get("mpn", "")) == "HC-PM254-8.5H-1x22P")


# ── C. the same two facts on the single-component verb ───────────────────────

func _run_describe_component() -> void:
	print("\n-- C. describe_component says the same thing --")
	var described: Dictionary = await _tools._describe_component(
		_host, {"component_id": "U1S"})
	var listed: Dictionary = _by_ref(await _tools._get_components(_host, {}))

	check("describe_component succeeds on the socket set",
		bool(described.get("success", false)))
	check("its placements are the list verb's, exactly",
		JSON.stringify(described.get("physical_placements", []))
			== JSON.stringify((listed.get("U1S", {}) as Dictionary)
				.get("physical_placements", [])))
	check("its assembly block is the list verb's, exactly",
		JSON.stringify(described.get("assembly", {}))
			== JSON.stringify((listed.get("U1S", {}) as Dictionary)
				.get("assembly", {})))

	var ordinary: Dictionary = await _tools._describe_component(
		_host, {"component_id": "C1"})
	check("an ordinary part describes one placement under its own ref",
		(ordinary.get("physical_placements", []) as Array).size() == 1)


# ── D. no backend: the read still answers, and says why ──────────────────────

func _run_channel_unavailable() -> void:
	print("\n-- D. the channel is down --")
	_panel.reply = {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "plugin IPC channel not ready"}}
	var reply: Dictionary = await _tools._get_components(_host, {})
	var comps := _by_ref(reply)

	check("a read is never blocked by a missing backend",
		bool(reply.get("success", false)) and comps.size() == 3)
	check("no component claims a placement nothing resolved",
		not (comps.get("U1S", {}) as Dictionary).has("physical_placements"))
	check("the reply says why, in the worker's own words",
		str(reply.get("physical_placements_unavailable", ""))
			== "plugin IPC channel not ready")
	check("the AUTHORED identity needs no backend and is still there",
		str(((comps.get("U1S", {}) as Dictionary).get("assembly", {}) as Dictionary)
			.get("mpn", "")) == "HC-PM254-8.5H-1x22P")

	var described: Dictionary = await _tools._describe_component(
		_host, {"component_id": "U1S"})
	check("describe_component states the same unavailability",
		str(described.get("physical_placements_unavailable", ""))
			== "plugin IPC channel not ready")


# ── E. the board itself does not compile ─────────────────────────────────────

func _run_board_does_not_compile() -> void:
	print("\n-- E. the board does not compile --")
	var reason := "component 'X1' footprint 'NoSuchLibrary:NoSuchPart' is not in the library"
	_panel.reply = {"ok": true, "result": {
		"resolved": false, "components": [], "reason": reason}}
	var reply: Dictionary = await _tools._get_components(_host, {})
	var comps := _by_ref(reply)

	check("the compile's own reason reaches the reader",
		str(reply.get("physical_placements_unavailable", "")) == reason)
	check("silence is never an empty placement list",
		not (comps.get("C1", {}) as Dictionary).has("physical_placements"))


# ── F. no live panel at all ──────────────────────────────────────────────────

func _run_no_panel_bound() -> void:
	print("\n-- F. no panel is bound --")
	_host.panel = null
	var reply: Dictionary = await _tools._get_components(_host, {})
	check("a headless read answers, and names the missing backend",
		bool(reply.get("success", false))
			and str(reply.get("physical_placements_unavailable", "")).contains("backend"))
