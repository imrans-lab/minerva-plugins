extends SceneTree
## Bug 019fa0f8d575 (fixed epoch GA-6) — the ONE typed-Dictionary guard for
## worker-reply reads. GDScript hard-errors when a wrong-TYPE value lands in
## a statically-typed var, and `.get(key, {})` defaults only on an ABSENT
## key, so a JSON null/list/string at the key used to crash the whole render
## or tool call (75 sites across the two panel files; two passed NO default
## and crashed on a merely-absent key). The fix is one static helper per
## file, applied uniformly — so the helper's matrix IS the behavioral pin.
##
## Run:
##   godot --headless --path src --script ../../minerva-plugins/pcb/tests/gd/test_dict_guard.gd

const PANEL_TOOLS_PATH := "res://../../minerva-plugins/pcb/ui/panel_tools.gd"
const PCB_PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

var _fail := 0
var _passed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s" % label)


func _matrix(script: Script, name: String) -> void:
	# Every wrong-type shape a malformed/foreign reply can carry maps to {}.
	_check(script._dict_or_empty(null) == {}, "%s: null -> {}" % name)
	_check(script._dict_or_empty([]) == {}, "%s: array -> {}" % name)
	_check(script._dict_or_empty("oops") == {}, "%s: string -> {}" % name)
	_check(script._dict_or_empty(42) == {}, "%s: int -> {}" % name)
	_check(script._dict_or_empty(3.5) == {}, "%s: float -> {}" % name)
	_check(script._dict_or_empty(true) == {}, "%s: bool -> {}" % name)
	# A real Dictionary passes through IDENTICALLY (same reference, not a copy
	# — callers that mutate the result in place depend on this).
	var real := {"k": 1}
	_check(script._dict_or_empty(real) == real, "%s: dict passes through" % name)
	_check(script._dict_or_empty(real) is Dictionary, "%s: type kept" % name)
	# The fallback arg (the one site whose absent-key default is another
	# Dictionary): wrong type -> fallback, right type -> the value.
	var fb := {"fb": true}
	_check(script._dict_or_empty(null, fb) == fb, "%s: null -> fallback" % name)
	_check(script._dict_or_empty(real, fb) == real, "%s: dict beats fallback" % name)
	# The `.get` composition the sweep produces: absent key -> null -> {};
	# present-but-malformed -> {}; present-and-well-formed -> the dict.
	var reply := {"good": {"x": 1}, "bad": null, "worse": [1, 2]}
	_check(script._dict_or_empty(reply.get("missing")) == {},
		"%s: absent key -> {} (the no-default crash class)" % name)
	_check(script._dict_or_empty(reply.get("bad")) == {},
		"%s: null value -> {}" % name)
	_check(script._dict_or_empty(reply.get("worse")) == {},
		"%s: list value -> {}" % name)
	_check(script._dict_or_empty(reply.get("good")) == {"x": 1},
		"%s: well-formed value survives" % name)


func _init() -> void:
	var tools: Script = load(PANEL_TOOLS_PATH)
	_check(tools != null, "panel_tools.gd loads")
	if tools != null:
		_matrix(tools, "panel_tools")

	var panel: Script = load(PCB_PANEL_PATH)
	_check(panel != null, "PCBPanel.gd loads")
	if panel != null:
		_matrix(panel, "PCBPanel")

	print("\n=== Results: %d passed, %d failed ===" % [_passed, _fail])
	quit(1 if _fail > 0 else 0)
