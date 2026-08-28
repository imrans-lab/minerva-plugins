extends RefCounted
## PcbTraceAngles — THE one definition of `design_rules.allowed_trace_angles_deg`,
## shared by the Trace tool's snap and the worker's gc12 direction check.
##
## ── THE FRAME, AND WHY IT HAS TO BE WRITTEN DOWN ─────────────────────────────
## An entry is a DIRECTION IN THE BOARD'S OWN MILLIMETRE FRAME, measured from +X
## toward +Y, in degrees. That frame is y-DOWN — the same frame every `x_mm` /
## `y_mm` in the board YAML uses and the same one the canvas paints — so on
## screen the angle sweeps CLOCKWISE and `45` names the down-and-right diagonal.
##
## A direction and its REVERSE are one constraint (0 and 180 are the same rule
## for a horizontal run), so every entry folds into [0, 180) and a segment's own
## heading folds the same way before the two are compared. Both halves of that
## fold are here, in one place, because a snap that folded differently from the
## check would draw copper the check then flags.
##
## Octilinear {0, 45, 90, 135} and Manhattan {0, 90} are closed under the y-flip,
## so for them the frame is invisible; an ASYMMETRIC set (a board declaring only
## 30, say) is read in the board frame, and this note is the reason a reader can
## tell which way it leans.
##
## ── THE CONFORMANCE MEASURE ──────────────────────────────────────────────────
## `deviation()` is a PERPENDICULAR DISTANCE, not an angle, matching
## drc_geometric._check_gc12_trace_direction byte for byte: |d x u|, with u the
## unit vector along the allowed direction. An angular tolerance is
## scale-dependent (the same coordinate quantization is 0.0036 deg across a
## 1.6 mm run and 0.057 deg across a 0.1 mm one); a distance is the same rule at
## every length. The snap below picks the allowed direction that MINIMISES this
## quantity, so the direction the tool draws in is by construction the one the
## check would name as nearest.
##
## Off-tree plugin: NO class_name; reached by relative preload.

## The three modes the Options menu offers. `custom` is not offered as a choice —
## it is what a board that declares some other set reads back as, so a menu that
## cannot express the board's rule says so instead of silently misreporting it.
const MODE_MANHATTAN := "manhattan"
const MODE_OCTILINEAR := "octilinear"
const MODE_FREE := "free"
const MODE_CUSTOM := "custom"

## Human-facing labels, one per mode, so the menu and the MCP reply agree.
const MODE_LABELS := {
	MODE_MANHATTAN: "Manhattan (0/90)",
	MODE_OCTILINEAR: "Octilinear (0/45/90/135)",
	MODE_FREE: "Free (any angle)",
	MODE_CUSTOM: "Custom",
}

const MANHATTAN_ANGLES: Array[float] = [0.0, 90.0]
const OCTILINEAR_ANGLES: Array[float] = [0.0, 45.0, 90.0, 135.0]

## The mode a board that has never been told anything gets. Octilinear is the
## default because it is the loosest set that still keeps a hand-drawn run on a
## direction a fab and a reviewer can read at a glance.
const DEFAULT_MODE := MODE_OCTILINEAR

## The named modes, in menu order. `custom` is deliberately absent (see above).
const OFFERED_MODES: Array[String] = [MODE_MANHATTAN, MODE_OCTILINEAR, MODE_FREE]

## Perpendicular tolerance, mm, for "this segment already runs in an allowed
## direction". THE SAME NUMBER as drc_geometric.GC12_AXIS_TOLERANCE_MM — a
## segment the panel calls conforming and the worker flags would be the exact
## disagreement this module exists to prevent.
const CONFORM_TOLERANCE_MM := 1e-3


## The angle set for a named mode. Free is the EMPTY set, which is what "no
## direction constraint" is spelled as everywhere: an absent
## `allowed_trace_angles_deg`, an empty tuple in ResolvedDesignRules, and a
## gc12 that reports itself not evaluated.
static func angles_for_mode(mode: String) -> Array[float]:
	match mode:
		MODE_MANHATTAN:
			return MANHATTAN_ANGLES.duplicate()
		MODE_OCTILINEAR:
			return OCTILINEAR_ANGLES.duplicate()
		_:
			return [] as Array[float]


## The mode a stored angle set reads back as. An empty set is Free; a set that
## matches neither named set is MODE_CUSTOM — never coerced to the nearest
## named one, because reporting a board's rule as something it is not is how a
## menu and a board silently disagree.
static func mode_for_angles(angles: Array) -> String:
	var folded := normalise(angles)
	if folded.is_empty():
		return MODE_FREE
	if folded == MANHATTAN_ANGLES:
		return MODE_MANHATTAN
	if folded == OCTILINEAR_ANGLES:
		return MODE_OCTILINEAR
	return MODE_CUSTOM


## Fold an authored list into the canonical form: every entry into [0, 180),
## de-duplicated, ascending. Non-numeric and non-finite entries are DROPPED here
## — `validate()` is the surface that refuses them by name; this is the reader
## used on already-stored state, where the honest answer to a corrupt entry is
## to ignore it rather than to leave the tool with no rule at all.
static func normalise(angles) -> Array[float]:
	var out: Array[float] = []
	if not (angles is Array or angles is PackedFloat32Array or angles is PackedFloat64Array):
		return out
	for raw in angles:
		if raw is bool or not (raw is float or raw is int):
			continue
		var value := float(raw)
		if not is_finite(value):
			continue
		var folded := fposmod(value, 180.0)
		# fposmod can return exactly 180.0 for a value a hair under it after
		# rounding; 180 and 0 are the same direction, so it belongs at 0.
		if is_equal_approx(folded, 180.0):
			folded = 0.0
		var seen := false
		for kept in out:
			if is_equal_approx(kept, folded):
				seen = true
				break
		if not seen:
			out.append(folded)
	out.sort()
	return out


## Validate an authored list on the WRITE path. Returns {ok, angles, error}.
##
## Refuses rather than silently dropping, and refuses the same three things the
## worker's compile_board._allowed_trace_angles refuses (a non-list, a
## non-number entry, a non-finite entry) so a set the panel accepts is a set the
## board will compile. An EMPTY list is accepted here and means Free — the
## worker refuses `[]` in YAML because an author who wrote an empty list asked
## for a constraint and got none, but the panel's Free mode REMOVES the key
## rather than writing an empty one.
static func validate(angles) -> Dictionary:
	if not (angles is Array):
		return {"ok": false, "angles": [] as Array[float],
			"error": "allowed_trace_angles_deg must be a list of directions in degrees."}
	for raw in angles:
		if raw is bool or not (raw is float or raw is int):
			return {"ok": false, "angles": [] as Array[float],
				"error": "allowed_trace_angles_deg entries must be numbers in degrees; got %s."
					% type_string(typeof(raw))}
		if not is_finite(float(raw)):
			return {"ok": false, "angles": [] as Array[float],
				"error": "allowed_trace_angles_deg entries must be finite numbers."}
	return {"ok": true, "angles": normalise(angles), "error": ""}


## The perpendicular deviation, in mm, of the vector `delta` from the allowed
## direction `angle_deg`. |d x u| — the quantity gc12 measures, in the same
## frame and with the same sign convention (none: it is an absolute value).
static func deviation(delta: Vector2, angle_deg: float) -> float:
	var radians := deg_to_rad(angle_deg)
	return absf(delta.x * sin(radians) - delta.y * cos(radians))


## The allowed direction `delta` is closest to, as {angle, deviation}. Ties go
## to the lowest angle, because `normalise` sorts and this walks in order — a
## deterministic pick, so the preview and the commit cannot choose differently.
## An empty set returns {angle: 0.0, deviation: 0.0, matched: false}.
static func nearest(delta: Vector2, angles: Array) -> Dictionary:
	var folded := normalise(angles)
	if folded.is_empty():
		return {"angle": 0.0, "deviation": 0.0, "matched": false}
	var best_angle := folded[0]
	var best_dev := deviation(delta, folded[0])
	for i in range(1, folded.size()):
		var dev := deviation(delta, folded[i])
		if dev < best_dev:
			best_dev = dev
			best_angle = folded[i]
	return {"angle": best_angle, "deviation": best_dev, "matched": true}


## Does a segment already run in an allowed direction? The panel-side twin of
## gc12's verdict, on the same tolerance — used to tell a human that the run
## they drew is legal without asking the worker.
static func conforms(from: Vector2, to: Vector2, angles: Array,
		tolerance_mm: float = CONFORM_TOLERANCE_MM) -> bool:
	var folded := normalise(angles)
	if folded.is_empty():
		return true
	var delta := to - from
	if delta.length() <= tolerance_mm:
		# Shorter than the tolerance in every direction at once, so it has no
		# direction to be wrong about — gc12's own rule for a sub-tolerance run.
		return true
	return nearest(delta, folded)["deviation"] <= tolerance_mm


## The heading of a segment, folded the way the allowed set is: degrees in
## [0, 180) measured from +X toward +Y in the board's y-down frame. The number a
## finding reports and the number a human reads off the status line.
static func heading_deg(from: Vector2, to: Vector2) -> float:
	var delta := to - from
	return fposmod(rad_to_deg(atan2(delta.y, delta.x)), 180.0)


## SNAP: where `target` lands when the run leaving `anchor` may only travel in
## one of `angles`. The point is the projection of `target` onto the nearest
## allowed line through `anchor` — the line, not the ray, because a direction
## stands for its own reverse, so pulling backwards is legal and is what a user
## dragging up-left from the anchor means.
##
## An empty set (Free) returns `target` untouched.
static func snap_point(anchor: Vector2, target: Vector2, angles: Array) -> Vector2:
	var folded := normalise(angles)
	if folded.is_empty():
		return target
	var delta := target - anchor
	if delta.length() <= CONFORM_TOLERANCE_MM:
		return target
	var pick := nearest(delta, folded)
	var radians := deg_to_rad(float(pick["angle"]))
	var unit := Vector2(cos(radians), sin(radians))
	return anchor + unit * delta.dot(unit)


## GRID, APPLIED LAST AND ALONG THE RUN. Quantising x and y independently would
## push the endpoint off the allowed line, which is the whole point of doing the
## angle first — so the DISTANCE along the direction is what gets quantised.
##
## The step is `pitch / max(|ux|, |uy|)`, which makes the run's DOMINANT axis
## land on grid multiples: `pitch` for 0 and 90 (identical to plain grid snap),
## `pitch * sqrt(2)` for 45 and 135 (so both axes move by whole pitches at once),
## and the dominant axis for any other declared direction. `snapped` stays on the
## line by construction.
static func snap_along(anchor: Vector2, snapped: Vector2, pitch_mm: float) -> Vector2:
	if pitch_mm <= 0.0:
		return snapped
	var delta := snapped - anchor
	var length := delta.length()
	if length <= CONFORM_TOLERANCE_MM:
		return snapped
	var unit := delta / length
	var dominant := maxf(absf(unit.x), absf(unit.y))
	if dominant <= 0.0:
		return snapped
	var step := pitch_mm / dominant
	return anchor + unit * (roundf(length / step) * step)
