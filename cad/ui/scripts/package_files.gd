extends RefCounted
## Portable paths live beside unchanged DSL, scoped to that document only.
const SUFFIX := ".package.json"
const SCHEMA := "minerva.cad.package/v1"
const MAX_BYTES := 512 * 1024 * 1024
var _maps: Dictionary = {}

func clear() -> void:
	_maps.clear()

func resolve(raw: String, document_path: String) -> Dictionary:
	var sidecar := document_path + SUFFIX
	if document_path.is_empty() or not FileAccess.file_exists(sidecar):
		return {}
	if not _maps.has(sidecar):
		var file := FileAccess.open(sidecar, FileAccess.READ)
		if file == null or file.get_length() > 4 * 1024 * 1024:
			return {"path": "", "warning": "", "error": "Cannot read CAD package map: " + sidecar}
		var parser := JSON.new()
		if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary or parser.data.get("schema") != SCHEMA:
			return {"path": "", "warning": "", "error": "Invalid CAD package map: " + sidecar}
		_maps[sidecar] = parser.data
	var manifest: Dictionary = _maps[sidecar]
	var mapping = manifest.get("paths", {})
	if not mapping is Dictionary:
		return {"path": "", "warning": "", "error": "CAD package paths must be a dictionary"}
	if not mapping.has(raw):
		return {}
	var relative := str(mapping[raw])
	var path := inside(document_path.get_base_dir(), relative)
	if path.is_empty():
		return {"path": "", "warning": "", "error": "CAD package path leaves its directory: " + relative}
	return {"path": path, "warning": "", "error": ""}

static func inside(root: String, relative: String) -> String:
	if relative.is_absolute_path():
		return ""
	var base := root.simplify_path().trim_suffix("/")
	var path := base.path_join(relative).simplify_path()
	return path if path.begins_with(base + "/") else ""

## Freeze an asset relative to the common ancestor of it and its side files.
## URI relationships survive, and repackaging does not grow nested absolute paths.
static func freeze(library: RefCounted, dependencies: Array, document_path: String, directory: String) -> Dictionary:
	var paths: Dictionary = {}
	var files: Dictionary = {}
	var originals: Dictionary = {}
	var total := 0
	for reference: Dictionary in dependencies:
		var raw := str(reference.get("path", "")).strip_edges()
		if paths.has(raw):
			continue
		var resolved: Dictionary = library.resolve(raw, document_path)
		if not str(resolved.get("error", "")).is_empty():
			return {"error": resolved.error}
		var absolute := str(resolved.get("path", ""))
		var dependencies_of_asset: Array = library.dependency_paths(absolute)
		var common := absolute.get_base_dir()
		for dependency: String in dependencies_of_asset:
			while not dependency.begins_with(common.trim_suffix("/") + "/"):
				var parent := common.get_base_dir()
				if parent == common or parent.is_empty():
					return {"error": "Dependency has no shared filesystem root: " + dependency}
				common = parent
		var asset_root := "dependencies/" + raw.sha256_text() + "/"
		for dependency: String in dependencies_of_asset:
			var relative := asset_root + dependency.trim_prefix(common.trim_suffix("/") + "/")
			var target := inside(directory, relative)
			if target.is_empty():
				return {"error": "Unsupported dependency path: " + dependency}
			if files.has(relative):
				continue
			var input := FileAccess.open(dependency, FileAccess.READ)
			if input == null:
				return {"error": "Required dependency is missing or unreadable: " + dependency}
			total += input.get_length()
			if total > MAX_BYTES or files.size() >= 2048:
				return {"error": "CAD package exceeds 512 MiB or 2048 dependency files"}
			var bytes := input.get_buffer(input.get_length())
			if bytes.size() != input.get_length():
				return {"error": "Dependency changed while reading: " + dependency}
			var error := write_bytes(target, bytes)
			if not error.is_empty():
				return {"error": error}
			files[relative] = {"sha256": FileAccess.get_sha256(target), "bytes": bytes.size()}
			originals[dependency] = files[relative].sha256
		paths[raw] = asset_root + absolute.trim_prefix(common.trim_suffix("/") + "/")
	for path: String in originals:
		if FileAccess.get_sha256(path) != str(originals[path]):
			return {"error": "Dependency changed while freezing package: " + path}
	return {"paths": paths, "files": files, "bytes": total}

static func write_bytes(path: String, bytes: PackedByteArray) -> String:
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return "Cannot create package directory: " + path.get_base_dir()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot write package file: " + path
	file.store_buffer(bytes)
	file.flush()
	return "" if file.get_error() == OK else "Could not finish writing: " + path
