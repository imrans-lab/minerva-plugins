extends RefCounted
## Board-LEVEL graphics: the panel's model for artwork the BOARD owns rather
## than a component.
##
## THE GAP IT CLOSES. Every graphic in this editor used to hang off a component
## and be placed by that component's transform. There was no owner for "a
## copyright line on the back of the board", so smart-remote-v2's was authored
## as 65 B.SilkS polylines attached to TP1 — a test point — in ABSOLUTE board
## coordinates that TP1's own placement would have corrupted the moment anyone
## dragged it.
##
## HELD VERBATIM, like zones and cutouts (see the `zones` declaration in
## pcb_data.gd). The canonical dict `pcb.deserialize` hands over is the dict we
## keep and the dict we hand back, so a field added to Go's `board.Graphic`
## survives this model without a change here. Nothing is reshaped on the way in.
##
## TEXT IS PROVENANCE, NOT GEOMETRY. A `kind: "text"` entry stores what the text
## SAYS — string, anchor, size, rotation — and never its strokes. Strokes are
## DERIVED for drawing, here, from the same glyph table the worker's compiler
## derives them from (pcb_board_font.gd <- pcb_board_font_data.gd <-
## worker/pcb_worker/board_font.py). That is what makes the editor preview and
## the fabricated legend the same shape rather than two hopefully-equal copies.
##
## Off-tree plugin: NO class_name (see sibling pcb_layer_stack.gd) — reached via
## a relative preload():
##     const PcbBoardGraphic := preload("pcb_board_graphic.gd")

const PcbBoardFont := preload("pcb_board_font.gd")
const PcbEntityId := preload("pcb_entity_id.gd")

## The entity type minted for a board graphic. Matches Go's
## `isMintedID("graphic", ...)` in internal/board/validate.go and the Python
## `_check_entity_ids("graphic", ...)` in board_validate.py — three languages,
## one token, and the id a user deletes by must be the id the codec accepts.
const ENTITY_TYPE := "graphic"

## Silk and courtyard ONLY, fail-closed, mirroring
## board_graphics.ALLOWED_ROLES in the worker. Copper would be unconnected metal
## that routing and DRC must reason about with no net; Edge.Cuts already has an
## owner (the board profile and its cutouts), and a second way to draw the rim
## is a second answer to "how big is this board".
const ALLOWED_LAYERS := ["F.SilkS", "B.SilkS", "F.CrtYd", "B.CrtYd"]

## The authoring vocabulary. `poly` CLOSES back to its first point; `polyline`
## does not, which is exactly why a glyph stroke is a polyline (a closed "C" is
## an "O").
const KINDS := ["text", "line", "circle", "poly", "polyline", "rect"]

const DEFAULT_WIDTH_MM := 0.15
const DEFAULT_TEXT_SIZE_MM := 1.0


static func is_silk(layer: String) -> bool:
	return layer == "F.SilkS" or layer == "B.SilkS"


static func is_courtyard(layer: String) -> bool:
	return layer == "F.CrtYd" or layer == "B.CrtYd"


static func graphic_id(graphic: Dictionary) -> String:
	return str(graphic.get("id", ""))


static func layer_of(graphic: Dictionary) -> String:
	return str(graphic.get("layer", ""))


static func width_of(graphic: Dictionary) -> float:
	var w: Variant = graphic.get("width")
	if w is float or w is int:
		return float(w)
	return DEFAULT_WIDTH_MM


## Whether a text entry's glyphs are mirror-written.
##
## DERIVED FROM THE LAYER, not a preference: a Gerber is plotted as seen from the
## top THROUGH the board, so back-side legend must be mirror-written in the file
## to read correctly once the board is flipped. Pinning it to the layer means the
## editor cannot show text that would come out backwards on the fab. An explicit
## `mirror` key still wins when present, so a deliberate exception stays
## expressible; nothing authors one today. Mirrors board_graphics._mirror_for.
static func mirror_for(graphic: Dictionary) -> bool:
	var explicit: Variant = graphic.get("mirror")
	if explicit is bool:
		return explicit
	return layer_of(graphic).begins_with("B.")


static func _point(value: Variant) -> Vector2:
	## The canonical BOARD-LEVEL point shape, {x_mm, y_mm} — the same shape
	## trace points, zone outlines and cutout outlines use, and the only shape
	## Go's typed `Points []Point` decodes. Deliberately NOT the bare [x, y]
	## pair component graphics ride with: one shape on both sides, or a board
	## parses in the panel and is refused by the codec that gates every load.
	if value is Dictionary:
		return Vector2(float(value.get("x_mm", 0.0)), float(value.get("y_mm", 0.0)))
	return Vector2.ZERO


static func _points(graphic: Dictionary) -> Array:
	var out: Array = []
	for p in graphic.get("points", []):
		if p is Dictionary:
			out.append(_point(p))
	return out


## Board-ABSOLUTE display strokes for one graphic, as an Array of Arrays of
## Vector2 in board mm, plus the closed/open flag the canvas needs.
##
## Returns { "polylines": Array[Array[Vector2]], "closed": bool,
##           "circle": {center, radius} or null, "missing": Array[String] }.
##
## Circles stay a circle rather than being tessellated here: the canvas draws
## them with draw_arc, which is both cheaper and smoother than a polygon at any
## zoom, and tessellating in the model would bake a segment count that the view
## is the only thing qualified to choose.
static func display(graphic: Dictionary) -> Dictionary:
	var kind := str(graphic.get("kind", ""))
	var out := {"polylines": [], "closed": false, "circle": null, "missing": []}

	match kind:
		"text":
			var text := str(graphic.get("text", ""))
			if text.is_empty():
				return out
			var anchor: Vector2 = _point(graphic.get("position", {}))
			var size: float = float(graphic.get("size_mm", DEFAULT_TEXT_SIZE_MM))
			if size <= 0.0:
				size = DEFAULT_TEXT_SIZE_MM
			var align := str(graphic.get("h_align", "left"))
			if align != "center":
				align = "left"
			var r := PcbBoardFont.strokes_for(
				text, anchor.x, anchor.y, size,
				float(graphic.get("rotation_deg", 0.0)), mirror_for(graphic), align)
			out["polylines"] = r["polylines"]
			out["missing"] = r["missing"]
		"line":
			out["polylines"] = [[_point(graphic.get("start", {})),
					_point(graphic.get("end", {}))]]
		"circle":
			var radius := float(graphic.get("radius", 0.0))
			if radius > 0.0:
				out["circle"] = {"center": _point(graphic.get("center", {})),
						"radius": radius}
		"rect":
			var a: Vector2 = _point(graphic.get("start", {}))
			var b: Vector2 = _point(graphic.get("end", {}))
			out["polylines"] = [[a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)]]
			out["closed"] = true
		"poly":
			out["polylines"] = [_points(graphic)]
			out["closed"] = true
		"polyline":
			out["polylines"] = [_points(graphic)]

	return out


## Axis-aligned board-mm bounds of a graphic, or a zero Rect2 when it draws
## nothing. Reported by the authoring verbs so a caller can see where its
## artwork landed without re-deriving the font.
static func bounds(graphic: Dictionary) -> Rect2:
	var shown := display(graphic)
	if shown["circle"] != null:
		var c: Vector2 = shown["circle"]["center"]
		var r: float = shown["circle"]["radius"]
		return Rect2(c - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
	return PcbBoardFont.bounds_of(shown["polylines"])


static func bounds_dict(graphic: Dictionary) -> Dictionary:
	var r := bounds(graphic)
	return {"min_x_mm": r.position.x, "min_y_mm": r.position.y,
			"max_x_mm": r.end.x, "max_y_mm": r.end.y,
			"width_mm": r.size.x, "height_mm": r.size.y}


## Build a `kind: "text"` payload, minting an id when the caller supplies none.
## Returns { "ok": true, "graphic": Dictionary } or { "ok": false, "error": String }.
##
## Refuse-before-mint: an id is only spent on a payload that is going to be
## accepted, so a rejected call leaves no gap in the id space and no half-written
## entry for the next undo to restore.
static func build_text(text: String, x_mm: float, y_mm: float, layer: String,
		size_mm: float, rotation_deg: float = 0.0, id: String = "",
		width_mm: float = -1.0, h_align: String = "left") -> Dictionary:
	if text.is_empty():
		return {"ok": false, "error": "text is required and must not be empty"}
	if not ALLOWED_LAYERS.has(layer):
		return {"ok": false, "error":
			"layer %s is not a board-graphic layer; expected one of %s" %
			[layer, ", ".join(ALLOWED_LAYERS)]}
	if size_mm <= 0.0:
		return {"ok": false, "error": "size_mm must be > 0, got %s" % size_mm}
	var graphic := {
		"id": id if not id.is_empty() else PcbEntityId.mint(ENTITY_TYPE),
		"layer": layer,
		"kind": "text",
		"text": text,
		"position": {"x_mm": x_mm, "y_mm": y_mm},
		"size_mm": size_mm,
		"width": width_mm if width_mm > 0.0 else DEFAULT_WIDTH_MM,
	}
	if not is_zero_approx(rotation_deg):
		graphic["rotation_deg"] = rotation_deg
	if h_align == "center":
		graphic["h_align"] = "center"
	return {"ok": true, "graphic": graphic}


## Build a raw-geometry payload. `spec` carries whichever of
## polylines / points / rect / circle the caller supplied, already in the
## canonical {x_mm, y_mm} point shape.
static func build_geometry(layer: String, spec: Dictionary, width_mm: float = -1.0,
		id: String = "") -> Dictionary:
	if not ALLOWED_LAYERS.has(layer):
		return {"ok": false, "error":
			"layer %s is not a board-graphic layer; expected one of %s" %
			[layer, ", ".join(ALLOWED_LAYERS)]}
	var kind := str(spec.get("kind", ""))
	if not KINDS.has(kind) or kind == "text":
		return {"ok": false, "error":
			"kind %s is not raw geometry; expected line, circle, poly, polyline or rect"
			% kind}
	var graphic := {
		"id": id if not id.is_empty() else PcbEntityId.mint(ENTITY_TYPE),
		"layer": layer,
		"kind": kind,
		"width": width_mm if width_mm > 0.0 else DEFAULT_WIDTH_MM,
	}
	match kind:
		"line", "rect":
			if not (spec.has("start") and spec.has("end")):
				return {"ok": false, "error": "%s requires start and end points" % kind}
			graphic["start"] = spec["start"]
			graphic["end"] = spec["end"]
		"circle":
			var radius := float(spec.get("radius", 0.0))
			if radius <= 0.0 or not spec.has("center"):
				return {"ok": false, "error": "circle requires a center and a positive radius"}
			graphic["center"] = spec["center"]
			graphic["radius"] = radius
		"poly", "polyline":
			var pts: Array = spec.get("points", [])
			var minimum := 3 if kind == "poly" else 2
			if pts.size() < minimum:
				return {"ok": false, "error":
					"%s requires at least %d points, got %d" % [kind, minimum, pts.size()]}
			graphic["points"] = pts
	return {"ok": true, "graphic": graphic}


## Does `world_pos` (board mm) land on this graphic's painted body, within
## `tolerance` mm?
##
## Lives HERE rather than in pcb_canvas.gd because it is geometry, not view: the
## canvas owns only the zoom that produces the tolerance. Keeping it beside
## display() also means the pick and the paint walk the SAME strokes — a hit test
## that re-derived the geometry could disagree with what the user can see, which
## is the worst way a pick can fail.
static func hit_test(graphic: Dictionary, world_pos: Vector2, tolerance: float) -> bool:
	var shown := display(graphic)
	var circle: Variant = shown["circle"]
	if circle != null:
		var c: Vector2 = (circle as Dictionary)["center"]
		var r: float = float((circle as Dictionary)["radius"])
		return absf(world_pos.distance_to(c) - r) <= tolerance
	var closed: bool = shown["closed"]
	for stroke in shown["polylines"]:
		var pts: Array = stroke
		var count := pts.size()
		if count < 2:
			continue
		var span := count if closed else count - 1
		for j in span:
			var a: Vector2 = pts[j]
			var b: Vector2 = pts[(j + 1) % count]
			if Geometry2D.get_closest_point_to_segment(world_pos, a, b) \
					.distance_to(world_pos) <= tolerance:
				return true
	return false


## A one-line summary for list/describe replies and delete confirmations.
static func summary(graphic: Dictionary) -> Dictionary:
	var out := {
		"graphic_id": graphic_id(graphic),
		"layer": layer_of(graphic),
		"kind": str(graphic.get("kind", "")),
		"width_mm": width_of(graphic),
		"bounds": bounds_dict(graphic),
	}
	if str(graphic.get("kind", "")) == "text":
		out["text"] = str(graphic.get("text", ""))
		out["size_mm"] = float(graphic.get("size_mm", DEFAULT_TEXT_SIZE_MM))
		out["rotation_deg"] = float(graphic.get("rotation_deg", 0.0))
		out["mirrored"] = mirror_for(graphic)
		var missing: Array = display(graphic)["missing"]
		if not missing.is_empty():
			out["missing_glyphs"] = missing
	return out
