extends RefCounted
## minerva_cad_material — is the evaluated solid HERE, and how thick is it?
##
## WHY THIS VERB EXISTS. Every other check measures the solid AGAINST a
## reference: interference, clearance, fasteners. Air violates none of them, so
## a tray whose floor had been subtracted away passed all three on rev 4 and
## three floorless STLs were exported before anyone looked at a picture.
## minerva_cad_probe answers about a PIXEL of a pane, and the gauge is
## ray-sampled and answers about surfaces; neither of them can say "there is
## material at this world point".
##
## WHY THE WORKER AND NOT THE PANEL'S COLLIDERS. The panel holds a
## tessellation and physics bodies built from it, and containment read off
## those is a parity count over triangles — which a coincident-face seam (two
## faces a union left in the same plane) flips twice, reading material as air.
## The worker holds the B-Rep, and OCCT's BRepClass3d_SolidClassifier answers
## containment exactly, with no tessellation and no rays. So this module owns
## only the wiring: which source, which channel, and what comes back.
##
## `body` NAMES THE SOLID THE ANSWER LANDED IN, and `part` — added by the verb
## layer — names the binding that was probed. A probe in air has a part and no
## body, which is the whole point of the verb.
##
## PART SCOPING comes for free from panel_tools' _per_part: with `parts` it
## hands each leg the source that evaluates to that binding, already cached
## per document by part_cache.gd, and this module measures whatever source it
## is given.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: ui/panel_tools.gd (minerva_cad_material).

const _WorkerReply: Script = preload("worker_reply.gd")

## The IPC channel, which is also the MCP tool name and names the worker
## method — the same rule cad.clearance and cad.cylindrical_features follow.
const MATERIAL_CHANNEL: String = "cad.material"
## One await of a reply. The worker re-translates the DSL, which on a lofted
## shell is minutes of OCCT, so the round trip is renewed in chunks rather
## than abandoned at the first limit (CADPanel.call_backend_until).
const MATERIAL_CHUNK_MS: int = 60000
const MATERIAL_GIVE_UP_MS: int = 600000
## The one-shot fallback for a panel that has no renewing call.
const MATERIAL_TIMEOUT_MS: int = 120000


## Probe the material. `args`: at_mm=[x,y,z] OR from_mm=[x,y,z] with
## direction_mm=[dx,dy,dz], plus max_distance_mm, tolerance_mm, and the
## `source` a part-scoped leg states.
##
## The reply is the worker's, with `checked` in front of it:
##
##   point: {success, checked, units, shape_name, mode:"point", at_mm, inside,
##           state, body, body_index, body_count, nearest_surface_mm,
##           nearest_point_mm, bound}
##   ray:   {success, checked, units, shape_name, mode:"ray", from_mm,
##           direction_mm, count, segments: [{entry_mm, exit_mm, thickness_mm,
##           entry_point_mm, exit_point_mm, body, body_index}],
##           total_thickness_mm, started_inside, surface_crossings, unbounded,
##           bound}
##
## `checked: false` with a `reason` is not the same answer as "there is no
## material there", and a reader that cannot tell them apart trusts a probe
## that never ran.
static func probe(panel: Object, args: Dictionary) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return _refused("the CAD panel is gone")
	var request: Dictionary = _request(args)
	if request.has("error"):
		return _refused(str(request["error"]))

	# A part-scoped probe states the source that evaluates to ITS part; with
	# none the document's own source is the solid.
	var source := str(args.get("source", ""))
	if source.strip_edges().is_empty() and panel.has_method("get_document_state"):
		source = str((panel.get_document_state() as Dictionary).get("source", ""))
	if source.strip_edges().is_empty():
		return _refused("there is no DSL source to evaluate a solid from")
	request["source"] = source

	var envelope: Dictionary = {}
	if panel.has_method("call_backend_until"):
		envelope = await panel.call_backend_until(MATERIAL_CHANNEL, request,
			MATERIAL_CHUNK_MS, MATERIAL_GIVE_UP_MS)
	elif panel.has_method("call_backend"):
		envelope = await panel.call_backend(MATERIAL_CHANNEL, request,
			MATERIAL_TIMEOUT_MS)
	else:
		return _refused("this panel cannot reach the CAD worker")

	var result: Dictionary = _WorkerReply.unwrap(envelope, "material")
	if result.has("error"):
		return _refused(str(result["error"]))
	var reply: Dictionary = {"success": true, "checked": true}
	reply.merge(result)
	return reply


## The worker request, or {error} naming what the caller has to say instead.
## The two forms are checked HERE as well as in the worker so that a mistyped
## probe costs no round trip and no evaluation.
static func _request(args: Dictionary) -> Dictionary:
	var has_at: bool = args.has("at_mm")
	var has_from: bool = args.has("from_mm")
	if has_at and has_from:
		return {"error": "minerva_cad_material takes at_mm OR from_mm, not "
			+ "both: they are two different questions and one reply cannot be "
			+ "about both"}
	var request: Dictionary = {}
	if has_at:
		var at: Array = _triple(args.get("at_mm"))
		if at.is_empty():
			return {"error": "at_mm must be three numbers [x, y, z] in "
				+ "world millimetres"}
		request["at_mm"] = at
	elif has_from:
		var from: Array = _triple(args.get("from_mm"))
		if from.is_empty():
			return {"error": "from_mm must be three numbers [x, y, z] in "
				+ "world millimetres"}
		var direction: Array = _triple(args.get("direction_mm"))
		if direction.is_empty():
			return {"error": "the ray form needs direction_mm=[dx, dy, dz] "
				+ "beside from_mm, e.g. [0, 0, -1] for straight down"}
		if _length(direction) <= 0.0:
			return {"error": "direction_mm has no length; give the way the "
				+ "ray points, e.g. [0, 0, -1] for straight down"}
		request["from_mm"] = from
		request["direction_mm"] = direction
	else:
		return {"error": "minerva_cad_material needs either at_mm=[x, y, z] "
			+ "(is the solid here?) or from_mm + direction_mm (where does it "
			+ "start and stop along this ray?)"}
	if args.has("max_distance_mm"):
		var reach := float(args["max_distance_mm"])
		if reach <= 0.0:
			return {"error": "max_distance_mm must be greater than zero"}
		request["max_distance_mm"] = reach
	if args.has("tolerance_mm"):
		var tolerance := float(args["tolerance_mm"])
		if tolerance <= 0.0:
			return {"error": "tolerance_mm must be greater than zero"}
		request["tolerance_mm"] = tolerance
	return request


## Three numbers as floats, or [] for anything else. JSON hands every number
## over as a float, so an int in the source is not a different case.
static func _triple(raw: Variant) -> Array:
	if not (raw is Array) or (raw as Array).size() != 3:
		return []
	var out: Array = []
	for entry in (raw as Array):
		if not (entry is float or entry is int):
			return []
		out.append(float(entry))
	return out


static func _length(triple: Array) -> float:
	return Vector3(float(triple[0]), float(triple[1]),
		float(triple[2])).length()


## A probe that did not run. `checked` false and a reason, never a verdict
## about material nobody measured.
##
## `pass` false is what makes a refused leg COUNT in a parts= run: the fold in
## panel_tools._per_part reads success and pass, and a refusal that carried
## neither would be folded in as one more part that was fine.
static func _refused(reason: String) -> Dictionary:
	return {"success": true, "checked": false, "measured": false,
		"pass": false, "reason": reason}
