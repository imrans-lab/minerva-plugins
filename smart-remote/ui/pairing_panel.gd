extends VBoxContainer
signal request(channel: String, payload: Dictionary, reply_id: String)
const CHANNEL := "minerva_smart_remote_pairing"
const LABELS := {
	"scanning": "Looking for the remote…",
	"connecting": "Connecting…",
	"authenticating": "Checking the setup code…",
	"scanning_wifi": "Scanning WiFi…",
	"awaiting_wifi": "Choose a network and enter its password.",
	"applying_wifi": "Applying WiFi settings…",
	"connecting_wifi": "Connecting WiFi…",
	"waiting_lan": "Pairing saved; waiting for the remote…",
	"confirmed": "Paired and connected.",
	"unconfirmed": "Pairing saved, not yet confirmed.",
	"cancelled": "Monitoring cancelled.",
	"failed": "Pairing stopped."
}
const ERRORS := {
	"input": "Enter the six-digit setup code shown on the remote.",
	"not_found": "No remote in setup was found. Hold SW2 while waking it, then retry.",
	"wrong_password": "Wrong WiFi password; enter a fresh password.",
	"network_not_found": "WiFi network not found; check its availability.",
	"input_timeout": "Timed out waiting for input. Start again.",
	"authentication": "Setup code was rejected; restart remote setup.",
	"transport": "Bluetooth connection lost; restart remote setup."
}
@onready var _mouse_status: Label = $MouseStatus
@onready var _code: LineEdit = $Code
@onready var _password: LineEdit = $Password
@onready var _networks: OptionButton = $Networks
@onready var _status: Label = $Status
@onready var _host: LineEdit = $Host
@onready var _start_button: Button = $Start
@onready var _apply_button: Button = $Apply
@onready var _cancel_button: Button = $Cancel
@onready var _poll_timer: Timer = $Poll
var _ipc: Node
var _sequence: int = 0
var _delivered: int = 0
var _operation: int = 0
var _pending: int = 0
var _closed: bool = false
var _default_host: String = ""
var _cancel_requested: bool = false
var _port: int = 47821

func _ready() -> void:
	_mouse_status.visible = OS.get_name() in ["Linux", "Windows"]
	_start_button.pressed.connect(_start)
	_code.text_submitted.connect(func(_text: String) -> void: _start())
	_apply_button.pressed.connect(_apply)
	_cancel_button.pressed.connect(_cancel)
	_poll_timer.timeout.connect(_poll)

func _on_panel_loaded(_ctx: Dictionary) -> void:
	_ipc = get_node_or_null("_MinervaIPC")
	_poll_timer.start()
	_poll()

func _integer(value: Variant, maximum: int) -> int:
	if value is int:
		var integer: int = value
		return integer if integer >= 1 and integer <= maximum else 0
	if value is float:
		var number: float = value
		if is_finite(number) and number == floor(number) and number >= 1.0 and number <= float(maximum):
			return int(number)
	return 0

func _call(arguments: Dictionary) -> Dictionary:
	if _ipc == null or _closed:
		arguments.clear()
		return {}
	_pending += 1
	_sequence += 1
	var ticket: int = _sequence
	var reply_id := "remote-%d-%d" % [get_instance_id(), ticket]
	request.emit(CHANNEL, arguments, reply_id)
	var reply: Variant = await _ipc.call("await_reply", reply_id, 10000)
	arguments.clear()
	_pending -= 1
	if _closed or ticket < _delivered:
		return {}
	_delivered = ticket
	if not reply is Dictionary:
		_status.text = "Pairing request failed. Reopen to see progress or retry."
		return {}
	var response: Dictionary = reply
	if response.get("success", false) != true:
		_status.text = "Pairing request failed. Reopen to see progress or retry."
		return {}
	var body: Variant = response.get("result", {})
	if body is Dictionary:
		var result: Dictionary = body
		return result
	return {}

func _start() -> void:
	if _closed or _start_button.disabled:
		return
	if _code.text.length() != 6:
		_status.text = str(ERRORS.input)
		return
	for index: int in _code.text.length():
		var digit: int = _code.text.unicode_at(index)
		if digit < 48 or digit > 57:
			_status.text = str(ERRORS.input)
			return
	var arguments := {"action": "start", "code": _code.text}
	_code.clear()
	_networks.clear()
	_operation = 0
	_cancel_requested = false
	_start_button.disabled = true
	_cancel_button.disabled = false
	_render(await _call(arguments))

func _apply() -> void:
	if _networks.selected < 0:
		_status.text = "Choose a network first."
		return
	var arguments := {"action": "apply", "operation_id": _operation,
		"ssid": _networks.get_item_metadata(_networks.selected), "password": _password.text,
		"host": _host.text, "port": _port}
	_password.clear()
	_apply_button.disabled = true
	_render(await _call(arguments))

func _cancel() -> void:
	_code.clear()
	_password.clear()
	_cancel_requested = _operation == 0
	if _operation != 0:
		_render(await _call({"action": "cancel", "operation_id": _operation}))

func _poll() -> void:
	if _pending > 0 or _closed:
		return
	var body: Dictionary = await _call({"action": "describe"})
	if body.is_empty() or _pending > 0 or _closed:
		return
	if _mouse_status.visible:
		var paired: Variant = body.get("mouse_paired")
		_mouse_status.text = "Mouse paired: %s" % ("yes" if paired else "no") if paired is bool else "Mouse pairing status unavailable."
	if body.has("port"):
		var port: int = _integer(body.get("port"), 65535)
		if port == 0:
			_status.text = "Invalid listener port."
			return
		_port = port
		if _host.editable and _host.text == _default_host:
			_default_host = str(body.host) if body.get("host") != null else ""
			_host.text = _default_host
		_host.visible = _host.text.is_empty() or _host.text != _default_host
	var operation: Variant = body.get("operation", {})
	if operation is Dictionary:
		var current: Dictionary = operation
		if current.is_empty():
			_start_button.disabled = false
			_cancel_button.disabled = true
		_render(current)

func _render(body: Dictionary) -> void:
	if body.is_empty():
		return
	var number: int = _integer(body.get("operation_id"), 9007199254740991)
	if number == 0:
		_status.text = "Invalid pairing operation."
		return
	if number < _operation:
		return
	_operation = number
	var value: Variant = body.get("pairing", {})
	if not value is Dictionary:
		_status.text = "Invalid pairing status."
		return
	var details: Dictionary = value
	var stage_value: Variant = details.get("stage", "")
	if stage_value is String and stage_value.is_empty():
		stage_value = body.get("stage", "")
	if not stage_value is String or not LABELS.has(stage_value):
		_status.text = "Invalid pairing stage."
		_start_button.disabled = true
		_apply_button.disabled = true
		return
	var stage: String = stage_value
	_status.text = str(LABELS.get(stage, stage.replace("_", " ")))
	var storage: String = str(details.get("persistence", "none"))
	if storage == "pending":
		_status.text = "Saving pairing; please wait…"
	elif storage == "stored" and stage != "confirmed":
		_status.text = "Pairing saved, not yet confirmed."
	elif details.get("save_possible", false) == true and stage in ["failed", "cancelled"]:
		_status.text += " The remote may have saved settings; confirmation is unknown."
	if details.get("confirmation_pending", false) == true:
		_status.text += " Checking saved state…"
	var error: Variant = body.get("error")
	if error == null:
		error = details.get("error")
	if error != null:
		_status.text += " " + str(ERRORS.get(str(error), str(error).replace("_", " ")))
	var waiting: bool = stage == "awaiting_wifi"
	_apply_button.disabled = not waiting
	_start_button.disabled = storage == "pending" or stage in [
		"scanning", "connecting", "authenticating", "scanning_wifi", "awaiting_wifi",
		"applying_wifi", "connecting_wifi", "waiting_lan"]
	_cancel_button.disabled = _operation == 0
	_host.editable = details.get("device_id") == null
	if details.get("host") != null:
		var port: int = _integer(details.get("port"), 65535)
		if port == 0:
			_status.text = "Invalid staged port."
			_apply_button.disabled = true
			return
		_host.text = str(details.host)
		_port = port
	var networks: Variant = details.get("networks", [])
	if not networks is Array:
		_status.text = "Invalid WiFi network list."
		_apply_button.disabled = true
		return
	if waiting and _networks.item_count == 0:
		for entry: Variant in networks:
			if not entry is Dictionary or not entry.get("label") is String or not entry.get("ssid") is String:
				_status.text = "Invalid WiFi network."
				_apply_button.disabled = true
				return
		for entry: Dictionary in networks:
			_networks.add_item(entry.label)
			_networks.set_item_metadata(_networks.item_count - 1, entry.ssid)
	if _cancel_requested:
		_cancel()

func _on_panel_unload() -> void:
	_closed = true
	_poll_timer.stop()
	_code.clear()
	_password.clear()

func _on_panel_save_request(_ctx: Dictionary) -> Dictionary:
	return {}

func _on_panel_load_request(_document: Variant) -> void:
	_code.clear()
	_password.clear()
