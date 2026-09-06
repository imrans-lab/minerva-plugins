extends PanelContainer
## The one thing the CAD panel says out loud about an evaluation: a reference
## mesh that would not load, and the interference the check found. Attached to
## the EvalBanner node of CADPanel.tscn.
##
## Three rules, all of them about WHICH evaluation the reader is looking at:
##
##   STAMPED    a report names the evaluation it came from, so the report
##              standing on screen can be told from the one before it. Without
##              that a reader has no way to know whether the fault they just
##              edited away is still being reported.
##   REPLACED   a settled evaluation either replaces the report or clears it.
##              Nothing survives an evaluation that had nothing to say.
##   DISMISSED PER REPORT
##              the close button hides THIS report, keyed to its evaluation, so
##              a later evaluation's report shows itself rather than inheriting
##              the dismissal. Re-showing the SAME report — the mesh-import
##              notice is re-asserted after every evaluation — stays hidden.
##
## The banner sits at the BOTTOM of the panel: every interactive control the
## layouts own (the per-pane projection rows, the sidebar buttons and tree) is
## at the top, so a report can never cover one. It is mouse-transparent apart
## from its close button, so the pane it lies over still orbits under it.
##
## No class_name: off-tree plugin scripts cannot use class_name.

@onready var _stamp_label: Label = $Body/Header/Stamp
@onready var _close_button: Button = $Body/Header/Close
@onready var _message_label: Label = $Body/Message

## Identity of the report on screen, and of the one the reader closed. Equal
## means the reader has already seen and dismissed exactly this report.
var _key: String = ""
var _dismissed_key: String = ""
## What is being shown, as the MCP reader gets it.
var _stamp: String = ""
var _message: String = ""


func _ready() -> void:
	visible = false
	_close_button.pressed.connect(dismiss)


## Report what a settled evaluation found. `last_eval` is the panel's own
## result dictionary: its request id and timestamp are the report's identity,
## which is what makes a dismissal apply to one report rather than to the
## banner itself.
func show_for_eval(message: String, last_eval: Dictionary) -> void:
	var when: float = float(last_eval.get("ts", 0.0))
	_show(message,
		"%s#%.3f" % [str(last_eval.get("request_id", "")), when],
		clock_text(when))


## Report something that is not an evaluation's verdict — the mesh-import
## notice, which is re-asserted after every evaluation until the document has a
## file path. Its own text is its identity, so dismissing it dismisses it for
## as long as it says the same thing.
func show_notice(message: String) -> void:
	_show(message, "notice:" + message, "")


func _show(message: String, key: String, stamp: String) -> void:
	_message = message
	_key = key
	_stamp = stamp
	if _message_label != null:
		_message_label.text = message
	if _stamp_label != null:
		_stamp_label.text = "Evaluation %s" % stamp if not stamp.is_empty() \
			else "Notice"
	visible = key != _dismissed_key


## No report. The dismissal is forgotten with it: a second report about an
## evaluation that is already over cannot arrive, so a kept key would only
## outlive its use.
func clear() -> void:
	_message = ""
	_key = ""
	_stamp = ""
	if _message_label != null:
		_message_label.text = ""
	visible = false
	_dismissed_key = ""


## Hide the report on screen. A later evaluation's report carries a different
## key and shows itself.
func dismiss() -> void:
	if _key.is_empty():
		return
	_dismissed_key = _key
	visible = false


## What the banner is showing, for last_eval on the MCP wire: the owner is
## GUI-only and an agent is not, and they must read the same verdict.
func state_for_mcp() -> Dictionary:
	return {
		"visible": visible,
		"dismissed": not _key.is_empty() and _key == _dismissed_key,
		# What a reader tells two reports apart by: the wall clock for the
		# owner, the evaluation's own id for an agent.
		"stamp": _stamp,
		"eval": _key,
		"text": _message,
	}


## Wall-clock time of a unix timestamp, which is how a reader tells one
## evaluation from the one before it. Local, because the reader is looking at
## a clock on the same machine.
static func clock_text(unix_seconds: float) -> String:
	if unix_seconds <= 0.0:
		return ""
	var bias_seconds: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_time_string_from_unix_time(int(unix_seconds) + bias_seconds)
