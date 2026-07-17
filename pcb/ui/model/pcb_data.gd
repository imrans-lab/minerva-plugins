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

## Undo/redo history
var history: Array[Dictionary] = []
var history_index: int = -1
const MAX_HISTORY_SIZE := 50

## Change journal — append-only log of forward actions (not undo/redo)
var change_journal: Array[Dictionary] = []
const MAX_JOURNAL_SIZE := 200
signal journal_entry_added(entry: Dictionary)

## Next trace ID counter
var _next_trace_id: int = 1


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


## Remove a net
func remove_net(net_name: String) -> void:
	if nets.has(net_name):
		# Also remove traces for this net
		var traces_to_remove: Array[String] = []
		for trace_id in traces:
			if traces[trace_id].net_name == net_name:
				traces_to_remove.append(trace_id)

		for trace_id in traces_to_remove:
			traces.erase(trace_id)

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

	traces[trace.id] = trace
	record_change("add_trace", {
		"trace_id": trace.id,
		"net_name": trace.net_name,
		"layer": trace.layer,
		"segment_count": maxi(0, trace.waypoints.size() - 1)
	})
	trace_changed.emit(trace.id)
	data_changed.emit()


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


## Clear all traces and vias
func clear_traces() -> void:
	traces.clear()
	vias.clear()
	_next_trace_id = 1
	record_change("clear_traces", {})
	data_changed.emit()


## Add a via
func add_via(via_data: Dictionary) -> void:
	vias.append(via_data)
	record_change("add_via", {"index": vias.size() - 1})
	data_changed.emit()


## Remove a via by index
func remove_via(index: int) -> void:
	if index >= 0 and index < vias.size():
		vias.remove_at(index)
		record_change("remove_via", {"index": index})
		data_changed.emit()

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
		"mounting_holes": mounting_holes.duplicate(true)
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
	data_changed.emit()
	structure_changed.emit()
	return true


## Redo last undone action
func redo() -> bool:
	if history_index >= history.size() - 1:
		return false

	history_index += 1
	_restore_state(history[history_index])
	data_changed.emit()
	structure_changed.emit()
	return true


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

	# Restore vias + mounting holes (F1 — see save_to_history). Reuse the shared
	# loaders so Vector2/dict positions normalize the same way as file load.
	_load_vias(state.get("vias", []))
	_load_mounting_holes(state.get("mounting_holes", []))

#endregion


#region Change Journal

## Record a change to the journal
func record_change(action: String, details: Dictionary) -> void:
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
		"mounting_holes": holes_arr
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

	# Load vias
	_load_vias(data.get("vias", []))

	# Load mounting holes (mirror vias so undo snapshots don't drop them)
	_load_mounting_holes(data.get("mounting_holes", []))

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

	return {
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
			traces[trace.id] = trace

	# Vias (canonical list → internal via dicts)
	_load_vias(_vias_from_board_list(data.get("vias", [])))

	# Mounting holes (canonical list → internal mounting-hole dicts)
	_load_mounting_holes(_mounting_holes_from_board_list(data.get("mounting_holes", [])))

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
	var s := str(v).strip_edges()
	if s.to_lower() == "f.cu":
		return "top"
	if s.to_lower() == "b.cu":
		return "bottom"
	if s.is_empty():
		return "top"
	return s.to_lower()


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

## Clear all data
func clear() -> void:
	components.clear()
	nets.clear()
	traces.clear()
	vias.clear()
	mounting_holes.clear()
	history.clear()
	history_index = -1
	_next_trace_id = 1
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
