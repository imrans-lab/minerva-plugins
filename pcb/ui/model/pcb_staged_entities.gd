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
## ── dispositions (owner ruling 3: minimal first; amended epoch GA) ────────────
## staged → accepted | rejected, both TERMINAL. "accepted" is stamped ONLY by
## the accept transaction (the same act that writes the board), never
## independently.
##
## FROZEN (epoch GA, DCR 019ffc52a541, acceptance check K7) is a fourth
## disposition and is NOT terminal — staged ⇄ frozen, and either may still be
## accepted or rejected directly. The original ruling declined it on the
## grounds that "nothing regenerates staged entities, so the candidate
## vocabulary would be words without meaning here". That reasoning held while
## staged entities were inert, and stopped holding at epoch OFC: OFC-3 made
## route candidates preview against a PLACEMENT ghost's pose, so a live pose
## now steers generated work. Freezing a placement means THE POSE IS SETTLED —
## update_placement_target refuses on it — so a candidate routed against that
## pose cannot be invalidated by a later drag.
##
## Freeze is PLACEMENT-ONLY, deliberately. Zone and cutout payloads are already
## immutable once staged (there is no Update verb for them) and nothing
## regenerates against them, so for those kinds the original reasoning is
## untouched and freeze would still be a word without meaning.
##
## LIVE = staged OR frozen. That is the set the composer appends, the canvas
## draws, and the review verbs act on; see staged_entries().
##
## Off-tree plugin: NO class_name; relative preload + duck typing. Payloads are
## already JSON-safe (canonical dicts — {x_mm,y_mm} outlines, string ids).

const _Self := preload("pcb_staged_entities.gd")

## Legal kinds — the entity families the v1 substrate stages. Route proposals
## stay in the routing workspace (a different species: generated answers, not
## staged edits). Component DELETIONS remain out of scope (DCR S10).
##
## "placement" (SPIKE 019ff8615fbe — placement-coworking): a proposed component
## MOVE, {component_id, from{...}, to{...}}. Unlike zone/cutout its accept does
## not ADD an entity — it applies a move (PCBData.add_placement_payload). It is
## also the one kind whose payload is MUTABLE while live (the ghost is
## draggable; dragging IS the Update of the CRUD cycle under ratification) —
## see update_placement_target for the deliberate breach of the
## payloads-immutable rule and its undo consequence.
const KINDS := ["zone", "cutout", "placement"]

const DISPOSITIONS := ["staged", "accepted", "rejected", "frozen"]
const TERMINAL_DISPOSITIONS := ["accepted", "rejected"]

## LIVE dispositions — the entry is still in play: it renders, it composes into
## the effective draft board, and the review verbs act on it. Every predicate
## in this file that used to compare against the literal "staged" tests THIS
## instead, so adding "frozen" could not silently drop a frozen ghost out of
## the composer, the canvas or the MCP list (the eleven consumers of
## staged_entries()/staged_payloads() are deliberately left unchanged).
const LIVE_DISPOSITIONS := ["staged", "frozen"]

## Named refusal codes.
const ERR_UNKNOWN_ENTRY := "staged_entry_not_found"
const ERR_TERMINAL := "staged_entry_terminal"
const ERR_BAD_KIND := "staged_kind_unknown"
const ERR_BAD_PAYLOAD := "staged_payload_invalid"
const ERR_BAD_DISPOSITION := "staged_disposition_invalid"
const ERR_DUPLICATE_ENTITY := "staged_entity_duplicate"
## The pose of a FROZEN placement is settled — that is what freezing bought.
## Revising it would silently invalidate any route candidate proposed against
## that pose, so the edit is refused BY NAME rather than quietly winning.
const ERR_FROZEN := "staged_entry_frozen"
## Freeze answers a question only a placement can ask (see the dispositions
## note at the top): zone/cutout payloads are already immutable and nothing
## regenerates against them.
const ERR_NOT_FREEZABLE := "staged_kind_not_freezable"

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
	# Codex 1182 F4: one LIVE placement per component is a STORE invariant,
	# not a caller convention — two live moves of the same part make review,
	# render and sequential accepts ambiguous. Terminal audit entries stay
	# legal (reject-then-repropose).
	if kind == "placement":
		var comp_id := str(payload.get("component_id", ""))
		if comp_id.is_empty():
			last_error = {"staged_id": "", "error": ERR_BAD_PAYLOAD, "verb": "stage"}
			push_warning("[StagedEntities] stage refused: placement without component_id")
			return ""
		if not live_placement_for_component(comp_id).is_empty():
			last_error = {"staged_id": "", "error": ERR_DUPLICATE_ENTITY, "verb": "stage"}
			push_warning("[StagedEntities] stage refused: component '%s' already has a live move ghost" % comp_id)
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


## Is this disposition still in play? "staged" and "frozen" both are — a frozen
## entry has settled its pose, not left the workspace. Kept as one predicate so
## the live/terminal split is decided in exactly one place.
static func is_live_disposition(disposition: String) -> bool:
	return disposition in LIVE_DISPOSITIONS


## LIVE entries (staged OR frozen) — what the composer appends, the canvas
## draws, and the review verbs act on. Returns [{staged_id, ...entry}].
## Callers that must distinguish the two read `disposition` off the record;
## everything that only cares "is this ghost still in play" gets the right
## answer without changing.
func staged_entries() -> Array:
	var out: Array = []
	for sid in entries:
		var e: Dictionary = entries[sid]
		if is_live_disposition(str(e.get("disposition", ""))):
			var rec: Dictionary = e.duplicate(true)
			rec["staged_id"] = str(sid)
			out.append(rec)
	return out


## The FROZEN live entries only — the set whose poses are settled. Callers that
## need the split (a status line, a reviewer's "what is held") read this rather
## than re-deriving the predicate.
func frozen_entries() -> Array:
	var out: Array = []
	for e in staged_entries():
		if str((e as Dictionary).get("disposition", "")) == "frozen":
			out.append(e)
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
		if not is_live_disposition(str(e.get("disposition", ""))):
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


# ── placement-kind helpers (SPIKE 019ff8615fbe) ───────────────────────────────

## The LIVE placement staged for `component_id`, or "" — at most one may be
## live per component (the propose paths check this so a second drag REVISES
## the standing ghost instead of stacking a twin).
func live_placement_for_component(component_id: String) -> String:
	for e in staged_entries():
		var entry: Dictionary = e
		if str(entry.get("kind", "")) != "placement":
			continue
		if str((entry.get("payload", {}) as Dictionary).get("component_id", "")) == component_id:
			return str(entry.get("staged_id", ""))
	return ""


## Move a LIVE placement's TARGET pose (the Update of the CRUD cycle: ghost
## drag, the rotate arcs, and the MCP update verb all land here). THE RULE
## (P1, ratified sheet D1/B3): a live proposal's target pose is SCRATCH, not
## record — it may be revised freely by either party until a terminal verdict,
## and pose edits carry NO history. Bucket-9 snapshots stay DISPOSITIONS ONLY:
## undo revives/retires whole ghosts (the accept/reject acts, which ARE
## record) and never replays pose edits. This is the ONE exception to the
## store's payloads-immutable stance, legal ONLY for the "placement" kind and
## ONLY through this method — zone/cutout payloads stay frozen at stage time.
## `note`: null = unchanged; any String REPLACES the note, and "" CLEARS it
## (Codex 1182 F7 — the advertised clear semantics).
func update_placement_target(staged_id: String, to_x_mm: float, to_y_mm: float,
		to_rotation_deg: float, note = null) -> bool:
	var e: Dictionary = get_entry(staged_id)
	if e.is_empty():
		last_error = {"staged_id": staged_id, "error": ERR_UNKNOWN_ENTRY, "verb": "update_placement"}
		return false
	if str(e.get("disposition", "")) in TERMINAL_DISPOSITIONS:
		last_error = {"staged_id": staged_id, "error": ERR_TERMINAL, "verb": "update_placement"}
		return false
	# THE TEETH OF FREEZE (K7): a frozen pose is settled, and a route candidate
	# may already have been proposed against it. Silently accepting the drag
	# would invalidate that candidate without saying so — the exact fail-open
	# this disposition exists to close. Unfreeze first, deliberately.
	if str(e.get("disposition", "")) == "frozen":
		last_error = {"staged_id": staged_id, "error": ERR_FROZEN, "verb": "update_placement"}
		push_warning("[StagedEntities] update_placement refused: '%s' is frozen — unfreeze to revise its pose" % staged_id)
		return false
	if str(e.get("kind", "")) != "placement":
		last_error = {"staged_id": staged_id, "error": ERR_BAD_KIND, "verb": "update_placement"}
		return false
	var payload: Dictionary = e.get("payload", {})
	payload["to"] = {"x_mm": to_x_mm, "y_mm": to_y_mm, "rotation_deg": to_rotation_deg}
	e["payload"] = payload
	if note != null:
		e["note"] = str(note)
	entries[staged_id] = e
	last_error = {}
	changed.emit()
	return true


## FREEZE a live placement: settle its pose so a route candidate proposed
## against it cannot be invalidated by a later drag. Legal only for the
## "placement" kind (see the dispositions note at the top of this file), only
## from "staged", and never for a terminal entry.
##
## Freezing does NOT take the ghost out of play: it still renders, still
## composes into the effective draft board, and may still be accepted or
## rejected DIRECTLY without unfreezing first. Requiring an unfreeze before
## accept would be ceremony without meaning — freeze settles the pose, accept
## lands it, and a user who froze a pose because they were happy with it is
## the likeliest person to accept it next.
##
## HISTORY PAIRING IS MANDATORY, exactly as for stamp(): a disposition written
## bare is a latent clobber, because every later board snapshot carries the
## full disposition map and undoing an UNRELATED edit would restore the
## pre-freeze value and silently thaw the pose. The verb layer owns that
## transaction (attach_staged_snapshot → set → save_to_history), the same way
## station 5's reject verb owns reject's. Nothing may call this bare.
func freeze(staged_id: String) -> bool:
	return _set_live_disposition(staged_id, "frozen", "freeze")


## UNFREEZE back to "staged" — the only way a settled pose becomes editable
## again. Same history-pairing obligation as freeze().
func unfreeze(staged_id: String) -> bool:
	return _set_live_disposition(staged_id, "staged", "unfreeze")


## The shared freeze/unfreeze setter. Refuses BY NAME on: unknown entry, a
## terminal entry, a non-placement kind, and a no-op (already in the requested
## disposition) — a verb that silently succeeds without changing anything reads
## as "it worked" to both doorways, so it is refused rather than swallowed.
func _set_live_disposition(staged_id: String, want: String, verb: String) -> bool:
	var e: Dictionary = get_entry(staged_id)
	if e.is_empty():
		last_error = {"staged_id": staged_id, "error": ERR_UNKNOWN_ENTRY, "verb": verb}
		push_warning("[StagedEntities] %s refused: no entry '%s'" % [verb, staged_id])
		return false
	var have := str(e.get("disposition", ""))
	if have in TERMINAL_DISPOSITIONS:
		last_error = {"staged_id": staged_id, "error": ERR_TERMINAL, "verb": verb}
		push_warning("[StagedEntities] %s refused: '%s' is already %s" % [verb, staged_id, have])
		return false
	if str(e.get("kind", "")) != "placement":
		last_error = {"staged_id": staged_id, "error": ERR_NOT_FREEZABLE, "verb": verb}
		push_warning("[StagedEntities] %s refused: kind '%s' is not freezable" % [verb, str(e.get("kind", ""))])
		return false
	if have == want:
		last_error = {"staged_id": staged_id, "error": ERR_BAD_DISPOSITION, "verb": verb}
		push_warning("[StagedEntities] %s refused: '%s' is already %s" % [verb, staged_id, want])
		return false
	e["disposition"] = want
	entries[staged_id] = e
	last_error = {}
	changed.emit()
	return true


## Is this live entry's pose settled? The render layer and both doorways ask
## this rather than string-comparing a disposition they would have to keep in
## sync with this file.
func is_frozen(staged_id: String) -> bool:
	return str((entries.get(staged_id, {}) as Dictionary).get("disposition", "")) == "frozen"


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
		# LIVE, not literally "staged": a frozen entry occupies its canonical id
		# exactly as a staged one does, so it must reserve that id here too —
		# otherwise a reload could seat a live twin beside a frozen ghost and
		# make staged_id_for_entity/selection/accept ambiguous, which is the
		# very thing this gate exists to prevent.
		if is_live_disposition(str(e.get("disposition", ""))):
			if live_ids.has(pid):
				push_warning("[StagedEntities] dropped entry '%s': a live entry for '%s' already loaded" % [str(sid), pid])
				continue
			live_ids[pid] = true
			# Codex 1182 F4, load half: the same one-live-placement-per-
			# component rule stage() enforces — first wins, later twins drop.
			if str(e.get("kind", "")) == "placement":
				var live_comp := str((e.get("payload", {}) as Dictionary).get("component_id", ""))
				if live_comp.is_empty() or live_ids.has("placement@" + live_comp):
					push_warning("[StagedEntities] dropped entry '%s': live placement for component '%s' already loaded" % [str(sid), live_comp])
					continue
				live_ids["placement@" + live_comp] = true
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

## The purposes a draft board may be composed FOR. Both append staged ZONES and
## apply staged PLACEMENTS today; the purpose argument is the gate that keeps
## any future divergence at THIS one site and gives an unknown consumer a
## refusal instead of a guess.
const COMPOSE_PURPOSES := ["route", "geometric"]

## Compose the EFFECTIVE DRAFT BOARD: a fresh canonical dict = the real board
## plus the LIVE staged entities the given purpose may see. This is the ONE
## union (A8): no consumer appends staged content to a board dict privately —
## grep for callers of staged_payloads to prove it.
##
##   "route"     — staged ZONES appended (a staged keepout detours a draft
##                 propose through the shipped obstacle path,
##                 route_bridge._keepout_obstacle) + staged PLACEMENTS
##                 applied (components virtually AT their ghost targets).
##   "geometric" — staged ZONES appended (gc7 zone-clearance findings against
##                 proposed copper) + staged PLACEMENTS applied. Its production
##                 consumer is PCBPanel.check_draft, which composes the board it
##                 sends over pcb.draft_check (epoch GA, K9); the propose
##                 reply's geometric summary is separately computed worker-side
##                 from the composed "route" request, so A3(b) rides that dict.
##
## PLACEMENTS compose for BOTH purposes deliberately (OFC-2 decision, epoch
## 019ff9421d3f): the whole point of previewing a route or DRC against a
## proposal is judging copper at the pose the ghost PROPOSES, not the pose
## the part still occupies. Only position/rotation move — traces stay at
## their real coordinates, so a preview honestly shows the copper the move
## would strand (flag-don't-fix). A placement naming a component that is no
## longer on the board composes NOTHING for that entry (skip + warn): the
## fail-safe direction is the same as everywhere else in this function —
## omitting draft content is never dangerous, inventing a component is.
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
	if not staged_zones.is_empty():
		var zones: Array = out.get("zones", []) if out.get("zones", null) is Array else []
		# Id-dedupe against the board's OWN zones (cold review st.3 F2):
		# two-store drift — accept landed the zone but the sidecar autosave
		# never did (crash), so a reload restores the entry as live-staged —
		# would otherwise compose a request with duplicate zone ids, making
		# worker findings that reference zone ids ambiguous. The board's copy
		# wins; the drifted entry still surfaces honestly at accept
		# (duplicate-id refusal).
		var board_zone_ids := {}
		for z in zones:
			if z is Dictionary:
				board_zone_ids[str((z as Dictionary).get("id", ""))] = true
		for z in staged_zones:
			if board_zone_ids.has(str((z as Dictionary).get("id", ""))):
				continue
			zones.append(z)
		out["zones"] = zones
	var staged_placements: Array = staged_store.staged_payloads("placement")
	if not staged_placements.is_empty():
		var comps: Array = out.get("components", []) if out.get("components", null) is Array else []
		var comp_by_ref := {}
		for c in comps:
			if c is Dictionary:
				comp_by_ref[str((c as Dictionary).get("ref", ""))] = c
		for p in staged_placements:
			if not (p is Dictionary):
				continue
			var pl: Dictionary = p
			var comp_id := str(pl.get("component_id", ""))
			var to: Variant = pl.get("to")
			if not comp_by_ref.has(comp_id) or not (to is Dictionary):
				# Two-store drift again, placement flavor: the component was
				# deleted after the ghost was staged (or the payload is
				# malformed). Compose NOTHING for this entry; accept's own
				# author/exists gate reports it honestly when acted on.
				push_warning("[StagedEntities] effective_draft_board: staged placement '%s' names component '%s' not on the board — composed nothing for it" % [
					str(pl.get("id", "")), comp_id])
				continue
			# The store's one-live-ghost-per-component invariant means at most
			# one entry ever reaches a given ref here. Only the pose moves:
			# pins are component-local (they ride along), traces are absolute
			# (they deliberately do NOT).
			var comp: Dictionary = comp_by_ref[comp_id]
			var to_d: Dictionary = to
			comp["x_mm"] = float(to_d.get("x_mm", comp.get("x_mm", 0.0)))
			comp["y_mm"] = float(to_d.get("y_mm", comp.get("y_mm", 0.0)))
			comp["rotation_deg"] = float(to_d.get("rotation_deg", comp.get("rotation_deg", 0.0)))
	return out
