extends RefCounted
## Point anchors: an annotation stuck to a spot on a reference mesh.
##
## THE FRAME IS THE WHOLE POINT. A cad/point anchor stores the point in the
## REFERENCE's own frame (converted CAD millimetres, the document's pose not
## applied) plus the name of the reference and of the node inside it. Resolving
## the anchor composes the pose the CURRENT evaluation gave that reference, so
## moving a mesh() call moves every annotation stuck to it without touching a
## single annotation. Storing a world point instead would strand every callout
## the moment the pose changed, silently and in the right-looking place.
##
## Envelope:
##   {
##     "plugin":    "cad",
##     "type":      "point",
##     "id":        "<reference>/<node>@x,y,z",   # required by the v2 schema
##     "reference": "<reference name>",
##     "node":      "<node name inside the file>",
##     "local":     [x, y, z],   # reference frame, millimetres
##     "normal":    [x, y, z],   # surface normal in the same frame, may be zero
##     "world":     [x, y, z],   # where it was when it was made — see below
##   }
##
## `world` is a memory, not a source of truth: it is what a stale resolve
## returns so a callout for a reference that is no longer in the document stays
## where the user last saw it instead of jumping to the origin.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/CadPointAnchor.gd")

const _CadAnchorTypesScript = preload("CadAnchorTypes.gd")

## Millimetres of precision kept in the anchor id. Two points closer than this
## on the same node share an id, which is exactly what "the same spot" means.
const ID_PRECISION: int = 3


## Build a conformant cad/point anchor. `local` and `normal` are in the
## reference's own frame; `world` is where that point sits under the pose in
## force when the anchor was made.
static func build(
	reference: String,
	node_name: String,
	local: Vector3,
	normal: Vector3 = Vector3.ZERO,
	world: Vector3 = Vector3.ZERO
) -> Dictionary:
	return {
		"plugin": _CadAnchorTypesScript.PLUGIN,
		"type": _CadAnchorTypesScript.POINT_TYPE,
		"id": point_id(reference, node_name, local),
		"reference": reference,
		"node": node_name,
		"local": [local.x, local.y, local.z],
		"normal": [normal.x, normal.y, normal.z],
		"world": [world.x, world.y, world.z],
	}


## Stable identity for a point: which node of which reference, and where on it.
static func point_id(reference: String, node_name: String, local: Vector3) -> String:
	var fmt := "%." + str(ID_PRECISION) + "f"
	return "%s/%s@%s,%s,%s" % [
		reference,
		node_name,
		fmt % local.x,
		fmt % local.y,
		fmt % local.z,
	]


static func is_point_anchor(anchor: Variant) -> bool:
	if not (anchor is Dictionary):
		return false
	var d: Dictionary = anchor
	return str(d.get("plugin", "")) == _CadAnchorTypesScript.PLUGIN \
		and str(d.get("type", "")) == _CadAnchorTypesScript.POINT_TYPE


## Resolve a cad/point anchor against the references a mount actually put on
## screen (CADPanel.get_reference_state() records).
##
## Returns null for an envelope that is not a point anchor at all, so the
## substrate falls back to the stored snapshot. Otherwise returns
##   {position: Vector3 (world), local: Vector3, normal: Vector3 (world),
##    reference: String, node: String, stale: bool}
## with stale=true — and the last-known world position — when the named
## reference is no longer mounted. A removed mesh() must leave the annotation
## marked, not crash the panel and not move the callout to the origin.
static func resolve(anchor: Variant, records: Array) -> Variant:
	if not is_point_anchor(anchor):
		return null
	var d: Dictionary = anchor
	var reference := str(d.get("reference", ""))
	var node_name := str(d.get("node", ""))
	var local := vec3_from(d.get("local", null))
	var normal := vec3_from(d.get("normal", null))
	var remembered := vec3_from(d.get("world", null))

	var record := record_named(records, reference)
	if record.is_empty():
		return {
			"position": remembered,
			"local": local,
			"normal": normal,
			"reference": reference,
			"node": node_name,
			"stale": true,
		}
	var pose: Transform3D = record.get("pose", Transform3D.IDENTITY)
	# A normal follows the inverse transpose of the pose, not the pose: a
	# reference posed with a non-uniform scale would otherwise report a
	# normal that is no longer perpendicular to the surface it came from.
	var world_normal := pose.basis.inverse().transposed() * normal
	return {
		"position": pose * local,
		"local": local,
		"normal": world_normal.normalized() if world_normal.length_squared() > 0.0 else Vector3.ZERO,
		"reference": reference,
		"node": node_name,
		"stale": false,
	}


## The mounted record with this name, or {} when the document no longer names
## it. There is deliberately no "first record" fallback: a point resolved
## against another reference's pose is a wrong answer with no error in it.
static func record_named(records: Array, reference: String) -> Dictionary:
	if reference.is_empty():
		return {}
	for entry in records:
		if not (entry is Dictionary):
			continue
		if str((entry as Dictionary).get("name", "")) == reference:
			return entry
	return {}


static func vec3_from(raw: Variant) -> Vector3:
	if raw is Vector3:
		return raw
	if raw is Array and (raw as Array).size() >= 3:
		var values: Array = raw
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO
