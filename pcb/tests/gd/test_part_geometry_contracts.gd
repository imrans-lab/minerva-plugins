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
##      half — a component that carries pads emits the key, a pins-only one does
##      not, and a dict stating lands under no has_pad_geometry flag still reads
##      fabricable through BOTH deserializers (the board contract's
##      load_from_board_dict and the legacy load_from_dict/from_dict pair) —
##      because the wire rule is only sound if the key means what it says, on
##      the write side and on every read side.
##
##   4. THE DRAWN DESIGNATOR IS A RENDER OF THE LIVE REF, not a stored picture
##      of the ref it was rendered from. Section 4 states it over the whole
##      lifecycle a picture used to survive: rename, copy, board-dict load and
##      panel-state restore — and pins one designator against a stroke vector
##      taken from the WORKER's font, so the two fonts cannot drift apart while
##      each stays internally consistent. It closes on WHERE the designator
##      lands: a resolved part draws its ref clear of its own courtyard, which
##      is the panel half of a rule the fab silk and the DRC projection share.
##
## FAILS AGAINST OLD: section 1's two word cases land on the opposite sides;
## section 2's DIP case returns one pin where three are asserted; section 4's
## copy and load cases draw the ref they were copied from, and its courtyard
## case draws SW2's designator inside the switch body.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PCBComponent := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PcbPadRow := preload("res://../../minerva-plugins/pcb/ui/model/pcb_pad_row.gd")
const PcbLibraryPart := preload("res://../../minerva-plugins/pcb/ui/model/pcb_library_part.gd")
const PcbRefdesAnchor := preload("res://../../minerva-plugins/pcb/ui/model/pcb_refdes_anchor.gd")

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
	await _run_the_designator_anchor_is_movable()
	await _run_the_placement_is_board_state()
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

	# THE KEY IS THE AUTHORITY; `has_pad_geometry` is only an extra marker of it.
	# The worker compiles a component FULL on the `pads` KEY alone
	# (inline_footprint.carries_full_geometry) and writes the flag only on its
	# own resolve path, so a board can legitimately state real lands and no
	# flag. The panel must agree, or the canvas would badge unbuildable a part
	# the fab builds from the board's own geometry. load_from_board_dict is
	# where the two spellings become one rule — a non-empty pads list sets the
	# flag — and these two assertions are what hold that.
	var flagless = PCBComponent.new()
	flagless.load_from_board_dict({
		"id": "R9", "footprint": "NoSuchLib:R_0603_Authored",
		"x_mm": 12.0, "y_mm": 8.0,
		"pads": [
			{"number": "1", "type": "smd", "shape": "rect",
				"position": {"x": -0.75, "y": 0.0},
				"size": {"width": 0.9, "height": 0.95}, "layers": ["F.Cu"]},
			{"number": "2", "type": "smd", "shape": "rect",
				"position": {"x": 0.75, "y": 0.0},
				"size": {"width": 0.9, "height": 0.95}, "layers": ["F.Cu"]}]})
	check("a pads-list part carrying NO has_pad_geometry flag loads with real lands",
		flagless.pads.size() == 2 and flagless.pads_authored)
	check("…and reads FABRICABLE — the key is the authority, the flag only marks it",
		PcbLibraryPart.is_fabricable(flagless))
	check("…with geometry source 'authored': the board owns those lands, no library did",
		str(PcbLibraryPart.geometry_state(flagless).get("source", "")) == "authored")

	# THE OTHER DOOR. load_from_board_dict reads the board contract; panel state
	# and .minpcb snapshots come in through the legacy load_from_dict/from_dict
	# pair, which is a separate parse of the same `pads` key (its own
	# `pads_authored = raw_pads is Array`, its own position/pins spelling). The
	# authority rule has to hold on both or the same part reads fabricable from
	# a board and unbuildable the moment the session restores it.
	var flagless_legacy = PCBComponent.from_dict({
		"id": "R9", "footprint": "NoSuchLib:R_0603_Authored",
		"position": {"x": 12.0, "y": 8.0},
		"pads": [
			{"number": "1", "type": "smd", "shape": "rect",
				"position": {"x": -0.75, "y": 0.0},
				"size": {"width": 0.9, "height": 0.95}, "layers": ["F.Cu"]},
			{"number": "2", "type": "smd", "shape": "rect",
				"position": {"x": 0.75, "y": 0.0},
				"size": {"width": 0.9, "height": 0.95}, "layers": ["F.Cu"]}]})
	check("the legacy from_dict/load_from_dict door reads the same flagless pads "
		+ "list as real lands",
		flagless_legacy.pads.size() == 2 and flagless_legacy.pads_authored)
	check("…and reads FABRICABLE through that door too",
		PcbLibraryPart.is_fabricable(flagless_legacy))
	check("…with the same 'authored' geometry source",
		str(PcbLibraryPart.geometry_state(flagless_legacy).get("source", "")) == "authored")


# ── 4. The drawn designator is a RENDER of the live ref ──────────────────────
#
# A designator exists nowhere in the authored board: it is glyph geometry, and
# somebody has to synthesize it. The panel used to be handed the worker's
# rendering and to store it — on the component, in panel state, and (through
# the canonical passthrough) in the saved board. A rendering of a ref is a
# picture of ONE name, so the picture outlived the name: a part copied from its
# neighbour kept drawing the neighbour's designator, on screen and in every
# board written afterwards, until something re-resolved it. JP6 on
# smart-remote-v2 drew JP5.
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

	# THE INDEPENDENT ORACLE. Every assertion above renders the expected value
	# with the SAME PcbBoardFont as the value under test, so a panel font that
	# drifted from the worker's would satisfy all of them and the editor would
	# draw a designator the fab does not print. These numbers come from the
	# WORKER's font instead (see J1_DEFAULT_STROKES), and
	# worker/tests/test_board_font.py pins the same list on its side.
	var j1 = PCBComponent.new()
	j1.id = "J1"
	check("a J1 at the DEFAULT anchor strokes the worker font's own J1, to 1e-6 mm",
		_strokes_match(j1.refdes_graphics, J1_DEFAULT_STROKES))

	_check_the_designator_clears_the_courtyard()


## The switch-shaped footprint the worker derives an anchor for: a courtyard
## spanning local y -3.3 .. +3.4, x -4.25 .. +4.25 (the seat of a 6x6 tactile
## switch), and the anchor a resolve sends for it.
##
## WHY A LITERAL. The panel does not derive this — the worker does
## (worker/pcb_worker/refdes_anchor.py: the courtyard's top edge, minus a
## 0.25 mm clearance, minus half the 0.15 mm stroke = -3.625, x-centred on the
## courtyard) and puts it on the wire. Pinning the number here is the same
## cross-language contract J1_DEFAULT_STROKES pins for the font: the panel must
## DRAW what the fab will PRINT, and a worker rule that moved without the panel
## noticing shows up as a designator drawn on top of the part.
const SWITCH_COURTYARD: Array = [
	{"layer": "F.CrtYd", "kind": "line", "width": 0.05,
		"start": [-4.25, -3.3], "end": [4.25, -3.3]},
	{"layer": "F.CrtYd", "kind": "line", "width": 0.05,
		"start": [4.25, -3.3], "end": [4.25, 3.4]},
	{"layer": "F.CrtYd", "kind": "line", "width": 0.05,
		"start": [4.25, 3.4], "end": [-4.25, 3.4]},
	{"layer": "F.CrtYd", "kind": "line", "width": 0.05,
		"start": [-4.25, 3.4], "end": [-4.25, -3.3]},
]
const SWITCH_ANCHOR := {"x_mm": 0.0, "y_mm": -3.625, "rotation_deg": 0.0,
	"size_mm": 1.0, "hidden": false}
## The anchor a pre-derivation resolve sent for the SAME footprint: a fixed
## 1.5 mm above the ORIGIN, which is 1.8 mm INSIDE this courtyard.
const SWITCH_ANCHOR_OLD := {"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0,
	"size_mm": 1.0, "hidden": false}


## The lowest (largest-y) point of a component's designator strokes, in
## footprint-LOCAL mm — the edge that has to stay clear of the body.
func _stroke_bottom(comp) -> float:
	var lowest := -INF
	for g in comp.refdes_graphics:
		for pt in g["points"]:
			lowest = maxf(lowest, (pt as Vector2).y)
	return lowest


## The top edge of a component's F.CrtYd graphics, read off the component's own
## graphics list rather than from any anchor — the independent oracle.
func _courtyard_top(comp) -> float:
	var top := INF
	for g in comp.graphics:
		if str(g.get("layer", "")) != "F.CrtYd":
			continue
		for key in ["start", "end"]:
			if g.has(key):
				top = minf(top, (g[key] as Vector2).y)
	return top


## A RESOLVED component draws its designator clear of its own courtyard.
##
## The panel is one of the three surfaces that must place a designator in the
## same spot (the Gerber emitter and the DRC silk projection are the others), and
## it is the only one a human looks at. It does not derive the anchor — it
## strokes the ref at the anchor the resolve sent — so what this states is that
## the wire value and the courtyard beside it agree once drawn.
func _check_the_designator_clears_the_courtyard() -> void:
	var sw = PCBComponent.new()
	sw.id = "SW2"
	sw.set_footprint_by_name("SW_EVP-ASAC1A")
	sw.load_footprint_graphics(SWITCH_COURTYARD, SWITCH_ANCHOR)
	var top := _courtyard_top(sw)
	check("the fixture's courtyard is the switch's own (top edge at -3.3)",
		absf(top + 3.3) < EPS_MM)
	check("a resolved part draws its designator clear of its own courtyard",
		sw.refdes_graphics.size() > 0 and _stroke_bottom(sw) < top)
	check("…with the stroke's own width to spare, not merely touching",
		_stroke_bottom(sw) + 0.5 * PCBComponent.REFDES_STROKE_WIDTH_MM < top)

	# TEETH: the same part at the anchor the fixed-offset resolve used to send
	# draws INSIDE the switch body, where it is invisible once the part is
	# soldered. Without this the check above would pass on any anchor that
	# happens to be above the origin.
	var old = PCBComponent.new()
	old.id = "SW2"
	old.set_footprint_by_name("SW_EVP-ASAC1A")
	old.load_footprint_graphics(SWITCH_COURTYARD, SWITCH_ANCHOR_OLD)
	check("…and the pre-derivation anchor would have drawn ON the courtyard",
		_stroke_bottom(old) > top)


## "J1" at the default designator anchor, in footprint-LOCAL mm: the worker's
## board_font rendered at cap height 1.0, centred on the anchor's x, with the
## baseline at REFDES_DEFAULT_Y_MM (-1.5). Generated ONCE from the worker and
## pasted:
##
##   cd pcb/worker && python3 -c "from pcb_worker import board_font; \
##     print([[(x, y - 1.5) for x, y in s] \
##       for s in board_font.render('J1', size=1.0, h_align='center').polylines])"
const J1_DEFAULT_STROKES: Array = [
	[Vector2(-0.25, -2.5), Vector2(-0.25, -1.6666666667),
		Vector2(-0.4166666667, -1.5), Vector2(-0.5833333333, -1.5),
		Vector2(-0.75, -1.6666666667)],
	[Vector2(0.25, -2.3333333333), Vector2(0.4166666667, -2.5),
		Vector2(0.4166666667, -1.5)],
	[Vector2(0.0833333333, -1.5), Vector2(0.75, -1.5)],
]


## Is `drawn` — a refdes_graphics list — stroke-for-stroke and point-for-point
## within 1e-6 mm of `want`, a list of Vector2 lists? Reports the first
## disagreement, since "the glyphs differ" is not actionable on its own.
func _strokes_match(drawn: Array, want: Array) -> bool:
	if drawn.size() != want.size():
		printerr("    %d strokes, want %d" % [drawn.size(), want.size()])
		return false
	for i in range(drawn.size()):
		var got: Array = (drawn[i] as Dictionary)["points"]
		var expect: Array = want[i]
		if got.size() != expect.size():
			printerr("    stroke %d has %d points, want %d" % [i, got.size(), expect.size()])
			return false
		for j in range(got.size()):
			var delta: Vector2 = (got[j] as Vector2) - (expect[j] as Vector2)
			if absf(delta.x) > 1.0e-6 or absf(delta.y) > 1.0e-6:
				printerr("    stroke %d point %d is %s, want %s"
					% [i, j, str(got[j]), str(expect[j])])
				return false
	return true


# ── 5. moving the designator (`minerva_pcb_set_refdes`) ──────────────────────
#
# Section 4 states that the label is a RENDER of (ref, anchor). This section
# states that an agent can move the anchor — and that the reply tells it where
# the ink went, in the frame the board is drawn in.
#
# THE ORACLE IS THE BOX, NOT THE FIELD. Reading back the anchor you just wrote
# proves only that a dictionary was stored. Every claim below is measured on
# `bounds` — the board-frame box of the strokes — or on the strokes themselves,
# so a verb that stored the anchor and never re-rendered fails.

const REFDES_EDITOR := "RefdesProbe"
const REFDES_REF := "SW2"
## A deliberate two-axis move, neither component of which is zero: a box that
## tracked only x, or only the sign of y, cannot pass the translation check.
const REFDES_DELTA := Vector2(3.5, -1.25)


func _refdes_call(host, args: Dictionary) -> Dictionary:
	var call_args := {"editor_name": REFDES_EDITOR, "component_id": REFDES_REF}
	call_args.merge(args)
	return await PanelTools.handle(host, "minerva_pcb_set_refdes", call_args)


## The switch of section 4, on a board, with one baseline history state behind
## it so `undo` has somewhere to land.
func _refdes_host() -> ModelHost:
	var host := _host()
	var sw = host.data.new_component()
	sw.id = REFDES_REF
	sw.set_footprint_by_name("SW_EVP-ASAC1A")
	sw.position = PIVOT_AT
	sw.pins = {"1": Vector2(-PAD_OFFSET_MM, 0.0), "2": Vector2(PAD_OFFSET_MM, 0.0)}
	sw.load_footprint_graphics(SWITCH_COURTYARD, SWITCH_ANCHOR)
	host.data.add_component(sw)
	host.data.save_to_history("baseline")
	return host


func _box(reply: Dictionary) -> Dictionary:
	return (reply.get("bounds", {}) as Dictionary)


func _run_the_designator_anchor_is_movable() -> void:
	print("-- 5. minerva_pcb_set_refdes moves the label and says where it went --")
	var host := _refdes_host()
	var data = host.data

	var read := await _refdes_call(host, {})
	check("a read reports the component's resolved anchor",
		(read.get("anchor", {}) as Dictionary) == SWITCH_ANCHOR)
	check("…and writes nothing: changed is empty and no history step was pushed",
		(read.get("changed", []) as Array).is_empty() and data.history.size() == 1)
	var before := _box(read)
	check("…and reports a board-frame box that straddles the label above the part",
		float(before.get("min_x_mm", 0.0)) < PIVOT_AT.x
			and float(before.get("max_x_mm", 0.0)) > PIVOT_AT.x
			and float(before.get("max_y_mm", 0.0)) < PIVOT_AT.y)

	# THE MOVE. The box must translate by exactly the delta — that is the only
	# assertion here that a store-without-render implementation fails.
	var moved := await _refdes_call(host, {
		"x_mm": SWITCH_ANCHOR["x_mm"] + REFDES_DELTA.x,
		"y_mm": SWITCH_ANCHOR["y_mm"] + REFDES_DELTA.y})
	var after := _box(moved)
	check("moving the anchor translates the drawn box by exactly that delta",
		absf(float(after["min_x_mm"]) - float(before["min_x_mm"]) - REFDES_DELTA.x) < EPS_MM
			and absf(float(after["min_y_mm"]) - float(before["min_y_mm"]) - REFDES_DELTA.y) < EPS_MM)
	check("…without resizing it — the same glyphs, somewhere else",
		absf(float(after["width_mm"]) - float(before["width_mm"])) < EPS_MM
			and absf(float(after["height_mm"]) - float(before["height_mm"])) < EPS_MM)
	check("…and changed names the two fields that moved, and only those",
		", ".join(moved.get("changed", []) as Array) == "x_mm, y_mm")

	# ONE UNDO. The verb pairs its write with exactly one history step, so the
	# label goes back in one press — and the restored component is a NEW object
	# rebuilt from the snapshot, which is why the anchor has to survive to_dict.
	check("the write pushed exactly one history step", data.history.size() == 2)
	check("one undo puts the anchor back", data.undo()
		and (data.get_component(REFDES_REF).refdes_anchor as Dictionary) == SWITCH_ANCHOR)
	var restored := await _refdes_call(host, {})
	check("…and the label is drawn back where it was",
		absf(float(_box(restored)["min_x_mm"]) - float(before["min_x_mm"])) < EPS_MM
			and absf(float(_box(restored)["min_y_mm"]) - float(before["min_y_mm"])) < EPS_MM)

	# PANEL STATE. A restore does not re-resolve, so an agent's anchor has to
	# ride to_dict/from_dict or it is lost the next time the tab is rebuilt.
	await _refdes_call(host, {"x_mm": 4.75, "size_mm": 1.4})
	var live = data.get_component(REFDES_REF)
	var round_tripped = PCBComponent.from_dict(live.to_dict())
	check("the moved anchor survives a panel-state round trip",
		(round_tripped.refdes_anchor as Dictionary) == (live.refdes_anchor as Dictionary))
	check("…and the restored part redraws the same designator from it",
		round_tripped.refdes_graphics == live.refdes_graphics)

	# REFUSALS. Validated whole, applied whole: a bad argument changes nothing
	# and names itself. Nothing is clamped — an agent that had its number
	# silently adjusted would report the number it sent.
	var anchor_before: Dictionary = (live.refdes_anchor as Dictionary).duplicate()
	var typo := await _refdes_call(host, {"size": 1.0})
	check("an unknown key is refused BY NAME",
		not bool(typo.get("success", true)) and str(typo.get("error", "")).contains("size"))
	var too_big := await _refdes_call(host, {
		"size_mm": PcbRefdesAnchor.MAX_SIZE_MM + 1.0})
	check("a size_mm past the bound is refused, not clamped",
		not bool(too_big.get("success", true))
			and str(too_big.get("error", "")).contains("clamp"))
	check("…and neither refusal touched the anchor",
		(data.get_component(REFDES_REF).refdes_anchor as Dictionary) == anchor_before)

	# HIDDEN. No designator means no ink, so there is no box to report either.
	var hidden := await _refdes_call(host, {"hidden": true})
	check("hidden:true draws no designator and reports no box",
		data.get_component(REFDES_REF).refdes_graphics.is_empty()
			and _box(hidden).is_empty())


# ── 6. the placement is BOARD STATE, not panel decoration ────────────────────
#
# Section 5 states that the verb moves the label. This section states that the
# move SURVIVES: a placement somebody set is written into the board document,
# comes back on load, and reaches the worker — while a placement nobody set
# stays absent, so the derivation is free to answer differently on the next
# resolve or on a machine with a different library.
#
# THE ORACLE IS THE DOCUMENT AND THE REDRAWN INK. Every claim is made on the
# dict `to_saved_board_dict` actually produces, or on the strokes a component
# rebuilt from that dict draws — never on the field that was just assigned.

## What one component's saved board dict says, or {} when it is not there.
func _saved_component(data, ref: String) -> Dictionary:
	for entry in (data.to_saved_board_dict().get("components", []) as Array):
		if entry is Dictionary and str((entry as Dictionary).get("ref", "")) == ref:
			return entry
	return {}


func _run_the_placement_is_board_state() -> void:
	print("-- 6. an authored designator placement is written, reloaded and shipped --")
	var host := _refdes_host()
	var data = host.data

	# A component nobody has touched authors nothing. Both halves matter: the
	# authored key must be absent (nobody chose) AND the effective anchor must
	# be absent (it is this host's derivation, not the board's).
	var untouched: Dictionary = _saved_component(data, REFDES_REF)
	check("a component nobody set states no authored placement",
		not untouched.has("refdes_placement"))
	check("…and the document carries no derived anchor either",
		not untouched.has("refdes_anchor"))

	# THE WRITE. A deliberate three-field move so a dict that carried only the
	# position, or only the default size, cannot pass.
	var authored := {"x_mm": 1.75, "y_mm": -6.0, "rotation_deg": 0.0,
		"size_mm": 1.4, "hidden": false}
	await _refdes_call(host, authored)
	var saved: Dictionary = _saved_component(data, REFDES_REF)
	check("after set_refdes the document states the authored placement",
		(saved.get("refdes_placement", {}) as Dictionary) == authored)
	check("…and STILL no derived anchor rides to disk beside it",
		not saved.has("refdes_anchor"))

	# THE RELOAD. A fresh model, fed only the document — no resolve, no worker.
	# The label has to draw at the authored place from the board alone, or an
	# agent's placement is lost every time the tab is rebuilt.
	var reloaded = PCBData.new()
	reloaded.from_board_dict(data.to_saved_board_dict())
	var live = data.get_component(REFDES_REF)
	var back = reloaded.get_component(REFDES_REF)
	check("a fresh model loaded from that document redraws the same designator",
		back != null and _strokes_match(back.refdes_graphics, _points_of(live.refdes_graphics)))
	check("…and re-states the authored placement, so a second save keeps it",
		(_saved_component(reloaded, REFDES_REF).get("refdes_placement", {}) as Dictionary)
			== authored)

	# THE OVERLAY. A hand-authored document may state one field; the rest keeps
	# the derived answer, which is the same rule the worker applies. Fed here
	# through a board dict carrying BOTH the derived anchor a resolve attached
	# and a one-field authored block.
	var overlaid = PCBData.new()
	var doc: Dictionary = data.to_saved_board_dict()
	for entry in (doc["components"] as Array):
		if entry is Dictionary and str((entry as Dictionary).get("ref", "")) == REFDES_REF:
			(entry as Dictionary)["refdes_anchor"] = SWITCH_ANCHOR.duplicate()
			(entry as Dictionary)["refdes_placement"] = {"y_mm": -8.0}
	overlaid.from_board_dict(doc)
	var mixed = overlaid.get_component(REFDES_REF)
	check("a one-field authored block moves that field",
		absf(float(mixed.refdes_anchor["y_mm"]) + 8.0) < EPS_MM)
	check("…and inherits the derived answer for every field it does not state",
		absf(float(mixed.refdes_anchor["size_mm"]) - float(SWITCH_ANCHOR["size_mm"])) < EPS_MM
			and absf(float(mixed.refdes_anchor["x_mm"]) - float(SWITCH_ANCHOR["x_mm"])) < EPS_MM)

	# THE WIRE. The worker cannot honour what it is not sent, and the wire trim
	# drops render enrichment aggressively — the authored placement must not be
	# among the casualties.
	var wire: Dictionary = PanelTools.canonical_wire_board(data.to_board_dict())
	var wired: Dictionary = {}
	for entry in (wire.get("components", []) as Array):
		if entry is Dictionary and str((entry as Dictionary).get("ref", "")) == REFDES_REF:
			wired = entry
	check("the authored placement survives the canonical wire trim",
		(wired.get("refdes_placement", {}) as Dictionary) == authored)


## The point lists of a refdes_graphics array, in the shape `_strokes_match`
## compares against.
func _points_of(graphics: Array) -> Array:
	var out: Array = []
	for g in graphics:
		out.append((g as Dictionary)["points"])
	return out
