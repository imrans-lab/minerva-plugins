extends SceneTree
## TRACE-WIDTH SEEDING + THE PREFERENCE FILE (campaign-2 boundary, round A7's
## oracles BT-27 / BT-28 / BT-31; C2-CHECK 7 `019fb94e6...`, docket 019fb92f07e2).
##
## Run: godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_pcb_width_prefs.gd
##
## A7 shipped three claims that nothing pinned:
##
##   (BT-27) SEEDING PRECEDENCE — board design rule > stored preference >
##           control default, in that order, decided in PCBPanel.seeded_trace_width().
##   (BT-28) THE FILE ON DISK is the preference's representation: exactly
##           {"version": 1, "values": {...}} carrying the POST-CLAMP value; and a
##           corrupt file degrades to defaults with the warning shown ONCE.
##   (BT-31) An out-of-contract trace (wider than MAX_WIDTH_MM) must not have its
##           copper rewritten by the control that displays it.
##
## ORACLE DISCIPLINE. Every assertion here reads a DIFFERENT representation than
## the code under test writes:
##   * seeding is read off the mounted SpinBox's `value`, never from
##     seeded_trace_width()'s return — the function agreeing with itself proves
##     nothing about whether the control was ever driven;
##   * the file half reads RAW JSON PARSED OFF DISK, not the store's own
##     `snapshot()`, because "it is in memory" and "it survives a restart" are
##     different claims and only the second one is the feature;
##   * the width half reads the SERIALIZED board dict, not the trace object.
##
## C2-CHECK 7's own warning is obeyed: the three seeding fixtures use MUTUALLY
## DISTINCT numbers (rule 0.40 / preference 0.75 / default 0.25). With any two
## equal, a precedence inversion passes on a fixture that cannot tell them apart.
##
## SANDBOXING. pcb_prefs documents `_base_dir` as the probe/test seam, so both
## the shared store and the instances here are pointed at a scratch directory
## under user://. Nothing in this suite writes the real preference file, and the
## shared store's base dir is restored before the suite exits — a leaked override
## would make every later suite in the same process read a scratch file.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const PREFS_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_prefs.gd"
const TRACE_PATH := "res://../../minerva-plugins/pcb/ui/model/pcb_trace.gd"

## Mutually distinct on purpose — see the header.
const RULE_WIDTH := 0.40
const PREF_WIDTH := 0.75
## Wider than MAX_WIDTH_MM (5.0), for the out-of-contract case.
const OVERWIDE := 7.0

var _pass := 0
var _fail := 0

var _Prefs: Script = null
var _Trace: Script = null
var _scratch := ""
var _restore_base_dir := ""


func check(desc: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)


class FakeEditor extends RefCounted:
	var tab_title: String = "Width Prefs Tab"
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB trace-width seeding + preference file ===\n")
	await process_frame
	get_root().size = Vector2i(1300, 800)

	_Prefs = load(PREFS_PATH)
	_Trace = load(TRACE_PATH)
	check("prefs + trace scripts load off-tree", _Prefs != null and _Trace != null)
	if _Prefs == null or _Trace == null:
		_finish()
		return

	_scratch = "user://test_pcb_width_prefs"
	_wipe_scratch()

	# Point the PROCESS-WIDE store at the scratch dir for the whole suite. The
	# panel reads it through get_preferences() -> shared(), which takes no
	# argument, so this is the only injection point that reaches the panel.
	var shared = _Prefs.shared()
	_restore_base_dir = shared._base_dir
	shared._base_dir = _scratch

	await _test_seeding_precedence()
	_test_file_shape_on_disk()
	_test_corrupt_file_degrades_and_warns_once()
	await _test_overwide_trace_keeps_its_copper()
	_assert_every_section_ran()

	# Restore before exiting: a leaked override outlives this suite.
	shared._base_dir = _restore_base_dir
	shared.reload()
	_wipe_scratch()
	_finish()


# ── Harness ───────────────────────────────────────────────────────────────────

## SECTION REGISTRY — see test_pcb_panel_model.gd's copy for the incident that
## created it: a runtime error aborts the whole enclosing function, so an oracle
## can contribute ZERO assertions while the suite reads clean green.
var _section_marks: Array = []


func _begin_section(label: String) -> void:
	_section_marks.append({"label": label, "at": _pass + _fail})


func _assert_every_section_ran() -> void:
	print("\n-- every section actually ran --")
	var silent: Array = []
	for i in range(_section_marks.size()):
		var mark: Dictionary = _section_marks[i]
		var next_at: int = int(_section_marks[i + 1]["at"]) if i + 1 < _section_marks.size() \
				else _pass + _fail
		if next_at - int(mark["at"]) <= 0:
			silent.append(str(mark["label"]))
	check("no section produced ZERO assertions (silent: %s)" % str(silent), silent.is_empty())
	check("all 4 sections declared themselves (%d)" % _section_marks.size(),
			_section_marks.size() == 4)


func _wipe_scratch() -> void:
	var dir := _scratch.path_join("pcb")
	var file := dir.path_join("preferences.json")
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(file)


func _board(rule_width: float) -> Dictionary:
	var board: Dictionary = {
		"version": 1, "name": "WidthPrefs", "width_mm": 60.0, "height_mm": 40.0,
		"grid_mm": 2.54,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 20.0, "y_mm": 20.0,
				"rotation_deg": 0.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
	}
	if rule_width > 0.0:
		board["design_rules"] = {"trace_width_mm": rule_width}
	return board


func _mount(board: Dictionary) -> Control:
	var panel: Control = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1100, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(board)
	# _refresh_board_ui() IS the load path — every production entry point calls it
	# immediately after from_board_dict (PCBPanel.gd:421 on mount, :3262 on
	# load_board_from_yaml, :3574 on file open), and it is what re-seeds the width
	# box for the new board.
	#
	# TRAP, measured while writing this suite: a harness that stops at
	# from_board_dict leaves the box holding whatever it was seeded with BEFORE
	# any board existed. Fixtures (b) and (c) below still pass in that state — by
	# coincidence, since the pre-board seed reads the same preference and the same
	# default — so the omission looks harmless right up until fixture (a), where
	# the board's rule is the only thing that could have changed the number. Do
	# not remove this call to "simplify the harness".
	panel._refresh_board_ui()
	for _i in range(6):
		await process_frame
	return panel


## The SpinBox itself, found by NAME through the live tree. Deliberately not
## `panel._trace_width_spin`: a found node proves the control was actually built
## into the panel the human sees, which a member reference does not.
func _width_spin(panel: Control) -> SpinBox:
	return panel.find_child("TraceWidthSpin", true, false) as SpinBox


func _store_preference(value: float) -> void:
	var shared = _Prefs.shared()
	shared.reload()
	var res: Dictionary = shared.set_value(_Prefs.KEY_TRACE_WIDTH, value)
	if not bool(res.get("ok", false)):
		check("preference fixture stored", false, str(res.get("error", "")))


func _clear_preference() -> void:
	var shared = _Prefs.shared()
	_wipe_scratch()
	shared.reload()


# ── BT-27. Seeding precedence, three mutually-distinct fixtures ───────────────

## Owner ruling (A7): the BOARD's design rule outranks the stored preference,
## which outranks the control's own default. "The board is a document; the
## preference is a habit."
##
## Read off the mounted SpinBox because that is the number the human acts on. A
## precedence bug that inverts steps 1 and 2 shows up as fixture (a) reporting
## 0.75; one that drops step 3 shows up as fixture (c).
##
## The THIRD fixture is what makes step 2 observable at all: pcb_prefs returns
## the registry default for an UNSTORED key, so "never chose one" and "chose the
## default" read identically through get_value(). Only has_stored() separates
## them, and only a fixture with NO stored key can red when has_stored() is
## dropped.
func _test_seeding_precedence() -> void:
	_begin_section("BT-27")
	print("\n-- BT-27: seeding precedence (rule %.2f > preference %.2f > default %.2f) --"
			% [RULE_WIDTH, PREF_WIDTH, float(_Trace.DEFAULT_WIDTH_MM)])

	check("the three fixture widths are mutually distinct (C2-CHECK 7: equal values mask precedence)",
			not is_equal_approx(RULE_WIDTH, PREF_WIDTH)
			and not is_equal_approx(RULE_WIDTH, float(_Trace.DEFAULT_WIDTH_MM))
			and not is_equal_approx(PREF_WIDTH, float(_Trace.DEFAULT_WIDTH_MM)))

	# (a) board rule AND a stored preference -> the RULE wins.
	_store_preference(PREF_WIDTH)
	var panel_a := await _mount(_board(RULE_WIDTH))
	var spin_a := _width_spin(panel_a)
	check("(a) rule+preference: the width box is built into the panel", spin_a != null)
	if spin_a != null:
		check("(a) rule+preference -> the BOARD's rule (%.2f), not the preference" % RULE_WIDTH,
				is_equal_approx(spin_a.value, RULE_WIDTH),
				"got %.3f — %.3f would mean the preference outranked the document"
						% [spin_a.value, PREF_WIDTH])
	panel_a.queue_free()
	await process_frame

	# (b) NO rule, preference stored -> the PREFERENCE fills the gap.
	var panel_b := await _mount(_board(0.0))
	var spin_b := _width_spin(panel_b)
	check("(b) no rule + preference -> the stored preference (%.2f)" % PREF_WIDTH,
			spin_b != null and is_equal_approx(spin_b.value, PREF_WIDTH),
			"got %.3f" % (spin_b.value if spin_b != null else -1.0))
	panel_b.queue_free()
	await process_frame

	# (c) NEITHER -> the control's own default.
	_clear_preference()
	var panel_c := await _mount(_board(0.0))
	var spin_c := _width_spin(panel_c)
	check("(c) no rule + NO stored preference -> the default (%.2f)" % float(_Trace.DEFAULT_WIDTH_MM),
			spin_c != null and is_equal_approx(spin_c.value, float(_Trace.DEFAULT_WIDTH_MM)),
			"got %.3f — reading %.3f here would mean an UNSTORED key was treated as chosen"
					% [(spin_c.value if spin_c != null else -1.0), PREF_WIDTH])
	# ... and the store must AGREE that nothing was chosen. Asserted separately
	# from the spin value so a "default happens to equal the unstored read"
	# coincidence cannot carry the case.
	check("(c) the store reports the key as never-stored",
			not _Prefs.shared().has_stored(_Prefs.KEY_TRACE_WIDTH))
	panel_c.queue_free()
	await process_frame


# ── BT-28. The file on disk ───────────────────────────────────────────────────

## The DISK is the representation. A preference that lives only in memory is not
## a preference, it is a session variable — and every claim about "next time you
## open Minerva" rests on these bytes.
##
## Uses an INSTANCE store on its own directory rather than the shared one, so the
## file under assertion is created by this test and by nothing else.
func _test_file_shape_on_disk() -> void:
	_begin_section("BT-28")
	print("\n-- BT-28: the preference file's shape, and the post-clamp value --")
	var dir := _scratch.path_join("shape")
	var store = _Prefs.new(dir)
	var path: String = store.file_path()

	check("no file exists before the first write (first run is not an error)",
			not FileAccess.file_exists(path))

	# 40 mm is far out of contract; the store CLAMPS (unlike the model setter,
	# which refuses) and must persist what it actually stored, not what it was
	# handed. A file carrying 40.0 would re-read as an out-of-contract width on
	# every future launch.
	var res: Dictionary = store.set_value(_Prefs.KEY_TRACE_WIDTH, 40.0)
	check("an out-of-range write is accepted and reported as clamped",
			bool(res.get("ok", false)) and bool(res.get("clamped", false)),
			str(res))
	check("the file now exists", FileAccess.file_exists(path), path)

	var raw := ""
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		raw = f.get_as_text()
		f.close()
	var parsed: Variant = JSON.parse_string(raw)
	check("the file on disk is a JSON object", parsed is Dictionary)
	if parsed is Dictionary:
		var root: Dictionary = parsed
		var keys: Array = root.keys()
		keys.sort()
		check("its root is exactly {version, values} (host_owned convention)",
				keys == ["values", "version"], str(keys))
		check("version is the schema version, not an implicit 0",
				int(root.get("version", -1)) == int(_Prefs.SCHEMA_VERSION),
				str(root.get("version", null)))
		var values: Variant = root.get("values", null)
		check("values is a dictionary", values is Dictionary)
		if values is Dictionary:
			var stored: float = float((values as Dictionary).get(
					_Prefs.KEY_TRACE_WIDTH, -1.0))
			check("the value on disk is the POST-CLAMP width (%.2f), not the requested 40.0"
						% float(_Trace.MAX_WIDTH_MM),
					is_equal_approx(stored, float(_Trace.MAX_WIDTH_MM)),
					"got %.3f" % stored)

	# A SECOND store on the same directory is the restart: it must read the file
	# rather than inherit anything from the first instance.
	var reopened = _Prefs.new(dir)
	check("a fresh store reads the stored width back off disk",
			is_equal_approx(reopened.get_float(_Prefs.KEY_TRACE_WIDTH, -1.0),
					float(_Trace.MAX_WIDTH_MM)))
	check("... and reports it as STORED, not as the default coincidentally matching",
			reopened.has_stored(_Prefs.KEY_TRACE_WIDTH))

	DirAccess.remove_absolute(path)


## A corrupt file must degrade to defaults AND say so — once.
##
## "Once" is the load-bearing half. take_warning() is documented as consuming,
## because a warning is a thing to show a human, not standing state; a warning
## that re-arms on every seeding read would repaint the status line forever on a
## board whose width box is consulted on every selection change.
func _test_corrupt_file_degrades_and_warns_once() -> void:
	_begin_section("BT-28b")
	print("\n-- BT-28b: a corrupt preferences file degrades to defaults, warns ONCE --")
	var dir := _scratch.path_join("corrupt")
	var store = _Prefs.new(dir)
	DirAccess.make_dir_recursive_absolute(store.directory())
	var f := FileAccess.open(store.file_path(), FileAccess.WRITE)
	f.store_string("{ this is not json, it is a hand-edit gone wrong")
	f.close()

	# Reading through the store must not crash and must not adopt garbage.
	var value: float = store.get_float(_Prefs.KEY_TRACE_WIDTH, -1.0)
	check("a corrupt file reads back as the DEFAULT width, not as garbage",
			is_equal_approx(value, float(_Trace.DEFAULT_WIDTH_MM)),
			"got %.3f" % value)
	check("... and the key is not reported as stored",
			not store.has_stored(_Prefs.KEY_TRACE_WIDTH))

	check("a warning is raised", store.has_warning())
	var first: String = store.take_warning()
	check("the warning names the problem in words a human can act on",
			first.findn("preferences") >= 0 and first.findn("default") >= 0,
			first)

	# The COUNT: three further reads, no re-arm.
	for _i in range(3):
		store.get_float(_Prefs.KEY_TRACE_WIDTH, -1.0)
	check("the warning does NOT re-arm on subsequent reads (shown once, not forever)",
			not store.has_warning(),
			"take_warning() must consume; got %s" % store.take_warning())

	DirAccess.remove_absolute(store.file_path())


# ── BT-31. An out-of-contract trace ───────────────────────────────────────────

## A7 review F3 (recorded, narrow trigger): a trace authored WIDER than
## MAX_WIDTH_MM is out of the control's contract. The SpinBox that displays it is
## range-bounded, so it cannot show 7 mm.
##
## What this pins is the half that MATTERS and is true today: merely selecting
## such a trace must not rewrite its copper. The display is a view; the board is
## the document, and a view that silently narrows a 7 mm trace to 5 mm on
## selection would be a fabrication defect introduced by looking at it.
##
## The DISPLAY half of F3 (should the row read 7.0 or the clamped 5.0?) is NOT
## asserted here — see the FINDING recorded with this suite. It is an open
## question about shipped behaviour, and a test that fixed either answer now
## would either red on green code or lock in the behaviour the review flagged.
## What IS asserted is that whatever the row shows, it is inert: the serialized
## width is unchanged.
func _test_overwide_trace_keeps_its_copper() -> void:
	_begin_section("BT-31")
	print("\n-- BT-31: selecting an out-of-contract (%.1f mm) trace must not rewrite it --" % OVERWIDE)
	check("the fixture width really is out of contract",
			OVERWIDE > float(_Trace.MAX_WIDTH_MM))

	var board: Dictionary = _board(0.0)
	board["nets"] = [{"name": "N1", "pins": ["U1.1"]}]
	board["traces"] = [{
		"id": "T_WIDE", "net": "N1", "layer": "top", "width_mm": OVERWIDE,
		"points": [{"x_mm": 10.0, "y_mm": 10.0}, {"x_mm": 30.0, "y_mm": 10.0}],
	}]

	var panel := await _mount(board)
	var data = panel.get_data()

	# The oracle is the SERIALIZED board, never the trace object the panel holds.
	var before: float = _serialized_width(data, "T_WIDE")
	check("the authored %.1f mm width survives load+serialize" % OVERWIDE,
			is_equal_approx(before, OVERWIDE),
			"got %.3f — the width was already rewritten before any selection" % before)

	# Select it and let the property row drive.
	# panel._canvas, not panel.get_canvas() — the latter is CanvasItem's own
	# method and returns an RID, which silently is not the PCB canvas at all.
	var canvas: Variant = panel._canvas
	if canvas != null and canvas.has_method("select_trace"):
		canvas.select_trace("T_WIDE")
	elif canvas != null:
		canvas.set("selected_traces", ["T_WIDE"])
	if panel.has_method("_update_trace_rows"):
		panel._update_trace_rows()
	for _i in range(4):
		await process_frame

	var after: float = _serialized_width(data, "T_WIDE")
	check("after selection the SERIALIZED width is still %.1f mm" % OVERWIDE,
			is_equal_approx(after, OVERWIDE),
			"got %.3f — displaying a trace re-widened its copper" % after)

	# And the row, if it is showing, is inside its own declared contract — a
	# SpinBox reporting a value outside [min, max] would be a lying control.
	var row_spin := panel.find_child("TracePropWidthSpin", true, false) as SpinBox
	if row_spin != null:
		check("the property spin never reports a value outside its own declared range",
				row_spin.value >= row_spin.min_value - 0.0001
				and row_spin.value <= row_spin.max_value + 0.0001,
				"value=%.3f range=[%.3f, %.3f]"
						% [row_spin.value, row_spin.min_value, row_spin.max_value])

	panel.queue_free()
	await process_frame


func _serialized_width(data, trace_id: String) -> float:
	var dict: Dictionary = data.to_board_dict()
	for entry in dict.get("traces", []):
		if str((entry as Dictionary).get("id", "")) == trace_id:
			var d: Dictionary = entry
			if d.has("width_mm"):
				return float(d["width_mm"])
			return float(d.get("width", -1.0))
	return -1.0


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)
