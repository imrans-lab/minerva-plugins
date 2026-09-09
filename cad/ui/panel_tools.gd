extends "panel_tools_view.gd"
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
##   minerva_cad_material        is the solid HERE — at this point, and how
##                               thick along this ray. Air violates no check.
##   minerva_cad_snapshot_fit    the pane, rendered offscreen from a camera
##                               framed on the solid, a reference or a world
##                               box, so the geometry fills the pixels.
##   minerva_cad_snapshot_posed  the same picture from a pose the CALLER states
##                               — a direction or a yaw/pitch — in a world of
##                               its own, so it can look under a part no pane
##                               points at, and cut it open on a section plane.
##   minerva_cad_check_interference
##                               where the evaluated solid runs INTO a
##                               reference — the same report every evaluation
##                               already carries, on demand and scopeable.
##   minerva_cad_check_clearance
##                               how much air is between them, exactly. Both
##                               of those take against= (or
##                               reference="all-pairs") to measure two
##                               REFERENCES against each other instead —
##                               the off-board-parts layout question.
##   minerva_cad_reference_profile
##                               over a world-XY footprint, how tall is the
##                               reference geometry, and which node is it.
##   minerva_cad_check_fasteners will these screws go in — coaxiality, a clear
##                               path, engagement and head seating, per screw.
##   minerva_cad_check_design    all three of those, one after another, folded
##                               into one verdict and only the failing rows —
##                               the acceptance loop's check step.
##   minerva_cad_get_selected_reference
##                               which reference node the user last clicked,
##                               and where on it — the sibling of
##                               minerva_cad_get_selected_edge for foreign meshes.
##   minerva_cad_select_reference
##                               the same selection, made from here.
##   minerva_cad_view_overlay    draw a millimetre grid and the world axes in
##                               the panes, and report each pane's scale.
##   minerva_cad_await_eval      block until the panel has painted an
##                               evaluation — the wait a buffer edit needs
##                               before anything measures the result.
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
## THE FITTING AND PLUMBING LIVE UNDER THIS SCRIPT. ui/panel_tools_view.gd
## holds the two view verbs (minerva_cad_view_state, minerva_cad_view_overlay)
## and ui/panel_tools_measure.gd is the base under it: propose -> verify (minerva_cad_find_holes,
## minerva_cad_find_cylinders) and the scope, pose, frame and envelope
## helpers every verb here shares. Inheritance rather than a handle, so one
## preload of this file still resolves the whole panel-verb surface.
##
## Off-tree note: no class_name — preloaded by relative path from
## ui/cad_panel_scene.gd, the base CADPanel.gd extends.

const _ReferenceMeshes: Script = preload("scripts/reference_meshes.gd")
const _GeometryChecks: Script = preload("scripts/geometry_checks.gd")
const _FastenerChecks: Script = preload("scripts/fastener_checks.gd")
## The MCP rendering of an interference report: the panel keeps the full
## records digest for its joins, the wire carries a hash of it.
const _EvalReplyScript: Script = preload("scripts/eval_reply.gd")
## Which PART of the document a check is about, and how a named binding is
## evaluated into a mesh of its own.
const _PartScope: Script = preload("scripts/part_scope.gd")
## Each binding evaluated once per document, and the interference report the
## part-scoped clearance check joins against.
const _PartCache: Script = preload("scripts/part_cache.gd")
## The three checks run together and folded into one verdict. It is handed
## the check Callables rather than preloading this script back.
const _DesignCheck: Script = preload("scripts/design_check.gd")
## The verbs that ask about the references alone: reference-against-reference
## clearance and interference, and the z profile over a footprint.
const _ReferenceVerbs: Script = preload("scripts/reference_verbs.gd")
## The node boxes as keep-out source a shell can subtract (emit_dsl=true).
const _KeepoutDsl: Script = preload("scripts/keepout_dsl.gd")
## The framed capture: fit resolution, the offscreen camera and the PNG.
const _FitCapture: Script = preload("scripts/fit_capture.gd")
## The same picture from a stated pose, in a mirrored world of its own.
const _PosedCapture: Script = preload("scripts/posed_capture.gd")
## Whether the geometry a check is about to measure is the geometry the
## document describes, and the refusal when it is not.
const _Freshness: Script = preload("scripts/eval_freshness.gd")
## Several screw sizes in one call, each graded against its own reference.
const _FastenerScrews: Script = preload("scripts/fastener_screws.gd")
## The evaluated solid, mounted in front of a gauge for one call.
const _GaugeSolid: Script = preload("scripts/gauge_solid.gd")
## Is the solid here, answered in the worker off the B-Rep itself.
const _MaterialProbe: Script = preload("scripts/material_probe.gd")

## How long minerva_cad_await_eval waits by default, and the most it will
## wait when asked. A heavy document is minutes of worker time, and the cap
## is what stops a caller's own request window being spent inside the panel.
const DEFAULT_AWAIT_TIMEOUT_MS: int = 30000
const MAX_AWAIT_TIMEOUT_MS: int = 300000


## Every verb goes through the freshness gate first.
##
## A measuring verb reaches colliders built from the evaluation the panel
## PAINTED, and the document buffer runs ahead of that — an edit lands, the
## debounce runs, the worker takes its time, and a check in between measures
## the previous shape with nothing in its reply to say so. So the panel is
## asked whether the two describe one document: a measuring verb is REFUSED
## while they do not, and every check and await reply carries the version it
## was about, the version the buffer is at, and when that evaluation was
## stamped. See scripts/eval_freshness.gd.
## The verbs whose dispatch has a reference-pair branch (see _dispatch).
const PAIR_VERBS: Array[String] = [
	"minerva_cad_check_interference",
	"minerva_cad_check_clearance",
]


static func handle(panel, tool_name: String, args: Dictionary) -> Dictionary:
	if (_Freshness.MEASURING_VERBS.has(tool_name) or tool_name.begins_with("minerva_cad_snapshot")) and panel.has_method("verify_dependencies"):
		panel.verify_dependencies()
	var freshness: Dictionary = _Freshness.read(panel)
	if tool_name not in ["minerva_cad_build", "minerva_cad_await_eval", "minerva_cad_model"]:
		var requirement_error: String = _Freshness.requirement_error(args, freshness)
		if not requirement_error.is_empty():
			return _Freshness.stamp({"success": false, "checked": false,
				"error": requirement_error, "error_code": "evaluation_requirement"}, freshness)
		args = args.duplicate(true)
		args["_evaluated_document"] = preload("scripts/evaluation_state.gd").document(panel)

	var context_error: String = preload("scripts/model_views.gd").prepare_measurement(args, tool_name)
	if not context_error.is_empty():
		return _Freshness.stamp({"success": false, "checked": false, "pass": null,
			"reason": context_error, "error_code": "configuration_context"}, freshness)

	# A reference-against-reference call measures two mounted meshes and never
	# the evaluated solid, so the document running ahead of its evaluation
	# says nothing about its answer: it is STAMPED but not refused. Only the
	# two verbs that actually route a pair call away from the solid earn that;
	# an against= key on any other verb is ignored by its body and must not
	# lift the gate.
	var pair_call: bool = PAIR_VERBS.has(tool_name) and _ReferenceVerbs.is_pair_call(args)
	if not pair_call and not _Freshness.accepts_stale(args) and _Freshness.blocks(tool_name, freshness):
		return _Freshness.refusal(freshness)
	var scopes := preload("scripts/scoped_queries.gd")
	var reply: Dictionary
	if scopes.applies(tool_name, args):
		reply = await scopes.run(panel, tool_name, args, _dispatch)
	else:
		reply = await _dispatch(panel, tool_name, args)
	if tool_name in ["minerva_cad_build", "minerva_cad_model"]:
		return reply
	# Read AGAIN: the document can change while a measurement runs. A reply
	# stamped only with the state before it would say the geometry it
	# describes is current when it no longer is; one stamped only with the
	# state after would claim the NEW evaluation for numbers measured
	# against the old one. A painted evaluation that moved in between makes
	# the reply stale, with both versions named.
	var after: Dictionary = _Freshness.read(panel)
	if _Freshness.outrun(tool_name, freshness, after):
		return _Freshness.stamp_moved(reply, freshness, after)
	return _Freshness.stamp(reply, after)


static func _dispatch(panel, tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_cad_model":
			return await panel._model_views.handle(args)
		"minerva_cad_build":
			match str(args.get("action", "status")):
				"status": return panel.build_status()
				"build_latest": return panel.build_latest()
				"set_mode": return panel.set_build_mode(str(args.get("mode", "")))
			return {"success": false, "error": "Unknown build action"}
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
		"minerva_cad_material":
			# Per part like the other measuring verbs.
			return await _per_part(panel, args, _material)
		"minerva_cad_snapshot_fit":
			return await _FitCapture.snapshot(panel, args)
		"minerva_cad_snapshot_posed":
			return await _PosedCapture.snapshot(panel, args)
		"minerva_cad_check_interference":
			# against= (or reference="all-pairs") asks about two REFERENCES
			# and not about the solid, so it never scopes to a DSL part.
			if _ReferenceVerbs.is_pair_call(args):
				return await _fresh(panel, args, _pairs_interference)
			return await _per_part(panel, args, _check_interference)
		"minerva_cad_check_clearance":
			# Collecting a ticket measures nothing, so there is no snapshot
			# for a re-pose to invalidate — and a re-run would collect a
			# ticket the first attempt has already spent. The report it
			# hands back carries its own `references_moved`.
			if not str(args.get("ticket", "")).is_empty():
				return await _check_clearance(panel, args)
			if _ReferenceVerbs.is_pair_call(args):
				return await _fresh(panel, args, _pairs_clearance)
			return await _per_part(panel, args, _check_clearance)
		"minerva_cad_check_fasteners":
			return await _per_part(panel, args, _check_fasteners)
		"minerva_cad_check_design":
			# The three checks in one call. They are sequenced there, not
			# here, because interference and fasteners share the panel's one
			# solid collider and must not be in flight together.
			return await _DesignCheck.run(panel, args, _per_part,
				_check_interference, _check_clearance, _check_fasteners)
		"minerva_cad_reference_profile":
			return _ReferenceVerbs.reference_profile(panel, args)
		"minerva_cad_get_selected_reference":
			return await _fresh(panel, args, _selected_reference)
		"minerva_cad_select_reference":
			return await _fresh(panel, args, _select_reference)
		"minerva_cad_view_overlay":
			return _view_overlay(panel, args)
		"minerva_cad_await_eval":
			return await _await_eval(panel, args)
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
		# A reply that measured nothing — a clearance still running in the
		# worker — describes no pose, so a re-pose cannot have staled it.
		# Running the verb again would only start a second measurement.
		if str(reply.get("status", "")) == "running":
			return reply
	reply["stale"] = true
	reply["stale_reason"] = "the reference set changed while this measurement " \
		+ "was running, twice; the numbers describe a pose the document no " \
		+ "longer has — call again once the document is settled"
	return reply


## Run a check once per part. The fold lives in part_scope.gd, which owns what
## a part is; this binds the freshness wrapper every leg goes through.
static func _per_part(panel, args: Dictionary, verb: Callable) -> Dictionary:
	return await _PartScope.per_part(panel, args, verb, _fresh)


## The panel's digest of its mounted references, or "" for a panel that has
## none to report (a freed one included).
static func _reference_digest(panel) -> String:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("get_reference_digest"):
		return ""
	return str(panel.get_reference_digest())


# ---------------------------------------------------------------------------
# References and node bounds
# ---------------------------------------------------------------------------

## Every reference the document named, whether or not its file could be read.
## A failed one is reported with a status and a reason rather than left out:
## the list has to match the mesh() calls in the source, or the answer to
## "where is my board" is a shorter list with nothing to explain it.
static func _references(panel, args: Dictionary) -> Dictionary:
	var asked := str(args.get("reference", ""))
	var full := str(args.get("detail", "lean")) == "full"
	var records := _status_records(panel)
	var out: Array = []
	# The full rows regardless of detail=: the keep-out formatter reads the
	# node boxes, which the lean row does not carry.
	var rows: Array = []
	var named: Array = []
	var failed := 0
	var matched := false
	for entry in records:
		var record: Dictionary = entry
		named.append(str(record.get("name", "")))
		if not asked.is_empty() and str(record.get("name", "")) != asked:
			continue
		matched = true
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
		var row := {
			"name": str(record.get("name", "")),
			"path": str(record.get("path", "")),
			"resolved_path": str(record.get("resolved_path", "")),
			"content_stamp": str(record.get("stamp", "")),
			"definition": record.get("definition", ""),
			"source": record.get("source", ""), "accuracy": record.get("accuracy", "unspecified"),
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
		}
		rows.append(row)
		out.append(row if full else _ReplyShape.lean_reference(row))
	# A reference= that names nothing is a typo about the document, not an
	# empty scene: answering "no references" would hide it.
	if not asked.is_empty() and not matched:
		return _err("no reference named '%s' is mounted; mounted: %s"
			% [asked, ", ".join(named)])
	# The note is part of the reply's cost, so the lean one is a pointer and
	# the full one is the explanation.
	var note := "Lean rows: name, status, world bbox, node count. " \
		+ "detail=\"full\" adds the paths, the 4x4 pose, both frames and the " \
		+ "per-node boxes; reference=<name> scopes to one."
	if full:
		note = "The evaluated solid is described by minerva_cad_get_mesh_info; " \
			+ "this verb describes the foreign meshes named by mesh(). A " \
			+ "reference whose status is not 'ok' is drawn as a wireframe " \
			+ "marker at its pose and has loaded no geometry; `reason` says " \
			+ "why and names the file. A node's `path` from the file root is " \
			+ "its identity — `name` is only the leaf and two branches may " \
			+ "share one — and node= filters accept either."
	var payload := {
		"units": "mm",
		"references": out,
		"count": out.size(),
		"failed": failed,
		"detail": "full" if full else "lean",
		"note": note,
	}
	# The node boxes as source. Sizing a wall against a part means writing the
	# part's envelope into the document, and the envelope is already here.
	if bool(args.get("emit_dsl", false)):
		var emitted: Dictionary = _KeepoutDsl.emit(rows,
			args.get("nodes", []) as Array,
			float(args.get("clearance_mm", 0.0)))
		if emitted.has("error"):
			return _err(str(emitted["error"]))
		payload["dsl"] = str(emitted["dsl"])
		payload["dsl_bindings"] = emitted["bindings"]
		payload["dsl_note"] = "world millimetres, one cube per node grown by "\
			+ "clearance_mm on every side; subtract the bound names from your "\
			+ "part. Each box is taken in the node's WORLD pose, so a part "\
			+ "mounted at an angle keeps its world box and not a tight one."
		var omitted: Array = emitted["omitted"] as Array
		if not omitted.is_empty():
			payload["dsl_omitted"] = omitted
	return _ok(payload)


# ---------------------------------------------------------------------------
# Direct physical questions
# ---------------------------------------------------------------------------

## minerva_cad_material — the worker classifies; see scripts/material_probe.gd.
static func _material(panel, args: Dictionary) -> Dictionary:
	return await _MaterialProbe.probe(panel, args)


static func _gauge(panel, args: Dictionary) -> Dictionary:
	var gauge: Node = panel.get_mesh_gauge()
	if not _gauge_ready(gauge):
		return _err("measurement gauge is not available on this panel")
	var colliders := int(panel.ensure_gauge_built())

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

	# THE EVALUATED SOLID IS PART OF THE ANSWER. It lives in its own physics
	# world, so it has to be mounted in front of the gauge for the call; an
	# UNSCOPED question is about everything the pin could run into, and the
	# part being modelled is the first of those. A question scoped to one
	# mounted reference is about that reference, so it does not mount the
	# solid and does not pay for its collider.
	var solid: Dictionary = {"mounted": false, "reason": "reference= scoped "
		+ "this question to one mounted reference"}
	if asked.is_empty():
		solid = await _GaugeSolid.mount(panel)
	if not is_instance_valid(panel) or not _gauge_ready(gauge):
		_GaugeSolid.release(solid)
		return _err("the CAD panel closed while the gauge was being mounted")
	if colliders <= 0 and not bool(solid.get("mounted", false)):
		_GaugeSolid.release(solid)
		return _err("nothing to gauge against: no reference mesh is mounted "
			+ "and %s" % str(solid.get("reason", "there is no evaluated solid")))
	# AN UNSCOPED GAUGE WHOSE SOLID WENT UNMEASURED HAS NO VERDICT. The
	# question was about everything the pin could run into, and the part
	# being modelled is there but was not measured — another check holds it,
	# or its collider could not be built — so `fits` from the references
	# alone would answer yes to a pin buried in the solid. The verdict is
	# withheld and the reason named; reference= is the way to ask about the
	# references alone on purpose. A document with no solid geometry is
	# different: there is nothing the references could be hiding.
	if asked.is_empty() and bool(solid.get("unmeasured", false)):
		return _ok({
			"units": "mm",
			"checked": false,
			"fits": null,
			"contacts": [],
			"reason": "solid not measured: %s" % str(solid.get("reason",
				"the evaluated solid could not be mounted")),
			"measured_against": {
				"reference_colliders": colliders,
				"solid": false,
				"solid_triangles": 0,
				"solid_reason": str(solid.get("reason", "")),
			},
		})

	var result: Dictionary = await gauge.call("submit", "gauge", {
		"shape": shape,
		"size": size,
		"at": _vector(args.get("at_mm", [0.0, 0.0, 0.0])),
		"axis": _vector(args.get("axis", [0.0, 0.0, 1.0])),
		# The clearance search stops here. Without a ceiling from the caller
		# it runs to the scene's own extent, which is the only bound that is a
		# fact about the geometry rather than about the pin.
		"max_radius_mm": float(args.get("max_dia_mm", 0.0)) * 0.5,
		"mask": _scope_mask(gauge, args, {"name": asked}),
		"reference": asked,
		# The module owning the solid's world, so the job's rays reach it.
		"checks": solid.get("checks", null),
		# A verb reports WHERE a buried gauge is buried; the containment
		# probes fire thousands of the same job and read only the reason.
		"witness": true,
	})
	_GaugeSolid.release(solid)
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
		var witness := bool(contact.get("witness", false))
		var on := str(contact.get("on", "reference"))
		if on == "solid":
			# The evaluated part is in no reference's frame, so there is no
			# local coordinate for it and no reference name to invent.
			contacts.append({
				"point_mm": _frames(panel, contact.get("point_mm", Vector3.ZERO), ""),
				"node": "",
				"reference": "",
				"on": "solid",
				"witness": witness,
			})
			continue
		var entry := {
			"point_mm": _frames(panel, contact.get("point_mm", Vector3.ZERO), reference_name),
			"node": node_name,
			"reference": reference_name,
			"on": "reference",
			"witness": witness,
		}
		contacts.append(entry)
	var payload := {
		"units": "mm",
		"fits": bool(result.get("fits", false)),
		"contacts": contacts,
		"clearance_bound_mm": float(result.get("clearance_bound_mm", 0.0)),
		# WHAT THE ANSWER IS ABOUT. A gauge measured against the references
		# alone cannot see the part being modelled, and a reader that could
		# not tell the two cases apart would read "fits" as a fact about the
		# whole scene.
		"measured_against": {
			"reference_colliders": colliders,
			"solid": bool(solid.get("mounted", false)),
			"solid_triangles": int(solid.get("triangles", 0)),
		},
	}
	if not bool(solid.get("mounted", false)) and solid.has("reason"):
		payload["measured_against"]["solid_reason"] = str(solid["reason"])
	# A gauge that met geometry — the not-fitting branches — carries no flag of
	# its own; its clearance came off a wall, so it is bounded.
	payload["clearance_bounded"] = bool(result.get(
		"clearance_bounded", not result.has("clearance_at_least_mm")))
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
			+ "triangle of its own, so the contact reported carries "\
			+ "witness: true — the NEAREST surface of the body it is inside, "\
			+ "and `on` says which body that is. A witness contact is not a "\
			+ "foul: do not count it as a place the gauge touched."
	return _ok(payload)


## minerva_cad_await_eval — block until the panel's evaluation has settled.
##
## The write verbs answer before the worker does when the edit went through
## the shared buffer (minerva_doc_edit, or the user typing), so a measurement
## made straight after a write can describe the geometry the edit replaced.
## This verb closes that gap: it returns the status the panel PAINTED, and a
## timeout is reported rather than raised — the evaluation is still running.
static func _await_eval(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("await_evaluation"):
		return _err("this panel cannot report evaluation status")
	var timeout_ms := int(args.get("timeout_ms", DEFAULT_AWAIT_TIMEOUT_MS))
	timeout_ms = clampi(timeout_ms, 50, MAX_AWAIT_TIMEOUT_MS)
	var settled: Dictionary = await panel.await_evaluation(timeout_ms)
	if not is_instance_valid(panel):
		return _err("the CAD panel closed while its evaluation was awaited")
	var payload := {
		"status": "pending" if bool(settled.get("timed_out", false)) else "completed",
		"timed_out": bool(settled.get("timed_out", false)),
		"waited_ms": int(settled.get("waited_ms", 0)),
		"timeout_ms": timeout_ms,
		"last_eval": settled.get("last_eval", {}),
	}
	if bool(payload["timed_out"]):
		payload["note"] = "still evaluating after the timeout; the status is "\
			+ "the one the panel is showing now, and asking again resumes "\
			+ "the wait. Nothing was cancelled."
	return _ok(payload)


## minerva_cad_check_interference — where the solid and the references overlap.
##
## The panel runs this check on every evaluation anyway; the verb exists so an
## agent can ask about ONE reference or ONE node, and so it can ask again after
## an edit without having to find the last eval result.
##
## expected_contacts declares the contacts the design means to have, per pair;
## `count` then covers the rest. See scripts/expected_contacts.gd.
static func _check_interference(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("check_interference"):
		return _err("interference checking is not available on this panel")
	var asked := str(args.get("reference", ""))
	if not asked.is_empty() and not _has_reference(panel, asked):
		return _err("no reference named '%s' is mounted" % asked)
	var report: Dictionary = await panel.check_interference({
		"reference": asked,
		"node": str(args.get("node", "")),
		# The part this call is scoped to, when it is scoped to one: its own
		# tessellation in place of the document's render target, and the
		# source that produced it, so the report is stamped with that part's
		# digest and the clearance join lines up per part.
		"mesh": args.get("mesh", {}),
		"source": str(args.get("source", "")),
		"selection": args.get("selection", ""), "configuration": args.get("configuration", ""),
		# The contacts this design MEANS to have: measured like any other and
		# then held out of the count while the overlap stays inside what was
		# declared.
		"expected_contacts": args.get("expected_contacts", []),
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
## B-Rep surface. A measurement that outruns the caller's window comes back as
## a ticket; passing that ticket back collects it.
static func _check_clearance(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("check_clearance"):
		return _err("clearance checking is not available on this panel")
	var handle := str(args.get("ticket", ""))
	if not handle.is_empty():
		# A ticket names a measurement that was started with its own scope and
		# tolerance; nothing else in the call is read but the wait budget.
		var collected: Dictionary = await panel.check_clearance({"ticket": handle,
			"wait_ms": int(args.get("wait_ms", 0))})
		if collected.has("error"):
			return _err(str(collected["error"]))
		return _ok(_ReplyShape.filter_clearance(collected,
			int(args.get("limit", 0)), bool(args.get("failing_only", false)),
			str(args.get("detail", ""))))
	var asked := str(args.get("reference", ""))
	if not asked.is_empty() and not _has_reference(panel, asked):
		return _err("no reference named '%s' is mounted" % asked)
	await _ensure_part_interference(panel, args)
	var asked_clearance := {
		# The clearance measurement re-tessellates in the worker, so a
		# part-scoped call hands it that part's SOURCE rather than a mesh.
		"source": str(args.get("source", "")),
		"selection": args.get("selection", ""), "configuration": args.get("configuration", ""),
		"required_mm": float(args.get("required_mm", 0.0)),
		"tolerance_mm": float(args.get("tolerance_mm",
			_GeometryChecks.CLEARANCE_TOLERANCE_MM)),
		"reference": asked,
		"node": str(args.get("node", "")),
		"accept_unbounded_tolerance":
			bool(args.get("accept_unbounded_tolerance", false)),
		# The pairs this design MEANS to touch: graded against the gap each one
		# declares instead of required_mm, and listed in the reply with what
		# was measured for them.
		"expected_contacts": args.get("expected_contacts", []),
	}
	# How long this call may wait before it is handed a ticket; the client's
	# own window when the caller does not say.
	if args.has("wait_ms"):
		asked_clearance["wait_ms"] = int(args["wait_ms"])
	var report: Dictionary = await panel.check_clearance(asked_clearance)
	if report.has("error"):
		return _err(str(report["error"]))
	return _ok(_ReplyShape.filter_clearance(report,
		int(args.get("limit", 0)), bool(args.get("failing_only", false)),
		str(args.get("detail", ""))))


## Make sure a PART has an interference report of its own before its
## clearance is measured.
##
## A clearance distance is unsigned: it cannot tell a 0 that is a flush
## contact from a 0 that is a node buried in the wall, so the check joins the
## interference report for the same solid and refuses to pass without one.
## The document gets that report free — every evaluation runs the check — but
## a named part is a shape that exists only for the duration of this call, and
## with nothing to join, a part-scoped clearance could never pass. So the
## part's own check runs here first, unscoped, and lands in the part cache
## where the joiner looks for it.
##
## The collider for this part is already built by then (the check that built
## it is keyed on the same source digest), so this costs the ray walk and no
## rebuild. A report already in the cache for the colliders standing now is
## left alone; whether it is really fresh enough to join is still decided by
## the joiner, against the poses and the generation it recorded. Only an
## UNDECLARED report is ever in there — see _keep_part_report — so an
## interference leg that carried expected_contacts leaves this one to run.
static func _ensure_part_interference(panel, args: Dictionary) -> void:
	var source := str(args.get("source", ""))
	if source.strip_edges().is_empty():
		return
	var kept: Dictionary = _PartCache.interference(panel, _PartCache.scope_digest(args))
	if not kept.is_empty() and int(kept.get("gauge_generation", -1)) == _gauge_generation(panel):
		return
	# UNDECLARED ON PURPOSE. A declared pair leaves the report's `pairs` for
	# the declarations table, and the cache slot is keyed by source digest
	# alone: a report measured under one call's expected_contacts would be
	# handed to the next call, which may declare nothing, and a contained pair
	# missing from `pairs` reads there as "nothing crossing". The join wants
	# what is true of this shape whatever was declared; the declarations are
	# applied by the leg that stated them.
	await _check_interference(panel, {
		"mesh": args.get("mesh", {}),
		"source": source,
		"selection": args.get("selection", ""), "configuration": args.get("configuration", ""),
	})


## The gauge's collider generation, or -2 for a panel with no gauge — a value
## no report carries, so "no gauge" never reads as "the report is current".
static func _gauge_generation(panel) -> int:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("get_mesh_gauge"):
		return -2
	var gauge: Object = panel.get_mesh_gauge()
	if gauge == null or not is_instance_valid(gauge) \
			or not gauge.has_method("get_generation"):
		return -2
	return int(gauge.call("get_generation"))


## The two reference-against-reference entry points, as verbs _fresh can
## call: a Callable has to name a function of THIS script for the re-pose
## guard to wrap it, and the measurement itself lives in the sibling.
static func _pairs_clearance(panel, args: Dictionary) -> Dictionary:
	return await _ReferenceVerbs.check_pairs_clearance(panel, args)


static func _pairs_interference(panel, args: Dictionary) -> Dictionary:
	return await _ReferenceVerbs.check_pairs_interference(panel, args)


## minerva_cad_check_fasteners — will these screws actually go in?
##
## The holes come from _find_holes rather than from a second implementation:
## the fastener module never segments a reference, and a hole this verb pairs
## against is the same measured hole minerva_cad_find_holes would report, with
## the same gauge behind it. The diameter window defaults to a band around the
## screw so a board full of vias does not become a hundred pairing candidates.
##
## SEVERAL SIZES IN ONE CALL. `screws: [{dia_mm, length_mm, reference?, ...}]`
## grades each entry against the holes of its own reference only; `screw` is
## sugar for a one-element list and keeps the single-screw reply shape. The
## per-screw loop, the scoping and the merge live in scripts/fastener_screws.gd
## — it is handed _find_holes and _has_reference as Callables because they are
## members of this chain and preloading it back would be a cycle.
static func _check_fasteners(panel, args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("check_fasteners"):
		return _err("fastener checking is not available on this panel")
	var report: Dictionary = await _FastenerScrews.run(panel, args,
		_find_holes, _has_reference)
	if report.has("error"):
		return _err(str(report["error"]))
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
