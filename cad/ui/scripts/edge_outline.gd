extends RefCounted
## The evaluated solid's outline, drawn from the worker's B-Rep edges.
##
## The tessellation pass (reference_meshes.feature_edge_segments) decides what
## to draw by comparing triangle normals. That works on a mesh anyone handed
## us — a GLB or an STL reference has nothing else — but on a solid the worker
## built it is a guess at something the worker already knows exactly. Where a
## cylinder meets a curved face OCCT triangulates the intersection with slivers
## whose normals are unstable, and the guess comes back as isolated fragments
## along the seam: dots in the ortho panes.
##
## The edge registry has no such problem. It is topology: one entry per edge of
## the B-Rep, each carrying the edge sampled to chord tolerance. Drawing those
## polylines gives an outline where every segment belongs to a numbered edge —
## the same numbers the annotate and fillet tools address — so "which edge is
## that line?" is a lookup rather than an inference.
##
## References keep the tessellation path: they have no registry.
##
## No class_name: off-tree plugin scripts cannot use class_name.

## Shortest segment worth a line, in millimetres. The test is ABSOLUTE, not
## Vector3.is_equal_approx, whose epsilon scales with the coordinates: a solid
## posed a hundred metres from the origin makes that tolerance wider than the
## short edges of a small feature, and those edges would vanish from the
## outline. A micrometre is below anything the tessellator resolves, so only a
## genuinely coincident pair — the dot this pass exists to stop drawing — is
## skipped.
const DEGENERATE_SEGMENT_MM: float = 1.0e-6


## Endpoint pairs for every edge in `edges`, with the edge id each pair came
## from. Returns {segments: PackedVector3Array, edge_ids: PackedInt32Array,
## edges: int} — one id per SEGMENT (two positions), and `edges` the number of
## registry entries that contributed at least one segment.
##
## An entry is drawn from its `polyline` when it has one; otherwise from its
## `start`/`end`, which is exact for a straight edge and the best available
## stand-in for a curve from a worker too old to sample it. Entries that
## degenerate to a point contribute nothing: a zero-length segment is a dot,
## which is the thing this pass exists to stop drawing.
static func segments_from_edges(edges: Array) -> Dictionary:
	var segments := PackedVector3Array()
	var edge_ids := PackedInt32Array()
	var drawn := 0
	for entry_variant in edges:
		if not (entry_variant is Dictionary):
			continue
		var entry: Dictionary = entry_variant
		if not entry.has("id"):
			continue
		var id := int(entry["id"])
		var points := _points_of(entry)
		var before := segments.size()
		for index in range(points.size() - 1):
			var a := points[index]
			var b := points[index + 1]
			if a.distance_squared_to(b) <= DEGENERATE_SEGMENT_MM * DEGENERATE_SEGMENT_MM:
				continue
			segments.append(a)
			segments.append(b)
			edge_ids.append(id)
		if segments.size() > before:
			drawn += 1
	return {"segments": segments, "edge_ids": edge_ids, "edges": drawn}


## The ordered points of one registry entry: its sampled polyline, or its two
## endpoints when it has none. Empty when the entry carries neither.
static func _points_of(entry: Dictionary) -> PackedVector3Array:
	var points := PackedVector3Array()
	var polyline: Variant = entry.get("polyline", null)
	if polyline is Array and (polyline as Array).size() >= 2:
		for raw in (polyline as Array):
			if not _is_triple(raw):
				return PackedVector3Array()
			points.append(_vector3_from_triple(raw as Array))
		return points

	var start: Variant = entry.get("start", null)
	var end: Variant = entry.get("end", null)
	if not (_is_triple(start) and _is_triple(end)):
		return points
	points.append(_vector3_from_triple(start as Array))
	points.append(_vector3_from_triple(end as Array))
	return points


## Whether a registry field is an [x, y, z] triple. A malformed one is left out
## of the drawing rather than anchored to (0, 0, 0).
static func _is_triple(raw: Variant) -> bool:
	return raw is Array and (raw as Array).size() >= 3


static func _vector3_from_triple(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
