extends VBoxContainer
## The sidebar section that PUTS A PART ON THE BOARD.
##
## Before this there was no such affordance at all: a human working from the
## GUI could move, rotate and delete parts but could not add one, and an agent's
## only add built ESTIMATED geometry the hermetic worker then refused by name —
## which took the whole board's geometric DRC and every pour fill down with it.
## Adding a part was, in practice, YAML-only.
##
## THE REF IS THE INPUT, deliberately. A footprint ref ("LibNick:PartName") is
## what the worker's library chain resolves, so a part added this way carries
## the library's own lands and silk and is fabricable the moment it lands. The
## field is free text rather than a picker because the library is thousands of
## parts deep and the ref is a thing a human copies from a datasheet, a
## footprint report, or an agent's message — a dropdown over that set would be
## slower than typing and would still need a search box.
##
## THE SKETCH TYPES stay reachable from the same field: typing one of the
## generic names (HEADER, RESISTOR, …) places a sketch part, which is a real
## design act — you place the tap before you have chosen the connector. What
## the section will not do is let that happen silently; the note under the
## field says what a sketch part costs BEFORE it is placed, and the panel's
## held lead names every one on the board until it resolves or goes.
##
## THE GESTURE RUNS THE MCP VERB, not a private path: the same
## panel_tools.handle("minerva_pcb_add_component") an agent calls, with the
## panel as the host. GUI and MCP therefore place the same part and refuse the
## same things, which is the parity rule stated as code rather than as
## discipline.
##
## Built in code rather than as a .tscn, like every other section of this
## sidebar: the panel has no sub-scene precedent and its GD suites mount
## PCBPanel.gd standalone, where a plugin-directory .tscn is not reachable
## through res://.
##
## Off-tree script — NO class_name, reached by relative preload.

const _PanelTools := preload("panel_tools.gd")

## An example that resolves against the shipped seed library, so the empty
## field teaches the shape of the answer instead of only demanding one.
const PLACEHOLDER := "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical"

var _ref_edit: LineEdit = null
var _add_button: Button = null
var _note_label: Label = null

## The board host the verb runs against (the panel), and the panel's status
## writer. Both are seams the panel owns; nothing else here reaches into it.
var _panel = null
var _status: Callable = Callable()


func _init() -> void:
	name = "AddPartSection"

	var header := Label.new()
	header.name = "AddPartHeader"
	header.text = "Add Part"
	header.add_theme_font_size_override("font_size", 11)
	add_child(header)

	_ref_edit = LineEdit.new()
	_ref_edit.name = "AddPartRef"
	_ref_edit.placeholder_text = PLACEHOLDER
	_ref_edit.tooltip_text = "Library footprint ref \"LibNick:PartName\" — the part lands with the library's own pads and silk, fabricable immediately. A generic type (HEADER, RESISTOR, …) places a SKETCH part instead: the fab cannot build it and the status line will say so."
	_ref_edit.text_submitted.connect(func(_t: String) -> void: _submit())
	_ref_edit.text_changed.connect(func(_t: String) -> void: _refresh())
	add_child(_ref_edit)

	_add_button = Button.new()
	_add_button.name = "AddPartButton"
	_add_button.text = "Add Part"
	_add_button.disabled = true
	_add_button.pressed.connect(_submit)
	add_child(_add_button)

	# The sketch warning is shown BEFORE the part is placed, not after: the
	# whole defect this section closes is finding out afterwards.
	_note_label = Label.new()
	_note_label.name = "AddPartNote"
	_note_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_note_label.add_theme_font_size_override("font_size", 10)
	add_child(_note_label)
	_refresh()


## Hand the section the two panel seams it runs on. Until this is called the
## button still draws but refuses, rather than reaching for a null host.
func bind_panel(panel, status: Callable) -> void:
	_panel = panel
	_status = status


## The ref currently typed, trimmed.
func typed_ref() -> String:
	return _ref_edit.text.strip_edges() if _ref_edit != null else ""


## Where a part dropped from this section should land: the centre of what the
## human is LOOKING at, so an add while zoomed in does not appear off-screen.
## Falls back to the middle of the board when there is no canvas to ask.
func drop_point() -> Vector2:
	var data = _panel.get_data() if _panel != null and _panel.has_method("get_data") else null
	var canvas = _panel.get_board_canvas() if _panel != null and _panel.has_method("get_board_canvas") else null
	if canvas != null and canvas.has_method("screen_to_world"):
		return canvas.screen_to_world(canvas.size * 0.5)
	if data != null:
		return Vector2(data.board_width * 0.5, data.board_height * 0.5)
	return Vector2.ZERO


## Run the add. THE SAME VERB an agent calls — see the header.
func _submit() -> void:
	var ref := typed_ref()
	if ref.is_empty():
		return
	if _panel == null:
		_say("Add unavailable — the panel is not ready.")
		return
	var at := drop_point()
	_say("Adding %s…" % ref)
	var reply: Dictionary = await _PanelTools.handle(_panel,
		"minerva_pcb_add_component", {"footprint": ref, "x": at.x, "y": at.y})
	_say(result_line(reply))
	if bool(reply.get("success", false)):
		_ref_edit.text = ""
		_refresh()


## What the status line says about a finished add. Static and pure so the words
## can be asserted without a panel: a refusal quotes its own reason, a
## fabricable part says which library layer supplied it, and a sketch part is
## called one at the moment it lands.
static func result_line(reply: Dictionary) -> String:
	if not bool(reply.get("success", false)):
		return "Add refused: %s" % str(reply.get("error", "unknown"))
	var geometry: Variant = reply.get("geometry")
	var geo: Dictionary = geometry if geometry is Dictionary else {}
	var landed := "Added %s at (%.2f, %.2f)" % [str(reply.get("component_id", "")),
		float(reply.get("x", 0.0)), float(reply.get("y", 0.0))]
	if bool(geo.get("fabricable", false)):
		return "%s — %d pads from the %s library layer." % [landed,
			int(geo.get("pad_count", 0)), str(reply.get("footprint_layer", ""))]
	# The panel's held lead already names it; this says which gesture put it there.
	return "%s as a SKETCH part — the fab cannot build it." % landed


func _say(text: String) -> void:
	if _status.is_valid():
		_status.call(text)


## What the button and the note say about what is typed RIGHT NOW.
func _refresh() -> void:
	var ref := typed_ref()
	if _add_button != null:
		_add_button.disabled = ref.is_empty()
	if _note_label != null:
		_note_label.text = preview_note(ref)


## The one-line verdict on a typed footprint, before anything is placed. Static
## and pure so the words can be asserted directly.
static func preview_note(ref: String) -> String:
	if ref.strip_edges().is_empty():
		return "Type a library footprint ref to place a fabricable part."
	if ref.contains(":"):
		return "Library ref — the part lands with real pads and silk. An unknown ref is refused by name and nothing is added."
	return "SKETCH part: estimated geometry with no library behind it. The fab cannot build it, and while it is on the board the geometric DRC and every pour fill are unavailable."
