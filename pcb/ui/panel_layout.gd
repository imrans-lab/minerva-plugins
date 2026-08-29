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
##                        fold into a View menu, and the toolbar drops its
##                        caption labels, so it never h-scrolls.
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


## Does the toolbar have room for its CAPTION labels — the word beside a control
## that the control itself already says ("Layer:" beside a chooser reading
## "F.Cu")? Only above narrow.
##
## The width budget this answers, measured on the built strip: with captions the
## control strip's minimum is 412px, without them 360px, against a 400px narrow
## pane. Adding the Options menu (76px) to the strip is what pushed it over —
## a caption is the cheapest thing to spend that width on, because the chooser
## keeps its value on screen and its tooltip says the rest. It is the rule the
## narrow mode already applies to the Export button and the board-size readout,
## both of which are reachable elsewhere (the View menu, the status bar).
static func toolbar_captions_fit(mode: String) -> bool:
	return mode != MODE_NARROW


## The right sidebar's width per mode, in px. OWNED here rather than left to
## the widest row that happens to be mounted: the sidebar never expands, so
## its width IS its minimum, and until work item 01a04b9c9064 that minimum was
## an accident of the Properties rows' key labels and pickers — deleting them
## dropped the column to its 120 px floor.
## Budget: a 24 px icon button is ~36 px with theme padding, 4 px apart, so
## 184 seats four per row and 240 seats six plus the annotation dock pane that
## lives in the sidebar in wide mode. Narrow uses the medium width for its
## drawer.
const SIDEBAR_WIDE_PX := 240.0
const SIDEBAR_MEDIUM_PX := 184.0


static func sidebar_width_px(mode: String) -> float:
	return SIDEBAR_WIDE_PX if mode == MODE_WIDE else SIDEBAR_MEDIUM_PX
