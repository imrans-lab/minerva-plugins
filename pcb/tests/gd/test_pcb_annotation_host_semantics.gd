extends SceneTree
## PcbAnnotationHost board-space semantics test (annotation-migration round).
##
## Run: godot --headless --path src --script test/test_pcb_annotation_host_semantics.gd
##
## Fixes gap-register W-9: annotation markers must track board coordinates
## through zoom/pan (the host previously used an identity transform). Covers:
##   1. Board-mm↔screen transform bound to the live canvas — round-trips at
##      zoom=1 AND at a set zoom/pan, matching pcb_canvas.world_to_screen exactly.
##   2. describe_point precedence: pad → component → trace → canvas.point fallback.
##   3. anchored_to stamped on add (via AnnotationHost._stamp_anchor + describe_point).
##   4. canvas pan/zoom pokes the host's view_changed (the overlay redraw seam).
##   5. no-canvas fallback: identity transforms + bare-point describe_point, no crash.
##
## Off-tree scripts are load()ed at RUNTIME (res:// == src/, so
## res://../../minerva-plugins == C:/github/minerva-plugins) — a bad path FAILS a
## test rather than aborting the whole script at parse time. Everything is
## duck-typed (never typed AS a plugin class), matching the off-tree contract.

const PLUGIN_UI := "res://../../minerva-plugins/pcb/ui/"
const HOST_PATH := PLUGIN_UI + "PcbAnnotationHost.gd"
const CANVAS_PATH := PLUGIN_UI + "pcb_canvas.gd"
const DATA_PATH := PLUGIN_UI + "model/pcb_data.gd"
const COMPONENT_PATH := PLUGIN_UI + "model/pcb_component.gd"
const TRACE_PATH := PLUGIN_UI + "model/pcb_trace.gd"
const KIND_PATH := PLUGIN_UI + "kinds/pcb_route_hint_kind.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _Host: Script = null
var _Canvas: Script = null
var _Data: Script = null
var _Component: Script = null
var _Trace: Script = null
var _Kind: Script = null


func _init() -> void:
	print("=== PcbAnnotationHost Board-Space Semantics ===\n")
	await process_frame

	_Host = load(HOST_PATH)
	_Canvas = load(CANVAS_PATH)
	_Data = load(DATA_PATH)
	_Component = load(COMPONENT_PATH)
	_Trace = load(TRACE_PATH)
	_Kind = load(KIND_PATH)
	check("all off-tree scripts load",
			_Host != null and _Canvas != null and _Data != null
			and _Component != null and _Trace != null and _Kind != null)
	if _Host == null:
		_finish()
		return

	_test_transform_roundtrip()
	_test_describe_point_precedence()
	_test_anchored_to_stamped_on_add()
	_test_view_changed_poke()
	_test_no_canvas_fallback()

	# ── Semantic-anchor round additions ──
	_test_resolve_semantic_anchors()
	_test_resolve_rotated_pad()
	_test_stale_fallback()
	_test_anchor_summaries()
	_test_anchor_registry_repair()
	_test_repair_route_hint_endpoints()
	_test_kind_validate_payload()
	_test_kind_path_hit_test()
	_test_kind_summary_string()
	_test_author_tool_multiclick()
	_test_capabilities()
	_test_build_route_hint_envelope_width_mm_absent_by_default()
	_test_render_mode_gate()
	_test_render_mode_superseded()
	_test_canvas_none_mode_gates()
	_test_consumed_selection_veto()
	_test_marker_zoom_curve()
	_test_superseded_refusal_and_release()
	_test_reconcile_strip_bookkeeping()

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Fixtures ──────────────────────────────────────────────────────────────────

## Build a board: R1 (resistor) @ (10,10) with pins 1/2, U3 (IC_DIP) @ (30,20),
## and a GND trace along y=30 away from both parts.
func _make_board():
	var data = _Data.new()
	data.board_width = 60.0
	data.board_height = 40.0

	var r1 = _Component.new()
	r1.id = "R1"
	r1.set_footprint_by_name("RESISTOR")
	r1.position = Vector2(10.0, 10.0)
	r1.setup_standard_pins()   # pin "1"@(0,0), "2"@(2.54,0)
	data.add_component(r1)

	var u3 = _Component.new()
	u3.id = "U3"
	u3.set_footprint_by_name("IC_DIP")
	u3.position = Vector2(30.0, 20.0)
	u3.setup_standard_pins()
	data.add_component(u3)

	var t = _Trace.new()
	t.net_name = "GND"
	t.layer = "top"
	t.width = 0.25
	t.add_waypoint(Vector2(5.0, 30.0))   # typed Array[Vector2] — append, don't reassign
	t.add_waypoint(Vector2(20.0, 30.0))
	data.add_trace(t)

	return data


func _make_canvas(data):
	var canvas = _Canvas.new()
	canvas.size = Vector2(800.0, 600.0)
	canvas.set_data(data)
	return canvas


# ── 1. Transform round-trip ───────────────────────────────────────────────────

func _test_transform_roundtrip() -> void:
	print("-- board-mm↔screen transform tracks the live canvas --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var probes: Array = [Vector2(10.0, 10.0), Vector2(0.0, 0.0), Vector2(-7.5, 22.25)]

	# zoom=1, pan=0 — screen == doc + size/2 (doc != screen, but round-trips).
	canvas.zoom = 1.0
	canvas.pan_offset = Vector2.ZERO
	check("get_annotation_zoom reflects canvas zoom=1", is_equal_approx(host.get_annotation_zoom(), 1.0))
	for p in probes:
		var screen: Vector2 = host.transform_doc_to_screen(p)
		check("doc→screen matches canvas.world_to_screen @z=1 %s" % str(p),
				screen.is_equal_approx(canvas.world_to_screen(p)),
				"host=%s canvas=%s" % [str(screen), str(canvas.world_to_screen(p))])
		check("doc→screen→doc round-trips @z=1 %s" % str(p),
				host.transform_screen_to_doc(screen).is_equal_approx(p))
	check("z=1 origin is size/2 (doc 0,0 → 400,300)",
			host.transform_doc_to_screen(Vector2.ZERO).is_equal_approx(Vector2(400.0, 300.0)))

	# A set zoom + pan — assert the transform math + inverse round-trip.
	canvas.zoom = 4.0
	canvas.pan_offset = Vector2(50.0, -30.0)
	check("get_annotation_zoom reflects canvas zoom=4", is_equal_approx(host.get_annotation_zoom(), 4.0))
	for p in probes:
		var screen: Vector2 = host.transform_doc_to_screen(p)
		check("doc→screen matches canvas.world_to_screen @z=4,pan %s" % str(p),
				screen.is_equal_approx(canvas.world_to_screen(p)),
				"host=%s canvas=%s" % [str(screen), str(canvas.world_to_screen(p))])
		check("doc→screen→doc round-trips @z=4,pan %s" % str(p),
				host.transform_screen_to_doc(screen).is_equal_approx(p))
	# view_transform is the same affine the overlay applies.
	var xf: Transform2D = host.get_annotation_view_transform()
	check("get_annotation_view_transform == doc→screen affine",
			(xf * Vector2(10.0, 10.0)).is_equal_approx(host.transform_doc_to_screen(Vector2(10.0, 10.0))))

	canvas.free()


# ── 2. describe_point precedence ──────────────────────────────────────────────

func _test_describe_point_precedence() -> void:
	print("\n-- describe_point precedence: pad → component → trace → fallback --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	# pad — exactly on R1 pin 1 (10,10) and pin 2 (12.54,10).
	check("pad hit on pin 1 → 'pad:R1.1'",
			host.describe_point(Vector2(10.0, 10.0)) == "pad:R1.1",
			host.describe_point(Vector2(10.0, 10.0)))
	check("pad hit on pin 2 → 'pad:R1.2'",
			host.describe_point(Vector2(12.54, 10.0)) == "pad:R1.2",
			host.describe_point(Vector2(12.54, 10.0)))

	# component — inside R1's body but >1mm from either pin.
	check("body hit (not a pad) → 'component:R1'",
			host.describe_point(Vector2(11.27, 10.6)) == "component:R1",
			host.describe_point(Vector2(11.27, 10.6)))

	# trace — on the GND polyline, away from all parts.
	check("trace hit → 'trace:GND'",
			host.describe_point(Vector2(12.5, 30.0)) == "trace:GND",
			host.describe_point(Vector2(12.5, 30.0)))

	# fallback — empty board space.
	check("empty space → 'canvas.point (x, y) mm'",
			host.describe_point(Vector2(50.0, 5.0)) == "canvas.point (50.0, 5.0) mm",
			host.describe_point(Vector2(50.0, 5.0)))

	canvas.free()


# ── 3. anchored_to stamped on add ─────────────────────────────────────────────

func _test_anchored_to_stamped_on_add() -> void:
	print("\n-- anchored_to stamped on add via describe_point --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var pad_id: String = host.add_route_hint_at(10.0, 10.0, "keep clear of R1.1")
	check("route hint on pin 1 stamps anchored_to='pad:R1.1'",
			str(host.get_by_id(pad_id).get("anchored_to", "")) == "pad:R1.1",
			str(host.get_by_id(pad_id).get("anchored_to", "")))

	var body_id: String = host.add_route_hint_at(11.27, 10.6, "over R1 body")
	check("route hint over body stamps anchored_to='component:R1'",
			str(host.get_by_id(body_id).get("anchored_to", "")) == "component:R1",
			str(host.get_by_id(body_id).get("anchored_to", "")))

	canvas.free()


# ── 4. canvas pan/zoom pokes host.view_changed ────────────────────────────────

func _test_view_changed_poke() -> void:
	print("\n-- canvas pan/zoom pokes host.view_changed (overlay redraw seam) --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var spy := {"count": 0}
	host.view_changed.connect(func() -> void: spy.count += 1)

	canvas._zoom_at(canvas.size / 2.0, 1.2)
	check("canvas zoom pokes host.view_changed", spy.count >= 1,
			"count=%d" % spy.count)

	var before: int = spy.count
	canvas._center_view()
	check("canvas pan (center) pokes host.view_changed", spy.count > before,
			"before=%d after=%d" % [before, spy.count])

	canvas.free()


# ── 5. no-canvas fallback (headless / pre-mount) ──────────────────────────────

func _test_no_canvas_fallback() -> void:
	print("\n-- no-canvas host: identity transforms + bare-point describe, no crash --")
	var host = _Host.new()   # never set_canvas

	check("no-canvas view transform is identity",
			host.get_annotation_view_transform() == Transform2D.IDENTITY)
	check("no-canvas doc→screen is identity",
			host.transform_doc_to_screen(Vector2(5.0, 7.0)) == Vector2(5.0, 7.0))
	check("no-canvas screen→doc is identity",
			host.transform_screen_to_doc(Vector2(5.0, 7.0)) == Vector2(5.0, 7.0))
	check("no-canvas zoom is 1.0", is_equal_approx(host.get_annotation_zoom(), 1.0))
	check("no-canvas describe_point → bare board point",
			host.describe_point(Vector2(5.0, 7.0)) == "canvas.point (5.0, 7.0) mm",
			host.describe_point(Vector2(5.0, 7.0)))
	check("no-canvas render_content_to_image → null (safe)",
			host.render_content_to_image(Rect2()) == null)
	# Adding still works (stamps a bare-point anchored_to, no crash).
	var id: String = host.add_route_hint_at(3.0, 4.0, "headless")
	check("no-canvas add still stamps a bare-point anchored_to",
			str(host.get_by_id(id).get("anchored_to", "")) == "canvas.point (3.0, 4.0) mm",
			str(host.get_by_id(id).get("anchored_to", "")))


# ──────────────────────────────────────────────────────────────────────────────

# ── Semantic anchor helpers ───────────────────────────────────────────────────

func _pad_anchor(component: String, pin: String, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "pad", "id": {"component": component, "pin": pin},
			"snapshot": {"position": [snap.x, snap.y]}}


func _component_anchor(comp_id: String, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "component", "id": comp_id,
			"snapshot": {"position": [snap.x, snap.y]}}


func _net_anchor(net: String, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "net", "id": net,
			"snapshot": {"position": [snap.x, snap.y]}}


func _trace_anchor(id: Variant, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "trace", "id": id,
			"snapshot": {"position": [snap.x, snap.y]}}


# ── 6. resolve semantic anchors (pad/component/net/trace) ─────────────────────

func _test_resolve_semantic_anchors() -> void:
	print("\n-- resolve pad/component/net/trace against the live board --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	# pad R1.2 lives at world (12.54, 10) (pin "2" offset (2.54,0), rot 0).
	var r1 = data.get_component("R1")
	var pad_res: Dictionary = host.resolve_anchor(_pad_anchor("R1", "2", Vector2(0, 0)))
	check("pad resolve → live pin world pos",
			pad_res.position.is_equal_approx(r1.get_pin_world_position("2")) and not pad_res.stale,
			"got %s exp %s" % [str(pad_res.position), str(r1.get_pin_world_position("2"))])

	# component U3 origin (30, 20).
	var comp_res: Dictionary = host.resolve_anchor(_component_anchor("U3", Vector2(0, 0)))
	check("component resolve → origin (30,20)",
			comp_res.position.is_equal_approx(Vector2(30.0, 20.0)) and not comp_res.stale,
			str(comp_res.position))

	# net GND — nearest point on the GND trace (y=30 segment x∈[5,20]) to a snapshot
	# at (12.5, 34) is (12.5, 30).
	var net_res: Dictionary = host.resolve_anchor(_net_anchor("GND", Vector2(12.5, 34.0)))
	check("net resolve → nearest trace point (12.5, 30)",
			net_res.position.is_equal_approx(Vector2(12.5, 30.0)) and not net_res.stale,
			str(net_res.position))

	# trace by {net, segment 0} → midpoint of the only segment = (12.5, 30).
	var tr_res: Dictionary = host.resolve_anchor(_trace_anchor({"net": "GND", "segment": 0}, Vector2(0, 0)))
	check("trace resolve → segment-0 midpoint (12.5, 30)",
			tr_res.position.is_equal_approx(Vector2(12.5, 30.0)) and not tr_res.stale,
			str(tr_res.position))

	canvas.free()


# ── 7. rotated-component pad resolves rotation-correct ────────────────────────

func _test_resolve_rotated_pad() -> void:
	print("\n-- rotated component: pad resolves through the rigid-body transform --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	data.rotate_component("R1", 90.0)
	var r1 = data.get_component("R1")
	var res: Dictionary = host.resolve_anchor(_pad_anchor("R1", "2", Vector2(0, 0)))
	check("rotated pad resolve matches get_pin_world_position",
			res.position.is_equal_approx(r1.get_pin_world_position("2")),
			str(res.position))
	check("rotation actually moved the pad (≠ unrotated 12.54,10)",
			not res.position.is_equal_approx(Vector2(12.54, 10.0)),
			str(res.position))
	canvas.free()


# ── 8. stale fallback: deleted target → snapshot + stale flag ─────────────────

func _test_stale_fallback() -> void:
	print("\n-- stale: deleted component → resolve falls back to snapshot, flagged --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var snap := Vector2(12.54, 10.0)
	data.remove_component("R1")
	var res: Dictionary = host.resolve_anchor(_pad_anchor("R1", "2", snap))
	check("deleted pad → position falls back to snapshot", res.position.is_equal_approx(snap), str(res.position))
	check("deleted pad → stale flag set", bool(res.stale) == true)

	var cres: Dictionary = host.resolve_anchor(_component_anchor("R1", Vector2(9.0, 9.0)))
	check("deleted component → stale + snapshot", cres.position.is_equal_approx(Vector2(9.0, 9.0)) and bool(cres.stale))
	canvas.free()


# ── 9. anchor summaries ───────────────────────────────────────────────────────

func _test_anchor_summaries() -> void:
	print("\n-- anchor summaries: pad/component/net/trace --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	check("pad summary 'pad R1.2'", host.anchor_summary(_pad_anchor("R1", "2", Vector2.ZERO)) == "pad R1.2",
			host.anchor_summary(_pad_anchor("R1", "2", Vector2.ZERO)))
	check("component summary 'component U3'", host.anchor_summary(_component_anchor("U3", Vector2.ZERO)) == "component U3")
	check("net summary 'net GND'", host.anchor_summary(_net_anchor("GND", Vector2.ZERO)) == "net GND")
	check("trace summary 'trace GND'", host.anchor_summary(_trace_anchor({"net": "GND"}, Vector2.ZERO)) == "trace GND",
			host.anchor_summary(_trace_anchor({"net": "GND"}, Vector2.ZERO)))
	canvas.free()


# ── 10. anchor registry repair path (documented) ──────────────────────────────

func _test_anchor_registry_repair() -> void:
	print("\n-- get_anchor_registry() repair: refresh snapshot, null when gone --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var reg = host.get_anchor_registry()
	check("get_anchor_registry() is non-null", reg != null)
	if reg == null:
		canvas.free()
		return

	# summary + validate route through the registry adapter.
	check("registry.summary delegates to host ('pad R1.2')",
			reg.summary(_pad_anchor("R1", "2", Vector2.ZERO), host) == "pad R1.2")
	check("registry.validate_anchor flags a missing pad",
			not (reg.validate_anchor(_pad_anchor("R1", "9", Vector2.ZERO)) as Array).is_empty())

	# repair: stale snapshot (0,0) → refreshed to the live pin position.
	var repaired: Variant = reg.repair(_pad_anchor("R1", "2", Vector2.ZERO), host)
	check("repair returns a refreshed anchor Dict", repaired is Dictionary)
	if repaired is Dictionary:
		var r1 = data.get_component("R1")
		var pos: Array = (repaired as Dictionary).get("snapshot", {}).get("position", [])
		check("repair refreshed snapshot to live pin pos",
				pos.size() == 2 and Vector2(pos[0], pos[1]).is_equal_approx(r1.get_pin_world_position("2")),
				str(pos))

	# repair of a deleted target → null (caller marks broken).
	data.remove_component("R1")
	check("repair of a deleted pad → null (broken)", reg.repair(_pad_anchor("R1", "2", Vector2.ZERO), host) == null)
	canvas.free()


# ── 11. route-hint endpoint repair ────────────────────────────────────────────

func _test_repair_route_hint_endpoints() -> void:
	print("\n-- repair_route_hint: all endpoints must exist or the hint is broken --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var env: Dictionary = host.build_route_hint_envelope(
			10.0, 10.0, "", "F.Cu", "single_trace", [[10.0, 10.0], [30.0, 20.0]], "human",
			"", 0.25, ["R1.1"], ["U3.1"])
	env["anchor"] = _pad_anchor("R1", "1", Vector2(10.0, 10.0))

	var ok_res: Dictionary = host.repair_route_hint(env)
	check("intact endpoints → ok, not broken, has refreshed anchor",
			bool(ok_res.get("ok", false)) and not bool(ok_res.get("broken", true)) and ok_res.has("anchor"),
			str(ok_res))

	# Delete the destination component → its pin U3.1 vanishes.
	data.remove_component("U3")
	var broken_res: Dictionary = host.repair_route_hint(env)
	check("missing dest pin → broken, not silently re-anchored",
			not bool(broken_res.get("ok", true)) and bool(broken_res.get("broken", false)),
			str(broken_res))
	check("broken result reports the missing endpoint",
			"U3.1" in (broken_res.get("missing", []) as Array), str(broken_res.get("missing", [])))
	canvas.free()


# ── 12. kind validate on new payload + old skeleton tolerance ─────────────────

func _test_kind_validate_payload() -> void:
	print("\n-- kind.validate: new payload fields + old skeleton envelope --")
	var kind = _Kind.new()

	# Rich, valid envelope (pad anchor + all new fields).
	var rich := {
		"anchor": _pad_anchor("U1", "15", Vector2(12.0, 9.0)),
		"kind_payload": {
			"hint_type": "single_trace", "detail_level": "detailed", "layer": "F.Cu",
			"width_mm": 0.25, "source_pins": ["U1.15"], "dest_pins": ["J2.3"],
			"waypoints": [[12.0, 9.0], [20.0, 9.0]],
		},
	}
	check("rich pad-anchored payload validates clean", (kind.validate(rich) as Array).is_empty(),
			str(kind.validate(rich)))

	# Old skeleton envelope (board.point anchor, minimal payload) still accepted.
	var skeleton := {
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 5.0, "y": 5.0},
				"snapshot": {"position": [5.0, 5.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu", "text": "", "waypoints": []},
	}
	check("old skeleton envelope still validates clean", (kind.validate(skeleton) as Array).is_empty(),
			str(kind.validate(skeleton)))

	# Bad detail_level rejected.
	var bad_detail := rich.duplicate(true)
	bad_detail["kind_payload"]["detail_level"] = "verbose"
	check("bad detail_level rejected", not (kind.validate(bad_detail) as Array).is_empty())

	# Self-referencing endpoint rejected.
	var self_ref := rich.duplicate(true)
	self_ref["kind_payload"]["source_pins"] = ["U1.15"]
	self_ref["kind_payload"]["dest_pins"] = ["U1.15"]
	check("self-referencing source==dest rejected", not (kind.validate(self_ref) as Array).is_empty())

	# Non-array width / bad hint_type rejected.
	var bad_hint := skeleton.duplicate(true)
	bad_hint["kind_payload"]["hint_type"] = "star"
	check("bad hint_type rejected", not (kind.validate(bad_hint) as Array).is_empty())


# ── 13. kind path-based hit test ──────────────────────────────────────────────

func _test_kind_path_hit_test() -> void:
	print("\n-- kind.hit_test: distance-to-segment, not AABB --")
	var kind = _Kind.new()
	var ann := {
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu", "width_mm": 0.0,
				"waypoints": [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0]]},
	}
	check("on-segment point is a hit", kind.hit_test(ann, Vector2(5.0, 0.2), 0.2))
	check("point near the L-corner is a hit", kind.hit_test(ann, Vector2(10.0, 5.0), 0.3))
	# Interior of the L's bounding box but far from any segment → miss (proves it's
	# not an AABB test: (3,7) is inside the 0..10 box but >2mm from both arms).
	check("interior-but-off-path point is a miss", not kind.hit_test(ann, Vector2(3.0, 7.0), 0.3))


# ── 14. kind summary string form ──────────────────────────────────────────────

func _test_kind_summary_string() -> void:
	print("\n-- kind.summary: 'route hint U1.15→J2.3, F.Cu, 0.25mm, N waypoints' --")
	var kind = _Kind.new()
	var ann := {
		"anchor": _pad_anchor("U1", "15", Vector2(0, 0)),
		"kind_payload": {
			"hint_type": "single_trace", "layer": "F.Cu", "width_mm": 0.25,
			"source_pins": ["U1.15"], "dest_pins": ["J2.3"],
			"waypoints": [[0, 0], [4, 0], [4, 4], [8, 4]],
		},
	}
	check("full summary string form",
			kind.summary(ann) == "route hint U1.15→J2.3, F.Cu, 0.25mm, 4 waypoints",
			kind.summary(ann))

	# Empty parts omitted gracefully.
	var sparse := {
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0, "y": 0},
				"snapshot": {"position": [0, 0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "B.Cu", "waypoints": []},
	}
	check("sparse summary omits endpoints/width",
			kind.summary(sparse).begins_with("route hint, B.Cu"), kind.summary(sparse))


# ── 15. author tool multi-click flow ──────────────────────────────────────────

func _test_author_tool_multiclick() -> void:
	print("\n-- author tool: N clicks + commit → annotation_ready with N waypoints --")
	var host = _Host.new()   # no canvas → identity transform, screen == doc
	var kind = _Kind.new()
	var tool = kind.author_ui()
	check("author_ui() returns a tool", tool != null)
	if tool == null:
		return
	tool.on_activate(host)

	var captured := {"env": null, "cancels": 0}
	tool.annotation_ready.connect(func(e: Dictionary) -> void: captured.env = e)
	tool.cancelled.connect(func() -> void: captured.cancels += 1)

	# Three distinct clicks, then a repeat click on the last waypoint
	# (double-click — the commit gesture; the overlay only forwards Escape keys).
	tool.on_pointer_down(Vector2(0.0, 0.0), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(10.0, 0.0), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(10.0, 10.0), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(10.0, 10.0), MOUSE_BUTTON_LEFT, 0)

	check("double-click commit emitted annotation_ready", captured.env != null)
	if captured.env != null:
		var wps: Array = (captured.env as Dictionary).get("kind_payload", {}).get("waypoints", [])
		check("committed payload carries 3 waypoints", wps.size() == 3, str(wps))
		var anc: Dictionary = (captured.env as Dictionary).get("anchor", {})
		check("anchor sits at the first waypoint (0,0)",
				anc.get("id", {}).get("x", -1) == 0.0 and anc.get("id", {}).get("y", -1) == 0.0)
		check("committed kind is pcb_route_hint", str((captured.env as Dictionary).get("kind", "")) == "pcb_route_hint")

	# Double-click commit: two distinct clicks then a repeat of the last point.
	var tool2 = kind.author_ui()
	tool2.on_activate(host)
	var cap2 := {"env": null}
	tool2.annotation_ready.connect(func(e: Dictionary) -> void: cap2.env = e)
	tool2.on_pointer_down(Vector2(1.0, 1.0), MOUSE_BUTTON_LEFT, 0)
	tool2.on_pointer_down(Vector2(5.0, 1.0), MOUSE_BUTTON_LEFT, 0)
	tool2.on_pointer_down(Vector2(5.0, 1.0), MOUSE_BUTTON_LEFT, 0)   # double-click → commit
	check("double-click commit emitted with 2 waypoints",
			cap2.env != null and (cap2.env as Dictionary).get("kind_payload", {}).get("waypoints", []).size() == 2)

	# Escape cancels an in-progress path (no annotation_ready, one cancelled).
	var tool3 = kind.author_ui()
	tool3.on_activate(host)
	var cap3 := {"env": null, "cancels": 0}
	tool3.annotation_ready.connect(func(e: Dictionary) -> void: cap3.env = e)
	tool3.cancelled.connect(func() -> void: cap3.cancels += 1)
	tool3.on_pointer_down(Vector2(2.0, 2.0), MOUSE_BUTTON_LEFT, 0)
	tool3.on_pointer_down(Vector2(3.0, 3.0), MOUSE_BUTTON_LEFT, KEY_ESCAPE)
	check("Escape cancelled the path (no annotation, one cancelled)",
			cap3.env == null and cap3.cancels == 1)


# ── 16. capabilities reflect reality ──────────────────────────────────────────

func _test_capabilities() -> void:
	print("\n-- get_capabilities(): kinds/anchor_types/repair reflect reality --")
	var host = _Host.new()
	var caps: Dictionary = host.get_capabilities()
	var kinds: Array = caps.get("kinds", [])
	check("caps.kinds includes pcb_route_hint + core 2d_* generics",
			"pcb_route_hint" in kinds and "2d_arrow" in kinds and "2d_text" in kinds
			and "2d_region" in kinds and "2d_polyline" in kinds, str(kinds))
	var atypes: Array = caps.get("anchor_types", [])
	check("caps.anchor_types includes the new semantic pcb anchors",
			"pcb/pad" in atypes and "pcb/component" in atypes and "pcb/net" in atypes and "pcb/trace" in atypes,
			str(atypes))
	check("caps.lifecycle.repair is true (repair implemented)",
			bool((caps.get("lifecycle", {}) as Dictionary).get("repair", false)))

	# The registry actually carries the advertised core generic kinds.
	var reg = host.get_registry()
	check("registry carries 2d_arrow + 2d_polyline (generic authoring is real)",
			reg != null and reg.get_annotation_kind(&"2d_arrow") != null
			and reg.get_annotation_kind(&"2d_polyline") != null)

	# Author colors: substrate defaults are human-magenta / AI-cyan.
	check("substrate author colors: human=magenta, ai=cyan",
			AnnotationRenderContext.author_color("human") == Color(1.0, 0.5, 1.0)
			and AnnotationRenderContext.author_color("ai") == Color(0.0, 1.0, 1.0))


# ── 17. build_route_hint_envelope width_mm: absent by default (019fa73a191e) ──

## THE regression this item closes: build_route_hint_envelope's width_mm
## parameter used to be `float = 0.25`, so EVERY hint envelope — however
## authored — carried an explicit width_mm:0.25 that outranks the board's own
## design_rules.defaults.trace_width_mm downstream (agent_router/router.py's
## "caller_or_hint" step beats "board_rules"). A GDScript float cannot be
## null, so the fix is width_mm: Variant = null, with the key omitted from
## kind_payload entirely when null — not a 0.0 sentinel, which would render
## and validate identically to absent (pcb_route_hint_kind.gd :1114/:1214 both
## key off `width_mm > 0.0`) and so be undetectable here.
func _test_build_route_hint_envelope_width_mm_absent_by_default() -> void:
	print("\n-- build_route_hint_envelope: width_mm is ABSENT by default, not a stamped 0.25 --")
	var host = _Host.new()

	# The exact call shape every caller that never picks a width makes (the
	# waypoint author tool, add_route_hint_at, panel_tools's proposal writer,
	# and most gd test call sites): no width_mm argument at all.
	var env: Dictionary = host.build_route_hint_envelope(
			10.0, 10.0, "", "F.Cu", "waypoint", [[10.0, 10.0], [20.0, 10.0]], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	check("an unwidened hint gesture omits width_mm from the payload entirely",
			not kp.has("width_mm"), str(kp))

	# A genuinely caller-supplied width is still authored, verbatim, when passed
	# — the capability itself is unchanged, only the unconditional default is gone.
	var env_widened: Dictionary = host.build_route_hint_envelope(
			10.0, 10.0, "", "F.Cu", "waypoint", [[10.0, 10.0], [20.0, 10.0]], "human",
			"", 0.6)
	var kp_widened: Dictionary = env_widened.get("kind_payload", {})
	check("a caller-supplied width_mm is still carried through, verbatim",
			kp_widened.has("width_mm") and float(kp_widened["width_mm"]) == 0.6, str(kp_widened))

	# An explicit 0.0 is a real (if degenerate) caller value, not the same thing
	# as "no width was picked" — it must stay a present key, never collapsed to
	# absent. This also catches a truthy-check regression of the null guard: a
	# `if width_mm:` in place of `if width_mm != null:` would drop 0.0 here.
	var env_zero: Dictionary = host.build_route_hint_envelope(
			10.0, 10.0, "", "F.Cu", "waypoint", [[10.0, 10.0], [20.0, 10.0]], "human",
			"", 0.0)
	var kp_zero: Dictionary = env_zero.get("kind_payload", {})
	check("an explicit 0.0 width_mm is still a present key (not treated as null)",
			kp_zero.has("width_mm") and float(kp_zero["width_mm"]) == 0.0, str(kp_zero))


# ── 18. render-taxonomy gate (Epoch UX1 station 7, docket 019fcb32b5) ─────────
#
# Pure-function test of kind._render_mode_for / kind._has_live_candidate — no
# real PCBPanel/canvas mount needed (the gate reads its inputs entirely through
# a duck-typed host → panel → workspace walk). Fakes below implement ONLY the
# methods the gate's has_method guards look for, per hop, so each "degrade"
# assertion below is exercising a specific missing hop, not a stand-in for
# every method a real host/panel/workspace exposes.

## Minimal live-candidate stand-in: the ONE field _has_live_candidate reads.
class FakeCandidate extends RefCounted:
	var source_hint_ids: Array = []


## F6 (cold review): a candidate object that does NOT carry source_hint_ids at
## all — proves _has_live_candidate's `"source_hint_ids" in c` guard degrades
## instead of hard-erroring on the one hop that reads a member off `c`
## directly.
class FakeCandidateNoSourceHintIds extends RefCounted:
	pass


## Minimal routing-workspace stand-in: live_candidate_ids() + get_candidate(id),
## the two methods _has_live_candidate duck-types against.
class FakeWorkspace extends RefCounted:
	var _live_ids: Array = []
	var _candidates: Dictionary = {}

	func add_live_candidate(id: String, hint_ids: Array) -> void:
		var c := FakeCandidate.new()
		c.source_hint_ids = hint_ids
		_candidates[id] = c
		_live_ids.append(id)

	## A live_candidate_ids() entry that resolves to NOTHING (get_candidate
	## returns null) — proves the `if c == null: continue` degrade branch in
	## the walk, rather than just never exercising it.
	func add_live_id_without_candidate(id: String) -> void:
		_live_ids.append(id)

	## Registers an arbitrary object as a live candidate — used by the F6 test
	## to put a FakeCandidateNoSourceHintIds into the walk without going
	## through add_live_candidate's own source_hint_ids-bearing shape.
	func add_live_object(id: String, obj) -> void:
		_candidates[id] = obj
		_live_ids.append(id)

	func live_candidate_ids() -> Array:
		return _live_ids

	func get_candidate(id: String):
		return _candidates.get(id, null)


## Minimal panel stand-in: get_routing_workspace(), the method
## _has_live_candidate calls after host.get_panel().
class FakePanel extends RefCounted:
	var workspace = null
	func get_routing_workspace():
		return workspace


## Panel stand-in that deliberately OMITS get_routing_workspace() — proves the
## panel-hop degrade branch (host.get_panel() succeeds, but the panel itself
## predates the routing workspace).
class FakePanelNoWorkspaceMethod extends RefCounted:
	pass


## Full host stand-in: get_selected_annotation_id() + get_panel(), the two
## methods _render_mode_for/_has_live_candidate duck-type against.
class FakeGateHost extends RefCounted:
	var selected_id: String = ""
	var panel = null
	func get_selected_annotation_id() -> String:
		return selected_id
	func get_panel():
		return panel


## Host stand-in that deliberately OMITS get_panel() — proves the host-hop
## degrade branch (a host predating the routing-workspace seam entirely).
class FakeHostNoPanelMethod extends RefCounted:
	var selected_id: String = ""
	func get_selected_annotation_id() -> String:
		return selected_id


## Canvas-gate router stand-in (Epoch UX2 station 1): the annotation-router
## seam pcb_canvas._route_hint_masks_claim / _filter_masked_route_hints walk —
## registry + annotation list + screen↔doc transform + visibility — PLUS the
## host methods _render_mode_for duck-types against (get_panel), because the
## canvas passes the ROUTER itself as the render-mode host.
class FakeCanvasRouter extends RefCounted:
	var registry = null
	var annotations: Array = []
	var panel = null
	func get_registry():
		return registry
	func get_annotations() -> Array:
		return annotations
	func get_by_id(id: String) -> Dictionary:
		for a in annotations:
			if str(a.get("id", "")) == id:
				return a
		return {}
	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p
	func is_annotation_visible(_ann: Dictionary) -> bool:
		return true
	func get_panel():
		return panel


## Registry stand-in: returns the one real route-hint kind instance for the
## pcb_route_hint kind name, null for everything else.
class FakeKindRegistry extends RefCounted:
	var kind = null
	func get_annotation_kind(name: StringName):
		return kind if str(name) == "pcb_route_hint" else null


## F3 (cold review): a host with a MULTI-selection set —
## get_selected_annotation_ids() — plus get_panel(), so _is_selected's plural
## branch can be exercised independently of, and together with, the
## _has_live_candidate walk (a multi-selected hint with a live candidate must
## still render "full").
class FakeMultiSelectHost extends RefCounted:
	var selected_ids: PackedStringArray = PackedStringArray()
	var panel = null
	func get_selected_annotation_ids() -> PackedStringArray:
		return selected_ids
	func get_panel():
		return panel


func _test_render_mode_gate() -> void:
	print("\n-- kind._render_mode_for: render-taxonomy gate (station 7) --")
	var kind = _Kind.new()

	var hint_id := "hint_1"
	var ann := {
		"id": hint_id,
		"lifecycle": "open",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
				"waypoints": [[0.0, 0.0], [10.0, 0.0]]},
	}

	# Workspace unreachable (no host at all) → full (degrade — today's behavior).
	check("no host at all -> full (degrade)",
			kind._render_mode_for(ann, null) == "full")

	# Epoch UX2 station 1 (supersedes cold-review F4): an APPLIED hint renders
	# "none" EVERYWHERE, host or no host — the owner ruling ("no visible form
	# once applied") is an unconditional invariant, and the lifecycle read
	# needs no host, so even a headless overlay export agrees with the canvas
	# about what accepted means.
	var applied_no_host_ann := ann.duplicate(true)
	applied_no_host_ann["lifecycle"] = "applied"
	check("applied hint, no host at all -> none (UX2 station 1, unconditional)",
			kind._render_mode_for(applied_no_host_ann, null) == "none")

	var workspace := FakeWorkspace.new()
	var panel := FakePanel.new()
	panel.workspace = workspace
	var host := FakeGateHost.new()
	host.panel = panel

	# No candidate answers this hint → full (it is the route's sole representation).
	check("no live candidate -> full",
			kind._render_mode_for(ann, host) == "full")

	# A live candidate whose source_hint_ids names this hint → markers, no polyline.
	workspace.add_live_candidate("cand_1", [hint_id])
	check("hint with live candidate -> markers",
			kind._render_mode_for(ann, host) == "markers")

	# A live candidate that answers a DIFFERENT hint must not false-match.
	var other_ann := ann.duplicate(true)
	other_ann["id"] = "hint_2"
	check("live candidate answering a different hint -> full",
			kind._render_mode_for(other_ann, host) == "full")

	# Selected always wins back the full corridor, even with a live candidate.
	host.selected_id = hint_id
	check("selected hint -> full even with a live candidate",
			kind._render_mode_for(ann, host) == "full")
	host.selected_id = ""

	# Consumed (lifecycle "applied") -> none, independent of candidate state
	# (UX2 station 1: real copper owns the geometry; the hint is a record).
	var applied_ann := ann.duplicate(true)
	applied_ann["lifecycle"] = "applied"
	check("consumed (applied) hint -> none (UX2 station 1)",
			kind._render_mode_for(applied_ann, host) == "none")

	# Selection does NOT win over "applied" (UX2 station 1 flips the old rule):
	# canvas selection can't reach zero-ink annotations anyway (F1 gates mask
	# every claim), and a dock-driven selection of a consumed record must not
	# resurrect corridor ink on a canvas that shows real parts only.
	host.selected_id = hint_id
	check("selected + applied -> none (invisibility is unconditional)",
			kind._render_mode_for(applied_ann, host) == "none")
	host.selected_id = ""

	# The undo pin: commit-undo's lifecycle reconcile flips applied -> open,
	# and because _render_mode_for is a PURE read (no cached state), the very
	# same dictionary re-inks immediately — with a live candidate it returns
	# to "markers", and with none to "full". This is what makes Option A's
	# "invisible record, not deletion" restorable by construction.
	var undo_ann := applied_ann.duplicate(true)
	undo_ann["lifecycle"] = "open"
	check("applied -> open flip re-inks: live candidate -> markers (undo pin)",
			kind._render_mode_for(undo_ann, host) == "markers")
	var undo_ann_other := applied_ann.duplicate(true)
	undo_ann_other["lifecycle"] = "open"
	undo_ann_other["id"] = "hint_undo_solo"
	check("applied -> open flip re-inks: no candidate -> full (undo pin)",
			kind._render_mode_for(undo_ann_other, host) == "full")

	# Degrade, hop by hop: workspace-unreachable must resolve "full" no matter
	# WHICH hop is missing, not just a totally absent host.
	var host_no_panel_method := FakeHostNoPanelMethod.new()
	check("host lacking get_panel() -> full (degrade)",
			kind._render_mode_for(ann, host_no_panel_method) == "full")

	var host_null_panel := FakeGateHost.new()
	host_null_panel.panel = null
	check("get_panel() returns null -> full (degrade)",
			kind._render_mode_for(ann, host_null_panel) == "full")

	var panel_no_workspace_method := FakePanelNoWorkspaceMethod.new()
	var host_bad_panel := FakeGateHost.new()
	host_bad_panel.panel = panel_no_workspace_method
	check("panel lacking get_routing_workspace() -> full (degrade)",
			kind._render_mode_for(ann, host_bad_panel) == "full")

	var panel_null_workspace := FakePanel.new()
	panel_null_workspace.workspace = null
	var host_null_workspace := FakeGateHost.new()
	host_null_workspace.panel = panel_null_workspace
	check("get_routing_workspace() returns null -> full (degrade)",
			kind._render_mode_for(ann, host_null_workspace) == "full")

	# F3: multi-selection membership must win the same way primary selection
	# does — ANY member, not just the primary id. `panel` (still carrying the
	# hint_id -> cand_1 live candidate from above) is reused so this proves
	# selection beats "markers", not just beats the no-candidate default.
	var multi_host := FakeMultiSelectHost.new()
	multi_host.panel = panel
	multi_host.selected_ids = PackedStringArray(["some_other_id", hint_id])
	check("hint is a NON-primary member of a multi-selection -> full (F3)",
			kind._render_mode_for(ann, multi_host) == "full")

	multi_host.selected_ids = PackedStringArray(["some_other_id"])
	check("multi-selection NOT containing this hint, live candidate present -> markers",
			kind._render_mode_for(ann, multi_host) == "markers")

	multi_host.selected_ids = PackedStringArray()
	check("empty multi-selection, live candidate present -> markers",
			kind._render_mode_for(ann, multi_host) == "markers")

	# Degrade: a live_candidate_ids() entry that resolves to a null candidate
	# (get_candidate returns null) must be skipped, not error, and must not
	# false-match.
	var ws_null_cand := FakeWorkspace.new()
	ws_null_cand.add_live_id_without_candidate("ghost_cand")
	var panel_null_cand := FakePanel.new()
	panel_null_cand.workspace = ws_null_cand
	var host_null_cand := FakeGateHost.new()
	host_null_cand.panel = panel_null_cand
	check("live candidate id resolving to null candidate -> degrades to full, no error",
			kind._render_mode_for(ann, host_null_cand) == "full")

	# F6: a candidate object that doesn't carry source_hint_ids at all must
	# degrade (skip, no match) rather than hard-error reading the field.
	var ws_no_field := FakeWorkspace.new()
	ws_no_field.add_live_object("bad_cand", FakeCandidateNoSourceHintIds.new())
	var panel_no_field := FakePanel.new()
	panel_no_field.workspace = ws_no_field
	var host_no_field := FakeGateHost.new()
	host_no_field.panel = panel_no_field
	check("candidate object missing source_hint_ids -> no error, no match (F6)",
			kind._render_mode_for(ann, host_no_field) == "full")


## Epoch UX2 station 1 — the CANVAS gates for the "none" render mode, against
## the REAL pcb_canvas.gd + REAL kind (only the router seam is faked):
##   * _route_hint_masks_claim: a press ANYWHERE on a consumed (applied) hint
##     — corridor, or even the exact spot its marker used to occupy — masks
##     the claim (falls through to the board ladder), because "none" draws
##     zero ink and there is nothing on screen to click.
##   * _filter_masked_route_hints: no marquee, however large, can sweep a
##     consumed hint back into selection.
##   * Contrast rows pin that "markers" mode keeps its existing ink-reach
##     behavior — the "none" branches narrow nothing else.
func _test_canvas_none_mode_gates() -> void:
	print("\n-- pcb_canvas 'none'-mode gates (Epoch UX2 station 1) --")
	var kind = _Kind.new()
	# (HITL-6b: labels are retired outright — marker discs are the only hint
	# ink, so ink-miss geometry is exact by construction.)

	var registry := FakeKindRegistry.new()
	registry.kind = kind

	# Two hints sharing corridor shape (0,0)→(100,0): one consumed, one open
	# with a live candidate (markers mode).
	var applied_ann := {
		"id": "hint_applied", "kind": "pcb_route_hint", "lifecycle": "applied",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
				"waypoints": [[0.0, 0.0], [100.0, 0.0]]},
	}
	var markers_ann := {
		"id": "hint_markers", "kind": "pcb_route_hint", "lifecycle": "open",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
				"waypoints": [[0.0, 0.0], [100.0, 0.0]]},
	}

	var workspace := FakeWorkspace.new()
	workspace.add_live_candidate("cand_m", ["hint_markers"])
	var panel := FakePanel.new()
	panel.workspace = workspace

	var router := FakeCanvasRouter.new()
	router.registry = registry
	router.panel = panel

	var canvas = _Canvas.new()
	canvas.set_annotation_router(router)

	# ── Claim gate, consumed hint ──
	router.annotations = [applied_ann]
	# (canvas.zoom defaults to 4.0 px/mm: hit slack = 8px/4 = 2.0 doc units,
	# marker ink radius = _marker_geometry(4.0) = 4px/4 = 1.0mm — so y=1 hits
	# the corridor while x=50 sits far outside any marker/label ink.)
	check("press on consumed hint's corridor midpoint -> masked (falls through)",
			bool(canvas._route_hint_masks_claim(Vector2(50.0, 1.0))))
	check("press on consumed hint's former ANCHOR marker spot -> still masked",
			bool(canvas._route_hint_masks_claim(Vector2(0.0, 0.0))))
	check("press on consumed hint's former FAR marker spot -> still masked",
			bool(canvas._route_hint_masks_claim(Vector2(100.0, 0.0))))
	check("press far from the consumed hint entirely -> no mask (no ink hit at all)",
			not bool(canvas._route_hint_masks_claim(Vector2(50.0, 60.0))))

	# ── Claim gate, markers-mode contrast (existing behavior preserved) ──
	router.annotations = [markers_ann]
	check("markers mode: press on corridor midpoint (ink miss) -> masked",
			bool(canvas._route_hint_masks_claim(Vector2(50.0, 1.0))))
	check("markers mode: press ON the anchor marker -> NOT masked (visible ink)",
			not bool(canvas._route_hint_masks_claim(Vector2(0.0, 0.0))))

	# ── Marquee sweep ──
	router.annotations = [applied_ann, markers_ann]
	var everything := Rect2(-20.0, -20.0, 200.0, 100.0)
	var swept: PackedStringArray = canvas._filter_masked_route_hints(
			PackedStringArray(["hint_applied", "hint_markers"]), everything, router)
	check("marquee over EVERYTHING: consumed hint dropped from sweep",
			not ("hint_applied" in swept))
	check("marquee over EVERYTHING: markers-mode hint kept (rect reaches its markers)",
			"hint_markers" in swept)

	var corridor_only := Rect2(40.0, -6.0, 20.0, 12.0)
	var swept2: PackedStringArray = canvas._filter_masked_route_hints(
			PackedStringArray(["hint_applied", "hint_markers"]), corridor_only, router)
	check("marquee over corridor-only span: consumed hint dropped",
			not ("hint_applied" in swept2))
	check("marquee over corridor-only span: markers-mode hint ALSO dropped (no ink reached)",
			not ("hint_markers" in swept2))

	canvas.free()


## Epoch UX2 station 1, cold review F1/F2 — the consumed-hint selection veto on
## the REAL PcbAnnotationHost. An applied hint renders "none", so it must never
## be selectable: core selection visuals (transform-tool bounds/handles,
## overlay halo) and claims_point's single-selected gizmo branch all key off
## selection with no render-mode read — the veto at the host's setters is what
## keeps them honest. Plus the F2 fence: path_editing_locked on applied hints.
func _test_consumed_selection_veto() -> void:
	print("\n-- PcbAnnotationHost consumed-hint selection veto (UX2 station 1 F1/F2) --")
	var host = _Host.new()

	var wp_a: Array = [[0.0, 0.0], [10.0, 0.0]]
	var wp_b: Array = [[0.0, 5.0], [10.0, 5.0]]
	var id_a: String = str(host.add_route_hint_at(0.0, 0.0, "veto A", "F.Cu", "waypoint", wp_a, "human"))
	var id_b: String = str(host.add_route_hint_at(0.0, 5.0, "veto B", "F.Cu", "waypoint", wp_b, "human"))
	check("veto fixture: two hints stored", not id_a.is_empty() and not id_b.is_empty())

	# Flip-time deselect: A is selected at the moment it becomes applied.
	host.set_selected_annotation_id(id_a)
	check("open hint selectable (baseline)", host.get_selected_annotation_id() == id_a)
	var flip: Dictionary = host.update_annotation_lifecycle(id_a, "applied")
	check("lifecycle flip to applied accepted", bool(flip.get("ok", false)))
	check("flip-time deselect: selection cleared when the selected hint is consumed",
			host.get_selected_annotation_id() == "")

	# Setter veto, single id: refusal is a NO-OP — prior selection stands.
	host.set_selected_annotation_id(id_b)
	host.set_selected_annotation_id(id_a)
	check("selecting a consumed hint refused; prior selection stands",
			host.get_selected_annotation_id() == id_b)

	# Setter veto, set form: consumed ids are filtered, the rest pass through.
	host.set_selected_annotation_ids(PackedStringArray([id_a, id_b]), id_a)
	var ids: PackedStringArray = host.get_selected_annotation_ids()
	check("set form filters the consumed id out", not ids.has(id_a) and ids.has(id_b))
	check("consumed primary demoted to a surviving member",
			host.get_selected_annotation_id() == id_b)

	# Toggle routes through the set form — same filter.
	host.toggle_selected_annotation_id(id_a)
	check("toggle cannot add a consumed hint",
			not host.get_selected_annotation_ids().has(id_a))

	# F2 fence: consumed geometry is edit-locked (transform tool bend zones).
	var applied_ann: Dictionary = host.get_by_id(id_a)
	var kind = _Kind.new()
	check("path_editing_locked TRUE on a consumed hint",
			bool(kind.path_editing_locked(applied_ann)))

	# Undo pin: applied -> open makes the hint selectable and unlocked again,
	# purely from lifecycle state.
	host.update_annotation_lifecycle(id_a, "open")
	host.set_selected_annotation_id(id_a)
	check("reopened hint selectable again (undo pin)",
			host.get_selected_annotation_id() == id_a)
	check("path_editing_locked FALSE again on the reopened hint",
			not bool(kind.path_editing_locked(host.get_by_id(id_a))))


## HITL-6 (docket 019fdf2b5918) — the endpoint-diamond zoom curve. Owner spec:
## smaller base, NON-LINEAR by zoom (slightly larger zoomed out, shrinking
## zoomed in), and GONE at high zoom where the diamond hides connection-point
## geometry (the 0.54mm GND jog). One curve (_marker_geometry) feeds render()
## AND _visible_ink_hit, so faded ink stops claiming clicks (F1 contract).
func _test_marker_zoom_curve() -> void:
	print("\n-- endpoint-marker zoom curve (HITL-6) --")
	var kind = _Kind.new()

	# Doc-space radius strictly SHRINKS as zoom rises — the owner's curve;
	# the old maxf(1.25mm, 6px/zoom) grew on screen as you zoomed in.
	var d1: float = (kind._marker_geometry(1.0) as Vector2).x
	var d2: float = (kind._marker_geometry(2.0) as Vector2).x
	var d4: float = (kind._marker_geometry(4.0) as Vector2).x
	var d8: float = (kind._marker_geometry(8.0) as Vector2).x
	check("doc radius shrinks monotonically with zoom", d1 > d2 and d2 > d4 and d4 > d8)
	check("zoomed OUT is only SLIGHTLY larger in screen px (boost is bounded)",
		d1 * 1.0 <= d4 * 4.0 * 1.6)  # 5.5px vs 4px — under the +50% boost cap + margin
	check("full alpha through the working zoom range",
		(kind._marker_geometry(4.0) as Vector2).y == 1.0
		and (kind._marker_geometry(8.0) as Vector2).y == 1.0)

	# High-zoom band: fades, then disappears entirely.
	var mid_alpha: float = (kind._marker_geometry(12.0) as Vector2).y
	check("mid-band alpha strictly between 0 and 1", mid_alpha > 0.0 and mid_alpha < 1.0)
	check("at the band end the marker is GONE (radius 0, alpha 0)",
		kind._marker_geometry(16.0) == Vector2.ZERO
		and kind._marker_geometry(40.0) == Vector2.ZERO)

	# Ink parity: a press exactly ON the anchor of a markers-mode hint is
	# visible ink at working zoom and NOT ink at high zoom (markers are the
	# ONLY hint ink — labels retired at HITL-6b).
	var ann := {
		"id": "curve_probe", "lifecycle": "open",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
				"waypoints": [[0.0, 0.0], [10.0, 0.0]]},
	}
	check("anchor press IS visible ink at zoom 4",
		bool(kind._visible_ink_hit(ann, Vector2.ZERO, 0.5, 4.0)))
	check("anchor press is NOT ink at zoom 16 (faded markers claim nothing)",
		not bool(kind._visible_ink_hit(ann, Vector2.ZERO, 0.5, 16.0)))


## Supersession marker in the render gate (Codex 1047 fix round, verdict 1).
## Station 12 stamps kind_payload.waypoints_superseded_by_constraint_revision
## (int >= 1) on legacy waypoint hints whose routing authority moved to a
## task-level routing constraint — the host REFUSES edits to those waypoints.
## The ruling: the marker must participate in the render gate and OUTRANK the
## selected/full-corridor rule, else selection exposes handles for geometry the
## host refuses to write. Same pure-function fixtures as _test_render_mode_gate
## above; everything here is a kind_payload/host permutation of that group's
## `ann`, so the two groups A/B directly.
func _test_render_mode_superseded() -> void:
	print("\n-- kind._render_mode_for: supersession outranks selection (Codex 1047 v1) --")
	var kind = _Kind.new()

	var hint_id := "hint_s"
	var ann := {
		"id": hint_id,
		"lifecycle": "open",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu",
				"waypoints": [[0.0, 0.0], [10.0, 0.0]],
				"waypoints_superseded_by_constraint_revision": 1},
	}

	var workspace := FakeWorkspace.new()
	workspace.add_live_candidate("cand_s", [hint_id])
	var panel := FakePanel.new()
	panel.workspace = workspace
	var host := FakeGateHost.new()
	host.panel = panel

	# Unselected: the marker wins over BOTH the live-candidate rule and the
	# sole-representation default — never "markers", never "full".
	check("unselected superseded hint, live candidate present -> superseded (not markers)",
			kind._render_mode_for(ann, host) == "superseded")
	var host_no_candidate := FakeGateHost.new()
	check("unselected superseded hint, no candidate -> superseded (not full)",
			kind._render_mode_for(ann, host_no_candidate) == "superseded")

	# THE RULING: selection must NOT win back "full" — the host refuses edits
	# to these waypoints, so full-authority rendering (and the edit handles it
	# implies) would be a lie.
	host.selected_id = hint_id
	check("SELECTED superseded hint -> superseded, NEVER full (the verdict-1 rule)",
			kind._render_mode_for(ann, host) == "superseded")
	host.selected_id = ""

	# Lifecycle outranks the marker (UX2 station 1 flips the old rule): a
	# superseded hint whose candidate later COMMITTED is consumed — real
	# copper owns the geometry now, and the slash-corridor would be visible
	# ink for an accepted intent, exactly what the owner ruled out. The
	# superseded cue only matters while the hint is live history.
	var applied := ann.duplicate(true)
	applied["lifecycle"] = "applied"
	check("superseded + applied lifecycle -> none (applied outranks the marker)",
			kind._render_mode_for(applied, host) == "none")

	# Host-null: the marker is a pure payload read, so it applies headless
	# too — no pre-station-7 hint ever carried this (station-12) marker, so
	# there is no old headless behavior for step 0 to preserve here.
	check("superseded hint with NO host at all -> superseded (pure payload read)",
			kind._render_mode_for(ann, null) == "superseded")

	# A float revision (a payload that crossed a JSON boundary) still counts.
	var float_ann := ann.duplicate(true)
	(float_ann["kind_payload"] as Dictionary)["waypoints_superseded_by_constraint_revision"] = 2.0
	check("float marker (JSON round-trip) -> superseded",
			kind._render_mode_for(float_ann, host) == "superseded")

	# Contract edge: the stamp contract is int >= 1 — a 0 (or malformed) value
	# is NOT a marker, and the ordinary ladder resumes.
	var zero_ann := ann.duplicate(true)
	(zero_ann["kind_payload"] as Dictionary)["waypoints_superseded_by_constraint_revision"] = 0
	check("revision 0 is NOT a marker -> ordinary ladder (markers: live candidate)",
			kind._render_mode_for(zero_ann, host) == "markers")

	# ── The duck-typed transform-tool lock hook rides the same predicate ──────
	check("path_editing_locked TRUE on a stamped hint",
			bool(kind.path_editing_locked(ann)))
	check("path_editing_locked FALSE on revision 0",
			not bool(kind.path_editing_locked(zero_ann)))

	# ── Scenario (b), statelessness: stripping the marker (guided→detailed
	# conversion does exactly this) restores normal rendering AND unlock purely
	# from kind_payload state — nothing may be cached anywhere.
	var stripped := ann.duplicate(true)
	(stripped["kind_payload"] as Dictionary).erase("waypoints_superseded_by_constraint_revision")
	check("marker stripped: unselected + live candidate -> markers again",
			kind._render_mode_for(stripped, host) == "markers")
	host.selected_id = hint_id
	check("marker stripped: selected -> full again (regression guard)",
			kind._render_mode_for(stripped, host) == "full")
	host.selected_id = ""
	check("marker stripped: path_editing_locked FALSE again",
			not bool(kind.path_editing_locked(stripped)))


## Codex 1047 fix round, verdicts 3+4 — the host's structured refusal channel
## and the sanctioned release seam:
##   - last_update_refusal is {} on a fresh host, POPULATED (error
##     "waypoints_superseded", the hint id, the stamped revision, and a note
##     naming minerva_pcb_hint_convert_to_detailed) by a refused waypoints
##     edit, and CLEARED again by the next successful unrelated edit — it
##     always describes the MOST RECENT call or nothing.
##   - release_superseded_waypoints strips the marker + verdict-5 lock keys
##     WITHOUT the H2-1 re-injection putting them back, sets detail_level
##     "detailed", and waypoint edits are accepted again afterwards.
##   - UNDOABILITY DECISION PINNED: the release is ONE ordinary history step
##     (revision stack grows by one; undo_hint_revision takes it back,
##     restoring the marker via the snapshot — the documented annotation-side
##     asymmetry on release_superseded_waypoints' own doc).
func _test_superseded_refusal_and_release() -> void:
	print("\n-- host.last_update_refusal + release_superseded_waypoints (Codex 1047 v3+v4) --")
	var host = _Host.new()

	var wp: Array = [[0.0, 0.0], [4.0, 0.0]]
	var hint_id: String = str(host.add_route_hint_at(0.0, 0.0, "", "F.Cu", "waypoint", wp, "human"))
	check("fixture: hint added", not hint_id.is_empty())
	check("fixture: refusal channel starts empty", (host.last_update_refusal as Dictionary).is_empty())

	# Stamp the marker + verdict-5 lock keys through the ordinary update seam
	# (marker ADDITION is never refused — only waypoint CHANGES are), the same
	# write shape panel_tools._stamp_waypoints_superseded produces.
	var stamped: Dictionary = host.get_by_id(hint_id)
	var stamped_kp: Dictionary = (stamped.get("kind_payload", {}) as Dictionary).duplicate(true)
	stamped_kp["waypoints_superseded_by_constraint_revision"] = 3
	stamped_kp["_locked_fields"] = ["waypoints", "detail_level"]
	stamped_kp["_lock_reason"] = "superseded by task constraint revision 3"
	stamped["kind_payload"] = stamped_kp
	check("fixture: stamping update accepted", host.update_annotation(hint_id, stamped))
	check("fixture: stamping update leaves the refusal channel empty",
			(host.last_update_refusal as Dictionary).is_empty())

	# ── refused waypoints edit → structured refusal ───────────────────────────
	var edit: Dictionary = host.get_by_id(hint_id)
	var edit_kp: Dictionary = (edit.get("kind_payload", {}) as Dictionary).duplicate(true)
	edit_kp["waypoints"] = [[0.0, 0.0], [9.0, 9.0]]
	edit["kind_payload"] = edit_kp
	check("waypoints edit on the stamped hint returns false", not host.update_annotation(hint_id, edit))
	var refusal: Dictionary = host.last_update_refusal
	check("refusal channel is now POPULATED", not refusal.is_empty())
	check("refusal.error == waypoints_superseded",
			str(refusal.get("error", "")) == "waypoints_superseded")
	check("refusal names the hint", str(refusal.get("hint_id", "")) == hint_id)
	check("refusal carries the stamped constraint revision",
			int(refusal.get("constraint_revision", -1)) == 3)
	check("refusal note names minerva_pcb_hint_convert_to_detailed (the way forward)",
			str(refusal.get("note", "")).contains("minerva_pcb_hint_convert_to_detailed"))

	# ── successful unrelated edit → channel cleared ───────────────────────────
	var note_edit: Dictionary = host.get_by_id(hint_id)
	var note_kp: Dictionary = (note_edit.get("kind_payload", {}) as Dictionary).duplicate(true)
	note_kp["text"] = "still annotatable"
	note_edit["kind_payload"] = note_kp
	check("non-waypoints edit on the SAME hint succeeds", host.update_annotation(hint_id, note_edit))
	check("refusal channel cleared by the successful call",
			(host.last_update_refusal as Dictionary).is_empty())

	# ── lock keys are host-owned: an update dropping them gets them back ─────
	var strip: Dictionary = host.get_by_id(hint_id)
	var strip_kp: Dictionary = (strip.get("kind_payload", {}) as Dictionary).duplicate(true)
	strip_kp.erase("_locked_fields")
	strip_kp.erase("_lock_reason")
	strip["kind_payload"] = strip_kp
	check("lock-stripping update itself succeeds (marker kept, waypoints untouched)",
			host.update_annotation(hint_id, strip))
	var after_strip_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("_locked_fields re-injected (verdict 5 rides the marker's H2-1 seam)",
			after_strip_kp.get("_locked_fields", null) is Array)
	check("_lock_reason re-injected alongside",
			not str(after_strip_kp.get("_lock_reason", "")).is_empty())

	# ── the release: ONE sanctioned update, no re-injection ──────────────────
	var stack_before: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	var released: Dictionary = host.release_superseded_waypoints(hint_id)
	check("release_superseded_waypoints ok", bool(released.get("ok", false)))
	var released_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("marker GONE from storage — not re-injected",
			not released_kp.has("waypoints_superseded_by_constraint_revision"))
	check("_locked_fields gone", not released_kp.has("_locked_fields"))
	check("_lock_reason gone", not released_kp.has("_lock_reason"))
	check("detail_level is now detailed", str(released_kp.get("detail_level", "")) == "detailed")

	# ── waypoints are editable again ─────────────────────────────────────────
	var free_edit: Dictionary = host.get_by_id(hint_id)
	var free_kp: Dictionary = (free_edit.get("kind_payload", {}) as Dictionary).duplicate(true)
	free_kp["waypoints"] = [[0.0, 0.0], [12.0, 12.0]]
	free_edit["kind_payload"] = free_kp
	check("waypoints edit ACCEPTED after the release", host.update_annotation(hint_id, free_edit))
	check("refusal channel stays empty across the accepted edit",
			(host.last_update_refusal as Dictionary).is_empty())

	# ── undoability pinned: the release was ONE ordinary history step ────────
	var stack_after: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	check("release pushed exactly one revision (undoable, by decision)",
			stack_after == stack_before + 1 + 1)  # +release +the free edit above
	# Two undos: take back the free edit, then the release itself — the marker
	# returns via the snapshot (the documented annotation-side asymmetry).
	check("undo #1 (the free edit) ok", bool(host.undo_hint_revision(hint_id).get("ok", false)))
	check("undo #2 (the release) ok", bool(host.undo_hint_revision(hint_id).get("ok", false)))
	var undone_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("undoing the release restores the marker (annotation-side only, as documented)",
			undone_kp.has("waypoints_superseded_by_constraint_revision"))
	check("...and the guard re-arms: a fresh waypoints edit is refused again",
			not host.update_annotation(hint_id, _with_waypoints(host.get_by_id(hint_id), [[1.0, 1.0], [2.0, 2.0]])))
	check("...with the structured refusal populated again",
			str((host.last_update_refusal as Dictionary).get("error", "")) == "waypoints_superseded")

	# ── release refusals never crash ─────────────────────────────────────────
	check("release on an unknown id → not_found",
			str(host.release_superseded_waypoints("nope").get("error", "")) == "not_found")


## Codex 1047 fix round, verdict 6 — the host's SECOND sanctioned strip:
## reconcile_strip_superseded_marker, the annotation-side half of load-time
## two-store reconciliation (panel_tools.gd reconcile_superseded_waypoint_
## state calls it for the marker-without-constraint torn state). Pins the
## contract that distinguishes it from release_superseded_waypoints:
##   - marker + verdict-5 lock keys stripped WITHOUT the H2-1 re-injection
##     putting them back (same _bypass_superseded_release seam);
##   - detail_level PRESERVED as found — never forced to 'detailed' (the
##     deliberate reconciliation rule: both reachable torn shapes carry the
##     detail_level describing the pre-torn intent; see the method's doc);
##   - BOOKKEEPING, not an edit: no history step is created (revision_stack
##     unchanged), so undo never "takes back" a repair nobody performed;
##   - idempotent by contract: a second call is {ok:true, changed:false} and
##     writes nothing;
##   - the edit-refusal guard disarms afterwards (waypoint edits accepted).
func _test_reconcile_strip_bookkeeping() -> void:
	print("\n-- host.reconcile_strip_superseded_marker (Codex 1047 v6, load reconciliation) --")
	var host = _Host.new()

	var wp: Array = [[0.0, 0.0], [6.0, 0.0]]
	var hint_id: String = str(host.add_route_hint_at(0.0, 0.0, "", "F.Cu", "waypoint", wp, "human"))
	check("fixture: hint added", not hint_id.is_empty())
	var pre_detail: String = str((host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
		.get("detail_level", ""))
	check("fixture: detail_level is NOT 'detailed' (so preservation is observable)",
			pre_detail != "detailed")

	# Stamp marker + lock keys through the ordinary update seam (marker
	# ADDITION is never refused), same shape panel_tools._stamp_waypoints_
	# superseded writes — the same fixture technique the v3+v4 group uses.
	var stamped: Dictionary = host.get_by_id(hint_id)
	var stamped_kp: Dictionary = (stamped.get("kind_payload", {}) as Dictionary).duplicate(true)
	stamped_kp["waypoints_superseded_by_constraint_revision"] = 2
	stamped_kp["_locked_fields"] = ["waypoints", "detail_level"]
	stamped_kp["_lock_reason"] = "superseded by task constraint revision 2"
	stamped["kind_payload"] = stamped_kp
	check("fixture: stamping update accepted", host.update_annotation(hint_id, stamped))
	check("fixture: guard armed (waypoints edit refused)",
			not host.update_annotation(hint_id, _with_waypoints(host.get_by_id(hint_id), [[9.0, 9.0], [1.0, 1.0]])))

	# ── the bookkeeping strip ────────────────────────────────────────────────
	var stack_before: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	var res: Dictionary = host.reconcile_strip_superseded_marker(hint_id)
	check("strip ok", bool(res.get("ok", false)))
	check("strip reports changed:true (it had a marker to remove)", bool(res.get("changed", false)))
	var after_kp: Dictionary = (host.get_by_id(hint_id).get("kind_payload", {}) as Dictionary)
	check("marker GONE — not re-injected (sanctioned bypass, same as the release)",
			not after_kp.has("waypoints_superseded_by_constraint_revision"))
	check("_locked_fields gone", not after_kp.has("_locked_fields"))
	check("_lock_reason gone", not after_kp.has("_lock_reason"))
	check("detail_level PRESERVED as found — the reconciliation rule, NOT forced 'detailed'",
			str(after_kp.get("detail_level", "")) == pre_detail)
	check("waypoints untouched by the strip",
			(after_kp.get("waypoints", []) as Array).size() == 2)

	# ── bookkeeping: no history step ─────────────────────────────────────────
	var stack_after: int = (host.get_by_id(hint_id).get("revision_stack", []) as Array).size()
	check("revision_stack UNCHANGED — the repair is not an undoable edit",
			stack_after == stack_before)

	# ── guard disarmed: waypoints editable again ─────────────────────────────
	check("waypoints edit ACCEPTED after the strip",
			host.update_annotation(hint_id, _with_waypoints(host.get_by_id(hint_id), [[0.0, 0.0], [7.0, 7.0]])))

	# ── idempotence: second call is a clean no-op ────────────────────────────
	var payload_snapshot: String = JSON.stringify(host.get_by_id(hint_id).get("kind_payload", {}))
	var res2: Dictionary = host.reconcile_strip_superseded_marker(hint_id)
	check("second strip ok", bool(res2.get("ok", false)))
	check("second strip reports changed:false (nothing left to strip)",
			not bool(res2.get("changed", true)))
	check("second strip wrote nothing (payload byte-identical)",
			JSON.stringify(host.get_by_id(hint_id).get("kind_payload", {})) == payload_snapshot)

	# ── refusals never crash ─────────────────────────────────────────────────
	check("strip on an unknown id → not_found",
			str(host.reconcile_strip_superseded_marker("nope").get("error", "")) == "not_found")


## Small fixture helper for the group above: `ann` with its
## kind_payload.waypoints replaced (deep-copied, never mutating the input).
func _with_waypoints(ann: Dictionary, wp: Array) -> Dictionary:
	var out := ann.duplicate(true)
	var kp: Dictionary = (out.get("kind_payload", {}) as Dictionary).duplicate(true)
	kp["waypoints"] = wp
	out["kind_payload"] = kp
	return out


# ──────────────────────────────────────────────────────────────────────────────

func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
