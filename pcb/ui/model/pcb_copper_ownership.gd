extends RefCounted
## PcbCopperOwnership — does this route candidate REALLY own the copper carrying
## the id it recorded?
##
## ── WHY OWNERSHIP IS CHECKED, NOT ASSUMED ────────────────────────────────────
## A committed candidate records the ids of the copper its commit produced
## (RoutingWorkspace.correlations[cid].committed_trace_ids / _via_ids). Every
## consumer then treated that recorded id as PROOF of ownership — "is trace_5
## still on the board?" was the whole test. That is only sound while an id is
## never re-issued, and it was not: pcb.deserialize's v1→v2 migration re-minted
## the ordinal ids on every load_board, so a sidecar's "trace_5" came back
## pointing at whatever the panel happened to number trace_5 NEXT — usually
## freshly drawn copper on a completely different net. Deleting that copper then
## retired a stranger's commit, reopened its routing task, and told the caller
## "this copper was committed by 1 route candidate". A false attribution, on the
## reply, about work the user never did.
##
## PcbEntityId's minted ids close the re-issue hole going forward. This file
## closes the trust hole: ownership is a CHECK, not an assumption, so a record
## written before the fix — or hand-edited, or carried across a document switch —
## can never re-attach itself to whatever now carries that id.
##
## ── THE RULE ──────────────────────────────────────────────────────────────────
## Candidate C owns the copper carrying id X iff ALL of:
##   1. IDENTITY — X resolves to copper on the board. It does not     ⇒ MISSING.
##   2. NET      — that copper's net is C's net. It is not            ⇒ FOREIGN.
##   3. PLACE    — that copper's bounds intersect C's own geometry bounds, grown
##                 by BOUNDS_MARGIN_MM. They do not                   ⇒ FOREIGN.
## MISSING and FOREIGN mean different things and callers must not merge them:
## MISSING is "the candidate's copper was deleted" (retire the commit, reopen the
## task — a true, useful report); FOREIGN is "this record is lying" (drop the
## claim, report a finding, attribute nothing).
##
## PLACE IS A TIEBREAK, not a fence. It is an INTERSECTION against a generous
## margin, deliberately: a committed trace that was later cut or extended is
## still the candidate's copper (retire_commits_owning_trace is what handles an
## edit), and only a record pointing at copper somewhere else entirely should
## fail. It exists for the case identity and net cannot separate — two candidates
## on the same net.
##
## Checks 2 and 3 read the CANDIDATE's own net and geometry, so nothing new has
## to be written into the sidecar and a record from before this file is checked
## exactly as strictly as one written after it.
##
## Off-tree plugin: NO class_name; reached by relative preload. Pure statics over
## plain data — it takes a COPPER INDEX, so the same rule serves the live board
## object (reconcile) and a board dict (sidecar restore, which has no PCBData).

## How far outside a candidate's own bounds copper may sit and still read as its
## own. Sized for post-commit edits (a cut or a nudged waypoint), not for telling
## two neighbouring candidates apart — check 2 does that.
const BOUNDS_MARGIN_MM := 2.0

## audit() verdicts.
const OWNED := "owned"
const MISSING := "missing"
const FOREIGN := "foreign"


## Copper index over a LIVE PCBData: id -> {"net": String, "bounds": Rect2}.
## Traces and vias share one map — their minted ids live in separate domains
## ("trace:…" vs "via:…") and legacy ordinals are prefixed too, so a key can
## never mean both.
static func index_from_board(board) -> Dictionary:
	var out: Dictionary = {}
	if board == null or not is_instance_valid(board):
		return out
	if board.has_method("get_trace_ids") and board.has_method("get_trace"):
		for raw_id in board.get_trace_ids():
			var tid := str(raw_id)
			var trace = board.get_trace(tid)
			if trace == null or tid.is_empty():
				continue
			out[tid] = {"net": str(trace.net_name),
				"bounds": _bounds_of_points(trace.waypoints)}
	var via_list = board.get("vias")
	if via_list is Array:
		for entry in (via_list as Array):
			if not (entry is Dictionary):
				continue
			var via: Dictionary = entry
			var vid := str(via.get("id", ""))
			if vid.is_empty():
				continue
			var pos = via.get("position", Vector2.ZERO)
			var p := Vector2.ZERO
			if pos is Vector2:
				p = pos
			elif pos is Dictionary:
				p = Vector2(float((pos as Dictionary).get("x", 0.0)),
					float((pos as Dictionary).get("y", 0.0)))
			out[vid] = {"net": str(via.get("net_name", "")), "bounds": Rect2(p, Vector2.ZERO)}
	return out


## Copper index over a CANONICAL board dict (PCBData.to_board_dict / the dict the
## sidecar restore is handed). Same shape as index_from_board.
static func index_from_dict(board_dict: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var traces = board_dict.get("traces", [])
	if traces is Array:
		for entry in (traces as Array):
			if not (entry is Dictionary):
				continue
			var t: Dictionary = entry
			var tid := str(t.get("id", ""))
			if tid.is_empty():
				continue
			var pts: Array = []
			var raw_points = t.get("points", [])
			if raw_points is Array:
				for p in (raw_points as Array):
					if p is Dictionary:
						pts.append(Vector2(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0))))
			out[tid] = {"net": str(t.get("net", "")), "bounds": _bounds_of_points(pts)}
	var vias = board_dict.get("vias", [])
	if vias is Array:
		for entry in (vias as Array):
			if not (entry is Dictionary):
				continue
			var v: Dictionary = entry
			var vid := str(v.get("id", ""))
			if vid.is_empty():
				continue
			var p := Vector2(float(v.get("x_mm", 0.0)), float(v.get("y_mm", 0.0)))
			out[vid] = {"net": str(v.get("net", "")), "bounds": Rect2(p, Vector2.ZERO)}
	return out


## Union of a candidate's own segment points and via positions, grown by
## BOUNDS_MARGIN_MM. Returns an EMPTY-position Rect2 with a negative size when
## the candidate carries no geometry at all — verdict_for() reads that as "no
## place to compare against" and skips check 3 rather than failing it.
static func candidate_bounds(candidate) -> Rect2:
	var pts: Array = []
	if candidate == null:
		return _no_bounds()
	var segs = candidate.get("segments")
	if segs is Array:
		for entry in (segs as Array):
			if not (entry is Dictionary):
				continue
			var seg_points = (entry as Dictionary).get("points", [])
			if seg_points is Array:
				for p in (seg_points as Array):
					if p is Vector2:
						pts.append(p)
	var vias = candidate.get("vias")
	if vias is Array:
		for entry in (vias as Array):
			if not (entry is Dictionary):
				continue
			var pos = (entry as Dictionary).get("position", null)
			if pos is Vector2:
				pts.append(pos)
	if pts.is_empty():
		return _no_bounds()
	return _bounds_of_points(pts).grow(BOUNDS_MARGIN_MM)


## OWNED / MISSING / FOREIGN for one recorded id, against one candidate.
## `bounds` is candidate_bounds(candidate), passed in so a whole record costs one
## union rather than one per id.
static func verdict_for(candidate, copper_index: Dictionary, id: String,
		bounds: Rect2) -> String:
	if id.is_empty() or not copper_index.has(id):
		return MISSING
	var entry: Dictionary = copper_index[id]
	# Check 2 — NET. Skipped only when the candidate names no net at all (a
	# malformed candidate); an EMPTY net on the copper still fails against a
	# candidate that names one, which is the point.
	var want_net := str(candidate.net) if candidate != null else ""
	if not want_net.is_empty() and str(entry.get("net", "")) != want_net:
		return FOREIGN
	# Check 3 — PLACE. Skipped when either side has no geometry to compare.
	var copper_bounds: Rect2 = entry.get("bounds", _no_bounds())
	if bounds.size.x >= 0.0 and copper_bounds.size.x >= 0.0:
		if not bounds.intersects(copper_bounds, true):
			return FOREIGN
	return OWNED


## Audit a whole ownership record. Returns
##   {"owned_trace_ids", "owned_via_ids",   # the claim that survives
##    "missing_trace_ids", "missing_via_ids",  # copper genuinely gone
##    "foreign_trace_ids", "foreign_via_ids"}  # the record is lying
## Trace and via ids stay in separate lists because their callers act on them
## separately (remove_trace vs remove_via_by_id, missing_trace_ids vs
## missing_via_ids on the reply).
static func audit(candidate, copper_index: Dictionary, trace_ids: Array,
		via_ids: Array) -> Dictionary:
	var bounds := candidate_bounds(candidate)
	var out := {
		"owned_trace_ids": [], "owned_via_ids": [],
		"missing_trace_ids": [], "missing_via_ids": [],
		"foreign_trace_ids": [], "foreign_via_ids": [],
	}
	for raw in trace_ids:
		var tid := str(raw)
		match verdict_for(candidate, copper_index, tid, bounds):
			OWNED: (out["owned_trace_ids"] as Array).append(tid)
			MISSING: (out["missing_trace_ids"] as Array).append(tid)
			_: (out["foreign_trace_ids"] as Array).append(tid)
	for raw in via_ids:
		var vid := str(raw)
		match verdict_for(candidate, copper_index, vid, bounds):
			OWNED: (out["owned_via_ids"] as Array).append(vid)
			MISSING: (out["missing_via_ids"] as Array).append(vid)
			_: (out["foreign_via_ids"] as Array).append(vid)
	return out


## True iff the audit found at least one id whose copper is present but is NOT
## this candidate's — the "this record is lying" signal.
static func has_foreign(audited: Dictionary) -> bool:
	return not (audited.get("foreign_trace_ids", []) as Array).is_empty() \
		or not (audited.get("foreign_via_ids", []) as Array).is_empty()


static func _bounds_of_points(points) -> Rect2:
	var first := true
	var r := Rect2()
	for p in points:
		if not (p is Vector2):
			continue
		if first:
			r = Rect2(p, Vector2.ZERO)
			first = false
		else:
			r = r.expand(p)
	return r if not first else _no_bounds()


## The "no geometry" sentinel: a negative size, which no real bounds can have.
static func _no_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(-1.0, -1.0))
