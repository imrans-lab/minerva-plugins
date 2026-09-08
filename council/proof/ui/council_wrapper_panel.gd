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
## Authority. There is exactly one engine and it lives in the backend. The
## dictionary in `_snapshot` is the acknowledged record the wrapper persists and
## re-serves: it is what `_on_panel_save_request` returns and what
## `_on_panel_load_request` replaces. The wrapper never edits a record, never
## mints a revision, and never decides a status — it relays a request to the
## engine and persists whatever comes back. The page holds a view and nothing
## else. This proof has no backend attached, so it serves reads from the record
## it holds and refuses every command by saying who owns it.

const CouncilBridge := preload("council_bridge.gd")

## Ceiling on one page message, in UTF-16 code units — the unit `String.length()`
## returns, which is also the unit the host's own broker measures (its constant
## is named MAX_PAYLOAD_BYTES but counts code units). Half the host's 64 KiB cap,
## so a message stays valid under either reading if it ever has to travel the
## brokered path.
const MAX_MESSAGE_CODE_UNITS := 32768

var _ctx: Dictionary = {}
var _cef: Control = null
var _fallback: Label = null
var _page_path: String = ""

## The acknowledged record this panel persists and re-serves. Shape:
## schemas/project_snapshot.schema.json. It is only ever replaced wholesale —
## by a load, or by the snapshot the engine returns.
var _snapshot: Dictionary = _empty_snapshot()

## The host wires this to the tab's dirty flag. The real plugin emits it when the
## engine hands back a snapshot that differs from the persisted one; this proof
## has no engine, so nothing here ever makes the tab dirty.
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


## Opening a bound file and restoring a project both land here.
##
## The file-open path does not hand over the document alone: it builds
## {"file_path": path} and merges the parsed JSON into it, or sets "raw_text"
## when the file is not JSON. Those two keys are the host's, not the record's,
## so they are stripped before the payload is treated as a snapshot. An empty,
## non-JSON or unrecognised document opens an empty council rather than a broken
## one — the same guard the restore-from-note hook applies.
##
## Demotion of interrupted runs is NOT done here. The engine owns that, and it
## bumps the revision when it rewrites a record; a wrapper that also demoted
## would be a second engine disagreeing with the first.
func _on_panel_load_request(document) -> void:
	_snapshot = _snapshot_from_document(document)
	_push_event("council.snapshot_changed", {})


## Extracts a Council record from whatever the host handed over, or returns an
## empty one. Never returns a partially-recognised record.
func _snapshot_from_document(document) -> Dictionary:
	if not (document is Dictionary):
		return _empty_snapshot()
	var candidate: Dictionary = (document as Dictionary).duplicate(true)
	candidate.erase("file_path")
	candidate.erase("raw_text")
	if not _is_council_snapshot(candidate):
		return _empty_snapshot()
	return candidate


func _is_council_snapshot(candidate: Dictionary) -> bool:
	if str(candidate.get("record_kind", "")) != "council_project_snapshot":
		return false
	return int(candidate.get("schema_version", 0)) == 1


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
	if not _is_council_snapshot(payload):
		return false
	_snapshot = payload.duplicate(true)
	_push_event("council.snapshot_changed", {})
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

## One request envelope from the page.
##
## The wrapper validates the envelope's shape and answers reads from the record
## it holds. It does not apply commands: the engine does, and this proof has no
## engine attached. A malformed or oversized message still gets a reply whenever
## a request_id can be recovered, because a page whose Promise never settles
## looks identical to a hung panel.
func _on_page_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var request: Dictionary = parsed
	if str(request.get("envelope", "")) != "request":
		return
	var request_id := str(request.get("request_id", ""))
	if request_id == "":
		return

	var revision := int(_snapshot.get("snapshot_revision", 1))
	if raw.length() > MAX_MESSAGE_CODE_UNITS:
		_send(_err(request_id, revision, "payload_too_large",
			"That request is %d code units, over the %d the panel accepts in one message."
				% [raw.length(), MAX_MESSAGE_CODE_UNITS], false))
		return
	if not (request.get("payload", {}) is Dictionary):
		_send(_err(request_id, revision, "internal", "A request payload must be an object.", false))
		return

	_send(_reply_to(request, request_id, revision))


func _reply_to(request: Dictionary, request_id: String, revision: int) -> Dictionary:
	var command := str(request.get("command", ""))
	if command == "snapshot.get":
		return _ok(request_id, revision, {"snapshot": _snapshot.duplicate(true)})
	if not request.has("base_revision"):
		return _err(request_id, revision, "internal",
			"Command '%s' changes the council and must say which revision it was written against." % command,
			false)
	return _err(request_id, revision, "internal",
		"The Council engine applies '%s'. This wrapper proof has no backend attached; it renders the panel and persists what the engine returns." % command,
		false)


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
