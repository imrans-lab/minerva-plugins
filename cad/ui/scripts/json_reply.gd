extends RefCounted
## One plugin-local JSON boundary. Never stringify or discard unsupported data.
## Consumers: ui/panel_tools.gd wraps every public reply, including early returns.
const MAX_DEPTH: int = 128
const MAX_VALUES: int = 1000000
const MAX_SAFE_INTEGER: int = 9007199254740991

static func response(reply: Dictionary) -> Dictionary:
	var budget: Array[int] = [MAX_VALUES]
	var converted: Dictionary = _convert(reply, 0, budget)
	if not bool(converted.get("ok", false)):
		return {"success": false, "error_code": "cad_reply_not_json",
			"error": str(converted.get("error", "CAD reply is not JSON-safe"))}
	return converted["value"] as Dictionary


static func _convert(value: Variant, depth: int, budget: Array[int]) -> Dictionary:
	budget[0] -= 1
	if depth > MAX_DEPTH or budget[0] < 0:
		return _failure("CAD reply exceeds the JSON structural budget")
	if value == null or value is String or value is bool:
		return {"ok": true, "value": value}
	if value is StringName:
		return {"ok": true, "value": str(value)}
	if value is int:
		if value < -MAX_SAFE_INTEGER or value > MAX_SAFE_INTEGER:
			return _failure("CAD reply integer exceeds the safe JSON range")
		return {"ok": true, "value": value}
	if value is float:
		if not is_finite(value):
			return _failure("CAD reply contains a nonfinite number")
		return {"ok": true, "value": value}
	var kind: int = typeof(value)
	if kind in [TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY,
			TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY,
			TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY,
			TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY,
			TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY]:
		if value.size() > budget[0]:
			return _failure("CAD reply exceeds the JSON structural budget")
		# Conversion preserves the element values. Vector/Color elements still
		# fail visibly below; no coordinates or byte encoding are invented.
		value = Array(value)
	if value is Array:
		var array: Array = []
		for child: Variant in value:
			var converted: Dictionary = _convert(child, depth + 1, budget)
			if not bool(converted.get("ok", false)):
				return converted
			array.append(converted["value"])
		return {"ok": true, "value": array}
	if value is Dictionary:
		var object: Dictionary = {}
		for key: Variant in value:
			if not (key is String or key is StringName):
				return _failure("CAD reply object key is not text")
			var text_key: String = str(key)
			if object.has(text_key):
				return _failure("CAD reply object keys collide after text conversion")
			var converted: Dictionary = _convert(value[key], depth + 1, budget)
			if not bool(converted.get("ok", false)):
				return converted
			object[text_key] = converted["value"]
		return {"ok": true, "value": object}
	return _failure("CAD reply contains unsupported type " + type_string(typeof(value)))


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
