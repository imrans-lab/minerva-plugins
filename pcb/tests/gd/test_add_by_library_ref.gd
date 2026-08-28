extends SceneTree
## ADDING A PART BY LIBRARY FOOTPRINT REF, AGAINST THE REAL WORKER.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_add_by_library_ref.gd
##
## THE DEFECT. minerva_pcb_add_component used to take only the generic enums, which build ESTIMATED geometry with no library behind them.
## The hermetic worker refuses such a part by name — and that refusal takes the
## WHOLE board's geometric DRC and every pour fill down with it, silently: the
## panel showed nothing, the add reply said nothing, and the first news was an
## "indeterminate" verdict three calls later with 44 innocent parts in it. There
## was also no way to do it right: the library HAD the footprint and nothing on
## the panel or over MCP could add a part by its ref.
##
## ── WHAT EACH SECTION COVERS ─────────────────────────────────────────────────
##
##   1. A LIBRARY REF LANDS REAL GEOMETRY. The part added through the verb
##      carries the pads the WORKER says that footprint has — the two answers
##      come from the same library through two different calls, so a transport
##      that reshaped, truncated or invented geometry disagrees here. Silk and
##      courtyard arrive with it, which is what makes the part fabricable
##      rather than merely pad-bearing.
##
##   2. THE BOARD STILL CHECKS. The real worker's geometric DRC over the board
##      with the added part is DETERMINATE and clean. This is the whole point:
##      a part added this way costs the board nothing.
##
##   3. A SKETCH PART IS NAMED, AT ADD TIME, AND THE BOARD STOPS CHECKING. The
##      same board, the same check, one HEADER added: the verdict goes
##      indeterminate. That is CORRECT and stays (fail-closed is the hermetic
##      rule), so what this section pins is that nobody has to guess why — the
##      add reply names it, the panel's own census names it, and the worker's
##      refusal names the component. Section 2 is the control that makes this
##      section's failure attributable to the sketch part and nothing else.
##
##   4. AN UNRESOLVABLE REF ADDS NOTHING. A ref the library does not have is
##      refused by name, and the board is byte-identical afterwards — the
##      alternative is putting back exactly the placeholder this path retires.
##
## FAILS AGAINST OLD: section 1's add is refused outright ("Invalid footprint
## type"), so every assertion in 1 and 2 fails; section 3's reply carries no
## `geometry` block.

const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PCBData := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const PcbLibraryPart := preload("res://../../minerva-plugins/pcb/ui/model/pcb_library_part.gd")

const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"

## The fixture's minted ids — a v2 board requires them.
const BOARD_ID := "board:00000000000000000000000000000000"

## The part the whole suite is about: a 2-pin 2.54 mm header, in the shipped
## seed library, through-hole, whose pads are 1.8 mm on a 1.0 mm drill.
const HEADER_REF := "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical"
## A ref of the right SHAPE that no layer can supply.
const ABSENT_REF := "NoSuchLibrary_9x9mm:NoSuchPart_Vertical"

## Where the two headers go. Far apart and well inside the outline, so a clean
## geometric verdict in section 2 is about the parts resolving and not about
## some clearance the fixture happened to break.
const J1_AT := Vector2(10.0, 10.0)
const J2_AT := Vector2(30.0, 10.0)
## The sketch part, placed clear of both.
const SKETCH_AT := Vector2(20.0, 25.0)

var _pass := 0
var _fail := 0
var _used_real_worker := false
var _worker_fell_back := false


func _init() -> void:
	print("=== Add by library ref: real geometry, and the sketch part that is named ===\n")
	await _run_library_ref_lands_real_geometry()
	await _run_the_board_still_checks()
	await _run_a_sketch_part_is_named()
	await _run_an_unresolvable_ref_adds_nothing()
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


# ── the real worker ───────────────────────────────────────────────────────────

## Prints WHY a real-worker invocation fell back, loudly, before the canned
## result masks it — this suite is designated real-worker in EXPECTED_SUITES,
## so the gd runner FAILS the run on real_worker_used=false.
func _surface_worker_failure(tool_name: String, exit_code: int, output: Array, parsed: Variant) -> void:
	var detail := "no output from wrapper"
	if parsed is Dictionary:
		detail = JSON.stringify((parsed as Dictionary).get("error", parsed))
	elif not output.is_empty():
		detail = str(output[0]).left(500)
	printerr("[test_add_by_library_ref] REAL-WORKER %s FAILED (exit=%d): %s" % [
		tool_name, exit_code, detail])
	printerr("[test_add_by_library_ref] canned fallback engaged — real_worker_used will report false and the gd runner fails this suite; fix the invocation, do not trust the green assertions")


## Drive ONE registered channel against the REAL plugin binary + REAL Python
## worker, and return the worker's own envelope {ok, result|error}.
##
## `fallback` is the contract-allowed subprocess-boundary stand-in used when the
## binary is missing or refuses: it keeps the suite RUNNABLE (the same
## assertions execute either way) and can never satisfy the real-worker gate.
func _worker_call(tool_name: String, request: Dictionary, fallback: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(binary_path) or not FileAccess.file_exists(wrapper_path):
		# Every fallback path latches: a later successful call must not flip
		# the run's verdict back to true.
		_worker_fell_back = true
		_used_real_worker = false
		push_warning("[test_add_by_library_ref] real pcb-plugin binary not built — canned fallback")
		return fallback
	var req_uri := "user://add_by_library_ref_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		_worker_fell_back = true
		_used_real_worker = false
		printerr("[test_add_by_library_ref] REAL-WORKER INVOCATION FAILED: cannot write %s" % req_uri)
		return fallback
	f.store_string(JSON.stringify(request))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)
	var output: Array = []
	var exit_code := OS.execute("python3",
		[wrapper_path, binary_path, req_abs, tool_name], output, true)
	DirAccess.remove_absolute(req_abs)
	var parsed: Variant = null
	if not output.is_empty():
		parsed = JSON.parse_string(str(output[0]))
	if exit_code == 0 and parsed is Dictionary and (parsed as Dictionary).has("ok"):
		if not _worker_fell_back:
			_used_real_worker = true
		return parsed
	_worker_fell_back = true
	_used_real_worker = false
	_surface_worker_failure(tool_name, exit_code, output, parsed)
	return fallback


## The canned footprint geometry: the header's real numbers, hand-copied from
## the seed .kicad_mod, so the suite still exercises the whole add path on a
## machine with no binary. It has NO graphics, deliberately — the silk
## assertion in section 1 therefore cannot pass on the fallback either.
func _canned_footprint_geometry() -> Dictionary:
	return {"ok": true, "result": {
		"ref": HEADER_REF, "layer": "canned", "sha256": "",
		"pad_count": 2, "has_pad_geometry": true,
		"bounding_box": {"width": 3.6, "height": 6.14, "center_x": 0.0, "center_y": 1.27},
		"graphics": [], "refdes_graphics": [],
		"pads": [
			{"number": "1", "type": "thru_hole", "shape": "rect",
				"position": {"x": 0.0, "y": 0.0},
				"size": {"width": 1.8, "height": 1.8},
				"drill": {"x": 1.0, "y": 1.0}, "layers": ["*.Cu", "*.Mask"]},
			{"number": "2", "type": "thru_hole", "shape": "oval",
				"position": {"x": 0.0, "y": 2.54},
				"size": {"width": 1.8, "height": 1.8},
				"drill": {"x": 1.0, "y": 1.0}, "layers": ["*.Cu", "*.Mask"]},
		]}}


func _worker_footprint_geometry(ref: String, designator: String) -> Dictionary:
	return _worker_call("pcb.footprint_geometry",
		{"ref": ref, "designator": designator},
		_canned_footprint_geometry() if ref == HEADER_REF
			else {"ok": false, "error": {"kind": "footprint",
				"message": "footprint %s not found in any library layer" % ref}})


## The geometric DRC's own union: determinate {ok:true, verdict:'clean'|
## 'violations'} or indeterminate {ok:false, verdict:'indeterminate', error}.
## The canned stand-in mirrors the shape and nothing else.
func _worker_geometric_drc(board: Dictionary) -> Dictionary:
	var envelope := _worker_call("minerva_pcb_drc_geometric", {"board": board},
		{"ok": true, "result": {"ok": true, "verdict": "clean", "findings": []}})
	var inner = envelope.get("result")
	return inner if inner is Dictionary else {}


# ── the host: duck-typed, with the one worker bridge the add path needs ───────

class WorkerHost extends Node:
	var data = null
	## Set to this suite's _worker_footprint_geometry; the add path reaches the
	## library through here exactly as the panel reaches it through its own
	## pcb.footprint_geometry channel.
	var resolver: Callable = Callable()
	func get_board_data():
		return data
	func get_panel():
		return null
	func footprint_geometry(ref: String, designator: String = "") -> Dictionary:
		return resolver.call(ref, designator)


func _host() -> WorkerHost:
	var host := WorkerHost.new()
	host.data = PCBData.new()
	host.data.from_board_dict(_board())
	host.resolver = _worker_footprint_geometry
	get_root().add_child(host)
	return host


## An empty 40x40 board with rules the fixture's parts comfortably satisfy.
func _board() -> Dictionary:
	return {
		"version": 2, "id": BOARD_ID, "name": "add-by-ref",
		"width_mm": 40.0, "height_mm": 40.0,
		"layers": ["top", "bottom"],
		"design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
			"via_diameter_mm": 0.8, "via_drill_mm": 0.4},
		"components": [], "nets": [], "traces": [], "vias": [], "zones": [],
	}


func _add(host, footprint: String, at: Vector2, id: String, extra: Dictionary = {}) -> Dictionary:
	var args := {"editor_name": "AddProbe", "footprint": footprint,
		"x": at.x, "y": at.y, "id": id, "snap_to_grid": false}
	for key in extra:
		args[key] = extra[key]
	return await PanelTools.handle(host, "minerva_pcb_add_component", args)


## The two headers, connected pin 1 to pin 1 — the board sections 2 and 3 both
## measure. Returns the host.
func _wired_board() -> WorkerHost:
	var host := _host()
	await _add(host, HEADER_REF, J1_AT, "J1")
	await _add(host, HEADER_REF, J2_AT, "J2")
	await PanelTools.handle(host, "minerva_pcb_connect_net",
		{"editor_name": "AddProbe", "net_name": "TESTNET", "pins": ["J1.1", "J2.1"]})
	return host


# ── 1. a library ref lands real geometry ─────────────────────────────────────

func _run_library_ref_lands_real_geometry() -> void:
	print("-- 1. the added part carries the library's own lands and silk --")
	var host := _host()
	var reply := await _add(host, HEADER_REF, J1_AT, "J1")
	check("the add succeeded", bool(reply.get("success", false)))

	var geometry: Dictionary = reply.get("geometry", {})
	check("the reply calls the part FABRICABLE", bool(geometry.get("fabricable", false)))
	check("…sourced from the LIBRARY (got '%s')" % str(geometry.get("source", "")),
		str(geometry.get("source", "")) == "library")
	check("…under its authored ref, not the CUSTOM rendering bucket",
		str(geometry.get("footprint", "")) == HEADER_REF)
	check("…with the header's two lands (got %d)" % int(geometry.get("pad_count", -1)),
		int(geometry.get("pad_count", -1)) == 2)
	check("the reply names the LIBRARY LAYER that supplied it",
		not str(reply.get("footprint_layer", "")).is_empty())

	# THE INDEPENDENT ORACLE: ask the worker directly what that footprint's pads
	# are, and compare against what the component ended up holding. Two calls,
	# one library; a transport that reshaped or invented geometry fails here.
	var direct := _worker_footprint_geometry(HEADER_REF, "J1")
	var direct_pads: Array = (direct.get("result", {}) as Dictionary).get("pads", [])
	var comp = host.data.get_component("J1")
	check("the worker itself reports two pads for this footprint (got %d)" % direct_pads.size(),
		direct_pads.size() == 2)
	check("the component holds exactly the pads the worker reported",
		comp != null and comp.pads.size() == direct_pads.size())
	check("…at the worker's own local positions and sizes",
		comp != null and _pads_agree(comp.pads, direct_pads))

	# Silk/courtyard are what make it a PART rather than a pair of holes: a
	# fabricable add has to bring the body outline with the copper.
	check("silk/courtyard graphics came with it (got %d)" % (comp.graphics.size() if comp != null else -1),
		comp != null and comp.graphics.size() > 0)
	check("the printed reference designator came with it too",
		comp != null and comp.refdes_graphics.size() > 0)

	# The pin map is rebuilt from the lands, so connect_net can address them.
	check("its pins are addressable by the footprint's own pad numbers",
		comp != null and comp.pins.has("1") and comp.pins.has("2"))

	# The board owns the geometry outright now (the FULL rule), so the part
	# still compiles on a machine whose library lacks the ref.
	check("the serialized component carries the pads KEY — the board is the authority",
		comp != null and comp.to_board_dict().has("pads"))

	# ARGUMENTS THE FOOTPRINT ANSWERS ARE NAMED BACK, not silently dropped.
	var host2 := _host()
	var with_pins := await _add(host2, HEADER_REF, J1_AT, "J2", {"pin_count": 40})
	check("a pin_count passed with a library ref is reported as ignored",
		(with_pins.get("ignored", []) as Array).has("pin_count"))
	check("…and the part still has the FOOTPRINT's two pins, not forty",
		int((with_pins.get("geometry", {}) as Dictionary).get("pad_count", -1)) == 2)

	host.queue_free()
	host2.queue_free()


## Do two pad lists describe the same copper? Compared by number, local
## position and size — the fields a fab reads — at the model's own quantum.
func _pads_agree(held: Array, reported: Array) -> bool:
	var by_number := {}
	for p in reported:
		by_number[str((p as Dictionary).get("number", ""))] = p
	for pad in held:
		var num := str((pad as Dictionary).get("number", ""))
		if not by_number.has(num):
			return false
		var want: Dictionary = by_number[num]
		var want_pos: Dictionary = want.get("position", {})
		var want_size: Dictionary = want.get("size", {})
		var pos: Vector2 = (pad as Dictionary).get("position", Vector2.ZERO)
		var size: Vector2 = (pad as Dictionary).get("size", Vector2.ZERO)
		if absf(pos.x - float(want_pos.get("x", NAN))) > 1.0e-4:
			return false
		if absf(pos.y - float(want_pos.get("y", NAN))) > 1.0e-4:
			return false
		if absf(size.x - float(want_size.get("width", NAN))) > 1.0e-4:
			return false
		if absf(size.y - float(want_size.get("height", NAN))) > 1.0e-4:
			return false
	return true


# ── 2. the board still checks ────────────────────────────────────────────────

func _run_the_board_still_checks() -> void:
	print("-- 2. the real worker's geometric DRC over the board is clean --")
	var host := await _wired_board()
	check("both parts landed", host.data.components.size() == 2)
	check("the panel's own census finds nothing unfabricable",
		PcbLibraryPart.unresolved_ids(host.data).is_empty())

	var verdict := _worker_geometric_drc(
		PanelTools.canonical_wire_board(host.data.to_board_dict()))
	check("the check is DETERMINATE — the parts resolved (verdict '%s')"
			% str(verdict.get("verdict", "<none>")),
		bool(verdict.get("ok", false)) and str(verdict.get("verdict", "")) != "indeterminate")
	check("…and clean", str(verdict.get("verdict", "")) == "clean")
	host.queue_free()


# ── 3. a sketch part is named, and the board stops checking ──────────────────

func _run_a_sketch_part_is_named() -> void:
	print("-- 3. one sketch part: named at add time, and the board goes indeterminate --")
	var host := await _wired_board()
	var reply := await _add(host, "HEADER", SKETCH_AT, "TP2", {"pin_count": 2})
	check("the sketch add succeeds — placing a part before its footprint is chosen is allowed",
		bool(reply.get("success", false)))

	var geometry: Dictionary = reply.get("geometry", {})
	check("the reply says so AT ADD TIME: not fabricable",
		not bool(geometry.get("fabricable", true)))
	check("…and calls it a sketch (got '%s')" % str(geometry.get("source", "")),
		str(geometry.get("source", "")) == "sketch")
	check("…and the note names the way out — a library ref",
		str(geometry.get("note", "")).contains("LibNick:PartName"))

	# THE PANEL STATE, from the same one rule the canvas badge reads.
	var unresolved: Array = PcbLibraryPart.unresolved_ids(host.data)
	check("the panel's census names exactly the sketch part (got %s)" % str(unresolved),
		unresolved == ["TP2"])
	var lead := PcbLibraryPart.status_lead(unresolved)
	check("the held status lead names it by id", lead.contains("TP2"))
	check("…and says what it costs the board", lead.contains("pour"))

	# THE WORKER'S OWN VERDICT. Section 2 ran this exact check over this exact
	# board WITHOUT the sketch part and got a determinate clean, so the change
	# here is attributable to TP2 and to nothing else.
	var verdict := _worker_geometric_drc(
		PanelTools.canonical_wire_board(host.data.to_board_dict()))
	check("the geometric DRC now refuses the board (fail-closed, and correct)",
		not bool(verdict.get("ok", true)) or str(verdict.get("verdict", "")) == "indeterminate")
	var refusal := JSON.stringify(verdict.get("error", verdict))
	check("…and the refusal names the offending component rather than the board (got: %s)"
			% refusal.left(200),
		refusal.contains("TP2"))
	host.queue_free()


# ── 4. an unresolvable ref adds nothing ──────────────────────────────────────

func _run_an_unresolvable_ref_adds_nothing() -> void:
	print("-- 4. a ref the library does not have is refused, and nothing lands --")
	var host := _host()
	var before: int = host.data.components.size()
	var reply := await _add(host, ABSENT_REF, J1_AT, "J9")
	check("the add is refused", not bool(reply.get("success", false)))
	var err := str(reply.get("error", ""))
	check("…by name, quoting the ref that could not be resolved", err.contains(ABSENT_REF))
	check("…and pointing at the two verbs that fix it",
		err.contains("footprint_report") and err.contains("acquire_footprint"))
	check("the board is untouched — no placeholder was left behind",
		host.data.components.size() == before)
	check("…and specifically no component under the requested id",
		host.data.get_component("J9") == null)
	host.queue_free()
