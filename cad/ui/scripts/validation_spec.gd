extends RefCounted
## Authored requirements reuse each measurement tool's shipped argument schema.
const SCHEMA := "minerva.cad.validation/v1"
const MAX_BYTES := 262144
const MAX_CHECKS := 64
const KINDS := {"design": "minerva_cad_check_design", "clearance": "minerva_cad_check_clearance",
	"interference": "minerva_cad_check_interference", "fasteners": "minerva_cad_check_fasteners"}
const OWNED := ["editor_name", "ticket", "source", "mesh", "parts", "wait_ms", "accept_last_completed",
	"require_source_version", "require_source_digest", "require_reference_digest", "selection", "configuration"]
var _schemas: Dictionary = {}

func _init() -> void:
	var path: String = get_script().resource_path.get_base_dir().path_join("../../manifest.json").simplify_path()
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(path))
	if manifest is Dictionary:
		for tool: Dictionary in manifest.get("tools", []):
			_schemas[str(tool.name)] = tool.get("input_schema", {})

func read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Cannot read validation specification: " + path}
	if file.get_length() > MAX_BYTES:
		return {"error": "Validation specification exceeds 256 KiB"}
	var text := file.get_as_text()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"error": "Invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()]}
	var error := validate(json.data)
	if not error.is_empty():
		return {"error": error}
	return {"specification": json.data, "path": path, "digest": text.sha256_text()}

func validate(value: Variant) -> String:
	if not value is Dictionary or value.get("schema") != SCHEMA:
		return "Expected schema " + SCHEMA
	for key in value:
		if key not in ["schema", "checks"]:
			return "Unknown specification field: " + str(key)
	var checks = value.get("checks")
	if not checks is Array or checks.is_empty() or checks.size() > MAX_CHECKS:
		return "checks must contain 1–64 entries"
	var ids: Dictionary = {}
	for check in checks:
		if not check is Dictionary:
			return "Each check must be an object"
		for key in check:
			if key not in ["id", "title", "kind", "selection", "configuration", "args"]:
				return "Unknown check field: " + str(key)
		for key in ["id", "kind", "selection", "configuration"]:
			if not check.get(key) is String:
				return "Each check needs an explicit string " + key
		var id: String = check.id
		if id.is_empty() or id.length() > 128 or ids.has(id):
			return "Check IDs must be nonempty, unique and at most 128 characters"
		ids[id] = true
		if not KINDS.has(check.kind):
			return "Unknown check kind: " + str(check.kind)
		if not check.get("title", "") is String:
			return "Check title must be text"
		var args = check.get("args", {})
		if not args is Dictionary:
			return "Check args must be an object"
		for key in args:
			if str(key).begins_with("_") or key in OWNED:
				return "Check args cannot override execution field: " + str(key)
		var schema: Dictionary = _schemas.get(KINDS[check.kind], {})
		if schema.is_empty():
			return "Installed tool schema unavailable for " + str(check.kind)
		var error := _argument_error(args, schema, id + ".args", true)
		if not error.is_empty():
			return error
	return ""

func _argument_error(value: Variant, schema: Dictionary, path: String, root_args: bool = false) -> String:
	var type := str(schema.get("type", ""))
	var valid := true
	match type:
		"object": valid = value is Dictionary
		"array": valid = value is Array
		"string": valid = value is String
		"boolean": valid = value is bool
		"number": valid = (value is float or value is int) and is_finite(float(value))
		"integer": valid = (value is float or value is int) and is_finite(float(value)) and float(value) == floor(float(value))
	if not valid:
		return path + " must be " + type
	if schema.has("enum") and not value in schema.enum:
		return path + " is not an allowed value"
	if type in ["number", "integer"]:
		if value < schema.get("minimum", -INF) or value > schema.get("maximum", INF):
			return path + " is out of range"
	if type == "array":
		if value.size() < int(schema.get("minItems", 0)) or value.size() > int(schema.get("maxItems", 1000000)):
			return path + " has the wrong number of entries"
		for index in range(value.size()):
			var error := _argument_error(value[index], schema.get("items", {}), path + "[%d]" % index)
			if not error.is_empty():
				return error
	if type == "object":
		var properties: Dictionary = schema.get("properties", {})
		for key in value:
			if not properties.has(key):
				if root_args or not bool(schema.get("additionalProperties", true)):
					return path + " has unknown argument " + str(key)
				continue
			var error := _argument_error(value[key], properties[key], path + "." + str(key))
			if not error.is_empty():
				return error
		for required in schema.get("required", []):
			if root_args and required == "editor_name":
				continue
			if not value.has(required):
				return path + " requires " + str(required)
	return ""
