extends RefCounted
## PLUGIN-SCOPED preference store for the PCB plugin (round A7, docket
## 019fb92f07e2). First key: trace_width_mm. Designed for more.
##
## WHY A PLUGIN-OWNED STORE AND NOT MINERVA'S PREFERENCES (owner ruling, this
## round): "how wide is a trace" is a PCB-domain fact. Core preferences are the
## host application's own settings surface; a plugin that pushed its domain keys
## in there would make the host's settings grow a PCB section it cannot validate
## and cannot explain. This file keeps the key, its type, its bounds and its
## default in ONE place next to the model that consumes them.
##
## WHERE IT WRITES, and why NOT ctx.data_directory. The panel's mount context
## carries `data_directory`, but for a DEV-INSTALLED plugin that is the plugin's
## own SOURCE directory — this git repo. Writing preferences there would drop an
## untracked (or worse, tracked) JSON file into the working tree of whoever is
## editing the plugin. The install-time data directory is the correct home:
## Minerva's PluginManager._create_plugin_directories creates
## "user://plugins/data/<plugin_id>/" on every successful install
## (PluginManager.gd ~379-390, measured), and PluginMCPTools documents it as
## THE plugin data directory. That is what DEFAULT_BASE_DIR points at.
##
## The manifest's filesystem:{mode:"none"} does NOT govern this file. That
## declaration is the capability grant checked for the plugin's Go WORKER
## subprocess; this store runs IN-PROCESS inside the Godot panel, under the
## host's own user:// sandbox, exactly as the panel's other host_owned state
## does. Noted so a future reader does not "fix" a contradiction that is not one.
##
## CONVENTIONS (host_owned save/load, project memory): flat root with an explicit
## `version`, defensive `.get()` on every read, and a corrupt or unreadable file
## NEVER crashes the panel — it degrades to defaults and reports a warning the
## caller can show (take_warning(), surfaced through PCBPanel's transient status
## line, the same trace_tool_message surface a refused trace uses).
##
## Off-tree note: lives OUTSIDE Minerva's res:// tree, so NO class_name —
## preloaded by relative path, the convention every pcb/ui/*.gd file follows.

## Trace width bounds/validation live on the entity that HAS a width
## (pcb_trace.gd), so the spin box, the model setter and this registry all read
## ONE rule rather than three copies of 0.1 and 5.0.
const _PcbTraceScript := preload("pcb_trace.gd")

## Install-time plugin data directory root (PluginManager.gd:383).
const DEFAULT_BASE_DIR := "user://plugins/data"
const PLUGIN_ID := "pcb"
const FILE_NAME := "preferences.json"
const SCHEMA_VERSION := 1

## Canonical key names. Declared as constants so callers (panel, MCP tools) name
## a key by symbol and a typo fails at parse time rather than silently writing a
## key nothing reads.
const KEY_TRACE_WIDTH := "trace_width_mm"


## The KNOWN-KEY REGISTRY: the whole contract of this store.
##
## An unknown key is REFUSED, never silently adopted — a store that accepted
## anything would let an agent's typo look like a successful write and then read
## back the default forever, with nothing anywhere saying which key is real.
## Adding a preference is one entry here plus (for a UI-visible one) the control
## that reads it.
##
## Built by a static func rather than declared as a `const` Dictionary so each
## caller gets a fresh mutable dict and we avoid const-Dictionary read-only
## semantics. (A const initializer CAN fold another script's constants — see
## pcb_data.gd's DEFAULT_TRACE_WIDTH_MM — so that is not the reason.)
static func key_registry() -> Dictionary:
	return {
		KEY_TRACE_WIDTH: {
			"type": TYPE_FLOAT,
			"default": _PcbTraceScript.DEFAULT_WIDTH_MM,
			"min": _PcbTraceScript.MIN_WIDTH_MM,
			"max": _PcbTraceScript.MAX_WIDTH_MM,
			"description": "Width, in mm, a newly drawn trace starts at when the "
				+ "board's own design_rules.trace_width_mm does not say.",
		},
	}


## The process-wide store. A preference is PLUGIN-scoped, not panel-scoped: two
## open PCB tabs must not each carry a private idea of the default trace width.
## (The MCP preference tools are executor:"panel" and resolve a live panel by
## editor_name before dispatch, so in production they can't run panel-less —
## panel_tools' null-panel branch is defensive only.) Instances are still
## constructible (see _init) so tests and probes can point a store at a scratch
## directory instead of the real one.
static var _shared = null


static func shared():
	if _shared == null:
		_shared = new()
	return _shared


## Base directory override, for probes/tests. The real store always uses
## DEFAULT_BASE_DIR; nothing in production passes this.
var _base_dir: String = DEFAULT_BASE_DIR

## Stored values, key -> validated value. Only keys the user/agent actually SET
## live here — an absent key means "never chosen", which is a different fact
## from "chosen and equal to the default" (PCBPanel's seeding order depends on
## exactly that distinction: a board design rule outranks a stored preference,
## and an unstored preference falls through to the control's own default).
var _values: Dictionary = {}

## Lazy load: the file is read on first access, not at construction, so building
## a store costs nothing on a panel that never touches a preference.
var _loaded := false

## Last problem worth showing a human ("" when none). Consumed by take_warning().
var _warning: String = ""


func _init(base_dir: String = DEFAULT_BASE_DIR) -> void:
	_base_dir = base_dir if not base_dir.is_empty() else DEFAULT_BASE_DIR


## Directory this store persists into.
func directory() -> String:
	return _base_dir.path_join(PLUGIN_ID)


## Absolute-ish path of the preferences file (still a user:// path).
func file_path() -> String:
	return directory().path_join(FILE_NAME)


## Every declared key, sorted. The MCP surface reports this back on an unknown
## key so an agent can self-correct instead of guessing.
func known_keys() -> Array:
	var keys: Array = key_registry().keys()
	keys.sort()
	return keys


func is_known(key: String) -> bool:
	return key_registry().has(key)


## The registry entry for a key (type/default/min/max/description), or {}.
func describe(key: String) -> Dictionary:
	var reg: Dictionary = key_registry()
	if not reg.has(key):
		return {}
	return (reg[key] as Dictionary).duplicate(true)


## True when this key has actually been STORED (as opposed to reading its
## default). See _values for why the distinction is load-bearing.
func has_stored(key: String) -> bool:
	_ensure_loaded()
	return _values.has(key)


## The effective value for a key: the stored one when present, else the
## registry default. Unknown key -> null (callers gate on is_known first).
##
## Re-validated ON READ, not merely on write: the file is plain JSON on disk and
## a hand-edit is a supported way to break it. Reading through the same validator
## the writer uses means a hand-edited 40 mm trace width comes back clamped
## rather than reaching the board.
func get_value(key: String) -> Variant:
	_ensure_loaded()
	var spec: Dictionary = describe(key)
	if spec.is_empty():
		return null
	if not _values.has(key):
		return spec["default"]
	var coerced: Dictionary = _coerce(key, _values[key])
	if not str(coerced.get("error", "")).is_empty():
		return spec["default"]
	return coerced["value"]


## Typed getter for float keys (the only kind so far). A non-float key returns
## the fallback rather than a garbled cast.
func get_float(key: String, fallback: float = 0.0) -> float:
	var spec: Dictionary = describe(key)
	if spec.is_empty() or int(spec.get("type", TYPE_NIL)) != TYPE_FLOAT:
		return fallback
	return float(get_value(key))


## Write a preference. Returns:
##   {ok: bool, error: String, value: <stored, post-clamp>, requested: <input>,
##    clamped: bool, changed: bool}
##
## CLAMPS rather than refuses an out-of-range value, and says so via `clamped` +
## the returned `value`. Deliberate, and deliberately DIFFERENT from
## pcb_data.set_trace_width, which REFUSES an out-of-range width: that setter
## writes COPPER (a 40 mm "trace" is a fabrication defect, so the honest answer
## is "no"), while this writes a STARTING POINT for a control that is itself
## range-bounded — clamping a preference into the range the spin box can express
## is the same thing the spin box would do to it, and refusing would leave the
## user with no stored preference at all. The reply always names the stored
## value, so a clamp is visible, never silent.
##
## An UNKNOWN KEY is refused (see key_registry). A no-op write journals nothing
## and does not touch the file — reported as changed:false, ok:true.
func set_value(key: String, value: Variant) -> Dictionary:
	_ensure_loaded()
	if not is_known(key):
		return {
			"ok": false,
			"error": "Unknown preference key \"%s\". Known keys: %s" % [key, ", ".join(known_keys())],
			"value": null, "requested": value, "clamped": false, "changed": false,
		}
	var coerced: Dictionary = _coerce(key, value)
	var refusal := str(coerced.get("error", ""))
	if not refusal.is_empty():
		return {"ok": false, "error": refusal, "value": null, "requested": value,
			"clamped": false, "changed": false}

	var stored: Variant = coerced["value"]
	var previous: Variant = get_value(key)
	var changed: bool = not _same(previous, stored) or not _values.has(key)
	if not changed:
		return {"ok": true, "error": "", "value": stored, "requested": value,
			"clamped": bool(coerced.get("clamped", false)), "changed": false}

	_values[key] = stored
	_save()
	return {"ok": true, "error": "", "value": stored, "requested": value,
		"clamped": bool(coerced.get("clamped", false)), "changed": true}


## Drop a stored preference, returning the key to "never chosen". Provided
## because "unset" is a real state the seeding order distinguishes; nothing in
## the UI calls it yet.
func clear_value(key: String) -> bool:
	_ensure_loaded()
	if not _values.has(key):
		return false
	_values.erase(key)
	_save()
	return true


## Every stored key/value plus the effective values, for MCP/debug read-out.
func snapshot() -> Dictionary:
	_ensure_loaded()
	var effective: Dictionary = {}
	for key in known_keys():
		effective[key] = get_value(key)
	return {"stored": _values.duplicate(true), "effective": effective}


## Re-read from disk on next access (used by probes and after an external edit).
func reload() -> void:
	_loaded = false
	_values.clear()


## The last warning, CONSUMED (subsequent calls return "" until a new one). A
## warning is a one-shot thing to show a human, not standing state.
func take_warning() -> String:
	var w := _warning
	_warning = ""
	return w


func has_warning() -> bool:
	return not _warning.is_empty()


# ── Internals ────────────────────────────────────────────────────────────────

## Validate + coerce a raw value against its registry entry.
## Returns {value, clamped, error}.
##
## Whole-number floats are accepted for int-typed keys: Godot's JSON.parse
## returns EVERY number as a float, so a stored `3` reads back as 3.0 and an
## int-typed key that demanded TYPE_INT would reject its own file (project
## memory: "GDScript JSON.parse returns all numbers as float"). No int key
## exists yet; the rule is written now so the first one does not trip on it.
func _coerce(key: String, raw: Variant) -> Dictionary:
	var spec: Dictionary = describe(key)
	if spec.is_empty():
		return {"value": null, "clamped": false, "error": "Unknown preference key \"%s\"." % key}
	var want: int = int(spec.get("type", TYPE_NIL))

	match want:
		TYPE_FLOAT:
			if not (raw is float or raw is int):
				return {"value": null, "clamped": false,
					"error": "Preference \"%s\" is a number in mm; got %s." % [key, type_string(typeof(raw))]}
			var f := float(raw)
			if not is_finite(f):
				return {"value": null, "clamped": false,
					"error": "Preference \"%s\" must be a finite number." % key}
			var lo := float(spec.get("min", -INF))
			var hi := float(spec.get("max", INF))
			var c := clampf(f, lo, hi)
			return {"value": c, "clamped": not is_equal_approx(c, f), "error": ""}
		TYPE_INT:
			if raw is int:
				return _clamp_int(key, int(raw), spec)
			if raw is float and is_equal_approx(float(raw), roundf(float(raw))):
				return _clamp_int(key, int(roundf(float(raw))), spec)
			return {"value": null, "clamped": false,
				"error": "Preference \"%s\" is a whole number; got %s." % [key, type_string(typeof(raw))]}
		TYPE_BOOL:
			if raw is bool:
				return {"value": bool(raw), "clamped": false, "error": ""}
			return {"value": null, "clamped": false,
				"error": "Preference \"%s\" is true/false; got %s." % [key, type_string(typeof(raw))]}
		TYPE_STRING:
			if raw is String or raw is StringName:
				var s := str(raw)
				var allowed: Array = spec.get("allowed", [])
				if not allowed.is_empty() and not (s in allowed):
					return {"value": null, "clamped": false,
						"error": "Preference \"%s\" must be one of: %s." % [key, ", ".join(allowed)]}
				return {"value": s, "clamped": false, "error": ""}
			return {"value": null, "clamped": false,
				"error": "Preference \"%s\" is text; got %s." % [key, type_string(typeof(raw))]}
		_:
			return {"value": null, "clamped": false,
				"error": "Preference \"%s\" has an unsupported declared type." % key}


func _clamp_int(key: String, v: int, spec: Dictionary) -> Dictionary:
	var lo: int = int(spec.get("min", -9223372036854775807))
	var hi: int = int(spec.get("max", 9223372036854775807))
	var c: int = clampi(v, lo, hi)
	return {"value": c, "clamped": c != v, "error": ""}


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return is_equal_approx(float(a), float(b))
	return a == b


func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_values = {}

	var path := file_path()
	if not FileAccess.file_exists(path):
		# The normal first-run state, NOT a problem: defaults, no warning.
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_warning = "PCB preferences could not be read (%s) — using defaults." % path
		return
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_warning = "PCB preferences file is not valid JSON — using defaults (%s)." % path
		return
	var root: Dictionary = parsed
	# Defensive .get() throughout: a file written by a future version, a
	# hand-edit, or a truncated write must degrade rather than crash.
	var version := int(root.get("version", 0))
	if version > SCHEMA_VERSION:
		_warning = ("PCB preferences were written by a newer version (%d) — reading what is "
			+ "recognisable and leaving the rest alone.") % version
	var values: Variant = root.get("values", {})
	if not (values is Dictionary):
		_warning = "PCB preferences file has no readable values block — using defaults (%s)." % path
		return

	var skipped: Array = []
	for key in (values as Dictionary):
		var k := str(key)
		if not is_known(k):
			# An unrecognised key is LEFT OUT of _values but NOT deleted from the
			# file: _save() rewrites only what this version knows, so a key from a
			# newer version would be lost. That is accepted (and warned about) —
			# the alternative, round-tripping data we cannot validate, is how a
			# store starts silently carrying garbage.
			skipped.append(k)
			continue
		var coerced: Dictionary = _coerce(k, (values as Dictionary)[key])
		if not str(coerced.get("error", "")).is_empty():
			skipped.append(k)
			continue
		_values[k] = coerced["value"]
	if not skipped.is_empty():
		_warning = "PCB preferences: ignored unreadable key(s) %s." % ", ".join(skipped)


func _save() -> void:
	var dir := directory()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			_warning = "PCB preferences could not be saved — %s is unwritable (%s)." % [
				dir, error_string(err)]
			return
	var file := FileAccess.open(file_path(), FileAccess.WRITE)
	if file == null:
		_warning = "PCB preferences could not be saved to %s (%s)." % [
			file_path(), error_string(FileAccess.get_open_error())]
		return
	file.store_string(JSON.stringify({
		"version": SCHEMA_VERSION,
		"values": _values,
	}, "\t"))
	file.close()
