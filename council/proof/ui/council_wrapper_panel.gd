extends Control

## Council's native wrapper: a godot_scene plugin panel that renders an HTML
## surface inside a CefTexture it owns.
##
## Why this shape exists. An html-kind plugin panel becomes an Editor of
## Type.WEBVIEW, and every host persistence hook is gated on Type.PLUGIN_SCENE
## with a non-null plugin_scene_root, so an html panel gets no save, no project
## round-trip, no plugin note and no restore — its "save" writes the page source
## to a .html file. A godot_scene panel gets all of those hooks, and CefTexture
## is a plain ClassDB class, so a scene panel can host the same HTML surface
## while keeping the native lifecycle. This wrapper is that proof.
##
## Authority. The dictionary in `_snapshot` is the panel's copy of the
## project-owned record. It is what `_on_panel_save_request` returns and what
## `_on_panel_load_request` replaces. The page holds a view of it and nothing
## else; every page mutation is a request that this wrapper accepts or refuses,
## and the page is told the revision it was answered against.

const CouncilBridge := preload("council_bridge.gd")

## Half the host's 64 KiB pluginIPC cap. Council's own page IPC is not brokered,
## but the wrapper holds itself to the same budget so the protocol stays valid
## if a message ever has to travel the brokered path.
const MAX_MESSAGE_BYTES := 32768

var _ctx: Dictionary = {}
var _cef: Control = null
var _fallback: Label = null
var _page_path: String = ""

## The authoritative panel record. Shape: schemas/project_snapshot.schema.json.
var _snapshot: Dictionary = _empty_snapshot()

## request_id -> reply, so a repeated request returns the first answer instead
## of applying twice.
var _replies: Dictionary = {}

signal content_changed()

## The scene-panel broker routes this to the declared backend channel and calls
## back through `receive`. The proof declares no channels, so nothing is emitted
## here yet; the signal exists so the backend hop needs no reshaping later.
signal request(channel: String, payload: Dictionary, reply_id: String)


func _empty_snapshot() -> Dictionary:
	return {
		"schema_version": 1,
		"record_kind": "council_project_snapshot",
		"snapshot_revision": 1,
		"definitions": [],
		"sessions": [],
	}


# ---------------------------------------------------------------------------
# Panel lifecycle
# ---------------------------------------------------------------------------

## Mounts the HTML surface. When godot-cef is missing the panel says so in
## words the user can act on rather than rendering an empty rectangle.
func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	if not ClassDB.class_exists("CefTexture"):
		_show_unavailable(
			"Council needs the embedded browser (godot-cef), which this Minerva build does not provide. "
			+ "The council data in this project is intact and will render when Council is opened on a build that has it."
		)
		return
	_mount_page()


func _on_panel_unload() -> void:
	if _cef != null and _cef.has_signal("ipc_message") and _cef.ipc_message.is_connected(_on_page_message):
		_cef.ipc_message.disconnect(_on_page_message)
	_cef = null
	if _page_path != "" and FileAccess.file_exists(_page_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_page_path))
	_page_path = ""


## Ctrl+S under save_mode host_owned, and the project serialize path, both take
## this dictionary verbatim.
func _on_panel_save_request() -> Dictionary:
	return _snapshot.duplicate(true)


## Opening a bound file and restoring a project both land here. A run that was
## in flight when the record was written is never resumed: it is demoted to a
## visible failure with a retry, so reopening cannot spend tokens.
func _on_panel_load_request(document) -> void:
	if not (document is Dictionary):
		return
	_snapshot = (document as Dictionary).duplicate(true)
	var interrupted := _demote_interrupted_runs()
	_push_event("council.snapshot_changed", {"interrupted_runs": interrupted})


## Building a note from the panel. The plugin_data kind is what allows the note
## to reopen this panel later; the caption is the only text the note carries
## into a chat turn, so it names the question rather than describing the widget.
func _on_panel_create_note_request(ctx: Dictionary) -> Dictionary:
	var caption := _caption_for_llm()
	return {
		"kind": "plugin_data",
		"plugin_id": str(ctx.get("plugin_id", "")),
		"panel_name": str(ctx.get("panel_name", "")),
		"payload": _snapshot.duplicate(true),
		"preview_alt_text": caption,
	}


## The inverse of the note hook. An unrecognised payload returns false so the
## host can tell the user rather than opening a blank council.
func _on_panel_restore_from_note(payload: Dictionary) -> bool:
	if str(payload.get("record_kind", "")) != "council_project_snapshot":
		return false
	if int(payload.get("schema_version", 0)) != 1:
		return false
	_on_panel_load_request(payload)
	return true


## Implemented against the documented contract even though the host has no
## production caller for it yet; when one appears Council needs no change.
func _on_panel_render_for_llm(_ctx: Dictionary) -> Array:
	return [{"type": "text", "text": _caption_for_llm()}]


## Backend push. The channel is the raw event name for an event and the literal
## "state" for a state snapshot. Council forwards both to the page as events; the
## page re-reads rather than trusting the payload.
func receive(channel: String, payload: Dictionary) -> void:
	if channel == "state":
		_push_event("council.snapshot_changed", {})
		return
	_push_event(channel, payload)


# ---------------------------------------------------------------------------
# HTML surface
# ---------------------------------------------------------------------------

func _mount_page() -> void:
	var data_dir := str(_ctx.get("data_directory", ""))
	var entry := data_dir.path_join("ui/proof.html")
	if not FileAccess.file_exists(entry):
		_show_unavailable("Council's panel page is missing from the install at %s." % entry)
		return
	var source := FileAccess.get_file_as_string(entry)

	# CefTexture loads URLs, not inline HTML, so the bridge-injected page is
	# materialised to disk and handed over as a file:// URL.
	_page_path = "user://council_panel_%d.html" % get_instance_id()
	var f := FileAccess.open(_page_path, FileAccess.WRITE)
	if f == null:
		_show_unavailable("Council could not stage its panel page for display.")
		return
	f.store_string(CouncilBridge.inject(source))
	f.close()

	var cef: Control = ClassDB.instantiate("CefTexture") as Control
	if cef == null:
		_show_unavailable("Council could not create the embedded browser view.")
		return
	if cef.has_method("set_enable_accelerated_osr"):
		cef.set("enable_accelerated_osr", false)

	# CefTexture's node-level input hook consumes every event in the viewport it
	# sits in. A SubViewport scopes that to this panel, so the rest of Minerva
	# keeps its menus and tabs.
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	svc.mouse_filter = Control.MOUSE_FILTER_STOP

	var sv := SubViewport.new()
	sv.handle_input_locally = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = true
	svc.add_child(sv)
	sv.add_child(cef)
	cef.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(svc)

	if cef.has_signal("ipc_message"):
		cef.ipc_message.connect(_on_page_message)
	_cef = cef
	cef.set("url", "file://" + ProjectSettings.globalize_path(_page_path))


func _show_unavailable(message: String) -> void:
	if _fallback == null:
		_fallback = Label.new()
		_fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(_fallback)
	_fallback.text = message


# ---------------------------------------------------------------------------
# Page protocol
# ---------------------------------------------------------------------------

## One request envelope from the page. Every mutating command is checked against
## base_revision and deduplicated on request_id before anything is applied.
func _on_page_message(raw: String) -> void:
	if raw.length() > MAX_MESSAGE_BYTES:
		return
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var request: Dictionary = parsed
	if str(request.get("envelope", "")) != "request":
		return
	var request_id := str(request.get("request_id", ""))
	if request_id == "":
		return
	if _replies.has(request_id):
		var stored: Dictionary = (_replies[request_id] as Dictionary).duplicate(true)
		stored["replayed"] = true
		_send(stored)
		return

	var reply := _apply(request)
	_replies[request_id] = reply.duplicate(true)
	_send(reply)


func _apply(request: Dictionary) -> Dictionary:
	var request_id := str(request.get("request_id", ""))
	var command := str(request.get("command", ""))
	var revision := int(_snapshot.get("snapshot_revision", 1))

	if command == "snapshot.get":
		return _ok(request_id, revision, {"snapshot": _snapshot.duplicate(true)})

	if not request.has("base_revision"):
		return _err(request_id, revision, "internal",
			"Command '%s' changes the council and must say which revision it was written against." % command, false)
	if int(request.get("base_revision", 0)) != revision:
		return _err(request_id, revision, "stale_revision",
			"This view is behind the saved council. Reload it and try again.", true)

	# The proof mutates one field so that save, reload and revision checking are
	# all exercised end to end; the real command set lands with the engine.
	if command == "definition.upsert":
		var incoming: Variant = request.get("payload", {}).get("definition", null)
		if not (incoming is Dictionary):
			return _err(request_id, revision, "internal", "No definition in the request.", false)
		_upsert_definition(incoming as Dictionary)
		revision += 1
		_snapshot["snapshot_revision"] = revision
		content_changed.emit()
		_push_event("council.snapshot_changed", {})
		return _ok(request_id, revision, {})

	return _err(request_id, revision, "internal", "Council does not know the command '%s'." % command, false)


func _upsert_definition(definition: Dictionary) -> void:
	var definitions: Array = _snapshot.get("definitions", [])
	var id := str(definition.get("definition_id", ""))
	for i in definitions.size():
		if str((definitions[i] as Dictionary).get("definition_id", "")) == id:
			definitions[i] = definition
			return
	definitions.append(definition)
	_snapshot["definitions"] = definitions


func _ok(request_id: String, revision: int, payload: Dictionary) -> Dictionary:
	return {
		"schema_version": 1, "envelope": "reply", "request_id": request_id,
		"ok": true, "snapshot_revision": revision, "payload": payload,
	}


func _err(request_id: String, revision: int, code: String, message: String, retryable: bool) -> Dictionary:
	return {
		"schema_version": 1, "envelope": "reply", "request_id": request_id,
		"ok": false, "snapshot_revision": revision,
		"error": {"code": code, "message": message, "retryable": retryable},
	}


func _push_event(name: String, payload: Dictionary) -> void:
	_send({
		"schema_version": 1, "envelope": "event", "event": name,
		"snapshot_revision": int(_snapshot.get("snapshot_revision", 1)),
		"payload": payload,
	})


## eval() must be deferred: evaluating JavaScript from inside the browser's own
## IPC callback re-enters the view while it is still borrowed.
func _send(envelope: Dictionary) -> void:
	if _cef == null:
		return
	_cef.call_deferred("eval", "window.council._deliver(%s);" % JSON.stringify(envelope))


# ---------------------------------------------------------------------------
# Record helpers
# ---------------------------------------------------------------------------

## Mirrors contract.RehydrateOnLoad: a run left mid-flight becomes a visible,
## retryable failure instead of silently continuing.
func _demote_interrupted_runs() -> int:
	var demoted := 0
	for session_variant in _snapshot.get("sessions", []):
		var session: Dictionary = session_variant
		for run_variant in session.get("runs", []):
			var run: Dictionary = run_variant
			var status := str(run.get("status", ""))
			if status != "pending" and status != "running":
				continue
			for contribution_variant in run.get("contributions", []):
				var contribution: Dictionary = contribution_variant
				var c_status := str(contribution.get("status", ""))
				if c_status == "pending" or c_status == "running":
					contribution["status"] = "failed"
					contribution["failure"] = _interrupted()
			run["status"] = "failed"
			run["failure"] = _interrupted()
			demoted += 1
		# The status describes the session, not the runs: a session whose runs
		# are all already terminal is still not running.
		if str(session.get("status", "")) == "running":
			session["status"] = "partial"
	return demoted


func _interrupted() -> Dictionary:
	return {
		"code": "interrupted",
		"message": "The run was in flight when the session was last closed. It was not resumed; start it again to retry.",
		"retryable": true,
	}


## The one line of text a note carries into a chat turn.
func _caption_for_llm() -> String:
	var sessions: Array = _snapshot.get("sessions", [])
	if sessions.is_empty():
		return "Council: no session yet."
	var session: Dictionary = sessions[sessions.size() - 1]
	return "Council session on: %s (%s)" % [
		str(session.get("question", "(no question)")),
		str(session.get("status", "unknown")),
	]
