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
## DELIBERATELY EXCLUDED: board name, grid_mm (a UI snap grid), the routing
## workspace itself (routing is never a fingerprint input — it is the thing being
## guarded), and any transient/selection state. The 2-layer model is all that
## exists today (no speculative N-layer fields).
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

## Persist `workspace` beside the board file. ZERO candidates ⇒ the sidecar is
## DELETED (mirrors AnnotationSidecar's zero-payload rule) — a candidate-free
## workspace leaves no file on disk. The board_document_id is carried forward
## from any existing sidecar at this path (so re-saving the SAME file keeps a
## stable id); a Save-As to a NEW path has no sidecar there yet and mints a fresh
## id for the copy. Returns an Error code.
static func save_workspace(board_path: String, workspace, board_dict: Dictionary, board_revision: int) -> Error:
	if board_path.is_empty() or workspace == null:
		return ERR_INVALID_PARAMETER
	var durable: Dictionary = workspace.to_sidecar_dict()
	var cands: Dictionary = durable.get("candidates", {}) if durable.get("candidates", {}) is Dictionary else {}
	if cands.is_empty():
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
		"board_fingerprint": compute_board_fingerprint(board_dict),
		"board_revision": int(board_revision),
		"workspace": durable,
	}
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
static func load_into_workspace(board_path: String, workspace, current_board_dict: Dictionary, _current_board_revision: int = 0) -> Dictionary:
	if workspace == null:
		return {"status": "missing", "candidate_count": 0}
	if not has_sidecar(board_path):
		return {"status": "missing", "candidate_count": 0}

	var envelope := read_envelope(board_path)
	if envelope.is_empty():
		# has_sidecar was true but the file did not parse → treated as empty.
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
		# Missing/garbled workspace token — nothing coherent to load.
		return {"status": "empty", "candidate_count": 0, "reason": "missing workspace token"}
	if stored_fp.is_empty():
		quarantine = true
		if reason.is_empty():
			reason = "missing board_fingerprint token"

	# Load candidates first (so a quarantine can still surface them as stale).
	workspace.load_from_dict(ws_dict as Dictionary)
	var count: int = workspace.candidates.size()

	if quarantine:
		workspace.mark_all_stale()
		return {"status": "quarantine_stale", "candidate_count": count, "reason": reason}

	# Fingerprint coherence: recompute from the CURRENT board and compare.
	var current_fp := compute_board_fingerprint(current_board_dict)
	if current_fp != stored_fp:
		workspace.mark_all_stale()
		return {
			"status": "quarantine_stale", "candidate_count": count,
			"reason": "board_fingerprint mismatch",
			"stored_fingerprint": stored_fp, "current_fingerprint": current_fp,
		}

	return {"status": "loaded_clean", "candidate_count": count, "stored_fingerprint": stored_fp}


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
