extends "scan_tree_provider.gd"
## Aggregate scan_tree provider for a destination area (vault OR directory kind).
##
## Reads session_state with include_paths=true and renders one row per session
## entry of the matching kind.  Session is the source of truth — dest_registry
## is no longer consulted here.  See DCR 019e3c48f0da for rationale.
##
## Top-level destination nodes carry two extra fields scan_tree.gd reads to add
## inline row buttons:
##   dest_id: String  — synthetic "session:<label>" id for button dispatch
##   locked:  bool    — always false (session-tracked entries are not lockable)
##
## No class_name — off-tree plugin script; loaded via preload().

var _conn: Object = null
var _registry_path: String = ""  # kept for backward-compat init() signature; unused
var _area_kind: String = ""      # "vault" or "directory"
var _open_vault_path: String = ""  # kept for backward-compat init() signature; unused

## Latest session entries fetched (for any caller wanting to resolve label→path).
var last_destinations: Array = []

## W5d: vault path currently being built into category nodes (threaded through
## _build_category_nodes so doc rows can carry vault_path for extract_document).
var _building_vault_path: String = ""


## Attach connection + registry path + area kind.  Call before get_tree_data().
## open_vault_path: for vault areas, pass the currently-open vault path so it
## is always rendered directly from its file (W5c).  Ignored for directory areas.
func init(conn: Object, registry_path: String, area_kind: String, open_vault_path: String = "") -> void:
	_conn = conn
	_registry_path = registry_path
	_area_kind = area_kind
	_open_vault_path = open_vault_path


func get_source_label() -> String:
	return "Vaults" if _area_kind == "vault" else "Directories"


func get_tree_data() -> Array:
	if _conn == null:
		return []

	# Read the session (with paths, panel-only opt-in).
	var session_result: Dictionary = await _conn.call_tool(
		"minerva_scansort_session_state",
		{"include_paths": true},
	)
	if not session_result.get("ok", false):
		push_warning("[AreaProvider] session_state failed: %s" % session_result.get("error", "unknown"))
		return []

	var entries: Array = session_result.get("vaults" if _area_kind == "vault" else "dirs", [])
	last_destinations = entries.duplicate(true)

	var nodes: Array = []
	for entry: Dictionary in entries:
		var label: String     = str(entry.get("label", ""))
		var entry_path: String = str(entry.get("path", ""))
		if label.is_empty() or entry_path.is_empty():
			continue
		var synthetic_id: String = "session:%s" % label
		var children: Array
		var role: String
		if _area_kind == "vault":
			children = await _get_vault_children_by_path(entry_path)
			role = "vault_dest"
		else:
			children = await _get_directory_children_by_path(entry_path, synthetic_id)
			role = "dir_dest"
		nodes.append({
			"kind":      "folder",
			"name":      label,
			"key":       "dest:%s" % synthetic_id,
			"date":      "",
			"tooltip":   entry_path,
			"children":  children,
			"dest_id":   synthetic_id,
			"locked":    false,
			"node_role": role,
		})

	return nodes


# ---------------------------------------------------------------------------
# Per-destination child fetching (mirrors scan_tree_destination_provider.gd)
# ---------------------------------------------------------------------------

## W5c: fetch vault children directly from a vault path (bypasses registry).
## Used for the always-present open vault row.
func _get_vault_children_by_path(vault_path: String) -> Array:
	if vault_path.is_empty():
		return []

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_query_documents",
		{"vault_path": vault_path},
	)
	if not result.get("ok", false):
		push_warning("[AreaProvider] open vault query_documents failed: %s" % result.get("error", "unknown"))
		return []

	_building_vault_path = vault_path
	return _build_category_nodes(result.get("documents", []))


## Build a category→document tree from a flat documents array.
func _build_category_nodes(docs: Array) -> Array:
	var by_category: Dictionary = {}
	for doc: Dictionary in docs:
		var cat: String = str(doc.get("category", "uncategorized"))
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append(doc)

	var sorted_cats: Array = by_category.keys()
	sorted_cats.sort()

	var nodes: Array = []
	for cat: String in sorted_cats:
		var cat_docs: Array = by_category[cat]
		cat_docs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var da: String = str(a.get("display_name", a.get("original_filename", "")))
			var db: String = str(b.get("display_name", b.get("original_filename", "")))
			return da < db
		)
		var children: Array = []
		for doc: Dictionary in cat_docs:
			var doc_id: int = int(doc.get("doc_id", 0))
			var display: String = str(doc.get("display_name", doc.get("original_filename", "unknown")))
			var sender: String = str(doc.get("sender", ""))
			var desc: String = str(doc.get("description", ""))
			var is_encrypted: bool = bool(doc.get("encrypted", false))
			children.append({
				"kind":       "file",
				"name":       display,
				"key":        "doc:%d" % doc_id,
				"date":       str(doc.get("doc_date", "")),
				"tooltip":    "%s\nSender: %s\n%s%s" % [
					display, sender, desc,
					"\n[encrypted]" if is_encrypted else "",
				],
				"children":   [],
				"node_role":  "document",
				"vault_path": _building_vault_path,
				"encrypted":  is_encrypted,
			})
		nodes.append({
			"kind":     "folder",
			"name":     "%s/ (%d)" % [cat, cat_docs.size()],
			"key":      "cat:%s" % cat,
			"date":     "",
			"tooltip":  "",
			"children": children,
		})
	return nodes


func _get_directory_children_by_path(dir_path: String, _dest_id: String) -> Array:
	if dir_path.is_empty():
		return []

	var args: Dictionary = {"disk_root": dir_path}

	var result: Dictionary = await _conn.call_tool(
		"minerva_scansort_list_disk_files",
		args,
	)
	if not result.get("ok", false):
		push_warning("[AreaProvider] dir list_disk_files failed: %s" % result.get("error", "unknown"))
		return []

	var files: Array = result.get("files", [])
	var by_dir: Dictionary = {}
	for f: Dictionary in files:
		var rel: String = str(f.get("rel_path", ""))
		var top: String
		var slash_pos: int = rel.find("/")
		if slash_pos < 0:
			top = "(root)"
		else:
			top = rel.substr(0, slash_pos)
		if not by_dir.has(top):
			by_dir[top] = []
		by_dir[top].append(f)

	var sorted_dirs: Array = by_dir.keys()
	sorted_dirs.sort()

	var nodes: Array = []
	for dir_name: String in sorted_dirs:
		var dir_files: Array = by_dir[dir_name]
		dir_files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return str(a.get("rel_path", "")) < str(b.get("rel_path", ""))
		)
		var children: Array = []
		for f: Dictionary in dir_files:
			var fpath: String = str(f.get("path", ""))
			var fname: String = str(f.get("name", fpath.get_file()))
			var rel: String   = str(f.get("rel_path", fname))
			var size: int     = int(f.get("size", 0))
			children.append({
				"kind":      "file",
				"name":      fname,
				"key":       fpath,
				"date":      "",
				"tooltip":   "%s\nSize: %d bytes" % [rel, size],
				"children":  [],
				"node_role": "document",
			})
		nodes.append({
			"kind":     "folder",
			"name":     "%s/ (%d)" % [dir_name, dir_files.size()],
			"key":      "dir:%s" % dir_name,
			"date":     "",
			"tooltip":  "",
			"children": children,
		})
	return nodes
