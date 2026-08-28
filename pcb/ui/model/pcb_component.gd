extends RefCounted
## Represents a component on the PCB board (resistor, IC, switch, etc.)
##
## Off-tree port of Minerva src/Scripts/UI/Controls/PCBEditor/PCBComponent.gd.
## NO class_name (plugin lives outside res://; plugin-local class_names are
## unresolvable and break the off-tree parser cache). Siblings are reached via
## relative preload(); cross-file values are duck-typed.
##
## Boundary: to_board_dict()/from_board_dict() speak the canonical contract
## (ref/x_mm/y_mm/rotation_deg/pins[{number,x_mm,y_mm}]). Render detail
## (footprint_id/width/height/local_bounds/pads/color/…) is emitted as canonical
## component "Extra" — sibling keys, exactly the set pcb/internal/board/minpcb.go
## parks in Component.Extra. Internal to_dict()/from_dict() keep the legacy shape
## (undo snapshots + Round-B friction).

const _Self := preload("pcb_component.gd")
## The panel's half of the board stroke font — the same glyph table the
## worker prints designators with. Used to RENDER this component's ref
## rather than store a picture of it (see refdes_graphics).
const PcbBoardFont := preload("pcb_board_font.gd")
## The copper-layer vocabulary. Only its SILENT readers are used here
## (is_copper); the warning-emitting normaliser stays out of the draw path.
const PcbLayerStack := preload("pcb_layer_stack.gd")

## Footprint types for visual rendering
enum FootprintType {
	RESISTOR,
	CAPACITOR,
	IC_DIP,
	IC_QFP,
	IC_BGA,
	SWITCH,
	CONNECTOR,
	LED,
	DIODE,
	TRANSISTOR,
	CRYSTAL,
	HEADER,
	MOUNTING_HOLE,
	MODULE,  # Large modules like ESP32 dev boards
	CUSTOM
}

## Unique identifier (e.g., "SW1", "U3", "R12") — the reference designator, and
## the text the fab prints on silk. Assigning it re-renders `refdes_graphics`,
## which is what makes a rename or a copy show the NEW name on the canvas
## instead of the one the strokes were rendered from.
var id: String = "":
	set(value):
		id = value
		_refresh_refdes_graphics()

## Component footprint type
var footprint: FootprintType = FootprintType.CUSTOM

## Origin/anchor position in mm (typically pin 1, following KiCAD convention)
var position: Vector2 = Vector2.ZERO

## Rotation in degrees (0, 90, 180, 270)
var rotation: float = 0.0

## Bounding box dimensions in mm
var width: float = 5.0
var height: float = 2.5

## The bounding box relative to the footprint origin/pin 1 (0,0)
## e.g. Rect2(-1.27, -1.27, 10, 5) means body starts 1.27mm before origin, extends right/down
var local_bounds: Rect2 = Rect2(-1.27, -1.27, 5.0, 2.5)

## Pin definitions: pin_name -> relative Vector2 offset from anchor (origin)
var pins: Dictionary = {}

## Canonical component keys this model does NOT represent (assembly, mpn, ...),
## preserved verbatim from load_from_board_dict and re-emitted by
## to_board_dict — the GDScript mirror of Go's Extra passthrough. Epoch CPN1
## found the loss live: `assembly: exclude` and `mpn` vanished across the
## first real promote.
var canonical_extra: Dictionary = {}

## Per-pin canonical extras keyed by pin number (drill_mm /
## annulus_diameter_mm / plated / pad_width_mm / pad_height_mm / name, ...) —
## same preservation contract as canonical_extra; see the pin-loading note in
## load_from_board_dict.
var pin_extra: Dictionary = {}

## Additional properties (value, package, manufacturer, etc.)
var properties: Dictionary = {}

## Layer: "top" or "bottom"
var layer: String = "top"

## The tokens that name the BACK of the board, matching the worker's
## geometry.BOTTOM_LAYER_NAMES exactly — one vocabulary for "which side is this
## part mounted on" across the boundary. Read by is_bottom_side(), which
## get_transform() calls on every draw, so the test is a silent lookup rather
## than the warning-emitting PcbLayerStack normaliser.
const BACK_SIDE_TOKENS: Array = ["bottom", "b.cu", "back"]

## Whether this component is locked (skipped during hit-testing)
var locked: bool = false

## Visual properties
var color: Color = Color(0.2, 0.6, 0.3, 1.0)
var label_visible: bool = true

## KiCAD footprint ID (e.g., "Button_Switch_SMD:SW_SPST_PTS645Sx43SMTR92")
var footprint_id: String = ""

## Detailed pad geometry from KiCAD footprint library
## Each pad is a Dictionary with keys:
##   number: String - Pad number/name
##   type: String - "smd", "thru_hole", or "np_thru_hole"
##   shape: String - "rect", "circle", "oval", "roundrect", "custom"
##   position: Vector2 - Position relative to component center (mm)
##   size: Vector2 - Pad size (width, height in mm)
##   drill: float - Drill diameter for through-holes (0 for SMD)
##   layers: Array[String] - Copper/mask layers
var pads: Array = []

## Whether pad geometry has been loaded from footprint library
var has_pad_geometry: bool = false

## Whether the `pads` list is this component's own geometry AUTHORITY — true
## when the dict this component was loaded from carried a `pads` key.
##
## The worker reads the KEY, not its contents
## (inline_footprint.carries_full_geometry): a present `pads` list says "these
## are ALL the lands, do not consult the library", so an EMPTY list is a real
## answer (zero pads — a graphics-only pseudo-component like a silk logo) while
## an ABSENT key is a pins-only part that still needs a library resolve.
## has_pad_geometry cannot carry this distinction: it is derived from the lands
## themselves being non-empty. Emitting `pads: []` for a pins-only component
## made the worker refuse the whole board with "pin '1' has no matching
## footprint pad".
var pads_authored: bool = false

## The COMPONENT-level resolved fact, distinct from the PAD-level
## has_pad_geometry above: a silk-only footprint resolves with zero pads, so
## the pad marker alone cannot say "this component is resolved". Set by the
## worker's resolve success path only; absence means unresolved.
##
## SESSION STATE, NOT BOARD DATA. It records that a resolve succeeded against
## THIS machine's library, which is a fact about the machine, not about the
## board. load_from_board_dict therefore never restores it from a saved
## document: a board authored where the library HAD the ref, reopened where it
## does not, would otherwise claim resolved — and canonical_wire_board would
## trim the pads off a part the worker here cannot resolve either, handing it a
## silently pad-less component. It is set only from a resolve performed in this
## session (pcb_library_part.apply_geometry, or a board load whose caller says
## the flags came from a live resolve), and to_saved_board_dict strips it back
## out of everything written to disk.
var footprint_resolved: bool = false

## Silk/courtyard graphics attached by the worker's footprint-RESOLVE step
## (pcb/worker/pcb_worker/resolve.py), in component-LOCAL mm coords (same
## frame as `pads[].position`). Each entry is a Dictionary:
##   layer: String  - the layer the FOOTPRINT authored, usually "F.SilkS"
##                    or "F.CrtYd". It is footprint-local like the coords:
##                    the BOARD layer a stroke prints on is
##                    placed_graphic_layer(), which flips it for a
##                    bottom-mounted part.
##   kind: String    - "line", "circle", "arc", or "poly"
##   width: float    - stroke width in mm
##   start/end: Vector2   (kind == "line")
##   center: Vector2, radius: float   (kind == "circle")
##   points: Array[Vector2], angle: float (optional)  (kind == "arc" or "poly")
var graphics: Array = []

## LAST-RESORT designator anchor — mirrors silk_source.REFDES_LOCAL_Y_MM /
## REFDES_TEXT_SIZE_MM / SILK_TEXT_WIDTH_MM: a designator centred on the
## component origin and printed 1.5 mm above it.
##
## It applies ONLY to a component with no measured anchor at all (an empty
## `refdes_anchor` — nothing resolved this part yet). A resolved part carries
## the worker's anchor instead: the footprint's own authored reference fp_text,
## else the anchor derived from its courtyard (worker refdes_anchor.py), which
## is what keeps the designator off the body of anything bigger than an 0805.
const REFDES_DEFAULT_Y_MM := -1.5
const REFDES_DEFAULT_SIZE_MM := 1.0
const REFDES_STROKE_WIDTH_MM := 0.15

## Where the fab prints this component's designator, in footprint-LOCAL mm:
## `{x_mm, y_mm, rotation_deg, size_mm, hidden}` as the worker's resolve
## measured it (resolve.py::_refdes_anchor) — the board's own AUTHORED
## `refdes_placement` below, else the footprint's authored reference fp_text,
## else the anchor derived from its courtyard. The Gerber emitter, the DRC silk
## projection and the KiCad export read that same rule, so what this draws is
## where the fab prints. An EMPTY dict means nothing has been measured yet, and
## the REFDES_DEFAULT_* above applies.
##
## This is the EFFECTIVE value, so it is session state: it is never written to
## a document (to_board_dict does not emit it, and the Go codec lists it in
## DerivedComponentKeys), because a saved one would freeze one machine's
## library into the board.
##
## Library-derived, like `graphics`: it rides panel state (to_dict) so a
## restore does not have to re-resolve, and is re-measured by every load's
## resolve enrichment. Assigning it re-renders the strokes.
var refdes_anchor: Dictionary = {}:
	set(value):
		refdes_anchor = value
		_refresh_refdes_graphics()

## The AUTHORED designator placement — the one a human or an agent SET through
## `minerva_pcb_set_refdes`, in the same footprint-local `{x_mm, y_mm,
## rotation_deg, size_mm, hidden}` shape. EMPTY means nobody chose, and the
## derivation above applies unchanged.
##
## Unlike `refdes_anchor` this is BOARD SOURCE: it is written into every
## document (to_board_dict -> the .pcbskel save, the YAML export, the promote),
## it survives the Go codec as an ordinary component field, and the worker
## honours it above the footprint's own fp_text on every fab surface. A DERIVED
## anchor is never written back here — that is what keeps "nobody chose" a fact
## the next resolve is free to answer differently.
##
## It may be PARTIAL: a block stating only `hidden` keeps the derived position.
## `_effective_refdes_anchor` is the one overlay, mirroring the worker's
## refdes_anchor.component_reference_text.
var refdes_placement: Dictionary = {}

## PRINTED reference designator — the stroke-font glyphs the fab actually
## prints on silk, in the SAME footprint-local frame as `graphics`, poly entries
## only. Kept separate from `graphics` because the loose-dict emitters consume
## comp["graphics"] and then synthesize the designator themselves — merged
## strokes would print twice.
##
## DERIVED, NEVER STORED. It is a render of `id` at `refdes_anchor`, refreshed
## by both setters, and no dict deserializes into it or serializes out of it —
## so the glyphs always spell THIS component's ref rather than whatever ref a
## carried-through render was made from.
var refdes_graphics: Array = []

## True only while a load_from_* call is filling this component. Both fields the
## designator is rendered from (`id`, `refdes_anchor`) are set by every load, so
## without this each load renders the glyphs twice per component and throws the
## first render away. The loads clear it and refresh ONCE at the end; a live
## rename or anchor move never sets it, so the setters still self-sync.
var _loading_fields: bool = false

## Bounding box center offset from footprint origin (for origin-based positioning)
## When has_pad_geometry is true, position = origin, visual center = position + bbox_center_offset
var bbox_center_offset: Vector2 = Vector2.ZERO


## ── Component groups (stage 1) ────────────────────────────────────────────────
## The `properties` key group membership rides in.
##
## PROPERTIES, NOT A NEW TOP-LEVEL FIELD — measured, not stylistic. The legacy
## .minpcb importer (pcb/internal/board/minpcb.go) walks every per-component key
## against `knownComponentFields` and emits
## `component %q: non-canonical field %q preserved as passthrough` for anything
## outside it (minpcb.go:250). `properties` IS in that set and is already carried
## whole, so a group id inside it rides every serialization path — to_dict,
## to_board_dict, the two load halves, undo snapshots, host_owned save/load —
## with no Go change and no per-component warning. A top-level `group_id` would
## have needed the Go map extended, which is out of this round's fence.
const GROUP_PROPERTY_KEY := "group_id"


## This component's group id, or "" when it belongs to no group.
func group_id() -> String:
	return str(properties.get(GROUP_PROPERTY_KEY, ""))


## Is this component a member of a group?
func is_grouped() -> bool:
	return not group_id().is_empty()


## Join a group, or leave one when `gid` is empty.
##
## Leaving ERASES the key rather than storing "": an ungrouped component must
## serialize exactly as it did before groups existed, so a board that was grouped
## and then ungrouped round-trips byte-identical to one that never was.
func set_group_id(gid: String) -> void:
	if gid.is_empty():
		properties.erase(GROUP_PROPERTY_KEY)
	else:
		properties[GROUP_PROPERTY_KEY] = gid


## Get the string name of this component's footprint enum (within-file enum
## access so cross-file callers never touch the enum directly — off-tree safe).
func get_footprint_name() -> String:
	return FootprintType.keys()[footprint]


## Get the canonical authored footprint identity. Library-qualified footprint
## refs live in footprint_id while the panel uses CUSTOM as its rendering enum;
## external formats must emit the authored ref, never that implementation bucket.
func get_canonical_footprint_name() -> String:
	if footprint == FootprintType.CUSTOM and not footprint_id.is_empty():
		return footprint_id
	return get_footprint_name()


## Set footprint enum from a string name; CUSTOM fallback for unknown names.
func set_footprint_by_name(fp_name: String) -> void:
	var idx := FootprintType.keys().find(fp_name)
	footprint = (idx as FootprintType) if idx >= 0 else FootprintType.CUSTOM


## Get the world-space position of a pin using rigid body transform
func get_pin_world_position(pin_name: String) -> Vector2:
	var local_pos: Vector2 = pins.get(pin_name, Vector2.ZERO)
	var xform := get_transform()
	return position + (xform * local_pos)


## Millimetres from `point` to pin `pin_name`'s COPPER: 0.0 anywhere on one of
## its lands, otherwise the gap to the nearest land edge. This is the measure a
## pad PICKER ranks and thresholds on — a click on a 6mm connector land is on
## that pad wherever it lands, which the distance to the pad's CENTRE cannot
## say, and on a board whose pads are not all one size that centre distance
## hands a big pad's own copper to whatever small pad happens to sit nearer.
##
## Never reports MORE than the centre distance, so it can only ever find a pin
## the centre measure also found: `pins[]` and `pads[].position` are two
## separate fields, and a pin whose footprint disagrees with itself must still
## be pickable at the position the rest of the model routes to.
func pin_copper_distance(pin_name: String, point: Vector2) -> float:
	return pin_copper_distance_from(position, get_transform(),
		get_pin_world_position(pin_name), lands_for_pin(pin_name), point)


## The BOARD layers one of this component's lands occupies.
##
## The other half of the placement rule get_transform carries: `pads[].layers`
## is FOOTPRINT-LOCAL, like `pads[].position`, so the F.Cu land of a
## bottom-mounted part is B.Cu copper on the board and every explicit front/back
## token swaps. A wildcard ("*.Cu") already names both sides and survives
## untouched, as does a token this model does not recognise — the readers
## downstream fail visibly on junk, and a name with no side has no side to swap.
##
## Same rule as the worker's drc._placed_layers / PlacementTransform.layer, and
## it is the reason a land may state its own layers at all: without the flip a
## back-side land reads as front copper and every side-aware answer (contact,
## the pin inspector's side, bus legs) inverts for exactly the parts that are
## hardest to see.
func placed_pad_layers(pad: Dictionary) -> Array:
	var declared: Variant = pad.get("layers", [])
	if not (declared is Array):
		return []
	if not is_bottom_side():
		return declared
	var out: Array = []
	for name in (declared as Array):
		out.append(flipped_layer_token(name))
	return out


## The BOARD layer one of this component's `graphics` entries prints on.
##
## Artwork is footprint-LOCAL, exactly like `pads[].layers`, so it takes the
## same flip: on a bottom-mounted part F-authored artwork lands on the back and
## B-authored artwork lands on the front. That is what KiCad does on flip and
## what the fab emitter already does (gerber._harvest_component_graphics, the
## `pre_placed=False` branch) — the canvas reading the authored layer literally
## is what let a flipped part's silk go missing.
func placed_graphic_layer(graphic: Dictionary) -> String:
	var authored := str(graphic.get("layer", ""))
	if not is_bottom_side():
		return authored
	return str(flipped_layer_token(authored))


## This component's graphics that print on BOARD layer `layer_name` — the ONE
## selection every artwork renderer walks, so what is drawn and what a side-aware
## reader reports cannot drift apart.
func graphics_for_placed_layer(layer_name: String) -> Array:
	var out: Array = []
	for g in graphics:
		if placed_graphic_layer(g as Dictionary) == layer_name:
			out.append(g)
	return out


## Does this land claim COPPER at all?
##
## A land that DECLARES a layer list naming no copper is a paste/mask stencil
## aperture, not a land — KiCad splits a thermal pad into unnumbered
## `(pad "" smd ... (layers "F.Paste"))` nodes — and painting one as copper
## invents metal the fab never makes. A land with NO `layers` key is the legacy
## declaration and keeps its historical copper, as does one whose only claim is
## the "*.Cu" wildcard. Same reading as the worker's pad_source.has_copper.
func pad_names_copper(pad: Dictionary) -> bool:
	var declared: Array = placed_pad_layers(pad)
	if declared.is_empty():
		return true
	for raw_layer in declared:
		# The wildcard is copper on every layer — copper, but no single layer.
		if str(raw_layer).strip_edges().to_lower() == "*.cu":
			return true
		if PcbLayerStack.is_copper(raw_layer):
			return true
	return false


## One layer token reflected to the other side of the board. Front/back prefixes
## and the canonical top/bottom ids swap; anything else — a wildcard, an inner
## layer, an unreadable value — is returned as it came.
static func flipped_layer_token(name: Variant) -> Variant:
	var text := str(name)
	var low := text.to_lower()
	if low.begins_with("f."):
		return "B." + text.substr(2)
	if low.begins_with("b."):
		return "F." + text.substr(2)
	if low == "top":
		return "bottom"
	if low == "bottom":
		return "top"
	return name


## The lands of one pin — the `pads` entries carrying its number. A footprint
## may declare several for one electrical pin (a split thermal land), and none
## at all when it never resolved.
func lands_for_pin(pin_name: String) -> Array:
	var out: Array = []
	for pad in pads:
		if str((pad as Dictionary).get("number", "")) == pin_name:
			out.append(pad)
	return out


## The pad-picking rule itself, free of any component instance so a hit-test
## seam holding lands directly measures the same way. `origin`/`xform` are the
## frame the lands are placed in (a component's position / get_transform());
## `centre` is the pin's world position; `pin_lands` its `pads` entries.
static func pin_copper_distance_from(origin: Vector2, xform: Transform2D,
		centre: Vector2, pin_lands: Array, point: Vector2) -> float:
	var best := centre.distance_to(point)
	for land in pin_lands:
		best = minf(best, _land_distance(land as Dictionary, origin, xform, point))
	return best


## Millimetres from `point` to ONE land's copper, 0.0 inside it.
##
## SHAPES, and why the model differs from pcb_ratsnest's land of the same name:
## this is a POINTER measurement, so where the shape cannot be represented
## exactly it errs LARGE (a click on real copper must resolve to it), while the
## ratsnest errs small (copper merely near an island must not read as joined).
##   rect / roundrect / unknown — the oriented rectangle. The authored corner
##     radius is not carried in the model, and the rectangle contains every
##     roundrect of that size; the overhang is at most one corner radius, far
##     under the slack a picker already grants around a pad.
##   circle / oval — the exact stadium: the long-axis segment swollen by the
##     short half-axis, which is a disc when the two sizes are equal.
##
## ROTATION: a land's OFFSET turns with the component only, its BODY with the
## component's rotation and its own — same CW degree convention throughout (see
## get_transform), so the copper is measured where it is fabricated.
##
## THE BACK OF THE BOARD needs nothing extra here. `xform` carries the mirror,
## so undoing it lands the probe in true footprint-local coordinates, where the
## land sits at its authored offset and its authored angle — which is exactly
## what the +rotation step below undoes.
static func _land_distance(land: Dictionary, origin: Vector2,
		xform: Transform2D, point: Vector2) -> float:
	var half: Vector2 = (land.get("size", Vector2(1, 1)) as Vector2) * 0.5
	var land_pos: Vector2 = land.get("position", Vector2.ZERO)
	# Into the land's own frame: undo the component transform, then the land's
	# offset, then the land's own rotation. Placing a land turns it by
	# -rotation (CW, as get_transform does), so undoing that turns by +rotation.
	var in_footprint: Vector2 = (xform.affine_inverse() * (point - origin)) - land_pos
	var local := in_footprint.rotated(deg_to_rad(float(land.get("rotation", 0.0))))
	var shape := str(land.get("shape", "rect")).strip_edges().to_lower()
	if shape == "circle" or shape == "oval":
		var radius := minf(half.x, half.y)
		var extent := maxf(half.x, half.y) - radius
		var axis := Vector2(extent, 0.0) if half.x >= half.y else Vector2(0.0, extent)
		var to_axis := Vector2(maxf(absf(local.x) - axis.x, 0.0),
			maxf(absf(local.y) - axis.y, 0.0))
		return maxf(to_axis.length() - radius, 0.0)
	return Vector2(maxf(absf(local.x) - half.x, 0.0),
		maxf(absf(local.y) - half.y, 0.0)).length()


## Get the symbolic name for a pin number (from geometry import)
## Returns empty string if no name is defined
func get_pin_name(pin_number: String) -> String:
	for pad in pads:
		if str(pad.get("number", "")) == pin_number:
			var name = pad.get("name", "")
			if name != null and not str(name).is_empty():
				return str(name)
			break
	return ""


## Whether this part is mounted on the BACK of the board — the fact that decides
## whether footprint-local geometry is mirrored on its way to board space.
func is_bottom_side() -> bool:
	return str(layer).strip_edges().to_lower() in BACK_SIDE_TOKENS


## THE footprint-local -> board transform for this component: ONE object every
## surface composes with, so draw, hit-test and every measurement agree by
## construction rather than by three matching edits.
##
##     board_point = position + get_transform() * footprint_local_point
##
## ROTATION. `rotation` is the canonical rotation_deg, defined KiCad-equivalent:
## KiCad applies a footprint angle as R(radians(-angle)) in board space (its
## angle is CW in the Y-down file frame). The worker matches this exactly
## (geometry.rotate_local_offset and everything delegating to it), so the panel
## MUST too — hence deg_to_rad(-rotation) — or pads/silk/pins desync from the
## fab for 90/270 parts. Do NOT "fix" this to +rotation: if a board's 90/270
## parts land off their traces, the DATA has the wrong-sign rotation (e.g. a
## stale pre-KiCad-convention negation at import), not this.
##
## MIRROR. pcbnew's footprint flip NEGATES LOCAL Y before applying the rotation,
## so a back-side part's lands, silk and designator are reflected about the
## footprint's own x axis. `scaled_local` right-multiplies, which is exactly that
## order — mirror first, then turn — and matches geometry.PlacementTransform.point
## (`if side is BOTTOM: ly = -ly` ahead of place_point). Because the reflection
## lives IN the transform, a land's own `rotation` needs no separate sign rule
## here: its body is built inside this frame and comes out turning the right way
## (see pcb_copper_contact.physical_pad_node and _land_distance). The one place
## that cannot inherit it is a land angle handed OUT as a board number —
## get_pad_world_transform — which folds the same sign explicitly.
##
## The transform is footprint-local -> board OFFSET only; `position` is added by
## the caller, as the formula above shows. That keeps the offset and the
## translation separable, which is what lets a proposed pose reuse the same
## frame at a different anchor.
func get_transform() -> Transform2D:
	return transform_at(rotation)


## The SAME frame at an arbitrary angle — the pose a proposal is drawn at, which
## is not this component's own until the proposal is accepted. Keeping it here
## means a ghost is placed by the placement rule rather than by a second
## Transform2D built at the call site, which is how a proposed part came to be
## drawn unmirrored while its committed self was mirrored.
func transform_at(rotation_deg: float) -> Transform2D:
	var xform := Transform2D(deg_to_rad(-rotation_deg), Vector2.ZERO)
	if is_bottom_side():
		xform = xform.scaled_local(Vector2(1.0, -1.0))
	return xform


## Get local body polygon for drawing (4 corners relative to anchor)
func get_local_body_polygon() -> PackedVector2Array:
	return PackedVector2Array([
		local_bounds.position,  # Top-Left
		Vector2(local_bounds.end.x, local_bounds.position.y),  # Top-Right
		local_bounds.end,  # Bottom-Right
		Vector2(local_bounds.position.x, local_bounds.end.y)  # Bottom-Left
	])


## Load pad geometry from pcb-architect footprint-geometry output
## geometry: Dictionary with keys: pads, bounding_box, footprint_id,
##   has_pad_geometry (canonical resolved-vs-fallback marker; Stage 2 step 7).
##   The legacy key ``footprint_found`` is still accepted for older
##   pcb-architect output that predates the rename.
func load_pad_geometry(geometry: Dictionary) -> void:
	footprint_id = geometry.get("footprint_id", "")
	has_pad_geometry = geometry.get("has_pad_geometry", geometry.get("footprint_found", false))

	# Update bounding box from footprint data
	var bbox: Dictionary = geometry.get("bounding_box", {})
	if bbox.size() > 0:
		width = bbox.get("width", width)
		height = bbox.get("height", height)
		# Get the center offset (how far body center is from origin)
		var center_x: float = bbox.get("center_x", 0.0)
		var center_y: float = bbox.get("center_y", 0.0)
		bbox_center_offset = Vector2(center_x, center_y)

		# Calculate local_bounds: Rect2 relative to anchor (0,0)
		# If center is at (cx, cy), then top-left is at (cx - w/2, cy - h/2)
		local_bounds = Rect2(
			center_x - width / 2.0,
			center_y - height / 2.0,
			width,
			height
		)

	# Load pads through the ONE pad deserializer, so an imported land keeps the
	# same fab-affecting optionals (corner_rratio above all) a board-dict land
	# keeps. A private copy of this loop dropped the authored corner radius, and
	# the contact predicate then read every imported roundrect as the stadium
	# inscribed in it — copper on a corner became a false open.
	_pads_from_list(geometry.get("pads", []))

	# Also update pins dictionary for net connections (electrical pads only)
	pins.clear()
	for pad in pads:
		var num := str(pad.get("number", ""))
		var ptype := str(pad.get("type", "smd"))
		if num.is_empty():
			continue
		if ptype == "np_thru_hole":
			continue  # Mechanical hole: not an electrical pin
		pins[num] = pad.get("position", Vector2.ZERO)


## Attach a footprint's silk/courtyard graphics and its printed designator —
## the graphics half of load_pad_geometry above, for the ADD-BY-REF path, which
## gets its geometry from a single-footprint resolve rather than from a board
## load. The graphics are in the SAME footprint-local frame as
## `pads[].position`, and so is the designator anchor.
func load_footprint_graphics(graphics_data: Array, refdes_anchor_data: Dictionary) -> void:
	_graphics_from_list(graphics_data)
	_adopt_derived_anchor(refdes_anchor_data)


## Parse a point from either the worker's native `[x, y]` array shape or the
## Godot round-trip `{x:, y:}` dict shape (defensive — `graphics` may arrive
## via either channel; see `_graphics_from_list`).
static func _point_from_any(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is Dictionary:
		return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
	return Vector2.ZERO


## Serialize the graphics array to a JSON-safe list (shared by to_dict/to_board_dict).
func _graphics_to_list() -> Array:
	var list := []
	for g in graphics:
		var kind: String = g.get("kind", "")
		var entry := {
			"layer": g.get("layer", ""),
			"kind": kind,
			"width": g.get("width", 0.0),
		}
		match kind:
			"line":
				var start: Vector2 = g.get("start", Vector2.ZERO)
				var end: Vector2 = g.get("end", Vector2.ZERO)
				entry["start"] = {"x": start.x, "y": start.y}
				entry["end"] = {"x": end.x, "y": end.y}
			"circle":
				var center: Vector2 = g.get("center", Vector2.ZERO)
				entry["center"] = {"x": center.x, "y": center.y}
				entry["radius"] = g.get("radius", 0.0)
			"arc", "poly":
				var pts_list := []
				for pt in g.get("points", []):
					var p: Vector2 = pt
					pts_list.append({"x": p.x, "y": p.y})
				entry["points"] = pts_list
				if g.has("angle"):
					entry["angle"] = g["angle"]
		list.append(entry)
	return list


## Re-render the printed designator from the LIVE ref at the current anchor.
## Called by the `id` and `refdes_anchor` setters — that pair is the whole sync
## contract, and the reason no caller has to remember to refresh after a
## rename, a copy, a load or a normalize. A load sets both, so it suppresses the
## setters with `_loading_fields` and calls this once at the end instead.
##
## The glyphs, the anchor defaults and the stroke width are the emitter's own
## (PcbBoardFont mirrors board_font; silk_source places designator glyphs
## CENTRED on the anchor with the baseline at its y), so what the canvas draws
## is what the Gerber will carry. A hidden reference draws nothing, matching
## the emitter's authored-hidden rule.
func _refresh_refdes_graphics() -> void:
	if _loading_fields:
		return
	refdes_graphics = []
	if id.strip_edges().is_empty() or bool(refdes_anchor.get("hidden", false)):
		return
	var rendered: Dictionary = PcbBoardFont.strokes_for(
		id,
		float(refdes_anchor.get("x_mm", 0.0)),
		float(refdes_anchor.get("y_mm", REFDES_DEFAULT_Y_MM)),
		float(refdes_anchor.get("size_mm", REFDES_DEFAULT_SIZE_MM)),
		float(refdes_anchor.get("rotation_deg", 0.0)),
		false, "center")
	for stroke in rendered["polylines"]:
		var pts: Array = stroke
		if pts.size() >= 2:
			refdes_graphics.append({
				"layer": "F.SilkS", "kind": "poly",
				"width": REFDES_STROKE_WIDTH_MM, "points": pts})


## Read a designator anchor off a dict, tolerating a missing or malformed one:
## an unmeasured anchor is the default anchor, never a crash.
static func _anchor_from_any(v) -> Dictionary:
	return (v as Dictionary) if v is Dictionary else {}


## The DERIVED anchor `base` with the authored placement laid over it, per
## field — the panel half of the worker's one precedence rule
## (worker/pcb_worker/refdes_anchor.py). Authored beats derived; a field the
## author did not state keeps the derived answer, so `{hidden: true}` hides a
## designator without freezing where it would otherwise have been.
func _effective_refdes_anchor(base: Dictionary) -> Dictionary:
	if refdes_placement.is_empty():
		return base
	var out: Dictionary = base.duplicate()
	for key in refdes_placement:
		out[key] = refdes_placement[key]
	return out


## Adopt a freshly DERIVED anchor (a resolve reply, a document, a snapshot)
## through the overlay. The single writer for every derived source, so no load
## path can forget the authored half.
func _adopt_derived_anchor(base: Dictionary) -> void:
	refdes_anchor = _effective_refdes_anchor(base)


## Deserialize a graphics list (shared by from_dict/from_board_dict) into
## `graphics`, normalizing points to Vector2 regardless of source shape
## (worker `[x,y]` arrays vs. round-tripped `{x:,y:}` dicts).
func _graphics_from_list(graphics_data: Array) -> void:
	graphics.clear()
	for g_data in graphics_data:
		if not (g_data is Dictionary):
			continue
		var kind: String = str(g_data.get("kind", ""))
		var entry := {
			"layer": str(g_data.get("layer", "")),
			"kind": kind,
			"width": float(g_data.get("width", 0.0)) if g_data.get("width") != null else 0.0,
		}
		match kind:
			"line":
				entry["start"] = _point_from_any(g_data.get("start", Vector2.ZERO))
				entry["end"] = _point_from_any(g_data.get("end", Vector2.ZERO))
			"circle":
				entry["center"] = _point_from_any(g_data.get("center", Vector2.ZERO))
				entry["radius"] = float(g_data.get("radius", 0.0))
			"arc", "poly":
				var pts: Array = []
				for pt_data in g_data.get("points", []):
					pts.append(_point_from_any(pt_data))
				entry["points"] = pts
				if g_data.has("angle") and g_data["angle"] != null:
					entry["angle"] = float(g_data["angle"])
		graphics.append(entry)


## Compute the axis-aligned bbox (component-LOCAL mm, same frame as
## `pads[].position`) of every `graphics` entry on the given layer
## ("F.CrtYd" / "F.SilkS"). Returns null when no entry on that layer exists,
## or the extent degenerates to zero width/height (a stray single-point
## entry, not real body geometry) — callers treat null as "no usable bounds
## on this layer, try the next fallback".
func _graphics_layer_bounds(layer_name: String):
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	var found := false
	for g in graphics:
		if str(g.get("layer", "")) != layer_name:
			continue
		match str(g.get("kind", "")):
			"line":
				var s: Vector2 = g.get("start", Vector2.ZERO)
				var e: Vector2 = g.get("end", Vector2.ZERO)
				min_p.x = minf(min_p.x, minf(s.x, e.x))
				min_p.y = minf(min_p.y, minf(s.y, e.y))
				max_p.x = maxf(max_p.x, maxf(s.x, e.x))
				max_p.y = maxf(max_p.y, maxf(s.y, e.y))
				found = true
			"circle":
				var c: Vector2 = g.get("center", Vector2.ZERO)
				var r: float = float(g.get("radius", 0.0))
				min_p.x = minf(min_p.x, c.x - r)
				min_p.y = minf(min_p.y, c.y - r)
				max_p.x = maxf(max_p.x, c.x + r)
				max_p.y = maxf(max_p.y, c.y + r)
				found = true
			"arc", "poly":
				for pt in g.get("points", []):
					var p: Vector2 = pt
					min_p.x = minf(min_p.x, p.x)
					min_p.y = minf(min_p.y, p.y)
					max_p.x = maxf(max_p.x, p.x)
					max_p.y = maxf(max_p.y, p.y)
					found = true
	if not found or max_p.x <= min_p.x or max_p.y <= min_p.y:
		return null
	return Rect2(min_p, max_p - min_p)


## Derive local_bounds (and width/height, kept in sync so label placement and
## other width/height readers agree) from the F.CrtYd graphics extent, falling
## back to the F.SilkS bbox when the footprint carries no courtyard. LOCAL
## frame, pre-rotation — `graphics` is already component-local mm, the same
## frame local_bounds lives in, so no transform is applied here.
## Returns true when a derived bounds was applied, false when `graphics` had
## neither layer (caller keeps whatever local_bounds it already computed).
func _derive_bounds_from_graphics() -> bool:
	var bounds = _graphics_layer_bounds("F.CrtYd")
	if bounds == null:
		bounds = _graphics_layer_bounds("F.SilkS")
	if bounds == null:
		return false
	local_bounds = bounds
	width = bounds.size.x
	height = bounds.size.y
	return true


## THE land-to-world transform — one answer for every surface that has to know
## where a piece of pad copper physically is.
##
## Returns {position: world centre, size: the land's own size, rotation: the
## land's world angle in BOARD degrees — the CW/KiCad convention `rotation`
## itself is in, so a Godot-space consumer NEGATES it exactly as get_transform
## and _land_distance do}. The three compose exactly as _land_distance measures:
## the OFFSET turns with the component only, the BODY with the component's
## rotation and the land's own. Size is never swapped — a 90-degree turn is
## carried by `rotation`, which is what lets an arbitrary angle work at all and
## what makes the drawn rectangle and the hit-test rectangle one rectangle.
##
## Before this was the one answer it disagreed with the model twice: it turned
## the offset by +rotation where every other path (get_transform, the worker,
## KiCad) turns it by -rotation, and it swapped width/height on `int(rotation) %
## 180 == 90`, which is false for -90. Callers wanting an axis-aligned box build
## it from these three (pcb_pad_approach.land_rect).
func get_pad_world_transform(pad: Dictionary) -> Dictionary:
	return pad_world_transform_at(pad, position, rotation)


## The same land geometry at an arbitrary POSE — where this part's copper would
## be if it were placed at `origin` turned `rotation_deg`. A placement proposal
## draws its lands through this, so a ghost land and the committed land it
## becomes are one derivation and cannot disagree about shape, size or angle.
func pad_world_transform_at(pad: Dictionary, origin: Vector2,
		rotation_deg: float) -> Dictionary:
	var local_pos: Vector2 = pad.get("position", Vector2.ZERO)
	var land_rotation := float(pad.get("rotation", 0.0))
	return {
		"position": origin + (transform_at(rotation_deg) * local_pos),
		"size": pad.get("size", Vector2(1, 1)) as Vector2,
		# The land's BOARD angle. On the front the two angles ADD; on the back
		# the mirror in get_transform reflects the land's own turn, which
		# NEGATES it — the same fold geometry.PlacementTransform.angle applies
		# (`rotation_deg + local` on top, `rotation_deg - local` on the bottom).
		# This is the one land angle stated as a number instead of being carried
		# by the frame, so it is the one place that spells the sign out.
		"rotation": (rotation_deg - land_rotation) if is_bottom_side()
			else (rotation_deg + land_rotation),
	}


## Get all pin world positions
func get_all_pin_positions() -> Dictionary:
	var result: Dictionary = {}
	for pin_name in pins:
		result[pin_name] = get_pin_world_position(pin_name)
	return result


## Get the bounding rectangle in world space
func get_bounding_rect() -> Rect2:
	# Use rigid body transform for consistent rotation
	var xform := get_transform()
	var local_poly := get_local_body_polygon()

	# Transform corners and find axis-aligned bounds
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for corner in local_poly:
		var world_point: Vector2 = position + (xform * corner)
		min_pos.x = minf(min_pos.x, world_point.x)
		min_pos.y = minf(min_pos.y, world_point.y)
		max_pos.x = maxf(max_pos.x, world_point.x)
		max_pos.y = maxf(max_pos.y, world_point.y)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is inside this component's bounding rect
func contains_point(point: Vector2) -> bool:
	return get_bounding_rect().has_point(point)


## Set position (for undo/redo support)
func set_position(new_pos: Vector2) -> void:
	position = new_pos


## Set rotation (constrained to 0, 90, 180, 270)
func set_rotation(degrees: float) -> void:
	rotation = snap_rotation(degrees)


## The model's SINGLE rotation-quantization authority: normalize into [0, 360)
## then snap to the nearest multiple of 90. Static so pcb_data.rotate_group can
## snap a rigid-body delta through the same rule bodies use — the two halves of
## a group rotation must never disagree (cold-review A4 finding 1).
static func snap_rotation(degrees: float) -> float:
	var normalized := fmod(degrees, 360.0)
	if normalized < 0:
		normalized += 360.0
	return roundf(normalized / 90.0) * 90.0


## THE ROTATION WORDS, and what they mean ON SCREEN.
##
## The NUMBER is KiCad's: rotation_deg applies as R(-angle) in the panel's
## y-down board frame (see get_transform), which is the convention the worker's
## emitters share and must never change. But that makes a POSITIVE angle turn
## the part COUNTER-clockwise as a human watches it: a pad WEST of the origin
## lands SOUTH at 90 (west→south is 9 o'clock to 6 o'clock on screen).
##
## The words therefore mean what the EYE sees, not what the number does; the
## numbers are untouched. Static so the panel verb and the canvas key press
## cannot drift apart.
static func clockwise_from(degrees: float) -> float:
	return fmod(degrees - 90.0 + 360.0, 360.0)


static func counterclockwise_from(degrees: float) -> float:
	return fmod(degrees + 90.0, 360.0)


## Rotate a quarter turn CLOCKWISE as drawn on screen.
func rotate_clockwise() -> void:
	set_rotation(clockwise_from(rotation))


## Rotate a quarter turn COUNTER-clockwise as drawn on screen.
func rotate_counterclockwise() -> void:
	set_rotation(counterclockwise_from(rotation))


## Initialize standard pin layout for common footprints
## KiCAD convention: Pin 1 at origin (0,0), body extends from there
func setup_standard_pins() -> void:
	pins.clear()

	match footprint:
		FootprintType.RESISTOR, FootprintType.CAPACITOR, FootprintType.DIODE, FootprintType.LED:
			# Two-terminal component, horizontal, pin 1 at origin
			width = 3.0
			height = 1.5
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(2.54, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(1.27, 0)

		FootprintType.TRANSISTOR:
			# Three-terminal (TO-92 style), pin 1 at origin
			width = 3.0
			height = 2.0
			pins["B"] = Vector2(0, 0)
			pins["C"] = Vector2(1.27, 0)
			pins["E"] = Vector2(2.54, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(1.27, 0)

		FootprintType.IC_DIP:
			# 8-pin DIP as default, pin 1 at origin (top-left)
			var row_spacing := 7.62
			var pins_per_side := 4
			var total_height := (pins_per_side - 1) * 2.54
			width = row_spacing + 2.54
			height = total_height + 2.54
			for i in range(pins_per_side):
				pins[str(i + 1)] = Vector2(0, i * 2.54)
				pins[str(8 - i)] = Vector2(row_spacing, i * 2.54)
			local_bounds = Rect2(-1.27, -1.27, width, height)
			bbox_center_offset = Vector2(row_spacing / 2.0, total_height / 2.0)

		FootprintType.SWITCH:
			# Simple push button, pin 1 at origin (top-left)
			width = 6.0
			height = 6.0
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(5.08, 0)
			pins["3"] = Vector2(0, 5.08)
			pins["4"] = Vector2(5.08, 5.08)
			local_bounds = Rect2(-0.5, -0.5, width, height)
			bbox_center_offset = Vector2(2.54, 2.54)

		FootprintType.CONNECTOR, FootprintType.HEADER:
			# 2-pin header as default, vertical, pin 1 at origin
			width = 2.54
			height = 2.54 + 2.54
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(0, 2.54)
			local_bounds = Rect2(-width / 2.0, -1.27, width, height)
			bbox_center_offset = Vector2(0, 1.27)

		FootprintType.MOUNTING_HOLE:
			# Mounting hole - single pin at origin
			width = 3.2
			height = 3.2
			pins["1"] = Vector2(0, 0)
			local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)
			bbox_center_offset = Vector2.ZERO

		FootprintType.MODULE:
			# Large module (like ESP32 dev board) - default 2x20 pins
			# Pin 1 at origin (top-left), body extends beyond pin rows
			var row_spacing := 22.86  # ~0.9" for dev boards
			var pins_per_side := 20
			var body_extension := 9.0  # Body extends beyond pins on each end
			var total_pin_height := (pins_per_side - 1) * 2.54
			width = row_spacing + 2.54
			height = total_pin_height + (body_extension * 2)
			for i in range(pins_per_side):
				pins[str(i + 1)] = Vector2(0, i * 2.54)
				pins[str(40 - i)] = Vector2(row_spacing, i * 2.54)
			local_bounds = Rect2(-1.27, -body_extension, width, height)
			bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)

		FootprintType.CRYSTAL:
			# Crystal oscillator, pin 1 at origin
			width = 5.0
			height = 2.0
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(4.0, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(2.0, 0)

		_:
			# Default fallback
			width = 5.0
			height = 2.5
			pins["1"] = Vector2(0, 0)
			local_bounds = Rect2(-1.0, -height / 2.0, width, height)
			bbox_center_offset = Vector2(width / 2.0 - 1.0, 0)


## Setup a single-row header/connector with custom pin count
## KiCAD convention: Vertical orientation, pin 1 at origin (0,0), pins going down (+Y)
func setup_header_pins(pin_count: int, pin_names: Array = []) -> void:
	pins.clear()
	var spacing := 2.54  # Standard 0.1" spacing
	var total_length := (pin_count - 1) * spacing
	# Vertical orientation: width is narrow, height is long
	width = 2.54
	height = total_length + 2.54

	for i in range(pin_count):
		var pin_name: String
		if i < pin_names.size():
			pin_name = str(pin_names[i])
		else:
			pin_name = str(i + 1)
		# Pin 1 at origin (0, 0), subsequent pins going down (+Y)
		pins[pin_name] = Vector2(0, i * spacing)

	# local_bounds relative to pin 1 origin: body centered on X, extends down from pin 1
	local_bounds = Rect2(-width / 2.0, -1.27, width, height)
	# Calculate center offset from origin for compatibility
	bbox_center_offset = Vector2(0, total_length / 2.0)


## Setup a dual-row DIP with custom pin count (must be even)
## KiCAD convention: Pin 1 at origin (0,0) top-left, left side going down, right side going up
func setup_dip_pins(pin_count: int, row_spacing: float = 7.62) -> void:
	pins.clear()
	@warning_ignore("integer_division")
	var pins_per_side := pin_count / 2
	var spacing := 2.54
	var total_pin_height := (pins_per_side - 1) * spacing
	width = row_spacing + 2.54
	height = total_pin_height + 2.54

	for i in range(pins_per_side):
		# Left side: 1, 2, 3... going down from origin
		# Pin 1 at (0, 0), Pin 2 at (0, 2.54), etc.
		pins[str(i + 1)] = Vector2(0, i * spacing)
		# Right side: N, N-1, N-2... going up from bottom-right
		# Pin N at (row_spacing, 0), Pin N-1 at (row_spacing, 2.54), etc.
		pins[str(pin_count - i)] = Vector2(row_spacing, i * spacing)

	# local_bounds relative to pin 1 origin: extends right and down from origin
	local_bounds = Rect2(-1.27, -1.27, width, height)
	# Calculate center offset from origin
	bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)


## Setup a large module (ESP32 dev boards, etc.) with custom pin count
## KiCAD convention: Pin 1 at origin (0,0), body extends beyond pin rows
## row_spacing: distance between pin rows (default ~22.86mm for dev boards)
## body_extension: how much the body extends beyond pin rows on each end
func setup_module_pins(pin_count: int, row_spacing: float = 22.86, body_extension: float = 9.0) -> void:
	pins.clear()
	@warning_ignore("integer_division")
	var pins_per_side := pin_count / 2
	var spacing := 2.54
	var total_pin_height := (pins_per_side - 1) * spacing

	# Body dimensions - wider than DIP, extends beyond pins
	width = row_spacing + 2.54
	# Height: pin area + extension on both ends
	height = total_pin_height + (body_extension * 2)

	for i in range(pins_per_side):
		# Left side: 1, 2, 3... going down from origin
		pins[str(i + 1)] = Vector2(0, i * spacing)
		# Right side: N, N-1, N-2... going up from bottom-right
		pins[str(pin_count - i)] = Vector2(row_spacing, i * spacing)

	# local_bounds: body extends beyond pins
	# Top edge at -body_extension (above pin 1), bottom at total_pin_height + body_extension
	local_bounds = Rect2(-1.27, -body_extension, width, height)
	# Center offset from pin 1 origin
	bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)


## Generic pin layout for any footprint type.
## Works when none of the specialised methods (header, DIP, module) apply.
##   pin_count  – number of pads (>= 1)
##   pad_type   – "smd" or "tht" (affects pad/body sizing)
##   spacing    – centre-to-centre pin pitch in mm (default 2.54)
##   row_sp     – distance between dual rows in mm (default 7.62)
func setup_generic_pins(pin_count: int, pad_type: String = "tht", spacing: float = 2.54, row_sp: float = 7.62) -> void:
	pins.clear()

	var is_smd := (pad_type == "smd")
	# Pad body margin – THT pads are slightly larger than SMD
	var pad_margin := 1.0 if is_smd else 1.27

	if pin_count == 1:
		# Single centred pad (mounting-hole style)
		width = 3.2
		height = 3.2
		pins["1"] = Vector2(0, 0)
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)
		bbox_center_offset = Vector2.ZERO

	elif pin_count <= 3:
		# Inline horizontal row
		var total_length := (pin_count - 1) * spacing
		width = total_length + pad_margin * 2
		height = pad_margin * 2
		for i in range(pin_count):
			pins[str(i + 1)] = Vector2(i * spacing, 0)
		local_bounds = Rect2(-pad_margin, -height / 2.0, width, height)
		bbox_center_offset = Vector2(total_length / 2.0, 0)

	elif pin_count % 2 == 0:
		# Even pin count >= 4 → dual-row (DIP-like)
		@warning_ignore("integer_division")
		var pins_per_side := pin_count / 2
		var total_pin_height := (pins_per_side - 1) * spacing
		width = row_sp + pad_margin * 2
		height = total_pin_height + pad_margin * 2
		for i in range(pins_per_side):
			pins[str(i + 1)] = Vector2(0, i * spacing)
			pins[str(pin_count - i)] = Vector2(row_sp, i * spacing)
		local_bounds = Rect2(-pad_margin, -pad_margin, width, height)
		bbox_center_offset = Vector2(row_sp / 2.0, total_pin_height / 2.0)

	else:
		# Odd pin count >= 5 → single-row vertical (header-like)
		var total_length := (pin_count - 1) * spacing
		width = pad_margin * 2
		height = total_length + pad_margin * 2
		for i in range(pin_count):
			pins[str(i + 1)] = Vector2(0, i * spacing)
		local_bounds = Rect2(-width / 2.0, -pad_margin, width, height)
		bbox_center_offset = Vector2(0, total_length / 2.0)


## Setup custom size without changing pins
## Maintains origin-based positioning (body extends from near origin)
func set_size(new_width: float, new_height: float) -> void:
	width = new_width
	height = new_height
	# Update local_bounds - body starts slightly before origin, extends right/down
	# Use small margin (-1.27mm) to allow pin 1 to be inside the body
	local_bounds = Rect2(-1.27, -1.27, width, height)
	# Update center offset
	bbox_center_offset = Vector2(width / 2.0 - 1.27, height / 2.0 - 1.27)


## Create a deep copy of this component
func duplicate_component():
	var copy = _Self.new()
	copy.id = id
	copy.footprint = footprint
	copy.position = position
	copy.rotation = rotation
	copy.width = width
	copy.height = height
	copy.pins = pins.duplicate(true)
	copy.properties = properties.duplicate(true)
	copy.layer = layer
	copy.color = color
	copy.label_visible = label_visible
	copy.footprint_id = footprint_id
	copy.pads = pads.duplicate(true)
	copy.has_pad_geometry = has_pad_geometry
	copy.pads_authored = pads_authored
	copy.graphics = graphics.duplicate(true)
	# The anchor, not the strokes: copy.id is already this copy's own name, so
	# assigning the anchor renders the designator the COPY carries. A copied
	# blob of strokes is how a part came to draw its source's ref.
	copy.refdes_placement = refdes_placement.duplicate()
	copy.refdes_anchor = refdes_anchor.duplicate()
	copy.bbox_center_offset = bbox_center_offset
	copy.local_bounds = local_bounds
	copy.locked = locked
	# Canonical passthrough rides every copy path too — a duplicated component
	# that lost `assembly: exclude` or its pins' drill/annulus overrides would
	# be a different PART, silently (Codex review 1086 finding 3's class).
	copy.canonical_extra = canonical_extra.duplicate(true)
	copy.pin_extra = pin_extra.duplicate(true)
	return copy


## Pad keys the worker emits ONLY when the footprint authored them, carried
## verbatim through decode -> encode so a panel round trip cannot re-default a
## land's corner radius, its mask/paste opening, or its authored-shape
## provenance. Order fixed so the serialized key order is stable.
const PAD_OPTIONAL_KEYS: Array = [
	"corner_rratio", "raw_shape", "solder_mask_margin", "solder_paste_margin"]


## Whether a serialized dict should carry a `pads` key at all: the component
## really has lands, or it authored an explicitly empty list. A pins-only
## component emits NO key, so the worker resolves its footprint from the
## library instead of reading "zero pads" (see pads_authored).
func _emits_pads() -> bool:
	return pads_authored or not pads.is_empty()


## Serialize the pads array to a JSON-safe list (shared by to_dict/to_board_dict).
func _pads_to_list() -> Array:
	var pads_list := []
	for pad in pads:
		var pad_pos: Vector2 = pad.get("position", Vector2.ZERO)
		var pad_size: Vector2 = pad.get("size", Vector2(1, 1))
		var drill_val = pad.get("drill", Vector2.ZERO)
		var drill_dict: Dictionary
		if drill_val is Vector2:
			drill_dict = {"x": drill_val.x, "y": drill_val.y}
		else:
			# Legacy: float drill value
			var d := float(drill_val) if drill_val != null else 0.0
			drill_dict = {"x": d, "y": d}
		var entry := {
			"number": pad.get("number", ""),
			"type": pad.get("type", "smd"),
			"shape": pad.get("shape", "rect"),
			"position": {"x": pad_pos.x, "y": pad_pos.y},
			"size": {"width": pad_size.x, "height": pad_size.y},
			"drill": drill_dict,
			"layers": pad.get("layers", [])
		}
		# Emitted only when set, matching the worker's own omit-zero convention
		# for this key — an unrotated pad's serialized shape stays unchanged.
		var pad_rotation := float(pad.get("rotation", 0.0))
		if pad_rotation != 0.0:
			entry["rotation"] = pad_rotation
		# The fab-affecting optionals, present-only in exact parity with the
		# worker's two producers (resolve._pads_from_parsed,
		# footprint_def.to_board_pad_dicts): a pad that carried none stays
		# byte-identical, and a pad that carried them keeps them. Dropping them
		# here re-defaulted every roundrect's corner radius and every land's
		# mask opening the moment a board was saved from the panel.
		for key in PAD_OPTIONAL_KEYS:
			if pad.has(key):
				entry[key] = pad[key]
		pads_list.append(entry)
	return pads_list


## Deserialize a pads list (shared by from_dict/from_board_dict) into `pads`.
func _pads_from_list(pads_data: Array) -> void:
	pads.clear()
	for pad_data in pads_data:
		var pad_pos: Dictionary = pad_data.get("position", {})
		var pad_size: Dictionary = pad_data.get("size", {})
		# U4 (019f9509a54c): a resolved pad with no authored geometry now arrives
		# as size: {width: null, height: null} (worker no longer fabricates a
		# 1.0x1.0mm land — see pcb_worker/resolve.py::_pads_from_parsed). Dictionary
		# .get(key, default) only returns `default` when the KEY IS ABSENT; a
		# key present with a stored null value comes back as null, not 1 — so an
		# un-guarded Vector2(pad_size.get("width", 1), ...) would construct
		# Vector2(null, null) and error. Treat a null dimension as "no pad
		# geometry" the SAME way _pads_from_canonical_pins treats a bare
		# positional pin (no drill, no width/height): skip the render pad
		# entirely rather than inventing a size here too.
		var size_w = pad_size.get("width", 1)
		var size_h = pad_size.get("height", 1)
		if size_w == null or size_h == null:
			continue
		# Handle both legacy float drill and new Vector2 dict drill. A slot drill
		# arrives as {x, y} from the board contract and as {width, height} from
		# the footprint-geometry import — both spellings mean the same hole.
		var drill_raw = pad_data.get("drill", 0.0)
		var drill_vec := Vector2.ZERO
		if drill_raw is Dictionary:
			drill_vec = Vector2(
				float(drill_raw.get("x", drill_raw.get("width", 0.0))),
				float(drill_raw.get("y", drill_raw.get("height", 0.0))))
		elif drill_raw is float or drill_raw is int:
			var d := float(drill_raw)
			drill_vec = Vector2(d, d)
		var pad := {
			"number": pad_data.get("number", ""),
			"type": pad_data.get("type", "smd"),
			"shape": pad_data.get("shape", "rect"),
			"position": Vector2(pad_pos.get("x", 0), pad_pos.get("y", 0)),
			"size": Vector2(size_w, size_h),
			# The pad's own rotation WITHIN the footprint, degrees, same CW
			# convention as the component's rotation_deg. Part of the pad's
			# shape: a 2.0x0.5 pad at rotation 90 is vertical, not horizontal.
			"rotation": float(pad_data.get("rotation", 0.0)),
			"drill": drill_vec,
			"layers": pad_data.get("layers", [])
		}
		# The fab-affecting optionals ride along: corner_rratio is the
		# roundrect's real corner radius (as a fraction of the short side),
		# raw_shape is the footprint-AUTHORED shape token, and the two margins
		# are per-side mask/paste growth over copper. Present-only, so a key
		# that was absent stays absent and `pad.has(key)` on the way back out
		# asks the same "was this authored" question the worker asked.
		for key in PAD_OPTIONAL_KEYS:
			var value: Variant = pad_data.get(key)
			if value != null:
				pad[key] = value
		# The footprint's symbolic pin name, present-only (get_pin_name reads it).
		var pad_name := str(pad_data.get("name", ""))
		if not pad_name.is_empty():
			pad["name"] = pad_name
		pads.append(pad)
	# THE LANDS THEMSELVES ARE THE RESOLVED-VS-FALLBACK FACT, exactly as the
	# worker defines it (pad_source.has_resolved_pads: a non-empty `pads` list is
	# the single ground truth, mirrored across the boundary under this key).
	#
	# The worker only WRITES has_pad_geometry on the footprint-resolve success
	# path, so a part that authors its lands inline — geometry the fab emitters
	# use verbatim — arrives with real pads and no key at all. Trusting the key
	# alone made every consumer that gates on it (the copper-contact predicate,
	# the pad renderer, the unresolved badge) discard those lands: contact then
	# fell back to a coincidence disc at the pin centre and reported copper
	# sitting ON a land as a free end, while the worker's DRC called it joined.
	if not pads.is_empty():
		has_pad_geometry = true


## Synthesize render pads from geometry-bearing canonical pins. Worker-authored
## boards express pad geometry ON the pins (drill_mm/annulus_diameter_mm for
## through-hole, pad_width_mm/pad_height_mm for SMD) and carry no separate `pads`
## array, so load_from_board_dict falls back here. Produces the same internal pad
## shape as _pads_from_list. When fit_body is true (the dict gave no width/height)
## the body box is fitted to the synthesized pad extents.
func _pads_from_canonical_pins(pin_list: Array, fit_body: bool) -> void:
	pads.clear()
	var synthesized := false
	for pd in pin_list:
		if not (pd is Dictionary):
			continue
		var pos := Vector2(float(pd.get("x_mm", 0.0)), float(pd.get("y_mm", 0.0)))
		var drill := float(pd.get("drill_mm", 0.0))
		var annulus := float(pd.get("annulus_diameter_mm", 0.0))
		var pw := float(pd.get("pad_width_mm", 0.0))
		var ph := float(pd.get("pad_height_mm", 0.0))
		var pad := {
			"number": str(pd.get("number", "")),
			"name": str(pd.get("name", "")),
			"position": pos,
		}
		if drill > 0.0:
			var d := annulus if annulus > 0.0 else drill * 2.0
			# "thru_hole" (NOT "tht") — this is the pad's stored type field, whose
			# vocabulary is smd/thru_hole/np_thru_hole (see the pad-shape docstring
			# above). The canvas gates the drill-hole render on
			# pad_type in ["thru_hole","np_thru_hole"] (pcb_canvas _draw_component_pads);
			# emitting "tht" here left load_board THT pads rendering as solid discs
			# with no hole. "tht" is only the setup_generic_pins SIZING argument, not
			# a stored type. (Bug 019f75c24bd2.)
			pad["type"] = "thru_hole"
			pad["shape"] = "circle"
			pad["size"] = Vector2(d, d)
			pad["drill"] = Vector2(drill, drill)
			pad["layers"] = ["F.Cu", "B.Cu"]
		elif pw > 0.0 or ph > 0.0:
			pad["type"] = "smd"
			pad["shape"] = "rect"
			pad["size"] = Vector2(pw if pw > 0.0 else 1.0, ph if ph > 0.0 else 1.0)
			pad["drill"] = Vector2.ZERO
			# FOOTPRINT-LOCAL, like every other field on a land: the front face
			# of the package. placed_pad_layers turns it into B.Cu for a
			# back-mounted part, and to_board_dict hands the worker the same
			# local list its own placement rule expects. Naming the BOARD side
			# here would be flipped a second time downstream, landing a back
			# part's copper on the front.
			pad["layers"] = ["F.Cu"]
		else:
			# Bare positional pin (no pad geometry) — no render pad.
			continue
		pads.append(pad)
		synthesized = true
	if synthesized:
		has_pad_geometry = true
		if fit_body:
			_fit_body_to_pads()


## Fit the body box (width/height/local_bounds/bbox_center_offset) to the current
## pad extents — used when a canonical board provided pad geometry but no explicit
## body dimensions (worker-authored boards).
func _fit_body_to_pads() -> void:
	if pads.is_empty():
		return
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for pad in pads:
		var pos: Vector2 = pad.get("position", Vector2.ZERO)
		var sz: Vector2 = pad.get("size", Vector2.ZERO)
		min_p.x = minf(min_p.x, pos.x - sz.x / 2.0)
		min_p.y = minf(min_p.y, pos.y - sz.y / 2.0)
		max_p.x = maxf(max_p.x, pos.x + sz.x / 2.0)
		max_p.y = maxf(max_p.y, pos.y + sz.y / 2.0)
	width = max_p.x - min_p.x
	height = max_p.y - min_p.y
	local_bounds = Rect2(min_p.x, min_p.y, width, height)
	bbox_center_offset = (min_p + max_p) * 0.5


## Serialize to dictionary (legacy .minpcb shape — undo snapshots + Round-B)
func to_dict() -> Dictionary:
	var pins_dict := {}
	for pin_name in pins:
		var pin_pos: Vector2 = pins[pin_name]
		pins_dict[pin_name] = {"x": pin_pos.x, "y": pin_pos.y}

	var d := {
		"id": id,
		"footprint": get_footprint_name(),
		"footprint_id": footprint_id,
		"position": {"x": position.x, "y": position.y},
		"rotation": rotation,
		"width": width,
		"height": height,
		"local_bounds": {"x": local_bounds.position.x, "y": local_bounds.position.y, "w": local_bounds.size.x, "h": local_bounds.size.y},
		"pins": pins_dict,
		"pads": _pads_to_list(),
		"has_pad_geometry": has_pad_geometry,
		"footprint_resolved": footprint_resolved,
		"graphics": _graphics_to_list(),
		"refdes_anchor": refdes_anchor.duplicate(),
		# The AUTHORED half rides the undo shape too: history round-trips
		# reconstruct components from this dict, and a snapshot that carried
		# only the effective anchor would silently demote a placed designator
		# back to derived on the first undo.
		"refdes_placement": refdes_placement.duplicate(),
		"bbox_center_offset": {"x": bbox_center_offset.x, "y": bbox_center_offset.y},
		"properties": properties.duplicate(),
		"layer": layer,
		"color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a},
		"label_visible": label_visible,
		"locked": locked,
		# CANONICAL PASSTHROUGH ON THE LEGACY CODEC (Codex review 1086 finding 3).
		# This shape is not just the .minpcb file format — PCBData._serialize_
		# components uses it for UNDO HISTORY, and history round-trips
		# reconstruct components from it. Without these two keys an undo after
		# a canonical load silently erased `assembly: exclude`, `mpn`, and pin
		# drill/annulus overrides, and the next promote wrote that loss to the
		# design of record. Nested under one key each so they cannot collide
		# with a legacy field name.
		"canonical_extra": canonical_extra.duplicate(true),
		"pin_extra": pin_extra.duplicate(true)
	}
	# A pins-only component states no `pads` key on EITHER codec (_emits_pads).
	# Undo history round-trips through this shape, so an undo must not turn a
	# library-resolved part into one claiming zero lands.
	if not _emits_pads():
		d.erase("pads")
	return d


## Deserialize from dictionary (legacy .minpcb shape)
func load_from_dict(data: Dictionary) -> void:
	_loading_fields = true
	id = data.get("id", "")
	set_footprint_by_name(str(data.get("footprint", "CUSTOM")))
	footprint_id = data.get("footprint_id", "")

	var pos_data: Dictionary = data.get("position", {})
	position = Vector2(pos_data.get("x", 0), pos_data.get("y", 0))

	rotation = data.get("rotation", 0.0)
	width = data.get("width", 5.0)
	height = data.get("height", 2.5)

	# Load local_bounds or compute from width/height
	var bounds_data: Dictionary = data.get("local_bounds", {})
	if bounds_data.size() > 0:
		local_bounds = Rect2(
			bounds_data.get("x", -width / 2.0),
			bounds_data.get("y", -height / 2.0),
			bounds_data.get("w", width),
			bounds_data.get("h", height)
		)
	else:
		# Default: centered at anchor
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)

	pins.clear()
	var pins_data: Dictionary = data.get("pins", {})
	for pin_name in pins_data:
		var pin_pos_data: Dictionary = pins_data[pin_name]
		pins[pin_name] = Vector2(pin_pos_data.get("x", 0), pin_pos_data.get("y", 0))

	# Load pad geometry
	has_pad_geometry = data.get("has_pad_geometry", false)
	footprint_resolved = bool(data.get("footprint_resolved", false))
	var bbox_offset_data: Dictionary = data.get("bbox_center_offset", {})
	bbox_center_offset = Vector2(bbox_offset_data.get("x", 0), bbox_offset_data.get("y", 0))
	var raw_pads: Variant = data.get("pads")
	pads_authored = raw_pads is Array
	_pads_from_list(raw_pads if pads_authored else [])
	_graphics_from_list(data.get("graphics", []))
	# Authored FIRST: the overlay reads it.
	refdes_placement = _anchor_from_any(data.get("refdes_placement")).duplicate()
	_adopt_derived_anchor(_anchor_from_any(data.get("refdes_anchor")))

	# U1-render unit 2: when the snapshot gave no explicit size (no local_bounds,
	# no width/height Extra), replace the untouched default/centered bounds with
	# the real courtyard/silk extent. Explicit width/height or local_bounds in
	# `data` always wins — checked the same way as `data.has(...)` above, never
	# by comparing against a hardcoded default value.
	if bounds_data.is_empty() and not data.has("width") and not data.has("height"):
		_derive_bounds_from_graphics()

	properties = data.get("properties", {}).duplicate()
	layer = data.get("layer", "top")

	var color_data: Dictionary = data.get("color", {})
	if color_data.size() > 0:
		color = Color(
			color_data.get("r", 0.2),
			color_data.get("g", 0.6),
			color_data.get("b", 0.3),
			color_data.get("a", 1.0)
		)

	label_visible = data.get("label_visible", true)
	locked = data.get("locked", false)
	# Restore the canonical passthrough (Codex review 1086 finding 3) — the
	# write half is in to_dict(). Absent keys leave EMPTY dicts rather than
	# stale state: a legacy .minpcb that predates these fields genuinely has
	# no extras, and inheriting the previous component's would be worse than
	# having none.
	var ce = data.get("canonical_extra", {})
	canonical_extra = (ce as Dictionary).duplicate(true) if ce is Dictionary else {}
	# Panel state saved before the designator became derived parked the
	# rendered strokes in here, and to_board_dict re-emits the passthrough
	# verbatim — which is how one component's designator reached another
	# component's saved board. Nothing renders from them any more; drop them
	# on the way in so no board written from this session can carry them.
	canonical_extra.erase("refdes_graphics")
	var pe = data.get("pin_extra", {})
	pin_extra = (pe as Dictionary).duplicate(true) if pe is Dictionary else {}

	# ONE render, from the ref and anchor this load finished with.
	_loading_fields = false
	_refresh_refdes_graphics()


## Create from dictionary (static constructor, legacy shape)
static func from_dict(data: Dictionary):
	var component := _Self.new()
	component.load_from_dict(data)
	return component


# ── Canonical boundary (pcb/internal/board Component) ─────────────────────────
# Canonical fields: ref / footprint / value / x_mm / y_mm / rotation_deg / layer
# / pins:[{number,x_mm,y_mm}]. Render detail is emitted as canonical "Extra"
# (sibling keys) — the exact set minpcb.go parks in Component.Extra so YAML
# round-trips it losslessly. Value is dual-written (canonical `value` + inside
# `properties`) mirroring minpcb.go, which extracts properties.value → Value AND
# still parks properties.

## Serialize to a canonical board-contract component dict.
func to_board_dict() -> Dictionary:
	var d := {
		"ref": id,
		"footprint": get_canonical_footprint_name(),
		"x_mm": position.x,
		"y_mm": position.y,
		"rotation_deg": rotation,
		"layer": layer,
	}
	var val := str(properties.get("value", ""))
	if not val.is_empty():
		d["value"] = val

	# Re-emit the preserved canonical extras (assembly, mpn, ...) — knowns win
	# on any collision, so a stale extra can never clobber a modeled field.
	for extra_key in canonical_extra:
		if not d.has(extra_key):
			d[extra_key] = canonical_extra[extra_key]

	# pins: name→offset map → sorted list of {number, x_mm, y_mm} + each pin's
	# preserved fab-geometry extras (drill_mm/annulus_diameter_mm/...).
	var pin_keys := pins.keys()
	pin_keys.sort()
	var pin_list := []
	for k in pin_keys:
		var p: Vector2 = pins[k]
		var pin_dict := {"number": str(k), "x_mm": p.x, "y_mm": p.y}
		var extras: Dictionary = pin_extra.get(str(k), {})
		for ek in extras:
			if not pin_dict.has(ek):
				pin_dict[ek] = extras[ek]
		pin_list.append(pin_dict)
	d["pins"] = pin_list

	# Canonical Extra (render detail — mirrors minpcb.go knownComponentFields).
	d["footprint_id"] = footprint_id
	d["width"] = width
	d["height"] = height
	d["local_bounds"] = {
		"x": local_bounds.position.x, "y": local_bounds.position.y,
		"w": local_bounds.size.x, "h": local_bounds.size.y}
	# Present-only: the `pads` KEY is what tells the worker the board owns this
	# component's geometry outright (_emits_pads / pads_authored).
	if _emits_pads():
		d["pads"] = _pads_to_list()
	d["has_pad_geometry"] = has_pad_geometry
	# Present-only, and straight off the live field rather than out of the
	# canonical_extra passthrough: the flag on the dict must be THIS session's
	# resolve result, which is what canonical_wire_board reads to decide whether
	# the worker can re-derive the lands it is about to drop. Emitting it
	# unconditionally would put `false` on the wire for every unresolved part
	# for no reader; emitting it from canonical_extra would replay whatever the
	# document was saved with. to_saved_board_dict strips it from anything that
	# gets written, so no file ever carries it.
	if footprint_resolved:
		d["footprint_resolved"] = true
	d["graphics"] = _graphics_to_list()
	# AUTHORED BOARD STATE, present-only. Absent means nobody set this
	# component's designator and the worker's derivation applies unchanged, so a
	# board that has never used set_refdes serializes exactly as it did before
	# the key existed. `refdes_anchor` is NOT emitted here — it is the effective
	# value a resolve computes, and writing it would freeze one host's library
	# into the document (the reason it is a derived key on the Go side).
	if not refdes_placement.is_empty():
		d["refdes_placement"] = refdes_placement.duplicate()
	d["bbox_center_offset"] = {"x": bbox_center_offset.x, "y": bbox_center_offset.y}
	d["properties"] = properties.duplicate()
	d["color"] = {"r": color.r, "g": color.g, "b": color.b, "a": color.a}
	d["label_visible"] = label_visible
	d["locked"] = locked
	return d


## Restore from a canonical board-contract component dict.
##
## `resolve_is_live` says whether `data`'s footprint_resolved flags were
## produced by a resolve run on THIS machine moments ago (the pcb.deserialize
## board-load path, which resolves against this host's library before replying)
## rather than read back off a document. Only that caller may say true; a file
## restore, an undo snapshot and a hand-built dict all leave it false, so a
## stale flag saved elsewhere cannot survive the load. See footprint_resolved.
func load_from_board_dict(data: Dictionary, resolve_is_live: bool = false) -> void:
	_loading_fields = true
	id = str(data.get("ref", data.get("id", "")))
	var authored_fp := str(data.get("footprint", "CUSTOM"))
	set_footprint_by_name(authored_fp)
	footprint_id = str(data.get("footprint_id", ""))
	# Read-side ref preservation (docket 019fcb32d81c / the 019fa9640ac1 hard
	# prerequisite): a canonical library ref ("Lib:Name") is no enum name, so
	# set_footprint_by_name maps it to CUSTOM — and without keeping the
	# authored string, to_board_dict could only ever hand the worker "CUSTOM",
	# which the hermetic compiler refuses. An explicit footprint_id from the
	# Extra round-trip wins; otherwise the authored ref IS the identity.
	if footprint_id.is_empty() and footprint == FootprintType.CUSTOM and authored_fp != "CUSTOM":
		footprint_id = authored_fp
	position = Vector2(float(data.get("x_mm", 0.0)), float(data.get("y_mm", 0.0)))
	rotation = float(data.get("rotation_deg", 0.0))
	layer = str(data.get("layer", "top"))
	width = float(data.get("width", 5.0))
	height = float(data.get("height", 2.5))

	var bounds_data: Dictionary = data.get("local_bounds", {})
	if bounds_data.size() > 0:
		local_bounds = Rect2(
			bounds_data.get("x", -width / 2.0),
			bounds_data.get("y", -height / 2.0),
			bounds_data.get("w", width),
			bounds_data.get("h", height))
	else:
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)

	# pins: canonical list of {number,x_mm,y_mm} → name→offset map. Every key
	# BEYOND number/x_mm/y_mm (drill_mm, annulus_diameter_mm, plated,
	# pad_width_mm, pad_height_mm, name, ...) is AUTHORED FAB GEOMETRY the
	# model does not represent — preserved per pin and re-emitted verbatim by
	# to_board_dict. Epoch CPN1 found the loss live: the coupon's TP1
	# min-annular override (drill 0.6 / annulus 0.96) silently reverted to the
	# library default across the first real promote, killing the witness the
	# board exists to carry.
	pins.clear()
	pin_extra.clear()
	var pin_list: Array = data.get("pins", [])
	for pd in pin_list:
		if pd is Dictionary:
			var pnum := str(pd.get("number", ""))
			pins[pnum] = Vector2(
				float(pd.get("x_mm", 0.0)), float(pd.get("y_mm", 0.0)))
			var extras := {}
			for k in (pd as Dictionary):
				if k not in ["number", "x_mm", "y_mm"]:
					extras[k] = pd[k]
			if not extras.is_empty():
				pin_extra[pnum] = extras

	has_pad_geometry = data.get("has_pad_geometry", false)
	footprint_resolved = resolve_is_live and bool(data.get("footprint_resolved", false))
	var bbox_offset_data: Dictionary = data.get("bbox_center_offset", {})
	bbox_center_offset = Vector2(bbox_offset_data.get("x", 0), bbox_offset_data.get("y", 0))
	# Render pads: editor-authored boards carry an explicit `pads` array (render
	# detail parked in canonical Extra). Worker-authored boards (the worker
	# canonical YAML) instead carry pad geometry ON the pins themselves and have
	# NO `pads` array — synthesize the render pads from that pin geometry so a
	# whole-board load (minerva_pcb_load_board) renders real pads, not
	# placeholders. Fit the body to the pads only when the dict gave no size.
	# Branch on the KEY, matching the worker's own FULL-vs-PARTIAL rule: a
	# stated `pads` list is the complete set of lands even when it is empty, so
	# synthesizing pads from the pins there would invent copper the board says
	# it does not have. A `pads` value that is not a list is unreadable as
	# geometry and takes the pins path.
	var raw_pads: Variant = data.get("pads")
	pads_authored = raw_pads is Array
	if pads_authored:
		_pads_from_list(raw_pads)
	else:
		_pads_from_canonical_pins(pin_list, not (data.has("width") or data.has("height")))
	_graphics_from_list(data.get("graphics", []))
	# Authored FIRST: the overlay reads it. A document's authored placement is
	# what makes the label draw where it was SET even before this session's
	# resolve has answered — and the resolve answers with the same overlay
	# applied, so the two agree.
	refdes_placement = _anchor_from_any(data.get("refdes_placement")).duplicate()
	_adopt_derived_anchor(_anchor_from_any(data.get("refdes_anchor")))

	# U1-render unit 2: when the board dict gave no explicit size (no
	# local_bounds, no width/height Extra — the same "not (data.has(...))"
	# check the pad-fit call above uses for `fit_body`), replace whatever got
	# computed above — the default-centered rect OR the _fit_body_to_pads()
	# pad-extent fit — with the real courtyard/silk extent. The courtyard is
	# the module's true footprint; pads/defaults are only fallbacks for when
	# nothing better is known, so this intentionally runs AFTER and can
	# override the pad-fit result. Explicit local_bounds/width/height in
	# `data` (checked identically) always wins and is never touched.
	if bounds_data.is_empty() and not data.has("width") and not data.has("height"):
		_derive_bounds_from_graphics()

	properties = (data.get("properties", {}) as Dictionary).duplicate()
	# `value` is derivative of properties.value (minpcb dual-write). Only adopt the
	# canonical scalar when properties itself did not carry it.
	if not properties.has("value") and data.has("value"):
		properties["value"] = str(data["value"])

	var color_data: Dictionary = data.get("color", {})
	if color_data.size() > 0:
		color = Color(
			color_data.get("r", 0.2),
			color_data.get("g", 0.6),
			color_data.get("b", 0.3),
			color_data.get("a", 1.0))
	label_visible = data.get("label_visible", true)
	locked = data.get("locked", false)

	# Preserve every canonical key this model has no field for (assembly, mpn,
	# future schema growth) — see canonical_extra's declaration. The known set
	# below is every key the reads above consumed; anything else is authored
	# design intent that must survive the round trip verbatim.
	canonical_extra.clear()
	# footprint_resolved is listed here so the passthrough cannot re-emit it:
	# it is session state (see its declaration), and canonical_extra is the one
	# path by which a saved flag could otherwise reach to_board_dict again.
	# refdes_graphics is listed for the same reason and read by nothing: older
	# boards carry a RENDERING of some component's designator, and parking it
	# in the passthrough is what re-emitted one part's name under another's.
	var known := ["ref", "id", "footprint", "footprint_id", "x_mm", "y_mm",
		"rotation_deg", "layer", "width", "height", "local_bounds", "pads",
		"has_pad_geometry", "footprint_resolved", "graphics",
		"refdes_anchor", "refdes_graphics", "refdes_placement",
		"bbox_center_offset", "properties",
		"color", "label_visible", "locked", "pins", "value"]
	for k in data:
		if k not in known:
			canonical_extra[k] = data[k]

	# ONE render, from the ref and anchor this load finished with.
	_loading_fields = false
	_refresh_refdes_graphics()


## Create from a canonical board-contract component dict (static constructor).
static func from_board_dict(data: Dictionary, resolve_is_live: bool = false):
	var component := _Self.new()
	component.load_from_board_dict(data, resolve_is_live)
	return component


## Get a human-readable description
func get_description() -> String:
	var value_str := ""
	if properties.has("value"):
		value_str = " (%s)" % properties["value"]
	return "%s%s - %s on %s layer" % [id, value_str, get_footprint_name(), layer]
