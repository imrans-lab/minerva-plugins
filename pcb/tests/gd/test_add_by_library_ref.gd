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
##      carries the pads the LOCKED FOOTPRINT FILE authors. The oracle is that
##      .kicad_mod, parsed here — asking the worker a second time would compare
##      one library read against another, and geometry that is consistently
##      wrong on both sides would pass. Silk and courtyard arrive with it,
##      which is what makes the part fabricable rather than merely pad-bearing.
##
##   2. THE BOARD STILL CHECKS, AND THE RESOLVE IS WHAT SHRINKS THE WIRE. The
##      real worker's geometric DRC over the board with the added part is
##      DETERMINATE and clean. This is the whole point: a part added this way
##      costs the board nothing. The same board then pins both halves of the
##      resolved-fact contract: because the parts resolved against THIS
##      machine's library moments ago, the wire form drops their lands (the
##      worker re-derives them) — and because that fact is about this machine
##      and not about the board, the SAVED document carries the lands but not
##      the claim. A document that carried the claim is what reopened on a
##      machine whose library lacked the ref, trimmed the pads anyway, and
##      handed the worker a part with no geometry and no way to get any.
##
##   3. A SKETCH PART IS NAMED, AT ADD TIME, AND THE BOARD STOPS CHECKING. The
##      same board, the same check, one HEADER added: the verdict goes
##      indeterminate. That is CORRECT and stays (fail-closed is the hermetic
##      rule), so what this section pins is that nobody has to guess why — the
##      add reply names it, the panel's own census names it, and the worker's
##      refusal names the component. The POUR the status lead promises is
##      driven for real over the same channel the panel uses: an authored pour
##      refuses to fill while the sketch part is on the board, names it, and
##      fills again the moment it is deleted. Section 2 is the control that
##      makes this section's failure attributable to the sketch part and
##      nothing else.
##
##   4. AN UNRESOLVABLE REF ADDS NOTHING. A ref the library does not have is
##      refused by name, and the board is byte-identical afterwards — the
##      alternative is putting back exactly the placeholder this path retires.
##
## FAILS AGAINST OLD: section 1's add is refused outright ("Invalid footprint
## type"), so every assertion in 1 and 2 fails; section 3's reply carries no
## `geometry` block.
## Section 2's wire/save assertions fail on their own account against the codec
## that round-tripped footprint_resolved: the live dict never carried the flag
## for a part added this session (it only ever arrived through the canonical
## Extra passthrough, so the wire trimmed nothing), and to_saved_board_dict did
## not exist.

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

## THE ORACLE FILE: the authored footprint HEADER_REF names, and the sha256
## footprints.lock.json pins it at. Both sides of the add path read this file
## through the worker; this suite reads the bytes.
const HEADER_MOD_PATH := PLUGIN_ROOT + "/library/footprints/Connector_PinHeader_2.54mm.pretty/PinHeader_1x02_P2.54mm_Vertical.kicad_mod"
const HEADER_MOD_SHA := "d5ac19c4d2a8248d6bdb67fee2db15f11d6a63af7c5bd63dd6faf23103b60c1c"

## Where the two headers go. Far apart and well inside the outline, so a clean
## geometric verdict in section 2 is about the parts resolving and not about
## some clearance the fixture happened to break.
const J1_AT := Vector2(10.0, 10.0)
const J2_AT := Vector2(30.0, 10.0)
## The sketch part, placed clear of both.
const SKETCH_AT := Vector2(20.0, 25.0)

## The pour section 3 authors over both headers. Well inside the 40x40 outline
## and far larger than anything the compiler carves out of it, so an empty fill
## is about the fill being REFUSED and not about a pour with nowhere to go.
const POUR_MIN := Vector2(5.0, 5.0)
const POUR_MAX := Vector2(35.0, 15.0)

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
		"graphics": [],
		# The DEFAULT designator anchor (the emitter's, for a footprint that
		# authors no reference fp_text). The part strokes its own ref here —
		# the reply never carries a rendering of one.
		"refdes_anchor": {"x_mm": 0.0, "y_mm": -1.5, "rotation_deg": 0.0,
			"size_mm": 1.0, "hidden": false},
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


func _worker_footprint_geometry(ref: String) -> Dictionary:
	return _worker_call("pcb.footprint_geometry",
		{"ref": ref},
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


## The pour fill, over the SAME channel and payload the panel's own
## PCBPanel.zone_fill_check sends. The canned stand-in mirrors the reply shape
## and answers the FILLABLE case, so it cannot satisfy the refusal arm.
func _worker_zone_fill(board: Dictionary) -> Dictionary:
	return _worker_call("pcb.zone_fill", {"board": board},
		{"ok": true, "result": {"zones": [
			{"id": "canned", "fill": [_rect(POUR_MIN, POUR_MAX)]}]}})


## Total filled regions across every pour in a zone_fill reply. A pour whose
## copper was never computed is OMITTED from the reply, so absent and empty
## both count as zero here — which is what "the fill did not come back" means.
func _pour_regions(reply: Dictionary) -> int:
	var result = reply.get("result")
	if not bool(reply.get("ok", false)) or not (result is Dictionary):
		return 0
	var total := 0
	for entry in (result as Dictionary).get("zones", []):
		if entry is Dictionary:
			var fill = (entry as Dictionary).get("fill")
			if fill is Array:
				total += (fill as Array).size()
	return total


## A closed rectangular outline in the {x_mm, y_mm} point form the zone verbs
## and the fill reply both speak.
func _rect(a: Vector2, b: Vector2) -> Array:
	return [{"x_mm": a.x, "y_mm": a.y}, {"x_mm": b.x, "y_mm": a.y},
		{"x_mm": b.x, "y_mm": b.y}, {"x_mm": a.x, "y_mm": b.y}]


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
	func footprint_geometry(ref: String) -> Dictionary:
		return resolver.call(ref)


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
	# `pins` is [{component, pin}] — the verb refuses bare "J1.1" strings with
	# invalid_pin. It used to be called with those strings here, so TESTNET was
	# never declared and section 3's pour was refused for the wrong reason; the
	# reply is checked so a silent refusal cannot hide the fixture again.
	var wired: Dictionary = await PanelTools.handle(host, "minerva_pcb_connect_net",
		{"editor_name": "AddProbe", "net_name": "TESTNET",
		"pins": [{"component": "J1", "pin": "1"}, {"component": "J2", "pin": "1"}]})
	check("fixture: TESTNET wired across both headers (got: %s)" % str(wired.get("error", "")),
		bool(wired.get("success", false)) and host.data.has_net("TESTNET"))
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

	# THE INDEPENDENT ORACLE: the authored footprint FILE, parsed here. A second
	# call to the worker would compare one library read against another, so
	# geometry that is wrong the same way on both sides would pass; the
	# .kicad_mod is the source those reads descend from and nothing in the add
	# path can reach it.
	var authored := _authored_pads()
	check("the oracle is the footprint the lock pins (sha256 matches)",
		FileAccess.get_sha256(ProjectSettings.globalize_path(HEADER_MOD_PATH))
			== HEADER_MOD_SHA)
	var want_numbers: Array = authored.keys()
	want_numbers.sort()
	check("…and that file authors two pads (got %s)" % str(want_numbers),
		want_numbers == ["1", "2"])

	var comp = host.data.get_component("J1")
	check("the component holds exactly the footprint's pad numbers (got %s)"
			% str(_pad_numbers(comp)), _pad_numbers(comp) == want_numbers)
	check("…at the authored local positions, sizes, drills and shapes",
		_lands_match_authored(comp, authored))
	check("…and the pose lands each of them at the requested board coordinate",
		_pins_match_authored(comp, authored, J1_AT))

	# Silk/courtyard are what make it a PART rather than a pair of holes: a
	# fabricable add has to bring the body outline with the copper.
	check("silk/courtyard graphics came with it (got %d)" % (comp.graphics.size() if comp != null else -1),
		comp != null and comp.graphics.size() > 0)
	# The designator is a RENDER of the live ref, not a picture the reply
	# carried: a copy of this part answers to its own new name, and answers to
	# J1's strokes again the moment it is named J1.
	var twin = comp.duplicate_component() if comp != null else null
	if twin != null:
		twin.id = "ZZ9"
	var twin_renamed: bool = twin != null \
		and twin.refdes_graphics.size() > 0 \
		and twin.refdes_graphics != comp.refdes_graphics
	if twin != null:
		twin.id = "J1"
	check("it strokes its OWN ref as the printed designator — a copy follows its new name, and matches again when renamed back",
		comp != null and comp.refdes_graphics.size() > 0
			and twin_renamed and twin.refdes_graphics == comp.refdes_graphics)

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


## The authored .kicad_mod's own pad facts, keyed by pad number:
## {number: {type, shape, position: Vector2, size: Vector2, drill: float}}.
##
## Parses the s-expression form directly —
## `(pad <number> <type> <shape> (at x y) (size w h) (drill d) (layers ...))` —
## because the point of this oracle is that it shares no code with the resolve
## path under test.
func _authored_pads() -> Dictionary:
	var out := {}
	var f := FileAccess.open(
		ProjectSettings.globalize_path(HEADER_MOD_PATH), FileAccess.READ)
	if f == null:
		printerr("[test_add_by_library_ref] cannot read the oracle footprint: %s"
			% HEADER_MOD_PATH)
		return out
	var text := f.get_as_text()
	f.close()
	var re := RegEx.new()
	re.compile("\\(pad\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+\\(at\\s+([-\\d.]+)\\s+([-\\d.]+)\\)\\s+\\(size\\s+([-\\d.]+)\\s+([-\\d.]+)\\)(?:\\s+\\(drill\\s+([-\\d.]+)\\))?")
	for m in re.search_all(text):
		out[m.get_string(1)] = {
			"type": m.get_string(2),
			"shape": m.get_string(3),
			"position": Vector2(m.get_string(4).to_float(), m.get_string(5).to_float()),
			"size": Vector2(m.get_string(6).to_float(), m.get_string(7).to_float()),
			"drill": m.get_string(8).to_float(),
		}
	return out


## The pad numbers a component actually holds, sorted.
func _pad_numbers(comp) -> Array:
	var out: Array = []
	if comp == null:
		return out
	for pad in comp.pads:
		out.append(str((pad as Dictionary).get("number", "")))
	out.sort()
	return out


## One pad's drill diameter, whichever of the model's two encodings it carries
## (Vector2 for the current form, a bare float for the legacy one).
func _pad_drill(pad) -> float:
	var raw = (pad as Dictionary).get("drill", 0.0)
	if raw is Vector2:
		return (raw as Vector2).x
	if raw is Dictionary:
		return float((raw as Dictionary).get("x", 0.0))
	return float(raw)


## Do the component's lands carry the FILE's numbers? Local position, size,
## drill, shape and type — the fields a fab reads off a pad.
func _lands_match_authored(comp, authored: Dictionary) -> bool:
	if comp == null or comp.pads.size() != authored.size():
		return false
	for pad in comp.pads:
		var num := str((pad as Dictionary).get("number", ""))
		if not authored.has(num):
			return false
		var want: Dictionary = authored[num]
		var pos: Vector2 = (pad as Dictionary).get("position", Vector2.ZERO)
		var size: Vector2 = (pad as Dictionary).get("size", Vector2.ZERO)
		if not pos.is_equal_approx(want["position"]):
			return false
		if not size.is_equal_approx(want["size"]):
			return false
		if absf(_pad_drill(pad) - float(want["drill"])) > 1.0e-4:
			return false
		if str((pad as Dictionary).get("shape", "")) != str(want["shape"]):
			return false
		if str((pad as Dictionary).get("type", "")) != str(want["type"]):
			return false
	return true


## Does the rebuilt pin map put every authored pad at the BOARD coordinate the
## add asked for? The pins carry local offsets, so the authored position is
## transformed by the component's own pose — `origin` is where the add put the
## part, which is what makes this the assertion that reads the pose rather than
## the footprint.
func _pins_match_authored(comp, authored: Dictionary, origin: Vector2) -> bool:
	if comp == null or comp.pins.size() != authored.size():
		return false
	var turn := deg_to_rad(comp.rotation)
	for num in authored:
		if not comp.pins.has(num):
			return false
		var held: Vector2 = comp.position + (comp.pins[num] as Vector2).rotated(turn)
		var want: Vector2 = origin + (authored[num]["position"] as Vector2).rotated(turn)
		if held.distance_to(want) > 1.0e-4:
			return false
	return true


# ── 2. the board still checks ────────────────────────────────────────────────

func _run_the_board_still_checks() -> void:
	print("-- 2. the real worker's geometric DRC over the board is clean --")
	var host := await _wired_board()
	check("both parts landed", host.data.components.size() == 2)
	check("the panel's own census finds nothing unfabricable",
		PcbLibraryPart.unresolved_ids(host.data).is_empty())

	var full_board: Dictionary = host.data.to_board_dict()
	var verdict := _worker_geometric_drc(
		PanelTools.canonical_wire_board(full_board))
	check("the check is DETERMINATE — the parts resolved (verdict '%s')"
			% str(verdict.get("verdict", "<none>")),
		bool(verdict.get("ok", false)) and str(verdict.get("verdict", "")) != "indeterminate")
	check("…and clean", str(verdict.get("verdict", "")) == "clean")

	# THE RESOLVE THAT JUST HAPPENED IS WHAT SHRINKS THE WIRE. Both headers came
	# off THIS machine's library moments ago, so the worker on the other end of
	# the channel can re-derive their lands and the wire form drops them. The
	# fact is carried by footprint_resolved, which the add path sets from the
	# real pcb.footprint_geometry reply — session state, never restored from a
	# document, so this assertion is about the resolve and not about a flag some
	# earlier save wrote.
	var wire_board: Dictionary = PanelTools.canonical_wire_board(full_board)
	var carried_pads := 0
	var wire_pads := 0
	for comp in (full_board.get("components", []) as Array):
		if (comp as Dictionary).has("pads"):
			carried_pads += 1
		check("%s reached the board dict marked resolved by this session's library read"
				% str((comp as Dictionary).get("ref", "?")),
			bool((comp as Dictionary).get("footprint_resolved", false)))
	for comp in (wire_board.get("components", []) as Array):
		if (comp as Dictionary).has("pads"):
			wire_pads += 1
	check("the live board dict carries both parts' lands (%d of 2)" % carried_pads,
		carried_pads == 2)
	check("…and the wire form carries none of them — resolved here, so the worker re-derives (%d)" % wire_pads,
		wire_pads == 0)

	# THE SAVE HALF, on the same board: what gets written must not tell the next
	# machine that ITS library resolved these refs. Reopening a document that
	# claimed so is what silently handed the worker a pad-less part.
	var saved_board: Dictionary = host.data.to_saved_board_dict()
	var saved_flags := 0
	var saved_pads := 0
	for comp in (saved_board.get("components", []) as Array):
		if (comp as Dictionary).has("footprint_resolved"):
			saved_flags += 1
		if (comp as Dictionary).has("pads"):
			saved_pads += 1
	check("the saved board asserts no resolve (%d flags)" % saved_flags, saved_flags == 0)
	check("…while keeping the lands it authored, so it opens fabricable anywhere (%d of 2)"
			% saved_pads, saved_pads == 2)
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

	# THE POUR, DRIVEN. The status lead above only SAYS a sketch part costs the
	# board its pours; this authors one and runs the panel's own pcb.zone_fill
	# round-trip over it, so the claim is measured on the fill itself.
	var zoned := await PanelTools.handle(host, "minerva_pcb_create_zone", {
		"editor_name": "AddProbe", "kind": "copper_pour", "net": "TESTNET",
		"layer": "top", "outline": _rect(POUR_MIN, POUR_MAX)})
	check("a copper pour is authored over both headers (got: %s)" % str(zoned.get("error", "")),
		bool(zoned.get("success", false)))

	var refused := _worker_zone_fill(
		PanelTools.canonical_wire_board(host.data.to_board_dict()))
	check("the FILL refuses the board too, not only the geometric DRC",
		not bool(refused.get("ok", true)))
	var fill_refusal := JSON.stringify(refused.get("error", refused))
	check("…naming the sketch part that took the pour down (got: %s)"
			% fill_refusal.left(200),
		fill_refusal.contains("TP2"))

	# AND IT COMES BACK. Deleting the one sketch part is the only difference
	# between the two fills, so copper returning is attributable to it alone.
	var removed := await PanelTools.handle(host, "minerva_pcb_delete_component",
		{"editor_name": "AddProbe", "component_id": "TP2"})
	check("the sketch part is deleted", bool(removed.get("success", false))
		and host.data.get_component("TP2") == null)
	var refilled := _worker_zone_fill(
		PanelTools.canonical_wire_board(host.data.to_board_dict()))
	check("the pour fills once the sketch part is gone", bool(refilled.get("ok", false)))
	check("…with copper actually in it (regions=%d)" % _pour_regions(refilled),
		_pour_regions(refilled) > 0)
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
