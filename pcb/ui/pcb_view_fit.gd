extends RefCounted
## THE ONE FIT DERIVATION for the PCB canvas (bug 01a040f7523e).
##
## Given content in board mm and a viewport in pixels: what zoom (px/mm) and
## what centre show all of that content, as large as the viewport allows? Every
## "frame this" caller goes through here — the toolbar Fit button and
## minerva_pcb_set_view {fit:true} (pcb_canvas.zoom_to_fit), a component/region
## frame (pcb_canvas.frame_rect), and the off-screen capture behind
## minerva_pcb_get_image {fit:true} (pcb_canvas._frame_board_for_capture).
##
## There used to be two: the on-screen fit framed the COMPONENT bounding box
## with a fixed 10 mm margin, while the capture fit framed the BOARD OUTLINE
## UNION the components with a fractional one. So the two answered "show me the
## whole board" differently on the same board — and the on-screen one framed
## nothing recognisable when the parts sat in one corner (or when the board had
## no parts at all, in which case it left the zoom untouched entirely and the
## board could sit off-frame: "the board disappeared").
##
## Pure math on purpose. It never writes zoom/pan_offset — pcb_canvas.gd owns
## those and applies the result through set_view_center_zoom.

## Padding kept around fitted content, as a fraction of the content's own size
## per side. Fractional rather than a fixed mm figure: a fixed margin is a
## different share of a 20 mm board than of a 200 mm one, so how big the board
## looked would swing with the board instead of with the viewport.
const PAD_FRACTION := 0.05


## What "the whole board" means: the board outline (drawn from the origin — see
## pcb_canvas._draw_board) UNION every component's bounds, so a part hanging off
## the edge still lands in frame and a board with no parts still frames its
## outline.
static func board_content_rect(data) -> Rect2:
	if data == null:
		return Rect2()
	var rect := Rect2(0.0, 0.0, float(data.board_width), float(data.board_height))
	for comp_id in data.components:
		var comp = data.components[comp_id]
		if comp != null and comp.has_method("get_bounding_rect"):
			rect = rect.merge(comp.get_bounding_rect())
	return rect


## Grow a rect by `fraction` of its own size on every side.
static func pad(content: Rect2, fraction: float) -> Rect2:
	if fraction <= 0.0:
		return content
	var d: Vector2 = content.size * fraction
	return Rect2(content.position - d, content.size + d * 2.0)


## The zoom (px/mm) that fits `content` into a `viewport_px` rect: the SMALLER
## of the two axis zooms, so the whole rect is visible on both axes and the
## other axis simply shows more board. That minimum is what makes the same call
## correct on a wide pane and on a tall narrow docked one.
##
## Returns 0.0 — "no opinion, leave the view alone" — for degenerate content or
## a viewport that has not been laid out yet; fitting to a 0-wide pane would
## otherwise pin the zoom at min_zoom and frame nothing.
static func fit_zoom(content: Rect2, viewport_px: Vector2, min_zoom: float, max_zoom: float,
		pad_fraction: float = PAD_FRACTION) -> float:
	if viewport_px.x <= 0.0 or viewport_px.y <= 0.0:
		return 0.0
	var padded := pad(content, pad_fraction)
	if padded.size.x <= 0.0 or padded.size.y <= 0.0:
		return 0.0
	return clampf(minf(viewport_px.x / padded.size.x, viewport_px.y / padded.size.y),
		min_zoom, max_zoom)
