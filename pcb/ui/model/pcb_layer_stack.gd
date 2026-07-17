extends RefCounted
## Canonical layer-stack + via-span contract (GDScript / plugin side).
##
## THE single source of truth on the GD side for the "top"/"bottom" <-> KiCad
## "F.Cu"/"B.Cu" mapping and via-span legality, mirroring the Python contract
## in pcb/worker/agent_router/layers.py value-for-value (they are two languages;
## the GD side cannot import the Python one). Before T1.5 this mapping was
## inlined/duplicated in pcb_data._canon_layer_name, panel_tools ternaries and
## pcb_canvas._canonical_layer; those now all call the helpers here.
##
## Off-tree plugin: NO class_name (see sibling pcb_trace.gd) — reached via a
## relative preload():  const PcbLayerStack := preload("pcb_layer_stack.gd").
##
## Scope: a 2-entry (through-via) copper stack. Helpers derive legality from the
## stack index table so blind/buried layers can be added later by extending the
## stack alone. NO N-layer support is implemented today.

## Canonical id -> KiCad copper layer alias (the one map; keep direction fixed).
const CANON_TO_KICAD := {"top": "F.Cu", "bottom": "B.Cu"}
const KICAD_TO_CANON := {"F.Cu": "top", "B.Cu": "bottom"}
## Canonical id -> physical stack index (top = 0, outward). Legality derives
## from this table rather than a hardcoded top/bottom pair.
const STACK_INDEX := {"top": 0, "bottom": 1}


## One entry in the layer stack. Kept as a plain Dictionary (host_owned save
## conventions favour dict/JSON-friendly shapes over typed inner classes).
static func _entry(layer_id: String, index: int, color: Color) -> Dictionary:
	return {
		"layer_id": layer_id,
		"kicad_alias": CANON_TO_KICAD.get(layer_id, "F.Cu"),
		"index": index,
		"color": color,
		"kind": "copper",
		"routing_enabled": true,
		"visible": true,
	}


## The default 2-layer through-hole stack (top + bottom copper).
static func default_two_layer() -> Array:
	return [
		_entry("top", 0, Color(0.85, 0.2, 0.2)),
		_entry("bottom", 1, Color(0.2, 0.4, 0.85)),
	]


## The canonical span (top<->bottom) a 2-layer through-via bridges. One place
## for N-layer to later override.
static func default_through_via_span() -> Array:
	return ["top", "bottom"]


## The same default span expressed in KiCad copper names, for the legacy
## "layers" via field consumed by pcb_data._via_to_board_dict / import/export.
static func default_via_kicad_layers() -> Array:
	return [canon_to_kicad("top"), canon_to_kicad("bottom")]


## Canonical ("top"/"bottom") -> KiCad copper layer name.
## Mirrors the old route_bridge/canon_to_kicad edge cases: empty -> "F.Cu";
## an already-KiCad or unknown name passes through (only a recognised canonical
## name, case-insensitively, is remapped).
static func canon_to_kicad(layer_id) -> String:
	var s := str(layer_id).strip_edges()
	if s.is_empty():
		return "F.Cu"
	return CANON_TO_KICAD.get(s.to_lower(), s)


## KiCad copper layer name -> canonical ("top"/"bottom").
## Mirrors the old pcb_data._canon_layer_name exactly: empty -> "top";
## "F.Cu"/"B.Cu" (case-insensitive) -> top/bottom; else lower-cased passthrough.
static func kicad_to_canon(layer) -> String:
	var s := str(layer).strip_edges()
	if s.to_lower() == "f.cu":
		return "top"
	if s.to_lower() == "b.cu":
		return "bottom"
	if s.is_empty():
		return "top"
	return s.to_lower()


## True iff `layer_id` (canonical or KiCad) is a routable copper layer.
static func is_copper(layer_id) -> bool:
	return STACK_INDEX.has(kicad_to_canon(layer_id))


## True iff a via may span from_id <-> to_id. Today: a through-via top<->bottom
## is legal; same-layer/degenerate is illegal. Derived from STACK_INDEX so
## blind/buried layers become a stack-table edit, not a predicate rewrite.
##
## NOTE: this is the THROUGH-via 2-layer rule ONLY — any two distinct stack
## indices ⇒ legal. It is NOT complete multilayer legality: blind/buried spans
## (which are illegal for some layer PAIRS even when the indices differ) will
## require an explicit span-rule/adjacency table, not merely adding layers to
## STACK_INDEX. Do not mistake the current shape for full N-layer support.
static func is_legal_via_span(from_id, to_id) -> bool:
	var a := kicad_to_canon(from_id)
	var b := kicad_to_canon(to_id)
	if not STACK_INDEX.has(a) or not STACK_INDEX.has(b):
		return false
	return STACK_INDEX[a] != STACK_INDEX[b]
