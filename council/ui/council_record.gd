extends RefCounted

## The record the Council panel holds, and the only place that decides what a
## document handed to the panel actually is.
##
## Council's durable state is one `council_project_snapshot`
## (schemas/project_snapshot.schema.json). The wrapper persists it and re-serves
## it; it never edits one — mutations belong to the backend engine, which mints
## every revision (architecture.md §3). The two exceptions this class allows are
## `view`, which is user-intent state no engine has an opinion about, and
## adopting a whole snapshot the engine returned.
##
## Unrecognised documents are the other half of the job. A panel that replaced
## an unknown file with an empty council would destroy it on the next Ctrl+S,
## because the same hook feeds both the file write and the project's
## `__panel_state`. So a document this class does not recognise is kept as bytes
## and handed straight back on save, and the panel refuses to edit while it
## holds one.

const SCHEMA_VERSION := 1
const RECORD_KIND := "council_project_snapshot"

## The oldest record shape the engine still has a migration for
## (internal/contract/migrate.go). A document between this and SCHEMA_VERSION is
## OPENED rather than preserved as unreadable: seeding the engine migrates it,
## and the migrated form comes back through the same path a demoted one does. A
## document from a NEWER version is still refused — guessing at a shape the
## invariants were not written for is how a council gets quietly truncated.
const OLDEST_MIGRATABLE_SCHEMA_VERSION := 0

## Keys the host adds to a document on the file-open path and which are not part
## of the record: Editor.gd._load_plugin_scene_file (Editor.gd:1291-1299) builds
## `{"file_path": path}` and merges the parsed JSON into it, or sets `raw_text`
## when the body is not a JSON object.
const HOST_DOCUMENT_KEYS := ["file_path", "raw_text"]

## The save payload key the host writes verbatim as raw bytes instead of
## re-serialising as JSON: Editor.gd:1727 hands the payload to
## PluginScenePanelHost.save_file, which writes `_bytes` as a buffer
## (PluginScenePanelHost.gd:246-250) and otherwise stringifies the whole
## dictionary (:254). It is how an unreadable document survives a save
## unchanged.
const RAW_BYTES_KEY := "_bytes"

## The same bytes, base64-encoded, for the OTHER consumer of the save payload.
##
## The file write takes RAW_BYTES_KEY and ignores every other key. The project
## write takes the same dictionary through JSON.stringify (vboxEditor.gd:494-499 →
## ProjectPackage.gd:303), and Godot serialises a PackedByteArray as a QUOTED
## STRING of its str() form — "[137, 80, …]" — which parses back as a String,
## not bytes. A restore that only knew the PackedByteArray shape would find
## nothing, treat the wrapper dictionary itself as "the original document", and
## overwrite the user's file on the next save: exactly the loss this whole path
## exists to prevent. So the payload carries both encodings and the restore
## prefers this one.
const RAW_BYTES_BASE64_KEY := "_bytes_base64"

## Sibling of RAW_BYTES_KEY carrying why the panel could not read the document.
## The host ignores it on the file path (RAW_BYTES_KEY alone decides the write),
## and it is what carries the explanation through a project round-trip.
const UNREADABLE_REASON_KEY := "_council_unreadable"

## The acknowledged record. Replaced wholesale — by a load, a note restore, or
## the snapshot the engine returns — and otherwise read-only.
var _snapshot: Dictionary = empty_snapshot()

## The bytes of a document the panel could not read, kept so a save writes them
## back unchanged. Empty whenever the panel holds a real council.
var _foreign_bytes: PackedByteArray = PackedByteArray()

## Why the document could not be read, in a sentence a user can act on.
var _foreign_reason: String = ""


## A brand-new, untitled council: what a fresh tab holds before anything is in
## it.
##
## It is written at the OLDEST migratable version and carries no `project_id`,
## which is deliberate. `project_id` is required by
## project_snapshot.schema.json and is minted by the engine's migration ladder;
## a wrapper that minted one would be a second writer of an identity that must
## be unique, and claiming the current schema_version while missing a required
## field would be a record the engine refuses. Declaring the version it really
## is leaves the ladder as the only path that produces a current record — the
## first seed migrates this into one, exactly as it migrates a document written
## by an older Council.
static func empty_snapshot() -> Dictionary:
	return {
		"schema_version": OLDEST_MIGRATABLE_SCHEMA_VERSION,
		"record_kind": RECORD_KIND,
		"snapshot_revision": 1,
		"definitions": [],
		"sessions": [],
	}


## True when `candidate` is a Council snapshot in the shape this build writes.
## This is the test for a record coming back FROM the engine, which always
## answers in the current shape; a reply in any other is a malformed reply and
## must not overwrite a good record.
static func is_council_snapshot(candidate: Variant) -> bool:
	if not (candidate is Dictionary):
		return false
	var d: Dictionary = candidate
	if str(d.get("record_kind", "")) != RECORD_KIND:
		return false
	return int(d.get("schema_version", 0)) == SCHEMA_VERSION


## True when `candidate` is a Council document this build can OPEN — the current
## shape, or an older one the engine has a migration for. It is deliberately
## wider than is_council_snapshot: a document the engine can migrate must not be
## preserved as an unreadable foreign file, because then the user's own council
## would open as a wall of text saying Council will not touch it.
static func is_migratable_council_document(candidate: Variant) -> bool:
	if not (candidate is Dictionary):
		return false
	var d: Dictionary = candidate
	if str(d.get("record_kind", "")) != RECORD_KIND:
		return false
	var version := int(d.get("schema_version", 0))
	return version >= OLDEST_MIGRATABLE_SCHEMA_VERSION and version <= SCHEMA_VERSION


# ---------------------------------------------------------------------------
# Reading the held record
# ---------------------------------------------------------------------------

func snapshot() -> Dictionary:
	return _snapshot.duplicate(true)


func revision() -> int:
	return int(_snapshot.get("snapshot_revision", 1))


func is_unreadable() -> bool:
	return not _foreign_bytes.is_empty()


func unreadable_reason() -> String:
	return _foreign_reason


# ---------------------------------------------------------------------------
# Replacing the held record
# ---------------------------------------------------------------------------

## Adopt a snapshot the engine produced. Returns false (and changes nothing) if
## it is not a snapshot this build speaks, so a malformed backend reply cannot
## overwrite a good record.
func adopt(candidate: Variant) -> bool:
	if not is_council_snapshot(candidate):
		return false
	_snapshot = (candidate as Dictionary).duplicate(true)
	_foreign_bytes = PackedByteArray()
	_foreign_reason = ""
	return true


## Take whatever the host handed over on a file open, a project restore, or a
## note restore, and end in exactly one of three states: an empty council, a
## council, or an unreadable document preserved byte-for-byte.
##
## `document` is the host's shape, not the record's: the file-open path merges
## the parsed JSON into `{"file_path": path}`, or sets `raw_text` for a body
## that is not a JSON object. A project restore passes back whatever
## `save_payload()` returned, which for an unreadable document is the preserved
## bytes — read from the base64 sibling, because JSON does not carry a
## PackedByteArray (see RAW_BYTES_BASE64_KEY).
func adopt_document(document: Variant) -> void:
	_snapshot = empty_snapshot()
	_foreign_bytes = PackedByteArray()
	_foreign_reason = ""
	if not (document is Dictionary):
		return

	var doc: Dictionary = (document as Dictionary).duplicate(true)
	var file_path := str(doc.get("file_path", ""))
	var raw_text := str(doc.get("raw_text", ""))
	for key in HOST_DOCUMENT_KEYS:
		doc.erase(key)

	# A document preserved by an earlier save, coming back through the project.
	if doc.has(RAW_BYTES_BASE64_KEY) or doc.has(RAW_BYTES_KEY):
		var carried := _to_bytes(doc.get(RAW_BYTES_BASE64_KEY, doc.get(RAW_BYTES_KEY, null)))
		if not carried.is_empty():
			_foreign_bytes = carried
			_foreign_reason = str(doc.get(UNREADABLE_REASON_KEY,
				"Council could not read this document."))
			return

	# Nothing at all: a new, untitled council. An empty file opens the same way.
	if doc.is_empty() and raw_text.strip_edges().is_empty():
		return

	# An older document is held as it is and handed to the engine unchanged; the
	# migrated form comes back from the seed and replaces it (council_backend.gd
	# `_ensure_seeded`). Nothing is rewritten here — migration is the engine's,
	# like every other rewrite of the record.
	if is_migratable_council_document(doc):
		_snapshot = doc
		return

	# Something is there and it is not a council. Keep it exactly as it is.
	_foreign_bytes = _original_bytes(file_path, raw_text, doc)
	_foreign_reason = _describe_unreadable(doc, raw_text)


## Write the user's view intent into the record. This is the one field the
## wrapper owns (architecture.md §3): it advances no revision, because no
## engine derives anything from it, and a snapshot without it opens correctly.
## Returns false when the panel is holding an unreadable document.
func set_view(view: Dictionary) -> bool:
	if is_unreadable():
		return false
	if view.is_empty():
		_snapshot.erase("view")
	else:
		_snapshot["view"] = view.duplicate(true)
	return true


# ---------------------------------------------------------------------------
# Handing the record back to the host
# ---------------------------------------------------------------------------

## What `_on_panel_save_request()` returns. The host uses this same dictionary
## for two different writes — the tab's file and the project's `__panel_state` —
## so it has to be correct for both.
func save_payload() -> Dictionary:
	if is_unreadable():
		return {
			RAW_BYTES_KEY: _foreign_bytes,
			RAW_BYTES_BASE64_KEY: Marshalls.raw_to_base64(_foreign_bytes),
			UNREADABLE_REASON_KEY: _foreign_reason,
		}
	return _snapshot.duplicate(true)


# ---------------------------------------------------------------------------
# Text derived from the record
# ---------------------------------------------------------------------------

## The one line a plugin_data note carries into a chat turn. A note built from a
## panel is rendered with the image controls, so a caption is all the text a
## provider sees — it names the session rather than describing the widget.
func caption() -> String:
	if is_unreadable():
		return "Council: this document could not be read."
	var sessions: Array = _snapshot.get("sessions", [])
	if sessions.is_empty():
		return "Council: no session yet."
	var session: Dictionary = _selected_session()
	return "Council session on: %s (%s)" % [
		str(session.get("question", "(no question)")),
		str(session.get("status", "unknown")),
	]


## The context a session hands to a chat or to a render-for-LLM caller: the
## question, the state, and the text of the contributions named in `selection`
## (all complete contributions when the selection is empty). One derivation
## feeds both callers, so what the user sends and what a provider reads can
## never be two different summaries.
func context_text(session_id: String, selection: PackedStringArray) -> String:
	var session: Dictionary = find_session(session_id)
	if session.is_empty():
		return ""
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Council session: %s" % str(session.get("question", "")))
	lines.append("Status: %s" % str(session.get("status", "unknown")))
	for run_v in session.get("runs", []):
		var run: Dictionary = run_v if run_v is Dictionary else {}
		var parts: Array = (run.get("contributions", []) as Array).duplicate()
		if run.get("synthesis", null) is Dictionary:
			parts.append(run["synthesis"])
		for c_v in parts:
			var c: Dictionary = c_v if c_v is Dictionary else {}
			var cid := str(c.get("contribution_id", ""))
			var wanted := cid in selection if not selection.is_empty() \
				else str(c.get("status", "")) == "complete"
			if not wanted:
				continue
			var text := str(c.get("text", "")).strip_edges()
			if text.is_empty():
				continue
			lines.append("")
			lines.append("[%s / %s] %s" % [
				str(c.get("seat_id", "?")), str(c.get("member_id", "?")), text])
	return "\n".join(lines)


## The session `session_id` names, or the selected/last one when it is empty.
func find_session(session_id: String) -> Dictionary:
	if session_id.is_empty():
		return _selected_session()
	for s_v in _snapshot.get("sessions", []):
		var s: Dictionary = s_v if s_v is Dictionary else {}
		if str(s.get("session_id", "")) == session_id:
			return s
	return {}


# ---------------------------------------------------------------------------
# Private
# ---------------------------------------------------------------------------

## The session the view points at, falling back to the last one. Never a
## session picked by which tab is focused — the panel has no such notion.
func _selected_session() -> Dictionary:
	var sessions: Array = _snapshot.get("sessions", [])
	if sessions.is_empty():
		return {}
	var view: Dictionary = _snapshot.get("view", {}) if _snapshot.get("view", {}) is Dictionary else {}
	var selected := str(view.get("selected_session_id", ""))
	for s_v in sessions:
		var s: Dictionary = s_v if s_v is Dictionary else {}
		if str(s.get("session_id", "")) == selected:
			return s
	var last = sessions[sessions.size() - 1]
	return last if last is Dictionary else {}


## The bytes to hand back on save. The file itself is preferred, because that is
## the only source that is exactly what the user had; the parsed forms are
## fallbacks for a document that never came from a file.
func _original_bytes(file_path: String, raw_text: String, parsed: Dictionary) -> PackedByteArray:
	if not file_path.is_empty() and FileAccess.file_exists(file_path):
		var bytes := FileAccess.get_file_as_bytes(file_path)
		if not bytes.is_empty():
			return bytes
	if not raw_text.is_empty():
		return raw_text.to_utf8_buffer()
	return JSON.stringify(parsed, "\t").to_utf8_buffer()


## The bytes behind either encoding the save payload carries: the
## PackedByteArray itself when the dictionary never left the process, and the
## base64 String when it came back through the project's JSON.
func _to_bytes(value: Variant) -> PackedByteArray:
	if value is PackedByteArray:
		return value
	if value is String and not (value as String).is_empty():
		return Marshalls.base64_to_raw(value)
	return PackedByteArray()


## Why the panel will not edit this document, in the terms the user can check.
func _describe_unreadable(parsed: Dictionary, raw_text: String) -> String:
	if not raw_text.is_empty():
		return ("This file is not a Council document — its contents are not JSON. "
			+ "Council will not change it: saving writes the file back exactly as it was.")
	if str(parsed.get("record_kind", "")) == RECORD_KIND:
		return ("This Council document was written by a newer version (schema %s; this build reads %d). "
			+ "Council will not change it: saving writes the file back exactly as it was.") % [
				str(parsed.get("schema_version", "?")), SCHEMA_VERSION]
	return ("This file is not a Council document. "
		+ "Council will not change it: saving writes the file back exactly as it was.")
