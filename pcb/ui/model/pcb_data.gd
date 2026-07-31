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
var zones: Array[Dictionary] = []

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
func get_trace_at(position: Vector2, threshold: float = 1.0) -> String:
	var best_id: String = ""
	var best_length: float = INF

	for trace_id in traces:
		var trace = traces[trace_id]
		if trace.is_point_near(position, threshold):
			var trace_length: float = trace.get_length()
			if trace_length < best_length:
				best_length = trace_length
				best_id = trace_id

	return best_id


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

#endregion


#region Zone Management

## Entropy width of a minted persistent id — 16 bytes → 32 lowercase hex chars.
## MIRRORS internal/board/migrate.go's mintedIDBytes; internal/board/validate.go
## isMintedID() checks EXACTLY this width, so the two must not drift.
const MINTED_ID_BYTES := 16


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
	var zone_is_keepout := kind.strip_edges().to_lower() == "keepout"
	if point_count < 3:
		return "A zone outline needs at least 3 points (%d placed)." % point_count
	if net_name.is_empty():
		# A keepout with no net is the KiCad-parity case, not a refusal.
		if not zone_is_keepout:
			return "Pick a net first — a copper pour must name a declared net."
	elif not has_net(net_name):
		return "Net \"%s\" is not declared on this board." % net_name
	if layer.is_empty():
		return "No copper layer to place the zone on."
	if not layers.is_empty() and layer not in layers:
		return "Layer \"%s\" is not in the board's declared layer stack." % layer
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
	var pts := PackedVector2Array(outline_points)
	var refusal := zone_author_error(net_name, layer, pts.size(), kind)
	if not refusal.is_empty():
		push_warning("[PCBData] create_zone refused: %s" % refusal)
		return {}

	var outline: Array = []
	for p in pts:
		outline.append({"x_mm": p.x, "y_mm": p.y})

	var zone := {
		"id": mint_entity_id("zone"),
		"layer": layer,
		"kind": kind,
		"outline": outline,
	}
	if not net_name.is_empty():
		zone["net"] = net_name
	zones.append(zone)
	record_change("add_zone", {
		"zone_id": zone["id"],
		"net_name": net_name,
		"layer": layer,
		"kind": kind,
		"point_count": pts.size(),
	})
	data_changed.emit()
	return zone

#endregion


#region Trace Authoring

## Fallback width for an authored trace when the board declares no design rule.
## MATCHES pcb_trace.gd's own `width` default, so a board with no design_rules
## block authors traces at the same width the rest of this model already assumes
## rather than at a second, differently-chosen number.
const DEFAULT_TRACE_WIDTH_MM := 0.25


## The width a newly authored trace gets, in mm.
##
## `design_rules` is the canonical board block (see its declaration) and
## `trace_width_mm` is its canonical key — the board's own answer to "how wide is
## a trace here", so the drawing tool asks the board instead of carrying a
## preference of its own. Non-positive or missing (an older board, or one whose
## design_rules block never named a width) falls back to DEFAULT_TRACE_WIDTH_MM;
## a zero-width trace is not copper, so a malformed rule must not produce one.
func authored_trace_width() -> float:
	var w := float(design_rules.get("trace_width_mm", 0.0))
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
func trace_author_error(net_name: String, layer: String, point_count: int) -> String:
	if point_count < 2:
		return "A trace needs at least 2 points (%d placed)." % point_count
	if net_name.is_empty():
		return "A trace must name a net — start it on a pad that has one."
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
		"zones": _zones_to_list()
	}

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
			comp.get_footprint_name(),
			comp.position.x,
			comp.position.y,
			comp.rotation,
			comp.layer,
			value
		])

	return "\n".join(lines)


## Import from CSV format
func from_csv(csv_text: String) -> void:
	var lines := csv_text.split("\n")
	if lines.size() < 2:
		return

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
		return

	# Parse data rows
	var imported := 0
	for i in range(1, lines.size()):
		var line := lines[i].strip_edges()
		if line.is_empty():
			continue

		var fields := line.split(",")
		if fields.size() <= id_idx:
			continue

		var component = PCBComponentScript.new()
		component.id = fields[id_idx]

		if footprint_idx >= 0 and fields.size() > footprint_idx:
			component.set_footprint_by_name(fields[footprint_idx])

		if x_idx >= 0 and fields.size() > x_idx:
			component.position.x = fields[x_idx].to_float()
		if y_idx >= 0 and fields.size() > y_idx:
			component.position.y = fields[y_idx].to_float()
		if rot_idx >= 0 and fields.size() > rot_idx:
			component.rotation = fields[rot_idx].to_float()
		if layer_idx >= 0 and fields.size() > layer_idx:
			component.layer = fields[layer_idx]
		if value_idx >= 0 and fields.size() > value_idx:
			component.properties["value"] = fields[value_idx]

		component.setup_standard_pins()
		components[component.id] = component
		imported += 1

	# from_csv is a forward in-place MERGE (appends/overwrites components on the
	# CURRENT board — it does NOT clear or reset history), so it is a delta and
	# MUST advance board_revision. Funnel one summary record through record_change
	# (bumps once + journals + respects an active batch). A header-only CSV that
	# imported nothing is a no-op and is left unbumped.
	if imported > 0:
		record_change("import_csv", {"count": imported})
	structure_changed.emit()
	data_changed.emit()

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
	# Emitted ONLY when the board actually has zones, so a zone-free board's
	# canonical dict — and therefore the YAML pcb.serialize writes from it — is
	# byte-identical to what it was before zones existed. Go's Zone slice is
	# `omitempty`, so an empty list would round-trip away anyway; not emitting it
	# keeps that from being a thing anyone has to know.
	if not zones.is_empty():
		out["zones"] = _zones_to_list()
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
func _zones_to_list() -> Array:
	var result: Array = []
	for zone in zones:
		result.append(zone.duplicate(true))
	return result


## Deep-copy a canonical or snapshot zone list on the way IN. Non-dict entries are
## dropped rather than tolerated: every other loader here does the same
## (_vias_from_board_list, the component/net/trace loops), and a zone that is not
## a mapping has no outline to draw.
func _zones_from_list(zone_list) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not (zone_list is Array):
		return result
	for zd in zone_list:
		if zd is Dictionary:
			result.append((zd as Dictionary).duplicate(true))
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
