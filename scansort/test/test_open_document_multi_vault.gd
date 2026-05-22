extends SceneTree
## Regression test — scansort must attach the correct vault password when a
## document is opened, even when that document's vault is NOT the most-recently
## opened one. Reproduces RCA 019e4ca264 headlessly.
##
## Tracks docket: RCA 019e4ca264 / W1 019e4ca329.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script ~/github/plugins/scansort/test/test_open_document_multi_vault.gd
##
## HOW IT REPRODUCES THE BUG — and what is and isn't real:
##   * It instantiates the REAL Scansort_Panel and drives the REAL
##     _on_area_tree_file_activated (the exact double-click handler) and the
##     REAL _find_vault_path_for_doc_key. All panel logic under test is real.
##   * The ONLY test double is a passive call-recorder substituted for the MCP
##     connection. It simulates NO scansort behaviour — it records the
##     extract_document arguments the panel decides to send, then returns a
##     canned failure. It is an observation point, not a behaviour mock (it is
##     categorically unlike the rejected fake classification provider).
##   * The bug IS precisely that the panel omits the vault password for a
##     document in a non-active vault (ScansortPanel.gd:1225). The recorder
##     makes that decision directly observable.
##   * The downstream consequence — an encrypted doc then fails to extract — is
##     already proven by the runtime log in RCA 019e4ca264 (console extract
##     id 66: no "password" arg -> "Document is encrypted… password required").

const PANEL_REL := "github/plugins/scansort/ui/ScansortPanel.gd"

var _pass: int = 0
var _fail: int = 0


## Passive spy for the MCP connection: records every call_tool and returns a
## canned failure. Simulates no scansort logic.
class RecordingConn:
	var calls: Array = []
	func call_tool(tool_name: String, args: Dictionary) -> Dictionary:
		calls.append({"name": tool_name, "args": args.duplicate(true)})
		await Engine.get_main_loop().process_frame
		return {"ok": false, "error": "recording-conn: tool not executed"}
	func last_call(tool_name: String) -> Dictionary:
		for i in range(calls.size() - 1, -1, -1):
			if calls[i]["name"] == tool_name:
				return calls[i]
		return {}


## Stands in for SingletonObject.plugin_manager so the panel's _get_connection()
## resolves to the recorder. One method, no logic.
class FakePluginManager:
	var _conn
	func _init(conn) -> void:
		_conn = conn
	func get_connection(_id: String):
		return _conn


func _init() -> void:
	print("=== Scansort Multi-Vault Open-Document Regression Test (RCA 019e4ca264) ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d — scansort non-active-vault open repro is RED (expected pre-fix)" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		printerr("FAIL: SingletonObject autoload not found")
		_fail += 1
		return

	# Substitute the recorder for the connection the panel's _get_connection()
	# fetches (SingletonObject -> plugin_manager -> get_connection("scansort")).
	# The real plugin_manager is restored at the end so engine-shutdown cleanup
	# (SingletonObject -> plugin_manager.shutdown_all()) still works.
	var real_pm = so.get("plugin_manager")
	var rec := RecordingConn.new()
	so.set("plugin_manager", FakePluginManager.new(rec))

	var panel_script: Script = load(OS.get_environment("HOME").path_join(PANEL_REL))
	if panel_script == null:
		printerr("FAIL: could not load ScansortPanel.gd")
		_fail += 1
		return
	var panel = panel_script.new()
	# Deliberately NOT added to the scene tree: _ready() builds the whole UI and
	# is not needed. _on_area_tree_file_activated is driven directly; set_status
	# is null-guarded so it safely no-ops without the UI.

	# --- Scenario: three vaults open, B focused last --------------------------
	# The user opened encrypted vault A, then encrypted vault B, then plain
	# vault C. Post-fix scansort keeps a per-vault password store, so EVERY
	# opened vault's password survives — A's password is no longer lost when B
	# (or C) is opened. Populate the store to mimic that end-state.
	var vault_a := "/home/u/temp/vaults/encrypted_a.ssort"
	var vault_b := "/home/u/temp3/encrypted_b.ssort"
	var vault_c := "/home/u/temp/vaults/plain_c.ssort"   # non-encrypted vault
	panel._active_vault_path = vault_b
	panel._vault_password_store.set_password(vault_a, "pw-A")
	panel._vault_password_store.set_password(vault_b, "pw-B")
	panel._vault_password_store.set_password(vault_c, "")  # non-encrypted

	# The vault area tree shows documents from ALL registry vaults; each doc row
	# carries its own vault_path meta (as scan_tree.gd does at :204).
	var area_tree := _build_area_tree({"doc:101": vault_a, "doc:202": vault_c})
	panel._vault_area_tree = area_tree
	panel._dir_area_tree = null

	# --- CASE 1: encrypted document in the non-active vault A -----------------
	rec.calls.clear()
	await panel._on_area_tree_file_activated("doc:101")
	var ex_a: Dictionary = rec.last_call("minerva_scansort_extract_document")
	check("CASE 1: panel dispatched extract_document for the vault-A doc",
			not ex_a.is_empty(), "no extract_document call recorded")
	if not ex_a.is_empty():
		var args_a: Dictionary = ex_a["args"]
		print("    CASE 1 extract args: %s" % JSON.stringify(args_a))
		check("CASE 1: extract targets vault A",
				str(args_a.get("vault_path", "")) == vault_a,
				"got vault_path=%s" % str(args_a.get("vault_path", "")))
		# THE BUG: the panel must send vault A's password so its encrypted doc
		# can be decrypted. It sends none — vault A != the active vault B, so the
		# ScansortPanel.gd:1225 guard withholds the cached password.
		var pw_a: String = str(args_a.get("password", ""))
		check("REPRO: extract for an encrypted non-active-vault doc carries a password",
				not pw_a.is_empty(),
				"NO password sent for vault A's encrypted doc — it cannot be decrypted")

	# --- CASE 2: non-encrypted document in the non-active vault C -------------
	# A non-encrypted vault needs no password; opening its document should still
	# dispatch a well-formed extract for vault C. Control / coverage — the bug
	# does not affect this path and the fix must keep it working.
	rec.calls.clear()
	await panel._on_area_tree_file_activated("doc:202")
	var ex_c: Dictionary = rec.last_call("minerva_scansort_extract_document")
	check("CASE 2: panel dispatched extract_document for the vault-C doc",
			not ex_c.is_empty(), "no extract_document call recorded")
	if not ex_c.is_empty():
		print("    CASE 2 extract args: %s" % JSON.stringify(ex_c["args"]))
		check("CASE 2: extract targets vault C (non-encrypted)",
				str(ex_c["args"].get("vault_path", "")) == vault_c,
				"got vault_path=%s" % str(ex_c["args"].get("vault_path", "")))

	panel.free()
	area_tree.free()
	so.set("plugin_manager", real_pm)  # restore for clean engine shutdown


## Build a Tree mimicking scan_tree.gd's output: each doc row's column-1
## metadata is the "doc:<id>" key, with a "vault_path" meta carrying its vault.
func _build_area_tree(doc_to_vault: Dictionary) -> Tree:
	var tree := Tree.new()
	root.add_child(tree)          # in-tree so columns/items initialise
	tree.columns = 3
	var tree_root := tree.create_item()
	for doc_key in doc_to_vault:
		var it := tree.create_item(tree_root)
		it.set_metadata(1, doc_key)
		it.set_meta("kind", "file")
		it.set_meta("vault_path", str(doc_to_vault[doc_key]))
	return tree


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
