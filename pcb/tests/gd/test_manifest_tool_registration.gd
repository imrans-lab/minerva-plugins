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
## first time. Kept as a literal list (not derived from the manifest) so this
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

	# Total count pin: 37 panel tools (29 pre-A6 + the 5 A6 zone tools + the 3 A7
	# trace-width/preference tools: set_trace_width, get_preference,
	# set_preference) + these 11 worker tools == 48. Catches a manifest that
	# silently dropped or duplicated an unrelated entry while a round's diff was
	# being made.
	check("total registered tool count == 48", registered.size() == 48,
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
