extends RefCounted
## PCB panel-executed MCP tool surface — wave 1 (DCR 019f6c3d0e3d, C2 round,
## docket 019f6c45f09e).
##
## The 16 wave-1 tool bodies MOVED VERBATIM from Minerva core's
## MCPPcbPanelTools.gd (see Docs/design/panel-executed-tools.md §3 migration
## table): set_board_size, get_components, get_nets, get_pin_position,
## pin_info, add_component, move_component, move_relative, rotate_component,
## delete_component, connect_net, spatial_query, describe_component,
## import_csv, export_csv, import_footprint_geometry. Tool names, arg
## validation, result shapes, and error messages are preserved EXACTLY —
## existing test suites assert against them unmodified.
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
## Off-tree note: this file lives OUTSIDE Minerva's res:// tree, so it MUST
## NOT declare a class_name — preloaded by relative path from PCBPanel.gd
## (matches the convention every other pcb/ui/*.gd file already follows).

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


# ── Host-access helpers (copied from MCPPcbPanelTools.gd — wave-2 keeps its
#    own copy in core since get_change_journal/import_export_trace_geometry/
#    get_image still need them there) ──────────────────────────────────────

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
