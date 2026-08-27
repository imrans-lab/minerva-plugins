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
const PcbViaDimensions := preload("pcb_via_dimensions.gd")

## Legal values for the two orthogonal status axes.
const DISPOSITIONS := ["proposed", "pinned", "frozen", "superseded", "rejected", "committed"]
const VALIDATIONS := ["unchecked", "checking", "clean", "violating", "stale", "error"]

## ── DISPOSITION TRANSITION LEGALITY TABLE ─────────────────────────────────────
## from → the dispositions it may legally move to. An IDENTITY move (x → x) is
## always legal and is a no-op: re-asserting the state a candidate is already in
## is not a transition, and refusing it would force every caller to guard its own
## writes. Anything else not listed here is REFUSED with a named error (see
## transition_error); the workspace surfaces the refusal rather than silently
## clamping, so an illegal workflow verb is visibly rejected, never half-applied.
##
## Rationale per row (DCR 019f7095c395 vocabulary: Accept/Commit, Keep/Pin,
## Reject, Try-again):
##   proposed   — the live draft: the FULL fan-out. Pin it (Keep), replace it
##                (Try-again ⇒ superseded), discard it (Reject), or commit it
##                (Accept).
##   pinned     — still a DRAFT, not copper. → proposed is Unpin. → superseded is
##                an explicit user Try-again on the same task; the pin is dropped
##                from the live keep-out set and the geometry survives as audit,
##                so nothing is silently lost. → rejected is a later, stronger
##                intent than the earlier pin. → committed because pinning must
##                not block Accept (the DCR's "Edit … and pin it", then commit).
##                → frozen is the ESCALATION: the user promotes a hold into a
##                settlement (Epoch UX3, K7).
##   frozen     — SETTLED, not copper (K7/K8: "accepted or frozen proposals
##                become obstacles … good traces stay fixed"). Frozen is a
##                STRONGER pin, and its teeth are exactly the moves it refuses:
##                NO reject, NO supersede, NO geometry edit while frozen — a
##                settled route cannot be discarded or reshaped by a single
##                verb, targeted or batch; the demotion (unfreeze → proposed)
##                must come first, so destroying settled work is always a
##                visible two-step. The two exits: → proposed is Unfreeze (the
##                deliberate demotion), → committed because freezing must not
##                block Accept — settled geometry becoming copper is the loop's
##                happy path. NOT terminal: frozen stays in the LIVE set (it is
##                draft-checked, rendered, and routed AROUND as fixed copper).
##                frozen → pinned is deliberately ABSENT: no verb demotes a
##                settlement into a mere hold, and a legal-but-verbless row
##                would silently re-enable the Pin menu item on frozen ghosts.
##                SCOPE (cold review finding 6): "always a two-step" binds the
##                WORKFLOW-VERB surface this table governs. The RESTORE paths
##                (load_from_dict, RoutingWorkspace.restore_dispositions — the
##                compensating half of a board undo) write through the raw
##                setter by their own documented contract and may reinstate
##                whatever disposition the snapshot recorded, frozen included;
##                a board undo rewinding past a freeze rewinds the freeze too.
##   superseded — TERMINAL. A superseded candidate is the historical record of a
##                replaced generation. Reviving it (→ proposed/pinned) would put
##                TWO live candidates on one task and break the one-live-answer
##                invariant candidates_for_task/_task_candidate depend on;
##                rejecting a candidate that already left the live set carries no
##                user meaning. The way "back" is a new propose, not a revival.
##   rejected   — TERMINAL. Reject means discard-and-reopen-the-task; the way
##                back is a NEW candidate from a new propose, so an un-reject
##                would resurrect stale geometry the user already refused.
##   committed  — TERMINAL for every WORKFLOW verb: once the copper is on the
##                board, pin/reject/supersede are meaningless against the
##                candidate. The ONE exit is UNCOMMIT (see UNCOMMIT_TARGETS),
##                which is a COMPENSATING transition mirroring a board undo, not
##                a workflow decision.
const DISPOSITION_TRANSITIONS := {
	"proposed": ["pinned", "frozen", "superseded", "rejected", "committed"],
	"pinned": ["proposed", "frozen", "superseded", "rejected", "committed"],
	"frozen": ["proposed", "committed"],
	"superseded": [],
	"rejected": [],
	"committed": [],
}

## Dispositions no WORKFLOW verb may leave (see the table's rationale).
const TERMINAL_DISPOSITIONS := ["superseded", "rejected", "committed"]

## The ONLY exits from "committed", and NOT a workflow verb: uncommit is the
## compensating half of a board undo (the board no longer holds the candidate's
## copper, so the candidate must become live again). It may only restore a
## disposition the candidate could have HELD before commit — proposed, pinned,
## or frozen (frozen → committed is legal, so a board undo of that commit must
## be able to reinstate the settlement it consumed).
## Reached via uncommit_to(), never via transition_to(), so a caller can never
## reach it by accident. Shipped + pinned by test_parity_bridge.gd (GATE INV-1).
const UNCOMMIT_TARGETS := ["proposed", "pinned", "frozen"]

## Named refusal codes (the "named error" a refused transition reports).
const ERR_UNKNOWN_DISPOSITION := "unknown_disposition"
const ERR_TERMINAL_DISPOSITION := "terminal_disposition"
const ERR_ILLEGAL_TRANSITION := "illegal_disposition_transition"
const ERR_NOT_COMMITTED := "not_committed"

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

## ── P1-B (Codex 1047, consolidated review): CONSTRAINT provenance ─────────────
## Which task-constraint revision GENERATED this candidate, and the per-hint
## status the router reported doing it. Pre-fix these were stamped only onto
## the immediate propose/reroute reply dictionaries — they vanished from every
## later workspace listing and from sidecar reloads, so a candidate generated
## against an OLD constraint (steer bumped the revision, the reroute then
## failed) was indistinguishable from a current one and could be silently
## committed. -1 = generated with no constraint in play (also every candidate
## persisted before this field existed). The workspace's commit preflight
## compares this against the governing tasks' CURRENT constraint revisions and
## refuses a stale commit (ERR_CONSTRAINT_STALE in pcb_routing_workspace.gd).
var constraint_revision: int = -1

## Per-hint router status captured at generation ([{hint_id, status, ...}], the
## same records the reply's hint_status carries — corridor_adherence included
## when the router reported it). Empty when the router reported nothing.
var hint_status: Array = []

## OFC-3 (epoch 019ff9421d3f): the LIVE placement ghosts the composed draft
## board carried when this candidate was generated — [{id, component_id,
## to:{x_mm, y_mm, rotation_deg}}]. Empty for candidates routed against the
## real board (no ghosts live at generation). The candidate's copper is only
## valid in a world where each snapshot pose LANDS: commit gates on it, and
## every listing derives a per-ghost status (satisfied/pending/invalidated)
## from the CURRENT board + store — deliberately not event-driven, because
## ghost pose edits are scratch (no board-revision bump), so the
## base_board_revision staleness idiom above cannot see them.
var draft_placements: Array = []

## WIDTH PROVENANCE (UX4 station 10, work item 019fd0ab5af8): which source
## sized this candidate's copper — DURABLE state like constraint_revision
## (P1-B's precedent), so a review surface can tell an INTENDED 0.25mm from a
## SILENT fallback to it. Vocabulary: the worker's effective-rules words
## ("caller_option"/"hint"/"board_rules"/"engine_default"/"net_class"/
## "net_copper" — the last one meaning the width this net's OWN EXISTING copper
## established) when
## the route carried them, else the workspace's own ingest verdict ("hint" |
## "default" | "caller_option"). "" = generated before this field existed.
var width_source: String = ""

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


## RAW validating setter for the disposition axis. Rejects out-of-set values and
## does NOT touch the validation axis.
##
## NOTE (C1): this is the SET-MEMBERSHIP setter only — it deliberately does NOT
## consult DISPOSITION_TRANSITIONS, because it is also the RESTORE path
## (load_from_dict must be able to reinstate a stored "superseded"/"rejected"/
## "committed" on a freshly constructed candidate, which is not a workflow
## transition at all). WORKFLOW verbs must go through transition_to() below, or
## through RoutingWorkspace's pin/unpin/reject/mark_committed/uncommit, which
## funnel every workflow move through the legality table.
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


# ── disposition transition gate ───────────────────────────────────────────────

## The named error for moving `from` → `to`, or "" when the move is LEGAL.
## Identity moves are legal (no-op). Order of checks matters: an unknown value is
## reported as unknown BEFORE any terminal/legality verdict, so a typo is never
## mis-reported as a workflow violation.
static func transition_error(from: String, to: String) -> String:
	if not (from in DISPOSITIONS) or not (to in DISPOSITIONS):
		return ERR_UNKNOWN_DISPOSITION
	if from == to:
		return ""  # identity: re-asserting the current state is not a transition
	if to in (DISPOSITION_TRANSITIONS.get(from, []) as Array):
		return ""
	if from in TERMINAL_DISPOSITIONS:
		return ERR_TERMINAL_DISPOSITION
	return ERR_ILLEGAL_TRANSITION


## True iff this candidate may legally move to `to` right now.
func can_transition_to(to: String) -> bool:
	return transition_error(_disposition, to).is_empty()


## GATED workflow mutator: move the disposition to `to`. Returns "" on success
## (value applied) or the NAMED error on refusal (value UNCHANGED — a refused
## transition is never half-applied). The validation axis is never touched.
func transition_to(to: String) -> String:
	var err := transition_error(_disposition, to)
	if not err.is_empty():
		return err
	_disposition = to
	return ""


## COMPENSATING exit from "committed" (see UNCOMMIT_TARGETS). Returns "" on
## success or a named error: ERR_NOT_COMMITTED when the candidate is not
## committed, ERR_ILLEGAL_TRANSITION when `to` is not a legal uncommit target.
func uncommit_to(to: String) -> String:
	if _disposition != "committed":
		return ERR_NOT_COMMITTED
	if not (to in UNCOMMIT_TARGETS):
		return ERR_ILLEGAL_TRANSITION
	_disposition = to
	return ""


# ── board-revision staleness (per candidate) ──────────────────────────────────

## True iff this candidate was generated against a DIFFERENT board revision than
## `board_revision` — i.e. the board moved underneath it. int() on both sides
## because a JSON round-trip hands back whole numbers as float (5.0 != 5 under
## GDScript's type-strict ==).
func is_stale_for_board_revision(board_revision: int) -> bool:
	return int(base_board_revision) != int(board_revision)


# ── geometry builders ─────────────────────────────────────────────────────────

## Build a segment dict (does NOT append — the workspace owns id assignment and
## appends). points is an ordered Array[Vector2].
static func make_segment(id: String, layer: String, width: float, points: Array, locked: bool = false) -> Dictionary:
	var pts: Array = []
	for p in points:
		pts.append(p)
	return {"id": id, "layer": layer, "width": width, "points": pts, "locked": locked}


## Build a via dict.
##
## The diameter/drill DEFAULTS are the last-resort constants, not a policy: a
## caller that has a board must resolve them through PcbViaDimensions and pass
## the answer. Leaving 0.8/0.4 as bare literals here is what made every ingested
## candidate via ignore design_rules (bug 01a03b87473c) — the sizes were stamped
## before anything with a board ever saw the via, and the downstream rescue only
## fires on a ZERO stamp.
static func make_via(id: String, position: Vector2, from_layer: String, to_layer: String, diameter: float = PcbViaDimensions.DEFAULT_DIAMETER_MM, drill: float = PcbViaDimensions.DEFAULT_DRILL_MM, locked: bool = false) -> Dictionary:
	return {
		"id": id, "position": position,
		"from_layer": from_layer, "to_layer": to_layer,
		"diameter": diameter, "drill": drill, "locked": locked,
	}


func add_segment(seg: Dictionary) -> void:
	segments.append(seg)


func add_via(via: Dictionary) -> void:
	vias.append(via)


## True iff `candidate` is a PROPOSED VIA ENTITY — the ghost
## minerva_pcb_propose_via / the canvas Via-proposal gesture mint: exactly one
## via, no copper, and its own `proposed_entity` mark.
##
## THE MARK, NOT THE SHAPE (work item 01a04106bd). Ownership made "has no
## provenance" useless as the test — a via ghost now records the route hint it
## SERVES on source_hint_ids — and the shape alone is ambiguous, because a
## router candidate can legitimately come back vias-only on a partial answer.
## Only propose_via stamps the mark, so only it matches.
##
## Every surface that must tell "a hole somebody proposed" from "an answer to a
## routing question" asks HERE: commit's consumed-hint record, the hint's render
## mode, the lifecycle reconcile, reroute scoping, and the listing's owner label.
## Static + duck-typed so the annotation kind can reach it without a workspace.
static func is_proposed_via_entity(candidate) -> bool:
	# `in` guards, not bare reads: callers hand this duck-typed objects (the
	# annotation kind's workspace walk is explicitly degrade-tolerant), and a
	# stand-in without these members must answer "no", not error.
	if candidate == null or not ("segments" in candidate) or not ("vias" in candidate):
		return false
	if not (candidate.segments as Array).is_empty():
		return false
	if (candidate.vias as Array).size() != 1:
		return false
	var only_via = (candidate.vias as Array)[0]
	return only_via is Dictionary \
		and bool((only_via as Dictionary).get("proposed_entity", false))


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
		"constraint_revision": constraint_revision,
		"hint_status": hint_status.duplicate(true),
		"width_source": width_source,
		"draft_placements": draft_placements.duplicate(true),
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

	# P1-B: absent on every pre-provenance record — defaults to -1/[] (the
	# "generated unconstrained / unknown" shape), int() for the JSON float.
	constraint_revision = int(data.get("constraint_revision", -1))
	hint_status = (data.get("hint_status", []) as Array).duplicate(true) \
		if data.get("hint_status", []) is Array else []
	# UX4 station 10: absent on pre-provenance records — "" means unknown.
	width_source = str(data.get("width_source", ""))
	# OFC-3: absent on pre-provenance records — [] means "routed against the
	# real board" (also the honest default for legacy sidecars: no gate).
	draft_placements = (data.get("draft_placements", []) as Array).duplicate(true) \
		if data.get("draft_placements", []) is Array else []

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
