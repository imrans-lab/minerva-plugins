extends SceneTree
## A POUR'S COMPILED FILL, FROM THE COMPILER TO THE MODEL THAT ANSWERS
## "WHAT IS ALREADY JOINED".
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_zone_fill_transport.gd
##
## The consumer half — a pour conducts as its fill, one region per conductor,
## no fill means no connection — is pinned by test_pcb_ratsnest.gd section 7
## against hand-written fill dictionaries. This suite covers what carries a
## REAL compiler answer to that consumer: the pcb.zone_fill channel, and
## PCBData's adopt/clear/strip rules for the derived key it lands on.
##
## ── WHAT EACH SECTION COVERS ─────────────────────────────────────────────────
##
##   1. THE TRANSPORT PRESERVES THE COMPILER'S REGIONS. Two independently
##      derived answers about one board must agree: the regions the compiler
##      emitted, and the regions the model holds after adopting them. Then a
##      THIRD derivation — recompiling the board the model now projects — must
##      agree with what the model holds, which is what a transport that
##      reshapes, truncates, reorders or loses coordinates fails.
##
##   2. THE SEVERED PLANE, END TO END. One authored pour outline, two lands
##      under it, and one foreign-net trace that either crosses the pour or is
##      absent. The compiler answers 1 region or 2; the ratsnest answers joined
##      or still owed. Nothing between the two is written down here.
##
##   3. THE SAFE FALLBACK IS NOT A HOLLOW NEGATIVE. Every "still owed" below is
##      stated on a board whose pour OUTLINE, adopted as if it were a fill,
##      demonstrably joins the two lands — asserted, not assumed. So an
##      implementation that fell back to the boundary would report 0 where
##      these assert 1, and each negative fails against exactly the thing it
##      exists to catch.
##
##   4. THE MODEL NEVER CARRIES THE FILL OUT. It is stripped from the board
##      projection (and so from the history snapshot and every worker request
##      built on it), and it is stripped on the way in, so adopt_zone_fill is
##      the only writer and a fill riding in a document cannot be trusted.
##
##   5. A LIVE DRAG DROPS IT. The move gesture writes positions straight onto
##      entities without the model's change signal, so the drop is stated in
##      the gesture itself; the ratsnest, which re-solves every frame, must go
##      back to owing the join.

const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const Ratsnest := preload("res://../../minerva-plugins/pcb/ui/model/pcb_ratsnest.gd")
const PcbCanvasScript := preload("res://../../minerva-plugins/pcb/ui/pcb_canvas.gd")

const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"

## The fixture's minted ids. A v2 board requires them, and the zone's is what
## the channel matches an adopted fill against.
const BOARD_ID := "board:00000000000000000000000000000000"
const ZONE_ID := "zone:11111111111111111111111111111111"
const TRACE_ID := "trace:22222222222222222222222222222222"

## The seed-library footprint the fixture's parts use, and its pad geometry.
## The compiler REFUSES a board whose declared pins disagree with the locked
## footprint's pads, so these are the footprint's own numbers.
const FOOTPRINT := "R_0805"
const PAD_OFFSET_MM := 0.95
const PAD_W_MM := 1.0
const PAD_H_MM := 1.45

## The pour outline, and the parts under it. P1.1 and P2.1 are the pour's own
## net; the sever cut lands between them.
const POUR_MIN := Vector2(5.0, 7.0)
const POUR_MAX := Vector2(25.0, 13.0)
const P1_AT := Vector2(10.0, 10.0)
const P2_AT := Vector2(20.0, 10.0)
const SEVER_X := 15.0

var _pass := 0
var _fail := 0
var _used_real_worker := false
var _worker_fell_back := false


func _init() -> void:
	print("=== Zone fill: compiler to connectivity ===\n")
	_run_transport_preserves_regions()
	_run_severed_plane_end_to_end()
	_run_safe_fallback()
	_run_fill_never_leaves_the_model()
	_run_live_drag_drops_it()
	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [
		_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


# ── the fixture ───────────────────────────────────────────────────────────────

func _rect(a: Vector2, b: Vector2) -> Array:
	return [{"x_mm": a.x, "y_mm": a.y}, {"x_mm": b.x, "y_mm": a.y},
		{"x_mm": b.x, "y_mm": b.y}, {"x_mm": a.x, "y_mm": b.y}]


func _part(ref: String, at: Vector2) -> Dictionary:
	return {"ref": ref, "footprint": FOOTPRINT, "x_mm": at.x, "y_mm": at.y,
		"rotation_deg": 0.0, "layer": "top", "pins": [
			{"number": "1", "x_mm": -PAD_OFFSET_MM, "y_mm": 0.0,
				"pad_width_mm": PAD_W_MM, "pad_height_mm": PAD_H_MM},
			{"number": "2", "x_mm": PAD_OFFSET_MM, "y_mm": 0.0,
				"pad_width_mm": PAD_W_MM, "pad_height_mm": PAD_H_MM}]}


## The board. `severed` adds ONE foreign-net trace crossing the pour from edge
## to edge; nothing else differs, so every difference in the answers below is
## attributable to that trace and to the fill the compiler makes of it.
func _board_dict(severed: bool) -> Dictionary:
	var traces: Array = []
	if severed:
		traces.append({"id": TRACE_ID, "net": "SIG", "layer": "top", "width_mm": 0.3,
			"points": [{"x_mm": SEVER_X, "y_mm": POUR_MIN.y - 2.0},
				{"x_mm": SEVER_X, "y_mm": POUR_MAX.y + 2.0}]})
	return {
		"version": 2, "id": BOARD_ID, "name": "pour-transport",
		"width_mm": 30.0, "height_mm": 20.0,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
			"via_diameter_mm": 0.8, "via_drill_mm": 0.4},
		"components": [_part("P1", P1_AT), _part("P2", P2_AT)],
		"nets": [{"name": "PR", "pins": ["P1.1", "P2.1"]},
			{"name": "SIG", "pins": ["P1.2", "P2.2"]}],
		"traces": traces,
		"vias": [],
		"zones": [{"id": ZONE_ID, "kind": "copper_pour", "net": "PR", "layer": "top",
			"clearance_mm": 0.2, "outline": _rect(POUR_MIN, POUR_MAX)}],
	}


func _loaded(severed: bool):
	var data = PCBData.new()
	data.from_board_dict(_board_dict(severed))
	return data


## Remaining joins the ratsnest still owes on the pour's net.
func _owed(data) -> int:
	for row in Ratsnest.compute(data).get("nets", []):
		if str((row as Dictionary)["net"]) == "PR":
			return int((row as Dictionary)["remaining"])
	return 0


## A canonical text rendering of one zone's fill: region count, then every
## point of every region in order at full precision. Two answers about the same
## copper produce the same string; a lost region, a dropped or reordered point,
## and a quantized coordinate each produce a different one.
func _fill_signature(fill) -> String:
	if not (fill is Array):
		return "<no fill>"
	var out := PackedStringArray()
	out.append("regions=%d" % (fill as Array).size())
	for region in (fill as Array):
		if not (region is Array):
			out.append("  <not a region>")
			continue
		out.append("  points=%d" % (region as Array).size())
		for p in (region as Array):
			if not (p is Dictionary):
				out.append("    <not a point>")
				continue
			out.append("    %.10f,%.10f" % [
				float((p as Dictionary).get("x_mm", NAN)),
				float((p as Dictionary).get("y_mm", NAN))])
	return "\n".join(out)


## The zone-fill reply's entry for the fixture's pour, or {} when absent.
func _pour_entry(reply: Dictionary) -> Dictionary:
	if not bool(reply.get("ok", false)):
		return {}
	var result = reply.get("result")
	if not (result is Dictionary):
		return {}
	for entry in (result as Dictionary).get("zones", []):
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == ZONE_ID:
			return entry
	return {}


func _held_fill(data):
	for zone in data.zones:
		if str((zone as Dictionary).get("id", "")) == ZONE_ID:
			return (zone as Dictionary).get("fill")
	return null


# ── the real worker ───────────────────────────────────────────────────────────

## Prints WHY a real-worker invocation fell back, loudly, before the canned
## result masks it — this suite is designated real-worker in EXPECTED_SUITES,
## so the gd runner FAILS the run on real_worker_used=false.
func _surface_worker_failure(exit_code: int, output: Array, parsed: Variant) -> void:
	var detail := "no output from wrapper"
	if parsed is Dictionary:
		detail = JSON.stringify((parsed as Dictionary).get("error", parsed))
	elif not output.is_empty():
		detail = str(output[0]).left(500)
	printerr("[test_zone_fill_transport] REAL-WORKER INVOCATION FAILED (exit=%d): %s" % [
		exit_code, detail])
	printerr("[test_zone_fill_transport] canned fallback engaged — real_worker_used will report false and the gd runner fails this suite; fix the invocation, do not trust the green assertions")


## Compile `board` through the REAL plugin binary and return the pcb.zone_fill
## envelope, {ok, result:{zones:[…]}}.
func _worker_zone_fill(board: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		# Every fallback path latches: a later successful call must not flip the
		# run's verdict back to true.
		_worker_fell_back = true
		_used_real_worker = false
		push_warning("[test_zone_fill_transport] real pcb-plugin binary not built — canned fill fallback")
		return _canned_zone_fill(board)
	var req_uri := "user://zone_fill_transport_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		_worker_fell_back = true
		_used_real_worker = false
		printerr("[test_zone_fill_transport] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return _canned_zone_fill(board)
	f.store_string(JSON.stringify({"board": board}))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)
	var output: Array = []
	var exit_code := OS.execute("python3",
		[wrapper_path, binary_path, req_abs, "pcb.zone_fill"], output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code == 0 and parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
		if not _worker_fell_back:
			_used_real_worker = true
		return parsed
	_worker_fell_back = true
	_used_real_worker = false
	_surface_worker_failure(exit_code, output, parsed)
	return _canned_zone_fill(board)


## Contract-allowed fallback (subprocess-boundary fake), reached ONLY when the
## real binary is missing or refuses. It keeps the suite RUNNABLE — the same
## number of assertions execute either way — and can never satisfy the
## real-worker gate, which is what stops it being mistaken for a pass. It is a
## crude stand-in for the filler: the pour rectangle, cut in two at the sever
## line when a trace crosses there.
func _canned_zone_fill(board: Dictionary) -> Dictionary:
	var severed := not (board.get("traces", []) as Array).is_empty()
	var regions: Array = []
	if severed:
		regions.append(_rect(POUR_MIN, Vector2(SEVER_X - 0.35, POUR_MAX.y)))
		regions.append(_rect(Vector2(SEVER_X + 0.35, POUR_MIN.y), POUR_MAX))
	else:
		regions.append(_rect(POUR_MIN, POUR_MAX))
	return {"ok": true, "result": {"zones": [{"id": ZONE_ID, "fill": regions}]}}


# ── 1. the transport preserves the compiler's regions ─────────────────────────

func _run_transport_preserves_regions() -> void:
	print("-- 1. the compiler's regions survive the transport --")
	var data = _loaded(true)
	var reply := _worker_zone_fill(data.to_board_dict())
	var emitted := _pour_entry(reply)
	check("the compiler answered for the pour", not emitted.is_empty())
	var emitted_fill = emitted.get("fill")

	# The agreement checks below are worthless over a trivial answer, so state
	# what the answer has to be before comparing anything to it: this board's
	# pour is severed, so more than one region, each a real polygon.
	var region_count := (emitted_fill as Array).size() if emitted_fill is Array else 0
	check("…with more than one region, so agreement is a real claim (got %d)" % region_count,
		region_count > 1)
	var smallest := 0
	if emitted_fill is Array and region_count > 0:
		smallest = 0x7FFFFFFF
		for region in (emitted_fill as Array):
			smallest = mini(smallest, (region as Array).size() if region is Array else 0)
	check("…every region a polygon of at least 3 points (smallest %d)" % smallest,
		smallest >= 3)

	check_eq("exactly one zone takes a fill", data.adopt_zone_fill(
		_dict_or_empty(reply.get("result")).get("zones", [])), 1)

	# ORACLE: two derivations of one thing. The compiler emitted the regions;
	# the model holds them after the channel, the JSON hop and adoption. A
	# transport that reshapes, truncates, reorders or rounds disagrees here.
	check("what the model holds is what the compiler emitted",
		_fill_signature(_held_fill(data)) == _fill_signature(emitted_fill))

	# ORACLE, independently: recompile the board the MODEL projects. The
	# compiler is run again, from the model's own state rather than from the
	# fixture, and must produce the fill the model is holding. This is what
	# fails if the projection lost part of the board, or if the fill were
	# leaking back into the projection and changing what compiles.
	var recompiled := _pour_entry(_worker_zone_fill(data.to_board_dict()))
	check("recompiling the board the model projects reproduces the fill it holds",
		_fill_signature(recompiled.get("fill")) == _fill_signature(_held_fill(data)))


func _dict_or_empty(v) -> Dictionary:
	return v if v is Dictionary else {}


# ── 2. the severed plane, end to end ──────────────────────────────────────────

func _run_severed_plane_end_to_end() -> void:
	print("-- 2. the severed plane, compiler to ratsnest --")
	# The two boards' pours are the SAME authored outline. Stated, so "the
	# fill decided it" is a measurement rather than a claim about the fixture.
	check("both boards author the identical pour outline",
		JSON.stringify(_board_dict(false)["zones"]) == JSON.stringify(_board_dict(true)["zones"]))

	var whole = _loaded(false)
	var whole_fill := _pour_entry(_worker_zone_fill(whole.to_board_dict()))
	check_eq("an unsevered outline compiles to ONE region",
		(whole_fill.get("fill") as Array).size() if whole_fill.get("fill") is Array else -1, 1)
	whole.adopt_zone_fill([whole_fill])
	check_eq("…and the plane serves the join: nothing owed", _owed(whole), 0)

	var severed = _loaded(true)
	var severed_fill := _pour_entry(_worker_zone_fill(severed.to_board_dict()))
	check_eq("one foreign trace across it compiles to TWO regions",
		(severed_fill.get("fill") as Array).size() if severed_fill.get("fill") is Array else -1, 2)
	severed.adopt_zone_fill([severed_fill])
	check_eq("…and the join is still owed", _owed(severed), 1)


# ── 3. the safe fallback is not a hollow negative ─────────────────────────────

func _run_safe_fallback() -> void:
	print("-- 3. no usable fill means no connection --")
	var outline_as_fill: Array = [{"id": ZONE_ID, "fill": [_rect(POUR_MIN, POUR_MAX)]}]

	# THE CONTROL, and the whole reason the negatives below mean anything: the
	# severed board's authored OUTLINE, adopted as if it were the copper, joins
	# the two lands. Every "still owed" that follows is therefore a statement
	# about the fill, and would read 0 under an implementation that fell back
	# to the boundary.
	var control = _loaded(true)
	control.adopt_zone_fill(outline_as_fill)
	check_eq("the pour OUTLINE, adopted as copper, joins the two lands", _owed(control), 0)

	check_eq("a pour with no fill adopted at all owes the join", _owed(_loaded(true)), 1)

	var unknown_zone = _loaded(true)
	check_eq("a reply naming a zone this board does not have adopts nothing",
		unknown_zone.adopt_zone_fill(
			[{"id": "zone:deadbeefdeadbeefdeadbeefdeadbeef",
				"fill": [_rect(POUR_MIN, POUR_MAX)]}]), 0)
	check_eq("…and the join is still owed", _owed(unknown_zone), 1)

	var idless = _loaded(true)
	check_eq("a reply entry with no id adopts nothing",
		idless.adopt_zone_fill([{"fill": [_rect(POUR_MIN, POUR_MAX)]}]), 0)
	check_eq("…and the join is still owed", _owed(idless), 1)

	var unshaped = _loaded(true)
	check_eq("a reply whose fill is not an Array adopts nothing",
		unshaped.adopt_zone_fill([{"id": ZONE_ID, "fill": "solid"}]), 0)
	check_eq("…and the join is still owed", _owed(unshaped), 1)

	var not_a_list = _loaded(true)
	check_eq("a reply that is not a list of entries adopts nothing",
		not_a_list.adopt_zone_fill({"zones": outline_as_fill}), 0)
	check_eq("…and the join is still owed", _owed(not_a_list), 1)

	# ADOPTION REPLACES. A later answer that says nothing about this pour is
	# the answer "no fill was computed for it", not "keep the last one".
	var superseded = _loaded(true)
	superseded.adopt_zone_fill(outline_as_fill)
	check_eq("a later reply that omits the pour drops the fill it had",
		superseded.adopt_zone_fill([]), 0)
	check_eq("…and the join is owed again", _owed(superseded), 1)

	var cleared = _loaded(true)
	cleared.adopt_zone_fill(outline_as_fill)
	cleared.clear_zone_fill()
	check_eq("clearing the fill puts the join back", _owed(cleared), 1)


# ── 4. the fill never leaves the model ────────────────────────────────────────

func _run_fill_never_leaves_the_model() -> void:
	print("-- 4. derived state stays derived --")
	var data = _loaded(true)
	data.adopt_zone_fill([{"id": ZONE_ID, "fill": [_rect(POUR_MIN, POUR_MAX)]}])
	check("the model is holding a fill to begin with", _held_fill(data) is Array)

	var projected: Dictionary = data.to_board_dict()
	var carried := false
	for zone in (projected.get("zones", []) as Array):
		if zone is Dictionary and (zone as Dictionary).has("fill"):
			carried = true
	check("the board projection carries no fill on any zone", not carried)

	# The board the model projects is what the history snapshot stores and what
	# every worker request is built from, so the strip above covers all three.
	# The way IN is stripped too, which is what makes adoption the only writer:
	# a fill riding in a loaded document describes whatever board it was
	# computed from, and this session cannot know that was this one.
	var seeded := _board_dict(true)
	((seeded["zones"] as Array)[0] as Dictionary)["fill"] = [_rect(POUR_MIN, POUR_MAX)]
	var reloaded = PCBData.new()
	reloaded.from_board_dict(seeded)
	check("a fill authored into a loaded board is not held", _held_fill(reloaded) == null)
	check_eq("…and the join it would have served is still owed", _owed(reloaded), 1)


# ── 5. a live drag drops it ───────────────────────────────────────────────────

func _run_live_drag_drops_it() -> void:
	print("-- 5. a live drag drops the fill --")
	var data = _loaded(false)
	data.adopt_zone_fill([{"id": ZONE_ID, "fill": [_rect(POUR_MIN, POUR_MAX)]}])
	check_eq("the plane serves the join before the drag", _owed(data), 0)

	var canvas = PcbCanvasScript.new()
	canvas.data = data
	canvas._add_to_selection(canvas.KIND_COMPONENT, "P1")
	canvas._capture_drag_origins()
	canvas._apply_drag_delta(Vector2(0.1, 0.0))
	check("the drag dropped the fill", _held_fill(data) == null)
	check_eq("…so the join is owed while the copper is moving", _owed(data), 1)
	canvas.free()
