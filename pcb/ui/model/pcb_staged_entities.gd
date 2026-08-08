extends RefCounted
## StagedEntities — the DRAFT store for board entities (Epoch UX4, DCR
## 019fe07523ca S1). A sibling of the route-candidate workspace, deliberately
## generic and deliberately DUMB: it stages CANONICAL payloads (the exact dict
## a build_*_payload produced, carrying a MINTED persistent id) and it never
## interprets them. The board never learns about staging; this store never
## learns how to mutate the board — accept replays the direct add verb
## (PCBData.add_*_payload), which re-validates against the CURRENT board.
##
## ── validation stance (DCR F11, restated from the review) ─────────────────────
## Invalid-AT-ENTRY is unrepresentable: the staging path runs the same
## build/validate step the direct verb runs BEFORE calling stage(). But the
## LOAD-BEARING gate is accept's re-validation — board drift between stage and
## accept (a net deleted, a layer removed) is fully representable here and
## surfaces as add_*_payload's own named refusal. Entry validation is a UX
## courtesy (fail fast), not the invariant.
##
## ── dispositions (owner ruling 3: minimal first) ──────────────────────────────
## staged → accepted | rejected, both TERMINAL. No pin/freeze — nothing
## regenerates staged entities, so the candidate vocabulary would be words
## without meaning here. "accepted" is stamped ONLY by the accept transaction
## (the same act that writes the board), never independently.
##
## Off-tree plugin: NO class_name; relative preload + duck typing. Payloads are
## already JSON-safe (canonical dicts — {x_mm,y_mm} outlines, string ids).

const _Self := preload("pcb_staged_entities.gd")

## Legal kinds — the entity families the v1 substrate stages. Route proposals
## stay in the routing workspace (a different species: generated answers, not
## staged edits); component moves and deletions are explicitly out of scope
## (DCR S10).
const KINDS := ["zone", "cutout"]

const DISPOSITIONS := ["staged", "accepted", "rejected"]
const TERMINAL_DISPOSITIONS := ["accepted", "rejected"]

## Named refusal codes.
const ERR_UNKNOWN_ENTRY := "staged_entry_not_found"
const ERR_TERMINAL := "staged_entry_terminal"
const ERR_BAD_KIND := "staged_kind_unknown"
const ERR_BAD_PAYLOAD := "staged_payload_invalid"
const ERR_BAD_DISPOSITION := "staged_disposition_invalid"
const ERR_DUPLICATE_ENTITY := "staged_entity_duplicate"

## Emitted on EVERY observable mutation (stage/stamp/restore/load) — the
## render layer redraws on it and the panel's sidecar autosave debounce rides
## it (DCR S9: an MCP-staged entity must persist without Ctrl+S).
signal changed

## staged_id -> entry. Entry shape:
##   {kind: "zone"|"cutout", payload: Dictionary (canonical, minted id),
##    disposition: String, base_board_revision: int, author: "human"|"ai",
##    note: String}
var entries: Dictionary = {}

## Monotonic store-key counter ("staged_N" — the STORE's key, never the
## payload's id; the payload carries its own minted canonical id, which is
## what render/selection/findings/accept all reference). High-water restored
## on load so post-load stages can never collide with loaded keys.
var _counter: int = 0

## The most recent refusal, for callers that only see a false/empty return:
## {"staged_id", "error", "verb"}.
var last_error: Dictionary = {}


func next_id() -> String:
	_counter += 1
	return "staged_%d" % _counter


## STAGE a built payload. The caller (the one build+branch choke point per
## tool — DCR A8) has already run build_*_payload, so `payload` is canonical
## and carries a minted id; this trusts but VERIFIES the cheap halves (kind
## known, payload non-empty with an id) and refuses by name otherwise —
## a malformed stage is a caller bug worth surfacing, not storing.
## Returns the staged_id, or "" (last_error set).
func stage(kind: String, payload: Dictionary, author: String = "human",
		base_board_revision: int = 0, note: String = "") -> String:
	if not (kind in KINDS):
		last_error = {"staged_id": "", "error": ERR_BAD_KIND, "verb": "stage"}
		push_warning("[StagedEntities] stage refused: unknown kind '%s'" % kind)
		return ""
	if payload.is_empty() or str(payload.get("id", "")).is_empty():
		last_error = {"staged_id": "", "error": ERR_BAD_PAYLOAD, "verb": "stage"}
		push_warning("[StagedEntities] stage refused: payload empty or id-less")
		return ""
	# A second LIVE entry for the same canonical id would make
	# staged_id_for_entity ambiguous and the loser's accept refuse on
	# board-duplicate — refuse up front (cheap-half check, cold review F6b).
	if not staged_id_for_entity(str(payload.get("id", ""))).is_empty():
		last_error = {"staged_id": "", "error": ERR_DUPLICATE_ENTITY, "verb": "stage"}
		push_warning("[StagedEntities] stage refused: entity '%s' is already staged" % str(payload.get("id", "")))
		return ""
	if author != "human" and author != "ai":
		push_warning("[StagedEntities] unknown author '%s' recorded as 'human'" % author)
	var sid := next_id()
	entries[sid] = {
		"kind": kind,
		"payload": payload.duplicate(true),
		"disposition": "staged",
		"base_board_revision": int(base_board_revision),
		"author": "ai" if author == "ai" else "human",
		"note": note,
	}
	last_error = {}
	changed.emit()
	return sid


## Deep COPY — the store's entries mutate only through stamp()/restore
## (handing out the live dict would let callers flip a terminal disposition
## in place, silently and signal-less — cold review F5).
func get_entry(staged_id: String) -> Dictionary:
	return (entries.get(staged_id, {}) as Dictionary).duplicate(true)


## LIVE entries (disposition == "staged") — what the composer appends, the
## canvas draws, and the review verbs act on. Returns [{staged_id, ...entry}].
func staged_entries() -> Array:
	var out: Array = []
	for sid in entries:
		var e: Dictionary = entries[sid]
		if str(e.get("disposition", "")) == "staged":
			var rec: Dictionary = e.duplicate(true)
			rec["staged_id"] = str(sid)
			out.append(rec)
	return out


## Live payloads of one kind — the composer's read (DCR S3).
func staged_payloads(kind: String) -> Array:
	var out: Array = []
	for e in staged_entries():
		if str((e as Dictionary).get("kind", "")) == kind:
			out.append(((e as Dictionary).get("payload", {}) as Dictionary).duplicate(true))
	return out


## The staged entry whose PAYLOAD id is `entity_id` ("" kind = any kind) —
## how render/selection resolve a canonical id back to the store.
func staged_id_for_entity(entity_id: String) -> String:
	for sid in entries:
		var e: Dictionary = entries[sid]
		if str(e.get("disposition", "")) != "staged":
			continue
		if str((e.get("payload", {}) as Dictionary).get("id", "")) == entity_id:
			return str(sid)
	return ""


## Stamp a TERMINAL disposition. `accepted` may only be stamped by the accept
## transaction (the caller that just ran add_*_payload successfully — this
## store cannot verify that, but the one-caller rule is enforced at review;
## the stamp is deliberately not public-API-named "accept" to discourage
## casual use). Refuses by name on unknown/terminal entries.
##
## HISTORY PAIRING IS MANDATORY (cold review F3): every terminal stamp must be
## wrapped by the caller as attach_staged_snapshot() → [board write, accept
## only] → stamp → save_to_history. A BARE stamp is a latent clobber: every
## later board snapshot carries the full disposition map, so undoing any
## UNRELATED edit would restore the pre-stamp disposition and revive the
## ghost. This is why terminal re-opening is legal through
## restore_dispositions (undo of the PAIRED entry must return the ghost) but
## refused here.
func stamp(staged_id: String, disposition: String, verb: String) -> bool:
	if not (disposition in TERMINAL_DISPOSITIONS):
		last_error = {"staged_id": staged_id, "error": ERR_BAD_DISPOSITION, "verb": verb}
		return false
	var e: Dictionary = get_entry(staged_id)
	if e.is_empty():
		last_error = {"staged_id": staged_id, "error": ERR_UNKNOWN_ENTRY, "verb": verb}
		push_warning("[StagedEntities] %s refused: no entry '%s'" % [verb, staged_id])
		return false
	if str(e.get("disposition", "")) in TERMINAL_DISPOSITIONS:
		last_error = {"staged_id": staged_id, "error": ERR_TERMINAL, "verb": verb}
		push_warning("[StagedEntities] %s refused: '%s' is already %s" % [verb, staged_id, str(e.get("disposition", ""))])
		return false
	e["disposition"] = disposition
	entries[staged_id] = e
	last_error = {}
	changed.emit()
	return true


## See stamp(): the caller MUST pair this with a history entry
## (attach_staged_snapshot before, save_to_history after) or undo of any
## unrelated edit will silently un-reject. Station 5's reject verb owns that
## transaction; nothing may call this bare.
func reject(staged_id: String) -> bool:
	return stamp(staged_id, "rejected", "reject")


# ── bucket-9 history participation (DCR F8) ───────────────────────────────────
# The SAME snapshot/restore contract the routing workspace's bucket-8 delegate
# keeps: dispositions only (payloads are immutable once staged), so a board
# undo that reverts an accept restores the entry to "staged" and its ghost
# returns. Restore writes RAW (it is a restore, not a verb) and emits once.

func snapshot_dispositions() -> Dictionary:
	var out: Dictionary = {}
	for sid in entries:
		out[str(sid)] = str((entries[sid] as Dictionary).get("disposition", "staged"))
	return out


func restore_dispositions(snap: Dictionary) -> Array:
	var moved: Array = []
	for sid in snap:
		var e: Dictionary = get_entry(str(sid))
		if e.is_empty():
			continue
		var want := str(snap[sid])
		if not (want in DISPOSITIONS):
			continue
		if str(e.get("disposition", "")) == want:
			continue
		e["disposition"] = want
		entries[str(sid)] = e
		moved.append(str(sid))
	if not moved.is_empty():
		changed.emit()
	return moved


# ── serialisation (the routing sidecar's "staged_entities" section, DCR S9) ───

func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for sid in entries:
		out[str(sid)] = (entries[sid] as Dictionary).duplicate(true)
	return {"entries": out, "counter": _counter}


## NOTE for the persistence station: this emits `changed` unconditionally —
## the panel's load path must call it inside its _restoring gate or opening
## a board will dirty the tab (cold review F7).
func load_from_dict(data: Dictionary) -> void:
	entries.clear()
	var raw: Dictionary = data.get("entries", {}) if data.get("entries", {}) is Dictionary else {}
	var live_ids: Dictionary = {}
	for sid in raw:
		if not (raw[sid] is Dictionary):
			continue
		var e: Dictionary = (raw[sid] as Dictionary).duplicate(true)
		# Tolerant restore: unknown kinds/dispositions quarantine the ENTRY
		# (skipped, warned), never the store — a hand-edited sidecar cannot
		# poison the rest, and accept re-validates everything anyway.
		if not (str(e.get("kind", "")) in KINDS):
			push_warning("[StagedEntities] dropped entry '%s' with unknown kind '%s'" % [str(sid), str(e.get("kind", ""))])
			continue
		if not (str(e.get("disposition", "")) in DISPOSITIONS):
			e["disposition"] = "staged"
		# Codex UX4 F4: the load path enforces the SAME invariants stage()
		# refuses at the front door — an id-less payload is unaddressable
		# (dropped), and at most ONE LIVE entry may resolve any canonical id
		# (a second live twin would make staged_id_for_entity/selection/
		# accept ambiguous; first wins, later twins dropped with a warning).
		# Terminal duplicates are legal audit (reject-then-restage).
		var pid := str((e.get("payload", {}) as Dictionary).get("id", "")) \
			if e.get("payload", {}) is Dictionary else ""
		if pid.is_empty():
			push_warning("[StagedEntities] dropped entry '%s': payload empty or id-less" % str(sid))
			continue
		if str(e.get("disposition", "")) == "staged":
			if live_ids.has(pid):
				push_warning("[StagedEntities] dropped entry '%s': a live entry for '%s' already loaded" % [str(sid), pid])
				continue
			live_ids[pid] = true
		e["base_board_revision"] = int(e.get("base_board_revision", 0))
		entries[str(sid)] = e
	# High-water counter: max of stored counter and the largest staged_N key.
	_counter = int(data.get("counter", 0))
	for sid in entries:
		_counter = maxi(_counter, _suffix_num(str(sid)))
	changed.emit()


static func from_dict(data: Dictionary):
	var s := _Self.new()
	s.load_from_dict(data)
	return s


static func _suffix_num(id: String) -> int:
	var parts := id.split("_")
	if parts.size() < 2:
		return 0
	return int(parts[parts.size() - 1])


## Anything worth persisting? (The sidecar's zero-payload delete rule reads
## this beside the candidate count — DCR S9/F5b.)
func is_empty() -> bool:
	return entries.is_empty()


# ── the effective draft board (DCR S3 — ONE composer, per-purpose content) ────

## The purposes a draft board may be composed FOR. Both append staged ZONES
## only today; the purpose argument is the gate that keeps any future
## divergence at THIS one site and gives an unknown consumer a refusal
## instead of a guess.
const COMPOSE_PURPOSES := ["route", "geometric"]

## Compose the EFFECTIVE DRAFT BOARD: a fresh canonical dict = the real board
## plus the LIVE staged entities the given purpose may see. This is the ONE
## union (A8): no consumer appends staged content to a board dict privately —
## grep for callers of staged_payloads to prove it.
##
##   "route"     — staged ZONES appended (a staged keepout detours a draft
##                 propose through the shipped obstacle path,
##                 route_bridge._keepout_obstacle).
##   "geometric" — staged ZONES appended (gc7 zone-clearance findings against
##                 proposed copper). No panel-side consumer yet — the propose
##                 reply's geometric summary is computed worker-side from the
##                 SAME composed "route" request, so A3(b) rides that dict.
##
## CUTOUTS ARE NEVER COMPOSED, for any purpose: compile hard-refuses a
## non-empty cutouts list ("authorable, not compilable" — board.go doctrine)
## and routing ignores REAL cutouts too, so exclusion is consistency. A staged
## cutout's whole v1 power is review-before-land (ghost + accept/reject +
## persistence).
##
## Fail-safe direction: an unknown purpose or an absent/duck-typing-less store
## composes NOTHING (plain deep copy, warned) — draft content leaking into a
## real-board consumer is the dangerous direction; omitting drafts never is.
## The input dict is never mutated. The result is request-scoped and must
## never be serialized or fed to any cache keyed to the REAL board (A9/K5).
static func effective_draft_board(board_dict: Dictionary, staged_store, purpose: String) -> Dictionary:
	var out: Dictionary = board_dict.duplicate(true)
	if not (purpose in COMPOSE_PURPOSES):
		push_warning("[StagedEntities] effective_draft_board: unknown purpose '%s' — composed nothing" % purpose)
		return out
	if staged_store == null or not staged_store.has_method("staged_payloads"):
		return out
	var staged_zones: Array = staged_store.staged_payloads("zone")
	if staged_zones.is_empty():
		return out
	var zones: Array = out.get("zones", []) if out.get("zones", null) is Array else []
	# Id-dedupe against the board's OWN zones (cold review st.3 F2): two-store
	# drift — accept landed the zone but the sidecar autosave never did
	# (crash), so a reload restores the entry as live-staged — would otherwise
	# compose a request with duplicate zone ids, making worker findings that
	# reference zone ids ambiguous. The board's copy wins; the drifted entry
	# still surfaces honestly at accept (duplicate-id refusal).
	var board_zone_ids := {}
	for z in zones:
		if z is Dictionary:
			board_zone_ids[str((z as Dictionary).get("id", ""))] = true
	for z in staged_zones:
		if board_zone_ids.has(str((z as Dictionary).get("id", ""))):
			continue
		zones.append(z)
	out["zones"] = zones
	return out
