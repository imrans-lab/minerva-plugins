extends Control

## Council's native panel: a godot_scene plugin panel that renders Council's
## HTML surface in a CefTexture it owns.
##
## WHY THIS SHAPE. An `html`-kind plugin panel becomes an Editor of
## Type.WEBVIEW, and every host persistence hook is gated on Type.PLUGIN_SCENE
## with a non-null plugin_scene_root — such a panel's Ctrl+S writes the page
## markup and its note captures the page. A godot_scene panel gets the whole
## native lifecycle, and CefTexture is an ordinary ClassDB class, so a scene
## panel can host the same HTML surface and keep save, load, notes, restore and
## the project round-trip. architecture.md §1 has the citations.
##
## AUTHORITY. There is one engine and it lives in the backend. This panel is the
## durable owner of the record and a relay: it persists the snapshot the engine
## returns, answers reads from what it holds, and never edits a record, derives a
## status or mints a revision. The page is a view — it holds nothing that is not
## in the record or in flight, and a page reload loses nothing.
##
## The three things the panel must copy from the host's own CEF editor, each a
## defect if skipped: CefTexture lives in a SubViewport (its node-level input
## hook otherwise eats every event in the main viewport), eval() is deferred
## (evaluating JS from inside the browser's IPC callback re-enters a borrowed
## view), and the page is materialised to a file (CefTexture loads URLs, not
## markup).

const CouncilBridge := preload("council_bridge.gd")
const CouncilRecord := preload("council_record.gd")
const CouncilBackend := preload("council_backend.gd")

## Ceiling on one REQUEST from the page, in UTF-16 code units. Half the host's
## IPC cap, so a request that reaches the ceiling still fits inside the envelope
## that carries it onward to the backend (architecture.md §6). It deliberately
## does not apply outbound: a snapshot.get reply carries the whole record, which
## is bounded by the host hop rather than by this, and refusing to answer a read
## the wrapper can serve from memory would help nobody.
const MAX_MESSAGE_CODE_UNITS := 32768

## Commands this wrapper answers itself. Everything else is the engine's and is
## relayed unchanged; `snapshot.get` is answered here because the record the
## wrapper holds IS the durable one, and a council must still be readable when
## the backend is stopped.
const WRAPPER_PREFIX := "wrapper."
const READ_LOCALLY := "snapshot.get"

## The characters an Id may contain after its first (common.schema.json).
const ID_SAFE_CHARACTERS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"

@onready var _surface: SubViewportContainer = $Surface
@onready var _browser: SubViewport = $Surface/Browser
@onready var _notice: Label = $Notice

var _ctx: Dictionary = {}
var _record: CouncilRecord = CouncilRecord.new()
var _backend: CouncilBackend = null
var _cef: Control = null
var _page_path: String = ""

## Outbound envelopes wait here until the page says its bridge is up. Without
## the gate an event pushed during mounting is evaluated into a document that
## does not have `window.council` yet and is simply lost.
var _page_ready: bool = false
var _outbox: Array[Dictionary] = []

## Counter behind the request ids the wrapper mints for itself. Paired with the
## panel key, the way the page bridge pairs its own counter with a timestamp: a
## clock reading alone collides between two panels started in the same
## millisecond, and two panels sharing a request id share an idempotency ledger
## entry — the second one would be answered with the first one's reply.
var _request_seq: int = 0

## Bumped every time the panel adopts a different document. An exchange captures
## it before its await and refuses to apply its result if it has moved: the
## answer belongs to a document this panel no longer has open.
var _document_epoch: int = 0

## The host wires this to the tab's dirty flag (Editor.gd's PLUGIN_SCENE branch
## sets _plugin_scene_modified). It is emitted when — and only when — the record
## this panel holds has actually changed.
signal content_changed()

## Routed by PluginScenePanelBroker to the declared channel, with the reply
## delivered through the $_MinervaIPC helper it attaches.
signal request(channel: String, payload: Dictionary, reply_id: String)


# ---------------------------------------------------------------------------
# Panel lifecycle
# ---------------------------------------------------------------------------

## ctx shape: PluginScenePanelHost._build_ctx — plugin_id, panel_name,
## panel_key, data_directory, broker, file_path, associated_object, editor.
func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	_backend = CouncilBackend.new(self, str(ctx.get("panel_key", ctx.get("panel_name", ""))))
	_surface.focus_entered.connect(_on_surface_focus_changed.bind(true))
	_surface.focus_exited.connect(_on_surface_focus_changed.bind(false))
	if not ClassDB.class_exists("CefTexture"):
		_show_notice(
			"Council needs the embedded browser (godot-cef), which this Minerva build does not provide. "
			+ "The council data in this project is intact and will render when Council is opened on a build that has it.")
		return
	_mount_page()
	_refresh_notice()


func _on_panel_unload() -> void:
	if _cef != null and is_instance_valid(_cef) \
			and _cef.is_connected("ipc_message", _on_page_message):
		_cef.disconnect("ipc_message", _on_page_message)
	_cef = null
	_page_ready = false
	_outbox.clear()
	# The record this panel seeded the engine with leaves with the panel, and so
	# does the lease: a queued exchange must not wait on a tab that is gone.
	if _backend != null:
		_backend.release_on_unload()
	if _page_path != "" and FileAccess.file_exists(_page_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_page_path))
	_page_path = ""


## Ctrl+S under save_mode host_owned and the project serialize path both take
## this dictionary verbatim, so it has to be right for both (council_record.gd).
func _on_panel_save_request() -> Dictionary:
	return _record.save_payload()


## Opening a bound file and restoring a project both land here. An unreadable
## document is preserved rather than replaced, and the panel says so.
##
## Interrupted runs are NOT demoted here. That is the engine's rule and it costs
## a revision; a wrapper that also demoted would be a second engine free to
## disagree with the first. Seeding the engine is what applies it, and the
## rewritten record comes back through the same path everything else does.
func _on_panel_load_request(document) -> void:
	_adopting_new_document()
	_record.adopt_document(document)
	_refresh_notice()
	_push_event("council.snapshot_changed", {})
	if not _record.is_unreadable():
		_rehydrate.call_deferred()


## What both "the panel now holds a different document" paths have to do.
##
## The engine may still be holding the document this panel had a moment ago, so
## the seed is forgotten and the next exchange re-seeds. The epoch is what
## protects an exchange that is ALREADY in flight: the host's restore order fires
## the file load and its rehydrate first and the project restore a frame later,
## so a request is often mid-await when this runs, and the snapshot it eventually
## carries back belongs to the document that has just been replaced. Bumping the
## epoch makes that outcome discardable instead of letting it overwrite the
## freshly restored record.
##
## The lease itself is deliberately NOT released here — see forget_seed().
func _adopting_new_document() -> void:
	_document_epoch += 1
	if _backend != null:
		_backend.forget_seed()


## Seed the engine with the record just adopted, so its interruption rule runs
## and the demoted form is persisted. A `snapshot.get` is the cheapest command
## that reaches the engine; nothing here mutates.
func _rehydrate() -> void:
	if _backend == null:
		return
	await _relay_to_engine({
		"schema_version": 1, "envelope": "request",
		"request_id": _mint_request_id("rehydrate"),
		"command": "snapshot.get", "payload": {},
	})


## A request id of this panel's own, unique across panels and across restarts of
## the exchange. The panel key is in it because the id is an idempotency key in
## the backend's ledger: two panels sharing one would have the second answered
## with the first one's stored reply. The key is sanitised because the host mints
## it as "<panel>#<instance id>" (Editor.gd:289) and "#" is not in the Id pattern
## the schema accepts — an id the backend cannot read is a request it cannot
## answer at all.
func _mint_request_id(prefix: String) -> String:
	_request_seq += 1
	var key := ""
	for character in str(_ctx.get("panel_key", "panel")):
		key += character if ID_SAFE_CHARACTERS.contains(character) else "-"
	return "%s-%s-%d" % [prefix, key, _request_seq]


## The plugin_data kind is what lets the note reopen this panel. The caption is
## the only text the note carries into a chat turn (a plugin_data note is built
## with the image controls), so it names the session rather than the widget.
func _on_panel_create_note_request(ctx: Dictionary) -> Dictionary:
	return {
		"kind": "plugin_data",
		"plugin_id": str(ctx.get("plugin_id", _ctx.get("plugin_id", ""))),
		"panel_name": str(ctx.get("panel_name", _ctx.get("panel_name", ""))),
		"payload": _record.snapshot(),
		"preview_alt_text": _record.caption(),
	}


## The inverse of the note hook. Must NOT be a coroutine: the host does not
## await this one (Note.gd), so a coroutine would return a truthy state object
## and read as success.
func _on_panel_restore_from_note(payload: Dictionary) -> bool:
	if not _record.adopt(payload):
		return false
	_adopting_new_document()
	_refresh_notice()
	_push_event("council.snapshot_changed", {})
	_rehydrate.call_deferred()
	return true


## Implemented against the documented contract even though the host has no
## production caller for it yet; when one appears Council needs no change. Same
## derivation as the chat handoff, so the two can never disagree.
func _on_panel_render_for_llm(_ctx_unused: Dictionary) -> Array:
	var text := _record.context_text("", PackedStringArray())
	if text.is_empty():
		text = _record.caption()
	return [{"type": "text", "text": text}]


## Backend push. The channel is the raw event name, or the literal "state".
## Either way the page is told the record moved and re-reads; an event carries
## no authority.
func receive(channel: String, payload: Dictionary) -> void:
	if channel == "state":
		_push_event("council.snapshot_changed", {})
		return
	_push_event(channel, payload)


# ---------------------------------------------------------------------------
# The CEF surface
# ---------------------------------------------------------------------------

func _mount_page() -> void:
	var entry := str(_ctx.get("data_directory", "")).path_join("ui/panel.html")
	if not FileAccess.file_exists(entry):
		_show_notice("Council's panel page is missing from the install at %s." % entry)
		return

	# CefTexture loads URLs, not markup, so the bridge-injected page is staged on
	# disk and handed over as a file:// URL.
	_page_path = "user://council_panel_%d.html" % get_instance_id()
	var staged := FileAccess.open(_page_path, FileAccess.WRITE)
	if staged == null:
		_show_notice("Council could not stage its panel page for display.")
		return
	staged.store_string(CouncilBridge.inject(FileAccess.get_file_as_string(entry)))
	staged.close()

	var cef: Control = ClassDB.instantiate("CefTexture") as Control
	if cef == null:
		_show_notice("Council could not create the embedded browser view.")
		return
	# Accelerated OSR renders black on the Vulkan DMA-BUF path this stack uses;
	# the host force-disables it for the same reason.
	if cef.has_method("set_enable_accelerated_osr"):
		cef.set("enable_accelerated_osr", false)

	_browser.add_child(cef)
	cef.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cef.focus_mode = Control.FOCUS_ALL
	if cef.has_signal("ipc_message"):
		cef.connect("ipc_message", _on_page_message)
	_cef = cef
	_apply_oversampling()
	# The ratio changes with the surface, not just at mount: a resized pane, a
	# host UI-scale change (which reflows control sizes) or a move to another
	# display all land here. The host's own CEF editor hooks `resized` for
	# exactly this.
	if not resized.is_connected(_apply_oversampling):
		resized.connect(_apply_oversampling)
	cef.set("url", "file://" + ProjectSettings.globalize_path(_page_path))


## Render the page at physical pixel density. The SubViewport's target is sized
## in logical pixels, so without this the page renders small and is bitmap-
## upscaled by the host's UI zoom and the display's HiDPI backing.
func _apply_oversampling() -> void:
	var tree := get_tree()
	if tree == null or _browser == null:
		return
	var ui_scale: float = tree.root.content_scale_factor
	var screen: int = DisplayServer.window_get_current_screen()
	var display_scale := 1.0
	if OS.get_name() == "Windows":
		var dpi: int = DisplayServer.screen_get_dpi(screen)
		display_scale = maxf(1.0, float(dpi) / 96.0) if dpi > 0 else 1.0
	else:
		display_scale = DisplayServer.screen_get_scale(screen)
	if display_scale <= 0.0:
		display_scale = 1.0
	_browser.set_use_oversampling(true)
	_browser.set_oversampling_override(maxf(1.0, ui_scale * display_scale))


## Godot delivers this to every Control under a theme that changed, which is how
## the panel learns the user switched Minerva between light and dark without
## reaching for a host singleton.
func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _page_ready:
		_push_event("council.theme_changed", theme_description())


## The page's half of the host theme: whether the surface is dark, and the two
## colours Minerva is actually drawing text and panels with. Derived from this
## Control's own inherited theme, so it follows the host without depending on
## it. A panel with no theme yet reports the light default.
func theme_description() -> Dictionary:
	var text_color := get_theme_color("font_color", "Label")
	var panel_style := get_theme_stylebox("panel", "Panel")
	var background := Color(0.98, 0.97, 0.95)
	if panel_style is StyleBoxFlat:
		background = (panel_style as StyleBoxFlat).bg_color
	return {
		"dark": background.get_luminance() < 0.5,
		"background": background.to_html(false),
		"text": text_color.to_html(false),
		"font_size": get_theme_font_size("font_size", "Label"),
	}


## Focus follows the surface. CefTexture handles the focus notifications itself
## once it has focus, so the panel's job is to hand it over on a click and to
## tell the page, which draws its own focus ring.
func _on_surface_focus_changed(focused: bool) -> void:
	if focused and _cef != null and is_instance_valid(_cef):
		_cef.grab_focus()
	_push_event("council.focus_changed", {"focused": focused})


func _show_notice(message: String) -> void:
	_notice.text = message
	_notice.visible = true
	_surface.visible = false


func _refresh_notice() -> void:
	if _record.is_unreadable():
		_show_notice(_record.unreadable_reason())
		return
	if _cef != null:
		_notice.visible = false
		_surface.visible = true


# ---------------------------------------------------------------------------
# The page protocol
# ---------------------------------------------------------------------------

## One message from the page: a request envelope, or the bridge's ready signal.
##
## Every recoverable failure is answered. A dropped message leaves the page's
## Promise pending forever, which is indistinguishable from a hung panel.
func _on_page_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var message: Dictionary = parsed
	var envelope := str(message.get("envelope", ""))

	if envelope == "ready":
		_page_ready = true
		_push_event("council.theme_changed", theme_description())
		var queued := _outbox.duplicate()
		_outbox.clear()
		for pending in queued:
			_send(pending)
		_push_event("council.snapshot_changed", {})
		return

	if envelope != "request":
		return
	var request_id := str(message.get("request_id", ""))
	if request_id == "":
		return

	var revision := _record.revision()
	if raw.length() > MAX_MESSAGE_CODE_UNITS:
		_send(_err(request_id, revision, "payload_too_large",
			"That request is %d code units, over the %d the panel accepts in one message."
				% [raw.length(), MAX_MESSAGE_CODE_UNITS], false))
		return
	if not (message.get("payload", {}) is Dictionary):
		_send(_err(request_id, revision, "internal", "A request payload must be an object.", false))
		return

	var command := str(message.get("command", ""))
	if command.begins_with(WRAPPER_PREFIX):
		_send(await _wrapper_command(command, message, request_id, revision))
		return
	if _record.is_unreadable():
		_send(_err(request_id, revision, "internal",
			"Council will not change this document: " + _record.unreadable_reason(), false))
		return
	if command == READ_LOCALLY:
		_send(_ok(request_id, revision, {"snapshot": _record.snapshot()}))
		return
	_send(await _relay_to_engine(message))


## Send one request to the engine and persist whatever comes back. This is the
## only path by which the held record changes, and content_changed is emitted
## only when it actually did.
func _relay_to_engine(message: Dictionary) -> Dictionary:
	if _backend == null:
		return _err(str(message.get("request_id", "")), _record.revision(), "internal",
			"This panel is not mounted, so it cannot reach the Council backend.", false)
	var epoch := _document_epoch
	var outcome: Dictionary = await _backend.relay(message, _record.snapshot())
	if epoch != _document_epoch:
		# A load or a note restore replaced the document while this was in
		# flight. Its snapshot is the OLD document's, and adopting it would undo
		# the one the user just opened. The page is told to re-read rather than
		# handed an answer about something it is no longer showing.
		return _err(str(message.get("request_id", "")), _record.revision(), "stale_revision",
			"The panel opened a different council while that request was in flight; re-read and try again.",
			true)
	var snapshot: Dictionary = outcome.get("snapshot", {})
	if not snapshot.is_empty() and int(snapshot.get("snapshot_revision", 0)) != _record.revision():
		if _record.adopt(snapshot):
			_refresh_notice()
			content_changed.emit()
	return outcome.get("reply", {})


## The wrapper's own operations. None of them changes a council: they describe
## the panel, hand a selection to the host, or write `view`, which is user intent
## no engine derives anything from and which advances no revision.
func _wrapper_command(command: String, message: Dictionary, request_id: String,
		revision: int) -> Dictionary:
	var payload: Dictionary = message.get("payload", {})
	match command:
		"wrapper.describe":
			return _ok(request_id, revision, {
				"panel_key": str(_ctx.get("panel_key", "")),
				"plugin_id": str(_ctx.get("plugin_id", "")),
				"file_path": str(_ctx.get("file_path", "")),
				"unreadable": _record.is_unreadable(),
				"unreadable_reason": _record.unreadable_reason(),
				"theme": theme_description(),
				"max_message_code_units": MAX_MESSAGE_CODE_UNITS,
			})
		"wrapper.set_view":
			var view: Variant = payload.get("view", {})
			if not (view is Dictionary):
				return _err(request_id, revision, "internal", "view must be an object.", false)
			if not _record.set_view(view):
				return _err(request_id, revision, "internal",
					"Council will not change this document: " + _record.unreadable_reason(), false)
			content_changed.emit()
			return _ok(request_id, revision, {"view": view})
		"wrapper.chat_handoff":
			return await _chat_handoff(payload, request_id, revision)
	return _err(request_id, revision, "internal",
		"'%s' is not an operation this panel performs." % command, false)


## Hand the selected contributions to the chat this session is bound to.
##
## The destination is read from the session's own `chat_binding.chat_id` in the
## record. There is deliberately no fallback: an unbound session is refused, and
## no code path here can learn which tab is focused. Sending starts a turn in
## that chat, so it is a user action, never something the panel does on its own.
func _chat_handoff(payload: Dictionary, request_id: String, revision: int) -> Dictionary:
	if _backend == null:
		return _err(request_id, revision, "internal",
			"This panel is not mounted, so it cannot reach a chat.", false)
	var session_id := str(payload.get("session_id", ""))
	var session: Dictionary = _record.find_session(session_id)
	if session.is_empty():
		return _err(request_id, revision, "internal",
			"There is no session to send.", false)
	var binding: Dictionary = session.get("chat_binding", {}) \
		if session.get("chat_binding", {}) is Dictionary else {}
	var chat_id := str(binding.get("chat_id", ""))
	var selection := PackedStringArray()
	for c in payload.get("contribution_ids", []):
		selection.append(str(c))
	var text := _record.context_text(str(session.get("session_id", "")), selection)
	if text.strip_edges().is_empty():
		return _err(request_id, revision, "internal",
			"There is nothing in this session to send yet.", false)

	var sent: Dictionary = await _backend.send_to_chat(chat_id, text)
	if not bool(sent.get("ok", false)):
		return _err(request_id, revision, str(sent.get("code", "internal")),
			str(sent.get("message", "")), bool(sent.get("retryable", false)))
	return _ok(request_id, revision, {"chat_id": chat_id, "characters": text.length()})


func _ok(request_id: String, revision: int, payload: Dictionary) -> Dictionary:
	return {
		"schema_version": 1, "envelope": "reply", "request_id": request_id,
		"ok": true, "snapshot_revision": revision, "payload": payload,
	}


func _err(request_id: String, revision: int, code: String, message: String,
		retryable: bool) -> Dictionary:
	return {
		"schema_version": 1, "envelope": "reply", "request_id": request_id,
		"ok": false, "snapshot_revision": revision,
		"error": {"code": code, "message": message, "retryable": retryable},
	}


func _push_event(name: String, payload: Dictionary) -> void:
	_send({
		"schema_version": 1, "envelope": "event", "event": name,
		"snapshot_revision": _record.revision(), "payload": payload,
	})


## eval() is deferred: evaluating JavaScript from inside the browser's own IPC
## callback re-enters the view while it is still borrowed. Anything sent before
## the page's bridge exists is queued rather than evaluated into nothing.
func _send(envelope: Dictionary) -> void:
	if _cef == null or not is_instance_valid(_cef):
		return
	if not _page_ready:
		_outbox.append(envelope)
		return
	_cef.call_deferred("eval", "window.council._deliver(%s);" % JSON.stringify(envelope))
