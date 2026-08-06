extends SceneTree
## PRODUCTION-PATH seam integration test (work item 019fd5fe4127 — the
## capstone of DCR 019fd5fd9084).
##
## WHY THIS SUITE EXISTS (docs/llm-ergonomics.md): every seam failure this
## cycle lived BETWEEN test suites that each tested against a double of the
## other side —
##   * F0: PCBPanel.route_board's allow-list dropped task_constraints while
##     panel_tools was green against RouterShim and route_bridge was green
##     against pytest fixtures — the function in the middle was the only
##     untested code, and it was the production path.
##   * the Go deserialize once dropped worker advisories the same way;
##   * the UI renderer read only `clean` while the worker said more;
##   * the commit acknowledgment policy gates on a cache no unit suite feeds
##     the way production feeds it.
## This fixture closes the CLASS, not the instances: it drives the REAL
## plugin backend (the pcb-plugin Go binary + its Python worker subprocess)
## through the REAL panel dispatch chain —
##
##   PanelTools.handle → PCBPanel (route_board / load_board_from_yaml /
##   assembly_check) → panel `request` signal → PluginScenePanelBroker.
##   handle_scene_request (manifest-validated, the production broker class
##   with a REAL PluginManager) → MCPServerConnection tools/call over STDIO
##   → Go dispatch → Python worker — and back through MinervaIPC._reply.
##
## NOTHING in the middle is a shim, and every assertion is on the PUBLIC
## panel reply only (the exact dict an MCP caller sees) — so a regression in
## ANY hop of that chain fails here, structurally unlike the doubled suites.
##
## SETUP/TEARDOWN mirrors test_pcb_backend_lifecycle.gd Section C exactly
## (fresh PluginManager, install-if-absent, stop-if-running, start, stop at
## the end) plus test_pcb_plugin_smoke.gd's binary-gated SKIP contract: when
## the Go binary is not built on this host, the live sections skip loudly and
## only Section 0's manifest assertions run (they are real seam assertions —
## the channel declarations the whole chain depends on — not padding).
##
## THE FIXTURE BOARD (synthesized here — geometry copied from the SEED
## LIBRARY's own footprints, no external board referenced):
##   * D1 (Diode_SMD:D_SMA) and J1 (Connector_JST JST_PH horizontal) placed
##     3.58 mm apart at rot 90 — their COURTYARDS overlap (a ~0.07 × 6.15 mm
##     sliver), the assembly-advisory class of finding that the pad_extent
##     fallback can NEVER catch (the JST housing reaches ~4.5 mm past its
##     pads), so a "findings" verdict here PROVES the tolerant resolve
##     attached real library courtyards through the real chain.
##   * net N_SPAN connects D1.2 ↔ J1.1 — the span we author an intent on.
##   * D2 (a second D_SMA, far away) + net N_EMPTY (D2.1 ↔ D2.2) with ZERO
##     traces — the zero-copper net the whole-board health ledger must name
##     even on a span-scoped propose (llm-ergonomics F2).
##   * no zones (avoids the routing fail-closed keepout path).
##
## THE SCENARIO (one linear pass, public replies only):
##   1. load the YAML via minerva_pcb_load_board → the reply's `assembly`
##      tri-state is "findings" naming D1+J1 on a courtyard basis (this is
##      panel → Go pcb.deserialize + resolve enrichment → Go
##      pcb.assembly_check → Python worker, end-to-end — the seam the Go
##      deserialize used to drop).
##   2. author a route intent on N_SPAN with a corridor
##      (minerva_pcb_add_route_intent), then propose span-scoped via the
##      REAL worker (minerva_pcb_workspace_propose hint_ids:[hint]) → a
##      candidate lands AND board_health names N_EMPTY in missing_copper
##      AND board_health.assembly.status == "findings" AND the candidate
##      carries constraint_revision + hint_status — THE F0 ASSERTION: the
##      task_constraints corridor must survive the real
##      PCBPanel.route_board hop, which was structurally impossible to
##      assert before this suite.
##   3. commit WITHOUT acknowledge_placement → refused
##      "placement_blocker_unacknowledged" + blocking_findings naming the
##      D1/J1 pair + NO copper written.
##   4. commit WITH acknowledge_placement:true → success +
##      acknowledged_placement_findings recorded + copper written.
##   5. teardown per the lifecycle suite's idiom.
##
## Off-tree: every plugin script is loaded by path and duck-typed (never
## typed AS a plugin class); core class_names (MinervaIPC,
## AnnotationHostRegistry) resolve because this runs inside the Minerva
## host project, same as every other suite in this directory.
##
## Run: godot --headless --path src --script \
##   res://../../minerva-plugins/pcb/tests/gd/test_production_seam.gd
## Or via the whole-suite runner: pcb/scripts/run-gd-tests.sh <minerva-checkout>

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const MANIFEST_RES_PATH := "res://../../minerva-plugins/pcb/manifest.json"
const PLUGIN_DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const SCENE_PANEL_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"

const PCB_PLUGIN_DIR_REL := "/github/minerva-plugins/pcb"
const PCB_BINARY_REL := "/pcb-plugin"
const PCB_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_BUILDING := 6       # PluginManager's setup-pipeline extension states
const S_BUILD_FAILED := 7

## The three backend channels this scenario's chain rides. Section 0 pins
## their manifest declaration — the broker refuses any undeclared channel, so
## a manifest drift here would fail the LIVE sections with an opaque
## permission_denied; these assertions name the drift instead.
const PRODUCTION_CHANNELS := ["pcb.deserialize", "pcb.route", "pcb.assembly_check"]

## The fixture board (see the class doc). Pin offsets and courtyard extents
## are the seed library's own (library/footprints/Diode_SMD.pretty/D_SMA
## .kicad_mod and Connector_JST.pretty/JST_PH_S2B-PH-K_1x02_P2.00mm_
## Horizontal.kicad_mod — same numbers the worker's assembly_advisory pytest
## pins): D_SMA pads 2.2×1.7 at (±2.05, 0), courtyard (−3.7,−1.8)…(3.7,1.8);
## JST_PH TH pads 1.2×1.75 drill 0.75 at (0,0)/(2,0), courtyard
## (−2.45,−1.85)…(4.45,6.75). Under rot 90 (KiCad CW: (x,y)→(y,−x)):
## D1 courtyard X[18.2,21.8] Y[9.0,16.4]; J1 courtyard X[21.73,30.33]
## Y[8.25,15.15] → a 0.07 mm wide overlap sliver. Span endpoints land at
## D1.2 world (20.0, 10.65) and J1.1 world (23.58, 12.7) — ~4.1 mm apart,
## comfortably routable on `top` (clearance 0.2, width 0.25).
const BOARD_YAML := """version: 1
name: seam-probe
width_mm: 50
height_mm: 30
layers: [top, bottom]
design_rules:
  clearance_mm: 0.2
  trace_width_mm: 0.25
  via_diameter_mm: 0.8
  via_drill_mm: 0.4
components:
  - ref: D1
    footprint: Diode_SMD:D_SMA
    x_mm: 20.0
    y_mm: 12.7
    rotation_deg: 90
    layer: top
    pins:
      - {number: "1", x_mm: -2.05, y_mm: 0.0, pad_width_mm: 2.2, pad_height_mm: 1.7}
      - {number: "2", x_mm: 2.05, y_mm: 0.0, pad_width_mm: 2.2, pad_height_mm: 1.7}
  - ref: J1
    footprint: Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal
    x_mm: 23.58
    y_mm: 12.7
    rotation_deg: 90
    layer: top
    pins:
      - {number: "1", x_mm: 0.0, y_mm: 0.0, drill_mm: 0.75, pad_width_mm: 1.2, pad_height_mm: 1.75}
      - {number: "2", x_mm: 2.0, y_mm: 0.0, drill_mm: 0.75, pad_width_mm: 1.2, pad_height_mm: 1.75}
  - ref: D2
    footprint: Diode_SMD:D_SMA
    x_mm: 40.0
    y_mm: 22.0
    rotation_deg: 0
    layer: top
    pins:
      - {number: "1", x_mm: -2.05, y_mm: 0.0, pad_width_mm: 2.2, pad_height_mm: 1.7}
      - {number: "2", x_mm: 2.05, y_mm: 0.0, pad_width_mm: 2.2, pad_height_mm: 1.7}
nets:
  - name: N_SPAN
    pins: [D1.2, J1.1]
  - name: N_EMPTY
    pins: [D2.1, D2.2]
"""

var _pass := 0
var _fail := 0

var _pm = null            # PluginManager (real, fresh — lifecycle Section C idiom)
var _broker = null        # PluginScenePanelBroker (real, wired to _pm)
var panel = null          # PCBPanel (real, mounted)
var data = null           # the panel's live PCBData
var _hint_id := ""        # the N_SPAN route intent's annotation id
var _candidate_id := ""   # the landed candidate under commit-gate test


## Minimal editor stand-in for _on_panel_loaded's ctx (same shape
## test_pcb_explicit_propose.gd mounts with — the panel only reads tab_title).
class FakeEditor extends RefCounted:
	var tab_title: String = "ProductionSeamProbe"
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB production-path seam test (work item 019fd5fe4127 / DCR 019fd5fd9084) ===\n")
	await process_frame

	print("########## SECTION 0 — manifest declares the production channels ##########\n")
	_test_manifest_declares_production_channels()

	print("\n########## SECTIONS 1-4 — the live chain (real Go binary + Python worker) ##########\n")
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
		print("      (Go toolchain absent on this host — live sections not exercised.)")
		print("      Build with: cd %s && go build -o pcb-plugin ." % plugin_dir)
	else:
		var mounted: bool = await _mount_production_chain(plugin_dir + PCB_MANIFEST_REL)
		if mounted:
			await _step_1_load_carries_assembly_findings()
			await _step_2_span_propose_full_contract()
			await _step_3_commit_refused_unacknowledged()
			await _step_4_commit_acknowledged_lays_copper()
		else:
			printerr("SETUP FAILED — production chain did not mount; live steps not run")
		await _teardown()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ──────────────────────────────────────────────────────────────────────────────
# Section 0 — manifest wiring (runs unconditionally; real seam assertions)
# ──────────────────────────────────────────────────────────────────────────────

func _test_manifest_declares_production_channels() -> void:
	print("-- manifest.json declares every channel the production chain rides --")
	var f := FileAccess.open(MANIFEST_RES_PATH, FileAccess.READ)
	check("manifest.json opens", f != null)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	check("manifest.json parses", parsed is Dictionary)
	if not (parsed is Dictionary):
		return
	var ui: Dictionary = (parsed as Dictionary).get("ui", {})
	var ipc_messages: Array = ui.get("ipc_messages", [])
	var panel_channels: Array = []
	for p in ui.get("panels", []):
		if p is Dictionary and str((p as Dictionary).get("name", "")) == "pcb_panel":
			panel_channels = (p as Dictionary).get("ipc_channels", [])
			break
	check("pcb_panel entry found in ui.panels", not panel_channels.is_empty())
	for ch in PRODUCTION_CHANNELS:
		check("ui.ipc_messages declares '%s'" % ch, ch in ipc_messages)
		check("pcb_panel.ipc_channels declares '%s'" % ch, ch in panel_channels)


# ──────────────────────────────────────────────────────────────────────────────
# Mount — real PluginManager + real PluginScenePanelBroker + real PCBPanel
# ──────────────────────────────────────────────────────────────────────────────

## Start the REAL backend and mount a REAL panel wired through the REAL broker
## class. Mirrors test_pcb_backend_lifecycle.gd Section C for the subprocess
## half (fresh PluginManager, install-if-absent, stop-if-running, start) and
## PluginScenePanelHost's production order for the panel half: broker.
## register_panel BEFORE _on_panel_loaded (§5.3 trampoline), panel registered
## under its MANIFEST name "pcb_panel" (the broker validates panel_name
## against def.ui_panel_names) with the manifest's own declared channels.
func _mount_production_chain(manifest_path: String) -> bool:
	# ── backend subprocess (lifecycle Section C idiom, verbatim) ──────────────
	var def_script: Script = load(PLUGIN_DEFINITION_SCRIPT_PATH)
	check("PluginDefinition script loads", def_script != null)
	if def_script == null:
		return false

	var pm_script: Script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	check("PluginManager.gd loads", pm_script != null)
	if pm_script == null:
		return false
	_pm = pm_script.new()
	root.add_child(_pm)
	await process_frame
	check("PluginManager initialised", _pm._db != null)
	if _pm._db == null:
		return false

	var def = _pm._db.get_by_id("pcb")
	# STALE-INSTALL REFRESH (found live by this suite's first run): the plugin
	# DB persists the definition at install time and NEITHER reload NOR restart
	# re-scans the manifest (documented remove+install contract, docket note
	# "plugin new tool requires reinstall"). A definition installed before the
	# manifest gained pcb.assembly_check makes the broker deny that channel by
	# allowlist — the load-time assembly tri-state then degrades to
	# {status:"indeterminate", error:"Permission denied"} while pcb.route still
	# works, which is EXACTLY the doubled-suite blind spot this fixture exists
	# to close. Refresh through the manager's own public API so the test
	# asserts the current manifest's contract, not a fossil record's.
	if def != null:
		var stale := false
		for ch in PRODUCTION_CHANNELS:
			if not (ch in def.ui_ipc_messages):
				stale = true
				break
		if stale:
			print("  [production-seam] installed pcb definition predates the current "
					+ "manifest's channel list — refreshing via remove_plugin + install_plugin")
			if def.state == S_RUNNING:
				await _pm.stop_plugin("pcb")
			var remove_result: Dictionary = await _pm.remove_plugin("pcb", false)
			check("stale install removed cleanly", remove_result.get("ok", false) == true,
					"got: %s" % str(remove_result))
			def = null
	if def == null:
		var install_result: Dictionary = await _pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = _pm._db.get_by_id("pcb")
		# The pcb manifest carries a `setup` stanza, so install kicks off the
		# ALWAYS-BUILD pipeline (go_build + python_venv) on a worker thread and
		# leaves def.state == S_BUILDING until it lands. Wait it out before
		# starting: (a) go_build rewrites the very binary start_plugin would
		# exec, and (b) a pipeline still running when this headless process
		# exits crashes engine teardown (observed live: SetupExecutors
		# is_process_running on a freed handle → recursive_mutex abort → the
		# runner reads a non-zero exit despite a green Results line).
		if def != null and def.state == S_BUILDING:
			print("  [production-seam] setup pipeline building (go_build + python_venv) — waiting…")
			var deadline_ms: int = Time.get_ticks_msec() + 900_000
			while def.state == S_BUILDING and Time.get_ticks_msec() < deadline_ms:
				await create_timer(0.5).timeout
			check("setup pipeline finished (state left BUILDING)", def.state != S_BUILDING,
					"still BUILDING after 900s")
			check("setup pipeline did not fail the build", def.state != S_BUILD_FAILED,
					"state=%d (S_BUILD_FAILED)" % def.state)
	check("PCB definition loaded into DB", def != null)
	if def == null:
		return false
	# The INSTALLED definition (what the broker actually validates against —
	# not the on-disk manifest Section 0 read) must declare every production
	# channel. This is the assertion that catches the stale-install seam by
	# name instead of as a downstream "Permission denied".
	for ch in PRODUCTION_CHANNELS:
		check("installed definition declares '%s'" % ch, ch in def.ui_ipc_messages,
				"installed ui_ipc_messages=%s" % str(def.ui_ipc_messages))
	if def.state == S_RUNNING:
		await _pm.stop_plugin("pcb")

	var start_result: Dictionary = await _pm.start_plugin("pcb")
	check("start_plugin returns ok", start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	if start_result.get("ok", false) != true:
		return false
	check("connection exists post-start", _pm.get_connection("pcb") != null)

	# ── the production broker, with the REAL PluginManager ────────────────────
	# Policy/capability-broker/audit stay null: backend-channel dispatch (the
	# path under test) consults NONE of them — only capability:* channels do,
	# and with the backend already RUNNING the panel's lazy-start capability
	# never fires. _audit guards a null audit_log itself.
	var broker_script: Script = load(SCENE_PANEL_BROKER_SCRIPT_PATH)
	check("PluginScenePanelBroker.gd loads", broker_script != null)
	if broker_script == null:
		return false
	_broker = broker_script.new(_pm, null, null, null)

	# Declared channels come from the live PluginDefinition (the same source
	# production registration reads), not re-typed here.
	var declared: PackedStringArray = PackedStringArray()
	for p in def.ui_panels:
		if p is Dictionary and str((p as Dictionary).get("name", "")) == "pcb_panel":
			for ch in (p as Dictionary).get("ipc_channels", []):
				declared.append(str(ch))
			break
	check("manifest panel declares channels for registration", declared.size() > 0)

	# ── the real panel, production mount order ───────────────────────────────
	panel = load(PANEL_PATH).new()
	check("PCBPanel script loads + instantiates", panel != null)
	if panel == null:
		return false
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)

	# Step 10 before step 11 (PluginScenePanelHost): register with the broker
	# (attaches the REAL MinervaIPC helper "$_MinervaIPC" and wires the
	# panel's `request` signal to handle_scene_request), THEN fire the load
	# hook — same order production mounting guarantees.
	_broker.register_panel(panel, "pcb", "pcb_panel", declared)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})

	data = panel.get_data()
	check("panel exposes live board data", data != null)
	check("broker attached the real _MinervaIPC helper",
			panel.get_node_or_null("_MinervaIPC") != null)
	for _i in range(4):
		await process_frame
	return data != null


# ──────────────────────────────────────────────────────────────────────────────
# Step 1 — load: panel → Go pcb.deserialize (+resolve enrichment) →
#          Go pcb.assembly_check → Python worker, end to end
# ──────────────────────────────────────────────────────────────────────────────

func _step_1_load_carries_assembly_findings() -> void:
	print("-- 1: minerva_pcb_load_board — real deserialize + load-time assembly tri-state --")
	var reply: Dictionary = await panel.handle_tool("minerva_pcb_load_board", {"yaml": BOARD_YAML})
	check("1: load reply is success", bool(reply.get("success", false)), str(reply))
	check_eq("1: component_count", int(reply.get("component_count", -1)), 3)
	check_eq("1: net_count", int(reply.get("net_count", -1)), 2)

	# The tri-state the load path attaches (PCBPanel.load_board_from_yaml runs
	# pcb.assembly_check over the DESERIALIZED, graphics-enriched board dict and
	# feeds the panel's assembly cache — the same cache step 3's commit gate
	# reads). "findings" here — not "indeterminate", not "pass" — is only
	# reachable when the worker's tolerant resolve actually attached the
	# library courtyards AND the Go side round-tripped them AND the check ran.
	var assembly: Dictionary = reply.get("assembly", {}) \
			if reply.get("assembly", {}) is Dictionary else {}
	check("1: load reply carries an assembly dict", not assembly.is_empty(), str(reply))
	check("1: assembly.status is findings", str(assembly.get("status", "")) == "findings",
			"assembly=%s" % str(assembly))
	var pair: Dictionary = _finding_naming(assembly, ["D1", "J1"])
	check("1: a finding names the D1/J1 overlap pair", not pair.is_empty(),
			"findings=%s" % str(assembly.get("findings", [])))
	# Courtyard basis proves the finding came from resolved library geometry —
	# the pad_extent fallback can NEVER see this overlap (the JST housing
	# reaches ~4.5mm past its pads; see the fixture doc above).
	check_eq("1: the finding's basis is courtyard", str(pair.get("basis", "")), "courtyard")
	check_eq("1: advisory severity (ergonomics floor, not a DRC gate)",
			str(pair.get("severity", "")), "advisory")
	check_eq("1: board starts with zero traces", data.get_trace_count(), 0)


# ──────────────────────────────────────────────────────────────────────────────
# Step 2 — intent + span-scoped propose through the REAL worker (the F0 seam)
# ──────────────────────────────────────────────────────────────────────────────

func _step_2_span_propose_full_contract() -> void:
	print("-- 2: add_route_intent + workspace_propose — real router, F0 constraint survival --")
	# Author the intent WITH a corridor: this mints the task-owned
	# routing_constraint (revision 1) whose survival across the real
	# route_board hop is exactly what F0's allow-list dropped.
	var intent: Dictionary = await panel.handle_tool("minerva_pcb_add_route_intent", {
		"source_pin": "D1.2",
		"dest_pin": "J1.1",
		"note": "production-seam span under test (work item 019fd5fe4127)",
		"corridor": [
			{"x_mm": 20.0, "y_mm": 10.65},
			{"x_mm": 23.58, "y_mm": 12.7},
		],
	})
	check("2: add_route_intent succeeds", bool(intent.get("success", false)), str(intent))
	_hint_id = str(intent.get("hint_id", ""))
	check("2: hint_id assigned", not _hint_id.is_empty())
	check_eq("2: intent resolved onto net N_SPAN", str(intent.get("net", "")), "N_SPAN")
	check_eq("2: constraint_revision minted at 1", int(intent.get("constraint_revision", 0)), 1)

	# Span-scoped propose (hint_ids named → selection mode "ids" → scope.tasks
	# carries the D1.2↔J1.1 span) through the REAL worker.
	var reply: Dictionary = await panel.handle_tool("minerva_pcb_workspace_propose", {
		"hint_ids": [_hint_id],
	})
	check("2: propose succeeds", bool(reply.get("success", false)), str(reply))
	check("2: a candidate landed", int(reply.get("proposed", 0)) >= 1
			and (reply.get("candidates", []) as Array).size() >= 1, str(reply))
	# The ask-boundary narration (docket 019fcb6f9d20): the run was span-scoped
	# and the reply must SAY so.
	var scope: Dictionary = reply.get("scope", {}) if reply.get("scope", {}) is Dictionary else {}
	check_eq("2: reply narrates the span scope (1 span task)", int(scope.get("span_tasks", 0)), 1)

	var cand: Dictionary = {}
	for c in reply.get("candidates", []):
		if c is Dictionary and str((c as Dictionary).get("net", "")) == "N_SPAN":
			cand = c
			break
	check("2: the candidate is on net N_SPAN", not cand.is_empty(),
			"candidates=%s" % str(reply.get("candidates", [])))
	if not cand.is_empty():
		_candidate_id = str(cand.get("candidate_id", ""))
		check("2: candidate_id assigned", not _candidate_id.is_empty())
		check("2: candidate links back to the source hint",
				(cand.get("source_hint_ids", []) as Array) == [_hint_id],
				"got %s" % str(cand.get("source_hint_ids", [])))
		# ── THE F0 ASSERTION ─────────────────────────────────────────────────
		# constraint_revision on the LANDED candidate can only exist if the
		# task_constraints entry rode the REAL PCBPanel.route_board request
		# assembly to the worker and came back cited on the route. Before this
		# suite, both neighbouring test suites were green while the live hop
		# silently dropped the key.
		check("2: F0 — candidate cites constraint_revision (task_constraints survived the real hop)",
				cand.has("constraint_revision"), "candidate=%s" % str(cand))
		check_eq("2: F0 — constraint_revision is the authored revision, int-typed (F5)",
				cand.get("constraint_revision"), 1)
		check("2: F0 — hint_status attached (worker's per-hint corridor verdict came back)",
				cand.has("hint_status") and (cand.get("hint_status", []) as Array).size() >= 1,
				"candidate=%s" % str(cand))

	# ── board_health: the whole-board ledger despite the span-scoped ask ──────
	var health: Dictionary = reply.get("board_health", {}) \
			if reply.get("board_health", {}) is Dictionary else {}
	check("2: board_health present on the propose reply", not health.is_empty(), str(reply))
	check("2: F2 — missing_copper names N_EMPTY (whole-board ledger despite span scope)",
			"N_EMPTY" in (health.get("missing_copper", []) as Array),
			"missing_copper=%s" % str(health.get("missing_copper", [])))
	check_eq("2: board_health.complete is false (copper is missing)",
			health.get("complete"), false)
	check_eq("2: board_health.approximate honesty flag", bool(health.get("approximate", false)), true)
	var bh_assembly: Dictionary = health.get("assembly", {}) \
			if health.get("assembly", {}) is Dictionary else {}
	check_eq("2: F3 — board_health.assembly.status is findings (collision named at propose)",
			str(bh_assembly.get("status", "")), "findings")
	# Panel-owned enrichment (DCR 019fd5fd9084): revision provenance + the
	# render-preflight nudge (warn-only, never a refusal).
	check_eq("2: board_health.board_revision is the live board's revision",
			int(health.get("board_revision", -1)), int(data.board_revision))
	var preflight: Dictionary = health.get("preflight", {}) \
			if health.get("preflight", {}) is Dictionary else {}
	check("2: preflight carries rendered_this_revision",
			preflight.has("rendered_this_revision"), str(health))
	check_eq("2: nothing was rendered this session — preflight says so",
			bool(preflight.get("rendered_this_revision", true)), false)
	check_eq("2: propose lays no copper (candidates are ghosts)", data.get_trace_count(), 0)


# ──────────────────────────────────────────────────────────────────────────────
# Step 3 — commit gate: fresh findings intersecting the endpoints REFUSE
# ──────────────────────────────────────────────────────────────────────────────

func _step_3_commit_refused_unacknowledged() -> void:
	print("-- 3: workspace_commit WITHOUT acknowledge_placement — refused by name --")
	if _candidate_id.is_empty():
		check("3: prerequisite candidate exists", false, "step 2 landed no candidate")
		return
	var traces_before: int = data.get_trace_count()
	var reply: Dictionary = await panel.handle_tool("minerva_pcb_workspace_commit", {
		"candidate_id": _candidate_id,
	})
	check("3: commit is refused", not bool(reply.get("success", true)), str(reply))
	check_eq("3: refusal is named placement_blocker_unacknowledged",
			str(reply.get("error", "")), "placement_blocker_unacknowledged")
	var blocking: Array = reply.get("blocking_findings", []) \
			if reply.get("blocking_findings", []) is Array else []
	check("3: blocking_findings present", blocking.size() >= 1, str(reply))
	var names_pair := false
	for f in blocking:
		if f is Dictionary:
			var comps: Array = (f as Dictionary).get("components", [])
			if "D1" in comps and "J1" in comps:
				names_pair = true
				break
	check("3: blocking_findings name the D1/J1 overlap pair", names_pair,
			"blocking_findings=%s" % str(blocking))
	check_eq("3: NO copper written — trace count unchanged",
			data.get_trace_count(), traces_before)


# ──────────────────────────────────────────────────────────────────────────────
# Step 4 — commit acknowledged: proceeds, records the acknowledgment, lays copper
# ──────────────────────────────────────────────────────────────────────────────

func _step_4_commit_acknowledged_lays_copper() -> void:
	print("-- 4: workspace_commit WITH acknowledge_placement:true — proceeds + records --")
	if _candidate_id.is_empty():
		check("4: prerequisite candidate exists", false, "step 2 landed no candidate")
		return
	var reply: Dictionary = await panel.handle_tool("minerva_pcb_workspace_commit", {
		"candidate_id": _candidate_id,
		"acknowledge_placement": true,
	})
	check("4: acknowledged commit succeeds", bool(reply.get("success", false)), str(reply))
	var acked: Array = reply.get("acknowledged_placement_findings", []) \
			if reply.get("acknowledged_placement_findings", []) is Array else []
	check("4: acknowledged_placement_findings recorded on the reply",
			acked.size() >= 1, str(reply))
	check_eq("4: committed candidate's disposition",
			str((reply.get("candidate", {}) as Dictionary).get("disposition", "")), "committed")
	check("4: copper written — at least one trace_id reported",
			not (reply.get("trace_ids", []) as Array).is_empty(), str(reply))
	check_eq("4: exactly one trace on the board", data.get_trace_count(), 1)
	check_eq("4: the copper is on net N_SPAN", (data.get_traces_for_net("N_SPAN") as Array).size(), 1)
	check("4: the source hint was consumed",
			(reply.get("consumed_hint_ids", []) as Array) == [_hint_id],
			"got %s" % str(reply.get("consumed_hint_ids", [])))


# ──────────────────────────────────────────────────────────────────────────────
# Teardown — lifecycle suite idiom
# ──────────────────────────────────────────────────────────────────────────────

func _teardown() -> void:
	if _broker != null and panel != null:
		_broker.unregister_panel("pcb", "pcb_panel")
	if panel != null and is_instance_valid(panel):
		panel._on_panel_unload()
		panel.queue_free()
		panel = null
		await process_frame
	if _pm != null:
		var stop_result: Dictionary = await _pm.stop_plugin("pcb")
		check("teardown: stop_plugin returns ok", stop_result.get("ok", false) == true,
				"got: %s" % str(stop_result))
	AnnotationHostRegistry._reset_for_test()


# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

## The first finding in `assembly.findings` whose components list contains
## every ref in `refs` — {} when none does.
func _finding_naming(assembly: Dictionary, refs: Array) -> Dictionary:
	for f in assembly.get("findings", []):
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


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)


func check_eq(description: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [description, str(expected), str(actual)], actual == expected)
