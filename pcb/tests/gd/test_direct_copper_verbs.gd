extends SceneTree
## EPOCH NLC station C2 — minerva_pcb_place_via (item 019fff60e05a).
##
## Run (via a Minerva checkout as the Godot host):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## THE PARITY GAP. Copper CREATION was proposal-only while copper DESTRUCTION
## was direct: minerva_pcb_delete_via and minerva_pcb_delete_traces act on the
## board, but the only add-via verb edited a route HINT. An agent could delete a
## via it could not put back, and the owner's N-layer HITL named it — "there is
## no tool to place a via for the human, only propose ... that breaks a goal of
## parity between tools and proposals".
##
## The suite is named for the THEME, not the verb, because C3's direct trace
## verb belongs beside this one: they are the same gap answered twice, and
## splitting them would hide that the pair has to stay symmetric.
##
## REUSE SCAN: panel boot + check helpers follow test_view_state.gd, which
## follows test_parity_bridge.gd. Assertions read back through the MODEL
## (data.vias, data.get_via) rather than trusting the verb's reply — the reply
## is the thing under test.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Direct copper verbs (NLC C2) ===\n")
	_run_place_via_lands_on_the_board()
	_run_span_is_not_selectable()
	_run_refusals_change_nothing()
	_run_round_trips_with_delete()
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


func _ctx() -> Dictionary:
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var panel = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	var host = panel.get_annotation_host()
	host.set_panel(panel)
	var data = panel.get_data()
	# A four-layer board, so "the span is always through" is a claim with
	# something to be wrong about — on a 2-layer board top<->bottom is the only
	# span there is and the assertion would be vacuous.
	if data != null and data.has_method("set_board_layers"):
		data.set_board_layers(["top", "in1", "in2", "bottom"])
	return {"driver": driver, "panel": panel, "host": host, "data": data}


# ── 1. it lands on the BOARD, not on a proposal ───────────────────────────────

func _run_place_via_lands_on_the_board() -> void:
	print("-- 1. place_via writes a real board via --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var before: int = data.vias.size()
	var res: Dictionary = PanelTools._place_via(host, {"x_mm": 10.0, "y_mm": 12.5, "net_name": "GND"})
	check("place_via succeeds", bool(res.get("success", false)))

	# Read back through the MODEL. The reply saying it worked is not evidence
	# that copper exists.
	check_eq("the board gained exactly one via", data.vias.size(), before + 1)
	var via_id := str(res.get("via_id", ""))
	check("the reply names a via id", not via_id.is_empty())
	var stored: Dictionary = data.get_via(via_id)
	check("that id resolves to a stored via", not stored.is_empty())
	check_eq("stored at the point asked for", data.via_position(stored), Vector2(10.0, 12.5))
	check_eq("carrying the net it was given", str(stored.get("net_name", "")), "GND")

	# THROUGH SPAN, unconditionally — on a 4-layer board.
	check_eq("stored span is top", str(stored.get("from_layer", "")), "top")
	check_eq("stored span is bottom", str(stored.get("to_layer", "")), "bottom")

	# Defaults, and the ring between them.
	check_eq("default size", float(stored.get("size", 0.0)), 0.8)
	check_eq("default drill", float(stored.get("drill", 0.0)), 0.4)

	ctx["driver"].free_panel(ctx["panel"])


# ── 2. a span argument is REFUSED, not ignored ────────────────────────────────

func _run_span_is_not_selectable() -> void:
	print("-- 2. from_layer/to_layer/layers are refused, never silently dropped --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	# Silently ignoring an argument someone bothered to write is how a caller
	# comes to believe in a blind/buried via this pipeline cannot fabricate.
	for banned in ["from_layer", "to_layer", "layers"]:
		var args := {"x_mm": 5.0, "y_mm": 5.0}
		args[banned] = "in1"
		var res: Dictionary = PanelTools._place_via(host, args)
		check("'%s' is refused" % banned, not bool(res.get("success", true)))
		check_eq("named span_not_selectable for '%s'" % banned,
			str(res.get("error", "")), "span_not_selectable")

	check_eq("no via was created by any of them", data.vias.size(), 0)

	ctx["driver"].free_panel(ctx["panel"])


# ── 3. every refusal is named, and writes nothing ─────────────────────────────

func _run_refusals_change_nothing() -> void:
	print("-- 3. off-board, stacked, and degenerate geometry all refuse --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var missing: Dictionary = PanelTools._place_via(host, {"y_mm": 1.0})
	check("a missing coordinate refuses", not bool(missing.get("success", true)))

	# Off the board outline. The agent cannot see the board to notice it asked
	# for copper that cannot be manufactured.
	var off: Dictionary = PanelTools._place_via(host,
		{"x_mm": float(data.board_width) + 50.0, "y_mm": 1.0})
	check("a point off the board refuses", not bool(off.get("success", true)))
	check_eq("named outside_board", str(off.get("error", "")), "outside_board")

	# The annular ring IS size minus drill, so a drill at least as wide as the
	# pad is a hole through nothing.
	var ring: Dictionary = PanelTools._place_via(host,
		{"x_mm": 5.0, "y_mm": 5.0, "size_mm": 0.4, "drill_mm": 0.4})
	check("drill >= size refuses", not bool(ring.get("success", true)))

	var neg: Dictionary = PanelTools._place_via(host,
		{"x_mm": 5.0, "y_mm": 5.0, "drill_mm": -1.0})
	check("a non-positive drill refuses", not bool(neg.get("success", true)))

	check_eq("not one refusal wrote copper", data.vias.size(), 0)

	# Stacking: place one, then ask for the same point again.
	check("the first via at (5,5) is placed",
		bool(PanelTools._place_via(host, {"x_mm": 5.0, "y_mm": 5.0}).get("success", false)))
	var stacked: Dictionary = PanelTools._place_via(host, {"x_mm": 5.0, "y_mm": 5.0})
	check("a second via at the same point refuses", not bool(stacked.get("success", true)))
	check_eq("named via_already_there", str(stacked.get("error", "")), "via_already_there")
	check("and names the via already there", not str(stacked.get("via_id", "")).is_empty())
	check_eq("still exactly one via", data.vias.size(), 1)

	ctx["driver"].free_panel(ctx["panel"])


# ── 4. create and destroy are now symmetric ───────────────────────────────────

func _run_round_trips_with_delete() -> void:
	print("-- 4. place -> delete -> place: the parity claim, end to end --")
	var ctx := _ctx()
	var host = ctx["host"]
	var data = ctx["data"]

	var placed: Dictionary = PanelTools._place_via(host, {"x_mm": 20.0, "y_mm": 20.0, "net_name": "N1"})
	var via_id := str(placed.get("via_id", ""))
	check_eq("one via on the board", data.vias.size(), 1)

	# THE WHOLE POINT OF THE STATION: the agent can put back what it removed.
	var deleted: Dictionary = PanelTools._delete_via(host, {"via_id": via_id})
	check("delete_via accepts the id place_via minted", bool(deleted.get("success", false)))
	check_eq("board is empty again", data.vias.size(), 0)

	var again: Dictionary = PanelTools._place_via(host, {"x_mm": 20.0, "y_mm": 20.0, "net_name": "N1"})
	check("the same via can be placed again", bool(again.get("success", false)))
	check_eq("board has one via once more", data.vias.size(), 1)
	# A re-place must not collide with the freed id — the model's id high-water
	# mark is what prevents it, and this is the caller that would notice.
	check("the re-placed via has a non-empty id", not str(again.get("via_id", "")).is_empty())

	ctx["driver"].free_panel(ctx["panel"])
