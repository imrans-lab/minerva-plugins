extends RefCounted
## Persistent edge identity is geometry, never an evaluation-local integer.
## Coordinates and lengths are CAD millimetres; match within 0.0001 mm.
const TOLERANCE_MM: float = 0.0001

static func build(edge_id: int, edges: Array) -> Dictionary:
	for value: Variant in edges:
		if not value is Dictionary:
			continue
		var edge: Dictionary = value
		if number(edge.get("id", -1)) != edge_id:
			continue
		var signature := geometry(edge)
		if not signature.is_empty():
			return {"plugin": "cad", "type": "edge", "id": edge_id, "geometry": signature}
	return {}

static func resolve(anchor: Dictionary, edges: Array) -> Dictionary:
	var saved_value: Variant = anchor.get("geometry")
	var saved: Dictionary = saved_value if saved_value is Dictionary else {}
	var signature := geometry(saved)
	var matches: Array[Dictionary] = []
	if not signature.is_empty():
		for value: Variant in edges:
			if not value is Dictionary:
				continue
			var edge: Dictionary = value
			var candidate := geometry(edge)
			if not candidate.is_empty() and same(signature, candidate):
				matches.append({"position": position(candidate),
					"edge_id": int(number(edge.get("id", -1))), "stale": false})
	if matches.size() == 1:
		return matches[0]
	return {"position": position(saved), "edge_id": int(number(anchor.get("id", -1))), "stale": true}

static func geometry(edge: Dictionary) -> Dictionary:
	var midpoint := coordinates(edge.get("midpoint"))
	var kind := str(edge.get("kind", ""))
	var length_value: Variant = edge.get("length")
	if midpoint.is_empty() or kind.is_empty() or not finite_number(length_value) or number(length_value) < 0.0:
		return {}
	var signature := {"kind": kind, "midpoint": midpoint, "length": number(length_value)}
	var radius: Variant = edge.get("radius")
	if radius != null:
		if not finite_number(radius) or number(radius) < 0.0:
			return {}
		signature["radius"] = number(radius)
	return signature

static func same(left: Dictionary, right: Dictionary) -> bool:
	return left.kind == right.kind and position(left).distance_to(position(right)) <= TOLERANCE_MM \
		and absf(number(left.length) - number(right.length)) <= TOLERANCE_MM \
		and left.has("radius") == right.has("radius") \
		and (not left.has("radius") or absf(number(left.radius) - number(right.radius)) <= TOLERANCE_MM)

static func position(edge: Dictionary) -> Vector3:
	var midpoint := coordinates(edge.get("midpoint"))
	return Vector3(midpoint[0], midpoint[1], midpoint[2]) if midpoint.size() == 3 else Vector3.ZERO

static func coordinates(value: Variant) -> Array[float]:
	if not value is Array:
		return []
	var raw: Array = value
	if raw.size() != 3:
		return []
	var result: Array[float] = []
	for coordinate: Variant in raw:
		if not finite_number(coordinate):
			return []
		result.append(number(coordinate))
	return result

static func finite_number(value: Variant) -> bool:
	if value is float:
		var scalar: float = value
		return is_finite(scalar)
	return value is int

static func number(value: Variant) -> float:
	if value is float:
		return value
	if value is int:
		var integer: int = value
		return float(integer)
	return 0.0
