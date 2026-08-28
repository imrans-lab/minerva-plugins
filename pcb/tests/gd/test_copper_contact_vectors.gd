extends SceneTree
## The panel half of the shared pad-contact vectors (pcb/spec/contact).
##
## worker/tests/test_copper_contact_vectors.py runs the SAME directory against
## the worker's implementation. Both runners ENUMERATE it, so a case the two
## sides answer differently cannot be added without one of them going red — and
## that is the only thing keeping the panel's predicate and the connectivity
## DRC's from drifting, since neither side can call the other while the answer
## is needed.
##
## The expected values are not in this file. They are in the vectors, each with
## its hand derivation written out beside it — see spec/contact/README.md.
##
## Run via pcb/scripts/run-gd-tests.sh <minerva-checkout> (same convention as
## every suite here — see test_routing_workspace_model.gd's header).

const Contact := preload("res://../../minerva-plugins/pcb/ui/model/pcb_copper_contact.gd")
const PCBComponentScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_component.gd")
const PCBDataScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")

const VECTOR_DIR := "res://../../minerva-plugins/pcb/spec/contact"

## The board stack a vector's copper lives on. The vectors state their layers
## explicitly, so this only feeds the kinds of copper that pierce every layer.
static func _stack() -> PackedStringArray:
	return PackedStringArray(["top", "bottom"])

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Pad contact: the shared spec/contact vectors ===\n")
	var names := _vector_names()
	check("the vector directory is readable and not empty", names.size() > 0)
	for name in names:
		_run_vector(name)
	_run_symmetry(names)
	_run_unknown_land()
	_run_unknown_via()
	_run_land_rotation_is_placed()
	_run_loaded_inline_lands()
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


func _vector_names() -> PackedStringArray:
	var out := PackedStringArray()
	# Globalized: the vectors live outside the Minerva project the runner boots,
	# so res:// reaches them for a FILE read but DirAccess wants a real path.
	var dir := DirAccess.open(ProjectSettings.globalize_path(VECTOR_DIR))
	if dir == null:
		dir = DirAccess.open(VECTOR_DIR)
	if dir == null:
		printerr("  cannot open %s" % VECTOR_DIR)
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and not entry.begins_with("."):
			out.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _case(name: String) -> Dictionary:
	var path := "%s/%s/case.json" % [VECTOR_DIR, name]
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


## The vector's pad as a REAL component carrying one land, so the same builder
## the board walk uses produces the node.
##
## An OPTIONAL `pad.component` block gives that component a PLACEMENT — position,
## rotation and side. With it, the land's `at`, `rotation_deg` and `layers` are
## FOOTPRINT-LOCAL and pcb_component.get_transform / placed_pad_layers put them
## on the board; that is the only way these vectors can pin what a back-mounted
## part does to its own lands, since no footprint authors the side it will end up
## on. Without it the component sits at the origin unrotated on the front and the
## land holds the board-frame centre and angle, exactly as before.
func _pad_node(spec: Dictionary) -> Dictionary:
	var placement: Dictionary = spec.get("component", {})
	var comp = PCBComponentScript.new()
	comp.id = "P1"
	var anchor: Array = placement.get("at", [0.0, 0.0])
	comp.position = Vector2(float(anchor[0]), float(anchor[1]))
	comp.rotation = float(placement.get("rotation_deg", 0.0))
	comp.layer = str(placement.get("layer", "top"))
	comp.has_pad_geometry = true
	var at: Array = spec["at"]
	var size: Array = spec["size"]
	var land := {
		"number": "1",
		"type": str(spec.get("type", "smd")),
		"shape": str(spec["shape"]),
		"position": Vector2(float(at[0]), float(at[1])),
		"size": Vector2(float(size[0]), float(size[1])),
		"rotation": float(spec.get("rotation_deg", 0.0)),
		"layers": spec.get("layers", []),
	}
	if spec.has("corner_rratio"):
		land["corner_rratio"] = float(spec["corner_rratio"])
	comp.pads = [land]
	comp.pins = {"1": Vector2(float(at[0]), float(at[1]))}
	# only_land = false: the sole-land safeguard adds the PIN centre as a second
	# zero-swell point, which the worker has no second field to disagree with.
	# The vectors compare LAND geometry (see spec/contact/README.md).
	return Contact.physical_pad_node(comp, land, _stack(),
		comp.get_pin_world_position("1"), false)


## THE LAND'S OWN ANGLE IS PLACED, not merely stored.
##
## A vector states a land's rotation and its component's placement separately,
## and a build that dropped either composition still answers most cases the same
## way — a square land, or one whose two angles cancel, touches the same copper
## either way. These two are the pair that cannot: ONE oblong land turned 90
## inside its footprint, read once on an unrotated part and once on a part turned
## 90 itself. The board-frame extents must SWAP. A build that ignores the land's
## own turn, or that fails to compose it with the part's, leaves them equal.
func _run_land_rotation_is_placed() -> void:
	var spec := {
		"at": [1.0, 0.0], "size": [2.0, 0.5], "shape": "rect",
		"rotation_deg": 90.0, "layers": ["F.Cu"],
	}
	var upright_spec := spec.duplicate(true)
	upright_spec["component"] = {"at": [10.0, 20.0], "rotation_deg": 0.0, "layer": "top"}
	var turned_spec := spec.duplicate(true)
	turned_spec["component"] = {"at": [10.0, 20.0], "rotation_deg": 90.0, "layer": "top"}

	var a := _land_extent(_pad_node(upright_spec))
	var b := _land_extent(_pad_node(turned_spec))
	check("a land turned 90 inside its footprint stands UP on an unrotated part (got %0.2f x %0.2f)"
			% [a.x, a.y],
		is_equal_approx(a.x, 0.5) and is_equal_approx(a.y, 2.0))
	check("...and lies FLAT once the part is turned 90 too — the two angles compose (got %0.2f x %0.2f)"
			% [b.x, b.y],
		is_equal_approx(b.x, 2.0) and is_equal_approx(b.y, 0.5))

	# The land's OFFSET rides the same transform as its angle, so the turned
	# part carries its land round with it: footprint-local (1, 0) at rotation 90
	# is one millimetre off the anchor along y.
	var turned := _pad_node(turned_spec)
	check("...and the land's centre is placed by that same transform (got %s)"
			% str(turned["at"]),
		(turned["at"] as Vector2).is_equal_approx(Vector2(10.0, 19.0)))


## The board-frame width and height of a rect land's quad — the shape's own
## extent, read off the built node rather than re-derived from the spec.
func _land_extent(node: Dictionary) -> Vector2:
	var quad: PackedVector2Array = (node["polys"] as Array)[0]
	var lo: Vector2 = quad[0]
	var hi: Vector2 = quad[0]
	for p in quad:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	return hi - lo


## The vector's pour region as the conductor node the fill builds: one ring, on
## the zone's own layer.
func _region_node(spec: Dictionary) -> Dictionary:
	var ring := PackedVector2Array()
	for p in (spec["ring"] as Array):
		var xy: Array = p
		ring.append(Vector2(float(xy[0]), float(xy[1])))
	return Contact.region_node(ring, spec.get("layer", "top"))


## The vector's trace as the swept copper a whole run is: what a via or a land
## is measured against when the RUN is the target rather than the probe.
func _trace_node(spec: Dictionary) -> Dictionary:
	var a: Array = spec["a"]
	var b: Array = spec["b"]
	return Contact.trace_node(PackedVector2Array([
			Vector2(float(a[0]), float(a[1])),
			Vector2(float(b[0]), float(b[1]))]),
		float(spec.get("width_mm", 0.0)), spec.get("layer", "top"))


## The copper the vector's probe is measured AGAINST — a pad's land, a pour's
## filled region, or a trace's swept run. Three builders, ONE predicate: that is
## the whole point of the node shape, so these vectors exercise all of them
## through it.
func _target_node(case: Dictionary) -> Dictionary:
	if case.has("region"):
		return _region_node(case["region"])
	if case.has("trace"):
		return _trace_node(case["trace"])
	return _pad_node(case["pad"])


func _copper_node(spec: Dictionary) -> Dictionary:
	var a: Array = spec["a"]
	var start := Vector2(float(a[0]), float(a[1]))
	var width := float(spec.get("width_mm", 0.0))
	var layer = spec.get("layer", "top")
	if str(spec["kind"]) == "via":
		# LAYERS FROM THE CASE, not the whole stack: a vector that states a span
		# is the only way these vectors can ever pin a blind/buried barrel, and
		# the through span every board writes today says the same thing either
		# way. The RADIUS is half the stated diameter — the panel stores a via's
		# "size" as its outer diameter (PCBData.via_radius).
		return Contact.via_node(start, float(spec.get("diameter_mm", 0.0)) * 0.5,
			spec.get("layers", []))
	if str(spec["kind"]) == "endpoint":
		return Contact.endpoint_node(start, width, layer)
	var b: Array = spec["b"]
	return Contact.trace_node(
		PackedVector2Array([start, Vector2(float(b[0]), float(b[1]))]),
		width, layer)


func _run_vector(name: String) -> void:
	var case := _case(name)
	if case.is_empty():
		check("%s: case.json parses" % name, false)
		return
	var target := _target_node(case)
	var copper := _copper_node(case["copper"])
	var got := Contact.nodes_touch(copper, target)
	var want := bool(case["touches"])
	if got != want:
		printerr("  %s: %s" % [name, str(case.get("why", ""))])
	check("%s: touches == %s" % [name, str(want)], got == want)


## Copper reaching copper is not a directed relation. Every consumer picks its
## own argument order, so an asymmetric implementation would answer differently
## for the trace verbs than for the pin inspector.
func _run_symmetry(names: PackedStringArray) -> void:
	var asymmetric := 0
	for name in names:
		var case := _case(name)
		if case.is_empty():
			continue
		var target := _target_node(case)
		var copper := _copper_node(case["copper"])
		if Contact.nodes_touch(copper, target) != Contact.nodes_touch(target, copper):
			asymmetric += 1
			printerr("  asymmetric: %s" % name)
	check("the predicate answers the same in both argument orders",
		asymmetric == 0)


## A pin whose footprint never resolved has no land to be exact about. It keeps
## the small assumed disc — the one place the model guesses, and it guesses
## SMALL so copper merely passing near an unresolved pin does not read as
## landed on it.
##
## THE DISC IS THE BOARD'S CLEARANCE, the same derivation the worker runs
## (drc._board_clearance feeding copper_contact.pad_node's
## unknown_land_radius_mm), defaulting to the same number when the board
## declares none. A panel-only 0.3 answered "joined" for a probe 0.25 mm off
## centre that the census called clear — a disagreement no vector could catch,
## because every vector states a size.
func _run_unknown_land() -> void:
	var comp = PCBComponentScript.new()
	comp.id = "U9"
	comp.position = Vector2.ZERO
	comp.rotation = 0.0
	comp.layer = "top"
	comp.has_pad_geometry = false
	comp.pins = {"1": Vector2(0.0, 0.0)}
	# The default radius is 0.2 and the probe carries no width, so 0.15mm out is
	# on the assumed copper and 0.25mm out is 0.05mm clear of it — the SAME two
	# probes worker/tests/test_copper_contact_vectors.py measures.
	check("the default disc is the worker's default coincidence tolerance",
		is_equal_approx(Contact.DEFAULT_UNKNOWN_LAND_RADIUS_MM, 0.2))
	var inside := Contact.endpoint_node(Vector2(0.15, 0.0), 0.0, "top")
	var outside := Contact.endpoint_node(Vector2(0.25, 0.0), 0.0, "top")
	check("a geometry-less pin is reached inside its assumed radius",
		Contact.copper_joins_pin(inside, comp, "1", _stack()))
	check("a geometry-less pin is not reached outside it",
		not Contact.copper_joins_pin(outside, comp, "1", _stack()))

	# A BOARD THAT DECLARES A CLEARANCE SETS THE DISC. Same rule as the worker's,
	# so the 0.25mm probe flips together on both sides rather than only here.
	var loose = PCBDataScript.new()
	loose.design_rules = {"clearance_mm": 0.35}
	check("the board's own clearance is the radius",
		is_equal_approx(Contact.unknown_land_radius(loose), 0.35))
	check("...and the probe that was clear is now landed",
		Contact.copper_joins_pin(outside, comp, "1", _stack(),
			Contact.unknown_land_radius(loose)))
	var plain = PCBDataScript.new()
	plain.design_rules = {}
	check("a board declaring no clearance falls back to the shared default",
		is_equal_approx(Contact.unknown_land_radius(plain),
			Contact.DEFAULT_UNKNOWN_LAND_RADIUS_MM))
	check("and so does no board at all (the headless answer)",
		is_equal_approx(Contact.unknown_land_radius(null),
			Contact.DEFAULT_UNKNOWN_LAND_RADIUS_MM))



## THE UNSIZED VIA — the barrel twin of the unknown land above.
##
## A via that declares no diameter gets the same disc an unsized land gets: the
## board's own clearance, defaulting to DEFAULT_UNKNOWN_LAND_RADIUS_MM. That is
## the rule drc._via_radius runs, so the two sides credit one barrel the same
## copper.
##
## The probe distance is what separates the two answers this used to have. A
## fixed 0.8 mm assumption here credited a 0.40 mm radius against the worker's
## 0.20, so a run ending 0.30 mm off an unsized barrel read joined on the panel
## and dangling in the census. No vector can catch it: both runners hand
## `copper.diameter_mm` straight to via_node, so an unsized via inside a case is
## a zero-radius disc on both sides and reaches neither fallback.
func _run_unknown_via() -> void:
	var plain = PCBDataScript.new()
	plain.design_rules = {}
	check("an unsized via falls back to the shared coincidence disc",
		is_equal_approx(PCBDataScript.via_radius({}, plain),
			Contact.DEFAULT_UNKNOWN_LAND_RADIUS_MM))
	check("a zero diameter is 'nobody has said', not a zero-sized barrel",
		is_equal_approx(PCBDataScript.via_radius({"size": 0.0}, plain),
			Contact.DEFAULT_UNKNOWN_LAND_RADIUS_MM))
	check("a stated size still wins",
		is_equal_approx(PCBDataScript.via_radius({"size": 0.8}, plain), 0.4))
	check("and no board at all is the same headless answer",
		is_equal_approx(PCBDataScript.via_radius({}),
			Contact.DEFAULT_UNKNOWN_LAND_RADIUS_MM))

	# The SAME two probes worker/tests/test_copper_contact_vectors.py measures
	# against the barrel: 0.15mm out is on the assumed copper, 0.30mm out is
	# 0.10mm clear of it — the distance the old 0.8mm assumption called landed.
	var barrel := Contact.via_node(Vector2.ZERO,
		PCBDataScript.via_radius({}, plain), ["top", "bottom"])
	var near := Contact.endpoint_node(Vector2(0.15, 0.0), 0.0, "top")
	var far := Contact.endpoint_node(Vector2(0.30, 0.0), 0.0, "top")
	check("an unsized barrel is reached inside its assumed radius",
		Contact.nodes_touch(near, barrel))
	check("an unsized barrel is not reached at the distance the old rule joined",
		not Contact.nodes_touch(far, barrel))

	# A BOARD THAT DECLARES A CLEARANCE SETS THE DISC, exactly as it does for a
	# land, so the far probe flips together on both sides rather than only here.
	var loose = PCBDataScript.new()
	loose.design_rules = {"clearance_mm": 0.35}
	check("the board's own clearance is the barrel radius too",
		is_equal_approx(PCBDataScript.via_radius({}, loose), 0.35))
	check("...and the probe that was clear is now landed",
		Contact.nodes_touch(far, Contact.via_node(Vector2.ZERO,
			PCBDataScript.via_radius({}, loose), ["top", "bottom"])))

## THE LOADED-BOARD SEAM: a part that authors its lands INLINE.
##
## Every vector above hands physical_pad_node a component this file builds by
## hand, pads assigned directly — so nothing above can see what the board LOADER
## does to those lands. A part whose footprint no library can supply authors its
## geometry inline instead, and the worker writes NO has_pad_geometry key for it
## (that key is written only on the footprint-resolve success path) while its
## own predicate still reads the lands as real (pad_source.has_resolved_pads: a
## non-empty `pads` list). A panel that gated on the key discarded those lands
## and fell back to a coincidence disc at the pin centre — copper sitting ON a
## rotated land, or in a roundrect's corner, then read as a FREE end while the
## connectivity DRC called it joined.
##
## The lands and probes are the HITL bench's R9 row, verbatim
## (worker/tests/testdata/hitl_bench.yaml); the worker's answer for the same
## four probes is pinned by worker/tests/test_pad_contact_rule.py.
func _run_loaded_inline_lands() -> void:
	# U9A: one 2.0 x 0.6 land with its OWN rotation 90 inside a part at rotation
	# 0, so the copper stands TALL — x 21.7..22.3, y 103.0..105.0.
	var rotated = _inline_part("U9A", 22.0, 104.0, {
		"number": "1", "type": "smd", "shape": "rect", "rotation": 90,
		"position": {"x": 0.0, "y": 0.0},
		"size": {"width": 2.0, "height": 0.6},
		"layers": ["F.Cu", "F.Mask", "F.Paste"]})
	check("an inline land survives the load", rotated.pads.size() == 1)
	check("the loader states pad geometry from the lands themselves",
		rotated.has_pad_geometry)
	# 0.8mm above the pin centre: 0.2mm inside the ROTATED land, 0.5mm outside
	# the same land unrotated. So this probe measures the pad rotation itself.
	var probe_a := Contact.endpoint_node(Vector2(22.0, 104.8), 0.25, "top")
	check("copper inside a rotated inline land is landed on it",
		Contact.copper_joins_pin(probe_a, rotated, "1", _stack()))
	var unrotated = _inline_part("U9A", 22.0, 104.0, {
		"number": "1", "type": "smd", "shape": "rect",
		"position": {"x": 0.0, "y": 0.0},
		"size": {"width": 2.0, "height": 0.6},
		"layers": ["F.Cu", "F.Mask", "F.Paste"]})
	check("...and clear of the same land unrotated",
		not Contact.copper_joins_pin(probe_a, unrotated, "1", _stack()))

	# U9B: a 2.0 x 2.0 roundrect with corner_rratio 0.25 — a 0.5mm corner
	# radius, so the inner core is 0.5 x 0.5 (spec vector 080's land, reached
	# here through the loader instead of by hand).
	var corner = _inline_part("U9B", 46.0, 104.0, {
		"number": "1", "type": "smd", "shape": "roundrect",
		"corner_rratio": 0.25, "position": {"x": 0.0, "y": 0.0},
		"size": {"width": 2.0, "height": 2.0},
		"layers": ["F.Cu", "F.Mask", "F.Paste"]})
	check("the load keeps the authored corner radius",
		is_equal_approx(float((corner.pads[0] as Dictionary).get("corner_rratio", 0.0)), 0.25))
	# 0.424mm from the nearest core corner: 0.076mm INSIDE the copper, and
	# 0.066mm outside it 0.1mm further out along the diagonal.
	check("copper in an inline roundrect's corner is landed on it",
		Contact.copper_joins_pin(
			Contact.endpoint_node(Vector2(46.8, 104.8), 0.05, "top"),
			corner, "1", _stack()))
	check("...and clear of it 0.1mm further out",
		not Contact.copper_joins_pin(
			Contact.endpoint_node(Vector2(46.9, 104.9), 0.05, "top"),
			corner, "1", _stack()))

	# THE TRACE TOOL MUST TERMINATE ON THESE LANDS. Its pad rung ranks a click
	# by pcb_component.pin_copper_distance — distance to the pad's COPPER, not
	# to its centre — so the pad a click lands on is the pad the predicate above
	# credits. A 0.6mm-wide land turned 90 degrees is hittable up its long axis,
	# which its unrotated self is not, and neither land's centre is anywhere
	# near these probes.
	check("a click on the rotated land's copper is 0mm from that pin",
		is_zero_approx(rotated.pin_copper_distance("1", Vector2(22.0, 104.8))))
	check("...and the same click is off the copper unrotated",
		unrotated.pin_copper_distance("1", Vector2(22.0, 104.8)) > 0.4)
	check("a click in the roundrect land's corner is 0mm from that pin",
		is_zero_approx(corner.pin_copper_distance("1", Vector2(46.8, 104.8))))


## One inline-geometry part as the LOADER makes it, from the canonical board
## dict the worker sends: no has_pad_geometry key, because its footprint never
## resolved from a library — the lands are the only statement of its copper.
func _inline_part(ref: String, x: float, y: float, pad: Dictionary):
	return PCBComponentScript.from_board_dict({
		"ref": ref, "footprint": "Bench_InlineLand_1P",
		"x_mm": x, "y_mm": y, "rotation_deg": 0.0, "layer": "top",
		"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}],
		"pads": [pad],
	})
