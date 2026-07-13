extends RefCounted
## pcb/ui/panel_layout.gd — width-mode resolver for the PCB panel's responsive
## layout (UI redesign round B).
##
## Minerva editors live in resizable 1/2/3-column layouts; the panel adapts to
## its OWN measured width (never window size or column count):
##   wide   (>= 900px)  — full layout: labeled sidebar sections, all toolbar
##                        controls inline. Typical 1-col / wide 2-col.
##   medium (480..900)  — compact sidebar (icon flows, wrapping), full toolbar.
##                        The 3-col default; primary design target.
##   narrow (< 480px)   — sidebar hidden behind a drawer toggle; view toggles
##                        fold into a View menu so the toolbar never h-scrolls.
##
## Hysteresis: leaving a mode requires crossing the boundary by HYSTERESIS_PX
## so dragging a column splitter across a breakpoint doesn't flicker modes.
##
## Off-tree plugin constraints: no class_name; load via preload from siblings.

const MODE_WIDE := "wide"
const MODE_MEDIUM := "medium"
const MODE_NARROW := "narrow"

const NARROW_MAX_PX := 480.0
const WIDE_MIN_PX := 900.0
const HYSTERESIS_PX := 20.0


## Resolves the layout mode for a panel width, sticky to `current` within the
## hysteresis band. Pass current = "" (or an unknown value) for the initial,
## hysteresis-free classification.
static func mode_for_width(width: float, current: String = "") -> String:
	var narrow_boundary := NARROW_MAX_PX
	if current == MODE_NARROW:
		narrow_boundary += HYSTERESIS_PX  # harder to leave narrow
	var wide_boundary := WIDE_MIN_PX
	if current == MODE_WIDE:
		wide_boundary -= HYSTERESIS_PX  # harder to leave wide

	if width < narrow_boundary:
		return MODE_NARROW
	if width >= wide_boundary:
		return MODE_WIDE
	return MODE_MEDIUM
