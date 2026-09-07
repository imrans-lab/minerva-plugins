extends RefCounted
## gauge_solid.gd — putting the EVALUATED SOLID in front of a gauge.
##
## minerva_cad_gauge asks "will this pin, at this place, go in", and until this
## file existed it asked only the mounted reference meshes: the solid's own
## collider lives in interference_world.gd's private world, rebuilt on every
## evaluation, and mesh_gauge.gd never saw it. A sphere dropped inside a 2 mm
## tray floor therefore came back {fits: true, contacts: []} — the one verb
## that can answer "is there material here" answering yes to everything.
##
## So the solid is mounted for the duration of ONE gauge call, the same way
## fastener_checks.gd borrows it: take the module's reservation, build the
## collider from the document's own render target, hand the module to the job
## so its rays reach both worlds, release. The reservation is what keeps a
## gauge from freeing a body a running check is casting against — the collider
## and the counters are module state, and one owner at a time is the rule.
##
## The document's render target has no stamp to cache a collider under, so
## build_solid is passed an empty key and welds every time; a gauge on a large
## part pays that build. It is the same build an interference check pays, and
## a cached one keyed on nothing would be a collider from another document.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/gauge_solid.gd"), from ui/panel_tools.gd


## Mount the panel's evaluated solid for one gauge call.
##
## Returns {mounted, triangles, checks, ticket} — `mounted` false with a
## `reason` when there is no solid to mount or the module is busy, which is
## never fatal on its own: a gauge against the references alone is still an
## answer, and the caller reports what it measured against.
static func mount(panel: Object) -> Dictionary:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("get_geometry_checks"):
		return _absent("this panel has no evaluated solid to gauge against")
	var checks: Object = panel.get_geometry_checks()
	if checks == null or not is_instance_valid(checks):
		return _absent("the solid's collider world is not available on this panel")

	var mesh_data: Dictionary = {}
	if panel.has_method("get_document_state"):
		mesh_data = (panel.get_document_state() as Dictionary).get("mesh", {}) as Dictionary
	if (mesh_data.get("faces", []) as Array).is_empty():
		return _absent("the document has not evaluated to any solid geometry")

	var reservation: Dictionary = await checks.call("reserve", false)
	var ticket := int(reservation.get("ticket", 0))
	if ticket == 0:
		return _absent("another check holds this panel's geometry; the gauge "
			+ "measured against the mounted references only")
	var triangles := int(checks.call("build_solid", mesh_data, ticket, ""))
	if triangles <= 0:
		checks.call("release_reservation", ticket)
		return _absent("the evaluation produced no solid geometry to gauge against")
	# The synchronous phase — welding a keyless render target, which is every
	# triangle of the part — ends here; past this point mesh_gauge times its
	# own job out. The reclaim clock is restarted rather than charged for
	# both, or an evaluation's own check reclaims the module mid-cast and
	# frees the body the gauge's rays are still meeting.
	checks.call("refresh_reservation", ticket)
	return {
		"mounted": true,
		"triangles": triangles,
		"checks": checks,
		"ticket": ticket,
	}


## Give the module back. Safe to call on a mount that never took it.
static func release(mounted: Dictionary) -> void:
	if not bool(mounted.get("mounted", false)):
		return
	var checks: Object = mounted.get("checks", null)
	if checks != null and is_instance_valid(checks):
		checks.call("release_reservation", int(mounted.get("ticket", 0)))


static func _absent(reason: String) -> Dictionary:
	return {"mounted": false, "triangles": 0, "checks": null, "ticket": 0,
		"reason": reason}
