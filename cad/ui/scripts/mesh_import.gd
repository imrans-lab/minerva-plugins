## mesh_import.gd — turning a picked mesh file into one line of .mcad source.
##
## The GUI import action is text authoring, not a second way to hold geometry:
## everything it does ends as `refN = mesh("path")` in the document, so the pose
## verbs, undo, save and an LLM reading the source all keep working on it. This
## module is the whole decision — which name, which path, what the line looks
## like — kept out of the panel so it can be exercised without a viewport, and
## kept away from the panel's other state so it cannot drift into holding any.
##
## Nothing here touches the filesystem or the document buffer. The caller owns
## both: it hands in the current source text and the two paths, and gets back
## the source it should write.
extends RefCounted

## Extensions the panel can actually load today (reference_meshes.gd reads
## glTF and STL). OBJ joins this list when its parser lands — the file dialog,
## the import guard and the skill text all read it from here.
const SUPPORTED_EXTENSIONS: Array = ["glb", "gltf", "stl"]

## Prefix for generated binding names. `ref1`, `ref2`, … — numbered from the
## first, because an unnumbered `ref` followed by `ref2` reads as if the second
## import were the odd one out.
const NAME_PREFIX: String = "ref"


## Filter strings for a FileDialog, built from SUPPORTED_EXTENSIONS so a new
## format cannot be loadable but unpickable.
static func dialog_filters() -> PackedStringArray:
	var patterns := PackedStringArray()
	for extension in SUPPORTED_EXTENSIONS:
		patterns.append("*." + extension)
	var filters := PackedStringArray()
	filters.append("%s ; Mesh files" % ", ".join(patterns))
	filters.append("* ; All files")
	return filters


## True when `path` names a format the panel can load.
static func is_supported(path: String) -> bool:
	return path.get_extension().to_lower() in SUPPORTED_EXTENSIONS


## How the mesh file should be spelled inside a document saved at
## `document_path`. Returns {path, absolute, warning}.
##
## A relative path is what makes the .mcad portable — the pair of files can be
## copied to another machine or another checkout and still resolve. It is only
## possible once the document has a home: an unsaved document, or a mesh on a
## different Windows volume, gets the absolute path plus a warning saying so.
static func document_relative_path(mesh_path: String, document_path: String) -> Dictionary:
	var absolute := mesh_path.simplify_path()
	var out := {"path": absolute, "absolute": true, "warning": ""}

	var document := document_path.strip_edges()
	if document.is_empty():
		out["warning"] = (
			"'%s' was written as an absolute path because this document has "
			+ "never been saved. Save the .mcad next to the mesh and rewrite "
			+ "the path relative to it to keep the pair portable."
		) % absolute.get_file()
		return out

	var document_parts := document.simplify_path().get_base_dir().split("/", false)
	var mesh_parts := absolute.split("/", false)
	if mesh_parts.is_empty():
		return out

	# Nothing in common means a different Windows drive, or two trees that only
	# meet at the filesystem root. Either way a relative path would be a chain
	# of `..` with no meaning to a reader, so the absolute path stays.
	var shared := 0
	while shared < document_parts.size() and shared < mesh_parts.size() \
			and document_parts[shared] == mesh_parts[shared]:
		shared += 1
	if shared == 0 and not document_parts.is_empty():
		out["warning"] = (
			"'%s' shares no directory with the document, so the path stayed "
			+ "absolute and the pair is not portable together."
		) % absolute.get_file()
		return out

	var segments := PackedStringArray()
	for _step in range(document_parts.size() - shared):
		segments.append("..")
	for index in range(shared, mesh_parts.size()):
		segments.append(mesh_parts[index])

	out["path"] = "/".join(segments)
	out["absolute"] = false
	return out


## The next free `refN` for this source. Every left-hand side already bound in
## the document is skipped, so importing twice yields ref1 then ref2 and an
## import into a document that already hand-wrote `ref1 = mesh(...)` yields
## ref2 — neither can shadow what is already there.
static func next_reference_name(source: String) -> String:
	var taken := bound_names(source)
	var index := 1
	while ("%s%d" % [NAME_PREFIX, index]) in taken:
		index += 1
	return "%s%d" % [NAME_PREFIX, index]


## Names the source binds at any indentation: the identifier on the left of a
## top-level or module-body `=`. Comparisons (`==`) are not assignments.
static func bound_names(source: String) -> PackedStringArray:
	var names := PackedStringArray()
	var pattern := RegEx.new()
	pattern.compile("(?m)^[ \\t]*([A-Za-z_][A-Za-z0-9_]*)[ \\t]*=[^=]")
	for found in pattern.search_all(source + "\n"):
		var name := found.get_string(1)
		if not (name in names):
			names.append(name)
	return names


## True when the path can live inside a one-line DSL statement. POSIX allows a
## newline or a carriage return in a filename; the statement `refN = mesh("…")`
## has no way to carry one, so such a path is refused rather than written out
## as a broken — or injected — pair of lines.
static func path_is_one_line(path: String) -> bool:
	return not (path.contains("\n") or path.contains("\r"))


## The source line an import adds. The path is embedded as a double-quoted
## string, so a backslash or a quote inside it is escaped rather than ending
## the literal early. A path that is not one line has no representation here
## and yields an empty string; plan_import refuses it by name before this runs.
static func mesh_line(name: String, path: String) -> String:
	if not path_is_one_line(path):
		push_error("mesh() path contains a line break and cannot be written: %s" % path)
		return ""
	var quoted := path.replace("\\", "\\\\").replace("\"", "\\\"")
	return "%s = mesh(\"%s\")" % [name, quoted]


## `source` with `line` appended as its own last line, exactly once. A source
## that did not end in a newline gets one first, so the import never joins
## itself onto the statement the user was in the middle of writing.
static func append_line(source: String, line: String) -> String:
	if source.is_empty():
		return line + "\n"
	var separator := "" if source.ends_with("\n") else "\n"
	return source + separator + line + "\n"


## The whole decision, in one call: what the new source is, what was added and
## what the user has to be told. Returns
## {ok, source, line, name, path, absolute, warning, error}.
## `source` is unchanged and `ok` is false when `error` is set.
static func plan_import(
	source: String,
	mesh_path: String,
	document_path: String
) -> Dictionary:
	var plan := {
		"ok": false,
		"source": source,
		"line": "",
		"name": "",
		"path": "",
		"absolute": true,
		"warning": "",
		"error": "",
	}

	var picked := mesh_path.strip_edges()
	if picked.is_empty():
		plan["error"] = "no file was chosen"
		return plan
	if not path_is_one_line(picked):
		plan["error"] = ("'%s' contains a line break; a mesh() statement is one "
			+ "line and cannot name it. Rename the file and import it again.") \
			% picked.replace("\n", "\\n").replace("\r", "\\r")
		return plan
	if not is_supported(picked):
		plan["error"] = "'%s' is not a mesh format this panel can load (%s)" % [
			picked.get_file(), ", ".join(SUPPORTED_EXTENSIONS),
		]
		return plan

	var spelled := document_relative_path(picked, document_path)
	var name := next_reference_name(source)
	var line := mesh_line(name, str(spelled["path"]))

	plan["ok"] = true
	plan["source"] = append_line(source, line)
	plan["line"] = line
	plan["name"] = name
	plan["path"] = str(spelled["path"])
	plan["absolute"] = bool(spelled["absolute"])
	plan["warning"] = str(spelled["warning"])
	return plan
