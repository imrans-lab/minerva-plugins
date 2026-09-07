extends SceneTree
## One evaluation state per open document, reachable by every name it has.
##
## WHY THIS SUITE LOOKS THE WAY IT DOES
##
## The host's scene-panel broker used to key its registry by the MANIFEST panel
## name — one slot named "cad_panel" for the whole plugin. Opening a second
## .mcad overwrote the first panel's slot, taking its IPC helper and its
## outbound channels with it; closing the second erased the slot outright, and
## the first document then took edits that reached no worker. Its render tab
## kept answering with an evaluation stamped half an hour earlier and nothing
## in the reply said why. So what is pinned here is that TWO panels on ONE real
## broker each keep their own registration, their own helper and their own
## evaluation, that closing one leaves the other evaluating, and that a name is
## refused rather than guessed when it could mean either.
##
## The second half is addressing. A paired document is two tabs on one file:
## the text tab under the bare file name and the render tab under the "(1)"
## name Minerva appends. Every cad verb had to be addressed with the "(1)"
## name, which nothing in the document tells the caller. The broker resolves a
## panel by tab title, absolute path and bare file name, and a registration
## whose scene root is gone is not "known" — it is reported apart, with the one
## thing that explains it.
##
## The broker, the panel scene, the buffers and the error builder are all real.
## The Editor wrapper is not: the broker reads only `tab_title` and `file` off
## it, at lookup time, and a stub with those two fields exercises exactly the
## reads the host makes while letting this suite choose the names.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"

## Host classes, preloaded by path rather than by class_name: this script is
## parsed from outside Minerva's res:// tree, and the paths are pinned in
## tests/gd/REQUIRED_HOST_FILES so a host refactor fails by name.
const DocumentBufferScript := preload("res://Scripts/Services/Documents/DocumentBuffer.gd")
const PanelBrokerScript := preload("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd")
## The host's own editor_not_found builder — the reply a caller who mistyped a
## name actually reads.
const PluginErrorsScript := preload("res://Scripts/Services/Plugins/PluginErrors.gd")
## The panel's MCP verb surface, to prove a resolved panel answers verbs.
const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")

const SOURCE := "part = cube(10, 10, 10)\n"
const EDITED_SOURCE := "part = cube(20, 10, 10)\n"
const OTHER_SOURCE := "part = cylinder(5, 20)\n"

## The two documents opened side by side. Same plugin, same manifest panel,
## different files — the case the single-slot registry could not hold.
const DOC_A_NAME := "enclosure-rev4.mcad"
const DOC_B_NAME := "bracket.mcad"

## The manifest panel name every cad panel shares. Addressing by it is only
## unambiguous while exactly one panel is open.
const MANIFEST_PANEL := "cad_panel"

var _pass: int = 0
var _fail: int = 0
var _doc_a_path: String = ""
var _doc_b_path: String = ""


## Stands in for Minerva's Editor wrapper. The broker holds it weakly and reads
## `tab_title` and `file` on every lookup, so the two fields ARE the contract;
## a rename is a write to tab_title and nothing else.
class StubEditor extends RefCounted:
	var tab_title: String = ""
	var file: String = ""

	func _init(p_title: String, p_file: String) -> void:
		tab_title = p_title
		file = p_file


func _init() -> void:
	print("=== CAD Editor Addressing Test ===\n")
	await process_frame
	await _run()
	_cleanup()
	# Two frames so the rendering server releases the freed panels' viewport
	# textures before quit; otherwise they are reported as leaked at exit.
	await process_frame
	await process_frame
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	_doc_a_path = OS.get_user_data_dir().path_join(DOC_A_NAME)
	_doc_b_path = OS.get_user_data_dir().path_join(DOC_B_NAME)
	_write(_doc_a_path, SOURCE)
	_write(_doc_b_path, OTHER_SOURCE)

	await _test_two_open_documents_evaluate_independently()
	await _test_closing_one_document_leaves_the_other_evaluating()
	await _test_every_name_a_document_has_reaches_its_panel()
	await _test_a_name_that_could_mean_either_is_refused_not_guessed()
	await _test_a_panel_that_is_gone_is_not_a_known_editor()


# ---------------------------------------------------------------------------
# A5: one evaluation state per document
# ---------------------------------------------------------------------------

## Both documents open at once. The single-slot registry could not fail this
## by refusing the second open — a refusal leaves panel B unregistered, and
## every assertion below about B then fails by name.
func _test_two_open_documents_evaluate_independently() -> void:
	print("\n-- two documents open at once --")
	var broker: Object = PanelBrokerScript.new()
	var a := _open(broker, DOC_A_NAME, _doc_a_path, SOURCE, 0)
	var b := _open(broker, DOC_B_NAME, _doc_b_path, OTHER_SOURCE, 1)
	if a.is_empty() or b.is_empty():
		_close(broker, a)
		_close(broker, b)
		return

	check("open: both panels hold a registration of their own",
			broker.is_panel_registered(str(a["key"]))
			and broker.is_panel_registered(str(b["key"])),
			"registry lists %s" % str(broker.list_panel_editor_names()))
	check("open: opening the second document did not take the first's IPC helper",
			(a["panel"] as Node).get_node_or_null("_MinervaIPC") != null
			and (b["panel"] as Node).get_node_or_null("_MinervaIPC") != null,
			"A helper=%s B helper=%s" % [
				str((a["panel"] as Node).get_node_or_null("_MinervaIPC")),
				str((b["panel"] as Node).get_node_or_null("_MinervaIPC"))])
	check("open: both tabs answer to their own name",
			broker.get_panel_for_editor(str(a["title"])) == a["panel"]
			and broker.get_panel_for_editor(str(b["title"])) == b["panel"],
			"A -> %s, B -> %s" % [
				str(broker.get_panel_for_editor(str(a["title"]))),
				str(broker.get_panel_for_editor(str(b["title"])))])

	# An edit to A, and only A: the count on B is the control that shows the
	# two documents are not sharing one evaluation.
	var b_before: int = _evaluations(b).size()
	_edit(a, EDITED_SOURCE)
	await create_timer(0.5).timeout
	check("edit A: A's own edit reached A's worker",
			_evaluations(a).size() >= 2,
			"A dispatched %s" % str(a["dispatched"]))
	check("edit A: B was not evaluated by A's edit",
			_evaluations(b).size() == b_before,
			"B dispatched %s" % str(b["dispatched"]))

	var a_after_a: int = _evaluations(a).size()
	_edit(b, EDITED_SOURCE)
	await create_timer(0.5).timeout
	check("edit B: B's own edit reached B's worker",
			_evaluations(b).size() > b_before,
			"B dispatched %s" % str(b["dispatched"]))
	check("edit B: A was not evaluated again by B's edit",
			_evaluations(a).size() == a_after_a,
			"A dispatched %s" % str(a["dispatched"]))

	_close(broker, a)
	_close(broker, b)


## The measured failure: B is closed, and A — untouched by any of it — stops
## evaluating. A's registration must survive B's teardown intact.
func _test_closing_one_document_leaves_the_other_evaluating() -> void:
	print("\n-- the second document closes, the first keeps working --")
	var broker: Object = PanelBrokerScript.new()
	var a := _open(broker, DOC_A_NAME, _doc_a_path, SOURCE, 0)
	var b := _open(broker, DOC_B_NAME, _doc_b_path, OTHER_SOURCE, 1)
	if a.is_empty() or b.is_empty():
		_close(broker, a)
		_close(broker, b)
		return

	_close(broker, b)
	await process_frame

	check("close: the surviving panel is still registered",
			broker.is_panel_registered(str(a["key"])),
			"registry lists %s" % str(broker.list_panel_editor_names()))
	check("close: the surviving panel still has its IPC helper",
			(a["panel"] as Node).get_node_or_null("_MinervaIPC") != null)
	check("close: the surviving panel still answers to its name",
			broker.get_panel_for_editor(str(a["title"])) == a["panel"])

	var before: int = _evaluations(a).size()
	_edit(a, EDITED_SOURCE)
	await create_timer(0.5).timeout
	check("close: an edit to the surviving document still reaches its worker",
			_evaluations(a).size() > before,
			"A dispatched %s" % str(a["dispatched"]))

	_close(broker, a)


# ---------------------------------------------------------------------------
# A7: every name a document has reaches its panel
# ---------------------------------------------------------------------------

## The render tab of a paired document carries the "(1)" title, but a caller
## holding the document knows its file name and its path. All three must land
## on the same panel, and that panel must answer a verb.
func _test_every_name_a_document_has_reaches_its_panel() -> void:
	print("\n-- one panel, every name it has --")
	var broker: Object = PanelBrokerScript.new()
	# Index 1 gives this panel the uniquified render-tab title, which is what
	# the owner had to type before every verb.
	var a := _open(broker, DOC_A_NAME, _doc_a_path, SOURCE, 1)
	if a.is_empty():
		return
	var panel: Node = a["panel"]

	check("address: the uniquified render-tab title still works",
			broker.get_panel_for_editor("%s (1)" % DOC_A_NAME) == panel,
			"resolved %s" % str(broker.get_panel_for_editor("%s (1)" % DOC_A_NAME)))
	check("address: the bare file name reaches the panel rendering it",
			broker.get_panel_for_editor(DOC_A_NAME) == panel,
			"resolved %s" % str(broker.get_panel_for_editor(DOC_A_NAME)))
	check("address: the document's absolute path reaches the same panel",
			broker.get_panel_for_editor(_doc_a_path) == panel,
			"resolved %s" % str(broker.get_panel_for_editor(_doc_a_path)))
	check("address: the manifest panel name works while only one is open",
			broker.get_panel_for_editor(MANIFEST_PANEL) == panel)
	check("address: a name no open document has resolves to nothing",
			broker.get_panel_for_editor("not-open.mcad") == null)

	# Resolution is only worth anything if the thing it returns answers verbs.
	var by_bare_name: Node = broker.get_panel_for_editor(DOC_A_NAME)
	var reply: Dictionary = await PanelTools.handle(
			by_bare_name, "minerva_cad_references", {})
	check("address: the panel found by bare name answers a cad verb",
			reply.has("success"),
			"reply = %s" % str(reply))

	check("address: the owning plugin is the same whichever name is used",
			str(broker.get_panel_owner(DOC_A_NAME)) == "cad"
			and str(broker.get_panel_owner(_doc_a_path)) == "cad"
			and str(broker.get_panel_owner("%s (1)" % DOC_A_NAME)) == "cad",
			"owners: %s / %s / %s" % [
				str(broker.get_panel_owner(DOC_A_NAME)),
				str(broker.get_panel_owner(_doc_a_path)),
				str(broker.get_panel_owner("%s (1)" % DOC_A_NAME))])

	_close(broker, a)


## Two documents that share a bare file name in different directories, neither
## of them TITLED that bare name — the paired case, where both render tabs
## carry a "(N)" suffix. Picking whichever one registered first would silently
## answer about the wrong document, so a name that reaches both only through
## the same, least precise alias resolves to nothing, and each document stays
## addressable by the names that ARE its own.
##
## Names are tiered, so this is genuinely about the tier being shared: a panel
## whose tab title IS the bare name would win it outright over a panel that
## only matches it as a file name.
func _test_a_name_that_could_mean_either_is_refused_not_guessed() -> void:
	print("\n-- a name two documents answer to --")
	var broker: Object = PanelBrokerScript.new()
	var nested_dir: String = OS.get_user_data_dir().path_join("cad_addressing_nested")
	DirAccess.make_dir_recursive_absolute(nested_dir)
	var twin_path: String = nested_dir.path_join(DOC_A_NAME)
	_write(twin_path, OTHER_SOURCE)

	var a := _open(broker, DOC_A_NAME, _doc_a_path, SOURCE, 1)
	var twin := _open(broker, DOC_A_NAME, twin_path, OTHER_SOURCE, 2)
	if a.is_empty() or twin.is_empty():
		_close(broker, a)
		_close(broker, twin)
		return

	check("ambiguous: a bare name two open documents share resolves to nothing",
			broker.get_panel_for_editor(DOC_A_NAME) == null,
			"resolved %s" % str(broker.get_panel_for_editor(DOC_A_NAME)))
	check("ambiguous: the manifest panel name is ambiguous too once two are open",
			broker.get_panel_for_editor(MANIFEST_PANEL) == null)
	check("ambiguous: each document is still reachable by its own path",
			broker.get_panel_for_editor(_doc_a_path) == a["panel"]
			and broker.get_panel_for_editor(twin_path) == twin["panel"])
	check("ambiguous: each document is still reachable by its own tab title",
			broker.get_panel_for_editor(str(a["title"])) == a["panel"]
			and broker.get_panel_for_editor(str(twin["title"])) == twin["panel"])

	_close(broker, a)
	_close(broker, twin)
	DirAccess.remove_absolute(twin_path)
	DirAccess.remove_absolute(nested_dir)


## A registration whose scene root is gone answers nothing. Listing it among
## the known editors sends the caller round the same failing call; the reply
## must separate it and say what happened to it.
func _test_a_panel_that_is_gone_is_not_a_known_editor() -> void:
	print("\n-- a registration whose panel is gone --")
	var broker: Object = PanelBrokerScript.new()
	var live := _open(broker, DOC_A_NAME, _doc_a_path, SOURCE, 0)
	var doomed := _open(broker, DOC_B_NAME, _doc_b_path, OTHER_SOURCE, 1)
	if live.is_empty() or doomed.is_empty():
		_close(broker, live)
		_close(broker, doomed)
		return

	# Free the scene root WITHOUT unregistering: the dead-registration shape a
	# panel that failed to stay up leaves behind.
	var doomed_title: String = str(doomed["title"])
	var doomed_panel: Node = doomed["panel"]
	if doomed_panel.get_parent() != null:
		doomed_panel.get_parent().remove_child(doomed_panel)
	doomed_panel.free()
	doomed["panel"] = null

	var known: Array = broker.list_panel_editor_names()
	var dead: Array = broker.list_dead_panel_editor_names()

	check("dead: the freed panel is not offered as a known editor",
			not known.has(doomed_title),
			"known = %s" % str(known))
	check("dead: the live panel is still offered",
			known.has(str(live["title"])),
			"known = %s" % str(known))
	check("dead: the freed panel is named among the unreachable ones",
			dead.has(doomed_title),
			"dead = %s" % str(dead))
	check("dead: nothing resolves to the freed panel",
			broker.get_panel_for_editor(doomed_title) == null)

	var reply: Dictionary = PluginErrorsScript.editor_not_found(
			"cad", doomed_title, known, dead)
	var message: String = str(reply.get("error_message", ""))
	check("dead: the reply says the scene root was freed without unregistering",
			message.contains("scene root was freed"),
			"message = %s" % message)
	check("dead: the reply points at the Minerva log for the reason",
			message.contains("see the Minerva log"),
			"message = %s" % message)
	check("dead: the unreachable name is reported apart from the known ones",
			not (reply.get("known_editors", []) as Array).has(doomed_title)
			and (reply.get("dead_editors", []) as Array).has(doomed_title),
			"reply = %s" % str(reply))

	# The dead entry is still the owner's to unregister, or teardown leaks it.
	check("dead: the freed panel's registration can still be unregistered",
			str(broker.get_panel_owner(str(doomed["key"]))) == "cad")
	broker.unregister_panel("cad", str(doomed["key"]))
	check("dead: unregistering it clears the unreachable list",
			broker.list_dead_panel_editor_names().is_empty(),
			"dead = %s" % str(broker.list_dead_panel_editor_names()))

	_close(broker, live)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Open one document the way the host does: a real panel scene, registered on
## the SHARED broker under a per-tab key with the manifest panel name beside
## it, then a real DocumentBuffer attached.
##
## `tab_index` picks the tab title: index 0 is the plain file name, any higher
## index gets the "(N)" suffix Minerva appends to a second tab on one file —
## the render tab of a paired document.
func _open(broker: Object, file_name: String, path: String, text: String,
		tab_index: int) -> Dictionary:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	var panel: Node = packed.instantiate() if packed != null else null
	check("setup: the CAD panel scene instantiates", panel != null,
			"could not instantiate %s" % PANEL_SCENE_PATH)
	if panel == null:
		return {}
	root.add_child(panel)

	var title: String = file_name if tab_index == 0 else "%s (%d)" % [file_name, tab_index]
	var editor := StubEditor.new(title, path)
	# The host derives this from the Editor instance; anything unique per open
	# tab does the same job.
	var key: String = "%s#%d" % [MANIFEST_PANEL, panel.get_instance_id()]

	broker.register_panel(panel, "cad", key,
			PackedStringArray(["cad.evaluate", "cad.cancel_eval"]),
			MANIFEST_PANEL, editor)
	# register_panel also wires the panel's `request` signal to the broker's
	# own dispatch, and THIS SUITE IS THE BACKEND: the broker here has no
	# PluginManager, so it has no manifest to validate the panel against and
	# no running plugin connection to forward to — it would answer every
	# request with permission_denied within a millisecond. Only the trampoline
	# is dropped; the broker keeps doing the parts the suite needs (the IPC
	# helper, the buffer attach, and the registry itself).
	for connection in panel.get_signal_connection_list("request"):
		panel.disconnect("request", (connection as Dictionary)["callable"] as Callable)
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": MANIFEST_PANEL,
		"panel_key": key,
		"broker": broker,
		"editor": editor,
		"host_api_version": "1",
	})

	var dispatched: Array = []
	panel.request.connect(func(channel: String, payload: Dictionary, reply_id: String) -> void:
		dispatched.append({"channel": channel, "payload": payload, "reply_id": reply_id}))

	var buffer = DocumentBufferScript.new(path, text)
	broker.attach_buffer_to_panel("cad", key, buffer)

	return {
		"panel": panel,
		"key": key,
		"title": title,
		"path": path,
		"editor": editor,
		"buffer": buffer,
		"dispatched": dispatched,
	}


## Type into a document the way the paired text editor does — through the
## shared buffer, so the edit reaches the panel over the substrate's own
## text_changed channel rather than by calling the panel directly.
func _edit(doc: Dictionary, text: String) -> void:
	var buffer: Object = doc["buffer"]
	buffer.apply_edit(text)


## Only the evaluations this document dispatched. Cancels and other channels
## are noise for a count of "was this document's worker asked".
func _evaluations(doc: Dictionary) -> Array:
	var out: Array = []
	for entry in (doc["dispatched"] as Array):
		if str((entry as Dictionary)["channel"]) == "cad.evaluate":
			out.append(entry)
	return out


## Close a document the way the host does on tab close: detach the buffer,
## unregister, then free the scene. Freed immediately, not queued — the last
## document is closed right before quit(), and a queued free never gets its
## frame, which Godot reports as resources still in use at exit.
func _close(broker: Object, doc: Dictionary) -> void:
	if doc.is_empty():
		return
	var key: String = str(doc.get("key", ""))
	var panel: Node = doc.get("panel", null)
	if panel != null and is_instance_valid(panel):
		# The host fires the unload hook first, which is what drops the panel's
		# entry from the process-global annotation-host registry.
		panel._on_panel_unload()
	if broker != null and not key.is_empty() and broker.is_panel_registered(key):
		broker.detach_buffer_from_panel("cad", key)
		broker.unregister_panel("cad", key)
	if panel != null and is_instance_valid(panel):
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		panel.free()
	doc["panel"] = null


func _write(path: String, text: String) -> void:
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle != null:
		handle.store_string(text)
		handle.close()


func _cleanup() -> void:
	for path in [_doc_a_path, _doc_b_path]:
		if path != "" and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


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
