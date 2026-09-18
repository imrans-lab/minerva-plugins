extends Control
## One selection and edit path for the viewport controls and MCP.
const Point := preload("CadPointAnchor.gd")
const Records := preload("reference_selection.gd")
const Freshness := preload("eval_freshness.gd")
var panel: Control
var mode := ""
var axis := 0
var drag: Dictionary = {}
var history: Array = []
var cursor := 0

func setup(owner_panel: Control) -> void:
	panel = owner_panel
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_ALL
	for key in ["Select", "Translate", "Rotate"]:
		var button: Button = panel.get_node("ObjectDock/Tools/" + key)
		panel._build._set_icon(button, key.to_lower() + ".svg", key)
		button.pressed.connect(func(): set_mode(key.to_lower()))
	panel.get_node("ObjectDock/Axis").item_selected.connect(func(index: int): axis = index)
	panel.annotation_tool_status_changed.connect(refresh)
	panel.get_annotation_host().view_changed.connect(queue_redraw)

func set_mode(value: String) -> void:
	drag.clear()
	mode = value
	mouse_filter = Control.MOUSE_FILTER_IGNORE if mode.is_empty() else Control.MOUSE_FILTER_STOP
	if not mode.is_empty():
		var overlay := panel.find_child("PlatformAnnotationOverlay", true, false)
		if overlay != null:
			overlay.set_active_tool(null)
		grab_focus()
	for key in ["Select", "Translate", "Rotate"]:
		panel.get_node("ObjectDock/Tools/" + key).set_pressed_no_signal(mode == key.to_lower())
	refresh()

func refresh() -> void:
	if panel == null:
		return
	var selected: Dictionary = panel.get_reference_selection()
	var label: Label = panel.get_node("ObjectDock/Selection")
	label.text = str(selected.get("object_id", "No object selected"))
	label.tooltip_text = "Read identity, source and surface point with minerva_cad_object."
	queue_redraw()

func _has_point(point: Vector2) -> bool:
	# The canvas also spans the toolbar for annotation coordinates. Only the
	# actual viewports belong to object interaction; let toolbar clicks through.
	if panel == null:
		return false
	for pane: Dictionary in panel.get_annotation_host().get_panes():
		if (pane.viewport_rect as Rect2).has_point(point):
			return true
	return false

func _gui_input(event: InputEvent) -> void:
	if mode.is_empty():
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		drag.clear()
		set_mode("select")
		accept_event()
		return
	if event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			panel.get_annotation_host().forward_navigation_input(event)
			accept_event()
			return
		if event.pressed:
			grab_focus()
			var hit: Dictionary = panel.get_annotation_host().pick_surface(event.position)
			if not hit.is_empty():
				panel._reference_selection.select_hit(hit, panel.get_annotation_host().get_active_viewport(), event.position)
				if mode != "select":
					var plan := placement()
					if plan.has("error"):
						message(str(plan.error))
					else:
						drag = {"pixel": event.position, "plan": plan, "value": 0.0, "mode": mode, "axis": axis}
			else:
				panel._reference_selection.clear_selection()
		elif not drag.is_empty():
			var pending := drag.duplicate(true)
			drag.clear()
			if absf(pending.value) > 0.00001:
				var reply := transform_object(pending.plan, pending.mode, pending.axis, pending.value)
				message(str(reply.get("error", "Placement written to DSL")))
		refresh()
		accept_event()
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			panel.get_annotation_host().forward_navigation_input(event)
		elif not drag.is_empty():
			if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
				drag.clear()
			else:
				var delta: Vector2 = event.position - drag.pixel
				drag.value = delta.x if drag.mode == "rotate" else translation_distance(delta, drag)
				message("%s %s: %.2f %s · release to apply, Esc to cancel" % [drag.mode.capitalize(), "XYZ"[axis], drag.value, "mm" if drag.mode == "translate" else "°"])
			queue_redraw()
		accept_event()
	elif event is InputEventGesture:
		panel.get_annotation_host().forward_navigation_input(event)
		accept_event()

func placement() -> Dictionary:
	var freshness := Freshness.read(panel)
	if bool(freshness.get("stale", false)):
		return {"error": "Build latest source before moving an object."}
	var selected: Dictionary = panel.get_reference_selection()
	var state: Dictionary = panel.get_evaluation_state()
	var entry: Dictionary = state.get("model", {}).get("placements", {}).get(str(selected.get("object_id", "")), {})
	if entry.is_empty():
		return {"error": "This occurrence has no independent editable placement. Edit its DSL definition."}
	var result := entry.duplicate(true)
	result["source"] = panel._current_source()
	result["version"] = panel._buffer_version
	return result

func translation_distance(delta: Vector2, pending: Dictionary) -> float:
	var origin := Point.vec3_from([pending.plan.matrix[0][3], pending.plan.matrix[1][3], pending.plan.matrix[2][3]])
	var direction := Vector3.ZERO
	direction[int(pending.axis)] = 1.0
	for pane: Dictionary in panel.get_annotation_host().get_panes():
		if not (pane.viewport_rect as Rect2).has_point(pending.pixel):
			continue
		var camera: Camera3D = pane.camera
		var projected := camera.unproject_position(origin + direction) - camera.unproject_position(origin)
		if projected.length_squared() < 0.01:
			return 0.0
		return delta.dot(projected) / projected.length_squared()
	return 0.0

func transform_object(plan: Dictionary, operation: String, coordinate_axis: int, amount: float) -> Dictionary:
	if operation not in ["translate", "rotate"] or coordinate_axis < 0 or coordinate_axis > 2 or not is_finite(amount):
		return {"success": false, "error": "Expected translate/rotate, axis 0..2 and a finite amount."}
	if plan.has("error"):
		return {"success": false, "error": plan.error}
	if str(plan.source) != panel._current_source() or int(plan.version) != panel._buffer_version:
		return {"success": false, "error": "Source changed during the gesture; placement was not written."}
	var vector := Vector3.ZERO
	vector[coordinate_axis] = amount
	var expression := str(plan.expression)
	if operation == "translate":
		expression = "translate(%s, %s)" % [JSON.stringify(vec(vector)), expression]
	else:
		var pivot := Vector3(plan.matrix[0][3], plan.matrix[1][3], plan.matrix[2][3])
		expression = "translate(%s, rotate(%s, translate(%s, %s)))" % [JSON.stringify(vec(pivot)), JSON.stringify(vec(vector)), JSON.stringify(vec(-pivot)), expression]
	var before := str(plan.source)
	var after := before.substr(0, int(plan.start)) + expression + before.substr(int(plan.end))
	panel._apply_source_edit(after)
	remember({"kind": "source", "before": before, "after": after})
	return {"success": true, "source_version": panel._buffer_version, "build": panel.build_status()}

func remember(change: Dictionary) -> void:
	history.resize(cursor)
	history.append(change)
	if history.size() > 100:
		history.pop_front()
	cursor = history.size()

func undo(redo: bool) -> Dictionary:
	var index := cursor if redo else cursor - 1
	if index < 0 or index >= history.size():
		return {"success": false, "error": "No CAD edit to redo" if redo else "No CAD edit to undo"}
	var change: Dictionary = history[index]
	var expected: Variant = change.before if redo else change.after
	var replacement: Variant = change.after if redo else change.before
	if change.kind == "source":
		if panel._current_source() != str(expected):
			return {"success": false, "error": "Source has newer edits; use the text editor undo history."}
		panel._apply_source_edit(str(replacement))
	else:
		var host: Object = panel.get_annotation_host()
		var current := annotation(str(change.id))
		if current != expected:
			return {"success": false, "error": "Annotation changed since this CAD edit."}
		host.update_annotation(str(change.id), replacement)
	cursor += 1 if redo else -1
	queue_redraw()
	return {"success": true}

func annotation(id: String) -> Dictionary:
	for entry: Dictionary in panel.get_annotation_host().get_annotations():
		if str(entry.id) == id:
			return entry.duplicate(true)
	return {}

func message(text: String) -> void:
	panel.get_node("ObjectDock/Status").text = text

static func vec(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _draw() -> void:
	if panel == null:
		return
	var selected: Dictionary = panel.get_reference_selection()
	if selected.is_empty() or bool(selected.get("stale", false)):
		return
	var box: AABB = selected.get("world_aabb", AABB())
	var preview := Transform3D.IDENTITY
	if not drag.is_empty():
		var direction := Vector3.ZERO
		direction[int(drag.axis)] = 1.0
		if drag.mode == "translate":
			preview.origin = direction * float(drag.value)
		else:
			var pivot := Vector3(drag.plan.matrix[0][3], drag.plan.matrix[1][3], drag.plan.matrix[2][3])
			preview.basis = Basis(direction, deg_to_rad(drag.value))
			preview.origin = pivot - preview.basis * pivot
	for pane: Dictionary in panel.get_annotation_host().get_panes():
		var camera: Camera3D = pane.camera
		var rect: Rect2 = pane.viewport_rect
		for i in range(8):
			for j in range(i + 1, 8):
				var xor_value := i ^ j
				if xor_value not in [1, 2, 4]:
					continue
				var a := preview * box.get_endpoint(i)
				var b := preview * box.get_endpoint(j)
				if camera.is_position_behind(a) or camera.is_position_behind(b):
					continue
				var start := camera.unproject_position(a) + rect.position
				var end := camera.unproject_position(b) + rect.position
				if rect.has_point(start) and rect.has_point(end):
					draw_line(start, end, Color(0.1, 0.65, 1.0), 2.0)
