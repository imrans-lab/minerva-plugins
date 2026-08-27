extends SceneTree
## Remora 01a03820df78 (sev 3) — a transient status message wiped early.
##
## Run (via a Minerva checkout as the Godot host — NEVER the live checkout):
##   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
##
## THE DEFECT. _show_transient_status armed a fresh 2s SceneTreeTimer per
## message and never cancelled the one already pending, so two messages less
## than 2s apart left TWO clears queued and the FIRST — armed by a message
## already gone from the line — wiped the SECOND. A message arriving at t=1.9s
## was visible for 0.1s. The user's report: "the status line blinks out
## immediately when two things happen at once".
##
## THE ORACLE the item gives, section 1: emit two messages T < 2s apart; the
## second is still displayed at first_time + 2.0 + epsilon. That is measured
## here in REAL TIME (the defect is about a clock, and a test that only drove
## the token would pass against a fix that armed the token but not the timer).
## Section 2 drives the supersede seam directly so the mechanism is pinned too,
## and section 3 holds the HELD LEADS out of it — those are conditions, not
## messages, and no part of this change may make them blink.
##
## FAILS AGAINST OLD: section 1 reads the label at t=2.2s and finds the first
## message's uncancelled clear has already reverted the line; section 2's
## _clear_transient_status does not exist on the base commit and is asserted
## present before it is called, so it reds rather than crashing.
##
## REUSE SCAN: panel mount + check helpers follow test_direct_copper_verbs.gd.

const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

## The window the panel promises a transient message (PCBPanel's own
## TRANSIENT_STATUS_SECONDS). Spelled out here rather than read off the panel:
## it is the number the bug report is written against, so this file is where a
## change to it has to be noticed.
const WINDOW_SECONDS := 2.0
## When the SECOND message is emitted, well inside the first one's window.
const SECOND_MESSAGE_AT := 1.2
## How far past the FIRST message's deadline the line is read. The whole defect
## lives in this gap: the old first timer fires at 2.0, this reads at 2.2.
const READ_AT := 2.2

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== transient status (remora 01a03820df78) ===\n")
	await _run_second_message_survives_the_first_deadline()
	await _run_supersede_seam()
	await _run_held_leads_are_untouched()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
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


class FakeEditor extends RefCounted:
	var tab_title: String = "StatusProbe"
	var associated_object: Variant = ""


## A panel MOUNTED IN THE REAL TREE. _show_transient_status needs a tree to arm
## a timer at all, and _update_status needs a real canvas and a real board or it
## returns without writing — against which the OLD code's stray clear would have
## no visible effect and this suite would pass a broken panel.
func _mount() -> Variant:
	var panel: Variant = load(PCB_PANEL_SCRIPT_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(1100, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	for _i in range(6):
		await process_frame
	return panel


func _unmount(panel: Variant) -> void:
	if panel != null and panel is Node:
		(panel as Node).queue_free()
	await process_frame


func _status_text(panel) -> String:
	return str(panel._status_label.text) if panel._status_label != null else ""


# ── 1. THE ORACLE, in real time ──────────────────────────────────────────────

func _run_second_message_survives_the_first_deadline() -> void:
	print("\n-- 1. the second message outlives the first message's deadline --")
	var panel = await _mount()
	check("the panel has a status line to write to", panel._status_label != null)

	panel._show_transient_status("FIRST MESSAGE")
	check("O1: the first message is on the line",
		_status_text(panel).contains("FIRST MESSAGE"))

	await create_timer(SECOND_MESSAGE_AT).timeout
	panel._show_transient_status("SECOND MESSAGE")
	check("O1: the second message replaced it",
		_status_text(panel).contains("SECOND MESSAGE"))
	check("O1: and the first is gone", not _status_text(panel).contains("FIRST MESSAGE"))

	# t = READ_AT, past the FIRST message's 2.0s deadline and short of the
	# second's (1.2 + 2.0 = 3.2). This is the assertion the bug is about.
	await create_timer(READ_AT - SECOND_MESSAGE_AT).timeout
	check("O1: at first_time + %.1fs the SECOND message is still displayed" % READ_AT,
		_status_text(panel).contains("SECOND MESSAGE"))

	# ...and it does still clear. A fix that simply stopped clearing would pass
	# every check above.
	await create_timer((SECOND_MESSAGE_AT + WINDOW_SECONDS + 0.3) - READ_AT).timeout
	check("O1: past its OWN deadline the second message clears",
		not _status_text(panel).contains("SECOND MESSAGE"))
	check("O1: and the steady-state readout is back",
		_status_text(panel).contains("parts"))
	await _unmount(panel)


# ── 2. THE SUPERSEDE SEAM ────────────────────────────────────────────────────
#
# A SceneTreeTimer cannot be cancelled, so the pending clear is identified by a
# token and a superseded one does nothing. Driving that directly pins the
# MECHANISM: section 1 could be satisfied by a longer window, this cannot.

func _run_supersede_seam() -> void:
	print("\n-- 2. a superseded clear does nothing --")
	var panel = await _mount()
	check("O2: the panel has a supersede seam at all",
		panel.has_method("_clear_transient_status"))
	if not panel.has_method("_clear_transient_status"):
		await _unmount(panel)
		return

	panel._show_transient_status("MESSAGE ONE")
	var first_token: int = int(panel._transient_status_token)
	panel._show_transient_status("MESSAGE TWO")
	var second_token: int = int(panel._transient_status_token)
	check("O2: the second message took a NEW token", second_token != first_token)

	panel._clear_transient_status(first_token)
	check("O2: firing the FIRST message's clear leaves the second standing",
		_status_text(panel).contains("MESSAGE TWO"))

	panel._clear_transient_status(second_token)
	check("O2: firing the CURRENT clear reverts the line",
		not _status_text(panel).contains("MESSAGE TWO"))
	check("O2: to the steady-state readout", _status_text(panel).contains("parts"))

	# The clear is idempotent: a timer that fires after its own clear already
	# ran must not re-revert a message written since.
	panel._show_transient_status("MESSAGE THREE")
	panel._clear_transient_status(second_token)
	check("O2: a clear fired twice cannot reach a later message",
		_status_text(panel).contains("MESSAGE THREE"))
	await _unmount(panel)


# ── 3. THE HELD LEADS ARE NOT MESSAGES ───────────────────────────────────────
#
# _status_lead's parts (an indeterminate load check, an overlay that failed to
# fetch, a live bus refusal) are CONDITIONS. They ride every write through
# _set_status and must survive both a transient message and its clear — that is
# what "held" means, and it is the property most easily broken by touching the
# transient path.

func _run_held_leads_are_untouched() -> void:
	print("\n-- 3. the held leads survive a message and its clear --")
	var panel = await _mount()
	# The seam this section drives is the one section 2 asserts into existence;
	# without it there is nothing here to measure, and calling it would abort the
	# suite instead of failing a check.
	if not panel.has_method("_clear_transient_status"):
		check("O3: skipped — no supersede seam (section 2 already reds on this)", false)
		await _unmount(panel)
		return
	var lead := "[UNMEASURED] "
	panel._load_check_lead = lead
	check("O3: the lead leads the line it is set on",
		panel._status_lead().begins_with(lead))

	panel._show_transient_status("A TRANSIENT THING")
	check("O3: a transient message does not displace it",
		_status_text(panel).begins_with(lead)
		and _status_text(panel).contains("A TRANSIENT THING"))

	panel._clear_transient_status(int(panel._transient_status_token))
	check("O3: nor does the clear that removes the message",
		_status_text(panel).begins_with(lead))
	check("O3: the message itself is gone, though",
		not _status_text(panel).contains("A TRANSIENT THING"))
	await _unmount(panel)
