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
	candidate_changed.emit(id)


## Unpin a candidate: drop from the pinned set AND revert disposition to proposed.
func unpin(id: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	pinned.erase(id)
	c.disposition = "proposed"
	candidate_changed.emit(id)


func is_pinned(id: String) -> bool:
	return pinned.has(id)


## Reject a candidate: disposition=rejected + emit candidate_changed.
func reject(id: String) -> void:
	var c = get_candidate(id)
	if c == null:
		return
	c.disposition = "rejected"
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
	var hint_ids := _hint_ids(source_hints)
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

		var task_key := _task_key(net, hint_ids)
		var generation := 1
		var prior_id: String = str(_task_candidate.get(task_key, ""))
		if not prior_id.is_empty() and candidates.has(prior_id):
			var prior = candidates[prior_id]
			generation = int(prior.generation) + 1
			prior.disposition = "superseded"
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
