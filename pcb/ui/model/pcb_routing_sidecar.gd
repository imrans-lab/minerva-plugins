extends RefCounted
## RoutingSidecar — durable, versioned, crash-safe persistence for the routing
## workspace (T2a). Plugin-owned counterpart to the core AnnotationSidecar: it
## MIRRORS that file's shape (atomic tmp→rename write, corrupt-backup on read,
## zero-payload ⇒ delete) but lives in the plugin tree and is reached via a
## relative preload (off-tree plugin: NO class_name).
##
## ── On-disk envelope (<board_path>.routing.json) ──────────────────────────────
##   {
##     "schema_version":     1,             # constant; future/unknown ⇒ quarantine
##     "board_document_id":  "pcbdoc-…",    # stable provenance id (random ONCE)
##     "board_fingerprint":  "<sha256hex>", # coherence token (see below)
##     "board_revision":     <int>,         # provenance only — NOT the coherence
##                                          #   signal (fingerprint is); a board
##                                          #   whose revision advanced but whose
##                                          #   fingerprint is unchanged (ABA:
##                                          #   change→revert) stays COHERENT.
##     "workspace":          <durable dict> # workspace.to_sidecar_dict()
##   }
##
## ── board_fingerprint: what it covers + how it is canonicalised ───────────────
## A deterministic SHA-256 over a CANONICAL serialisation of the routing/DRC-
## relevant board inputs ONLY, drawn from PCBData.to_board_dict():
##   width_mm, height_mm (board outline/size), layers (the layer stack),
##   design_rules, components (+pads), nets, committed traces, committed vias,
##   and mounting_holes (physical routing KEEPOUTS — a hole moved into a
##   candidate's path must stale it, so hole geometry is a coherence input).
## DELIBERATELY EXCLUDED: board name, the routing workspace itself (routing is
## never a fingerprint input — it is the thing being guarded), and any
## transient/selection state. The drawing grid is not listed because it is not
## in the dict at all any more (panel session state, pcb_session_state.gd). The
## 2-layer model is all that exists today (no speculative N-layer fields).
##
## Canonicalisation (see _canonical/_num) makes the hash INVARIANT to:
##   - dict key order (keys are string-sorted),
##   - via list order (vias are canonically sorted before hashing; components/
##     nets/traces already arrive sorted from to_board_dict),
##   - the GDScript int↔float JSON coercion: every number is formatted "%.6f"
##     (int 100 and float 100.0 both → "100.000000"), so a value that reserialises
##     as a float after a disk round-trip hashes identically to its in-memory
##     form. Strings are length-prefixed so no delimiter can collide.

const _Self := preload("pcb_routing_sidecar.gd")
const PcbCopperOwnership := preload("pcb_copper_ownership.gd")

## Current on-disk schema. Bump ONLY on a breaking change (and teach _migrate).
const SCHEMA_VERSION: int = 1
const SIDECAR_SUFFIX: String = ".routing.json"


# ── path / existence / delete ─────────────────────────────────────────────────

## "<board_path>.routing.json" (suffix appended to the FULL filename incl. ext,
## mirroring AnnotationSidecar.sidecar_path_for).
static func sidecar_path_for(board_path: String) -> String:
	return board_path + SIDECAR_SUFFIX


static func has_sidecar(board_path: String) -> bool:
	return FileAccess.file_exists(sidecar_path_for(board_path))


## Delete the sidecar. OK if it existed and was removed, or if absent.
static func delete_sidecar(board_path: String) -> Error:
	var sp := sidecar_path_for(board_path)
	if not FileAccess.file_exists(sp):
		return OK
	var err := DirAccess.remove_absolute(sp)
	if err != OK:
		push_error("[RoutingSidecar] delete failed for %s (error %d)" % [sp, err])
	return err


# ── low-level read / write ────────────────────────────────────────────────────

## Parse the envelope. Returns {} when the file is missing OR unparseable; an
## unparseable (non-dict / bad JSON) file is first backed up to
## <sidecar>.corrupt-<unix> so the board still opens. A syntactically valid dict
## that merely LACKS tokens is returned as-is (that is a quarantine decision the
## caller makes, not corruption).
static func read_envelope(board_path: String) -> Dictionary:
	var sp := sidecar_path_for(board_path)
	if not FileAccess.file_exists(sp):
		return {}
	var f := FileAccess.open(sp, FileAccess.READ)
	if f == null:
		push_error("[RoutingSidecar] cannot open %s (error %d)" % [sp, FileAccess.get_open_error()])
		return {}
	var raw := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		_backup_corrupt(sp)
		return {}
	return parsed as Dictionary


## Atomic write: JSON → <sidecar>.tmp → flush()+close() → rename over target.
## Never leaves a half-written sidecar; a failed rename cleans up the tmp.
static func write_envelope(board_path: String, envelope: Dictionary) -> Error:
	var sp := sidecar_path_for(board_path)
	var tmp := sp + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[RoutingSidecar] cannot open tmp %s (error %d)" % [tmp, FileAccess.get_open_error()])
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(envelope, "\t"))
	f.flush()   # land bytes before the rename
	f.close()
	var err := DirAccess.rename_absolute(tmp, sp)
	if err != OK:
		push_error("[RoutingSidecar] rename %s → %s failed (error %d)" % [tmp, sp, err])
		DirAccess.remove_absolute(tmp)
	return err


# ── high-level save / load (the seam PCBPanel wires) ──────────────────────────

## Bug 01a022b1b7d5: a task carrying a routing_constraint IS payload. The
## corridor an intent authored lives ONLY on its eager task (station 8's
## authoring decision, comment 1028 — never on the annotation; station 9 is
## the consumption side), so deleting the sidecar while such a task is
## unanswered silently evaporates the steering: the annotation survives in
## .annotations.json, the next propose runs unguided. A BARE task is still
## NOT payload — it is fully reconstructible from its hint on the next
## propose, so the zero-payload hygiene (and the persistence suite's
## "zero candidates ⇒ sidecar deleted" pin) stands.
static func _has_constrained_task(durable: Dictionary) -> bool:
	var tasks: Dictionary = durable.get("tasks", {}) if durable.get("tasks", {}) is Dictionary else {}
	for tid in tasks:
		if not (tasks[tid] is Dictionary):
			continue
		var rc: Variant = (tasks[tid] as Dictionary).get("routing_constraint", {})
		if rc is Dictionary and not (rc as Dictionary).is_empty():
			return true
	return false


## Reset a bound staged store (Codex UX4 F1): called on EVERY load path that
## does not load — missing sidecar, unparseable envelope, garbled workspace
## token — so the previous document's drafts can never survive a switch onto
## a board whose own sidecar could not answer.
static func _reset_staged(staged_store) -> void:
	if staged_store != null and staged_store.has_method("load_from_dict"):
		staged_store.load_from_dict({})

## Persist `workspace` beside the board file. ZERO payload ⇒ the sidecar is
## DELETED (mirrors AnnotationSidecar's zero-payload rule) — and "zero
## payload" means NO candidates, NO staged entities (Epoch UX4 station 6, DCR
## S9: an area draft alone keeps the file alive), AND no constraint-carrying
## task (bug 01a022b1b7d5: an unanswered intent's corridor lives only on its
## eager task and must survive the session). `staged_store` is the
## panel's StagedEntities store (optional — existing callers without one keep
## the exact prior candidates-only behavior); its section is written verbatim
## (store.to_dict()) under "staged_entities", absent when the store is empty.
## The board_document_id is carried forward from any existing sidecar at this
## path (so re-saving the SAME file keeps a stable id); a Save-As to a NEW
## path has no sidecar there yet and mints a fresh id for the copy. Returns an
## Error code.
static func save_workspace(board_path: String, workspace, board_dict: Dictionary,
		board_revision: int, staged_store = null) -> Error:
	if board_path.is_empty() or workspace == null:
		return ERR_INVALID_PARAMETER
	var durable: Dictionary = workspace.to_sidecar_dict()
	var cands: Dictionary = durable.get("candidates", {}) if durable.get("candidates", {}) is Dictionary else {}
	var staged_section: Dictionary = {}
	if staged_store != null and staged_store.has_method("to_dict") and not staged_store.is_empty():
		staged_section = staged_store.to_dict()
	if cands.is_empty() and staged_section.is_empty() \
			and not _has_constrained_task(durable):
		return delete_sidecar(board_path)

	# Carry a stable document id forward from an existing sidecar, else mint one.
	var doc_id := ""
	var existing := read_envelope(board_path)
	if not existing.is_empty():
		doc_id = str(existing.get("board_document_id", ""))
	if doc_id.is_empty():
		doc_id = _generate_document_id()

	var envelope := {
		"schema_version": SCHEMA_VERSION,
		"board_document_id": doc_id,
		"board_fingerprint": compute_board_fingerprint_v2(board_dict),
		# Epoch UX3 station 11 cold review F4: fingerprints are now computed
		# over the CANONICAL-SURVIVOR projection (v2) so a promotion's
		# serialize→deserialize round trip — which drops every GD-only key —
		# cannot orphan this sidecar. Version stamped so the loader compares
		# old envelopes with the legacy whole-dict hash they were written with.
		"fingerprint_version": 2,
		"board_revision": int(board_revision),
		"workspace": durable,
	}
	# UX4 S9: additive, absent-when-empty — the frozen-set precedent (a new
	# key inside the envelope, no schema bump; an old loader ignores it, this
	# loader treats absence as an empty store).
	if not staged_section.is_empty():
		envelope["staged_entities"] = staged_section
	return write_envelope(board_path, envelope)


## Load the sidecar into `workspace`, gated by a board-coherence check against
## `current_board_dict` (the just-loaded board's to_board_dict()). NEVER crashes;
## NEVER silently trusts a mismatched/stale/unknown sidecar. Returns a status
## dict {status, candidate_count, reason?, stored_fingerprint?, current_fingerprint?}:
##   "missing"          — no sidecar; workspace untouched.
##   "empty"            — unparseable/corrupt (already backed up); nothing loaded.
##   "loaded_clean"     — fingerprint MATCH; candidates loaded, none marked stale.
##   "quarantine_stale" — future/unknown schema_version OR missing token OR
##                        fingerprint MISMATCH → candidates loaded (if possible)
##                        with ALL validation=stale, dispositions preserved.
## A "loaded_clean" load also runs the RESTORE-TIME OWNERSHIP AUDIT: a
## committed candidate whose recorded copper ids do not resolve on
## THIS board, or resolve to copper on another net, has that claim dropped and is
## uncommitted if nothing provable is left. The per-candidate findings ride back
## as `stale_ownership` (ABSENT when empty), so the caller can surface them —
## silently re-attaching a stale record to whatever now carries that id is
## exactly the false "committed by" this closes. It runs ONLY on the coherent
## path: it is a destructive repair, and a quarantined sidecar is one whose board
## has already been proved different, where "the ids do not resolve" carries no
## information.
static func load_into_workspace(board_path: String, workspace, current_board_dict: Dictionary,
		_current_board_revision: int = 0, staged_store = null) -> Dictionary:
	if workspace == null:
		return {"status": "missing", "candidate_count": 0}
	if not has_sidecar(board_path):
		# UX4 S9: no sidecar means no drafts either — a bound store is RESET so
		# a document switch cannot carry the prior board's drafts across.
		_reset_staged(staged_store)
		return {"status": "missing", "candidate_count": 0}

	var envelope := read_envelope(board_path)
	if envelope.is_empty():
		# has_sidecar was true but the file did not parse → treated as empty.
		# Codex UX4 F1: EVERY non-loading path resets a bound store, not just
		# the missing-sidecar one — an unparseable envelope on a document
		# switch must not leave the PRIOR board's drafts alive over this one.
		_reset_staged(staged_store)
		return {"status": "empty", "candidate_count": 0, "reason": "unparseable"}

	var version := int(envelope.get("schema_version", -1))
	var ws_dict: Variant = envelope.get("workspace", null)
	var stored_fp := str(envelope.get("board_fingerprint", ""))

	# Quarantine triggers that do not depend on the fingerprint.
	var quarantine := false
	var reason := ""
	if version != SCHEMA_VERSION:
		# A future/unknown version cannot be parsed as current. _migrate is the
		# forward hook; for v1 it has nothing to upgrade and returns {} → we still
		# best-effort load the candidates but force them all stale.
		var migrated: Dictionary = _migrate(version, envelope)
		if not migrated.is_empty():
			envelope = migrated
			ws_dict = envelope.get("workspace", null)
			stored_fp = str(envelope.get("board_fingerprint", ""))
		else:
			quarantine = true
			reason = "schema_version %d != %d" % [version, SCHEMA_VERSION]
	if not (ws_dict is Dictionary):
		# Missing/garbled workspace token — nothing coherent to load. Same F1
		# rule as the unparseable path above: a refused load resets the store.
		_reset_staged(staged_store)
		return {"status": "empty", "candidate_count": 0, "reason": "missing workspace token"}
	if stored_fp.is_empty():
		quarantine = true
		if reason.is_empty():
			reason = "missing board_fingerprint token"

	# Load candidates first (so a quarantine can still surface them as stale).
	workspace.load_from_dict(ws_dict as Dictionary)
	var count: int = workspace.candidates.size()

	# UX4 S9 QUARANTINE RULE, stated: staged entries load on EVERY coherent
	# envelope — including fingerprint-mismatch/schema quarantines — because a
	# drifted staged payload is SAFE to carry (it mutates nothing until
	# accept, and accept re-validates against the CURRENT board, refusing by
	# name). Candidates get marked stale below; drafts have no validation
	# channel to mark, their gate is the accept itself. Absent section = empty
	# store (the additive-key contract).
	var staged_count := 0
	if staged_store != null and staged_store.has_method("load_from_dict"):
		var staged_section: Dictionary = envelope.get("staged_entities", {}) \
			if envelope.get("staged_entities", {}) is Dictionary else {}
		staged_store.load_from_dict(staged_section)
		staged_count = staged_store.staged_entries().size()

	if quarantine:
		workspace.mark_all_stale()
		return {"status": "quarantine_stale", "candidate_count": count,
			"staged_count": staged_count, "reason": reason}

	# Fingerprint coherence: recompute from the CURRENT board and compare —
	# with the SAME algorithm the envelope was written with (F4): v2 envelopes
	# compare the canonical-survivor projection; legacy envelopes (no
	# fingerprint_version) compare the whole-dict v1 hash, so every existing
	# sidecar keeps loading clean until its next write upgrades it.
	var fp_version := int(envelope.get("fingerprint_version", 1))
	var current_fp := compute_board_fingerprint_v2(current_board_dict) \
		if fp_version >= 2 else compute_board_fingerprint(current_board_dict)
	if current_fp != stored_fp:
		workspace.mark_all_stale()
		return {
			"status": "quarantine_stale", "candidate_count": count,
			"staged_count": staged_count,
			"reason": "board_fingerprint mismatch",
			"stored_fingerprint": stored_fp, "current_fingerprint": current_fp,
		}

	# COHERENT BOARD ONLY. The audit is a DESTRUCTIVE repair — it edits the
	# ownership records and can uncommit — so it may only run once the
	# fingerprint has proved this is the board the sidecar was written against.
	# On a quarantine the copper legitimately differs (Save-As, an edit between
	# sessions, an unknown schema) and "every id fails to resolve" would mean
	# nothing; mark_all_stale is the honest answer there, and the delete/edit
	# verbs' own pre-check still refuses to attribute copper to a stale claim.
	return _with_ownership({"status": "loaded_clean", "candidate_count": count,
		"staged_count": staged_count, "stored_fingerprint": stored_fp},
		_audit_ownership(workspace, current_board_dict))


## Run the restore-time ownership audit against the board that just loaded.
## Tolerates a workspace that predates the method (duck-typed seam, same as every
## other call in this file).
static func _audit_ownership(workspace, current_board_dict: Dictionary) -> Array:
	if workspace == null or not workspace.has_method("drop_unowned_commit_records"):
		return []
	return workspace.drop_unowned_commit_records(
		PcbCopperOwnership.index_from_dict(current_board_dict))


## ADDITIVE, ABSENT WHEN EMPTY — the rule the rest of this envelope keeps.
static func _with_ownership(status: Dictionary, stale_ownership: Array) -> Dictionary:
	if not stale_ownership.is_empty():
		status["stale_ownership"] = stale_ownership
	return status


# ── schema migration (forward hook) ───────────────────────────────────────────

## Upgrade an older-schema envelope to the CURRENT shape. v1 is the first
## schema, so there is nothing to migrate yet and a FUTURE/unknown version
## cannot be down-migrated → return {} to signal "not parseable as current"
## (the caller then quarantines). Add version-specific upgrade branches here as
## the schema evolves.
static func _migrate(_version: int, _data: Dictionary) -> Dictionary:
	return {}


# ── fingerprint ───────────────────────────────────────────────────────────────

## Deterministic SHA-256 over the DRC/routing-relevant board inputs. See the
## file header for exactly what is covered and how it is canonicalised.
static func compute_board_fingerprint(board_dict: Dictionary) -> String:
	var subset := {
		"width_mm": board_dict.get("width_mm", 0.0),
		"height_mm": board_dict.get("height_mm", 0.0),
		"layers": board_dict.get("layers", []),
		"design_rules": board_dict.get("design_rules", {}),
		"components": board_dict.get("components", []),
		"nets": board_dict.get("nets", []),
		"traces": board_dict.get("traces", []),
		"vias": board_dict.get("vias", []),
		# Mounting holes are physical routing KEEPOUTS — moving/adding one can
		# invalidate a committed candidate's path, so they MUST feed the hash
		# (else a hole edit reads false-clean). Holes are GLOBAL keepouts, so ANY
		# hole change stales every candidate — acceptable and correct.
		"mounting_holes": board_dict.get("mounting_holes", []),
	}
	return _canonical(subset).sha256_text()


## V2 fingerprint (Epoch UX3 station 11, cold review F4): SHA-256 over the
## CANONICAL-SURVIVOR projection of the board — exactly the keys the Go
## serialize→deserialize round trip preserves (internal/board/board.go's
## first-classed json fields; every Extra map is json:"-" and DROPPED). The
## v1 hash covered the whole GD dict, so GD-only session keys (locked,
## graphics, pads enrichment, colors…) fed it — and the first promotion of
## any board carrying one changed the recomputed hash and quarantined the
## sidecar. v2 hashes only what the design of record can actually carry, so
## "the same canonical board" fingerprints identically before and after a
## round trip AND across worker-enrichment differences. The projection is an
## ALLOWLIST on purpose: a new GD-only key defaults to excluded (stable),
## and a new CANONICAL key must be added here deliberately, beside the Go
## struct change that first-classes it.
static func compute_board_fingerprint_v2(board_dict: Dictionary) -> String:
	var dr: Dictionary = board_dict.get("design_rules", {}) if board_dict.get("design_rules", {}) is Dictionary else {}
	# One projection per Hole-shaped list (mounting/pth/npth share the Go
	# struct, so they share the allowlist).
	var hole_keys := ["id", "x_mm", "y_mm", "diameter_mm", "drill_mm", "plated", "annulus_mm"]
	var subset := {
		"width_mm": board_dict.get("width_mm", 0.0),
		"height_mm": board_dict.get("height_mm", 0.0),
		# Origin shifts every coordinate's meaning — routing-relevant
		# (Codex 1056 finding 1).
		"origin": board_dict.get("origin", null),
		"layers": board_dict.get("layers", []),
		"design_rules": _project(dr, ["clearance_mm", "trace_width_mm",
			"via_diameter_mm", "via_drill_mm", "diff_pair_gap_mm", "diff_pair_width_mm"]),
		"components": _project_list(board_dict.get("components", []),
			["ref", "footprint", "value", "x_mm", "y_mm", "rotation_deg", "layer", "pins"]),
		"nets": _project_list(board_dict.get("nets", []), ["name", "pins"]),
		"traces": _project_list(board_dict.get("traces", []),
			["id", "net", "layer", "width_mm", "points"]),
		"vias": _project_list(board_dict.get("vias", []),
			["id", "x_mm", "y_mm", "drill_mm", "diameter_mm", "net", "from_layer", "to_layer", "tented"]),
		# ZONES became routing-relevant in Epoch UX3 station 2 (keepouts are
		# router obstacles now) — a keepout edit MUST stale candidates routed
		# around the old region (Codex 1056 finding 1; v1 never covered them
		# either, but pre-station-2 a keepout board refused to route at all).
		# Pours matter too: fills carve around committed copper.
		"zones": _project_list(board_dict.get("zones", []),
			["id", "kind", "net", "layer", "clearance_mm",
			 "thermal_gap_mm", "thermal_bridge_width_mm", "outline"]),
		# Cutouts are through-board openings — physical keepouts.
		"cutouts": _project_list(board_dict.get("cutouts", []), ["id", "outline"]),
		"mounting_holes": _project_list(board_dict.get("mounting_holes", []), hole_keys),
		# PTH/NPTH board holes share the Hole struct and the same routing
		# relevance as mounting holes (a gap in BOTH v1 and v2 until Codex
		# 1056 finding 1's class fix — Codex's own list missed them too).
		"pth_holes": _project_list(board_dict.get("pth_holes", []), hole_keys),
		"npth_holes": _project_list(board_dict.get("npth_holes", []), hole_keys),
	}
	return _canonical(subset).sha256_text()
	# DELIBERATELY EXCLUDED, so the next reader does not "complete" the list:
	# name/id/version (identity, not routing inputs) and the
	# annotations/route_hints blobs (the sidecars' own content class — hashing
	# them would make the fingerprint self-referential and unstable).


## Keep only `keys` of a dict, ABSENT keys stay absent (matching omitempty —
## a key the GD dict never wrote and a key the round trip dropped read alike).
static func _project(d: Dictionary, keys: Array) -> Dictionary:
	var out: Dictionary = {}
	for k in keys:
		if d.has(k):
			out[k] = d[k]
	return out


static func _project_list(raw, keys: Array) -> Array:
	var out: Array = []
	if raw is Array:
		for entry in raw:
			if entry is Dictionary:
				out.append(_project(entry, keys))
			else:
				out.append(entry)
	return out


## Stable, collision-resistant canonical string for any JSON-ish value.
static func _canonical(v) -> String:
	if v == null:
		return "N"
	if v is bool:
		return "b1" if v else "b0"
	if v is int or v is float:
		return _num(v)
	if v is String:
		var s: String = v
		return "s%d:%s" % [s.length(), s]
	if v is Vector2:
		return "v(%s,%s)" % [_num((v as Vector2).x), _num((v as Vector2).y)]
	if v is Array:
		var arr: Array = v
		var parts := PackedStringArray()
		for e in arr:
			parts.append(_canonical(e))
		# Arrays of ENTITIES (all-Dictionary: components/nets/traces/vias/
		# mounting_holes and their nested pads/pins) are SETS — sort them so
		# element order can never churn the hash (removes false-stale). Arrays
		# with any non-dict element are ORDERED SEQUENCES whose order is SEMANTIC
		# — the layer stack and a trace's waypoints/points — and are PRESERVED, so
		# a genuine reordering still changes the hash (no false-clean). Numbers
		# stay %.6f at every depth via the int/float branch above.
		if _all_dict(arr):
			parts.sort()
		return "[" + ",".join(parts) + "]"
	if v is Dictionary:
		var d: Dictionary = v
		# String-sort keys; JSON object keys are strings, so str(k)==k here.
		var by_str := {}
		var skeys := PackedStringArray()
		for k in d.keys():
			var ks := str(k)
			by_str[ks] = d[k]
			skeys.append(ks)
		skeys.sort()
		var parts := PackedStringArray()
		for ks in skeys:
			parts.append("%s=%s" % [ks, _canonical(by_str[ks])])
		return "{" + ";".join(parts) + "}"
	# Fallback: stringify (length-prefixed) — keeps unknown types deterministic.
	var fs := str(v)
	return "s%d:%s" % [fs.length(), fs]


## Format any number as a fixed-precision string so the int↔float JSON coercion
## can never change the hash. Normalises -0.0 → 0.0.
static func _num(n) -> String:
	var f := float(n)
	if f == 0.0:
		f = 0.0
	return "%.6f" % f


## True iff every element is a Dictionary (an empty array counts as true). Marks
## an array as a set-of-entities (sortable) vs an ordered sequence (preserved).
static func _all_dict(arr: Array) -> bool:
	for e in arr:
		if not (e is Dictionary):
			return false
	return true


# ── document id ───────────────────────────────────────────────────────────────

## A random provenance id, minted ONCE then persisted in the envelope. Random is
## fine here (it is NOT a fingerprint input); it never enters compute_*.
static func _generate_document_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var hex := ""
	for _i in 4:
		hex += "%08x" % rng.randi()
	return "pcbdoc-" + hex


# ── corrupt backup ────────────────────────────────────────────────────────────

## Rename a corrupt sidecar to <path>.corrupt-<unix_seconds>. Never throws —
## corruption recovery is quiet enough that the board still opens.
static func _backup_corrupt(sidecar_path: String) -> void:
	var backup := "%s.corrupt-%d" % [sidecar_path, int(Time.get_unix_time_from_system())]
	var err := DirAccess.rename_absolute(sidecar_path, backup)
	if err == OK:
		push_warning("[RoutingSidecar] corrupt sidecar backed up to %s" % backup)
	else:
		push_error("[RoutingSidecar] could not back up corrupt sidecar %s (error %d)" % [sidecar_path, err])
