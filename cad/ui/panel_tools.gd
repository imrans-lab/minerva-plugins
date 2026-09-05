extends RefCounted
## CAD panel-executed MCP tool surface.
##
## Two families live here:
##
##   minerva_cad_view_state      what the user is currently looking at.
##   minerva_cad_references      which foreign meshes are in the scene, where
##                               they are posed and what their nodes bound.
##   minerva_cad_find_holes      propose holes by fitting, verify each one with
##                               a physical gauge, report the numbers.
##   minerva_cad_find_cylinders  the same for cylinders of either sense —
##                               concave (holes, bores) or convex (bosses).
##   minerva_cad_gauge           put a pin or a block somewhere and ask whether
##                               it fits, and if not, where it touched.
##   minerva_cad_probe           what is under this pixel of this pane.
##   minerva_cad_check_interference
##                               where the evaluated solid runs INTO a
##                               reference — the same report every evaluation
##                               already carries, on demand and scopeable.
##   minerva_cad_check_clearance
##                               how much air is between them, exactly.
##   minerva_cad_check_fasteners will these screws go in — coaxiality, a clear
##                               path, engagement and head seating, per screw.
##   minerva_cad_get_selected_reference
##                               which reference node the user last clicked,
##                               and where on it — the sibling of
##                               minerva_cad_get_selected_edge for foreign meshes.
##   minerva_cad_select_reference
##                               the same selection, made from here.
##   minerva_cad_view_overlay    draw a millimetre grid and the world axes in
##                               the panes, and report each pane's scale.
##
## WHY THESE ARE PANEL VERBS AND NOT CORE ONES. minerva_cad_get_mesh_info and
## minerva_cad_snapshot live in Minerva's own MCPCadTools; extending them is a
## host change and a host release. These verbs are declared executor:"panel" in
## the manifest instead, so the plugin ships them on its own. The division that
## falls out is a clean one: get_mesh_info describes the evaluated SOLID,
## minerva_cad_references describes the foreign REFERENCES, and the overlay
## verb puts a ruler into the scene so the host's existing snapshot verb
## captures it without knowing anything about measurement.
##
## EVERY NUMBER IS MILLIMETRES, IN BOTH FRAMES. A position is reported as
## {world, local}: world is the posed CAD scene, local is the reference file's
## own frame with the pose taken back off. An LLM editing the .mcad thinks in
## local (the hole is at (4, 4) on the board no matter where the board is
## posed); an LLM placing new geometry thinks in world.
##
## Off-tree note: no class_name — preloaded by relative path from CADPanel.gd.

const _MeshFeatures: Script = preload("scripts/mesh_features.gd")
const _ReferenceMeshes: Script = preload("scripts/reference_meshes.gd")
const _GeometryChecks: Script = preload("scripts/geometry_checks.gd")
const _FastenerChecks: Script = preload("scripts/fastener_checks.gd")
## The MCP rendering of an interference report: the panel keeps the full
## records digest for its joins, the wire carries a hash of it.
const _EvalReplyScript: Script = preload("scripts/eval_reply.gd")

## Default hole diameters to look for, in millimetres. Wide enough for a via
## and a mounting hole, narrow enough to leave the outline alone.
const DEFAULT_MIN_DIA_MM: float = 0.3
const DEFAULT_MAX_DIA_MM: float = 30.0
## A wall has to go this far round for the fitter to call it a hole rather than
## a fillet.
const DEFAULT_MIN_COVERAGE: float = 0.6
## Ray-grid fallback pitch, used only when the fitter proposes nothing at all.
const FALLBACK_PITCH_MM: float = 1.0
## When two fitted cylinders are the same physical hole seen in two nodes:
## axes parallel to within this dot product, centres concentric and radii equal
## to within the tolerances below. The floors matter for small drills, the
## fractions for large bores.
const COAXIAL_DOT: float = 0.999
const CENTRE_TOLERANCE_MM: float = 0.05
const CENTRE_TOLERANCE_FRACTION: float = 0.1
const RADIUS_TOLERANCE_MM: float = 0.02
const RADIUS_TOLERANCE_FRACTION: float = 0.05

## Candidate and report keys that are LENGTHS, and so scale with the pose.
const SCALED_LENGTH_KEYS: Array = [
	"radius_mm", "dia_mm", "inscribed_dia_mm", "gauge_dia_mm",
	"gauge_dia_at_least_mm",
	"half_extent_mm", "extent_mm", "depth_mm", "residual_mm",
]


static func handle(panel, tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_cad_view_state":
			return _view_state(panel, args)
		"minerva_cad_references":
			return _references(panel, args)
		"minerva_cad_find_holes":
			return await _fresh(panel, args, _find_holes)
		"minerva_cad_find_cylinders":
			return await _fresh(panel, args, _find_cylinders)
		"minerva_cad_gauge":
			return await _fresh(panel, args, _gauge)
		"minerva_cad_probe":
			return await _fresh(panel, args, _probe)
		"minerva_cad_check_interference":
			return await _fresh(panel, args, _check_interference)
		"minerva_cad_check_clearance":
			return await _fresh(panel, args, _check_clearance)
		"minerva_cad_check_fasteners":
			return await _fresh(panel, args, _check_fasteners)
		"minerva_cad_get_selected_reference":
			return await _fresh(panel, args, _selected_reference)
		"minerva_cad_select_reference":
			return await _fresh(panel, args, _select_reference)
		"minerva_cad_view_overlay":
			return _view_overlay(panel, args)
	return {}


## Every awaiting verb snapshots the panel's poses, records and colliders
## before it waits — on the segmentation worker, on a physics step — and the
## document can change under it while it waits. The reference digest is the
## panel's own word for "the reference set changed": it is read before and
## after the verb, and a change means the reply describes a pose the
## document no longer has. The verb is then run once more; a document that
## is still changing gets its reply back marked `stale`, with the reason,
## rather than being chased. A panel freed during the wait is an error.
static func _fresh(panel, args: Dictionary, verb: Callable) -> Dictionary:
	var reply: Dictionary = {}
	for attempt in range(2):
		var before := _reference_digest(panel)
		reply = await verb.call(panel, args)
		if not is_instance_valid(panel):
			return _err("the CAD panel closed while the measurement was running")
		if _reference_digest(panel) == before:
			return reply
	reply["stale"] = true
	reply["stale_reason"] = "the reference set changed while this measurement " \
		+ "was running, twice; the numbers describe a pose the document no " \
		+ "longer has — call again once the document is settled"
	return reply


## The panel's digest of its mounted references, or "" for a panel that has
## none to report (a freed one included).
static func _reference_digest(panel) -> String:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("get_reference_digest"):
		return ""
	return str(panel.get_reference_digest())


## minerva_cad_view_state — delegates to CADPanel.get_view_state().
static func _view_state(panel, _args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("get_view_state"):
		return _err("CAD view state not available on this panel")
	return _ok(panel.get_view_state())


# ---------------------------------------------------------------------------
# References and node bounds
# ---------------------------------------------------------------------------

## Every reference the document named, whether or not its file could be read.
## A failed one is reported with a status and a reason rather than left out:
## the list has to match the mesh() calls in the source, or the answer to
## "where is my board" is a shorter list with nothing to explain it.
static func _references(panel, _args: Dictionary) -> Dictionary:
	var records := _status_records(panel)
	var out: Array = []
	var failed := 0
	for entry in records:
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var nodes: Array = []
		for node_entry in record.get("node_bounds", []):
			var node: Dictionary = node_entry
			var box: AABB = node.get("aabb", AABB())
			nodes.append({
				"name": str(node.get("name", "")),
				"path": str(node.get("path", node.get("name", ""))),
				"bbox_mm": _boxes(box, pose),
			})
		var status := str(record.get("status", _ReferenceMeshes.STATUS_OK))
		if status != _ReferenceMeshes.STATUS_OK:
			failed += 1
		out.append({
			"name": str(record.get("name", "")),
			"path": str(record.get("path", "")),
			"resolved_path": str(record.get("resolved_path", "")),
			"status": status,
			"reason": str(record.get("reason", "")),
			"warning": str(record.get("warning", "")),
			"triangle_count": int(record.get("triangle_count", 0)),
			"bytes": int(record.get("bytes", 0)),
			"load_ms": int(record.get("load_ms", 0)),
			"outlines_skipped": bool(record.get("outlines_skipped", false)),
			"pose": _matrix(pose),
			"bbox_mm": _boxes(record.get("local_aabb", AABB()), pose),
			"nodes": nodes,
		})
	return _ok({
		"units": "mm",
		"references": out,
		"count": out.size(),
		"failed": failed,
		"note": "The evaluated solid is described by minerva_cad_get_mesh_info; "
			+ "this verb describes the foreign meshes named by mesh(). A "
			+ "reference whose status is not 'ok' is drawn as a wireframe "
			+ "marker at its pose and has loaded no geometry; `reason` says "
			+ "why and names the file. A node's `path` from the file root is "
			+ "its identity — `name` is only the leaf and two branches may "
			+ "share one — and node= filters accept either.",
	})


# ---------------------------------------------------------------------------
# Propose -> verify
# ---------------------------------------------------------------------------

static func _find_holes(panel, args: Dictionary) -> Dictionary:
	var scope := _scope(panel, args)
	if scope.has("error"):
		return _err(str(scope["error"]))
	var min_dia := float(args.get("min_dia_mm", DEFAULT_MIN_DIA_MM))
	var max_dia := float(args.get("max_dia_mm", DEFAULT_MAX_DIA_MM))
	var gauge: Node = panel.get_mesh_gauge()
	var features: RefCounted = panel.get_mesh_features()
	if not _gauge_ready(gauge) or features == null:
		return _err("the measurement modules are not available on this panel")
	panel.ensure_gauge_built()

	var holes: Array = []
	var proposed := 0
	var fell_back := false
	# Segmentation time for the files that were segmented on THIS call. Zero
	# means every reference was already analysed: the cost is per file, not per
	# question, and this is the number that says so.
	var segment_ms := 0
	# A node= filter that misses THIS reference is only an error when it misses
	# every reference in scope; the misses are collected and judged after.
	var node_missing: Array = []
	var node_matched := false
	for entry in scope["records"]:
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var before := int(features.call("get_analysis_count"))
		var analysis := await _analysis(panel, record, args)
		if not is_instance_valid(panel) or not _gauge_ready(gauge):
			return _err("the CAD panel closed while its reference mesh was being segmented")
		if analysis.has("error"):
			if bool(analysis.get("node_missing", false)):
				node_missing.append(str(analysis["error"]))
				continue
			return _err(str(analysis["error"]))
		node_matched = true
		if int(features.call("get_analysis_count")) > before:
			segment_ms += int(analysis.get("elapsed_ms", 0))
		# The thresholds are world millimetres, like every reported length, and
		# the candidates are still in the file's own frame: a scaled pose makes
		# those two different numbers, so the limits come back to the local
		# frame before they filter local candidates.
		var scale := pose_scale(pose)
		var candidates: Array = _MeshFeatures.concave_cylinders(
			analysis.get("candidates", []),
			min_dia / scale,
			max_dia / scale,
			float(args.get("min_coverage", DEFAULT_MIN_COVERAGE))
		)
		proposed += candidates.size()

		var posed: Array = []
		for candidate in candidates:
			posed.append(_pose_candidate(candidate as Dictionary, pose))
		if posed.is_empty() and bool(args.get("fallback", true)):
			# True soup: no region fitted a cylinder. Seed with a ray grid and
			# measure the seeds the same way — the numbers still come from the
			# gauge, only the proposal changed.
			fell_back = true
			posed = await _seed_candidates(gauge, record, args)
		posed = _merge_coaxial(posed)
		if posed.is_empty():
			continue

		var measured: Dictionary = await gauge.call("submit", "measure_holes", {
			"candidates": posed,
			"mask": _scope_mask(gauge, args, record),
			"reference": str(record.get("name", "")),
		})
		if measured.has("error"):
			return _err(str(measured["error"]))
		for hole in measured.get("holes", []):
			var report := _report_cylinder(hole as Dictionary, record, pose)
			if bool(args.get("verified_only", false)) and not bool(report["verified"]):
				continue
			holes.append(report)

	if not node_matched and not node_missing.is_empty():
		return _err("; ".join(node_missing))
	return _ok({
		"units": "mm",
		"holes": holes,
		"count": holes.size(),
		"proposed": proposed,
		"seeded_by_ray_grid": fell_back,
		"segment_ms": segment_ms,
		"collider_count": int(gauge.call("get_shape_count")),
	})


static func _find_cylinders(panel, args: Dictionary) -> Dictionary:
	var scope := _scope(panel, args)
	if scope.has("error"):
		return _err(str(scope["error"]))
	var kind := str(args.get("kind", "any"))
	var min_dia := float(args.get("min_dia_mm", 0.0))
	var max_dia := float(args.get("max_dia_mm", 1.0e6))
	var min_coverage := float(args.get("min_coverage", 0.0))
	var gauge: Node = panel.get_mesh_gauge()
	if not _gauge_ready(gauge):
		return _err("measurement gauge is not available on this panel")
	panel.ensure_gauge_built()

	var found: Array = []
	var node_missing: Array = []
	var node_matched := false
	for entry in scope["records"]:
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var analysis := await _analysis(panel, record, args)
		if not is_instance_valid(panel) or not _gauge_ready(gauge):
			return _err("the CAD panel closed while its reference mesh was being segmented")
		if analysis.has("error"):
			if bool(analysis.get("node_missing", false)):
				node_missing.append(str(analysis["error"]))
				continue
			return _err(str(analysis["error"]))
		node_matched = true
		# World thresholds against local candidates: see _find_holes.
		var scale := pose_scale(pose)
		var local_min := min_dia / scale
		var local_max := max_dia / scale
		var concave: Array = []
		var convex: Array = []
		for candidate_entry in analysis.get("candidates", []):
			var candidate: Dictionary = candidate_entry
			if str(candidate.get("kind", "")) != "cylinder":
				continue
			var dia := float(candidate.get("dia_mm", 0.0))
			if dia < local_min or dia > local_max:
				continue
			if float(candidate.get("coverage", 0.0)) < min_coverage:
				continue
			var form := str(candidate.get("form", ""))
			if kind != "any" and form != kind:
				continue
			if form == "concave":
				concave.append(_pose_candidate(candidate, pose))
			else:
				convex.append(_pose_candidate(candidate, pose))

		# A gauge that could not run reports an error, not an empty list; a
		# swallowed error would answer "no cylinders" for a part full of them.
		if not concave.is_empty():
			var mask := _scope_mask(gauge, args, record)
			var holes: Dictionary = await gauge.call(
				"submit", "measure_holes", {"candidates": concave, "mask": mask,
				"reference": str(record.get("name", ""))})
			if holes.has("error"):
				return _err(str(holes["error"]))
			for hole in holes.get("holes", []):
				found.append(_report_cylinder(hole as Dictionary, record, pose))
		if not convex.is_empty():
			var convex_mask := _scope_mask(gauge, args, record)
			var bosses: Dictionary = await gauge.call(
				"submit", "measure_convex", {"candidates": convex, "mask": convex_mask,
				"reference": str(record.get("name", ""))})
			if bosses.has("error"):
				return _err(str(bosses["error"]))
			for boss in bosses.get("cylinders", []):
				found.append(_report_cylinder(boss as Dictionary, record, pose))

	if not node_matched and not node_missing.is_empty():
		return _err("; ".join(node_missing))
	return _ok({
		"units": "mm",
		"cylinders": found,
		"count": found.size(),
	})


# ---------------------------------------------------------------------------
# Direct physical questions
# ---------------------------------------------------------------------------

static func _gauge(panel, args: Dictionary) -> Dictionary:
	var gauge: Node = panel.get_mesh_gauge()
	if not _gauge_ready(gauge):
		return _err("measurement gauge is not available on this panel")
	if panel.ensure_gauge_built() <= 0:
		return _err("no reference mesh is mounted; nothing to gauge against")

	var shape := str(args.get("shape", "cylinder"))
	var size := Vector3.ONE
	match shape:
		"cylinder":
			size = Vector3(
				float(args.get("dia_mm", 1.0)), float(args.get("length_mm", 5.0)), 0.0)
		"sphere":
			size = Vector3(float(args.get("dia_mm", 1.0)), 0.0, 0.0)
		"box":
			size = _vector(args.get("size_mm", [1.0, 1.0, 1.0]))
		_:
			return _err("unsupported gauge shape '%s' (cylinder, box, sphere)" % shape)

	var asked := str(args.get("reference", ""))
	if not asked.is_empty() and not _has_reference(panel, asked):
		return _err("no reference named '%s' is mounted" % asked)
	var result: Dictionary = await gauge.call("submit", "gauge", {
		"shape": shape,
		"size": size,
		"at": _vector(args.get("at_mm", [0.0, 0.0, 0.0])),
		"axis": _vector(args.get("axis", [0.0, 0.0, 1.0])),
		# The clearance search stops here. Without a ceiling from the caller
		# it runs to the reference's own extent, which is the only bound that
		# is a fact about the part rather than about the pin.
		"max_radius_mm": float(args.get("max_dia_mm", 0.0)) * 0.5,
		"mask": _scope_mask(gauge, args, {"name": asked}),
		"reference": asked,
	})
	if result.has("error"):
		return _err(str(result["error"]))

	# A contact is un-posed by the pose of the reference it actually lies on.
	# The gauge names that reference beside the node it touched — `node` is the
	# bare node path, the same identity find_holes and the selection verbs use
	# — and the caller's own `reference` stands in when the contact could not be
	# attributed. There is no sensible default beyond those two: taking the
	# first mounted reference would silently report a local position in another
	# part's frame, so an unattributed contact is reported in world only.
	var contacts: Array = []
	for contact_entry in result.get("contacts", []):
		var contact: Dictionary = contact_entry
		var node_name := str(contact.get("node", ""))
		var reference_name := str(contact.get("reference", ""))
		if reference_name.is_empty():
			reference_name = asked
		var entry := {
			"point_mm": _frames(panel, contact.get("point_mm", Vector3.ZERO), reference_name),
			"node": node_name,
			"reference": reference_name,
		}
		contacts.append(entry)
	var payload := {
		"units": "mm",
		"fits": bool(result.get("fits", false)),
		"contacts": contacts,
		"clearance_bound_mm": float(result.get("clearance_bound_mm", 0.0)),
	}
	# Clearance is only a measurement when a wall stopped it. In open space the
	# gauge reports the search bound instead, under a key that says so, so the
	# two can never be confused by a reader of the payload.
	if result.has("clearance_at_least_mm"):
		payload["clearance_at_least_mm"] = float(result["clearance_at_least_mm"])
	else:
		payload["clearance_mm"] = float(result.get("clearance_mm", 0.0))
	if result.has("reason"):
		payload["reason"] = str(result["reason"])
	if str(result.get("reason", "")) == "inside_solid":
		payload["note"] = "A gauge buried in solid material crosses no "\
			+ "triangle and so touches nothing; it does not fit, and has no contacts."
	return _ok(payload)


## minerva_cad_check_interference — where the solid and the references overlap.
##
## The panel runs this check on every evaluation anyway; the verb exists so an
## agent can ask about ONE reference or ONE node, and so it can ask again after
## an edit without having to find the last eval result.
static func _check_interference(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("check_interference"):
		return _err("interference checking is not available on this panel")
	var asked := str(args.get("reference", ""))
	if not asked.is_empty() and not _has_reference(panel, asked):
		return _err("no reference named '%s' is mounted" % asked)
	var report: Dictionary = await panel.check_interference({
		"reference": asked,
		"node": str(args.get("node", "")),
		# An agent asking now: refused with `busy` while an evaluation's own
		# check holds the geometry, rather than queued behind it. The caller
		# can ask again; a wait it cannot see would just look like a hang.
		"on_demand": true,
	})
	if report.has("error"):
		return _err(str(report["error"]))
	return _ok(_EvalReplyScript.interference_for_mcp(report))


## minerva_cad_check_clearance — how much air is there, and where is it
## tightest? The distance is computed in the worker over a swept-sphere BVH,
## so the number is exact for the two meshes; the reply states the tolerance
## the solid was tessellated at, which is the error bar against the true
## B-Rep surface.
static func _check_clearance(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("check_clearance"):
		return _err("clearance checking is not available on this panel")
	var asked := str(args.get("reference", ""))
	if not asked.is_empty() and not _has_reference(panel, asked):
		return _err("no reference named '%s' is mounted" % asked)
	var report: Dictionary = await panel.check_clearance({
		"required_mm": float(args.get("required_mm", 0.0)),
		"tolerance_mm": float(args.get("tolerance_mm",
			_GeometryChecks.CLEARANCE_TOLERANCE_MM)),
		"reference": asked,
		"node": str(args.get("node", "")),
		"accept_unbounded_tolerance":
			bool(args.get("accept_unbounded_tolerance", false)),
	})
	if report.has("error"):
		return _err(str(report["error"]))
	return _ok(report)


## minerva_cad_check_fasteners — will these screws actually go in?
##
## The holes come from _find_holes rather than from a second implementation:
## the fastener module never segments a reference, and a hole this verb pairs
## against is the same measured hole minerva_cad_find_holes would report, with
## the same gauge behind it. The diameter window defaults to a band around the
## screw so a board full of vias does not become a hundred pairing candidates.
static func _check_fasteners(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("check_fasteners"):
		return _err("fastener checking is not available on this panel")
	var asked := str(args.get("reference", ""))
	if not asked.is_empty() and not _has_reference(panel, asked):
		return _err("no reference named '%s' is mounted" % asked)
	var screw: Dictionary = args.get("screw", {}) as Dictionary
	var dia := float(screw.get("dia_mm", 0.0))
	if dia <= 0.0:
		return _err("check_fasteners needs screw: {dia_mm, length_mm} in millimetres")

	var hole_args := args.duplicate(true)
	hole_args["min_dia_mm"] = float(args.get("min_dia_mm", dia * 0.8))
	hole_args["max_dia_mm"] = float(args.get("max_dia_mm", dia * 2.5))
	var holes: Dictionary = await _find_holes(panel, hole_args)
	if holes.has("error"):
		return holes

	var report: Dictionary = await panel.check_fasteners({
		"screw": screw,
		"holes": holes.get("holes", []),
		"pairs": args.get("pairs", []),
		"engagement_min_d": float(args.get("engagement_min_d",
			_FastenerChecks.DEFAULT_ENGAGEMENT_D)),
		"clearance_hole_dia_mm": args.get("clearance_hole_dia_mm", 0.0),
		"compare_fit": bool(args.get("compare_fit", false)),
		"reference": asked,
		"node": str(args.get("node", "")),
	})
	if report.has("error"):
		return _err(str(report["error"]))
	report["holes_considered"] = int(holes.get("count", 0))
	return _ok(report)


static func _probe(panel, args: Dictionary) -> Dictionary:
	var gauge: Node = panel.get_mesh_gauge()
	if not _gauge_ready(gauge):
		return _err("measurement gauge is not available on this panel")
	if panel.ensure_gauge_built() <= 0:
		return _err("no reference mesh is mounted; nothing to probe")
	var pixels: Array = args.get("px", [])
	if pixels.size() < 2:
		return _err("probe needs px: [x, y] in the pane's own pixels")
	var view := str(args.get("view", "active"))
	var ray: Dictionary = panel.get_pick_ray(view, Vector2(float(pixels[0]), float(pixels[1])))
	if ray.has("error"):
		return _err(str(ray["error"]))

	var hit: Dictionary = await gauge.call("submit", "raycast", {
		"from": ray["from"],
		"to": ray["to"],
	})
	if hit.has("error"):
		return _err(str(hit["error"]))
	if not bool(hit.get("hit", false)):
		return _ok({
			"units": "mm",
			"hit": false,
			"view": view,
			"width_px": ray.get("width_px", 0),
			"height_px": ray.get("height_px", 0),
		})

	var node_name := str(hit.get("node", ""))
	var reference_name := str(hit.get("reference", ""))
	return _ok({
		"units": "mm",
		"hit": true,
		"view": view,
		"position_mm": _frames(panel, hit.get("position", Vector3.ZERO), reference_name),
		"normal": _vec(hit.get("normal", Vector3.UP)),
		"reference": reference_name,
		"node": node_name,
		"width_px": ray.get("width_px", 0),
		"height_px": ray.get("height_px", 0),
	})


# ---------------------------------------------------------------------------
# The user's click as the LLM's seed
# ---------------------------------------------------------------------------

## minerva_cad_get_selected_reference — the last reference node the user
## pointed at, in both frames, with the node's bounds and the hole the click
## landed in if it landed in one. This is the handoff: the human knows which
## bracket they mean and cannot say it in numbers; the click says it exactly.
static func _selected_reference(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("get_reference_selection"):
		return _err("reference selection is not available on this panel")
	var selection: Dictionary = panel.get_reference_selection()
	if selection.is_empty():
		return _ok({
			"units": "mm",
			"selected": false,
			"references": _reference_names(panel),
			"note": "Nothing is selected. Ask the user to click a reference in "
				+ "a view, or select one yourself with minerva_cad_select_reference.",
		})
	return _ok(await _selection_payload(panel, selection, args))


## minerva_cad_select_reference — the same selection, made from the agent side,
## so an LLM can point at a node it found by name and have the user see the
## same highlight the user's own click would have made.
static func _select_reference(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("select_reference_node"):
		return _err("reference selection is not available on this panel")
	var reference := str(args.get("reference", ""))
	if reference.is_empty():
		return _err("select_reference needs a reference name; "
			+ "minerva_cad_references lists them")
	var point: Variant = args.get("point_mm", null)
	var selection: Dictionary = panel.select_reference_node(
		reference, str(args.get("node", "")), point)
	if selection.is_empty():
		return _err("no mounted reference named '%s' has a node '%s'"
			% [reference, str(args.get("node", ""))])
	return _ok(await _selection_payload(panel, selection, args))


## One selection, reported the way every other measurement is: both frames,
## millimetres, and nothing computed twice.
static func _selection_payload(panel, selection: Dictionary, args: Dictionary) -> Dictionary:
	var local_box: AABB = selection.get("local_aabb", AABB())
	var world_box: AABB = selection.get("world_aabb", AABB())
	var pixel: Vector2 = selection.get("pixel", Vector2.ZERO)
	var nearest_hole: Variant = await _nearest_hole(panel, selection, args)
	return {
		"units": "mm",
		"selected": true,
		"reference": str(selection.get("reference", "")),
		"node": str(selection.get("node", "")),
		"stale": bool(selection.get("stale", false)),
		"point_mm": {
			"world": _vec(selection.get("world", Vector3.ZERO)),
			"local": _vec(selection.get("local", Vector3.ZERO)),
		},
		"point_source": str(selection.get("point_source", "")),
		"node_path": str(selection.get("node", "")),
		"normal": {
			"world": _vec(selection.get("normal_world", Vector3.ZERO)),
			"local": _vec(selection.get("normal", Vector3.ZERO)),
		},
		"bounds_mm": {
			"local": {"min": _vec(local_box.position), "max": _vec(local_box.end)},
			"world": {"min": _vec(world_box.position), "max": _vec(world_box.end)},
		},
		"size_mm": _vec(world_box.size),
		"selected_by": str(selection.get("source", "")),
		"view": str(selection.get("view", "")),
		"px": [pixel.x, pixel.y],
		"nearest_hole": nearest_hole,
		"note": "point_mm.local is the reference file's own frame — the frame "
			+ "the mesh() pose is applied to — and point_mm.world is the posed "
			+ "scene; the normal is given in both. `node` is the node's path from "
			+ "the file root. A stale selection means the document no longer "
			+ "mounts that reference.",
	}


## The fitted hole the selected point lies inside, or null. Fitting only: this
## is the cheap answer to "what did I click in", and it says so. The measured
## answer is minerva_cad_find_holes, which gauges the same candidate.
static func _nearest_hole(panel, selection: Dictionary, args: Dictionary) -> Variant:
	if not bool(args.get("include_hole", true)):
		return null
	var node_name := str(selection.get("node", ""))
	var record: Dictionary = {}
	for entry in _records(panel):
		if str((entry as Dictionary).get("name", "")) == str(selection.get("reference", "")):
			record = entry
			break
	if record.is_empty():
		return null
	var analysis := await _analysis(panel, record, {"node": node_name})
	if analysis.has("error"):
		return null
	var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
	var factor := pose_scale(pose)
	# World thresholds, local candidates: the limits come back to the file's
	# own frame before they filter, so max_dia_mm means the same millimetre
	# here as it does in the reported diameter.
	var candidates: Array = _MeshFeatures.concave_cylinders(
		analysis.get("candidates", []),
		float(args.get("min_dia_mm", DEFAULT_MIN_DIA_MM)) / factor,
		float(args.get("max_dia_mm", DEFAULT_MAX_DIA_MM)) / factor,
		float(args.get("min_coverage", DEFAULT_MIN_COVERAGE))
	)
	var point: Vector3 = selection.get("local", Vector3.ZERO)
	var best: Dictionary = {}
	var best_radial := INF
	for candidate_entry in candidates:
		var candidate: Dictionary = candidate_entry
		var centre: Vector3 = candidate.get("center", Vector3.ZERO)
		var axis: Vector3 = (candidate.get("axis", Vector3.UP) as Vector3).normalized()
		var offset := point - centre
		var along := offset.dot(axis)
		var radial := (offset - axis * along).length()
		var radius := float(candidate.get("radius_mm", 0.0))
		# Inside the wall, and between the two ends of it: a click on the far
		# side of the part is not a click in this hole.
		if radial > radius or absf(along) > float(candidate.get("half_extent_mm", 0.0)):
			continue
		if radial >= best_radial:
			continue
		best_radial = radial
		best = candidate
	if best.is_empty():
		return null
	# Reported like every other row: lengths in world millimetres, with the
	# file's own frame beside them and the factor between the two.
	var posed := _pose_candidate(best, pose)
	var local_lengths := {}
	for key in SCALED_LENGTH_KEYS:
		if best.get(key, null) != null:
			local_lengths[key] = float(best[key])
	return {
		"node": str(best.get("node", node_name)),
		"center_mm": _points(pose * (best.get("center", Vector3.ZERO) as Vector3), pose),
		"axis": _axes(pose.basis * (best.get("axis", Vector3.UP) as Vector3), pose),
		"dia_mm": float(posed.get("dia_mm", 0.0)),
		"inscribed_dia_mm": float(posed.get("inscribed_dia_mm", 0.0)),
		"facets": int(best.get("facets", 0)),
		"coverage": float(best.get("coverage", 0.0)),
		"residual_mm": posed.get("residual_mm", null),
		"radial_distance_mm": best_radial * factor,
		"scale": factor,
		"local": local_lengths,
		"source": "fit",
		"note": "Proposed by fitting, NOT gauged: dia_mm is the circumscribed "
			+ "circle of the tessellation. Call minerva_cad_find_holes for the "
			+ "measured diameter and the through test.",
	}


## Names of the references that are mounted, for an empty selection's message.
static func _reference_names(panel) -> Array:
	var names: Array = []
	for entry in _records(panel):
		names.append(str((entry as Dictionary).get("name", "")))
	return names


static func _view_overlay(panel, args: Dictionary) -> Dictionary:
	var mode := str(args.get("overlay", "grid"))
	if mode not in ["none", "grid", "axes", "grid+axes"]:
		return _err("overlay must be none, grid, axes or grid+axes")
	var drawn: Dictionary = panel.set_measurement_overlay(
		mode, float(args.get("grid_mm", 10.0)))
	# In narrow layout the four named panes do not exist; reporting the single
	# pane four times under four names would be four lies. Ask the panel and
	# say which pane there actually is.
	var views: Array = []
	var refusal := ""
	if panel.has_method("view_unavailable_reason"):
		refusal = str(panel.view_unavailable_reason("top"))
	if refusal.is_empty():
		for view in ["top", "front", "right", "iso"]:
			var metrics: Dictionary = panel.get_view_metrics(view)
			if not metrics.has("error"):
				views.append(metrics)
	else:
		var single: Dictionary = panel.get_view_metrics("active")
		if not single.has("error"):
			views.append(single)
	var payload := {
		"units": "mm",
		"overlay": str(drawn.get("mode", mode)),
		"grid_mm": float(drawn.get("grid_mm", 0.0)),
		"lines": int(drawn.get("lines", 0)),
		"views": views,
		"note": "Take the picture with minerva_cad_snapshot; the overlay is "
			+ "scene geometry and is captured with everything else.",
	}
	if not refusal.is_empty():
		payload["views_unavailable"] = refusal
	return _ok(payload)


# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------

static func _records(panel) -> Array:
	if panel == null or not panel.has_method("get_reference_state"):
		return []
	return panel.get_reference_state()


## Every reference the document named, loaded or not. Only the reporting verb
## wants these; a measurement runs on _records(), which holds geometry.
static func _status_records(panel) -> Array:
	if panel == null or not panel.has_method("get_reference_status"):
		return _records(panel)
	return panel.get_reference_status()


## Records in scope, filtered by the optional `reference` name. A named
## reference that is not mounted is an error rather than an empty result: the
## caller misspelled something and should be told so.
static func _scope(panel, args: Dictionary) -> Dictionary:
	var records := _records(panel)
	if records.is_empty():
		return {"error": "no reference mesh is mounted in this editor"}
	var wanted := str(args.get("reference", ""))
	if wanted.is_empty():
		return {"records": records}
	var kept: Array = []
	for entry in records:
		if str((entry as Dictionary).get("name", "")) == wanted:
			kept.append(entry)
	if kept.is_empty():
		return {"error": "no reference named '%s' is mounted" % wanted}
	return {"records": kept}


## Segment and fit one reference, once. The cache key carries the file's
## content stamp and the node filter, so a pose edit never re-segments and a
## file edit always does.
##
## A node= filter that matches nothing in ANY reference in scope is an ERROR
## naming the filter and the nodes there are. A successful measurement of zero
## holes is indistinguishable from a typo, and the typo is by far the likelier
## of the two. Here the miss is only reported — `node_missing` marks it, and
## the caller decides, because with several references in scope a node present
## in one of them is a match and not a typo.
static func _analysis(panel, record: Dictionary, args: Dictionary) -> Dictionary:
	var features: RefCounted = panel.get_mesh_features()
	if features == null:
		return {"candidates": []}
	var node_filter := str(args.get("node", ""))
	var parts: Array = record.get("parts", [])
	if not node_filter.is_empty():
		var kept: Array = []
		var available: Array = []
		for entry in parts:
			var part: Dictionary = entry
			var path := str(part.get("node_path", part.get("node", "")))
			if not (path in available):
				available.append(path)
			# A leaf name matches every node that carries it; a full path
			# matches the one node it names.
			if path == node_filter or str(part.get("node", "")) == node_filter:
				kept.append(entry)
		if kept.is_empty():
			return {
				"candidates": [],
				"node_missing": true,
				"error": "no node '%s' in reference '%s'; it has %s"
					% [node_filter, str(record.get("name", "")), str(available)],
			}
		parts = kept
	# The segmentation runs on the CONVERTED parts, so units and up belong in
	# the key: without them a units= edit reuses candidates in the old frame.
	var key := "%s|%s|%s|%s|%s" % [
		str(record.get("resolved_path", "")),
		str(record.get("stamp", "")),
		str(record.get("units", "")),
		str(record.get("up", "")),
		node_filter,
	]
	return await features.call(
		"features_for_async",
		key,
		parts,
		float(args.get("region_angle_deg", _MeshFeatures.DEFAULT_REGION_ANGLE_DEG)),
		panel.get_tree()
	)


## The uniform factor a pose scales lengths by. The DSL refuses a non-uniform
## scale on a reference — an ellipse has no diameter to report — so the cube
## root of the basis determinant is the whole of it, and its magnitude survives
## a mirror.
static func pose_scale(pose: Transform3D) -> float:
	var determinant := absf(pose.basis.determinant())
	return pow(determinant, 1.0 / 3.0) if determinant > 0.0 else 1.0


## A candidate in the reference's local frame, moved into the posed world where
## the gauge works. Lengths scale with the pose as well as positions: a
## reference posed at scale 2 has a hole of twice the diameter in the world,
## and a gauge searching for the fitted radius has to be told the world one.
static func _pose_candidate(candidate: Dictionary, pose: Transform3D) -> Dictionary:
	var posed := candidate.duplicate(true)
	posed["center"] = pose * (candidate.get("center", Vector3.ZERO) as Vector3)
	posed["axis"] = (pose.basis * (candidate.get("axis", Vector3.UP) as Vector3)).normalized()
	var factor := pose_scale(pose)
	if not is_equal_approx(factor, 1.0):
		for key in SCALED_LENGTH_KEYS:
			if candidate.get(key, null) != null:
				posed[key] = float(candidate[key]) * factor
	return posed


## Ray-grid seeds as hole candidates. The seed only proposes a place to look;
## the centre, the diameter and the through test all still come from the gauge.
static func _seed_candidates(gauge: Node, record: Dictionary, args: Dictionary) -> Array:
	var bounds: AABB = record.get("world_aabb", AABB())
	var axis := _vector(args.get("axis", [0.0, 0.0, 1.0]))
	var seeded: Dictionary = await gauge.call("submit", "seed_grid", {
		"bounds": bounds,
		"axis": axis,
		"pitch_mm": float(args.get("pitch_mm", FALLBACK_PITCH_MM)),
		"mask": _scope_mask(gauge, args, record),
		"reference": str(record.get("name", "")),
	})
	var out: Array = []
	var half_extent := _extent_along(bounds, axis) * 0.5
	for entry in seeded.get("seeds", []):
		var seed: Dictionary = entry
		var hint := float(seed.get("radius_hint_mm", 0.5))
		out.append({
			"kind": "cylinder",
			"form": "concave",
			"node": "",
			"center": seed.get("center", Vector3.ZERO),
			"axis": axis,
			"radius_mm": hint,
			"dia_mm": hint * 2.0,
			"inscribed_dia_mm": hint * 2.0,
			"half_extent_mm": half_extent,
			"extent_mm": half_extent * 2.0,
			"residual_mm": null,
			"facets": 0,
			"coverage": 0.0,
			"source": "ray-grid",
		})
	return out


## A hole through a stack of nodes is fitted once per node whose wall it
## crosses — a board GLB has substrate, copper and mask, and a 3.2 mm drill
## comes back three times. Two candidates are the same hole when they are
## coaxial, concentric and the same size; merging them before the gauge runs
## also saves the duplicate measurements. The merged row keeps every node the
## hole passes through, because "which layers does this drill cross" is a real
## question and the node names are the only answer to it.
static func _merge_coaxial(candidates: Array) -> Array:
	# One pass merges each candidate into the first entry it matches, so with an
	# unlucky node order a drill can end as two entries that would merge with
	# each other. Repeat until a pass changes nothing.
	var merged: Array = _merge_coaxial_pass(candidates)
	while merged.size() < candidates.size():
		candidates = merged
		merged = _merge_coaxial_pass(candidates)
	return merged


static func _merge_coaxial_pass(candidates: Array) -> Array:
	var merged: Array = []
	for entry in candidates:
		var candidate: Dictionary = entry
		var axis: Vector3 = (candidate.get("axis", Vector3.UP) as Vector3).normalized()
		var centre: Vector3 = candidate.get("center", Vector3.ZERO)
		var radius := float(candidate.get("radius_mm", 0.0))
		var half := float(candidate.get("half_extent_mm", 0.0))
		var target: Dictionary = {}
		for existing_entry in merged:
			var existing: Dictionary = existing_entry
			var other_axis: Vector3 = (existing.get("axis", Vector3.UP) as Vector3).normalized()
			if absf(other_axis.dot(axis)) < COAXIAL_DOT:
				continue
			if absf(float(existing.get("radius_mm", 0.0)) - radius) \
					> maxf(RADIUS_TOLERANCE_MM, radius * RADIUS_TOLERANCE_FRACTION):
				continue
			var offset: Vector3 = centre - (existing.get("center", Vector3.ZERO) as Vector3)
			var perpendicular := (offset - other_axis * offset.dot(other_axis)).length()
			if perpendicular > maxf(CENTRE_TOLERANCE_MM, radius * CENTRE_TOLERANCE_FRACTION):
				continue
			# Coaxial and same radius is not enough: two holes in plates that
			# do not touch are two holes. Their axial runs must overlap or meet.
			var axial_gap := absf(offset.dot(other_axis)) \
				- float(existing.get("half_extent_mm", 0.0)) - half
			if axial_gap > maxf(CENTRE_TOLERANCE_MM, radius * CENTRE_TOLERANCE_FRACTION):
				continue
			target = existing
			break
		if target.is_empty():
			var fresh := candidate.duplicate(true)
			fresh["axis"] = axis
			fresh["nodes"] = _nodes_of(candidate)
			merged.append(fresh)
			continue
		var nodes: Array = target["nodes"]
		for node_name in _nodes_of(candidate):
			if not nodes.has(node_name):
				nodes.append(node_name)
		# The merged hole spans the union of the axial runs: a drill through
		# three plates is as deep as all three, not as deep as the thickest.
		var target_axis: Vector3 = target["axis"]
		var target_centre: Vector3 = target.get("center", Vector3.ZERO)
		var base := target_centre.dot(target_axis)
		var target_half := float(target.get("half_extent_mm", 0.0))
		var here := centre.dot(target_axis)
		var low := minf(base - target_half, here - half)
		var high := maxf(base + target_half, here + half)
		var new_half := (high - low) * 0.5
		target["center"] = target_centre + target_axis * ((low + high) * 0.5 - base)
		target["half_extent_mm"] = new_half
		target["extent_mm"] = new_half * 2.0
	return merged


## One measured cylinder, in both frames, with the numbers that make it
## falsifiable: the fitted (circumscribed) diameter the tessellation implies,
## the gauge diameter that actually went in, the facet count that separates
## them, and the fit residual.
##
## Every LENGTH here is a world millimetre, because that is where the gauge
## measured it; `local` carries the same lengths in the reference file's own
## frame, which is what an LLM comparing against the part's drawing wants. The
## two differ exactly when the pose scales, and `scale` says by how much.
static func _report_cylinder(
	measured: Dictionary,
	record: Dictionary,
	pose: Transform3D
) -> Dictionary:
	var centre: Vector3 = measured.get("center", Vector3.ZERO)
	var axis: Vector3 = measured.get("axis", Vector3.UP)
	var factor := pose_scale(pose)
	var local_lengths := {}
	for key in SCALED_LENGTH_KEYS:
		var value: Variant = measured.get(key, null)
		if value != null:
			local_lengths[key] = float(value) / factor
	return {
		"reference": str(record.get("name", "")),
		"node": str(measured.get("node", "")),
		"nodes": measured.get("nodes", [str(measured.get("node", ""))]),
		"form": str(measured.get("form", "")),
		"center_mm": _points(centre, pose),
		"axis": _axes(axis, pose),
		"dia_mm": float(measured.get("dia_mm", 0.0)),
		"inscribed_dia_mm": float(measured.get("inscribed_dia_mm", 0.0)),
		"gauge_dia_mm": float(measured.get("gauge_dia_mm", 0.0)),
		# False when no wall was met inside the search bound: gauge_dia_mm is
		# then 0 and gauge_dia_at_least_mm carries the floor the bound implies.
		"gauge_bounded": bool(measured.get("gauge_bounded", true)),
		"gauge_dia_at_least_mm": float(measured.get("gauge_dia_at_least_mm", 0.0)),
		"facets": int(measured.get("facets", 0)),
		"coverage": float(measured.get("coverage", 0.0)),
		"residual_mm": measured.get("residual_mm", null),
		"extent_mm": float(measured.get("extent_mm", 0.0)),
		"through": bool(measured.get("through", false)),
		"depth_mm": float(measured.get("depth_mm", 0.0)),
		"verified": bool(measured.get("verified", false)),
		"source": str(measured.get("source", "fit")),
		"scale": factor,
		"local": local_lengths,
	}


## The mask a measurement of `record` runs under.
##
## Scope is the caller's word, not a default. A caller that NAMED a reference
## is asking about that part on its own, and a second part crossing the hole is
## not part of the answer. A caller that named none is asking about the
## ASSEMBLY, where a mating part obstructing a hole is exactly the thing worth
## reporting — so an unscoped call queries every body.
static func _scope_mask(gauge: Node, args: Dictionary, record: Dictionary) -> int:
	if str(args.get("reference", "")).is_empty():
		return _mask_for(gauge, "")
	return _mask_for(gauge, str(record.get("name", "")))


## Collision mask for one reference, or every layer for an empty name. The
## mask IS the scope: the gauge reads the reference name that travels with
## each job only under a narrowed mask, to tell overflow references sharing
## Godot's final collision layer apart; under every layer it is ignored.
static func _mask_for(gauge: Node, reference_name: String) -> int:
	if gauge == null or not gauge.has_method("mask_for"):
		# Every layer. A zero mask would report a fit everywhere.
		return 0xFFFFFFFF
	return int(gauge.call("mask_for", reference_name))


## The gauge must be a live node inside the tree before anything is awaited on
## it: a submit to a gauge that cannot step physics would never return.
static func _gauge_ready(gauge: Node) -> bool:
	return gauge != null and is_instance_valid(gauge) and gauge.is_inside_tree()


## The pose of one NAMED reference. There is deliberately no "first reference"
## fallback: an unnamed or unknown reference has no local frame, and a caller
## that guessed one would report a local position measured off another part.
static func _pose_for(panel, reference_name: String) -> Transform3D:
	for entry in _records(panel):
		var record: Dictionary = entry
		if not reference_name.is_empty() and str(record.get("name", "")) == reference_name:
			return record.get("pose", Transform3D.IDENTITY)
	return Transform3D.IDENTITY


## A raw candidate names one node; a merged entry carries the list.
static func _nodes_of(candidate: Dictionary) -> Array:
	if candidate.has("nodes"):
		return (candidate["nodes"] as Array).duplicate()
	return [str(candidate.get("node", ""))]


static func _has_reference(panel, reference_name: String) -> bool:
	if reference_name.is_empty():
		return false
	for entry in _records(panel):
		if str((entry as Dictionary).get("name", "")) == reference_name:
			return true
	return false


## A world point in both frames when the reference is known, and in world only
## — with the reason — when it is not.
static func _frames(panel, world: Vector3, reference_name: String) -> Dictionary:
	if _has_reference(panel, reference_name):
		return _points(world, _pose_for(panel, reference_name))
	var reason := "no reference named the point, so it is reported in world only"
	if not reference_name.is_empty():
		reason = "no mounted reference is named '%s'; world only" % reference_name
	return {"world": _vec(world), "local": null, "local_unavailable": reason}


static func _points(world: Vector3, pose: Transform3D) -> Dictionary:
	return {
		"world": _vec(world),
		"local": _vec(pose.affine_inverse() * world),
	}


static func _axes(world: Vector3, pose: Transform3D) -> Dictionary:
	var local := pose.basis.inverse() * world
	return {
		"world": _vec(world.normalized()),
		"local": _vec(local.normalized() if local.length_squared() > 0.0 else Vector3.UP),
	}


static func _boxes(local_box: AABB, pose: Transform3D) -> Dictionary:
	var world_box := AABB()
	var lo := local_box.position
	var hi := local_box.position + local_box.size
	var first := true
	for i in range(8):
		var corner := Vector3(
			hi.x if (i & 1) != 0 else lo.x,
			hi.y if (i & 2) != 0 else lo.y,
			hi.z if (i & 4) != 0 else lo.z
		)
		var p := pose * corner
		if first:
			world_box = AABB(p, Vector3.ZERO)
			first = false
		else:
			world_box = world_box.expand(p)
	return {
		"local": {"min": _vec(lo), "max": _vec(hi)},
		"world": {
			"min": _vec(world_box.position),
			"max": _vec(world_box.position + world_box.size),
		},
	}


## A Transform3D as the row-major 4x4 the DSL and the worker speak.
static func _matrix(pose: Transform3D) -> Array:
	var b := pose.basis
	var o := pose.origin
	return [
		[b.x.x, b.y.x, b.z.x, o.x],
		[b.x.y, b.y.y, b.z.y, o.y],
		[b.x.z, b.y.z, b.z.z, o.z],
		[0.0, 0.0, 0.0, 1.0],
	]


static func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _vector(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


static func _extent_along(bounds: AABB, direction: Vector3) -> float:
	return absf(bounds.size.x * direction.x) \
		+ absf(bounds.size.y * direction.y) \
		+ absf(bounds.size.z * direction.z)


# ── Envelope builders (self-contained, mirrors pcb/ui/panel_tools.gd) ────────

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
