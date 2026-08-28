extends RefCounted
## THE ORDER THE CANVAS PAINTS COPPER IN, AS DATA.
##
## A board is painted the way it is made: etched copper first, then the lands
## parts solder to, then the drilled holes as voids that clear the middle of
## every barrel. Painting a trace after the land it enters shows copper running
## across a hole no fab ever leaves filled — the trace must end UNDER the land,
## and the hole must end up empty whatever ran through it.
##
## The rule lives here rather than inside the canvas because it is pure
## ordering: it reads no node state, touches no board model and issues no draw
## call, so the order it produces can be asserted directly. pcb_canvas
## ._draw_copper() walks the returned array and does nothing but dispatch, so
## the array IS the draw order the user sees.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd) — reached via
## a relative preload():
##   const PcbCopperDrawOrder := preload("model/pcb_copper_draw_order.gd")

## Pass kinds. `layer` is meaningful on TRACES and SMD_LANDS and empty ("") on
## the three board-wide passes.
const TRACES := "traces"
const SMD_LANDS := "smd_lands"
const THT_LANDS := "tht_lands"
const VIAS := "vias"
const DRILLS := "drills"


## Build the ordered pass list.
##
## `stack_top_first` is the board's declared copper stack in the order
## pcb_canvas._stack_layers() hands it over — top-most entry FIRST. Painting
## walks it backwards so the bottom-most copper lays down first and the
## top-most lands on top of it, which is what looking down at a board shows.
##
## PER LAYER, bottom-most first: that layer's traces, then the SMD lands of the
## parts mounted on it. Interleaving matters — a bottom land drawn above every
## trace would cover a top trace crossing over it, which is the same artifact
## in the mirror.
##
## A THROUGH-HOLE land pierces every copper layer, so it is painted ONCE after
## the whole stack instead of once per layer, and vias sit with it for the same
## reason. Every drilled hole is painted last, as a void over all of the copper.
##
## `trace_layers` / `mount_layers` are the layer ids actually present on the
## board. Ids the declared stack never mentions (a malformed or out-of-stack
## layer name) still get a pass — appended above the stack, traces before
## lands — so nothing an author wrote is silently undrawn.
static func build(stack_top_first: Array, trace_layers: Array, mount_layers: Array) -> Array:
	var passes: Array = []
	var declared := {}
	for i in range(stack_top_first.size() - 1, -1, -1):
		var layer_id := str(stack_top_first[i])
		declared[layer_id] = true
		passes.append({"kind": TRACES, "layer": layer_id})
		passes.append({"kind": SMD_LANDS, "layer": layer_id})

	for tl in trace_layers:
		if not declared.has(str(tl)):
			passes.append({"kind": TRACES, "layer": str(tl)})
	for ml in mount_layers:
		if not declared.has(str(ml)):
			passes.append({"kind": SMD_LANDS, "layer": str(ml)})

	passes.append({"kind": THT_LANDS, "layer": ""})
	passes.append({"kind": VIAS, "layer": ""})
	passes.append({"kind": DRILLS, "layer": ""})
	return passes
