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


## The vector's pad as a REAL component carrying one land: the component sits at
## the origin unrotated and the land holds the board-frame centre and angle, so
## the same builder the board walk uses produces the node.
func _pad_node(spec: Dictionary) -> Dictionary:
	var comp = PCBComponentScript.new()
	comp.id = "P1"
	comp.position = Vector2.ZERO
	comp.rotation = 0.0
	comp.layer = "top"
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
		Vector2(float(at[0]), float(at[1])), false)


## The vector's pour region as the conductor node the fill builds: one ring, on
## the zone's own layer.
func _region_node(spec: Dictionary) -> Dictionary:
	var ring := PackedVector2Array()
	for p in (spec["ring"] as Array):
		var xy: Array = p
		ring.append(Vector2(float(xy[0]), float(xy[1])))
	return Contact.region_node(ring, spec.get("layer", "top"))


## The copper the vector's run is measured AGAINST — a pad's land, or a pour's
## filled region. Two builders, ONE predicate: that is the whole point of the
## node shape, so these vectors exercise both through it.
func _target_node(case: Dictionary) -> Dictionary:
	if case.has("region"):
		return _region_node(case["region"])
	return _pad_node(case["pad"])


func _copper_node(spec: Dictionary) -> Dictionary:
	var a: Array = spec["a"]
	var start := Vector2(float(a[0]), float(a[1]))
	var width := float(spec.get("width_mm", 0.0))
	var layer = spec.get("layer", "top")
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
func _run_unknown_land() -> void:
	var comp = PCBComponentScript.new()
	comp.id = "U9"
	comp.position = Vector2.ZERO
	comp.rotation = 0.0
	comp.layer = "top"
	comp.has_pad_geometry = false
	comp.pins = {"1": Vector2(0.0, 0.0)}
	# FALLBACK_PAD_RADIUS_MM is 0.3 and the probe carries no width, so 0.25mm
	# out is on the assumed copper and 0.35mm out is 0.05mm clear of it.
	var inside := Contact.endpoint_node(Vector2(0.25, 0.0), 0.0, "top")
	var outside := Contact.endpoint_node(Vector2(0.35, 0.0), 0.0, "top")
	check("a geometry-less pin is reached inside its assumed radius",
		Contact.copper_joins_pin(inside, comp, "1", _stack()))
	check("a geometry-less pin is not reached outside it",
		not Contact.copper_joins_pin(outside, comp, "1", _stack()))
