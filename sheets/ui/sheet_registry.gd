class_name Sheets_SheetRegistry
extends RefCounted
## Live sheet lookup stays inside the plugin. Panels supply their current title
## and data so tab renames and model replacement do not leave stale entries.

class Entry:
	extends RefCounted
	var owner: WeakRef
	var title: Callable
	var data: Callable

static var _entries: Array[Entry] = []

static func register(owner: Node, title: Callable, data: Callable) -> void:
	unregister(owner)
	var entry := Entry.new()
	entry.owner = weakref(owner)
	entry.title = title
	entry.data = data
	_entries.append(entry)

static func unregister(owner: Node) -> void:
	for index: int in range(_entries.size() - 1, -1, -1):
		var current: Object = _entries[index].owner.get_ref()
		if current == null or current == owner:
			_entries.remove_at(index)

static func resolve(title: String) -> RefCounted:
	var result: RefCounted = null
	var matches := 0
	for entry: Entry in _entries:
		if entry.owner.get_ref() != null and entry.title.is_valid() and entry.data.is_valid():
			if str(entry.title.call()) == title:
				matches += 1
				if matches > 1:
					return null # Ambiguous titles use the formula engine's visible reference error.
				result = entry.data.call()
	return result
