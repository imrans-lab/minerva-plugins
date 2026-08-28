extends "res://../../minerva-plugins/pcb/ui/pcb_canvas.gd"
## A pcb_canvas that RECORDS what _draw_copper() dispatches instead of painting it.
##
## NOT a suite — a test double, so the filename deliberately does not match the
## runner's `test_*.gd` glob (pcb/scripts/run-gd-tests.sh) or its EXPECTED_SUITES
## manifest. Used by test_pcb_pad_fidelity.gd section 4.
##
## WHY IT EXISTS: pcb_canvas draws in immediate mode, so a finished frame has no
## children to index and headless runs have no render device to sample. What CAN
## be observed is the sequence of painter calls _draw_copper() makes, and every
## one of those is a method — so a subclass overriding them records the dispatch
## the real _draw_copper() performs, with no draw_* call reached at all.
##
## Every painter _draw_copper() calls per pass is overridden here. Adding a pass
## to _draw_copper without overriding its painter would let a real draw_* call
## through, which is loud (Godot refuses drawing outside NOTIFICATION_DRAW)
## rather than silent.
##
## The two ARTWORK painters (component graphics + designator) are overridden for
## the same reason, so a suite may call _draw_component_silk / _draw_staged_lands
## directly. The rest of _draw_component still paints natively — drive the
## per-layer entry points, not the whole component.

## One entry per painter call, in dispatch order:
##   kind      — "trace", "land", "drill", "vias", "graphics" or "refdes"
##   layer     — the trace's canonical copper layer, or the BOARD layer an
##               artwork pass was asked for; "" where the pass has none
##   id        — trace id, "<ref>.<pin>" for a land/drill, "<ref>" for artwork,
##               else the pass name
##   pad_type  — "smd" / "thru_hole" / "np_thru_hole" / "fallback_pin" for a
##               pad record, "" otherwise
##
## A LAND record additionally carries the geometry the painter would have drawn
## — `shape`, and the world-mm `pos` / `size` / `rot` resolved through the
## canvas's own pad_draw_geometry — plus the `alpha` it was dimmed by. That is
## what lets a PROPOSED land be compared against the committed land it becomes:
## the two must be the same shape at the same angle, or the ghost is lying about
## the copper it is previewing.
##
## An ARTWORK record carries the `count` of graphics the requested board layer
## actually selected (comp.graphics_for_placed_layer — the same selection the
## real painter walks) and the `color` the ink was asked for.
var records: Array = []


func _draw_single_trace(trace, layer_id: String) -> void:
	records.append({"kind": "trace", "layer": layer_id,
		"id": str(trace.id), "pad_type": ""})


func _draw_pad(comp, pad: Dictionary, phase: PadPhase, pose: Dictionary = {},
		alpha: float = 1.0) -> void:
	var world: Dictionary = pad_draw_geometry(comp, pad, pose)
	records.append({
		"kind": "land" if phase == PadPhase.LANDS else "drill",
		"layer": "",
		"id": "%s.%s" % [str(comp.id), str(pad.get("number", ""))],
		"pad_type": str(pad.get("type", "smd")),
		"shape": str(pad.get("shape", "rect")),
		"corner_rratio": pad.get("corner_rratio", null),
		"pos": world["position"] as Vector2,
		"size": world["size"] as Vector2,
		"rot": float(world["rotation"]),
		"alpha": alpha})


func _draw_component_graphics_layer(comp, _xform: Transform2D, layer_name: String,
		stroke_color: Color, _min_width_px: float, _origin = null) -> void:
	records.append({"kind": "graphics", "layer": layer_name, "id": str(comp.id),
		"pad_type": "", "count": comp.graphics_for_placed_layer(layer_name).size(),
		"color": stroke_color})


func _draw_component_refdes(comp, _xform: Transform2D) -> void:
	records.append({"kind": "refdes", "layer": "", "id": str(comp.id),
		"pad_type": "", "count": comp.refdes_graphics.size()})


func _draw_fallback_pins(comp, _xform: Transform2D, phase: PadPhase) -> void:
	records.append({
		"kind": "land" if phase == PadPhase.LANDS else "drill",
		"layer": "", "id": str(comp.id), "pad_type": "fallback_pin"})


func _draw_vias() -> void:
	records.append({"kind": "vias", "layer": "", "id": "vias", "pad_type": ""})


func _draw_via_drills() -> void:
	records.append({"kind": "drill", "layer": "", "id": "via_drills",
		"pad_type": ""})


func _draw_mounting_hole_drills() -> void:
	records.append({"kind": "drill", "layer": "", "id": "mounting_hole_drills",
		"pad_type": ""})
