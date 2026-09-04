extends Node
## One pane's left click, turned into a reference-node pick.
##
## WHY THIS IS A Node AND NOT A Control. The edge overlay (Cad_GeometryOverlay)
## is a Control and picks edges in _gui_input, consuming the clicks it uses.
## GUI input is delivered before unhandled input, so a plain Node that only
## implements _unhandled_input can only ever see a click the edge path did not
## take. That ordering — not a flag, not a priority number — is what keeps edge
## selection and node selection from fighting.
##
## The pixel in an unhandled InputEventMouseButton inside a SubViewport is
## already in that SubViewport's own coordinates, which is the frame
## CADPanel.get_pick_ray() and minerva_cad_probe both speak.
##
## Scene-declared: one per SubViewport in CADPanel.tscn, with view_id set to
## the pane's name. CADPanel's reference_selection module calls setup().

## Which pane this node watches: "top", "front", "right", "iso" or "single".
@export var view_id: String = "iso"

## Called with (view_id, pixel); returns true when the click selected
## something, in which case the event is marked handled so it does not also
## reach the camera.
var _handler: Callable = Callable()


func setup(handler: Callable) -> void:
	_handler = handler


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	if not _handler.is_valid():
		return
	if bool(_handler.call(view_id, button.position)):
		var viewport := get_viewport()
		if viewport != null:
			viewport.set_input_as_handled()
