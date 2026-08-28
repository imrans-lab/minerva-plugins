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

## Legacy split+via+layer-run-toggle geometry (U4) lives on
## pcb_route_hint_kind.gd as apply_via_at_point for _add_via below. The canvas
## Via tool no longer uses it: DCR 01a0033a12a9 made that gesture propose an
## independent via entity instead of editing a route hint.
const _PcbRouteHintKindScript := preload("kinds/pcb_route_hint_kind.gd")
## T1.5: the ONE canonical layer/via-span contract (top/bottom <-> F.Cu/B.Cu).
const PcbLayerStack := preload("model/pcb_layer_stack.gd")
## A7: the plugin-scoped preference store. The SAME process-wide instance the
## panel reads (pcb_prefs.shared()), which is what makes an agent's write and a
## human's turn of the width box two views of one value rather than two stores.
const _PcbPrefsScript := preload("model/pcb_prefs.gd")
## The Options block — one read and one write shared with the panel's Options
## menu, so a click and this verb are the same operation.
const _PcbOptionsMenuScript := preload("pcb_options_menu.gd")
const _PcbBoardHistoryScript := preload("pcb_board_history.gd")
## B2 (MCP parity round): static-func + const access for the zone outline
## helpers (zone_outline_to_list/zone_outline_points, MIN_ZONE_OUTLINE_POINTS)
## without depending on GDScript's instance-forwarding for consts across a
## duck-typed `data` reference — mirrors pcb_canvas.gd's own PCBDataScript
## const, same off-tree preload-by-path convention.
const _PcbDataScript := preload("model/pcb_data.gd")
## The region read: ONE call for everything inside a board rectangle. Its own file — this one is a god file and gets DISPATCH
## WIRING ONLY. It also owns the per-via layers_touched derivation that
## minerva_pcb_list_vias below now reports.
const _PcbRegionDescribe := preload("model/pcb_region_describe.gd")
## The pin→net invariant and the two membership verbs. Kept off panel_tools
## so the "a pin is on one net" rule has one home both this surface and the
## panel's loader read.
const _PcbNetMembershipScript := preload("model/pcb_net_membership.gd")
## THE pad row. Every verb that describes a pad (get_selection, pin_info,
## free_pins, the move/rotate replies) emits this one shape.
const _PcbPadRowScript := preload("model/pcb_pad_row.gd")
## C4a: the disposition legality vocabulary (DISPOSITIONS, TERMINAL_DISPOSITIONS
## and the named refusal codes). Preloaded so the workspace verb tools NAME their
## refusals from the canonical const set instead of re-listing it — a second copy
## of the terminal set is a second thing to keep in step with the legality table.
const _PcbRouteCandidateScript := preload("model/pcb_route_candidate.gd")
const _PcbCopperOwnership := preload("model/pcb_copper_ownership.gd")
## C5 (S3+S4, DCR 019fb572b888): the pure bus-geometry module (S1+S2, shipped
## and pinned by test_pcb_bus_geometry.gd — a standing pin this file consumes
## and never edits). Zero imports itself.
const BusGeom := preload("model/pcb_bus_geometry.gd")
const PcbTraceGeometry := preload("model/pcb_trace_geometry.gd")
const PcbBusLabels := preload("model/pcb_bus_labels.gd")
const PcbViaDimensions := preload("model/pcb_via_dimensions.gd")
const PcbTraceWidth := preload("model/pcb_trace_width.gd")
const PcbBoardGraphic := preload("model/pcb_board_graphic.gd")
const StagedEntities := preload("model/pcb_staged_entities.gd")
## What a component's geometry IS (library / authored / sketch), and the one
## construction both add paths run. Owns the sketch-footprint name list too.
const PcbLibraryPart := preload("model/pcb_library_part.gd")
const _PcbComponentScript := preload("model/pcb_component.gd")


## Dispatch entry point — called by PCBPanel.handle_tool(tool_name, args).
## THE one type guard for Dictionary reads off worker replies (bug
## 019fa0f8d575, fixed epoch GA-6; twin of PCBPanel._dict_or_empty). GDScript
## hard-errors when a value of the wrong TYPE lands in a statically-typed
## var, and `.get(key, {})` defaults only on an ABSENT key — a JSON
## null/list/string at the key crashed the whole tool call. Every
## `var x: Dictionary = <reply>.get(...)` in this file goes through here;
## uniformity is the point, so apply it at any new site rather than
## re-deriving an inline ternary. `fallback` covers the rare site whose
## absent-key default is another Dictionary, not {}.
static func _dict_or_empty(v, fallback: Dictionary = {}) -> Dictionary:
	return v if v is Dictionary else fallback


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
		"minerva_pcb_set_board_layers":
			return _set_board_layers(host, args)
		"minerva_pcb_get_components":
			return _get_components(host, args)
		"minerva_pcb_get_nets":
			return _get_nets(host, args)
		"minerva_pcb_get_pin_position":
			return _get_pin_position(host, args)
		"minerva_pcb_pin_info":
			return _pin_info(host, args)
		# The four placement verbs are coroutines since work item 019fd5fe2724
		# (they await the pcb.assembly_check channel after mutating) — awaited
		# here exactly like _apply_route_hints/_load_board; handle() was already
		# a coroutine as a whole (see PCBPanel.handle_tool's Godot 4.6 note).
		"minerva_pcb_add_component":
			return await _add_component(host, args)
		"minerva_pcb_move_component":
			return await _move_component(host, args)
		"minerva_pcb_move_relative":
			return await _move_relative(host, args)
		"minerva_pcb_rotate_component":
			return await _rotate_component(host, args)
		"minerva_pcb_delete_component":
			return _delete_component(host, args)
		"minerva_pcb_connect_net":
			return _connect_net(host, args)
		"minerva_pcb_disconnect_net":
			return _disconnect_net(host, args)
		# The pad family: what is free on a part, and the two net edits a pad
		# selection affords. Each is ONE undo step.
		"minerva_pcb_free_pins":
			return _free_pins(host, args)
		"minerva_pcb_move_net":
			return _move_net(host, args)
		"minerva_pcb_swap_nets":
			return _swap_nets(host, args)
		"minerva_pcb_select":
			return _select(host, args)
		"minerva_pcb_spatial_query":
			return _spatial_query(host, args)
		"minerva_pcb_describe_region":
			return _describe_region(host, args)
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
		"minerva_pcb_cut_trace":
			return _cut_trace(host, args)
		"minerva_pcb_get_image":
			return await _get_image(host, args)
		"minerva_pcb_set_view":
			return _set_view(host, args)
		"minerva_pcb_view_state":
			return await _view_state(host, args)
		"minerva_pcb_apply_route_hints":
			return await _apply_route_hints(host, args)
		"minerva_pcb_hint_undo":
			return _hint_undo(host, args)
		"minerva_pcb_hint_redo":
			return _hint_redo(host, args)
		"minerva_pcb_board_drc":
			return await _board_drc(host, args)
		"minerva_pcb_undo":
			return _board_history(host, "undo")
		"minerva_pcb_redo":
			return _board_history(host, "redo")
		# Codex 1047 fix round, verdict 4: the NAMED guided→detailed conversion
		"minerva_pcb_hint_convert_to_detailed":
			return _hint_convert_to_detailed(host, args)
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
		"minerva_pcb_place_via":
			return _place_via(host, args)
		"minerva_pcb_propose_via":
			return _propose_via(host, args)
		"minerva_pcb_add_trace":
			return _add_trace(host, args)
		"minerva_pcb_update_via":
			return _update_via(host, args)
		"minerva_pcb_fabrication_stage":
			return _fabrication_stage(host, args)
		"minerva_pcb_delete_via":
			return _delete_via(host, args)
		"minerva_pcb_board_rules":
			return _board_rules(host, args)
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
		"minerva_pcb_add_silk_text":
			return _add_silk_text(host, args)
		"minerva_pcb_add_graphic":
			return _add_graphic(host, args)
		"minerva_pcb_delete_graphic":
			return _delete_graphic(host, args)
		"minerva_pcb_delete_cutout":
			return _delete_cutout(host, args)
		"minerva_pcb_propose_zone":
			return _propose_zone(host, args)
		"minerva_pcb_propose_cutout":
			return _propose_cutout(host, args)
		"minerva_pcb_propose_placement":
			return _propose_placement(host, args)
		"minerva_pcb_placement_update":
			return _placement_update(host, args)
		"minerva_pcb_staged_list":
			return _staged_list(host, args)
		"minerva_pcb_staged_accept":
			return await _staged_accept(host, args)
		"minerva_pcb_staged_freeze":
			return _staged_freeze(host, args)
		"minerva_pcb_staged_unfreeze":
			return _staged_unfreeze(host, args)
		"minerva_pcb_staged_reject":
			return _staged_reject(host, args)
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
		"minerva_pcb_get_selection":
			return _get_selection(host, args)
		"minerva_pcb_workspace_pin":
			return _workspace_pin(host, args)
		"minerva_pcb_workspace_unpin":
			return _workspace_unpin(host, args)
		"minerva_pcb_workspace_freeze":
			return _workspace_freeze(host, args)
		"minerva_pcb_workspace_unfreeze":
			return _workspace_unfreeze(host, args)
		"minerva_pcb_point":
			return _point(host, args)
		"minerva_pcb_hint_move_bend":
			return _hint_bend_edit(host, args, "move")
		"minerva_pcb_hint_insert_bend":
			return _hint_bend_edit(host, args, "insert")
		"minerva_pcb_hint_delete_bend":
			return _hint_bend_edit(host, args, "delete")
		"minerva_pcb_clear_hints_by_author":
			return _clear_hints_by_author(host, args)
		"minerva_pcb_export_yaml":
			return await _export_yaml(host, args)
		"minerva_pcb_list_mounting_holes":
			return _list_mounting_holes(host, args)
		"minerva_pcb_promote":
			return await _promote(host, args)
		"minerva_pcb_board_check":
			return await _board_check(host, args)
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
		# ── Epoch UX1 station 8 (DCR 019fd095e694): the ROUTE INTENT verb ──────
		"minerva_pcb_add_route_intent":
			return _add_route_intent(host, args)
		# Epoch UX1 station 10 (DCR 019fd095e694): the CANDIDATE-EDIT verb
		"minerva_pcb_workspace_edit_candidate":
			return _workspace_edit_candidate(host, args)
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


## Declare the board's copper stack (epoch GA-1). Accepts EITHER an explicit
## `layers` array (validated by the one GD shape rule, PcbLayerStack.
## stack_shape_error) or a `count` int (built through stack_for_count — the
## only stack shape that count admits, so the two spellings cannot diverge).
## Refusals — bad shape, or shrinking onto layers that still carry copper —
## come back verbatim from the model as errors; a no-op re-declaration reports
## changed=false. The reply always carries the (post-edit) declared stack so an
## agent needs no second read to learn what it may now author on.
static func _set_board_layers(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	# STRICT argument grammar (epoch GA repair round, Codex whole-epoch
	# review finding 5): the manifest says "Provide this OR layers" and
	# count >= 2 — silently preferring one of two conflicting spellings, or
	# clamping an invalid count up to a legal stack, answers a question the
	# caller didn't ask. Both-present refuses; count outside 2..32 refuses
	# by name instead of riding stack_for_count's clamp.
	if args.has("layers") and args.has("count"):
		return _err("Provide layers OR count, not both — they are two "
			+ "spellings of the same declaration and a conflict between "
			+ "them has no right answer")
	var new_layers: Array = []
	if args.has("layers"):
		var raw = args.get("layers")
		if not (raw is Array):
			return _err("layers must be an array of canonical copper layer names")
		new_layers = raw
	elif args.has("count"):
		# GDScript JSON numbers arrive as floats; accept whole-number floats.
		var count_raw = args.get("count")
		var count := int(count_raw)
		if float(count) != float(count_raw):
			return _err("count must be a whole number of copper layers")
		var max_copper: int = 2 + PcbLayerStack.MAX_INNER_LAYERS
		if count < 2 or count > max_copper:
			return _err("count must be between 2 and %d copper layers, got %d"
				% [max_copper, count])
		new_layers = PcbLayerStack.stack_for_count(count)
	else:
		return _err("Provide either layers (explicit canonical stack) or count (copper layer count)")
	var before: Array = data.layers.duplicate()
	var refusal: String = data.set_board_layers(new_layers)
	if not refusal.is_empty():
		return _err(refusal)
	var changed: bool = data.layers != before
	if changed:
		data.save_to_history("Set board layers")
	return _ok({"layers": data.layers.duplicate(), "changed": changed})


static func _get_components(host, _args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var components: Array = []
	for comp_id in data.components:
		var comp = data.components[comp_id]
		var comp_info := {
			"id": comp.id,
			"footprint": comp.get_footprint_name(),
			"x": _mm(comp.position.x),
			"y": _mm(comp.position.y),
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
				"x": _mm(data.member_offset(comp.id).x),
				"y": _mm(data.member_offset(comp.id).y)}
		components.append(comp_info)
	return _ok({"component_count": components.size(), "components": components})


static func _get_nets(host, _args: Dictionary) -> Dictionary:
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
		"world_position": {"x": _mm(world_pos.x), "y": _mm(world_pos.y)},
		"component_position": {"x": _mm(comp.position.x), "y": _mm(comp.position.y)},
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

	# `position` is NOT stamped here. It arrives with the rest of the pad row
	# from host.pin_info, as {x_mm, y_mm} — the shape
	# minerva_pcb_get_selection and minerva_pcb_free_pins also use. Overwriting
	# it here with a bare [x, y] from the same get_pin_world_position call would
	# make one reply family spell one coordinate two ways; the row is the one
	# spelling.
	return _ok(result)


static func _add_component(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	# The WHOLE construction — sketch layout, library-ref resolve, the refusals
	# — is PcbLibraryPart.build. This verb is the ONLY path a part takes onto
	# the board; nothing touches the board until the part is in hand.
	var built: Dictionary = await PcbLibraryPart.build(host, data, args)
	if not bool(built.get("ok", false)):
		return _err(str(built.get("error", "the component could not be built")))
	var comp = built["component"]
	data.add_component(comp)
	data.save_to_history("Add " + str(comp.id))
	# Work item 019fd5fe2724: placement changed — invalidate + re-check assembly,
	# attach the tri-state as `assembly` (coroutine; handle() awaits this verb).
	return await _with_assembly_after_placement(host, data, _with_snap_disclosure(
		_ok(PcbLibraryPart.add_reply(comp, built)),
		float(args.get("x", 50.0)), float(args.get("y", 50.0)), comp.position))


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
						"at": [_mm(endpoint.x), _mm(endpoint.y)],
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


## PLACEMENT-OP assembly surfacing (work item 019fd5fe2724, DCR 019fd5fd9084):
## after a placement verb (add/move/rotate/move_relative) has MUTATED the
## board, (a) the panel's assembly cache is invalidated FIRST — the old verdict
## describes a placement that no longer exists, and a refresh that fails below
## must not leave it standing — then (b) the pcb.assembly_check channel re-runs
## over the current board and the tri-state verdict is attached to the verb's
## reply as `assembly`, refreshing the cache (inside _run_assembly_check).
## Headless / channel-down degrades to {status:"indeterminate", ...} — attached,
## never silent, and NEVER a gate here (the gate lives at commit, where ghost
## geometry becomes copper). No-op on refusal replies: nothing mutated, the
## cache still tells the truth.
static func _with_assembly_after_placement(host, data, reply: Dictionary) -> Dictionary:
	if not bool(reply.get("success", false)):
		return reply
	var panel = _get_panel(host)
	if panel != null and panel.has_method("invalidate_assembly_state"):
		panel.invalidate_assembly_state()
	reply["assembly"] = await _run_assembly_check(host, data)
	return reply


## Snap disclosure (Epoch UX2 station 6, docket 019fde367b24): when the grid
## snap landed a placement somewhere OTHER than what the caller asked for,
## the reply says so — snapped:true + requested:[x,y] beside the landed
## coordinates. HITL-5: move_component silently snapped 70.68 → 71.12; an
## agent that doesn't diff request-vs-reply carries the stale number into
## corridor math. No keys when the request landed exactly (the common case).
## requested_x/requested_y are the caller's OWN 64-bit numbers, echoed
## verbatim (Codex 1049 finding 5: routing them through a Vector2 truncated
## them to float32 — 70.68 came back as 70.6800003051758).
static func _with_snap_disclosure(reply: Dictionary, requested_x: float, requested_y: float,
		landed: Vector2) -> Dictionary:
	if Vector2(requested_x, requested_y).distance_to(landed) > 0.0005:
		reply["snapped"] = true
		reply["requested"] = [requested_x, requested_y]
	return reply


## Stamp a placement reply with WHERE EVERY PAD LANDED. A move or a rotate that
## only answers "the component is at x,y, rotation 90" leaves the caller to work
## out which way pin 1 went, and a rotation convention guessed backwards routes
## to the wrong end of a part. The pads are in the model at the moment of the
## reply, so a second round trip through pin_info is pure ceremony. Same row
## shape get_selection and free_pins use.
##
## Only stamped onto a SUCCESS: a refusal moved nothing, and rows on it would
## read as "here is where it went".
static func _with_pad_rows(data, reply: Dictionary, component_id: String) -> Dictionary:
	if not bool(reply.get("success", false)) or data == null:
		return reply
	var comp = data.get_component(component_id)
	if comp == null:
		return reply
	reply["pads"] = _PcbPadRowScript.rows_for_component(data, comp)
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
	var asked_x: float = float(args.get("x", 0.0))
	var asked_y: float = float(args.get("y", 0.0))
	# FREEFORM MOVE (HITL-6, docket 019fdf2b939e — owner: "move to any
	# specified position"): snap_to_grid:false lands the part EXACTLY where
	# asked — sub-grid pin alignment (the straight-GND placement the forced
	# snap made unreachable) is now expressible. Default true: byte-identical
	# to every pre-existing call, and the snap disclosure below still reports
	# any snap that does happen.
	var do_snap: bool = bool(args.get("snap_to_grid", true))
	var new_pos: Vector2 = data.snap_to_grid(Vector2(asked_x, asked_y)) if do_snap \
		else Vector2(asked_x, asked_y)
	# A GROUPED component moves the WHOLE group, offsets preserved — the same
	# semantics a canvas drag has (A4). Ungrouped: unchanged, byte for byte.
	var group_reply := _move_component_group(data, component_id, new_pos)
	if not group_reply.is_empty():
		if bool(group_reply.get("success", false)):
			_with_snap_disclosure(group_reply, asked_x, asked_y, new_pos)
		# Work item 019fd5fe2724: assembly re-check on every mutating exit (the
		# helper no-ops on a locked-group refusal — nothing moved).
		return await _with_assembly_after_placement(host, data,
			_with_pad_rows(data, _with_dangling_copper(data, group_reply, pre_pins),
				component_id))
	data.move_component(component_id, new_pos)
	data.save_to_history("Move " + component_id)
	return await _with_assembly_after_placement(host, data, _with_pad_rows(data,
		_with_dangling_copper(data,
			_with_snap_disclosure(_ok({"component_id": component_id,
				"x": _mm(new_pos.x), "y": _mm(new_pos.y)}),
				asked_x, asked_y, new_pos), pre_pins), component_id))


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
		"x": _mm(new_pos.x),
		"y": _mm(new_pos.y),
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
		"new_x": _mm(new_pos.x),
		"new_y": _mm(new_pos.y),
		"interpreted_direction": direction,
	}
	if data.has_component(component_id):
		var pre_pins: Dictionary = _pre_transform_pins(data, component_id)
		# UX2 station 6: the reply's new_x/new_y previously echoed the
		# INTERPRETED point while the move landed on its SNAPPED position —
		# the reply now reports where the component actually IS, with the
		# snap disclosed against the interpreted point. snap_to_grid:false
		# (HITL-6 freeform, docket 019fdf2b939e) lands on the interpreted
		# point exactly.
		var landed: Vector2 = data.snap_to_grid(new_pos) \
			if bool(args.get("snap_to_grid", true)) else new_pos
		reply["new_x"] = _mm(landed.x)
		reply["new_y"] = _mm(landed.y)
		# Quantized at the CALL SITE, not inside the helper. For every other
		# caller `requested` is the caller's own 64-bit argument, echoed
		# verbatim on purpose; here it is arithmetic this surface performed on
		# float32 positions (the caller passed a direction, not a coordinate),
		# so it carries residue of our own making and must land on the same
		# grid as the new_x/new_y beside it.
		_with_snap_disclosure(reply, _mm(new_pos.x), _mm(new_pos.y), landed)
		# Group parity with _move_component: a grouped component carries its whole
		# group to the interpreted destination. The reply keeps new_x/new_y (the
		# ADDRESSED component's landing point) and adds the group fields.
		var group_reply := _move_component_group(data, component_id, landed)
		if not group_reply.is_empty():
			if not bool(group_reply.get("success", false)):
				return group_reply  # locked group — surface the refusal verbatim
			for key in ["group_id", "moved_components", "moved_count"]:
				reply[key] = group_reply[key]
			# Work item 019fd5fe2724: mutating exit — see _add_component's stamp.
			return await _with_assembly_after_placement(host, data,
				_with_pad_rows(data, _with_dangling_copper(data, _ok(reply), pre_pins),
					component_id))
		data.move_component(component_id, landed)
		data.save_to_history("Move " + component_id)
		return await _with_assembly_after_placement(host, data,
			_with_pad_rows(data, _with_dangling_copper(data, _ok(reply), pre_pins),
				component_id))

	# Non-mutating exit (component unknown to the model — interpretation only):
	# nothing moved, so no cache invalidation and no assembly re-check.
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

	# The WORDS mean what the human sees turn; the arithmetic behind them lives
	# with the numeric convention it has to match, in PCBComponent, so the
	# keyboard gesture and this verb cannot drift.
	var degrees = args.get("degrees", 90)
	var new_rotation: float = comp.rotation
	if degrees is String:
		if degrees.to_lower() == "clockwise":
			new_rotation = _PcbComponentScript.clockwise_from(comp.rotation)
		elif degrees.to_lower() == "counterclockwise":
			new_rotation = _PcbComponentScript.counterclockwise_from(comp.rotation)
		else:
			return _err("degrees must be a number, or the word 'clockwise' or 'counterclockwise' — got '%s'" % str(degrees))
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
		# Work item 019fd5fe2724: mutating exit — see _add_component's stamp.
		return await _with_assembly_after_placement(host, data, _with_pad_rows(data,
			_with_dangling_copper(data, _ok({
				"component_id": component_id,
				"rotation": comp.rotation,
				"group_id": group_id,
				"rotated_components": turned,
				"rotated_count": turned.size(),
			}), pre_pins), component_id))

	data.rotate_component(component_id, new_rotation)
	data.save_to_history("Rotate " + component_id)
	return await _with_assembly_after_placement(host, data, _with_pad_rows(data,
		_with_dangling_copper(data,
			_ok({"component_id": component_id, "rotation": new_rotation}), pre_pins),
		component_id))


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


## Membership is a MOVE, not an addition: pins already on another net are taken
## off it here, and the reply names them under `moved`. One undo step for the
## whole call (pcb_net_membership composes it).
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

	var connected: Dictionary = _PcbNetMembershipScript.connect_pins(data, net_name, pins)
	# A refusal is all-or-nothing and reports itself — never wrapped as success
	# with an empty result, which is what an unreadable or unknown pin used to
	# look like from here.
	if connected.has("error"):
		connected["success"] = false
		return connected
	return _ok(connected)


## The removal half of the membership pair. `net_name` is OPTIONAL and acts as a
## guard, not a selector — a pin belongs to at most one net, so naming it is a
## way of saying which net you believe holds the pin, and being told when that
## belief is stale rather than having the wrong membership removed.
static func _disconnect_net(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var pins: Array = args.get("pins", [])
	if pins.is_empty():
		return _err("pins array is required")
	var result: Dictionary = _PcbNetMembershipScript.disconnect_pins(
		data, pins, str(args.get("net_name", "")))
	if result.has("error"):
		result["success"] = false
		return result
	return _ok(result)


## What is AVAILABLE on a part: its pins on no net, as pad rows. A VERB rather
## than a flag on minerva_pcb_pin_info, deliberately — pin_info answers about ONE
## named pin, and "what is free over there" is the question asked when you do NOT
## know the pin. A verb with its own name is findable in the tool list where an
## optional argument on somebody else's verb is not.
##
## `side` filters to one side/COLUMN of the part ("free pins on the west column
## of U1S" is a read, not a coordinate scan). `exclude_roles` drops pins the
## board's own pin table flags — the owner's live filter is
## ["strapping","uart_console","onboard_led"]. Roles come from the BOARD (a
## pin's `roles` key, preserved verbatim through the canonical document), never
## from an agent's memory of a devkit; a board that declares none returns [].
static func _free_pins(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", "")).strip_edges()
	if component_id.is_empty():
		return _err("component_id is required")
	var comp = data.get_component(component_id)
	if comp == null:
		return _err("Component not found: %s" % component_id)
	var side: String = str(args.get("side", "")).strip_edges().to_lower()
	if not side.is_empty() and not (side in ["north", "east", "south", "west"]):
		return _err("side must be one of: north, east, south, west")
	var exclude: Array = _array_or_empty(args.get("exclude_roles"))
	var rows: Array = _PcbPadRowScript.free_pins(data, comp, side, exclude)
	var reply: Dictionary = {
		"component_id": component_id,
		"free_count": rows.size(),
		"free_pins": rows,
		"pin_count": comp.pins.size(),
	}
	if not side.is_empty():
		reply["side"] = side
	if not exclude.is_empty():
		reply["excluded_roles"] = exclude
	if rows.is_empty():
		reply["note"] = "every pin of %s that matches the filter is already on a net" % component_id
	return _ok(reply)


## MOVE one pin's net onto another pin, ONE undo step — the verb twin of the
## pad selection's "Move net to…". The source pin comes off
## the net, the destination goes on it, and a destination that was on another
## net is taken off it and named under `displaced`.
static func _move_net(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var from_ref: String = str(args.get("from", "")).strip_edges()
	var to_ref: String = str(args.get("to", "")).strip_edges()
	if from_ref.is_empty() or to_ref.is_empty():
		return _err("from and to are required, each a \"Component.Pin\" ref")
	var result: Dictionary = _PcbNetMembershipScript.move_net(data, from_ref, to_ref)
	if result.has("error"):
		result["success"] = false
		return result
	result["pads"] = _PcbPadRowScript.rows_for_refs(data, [from_ref, to_ref])
	_refresh_pad_selection(host)
	return _ok(result)


## EXCHANGE the nets of two pins, ONE undo step — the BTN3/BTN4 swap the owner
## does by hand today, and the verb twin of the selection's "Swap nets".
static func _swap_nets(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var pins: Array = _array_or_empty(args.get("pins"))
	if pins.size() != 2:
		return _err("pins must name exactly two pads, e.g. [\"U1S.8\", \"U1S.9\"]")
	var ref_a: String = str(pins[0]).strip_edges()
	var ref_b: String = str(pins[1]).strip_edges()
	var result: Dictionary = _PcbNetMembershipScript.swap_nets(data, ref_a, ref_b)
	if result.has("error"):
		result["success"] = false
		return result
	result["pads"] = _PcbPadRowScript.rows_for_refs(data, [ref_a, ref_b])
	_refresh_pad_selection(host)
	return _ok(result)


## THE MIRROR of minerva_pcb_get_selection for a WHOLE selection: the caller
## sets what is selected, so "these are the pins I mean" is something it can
## SHOW rather than describe. minerva_pcb_point is the
## single-entity form and stays exactly as it was; this one takes a list and
## adds pads, addressed by their "REF.PIN" row address.
##
## Returns the resulting selection through _get_selection itself, so what this
## verb says it selected and what the deictic read reports cannot diverge.
static func _select(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("select_entities"):
		return _err("no live panel — selection is a canvas concept")
	var entries: Array = []
	for raw in _array_or_empty(args.get("pads")):
		entries.append({"kind": "pad", "id": str(raw)})
	for raw in _array_or_empty(args.get("entities")):
		if raw is Dictionary:
			entries.append({"kind": str((raw as Dictionary).get("kind", "")),
				"id": str((raw as Dictionary).get("id", ""))})
	if entries.is_empty():
		return _err("pads (\"Component.Pin\" refs) or entities ([{kind, id}]) is required")
	var res: Dictionary = panel.select_entities(entries)
	if not bool(res.get("ok", false)):
		return {"success": false, "error": str(res.get("error", "select_failed")),
			"note": str(res.get("message", ""))}
	var reply: Dictionary = {"selected": int(res.get("selected", 0))}
	if res.has("not_found"):
		reply["not_found"] = res["not_found"]
	var read: Dictionary = _get_selection(host, {})
	if read.has("selection"):
		reply["selection"] = read["selection"]
	reply["note"] = "the canvas selection is now this — the human sees it lit exactly as their own click would show it"
	return _ok(reply)


## An argument that must be a list, or an empty one. The typed-Dictionary
## guard's twin (see _dict_or_empty): an agent that sends a string where an
## array belongs gets a named refusal from the caller's own emptiness check
## rather than a cast to null and a crash three lines later.
static func _array_or_empty(value) -> Array:
	return value as Array if value is Array else []


## Nudge the panel's pad-selection sidebar after an MCP net edit. A net move
## changes what the section says without changing WHAT is selected, so nothing
## on the selection_changed feed would repaint it. No-op headless.
static func _refresh_pad_selection(host) -> void:
	var panel = _get_panel(host)
	if panel != null and panel.has_method("refresh_pin_selection_section"):
		panel.refresh_pin_selection_section()


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
	var reply: Dictionary = {
		"reference": reference_component,
		"radius_mm": _mm(radius),
		"nearby_count": results.size(),
		"nearby": results,
	}
	# COPPER IN THE SAME AREA (bug 019fa1cda337, acceptance check K28). The
	# question "what is ROUTED here" was unanswerable over MCP: this verb
	# returned components only, so an agent asked to reason about congestion or
	# to avoid existing copper had no way to see any of it — while the human's
	# marquee over the same rectangle picked all five kinds.
	var ref_comp = data.get_component(reference_component)
	if ref_comp == null:
		# The component vanished between the nearby-walk and here (or the
		# spatial index outlived it). Report what we have rather than inventing
		# a region centred on nowhere — a copper answer for the wrong rectangle
		# is worse than no copper answer.
		reply["copper"] = {"unavailable": "reference component not found on the board"}
		return _ok(reply)
	var comp_pos: Vector2 = ref_comp.position
	var region := Rect2(
		Vector2(comp_pos.x - radius, comp_pos.y - radius),
		Vector2(radius * 2.0, radius * 2.0))
	reply["copper"] = _copper_in_region(data, region)
	return _ok(reply)


## ONE READ of a board rectangle — components with their pad rows, traces with their free ends, vias with the layers their copper
## really meets, pours with their outlines, keepouts, cutouts and the notes
## anchored inside.
##
## READ-ONLY: nothing here mutates the board or journals anything.
##
## DISPATCH WIRING ONLY. Every answer is assembled in
## model/pcb_region_describe.gd, out of the surfaces that already own the
## rules — this file is a god file and does not get the region read's body.
##
## An EMPTY region is a legitimate answer, not an error: empty arrays, and the
## reply's `searched` list is what says the arrays are empty because nothing is
## there rather than because nothing was looked for.
static func _describe_region(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	for key in ["x_mm", "y_mm", "width_mm", "height_mm"]:
		if not args.has(key):
			return _err("%s is required — the region is a rectangle in board mm (x_mm, y_mm = its top-left corner)" % key)
	var width := float(args.get("width_mm", 0.0))
	var height := float(args.get("height_mm", 0.0))
	if width <= 0.0 or height <= 0.0:
		return _err("width_mm and height_mm must be greater than 0 (got %s x %s) — x_mm/y_mm name the corner, not the opposite corner" % [str(width), str(height)])
	var layer_in := str(args.get("layer", ""))
	if not layer_in.is_empty() and not PcbLayerStack.is_copper(layer_in):
		return _err("layer '%s' is not a copper layer — use \"top\", \"bottom\", \"in1\"..., a KiCad copper name, or omit it for every layer" % layer_in)
	var region := Rect2(Vector2(float(args["x_mm"]), float(args["y_mm"])),
		Vector2(width, height))
	var annotations: Array = []
	if host != null and host.has_method("get_all_annotations"):
		annotations = host.get_all_annotations() as Array
	return _ok(_PcbRegionDescribe.describe(data, region, layer_in, annotations))


## Every non-component entity the board has in `region`, using the SAME model
## queries the human's marquee walks — one implementation, two doorways, which
## is the whole parity principle.
##
## VIEW STATE IS DELIBERATELY IGNORED. The human's box-select honours layer
## visibility, because a person selects what they can see. An agent asking what
## is routed somewhere is asking a question about the BOARD, and an answer that
## changed with someone else's View-menu toggles would be unreproducible from
## the agent's side and quietly wrong. The reply says so rather than leaving the
## difference to be discovered.
static func _copper_in_region(data, region: Rect2) -> Dictionary:
	var traces: Array = data.get_traces_in_region(region)
	var vias: Array = data.get_vias_in_region(region)
	var zones: Array = data.get_zones_in_region(region)
	var cutouts: Array = data.cutouts_in_region(region)
	return {
		"region_mm": {"x_mm": _mm(region.position.x), "y_mm": _mm(region.position.y),
			"width_mm": _mm(region.size.x), "height_mm": _mm(region.size.y)},
		"traces": traces,
		"vias": vias,
		"zones": zones,
		"cutouts": cutouts,
		# COUNTS EVERY KIND IT LISTS. An earlier version summed traces, vias and
		# zones while also returning cutouts, so `count` disagreed with the
		# arrays beside it — a number that quietly means something other than
		# "how many things are in here" is worse than no number.
		"count": traces.size() + vias.size() + zones.size() + cutouts.size(),
		# NAME WHAT WAS SEARCHED. Without this an agent reading "traces: []"
		# cannot tell "nothing is routed here" from "traces were not looked
		# for" — and the first reading is the dangerous one, because it invites
		# routing straight through copper the query never examined.
		#
		# COMPONENTS ARE DELIBERATELY ABSENT from this list even though the
		# reply carries them: `nearby` was gathered over a RADIUS CIRCLE around
		# the reference part, while everything here was gathered over
		# `region_mm`, the square that circle inscribes. Listing them together
		# would imply one search where there were two, with different shapes.
		"searched": ["traces", "vias", "zones", "cutouts"],
		"searched_over": "region_mm (the square bounding the radius); `nearby` components used the radius circle instead",
		"note": "copper is reported regardless of layer visibility — this answers what the BOARD has, not what the panel currently shows",
	}


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
	var import_result: Dictionary = data.from_csv(csv_content)
	var result := {"component_count": data.get_component_count()}
	var dropped: Array = import_result.get("dropped_identity_extras", [])
	if not dropped.is_empty():
		result["dropped_identity_extras"] = dropped
		result["warnings"] = [{
			"code": "dropped_identity_extras",
			"message": "CSV identity changes discarded component extras; inspect dropped_identity_extras.",
			"components": dropped,
		}]
	return _ok(result)


static func _export_csv(host, _args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	return _ok({"csv": data.to_csv()})


static func _import_footprint_geometry(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var geometry_data: Dictionary = _dict_or_empty(args.get("geometry"))
	if geometry_data.is_empty():
		return _err("geometry data is required")
	var position_is_center: bool = bool(args.get("position_is_center", false))
	var invert_y: bool = bool(args.get("invert_y", false))

	var components_data: Dictionary = _dict_or_empty(geometry_data.get("components"))
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

	# Journal coordinates ride VERBATIM, deliberately. The journal is a record of
	# what happened, not a coordinate to compute against: rounding it would make
	# the record disagree with the move it describes, and the entries are
	# free-shaped so there is no boundary to round at anyway.
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
	var trace_data: Dictionary = _dict_or_empty(args.get("trace_data"))
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
##
## Routing workspace: deleting copper a COMMITTED route candidate owns retires
## that commit and REOPENS its routing task, reported as `reopened_candidate_ids`
## (see phase 3 below and RoutingWorkspace.reconcile_committed_copper). It
## rides the same single undo step as the copper itself.
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

	# Ownership pre-check (see _prune_foreign_commit_claims): a stale claim has to
	# be dropped while its copper is still on the board, or phase 3 cannot tell a
	# lie from a loss.
	_prune_foreign_commit_claims(host, data)

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

	# ── Phase 3: tell the ROUTING WORKSPACE its copper is gone. Copper the
	# caller just named may be copper a COMMITTED route candidate owns; the
	# reconcile retires that commit and reopens its task.
	#
	# BEFORE the snapshot: the delete's own history entry then carries BOTH
	# halves (bucket 8 — the copper gone AND the commit retired), so one undo
	# restores copper and commit together and one redo removes both again.
	# Copper leaving any other way is reconciled at the workspace verbs' own
	# entry (_workspace_ctx).
	var reopened: Array = []
	if not deleted_trace_ids.is_empty() or not deleted_via_ids.is_empty():
		reopened = _reconcile_committed_copper(host, data)
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
	# ADDITIVE, ABSENT WHEN EMPTY (the same rule missing_*/net_* keep above):
	# present only when the delete reopened routing work the caller did not
	# name.
	if not reopened.is_empty():
		reply["reopened_candidate_ids"] = reopened
		reply["note"] = "this copper was committed by %d route candidate(s); their commits are retired and their routing tasks are OPEN again (they are live once more, and any DRC verdict they held is staled — re-check or reroute before committing them)" % reopened.size()
	return _ok(reply)


static func _export_trace_geometry(host, _args: Dictionary) -> Dictionary:
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
				"start": {"x": _mm(start_pt.x), "y": _mm(start_pt.y)},
				"end": {"x": _mm(end_pt.x), "y": _mm(end_pt.y)},
				"width": _mm(float(trace.width)),
				"layer": layer_name,
				"net_name": trace.net_name,
			})

	var vias_output: Array = []
	for via in data.vias:
		var pos: Vector2 = via.get("position", Vector2.ZERO)
		var via_out := {
			"position": {"x": _mm(pos.x), "y": _mm(pos.y)},
			"size": _mm(float(via.get("size", 0.8))),
			"drill": _mm(float(via.get("drill", 0.4))),
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
## minerva_pcb_view_state — READ, and optionally SET, what the View menu shows
## (epoch NLC station C4, item 019ffeaccc0c).
##
## THE GAP THIS CLOSES. minerva_pcb_set_view aims the CAMERA. Nothing exposed
## what the camera was pointed at: an agent could not tell whether traces were
## drawn, whether an inner layer was hidden, or whether the fab preview was up —
## so it could not read its own minerva_pcb_get_image. In the N-layer co-design
## HITL the human could solo each layer and confirm the board while the agent
## beside them was blind to the same control. This is deliberately NOT
## layer-specific: every flag in the _VIEW_FLAGS family had the same gap, and a
## per-flag verb would have re-created it for the next flag added.
##
## ALWAYS RETURNS THE FULL RESULTING STATE, whether or not it changed anything —
## a setter whose reply an agent has to guess at is a setter it has to follow
## with a getter, and there is no getter to follow it with. `flags` is read off
## the LIVE canvas after the writes settle, so an overlay whose on-demand fetch
## failed reads false; `overlay_unavailable` (present only then) carries the
## reason, the same sentence the status bar shows the human.
##
## Writes (all optional, all absolute rather than relative — an absolute view is
## idempotent, and a toggle needs a read the caller may not have done):
##   flags: {<flag_name>: bool, ...}   any subset of view_flag_names()
##   hidden_layers: [canonical layer ids]   THE COMPLETE hidden set, not a delta
##
## VALIDATED IN FULL BEFORE ANYTHING IS APPLIED. A request naming one good flag
## and one typo changes nothing and says which was wrong, rather than leaving
## the view half-moved — the caller cannot see the screen to notice.
##
##   trace_layer_filter: "all" | a declared copper layer id
##
## THE FILTER AND THE EYES COMPOSE, ASYMMETRICALLY, and callers must know it:
## pcb_canvas._layer_visible gives a SPECIFIC filter priority over every
## per-layer eye. So hiding layers while a specific filter is in force changes
## the eye dictionary and nothing on screen. Applying `hidden_layers` therefore
## puts the filter back to "all" (reported in `changed`) so the eyes govern —
## otherwise the solo gesture would silently do the opposite of what was asked.
## An explicit `trace_layer_filter` in the SAME request is applied last and
## wins, so a caller can ask for both and get exactly what they wrote.
##
##   fab_preview_layer: "all" | an emitted layer key ("f_cu", "b_silks", "pth"…)
##
## THE ONLY WRITE VALIDATED AFTER IT IS APPLIED, and it has to be: its
## vocabulary is the ARTIFACT SET, which the `flags` write in this same request
## may have only just fetched, so there is nothing to validate against
## beforehand. A key the emitted set does not carry refuses by name, lists what
## WAS emitted, and reports in `changed` everything that did land — so the
## resulting view is fully described even though the request failed. Read it
## back from `fab_preview_layer`; the menu of legal values is
## `fab_preview_layers`, which is empty until the preview holds artwork.
##
##   working_layer: a declared copper layer id
##
## THE ONE THING HERE THAT IS NOT VIEW. It is where the canvas AUTHORS copper:
## the layer the trace tool, the zone tools and the bus draw on. It rides on this
## verb because an agent has to read it to know what the human's next gesture
## will do, and it is independent of every filter and eye above — setting it
## changes nothing on screen, and no view write moves it. The direct authoring
## verbs take an explicit `layer` and never consult it.
static func _view_state(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("get_canvas"):
		return _err("PCB view control not available")
	var canvas = host.get_canvas()
	if canvas == null or not is_instance_valid(canvas):
		return _err("PCB canvas not available (panel detached/headless)")
	var panel = host.get_panel() if host.has_method("get_panel") else null
	if panel == null or not panel.has_method("view_flag_names") \
			or not panel.has_method("set_view_flag"):
		return _err("PCB panel not available (detached, or predates view_state)")

	var flag_names: Array = panel.view_flag_names()
	var data = _get_data(host)
	var declared: Array = []
	if data != null and "layers" in data and data.layers is Array:
		declared = (data.layers as Array).duplicate()

	# ── validate everything first ────────────────────────────────────────────
	#
	# TYPES AS WELL AS NAMES. `bool(some_string)` is not a valid conversion in
	# GDScript and errors AT THE POINT OF USE — which, if it were left to the
	# apply loop below, would be after earlier flags had already been written:
	# precisely the partial application this station promises cannot happen.
	# The manifest schema constrains nothing inside `flags`, so a loosely-typed
	# caller sending {"show_traces": "true"} is an ordinary input, not an
	# exotic one.
	var want_flags: Dictionary = {}
	if args.has("flags"):
		var raw_flags: Variant = args.get("flags")
		# Refused, not swallowed. _dict_or_empty would have turned a wrong-typed
		# `flags` into {} and reported success, which is the silent no-op the
		# sibling hidden_layers check already refuses by name.
		if not (raw_flags is Dictionary):
			return {"success": false, "error": "invalid_args",
				"note": "flags must be an object of {flag_name: true|false}"}
		want_flags = raw_flags
		for k in want_flags.keys():
			if not (str(k) in flag_names):
				return {"success": false, "error": "unknown_view_flag",
					"unknown": str(k), "known_flags": flag_names,
					"note": "no View flag is called '%s'" % str(k)}
			if not (want_flags[k] is bool):
				return {"success": false, "error": "invalid_args",
					"note": "flag '%s' must be true or false, got %s"
						% [str(k), str(want_flags[k])]}

	var want_filter := ""
	var set_filter := args.has("trace_layer_filter")
	if set_filter:
		want_filter = str(args.get("trace_layer_filter", "")).strip_edges()
		if want_filter.is_empty():
			return {"success": false, "error": "invalid_args",
				"note": "trace_layer_filter must be \"all\" or a declared copper layer id"}
		if want_filter != "all":
			want_filter = PcbLayerStack.kicad_to_canon(want_filter)
			if not (want_filter in declared):
				return {"success": false, "error": "layer_not_on_stack",
					"unknown": str(args.get("trace_layer_filter", "")),
					"declared_layers": declared,
					"note": "this board declares %s — it cannot filter to '%s'"
						% [str(declared), str(args.get("trace_layer_filter", ""))]}
		if not panel.has_method("set_trace_layer_filter"):
			return {"success": false, "error": "unsupported",
				"note": "this panel predates the trace_layer_filter setter"}

	# The WORKING layer: authoring, not view. "all" is refused by name rather
	# than folded to a default — a caller that wrote it has confused this with
	# the filter beside it, and copper has to land on ONE layer.
	var want_working := ""
	var set_working := args.has("working_layer")
	if set_working:
		want_working = str(args.get("working_layer", "")).strip_edges()
		if want_working.is_empty() or want_working == "all":
			return {"success": false, "error": "invalid_args",
				"note": "working_layer must be a declared copper layer id — it is where copper is AUTHORED, and \"all\" is not a layer to draw on"}
		want_working = PcbLayerStack.kicad_to_canon(want_working)
		if not (want_working in declared):
			return {"success": false, "error": "layer_not_on_stack",
				"unknown": str(args.get("working_layer", "")),
				"declared_layers": declared,
				"note": "this board declares %s — it cannot author on '%s'"
					% [str(declared), str(args.get("working_layer", ""))]}
		if not panel.has_method("set_working_layer"):
			return {"success": false, "error": "unsupported",
				"note": "this panel predates the working layer"}

	var want_hidden: Array = []
	var set_hidden := args.has("hidden_layers")
	if set_hidden:
		var raw_hidden: Variant = args.get("hidden_layers")
		if not (raw_hidden is Array):
			return {"success": false, "error": "invalid_args",
				"note": "hidden_layers must be an array of canonical layer ids (the COMPLETE hidden set)"}
		# A board with no declared stack cannot answer "does this layer exist",
		# so a hide request against it is unanswerable rather than satisfied.
		# Applying it would hide nothing and report success — a silent no-op on
		# a request that named layers.
		if not (raw_hidden as Array).is_empty() and declared.is_empty():
			return {"success": false, "error": "no_declared_stack",
				"note": "this board declares no copper stack, so there is no layer to hide"}
		for entry in (raw_hidden as Array):
			# Refuse the EMPTY name explicitly: kicad_to_canon maps "" to "top"
			# with only a warning (it is the read side), so `hidden_layers: [""]`
			# would otherwise hide the top layer nobody named.
			if str(entry).strip_edges().is_empty():
				return {"success": false, "error": "invalid_args",
					"note": "hidden_layers contains an empty layer name — name a layer or omit it"}
			var canon := PcbLayerStack.kicad_to_canon(str(entry))
			if not (canon in declared):
				return {"success": false, "error": "layer_not_on_stack",
					"unknown": str(entry), "declared_layers": declared,
					"note": "this board declares %s — it has no layer '%s' to hide"
						% [str(declared), str(entry)]}
			want_hidden.append(canon)

	# ── apply ────────────────────────────────────────────────────────────────
	var changed: Array = []
	for k in want_flags.keys():
		var flag := str(k)
		var value := bool(want_flags[k])
		# AWAITED: set_view_flag runs the on-demand mask/fab-preview worker
		# round-trips, so returning before it settles would report a view as
		# applied while its artwork was still in flight.
		if bool(canvas.get(flag)) != value and await panel.set_view_flag(flag, value):
			changed.append(flag)
	if set_hidden and canvas.has_method("set_layer_hidden"):
		# THE FILTER MUST YIELD TO THE EYES FIRST (cold review 2, finding 1).
		# pcb_canvas._layer_visible gives a specific trace_layer_filter priority
		# over every per-layer eye, so hiding layers while a specific filter is
		# in force changes the eye dictionary and NOTHING on screen — the
		# solo gesture would silently do the opposite of what was asked. Reported
		# in `changed`, because it is a visible change to what is on screen.
		if panel.has_method("set_trace_layer_filter") \
				and str(canvas.get("trace_layer_filter")) not in ["", "all"]:
			if panel.set_trace_layer_filter("all"):
				changed.append("trace_layer_filter")
		for canon in declared:
			var should_hide: bool = str(canon) in want_hidden
			if bool(canvas.is_layer_hidden(str(canon))) != should_hide:
				canvas.set_layer_hidden(str(canon), should_hide)
				changed.append("layer:%s" % str(canon))
	# LAST, deliberately: an EXPLICIT filter in the same request outranks the
	# implicit "all" the hidden_layers path just set, so a caller can ask for
	# both and get what they literally asked for.
	if set_filter and str(canvas.get("trace_layer_filter")) != want_filter:
		if panel.set_trace_layer_filter(want_filter):
			if not ("trace_layer_filter" in changed):
				changed.append("trace_layer_filter")
	# AFTER the flags, of necessity — see the doc block. Straight to the canvas,
	# the same setter the View menu's picker writes through.
	if args.has("fab_preview_layer"):
		var want_fab := str(args.get("fab_preview_layer", "")).strip_edges()
		var fab_choices: Array = canvas.fab_preview_layer_choices() \
			if canvas.has_method("fab_preview_layer_choices") else []
		if not canvas.has_method("set_fab_preview_layer"):
			return {"success": false, "error": "unsupported",
				"note": "this panel predates the fab preview layer picker"}
		if str(canvas.get("fab_preview_layer")) != want_fab:
			if not canvas.set_fab_preview_layer(want_fab):
				# WHY IT HOLDS NOTHING is the actionable half. An empty picker
				# is almost never a mis-typed key: it is a preview that was
				# never fetched, or one a board edit retracted between the read
				# that listed the layers and this write.
				var empty_note := "" if fab_choices.size() > 1 else \
					" — the preview is holding no artwork at all; " \
					+ "raise View > Fab preview (show_fab_preview) and read " \
					+ "overlay_unavailable if it does not stay up"
				return {"success": false, "error": "layer_not_emitted",
					"unknown": want_fab, "available": fab_choices, "changed": changed,
					"note": "the fab preview holds %s — it has no layer '%s' to isolate%s"
						% [str(fab_choices), want_fab, empty_note]}
			changed.append("fab_preview_layer")
	# Independent of everything above: nothing in the view half reads or writes
	# it, so its ordering among the view writes cannot matter.
	if set_working and str(canvas.get("working_layer")) != want_working:
		if panel.set_working_layer(want_working):
			changed.append("working_layer")

	# ── report the whole resulting state ─────────────────────────────────────
	var flags_out: Dictionary = {}
	for name in flag_names:
		flags_out[str(name)] = bool(canvas.get(str(name)))
	var layers_out: Array = []
	for canon in declared:
		layers_out.append({
			"id": str(canon),
			"kicad": PcbLayerStack.canon_to_kicad(str(canon)) if PcbLayerStack.is_copper(canon) else "",
			"hidden": bool(canvas.is_layer_hidden(str(canon))) if canvas.has_method("is_layer_hidden") else false,
		})
	# WHY A FLAG A CALLER JUST RAISED READS FALSE. show_mask and
	# show_fab_preview come back down when their worker fetch returns nothing —
	# the flag may only claim a view that is actually on screen. The human is
	# told in the status lead; without this key the flag would read quietly
	# false with no reason anywhere in the reply. Absent when every raised
	# overlay is drawn.
	var overlay_out: Dictionary = panel.overlay_notes() \
		if panel.has_method("overlay_notes") else {}
	var out: Dictionary = {
		"flags": flags_out,
		"layers": layers_out,
		"trace_layer_filter": str(canvas.get("trace_layer_filter")),
		"working_layer": str(canvas.get("working_layer")),
		# The picker and its menu. `fab_preview_layers` is what the emitted set
		# actually contains, so a caller never has to guess a key.
		"fab_preview_layer": str(canvas.get("fab_preview_layer")),
		"fab_preview_layers": canvas.fab_preview_layer_choices() \
			if canvas.has_method("fab_preview_layer_choices") else [],
		"changed": changed,
	}
	if not overlay_out.is_empty():
		out["overlay_unavailable"] = overlay_out
	return _ok(out)


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
		if not canvas.has_method("zoom_to_fit"):
			return _err("PCB canvas cannot fit (no zoom_to_fit)")
		# Fitting needs a laid-out viewport to fit TO. Without this the fit is a
		# silent no-op and the reply reports the OLD camera as though it had
		# moved — the failure that reads as "the board disappeared".
		var vp: Vector2 = canvas.size
		if vp.x <= 0.0 or vp.y <= 0.0:
			return _err("PCB canvas has no viewport rect yet (panel not laid out)")
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
		# The declared copper stack (epoch GA-1): the stack is a mutable board
		# property now, and this metadata block is the board-facts read every
		# agent already gets with a look at the board.
		metadata["layers"] = data.layers.duplicate()
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

	# RENDER PREFLIGHT stamp (DCR 019fd5fd9084 item 3): a capture that actually
	# produced pixels marks the CURRENT board_revision as "seen" — board_health's
	# preflight.rendered_this_revision (see _attach_board_health) compares
	# against this. Stamped for BOTH delivery forms below (save_to_path write
	# failure falls through to its own error before reaching the stamp's return,
	# but the pixels were already rendered — stamping here, after encode, is the
	# honest "the model could have looked" point). Warn-only downstream, never a
	# refusal.
	var stamp_panel = _get_panel(host)
	if stamp_panel != null and stamp_panel.has_method("note_render_captured") and data != null:
		stamp_panel.note_render_captured(int(data.board_revision))

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


# ── minerva_pcb_board_drc: the two DRC checks over the LIVE board ────────────
#
# minerva_pcb_drc / minerva_pcb_drc_geometric stay backend tools that take a
# document (yaml/board) — the headless form CI and the Go stdio smoke use.
# This verb is their live-board twin: editor_name in, the panel's own
# to_board_dict out over the SAME backend tools (declared as this panel's IPC
# channels), snapshotted by reference when the board is over the broker cap —
# the pipe pcb.route and pcb.draft_check ride — so a large board never has to
# be exported, parsed and fed back. The reply is the worker's own findings
# payload; the board is never echoed.

static func _board_drc(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("worker_check"):
		return _err("no live panel — minerva_pcb_board_drc checks the board open in an editor; with a document in hand use minerva_pcb_drc / minerva_pcb_drc_geometric")
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var geometric: bool = bool(args.get("geometric", false))
	var channel: String = "minerva_pcb_drc_geometric" if geometric else "minerva_pcb_drc"
	var payload: Dictionary = {"board": data.to_board_dict()}
	if geometric and args.has("verbose_warnings"):
		payload["verbose_warnings"] = bool(args["verbose_warnings"])
	var reply: Dictionary = await panel.worker_check(channel, payload)
	if not bool(reply.get("success", false)):
		return reply
	var out: Dictionary = (reply.get("result", {}) as Dictionary).duplicate()
	out["check"] = "geometric" if geometric else "connectivity"
	out["board_source"] = "editor"
	return _ok(out)


# ── Board-level undo/redo (minerva_pcb_undo / minerva_pcb_redo) ──────────────
#
# The verb twins of Ctrl+Z / Ctrl+Shift+Z and the host's ribbon buttons. When
# a live panel is mounted the step goes THROUGH it (PCBPanel.board_undo/
# board_redo), so the status line and the pickers react exactly as they do to
# the keys; headless (no panel) the module steps the model directly.

static func _board_history(host, which: String) -> Dictionary:
	var panel = _get_panel(host)
	var result: Dictionary
	if panel != null and panel.has_method("board_undo"):
		result = panel.board_undo() if which == "undo" else panel.board_redo()
	else:
		var data = _resolve_data(host)
		if not (data is Object):
			return data
		result = _PcbBoardHistoryScript.undo(data) if which == "undo" \
			else _PcbBoardHistoryScript.redo(data)
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", which + "_failed")))
	return _ok({"action": str(result.get("action", "")),
		"undo_depth": int(result.get("undo_depth", 0)),
		"redo_depth": int(result.get("redo_depth", 0))})


## Codex 1047 fix round, verdict 4 — minerva_pcb_hint_convert_to_detailed:
## the NAMED live-editor operation for the guided→detailed transition on a
## SUPERSEDED hint. Verdict 4's ruling: this transition must remove the task
## constraint AND the supersession marker as one NAMED operation, then permit
## waypoint editing — a plain annotation patch cannot honestly coordinate
## that (the host's re-injection guard would restore a stripped marker, and
## nothing annotation-side can clear a workspace constraint), so it is a verb
## with its own refusal table instead.
##
## NOT ATOMIC — ordered two-store writes (Codex 1047 fix round, verdict 6):
## the constraint lives in the routing workspace (persisted in the workspace
## sidecar) and the marker lives on the annotation (persisted in the
## annotations sidecar) — two stores, two files, no transaction spans them. A
## crash between the two writes, or a later save that lands one sidecar but
## not the other, leaves a TORN state. The supported contract is therefore:
## ordered writes (workspace first, annotation second) + DETERMINISTIC
## LOAD-TIME RECONCILIATION (reconcile_superseded_waypoint_state below, run
## from the panel's load path once both sidecars are in memory) + the
## structured record each repair emits (workspace.last_load_reconciliation).
##
## Order of operations (workspace FIRST, annotation second — a refusal must
## land before ANY mutation, and the annotation release is the half that
## cannot fail once the constraint question is settled):
##   1. hint exists and is a pcb_route_hint, else hint_not_found /
##      not_a_route_hint.
##   2. Resolve the governing task via workspace.task_for_hint (singleton
##      preferred, membership fallback — that function's own contract):
##      (a) a CONSTRAINED task whose key names exactly this hint AND whose
##          constraint's owner_hint_id is this hint → clear
##          task.routing_constraint = {} (the workspace half, written first);
##      (b) a CONSTRAINED task that is merged/multi-hint, or whose constraint
##          names a different owner → REFUSE constraint_not_singly_owned:
##          clearing it would orphan or damage steering other hints share —
##          the reply names the owning task and the legal alternative
##          (steer via minerva_pcb_workspace_reroute_route);
##      (c) no task, or an UNCONSTRAINED task, while the marker is present →
##          proceed with the marker-only cleanup. This is the documented TORN
##          state (e.g. an undo of a prior conversion restored the marker but
##          not the constraint — see release_superseded_waypoints' own
##          undoability doc) and this verb is its named recovery.
##   3. A hint with NO marker and no singly-owned constraint has nothing to
##      convert → not_superseded (an ordinary hint's detail_level is plain
##      annotation data, editable through the normal update path).
##   4. host.release_superseded_waypoints(hint_id): ONE update with the
##      re-injection and edit-refusal guards stood down — strips the marker
##      plus the verdict-5 lock keys, sets detail_level "detailed". Undoable
##      as ONE history step (deliberate; rationale + the constraint-side
##      asymmetry live on that method's doc, the single home for the
##      decision).
##
## After success: the hint's waypoints are editable again (the host guard
## keys off the now-absent marker — pure payload state, nothing cached), the
## seeder's `detailed` gate guarantees no future propose re-seeds/re-stamps
## it, and route_bridge consumes the waypoints literally (as-drawn) — the
## reply's note says exactly that.
static func _hint_convert_to_detailed(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("get_by_id") \
			or not host.has_method("release_superseded_waypoints"):
		return _err("PCB annotation host not available")
	var hint_id: String = str(args.get("hint_id", ""))
	if hint_id.is_empty():
		return _err("hint_id is required")

	var ann: Dictionary = host.get_by_id(hint_id)
	if ann.is_empty():
		return {
			"success": false, "error": "hint_not_found", "hint_id": hint_id,
			"note": "no annotation with this id exists on the board — list route hints via minerva_annotations_list",
		}
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return {
			"success": false, "error": "not_a_route_hint", "hint_id": hint_id,
			"kind": str(ann.get("kind", "")),
			"note": "only a pcb_route_hint can be converted — this annotation is a %s" % str(ann.get("kind", "")),
		}

	var kp: Dictionary = _dict_or_empty(ann.get("kind_payload"))
	var has_marker: bool = kp.has("waypoints_superseded_by_constraint_revision")

	# ── the workspace half: clear (case a), refuse (case b), or skip (case c) ─
	var task_id: String = ""
	var cleared_constraint_revision: int = 0
	var workspace = _get_workspace(host)
	var task = workspace.task_for_hint(hint_id) if workspace != null else null
	var cleared := false
	if task != null:
		task_id = str(task.task_id)
		if task.is_constrained():
			var owner_hints: Array = workspace.task_hint_ids(task_id)
			var singly_owned: bool = owner_hints.size() == 1 \
					and str(owner_hints[0]) == hint_id \
					and str((task.routing_constraint as Dictionary).get("owner_hint_id", "")) == hint_id
			if not singly_owned:
				# Case (b): a merged multi-hint task's constraint (or one
				# attributed to a different hint) is NOT this conversion's to
				# clear — doing so would orphan/damage steering the other
				# hint(s) share. Refuse BEFORE any mutation.
				return {
					"success": false, "error": "constraint_not_singly_owned",
					"hint_id": hint_id, "task_id": task_id, "hint_ids": owner_hints,
					"note": ("task '%s' owns the governing routing constraint and its key names %d hint(s) "
						+ "(%s) — converting this hint alone would orphan or damage steering they share. "
						+ "Steer that task via minerva_pcb_workspace_reroute_route instead, or reroute "
						+ "the individual hint's own task first.") % [task_id, owner_hints.size(), ", ".join(owner_hints)],
				}
			# Case (a): singly owned — the workspace half, written first (see
			# the two-store note in the header: NOT atomic with the annotation
			# release below; load-time reconciliation owns the torn shapes).
			cleared_constraint_revision = int((task.routing_constraint as Dictionary).get("revision", 0))
			# Same monotonic floor as reroute_route's clear_constraint (UX2
			# station 2 cold review F2) — a later constraint must never reuse
			# the cleared revision.
			if "constraint_revision_floor" in task:
				task.constraint_revision_floor = maxi(
					int(task.constraint_revision_floor), cleared_constraint_revision)
			task.routing_constraint = {}
			cleared = true

	if not has_marker and not cleared:
		# Nothing to convert: never stamped, and no singly-owned constraint to
		# clear. An ordinary hint's detail_level is plain annotation data —
		# edit it through minerva_annotations_update, not this verb.
		return {
			"success": false, "error": "not_superseded", "hint_id": hint_id,
			"note": "this hint carries no waypoints_superseded_by_constraint_revision marker and no "
				+ "singly-owned task constraint — there is nothing to convert; set detail_level via a "
				+ "normal annotation update instead",
		}

	# ── the annotation half: the host-sanctioned single-update release ────────
	var released: Dictionary = host.release_superseded_waypoints(hint_id)
	if not bool(released.get("ok", false)):
		return _err("conversion release failed: %s" % str(released.get("error", "unknown")))

	var reply: Dictionary = {
		"hint_id": hint_id,
		"task_id": task_id,
		"detail_level": "detailed",
		"note": "converted to 'detailed' — the supersession marker and offline locks are gone, the "
			+ "hint's waypoints are editable again, and routing will follow them literally (as-drawn) "
			+ "on the next propose; this hint is never re-seeded. The conversion is one undoable "
			+ "history step (minerva_pcb_hint_undo restores the annotation side only).",
	}
	if cleared:
		reply["cleared_constraint_revision"] = cleared_constraint_revision
	return _ok(reply)


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

	var kp: Dictionary = _dict_or_empty(ann.get("kind_payload"))

	# FROZEN GATE, BEFORE the annotation write (cold review, Epoch UX3
	# station 1, finding 3): this tool's own invariant is "both stores stay
	# geometrically identical — never one mutated without the other", and
	# sync_candidate_geometry now refuses on a frozen candidate. Refusing
	# AFTER host.update_annotation would leave the annotation carrying a via
	# the settled candidate does not — the divergence the invariant forbids —
	# under a success:true reply. So the freeze is checked first, and the
	# whole edit refuses by the same name the direct edit verbs use.
	var gate_workspace = _get_workspace(host)
	if gate_workspace != null and gate_workspace.has_method("candidate_for_annotation"):
		var gate_cid := str(gate_workspace.candidate_for_annotation(id))
		if not gate_cid.is_empty() and gate_workspace.has_method("is_frozen") \
				and gate_workspace.is_frozen(gate_cid):
			return {"success": false, "error": "candidate_frozen",
				"candidate_id": gate_cid,
				"note": "annotation '%s' bridges to frozen candidate %s — settled geometry does not edit; minerva_pcb_workspace_unfreeze first" % [id, gate_cid]}

	var result: Dictionary = _PcbRouteHintKindScript.apply_via_at_point(kp, float(args.get("x", 0.0)), float(args.get("y", 0.0)))
	if not bool(result.get("ok", false)):
		# error_code carried through verbatim (epoch NLC C1a): an agent
		# retrying a refused via needs to know whether it MISSED
		# ("no_segment_at_point" — move the point) or whether the layer itself
		# is unsupported ("unsupported_layer" — no point on this run will ever
		# work), and a prose message is not a thing to branch on.
		var refusal: Dictionary = _err(str(result.get("error", "could not insert via")))
		if result.has("error_code"):
			refusal["error_code"] = str(result["error_code"])
		return refusal

	var new_ann: Dictionary = ann.duplicate(true)
	var new_kp: Dictionary = _dict_or_empty(result.get("kind_payload"), kp)
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
			bridged_synced = bool(workspace.sync_candidate_geometry(
				cand_id, new_segments, new_vias, _get_data(host)))

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
	var workspace = _get_workspace(host)
	if workspace != null:
		_reconcile_hint_lifecycle(host, workspace)

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

	# Epoch UX1 station 12: one-time legacy waypoint-hint migration, BEFORE
	# the router runs — see _seed_legacy_waypoint_constraints' own doc for the
	# full contract (durability, one-time gate, net-resolution discipline).
	_seed_legacy_waypoint_constraints(host, workspace, data, source_hints)

	# F7 (cold review, Epoch UX1 station 9): this verb SHARES ONE router
	# round-trip across BOTH its branches (commit=true -> _materialize_routes,
	# commit=false -> _propose_into_workspace both read `result` off the SAME
	# reply below), so fixing this ONE _run_router call fixes both at once.
	# It never built the `task_constraints` half of `extra` at all — a
	# selected hint whose task carried a routing_constraint silently routed
	# UNSTEERED through this call, even though the identical hint would be
	# steered through minerva_pcb_workspace_propose. Mirrors that call's own
	# extra-building exactly: _route_request_extra(workspace, {}, hint_ids) —
	# no `scope` here (this verb's own contract never built one; DCR finding
	# 7 part 2 is propose/reroute-only), just the additive task_constraints
	# key. `workspace` may be null (headless/no mount) — _route_request_extra
	# already null-checks it, same as every other caller.
	var route_extra: Dictionary = _route_request_extra(workspace, {}, _hint_id_list(source_hints))
	# Epoch UX4 station 3 (DCR S3/A2): only the CANDIDATE-producing branch is
	# a draft request — commit=true lands real copper and must route against
	# the REAL board, uncomposed. The marker is panel-side (route_board's
	# params allow-list never forwards it to the worker).
	if not commit:
		route_extra["draft_request"] = true
	var reply: Dictionary = await _run_router(host, selection, route_extra)
	if not bool(reply.get("ok", false)):
		return _router_call_failed(reply, source_hints)

	var result: Dictionary = _dict_or_empty(reply.get("result"))
	if commit:
		return _materialize_routes(host, data, result, source_hints)
	return _propose_into_workspace(host, data, result, source_hints,
		reply.get("draft_context", {}) if reply.get("draft_context", null) is Dictionary else {})


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
## candidate keep-outs (DCR finding 7 part 1), an explicit `scope` (part 2),
## and — Epoch UX1 station 9 (DCR 019fd095e694) — `task_constraints` (part 3),
## each added ONLY when there is something to say. Nothing pinned, no scope
## derived and no selected hint's task constrained -> {} -> route_board stamps
## NONE of the three keys -> the pre-existing {board, route_hints, selection}
## wire payload, byte-for-byte (the no-regression requirement every one of
## these additive keys shares: "absent keeps today's behavior byte-identical").
## `hint_ids` is the SAME selected-hint-id list the caller already built for
## `selection` — passed separately (not re-derived from `scope`, which several
## callers deliberately leave empty) so a task_constraints lookup never depends
## on a scope having been computed.
static func _route_request_extra(workspace, scope, hint_ids: Array = []) -> Dictionary:
	var out: Dictionary = {}
	if workspace != null:
		# Pinned + FROZEN (Epoch UX3, K8): both ride the `pinned_candidates`
		# wire key — the worker treats every entry as fixed copper, which is
		# exactly what "frozen honored as committed copper" means, so no second
		# param exists to drift from the proven one.
		var keepouts: Array = workspace.keepout_candidates_wire()
		if not keepouts.is_empty():
			out["pinned_candidates"] = keepouts
	if scope is Dictionary and not (scope as Dictionary).is_empty():
		out["scope"] = scope
	var task_constraints: Dictionary = _task_constraints_for_hints(workspace, hint_ids)
	if not task_constraints.is_empty():
		out["task_constraints"] = task_constraints
	return out


## Station 9's propose-side half of "the task constraint becomes consumed":
## one entry per hint in `hint_ids` whose own task (workspace.task_for_hint —
## the same "net|hint_id[,...]" key format station 8's eager creation and
## ingest both mint) carries a routing_constraint. Wire shape per entry
## mirrors PcbRouteTask.routing_constraint verbatim: {corridor_points:[[x,y],
## ...], preferred_layer, revision} — route_bridge.hints_to_router reads this
## exact shape. Absent entirely (empty Dictionary) when no selected hint's
## task is constrained, which is the overwhelming common case — every hint
## nobody ever gave a corridor to.
##
## F3 (cold review): emitted ONLY when `hid_str` is the constraint's own
## owner_hint_id. Without this gate, a MERGED multi-hint task ("net|hidA,
## hidB" — H3-1 absorption) whose constraint answers hidA alone would echo
## that SAME corridor for hidB too, purely because task_for_hint(hidB) also
## resolves to the merged task — a duplicated-authority bug: steering one
## span of a net would silently also steer a sibling span nobody touched. An
## unattributed constraint (owner_hint_id == "", e.g. one written before this
## follow-up, or via a steer call that could not name a single owner) emits
## for NO hint — a safe no-op rather than a guess, same spirit as every other
## ambiguity refusal in this file.
static func _task_constraints_for_hints(workspace, hint_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	if workspace == null:
		return out
	for hid in hint_ids:
		var hid_str := str(hid)
		if hid_str.is_empty() or out.has(hid_str):
			continue
		var task = workspace.task_for_hint(hid_str)
		if task == null or not task.is_constrained():
			continue
		var c: Dictionary = task.routing_constraint
		if str(c.get("owner_hint_id", "")) != hid_str:
			continue
		out[hid_str] = {
			"corridor_points": _corridor_points_wire(c.get("corridor_points", [])),
			"preferred_layer": str(c.get("preferred_layer", "")),
			"revision": int(c.get("revision", 0)),
		}
	return out


## PcbRouteTask.routing_constraint.corridor_points (Array[Vector2] at runtime)
## -> the wire shape route_bridge._corridor_from_task_constraint parses:
## [[x,y], ...]. A stray non-Vector2 entry (should not occur — the field's own
## setter contract is Vector2-only, see pcb_route_task.gd) is skipped rather
## than crashing the request build.
static func _corridor_points_wire(points: Array) -> Array:
	var out: Array = []
	for p in points:
		if p is Vector2:
			out.append([_mm((p as Vector2).x), _mm((p as Vector2).y)])
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
## `endpoints` is deliberately omitted from the task entry on HINT-SCOPED
## reroutes: an endpoints list would ask parse_route_scope to validate a
## SPAN, and a reroute always means "the whole route for this task"
## (reroute-span is the documented degrade to whole-route, see
## _workspace_reroute_span) — never a span, so omitting it resolves to the
## whole net. The ONE exception is leg C's HINT-LESS fallback (DCR
## 01a022ab356c): with no hints to select, the candidate's own terminals are
## the run's only narrowing, so _workspace_reroute adds them to this scope
## via _endpoint_pin_refs below.
static func _reroute_scope(c, source_hints: Array, _data) -> Dictionary:
	for hint in source_hints:
		var kp: Dictionary = _dict_or_empty(hint.get("kind_payload"))
		if _is_bus_branch_hint(kp):
			return {}
	return {"tasks": [{"task_id": str(c.task_id), "net": str(c.net)}]}


## The candidate's endpoints as "Comp.Pin" wire strings (DCR 01a022ab356c
## leg C). The model stores endpoints as {component, pin} dicts
## (_endpoints_from_hints); route_bridge.parse_route_scope wants pad refs —
## and ONLY pad refs: a component-only entry (empty pin) is skipped rather
## than emitted, because "U1" is never a routable terminal and the worker
## would refuse the whole scope over it.
static func _endpoint_pin_refs(c) -> Array:
	var out: Array = []
	for e in c.endpoints:
		if e is Dictionary:
			var comp := str((e as Dictionary).get("component", ""))
			var pin := str((e as Dictionary).get("pin", ""))
			if comp.is_empty() or pin.is_empty():
				continue
			out.append("%s.%s" % [comp, pin])
		elif str(e).contains("."):
			out.append(str(e))
	return out


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
		var kp: Dictionary = _dict_or_empty(hint.get("kind_payload"))
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


## Error kinds that mean the router worker DID NOT ANSWER — no worker envelope
## came back at all. "worker_unavailable": no IPC bridge reachable (headless, no
## broker mounted, channel unregistered). "worker_error": the broker replied
## WITHOUT an {ok,…} envelope (transport or backend fault). "": an {ok:false}
## carrying no error dict, which says nothing either way. Every OTHER kind is a
## worker envelope: the worker answered, and its answer was a refusal.
const _ROUTER_NO_ANSWER_KINDS: Array[String] = ["", "worker_unavailable", "worker_error"]


## Structured failure-as-feedback for a route call that produced no result —
## either because the worker never answered, or because it answered "no".
##
## BACKEND STOPPED is its own answer.
## PCBPanel.route_board() tags a reply whose error_code was "plugin_not_running"
## (the pcb backend subprocess is not RUNNING — PluginScenePanelBroker.
## _dispatch_to_plugin_backend's own check) with error.kind ==
## "plugin_not_running" specifically. Callers that need a human-actionable
## message (the Propose button) key off error=="pcb_backend_stopped"; agents get
## the same signal plus recovery_hint="start via minerva_plugin_start" in the
## machine shape.
##
## A WORKER REFUSAL IS NOT SILENCE. The worker's own {ok:false, error:{kind,
## message}} envelope — unsupported_geometry, unsupported_scope, parse, route —
## is reported as "route_worker_refused" carrying that kind and message, so the
## named fix is the board's, not "restart a worker that is running fine".
## route_worker_unavailable is reserved for the no-answer kinds above.
static func _router_call_failed(reply: Dictionary, source_hints: Array) -> Dictionary:
	var err: Dictionary = _dict_or_empty(reply.get("error"))
	var kind: String = str(err.get("kind", ""))
	if kind == "plugin_not_running":
		return {
			"success": false,
			"error": "pcb_backend_stopped",
			"detail": err,
			"hint_ids": _hint_id_list(source_hints),
			"recovery_hint": "start via minerva_plugin_start",
			"note": "Routing needs the pcb backend, and it is not running. Start it (minerva_plugin_start, plugin_id \"pcb\"), then retry.",
		}
	if not _ROUTER_NO_ANSWER_KINDS.has(kind):
		var message: String = str(err.get("message", ""))
		var note: String = "Router worker refused this run (%s)" % kind
		if not message.is_empty():
			note += ": %s" % message
		note += ". The worker answered — this is the board's geometry or the run's scope, not an outage."
		return {
			"success": false,
			"error": "route_worker_refused",
			"kind": kind,
			"message": message,
			"detail": err,
			"hint_ids": _hint_id_list(source_hints),
			"note": note,
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
		var payload: Dictionary = _dict_or_empty(ann.get("kind_payload"))
		if payload.has("proposal_for"):
			continue  # an AI proposal — not a source hint
		if not wanted.is_empty():
			if wanted.has(str(ann.get("id", ""))):
				out.append(ann)
		elif str(ann.get("lifecycle", "open")) == "open":
			out.append(ann)
	return out


## Epoch UX1 station 12 (DCR 019fd095e694, docket 019fd057ea0b comment 1028,
## §"LEGACY WAYPOINT-HINT MIGRATION" — adopted verbatim): ONE-TIME seeding of
## a legacy hint's inline kind_payload.waypoints into its own task's durable
## routing_constraint, run at PROPOSE-TIME hint gathering — both
## minerva_pcb_apply_route_hints and minerva_pcb_workspace_propose call this
## right after _gather_route_hints, BEFORE _run_router — so the write lands
## even when the router leg that follows never succeeds (1028: "steering
## durability must not depend on obtaining a candidate").
##
## Station 8's minerva_pcb_add_route_intent is the NEW-PATH tool and NEVER
## carries waypoints on its own hint (its corridor goes straight to the task —
## see that function's own doc). This is the COMPATIBILITY path for every
## hint authored before that station existed, or by any other caller still
## drawing waypoints onto a hint.
##
## Seeds a hint iff ALL of:
##   - kind_payload.detail_level != "detailed" — a 'detailed' hint IS the
##     as-drawn channel (route_bridge.materialize_detailed_hints consumes its
##     waypoints literally as the routed geometry, worker-side); it is NEVER
##     seeded and NEVER refused by PcbAnnotationHost's edit guard (station
##     12's other half) — it bypasses this whole mechanism by construction,
##     unconditionally.
##   - NOT a bus-branch hint (H1-1, fix round — _is_bus_branch_hint) — a bus
##     hint's waypoints are never the single-net corridor this station
##     writes; see the gate's own comment at the call site.
##   - kind_payload.waypoints is non-empty.
##   - the hint's net is cleanly derivable — mirrors route_bridge._net_for_hint's
##     own priority (net_names[0] if the board carries it, else the first
##     source_pins/dest_pins pin that resolves to a board net) via
##     _resolve_hint_net_for_seeding, kept to this file's own
##     completely-derivable-or-nothing discipline (_propose_scope's doc). A
##     hint this panel cannot resolve a net for is left UNSEEDED —
##     best-effort migration, not a refusal; it keeps routing off its own
##     legacy waypoints exactly as it always has.
##   - the hint's task (workspace.task_for_hint, singleton "net|hint_id" key —
##     the SAME key ensure_task/ingest mint, reused verbatim, never
##     reimplemented) is either UNKNOWN or that EXACT singleton — never a
##     task this hint merely MEMBERS (H1-2, fix round — a merged multi-hint
##     key some other hint's absorbed route already owns; see the gate's own
##     comment) — and carries NO routing_constraint yet. This is what makes
##     seeding ONE-TIME: a task already constrained by ANY channel (a prior
##     seed, an add_route_intent corridor, an explicit steer) is left
##     completely alone — its owning hint's waypoints are never re-read.
##
## SEEDED CONSTRAINT shape (PcbRouteTask.routing_constraint — the SAME dict
## every other station writes, plus two migration-only provenance keys 1028
## asked for by name):
##   corridor_points        the hint's OWN waypoints, converted to Vector2.
##   preferred_layer        the hint's kind_payload.layer.
##   revision                1 (a fresh constraint, same as station 8's).
##   authored_by             "migration" — distinct from "ai"/"human": this
##                           corridor was never actually AUTHORED by this
##                           call, it is a mechanical carry-over of what the
##                           hint already said.
##   base_board_revision     PCBData.board_revision at seed time.
##   owner_hint_id           hint_id — unambiguous by construction (the
##                           eagerly-minted task names exactly this one hint,
##                           same as station 8's own singleton task).
##   seeded_from_hint_id     hint_id again, explicit per 1028's own list
##                           ("Record seeded_from_hint_id and
##                           seeded_from_hint_revision").
##   seeded_from_hint_revision  the hint's OWN revision_stack size at seed
##                           time — how many prior edits its kind_payload has
##                           already been through (0 for a hint never edited).
##
## Once written, station 9's UNCHANGED _task_constraints_for_hints is the
## SOLE consumer any propose/reroute reads through, and
## route_bridge.hints_to_router OVERRIDES kind_payload.waypoints outright once
## a task_constraints entry exists for a hint (that function's own doc:
## constraint_pts REPLACES kp.waypoints, never merged with it). ASSERTION:
## this function's is_constrained() gate above, together with
## _task_constraints_for_hints' identical gate (station 9, unmodified by this
## station — it emits a task's constraint only under its own owner_hint_id,
## never re-deriving anything from the hint's waypoints), together guarantee
## a constrained task's owning hint's waypoints are read for ROUTING exactly
## ONCE: at the seed that first constrains the task. No later propose/reroute
## re-reads them.
##
## Immediately after seeding, the hint is stamped
## kind_payload.waypoints_superseded_by_constraint_revision via the SAME
## _stamp_waypoints_superseded station 9 already uses for a live steer — one
## marker, one meaning, regardless of which channel wrote the constraint that
## made the legacy field inert. PcbAnnotationHost.update_annotation (station
## 12's other half) refuses any FURTHER edit that changes kind_payload.waypoints
## on a hint carrying that marker — see that function's own doc.
##
## TWO-STORE CONTRACT (Codex 1047 fix round, verdict 6): the constraint write
## and the stamp above are ORDERED (constraint first) but NOT atomic — they
## land in two stores persisted to two different sidecar files. A crash
## between them, or a save of one sidecar without the other, is repaired
## deterministically at the next load by reconcile_superseded_waypoint_state
## (see its own doc for the authority rule and record shape) — never papered
## over by an atomicity claim.
##
## Deliberately NOT implemented here: 1028's step 4, a HARD REFUSAL of
## waypoint-carrying hints at propose time, is explicitly post-boundary — this
## function only ever ADDS a constraint, it never refuses a propose for a hint
## carrying legacy waypoints. That refusal, if the epoch ever adopts it, is a
## separate, later change to _gather_route_hints or its callers.
static func _seed_legacy_waypoint_constraints(host, workspace, data, source_hints: Array) -> void:
	if workspace == null or data == null:
		return
	for hint in source_hints:
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = _dict_or_empty(hint.get("kind_payload"))
		if str(kp.get("detail_level", "")) == "detailed":
			continue
		# H1-1 (fix round, epoch UX1 station 12): a BUS-BRANCH hint
		# (_is_bus_branch_hint — hint_type=="bus" with >=2 net_names, the
		# worker's own bus-branch ENTRY condition) is NEVER a single-net
		# corridor seed candidate — route_bridge.hints_to_router resolves it
		# through a DIFFERENT rule entirely (every present net_names entry, or
		# degenerate-zero; see _is_bus_branch_hint's own doc), never the
		# single corridor this station writes. Seeding one anyway would stamp
		# waypoints_superseded_by_constraint_revision on a hint whose
		# waypoints were never the routing input to begin with, and later
		# refuse edits to a field that was never inert — the SAME
		# "PROVEN REGRESSION" class _propose_scope's own doc names for the
		# scope builders (a bus hint mis-handled by the single-net rule);
		# this gate reuses that exact guard rather than re-deriving a second
		# bus check.
		if _is_bus_branch_hint(kp):
			continue
		var raw_waypoints: Array = kp.get("waypoints", []) if kp.get("waypoints", []) is Array else []
		if raw_waypoints.is_empty():
			continue
		var hint_id: String = str(hint.get("id", ""))
		if hint_id.is_empty():
			continue
		# ONE-TIME gate: any existing task this hint already attributes to
		# (exact singleton or merged-membership fallback — task_for_hint's own
		# priority) that is ALREADY constrained means some channel got here
		# first. Never re-read the hint's waypoints in that case.
		var existing_task = workspace.task_for_hint(hint_id)
		if existing_task != null:
			# H1-2 (fix round, MED): a task this hint merely MEMBERS (a merged
			# multi-hint key, H3-1 absorption) is never this seed's to touch,
			# constrained or not. The exact-singleton branch of task_for_hint
			# (hint_set.size()==1) is the ONLY shape this station itself ever
			# mints ("<net>|<hint_id>"); a membership match means some OTHER
			# hint's route already merged with this one and owns (or, on a
			# constraint conflict, deliberately DROPPED) whatever steering
			# applies now. Minting a fresh singleton beside that merged task
			# would resurrect a dropped conflict (or fork a corridor away from
			# the task the router actually answers for this hint) — strictly
			# worse than leaving a still-unconstrained legacy hint unseeded,
			# which is only ever the pre-station-12 behavior it always had.
			var owner_hints: Array = workspace.task_hint_ids(str(existing_task.task_id))
			if owner_hints.size() != 1 or str(owner_hints[0]) != hint_id:
				continue
			if existing_task.is_constrained():
				continue
		var net: String = _resolve_hint_net_for_seeding(kp, data)
		if net.is_empty():
			continue  # net not cleanly derivable — best-effort, no seed
		var corridor_points: Array = []
		for wp in raw_waypoints:
			corridor_points.append(_arr_to_vec2(wp))
		if corridor_points.is_empty():
			continue
		var task_id: String = "%s|%s" % [net, hint_id]
		var task = workspace.ensure_task(task_id, net)
		if task.is_constrained():
			continue  # ensure_task resolved onto an already-constrained task
		var revision_stack: Array = hint.get("revision_stack", []) if hint.get("revision_stack", []) is Array else []
		# Seed revision resumes above any clear's floor (UX2 station 2 cold
		# review F2) — for a never-cleared task this is the original 1.
		var seed_revision: int = (int(task.constraint_revision_floor) \
			if "constraint_revision_floor" in task else 0) + 1
		task.routing_constraint = {
			"corridor_points": corridor_points,
			"preferred_layer": str(kp.get("layer", "")),
			"revision": seed_revision,
			"authored_by": "migration",
			"base_board_revision": int(data.board_revision),
			"owner_hint_id": hint_id,
			"seeded_from_hint_id": hint_id,
			"seeded_from_hint_revision": revision_stack.size(),
		}
		_stamp_waypoints_superseded(host, hint_id, seed_revision)


## Net resolution mirror of route_bridge._net_for_hint's priority (Python,
## worker-side), kept to this file's own completely-derivable-or-nothing
## discipline (see _propose_scope's own doc for the established convention):
## try kind_payload.net_names[0] when the board carries it, else the first
## source_pins/dest_pins pin ref that resolves to a board net. "" when
## neither resolves — the caller's contract is "no seed" for that outcome,
## never a guess.
static func _resolve_hint_net_for_seeding(kp: Dictionary, data) -> String:
	var names: Array = _hint_net_names(kp)
	if not names.is_empty():
		var first: String = names[0]
		if _board_net_set(data).has(first):
			return first
		# stale net_names[0] — falls through to pin resolution, same as
		# _net_for_hint's own fallback.
	for key in ["source_pins", "dest_pins"]:
		var refs: Array = kp.get(key, []) if kp.get(key, []) is Array else []
		for raw_ref in refs:
			var ref := str(raw_ref)
			var dot := ref.rfind(".")
			if dot <= 0 or dot >= ref.length() - 1:
				continue
			var net := str(data.find_net_for_pin(ref.left(dot), ref.substr(dot + 1)))
			if not net.is_empty():
				return net
	return ""


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
## annotation side used, and `data` is the live board — the last two rungs of
## the width ladder (see _route_width) live there.
static func _normalize_route_records(result: Dictionary, source_hints: Array, data = null) -> Array:
	var records: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var rec: Dictionary = {
			"net": net,
			"segments": (route.get("segments", []) as Array).duplicate(true) if route.get("segments", []) is Array else [],
			"vias": (route.get("vias", []) as Array).duplicate(true) if route.get("vias", []) is Array else [],
			"width": _route_width(route, source_hints, net, data),
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
		# WIDTH PROVENANCE (docket 019fd0ab5af8): the worker already resolves
		# which source supplied this route's width (methods.py
		# _attach_effective_routing_rules — "caller_option"/"hint"/"board_rules"/
		# "engine_default"/"net_class"/"net_copper") and stamps it per-route as
		# route["effective_routing_rules"]["trace_width_mm"]. HITL found an
		# owner-drawn hint with no width fell back to the router's 0.25mm default
		# silently where 0.5mm was intended — this is what makes that fallback
		# OBSERVABLE instead of indistinguishable from an intentional 0.25mm.
		# Same absent-key contract as drc/drc_geometric above: an older worker
		# that never attached effective_routing_rules stamps nothing here, and
		# _ingest_result_into_workspace's stamping onto the candidate record
		# stays absent too (never invented).
		var erules: Dictionary = _dict_or_empty(route.get("effective_routing_rules"))
		var width_entry: Dictionary = _dict_or_empty(erules.get("trace_width_mm"))
		if width_entry.has("value"):
			rec["effective_width_mm"] = float(width_entry.get("value", 0.0))
			rec["effective_width_source"] = str(width_entry.get("source", ""))
		# STATION 9 (DCR 019fd095e694): the task routing_constraint revision that
		# steered this route, when a task_constraints entry (not legacy inline
		# waypoints) produced it — methods.py attaches "constraint_revision" onto
		# a route dict with the SAME absent-key contract as drc/drc_geometric
		# above (see route_bridge.hints_to_router's own doc). Carried through
		# unchanged so _ingest_result_into_workspace/_propose_into_workspace can
		# stamp it onto the candidate record without re-deriving it.
		if route.has("constraint_revision"):
			rec["constraint_revision"] = int(route.get("constraint_revision"))
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
static func _propose_into_workspace(host, data, result: Dictionary, source_hints: Array,
		draft_context: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]

	var records: Array = _normalize_route_records(result, source_hints, data)
	var revision: int = int(data.board_revision) if data != null else 0
	# OFC-3 provenance, F1-repaired (Codex 1188): consumed from the
	# COMPOSE-TIME draft_context the route reply carried — never re-sampled
	# here, a full worker round-trip after composition. An empty context means
	# the request was routed against the real board: no provenance, no gate.
	var draft_snapshot: Array = draft_context.get("draft_placements", []) \
		if draft_context.get("draft_placements", null) is Array else []
	var proposals: Array = []
	var holds: Array = []
	var unresolved_widths: Array = []
	for rec in records:
		var pts: Array = rec.get("polyline", [])
		if pts.size() < 2:
			continue  # degenerate polyline — _write_one_proposal used to skip these too
		var cid: String = str(workspace.ingest_record(rec, revision, data))
		# last_ingest_holds is PER CALL and ingest_record resets it on entry — see
		# _ingest_result_into_workspace's identical accumulation-in-loop note.
		for hold in workspace.last_ingest_holds:
			holds.append(hold)
		# Same per-call accumulation for a route whose copper width could not be
		# resolved. The ghost lands — a candidate is a
		# question, not a board edit — but commit refuses it by name, so the
		# state has to be visible HERE rather than at accept time.
		for miss in workspace.last_ingest_unresolved_widths:
			unresolved_widths.append(miss)
		if cid.is_empty():
			continue  # HELD — the task's active candidate is pinned; see `holds`
		if not draft_snapshot.is_empty():
			var cobj_stamp = workspace.get_candidate(cid)
			if cobj_stamp != null:
				cobj_stamp.draft_placements = draft_snapshot.duplicate(true)
		var entry: Dictionary = {
			"id": cid,
			"candidate_id": cid,
			"net": str(rec.get("net", "")),
			"layer": str(rec.get("layer", "F.Cu")),
			"waypoint_count": pts.size(),
			"source_hint_ids": rec.get("source_hint_ids", []),
			"width_mm": _mm(float(rec.get("width", 0.0))),
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
		# STATION 9: same additive key _stamp_constraint_revision stamps onto
		# the workspace-native candidate record, here in the pre-S5 proposals
		# shape for parity — absent when `rec` carries none.
		if rec.has("constraint_revision"):
			entry["constraint_revision"] = int(rec.get("constraint_revision"))
		# OFC-3 parity: the reply row says what the candidate now durably
		# knows — which ghost poses this copper depends on, with the derived
		# status (trivially "pending" at ingest, but one derivation serves
		# every surface).
		if not draft_snapshot.is_empty():
			entry["draft_placements"] = draft_snapshot.duplicate(true)
			_stamp_draft_placement_status(entry, host)
		proposals.append(entry)

	var reply: Dictionary = {
		"committed": false,
		"proposed": proposals.size(),
		"proposals": proposals,
		"holds": holds,
		# Routes no source could size: not the reply's stamp, not a hint, not
		# the net's own copper, not the board's design rule. Their candidates
		# carry width 0.0 / width_source "unresolved" and commit refuses them
		# by name, rather than fabricating copper at an invented width. Empty
		# on every ordinary propose.
		"unresolved_widths": unresolved_widths,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
		"drc_summary": result.get("drc_summary", {}),
		# (F1/F3 pass-throughs are appended below the literal — see the
		# _pass_through_result_key calls before the return.)
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
	}
	# Epoch UX1 station 11: same refresh as _ingest_result_into_workspace's
	# "propose" default — a non-empty landing gets the compact
	# legal-successors sentence instead of the bare note above.
	if not proposals.is_empty():
		reply["note"] = _next_steps("propose", {"count": proposals.size()})
	# docket 019fce3ac3f5 item 2 + F6 (HITL-4): capability notes split out of
	# stuck[], and since F6 summarised to a count on routing replies —
	# additive, absent-when-empty so a caller with no capability warnings
	# sees no shape change.
	var emitter_summary: Dictionary = _emitter_notes_summary_from_result(result)
	if not emitter_summary.is_empty():
		reply["emitter_notes_summary"] = emitter_summary
	_pass_through_result_key(reply, result, "span_outcomes")
	# UX2 station 6: per-route census credit ("merges N islands"), worker-owned
	# shape, same additive absent-when-empty convention as span_outcomes.
	_pass_through_result_key(reply, result, "island_deltas")
	# DCR 019fd5fd9084: board_health replaced the worker's old top-level
	# assembly_advisories key — verbatim pass-through + the two panel-owned
	# enrichment fields; DRAFT reply (composed request), so labeled and
	# cache-feed SKIPPED (UX4 station 3, A9).
	_attach_board_health(host, reply, result, true)
	return _ok(reply)


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
		# The width the ROUTER drew this net at — see _route_width.
		#
		# FAIL CLOSED, no invented literal. This is the path
		# that writes physical copper, so "I could not resolve a width" must not
		# resolve to 0.25mm: a board would gain 0.25mm traces with nothing in any
		# report saying the number was guessed rather than sourced. The route
		# lays no copper and names what it could not resolve; the rest of the
		# reply's routes are unaffected, exactly as for unusable segments below.
		var width: float = _route_width(route, source_hints, net, data)
		# GROUPED BY LAYER **AND WIDTH**. A segment that states its own
		# `width_mm` is copper the worker sized for that stretch specifically,
		# and one trace carries one width — so a route drawn at two widths
		# becomes two traces rather than one trace at whichever width won.
		# `width` above is the route-wide fallback for segments that state none.
		var by_group := {}
		var unresolved := false
		for seg in route.get("segments", []):
			if not (seg is Dictionary):
				continue
			var seg_width: float = maxf(0.0, float(seg.get("width_mm", 0.0)))
			if seg_width <= 0.0:
				seg_width = width
			if seg_width <= 0.0:
				unresolved = true
				break
			var lyr: String = str(seg.get("layer", "F.Cu"))
			var key := "%s|%s" % [lyr, seg_width]
			if not by_group.has(key):
				by_group[key] = {"layer": lyr, "width": seg_width, "segments": []}
			(by_group[key]["segments"] as Array).append({
				"start": _arr_to_vec2(seg.get("start", [0, 0])),
				"end": _arr_to_vec2(seg.get("end", [0, 0])),
			})
		if unresolved:
			failed.append({"net": net, "reason":
				"no trace width could be resolved for net '%s': the route reply carries no " % net
				+ "segment width_mm or effective_routing_rules.trace_width_mm, no source hint "
				+ "for this net authors a width_mm, the net has no established copper and the "
				+ "board declares no design_rules.trace_width_mm — no copper was created for it"})
			continue
		var made_any := false
		for key in by_group:
			var group: Dictionary = by_group[key]
			for polyline in _build_polylines_from_segments(group["segments"]):
				if polyline.size() < 2:
					continue
				var trace = data.new_trace()
				trace.net_name = net
				trace.layer = PcbLayerStack.kicad_to_canon(str(group["layer"]))
				trace.width = float(group["width"])
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
		# added. top<->bottom stays correct at ANY declared depth (epoch GA-1):
		# a THROUGH via spans the whole stack by definition, and through is the
		# only via kind v1 models — blind/buried never materialize here.
		var via_dims: Dictionary = PcbViaDimensions.from_board(data)
		var via_size: float = float(via_dims["diameter"])
		var via_drill: float = float(via_dims["drill"])
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
			var kp: Dictionary = _dict_or_empty(ann.get("kind_payload"))
			var links: Array = kp.get("proposal_for", []) if kp.get("proposal_for", []) is Array else []
			for linked in links:
				if str(linked) in consumed_ids:
					var pid := str(ann.get("id", ""))
					if not pid.is_empty() and host.remove_annotation(pid):
						removed_proposals.append(pid)
					break
	var reply: Dictionary = {
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
	# docket 019fce3ac3f5 item 2 + F6 (HITL-4): same summarised split as
	# _propose_into_workspace above — additive, absent-when-empty.
	var emitter_summary: Dictionary = _emitter_notes_summary_from_result(result)
	if not emitter_summary.is_empty():
		reply["emitter_notes_summary"] = emitter_summary
	_pass_through_result_key(reply, result, "span_outcomes")
	# UX2 station 6: per-route census credit ("merges N islands"), worker-owned
	# shape, same additive absent-when-empty convention as span_outcomes.
	_pass_through_result_key(reply, result, "island_deltas")
	# DCR 019fd5fd9084: board_health replaced assembly_advisories — see
	# _attach_board_health (pass-through + panel enrichment + cache feed).
	_attach_board_health(host, reply, result)
	return reply


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


## docket 019fce3ac3f5 item 2: ~28 per-COMPONENT emitter-capability warnings
## ("feature_omitted", "captured_geometry_not_emitted", "ordinal_ids" — the
## worker's own capability bookkeeping, not routing feedback) rode stuck[] on
## every single propose and buried the 1-3 real per-hint routing warnings
## under them — unread through two HITL cycles. These three codes are the
## split key between _stuck_from_result (genuine stuck) and
## _emitter_notes_from_result (capability noise) below.
const _EMITTER_NOTE_CODES: Array[String] = [
	"feature_omitted", "captured_geometry_not_emitted", "ordinal_ids",
]

## unrouted nets (+ bridge warnings) → structured "stuck" feedback the agent can
## reason about: which net, which pad pair is blocked. Emitter-capability notes
## (see _EMITTER_NOTE_CODES) are excluded — they ride result["emitter_notes"]
## via _emitter_notes_from_result instead (docket 019fce3ac3f5 item 2); a
## warning without a "code", or whose code isn't a capability note, is treated
## as genuine stuck feedback, same as before this split.
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
		if w is Dictionary and str((w as Dictionary).get("code", "")) in _EMITTER_NOTE_CODES:
			continue
		stuck.append({"warning": w})
	return stuck


## Sibling of _stuck_from_result: the emitter-capability notes it filters OUT,
## kept verbatim (same {"warning": …} wrapper stuck[] entries used) so nothing
## is silently dropped — just moved off the channel the real routing warnings
## need to be readable in (docket 019fce3ac3f5 item 2).
static func _emitter_notes_from_result(result: Dictionary) -> Array:
	var notes: Array = []
	for w in result.get("warnings", []):
		if w is Dictionary and str((w as Dictionary).get("code", "")) in _EMITTER_NOTE_CODES:
			notes.append({"warning": w})
	return notes


## F1/F3 (HITL-4, docs/llm-ergonomics.md): copy one additive worker-result
## key onto a reply VERBATIM — worker owns the shape; absent/empty stays
## absent (the same absent-when-empty contract every additive key here uses).
static func _pass_through_result_key(reply: Dictionary, result: Dictionary, key: String) -> void:
	var v: Variant = result.get(key)
	if v is Array and not (v as Array).is_empty():
		reply[key] = v


## Dictionary-typed sibling of _pass_through_result_key (DCR 019fd5fd9084):
## same verbatim / absent-when-empty contract, for worker-result keys whose
## value is an object rather than a list (board_health). Kept separate rather
## than widening the Array helper's type check — each call site names exactly
## the shape it expects, so a worker shape drift fails loudly as an absent key
## instead of passing the wrong container through.
static func _pass_through_result_dict(reply: Dictionary, result: Dictionary, key: String) -> void:
	var v: Variant = result.get(key)
	if v is Dictionary and not (v as Dictionary).is_empty():
		reply[key] = v


## ── board_health attach + panel enrichment (DCR 019fd5fd9084) ─────────────────
##
## The worker's whole-board health ledger ({complete:true|false|null,
## missing_copper:[net], partial:[{net,pin_groups}]?, indeterminate:[...]?,
## assembly:{status:"pass"|"findings"|"indeterminate", findings, ...},
## approximate:true} — always present on ok routing results; the old top-level
## assembly_advisories key is GONE) is passed through VERBATIM, then enriched
## with the two fields only the PANEL can know:
##
##   board_health.board_revision  — the live PCBData.board_revision, so a caller
##                                  can tell which board state the verdict
##                                  describes (the same provenance stamp every
##                                  candidate already carries).
##   board_health.preflight       — {rendered_this_revision: bool} (DCR item 3):
##                                  whether a minerva_pcb_get_image capture has
##                                  succeeded SINCE the last board mutation.
##                                  WARN-ONLY — a standing nudge field, NEVER a
##                                  refusal anywhere ("geometry authored blind is
##                                  geometry authored wrong", llm-ergonomics F9).
##
## Side effect: a present board_health.assembly FEEDS the panel's assembly-state
## cache (DCR item 2) at the stamped revision — the commit acknowledgment gate
## reads that cache. Absent/empty board_health (older worker) attaches nothing
## and feeds nothing, same absent-key contract as every additive key here.
##
## Epoch UX4 station 3 (DCR S3 cache isolation, A9): `draft` = the reply
## answers a DRAFT request — its health was computed from the COMPOSED board
## (real + staged zones), so it is surfaced on the reply LABELED
## (health.draft = true) but must NEVER feed the assembly cache: that cache
## is the REAL board's verdict, keyed to its revision, and the commit
## acknowledgment gate reads it. Draft callers: _propose_into_workspace and
## _ingest_result_into_workspace (candidate-producing replies).
## _materialize_routes (direct copper, uncomposed request) keeps feeding.
static func _attach_board_health(host, reply: Dictionary, result: Dictionary, draft: bool = false) -> void:
	var bh: Variant = result.get("board_health")
	if not (bh is Dictionary) or (bh as Dictionary).is_empty():
		return
	var health: Dictionary = (bh as Dictionary).duplicate(true)
	# UX2 station 6 (docket 019fde367b24): pin_groups int normalization — the
	# worker emits ints, but the Go↔GDScript JSON hop parses every number as
	# float, so partial[].pin_groups reached callers as 9.0. Same
	# JSON-boundary class as the F5 constraint_revision fix in
	# _attach_hint_status; normalized once, here at the lift.
	if health.get("partial", null) is Array:
		for entry in (health["partial"] as Array):
			if entry is Dictionary and (entry as Dictionary).has("pin_groups"):
				(entry as Dictionary)["pin_groups"] = int((entry as Dictionary)["pin_groups"])
	var data = _get_data(host)
	var revision: int = int(data.board_revision) if data != null else 0
	# For a DRAFT reply this revision is approximate: the verdict was computed
	# from the COMPOSED board (real + staged zones), not the revision named
	# here — the draft:true label below is what disambiguates (and why the
	# cache feed is skipped).
	health["board_revision"] = revision
	var rendered := false
	var panel = _get_panel(host)
	if panel != null and panel.has_method("get_last_rendered_board_revision"):
		rendered = int(panel.get_last_rendered_board_revision()) == revision
	health["preflight"] = {"rendered_this_revision": rendered}
	if draft:
		health["draft"] = true
	reply["board_health"] = health
	if draft:
		return
	var assembly: Variant = health.get("assembly")
	if assembly is Dictionary and not (assembly as Dictionary).is_empty():
		_feed_assembly_cache(host, assembly, revision)


## Normalize an assembly_check round-trip reply ({ok, result:{status, findings,
## indeterminate?, error?}} — PCBPanel.assembly_check / a worker board_health.
## assembly object) to the bare TRI-STATE dict the load/placement replies and
## the cache carry. Failure-as-feedback: any envelope that does not carry a
## recognisable status degrades to {status:"indeterminate", error} — never a
## crash, never silently a pass (the same fail-closed reading
## _geometric_status_suffix documents for its verdict string).
static func _assembly_tri_state(reply: Dictionary) -> Dictionary:
	if bool(reply.get("ok", false)) and reply.get("result", null) is Dictionary:
		var tri: Dictionary = _dict_or_empty((reply.get("result") as Dictionary).duplicate(true))
		if str(tri.get("status", "")) in ["pass", "findings", "indeterminate"]:
			return tri
		return {"status": "indeterminate",
			"error": "assembly_check returned an unrecognised status '%s'" % str(tri.get("status", ""))}
	var err: Variant = reply.get("error", {})
	var msg: String = str((err as Dictionary).get("message", "assembly_check failed")) \
		if err is Dictionary else str(err)
	return {"status": "indeterminate", "error": msg}


## Write one tri-state verdict into the panel's assembly cache (silently a no-op
## headless / when no panel is bound — the cache is PANEL state; a model-only
## context has no commit gate to feed).
static func _feed_assembly_cache(host, assembly: Dictionary, board_revision: int) -> void:
	var panel = _get_panel(host)
	if panel != null and panel.has_method("set_assembly_state"):
		panel.set_assembly_state(assembly, board_revision)


## Per-component fields canonical_wire_board strips — the panel's RENDER
## enrichment (worker-attached or panel-derived draw detail; refdes_graphics
## now only ever reaches here on a payload authored before the designator
## became derived). Every entry is
## poison-proven unread by the worker's assembly/board_health kernels
## (worker/tests/test_board_health_resolve_first.py): both resolve tolerantly
## from the library chain themselves, so shipping these is pure wire weight.
## `pads` is deliberately NOT here — see canonical_wire_board.
const _WIRE_DROP_COMPONENT_FIELDS: Array[String] = [
	"graphics", "refdes_graphics", "local_bounds", "width", "height",
	"bbox_center_offset", "properties", "color", "has_pad_geometry",
	"footprint_id", "label_visible", "locked", "footprint_resolved",
]


## The CANONICAL WIRE form of a board dict — what the worker channels
## (pcb.assembly_check / pcb.board_health) are actually owed (bug
## 01a007f1dd02). The full panel dict ships ~9x the canonical size in render
## enrichment (pads/graphics/refdes_graphics dominate) and blew the host
## broker's 64 KiB payload cap on an ordinary 36-component board, silently
## disabling the assembly advisory on exactly the boards big enough to need
## it. The worker resolves tolerantly from the library chain on BOTH channels
## (resolve-first census: bug 01a01b6bc649), so enrichment for
## library-resolvable components is recomputed server-side and never read off
## the wire.
##
## DROP-LIST philosophy, not keep-list: unknown board sections and component
## extras (origin, zones, mpn, assembly, ...) PASS THROUGH — an allowlist
## silently sheds the next canonical field someone adds, which is how the
## first draft of this helper lost quadlayer's `origin`.
##
## `pads` is conditional, and the condition is a MEASURED fact, not a shape:
## dropped only for a component marked `footprint_resolved`, the flag the
## worker writes on its own resolve success path — precisely when it re-derives
## the same lands server-side and the wire copy is dead weight. KEPT for
## everything else, a library-SHAPED ref included: the `pads` KEY declares that
## the BOARD owns this component's geometry, so dropping it does not shed
## weight, it demotes a FULL part to a PARTIAL one and hands the worker a ref
## this host may be unable to resolve. `pins` always travel: they are canonical
## fab geometry and the pad_extent fallback.
##
## Idempotent: applying it to its own output is the identity.
static func canonical_wire_board(board: Dictionary) -> Dictionary:
	var out := {}
	for key in board:
		if key == "components":
			continue
		out[key] = board[key]
	var comps_out: Array = []
	var comps_in_v: Variant = board.get("components", [])
	var comps_in: Array = comps_in_v if comps_in_v is Array else []
	for comp_v in comps_in:
		if not (comp_v is Dictionary):
			comps_out.append(comp_v)
			continue
		var comp: Dictionary = comp_v
		var lean := {}
		var worker_can_rederive_pads: bool = bool(comp.get("footprint_resolved", false))
		for key in comp:
			if key in _WIRE_DROP_COMPONENT_FIELDS:
				continue
			if key == "pads" and worker_can_rederive_pads:
				continue
			lean[key] = comp[key]
		comps_out.append(lean)
	out["components"] = comps_out
	return out


## ONE worker reply, normalised: the channel may hand back the worker's own
## {ok, result} or the broker's {success, result:{…}} double wrap, and a caller
## must not have to know which. A broker-level failure becomes the worker's own
## refusal shape so every caller branches on one thing.
static func worker_envelope(result: Dictionary, what: String) -> Dictionary:
	if result.has("ok"):
		return result
	if bool(result.get("success", false)) and result.get("result", null) is Dictionary:
		var inner: Dictionary = _dict_or_empty(result.get("result"))
		return inner if inner.has("ok") else {"ok": true, "result": inner}
	return {"ok": false, "error": {
		"kind": str(result.get("error_code", "worker_error")),
		"message": str(result.get("error_message",
			result.get("error", "%s failed" % what)))}}


## Run the pcb.assembly_check channel over the LIVE board and return the
## tri-state verdict, feeding the cache as a side effect (work item
## 019fd5fe2724 — the placement verbs' refresh half). A host without the
## bridge (headless model-only fixtures) or a failed channel degrades to
## {status:"indeterminate", ...} — advisory, NEVER a gate here. The board
## crosses the broker as its canonical wire form (canonical_wire_board) —
## the full dict blew the 64 KiB payload cap on real boards (01a007f1dd02).
static func _run_assembly_check(host, data) -> Dictionary:
	if data == null or host == null or not host.has_method("assembly_check"):
		return {"status": "indeterminate",
			"reason": "assembly check unavailable — no channel bridge (headless / before mount)"}
	var reply: Dictionary = await host.assembly_check(
		canonical_wire_board(data.to_board_dict()))
	var tri: Dictionary = _assembly_tri_state(reply)
	_feed_assembly_cache(host, tri, int(data.board_revision))
	return tri


## F6 (HITL-4, docs/llm-ergonomics.md): the ROUTING-family replies carry a
## one-line COUNT SUMMARY of the emitter-capability notes, not the ~27-entry
## verbatim list. Those notes are per-BOARD static facts (footprint fab-text
## omissions, courtyard participation) — identical on every propose for a
## given board — and at three-per-component they dominated every routing
## reply while carrying zero routing signal. The full verbatim text still
## exists where it is decision-relevant: the fab/export surfaces
## (minerva_pcb_gerbers / export replies) and the worker result itself.
## {} when the result carries none — same absent-when-empty contract the
## old list had.
static func _emitter_notes_summary_from_result(result: Dictionary) -> Dictionary:
	var by_code: Dictionary = {}
	var count := 0
	for w in result.get("warnings", []):
		if not (w is Dictionary):
			continue
		var code := str((w as Dictionary).get("code", ""))
		if code in _EMITTER_NOTE_CODES:
			count += 1
			by_code[code] = int(by_code.get(code, 0)) + 1
	if count == 0:
		return {}
	return {
		"count": count,
		"codes": by_code,
		"note": "per-board emitter-capability notes (static for this board; decision-relevant at fab/export time) — full text rides the gerbers/export replies",
	}


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


## The width this route's copper is ACTUALLY drawn at, in mm.
##
## THE REPLY OUTRANKS THE HINTS, most specific first:
##
## 1. the SEGMENTS' own `width_mm`, when they all state the same one — the
##    value ir_candidates checks the overlay at, so nothing coarser may
##    overrule it. USUALLY THIS IS RUNG 2 WEARING A SEGMENT'S CLOTHES: the
##    worker `setdefault`s the route-wide effective width onto every segment
##    that carries none (methods._attach_effective_routing_rules), so the two
##    rungs agree on all but the routes where a segment really was drawn at its
##    own width (a detailed hint, a reroute given an explicit width). Rung 1
##    matters for those routes, and for the mixed-width route _route_segment_
##    width declines to answer at all.
## 2. `effective_routing_rules.trace_width_mm.value`, the ROUTE-wide width the
##    worker resolved (methods.py `_effective_routing_rules_detailed` plus the
##    per-net step): an explicit caller option, a hint-authored width, the net's
##    class minimum, the width the net's own EXISTING copper establishes, the
##    board's default — in that order, already decided.
## 3. the hint derivation below (`_width_for_net`), which sees hints only. It
##    runs when the reply carries no width at all: an older worker, or a path
##    that skipped the attach. Same absent-key contract as every other field
##    read off a route reply.
## 4. the BOARD (PcbTraceWidth): the net's own established copper, then
##    design_rules.trace_width_mm.
##
## A missing width is RESOLVED, not invented — 0.0 comes back only when no
## source anywhere has an answer, and the callers refuse rather than pick a
## number.
static func _route_width(route: Dictionary, source_hints: Array, net: String, data = null) -> float:
	var stamped: float = _route_segment_width(route)
	if stamped > 0.0:
		return stamped
	var routed: float = _route_effective_width(route)
	if routed > 0.0:
		return routed
	var hinted: float = _width_for_net(source_hints, net)
	if hinted > 0.0:
		return hinted
	return float(PcbTraceWidth.from_board(data, net)["width"])


## The width this route's SEGMENTS state, when every one of them states the
## same positive one; 0.0 otherwise.
##
## Unanimity is the condition because this answers a ROUTE-wide question. A
## route whose segments were drawn at different widths has no single answer to
## give here — `_materialize_routes` reads each segment's own width and commits
## one trace per (layer, width) instead, so nothing is lost by declining.
static func _route_segment_width(route: Dictionary) -> float:
	var seen := 0.0
	for seg in route.get("segments", []):
		if not (seg is Dictionary):
			continue
		var w: float = maxf(0.0, float((seg as Dictionary).get("width_mm", 0.0)))
		if w <= 0.0:
			return 0.0
		if seen > 0.0 and not is_equal_approx(w, seen):
			return 0.0
		seen = w
	return seen


## `effective_routing_rules.trace_width_mm.value` off one route, or 0.0 when the
## route carries no stamp (or a non-positive one, which is not a width).
static func _route_effective_width(route: Dictionary) -> float:
	var erules: Dictionary = _dict_or_empty(route.get("effective_routing_rules"))
	var entry: Dictionary = _dict_or_empty(erules.get("trace_width_mm"))
	if not entry.has("value"):
		return 0.0
	return maxf(0.0, float(entry.get("value", 0.0)))


## Widest authored trace width among the source hints that target `net`
## (kind_payload.net_names). 0.0 when none specify a width.
static func _width_for_net(source_hints: Array, net: String) -> float:
	var w := 0.0
	for hint in source_hints:
		var kp: Dictionary = _dict_or_empty(hint.get("kind_payload"))
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
		return [_mm((raw as Vector2).x), _mm((raw as Vector2).y)]
	if raw is Array and (raw as Array).size() >= 2:
		return [_mm(float((raw as Array)[0])), _mm(float((raw as Array)[1]))]
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
static func _list_zones(host, _args: Dictionary) -> Dictionary:
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
## Millimetre quantization for every mm value that leaves this surface.
##
## PcbAnnotationHost keeps a one-line mirror of this (the dependency direction
## is tools -> host, so the host cannot reach here). Change the quantum in both
## or the two surfaces disagree about what grid they are on.
##
## Vector2 is single-precision, so a pad the author placed at 75.4 comes back as
## 75.4000015258789. That residue is not a measurement — it is the float32
## representation of the number the author typed — and it travels: an external
## router reads a pin position over MCP, computes against it, and writes copper
## back at a coordinate that misses the pad by a sub-micron, which then reads as
## a real geometric finding. 0.1 um is four orders of magnitude finer than
## anything fabricable and comfortably coarser than the noise.
static func _mm(value: float) -> float:
	return snapped(value, 0.0001)


## Two holes closer than this are the same hole. Well below any drill tolerance,
## well above float32 noise at board coordinates.
const _HOLE_COINCIDENT_MM := 0.001
## Beyond this many holes the collinearity scan (which is O(n^3)) is skipped and
## says so, rather than quietly costing more than the advisory is worth.
const _HOLE_ADVISORY_MAX := 64


## Mounting-hole placement patterns worth a second look, as {code, holes, note}.
##
## NO GEOMETRIC CHECK COVERS THIS. GC11's proximity half never runs (no shipped
## profile publishes a hole-to-edge figure), GC6 fires only on a near-collision,
## and GC10 is about copper. So a hole pattern that was silently rewritten —
## every hole landing on one line, or two holes stacked at one point — passes
## every check and is discovered when the board comes back from the fab.
##
## ADVISORY, never a refusal: three collinear holes are a legitimate pattern on
## plenty of boards. The reply says what it saw; the reader decides.
static func _hole_placement_advisory(holes: Array) -> Array:
	var out: Array = []
	var coincident: Array = []
	for i in range(holes.size()):
		for j in range(i + 1, holes.size()):
			var a: Vector2 = holes[i]["pt"]
			var b: Vector2 = holes[j]["pt"]
			if a.distance_to(b) <= _HOLE_COINCIDENT_MM:
				coincident.append([holes[i]["index"], holes[j]["index"]])
	if not coincident.is_empty():
		out.append({
			"code": "coincident_holes",
			"holes": coincident,
			"note": "two mounting holes occupy the same point — one of them drills nothing new, and a fab may reject the pair or merge them",
		})
	if holes.size() > _HOLE_ADVISORY_MAX:
		out.append({
			"code": "collinearity_not_checked",
			"holes": [],
			"note": "more than %d mounting holes — the collinearity scan was skipped, so a linear pattern would not be reported here" % _HOLE_ADVISORY_MAX,
		})
		return out
	var collinear: Array = []
	for i in range(holes.size()):
		for j in range(i + 1, holes.size()):
			for k in range(j + 1, holes.size()):
				var a: Vector2 = holes[i]["pt"]
				var b: Vector2 = holes[j]["pt"]
				var c: Vector2 = holes[k]["pt"]
				# ANY coincident pair in the triple disqualifies it. Two points
				# and a duplicate of one of them are trivially "collinear", so a
				# stacked pair plus any third hole would raise BOTH advisories
				# for one fault — on the advisory whose whole value is that it
				# does not cry wolf.
				if a.distance_to(b) <= _HOLE_COINCIDENT_MM \
						or a.distance_to(c) <= _HOLE_COINCIDENT_MM \
						or b.distance_to(c) <= _HOLE_COINCIDENT_MM:
					continue
				var ab := b - a
				# Perpendicular distance from c to the line through a and b.
				var area2: float = absf(ab.x * (c.y - a.y) - ab.y * (c.x - a.x))
				if area2 / ab.length() <= _HOLE_COINCIDENT_MM:
					collinear.append([holes[i]["index"], holes[j]["index"], holes[k]["index"]])
	if not collinear.is_empty():
		out.append({
			"code": "collinear_holes",
			"holes": collinear,
			"note": "three or more mounting holes lie on one line — legitimate on some boards, and also exactly what a silently rewritten hole pattern looks like",
		})
	return out


## The mounting holes the board declares, with their placement read back.
##
## Named for mounting holes rather than the plan's `list_holes`: pad drills and
## via barrels are holes too, and this verb does not report them.
static func _list_mounting_holes(host, _args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var holes: Array = []
	var geometry: Array = []
	var index := 0
	for hole in data.mounting_holes:
		if not (hole is Dictionary):
			index += 1
			continue
		var raw: Variant = (hole as Dictionary).get("position", null)
		var pt := Vector2.ZERO
		if raw is Vector2:
			pt = raw
		elif raw is Dictionary:
			pt = Vector2(float((raw as Dictionary).get("x", 0.0)),
				float((raw as Dictionary).get("y", 0.0)))
		holes.append({
			"index": index,
			"x_mm": _mm(pt.x),
			"y_mm": _mm(pt.y),
			"diameter_mm": _mm(float((hole as Dictionary).get("diameter", 0.0))),
			"plated": bool((hole as Dictionary).get("plated", false)),
		})
		geometry.append({"index": index, "pt": pt})
		index += 1
	var reply := {
		"hole_count": holes.size(),
		"mounting_holes": holes,
		"note": "mounting holes only — pad drills and via barrels are not reported here",
	}
	var advisory: Array = _hole_placement_advisory(geometry)
	if not advisory.is_empty():
		reply["placement_advisory"] = advisory
	return _ok(reply)


## LAYERS_TOUCHED. from_layer/to_layer say what the barrel SPANS; every through via spans the whole stack, so the span cannot
## show a via that joins nothing on one side. layers_touched answers the other
## question — which copper layers have copper actually MEETING the barrel — by
## the shared contact predicate, the same one the connectivity DRC and the trace
## free-end rule read. It NAMES the fact and judges nothing: "this via is
## stranded" stays DRC's verdict to give.
##
## The board's copper is indexed ONCE for the whole list rather than per via
## (PcbRegionDescribe.build_copper_index) — rebuilding it inside the loop is
## what would turn a cheap read into a slow one on a real board.
static func _list_vias(host, _args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var vias_arr: Array = []
	if data.vias.is_empty():
		return _ok({"via_count": 0, "vias": vias_arr})
	var copper: Dictionary = _PcbRegionDescribe.build_copper_index(data)
	for via in data.vias:
		vias_arr.append(_PcbRegionDescribe.via_entry(data, via, copper))
	return _ok({"via_count": vias_arr.size(), "vias": vias_arr})


## Draw ONE trace directly on the board — one journalled, undoable step.
##
## The other half of station C2's parity gap (epoch NLC station C3, item
## 01a001c39aa3): minerva_pcb_delete_traces removes copper directly, and until
## now the only way to ADD a trace was to propose one and route it. The human
## has had a direct Trace tool on the canvas the whole time.
##
## RULING ON "DOES A DIRECT TRACE BYPASS DRC?" (the open question on the item):
## IT LANDS AS COPPER, and DRC stays a separate question asked by a separate
## verb. Decided by PARITY, which is this epoch's whole point — the human's
## canvas Trace tool (pcb_canvas.gd _commit_trace) validates authorability and
## commits, and gates on no DRC at all. A verb that refused what the Trace tool
## accepts would make the agent a second-class author of the same board, which
## is the asymmetry this station exists to remove. It also matches every other
## direct verb here: place_via, delete_via, move_component and create_zone all
## write and let the next check speak.
##
## So this shares the human tool's EXACT model path — trace_author_error to
## validate, create_trace_entity to build — rather than a parallel one. One
## implementation, one set of refusals, one undo history. Run
## minerva_pcb_drc / minerva_pcb_drc_geometric afterwards; the reply says so.
##
## TRACE-END ANCHORS (`start` / `end`, each {trace_id, end: "start"|"end"}) are
## the verb's twin of the canvas's third anchor kind, with the same rules: the
## end must be FREE (pcb_data.free-end rule), a start end lends the run its net
## and layer (a supplied net_name/layer must agree), an end end must already
## agree on both, and the result is the SAME trace EXTENDED — one journal row,
## one undo step, id kept — never a second entity. A gesture that starts on a
## trace end and also finishes on one extends the start trace only, exactly as
## the click does.
static func _add_trace(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data

	var start_end: Dictionary = {}
	if args.has("start"):
		start_end = _trace_end_arg(data, args["start"], "start")
		if not bool(start_end.get("ok", false)):
			return start_end["reply"]
	var finish_end: Dictionary = {}
	if args.has("end"):
		finish_end = _trace_end_arg(data, args["end"], "end")
		if not bool(finish_end.get("ok", false)):
			return finish_end["reply"]
	var extending: bool = not start_end.is_empty() or not finish_end.is_empty()
	if not start_end.is_empty() and not finish_end.is_empty() \
			and str((start_end["trace"]).id) == str((finish_end["trace"]).id):
		return {"success": false, "error": "trace_end_same_trace",
			"note": "start and end name the two ends of the same trace — that would close it into a loop; end on a pad or via instead"}
	if extending and args.has("width_mm"):
		return _err("width_mm cannot be set when extending a trace — the trace keeps its own width")

	var net_name: String = str(args.get("net_name", ""))
	var layer_in: String = str(args.get("layer", ""))
	if not start_end.is_empty():
		var lend = start_end["trace"]
		if not net_name.is_empty() and net_name != str(lend.net_name):
			return {"success": false, "error": "trace_end_net_mismatch",
				"note": "the start trace end is on net '%s', not '%s' — a trace inherits its net from the end it starts on; omit net_name"
					% [str(lend.net_name), net_name]}
		net_name = str(lend.net_name)
		if not layer_in.is_empty() and PcbLayerStack.kicad_to_canon(layer_in) != str(lend.layer):
			return {"success": false, "error": "trace_end_layer_mismatch",
				"note": "the start trace end is on layer '%s', not '%s' — one polyline lives on one layer; omit layer"
					% [str(lend.layer), layer_in]}
		layer_in = str(lend.layer)
	if layer_in.is_empty():
		return _err("layer is required (\"top\", \"bottom\", \"in1\"..., or a KiCad copper name)")
	var layer: String = PcbLayerStack.kicad_to_canon(layer_in)

	# Declared-stack membership, same check and same reason as
	# _edit_candidate_insert_via: "in7" as a typo and "in7" as a plane are
	# indistinguishable without it, and the compiler would name a segment
	# instead of the argument that caused it.
	var declared: Array = data.layers if ("layers" in data and data.layers is Array) else []
	if not declared.is_empty() and not (layer in declared):
		return {"success": false, "error": "layer_not_on_stack",
			"declared_layers": declared.duplicate(),
			"note": "this board declares %s — it has no layer '%s' to draw on"
				% [str(declared), layer_in]}

	var raw_points: Variant = args.get("points")
	if not (raw_points is Array):
		return _err("points must be an array of [x_mm, y_mm] pairs")
	var pts := PackedVector2Array()
	if not start_end.is_empty():
		pts.append(start_end["position"] as Vector2)
	for entry in (raw_points as Array):
		var pair: Variant = _parse_xy_pair(entry)
		if pair == null:
			return _err("every entry in points must be [x_mm, y_mm]; got %s" % str(entry))
		pts.append(pair as Vector2)
	if not finish_end.is_empty():
		var target = finish_end["trace"]
		if str(target.layer) != layer:
			return {"success": false, "error": "trace_end_layer_mismatch",
				"note": "the end trace end is on layer '%s' and this run is on '%s' — one polyline lives on one layer; end on a via to change layer"
					% [str(target.layer), layer]}
		if str(target.net_name) != net_name:
			return {"success": false, "error": "trace_end_net_mismatch",
				"note": "the end trace end is on net '%s', not '%s' — one polyline cannot carry two nets; end on a pad or via instead"
					% [str(target.net_name), net_name]}
		pts.append(finish_end["position"] as Vector2)

	# THE HUMAN TOOL'S OWN GUARD, not a re-implementation of it. Covers the
	# net/layer/point-count rules in one place, so an agent and a click are
	# refused for the same reasons in the same words.
	var refusal: String = str(data.trace_author_error(net_name, layer, pts.size()))
	if not refusal.is_empty():
		return {"success": false, "error": "trace_not_authorable", "note": refusal}

	# WIDTH IS CHECKED, NOT COERCED (cold review 2, finding 6). Only an OMITTED
	# or exactly-zero width is the documented "use the board default" sentinel.
	# create_trace_entity treats ANY non-positive value as that sentinel, so
	# width_mm:-1 — schema-valid numeric input — silently landed real copper at
	# the authored default under a success reply, and a wrong-typed value
	# coerced to 0.0 and did the same.
	var width: float = 0.0
	if args.has("width_mm"):
		if not (args["width_mm"] is float or args["width_mm"] is int):
			return _err("width_mm must be a number, got %s" % str(args["width_mm"]))
		width = float(args["width_mm"])
		if is_nan(width) or is_inf(width) or width < 0.0:
			return _err("width_mm must be a positive number, or 0 to use the board's authored width (got %s)"
				% str(args["width_mm"]))
	if extending:
		# The canvas's rule: a run that STARTED on a trace end extends that
		# trace as drawn; one that only FINISHED on one extends the target with
		# the run reversed, so the polyline stays one piece.
		var grow: Dictionary = start_end if not start_end.is_empty() else finish_end
		var run := pts.duplicate()
		if start_end.is_empty():
			run.reverse()
		var grown_id: String = str((grow["trace"]).id)
		var error: String = str(data.extend_trace(grown_id, str(grow["which"]), run))
		if not error.is_empty():
			var name := "trace_not_extendable"
			if data.is_locked_refusal(error):
				name = "trace_locked"
			elif data.is_joined_end_refusal(error):
				name = "trace_end_not_free"
			return {"success": false, "error": name, "note": error}
		var reopened: Array = _retire_commits_owning_trace(host, data, grown_id)
		data.save_to_history("Extend trace")
		var grown = data.get_trace(grown_id)
		var all_points: Array = []
		for p in grown.waypoints:
			all_points.append([_mm((p as Vector2).x), _mm((p as Vector2).y)])
		var grown_reply: Dictionary = {
			"trace_id": grown_id,
			"extended_from": str(grow["which"]),
			"net_name": net_name,
			"layer": layer,
			"width_mm": _mm(float(grown.width)),
			"point_count": grown.waypoints.size(),
			"segment_count": maxi(0, grown.waypoints.size() - 1),
			"points": all_points,
			"trace_count": data.traces.size(),
			"note": ("the existing trace was extended in place (same id) — this verb runs no DRC, "
				+ "exactly as the canvas Trace tool does not. Run minerva_pcb_drc and "
				+ "minerva_pcb_drc_geometric to find out what it touched."),
		}
		if not reopened.is_empty():
			grown_reply["reopened_candidate_ids"] = reopened
			grown_reply["note"] = str(grown_reply["note"]) + " The trace was copper a committed route candidate owned — that commit is retired and its routing task is open again."
		return _ok(grown_reply)

	var trace = data.create_trace_entity(net_name, layer, pts, width)
	if trace == null:
		return _err("the board model refused this trace — see the log")
	data.save_to_history("Add trace")

	var out_points: Array = []
	for p in pts:
		out_points.append([_mm(p.x), _mm(p.y)])
	return _ok({
		"trace_id": str(trace.id),
		"net_name": net_name,
		"layer": layer,
		"width_mm": _mm(float(trace.width) if "width" in trace else width),
		"point_count": pts.size(),
		"segment_count": maxi(0, pts.size() - 1),
		"points": out_points,
		"trace_count": data.traces.size(),
		"note": ("copper is on the board now — this verb runs no DRC, exactly as the canvas "
			+ "Trace tool does not. Run minerva_pcb_drc (connectivity) and "
			+ "minerva_pcb_drc_geometric (clearances) to find out what it touched."),
	})


## Cut ONE trace at an interior vertex — the MCP twin of the canvas's "Cut
## here" item, through the same model call (pcb_data.cut_trace) and the same
## refusals. The vertex is given as at_index, or as x_mm/y_mm, which picks the
## nearest INTERIOR vertex within the canvas's pad snap radius exactly as the
## click does (pcb_data.nearest_interior_vertex). One journal row, one undo step.
static func _cut_trace(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var trace_id: String = str(args.get("trace_id", ""))
	if trace_id.is_empty():
		return _err("trace_id is required")
	var trace = data.get_trace(trace_id)
	if trace == null:
		return {"success": false, "error": "no_such_trace",
			"note": "no trace '%s' on this board" % trace_id}
	if bool(trace.locked):
		return {"success": false, "error": "trace_locked",
			"note": "trace '%s' is locked — unlock it before cutting it" % trace_id}
	var at_index: int = -1
	if args.has("at_index"):
		if not (args["at_index"] is int or args["at_index"] is float) \
				or float(args["at_index"]) != floorf(float(args["at_index"])):
			return _err("at_index must be a whole number, got %s" % str(args["at_index"]))
		at_index = int(args["at_index"])
	elif args.has("x_mm") or args.has("y_mm"):
		for key in ["x_mm", "y_mm"]:
			if not args.has(key) or not (args[key] is float or args[key] is int):
				return _err("x_mm and y_mm are both required for the coordinate form, as numbers")
		var snap: float = data.TRACE_SNAP_MM
		at_index = data.nearest_interior_vertex(trace_id,
			Vector2(float(args["x_mm"]), float(args["y_mm"])), snap)
		if at_index < 0:
			return {"success": false, "error": "no_vertex_in_reach",
				"note": "no interior vertex of '%s' within %.2f mm of (%.3f, %.3f) — a trace is cut at a bend, not at an end (minerva_pcb_delete_traces for that)"
					% [trace_id, snap, float(args["x_mm"]), float(args["y_mm"])]}
	else:
		return _err("give at_index, or x_mm + y_mm to pick the nearest interior vertex")
	var count_before: int = trace.waypoints.size()
	var error: String = str(data.cut_trace(trace_id, at_index))
	if not error.is_empty():
		return {"success": false,
			"error": "trace_locked" if data.is_locked_refusal(error) else "trace_not_cuttable",
			"note": error}
	# Copper a COMMITTED candidate owns has just changed shape under it: retire
	# that commit inside this same history step, as _delete_traces does.
	var reopened: Array = _retire_commits_owning_trace(host, data, trace_id)
	data.save_to_history("Cut trace")
	var kept: int = trace.waypoints.size()
	var reply: Dictionary = {
		"trace_id": trace_id,
		"at_index": at_index,
		"kept_point_count": kept,
		"dropped_count": count_before - kept,
		"free_end": not data.trace_end_is_joined(trace_id, data.TRACE_END_END),
		"trace_count": data.traces.size(),
	}
	if not reopened.is_empty():
		reply["reopened_candidate_ids"] = reopened
		reply["note"] = "the cut trace was copper a committed route candidate owned — that commit is retired and its routing task is open again"
	return _ok(reply)


## The edit twin of _reconcile_committed_copper: retire the commit of any
## candidate whose recorded copper includes `trace_id`, because its geometry
## just changed under it. Placed BEFORE the caller's snapshot, so one history
## step carries the edit and the retired commit together.
static func _retire_commits_owning_trace(host, data, trace_id: String) -> Array:
	if data == null or not is_instance_valid(data):
		return []
	var workspace = _get_workspace(host)
	if workspace == null or not workspace.has_method("retire_commits_owning_trace"):
		return []
	if data.has_method("bind_routing_workspace"):
		data.bind_routing_workspace(workspace)
	# Same ownership pre-check the delete verbs run: an edit
	# must not retire a commit whose record merely NAMES this trace's id while
	# the copper belongs to another net.
	_prune_foreign_commit_claims(host, data)
	return workspace.retire_commits_owning_trace(trace_id)


## Resolve one of _add_trace's `start` / `end` arguments — {trace_id, end} — to
## {ok, trace, which, position} or {ok: false, reply}. The end must exist and
## be FREE by the model's rule (pcb_data.trace_end_is_joined): an end already
## on a pad, in a via or on same-net copper is refused as trace_end_not_free,
## the same end the canvas declines to offer as an anchor.
static func _trace_end_arg(data, raw: Variant, label: String) -> Dictionary:
	if not (raw is Dictionary):
		return {"ok": false, "reply": _err("%s must be {trace_id, end: \"start\"|\"end\"}" % label)}
	var spec: Dictionary = raw
	var trace_id: String = str(spec.get("trace_id", ""))
	var which: String = str(spec.get("end", ""))
	if trace_id.is_empty():
		return {"ok": false, "reply": _err("%s.trace_id is required" % label)}
	if which != data.TRACE_END_START and which != data.TRACE_END_END:
		return {"ok": false, "reply": _err("%s.end must be \"start\" or \"end\", got \"%s\"" % [label, which])}
	var trace = data.get_trace(trace_id)
	if trace == null:
		return {"ok": false, "reply": {"success": false, "error": "no_such_trace",
			"note": "no trace '%s' on this board" % trace_id}}
	if bool(trace.locked):
		return {"ok": false, "reply": {"success": false, "error": "trace_locked",
			"note": "trace '%s' is locked — unlock it before continuing it" % trace_id}}
	if trace.waypoints.size() < 2:
		return {"ok": false, "reply": {"success": false, "error": "trace_end_not_free",
			"note": "trace '%s' has no run to continue" % trace_id}}
	if data.trace_end_is_joined(trace_id, which):
		return {"ok": false, "reply": {"success": false, "error": "trace_end_not_free",
			"note": "the %s end of trace '%s' already touches a pad, a via or same-net copper — a joined end is not somewhere to continue from"
				% [which, trace_id]}}
	var position: Vector2 = trace.waypoints[0] if which == data.TRACE_END_START \
		else trace.waypoints[trace.waypoints.size() - 1]
	return {"ok": true, "trace": trace, "which": which, "position": position}


## Propose ONE via — a ghost via for review, the Proposals-area twin of
## minerva_pcb_place_via (DCR 01a0033a12a9).
##
## Completes the panel's two-area language for vias: Tools place a REAL via,
## Proposals propose a GHOST one, and workspace_commit turns it into copper.
## Before this, the Proposals area's only via verb BISECTED A ROUTE — a trace
## operation wearing a via's name. Under the owner's model a via is an entity
## that exists at a point, so proposing one proposes an entity.
##
## No layer argument: a v1 via joins every copper layer, so there is nothing to
## choose. Which layer a RUN continues on past a via is a routing decision and
## belongs to a trace verb.
##
## `for_hint` NAMES THE ROUTE HINT THIS VIA SERVES, and with it the ghost stops
## being an orphan. Without it a ghost carries net "", task_id "" and
## source_hint_ids [], and which hint it belongs to is recoverable only by
## matching coordinates to hint segments by eye — ambiguous the moment a second
## hint is nearby. Given a hint id, the via records it and INHERITS THAT HINT'S NET when no net_name
## was passed. Given neither, the via is still proposed (an unassigned via is
## legitimate) and every listing labels it `owner: "none"`.
static func _propose_via(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]

	if not args.has("x_mm") or not args.has("y_mm"):
		return _err("x_mm and y_mm are required")
	for banned in ["from_layer", "to_layer", "layers"]:
		if args.has(banned):
			return {"success": false, "error": "span_not_selectable",
				"note": ("a v1 via is a THROUGH via — it crosses the whole board and joins every "
					+ "declared layer, so '%s' is not a choice this pipeline can honour. Omit it; "
					+ "the layer a trace continues on is a property of that trace, not the hole.")
					% banned}
	for key in ["x_mm", "y_mm", "size_mm", "drill_mm"]:
		if args.has(key) and not (args[key] is float or args[key] is int):
			return _err("%s must be a number, got %s" % [key, str(args[key])])

	var pos := Vector2(float(args["x_mm"]), float(args["y_mm"]))
	# 0.0 means "the board's design_rules decide" — the resolution lives in
	# PcbViaDimensions, one rule for every via this plugin creates. An explicit
	# size_mm/drill_mm still outranks the rules.
	var size_mm := float(args.get("size_mm", 0.0))
	var drill_mm := float(args.get("drill_mm", 0.0))
	var net_name: String = str(args.get("net_name", ""))

	# OWNERSHIP: the route hint this via serves, and the net it inherits from it.
	var for_hint: String = str(args.get("for_hint", ""))
	if not for_hint.is_empty():
		var owner_ann: Dictionary = host.get_by_id(for_hint) if host.has_method("get_by_id") else {}
		if owner_ann.is_empty():
			return {"success": false, "error": "hint_not_found",
				"note": "no annotation '%s' on this board — for_hint must name a pcb_route_hint" % for_hint}
		if str(owner_ann.get("kind", "")) != "pcb_route_hint":
			return {"success": false, "error": "not_a_route_hint",
				"note": "annotation '%s' is a '%s', not a pcb_route_hint — a via can only be owned by a route hint"
					% [for_hint, str(owner_ann.get("kind", ""))]}
		if net_name.is_empty():
			net_name = _resolve_hint_net_for_seeding(_dict_or_empty(owner_ann.get("kind_payload")), data)

	# ONE proposal gate for both surfaces. RoutingWorkspace calls the board's
	# canonical via_author_error and also sees live candidate vias, which PCBData
	# alone cannot: two ghost proposals at one point must not both be accepted.
	var res: Dictionary = workspace.propose_via(pos, net_name, size_mm, drill_mm, data, for_hint)
	if not bool(res.get("ok", false)):
		return {"success": false, "error": str(res.get("error", "propose_via_refused")),
			"note": str(res.get("message", ""))}
	var actual: Array = res.get("at", [pos.x, pos.y])
	return _ok({
		"candidate_id": str(res.get("candidate_id", "")),
		"via_id": str(res.get("via_id", "")),
		"x_mm": _mm(float(actual[0])),
		"y_mm": _mm(float(actual[1])),
		"net_name": str(res.get("net_name", net_name)),
		"trace_id": str(res.get("trace_id", "")),
		"snapped_to_trace": bool(res.get("snapped_to_trace", false)),
		"size_mm": _mm(float(res.get("size_mm", 0.0))),
		"drill_mm": _mm(float(res.get("drill_mm", 0.0))),
		"from_layer": str(res.get("from_layer", "top")),
		"to_layer": str(res.get("to_layer", "bottom")),
		"for_hint": for_hint,
		"owner": ("hint %s" % for_hint) if not for_hint.is_empty() else "none",
		"note": ("a GHOST via — nothing is on the board yet. Accept it with "
			+ "minerva_pcb_workspace_commit, or drop it with minerva_pcb_workspace_reject.")
			+ ("" if not for_hint.is_empty() else
				" UNOWNED: it names no route hint (for_hint) "
				+ ("and no net" if net_name.is_empty() else "")
				+ " — every listing will show it as owner:none, and nothing but its "
				+ "coordinates says what it is for."),
	})


## Place ONE via directly on the board — one journalled, undoable step.
##
## THE PARITY GAP THIS CLOSES (epoch NLC station C2, item 019fff60e05a). Before
## this, copper CREATION was proposal-only while copper DESTRUCTION was direct:
## minerva_pcb_delete_via and minerva_pcb_delete_traces act on the board, but the
## only add-via verb (minerva_pcb_add_via) splits a route HINT. The owner's
## N-layer HITL named it exactly — "there is no tool to place a via for the
## human, only propose ... that breaks a goal of parity between tools and
## proposals". An agent could delete a via it could not put back.
##
## THE SPAN IS ALWAYS THE THROUGH SPAN, and from_layer/to_layer are NOT accepted.
## A v1 via crosses the whole board and joins every declared layer, so there is
## nothing to choose (see methods._routes_to_vias' own docstring, and epoch NLC
## C1b for the same reasoning on the candidate side). A caller that passes a span
## is REFUSED rather than quietly ignored: silently dropping an argument someone
## bothered to write is how a caller comes to believe in a blind/buried via this
## pipeline cannot fabricate.
##
## Mutate-then-snapshot, matching _delete_via: add first, save_to_history after.
## add_via journals its own "add_via" entry; this owes only the history step.
static func _place_via(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	if not args.has("x_mm") or not args.has("y_mm"):
		return _err("x_mm and y_mm are required")
	for banned in ["from_layer", "to_layer", "layers"]:
		if args.has(banned):
			return {"success": false, "error": "span_not_selectable",
				"note": ("a v1 via is a THROUGH via — it crosses the whole board and joins every "
					+ "declared layer, so '%s' is not a choice this pipeline can honour. "
					+ "Blind/buried vias are out of scope. Omit it. To change which layer a "
					+ "TRACE continues on past a via, that is the run's own layer, not the hole's.")
					% banned}

	# NUMBERS ARE CHECKED, NOT COERCED. float("nope") is 0.0 in GDScript, so a
	# non-numeric argument would silently become a via at the origin — copper the
	# caller never asked for, from an argument nobody rejected.
	for key in ["x_mm", "y_mm", "size_mm", "drill_mm"]:
		if args.has(key) and not (args[key] is float or args[key] is int):
			return _err("%s must be a number, got %s" % [key, str(args[key])])

	var pos := Vector2(float(args["x_mm"]), float(args["y_mm"]))
	var size_mm := float(args.get("size_mm", 0.8))
	var drill_mm := float(args.get("drill_mm", 0.4))

	var resolved: Dictionary = data.resolve_via_target(
		pos, size_mm, drill_mm, str(args.get("net_name", "")))
	if not bool(resolved.get("ok", false)):
		return {"success": false, "error": "via_not_placeable",
			"note": str(resolved.get("error", "The via cannot be placed there."))}
	pos = resolved.get("position", pos)
	var net_name := str(resolved.get("net_name", ""))

	var span: Array = PcbLayerStack.default_through_via_span()
	data.begin_batch()
	var via_id: String = str(data.add_via({
		"position": pos,
		"net_name": net_name,
		"size": size_mm,
		"drill": drill_mm,
		"from_layer": str(span[0]),
		"to_layer": str(span[1]),
	}))
	var trace_id := str(resolved.get("trace_id", ""))
	if not trace_id.is_empty():
		data.insert_trace_junction(trace_id, pos)
	data.end_batch("Place via " + via_id)
	return _ok({
		"via_id": via_id,
		"x_mm": _mm(pos.x),
		"y_mm": _mm(pos.y),
		"net_name": net_name,
		"trace_id": trace_id,
		"snapped_to_trace": bool(resolved.get("snapped", false)),
		"size_mm": _mm(size_mm),
		"drill_mm": _mm(drill_mm),
		"from_layer": str(span[0]),
		"to_layer": str(span[1]),
		"via_count": data.vias.size(),
	})


## Read or declare the board's FABRICATION STAGE — what this board IS for
## manufacturing (DCR 01a0033a12a9 change 3). One read/write verb, following
## the minerva_pcb_view_state precedent from this same epoch rather than a
## get/set pair, because the read and the write describe one small fact.
##
## WHY THE BOARD NEEDS TO SAY THIS. A via-only board has every net unrouted BY
## DESIGN — fiber-laser users cannot drill, so they order a drilled, plated
## board with no copper runs and lase the traces themselves afterwards. Before
## this, the connectivity census had no vocabulary for that: the customer's
## CORRECT board reported a wall of missing_copper, indistinguishable from a job
## someone abandoned half-routed.
##
## A DECLARATION, NOT A SUPPRESSION, and the difference is the whole design.
## Nothing here turns a check off. Every unrouted and fragmented net is still
## computed and still listed, the stage rides in the same reply, and the
## VIOLATION checks (shorts, crossings, dangling ends, layer changes with no
## via) fire exactly as before — those report copper that is WRONG, and a stage
## excuses only copper that is ABSENT.
##
## REFUSES BY NAME rather than defaulting, for the reason the whole epoch
## exists: a stage that fell back to "routed" on a typo would silently re-report
## a via-only board as broken, and one that fell back the other way would
## silently excuse a board someone genuinely left half-routed.
static func _fabrication_stage(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	if args.has("stage"):
		if not (args["stage"] is String):
			return {"success": false, "error": "invalid_args",
				"note": "stage must be a string, got %s" % str(args["stage"])}
		var refusal: String = data.set_fabrication_stage(str(args["stage"]))
		if not refusal.is_empty():
			return {"success": false, "error": "invalid_fabrication_stage",
				"note": refusal, "known_stages": _PcbDataScript.FAB_STAGES}
		data.save_to_history("Set fabrication stage")
	var stage := str(data.fabrication_stage)
	var deferred := stage != _PcbDataScript.FAB_STAGE_ROUTED
	return _ok({
		"fabrication_stage": stage,
		# The DERIVED question beside the raw token, the same pairing the worker
		# census returns — a caller branches on this rather than re-deriving it
		# from a token list that could go stale.
		"routing_deferred": deferred,
		"known_stages": _PcbDataScript.FAB_STAGES,
		"trace_count": data.traces.size(),
		"via_count": data.vias.size(),
	})


## Edit ONE placed via — position, net, size or drill — in one journalled,
## undoable step. The agent half of what the canvas drag and the Properties
## rows do for the human; both come through PCBData.update_via, so an agent's
## call and a human's edit are refused identically, in identical words.
##
## THE GAP THIS CLOSES (DCR 01a0033a12a9 change 2). place/delete/list existed;
## nothing could ADJUST a via. Delete-and-replace was the only route and it
## loses the id, which matters under the owner's model — vias are placed FIRST
## and routed against later, so the via id is the stable thing traces are
## authored against. Moving one was possible ONLY by dragging it on the canvas
## (PCBData.move_via had exactly one caller, pcb_canvas._end_selection_drag),
## and net/size/drill could not be changed on ANY surface.
##
## ABSENT ARGUMENT MEANS UNCHANGED — a partial edit never blanks the rest of
## the via. x_mm and y_mm must come together: a via moves as a point, and
## accepting one alone would silently combine a new X with a stale Y.
##
## THE SPAN IS STILL NOT SELECTABLE, for the reason _place_via spells out at
## length: a v1 via is a THROUGH via. A caller passing a span is refused rather
## than quietly ignored.
##
## THE RESULT MAY NOT BE WHAT WAS ASKED FOR, and the reply says so rather than
## hiding it: growing a via can make it reach a trace, which snaps it to that
## centreline and inherits the net (`snapped_to_trace`), and clearing the net of
## a via sitting on copper re-inherits that copper's net. Both are the placement
## rule applied consistently — see PCBData.update_via for why the alternative is
## bug 01a003e2fb6e.
static func _update_via(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var via_id: String = str(args.get("via_id", ""))
	if data.get_via(via_id).is_empty():
		return _err("Unknown via: %s" % via_id)

	for banned in ["from_layer", "to_layer", "layers"]:
		if args.has(banned):
			return {"success": false, "error": "span_not_selectable",
				"note": ("a v1 via is a THROUGH via — it crosses the whole board and joins every "
					+ "declared layer, so '%s' is not a choice this pipeline can honour. "
					+ "Blind/buried vias are out of scope. Omit it. To change which layer a "
					+ "TRACE continues on past a via, that is the run's own layer, not the hole's.")
					% banned}

	# NUMBERS ARE CHECKED, NOT COERCED — the same reason _place_via gives:
	# float("nope") is 0.0 in GDScript, so a non-numeric argument would move the
	# via to the origin or shrink it to nothing without anyone refusing it.
	for key in ["x_mm", "y_mm", "size_mm", "drill_mm"]:
		if args.has(key) and not (args[key] is float or args[key] is int):
			return _err("%s must be a number, got %s" % [key, str(args[key])])
	if args.has("x_mm") != args.has("y_mm"):
		return _err("x_mm and y_mm must be given together — a via moves as a point, "
			+ "and one without the other would pair a new coordinate with a stale one.")

	var changes: Dictionary = {}
	if args.has("x_mm"):
		changes["position"] = Vector2(float(args["x_mm"]), float(args["y_mm"]))
	if args.has("net_name"):
		changes["net_name"] = str(args["net_name"])
	if args.has("size_mm"):
		changes["size"] = float(args["size_mm"])
	if args.has("drill_mm"):
		changes["drill"] = float(args["drill_mm"])
	if changes.is_empty():
		return _err("Nothing to change — give at least one of x_mm/y_mm, net_name, "
			+ "size_mm or drill_mm.")

	# end_batch is a no-op when nothing was applied, so a refusal inside
	# update_via leaves no history step and no board_revision bump.
	data.begin_batch()
	var res: Dictionary = data.update_via(via_id, changes)
	data.end_batch("Update via " + via_id)
	if not bool(res.get("ok", false)):
		return {"success": false, "error": str(res.get("error", "via_not_placeable")),
			"note": str(res.get("message", "The via cannot be edited that way."))}

	var pos: Vector2 = res.get("position", Vector2.ZERO)
	var span: Array = PcbLayerStack.default_through_via_span()
	return _ok({
		"via_id": via_id,
		"x_mm": _mm(pos.x),
		"y_mm": _mm(pos.y),
		"net_name": str(res.get("net_name", "")),
		"size_mm": _mm(float(res.get("size", 0.8))),
		"drill_mm": _mm(float(res.get("drill", 0.4))),
		"trace_ids": res.get("trace_ids", []),
		"snapped_to_trace": bool(res.get("snapped", false)),
		# `changed` false is a successful no-op: the requested values were
		# already the via's values. Distinct from a refusal, which returns
		# success:false with a named error.
		"changed": bool(res.get("moved", false)),
		"from_layer": str(span[0]),
		"to_layer": str(span[1]),
	})


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
	_prune_foreign_commit_claims(host, data)  # see _delete_traces' phase-2 note
	if not data.remove_via_by_id(via_id):
		return _err("Unknown via: %s" % via_id)
	# A via a COMMITTED candidate owns is a layer change that candidate's route
	# depends on, so removing it retires the commit. Placed like _delete_traces'
	# phase 3: before the snapshot, so this delete's one history entry carries
	# both halves.
	var reopened: Array = _reconcile_committed_copper(host, data)
	data.save_to_history("Delete via " + via_id)
	var reply := {
		"deleted": via_id,
		"net_name": net_name,
		"x_mm": _mm(pos.x),
		"y_mm": _mm(pos.y),
		"remaining_via_count": data.vias.size(),
	}
	if not reopened.is_empty():
		reply["reopened_candidate_ids"] = reopened
		reply["note"] = "this via was committed by %d route candidate(s); their commits are retired and their routing tasks are OPEN again — re-check or reroute before committing them" % reopened.size()
	return _ok(reply)


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
static func _list_cutouts(host, _args: Dictionary) -> Dictionary:
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


# ── BOARD-LEVEL GRAPHICS ──────────────────────────────────────────────────────
# Artwork the BOARD owns rather than a component. The only other graphic owner
# is a footprint, so without these verbs board text has to be hung off whatever
# part happens to be nearby, in absolute board coordinates that part's placement
# then corrupts.
#
# Both authoring verbs are ONE journalled undo step (mutate, THEN
# save_to_history — snapshotting first makes redo silently do nothing), mint
# their id through PcbEntityId so it is the same "<type>:<32hex>" token the Go
# codec and the Python validator accept, and reply with that id plus the bounds
# the artwork actually occupies.


## Parse one {x_mm, y_mm} point, or null. Board graphics use the canonical
## board-level point shape, the same one zones, cutouts and traces use — never
## the bare [x, y] pair component graphics ride with.
static func _graphic_point(raw) -> Variant:
	if not (raw is Dictionary) or not raw.has("x_mm") or not raw.has("y_mm"):
		return null
	return {"x_mm": float(raw["x_mm"]), "y_mm": float(raw["y_mm"])}


static func _graphic_points(raw) -> Variant:
	if not (raw is Array):
		return null
	var out: Array = []
	for p in raw:
		var pt = _graphic_point(p)
		if pt == null:
			return null
		out.append(pt)
	return out


## Render a string as stroke-font polylines on a silk layer.
##
## B-SIDE TEXT IS MIRRORED, automatically and unconditionally, because a Gerber
## is plotted as seen from the top THROUGH the board: back legend has to be
## mirror-written in the file to read correctly once the board is flipped. The
## mirror is about the text's own anchor, so asking for text at (10, 10) puts it
## at (10, 10) on either side — it does not move, it reads the other way. The
## reply says `mirrored` so the caller never has to infer it.
##
## The board stores WHAT THE TEXT SAYS, not its strokes: the panel and the
## worker's compiler both derive glyphs from the same table, so fixing a typo is
## an edit to one string rather than a regeneration of a hundred polylines.
static func _add_silk_text(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var text := str(args.get("text", ""))
	if text.is_empty():
		return _err("text is required and must not be empty")
	if not args.has("position"):
		return _err("position is required: {x_mm, y_mm}")
	var pos = _graphic_point(args.get("position"))
	if pos == null:
		return _err("position needs x_mm and y_mm")
	var layer := str(args.get("layer", "F.SilkS"))
	if not PcbBoardGraphic.is_silk(layer):
		return _err("layer must be F.SilkS or B.SilkS for text, got %s" % layer)
	var size_mm := float(args.get("size_mm", PcbBoardGraphic.DEFAULT_TEXT_SIZE_MM))
	var built: Dictionary = PcbBoardGraphic.build_text(
		text, float(pos["x_mm"]), float(pos["y_mm"]), layer, size_mm,
		float(args.get("rotation_deg", 0.0)), str(args.get("id", "")),
		float(args.get("width_mm", -1.0)), str(args.get("h_align", "left")))
	if not built["ok"]:
		return _err(built["error"])
	var stored: Dictionary = data.add_board_graphic(built["graphic"])
	if stored.is_empty():
		return _err("Board graphic could not be added (duplicate or malformed id).")
	data.save_to_history("Add silk text")
	var reply: Dictionary = PcbBoardGraphic.summary(stored)
	# Unknown characters draw a BOX and are named here rather than dropped. A
	# dropped character shortens a legend without saying so; a box is visible in
	# the editor and this list explains it without a second call.
	var missing: Array = PcbBoardGraphic.display(stored)["missing"]
	reply["missing_glyphs"] = missing
	if not missing.is_empty():
		reply["note"] = ("%d character(s) have no glyph in the board font and are "
			+ "drawn as a box: %s") % [missing.size(), ", ".join(missing)]
	return _ok(reply)


## Author raw stroke geometry on a silk or courtyard layer.
##
## Accepts exactly one of `polylines`, `points`, `rect` or `circle`. Copper and
## Edge.Cuts are refused: board-level copper would be unconnected metal that
## routing and DRC must reason about with no net, and the board rim already has
## an owner (the profile and its cutouts).
static func _add_graphic(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var layer := str(args.get("layer", ""))
	if layer.is_empty():
		return _err("layer is required: one of %s" % ", ".join(PcbBoardGraphic.ALLOWED_LAYERS))
	var width_mm := float(args.get("width_mm", -1.0))

	# EXACTLY ONE geometry key. Accepting several and silently preferring one is
	# how a caller ends up drawing something it did not ask for.
	var supplied: Array = []
	for key in ["polylines", "points", "rect", "circle"]:
		if args.has(key):
			supplied.append(key)
	if supplied.size() != 1:
		return _err("supply exactly one of polylines, points, rect or circle (got %d: %s)"
			% [supplied.size(), ", ".join(supplied)])

	var specs: Array = []
	match supplied[0]:
		"polylines":
			var raw = args.get("polylines")
			if not (raw is Array) or (raw as Array).is_empty():
				return _err("polylines must be a non-empty array of point arrays")
			for chain in raw:
				var pts = _graphic_points(chain)
				if pts == null:
					return _err("every polyline point needs x_mm and y_mm")
				specs.append({"kind": "polyline", "points": pts})
		"points":
			var pts = _graphic_points(args.get("points"))
			if pts == null:
				return _err("every point needs x_mm and y_mm")
			var closed := bool(args.get("closed", false))
			specs.append({"kind": "poly" if closed else "polyline", "points": pts})
		"rect":
			var r = args.get("rect")
			if not (r is Dictionary):
				return _err("rect must be {start:{x_mm,y_mm}, end:{x_mm,y_mm}}")
			var a = _graphic_point((r as Dictionary).get("start"))
			var b = _graphic_point((r as Dictionary).get("end"))
			if a == null or b == null:
				return _err("rect needs start and end points with x_mm and y_mm")
			specs.append({"kind": "rect", "start": a, "end": b})
		"circle":
			var c = args.get("circle")
			if not (c is Dictionary):
				return _err("circle must be {center:{x_mm,y_mm}, radius_mm:<n>}")
			var centre = _graphic_point((c as Dictionary).get("center"))
			var radius := float((c as Dictionary).get("radius_mm", 0.0))
			if centre == null or radius <= 0.0:
				return _err("circle needs a center with x_mm/y_mm and a positive radius_mm")
			specs.append({"kind": "circle", "center": centre, "radius": radius})

	# Build EVERY payload before writing ANY of them, so a malformed third chain
	# refuses the whole call instead of leaving one and a half graphics on the
	# board for the next undo to half-restore.
	var payloads: Array = []
	var requested_id := str(args.get("id", ""))
	# ONE ID NAMES ONE GRAPHIC. Several polylines are several graphics, and the
	# id used to be applied to none of them — the caller asked for artwork it
	# could delete by that id and got artwork it could not.
	if not requested_id.is_empty() and specs.size() > 1:
		return _err(("id names ONE graphic, but %d polylines are %d graphics. "
			+ "Add them one call at a time to give each its own id, or drop id "
			+ "to have one minted per polyline.") % [specs.size(), specs.size()])
	for i in specs.size():
		var built: Dictionary = PcbBoardGraphic.build_geometry(
			layer, specs[i], width_mm,
			requested_id if (i == 0 and specs.size() == 1) else "")
		if not built["ok"]:
			return _err(built["error"])
		payloads.append(built["graphic"])

	data.begin_batch()
	var written: Array = []
	for payload in payloads:
		var stored: Dictionary = data.add_board_graphic(payload)
		if not stored.is_empty():
			written.append(PcbBoardGraphic.summary(stored))
	data.end_batch("Add graphic" if written.size() == 1 else "Add graphic (%d)" % written.size())
	if written.is_empty():
		return _err("No graphic was added (duplicate or malformed id).")
	if written.size() == 1:
		return _ok(written[0])
	return _ok({"graphics": written, "graphic_count": written.size()})


## Delete one board graphic by id. ONE undo step, and an unknown id is an
## explicit error rather than a silent no-op — the same contract _delete_zone
## keeps. Mutate THEN snapshot — snapshotting first makes redo silently do
## nothing.
static func _delete_graphic(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var graphic_id := str(args.get("graphic_id", ""))
	if graphic_id.is_empty():
		return _err("graphic_id is required")
	var graphic: Dictionary = data.get_board_graphic(graphic_id)
	if graphic.is_empty():
		return _err("Unknown board graphic: %s" % graphic_id)
	# Read the reply fields BEFORE the removal — afterwards the dict is off the
	# board and `summary` would be describing something that no longer exists.
	var summary: Dictionary = PcbBoardGraphic.summary(graphic)
	if not data.remove_board_graphic(graphic_id):
		return _err("Unknown board graphic: %s" % graphic_id)
	data.save_to_history("Delete board graphic " + graphic_id)
	summary["deleted"] = graphic_id
	return _ok(summary)


# ── Epoch UX4 station 8 (DCR S8): the STAGING family ──────────────────────────
# minerva_pcb_propose_zone/_propose_cutout are ARG-IDENTICAL twins of the
# create_* tools — same validation, same refusal texts — that land a DRAFT in
# the staged store instead of writing the board. FAMILY NOTE (the naming
# hazard the DCR review called out): this propose_* family STAGES BOARD
# ENTITIES; the unrelated workspace_propose_* family runs the ROUTER. The
# tool descriptions state membership so an agent never conflates them.
# All five are THIN over the panel's own transactions (stage_built_payload /
# accept_staged / reject_staged / accept_staged_batch) — the same one-doorway
# rule (A8) the canvas commit sites keep.


static func _staged_panel(host) -> Variant:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("stage_built_payload"):
		return _err("no live panel — staging is a panel transaction")
	return panel


static func _propose_zone(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var panel = _staged_panel(host)
	if not (panel is Object):
		return panel
	var kind: String = str(args.get("kind", "copper_pour"))
	var net_name: String = str(args.get("net", ""))
	var layer: String = str(args.get("layer", ""))
	if not args.has("outline"):
		return _err("outline is required: an array of {x_mm, y_mm} points")
	var pts = _parse_zone_outline(args.get("outline"))
	if pts == null:
		return _err("outline points need x_mm and y_mm")
	var built: Dictionary = data.build_zone_payload(net_name, layer, pts, kind)
	if not bool(built.get("ok", false)):
		return _err(str(built.get("error", "Zone was refused.")))
	var payload: Dictionary = _dict_or_empty(built.get("payload"))
	var staged: Dictionary = panel.stage_built_payload("zone", payload, "ai", str(args.get("note", "")))
	if not bool(staged.get("ok", false)):
		return {"success": false, "error": str(staged.get("error", "stage_refused"))}
	return _ok({
		"entity_id": str(payload.get("id", "")),
		"staged_id": str(staged.get("staged_id", "")),
		"kind": data.zone_kind(payload),
		"net": str(payload.get("net", "")),
		"layer": str(payload.get("layer", "")),
		"point_count": pts.size(),
		"note": "a ghost DRAFT — nothing is on the board until minerva_pcb_staged_accept",
	})


static func _propose_cutout(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var panel = _staged_panel(host)
	if not (panel is Object):
		return panel
	if not args.has("outline"):
		return _err("outline is required: an array of {x_mm, y_mm} points")
	var pts = _parse_zone_outline(args.get("outline"))
	if pts == null:
		return _err("outline points need x_mm and y_mm")
	var built: Dictionary = data.build_cutout_payload(pts)
	if not bool(built.get("ok", false)):
		return _err(str(built.get("error", "Cutout was refused.")))
	var payload: Dictionary = _dict_or_empty(built.get("payload"))
	var staged: Dictionary = panel.stage_built_payload("cutout", payload, "ai", str(args.get("note", "")))
	if not bool(staged.get("ok", false)):
		return {"success": false, "error": str(staged.get("error", "stage_refused"))}
	return _ok({
		"entity_id": str(payload.get("id", "")),
		"staged_id": str(staged.get("staged_id", "")),
		"point_count": pts.size(),
		"note": "a ghost DRAFT — nothing is on the board until minerva_pcb_staged_accept",
	})


## P1 C5: other live placement ghosts' TARGET poses, as extra collision
## bodies for PCBData.placement_collisions — so two pending proposals that
## collide with each other are reported, not just proposal-vs-board.
static func _other_ghost_targets(store, exclude_entity_id: String) -> Array:
	var extras: Array = []
	if store == null or not store.has_method("staged_entries"):
		return extras
	for e in store.staged_entries():
		var entry: Dictionary = e
		if str(entry.get("kind", "")) != "placement":
			continue
		var payload: Dictionary = _dict_or_empty(entry.get("payload"))
		if str(payload.get("id", "")) == exclude_entity_id:
			continue
		var to: Dictionary = _dict_or_empty(payload.get("to"))
		# VERBATIM, not quantized. These are collision BODIES handed to
		# PCBData.placement_collisions, not a reply — rounding them moves the
		# other ghost by up to 0.00005mm before the polygon intersection and can
		# flip a tangent overlap. The staged payload already holds the caller's
		# own 64-bit target, which is the pose the collision has to be computed
		# against. Same reply-boundary distinction the route-intent sentinel
		# regression came from.
		extras.append({
			"component_id": str(payload.get("component_id", "")),
			"x_mm": float(to.get("x_mm", 0.0)),
			"y_mm": float(to.get("y_mm", 0.0)),
			"rotation_deg": float(to.get("rotation_deg", 0.0)),
		})
	return extras


## Propose a component MOVE as a staged ghost (spike 019ff8615fbe, hardened
## in P1). The agent twin of propose-mode dragging; author "ai". One live
## ghost per component — a standing one refuses with its entity_id so the
## agent revises via minerva_pcb_placement_update (or rejects first).
static func _propose_placement(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data
	var panel = _staged_panel(host)
	if not (panel is Object):
		return panel
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required (the ref, e.g. \"R1\")")
	if not (args.has("x_mm") and args.has("y_mm")):
		return _err("x_mm and y_mm are required: the proposed target position")
	var comp = data.get_component(component_id)
	if comp == null:
		return _err("Component \"%s\" is not on this board." % component_id)
	var store = panel.get_staged_store() if panel.has_method("get_staged_store") else null
	if store != null and store.has_method("live_placement_for_component"):
		var standing := str(store.live_placement_for_component(component_id))
		if not standing.is_empty():
			var st_entry: Dictionary = store.get_entry(standing)
			return {"success": false, "error": "placement_already_staged",
				"entity_id": str((st_entry.get("payload", {}) as Dictionary).get("id", "")),
				"note": "one live move ghost per component — revise it with minerva_pcb_placement_update or reject it first"}
	var rot := float(args.get("rotation_deg", comp.rotation))
	var built: Dictionary = data.build_placement_payload(component_id,
		float(args.get("x_mm", 0.0)), float(args.get("y_mm", 0.0)), rot)
	if not bool(built.get("ok", false)):
		return _err(str(built.get("error", "Placement was refused.")))
	var payload: Dictionary = _dict_or_empty(built.get("payload"))
	var staged: Dictionary = panel.stage_built_payload("placement", payload, "ai", str(args.get("note", "")))
	if not bool(staged.get("ok", false)):
		return {"success": false, "error": str(staged.get("error", "stage_refused"))}
	var reply := _ok({
		"entity_id": str(payload.get("id", "")),
		"staged_id": str(staged.get("staged_id", "")),
		"component_id": component_id,
		"from": payload.get("from", {}),
		"to": payload.get("to", {}),
		"affected_nets": payload.get("affected_nets", []),
		"note": "a ghost DRAFT — the part has not moved; minerva_pcb_staged_accept applies it, and routed copper is FLAGGED, never auto-fixed",
	})
	# P1 C5 (parity principle): the reply carries what the dragging human
	# SEES — target-pose overlap vs placed parts and other live ghosts.
	# Advisory always (A7): nothing refuses on a collision.
	var to: Dictionary = _dict_or_empty(payload.get("to"))
	var collisions: Array = data.placement_collisions(component_id,
		float(to.get("x_mm", 0.0)), float(to.get("y_mm", 0.0)),
		float(to.get("rotation_deg", 0.0)),
		_other_ghost_targets(store, str(payload.get("id", ""))))
	if not collisions.is_empty():
		reply["collisions"] = collisions
	return reply


## SPIKE 019ff8615fbe: revise a live placement ghost's TARGET pose — the
## agent twin of dragging the ghost (the Update of the CRUD cycle).
static func _placement_update(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("get_staged_store"):
		return _err("no live panel — the staged store is panel state")
	var store = panel.get_staged_store()
	if store == null:
		return _err("no staged store bound to this panel")
	var entity_id: String = str(args.get("entity_id", ""))
	if entity_id.is_empty():
		return _err("entity_id is required (the placement:<hex> id from propose/list)")
	var sid := str(store.staged_id_for_entity(entity_id))
	if sid.is_empty():
		return _err("staged_entry_not_found: no live entry '%s'" % entity_id)
	var entry: Dictionary = store.get_entry(sid)
	if str(entry.get("kind", "")) != "placement":
		return _err("'%s' is a staged %s, not a placement" % [entity_id, str(entry.get("kind", ""))])
	var to: Dictionary = _dict_or_empty((entry.get("payload", {}) as Dictionary).get("to"))
	if not (to is Dictionary):
		to = {}
	var x := float(args.get("x_mm", to.get("x_mm", 0.0)))
	var y := float(args.get("y_mm", to.get("y_mm", 0.0)))
	var rot := float(args.get("rotation_deg", to.get("rotation_deg", 0.0)))
	# Codex 1182 F7: note is tri-state — absent = unchanged, "" = CLEAR.
	if not store.update_placement_target(sid, x, y, rot,
			args.get("note") if args.has("note") else null):
		return _err(str(store.last_error.get("error", "update_refused")))
	var reply := _ok({
		"entity_id": entity_id,
		"to": {"x_mm": _mm(x), "y_mm": _mm(y), "rotation_deg": rot},
		"note": "ghost revised in place — still a DRAFT until minerva_pcb_staged_accept",
	})
	# P1 C5: the revised pose gets the same collision advisory propose gives.
	var data = _resolve_data(host)
	if data is Object:
		var upd_comp := str((entry.get("payload", {}) as Dictionary).get("component_id", ""))
		var collisions: Array = data.placement_collisions(upd_comp,
			x, y, rot, _other_ghost_targets(store, entity_id))
		if not collisions.is_empty():
			reply["collisions"] = collisions
		# Codex 1182 F5: what-breaks is derived from the CURRENT board, not
		# the proposal-time snapshot — copper may have changed since staging.
		reply["affected_nets"] = data.placement_affected_nets(upd_comp)
	return reply


static func _staged_list(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("get_staged_store"):
		return _err("no live panel — the staged store is panel state")
	var store = panel.get_staged_store()
	if store == null:
		return _err("no staged store bound to this panel")
	var include_terminal: bool = bool(args.get("include_terminal", false))
	var live_data = _resolve_data(host)
	var row_data = live_data if live_data is Object else null
	var entries: Array = []
	if include_terminal:
		for sid in store.entries:
			var e: Dictionary = store.get_entry(str(sid))
			e["staged_id"] = str(sid)
			entries.append(_staged_list_row(e, row_data))
	else:
		for e in store.staged_entries():
			entries.append(_staged_list_row(e, row_data))
	return _ok({"staged": entries, "count": entries.size(),
		"live_count": store.staged_entries().size()})


static func _staged_list_row(e: Dictionary, data = null) -> Dictionary:
	var payload: Dictionary = _dict_or_empty(e.get("payload"))
	var row := {
		"staged_id": str(e.get("staged_id", "")),
		"entity_id": str(payload.get("id", "")),
		"kind": str(e.get("kind", "")),
		"disposition": str(e.get("disposition", "")),
		"author": str(e.get("author", "")),
		"base_board_revision": int(e.get("base_board_revision", 0)),
	}
	if str(e.get("kind", "")) == "zone":
		row["zone_kind"] = str(payload.get("kind", ""))
		row["layer"] = str(payload.get("layer", ""))
		var net := str(payload.get("net", ""))
		if not net.is_empty():
			row["net"] = net
	elif str(e.get("kind", "")) == "placement":
		row["component_id"] = str(payload.get("component_id", ""))
		row["from"] = payload.get("from", {})
		row["to"] = payload.get("to", {})
		# Codex 1182 F5: LIVE derivation when the board is reachable — the
		# routed flag must describe today's copper, not staging day's. The
		# payload's proposal-time snapshot stays available as audit.
		#
		# The discriminator is TERMINAL vs LIVE, not the literal "staged"
		# (epoch GA cold review, finding 2). A terminal entry is an audit
		# record and must keep the pose-time snapshot; every LIVE entry is a
		# standing proposal whose routed flag has to describe today's copper —
		# and since freeze arrived there is more than one live disposition.
		# Written as "not terminal" so a future live disposition inherits the
		# correct behaviour instead of silently falling to the stale branch,
		# which is exactly how this defect was introduced.
		if data != null and not (str(e.get("disposition", "")) in StagedEntities.TERMINAL_DISPOSITIONS):
			row["affected_nets"] = data.placement_affected_nets(str(payload.get("component_id", "")))
		else:
			row["affected_nets"] = payload.get("affected_nets", [])
	var note := str(e.get("note", ""))
	if not note.is_empty():
		row["note"] = note
	return row


static func _staged_accept(host, args: Dictionary) -> Dictionary:
	var panel = _staged_panel(host)
	if not (panel is Object):
		return panel
	var data = _resolve_data(host)
	# Batch form (DCR S5's batch-accept pattern): entity_ids = all-or-nothing,
	# one undo step. Singular entity_id stays the simple path.
	if args.has("entity_ids") and args.get("entity_ids") is Array:
		var out: Dictionary = _dict_or_empty(panel.accept_staged_batch(args.get("entity_ids")))
		if not bool(out.get("ok", false)):
			return {"success": false, "error": str(out.get("error", "batch_refused")),
				"refusals": out.get("refusals", []),
				"note": str(out.get("note", ""))}
		var batch_reply := _ok({"accepted": int(out.get("accepted", 0)),
			"note": "one history step — a single undo returns the whole batch to ghosts"})
		# P1 C2 parity: an accepted MOVE reports its consequences like the
		# direct-move verb does. Codex 1182 F3: the assembly re-check keys on
		# WHETHER A PLACEMENT LANDED, never on whether copper happened to
		# strand — an overlapping unrouted move has no dangling_copper and is
		# exactly the case assembly exists to catch.
		if out.has("dangling_copper"):
			batch_reply["dangling_copper"] = out.get("dangling_copper")
		if int(out.get("placements", 0)) > 0 and data is Object:
			batch_reply = await _with_assembly_after_placement(host, data, batch_reply)
		return batch_reply
	var entity_id: String = str(args.get("entity_id", ""))
	if entity_id.is_empty():
		return _err("entity_id (or entity_ids for a batch) is required")
	var res: Dictionary = panel.accept_staged(entity_id)
	if not bool(res.get("ok", false)):
		return {"success": false, "error": str(res.get("error", "accept_refused")),
			"entity_id": entity_id, "note": str(res.get("note", ""))}
	var reply := _ok({"entity_id": entity_id, "kind": str(res.get("kind", "")),
		"note": "landed on the board (journalled; undo returns it to a ghost)"})
	if str(res.get("kind", "")) == "placement":
		if res.has("dangling_copper"):
			reply["dangling_copper"] = res.get("dangling_copper")
		if data is Object:
			reply = await _with_assembly_after_placement(host, data, reply)
	return reply


static func _staged_reject(host, args: Dictionary) -> Dictionary:
	var panel = _staged_panel(host)
	if not (panel is Object):
		return panel
	var entity_id: String = str(args.get("entity_id", ""))
	if entity_id.is_empty():
		return _err("entity_id is required")
	var res: Dictionary = panel.reject_staged(entity_id)
	if not bool(res.get("ok", false)):
		return {"success": false, "error": str(res.get("error", "reject_refused")),
			"entity_id": entity_id}
	return _ok({"entity_id": entity_id, "kind": str(res.get("kind", "")),
		"note": "draft discarded (kept as audit; undo revives the ghost)"})


## FREEZE a staged placement's pose (epoch GA, K7). The agent's half of the
## same verb the canvas offers — parity principle: one implementation
## (PCBPanel._set_staged_frozen, which owns the mandatory history pairing),
## one vocabulary, the same named refusals both ways.
static func _staged_freeze(host, args: Dictionary) -> Dictionary:
	return _staged_freeze_common(host, args, true)


## UNFREEZE a frozen staged placement.
static func _staged_unfreeze(host, args: Dictionary) -> Dictionary:
	return _staged_freeze_common(host, args, false)


static func _staged_freeze_common(host, args: Dictionary, want_frozen: bool) -> Dictionary:
	var panel = _staged_panel(host)
	if not (panel is Object):
		return panel
	var entity_id: String = str(args.get("entity_id", ""))
	if entity_id.is_empty():
		return _err("entity_id is required")
	var res: Dictionary = panel.freeze_staged(entity_id) if want_frozen \
		else panel.unfreeze_staged(entity_id)
	if not bool(res.get("ok", false)):
		# The store's refusals reach the agent BY NAME rather than as a generic
		# failure: staged_kind_not_freezable (only placements steer routing),
		# staged_entry_not_found, and the deliberate no-op refusal — an agent
		# that cannot tell "wrong kind" from "already frozen" cannot repair its
		# own call. NOT staged_entry_terminal: the panel resolves an entity id
		# through _resolve_live_staged first, which reports a terminal entry as
		# not-found because it is no longer live. Both doorways agree on that,
		# so parity holds; it is the store-level refusal that is unreachable
		# from here, not a divergence.
		return {"success": false, "error": str(res.get("error", "freeze_refused")),
			"entity_id": entity_id}
	if want_frozen:
		return _ok({"entity_id": entity_id, "kind": str(res.get("kind", "")), "frozen": true,
			"note": "pose settled — the ghost still renders, still counts in draft checks, and can be accepted or rejected without unfreezing; minerva_pcb_staged_unfreeze makes it editable again"})
	return _ok({"entity_id": entity_id, "kind": str(res.get("kind", "")), "frozen": false,
		"note": "pose editable again — routes already proposed against the settled pose may now go stale"})


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
			"dx_mm": _mm(offset.x), "dy_mm": _mm(offset.y), "changed": false,
		})
	if not data.set_member_offset(component_id, offset):
		# Defensive only — every refusal case above (ungrouped/locked/anchor)
		# is already handled ahead of this call.
		return _err("Could not set offset for %s." % component_id)
	data.save_to_history("Offset %s" % component_id)
	return _ok({
		"component_id": component_id, "group_id": gid,
		"dx_mm": _mm(offset.x), "dy_mm": _mm(offset.y), "changed": true,
	})


# ── Observability (B2, item 019fbb7156) ──────────────────────────────────────

## Structured panel layout state (mode/width/sidebar/drawer/dock/plugin_build
## — see PCBPanel.get_layout_state's own docs for the full shape, including
## the plugin_build design choice). Read-only — journals nothing, mutates
## nothing.
static func _get_layout_state(host, _args: Dictionary) -> Dictionary:
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
		return _ok({"trace_id": trace_id, "width_mm": _mm(float(trace.width)), "changed": false})
	var refusal: String = data.set_trace_width(trace_id, width_mm)
	if not refusal.is_empty():
		return _err(refusal)
	data.save_to_history("Set trace width")
	# The STORED width, re-read off the trace rather than echoed from the
	# request: the model is what a width IS, and a reply that echoed the input
	# would be indistinguishable from a write that never landed.
	return _ok({
		"trace_id": trace_id,
		"width_mm": _mm(float(trace.width)),
		"net_name": str(trace.net_name),
		"layer": str(trace.layer),
		"changed": true,
	})


## Read — and optionally set — the board's OPTIONS block: the allowed trace
## directions, the four numeric design rules, the drawing-grid pitch, and the
## three per-user snap toggles. The `view_state` shape, for the same reason:
## one verb that always reports the whole block, so a caller can read before it
## writes and read back what it changed without a second call.
##
## THE SAME OPERATION THE MENU RUNS. Both halves live in pcb_options_menu.gd
## (read_state / apply) and this verb only shapes the envelope, so the panel's
## Options menu and this tool cannot drift into two rules.
##
## VALIDATED WHOLE, THEN APPLIED WHOLE: a bad mode, a malformed angle list, an
## unknown key or an out-of-range width changes NOTHING and names what was
## wrong. The board half of a real change is exactly one undo step however many
## rules moved.
##
## `trace_angle_mode` and `allowed_trace_angles_deg` are two spellings of one
## rule and passing both is refused rather than silently resolved — a mode IS an
## angle set, and a caller that sent conflicting ones asked two different things.
static func _board_rules(host, args: Dictionary) -> Dictionary:
	var data = _get_data(host)
	var prefs = _PcbPrefsScript.shared()
	var changes: Dictionary = {}
	for key in args:
		var name := str(key)
		if name == "editor_name":
			continue
		changes[name] = args[key]
	if changes.is_empty():
		return _ok(_PcbOptionsMenuScript.read_state(data, prefs))
	var result: Dictionary = _PcbOptionsMenuScript.apply(data, prefs, changes)
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", "Board rules could not be set.")))
	var reply: Dictionary = _dict_or_empty(result.get("state", {}))
	reply["changed"] = result.get("changed", [])
	var warning := str(prefs.take_warning())
	if not warning.is_empty():
		reply["warning"] = warning
	return _ok(reply)


## Read one plugin preference. Read-only — journals nothing, writes nothing.
## Reports the EFFECTIVE value plus whether it was actually stored, because
## "never chosen" and "chosen and equal to the default" are different facts the
## panel's seeding order depends on.
static func _get_preference(_host, args: Dictionary) -> Dictionary:
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
	var res: Dictionary = _dict_or_empty(prefs.set_value(key, args.get("value")))
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
	# src_path rides along (UX2 station 8): a file-loaded board's annotations
	# get a durable sidecar home at <path>.annotations.json — see
	# load_board_from_yaml's adoption rules.
	var reply: Dictionary = await host.load_board(yaml_text, src_path)
	if not bool(reply.get("ok", false)):
		var err_info: Dictionary = _dict_or_empty(reply.get("error"))
		return _err(str(err_info.get("message", "load_board failed")))
	var out: Dictionary = _dict_or_empty(reply.get("result"))
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

	var before_nets: Dictionary = _dict_or_empty(before.get("trace_nets"))
	var after_nets: Dictionary = _dict_or_empty(after.get("trace_nets"))
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
	# COPPER-LOSS reconcile, the same compensating-half shape as
	# _reconcile_hint_lifecycle below: nothing tells the workspace that copper it
	# committed was deleted, so the question is asked HERE, at the top of every
	# verb, BEFORE any of them reports a task state or a committed_trace_ids
	# list. The rule itself lives in the model
	# (RoutingWorkspace.reconcile_committed_copper); this is only the wiring.
	# Runs FIRST so the hint pass below sees the reconciled dispositions and
	# reopens the source hint of a commit that just lost its copper in the same
	# pass.
	_reconcile_committed_copper(host, data)
	# MF-2 (review, owner-ratified HITL-2 — undo coherence): see
	# _reconcile_hint_lifecycle's own doc for why this lazy self-heal, run at
	# the top of EVERY workspace verb, is the compensating half for a gap that
	# cannot be closed synchronously.
	_reconcile_hint_lifecycle(host, workspace)
	return {"ok": true, "ws": workspace, "data": data}


## OWNERSHIP PRE-CHECK, run BEFORE copper is removed or reshaped.
## _reconcile_committed_copper below runs AFTER the removal, where a
## lying record and a genuine loss look identical — both name an id the board no
## longer carries. Asked HERE, while the copper is still resolvable, the two
## separate: a claim on copper that belongs to another net is dropped, so the
## edit that follows can only ever retire a commit that really owned what it
## just lost. PRUNE-ONLY: a claim on an id that already resolves to nothing is
## left for the reconcile to report as the loss it is, and no candidate is
## uncommitted here. Silent by design — the drop is warned inside the workspace,
## and the load_board that restored the record is where it is reported.
##
## Three callers: _delete_traces, _delete_via and _retire_commits_owning_trace.
static func _prune_foreign_commit_claims(host, data) -> void:
	if data == null or not is_instance_valid(data):
		return
	var workspace = _get_workspace(host)
	if workspace == null or not workspace.has_method("prune_foreign_copper_claims"):
		return
	workspace.prune_foreign_copper_claims(_PcbCopperOwnership.index_from_board(data))


## Wiring for the copper-loss reconcile: resolve the routing workspace, BIND it
## to the board (idempotent — bucket 8 only exists while a delegate is bound)
## and ask the model its question. Returns the candidate ids whose commit was
## retired, [] when there is no workspace to ask (headless, or a host with no
## panel).
##
## Two callers: _workspace_ctx above, so every workspace verb reports against
## copper that exists, and _delete_traces, so that tool reconciles inside its
## own history step.
static func _reconcile_committed_copper(host, data) -> Array:
	if data == null or not is_instance_valid(data):
		return []
	var workspace = _get_workspace(host)
	if workspace == null or not workspace.has_method("reconcile_committed_copper"):
		return []
	if data.has_method("bind_routing_workspace"):
		data.bind_routing_workspace(workspace)
	return workspace.reconcile_committed_copper(data)


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
## Since Epoch UX2 station 1 the reconcile enforces BOTH directions — see the
## inline comment in the loop: PCBData.redo() re-commits a candidate without
## touching the annotation store, so open-but-committed needs re-closing
## exactly the way applied-but-uncommitted needs reopening.
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
		if c == null or str(c.disposition) != "committed":
			continue
		# OWNERSHIP IS NOT CONSUMPTION: a via ENTITY
		# (no copper, one via) carries the hint it SERVES, not an answer to it.
		# A committed hole must never count as the copper backing an applied
		# hint — that is exactly the reopen this reconcile exists to perform.
		if _PcbRouteCandidateScript.is_proposed_via_entity(c):
			continue
		for hid in c.source_hint_ids:
			committed_hint_ids[str(hid)] = true
	for ann in host.get_all_annotations():
		if not (ann is Dictionary):
			continue
		if str((ann as Dictionary).get("kind", "")) != "pcb_route_hint":
			continue
		var hid := str((ann as Dictionary).get("id", ""))
		var lifecycle := str((ann as Dictionary).get("lifecycle", "open"))
		# BOTH directions of the same invariant (Epoch UX2 station 1, cold
		# review F3): "applied" is truthful iff a committed candidate backs
		# the hint RIGHT NOW.
		#   applied + no committed candidate -> reopen (commit was undone);
		#   open + committed candidate      -> re-close (the undo was itself
		#     redone via PCBData.redo(), which restores the candidate's
		#     committed disposition but never touches the annotation store —
		#     without this half the hint re-inks its full corridor OVER real
		#     copper and the next propose re-gathers it: duplicate copper).
		if lifecycle == "applied" and not committed_hint_ids.has(hid):
			_set_hint_lifecycle(host, hid, "open")
		elif lifecycle == "open" and committed_hint_ids.has(hid):
			_set_hint_lifecycle(host, hid, "applied")


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


## Mutate ONE hint's kind_payload.width_mm through the same
## mutate-with-history seam as _set_hint_lifecycle above (UX2 station 3 —
## reroute_route's width_mm arg). A width change is a REAL edit (unlike the
## lifecycle bookkeeping above): it rides the hint's revision history, so
## Ctrl+Z on the hint takes it back. Not a waypoints edit, so the superseded
## guard does not refuse it.
static func _set_hint_width(host, hint_id: String, width_mm: float) -> bool:
	if host == null or not host.has_method("get_by_id") or not host.has_method("update_annotation"):
		return false
	var ann: Dictionary = host.get_by_id(hint_id)
	if ann.is_empty():
		return false
	var updated: Dictionary = ann.duplicate(true)
	var kp: Dictionary = _dict_or_empty(updated.get("kind_payload")).duplicate(true)
	kp["width_mm"] = width_mm
	updated["kind_payload"] = kp
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
	# P1-B (Codex 1047): constraint provenance is DURABLE candidate state now
	# (PcbRouteCandidate.constraint_revision / .hint_status, set at ingest) —
	# every listing surfaces it, not just the immediate propose/reroute reply.
	# Same absent-key contract as _stamp_constraint_revision: -1/-empty means
	# "generated with no constraint in play" and the key is simply absent.
	if int(c.constraint_revision) >= 0:
		rec["constraint_revision"] = int(c.constraint_revision)
	# UX4 station 10 (019fd0ab5af8): width + its provenance on EVERY listing,
	# not just the propose reply — the review question "is this 0.25mm meant
	# or a fallback" is now answerable from any surface. Absent for legacy
	# candidates ("" = generated before the field existed).
	if not (c.segments as Array).is_empty() and c.segments[0] is Dictionary:
		rec["width_mm"] = float((c.segments[0] as Dictionary).get("width", 0.0))
	if not str(c.width_source).is_empty():
		rec["width_source"] = str(c.width_source)
	if not (c.hint_status as Array).is_empty():
		rec["hint_status"] = (c.hint_status as Array).duplicate(true)
	# OFC-3: draft-placement provenance is durable candidate state (stamped at
	# ingest) — absent-when-empty like the provenance keys above. The derived
	# per-ghost status needs board+store context this builder doesn't have;
	# callers with a host attach it via _stamp_draft_placement_status.
	if not (c.draft_placements as Array).is_empty():
		rec["draft_placements"] = (c.draft_placements as Array).duplicate(true)
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
	# VIA-ENTITY OWNERSHIP. A candidate that is exactly ONE VIA and no copper is
	# a proposed via ENTITY, and the question asked of every one of them is
	# "what is this for?". Answer it on the row rather than leaving a reader to
	# match coordinates to hint segments by eye:
	# `owner_hint_ids` is who it serves, `owner` is the one-word verdict, and an
	# ownerless one SAYS SO — it stays perfectly legal (an unassigned via is a
	# real workflow), it is just never again mistaken for an attributed one.
	if _PcbRouteCandidateScript.is_proposed_via_entity(c):
		var owners: Array = _string_list(c.source_hint_ids)
		rec["owner_hint_ids"] = owners
		rec["owner"] = ("hint %s" % str(owners[0])) if not owners.is_empty() else "none"
		if owners.is_empty():
			rec["unowned"] = true
			rec["unowned_note"] = "unowned via ghost: it names no route hint" \
				+ ("" if not str(c.net).is_empty() else " and no net") \
				+ " — re-propose it with for_hint (minerva_pcb_propose_via) to say what it serves"

	# Route-quality metrics (Epoch UX2 station 4, docket 019fde36651a — the
	# HITL-5 lesson mechanized: nothing in the loop scored route QUALITY, so
	# satisfying-the-collision-signal masqueraded as done and a human had to
	# catch "this route wants a placement change"). Cheap, always-on, computed
	# from the candidate's own geometry.
	var quality: Dictionary = _route_quality(c)
	if not quality.is_empty():
		rec["bend_count"] = quality["bend_count"]
		rec["routed_length_mm"] = quality["routed_length_mm"]
		if quality.has("length_ratio"):
			rec["length_ratio"] = quality["length_ratio"]
		if quality.has("misalignment_mm"):
			rec["misalignment_mm"] = quality["misalignment_mm"]
	return rec


## OFC-3 (epoch 019ff9421d3f): snapshot of every LIVE placement ghost, in the
## shape candidates carry as draft_placements — taken at ingest so a
## candidate generated against a composed draft knows exactly which ghost
## poses its copper depends on. Empty when no ghosts are live (the common
## real-board propose) or when the panel/store is unreachable (headless
## harness without a mount) — absent provenance means no gate, the honest
## legacy behavior.
static func _live_placement_snapshot(host) -> Array:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("get_staged_store"):
		return []
	return _live_placement_snapshot_from_store(panel.get_staged_store())


## The store-walk half, callable where the STORE is already in hand —
## PCBPanel.route_board captures the compose-time draft context through this
## (F1, Codex OFC review 1188: provenance must be sampled ATOMICALLY with the
## request composition, never re-sampled after the worker await).
static func _live_placement_snapshot_from_store(store) -> Array:
	if store == null or not store.has_method("staged_payloads"):
		return []
	var out: Array = []
	for p in store.staged_payloads("placement"):
		if not (p is Dictionary):
			continue
		out.append({
			"id": str((p as Dictionary).get("id", "")),
			"component_id": str((p as Dictionary).get("component_id", "")),
			"to": ((p as Dictionary).get("to", {}) as Dictionary).duplicate(true) \
				if (p as Dictionary).get("to", null) is Dictionary else {},
		})
	return out


## Pose equality for draft-placement status: exact-assignment poses survive
## float round-trips bit-identically, but rotation may normalize (450 == 90),
## so compare mod 360 with a hair of tolerance.
static func _placement_pose_matches(x: float, y: float, rot: float, to: Dictionary) -> bool:
	if not (is_equal_approx(x, float(to.get("x_mm", 0.0))) \
			and is_equal_approx(y, float(to.get("y_mm", 0.0)))):
		return false
	var a := fposmod(rot, 360.0)
	var b := fposmod(float(to.get("rotation_deg", 0.0)), 360.0)
	return is_equal_approx(a, b) or is_equal_approx(absf(a - b), 360.0)


## Derive each snapshot ghost's CURRENT status — at READ time, from the board
## and store as they are now (one derivation for listings, commit gate and
## replies; never cached, never event-driven — ghost pose edits are scratch
## and bump no revision anything could subscribe to):
##   satisfied   — the component's REAL pose equals the snapshot target: the
##                 move landed, this dependency is discharged.
##   pending     — a live ghost still targets the snapshot pose (any ghost —
##                 reject-then-repropose to the same pose is the same world):
##                 accept the move first, or reject it and reroute.
##   invalidated — component gone, ghost gone, or ghost retargeted: the
##                 candidate routed against a world that no longer exists.
## Returns the snapshot rows with a "status" key added; [] in ⇒ [] out.
static func _draft_placement_status(data, store, snapshot: Array) -> Array:
	var out: Array = []
	for s in snapshot:
		if not (s is Dictionary):
			continue
		var row: Dictionary = (s as Dictionary).duplicate(true)
		var comp_id := str(row.get("component_id", ""))
		var to: Dictionary = _dict_or_empty(row.get("to"))
		var status := "invalidated"
		var comp = data.get_component(comp_id) if data != null else null
		if comp != null and not to.is_empty():
			if _placement_pose_matches(comp.position.x, comp.position.y, comp.rotation, to):
				status = "satisfied"
			elif store != null and store.has_method("live_placement_for_component"):
				var sid := str(store.live_placement_for_component(comp_id))
				if not sid.is_empty():
					var live_to: Variant = ((store.get_entry(sid).get("payload", {}) as Dictionary)).get("to")
					if live_to is Dictionary and _placement_pose_matches(
							float((live_to as Dictionary).get("x_mm", 0.0)),
							float((live_to as Dictionary).get("y_mm", 0.0)),
							float((live_to as Dictionary).get("rotation_deg", 0.0)), to):
						status = "pending"
		row["status"] = status
		out.append(row)
	return out


## Attach derived statuses onto a candidate record's draft_placements rows —
## the caller-with-a-host half of _candidate_record's OFC-3 note. No-op for
## records without provenance.
static func _stamp_draft_placement_status(rec: Dictionary, host) -> void:
	if not rec.has("draft_placements"):
		return
	var data = _get_data(host)
	var panel = _get_panel(host)
	var store = panel.get_staged_store() \
		if panel != null and panel.has_method("get_staged_store") else null
	rec["draft_placements"] = _draft_placement_status(
		data, store, rec.get("draft_placements", []))


## The commit-side gate (OFC-3 ceremony, option (a) — the fail-safe default
## pending the owner's feel ruling, recorded on 019ff9428d80): copper routed
## against a ghost pose is INVALID on the real board until that placement
## lands. No acknowledge bypass — unlike the assembly gate's advisory
## findings, this is a factual mismatch, not a judgment call. Returns {} when
## the candidate carries no provenance or every dependency is satisfied;
## otherwise the refusal reply.
static func _draft_placement_block(host, c) -> Dictionary:
	if c == null or (c.draft_placements as Array).is_empty():
		return {}
	var data = _get_data(host)
	var panel = _get_panel(host)
	var store = panel.get_staged_store() \
		if panel != null and panel.has_method("get_staged_store") else null
	var statuses: Array = _draft_placement_status(data, store, c.draft_placements)
	var pending: Array = []
	var invalidated: Array = []
	for row in statuses:
		match str((row as Dictionary).get("status", "")):
			"pending": pending.append(row)
			"invalidated": invalidated.append(row)
	if pending.is_empty() and invalidated.is_empty():
		return {}
	# Invalidated outranks pending: an accept can cure pending, nothing but a
	# reroute cures invalidated.
	if not invalidated.is_empty():
		return {"success": false, "error": "draft_placement_invalidated",
			"candidate_id": str(c.candidate_id),
			"draft_placements": statuses,
			"note": "this candidate was routed against placement ghost pose(s) that no longer exist (ghost rejected, retargeted, or component gone) — its copper describes a world that isn't coming; reroute it (minerva_pcb_workspace_reroute_route) or reject it"}
	return {"success": false, "error": "draft_placement_pending",
		"candidate_id": str(c.candidate_id),
		"draft_placements": statuses,
		"note": "this candidate's copper lands at a placement ghost's target pads — accept the move first (minerva_pcb_staged_accept on the ghost id above), then commit; or reject the ghost and reroute"}


## Chain a candidate's segments into ordered XY polyline runs — the SHARED
## geometry walk behind _corridor_from_candidate_geometry (single-run
## enforcement is that caller's own rule) and _route_quality (which accepts
## any run count). Layer-agnostic on purpose: a layer-changing via with
## endpoint-coincident copper either side continues the SAME run — only a
## genuine XY gap starts a new one. Same epsilon family as commit-side
## chaining (see _GEOMETRY_CHAIN_EPSILON_MM's doc).
static func _chained_runs(c) -> Array:
	var runs: Array = []  # Array[Array[Vector2]]
	for seg in c.segments:
		if not (seg is Dictionary):
			continue
		var seg_pts: Array = []
		for p in (seg as Dictionary).get("points", []):
			if p is Vector2:
				seg_pts.append(p)
		if seg_pts.is_empty():
			continue
		if not runs.is_empty():
			var cur: Array = runs[runs.size() - 1]
			var last: Vector2 = cur[cur.size() - 1]
			if last.distance_to(seg_pts[0] as Vector2) <= _GEOMETRY_CHAIN_EPSILON_MM:
				for k in range(1, seg_pts.size()):
					cur.append(seg_pts[k])
				continue
		runs.append(seg_pts.duplicate())
	return runs


## Cheap route-quality metrics over a candidate's chained geometry (UX2
## station 4): {bend_count, routed_length_mm, length_ratio?}.
##   bend_count        interior vertices where the direction actually turns
##                     (collinear joints — e.g. a via splitting a straight
##                     run — do not count). Summed across disconnected runs.
##   routed_length_mm  total copper centerline length, all runs.
##   length_ratio      routed_length / manhattan-minimum, where the manhattan
##                     minimum is Σ per run of |dx|+|dy| between that run's
##                     endpoints — the shortest rectilinear path pretending
##                     no obstacle exists. APPROXIMATE by design: a diagonal
##                     route can score < 1.0, and the metric says nothing
##                     about which detours were justified. Absent when the
##                     manhattan minimum is ~0 (loop / zero-length run —
##                     a ratio against 0 is noise, not signal).
## The point of these numbers (owner, HITL-5): a HIGH ratio or bend count on
## a SHORT neighbor hop is the "move the part instead" smell — 5+5+5-segment
## signal-chasing vs 2+2+5 placement-first was the A/B that filed this.
static func _route_quality(c) -> Dictionary:
	if c == null:
		return {}
	var runs: Array = _chained_runs(c)
	# A vias-only / geometry-less candidate reports honest ZEROS rather than
	# omitting the keys (cold review F2): the record shape stays uniform, and
	# only length_ratio is ever conditionally absent.
	var bends: int = 0
	var routed: float = 0.0
	var manhattan: float = 0.0
	for run in runs:
		var pts: Array = run
		manhattan += PcbTraceGeometry.manhattan_distance(pts[0] as Vector2, pts[pts.size() - 1] as Vector2)
		# Leg-walk, carrying the last NON-DEGENERATE direction across
		# zero-length legs (cold review F3): a router that emits a degenerate
		# zero-length segment AT a corner must not make that genuine bend
		# vanish — comparing only immediate neighbors skipped both joints.
		var prev_dir := Vector2.ZERO
		for i in range(1, pts.size()):
			var leg: Vector2 = (pts[i] as Vector2) - (pts[i - 1] as Vector2)
			var leg_len: float = leg.length()
			routed += leg_len
			if leg_len <= _GEOMETRY_CHAIN_EPSILON_MM:
				continue
			var dir: Vector2 = leg / leg_len
			if prev_dir != Vector2.ZERO:
				# A turn is a genuine direction change — cross ≉ 0 (or a
				# straight reversal, dot < 0: copper doubling back).
				if absf(prev_dir.cross(dir)) > 0.001 or prev_dir.dot(dir) < 0.0:
					bends += 1
			prev_dir = dir
	var out: Dictionary = {
		"bend_count": bends,
		"routed_length_mm": snappedf(routed, 0.001),
	}
	if manhattan > _GEOMETRY_CHAIN_EPSILON_MM:
		out["length_ratio"] = snappedf(routed / manhattan, 0.001)
	# misalignment_mm (HITL-6, docket 019fdf2bce15): for a SINGLE-run
	# candidate — the 2-pin span case — the perpendicular offset its jog
	# spans: min(|dx|, |dy|) between the run's endpoints. 0.0 means the pads
	# align and every bend is a detour; > 0 means at least one bend is
	# structural (the pads don't line up — HITL-6's GND read 0.54 here) and
	# the PLACEMENT is the thing to question. ratio 1.0 cannot distinguish
	# the two — that is exactly the read the owner caught. Multi-run
	# candidates get no key (no single pad pair to blame).
	if runs.size() == 1:
		var run_pts: Array = runs[0]
		var a0: Vector2 = run_pts[0]
		var a1: Vector2 = run_pts[run_pts.size() - 1]
		out["misalignment_mm"] = snappedf(minf(absf(a1.x - a0.x), absf(a1.y - a0.y)), 0.001)
	return out


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
				pts.append([_mm((p as Vector2).x), _mm((p as Vector2).y)])
		segments.append({
			"id": str(seg_dict.get("id", "")),
			"layer": str(seg_dict.get("layer", "")),
			"width": _mm(float(seg_dict.get("width", 0.0))),
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
			"position": [_mm((pos as Vector2).x), _mm((pos as Vector2).y)] \
				if pos is Vector2 else [],
			"diameter": _mm(float(via_dict.get("diameter", 0.0))),
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
		"freeze":
			applied = workspace.freeze(cid)
		"unfreeze":
			applied = workspace.unfreeze(cid)
	if not applied:
		return _workspace_refusal(workspace, verb, cid)
	var reply: Dictionary = {"verb": verb}
	reply.merge(_candidate_record(workspace, workspace.get_candidate(cid)))
	_stamp_draft_placement_status(reply, host)  # OFC-3: derived ghost-dependency status
	# INV-2 is observable, not merely internal: name the candidates whose verdict
	# this verb invalidated so a caller knows what needs re-checking.
	reply["stale_candidate_ids"] = _stale_ids(workspace)
	# Epoch UX1 station 11: reject is the one disposition verb that reopens a
	# task with no successor of its own — say so. pin/unpin already read as
	# self-explanatory holds/releases and are unchanged.
	if verb == "reject":
		reply["note"] = _next_steps("reject", {})
	# Epoch UX3, K7: freezing changes what a candidate will REFUSE from here on
	# (reject/supersede/edits) — name the contract so the caller is not
	# surprised by the first refusal.
	if verb == "freeze":
		reply["note"] = "frozen: future routing treats this geometry as fixed copper; reject/try-again/edits are refused until minerva_pcb_workspace_unfreeze"
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


## Epoch UX1 station 11 (DCR 019fd095e694, docket 019fd095e694 "MCP surface"
## bullet "Replies name legal successors"): the ONE place that composes the
## compact next-step sentence a workspace-verb reply's `note` key carries, so
## the phrasing of "what can I legally call next" cannot drift between the
## reply sites that need it. TEXT ONLY — no behavior, schema, or tool
## surface change; every call site already had (or gains) exactly one `note`
## key, never a second one. `kind` selects the reply site; `ctx` carries just
## the values that sentence needs (e.g. a landed count). An unrecognised
## `kind` returns "" so a caller can guard with `if not text.is_empty()`
## instead of every call site re-deciding what "no guidance" means.
static func _next_steps(kind: String, ctx: Dictionary) -> String:
	match kind:
		"route_intent":
			var hint_id: String = str(ctx.get("hint_id", ""))
			var text := "no routing was performed. Legal next steps: minerva_pcb_workspace_propose(hint_ids:[\"%s\"]) or minerva_pcb_apply_route_hints(hint_ids:[\"%s\"]) to generate a candidate for review" % [hint_id, hint_id]
			var rev: Variant = ctx.get("constraint_revision")
			if rev != null:
				text += "; the stored corridor steers minerva_pcb_workspace_propose's router run (Epoch UX1 station 9) — the landed candidate will carry constraint_revision %d" % int(rev)
			return text
		"propose":
			return "%d candidate(s) await review: read geometry with workspace_list include_geometry:true, adjust with workspace_edit_candidate or reroute_route (corridor/preserve_shape_as_corridor), then workspace_commit (single or candidate_ids batch) or workspace_reject" % int(ctx.get("count", 0))
		"workspace_list":
			return "%d live candidate(s) pending: read geometry with workspace_list include_geometry:true, adjust with workspace_edit_candidate or reroute_route, then workspace_commit or workspace_reject" % int(ctx.get("count", 0))
		"edit_candidate":
			return "edited geometry is candidate-local; pin to hold it, or reroute_route preserve_shape_as_corridor to make it durable steering; commit when ready"
		"reroute_route":
			return "a fresh candidate replaced the prior generation; review it (workspace_list include_geometry:true), then workspace_commit or workspace_reject"
		"commit":
			return "copper landed; undo reverts; propose remaining open hints"
		"reject":
			return "task reopened; re-propose or edit the intent"
	return ""


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

	# ── DCR 01a022ab356c leg B: one-call span-propose ─────────────────────────
	# spans:[{source_pin, dest_pin, width_mm?, note?, corridor?}] mints a route
	# intent per span through the SAME author path the standalone tool uses
	# (identical annotation, citeable ref, width channel, eager task), then
	# routes the minted hints in this very call. ATOMIC across both stores:
	# every span validates BEFORE anything mints — a refusal leaves neither an
	# annotation nor an eager task behind. spans + hint_ids are a UNION (one
	# worker run routes both; owner ruling on the DCR).
	var minted_hint_ids: Array = []
	if args.has("spans"):
		var spans_v: Variant = args.get("spans")
		if not (spans_v is Array):
			return _err("spans must be an array of {source_pin, dest_pin, width_mm?, note?, corridor?}")
		var spans: Array = spans_v
		if spans.is_empty():
			# Present-but-empty refuses by name (the corridor precedent):
			# spans:[] is a caller stating "route these spans: none", not the
			# same ask as omitting the key.
			return _err("spans present but empty — omit the key entirely for a hint-only propose")
		for i in range(spans.size()):
			if not (spans[i] is Dictionary):
				return _err("spans[%d] must be an object with source_pin and dest_pin" % i)
			var v: Dictionary = _validate_route_intent(data, spans[i] as Dictionary)
			if not bool(v.get("ok", false)):
				var refusal: Dictionary = v.duplicate()
				refusal["span_index"] = i
				return refusal
		for i in range(spans.size()):
			var minted: Dictionary = _add_route_intent(host, spans[i] as Dictionary)
			if not bool(minted.get("success", false)):
				# Post-validation mint failures are NOT fully unreachable
				# (annotation-host/schema rejection sits past validation), and
				# spans 0..i-1 are already minted — name them on the failure
				# (fix cold review f4) so nothing is half-minted SILENTLY:
				# the earlier intents remain ordinary open hints.
				var failure: Dictionary = minted.duplicate()
				failure["span_index"] = i
				if not minted_hint_ids.is_empty():
					failure["minted_hint_ids"] = minted_hint_ids.duplicate()
					failure["note"] = str(failure.get("note", "")) \
						+ " — earlier spans already minted their intents (see minted_hint_ids); they remain open hints, routable by a later propose or deletable individually"
				return failure
			minted_hint_ids.append(str(minted.get("hint_id", "")))

	var hint_ids: Array = args.get("hint_ids", []) if args.get("hint_ids", []) is Array else []
	if not minted_hint_ids.is_empty():
		# Union — and with spans present the selection is ALWAYS ids-mode:
		# a span-propose must never widen into an every-open-hint run.
		hint_ids = hint_ids + minted_hint_ids
	var source_hints: Array = _gather_route_hints(host, hint_ids)
	if source_hints.is_empty():
		return _ok({
			"proposed": 0, "candidates": [], "holds": [], "unrouted": [], "stuck": [],
			"note": "no open route hints to route (add hints, pass hint_ids, or pass spans:[{source_pin, dest_pin}] to mint an intent and route it in one call)",
		})
	var selection: Dictionary
	if hint_ids.is_empty():
		selection = {"mode": "open"}
	else:
		selection = {"mode": "ids", "ids": _hint_id_list(source_hints)}

	# Epoch UX1 station 12: one-time legacy waypoint-hint migration, BEFORE
	# the router runs — see _seed_legacy_waypoint_constraints' own doc for the
	# full contract (durability, one-time gate, net-resolution discipline).
	_seed_legacy_waypoint_constraints(host, workspace, data, source_hints)

	var scope: Variant = _propose_scope(hint_ids, source_hints, data)
	# task_constraints (station 9) is keyed on the RESOLVED selection
	# (_hint_id_list(source_hints)), not the caller's raw hint_ids arg — an
	# "open" propose (hint_ids empty, selection {"mode":"open"}) still needs
	# every ACTUALLY-selected hint's task consulted, not none.
	var route_extra: Dictionary = _route_request_extra(workspace, scope, _hint_id_list(source_hints))
	# Epoch UX4 station 3: propose only ever lands ghosts — always a draft
	# request (staged keepouts detour it; the reply's health never feeds the
	# real board's assembly cache).
	route_extra["draft_request"] = true
	var reply: Dictionary = await _run_router(host, selection, route_extra)
	if not bool(reply.get("ok", false)):
		return _router_call_failed(reply, source_hints)
	var result: Dictionary = _dict_or_empty(reply.get("result"))
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
	var landed: Dictionary = await _ingest_result_into_workspace(host, workspace, data, result, source_hints, extra,
		reply.get("draft_context", {}) if reply.get("draft_context", null) is Dictionary else {})
	if not minted_hint_ids.is_empty():
		# Leg B reply contract: the caller learns WHICH intents this call
		# minted (order matches spans) — the durable, citeable records.
		landed["minted_hint_ids"] = minted_hint_ids
	return landed


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
	if not result.has("per_candidate"):
		return {"skipped": str(result.get("error", "draft_check_no_reply"))}
	if str(result.get("error", "")) != "":
		# A verdict the worker could not stand behind. The validations below are
		# workspace-authoritative so this cannot go false-clean, but the reply
		# must still say the check did not finish.
		return {"skipped": "draft_check_incomplete",
			"worker_error": str(result.get("error"))}
	var validation: Dictionary = {}
	for cid in live:
		var c = workspace.get_candidate(str(cid))
		if c != null:
			validation[str(cid)] = str(c.validation)
	var out := {
		"checked": live,
		"checked_stale": stale,
		# The workspace has applied coherence guards and fail-closed geometric
		# indeterminacy. Expose that authoritative verdict under the familiar key;
		# returning the worker's pre-application value here reintroduced the very
		# false-clean the state model had rejected.
		"per_candidate": validation,
		"findings": result.get("findings", []),
		"validation": validation,
	}
	# Keep the automatic landing check as honest as the explicit workspace-check
	# verb. A connectivity verdict is not a geometric verdict; if geometry could
	# not run, expose both the authoritative workspace state and the reason.
	var indeterminate: Dictionary = workspace.geometric_indeterminate() \
		if workspace.has_method("geometric_indeterminate") else {}
	if not indeterminate.is_empty():
		out["geometric_indeterminate"] = indeterminate
		out["note"] = "geometry could NOT be verified (%s) — no candidate is reported clean" % str(indeterminate.get("kind", "unknown"))
	var provenance: Variant = result.get("draft_provenance")
	if provenance is Array and not (provenance as Array).is_empty():
		out["draft_provenance"] = provenance
	return out


## Stamp width PROVENANCE (docket 019fd0ab5af8) from a _normalize_route_records
## record onto the candidate record it produced — additive keys "width_mm"
## (the route's effective width) and "width_source" (whatever vocabulary
## methods.py _attach_effective_routing_rules emits — "caller_option", "hint",
## "board_rules", "engine_default", "net_class", "net_copper" — relayed
## verbatim, never reinterpreted here). Absent when `route_rec` carries no
## "effective_width_mm" (the worker attached no provenance for this route —
## see _normalize_route_records' own absent-key note), so a caller can never
## mistake "we don't know" for "board default".
static func _stamp_width_provenance(candidate_rec: Dictionary, route_rec: Dictionary) -> void:
	if not route_rec.has("effective_width_mm"):
		return
	candidate_rec["width_mm"] = route_rec.get("effective_width_mm")
	candidate_rec["width_source"] = route_rec.get("effective_width_source", "")


## STATION 9 (DCR 019fd095e694), the "candidates cite the revision" half:
## additive `constraint_revision` key, same absent-key contract as
## _stamp_width_provenance above — absent when `route_rec` carries none (an
## unguided route, a route guided only by legacy inline waypoints, or an older
## worker that predates this station), never invented as 0.
static func _stamp_constraint_revision(candidate_rec: Dictionary, route_rec: Dictionary) -> void:
	if not route_rec.has("constraint_revision"):
		return
	candidate_rec["constraint_revision"] = int(route_rec.get("constraint_revision"))


## Lift MACHINE-READABLE per-hint statuses out of the router's flat warning
## list and onto the CANDIDATE they concern (bug 019fcf152791, Stage A).
##
## PLACEMENT IS THE POINT. These statuses also ride `stuck[]` like every other
## bridge warning — and `stuck[]` is where 1-3 real per-hint notes sit buried
## under ~28 repeated emitter-capability warnings on every single call
## (019fce3ac3f5 nit 2). A status that says "your authored corridor was
## ignored" is worthless in that channel: it went unread through two HITL
## cycles. It belongs on the candidate record, beside the geometry it is a
## statement about, where the pre-commit review actually happens.
##
## Matching is by hint id against each candidate's own source_hint_ids — never
## by net (two hints can name one net) and never positionally.
##
## docket 019fcf152791 (GDScript side): ALSO lifts result.corridor_adherence —
## the router's per-hint verdict on whether a route honored an owner-authored
## waypoint corridor ({hint_id, endpoints, status, corridor_honored,
## max_deviation_mm, tolerance_mm, per_waypoint, skipped_waypoints}). Same
## placement argument as the warnings above: this is a statement about a
## specific hint's geometry, so it belongs beside that geometry on the
## candidate record, not in stuck[]. Entries are attached VERBATIM (worker
## owns the shape) into the SAME rec["hint_status"] list the warnings-derived
## statuses use — one list, matched by hint id only, so a caller reads one
## place instead of two channels that could drift.
static func _attach_hint_status(landed: Array, result: Dictionary) -> void:
	var by_hint: Dictionary = {}
	for w in result.get("warnings", []):
		if not (w is Dictionary):
			continue
		var wd: Dictionary = w
		# Only STRUCTURED statuses are lifted; a bare {id, message} stays in
		# stuck[] where it always was (this is additive, not a re-route of the
		# whole warning channel).
		if not wd.has("waypoint_status"):
			continue
		var hid := str(wd.get("id", ""))
		if hid.is_empty():
			continue
		if not by_hint.has(hid):
			by_hint[hid] = []
		(by_hint[hid] as Array).append(wd)
	for ca in result.get("corridor_adherence", []):
		if not (ca is Dictionary):
			continue
		var cad: Dictionary = ca
		var chid := str(cad.get("hint_id", ""))
		if chid.is_empty():
			continue
		if not by_hint.has(chid):
			by_hint[chid] = []
		(by_hint[chid] as Array).append(cad)
	if by_hint.is_empty():
		return
	for rec in landed:
		if not (rec is Dictionary):
			continue
		var statuses: Array = []
		for hid in (rec as Dictionary).get("source_hint_ids", []):
			for wd in by_hint.get(str(hid), []):
				# F5 (HITL-4, docs/llm-ergonomics.md): the worker's JSON float
				# for the revision key is normalised to int here, matching the
				# candidate's own durable int field — the rest of the entry
				# stays verbatim (worker owns the shape).
				var entry: Dictionary = (wd as Dictionary).duplicate(true)
				if entry.has("constraint_revision"):
					entry["constraint_revision"] = int(entry.get("constraint_revision"))
				statuses.append(entry)
		if not statuses.is_empty():
			(rec as Dictionary)["hint_status"] = statuses


## The SHARED landing path for every tool that turns a router reply into
## candidates (propose, reroute-route, reroute-span). One place that normalizes,
## ingests, accumulates holds and shapes the reply, so the three verbs report
## identically and a fix to one is a fix to all. `extra` is merged last so a
## caller can stamp its own metadata (e.g. the span degrade notice).
static func _ingest_result_into_workspace(host, workspace, data, result: Dictionary,
		source_hints: Array, extra: Dictionary, draft_context: Dictionary = {},
		record_overrides: Dictionary = {}) -> Dictionary:
	# record_overrides (DCR 01a022ab356c leg C): keys merged onto EVERY
	# normalized record before ingest — the hint-less reroute passes
	# task_key_override / endpoints_override / width_override so a
	# hint-unattributed answer lands on the asking task instead of a phantom
	# "net|" key. Empty (the default) is byte-identical to the old behavior.
	var records: Array = _normalize_route_records(result, source_hints, data)
	if not record_overrides.is_empty():
		for rec_v in records:
			if rec_v is Dictionary:
				(rec_v as Dictionary).merge(record_overrides, true)
	# F1 (Codex 1188): the request context is captured by route_board
	# ATOMICALLY with the composition and rides the reply — both halves are
	# consumed from it here. base_board_revision comes from COMPOSE time when
	# the context carries it, so a board edited mid-flight lands its candidate
	# already stale under the existing is_stale_for_board_revision idiom
	# instead of masquerading as current.
	var revision: int = int(draft_context.get("board_revision",
		int(data.board_revision) if data != null else 0))
	var draft_snapshot: Array = draft_context.get("draft_placements", []) \
		if draft_context.get("draft_placements", null) is Array else []
	var landed: Array = []
	var holds: Array = []
	var unresolved_widths: Array = []
	# F4 (cold review): merge absorption's dropped-constraint conflicts —
	# same per-call accumulation idiom as `holds` above (workspace.
	# last_ingest_constraint_conflicts is reset at the start of every
	# ingest_record call, so this loop collects exactly the conflicts THIS
	# ingest caused).
	var constraint_conflicts: Array = []
	for rec in records:
		var cid: String = str(workspace.ingest_record(rec, revision, data))
		for hold in workspace.last_ingest_holds:
			holds.append(hold)
		for conflict in workspace.last_ingest_constraint_conflicts:
			constraint_conflicts.append(conflict)
		# Routes whose copper width could not be resolved —
		# same per-call accumulation idiom as `holds`. The ghost lands; commit
		# is what refuses it.
		for miss in workspace.last_ingest_unresolved_widths:
			unresolved_widths.append(miss)
		if cid.is_empty():
			continue
		# OFC-3: draft-placement provenance becomes durable candidate state
		# BEFORE the record is built, so the reply rows and every later
		# listing/sidecar reload report it identically.
		if not draft_snapshot.is_empty():
			var cobj_stamp = workspace.get_candidate(cid)
			if cobj_stamp != null:
				cobj_stamp.draft_placements = draft_snapshot.duplicate(true)
		var candidate_rec: Dictionary = _candidate_record(workspace, workspace.get_candidate(cid))
		_stamp_draft_placement_status(candidate_rec, host)
		# docket 019fd0ab5af8: stamp width provenance from the SAME normalized
		# `rec` that produced this exact candidate (ingest_record above is a
		# direct one-call-per-rec correspondence) — not a post-hoc match by net
		# or hint id, so two routes sharing one net can never cross-attribute.
		_stamp_width_provenance(candidate_rec, rec)
		_stamp_constraint_revision(candidate_rec, rec)
		landed.append(candidate_rec)
	_attach_hint_status(landed, result)
	# P1-B (Codex 1047): the statuses _attach_hint_status just lifted onto the
	# reply records become DURABLE candidate state too — matched back by
	# candidate_id (the recs were built one-per-ingest above), so workspace
	# listings and sidecar reloads keep reporting what the router said about
	# each hint at generation time instead of the stamp evaporating with this
	# reply. constraint_revision took the ingest_record path (the model owns
	# that stamp); hint_status is derived HERE from result warnings/adherence,
	# so here is where it lands on the object.
	for rec in landed:
		if not (rec is Dictionary) or not (rec as Dictionary).has("hint_status"):
			continue
		var cobj = workspace.get_candidate(str((rec as Dictionary).get("candidate_id", "")))
		if cobj != null:
			cobj.hint_status = ((rec as Dictionary)["hint_status"] as Array).duplicate(true)
	var out: Dictionary = {
		"proposed": landed.size(),
		"candidates": landed,
		"holds": holds,
		# See _ingest_result_into_workspace's key of the same name.
		"unresolved_widths": unresolved_widths,
		"routes_returned": (result.get("routes", []) as Array).size() if result.get("routes", []) is Array else 0,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
		"drc_summary": result.get("drc_summary", {}),
		"drc_geometric_summary": result.get("drc_geometric_summary", {}),
		"stale_candidate_ids": _stale_ids(workspace),
		"note": "candidates landed in the routing workspace; no proposal annotations were written",
	}
	# F1/F3 (HITL-4, docs/llm-ergonomics.md): the worker's per-span outcome
	# accounting ("already_connected" spans etc. — every asked-about span lands
	# in exactly one of candidates/holds/unrouted/span_outcomes) — additive,
	# absent-when-empty, passed VERBATIM (worker owns the shape). The F3
	# assembly half moved into board_health (DCR 019fd5fd9084): verbatim
	# pass-through + the panel-owned board_revision/preflight enrichment +
	# assembly-cache feed, see _attach_board_health.
	_pass_through_result_key(out, result, "span_outcomes")
	_pass_through_result_key(out, result, "island_deltas")
	# DRAFT reply (composed propose/reroute request) — labeled, cache-feed
	# skipped (UX4 station 3, A9).
	_attach_board_health(host, out, result, true)
	# Epoch UX1 station 11: a non-empty landing gets the compact legal-
	# successors sentence instead of the bare "landed" note above — the
	# reroute callers (_workspace_reroute) refresh this again with their own
	# more specific text, so this default only shows through for
	# minerva_pcb_workspace_propose itself.
	if not landed.is_empty():
		out["note"] = _next_steps("propose", {"count": landed.size()})
	# docket 019fce3ac3f5 item 2 + F6 (HITL-4): same summarised split as
	# apply_route_hints — additive, absent-when-empty so the shared shape
	# stays unchanged when the worker reports no capability notes.
	var emitter_summary: Dictionary = _emitter_notes_summary_from_result(result)
	if not emitter_summary.is_empty():
		out["emitter_notes_summary"] = emitter_summary
	# F4: additive, absent-when-empty — the overwhelming common case (no
	# merge happened, or the merge's absorbed tasks never conflicted).
	if not constraint_conflicts.is_empty():
		out["constraint_conflicts"] = constraint_conflicts
	var cross: Dictionary = await _cross_candidate_check(host, workspace, data)
	if not cross.is_empty():
		out["cross_candidate_check"] = cross
		if not (cross.get("findings", []) as Array).is_empty():
			out["note"] = str(out["note"]) \
				+ "; WARNING: the set-scoped check found findings across the live candidate set — see cross_candidate_check"
		elif cross.has("geometric_indeterminate"):
			out["note"] = str(out["note"]) \
				+ "; WARNING: the set-scoped check could not verify geometry — see cross_candidate_check"
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
		# OFC-3: listings answer "can this commit right now" — derive each
		# draft-ghost dependency's current status (satisfied/pending/
		# invalidated) from the live board + store.
		_stamp_draft_placement_status(rec, host)
		if include_geometry:
			rec["geometry"] = _candidate_geometry(c)
		out.append(rec)
	var tasks: Array = []
	for t in workspace.list_tasks():
		var trec: Dictionary = {
			"task_id": str(t.task_id), "net": str(t.net), "state": str(t.state),
			"span_scoped": bool(t.is_span_scoped()),
		}
		# SECONDARY (cold review) / Epoch UX1 station 8's constraint read
		# surface: additive-only, absent when the task carries no
		# routing_constraint — a pre-station task record (or any task nobody
		# ever gave a corridor) stays byte-identical.
		if t.is_constrained():
			trec["constrained"] = true
			trec["constraint_revision"] = int((t.routing_constraint as Dictionary).get("revision", 0))
		tasks.append(trec)
	var reply: Dictionary = {
		"candidates": out,
		"count": out.size(),
		"tasks": tasks,
		"open_task_ids": workspace.open_task_ids(),
		"active_candidate_id": str(workspace.active_candidate_id),
		"pinned_candidate_ids": workspace.pinned.keys(),
		"frozen_candidate_ids": workspace.frozen.keys(),
		"stale_candidate_ids": _stale_ids(workspace),
		"include_terminal": include_terminal,
	}
	# Epoch UX1 station 11: additive `note`, present only when this listing
	# actually shows a live candidate to act on — an empty workspace has
	# nothing to name a legal successor for.
	if out.size() > 0:
		reply["note"] = _next_steps("workspace_list", {"count": out.size()})
	return _ok(reply)


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
	_stamp_draft_placement_status(rec, host)  # OFC-3: derived ghost-dependency status
	if bool(args.get("include_geometry", false)):
		rec["geometry"] = _candidate_geometry(workspace.get_candidate(cid))
	var reply: Dictionary = {"active_candidate_id": cid, "candidate": rec}
	if workspace.has_method("findings_for_candidate"):
		reply["findings"] = workspace.findings_for_candidate(cid)
	return _ok(reply)


## THE deictic read (HITL-6b, docket 019fdf5579): whatever the human has
## selected on canvas, every kind in one call — components, traces, vias,
## zones, cutouts, route candidates (ghosts), and annotations — each entry
## enriched enough to answer "what's this?" without per-kind spelunking.
## Read-only; journals nothing. Empty selection is a SUCCESS with
## selection: [] — "nothing is selected" is an answer, not an error.
static func _get_selection(host, _args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("get_selection_state"):
		return _err("no live panel — selection is a canvas concept")
	var state: Dictionary = panel.get_selection_state()
	var data = _get_data(host)
	var workspace = _get_workspace(host)
	var entries: Array = []

	for comp_id in state.get("components", []):
		var entry: Dictionary = {"kind": "component", "id": str(comp_id)}
		if data != null and data.has_component(str(comp_id)):
			var comp = data.get_component(str(comp_id))
			entry["x"] = _mm(comp.position.x)
			entry["y"] = _mm(comp.position.y)
			entry["rotation"] = comp.rotation
			entry["value"] = str(comp.properties.get("value", "")) \
				if "properties" in comp else ""
		entries.append(entry)

	for trace_id in state.get("traces", []):
		var t_entry: Dictionary = {"kind": "trace", "id": str(trace_id)}
		if data != null and data.traces.has(str(trace_id)):
			var t = data.traces[str(trace_id)]
			t_entry["net"] = str(t.net_name)
		entries.append(t_entry)

	for via_id in state.get("vias", []):
		entries.append({"kind": "via", "id": str(via_id)})
	for zone_id in state.get("zones", []):
		entries.append({"kind": "zone", "id": str(zone_id)})
	for cutout_id in state.get("cutouts", []):
		entries.append({"kind": "cutout", "id": str(cutout_id)})

	# BOARD GRAPHICS — the canvas can select one, so "what have I got selected"
	# has to be able to say so. Described by the same summary the list/add verbs
	# report, so one graphic reads the same however it is reached.
	for graphic_id in state.get("board_graphics", []):
		var g_entry: Dictionary = {"kind": "board_graphic", "id": str(graphic_id)}
		if data != null and data.has_method("get_board_graphic"):
			var graphic: Dictionary = data.get_board_graphic(str(graphic_id))
			if not graphic.is_empty():
				g_entry.merge(PcbBoardGraphic.summary(graphic), true)
				g_entry["kind"] = "board_graphic"
				g_entry["id"] = str(graphic_id)
		entries.append(g_entry)

	# PADS — the pin-level half of the deixis. This is what makes "see these
	# pins? move them to the other side of U1S" answerable: the human picks pads
	# with the Pin Select tool, and THIS is where the caller reads which ones. One shape, defined once in pcb_pad_row and reused by
	# pin_info, the free-pins read and the move/rotate replies, so a pad
	# described by any of them is described the same way. `id` is the row's own
	# "REF.PIN" address — a pad has no minted id of its own.
	for pad_row in _PcbPadRowScript.rows_for_refs(data, state.get("pads", [])):
		var pad_entry: Dictionary = pad_row
		pad_entry["id"] = str(pad_entry.get("ref", ""))
		entries.append(pad_entry)

	for cid in state.get("candidates", []):
		if workspace == null:
			entries.append({"kind": "candidate", "id": str(cid)})
			continue
		var c = workspace.get_candidate(str(cid))
		if c == null:
			continue
		# The full candidate record — net, disposition, validation, quality
		# metrics, provenance — IS the "what's this" answer for a ghost.
		var rec: Dictionary = _candidate_record(workspace, c)
		_stamp_draft_placement_status(rec, host)  # OFC-3: "what's this" includes "can it commit"
		rec["kind"] = "candidate"
		rec["id"] = str(cid)
		# Source-intent context: the human-readable note the intent was
		# authored with, when its hint still carries one.
		if host != null and host.has_method("get_by_id"):
			var intents: Array = []
			for hid in rec.get("source_hint_ids", []):
				var ann: Dictionary = host.get_by_id(str(hid))
				if not ann.is_empty():
					var text: String = str((ann.get("kind_payload", {}) as Dictionary).get("text", ""))
					if not text.is_empty():
						intents.append(text)
			if not intents.is_empty():
				rec["source_intent_notes"] = intents
		entries.append(rec)

	# UX4 S4: staged drafts — the store entry (entity kind, author, note,
	# disposition) is the "what's this" answer for an area ghost, same idea
	# as the candidate record above. `id` is the CANONICAL payload id the
	# canvas selected; staged_id locates the store entry for the review verbs.
	var staged_store = panel.get_staged_store() if panel.has_method("get_staged_store") else null
	for eid in state.get("staged", []):
		var s_entry: Dictionary = {"kind": "staged", "id": str(eid)}
		if staged_store != null:
			var sid := str(staged_store.staged_id_for_entity(str(eid)))
			if not sid.is_empty():
				var se: Dictionary = staged_store.get_entry(sid)
				s_entry["staged_id"] = sid
				s_entry["entity_kind"] = str(se.get("kind", ""))
				s_entry["author"] = str(se.get("author", ""))
				s_entry["disposition"] = str(se.get("disposition", ""))
				var s_note := str(se.get("note", ""))
				if not s_note.is_empty():
					s_entry["note"] = s_note
		entries.append(s_entry)

	if host != null and host.has_method("get_selected_annotation_ids") \
			and host.has_method("get_by_id"):
		for aid in host.get_selected_annotation_ids():
			var ann: Dictionary = host.get_by_id(str(aid))
			if ann.is_empty():
				continue
			var a_entry: Dictionary = {
				"kind": "annotation", "id": str(aid),
				"annotation_kind": str(ann.get("kind", "")),
				"lifecycle": str(ann.get("lifecycle", "open")),
			}
			var summary: String = str(ann.get("summary", ""))
			if not summary.is_empty():
				a_entry["summary"] = summary
			var ref: String = str(ann.get("ref", ""))
			if not ref.is_empty():
				a_entry["ref"] = ref
			entries.append(a_entry)

	# The FOCUSED FINDING (Epoch UX3 station 4, K11's read half): clicking a
	# DRC witness on the canvas selects the owning candidate AND records
	# "cid#index" in the workspace's selected_finding_id — this is where that
	# focus becomes answerable. The entry is the STORED finding verbatim
	# (type, measured/required, closest/witness geometry, ref/pad/net_name,
	# subjects…) plus the ids that locate it, so "what is this marker?" gets
	# the whole verdict, not a summary. A dangling id (findings replaced by a
	# newer check since the click) contributes nothing rather than a guess.
	if workspace != null:
		var fid := str(workspace.selected_finding_id)
		if not fid.is_empty() and fid.contains("#") \
				and workspace.has_method("findings_for_candidate"):
			var fid_cid := fid.get_slice("#", 0)
			var fid_idx := int(fid.get_slice("#", 1))
			var stored: Array = workspace.findings_for_candidate(fid_cid)
			if fid_idx >= 0 and fid_idx < stored.size() and stored[fid_idx] is Dictionary:
				var f_entry: Dictionary = (stored[fid_idx] as Dictionary).duplicate(true)
				f_entry["kind"] = "finding"
				f_entry["id"] = fid
				f_entry["candidate_id"] = fid_cid
				entries.append(f_entry)

	var reply: Dictionary = {"selection": entries, "count": entries.size()}
	var active: String = str(state.get("active_candidate_id", ""))
	if not active.is_empty():
		reply["active_candidate_id"] = active
	if entries.is_empty():
		reply["note"] = "nothing is selected on the canvas"
	return _ok(reply)


static func _workspace_pin(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "pin")


static func _workspace_unpin(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "unpin")


# ── Epoch UX3 station 10 (docket 019fdf9101b5): LLM reverse parity ────────────

## THE MIRROR of minerva_pcb_get_selection: the LLM points AT an entity for
## the human — selection through the SAME canvas choke points a click uses,
## so the human sees exactly what a click would have lit. Deixis both ways.
static func _point(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("point_at_entity"):
		return _err("no live panel — pointing is a canvas act")
	var kind: String = str(args.get("kind", "")).strip_edges()
	var id: String = str(args.get("id", "")).strip_edges()
	if kind.is_empty() or id.is_empty():
		return _err("kind and id are required")
	var res: Dictionary = panel.point_at_entity(kind, id)
	if not bool(res.get("ok", false)):
		return {"success": false, "error": str(res.get("error", "point_failed")),
			"kind": kind, "id": id, "note": str(res.get("message", ""))}
	return _ok({"pointed": {"kind": kind, "id": id},
		"note": "the entity is now the canvas selection — the human sees it lit exactly as their own click would show it"})


## Micro hint-edit verbs (station 10b): move/insert/delete ONE bend of a
## route hint — thin wrappers over the SAME storage convention the canvas
## BendHandleEditTool lands (kind.bend_points/with_bend_points, one
## host.update_annotation revision per call), so the LLM stops wholesale-
## patching kind_payload. The superseded lock is respected BY NAME with the
## sanctioned exits, the same answer every other edit surface gives.
static func _hint_bend_edit(host, args: Dictionary, op: String) -> Dictionary:
	if host == null or not host.has_method("get_by_id") \
			or not host.has_method("update_annotation") or not host.has_method("get_registry"):
		return _err("PCB annotation host not available")
	var hint_id: String = str(args.get("hint_id", ""))
	if hint_id.is_empty():
		return _err("hint_id is required")
	var ann: Dictionary = host.get_by_id(hint_id)
	if ann.is_empty():
		return {"success": false, "error": "hint_not_found", "hint_id": hint_id}
	if str(ann.get("kind", "")) != "pcb_route_hint":
		return {"success": false, "error": "not_a_route_hint", "hint_id": hint_id,
			"kind": str(ann.get("kind", ""))}
	var kp: Dictionary = _dict_or_empty(ann.get("kind_payload"))
	if kp.has("waypoints_superseded_by_constraint_revision"):
		return {"success": false, "error": "waypoints_superseded", "hint_id": hint_id,
			"note": "this hint's waypoints are locked by a governing task constraint — minerva_pcb_hint_convert_to_detailed reclaims them, or steer the task via minerva_pcb_workspace_reroute_route"}
	var registry = host.get_registry()
	var kind = registry.get_annotation_kind(StringName("pcb_route_hint")) if registry != null else null
	if kind == null:
		return _err("pcb_route_hint kind not registered")

	var bends: Array = kind.bend_points(ann)
	match op:
		"move", "insert":
			if not args.has("x_mm") or not args.has("y_mm"):
				return _err("x_mm and y_mm are required")
	var point := Vector2(float(args.get("x_mm", 0.0)), float(args.get("y_mm", 0.0)))
	match op:
		"move":
			var idx_m: int = int(args.get("index", -1))
			if idx_m < 0 or idx_m >= bends.size():
				return {"success": false, "error": "bend_index_out_of_range",
					"hint_id": hint_id, "index": idx_m, "bend_count": bends.size()}
			bends[idx_m] = point
		"insert":
			# index optional: absent/oversized appends (the common "add one
			# more bend at the end" ask needs no arithmetic).
			var idx_i: int = int(args.get("index", bends.size()))
			idx_i = clampi(idx_i, 0, bends.size())
			bends.insert(idx_i, point)
		"delete":
			var idx_d: int = int(args.get("index", -1))
			if idx_d < 0 or idx_d >= bends.size():
				return {"success": false, "error": "bend_index_out_of_range",
					"hint_id": hint_id, "index": idx_d, "bend_count": bends.size()}
			bends.remove_at(idx_d)

	var new_ann: Dictionary = kind.with_bend_points(ann, bends)
	if not host.update_annotation(hint_id, new_ann):
		return {"success": false, "error": "update_refused", "hint_id": hint_id,
			"note": "the host refused the waypoint update — see the host's structured refusal for the governing lock"}
	var out_bends: Array = []
	for b in kind.bend_points(host.get_by_id(hint_id)):
		out_bends.append([_mm((b as Vector2).x), _mm((b as Vector2).y)])
	return _ok({"hint_id": hint_id, "op": op,
		"bend_count": out_bends.size(), "bends": out_bends})


## The MCP twin of the workflow dock's clear-by-author menu (station 10c) —
## the SAME host filter, so the two doorways cannot diverge: workflow-class
## annotations only, review annotations never touched.
static func _clear_hints_by_author(host, args: Dictionary) -> Dictionary:
	if host == null or not host.has_method("clear_annotations_by_author"):
		return _err("PCB annotation host not available")
	var author: String = str(args.get("author", "")).strip_edges()
	if not (author in ["human", "ai", "all"]):
		return _err("author must be one of: human, ai, all")
	var removed: int = int(host.clear_annotations_by_author(author))
	return _ok({"removed": removed, "author": author,
		"note": "route hints only (workflow class) — review annotations are never touched, same filter as the dock menu"})


## The Export YAML button's verb — PCBPanel.export_yaml_text owns it, and both
## doorways run that one implementation. UNGATED and non-writing by design:
## minerva_pcb_promote remains the only verb that puts bytes in a .yaml file,
## so this cannot make a board the gate refuses become the design of record.
static func _export_yaml(host, args: Dictionary) -> Dictionary:
	# A `path` reads as "write it there", which this verb deliberately cannot
	# do. Refusing by name beats ignoring the argument and returning a success
	# the caller reads as a file having been written.
	if str(args.get("path", "")).strip_edges() != "":
		return {"success": false, "error": "path_not_supported",
			"note": "this verb returns the document and writes nothing — use minerva_pcb_promote to write the canonical file (it gates first)"}
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("export_yaml_text"):
		return _err("no live panel — YAML export serializes the live board")
	var result: Dictionary = await panel.export_yaml_text()
	if not bool(result.get("success", false)):
		return result
	return _ok({
		"yaml": str(result.get("yaml", "")),
		"bytes": int(result.get("bytes", 0)),
		"draft": true,
		"note": "draft export — nothing was written and no gate ran; minerva_pcb_promote is the gated writer of the canonical file",
	})


## Epoch UX3 station 11 (K13): gated promotion — a thin tool over
## PCBPanel.promote, which owns the whole verb (gate → serialize → write →
## census delta). Both doorways (this tool, the Promote button) run the SAME
## implementation; neither can acknowledge through the gate.
static func _promote(host, args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("promote"):
		return _err("no live panel — promotion serializes the live board")
	# allow_copper_regression (UX4 station 9): the deliberate override for the
	# panel's regression guard — same arg the button's confirm dialog passes.
	return await panel.promote(str(args.get("path", "")),
		bool(args.get("allow_copper_regression", false)))


## OFC-4: the promote gate's read-only twin — PCBPanel.board_check owns the
## verb (same stripped live board, same worker verdict, no write, no gate).
static func _board_check(host, _args: Dictionary) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("board_check"):
		return _err("no live panel — the census reads the live board")
	return await panel.board_check()


static func _workspace_freeze(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "freeze")


static func _workspace_unfreeze(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "unfreeze")


static func _workspace_reject(host, args: Dictionary) -> Dictionary:
	return _workspace_disposition_verb(host, args, "reject")


## COMMIT — INV-1. A thin tool over RoutingWorkspace.commit, which owns the whole
## transaction (board writes + disposition + the paired history snapshot). The
## tool deliberately adds NO board mutation of its own: a second writer would be
## a second thing to undo.
## ── COMMIT-time assembly acknowledgment gate (DCR 019fd5fd9084 item 2) ───────
##
## The design line: advisory-grade approximations NEVER hard-block — but KNOWN
## findings at the commit point require explicit acknowledgment. Committing is
## the one moment ghost geometry becomes real copper, and HITL-4's root cause
## was copper routed through a placement the owner had already ruled broken
## with no automated signal firing (llm-ergonomics F3/F9: "placement questions
## settle before copper"). Decision table, evaluated against the PANEL's
## assembly-state cache (fed by board_health pass-throughs, load-time checks
## and placement-op refreshes — see _attach_board_health/_run_assembly_check):
##
##   cache state                     │ gate behaviour
##   ────────────────────────────────┼──────────────────────────────────────────
##   absent (never fed/invalidated)  │ WARN: reply carries assembly_note
##                                   │ {status:"indeterminate"} — never blocks.
##   stale (revision mismatch)       │ WARN: same — a verdict about a different
##                                   │ board must not gate this one.
##   fresh, status "indeterminate"   │ WARN: same — "could not check" is not a
##                                   │ finding; indeterminate warns.
##   fresh, status "pass"            │ silent — nothing to say.
##   fresh, status "findings", NO    │ silent — the findings don't touch this
##     component intersection        │ candidate's endpoints; not its blocker.
##   fresh, status "findings", ≥1    │ REFUSE "placement_blocker_unacknowledged"
##     finding's components intersect│ listing blocking_findings — UNLESS
##     the candidate's endpoint      │ args.acknowledge_placement == true, in
##     components                    │ which case the commit proceeds and the
##                                   │ reply records acknowledged_placement_
##                                   │ findings.
##
## BATCH: the gate runs per-member in PREFLIGHT (before commit_batch lays any
## copper) — one unacknowledged blocked member refuses the WHOLE batch, the
## existing all-or-nothing convention ("ALL validation precedes ALL mutation").


## Classify the panel's cached assembly state against the live board revision.
## Returns {mode:"absent"|"stale"|"indeterminate"|"pass"|"findings",
## assembly?:Dictionary, cached_revision?:int}.
static func _assembly_gate(host, data) -> Dictionary:
	var panel = _get_panel(host)
	if panel == null or not panel.has_method("get_assembly_state"):
		return {"mode": "absent"}
	var cached: Dictionary = panel.get_assembly_state()
	if cached.is_empty():
		return {"mode": "absent"}
	var revision: int = int(data.board_revision) if data != null else 0
	var cached_revision: int = int(cached.get("board_revision", -1))
	if cached_revision != revision:
		return {"mode": "stale", "cached_revision": cached_revision}
	var assembly: Dictionary = _dict_or_empty(cached.get("assembly"))
	var status := str(assembly.get("status", ""))
	if status == "findings":
		return {"mode": "findings", "assembly": assembly}
	if status == "pass":
		return {"mode": "pass", "assembly": assembly}
	# "indeterminate" and any unrecognised status both read as indeterminate —
	# the same fail-closed vocabulary rule _geometric_status_suffix pins.
	return {"mode": "indeterminate", "assembly": assembly}


## The advisory assembly_note for a non-blocking gate outcome, or {} when the
## gate has nothing to say (pass / findings — findings either block or are not
## this candidate's business). Indeterminate WARNS, findings GATE.
static func _assembly_gate_note(gate: Dictionary) -> Dictionary:
	match str(gate.get("mode", "")):
		"absent":
			return {"status": "indeterminate",
				"reason": "no assembly state cached — a load, propose, or placement op refreshes it"}
		"stale":
			return {"status": "indeterminate",
				"reason": "cached assembly state is stale (computed at board_revision %d) — placement changed since; a load, propose, or placement op refreshes it" \
					% int(gate.get("cached_revision", -1))}
		"indeterminate":
			var assembly: Dictionary = _dict_or_empty(gate.get("assembly"))
			return {"status": "indeterminate",
				"reason": str(assembly.get("error", assembly.get("reason", "assembly check could not run")))}
	return {}


## The COMPONENT REFS a candidate's route terminates on, for the gate's
## intersection test. Three sources, most-authoritative first:
##   1. the candidate's own endpoints (copied from its task at ingest —
##      {"component","pin","position"} open dicts, RouteTask.endpoints shape);
##   2. its task's endpoints (a candidate ingested before endpoints were copied,
##      or a sidecar round-trip that dropped them);
##   3. FALLBACK: parse the component out of the source hints' own pin refs
##      (kind_payload.source_pins/dest_pins, "U1.3" → "U1") via host.get_by_id.
## Empty result ⇒ the gate cannot attribute findings to this candidate and
## stays silent (never guesses an intersection).
static func _candidate_endpoint_components(host, workspace, c) -> Array:
	var comps: Array = []
	if c == null:
		return comps
	var sources: Array = c.endpoints if (c.endpoints as Array).size() > 0 else []
	if sources.is_empty() and workspace != null and workspace.has_method("get_task"):
		var task = workspace.get_task(str(c.task_id))
		if task != null and (task.endpoints as Array).size() > 0:
			sources = task.endpoints
	for e in sources:
		if e is Dictionary:
			var comp := str((e as Dictionary).get("component", ""))
			if not comp.is_empty() and not (comp in comps):
				comps.append(comp)
	if comps.is_empty() and host != null and host.has_method("get_by_id"):
		for hid in c.source_hint_ids:
			var ann: Dictionary = host.get_by_id(str(hid))
			if ann.is_empty():
				continue
			var kp: Dictionary = _dict_or_empty(ann.get("kind_payload"))
			for key in ["source_pins", "dest_pins"]:
				var pins: Array = kp.get(key, []) if kp.get(key, []) is Array else []
				for pin_ref in pins:
					var ref := str(pin_ref)
					var dot := ref.find(".")
					if dot > 0:
						var comp2 := ref.substr(0, dot)
						if not (comp2 in comps):
							comps.append(comp2)
	return comps


## The subset of a fresh "findings" assembly state whose findings touch any of
## `comps` (finding.components ∩ comps ≠ ∅ — the worker contract's finding
## shape names the colliding components). Empty when comps is empty: an
## unattributable candidate is never blocked on a guess.
static func _blocking_findings_for(assembly: Dictionary, comps: Array) -> Array:
	var out: Array = []
	if comps.is_empty():
		return out
	var findings: Array = assembly.get("findings", []) \
		if assembly.get("findings", []) is Array else []
	for f in findings:
		if not (f is Dictionary):
			continue
		var f_comps: Array = (f as Dictionary).get("components", []) \
			if (f as Dictionary).get("components", []) is Array else []
		for fc in f_comps:
			if str(fc) in comps:
				out.append(f)
				break
	return out


const _PLACEMENT_BLOCKER_NOTE := "the panel's FRESH assembly state carries findings touching this candidate's endpoint components — placement questions settle before copper (DCR 019fd5fd9084). Re-place the parts and re-check, or pass acknowledge_placement:true to commit anyway (the reply then records acknowledged_placement_findings)"


static func _workspace_commit(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]

	# DCR 019fd5fd9084 item 2: classify the cached assembly state ONCE, up
	# front — both the single and batch paths below consult it in preflight
	# (before any copper) and stamp the advisory note on success. SYNCHRONOUS
	# by design: the gate reads the cache, it never runs the check itself, so
	# commit keeps its no-worker-hop contract.
	var assembly_gate: Dictionary = _assembly_gate(host, data)
	var assembly_note: Dictionary = _assembly_gate_note(assembly_gate)
	var acknowledge: bool = bool(args.get("acknowledge_placement", false))

	# BATCH FORM (docket 019fd0ab6dd2): candidate_ids commits several
	# candidates as ONE undoable step through RoutingWorkspace.commit_batch —
	# one history entry, one revision bump, and every member reporting its
	# PRE-batch verdict instead of the staleness a batch-mate's own commit
	# caused. Exactly one of candidate_id / candidate_ids is required, judged
	# by ARGUMENT PRESENCE, not by normalized emptiness (Codex review P2):
	# candidate_ids:[] must get the batch form's own named error, and
	# candidate_id alongside an empty candidate_ids is still the ambiguous ask
	# — refusing beats guessing which form the caller meant.
	if args.has("candidate_ids") and args.has("candidate_id"):
		return _err("pass candidate_id OR candidate_ids, not both")
	if args.has("candidate_ids"):
		var batch_ids: Array = _string_list(args.get("candidate_ids", []))
		if batch_ids.is_empty():
			return _err("candidate_ids must name at least one candidate (empty batch)")
		# OFC-3 DRAFT-PLACEMENT GATE, per member, all-or-nothing, and AHEAD of
		# the assembly gate below on purpose: that one is advisory (findings a
		# human may acknowledge past); this one is factual — a member's copper
		# lands at a ghost pose that hasn't happened, and no acknowledge flag
		# exists for it. Ceremony ruling pending on 019ff9428d80; option (a)
		# refuse-until-accepted is the fail-safe default built here.
		var draft_blocked: Array = []
		for bid in batch_ids:
			var member_block: Dictionary = _draft_placement_block(
				host, workspace.get_candidate(str(bid)))
			if not member_block.is_empty():
				draft_blocked.append(member_block)
		if not draft_blocked.is_empty():
			return {"success": false, "error": "draft_placement_blocked",
				"blocked_members": draft_blocked,
				"note": "batch refused whole (all-or-nothing): member candidate(s) were routed against live placement ghost(s) — accept those moves first, or reject them and reroute; see blocked_members"}
		# PLACEMENT GATE, per-member, in PREFLIGHT (DCR 019fd5fd9084 item 2 —
		# before commit_batch lays ANY copper): one unacknowledged blocked
		# member refuses the WHOLE batch, the existing all-or-nothing
		# convention. A member id the workspace doesn't know is skipped here —
		# commit_batch's own validation refuses it by name, and this gate
		# never pre-empts a more specific refusal.
		var batch_acknowledged: Array = []
		if str(assembly_gate.get("mode", "")) == "findings":
			var blocked: Array = []
			for bid in batch_ids:
				var member = workspace.get_candidate(str(bid))
				if member == null:
					continue
				var member_blocking: Array = _blocking_findings_for(
					assembly_gate.get("assembly", {}),
					_candidate_endpoint_components(host, workspace, member))
				if not member_blocking.is_empty():
					blocked.append({"candidate_id": str(bid),
						"blocking_findings": member_blocking})
			if not blocked.is_empty():
				if not acknowledge:
					return {
						"success": false,
						"error": "placement_blocker_unacknowledged",
						"blocked_members": blocked,
						"note": "batch refused whole (all-or-nothing): " + _PLACEMENT_BLOCKER_NOTE,
					}
				batch_acknowledged = blocked
		var batch: Dictionary = workspace.commit_batch(batch_ids, data)
		if not bool(batch.get("ok", false)):
			return {
				"success": false,
				"error": str(batch.get("error", "commit_failed")),
				"candidate_id": str(batch.get("candidate_id", "")),
				"note": str(batch.get("message", "")),
			}
		# Same MF-2 hint-lifecycle closure the single path performs below, per
		# member (see that comment for the full contract).
		var recs: Array = []
		for r in batch.get("results", []):
			for hid in (r as Dictionary).get("consumed_hint_ids", []):
				_set_hint_lifecycle(host, str(hid), "applied")
			var member_rec: Dictionary = _candidate_record(workspace,
				workspace.get_candidate(str((r as Dictionary).get("candidate_id", ""))))
			_stamp_draft_placement_status(member_rec, host)  # OFC-3: post-commit, dependencies read satisfied
			recs.append(member_rec)
		var breply: Dictionary = batch.duplicate(true)
		breply.erase("ok")
		breply["candidates"] = recs
		breply["stale_candidate_ids"] = _stale_ids(workspace)
		breply["undo_note"] = "one board history step: Ctrl+Z (or PCBData.undo) removes EVERY batch member's copper AND returns each candidate to its pre-commit disposition — the source hints reopen the next time any workspace tool runs (see _reconcile_hint_lifecycle), not synchronously with this undo"
		# Epoch UX1 station 11: additive alongside undo_note (a different
		# question — "what next", not "how to take it back").
		breply["note"] = _next_steps("commit", {})
		# DCR 019fd5fd9084 item 2, additive + absent-when-empty: the advisory
		# note for a non-blocking gate state, and the acknowledged-findings
		# record when acknowledge_placement carried a commit through blockers.
		if not assembly_note.is_empty():
			breply["assembly_note"] = assembly_note
		if not batch_acknowledged.is_empty():
			breply["acknowledged_placement_findings"] = batch_acknowledged
		return _ok(breply)

	var cid: String = str(args.get("candidate_id", ""))
	if cid.is_empty():
		return _err("candidate_id is required")
	# OFC-3 DRAFT-PLACEMENT GATE, single form — same position and same
	# no-acknowledge contract as the batch gate above.
	var draft_block: Dictionary = _draft_placement_block(host, workspace.get_candidate(cid))
	if not draft_block.is_empty():
		return draft_block
	# PLACEMENT GATE (DCR 019fd5fd9084 item 2), single form — same preflight
	# position as the batch gate above: before workspace.commit lays copper.
	# An unknown cid is skipped (null candidate → no endpoints → no blocking);
	# workspace.commit refuses it by name just below.
	var acknowledged_findings: Array = []
	if str(assembly_gate.get("mode", "")) == "findings":
		var blocking: Array = _blocking_findings_for(
			assembly_gate.get("assembly", {}),
			_candidate_endpoint_components(host, workspace, workspace.get_candidate(cid)))
		if not blocking.is_empty():
			if not acknowledge:
				return {
					"success": false,
					"error": "placement_blocker_unacknowledged",
					"candidate_id": cid,
					"blocking_findings": blocking,
					"note": _PLACEMENT_BLOCKER_NOTE,
				}
			acknowledged_findings = blocking
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
	_stamp_draft_placement_status(reply["candidate"], host)  # OFC-3
	reply["stale_candidate_ids"] = _stale_ids(workspace)
	reply["undo_note"] = "one board history step: Ctrl+Z (or PCBData.undo) removes this copper AND returns the candidate to its pre-commit disposition — the source hint(s) reopen the next time any workspace tool runs (see _reconcile_hint_lifecycle), not synchronously with this undo"
	# Epoch UX1 station 11: additive alongside undo_note (a different
	# question — "what next", not "how to take it back").
	reply["note"] = _next_steps("commit", {})
	# DCR 019fd5fd9084 item 2, additive + absent-when-empty — see the batch
	# path's twin stamp above for the contract.
	if not assembly_note.is_empty():
		reply["assembly_note"] = assembly_note
	if not acknowledged_findings.is_empty():
		reply["acknowledged_placement_findings"] = acknowledged_findings
	return _ok(reply)


## TRY-AGAIN over the WHOLE route, with optional TASK STEERING beforehand
## (Epoch UX1 station 9, DCR 019fd095e694 — docket 019fd057ea0b comment 1028's
## "surface the choice at REROUTE time" resolution). Runs the router again
## scoped to the candidate's own source hints and lands a NEW generation for
## the same task — see _workspace_reroute's own doc for that half, unchanged.
##
## THE ROUTER IS RUN FIRST (inside _workspace_reroute below), then the prior is
## retired. Retiring first would mean a router failure left the task with no
## answer at all — the old geometry gone and nothing in its place. A PROPOSED
## prior is superseded by the ingest itself; only a PINNED prior needs the
## explicit targeted supersede, which is exactly the consent the workspace's
## ingest policy demands (acting on THIS candidate) and not the batch consent
## it refuses.
##
## Optional STEERING args, mutually exclusive by ARGUMENT PRESENCE (never
## guessed from truthiness — same convention this file uses throughout, e.g.
## _workspace_commit's candidate_id/candidate_ids check):
##   corridor                     Array of {x_mm,y_mm} — REPLACES the task's
##                                 routing_constraint with this corridor.
##   preserve_shape_as_corridor   bool — true DERIVES the new corridor from the
##                                 candidate's CURRENT geometry polyline, read
##                                 BEFORE this same call reroutes it into
##                                 something else. A caller passing `false`
##                                 alongside neither key present is a plain
##                                 reroute — this is the one steering key whose
##                                 own VALUE (not just presence) decides
##                                 whether steering happens at all, because
##                                 "false" has an honest meaning ("reroute
##                                 fresh") that "corridor:[]" does not.
##   clear_constraint             bool — true REMOVES the task's
##                                 routing_constraint entirely (Epoch UX2
##                                 station 2): the reroute this call performs,
##                                 and every propose after it, runs unguided.
##                                 Mutually exclusive with corridor /
##                                 preserve_shape_as_corridor. Refuses
##                                 `no_constraint_to_clear` by name on an
##                                 unconstrained task. The owner hint's
##                                 supersession marker is stripped through the
##                                 sanctioned release, so its own waypoints
##                                 (if any) are live authority again. Reports
##                                 cleared_constraint_revision on every reply.
##   expected_constraint_revision int — optimistic concurrency on the task's
##                                 CURRENT constraint revision (0 for an
##                                 unconstrained task). A mismatch refuses
##                                 `constraint_revision_conflict` naming the
##                                 actual revision and steers/clears NOTHING.
##                                 Read only when a steering arg above (or
##                                 clear_constraint) is also acting — a bare
##                                 expected_constraint_revision with nothing
##                                 to guard is ignored.
##
## DURABILITY INVARIANT (comment 1028: "steering durability does not depend on
## obtaining a candidate"). When a steering arg IS acting, the task's
## routing_constraint is written AFTER every refusable precondition has
## passed (F1, cold review — see below) but still BEFORE the router runs. If
## the router leg THEN fails — worker unavailable, or the pinned-prior
## supersede/ingest step that follows it — the bumped constraint STANDS. The
## operator's steering decision is not undone by a routing failure, because
## it was never conditioned on one succeeding: a later re-propose or reroute
## still sees the fresh corridor even if THIS call's router leg never landed
## a candidate. And (F1's own follow-up) that failure reply now SAYS so —
## `steered:true` + `constraint_revision` are stamped onto ANY failure this
## function returns once steering has landed, so the bump is REPORTED, not
## just durable.
##
## F1 (cold review) reordered this function: ALL refusable preconditions —
## both _workspace_reroute's own (candidate exists, disposition can reach
## superseded, source hints present/resolvable) and steering's own (task
## exists, expected_constraint_revision match, corridor present/valid, F3's
## multi_span_task) — are checked FIRST, via the shared _reroute_precheck,
## before ANY mutation. Previously steering wrote the constraint BEFORE
## _workspace_reroute's own checks ran, so a candidate that could never
## legally reach "superseded" (already committed/rejected/superseded) still
## took a silent constraint-revision bump on its way to a refusal it was
## always going to hit.
static func _workspace_reroute_route(host, args: Dictionary) -> Dictionary:
	var has_corridor: bool = args.has("corridor")
	var has_preserve_key: bool = args.has("preserve_shape_as_corridor")
	if has_corridor and has_preserve_key:
		return {
			"success": false, "error": "corridor_args_conflict",
			"note": "pass corridor OR preserve_shape_as_corridor, not both — they are two different ways of stating the task's new routing_constraint",
		}
	var preserve: bool = has_preserve_key and bool(args.get("preserve_shape_as_corridor", false))
	var wants_steer: bool = has_corridor or preserve
	# clear_constraint (Epoch UX2 station 2, docket 019fde361cf0 — HITL-5: a
	# corridor could be REPLACED but never REMOVED, and the
	# constraint_stale_candidate refusal literally advised a verb that did not
	# exist). A clear IS a steer in the opposite direction: "route this
	# unguided from now on" — same precondition discipline, same
	# expected_constraint_revision guard, same durability invariant (the clear
	# lands before the router and survives a router failure).
	var wants_clear: bool = args.has("clear_constraint") and bool(args.get("clear_constraint", false))
	if wants_clear and (has_corridor or has_preserve_key):
		return {
			"success": false, "error": "corridor_args_conflict",
			"note": "clear_constraint removes the task's routing_constraint — it cannot be combined with corridor/preserve_shape_as_corridor, which write a new one",
		}
	# width_mm (Epoch UX2 station 3, docket 019fde363162): review-time width
	# change — lands on the candidate's source hints' kind_payload (the same
	# durable channel add_route_intent writes and _width_from_hints reads)
	# before the router leg reroutes. Validated HERE, with every other
	# args-shape refusal, so a bad width refuses before any steer/clear
	# mutation lands (precondition-first, F1's ordering discipline).
	var wants_width: bool = args.has("width_mm")
	var width_val: float = 0.0
	if wants_width:
		var raw_width: Variant = args.get("width_mm")
		if not (raw_width is float or raw_width is int) or float(raw_width) <= 0.0:
			return {
				"success": false, "error": "invalid_width",
				"note": "width_mm must be a positive number (trace width in mm) — omit the key entirely to keep each hint's current width",
			}
		width_val = float(raw_width)

	var pre: Dictionary = _reroute_precheck(host, args)
	if not bool(pre.get("ok", false)):
		return pre.get("reply")

	# DCR 01a022ab356c leg C (fix cold review f3): corridor steering is
	# hint-keyed end to end (owner_hint_id, the {hint_id: …} wire map, the
	# worker's per-hint application) — a hint-less fallback run can never
	# consume the constraint a steer would write, so writing one here would
	# be silently ignored AND leave the landed generation commit-gated
	# stale. Refuse by name. clear_constraint stays legal — it is the
	# recovery path for exactly that stale gate.
	if bool(pre.get("hintless", false)) and wants_steer:
		return {
			"success": false, "error": "steering_unavailable_hintless",
			"candidate_id": str(pre["cid"]),
			"note": "corridor steering is hint-keyed and this candidate has no live source hints — a hint-less fallback run cannot consume a routing_constraint. Author a fresh intent (minerva_pcb_add_route_intent, or spans on workspace_propose) to steer this span; clear_constraint remains available to release a stale one.",
		}

	var cleared_revision: int = 0
	if wants_clear:
		var clear: Dictionary = _clear_task_constraint_before_reroute(host, args, pre)
		if not bool(clear.get("ok", false)):
			return clear.get("reply")
		cleared_revision = int(clear.get("cleared_revision", 0))
	elif wants_steer:
		var steer: Dictionary = _steer_task_before_reroute(host, args, preserve, pre)
		if not bool(steer.get("ok", false)):
			return steer.get("reply")

	if wants_width:
		# Same write-before-router durability as steer/clear: the width intent
		# lands on the durable hints whether or not the router leg succeeds.
		# Applied to EVERY source hint — a candidate answering merged spans is
		# one route, and "make this route width X" means the whole route (the
		# per-hint refusal dance is exactly the ergonomic failure this station
		# removes). The router leg re-reads annotations fresh, so this call's
		# own reroute already routes at the new width (width_source:"hint").
		for hid in pre["hint_ids"]:
			_set_hint_width(host, str(hid), width_val)

	var reply: Dictionary = await _workspace_reroute(host, args, {}, pre)
	if wants_width:
		reply["width_mm"] = width_val
	if wants_steer and not bool(reply.get("success", true)):
		# F1: the bump above already landed durably by this point (every
		# remaining failure mode — worker unavailable, pinned-supersede,
		# ingest — happens strictly AFTER the write) — say so on the reply
		# rather than leaving the caller to infer it. `constraint_revision`
		# is the revision AFTER this call's steer: a retry that wants to
		# steer again passes THIS number as expected_constraint_revision, not
		# whatever it read before making this call.
		var task = pre["workspace"].get_task(str(pre["candidate"].task_id))
		reply["steered"] = true
		reply["constraint_revision"] = int(task.routing_constraint.get("revision", 0)) \
			if task != null and task.is_constrained() else 0
	if wants_clear:
		# Same durability-reporting rule as the steer half above, on EVERY
		# reply (success or failure): the constraint is gone whether or not
		# the router leg landed a fresh candidate.
		reply["cleared_constraint"] = true
		reply["cleared_constraint_revision"] = cleared_revision
		reply["constraint_revision"] = 0
	return reply


## The steering half of _workspace_reroute_route, run AFTER every reroute-side
## refusable precondition has already passed (`pre` — the _reroute_precheck
## result the caller ran first) and to completion BEFORE the router (see that
## function's DURABILITY INVARIANT doc). Returns {"ok":true} once the task's
## routing_constraint has been written, or {"ok":false,"reply":<named
## refusal>} — every error this feature can produce is owned here, and
## _workspace_reroute_route hands the refusal back unchanged.
static func _steer_task_before_reroute(host, args: Dictionary, preserve: bool, pre: Dictionary) -> Dictionary:
	var workspace = pre["workspace"]
	var data = pre["data"]
	var c = pre["candidate"]
	var cid: String = str(pre["cid"])

	var task = workspace.get_task(str(c.task_id))
	if task == null:
		return {"ok": false, "reply": {
			"success": false, "error": "task_not_found", "candidate_id": cid,
			"task_id": str(c.task_id),
			"note": "this candidate's task no longer exists in the workspace — there is nothing to steer",
		}}

	var actual_revision: int = int((task.routing_constraint as Dictionary).get("revision", 0)) \
		if task.is_constrained() else 0
	if args.has("expected_constraint_revision"):
		var expected: int = int(args.get("expected_constraint_revision"))
		if expected != actual_revision:
			return {"ok": false, "reply": {
				"success": false, "error": "constraint_revision_conflict",
				"candidate_id": cid, "task_id": str(c.task_id),
				"expected_constraint_revision": expected,
				"actual_constraint_revision": actual_revision,
				"note": "the task's routing_constraint has moved since you read it — re-read the current revision (minerva_pcb_workspace_list reports constraint_revision on constrained tasks) before steering it again",
			}}

	# F3 (cold review): this task's own hint attribution. A SINGLETON key
	# ("net|hint_id") is the only shape with an unambiguous owner; a MERGED
	# multi-hint task (H3-1 absorption, "net|hidA,hidB") has no single hint
	# the constraint this call is about to write could honestly be
	# attributed to.
	var task_hints: Array = workspace.task_hint_ids(str(task.task_id))
	var owner_hint_id: String = str(task_hints[0]) if task_hints.size() == 1 else ""

	var corridor_points: Array
	if preserve:
		# F3: preserve_shape_as_corridor DERIVES a corridor and attributes it
		# to this task — refuse rather than derive-and-misattribute (the
		# duplicated-authority hazard this follow-up closes) when there is no
		# single hint to own it.
		if task_hints.size() != 1:
			return {"ok": false, "reply": {
				"success": false, "error": "multi_span_task", "candidate_id": cid,
				"task_id": str(c.task_id), "hint_ids": task_hints,
				"note": "preserve_shape_as_corridor needs a task whose key names exactly one hint, so the derived corridor has an unambiguous owner — this task names %d (%s); steer with an explicit `corridor` array instead, or reroute the individual hint's own task" % [task_hints.size(), ", ".join(task_hints)],
			}}
		var chained: Dictionary = _corridor_from_candidate_geometry(c)
		if not bool(chained.get("ok", false)):
			var runs: int = int(chained.get("runs", 0))
			if runs <= 1:
				return {"ok": false, "reply": {
					"success": false, "error": "no_geometry_to_preserve", "candidate_id": cid,
					"note": "this candidate has no segment geometry to derive a corridor from",
				}}
			# F6 (cold review): this candidate's segments do not
			# endpoint-chain into ONE continuous path — the old
			# implementation concatenated every disconnected run anyway,
			# fabricating a jump across the gap the candidate's own geometry
			# never drew.
			return {"ok": false, "reply": {
				"success": false, "error": "no_single_path", "candidate_id": cid,
				"runs": runs,
				"note": "this candidate's geometry is %d disconnected runs, not one continuous path — preserve_shape_as_corridor needs a single chainable polyline" % runs,
			}}
		corridor_points = chained["points"]
	else:
		# V2 (Codex 1047): the SAME single-owner requirement as the preserve
		# branch above — an explicit corridor steered onto a MERGED multi-hint
		# task would write owner_hint_id:"" (there is no single hint to
		# attribute it to), and _task_constraints_for_hints deliberately emits
		# an ownerless constraint for NO hint. That is a successful-looking
		# durable NO-OP: the revision bumps, the reply says steered, and no
		# future propose is influenced by it. Refuse BEFORE mutation instead.
		if task_hints.size() != 1:
			return {"ok": false, "reply": {
				"success": false, "error": "multi_span_task", "candidate_id": cid,
				"task_id": str(c.task_id), "hint_ids": task_hints,
				"note": "steering writes an owner-attributed constraint, and this task's key names %d hints (%s) — no single owner exists, so the corridor would durably steer NOTHING; steer the individual hint's own task instead" % [task_hints.size(), ", ".join(task_hints)],
			}}
		var parsed: Variant = _parse_route_intent_corridor(args.get("corridor"))
		if parsed == null:
			return {"ok": false, "reply": _err("corridor must be an array of {x_mm, y_mm} points")}
		corridor_points = parsed
		if corridor_points.is_empty():
			# F12 (cold review): named refusal, not prose-as-code — the
			# reroute path's own copy of the same defect
			# minerva_pcb_add_route_intent's corridor:[] check already had
			# (that one is a DIFFERENT call site, out of this fence).
			return {"ok": false, "reply": {
				"success": false, "error": "corridor_present_but_empty", "candidate_id": cid,
				"note": "corridor was present but carried no points — omit the key entirely for \"no corridor\" instead",
			}}

	var preserved_layer: String = str(task.routing_constraint.get("preferred_layer", "")) \
		if task.is_constrained() else ""
	# Monotonic across clears (UX2 station 2 cold review F2): resume above the
	# floor a clear left behind, so a pre-clear candidate's stamped revision
	# can never collide with a fresh constraint's.
	var floor_rev: int = int(task.constraint_revision_floor) \
		if "constraint_revision_floor" in task else 0
	var new_revision: int = maxi(actual_revision, floor_rev) + 1
	# DURABILITY INVARIANT (docket 019fd057ea0b comment 1028) — see
	# _workspace_reroute_route's own doc for the full rationale. Written NOW,
	# before that caller ever reaches the router: a routing failure below must
	# not undo this steering decision, because the decision was never
	# conditioned on the router succeeding.
	task.routing_constraint = {
		"corridor_points": corridor_points,
		"preferred_layer": preserved_layer,
		"revision": new_revision,
		"authored_by": "ai",
		"base_board_revision": int(data.board_revision) if data != null else 0,
		"owner_hint_id": owner_hint_id,
	}
	# F2 (cold review): duplicated-authority guard for legacy waypoints — see
	# _stamp_waypoints_superseded's own doc for the full contract, including
	# the deferred render/edit-refusal implications note.
	_stamp_waypoints_superseded(host, owner_hint_id, new_revision)
	return {"ok": true}


## The clearing half of _workspace_reroute_route (Epoch UX2 station 2, docket
## 019fde361cf0): remove the task's routing_constraint entirely so the reroute
## that follows — and every propose after it — runs unguided. Mirrors
## _steer_task_before_reroute's discipline exactly (same task_not_found /
## constraint_revision_conflict refusal shapes, same run-before-the-router
## durability), and _hint_convert_to_detailed's precedent for what "cleared"
## means: task.routing_constraint = {} (the workspace store is authoritative),
## then the annotation-side supersession marker is stripped through the
## host's sanctioned bookkeeping path — the SAME marker-without-constraint
## repair reconcile_superseded_waypoint_state performs at load, done
## synchronously here so THIS call's own router leg already routes the hint's
## waypoints as live authority (an intent-shape hint with no waypoints simply
## routes unguided).
##
## Returns {"ok":true, "cleared_revision":N} or {"ok":false, "reply":<named
## refusal>}. A task with NO constraint refuses `no_constraint_to_clear` by
## name rather than no-op-succeeding: the caller believed a constraint
## governed this task, and silently "clearing" nothing would confirm a false
## model (minerva_pcb_workspace_list reports constraint_revision to re-read).
static func _clear_task_constraint_before_reroute(host, args: Dictionary, pre: Dictionary) -> Dictionary:
	var workspace = pre["workspace"]
	var c = pre["candidate"]
	var cid: String = str(pre["cid"])

	var task = workspace.get_task(str(c.task_id))
	if task == null:
		return {"ok": false, "reply": {
			"success": false, "error": "task_not_found", "candidate_id": cid,
			"task_id": str(c.task_id),
			"note": "this candidate's task no longer exists in the workspace — there is nothing to clear",
		}}

	var actual_revision: int = int((task.routing_constraint as Dictionary).get("revision", 0)) \
		if task.is_constrained() else 0
	if args.has("expected_constraint_revision"):
		var expected: int = int(args.get("expected_constraint_revision"))
		if expected != actual_revision:
			return {"ok": false, "reply": {
				"success": false, "error": "constraint_revision_conflict",
				"candidate_id": cid, "task_id": str(c.task_id),
				"expected_constraint_revision": expected,
				"actual_constraint_revision": actual_revision,
				"note": "the task's routing_constraint has moved since you read it — re-read the current revision (minerva_pcb_workspace_list reports constraint_revision on constrained tasks) before clearing it",
			}}

	if not task.is_constrained():
		return {"ok": false, "reply": {
			"success": false, "error": "no_constraint_to_clear",
			"candidate_id": cid, "task_id": str(c.task_id),
			"note": "this candidate's task carries no routing_constraint — a plain reroute (no steering args) already routes it unguided",
		}}

	var owner_hint_id: String = str((task.routing_constraint as Dictionary).get("owner_hint_id", ""))
	# Authority store first (the same write order every constraint writer
	# uses: constraint, then marker) — clearing is the {} write
	# _hint_convert_to_detailed established as the canonical cleared state.
	# The revision floor survives the {} (see pcb_route_task.gd's field doc):
	# a later steer resumes ABOVE the cleared revision, never reusing it.
	if "constraint_revision_floor" in task:
		task.constraint_revision_floor = maxi(int(task.constraint_revision_floor), actual_revision)
	task.routing_constraint = {}
	# Derived store second: strip the now-orphaned supersession marker through
	# the sanctioned release (NEVER plain update_annotation — the H2-1
	# re-injection guard would put it straight back). Best-effort by the same
	# rule as _stamp_waypoints_superseded: a host without the method degrades
	# to the lazy load-time reconcile.
	if not owner_hint_id.is_empty() and host != null \
			and host.has_method("reconcile_strip_superseded_marker"):
		host.reconcile_strip_superseded_marker(owner_hint_id)
	return {"ok": true, "cleared_revision": actual_revision}


## Endpoint-coincidence epsilon (board mm) for chaining a candidate's OWN
## segment geometry into one polyline — same constant family as
## RoutingWorkspace._COMMIT_CHAIN_EPSILON_MM / pcb_canvas.gd
## CANDIDATE_RUN_CHAIN_EPSILON_MM (each file keeps its own copy of this
## family rather than a shared cross-file const — it only absorbs float
## noise, since the router splits at exact shared points, and the three
## sites already disagreed on nothing but the name before this one existed).
const _GEOMETRY_CHAIN_EPSILON_MM := 0.0001

## preserve_shape_as_corridor's source: the candidate's CURRENT geometry,
## chained into ONE ordered Array[Vector2] polyline — but ONLY when every
## segment endpoint-chains to the next (F6, cold review, Epoch UX1 station
## 9). The old implementation concatenated every segment's points regardless
## of adjacency, so a candidate with more than one DISCONNECTED run (the
## mandatory GATE fixture in test_workspace_tools.gd is exactly this shape —
## see its own doc) produced one polyline with a fabricated jump across the
## gap: a corridor claiming a path the candidate's own geometry never drew.
## Segments are walked in the candidate's own emission order (the route's
## walk order); a segment whose first point does not endpoint-coincide with
## the running polyline's last point (within _GEOMETRY_CHAIN_EPSILON_MM)
## starts a NEW run instead of extending the current one — the SAME EPSILON
## RoutingWorkspace._chain_seg_plan uses commit-side (mirrored rather than
## shared; that helper sits inside the commit transaction's own fence). Only
## the epsilon is shared, deliberately NOT _chain_seg_plan's full merge
## condition (same layer + same width): a corridor is plain XY steering
## geometry, layer-agnostic, so a layer-changing via (endpoint-coincident,
## different layer either side) chains into ONE run here exactly as it did
## before this fix — only a GENUINE gap between two coordinates breaks the
## run, never a layer change alone.
## Returns {"ok":true, "points":[...]} for exactly one run, or
## {"ok":false, "runs":N} for zero or more than one — the caller refuses BY
## NAME (no_geometry_to_preserve / no_single_path) rather than silently
## bridging the gap. Read BEFORE the reroute that follows replaces this
## candidate's geometry with something else — a snapshot of the shape as the
## caller last saw/edited it, not a live reference.
static func _corridor_from_candidate_geometry(c) -> Dictionary:
	# The walk itself is _chained_runs (shared with _route_quality since UX2
	# station 4); the ONE-run enforcement below is this caller's own rule.
	var runs: Array = _chained_runs(c)
	if runs.size() != 1:
		return {"ok": false, "runs": runs.size()}
	return {"ok": true, "points": runs[0]}


## F2 (cold review, Epoch UX1 station 9): duplicated-authority guard for
## legacy waypoints. When a task's routing_constraint steers routing AND the
## hint annotation this constraint is attributed to (`owner_hint_id` — "" is
## a no-op call, see below) still carries its own kind_payload.waypoints,
## that legacy field is now DEAD for routing purposes
## (route_bridge.hints_to_router's task_constraints override already ignores
## it entirely — see that function's own doc) — but nothing on the
## annotation itself said so, which is the duplicated-authority hazard: an
## editor looking at the hint's own waypoints would see geometry that no
## longer describes what actually steers the route. Stamps
## kind_payload.waypoints_superseded_by_constraint_revision = N through the
## standard mutate-with-history seam (host.update_annotation — the same one
## _set_hint_lifecycle/_add_via use), additive-only, never clearing the
## legacy waypoints themselves (they stay readable, just marked stale).
##
## RENDER / EDIT-REFUSAL IMPLICATIONS (e.g. should the canvas grey out a
## superseded corridor, or refuse to hand-edit it) are explicitly OUT OF
## FENCE for this round — deferred to the pre-boundary Codex round per the
## cold review that raised this finding.
##
## Best-effort and silent: an empty `hint_id` (steering a multi-hint task via
## an explicit `corridor` — F3's owner_hint_id is "" there, nothing to
## stamp), a host that cannot update annotations, a hint that no longer
## exists, or a hint with no legacy waypoints to begin with all degrade to a
## no-op rather than failing the steer that already durably wrote the task's
## own constraint.
static func _stamp_waypoints_superseded(host, hint_id: String, constraint_revision: int) -> void:
	if hint_id.is_empty() or host == null \
			or not host.has_method("get_by_id") or not host.has_method("update_annotation"):
		return
	var ann: Dictionary = host.get_by_id(hint_id)
	if ann.is_empty():
		return
	var kp: Variant = ann.get("kind_payload", {})
	if not (kp is Dictionary) or (kp.get("waypoints", []) as Array).is_empty():
		return
	var updated: Dictionary = ann.duplicate(true)
	var new_kp: Dictionary = (kp as Dictionary).duplicate(true)
	new_kp["waypoints_superseded_by_constraint_revision"] = constraint_revision
	# Codex 1047 fix round, verdict 5: the OFFLINE lock, stamped beside the
	# marker. Core's MCPAnnotationTools offline (document_path) update path
	# refuses any sidecar patch that actually CHANGES a kind_payload key named
	# in _locked_fields (error "live_editor_required", echoing _lock_reason) —
	# the live host's own guards cannot protect a sidecar edited with no panel
	# open, and these two fields coordinate with workspace state (the task's
	# routing_constraint) that only the live editor can see. Removed ONLY by
	# release_superseded_waypoints (the minerva_pcb_hint_convert_to_detailed
	# conversion, verdict 4); the host's marker re-injection keeps them from
	# being stripped by a partial live update. detail_level is locked along
	# with waypoints because flipping it to 'detailed' offline would silently
	# exit the seeder's one-time gate without clearing the constraint —
	# exactly the uncoordinated transition verdict 4's named operation exists
	# to own.
	new_kp["_locked_fields"] = ["waypoints", "detail_level"]
	new_kp["_lock_reason"] = ("waypoints are superseded by the task's routing constraint "
		+ "(revision %d) — open the board in the live editor and steer via "
		+ "minerva_pcb_workspace_reroute_route, or reclaim manual waypoint control with "
		+ "minerva_pcb_hint_convert_to_detailed") % constraint_revision
	updated["kind_payload"] = new_kp
	host.update_annotation(hint_id, updated)


## Codex 1047 fix round, verdict 6 — DETERMINISTIC LOAD-TIME RECONCILIATION of
## the two supersession stores. The legacy-waypoint supersession system writes
## TWO stores that persist in TWO different sidecar files:
##   1. the routing workspace's task routing_constraint (workspace sidecar,
##      via to_sidecar_dict/tasks) — written by _seed_legacy_waypoint_
##      constraints and _steer_task_before_reroute, cleared by
##      _hint_convert_to_detailed;
##   2. the annotation's kind_payload.waypoints_superseded_by_constraint_
##      revision marker + the verdict-5 offline-lock keys (_locked_fields/
##      _lock_reason) (annotations sidecar) — written by
##      _stamp_waypoints_superseded, stripped by the host's sanctioned
##      release.
## Every writer orders the pair (constraint first, marker second) but nothing
## makes the pair atomic: a crash/kill between the two writes, a save that
## lands one sidecar but not the other, or the DOCUMENTED undo-of-conversion
## asymmetry (release_superseded_waypoints' own doc) all leave a TORN state.
## Per the verdict-6 ruling, the supported contract is: ordered two-store
## writes + THIS deterministic reconciliation pass at load + the structured
## record below — never a claim of atomicity.
##
## AUTHORITY RULE: the workspace constraint store is authoritative; the
## annotation marker is DERIVED. "A constraint governs this hint" is decided
## by EXACTLY the gate the wire channel uses (_task_constraints_for_hints,
## mirrored, never re-derived differently): workspace.task_for_hint(hint) is
## constrained AND its constraint's owner_hint_id == hint — that is precisely
## the condition under which route_bridge.hints_to_router overrides the
## hint's own waypoints, i.e. under which the marker tells the truth.
##
## Per pcb_route_hint annotation, exactly one of three outcomes:
##   - CONSTRAINT-WITHOUT-MARKER (governing constraint; hint carries no
##     marker, e.g. workspace sidecar saved but annotations sidecar not, or a
##     crash between the seed's constraint write and its stamp): re-stamp the
##     marker at the constraint's revision via the SAME
##     _stamp_waypoints_superseded every live writer uses (which also writes
##     the lock keys — so this doubles as the CX-C backfill for pre-lock-era
##     stamps). Only when the hint carries waypoints to supersede — the stamp
##     helper's own empty-waypoints no-op is mirrored here so an intent-only
##     hint (waypoints [] by construction) never gets a phantom marker or a
##     phantom record.
##   - MARKER-OUT-OF-SHAPE (governing constraint AND marker, but the marker
##     names a different revision or the lock keys are absent — a pre-CX-C
##     stamp, or a stamp from a superseded save): same re-stamp, same
##     mechanism, reason "marker_out_of_shape".
##   - MARKER-WITHOUT-CONSTRAINT (marker present; NO governing constraint —
##     e.g. annotations sidecar saved but workspace sidecar not, or the
##     undo-of-conversion torn state): strip marker + lock keys through the
##     host's sanctioned bookkeeping path (reconcile_strip_superseded_marker
##     — NEVER a plain update_annotation, whose H2-1 re-injection guard would
##     put the marker straight back). detail_level is PRESERVED as found —
##     the deliberate rule; the full rationale (both reachable torn shapes
##     carry the detail_level that describes the pre-torn intent) lives on
##     that host method's own doc, the single home for the decision.
##
## Every repair emits a STRUCTURED record (the supported contract — the
## push_warning prose beside it is best-effort narration, per the ruling) in
## the F4 conflict-record idiom: {hint_id, task_id, action, reason[,
## constraint_revision]}. Records are returned AND, when the workspace
## carries the field, published on workspace.last_load_reconciliation (reset
## at the start of every pass — the last_ingest_* per-call convention).
##
## HISTORY: reconciliation is bookkeeping — neither direction creates an
## undoable step. The strip goes through the host's _suppress_hint_history
## seam; the stamp touches no _HINT_HISTORY_FIELDS entry (the same property
## that keeps every live stamp out of history).
##
## IDEMPOTENT + DETERMINISTIC: each hint's outcome depends only on that hint
## and its own governing task (no cross-hint interaction, no ordering
## dependence), and every repair moves the pair INTO the consistent state its
## own gate tests — so a second pass over the repaired stores emits nothing.
##
## Duck-typed/headless-safe at every hop (a stub host or workspace missing a
## method degrades to skipping that hint, never crashing), matching this
## file's off-tree discipline.
static func reconcile_superseded_waypoint_state(host, workspace) -> Array:
	var records: Array = []
	if host == null or workspace == null \
			or not host.has_method("get_all_annotations") \
			or not workspace.has_method("task_for_hint"):
		return records
	# Per-call reset FIRST (the last_ingest_* convention) so a pass that finds
	# nothing torn leaves the channel empty rather than describing a stale
	# earlier load.
	if "last_load_reconciliation" in workspace:
		workspace.last_load_reconciliation = []
	for ann in host.get_all_annotations():
		if not (ann is Dictionary) or str((ann as Dictionary).get("kind", "")) != "pcb_route_hint":
			continue
		var hint_id: String = str((ann as Dictionary).get("id", ""))
		if hint_id.is_empty():
			continue
		var kp: Dictionary = _dict_or_empty((ann as Dictionary).get("kind_payload"))
		var has_marker: bool = kp.has("waypoints_superseded_by_constraint_revision")
		# The authority gate — _task_constraints_for_hints' exact condition.
		var task = workspace.task_for_hint(hint_id)
		var constraint: Dictionary = {}
		if task != null and task.is_constrained():
			constraint = task.routing_constraint
		var governed: bool = not constraint.is_empty() \
			and str(constraint.get("owner_hint_id", "")) == hint_id
		if governed:
			var wp: Array = kp.get("waypoints", []) if kp.get("waypoints", []) is Array else []
			if wp.is_empty():
				continue  # nothing to supersede — mirror the stamp's own no-op
			var rev: int = int(constraint.get("revision", 0))
			var out_of_shape: bool = has_marker and (
				int(kp.get("waypoints_superseded_by_constraint_revision", 0)) != rev
				or not kp.has("_locked_fields") or not kp.has("_lock_reason"))
			if has_marker and not out_of_shape:
				continue  # consistent — the common case
			_stamp_waypoints_superseded(host, hint_id, rev)
			var record: Dictionary = {
				"hint_id": hint_id,
				"task_id": str(task.task_id),
				"action": "restamped_marker",
				"reason": "marker_out_of_shape" if has_marker else "constraint_without_marker",
				"constraint_revision": rev,
			}
			records.append(record)
			push_warning(("[panel_tools] load reconciliation (verdict 6): re-stamped "
				+ "waypoints_superseded_by_constraint_revision=%d on pcb_route_hint '%s' — task '%s' "
				+ "carries the governing routing_constraint (the authoritative store) but the "
				+ "annotation marker was %s (torn two-store save)") % [
					rev, hint_id, str(task.task_id),
					"out of shape" if has_marker else "absent"])
		elif has_marker:
			if not host.has_method("reconcile_strip_superseded_marker"):
				continue
			var stripped: Dictionary = host.reconcile_strip_superseded_marker(hint_id)
			if not bool(stripped.get("ok", false)) or not bool(stripped.get("changed", false)):
				continue
			records.append({
				"hint_id": hint_id,
				"task_id": str(task.task_id) if task != null else "",
				"action": "released_stale_marker",
				"reason": "marker_without_constraint",
			})
			push_warning(("[panel_tools] load reconciliation (verdict 6): stripped a stale "
				+ "waypoints_superseded_by_constraint_revision marker (+ lock keys) from "
				+ "pcb_route_hint '%s' — no owner-attributed routing_constraint governs it in the "
				+ "workspace (the authoritative store), so its waypoints are live authority again; "
				+ "detail_level preserved as found") % hint_id)
	# Publish on the workspace's structured channel (per-call reset, same
	# convention as last_ingest_holds/last_ingest_constraint_conflicts).
	if "last_load_reconciliation" in workspace:
		workspace.last_load_reconciliation = records.duplicate(true)
	return records


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


## Preconditions a reroute needs BEFORE any mutation — candidate exists, its
## disposition can legally reach "superseded", and its source hints are still
## present/resolvable on the board. Factored out (F1, cold review, Epoch UX1
## station 9) so _workspace_reroute_route can run every refusable check FIRST
## — including these — before _steer_task_before_reroute ever writes a task's
## routing_constraint, and so this function keeps checking the exact same
## things it always did, just through one shared implementation instead of
## two copies that could drift.
## Returns {ok:true, workspace, data, candidate, cid, hint_ids, source_hints}
## or {ok:false, reply:<named refusal>}.
static func _reroute_precheck(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return {"ok": false, "reply": ctx.get("reply")}
	var workspace = ctx["ws"]
	var data = ctx["data"]
	var cid: String = str(args.get("candidate_id", ""))
	if cid.is_empty():
		return {"ok": false, "reply": _err("candidate_id is required")}
	var c = workspace.get_candidate(cid)
	if c == null:
		return {"ok": false, "reply": {"success": false, "error": "candidate_not_found", "candidate_id": cid}}
	if not workspace.can_transition(cid, "superseded"):
		return {"ok": false, "reply": _workspace_refusal_static(cid, str(c.disposition))}

	# DCR 01a022ab356c leg C: hint provenance is the PREFERRED scoping, no
	# longer the only one. A candidate whose hints are gone (deleted intent)
	# or that never had any (bus/fallback generations, worker attributed [])
	# degrades to a hint-less run scoped by the candidate's OWN task_id/net/
	# endpoints — the worker already accepts task/terminal scope
	# (route_bridge.parse_route_scope), and the candidate's endpoints are
	# durable. The executor lands the answer on the SAME task (ingest
	# task-key override) and reports hintless_fallback:true. This retires the
	# no_source_hints / source_hints_missing refusals; a candidate with NO
	# endpoints either still fails closed — an unscopable run must never
	# silently widen to the whole board.
	# OWNERSHIP IS NOT AN ANSWER: a via ENTITY (no
	# copper, one via) carries the hint it SERVES on source_hint_ids. Rerouting
	# is about a hint's ROUTE, never about a hole, so a via ghost scopes as
	# HINT-LESS exactly as it did before ownership existed — and, carrying no
	# endpoints either, falls through to the gate below as unscopable_candidate.
	var hint_ids: Array = [] if _PcbRouteCandidateScript.is_proposed_via_entity(c) \
		else _string_list(c.source_hint_ids)
	var source_hints: Array = _gather_route_hints(host, hint_ids) if not hint_ids.is_empty() else []
	if hint_ids.is_empty() or source_hints.is_empty():
		# ≥2 DEDUPED well-formed refs (fix cold review f5): a single terminal,
		# a duplicated pad, or component-only entries all pass an emptiness
		# check yet make parse_route_scope refuse — which would surface as a
		# misdiagnosed "route_worker_unavailable". Gate here, by name.
		var seen: Dictionary = {}
		for r in _endpoint_pin_refs(c):
			seen[str(r)] = true
		if seen.size() < 2:
			return {"ok": false, "reply": {
				"success": false, "error": "unscopable_candidate", "candidate_id": cid,
				"note": "this candidate has neither live source hints nor at least two well-formed endpoint pin refs (\"Comp.Pin\") — a reroute cannot be scoped to it, and an unscoped run would route the whole board",
			}}
		return {"ok": true, "workspace": workspace, "data": data, "candidate": c,
			"cid": cid, "hint_ids": [], "source_hints": [], "hintless": true}
	return {"ok": true, "workspace": workspace, "data": data, "candidate": c,
		"cid": cid, "hint_ids": hint_ids, "source_hints": source_hints}


## `pre` is an already-passed _reroute_precheck result (F1) when the caller
## has one (_workspace_reroute_route, after its own steering has run); every
## other caller (_workspace_reroute_span) leaves it at the default {} and
## this function runs the precheck itself — byte-identical to what it always
## did.
static func _workspace_reroute(host, args: Dictionary, extra: Dictionary, pre: Dictionary = {}) -> Dictionary:
	if not bool(pre.get("ok", false)):
		pre = _reroute_precheck(host, args)
		if not bool(pre.get("ok", false)):
			return pre.get("reply")
	var workspace = pre["workspace"]
	var data = pre["data"]
	var c = pre["candidate"]
	var cid: String = str(pre["cid"])
	var source_hints: Array = pre["source_hints"]
	var hintless: bool = bool(pre.get("hintless", false))

	var scope: Dictionary = _reroute_scope(c, source_hints, data)
	if hintless and scope.has("tasks"):
		# Leg C: a hint-less run's ONLY steering is the candidate's own
		# terminals — ride them on the task scope (as "Comp.Pin" ref strings,
		# the parse_route_scope wire shape) so the worker narrows the run
		# instead of routing the whole net blind.
		for t in scope["tasks"]:
			if t is Dictionary:
				(t as Dictionary)["endpoints"] = _endpoint_pin_refs(c)
	var route_extra: Dictionary = _route_request_extra(
		workspace, scope, _hint_id_list(source_hints))
	# Epoch UX4 station 3: a reroute replaces one ghost with another — always
	# a draft request, same contract as propose above.
	route_extra["draft_request"] = true
	var reply: Dictionary = await _run_router(
		host, {"mode": "ids", "ids": _hint_id_list(source_hints)}, route_extra)
	if not bool(reply.get("ok", false)):
		return _router_call_failed(reply, source_hints)

	# The router answered — NOW retire the prior. A pinned prior would otherwise
	# HOLD its task and the fresh geometry would be dropped on the floor.
	var prior_task: String = str(c.task_id)
	if str(c.disposition) == "pinned" and not workspace.supersede(cid):
		return _workspace_refusal(workspace, "reroute", cid)

	# Leg C ingest override: a hint-less reply attributes to [] — without the
	# override the answer would land on a phantom "net|" task, leaving TWO
	# live candidates for one question. The overrides pin the answer to the
	# SAME task, carry the endpoints onto the fallback generation (so IT can
	# be rerouted again), and keep the prior width.
	var overrides: Dictionary = {}
	if hintless:
		# Prior width rides per-segment on the candidate (no scalar field) —
		# the first segment's width is the run width every reply reports.
		var prior_width := 0.0
		if not c.segments.is_empty() and c.segments[0] is Dictionary:
			prior_width = float((c.segments[0] as Dictionary).get("width", 0.0))
		overrides = {
			# endpoints keep the model's {component, pin} DICT shape — the
			# override feeds cand.endpoints directly, and every consumer
			# (including this very fallback on the NEXT reroute) reads dicts.
			"task_key_override": prior_task,
			"endpoints_override": (c.endpoints as Array).duplicate(true),
			"width_override": prior_width,
		}
	var landed: Dictionary = await _ingest_result_into_workspace(
		host, workspace, data, reply.get("result", {}), source_hints, extra,
		reply.get("draft_context", {}) if reply.get("draft_context", null) is Dictionary else {},
		overrides)
	if hintless:
		landed["hintless_fallback"] = true
		# Honesty for constrained tasks (fix cold review f3): the constraint
		# could not ride this run, and the landed generation will refuse
		# commit as constraint-stale — say so NOW, with the recovery named.
		var asking_task = workspace.get_task(prior_task)
		if asking_task != null and asking_task.is_constrained():
			landed["constraint_note"] = "the asking task carries a routing_constraint this hint-less run could NOT consume (steering is hint-keyed) — committing the landed generation will refuse constraint-stale; clear_constraint on a reroute releases it, or author a fresh intent to steer"
	landed["rerouted_candidate_id"] = cid
	landed["prior_task_id"] = prior_task
	# Epoch UX1 station 11: reroute's own review-then-commit guidance replaces
	# _ingest_result_into_workspace's generic "propose" note — a reroute
	# always names ONE fresh generation, not an open-ended candidate set.
	if not (landed.get("candidates", []) as Array).is_empty():
		landed["note"] = _next_steps("reroute_route", {})
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
		# FROZEN is live-but-locked, not departed (cold review finding 5): the
		# refusal reaches here because frozen → superseded has no table row,
		# and the remedy is the unfreeze verb — the prose must not claim the
		# candidate left the live set when it did not.
		"note": "a frozen candidate cannot be rerouted — it is settled; minerva_pcb_workspace_unfreeze it first, then reroute" if from == "frozen" \
			else "a %s candidate cannot be rerouted — it has already left the live set" % from,
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
	if not result.has("per_candidate"):
		# check_draft names its own failure now. It used to return {} for an
		# unmounted panel, a mid-flight ghost drag AND a broker refusal alike,
		# so every one of them arrived here as "the worker did not answer" —
		# one message for three faults with three different fixes.
		return {"success": false,
			"error": str(result.get("error", "draft_check_no_reply")),
			"checked": targets,
			"note": str(result.get("note",
				"the draft_check worker channel did not answer; every checked candidate was reverted to the validation it had before (never left 'checking')"))}
	# The worker can score a request and still report that it could not finish
	# (an unreadable board snapshot, an indeterminate geometric leg). That was
	# write-only: it rode the reply and nothing surfaced it, so a caller saw an
	# empty findings list and read it as clean.
	if str(result.get("error", "")) != "":
		return {"success": false, "error": "draft_check_incomplete",
			"checked": targets,
			"worker_error": str(result.get("error")),
			"note": "the worker returned a verdict it could not stand behind; every checked candidate kept the validation it had"}
	var after: Dictionary = {}
	for t in targets:
		var c = workspace.get_candidate(str(t))
		if c != null:
			after[str(t)] = str(c.validation)
	var reply: Dictionary = {
		"checked": targets,
		"checked_stale": stale,
		# Same authoritative shape as `validation`: coherence guards and geometric
		# fail-closed policy have already been applied by the workspace.
		"per_candidate": after,
		"findings": result.get("findings", []),
		"validation": after,
		"board_token": result.get("board_token", ""),
		"workspace_generation": result.get("workspace_generation", 0),
		"newly_stale_candidate_ids": newly_stale,
	}
	# GEOMETRY THAT COULD NOT BE VERIFIED MUST REACH THE AGENT (Codex re-review
	# finding 2). Without this the MCP reply carried per-candidate verdicts from
	# the connectivity half while the geometric half had silently not run, and
	# an agent reading "clean" would route on copper whose clearances nobody
	# checked. The workspace already downgrades those candidates off "clean";
	# this says WHY, which is what makes the downgrade actionable.
	var indeterminate: Dictionary = workspace.geometric_indeterminate() \
		if workspace.has_method("geometric_indeterminate") else {}
	if not indeterminate.is_empty():
		reply["geometric_indeterminate"] = indeterminate
		reply["note"] = "geometry could NOT be verified (%s) — unverified clean verdicts were downgraded to error; definite connectivity violations remain reported" % str(indeterminate.get("kind", "unknown"))
	var provenance: Variant = result.get("draft_provenance")
	if provenance is Array and not (provenance as Array).is_empty():
		reply["draft_provenance"] = provenance
	return _ok(reply)


# ══ C5 — BUS TOOL geometry core + MCP parity (S3+S4, DCR 019fb572b888) ══════
#
# bus_plan/bus_commit_plan are the ONE shared implementation the canvas
# gesture (pcb_canvas.gd's _commit_bus/_draw_bus_preview, which preload this
# file) and BOTH MCP bus verbs below call — "MCP tool result == gesture result
# on the same input" is true by construction (one function, not two
# hand-synchronised copies), not merely tested for. The pads a bus runs between
# are part of that one plan for the same reason: a verb that grew its own
# pad-to-pad path would be the second copy.
#
# Split in two on purpose: bus_plan is PURE (no mutation, no history — safe to
# call every redraw for the live preview) and bus_commit_plan MUTATES (create
# N traces, one save_to_history). A caller always calls bus_plan first.
#
# A BUS MAY CHANGE LAYER ONCE, at a VIA STATION: one interior spine vertex
# where every track drops a via and continues on a second layer. A plan
# carrying one lands TWO traces and ONE via per net instead of one trace —
# the same shape the routing workspace materializes a layer-changing route
# into, so DRC, Gerber and the single undo step treat a bus via like any other.
#
# A PLAN HAS THREE STATES, not two (pcb_bus_geometry.gd's "two classes of no"):
# clean (ok), BAD BUT BUILDABLE (ok false, buildable true, findings non-empty,
# geometry present) and UNBUILDABLE (ok false, buildable false, no geometry).
# The two writers below land the first two and refuse the third — copper that
# exists can be corrected, and a bus refused outright leaves nothing to correct.

## Mirrors pcb_bus_geometry.gd's own _MIN_SEGMENT_MM — kept as an independent
## constant rather than reaching into that module's private (leading-
## underscore) internals, which would couple this file to an implementation
## detail of a standing pin never meant to be consumed past its public statics
## (offset_polyline/pitch_between/cumulative_offsets/MITER_LIMIT).
const _BUS_MIN_SEGMENT_MM := 1e-6

## The refusal both writers answer an INCOMPLETE plan with (bus_plan's
## target-less corridor — see its doc). Shared so the fail-closed gate reads
## identically wherever a plan turns into copper or a candidate.
const _BUS_INCOMPLETE_PLAN := "This bus has no target pad for every net yet — a bus is authored pad to pad, so nothing was written."

## The one finding type raised in THIS file rather than in pcb_bus_geometry.gd:
## the inner fold is measured before the pads are resolved, so the geometry
## module never sees the spine that causes it.
const BUS_FINDING_INNER_FOLD := "bus_inner_fold"

## The SECOND finding type raised in this file: bus copper sitting on, or inside
## the board's clearance of, copper belonging to ANOTHER net — a pad, a via or a
## trace that is already on the board.
##
## It cannot live in pcb_bus_geometry.gd for the same reason the inner fold
## cannot: that module is pure geometry over points and imports nothing, so it
## has no board to ask what else is on the layer. It sees the pads it is routing
## to as bare coordinates and cannot even tell which net one belongs to.
const BUS_FINDING_FOREIGN_COPPER := "bus_foreign_copper"

## A bus leg that lands on a layer
## its own pad has no copper on — an SMD pad on the other side of the board
## from the layer the leg runs on. The copper ends under the pad with nothing
## to join, which is an open by construction, and nothing in bundle_routes can
## see it: that module knows pads as bare points, not as copper on a layer.
const BUS_FINDING_PAD_OFF_LAYER := "bus_pad_off_layer"

## A via station whose vias leave another net's pad clear of the
## board's clearance but not of a routing CORRIDOR. A via ring that sits one
## clearance from a pad's copper is legal and walls the pad off — no track can
## pass between them — so the pad cannot be reached from that side any more.
## The corridor is one track width plus a clearance each side of it.
const BUS_FINDING_STATION_CROWDS_PAD := "bus_station_crowds_pad"

## How far inside the board's clearance a bus route may measure against another
## net's copper before the pass below calls it a violation, in mm. Mirrors
## pcb_bus_geometry.gd's own _CLEARANCE_TOLERANCE_MM — an independent constant
## rather than a reach into that module's privates, same as _BUS_MIN_SEGMENT_MM
## above, and for the same reason: Vector2 is 32-bit float, so copper laid out
## EXACTLY at its clearance measures that clearance only to within an ulp.
const _BUS_FOREIGN_TOLERANCE_MM := 1e-3

## A plan that HAS geometry, clean or not: `ok` iff nothing was found, `error`
## the first finding's words.
##
## Every finding is stamped with the plan's `layer` and, for a single-net rule,
## its `net_name` — the two keys the routing workspace's witness renderer reads
## off a draft-check finding, so a bus finding drawn as a ghost's witness needs
## no shape of its own.
##
## A finding that ALREADY names a layer keeps it. Only the board-aware
## foreign-copper pass sets one, and it has to: a bus with a via station runs on
## two layers, and the half of it past the station is not on the plan's `layer`.
static func _bus_planned(findings: Array, layer: String, fields: Dictionary) -> Dictionary:
	var stamped: Array = []
	for raw in findings:
		var f: Dictionary = (raw as Dictionary).duplicate(true)
		if not f.has("layer"):
			f["layer"] = layer
		var nets: Array = f.get("nets", []) if f.get("nets", []) is Array else []
		if nets.size() == 1:
			f["net_name"] = str(nets[0])
		stamped.append(f)
	var out: Dictionary = {
		"ok": stamped.is_empty(),
		"buildable": true,
		"findings": stamped,
		"error": "" if stamped.is_empty() else str((stamped[0] as Dictionary).get("message", "")),
	}
	out.merge(fields)
	return out


## The bus tool's UNBUILDABLE refusal, in pcb_bus_geometry.gd's own shape, so a
## refusal raised in this file and one raised inside the geometry are the same
## dictionary to every caller.
static func _bus_unbuildable(message: String) -> Dictionary:
	return {"ok": false, "buildable": false, "error": message, "findings": []}


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


## Resolve one "Component.Pin" ref per net into the pad centre a bus leg starts
## (or ends) at.
##
## THE NET CHECK IS THE POINT. BusGeom.bundle_routes sees coordinates only and
## has no way to tell that a pad belongs to the net whose track is being run to
## it; a ref naming another net's pad would otherwise route real copper to the
## wrong pin and pass every geometric test on the way. Checked here, in the one
## place both the canvas gesture and the two MCP verbs learn a pad's position.
##
## Returns {ok, error, points} — points parallel to `nets` on success.
static func bus_pad_anchors(data, nets: Array, pins: PackedStringArray, role: String) -> Dictionary:
	if pins.size() != nets.size():
		return {"ok": false, "points": PackedVector2Array(), "error":
			"A bus needs one %s pin per net (%d nets, %d %s pins)." % [role, nets.size(), pins.size(), role]}
	var points := PackedVector2Array()
	var pads: Array = []
	for i in range(nets.size()):
		var net_name: String = str(nets[i])
		var ref: String = str(pins[i])
		var resolved: Dictionary = _resolve_route_intent_pin(data, ref)
		if not bool(resolved.get("ok", false)):
			return {"ok": false, "points": PackedVector2Array(), "error":
				"Net \"%s\"'s %s pin: %s" % [net_name, role, str(resolved.get("message", ""))]}
		var component: String = str(resolved["component"])
		var pin: String = str(resolved["pin"])
		var pin_net: String = data.find_net_for_pin(component, pin)
		if pin_net != net_name:
			return {"ok": false, "points": PackedVector2Array(), "error":
				"Pin %s is on net \"%s\", not \"%s\" — a bus's %s pin has to sit on the net it carries."
					% [ref, pin_net if not pin_net.is_empty() else "(none)", net_name, role]}
		var comp = resolved["comp"]
		points.append(comp.get_pin_world_position(pin))
		# The pad as COPPER, not just a point: which layers it is on, so the
		# plan can tell whether the leg that reaches it lands on one of them.
		var copper: Dictionary = _bus_pad_layers(comp, pin)
		pads.append({"ref": "%s.%s" % [str(comp.id), pin], "net": net_name,
			"centre": points[i], "all_layers": copper["all_layers"],
			"layers": copper["layers"], "no_copper": bool(copper.get("no_copper", false))})
	return {"ok": true, "error": "", "points": points, "pads": pads}


# ── THE BOARD-AWARE PASS: bus copper against ANOTHER NET'S copper ────────────
#
# BusGeom.bundle_routes measures the bus against ITSELF and nothing else. It is
# a pure geometry module that takes pads as bare coordinates, imports nothing
# and cannot be told what else is on the layer without becoming board-aware —
# which would cost it the property that makes it a standing pin (exercised with
# plain numbers, no scene tree, no board). So the check lives HERE, in bus_plan,
# over the polylines bundle_routes hands back: this is the one function both the
# canvas gesture and both MCP verbs already call, it already holds `data`, and a
# finding raised here reaches the status line, the verb reply and the ghost's
# per-candidate findings through the exact channels the existing findings use.
#
# THIS IS BAD-BUT-BUILDABLE, like every other bus finding: the copper still
# lands. Copper that exists can be corrected; a refusal leaves nothing to.
#
# WHAT IT MEASURES: copper EDGE to copper EDGE, against the board's own
# design_rule_clearance(). One convention for pads, vias and traces alike, and
# the one a fab states — a negative figure is overlap, i.e. a short.

## Canonical copper id for a stored layer name, or "" when the name is not
## copper at all. Silent where PcbLayerStack.kicad_to_canon warns: pads legally
## carry mask and paste layer names, and "not copper" is not an error to report.
static func _bus_canon_layer(name: String) -> String:
	return PcbLayerStack.kicad_to_canon(name) if PcbLayerStack.is_copper(name) else ""


## Every piece of copper ALREADY on the board a bus could land on, as
## [{kind, what, ref, net, all_layers, layers, bounds, ...}].
##
## PADS ARE ENUMERATED THROUGH THE COMPONENT'S PINS, not through its render
## `pads` array, because the pins are the set the board actually routes to: a
## footprint that never resolved carries pins and no lands, and its copper is
## then known only as a point. Mechanical (np_thru_hole) holes never enter
## `pins` at all, which is right — a hole is not copper.
##
## Pad copper is measured by pcb_component.pin_copper_distance, the SAME rule
## the pad picker and the hit-test use, so this pass and the pointer agree about
## where a pad's copper ends. A pin with no lands falls back to its CENTRE
## inside that rule; items carrying `centre_only` say so in their finding.
##
## VIAS ARE TAKEN AS PRESENT ON EVERY COPPER LAYER. This model has no
## blind/buried via — PcbLayerStack.is_legal_via_span refuses any span that is
## not through — so a via's barrel crosses the whole stack.
static func _bus_board_copper(data) -> Array:
	var pin_nets: Dictionary = {}
	for net_name in data.nets:
		for raw_pin in data.get_net(str(net_name)).pins:
			var pin_ref: Dictionary = raw_pin
			pin_nets["%s.%s" % [str(pin_ref.get("component_id", "")), str(pin_ref.get("pin_name", ""))]] = str(net_name)

	var items: Array = []
	for comp in data.get_all_components():
		for raw_name in comp.pins:
			var pin: String = str(raw_name)
			var lands: Array = comp.lands_for_pin(pin)
			var pin_local: Vector2 = comp.pins.get(pin, Vector2.ZERO)
			var reach := 0.0
			for raw_land in lands:
				var land: Dictionary = raw_land
				var size: Vector2 = land.get("size", Vector2.ZERO)
				var offset: Vector2 = land.get("position", Vector2.ZERO)
				# Half-DIAGONAL, so the box holds the land at any rotation.
				reach = maxf(reach, offset.distance_to(pin_local) + size.length() * 0.5)
			var copper: Dictionary = _bus_pad_layers(comp, pin)
			if bool(copper.get("no_copper", false)):
				continue
			var centre: Vector2 = comp.get_pin_world_position(pin)
			items.append({
				"kind": "pad", "what": "pad", "ref": "%s.%s" % [str(comp.id), pin],
				"net": str(pin_nets.get("%s.%s" % [str(comp.id), pin], "")),
				"all_layers": copper["all_layers"], "layers": copper["layers"],
				"comp": comp, "pin": pin, "centre": centre,
				"centre_only": lands.is_empty(),
				"bounds": Rect2(centre, Vector2.ZERO).grow(reach + _BUS_FOREIGN_TOLERANCE_MM),
			})

	for raw_via in data.vias:
		var via: Dictionary = raw_via
		var at: Vector2 = _PcbDataScript.via_position(via)
		var radius: float = _PcbDataScript.via_radius(via, data)
		items.append({
			"kind": "via", "what": "via", "ref": str(via.get("id", "(id-less via)")),
			"net": str(via.get("net_name", "")),
			"all_layers": true, "layers": {},
			"centre": at, "radius": radius, "centre_only": false,
			"bounds": Rect2(at, Vector2.ZERO).grow(radius + _BUS_FOREIGN_TOLERANCE_MM),
		})

	for raw_id in data.traces:
		var trace = data.get_trace(str(raw_id))
		if trace == null or trace.waypoints.size() < 2:
			continue
		var canon := _bus_canon_layer(str(trace.layer))
		if canon.is_empty():
			continue
		var half: float = float(trace.width) * 0.5
		items.append({
			"kind": "trace", "what": "trace", "ref": str(trace.id),
			"net": str(trace.net_name),
			"all_layers": false, "layers": {canon: true},
			"points": trace.waypoints, "half": half, "centre_only": false,
			"bounds": PcbTraceGeometry.bounds(PackedVector2Array(trace.waypoints)).grow(half + _BUS_FOREIGN_TOLERANCE_MM),
		})
	return items


## Which copper layers one pad is on: {all_layers, layers, no_copper} —
## `all_layers` true for a plated through-hole land (its barrel crosses the
## stack) or a pin with no land geometry at all, else `layers` the canonical
## copper ids its SMD lands name. An UNPLATED hole (np_thru_hole) is a hole and
## nothing more — no barrel, no ring, no copper on any layer — so a pin whose
## lands are all unplated is `no_copper`: it is not on any layer, and it is
## not copper another net could be foreign to.
##
## A land naming no copper layer of its own sits on the side its component is
## placed on; a component with no readable side is taken as everywhere, which
## is the fail-closed reading for the foreign-copper pass (it meets every
## probe) and the fail-open one for the off-layer rule (no leg can miss it) —
## a pad the board cannot place on a layer is not a pad this file can judge.
static func _bus_pad_layers(comp, pin: String) -> Dictionary:
	var lands: Array = comp.lands_for_pin(pin)
	var all_layers: bool = lands.is_empty()
	var layers: Dictionary = {}
	var unplated := 0
	for raw_land in lands:
		var land: Dictionary = raw_land
		var land_type := str(land.get("type", "smd")).to_lower()
		if land_type == "np_thru_hole":
			unplated += 1
			continue
		if land_type == "thru_hole":
			all_layers = true
			continue
		# PLACED layers (pcb_component.placed_pad_layers): a back-mounted part's
		# F.Cu land is B.Cu copper.
		for raw_layer in comp.placed_pad_layers(land):
			var canon := _bus_canon_layer(str(raw_layer))
			if not canon.is_empty():
				layers[canon] = true
	if not lands.is_empty() and unplated == lands.size():
		return {"all_layers": false, "layers": {}, "no_copper": true}
	if not all_layers and layers.is_empty():
		var side := _bus_canon_layer(str(comp.layer))
		if side.is_empty():
			all_layers = true
		else:
			layers[side] = true
	return {"all_layers": all_layers, "layers": layers, "no_copper": false}


## One finding per bus pad whose leg lands on a layer the pad has no copper on.
##
## `pads` is bus_pad_anchors' `pads` for one end, `landing` the layer that
## end's legs run on — the plan's own layer at the source end; past a via
## station, the station's layer at the target end. A through-hole pad is on
## every layer and never raises this. The way out differs by end: a source leg
## is on the layer the bus STARTS on, so the fix is to start it elsewhere; a
## target leg can be brought to the pad's layer by a station before it.
static func _bus_pad_off_layer_findings(pads: Array, landing: String, role: String) -> Array:
	var out: Array = []
	var canon := _bus_canon_layer(landing)
	for raw in pads:
		var pad: Dictionary = raw
		if bool(pad.get("all_layers", false)):
			continue
		var layers: Array = (pad.get("layers", {}) as Dictionary).keys()
		layers.sort()
		var no_copper: bool = bool(pad.get("no_copper", false))
		if canon.is_empty() or (not no_copper and (layers.is_empty() or canon in layers)):
			continue
		var net: String = str(pad.get("net", ""))
		var ref: String = str(pad.get("ref", ""))
		var on := "no layer at all (an unplated hole)" if no_copper \
			else ", ".join(PackedStringArray(layers))
		var way_out := ""
		if role == "source":
			way_out = "Start the bus on %s instead, or bus from a pad that is on %s." % [on, landing]
		else:
			way_out = "Switch the Layer chooser before this pad to add a via station that brings the bus to %s (via_station_index and via_station_layer on minerva_pcb_route_bus_direct), or bus to a pad that is on %s." % [on, landing]
		var centre: Vector2 = pad.get("centre", Vector2.ZERO)
		out.append({
			"type": BUS_FINDING_PAD_OFF_LAYER,
			"message": "Net \"%s\"'s %s pad %s has copper on %s only, and its bus leg lands on %s — the copper ends under the pad with nothing to join, which is an open. %s"
				% [net, role, ref, on, landing, way_out],
			"nets": [net],
			"measured_mm": 0.0,
			"required_mm": 0.0,
			"layer": landing,
			"pad_ref": ref,
			"pad_layers": layers,
			"closest": [centre.x, centre.y],
			"witness": [centre.x, centre.y],
			"midpoint": [centre.x, centre.y],
		})
	return out


## One finding per (station via, foreign pad) pair whose bare board between
## them is at least the clearance — so the foreign-copper pass has nothing to
## say — but less than a routing corridor: `trace_width` plus `clearance` on
## each side of it, the room one track needs to pass between the via's ring and
## the pad's copper. THAT TRACK IS THE PAD'S, NOT THE BUS'S: the corridor is
## kept for whatever will one day route to the walled-off pad, so its width is
## the board's rule (design_rule_trace_width), and the bus's own track widths
## play no part in it. Measured ring edge to copper edge with the same
## pin_copper_distance rule the foreign pass uses for pads, so the two findings
## split a single scale at the clearance and never both name one pair.
static func _bus_station_corridor_findings(data, nets: PackedStringArray,
		via_points: Array, via_diameter: float, clearance: float,
		trace_width: float, layer: String) -> Array:
	if data == null or via_points.is_empty() or via_points.size() != nets.size():
		return []
	var radius: float = maxf(0.0, via_diameter) * 0.5
	var need: float = maxf(0.0, trace_width) + 2.0 * maxf(0.0, clearance)
	var out: Array = []
	var items: Array = _bus_board_copper(data)
	for i in range(via_points.size()):
		var at: Vector2 = via_points[i]
		var bus_net: String = str(nets[i])
		var box := Rect2(at, Vector2.ZERO).grow(radius + need + _BUS_FOREIGN_TOLERANCE_MM)
		for raw_item in items:
			var item: Dictionary = raw_item
			if str(item["kind"]) != "pad" or str(item["net"]) == bus_net:
				continue
			if not box.intersects(item["bounds"] as Rect2):
				continue
			var comp = item["comp"]
			var pin: String = str(item["pin"])
			var gap: float = comp.pin_copper_distance(pin, at) - radius
			if gap < maxf(0.0, clearance) - _BUS_FOREIGN_TOLERANCE_MM \
					or gap >= need - _BUS_FOREIGN_TOLERANCE_MM:
				continue
			var foreign_net: String = str(item["net"])
			var centre: Vector2 = item["centre"]
			out.append({
				"type": BUS_FINDING_STATION_CROWDS_PAD,
				"message": "Net \"%s\"'s station via at (%.3f, %.3f) leaves %.3fmm of bare board beside pad %s (net \"%s\") — clear of this board's %.3fmm clearance, but a track needs %.3fmm to pass between them (%.3fmm trace width plus %.3fmm clearance each side), so the station walls that pad off from this side. Move the station along the spine, away from the pad, or move the pad."
					% [bus_net, at.x, at.y, gap, str(item["ref"]),
						foreign_net if not foreign_net.is_empty() else "(none)",
						maxf(0.0, clearance), need, maxf(0.0, trace_width), maxf(0.0, clearance)],
				"nets": [bus_net],
				"measured_mm": gap,
				"required_mm": need,
				"layer": _bus_via_hit_layer(item, layer),
				"foreign_ref": str(item["ref"]),
				"foreign_net": foreign_net,
				"closest": [at.x, at.y],
				"witness": [centre.x, centre.y],
				"midpoint": [(at.x + centre.x) * 0.5, (at.y + centre.y) * 0.5],
			})
	return out


## Does this board item have copper on `probe_layer`? An empty `probe_layer`
## means the bus copper being measured spans the stack (a station via), and so
## meets everything.
## The layer a finding names when a THROUGH VIA (a probe on every layer) meets
## `item`: the item's own layer, so a station via that lands on bottom-only
## copper is reported on bottom rather than on the layer the bus started on.
## Copper on every layer is reported on `fallback` — any layer is true there.
static func _bus_via_hit_layer(item: Dictionary, fallback: String) -> String:
	if bool(item.get("all_layers", false)):
		return fallback
	var layers: Array = (item.get("layers", {}) as Dictionary).keys()
	if layers.is_empty():
		return fallback
	layers.sort()
	return str(layers[0])


static func _bus_item_on_layer(item: Dictionary, probe_layer: String) -> bool:
	if bool(item.get("all_layers", false)) or probe_layer.is_empty():
		return true
	return (item.get("layers", {}) as Dictionary).has(probe_layer)


## Closest approach between ONE bus segment's CENTRELINE and one board item's
## copper EDGE: {distance, a, b}, `a` on the bus and `b` on (or at the centre
## of) the item.
##
## A PAD is asked through pcb_component.pin_copper_distance — the production
## rule, called rather than copied — at the three points of this segment that
## can hold the minimum: its two ends and the point nearest the pad's centre.
## That triple is EXACT for an axis-aligned land against an axis-aligned
## segment, which is every land at a cardinal rotation and every segment a bus
## builds. A land rotated off-axis can measure LONG by up to its own corner
## overhang; nothing this tool authors produces one, and the pad picker makes
## the same trade in the other direction.
static func _bus_item_gap(item: Dictionary, a0: Vector2, a1: Vector2) -> Dictionary:
	var kind: String = str(item["kind"])
	if kind == "trace":
		# The GENERAL segment gap, deliberately unlike the bus module's own
		# axis-aligned shortcut: an existing trace is whatever a router or a
		# human left there, and a diagonal one would read as touching whenever
		# its box merely overlapped — a false short on every crossing corner.
		var best: Dictionary = PcbTraceGeometry.segment_to_polyline_gap(
			PackedVector2Array(item["points"]), a0, a1)
		best["distance"] = float(best["distance"]) - float(item["half"])
		return best
	var centre: Vector2 = item["centre"]
	var near: Vector2 = PcbTraceGeometry.closest_point_on_segment(centre, a0, a1)
	if kind == "via":
		return {"distance": near.distance_to(centre) - float(item["radius"]),
			"a": near, "b": centre}
	var comp = item["comp"]
	var pin: String = str(item["pin"])
	var best_at: Vector2 = near
	var best_d: float = comp.pin_copper_distance(pin, near)
	for p in [a0, a1]:
		var at: Vector2 = p
		var d: float = comp.pin_copper_distance(pin, at)
		if d < best_d:
			best_d = d
			best_at = at
	return {"distance": best_d, "a": best_at, "b": centre}


## One finding per (bus net, board item) pair whose copper is closer than the
## board's clearance allows, worst approach only — a leg running the length of a
## pad meets it in several segments and is one defect, not four.
##
## `polylines`/`widths` are bundle_routes' finished routes; `station_layer`,
## `splits` and `via_points` are its via station (empty/-1 for a single-layer
## bus), which is what makes each net's copper TWO runs on two layers plus a via
## that spans them. The station's own vias are measured too: they are bus copper
## and land on the board with everything else.
##
## THE BUS'S OWN NETS ARE NOT FOREIGN TO THEMSELVES but ARE foreign to each
## other — the live defect this exists for was one bus net's breakout leg run
## down a pad column through ANOTHER bus net's target pad. Track-against-track
## spacing stays BusGeom's job (FINDING_CLEARANCE); this pass only ever asks
## about copper already on the board.
static func _bus_foreign_copper_findings(data, nets: PackedStringArray, widths: Array,
		polylines: Array, layer: String, station_layer: String, splits: Array,
		via_points: Array, via_diameter: float, clearance: float) -> Array:
	if data == null or polylines.is_empty():
		return []
	var items: Array = _bus_board_copper(data)
	if items.is_empty():
		return []

	# Every piece of copper the bus itself puts down, as {net_index, points,
	# layer, half}. `half` is what that piece claims either side of the point it
	# is addressed by — a track's half-width, a via's radius — and an empty
	# `layer` means "the whole stack", which is what a through via is.
	var probes: Array = []
	var station_active: bool = not station_layer.is_empty() \
		and splits.size() == polylines.size() and via_points.size() == polylines.size()
	for i in range(polylines.size()):
		var poly: PackedVector2Array = polylines[i]
		var half: float = float(widths[i]) * 0.5
		var cut: int = int(splits[i]) if station_active else -1
		if cut < 1 or cut > poly.size() - 2:
			probes.append({"net_index": i, "points": poly, "layer": layer, "half": half})
			continue
		probes.append({"net_index": i, "points": poly.slice(0, cut + 1), "layer": layer, "half": half})
		probes.append({"net_index": i, "points": poly.slice(cut), "layer": station_layer, "half": half})
		var at: Vector2 = via_points[i]
		probes.append({"net_index": i, "points": PackedVector2Array([at, at]),
			"layer": "", "half": maxf(0.0, via_diameter) * 0.5})

	# key "<net index>|<item index>" -> the worst approach found for that pair.
	var worst: Dictionary = {}
	for raw_probe in probes:
		var probe: Dictionary = raw_probe
		var pts: PackedVector2Array = probe["points"]
		if pts.size() < 2:
			continue
		var index: int = int(probe["net_index"])
		var bus_net: String = str(nets[index])
		var half: float = float(probe["half"])
		var probe_layer: String = str(probe["layer"])
		var box: Rect2 = PcbTraceGeometry.bounds(pts).grow(
			half + maxf(0.0, clearance) + _BUS_FOREIGN_TOLERANCE_MM)
		for k in range(items.size()):
			var item: Dictionary = items[k]
			if str(item["net"]) == bus_net:
				continue
			if not _bus_item_on_layer(item, probe_layer):
				continue
			var item_box: Rect2 = item["bounds"]
			if not box.intersects(item_box):
				continue
			var best: Dictionary = {}
			for s in range(pts.size() - 1):
				var g: Dictionary = _bus_item_gap(item, pts[s], pts[s + 1])
				if best.is_empty() or float(g["distance"]) < float(best["distance"]):
					best = g
			var gap: float = float(best["distance"]) - half
			if gap >= maxf(0.0, clearance) - _BUS_FOREIGN_TOLERANCE_MM:
				continue
			var key := "%d|%d" % [index, k]
			if worst.has(key) and float((worst[key] as Dictionary)["gap"]) <= gap:
				continue
			worst[key] = {"gap": gap, "a": best["a"], "b": best["b"], "item": k,
				"net_index": index,
				"layer": probe_layer if not probe_layer.is_empty() else _bus_via_hit_layer(item, layer)}

	var out: Array = []
	for key in worst:
		out.append(_bus_foreign_finding(worst[key] as Dictionary, items, nets, clearance))
	return out


## ONE foreign-copper finding, in pcb_bus_geometry.gd's own finding shape plus
## the two machine-readable keys a caller would otherwise have to parse out of
## the prose (`foreign_ref`, `foreign_net`).
##
## `nets` holds ONLY the bus net, never the foreign one: it is the key the
## workspace files a finding under, and a bus net's ghost must not be handed a
## defect belonging to a net it is not carrying.
static func _bus_foreign_finding(hit: Dictionary, items: Array, nets: PackedStringArray,
		clearance: float) -> Dictionary:
	var item: Dictionary = items[int(hit["item"])]
	var bus_net: String = str(nets[int(hit["net_index"])])
	var gap: float = float(hit["gap"])
	var at_bus: Vector2 = hit["a"]
	var at_item: Vector2 = hit["b"]
	var run_layer: String = str(hit["layer"])
	var foreign_net: String = str(item["net"])
	var what := "%s %s (net \"%s\")" % [str(item["what"]), str(item["ref"]),
		foreign_net if not foreign_net.is_empty() else "(none)"]
	var caveat := ""
	if bool(item.get("centre_only", false)):
		caveat = " Measured to the pad CENTRE — this footprint carries no pad geometry, so the real copper reaches further than this figure says."
	var message := ""
	if gap <= _BUS_FOREIGN_TOLERANCE_MM:
		message = "Net \"%s\"'s bus copper lands on %s on %s at (%.3f, %.3f) — that is one piece of copper across two nets. Move the pad or the spine, pick a different pad, or take this net to another layer.%s" \
			% [bus_net, what, run_layer, at_item.x, at_item.y, caveat]
	else:
		message = "Net \"%s\"'s bus copper runs %.3fmm from %s on %s near (%.3f, %.3f) — this board's %.3fmm clearance needs that much bare board between two nets. Move the pad or the spine, or take this net to another layer.%s" \
			% [bus_net, gap, what, run_layer, at_item.x, at_item.y, maxf(0.0, clearance), caveat]
	return {
		"type": BUS_FINDING_FOREIGN_COPPER,
		"message": message,
		"nets": [bus_net],
		"measured_mm": gap,
		"required_mm": maxf(0.0, clearance),
		"layer": run_layer,
		"foreign_ref": str(item["ref"]),
		"foreign_net": foreign_net,
		"closest": [at_bus.x, at_bus.y],
		"witness": [at_item.x, at_item.y],
		"midpoint": [(at_bus.x + at_item.x) * 0.5, (at_bus.y + at_item.y) * 0.5],
	}


## PURE. The whole bus geometry pipeline in one place: per-net width
## resolution -> data.design_rule_clearance() -> BusGeom.pitch_between (via
## cumulative_offsets) -> the INNER-FOLD GUARD (pcb_bus_geometry.gd's own
## documented gap — "a caller must either refuse a spine with segments shorter
## than the widest offset, or accept the fold"; this tool layer refuses, never
## accepts the fold) -> BusGeom.bundle_routes, which returns each net's WHOLE
## polyline from its source pad to its target pad, breakout legs included.
##
## `nets` is the ORDERED net-name array — T11: this order is never re-sorted,
## by either this function or BusGeom underneath it; it is the caller's (the
## picker's, or the MCP arg's) order, verbatim.
##
## `source_pins`/`target_pins` are "Component.Pin" refs, one per net in the
## same order (see bus_pad_anchors for the net check they get).
##
## `target_pins` MAY BE EMPTY, and ONLY that: the INCOMPLETE plan the canvas
## previews while the path is still being drawn and no target has been picked
## yet. It carries the bundle's bare LANES (offset_polyline, no breakout legs)
## so the corridor can be drawn, and reports complete == false —
## bus_commit_plan and bus_propose_plan both refuse such a plan, so a bus that
## does not reach its pads cannot become copper or a candidate.
##
## `width_override`, when > 0.0, replaces the per-net auto-derived width for
## EVERY net (the MCP tools' optional uniform override — the canvas gesture
## never passes one, relying on bus_net_width's per-net derivation instead).
##
## `via_station_index` (>= 0) puts a VIA STATION on that vertex of
## `spine_points`: every track vias down there and continues on
## `via_station_layer`, which must be a declared copper layer other than
## `layer`. The via pad and drill come from the board's design_rules block. The
## plan then carries via_station_splits/via_station_points, the cut each net's
## polyline takes and the via centre it takes it at.
##
## OPEN ENDS: a `target_pins` entry of "" means that net has NO target — its
## track ends open at the end of its own lane (past the via, on the station
## layer, for a station bus) as a free end the Trace tool can continue from.
## The plan is still `complete` (it is committable) and carries `open_nets`,
## the names of those nets in bus order; findings are raised for landed nets
## exactly as before and never for a target that does not exist, while the open
## copper itself is still measured against the board like any other. An EMPTY
## target_pins stays the corridor-only preview and is not committable.
##
## `clean_order` (a pad-to-pad plan only) is the pick order the geometry found
## free of end crossings when this order has one — BusGeom.clean_pick_order,
## advisory words, nothing re-sorted — else empty.
##
## Returns {ok, buildable, findings, error, complete, nets, widths, offsets,
## polylines, layer, source_pins, target_pins, open_nets, clean_order,
## via_station_index,
## via_station_layer, via_station_points, via_station_splits, via_size_mm,
## via_drill_mm}.
##
## `ok` means CLEAN. `buildable` means geometry exists — false only for the
## refusals that leave nothing to draw (too few nets, an undeclared net, no
## layer, a spine of one point, an unresolvable or wrong-net pin, and
## bundle_routes' own unbuildable set including a diagonal spine). Everything
## else — the inner-fold guard, a pad inside the corridor, legs that cross at an
## end, a spine too short for its fan-outs, two nets inside their clearance —
## returns buildable with the polylines AND one entry in `findings` per broken
## rule.
##
## `error` stays the ONE string it always was: "" when clean, else the first
## finding's message, so a caller that shows the user one line shows the same
## line it used to.
static func bus_plan(data, nets: Array, spine_points: PackedVector2Array, layer: String,
		source_pins: PackedStringArray, target_pins: PackedStringArray,
		width_override: float = 0.0, via_station_index: int = -1,
		via_station_layer: String = "", advise_leave_open: bool = true) -> Dictionary:
	if nets.size() < 2:
		return _bus_unbuildable("A bus needs at least 2 nets (%d given)." % nets.size())
	var net_names := PackedStringArray()
	for net_name in nets:
		if not data.has_net(str(net_name)):
			return _bus_unbuildable("Net \"%s\" is not declared on this board." % str(net_name))
		net_names.append(str(net_name))
	if layer.is_empty():
		return _bus_unbuildable("No copper layer to place the bus on.")
	# LAYER MEMBERSHIP: the canvas gesture always hands this function a layer
	# that already passed trace_author_layer()'s own declared-stack check, so
	# this predicate is normally a no-op for it — but the MCP verbs' `layer`
	# arg is caller-supplied, untrusted text, the ONE
	# input this function does not otherwise validate before reaching
	# create_trace_entity. Checked HERE, in the one shared plan function,
	# rather than only in the MCP handler, so "same validation path" stays true
	# for both callers instead of the MCP path growing a second, parallel
	# check. Same predicate + wording as pcb_data.trace_author_error's own
	# layer clause (_create_zone's precedent: reuse the model's real refusal
	# wording rather than inventing one) — checked directly rather than through
	# that function so a garbage layer is named HERE, before any per-net width
	# work runs, instead of surfacing only once bus_commit_plan reaches the
	# first create_trace_entity call and wraps it in the generic "Bus was
	# refused by the board model on net %s" message.
	var declared_layers: Array = data.layers if data else []
	if not declared_layers.is_empty() and layer not in declared_layers:
		return _bus_unbuildable("Layer \"%s\" is not in the board's declared layer stack." % layer)
	# The station's SECOND layer gets the identical treatment, in the same one
	# shared place, for the same reason: the MCP verbs' arg is untrusted text.
	if via_station_index >= 0:
		if via_station_layer.is_empty():
			return _bus_unbuildable("A via station needs the copper layer the bus continues on past it.")
		if via_station_layer == layer:
			return _bus_unbuildable("A via station hands the bus to ANOTHER layer — \"%s\" is the one it is already on." % layer)
		if not declared_layers.is_empty() and via_station_layer not in declared_layers:
			return _bus_unbuildable("Layer \"%s\" is not in the board's declared layer stack." % via_station_layer)

	var cleaned := _bus_drop_duplicates(spine_points)
	if cleaned.size() < 2:
		return _bus_unbuildable("The bus spine needs at least 2 distinct points (%d given)." % spine_points.size())

	var widths: Array = []
	for net_name in nets:
		widths.append(width_override if width_override > 0.0 else bus_net_width(data, str(net_name)))
	var clearance: float = data.design_rule_clearance()
	var offsets: Array = BusGeom.cumulative_offsets(widths, clearance)
	# ONE rule for every via this plugin creates, so a via a bus drops and a via
	# a committed route drops measure the same on the same board.
	var via_dims: Dictionary = PcbViaDimensions.from_board(data)
	var via_size: float = via_dims["diameter"]
	var via_drill: float = via_dims["drill"]

	# INNER-FOLD FINDING. Checked against the WIDEST |offset| in the whole bus
	# (pcb_bus_geometry.gd's own wording), on the DEDUPLICATED spine — a
	# duplicate point is a zero-length segment offset_polyline drops silently,
	# not a fold (see _bus_drop_duplicates' doc). bundle_routes measures the
	# same end segments again after the fan-outs eat into them; this one runs
	# first because it is the wording that names the fold.
	var findings: Array = []
	var max_offset := 0.0
	for o in offsets:
		max_offset = maxf(max_offset, absf(float(o)))
	for i in range(cleaned.size() - 1):
		var seg_len: float = cleaned[i].distance_to(cleaned[i + 1])
		if seg_len < max_offset:
			findings.append({
				"type": BUS_FINDING_INNER_FOLD,
				"message": "Bus spine segment %d→%d (%.3fmm) is shorter than the widest track offset (%.3fmm) — the inner track would fold back on itself. Add a waypoint or widen this corner."
					% [i, i + 1, seg_len, max_offset],
				"nets": [],
				"measured_mm": seg_len,
				"required_mm": max_offset,
			})

	var sources: Dictionary = bus_pad_anchors(data, nets, source_pins, "source")
	if not bool(sources["ok"]):
		return _bus_unbuildable(str(sources["error"]))
	# A source leg is always on the plan's own layer, so this end is judged
	# before the targets exist and the preview can already say so.
	findings.append_array(_bus_pad_off_layer_findings(sources["pads"], layer, "source"))

	if target_pins.is_empty():
		var lanes: Array = []
		for offset in offsets:
			lanes.append(BusGeom.offset_polyline(spine_points, float(offset)))
		# The corridor-only preview draws LANES, which have no pads, no legs and
		# so no station to widen around — the station is echoed back for the
		# caller that is already drawing it, not built into this geometry.
		return _bus_planned(findings, layer, {
			"complete": false,
			"nets": nets.duplicate(), "widths": widths, "offsets": offsets,
			"polylines": lanes, "layer": layer,
			"source_pins": source_pins, "target_pins": PackedStringArray(),
			"via_station_index": -1, "via_station_layer": via_station_layer,
			"via_station_points": [], "via_station_splits": [],
			"via_size_mm": via_size, "via_drill_mm": via_drill,
		})

	if target_pins.size() != nets.size():
		return _bus_unbuildable("A bus needs one target pin per net (%d nets, %d target pins)." % [nets.size(), target_pins.size()])
	# The landed nets resolve their pads; an open net contributes a placeholder
	# point the geometry ignores and a flag it honours.
	var open_flags: Array = []
	var open_nets: Array = []
	var landed_nets: Array = []
	var landed_pins := PackedStringArray()
	for i in range(nets.size()):
		var is_open: bool = str(target_pins[i]).is_empty()
		open_flags.append(is_open)
		if is_open:
			open_nets.append(str(nets[i]))
		else:
			landed_nets.append(nets[i])
			landed_pins.append(target_pins[i])
	var targets: Dictionary = bus_pad_anchors(data, landed_nets, landed_pins, "target")
	if not bool(targets["ok"]):
		return _bus_unbuildable(str(targets["error"]))
	var target_points := PackedVector2Array()
	var landed_at: int = 0
	for i in range(nets.size()):
		if open_flags[i]:
			target_points.append(Vector2.ZERO)
		else:
			target_points.append((targets["points"] as PackedVector2Array)[landed_at])
			landed_at += 1

	var routed: Dictionary = BusGeom.bundle_routes(
		spine_points, net_names, sources["points"], target_points, widths, clearance,
		via_station_index, via_size if via_station_index >= 0 else 0.0,
		open_flags if not open_nets.is_empty() else [])
	if not bool(routed.get("buildable", false)):
		return _bus_unbuildable(str(routed.get("error", "The bus geometry was refused.")))
	findings.append_array(routed.get("findings", []) as Array)
	# The target legs run on whichever layer the bus is on when it gets there.
	findings.append_array(_bus_pad_off_layer_findings(targets["pads"],
		via_station_layer if via_station_index >= 0 else layer, "target"))
	# THE BOARD-AWARE PASS, and the only rule here that looks at anything other
	# than the bus. Runs LAST because it measures the FINISHED routes — legs,
	# lanes, station fans and the station's own vias — against the copper the
	# board already carries. The station index is read back off `routed`, not
	# off the argument: bundle_routes resolves it on the deduplicated spine.
	var routed_station: int = int(routed.get("via_station_index", -1))
	findings.append_array(_bus_foreign_copper_findings(data, net_names, widths,
		routed["polylines"], layer,
		via_station_layer if routed_station >= 0 else "",
		routed.get("via_station_splits", []) as Array,
		routed.get("via_station_points", []) as Array,
		via_size, clearance))
	if routed_station >= 0:
		var corridor_width: float = data.design_rule_trace_width()
		if corridor_width <= 0.0:
			corridor_width = data.authored_trace_width()
		findings.append_array(_bus_station_corridor_findings(data, net_names,
			routed.get("via_station_points", []) as Array, via_size, clearance,
			corridor_width, layer))
	# THE ORDER ADVISORY: only when a leg crosses at an end, and only as words —
	# the geometry's own permutation search, on the same spine and pads.
	var clean_order := PackedStringArray()
	var searched := false
	# The first TARGET-end crossing pair, whichever end's finding came first.
	var target_pair: Array = []
	for f in findings:
		if str((f as Dictionary).get("type", "")) != BusGeom.FINDING_END_CROSSING:
			continue
		if not searched:
			searched = true
			clean_order = BusGeom.clean_pick_order(spine_points, net_names,
				sources["points"], target_points, widths, clearance,
				via_station_index, via_size if via_station_index >= 0 else 0.0,
				open_flags if not open_nets.is_empty() else [])
		var pair: Array = (f as Dictionary).get("nets", []) if (f as Dictionary).get("nets", []) is Array else []
		if target_pair.is_empty() and str((f as Dictionary).get("end", "")) == "target" \
				and pair.size() == 2:
			target_pair = pair
	# NO CLEAN ORDER and a crossing at the TARGET end: the other end fixes the
	# order, so the way out is to land the rest and leave one net open — the
	# concrete targets array is the next call. VERIFIED, not assumed: the
	# reduced bus is re-planned (bus_plan is pure) and the advice is given
	# only when that plan carries no end crossing at all.
	var leave_open_net := ""
	var leave_open_targets := PackedStringArray()
	var leave_open_pair: Array = []
	if advise_leave_open and clean_order.is_empty() and not target_pair.is_empty():
		var way_out: Dictionary = _bus_leave_one_open(data, nets, spine_points, layer,
			source_pins, target_pins, width_override, via_station_index, via_station_layer,
			findings)
		leave_open_net = str(way_out.get("net", ""))
		leave_open_pair = way_out.get("pair", [])
		leave_open_targets = PackedStringArray(way_out.get("targets", PackedStringArray()))

	return _bus_planned(findings, layer, {
		"complete": true,
		"clean_order": clean_order,
		"leave_open_net": leave_open_net,
		"leave_open_pair": leave_open_pair,
		"leave_open_targets": leave_open_targets,
		"nets": nets.duplicate(), "widths": widths, "offsets": routed["offsets"],
		"polylines": routed["polylines"], "layer": layer,
		"source_pins": source_pins, "target_pins": target_pins, "open_nets": open_nets,
		"source_stations": routed["source_stations"], "target_stations": routed["target_stations"],
		"source_order": routed["source_order"], "target_order": routed["target_order"],
		# The index is the geometry's own — measured on the DEDUPLICATED spine,
		# so it can differ from the caller's when the spine carried a repeated
		# click.
		"via_station_index": int(routed.get("via_station_index", -1)),
		"via_station_layer": via_station_layer if via_station_index >= 0 else "",
		"via_station_points": routed.get("via_station_points", []),
		"via_station_splits": routed.get("via_station_splits", []),
		"via_size_mm": via_size, "via_drill_mm": via_drill,
	})


## The VIA STATION a plan carries, in the one form both writers need:
## {active, layer, splits, points, error}. `active` is false — and every other
## field empty — unless the plan really routed through a station, so neither
## writer re-derives "is this a two-layer bus" from three keys that could
## disagree. A plan that NAMES a station layer but whose splits or points do
## not line up with its nets, or whose cut would leave a run with one point, is
## an `error` rather than a silent single-layer bus: the writers refuse on it
## BEFORE touching the board, so a malformed plan can never throw mid-commit
## past the rollback.
static func _bus_station_runs(plan: Dictionary) -> Dictionary:
	var inactive := {"active": false, "layer": "", "splits": [], "points": [], "error": ""}
	var station_layer: String = str(plan.get("via_station_layer", ""))
	if station_layer.is_empty():
		return inactive
	var raw_splits: Variant = plan.get("via_station_splits", [])
	var raw_points: Variant = plan.get("via_station_points", [])
	var splits: Array = raw_splits if raw_splits is Array else []
	var points: Array = raw_points if raw_points is Array else []
	var polylines: Array = plan.get("polylines", [])
	var count: int = (plan.get("nets", []) as Array).size()
	if splits.size() != count or points.size() != count or polylines.size() != count:
		inactive["error"] = "Bus plan names via station layer %s but carries %d split(s) and %d via point(s) for %d net(s)." % [
			station_layer, splits.size(), points.size(), count]
		return inactive
	for i in range(count):
		var poly: PackedVector2Array = polylines[i]
		var cut: int = int(splits[i])
		if not (splits[i] is int) or not (points[i] is Vector2) or cut < 1 or cut > poly.size() - 2:
			inactive["error"] = "Bus plan's via station cut on net %s (index %s of %d points) leaves no copper on one side." % [
				str((plan.get("nets", []) as Array)[i]), str(splits[i]), poly.size()]
			return inactive
	return {"active": true, "layer": station_layer, "splits": splits, "points": points, "error": ""}


## Undo everything a half-finished bus put on the board. Vias as well as traces:
## a station's via is created between two of its net's traces, so a refusal on
## the SECOND run would otherwise leave a hole in copper nothing joins.
static func _bus_rollback(data, trace_ids: Array, via_ids: Array) -> void:
	for tid in trace_ids:
		data.remove_trace(str(tid))
	for vid in via_ids:
		data.remove_via_by_id(str(vid))


## The net to leave open so the rest of the bus lands with no end crossing,
## as {net, pair, targets} — or {} when no single open lane does it.
##
## Candidates, in order: the second net of the first target-end crossing
## pair, then the net that appears in the MOST target-end crossing pairs (the
## one every crossing shares, when they share one). Each candidate's reduced
## targets array is re-planned through bus_plan itself and accepted only when
## that plan has no end-crossing finding at either end — opening one net of
## one pair can leave another pair crossing, and advice that does not work is
## worse than none. `pair` is the first target-end crossing the chosen net is
## in, for the sentence.
static func _bus_leave_one_open(data, nets: Array, spine_points: PackedVector2Array,
		layer: String, source_pins: PackedStringArray, target_pins: PackedStringArray,
		width_override: float, via_station_index: int, via_station_layer: String,
		findings: Array) -> Dictionary:
	var pairs: Array = []
	var tally: Dictionary = {}
	for f in findings:
		if str((f as Dictionary).get("type", "")) != BusGeom.FINDING_END_CROSSING \
				or str((f as Dictionary).get("end", "")) != "target":
			continue
		var pair: Array = (f as Dictionary).get("nets", []) if (f as Dictionary).get("nets", []) is Array else []
		if pair.size() != 2:
			continue
		pairs.append(pair)
		for net in pair:
			tally[str(net)] = int(tally.get(str(net), 0)) + 1
	if pairs.is_empty():
		return {}
	var candidates: Array = [str((pairs[0] as Array)[1])]
	var most := ""
	for net in tally:
		if most.is_empty() or int(tally[net]) > int(tally[most]):
			most = str(net)
	if not most.is_empty() and not (most in candidates):
		candidates.append(most)
	for candidate in candidates:
		var idx: int = nets.find(candidate)
		if idx < 0 or idx >= target_pins.size() or target_pins[idx].is_empty():
			continue
		var reduced := PackedStringArray(target_pins)
		reduced[idx] = ""
		var replan: Dictionary = bus_plan(data, nets, spine_points, layer, source_pins,
			reduced, width_override, via_station_index, via_station_layer, false)
		if not bool(replan.get("buildable", false)):
			continue
		var crosses := false
		for f in replan.get("findings", []):
			if str((f as Dictionary).get("type", "")) == BusGeom.FINDING_END_CROSSING:
				crosses = true
				break
		if crosses:
			continue
		var pair_for_words: Array = pairs[0]
		for pair in pairs:
			if candidate in (pair as Array):
				pair_for_words = pair
				break
		return {"net": candidate, "pair": pair_for_words, "targets": reduced}
	return {}


## The gate every consumer of a bus plan passes it through before acting on
## it — commit, dry run and proposal alike: the plan must be buildable and
## COMPLETE (every target picked or deliberately open), and its via station,
## when it names one, coherent (_bus_station_runs). Returns {ok:true, station}
## or the {ok:false, error, findings:[]} refusal the caller returns verbatim.
static func _bus_gate(plan: Dictionary) -> Dictionary:
	if not bool(plan.get("ok", false)) and not bool(plan.get("buildable", false)):
		return {"ok": false, "error": str(plan.get("error", "Bus was refused.")), "findings": []}
	if not bool(plan.get("complete", false)):
		return {"ok": false, "error": _BUS_INCOMPLETE_PLAN, "findings": []}
	var station: Dictionary = _bus_station_runs(plan)
	if not str(station["error"]).is_empty():
		return {"ok": false, "error": str(station["error"]), "findings": []}
	return {"ok": true, "station": station}


## MUTATES. Takes any plan that HAS geometry — clean or bad-but-buildable — and
## lands it as copper. TRUSTS NOTHING: an UNBUILDABLE plan and an INCOMPLETE
## (corridor-only) plan are both refused here, so neither shape bus_plan can
## return that must not become copper can, whichever caller holds it.
##
## A bad-but-buildable plan lands its traces AND hands its `findings` back, so
## the caller can say what broke. That is the point of committing it: a rule
## broken on copper that exists can be corrected, and a refusal that lands
## nothing leaves nothing to correct.
##
## Creates one Trace entity per net via data.create_trace_entity (the
## SAME minted-id, fail-closed-if-refused path every other authoring tool on
## this board uses), then ONE save_to_history call for the whole batch — one
## journal step for the whole bus, one undo removes all N.
##
## A plan with a VIA STATION lands TWO traces and ONE through via per net
## instead: the polyline is cut at its via point, each half authored on its own
## layer, and the via added with data.add_via at the same through span
## minerva_pcb_place_via and every committed route use. That is the board's only
## representation of a run that changes layer — a Trace carries ONE layer — so a
## bus via is indistinguishable from any other via to DRC, Gerber and undo.
##
## FAIL-CLOSED MID-BATCH: create_trace_entity refusing net i is defensive
## (bus_plan already checked has_net/layer) but handled anyway — every trace
## already created THIS call is rolled back with data.remove_trace before
## returning, so a partial, un-journalled bus never sits on the board with no
## undo step able to remove it (nothing has been save_to_history'd yet; every
## add_trace so far is only in `traces`, not a journal entry the user can act
## on).
static func bus_commit_plan(data, plan: Dictionary, history_label: String) -> Dictionary:
	var gate: Dictionary = _bus_gate(plan)
	if not bool(gate["ok"]):
		return gate
	var nets: Array = plan.get("nets", [])
	var widths: Array = plan.get("widths", [])
	var polylines: Array = plan.get("polylines", [])
	var layer: String = str(plan.get("layer", ""))
	var station: Dictionary = gate["station"]
	var station_active: bool = bool(station["active"])
	var via_span: Array = PcbLayerStack.default_through_via_span()
	# ONE rule for every via this plugin creates: the plan's own numbers when it
	# carries them (bus_plan resolves them against this same board), else the
	# board's design_rules, else the constants.
	var station_via_dims: Dictionary = PcbViaDimensions.from_board(data,
		float(plan.get("via_size_mm", 0.0)), float(plan.get("via_drill_mm", 0.0)))
	var created_ids: Array[String] = []
	var created_via_ids: Array[String] = []
	# Per net, in bus order: the trace ids each net produced (one, or two
	# around a station) and its via id ("" without a station) — what the reply's
	# nets_detail is built from.
	var net_trace_ids: Array = []
	var net_via_ids: Array = []
	for i in range(nets.size()):
		var split: Dictionary = _bus_runs(polylines[i], layer, station, i)
		var runs: Array = split["runs"]
		var run_layers: Array = split["layers"]
		var mine: Array = []
		for r in range(runs.size()):
			var trace = data.create_trace_entity(
				str(nets[i]), str(run_layers[r]), runs[r], float(widths[i]))
			if trace == null:
				_bus_rollback(data, created_ids, created_via_ids)
				return {"ok": false, "error": "Bus was refused by the board model on net %s." % str(nets[i]), "findings": []}
			created_ids.append(str(trace.id))
			mine.append(str(trace.id))
		net_trace_ids.append(mine)
		net_via_ids.append("")
		if not station_active:
			continue
		var via_id := str(data.add_via({
			"position": (station["points"] as Array)[i],
			"net_name": str(nets[i]),
			"size": station_via_dims["diameter"],
			"drill": station_via_dims["drill"],
			"from_layer": str(via_span[0]), "to_layer": str(via_span[1]),
		}))
		if via_id.is_empty():
			_bus_rollback(data, created_ids, created_via_ids)
			return {"ok": false, "error": "The board model refused the via station on net %s." % str(nets[i]), "findings": []}
		created_via_ids.append(via_id)
		net_via_ids[i] = via_id
	data.save_to_history(history_label)
	# ONE journal row for the bus as a whole, after the per-trace add_trace rows
	# the model wrote: what stood at commit — the findings the author was shown
	# and landed anyway, the copper they name, and the ids this call created —
	# so the journal can answer "was that short reported?" after the fact.
	data.record_change("add_bus", _bus_journal_details(plan, created_ids, created_via_ids,
		layer, str(station["layer"])))
	return {"ok": true, "error": "", "trace_ids": created_ids, "via_ids": created_via_ids,
		"nets": nets, "widths": widths, "layer": layer,
		"via_station_layer": str(station["layer"]), "findings": plan.get("findings", []),
		"open_nets": (plan.get("open_nets", []) as Array).duplicate(),
		"nets_detail": bus_nets_detail(plan, station, net_trace_ids, net_via_ids),
		"clean_order": PackedStringArray(plan.get("clean_order", PackedStringArray()))}


## DRY RUN twin of bus_commit_plan: the SAME gates (buildable and complete, a
## coherent station) and the SAME reply shape, with nothing written — no trace,
## no via, no history step, no journal row. trace_ids/via_ids are empty and
## nets_detail carries the geometry with empty ids and a null free_end, exactly
## as a proposal's does. Lets an agent read a bus's findings, lane offsets and
## polylines before deciding to commit, propose a ghost, or redraw the spine.
static func bus_dry_run_plan(plan: Dictionary) -> Dictionary:
	var gate: Dictionary = _bus_gate(plan)
	if not bool(gate["ok"]):
		return gate
	var station: Dictionary = gate["station"]
	return {"ok": true, "error": "", "dry_run": true, "trace_ids": [], "via_ids": [],
		"nets": plan.get("nets", []), "widths": plan.get("widths", []),
		"layer": str(plan.get("layer", "")),
		"via_station_layer": str(station["layer"]), "findings": plan.get("findings", []),
		"open_nets": (plan.get("open_nets", []) as Array).duplicate(),
		"nets_detail": bus_nets_detail(plan, station, [], []),
		"clean_order": PackedStringArray(plan.get("clean_order", PackedStringArray()))}


## One net's polyline cut into the runs the board carries: {runs: [
## PackedVector2Array], layers: [String]} — the whole polyline on `layer`
## without a station, or two runs around the via (the cut vertex on both, so
## the via point is the first run's last point and the second's first) with
## the second on the station's layer. The ONE slicing rule behind the traces
## bus_commit_plan creates and the polylines bus_nets_detail reports.
static func _bus_runs(poly: PackedVector2Array, layer: String, station: Dictionary,
		index: int) -> Dictionary:
	if not bool(station.get("active", false)):
		return {"runs": [poly], "layers": [layer]}
	var cut: int = int((station["splits"] as Array)[index])
	return {"runs": [poly.slice(0, cut + 1), poly.slice(cut)],
		"layers": [layer, str(station["layer"])]}


## The per-net account of a bus, for the two bus verbs' replies: everything the
## NEXT verb needs, so an agent never has to export the board and hunt for the
## polyline that ends at the spine. One entry per net, in bus order:
##
##   net, lane_index (bus order, 0-based), offset_mm (the lane's signed offset
##   from the spine), source (the "Component.Pin" it left), landed (bool),
##   target (the pad ref it landed on, "" when open),
##   traces: [{trace_id, layer, points: [[x_mm, y_mm], ...]}] — one run, or two
##   around a via station, each run's points being EXACTLY the polyline the
##   board's trace carries; via_id ("" without a station) and via: [x, y];
##   and for an OPEN lane: free_end — {trace_id, end: "end"}, the very object
##   minerva_pcb_add_trace takes as its `start` anchor, so it can be passed
##   verbatim — plus free_end_x_mm / free_end_y_mm / free_end_layer for a
##   reader. A ghost (propose) run has no trace ids yet: trace_id and via_id are
##   "" and free_end is null, while the coordinates are still reported.
##
## `net_trace_ids[i]` is the id list for net i's runs (empty for a proposal);
## `net_via_ids[i]` its via id or "".
static func bus_nets_detail(plan: Dictionary, station: Dictionary,
		net_trace_ids: Array, net_via_ids: Array) -> Array:
	var nets: Array = plan.get("nets", [])
	var polylines: Array = plan.get("polylines", [])
	var offsets: Array = plan.get("offsets", [])
	var layer: String = str(plan.get("layer", ""))
	var open_nets: Array = plan.get("open_nets", []) if plan.get("open_nets", []) is Array else []
	var sources: PackedStringArray = PackedStringArray(plan.get("source_pins", PackedStringArray()))
	var targets: PackedStringArray = PackedStringArray(plan.get("target_pins", PackedStringArray()))
	var station_active: bool = bool(station.get("active", false))
	var out: Array = []
	for i in range(nets.size()):
		var split: Dictionary = _bus_runs(polylines[i], layer, station, i)
		var runs: Array = split["runs"]
		var run_layers: Array = split["layers"]
		var ids: Array = net_trace_ids[i] if i < net_trace_ids.size() else []
		var traces: Array = []
		for r in range(runs.size()):
			var pts: Array = []
			for pt in (runs[r] as PackedVector2Array):
				pts.append([_mm(pt.x), _mm(pt.y)])
			traces.append({"trace_id": str(ids[r]) if r < ids.size() else "",
				"layer": str(run_layers[r]), "points": pts})
		var net: String = str(nets[i])
		var landed: bool = not (net in open_nets)
		var entry: Dictionary = {
			"net": net, "lane_index": i,
			"offset_mm": _mm(float(offsets[i])) if i < offsets.size() else 0.0,
			"source": sources[i] if i < sources.size() else "",
			"landed": landed,
			"target": (targets[i] if i < targets.size() else "") if landed else "",
			"traces": traces,
			"via_id": str(net_via_ids[i]) if i < net_via_ids.size() else "",
		}
		if station_active:
			var at: Vector2 = (station["points"] as Array)[i]
			entry["via"] = [_mm(at.x), _mm(at.y)]
		if not landed:
			# The open lane ends where its LAST run ends — past the station when
			# there is one — so that run's "end" end is the free end.
			var last: Dictionary = traces[traces.size() - 1]
			var last_pt: Vector2 = (runs[runs.size() - 1] as PackedVector2Array)[
				(runs[runs.size() - 1] as PackedVector2Array).size() - 1]
			var tid: String = str(last["trace_id"])
			entry["free_end"] = {"trace_id": tid, "end": "end"} if not tid.is_empty() else null
			entry["free_end_x_mm"] = _mm(last_pt.x)
			entry["free_end_y_mm"] = _mm(last_pt.y)
			entry["free_end_layer"] = str(last["layer"])
		out.append(entry)
	return out


## The `details` of a bus commit's journal row: {nets, open_nets, layer,
## via_station_layer, trace_ids, via_ids, finding_count, finding_types:
## {type: count}, findings: [{type, nets, layer, foreign_ref?, pad_ref?}]}.
## `open_nets` names the nets whose track ended open, in bus order. Findings are summarised to
## their machine-readable keys rather than carried whole — the prose is what the
## status line and verb reply already showed; the journal keeps the facts.
static func _bus_journal_details(plan: Dictionary, trace_ids: Array, via_ids: Array,
		layer: String, via_station_layer: String) -> Dictionary:
	var findings: Array = plan.get("findings", []) if plan.get("findings", []) is Array else []
	var types: Dictionary = {}
	var summary: Array = []
	for raw in findings:
		var f: Dictionary = raw
		var type := str(f.get("type", ""))
		types[type] = int(types.get(type, 0)) + 1
		var row: Dictionary = {"type": type, "nets": f.get("nets", []),
			"layer": str(f.get("layer", ""))}
		for key in ["foreign_ref", "foreign_net", "pad_ref"]:
			if f.has(key):
				row[key] = f[key]
		summary.append(row)
	return {
		"nets": (plan.get("nets", []) as Array).duplicate(),
		"open_nets": (plan.get("open_nets", []) as Array).duplicate(),
		"layer": layer,
		"via_station_layer": via_station_layer,
		"trace_ids": trace_ids.duplicate(),
		"via_ids": via_ids.duplicate(),
		"finding_count": findings.size(),
		"finding_types": types,
		"findings": summary,
	}


## GHOST twin of bus_commit_plan: the SAME plan and the SAME gate (buildable
## and complete), but the N pad-to-pad traces land as workspace RouteCandidates
## (one per net, disposition "proposed") instead of board copper. NOTHING is
## journalled and the board is not mutated — resolution happens through the
## normal workspace
## verbs (minerva_pcb_workspace_commit/_reject/pin, or the canvas candidate
## menu), so a bus participates in the propose → steer → accept loop instead of
## being the one author verb that bypassed it.
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
##
## A BAD-BUT-BUILDABLE plan proposes too, and each ghost is handed the findings
## that name its net through the workspace's own per-candidate findings channel
## — the same store a draft-check reply writes and the canvas draws witnesses
## from, so a bus violation is visible on the ghost without a worker round trip.
static func bus_propose_plan(workspace, data, plan: Dictionary) -> Dictionary:
	if workspace == null:
		return {"ok": false, "error": "no routing workspace is bound to this panel (headless / before mount)"}
	var gate: Dictionary = _bus_gate(plan)
	if not bool(gate["ok"]):
		return gate
	var findings: Array = plan.get("findings", []) if plan.get("findings", []) is Array else []
	var nets: Array = plan.get("nets", [])
	var widths: Array = plan.get("widths", [])
	var polylines: Array = plan.get("polylines", [])
	var layer: String = str(plan.get("layer", ""))
	var revision: int = int(data.board_revision) if data != null else 0
	var station: Dictionary = gate["station"]
	var landed: Array = []
	var holds: Array = []
	for i in range(nets.size()):
		var poly: PackedVector2Array = polylines[i]
		# Segment j runs poly[j]→poly[j+1], so the cut index is the FIRST
		# segment on the far side of the via.
		var cut: int = int((station["splits"] as Array)[i]) if bool(station["active"]) else -1
		var segs: Array = []
		for j in range(poly.size() - 1):
			segs.append({
				"start": [poly[j].x, poly[j].y],
				"end": [poly[j + 1].x, poly[j + 1].y],
				"layer": layer if (cut < 0 or j < cut) else str(station["layer"]),
			})
		var ghost_vias: Array = []
		if cut >= 0:
			var at: Vector2 = (station["points"] as Array)[i]
			ghost_vias.append([at.x, at.y])
		var rec: Dictionary = {
			"net": str(nets[i]),
			"segments": segs,
			"vias": ghost_vias,
			"source_hints": [],
			"source_hint_ids": [],
			"width_override": float(widths[i]),
		}
		var cid: String = str(workspace.ingest_record(rec, revision, data))
		# last_ingest_holds is PER CALL and ingest_record resets it on entry —
		# accumulate in-loop, same as _ingest_result_into_workspace.
		for hold in workspace.last_ingest_holds:
			holds.append(hold)
		if cid.is_empty():
			continue
		var mine: Array = _bus_findings_for_candidate(findings, str(nets[i]), cid)
		if not mine.is_empty() and workspace.has_method("set_findings"):
			workspace.set_findings(cid, mine)
		landed.append(_candidate_record(workspace, workspace.get_candidate(cid)))
	# Ghosts have no trace or via ids yet; the coordinates are still the
	# geometry the next verb will need, keyed to its candidate.
	var detail: Array = bus_nets_detail(plan, station, [], [])
	for i in range(detail.size()):
		var cid := ""
		for c in landed:
			if str((c as Dictionary).get("net", "")) == str((detail[i] as Dictionary)["net"]):
				cid = str((c as Dictionary).get("candidate_id", ""))
		(detail[i] as Dictionary)["candidate_id"] = cid
	return {
		"ok": true, "error": "",
		"proposed": landed.size(), "candidates": landed, "holds": holds,
		"nets": nets, "widths": widths, "layer": layer,
		"via_station_layer": str(station["layer"]), "findings": findings,
		"open_nets": (plan.get("open_nets", []) as Array).duplicate(),
		"nets_detail": detail,
	}


## The plan findings that belong on ONE ghost, stamped with its subject.
##
## A finding naming nets takes only the ghosts it names; a finding naming none
## (a spine rule — it doubles back, it is shorter than its own fan-outs) belongs
## to every track riding that spine, so it goes on all of them. `subjects` is
## the key the workspace's own finding readers key off, so it is written here
## rather than left for a consumer to infer from the candidate it was filed
## under.
static func _bus_findings_for_candidate(findings: Array, net_name: String, cid: String) -> Array:
	var out: Array = []
	for raw in findings:
		var f: Dictionary = raw as Dictionary
		var nets: Array = f.get("nets", []) if f.get("nets", []) is Array else []
		if not nets.is_empty() and not (net_name in nets):
			continue
		var copy: Dictionary = f.duplicate(true)
		copy["subjects"] = [{"candidate_id": cid, "net": net_name}]
		out.append(copy)
	return out


## Every finding's own words, in one line — the form both bus verbs and the
## canvas gesture report a bad-but-buildable bus with, so agent and human are
## told the same thing.
static func bus_findings_sentence(findings: Array) -> String:
	var parts := PackedStringArray()
	for raw in findings:
		parts.append(str((raw as Dictionary).get("message", "")))
	return " · ".join(parts)


## Shared arg → plan parsing for the two bus MCP handlers (_route_bus_direct
## and _workspace_propose_bus): ordered nets + spine points + one source and one
## target pad per net + layer + width_override + the optional via station, then
## bus_plan. Returns
## bus_plan's own {ok, error, ...} shape so a parse refusal and a plan refusal
## surface identically.
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

	var sources = _bus_pin_refs(args.get("sources"))
	if sources == null:
		return {"ok": false, "error": "sources is required: one \"Component.Pin\" pad per net, in the same order as nets — the pad each track leaves from."}
	var targets = _bus_pin_refs(args.get("targets"))
	if targets == null:
		return {"ok": false, "error": "targets is required: one \"Component.Pin\" pad per net, in the same order as nets — the pad each track runs to, or \"\" to leave that net's lane ending open."}

	var layer: String = str(args.get("layer", ""))
	if layer.is_empty():
		var declared: Array = data.layers if data else []
		if declared.size() == 1:
			layer = str(declared[0])
		else:
			return {"ok": false, "error": "layer is required (the board declares %d copper layers, not exactly 1)." % declared.size()}

	var width_override: float = float(args.get("width_override", 0.0))

	# THE VIA STATION IS ONE FACT IN TWO ARGUMENTS, so half of it is refused
	# rather than half-honoured: an index with no layer would silently plan a
	# single-layer bus, and a layer with no index a bus whose second layer
	# nothing ever reaches.
	var station_index := -1
	var station_layer := ""
	if args.has("via_station_index") or args.has("via_station_layer"):
		if not args.has("via_station_index") or not args.has("via_station_layer"):
			return {"ok": false, "error": "a via station needs BOTH via_station_index (which spine vertex carries it) and via_station_layer (the copper layer the bus continues on past it)."}
		var raw_station: Variant = args.get("via_station_index")
		# JSON numbers arrive as floats; only an integral one names a vertex.
		if not (raw_station is int or raw_station is float) or int(raw_station) < 0 \
				or float(raw_station) != floorf(float(raw_station)):
			return {"ok": false, "error": "via_station_index must be a non-negative integer index into points"}
		station_index = int(raw_station)
		station_layer = str(args.get("via_station_layer", ""))

	return bus_plan(data, nets, pts, layer, sources, targets, width_override,
		station_index, station_layer)


## Parse an MCP pin-ref array ("U1.1", ...) into a PackedStringArray, or null
## when the key is absent or not an array of refs. NULL IS NOT AN EMPTY ARRAY
## here: an empty target_pins is bus_plan's legal "corridor only, do not
## commit" input, which no MCP caller may reach — both verbs write, and a
## missing key has to refuse, not silently plan a bus that stops short of the
## pads.
static func _bus_pin_refs(raw) -> Variant:
	if not (raw is Array) or (raw as Array).is_empty():
		return null
	var refs := PackedStringArray()
	for r in (raw as Array):
		refs.append(str(r))
	return refs


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
	if not bool(plan.get("buildable", false)):
		return _err(str(plan.get("error", "Bus was refused.")))

	var out: Dictionary = bus_propose_plan(workspace, data, plan)
	if not bool(out.get("ok", false)):
		return _err(str(out.get("error", "Bus proposal was refused.")))

	var findings: Array = out.get("findings", []) if out.get("findings", []) is Array else []
	var reply: Dictionary = {
		"proposed": out.get("proposed", 0),
		"candidates": out.get("candidates", []),
		"holds": out.get("holds", []),
		"nets": out.get("nets", []),
		"widths": out.get("widths", []),
		"layer": str(out.get("layer", "")),
		"via_station_layer": str(out.get("via_station_layer", "")),
		"findings": findings,
		"open_nets": out.get("open_nets", []),
		"nets_detail": out.get("nets_detail", []),
		"note": "ghost candidates landed in the routing workspace; no copper was committed — resolve via minerva_pcb_workspace_commit/_reject/pin.",
	}
	if not findings.is_empty():
		reply["note"] = "%d bus rule(s) broke and the ghosts were proposed anyway so they can be corrected: %s. Nothing was committed — resolve via minerva_pcb_workspace_commit/_reject/pin." \
			% [findings.size(), bus_findings_sentence(findings)]
		_add_leave_one_open(reply, plan)
	var open_words: String = PcbBusLabels.bus_open_sentence(out.get("open_nets", []) as Array)
	if not open_words.is_empty():
		reply["note"] = "%s %s" % [str(reply["note"]), open_words]
	var cross: Dictionary = await _cross_candidate_check(host, workspace, data)
	if not cross.is_empty():
		reply["cross_candidate_check"] = cross
		if not (cross.get("findings", []) as Array).is_empty():
			reply["note"] = str(reply["note"]) \
				+ "; WARNING: the set-scoped check found findings across the live candidate set — see cross_candidate_check"
		elif cross.has("geometric_indeterminate"):
			reply["note"] = str(reply["note"]) \
				+ "; WARNING: the set-scoped check could not verify geometry — see cross_candidate_check"
	return _ok(reply)


## ── Epoch UX1 station 8 (DCR 019fd095e694, converged docket 019fd057ea0b
## comment 1028): minerva_pcb_add_route_intent — ONE authoring call, ONE
## router round-trip preserved (comment 1027's scenario requirement), clean
## object ownership preserved (comment 1026's requirement) by EAGER TASK
## CREATION rather than by putting steering back on the connectivity object.
##
## Atomically, with NO routing performed:
##   (a) a pcb_route_hint annotation — CONNECTIVITY ONLY. source_pins/dest_pins
##       + note; waypoints is ALWAYS [] here, by construction — corridor never
##       lands on this object (the "duplicated authority" hazard 1028 rejected).
##   (b) an eagerly-created RouteTask in the workspace, task_id "NET|hint_id"
##       (the SAME key format _task_key/_create_candidate_for_route mint at
##       ingest — see pcb_routing_workspace.gd — so a later propose of this
##       hint supersedes THIS task rather than minting a duplicate), via
##       RoutingWorkspace.ensure_task (reused, not reimplemented).
##   (c) when `corridor` is given, a routing_constraint STORED on that task
##       (PcbRouteTask.routing_constraint) — revision 1, authored_by "ai",
##       base_board_revision stamped from the board's CURRENT revision. This
##       station only CREATES + ROUND-TRIPS the constraint; CONSUMPTION —
##       minerva_pcb_workspace_propose/_workspace_reroute_route reading it to
##       steer the router — is Epoch UX1 station 9 (_route_request_extra /
##       _task_constraints_for_hints below; see PcbRouteTask's own field doc).
##
## Refused BY NAME before anything is created: an unresolvable pin
## ("pin_unresolvable"), pins that don't share one net ("cross_net_pins"), more
## than one endpoint per side ("single_endpoint_only" — this tool's signature
## only accepts one source_pin/dest_pin string; a caller that sends an array is
## refused rather than silently taking the first), or no live workspace
## ("workspace_unavailable", via _workspace_ctx).
## Validation half of _add_route_intent, factored (DCR 01a022ab356c leg B) so
## span-propose can validate EVERY span before minting ANY — atomic across
## both stores. Pure: touches neither annotations nor tasks. Returns
## {ok:true, source_pin, dest_pin, source_resolved, dest_resolved, net,
## corridor_points, width_mm} — or, on refusal, the EXACT error dict
## _add_route_intent always returned, VERBATIM (shapes are pinned by suites;
## callers detect refusal by the absent "ok" key).
static func _validate_route_intent(data, args: Dictionary) -> Dictionary:
	if args.get("source_pin", "") is Array or args.get("dest_pin", "") is Array:
		return {
			"success": false, "error": "single_endpoint_only",
			"note": "minerva_pcb_add_route_intent accepts exactly one source_pin and one dest_pin string — multi-endpoint routing is not expressed by this tool",
		}

	var source_pin: String = str(args.get("source_pin", "")).strip_edges()
	var dest_pin: String = str(args.get("dest_pin", "")).strip_edges()
	if source_pin.is_empty():
		return _err("source_pin is required")
	if dest_pin.is_empty():
		return _err("dest_pin is required")

	var source_resolved: Dictionary = _resolve_route_intent_pin(data, source_pin)
	if not bool(source_resolved.get("ok", false)):
		return {
			"success": false, "error": "pin_unresolvable", "which": "source",
			"pin_ref": source_pin, "note": str(source_resolved.get("message", "")),
		}
	var dest_resolved: Dictionary = _resolve_route_intent_pin(data, dest_pin)
	if not bool(dest_resolved.get("ok", false)):
		return {
			"success": false, "error": "pin_unresolvable", "which": "dest",
			"pin_ref": dest_pin, "note": str(dest_resolved.get("message", "")),
		}

	var source_net: String = str(data.find_net_for_pin(source_resolved["component"], source_resolved["pin"]))
	if source_net.is_empty():
		return {
			"success": false, "error": "pin_unresolvable", "which": "source",
			"pin_ref": source_pin, "note": "pin '%s' is not connected to any net" % source_pin,
		}
	var dest_net: String = str(data.find_net_for_pin(dest_resolved["component"], dest_resolved["pin"]))
	if dest_net.is_empty():
		return {
			"success": false, "error": "pin_unresolvable", "which": "dest",
			"pin_ref": dest_pin, "note": "pin '%s' is not connected to any net" % dest_pin,
		}
	if source_net != dest_net:
		return {
			"success": false, "error": "cross_net_pins",
			"source_pin": source_pin, "dest_pin": dest_pin,
			"source_net": source_net, "dest_net": dest_net,
			"note": "source_pin (net '%s') and dest_pin (net '%s') are not on the same net — an intent connects two pins already on ONE net; connect them first (minerva_pcb_connect_net) if that is what you mean" % [source_net, dest_net],
		}
	var net: String = source_net

	var corridor_points: Variant = null
	if args.has("corridor"):
		# SECONDARY (cold review): refuse by ARGUMENT PRESENCE, matching this
		# file's own P2 convention (_workspace_commit's candidate_ids:[] check
		# above) — corridor:[] is a caller stating "steer with an empty
		# corridor", which is not the same ask as omitting the key entirely
		# ("no corridor"), so it gets its own named refusal rather than
		# silently degrading to "no corridor" or minting a zero-point constraint.
		var raw_corridor: Variant = args.get("corridor")
		if raw_corridor is Array and (raw_corridor as Array).is_empty():
			return _err("corridor present but empty")
		corridor_points = _parse_route_intent_corridor(raw_corridor)
		if corridor_points == null:
			return _err("corridor must be an array of {x_mm, y_mm} points")

	# Optional trace width (Epoch UX2 station 3, docket 019fde363162): width is
	# part of ROUTING INTENT — HITL-5 needed three wholesale kind_payload
	# patches per width change because only the intent tool never exposed the
	# end-to-end plumbing that already exists (kind_payload.width_mm →
	# route_bridge._width_from_hints → candidate width_mm + width_source:
	# "hint"). Validated here, landed on the minted hint's kind_payload below.
	var width_mm: Variant = null
	if args.has("width_mm"):
		var raw_width: Variant = args.get("width_mm")
		if not (raw_width is float or raw_width is int) or float(raw_width) <= 0.0:
			return {
				"success": false, "error": "invalid_width",
				"note": "width_mm must be a positive number (trace width in mm) — omit the key entirely for the net class default",
			}
		width_mm = float(raw_width)

	return {"ok": true, "source_pin": source_pin, "dest_pin": dest_pin,
		"source_resolved": source_resolved, "dest_resolved": dest_resolved,
		# width_mm is NOT quantized here and must not be: this is an internal
		# validation result, not a reply, and null is a load-bearing sentinel
		# ("no width given — use the net class default"). _mm takes a float, so
		# snapping it both crashes on the sentinel and would destroy it.
		"net": net, "corridor_points": corridor_points, "width_mm": width_mm}


static func _add_route_intent(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]
	var data = ctx["data"]

	var v: Dictionary = _validate_route_intent(data, args)
	if not bool(v.get("ok", false)):
		return v
	var source_pin: String = v["source_pin"]
	var dest_pin: String = v["dest_pin"]
	var source_resolved: Dictionary = v["source_resolved"]
	var dest_resolved: Dictionary = v["dest_resolved"]
	var net: String = v["net"]
	var corridor_points: Variant = v["corridor_points"]
	var width_mm: Variant = v["width_mm"]

	# ── (a) the connectivity annotation — NO waypoints, ever, by construction ──
	var source_comp = source_resolved["comp"]
	var anchor_pos: Vector2 = source_comp.get_pin_world_position(str(source_resolved["pin"]))
	var note: String = str(args.get("note", ""))
	# AUTHOR pass-through (Epoch UX3 station 8a): the pad→pad canvas gesture
	# delegates here, and the human's own act must not mint an "ai" hint —
	# authorship drives rendering color and clear-by-author scoping. Default
	# stays "ai" (the agent's tool); only an explicit "human" flips it.
	var author: String = "human" if str(args.get("author", "")) == "human" else "ai"
	var envelope: Dictionary = host.build_route_hint_envelope(
		anchor_pos.x, anchor_pos.y, note, "F.Cu", "waypoint", [], author, "", width_mm,
		[source_pin], [dest_pin])
	# dest_point: the SAME commit-time-resolved render/hit-test cache the
	# single-trace tool stamps (see pcb_route_hint_kind.gd's rationale —
	# hit_test/bounds have no host to resolve dest_pins live). Station 8a made
	# the pad→pad gesture delegate HERE, so the intent must render and
	# hit-test as the drawn line the gesture promises; agent-authored intents
	# gain the same visible line for free. Same accepted-staleness tradeoff.
	var dest_comp = dest_resolved["comp"]
	var dest_pos: Vector2 = dest_comp.get_pin_world_position(str(dest_resolved["pin"]))
	var intent_kp: Dictionary = _dict_or_empty(envelope.get("kind_payload"))
	intent_kp["dest_point"] = [dest_pos.x, dest_pos.y]
	envelope["kind_payload"] = intent_kp
	_maybe_stamp_annotation_ref(envelope)
	var ref: String = str(envelope.get("ref", ""))
	var hint_id: String = host.add_annotation_v2(envelope)
	if hint_id.is_empty():
		return {
			"success": false, "error": "annotation_rejected",
			"note": "the host rejected the route-hint envelope (validation failed) — no intent, task or constraint was created",
		}

	# ── (b) eager task creation — SAME key format ingest mints, reused verbatim ──
	var task_id: String = "%s|%s" % [net, hint_id]
	var task = workspace.ensure_task(task_id, net)

	# ── (c) optional task-owned constraint — NEVER on the annotation ───────────
	var constraint_revision: Variant = null
	if corridor_points is Array and (corridor_points as Array).size() > 0:
		task.routing_constraint = {
			"corridor_points": corridor_points,
			"preferred_layer": "",
			"revision": 1,
			"authored_by": "ai",
			"base_board_revision": int(data.board_revision),
			# F3 (cold review): this task is minted with EXACTLY one hint
			# ("net|hint_id" — see (b) above), so ownership is unambiguous at
			# creation. _task_constraints_for_hints (station 9's consumption
			# side) emits this constraint ONLY under this exact hint id.
			"owner_hint_id": hint_id,
		}
		constraint_revision = 1

	var reply: Dictionary = {
		"hint_id": hint_id,
		"task_id": task_id,
		"net": net,
	}
	if not ref.is_empty():
		reply["ref"] = ref
	if constraint_revision != null:
		reply["constraint_revision"] = constraint_revision
	# UX2 station 3: echo the landed width so the caller sees the intent took
	# — the propose reply then closes the loop with width_source:"hint".
	if width_mm != null:
		reply["width_mm"] = width_mm
	# Epoch UX1 station 11: normalized through the shared _next_steps helper
	# (same "route_intent" text as before, byte-identical) rather than built
	# inline here.
	reply["note"] = _next_steps("route_intent", {"hint_id": hint_id, "constraint_revision": constraint_revision})
	return _ok(reply)


## Parse an MCP pin ref "Component.Pin" against the board model. Returns
## {ok:true, component, pin, comp} or {ok:false, message}. Mirrors
## _get_pin_position's ref-splitting convention (rfind(".") — a pin name can
## itself be dotted, so only the LAST dot separates component from pin).
static func _resolve_route_intent_pin(data, ref: String) -> Dictionary:
	var dot := ref.rfind(".")
	if dot <= 0 or dot >= ref.length() - 1:
		return {"ok": false, "message": "malformed pin ref '%s' — expected 'Component.Pin'" % ref}
	var component := ref.left(dot)
	var pin := ref.substr(dot + 1)
	var comp = data.get_component(component)
	if comp == null:
		return {"ok": false, "message": "component not found: %s" % component}
	if not comp.pins.has(pin):
		return {"ok": false, "message": "pin '%s' not found on component '%s'" % [pin, component]}
	return {"ok": true, "component": component, "pin": pin, "comp": comp}


## Parse an MCP corridor arg ([{x_mm,y_mm}, ...]) into an Array[Vector2], or
## null when malformed. Mirrors _parse_zone_outline's convention (same wire
## shape, x_mm/y_mm points) but returns a plain Array rather than a
## PackedVector2Array — PcbRouteTask.routing_constraint stores corridor_points
## the same open-Array-of-Vector2 way span stores its "from"/"to" points.
static func _parse_route_intent_corridor(raw) -> Variant:
	if not (raw is Array):
		return null
	var pts: Array = []
	for p in raw:
		if not (p is Dictionary) or not p.has("x_mm") or not p.has("y_mm"):
			return null
		pts.append(Vector2(float(p["x_mm"]), float(p["y_mm"])))
	return pts


## ── Epoch UX1 station 10 (DCR 019fd095e694, docket 019fd057ea0b comments
## 1026/1028): minerva_pcb_workspace_edit_candidate — the ONE discriminated
## candidate-GEOMETRY-edit verb (Codex Q4: "ADD one candidate-edit tool with a
## discriminated operation … backed by shared RoutingWorkspace methods", not a
## family of independent verbs that would each cost a tool-budget slot).
##
## EDIT != POLICY. This tool touches ONLY the named candidate's own geometry —
## never the candidate's task, never its routing_constraint. A caller who wants
## an edited shape to survive the NEXT re-propose reroutes with
## minerva_pcb_workspace_reroute_route's preserve_shape_as_corridor:true (Epoch
## UX1 station 9) — a separate, visible decision, not a side effect of editing a
## draft. NO AUTO-PIN either (comment 1026 Q5): editing a candidate does not
## hold it against ingest; pin is its own explicit verb.
##
## op == "move_junction": args point:[x_mm,y_mm], to:[x_mm,y_mm]. Junction
## IDENTITY, not a flattened bend index (see RoutingWorkspace.move_junction's
## own header for the full docket 1026 rationale) — every segment endpoint AND
## via coincident with `point` moves atomically to `to`. Refused BY NAME:
## junction_not_found (nothing coincident with point), ambiguous_junction
## (point matches junctions on more than one of this candidate's disconnected
## paths — see INV-3's own header on why a candidate can carry more than one),
## degenerate_result (the move would collapse a segment to zero length — never
## emitted, docket 019f9cc3245d).
##
## op == "insert_via": args position:[x_mm,y_mm], from_layer, to_layer.
## DELEGATES to RoutingWorkspace.add_via — the EXISTING path-scoped via/layer
## edit entry INV-3 names — verbatim, not reimplemented. Its own named
## refusals (illegal_via_span, no_segment_at_point, degenerate_insert_at_endpoint,
## degenerate_insert_on_via, segment_locked, from_layer_mismatch,
## continuation_layer_not_copper) pass through unchanged.
##
## SINCE EPOCH NLC C1b, `to_layer` is the layer THE RUN CONTINUES ON, not an end
## of the via's span — a v1 via is always a through via and its recorded span is
## always top<->bottom whatever the stack depth. `to_layer` may therefore name
## ANY copper layer, inner ones included; it previously could not, because the
## value was tested with is_legal_via_span, whose STACK_INDEX holds only
## {"top","bottom"} and so refused every inner continuation on every board.
## illegal_via_span now means only "this via would change nothing" (to_layer
## equals the layer the run is already on). The reply reports the run's
## from_layer/to_layer AND the hole's via_span separately, because they were one
## value before this station and a reader must not infer either from the other.
##
## This verb is currently the ONLY way to place a via whose run continues on an
## inner layer: the canvas gesture can resolve the outer pair by itself but has
## no layer picker, so it refuses an inner-layer run with a toast naming this
## verb. That picker is station C2's (the via tool).
##
## CONCURRENCY (comment 1026 Q5, symmetric with station 9's
## expected_constraint_revision): `expected_candidate_revision`, when given, is
## checked against the candidate's CURRENT candidate_revision BEFORE either op
## runs — a mismatch refuses candidate_revision_conflict {expected, actual} and
## mutates nothing. A successful edit bumps candidate_revision (both model
## methods do this themselves, mirrored from add_via's own bump) — a caller
## chaining a second edit passes the NEW revision this reply reports, not the
## one it read before this call.
##
## Both ops refuse a TERMINAL candidate (committed/rejected/superseded) by name
## — a terminal candidate is a record, not a draft, the same rule add_via
## already enforced before this station existed. Both ops ALSO refuse a
## FROZEN candidate (candidate_frozen, Epoch UX3 station 1): settled geometry
## is live but locked, and the remedy is minerva_pcb_workspace_unfreeze, not
## a re-propose.
static func _workspace_edit_candidate(host, args: Dictionary) -> Dictionary:
	var ctx: Dictionary = _workspace_ctx(host)
	if not bool(ctx.get("ok", false)):
		return ctx.get("reply")
	var workspace = ctx["ws"]

	var cid: String = str(args.get("candidate_id", ""))
	if cid.is_empty():
		return _err("candidate_id is required")
	var op: String = str(args.get("op", ""))
	if op.is_empty():
		return _err("op is required")
	if not (op in ["move_junction", "insert_via"]):
		return {
			"success": false, "error": "unknown_op", "op": op, "candidate_id": cid,
			"note": "op must be one of: move_junction, insert_via",
		}

	var c = workspace.get_candidate(cid)
	if c == null:
		return {"success": false, "error": "candidate_not_found", "candidate_id": cid}

	# CONCURRENCY, before ANY mutation and before either op's own model-side
	# checks run — mirrors _steer_task_before_reroute's expected_constraint_revision
	# guard (station 9), the candidate-scoped twin of that task-scoped one.
	if args.has("expected_candidate_revision"):
		var expected: int = int(args.get("expected_candidate_revision"))
		var actual: int = int(c.candidate_revision)
		if expected != actual:
			return {
				"success": false, "error": "candidate_revision_conflict",
				"candidate_id": cid,
				"expected_candidate_revision": expected,
				"actual_candidate_revision": actual,
				"note": "this candidate's geometry has moved since you read it — re-read candidate_revision (minerva_pcb_workspace_list/get_active) before editing it again",
			}

	var out: Dictionary = {}
	match op:
		"move_junction":
			out = _edit_candidate_move_junction(workspace, cid, args, ctx["data"])
		"insert_via":
			out = _edit_candidate_insert_via(workspace, cid, args, ctx["data"])
	if not bool(out.get("ok", false)):
		return {
			"success": false,
			"error": str(out.get("error", "edit_refused")),
			"candidate_id": cid,
			"op": op,
			"message": str(out.get("message", "")),
		}

	var reply: Dictionary = out.duplicate()
	reply.erase("ok")
	reply["op"] = op
	# Epoch UX1 station 11: refreshed through the shared helper — same
	# substance (candidate-local edit, pin/reroute_route to make it durable,
	# commit when ready) as the longer prose this replaced, one note, not two.
	reply["note"] = _next_steps("edit_candidate", {})
	return _ok(reply)


## move_junction's own arg parsing, in [x_mm,y_mm] ARRAY shape (matching this
## candidate's own geometry wire shape — segments' points are [[x,y],…] — rather
## than the {x_mm,y_mm} dict shape corridor/pin lookups use elsewhere in this
## file, because the point named here IS a point already living in that wire
## shape, read back from a prior list/get_active/include_geometry reply).
static func _edit_candidate_move_junction(workspace, cid: String, args: Dictionary,
		data = null) -> Dictionary:
	var point: Variant = _parse_xy_pair(args.get("point"))
	if point == null:
		return {"ok": false, "error": "invalid_point", "message": "point must be [x_mm, y_mm]"}
	var to: Variant = _parse_xy_pair(args.get("to"))
	if to == null:
		return {"ok": false, "error": "invalid_point", "message": "to must be [x_mm, y_mm]"}
	return workspace.move_junction(cid, point, to, data)


## insert_via's own arg parsing — delegates the actual edit to
## RoutingWorkspace.add_via verbatim; this function does nothing but shape the
## MCP args into that call's own signature.
static func _edit_candidate_insert_via(workspace, cid: String, args: Dictionary, data = null) -> Dictionary:
	var position: Variant = _parse_xy_pair(args.get("position"))
	if position == null:
		return {"ok": false, "error": "invalid_point", "message": "position must be [x_mm, y_mm]"}
	var from_layer: String = str(args.get("from_layer", ""))
	var to_layer: String = str(args.get("to_layer", ""))
	if from_layer.is_empty():
		return {"ok": false, "error": "invalid_args", "message": "from_layer is required"}
	if to_layer.is_empty():
		return {"ok": false, "error": "invalid_args", "message": "to_layer is required"}

	# THE DECLARED-STACK CHECK RoutingWorkspace.add_via DEFERS TO THIS LAYER
	# (epoch NLC C1b). add_via validates that the run's continuation layer is
	# COPPER, which is all a workspace can know — it holds candidates, not a
	# board. Whether that copper layer actually EXISTS on this board is a
	# question only something holding the board can answer, and it is the
	# difference between "in7" being a typo and being a plane: without this,
	# a continuation onto an undeclared layer would be accepted here and
	# refused much later by the compiler, naming a segment rather than the
	# argument that caused it.
	if data != null and "layers" in data:
		var declared: Array = data.layers if data.layers is Array else []
		var canon_to: String = PcbLayerStack.kicad_to_canon(to_layer)
		if not declared.is_empty() and not (canon_to in declared):
			return {"ok": false, "error": "layer_not_on_stack",
				"message": "this board declares %s — a run cannot continue on %s, which is not one of them"
					% [str(declared), canon_to],
				"declared_layers": declared.duplicate()}

	# `data` rides along so the inserted via takes its diameter/drill from the
	# board's design_rules, like every other via this plugin creates.
	return workspace.add_via(cid, position, from_layer, to_layer, data)


## Parse an [x_mm, y_mm] wire pair into a Vector2, or null when malformed —
## the array-shaped twin of _parse_route_intent_corridor's per-point
## {x_mm,y_mm} dict parsing, used where the wire value is a bare point rather
## than a polyline.
static func _parse_xy_pair(raw: Variant) -> Variant:
	if not (raw is Array) or (raw as Array).size() != 2:
		return null
	var arr: Array = raw
	if not (arr[0] is float or arr[0] is int) or not (arr[1] is float or arr[1] is int):
		return null
	return Vector2(float(arr[0]), float(arr[1]))


## Best-effort citeable ref (C<n>) stamp, mirroring core MCPAnnotationTools'
## _annotations_add flow (ProjectIdentity.stamp() called on the envelope BEFORE
## the host stores it) WITHOUT a class_name reference to ProjectIdentity — an
## off-tree script cannot resolve one (see PcbAnnotationHost.gd's own off-tree
## note; core's citeable-annotation-ref machinery, ProjectIdentity.gd, lives
## entirely in-tree). Duck-typed through the same path ProjectIdentity.current() takes
## internally: SceneTree -> the "SingletonObject" autoload node -> its
## project_identity property -> .stamp(envelope) by name by contract.
## Mutates `envelope` in place, adding "ref"/"ref_project" when a live
## identity is reachable. A no-op in headless/test contexts (no SceneTree
## root, no mounted SingletonObject, or a bare test double without a
## project_identity property) — the caller reads envelope.get("ref","")
## afterward, so "the C-ref if reachable" degrades to an absent key rather
## than failing the intent.
static func _maybe_stamp_annotation_ref(envelope: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var so := tree.root.get_node_or_null("SingletonObject")
	if so == null:
		return
	var pi: Variant = so.get("project_identity")
	if not (pi is Object) or not (pi as Object).has_method("stamp"):
		return
	(pi as Object).call("stamp", envelope)


## minerva_pcb_route_bus_direct — the agent's doorway onto the SAME gesture
## the canvas Bus tool draws (see the region doc above): an ORDERED net list
## (T11 — echoed back verbatim, never re-sorted) plus a spine polyline in one
## call, same validation path (bus_plan), same single journal step
## (bus_commit_plan), same named refusal shape. The canvas's WORKING layer is
## NOT consulted here (there is no canvas in an MCP call, and a verb that read
## panel state would route differently depending on what the human last clicked)
## — an agent must name `layer` explicitly, or the board's only declared copper
## layer is used when there is exactly one.
static func _route_bus_direct(host, args: Dictionary) -> Dictionary:
	var data = _resolve_data(host)
	if not (data is Object):
		return data

	var plan: Dictionary = _bus_plan_from_args(data, args)
	if not bool(plan.get("buildable", false)):
		return _err(str(plan.get("error", "Bus was refused.")))

	# dry_run: the same plan, the same gates, the same reply — and no write.
	var dry_run: bool = bool(args.get("dry_run", false))
	var result: Dictionary = bus_dry_run_plan(plan) if dry_run \
		else bus_commit_plan(data, plan, "Add bus (%d nets)" % (plan.get("nets", []) as Array).size())
	if not bool(result.get("ok", false)):
		return _err(str(result.get("error", "Bus was refused by the board model.")))

	var findings: Array = result.get("findings", []) if result.get("findings", []) is Array else []
	var reply: Dictionary = {
		"dry_run": dry_run,
		"trace_ids": result.get("trace_ids", []),
		"via_ids": result.get("via_ids", []),
		"nets": result.get("nets", []),
		"widths": result.get("widths", []),
		"layer": str(result.get("layer", "")),
		"via_station_layer": str(result.get("via_station_layer", "")),
		"findings": findings,
		"open_nets": result.get("open_nets", []),
		"nets_detail": result.get("nets_detail", []),
	}
	if dry_run:
		reply["dry_run_note"] = "nothing was written: no trace, via, history step or journal row. Call again without dry_run to commit, or minerva_pcb_workspace_propose_bus for a reviewable ghost."
	else:
		reply["undo_note"] = "one board history step: Ctrl+Z (or PCBData.undo) removes all traces and vias this call created."
	if not findings.is_empty():
		var landing: String = "would land anyway" if dry_run else "landed anyway"
		reply["note"] = "%d bus rule(s) broke and the copper %s so it can be corrected: %s. Fix it in place (move a pad, redraw the spine, minerva_pcb_delete_traces) or undo the whole step." \
			% [findings.size(), landing, bus_findings_sentence(findings)]
		var advice: String = PcbBusLabels.clean_order_sentence(
			PackedStringArray(result.get("clean_order", PackedStringArray())))
		if not advice.is_empty():
			reply["clean_order"] = Array(result.get("clean_order", PackedStringArray()))
			reply["note"] = "%s Advisory: %s" % [str(reply["note"]), advice]
		_add_leave_one_open(reply, plan)
	var open_words: String = PcbBusLabels.bus_open_sentence(result.get("open_nets", []) as Array)
	if not open_words.is_empty():
		reply["note"] = open_words if not reply.has("note") else "%s %s" % [str(reply["note"]), open_words]
	return _ok(reply)


## When the plan found no clean pick order for a target-end crossing, the
## reply carries the next verb: leave_open_net, the concrete leave_open_targets
## array, and the sentence appended to the note.
static func _add_leave_one_open(reply: Dictionary, plan: Dictionary) -> void:
	var open_net: String = str(plan.get("leave_open_net", ""))
	if open_net.is_empty():
		return
	var targets := PackedStringArray(plan.get("leave_open_targets", PackedStringArray()))
	var pair: Array = plan.get("leave_open_pair", []) if plan.get("leave_open_pair", []) is Array else []
	if pair.size() != 2:
		return
	reply["leave_open_net"] = open_net
	reply["leave_open_targets"] = Array(targets)
	var words: String = PcbBusLabels.leave_one_open_sentence(str(pair[0]), str(pair[1]),
		open_net, targets)
	reply["note"] = words if not reply.has("note") else "%s %s" % [str(reply["note"]), words]


static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}


# ── Board-by-reference (work item 01a0223ec9e271269fd664fcf90dd20b) ──────────
# The host broker caps panel→plugin requests at 64 KiB and the board-carrying
# channels (pcb.route / pcb.serialize / pcb.deserialize) inlined O(board)
# documents into that pipe — a real board (~700 KB expanded) made all three
# fail payload_too_large. These two helpers are the panel half of the fix:
# an over-limit payload swaps its document for {board_path, board_digest}
# (a snapshot file the worker process reads back sha256-verified), and
# serialize CONSUMERS read the worker's oversized {yaml_path, yaml_digest}
# reply back through one verified reader.

## Margin under PluginScenePanelBroker.MAX_PAYLOAD_BYTES (65536): the payload
## is measured here pre-envelope, so leave headroom for reply-id fields.
const _SNAPSHOT_LIMIT := 60000
## Snapshot retention: never delete the file just written (the backend-ensure
## retry re-emits the same payload and the worker re-reads it), never
## accumulate forever either — a count-bounded prune on each write.
const _SNAPSHOT_KEEP := 8

static var _snapshot_seq := 0


## If JSON.stringify(payload) exceeds `limit`, snapshot payload[key] (a board
## dict or source text) to a unique OS-native file under base_dir and return a
## COPY of the payload with the key replaced by {board_path, board_digest}.
## Under-limit payloads (and payloads without the key) pass through
## UNCHANGED — no current caller changes wire shape. NEVER mutates its input:
## _request_with_backend_ensure's retry re-emits the same payload dict.
## On any snapshot-write failure the ORIGINAL payload is returned — the broker
## then refuses it loudly (payload_too_large), which beats silently dropping
## the request.
static func board_payload_by_ref_if_large(payload: Dictionary, key: String,
		base_dir: String, limit: int = _SNAPSHOT_LIMIT) -> Dictionary:
	if not payload.has(key):
		return payload
	if JSON.stringify(payload).length() <= limit:
		return payload
	var doc: Variant = payload[key]
	var text: String = doc if doc is String else JSON.stringify(doc)
	var abs_dir := ProjectSettings.globalize_path(base_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	_prune_snapshots(abs_dir)
	_snapshot_seq += 1
	var path := abs_dir.path_join("board-%d-%d.snap" % [Time.get_ticks_usec(), _snapshot_seq])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return payload
	f.store_string(text)
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		DirAccess.remove_absolute(path)
		return payload
	var digest := FileAccess.get_sha256(path)
	if digest.is_empty():
		# Hash failure is a write-failure (fix cold review F8): fall back to
		# the original payload — the broker's loud payload_too_large beats a
		# request the worker would refuse as digest-less.
		DirAccess.remove_absolute(path)
		return payload
	var out := payload.duplicate()
	out.erase(key)
	out["board_path"] = path
	out["board_digest"] = digest
	return out


## Read the yaml text out of a pcb.serialize result payload, whichever shape
## it arrived in: inline {yaml} (under-cap, unchanged behavior) or by-path
## {yaml_path, yaml_digest} (over-cap — Go lands the document in a temp file).
## The digest is verified before a byte is trusted; a mismatch or missing file
## is refused by name, never returned as "empty document".
## Returns {ok: bool, yaml: String, error: String}.
static func yaml_from_serialize_result(payload: Dictionary) -> Dictionary:
	var inline := str(payload.get("yaml", payload.get("text", "")))
	if not inline.is_empty():
		return {"ok": true, "yaml": inline, "error": ""}
	var path := str(payload.get("yaml_path", ""))
	if path.is_empty():
		return {"ok": false, "yaml": "",
			"error": "serialize reply carried neither yaml nor yaml_path"}
	if not FileAccess.file_exists(path):
		return {"ok": false, "yaml": "",
			"error": "serialize yaml_path missing: %s" % path}
	var digest := str(payload.get("yaml_digest", ""))
	if digest.is_empty() \
			or FileAccess.get_sha256(path).to_lower() != digest.to_lower():
		return {"ok": false, "yaml": "",
			"error": "serialize yaml_path digest mismatch for %s" % path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "yaml": "",
			"error": "cannot open serialize yaml_path %s" % path}
	var text := f.get_as_text()
	f.close()
	# CONSUME on successful read (fix cold review F3): the Go side lands each
	# over-cap document in a fresh os.CreateTemp file and nothing else ever
	# deletes it — and unlike the request snapshot (which the backend-ensure
	# retry re-reads), a reply document is read exactly once. A FAILED read
	# leaves the file for diagnosis.
	DirAccess.remove_absolute(path)
	return {"ok": true, "yaml": text, "error": ""}


## Delete oldest snapshots until at most _SNAPSHOT_KEEP - 1 remain, so the
## write that follows lands within the retention bound.
static func _prune_snapshots(abs_dir: String) -> void:
	var files: Array = []
	for fname in DirAccess.get_files_at(abs_dir):
		if str(fname).begins_with("board-") and str(fname).ends_with(".snap"):
			var p := abs_dir.path_join(str(fname))
			files.append({"path": p, "mtime": FileAccess.get_modified_time(p)})
	if files.size() < _SNAPSHOT_KEEP:
		return
	files.sort_custom(func(a, b): return int(a["mtime"]) < int(b["mtime"]))
	for i in range(files.size() - (_SNAPSHOT_KEEP - 1)):
		DirAccess.remove_absolute(str(files[i]["path"]))
