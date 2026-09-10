extends RefCounted

## The panel's hop to the Council backend, and the thing that keeps two panels
## out of each other's councils.
##
## THE PROBLEM THIS CLASS EXISTS FOR. One plugin process serves every open
## Council tab, and its engine holds exactly ONE working snapshot
## (internal/session/store.go: `Store.snapshot`, replaced wholesale by Load).
## Two panels showing two projects therefore share one store. Nothing in the
## backend can tell them apart, because the durable record lives in the panel,
## not in the backend (architecture.md §3).
##
## THE RULE. A panel may only speak to the engine while the engine is loaded
## with THAT panel's record. So an exchange is: take the process-wide lease,
## seed the engine with my record if it is not already mine, send the command,
## read the acknowledged snapshot back, release. The lease makes an exchange
## atomic against every other panel; the seed makes "the engine holds my record"
## true rather than hoped for. A panel that loses the lease mid-exchange cannot
## happen; a panel whose exchange fails clears the holder so the next one
## re-seeds instead of trusting a working copy nobody can name.
##
## SIZE IS MEASURED WHERE IT IS ENFORCED. The host caps a scene request at
## `JSON.stringify(payload).length()` — the WHOLE argument dictionary, including
## the keys this class wraps a snapshot or an envelope in
## (PluginScenePanelBroker.gd `MAX_PAYLOAD_BYTES`, checked at its step 6). A
## check against the record alone would pass a message the broker then drops, so
## the measurement here is of the serialised payload that will actually travel.

## The host's cap on one scene request, in UTF-16 code units — the unit
## `String.length()` returns, which is the unit the host's own check uses
## despite its constant being named MAX_PAYLOAD_BYTES.
## Mirrors PluginScenePanelBroker.MAX_PAYLOAD_BYTES; a plugin cannot preload a
## host script (it must load outside the project for the syntax gate), so the
## value is duplicated here and pinned against the host's own constant by
## tests/gd/test_council_panel.gd.
const HOST_IPC_PAYLOAD_LIMIT := 65536

## Backend channels, which are the backend's MCP tool names (the broker calls
## `tools/call` with the channel as the tool name). Every one of these is
## declared in manifest.json under `ui.ipc_messages` and on the panel.
const COMMAND_CHANNEL := "minerva_council_command"
const LOAD_CHANNEL := "minerva_council_load_snapshot"
const EXPORT_CHANNEL := "minerva_council_export_snapshot"

## The host's enabled providers and models. It is the one backend channel that
## does not touch the record, so it is called WITHOUT the lease: taking it would
## make a model list wait behind another tab's round for no reason, and there is
## no snapshot for the two to disagree about.
const MODELS_CHANNEL := "minerva_council_models"

## The host capability that delivers a selected context to an explicitly named
## chat. `minerva_send_message` takes the chat_id as a parameter, which is the
## whole reason Council can use it: there is no path here that could pick a
## destination from whichever tab happens to be focused.
const SEND_MESSAGE_CHANNEL := "capability:mcp.proxy:minerva_send_message"

## How long the panel waits for one hop. The broker gives the backend 1800 s;
## these calls are local engine work and a wait this long already means the
## backend is wedged. A timed-out exchange clears the lease holder, so the state
## the next exchange assumes is re-established rather than inherited.
##
## Declared in seconds and multiplied up, because the timeout MESSAGE is in
## seconds: deriving the milliseconds from the seconds keeps one number in the
## file, where dividing the milliseconds back down would be an integer division
## whose remainder silently disappears.
const HOP_TIMEOUT_SECONDS := 120
const HOP_TIMEOUT_MS := HOP_TIMEOUT_SECONDS * 1000

## Where the lease lives.
##
## It has to be ONE object for the whole process: two panels that each saw their
## own copy of it would each believe they hold the engine. A `static var` lives
## on the script RESOURCE, and a plugin hot reload replaces that resource while
## panels mounted before it keep the old one — two scripts, two sets of statics,
## two panels each certain the engine is theirs. Engine-level metadata is a
## single object by construction, independent of how many times this script is
## loaded or reloaded.
const LEASE_META := "council_backend_lease"

var _panel: Node = null
var _panel_key: String = ""
var _reply_seq: int = 0
var _seed_generation: int = 0


## One waiting exchange. A signal carrier rather than a poll loop, so the queue
## is FIFO and costs nothing while it waits. It carries whose exchange it is, so
## a handoff to a panel that has since closed is skipped instead of stranding
## the lease on a coroutine nobody will ever resume.
class _LeaseWaiter extends RefCounted:
	signal granted()
	var key: String = ""
	var panel_ref: WeakRef = null


func _init(panel: Node, panel_key: String) -> void:
	_panel = panel
	_panel_key = panel_key


# ---------------------------------------------------------------------------
# The exchange
# ---------------------------------------------------------------------------

## Relay one protocol request to the engine, against `record`.
##
## Returns {"reply": <reply envelope>, "snapshot": <the acknowledged snapshot,
## or {} when nothing moved>}. The caller persists the snapshot; this class
## never keeps one, because a second copy of the record is a second place for it
## to be wrong.
func relay(request: Dictionary, record: Dictionary, current_record := Callable(), read_current_only := false) -> Dictionary:
	var request_id := str(request.get("request_id", ""))
	await _acquire()
	# A queued exchange must read the durable record after acquiring the store.
	# Another exchange may have advanced it, or the tab may hold a new document.
	if current_record.is_valid():
		record = current_record.call()
		if record.is_empty():
			_release()
			return {"reply": _failure(request_id, 1, "stale_revision",
				"The panel opened a different council; re-read and try again.", true), "snapshot": {}}
	# Background convergence only observes. It must never load an older panel
	# snapshot over the current engine while waiting for the lease.
	var seeded: Dictionary = {"ok": true, "snapshot": {}}
	if not read_current_only:
		seeded = await _ensure_seeded(record)
	if not bool(seeded.get("ok", false)):
		_set_holder("")
		_release()
		return {"reply": _failure(request_id, int(record.get("snapshot_revision", 1)),
			str(seeded.get("code", "internal")), str(seeded.get("message", "")),
			bool(seeded.get("retryable", false))), "snapshot": {}}

	var carried: Dictionary = seeded.get("snapshot", {})
	var revision: int = int(record.get("snapshot_revision", 1))
	if not carried.is_empty():
		revision = int(carried.get("snapshot_revision", revision))

	request = request.duplicate(true)
	var expected := str(carried.get("project_id", record.get("project_id", "")))
	if not expected.is_empty():
		request["expected_project_id"] = expected
	var sent := await _send(COMMAND_CHANNEL, request)
	if not bool(sent.get("ok", false)):
		_set_holder("")
		_release()
		return {"reply": _failure(request_id, revision, str(sent.get("code", "internal")),
			str(sent.get("message", "")), bool(sent.get("retryable", true))),
			"snapshot": carried}

	var reply: Dictionary = sent.get("body", {})
	# A refusal produced against a revision that is not the one we seeded means
	# the store is no longer holding our record — the backend was restarted under
	# us (auto_reload rebuilds the binary while panels stay mounted), so the
	# holder we believe in is a fiction and every later exchange would skip the
	# seed and loop on stale_revision. Forget it; the next exchange re-seeds.
	if not bool(reply.get("ok", true)) and _holder() == _panel_key:
		var failure: Dictionary = reply.get("error", {})
		if int(reply.get("snapshot_revision", revision)) != revision \
				or str(failure.get("code", "")) == "stale_revision":
			_set_holder("")

	# The engine advanced the record: read the acknowledged snapshot back, because
	# a command reply carries its own payload and not the record. Nothing is shown
	# as saved before this returns.
	if bool(reply.get("ok", false)) and str(request.get("command", "")) == "snapshot.get":
		# This snapshot and its identity were read atomically by the command.
		# An extra export hop could observe a different document loaded meanwhile.
		carried = (reply.get("payload", {}) as Dictionary).get("snapshot", {})
	elif bool(reply.get("ok", false)) and int(reply.get("snapshot_revision", 0)) != revision:
		var exported := await _send(EXPORT_CHANNEL, {})
		if bool(exported.get("ok", false)) and _refusal(exported.get("body", {})).is_empty():
			var snapshot: Variant = (exported.get("body", {}) as Dictionary).get("snapshot", null)
			if snapshot is Dictionary:
				carried = snapshot
		else:
			# The mutation happened but the record did not come back. Say so
			# rather than reporting a save that did not reach the project.
			_set_holder("")
			_release()
			return {"reply": _failure(request_id, int(reply.get("snapshot_revision", revision)),
				"internal",
				"The council was changed but the updated record could not be read back, so it has not been saved. "
				+ "Reopen the panel to re-read it. (" + str(exported.get("message", "")) + ")",
				true), "snapshot": carried}

	_release()
	return {"reply": reply, "snapshot": carried}


## Read Minerva's enabled providers and models. Each call re-reads them from the
## host, which is what makes it the answer after a user enables a model.
func models() -> Dictionary:
	return await _send(MODELS_CHANNEL, {})


## Hand `text` to the chat `chat_id` names. The caller resolves the id from the
## session's recorded `chat_binding`; this class refuses an empty one rather
## than falling back to anything.
func send_to_chat(chat_id: String, text: String) -> Dictionary:
	if chat_id.strip_edges().is_empty():
		return {"ok": false, "code": "missing_chat",
			"message": "This session is not bound to a chat, so there is nowhere to send it."}
	return await _send(SEND_MESSAGE_CHANNEL, {"chat_id": chat_id, "message": text})


# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------

## Make the engine hold this panel's record. A no-op when it already does.
##
## Load is where the record can come back different, and there are three ways:
## the interruption rule demotes work that was in flight when the owning process
## went away; a migration brings a document written by an older Council up to
## this build's shape and mints its project identity; and a RECOVERY happens when
## the engine was already holding a later state of this same document — the round
## that kept running after the panel closed, whose contributions exist nowhere
## else. Each of them means the rewritten form is the one the panel must persist,
## and it is returned here as `snapshot`.
func _ensure_seeded(record: Dictionary) -> Dictionary:
	if _holder() == _panel_key and not _panel_key.is_empty():
		return {"ok": true, "snapshot": {}}
	var generation := _seed_generation
	# "reopen" asks the engine to KEEP a later state of this same document rather
	# than take the copy the panel last persisted — the round that outlived its
	# tab. It is sent only when the engine holds NOBODY's record, which is what
	# an unmount, a tab close or a backend restart leaves behind. While another
	# panel is the holder this is a panel joining a document someone else is
	# working in, and the engine's test — same project identity, higher revision,
	# every session and run still present — cannot tell that from a file copy
	# that merely lags behind (architecture.md §4.3). So it is a plain replace,
	# and two open panels can never be merged into one another.
	var mode := "reopen" if _holder().is_empty() else "replace"
	var loaded := await _send(LOAD_CHANNEL, {"snapshot": record, "mode": mode})
	if generation != _seed_generation:
		return {"ok": false, "code": "stale_revision", "retryable": true,
			"message": "The panel opened a different council while the backend was loading it."}
	if not bool(loaded.get("ok", false)):
		return loaded
	var body: Dictionary = loaded.get("body", {})
	var refused := _refusal(body)
	if not refused.is_empty():
		return refused
	_set_holder(_panel_key)
	# The revision moving is the general signal and each of the three named
	# reasons implies it; they are read as well so a future load that rewrites a
	# record without moving the revision still comes back rather than being lost.
	var reported: Variant = body.get("migrations", [])
	var migrations: Array = reported if reported is Array else []
	if int(body.get("runs_demoted", 0)) > 0 \
			or bool(body.get("recovered", false)) \
			or not migrations.is_empty() \
			or int(body.get("snapshot_revision", 0)) != int(record.get("snapshot_revision", 1)):
		var exported := await _send(EXPORT_CHANNEL, {})
		if bool(exported.get("ok", false)) and _refusal(exported.get("body", {})).is_empty():
			var snapshot: Variant = (exported.get("body", {}) as Dictionary).get("snapshot", null)
			if snapshot is Dictionary:
				return {"ok": true, "snapshot": snapshot}
	return {"ok": true, "snapshot": {}}


## Forget that the engine holds this panel's record — nothing more.
##
## Called whenever the panel adopts a DIFFERENT document (a file opened, a
## project restored, a note reopened): what the engine was seeded with is no
## longer what this panel holds, so the next exchange must seed again.
##
## It deliberately does not touch the lease. The host's own restore order runs
## the file load and its rehydrate first and `_restore_panel_state` a frame
## later, so this fires while THIS panel's exchange is very often still in
## flight; releasing here would hand that running exchange's lease to someone
## else, and the coroutine would finish against an engine seeded by another
## panel. The in-flight exchange releases normally when it ends, and a panel
## that dies mid-exchange is reclaimed by _acquire().
func forget_seed() -> void:
	_seed_generation += 1
	if _holder() == _panel_key:
		_set_holder("")


## The panel is going away for good: forget the seed AND give the lease up, so a
## queued exchange is not left waiting on a tab that no longer exists.
func release_on_unload() -> void:
	forget_seed()
	_release()


## Which panel's record the engine is currently loaded with, by the host's
## per-open-tab registry key. Empty means "nobody's" — the next exchange seeds.
static func lease_holder() -> String:
	return _holder()


## Which panel's exchange currently holds the lease, by panel key. Empty when it
## is free. Distinct from lease_holder(), which is about the RECORD the engine
## was seeded with.
static func lease_taker() -> String:
	var lease := _lease()
	return str(lease.get("taken_by", "")) if bool(lease.get("taken", false)) else ""


## The panel behind the current taker, or null. Exposed so a caller can ask
## whether the lease is held by something still alive.
static func lease_taker_panel():
	return _taken_by_panel(_lease())


static func _holder() -> String:
	return str(_lease().get("holder", ""))


static func _set_holder(key: String) -> void:
	_lease()["holder"] = key


# ---------------------------------------------------------------------------
# One hop over the host broker
# ---------------------------------------------------------------------------

## Emit one request on `channel` and await its reply.
##
## Returns {ok, body} on success, or {ok:false, code, message, retryable}. The
## codes are the protocol's Failure enum (session.schema.json), so a caller can
## put one straight into a reply envelope.
func _send(channel: String, payload: Dictionary) -> Dictionary:
	if _panel == null or not is_instance_valid(_panel):
		return {"ok": false, "code": "internal", "message": "The panel is gone.", "retryable": false}

	var measured := measure(payload)
	if measured > HOST_IPC_PAYLOAD_LIMIT:
		return {"ok": false, "code": "payload_too_large", "retryable": false,
			"message": ("This Council document needs %d units in one message and the host carries %d. "
				+ "Nothing was changed. Move some material into its own Council document.")
				% [measured, HOST_IPC_PAYLOAD_LIMIT]}

	var helper: Node = _panel.get_node_or_null("_MinervaIPC")
	if helper == null:
		return {"ok": false, "code": "internal", "retryable": false,
			"message": "This panel is not registered with the host, so it cannot reach the Council backend."}

	_reply_seq += 1
	var reply_id := "%s-%d" % [_panel_key, _reply_seq]
	_panel.request.emit(channel, payload, reply_id)
	var result: Dictionary = await helper.await_reply(reply_id, HOP_TIMEOUT_MS)

	if not bool(result.get("success", false)):
		var code: String = str(result.get("error_code", ""))
		return {"ok": false, "retryable": code != "permission_denied",
			"code": "timeout" if code == "timeout" else "internal",
			"message": _explain_transport_failure(code, str(result.get("error_message", "")))}

	var body: Variant = result.get("result", {})
	if not (body is Dictionary):
		return {"ok": false, "code": "internal", "retryable": false,
			"message": "The Council backend answered with something that is not a record."}
	return {"ok": true, "body": body}


## The backend answers a refused load or export with {ok:false, error} rather
## than a transport failure, and the broker passes that through as a successful
## dispatch. So a body has to be read for its own verdict; taking the hop's
## success for the backend's would treat "your record was refused" as "loaded".
## Returns {} when the body is a success.
func _refusal(body: Dictionary) -> Dictionary:
	if bool(body.get("ok", true)):
		return {}
	return {"ok": false, "code": "internal", "retryable": false,
		"message": str(body.get("error", "The Council backend refused the record."))}


## What the host will measure this payload as: the serialised argument
## dictionary, wrapper keys included, in the units the broker counts.
static func measure(payload: Dictionary) -> int:
	return JSON.stringify(payload).length()


func _explain_transport_failure(code: String, message: String) -> String:
	match code:
		"plugin_not_running":
			return ("The Council backend is not running, so nothing can be changed right now. "
				+ "Your council is safe in the project; start the plugin and try again.")
		"timeout":
			return "The Council backend did not answer within %d seconds." % HOP_TIMEOUT_SECONDS
		"permission_denied":
			return "The host refused this call: %s" % message
		_:
			return message if not message.is_empty() else "The Council backend could not be reached."


func _failure(request_id: String, revision: int, code: String, message: String,
		retryable: bool) -> Dictionary:
	return {
		"schema_version": 1, "envelope": "reply", "request_id": request_id,
		"ok": false, "snapshot_revision": revision,
		"error": {"code": code, "message": message, "retryable": retryable},
	}


# ---------------------------------------------------------------------------
# The lease
# ---------------------------------------------------------------------------

static func _lease() -> Dictionary:
	if not Engine.has_meta(LEASE_META):
		Engine.set_meta(LEASE_META, {
			"holder": "", "taken": false, "taken_by": "", "taken_ref": null, "waiters": [],
		})
	return Engine.get_meta(LEASE_META)


## True while `panel` is a panel the host still has registered — the broker
## attaches its IPC helper on registration and frees it on unregister, so the
## helper's presence is the host's own answer to "is this panel still live".
static func _is_live(panel) -> bool:
	if panel == null or not is_instance_valid(panel):
		return false
	return (panel as Node).get_node_or_null("_MinervaIPC") != null


func _acquire() -> void:
	var lease := _lease()
	# A lease held by a panel the host no longer has is a lease nobody will ever
	# release: that exchange's coroutine was abandoned when the tab closed or the
	# scene hot-reloaded. Reclaim it rather than wait behind a coroutine that is
	# not running.
	if bool(lease.get("taken", false)) and not _is_live(_taken_by_panel(lease)):
		_hand_off(lease)
	if not bool(lease.get("taken", false)):
		_take(lease, _panel_key, weakref(_panel))
		return
	var waiter := _LeaseWaiter.new()
	waiter.key = _panel_key
	waiter.panel_ref = weakref(_panel)
	(lease["waiters"] as Array).append(waiter)
	await waiter.granted


## Give the lease up. ONLY the panel that holds it may: a caller that does not
## would hand off — or clear — a lease belonging to an exchange still running,
## and that exchange would then finish against an engine seeded by someone else.
func _release() -> void:
	var lease := _lease()
	if str(lease.get("taken_by", "")) != _panel_key:
		return
	_hand_off(lease)


## Pass the lease to the next exchange in line, or leave it free. Unguarded, so
## it can also reclaim a lease whose taker is gone; every guarded path goes
## through _release().
static func _hand_off(lease: Dictionary) -> void:
	var waiters: Array = lease["waiters"]
	while not waiters.is_empty():
		# The lease stays taken and passes straight to the next exchange in line,
		# skipping any whose panel has gone: nothing is awaiting that signal.
		var next: _LeaseWaiter = waiters.pop_front()
		if not _is_live(next.panel_ref.get_ref()):
			continue
		_take(lease, next.key, next.panel_ref)
		next.granted.emit()
		return
	lease["taken"] = false
	lease["taken_by"] = ""
	lease["taken_ref"] = null


static func _take(lease: Dictionary, key: String, panel_ref: WeakRef) -> void:
	lease["taken"] = true
	lease["taken_by"] = key
	lease["taken_ref"] = panel_ref


static func _taken_by_panel(lease: Dictionary):
	var ref = lease.get("taken_ref", null)
	return ref.get_ref() if ref is WeakRef else null
