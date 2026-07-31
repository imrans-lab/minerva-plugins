extends SceneTree
## Regression guards for the epoch-6 HITL fix batch (owner ruling amendment of
## 2026-07-30: regressions for HITL-found defects are authored where
## automatable).
##
##   * redo-after-delete — docket 019fb64ebebe / bug 019fb5ad791c (fixed at
##     23a75f7): a deletion snapshotted AFTER the mutation must undo AND redo.
##   * per-layer trace palette — docket 019fb64eed18 / item 019fb59c2d17
##     (shipped at 4aa57e8): inner-layer traces never borrow the top colour.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Epoch-6 fix regressions ===\n")
	_run_redo_after_delete()
	_run_trace_palette()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		printerr("  FAIL: " + desc)


## The fixed ordering (mutate, THEN save_to_history) must make redo re-apply
## the deletion. Before 23a75f7 the snapshot preceded the mutation, so redo
## restored the pre-delete state and silently did nothing.
func _run_redo_after_delete() -> void:
	print("-- redo re-applies deletions (bug 019fb5ad791c) --")
	var data = PCBData.new()
	var comp = data.new_component()
	comp.id = "U1"
	comp.position = Vector2(0, 0)
	data.add_component(comp)
	var t = data.new_trace()
	t.id = "t1"
	t.net_name = "N1"
	t.layer = "top"
	t.width = 0.3
	t.waypoints.append(Vector2(0, 0))
	t.waypoints.append(Vector2(5, 0))
	data.add_trace(t)
	data.save_to_history("baseline")

	data.remove_component("U1")
	data.save_to_history("delete U1")
	check("undo restores the component", data.undo() and data.has_component("U1"))
	check("redo re-deletes the component", data.redo() and not data.has_component("U1"))

	data.remove_trace("t1")
	data.save_to_history("delete t1")
	check("undo restores the trace", data.undo() and data.get_trace("t1") != null)
	check("redo re-deletes the trace", data.redo() and data.get_trace("t1") == null)


func _run_trace_palette() -> void:
	print("-- per-layer trace palette (item 019fb59c2d17) --")
	var canvas = PcbCanvasScript.new()
	var top: Color = canvas._trace_layer_color("top")
	var bottom: Color = canvas._trace_layer_color("bottom")
	check("top uses trace_top_color", top == canvas.trace_top_color)
	check("bottom uses trace_bottom_color", bottom == canvas.trace_bottom_color)

	var seen := {}
	var all_distinct := true
	for k in range(1, 7):
		var c: Color = canvas._trace_layer_color("in%d" % k)
		if c == top or c == bottom or seen.has(c):
			all_distinct = false
		seen[c] = true
	check("in1..in6 are distinct and never the top/bottom colour", all_distinct)
	check("in7 cycles onto in1's hue",
		canvas._trace_layer_color("in7") == canvas._trace_layer_color("in1"))
	check("malformed layer names fall back to the top colour",
		canvas._trace_layer_color("garbage") == top
		and canvas._trace_layer_color("in0") == top
		and canvas._trace_layer_color("in31") == top)
	canvas.free()
