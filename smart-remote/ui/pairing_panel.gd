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
	"wrong_password": "Wrong WiFi password; enter a fresh password.",
	"network_not_found": "WiFi network not found; check its availability.",
	"input_timeout": "Timed out waiting for input. Start again.",
	"authentication": "Setup code was rejected; restart remote setup.",
	"transport": "Bluetooth connection lost; restart remote setup."
}
@onready var _code: LineEdit = $Code
@onready var _password: LineEdit = $Password
@onready var _networks: OptionButton = $Networks
@onready var _status: Label = $Status
@onready var _name: LineEdit = $Name
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
var _defaults_initialized: bool = false
var _cancel_requested: bool = false
var _port: int = 47821

func _ready() -> void:
	_start_button.pressed.connect(_start)
	_apply_button.pressed.connect(_apply)
	_cancel_button.pressed.connect(_cancel)
	_poll_timer.timeout.connect(_poll)

func _on_panel_loaded(_ctx: Dictionary) -> void:
	_ipc = get_node_or_null("_MinervaIPC")
	_poll_timer.start()
	_poll()

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
	if not reply is Dictionary or not bool(reply.get("success", false)):
		_status.text = "Pairing request failed. Reopen to see progress or retry."
		return {}
	var body: Variant = reply.get("result", {})
	return body if body is Dictionary else {}

func _start() -> void:
	var arguments := {"action": "start", "name": _name.text, "code": _code.text}
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
	if not _defaults_initialized and body.has("port"):
		var port: Variant = body.port
		if (not (port is int or port is float) or not is_finite(float(port))
				or float(port) != floor(float(port)) or float(port) < 1 or float(port) > 65535):
			_status.text = "Invalid listener port."
			return
		_port = int(port)
		_host.text = str(body.host) if body.get("host") != null else ""
		_host.visible = _host.text.is_empty()
		_defaults_initialized = true
	var operation: Variant = body.get("operation", {})
	if operation is Dictionary:
		if operation.is_empty():
			_start_button.disabled = false
			_cancel_button.disabled = true
		_render(operation)

func _render(body: Dictionary) -> void:
	if body.is_empty():
		return
	var number: Variant = body.get("operation_id", 0)
	if (not (number is int or number is float) or not is_finite(float(number))
			or float(number) != floor(float(number)) or float(number) < 1
			or float(number) > 9007199254740991.0):
		_status.text = "Invalid pairing operation."
		return
	if int(number) < _operation:
		return
	_operation = int(number)
	var value: Variant = body.get("pairing", {})
	if not value is Dictionary:
		_status.text = "Invalid pairing status."
		return
	var details: Dictionary = value
	var stage: String = str(details.get("stage", ""))
	if stage.is_empty():
		stage = str(body.get("stage", "idle"))
	_status.text = str(LABELS.get(stage, stage.replace("_", " ")))
	var storage: String = str(details.get("persistence", "none"))
	if storage == "pending":
		_status.text = "Saving pairing; please wait…"
	elif storage == "stored" and stage != "confirmed":
		_status.text = "Pairing saved, not yet confirmed."
	elif bool(details.get("save_possible", false)) and stage in ["failed", "cancelled"]:
		_status.text += " The remote may have saved settings; confirmation is unknown."
	if bool(details.get("confirmation_pending", false)):
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
		var port: Variant = details.get("port")
		if (not (port is int or port is float) or not is_finite(float(port))
				or float(port) != floor(float(port)) or float(port) < 1 or float(port) > 65535):
			_status.text = "Invalid staged port."
			_apply_button.disabled = true
			return
		_host.text = str(details.host)
		_port = int(port)
	var networks: Array = details.get("networks", [])
	if waiting and _networks.item_count == 0:
		for row: Dictionary in networks:
			_networks.add_item(str(row.label))
			_networks.set_item_metadata(_networks.item_count - 1, str(row.ssid))
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
