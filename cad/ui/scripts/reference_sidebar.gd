extends VBoxContainer
## The wide sidebar's reference inspector: every mounted reference and its
## nodes, and the name and world bounds of whichever one is selected.
##
## The mesh() lines in a document are the only thing in the CAD panel the user
## cannot see the shape of from the source — a reference is a file name and a
## pose, and its nodes exist only inside the file. This list is where they
## become visible and clickable.
##
## Scene-declared: the Tree and the two Labels are children in CADPanel.tscn.
## The script only fills them in, so there is no dynamically built UI to debug.

## Emitted when the user picks a node row. CADPanel's reference_selection
## module selects it, exactly as a click in a viewport would.
signal node_activated(reference: String, node_name: String)

const NOTHING_SELECTED: String = "No reference node selected. Click one in a view, or a row above."

@onready var _tree: Tree = $ReferenceTree as Tree
@onready var _detail: Label = $ReferenceDetail as Label

## reference|node -> TreeItem, so a selection made elsewhere (a viewport click
## or the MCP verb) can highlight the same row.
var _rows: Dictionary = {}

## True while the script is syncing the Tree to an external selection, so the
## resulting item_selected does not bounce back out as a user action.
var _syncing: bool = false


func _ready() -> void:
	if _tree != null:
		_tree.set_column_title(0, "reference / node")
		_tree.set_column_title(1, "size mm")
		_tree.set_column_titles_visible(true)
		_tree.item_selected.connect(_on_item_selected)
	if _detail != null:
		_detail.text = NOTHING_SELECTED
	set_entries([])


## Rebuild the list from reference_selection.node_entries(): one parent row per
## reference, one child row per node inside it.
func set_entries(entries: Array) -> void:
	if _tree == null:
		return
	_syncing = true
	_tree.clear()
	_rows.clear()
	var root := _tree.create_item()
	if entries.is_empty():
		var empty := _tree.create_item(root)
		empty.set_text(0, "(no references)")
		empty.set_selectable(0, false)
		_syncing = false
		return
	var parents := {}
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var row: Dictionary = entry
		var reference := str(row.get("reference", ""))
		if not parents.has(reference):
			var parent_item := _tree.create_item(root)
			parent_item.set_text(0, reference if not reference.is_empty() else "(unnamed)")
			parent_item.set_selectable(0, false)
			parents[reference] = parent_item
		var node_name := str(row.get("node", ""))
		var world_box: AABB = row.get("world_aabb", AABB())
		var item := _tree.create_item(parents[reference])
		item.set_text(0, node_name)
		item.set_text(1, _size_text(world_box))
		item.set_metadata(0, {"reference": reference, "node": node_name})
		_rows[_key(reference, node_name)] = item
	_syncing = false


## Show a selection made anywhere — a viewport click, a row, or the MCP verb.
func set_selection(selection: Dictionary) -> void:
	if _detail == null:
		return
	if selection.is_empty():
		_detail.text = NOTHING_SELECTED
		if _tree != null:
			_syncing = true
			_tree.deselect_all()
			_syncing = false
		return
	var reference := str(selection.get("reference", ""))
	var node_name := str(selection.get("node", ""))
	var world_box: AABB = selection.get("world_aabb", AABB())
	var point: Vector3 = selection.get("world", Vector3.ZERO)
	var lines: Array = [
		"%s / %s%s" % [reference, node_name, " (gone)" if bool(selection.get("stale", false)) else ""],
		"size %s mm" % _size_text(world_box),
		"world %s .. %s" % [_point_text(world_box.position), _point_text(world_box.end)],
		"point %s mm" % _point_text(point),
	]
	_detail.text = "\n".join(lines)
	var item: Variant = _rows.get(_key(reference, node_name), null)
	if item != null and _tree != null:
		_syncing = true
		_tree.deselect_all()
		(item as TreeItem).select(0)
		_syncing = false


func _on_item_selected() -> void:
	if _syncing or _tree == null:
		return
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary):
		return
	var row: Dictionary = meta
	node_activated.emit(str(row.get("reference", "")), str(row.get("node", "")))


func _size_text(box: AABB) -> String:
	return "%.1f x %.1f x %.1f" % [box.size.x, box.size.y, box.size.z]


func _point_text(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]


func _key(reference: String, node_name: String) -> String:
	return "%s|%s" % [reference, node_name]
