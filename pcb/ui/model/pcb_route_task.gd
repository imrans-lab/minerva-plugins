extends RefCounted
## RouteTask — the routing JOB a RouteCandidate answers.
##
## A task names one net and the set of endpoints (pads / anchor points) that a
## route for that net must connect. It is the stable "question"; a RouteCandidate
## is one "answer". Multiple candidates (different generations) can answer the
## same task_id.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd / pcb_trace.gd).
## Reached via relative preload(); cross-file refs are duck-typed. Vector2 fields
## serialise to {"x","y"} dicts for JSON safety (same convention as pcb_trace).
##
## GDScript gotcha: JSON round-trips whole numbers as float — int fields are cast
## with int() on load so a loaded 3.0 compares equal to 3.

const _Self := preload("pcb_route_task.gd")

## Stable identity of the routing job (workspace-scoped, e.g. "task_1").
var task_id: String = ""

## Net this task routes.
var net: String = ""

## Endpoints the route must connect. Each entry is a plain dict describing one
## pad / anchor, e.g. {"component":"U1","pin":"3","position":Vector2}. Kept as an
## open dict list (not a typed value object) so callers can carry whatever anchor
## detail the router needs without a schema migration.
var endpoints: Array = []


## Deep copy.
func duplicate_task():
	var copy := _Self.new()
	copy.task_id = task_id
	copy.net = net
	copy.endpoints = _endpoints_deep_copy(endpoints)
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
	}


func load_from_dict(data: Dictionary) -> void:
	task_id = str(data.get("task_id", ""))
	net = str(data.get("net", ""))
	endpoints.clear()
	for e in data.get("endpoints", []):
		endpoints.append(_endpoint_from_json(e))


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


## Restore a single endpoint from a JSON dict ({x,y} "position" → Vector2).
static func _endpoint_from_json(e):
	if not (e is Dictionary):
		return e
	var out: Dictionary = (e as Dictionary).duplicate(true)
	if out.has("position") and out["position"] is Dictionary:
		var pd: Dictionary = out["position"]
		out["position"] = Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0)))
	return out
