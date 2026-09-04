extends RefCounted
## CAD panel-executed MCP tool surface (DCR 019f6c3d0e3d, round C6).
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

## Default hole diameters to look for, in millimetres. Wide enough for a via
## and a mounting hole, narrow enough to leave the outline alone.
const DEFAULT_MIN_DIA_MM: float = 0.3
const DEFAULT_MAX_DIA_MM: float = 30.0
## A wall has to go this far round for the fitter to call it a hole rather than
## a fillet.
const DEFAULT_MIN_COVERAGE: float = 0.6
## Ray-grid fallback pitch, used only when the fitter proposes nothing at all.
const FALLBACK_PITCH_MM: float = 1.0


static func handle(panel, tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_cad_view_state":
			return _view_state(panel, args)
		"minerva_cad_references":
			return _references(panel, args)
		"minerva_cad_find_holes":
			return await _find_holes(panel, args)
		"minerva_cad_find_cylinders":
			return await _find_cylinders(panel, args)
		"minerva_cad_gauge":
			return await _gauge(panel, args)
		"minerva_cad_probe":
			return await _probe(panel, args)
		"minerva_cad_view_overlay":
			return _view_overlay(panel, args)
	return {}


## minerva_cad_view_state — delegates to CADPanel.get_view_state().
static func _view_state(panel, _args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("get_view_state"):
		return _err("CAD view state not available on this panel")
	return _ok(panel.get_view_state())


# ---------------------------------------------------------------------------
# References and node bounds
# ---------------------------------------------------------------------------

static func _references(panel, _args: Dictionary) -> Dictionary:
	var records := _records(panel)
	var out: Array = []
	for entry in records:
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var nodes: Array = []
		for node_entry in record.get("node_bounds", []):
			var node: Dictionary = node_entry
			var box: AABB = node.get("aabb", AABB())
			nodes.append({
				"name": str(node.get("name", "")),
				"bbox_mm": _boxes(box, pose),
			})
		out.append({
			"name": str(record.get("name", "")),
			"path": str(record.get("path", "")),
			"resolved_path": str(record.get("resolved_path", "")),
			"pose": _matrix(pose),
			"bbox_mm": _boxes(record.get("local_aabb", AABB()), pose),
			"nodes": nodes,
		})
	return _ok({
		"units": "mm",
		"references": out,
		"count": out.size(),
		"note": "The evaluated solid is described by minerva_cad_get_mesh_info; "
			+ "this verb describes the foreign meshes named by mesh().",
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
	if gauge == null or features == null:
		return _err("the measurement modules are not available on this panel")
	panel.ensure_gauge_built()

	var holes: Array = []
	var proposed := 0
	var fell_back := false
	# Segmentation time for the files that were segmented on THIS call. Zero
	# means every reference was already analysed: the cost is per file, not per
	# question, and this is the number that says so.
	var segment_ms := 0
	for entry in scope["records"]:
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var before := int(features.call("get_analysis_count"))
		var analysis := _analysis(panel, record, args)
		if int(features.call("get_analysis_count")) > before:
			segment_ms += int(analysis.get("elapsed_ms", 0))
		var candidates: Array = _MeshFeatures.concave_cylinders(
			analysis.get("candidates", []),
			min_dia,
			max_dia,
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
		if posed.is_empty():
			continue

		var measured: Dictionary = await gauge.call("submit", "measure_holes", {
			"candidates": posed,
		})
		if measured.has("error"):
			return _err(str(measured["error"]))
		for hole in measured.get("holes", []):
			var report := _report_cylinder(hole as Dictionary, record, pose)
			if bool(args.get("verified_only", false)) and not bool(report["verified"]):
				continue
			holes.append(report)

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
	if gauge == null:
		return _err("measurement gauge is not available on this panel")
	panel.ensure_gauge_built()

	var found: Array = []
	for entry in scope["records"]:
		var record: Dictionary = entry
		var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
		var analysis := _analysis(panel, record, args)
		var concave: Array = []
		var convex: Array = []
		for candidate_entry in analysis.get("candidates", []):
			var candidate: Dictionary = candidate_entry
			if str(candidate.get("kind", "")) != "cylinder":
				continue
			var dia := float(candidate.get("dia_mm", 0.0))
			if dia < min_dia or dia > max_dia:
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

		if not concave.is_empty():
			var holes: Dictionary = await gauge.call(
				"submit", "measure_holes", {"candidates": concave})
			for hole in holes.get("holes", []):
				found.append(_report_cylinder(hole as Dictionary, record, pose))
		if not convex.is_empty():
			var bosses: Dictionary = await gauge.call(
				"submit", "measure_convex", {"candidates": convex})
			for boss in bosses.get("cylinders", []):
				found.append(_report_cylinder(boss as Dictionary, record, pose))

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
	if gauge == null:
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

	var result: Dictionary = await gauge.call("submit", "gauge", {
		"shape": shape,
		"size": size,
		"at": _vector(args.get("at_mm", [0.0, 0.0, 0.0])),
		"axis": _vector(args.get("axis", [0.0, 0.0, 1.0])),
	})
	if result.has("error"):
		return _err(str(result["error"]))

	var pose: Transform3D = _pose_for(panel, str(args.get("reference", "")))
	var contacts: Array = []
	for contact_entry in result.get("contacts", []):
		var contact: Dictionary = contact_entry
		contacts.append({
			"point_mm": _points(contact.get("point_mm", Vector3.ZERO), pose),
			"node": str(contact.get("node", "")),
		})
	return _ok({
		"units": "mm",
		"fits": bool(result.get("fits", false)),
		"contacts": contacts,
		"clearance_mm": float(result.get("clearance_mm", 0.0)),
	})


static func _probe(panel, args: Dictionary) -> Dictionary:
	var gauge: Node = panel.get_mesh_gauge()
	if gauge == null:
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
	var reference_name := node_name.get_slice("/", 0)
	var pose := _pose_for(panel, reference_name)
	return _ok({
		"units": "mm",
		"hit": true,
		"view": view,
		"position_mm": _points(hit.get("position", Vector3.ZERO), pose),
		"normal": _vec(hit.get("normal", Vector3.UP)),
		"reference": reference_name,
		"node": node_name,
		"width_px": ray.get("width_px", 0),
		"height_px": ray.get("height_px", 0),
	})


static func _view_overlay(panel, args: Dictionary) -> Dictionary:
	var mode := str(args.get("overlay", "grid"))
	if mode not in ["none", "grid", "axes", "grid+axes"]:
		return _err("overlay must be none, grid, axes or grid+axes")
	var drawn: Dictionary = panel.set_measurement_overlay(
		mode, float(args.get("grid_mm", 10.0)))
	var views: Array = []
	for view in ["top", "front", "right", "iso"]:
		var metrics: Dictionary = panel.get_view_metrics(view)
		if not metrics.has("error"):
			views.append(metrics)
	return _ok({
		"units": "mm",
		"overlay": str(drawn.get("mode", mode)),
		"grid_mm": float(drawn.get("grid_mm", 0.0)),
		"lines": int(drawn.get("lines", 0)),
		"views": views,
		"note": "Take the picture with minerva_cad_snapshot; the overlay is "
			+ "scene geometry and is captured with everything else.",
	})


# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------

static func _records(panel) -> Array:
	if panel == null or not panel.has_method("get_reference_state"):
		return []
	return panel.get_reference_state()


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
static func _analysis(panel, record: Dictionary, args: Dictionary) -> Dictionary:
	var features: RefCounted = panel.get_mesh_features()
	if features == null:
		return {"candidates": []}
	var node_filter := str(args.get("node", ""))
	var parts: Array = record.get("parts", [])
	if not node_filter.is_empty():
		var kept: Array = []
		for entry in parts:
			if str((entry as Dictionary).get("node", "")) == node_filter:
				kept.append(entry)
		parts = kept
	var key := "%s|%s|%s" % [
		str(record.get("resolved_path", "")),
		str(record.get("stamp", "")),
		node_filter,
	]
	return features.call(
		"features_for",
		key,
		parts,
		float(args.get("region_angle_deg", _MeshFeatures.DEFAULT_REGION_ANGLE_DEG))
	)


## A candidate in the reference's local frame, moved into the posed world where
## the gauge works.
static func _pose_candidate(candidate: Dictionary, pose: Transform3D) -> Dictionary:
	var posed := candidate.duplicate(true)
	posed["center"] = pose * (candidate.get("center", Vector3.ZERO) as Vector3)
	posed["axis"] = (pose.basis * (candidate.get("axis", Vector3.UP) as Vector3)).normalized()
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


## One measured cylinder, in both frames, with the numbers that make it
## falsifiable: the fitted (circumscribed) diameter the tessellation implies,
## the gauge diameter that actually went in, the facet count that separates
## them, and the fit residual.
static func _report_cylinder(
	measured: Dictionary,
	record: Dictionary,
	pose: Transform3D
) -> Dictionary:
	var centre: Vector3 = measured.get("center", Vector3.ZERO)
	var axis: Vector3 = measured.get("axis", Vector3.UP)
	return {
		"reference": str(record.get("name", "")),
		"node": str(measured.get("node", "")),
		"form": str(measured.get("form", "")),
		"center_mm": _points(centre, pose),
		"axis": _axes(axis, pose),
		"dia_mm": float(measured.get("dia_mm", 0.0)),
		"inscribed_dia_mm": float(measured.get("inscribed_dia_mm", 0.0)),
		"gauge_dia_mm": float(measured.get("gauge_dia_mm", 0.0)),
		"facets": int(measured.get("facets", 0)),
		"coverage": float(measured.get("coverage", 0.0)),
		"residual_mm": measured.get("residual_mm", null),
		"extent_mm": float(measured.get("extent_mm", 0.0)),
		"through": bool(measured.get("through", false)),
		"depth_mm": float(measured.get("depth_mm", 0.0)),
		"verified": bool(measured.get("verified", false)),
		"source": str(measured.get("source", "fit")),
	}


static func _pose_for(panel, reference_name: String) -> Transform3D:
	for entry in _records(panel):
		var record: Dictionary = entry
		if reference_name.is_empty() or str(record.get("name", "")) == reference_name:
			return record.get("pose", Transform3D.IDENTITY)
	return Transform3D.IDENTITY


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
