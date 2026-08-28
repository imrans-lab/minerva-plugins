extends RefCounted
## SNAP-PREFERENCE FIXTURE for the gd suites that exercise the Options snaps.
##
## NOT a suite: the runner's glob is `test_*.gd` (run-gd-tests.sh), so this file
## is invisible to it and needs no EXPECTED_SUITES row. It is preloaded by the
## suites that need it.
##
## WHY IT EXISTS. `PcbOptionsPrefs.shared()` is a process-wide store backed by a
## REAL file under `user://plugins/data/pcb/` — the developer's own preferences
## on the machine running the suite. A suite that reads the live snap toggles
## therefore inherits whatever that developer last clicked: a stored
## `snap_angle=false` turns the angle-snap assertions red for a reason that has
## nothing to do with the code under test, and a suite that WRITES one leaves it
## changed afterwards.
##
## `reset()` returns the three snap keys to "never chosen" (so every read sees
## the registry default, `true`) and hands back what was there; `restore()` puts
## exactly that back, including the difference between an unstored key and one
## stored at the default value — a distinction the seeding order depends on.
##
## Off-tree: preloaded through the same `res://../../minerva-plugins/...` path
## every pcb gd suite uses for plugin sources (the suites run under
## `godot --path <minerva>/src`).

const _PcbPrefs := preload("res://../../minerva-plugins/pcb/ui/model/pcb_prefs.gd")

## The three per-user snap toggles, and nothing else: a fixture that reset the
## whole store would also wipe `trace_width_mm`, which other suites pin.
const SNAP_KEYS: Array[String] = [
	_PcbPrefs.KEY_SNAP_GRID, _PcbPrefs.KEY_SNAP_LAND, _PcbPrefs.KEY_SNAP_ANGLE]


## Clear the three snap keys and return what they held, for `restore()`.
## A key that was never stored is recorded as `null`, which is what makes the
## restore able to put "unstored" back rather than writing the default.
static func reset() -> Dictionary:
	var prefs = _PcbPrefs.shared()
	var saved: Dictionary = {}
	for key in SNAP_KEYS:
		saved[key] = prefs.get_value(key) if prefs.has_stored(key) else null
		prefs.clear_value(key)
	return saved


## Put back exactly what `reset()` found.
static func restore(saved: Dictionary) -> void:
	if saved.is_empty():
		# reset() never ran (an early exit before the fixture was taken).
		# Touching nothing is the honest answer; clearing three keys nobody
		# saved would be the fixture causing the damage it exists to prevent.
		return
	var prefs = _PcbPrefs.shared()
	for key in SNAP_KEYS:
		var previous: Variant = saved.get(key, null)
		if previous == null:
			prefs.clear_value(key)
		else:
			prefs.set_value(key, bool(previous))
