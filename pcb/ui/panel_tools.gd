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
## T1.5: the ONE canonical layer/via-span contract (top/bottom <-> F.Cu/B.Cu).
const PcbLayerStack := preload("model/pcb_layer_stack.gd")
## A7: the plugin-scoped preference store. The SAME process-wide instance the
## panel reads (pcb_prefs.shared()), which is what makes an agent's write and a
## human's turn of the width box two views of one value rather than two stores.
const _PcbPrefsScript := preload("model/pcb_prefs.gd")
## B2 (MCP parity round): static-func + const access for the zone outline
## helpers (zone_outline_to_list/zone_outline_points, MIN_ZONE_OUTLINE_POINTS)
## without depending on GDScript's instance-forwarding for consts across a
## duck-typed `data` reference — mirrors pcb_canvas.gd's own PCBDataScript
## const, same off-tree preload-by-path convention.
const _PcbDataScript := preload("model/pcb_data.gd")
## C4a: the disposition legality vocabulary (DISPOSITIONS, TERMINAL_DISPOSITIONS
## and the named refusal codes). Preloaded so the workspace verb tools NAME their
## refusals from the canonical const set instead of re-listing it — a second copy
## of the terminal set is a second thing to keep in step with the legality table.
const _PcbRouteCandidateScript := preload("model/pcb_route_candidate.gd")
## C5 (S3+S4, DCR 019fb572b888): the pure bus-geometry module (S1+S2, shipped
## and pinned by test_pcb_bus_geometry.gd — a standing pin this file consumes
## and never edits). Zero imports itself.
const BusGeom := preload("model/pcb_bus_geometry.gd")

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
		"minerva_pcb_delete_traces":
			return _delete_traces(host, args)
		"minerva_pcb_get_image":
			return await _get_image(host, args)
		"minerva_pcb_set_view":
			return _set_view(host, args)
		"minerva_pcb_apply_route_hints":
			return await _apply_route_hints(host, args)
		"minerva_pcb_hint_undo":
			return _hint_undo(host, args)
		"minerva_pcb_hint_redo":
			return _hint_redo(host, args)
		"minerva_pcb_add_via":
			return _add_via(host, args)
		"minerva_pcb_load_board":
			return await _load_board(host, args)
		"minerva_pcb_list_zones":
			return _list_zones(host, args)
		"minerva_pcb_describe_zone":
			return _describe_zone(host, args)
		"minerva_pcb_delete_zone":
			return _delete_zone(host, args)
		"minerva_pcb_set_zone_net":
			return _set_zone_net(host, args)
		"minerva_pcb_set_zone_layer":
			return _set_zone_layer(host, args)
		"minerva_pcb_set_trace_width":
			return _set_trace_width(host, args)
		"minerva_pcb_list_vias":
			return _list_vias(host, args)
		"minerva_pcb_delete_via":
			return _delete_via(host, args)
		"minerva_pcb_get_preference":
			return _get_preference(host, args)
		"minerva_pcb_set_preference":
			return _set_preference(host, args)
		"minerva_pcb_create_zone":
			return _create_zone(host, args)
		"minerva_pcb_set_zone_outline":
			return _set_zone_outline(host, args)
		"minerva_pcb_list_cutouts":
			return _list_cutouts(host, args)
		"minerva_pcb_describe_cutout":
			return _describe_cutout(host, args)
		"minerva_pcb_create_cutout":
			return _create_cutout(host, args)
		"minerva_pcb_delete_cutout":
			return _delete_cutout(host, args)
		"minerva_pcb_group_components":
			return _group_components(host, args)
		"minerva_pcb_ungroup":
			return _ungroup(host, args)
		"minerva_pcb_set_group_member_offset":
			return _set_group_member_offset(host, args)
		"minerva_pcb_get_layout_state":
			return _get_layout_state(host, args)
		# ── C4a: the routing-workspace VERB surface (S4, DCR 019f7095c395) ────
		"minerva_pcb_workspace_propose":
			return await _workspace_propose(host, args)
		"minerva_pcb_workspace_list":
			return _workspace_list(host, args)
		"minerva_pcb_workspace_get_active":
			return _workspace_get_active(host, args)
		"minerva_pcb_workspace_pin":
			return _workspace_pin(host, args)
		"minerva_pcb_workspace_unpin":
			return _workspace_unpin(host, args)
		"minerva_pcb_workspace_reject":
			return _workspace_reject(host, args)
		"minerva_pcb_workspace_commit":
			return _workspace_commit(host, args)
		"minerva_pcb_workspace_reroute_route":
			return await _workspace_reroute_route(host, args)
		"minerva_pcb_workspace_reroute_span":
			return await _workspace_reroute_span(host, args)
		"minerva_pcb_workspace_check":
			return await _workspace_check(host, args)
		# ── C5: the bus tool's MCP parity surface (S3+S4, DCR 019fb572b888) ────
		"minerva_pcb_route_bus_direct":
			return _route_bus_direct(host, args)
		# ── Bus-propose (docket 019fcac1509d): the bus's PROPOSAL verb ────────
		"minerva_pcb_workspace_propose_bus":
			return await _workspace_propose_bus(host, args)
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
		# Group membership (A4), ADDITIVE and emitted only for a grouped
		# component — a group-free board's reply is unchanged key for key. An
		# agent has no other way to discover that moving this part will move
		# others, and the move/rotate/delete tools all behave as a unit on it.
		if comp.is_grouped():
			comp_info["group_id"] = comp.group_id()
			comp_info["group_members"] = data.group_member_ids(comp.group_id())
			comp_info["group_anchor"] = data.group_anchor_id(comp.group_id())
			comp_info["group_offset"] = {
				"x": data.member_offset(comp.id).x, "y": data.member_offset(comp.id).y}
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

	data.add_component(comp)
	data.save_to_history("Add " + component_id)

	return _ok({
		"component_id": component_id,
		"x": comp.position.x,
		"y": comp.position.y,
		"pin_count": comp.pins.size(),
	})


## Pad-coincidence epsilon (board mm) for the dangling-copper sweep below.
## Trace endpoints land ON pad centres (the router snaps them there), so this
## only absorbs float noise from the transform math.
const _DANGLE_EPSILON_MM := 0.05


## Mutation honesty for component transforms (docket 019fce619a30, same family
## as load_board's delta and the landing verbs' cross_candidate_check): copper
## does NOT follow parts, so a move/rotate can orphan committed traces that
## ended on the part's pads — and in HITL-3 that orphan surfaced two calls
## later as a DRC dangling_endpoint instead of in the mover's own reply.
##
## `pre_pins_by_comp` maps component_id -> get_all_pin_positions() captured
## BEFORE the transform (one entry for a single move, one per member for a
## group move). After the transform, every committed trace endpoint that sat
## on one of those pre-transform pads and now touches NONE of that component's
## pads is named: trace_id, net, position. The caller appends the result as
## `dangling_copper` — advisory only, never a refusal (the move already
## happened, honestly and undoably; this is the map to the mess).
static func _dangling_copper_warnings(data, pre_pins_by_comp: Dictionary) -> Array:
	var warnings: Array = []
	for comp_id in pre_pins_by_comp:
		var comp = data.get_component(str(comp_id))
		if comp == null:
			continue
		var pre_pins: Dictionary = pre_pins_by_comp[comp_id]
		var post_pins: Dictionary = comp.get_all_pin_positions()
		for trace_id in data.traces:
			var trace = data.traces[trace_id]
			var wp: Array = trace.waypoints
			if wp.size() < 2:
				continue
			for endpoint in [wp[0] as Vector2, wp[wp.size() - 1] as Vector2]:
				var was_on_pad := false
				for pin_name in pre_pins:
					if (pre_pins[pin_name] as Vector2).distance_to(endpoint) <= _DANGLE_EPSILON_MM:
						was_on_pad = true
						break
				if not was_on_pad:
					continue
				var still_on_pad := false
				for pin_name in post_pins:
					if (post_pins[pin_name] as Vector2).distance_to(endpoint) <= _DANGLE_EPSILON_MM:
						still_on_pad = true
						break
				if not still_on_pad:
					warnings.append({
						"trace_id": str(trace.id),
						"net": str(trace.net_name),
						"at": [endpoint.x, endpoint.y],
						"component_id": str(comp_id),
						"message": "trace endpoint at (%.2f, %.2f) on net '%s' sat on a %s pad before this transform and now dangles — copper does not follow parts; delete it (minerva_pcb_delete_traces) or reroute" \
							% [endpoint.x, endpoint.y, str(trace.net_name), str(comp_id)],
					})
	return warnings


## Pre-transform pad snapshot for _dangling_copper_warnings: the addressed
## component, plus every group member when it is grouped (a group transform
## moves ALL their pads).
static func _pre_transform_pins(data, component_id: String) -> Dictionary:
	var out: Dictionary = {}
	var ids: Array = [component_id]
	var group_id: String = str(data.component_group_id(component_id))
	if not group_id.is_empty() and data.has_method("group_member_ids"):
		for mid in data.group_member_ids(group_id):
			if not (str(mid) in ids):
				ids.append(str(mid))
	for cid in ids:
		var comp = data.get_component(str(cid))
		if comp != null:
			out[str(cid)] = comp.get_all_pin_positions()
	return out


## Append the dangling-copper sweep to a successful transform reply (no-op on
## refusals and on a clean sweep, so untouched boards see untouched replies).
static func _with_dangling_copper(data, reply: Dictionary, pre_pins_by_comp: Dictionary) -> Dictionary:
	if not bool(reply.get("success", false)):
		return reply
	var warnings: Array = _dangling_copper_warnings(data, pre_pins_by_comp)
	if not warnings.is_empty():
		reply["dangling_copper"] = warnings
	return reply


static func _move_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Component not found: %s" % component_id)

	var pre_pins: Dictionary = _pre_transform_pins(data, component_id)
	var new_pos: Vector2 = data.snap_to_grid(Vector2(float(args.get("x", 0.0)), float(args.get("y", 0.0))))
	# A GROUPED component moves the WHOLE group, offsets preserved — the same
	# semantics a canvas drag has (A4). Ungrouped: unchanged, byte for byte.
	var group_reply := _move_component_group(data, component_id, new_pos)
	if not group_reply.is_empty():
		return _with_dangling_copper(data, group_reply, pre_pins)
	data.move_component(component_id, new_pos)
	data.save_to_history("Move " + component_id)
	return _with_dangling_copper(data,
		_ok({"component_id": component_id, "x": new_pos.x, "y": new_pos.y}), pre_pins)


## Shared group-move half of move_component / move_relative.
##
## Returns {} when `component_id` is UNGROUPED — the caller then runs its original
## single-component path untouched, which is what keeps a group-free board's tool
## behaviour identical. Otherwise it performs the whole-group translation and
## returns the finished MCP reply.
##
## The reply is ADDITIVE: component_id / x / y still describe the ADDRESSED
## component exactly as before (it does land on the requested point — the rest of
## the group moves by the same delta), with group_id / moved_components /
## moved_count added for a caller that wants to know the move was a unit move.
##
## ONE undo step via begin_batch/end_batch, the same pair the canvas drag closes
## with, rather than N save_to_history calls.
static func _move_component_group(data, component_id: String, new_pos: Vector2) -> Dictionary:
	var group_id: String = str(data.component_group_id(component_id))
	if group_id.is_empty():
		return {}
	if data.is_group_locked(group_id):
		return _err("Group is locked — %s cannot be moved" % component_id)
	var delta: Vector2 = new_pos - data.get_component(component_id).position
	data.begin_batch()
	var moved: Array = data.translate_group(component_id, delta)
	data.end_batch("Move group (%d)" % moved.size())
	return _ok({
		"component_id": component_id,
		"x": new_pos.x,
		"y": new_pos.y,
		"group_id": group_id,
		"moved_components": moved,
		"moved_count": moved.size(),
	})


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
	var reply := {
		"component_id": component_id,
		"new_x": new_pos.x,
		"new_y": new_pos.y,
		"interpreted_direction": direction,
	}
	if data.has_component(component_id):
		var pre_pins: Dictionary = _pre_transform_pins(data, component_id)
		# Group parity with _move_component: a grouped component carries its whole
		# group to the interpreted destination. The reply keeps new_x/new_y (the
		# ADDRESSED component's landing point) and adds the group fields.
		var group_reply := _move_component_group(data, component_id, data.snap_to_grid(new_pos))
		if not group_reply.is_empty():
			if not bool(group_reply.get("success", false)):
				return group_reply  # locked group — surface the refusal verbatim
			for key in ["group_id", "moved_components", "moved_count"]:
				reply[key] = group_reply[key]
			return _with_dangling_copper(data, _ok(reply), pre_pins)
		data.move_component(component_id, data.snap_to_grid(new_pos))
		data.save_to_history("Move " + component_id)
		return _with_dangling_copper(data, _ok(reply), pre_pins)

	return _ok(reply)


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

	var pre_pins: Dictionary = _pre_transform_pins(data, component_id)
	# A GROUPED component rotates its whole group as a RIGID BODY about the group
	# anchor (positions orbit, every member's own rotation turns) — the same thing
	# R does on the canvas for a group selection. The requested rotation is
	# ABSOLUTE for the addressed component, so the group's turn is the DELTA that
	# gets that component there; every other member turns by the same amount.
	var group_id: String = str(data.component_group_id(component_id))
	if not group_id.is_empty():
		if data.is_group_locked(group_id):
			return _err("Group is locked — %s cannot be rotated" % component_id)
		data.begin_batch()
		var turned: Array = data.rotate_group(component_id, new_rotation - comp.rotation)
		data.end_batch("Rotate group (%d)" % turned.size())
		return _with_dangling_copper(data, _ok({
			"component_id": component_id,
			"rotation": comp.rotation,
			"group_id": group_id,
			"rotated_components": turned,
			"rotated_count": turned.size(),
		}), pre_pins)

	data.rotate_component(component_id, new_rotation)
	data.save_to_history("Rotate " + component_id)
	return _with_dangling_copper(data,
		_ok({"component_id": component_id, "rotation": new_rotation}), pre_pins)


static func _delete_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Component not found: %s" % component_id)

	# A GROUPED component deletes its WHOLE group (A4) — the group is one physical
	# part, so removing one of its footprints and leaving the rest is a delete no
	# caller can mean. ONE undo step (the batch pair), and `deleted` still names
	# the addressed component so the existing reply field keeps its meaning.
	var group_id: String = str(data.component_group_id(component_id))
	if not group_id.is_empty():
		if data.is_group_locked(group_id):
			return _err("Group is locked — %s cannot be deleted" % component_id)
		data.begin_batch()
		var removed: Array = data.remove_group(component_id)
		data.end_batch("Delete group (%d)" % removed.size())
		return _ok({
			"deleted": component_id,
			"group_id": group_id,
			"deleted_components": removed,
			"deleted_count": removed.size(),
		})

	data.remove_component(component_id)
	data.save_to_history("Delete " + component_id)
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
		# Canonical resolved-vs-fallback marker is has_pad_geometry (Stage 2
		# step 7); legacy footprint_found still accepted for older output.
		if comp_geometry.get("has_pad_geometry", comp_geometry.get("footprint_found", false)):
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
		# A caller-supplied trace_id (as emitted by _export_trace_geometry) is
		# part of the GROUPING key, not just carried along: two distinct traces
		# on the same net+layer must not be merged into one polyline group just
		# because they share a net. Segments with no trace_id fall into the
		# shared ""-id group and keep the historical net+layer merge behaviour.
		var supplied_trace_id: String = str(seg.get("trace_id", ""))
		var key := "%s|%s|%s" % [supplied_trace_id, net_name, layer]
		if not trace_groups.has(key):
			trace_groups[key] = {
				"trace_id": supplied_trace_id,
				"net_name": net_name,
				"layer": PcbLayerStack.kicad_to_canon(layer),
				"width": seg.get("width", 0.3),
				"segments": [],
			}
		var start = seg.get("start", {})
		var end_pt = seg.get("end", {})
		trace_groups[key].segments.append({
			"start": Vector2(start.get("x", 0), start.get("y", 0)),
			"end": Vector2(end_pt.get("x", 0), end_pt.get("y", 0)),
		})

	# Reserve every supplied trace id BEFORE creating anything, so the result
	# does not depend on the caller's segment ordering: an unnamed group listed
	# ahead of a supplied "trace_1" would otherwise auto-mint "trace_1" first and
	# be silently overwritten (PCBData.traces is keyed by id). See
	# PCBData.reserve_trace_id.
	for key in trace_groups:
		data.reserve_trace_id(str(trace_groups[key].trace_id))

	var trace_count := 0
	var imported_trace_ids: Array = []
	# One supplied id can be worn by exactly ONE trace per import, so the claim
	# has to be tracked ACROSS groups, not per group. The group key is
	# trace_id|net|layer, so a single supplied id appearing on two layers (or two
	# nets) produces TWO groups; when the claim lived inside the group loop both
	# assigned it and the second silently OVERWROTE the first in PCBData.traces
	# (id-keyed Dictionary) — copper destroyed while the reply reported both as
	# landed. Keyed by id, so a group whose id was already taken falls through to
	# the auto-mint exactly like an unnamed one.
	var claimed_trace_ids: Dictionary = {}
	for key in trace_groups:
		var group = trace_groups[key]
		var polylines := _build_polylines_from_segments(group.segments)
		for polyline in polylines:
			if polyline.size() < 2:
				continue
			var trace = data.new_trace()
			# Honour the caller's id so export -> filter -> import round-trips
			# identity instead of renumbering positionally (the old
			# "trace_%d" % trace_count, which made every id a function of
			# iteration order and silently renamed everything on every import).
			# An empty id is left empty on purpose: PCBData.add_trace then mints
			# from its own monotonic counter, which high-waters past supplied
			# ids so an auto-mint can never collide with one.
			#
			# One supplied id can only be worn by ONE trace (PCBData.traces is
			# keyed by id — reusing it would overwrite). The FIRST claimant keeps
			# it and every later one is minted fresh, so no copper is lost to a
			# silent overwrite. This holds both WITHIN a group (one supplied id
			# resolving to several disconnected polylines) and ACROSS groups (the
			# same id sent on two layers or two nets) — see claimed_trace_ids.
			var wanted_id: String = str(group.trace_id)
			if not wanted_id.is_empty() and not claimed_trace_ids.has(wanted_id):
				claimed_trace_ids[wanted_id] = true
				trace.id = wanted_id
			trace.net_name = group.net_name
			trace.layer = group.layer
			trace.width = group.width
			for point in polyline:
				trace.waypoints.append(point)
			data.add_trace(trace)
			imported_trace_ids.append(str(trace.id))
			trace_count += 1

	var vias_input: Array = trace_data.get("vias", [])
	# Same up-front reservation for vias (see PCBData.reserve_via_id): an
	# id-less via ahead of a supplied "via_1" would auto-mint that same id and
	# leave two vias sharing one handle.
	for via_data in vias_input:
		data.reserve_via_id(str(via_data.get("id", "")))

	var imported_via_ids: Array = []
	# Via twin of claimed_trace_ids: one supplied via id is worn by exactly ONE
	# via per import, first claimant keeps it, later ones mint fresh.
	#
	# SEPARATE from the trace claim set on purpose. Traces and vias are distinct
	# id spaces ("trace_N" vs "via_N") backed by distinct counters
	# (_next_trace_id / _next_via_id), so a trace id must never be able to block
	# a via id or vice versa. Two sets, one rule.
	#
	# Unlike the trace case nothing is overwritten — vias are a list, so a
	# duplicate loses no copper. What it breaks is the identity contract:
	# PCBData.remove_via_by_id resolves the FIRST match only, so a second via
	# wearing the same id is permanently undeletable by id, and delete_traces
	# would report that id as deleted while a via wearing it survives. This is
	# precisely the hazard PCBData.reserve_via_id's doc describes; the claim is
	# what actually prevents it.
	var claimed_via_ids: Dictionary = {}
	for via_data in vias_input:
		var pos = via_data.get("position", {})
		var via_entry := {
			"position": Vector2(pos.get("x", 0), pos.get("y", 0)),
			"size": via_data.get("size", 0.8),
			"drill": via_data.get("drill", 0.4),
			"net_name": via_data.get("net_name", ""),
			"layers": via_data.get("layers", PcbLayerStack.default_via_kicad_layers()),
		}
		# Same round-trip rule as traces. The "id" key is set only when the
		# caller supplied one AND it is still unclaimed — add_via reads its
		# ABSENCE as "mint me a fresh id" and its presence as "keep this one, and
		# high-water past it".
		var supplied_via_id: String = str(via_data.get("id", ""))
		if not supplied_via_id.is_empty() and not claimed_via_ids.has(supplied_via_id):
			claimed_via_ids[supplied_via_id] = true
			via_entry["id"] = supplied_via_id
		imported_via_ids.append(data.add_via(via_entry))

	data.save_to_history("Import traces")
	# trace_ids/via_ids report the identities that actually landed, so a caller
	# can verify preservation without a second export round trip.
	return _ok({
		"trace_count": trace_count,
		"via_count": vias_input.size(),
		"trace_ids": imported_trace_ids,
		"via_ids": imported_via_ids,
	})


## Targeted removal of a SUBSET of committed copper (docket 019f809798d1).
##
## Before this existed the only deletion path was import_trace_geometry, which
## clears the whole board and re-imports — so removing one trace meant exporting
## every trace, filtering outside the tool, and pushing the entire replacement
## set back through context.
##
## Selection is by IDENTITY only — `trace_ids`, `via_ids`, `net_name` — and the
## three combine as a UNION. There is deliberately NO spatial/region selector:
## a region predicate has to make a silent judgement about a trace that CROSSES
## the boundary, and this project's standing ruling is that routing/DRC/CAM fail
## closed rather than approximate copper. Now that export_trace_geometry stamps
## a trace_id on every segment and an id on every via, a caller does its own
## spatial filtering against real coordinates and then names exactly what it
## chose. Partial-trace CLIPPING (splitting a trace at a boundary) is likewise
## not offered — see the remaining-gap note in the plugin docs.
##
## `net_name` selects TRACES only, never vias. A via sitting on that net is
## copper the caller did not name, and deciding it is now orphaned is exactly
## the kind of judgement this surface refuses to make; name the via by id.
##
## PARTIAL SUCCESS IS A SUCCESS, and it is reported. A caller naming five ids of
## which two are stale gets the three deletions applied and the two stale ids
## back in `missing_trace_ids`/`missing_via_ids`. Failing the whole call would
## punish a caller for holding a slightly old view of the board and would make a
## retry of a partly-applied delete impossible; silently succeeding would hide
## that the board is not what the caller thought. Only a MALFORMED request (no
## selector at all) is an error.
##
## Absent vs empty in the reply: `missing_trace_ids` is present only when
## `trace_ids` was supplied, so [] honestly means "we checked your ids, none
## were stale" while ABSENT means "you named no trace ids, so there was nothing
## to check". Same for `missing_via_ids`/`via_ids` and for
## `net_name`/`net_match_count`.
##
## Undo: a delete that changed anything ends with save_to_history, exactly as
## _import_trace_geometry does, so one undo restores the removed traces and
## vias (PCBData.save_to_history snapshots both — see its F1 note). A delete
## that removed nothing takes no snapshot: an undo step that undoes nothing is
## noise in the history.
static func _delete_traces(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data

	var has_trace_ids: bool = args.has("trace_ids")
	var has_via_ids: bool = args.has("via_ids")
	var net_name: String = str(args.get("net_name", ""))
	var has_net: bool = not net_name.is_empty()
	if not (has_trace_ids or has_via_ids or has_net):
		return _err("at least one of trace_ids, via_ids or net_name is required")

	# ── Phase 1: resolve the whole selection against the board as the caller
	# sees it, BEFORE mutating anything. Resolving first is what makes
	# net_match_count unambiguous (it counts the net's traces on the untouched
	# board, not on a board already thinned by the trace_ids pass) and keeps the
	# union free of double-counting.
	var trace_ids_to_delete: Array[String] = []
	var missing_trace_ids: Array[String] = []
	var selected: Dictionary = {}

	if has_trace_ids:
		for raw_id in (args.get("trace_ids", []) as Array):
			var tid := str(raw_id)
			if selected.has(tid):
				continue
			selected[tid] = true
			# An EMPTY id is reported as missing, never skipped. Skipping it made
			# {"trace_ids": [""]} return missing_trace_ids: [], i.e. "we checked
			# your ids and none were stale" about a request that checked nothing —
			# the absent-vs-empty rule broken in the direction that matters most,
			# a confident all-clear for a call that did nothing. It is reachable:
			# a via/trace from a board file predating stable ids has no id key, so
			# a caller mapping `.get("id", "")` over an exported list sends "".
			# Reported rather than rejected because an unusable handle is a stale
			# selector, not a malformed request — the same reason a non-existent
			# id does not fail the call. Rejecting would also punish a caller that
			# named nine good ids and one id-less item.
			if tid.is_empty() or data.get_trace(tid) == null:
				missing_trace_ids.append(tid)
			else:
				trace_ids_to_delete.append(tid)

	var net_match_count := 0
	if has_net:
		for trace in data.get_traces_for_net(net_name):
			net_match_count += 1
			var tid := str(trace.id)
			if selected.has(tid):
				continue
			selected[tid] = true
			trace_ids_to_delete.append(tid)

	var via_ids_to_delete: Array[String] = []
	var missing_via_ids: Array[String] = []
	var via_selected: Dictionary = {}
	if has_via_ids:
		for raw_id in (args.get("via_ids", []) as Array):
			var vid := str(raw_id)
			if via_selected.has(vid):
				continue
			via_selected[vid] = true
			# Empty id reported, not skipped — see the trace pass above for the
			# reasoning.
			#
			# Note there is deliberately NO `vid.is_empty() or` short-circuit
			# here: PCBData.find_via_index is the single authority on "does any
			# via carry this id", the empty case included. Short-circuiting would
			# duplicate that knowledge in two places AND leave find_via_index's
			# own empty-id guard unexecuted — which is exactly what happened, and
			# a guard nothing reaches is a guard nothing tests. Routing "" through
			# it is what makes it load-bearing: without that guard "" matches the
			# first via carrying NO id key (str(v.get("id","")) == "") and deletes
			# a legacy via the caller never named.
			#
			# The trace pass above keeps its explicit is_empty() check because
			# there is no equivalent helper to hold the rule — get_trace is a bare
			# Dictionary lookup — so the selector has to state it inline.
			if data.find_via_index(vid) < 0:
				missing_via_ids.append(vid)
			else:
				via_ids_to_delete.append(vid)

	# ── Phase 2: apply. Traces go by id through PCBData.remove_trace; vias go by
	# id through remove_via_by_id, NEVER by index — remove_via is positional and
	# every removal shifts the vias after it, so a loop over indices captured in
	# phase 1 would delete the wrong vias.
	var deleted_trace_ids: Array[String] = []
	for tid in trace_ids_to_delete:
		data.remove_trace(tid)
		deleted_trace_ids.append(tid)

	var deleted_via_ids: Array[String] = []
	for vid in via_ids_to_delete:
		if data.remove_via_by_id(vid):
			deleted_via_ids.append(vid)
		else:
			# Only reachable if the board changed under us between phases.
			missing_via_ids.append(vid)

	if not deleted_trace_ids.is_empty() or not deleted_via_ids.is_empty():
		data.save_to_history("Delete traces")

	var reply := {
		"deleted_trace_ids": deleted_trace_ids,
		"deleted_trace_count": deleted_trace_ids.size(),
		"deleted_via_ids": deleted_via_ids,
		"deleted_via_count": deleted_via_ids.size(),
		"remaining_trace_count": data.get_trace_ids().size(),
		"remaining_via_count": data.vias.size(),
	}
	if has_trace_ids:
		reply["missing_trace_ids"] = missing_trace_ids
	if has_via_ids:
		reply["missing_via_ids"] = missing_via_ids
	if has_net:
		reply["net_name"] = net_name
		reply["net_match_count"] = net_match_count
	return _ok(reply)


static func _export_trace_geometry(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data

	var traces_output: Array = []
	for trace_id in data.get_trace_ids():
		var trace = data.get_trace(trace_id)
		if not trace:
			continue
		# canon_to_kicad FAILS CLOSED since epoch 6 unit 3a: "" means "this is not
		# a copper layer I can name". ABORT the whole export rather than emit a
		# blank `layer` — this payload feeds fabrication geometry, and a segment
		# whose layer is "" is copper of unknown side. Naming the trace and the
		# offending layer makes the bad record findable in the board.
		var layer_name: String = PcbLayerStack.canon_to_kicad(trace.layer)
		if layer_name.is_empty():
			return _err("export_trace_geometry: trace \"%s\" is on layer \"%s\", which is not a copper layer this contract can name (expected top/bottom/in1..in30 or F.Cu/B.Cu/In<k>.Cu). Export aborted — fix the trace's layer." % [trace_id, str(trace.layer)])
		for i in range(trace.waypoints.size() - 1):
			var start_pt: Vector2 = trace.waypoints[i]
			var end_pt: Vector2 = trace.waypoints[i + 1]
			traces_output.append({
				# EVERY segment carries the id of the trace it came from. A trace
				# is a polyline, so its N-1 segments all repeat the SAME
				# trace_id — that is the intended relationship (it is what tells
				# a caller which segments are one piece of copper), not a
				# duplicate to be de-duplicated. Without it nothing in this
				# payload NAMES a trace and coordinates are the only handle,
				# which is why targeted deletion used to be impossible.
				"trace_id": trace_id,
				"start": {"x": snapped(start_pt.x, 0.0001), "y": snapped(start_pt.y, 0.0001)},
				"end": {"x": snapped(end_pt.x, 0.0001), "y": snapped(end_pt.y, 0.0001)},
				"width": trace.width,
				"layer": layer_name,
				"net_name": trace.net_name,
			})

	var vias_output: Array = []
	for via in data.vias:
		var pos: Vector2 = via.get("position", Vector2.ZERO)
		var via_out := {
			"position": {"x": snapped(pos.x, 0.0001), "y": snapped(pos.y, 0.0001)},
			"size": via.get("size", 0.8),
			"drill": via.get("drill", 0.4),
			"net_name": via.get("net_name", ""),
			"layers": via.get("layers", PcbLayerStack.default_via_kicad_layers()),
		}
		# PCBData.add_via mints a stable id for every via it accepts, so in
		# practice this key is always present. It is emitted CONDITIONALLY
		# because a via restored from a legacy board file predating stable via
		# ids genuinely has none — and an absent key ("this via has no identity")
		# is a different claim from an empty string ("its identity is blank").
		# A caller can then tell that the via is not addressable by
		# minerva_pcb_delete_traces rather than sending "" and getting nothing.
		var via_id: String = str(via.get("id", ""))
		if not via_id.is_empty():
			via_out["id"] = via_id
		vias_output.append(via_out)

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
## Pan/zoom the board camera so an agent (and the human watching the panel) can
## view items at different scales. Drives the LIVE canvas view; capture it with
## minerva_pcb_get_image {fit:false}. Precedence (first present wins):
##   component_id  — frame one component (optional margin_mm)
##   region        — frame a world-mm rect {x_mm,y_mm,width_mm,height_mm}
##   center_x_mm/center_y_mm/zoom — set centre (mm) + zoom (px/mm); any omitted
##                   axis/zoom keeps its current value
##   zoom_factor   — multiply current zoom (>1 in, <1 out), centre fixed
##   fit:true      — frame the whole board
## Returns {view:{zoom, center_x_mm, center_y_mm, visible:{...}}}.
static func _set_view(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("get_canvas"):
		return _err("PCB view control not available")
	var canvas = host.get_canvas()
	if canvas == null or not is_instance_valid(canvas):
		return _err("PCB canvas not available (panel detached/headless)")

	if args.has("component_id"):
		var data = _get_data(host)
		var cid: String = str(args["component_id"])
		if not (data is Object) or not (cid in data.components):
			return _err("component not found: %s" % cid)
		var comp = data.components[cid]
		if not comp.has_method("get_bounding_rect"):
			return _err("component has no bounds: %s" % cid)
		canvas.frame_rect(comp.get_bounding_rect(), float(args.get("margin_mm", 2.0)))
	elif args.has("region"):
		var r = args["region"]
		if not (r is Dictionary):
			return _err("region must be an object {x_mm,y_mm,width_mm,height_mm}")
		var rect := Rect2(float(r.get("x_mm", 0.0)), float(r.get("y_mm", 0.0)),
			float(r.get("width_mm", 0.0)), float(r.get("height_mm", 0.0)))
		canvas.frame_rect(rect, float(args.get("margin_mm", 0.0)))
	elif args.has("center_x_mm") or args.has("center_y_mm") or args.has("zoom"):
		var cur: Dictionary = canvas.get_view() if canvas.has_method("get_view") else {}
		canvas.set_view_center_zoom(
			Vector2(float(args.get("center_x_mm", cur.get("center_x_mm", 0.0))),
				float(args.get("center_y_mm", cur.get("center_y_mm", 0.0)))),
			float(args.get("zoom", cur.get("zoom", 4.0))))
	elif args.has("zoom_factor"):
		canvas.zoom_by(float(args["zoom_factor"]))
	elif bool(args.get("fit", false)):
		if canvas.has_method("zoom_to_fit"):
			canvas.zoom_to_fit()
	else:
		return _err("set_view needs one of: component_id, region, "
			+ "center_x_mm/center_y_mm/zoom, zoom_factor, or fit:true")

	var view: Dictionary = canvas.get_view() if canvas.has_method("get_view") else {}
	return _ok({"view": view})


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

	# Render the board OFF-SCREEN at the requested size (bug 019f7876e3d4): the
	# old "screenshot the window viewport + crop" path returned only the editor
	# background for a plugin-hosted / non-foreground panel and ignored width/
	# height. capture_to_image builds its own SubViewport so the capture is
	# independent of tab focus and honors the size. fit defaults TRUE (whole
	# board); fit=false reproduces the current minerva_pcb_set_view camera (a
	# zoomed-in detail). This whole call is already awaited by handle().
	var want_fit: bool = bool(args.get("fit", true))
	var width: int = int(args.get("width", 800))
	var height: int = int(args.get("height", 600))

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
	var canvas = host.get_canvas() if host.has_method("get_canvas") else null
	if canvas != null and is_instance_valid(canvas) and canvas.has_method("capture_to_image"):
		img = await canvas.capture_to_image(width, height, want_fit)
	elif host.has_method("render_content_to_image"):
		# Legacy fallback (headless / a host without a canvas).
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
	var new_kp: Dictionary = result.get("kind_payload", kp)
	new_ann["kind_payload"] = new_kp
	if not host.update_annotation(id, new_ann):
		return _err("failed to persist via insertion for '%s'" % id)

	# T2.3 bridged Add-Via: DESIGN CHOICE = route-through (not disable). Add-Via is
	# a first-class capability that fires on the SAME propose-originated proposals
	# that dual-write always bridges, so disabling it would break the common case.
	# Instead, re-derive the correlated candidate's geometry from the SAME updated
	# raw route (the recomputed segments + the appended via) so both stores stay
	# geometrically identical — never one mutated without the other.
	var bridged_synced := false
	var workspace = _get_workspace(host)
	if workspace != null and workspace.has_method("candidate_for_annotation"):
		var cand_id := str(workspace.candidate_for_annotation(id))
		if not cand_id.is_empty() and workspace.has_method("sync_candidate_geometry"):
			var new_segments: Array = result.get("segments", []) if result.get("segments", []) is Array else []
			var new_vias: Array = new_kp.get("vias", []) if new_kp.get("vias", []) is Array else []
			bridged_synced = bool(workspace.sync_candidate_geometry(cand_id, new_segments, new_vias))

	return _ok({
		"via_count": result.get("via_count", 0),
		"segments": result.get("segments", []),
		"bridged_candidate_synced": bridged_synced,
	})


# ── Route-correction collaboration loop (moved verbatim from
#    MCPPcbPanelTools.gd, C3 round) ───────────────────────────────────────────
#
# minerva_pcb_apply_route_hints closes the route-correction loop (agent-router
# child 019eb47eb567). The propose→inspect→apply→iterate flow:
#
#   1. PROPOSE (commit absent/false): gather the board's OPEN pcb_route_hint
#      annotations (or the given hint_ids) and route them through the worker.
#      S5 removal (C4b, DCR 019f7095c395): the routed polylines land as
#      RouteCandidates in the panel's RoutingWorkspace — NOT as AI-authored
#      proposal annotations. The workspace is the sole propose store now (this
#      is the exact landing path minerva_pcb_workspace_propose uses). The
#      reply's `proposals` array is a RESULT-DERIVED summary (net/layer/
#      waypoint_count/width_mm/drc_geometric/source_hint_ids/candidate_id) kept
#      in the pre-S5 shape on purpose — see _propose_into_workspace. Proposing
#      does NOT mutate the board — the user inspects candidates on the canvas
#      or via minerva_pcb_workspace_list/get_active first.
#   2. APPLY (commit=true): re-route the selected open hints and MATERIALIZE the
#      results as real traces in the model (journaled via save_to_history), then
#      transition the source hints open→applied. Returns applied/traces_added.
#      Unaffected by S5 — this branch never wrote annotations.
#   3. ITERATE: applied hints are excluded from the default (open) gather; a
#      workspace candidate is never itself gathered as a source hint (only
#      pcb_route_hint ANNOTATIONS are), so re-running after the user edits/adds
#      hints picks up only the fresh open hints.
#
# FAILURE AS FEEDBACK: partial/failed routing returns WHERE it got stuck —
# result.unrouted (net + blocked pad pair) surfaced as `stuck`, plus bridge
# warnings — structured data the agent can reason about, not a bare "failed".
#
# RETIRED (S5, C4b): minerva_pcb_proposal_accept/_reject, the per-proposal
# annotation verbs. A candidate landed by PROPOSE above is resolved through
# minerva_pcb_workspace_commit/_reject(candidate_id) — or the canvas candidate
# context menu — never through an annotation id.

static func _apply_route_hints(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var hint_ids: Array = args.get("hint_ids", [])
	var commit: bool = bool(args.get("commit", false))

	# MF-2(b1) (review): reconcile BEFORE gathering — a hint left "applied" by
	# a since-undone commit (see _reconcile_hint_lifecycle's doc: the two-store
	# undo gap means a plain data.undo() cannot revert it synchronously) must
	# reopen to "open" before _gather_route_hints' default (open-only) scope
	# decides whether to offer it to THIS run. Reconciling only inside
	# _workspace_ctx (the workspace tools' own entry point) would leave a
	# stranded hint skipped for one full apply_route_hints call — this is the
	# OTHER production entry point onto the same gather, and needs the same
	# fix. No workspace bound (headless / before mount) is a silent no-op,
	# same as every other duck-typed workspace touch in this function.
	var workspace_for_reconcile = _get_workspace(host)
	if workspace_for_reconcile != null:
		_reconcile_hint_lifecycle(host, workspace_for_reconcile)

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
	return _propose_into_workspace(host, data, result, source_hints)


## Reach the router worker through the in-fence host bridge (async). The host
## forwards to the panel's broker request path. Returns the worker's {ok, result}
## envelope, or a structured worker_unavailable when no bridge is reachable
## (headless / channel not registered — see the WORKER-INVOCATION note in the
## contract doc).
## `extra` (DCR finding 7) carries the optional `scope`/`pinned_candidates` keys
## through to PCBPanel.route_board — see _route_request_extra. Every existing
## caller passes one argument and gets the default {}, so the wire payload it
## produces is unchanged.
static func _run_router(host, selection: Dictionary, extra: Dictionary = {}) -> Dictionary:
	if host != null and host.has_method("run_router"):
		return await host.run_router(selection, extra)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "host has no run_router bridge to the router worker"}}


## Build the `extra` argument _run_router forwards to route_board: pinned-
## candidate keep-outs (DCR finding 7 part 1) plus an explicit `scope` (part 2),
## each added ONLY when there is something to say. Nothing pinned and no scope
## derived -> {} -> route_board stamps neither key -> the pre-existing
## {board, route_hints, selection} wire payload, byte-for-byte (the no-regression
## requirement: "absent scope keeps today's behavior byte-identical").
static func _route_request_extra(workspace, scope) -> Dictionary:
	var out: Dictionary = {}
	if workspace != null:
		var pinned: Array = workspace.pinned_candidates_wire()
		if not pinned.is_empty():
			out["pinned_candidates"] = pinned
	if scope is Dictionary and not (scope as Dictionary).is_empty():
		out["scope"] = scope
	return out


## Non-empty net_names entries, in order, exactly as route_bridge._net_for_hint
## / hints_to_router read them (kp.get("net_names") filtered on `str(n)`).
static func _hint_net_names(kp: Dictionary) -> Array:
	var out: Array = []
	for n in _string_list(kp.get("net_names", [])):
		if n != "":
			out.append(n)
	return out


## Board net names as a lookup set, for the "is this name actually on the
## board" check both scope builders below need (mirrors `n in board.nets` /
## `n in board.nets` on the worker side, against this panel's own PCBData).
static func _board_net_set(data) -> Dictionary:
	var out: Dictionary = {}
	if data != null:
		for n in data.get_net_names():
			out[str(n)] = true
	return out


## True iff `kp` enters route_bridge.hints_to_router's BUS BRANCH:
## `hint_type == "bus" and len(names) >= 2` — the worker's own ENTRY
## condition, mirrored exactly, NOT the outcome once inside it. Board presence
## is deliberately NOT checked here (review fix c2-epochD, round 2): a hint
## that enters the branch but resolves to <2 PRESENT nets is DEGENERATE —
## hints_to_router still `continue`s past it contributing ZERO nets (see
## "bus hint resolved to <2 present nets — skipped") rather than falling back
## to _net_for_hint's single-net rule. So inside the branch there are only two
## outcomes, multi-net (>=2 present) or zero (<2 present), and NEITHER is the
## single name this panel could express as `scope.nets` — a first cut that
## required `present >= 2` here left the zero-contribution case
## mis-classified as "not a bus hint", falling through to the names[0] rule
## and emitting a scope for a net the worker resolved NOTHING from (proven:
## methods.py's disagreement check then passes and overwrites only_nets with
## it). A hint_type=="bus" hint with FEWER than 2 net_names never enters this
## branch at all worker-side — it falls to _net_for_hint like any other
## hint — so it is correctly EXCLUDED here too (len(names) < 2 -> false).
static func _is_bus_branch_hint(kp: Dictionary) -> bool:
	if str(kp.get("hint_type", "waypoint")) != "bus":
		return false
	return _hint_net_names(kp).size() >= 2


## Scope for a REROUTE (DCR finding 7 part 2; review fix c2-epochD, docket
## 019fc1b0db34): the candidate's OWN task/net — but ONLY when that net is the
## UNAMBIGUOUS resolution of the SAME source hints this reroute selects.
##
## PROVEN REGRESSION this guards against: a BUS-BRANCH hint (see
## _is_bus_branch_hint — hint_type=="bus" with >=2 net_names, mirroring the
## worker's branch ENTRY condition, not its outcome) is NOT resolved by
## _net_for_hint's names[0]-only rule — route_bridge.hints_to_router gives it a
## dedicated branch whose only two outcomes are "every PRESENT net in the bus"
## or, degenerately, "zero nets" (see _is_bus_branch_hint's doc — neither is a
## single name this panel can express). Selecting that hint (this reroute
## always selects the candidate's OWN source_hint_ids) therefore makes the
## worker's hint-derived nets diverge from a scope naming only THIS
## candidate's single net — disagreement, hard refusal (parse_route_scope
## refuses rather than narrows), for EITHER candidate the bus produced, since
## both select the same hint. So: if any source hint feeding this reroute is a
## bus-branch hint, skip the scope entirely; the reroute still runs, unscoped,
## exactly as before this fix.
##
## `endpoints` is deliberately omitted from the task entry: an endpoints list
## would ask parse_route_scope to validate a SPAN, and a reroute always means
## "the whole route for this task" (reroute-span is the documented degrade to
## whole-route, see _workspace_reroute_span) — never a span, so omitting it
## resolves to the whole net.
static func _reroute_scope(c, source_hints: Array, _data) -> Dictionary:
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if _is_bus_branch_hint(kp):
			return {}
	return {"tasks": [{"task_id": str(c.task_id), "net": str(c.net)}]}


## Scope for a PROPOSE with an explicit hint_ids selection (DCR finding 7 part
## 2; review fix c2-epochD, docket 019fc1b0db34): the nets EVERY selected hint
## resolves to, mirroring route_bridge._net_for_hint / hints_to_router's
## resolution EXACTLY rather than approximating it — the prior version unioned
## the WHOLE net_names array per hint, which is neither of the worker's two
## real resolution rules and was PROVEN to both under- and over-scope:
##   - a stale names[0] (renamed/removed net) that the worker falls through to
##     resolve via source_pins/dest_pins would make this panel scope to the
##     stale name while the worker routes the resolved one — disagreement,
##     hard unsupported_scope, where an unscoped run used to work.
##   - a NON-bus hint with >1 net_names (_net_for_hint only ever trusts
##     names[0]) would scope to BOTH names; methods.py's disagreement check
##     passes (the worker's one resolved net is a subset) and then OVERWRITES
##     only_nets with the full (too-wide) scope — silently routing a net
##     nothing asked for.
##   - a DEGENERATE bus hint (hint_type=="bus", >=2 net_names, but FEWER than
##     2 of them present on the board) enters hints_to_router's bus branch and
##     contributes ZERO nets there (see _is_bus_branch_hint) — a first cut that
##     required the bus's PRESENT count to be >=2 before treating it as "a bus"
##     mis-classified this case as "not a bus", fell through to the names[0]
##     rule, and emitted a scope for a net the worker resolved NOTHING from;
##     methods.py's disagreement check then passed (0 resolved nets is always
##     a subset) and overwrote only_nets with that phantom scope.
##
## The mirror, per selected hint:
##   - a BUS-BRANCH hint (see _is_bus_branch_hint — the worker's branch ENTRY
##     condition, hint_type=="bus" with >=2 net_names, checked WITHOUT regard
##     to how many resolve) is a DIFFERENT rule from the single-net one below,
##     with only two possible outcomes (multi-net or degenerate-zero) and
##     NEITHER is a single name this panel can express — so its presence bails
##     the WHOLE scope to unscoped, same as an unresolvable hint. This is an
##     entry-condition check, not an outcome check: it must not be narrowed by
##     re-deriving present-count here, or the degenerate case reopens.
##   - otherwise: drop empty strings, take names[0] ONLY (never the rest of
##     the array), and trust it only if the board actually carries it — the
##     exact _net_for_hint priority up to and including its board-membership
##     check. A hint with no usable name here falls through to WORKER-SIDE pin
##     resolution (source_pins/dest_pins against the compiled board), which
##     this panel cannot replicate — so it bails the whole scope too.
##
## Built only when EVERY selected hint resolves this way with total
## confidence; any hint this panel cannot mirror exactly takes the WHOLE
## propose back to unscoped (the established completely-derivable-or-nothing
## rule) rather than guess a scope that could disagree with what the worker
## actually routes.
static func _propose_scope(hint_ids: Array, source_hints: Array, data) -> Variant:
	if hint_ids.is_empty():
		return null
	var board_nets: Dictionary = _board_net_set(data)
	var nets := {}
	var tasks: Array = []
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if _is_bus_branch_hint(kp):
			return null  # a different resolution rule — not mirrored here
		# SPAN FORM first (docket 019fcb6f9d20 — the ask is the task boundary):
		# a hint carrying explicit source+dest pins that all resolve to ONE
		# board net becomes a span task — the worker routes exactly that span
		# (route_bridge parse_route_scope -> engine net_terminals) instead of
		# widening to the whole net and stitching islands the ask never named.
		var span: Dictionary = _span_task_for_hint(hint, kp, data, board_nets)
		if not span.is_empty():
			tasks.append(span)
			continue
		var names: Array = _hint_net_names(kp)
		if names.is_empty():
			return null  # falls through to pin resolution worker-side
		var first: String = names[0]
		if not board_nets.has(first):
			return null  # stale name — worker falls through to pin resolution
		nets[first] = true
	if nets.is_empty() and tasks.is_empty():
		return null
	var scope := {}
	if not tasks.is_empty():
		scope["tasks"] = tasks
	if not nets.is_empty():
		scope["nets"] = nets.keys()
	return scope


## The span-task mirror of the worker's pin resolution, kept to the same
## completely-derivable-or-nothing discipline as the net rule above: {} unless
## the hint carries 1+ source AND 1+ dest pins, every pin resolves on the live
## board, and they all agree on ONE net the board carries. Any ambiguity
## returns {} so the hint falls back to the net rule (or takes the whole scope
## to unscoped) rather than shipping a span the worker would refuse.
static func _span_task_for_hint(hint: Dictionary, kp: Dictionary, data, board_nets: Dictionary) -> Dictionary:
	if data == null:
		return {}
	var src: Array = kp.get("source_pins", []) if kp.get("source_pins", []) is Array else []
	var dst: Array = kp.get("dest_pins", []) if kp.get("dest_pins", []) is Array else []
	if src.is_empty() or dst.is_empty():
		return {}
	var endpoints: Array = []
	var net := ""
	for pin_ref in src + dst:
		var ref := str(pin_ref)
		var comp := ref.rsplit(".", true, 1)
		if comp.size() != 2 or String(comp[0]).is_empty() or String(comp[1]).is_empty():
			return {}
		var pin_net := str(data.find_net_for_pin(String(comp[0]), String(comp[1])))
		if pin_net.is_empty():
			return {}
		if net.is_empty():
			net = pin_net
		elif pin_net != net:
			return {}  # endpoints disagree on the net — not a clean span
		if not endpoints.has(ref):
			endpoints.append(ref)
	if net.is_empty() or not board_nets.has(net) or endpoints.size() < 2:
		return {}
	return {
		"task_id": str(hint.get("id", "")),
		"net": net,
		"endpoints": endpoints,
	}


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


## T2.3 normalization seam: derive ONE normalized route record per route, ONCE,
## from the raw router `result` + the propose call's source hints. BOTH shadow
## projections — the annotation proposal (_write_records_as_proposals below) and
## the RouteCandidate (RoutingWorkspace.ingest_record) — are then derived from
## the SAME record, so they are guaranteed to describe identical geometry rather
## than being two independent parses of `result` that can silently drift.
##
## A record carries the RAW router geometry verbatim (segments in
## {start,end,layer} shape, vias positional [x,y]) so the annotation stores it
## losslessly (U2) AND the workspace parses the exact same bytes into its
## canonical candidate — plus the once-resolved provenance/width and the flattened
## polyline/layer the annotation badge needs. `source_hints` rides along so the
## workspace resolves width/hint-ids/endpoints from the identical inputs the
## annotation side used.
static func _normalize_route_records(result: Dictionary, source_hints: Array) -> Array:
	var records: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var rec: Dictionary = {
			"net": net,
			"segments": (route.get("segments", []) as Array).duplicate(true) if route.get("segments", []) is Array else [],
			"vias": (route.get("vias", []) as Array).duplicate(true) if route.get("vias", []) is Array else [],
			"width": _width_for_net(source_hints, net),
			"source_hint_ids": _route_hint_ids(route),
			"polyline": _route_polyline(route),
			"layer": _route_layer(route),
			"source_hints": source_hints,
		}
		# DRC-at-propose (docket 019f6f1492e0): carry the worker's per-route "drc"
		# verdict ONLY when present (absent-key ⇒ no badge contract preserved).
		if route.has("drc"):
			rec["drc"] = route.get("drc")
		# GEOMETRIC DRC-at-propose (docket 019f98b24284): same absent-key contract
		# for the copper verdict — see methods.py _attach_route_geometric_drc.
		# This is what closes the gap where a proposal shorting a different-net
		# pad reported "clean" because only the centreline (connectivity) check
		# above was ever attached to a route.
		if route.has("drc_geometric"):
			rec["drc_geometric"] = route.get("drc_geometric")
		records.append(rec)
	return records


## PROPOSE (S5, C4b, DCR 019f7095c395): routed polylines → RouteCandidates in
## the panel's RoutingWorkspace. RETIRED: this used to also write an
## AI-authored cyan proposal ANNOTATION per record
## (_write_back_proposals/_write_records_as_proposals/_write_one_proposal,
## dual-written alongside the workspace ingest by _dual_write_propose during
## the T2 shadow phase). The workspace is the sole propose store now — no
## annotation is written, so there is nothing left for
## minerva_pcb_proposal_accept/_reject to act on; those two tools are RETIRED
## in the same change (see docs/tools.md). The board is NOT mutated by this
## call either way.
##
## The reply's `proposals` array is kept in the PRE-S5 shape on purpose
## (net/layer/waypoint_count/width_mm/drc_geometric/source_hint_ids) — it is
## RESULT-derived, never annotation-derived, so PCBPanel's status-line
## rendering (_offending_nets/_geometric_status_suffix, out of this unit's
## fence) needs no change. `id`/`candidate_id` in each entry is the WORKSPACE
## candidate id: resolve it via minerva_pcb_workspace_commit/_reject/pin, or
## the canvas candidate menu — never via an annotation id.
static func _propose_into_workspace(host, data, result: Dictionary, source_hints: Array) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]

	var records: Array = _normalize_route_records(result, source_hints)
	var revision: int = int(data.board_revision) if data != null else 0
	var proposals: Array = []
	var holds: Array = []
	for rec in records:
		var pts: Array = rec.get("polyline", [])
		if pts.size() < 2:
			continue  # degenerate polyline — _write_one_proposal used to skip these too
		var cid: String = str(workspace.ingest_record(rec, revision))
		# last_ingest_holds is PER CALL and ingest_record resets it on entry — see
		# _ingest_result_into_workspace's identical accumulation-in-loop note.
		for hold in workspace.last_ingest_holds:
			holds.append(hold)
		if cid.is_empty():
			continue  # HELD — the task's active candidate is pinned; see `holds`
		var entry: Dictionary = {
			"id": cid,
			"candidate_id": cid,
			"net": str(rec.get("net", "")),
			"layer": str(rec.get("layer", "F.Cu")),
			"waypoint_count": pts.size(),
			"source_hint_ids": rec.get("source_hint_ids", []),
			"width_mm": float(rec.get("width", 0.0)),
		}
		# DRC-at-propose (docket 019f6f1492e0): the per-route CONNECTIVITY verdict
		# (absent-key ⇒ older worker / non-canonical path that skipped the attach).
		# This used to be stamped ONLY on the annotation's kind_payload.drc
		# (_write_one_proposal) — with no annotation to carry it, the reply is
		# now the only place it can land; added here for parity with
		# drc_geometric below rather than silently dropping the field.
		if rec.has("drc"):
			entry["drc"] = rec.get("drc")
		# GEOMETRIC DRC-at-propose (docket 019f98b24284): stamp THIS candidate's
		# own verdict (absent-key ⇒ older worker, same contract as "drc" above)
		# so a caller can name WHICH candidate is geometrically dirty instead of
		# only knowing the batch contains a violation somewhere.
		if rec.has("drc_geometric"):
			entry["drc_geometric"] = rec.get("drc_geometric")
		proposals.append(entry)

	return _ok({
		"committed": false,
		"proposed": proposals.size(),
		"proposals": proposals,
		"holds": holds,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
		"drc_summary": result.get("drc_summary", {}),
		# GEOMETRIC DRC-at-propose (docket 019f98b24284): the candidate-scoped
		# union — findings/per_candidate attributed to route[<i>], PLUS the
		# board's own pre-existing "baseline" violations kept SEPARATE (see
		# ir_candidates.check_candidates) — alongside drc_summary above. NEVER
		# merge the two: drc_summary answers connectivity, this answers copper,
		# and PCBPanel._geometric_status_suffix reads only this key so a dirty
		# baseline can never mark a clean proposal dirty (or vice versa).
		"drc_geometric_summary": result.get("drc_geometric_summary", {}),
		"stale_candidate_ids": _stale_ids(workspace),
		"note": "candidates landed in the routing workspace; no proposal annotation was written (S5, DCR 019f7095c395) — resolve via minerva_pcb_workspace_commit/_reject(candidate_id) or the canvas candidate menu",
	})


## The panel's RoutingWorkspace off a host (duck-typed through the same
## host→panel back-reference run_router/route_board use), or null when no panel
## is bound (headless / before mount) or it exposes no workspace.
static func _get_workspace(host):
	if host == null or not host.has_method("get_panel"):
		return null
	var panel = host.get_panel()
	if panel == null or not is_instance_valid(panel) or not panel.has_method("get_routing_workspace"):
		return null
	return panel.get_routing_workspace()


## APPLY: materialize routed polylines as real traces (journaled) + transition
## source hints open→applied. Per-layer segment grouping mirrors
## import_trace_geometry so multi-layer routes become correct single-layer traces.
static func _materialize_routes(host, data, result: Dictionary, source_hints: Array) -> Dictionary:
	var traces_added := 0
	var failed: Array = []
	# T2.3: stable ids of the copper this materialization created, so a bridged
	# accept can record them on its candidate (ResolvedBoard IR references
	# committed copper by these ids, which survive to_board_dict()/reload).
	var created_trace_ids: Array = []
	var created_via_ids: Array = []
	# Hint ids earned by a route that actually laid copper, collected AT the
	# point of success (019fa109b43c) rather than re-derived afterward by
	# re-looping over `result.routes` — that re-loop could not tell success
	# from failure without re-deriving `failed`, which is exactly the bug.
	var succeeded_hint_ids: Array = []
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
				trace.layer = PcbLayerStack.kicad_to_canon(lyr)
				trace.width = width
				for point in polyline:
					trace.waypoints.append(point)
				data.add_trace(trace)
				created_trace_ids.append(str(trace.id))
				traces_added += 1
				made_any = true
		if not made_any:
			# 019fa109b43c, Defect B: a route with no usable segments produced
			# no copper. Its via(s), if any, would be unreachable-by-redo
			# orphans (the F1 class this file's history-snapshot fix was
			# written to close, on the other side of the seam) AND would
			# assert an answer to a hint that was never carried out. Skip the
			# via loop below entirely for this route — no copper, no via.
			failed.append({"net": net, "reason": "no usable segments in routed result"})
			continue
		# 019fa109b43c, Defect A: record this route's hint ids HERE, inside the
		# made_any success path — not by re-looping over result.routes below,
		# which could not distinguish a succeeded route from a failed one
		# without redoing the `failed` computation above.
		for hid in _route_hint_ids(route):
			if not (hid in succeeded_hint_ids):
				succeeded_hint_ids.append(hid)
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
		var _via_span: Array = PcbLayerStack.default_through_via_span()
		for via in route.get("vias", []):
			created_via_ids.append(data.add_via({
				"position": _via_position(via),
				"size": via_size,
				"drill": via_drill,
				"net_name": net,
				"from_layer": _via_span[0],
				"to_layer": _via_span[1],
			}))

	# Snapshot AFTER mutation so the undo/redo checkpoint captures the applied
	# traces (undo() restores the PREVIOUS entry — matches _import_trace_geometry;
	# snapshotting before would leave the applied state unrecoverable on redo).
	if traces_added > 0:
		data.save_to_history("Apply route hints")

	# MF-2(b2) UNIFIED (narrow re-review, 2026-08-02, adjudicated — no
	# escalation needed): this used to DELETE an accepted hint once its real
	# trace existed (HITL-2, 2026-07-16) — that was the LEGACY-era reading.
	# The owner-visible contract manifest.json's own apply_route_hints text
	# states, and minerva_pcb_workspace_commit now also implements
	# (_workspace_commit, above), is open→applied, never delete: a hint is
	# durable intent/commentary, and _gather_route_hints' default (open-only)
	# scope already excludes non-open lifecycle, so an applied hint is
	# excluded from the next iterate without having to be gone. Both commit
	# paths (workspace-native and this bulk one) now close the SAME way.
	# RECORDED for HITL: the owner may still veto this unification
	# ("materialize now marks applied instead of deleting" is on the rulings
	# list) — applied here per review adjudication, not an independent
	# new ruling. Proposals answering a consumed hint (kind_payload.
	# proposal_for) are still removed with it — that sweep is proposal-annotation
	# cleanup (S5 already retires proposal annotations entirely), unrelated
	# to the hint's own lifecycle.
	var consumed_ids: Array = []
	if traces_added > 0:
		var to_close: Array = []
		if failed.is_empty():
			to_close = _hint_id_list(source_hints)
		else:
			# Attribution comes from the worker's own per-route "hint_ids"
			# (methods.py _hint_ids_by_net, docket 019f9c3a136c) rather than
			# re-derived net-name matching — it also covers source_pins/dest_pins,
			# so the BLANKET "every selected hint" claim is gone: a hint for a net
			# this reply never mentions is no longer swept up.
			#
			# 019fa109b43c: to_close is succeeded_hint_ids, accumulated above
			# INSIDE the route loop's made_any success path — never re-derived
			# here by re-looping over result.routes. A route that landed in
			# `failed` never reached that accumulation, so its hints are excluded
			# here, not merely deprioritized: a hint is consumed only when the
			# route it answers actually laid copper.
			to_close = succeeded_hint_ids.duplicate()
		for hid in to_close:
			if str(hid).is_empty():
				continue
			if _set_hint_lifecycle(host, str(hid), "applied"):
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
		"trace_ids": created_trace_ids,
		"via_ids": created_via_ids,
		"failed": failed,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
	}


## RETIRED (S5, C4b, DCR 019f7095c395): _proposal_accept / _proposal_reject —
## the per-proposal annotation verbs behind minerva_pcb_proposal_accept/_reject
## — are removed. PROPOSE no longer writes a proposal annotation
## (_propose_into_workspace, above) for either of them to act on; a landed
## candidate is resolved through minerva_pcb_workspace_commit(candidate_id) /
## minerva_pcb_workspace_reject(candidate_id) instead, which own the exact same
## concerns these used to (commit shares _materialize_routes' trace synthesis
## transitively via RoutingWorkspace.commit; reject flips disposition→rejected
## and leaves source hints open for iteration). _materialize_routes' own
## removed_proposal_ids sweep (below) is left in place, unchanged, as a
## defensive cleanup for legacy proposal annotations a pre-S5 .pcbskel may
## still carry — see the load-time migration notice in PCBPanel.gd.


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


## The worker's own per-route attribution (docket 019f9c3a136c), verbatim.
## methods.py `_hint_ids_by_net` resolves net_names + source_pins + dest_pins
## — strictly more than the panel could re-derive from net_names alone — and
## is the reason this reads the worker's answer instead of re-deriving one.
##
## Three states collapse to two outcomes (the per-route `hint_ids` stamp in
## `methods.py` `_route`, guarded by `if envelopes:`, is the spec):
##   - `hint_ids` key ABSENT   -> no hints were supplied at all (unhinted
##     whole-board run); the worker omits the key rather than sending `[]`
##     because `[]` would read as "no hint wanted this" when the truth is "no
##     hint was asked".
##   - `hint_ids` present, []  -> hints WERE supplied, none named this net.
##   - `hint_ids` present, non-empty -> those exact ids, verbatim.
## Absent and [] mean different things but produce the same correct output
## here (empty) — Dictionary.get(..., []) naturally collapses them without
## needing to branch on `route.has("hint_ids")`.
##
## NEVER falls back to "every source hint" — that blanket claim was the bug
## (019f9c3a136c): _materialize_routes consumes (marks applied) exactly the hints
## named here, and a landed workspace candidate's source_hint_ids is this same
## list — either way, overclaiming silently drops/misattributes a hint the
## user never got routed. An empty result here is correct and must stay empty.
static func _route_hint_ids(route: Dictionary) -> Array:
	return _string_list(route.get("hint_ids", []))


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


# ── Zone tools (A6, docket 019fb9206e81 MCP zone parity) ─────────────────────
# MCP parity for the zone surface the canvas already has (round A5 select/edit,
# the delete slice): same journalled model path (data.remove_zone /
# data.set_zone_net / data.set_zone_layer), so an agent mutation and a human
# canvas edit are indistinguishable to pcb_data — including the data_changed
# signal each of those model calls already emits, which is what repaints the
# human's canvas live (pcb_canvas.set_data wires data.data_changed ->
# _on_data_changed -> queue_redraw; nothing new was added here or there).

## List every zone, summary shape. Read-only — journals nothing.
static func _list_zones(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var zones_arr: Array = []
	for zone in data.zones:
		zones_arr.append({
			"zone_id": str(zone.get("id", "")),
			"kind": data.zone_kind(zone),
			"net": str(zone.get("net", "")),
			"layer": str(zone.get("layer", "")),
			"point_count": data.zone_outline_points(zone).size(),
		})
	return _ok({"zone_count": zones_arr.size(), "zones": zones_arr})


## List every board via (item 019fbb96cf). Read-only — journals nothing.
##
## WHY THIS EXISTS when export_trace_geometry already emits a vias[] block: that
## tool's payload is FABRICATION geometry — it aborts the whole export when any
## trace sits on a layer it cannot name, it emits KiCad layer names, and it walks
## every trace segment on the board to produce them. An agent that only wants to
## know which vias exist should not have to survive an unrelated trace's bad
## layer, nor parse thousands of segments to reach the via list. The two are kept
## agreeing by construction all the same: both read data.vias directly, and both
## emit `id` only when the via really carries one.
##
## THIS IS NOT THE PARTNER OF minerva_pcb_add_via. That tool edits a route-hint
## PROPOSAL annotation, not the board (it splits a proposed segment and inserts a
## via into the proposal), so it neither creates nor can name anything listed
## here. Board vias are created by committing routes — apply_route_hints with
## commit, or import_trace_geometry. The honest siblings of this tool are
## minerva_pcb_delete_via (below) and minerva_pcb_delete_traces' via_ids.
##
## ID-LESS VIAS ARE LISTED, with the key absent rather than blank — the same
## claim export_trace_geometry makes: a via from a board file predating stable
## via ids genuinely has no identity, and "absent" says that, while "" would
## claim its identity is the empty string. Such a via cannot be deleted by id and
## cannot be clicked on the canvas either; both surfaces agree about that.
static func _list_vias(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var vias_arr: Array = []
	for via in data.vias:
		var pos: Vector2 = data.via_position(via)
		var entry := {
			"x_mm": snapped(pos.x, 0.0001),
			"y_mm": snapped(pos.y, 0.0001),
			"net_name": str(via.get("net_name", "")),
			"from_layer": str(via.get("from_layer", "")),
			"to_layer": str(via.get("to_layer", "")),
			"size_mm": float(via.get("size", 0.8)),
			"drill_mm": float(via.get("drill", 0.4)),
		}
		var via_id: String = str(via.get("id", ""))
		if not via_id.is_empty():
			entry["via_id"] = via_id
		vias_arr.append(entry)
	return _ok({"via_count": vias_arr.size(), "vias": vias_arr})


## Delete ONE board via by id — one journalled, undoable step.
##
## The single-target twin of minerva_pcb_delete_traces' via_ids array, and the
## agent's half of what the human's Delete key and eraser now do on the canvas.
## Both ride the SAME model call (remove_via_by_id) and the same undo history, so
## an agent's delete and a human's are indistinguishable to the board.
##
## Mutate-then-snapshot (bug 019fb5ad791c): remove first, save_to_history after —
## snapshotting before the removal makes redo silently replay the pre-delete
## state. remove_via_by_id journals the "remove_via" entry itself; this owes only
## the single history step, per the model's house rule that no mutator snapshots
## itself.
##
## Unknown (or empty) via_id is an explicit error, never a silent no-op — the
## same contract delete_zone keeps. The empty case is routed through the model's
## find_via_index rather than short-circuited here, for the reason _delete_traces
## spells out: "" would otherwise match the first via carrying no id key and
## delete copper the caller never named, and the guard that prevents it must stay
## the one being executed.
static func _delete_via(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var via_id: String = str(args.get("via_id", ""))
	var via: Dictionary = data.get_via(via_id)
	if via.is_empty():
		return _err("Unknown via: %s" % via_id)
	# Read the reply fields BEFORE the removal — afterwards the dict is off the
	# board and `data.vias` no longer holds it.
	var pos: Vector2 = data.via_position(via)
	var net_name: String = str(via.get("net_name", ""))
	if not data.remove_via_by_id(via_id):
		return _err("Unknown via: %s" % via_id)
	data.save_to_history("Delete via " + via_id)
	return _ok({
		"deleted": via_id,
		"net_name": net_name,
		"x_mm": snapped(pos.x, 0.0001),
		"y_mm": snapped(pos.y, 0.0001),
		"remaining_via_count": data.vias.size(),
	})


## Describe one zone in full, including its outline. Read-only — journals
## nothing. The outline is round-tripped through zone_outline_points (parse) ->
## zone_outline_to_list (re-encode) rather than returned raw, so a malformed
## stored outline still comes back as a clean, canonical {x_mm,y_mm} list —
## the same normalisation the model's own writers rely on.
static func _describe_zone(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var zone_id: String = str(args.get("zone_id", ""))
	if zone_id.is_empty():
		return _err("zone_id is required")
	var zone: Dictionary = data.get_zone(zone_id)
	if zone.is_empty():
		return _err("Unknown zone: %s" % zone_id)
	var pts: PackedVector2Array = data.zone_outline_points(zone)
	return _ok({
		"zone_id": zone_id,
		"kind": data.zone_kind(zone),
		"net": str(zone.get("net", "")),
		"layer": str(zone.get("layer", "")),
		"point_count": pts.size(),
		"outline": data.zone_outline_to_list(pts),
	})


## Delete a zone. Mirrors _delete_component's idiom: mutate then
## save_to_history (mutate-then-snapshot, bug 019fb5ad791c — snapshotting
## before the removal would make redo silently do nothing), ONE undo step, and
## a reply that names what was deleted. Unknown zone_id is an explicit error,
## never a silent no-op.
static func _delete_zone(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var zone_id: String = str(args.get("zone_id", ""))
	if zone_id.is_empty():
		return _err("zone_id is required")
	var zone: Dictionary = data.get_zone(zone_id)
	if zone.is_empty():
		return _err("Unknown zone: %s" % zone_id)
	if not data.remove_zone(zone_id):
		return _err("Unknown zone: %s" % zone_id)
	data.save_to_history("Delete zone " + zone_id)
	return _ok({
		"deleted": zone_id,
		"kind": data.zone_kind(zone),
		"net": str(zone.get("net", "")),
		"layer": str(zone.get("layer", "")),
	})


## Re-assign a zone's net. data.set_zone_net returns "" for BOTH a real write
## and "no change needed", so this copies the current-value guard PCBPanel's
## own net picker uses (_on_zone_prop_net_selected, ~PCBPanel.gd:1221): compare
## the zone's stored net to the requested one FIRST, and reply a no-op success
## without ever calling the model or journalling — an unguarded caller would
## push an empty undo step (cold-review F3 in pcb_data.gd's own docs). A real
## write is exactly one save_to_history call. Every model refusal (keepout,
## undeclared net) surfaces verbatim as an _err.
static func _set_zone_net(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var zone_id: String = str(args.get("zone_id", ""))
	if zone_id.is_empty():
		return _err("zone_id is required")
	var zone: Dictionary = data.get_zone(zone_id)
	if zone.is_empty():
		return _err("Unknown zone: %s" % zone_id)
	var net_name: String = str(args.get("net_name", ""))
	if str(zone.get("net", "")) == net_name:
		return _ok({"zone_id": zone_id, "net": net_name, "changed": false})
	var refusal: String = data.set_zone_net(zone_id, net_name)
	if not refusal.is_empty():
		return _err(refusal)
	data.save_to_history("Set zone net")
	return _ok({"zone_id": zone_id, "net": net_name, "changed": true})


## Re-assign a zone's copper layer. Same no-op guard as set_zone_net, and same
## source (PCBPanel._on_zone_prop_layer_selected, ~PCBPanel.gd:1246) —
## INCLUDING its asymmetry: an empty layer never short-circuits the guard
## (there is no legitimate "current" empty layer to match), so it always
## reaches the model and comes back as that setter's own refusal ("no layer
## stack", "layer not declared"). Every model refusal surfaces verbatim as an
## _err.
static func _set_zone_layer(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var zone_id: String = str(args.get("zone_id", ""))
	if zone_id.is_empty():
		return _err("zone_id is required")
	var zone: Dictionary = data.get_zone(zone_id)
	if zone.is_empty():
		return _err("Unknown zone: %s" % zone_id)
	var layer: String = str(args.get("layer", ""))
	if not layer.is_empty() and str(zone.get("layer", "")) == layer:
		return _ok({"zone_id": zone_id, "layer": layer, "changed": false})
	var refusal: String = data.set_zone_layer(zone_id, layer)
	if not refusal.is_empty():
		return _err(refusal)
	data.save_to_history("Set zone layer")
	return _ok({"zone_id": zone_id, "layer": layer, "changed": true})


# ── Zone geometry parity (B2, item 019fbb964c) ───────────────────────────────
# create_zone/set_zone_outline round out the A6 zone surface (list/describe/
# delete/set_net/set_layer) with authoring + geometry editing, so the whole
# zone lifecycle is agent-reachable the way the canvas' A5 drawing tool and
# vertex-drag already are. Both ride the MODEL path only — data.create_zone /
# data.set_zone_outline — never the board-YAML round trip (the A6 lazy-fix
# catch: a tool that serializes/reloads to make an edit takes a different,
# untested path from every human gesture and drifts from it silently).

## Parse an MCP outline arg ([{x_mm,y_mm}, ...]) into a PackedVector2Array, or
## null when malformed — the ONE parser shared by create_zone and
## set_zone_outline so a bad point is rejected identically by both.
static func _parse_zone_outline(raw) -> Variant:
	if not (raw is Array):
		return null
	var pts := PackedVector2Array()
	for p in raw:
		if not (p is Dictionary) or not p.has("x_mm") or not p.has("y_mm"):
			return null
		pts.append(Vector2(float(p["x_mm"]), float(p["y_mm"])))
	return pts


## Author a new zone (pour or keepout) and add it to the board. ONE journalled
## undo step: data.create_zone already record_change's + data_changed's
## internally (mirrors add_component's own idiom), so this owes only the
## closing save_to_history.
##
## The refusal text is produced by calling data.zone_author_error OURSELVES,
## ahead of create_zone, rather than reading create_zone's return — create_zone
## only push_warning()s its reason to the console and returns {} either way, so
## the model's real, verbatim refusal string (unknown net, unknown layer, too
## few points, no layer) has to be asked for explicitly to reach the caller.
## zone_author_error is the SAME rule create_zone itself runs, so the tool
## invents no wording of its own — see zone_author_error's own docs for why
## the net/layer clauses are ordered points-first.
static func _create_zone(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var kind: String = str(args.get("kind", "copper_pour"))
	var net_name: String = str(args.get("net", ""))
	var layer: String = str(args.get("layer", ""))
	# Cold review F5: a genuinely ABSENT `outline` key must say so, not fall
	# through args.get's [] default into zone_author_error and come back as
	# "needs at least 3 points (0 placed)" — truthful, but not the actual
	# problem (the arg was never given).
	if not args.has("outline"):
		return _err("outline is required: an array of {x_mm, y_mm} points")
	var pts = _parse_zone_outline(args.get("outline"))
	if pts == null:
		return _err("outline points need x_mm and y_mm")
	var refusal: String = data.zone_author_error(net_name, layer, pts.size(), kind)
	if not refusal.is_empty():
		return _err(refusal)
	var zone: Dictionary = data.create_zone(net_name, layer, pts, kind)
	if zone.is_empty():
		# Defensive only — zone_author_error above already cleared every known
		# refusal, so create_zone succeeding is the expected path.
		return _err("Zone could not be created.")
	data.save_to_history("Create zone")
	return _ok({
		"zone_id": str(zone.get("id", "")),
		"kind": data.zone_kind(zone),
		"net": str(zone.get("net", "")),
		"layer": str(zone.get("layer", "")),
		"point_count": data.zone_outline_points(zone).size(),
	})


## Replace a committed zone's outline wholesale — the MCP counterpart of the
## canvas' vertex-drag commit (pcb_canvas._end_zone_vertex_drag /
## _journal_zone_outline_edit). Journals the SAME "edit_zone_outline" shape
## that reader already parses (zone_id, op, vertex_index, old_point_count,
## point_count), with op="set_outline" and vertex_index=-1 marking a
## whole-outline replace rather than a single-vertex edit — no existing reader
## requires vertex_index, so widening the op vocabulary is additive.
##
## NO-CHANGE GUARD compares the point LISTS VALUE-WISE (Vector2 == Vector2),
## not the raw dicts set_zone_outline stores them as — a caller resubmitting
## the same outline in a different dict key order or float formatting must
## still land on changed:false, exactly like set_zone_net/set_zone_layer's
## guard on their scalar fields. set_zone_outline itself is a LIVE-DRAG WRITER
## (silent about a real write, vocal about a refusal — see its own docs), so
## this tool owns the journal + one save_to_history the same way the canvas'
## drag-end commit does.
static func _set_zone_outline(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var zone_id: String = str(args.get("zone_id", ""))
	if zone_id.is_empty():
		return _err("zone_id is required")
	var zone: Dictionary = data.get_zone(zone_id)
	if zone.is_empty():
		return _err("Unknown zone: %s" % zone_id)
	# Cold review F5: same distinction as _create_zone — an absent `outline`
	# key names itself, rather than silently becoming a 0-point outline that
	# reports the wrong (if truthful) reason.
	if not args.has("outline"):
		return _err("outline is required: an array of {x_mm, y_mm} points")
	var pts = _parse_zone_outline(args.get("outline"))
	if pts == null:
		return _err("outline points need x_mm and y_mm")

	var old_pts: PackedVector2Array = data.zone_outline_points(zone)
	if pts.size() == old_pts.size():
		var identical := true
		for i in pts.size():
			if pts[i] != old_pts[i]:
				identical = false
				break
		if identical:
			return _ok({"zone_id": zone_id, "point_count": pts.size(), "changed": false})

	var old_count := old_pts.size()
	if not data.set_zone_outline(zone_id, pts):
		# Cold review F3: this MUST read exactly like zone_author_error's own
		# string (pcb_data.gd:1218), not set_zone_outline's push_warning-only
		# wording ("given" vs "placed") — one rule, one spelling, everywhere a
		# caller (create_zone or this tool) can actually see it.
		return _err("A zone outline needs at least %d points (%d placed)." % [
			_PcbDataScript.MIN_ZONE_OUTLINE_POINTS, pts.size()])
	data.record_change("edit_zone_outline", {
		"zone_id": zone_id,
		"op": "set_outline",
		"vertex_index": -1,
		"old_point_count": old_count,
		"point_count": pts.size(),
	})
	# set_zone_outline is deliberately silent about the write (LIVE-DRAG WRITER
	# contract); the canvas repaints off THIS signal — the same data_changed
	# relay pcb_canvas.set_data wires to _on_data_changed -> queue_redraw, no
	# new canvas code involved.
	data.data_changed.emit()
	data.save_to_history("Set zone outline")
	return _ok({"zone_id": zone_id, "point_count": pts.size(), "changed": true})


# ── Cutout tools (campaign 2 epoch B, unit 3) ─────────────────────────────────
# MCP parity for the cutout surface this unit adds to the canvas (draw tool +
# eraser/trash/context-menu delete). Same journalled model path as the zone
# tools above (data.create_cutout / data.remove_cutout), so an agent mutation
# and a human canvas edit are indistinguishable to pcb_data. A cutout has no
# net and no layer (see pcb_data.gd's Cutout Management doc), so this is the
# FOUR-tool subset of the zone surface's seven: list/describe/create/delete,
# with no set_net/set_layer/set_outline counterparts to author. The outline
# parser (_parse_zone_outline, above) and the outline codecs
# (zone_outline_points/zone_outline_to_list) are reused verbatim — they are
# generic {x_mm,y_mm} point-list helpers, not zone-specific in what they do.

## List every cutout, summary shape. Read-only — journals nothing. Mirrors
## _list_zones minus the kind/net/layer fields a cutout does not have.
static func _list_cutouts(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var cutouts_arr: Array = []
	for cutout in data.cutouts:
		cutouts_arr.append({
			"cutout_id": str(cutout.get("id", "")),
			"point_count": data.zone_outline_points(cutout).size(),
		})
	return _ok({"cutout_count": cutouts_arr.size(), "cutouts": cutouts_arr})


## Describe one cutout in full, including its outline. Read-only — journals
## nothing. Mirrors _describe_zone: the outline is round-tripped through
## zone_outline_points (parse) -> zone_outline_to_list (re-encode) rather than
## returned raw, so a malformed stored outline still comes back canonical.
static func _describe_cutout(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var cutout_id: String = str(args.get("cutout_id", ""))
	if cutout_id.is_empty():
		return _err("cutout_id is required")
	var cutout: Dictionary = data.get_cutout(cutout_id)
	if cutout.is_empty():
		return _err("Unknown cutout: %s" % cutout_id)
	var pts: PackedVector2Array = data.zone_outline_points(cutout)
	return _ok({
		"cutout_id": cutout_id,
		"point_count": pts.size(),
		"outline": data.zone_outline_to_list(pts),
	})


## Author a new cutout and add it to the board. ONE journalled undo step:
## data.create_cutout already record_change's + data_changed's internally
## (mirrors create_zone's own idiom), so this owes only the closing
## save_to_history.
##
## The refusal text is produced by calling data.cutout_author_error OURSELVES,
## ahead of create_cutout, for the same reason _create_zone calls
## zone_author_error itself: create_cutout only push_warning()s its reason to
## the console and returns {} either way, so the model's real, verbatim
## refusal string (too few points — the ONLY rule a cutout has) has to be
## asked for explicitly to reach the caller.
static func _create_cutout(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	# Cold review F5 (zone tools' own fix, reused here): a genuinely ABSENT
	# `outline` key must say so, not fall through args.get's [] default into
	# cutout_author_error and come back as "needs at least 3 points (0
	# placed)" — truthful, but not the actual problem.
	if not args.has("outline"):
		return _err("outline is required: an array of {x_mm, y_mm} points")
	var pts = _parse_zone_outline(args.get("outline"))
	if pts == null:
		return _err("outline points need x_mm and y_mm")
	var refusal: String = data.cutout_author_error(pts.size())
	if not refusal.is_empty():
		return _err(refusal)
	var cutout: Dictionary = data.create_cutout(pts)
	if cutout.is_empty():
		# Defensive only — cutout_author_error above already cleared the only
		# known refusal, so create_cutout succeeding is the expected path.
		return _err("Cutout could not be created.")
	data.save_to_history("Create cutout")
	return _ok({
		"cutout_id": str(cutout.get("id", "")),
		"point_count": data.zone_outline_points(cutout).size(),
	})


## Delete a cutout. Mirrors _delete_zone's idiom exactly (mutate-then-snapshot,
## bug 019fb5ad791c; one undo step; unknown cutout_id is an explicit error,
## never a silent no-op), minus the net/layer fields a cutout does not have.
static func _delete_cutout(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var cutout_id: String = str(args.get("cutout_id", ""))
	if cutout_id.is_empty():
		return _err("cutout_id is required")
	var cutout: Dictionary = data.get_cutout(cutout_id)
	if cutout.is_empty():
		return _err("Unknown cutout: %s" % cutout_id)
	if not data.remove_cutout(cutout_id):
		return _err("Unknown cutout: %s" % cutout_id)
	data.save_to_history("Delete cutout " + cutout_id)
	return _ok({"deleted": cutout_id})


# ── Group parity (B2, item 019fba0386) ───────────────────────────────────────
# MCP counterparts of the canvas' Ctrl+G / Ctrl+Shift+G gestures
# (pcb_canvas._group_selection / _ungroup_selection) and PCBPanel's offset
# fields (_commit_member_offset). All three ride pcb_data's group model
# (A4/A4-stage-2) directly — group_components / ungroup_components /
# set_member_offset — so an agent's grouping and a human's are the same
# operation to the board, and minerva_pcb_get_components' group_id/
# group_members/group_anchor/group_offset fields (already shipped) describe
# exactly what these three mutate.
#
# NO LOCK CONCEPT ON GROUP/UNGROUP: is_group_locked gates the operations that
# move geometry (translate/rotate/remove/set_member_offset) — a lock protects
# a physical layout, not the grouping relationship itself. group_components
# and ungroup_components carry no lock check in the model, and none is added
# here; only set_group_member_offset (below) can refuse "locked".

## Stamp two or more known components into one group (merging any existing
## groups among them). ONE journalled undo step: data.group_components already
## record_change's + data_changed's internally (mirrors create_zone's idiom),
## so this owes only the closing save_to_history — same label the canvas'
## Ctrl+G gesture uses ("Group %d components").
##
## group_components returns "" for TWO different reasons the model does not
## distinguish (cold facts, not a model refusal string to relay verbatim):
## fewer than two REAL components after expansion, or a selection that is
## ALREADY exactly one group. This tool tells them apart itself — the first is
## a real error, the second is a no-op reply (changed:false) with the
## existing group's id and members, the same idiom set_zone_net's current-
## value guard uses.
static func _group_components(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var raw = args.get("component_ids", [])
	if not (raw is Array) or raw.is_empty():
		return _err("component_ids is required: an array of two or more component ids")
	var ids: Array[String] = []
	for cid in raw:
		ids.append(str(cid))

	var members: Array = data.expand_to_groups(ids)
	var present: Array[String] = []
	for cid in members:
		if data.has_component(cid):
			present.append(cid)
	if present.size() < 2:
		return _err("Grouping needs at least two known components (%d found)." % present.size())

	var group_id: String = data.group_components(ids)
	if group_id.is_empty():
		# present.size() >= 2 but nothing was stamped. The ONLY case this
		# tool's own pre-check (mirroring group_components:457-464) predicts is
		# "the selection is already exactly one flat group" — but the model's
		# own floor is the real authority, and re-deriving it here (rather than
		# asking the model for a reason) is exactly the drift hazard cold
		# review F2 named: if the model ever refuses for a DIFFERENT reason,
		# present[0] would not actually be grouped, existing_gid comes back
		# "", and returning _ok() for it would be a success-shaped reply for a
		# refused op. Guard that case explicitly instead of trusting the
		# no-op assumption.
		var existing_gid: String = data.component_group_id(present[0])
		if existing_gid.is_empty():
			return _err("Grouping was refused.")
		return _ok({
			"group_id": existing_gid,
			"member_ids": data.group_member_ids(existing_gid),
			"changed": false,
		})
	var member_ids: Array = data.group_member_ids(group_id)
	data.save_to_history("Group %d components" % member_ids.size())
	return _ok({"group_id": group_id, "member_ids": member_ids, "changed": true})


## Dissolve the group(s) touched by `group_id` or `component_ids`. Positions
## are untouched (ungroup_components' own contract) — members simply become
## independently selectable/movable again. ONE journalled undo step, same
## label the canvas' Ctrl+Shift+G gesture uses ("Ungroup %d components").
##
## Accepts EITHER a group_id (resolved to its member list via
## group_member_ids, so an unknown group_id is an explicit error) OR
## component_ids (any member of a touched group pulls in the whole group,
## ungroup_components' own contract) — group_id takes precedence when both are
## given. Releasing nothing (every named component already ungrouped) is a
## no-op reply (changed:false), not an error — the same "nothing to do" shape
## group_components' merge case uses, not a refusal.
static func _ungroup(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var group_id_arg: String = str(args.get("group_id", ""))
	var ids: Array[String] = []
	if not group_id_arg.is_empty():
		var members: Array[String] = data.group_member_ids(group_id_arg)
		if members.is_empty():
			return _err("Unknown group: %s" % group_id_arg)
		ids = members
	else:
		var raw = args.get("component_ids", [])
		if not (raw is Array) or raw.is_empty():
			return _err("component_ids or group_id is required")
		var known: Array[String] = []
		for cid in raw:
			var s := str(cid)
			ids.append(s)
			if data.has_component(s):
				known.append(s)
		if known.is_empty():
			return _err("Unknown component(s): %s" % ", ".join(ids))

	var released: Array = data.ungroup_components(ids)
	if released.is_empty():
		return _ok({"released": [], "changed": false})
	data.save_to_history("Ungroup %d components" % released.size())
	return _ok({"released": released, "changed": true})


## Reposition ONE grouped member relative to its group's anchor (A4 stage-2) —
## the MCP counterpart of PCBPanel's offset LineEdits (_commit_member_offset).
##
## set_member_offset returns a BARE bool that conflates four different
## outcomes (ungrouped, locked, anchor, no-op-already-there) into one `false`,
## so — same reasoning as _create_zone above — this tool re-derives EACH
## refusal reason itself, in the model's own check order (component_group_id
## empty/locked, THEN anchor), before ever calling the model, so the caller
## gets a specific, stable reason instead of one bare "refused". The no-change
## comparison is done here too (target position == current position) so a
## resubmit of the same offset is changed:false and journals nothing, the same
## guard idiom every other setter in this file uses.
static func _set_group_member_offset(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Unknown component: %s" % component_id)
	if not (args.get("dx_mm") is float or args.get("dx_mm") is int) \
			or not (args.get("dy_mm") is float or args.get("dy_mm") is int):
		return _err("dx_mm and dy_mm are required and must be numbers of millimetres")

	var gid: String = data.component_group_id(component_id)
	if gid.is_empty():
		return _err("Component %s is not in a group." % component_id)
	if data.is_group_locked(gid):
		return _err("Group is locked — nothing offset.")
	var anchor_id: String = data.group_anchor_id(gid)
	if anchor_id == component_id:
		return _err("The anchor has no editable offset — moving it would move the whole group.")

	var offset := Vector2(float(args.get("dx_mm")), float(args.get("dy_mm")))
	var anchor_pos: Vector2 = data.get_component(anchor_id).position
	var target: Vector2 = anchor_pos + offset
	var comp = data.get_component(component_id)
	if comp.position == target:
		return _ok({
			"component_id": component_id, "group_id": gid,
			"dx_mm": offset.x, "dy_mm": offset.y, "changed": false,
		})
	if not data.set_member_offset(component_id, offset):
		# Defensive only — every refusal case above (ungrouped/locked/anchor)
		# is already handled ahead of this call.
		return _err("Could not set offset for %s." % component_id)
	data.save_to_history("Offset %s" % component_id)
	return _ok({
		"component_id": component_id, "group_id": gid,
		"dx_mm": offset.x, "dy_mm": offset.y, "changed": true,
	})


# ── Observability (B2, item 019fbb7156) ──────────────────────────────────────

## Structured panel layout state (mode/width/sidebar/drawer/dock/plugin_build
## — see PCBPanel.get_layout_state's own docs for the full shape, including
## the plugin_build design choice). Read-only — journals nothing, mutates
## nothing.
static func _get_layout_state(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("get_layout_state"):
		return _err("PCB panel not available")
	return _ok(panel.get_layout_state())


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
# ── Trace width + preferences (A7, docket 019fb92f07e2) ─────────────────────
# Same journalled model path the human's width controls use
# (pcb_data.set_trace_width), and the SAME process-wide preference store the
# panel reads (pcb_prefs.shared()) — which is what makes an agent write show up
# in the human's spin box and a human turn show up in an agent's read. The live
# repaint rides data_changed, which set_trace_width already emits (the canvas
# wires data.data_changed -> _on_data_changed -> queue_redraw; nothing was added
# here or there).

## Re-width one trace. Mirrors _set_zone_net's idiom exactly: current-value guard
## FIRST (set_trace_width returns "" for both a real write and "no change
## needed", so an unguarded caller would push an empty undo step — cold-review F3
## in pcb_data.gd's own docs), then the model call, then ONE save_to_history.
## Every model refusal (unknown trace, non-positive, out-of-range) surfaces
## verbatim as an _err — the tool invents no message of its own.
static func _set_trace_width(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var trace_id: String = str(args.get("trace_id", ""))
	if trace_id.is_empty():
		return _err("trace_id is required")
	var trace = data.get_trace(trace_id)
	if trace == null:
		return _err("Unknown trace: %s" % trace_id)
	if not (args.get("width_mm") is float or args.get("width_mm") is int):
		return _err("width_mm is required and must be a number of millimetres")
	var width_mm := float(args.get("width_mm"))
	if is_equal_approx(float(trace.width), width_mm):
		return _ok({"trace_id": trace_id, "width_mm": float(trace.width), "changed": false})
	var refusal: String = data.set_trace_width(trace_id, width_mm)
	if not refusal.is_empty():
		return _err(refusal)
	data.save_to_history("Set trace width")
	# The STORED width, re-read off the trace rather than echoed from the
	# request: the model is what a width IS, and a reply that echoed the input
	# would be indistinguishable from a write that never landed.
	return _ok({
		"trace_id": trace_id,
		"width_mm": float(trace.width),
		"net_name": str(trace.net_name),
		"layer": str(trace.layer),
		"changed": true,
	})


## Read one plugin preference. Read-only — journals nothing, writes nothing.
## Reports the EFFECTIVE value plus whether it was actually stored, because
## "never chosen" and "chosen and equal to the default" are different facts the
## panel's seeding order depends on.
static func _get_preference(host, args: Dictionary) -> Dictionary:
	var prefs = _PcbPrefsScript.shared()
	var key: String = str(args.get("key", ""))
	if key.is_empty():
		return _err("key is required. Known keys: %s" % ", ".join(prefs.known_keys()))
	if not prefs.is_known(key):
		return _err("Unknown preference key \"%s\". Known keys: %s" % [
			key, ", ".join(prefs.known_keys())])
	var spec: Dictionary = prefs.describe(key)
	var reply := {
		"key": key,
		"value": prefs.get_value(key),
		"stored": prefs.has_stored(key),
		"default": spec.get("default", null),
		"description": str(spec.get("description", "")),
	}
	if spec.has("min"):
		reply["min"] = spec["min"]
	if spec.has("max"):
		reply["max"] = spec["max"]
	var warning := str(prefs.take_warning())
	if not warning.is_empty():
		reply["warning"] = warning
	return _ok(reply)


## Write one plugin preference, and push it into the live panel so the human sees
## it in the same control they would have turned themselves.
##
## An UNKNOWN KEY is refused, never silently adopted (pcb_prefs.key_registry
## owns that judgement, and the refusal names the keys that do exist so an agent
## can self-correct). The store validates and CLAMPS the value by its own rules
## and the reply reports the STORED, post-clamp value plus a `clamped` flag — a
## clamp is visible, never silent. Note the deliberate asymmetry with
## _set_trace_width above, which REFUSES an out-of-range width: that one writes
## copper, this one writes a starting point (see pcb_prefs.set_value).
##
## The live push goes through host.get_panel() — the same duck-typed host→panel
## back-reference run_router/load_board already use — so a headless host (no
## panel mounted) simply stores the value and says so, rather than failing.
static func _set_preference(host, args: Dictionary) -> Dictionary:
	var prefs = _PcbPrefsScript.shared()
	var key: String = str(args.get("key", ""))
	if key.is_empty():
		return _err("key is required. Known keys: %s" % ", ".join(prefs.known_keys()))
	if not prefs.is_known(key):
		return _err("Unknown preference key \"%s\". Known keys: %s" % [
			key, ", ".join(prefs.known_keys())])
	if not args.has("value"):
		return _err("value is required")
	var res: Dictionary = prefs.set_value(key, args.get("value"))
	if not bool(res.get("ok", false)):
		return _err(str(res.get("error", "Preference could not be stored.")))

	var applied := false
	var panel = _get_panel(host)
	if panel != null and panel.has_method("apply_preference"):
		panel.apply_preference(key, res.get("value"))
		applied = true

	var reply := {
		"key": key,
		"value": res.get("value"),
		"requested": args.get("value"),
		"clamped": bool(res.get("clamped", false)),
		"changed": bool(res.get("changed", false)),
		"applied_to_panel": applied,
	}
	var warning := str(prefs.take_warning())
	if not warning.is_empty():
		reply["warning"] = warning
	return _ok(reply)


## The live PCBPanel behind a host, or null (headless / before mount). Same
## duck-typed host→panel back-reference _get_workspace uses.
static func _get_panel(host):
	if host == null or not host.has_method("get_panel"):
		return null
	var panel = host.get_panel()
	if panel == null or not is_instance_valid(panel):
		return null
	return panel


static func _resolve_data(host) -> Variant:
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	return data


# ── Envelope builders (self-contained, mirrors MCPCadTools/MCPPcbPanelTools) ──

## Whole-board load (minerva_pcb_load_board) — parse canonical YAML via the Go
## backend's pcb.deserialize channel and rebuild the live board in one call.
## ASYNC: awaits the panel broker bridge (host.load_board → panel.load_board_from_yaml),
## same shape as _apply_route_hints. Failure-as-feedback: a worker/broker failure
## comes back as an _err, never a crash.
static func _load_board(host, args: Dictionary) -> Dictionary:
	if host == null:
		return _err("PCB data not available")
	# Dual-key source (docket 019fcbdef1f1, the annotations_list convention):
	# inline `yaml` OR an absolute `path` read server-side — exactly one. The
	# path form exists because the inline form taxes an agent the whole board
	# TWICE in context (measured ~12-14K tokens for a small board), which is
	# precisely the pressure that invites bypassing the MCP surface.
	var yaml_text: String = str(args.get("yaml", ""))
	var src_path: String = str(args.get("path", ""))
	if yaml_text.is_empty() and src_path.is_empty():
		return _err("provide one of 'yaml' (inline board source) or 'path' (absolute file path)")
	if not yaml_text.is_empty() and not src_path.is_empty():
		return _err("provide only one of 'yaml' or 'path', not both")
	if not src_path.is_empty():
		if not FileAccess.file_exists(src_path):
			return _err("file_not_found: %s" % src_path)
		var f := FileAccess.open(src_path, FileAccess.READ)
		if f == null:
			return _err("file_unreadable: %s (error %d)" % [src_path, FileAccess.get_open_error()])
		yaml_text = f.get_as_text()
		f.close()
		if yaml_text.strip_edges().is_empty():
			return _err("file_empty: %s" % src_path)
	if not host.has_method("load_board"):
		return _err("host has no load_board bridge to the panel")
	# Census BEFORE the destructive replace (docket 019fcb6ffeba): load_board
	# swaps the whole board, and an incoming source that lacks entities the
	# live board carries destroys them without either the agent or the owner
	# being told (measured: a canonical YAML with no zones: section silently
	# vaporized 2 live zones). Board↔YAML reconciliation is an LLM task by
	# owner ruling — this tool's job is to be HONEST about what changed, not
	# to merge. Entity identity is type-level (ids re-mint on load): component
	# refs, per-net trace counts, via positions, zone/cutout/hole counts.
	var before: Dictionary = _board_census(_get_data(host))
	var reply: Dictionary = await host.load_board(yaml_text)
	if not bool(reply.get("ok", false)):
		var err_info: Dictionary = reply.get("error", {})
		return _err(str(err_info.get("message", "load_board failed")))
	var out: Dictionary = reply.get("result", {})
	var after: Dictionary = _board_census(_get_data(host))
	var delta: Dictionary = _census_delta(before, after)
	if not delta.is_empty():
		out["delta"] = delta
	# Verification anchors (docket 019fcbdef1f1): the digest lets an agent that
	# hand-carried the YAML PROVE the board it loaded is byte-identical to its
	# source (the inline path has silent-corruption risk with no detection
	# otherwise); the name + echoed path say WHAT landed at a glance.
	out["source_digest"] = yaml_text.sha256_text()
	if not src_path.is_empty():
		out["path"] = src_path
	var loaded_data = _get_data(host)
	if loaded_data != null:
		out["board_name"] = str(loaded_data.board_name)
	return _ok(out)


## Type-level inventory of the live board, for _load_board's honesty report.
## {} when there is no board yet (first load has nothing to lose).
static func _board_census(data) -> Dictionary:
	if data == null:
		return {}
	var trace_nets := {}
	for tid in data.traces:
		var t = data.traces[tid]
		var net := str(t.net_name) if t != null else ""
		trace_nets[net] = int(trace_nets.get(net, 0)) + 1
	var via_positions: Array = []
	for via in data.vias:
		var pos: Vector2 = data.via_position(via)
		via_positions.append("(%.2f, %.2f)" % [pos.x, pos.y])
	return {
		"components": data.components.keys(),
		"trace_nets": trace_nets,
		"vias": via_positions,
		"zones": data.zones.size(),
		"cutouts": data.cutouts.size(),
		"mounting_holes": data.mounting_holes.size(),
	}


## What the replace removed/changed, keyed by entity kind — only kinds that
## actually shrank or changed appear, so an identical reload reports {}.
## `dropped` restates the shrinkage as sentences an agent can surface verbatim.
static func _census_delta(before: Dictionary, after: Dictionary) -> Dictionary:
	if before.is_empty():
		return {}
	var delta := {}
	var dropped: Array = []

	var before_comps: Array = before.get("components", [])
	var after_comps: Array = after.get("components", [])
	var removed_comps: Array = []
	for ref in before_comps:
		if not after_comps.has(ref):
			removed_comps.append(ref)
	if not removed_comps.is_empty():
		delta["components_removed"] = removed_comps
		dropped.append("components removed: %s" % str(removed_comps))

	var before_nets: Dictionary = before.get("trace_nets", {})
	var after_nets: Dictionary = after.get("trace_nets", {})
	var trace_changes := {}
	for net in before_nets:
		var b: int = int(before_nets[net])
		var a: int = int(after_nets.get(net, 0))
		if a < b:
			trace_changes[net] = {"before": b, "after": a}
	if not trace_changes.is_empty():
		delta["traces_reduced"] = trace_changes
		dropped.append("trace counts reduced on net(s): %s" % str(trace_changes.keys()))

	var before_vias: Array = before.get("vias", [])
	var after_vias: Array = after.get("vias", [])
	var removed_vias: Array = []
	for pos in before_vias:
		if not after_vias.has(pos):
			removed_vias.append(pos)
	if not removed_vias.is_empty():
		delta["vias_removed"] = removed_vias
		dropped.append("vias removed at: %s" % str(removed_vias))

	for kind in ["zones", "cutouts", "mounting_holes"]:
		var b2: int = int(before.get(kind, 0))
		var a2: int = int(after.get(kind, 0))
		if a2 < b2:
			delta["%s_removed" % kind] = b2 - a2
			dropped.append("%d %s removed (live board had %d, incoming source has %d)" % [b2 - a2, kind, b2, a2])

	if not dropped.is_empty():
		delta["dropped"] = dropped
	return delta


# ══ C4a — ROUTING-WORKSPACE VERB TOOLS (S4, DCR 019f7095c395) ════════════════
#
# Ten tools, one model. They are the AGENT's doorway onto exactly the verbs the
# canvas context menu offers a human (pcb_canvas.gd's candidate menu) — the same
# RoutingWorkspace calls, the same legality table, the same named refusals — so
# neither surface can drift into having a power the other lacks.
#
# HOW THIS RELATES TO minerva_pcb_apply_route_hints's PROPOSE BRANCH:
# S5 (C4b, DCR 019f7095c395) retired the annotation half — apply_route_hints
# (commit=false) now also lands CANDIDATES ONLY, via _propose_into_workspace,
# the same ingest_record landing path this cluster's own _workspace_propose
# uses below. Both tools write to the same one store; neither writes an
# annotation. A caller picks apply_route_hints for the legacy gather-by-hint_
# ids shape (and its PCBPanel-compatible `proposals` reply array) or
# minerva_pcb_workspace_propose for the workspace-native `candidates` shape —
# same underlying candidates land either way.
#
# EVERY REFUSAL IS NAMED. A tool that could not do what was asked returns
# {success:false, error:"<code>", …} with the workspace's own code
# (illegal_disposition_transition, terminal_disposition, candidate_not_found,
# unmodelable_segment, …) rather than a prose-only message, so an agent can
# branch on the reason and a human can be told which one it was.


## Resolve the workspace + board a verb needs, and BIND them to each other.
##
## The binding is the load-bearing line: PCBData's history bucket 8 only exists
## while a delegate is bound (see pcb_data.bind_routing_workspace), and the
## natural session-start wiring point is PCBPanel, which is outside this unit's
## fence. Binding here — idempotently, at the top of every workspace verb — is
## what makes undo-after-commit work without reaching into the panel. commit()
## additionally pairs the PRE-commit snapshot, so the binding's timing cannot
## change the outcome.
##
## Returns {"ok":true,"ws":…,"data":…} or {"ok":false,"reply":<error envelope>}.
static func _workspace_ctx(host) -> Dictionary:
	var data = _get_data(host)
	if data == null:
		return {"ok": false, "reply": _err("PCB data not available")}
	var workspace = _get_workspace(host)
	if workspace == null:
		return {"ok": false, "reply": {
			"success": false, "error": "workspace_unavailable",
			"note": "no routing workspace is bound to this panel (headless / before mount)",
		}}
	if data.has_method("bind_routing_workspace"):
		data.bind_routing_workspace(workspace)
	# MF-2 (review, owner-ratified HITL-2 — undo coherence): see
	# _reconcile_hint_lifecycle's own doc for why this lazy self-heal, run at
	# the top of EVERY workspace verb, is the compensating half for a gap that
	# cannot be closed synchronously.
	_reconcile_hint_lifecycle(host, workspace)
	return {"ok": true, "ws": workspace, "data": data}


## MF-2 (review, owner-ratified HITL-2 contract; DCR finding 6's "two-store
## gap"): minerva_pcb_workspace_commit closes the source-hint lifecycle
## (open→applied — see _workspace_commit) as its half of the composite
## commit transaction. That transition CANNOT ride pcb_data's board-history
## undo/redo the way the candidate's own disposition does (INV-1's paired
## snapshot, RoutingWorkspace.snapshot_dispositions/restore_dispositions) —
## annotations are a SEPARATE store with their own per-hint revision stack,
## entirely unconnected to pcb_data's history buckets, and restore_dispositions
## itself lives in pcb_routing_workspace.gd (out of this unit's fence) with
## deliberately NO reference to the annotation host (the same "model never
## touches annotations" rule _workspace_commit itself honors). So a plain
## data.undo() after a commit reverts the candidate's disposition back to
## live automatically, but leaves any hint it had marked "applied" stranded —
## exactly the state that would make the next propose silently skip a hint
## the user believes is still open, and risk "iterate lands duplicate copper"
## the other direction (a re-authored hint answering the same net getting no
## fresh candidate because the stale one still LOOKS live via its hint).
##
## COMPENSATING HALF: rather than reach into the out-of-fence restore path (or
## giving the model a host reference it was deliberately never given), this
## reconciles the INVARIANT directly — "applied" is only a truthful lifecycle
## for a hint whose candidate is ACTUALLY committed right now — every time any
## workspace verb runs (they all resolve through _workspace_ctx first,
## including propose). A hint the reader finds "applied" with no live
## committed candidate backing it (undo happened since) reopens to "open"
## before the verb's own work proceeds. This closes the loop by the next
## propose at the latest — the exact point the "duplicate copper" failure
## mode would otherwise strike.
static func _reconcile_hint_lifecycle(host, workspace) -> void:
	if host == null or not host.has_method("get_all_annotations"):
		return
	if workspace == null or not workspace.has_method("list_candidates"):
		return
	var committed_hint_ids: Dictionary = {}
	for c in workspace.list_candidates():
		if c != null and str(c.disposition) == "committed":
			for hid in c.source_hint_ids:
				committed_hint_ids[str(hid)] = true
	for ann in host.get_all_annotations():
		if not (ann is Dictionary):
			continue
		if str((ann as Dictionary).get("kind", "")) != "pcb_route_hint":
			continue
		if str((ann as Dictionary).get("lifecycle", "open")) != "applied":
			continue
		var hid := str((ann as Dictionary).get("id", ""))
		if not committed_hint_ids.has(hid):
			_set_hint_lifecycle(host, hid, "open")


## Mutate ONE hint's top-level `lifecycle` field through the standard
## mutate-with-history seam (host.update_annotation — the same one
## _add_via/BendHandleEditTool use), leaving every other field untouched.
## Returns false (silently — this is a best-effort compensating/closing
## action, never itself the reason a caller's own verb fails) when the
## annotation is gone or the host cannot persist the change.
static func _set_hint_lifecycle(host, hint_id: String, lifecycle: String) -> bool:
	if host == null or not host.has_method("get_by_id") or not host.has_method("update_annotation"):
		return false
	var ann: Dictionary = host.get_by_id(hint_id)
	if ann.is_empty():
		return false
	var updated: Dictionary = ann.duplicate(true)
	updated["lifecycle"] = lifecycle
	return bool(host.update_annotation(hint_id, updated))


## One candidate, as the shape every workspace tool reports it in.
static func _candidate_record(workspace, c) -> Dictionary:
	if c == null:
		return {}
	var cid := str(c.candidate_id)
	var layers: Array = []
	for seg in c.segments:
		if seg is Dictionary:
			var lyr := str((seg as Dictionary).get("layer", ""))
			if not lyr.is_empty() and not (lyr in layers):
				layers.append(lyr)
	var rec: Dictionary = {
		"candidate_id": cid,
		"task_id": str(c.task_id),
		"net": str(c.net),
		"generation": int(c.generation),
		"disposition": str(c.disposition),
		"validation": str(c.validation),
		"segment_count": (c.segments as Array).size(),
		"via_count": (c.vias as Array).size(),
		"layers": layers,
		"base_board_revision": int(c.base_board_revision),
		"candidate_revision": int(c.candidate_revision),
		"source_hint_ids": _string_list(c.source_hint_ids),
		"task_state": str(workspace.task_state(str(c.task_id))),
	}
	if workspace.has_method("committed_copper_ids"):
		var copper: Dictionary = workspace.committed_copper_ids(cid)
		if not (copper.get("trace_ids", []) as Array).is_empty() \
				or not (copper.get("via_ids", []) as Array).is_empty():
			rec["committed_trace_ids"] = copper.get("trace_ids", [])
			rec["committed_via_ids"] = copper.get("via_ids", [])
	if workspace.has_method("findings_for_candidate"):
		var f: Array = workspace.findings_for_candidate(cid)
		if not f.is_empty():
			rec["finding_count"] = f.size()
	return rec


## The candidate's GEOMETRY, JSON-shaped (docket 019fce3ac3f5 item 3): segments
## as {id, layer, width, points:[[x,y],…]} and vias as {id, position:[x,y],
## diameter, from_layer, to_layer}. This is the pre-commit review object — until
## it existed, an agent could read a committed trace's every coordinate
## (export_trace_geometry) but had to approve a PROPOSAL on segment counts and
## DRC verdicts alone; HITL-3 shipped an under-body bend and a pad-row corridor
## that one look at the numbers would have caught. Opt-in via include_geometry
## so default lists and the landing verbs' candidate records stay lean.
static func _candidate_geometry(c) -> Dictionary:
	var segments: Array = []
	for seg in c.segments:
		if not (seg is Dictionary):
			continue
		var seg_dict: Dictionary = seg
		var pts: Array = []
		for p in seg_dict.get("points", []):
			if p is Vector2:
				pts.append([(p as Vector2).x, (p as Vector2).y])
		segments.append({
			"id": str(seg_dict.get("id", "")),
			"layer": str(seg_dict.get("layer", "")),
			"width": float(seg_dict.get("width", 0.0)),
			"points": pts,
		})
	var vias: Array = []
	for via in c.vias:
		if not (via is Dictionary):
			continue
		var via_dict: Dictionary = via
		var pos: Variant = via_dict.get("position", null)
		vias.append({
			"id": str(via_dict.get("id", "")),
			"position": [(pos as Vector2).x, (pos as Vector2).y] if pos is Vector2 else [],
			"diameter": float(via_dict.get("diameter", 0.0)),
			"from_layer": str(via_dict.get("from_layer", "")),
			"to_layer": str(via_dict.get("to_layer", "")),
		})
	return {"segments": segments, "vias": vias}


## The named-refusal envelope for a disposition verb that came back false. Reads
## the workspace's own last_transition_error so the tool never invents a reason.
static func _workspace_refusal(workspace, verb: String, candidate_id: String) -> Dictionary:
	var err: Dictionary = workspace.last_transition_error if workspace.last_transition_error is Dictionary else {}
	var code := str(err.get("error", "transition_refused"))
	return {
		"success": false,
		"error": code,
		"candidate_id": candidate_id,
		"verb": verb,
		"from": str(err.get("from", "")),
		"to": str(err.get("to", "")),
		"note": "the disposition legality table refused this move (see pcb_route_candidate.gd DISPOSITION_TRANSITIONS)",
	}


## Shared body of pin / unpin / reject — one implementation, three names, so the
## three cannot drift in what they report.
static func _workspace_disposition_verb(host, args: Dictionary, verb: String) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var cid: String = str(args.get("candidate_id", ""))
	if cid.is_empty():
		return _err("candidate_id is required")
	if workspace.get_candidate(cid) == null:
		return {"success": false, "error": "candidate_not_found", "candidate_id": cid}
	var applied: bool = false
	match verb:
		"pin":
			applied = workspace.pin(cid)
		"unpin":
			applied = workspace.unpin(cid)
		"reject":
			applied = workspace.reject(cid)
	if not applied:
		return _workspace_refusal(workspace, verb, cid)
	var reply: Dictionary = {"verb": verb}
	reply.merge(_candidate_record(workspace, workspace.get_candidate(cid)))
	# INV-2 is observable, not merely internal: name the candidates whose verdict
	# this verb invalidated so a caller knows what needs re-checking.
	reply["stale_candidate_ids"] = _stale_ids(workspace)
	return _ok(reply)


## Every candidate currently carrying validation == "stale" — the INV-2 read
## surface the verbs report so staleness is never something a caller has to
## infer from a separate list call.
static func _stale_ids(workspace) -> Array:
	var out: Array = []
	for c in workspace.list_candidates():
		if c != null and str(c.validation) == "stale":
			out.append(str(c.candidate_id))
	return out


## PROPOSE into the workspace. Runs the router exactly as
## minerva_pcb_apply_route_hints does (same host bridge, same hint gathering,
## same normalization seam) and lands RouteCandidates — no annotations.
##
## HOLDS ARE SURFACED, NOT SWALLOWED. A task whose active candidate is PINNED is
## HELD by the workspace: the incoming candidate is not created and the pin
## stands (RoutingWorkspace's ingest policy — a batch re-route is not consent
## about a candidate the user pinned). The reply therefore reports FEWER
## candidates than routes, and `holds` says which task, which candidate and why,
## so "nothing changed for net N3" is never invisible.
##
## last_ingest_holds is PER CALL and ingest_record resets it on entry, so the
## holds are accumulated here across the per-record loop rather than read once
## at the end — reading it after the loop would report only the last record's.
static func _workspace_propose(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]

	var hint_ids: Array = args.get("hint_ids", []) if args.get("hint_ids", []) is Array else []
	var source_hints: Array = _gather_route_hints(host, hint_ids)
	if source_hints.is_empty():
		return _ok({
			"proposed": 0, "candidates": [], "holds": [], "unrouted": [], "stuck": [],
			"note": "no open route hints to route (add hints or pass hint_ids)",
		})
	var selection: Dictionary
	if hint_ids.is_empty():
		selection = {"mode": "open"}
	else:
		selection = {"mode": "ids", "ids": _hint_id_list(source_hints)}

	var scope: Variant = _propose_scope(hint_ids, source_hints, data)
	var route_extra: Dictionary = _route_request_extra(workspace, scope)
	var reply: Dictionary = await _run_router(host, selection, route_extra)
	if not bool(reply.get("ok", false)):
		return _router_unavailable(reply, source_hints)
	var result: Dictionary = reply.get("result", {})
	# Narrate the ask boundary (docket 019fcb6f9d20): when the run was
	# span-scoped, say so — the caller should never have to infer from the
	# candidate list whether net-completion was attempted.
	var extra := {}
	if scope is Dictionary and (scope as Dictionary).has("tasks"):
		var span_tasks: Array = (scope as Dictionary).get("tasks", [])
		extra["scope"] = {
			"span_tasks": span_tasks.size(),
			"note": "span-scoped to the hints' own endpoints; net-completion "
				+ "beyond the ask was NOT attempted — propose net-level hints "
				+ "(or omit endpoints) to route whole nets.",
		}
	return await _ingest_result_into_workspace(host, workspace, data, result, source_hints, extra)


## Reply honesty for every candidate-landing verb (docket 019fce3a6c57): when
## the LIVE set holds two or more candidates, run the SAME set-scoped draft
## check minerva_pcb_workspace_check runs — union of committed copper and every
## live candidate's draft copper — and hand back its findings. The per-route
## drc summaries in a router reply are candidate-vs-board only, so two live
## ghosts crossing each other on one layer read "clean" everywhere else; this
## is the one place a landing verb can tell the caller about that short.
##
## NEVER the reason a landing verb fails: no bridge (headless / before mount)
## or no worker reply degrades to a named skip, and a single live candidate
## returns {} (the router's own draft DRC already covered candidate-vs-board).
## Stale siblings are checked DELIBERATELY (their existing geometry is what is
## on screen next to the fresh ghost) — the ids are named in `checked_stale`.
static func _cross_candidate_check(host, workspace, data) -> Dictionary:
	var live: Array = _string_list(workspace.live_candidate_ids())
	if live.size() < 2:
		return {}
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("check_draft"):
		return {"skipped": "draft_check_unavailable"}
	workspace.rebase(int(data.board_revision))
	var stale: Array = []
	for cid in live:
		var c = workspace.get_candidate(str(cid))
		if c != null and str(c.validation) == "stale":
			stale.append(str(cid))
	var result: Dictionary = await panel.check_draft(live)
	if result.is_empty() or not result.has("per_candidate"):
		return {"skipped": "draft_check_no_reply"}
	return {
		"checked": live,
		"checked_stale": stale,
		"per_candidate": result.get("per_candidate", {}),
		"findings": result.get("findings", []),
	}


## The SHARED landing path for every tool that turns a router reply into
## candidates (propose, reroute-route, reroute-span). One place that normalizes,
## ingests, accumulates holds and shapes the reply, so the three verbs report
## identically and a fix to one is a fix to all. `extra` is merged last so a
## caller can stamp its own metadata (e.g. the span degrade notice).
static func _ingest_result_into_workspace(host, workspace, data, result: Dictionary,
		source_hints: Array, extra: Dictionary) -> Dictionary:
	var records: Array = _normalize_route_records(result, source_hints)
	var revision: int = int(data.board_revision) if data != null else 0
	var landed: Array = []
	var holds: Array = []
	for rec in records:
		var cid: String = str(workspace.ingest_record(rec, revision))
		for hold in workspace.last_ingest_holds:
			holds.append(hold)
		if cid.is_empty():
			continue
		landed.append(_candidate_record(workspace, workspace.get_candidate(cid)))
	var out: Dictionary = {
		"proposed": landed.size(),
		"candidates": landed,
		"holds": holds,
		"routes_returned": (result.get("routes", []) as Array).size() if result.get("routes", []) is Array else 0,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
		"drc_summary": result.get("drc_summary", {}),
		"drc_geometric_summary": result.get("drc_geometric_summary", {}),
		"stale_candidate_ids": _stale_ids(workspace),
		"note": "candidates landed in the routing workspace; no proposal annotations were written",
	}
	var cross: Dictionary = await _cross_candidate_check(host, workspace, data)
	if not cross.is_empty():
		out["cross_candidate_check"] = cross
		if not (cross.get("findings", []) as Array).is_empty():
			out["note"] = str(out["note"]) \
				+ "; WARNING: the set-scoped check found findings across the live candidate set — see cross_candidate_check"
	out.merge(extra, true)
	return _ok(out)


## LIST the workspace. Live candidates by default — a terminal one is history and
## would bury the two or three answers a caller is actually deciding between.
static func _workspace_list(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var include_terminal: bool = bool(args.get("include_terminal", false))
	var include_geometry: bool = bool(args.get("include_geometry", false))
	var want_task: String = str(args.get("task_id", ""))
	var want_net: String = str(args.get("net", ""))
	var live: Dictionary = {}
	for id in workspace.live_candidate_ids():
		live[str(id)] = true
	var out: Array = []
	for c in workspace.list_candidates():
		if c == null:
			continue
		var cid := str(c.candidate_id)
		if not include_terminal and not live.has(cid):
			continue
		if not want_task.is_empty() and str(c.task_id) != want_task:
			continue
		if not want_net.is_empty() and str(c.net) != want_net:
			continue
		var rec: Dictionary = _candidate_record(workspace, c)
		if include_geometry:
			rec["geometry"] = _candidate_geometry(c)
		out.append(rec)
	var tasks: Array = []
	for t in workspace.list_tasks():
		tasks.append({
			"task_id": str(t.task_id), "net": str(t.net), "state": str(t.state),
			"span_scoped": bool(t.is_span_scoped()),
		})
	return _ok({
		"candidates": out,
		"count": out.size(),
		"tasks": tasks,
		"open_task_ids": workspace.open_task_ids(),
		"active_candidate_id": str(workspace.active_candidate_id),
		"pinned_candidate_ids": workspace.pinned.keys(),
		"stale_candidate_ids": _stale_ids(workspace),
		"include_terminal": include_terminal,
	})


## The candidate the UI is focused on. Empty active id is a SUCCESS with
## active_candidate_id "" — "nothing is selected" is an answer, not an error.
static func _workspace_get_active(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var cid: String = str(workspace.active_candidate_id)
	if cid.is_empty():
		return _ok({"active_candidate_id": "", "candidate": {},
			"note": "no candidate is active (select one on the canvas, or pass candidate_id to the verb you meant)"})
	var rec: Dictionary = _candidate_record(workspace, workspace.get_candidate(cid))
	if bool(args.get("include_geometry", false)):
		rec["geometry"] = _candidate_geometry(workspace.get_candidate(cid))
	var reply: Dictionary = {"active_candidate_id": cid, "candidate": rec}
	if workspace.has_method("findings_for_candidate"):
		reply["findings"] = workspace.findings_for_candidate(cid)
	return _ok(reply)


static func _workspace_pin(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "pin")


static func _workspace_unpin(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "unpin")


static func _workspace_reject(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "reject")


## COMMIT — INV-1. A thin tool over RoutingWorkspace.commit, which owns the whole
## transaction (board writes + disposition + the paired history snapshot). The
## tool deliberately adds NO board mutation of its own: a second writer would be
## a second thing to undo.
static func _workspace_commit(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]
	var cid: String = str(args.get("candidate_id", ""))
	if cid.is_empty():
		return _err("candidate_id is required")
	var res: Dictionary = workspace.commit(cid, data)
	if not bool(res.get("ok", false)):
		return {
			"success": false,
			"error": str(res.get("error", "commit_failed")),
			"candidate_id": str(res.get("candidate_id", cid)),
			"note": str(res.get("message", "")),
		}
	var reply: Dictionary = res.duplicate(true)
	reply.erase("ok")

	# MF-2 (review, owner-ratified HITL-2 contract; manifest.json's own
	# apply_route_hints text and the DCR's composite-transaction text both
	# still encode it): commit closes the source-hint lifecycle — each
	# consumed hint transitions open→applied, NEVER deleted. Applied hints
	# are durable intent/commentary that answered THIS route, kept for the
	# record; _gather_route_hints' default (open-only) scope already excludes
	# non-open lifecycle, so the next propose skips them without further
	# wiring — that is what keeps iterate from landing duplicate copper on a
	# hint already answered. Undo coherence for this transition is handled
	# separately, lazily, by _reconcile_hint_lifecycle (see its doc) — it
	# cannot ride this same board-history step (a different store).
	var consumed_hint_ids: Array = res.get("consumed_hint_ids", [])
	for hid in consumed_hint_ids:
		_set_hint_lifecycle(host, str(hid), "applied")

	reply["candidate"] = _candidate_record(workspace, workspace.get_candidate(cid))
	reply["stale_candidate_ids"] = _stale_ids(workspace)
	reply["undo_note"] = "one board history step: Ctrl+Z (or PCBData.undo) removes this copper AND returns the candidate to its pre-commit disposition — the source hint(s) reopen the next time any workspace tool runs (see _reconcile_hint_lifecycle), not synchronously with this undo"
	return _ok(reply)


## TRY-AGAIN over the WHOLE route. Runs the router again scoped to the
## candidate's own source hints and lands a NEW generation for the same task.
##
## THE ROUTER IS RUN FIRST, then the prior is retired. Retiring first would mean
## a router failure left the task with no answer at all — the old geometry gone
## and nothing in its place. A PROPOSED prior is superseded by the ingest itself;
## only a PINNED prior needs the explicit targeted supersede, which is exactly
## the consent the workspace's ingest policy demands (acting on THIS candidate)
## and not the batch consent it refuses.
static func _workspace_reroute_route(host, args: Dictionary) -> Dictionary:
	return await _workspace_reroute(host, args, {})


## REROUTE-SPAN — DEGRADED, and it says so on every reply.
##
## The DCR's Reroute-Span "replaces only a selected interval". The routing engine
## cannot express that: agent_router scopes by WHOLE NET, and
## route_bridge.parse_route_scope REFUSES a span rather than widening it —
## "honouring this would route the entire net and return copper between pads the
## task never named". So this verb does the only honest thing available: it
## performs a WHOLE-ROUTE reroute and stamps `degraded`, `degraded_to`,
## `limitation` and the docket id on the reply. It deliberately does NOT create a
## span-scoped RouteTask: recording a span question whose answer is whole-route
## geometry would make the model claim a scope it never had.
## Tracked as docket 019fc155bc32; when agent_router grows span support this verb
## stops degrading and the model's reroute_span stub becomes the implementation.
static func _workspace_reroute_span(host, args: Dictionary) -> Dictionary:
	var requested: Array = _string_list(args.get("segment_ids", []))
	return await _workspace_reroute(host, args, {
		"degraded": true,
		"degraded_to": "whole_route",
		"requested_segment_ids": requested,
		"limitation": "span-scoped routing is not available: the routing engine scopes by whole net (route_bridge.parse_route_scope refuses a span rather than widening it), so this call rerouted the ENTIRE route, not only the segments named. The reply's candidate is whole-route geometry.",
		"limitation_docket": "019fc155bc32",
	})


static func _workspace_reroute(host, args: Dictionary, extra: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]
	var cid: String = str(args.get("candidate_id", ""))
	if cid.is_empty():
		return _err("candidate_id is required")
	var c = workspace.get_candidate(cid)
	if c == null:
		return {"success": false, "error": "candidate_not_found", "candidate_id": cid}
	if not workspace.can_transition(cid, "superseded"):
		return _workspace_refusal_static(cid, str(c.disposition))

	var hint_ids: Array = _string_list(c.source_hint_ids)
	if hint_ids.is_empty():
		# FAIL CLOSED rather than run a whole-board route. `route_board`/
		# `run_router` DO now forward an explicit `scope` (DCR finding 7,
		# _reroute_scope below, built straight from this candidate's own
		# task_id/net) — but only AFTER this gate: this verb still requires
		# hint provenance FIRST and uses `scope` as a belt-and-suspenders
		# assertion alongside it, not as a substitute for it. Lifting this gate
		# so a hint-less candidate could be addressed by task/net scope alone
		# is a separate, larger change to this function's control flow — not
		# part of this fence.
		return {
			"success": false, "error": "no_source_hints", "candidate_id": cid,
			"note": "this candidate carries no source route-hint ids; reroute is gated on hint provenance before the router bridge is even called, so an explicit task/net scope cannot be substituted for it here (see pcb/docs/tools.md's route-request note for what scope/pinned_candidates now cover)",
		}
	var source_hints: Array = _gather_route_hints(host, hint_ids)
	if source_hints.is_empty():
		return {
			"success": false, "error": "source_hints_missing", "candidate_id": cid,
			"hint_ids": hint_ids,
			"note": "the route hints this candidate came from are no longer on the board, so the run cannot be scoped to it",
		}

	var route_extra: Dictionary = _route_request_extra(
		workspace, _reroute_scope(c, source_hints, data))
	var reply: Dictionary = await _run_router(
		host, {"mode": "ids", "ids": _hint_id_list(source_hints)}, route_extra)
	if not bool(reply.get("ok", false)):
		return _router_unavailable(reply, source_hints)

	# The router answered — NOW retire the prior. A pinned prior would otherwise
	# HOLD its task and the fresh geometry would be dropped on the floor.
	var prior_task: String = str(c.task_id)
	if str(c.disposition) == "pinned" and not workspace.supersede(cid):
		return _workspace_refusal(workspace, "reroute", cid)

	var landed: Dictionary = await _ingest_result_into_workspace(
		host, workspace, data, reply.get("result", {}), source_hints, extra)
	landed["rerouted_candidate_id"] = cid
	landed["prior_task_id"] = prior_task
	# A reroute is meant to answer the SAME question again. Say plainly whether
	# it did: the task key is derived from the worker's own per-route hint
	# attribution, so a reply that attributes differently lands a NEW task, and
	# a caller that assumed otherwise would be looking at the wrong generation.
	var same := false
	for rec in landed.get("candidates", []):
		if rec is Dictionary and str((rec as Dictionary).get("task_id", "")) == prior_task:
			same = true
	landed["same_task"] = same
	return landed


## Refusal envelope for a verb blocked by the legality table BEFORE it was
## attempted (can_transition said no, so last_transition_error is not set).
## The terminal-set test reads the CANONICAL const on PcbRouteCandidate rather
## than re-listing its members: a second copy of that list is a second thing to
## keep in step with the legality table, and it would drift silently.
static func _workspace_refusal_static(candidate_id: String, from: String) -> Dictionary:
	var terminal: Array = _PcbRouteCandidateScript.TERMINAL_DISPOSITIONS
	return {
		"success": false,
		"error": _PcbRouteCandidateScript.ERR_TERMINAL_DISPOSITION if from in terminal \
			else _PcbRouteCandidateScript.ERR_ILLEGAL_TRANSITION,
		"candidate_id": candidate_id,
		"from": from,
		"to": "superseded",
		"note": "a %s candidate cannot be rerouted — it has already left the live set" % from,
	}


## SET-SCOPED draft DRC over the workspace.
##
## Runs the panel's existing draft-check plumbing verbatim
## (PCBPanel.check_draft → the pcb.draft_check broker channel → worker
## methods._draft_check), which checks the UNION of committed copper and every
## checked candidate's draft copper and returns findings whose subjects name
## CANDIDATE / SEGMENT / VIA ids. The workspace's own guards (board_token,
## workspace_generation, per-candidate revision) decide what is written back, so
## a stale reply can never mark anything clean; this tool adds no verdict of its
## own.
##
## STALE CANDIDATES REFUSE. Before checking, the workspace is REBASED onto the
## live board revision — which is what makes the gate mean anything: a candidate
## generated against an older board is marked stale right here, and checking it
## silently would hand back a verdict that reads as "this proposal is fine" about
## geometry generated for a board that has since moved. Two exits, both stated in
## the refusal: reroute/re-propose it (fresh geometry against this board), or ask
## again with include_stale:true to check the old geometry deliberately.
static func _workspace_check(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]
	var include_stale: bool = bool(args.get("include_stale", false))

	# Bind + mark. This is also the wiring gap C1 filed (019fc14e3884): nothing
	# else threads the live board revision into the workspace, so the check is
	# where it happens.
	var newly_stale: Array = workspace.rebase(int(data.board_revision))

	var requested: Array = _string_list(args.get("candidate_ids", []))
	var targets: Array = requested if not requested.is_empty() else workspace.live_candidate_ids()
	var unknown: Array = []
	for t in targets:
		if workspace.get_candidate(str(t)) == null:
			unknown.append(str(t))
	if not unknown.is_empty():
		return {"success": false, "error": "candidate_not_found", "candidate_ids": unknown}
	if targets.is_empty():
		return _ok({"checked": [], "per_candidate": {}, "findings": [],
			"note": "no live candidates to check"})

	var stale: Array = []
	for t in targets:
		if str(workspace.get_candidate(str(t)).validation) == "stale":
			stale.append(str(t))
	if not stale.is_empty() and not include_stale:
		return {
			"success": false, "error": "stale_candidates", "stale_candidate_ids": stale,
			"newly_stale_candidate_ids": newly_stale,
			"board_revision": int(data.board_revision),
			"note": "these candidates were generated against a different board revision, or a verb invalidated their verdict. Reroute/re-propose them for geometry against THIS board, or re-run with include_stale:true to check the existing geometry against it deliberately.",
		}

	var panel = _get_panel(host)
	if panel == null or not panel.has_method("check_draft"):
		return {"success": false, "error": "draft_check_unavailable",
			"note": "no panel bridge to the pcb.draft_check worker channel (headless / before mount)"}
	var result: Dictionary = await panel.check_draft(targets)
	if result.is_empty() or not result.has("per_candidate"):
		return {"success": false, "error": "draft_check_no_reply",
			"checked": targets,
			"note": "the draft_check worker channel did not answer; every checked candidate was reverted to the validation it had before (never left 'checking')"}
	var after: Dictionary = {}
	for t in targets:
		var c = workspace.get_candidate(str(t))
		if c != null:
			after[str(t)] = str(c.validation)
	return _ok({
		"checked": targets,
		"checked_stale": stale,
		"per_candidate": result.get("per_candidate", {}),
		"findings": result.get("findings", []),
		"validation": after,
		"board_token": result.get("board_token", ""),
		"workspace_generation": result.get("workspace_generation", 0),
		"newly_stale_candidate_ids": newly_stale,
	})


# ══ C5 — BUS TOOL geometry core + MCP parity (S3+S4, DCR 019fb572b888) ══════
#
# bus_plan/bus_commit_plan are the ONE shared implementation the canvas
# gesture (pcb_canvas.gd's _commit_bus/_draw_bus_preview, which preload this
# file) and minerva_pcb_route_bus_direct below both call — the parked suite's
# "MCP tool result == gesture result on the same input" claim is true by
# construction (one function, not two hand-synchronised copies), not merely
# tested for.
#
# Split in two on purpose: bus_plan is PURE (no mutation, no history — safe to
# call every redraw for the live preview) and bus_commit_plan MUTATES (create
# N traces, one save_to_history). A caller always calls bus_plan first and
# only calls bus_commit_plan when plan.ok is true.

## Mirrors pcb_bus_geometry.gd's own _MIN_SEGMENT_MM — kept as an independent
## constant rather than reaching into that module's private (leading-
## underscore) internals, which would couple this file to an implementation
## detail of a standing pin never meant to be consumed past its public statics
## (offset_polyline/pitch_between/cumulative_offsets/MITER_LIMIT).
const _BUS_MIN_SEGMENT_MM := 1e-6


## The per-net width bus_plan uses when no override is given: the widest
## EXISTING trace already on that net, else the board's own default
## (data.authored_trace_width) — a bus joining a net that already has copper
## should not draw a different-width track for it, and a net with no copper
## yet gets the same default any other new trace would.
static func bus_net_width(data, net_name: String) -> float:
	var widest := 0.0
	for trace in data.get_traces_for_net(net_name):
		widest = maxf(widest, float(trace.width))
	return widest if widest > 0.0 else data.authored_trace_width()


## Consecutive-duplicate-point removal for the INNER-FOLD GUARD's segment scan
## ONLY — offset_polyline drops duplicates internally already (see its own
## return-shape doc) and is called on the RAW spine_points below, unchanged.
## Without this, two coincident spine clicks (a snapped double-click, or a
## replayed drag) would report a false "segment N is shorter than the widest
## offset" for a zero-length segment that offset_polyline was always going to
## drop silently and harmlessly — a real bug report about geometry that was
## never going to fold.
static func _bus_drop_duplicates(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > _BUS_MIN_SEGMENT_MM:
			out.append(p)
	return out


## PURE. The whole bus geometry pipeline in one place: per-net width
## resolution -> data.design_rule_clearance() -> BusGeom.pitch_between (via
## cumulative_offsets) -> BusGeom.offset_polyline per net -> the INNER-FOLD
## GUARD (pcb_bus_geometry.gd:78-82's documented gap — "S4 must either refuse
## a spine with segments shorter than the widest offset, or accept the fold";
## this tool layer refuses, never accepts the fold).
##
## `nets` is the ORDERED net-name array — T11: this order is never re-sorted,
## by either this function or BusGeom.cumulative_offsets underneath it; it is
## the caller's (the picker's, or the MCP arg's) order, verbatim.
## `width_override`, when > 0.0, replaces the per-net auto-derived width for
## EVERY net (the MCP tool's optional uniform override — the canvas gesture
## never passes one, relying on bus_net_width's per-net derivation instead).
##
## Returns {ok, error, nets, widths, offsets, polylines, layer} — `error` is
## "" when ok, else the ONE refusal string (structural refusals — too few
## nets, an undeclared net, no layer, too few spine points — and the
## inner-fold guard's named refusal all land in this same field, so every
## caller checks exactly one thing).
static func bus_plan(data, nets: Array, spine_points: PackedVector2Array, layer: String, width_override: float = 0.0) -> Dictionary:
	if nets.size() < 2:
		return {"ok": false, "error": "A bus needs at least 2 nets (%d given)." % nets.size()}
	for net_name in nets:
		if not data.has_net(str(net_name)):
			return {"ok": false, "error": "Net \"%s\" is not declared on this board." % str(net_name)}
	if layer.is_empty():
		return {"ok": false, "error": "No copper layer to place the bus on."}
	# LAYER MEMBERSHIP (cold review N1): the canvas gesture always hands this
	# function a layer that already passed trace_author_layer()'s own
	# declared-stack check, so this predicate is normally a no-op for it — but
	# minerva_pcb_route_bus_direct's `layer` arg is caller-supplied, untrusted
	# text, the ONE input this function does not otherwise validate before
	# reaching create_trace_entity. Checked HERE, in the one shared plan
	# function, rather than only in the MCP handler, so "same validation path"
	# stays true for both callers instead of the MCP path growing a second,
	# parallel check. Same predicate + wording as pcb_data.trace_author_error's
	# own layer clause (_create_zone's precedent: reuse the model's real
	# refusal wording rather than inventing one) — checked directly rather
	# than through that function so a garbage layer is named HERE, before any
	# per-net width work runs, instead of surfacing only once bus_commit_plan
	# reaches the first create_trace_entity call and wraps it in the generic
	# "Bus was refused by the board model on net %s" message.
	var declared_layers: Array = data.layers if data else []
	if not declared_layers.is_empty() and layer not in declared_layers:
		return {"ok": false, "error": "Layer \"%s\" is not in the board's declared layer stack." % layer}

	var cleaned := _bus_drop_duplicates(spine_points)
	if cleaned.size() < 2:
		return {"ok": false, "error": "The bus spine needs at least 2 distinct points (%d given)." % spine_points.size()}

	var widths: Array = []
	for net_name in nets:
		widths.append(width_override if width_override > 0.0 else bus_net_width(data, str(net_name)))
	var clearance: float = data.design_rule_clearance()
	var offsets: Array = BusGeom.cumulative_offsets(widths, clearance)

	# INNER-FOLD GUARD. Checked against the WIDEST |offset| in the whole bus
	# (pcb_bus_geometry.gd's own wording), on the DEDUPLICATED spine — a
	# duplicate point is a zero-length segment offset_polyline drops silently,
	# not a fold (see _bus_drop_duplicates' doc).
	var max_offset := 0.0
	for o in offsets:
		max_offset = maxf(max_offset, absf(float(o)))
	for i in range(cleaned.size() - 1):
		var seg_len: float = cleaned[i].distance_to(cleaned[i + 1])
		if seg_len < max_offset:
			return {"ok": false, "error":
				"Bus spine segment %d→%d (%.3fmm) is shorter than the widest track offset (%.3fmm) — the inner track would fold back on itself. Add a waypoint or widen this corner."
					% [i, i + 1, seg_len, max_offset]}

	var polylines: Array = []
	for offset in offsets:
		polylines.append(BusGeom.offset_polyline(spine_points, float(offset)))

	return {
		"ok": true, "error": "",
		"nets": nets.duplicate(), "widths": widths, "offsets": offsets,
		"polylines": polylines, "layer": layer,
	}


## MUTATES. Call only with a plan whose ok == true (bus_plan's own refusal
## check already ran — this function trusts it). Creates one Trace entity per
## net via data.create_trace_entity (the SAME minted-id, fail-closed-if-
## refused path every other authoring tool on this board uses), then ONE
## save_to_history call for the whole batch — "one journal step for the whole
## bus, one undo removes all N" (docket 019fb572b888 S4).
##
## FAIL-CLOSED MID-BATCH: create_trace_entity refusing net i is defensive
## (bus_plan already checked has_net/layer) but handled anyway — every trace
## already created THIS call is rolled back with data.remove_trace before
## returning, so a partial, un-journalled bus never sits on the board with no
## undo step able to remove it (nothing has been save_to_history'd yet; every
## add_trace so far is only in `traces`, not a journal entry the user can act
## on).
static func bus_commit_plan(data, plan: Dictionary, history_label: String) -> Dictionary:
	var nets: Array = plan.get("nets", [])
	var widths: Array = plan.get("widths", [])
	var polylines: Array = plan.get("polylines", [])
	var layer: String = str(plan.get("layer", ""))
	var created_ids: Array[String] = []
	for i in range(nets.size()):
		var trace = data.create_trace_entity(str(nets[i]), layer, polylines[i], float(widths[i]))
		if trace == null:
			for tid in created_ids:
				data.remove_trace(tid)
			return {"ok": false, "error": "Bus was refused by the board model on net %s." % str(nets[i])}
		created_ids.append(str(trace.id))
	data.save_to_history(history_label)
	return {"ok": true, "error": "", "trace_ids": created_ids, "nets": nets, "widths": widths, "layer": layer}


## GHOST twin of bus_commit_plan (docket 019fcac1509d): the SAME ok'd plan, but
## the N traces land as workspace RouteCandidates (one per net, disposition
## "proposed") instead of board copper. NOTHING is journalled and the board is
## not mutated — resolution happens through the normal workspace verbs
## (minerva_pcb_workspace_commit/_reject/pin, or the canvas candidate menu),
## so a bus finally participates in the propose → steer → accept loop (S4)
## instead of being the one author verb that bypassed it.
##
## Each record carries the plan's exact offset polyline as raw router-shape
## segments ({start,end,layer}) plus a width_override — the per-net width
## bus_plan already resolved from the board's own copper — so ingest does not
## fall through to _width_from_hints' 0.25mm hintless default. source_hint_ids
## is [] ON PURPOSE (a legitimate "no hint answered this" verdict, docket
## 019fa109766f), which keys each candidate to the whole-net task: re-proposing
## the same bus supersedes the prior ghost per net, same as any re-propose.
## A PINNED prior holds its net's task (candidate not created, reported in
## holds) — identical semantics to _workspace_propose's ingest.
static func bus_propose_plan(workspace, data, plan: Dictionary) -> Dictionary:
	if workspace == null:
		return {"ok": false, "error": "no routing workspace is bound to this panel (headless / before mount)"}
	var nets: Array = plan.get("nets", [])
	var widths: Array = plan.get("widths", [])
	var polylines: Array = plan.get("polylines", [])
	var layer: String = str(plan.get("layer", ""))
	var revision: int = int(data.board_revision) if data != null else 0
	var landed: Array = []
	var holds: Array = []
	for i in range(nets.size()):
		var poly: PackedVector2Array = polylines[i]
		var segs: Array = []
		for j in range(poly.size() - 1):
			segs.append({
				"start": [poly[j].x, poly[j].y],
				"end": [poly[j + 1].x, poly[j + 1].y],
				"layer": layer,
			})
		var rec: Dictionary = {
			"net": str(nets[i]),
			"segments": segs,
			"vias": [],
			"source_hints": [],
			"source_hint_ids": [],
			"width_override": float(widths[i]),
		}
		var cid: String = str(workspace.ingest_record(rec, revision))
		# last_ingest_holds is PER CALL and ingest_record resets it on entry —
		# accumulate in-loop, same as _ingest_result_into_workspace.
		for hold in workspace.last_ingest_holds:
			holds.append(hold)
		if cid.is_empty():
			continue
		landed.append(_candidate_record(workspace, workspace.get_candidate(cid)))
	return {
		"ok": true, "error": "",
		"proposed": landed.size(), "candidates": landed, "holds": holds,
		"nets": nets, "widths": widths, "layer": layer,
	}


## Shared arg → plan parsing for the two bus MCP handlers (_route_bus_direct
## and _workspace_propose_bus): ordered nets + spine points + layer +
## width_override, then bus_plan. Returns bus_plan's own {ok, error, ...} shape
## so a parse refusal and a plan refusal surface identically.
static func _bus_plan_from_args(data, args: Dictionary) -> Dictionary:
	if not args.has("nets"):
		return {"ok": false, "error": "nets is required: an ordered array of declared net names (2+)"}
	var raw_nets = args.get("nets")
	if not (raw_nets is Array):
		return {"ok": false, "error": "nets must be an array of net names"}
	var nets: Array = []
	for n in raw_nets:
		nets.append(str(n))

	if not args.has("points"):
		return {"ok": false, "error": "points is required: an array of {x_mm, y_mm} spine vertices"}
	var pts = _parse_zone_outline(args.get("points"))
	if pts == null:
		return {"ok": false, "error": "points need x_mm and y_mm"}

	var layer: String = str(args.get("layer", ""))
	if layer.is_empty():
		var declared: Array = data.layers if data else []
		if declared.size() == 1:
			layer = str(declared[0])
		else:
			return {"ok": false, "error": "layer is required (the board declares %d copper layers, not exactly 1)." % declared.size()}

	var width_override: float = float(args.get("width_override", 0.0))
	return bus_plan(data, nets, pts, layer, width_override)


## minerva_pcb_workspace_propose_bus — the bus's PROPOSAL doorway (docket
## 019fcac1509d): same args, same validation path (_bus_plan_from_args →
## bus_plan) as minerva_pcb_route_bus_direct, but the plan lands as workspace
## candidates via bus_propose_plan instead of committing copper. The canvas
## gesture's Shift+Enter calls the SAME bus_propose_plan, so agent and human
## propose identical geometry by construction.
static func _workspace_propose_bus(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]

	var plan: Dictionary = _bus_plan_from_args(data, args)
	if not bool(plan.get("ok", false)):
		return _err(str(plan.get("error", "Bus was refused.")))

	var out: Dictionary = bus_propose_plan(workspace, data, plan)
	if not bool(out.get("ok", false)):
		return _err(str(out.get("error", "Bus proposal was refused.")))

	var reply: Dictionary = {
		"proposed": out.get("proposed", 0),
		"candidates": out.get("candidates", []),
		"holds": out.get("holds", []),
		"nets": out.get("nets", []),
		"widths": out.get("widths", []),
		"layer": str(out.get("layer", "")),
		"note": "ghost candidates landed in the routing workspace; no copper was committed — resolve via minerva_pcb_workspace_commit/_reject/pin.",
	}
	var cross: Dictionary = await _cross_candidate_check(host, workspace, data)
	if not cross.is_empty():
		reply["cross_candidate_check"] = cross
		if not (cross.get("findings", []) as Array).is_empty():
			reply["note"] = str(reply["note"]) \
				+ "; WARNING: the set-scoped check found findings across the live candidate set — see cross_candidate_check"
	return _ok(reply)


## minerva_pcb_route_bus_direct — the agent's doorway onto the SAME gesture
## the canvas Bus tool draws (see the region doc above): an ORDERED net list
## (T11 — echoed back verbatim, never re-sorted) plus a spine polyline in one
## call, same validation path (bus_plan), same single journal step
## (bus_commit_plan), same named refusal shape. `layer` defaults to
## trace_author_layer()'s own rule (toolbar filter, else TRACE_DEFAULT_LAYER)
## is NOT available here (no canvas/toolbar in an MCP call) — an agent must
## name the layer explicitly, or the board's only declared copper layer is
## used when there is exactly one.
static func _route_bus_direct(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data

	var plan: Dictionary = _bus_plan_from_args(data, args)
	if not bool(plan.get("ok", false)):
		return _err(str(plan.get("error", "Bus was refused.")))

	var result: Dictionary = bus_commit_plan(data, plan, "Add bus (%d traces)" % (plan.get("nets", []) as Array).size())
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", "Bus was refused by the board model.")))

	return _ok({
		"trace_ids": result.get("trace_ids", []),
		"nets": result.get("nets", []),
		"widths": result.get("widths", []),
		"layer": str(result.get("layer", "")),
		"undo_note": "one board history step: Ctrl+Z (or PCBData.undo) removes all traces this call created.",
	})


static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
