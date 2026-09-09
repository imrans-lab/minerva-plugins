extends RefCounted
## Imported bytes are dependencies of the painted model, independent of source edits.
var _owner: WeakRef
var _snapshot: Dictionary = {}
var _watched: Dictionary = {}
var changed_paths: Array[String] = []
var _buffer: WeakRef

func _init(panel: Node) -> void:
	_owner = weakref(panel)

## Save As rebinds the same canonical buffer; it does not emit attach_buffer.
func bind_buffer(buffer: Object) -> void:
	var old: Object = _buffer.get_ref() if _buffer != null else null
	if old != null and old.saved.is_connected(_saved):
		old.saved.disconnect(_saved)
	_buffer = weakref(buffer) if buffer != null else null
	if buffer != null:
		buffer.saved.connect(_saved)

func _saved() -> void:
	var panel: Node = _owner.get_ref()
	var buffer: Object = _buffer.get_ref() if _buffer != null else null
	if panel == null or buffer == null:
		return
	var path := str(buffer.get("file_path"))
	if path == panel._document_path:
		return
	panel._cancel_inflight_eval_if_any()
	panel._document_path = path
	panel._buffer_path = path
	panel._open_eval_path = ""
	if panel._annotation_host != null:
		panel._annotation_host.set_document_source(path, panel._current_source())
	panel._start_eval_debounce()
	panel._build.refresh()

func path_changed() -> bool:
	var panel: Node = _owner.get_ref()
	var completed: Dictionary = panel._evaluation_state.completed
	return not completed.is_empty() and str(completed.get("path", "")) != panel._document_path

func accept() -> void:
	var panel: Node = _owner.get_ref()
	_snapshot = {}
	var wanted: Dictionary = {}
	for record: Dictionary in panel.get_reference_status():
		var path := str(record.get("resolved_path", ""))
		if path.is_empty():
			continue
		_snapshot[path] = str(record.get("stamp", ""))
		for dependency: String in panel._reference_library.dependency_paths(path):
			wanted[dependency] = true
	var document_path: String = str(panel.get_evaluation_state().get("path", ""))
	var sidecar := document_path + preload("package_files.gd").SUFFIX
	if not document_path.is_empty() and FileAccess.file_exists(sidecar):
		_snapshot[sidecar] = panel._reference_library.file_stamp(sidecar)
		wanted[sidecar] = true
	changed_paths.clear()
	for path: String in _watched:
		if not wanted.has(path):
			_watch("host.fs.unwatch", path)
	for path: String in wanted:
		if not _watched.has(path):
			_watch("host.fs.watch", path)
	_watched = wanted

func _watch(channel: String, path: String) -> void:
	var panel: Node = _owner.get_ref()
	if panel.get_node_or_null("_MinervaIPC") == null:
		return
	var reply: Dictionary = await panel.call_backend(channel, {"path": path, "deletions": true}, 5000)
	if not bool(reply.get("success", false)):
		push_warning("CAD dependency watch unavailable for %s: %s" % [path, str(reply)])

func changed(payload: Dictionary) -> void:
	if _watched.has(str(payload.get("path", ""))):
		verify()

func verify() -> void:
	if _snapshot.is_empty():
		return
	var panel: Node = _owner.get_ref()
	# Strong verification belongs at a measurement/export boundary, not every
	# frame or evaluation poll. It catches same-size/same-mtime replacements.
	panel._reference_library.refresh_stamps()
	var changed: Array[String] = []
	for path: String in _snapshot:
		if panel._reference_library.file_stamp(path) != str(_snapshot[path]):
			changed.append(path)
	changed.sort()
	var newly_changed := changed != changed_paths
	changed_paths = changed
	if newly_changed:
		panel._build.refresh()
		if not changed_paths.is_empty():
			panel._start_eval_debounce()

func is_stale() -> bool:
	return not changed_paths.is_empty() or path_changed()

func snapshot() -> Dictionary:
	return _snapshot.duplicate()
