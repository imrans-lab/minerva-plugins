extends RefCounted
## Pure layout choice from the panel's available content, never monitor size.
## Manual choices survive resizes; Auto requires usable four-view panes and
## uses separate leave/return thresholds so a boundary does not oscillate.

const MODES: Array[String] = ["auto", "single", "four"]
const PANE_MIN: Vector2 = Vector2(300.0, 225.0)
const RETURN_MARGIN: float = 12.0
const LEAVE_ASPECT: float = 0.65
const RETURN_ASPECT: float = 0.80


static func preference(value: String) -> String:
	return value if value in MODES else "auto"


static func choose(requested: String, available: Vector2, sidebar: float,
		split: float, grid_gap: Vector2, was_single: bool) -> Dictionary:
	var mode: String = preference(requested)
	var pane := Vector2(maxf(0.0, available.x - sidebar - split - grid_gap.x),
		maxf(0.0, available.y - grid_gap.y)) * 0.5
	var single: bool = mode == "single"
	var reason: String = "Manual single view" if single else "Manual four views"
	if mode == "auto":
		var margin: float = RETURN_MARGIN if was_single else 0.0
		var aspect: float = pane.x / pane.y if pane.y > 0.0 else 0.0
		if pane.x < PANE_MIN.x + margin or pane.y < PANE_MIN.y + margin:
			single = true
			reason = "Auto: four-view panes are below usable size" \
				if not was_single else "Auto: waiting for four-view size margin"
		elif aspect < LEAVE_ASPECT or (was_single and aspect <= RETURN_ASPECT):
			single = true
			reason = "Auto: four-view panes are too tall" \
				if not was_single else "Auto: waiting for four-view aspect margin"
		else:
			single = false
			reason = "Auto: four-view panes have usable size and aspect"
	return {"preference": mode, "mode": "single" if single else "four",
		"is_single": single, "reason": reason,
		"available_px": [available.x, available.y],
		"projected_four_pane_px": [pane.x, pane.y],
		"sidebar_px": sidebar, "split_px": split,
		"grid_gap_px": [grid_gap.x, grid_gap.y]}
