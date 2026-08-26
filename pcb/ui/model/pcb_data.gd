extends RefCounted
## Main data model for PCB layout with sparse storage for components, nets,
## traces, and vias.
##
## ── Off-tree port note ────────────────────────────────────────────────────────
## Ported from Minerva src/Scripts/UI/Controls/PCBEditor/PCBData.gd for the pcb
## plugin panel (Round A). This model is a sibling the panel adopts in Round B;
## Round B consumes it verbatim, so the mutation/query/signal API mirrors legacy
## method names to minimise UI-port friction.
##
## NO class_name (the plugin lives outside Minerva's res:// tree; plugin-local
## class_names are unresolvable and corrupt the off-tree parser cache). Siblings
## are reached with relative preload(); cross-file object references are
## duck-typed (a static PCB* type annotation would cross files and break the
## cache).
##
## ── What was PORTED / EXCLUDED / CHANGED vs legacy ────────────────────────────
## PORTED: component/net/trace/via state; the history undo stack (panel-internal
##   undo — the platform has no undo primitive yet, item 019f33d282c8); the
##   change_journal (PCB-specific observability, gap register B-10); spatial
##   query helpers; CSV import/export; snap/bounds utilities.
##
## EXCLUDED: annotations{} and route_hints{} storage and every add/get/remove/
##   clear method for them, plus the PCBAnnotation/PCBRouteHint scripts and the
##   annotation_added/annotation_removed/route_hint_added/route_hint_removed
##   signals. The platform annotation substrate (PcbAnnotationHost, a sibling)
##   OWNS these now. from_board_dict() TOLERATES incoming "annotations" /
##   "route_hints" keys by ignoring them (the Go importer passes them through
##   opaquely) — see the note in from_board_dict().
##
## CHANGED:
##   1. Canonical boundary. to_board_dict()/from_board_dict() speak the
##      pcb/internal/board contract exactly (ref/x_mm/y_mm/rotation_deg/width_mm/
##      points/design_rules …) so a board round-trips through pcb.serialize /
##      pcb.deserialize. Render detail rides as canonical component "Extra"
##      (sibling keys), mirroring pcb/internal/board/minpcb.go — NOT a second
##      mapping. Internal field names stay legacy-shaped (position, waypoints,
##      net_name) for Round-B friction; only the boundary is canonical.
##   2. Journal symmetry (gap register C-19). Legacy journalled only 5 of its
##      mutating ops (remove/move/rotate component, remove_trace, add_route_hint)
##      — an asymmetry that made change_journal an unreliable observability feed.
##      This port journals EVERY mutating op symmetrically: add/move/rotate/
##      delete component, net connect/disconnect, net add/remove, trace add/
##      remove, trace clear, via add/remove, and board resize.
##   3. Dropped to_yaml() (legacy one-way emitter) — superseded by the canonical
##      to_board_dict() boundary + the Go pcb.serialize channel, which owns YAML.
##   4. design_rules added as first-class board state so the canonical
##      design_rules block round-trips (legacy had no equivalent).

const PCBComponentScript := preload("pcb_component.gd")
const PCBNetScript := preload("pcb_net.gd")
const PCBTraceScript := preload("pcb_trace.gd")
const PcbLayerStack := preload("pcb_layer_stack.gd")
const PcbTraceGeometry := preload("pcb_trace_geometry.gd")

## Signals for reactive UI updates (panel relays these to drive dirty state).
signal data_changed()
signal component_changed(component_id: String)
signal component_added(component_id: String)
signal component_removed(component_id: String)
signal net_changed(net_name: String)
signal trace_changed(trace_id: String)
signal structure_changed()

## Board properties
var board_width: float = 100.0   # mm
var board_height: float = 100.0  # mm
var grid_size: float = 2.54      # mm (0.1 inch default)
var board_name: String = "Untitled"

## Board layers
var layers: Array[String] = ["top", "bottom"]

## Fabrication-stage tokens, mirroring internal/board/board.go's FabStage*
## constants and worker/pcb_worker/drc.py's FAB_STAGE_*. Three copies exist
## because the three runtimes cannot share a symbol; the Go one is the WRITE
## GATE (validateFabricationStage refuses anything outside the set), so this
## list only ever has to agree with it, never arbitrate.
const FAB_STAGE_ROUTED := "routed"
const FAB_STAGE_ROUTING_DEFERRED := "routing_deferred"
const FAB_STAGE_VIAS_ONLY := "vias_only"
const FAB_STAGES: Array[String] = [
	FAB_STAGE_ROUTED, FAB_STAGE_ROUTING_DEFERRED, FAB_STAGE_VIAS_ONLY]

## THE BOARD'S DECLARED MANUFACTURING INTENT (DCR 01a0033a12a9 change 3).
##
## "routed" is the default and every board that never declares a stage IS one —
## absent and "routed" are the same board, here, in the canonical dict, in Go
## and in the census. The other two say that unrouted nets are the JOB rather
## than a defect: a via-only board is drilled and plated with no copper runs
## intended at all (fiber-laser users cannot drill, so they order the holes and
## lase the runs later), and routing_deferred is the looser case where some
## copper may already exist.
##
## The panel does not DECIDE anything from this — drc.connectivity_completeness
## does. The model's job is to hold the declaration and not lose it.
var fabrication_stage: String = FAB_STAGE_ROUTED

## Board-wide manufacturing constraints (canonical design_rules block, stored as
## a plain dict of canonical keys: clearance_mm, trace_width_mm, via_diameter_mm,
## via_drill_mm, diff_pair_gap_mm, diff_pair_width_mm).
var design_rules: Dictionary = {}

## Sparse storage (like SpreadsheetData.cells)
var components: Dictionary = {}   # component_id -> pcb_component.gd
var nets: Dictionary = {}         # net_name -> pcb_net.gd
var traces: Dictionary = {}       # trace_id -> pcb_trace.gd
var vias: Array[Dictionary] = []  # [{position, size, drill, net_name, from_layer, to_layer}]
var mounting_holes: Array[Dictionary] = []  # [{position, diameter, plated}]

## Authored zones — copper pours and keepouts (docket 019fb43113).
##
## HELD VERBATIM, unlike vias / mounting_holes. Those two are re-shaped into an
## internal dict on the way in ({position: Vector2, size, drill, ...}) because
## the editor MUTATES them and the canvas hit-tests them. Nothing in this build
## edits a zone: they are authored in the board YAML, carried, and drawn. So the
## lossless thing and the simple thing coincide — keep the CANONICAL dict exactly
## as pcb.deserialize handed it over ({id, net, layer, kind, outline:[{x_mm,y_mm}],
## clearance_mm, thermal_*, + any Extra sibling}) and hand the same dict back on
## the way out. No field list to keep in sync with pcb/internal/board's Zone
## struct, and a field added there survives this model without a change here.
##
## `kind` ("copper_pour" | "keepout", per ZoneKind in worker/pcb_worker/
## resolved_board.py) IS a modeled field on the Go Zone struct as of the owner
## ruling of 2026-07-30 (docket 019fb5ad6d20) — it used to ride in Zone.Extra and
## reach the JSON boundary only via internal/board/json.go's inline marshalers.
## It was first-classed because Go's validateZones now BRANCHES on it (a keepout
## needs no net), and a rule that branches on a value cannot read it out of the
## forward-compat junk drawer. Nothing changes on this side: it still arrives as a
## plain `kind` key and round-trips out the same way — exactly once, since a
## modeled field is claimed by the codec and never duplicated into Extra.
##
## `net` is likewise unchanged in shape but no longer universal: a keepout may
## carry no `net` key at all (Go omits it when empty), so every read of a zone's
## net goes through `.get("net", "")`.
##
## ONE key here is NOT carried and is not authored: ZONE_FILL_KEY, a pour's
## compiled fill. See its declaration for how it enters and why it never leaves.
## The board's library lock: {footprint_ref: {sha256, layer?, source?}} (K20,
## DCR 019ffc52c358). Opaque to this model — carried, never adjudicated.
var library_lock: Dictionary = {}

var zones: Array[Dictionary] = []

## Authored cutouts — openings through the ENTIRE board (campaign 2 epoch B, U2
## contract: pcb/internal/board's Cutout struct).
##
## HELD VERBATIM, for the SAME reason zones are (see the `zones` declaration
## just above) — and the reason is even stronger here: a cutout has no fields
## this model would ever need to reshape (no position to drag-normalize, no
## layer to filter on). Canonical dict is exactly what pcb.deserialize hands
## over ({id, outline:[{x_mm,y_mm}], + any Extra sibling}) and exactly what goes
## back out. No field list to keep in sync with Cutout, and a field added there
## survives this model without a change here.
var cutouts: Array[Dictionary] = []

## Undo/redo history
var history: Array[Dictionary] = []
var history_index: int = -1
const MAX_HISTORY_SIZE := 50

## Monotonic-forward board revision (T1 — PcbRoutingWorkspace foundation).
## Increments on EVERY state-changing op — every forward mutation (via
## record_change, the shared mutation hook) AND every undo/redo restore. It is
## FORWARD-ONLY: undo produces a NEW board state, so it BUMPS the counter forward,
## it does NOT roll it back. Rationale: a RouteCandidate stores base_board_revision
## at generation time; a forward-only counter makes "has the board changed AT ALL
## since I was generated?" an unambiguous `board_revision != base_board_revision`.
##
## LOAD-FAMILY EXCLUSIONS (deliberately do NOT bump — they establish a NEW
## baseline, they are not a delta on the current one): clear_traces() bumps
## (delta), but the whole-board loaders load_from_dict()/from_board_dict() and
## clear-and-load paths do NOT — they replace the board wholesale and call
## save_to_history("Load") only. from_csv() is NOT in this family: it is a
## forward in-place merge, so it DOES bump (see from_csv). Rationale:
## base_board_revision answers "did the CURRENT board change since this candidate
## was generated"; loading a (possibly different) board resets the baseline, so a
## bump there would be meaningless rather than a real delta.
var board_revision: int = 0

## Batch-commit state (T5's future composite transaction). NOTE ON WHAT BATCH
## ACTUALLY DOES: mutators here never snapshot history themselves (the CALLER
## decides when to save_to_history), so a batch has no per-mutation snapshots to
## suppress. What it does today is DEFER the per-mutation board_revision bump:
## while a batch is open every mutation's bump is coalesced, and end_batch()
## performs exactly ONE save_to_history + ONE board_revision bump for the whole
## batch — so a single undo reverts the entire batch as one step.
var _batch_active: bool = false
var _batch_touched: bool = false

## Change journal — append-only log of forward actions (not undo/redo)
var change_journal: Array[Dictionary] = []
const MAX_JOURNAL_SIZE := 200
signal journal_entry_added(entry: Dictionary)

## ── ID COUNTER INVARIANT (stated ONCE, here — every site below CITES this,
## none re-derives it) ──────────────────────────────────────────────────────
## Every path that admits a trace or via id — whether minted fresh by add_trace/
## add_via or supplied from outside (import, board load, undo/redo restore) —
## MUST leave the corresponding counter (_next_trace_id / _next_via_id) at or
## above the highest id it admitted. NO PATH MAY EVER LOWER A COUNTER: not
## clear_traces(), not clear(), not undo/redo's _restore_state. An id is never
## reused within a session, so a stale-HIGH counter is always benign (it only
## skips numbers) while a stale-LOW one is a collision waiting to happen —
## `traces` is an id-keyed Dictionary, so a colliding mint OVERWRITES rather
## than duplicates. ACCEPTED COST: an exported-then-reimported board renumbers
## upward forever — safety over tidy numbering (owner ruling, docket
## 019fa172dd21 comment 868). Sites this governs: reserve_trace_id/
## reserve_via_id (the reservation half — a supplied id must push the counter
## up), and clear_traces/clear/_restore_state (the "never lower it" half).

## Next trace ID counter. Governed by the ID COUNTER INVARIANT above.
var _next_trace_id: int = 1

## Next via ID counter (T2.3). Vias are plain dicts (no wrapper class); a via
## minted here carries a stable "id" ("via_N") so a committed route's copper can
## be referenced by a durable identity that survives to_board_dict()/reload. The
## id rides in the via dict's extra-key passthrough (_via_to_board_dict /
## _vias_from_board_list already copy unknown keys), so no serialisation change
## is needed. Restored to a HIGH-WATER MARK on load so post-load mints never
## collide with loaded ids (mirrors RoutingWorkspace's counter policy). Governed
## by the ID COUNTER INVARIANT above.
var _next_via_id: int = 1


func _init(width: float = 100.0, height: float = 100.0) -> void:
	board_width = width
	board_height = height


#region Component Management

## Factory: a blank component instance. Off-tree bridge helper — the Minerva-core
## panel-local MCP tools (MCPPcbPanelTools) cannot preload the plugin component
## script, so they mint one here and configure it via duck-typed calls before
## add_component(). Keeps construction on the plugin side, orchestration in core.
func new_component():
	return PCBComponentScript.new()


## Factory: a blank trace instance. Same off-tree rationale as new_component —
## used by the import_trace_geometry bridge tool.
func new_trace():
	return PCBTraceScript.new()


## Add a component to the board
func add_component(component) -> void:
	if component.id.is_empty():
		push_error("[PCBData] Component must have an ID")
		return

	components[component.id] = component
	record_change("add_component", {"component_id": component.id})
	component_added.emit(component.id)
	data_changed.emit()


## Get a component by ID
func get_component(component_id: String):
	return components.get(component_id, null)


## Check if a component exists
func has_component(component_id: String) -> bool:
	return components.has(component_id)


## Remove a component from the board
func remove_component(component_id: String) -> void:
	if not components.has(component_id):
		return

	record_change("remove_component", {"component_id": component_id})

	# Remove from all nets
	for net_name in nets:
		nets[net_name].remove_component_pins(component_id)

	components.erase(component_id)
	component_removed.emit(component_id)
	data_changed.emit()


## Update component position
func move_component(component_id: String, new_position: Vector2) -> void:
	var component = get_component(component_id)
	if component:
		var old_position: Vector2 = component.position
		component.position = new_position
		record_change("move_component", {
			"component_id": component_id,
			"old_position": {"x": old_position.x, "y": old_position.y},
			"new_position": {"x": new_position.x, "y": new_position.y}
		})
		component_changed.emit(component_id)
		data_changed.emit()


## Update component rotation
func rotate_component(component_id: String, degrees: float) -> void:
	var component = get_component(component_id)
	if component:
		var old_rotation: float = component.rotation
		component.set_rotation(degrees)
		record_change("rotate_component", {
			"component_id": component_id,
			"old_rotation": old_rotation,
			"new_rotation": degrees
		})
		component_changed.emit(component_id)
		data_changed.emit()


## Get all component IDs
func get_component_ids() -> Array[String]:
	var result: Array[String] = []
	for id in components:
		result.append(id)
	return result


## Get all components as an array
func get_all_components() -> Array:
	var result: Array = []
	for comp in components.values():
		result.append(comp)
	return result


## Get component at a position (for hit testing)
## Skips locked components so clicks pass through to items underneath.
func get_component_at(position: Vector2) -> String:
	for component_id in components:
		var component = components[component_id]
		if component.locked:
			continue
		if component.contains_point(position):
			return component_id
	return ""


## Get all components in a region
func get_components_in_region(region: Rect2) -> Array[String]:
	var result: Array[String] = []
	for component_id in components:
		var component = components[component_id]
		if region.intersects(component.get_bounding_rect()):
			result.append(component_id)
	return result

#endregion


#region Component Groups
## Persistent component groups (campaign-2 A4). Two board components that are
## really ONE physical part (the owner's AMP1 + OUT) are stamped with a shared
## group id and thereafter move, rotate and delete as a rigid unit.
##
## THE MODEL OWNS GROUP SEMANTICS, not the canvas. Membership queries, the
## group-expand of a member set, and the group mutations all live here; the canvas
## and the MCP tools are both consumers, which is what keeps a drag and a
## minerva_pcb_move_component call meaning the same thing.
##
## STORAGE is the member's own `properties[group_id]` (see pcb_component.gd's
## GROUP_PROPERTY_KEY for the measured reason it is not a top-level field). There
## is no group registry object: a group IS the set of components sharing an id,
## so a group cannot go stale, cannot outlive its members, and needs no separate
## serialization path — deleting the last member deletes the group.
##
## HISTORY follows this file's standing rule: NO mutator here snapshots itself
## (the caller decides where an undo step begins and ends). Every group mutation
## below journals through record_change and emits, exactly like its single-
## component sibling; the caller wraps a multi-component one in
## begin_batch/end_batch so it lands as ONE undo step.
##
## NESTED GROUPS ARE OUT OF SCOPE: a component carries at most one group id, and
## grouping a selection that already contains grouped members MERGES them into a
## single flat group (Illustrator grammar) rather than nesting.


## The group id of one component, or "" (unknown component included).
func component_group_id(component_id: String) -> String:
	var comp = get_component(component_id)
	return comp.group_id() if comp != null else ""


## Every member of `group_id`, SORTED by component id.
##
## Sorted, not insertion-ordered, because `components` is a Dictionary whose key
## order is not a contract, and group_anchor_id() is defined off the first entry
## here — an anchor that changed between a save and a reload would silently
## redefine every member offset.
func group_member_ids(group_id: String) -> Array[String]:
	var result: Array[String] = []
	if group_id.is_empty():
		return result
	for comp_id in components:
		if components[comp_id].group_id() == group_id:
			result.append(comp_id)
	result.sort()
	return result


## The group's ANCHOR: the lowest member id in sorted order.
##
## Deterministic across save/reload by construction — it is derived from the ids
## themselves, and to_board_dict() emits components sorted by the same key — so
## the offsets computed against it are stable. Returns "" for an empty/unknown
## group.
func group_anchor_id(group_id: String) -> String:
	var members := group_member_ids(group_id)
	return members[0] if not members.is_empty() else ""


## Is this component its group's anchor? (False for an ungrouped component: it is
## not an anchor, it is simply not in a group.)
func is_group_anchor(component_id: String) -> bool:
	var gid := component_group_id(component_id)
	return not gid.is_empty() and group_anchor_id(gid) == component_id


## A member's offset from its group's anchor, in board mm. Vector2.ZERO for the
## anchor itself and for any ungrouped component.
func member_offset(component_id: String) -> Vector2:
	var gid := component_group_id(component_id)
	if gid.is_empty():
		return Vector2.ZERO
	var anchor = get_component(group_anchor_id(gid))
	var comp = get_component(component_id)
	if anchor == null or comp == null:
		return Vector2.ZERO
	return comp.position - anchor.position


## Grow a set of component ids to include every group-mate of every member.
##
## The ONE expand rule, shared by the canvas selection and the MCP tools. Order
## is preserved for the ids that were passed in, with each group's extra members
## appended right after the member that pulled them in — so a caller that cared
## about "the one I clicked" still finds it where it put it. Ungrouped ids pass
## through untouched, which is what makes a group-free board behave identically.
func expand_to_groups(component_ids) -> Array[String]:
	var result: Array[String] = []
	for component_id in component_ids:
		var cid := str(component_id)
		if not result.has(cid):
			result.append(cid)
		var gid := component_group_id(cid)
		if gid.is_empty():
			continue
		for member_id in group_member_ids(gid):
			if not result.has(member_id):
				result.append(member_id)
	return result


## WHOLE-UNIT LOCK RULE — deliberately NOT the per-entity rule.
##
## Everywhere else on this board a lock is PER ENTITY: the drag path skips the
## locked members of a mixed selection and moves the rest (pcb_canvas
## _capture_drag_origins), and the delete path does the same. A GROUP cannot work
## that way: it is one physical part, and moving three of its four members while
## the locked one stays put would tear the part apart. So one locked member locks
## the WHOLE group, for drag, delete, rotate and offset-edit alike.
##
## Stated as its own named helper precisely so a reviewer can see the two rules
## are different and which sites use which.
func is_group_locked(group_id: String) -> bool:
	if group_id.is_empty():
		return false
	for member_id in group_member_ids(group_id):
		if components[member_id].locked:
			return true
	return false


## The whole-unit rule addressed by COMPONENT: true when this component belongs to
## a group and any member of that group is locked. False for every ungrouped
## component — an ungrouped part is governed by the per-entity rule alone, so no
## existing behaviour moves.
func group_lock_blocks(component_id: String) -> bool:
	return is_group_locked(component_group_id(component_id))


## Stamp `component_ids` (and every existing group-mate of any of them) into ONE
## group and return its id.
##
## RETURNS "" WHEN NOTHING CHANGED — fewer than two real components, or a set that
## is already exactly one group. That is what lets every caller close with an
## unconditional save_to_history() on a non-empty return and never leave an empty
## undo step behind for a gesture that did nothing.
##
## MERGE, not nest (Illustrator grammar): if the selection contains members of two
## existing groups, all of both groups end up in a single flat group. Fewer than
## two components after expansion is refused — a group of one is not a group.
##
## REUSES an incoming group id rather than always minting: grouping a selection
## that is already exactly one group is then a no-op instead of a churn of the id
## (and of every member's serialized properties). When two or more groups merge, a
## fresh id is minted so neither side's identity silently wins.
func group_components(component_ids) -> String:
	var members := expand_to_groups(component_ids)
	var present: Array[String] = []
	for component_id in members:
		if has_component(component_id):
			present.append(component_id)
	if present.size() < 2:
		return ""

	var existing: Array[String] = []
	for component_id in present:
		var gid := component_group_id(component_id)
		if not gid.is_empty() and not existing.has(gid):
			existing.append(gid)

	var group_id := existing[0] if existing.size() == 1 else mint_entity_id("group")
	var stamped: Array[String] = []
	for component_id in present:
		var comp = components[component_id]
		if comp.group_id() == group_id:
			continue
		comp.set_group_id(group_id)
		stamped.append(component_id)
		component_changed.emit(component_id)
	if stamped.is_empty():
		return ""

	record_change("group_components", {
		"group_id": group_id,
		"component_ids": present.duplicate(),
		"stamped_ids": stamped,
		"merged_group_ids": existing,
	})
	data_changed.emit()
	return group_id


## Clear group membership from every group touched by `component_ids` and return
## the ids that were actually released.
##
## WHOLE GROUPS, not the named members only: ungrouping one member of a pair would
## leave a one-member group, which group_components refuses to create in the first
## place. Positions are UNTOUCHED — the parts stay exactly where they are and
## simply become independently selectable again.
func ungroup_components(component_ids) -> Array[String]:
	var released: Array[String] = []
	var group_ids: Array[String] = []
	for component_id in component_ids:
		var gid := component_group_id(str(component_id))
		if not gid.is_empty() and not group_ids.has(gid):
			group_ids.append(gid)
	for gid in group_ids:
		for member_id in group_member_ids(gid):
			components[member_id].set_group_id("")
			released.append(member_id)
			component_changed.emit(member_id)
	if released.is_empty():
		return released

	record_change("ungroup_components", {
		"group_ids": group_ids,
		"component_ids": released.duplicate(),
	})
	data_changed.emit()
	return released


## Translate every member of `component_id`'s group by `delta`, preserving the
## members' relative offsets exactly. Returns the ids that moved ([] when the
## component is ungrouped or the group is locked).
##
## Each member moves through move_component(), so the journal reads exactly like
## N single-component moves — the shape every existing journal reader already
## parses, and the same shape the canvas drag emits. The caller owes the history
## step (begin_batch/end_batch for one undo).
func translate_group(component_id: String, delta: Vector2) -> Array[String]:
	var moved: Array[String] = []
	var gid := component_group_id(component_id)
	if gid.is_empty() or is_group_locked(gid):
		return moved
	for member_id in group_member_ids(gid):
		move_component(member_id, components[member_id].position + delta)
		moved.append(member_id)
	return moved


## Rigid-body rotate a group by `degrees_delta` about its ANCHOR: every member's
## position orbits the anchor AND every member's own rotation turns by the same
## amount, so the unit behaves like the single footprint it physically is.
## Returns the ids that turned ([] when ungrouped or locked).
##
## THE SIGN IS THE KICAD CONVENTION, not a free choice. pcb_component.get_transform
## maps a component's own rotation through `Transform2D(deg_to_rad(-rotation))`
## (its docstring explains why: the worker, gerber export and kicad_io all use
## radians(-rotation_deg)). A member's position is geometry belonging to the same
## rigid body, so it must be carried by the SAME transform — hence
## `.rotated(deg_to_rad(-applied_delta))`. Rotating positions the other way would
## make a 90°-turned group's parts land mirrored across the anchor relative to
## their own turned bodies.
##
## THE DELTA IS SNAPPED BEFORE ANYTHING MOVES. Component bodies quantize to 90°
## multiples (pcb_component.set_rotation), so orbiting positions by the RAW delta
## would let the two halves of the same rigid body disagree — a 45° request
## turned every body 90° while positions orbited 45°, silently deforming the
## part (cold-review A4 finding 1). Snapping once through the model's single
## quantization authority (pcb_component.snap_rotation) and using that value for
## BOTH halves makes disagreement impossible; a delta that snaps to a full turn
## is a no-op and journals nothing.
func rotate_group(component_id: String, degrees_delta: float) -> Array[String]:
	var turned: Array[String] = []
	var gid := component_group_id(component_id)
	if gid.is_empty() or is_group_locked(gid):
		return turned
	var applied_delta: float = PCBComponentScript.snap_rotation(degrees_delta)
	if fposmod(applied_delta, 360.0) == 0.0:
		return turned
	var anchor_id := group_anchor_id(gid)
	var anchor_pos: Vector2 = components[anchor_id].position
	var radians := deg_to_rad(-applied_delta)
	for member_id in group_member_ids(gid):
		var comp = components[member_id]
		rotate_component(member_id, comp.rotation + applied_delta)
		var orbited: Vector2 = anchor_pos + (comp.position - anchor_pos).rotated(radians)
		if orbited != comp.position:
			move_component(member_id, orbited)
		turned.append(member_id)
	return turned


## Remove every member of `component_id`'s group through the journalled
## remove_component(). Returns the removed ids ([] when ungrouped or locked).
## The caller owes the history step.
func remove_group(component_id: String) -> Array[String]:
	var removed: Array[String] = []
	var gid := component_group_id(component_id)
	if gid.is_empty() or is_group_locked(gid):
		return removed
	for member_id in group_member_ids(gid):
		remove_component(member_id)
		removed.append(member_id)
	return removed


## STAGE 2 — numeric offset editing. Reposition ONE member to
## `anchor.position + offset`, leaving every other member of the group where it
## is. Returns true when the member moved.
##
## This is the deliberate exception to "a group moves as a unit": it is how the
## unit's INTERNAL geometry gets corrected once the real part is measured. The
## anchor itself has no editable offset (it IS the origin — moving it would move
## the whole group, which is what a drag is for), so anchor edits are refused.
## Lock-gated by the same whole-unit rule as every other group mutation.
func set_member_offset(component_id: String, offset: Vector2) -> bool:
	var gid := component_group_id(component_id)
	if gid.is_empty() or is_group_locked(gid):
		return false
	var anchor_id := group_anchor_id(gid)
	if anchor_id == component_id:
		return false
	var target: Vector2 = components[anchor_id].position + offset
	if components[component_id].position == target:
		return false
	move_component(component_id, target)
	return true

#endregion


#region Net Management

## Add a net
func add_net(net) -> void:
	if net.name.is_empty():
		push_error("[PCBData] Net must have a name")
		return

	nets[net.name] = net
	record_change("add_net", {"net_name": net.name})
	net_changed.emit(net.name)
	data_changed.emit()


## Get a net by name
func get_net(net_name: String):
	return nets.get(net_name, null)


## Check if a net exists
func has_net(net_name: String) -> bool:
	return nets.has(net_name)


## Remove a net (and every trace on it).
##
## No mutator may erase a collection member directly when a journalled remover
## exists for that member (owner ruling, docket 019fa17326b5 comment 867) — so
## each trace is removed through remove_trace() rather than a bare
## `traces.erase()`. That is what makes journalling/signalling for a net-wide
## delete identical, trace-for-trace, to a single-trace remove_trace() call
## instead of a second copy of that logic that can drift out of sync.
func remove_net(net_name: String) -> void:
	if nets.has(net_name):
		var traces_to_remove: Array[String] = []
		for trace_id in traces:
			if traces[trace_id].net_name == net_name:
				traces_to_remove.append(trace_id)

		for trace_id in traces_to_remove:
			remove_trace(trace_id)

		nets.erase(net_name)
		record_change("remove_net", {"net_name": net_name})
		net_changed.emit(net_name)
		data_changed.emit()


## Connect a pin to a net
func connect_pin_to_net(net_name: String, component_id: String, pin_name: String) -> void:
	if not nets.has(net_name):
		# Create the net if it doesn't exist
		var net = PCBNetScript.new()
		net.name = net_name
		net.color = PCBNetScript.generate_color_for_name(net_name)
		nets[net_name] = net

	nets[net_name].add_pin(component_id, pin_name)
	record_change("connect_net", {
		"net_name": net_name,
		"component_id": component_id,
		"pin_name": pin_name
	})
	net_changed.emit(net_name)
	data_changed.emit()


## Disconnect a pin from a net
func disconnect_pin_from_net(net_name: String, component_id: String, pin_name: String) -> void:
	if nets.has(net_name):
		nets[net_name].remove_pin(component_id, pin_name)
		record_change("disconnect_net", {
			"net_name": net_name,
			"component_id": component_id,
			"pin_name": pin_name
		})
		net_changed.emit(net_name)
		data_changed.emit()


## Get all net names
func get_net_names() -> Array[String]:
	var result: Array[String] = []
	for name in nets:
		result.append(name)
	return result


## Find which net a pin belongs to
func find_net_for_pin(component_id: String, pin_name: String) -> String:
	for net_name in nets:
		if nets[net_name].has_pin(component_id, pin_name):
			return net_name
	return ""

#endregion


#region Trace Management

## Add a trace
func add_trace(trace) -> void:
	if trace.id.is_empty():
		trace.id = "trace_%d" % _next_trace_id
		_next_trace_id += 1
	else:
		# A caller-supplied id must not let a LATER auto-mint collide with it —
		# the same high-water contract add_via already applies to via ids, via
		# the shared _stable_id_suffix helper. This is what lets the import tool
		# honour ids carried back from an export instead of renumbering.
		_next_trace_id = maxi(_next_trace_id, _stable_id_suffix(trace.id) + 1)

	traces[trace.id] = trace
	record_change("add_trace", {
		"trace_id": trace.id,
		"net_name": trace.net_name,
		"layer": trace.layer,
		"segment_count": maxi(0, trace.waypoints.size() - 1)
	})
	trace_changed.emit(trace.id)
	data_changed.emit()


## Reserve a caller-supplied trace id so a LATER auto-mint can never collide
## with it (the reservation half of the ID COUNTER INVARIANT above). add_trace
## already high-waters for each id it accepts, but a BULK importer must reserve
## every supplied id UP FRONT: `traces` is keyed by id, so if an unnamed trace
## is processed before a supplied "trace_1" the auto-mint produces "trace_1"
## itself and the supplied trace then silently overwrites it. Reserving first
## makes the outcome independent of the caller's ordering.
func reserve_trace_id(trace_id: String) -> void:
	if trace_id.is_empty():
		return
	_next_trace_id = maxi(_next_trace_id, _stable_id_suffix(trace_id) + 1)


## Via twin of reserve_trace_id (the reservation half of the ID COUNTER
## INVARIANT above). Vias are a list rather than an id-keyed map, so nothing is
## overwritten — but a duplicate id would leave both vias sharing one handle,
## and remove_via_by_id resolves only the first match, so the second would be
## undeletable by id.
func reserve_via_id(via_id: String) -> void:
	if via_id.is_empty():
		return
	_next_via_id = maxi(_next_via_id, _stable_id_suffix(via_id) + 1)


## Get a trace by ID
func get_trace(trace_id: String):
	return traces.get(trace_id, null)


## Remove a trace
func remove_trace(trace_id: String) -> void:
	if traces.has(trace_id):
		var trace = traces[trace_id]
		record_change("remove_trace", {
			"trace_id": trace_id,
			"net_name": trace.net_name,
			"layer": trace.layer,
			"segment_count": maxi(0, trace.waypoints.size() - 1)
		})
		traces.erase(trace_id)
		trace_changed.emit(trace_id)
		data_changed.emit()


## Get all traces for a net
func get_traces_for_net(net_name: String) -> Array:
	var result: Array = []
	for trace_id in traces:
		if traces[trace_id].net_name == net_name:
			result.append(traces[trace_id])
	return result


## Get all trace IDs
func get_trace_ids() -> Array[String]:
	var result: Array[String] = []
	for id in traces:
		result.append(id)
	return result


## Get trace at a position (for hit testing)
## Returns the closest trace ID, preferring shorter traces when multiple match
##
## `visible_filter`, when supplied, is a Callable(trace) -> bool the VIEW owns:
## the model knows nothing about layer filters or the show_traces toggle, so the
## canvas passes its own predicate rather than this file growing a second copy of
## the view's rules. Applied INSIDE the walk, not to the winner afterwards — a
## hidden trace crossing a visible one must not shadow it out of the pick.
## Omitted (the default) means "every trace is pickable", which is exactly what
## every pre-existing caller got.
func get_trace_at(position: Vector2, threshold: float = 1.0, visible_filter := Callable()) -> String:
	var best_id: String = ""
	var best_length: float = INF

	for trace_id in traces:
		var trace = traces[trace_id]
		if visible_filter.is_valid() and not visible_filter.call(trace):
			continue
		if trace.is_point_near(position, threshold):
			var trace_length: float = trace.get_length()
			if trace_length < best_length:
				best_length = trace_length
				best_id = trace_id

	return best_id


## Every trace the marquee `region` touches — the trace twin of
## get_components_in_region, sharing its `visible_filter` contract with
## get_trace_at above (the view owns visibility, the model owns geometry).
##
## GEOMETRY RULE, and why it is not the component one: a component sweeps by
## BOUNDING RECT because a footprint IS its rectangle. A trace is a path, and its
## bounding rect is mostly empty space — a long diagonal would be swept up by a
## marquee that never came near the copper. So a trace is hit when the marquee
## actually touches the polyline (see region_touches_polyline), which is the same
## "hits like a path" language get_trace_at's proximity test already speaks.
func get_traces_in_region(region: Rect2, visible_filter := Callable()) -> Array[String]:
	var result: Array[String] = []
	for trace_id in traces:
		var trace = traces[trace_id]
		if visible_filter.is_valid() and not visible_filter.call(trace):
			continue
		if region_touches_polyline(trace.waypoints, region):
			result.append(trace_id)
	return result


## Replace a trace's waypoints wholesale.
##
## LIVE-DRAG WRITER: deliberately silent — no record_change, no signals. Mirrors
## what a component drag has always done (the canvas writes comp.position
## directly every motion frame and journals ONCE at release), because a per-frame
## journal entry would bury the log and a per-frame history snapshot would make
## undo replay the drag pixel by pixel. The CALLER owes the journal entry and the
## single save_to_history at the end of the gesture. Use move_component's
## journalling sibling semantics for one-shot programmatic moves instead.
## Re-width an existing trace. "" on success, the user-facing refusal otherwise.
##
## JOURNALLED SETTER — deliberately the set_zone_net/set_zone_layer shape, NOT
## set_trace_waypoints' (the live-drag writer directly above, which journals
## nothing on purpose because a per-motion-frame entry would bury the log). A
## width change is a discrete authoring decision with a beginning and an end, so
## it records a change and emits, exactly as re-propertying a zone does.
##
## HISTORY IS THE CALLER'S, taken AFTER this returns (mutate-then-snapshot, bug
## 019fb5ad791c) — no mutator in this file snapshots itself.
##
## "" MEANS "NOTHING TO REPORT", NOT "SOMETHING CHANGED" — same caveat
## set_zone_net carries: re-setting the width a trace already has journals
## nothing and still returns "". A caller that snapshots MUST compare first or it
## pushes an empty undo step and the user's next Ctrl+Z appears to do nothing
## (cold-review F3). See PCBPanel._on_trace_prop_width_changed for the guard.
##
## Every rule lives on pcb_trace.width_error — ONE contract, shared with the
## width spin box's bounds and the preference registry. Out of range is REFUSED,
## not clamped: this writes copper (see that function's note).
##
## SELECTION GEOMETRY MOVES WITH THE WIDTH, by design: pcb_trace.get_bounding_rect
## pads by half the width and is_point_near widens its hit radius by the same
## half, and both read `width` live off the trace — nothing anywhere caches a
## trace's bounds (the spatial index indexes components only, measured). So a
## re-widened trace is immediately easier to click, which is the honest behaviour:
## the clickable copper IS the copper.
func set_trace_width(trace_id: String, width_mm: float) -> String:
	var trace = get_trace(trace_id)
	if trace == null:
		return "No such trace."
	var refusal: String = PCBTraceScript.width_error(width_mm)
	if not refusal.is_empty():
		return refusal
	var old_width := float(trace.width)
	if is_equal_approx(old_width, width_mm):
		return ""
	trace.width = width_mm
	record_change("set_trace_width", {
		"trace_id": trace_id,
		"old_width_mm": old_width,
		"width_mm": width_mm,
		"net_name": trace.net_name,
		"layer": trace.layer,
	})
	trace_changed.emit(trace_id)
	data_changed.emit()
	return ""


func set_trace_waypoints(trace_id: String, points) -> void:
	var trace = get_trace(trace_id)
	if trace == null:
		return
	var wp: Array[Vector2] = []
	for p in points:
		wp.append(p)
	trace.waypoints = wp


## How far (mm) a click reaches for a pad, a free trace end or a trace vertex
## — half a 0.1" pitch, so a click between two DIP pads is a miss rather than a
## coin toss. The canvas's TRACE_PAD_SNAP_MM and the verbs' coordinate forms
## read this ONE number so an agent's point reaches exactly as far as a click.
const TRACE_SNAP_MM := 1.27

## The two names a trace END goes by, in extend_trace and free_trace_end_at.
const TRACE_END_START := "start"
const TRACE_END_END := "end"

## Coincidence epsilon (mm) for "this trace end touches that copper" — the same
## pad-centre slack the dangling-copper sweep grants, applied to copper distance.
const TRACE_END_JOIN_EPS_MM := 0.05


## Is the given end of a trace already JOINED to other copper: on a pad's land,
## inside a via's disc, or on a same-net trace? An end that is joined is not a
## loose end, so it is not something to continue drawing from.
##
## The credit is the copper's own geometry: pin_copper_distance for pads (0 on
## the land), the via's radius for vias, and is_point_near (width/2 + eps) for
## a trace. NET-BLIND for pads and vias, NET-AWARE for traces, deliberately: a
## pad or via of ANY net under the end makes it "not free" (continuing from
## there would draw through copper that is not yours), while only a SAME-NET
## trace joins — a different-net trace under the end is a short for DRC to
## name, not a join. Zones are not consulted at all, so an end lying in a
## same-net pour still reads as free.
func trace_end_is_joined(trace_id: String, end: String) -> bool:
	var trace = get_trace(trace_id)
	if trace == null or trace.waypoints.size() < 2:
		return false
	var pt: Vector2 = trace.waypoints[0] if end == TRACE_END_START \
		else trace.waypoints[trace.waypoints.size() - 1]
	for comp_id in components:
		var comp = components[comp_id]
		for pin_name in comp.get_all_pin_positions():
			if comp.pin_copper_distance(str(pin_name), pt) <= TRACE_END_JOIN_EPS_MM:
				return true
	if not get_via_at(pt, TRACE_END_JOIN_EPS_MM).is_empty():
		return true
	for other_id in traces:
		if other_id == trace_id:
			continue
		var other = traces[other_id]
		if other.net_name == trace.net_name and other.is_point_near(pt, TRACE_END_JOIN_EPS_MM):
			return true
	return false


## The FREE trace end nearest `position` within `tol` (inclusive), or {}:
## {trace_id, end, position, net}. BOTH ends of every trace are measured and
## the nearest free one overall wins — a short stub whose two ends are both
## within `tol` answers with the nearer end, not the first one tested. On an
## exact tie the earlier trace keeps it, then its start. A joined end
## (trace_end_is_joined) and a LOCKED trace offer nothing.
##
## `visible_filter` is the view's predicate, applied inside the walk exactly as
## get_trace_at applies it.
func free_trace_end_at(position: Vector2, tol: float, visible_filter := Callable()) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for trace_id in traces:
		var trace = traces[trace_id]
		if visible_filter.is_valid() and not visible_filter.call(trace):
			continue
		if bool(trace.locked):
			continue
		var pts := PackedVector2Array(trace.waypoints)
		if pts.size() < 2:
			continue
		for end in [TRACE_END_START, TRACE_END_END]:
			var pt: Vector2 = pts[0] if end == TRACE_END_START else pts[pts.size() - 1]
			var d := pt.distance_to(position)
			if d > tol or d >= best_d:
				continue
			if trace_end_is_joined(trace_id, end):
				continue
			best_d = d
			best = {"trace_id": trace_id, "end": end, "position": pt,
				"net": str(trace.net_name)}
	return best


## Nearest INTERIOR vertex of a trace to `position` within `tol` (inclusive),
## or -1: interior means neither the first nor the last waypoint. Strict walk,
## the earlier vertex wins a tie. The end vertices are not offered here at all,
## because cutting at an end is a delete or a no-op — see cut_trace.
func nearest_interior_vertex(trace_id: String, position: Vector2, tol: float) -> int:
	var trace = get_trace(trace_id)
	if trace == null:
		return -1
	var best := -1
	var best_d := INF
	for i in range(1, trace.waypoints.size() - 1):
		var d: float = (trace.waypoints[i] as Vector2).distance_to(position)
		if d <= tol and d < best_d:
			best_d = d
			best = i
	return best


## Cut a trace at one of its INTERIOR vertices: the trace keeps its id and the
## waypoints up to and including `at_index`; everything after is dropped. The
## cut vertex becomes the trace's end — a free end unless something already
## joins it (trace_end_is_joined). Returns "" on success or the refusal in the
## model's words; a refusal changes nothing.
##
## Refused BY NAME rather than reinterpreted: an index at either end would be a
## whole-trace delete (index 0) or a no-op (the last), and both are answers the
## caller has to choose deliberately, not fall into; a 2-point trace has no
## interior to cut at.
##
## Journalled as ONE cut_trace row; history is NOT snapshotted here (the house
## rule: the caller owns the undo step).
func cut_trace(trace_id: String, at_index: int) -> String:
	var trace = get_trace(trace_id)
	if trace == null:
		return "No such trace \"%s\"." % trace_id
	var count: int = trace.waypoints.size()
	if count < 3:
		return "Trace \"%s\" has %d points — nothing between its ends to cut at." % [trace_id, count]
	if at_index <= 0 or at_index >= count - 1:
		return "Index %d is an end of trace \"%s\" (interior is 1..%d) — cutting there would delete it or change nothing; delete it or pick an interior vertex." \
			% [at_index, trace_id, count - 2]
	var kept: Array[Vector2] = []
	for i in range(at_index + 1):
		kept.append(trace.waypoints[i])
	trace.waypoints = kept
	record_change("cut_trace", {
		"trace_id": trace_id,
		"at_index": at_index,
		"dropped_count": count - (at_index + 1),
		"net_name": trace.net_name,
		"layer": trace.layer,
	})
	trace_changed.emit(trace_id)
	data_changed.emit()
	return ""


## Grow a trace's polyline from one of its ends so it stays ONE piece: `points`
## are ordered AWAY from that end (the end itself may lead them and is dropped,
## as is any point repeating its predecessor). Appended after the last point
## for TRACE_END_END, prepended in reverse before the first for TRACE_END_START.
## Returns "" on success or the refusal in the model's words; a refusal changes
## nothing. The trace keeps its id, net, layer and width — a polyline has one
## of each.
##
## Journalled as ONE extend_trace row; history is NOT snapshotted here (the house
## rule: the caller owns the undo step).
func extend_trace(trace_id: String, end: String, points: PackedVector2Array) -> String:
	var trace = get_trace(trace_id)
	if trace == null:
		return "No such trace \"%s\"." % trace_id
	if end != TRACE_END_START and end != TRACE_END_END:
		return "A trace end is \"%s\" or \"%s\", not \"%s\"." % [TRACE_END_START, TRACE_END_END, end]
	if trace.waypoints.size() < 2:
		return "Trace \"%s\" has no run to extend." % trace_id
	var anchor: Vector2 = trace.waypoints[0] if end == TRACE_END_START \
		else trace.waypoints[trace.waypoints.size() - 1]
	var added := PackedVector2Array()
	for p in points:
		var previous: Vector2 = anchor if added.is_empty() else added[added.size() - 1]
		if previous.is_equal_approx(p):
			continue
		added.append(p)
	if added.is_empty():
		return "Nothing to extend with — every point sits on the trace's %s." % end
	var old_count: int = trace.waypoints.size()
	if end == TRACE_END_END:
		for p in added:
			trace.waypoints.append(p)
	else:
		var grown: Array[Vector2] = []
		for i in range(added.size() - 1, -1, -1):
			grown.append(added[i])
		for p in trace.waypoints:
			grown.append(p)
		trace.waypoints = grown
	record_change("extend_trace", {
		"trace_id": trace_id,
		"end": end,
		"net_name": trace.net_name,
		"layer": trace.layer,
		"old_point_count": old_count,
		"point_count": trace.waypoints.size(),
		"added_count": added.size(),
	})
	trace_changed.emit(trace_id)
	data_changed.emit()
	return ""


## Clear all traces and vias.
##
## Per the ID COUNTER INVARIANT (see the statement near _next_trace_id), this
## does NOT reset _next_trace_id / _next_via_id — a stale-low counter after a
## clear is exactly the collision hazard the invariant exists to prevent (see
## docket 019fa172dd21 comment 868 for the concrete import->undo->mint sequence
## this avoids: resetting here would let a later mint reproduce an id an undo
## just restored, silently overwriting it in the id-keyed `traces` Dictionary).
##
## Journals WHAT was destroyed (every trace id and via id), not merely that a
## clear happened — an empty-details entry told an agent reading
## minerva_pcb_get_change_journal that copper vanished without saying which,
## and this is the one clear_traces() caller with a live production trigger
## (panel_tools.gd _import_trace_geometry / minerva_pcb_import_trace_geometry).
## Emits trace_changed for every removed trace, matching what removing them
## one at a time through remove_trace would have emitted; there is no
## per-via signal to mirror (add_via/remove_via emit none either).
func clear_traces() -> void:
	var removed_trace_ids: Array = get_trace_ids()
	var removed_via_ids: Array = []
	for v in vias:
		removed_via_ids.append(str((v as Dictionary).get("id", "")))

	traces.clear()
	vias.clear()
	record_change("clear_traces", {
		"trace_ids": removed_trace_ids,
		"via_ids": removed_via_ids,
		"trace_count": removed_trace_ids.size(),
		"via_count": removed_via_ids.size(),
	})
	for trace_id in removed_trace_ids:
		trace_changed.emit(trace_id)
	data_changed.emit()


## Add a via. Mints a stable "id" ("via_N") when the caller did not supply one
## (T2.3) so committed copper carries a durable identity across serialisation.
## Returns the via's id.
func add_via(via_data: Dictionary) -> String:
	if str(via_data.get("id", "")).is_empty():
		via_data["id"] = "via_%d" % _next_via_id
		_next_via_id += 1
	else:
		# A caller-supplied id must not let a later auto-mint collide with it.
		_next_via_id = maxi(_next_via_id, _stable_id_suffix(str(via_data["id"])) + 1)
	vias.append(via_data)
	record_change("add_via", {"index": vias.size() - 1, "via_id": str(via_data["id"])})
	data_changed.emit()
	return str(via_data["id"])


## Trailing integer of a stable id like "via_12"/"trace_7" -> 12/7; 0 if none.
## Feeds the high-water restoration so post-load mints never collide with ids
## that arrived from outside. Shared by BOTH id families (add_via/_load_vias for
## vias, add_trace for traces) — one parser, one contract.
static func _stable_id_suffix(id: String) -> int:
	var idx := id.rfind("_")
	if idx < 0 or idx + 1 >= id.length():
		return 0
	var tail := id.substr(idx + 1)
	return int(tail) if tail.is_valid_int() else 0


## Remove a via by index.
##
## POSITIONAL, and therefore NOT safe to drive from a caller-supplied selection:
## every removal shifts the index of every later via, so removing "vias 0 and 1"
## in a loop actually removes vias 0 and 2. Kept for the existing positional
## callers (canvas/undo paths and the model test suites, which pass an index they
## computed one line earlier). Anything selecting vias by IDENTITY must use
## remove_via_by_id instead.
func remove_via(index: int) -> void:
	if index >= 0 and index < vias.size():
		var details := _via_removal_details(index)
		vias.remove_at(index)
		record_change("remove_via", details)
		data_changed.emit()


## Journal details shared by remove_via/remove_via_by_id, so BOTH paths name
## the same identifying fields. An index alone cannot identify the destroyed
## via after the fact — indices shift on every removal — so via_id/net_name/
## position ride alongside it, matching the level of detail remove_trace
## already records for traces.
func _via_removal_details(index: int) -> Dictionary:
	var via: Dictionary = vias[index]
	var pos = via.get("position", Vector2.ZERO)
	var pos_dict: Dictionary = {"x": pos.x, "y": pos.y} if pos is Vector2 \
		else {"x": (pos as Dictionary).get("x", 0.0), "y": (pos as Dictionary).get("y", 0.0)}
	return {
		"index": index,
		"via_id": str(via.get("id", "")),
		"net_name": str(via.get("net_name", "")),
		"position": pos_dict,
	}


## Index of the via carrying `via_id`, or -1 when no via carries it.
##
## An EMPTY via_id never matches, and this guard is LOAD-BEARING, not defensive
## decoration: vias restored from a board file predating stable via ids carry no
## "id" key, so `str(via.get("id", ""))` is "" for them. A caller mapping
## `.get("id", "")` over an exported via list therefore really can send "", and
## the delete-traces selector passes it straight through to here. Without the
## guard, "" would match the first id-less via and delete copper the caller
## never named. Covered by the empty-id-selector test.
func find_via_index(via_id: String) -> int:
	if via_id.is_empty():
		return -1
	for i in range(vias.size()):
		if str((vias[i] as Dictionary).get("id", "")) == via_id:
			return i
	return -1


## Remove a via by its stable id (the "via_N" minted by add_via). Returns true
## if a via was removed, false if no via carries that id — the caller can then
## report the id as missing rather than guess. Index-shift-proof by construction:
## the index is resolved fresh from the id at the moment of removal, so a
## sequence of these calls never depends on positions captured earlier.
func remove_via_by_id(via_id: String) -> bool:
	var index := find_via_index(via_id)
	if index < 0:
		return false
	var details := _via_removal_details(index)
	vias.remove_at(index)
	record_change("remove_via", details)
	data_changed.emit()
	return true


## The via carrying `via_id`, or {} when none does. The identity-keyed read to
## put beside remove_via_by_id, so a caller that has an id never has to walk
## `vias` itself (and never has to reproduce find_via_index's load-bearing
## empty-id guard — "" resolves to {} here for exactly that reason).
func get_via(via_id: String) -> Dictionary:
	var index := find_via_index(via_id)
	return vias[index] if index >= 0 else {}


## A via's centre in board mm, whatever shape the stored "position" happens to
## be. ONE parser for the three shapes that reach this file: Vector2 (what
## _load_vias normalises to), {x,y} (what a caller-built dict or a JSON
## round-trip carries) and "(x, y)" (Vector2 stringified by a JSON round-trip).
##
## Written as a static helper rather than left inlined because via geometry now
## has FOUR readers — the canvas draw loop, the click pick, the marquee sweep and
## the MCP list tool — and four hand-rolled copies of a three-way shape check is
## exactly how one of them ends up silently returning ZERO for a legitimate via.
static func via_position(via: Dictionary) -> Vector2:
	var pos = via.get("position", Vector2.ZERO)
	if pos is Vector2:
		return pos
	if pos is Dictionary:
		return Vector2(pos.get("x", 0.0), pos.get("y", 0.0))
	if pos is String:
		var s: String = str(pos).replace("(", "").replace(")", "").strip_edges()
		var parts: PackedStringArray = s.split(",")
		if parts.size() >= 2:
			return Vector2(float(parts[0].strip_edges()), float(parts[1].strip_edges()))
	return Vector2.ZERO


## A via's outer radius in board mm (half its "size", the outer copper diameter).
## Defaults match add_via's own documented defaults, so a via dict that omits the
## key measures the same everywhere.
static func via_radius(via: Dictionary) -> float:
	return float(via.get("size", 0.8)) / 2.0


## Which via a click at `position` picks, or "".
##
## `min_radius` is the VIEW's minimum click target in board mm (the canvas passes
## a fixed screen-pixel radius divided by zoom): a 0.8mm via is a ~4px disc at a
## typical zoom, which is a target no hand can hit. The pick radius is therefore
## max(the via's own radius, min_radius) — the via's real copper when zoomed in,
## a comfortable target when zoomed out. Omitted (the default 0.0) means "pick by
## true geometry only", which is what the model's own tests want.
##
## TIES GO TO THE NEAREST CENTRE, not the smallest via: two vias overlapping at
## all is a board error, and "the one I clicked closest to" is the only answer a
## user can predict. (Contrast get_trace_at, which prefers the SHORTEST match —
## that rule exists because a long trace legitimately passes under a short one.)
##
## ID-LESS VIAS ARE SKIPPED, deliberately. Selection stores bare id strings, so a
## via restored from a board file predating stable via ids (no "id" key — see
## find_via_index) has nothing to store: picking it would put "" in the selection,
## which find_via_index then refuses to resolve, giving a via that highlights and
## cannot be deleted. Not pickable is the honest outcome; the via still draws, and
## export_trace_geometry still reports it as the id-less via it is.
func get_via_at(position: Vector2, min_radius: float = 0.0) -> String:
	var best_id: String = ""
	var best_distance: float = INF
	for via in vias:
		var via_id := str(via.get("id", ""))
		if via_id.is_empty():
			continue
		var centre := via_position(via)
		var reach := maxf(via_radius(via), min_radius)
		var distance := centre.distance_to(position)
		if distance <= reach and distance < best_distance:
			best_distance = distance
			best_id = via_id
	return best_id


## Every via the marquee `region` touches — the via twin of
## get_traces_in_region / get_zones_in_region.
##
## GEOMETRY RULE: a via IS its disc, so the sweep is an exact circle-vs-rect
## intersection (nearest point of the rect to the centre, within the radius).
## NO click-target slack is added here, and that asymmetry with get_via_at is the
## point: a marquee is drawn around what the user can see, so it should grab
## exactly the copper inside it, while a click is a single point that needs a
## target. Components and traces already sweep by true geometry the same way.
##
## Skips id-less vias for the same reason get_via_at does.
func get_vias_in_region(region: Rect2) -> Array[String]:
	var result: Array[String] = []
	for via in vias:
		var via_id := str(via.get("id", ""))
		if via_id.is_empty():
			continue
		var centre := via_position(via)
		var nearest := Vector2(
			clampf(centre.x, region.position.x, region.position.x + region.size.x),
			clampf(centre.y, region.position.y, region.position.y + region.size.y))
		if nearest.distance_to(centre) <= via_radius(via):
			result.append(via_id)
	return result

#endregion


#region Zone Management

## Entropy width of a minted persistent id — 16 bytes → 32 lowercase hex chars.
## MIRRORS internal/board/migrate.go's mintedIDBytes; internal/board/validate.go
## isMintedID() checks EXACTLY this width, so the two must not drift.
const MINTED_ID_BYTES := 16

## Fewest points that make a zone outline a polygon. MIRRORS internal/board's
## Validate (`invalid_zone_outline`) and is now the ONE place the UI states it:
## zone_author_error refuses a create below it, set_zone_outline refuses a write
## below it, and the canvas' vertex-delete gesture refuses to go under it.
const MIN_ZONE_OUTLINE_POINTS := 3


## Mint a fresh persistent entity id: "<entity_type>:<32 lowercase hex>".
##
## THE FORMAT IS THE CONTRACT, not a convention. internal/board/validate.go's
## isMintedID() accepts exactly "<type>:" + 32 chars from [0-9a-f]; anything else
## (empty, "zone_1", uppercase hex, a short tail) is UNMINTED and fails
## `unminted_persistent_id` on a v2 board. This is the FIRST UI-side minter: the
## trace/via counters above mint ORDINAL handles ("trace_7"/"via_12") which are
## deliberately NOT persistent ids — internal/board treats those legacy shapes as
## unminted and re-mints them at the v1→v2 migration boundary. Zones get the real
## thing because the contract names this exact gap: MigrateV1toV2 is the only
## other minter, so before this tool a zone hand-added to a v2 board had no way to
## acquire an id (docs/board-yaml.md, "Where a zone's id comes from").
##
## Entropy comes from Crypto (Godot's CSPRNG), not randi(), matching Go's
## crypto/rand for the same reason it does: a mint is a one-time write and these
## ids must stay globally unique across independently edited boards, which is what
## lets a persistent id SUBSUME the old board-namespacing rule. 128 bits makes
## that collision probability negligible.
static func mint_entity_id(entity_type: String) -> String:
	# hex_encode() emits LOWERCASE hex, which isMintedID requires.
	return "%s:%s" % [entity_type, Crypto.new().generate_random_bytes(MINTED_ID_BYTES).hex_encode()]


## Why the proposed zone cannot be authored, or "" when it can.
##
## ONE rule set, two consumers: create_zone() fail-closes on it, and the canvas
## drawing tool shows it to the user BEFORE committing. It mirrors Go's
## validateZones (internal/board/validate.go) field for field, because
## pcb.serialize is a fail-closed WRITE gate that runs Validate over the WHOLE
## board: one zone that violates these rules does not merely fail to save itself,
## it makes the entire board unserializable. Minting such a zone into the model
## would trade a refused gesture for a board the user cannot export at all.
##
## NOTE the kind-dependent one: `net` is required for a COPPER POUR and OPTIONAL
## for a KEEPOUT (owner boundary ruling 2026-07-30, docket 019fb5ad6d20:
## "Keepouts don't need net connections"). A pour is copper and copper belongs to
## a net; a keepout is a KiCad-style rule area — a prohibition on copper, not
## copper — and KiCad asks for no net either. Go's validateZones branches the same
## way on the now-modeled Zone.Kind. A keepout that DOES name a net is still
## checked against the declared nets, so a net-scoped keepout ("no GND copper
## here") stays expressible and a typo in its net name is still caught here.
func zone_author_error(net_name: String, layer: String, point_count: int, kind: String = "copper_pour") -> String:
	if point_count < MIN_ZONE_OUTLINE_POINTS:
		return "A zone outline needs at least %d points (%d placed)." % [MIN_ZONE_OUTLINE_POINTS, point_count]
	var net_refusal := zone_net_error(net_name, kind)
	if not net_refusal.is_empty():
		return net_refusal
	return zone_layer_error(layer)


## Why this NET cannot go on a zone of this KIND, or "" when it can.
##
## Split out of zone_author_error (cold-review F2) so a caller changing ONE field
## is judged on THAT field. The whole-zone check above still runs both halves in
## the same order, so create_zone and the drawing tool are unaffected — this is a
## decomposition, not a rule change.
##
## The split is not cosmetic: while both clauses ran on every setter, a zone that
## was bad in BOTH fields was permanently unrepairable. Setting its layer failed
## with a message about its stale NET, and setting its net failed with a message
## about its off-stack LAYER, so neither could ever be fixed and the board stayed
## unexportable — while the panel shipped explicit affordances for repairing both
## states. A refusal must name the control the user actually touched.
func zone_net_error(net_name: String, kind: String = "copper_pour") -> String:
	if net_name.is_empty():
		# A keepout with no net is the KiCad-parity case, not a refusal.
		if kind.strip_edges().to_lower() == "keepout":
			return ""
		return "Pick a net first — a copper pour must name a declared net."
	if not has_net(net_name):
		return "Net \"%s\" is not declared on this board." % net_name
	return ""


## Why this LAYER cannot carry a zone, or "" when it can. Net half's twin — see
## zone_net_error for why the two are separable.
##
## NOTE the permissive clause, unchanged and deliberate here: an EMPTY declared
## stack skips the membership test entirely. set_zone_layer refuses that case
## itself, ahead of this call, because a picker-supplied layer on a board with no
## stack has nothing to be valid against; create_zone's own path keeps the old
## permissive behaviour (filed separately).
func zone_layer_error(layer: String) -> String:
	if layer.is_empty():
		return "No copper layer to place the zone on."
	if not layers.is_empty() and layer not in layers:
		return "Layer \"%s\" is not in the board's declared layer stack." % layer
	return ""


## Replace the board's declared copper stack (epoch GA-1). Returns "" on
## success, else a human-readable refusal (the set_zone_layer convention).
##
## Two gates, both fail-closed:
##  * SHAPE — PcbLayerStack.stack_shape_error (the one GD home of the rule Go's
##    validateLayers / Python's _check_layers enforce): canonical names, no
##    dups, top first, bottom last, inners contiguous from in1.
##  * OCCUPANCY — shrinking the stack must not strand authored copper: a trace
##    or zone on a layer being removed refuses with a listing rather than
##    orphaning it (the canvas would still DRAW an undeclared-layer trace —
##    deliberately, so nothing vanishes — but serialize/compile would then
##    refuse the board; refusing HERE keeps the board always-consistent).
##    Vias never block: a through-via spans top<->bottom, which every legal
##    stack contains.
##
## Callers snapshot history themselves after a successful edit
## (data.save_to_history(...), the _set_zone_layer handler convention); the
## layers bucket makes the edit undoable.
func set_board_layers(new_layers: Array) -> String:
	var candidate: Array[String] = []
	for entry in new_layers:
		candidate.append(str(entry).strip_edges().to_lower())
	var shape_refusal := PcbLayerStack.stack_shape_error(candidate)
	if not shape_refusal.is_empty():
		return shape_refusal
	if candidate == layers:
		return ""
	var stranded: Array[String] = []
	for trace_id in traces:
		var trace = traces[trace_id]
		if trace.layer not in candidate:
			stranded.append("trace %s (layer %s)" % [str(trace_id), trace.layer])
	for zone in zones:
		var zone_layer := str(zone.get("layer", ""))
		if not zone_layer.is_empty() and zone_layer not in candidate:
			stranded.append("zone %s (layer %s)" % [str(zone.get("id", "?")), zone_layer])
	if not stranded.is_empty():
		var shown: Array[String] = stranded.slice(0, 5)
		var suffix := "" if stranded.size() <= 5 else " (and %d more)" % (stranded.size() - 5)
		return ("Cannot remove layers that still carry copper: %s%s. " +
			"Delete or re-layer that copper first.") % [", ".join(shown), suffix]
	var old_layers := layers.duplicate()
	layers = candidate
	record_change("set_board_layers", {
		"old_layers": old_layers,
		"layers": layers.duplicate(),
	})
	structure_changed.emit()
	return ""


## Create an authored zone and add it to the board. Returns the new zone dict
## (the model's own, not a copy) or {} when zone_author_error refused it.
##
## Mints a persistent "zone:<hex>" id when the caller supplies none — this is the
## whole point of the zone creation tool (docs/board-yaml.md: "a zone creation
## tool is the thing that would close it"). The dict is built in the CANONICAL
## shape the model stores zones in ({id, net, layer, kind, outline:[{x_mm,y_mm}]})
## rather than an internal one, because zones are held verbatim — see the `zones`
## declaration for why.
##
## `kind` is written explicitly even for a pour, though zone_kind() would default
## it: an authored entity should state what it is, and it is a modeled field on
## the Go Zone either way.
##
## `net` is written only when there IS one — a netless keepout (owner ruling
## 2026-07-30; see zone_author_error) gets NO `net` key rather than an empty one.
## That matches what Go emits (Zone.Net is omitempty), so a zone authored here and
## the same zone after a save/reload are the SAME dict shape; storing `net: ""`
## would make a fresh keepout differ from a reloaded one for no gain.
func create_zone(net_name: String, layer: String, outline_points, kind: String = "copper_pour") -> Dictionary:
	# Epoch UX4 (DCR 019fe07523ca S5): create = BUILD + ADD, split so the
	# staging path can build/validate a payload WITHOUT touching the board.
	# Byte-compatible with the pre-split verb: {} + push_warning on refusal,
	# the model's own dict on success.
	var built := build_zone_payload(net_name, layer, outline_points, kind)
	if not bool(built.get("ok", false)):
		push_warning("[PCBData] create_zone refused: %s" % str(built.get("error", "")))
		return {}
	return add_zone_payload(built.get("payload", {}))


## BUILD half (Epoch UX4, DCR 019fe07523ca S1/S5): validate + construct the
## CANONICAL zone payload, minting its persistent id — NO board write, NO
## journal, NO signal. The staging path stores this payload verbatim; the
## direct path hands it straight to add_zone_payload. Returns
## {ok:true, payload} or {ok:false, error:<the author refusal, verbatim>}.
func build_zone_payload(net_name: String, layer: String, outline_points, kind: String = "copper_pour") -> Dictionary:
	var pts := PackedVector2Array(outline_points)
	var refusal := zone_author_error(net_name, layer, pts.size(), kind)
	if not refusal.is_empty():
		return {"ok": false, "error": refusal}
	var zone := {
		"id": mint_entity_id("zone"),
		"layer": layer,
		"kind": kind,
		"outline": zone_outline_to_list(pts),
	}
	if not net_name.is_empty():
		zone["net"] = net_name
	return {"ok": true, "payload": zone}


## ADD half: write a BUILT payload onto the board (journal + signal). The id
## rides THROUGH — this is what lets a staged entity keep the identity its
## ghost/selection/findings referenced across accept (DCR F3). RE-VALIDATES
## against the CURRENT board (the load-bearing gate, DCR F11): a payload
## staged before a net/layer was deleted refuses HERE with the same author
## refusal a fresh attempt would get — plus the id checks a passthrough
## makes possible (minted format, unique). Returns the model's own dict, or
## {} with a push_warning naming the refusal.
func add_zone_payload(payload: Dictionary) -> Dictionary:
	if payload.is_empty():
		return {}
	var net_name := str(payload.get("net", ""))
	var layer := str(payload.get("layer", ""))
	var kind := str(payload.get("kind", "copper_pour"))
	var outline: Array = payload.get("outline", []) if payload.get("outline", []) is Array else []
	var refusal := zone_author_error(net_name, layer, outline.size(), kind)
	if not refusal.is_empty():
		push_warning("[PCBData] add_zone_payload refused: %s" % refusal)
		return {}
	var zid := str(payload.get("id", ""))
	if zid.is_empty() or not zid.begins_with("zone:"):
		push_warning("[PCBData] add_zone_payload refused: payload id '%s' is not a minted zone id" % zid)
		return {}
	if _zone_index(zid) >= 0:
		push_warning("[PCBData] add_zone_payload refused: zone id '%s' already on the board" % zid)
		return {}
	var zone: Dictionary = payload.duplicate(true)
	zones.append(zone)
	record_change("add_zone", {
		"zone_id": zid,
		"net_name": net_name,
		"layer": layer,
		"kind": kind,
		"point_count": outline.size(),
	})
	data_changed.emit()
	return zone


## Remove an authored zone by id. Returns true when a zone was removed, false
## for an unknown id. Mirrors remove_trace: record_change + data_changed here;
## the history snapshot is the CALLER's job, taken after the mutation
## (mutate-then-snapshot, bug 019fb5ad791c — snapshotting before the removal
## would make redo silently do nothing).
func remove_zone(zone_id: String) -> bool:
	var i := _zone_index(zone_id)
	if i < 0:
		return false
	var zone: Dictionary = zones[i]
	record_change("remove_zone", {
		"zone_id": zone_id,
		"net_name": str(zone.get("net", "")),
		"layer": str(zone.get("layer", "")),
		"kind": zone_kind(zone),
	})
	zones.remove_at(i)
	data_changed.emit()
	return true


## Index of a zone in `zones` by id, or -1. The ONE id->zone resolver: `zones` is
## a verbatim-dict list rather than an id-keyed map (see the `zones` declaration
## for why), so every by-id operation would otherwise re-write this walk.
func _zone_index(zone_id: String) -> int:
	for i in zones.size():
		if str(zones[i].get("id", "")) == zone_id:
			return i
	return -1


## A zone by id — the model's OWN dict (mutating it mutates the board), or {}.
func get_zone(zone_id: String) -> Dictionary:
	var i := _zone_index(zone_id)
	return zones[i] if i >= 0 else {}


## Encode board-mm points into the canonical outline list ({x_mm,y_mm} dicts).
## The write half of zone_outline_points, stated once so an authored zone and a
## moved zone cannot encode their geometry differently.
static func zone_outline_to_list(points) -> Array:
	var outline: Array = []
	for p in PackedVector2Array(points):
		outline.append({"x_mm": p.x, "y_mm": p.y})
	return outline


## Replace a zone's outline wholesale. LIVE-DRAG WRITER — silent about the WRITE
## ITSELF, for exactly the reasons set out on set_trace_waypoints (the caller owes
## journal + history at the end of the gesture: a per-frame record_change would
## push one journal entry per mouse-move frame).
##
## It is NOT silent about a REFUSAL, and that is the difference from before A5.
## Returns true when the outline was written, false when it was refused — the
## bool contract remove_zone already sets for "did the model actually change".
## The old signature returned void and wrote whatever it was handed, so ANY
## caller could put a 0/1/2-point outline into the board; internal/board's
## Validate rejects that as `invalid_zone_outline`, and pcb.serialize validates
## the WHOLE board, so one degenerate outline makes the entire board
## unexportable (the same fail-closed reasoning zone_author_error carries). A
## degenerate outline is also unrenderable and unpickable — _draw_zone and
## _zone_at both bail under 3 points — so it would be an invisible zone the user
## cannot select, delete or repair from the canvas. (zone_outline_points itself
## does NOT bail: it returns whatever it parses, however few points that is. Its
## own docstring has long claimed otherwise; the floor lives in its CALLERS and,
## since A5, here at the writer.)
##
## MINIMUM ONLY, deliberately: net/layer are not re-litigated here, because this
## writer never touches them and re-validating them would make a live drag of a
## zone whose net was deleted out from under it refuse mid-gesture.
func set_zone_outline(zone_id: String, points) -> bool:
	var i := _zone_index(zone_id)
	if i < 0:
		return false
	var pts := PackedVector2Array(points)
	if pts.size() < MIN_ZONE_OUTLINE_POINTS:
		push_warning("[PCBData] set_zone_outline refused: a zone outline needs at least %d points (%d given)" % [MIN_ZONE_OUTLINE_POINTS, pts.size()])
		return false
	zones[i]["outline"] = zone_outline_to_list(pts)
	return true


## Re-assign a committed zone's net. Returns "" on success, or the user-facing
## reason it was refused — the zone_author_error idiom (a refusal STRING, not a
## bare bool), because every caller of this is a UI control that owes the user a
## visible reason, and a bool would make each one invent its own wording for a
## rule this model owns.
##
## SAME AUTHORITY AS create_zone, SCOPED TO THIS FIELD: the proposed (net, kind)
## goes through zone_net_error — the very clause zone_author_error runs at
## authoring time — so a net this board never declared is refused here exactly as
## it is there. It does NOT re-judge the zone's layer; see zone_net_error for why
## judging both fields made a doubly-broken zone unrepairable (cold-review F2).
##
## KEEPOUTS REFUSE A NET OUTRIGHT, which is STRICTER than the board contract:
## docs/board-yaml.md and Go's validateZones both accept a net-scoped keepout
## ("no GND copper here"). This mirrors _commit_zone verbatim — the canvas zone
## tool already drops the armed net for a keepout and says so in as many words
## ("net-scoped keepouts are expressible in the board contract but are not
## something this tool can currently ask for", owner ruling 2026-07-30). One
## authoring surface, one answer: if net-scoped keepouts are ever wanted, they
## are wanted in BOTH places, not acquired by accident through the re-property
## row while the drawing tool still refuses them.
##
## Journals via record_change and emits data_changed (remove_zone's shape); the
## history snapshot is the CALLER's, taken AFTER this returns (mutate-then-
## snapshot, bug 019fb5ad791c).
##
## "" MEANS "NOTHING TO REPORT", NOT "SOMETHING CHANGED". Re-setting the value a
## zone already holds is a no-op: it journals nothing and returns "" exactly as a
## real write does. A caller that snapshots history MUST therefore compare the
## field itself first — save_to_history appends unconditionally, with no dedupe
## against the previous snapshot, so an unguarded caller pushes an EMPTY undo step
## and the user's next Ctrl+Z appears to do nothing (cold-review F3). See
## PCBPanel._on_zone_prop_net_selected for the guard.
func set_zone_net(zone_id: String, net_name: String) -> String:
	var i := _zone_index(zone_id)
	if i < 0:
		return "No such zone."
	var zone: Dictionary = zones[i]
	var kind := zone_kind(zone)
	if kind == "keepout":
		return "A keepout carries no net — it forbids copper rather than being copper."
	var old_net := str(zone.get("net", ""))
	# The NET clause only (cold-review F2): a zone whose layer is also off-contract
	# must still be repairable one field at a time, and a refusal must name the
	# field the caller touched.
	var refusal := zone_net_error(net_name, kind)
	if not refusal.is_empty():
		return refusal
	if net_name == old_net:
		return ""
	zone["net"] = net_name
	record_change("set_zone_net", {
		"zone_id": zone_id,
		"old_net": old_net,
		"net_name": net_name,
		"kind": kind,
	})
	data_changed.emit()
	return ""


## Re-assign a committed zone's copper layer. Same contract as set_zone_net
## above: "" on success, the user-facing refusal otherwise; record_change +
## data_changed here, history snapshot owed by the caller — INCLUDING the
## "" -also-means-no-change caveat spelled out there, which the caller must guard
## against before snapshotting.
##
## FAILS CLOSED ON AN EMPTY LAYER STACK, which zone_author_error does NOT.
## MEASURED: its layer clause is `if not layers.is_empty() and layer not in
## layers`, so a board declaring no stack accepts ANY layer name. That
## permissiveness is defensible at CREATE time (the tool derives the layer from
## the board itself, via zone_author_layer, so there is nothing to typo) and is
## left exactly as it is — create_zone's own path is unchanged and the gap is
## filed separately. It is NOT defensible here: this setter takes a layer name
## from a picker, and with no declared stack there is no such thing as a valid
## target, so the honest answer is a visible refusal rather than writing a layer
## nobody can confirm.
func set_zone_layer(zone_id: String, layer: String) -> String:
	var i := _zone_index(zone_id)
	if i < 0:
		return "No such zone."
	var zone: Dictionary = zones[i]
	if layers.is_empty():
		return "This board declares no layer stack — there is no layer to move the zone to."
	var old_layer := str(zone.get("layer", ""))
	# The LAYER clause only — see set_zone_net for why (cold-review F2).
	var refusal := zone_layer_error(layer)
	if not refusal.is_empty():
		return refusal
	if layer == old_layer:
		return ""
	zone["layer"] = layer
	record_change("set_zone_layer", {
		"zone_id": zone_id,
		"old_layer": old_layer,
		"layer": layer,
		"kind": zone_kind(zone),
	})
	data_changed.emit()
	return ""


## Shared sweep behind get_zones_in_region and cutouts_in_region (cold-review
## B4u3 F4): the two were a byte-for-byte 19-line copy save for the source
## list and ONE predicate (a zone's interior only counts for a keepout;
## a cutout's interior ALWAYS counts — see cutouts_in_region's own doc for
## why). `always_interior` parameterises that one difference; everything else
## — the id-empty skip, the visible_filter contract, the outline-point-count
## guard, the closed-path touch test — is identical for both callers.
static func _region_hits(entities: Array, region: Rect2, visible_filter: Callable,
		always_interior: bool) -> Array[String]:
	var result: Array[String] = []
	for entity in entities:
		var entity_id := str(entity.get("id", ""))
		if entity_id.is_empty():
			continue
		if visible_filter.is_valid() and not visible_filter.call(entity):
			continue
		var pts := zone_outline_points(entity)
		if pts.size() < 3:
			continue
		var closed := pts.duplicate()
		closed.append(pts[0])
		var hit := region_touches_polyline(closed, region)
		if not hit and (always_interior or zone_kind(entity) == "keepout"):
			hit = Geometry2D.is_point_in_polygon(region.get_center(), pts)
		if hit:
			result.append(entity_id)
	return result


## Every zone the marquee `region` touches, with the same `visible_filter`
## contract as get_traces_in_region (Callable(zone) -> bool, view-owned).
##
## The hit rule MIRRORS the click pick (pcb_canvas._zone_at) so what a box grabs
## and what a click grabs stay the same entity language: a pour hits like a PATH
## (its outline must be touched — a marquee drawn deep inside the board-spanning
## GND pour must not silently drag it), while a keepout hits like a FILLED region
## (it renders hatched), so a marquee lying wholly inside one selects it. Thin
## wrapper over _region_hits (always_interior=false: only a keepout's interior
## counts).
func get_zones_in_region(region: Rect2, visible_filter := Callable()) -> Array[String]:
	return _region_hits(zones, region, visible_filter, false)

#endregion


#region Cutout Management

## Fewest points that make a cutout outline a polygon. MIRRORS internal/board's
## validateCutouts (`invalid_cutout_outline`) — the cutout twin of
## MIN_ZONE_OUTLINE_POINTS, same value, kept as its own const because a cutout
## has no other authored field to co-locate it with.
const MIN_CUTOUT_OUTLINE_POINTS := 3


## Why the proposed cutout cannot be authored, or "" when it can.
##
## POINT-COUNT ONLY — unlike zone_author_error, there is no net or layer half:
## a cutout has neither (see the Cutout type's own comment on pcb/internal/
## board/board.go — "which layer" is the one question a cutout cannot be
## asked). One rule, one consumer pair: create_cutout() fail-closes on it, and
## the canvas drawing tool shows it to the user before committing.
func cutout_author_error(point_count: int) -> String:
	if point_count < MIN_CUTOUT_OUTLINE_POINTS:
		return "A cutout outline needs at least %d points (%d placed)." % [MIN_CUTOUT_OUTLINE_POINTS, point_count]
	return ""


## Create an authored cutout and add it to the board. Returns the new cutout
## dict (the model's own, not a copy) or {} when cutout_author_error refused it.
## Mints a persistent "cutout:<hex>" id — mirrors create_zone exactly, minus
## the net/layer fields a cutout does not have. Reuses zone_outline_to_list:
## that helper encodes board-mm points into the canonical {x_mm,y_mm} list and
## is not zone-specific in its implementation.
func create_cutout(outline_points) -> Dictionary:
	# Epoch UX4: build + add, the zone split's cutout twin — see create_zone.
	var built := build_cutout_payload(outline_points)
	if not bool(built.get("ok", false)):
		push_warning("[PCBData] create_cutout refused: %s" % str(built.get("error", "")))
		return {}
	return add_cutout_payload(built.get("payload", {}))


## BUILD half — see build_zone_payload for the contract.
func build_cutout_payload(outline_points) -> Dictionary:
	var pts := PackedVector2Array(outline_points)
	var refusal := cutout_author_error(pts.size())
	if not refusal.is_empty():
		return {"ok": false, "error": refusal}
	return {"ok": true, "payload": {
		"id": mint_entity_id("cutout"),
		"outline": zone_outline_to_list(pts),
	}}


## ADD half — see add_zone_payload for the contract (re-validation, id
## passthrough with format/uniqueness checks, journal + signal).
func add_cutout_payload(payload: Dictionary) -> Dictionary:
	if payload.is_empty():
		return {}
	var outline: Array = payload.get("outline", []) if payload.get("outline", []) is Array else []
	var refusal := cutout_author_error(outline.size())
	if not refusal.is_empty():
		push_warning("[PCBData] add_cutout_payload refused: %s" % refusal)
		return {}
	var cid := str(payload.get("id", ""))
	if cid.is_empty() or not cid.begins_with("cutout:"):
		push_warning("[PCBData] add_cutout_payload refused: payload id '%s' is not a minted cutout id" % cid)
		return {}
	if _cutout_index(cid) >= 0:
		push_warning("[PCBData] add_cutout_payload refused: cutout id '%s' already on the board" % cid)
		return {}
	var cutout: Dictionary = payload.duplicate(true)
	cutouts.append(cutout)
	record_change("add_cutout", {
		"cutout_id": cid,
		"point_count": outline.size(),
	})
	data_changed.emit()
	return cutout


## Remove an authored cutout by id. Returns true when a cutout was removed,
## false for an unknown id. Mirrors remove_zone: record_change + data_changed
## here; the history snapshot is the CALLER's job, taken after the mutation
## (mutate-then-snapshot — see remove_zone for the bug this order avoids).
func remove_cutout(cutout_id: String) -> bool:
	var i := _cutout_index(cutout_id)
	if i < 0:
		return false
	record_change("remove_cutout", {"cutout_id": cutout_id})
	cutouts.remove_at(i)
	data_changed.emit()
	return true


## Index of a cutout in `cutouts` by id, or -1. Mirrors _zone_index.
func _cutout_index(cutout_id: String) -> int:
	for i in cutouts.size():
		if str(cutouts[i].get("id", "")) == cutout_id:
			return i
	return -1


## A cutout by id — the model's OWN dict (mutating it mutates the board), or {}.
func get_cutout(cutout_id: String) -> Dictionary:
	var i := _cutout_index(cutout_id)
	return cutouts[i] if i >= 0 else {}


## Every cutout the marquee `region` touches, with the same `visible_filter`
## contract as get_zones_in_region.
##
## Unlike get_zones_in_region, the interior hit is UNCONDITIONAL — a cutout has
## no kind to branch on, and per the canvas render design (v1: hatched region
## over the board rect, no polygon-with-holes) a cutout hits like a FILLED
## region always, not like a path. A marquee lying wholly inside one selects it.
## Thin wrapper over _region_hits (always_interior=true), the SAME extraction
## get_zones_in_region's own doc names.
func cutouts_in_region(region: Rect2, visible_filter := Callable()) -> Array[String]:
	return _region_hits(cutouts, region, visible_filter, true)

#endregion


#region Placement Proposals (SPIKE 019ff8615fbe — placement-coworking)
## The staged-entity build/add pair for a proposed component MOVE. Same split
## as zones/cutouts (build validates + mints, add re-validates + writes), with
## one structural difference: accept does not ADD an entity to the board — it
## APPLIES a move. The payload therefore has no board-duplicate check; replay
## protection is the store's terminal-disposition rule.
##
## SPIKE stance on copper: accepting a placement NEVER touches traces. The
## affected_nets list (routed flag per net) is advisory freight the ghost and
## the accept reply both surface — "this move strands copper" is a fact shown,
## not a fix applied. The ratification session owns the real ruling.

## Why this payload's TARGET pose is malformed, or "" when whole (Codex 1182
## F1: ONE validator behind both the accept preflight and the add gate, so a
## torn/hand-edited sidecar draft refuses at PREFLIGHT — where the batch is
## still all-or-nothing — instead of mid-write).
static func placement_pose_error(payload: Dictionary) -> String:
	var to = payload.get("to", null)
	if not (to is Dictionary):
		return "placement payload has no 'to' pose"
	for k in ["x_mm", "y_mm"]:
		var v = (to as Dictionary).get(k, null)
		if not (v is float or v is int) or not is_finite(float(v)):
			return "placement 'to.%s' must be a finite number" % k
	var r = (to as Dictionary).get("rotation_deg", 0.0)
	if not (r is float or r is int) or not is_finite(float(r)):
		return "placement 'to.rotation_deg' must be a finite number"
	return ""


## Why the proposed move cannot be authored, or "" when it can.
func placement_author_error(component_id: String) -> String:
	var comp = get_component(component_id)
	if comp == null:
		return "Component \"%s\" is not on this board." % component_id
	if comp.locked:
		return "Component \"%s\" is locked — unlock it before proposing a move." % component_id
	return ""


## Nets touching `component_id`, each with whether the board carries copper
## for it: [{net, routed}]. The what-breaks fact a placement ghost carries.
func placement_affected_nets(component_id: String) -> Array:
	var routed_nets := {}
	for trace_id in traces:
		routed_nets[str(traces[trace_id].net_name)] = true
	var out: Array = []
	for net_name in nets:
		if (nets[net_name].get_pins_for_component(component_id) as Array).is_empty():
			continue
		out.append({"net": str(net_name), "routed": routed_nets.has(str(net_name))})
	return out


## World-space BODY polygon of a component AT AN ARBITRARY POSE — the one
## derivation the collision advisory uses for real parts and ghost targets
## alike (same rotation convention as pcb_component.get_transform).
func component_body_at_pose(component_id: String, x_mm: float, y_mm: float,
		rotation_deg: float) -> PackedVector2Array:
	var comp = get_component(component_id)
	if comp == null:
		return PackedVector2Array()
	var xform := Transform2D(deg_to_rad(-rotation_deg), Vector2.ZERO)
	var out := PackedVector2Array()
	for p in comp.get_local_body_polygon():
		out.append(Vector2(x_mm, y_mm) + (xform * p))
	return out


## COLLISION ADVISORY for a proposed pose (P1, ratified sheet C5 — the parity
## principle: the human SEES an overlap while dragging; the agent must be
## TOLD in the verb's reply). Body-polygon intersection of `component_id` at
## the proposed pose against (a) every OTHER placed part's body and (b) any
## `extra_bodies` [{component_id, x_mm, y_mm, rotation_deg}] — the caller
## passes other live ghost TARGETS here, so two pending proposals colliding
## with each other are caught too. Returns [{ref, overlap_mm2}] — ADVISORY
## always (A7's flag-don't-fix ruling): nothing refuses on it. Body bounds
## are the resolve-attached footprint bounds, so this approximates courtyard
## contact; the authoritative courtyard verdict stays assembly_check's.
func placement_collisions(component_id: String, x_mm: float, y_mm: float,
		rotation_deg: float, extra_bodies: Array = []) -> Array:
	var moving := component_body_at_pose(component_id, x_mm, y_mm, rotation_deg)
	if moving.size() < 3:
		return []
	var out: Array = []
	for other_id in components:
		if str(other_id) == component_id:
			continue
		var other = components[other_id]
		var other_poly := component_body_at_pose(str(other_id),
			other.position.x, other.position.y, other.rotation)
		var area := _polygon_overlap_area(moving, other_poly)
		if area > 0.0:
			out.append({"ref": str(other_id), "overlap_mm2": area})
	for b in extra_bodies:
		if not (b is Dictionary):
			continue
		var bid := str((b as Dictionary).get("component_id", ""))
		if bid == component_id:
			continue
		var ghost_poly := component_body_at_pose(bid,
			float((b as Dictionary).get("x_mm", 0.0)),
			float((b as Dictionary).get("y_mm", 0.0)),
			float((b as Dictionary).get("rotation_deg", 0.0)))
		var g_area := _polygon_overlap_area(moving, ghost_poly)
		if g_area > 0.0:
			out.append({"ref": bid, "overlap_mm2": g_area, "ghost": true})
	return out


static func _polygon_overlap_area(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if a.size() < 3 or b.size() < 3:
		return 0.0
	var total := 0.0
	for piece in Geometry2D.intersect_polygons(a, b):
		var poly: PackedVector2Array = piece
		# Shoelace; Godot may return either winding, so take the magnitude.
		var acc := 0.0
		for i in poly.size():
			var p := poly[i]
			var q := poly[(i + 1) % poly.size()]
			acc += p.x * q.y - q.x * p.y
		total += absf(acc) * 0.5
	return total


## BUILD half — see build_zone_payload for the contract. `from` is the
## component's pose NOW (captured at build so the ghost can draw its tether
## and the journal can tell what the proposal believed it was moving).
func build_placement_payload(component_id: String, to_x_mm: float, to_y_mm: float,
		to_rotation_deg: float) -> Dictionary:
	var refusal := placement_author_error(component_id)
	if not refusal.is_empty():
		return {"ok": false, "error": refusal}
	var comp = get_component(component_id)
	return {"ok": true, "payload": {
		"id": mint_entity_id("placement"),
		"component_id": component_id,
		"from": {"x_mm": comp.position.x, "y_mm": comp.position.y,
			"rotation_deg": comp.rotation},
		"to": {"x_mm": to_x_mm, "y_mm": to_y_mm, "rotation_deg": to_rotation_deg},
		"affected_nets": placement_affected_nets(component_id),
	}}


## ADD half — APPLY the proposed move against the CURRENT board (re-validated:
## the component may have been deleted or locked since staging). Journals the
## standard move_component/rotate_component shapes so every existing journal
## reader parses the landing. Returns the payload dict, or {} with a warning.
func add_placement_payload(payload: Dictionary) -> Dictionary:
	if payload.is_empty():
		return {}
	var component_id := str(payload.get("component_id", ""))
	var refusal := placement_author_error(component_id)
	if not refusal.is_empty():
		push_warning("[PCBData] add_placement_payload refused: %s" % refusal)
		return {}
	var pid := str(payload.get("id", ""))
	if pid.is_empty() or not pid.begins_with("placement:"):
		push_warning("[PCBData] add_placement_payload refused: payload id '%s' is not a minted placement id" % pid)
		return {}
	var pose_err := placement_pose_error(payload)
	if not pose_err.is_empty():
		push_warning("[PCBData] add_placement_payload refused: %s" % pose_err)
		return {}
	var to: Dictionary = payload.get("to", {})
	var comp = get_component(component_id)
	var target := Vector2(float(to.get("x_mm", 0.0)), float(to.get("y_mm", 0.0)))
	if comp.position != target:
		move_component(component_id, target)
	var target_rot := float(to.get("rotation_deg", comp.rotation))
	if comp.rotation != target_rot:
		rotate_component(component_id, target_rot)
	return payload

#endregion


#region Trace Authoring

## Fallback width for an authored trace when the board declares no design rule.
## MATCHES pcb_trace.gd's own `width` default (it IS that constant since A7), so
## a board with no design_rules block authors traces at the same width the rest
## of this model already assumes rather than at a second, differently-chosen
## number.
const DEFAULT_TRACE_WIDTH_MM := PCBTraceScript.DEFAULT_WIDTH_MM


## The board's OWN declared trace width, or 0.0 when it declares none.
##
## Split out of authored_trace_width (A7) because the two questions are
## different and one caller needs the harder one: authored_trace_width answers
## "what width do I lay copper at" and is never allowed to return 0, so it cannot
## distinguish "the board says 0.25" from "the board says nothing and 0.25 is the
## fallback". The width control's seeding order (board rule > stored preference >
## control default, owner ruling this round) turns on exactly that distinction —
## a stored preference must lose to a real design rule and WIN over a fallback.
## Non-positive is treated as absent: a malformed rule is not an answer.
func design_rule_trace_width() -> float:
	var w := float(design_rules.get("trace_width_mm", 0.0))
	return w if w > 0.0 else 0.0


## The board's OWN declared copper-to-copper clearance, or 0.0 when it declares
## none. mm.
##
## EXACT MIRROR of design_rule_trace_width above — same canonical block, same
## "non-positive is not an answer" reading, same 0.0-means-no-rule return. The
## two are the pair a parallel-bus pitch needs (pcb_bus_geometry.pitch_between
## takes both widths and this clearance), so they are deliberately the same shape
## rather than one of them growing a fallback of its own.
##
## THE FALLBACK ASYMMETRY IS ON PURPOSE. authored_trace_width() exists because a
## zero-width trace is not copper, so a missing width MUST become something.
## There is no authored_clearance() twin: a missing clearance is a real answer —
## "this board states no separation requirement" — and the honest handling is to
## surface the 0.0 to the caller, who can then space a bus at touching-but-not-
## overlapping pitch, or refuse, or ask. Inventing a house clearance here would
## put a number the board never declared into copper the fab will build.
##
## This is the FIRST reader of design_rules.clearance_mm anywhere in pcb/ui/ —
## the key has round-tripped through to_board_dict/from_board_dict since zones
## landed, but nothing had asked it a question until the bus geometry did.
func design_rule_clearance() -> float:
	var c := float(design_rules.get("clearance_mm", 0.0))
	return c if c > 0.0 else 0.0


## The width a newly authored trace gets, in mm.
##
## `design_rules` is the canonical board block (see its declaration) and
## `trace_width_mm` is its canonical key — the board's own answer to "how wide is
## a trace here", so the drawing tool asks the board instead of carrying a
## preference of its own. Non-positive or missing (an older board, or one whose
## design_rules block never named a width) falls back to DEFAULT_TRACE_WIDTH_MM;
## a zero-width trace is not copper, so a malformed rule must not produce one.
##
## UNCHANGED BEHAVIOUR after the A7 split above — same rule, same fallback, now
## expressed through design_rule_trace_width() so there is one place that reads
## the design_rules key.
func authored_trace_width() -> float:
	var w := design_rule_trace_width()
	return w if w > 0.0 else DEFAULT_TRACE_WIDTH_MM


## Why the proposed trace cannot be authored, or "" when it can.
##
## ONE rule set, two consumers — create_trace_entity() fail-closes on it and the
## canvas tool shows it before committing — exactly as zone_author_error() does
## for zones. It is NOT, however, a mirror of a Go validator: validateZones has
## no trace twin, and internal/board/validate.go says so in as many words ("there
## is no pre-existing 'a trace's net/layer must exist' check in this function to
## mirror"). So these are the UI's own authoring rules, deliberately set at the
## zone bar: a trace naming a net or layer the board never declared is copper
## nothing downstream can check (get_traces_for_net, the ratsnest and DRC all key
## on declared net names), and refusing the gesture is cheaper than shipping it.
##
## The one rule Go DOES enforce on traces is IDENTITY, not content: on a v2 board
## Validate() requires every trace id to be a minted "trace:<32hex>" — see
## create_trace_entity for why that is the id this path mints.
## Why a via may NOT be placed at `pos`, or "" if it may — the via twin of
## trace_author_error, and for the same reason: ONE rule read by both the
## canvas Via tool and minerva_pcb_place_via, so a human's click and an agent's
## call are refused identically, in identical words.
##
## Deliberately NOT a span check. A v1 via is a THROUGH via and its span is
## always top<->bottom whatever the stack depth, so there is nothing here to
## choose or validate; blind/buried vias are out of scope (see
## methods._routes_to_vias' docstring, and epoch NLC C1b).
func via_author_error(pos: Vector2, size: float, drill: float, net_name: String = "",
		ignore_via_id: String = "") -> String:
	# NaN FIRST, because every comparison below is false against it — a NaN
	# coordinate would sail through the bounds test and land copper nowhere.
	# It arrives from a caller that coerced a non-numeric argument, which is
	# exactly the shape a loosely-typed tool call has.
	if is_nan(pos.x) or is_nan(pos.y) or is_nan(size) or is_nan(drill):
		return "A via needs finite numbers for its position, size and drill."
	if size <= 0.0 or drill <= 0.0:
		return "A via needs a positive size and drill (got %.4f / %.4f)." % [size, drill]
	# An EMPTY net is fine — a via may be unassigned. A NAMED net that this
	# board does not declare is a typo, and accepting it would put the via on a
	# net nothing else is on. The trace side already refuses this through
	# trace_author_error; the via side used to accept it silently.
	if not net_name.is_empty() and not has_net(net_name):
		return "Net \"%s\" is not declared on this board." % net_name
	if drill >= size:
		# The difference between them IS the annular ring, so a drill at least
		# as wide as the pad is a hole through nothing. Caught here rather than
		# in a fabricator's DFM report.
		return "Drill %.4fmm must be smaller than pad %.4fmm — the difference is the annular ring." \
			% [drill, size]
	if board_width > 0.0 and board_height > 0.0 \
			and (pos.x < 0.0 or pos.y < 0.0 or pos.x > board_width or pos.y > board_height):
		return "(%.3f, %.3f) is outside this %.3f x %.3f mm board." \
			% [pos.x, pos.y, board_width, board_height]
	for existing in vias:
		if not (existing is Dictionary):
			continue
		if not ignore_via_id.is_empty() and str((existing as Dictionary).get("id", "")) == ignore_via_id:
			continue
		# The via's OWN disc is the claim, floored so a hairline via still has a
		# clickable footprint — the same shape RoutingWorkspace.add_via uses for
		# the same gesture question.
		var claim: float = maxf(float((existing as Dictionary).get("size", 0.8)) * 0.5, 0.05)
		if via_position(existing).distance_to(pos) <= claim:
			return "A via already sits at (%.3f, %.3f)." % [pos.x, pos.y]
	return ""


## Resolve the semantic target of a via authoring gesture.
##
## A via dropped in empty space remains a first-class standalone entity. A via
## whose annulus physically reaches an existing trace is not "near" that trace:
## it is copper touching copper. Leaving the raw click offset and netless makes
## the rendering claim a connection the model denies. This resolver therefore
## snaps that case to the nearest trace centreline, inherits the trace net when
## the caller did not name one, and returns the trace identity that must receive
## an explicit waypoint when the via is materialised.
##
## More than one touched net is ambiguous and refuses. A caller-authored net
## that disagrees with the touched trace also refuses rather than silently
## changing ownership. `ignore_via_id` is the move seam: the via being moved may
## occupy its own source/target point without tripping the duplicate gate.
func resolve_via_target(pos: Vector2, size: float, drill: float,
		net_name: String = "", ignore_via_id: String = "") -> Dictionary:
	var shape_error := via_author_error(pos, size, drill, net_name, ignore_via_id)
	if not shape_error.is_empty():
		return {"ok": false, "error": shape_error}

	var hits: Array = []
	for trace_id in traces:
		var trace = traces[trace_id]
		if trace == null or trace.waypoints.size() < 2:
			continue
		var closest: Vector2 = trace.get_closest_point(pos)
		var distance := closest.distance_to(pos)
		# Physical contact is the capture rule: outer via radius plus half the
		# trace width. This catches the HITL's partly-overlapping via without a
		# view/zoom-dependent magic number.
		var capture := size * 0.5 + float(trace.width) * 0.5
		if distance <= capture:
			hits.append({
				"trace_id": str(trace_id),
				"net_name": str(trace.net_name),
				"position": closest,
				"segment_index": int(trace.get_closest_segment_index(pos)),
				"distance": distance,
			})

	if hits.is_empty():
		return {"ok": true, "position": pos, "net_name": net_name,
			"trace_id": "", "segment_index": -1, "snapped": false}

	var touched_nets: Dictionary = {}
	for hit in hits:
		touched_nets[str((hit as Dictionary).get("net_name", ""))] = true
	if touched_nets.size() > 1:
		var names: Array = touched_nets.keys()
		names.sort()
		return {"ok": false, "error":
			"A via at (%.3f, %.3f) touches traces on multiple nets (%s); move it so the intended trace is unambiguous."
				% [pos.x, pos.y, ", ".join(names)]}

	# Deterministic winner: nearest centreline, then stable trace id.
	hits.sort_custom(func(a, b) -> bool:
		var da := float((a as Dictionary).get("distance", INF))
		var db := float((b as Dictionary).get("distance", INF))
		if not is_equal_approx(da, db):
			return da < db
		return str((a as Dictionary).get("trace_id", "")) < str((b as Dictionary).get("trace_id", "")))
	var chosen: Dictionary = hits[0]
	var trace_net := str(chosen.get("net_name", ""))
	if not net_name.is_empty() and net_name != trace_net:
		return {"ok": false, "error":
			"Via net '%s' conflicts with trace '%s' on net '%s'."
				% [net_name, str(chosen.get("trace_id", "")), trace_net]}
	var snapped_pos: Vector2 = chosen["position"]
	var snapped_error := via_author_error(
		snapped_pos, size, drill, trace_net if net_name.is_empty() else net_name,
		ignore_via_id)
	if not snapped_error.is_empty():
		return {"ok": false, "error": snapped_error}
	return {"ok": true, "position": snapped_pos,
		"net_name": trace_net if net_name.is_empty() else net_name,
		"trace_id": str(chosen.get("trace_id", "")),
		"segment_index": int(chosen.get("segment_index", -1)), "snapped": true}


## Insert an explicit waypoint where a via meets `trace_id`. The geometric
## result is unchanged, but the canonical topology now says what the rendering
## says: the trace is bisected at the via rather than merely passing beneath it.
## Returns true when a point was inserted, false when the trace already had the
## junction (or the trace no longer exists).
func insert_trace_junction(trace_id: String, position: Vector2) -> bool:
	var trace = get_trace(trace_id)
	if trace == null or trace.waypoints.size() < 2:
		return false
	const JUNCTION_EPS_MM := 0.0001
	for point in trace.waypoints:
		if (point as Vector2).distance_to(position) <= JUNCTION_EPS_MM:
			return false
	var segment_index := int(trace.get_closest_segment_index(position))
	if segment_index < 0:
		return false
	var projected: Vector2 = trace.get_closest_point(position)
	trace.waypoints.insert(segment_index + 1, projected)
	record_change("insert_trace_junction", {
		"trace_id": trace_id, "point_index": segment_index + 1,
		"position": {"x": projected.x, "y": projected.y},
	})
	trace_changed.emit(trace_id)
	data_changed.emit()
	return true


## Move one committed via as a position-only entity while preserving any real
## copper junction it already owns. Exact trace contacts at the old point move
## with the via; a trace touched at the destination is snapped, net-checked and
## explicitly bisected through the same resolver direct placement uses.
## History is the caller's (the canvas batches mixed-selection movement).
##
## POSITION-ONLY SUGAR over update_via, which is the one via-edit rule. A drag
## can only change a position, so keeping this narrow verb is what stops the
## drag path from ever rewriting a net, a size or a drill by accident.
func move_via(via_id: String, target: Vector2) -> Dictionary:
	return update_via(via_id, {"position": target})


## THE ONE VIA-EDIT RULE — what via_author_error/resolve_via_target are for
## CREATION, this is for a via that already exists. The canvas drag, the
## Properties rows and minerva_pcb_update_via all come through here, so a
## human's edit and an agent's call are refused identically, in identical
## words: the same contract _place_via keeps for placement (DCR 01a0033a12a9
## change 2). Before it there was no way to change a placed via's net, size or
## drill AT ALL on any surface, and its position could only be changed by
## dragging it — so an agent could delete and re-create a via but never adjust
## one, which is the same parity hole station C2 closed for placement.
##
## ABSENT KEY MEANS UNCHANGED. `changes` may carry any of "position" (Vector2),
## "net_name" (String), "size" and "drill" (float). A key that is not present is
## not an instruction to clear that field — a partial edit must never blank the
## rest of the via.
##
## VALIDATED IN FULL BEFORE ANYTHING IS APPLIED. The effective post-edit values
## go through resolve_via_target as ONE set, so an edit that would be refused
## leaves the via exactly as it was rather than half-applied. That ordering is
## load-bearing rather than tidy: the trace-capture radius is size-dependent, so
## a via that grows must be judged at its NEW size. Assigning the size first and
## resolving after would decide contact against geometry the board never had.
##
## TWO RESULTS THAT LOOK SURPRISING AND ARE THE MODEL BEING CONSISTENT:
##   * GROWING a via can MOVE it. A wider annulus can reach a trace it did not
##     touch before, and a via touching copper snaps to that centreline and
##     inherits the net exactly as placement does. The alternative is precisely
##     the offset, netless via that bug 01a003e2fb6e was filed for.
##   * CLEARING the net of a via that sits ON a trace does not leave it netless.
##     resolve_via_target re-inherits the trace's net, because a hole in that
##     copper IS on that net whatever the caller typed.
## The reply therefore reports the RESULTING position and net, never the
## requested ones, so a caller can always see when either happened.
func update_via(via_id: String, changes: Dictionary) -> Dictionary:
	var via: Dictionary = get_via(via_id)
	if via.is_empty():
		return {"ok": false, "error": "via_not_found",
			"message": "No via '%s' exists on this board." % via_id}
	var old_pos := via_position(via)
	var old_size := float(via.get("size", 0.8))
	var old_drill := float(via.get("drill", 0.4))
	var old_net := str(via.get("net_name", ""))

	# TYPE-GUARDED, not coerced. `changes["position"]` assigned straight into a
	# typed Vector2 local HARD-ERRORS on anything else, which is the 23-site
	# defect class docket 019fa0f8d575 records for this codebase. Refuse by name
	# instead. The numbers below need no such guard: float("nope") is 0.0 in
	# GDScript and via_author_error already refuses a non-positive size or drill
	# by name, so a bad number cannot become geometry.
	if changes.has("position") and not (changes["position"] is Vector2):
		return {"ok": false, "error": "via_not_placeable",
			"message": "A via position must be a Vector2 (got %s)." % str(changes["position"])}
	var target: Vector2 = changes["position"] if changes.has("position") else old_pos
	var size := float(changes["size"]) if changes.has("size") else old_size
	var drill := float(changes["drill"]) if changes.has("drill") else old_drill
	var want_net := str(changes["net_name"]) if changes.has("net_name") else old_net

	var resolved := resolve_via_target(target, size, drill, want_net, via_id)
	if not bool(resolved.get("ok", false)):
		return {"ok": false, "error": "via_not_placeable",
			"message": str(resolved.get("error", "The via cannot be moved there."))}
	var new_pos: Vector2 = resolved["position"]
	var new_net := str(resolved.get("net_name", old_net))
	if new_pos.distance_to(old_pos) <= 0.0001 and new_net == old_net \
			and is_equal_approx(size, old_size) and is_equal_approx(drill, old_drill):
		return {"ok": true, "via_id": via_id, "position": new_pos,
			"net_name": new_net, "size": old_size, "drill": old_drill,
			"trace_ids": [], "moved": false}

	# Every same-net trace that genuinely meets the old centre owns this
	# junction. Move that point with the via rather than detaching the hole.
	var touched: Array = []
	for trace_id in traces:
		var trace = traces[trace_id]
		if trace == null or trace.waypoints.size() < 2 or str(trace.net_name) != old_net:
			continue
		if trace.get_closest_point(old_pos).distance_to(old_pos) > 0.0001:
			continue
		var replaced := false
		for i in range(trace.waypoints.size()):
			if (trace.waypoints[i] as Vector2).distance_to(old_pos) <= 0.0001:
				trace.waypoints[i] = new_pos
				replaced = true
		if not replaced:
			var si := int(trace.get_closest_segment_index(old_pos))
			trace.waypoints.insert(si + 1, new_pos)
		if not (str(trace_id) in touched):
			touched.append(str(trace_id))

	via["position"] = new_pos
	via["net_name"] = new_net
	via["size"] = size
	via["drill"] = drill
	var target_trace := str(resolved.get("trace_id", ""))
	if not target_trace.is_empty():
		insert_trace_junction(target_trace, new_pos)
		if not (target_trace in touched):
			touched.append(target_trace)
	# ONE journal entry per edit, whatever it changed — a caller reading the
	# journal for a move still finds it here with old_position != new_position.
	# The old/new pairs are carried for every field so an entry is readable
	# without the board state that produced it.
	record_change("update_via", {
		"via_id": via_id,
		"old_position": {"x": old_pos.x, "y": old_pos.y},
		"new_position": {"x": new_pos.x, "y": new_pos.y},
		"old_net_name": old_net, "new_net_name": new_net,
		"old_size": old_size, "new_size": size,
		"old_drill": old_drill, "new_drill": drill,
		"trace_ids": touched.duplicate(),
	})
	for trace_id in touched:
		trace_changed.emit(str(trace_id))
	data_changed.emit()
	return {"ok": true, "via_id": via_id, "position": new_pos,
		"net_name": new_net, "size": size, "drill": drill,
		"trace_ids": touched, "moved": true,
		"snapped": bool(resolved.get("snapped", false))}


func trace_author_error(net_name: String, layer: String, point_count: int) -> String:
	if point_count < 2:
		return "A trace needs at least 2 points (%d placed)." % point_count
	if net_name.is_empty():
		return "A trace must name a net — the one carried by the pad, via or trace end it starts on."
	if not has_net(net_name):
		return "Net \"%s\" is not declared on this board." % net_name
	if layer.is_empty():
		return "No copper layer to place the trace on."
	if not layers.is_empty() and layer not in layers:
		return "Layer \"%s\" is not in the board's declared layer stack." % layer
	return ""


## Create an authored trace and add it to the board. Returns the new trace
## object, or null when trace_author_error refused it.
##
## MINTED, NOT ORDINAL — and this is the whole reason the path exists rather than
## callers just using add_trace(). add_trace() mints "trace_7" for an id-less
## trace; internal/board/migrate.go's isMintedID() rejects that shape, so on a v2
## board Validate() fails `unminted_persistent_id` and pcb.serialize — a
## fail-closed WHOLE-BOARD write gate — refuses to save the entire board, not
## merely the one trace. The ordinal handles are the v1 ordinal-bridge era's, and
## MigrateV1toV2 is what re-mints them; a trace authored today should not need
## rescuing by a migration.
##
## add_trace() itself is DELIBERATELY UNCHANGED: its behaviour for its existing
## callers (importers, the router's commit path, undo/redo restore) is load-
## bearing — the ID COUNTER INVARIANT above is built on those ordinals — and
## re-minting under them would renumber ids they hand back and forth. Instead this
## path pre-sets the id and hands the trace to add_trace, which takes the
## caller-supplied-id branch. That branch high-waters _next_trace_id via
## _stable_id_suffix(); a minted id contains no "_", so it returns 0 and the
## counter is left exactly where it was. Verified, not assumed — the minted path
## therefore cannot perturb ordinal minting for anyone else. Journalling,
## trace_changed and data_changed all come from add_trace, so there is one
## add-a-trace code path, not two.
##
## History is NOT snapshotted here (no mutator in this file snapshots itself —
## the caller decides where an undo step begins and ends); the canvas commit path
## calls save_to_history() AFTER this returns, the move idiom.
func create_trace_entity(net_name: String, layer: String, points, width: float = 0.0):
	var pts := PackedVector2Array(points)
	var refusal := trace_author_error(net_name, layer, pts.size())
	if not refusal.is_empty():
		push_warning("[PCBData] create_trace_entity refused: %s" % refusal)
		return null

	var trace = PCBTraceScript.new()
	trace.id = mint_entity_id("trace")
	trace.net_name = net_name
	trace.layer = layer
	trace.width = width if width > 0.0 else authored_trace_width()
	for p in pts:
		trace.waypoints.append(p)

	add_trace(trace)
	return trace

#endregion


#region Board Properties

## Declare what this board IS for manufacturing. Returns "" on success, or the
## refusal in the board model's own words — the set_zone_net idiom, so the
## panel and minerva_pcb_set_fabrication_stage show one sentence, not two.
##
## THE vias_only RULE IS MIRRORED FROM THE WRITE GATE, not invented here.
## internal/board/validate.go's validateFabricationStage refuses a vias_only
## board that carries traces, because a declaration the board's own contents
## contradict is a false one, and without that refusal the two deferred stages
## would be pure synonyms. Checking it HERE too is not duplicated authority: the
## Go gate stays the authority and would still refuse on save. This one exists
## so the human finds out when they pick the value rather than when the file
## fails to write, which is the same reason the zone pickers refuse locally.
##
## History is NOT snapshotted here — the house rule that no mutator in this file
## snapshots itself. The caller owns the undo step.
func set_fabrication_stage(stage: String) -> String:
	var wanted := FAB_STAGE_ROUTED if stage.is_empty() else stage
	if wanted not in FAB_STAGES:
		return "\"%s\" is not a fabrication stage this pipeline knows (want %s)." \
			% [stage, ", ".join(FAB_STAGES)]
	if wanted == FAB_STAGE_VIAS_ONLY and not traces.is_empty():
		return ("\"%s\" declares no copper runs, but this board has %d trace(s) — "
			+ "declare \"%s\" instead, or delete the traces.") \
			% [FAB_STAGE_VIAS_ONLY, traces.size(), FAB_STAGE_ROUTING_DEFERRED]
	if wanted == fabrication_stage:
		return ""
	var previous := fabrication_stage
	fabrication_stage = wanted
	record_change("set_fabrication_stage", {
		"old_stage": previous, "new_stage": wanted,
	})
	structure_changed.emit()
	data_changed.emit()
	return ""


## Resize the board outline (journalled + emits structure/data changes).
func set_board_size(new_width: float, new_height: float) -> void:
	var old_width := board_width
	var old_height := board_height
	board_width = new_width
	board_height = new_height
	record_change("resize_board", {
		"old_width": old_width, "old_height": old_height,
		"new_width": new_width, "new_height": new_height
	})
	structure_changed.emit()
	data_changed.emit()

#endregion


#region Undo/Redo Support

## ── HISTORY BUCKET 8: the routing workspace's disposition layer (C4a/INV-1) ───
##
## The seven buckets below this line are BOARD state. The eighth is not: it is
## the routing workspace's answer to "which candidate produced this copper, and
## what was it before it did". It rides the same snapshot because committing a
## route candidate is ONE act with two halves — copper appears AND the candidate
## becomes committed — and an undo that reverted only the copper would leave the
## workspace claiming copper that is no longer on the board.
##
## The board does not know what a RoutingWorkspace is. It holds a DUCK-TYPED
## delegate and calls exactly two method names on it (snapshot_dispositions /
## restore_dispositions), so this file preloads nothing from the routing model
## and the pure board model stays pure. An unbound delegate means the key is
## simply absent from the snapshot and no restore is attempted — never a guess.
var _workspace_delegate = null

## ── HISTORY BUCKET 9: the staged-entity store's disposition layer ─────────────
## (Epoch UX4, DCR 019fe07523ca F8.) The bucket-8 pattern verbatim, second
## participant: ACCEPTING a staged entity is ONE act with two halves — the
## entity appears on the board AND the entry becomes accepted — and an undo
## that reverted only the board write would leave the store claiming an
## acceptance the board no longer shows. Same duck-typed two-method contract
## (snapshot_dispositions/restore_dispositions), same absent-key rule.
var _staged_delegate = null

## Bind (or unbind, with null) the routing-workspace delegate. Idempotent.
func bind_routing_workspace(delegate) -> void:
	_workspace_delegate = delegate


## Bind (or unbind, with null) the staged-entity store delegate. Idempotent.
func bind_staged_store(delegate) -> void:
	_staged_delegate = delegate


func staged_store_delegate():
	return _staged_delegate


## The bound delegate, or null. Read surface for the owner and the tests.
func routing_workspace_delegate():
	return _workspace_delegate


## The delegate's snapshot, or {} when there is nothing to ask.
func _workspace_snapshot() -> Dictionary:
	if _workspace_delegate == null or not is_instance_valid(_workspace_delegate):
		return {}
	if not _workspace_delegate.has_method("snapshot_dispositions"):
		return {}
	var snap = _workspace_delegate.snapshot_dispositions()
	return snap if snap is Dictionary else {}


## Bucket-9 twin of _workspace_snapshot.
func _staged_snapshot() -> Dictionary:
	if _staged_delegate == null or not is_instance_valid(_staged_delegate):
		return {}
	if not _staged_delegate.has_method("snapshot_dispositions"):
		return {}
	var snap = _staged_delegate.snapshot_dispositions()
	return snap if snap is Dictionary else {}


## THE PAIRED SNAPSHOT. Stamp the CURRENT workspace layer onto the history entry
## that is already on top — the one that represents the board as it is RIGHT
## NOW, before the caller's about-to-happen mutation.
##
## Why this exists at all: undo() restores the PREVIOUS entry, so for
## undo-after-commit to restore the PRE-commit disposition, the pre-commit
## disposition has to be sitting on the previous entry. A delegate bound at the
## moment of the first commit was not bound when that entry was written, so the
## key would be missing and the undo would restore the board while leaving the
## candidate committed. Calling this immediately before the commit's own batch
## closes that window deterministically, regardless of when binding happened.
##
## Returns false when there is no entry to stamp (a board with no history has
## nothing to undo TO, so there is nothing to pair).
func attach_workspace_snapshot() -> bool:
	if history_index < 0 or history_index >= history.size():
		return false
	var entry: Dictionary = history[history_index]
	entry["workspace"] = _workspace_snapshot()
	history[history_index] = entry
	return true


## Bucket-9 twin of attach_workspace_snapshot — the ACCEPT site calls this
## immediately before its board write, for exactly the reason that function's
## doc records (the pre-accept disposition must sit on the PREVIOUS entry for
## undo-after-accept to restore it, regardless of when binding happened).
func attach_staged_snapshot() -> bool:
	if history_index < 0 or history_index >= history.size():
		return false
	var entry: Dictionary = history[history_index]
	entry["staged"] = _staged_snapshot()
	history[history_index] = entry
	return true


## Hand a restored snapshot's workspace layer back to the delegate.
## ABSENT KEY ⇒ UNTOUCHED: an entry written before a delegate was bound says
## nothing about the workspace, and "says nothing" must never be read as "had no
## candidates" — that would silently reset dispositions on every undo of a
## pre-binding edit.
func _restore_workspace_snapshot(state: Dictionary) -> void:
	if not state.has("workspace"):
		return
	if _workspace_delegate == null or not is_instance_valid(_workspace_delegate):
		return
	if not _workspace_delegate.has_method("restore_dispositions"):
		return
	var snap = state.get("workspace", {})
	_workspace_delegate.restore_dispositions(snap if snap is Dictionary else {})


## Bucket-9 twin — same absent-key-⇒-untouched rule, same rationale.
func _restore_staged_snapshot(state: Dictionary) -> void:
	if not state.has("staged"):
		return
	if _staged_delegate == null or not is_instance_valid(_staged_delegate):
		return
	if not _staged_delegate.has_method("restore_dispositions"):
		return
	var snap = state.get("staged", {})
	_staged_delegate.restore_dispositions(snap if snap is Dictionary else {})


## Save current state to history
func save_to_history(action_name: String = "Change") -> void:
	# Remove any redo states
	if history_index < history.size() - 1:
		history.resize(history_index + 1)

	# Save current state
	var state := {
		"action": action_name,
		"components": _serialize_components(),
		"nets": _serialize_nets(),
		"traces": _serialize_traces(),
		# F1 (Codex 019f70ec149b): the undo codec previously omitted vias +
		# mounting_holes (only the full-board serialize carried them), so
		# undoing an accepted via route removed its traces but ORPHANED its
		# vias. Deep-duplicate both into the snapshot so _restore_state can
		# rebuild them faithfully. Interim fix; the DCR (T1) unifies undo onto
		# one complete board codec.
		"vias": vias.duplicate(true),
		"mounting_holes": mounting_holes.duplicate(true),
		# Zones ride the snapshot for the SAME reason F1 put vias here. Nothing
		# edits a zone yet, so no undo step can currently change one — but the
		# snapshot is applied WHOLESALE by _restore_state, so a zone absent from
		# it is a zone DELETED by the next undo of an unrelated edit. Carrying it
		# costs a copy and closes the hole before an editing tool opens it.
		"zones": _zones_to_list(),
		# Cutouts ride the snapshot for the SAME reason zones do, one line up —
		# create_cutout/remove_cutout are forward mutators like add_zone/
		# remove_zone, so a cutout absent from a restored snapshot is a cutout
		# the next undo of an unrelated edit would silently delete.
		"cutouts": _cutouts_to_list(),
		# The layer STACK rides the snapshot as of epoch GA-1, because
		# set_board_layers is now a mutator: undoing across a stack edit
		# without this bucket would restore copper onto layers the board no
		# longer declares (or strand a widened stack). _restore_state treats an
		# ABSENT key as "leave the stack alone" so pre-GA-1 snapshots (none
		# survive a session, but the absent-key rule is the codec's contract)
		# stay applicable.
		"layers": layers.duplicate(),
		# The DECLARED STAGE rides the snapshot for the same reason the stack
		# does: set_fabrication_stage is a mutator, so undoing across a stage
		# edit without this bucket would leave the declaration behind while
		# every other bucket rewound. _restore_state's absent-key rule applies
		# here too — an older snapshot leaves the stage alone.
		"fabrication_stage": fabrication_stage
	}

	# BUCKET 8 — the routing workspace's disposition layer (see the block above
	# this function). Added ONLY when a delegate is bound, so a board with no
	# routing workspace produces byte-identical snapshots to the seven-bucket
	# ones it always did, and _restore_state's absent-key rule stays meaningful.
	if _workspace_delegate != null and is_instance_valid(_workspace_delegate):
		state["workspace"] = _workspace_snapshot()

	# BUCKET 9 — the staged store's disposition layer (Epoch UX4): same
	# bound-only rule, so an unbound board's snapshots stay byte-identical.
	if _staged_delegate != null and is_instance_valid(_staged_delegate):
		state["staged"] = _staged_snapshot()

	history.append(state)
	history_index = history.size() - 1

	# Limit history size
	if history.size() > MAX_HISTORY_SIZE:
		history.remove_at(0)
		history_index -= 1


## Undo last action
func undo() -> bool:
	if history_index <= 0:
		return false

	history_index -= 1
	_restore_state(history[history_index])
	# Undo produces a NEW board state — bump FORWARD (never roll back). See
	# board_revision doc.
	_bump_board_revision()
	data_changed.emit()
	structure_changed.emit()
	return true


## Redo last undone action
func redo() -> bool:
	if history_index >= history.size() - 1:
		return false

	history_index += 1
	_restore_state(history[history_index])
	# Redo is also a fresh state transition — bump forward.
	_bump_board_revision()
	data_changed.emit()
	structure_changed.emit()
	return true


## Single point that advances the monotonic-forward board revision. While a batch
## is open the bump is deferred (marked _batch_touched); end_batch() applies the
## one bump for the whole batch.
func _bump_board_revision() -> void:
	if _batch_active:
		_batch_touched = true
		return
	board_revision += 1


## Open a batch: defer per-mutation board_revision bumps until end_batch()
## (mutators don't self-snapshot history, so there is nothing else to suppress).
## Nested begin_batch() is ignored (stays a single batch).
func begin_batch() -> void:
	if _batch_active:
		push_warning("[PCBData] begin_batch called while a batch is already open")
		return
	_batch_active = true
	_batch_touched = false


## Close a batch: if any mutation was applied, perform exactly ONE save_to_history
## and ONE board_revision bump for everything in the batch (a single undo reverts
## the whole batch). A batch with no mutations is a no-op.
func end_batch(action_name: String = "Batch") -> void:
	if not _batch_active:
		push_warning("[PCBData] end_batch called with no open batch")
		return
	_batch_active = false
	if not _batch_touched:
		return
	_batch_touched = false
	save_to_history(action_name)
	_bump_board_revision()


## Check if undo is available
func can_undo() -> bool:
	return history_index > 0


## Check if redo is available
func can_redo() -> bool:
	return history_index < history.size() - 1


## Serialize components for undo
func _serialize_components() -> Dictionary:
	var result := {}
	for id in components:
		result[id] = components[id].to_dict()
	return result


## Serialize nets for undo
func _serialize_nets() -> Dictionary:
	var result := {}
	for name in nets:
		result[name] = nets[name].to_dict()
	return result


## Serialize traces for undo
func _serialize_traces() -> Dictionary:
	var result := {}
	for id in traces:
		result[id] = traces[id].to_dict()
	return result


## Restore state from history
func _restore_state(state: Dictionary) -> void:
	# Restore components
	components.clear()
	var comp_data: Dictionary = state.get("components", {})
	for id in comp_data:
		var component = PCBComponentScript.from_dict(comp_data[id])
		components[id] = component

	# Restore nets
	nets.clear()
	var net_data: Dictionary = state.get("nets", {})
	for name in net_data:
		var net = PCBNetScript.from_dict(net_data[name])
		nets[name] = net

	# Restore traces
	traces.clear()
	var trace_data: Dictionary = state.get("traces", {})
	for id in trace_data:
		var trace = PCBTraceScript.from_dict(trace_data[id])
		traces[id] = trace
		# ID COUNTER INVARIANT (see the statement near _next_trace_id): this path
		# writes traces[id] directly, bypassing add_trace, so it must reserve
		# here or a later id-less mint could reproduce a restored id and
		# overwrite it. Mirrors load_from_dict's identical fix. The via twin of
		# this is already covered — _load_vias below high-waters _next_via_id.
		reserve_trace_id(str(id))

	# Restore vias + mounting holes (F1 — see save_to_history). Reuse the shared
	# loaders so Vector2/dict positions normalize the same way as file load.
	# _load_vias already high-waters _next_via_id (T2.3) — do not duplicate that
	# here.
	_load_vias(state.get("vias", []))
	_load_mounting_holes(state.get("mounting_holes", []))
	zones = _zones_from_list(state.get("zones", []))
	cutouts = _cutouts_from_list(state.get("cutouts", []))
	# Layer stack (epoch GA-1): ABSENT key == leave the stack alone (the
	# workspace/staged absent-key rule), so only snapshots taken since the
	# stack became a mutable bucket ever rewrite it.
	if state.has("layers"):
		var restored_layers: Array[String] = []
		for entry in state["layers"]:
			restored_layers.append(str(entry))
		layers = restored_layers
	# Declared stage (DCR 01a0033a12a9 change 3): same ABSENT-key rule as the
	# stack above, and the same normalisation from_board_dict applies — a
	# snapshot carrying a token this build does not know rewinds to "routed"
	# rather than restoring a declaration nothing can honour.
	if state.has("fabrication_stage"):
		var restored_stage := str(state["fabrication_stage"])
		fabrication_stage = restored_stage if restored_stage in FAB_STAGES \
			else FAB_STAGE_ROUTED

	# BUCKET 8 — restore the workspace disposition layer LAST, after the board is
	# whole, so a delegate that reads the board while restoring sees the state
	# this snapshot describes rather than a half-applied one.
	_restore_workspace_snapshot(state)
	# BUCKET 9 — same last-after-board rule (Epoch UX4).
	_restore_staged_snapshot(state)

	# Batch state belongs to the CALLER's in-flight transaction, not to
	# whichever board snapshot happens to be restored. Without this, undoing
	# mid-batch leaves _batch_active set from a batch this restored state never
	# saw, and the next end_batch() would snapshot a state the batch never
	# produced.
	_batch_active = false
	_batch_touched = false

#endregion


#region Change Journal

## Record a change to the journal
func record_change(action: String, details: Dictionary) -> void:
	# record_change is the ONE hook every forward mutator funnels through
	# (add/remove/move/rotate component, net connect/disconnect/add/remove, trace
	# add/remove/clear, via add/remove, resize). Bumping the board revision here
	# gives every forward state change exactly one bump in a single place. undo/
	# redo do NOT call record_change, so they bump explicitly (see undo/redo).
	_bump_board_revision()

	var entry := {
		"timestamp": Time.get_unix_time_from_system(),
		"action": action,
		"details": details
	}
	change_journal.append(entry)

	# Enforce max size — drop oldest entries
	while change_journal.size() > MAX_JOURNAL_SIZE:
		change_journal.remove_at(0)

	journal_entry_added.emit(entry)


## Get journal entries, optionally filtered by timestamp
func get_change_journal(since_timestamp: float = 0.0) -> Array[Dictionary]:
	if since_timestamp <= 0.0:
		return change_journal.duplicate()

	var result: Array[Dictionary] = []
	for entry in change_journal:
		if entry.get("timestamp", 0.0) >= since_timestamp:
			result.append(entry)
	return result


## Clear all journal entries
func clear_change_journal() -> void:
	change_journal.clear()

#endregion


#region Serialization (legacy .minpcb shape)

## Serialize the entire PCB data (legacy .minpcb shape, minus annotations/
## route_hints — those live in the platform annotation substrate now).
func to_dict() -> Dictionary:
	var comp_dict := {}
	for id in components:
		comp_dict[id] = components[id].to_dict()

	var net_dict := {}
	for name in nets:
		net_dict[name] = nets[name].to_dict()

	var trace_dict := {}
	for id in traces:
		trace_dict[id] = traces[id].to_dict()

	# Serialize vias (convert Vector2 positions to Dictionary for JSON safety)
	var vias_arr: Array = []
	for via in vias:
		var via_copy = via.duplicate()
		if via_copy.has("position") and via_copy["position"] is Vector2:
			var p: Vector2 = via_copy["position"]
			via_copy["position"] = {"x": p.x, "y": p.y}
		vias_arr.append(via_copy)

	# Serialize mounting holes (mirror vias — Vector2 → Dictionary for JSON safety)
	var holes_arr: Array = []
	for hole in mounting_holes:
		var hole_copy = hole.duplicate()
		if hole_copy.has("position") and hole_copy["position"] is Vector2:
			var hp: Vector2 = hole_copy["position"]
			hole_copy["position"] = {"x": hp.x, "y": hp.y}
		holes_arr.append(hole_copy)

	return {
		"version": 1,
		"board_name": board_name,
		"board_width": board_width,
		"board_height": board_height,
		"grid_size": grid_size,
		"layers": layers.duplicate(),
		"components": comp_dict,
		"nets": net_dict,
		"traces": trace_dict,
		"vias": vias_arr,
		"mounting_holes": holes_arr,
		# Zones are already JSON-safe (canonical dicts of floats/strings, no
		# Vector2), so unlike vias / mounting_holes above they need no position
		# rewrite on the way out — just a deep copy.
		"zones": _zones_to_list()
	}


## Deserialize PCB data (legacy .minpcb shape). Annotation/route_hint keys are
## ignored here — the platform annotation substrate (PcbAnnotationHost) owns them.
func load_from_dict(data: Dictionary) -> void:
	board_name = data.get("board_name", "Untitled")
	board_width = data.get("board_width", 100.0)
	board_height = data.get("board_height", 100.0)
	grid_size = data.get("grid_size", 2.54)

	layers.clear()
	var layers_arr: Array = data.get("layers", ["top", "bottom"])
	for layer in layers_arr:
		layers.append(str(layer))

	# Load components
	components.clear()
	var comp_data: Dictionary = data.get("components", {})
	for id in comp_data:
		var component = PCBComponentScript.from_dict(comp_data[id])
		components[id] = component

	# Load nets
	nets.clear()
	var net_data: Dictionary = data.get("nets", {})
	for name in net_data:
		var net = PCBNetScript.from_dict(net_data[name])
		nets[name] = net

	# Load traces
	traces.clear()
	var trace_data: Dictionary = data.get("traces", {})
	for id in trace_data:
		var trace = PCBTraceScript.from_dict(trace_data[id])
		traces[id] = trace
		# High-water the trace-id counter, exactly as _load_vias already does for
		# vias. This path writes traces[id] directly instead of going through
		# add_trace, so without this _next_trace_id stays at 1 and the very FIRST
		# trace drawn after loading a board whose first trace is "trace_1" mints
		# that same id and OVERWRITES the loaded trace.
		reserve_trace_id(str(id))

	# Load vias
	_load_vias(data.get("vias", []))

	# Load mounting holes (mirror vias so undo snapshots don't drop them)
	_load_mounting_holes(data.get("mounting_holes", []))

	# Load zones (carried verbatim — see the `zones` declaration)
	zones = _zones_from_list(data.get("zones", []))

	# Save baseline snapshot so the first action can be undone
	history.clear()
	history_index = -1
	save_to_history("Load")

	structure_changed.emit()
	data_changed.emit()


## Shared via loader (legacy + canonical shapes both store vias with Vector2
## positions internally).
func _load_vias(vias_data: Array) -> void:
	vias.clear()
	for via_data in vias_data:
		if via_data is Dictionary:
			var via_entry: Dictionary = via_data.duplicate()
			if via_data.has("position"):
				var pos = via_data["position"]
				if pos is Vector2:
					via_entry["position"] = pos
				elif pos is Dictionary:
					via_entry["position"] = Vector2(
						pos.get("x", 0), pos.get("y", 0))
				elif pos is String:
					# Handle "(x, y)" from JSON round-trip of Vector2
					var s: String = str(pos).replace("(", "").replace(")", "").strip_edges()
					var parts: PackedStringArray = s.split(",")
					if parts.size() >= 2:
						via_entry["position"] = Vector2(
							float(parts[0].strip_edges()),
							float(parts[1].strip_edges()))
					else:
						via_entry["position"] = Vector2.ZERO
			# High-water the via id counter so a later add_via() mint can never
			# collide with a loaded via's id (T2.3 stable-id contract).
			var vid := str(via_entry.get("id", ""))
			if not vid.is_empty():
				_next_via_id = maxi(_next_via_id, _stable_id_suffix(vid) + 1)
			vias.append(via_entry)


## Shared mounting-hole loader (legacy + canonical shapes both store mounting
## holes with Vector2 positions internally). Mirrors _load_vias.
func _load_mounting_holes(holes_data: Array) -> void:
	mounting_holes.clear()
	for hole_data in holes_data:
		if hole_data is Dictionary:
			var hole_entry: Dictionary = hole_data.duplicate()
			if hole_data.has("position"):
				var pos = hole_data["position"]
				if pos is Vector2:
					hole_entry["position"] = pos
				elif pos is Dictionary:
					hole_entry["position"] = Vector2(
						pos.get("x", 0), pos.get("y", 0))
				elif pos is String:
					# Handle "(x, y)" from JSON round-trip of Vector2
					var s: String = str(pos).replace("(", "").replace(")", "").strip_edges()
					var parts: PackedStringArray = s.split(",")
					if parts.size() >= 2:
						hole_entry["position"] = Vector2(
							float(parts[0].strip_edges()),
							float(parts[1].strip_edges()))
					else:
						hole_entry["position"] = Vector2.ZERO
			mounting_holes.append(hole_entry)


## Export to CSV format (component placement list)
func to_csv() -> String:
	var lines: PackedStringArray = ["id,footprint,x,y,rotation,layer,value"]

	for id in components:
		var comp = components[id]
		var value: String = comp.properties.get("value", "")
		lines.append("%s,%s,%.2f,%.2f,%.0f,%s,%s" % [
			comp.id,
			comp.get_canonical_footprint_name(),
			comp.position.x,
			comp.position.y,
			comp.rotation,
			comp.layer,
			value
		])

	return "\n".join(lines)


## Describe only the NAMES of identity-bound extras an import must discard.
## Values may contain vendor or sourcing data and are not needed to make the
## loss actionable at the tool boundary.
func _csv_extra_drop_report(component, identity_fields: Array) -> Dictionary:
	var canonical_keys: Array = component.canonical_extra.keys()
	canonical_keys.sort()
	var pin_keys := {}
	var pin_numbers: Array = component.pin_extra.keys()
	pin_numbers.sort()
	for pin_number in pin_numbers:
		var extra = component.pin_extra[pin_number]
		var keys: Array = extra.keys() if extra is Dictionary else []
		keys.sort()
		pin_keys[str(pin_number)] = keys
	return {
		"ref": component.id,
		"identity_fields": identity_fields,
		"canonical_extra_keys": canonical_keys,
		"pin_extra_keys": pin_keys,
	}


## Import from CSV format. Existing rows are merged onto a deep copy when the
## footprint identity is unchanged, because CSV owns placement fields—not pin,
## pad, or render geometry. The return value lets callers surface any deliberate
## identity-extra loss; legacy callers may safely ignore it.
func from_csv(csv_text: String) -> Dictionary:
	## Component refs whose canonical extras were dropped because the CSV row
	## changed the part's identity — surfaced on the journal record so the
	## loss is visible rather than silent (Codex review 1090 finding 2).
	var dropped_extras: Array = []
	var lines := csv_text.split("\n")
	if lines.size() < 2:
		return {"imported_count": 0, "dropped_identity_extras": dropped_extras}

	# Parse header
	var header := lines[0].split(",")
	var id_idx := header.find("id")
	var footprint_idx := header.find("footprint")
	var x_idx := header.find("x")
	var y_idx := header.find("y")
	var rot_idx := header.find("rotation")
	var layer_idx := header.find("layer")
	var value_idx := header.find("value")

	if id_idx < 0 or x_idx < 0 or y_idx < 0:
		push_error("[PCBData] Invalid CSV format: missing required columns")
		return {"imported_count": 0, "dropped_identity_extras": dropped_extras}

	# Parse data rows
	var imported := 0
	for i in range(1, lines.size()):
		var line := lines[i].strip_edges()
		if line.is_empty():
			continue

		var fields := line.split(",")
		if fields.size() <= id_idx:
			continue

		var component_id: String = fields[id_idx].strip_edges()
		var prior = components.get(component_id, null)
		var has_authored_fp: bool = footprint_idx >= 0 and fields.size() > footprint_idx
		var authored_fp: String = fields[footprint_idx].strip_edges() \
				if has_authored_fp else ""
		var has_authored_value: bool = value_idx >= 0 and fields.size() > value_idx
		var authored_value: String = str(fields[value_idx]) if has_authored_value else ""
		var footprint_changed: bool = prior != null and has_authored_fp \
				and authored_fp != prior.get_canonical_footprint_name()
		var value_changed: bool = prior != null and has_authored_value \
				and authored_value != str(prior.properties.get("value", ""))

		# Preserve the full component—not just its extra dictionaries—while the
		# footprint is unchanged. setup_standard_pins() cannot reconstruct custom
		# library pin sets, pads, graphics, or imported bounds.
		var component = prior.duplicate_component() \
				if prior != null and not footprint_changed else PCBComponentScript.new()
		component.id = component_id

		if prior == null or footprint_changed:
			if has_authored_fp:
				component.set_footprint_by_name(authored_fp)
				# PRESERVE THE LIBRARY REF, mirroring load_from_board_dict's
				# read-side rule. Unknown names map to the CUSTOM render bucket,
				# so the authored string needs its own field.
				if component.footprint == component.FootprintType.CUSTOM \
						and authored_fp != "" and authored_fp != "CUSTOM":
					component.footprint_id = authored_fp
			component.setup_standard_pins()

		if x_idx >= 0 and fields.size() > x_idx:
			component.position.x = fields[x_idx].to_float()
		if y_idx >= 0 and fields.size() > y_idx:
			component.position.y = fields[y_idx].to_float()
		if rot_idx >= 0 and fields.size() > rot_idx:
			component.rotation = fields[rot_idx].to_float()
		if layer_idx >= 0 and fields.size() > layer_idx:
			component.layer = fields[layer_idx]
		if has_authored_value:
			component.properties["value"] = authored_value

		# CSV IMPORT OVERWRITES BY ID, so a component the board already had
		# loses anything outside the CSV's columns — including the canonical
		# passthrough (`assembly: exclude`, `mpn`, pin drill/annulus
		# overrides). Carrying it across the overwrite is right ONLY while the
		# row describes the SAME PART.
		#
		# The first version of this carried it unconditionally, on the claim
		# that a placement CSV cannot contradict those fields. That was wrong
		# on its own terms (Codex review 1090 finding 2): this CSV carries
		# FOOTPRINT and VALUE, both identity. Importing a row that changes R1
		# from 10k to 1k would have kept the 10k `mpn`, and promotion would
		# emit a BOM naming the wrong orderable part — or keep `assembly:
		# exclude` on a part that is now assembly-worthy. Pin overrides could
		# likewise migrate onto a different footprint's same-numbered pin.
		#
		# So: identity UNCHANGED -> preserve. Identity CHANGED -> the old
		# extras describe a part that is no longer here, so they are dropped —
		# and REPORTED, never silently, because a silent drop is the failure
		# this whole sweep exists to close. Refusing the entire import was
		# considered and rejected as disproportionate: one edited value should
		# not reject a bulk placement import.
		if prior != null:
			var identity_changed: bool = footprint_changed or value_changed
			var had_extras: bool = not prior.canonical_extra.is_empty() \
					or not prior.pin_extra.is_empty()
			if identity_changed:
				if had_extras:
					var changed_fields: Array = []
					if footprint_changed:
						changed_fields.append("footprint")
					if value_changed:
						changed_fields.append("value")
					dropped_extras.append(
							_csv_extra_drop_report(prior, changed_fields))
				component.canonical_extra.clear()
				component.pin_extra.clear()
		components[component.id] = component
		imported += 1

	# from_csv is a forward in-place MERGE (appends/overwrites components on the
	# CURRENT board — it does NOT clear or reset history), so it is a delta and
	# MUST advance board_revision. Funnel one summary record through record_change
	# (bumps once + journals + respects an active batch). A header-only CSV that
	# imported nothing is a no-op and is left unbumped.
	if imported > 0:
		var record := {"count": imported}
		if not dropped_extras.is_empty():
			record["dropped_identity_extras"] = dropped_extras
		record_change("import_csv", record)
	structure_changed.emit()
	data_changed.emit()
	return {"imported_count": imported, "dropped_identity_extras": dropped_extras}

#endregion


#region Canonical boundary (pcb/internal/board Board)

## Serialize the whole board to a canonical board-contract dict — the payload
## pcb.serialize expects, and what from_board_dict() round-trips. Components,
## nets and traces are deterministically sorted (matching minpcb.go). Annotations
## / route_hints are deliberately NOT emitted here (owned by PcbAnnotationHost).
func to_board_dict() -> Dictionary:
	var comp_keys := components.keys()
	comp_keys.sort()
	var comp_list: Array = []
	for id in comp_keys:
		comp_list.append(components[id].to_board_dict())

	var net_keys := nets.keys()
	net_keys.sort()
	var net_list: Array = []
	for name in net_keys:
		net_list.append(nets[name].to_board_dict())

	var trace_keys := traces.keys()
	trace_keys.sort()
	var trace_list: Array = []
	for id in trace_keys:
		trace_list.append(traces[id].to_board_dict())

	var via_list: Array = []
	for via in vias:
		via_list.append(_via_to_board_dict(via))

	var hole_list: Array = []
	for hole in mounting_holes:
		hole_list.append(_mounting_hole_to_board_dict(hole))

	var out := {
		"version": 1,
		"name": board_name,
		"width_mm": board_width,
		"height_mm": board_height,
		"grid_mm": grid_size,
		"layers": layers.duplicate(),
		"design_rules": design_rules.duplicate(),
		"components": comp_list,
		"nets": net_list,
		"traces": trace_list,
		"vias": via_list,
		"mounting_holes": hole_list
	}
	# Emitted ONLY when the board actually carries a lock, the same rule zones
	# follow below, so an unlocked board's canonical dict — and the YAML written
	# from it — is byte-identical to before this field existed.
	if not library_lock.is_empty():
		out["library_lock"] = library_lock.duplicate(true)
	# Emitted ONLY when the board actually has zones, so a zone-free board's
	# canonical dict — and therefore the YAML pcb.serialize writes from it — is
	# byte-identical to what it was before zones existed. Go's Zone slice is
	# `omitempty`, so an empty list would round-trip away anyway; not emitting it
	# keeps that from being a thing anyone has to know.
	if not zones.is_empty():
		out["zones"] = _zones_to_list()
	# Same conditional-emit idiom as zones, same reason: a cutout-free board's
	# canonical dict must stay byte-identical to what it was before cutouts
	# existed (T6 — this is the fixed-literal silent-drop point; `out` above is
	# a literal dict, so a field not written here would round-trip away on
	# every save even though `cutouts` itself is held verbatim). Go's Cutout
	# slice is `omitempty` too.
	if not cutouts.is_empty():
		out["cutouts"] = _cutouts_to_list()
	# Same conditional-emit idiom, same reason: a board that declares no
	# fabrication stage must serialize byte-identically to before the field
	# existed. Go's FabricationStage is `omitempty`, and drc.fabrication_stage
	# reads an absent value as "routed", so the default board is unchanged
	# end-to-end (DCR 01a0033a12a9 change 3).
	if not fabrication_stage.is_empty() and fabrication_stage != FAB_STAGE_ROUTED:
		out["fabrication_stage"] = fabrication_stage
	return out


## Restore board state from a canonical board-contract dict.
##
## TOLERATES "annotations" / "route_hints" keys by IGNORING them: the Go importer
## passes those through opaquely, but this model does not own annotation state —
## the platform annotation substrate (PcbAnnotationHost, a panel sibling) does.
func from_board_dict(data: Dictionary) -> void:
	board_name = str(data.get("name", "Untitled"))
	board_width = float(data.get("width_mm", 100.0))
	board_height = float(data.get("height_mm", 100.0))
	grid_size = float(data.get("grid_mm", 2.54))

	layers.clear()
	var layers_arr: Array = data.get("layers", ["top", "bottom"])
	for layer in layers_arr:
		layers.append(str(layer))

	design_rules = (data.get("design_rules", {}) as Dictionary).duplicate()

	# An unknown token is normalised to "routed" rather than carried. The Go
	# write gate (internal/board/validate.go validateFabricationStage) refuses
	# one, so a board that got here with a bad value did not come through that
	# gate — and the conservative reading is the one where an unrouted net stays
	# a DEFECT. Carrying it would let a typo silently excuse a half-routed board.
	var loaded_stage := str(data.get("fabrication_stage", ""))
	fabrication_stage = loaded_stage if loaded_stage in FAB_STAGES else FAB_STAGE_ROUTED

	# THE BOARD'S LIBRARY LOCK (K20, DCR 019ffc52c358) is carried through this
	# model rather than interpreted by it. The panel is not the authority on
	# what a board consumed — the compiler is — so this model's whole job is to
	# not lose it.
	#
	# TWO LIMITS ON "carried", stated because the first draft of this comment
	# overclaimed and prose is the one artifact with no gate:
	#   * a block that is not a Dictionary is replaced with {}, not preserved —
	#     the model cannot hand a malformed value to consumers that index it;
	#   * unrecognised fields inside an ENTRY survive this hop, but not a Go
	#     codec round trip: internal/board's LibraryLockEntry is typed, so it
	#     keeps sha256/layer/source and drops anything else. The durable
	#     guarantee is those three fields, not arbitrary extension.
	#
	# WHY THIS LINE EXISTS AT ALL: to_board_dict rebuilds the canonical dict
	# from typed fields rather than editing the loaded one, so any top-level key
	# this model does not explicitly carry is DESTROYED the first time a user
	# opens a locked board and saves it. Silent, total, and indistinguishable
	# from the board never having been locked.
	library_lock = (data.get("library_lock", {}) as Dictionary).duplicate(true) \
		if data.get("library_lock", null) is Dictionary else {}

	# Components (canonical list → id→object map)
	components.clear()
	var comp_list: Array = data.get("components", [])
	for cd in comp_list:
		if cd is Dictionary:
			var component = PCBComponentScript.from_board_dict(cd)
			components[component.id] = component

	# Nets (canonical list → name→object map)
	nets.clear()
	var net_list: Array = data.get("nets", [])
	for nd in net_list:
		if nd is Dictionary:
			var net = PCBNetScript.from_board_dict(nd)
			nets[net.name] = net

	# Traces (canonical list → id→object map)
	traces.clear()
	var trace_list: Array = data.get("traces", [])
	for td in trace_list:
		if td is Dictionary:
			var trace = PCBTraceScript.from_board_dict(td)
			if trace.id.is_empty():
				trace.id = "trace_%d" % _next_trace_id
				_next_trace_id += 1
			else:
				# Same high-water contract _load_vias applies to via ids. This
				# path writes traces[trace.id] directly rather than through
				# add_trace, so a supplied id must reserve itself here or the
				# FIRST subsequent auto-mint can reproduce it and overwrite this
				# trace (traces is keyed by id).
				reserve_trace_id(trace.id)
			traces[trace.id] = trace

	# Vias (canonical list → internal via dicts)
	_load_vias(_vias_from_board_list(data.get("vias", [])))

	# Mounting holes (canonical list → internal mounting-hole dicts)
	_load_mounting_holes(_mounting_holes_from_board_list(data.get("mounting_holes", [])))

	# Zones (carried verbatim — see the `zones` declaration).
	zones = _zones_from_list(data.get("zones", []))

	# Cutouts (carried verbatim — see the `cutouts` declaration). This is the
	# fix for the T6 silent-drop: a cutouts key authored in YAML and loaded here
	# must survive the round-trip, not be erased by a fixed-key from_board_dict.
	cutouts = _cutouts_from_list(data.get("cutouts", []))

	# annotations / route_hints: intentionally ignored — see method doc.

	# Save baseline snapshot so the first action can be undone.
	history.clear()
	history_index = -1
	save_to_history("Load")

	structure_changed.emit()
	data_changed.emit()


## Map a KiCad-named copper layer ("F.Cu"/"B.Cu") to the canonical top/bottom
## span name used by the via from_layer/to_layer fields; already-canonical
## values (and anything else) pass through lower-cased. This is the GDScript
## side of the ONE canonical convention documented in
## pcb/worker/pcb_worker/route_bridge.py (_LAYER_MAP = {"top":"F.Cu",
## "bottom":"B.Cu"}, _canon_layer) — mirrored here (not imported: this is
## GDScript, that is Python) rather than re-invented.
func _canon_layer_name(v) -> String:
	# T1.5: delegates to the ONE canonical GD contract; edge-case behaviour
	# (empty -> "top", F.Cu/B.Cu -> top/bottom, else lower-cased passthrough)
	# is preserved there. _via_to_board_dict's legacy "layers" consumption is
	# unchanged and still routes through here.
	return PcbLayerStack.kicad_to_canon(v)


## Map one internal via dict → canonical via dict. from_layer/to_layer are
## first-class canonical (top/bottom) fields on the copper span a via bridges.
## Preference order: an already-canonical from_layer/to_layer pair on the
## internal via (round-trip fidelity) > a legacy "layers" Extra passthrough
## (KiCad-named, e.g. ["F.Cu","B.Cu"] — what panel_tools._materialize_routes /
## import_trace_geometry currently store) mapped via _canon_layer_name > the
## only span a 2-layer board has, top<->bottom. The legacy "layers" key is
## consumed (mapped to from_layer/to_layer), NOT re-emitted, so a via never
## carries both a "layers" array and first-class from_layer/to_layer at once.
## Any OTHER extra keys still ride as canonical Extra siblings (mirrors
## minpcb.go importVias).
func _via_to_board_dict(via: Dictionary) -> Dictionary:
	var d := {}
	var pos = via.get("position", Vector2.ZERO)
	if pos is Vector2:
		d["x_mm"] = pos.x
		d["y_mm"] = pos.y
	elif pos is Dictionary:
		d["x_mm"] = float(pos.get("x", 0.0))
		d["y_mm"] = float(pos.get("y", 0.0))
	d["drill_mm"] = float(via.get("drill", 0.0))
	d["diameter_mm"] = float(via.get("size", 0.0))
	d["net"] = str(via.get("net_name", ""))

	var from_layer: String = str(via.get("from_layer", ""))
	var to_layer: String = str(via.get("to_layer", ""))
	if from_layer.is_empty() or to_layer.is_empty():
		var legacy_layers = via.get("layers")
		if legacy_layers is Array and legacy_layers.size() >= 2:
			from_layer = _canon_layer_name(legacy_layers[0])
			to_layer = _canon_layer_name(legacy_layers[1])
		else:
			from_layer = "top"
			to_layer = "bottom"
	d["from_layer"] = from_layer
	d["to_layer"] = to_layer

	for k in via:
		if k in ["position", "drill", "size", "net_name", "layers", "from_layer", "to_layer"]:
			continue
		d[k] = via[k]
	return d


## Map a canonical via list back to internal via dicts ({position,size,drill,
## net_name,from_layer,to_layer,+extra}). Fed to _load_vias which normalises
## the position to Vector2. Tolerates legacy canonical vias with no
## from_layer/to_layer (defaults to a full top<->bottom span) or with a
## legacy "layers" KiCad-named array instead (mapped via _canon_layer_name).
## The legacy "layers" key, if present, is consumed here and not carried into
## the internal entry — from_layer/to_layer is the one internal representation
## going forward, so a later _via_to_board_dict call round-trips it exactly.
func _vias_from_board_list(via_list: Array) -> Array:
	var result: Array = []
	for vd in via_list:
		if not vd is Dictionary:
			continue
		var entry := {
			"position": {"x": float(vd.get("x_mm", 0.0)), "y": float(vd.get("y_mm", 0.0))},
			"drill": float(vd.get("drill_mm", 0.0)),
			"size": float(vd.get("diameter_mm", 0.0)),
			"net_name": str(vd.get("net", ""))
		}
		var from_layer: String = str(vd.get("from_layer", ""))
		var to_layer: String = str(vd.get("to_layer", ""))
		if from_layer.is_empty() or to_layer.is_empty():
			var legacy_layers = vd.get("layers")
			if legacy_layers is Array and legacy_layers.size() >= 2:
				from_layer = _canon_layer_name(legacy_layers[0])
				to_layer = _canon_layer_name(legacy_layers[1])
			else:
				from_layer = "top"
				to_layer = "bottom"
		entry["from_layer"] = from_layer
		entry["to_layer"] = to_layer

		for k in vd:
			if k in ["x_mm", "y_mm", "drill_mm", "diameter_mm", "net", "from_layer", "to_layer", "layers"]:
				continue
			entry[k] = vd[k]
		result.append(entry)
	return result


## Map one internal mounting-hole dict → canonical mounting-hole dict. Any keys
## beyond the mapped set ride as canonical Extra siblings. Mirrors
## _via_to_board_dict.
func _mounting_hole_to_board_dict(hole: Dictionary) -> Dictionary:
	var d := {}
	var pos = hole.get("position", Vector2.ZERO)
	if pos is Vector2:
		d["x_mm"] = pos.x
		d["y_mm"] = pos.y
	elif pos is Dictionary:
		d["x_mm"] = float(pos.get("x", 0.0))
		d["y_mm"] = float(pos.get("y", 0.0))
	d["diameter_mm"] = float(hole.get("diameter", 0.0))
	d["plated"] = bool(hole.get("plated", false))
	for k in hole:
		if k in ["position", "diameter", "plated"]:
			continue
		d[k] = hole[k]
	return d


## Deep-copy the zone list on the way OUT, so a consumer that mutates the dict
## it was handed (a serializer normalising numbers, a tool building a payload)
## cannot reach back into this model's state. Mirrors the `.duplicate(true)`
## discipline save_to_history already applies to vias / mounting_holes.
##
## ZONE_FILL_KEY IS STRIPPED. See its declaration: this projection is the board
## as authored, and the fill is not authored.
func _zones_to_list() -> Array:
	var result: Array = []
	for zone in zones:
		var out: Dictionary = zone.duplicate(true)
		out.erase(ZONE_FILL_KEY)
		result.append(out)
	return result


## Deep-copy a canonical or snapshot zone list on the way IN. Non-dict entries are
## dropped rather than tolerated: every other loader here does the same
## (_vias_from_board_list, the component/net/trace loops), and a zone that is not
## a mapping has no outline to draw.
##
## ZONE_FILL_KEY IS STRIPPED here too, so adopt_zone_fill stays the only writer.
## See its declaration.
func _zones_from_list(zone_list) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not (zone_list is Array):
		return result
	for zd in zone_list:
		if zd is Dictionary:
			var entry: Dictionary = (zd as Dictionary).duplicate(true)
			entry.erase(ZONE_FILL_KEY)
			result.append(entry)
	return result


## The key a pour's COMPILED FILL rides on inside `zones` — the key
## pcb_ratsnest reads to decide what a plane actually conducts.
##
## DERIVED STATE, HELD ONLY IN MEMORY. Everything else in `zones` is the board
## as authored; this is a compile output about that board, and it is true only
## of the exact board it was computed from. So it enters through adopt_zone_fill
## and nothing else, and every projection out of this model strips it:
##
##   * to_board_dict — so it is never saved into the board source, never sent
##     back to the compiler, and never fingerprinted as if the board had moved;
##   * the history snapshot — so undo/redo restores a board without a fill
##     rather than a board wearing the fill of a different board;
##   * _zones_from_list — so a fill riding in a loaded document or a hand-edited
##     source can never be mistaken for one this session computed.
##
## Dropping it always costs the same thing and never more: a pour with no fill
## contributes no connection, so joins the plane really does serve are reported
## as still owed until a fresh fill arrives. The opposite mistake — a fill kept
## past the board it describes — reports a pad as already served when it is not,
## and that one reaches fabrication.
const ZONE_FILL_KEY := "fill"


## Adopt compiled pour fills onto the zones they belong to, matched by zone id.
##
## `entries` is the `zones` array of a zone-fill reply: [{id, fill}, ...], one
## entry per pour whose fill was computed, each `fill` an Array of regions.
## Returns how many zones took one.
##
## EVERY ZONE'S FILL IS REPLACED, adopted or not: a zone the reply does not
## mention had no fill computed for it, and the previous fill described a board
## that is no longer this one. Merging would leave exactly the stale answer
## ZONE_FILL_KEY's declaration refuses.
##
## An entry naming no zone id, or a zone id no zone on this board carries, is
## skipped — it describes a zone this model cannot identify, and guessing which
## one it meant would attach copper to the wrong plane. A `fill` that is not an
## Array is not adopted either; the ring-level reading of what IS adopted
## belongs to the consumer, which already refuses fill data it cannot use.
##
## Adoption is silent: no signal, no journal entry, no revision bump. The board
## did not change — only what is known about the copper it already describes.
func adopt_zone_fill(entries) -> int:
	clear_zone_fill()
	if not (entries is Array):
		return 0
	var by_id: Dictionary = {}
	for zone in zones:
		var zid := str(zone.get("id", ""))
		if not zid.is_empty():
			by_id[zid] = zone
	var adopted := 0
	for entry in (entries as Array):
		if not (entry is Dictionary):
			continue
		var zid := str((entry as Dictionary).get("id", ""))
		if not by_id.has(zid):
			continue
		var fill = (entry as Dictionary).get(ZONE_FILL_KEY)
		if not (fill is Array):
			continue
		(by_id[zid] as Dictionary)[ZONE_FILL_KEY] = (fill as Array).duplicate(true)
		adopted += 1
	return adopted


## Drop every adopted fill. The pours keep their outlines and contribute no
## connection until a fresh fill is adopted — see ZONE_FILL_KEY's declaration
## for why that is the direction to fail in.
func clear_zone_fill() -> void:
	for zone in zones:
		zone.erase(ZONE_FILL_KEY)


## Deep-copy the cutout list on the way OUT. Mirrors _zones_to_list, same
## reasoning: a consumer of to_board_dict() must not be able to reach back into
## this model's state through the dict it was handed.
func _cutouts_to_list() -> Array:
	var result: Array = []
	for cutout in cutouts:
		result.append(cutout.duplicate(true))
	return result


## Deep-copy a canonical or snapshot cutout list on the way IN. Mirrors
## _zones_from_list, including dropping non-dict entries rather than
## tolerating them.
func _cutouts_from_list(cutout_list) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not (cutout_list is Array):
		return result
	for cd in cutout_list:
		if cd is Dictionary:
			result.append((cd as Dictionary).duplicate(true))
	return result


## A zone's kind, normalised: "keepout" or "copper_pour".
##
## Defaults to "copper_pour" for a zone that states no kind, matching the Go
## contract exactly: internal/board's Zone.Kind is `omitempty` and its validator
## treats "" as ZoneKindCopperPour, so absence is a default, not a third kind.
## Defaulting the other way would silently promote an under-specified pour into a
## warning region on the canvas — and now that a keepout may be netless, into one
## the net requirement no longer guards.
##
## Case/whitespace ARE folded here and are NOT folded in Go (which rejects
## "Keepout" as invalid_zone_kind). Deliberate: this is a render-time read that
## should never crash on sloppy input, while Go is the write gate that tells the
## author about the typo.
static func zone_kind(zone: Dictionary) -> String:
	var kind := str(zone.get("kind", "")).strip_edges().to_lower()
	return kind if not kind.is_empty() else "copper_pour"


## A zone's authored outline as board-mm points. Empty (< 3 points) for a zone
## whose outline is missing or malformed; the Go validator already rejects a
## sub-triangle outline at the deserialize boundary, so this is belt-and-braces
## for zones that arrive from a snapshot rather than from a load.
static func zone_outline_points(zone: Dictionary) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var outline = zone.get("outline", [])
	if not (outline is Array):
		return pts
	for p in outline:
		if p is Dictionary:
			pts.append(Vector2(float(p.get("x_mm", 0.0)), float(p.get("y_mm", 0.0))))
	return pts


## Map a canonical mounting-hole list back to internal mounting-hole dicts
## ({position,diameter,plated,+extra}). Fed to _load_mounting_holes which
## normalises the position to Vector2. Mirrors _vias_from_board_list.
func _mounting_holes_from_board_list(hole_list: Array) -> Array:
	var result: Array = []
	for hd in hole_list:
		if not hd is Dictionary:
			continue
		var entry := {
			"position": {"x": float(hd.get("x_mm", 0.0)), "y": float(hd.get("y_mm", 0.0))},
			"diameter": float(hd.get("diameter_mm", 0.0)),
			"plated": bool(hd.get("plated", false))
		}
		for k in hd:
			if k in ["x_mm", "y_mm", "diameter_mm", "plated"]:
				continue
			entry[k] = hd[k]
		result.append(entry)
	return result

#endregion


#region Utility Methods

## Clear all data.
##
## Does NOT reset _next_trace_id / _next_via_id — see the ID COUNTER INVARIANT
## near _next_trace_id. (This used to reset _next_trace_id only, leaving the
## two counters governed by different rules on the same method; that asymmetry
## is itself what the invariant closes off.)
func clear() -> void:
	components.clear()
	nets.clear()
	traces.clear()
	vias.clear()
	mounting_holes.clear()
	zones.clear()
	cutouts.clear()
	history.clear()
	history_index = -1
	change_journal.clear()
	structure_changed.emit()
	data_changed.emit()


## Get the total component count
func get_component_count() -> int:
	return components.size()


## Get the total net count
func get_net_count() -> int:
	return nets.size()


## Get the total trace count
func get_trace_count() -> int:
	return traces.size()


## True when the marquee `region` touches the polyline `points` — any vertex
## inside the rect, or any segment crossing a rect edge.
##
## The ONE region/path predicate, shared by get_traces_in_region and
## get_zones_in_region so a trace and a zone outline cannot disagree about what
## "the box touched it" means. Pass a CLOSED point list (first point repeated) to
## test a polygon's outline; the caller closes it, because a trace is genuinely
## open and a zone outline genuinely is not.
##
## A fully-enclosing region is caught by the vertex test; a region entirely
## INSIDE a closed outline is deliberately NOT a hit here (see
## get_zones_in_region, which adds that case only for keepouts).
static func region_touches_polyline(points, region: Rect2) -> bool:
	return PcbTraceGeometry.polyline_touches_rect(PackedVector2Array(points), region)


## Snap a position to the grid
func snap_to_grid(position: Vector2) -> Vector2:
	return Vector2(
		roundf(position.x / grid_size) * grid_size,
		roundf(position.y / grid_size) * grid_size
	)


## Fraction of the PLACEMENT grid that an AUTHORING click snaps to.
##
## A quarter — 0.635 mm on the 2.54 mm (0.1") default — because placement and
## authoring are different jobs at different scales. `grid_size` is the pitch
## COMPONENTS sit on, and a part that lands between 0.1" points is a part on the
## wrong hole; but a pour corner or a trace bend has no such pitch to respect, and
## on the full grid the nearest legal point can be up to 1.27 mm from where the
## user clicked. Owner ruling (epoch 6 boundary, "pours have poor granularity;
## snaps too far"). A quarter and not "off": snapping still keeps parallel edges
## parallel and coincident corners coincident, which is most of what a grid is
## for. Free placement is one modifier key away — see pcb_canvas._author_point.
const AUTHOR_SNAP_FRACTION := 0.25


## Snap an AUTHORING click (zone vertex, trace waypoint) to the fine grid.
##
## The one snapper for entity authoring, shared by every drawing tool on the
## canvas — component drags keep snap_to_grid() above, deliberately. Guards a
## non-positive grid_size (a malformed board's "grid_mm": 0 would otherwise divide
## by zero and place the vertex at NaN, off the board and unserializable): with no
## usable grid the click stands as made.
func snap_author_point(position: Vector2) -> Vector2:
	var step := grid_size * AUTHOR_SNAP_FRACTION
	if step <= 0.0:
		return position
	return Vector2(
		roundf(position.x / step) * step,
		roundf(position.y / step) * step
	)


## Check if a position is within the board bounds
func is_within_bounds(position: Vector2) -> bool:
	return position.x >= 0 and position.x <= board_width and \
		   position.y >= 0 and position.y <= board_height


## Get the board bounding rectangle
func get_board_rect() -> Rect2:
	return Rect2(0, 0, board_width, board_height)


## Generate a unique component ID
func generate_component_id(prefix: String = "U") -> String:
	var counter := 1
	var new_id := "%s%d" % [prefix, counter]
	while components.has(new_id):
		counter += 1
		new_id = "%s%d" % [prefix, counter]
	return new_id

#endregion
