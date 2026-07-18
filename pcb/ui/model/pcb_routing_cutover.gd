extends RefCounted
## RoutingCutover — the strangler-fig CUTOVER COORDINATOR (T2.3). Holds a
## per-surface AUTHORITY flag deciding, surface by surface, whether the legacy
## annotation store or the plugin-owned RoutingWorkspace is the source of truth
## for that surface. This is the MECHANISM only: in T2.3 every surface defaults
## to (and stays at) "annotation" — later tasks flip individual surfaces once
## their WRITE path is genuinely workspace-backed (T3 canvas rendering, T5 the
## legacy verbs), and the whole shadow window relies on nothing here being
## flipped yet.
##
## ── Why a flag object and not a bool ──────────────────────────────────────────
## The cutover is INCREMENTAL: canvas rendering (T3) flips before the Accept/
## Reject/Add-Via verbs (T5), which flip before persistence. A single global
## bool cannot represent "canvas reads the workspace but the verbs still mutate
## annotations", which is exactly the mid-migration state. Each surface is an
## independent latch so the migration can advance and — critically — ROLL BACK
## one surface at a time without disturbing the others.
##
## ── The flip contract (never flip on a hope) ──────────────────────────────────
## set_workspace_authoritative(surface, workspace_backed) flips a surface to
## "workspace" ONLY when the caller ASSERTS (workspace_backed == true) that this
## surface's WRITE path is already workspace-backed. Passing false is a no-op
## that warns — you cannot flip a surface whose writes still land on annotations
## (that would read from the workspace while writes bypass it → silent
## divergence). rollback()/set_annotation_authoritative() always succeeds and
## always leaves the OLD (annotation) UI coherent, because the annotation store
## was never stopped being written during the shadow window.
##
## Off-tree plugin: NO class_name; relative preload + duck typing.

const _Self := preload("pcb_routing_cutover.gd")

## Emitted when a surface's authority changes (surface, new_authority).
signal authority_changed(surface: String, authority: String)

## The surfaces whose authority is tracked independently. Fixed set — an
## unknown surface name is rejected (never silently created) so a typo can
## never mint a phantom always-annotation surface.
const SURFACES := ["canvas", "inspector", "verbs", "mcp", "persistence", "drc"]

const ANNOTATION := "annotation"
const WORKSPACE := "workspace"

## surface -> "annotation" | "workspace". Every surface starts annotation-
## authoritative (legacy is the source of truth until a surface is proven
## workspace-backed).
var _authority: Dictionary = {}


func _init() -> void:
	for s in SURFACES:
		_authority[s] = ANNOTATION


## True iff `surface` currently reads/writes the RoutingWorkspace as its source
## of truth. Unknown surfaces read as NOT workspace-authoritative (fail-safe:
## an unrecognised surface can never be treated as migrated).
func is_workspace_authoritative(surface: String) -> bool:
	return _authority.get(surface, ANNOTATION) == WORKSPACE


## The raw authority string for `surface` ("annotation" for unknown surfaces).
func authority(surface: String) -> String:
	return str(_authority.get(surface, ANNOTATION))


## Flip `surface` to workspace-authoritative — ALLOWED ONLY when the caller
## asserts (workspace_backed == true) that this surface's WRITE path is already
## workspace-backed. Returns true on a successful flip. Rejects (returns false,
## warns) an unknown surface OR workspace_backed == false — you must not read a
## surface from the workspace while its writes still bypass it. Idempotent: a
## surface already at "workspace" flips to "workspace" again as a true no-op.
func set_workspace_authoritative(surface: String, workspace_backed: bool) -> bool:
	if not (surface in SURFACES):
		push_warning("[RoutingCutover] unknown surface '%s' — flip rejected" % surface)
		return false
	if not workspace_backed:
		push_warning("[RoutingCutover] refusing to flip '%s' to workspace: caller did not assert a workspace-backed write path" % surface)
		return false
	var changed: bool = _authority.get(surface, ANNOTATION) != WORKSPACE
	_authority[surface] = WORKSPACE
	if changed:
		authority_changed.emit(surface, WORKSPACE)
	return true


## Roll a surface back to annotation-authoritative. Always succeeds (the
## annotation store was written throughout the shadow window, so the old UI is
## always coherent to fall back to). Unknown surfaces are a no-op.
func set_annotation_authoritative(surface: String) -> void:
	if not (surface in SURFACES):
		return
	var changed: bool = _authority.get(surface, ANNOTATION) != ANNOTATION
	_authority[surface] = ANNOTATION
	if changed:
		authority_changed.emit(surface, ANNOTATION)


## Alias for set_annotation_authoritative — reads clearly at rollback call sites.
func rollback(surface: String) -> void:
	set_annotation_authoritative(surface)


## True iff NO surface has been flipped — the T2.3 default state (mechanism
## present, nothing cut over). Tests and the panel assert this in the shadow
## window.
func all_annotation_authoritative() -> bool:
	for s in SURFACES:
		if _authority.get(s, ANNOTATION) != ANNOTATION:
			return false
	return true


## Snapshot the authority map (copy — callers cannot mutate internal state).
func to_dict() -> Dictionary:
	return _authority.duplicate()


func load_from_dict(data: Dictionary) -> void:
	for s in SURFACES:
		var v := str(data.get(s, ANNOTATION))
		_authority[s] = v if v == WORKSPACE else ANNOTATION


static func from_dict(data: Dictionary):
	var c = _Self.new()
	c.load_from_dict(data)
	return c
