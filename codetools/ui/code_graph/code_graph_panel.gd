extends MinervaPluginPanel
## Code-graph visualizer panel controller.
##
## Off-tree plugin script: NO class_name; no res://addons references.
##
## On load: resolves a db_path from ctx, requests the code graph via
## minerva_codetools_get_graph, unwraps the double-wrapped reply, and
## feeds artifacts[0] to the child CodeGraphView via load_from_dict().
##
## Double-wrap unwinding matches the pattern in
## test_marketplace_install_start_codetools.gd _unwrap_envelope:
##   broker {success:true, result: worker {ok:true, result: envelope}}
##   where envelope has {status, artifacts, ...}
##
## db_path resolution (in priority order):
##   1. ctx.file_path if it ends with ".db"
##   2. ProjectSettings.globalize_path(ctx.data_directory) + "/code_visualizer.db"

@onready var _view: Control = $CodeGraphView

var _reply_counter: int = 0
var _status_label: Label = null


func _ready() -> void:
	# Wrap the view in a vbox with a status label on top (load / error state).
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Status label first → it lands at index 0 (above the view).
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status_label)
	# Reparent the existing view into the vbox, below the label.
	if _view != null and is_instance_valid(_view):
		remove_child(_view)
		vbox.add_child(_view)
		_view.size_flags_horizontal = SIZE_EXPAND_FILL
		_view.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(vbox)


# ── Plugin lifecycle ──────────────────────────────────────────────────────────

func _on_panel_loaded(ctx: Dictionary) -> void:
	_set_status("Loading code graph…")
	var db_path := _resolve_db_path(ctx)
	if not has_node("_MinervaIPC"):
		_set_status("Backend bridge unavailable — cannot load graph.")
		return
	_reply_counter += 1
	var reply_id := "codetools_get_graph_%d" % _reply_counter
	request.emit("minerva_codetools_get_graph", {"db_path": db_path}, reply_id)
	var raw: Dictionary = await $_MinervaIPC.await_reply(reply_id)
	_handle_reply(raw)


# ── Reply handling ────────────────────────────────────────────────────────────

func _handle_reply(raw: Dictionary) -> void:
	# Unwrap broker layer: {success: true, result: <worker-reply>}
	# A broker failure reply carries error_message/error_code (see MinervaIPC).
	if not bool(raw.get("success", false)):
		var err_msg: String = str(raw.get("error_message",
			raw.get("error_code", raw.get("result", "unknown error"))))
		_set_status("Graph request failed: %s" % err_msg)
		return
	var worker_reply: Variant = raw.get("result", {})
	# Unwrap worker layer: {ok: true, result: <envelope>}
	var envelope: Dictionary = _unwrap_envelope(worker_reply if worker_reply is Dictionary else {})
	if envelope.is_empty():
		_set_status("Graph response missing envelope.")
		return
	var status_val: String = str(envelope.get("status", ""))
	if status_val != "ok":
		var detail: String = str(envelope.get("error", envelope.get("summary", "status=%s" % status_val)))
		_set_status("Graph unavailable: %s" % detail)
		return
	var artifacts_raw: Variant = envelope.get("artifacts", [])
	if not (artifacts_raw is Array) or (artifacts_raw as Array).is_empty():
		_set_status("No graph artifacts in response.")
		return
	var artifact: Variant = (artifacts_raw as Array)[0]
	if not (artifact is Dictionary):
		_set_status("Artifact is not a dictionary.")
		return
	if _view == null or not is_instance_valid(_view):
		_set_status("Graph view node unavailable.")
		return
	_set_status("")
	_view.load_from_dict(artifact as Dictionary)


## Recursively unwrap the result layers to find the envelope dict that carries
## "status" and "artifacts". Mirrors _unwrap_envelope in the Gate-A test.
func _unwrap_envelope(d: Dictionary) -> Dictionary:
	if d.has("status") and d.has("artifacts"):
		return d
	if d.has("result") and d["result"] is Dictionary:
		return _unwrap_envelope(d["result"] as Dictionary)
	return {}


# ── Helpers ───────────────────────────────────────────────────────────────────

## Resolve the SQLite db path to query.
## Priority:
##   1. ctx.file_path if it ends with ".db"
##   2. data_directory + "/code_visualizer.db"
func _resolve_db_path(ctx: Dictionary) -> String:
	var file_path: String = str(ctx.get("file_path", "")).strip_edges()
	if not file_path.is_empty() and file_path.ends_with(".db"):
		return file_path
	var data_dir: String = str(ctx.get("data_directory", "")).strip_edges()
	if not data_dir.is_empty():
		var abs_dir: String = ProjectSettings.globalize_path(data_dir)
		return abs_dir.path_join("code_visualizer.db")
	return ""


func _set_status(msg: String) -> void:
	if _status_label != null and is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.visible = not msg.is_empty()
