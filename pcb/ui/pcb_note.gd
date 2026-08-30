extends RefCounted
## THE NOTE A PCB TAB HANDS THE HOST — the plugin_data note behind Save to Note
## and the chat-inject toggle, and the restore that reopens the board from it.
##
## Without these hooks the host falls back to a raw screenshot of the panel
## viewport (Editor._create_plugin_scene_screenshot_note): a flat image note of
## whatever camera the user was on, carrying no board, so the note cannot be
## reopened and a zoomed-in tab injects a corner of the board into the chat.
##
## Three parts, and the split between them is the design:
##
##   payload    the SAVED board dict — PCBData.to_saved_board_dict, the exact
##              shape _on_panel_save_request writes to a .pcbskel and
##              from_board_dict reads back. Restoring it into a fresh panel
##              therefore yields the same board, and a note written on one
##              machine does not carry this machine's library resolution
##              (that is what "saved" strips).
##
##   preview    the canvas rendered FIT TO THE BOARD, off-screen, at a
##              resolution where the designators survive — not a crop of the
##              live camera. Same capture body minerva_pcb_get_image uses.
##
##   alt text   a caption of facts the model ALREADY HOLDS: name, size, stack,
##              fabrication stage, counts, source path. NOTHING IS COMPUTED FOR
##              THE NOTE — no DRC, no worker round trip, no pour fill. A note is
##              what the user is looking at, and making it a report card would
##              both stall the toggle on a worker call and put a verdict in the
##              chat that no one asked for.
##
## The create hook is a coroutine: the host awaits it, so the preview comes
## from the same awaiting pcb_canvas.capture_to_image the MCP image export
## uses — one capture path, one framing.
##
## A capture that cannot run (headless, canvas detached) leaves preview_image
## out of the note. The host then substitutes its own panel screenshot where it
## can take one; where it cannot, the host drops the plugin_data shape and the
## note degrades to a plain screenshot note.

const PcbViewFit := preload("pcb_view_fit.gd")

## Payload schema version. Restore refuses anything else rather than guessing.
const PAYLOAD_VERSION := 1

## The preview's long edge in pixels. 1536 is the largest edge the image-carrying
## providers keep unscaled, and over a 100 mm board it resolves ~15 px per mm —
## a 1 mm silk designator lands ~15 px tall, which is the point of the whole
## fit-to-board capture. Larger boards degrade in legibility rather than in
## framing: the whole board is always in frame.
const PREVIEW_LONG_EDGE_PX := 1536

## Floor for the short edge, so a pathologically elongated board still produces
## an image with area. It is the ONE case where the preview's aspect stops
## matching the board's — a board over 24:1.
const PREVIEW_MIN_EDGE_PX := 64


## The plugin_data note for this board, in the shape Editor's
## _build_note_from_plugin_payload consumes. `data` is a PCBData, `canvas` the
## live pcb_canvas (may be null / detached), `source_path` the canonical YAML
## the board was adopted from ("" when it has none).
##
## Returns {} when there is no board at all — the host then reports an
## unusable payload and screenshots, which is the honest outcome for a panel
## with no model.
static func build_note(ctx: Dictionary, data, canvas, source_path: String) -> Dictionary:
	if data == null:
		return {}
	var payload: Dictionary = {
		"version": PAYLOAD_VERSION,
		"board": data.to_saved_board_dict(),
	}
	if not source_path.is_empty():
		payload["source_path"] = source_path
	var note: Dictionary = {
		"kind": "plugin_data",
		"plugin_id": "pcb",
		# The manifest's panel name, not the scene's: Note._open_linked_plugin_panel
		# reopens the note by (plugin_id, panel_name) through
		# add_plugin_scene_editor, which resolves the name against manifest.json.
		"panel_name": str(ctx.get("panel_name", "pcb_panel")),
		"payload": payload,
		"preview_alt_text": caption(data, source_path),
	}
	var preview: Image = await capture_preview(canvas, data)
	if preview != null and not preview.is_empty():
		note["preview_image"] = preview
	return note


## Rebuild `data` from a note payload written by build_note. Returns false —
## leaving the board untouched — for a payload from a schema this code does not
## know, or one whose board is not a Dictionary; the host toasts and leaves the
## panel on whatever it was showing.
##
## The source path is deliberately NOT adopted: adopting it would point Ctrl+S
## and the annotation-sidecar writer at a file this restore never read sidecars
## from. The note carries the path so the caption can name it, not so the panel
## can claim it.
static func restore_board(payload: Dictionary, data) -> bool:
	if data == null:
		return false
	if int(payload.get("version", 0)) != PAYLOAD_VERSION:
		push_warning("[pcb] restore_from_note: unsupported payload version %s"
			% str(payload.get("version", null)))
		return false
	var board_v: Variant = payload.get("board", null)
	if not (board_v is Dictionary):
		push_warning("[pcb] restore_from_note: payload.board is not a Dictionary")
		return false
	data.from_board_dict(board_v as Dictionary)
	return true


## The board's own facts, one line, in the order a reader needs them: which
## board, how big, what stack, how far along, how much of each thing, and where
## it came from. This is the note's alt text, and — for a provider with no image
## channel — the only thing the model gets, which is why it names the board
## rather than describing the picture.
static func caption(data, source_path: String) -> String:
	if data == null:
		return "PCB board (no board loaded)"
	var parts: Array[String] = [
		str(data.board_name),
		"%s x %s mm, %s, stage %s" % [
			_mm(float(data.board_width)), _mm(float(data.board_height)),
			_count(data.layers.size(), "layer"),
			str(data.fabrication_stage),
		],
		"%s, %s, %s, %s" % [
			_count(data.get_component_count(), "component"),
			_count(data.get_net_count(), "net"),
			_count(data.get_trace_count(), "trace"),
			_count(data.vias.size(), "via"),
		],
	]
	if not source_path.is_empty():
		parts.append(source_path)
	return " — ".join(parts)


## Render the preview off-screen through the canvas's own capture. Null (no
## preview) when there is no canvas, when it is detached, or in a headless run
## with no render target.
static func capture_preview(canvas, data) -> Image:
	if canvas == null or not is_instance_valid(canvas):
		return null
	if not canvas.has_method("capture_to_image"):
		return null
	var size: Vector2i = preview_size(data)
	return await canvas.capture_to_image(size.x, size.y, true)


## The capture size: the board content's OWN aspect, scaled so the long edge is
## PREVIEW_LONG_EDGE_PX.
##
## Matching the content aspect is what makes the board fill the note.
## pcb_view_fit pads by a fraction of the content per side (so the padded rect
## keeps the content's aspect) and then fits on the tighter axis — into a
## viewport of the same aspect that spends nothing on letterboxing. Capturing
## into the PANE's aspect instead would give a wide board in a tall dock a band
## of background top and bottom and shrink the designators by that same factor.
##
## "Content" is pcb_view_fit's: the board outline union every component's
## bounds, so the fit here and the fit on screen frame the same thing.
static func preview_size(data) -> Vector2i:
	var content: Rect2 = PcbViewFit.board_content_rect(data)
	if content.size.x <= 0.0 or content.size.y <= 0.0:
		return Vector2i(PREVIEW_LONG_EDGE_PX, PREVIEW_LONG_EDGE_PX)
	var scale: float = float(PREVIEW_LONG_EDGE_PX) / maxf(content.size.x, content.size.y)
	return Vector2i(
		maxi(int(roundf(content.size.x * scale)), PREVIEW_MIN_EDGE_PX),
		maxi(int(roundf(content.size.y * scale)), PREVIEW_MIN_EDGE_PX))


## A millimetre figure with no trailing zeros: 60.0 reads "60", 39.37 reads
## "39.37". A caption is prose, and "60.00 x 40.00 mm" reads like a measurement
## someone took rather than a board someone drew.
static func _mm(value: float) -> String:
	var text := String.num(value, 2)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text


static func _count(n: int, noun: String) -> String:
	return "%d %s%s" % [n, noun, "" if n == 1 else "s"]
