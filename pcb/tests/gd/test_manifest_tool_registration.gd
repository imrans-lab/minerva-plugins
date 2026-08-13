extends SceneTree
## Round D0-expose (docket 019fa486b408) host-registration gate.
##
## The Go stdio smoke (pcb/main_test.go) proves the BROKER answers each
## renamed tool by its manifest name — but it never touches Minerva's host
## code, so it cannot catch a manifest PluginToolRegistry.register_plugin_tools
## would reject (e.g. a name missing the "minerva_pcb_" prefix, which the
## registry enforces defensively even though PluginDefinition.validate()
## already checks it at parse time). This test closes that gap: it parses the
## REAL pcb/manifest.json through the real host parser (PluginDefinition) and
## registers its tools through the real host registry (PluginToolRegistry),
## exactly as PluginManager.start_plugin's install/start path does, and
## asserts the 11 renamed worker-backed tools land.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_manifest_tool_registration.gd
## Or via the whole-suite runner: pcb/scripts/run-gd-tests.sh <minerva-checkout>

# Loaded via load() by script path (not class_name) — mirrors
# src/test/test_pcb_plugin_smoke.gd's Section B, which loads these same two
# scripts the same way rather than relying on class_name global resolution.
const PLUGIN_DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const PLUGIN_TOOL_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"

# res:// == src/, so res://../../minerva-plugins/pcb/manifest.json is the
# REAL manifest this round edited — not a copy, not a fixture.
const PCB_MANIFEST_PATH := "res://../../minerva-plugins/pcb/manifest.json"

## The 11 tools round D0-expose (docket 019fa486b408) renamed from bare
## pcb_* broker names to minerva_pcb_* and declared in the manifest for the
## first time, PLUS D0-5's minerva_pcb_export_assembly (docket 019fc2f8b903)
## — same worker-backed shape, added to this same list so a rename/swap of
## the new tool reds BY NAME here too, not just via the aggregate count pin
## below. Kept as a literal list (not derived from the manifest) so this
## test pins the EXPECTED set independently of whatever the manifest happens
## to contain — a manifest that dropped one silently would still fail this.
const EXPECTED_WORKER_TOOLS := [
	"minerva_pcb_validate",
	"minerva_pcb_generate",
	"minerva_pcb_gerbers",
	"minerva_pcb_drc",
	"minerva_pcb_drc_geometric",
	"minerva_pcb_resolve",
	"minerva_pcb_normalize",
	"minerva_pcb_export_assembly",
	"minerva_pcb_check_libraries",
	"minerva_pcb_check_bom",
	"minerva_pcb_fetch_libraries",
	"minerva_pcb_library_status",
]

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== PCB manifest tool registration (round D0-expose, 019fa486b408) ===\n")

	var def_script: Script = load(PLUGIN_DEFINITION_SCRIPT_PATH)
	check("PluginDefinition script loads", def_script != null)
	if def_script == null:
		_finish()
		return

	# from_manifest() both parses the JSON AND runs validate() — a manifest
	# entry whose name doesn't start with "minerva_pcb_" fails validate() and
	# from_manifest returns null with pushed errors. So this one call already
	# proves the manifest is prefix-conformant before registration is even
	# attempted.
	var def = def_script.from_manifest(PCB_MANIFEST_PATH)
	check("pcb/manifest.json parses with zero validate() errors", def != null,
			"from_manifest returned null — see pushed validation errors above")
	if def == null:
		_finish()
		return
	check("parsed definition id == 'pcb'", def.id == "pcb", "got id='%s'" % str(def.id))

	var registry_script: Script = load(PLUGIN_TOOL_REGISTRY_SCRIPT_PATH)
	check("PluginToolRegistry script loads", registry_script != null)
	if registry_script == null:
		_finish()
		return
	var registry = registry_script.new()

	# The exact call PluginManager.on_plugin_started / initial-population makes
	# (see PluginToolRegistry.gd's own integration-plan comment): register
	# every manifest-declared tool for this plugin id in one atomic call.
	var result: Dictionary = registry.register_plugin_tools(def.id, def.tools)
	check("register_plugin_tools returns ok", result.get("ok", false) == true,
			"got: %s" % str(result))

	var registered: Array = result.get("registered", [])
	for tool_name in EXPECTED_WORKER_TOOLS:
		check("registered: %s" % tool_name, tool_name in registered,
				"registered set: %s" % str(registered))

	# Total count pin: 45 panel tools (29 pre-A6 + the 5 A6 zone tools + the 3 A7
	# trace-width/preference tools: set_trace_width, get_preference,
	# set_preference + the 2 B1-U2 board-via tools: list_vias, delete_via + the
	# 6 B2 MCP-parity tools: create_zone, set_zone_outline, group_components,
	# ungroup, set_group_member_offset, get_layout_state) + these 11 worker
	# tools + the 4 campaign-2-epoch-B unit-3 cutout tools (list_cutouts,
	# describe_cutout, create_cutout, delete_cutout — the zone surface's
	# four-tool subset, minus set_net/set_layer/set_outline, which a netless,
	# layerless cutout has nothing to name) == 60, + the 10 C4a routing-workspace
	# verb tools (workspace_propose, workspace_list, workspace_get_active,
	# workspace_pin, workspace_unpin, workspace_reject, workspace_commit,
	# workspace_reroute_route, workspace_reroute_span, workspace_check — the
	# agent's doorway onto the same verbs the canvas candidate menu offers a
	# human; DCR 019f7095c395 S4) == 70, - the 2 C4b S5-removal tools
	# (proposal_accept, proposal_reject — the per-proposal ANNOTATION verbs;
	# DCR 019f7095c395 S5. PROPOSE no longer writes a proposal annotation for
	# either to act on — panel_tools.gd _propose_into_workspace lands
	# RouteCandidates in the routing workspace instead, resolved through
	# minerva_pcb_workspace_commit/_reject, already counted above) == 68,
	# + 1 C5 bus-tool MCP parity tool (minerva_pcb_route_bus_direct — the
	# agent's doorway onto the canvas Bus tool, DCR 019fb572b888 S3+S4;
	# panel_tools.gd bus_plan/bus_commit_plan is the ONE implementation both
	# the gesture and this tool call) == 69, + 1 D0-5 worker-backed tool
	# (minerva_pcb_export_assembly — the Go/manifest wiring onto C8's
	# already-shipped worker-side assembly_bom/assembly_cpl emitters, docket
	# 019fc2f8b903) == 70, + 1 bus-propose tool
	# (minerva_pcb_workspace_propose_bus — the proposal twin of
	# route_bus_direct; panel_tools.gd bus_propose_plan is the ONE
	# implementation both the Shift+Enter gesture and this tool call, docket
	# 019fcac1509d) == 71, + 1 Epoch UX1 station 8 tool
	# (minerva_pcb_add_route_intent — the narrow connectivity-intent verb,
	# DCR 019fd095e694) == 72, + 1 Epoch UX1 station 10 tool
	# (minerva_pcb_workspace_edit_candidate — the ONE discriminated
	# candidate-edit verb, move_junction/insert_via, DCR 019fd095e694) == 73,
	# + 1 Codex 1047 fix-round verdict-4 tool
	# (minerva_pcb_hint_convert_to_detailed — the NAMED guided→detailed
	# conversion that clears a singly-owned task constraint and strips the
	# station-12 supersession marker in ordered two-store writes; NOT atomic
	# across the two sidecars — Codex 1047 verdict 6, load-time
	# reconciliation owns the torn shapes) == 74,
	# + 1 HITL-6b tool (minerva_pcb_get_selection — the deictic "what's this"
	# read over the canvas selection, docket 019fdf5579) == 75,
	# + 2 Epoch UX3 station-1 tools (minerva_pcb_workspace_freeze /
	# _unfreeze — K7's settlement verb pair, docket 019fdf913513; frozen rides
	# the pinned_candidates keep-out wire and always joins the draft-check
	# set) == 77,
	# + 5 Epoch UX3 station-10 tools (docket 019fdf9101b5 — LLM reverse
	# parity: minerva_pcb_point, the get_selection mirror; the three
	# hint_move/insert/delete_bend micro-edit verbs; and
	# minerva_pcb_clear_hints_by_author, the dock menu's MCP twin) == 82,
	# + 1 Epoch UX3 station-11 tool (minerva_pcb_promote — K13's gated
	# serialize-back verb, docket 019fdf91b3ac) == 83,
	# + 5 Epoch UX4 station-8 tools (DCR 019fe07523ca S8 — the STAGING family:
	# minerva_pcb_propose_zone/_propose_cutout, the create_* twins that land
	# review ghosts; minerva_pcb_staged_list/_staged_accept/_staged_reject,
	# the review verbs; distinct from the workspace_propose_* ROUTER family)
	# == 88.
	# Catches a manifest that silently dropped or duplicated an unrelated entry
	# while a round's diff was being made.
	#
	# DELIBERATE PIN BUMP, in its own commit: the number moves only when a round
	# adds or removes a tool ON PURPOSE, so the bump is reviewed as its own diff
	# rather than riding along inside a feature change where a silently-dropped
	# entry could hide behind it. This is the Epoch OFC station-4 bump
	# (96 -> 97, minerva_pcb_board_check — the live-board census, the promote
	# gate's read-only twin; kills detection-by-refusal, docket 019ff942beb4),
	# sequenced after the placement-coworking SPIKE bump
	# (94 -> 96, propose_placement + placement_update — staged component-move
	# ghosts, docket 019ff8615fbe; SPIKE quality, semantics under
	# ratification), sequenced after the Epoch LIB2 station-2 bump
	# (93 -> 94, B4's import tool — minerva_pcb_import_footprint, the
	# arbitrary-source supply-chain surface: git/URL/vendor-export bytes staged
	# UNBLESSED, never auto-trusted), sequenced after the LIB2 station-1 bump
	# (92 -> 93, B7's promote tool — minerva_pcb_footprint_promote, the bless
	# gate's exit door: a blessed WIP part moves whole into the durable user
	# layer), the Epoch LIB1 station-4 bump
	# (91 -> 92, B3's acquire tool — minerva_pcb_acquire_footprint, the
	# on-demand official-KiCad fetch that stages and auto-blesses through B2's
	# machinery), the LIB1 station-3 bump (88 -> 91, B2's
	# footprint stage/report/bless trio), the Epoch UX4 station-8 bump
	# (83 -> 88), UX3 station-11's (82 -> 83),
	# station-10's (77 -> 82), station-1's (75 -> 77), HITL-6b's (74 -> 75),
	# Codex 1047 verdict-4's (73 -> 74), UX1 station 10's (72 -> 73), station
	# 8's (71 -> 72), bus-propose's (70 -> 71), D0-5's (69 -> 70), C5's
	# (68 -> 69), C4b's (70 -> 68) and C4a's (60 -> 70) — all queue behind the
	# same serialization point.
	check("total registered tool count == 97", registered.size() == 97,
			"got %d: %s" % [registered.size(), str(registered)])

	# Each of the 11 must resolve through find_tool() with a non-empty
	# input_schema — guards against a manifest entry present in name only
	# (e.g. "input_schema" key missing entirely, which register_plugin_tools
	# would silently default to {"type":"object","properties":{}} rather than
	# reject). The Go side (TestManifestInputSchemaMatchesBroker) is what pins
	# the schema's CONTENT against the broker; this just confirms the host
	# sees a real, non-empty schema for each.
	for tool_name in EXPECTED_WORKER_TOOLS:
		var entry: Dictionary = registry.find_tool(tool_name)
		check("find_tool(%s) returns a non-empty input_schema" % tool_name,
				entry.get("input_schema", {}) is Dictionary and not (entry.get("input_schema", {}) as Dictionary).is_empty(),
				"entry: %s" % str(entry))
		check("find_tool(%s) executor defaults to 'backend'" % tool_name,
				str(entry.get("executor", "")) == "backend",
				"entry: %s" % str(entry))

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
