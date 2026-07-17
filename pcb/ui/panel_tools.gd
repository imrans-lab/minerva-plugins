extends RefCounted
## PCB panel-executed MCP tool surface — waves 1 + 2 (DCR 019f6c3d0e3d; wave 1
## C2 round docket 019f6c45f09e; wave 2 C3 round docket 019f6c4604ba).
##
## All 21 tool bodies MOVED VERBATIM from Minerva core's MCPPcbPanelTools.gd
## (see Docs/design/panel-executed-tools.md §3 migration table), which is now
## DELETED — this file is the SOLE remaining implementation.
##   Wave 1: set_board_size, get_components, get_nets, get_pin_position,
##   pin_info, add_component, move_component, move_relative, rotate_component,
##   delete_component, connect_net, spatial_query, describe_component,
##   import_csv, export_csv, import_footprint_geometry.
##   Wave 2: get_change_journal, import_trace_geometry, export_trace_geometry,
##   get_image, apply_route_hints (ASYNC — awaits the router worker bridge)
##   plus its whole route-correction collaboration-loop helper cluster
##   (_run_router … _build_polylines_from_segments).
## Tool names, arg validation, result shapes, and error messages are preserved
## EXACTLY — existing test suites assert against them (mechanically rerouted
## to call through this surface instead of the deleted core module).
##
## Host resolution is NO LONGER this surface's job (contract §2.2/§2.3): the
## PluginToolRegistry dispatcher resolves args.editor_name -> the live
## PCBPanel -> this panel's own PcbAnnotationHost, and verifies ownership,
## BEFORE calling PCBPanel.handle_tool(tool_name, args), which forwards here
## with the host already in hand. That is why every handler below takes
## `host` as a parameter instead of resolving it from args via
## AnnotationHostRegistry (the old core module's _resolve_host/_no_host_error
## dance is gone — panel_tools.gd never sees an unknown/missing editor_name).
##
## Coroutine note (Godot 4.6 static-typing landmine): apply_route_hints awaits
## the router bridge, so `handle()` as a whole is a coroutine once that branch
## exists in its body. PCBPanel.handle_tool awaits this call unconditionally
## (`return await _PanelToolsScript.handle(...)`) — correct for every tool,
## sync or async, since awaiting an already-resolved coroutine call is a no-op
## wait. Any other call site reaching `handle()` (tests included) must await
## too.
##
## Off-tree note: this file lives OUTSIDE Minerva's res:// tree, so it MUST
## NOT declare a class_name — preloaded by relative path from PCBPanel.gd
## (matches the convention every other pcb/ui/*.gd file already follows).

## Shared split+via+layer-run-toggle geometry (U4) lives on pcb_route_hint_kind.gd
## as a static func (apply_via_at_point) so ViaInsertTool (the canvas gesture)
## and _add_via below (the MCP parity tool) share ONE implementation. Off-tree,
## no class_name — reached by preload(), same convention every other
## cross-file pcb/ui/*.gd reference in this plugin already uses.
const _PcbRouteHintKindScript := preload("kinds/pcb_route_hint_kind.gd")

## Footprint names accepted by add_component (mirrors the legacy schema enum;
## the plugin component enum carries extra values but is set by NAME,
## off-tree safe). Moved from MCPPcbPanelTools._VALID_FOOTPRINTS verbatim —
## only add_component (wave 1) used it.
const _VALID_FOOTPRINTS: Array[String] = [
	"RESISTOR", "CAPACITOR", "IC_DIP", "IC_QFP", "SWITCH", "CONNECTOR",
	"LED", "DIODE", "TRANSISTOR", "HEADER", "MOUNTING_HOLE", "MODULE",
]


## Dispatch entry point — called by PCBPanel.handle_tool(tool_name, args).
## `host` is the panel's own PcbAnnotationHost (never null in production: the
## panel builds it eagerly in _init()); tests may still pass a fresh host
## directly. An unrecognised tool_name returns {} so the PluginToolRegistry
## dispatcher maps it to the structured tool_unhandled error (contract §2.4).
## Coroutine: the apply_route_hints branch awaits the router bridge, which
## makes this whole function a coroutine — every caller must await it (see
## the class doc note above).
static func handle(host, tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_pcb_set_board_size":
			return _set_board_size(host, args)
		"minerva_pcb_get_components":
			return _get_components(host, args)
		"minerva_pcb_get_nets":
			return _get_nets(host, args)
		"minerva_pcb_get_pin_position":
			return _get_pin_position(host, args)
		"minerva_pcb_pin_info":
			return _pin_info(host, args)
		"minerva_pcb_add_component":
			return _add_component(host, args)
		"minerva_pcb_move_component":
			return _move_component(host, args)
		"minerva_pcb_move_relative":
			return _move_relative(host, args)
		"minerva_pcb_rotate_component":
			return _rotate_component(host, args)
		"minerva_pcb_delete_component":
			return _delete_component(host, args)
		"minerva_pcb_connect_net":
			return _connect_net(host, args)
		"minerva_pcb_spatial_query":
			return _spatial_query(host, args)
		"minerva_pcb_describe_component":
			return _describe_component(host, args)
		"minerva_pcb_import_csv":
			return _import_csv(host, args)
		"minerva_pcb_export_csv":
			return _export_csv(host, args)
		"minerva_pcb_import_footprint_geometry":
			return _import_footprint_geometry(host, args)
		"minerva_pcb_get_change_journal":
			return _get_change_journal(host, args)
		"minerva_pcb_import_trace_geometry":
			return _import_trace_geometry(host, args)
		"minerva_pcb_export_trace_geometry":
			return _export_trace_geometry(host, args)
		"minerva_pcb_get_image":
			return _get_image(host, args)
		"minerva_pcb_apply_route_hints":
			return await _apply_route_hints(host, args)
		"minerva_pcb_proposal_accept":
			return _proposal_accept(host, args)
		"minerva_pcb_proposal_reject":
			return _proposal_reject(host, args)
		"minerva_pcb_hint_undo":
			return _hint_undo(host, args)
		"minerva_pcb_hint_redo":
			return _hint_redo(host, args)
		"minerva_pcb_add_via":
			return _add_via(host, args)
	return {}


# ── Tool implementations (moved verbatim from MCPPcbPanelTools.gd) ───────────

static func _set_board_size(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var width: float = float(args.get("width", 100.0))
	var height: float = float(args.get("height", 100.0))
	data.set_board_size(width, height)
	return _ok({"board_width": width, "board_height": height})


static func _get_components(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var components: Array = []
	for comp_id in data.components:
		var comp = data.components[comp_id]
		var comp_info := {
			"id": comp.id,
			"footprint": comp.get_footprint_name(),
			"x": comp.position.x,
			"y": comp.position.y,
			"rotation": comp.rotation,
			"layer": comp.layer,
			"pins": comp.pins.keys(),
		}
		if comp.properties.has("value"):
			comp_info["value"] = comp.properties["value"]
		components.append(comp_info)
	return _ok({"component_count": components.size(), "components": components})


static func _get_nets(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var nets_arr: Array = []
	for net_name in data.nets:
		var net = data.nets[net_name]
		var pins_arr: Array = []
		for pin in net.pins:
			pins_arr.append("%s.%s" % [pin.get("component_id", ""), pin.get("pin_name", "")])
		nets_arr.append({"name": net.name, "pins": pins_arr, "is_power": net.is_power_net})
	return _ok({"net_count": nets_arr.size(), "nets": nets_arr})


static func _get_pin_position(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	var pin: String = str(args.get("pin", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if pin.is_empty():
		return _err("pin is required")

	var comp = data.get_component(component_id)
	if not comp:
		return _err("Component not found: %s" % component_id)

	var available_pins: Array = []
	for pin_name in comp.pins:
		var pin_sym_name: String = comp.get_pin_name(str(pin_name))
		var entry := {"pin": str(pin_name)}
		if not pin_sym_name.is_empty():
			entry["name"] = pin_sym_name
		available_pins.append(entry)

	if not comp.pins.has(pin):
		return {
			"error": "Pin '%s' not found on component '%s'" % [pin, component_id],
			"success": false,
			"available_pins": available_pins,
		}

	var world_pos: Vector2 = comp.get_pin_world_position(pin)
	return {
		"success": true,
		"world_position": {"x": float(world_pos.x), "y": float(world_pos.y)},
		"component_position": {"x": float(comp.position.x), "y": float(comp.position.y)},
		"component_rotation": float(comp.rotation),
		"pin": str(pin),
		"pin_name": comp.get_pin_name(pin),
		"available_pins": available_pins,
	}


## WC-1 pin inspector MCP parity (contract §2/§3): resolves the SAME
## host.pad_at()/host.pin_info() the canvas's INSPECT_PIN mode drives, then
## adds display_name via host.pin_display_name() so this tool's answer is
## byte-for-byte what the panel's Pin Info section shows for the same pin.
## Duck-typed has_method guards (never a class reference — PcbAnnotationHost
## is off-tree); a garbage/malformed ref or an x_mm/y_mm miss returns a
## structured _err, never a crash.
static func _pin_info(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	if not host.has_method("pad_at") or not host.has_method("pin_info"):
		return _err("PCB pin inspector not available on this host")

	var component := ""
	var pin := ""
	if args.has("ref"):
		var ref: String = str(args.get("ref", ""))
		if ref.is_empty():
			return _err("ref must be a non-empty string")
		var dot := ref.rfind(".")
		if dot <= 0 or dot >= ref.length() - 1:
			return _err("malformed ref '%s' — expected 'Component.Pin'" % ref)
		component = ref.left(dot)
		pin = ref.substr(dot + 1)
	elif args.has("x_mm") and args.has("y_mm"):
		var x_mm: float = float(args.get("x_mm", 0.0))
		var y_mm: float = float(args.get("y_mm", 0.0))
		var hit: Dictionary = host.pad_at(Vector2(x_mm, y_mm))
		if hit.is_empty():
			return _err("no pad found near (%.3f, %.3f) mm" % [x_mm, y_mm])
		component = str(hit.get("component", ""))
		pin = str(hit.get("pin", ""))
	else:
		return _err("either ref (\"Component.Pin\") or x_mm/y_mm is required")

	var info: Dictionary = host.pin_info(component, pin)
	if info.is_empty():
		return _err("unknown pin '%s.%s'" % [component, pin])

	var result: Dictionary = info.duplicate(true)
	result["display_name"] = host.pin_display_name(info) if host.has_method("pin_display_name") else ""
	return _ok(result)


static func _add_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var footprint_str: String = str(args.get("footprint", ""))
	if footprint_str.is_empty():
		return _err("footprint is required")
	if not _VALID_FOOTPRINTS.has(footprint_str.to_upper()):
		return _err("Invalid footprint type: %s" % footprint_str)

	var x: float = float(args.get("x", 50.0))
	var y: float = float(args.get("y", 50.0))

	var component_id: String = str(args.get("id", ""))
	if component_id.is_empty():
		var prefix: String = footprint_str[0] if footprint_str.length() > 0 else "U"
		component_id = data.generate_component_id(prefix)

	var comp = data.new_component()
	comp.id = component_id
	comp.set_footprint_by_name(footprint_str.to_upper())

	var snap: bool = bool(args.get("snap_to_grid", true))
	if snap:
		comp.position = data.snap_to_grid(Vector2(x, y))
	else:
		comp.position = Vector2(x, y)
	comp.rotation = float(args.get("rotation", 0.0))

	var pin_count: int = int(args.get("pin_count", 0))
	var pin_names: Array = args.get("pin_names", [])
	if pin_count > 0:
		var pad_type: String = str(args.get("pad_type", "tht"))
		var pad_spacing: float = float(args.get("pad_spacing", 2.54))
		var row_sp: float = float(args.get("row_spacing", 7.62))
		match footprint_str.to_upper():
			"HEADER", "CONNECTOR":
				comp.setup_header_pins(pin_count, pin_names)
			"IC_DIP":
				comp.setup_dip_pins(pin_count)
			"MODULE":
				comp.setup_module_pins(pin_count)
			_:
				comp.setup_generic_pins(pin_count, pad_type, pad_spacing, row_sp)
	else:
		comp.setup_standard_pins()

	if args.has("width") or args.has("height"):
		var custom_width: float = float(args.get("width", comp.width))
		var custom_height: float = float(args.get("height", comp.height))
		comp.set_size(custom_width, custom_height)

	if args.has("value"):
		comp.properties["value"] = args.get("value")

	data.save_to_history("Add " + component_id)
	data.add_component(comp)

	return _ok({
		"component_id": component_id,
		"x": comp.position.x,
		"y": comp.position.y,
		"pin_count": comp.pins.size(),
	})


static func _move_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Component not found: %s" % component_id)

	var new_pos: Vector2 = data.snap_to_grid(Vector2(float(args.get("x", 0.0)), float(args.get("y", 0.0))))
	data.save_to_history("Move " + component_id)
	data.move_component(component_id, new_pos)
	return _ok({"component_id": component_id, "x": new_pos.x, "y": new_pos.y})


static func _move_relative(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	var component_id: String = str(args.get("component_id", ""))
	var direction: String = str(args.get("direction", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if direction.is_empty():
		return _err("direction is required")

	var spatial = _get_spatial(host)
	if spatial == null:
		return _err("PCB data not available")

	var new_pos: Vector2 = spatial.interpret_relative_move(component_id, direction)
	if data.has_component(component_id):
		data.save_to_history("Move " + component_id)
		data.move_component(component_id, data.snap_to_grid(new_pos))

	return _ok({
		"component_id": component_id,
		"new_x": new_pos.x,
		"new_y": new_pos.y,
		"interpreted_direction": direction,
	})


static func _rotate_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	var comp = data.get_component(component_id)
	if not comp:
		return _err("Component not found: %s" % component_id)

	var degrees = args.get("degrees", 90)
	var new_rotation: float = comp.rotation
	if degrees is String:
		if degrees.to_lower() == "clockwise":
			new_rotation = fmod(comp.rotation + 90.0, 360.0)
		elif degrees.to_lower() == "counterclockwise":
			new_rotation = fmod(comp.rotation - 90.0 + 360.0, 360.0)
	else:
		new_rotation = float(degrees)

	data.save_to_history("Rotate " + component_id)
	data.rotate_component(component_id, new_rotation)
	return _ok({"component_id": component_id, "rotation": new_rotation})


static func _delete_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Component not found: %s" % component_id)

	data.save_to_history("Delete " + component_id)
	data.remove_component(component_id)
	return _ok({"deleted": component_id})


static func _connect_net(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var net_name: String = str(args.get("net_name", ""))
	var pins: Array = args.get("pins", [])
	if net_name.is_empty():
		return _err("net_name is required")
	if pins.is_empty():
		return _err("pins array is required")

	var operations: Array = []
	for pin_info in pins:
		if pin_info is Dictionary:
			var comp_id: String = str(pin_info.get("component", ""))
			var pin_name: String = str(pin_info.get("pin", ""))
			if not comp_id.is_empty() and not pin_name.is_empty():
				operations.append({"component": comp_id, "pin": pin_name})

	var connected: Array = []
	for op in operations:
		connected.append("%s.%s" % [str(op.component), str(op.pin)])

	var result := {"success": true, "net_name": str(net_name), "connected_pins": connected}
	if JSON.stringify(result).is_empty():
		return _err("Internal serialization error")

	for op in operations:
		data.connect_pin_to_net(net_name, op.component, op.pin)
	return result


static func _spatial_query(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var reference_component: String = str(args.get("reference_component", ""))
	var radius: float = float(args.get("radius_mm", 20.0))
	if reference_component.is_empty():
		# No reference → same shape as get_components (mirrors legacy).
		return _get_components(host, args)

	var spatial = _get_spatial(host)
	if spatial == null:
		return _err("PCB data not available")

	var nearby = spatial.get_components_near(reference_component, radius)
	var results: Array = []
	for comp_id in nearby:
		results.append({
			"id": comp_id,
			"relationship": spatial.describe_relative_position(reference_component, comp_id),
		})
	return _ok({
		"reference": reference_component,
		"radius_mm": radius,
		"nearby_count": results.size(),
		"nearby": results,
	})


static func _describe_component(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	var spatial = _get_spatial(host)
	if spatial == null:
		return _err("PCB data not available")
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")

	var context: Dictionary = spatial.describe_component_context(component_id)
	if context.is_empty():
		return _err("Component not found: %s" % component_id)
	context["success"] = true
	return context


static func _import_csv(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var csv_content: String = str(args.get("csv_content", ""))
	if csv_content.is_empty():
		return _err("csv_content is required")
	data.from_csv(csv_content)
	return _ok({"component_count": data.get_component_count()})


static func _export_csv(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	return _ok({"csv": data.to_csv()})


static func _import_footprint_geometry(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var geometry_data: Dictionary = args.get("geometry", {})
	if geometry_data.is_empty():
		return _err("geometry data is required")
	var position_is_center: bool = bool(args.get("position_is_center", false))
	var invert_y: bool = bool(args.get("invert_y", false))

	var components_data: Dictionary = geometry_data.get("components", {})
	var updated_count := 0
	var position_adjusted_count := 0
	var missing: Array = []

	for comp_id in components_data:
		var comp = data.get_component(comp_id)
		if not comp:
			missing.append(comp_id)
			continue
		var comp_geometry: Dictionary = components_data[comp_id]
		if comp_geometry.get("footprint_found", false):
			comp.load_pad_geometry(comp_geometry)
			updated_count += 1
			if position_is_center or invert_y:
				var new_pos: Vector2 = comp.position
				if invert_y:
					new_pos.y = data.board_height - new_pos.y
				if position_is_center:
					var xform: Transform2D = comp.get_transform()
					new_pos -= xform * comp.bbox_center_offset
				comp.position = new_pos
				position_adjusted_count += 1
		else:
			missing.append(comp_id)

	data.save_to_history("Import footprint geometry")
	data.data_changed.emit()

	var result := {
		"success": true,
		"updated_count": updated_count,
		"missing_footprints": missing,
		"board_name": geometry_data.get("board_name", ""),
	}
	if position_is_center or invert_y:
		result["position_adjusted_count"] = position_adjusted_count
		result["position_corrections_applied"] = {
			"position_is_center": position_is_center,
			"invert_y": invert_y,
			"board_height": data.board_height,
		}
	return result


# ── Wave-2 tool implementations (moved verbatim from MCPPcbPanelTools.gd,
#    C3 round, docket 019f6c4604ba) ───────────────────────────────────────────

static func _get_change_journal(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var since_timestamp: float = float(args.get("since_timestamp", 0.0))
	var limit: int = int(args.get("limit", 50))

	var entries: Array = data.get_change_journal(since_timestamp)
	if limit > 0 and entries.size() > limit:
		entries = entries.slice(entries.size() - limit)

	return _ok({
		"total_entries": data.change_journal.size(),
		"returned_entries": entries.size(),
		"entries": entries,
	})


static func _import_trace_geometry(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	var trace_data: Dictionary = args.get("trace_data", {})
	if trace_data.is_empty():
		return _err("trace_data is required")

	data.clear_traces()

	var traces_input: Array = trace_data.get("traces", [])
	var trace_groups: Dictionary = {}
	for seg in traces_input:
		var net_name: String = seg.get("net_name", "")
		var layer: String = seg.get("layer", "F.Cu")
		var key := "%s_%s" % [net_name, layer]
		if not trace_groups.has(key):
			trace_groups[key] = {
				"net_name": net_name,
				"layer": "top" if layer == "F.Cu" else "bottom",
				"width": seg.get("width", 0.3),
				"segments": [],
			}
		var start = seg.get("start", {})
		var end_pt = seg.get("end", {})
		trace_groups[key].segments.append({
			"start": Vector2(start.get("x", 0), start.get("y", 0)),
			"end": Vector2(end_pt.get("x", 0), end_pt.get("y", 0)),
		})

	var trace_count := 0
	for key in trace_groups:
		var group = trace_groups[key]
		var polylines := _build_polylines_from_segments(group.segments)
		for polyline in polylines:
			if polyline.size() < 2:
				continue
			var trace = data.new_trace()
			trace.id = "trace_%d" % trace_count
			trace.net_name = group.net_name
			trace.layer = group.layer
			trace.width = group.width
			for point in polyline:
				trace.waypoints.append(point)
			data.add_trace(trace)
			trace_count += 1

	var vias_input: Array = trace_data.get("vias", [])
	for via_data in vias_input:
		var pos = via_data.get("position", {})
		data.add_via({
			"position": Vector2(pos.get("x", 0), pos.get("y", 0)),
			"size": via_data.get("size", 0.8),
			"drill": via_data.get("drill", 0.4),
			"net_name": via_data.get("net_name", ""),
			"layers": via_data.get("layers", ["F.Cu", "B.Cu"]),
		})

	data.save_to_history("Import traces")
	return _ok({"trace_count": trace_count, "via_count": vias_input.size()})


static func _export_trace_geometry(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data

	var traces_output: Array = []
	for trace_id in data.get_trace_ids():
		var trace = data.get_trace(trace_id)
		if not trace:
			continue
		var layer_name: String = "F.Cu" if trace.layer == "top" else "B.Cu"
		for i in range(trace.waypoints.size() - 1):
			var start_pt: Vector2 = trace.waypoints[i]
			var end_pt: Vector2 = trace.waypoints[i + 1]
			traces_output.append({
				"start": {"x": snapped(start_pt.x, 0.0001), "y": snapped(start_pt.y, 0.0001)},
				"end": {"x": snapped(end_pt.x, 0.0001), "y": snapped(end_pt.y, 0.0001)},
				"width": trace.width,
				"layer": layer_name,
				"net_name": trace.net_name,
			})

	var vias_output: Array = []
	for via in data.vias:
		var pos: Vector2 = via.get("position", Vector2.ZERO)
		vias_output.append({
			"position": {"x": snapped(pos.x, 0.0001), "y": snapped(pos.y, 0.0001)},
			"size": via.get("size", 0.8),
			"drill": via.get("drill", 0.4),
			"net_name": via.get("net_name", ""),
			"layers": via.get("layers", ["F.Cu", "B.Cu"]),
		})

	return _ok({
		"trace_count": traces_output.size(),
		"via_count": vias_output.size(),
		"trace_data": {"traces": traces_output, "vias": vias_output},
	})


## Snapshot-style image capture (mirrors minerva_cad_snapshot in spirit). Renders
## the live board canvas via the host's render_content_to_image; headless /
## unmounted → image_data null (never crashes). Metadata is always populated from
## the model. Synchronous: this host's render_content_to_image returns the current
## frame directly (no deferred capture to await), so there is nothing to wait on.
##
## save_to_path (optional, bug 019f6ea4e52a): write the PNG to a caller-supplied
## absolute filesystem path instead of returning it inline as base64. Mirrors the
## fix already applied to minerva_annotations_render_overlay (Minerva commit
## 4b74971c "render_overlay writes PNG to caller-supplied path") — inline base64
## PNGs survive in the LLM conversation transcript and get re-tokenized every
## turn, which stalled a routing agent for 6+ minutes on a single ~150KB inline
## image. Validated up front (absolute path, parent dir exists) before any
## capture work, same as the annotation-tools precedent. Default behavior with
## no save_to_path is byte-for-byte unchanged for existing callers.
static func _get_image(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")

	var save_to_path: String = str(args.get("save_to_path", ""))
	var using_save_path: bool = not save_to_path.is_empty()

	# Validate save_to_path before doing any capture work — fail fast with a
	# structured error, never crash.
	if using_save_path:
		if not save_to_path.is_absolute_path():
			return _err("save_to_path must be an absolute path (got: %s)" % save_to_path)
		var parent_dir: String = save_to_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(parent_dir):
			return _err("save_to_path parent directory does not exist: %s" % parent_dir)

	var data = _get_data(host)

	var metadata := {}
	if data != null:
		metadata["board_width_mm"] = data.board_width
		metadata["board_height_mm"] = data.board_height
		metadata["component_count"] = data.components.size()
		metadata["net_count"] = data.nets.size()
	if host.has_method("get_all_annotations"):
		metadata["annotation_count"] = (host.call("get_all_annotations") as Array).size()

	var img: Image = null
	if host.has_method("render_content_to_image"):
		img = host.call("render_content_to_image", Rect2()) as Image

	if img == null:
		if using_save_path:
			return _ok({
				"saved_to": null,
				"format": "png",
				"metadata": metadata,
				"note": "No rendered image available (panel not mounted / headless).",
			})
		return _ok({
			"image_data": null,
			"format": "png",
			"metadata": metadata,
			"note": "No rendered image available (panel not mounted / headless).",
		})

	var png_buf: PackedByteArray = img.save_png_to_buffer()
	if png_buf.is_empty():
		return _err("Failed to encode PCB image")

	if using_save_path:
		var save_err: Error = img.save_png(save_to_path)
		if save_err != OK:
			return _err("Failed to write PNG to %s (error %d)" % [save_to_path, save_err])
		return _ok({
			"saved_to": save_to_path,
			"format": "png",
			"width": img.get_width(),
			"height": img.get_height(),
			"byte_size": png_buf.size(),
			"metadata": metadata,
		})

	return _ok({
		"image_data": Marshalls.raw_to_base64(png_buf),
		"format": "png",
		"encoding": "base64",
		"width": img.get_width(),
		"height": img.get_height(),
		"metadata": metadata,
	})


# ── Per-hint revision undo/redo (C4 deliverable 2, docket 019f6c464ff0) ───────
#
# Panel-executed MCP counterparts to PcbAnnotationHost.undo_hint_revision /
# redo_hint_revision — the SAME engine the Ctrl+Z-while-selected UI seam
# (PCBPanel._unhandled_key_input) drives, so an agent and a human undo the
# identical revision stack (a human's canvas bend-drag and an agent's
# minerva_annotations_update edit are indistinguishable once they land on the
# host — see PcbAnnotationHost.gd's "Per-hint revision history" class doc).

static func _hint_undo(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("undo_hint_revision"):
		return _err("PCB annotation host not available")
	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return _err("id is required")
	var result: Dictionary = host.undo_hint_revision(id)
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", "undo failed")))
	return _ok({"id": id, "kind_payload": result.get("kind_payload", {})})


static func _hint_redo(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("redo_hint_revision"):
		return _err("PCB annotation host not available")
	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return _err("id is required")
	var result: Dictionary = host.redo_hint_revision(id)
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", "redo failed")))
	return _ok({"id": id, "kind_payload": result.get("kind_payload", {})})


# ── Manual via insertion (U4, DCR 019f7095c395 Stage-2) ───────────────────────

## MCP parity for ViaInsertTool (pcb_route_hint_kind.gd's canvas gesture):
## split the proposal's nearest kind_payload.segments entry at (x, y), insert
## a via there, and recompute the layer-run toggle for every segment. Calls
## the SAME static helper (apply_via_at_point) the canvas tool calls, then
## persists through host.update_annotation — the identical mutate-with-history
## seam BendHandleEditTool/the canvas ViaInsertTool use (undo/redo + revision
## history already wired there; north-star: an agent's tool call and a
## human's click are indistinguishable once they land on the host).
static func _add_via(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("get_by_id") or not host.has_method("update_annotation"):
		return _err("PCB annotation host not available")
	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return _err("id is required")
	if not args.has("x") or not args.has("y"):
		return _err("x and y are required")

	var ann: Dictionary = host.get_by_id(id)
	if ann.is_empty():
		return _err("annotation not found: %s" % id)
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return _err("annotation '%s' is not a pcb_route_hint" % id)

	var kp: Dictionary = ann.get("kind_payload", {})
	var result: Dictionary = _PcbRouteHintKindScript.apply_via_at_point(kp, float(args.get("x", 0.0)), float(args.get("y", 0.0)))
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", "could not insert via")))

	var new_ann: Dictionary = ann.duplicate(true)
	new_ann["kind_payload"] = result.get("kind_payload", kp)
	if not host.update_annotation(id, new_ann):
		return _err("failed to persist via insertion for '%s'" % id)

	return _ok({
		"via_count": result.get("via_count", 0),
		"segments": result.get("segments", []),
	})


# ── Route-correction collaboration loop (moved verbatim from
#    MCPPcbPanelTools.gd, C3 round) ───────────────────────────────────────────
#
# minerva_pcb_apply_route_hints closes the route-correction loop (agent-router
# child 019eb47eb567). The propose→inspect→apply→iterate flow:
#
#   1. PROPOSE (commit absent/false): gather the board's OPEN pcb_route_hint
#      annotations (or the given hint_ids), route them through the worker, and
#      write the routed polylines back as AI-authored (author.kind="ai" → cyan)
#      pcb_route_hint PROPOSAL annotations. A proposal carries the routed
#      waypoints + kind_payload.net_names=[net] + kind_payload.proposal_for=
#      [source hint ids]. Proposals do NOT mutate the board — the user inspects
#      them in the dock/canvas first.
#   2. APPLY (commit=true): re-route the selected open hints and MATERIALIZE the
#      results as real traces in the model (journaled via save_to_history), then
#      transition the source hints open→applied. Returns applied/traces_added.
#   3. ITERATE: applied hints are excluded from the default (open) gather and AI
#      proposals are never re-routed (they carry proposal_for), so re-running
#      after the user edits/adds hints picks up only the fresh open hints.
#
# FAILURE AS FEEDBACK: partial/failed routing returns WHERE it got stuck —
# result.unrouted (net + blocked pad pair) surfaced as `stuck`, plus bridge
# warnings — structured data the agent can reason about, not a bare "failed".

static func _apply_route_hints(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var hint_ids: Array = args.get("hint_ids", [])
	var commit: bool = bool(args.get("commit", false))

	var source_hints: Array = _gather_route_hints(host, hint_ids)
	if source_hints.is_empty():
		return _ok({
			"proposed": 0,
			"proposals": [],
			"unrouted": [],
			"stuck": [],
			"committed": commit,
			"note": "no open route hints to route (add hints or pass hint_ids)",
		})

	var selection: Dictionary
	if hint_ids.is_empty():
		selection = {"mode": "open"}
	else:
		selection = {"mode": "ids", "ids": _hint_id_list(source_hints)}

	var reply: Dictionary = await _run_router(host, selection)
	if not bool(reply.get("ok", false)):
		return _router_unavailable(reply, source_hints)

	var result: Dictionary = reply.get("result", {})
	if commit:
		return _materialize_routes(host, data, result, source_hints)
	return _write_back_proposals(host, result, source_hints)


## Reach the router worker through the in-fence host bridge (async). The host
## forwards to the panel's broker request path. Returns the worker's {ok, result}
## envelope, or a structured worker_unavailable when no bridge is reachable
## (headless / channel not registered — see the WORKER-INVOCATION note in the
## contract doc).
static func _run_router(host, selection: Dictionary) -> Dictionary:
	if host != null and host.has_method("run_router"):
		return await host.run_router(selection)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "host has no run_router bridge to the router worker"}}


## Structured failure-as-feedback when the worker did not answer.
##
## Backend-stopped affordance (C5, docket 019f6c465fd8, bug 019f6c1e0399):
## PCBPanel.route_board() tags a reply whose error_code was "plugin_not_running"
## (the pcb backend subprocess is not RUNNING — PluginScenePanelBroker.
## _dispatch_to_plugin_backend's own check) with error.kind ==
## "plugin_not_running" specifically, distinct from the generic
## "worker_unavailable" (no IPC bridge reachable at all — e.g. headless
## tests with no broker mounted) / "worker_error" (some OTHER routing
## failure) kinds. Callers that need a human-actionable message (the Propose
## button) key off error=="pcb_backend_stopped"; agents get the same signal
## plus recovery_hint="start via minerva_plugin_start" in the machine shape.
static func _router_unavailable(reply: Dictionary, source_hints: Array) -> Dictionary:
	var err: Dictionary = reply.get("error", {})
	if str(err.get("kind", "")) == "plugin_not_running":
		return {
			"success": false,
			"error": "pcb_backend_stopped",
			"detail": err,
			"hint_ids": _hint_id_list(source_hints),
			"recovery_hint": "start via minerva_plugin_start",
			"note": "Routing needs the pcb backend, and it is not running. Start it (minerva_plugin_start, plugin_id \"pcb\"), then retry.",
		}
	return {
		"success": false,
		"error": "route_worker_unavailable",
		"detail": err,
		"hint_ids": _hint_id_list(source_hints),
		"note": "Router worker did not answer. In-fence wiring reaches it via host.run_router → panel 'pcb.route' broker request; declaring the 'pcb.route' channel (or exposing minerva_pcb_route in the worker MCP tools) is the out-of-fence follow-up — see pcb/docs/tools.md.",
	}


## Gather the source route hints to route. With explicit hint_ids: exactly those
## (any lifecycle). Without: every OPEN human/source hint. AI proposals (carrying
## kind_payload.proposal_for) are NEVER treated as source hints — that keeps the
## iterate loop from re-routing its own proposals, and applied hints drop out of
## the default open gather.
static func _gather_route_hints(host, hint_ids: Array) -> Array:
	var anns: Array = []
	if host != null and host.has_method("get_all_annotations"):
		anns = host.call("get_all_annotations")
	var wanted := {}
	for i in hint_ids:
		wanted[str(i)] = true
	var out: Array = []
	for ann in anns:
		if not (ann is Dictionary):
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		var payload: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
		if payload.has("proposal_for"):
			continue  # an AI proposal — not a source hint
		if not wanted.is_empty():
			if wanted.has(str(ann.get("id", ""))):
				out.append(ann)
		elif str(ann.get("lifecycle", "open")) == "open":
			out.append(ann)
	return out


## PROPOSE: routed polylines → AI-authored cyan proposal annotations. The board
## is NOT mutated — only annotations are added. Each proposal links to the source
## hint id(s) answering the same net.
static func _write_back_proposals(host, result: Dictionary, source_hints: Array) -> Dictionary:
	var proposals: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var pts: Array = _route_polyline(route)
		if pts.size() < 2:
			continue
		var layer: String = _route_layer(route)
		var width: float = _width_for_net(source_hints, net)
		var linked: Array = _source_hint_ids_for_net(source_hints, net)
		var first: Array = pts[0]
		var envelope: Dictionary = host.call("build_route_hint_envelope",
			float(first[0]), float(first[1]), "", layer, "single_trace", pts, "ai")
		var kp: Dictionary = envelope.get("kind_payload", {})
		kp["net_names"] = [net]
		kp["proposal_for"] = linked
		if width > 0.0:
			kp["width_mm"] = width
		# Lossless carry (U2, DCR 019f7095c395 Stage-1): the route's EXACT
		# per-segment geometry (real per-segment layer, not the flattened
		# summary above) and its vias, stored verbatim so _proposal_accept can
		# commit precisely what was proposed instead of reconstructing a
		# single-layer, no-via approximation from `waypoints`/`layer`.
		# `waypoints` + `layer` are KEPT unchanged (backward-compat: the
		# renderer and legacy proposals still read them; `layer` stays the
		# first-segment summary for the badge).
		kp["segments"] = (route.get("segments", []) as Array).duplicate(true)
		kp["vias"] = (route.get("vias", []) as Array).duplicate(true)
		# DRC-at-propose (docket 019f6f1492e0): the worker's route() attaches a
		# per-route "drc" verdict (see pcb_worker.methods._attach_route_drc) —
		# copy it onto the proposal's kind_payload so the dock badge (generic
		# WorkflowAnnotationList) and MCP reads (annotations_list passes
		# kind_payload through unmodified) both see it. Absent when the
		# worker didn't run DRC (e.g. native-path routing, not reachable from
		# this canonical-only propose flow) — no key added, matching the
		# "absent drc key -> no badge" contract.
		if route.has("drc"):
			kp["drc"] = route.get("drc")
		envelope["kind_payload"] = kp
		envelope["summary"] = "Proposed route %s (%d waypoints, %s)" % [net, pts.size(), layer]
		var new_id: String = str(host.call("add_annotation_v2", envelope))
		if new_id.is_empty():
			continue
		proposals.append({
			"id": new_id,
			"net": net,
			"layer": layer,
			"waypoint_count": pts.size(),
			"proposal_for": linked,
			"width_mm": width,
		})
	return {
		"success": true,
		"committed": false,
		"proposed": proposals.size(),
		"proposals": proposals,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
		"drc_summary": result.get("drc_summary", {}),
	}


## APPLY: materialize routed polylines as real traces (journaled) + transition
## source hints open→applied. Per-layer segment grouping mirrors
## import_trace_geometry so multi-layer routes become correct single-layer traces.
static func _materialize_routes(host, data, result: Dictionary, source_hints: Array) -> Dictionary:
	var traces_added := 0
	var failed: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var width: float = _width_for_net(source_hints, net)
		if width <= 0.0:
			width = 0.25
		var by_layer := {}
		for seg in route.get("segments", []):
			if not (seg is Dictionary):
				continue
			var lyr: String = str(seg.get("layer", "F.Cu"))
			if not by_layer.has(lyr):
				by_layer[lyr] = []
			by_layer[lyr].append({
				"start": _arr_to_vec2(seg.get("start", [0, 0])),
				"end": _arr_to_vec2(seg.get("end", [0, 0])),
			})
		var made_any := false
		for lyr in by_layer:
			for polyline in _build_polylines_from_segments(by_layer[lyr]):
				if polyline.size() < 2:
					continue
				var trace = data.new_trace()
				trace.net_name = net
				trace.layer = "top" if lyr == "F.Cu" else "bottom"
				trace.width = width
				for point in polyline:
					trace.waypoints.append(point)
				data.add_trace(trace)
				traces_added += 1
				made_any = true
		if not made_any:
			failed.append({"net": net, "reason": "no usable segments in routed result"})
		# Via size/drill (U2, DCR 019f7095c395 Stage-1): the board's own
		# design_rules when set (via_diameter_mm/via_drill_mm), else the prior
		# 0.8/0.4 defaults — never hardcoded over an authored board's rules.
		# from_layer/to_layer are the canonical (top/bottom) span fields U1
		# added; a 2-layer board's via always spans top<->bottom.
		var dr: Dictionary = data.design_rules if data.design_rules is Dictionary else {}
		var via_size: float = float(dr.get("via_diameter_mm", 0.0))
		if via_size <= 0.0:
			via_size = 0.8
		var via_drill: float = float(dr.get("via_drill_mm", 0.0))
		if via_drill <= 0.0:
			via_drill = 0.4
		for via in route.get("vias", []):
			data.add_via({
				"position": _via_position(via),
				"size": via_size,
				"drill": via_drill,
				"net_name": net,
				"from_layer": "top",
				"to_layer": "bottom",
			})

	# Snapshot AFTER mutation so the undo/redo checkpoint captures the applied
	# traces (undo() restores the PREVIOUS entry — matches _import_trace_geometry;
	# snapshotting before would leave the applied state unrecoverable on redo).
	if traces_added > 0:
		data.save_to_history("Apply route hints")

	# Owner-ratified contract (HITL-2, 2026-07-16): an accepted hint is DELETED
	# once its real trace exists — it was scaffolding, and leaving it (or its
	# proposals) behind clutters the board. Hints whose nets failed to
	# materialize stay open for iteration. Proposals answering a consumed hint
	# (kind_payload.proposal_for) are removed with it.
	var consumed_ids: Array = []
	if traces_added > 0 and host.has_method("remove_annotation"):
		var to_delete: Array = []
		if failed.is_empty():
			to_delete = _hint_id_list(source_hints)
		else:
			var ok_nets: Array = []
			for route in result.get("routes", []):
				if route is Dictionary:
					ok_nets.append(str(route.get("net", "")))
			for net in ok_nets:
				for hid in _source_hint_ids_for_net(source_hints, str(net)):
					if not (hid in to_delete):
						to_delete.append(hid)
		for hid in to_delete:
			if str(hid).is_empty():
				continue
			if host.remove_annotation(str(hid)):
				consumed_ids.append(str(hid))
	var removed_proposals: Array = []
	if not consumed_ids.is_empty() and host.has_method("get_annotations"):
		for ann in host.get_annotations():
			if not (ann is Dictionary):
				continue
			var kp: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
			var links: Array = kp.get("proposal_for", []) if kp.get("proposal_for", []) is Array else []
			for linked in links:
				if str(linked) in consumed_ids:
					var pid := str(ann.get("id", ""))
					if not pid.is_empty() and host.remove_annotation(pid):
						removed_proposals.append(pid)
					break
	return {
		"success": true,
		"committed": true,
		"applied": consumed_ids.size(),
		"applied_hint_ids": consumed_ids,  # deprecated alias of consumed_hint_ids
		"consumed_hint_ids": consumed_ids,
		"removed_proposal_ids": removed_proposals,
		"traces_added": traces_added,
		"failed": failed,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
	}


## PER-PROPOSAL accept (C5, docket 019f6c465fd8, deliverable 2; lossless carry
## U2, DCR 019f7095c395 Stage-1). Materializes ONE proposal's own stored route
## as real trace(s)/via(s), sharing _materialize_routes verbatim rather than
## re-implementing trace synthesis: the proposal's kind_payload.segments +
## kind_payload.vias (the EXACT per-segment-layer geometry and vias
## _write_back_proposals stores verbatim from the router's route) are handed
## through unchanged in a synthetic single-route "result" shaped exactly like
## a router reply ({routes:[{net, segments, vias}]}). LEGACY proposals written
## before U2 (no kind_payload.segments) fall back to chopping
## kind_payload.waypoints (the FULL polyline — always anchor..dest, never
## interior-only) into single-layer segments on kind_payload.layer, with no
## vias — the pre-U2 lossy behavior, kept only for old proposals still on a
## board. Either way the result is handed to _materialize_routes together with
## the REAL source-hint dicts kind_payload.proposal_for points at (so width/
## consumed-id resolution — and the removed_proposal_ids cleanup pass that
## finds and deletes proposals linking to a consumed hint — are the exact same
## code the bulk commit=true path runs). Owner-ratified contract (HITL-2): an
## accepted proposal AND its source hint(s) are both deleted; regular (non-
## proposal) hints are untouched.
static func _proposal_accept(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("get_by_id"):
		return _err("PCB annotation host not available")
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return _err("id is required")
	var proposal: Dictionary = host.get_by_id(id)
	if proposal.is_empty():
		return _err("proposal not found: %s" % id)
	if str(proposal.get("kind", "")) != "pcb_route_hint":
		return _err("annotation '%s' is not a route-hint proposal" % id)

	var kp: Dictionary = proposal.get("kind_payload", {})
	var linked: Array = _string_list(kp.get("proposal_for", []))
	if linked.is_empty():
		return _err("annotation '%s' is not a proposal (no kind_payload.proposal_for)" % id)

	var net_names := _string_list(kp.get("net_names", []))
	var net: String = net_names[0] if not net_names.is_empty() else ""

	# Lossless path (U2): when the proposal carries its EXACT per-segment
	# geometry (written by _write_back_proposals above), commit that verbatim
	# — real per-segment layers + real vias — instead of reconstructing a
	# single-layer, no-via approximation from the flattened `waypoints`
	# polyline (that would silently re-introduce the collision the via
	# resolved). Fall back to waypoint reconstruction only for LEGACY
	# proposals written before U2 (no `segments` key).
	var segments: Array = []
	var vias: Array = []
	var raw_segments: Variant = kp.get("segments", [])
	if raw_segments is Array and not (raw_segments as Array).is_empty():
		segments = (raw_segments as Array).duplicate(true)
		var raw_vias: Variant = kp.get("vias", [])
		if raw_vias is Array:
			vias = (raw_vias as Array).duplicate(true)
	else:
		var pts: Array = []
		for wp in kp.get("waypoints", []):
			pts.append(_arr_to_vec2(wp))
		if pts.size() < 2:
			return _err("proposal '%s' has no routable polyline" % id)
		var kicad_layer := str(kp.get("layer", "F.Cu"))
		for i in range(pts.size() - 1):
			segments.append({"start": pts[i], "end": pts[i + 1], "layer": kicad_layer})

	if segments.is_empty():
		return _err("proposal '%s' has no routable polyline" % id)

	# The REAL source-hint dicts (for width fallback + so _materialize_routes'
	# own consumed-id / removed-proposal cleanup runs against the true hints,
	# not a synthetic stand-in). A hint may already be gone (a prior accept/
	# reject raced it) — fabricate a minimal stand-in carrying the proposal's
	# own net/width so materialization can still size the trace; there is then
	# nothing further to delete for that (already-gone) hint.
	var source_hints: Array = []
	for hid in linked:
		var h: Dictionary = host.get_by_id(hid)
		if not h.is_empty():
			source_hints.append(h)
	if source_hints.is_empty():
		source_hints = [{"id": "", "kind_payload": {"net_names": [net], "width_mm": kp.get("width_mm", 0.0)}}]

	var synth_result := {"routes": [{"net": net, "segments": segments, "vias": vias}]}
	var mat: Dictionary = _materialize_routes(host, data, synth_result, source_hints)
	if not bool(mat.get("success", false)) or int(mat.get("traces_added", 0)) <= 0:
		return _err("failed to materialize proposal '%s'" % id)

	# _materialize_routes already removes any proposal whose proposal_for links
	# a just-consumed hint — that generically catches THIS proposal since
	# consumed_hint_ids == linked. Fall back to a direct delete only for the
	# edge case above (source hints already gone, so nothing was "consumed" to
	# trigger that cleanup pass) — acceptance must never leave the proposal
	# behind.
	var removed_proposals: Array = mat.get("removed_proposal_ids", [])
	var removed_id := id if (id in removed_proposals) else ""
	if removed_id.is_empty() and host.has_method("remove_annotation"):
		if host.remove_annotation(id):
			removed_id = id

	return _ok({
		"trace_added": true,
		"consumed_hint_ids": mat.get("consumed_hint_ids", []),
		"removed_proposal_id": removed_id,
	})


## PER-PROPOSAL reject (C5 deliverable 2): deletes the proposal only. Source
## hints stay open — owner contract: "REJECT deletes the proposal; source hints
## stay open for iteration."
static func _proposal_reject(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("get_by_id"):
		return _err("PCB annotation host not available")
	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return _err("id is required")
	var proposal: Dictionary = host.get_by_id(id)
	if proposal.is_empty():
		return _err("proposal not found: %s" % id)

	var kp: Dictionary = proposal.get("kind_payload", {})
	var linked: Array = _string_list(kp.get("proposal_for", []))
	if linked.is_empty():
		return _err("annotation '%s' is not a proposal (no kind_payload.proposal_for)" % id)

	if not host.has_method("remove_annotation") or not host.remove_annotation(id):
		return _err("failed to remove proposal '%s'" % id)

	return _ok({
		"removed_proposal_id": id,
		"source_hints_still_open": linked,
	})


## unrouted nets (+ bridge warnings) → structured "stuck" feedback the agent can
## reason about: which net, which pad pair is blocked.
static func _stuck_from_result(result: Dictionary) -> Array:
	var stuck: Array = []
	for u in result.get("unrouted", []):
		if u is Dictionary:
			stuck.append({
				"net": u.get("net", ""),
				"from": u.get("from", ""),
				"to": u.get("to", ""),
				"reason": "unrouted — blocked pad pair (congestion or no legal path)",
			})
	for w in result.get("warnings", []):
		stuck.append({"warning": w})
	return stuck


## Ordered polyline (Array of [x, y]) chaining a route's segment endpoints. Layer
## changes/vias appear as continuous joints — adequate for a visual proposal.
static func _route_polyline(route: Dictionary) -> Array:
	var pts: Array = []
	for seg in route.get("segments", []):
		if not (seg is Dictionary):
			continue
		var st: Array = _arr_pair(seg.get("start", [0, 0]))
		var en: Array = _arr_pair(seg.get("end", [0, 0]))
		if pts.is_empty():
			pts.append(st)
		pts.append(en)
	return pts


## KiCad copper layer of a route (its first segment's layer), defaulting F.Cu.
static func _route_layer(route: Dictionary) -> String:
	for seg in route.get("segments", []):
		if seg is Dictionary and (seg as Dictionary).has("layer"):
			return str((seg as Dictionary).get("layer", "F.Cu"))
	return "F.Cu"


## Widest authored trace width among the source hints that target `net`
## (kind_payload.net_names). 0.0 when none specify a width.
static func _width_for_net(source_hints: Array, net: String) -> float:
	var w := 0.0
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if net in _string_list(kp.get("net_names", [])):
			var hw := float(kp.get("width_mm", 0.0))
			if hw > w:
				w = hw
	return w


## Source hint ids that answer `net` (by net_names). Falls back to ALL source
## hint ids when none match by net — the whole selection collectively asked to
## route, so the proposal is still traceable to its origin.
static func _source_hint_ids_for_net(source_hints: Array, net: String) -> Array:
	var ids: Array = []
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if net in _string_list(kp.get("net_names", [])):
			ids.append(str(hint.get("id", "")))
	if ids.is_empty():
		return _hint_id_list(source_hints)
	return ids


static func _hint_id_list(source_hints: Array) -> Array:
	var ids: Array = []
	for hint in source_hints:
		ids.append(str(hint.get("id", "")))
	return ids


static func _string_list(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for v in (raw as Array):
			out.append(str(v))
	return out


## Coerce a [x, y] pair (Array or Vector2) to a fresh [float, float] Array.
static func _arr_pair(raw) -> Array:
	if raw is Vector2:
		return [float((raw as Vector2).x), float((raw as Vector2).y)]
	if raw is Array and (raw as Array).size() >= 2:
		return [float((raw as Array)[0]), float((raw as Array)[1])]
	return [0.0, 0.0]


static func _arr_to_vec2(raw) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO


## A route's via entries are POSITIONAL [x, y] (the worker's public route()
## reply — see pcb_worker.methods ~394-406: vias:[[x,y],...], no from/to).
## Defensively also accept a {x_mm,y_mm} or {x,y} dict shape (a via re-fed
## from a canonical board dict, e.g. a hand-edited/legacy proposal).
static func _via_position(raw) -> Vector2:
	if raw is Dictionary:
		var d: Dictionary = raw as Dictionary
		if d.has("x_mm") and d.has("y_mm"):
			return Vector2(float(d.get("x_mm", 0.0)), float(d.get("y_mm", 0.0)))
		if d.has("x") and d.has("y"):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		if d.has("position"):
			return _arr_to_vec2(d.get("position", [0, 0]))
		return Vector2.ZERO
	return _arr_to_vec2(raw)


## Connect trace segments into polylines (pure geometry; ported verbatim from the
## legacy MCPPCBTools helper so import_trace_geometry stays call-compatible).
static func _build_polylines_from_segments(segments: Array) -> Array:
	if segments.is_empty():
		return []
	var result: Array = []
	var used: Array = []
	used.resize(segments.size())
	used.fill(false)
	for i in range(segments.size()):
		if used[i]:
			continue
		var polyline: Array[Vector2] = [segments[i].start, segments[i].end]
		used[i] = true
		var changed := true
		while changed:
			changed = false
			for j in range(segments.size()):
				if used[j]:
					continue
				var seg = segments[j]
				if seg.start.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.end)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.start)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.start)
					used[j] = true
					changed = true
				elif seg.start.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.end)
					used[j] = true
					changed = true
		result.append(polyline)
	return result


# ── Host-access helpers (moved verbatim from MCPPcbPanelTools.gd; now the
#    SOLE copy — the core module that used to keep its own is deleted) ──────

## The live board model off a host, or null (duck-typed — host may lack the getter).
static func _get_data(host):
	if host == null or not host.has_method("get_board_data"):
		return null
	return host.get_board_data()


## The spatial index off a host, or null (duck-typed).
static func _get_spatial(host):
	if host == null or not host.has_method("get_spatial_index"):
		return null
	return host.get_spatial_index()


## Resolve host -> board model in one step, returning either the model
## (Object) or a ready-to-return error Dictionary. Callers guard with
## `if not (data is Object)`. Unlike the old core module's _resolve_data,
## there is no editor_name/host resolution here — the dispatcher already
## handed us a live host — so the only failure mode left is a host without a
## board model (defensive; never hit against a mounted PCBPanel).
static func _resolve_data(host) -> Variant:
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	return data


# ── Envelope builders (self-contained, mirrors MCPCadTools/MCPPcbPanelTools) ──

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
