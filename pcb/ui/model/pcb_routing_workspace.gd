extends RefCounted
## RoutingWorkspace — owns the set of RouteCandidates for a routing session plus
## the selection/pin state a routing UI needs. This is the FOUNDATION domain
## model (T1); canvas, verbs, worker calls and annotation wiring land in later
## tasks and are STUBBED here with correct signatures.
##
## ── Stable-id generation ──────────────────────────────────────────────────────
## Ids are workspace-scoped monotonic counters: "cand_1", "seg_1", "via_1". They
## are deterministic (no random/time) so tests are reproducible. from_dict()
## restores each counter to a HIGH-WATER MARK — the max of the stored counter and
## the largest numeric suffix actually present in the loaded ids — so ids minted
## after a load can never collide with loaded ones.
##
## Off-tree plugin: NO class_name; relative preload + duck typing.

const _Self := preload("pcb_routing_workspace.gd")
const PcbRouteCandidate := preload("pcb_route_candidate.gd")
const PcbLayerStack := preload("pcb_layer_stack.gd")

## Emitted when a candidate is inserted.
signal candidate_added(id: String)
## Emitted when a candidate's disposition/geometry changes (pin/unpin/reject/edit).
signal candidate_changed(id: String)
## Emitted when a candidate is removed.
signal candidate_removed(id: String)
## Emitted when the active candidate changes.
signal active_candidate_changed(id: String)
## Emitted when a candidate's validation axis changes.
signal validation_changed(id: String)

## candidate_id -> RouteCandidate.
var candidates: Dictionary = {}
## The candidate the UI is focused on ("" = none).
var active_candidate_id: String = ""
## Set of pinned candidate ids (Dictionary used as a set: id -> true).
var pinned: Dictionary = {}
## The finding the UI has selected ("" = none).
var selected_finding_id: String = ""

## Stored findings per candidate (candidate_id -> Array). Populated by validation
## in a later task; empty for now.
var _findings: Dictionary = {}

## Monotonic id counters (last-issued number; next id is counter+1).
var _cand_counter: int = 0
var _seg_counter: int = 0
var _via_counter: int = 0

## T2 (S2.2) idempotent-replace bookkeeping: task_key -> the CURRENT (non-
## superseded) candidate_id answering that task. In-memory only — NOT part of
## to_dict/load_from_dict (persistence is T2a; the shadow workspace lives in
## memory this round, so this index does not need to survive a save/load yet).
var _task_candidate: Dictionary = {}

## ── T2.4 draft-check coherence state (TRANSIENT — never persisted) ─────────────
## workspace_generation: a monotonic counter bumped on ANY candidate-set change
## (add/remove/ingest/supersede + disposition changes that alter the live set).
## It is the SECOND coherence token draft_check echoes (alongside board_token):
## if the set drifted between begin_check and apply_check_result, the generation
## differs and the whole reply is discarded. It is RUNTIME state — it resets to 0
## on a fresh session/load and is DELIBERATELY absent from to_dict/to_sidecar_dict
## (the durable sidecar guards coherence with the board fingerprint, not this).
var _workspace_generation: int = 0

## The current board coherence token (compute_board_fingerprint of the live
## board). The workspace is a pure model with no PCBData dependency, so the OWNER
## (PCBPanel) sets this before begin_check and keeps it current; begin_check
## stamps it into the request and apply_check_result compares the echoed value
## against it. Transient — never persisted.
var board_token: String = ""

## In-flight begin_check snapshot: candidate_id -> {"revision": int,
## "prior": String}. Captured when begin_check flips a candidate to "checking"
## so apply_check_result can (a) detect a per-candidate revision drift and
## (b) revert a discarded candidate to exactly the validation it had before.
var _pending_check: Dictionary = {}


## The current workspace generation (read-only accessor for the owner/tests).
func workspace_generation() -> int:
	return _workspace_generation


## Bump the generation on any candidate-set change. Kept private + called from
## every set-mutating op so a stale draft-check reply is always caught.
func _bump_generation() -> void:
	_workspace_generation += 1


# ── id minting ────────────────────────────────────────────────────────────────

func next_candidate_id() -> String:
	_cand_counter += 1
	return "cand_%d" % _cand_counter


func next_segment_id() -> String:
	_seg_counter += 1
	return "seg_%d" % _seg_counter


func next_via_id() -> String:
	_via_counter += 1
	return "via_%d" % _via_counter


# ── real ops (pure state) ─────────────────────────────────────────────────────

## Insert a candidate. Mints a candidate_id if absent, and mints seg_/via_ ids for
## any segment/via lacking one, so every stored entity has a stable workspace id.
## Emits candidate_added. Returns the candidate_id.
func add_candidate(candidate) -> String:
	if str(candidate.candidate_id).is_empty():
		candidate.candidate_id = next_candidate_id()
	for seg in candidate.segments:
		if seg is Dictionary and str(seg.get("id", "")).is_empty():
			seg["id"] = next_segment_id()
	for via in candidate.vias:
		if via is Dictionary and str(via.get("id", "")).is_empty():
			via["id"] = next_via_id()
	var id: String = candidate.candidate_id
	candidates[id] = candidate
	if candidate.disposition == "pinned":
		pinned[id] = true
	_bump_generation()  # candidate-set grew → any in-flight draft-check is stale
	candidate_added.emit(id)
	return id


func get_candidate(id: String):
	return candidates.get(id, null)


## All candidates (insertion order of the backing dict).
func list_candidates() -> Array:
	return candidates.values()


## Non-superseded candidates for a task_id — the task's CURRENT-generation
## set. A re-ingest for the same task (see ingest_routing_result's
## idempotent-replace) supersedes the prior candidate rather than removing
## it, so `candidates` can hold >1 entry per task; this is "how many are
## LIVE for this task" without callers re-deriving the disposition filter.
func candidates_for_task(task_id: String) -> Array:
	var out: Array = []
	for c in candidates.values():
		if str(c.task_id) == task_id and c.disposition != "superseded":
			out.append(c)
	return out


func remove_candidate(id: String) -> void:
	if not candidates.has(id):
		return
	candidates.erase(id)
	pinned.erase(id)
	_findings.erase(id)
	_bump_generation()  # candidate-set shrank → any in-flight draft-check is stale
	if active_candidate_id == id:
		active_candidate_id = ""
		active_candidate_changed.emit("")
	candidate_removed.emit(id)


## Focus a candidate. Emits active_candidate_changed.
func set_active(id: String) -> void:
	active_candidate_id = id
	active_candidate_changed.emit(id)


## Pin a candidate: add to the pinned set AND set disposition=pinned.
func pin(id: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	pinned[id] = true
	c.disposition = "pinned"
	_bump_generation()  # disposition change alters the live set → invalidate in-flight check
	candidate_changed.emit(id)


## Unpin a candidate: drop from the pinned set AND revert disposition to proposed.
func unpin(id: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	pinned.erase(id)
	c.disposition = "proposed"
	_bump_generation()
	candidate_changed.emit(id)


func is_pinned(id: String) -> bool:
	return pinned.has(id)


## Reject a candidate: disposition=rejected + emit candidate_changed.
func reject(id: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	c.disposition = "rejected"
	_bump_generation()  # rejected leaves the live set → invalidate in-flight check
	candidate_changed.emit(id)


## Set a candidate's validation axis + emit validation_changed. Leaves the
## disposition axis untouched (orthogonality is enforced in RouteCandidate).
func set_validation(id: String, value: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	c.validation = value
	validation_changed.emit(id)


## Stored findings for a candidate (empty until a later task populates them).
func findings_for_candidate(id: String) -> Array:
	return _findings.get(id, [])


# ── T2.4 draft-check state machine (IPC-decoupled) ────────────────────────────
# The reusable NATIVE draft-check seam T5 depends on. It is split so it can be
# tested WITHOUT the worker: begin_check() builds a plain request payload and
# apply_check_result() consumes a plain reply dict. PCBPanel.check_draft() wires
# the two ends to the pcb.draft_check broker channel; here there is no IPC.
# ON-DEMAND only — no debounce/coalescing/cancellation/auto-recheck (that is T6).

## Candidate ids whose disposition keeps them in the LIVE routing set (i.e. NOT
## superseded/rejected/committed) — the default scope of a draft check.
func live_candidate_ids() -> Array:
	var out: Array = []
	for id in candidates:
		var c = candidates[id]
		if str(c.disposition) in ["superseded", "rejected", "committed"]:
			continue
		out.append(str(id))
	return out


## Begin an ON-DEMAND draft check. Flips the target candidates to
## validation="checking" (emitting validation_changed), SNAPSHOTS each one's
## candidate_revision + prior validation (so a mismatched reply can be reverted
## exactly), and returns the request payload the worker's draft_check consumes:
##   {board_token, workspace_generation, candidates:[{candidate_id, net,
##    revision, segments:[{id,layer,width,points:[[x,y],…]}],
##    vias:[{id,position:[x,y],from_layer,to_layer}]}]}
## board_token comes from `board_token` (owner-set) and workspace_generation from
## the current counter — both are stamped so apply_check_result can discard a
## stale reply. `candidate_ids` empty ⇒ all live candidates.
func begin_check(candidate_ids: Array = []) -> Dictionary:
	var ids: Array = candidate_ids if not candidate_ids.is_empty() else live_candidate_ids()
	_pending_check = {}
	var out_candidates: Array = []
	for raw_id in ids:
		var cid := str(raw_id)
		var c = get_candidate(cid)
		if c == null:
			continue
		_pending_check[cid] = {"revision": int(c.candidate_revision), "prior": str(c.validation)}
		set_validation(cid, "checking")  # emits validation_changed
		out_candidates.append({
			"candidate_id": cid,
			"net": str(c.net),
			"revision": int(c.candidate_revision),
			"segments": _segments_wire(c),
			"vias": _vias_wire(c),
		})
	return {
		"board_token": board_token,
		"workspace_generation": int(_workspace_generation),
		"candidates": out_candidates,
	}


## Apply a draft_check reply. GUARDS FIRST, then writes — a mismatched reply must
## NEVER mark a candidate clean:
##   1+2. WHOLE-REPLY discard if reply.board_token != current board_token OR
##        reply.workspace_generation != current _workspace_generation. Every
##        candidate begin_check set to "checking" is reverted to its snapshotted
##        prior validation; nothing is set clean/violating.
##   3.   PER-CANDIDATE discard if a candidate's CURRENT candidate_revision !=
##        the value snapshotted at begin_check (its geometry drifted mid-flight):
##        that candidate is reverted to its prior validation and skipped.
## Only on a FULL match is a candidate set clean/violating/error per the reply's
## per_candidate verdict, its findings stored (attributed by candidate_id), and
## validation_changed emitted. The workspace is the SOLE authoritative store of
## validation + findings (no parallel store).
func apply_check_result(reply: Dictionary) -> void:
	var reply_token := str(reply.get("board_token", ""))
	# workspace_generation round-trips through JSON as a float; int() normalises.
	var reply_gen := int(reply.get("workspace_generation", -1))

	# GUARD 1+2 — whole-reply coherence.
	if reply_token != board_token or reply_gen != _workspace_generation:
		_revert_pending()
		_pending_check = {}
		return

	var per_candidate: Dictionary = reply.get("per_candidate", {}) if reply.get("per_candidate", {}) is Dictionary else {}
	var findings: Array = reply.get("findings", []) if reply.get("findings", []) is Array else []

	for raw_cid in per_candidate:
		var cid := str(raw_cid)
		var c = get_candidate(cid)
		if c == null:
			continue
		var snap: Dictionary = _pending_check.get(cid, {})
		# GUARD 3 — a candidate not in this check, or whose revision drifted after
		# begin_check, is left as it was (revert to prior); never marked clean.
		if snap.is_empty():
			continue
		if int(c.candidate_revision) != int(snap.get("revision", -1)):
			if str(c.validation) == "checking":
				set_validation(cid, str(snap.get("prior", "unchecked")))
			continue
		var verdict := str(per_candidate[raw_cid])
		var value := "clean"
		if verdict == "violating" or verdict == "clean" or verdict == "error":
			value = verdict
		else:
			value = "error"  # an unknown verdict is never trusted as clean
		set_validation(cid, value)
		_findings[cid] = _findings_for_subject(findings, cid)

	_pending_check = {}


## Revert every still-"checking" pending candidate to its snapshotted prior
## validation. Used on a whole-reply discard.
func _revert_pending() -> void:
	for cid in _pending_check:
		var c = get_candidate(str(cid))
		if c == null:
			continue
		if str(c.validation) == "checking":
			set_validation(str(cid), str((_pending_check[cid] as Dictionary).get("prior", "unchecked")))


## Findings from a draft_check reply that name `cid` among their subjects.
static func _findings_for_subject(findings: Array, cid: String) -> Array:
	var out: Array = []
	for f in findings:
		if not (f is Dictionary):
			continue
		for s in (f as Dictionary).get("subjects", []):
			if s is Dictionary and str((s as Dictionary).get("candidate_id", "")) == cid:
				out.append(f)
				break
	return out


## Serialise a candidate's segments to the draft_check wire shape: points as
## [[x,y],…] (JSON-friendly, mirrors route segment coordinates).
func _segments_wire(c) -> Array:
	var out: Array = []
	for seg in c.segments:
		if not (seg is Dictionary):
			continue
		var pts: Array = []
		for p in (seg as Dictionary).get("points", []):
			if p is Vector2:
				pts.append([p.x, p.y])
			elif p is Dictionary:
				pts.append([float((p as Dictionary).get("x", 0.0)), float((p as Dictionary).get("y", 0.0))])
		out.append({
			"id": str((seg as Dictionary).get("id", "")),
			"layer": str((seg as Dictionary).get("layer", "top")),
			"width": float((seg as Dictionary).get("width", 0.25)),
			"points": pts,
		})
	return out


## Serialise a candidate's vias to the draft_check wire shape: position as [x,y].
func _vias_wire(c) -> Array:
	var out: Array = []
	for via in c.vias:
		if not (via is Dictionary):
			continue
		var via_dict: Dictionary = via
		var pos = via_dict.get("position", Vector2.ZERO)
		var xy: Array = [0.0, 0.0]
		if pos is Vector2:
			xy = [pos.x, pos.y]
		elif pos is Dictionary:
			xy = [float((pos as Dictionary).get("x", 0.0)), float((pos as Dictionary).get("y", 0.0))]
		out.append({
			"id": str(via_dict.get("id", "")),
			"position": xy,
			"from_layer": str(via_dict.get("from_layer", "top")),
			"to_layer": str(via_dict.get("to_layer", "bottom")),
		})
	return out


# ── stub ops (signatures fixed now; bodies land in T2/T5/T7) ───────────────────
# Each is a real no-op placeholder that push_warnings — NOT a fake success — so a
# premature caller is visibly unimplemented rather than silently wrong.

## T2 (S2.2) — SHADOW-phase ingest. Translates a router reply into
## RouteCandidates and adds them via add_candidate (mints cand_/seg_/via_ ids).
## This is dual-write ALONGSIDE panel_tools.gd's _write_back_proposals — the
## annotation proposals it writes remain the UI's source of truth; this
## workspace is populated in parallel and drives nothing visible yet.
##
## router_reply: {"routes":[{"net":String, "segments":[{"start":[x,y]|Vector2,
##   "end":[x,y]|Vector2, "layer":"F.Cu"/"B.Cu"}], "vias":[[x,y], ...]}], ...} —
##   EXACTLY the shape panel_tools.gd's _write_back_proposals/_materialize_routes
##   read (see panel_tools.gd ~990/~1058). A via entry is POSITIONAL [x,y] (the
##   worker's public route() reply carries no from/to — a through-via always
##   spans PcbLayerStack.default_through_via_span(), same assumption
##   _materialize_routes makes); a {x_mm,y_mm}/{x,y}/{"position":...} dict is
##   also accepted defensively, mirroring panel_tools._via_position.
##
## source_hints: the Array of source route-hint annotation dicts the propose
##   call gathered (kind_payload.net_names/source_pins/dest_pins/width_mm).
##   Their ids become source_hint_ids (provenance); net_names/width_mm size
##   each candidate's segment width (falls back to 0.25mm, matching
##   _materialize_routes' own fallback); source_pins/dest_pins seed `endpoints`.
##
## board_revision: PCBData.board_revision AT INGEST TIME, passed as a plain int
##   (not the PCBData object) so this pure-model file stays decoupled from
##   pcb_data.gd — the caller (panel_tools.gd, which already resolves the board
##   via _get_data(host)) reads data.board_revision and hands the int in.
##
## ── IDEMPOTENT REPLACE (discussion gap d) ──────────────────────────────────
## Task-identity key: `net + "|" + sorted(source_hint_ids).join(",")`. Two
## ingests sharing the same net AND the same set of source-hint ids are the
## SAME task (a re-propose of the same corridor); a different net or a
## different hint set is a DIFFERENT task. source_hint_ids are chosen over an
## endpoint-derived key because they are already stable/deterministic
## (annotation ids) and available on every ingest call with no extra parsing.
##
## Re-ingesting the SAME task NEVER appends a duplicate: the prior CURRENT
## candidate for that task_key is flipped to disposition="superseded"
## (candidate_changed emitted) and a NEW candidate is added at
## generation = prior.generation + 1 (candidate_added emitted). The superseded
## candidate is kept (not removed) as an audit trail; candidates_for_task()
## (non-superseded) is what stays size-1 across re-proposes for that task — a
## DIFFERENT task adds a genuinely new, independent candidate.
func ingest_routing_result(router_reply: Dictionary, source_hints: Array = [], board_revision: int = 0) -> Array:
	var new_ids: Array = []
	var via_span: Array = PcbLayerStack.default_through_via_span()

	for route in router_reply.get("routes", []):
		if not (route is Dictionary):
			continue
		var route_dict: Dictionary = route
		var segs: Array = route_dict.get("segments", [])
		var vias: Array = route_dict.get("vias", [])
		if segs.is_empty() and vias.is_empty():
			continue
		var net: String = str(route_dict.get("net", ""))

		# PER-NET attribution (T2a folds in docket #555): the task_key +
		# source_hint_ids are keyed on the hints that target THIS net, not the
		# GLOBAL propose hint set. A multi-net propose / a cross-net hint change
		# no longer shifts an unrelated net's task_key (which would leave a stale
		# duplicate). Mirrors panel_tools._source_hint_ids_for_net (same per-net
		# filter + same fallback-to-all when no hint names the net).
		var hint_ids := _hint_ids_for_net(source_hints, net)
		var task_key := _task_key(net, hint_ids)
		var generation := 1
		var prior_id: String = str(_task_candidate.get(task_key, ""))
		if not prior_id.is_empty() and candidates.has(prior_id):
			var prior = candidates[prior_id]
			generation = int(prior.generation) + 1
			prior.disposition = "superseded"
			_bump_generation()  # supersede leaves the live set (add_candidate bumps for the new one)
			candidate_changed.emit(prior_id)

		var cand = PcbRouteCandidate.new()
		cand.task_id = task_key
		cand.net = net
		cand.generation = generation
		cand.base_board_revision = board_revision
		cand.source_hint_ids = _to_string_typed_array(hint_ids)
		cand.endpoints = _endpoints_for_net(source_hints, net)

		var width := _width_for_net(source_hints, net)
		for seg in segs:
			if not (seg is Dictionary):
				continue
			var seg_dict: Dictionary = seg
			var layer := PcbLayerStack.kicad_to_canon(seg_dict.get("layer", "F.Cu"))
			var pts: Array = [_pt(seg_dict.get("start", [0, 0])), _pt(seg_dict.get("end", [0, 0]))]
			cand.add_segment(PcbRouteCandidate.make_segment("", layer, width, pts))

		for via in vias:
			var pos := _via_pt(via)
			cand.add_via(PcbRouteCandidate.make_via("", pos, via_span[0], via_span[1]))

		var new_id: String = add_candidate(cand)
		_task_candidate[task_key] = new_id
		new_ids.append(new_id)

	return new_ids


# ── ingest helpers (private) ────────────────────────────────────────────────

static func _hint_ids(source_hints: Array) -> Array:
	var out: Array = []
	for hint in source_hints:
		if hint is Dictionary:
			out.append(str((hint as Dictionary).get("id", "")))
	return out


## Ids of the source hints whose kind_payload.net_names include `net` — the
## PER-NET provenance/attribution set. Mirrors panel_tools._source_hint_ids_for_net
## exactly, INCLUDING its fallback: when NO hint names this net (e.g. a route for
## a net with no matching hint), fall back to the full hint set so a candidate is
## never left with empty provenance. Keeping this identical to the propose path
## means the workspace's task_key matches the proposal-linking the UI already does.
static func _hint_ids_for_net(source_hints: Array, net: String) -> Array:
	var ids: Array = []
	for hint in source_hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		var nets: Array = kp.get("net_names", []) if kp.get("net_names", []) is Array else []
		if net in nets:
			ids.append(str((hint as Dictionary).get("id", "")))
	if ids.is_empty():
		return _hint_ids(source_hints)
	return ids


static func _to_string_typed_array(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for id in ids:
		out.append(str(id))
	return out


## Deterministic task-identity key — see the ingest_routing_result contract doc.
static func _task_key(net: String, hint_ids: Array) -> String:
	var sorted_ids: Array = hint_ids.duplicate()
	sorted_ids.sort()
	var joined := ",".join(sorted_ids)
	return "%s|%s" % [net, joined]


## Endpoints seeded from the matching source hints' pin references
## (kind_payload.source_pins/dest_pins, each "Component.Pin"). Positions are
## not resolved here (no board/pad lookup in this pure model) — component/pin
## identity is enough for provenance; a later task can enrich with position.
static func _endpoints_for_net(source_hints: Array, net: String) -> Array:
	var out: Array = []
	for hint in source_hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		var nets: Array = kp.get("net_names", []) if kp.get("net_names", []) is Array else []
		if not (net in nets):
			continue
		for pin_ref in kp.get("source_pins", []):
			out.append(_pin_ref_to_endpoint(pin_ref))
		for pin_ref in kp.get("dest_pins", []):
			out.append(_pin_ref_to_endpoint(pin_ref))
	return out


static func _pin_ref_to_endpoint(pin_ref) -> Dictionary:
	var s := str(pin_ref)
	var idx := s.rfind(".")
	if idx < 0:
		return {"component": s, "pin": ""}
	return {"component": s.substr(0, idx), "pin": s.substr(idx + 1)}


## Widest authored trace width among the source hints that target `net`
## (mirrors panel_tools._width_for_net); falls back to 0.25mm — the same
## default _materialize_routes applies when no hint specifies a width — so a
## shadow candidate's width matches what would actually be committed.
static func _width_for_net(source_hints: Array, net: String) -> float:
	var w := 0.0
	for hint in source_hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {}) if (hint as Dictionary).get("kind_payload", {}) is Dictionary else {}
		var nets: Array = kp.get("net_names", []) if kp.get("net_names", []) is Array else []
		if net in nets:
			var hw := float(kp.get("width_mm", 0.0))
			if hw > w:
				w = hw
	if w <= 0.0:
		w = 0.25
	return w


## Coerce a [x, y] pair (Array/Vector2/{"x","y"} dict) to Vector2.
static func _pt(raw) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	if raw is Dictionary:
		var d: Dictionary = raw
		return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	return Vector2.ZERO


## A route's via entries are POSITIONAL [x,y] (mirrors panel_tools._via_position
## — SAME reply shape, independently read here since this pure model has no
## dependency on panel_tools.gd). Defensively also accepts {x_mm,y_mm}/{x,y}/
## {"position":...} dict shapes.
static func _via_pt(raw) -> Vector2:
	if raw is Dictionary:
		var d: Dictionary = raw
		if d.has("x_mm") and d.has("y_mm"):
			return Vector2(float(d.get("x_mm", 0.0)), float(d.get("y_mm", 0.0)))
		if d.has("x") and d.has("y"):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		if d.has("position"):
			return _pt(d.get("position", [0, 0]))
		return Vector2.ZERO
	return _pt(raw)


## T5: apply a candidate's geometry to the board as ONE batched transaction and
## mark it committed. STUB.
func commit(_candidate_id: String, _board = null) -> bool:
	push_warning("[RoutingWorkspace] commit is a stub (T5)")
	return false


## T7: add a via to a candidate at an interactive edit point. STUB.
func add_via(_candidate_id: String, _position: Vector2, _from_layer: String, _to_layer: String) -> bool:
	push_warning("[RoutingWorkspace] add_via is a stub (T7)")
	return false


## T7: insert a vertex into a candidate segment. STUB.
func add_vertex(_candidate_id: String, _segment_id: String, _index: int, _position: Vector2) -> bool:
	push_warning("[RoutingWorkspace] add_vertex is a stub (T7)")
	return false


## T7: add a routing gate/keepout constraint. STUB.
func add_gate(_candidate_id: String, _gate: Dictionary) -> bool:
	push_warning("[RoutingWorkspace] add_gate is a stub (T7)")
	return false


## T7: reroute one span of a candidate (partial re-route). STUB.
func reroute_span(_candidate_id: String, _segment_id: String) -> bool:
	push_warning("[RoutingWorkspace] reroute_span is a stub (T7)")
	return false


# ── serialisation ─────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	var cand_out: Dictionary = {}
	for id in candidates:
		cand_out[id] = candidates[id].to_dict()
	var pinned_out: Array = []
	for id in pinned:
		pinned_out.append(id)
	return {
		"candidates": cand_out,
		"active_candidate_id": active_candidate_id,
		"pinned": pinned_out,
		"selected_finding_id": selected_finding_id,
		"counters": {
			"candidate": _cand_counter,
			"segment": _seg_counter,
			"via": _via_counter,
		},
	}


## DURABLE serialisation for the on-disk routing sidecar (T2a). Identical to
## to_dict() MINUS the transient UI selection (active_candidate_id,
## selected_finding_id) — those are session state, not design intent, so they
## are NOT persisted (a fresh load starts with no active/selected). The pinned
## SET and the id counters ARE persisted: pinning is durable user intent, and
## the counters keep post-load ids from colliding with loaded ones. Round-trips
## back through load_from_dict (which defaults active/selected to "" when the
## keys are absent).
func to_sidecar_dict() -> Dictionary:
	var cand_out: Dictionary = {}
	for id in candidates:
		cand_out[id] = candidates[id].to_dict()
	var pinned_out: Array = []
	for id in pinned:
		pinned_out.append(id)
	return {
		"candidates": cand_out,
		"pinned": pinned_out,
		"counters": {
			"candidate": _cand_counter,
			"segment": _seg_counter,
			"via": _via_counter,
		},
	}


## Force EVERY candidate's validation axis to "stale" (disposition preserved).
## The coherence-quarantine signal: a loaded workspace whose board changed
## underneath it (fingerprint mismatch / unknown schema / missing token) is
## surfaced but never silently trusted — every candidate must be re-validated
## against the current board before it can be committed.
func mark_all_stale() -> void:
	for id in candidates:
		candidates[id].set_validation("stale")
		validation_changed.emit(str(id))


func load_from_dict(data: Dictionary) -> void:
	candidates.clear()
	pinned.clear()
	_findings.clear()

	var cand_data: Dictionary = data.get("candidates", {})
	for id in cand_data:
		candidates[id] = PcbRouteCandidate.from_dict(cand_data[id])

	active_candidate_id = str(data.get("active_candidate_id", ""))
	selected_finding_id = str(data.get("selected_finding_id", ""))

	for id in data.get("pinned", []):
		pinned[str(id)] = true

	# Restore counters to a HIGH-WATER MARK: max of the stored counter and the
	# largest numeric suffix present in loaded ids (int() tolerates JSON floats).
	var counters: Dictionary = data.get("counters", {})
	_cand_counter = int(counters.get("candidate", 0))
	_seg_counter = int(counters.get("segment", 0))
	_via_counter = int(counters.get("via", 0))
	for id in candidates:
		_cand_counter = maxi(_cand_counter, _suffix_num(str(id)))
		var c = candidates[id]
		for seg in c.segments:
			if seg is Dictionary:
				_seg_counter = maxi(_seg_counter, _suffix_num(str(seg.get("id", ""))))
		for via in c.vias:
			if via is Dictionary:
				_via_counter = maxi(_via_counter, _suffix_num(str(via.get("id", ""))))

	# Rebuild the in-memory idempotent-replace index from the loaded candidates
	# so a re-propose AFTER a load still supersedes (rather than duplicating) the
	# prior candidate for a task. _task_candidate is not itself persisted (T2's
	# contract), but it IS deterministically reconstructable from the loaded set.
	_rebuild_task_index()


## Rebuild _task_candidate: task_key -> the CURRENT (non-superseded, highest-
## generation) candidate answering it. Deterministic over the loaded candidates.
func _rebuild_task_index() -> void:
	_task_candidate.clear()
	for id in candidates:
		var c = candidates[id]
		if c.disposition == "superseded":
			continue
		var tk := str(c.task_id)
		if tk.is_empty():
			continue
		var cur := str(_task_candidate.get(tk, ""))
		if cur.is_empty() or int(c.generation) >= int(candidates[cur].generation):
			_task_candidate[tk] = str(id)


static func from_dict(data: Dictionary):
	var ws = _Self.new()
	ws.load_from_dict(data)
	return ws


## Trailing integer of an id like "cand_12" -> 12; 0 if none.
static func _suffix_num(id: String) -> int:
	var idx := id.rfind("_")
	if idx < 0 or idx + 1 >= id.length():
		return 0
	var tail := id.substr(idx + 1)
	if tail.is_valid_int():
		return int(tail)
	return 0
