extends RefCounted
## CAD panel-executed MCP tool surface — second-plugin adoption proof (DCR
## 019f6c3d0e3d, round C6, docket 019f6c469422).
##
## Mirrors pcb/ui/panel_tools.gd's conventions (static handle() dispatch,
## _ok/_err envelope builders) at MINIMAL scale: ONE tool.
##
##   minerva_cad_view_state — camera orientation/zoom + active-view context
##   for a live CAD editor, so an agent can reason about what the user is
##   currently LOOKING AT without a screenshot round-trip.
##
## Every field this tool returns already existed on CADPanel/OrbitCamera
## before this round (_responsive.width_class, _active_viewport_id, the
## projection-dropdown selection, OrbitCamera.get_target/get_distance/
## get_yaw/get_pitch/get_debug_state) — this round adds NO new host
## machinery, only a thin surfacing method (CADPanel.get_view_state()) plus
## this dispatch file. That is the acceptance-criterion (d) point: the
## executor:"panel" substrate is generic, not a pcb special case.
##
## Host resolution is NOT this surface's job (contract §2.2/§2.3,
## Docs/design/panel-executed-tools.md): the PluginToolRegistry dispatcher
## resolves args.editor_name -> the live CADPanel -> calls
## CADPanel.handle_tool(tool_name, args), which forwards here with the panel
## itself already in hand. panel_tools.gd never sees an unknown/missing
## editor_name.
##
## Off-tree note: this file lives OUTSIDE Minerva's res:// tree, so it MUST
## NOT declare a class_name — preloaded by relative path from CADPanel.gd
## (matches every other cad/ui/*.gd file's convention, and pcb/ui/panel_tools.gd).


## Dispatch entry point — called by CADPanel.handle_tool(tool_name, args).
## `panel` is the live CADPanel instance the dispatcher resolved (never null
## in production). An unrecognised tool_name returns {} so the
## PluginToolRegistry dispatcher maps it to the structured tool_unhandled
## error (contract §2.4).
static func handle(panel, tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_cad_view_state":
			return _view_state(panel, args)
	return {}


## minerva_cad_view_state — no args beyond editor_name (dispatcher-consumed;
## never reaches this file). Delegates the actual state surfacing to
## CADPanel.get_view_state() (defensive has_method check keeps this file
## crash-proof against a future panel refactor that renames/removes it).
static func _view_state(panel, _args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("get_view_state"):
		return _err("CAD view state not available on this panel")
	return _ok(panel.get_view_state())


# ── Envelope builders (self-contained, mirrors pcb/ui/panel_tools.gd) ────────

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}
