extends RefCounted
## RouteTask — the routing JOB a RouteCandidate answers.
##
## A task names one net and the set of endpoints (pads / anchor points) that a
## route for that net must connect. It is the stable "question"; a RouteCandidate
## is one "answer". Multiple candidates (different generations) can answer the
## same task_id.
##
## ── SCOPE: whole-net vs SPAN (C1) ─────────────────────────────────────────────
## A task's scope is `net` PLUS an OPTIONAL span interval:
##   span == {}        → WHOLE-NET scope: connect every endpoint of `net`.
##   span != {}        → SPAN scope: replace only the named interval of an
##                       existing candidate's geometry, holding the rest fixed
##                       (the DCR's "Reroute-Span replaces only a selected
##                       interval"). See make_span/span_key below for the shape.
## The span lives on the TASK (the question), not on the candidate (the answer),
## because "reroute just this stretch" is a differently-scoped QUESTION about the
## same net — so it gets its own task_id and its own candidate generations, and a
## later whole-net re-propose can never be confused for a span re-propose.
##
## ── LIFECYCLE: open / closed (C1) ─────────────────────────────────────────────
## open   — the task still needs copper: no candidate answering it is committed.
## closed — a candidate for this task has been COMMITTED (its copper is on the
##          board). Closing is DERIVED, never free-standing: RoutingWorkspace
##          recomputes it from the candidate set (_refresh_task_state), so an
##          uncommit/undo reopens the task automatically and the two stores can
##          never disagree. DCR vocabulary: "Reject = discard candidate, reopen
##          task" — a reject leaves/returns the task OPEN because rejecting is
##          not committing.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd / pcb_trace.gd).
## Reached via relative preload(); cross-file refs are duck-typed. Vector2 fields
## serialise to {"x","y"} dicts for JSON safety (same convention as pcb_trace).
##
## GDScript gotcha: JSON round-trips whole numbers as float — int fields are cast
## with int() on load so a loaded 3.0 compares equal to 3.

const _Self := preload("pcb_route_task.gd")

## Legal lifecycle states. Same validating-setter idiom as RouteCandidate's two
## status axes: an out-of-set value is refused (push_warning, value unchanged).
const STATES := ["open", "closed"]

## Stable identity of the routing job (workspace-scoped, e.g. "task_1").
var task_id: String = ""

## Net this task routes.
var net: String = ""

## Endpoints the route must connect. Each entry is a plain dict describing one
## pad / anchor, e.g. {"component":"U1","pin":"3","position":Vector2}. Kept as an
## open dict list (not a typed value object) so callers can carry whatever anchor
## detail the router needs without a schema migration.
var endpoints: Array = []

## OPTIONAL span interval ({} ⇒ whole-net scope). See make_span for the shape.
var span: Dictionary = {}

## ── lifecycle axis: open / closed ─────────────────────────────────────────────
var _state: String = "open"
var state: String:
	get:
		return _state
	set(value):
		set_state(value)


## Validating setter for the lifecycle axis (out-of-set values refused).
func set_state(value: String) -> void:
	if value in STATES:
		_state = value
	else:
		push_warning("[RouteTask] ignored invalid state '%s'" % value)


func is_open() -> bool:
	return _state == "open"


## True iff this task is scoped to a SPAN rather than the whole net.
func is_span_scoped() -> bool:
	return not span.is_empty()


## Build a span interval. `candidate_id` is the candidate whose geometry the
## span cuts out of; `segment_ids` are the segments being REPLACED; from/to are
## the two fixed anchor points the replacement must reconnect (carried
## explicitly so the router/worker gets the boundary without having to resolve
## the base candidate). Returns a plain JSON-friendly dict — the model stores no
## typed value object here, same open-dict convention as `endpoints`.
static func make_span(candidate_id: String, segment_ids: Array, from_point: Vector2, to_point: Vector2) -> Dictionary:
	var ids: Array = []
	for s in segment_ids:
		ids.append(str(s))
	return {
		"candidate_id": str(candidate_id),
		"segment_ids": ids,
		"from": from_point,
		"to": to_point,
	}


## Deterministic identity string for a span — "" for the empty (whole-net) span.
## SEGMENT IDS ARE SORTED so the same interval selected in a different click
## order produces the SAME key (and therefore the same task_id, so a re-propose
## of that span supersedes rather than duplicating). Anchor points are NOT part
## of the key: they are derived from the segments, and float formatting would
## make the key fragile.
static func span_key(span_dict: Dictionary) -> String:
	if span_dict.is_empty():
		return ""
	var ids: Array = []
	for s in span_dict.get("segment_ids", []):
		ids.append(str(s))
	ids.sort()
	return "%s:%s" % [str(span_dict.get("candidate_id", "")), ",".join(ids)]


## Deep copy.
func duplicate_task():
	var copy := _Self.new()
	copy.task_id = task_id
	copy.net = net
	copy.endpoints = _endpoints_deep_copy(endpoints)
	copy.span = span.duplicate(true)
	copy.set_state(_state)
	return copy


func _endpoints_deep_copy(src: Array) -> Array:
	var out: Array = []
	for e in src:
		if e is Dictionary:
			out.append((e as Dictionary).duplicate(true))
		else:
			out.append(e)
	return out


## Serialise every field (positions inside endpoints stay Vector2 here — they are
## JSON-safed by _endpoint_to_json below).
func to_dict() -> Dictionary:
	var eps: Array = []
	for e in endpoints:
		eps.append(_endpoint_to_json(e))
	return {
		"task_id": task_id,
		"net": net,
		"endpoints": eps,
		"span": _span_to_json(span),
		"state": _state,
	}


func load_from_dict(data: Dictionary) -> void:
	task_id = str(data.get("task_id", ""))
	net = str(data.get("net", ""))
	endpoints.clear()
	for e in data.get("endpoints", []):
		endpoints.append(_endpoint_from_json(e))
	var raw_span: Variant = data.get("span", {})
	span = _span_from_json(raw_span as Dictionary) if raw_span is Dictionary else {}
	# Route through the validating setter — an absent/garbled state falls back to
	# "open" (the safe default: an unknown task still needs routing).
	set_state(str(data.get("state", "open")))


static func from_dict(data: Dictionary):
	var t := _Self.new()
	t.load_from_dict(data)
	return t


## Convert a single endpoint to a JSON-safe dict (Vector2 "position" → {x,y}).
static func _endpoint_to_json(e):
	if not (e is Dictionary):
		return e
	var out: Dictionary = (e as Dictionary).duplicate(true)
	if out.has("position") and out["position"] is Vector2:
		var p: Vector2 = out["position"]
		out["position"] = {"x": p.x, "y": p.y}
	return out


## Span → JSON-safe dict (Vector2 "from"/"to" → {x,y}). Empty span stays empty.
static func _span_to_json(s: Dictionary) -> Dictionary:
	if s.is_empty():
		return {}
	var out: Dictionary = s.duplicate(true)
	for key in ["from", "to"]:
		if out.has(key) and out[key] is Vector2:
			var p: Vector2 = out[key]
			out[key] = {"x": p.x, "y": p.y}
	return out


## Span ← JSON dict ({x,y} "from"/"to" → Vector2). Empty span stays empty.
static func _span_from_json(s: Dictionary) -> Dictionary:
	if s.is_empty():
		return {}
	var out: Dictionary = s.duplicate(true)
	for key in ["from", "to"]:
		if out.has(key) and out[key] is Dictionary:
			var pd: Dictionary = out[key]
			out[key] = Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0)))
	var ids: Array = []
	for i in out.get("segment_ids", []):
		ids.append(str(i))
	out["segment_ids"] = ids
	out["candidate_id"] = str(out.get("candidate_id", ""))
	return out


## Restore a single endpoint from a JSON dict ({x,y} "position" → Vector2).
static func _endpoint_from_json(e):
	if not (e is Dictionary):
		return e
	var out: Dictionary = (e as Dictionary).duplicate(true)
	if out.has("position") and out["position"] is Dictionary:
		var pd: Dictionary = out["position"]
		out["position"] = Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0)))
	return out
