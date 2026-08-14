extends SceneTree
## EPOCH NLC station C4 — minerva_pcb_view_state (item 019ffeaccc0c).
##
## Run (via a Minerva checkout as the Godot host):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## THE GAP. minerva_pcb_set_view aims the CAMERA; nothing said what the camera
## was pointed AT. An agent could call minerva_pcb_get_image and had no way to
## know whether traces were drawn, whether an inner layer was hidden, or whether
## the fab preview was up — so it could not interpret its own screenshot. In the
## N-layer co-design HITL the human soloed each layer from the View menu and
## confirmed the board while the agent beside them was blind to the same
## control.
##
## WHY THE ASSERTIONS READ THE CANVAS, NOT THE REPLY. A view verb that reports
## what it INTENDED is the failure this station exists to remove — the whole
## point is that the reply describes what will actually be drawn. So every
## write below is checked against the live canvas object the renderer reads,
## and the reply is then checked to AGREE with it. Either alone would pass while
## the two disagreed.
##
## REUSE SCAN: panel boot + check helpers follow test_parity_bridge.gd
## (plugin_panel_driver, host.set_panel).
##
## SCOPE, stated accurately: these call PanelTools._view_state DIRECTLY. The
## dispatch wiring is NOT exercised here — an earlier version of this header
## claimed it was, and named a "handle_tool_call" entry point that does not
## exist (the dispatcher is handle()). The manifest<->dispatch pairing is pinned
## instead by test_pcb_panel_tools.gd, which reads both out of the source and
## fails if either side lacks the other.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== PCB view_state (NLC C4) ===\n")
	await _run_read_reports_the_canvas()
	await _run_flags_are_writable_and_absolute()
	await _run_layers_solo()
	await _run_refusals_change_nothing()
	await _run_types_are_validated()
	await _run_explicit_filter_wins()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


## A real panel + host + a FOUR-layer board, so the layer half has inner layers
## to hide. A 2-layer fixture cannot tell "hid the layer I named" from "hid the
## only other layer there was".

class FakeEditor extends RefCounted:
	var tab_title: String = "NlcProbe"
	var associated_object: Variant = ""


## A panel MOUNTED IN THE REAL TREE, because these suites touch the UI.
##
## plugin_panel_driver.load_panel only calls script.new() — the panel never
## enters the tree, so _ready()/_build_ui() never run and _canvas, _tool_buttons
## and every OptionButton stay null. Both reviews confirmed get_canvas() EXISTS
## and it does; it returns null against an unmounted panel, which only execution
## could show. Mount pattern copied from test_pcb_panel_ui.gd's
## _mount_panel_in_tree, which exists for exactly this reason.
func _mount() -> Variant:
	var panel: Variant = load(PCB_PANEL_SCRIPT_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1100, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	for _i in range(6):
		await process_frame
	return panel


func _unmount(panel: Variant) -> void:
	if panel != null and panel is Node:
		(panel as Node).queue_free()
	await process_frame


func _ctx() -> Dictionary:
	var panel = await _mount()
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()
	if data != null and data.has_method("set_board_layers"):
		data.set_board_layers(["top", "in1", "in2", "bottom"])
	return {"panel": panel, "host": host, "data": data, "canvas": host.get_canvas()}


## AWAITED: _view_state runs the on-demand mask/fab-preview worker round-trips
## through PCBPanel.set_view_flag, so it is a coroutine. Calling it without
## await would hand back a coroutine object and every assertion below would be
## reading fields off the wrong thing.
func _view(host, args: Dictionary = {}) -> Dictionary:
	return await PanelTools._view_state(host, args)


# ── 1. reading reports what the canvas actually holds ─────────────────────────

func _run_read_reports_the_canvas() -> void:
	print("-- 1. a bare read reports every flag and layer --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var canvas = ctx["canvas"]
	var panel = ctx["panel"]

	var res: Dictionary = await _view(host)
	check("read succeeds", bool(res.get("success", false)))
	var flags: Dictionary = res.get("flags", {})

	# Sourced from the panel's own _VIEW_FLAGS via view_flag_names(), so a flag
	# added there appears here without a second edit — that drift is how
	# show_route_candidates shipped with no control at all.
	check_eq("every View flag is reported", flags.size(), (panel.view_flag_names() as Array).size())
	check("show_traces is among them", flags.has("show_traces"))
	check("the on-demand overlays are among them",
		flags.has("show_mask") and flags.has("show_fab_preview"))

	# Agreement with the live canvas, flag by flag — not with a second copy of
	# the defaults written into this test.
	var disagreed: Array = []
	for name in flags.keys():
		if bool(flags[name]) != bool(canvas.get(str(name))):
			disagreed.append(str(name))
	check_eq("every reported flag matches the canvas", disagreed, [])

	var layers: Array = res.get("layers", [])
	check_eq("all four declared layers are reported", layers.size(), 4)
	check_eq("the first layer is top", str((layers[0] as Dictionary).get("id", "")), "top")
	check_eq("an inner layer reports its KiCad name too",
		str((layers[1] as Dictionary).get("kicad", "")), "In1.Cu")
	check("nothing is hidden to begin with",
		not bool((layers[1] as Dictionary).get("hidden", true)))
	check("a bare read changed nothing", (res.get("changed", []) as Array).is_empty())

	await _unmount(ctx["panel"])


# ── 2. flags are absolute, and reach the canvas ───────────────────────────────

func _run_flags_are_writable_and_absolute() -> void:
	print("-- 2. writing a flag moves the canvas, and is absolute not a toggle --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var canvas = ctx["canvas"]

	var before := bool(canvas.get("show_traces"))
	var grid_before := bool(canvas.get("show_grid"))
	var res: Dictionary = await _view(host, {"flags": {"show_traces": not before}})
	check("write succeeds", bool(res.get("success", false)))
	check_eq("THE CANVAS moved", bool(canvas.get("show_traces")), not before)
	check_eq("the reply agrees with the canvas",
		bool((res.get("flags", {}) as Dictionary).get("show_traces", before)), not before)
	check("the change is named in `changed`", "show_traces" in (res.get("changed", []) as Array))

	# ABSOLUTE, NOT A TOGGLE. Setting the same value again is a no-op — an agent
	# re-asserting a view it already asked for must not flip it back, which a
	# toggle-shaped verb would do and which is unnoticeable without a screen.
	var again: Dictionary = await _view(host, {"flags": {"show_traces": not before}})
	check_eq("re-asserting the same value changes nothing",
		(again.get("changed", []) as Array), [])
	check_eq("and the canvas is still where it was put",
		bool(canvas.get("show_traces")), not before)

	# Untouched flags are untouched: a partial write is not a whole-state write.
	# COMPARED AGAINST A VALUE CAPTURED BEFORE THE WRITE (cold review, finding
	# 9). The earlier form compared the reply to the canvas — both read from the
	# same object after the write — so it could not fail even if show_grid had
	# been changed.
	check_eq("a flag not named in the write kept its value",
		bool(canvas.get("show_grid")), grid_before)

	await _unmount(ctx["panel"])


# ── 3. hidden_layers is the COMPLETE set — which is what makes solo work ──────

func _run_layers_solo() -> void:
	print("-- 3. hidden_layers solos a layer, and is a set not a delta --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var canvas = ctx["canvas"]
	var panel = ctx["panel"]

	# Solo in1: hide every other declared layer. This is the gesture the human
	# had from the View menu and the agent did not.
	# THE TOOLBAR IS LEFT ON A SPECIFIC LAYER FIRST (cold review 2, finding 1).
	# That is the state the human leaves behind after soloing from the toolbar,
	# and it is the state in which this gesture used to do NOTHING: a specific
	# trace_layer_filter beats every per-layer eye in _layer_visible, so the eye
	# dictionary moved while the canvas kept drawing the filtered layer.
	panel.set_trace_layer_filter("top")
	check_eq("precondition: the toolbar filter is on a specific layer",
		str(canvas.trace_layer_filter), "top")

	var res: Dictionary = await _view(host, {"hidden_layers": ["top", "in2", "bottom"]})
	check("solo write succeeds", bool(res.get("success", false)))

	# ASSERT ACTUAL VISIBILITY, NOT THE BACKING DICTIONARY. is_layer_hidden reads
	# the eyes alone and would have passed while the canvas drew the opposite —
	# a producer-side assertion on the very state that was being ignored.
	check("in1 is ACTUALLY visible", bool(canvas.is_layer_visible("in1")))
	check("top is ACTUALLY not visible", not bool(canvas.is_layer_visible("top")))
	check("in2 is ACTUALLY not visible", not bool(canvas.is_layer_visible("in2")))
	check("bottom is ACTUALLY not visible", not bool(canvas.is_layer_visible("bottom")))
	check_eq("the filter was reset to all so the eyes govern",
		str(canvas.trace_layer_filter), "all")
	check("and the reset is reported", "trace_layer_filter" in (res.get("changed", []) as Array))

	# The eyes themselves still say what was asked, so the two views agree.
	check("in1 eye open", not bool(canvas.is_layer_hidden("in1")))
	check("top eye shut", bool(canvas.is_layer_hidden("top")))

	# A SET, NOT A DELTA. Passing a different set must UNHIDE what it omits;
	# a delta-shaped verb would leave the previous three hidden forever and an
	# agent would never work out why its screenshots were empty.
	var res2: Dictionary = await _view(host, {"hidden_layers": ["bottom"]})
	check("omitted layers become visible again", not bool(canvas.is_layer_hidden("top")))
	check("and the named one stays hidden", bool(canvas.is_layer_hidden("bottom")))
	var hidden_reported: Array = []
	for row in (res2.get("layers", []) as Array):
		if bool((row as Dictionary).get("hidden", false)):
			hidden_reported.append(str((row as Dictionary).get("id", "")))
	check_eq("the reply reports exactly that one hidden", hidden_reported, ["bottom"])

	# [] is the "show everything" request, and must not be read as "no key".
	await _view(host, {"hidden_layers": []})
	check("an empty set shows every layer",
		not bool(canvas.is_layer_hidden("bottom")) and not bool(canvas.is_layer_hidden("top")))

	await _unmount(ctx["panel"])


# ── 4. refusals are named, and TOTAL ──────────────────────────────────────────

func _run_refusals_change_nothing() -> void:
	print("-- 4. a bad request changes NOTHING, including its good half --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var canvas = ctx["canvas"]

	var grid_before := bool(canvas.get("show_grid"))

	# One good flag, one typo. The whole request must be refused: the caller
	# cannot see the screen, so a half-applied view is a view nobody knows the
	# shape of.
	var bad: Dictionary = await _view(host, {"flags": {"show_grid": not grid_before, "show_grd": true}})
	check("a request naming an unknown flag refuses", not bool(bad.get("success", true)))
	check_eq("named unknown_view_flag", str(bad.get("error", "")), "unknown_view_flag")
	check_eq("and says which one", str(bad.get("unknown", "")), "show_grd")
	check("and lists the flags that DO exist",
		not (bad.get("known_flags", []) as Array).is_empty())
	check_eq("THE GOOD HALF WAS NOT APPLIED", bool(canvas.get("show_grid")), grid_before)

	# A layer this board does not declare.
	var bad_layer: Dictionary = await _view(host, {"hidden_layers": ["in7"]})
	check("hiding an undeclared layer refuses", not bool(bad_layer.get("success", true)))
	check_eq("named layer_not_on_stack", str(bad_layer.get("error", "")), "layer_not_on_stack")
	check("the refusal reports the declared stack",
		(bad_layer.get("declared_layers", []) as Array).size() == 4)
	check("nothing was hidden by the refusal", not bool(canvas.is_layer_hidden("top")))

	# Wrong TYPE, not just a wrong value.
	var bad_type: Dictionary = await _view(host, {"hidden_layers": "top"})
	check("a non-array hidden_layers refuses", not bool(bad_type.get("success", true)))
	check_eq("named invalid_args", str(bad_type.get("error", "")), "invalid_args")

	await _unmount(ctx["panel"])


# ── 5. TYPES, not just names (cold review, finding 5) ─────────────────────────
#
# bool("true") is not a valid conversion in GDScript and errors AT THE POINT OF
# USE. Left to the apply loop, that error would land AFTER earlier flags had
# been written — the partial application this verb promises cannot happen. The
# manifest schema constrains nothing inside `flags`, so a loosely-typed caller
# sending a string is ordinary input, not an exotic case.

func _run_types_are_validated() -> void:
	print("-- 5. wrong-typed arguments refuse, and write nothing --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var canvas = ctx["canvas"]

	var traces_before := bool(canvas.get("show_traces"))
	var grid_before := bool(canvas.get("show_grid"))

	# A good flag FIRST, so a non-total validation would have applied it before
	# reaching the bad one.
	var bad_val: Dictionary = await _view(host, {"flags":
		{"show_grid": not grid_before, "show_traces": "true"}})
	check("a non-boolean flag value refuses", not bool(bad_val.get("success", true)))
	check_eq("named invalid_args", str(bad_val.get("error", "")), "invalid_args")
	check_eq("and the GOOD flag was not applied",
		bool(canvas.get("show_grid")), grid_before)
	check_eq("nor the bad one", bool(canvas.get("show_traces")), traces_before)

	# A non-dict `flags` was previously swallowed by _dict_or_empty and reported
	# as success — the silent no-op its hidden_layers sibling already refuses.
	var bad_flags: Dictionary = await _view(host, {"flags": "show_traces"})
	check("a non-object flags refuses", not bool(bad_flags.get("success", true)))
	check_eq("named invalid_args", str(bad_flags.get("error", "")), "invalid_args")

	# kicad_to_canon maps "" to "top" with only a warning (it is the read side),
	# so an empty name would hide the top layer nobody asked about.
	var empty_layer: Dictionary = await _view(host, {"hidden_layers": [""]})
	check("an empty layer name refuses", not bool(empty_layer.get("success", true)))
	check_eq("named invalid_args", str(empty_layer.get("error", "")), "invalid_args")
	check("and the top layer was NOT hidden", not bool(canvas.is_layer_hidden("top")))

	await _unmount(ctx["panel"])


# ── 6. an EXPLICIT filter outranks the implicit reset ─────────────────────────

func _run_explicit_filter_wins() -> void:
	print("-- 6. trace_layer_filter is writable and applied last --")
	var ctx: Dictionary = await _ctx()
	var host = ctx["host"]
	var canvas = ctx["canvas"]

	# Both in one request: hidden_layers would reset the filter to "all", but an
	# explicit filter is what the caller literally wrote, so it wins.
	var res: Dictionary = await _view(host, {
		"hidden_layers": ["bottom"], "trace_layer_filter": "in1"})
	check("write succeeds", bool(res.get("success", false)))
	check_eq("the explicit filter is in force", str(canvas.trace_layer_filter), "in1")
	check_eq("and is reported back", str(res.get("trace_layer_filter", "")), "in1")

	# A filter this board does not declare is refused by name, changing nothing.
	var bad: Dictionary = await _view(host, {"trace_layer_filter": "in7"})
	check("an undeclared filter refuses", not bool(bad.get("success", true)))
	check_eq("named layer_not_on_stack", str(bad.get("error", "")), "layer_not_on_stack")
	check_eq("the filter is untouched", str(canvas.trace_layer_filter), "in1")

	await _unmount(ctx["panel"])
