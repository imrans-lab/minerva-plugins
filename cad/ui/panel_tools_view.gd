extends "panel_tools_measure.gd"
## The CAD panel verbs about the VIEW: what the panes are showing, and the
## ruler drawn into them.
##
##   minerva_cad_view_state    which pane is on which preset, where each camera
##                             stands, and what the layout is.
##   minerva_cad_view_overlay  draw a millimetre grid and the world axes in the
##                             panes, and report each pane's scale.
##
## WHY IT IS ITS OWN FILE. It is a pure move out of ui/panel_tools.gd, which
## had reached the size where reading it to change one verb costs more than the
## change. The chain is panel_tools_measure.gd -> this -> panel_tools.gd:
## dispatch stays in panel_tools.gd and calls down into these, which is the
## direction inheritance may be read in — nothing here names a member of the
## script that extends it.
##
## The capture verbs are deliberately NOT here: a picture is scripts/
## fit_capture.gd and scripts/posed_capture.gd, which the dispatch calls
## directly.
##
## Off-tree note: no class_name — reached through panel_tools.gd.


## minerva_cad_view_state — delegates to CADPanel.get_view_state().
static func _view_state(panel, _args: Dictionary) -> Dictionary:
	if panel == null or not panel.has_method("get_view_state"):
		return _err("CAD view state not available on this panel")
	return _ok(panel.get_view_state())


## minerva_cad_view_overlay — the grid and axes, and each pane's scale.
static func _view_overlay(panel, args: Dictionary) -> Dictionary:
	var mode := str(args.get("overlay", "grid"))
	if mode not in ["none", "grid", "axes", "grid+axes"]:
		return _err("overlay must be none, grid, axes or grid+axes")
	var drawn: Dictionary = panel.set_measurement_overlay(
		mode, float(args.get("grid_mm", 10.0)))
	# In narrow layout the four named panes do not exist; reporting the single
	# pane four times under four names would be four lies. Ask the panel and
	# say which pane there actually is.
	var views: Array = []
	var refusal := ""
	if panel.has_method("view_unavailable_reason"):
		refusal = str(panel.view_unavailable_reason("top"))
	if refusal.is_empty():
		for view in ["top", "front", "right", "iso"]:
			var metrics: Dictionary = panel.get_view_metrics(view)
			if not metrics.has("error"):
				views.append(metrics)
	else:
		var single: Dictionary = panel.get_view_metrics("active")
		if not single.has("error"):
			views.append(single)
	var payload := {
		"units": "mm",
		"overlay": str(drawn.get("mode", mode)),
		"grid_mm": float(drawn.get("grid_mm", 0.0)),
		"lines": int(drawn.get("lines", 0)),
		"views": views,
		"note": "Take the picture with minerva_cad_snapshot; the overlay is "
			+ "scene geometry and is captured with everything else.",
	}
	if not refusal.is_empty():
		payload["views_unavailable"] = refusal
	return _ok(payload)
