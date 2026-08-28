extends SceneTree
## THE FOUR CONTRACTS A PART'S GEOMETRY OWES ITS READERS, none of which needs
## a worker: which way a rotation WORD turns the part on screen, which side of a
## two-column part a pin is on, what a component's own `pads` key means, and
## which name its printed designator draws.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_part_geometry_contracts.gd
##
## ── WHAT EACH SECTION COVERS ─────────────────────────────────────────────────
##
##   1. THE ROTATION WORDS MEAN WHAT THE EYE SEES.
##      Every assertion here is made on WHERE A PAD LANDED, never on the
##      rotation number — the number is KiCad's and is deliberately unchanged,
##      so a suite that asserted "clockwise sets 270" would be re-stating the
##      implementation. The oracle is the screen: on the panel's y-down board
##      frame, west is 9 o'clock and north is 12, so a pad that goes west→north
##      has turned clockwise. The numeric convention is pinned in the same
##      section, unchanged, so the fix cannot be mistaken for a sign flip in
##      the transform.
##
##   2. A TWO-COLUMN PART READS ITS COLUMNS AS ITS SIDES. A WIDE 2x3 DIP is
##      the case the bounding-box rule gets backwards: its shorter axis is the vertical one, so its corner pins
##      tied onto north/south and free_pins side:"west" answered with the
##      middle pin alone. The TALL socket is asserted in the same section
##      against the same rule — its answer must not move — and a single-column
##      header proves the structural rule does not swallow the row case.
##
##   3. THE `pads` KEY IS THE BOARD'S GEOMETRY AUTHORITY, not a payload
##      optimisation. Covered where the drop lives:
##      test_canonical_wire_board.gd section C. This suite states the model
##      half — a component that carries pads emits the key, and a pins-only one
##      does not — because the wire rule is only sound if the key means what it
##      says.
##
##   4. THE DRAWN DESIGNATOR IS A RENDER OF THE LIVE REF, not a stored picture
##      of the ref it was rendered from. Section 4 states it over the whole
##      lifecycle a picture used to survive: rename, copy, board-dict load and
##      panel-state restore.
##
## FAILS AGAINST OLD: section 1's two word cases land on the opposite sides;
## section 2's DIP case returns one pin where three are asserted; section 4's
## copy and load cases draw the ref they were copied from.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PcbPadRow := preload("res://../../minerva-plugins/pcb/ui/model/pcb_pad_row.gd")

## Board mm tolerance — coordinates ride through float32 Vector2 and leave
## quantized to 0.1 um, so an exact == against a float64 literal is a coin toss.
const EPS_MM := 1.0e-4

## The rotating part: two pads on the x axis, pad 1 WEST of the origin. One
## axis only, so "which side did pad 1 land on" has exactly one answer.
const PIVOT_AT := Vector2(30.0, 30.0)
const PAD_OFFSET_MM := 2.54

## The WIDE 2x3 DIP (Package_DIP:DIP-6_W7.62mm_Socket's own numbers): 7.62 mm
## between the columns, 2.54 mm between the rows — so the part is WIDER than it
## is tall, which is exactly what the box heuristic gets wrong.
const DIP_HALF_W := 3.81
const DIP_ROW_PITCH := 2.54

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Part geometry contracts: rotation words, pad-row sides, the pads key, the drawn designator ===\n")
	await _run_rotation_words_land_where_the_eye_expects()
	await _run_two_column_parts_read_columns_as_sides()
	_run_the_pads_key_is_an_authority_claim()
	_run_the_drawn_designator_is_the_live_ref()
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


# ── the host: duck-typed, model only ─────────────────────────────────────────
#
# panel_tools reaches its board through get_board_data() and nothing else for
# every verb this suite drives, so a two-method stand-in is the whole host. No
# panel, no canvas, no worker: these three contracts are model facts and a
# suite that needed a mounted panel to state them would be testing the mount.

class ModelHost extends Node:
	var data = null
	func get_board_data():
		return data
	func get_panel():
		return null


func _host() -> ModelHost:
	var host := ModelHost.new()
	host.data = PCBData.new()
	get_root().add_child(host)
	return host


## The two-pad pivot part, pad 1 at local -x (WEST), pad 2 at local +x (EAST).
func _add_pivot(data) -> void:
	var comp = data.new_component()
	comp.id = "P1"
	comp.set_footprint_by_name("CUSTOM")
	comp.position = PIVOT_AT
	comp.rotation = 0.0
	comp.pins = {"1": Vector2(-PAD_OFFSET_MM, 0.0), "2": Vector2(PAD_OFFSET_MM, 0.0)}
	data.add_component(comp)


## Which compass side of the part's origin a pad LANDED on, read off the reply's
## own pad row. "" when it is on neither axis by more than the tolerance — which
## is itself an answer worth failing on.
func _landed_side(reply: Dictionary, pin: String) -> String:
	for row in (reply.get("pads", []) as Array):
		if not (row is Dictionary) or str((row as Dictionary).get("pin", "")) != pin:
			continue
		var pos: Dictionary = (row as Dictionary).get("position", {})
		var dx := float(pos.get("x_mm", 0.0)) - PIVOT_AT.x
		var dy := float(pos.get("y_mm", 0.0)) - PIVOT_AT.y
		if absf(dx) > absf(dy) + EPS_MM:
			return "east" if dx > 0.0 else "west"
		if absf(dy) > absf(dx) + EPS_MM:
			# y-DOWN board frame: +y is toward the bottom of the screen.
			return "south" if dy > 0.0 else "north"
		return ""
	return ""


func _rotate(host, degrees) -> Dictionary:
	return await PanelTools.handle(host, "minerva_pcb_rotate_component", {
		"editor_name": "RotationProbe", "component_id": "P1", "degrees": degrees})


# ── 1. the rotation words land where the eye expects ─────────────────────────

func _run_rotation_words_land_where_the_eye_expects() -> void:
	print("-- 1. 'clockwise' turns the part clockwise ON SCREEN --")
	var host := _host()
	_add_pivot(host.data)

	# The premise, stated before anything is claimed about it: pad 1 starts WEST.
	# Every verdict below is "which side is pad 1 on now", so a fixture whose
	# pad 1 did not start west would make all of them meaningless.
	var at_rest := await _rotate(host, 0.0)
	check("pad 1 starts WEST of the origin (the premise the rest reads against)",
		_landed_side(at_rest, "1") == "west")

	var cw := await _rotate(host, "clockwise")
	check("'clockwise' from 0 lands pad 1 NORTH — west→north is a clockwise quarter turn on screen (got %s)" % _landed_side(cw, "1"),
		_landed_side(cw, "1") == "north")

	# Back to rest, then the other word, so each is measured from the same pose.
	await _rotate(host, 0.0)
	var ccw := await _rotate(host, "counterclockwise")
	check("'counterclockwise' from 0 lands pad 1 SOUTH — the other way round the same clock (got %s)" % _landed_side(ccw, "1"),
		_landed_side(ccw, "1") == "south")

	# THE NUMBER IS UNTOUCHED. rotation_deg stays KiCad's, which the worker's
	# emitters share: a fix that had flipped the transform's sign would move
	# this and desync every 90/270 part from the fab.
	await _rotate(host, 0.0)
	var at_90 := await _rotate(host, 90.0)
	check("degrees:90 still lands the west pad SOUTH — the KiCad number is unchanged (got %s)" % _landed_side(at_90, "1"),
		_landed_side(at_90, "1") == "south")
	var at_270 := await _rotate(host, 270.0)
	check("degrees:270 still lands the west pad NORTH (got %s)" % _landed_side(at_270, "1"),
		_landed_side(at_270, "1") == "north")

	# The keyboard gesture and the verb read ONE arithmetic authority, so the
	# canvas R key cannot drift back to the old vocabulary on its own.
	check("PCBComponent.clockwise_from(0) == 270 — the same turn the verb makes",
		is_equal_approx(PCBComponent.clockwise_from(0.0), 270.0))
	check("PCBComponent.counterclockwise_from(0) == 90",
		is_equal_approx(PCBComponent.counterclockwise_from(0.0), 90.0))
	var spun = PCBComponent.new()
	spun.set_rotation(0.0)
	spun.rotate_clockwise()
	check("rotate_clockwise() (the canvas R key) makes the SAME turn as the verb's word",
		is_equal_approx(spun.rotation, 270.0))

	# A word the verb does not know is a REFUSAL, not a silent no-op that
	# reports the unturned rotation back as if it had done something.
	var nonsense := await _rotate(host, "widdershins")
	check("an unknown rotation word is refused by name, not silently ignored",
		not bool(nonsense.get("success", false)))

	host.queue_free()


# ── 2. a two-column part reads its columns as its sides ──────────────────────

## A dual-column part: `rows` pins per column, columns at ±DIP_HALF_W, rows on
## DIP_ROW_PITCH. Pin numbering walks the west column down then the east column
## up, which is the DIP convention.
func _add_dual_column(data, id: String, rows: int) -> void:
	var comp = data.new_component()
	comp.id = id
	comp.set_footprint_by_name("CUSTOM")
	comp.position = Vector2(20.0, 20.0)
	comp.rotation = 0.0
	var pins := {}
	var span := (rows - 1) * DIP_ROW_PITCH
	for i in range(rows):
		var y := -span * 0.5 + i * DIP_ROW_PITCH
		pins[str(i + 1)] = Vector2(-DIP_HALF_W, y)
		pins[str(2 * rows - i)] = Vector2(DIP_HALF_W, y)
	comp.pins = pins
	data.add_component(comp)


## The bounding extent of a part's PIN CENTRES, which is what side_for_pin
## measures — not get_bounding_rect(), whose body box for a pins-only component
## is an unrelated default.
func _pin_cloud_extent(comp) -> Vector2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for pin in comp.pins:
		var p: Vector2 = comp.get_pin_world_position(str(pin))
		lo = lo.min(p)
		hi = hi.max(p)
	return hi - lo


func _sides(data, id: String) -> Dictionary:
	var comp = data.get_component(id)
	var out := {}
	for pin in comp.pins:
		var side := PcbPadRow.side_for_pin(comp, str(pin))
		out[side] = int(out.get(side, 0)) + 1
	return out


func _run_two_column_parts_read_columns_as_sides() -> void:
	print("-- 2. two columns are west/east, whatever the part's aspect --")
	var data = PCBData.new()

	# THE WIDE CASE: 3 rows over a 7.62 mm column gap is 7.62 wide x 5.08 tall.
	# State that it IS wider than tall, so the assertion below is known to be
	# exercising the aspect the box heuristic gets backwards rather than
	# passing for an unrelated reason.
	_add_dual_column(data, "J7", 3)
	var j7 = data.get_component("J7")
	var span := _pin_cloud_extent(j7)
	check("the DIP-6 fixture's PIN CLOUD really is wider than it is tall (%0.2f x %0.2f)" % [span.x, span.y],
		span.x > span.y)

	var wide := _sides(data, "J7")
	check("a wide 2x3 DIP puts THREE pins west (got %d)" % int(wide.get("west", 0)),
		int(wide.get("west", 0)) == 3)
	check("…and three east (got %d)" % int(wide.get("east", 0)),
		int(wide.get("east", 0)) == 3)
	check("…and none north or south — the columns ARE the sides",
		int(wide.get("north", 0)) == 0 and int(wide.get("south", 0)) == 0)

	# The verb the human actually calls, over the same part. All six pins are
	# free (no nets on this board), so side:"west" must list exactly the three.
	var host := _host()
	host.data = data
	var free_west: Dictionary = await PanelTools.handle(host, "minerva_pcb_free_pins", {
		"editor_name": "SideProbe", "component_id": "J7", "side": "west"})
	check("free_pins side:'west' on the 2x3 DIP returns three pins (got %d)"
			% int(free_west.get("free_count", -1)),
		int(free_west.get("free_count", -1)) == 3)
	var west_pins: Array = []
	for row in (free_west.get("free_pins", []) as Array):
		west_pins.append(str((row as Dictionary).get("pin", "")))
	west_pins.sort()
	check("…and they are pins 1, 2, 3 — the west column, not the middle pin alone (got %s)"
			% str(west_pins),
		west_pins == ["1", "2", "3"])

	# THE TALL CASE, unchanged: a 2x22 socket's columns were already what the
	# old tie-break picked, and this fix must not move that answer.
	_add_dual_column(data, "U1S", 22)
	var tall := _sides(data, "U1S")
	check("a tall 2x22 socket still puts 22 pins west (got %d)" % int(tall.get("west", 0)),
		int(tall.get("west", 0)) == 22)
	check("…and 22 east (got %d)" % int(tall.get("east", 0)),
		int(tall.get("east", 0)) == 22)

	# THE ROW CASE: a single-column 1x2 header has two ROWS and one column, so
	# the structural rule must answer north/south — proof it reads the pin
	# cloud's structure rather than always preferring x.
	var header = data.new_component()
	header.id = "J9"
	header.set_footprint_by_name("CUSTOM")
	header.position = Vector2(40.0, 40.0)
	header.pins = {"1": Vector2(0.0, -1.27), "2": Vector2(0.0, 1.27)}
	data.add_component(header)
	check("a single-column 1x2 header reads its pins as north/south",
		PcbPadRow.side_for_pin(header, "1") == "north"
			and PcbPadRow.side_for_pin(header, "2") == "south")

	host.queue_free()


# ── 3. the pads key is an authority claim ────────────────────────────────────

func _run_the_pads_key_is_an_authority_claim() -> void:
	print("-- 3. `pads` is emitted only when the board owns the geometry --")
	var pins_only = PCBComponent.new()
	pins_only.id = "X1"
	pins_only.set_footprint_by_name("HEADER")
	pins_only.pins = {"1": Vector2.ZERO}
	check("a pins-only component emits NO pads key — the worker must resolve its footprint",
		not pins_only.to_board_dict().has("pads"))

	var carrying = PCBComponent.new()
	carrying.id = "X2"
	carrying.set_footprint_by_name("CUSTOM")
	carrying.load_pad_geometry({
		"footprint_id": "NoSuchLib:P9_Custom", "has_pad_geometry": true,
		"pads": [{"number": "1", "type": "smd", "shape": "rect",
			"position": {"x": 0.0, "y": 0.0},
			"size": {"width": 2.0, "height": 2.0}, "layers": ["F.Cu"]}]})
	var carried: Dictionary = carrying.to_board_dict()
	check("a component carrying lands emits the pads key", carried.has("pads"))
	check("…and its authored ref, not the CUSTOM rendering bucket",
		str(carried.get("footprint", "")) == "NoSuchLib:P9_Custom")

	# The wire projection must not strip THAT part's lands: its ref is
	# library-SHAPED but nothing resolved it, so the board is the only place
	# its geometry exists. (The full rule table lives in
	# test_canonical_wire_board.gd section C; this is the end-to-end statement
	# over a real component rather than a hand-built dict.)
	var wired: Dictionary = PanelTools.canonical_wire_board(
		{"components": [carried]})
	check("canonical_wire_board keeps the lands of an unresolved colon-ref part",
		((wired["components"][0] as Dictionary).get("pads", []) as Array).size() == 1)

	var resolved: Dictionary = carried.duplicate(true)
	resolved["footprint_resolved"] = true
	var wired_resolved: Dictionary = PanelTools.canonical_wire_board(
		{"components": [resolved]})
	check("…and still drops them for a part the library provably resolved (the payload relief)",
		not (wired_resolved["components"][0] as Dictionary).has("pads"))


# ── 4. The drawn designator is a RENDER of the live ref ──────────────────────
#
# A designator exists nowhere in the authored board: it is glyph geometry, and
# somebody has to synthesize it. The panel used to be handed the worker's
# rendering and to store it — on the component, in panel state, and (through
# the canonical passthrough) in the saved board. A rendering of a ref is a
# picture of ONE name, so the picture outlived the name: a part copied from its
# neighbour kept drawing the neighbour's designator, on screen and in every
# board written afterwards, until something re-resolved it. JP6 on
# smart-remote-v2 drew JP5 (bug 01a047a3ae10).
#
# The strokes are derived now — a render of `id` at `refdes_anchor`, refreshed
# by both setters — so the questions below have only one possible answer.

## The far-offset authored anchor: a footprint that says where its reference
## goes. Deliberately nowhere near the default (x-centred, y = -1.5), so a
## renderer that ignored the anchor cannot accidentally satisfy the assertion.
const AUTHORED_ANCHOR := {"x_mm": 12.7, "y_mm": -1.9, "rotation_deg": 0.0,
	"size_mm": 1.2, "hidden": false}


## A bare component carrying a ref and an anchor — the only two inputs the
## designator has. Used as the ORACLE: whatever a renamed, copied or reloaded
## part draws must equal what a part freshly named that draws.
func _part(ref: String, anchor: Dictionary = AUTHORED_ANCHOR):
	var comp = PCBComponent.new()
	comp.id = ref
	comp.set_footprint_by_name("CUSTOM")
	comp.refdes_anchor = anchor
	return comp


func _stroke_x_extent(comp) -> Vector2:
	var lo := INF
	var hi := -INF
	for g in comp.refdes_graphics:
		for pt in g["points"]:
			var p: Vector2 = pt
			lo = minf(lo, p.x)
			hi = maxf(hi, p.x)
	return Vector2(lo, hi)


func _run_the_drawn_designator_is_the_live_ref() -> void:
	print("-- 4. the drawn designator is a render of the live ref --")
	var jp5 = _part("JP5")
	var jp6 = _part("JP6")
	check("a component strokes its designator at all",
		jp5.refdes_graphics.size() > 0 and jp6.refdes_graphics.size() > 0)

	var extent: Vector2 = _stroke_x_extent(jp5)
	check("…at the footprint's AUTHORED anchor, not the default one",
		extent.x <= AUTHORED_ANCHOR["x_mm"] and AUTHORED_ANCHOR["x_mm"] <= extent.y
			and _stroke_x_extent(_part("JP5", {})).y < AUTHORED_ANCHOR["x_mm"])

	# RENAME. The strokes are not a cache anyone has to remember to invalidate.
	var renamed = _part("JP5")
	renamed.id = "JP6"
	check("a rename redraws the designator: it becomes JP6's, and stops being JP5's",
		renamed.refdes_graphics == jp6.refdes_graphics
			and renamed.refdes_graphics != jp5.refdes_graphics)

	# COPY — the reported defect. The copy carries the source's anchor (same
	# footprint) but its own name, and must draw its own name.
	var copied = jp5.duplicate_component()
	copied.id = "JP6"
	check("a copy renamed JP6 draws JP6 — not the strokes it was copied from",
		copied.refdes_graphics == jp6.refdes_graphics)

	# LOAD. The exact shape of the owner's board: JP6's entry carrying JP5's
	# rendering, byte-for-byte, because the two were copies.
	var stale: Dictionary = jp6.to_board_dict()
	stale["refdes_graphics"] = [{"layer": "F.SilkS", "kind": "poly", "width": 0.15,
		"points": [{"x": 0.0, "y": -1.5}, {"x": 0.5, "y": -1.5}]}]
	stale["refdes_anchor"] = AUTHORED_ANCHOR
	var loaded = PCBComponent.new()
	loaded.load_from_board_dict(stale)
	check("a board dict carrying a stale rendering loads showing the component's OWN ref",
		loaded.refdes_graphics == jp6.refdes_graphics)
	check("…and the stale rendering does not come back out — no saved board or promote YAML can carry one",
		not loaded.to_board_dict().has("refdes_graphics"))

	# HIDDEN. A hidden reference prints nothing, so it must draw nothing —
	# the same ruling the emitter applies at its one glyph owner.
	var hidden = _part("U9", {"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0,
		"size_mm": 1.0, "hidden": true})
	check("a footprint whose reference is authored HIDDEN draws no designator",
		hidden.refdes_graphics.is_empty())

	# PANEL STATE. A restore does not re-resolve, so the anchor has to survive
	# it — the strokes are then re-derived rather than restored.
	var restored = PCBComponent.from_dict(jp5.to_dict())
	check("a panel-state round trip keeps the anchor and redraws the same designator",
		restored.refdes_anchor == jp5.refdes_anchor
			and restored.refdes_graphics == jp5.refdes_graphics)
