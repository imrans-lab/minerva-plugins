extends RefCounted
## THE pad row — one shape for "which pad, and what do we know about it".
##
## A pad is a first-class thing a human can point at (the Pin Select tool) and
## a thing an agent has to answer about. Before this module every surface that
## described a pad invented its own dictionary, so the deictic round trip
## ("see these pins?" → get_selection → an answer) needed a per-surface
## translation. Every surface now emits THIS row and nothing else:
##
##   minerva_pcb_get_selection   the pads the human has selected
##   minerva_pcb_pin_info        the pad the agent asked about (row + the
##                               inspector's own extras: net_members, traces)
##   minerva_pcb_free_pins       the pads of one component on no net
##   minerva_pcb_move_component  where every pad of the part LANDED
##   minerva_pcb_rotate_component  ditto — so "where did pin 1 go" is not a
##                               second round trip
##
## THE ROW
##   kind            always "pad" (get_selection entries are kind-tagged)
##   ref             "REF.PIN" — the one address form; parse_ref reads it back
##   component, pin  the same address split, so a caller never re-parses
##   net             the net holding the pin, "" when free
##   position        {x_mm, y_mm} — the pad's WORLD centre
##   layer           "top" | "bottom" | "all" (a through-hole barrel is on all)
##   side            which side/COLUMN of its own component the pad sits on,
##                   board frame: "the other side of U1S" is a filter, not a
##                   coordinate scan. NOT approach_sides — see below.
##   approach_sides  which way a board-rule trace can LEAVE the pad, clear of
##                   the component's other lands (pcb_pad_approach)
##   roles           what the socket pin table says this pin is for
##                   (strapping / uart_console / …), [] when it says nothing
##
## `side` and `approach_sides` are different questions and the names are close;
## side is about the PART's geometry, approach_sides about the ROUTE's.
##
## THE PIN TABLE. Roles come from the board, never from an agent's memory of a
## devkit: a pin's canonical dict may carry `roles`, and every key beyond
## number/x_mm/y_mm round-trips verbatim through pcb_component.pin_extra, the
## Go board model's Pin.Extra and the canonical YAML. So a socket's pin table
## is authored once in the board document and read here. A board that declares
## nothing gets [] and says so, rather than a guess.
##
## Off-tree module — NO class_name, reached by relative preload.

const _PcbPadApproach := preload("pcb_pad_approach.gd")

## The roles the free-pins read and the UI know how to talk about. NOT a
## whitelist: a board may declare its own vocabulary and it is passed through
## untouched — this list is what the docs and the sidebar are written against.
const ROLE_VOCABULARY: Array[String] = [
	"strapping", "uart_console", "jtag", "onboard_led", "adc",
]

## Pad `type` values whose barrel goes through every copper layer. Same list as
## pcb_canvas.THT_PAD_TYPES; duplicated here rather than reaching into a Control
## from a model module (this file is loaded headless, with no canvas at all).
const THT_PAD_TYPES: Array[String] = ["thru_hole", "np_thru_hole"]

## Below this the component's pad cloud has no extent on that axis, so the axis
## cannot say which side a pad is on.
const _SIDE_EXTENT_EPSILON_MM := 0.001


## "REF.PIN" → ["REF", "PIN"], or [] when it is not one. Split at the LAST dot:
## a refdes may contain dots, a pin number may not.
static func parse_ref(ref: String) -> Array:
	var dot := ref.rfind(".")
	if dot <= 0 or dot >= ref.length() - 1:
		return []
	return [ref.left(dot), ref.substr(dot + 1)]


static func make_ref(component_id: String, pin: String) -> String:
	return "%s.%s" % [component_id, pin]


## THE row for one pin of one component. `data` supplies the net and the board's
## design rules; pass null for a geometry-only row (net "" and all four
## approach sides). {} when the component does not carry the pin.
static func row(data, comp, pin: String) -> Dictionary:
	if comp == null or not comp.pins.has(pin):
		return {}
	var world: Vector2 = comp.get_pin_world_position(pin)
	var net: String = ""
	var approach: Array = ["north", "east", "south", "west"]
	if data != null:
		net = str(data.find_net_for_pin(str(comp.id), pin))
		var rules: Array = _PcbPadApproach.board_rules(data)
		approach = Array(_PcbPadApproach.pin_approach_sides(comp, pin,
			float(rules[0]), float(rules[1])))
	return {
		"kind": "pad",
		"ref": make_ref(str(comp.id), pin),
		"component": str(comp.id),
		"pin": pin,
		"net": net,
		"position": {"x_mm": _mm(world.x), "y_mm": _mm(world.y)},
		"layer": layer_for_pin(comp, pin),
		"side": side_for_pin(comp, pin),
		"approach_sides": approach,
		"roles": roles_for_pin(comp, pin),
	}


## Every pin of one component as a row, sorted by pin number so two reads of an
## unchanged board are byte-identical.
static func rows_for_component(data, comp) -> Array:
	if comp == null:
		return []
	var keys: Array = comp.pins.keys()
	keys.sort()
	var out: Array = []
	for pin in keys:
		var r := row(data, comp, str(pin))
		if not r.is_empty():
			out.append(r)
	return out


## Rows for a list of "REF.PIN" addresses, in the order given. A ref naming a
## component or pin the board does not have contributes nothing — the caller's
## own list length is what says whether anything was dropped.
static func rows_for_refs(data, refs: Array) -> Array:
	var out: Array = []
	if data == null:
		return out
	for raw in refs:
		var parts := parse_ref(str(raw))
		if parts.is_empty():
			continue
		var comp = data.get_component(str(parts[0]))
		if comp == null:
			continue
		var r := row(data, comp, str(parts[1]))
		if not r.is_empty():
			out.append(r)
	return out


## The component's pins on NO net — what is available to route to.
## `side` ("", or north/east/south/west) keeps only the pads on that side of the
## part; `exclude_roles` drops pads carrying any of those roles (the owner's
## live filter: no strapping, no UART console, no onboard LED).
static func free_pins(data, comp, side: String = "",
		exclude_roles: Array = []) -> Array:
	var wanted_side := side.strip_edges().to_lower()
	var banned := {}
	for r in exclude_roles:
		banned[str(r).strip_edges().to_lower()] = true
	var out: Array = []
	for r in rows_for_component(data, comp):
		var pad: Dictionary = r
		if not str(pad.get("net", "")).is_empty():
			continue
		if not wanted_side.is_empty() and str(pad.get("side", "")) != wanted_side:
			continue
		var blocked := false
		for role in (pad.get("roles", []) as Array):
			if banned.has(str(role)):
				blocked = true
				break
		if blocked:
			continue
		out.append(pad)
	return out


## What the board's pin table says this pin is for. Authored per pin as
## `roles: [strapping, adc]` (or one comma-separated string) and preserved
## verbatim through pin_extra; [] when the board declares nothing.
static func roles_for_pin(comp, pin: String) -> Array:
	if comp == null:
		return []
	var extras = comp.pin_extra.get(pin, {})
	if not (extras is Dictionary):
		return []
	var raw = (extras as Dictionary).get("roles", null)
	var listed: Array = []
	if raw is Array:
		listed = raw as Array
	elif raw is String and not (raw as String).strip_edges().is_empty():
		listed = (raw as String).split(",", false)
	var out: Array = []
	for item in listed:
		var role := str(item).strip_edges().to_lower()
		if not role.is_empty() and not out.has(role):
			out.append(role)
	return out


## The side (column) of its own component a pad sits on, in BOARD frame:
## north = -y, south = +y, east = +x, west = -x, matching pcb_pad_approach.
##
## The rule is the pad cloud's own box: a pin is on the side whose edge it lies
## nearest, measured as a FRACTION of that axis's extent so a tall two-column
## socket and a wide QFN are judged the same way. A corner pin ties at 0 on both
## axes and the SHORTER axis wins — for a socket that is the column axis, which
## is what "the east column of U1S" means. A part with one pin, or no extent on
## either axis, has no side and says "".
static func side_for_pin(comp, pin: String) -> String:
	if comp == null or not comp.pins.has(pin) or comp.pins.size() < 2:
		return ""
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for key in comp.pins:
		var p: Vector2 = comp.get_pin_world_position(str(key))
		min_p = min_p.min(p)
		max_p = max_p.max(p)
	var here: Vector2 = comp.get_pin_world_position(pin)
	var extent := max_p - min_p

	var best_x := ""
	var frac_x := INF
	if extent.x > _SIDE_EXTENT_EPSILON_MM:
		var west := (here.x - min_p.x) / extent.x
		var east := (max_p.x - here.x) / extent.x
		best_x = "west" if west <= east else "east"
		frac_x = minf(west, east)

	var best_y := ""
	var frac_y := INF
	if extent.y > _SIDE_EXTENT_EPSILON_MM:
		var north := (here.y - min_p.y) / extent.y
		var south := (max_p.y - here.y) / extent.y
		best_y = "north" if north <= south else "south"
		frac_y = minf(north, south)

	if best_x.is_empty() and best_y.is_empty():
		return ""
	if best_y.is_empty():
		return best_x
	if best_x.is_empty():
		return best_y
	if absf(frac_x - frac_y) < 1e-6:
		return best_x if extent.x <= extent.y else best_y
	return best_x if frac_x < frac_y else best_y


## Which copper the pad is on: "all" for a PLATED through-hole barrel, "none"
## for an unplated one, else the side its land declares, else the side the part
## is mounted on. A pin with no land geometry (a bare point pin) answers with
## the part's own layer.
##
## AN UNPLATED HOLE IS NOT ON EVERY LAYER, it is on no layer: it is drilled and
## never plated, so there is no barrel and no copper. It used to answer "all" —
## the same word the one pad that really does reach every layer uses — which
## read as "this mechanical hole is the best-connected pin on the part".
## "none" is the same reading pcb_copper_contact.physical_pad_node takes (it
## returns a no_copper_node there), so the row and the contact predicate agree.
##
## ONE LOGICAL PIN MAY OWN SEVERAL PHYSICAL LANDS, and the answer comes from
## the ones that CARRY COPPER — every land is read, not just the first. A pin
## whose np_thru_hole land happens to be listed before its smd land is the
## common shape (a plated-slot part, a shielding pin drilled and soldered),
## and reading only the first record answered "none" for a pin that is plainly
## on the front: the pad renders, routes and is committed to, while the row and
## every consumer downstream of it call it copper-less. NPTH lands are ignored
## here rather than voting; "none" is the answer only when NO land carries
## copper.
static func layer_for_pin(comp, pin: String) -> String:
	if comp == null:
		return ""
	var matched := false
	var has_copper := false
	var has_front := false
	var has_back := false
	for raw in comp.pads:
		var land: Dictionary = raw
		if str(land.get("number", "")) != pin:
			continue
		matched = true
		var land_type := str(land.get("type", "smd"))
		if land_type == "np_thru_hole":
			continue
		has_copper = true
		if land_type in THT_PAD_TYPES:
			return "all"
		for l in land.get("layers", []) as Array:
			var name := str(l)
			if name.begins_with("F."):
				has_front = true
			elif name.begins_with("B."):
				has_back = true
	if matched and not has_copper:
		return "none"
	# Both sides (or neither) named across the copper lands is no single side to
	# report, so the part's own mounting layer answers — the same fall-through a
	# land with no `layers` at all has always taken.
	if has_front and not has_back:
		return "top"
	if has_back and not has_front:
		return "bottom"
	return str(comp.layer)


## Board coordinates are reported at the same quantum every other pcb reply
## uses (panel_tools._mm), so a row and a position read never disagree in the
## last digits.
static func _mm(value: float) -> float:
	return snapped(value, 0.0001)
