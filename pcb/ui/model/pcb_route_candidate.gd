extends RefCounted
## RouteCandidate — one proposed answer to a RouteTask.
##
## A candidate carries the geometry (segments + vias) proposed for a net plus two
## INDEPENDENT status axes and enough versioning to tell whether it is stale
## relative to the board it was generated against.
##
## ── TWO ORTHOGONAL AXES (never coupled) ───────────────────────────────────────
##   disposition ∈ DISPOSITIONS — the user/workflow decision about the candidate
##                (proposed → pinned/superseded/rejected/committed).
##   validation  ∈ VALIDATIONS  — the DRC/geometry health of the candidate
##                (unchecked → checking → clean/violating/stale/error).
## They live in SEPARATE backing fields with SEPARATE validating setters, so
## setting one can never mutate the other. Each setter rejects out-of-set values
## (push_warning, value unchanged).
##
## ── MULTI-PAD TOPOLOGY (INV-3 trap) ───────────────────────────────────────────
## segments[] are INDEPENDENT entities — each its own ordered points + layer +
## width + id. A candidate for a multi-pad net whose route forms ≥2 DISCONNECTED
## copper paths is represented as ≥2 segments with NO shared-endpoint / single-
## chain assumption anywhere in this model. Do not add a "connected chain"
## invariant: it is exactly what bit the router (INV-3).
##
## Off-tree plugin: NO class_name; relative preload + duck typing. Vector2 fields
## serialise to {"x","y"} for JSON safety. GDScript JSON gotcha: whole numbers
## round-trip as float — int fields cast with int() on load.

const _Self := preload("pcb_route_candidate.gd")
const PcbLayerStack := preload("pcb_layer_stack.gd")
const PcbRouteTask := preload("pcb_route_task.gd")

## Legal values for the two orthogonal status axes.
const DISPOSITIONS := ["proposed", "pinned", "superseded", "rejected", "committed"]
const VALIDATIONS := ["unchecked", "checking", "clean", "violating", "stale", "error"]

## Identity / versioning.
var candidate_id: String = ""       ## stable, workspace-scoped (e.g. "cand_1")
var task_id: String = ""            ## the RouteTask this answers
var net: String = ""               ## net being routed
var endpoints: Array = []          ## copied from the task (same shape as RouteTask.endpoints)
var generation: int = 0            ## which generation/attempt produced this
var base_board_revision: int = 0   ## PCBData.board_revision at generation time
var candidate_revision: int = 0    ## bumps on every edit to this candidate's geometry

## Geometry. Segments and vias are plain dicts (host_owned / JSON-friendly), each
## carrying its own stable id (assigned by the owning workspace's counters).
##   segment: {"id","layer","width","points":Array[Vector2],"locked"}
##   via:     {"id","position":Vector2,"from_layer","to_layer","diameter","drill","locked"}
var segments: Array = []
var vias: Array = []

## Ids of the route-hints this candidate was generated from (provenance).
var source_hint_ids: Array[String] = []

## ── axis 1: disposition ───────────────────────────────────────────────────────
var _disposition: String = "proposed"
var disposition: String:
	get:
		return _disposition
	set(value):
		set_disposition(value)

## ── axis 2: validation ────────────────────────────────────────────────────────
var _validation: String = "unchecked"
var validation: String:
	get:
		return _validation
	set(value):
		set_validation(value)


## Validating setter for the disposition axis. Rejects out-of-set values and does
## NOT touch the validation axis.
func set_disposition(value: String) -> void:
	if value in DISPOSITIONS:
		_disposition = value
	else:
		push_warning("[RouteCandidate] ignored invalid disposition '%s'" % value)


## Validating setter for the validation axis. Rejects out-of-set values and does
## NOT touch the disposition axis.
func set_validation(value: String) -> void:
	if value in VALIDATIONS:
		_validation = value
	else:
		push_warning("[RouteCandidate] ignored invalid validation '%s'" % value)


# ── geometry builders ─────────────────────────────────────────────────────────

## Build a segment dict (does NOT append — the workspace owns id assignment and
## appends). points is an ordered Array[Vector2].
static func make_segment(id: String, layer: String, width: float, points: Array, locked: bool = false) -> Dictionary:
	var pts: Array = []
	for p in points:
		pts.append(p)
	return {"id": id, "layer": layer, "width": width, "points": pts, "locked": locked}


## Build a via dict.
static func make_via(id: String, position: Vector2, from_layer: String, to_layer: String, diameter: float = 0.8, drill: float = 0.4, locked: bool = false) -> Dictionary:
	return {
		"id": id, "position": position,
		"from_layer": from_layer, "to_layer": to_layer,
		"diameter": diameter, "drill": drill, "locked": locked,
	}


func add_segment(seg: Dictionary) -> void:
	segments.append(seg)


func add_via(via: Dictionary) -> void:
	vias.append(via)


# ── via-span legality (surfaced via the shared PcbLayerStack contract) ─────────

## True iff a single via's from_layer/to_layer is a legal span. This is how the
## candidate SURFACES span legality: it defers to the one canonical contract
## (PcbLayerStack.is_legal_via_span) rather than re-encoding the top/bottom rule.
## A same-layer / unknown-layer span returns false.
func via_span_legal(via: Dictionary) -> bool:
	return PcbLayerStack.is_legal_via_span(via.get("from_layer", ""), via.get("to_layer", ""))


## True iff every via on this candidate has a legal span.
func all_via_spans_legal() -> bool:
	for v in vias:
		if not via_span_legal(v):
			return false
	return true


## Ids of vias whose span is ILLEGAL (empty ⇒ all legal). Callers/UI flag these;
## the model does not silently drop them (they round-trip like any other via).
func illegal_via_span_ids() -> Array:
	var out: Array = []
	for v in vias:
		if not via_span_legal(v):
			out.append(str(v.get("id", "")))
	return out


# ── serialisation (round-trips EVERY field incl. stable ids + both axes) ───────

func to_dict() -> Dictionary:
	var seg_out: Array = []
	for s in segments:
		seg_out.append(_segment_to_json(s))
	var via_out: Array = []
	for v in vias:
		via_out.append(_via_to_json(v))
	var eps: Array = []
	for e in endpoints:
		eps.append(PcbRouteTask._endpoint_to_json(e))
	var hints: Array = []
	for h in source_hint_ids:
		hints.append(str(h))
	return {
		"candidate_id": candidate_id,
		"task_id": task_id,
		"net": net,
		"endpoints": eps,
		"generation": generation,
		"base_board_revision": base_board_revision,
		"candidate_revision": candidate_revision,
		"segments": seg_out,
		"vias": via_out,
		"source_hint_ids": hints,
		"disposition": _disposition,
		"validation": _validation,
	}


func load_from_dict(data: Dictionary) -> void:
	candidate_id = str(data.get("candidate_id", ""))
	task_id = str(data.get("task_id", ""))
	net = str(data.get("net", ""))
	# int() casts tolerate whole-number floats from JSON round-trips.
	generation = int(data.get("generation", 0))
	base_board_revision = int(data.get("base_board_revision", 0))
	candidate_revision = int(data.get("candidate_revision", 0))

	endpoints.clear()
	for e in data.get("endpoints", []):
		endpoints.append(PcbRouteTask._endpoint_from_json(e))

	segments.clear()
	for s in data.get("segments", []):
		if s is Dictionary:
			segments.append(_segment_from_json(s))

	vias.clear()
	for v in data.get("vias", []):
		if v is Dictionary:
			vias.append(_via_from_json(v))

	source_hint_ids.clear()
	for h in data.get("source_hint_ids", []):
		source_hint_ids.append(str(h))

	# Route through the validating setters (bad stored values fall back to defaults).
	set_disposition(str(data.get("disposition", "proposed")))
	set_validation(str(data.get("validation", "unchecked")))


static func from_dict(data: Dictionary):
	var c := _Self.new()
	c.load_from_dict(data)
	return c


# ── JSON helpers for segment/via geometry (Vector2 <-> {x,y}) ──────────────────

static func _segment_to_json(seg: Dictionary) -> Dictionary:
	var pts: Array = []
	for p in seg.get("points", []):
		if p is Vector2:
			pts.append({"x": p.x, "y": p.y})
		elif p is Dictionary:
			pts.append(p)
	return {
		"id": str(seg.get("id", "")),
		"layer": str(seg.get("layer", "top")),
		"width": float(seg.get("width", 0.25)),
		"points": pts,
		"locked": bool(seg.get("locked", false)),
	}


static func _segment_from_json(seg: Dictionary) -> Dictionary:
	var pts: Array = []
	for p in seg.get("points", []):
		if p is Dictionary:
			pts.append(Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))))
		elif p is Vector2:
			pts.append(p)
	return {
		"id": str(seg.get("id", "")),
		"layer": str(seg.get("layer", "top")),
		"width": float(seg.get("width", 0.25)),
		"points": pts,
		"locked": bool(seg.get("locked", false)),
	}


static func _via_to_json(via: Dictionary) -> Dictionary:
	var out: Dictionary = via.duplicate(true)
	if out.has("position") and out["position"] is Vector2:
		var p: Vector2 = out["position"]
		out["position"] = {"x": p.x, "y": p.y}
	return out


static func _via_from_json(via: Dictionary) -> Dictionary:
	var out: Dictionary = via.duplicate(true)
	if out.has("position") and out["position"] is Dictionary:
		var pd: Dictionary = out["position"]
		out["position"] = Vector2(float(pd.get("x", 0.0)), float(pd.get("y", 0.0)))
	out["diameter"] = float(out.get("diameter", 0.8))
	out["drill"] = float(out.get("drill", 0.4))
	out["locked"] = bool(out.get("locked", false))
	out["id"] = str(out.get("id", ""))
	return out
