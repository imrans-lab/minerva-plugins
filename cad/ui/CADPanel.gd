class_name Cad_CADPanel
extends "cad_panel_scene.gd"
## CADPanel.gd — the panel the scene instantiates, and the document half of
## it: the buffer the DSL text arrives on, the evaluation each change starts,
## and the verdict every reader — the banner, minerva_doc_read,
## minerva_cad_await_eval — gets back.
##
## The panes, the annotation host, the measurement and check modules and the
## mesh push are the base class, ui/cad_panel_scene.gd, which this extends: one
## node, one script chain, so every host hook stays reachable on the scene
## root. The evaluation path below reads that half; it is not read back.
##
## The base is extended by relative path, not by class_name: off-tree scripts
## are not resolvable that way (see the base header).

## What an evaluation reply looks like on the MCP wire: the reports the panel
## keeps whole for its own joins, rendered for a reader.
const _EvalReplyScript: Script = preload("scripts/eval_reply.gd")

## Editor name under which we registered our host with AnnotationHostRegistry.
var _registered_editor_name: String = ""

# ── Plugin context ──────────────────────────────────────────────────────────

var _ctx: Dictionary = {}

# ── Buffer-canonical (paired_dsl) state ─────────────────────────────────────
# DCR 019dfa66 §T6: when render_mode=paired_dsl, the panel receives DSL text
# via the substrate's platform-reserved channels (attach_buffer / text_changed
# / detach_buffer) instead of reading it off disk. The panel debounces rapid
# text_changed pushes, cancels any in-flight cad.evaluate via cad.cancel_eval,
# and re-issues evaluate with a fresh request_id.

var _buffer_path: String = ""
## Where the .mcad being edited lives on disk, or "" for an editor that has
## never been saved. mesh() paths are resolved against it.
var _document_path: String = ""
var _buffer_version: int = -1
var _pending_dsl_text: String = ""
var _inflight_request_id: String = ""

## The text the document-open path last dispatched an evaluation for. Opening a
## paired document delivers the source TWICE — once as a load request, once as
## the buffer attach — and each delivery would otherwise start its own
## evaluation of identical text. Cleared by anything that changes the document.
var _open_eval_text: String = ""

## How long one await of a cad.evaluate reply lasts before the panel re-arms it.
## MinervaIPC.await_reply is shared substrate: when its limit passes the await
## ends for good and the worker's later reply is dropped as stale, so a limit
## wide enough for the heaviest document would have to be raised for every
## channel. Instead the panel re-awaits the SAME reply_id in chunks. The re-arm
## runs in the same call stack as the expiry (await_reply resumes its caller
## synchronously), so no reply can land in the gap.
var _eval_await_chunk_ms: int = 300000

## Total time the panel waits before it abandons an evaluation, reports status
## "timeout" with the elapsed time and says so on the banner. Only a worker
## that never answers at all gets this far — supersede/cancel ends the rest.
var _eval_give_up_ms: int = 900000

## Debounce timer for text_changed → evaluate. Created lazily on first
## text_changed receipt so the panel doesn't pay the Timer cost in the legacy
## (non-paired_dsl) path.
var _eval_debounce_timer: Timer = null
const _EVAL_DEBOUNCE_SEC: float = 0.25
## How often await_evaluation looks again. Short enough that the wait costs
## the caller nothing it would notice, long enough not to spin.
const _AWAIT_POLL_SEC: float = 0.05

## Warning from the last GUI mesh import that must survive evaluations.
var _import_notice: String = ""

## Last-known evaluation result, surfaced via _on_panel_save_request so
## minerva_doc_read after a write exposes whether the worker actually
## accepted the DSL. Shape:
##   {status: "empty"|"pending"|"ok"|"error"|"cancelled"|"timeout",
##    error_kind?: String, error_message?: String, shape_name?: String,
##    body_count?: int, request_id?: String, ts?: int}
##
## "empty" = panel just opened, no DSL evaluated yet.
## "pending" = evaluate dispatched, awaiting worker reply.
## "ok" = worker returned a mesh; panel is rendering it.
## "error" = worker rejected the DSL (kind/message available).
## "cancelled" = preempted by a newer evaluate (transient; not user-visible).
## "timeout" = the panel gave up waiting; elapsed_ms says how long it waited.
var _last_eval_result: Dictionary = {"status": "empty"}

## Everything a note needs to know about the document this tab is showing:
## the DSL source, the file it came from, the last evaluation's verdict, the
## mesh the worker returned and the mesh() specs it named. One accessor because
## cad_note.gd is the only reader and it wants them together.
func get_document_state() -> Dictionary:
	return {
		"source": _current_source(),
		"path": _document_path,
		"last_eval": _last_eval_result,
		"mesh": _last_mesh_data,
		"references": _last_references,
	}

## Take on a document, its path and its reference set from a note restore.
## Mounting the references here rather than waiting for the evaluation means a
## reopened note shows its foreign geometry immediately — and correctly, since
## the path is set first and relative mesh() paths resolve against it.
func adopt_restored_document(document_path: String, source: String, references: Array) -> void:
	# No DocumentBuffer is attached to a restored tab: the note is a snapshot,
	# and _buffer_path stays empty so nothing pretends one is. If the owner
	# later opens the same .mcad in the text editor, that attach wins.
	_document_path = document_path
	_import_notice = ""
	_pending_dsl_text = source
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(document_path, source)
	_mount_references(references)
	if not source.strip_edges().is_empty():
		_evaluate_with_request_id(source)

## Send one request to the plugin backend over a declared IPC channel and
## return the host's reply envelope {success, result|error_code/error_message}.
## The evaluation path predates this and keeps its own copy, because it also
## owns cancellation and supersession; everything else asks through here.
func call_backend(channel: String, args: Dictionary,
		timeout_ms: int = 30000) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {
			"success": false,
			"error_code": "ipc_unavailable",
			"error_message": "MinervaIPC helper not attached; cannot reach "
				+ "the CAD plugin backend",
		}
	var reply_id := "%s:%d" % [channel, Time.get_ticks_usec()]
	request.emit(channel, args, reply_id)
	return await ipc.await_reply(reply_id, timeout_ms)


## The same round trip, kept alive until the backend actually answers.
##
## A channel whose work is unbounded — a clearance measurement re-tessellates
## the solid, which on a lofted shell is minutes of OCCT — cannot be awaited
## once: MinervaIPC.await_reply ends at its own limit and the worker's later
## reply is then dropped as stale, so the panel pays for a measurement and
## throws it away. This re-arms the await on the SAME reply_id in chunks
## (see _renew_await) until the answer lands or `give_up_ms` is spent.
func call_backend_until(channel: String, args: Dictionary,
		chunk_ms: int = 60000, give_up_ms: int = 900000) -> Dictionary:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		return {
			"success": false,
			"error_code": "ipc_unavailable",
			"error_message": "MinervaIPC helper not attached; cannot reach "
				+ "the CAD plugin backend",
		}
	var reply_id := "%s:%d" % [channel, Time.get_ticks_usec()]
	request.emit(channel, args, reply_id)
	return await _renew_await(ipc, reply_id, chunk_ms, give_up_ms, "")

# ── Plugin platform lifecycle hooks (override MinervaPluginPanel virtuals) ──

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx

	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name

	if _annotation_host != null and not _annotation_host.selection_changed.is_connected(_on_host_selection_changed):
		_annotation_host.selection_changed.connect(_on_host_selection_changed)


func _on_panel_unload() -> void:
	if _annotation_host != null and _annotation_host.selection_changed.is_connected(_on_host_selection_changed):
		_annotation_host.selection_changed.disconnect(_on_host_selection_changed)

	# Symmetric teardown for the AnnotationHostRegistry entry.
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""

	_cancel_inflight_eval_if_any()


# ── Buffer-canonical (paired_dsl) reception ─────────────────────────────────
# DCR 019dfa66 §T6. The substrate broker pushes platform-reserved channels
# directly to the panel root via Control.receive(channel, payload). The three
# channels are non-allowlisted (they bypass ipc_channels) — see PluginScenePanelBroker.

## Receive a platform-reserved channel push from the substrate broker.
## Channels: attach_buffer / text_changed / detach_buffer.
func receive(channel: String, payload: Dictionary) -> void:
	match channel:
		"attach_buffer":
			_buffer_path = str(payload.get("path", ""))
			if not _buffer_path.is_empty():
				_document_path = _buffer_path
				_import_notice = ""
			_buffer_version = int(payload.get("version", 0))
			var text: String = str(payload.get("text", ""))
			_pending_dsl_text = text
			# Mirror into the host so MCP introspection has fresh source.
			if _annotation_host != null and _annotation_host.has_method("set_document_source"):
				_annotation_host.set_document_source(_buffer_path, text)
			# Initial render is immediate (no debounce) so the panel paints
			# something as soon as the buffer attaches. Empty/whitespace
			# buffers are skipped — the worker would emit a parse warning,
			# producing a toast on every fresh-empty .mcad open.
			if not text.strip_edges().is_empty():
				_evaluate_document_open(text)
		"text_changed":
			_buffer_version = int(payload.get("version", 0))
			var text2: String = str(payload.get("text", ""))
			_pending_dsl_text = text2
			_open_eval_text = ""
			if _annotation_host != null and _annotation_host.has_method("set_document_source"):
				_annotation_host.set_document_source(_buffer_path, text2)
			_start_eval_debounce()
		"detach_buffer":
			_cancel_inflight_eval_if_any()
			# Stop any pending debounce so we don't fire an evaluate against
			# the now-empty _pending_dsl_text after the buffer detaches.
			if _eval_debounce_timer != null:
				_eval_debounce_timer.stop()
			_buffer_path = ""
			_buffer_version = -1
			_pending_dsl_text = ""
			_open_eval_text = ""


## Issue a fresh cad.evaluate with a unique request_id, cancelling any prior
## in-flight evaluate first so the worker doesn't waste cycles on stale text.
func _evaluate_with_request_id(text: String) -> void:
	_cancel_inflight_eval_if_any()
	var rid: String = "eval_%d" % Time.get_ticks_usec()
	# fire-and-await — supersession check inside _evaluate_and_render handles
	# the race where this call completes after a newer one has already landed.
	_evaluate_and_render(text, rid)


## Evaluate the source a document OPEN delivered, once. The host delivers an
## open twice (load request + buffer attach), so the second delivery of text
## that is already being evaluated is skipped rather than costing the worker a
## second full evaluation of the same document.
func _evaluate_document_open(text: String) -> void:
	if text == _open_eval_text:
		return
	_open_eval_text = text
	_evaluate_with_request_id(text)


## Cancel the current in-flight cad.evaluate (if any) by emitting cad.cancel_eval.
## The worker sees its context cancellation and returns kind=cancelled.
func _cancel_inflight_eval_if_any() -> void:
	if _inflight_request_id == "":
		return
	# Emit fire-and-forget — we don't need a reply correlation for the ack.
	# Empty reply_id signals the IPC helper to drop the response.
	request.emit("cad.cancel_eval", {"request_id": _inflight_request_id}, "")
	_inflight_request_id = ""


## Lazily create the debounce timer and (re)start it. Each text_changed
## resets the timer; the timer fires _on_eval_debounce_timeout once the user
## stops typing for _EVAL_DEBOUNCE_SEC seconds.
func _start_eval_debounce() -> void:
	if _eval_debounce_timer == null:
		_eval_debounce_timer = Timer.new()
		_eval_debounce_timer.one_shot = true
		_eval_debounce_timer.wait_time = _EVAL_DEBOUNCE_SEC
		_eval_debounce_timer.timeout.connect(_on_eval_debounce_timeout)
		add_child(_eval_debounce_timer)
	_eval_debounce_timer.stop()
	_eval_debounce_timer.start()


func _on_eval_debounce_timeout() -> void:
	# Empty/whitespace buffer → cancel any in-flight, but skip dispatching a
	# fresh evaluate (the worker would parse-error, surfacing a toast on
	# every keystroke that empties the buffer).
	if _pending_dsl_text.strip_edges().is_empty():
		_cancel_inflight_eval_if_any()
		return
	_evaluate_with_request_id(_pending_dsl_text)


# ── GUI mesh import ─────────────────────────────────────────────────────────
#
# The picker and the buttons are scene nodes, so their signals stay connected to
# the panel's own handlers; the action itself lives in scripts/mesh_import_ui.gd.

func _on_import_mesh_pressed() -> void:
	_mesh_import_ui.on_import_pressed()


func _on_mesh_file_selected(path: String) -> void:
	import_mesh_file(path)


## Append one `refN = mesh("path")` line for `absolute_path` to the document
## and re-evaluate. The action itself — the picker, the buttons and the edit —
## lives in scripts/mesh_import_ui.gd; this is the name its other callers reach
## it by.
##
## Returns the import plan — {ok, line, name, path, absolute, warning, error}.
func import_mesh_file(absolute_path: String) -> Dictionary:
	return _mesh_import_ui.import_file(absolute_path)


## The source as the document currently holds it. The attached buffer wins over
## the panel's mirror: an edit made in the text editor a moment ago is in the
## buffer before the panel's debounce has run.
func _current_source() -> String:
	var buffer: Object = _shared_buffer()
	if buffer != null and "text" in buffer:
		return str(buffer.text)
	return _pending_dsl_text


## Write `new_source` back to the document and start an evaluation.
##
## The buffer's apply_edit bumps its version and fires text_changed, which the
## paired text editor and this panel both receive — one document, two views.
## When no buffer is attached (a panel driven by _on_panel_load_request's
## `source` shape) the panel's own mirror is all there is.
func _apply_source_edit(new_source: String) -> void:
	var buffer: Object = _shared_buffer()
	if buffer != null and buffer.has_method("apply_edit"):
		# The buffer's text_changed push comes back through receive(), which
		# records the text and starts the debounce; doing it here too would
		# evaluate twice.
		buffer.apply_edit(new_source)
		return
	_pending_dsl_text = new_source
	_open_eval_text = ""
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(_buffer_path, new_source)
	# The ordinary typing path: one debounce, one evaluate, whether the text
	# came from the keyboard, from MCP or from here.
	_start_eval_debounce()


## The DocumentBuffer the substrate attached to this panel, or null. Typed
## Object because DocumentBuffer is a host class_name and this script lives
## outside Minerva's res:// tree.
func _shared_buffer() -> Object:
	var broker: Object = _ctx.get("broker", null) as Object
	if broker == null or not broker.has_method("get_attached_buffer"):
		return null
	var panel_name: String = str(_ctx.get("panel_name", ""))
	if panel_name.is_empty():
		return null
	return broker.get_attached_buffer(plugin_id, panel_name)


# ── Save/load contract (overrides MinervaPluginPanel virtuals) ──────────────

## last_eval as MCP sees it, with the report the panel is SHOWING merged in.
## The owner reads the banner and an agent reads this; a verdict that differed
## between them would be two answers to one question.
func _last_eval_for_mcp() -> Dictionary:
	var out: Dictionary = _EvalReplyScript.last_eval_for_mcp(_last_eval_result)
	if _eval_banner != null:
		out["banner"] = _eval_banner.state_for_mcp()
	return out


func _on_panel_save_request() -> Dictionary:
	# Include the current DSL source so doc_read on an open editor (whether
	# anonymous or path-bound) returns useful content. _pending_dsl_text is the
	# panel's authoritative source — kept in sync by attach_buffer / text_changed
	# (path-bound) and by _on_panel_load_request's `source` branch (anonymous).
	#
	# `last_eval` exposes the worker's most recent verdict on the DSL so MCP
	# callers can verify a doc_write actually rendered. Status values:
	# empty / pending / ok / error / cancelled / timeout. See _last_eval_result
	# decl for the full shape.
	#
	# TODO(later): include annotations + camera states.
	return {
		"version": 1,
		"source": _pending_dsl_text,
		"last_eval": _last_eval_for_mcp(),
	}


## Synchronous-apply hook: replaces the current source with `document.source`,
## cancels any in-flight evaluate, skips the text_changed debounce, awaits the
## worker's reply, and returns the resulting last_eval to the caller.
##
## Used by minerva_doc_write so the agent gets eval status (ok / error /
## timeout / cancelled) in the tool reply instead of polling. Mirrors
## _on_panel_load_request's `source` shape on input.
##
## Returns {ok: bool, last_eval: Dictionary}. ok mirrors last_eval.status == "ok".
func _on_panel_apply_sync(document: Dictionary) -> Dictionary:
	var src: String = str(document.get("source", ""))
	_pending_dsl_text = src
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(_buffer_path, src)

	if src.strip_edges().is_empty():
		_last_eval_result = {
			"status": "empty",
			"ts": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "last_eval": _last_eval_for_mcp()}

	# Race guard: when minerva_create_plugin_editor mounts a fresh paired_dsl
	# panel and the agent's first minerva_doc_write fires immediately after,
	# _MinervaIPC may not be queryable yet — the helper is attached as a
	# child of the panel root during broker.register_panel, but tree-mount
	# timing inside Editor.create_plugin_scene → instantiate_into can leave
	# get_node_or_null returning null on the very next request. Wait one
	# process frame and re-check; if still missing, fall back to the
	# debounce-driven async eval rather than failing the agent's call.
	if get_node_or_null("_MinervaIPC") == null:
		await get_tree().process_frame
	if get_node_or_null("_MinervaIPC") == null:
		# Helper still not reachable — let the existing text_changed → debounce
		# path carry this eval (the buffer.apply_edit upstream of this call has
		# already fired text_changed, which started the debounce timer). Surface
		# "pending" so the agent knows to verify via doc_read once the worker
		# replies. Don't cancel the in-flight or stop the debounce here — those
		# are exactly the things we want to leave running.
		_last_eval_result = {
			"status": "pending",
			"ts": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "last_eval": _last_eval_for_mcp()}

	# Helper is ready — synchronous eval as originally intended. Cancel any
	# in-flight + skip the debounce so the MCP caller gets a tight request →
	# response round-trip without a competing debounced eval landing late.
	_cancel_inflight_eval_if_any()
	if _eval_debounce_timer != null:
		_eval_debounce_timer.stop()

	var rid: String = "eval_sync_%d" % Time.get_ticks_usec()
	await _evaluate_and_render(src, rid)
	var status: String = str(_last_eval_result.get("status", ""))
	return {
		"ok": status == "ok",
		"last_eval": _last_eval_for_mcp(),
	}


## Wait until the panel has PAINTED an evaluation, and report the one it did.
##
## Backs minerva_cad_await_eval. An edit that arrives through the shared
## buffer — minerva_doc_edit, or the user typing — starts a debounce and then
## a worker round-trip, and neither is over when the write tool returns: a
## check_* call made straight afterwards measures the PREVIOUS geometry with
## nothing in its reply to say so. This is the wait for that, and it waits for
## the queued edit too: a debounce still running is an evaluation that has not
## started, which is no more settled than one that has not answered.
##
## Returns the wire form of last_eval plus `waited_ms` and `timed_out`. A
## timeout is not an error — the evaluation is still running, and the reply
## says so with the status the panel is showing.
func await_evaluation(timeout_ms: int) -> Dictionary:
	var started_ms: int = Time.get_ticks_msec()
	var timed_out := false
	while _evaluation_is_unsettled():
		if Time.get_ticks_msec() - started_ms >= timeout_ms:
			timed_out = true
			break
		await get_tree().create_timer(_AWAIT_POLL_SEC).timeout
		if not is_instance_valid(self):
			return {"status": "closed", "timed_out": false, "waited_ms": 0}
	return {
		"last_eval": _last_eval_for_mcp(),
		"timed_out": timed_out,
		"waited_ms": Time.get_ticks_msec() - started_ms,
	}


## True while an evaluation is either queued behind the debounce or still out
## with the worker.
func _evaluation_is_unsettled() -> bool:
	if str(_last_eval_result.get("status", "")) == "pending":
		return true
	return _eval_debounce_timer != null and _eval_debounce_timer.time_left > 0.0


func _on_panel_load_request(document: Dictionary) -> void:
	# Two load shapes are accepted:
	#  1. {source: "<DSL text>"} — in-memory DSL, used for anonymous editors
	#     created via minerva_create_plugin_editor + minerva_doc_write. No disk
	#     read; the panel just evaluates the supplied text.
	#  2. {file_path: "<absolute path>"} — disk-backed .mcad file (the host
	#     dispatches this when an .mcad is opened via File → Open).
	#
	# When BOTH are present, `source` wins (caller is forcing a new in-memory
	# version on top of a path-bound editor; tab will dirty until Save-As).
	if document.has("source"):
		var src: String = str(document.get("source", ""))
		_pending_dsl_text = src
		# No file path yet for anonymous editors; pass empty so MCP introspection
		# knows the source is unbacked. set_document_source still wires up the
		# panel's source-of-truth for annotations etc.
		if _annotation_host != null and _annotation_host.has_method("set_document_source"):
			_annotation_host.set_document_source(_buffer_path, src)
		if not src.strip_edges().is_empty():
			_evaluate_with_request_id(src)
		return

	# Round 3: live `.mcad` → CAD panel pipeline. The host loads the file path
	# from the editor; we read the DSL text off disk and round-trip it through
	# the worker's `evaluate` method. The reply carries {shape_name, mesh, edges}
	# which we push to all 5 MeshDisplay instances + the edge overlays + the
	# sidebar Tree.
	var file_path: String = str(document.get("file_path", ""))
	if file_path.is_empty():
		return

	var fa := FileAccess.open(file_path, FileAccess.READ)
	if fa == null:
		push_warning(
			"[CADPanel] _on_panel_load_request: cannot open '%s' (err=%d)"
			% [file_path, FileAccess.get_open_error()]
		)
		return
	var dsl_text: String = fa.get_as_text()
	fa.close()
	_document_path = file_path
	_import_notice = ""

	# Push document source into host so MCP can read it without IPC.
	if _annotation_host != null and _annotation_host.has_method("set_document_source"):
		_annotation_host.set_document_source(file_path, dsl_text)

	_pending_dsl_text = dsl_text
	_evaluate_document_open(dsl_text)


## Await one cad.evaluate reply for as long as the worker needs it.
##
## The shared IPC await ends at its own limit; this re-arms it on the same
## reply_id until the worker answers, a newer evaluation takes the in-flight
## slot, or _eval_give_up_ms is spent. Returns the IPC envelope with
## `elapsed_ms` added — on a give-up that envelope is the helper's own timeout
## error, which the caller turns into last_eval.status "timeout".
func _await_eval_reply(ipc: Node, reply_id: String, request_id: String) -> Dictionary:
	return await _renew_await(ipc, reply_id, _eval_await_chunk_ms,
		_eval_give_up_ms, request_id)


## Re-arm one IPC await on the same reply_id until the backend answers.
##
## The re-arm runs in the same call stack as the expiry (await_reply resumes
## its caller synchronously), so no reply can land in the gap. `request_id`
## non-empty adds the evaluation path's supersession: a newer request owning
## the in-flight slot ends the wait, because this reply is not worth having.
## Returns the envelope with `elapsed_ms` added — on a give-up that envelope
## is the helper's own timeout error.
func _renew_await(ipc: Node, reply_id: String, chunk_ms: int, give_up_ms: int,
		request_id: String) -> Dictionary:
	var started_ms: int = Time.get_ticks_msec()
	var envelope: Dictionary = {}
	while true:
		envelope = await ipc.await_reply(reply_id, chunk_ms)
		var elapsed_ms: int = Time.get_ticks_msec() - started_ms
		envelope["elapsed_ms"] = elapsed_ms
		# Only the IPC helper's own expiry sentinel names the reply_id back; a
		# timeout reported by the broker or the worker is a real answer.
		var expired: bool = (
			not bool(envelope.get("success", false))
			and str(envelope.get("error_code", "")) == "timeout"
			and str(envelope.get("reply_id", "")) == reply_id
		)
		# Superseded: a newer evaluation owns the panel, so this one is not worth
		# waiting on any longer. The caller drops the envelope either way.
		var superseded: bool = request_id != "" and _inflight_request_id != request_id
		if not expired or superseded:
			break
		if elapsed_ms >= give_up_ms:
			envelope["error_message"] = (
				"the worker did not answer in %.1f s" % (elapsed_ms / 1000.0))
			break
	return envelope


## Round-trip a DSL string through the worker's evaluate method and update the
## panel state (meshes, edges, sidebar) with the result. Centralised so a future
## bottom-split editor (`019dd0211893`) can call the same path on save/run.
##
## paired_dsl callers pass a request_id so cad.cancel_eval can cancel the
## in-flight evaluate when a newer text_changed arrives. The post-await
## supersession check drops stale results so a slow eval that finishes after
## a newer one has already landed doesn't clobber the panel state.
func _evaluate_and_render(dsl_text: String, request_id: String = "") -> void:
	var ipc := get_node_or_null("_MinervaIPC")
	if ipc == null:
		_last_eval_result = {
			"status": "error",
			"error_kind": "ipc_unavailable",
			"error_message": "MinervaIPC helper not attached; cannot dispatch cad.evaluate",
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning("[CADPanel] _evaluate_and_render: MinervaIPC helper not attached; cannot dispatch cad.evaluate")
		_show_eval_error("CAD evaluation unavailable — the panel's IPC helper is not attached.")
		return

	var reply_id := "cad.evaluate:" + str(Time.get_ticks_usec())
	var args: Dictionary = {"source": dsl_text}
	if request_id != "":
		args["request_id"] = request_id
		_inflight_request_id = request_id
	# Mark pending BEFORE the await so a same-tick doc_read sees pending, not
	# stale prior result.
	_last_eval_result = {
		"status": "pending",
		"request_id": request_id,
		"ts": Time.get_unix_time_from_system(),
	}
	# A fresh evaluate supersedes any prior failure — clear a stale banner.
	_hide_eval_error()
	request.emit("cad.evaluate", args, reply_id)

	# No fixed limit: a heavy document (many booleans, a cold build123d start)
	# can take minutes, and an answer the worker computed must be painted
	# whenever it is still the newest one.
	var result: Dictionary = await _await_eval_reply(ipc, reply_id, request_id)
	var elapsed_ms: int = int(result.get("elapsed_ms", 0))

	# Supersession: if a newer evaluate started while we were awaiting, drop
	# this result. The newer evaluate set _inflight_request_id to its own id;
	# our cancel_eval may have already triggered the worker's cancellation,
	# in which case `result` is a worker error kind=cancelled.
	if request_id != "" and _inflight_request_id != request_id:
		# Don't overwrite _last_eval_result — the newer evaluate owns it.
		return
	if request_id != "":
		_inflight_request_id = ""

	if not bool(result.get("success", false)):
		var err_code: String = str(result.get("error_code", "unknown"))
		var err_msg: String = str(result.get("error_message", ""))
		# IPC-layer timeout surfaces as success=false with a timeout-ish code.
		var st: String = "timeout" if err_code.findn("timeout") != -1 else "error"
		# How long it waited is the point of a give-up: "still pending" and
		# "abandoned after four minutes" are different facts for the reader.
		_last_eval_result = {
			"status": st,
			"error_kind": err_code,
			"error_message": err_msg,
			"elapsed_ms": elapsed_ms,
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning(
			"[CADPanel] cad.evaluate transport failure: %s — %s (after %d ms)"
			% [err_code, err_msg, elapsed_ms]
		)
		var _what: String = ("gave up after %.1f s" % (elapsed_ms / 1000.0)
			if st == "timeout" else "failed")
		_show_eval_error("CAD evaluation %s: %s" % [_what,
			err_msg if err_msg != "" else err_code])
		return

	# PluginScenePanelBroker wraps the worker payload in PluginErrors.success(),
	# so the visible shape is:
	#   result = {success:true, result: <worker_payload>}
	# where <worker_payload> is the raw worker dict {ok, result|error}.
	var worker_payload: Dictionary = result.get("result", {})
	if not (worker_payload is Dictionary):
		_last_eval_result = {
			"status": "error",
			"error_kind": "missing_worker_payload",
			"error_message": "cad.evaluate reply had no Dictionary payload",
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning("[CADPanel] cad.evaluate: missing worker payload")
		_show_eval_error("CAD evaluation failed — the worker reply was malformed.")
		return

	if not bool(worker_payload.get("ok", false)):
		# Worker may emit `error` as either a structured dict {kind, message} or a
		# bare string for older/parse-stage error paths. Defend against both.
		var err_var: Variant = worker_payload.get("error", {})
		var err: Dictionary = err_var if err_var is Dictionary else {}
		var kind: String = str(err.get("kind", "unknown"))
		var msg: String = str(err.get("message", err_var if err_var is String else ""))
		# kind=cancelled is the expected outcome of cad.cancel_eval — a newer
		# evaluate raced past this one. Silent return; no toast.
		if kind == "cancelled":
			_last_eval_result = {
				"status": "cancelled",
				"error_kind": kind,
				"request_id": request_id,
				"ts": Time.get_unix_time_from_system(),
			}
			return
		var frame: String = _EvalReplyScript.innermost_frame(str(err.get("traceback", "")))
		_last_eval_result = {
			"status": "error",
			"error_kind": kind,
			"error_message": msg,
			"error_frame": frame,
			"request_id": request_id,
			"ts": Time.get_unix_time_from_system(),
		}
		push_warning("[CADPanel] cad.evaluate worker error [%s]: %s" % [kind, msg])
		var banner: String = "CAD evaluation failed (%s): %s" % [kind,
			msg if msg != "" else "no detail provided"]
		if frame != "":
			banner += "\n%s" % frame
		_show_eval_error(banner)
		return

	var eval_result: Dictionary = worker_payload.get("result", {}) as Dictionary
	var mesh_data: Dictionary = eval_result.get("mesh", {}) as Dictionary
	var edges_var: Variant = eval_result.get("edges", [])
	var edges: Array = edges_var if edges_var is Array else []
	if _DEBUG_EDGE_PICK:
		print("[edge-pick] eval-response eval_result.keys=%s edges_var.type=%s edges.size=%d mesh.keys=%s" % [
			str(eval_result.keys()),
			str(typeof(edges_var)),
			edges.size(),
			str(mesh_data.keys()),
		])

	# Mount the referenced mesh files first: update_mesh auto-frames, and the
	# frame has to cover the references as well as the solid.
	var references_var: Variant = eval_result.get("references", [])
	_mount_references(references_var if references_var is Array else [])

	# Push mesh into all 5 MeshDisplay instances. The MeshRoot Node3D in each
	# SubViewport has scripts/mesh_display.gd attached, exposing update_mesh().
	for path in _MESH_ROOT_PATHS:
		var mr := get_node_or_null(path)
		if mr != null and mr.has_method("update_mesh"):
			mr.call("update_mesh", mesh_data, edges)

	# Update panel state and re-push edge overlays + sidebar tree.
	_last_mesh_data = mesh_data
	_edge_registry = edges
	# Mirror into host so MCP introspection tools can read without reaching into the panel.
	if _annotation_host != null:
		if _annotation_host.has_method("set_mesh_data"):
			_annotation_host.set_mesh_data(mesh_data)
		if _annotation_host.has_method("set_edge_registry"):
			_annotation_host.set_edge_registry(edges)
	_push_mesh_to_geometry_overlays()
	_edge_sidebar.render(_edge_registry)
	# Re-apply mesh visibility (ortho panes hide the shaded mesh; iso shows it).
	_apply_mesh_visibility()
	# update_mesh auto-framed every pane just now. A note restore's saved view
	# outranks that framing, and is applied here exactly once.
	_CadNoteScript.apply_pending_camera(self)

	# Mark the eval as ok so minerva_doc_read can verify success after a write.
	# shape_name comes straight from the worker (the named output the DSL
	# bound — e.g. the last assigned shape variable).
	_last_eval_result = {
		"status": "ok",
		"shape_name": str(eval_result.get("shape_name", "")),
		# Separate solid bodies in that shape. A part written as two halves
		# unions into a compound, which renders and measures as ONE shape but
		# is two bodies — invisible from the vertex count alone.
		"body_count": int(eval_result.get("body_count", 1)),
		# The worker emits one [x, y, z] triple per vertex.  Count records, not
		# scalar coordinates, so this agrees with minerva_cad_get_mesh_info.
		"vertex_count": (mesh_data.get("vertices", []) as Array).size(),
		"edge_count": edges.size(),
		# How the outline on screen was drawn, and how much of the edge list it
		# accounts for. "brep" means every line is a numbered edge; a solid
		# whose outlined_edges is short of edge_count has edges the drawing is
		# not showing.
		"outline": _outline_report(),
		"reference_count": int(_reference_report.get("mounted", 0)),
		"references": _reference_report.get("statuses", []),
		"request_id": request_id,
		"ts": Time.get_unix_time_from_system(),
	}
	# Holes, slivers and doubled faces in the tessellated solid, counted by the
	# outline pass that just walked it. Reported only when there are any: a
	# clean mesh has nothing to say, and a solid that renders as porous should
	# say so in numbers rather than leave the panes to be doubted.
	var defects: Dictionary = _mesh_defects()
	if not defects.is_empty():
		_last_eval_result["mesh_defects"] = defects
	# WHERE they are. The worker located them on the same tessellation it sent
	# here: non-manifold edges by world position (capped), degenerate faces as a
	# capped spread sample with the note that slivers on curved faces are not
	# defects. A count on its own names no feature to fix.
	var defect_sites: Variant = eval_result.get("mesh_defect_sites", {})
	if defect_sites is Dictionary and not (defect_sites as Dictionary).is_empty():
		_last_eval_result["mesh_defect_sites"] = defect_sites
	# Render succeeded — clear any error banner left by a prior failed evaluate.
	_hide_eval_error()
	# A reference that could not be loaded — or that was too big to outline —
	# is not an evaluation failure: the solid is on screen and correct. It
	# still has to be said out loud, or the board the user expected is simply
	# missing with no explanation. The lines name the reference and the reason.
	var lines := PackedStringArray()
	for reference_line in _reference_report.get("status_lines", PackedStringArray()):
		lines.append("Reference mesh: %s" % str(reference_line))

	# Does the solid run into any of them? Asked here rather than left to a
	# verb, because an agent iterating on an enclosure has no reason to ask
	# and every reason to know. The check waits on a physics step, so the
	# document may have moved on: the result is attached only if this
	# evaluation is still the one being shown.
	var stamp: float = float(_last_eval_result.get("ts", 0.0))
	var interference: Dictionary = await check_interference()
	if not is_instance_valid(self) or float(_last_eval_result.get("ts", -1.0)) != stamp:
		# A newer evaluation owns the banner now; this one paints nothing.
		return
	_last_eval_result["interference"] = interference
	var interference_line: String = _geometry_checks.status_line(interference)
	if not interference_line.is_empty():
		lines.append(interference_line)

	if not lines.is_empty():
		_show_eval_error("\n".join(lines))


## Say what this evaluation found. Called from _evaluate_and_render's failure
## paths, so a render that produced nothing says why instead of leaving an
## empty pane, and from its success path for a reference or interference
## report.
## The evaluation the message belongs to is _last_eval_result, which every
## caller has already written before it gets here.
func _show_eval_error(message: String) -> void:
	if _eval_banner != null:
		_eval_banner.show_for_eval(message, _last_eval_result)


## Nothing to report — a fresh evaluate started, or one settled clean.
## An import notice outlives evaluations: it stays until the buffer has a path.
## Save-As rebinds the attached buffer in place rather than re-attaching it, so
## the path is read from the buffer here, not from an attach event.
func _hide_eval_error() -> void:
	if _eval_banner == null:
		return
	if not _import_notice.is_empty():
		var buffer: Object = _shared_buffer()
		var buffer_path: Variant = buffer.get("file_path") if buffer != null else null
		if buffer_path is String and not (buffer_path as String).is_empty():
			_import_notice = ""
		else:
			_eval_banner.show_notice(_import_notice)
			return
	_eval_banner.clear()
