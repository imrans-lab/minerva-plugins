extends RefCounted
## Canonical layer-stack + via-span contract (GDScript / plugin side).
##
## THE single source of truth on the GD side for the canonical copper-layer
## names, their KiCad aliases, and via-span legality, mirroring the Python
## contract in pcb/worker/agent_router/layers.py value-for-value and
## rule-for-rule (they are two languages; the GD side cannot import the Python
## one). Before T1.5 this mapping was inlined/duplicated in
## pcb_data._canon_layer_name, panel_tools ternaries and
## pcb_canvas._canonical_layer; those now all call the helpers here.
##
## Off-tree plugin: NO class_name (see sibling pcb_trace.gd) — reached via a
## relative preload():  const PcbLayerStack := preload("pcb_layer_stack.gd").
##
## Canonical copper-layer names (epoch 6 unit 3a): "top", "in1".."in30",
## "bottom" — lowercase, 1-based — aliasing KiCad "F.Cu", "In1.Cu".."In30.Cu",
## "B.Cu". The inner range stops at 30 because KiCad's copper stack does.
##
## Inner layers are AUTHORABLE, NOT FABRICABLE (the same pattern zones use).
## CANON_TO_KICAD / KICAD_TO_CANON / STACK_INDEX below stay the TWO-layer
## FABRICABLE stack on purpose: the worker's compile step builds a board's
## stackup from those tables and refuses any stack other than exactly
## ["top","bottom"]. Inner-layer naming is a FUNCTION-level rule here (see
## inner_layer_index), never a table entry.
##
## Direction asymmetry (deliberate, mirrors Python):
##  * WRITE/export side — canon_to_kicad FAILS CLOSED: an empty or unknown name
##    push_error()s and returns "" instead of defaulting to "F.Cu". A silently
##    defaulted layer name is copper on the wrong side of a fabricated board.
##  * READ/import side — kicad_to_canon FAILS VISIBLE: an unknown name still
##    passes through lower-cased (refusing would make old boards unloadable) but
##    push_warning()s so the oddball is not silent.
##
## Via spans are THROUGH-HOLE ONLY: legality derives from STACK_INDEX, which
## holds only top/bottom, so a span touching an inner layer is illegal.
## Blind/buried vias are not modeled.

## Canonical id -> KiCad copper layer alias (the one map; keep direction fixed).
## FABRICABLE stack only — do NOT add in1..in30 (see the header).
const CANON_TO_KICAD := {"top": "F.Cu", "bottom": "B.Cu"}
const KICAD_TO_CANON := {"F.Cu": "top", "B.Cu": "bottom"}
## Canonical id -> physical stack index (top = 0, outward). Via-span legality
## derives from this table rather than a hardcoded top/bottom pair.
const STACK_INDEX := {"top": 0, "bottom": 1}
## KiCad's copper stack is 32 layers (F.Cu + In1..In30 + B.Cu), so every
## canonical name accepted here HAS a KiCad alias. Mirrors MAX_INNER_LAYERS in
## agent_router/layers.py and MaxInnerLayers in internal/board/validate.go.
const MAX_INNER_LAYERS := 30


## One entry in the layer stack. Kept as a plain Dictionary (host_owned save
## conventions favour dict/JSON-friendly shapes over typed inner classes).
## An unknown layer_id yields kicad_alias "" (and a push_error from
## canon_to_kicad) rather than a silent "F.Cu" — a stack entry that lies about
## its KiCad name is worse than one that is visibly empty.
static func _entry(layer_id: String, index: int, color: Color) -> Dictionary:
	return {
		"layer_id": layer_id,
		"kicad_alias": canon_to_kicad(layer_id),
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


## Returns k for the canonical inner-copper name "in<k>", else 0.
## k must be 1..MAX_INNER_LAYERS and written without a leading zero ("in01" is
## rejected): one layer, one spelling, so a name can never compare unequal to
## itself in a list of declared layers.
static func inner_layer_index(layer_id) -> int:
	var s := str(layer_id).strip_edges().to_lower()
	if not s.begins_with("in") or s.length() < 3:
		return 0
	var digits := s.substr(2)
	for i in digits.length():
		var c := digits.unicode_at(i)
		if c < 48 or c > 57:   # ASCII 0-9 only; is_valid_int() would accept "+1"/"-1"
			return 0
	if digits.begins_with("0"):
		return 0
	var k := int(digits)
	return k if (k >= 1 and k <= MAX_INNER_LAYERS) else 0


## Returns k for a lower-cased KiCad inner name "in<k>.cu", else 0.
static func _kicad_inner_layer_index(low: String) -> int:
	if not low.begins_with("in") or not low.ends_with(".cu"):
		return 0
	return inner_layer_index("in" + low.substr(2, low.length() - 5))


## Lower-cased KiCad copper name -> canonical id, or "" if it is not one.
static func _kicad_name_to_canon(low: String) -> String:
	if low == "f.cu":
		return "top"
	if low == "b.cu":
		return "bottom"
	var k := _kicad_inner_layer_index(low)
	return ("in%d" % k) if k > 0 else ""


## True iff layer_id is a canonical copper name: "top", "bottom", or "in1".."in30".
static func is_canonical_layer(layer_id) -> bool:
	var s := str(layer_id).strip_edges().to_lower()
	return CANON_TO_KICAD.has(s) or inner_layer_index(s) > 0


## Normalises a canonical OR KiCad copper name to its canonical id; "" for
## anything else. SILENT by design — the predicates below use it, and a
## predicate that warns is a predicate nobody can call in a draw loop.
static func _canon_or_empty(layer_id) -> String:
	var low := str(layer_id).strip_edges().to_lower()
	if is_canonical_layer(low):
		return low
	return _kicad_name_to_canon(low)


## Canonical copper id ("top"/"bottom"/"in<k>") -> KiCad copper layer name.
## Idempotent: an already-KiCad name is accepted and returned in its canonical
## spelling ("f.cu" -> "F.Cu").
##
## FAILS CLOSED: an empty or unrecognised name push_error()s and returns "".
## Until epoch 6 unit 3a this returned "F.Cu" for empty input and echoed an
## unknown name unchanged; both defaults are gone, because this is the WRITE
## side — a silently defaulted layer name is copper on the wrong side of the
## board. Callers must treat "" as "refuse to export this", NOT as a layer.
static func canon_to_kicad(layer_id) -> String:
	var canon := _canon_or_empty(layer_id)
	if canon.is_empty():
		push_error("PcbLayerStack.canon_to_kicad: unknown copper layer \"%s\" — expected \"top\", \"bottom\", \"in1\"..\"in%d\", or a KiCad copper name (\"F.Cu\"/\"B.Cu\"/\"In<k>.Cu\")" % [str(layer_id), MAX_INNER_LAYERS])
		return ""
	if CANON_TO_KICAD.has(canon):
		return CANON_TO_KICAD[canon]
	return "In%d.Cu" % inner_layer_index(canon)


## KiCad copper layer name -> canonical id ("top"/"bottom"/"in<k>").
## "F.Cu"/"B.Cu"/"In<k>.Cu" map case-insensitively; an already-canonical id is
## returned unchanged (idempotent).
##
## FAILS VISIBLE, not closed: this is the READ side, so an unrecognised name
## still passes through lower-cased (and empty still yields "top") — refusing
## would make an old or foreign board unloadable — but push_warning()s so the
## oddball layer name is visible instead of silent.
static func kicad_to_canon(layer) -> String:
	var s := str(layer).strip_edges()
	var low := s.to_lower()
	var canon := _canon_or_empty(low)
	if not canon.is_empty():
		return canon
	if low.is_empty():
		push_warning("PcbLayerStack.kicad_to_canon: empty layer name mapped to \"top\"; the caller should name a layer explicitly")
		return "top"
	push_warning("PcbLayerStack.kicad_to_canon: unknown layer name \"%s\" passed through as \"%s\" — not a canonical copper id or a KiCad copper name" % [s, low])
	return low


## True iff `layer_id` (canonical or KiCad) names a copper layer, INCLUDING the
## inner layers in1..in30. Copper-ness is a NAMING question, not a fabricability
## one: an inner layer is copper and is still refused by the compiler.
## STACK_INDEX membership — not this predicate — is the test for "a layer this
## 2-layer pipeline can route and fabricate".
static func is_copper(layer_id) -> bool:
	return not _canon_or_empty(layer_id).is_empty()


## True iff a via may span from_id <-> to_id. THROUGH-HOLE ONLY: a top<->bottom
## span is legal; a same-layer, degenerate, or inner-touching span is illegal.
## Derived from STACK_INDEX, which holds only the two fabricable layers, so
## declaring inner layers does NOT make a blind/buried span legal.
##
## NOTE: blind/buried vias are not modeled at all. Supporting them needs an
## explicit span-rule/adjacency table, not merely more entries in STACK_INDEX —
## some layer PAIRS are illegal even when their indices differ. Do not mistake
## the current shape for full N-layer support.
static func is_legal_via_span(from_id, to_id) -> bool:
	var a := _canon_or_empty(from_id)
	var b := _canon_or_empty(to_id)
	if not STACK_INDEX.has(a) or not STACK_INDEX.has(b):
		return false
	return STACK_INDEX[a] != STACK_INDEX[b]
