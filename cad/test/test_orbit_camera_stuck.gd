extends SceneTree
## Regression test — the CAD orbit camera must not stay latched in orbit after
## a lost middle-button release.
##
## Tracks docket: RCA 019e4ca28aaf (CAD camera stuck in orbit) / W1 019e4ca3494f.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script ~/github/plugins/cad/test/test_orbit_camera_stuck.gd
##
## FAIL-FIRST: the "lost release" scenario FAILS on the current orbit_camera.gd
## — handle_pointer_input keeps _dragging_orbit latched and orbits on every
## later motion — and PASSES once the W2 fix reconciles the latch against
## InputEventMouseMotion.button_mask.
##
## orbit_camera.gd is a self-contained Camera3D (no Minerva deps); loaded by
## absolute path so the test can run under Minerva's project, mirroring the
## presentation plugin's test convention.

var OrbitCameraScript: Script = load(
	OS.get_environment("HOME").path_join("github/plugins/cad/ui/scripts/orbit_camera.gd"))

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CAD Orbit Camera Stuck-Latch Regression Test (RCA 019e4ca28aaf) ===\n")
	if OrbitCameraScript == null:
		printerr("FAIL: could not load orbit_camera.gd")
		quit(1)
		return
	_run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d — orbit-camera stale-latch repro is RED (expected pre-W2-fix)" % _fail)
	quit(1 if _fail > 0 else 0)


## Build a middle-mouse button event.
func _mb(pressed: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_MIDDLE
	e.pressed = pressed
	e.position = Vector2(100, 100)
	return e


## Build a mouse-motion event. `mask` is the live button state — 0 means no
## button is currently held (what the OS reports after a release we never saw).
func _motion(rel: Vector2, mask: int) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.relative = rel
	e.button_mask = mask
	e.position = Vector2(100, 100)
	return e


func _run() -> void:
	# --- Control 1: a normal middle-drag orbits the camera ---------------------
	var cam = OrbitCameraScript.new()
	var yaw0: float = cam.get_yaw()
	cam.handle_pointer_input(_mb(true))
	cam.handle_pointer_input(_motion(Vector2(50, 0), MOUSE_BUTTON_MASK_MIDDLE))
	check("control: a normal middle-drag orbits (yaw changes)",
			not is_equal_approx(cam.get_yaw(), yaw0),
			"yaw stayed at %f" % cam.get_yaw())
	cam.free()

	# --- Control 2: a RECEIVED release stops the orbit -------------------------
	cam = OrbitCameraScript.new()
	cam.handle_pointer_input(_mb(true))
	cam.handle_pointer_input(_motion(Vector2(20, 0), MOUSE_BUTTON_MASK_MIDDLE))
	cam.handle_pointer_input(_mb(false))  # middle-up — delivered normally
	var yaw_after_release: float = cam.get_yaw()
	cam.handle_pointer_input(_motion(Vector2(50, 0), 0))
	check("control: after a received release, later motion does not orbit",
			is_equal_approx(cam.get_yaw(), yaw_after_release),
			"yaw drifted %f -> %f" % [yaw_after_release, cam.get_yaw()])
	cam.free()

	# --- THE REPRO: a LOST release must not strand the camera in orbit ---------
	cam = OrbitCameraScript.new()
	cam.handle_pointer_input(_mb(true))                                  # orbit starts
	cam.handle_pointer_input(_motion(Vector2(20, 0), MOUSE_BUTTON_MASK_MIDDLE))
	var yaw_mid: float = cam.get_yaw()
	# The middle-button RELEASE happened while the cursor was outside the CAD
	# SubViewport, so orbit_camera._input never received it — simulate by NOT
	# feeding the button-up. The user then moves the mouse back over the view
	# with NO button held (button_mask == 0):
	cam.handle_pointer_input(_motion(Vector2(80, 40), 0))
	check("REPRO: motion after a lost release must NOT orbit (yaw frozen)",
			is_equal_approx(cam.get_yaw(), yaw_mid),
			"STUCK IN ORBIT — yaw moved %f -> %f with no button held"
				% [yaw_mid, cam.get_yaw()])
	cam.free()


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
