extends RefCounted
## Stands in for the host broker on the panel's BULK route.
##
## CADPanel sends every backend round trip through MinervaIPC.request_bulk,
## which calls the broker's handle_scene_request DIRECTLY instead of emitting
## the panel's `request` signal — so a suite that is itself the backend can no
## longer see a send by watching that signal. MinervaIPC.configure_bulk()
## rebinds the helper's broker, so a recorder installed here receives every
## bulk send; it answers nothing, leaving the suite to deliver the reply by id
## the way it already does on the signal route.
##
## Two mechanics to know:
##   * the helper holds its broker WEAKLY, so the caller must keep the
##     recorder alive for as long as the panel is mounted;
##   * request_bulk dispatches with call_deferred, so a send is recorded at
##     the end of the frame it was made in, not during it — a suite that
##     drives the panel and then reads what was dispatched needs one
##     `await process_frame` between the two.
##
## Not a test suite: the runner's glob is test_*.gd.

const SCRIPT_PATH := "res://../../minerva-plugins/cad/tests/gd/bulk_route_recorder.gd"

## Every listener the suite wants on the bulk route, called as
## (channel, payload, reply_id) — the same arguments the `request` signal
## carries.
var _sinks: Array[Callable] = []


## Point `panel`'s IPC helper at a new recorder. Returns the recorder, which
## the caller must hold for as long as the panel is mounted.
static func install(panel: Node, panel_key: String, sink: Callable) -> RefCounted:
	var recorder = (load(SCRIPT_PATH) as Script).new()
	recorder.add_sink(sink)
	var ipc: Node = panel.get_node_or_null("_MinervaIPC")
	if ipc != null and ipc.has_method("configure_bulk"):
		ipc.configure_bulk(recorder, panel_key)
	return recorder


func add_sink(sink: Callable) -> void:
	_sinks.append(sink)


## The broker entry point MinervaIPC.request_bulk calls. Signature matches
## PluginScenePanelBroker.handle_scene_request.
func handle_scene_request(_panel_key: String, channel: String, payload: Dictionary,
		reply_id: String, _generation: int = 0, _bulk: bool = false) -> void:
	for sink in _sinks:
		if sink.is_valid():
			sink.call(channel, payload, reply_id)
