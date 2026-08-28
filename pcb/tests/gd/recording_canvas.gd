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

## One entry per painter call, in dispatch order:
##   kind      — "trace", "land", "drill", or "vias"
##   layer     — the trace's canonical copper layer; "" where the pass has none
##   id        — trace id, "<ref>.<pin>" for a land/drill, else the pass name
##   pad_type  — "smd" / "thru_hole" / "np_thru_hole" / "fallback_pin" for a
##               pad record, "" otherwise
var records: Array = []


func _draw_single_trace(trace, layer_id: String) -> void:
	records.append({"kind": "trace", "layer": layer_id,
		"id": str(trace.id), "pad_type": ""})


func _draw_pad(comp, pad: Dictionary, phase: PadPhase) -> void:
	records.append({
		"kind": "land" if phase == PadPhase.LANDS else "drill",
		"layer": "",
		"id": "%s.%s" % [str(comp.id), str(pad.get("number", ""))],
		"pad_type": str(pad.get("type", "smd"))})


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
