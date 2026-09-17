extends SceneTree
## pcb's CONTRACT GUARD — six domain-defined cases through the real host chain.
##
## WHY THIS SUITE EXISTS
##
## The host bounds an ordinary scene-panel reply at
## PluginScenePanelBroker.MAX_PAYLOAD_BYTES (64 KiB) in both directions. A
## whole-board pcb.deserialize reply is far past that for any real board, so
## minerva_pcb_load_board came back payload_too_large and the panel stayed
## empty — a total outage on every board anyone actually has, invisible to a
## suite whose worker is a shim, because a stood-in reply is never weighed by
## the host.
##
## This guard weighs the plugin against that contract at BOTH sizes and in both
## moods, because the failures cluster where those two axes cross: the reply
## that carries a document is the big one, and the reply that carries an ERROR
## LIST grows with the document too — a boundary the happy path never reaches.
##
##   1. null / empty document   — an empty document is refused, and never
##                                silently replaces the live board
##   2. small happy             — a two-part board lands whole
##   3. small unhappy           — the codec refuses a malformed document
##   4. large happy             — a 64-part board whose deserialize reply is
##                                OVER the control cap lands whole
##   5. large unhappy           — the same 64-part document, same defect as
##                                case 3, refused with nothing half-applied
##   6. large-with-errors reply — the same 64 parts placed in overlapping
##                                pairs: the health ledger names every pair
##                                and every unrouted net, and that reply is
##                                bigger than the clean board's
##
## pcb's own definition of LARGE is COMPONENT COUNT. 64 parts is the smallest
## round number whose deserialize reply ({board, resolved, warnings}, roughly
## 1.4 KB of resolved geometry per part) clears 64 KiB with room to spare while
## the REQUEST stays well under it — so a failure in case 4 can only be the
## reply direction.
##
## EVERYTHING IS REAL: a real PluginManager, the real PluginScenePanelBroker,
## the real pcb-plugin Go binary and its Python worker, the real PCBPanel.
## Nothing between the assertion and the subprocess is a double.
##
## ORACLE: revert the panel's bulk send seam (PCBPanel._send_request preferring
## MinervaIPC.request_bulk) and case 4 goes red with payload_too_large — the
## deserialize reply no longer fits the control lane — while cases 1, 2, 3 and
## 5 stay green, because their documents and refusals are small. Case 6 goes
## red with it, one hop later: its ledger request carries the whole board.
##
## THE UNHAPPY CASES are refused by the plugin's own codec (an unsupported
## schema version), the SAME defect at both sizes, so size is the only variable
## between case 3 and case 5.
##
## THE LIVE BOARD IS THE STATE PROBE, and the cases run in an order that gives
## that probe teeth: each unhappy case is weighed against the board the previous
## happy case left standing. "No partial state" and "no silent empty document"
## mean nothing measured against an empty panel.
##
## SKIP CONTRACT: with the Go binary unbuilt the live sections do not run and
## the suite says so loudly. Its assertion pin therefore describes a host that
## has built the plugin and installed it.
##
## Run: scripts/run-gd-tests.sh --plugin pcb <path-to-minerva-checkout>

const ContractGuard := preload("res://../../minerva-plugins/scripts/contract_guard.gd")

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const SCENE_PANEL_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"

const PCB_PLUGIN_DIR_REL := "/github/minerva-plugins/pcb"
const PCB_BINARY_REL := "/pcb-plugin"
const PCB_MANIFEST_REL := "/manifest.json"

## PluginDefinition.State values the setup pipeline passes through.
const S_RUNNING := 2
const S_BUILDING := 6
const S_BUILD_FAILED := 7

## The channels the six cases ride. The broker refuses any channel the
## INSTALLED definition does not declare, so a stale install would fail every
## live case with an opaque permission_denied; the mount names that drift.
const GUARD_CHANNELS := ["pcb.deserialize", "pcb.board_health"]

## pcb's unit of large, and the count both large moods share.
const LARGE_COMPONENTS := 64
const SMALL_COMPONENTS := 2

## A schema version this codec supports (v1 migrates its persistent ids at the
## deserialize boundary) and one it cannot, which is how the unhappy documents
## are refused: board.Validate answers unsupported_schema_version.
const VERSION_SUPPORTED := 1
const VERSION_REFUSED := 3

## Diode_SMD:D_SMA, the seed library's own geometry: pads 2.2 x 1.7 at
## (+/-2.05, 0), courtyard (-3.7,-1.8)...(3.7,1.8). A pair 6.9 mm apart on x
## overlaps by 0.5 mm of COURTYARD while its nearest pads stay 0.6 mm clear —
## the assembly-advisory finding class, reached without inventing a copper
## short that a different check would answer first.
const PAIR_PITCH_MM := 6.9
const GRID_PITCH_MM := 20.0
const PAIRS_PER_ROW := 10
const PARTS_PER_ROW := 20
const BOARD_SPAN_MM := 420.0

## The verb surface refuses with a message and no machine code — its codes live
## on the transport envelope, which every unhappy case asserts separately. An
## empty key list is how a surface declares that, and the Results line names it.
const NO_CODES: Array[String] = []

const DESERIALIZE_TIMEOUT_MS := 30000
const HEALTH_TIMEOUT_MS := 60000

var guard := ContractGuard.new()
var _pm: Node = null
var _broker: Object = null
var _panel: Node = null
var _data = null
## The clean large board's ledger size, case 6's baseline.
var _clean_health_bytes := -1


## _on_panel_loaded's ctx only ever reads tab_title off the editor.
class FakeEditor extends RefCounted:
	var tab_title: String = "ContractGuardProbe"
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB contract guard — six cases through the real host chain ===\n")
	await process_frame

	var home: String = OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	var plugin_dir: String = OS.get_environment("MINERVA_PCB_PLUGIN_DIR")
	if plugin_dir == "" and home != "":
		plugin_dir = home + PCB_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + PCB_BINARY_REL
	if not FileAccess.file_exists(binary_path) and FileAccess.file_exists(binary_path + ".exe"):
		binary_path += ".exe"

	if plugin_dir == "" or not FileAccess.file_exists(binary_path):
		print("SKIP: pcb-plugin binary not built at '%s'." % binary_path)
		print("      Build with: cd %s && go build -o pcb-plugin ." % plugin_dir)
	else:
		var mounted: bool = await _mount(plugin_dir + PCB_MANIFEST_REL)
		if mounted:
			# Order matters: every unhappy case is measured against the board
			# the happy case before it left standing (see the class doc).
			await _case_small_happy()
			await _case_null_document()
			await _case_small_unhappy()
			await _case_large_happy()
			await _case_large_unhappy()
			await _case_large_error_reply()
		else:
			printerr("SETUP FAILED — the real chain did not mount; cases not run")
		await _teardown()

	quit(guard.results())


# ---------------------------------------------------------------------------
# Mount — real PluginManager + real broker + real panel, production order
# ---------------------------------------------------------------------------

## Install-if-absent, refresh a stale install, start, register, load — the
## lifecycle suite's idiom. Only POST-CONDITIONS assert: the conditional repair
## paths print. A pin that counted assertions taken on a branch would drift with
## the host's install state rather than with this suite's contract.
func _mount(manifest_path: String) -> bool:
	var pm_script: Script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("  PluginManager.gd did not load")
		return false
	_pm = pm_script.new()
	root.add_child(_pm)
	await process_frame
	if not guard.check("setup: the plugin manager initialised its database", _pm._db != null):
		return false

	var def = _pm._db.get_by_id("pcb")
	# The plugin DB persists the definition at INSTALL time and neither reload
	# nor restart re-scans the manifest, so an install predating a channel this
	# guard rides would have the broker deny it by allowlist. Refresh through
	# the manager's own API so the assertions describe the manifest standing now.
	if def != null and not _declares_every_channel(def):
		print("  installed definition predates the manifest's channel list — "
				+ "refreshing via remove_plugin + install_plugin")
		if def.state == S_RUNNING:
			await _pm.stop_plugin("pcb")
		await _pm.remove_plugin("pcb", false)
		def = null
	if def == null:
		print("  installing the plugin from %s" % manifest_path)
		await _pm.install_plugin(manifest_path, true)
		def = _pm._db.get_by_id("pcb")
		# The manifest carries a `setup` stanza, so install runs go_build +
		# python_venv on a worker thread. Wait it out: the build rewrites the
		# very binary start_plugin would exec, and a pipeline still running at
		# process exit crashes engine teardown.
		if def != null and def.state == S_BUILDING:
			print("  setup pipeline building (go_build + python_venv) — waiting...")
			var deadline_ms: int = Time.get_ticks_msec() + 900000
			while def.state == S_BUILDING and Time.get_ticks_msec() < deadline_ms:
				await create_timer(0.5).timeout
			if def.state == S_BUILDING or def.state == S_BUILD_FAILED:
				printerr("  setup pipeline did not land (state=%d)" % def.state)
	if def == null:
		printerr("  the pcb definition never reached the plugin database")
		return false
	if not guard.check("setup: the installed definition declares every channel this "
			+ "guard rides", _declares_every_channel(def),
			"installed ui_ipc_messages=%s" % str(def.ui_ipc_messages)):
		return false

	if def.state == S_RUNNING:
		await _pm.stop_plugin("pcb")
	var start_result: Dictionary = await _pm.start_plugin("pcb")
	if not guard.check("setup: the backend starts", bool(start_result.get("ok", false)),
			str(start_result)):
		return false

	# Policy, capability broker and audit log stay null: backend-channel
	# dispatch consults none of them, and _audit guards a null log itself.
	var broker_script: Script = load(SCENE_PANEL_BROKER_SCRIPT_PATH)
	if broker_script == null:
		printerr("  PluginScenePanelBroker.gd did not load")
		return false
	_broker = broker_script.new(_pm, null, null, null)

	# Declared channels come from the live definition — the same source
	# production registration reads — never re-typed here.
	var declared := PackedStringArray()
	for p in def.ui_panels:
		if p is Dictionary and str((p as Dictionary).get("name", "")) == "pcb_panel":
			for ch in (p as Dictionary).get("ipc_channels", []):
				declared.append(str(ch))
			break

	_panel = load(PANEL_PATH).new()
	if _panel == null:
		printerr("  PCBPanel did not instantiate")
		return false
	root.add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.size = Vector2(900, 700)

	# Register before the load hook, the order PluginScenePanelHost guarantees:
	# registration is what attaches the MinervaIPC helper the panel sends on.
	_broker.register_panel(_panel, "pcb", "pcb_panel", declared)
	_panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})

	var ipc: Node = _panel.get_node_or_null("_MinervaIPC")
	if not guard.check("setup: the host offers the bulk route the large cases ride",
			ipc != null and ipc.has_method("request_bulk"), "helper=%s" % str(ipc)):
		return false
	_data = _panel.get_data()
	if not guard.check("setup: the panel exposes live board data", _data != null):
		return false
	for _i in range(4):
		await process_frame
	return true


func _declares_every_channel(def) -> bool:
	for ch in GUARD_CHANNELS:
		if not (ch in def.ui_ipc_messages):
			return false
	return true


# ---------------------------------------------------------------------------
# Case 2 — small happy (runs first: it is the state every refusal is weighed
# against)
# ---------------------------------------------------------------------------

func _case_small_happy() -> void:
	print("\n-- small happy: a two-part board lands whole --")
	var yaml_text := _board_yaml(SMALL_COMPONENTS, false, VERSION_SUPPORTED, "guard-small")
	var expected := _count_component_refs(yaml_text)
	var reply: Dictionary = await _panel.handle_tool(
			"minerva_pcb_load_board", {"yaml": yaml_text})
	guard.expect_success("small-happy", reply)
	guard.check_eq("small-happy: component_count equals the fixture's own ref count",
			int(reply.get("component_count", -1)), expected)
	guard.expect_document("small-happy", "the live board's component count",
			_data.get_component_count())


# ---------------------------------------------------------------------------
# Case 1 — null / empty document
# ---------------------------------------------------------------------------

## Two shapes of nothing: a document that is only whitespace (which reaches the
## codec, and must be refused there rather than parsed into an empty board) and
## an absent one (which the verb refuses before any wire crossing). Either way
## the board standing from the small-happy case must be untouched: the failure
## this forbids is a blank panel reported as a successful load.
func _case_null_document() -> void:
	print("\n-- null/empty document: nothing in is a refusal, never a blank board --")
	var envelope: Dictionary = await _panel._request_with_backend_ensure(
			"pcb.deserialize", {"yaml": "   \n"}, DESERIALIZE_TIMEOUT_MS)
	guard.expect_refusal("null-document", envelope)

	# The public verb's refusals carry a message and no machine code — the code
	# lives on the transport envelope above. Asserted for shape only, and
	# declared as such on the Results line.
	var reply: Dictionary = await _panel.handle_tool("minerva_pcb_load_board", {"yaml": ""})
	guard.expect_refusal("null-document(verb)", reply, NO_CODES)

	guard.expect_unchanged("null-document", "the live board's component count",
			_data.get_component_count(), SMALL_COMPONENTS)


# ---------------------------------------------------------------------------
# Case 3 — small unhappy
# ---------------------------------------------------------------------------

func _case_small_unhappy() -> void:
	print("\n-- small unhappy: the codec refuses a malformed two-part board --")
	var yaml_text := _board_yaml(SMALL_COMPONENTS, false, VERSION_REFUSED, "guard-small-bad")
	var envelope: Dictionary = await _panel._request_with_backend_ensure(
			"pcb.deserialize", {"yaml": yaml_text}, DESERIALIZE_TIMEOUT_MS)
	guard.expect_refusal("small-unhappy", envelope)

	var reply: Dictionary = await _panel.handle_tool(
			"minerva_pcb_load_board", {"yaml": yaml_text})
	guard.expect_refusal("small-unhappy(verb)", reply, NO_CODES)

	guard.expect_unchanged("small-unhappy", "the live board's component count",
			_data.get_component_count(), SMALL_COMPONENTS)


# ---------------------------------------------------------------------------
# Case 4 — large happy (the oracle case)
# ---------------------------------------------------------------------------

## The raw round trip runs first so the reply can be weighed before anything
## unwraps it — same broker, same backend, same channel the public verb below
## rides. Then the verb, whose reply is the exact dict an MCP caller sees.
func _case_large_happy() -> void:
	print("\n-- large happy: a 64-part board whose reply is over the control cap --")
	var yaml_text := _board_yaml(LARGE_COMPONENTS, false, VERSION_SUPPORTED, "guard-large")
	var expected := _count_component_refs(yaml_text)
	var cap: int = load(SCENE_PANEL_BROKER_SCRIPT_PATH).MAX_PAYLOAD_BYTES
	var request := {"yaml": yaml_text}

	var envelope: Dictionary = await _panel._request_with_backend_ensure(
			"pcb.deserialize", request, DESERIALIZE_TIMEOUT_MS)
	var weighed: Dictionary = guard.weigh("large-happy", request, envelope,
			"control cap %d B" % cap)
	guard.check("large-happy: the request is under the control cap — the reply is "
			+ "what is on trial", int(weighed["request_bytes"]) < cap,
			"request=%d cap=%d" % [int(weighed["request_bytes"]), cap])
	guard.check("large-happy: the reply really is over the control cap",
			int(weighed["reply_bytes"]) > cap,
			"reply=%d cap=%d" % [int(weighed["reply_bytes"]), cap])
	guard.expect_not_oversize_refusal("large-happy", envelope)

	var reply: Dictionary = await _panel.handle_tool(
			"minerva_pcb_load_board", {"yaml": yaml_text})
	guard.expect_success("large-happy(verb)", reply)
	guard.check_eq("large-happy: component_count equals the fixture's own ref count",
			int(reply.get("component_count", -1)), expected)
	guard.expect_document("large-happy", "the live board's component count",
			_data.get_component_count())

	# The clean board's health ledger — case 6's baseline, weighed the same way
	# so the two numbers come from one derivation.
	var health: Dictionary = await _weigh_health("large-happy(health)")
	guard.expect_success("large-happy(health)", health.get("envelope", {}))
	_clean_health_bytes = guard.reply_bytes("large-happy(health)")


# ---------------------------------------------------------------------------
# Case 5 — large unhappy
# ---------------------------------------------------------------------------

## The same defect as case 3 at the large size, so size is the only variable:
## a big refusal must be as structured, and as free of half-applied state, as a
## small one.
func _case_large_unhappy() -> void:
	print("\n-- large unhappy: a 64-part board the codec refuses, applying nothing --")
	var yaml_text := _board_yaml(LARGE_COMPONENTS, false, VERSION_REFUSED, "guard-large-bad")
	var request := {"yaml": yaml_text}
	var envelope: Dictionary = await _panel._request_with_backend_ensure(
			"pcb.deserialize", request, DESERIALIZE_TIMEOUT_MS)
	guard.weigh("large-unhappy", request, envelope)
	guard.expect_refusal("large-unhappy", envelope)

	var reply: Dictionary = await _panel.handle_tool(
			"minerva_pcb_load_board", {"yaml": yaml_text})
	guard.expect_refusal("large-unhappy(verb)", reply, NO_CODES)

	guard.expect_unchanged("large-unhappy", "the live board's component count",
			_data.get_component_count(), LARGE_COMPONENTS)
	guard.expect_unchanged("large-unhappy", "the live board's name",
			str(_data.board_name), "guard-large")


# ---------------------------------------------------------------------------
# Case 6 — the large-with-errors reply
# ---------------------------------------------------------------------------

## The finding list is what grows here, not the document: 64 parts placed as 32
## courtyard-overlapping pairs on 32 nets with no copper, so the whole-board
## health ledger answers with a finding per pair and an unrouted net per pair.
## That reply crosses the same host boundary the happy reply does, one hop
## later, and is the BIGGER of the two — which is why an unhappy path can break
## on a size a green happy path already proved.
func _case_large_error_reply() -> void:
	print("\n-- large-with-errors reply: the ledger for 32 overlapping pairs --")
	var yaml_text := _board_yaml(LARGE_COMPONENTS, true, VERSION_SUPPORTED, "guard-large-bad-pairs")
	var load_reply: Dictionary = await _panel.handle_tool(
			"minerva_pcb_load_board", {"yaml": yaml_text})
	guard.expect_success("large-errors(load)", load_reply)

	var weighed: Dictionary = await _weigh_health("large-errors")
	var envelope: Dictionary = weighed.get("envelope", {})
	guard.expect_not_oversize_refusal("large-errors", envelope)
	# Before anything is read off it: a dead connection answers every question
	# the same way, and the findings assertions below would then fail for a
	# reason that has nothing to do with the ledger.
	guard.expect_live_backend("large-errors", envelope)
	guard.expect_success("large-errors", envelope)

	var health: Dictionary = _unwrap_to(envelope, "assembly")
	var assembly: Dictionary = health.get("assembly", {}) if health.get("assembly") is Dictionary else {}
	var findings: Array = assembly.get("findings", [])
	var missing: Array = health.get("missing_copper", [])
	var pairs := LARGE_COMPONENTS / 2

	var unnamed: Array = []
	for pair in range(pairs):
		var refs := ["D%d" % (pair * 2 + 1), "D%d" % (pair * 2 + 2)]
		if _finding_naming(findings, refs).is_empty():
			unnamed.append(refs)
	guard.check("large-errors: every overlapping pair is named in the findings "
			+ "(%d findings for %d pairs)" % [findings.size(), pairs],
			unnamed.is_empty(), "unnamed pairs: %s" % str(unnamed).left(300))

	var absent: Array = []
	for pair in range(pairs):
		if not (_net_name(pair) in missing):
			absent.append(_net_name(pair))
	guard.check("large-errors: the census names every zero-copper net "
			+ "(%d named for %d nets)" % [missing.size(), pairs],
			absent.is_empty(), "absent: %s" % str(absent).left(300))

	# The point of the case, in one number: the same board, same call, same
	# component count — only the errors differ.
	var error_bytes := guard.reply_bytes("large-errors")
	guard.check("large-errors: the error-bearing ledger is the BIGGER reply "
			+ "(%d B vs %d B clean)" % [error_bytes, _clean_health_bytes],
			error_bytes > _clean_health_bytes and _clean_health_bytes > 0)


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

func _teardown() -> void:
	if _broker != null and _panel != null:
		_broker.unregister_panel("pcb", "pcb_panel")
	if _panel != null and is_instance_valid(_panel):
		_panel._on_panel_unload()
		_panel.queue_free()
		_panel = null
		await process_frame
	if _pm != null:
		var stop_result: Dictionary = await _pm.stop_plugin("pcb")
		guard.check("teardown: the backend stops", bool(stop_result.get("ok", false)),
				str(stop_result))
	AnnotationHostRegistry._reset_for_test()


# ---------------------------------------------------------------------------
# Fixtures — generated here, nothing read from outside the repo
# ---------------------------------------------------------------------------

## ONE builder for all six documents, so the only differences between cases are
## the ones the case is about: how many parts, whether each pair's courtyards
## overlap, and which schema version the document claims.
##
## Clean layout: a 20 mm grid, every courtyard clear of its neighbours.
## Overlapping layout: pairs 6.9 mm apart (0.5 mm of courtyard overlap, pads
## still 0.6 mm clear), pairs themselves 40 mm apart so no finding can come
## from anything but the pair it names.
func _board_yaml(count: int, overlapping_pairs: bool, version: int, name: String) -> String:
	var out := ("version: %d\n" % version) \
		+ ("name: %s\n" % name) \
		+ ("width_mm: %.1f\nheight_mm: %.1f\n" % [BOARD_SPAN_MM, BOARD_SPAN_MM]) \
		+ "layers: [top, bottom]\n" \
		+ "design_rules:\n" \
		+ "  clearance_mm: 0.2\n" \
		+ "  trace_width_mm: 0.25\n" \
		+ "  via_diameter_mm: 0.8\n" \
		+ "  via_drill_mm: 0.4\n" \
		+ "components:\n"
	for i in range(count):
		var x := 0.0
		var y := 0.0
		if overlapping_pairs:
			var pair: int = i / 2
			x = 10.0 + float(pair % PAIRS_PER_ROW) * (GRID_PITCH_MM * 2.0) \
				+ float(i % 2) * PAIR_PITCH_MM
			y = 10.0 + floor(float(pair) / float(PAIRS_PER_ROW)) * GRID_PITCH_MM
		else:
			x = 10.0 + float(i % PARTS_PER_ROW) * GRID_PITCH_MM
			y = 10.0 + floor(float(i) / float(PARTS_PER_ROW)) * GRID_PITCH_MM
		out += ("  - ref: D%d\n" % (i + 1)) \
			+ "    footprint: Diode_SMD:D_SMA\n" \
			+ ("    x_mm: %.2f\n" % x) \
			+ ("    y_mm: %.2f\n" % y) \
			+ "    rotation_deg: 0\n" \
			+ "    layer: top\n" \
			+ "    pins:\n" \
			+ '      - {number: "1", x_mm: -2.05, y_mm: 0.0, pad_width_mm: 2.2, pad_height_mm: 1.7}\n' \
			+ '      - {number: "2", x_mm: 2.05, y_mm: 0.0, pad_width_mm: 2.2, pad_height_mm: 1.7}\n'
	out += "nets:\n"
	if overlapping_pairs:
		# One net per pair, all of them without copper — so the completeness
		# census grows with the board exactly as the finding list does.
		for pair in range(count / 2):
			out += ("  - name: %s\n" % _net_name(pair)) \
				+ ("    pins: [D%d.1, D%d.2]\n" % [pair * 2 + 1, pair * 2 + 2])
	else:
		out += "  - name: N_CHAIN\n    pins: [D1.2, D2.1]\n"
	return out


func _net_name(pair: int) -> String:
	return "N_PAIR%d" % pair


## Count the components by reading the fixture TEXT, independently of the loop
## that wrote it — the number a load must agree with.
func _count_component_refs(yaml_text: String) -> int:
	var n := 0
	for line in yaml_text.split("\n"):
		if line.begins_with("  - ref: "):
			n += 1
	return n


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## One weighed pcb.board_health round trip over the board standing right now,
## sent exactly as the panel sends it — including the by-reference swap a board
## past the snapshot limit takes, which is why the measured request can be a
## handle rather than the document.
func _weigh_health(case_name: String) -> Dictionary:
	var board: Dictionary = _data.to_board_dict()
	var payload: Dictionary = _panel._payload_by_ref({"board": board}, "board")
	var by_ref: bool = not payload.has("board")
	var envelope: Dictionary = await _panel._request_with_backend_ensure(
			"pcb.board_health", payload, HEALTH_TIMEOUT_MS)
	var note := "board document %d B" % ContractGuard.bytes_of({"board": board})
	if by_ref:
		note += ", request sent by reference"
	guard.weigh(case_name, payload, envelope, note)
	return {"envelope": envelope, "board": board}


## Walk the broker/worker envelopes ({success|ok, result:{...}}) down to the
## dict that directly carries `key`. {} when none does.
func _unwrap_to(value: Variant, key: String) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var d: Dictionary = value
	if d.has(key):
		return d
	if d.get("result", null) is Dictionary:
		return _unwrap_to(d["result"], key)
	return {}


## The first finding whose components list contains every ref in `refs`.
func _finding_naming(findings: Array, refs: Array) -> Dictionary:
	for f in findings:
		if not (f is Dictionary):
			continue
		var comps: Array = (f as Dictionary).get("components", [])
		var all_present := true
		for r in refs:
			if not (str(r) in comps):
				all_present = false
				break
		if all_present:
			return f
	return {}
