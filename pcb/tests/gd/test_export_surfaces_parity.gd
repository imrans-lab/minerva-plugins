extends SceneTree
## Task-cycle 12 B4 (docket 01a0545d027a): the export affordance is a CHOICE of
## exporter, on every surface that offers it, and the tool surface reaches the
## same outcomes under the same refusal names.
##
## THE ORACLE — and it is not "both refuse". It is the two paths DISAGREEING:
## a board that refuses through one and exports through the other, or one fault
## carrying two different names depending on who asked. The owner works only
## through the GUI and cannot call a tool; an agent works only through tools and
## cannot click. A capability on one side only is invisible to half the people
## who need it, and a refusal named differently on each side is two bugs to
## chase instead of one fault to fix.
##
## Three doorways are driven here over ONE canned worker reply and compared to
## each other, never to a hand-written expectation:
##   1. the toolbar's Export menu,
##   2. the View menu's export rows (which exist because that pair hides at
##      narrow widths — an amendment to this task after review found the second
##      surface, and converting only one would have left a path that could
##      never reach the new exporters),
##   3. minerva_pcb_board_export.
##
## Run (via a Minerva scaffold as the Godot host):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_export_surfaces_parity.gd

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
## The SHIPPED service profile. Its `unchecked_rules` block is the origin of the
## entries a package reports: service_profile.py parses it verbatim into
## ServiceProfile.unchecked_rules, assembly_outputs hands that straight to the
## emission, and order_package concatenates it into the package's list without
## reshaping a key. Reading the file here is what stops the canned reply below
## from being a hand-written shape: a fixture spelled {code, message} passed the
## GUI renderer that reads {code, message} while the worker sent {id, reason},
## and every bullet under "NOTHING LOOKED AT THESE" rendered blank in the app.
const PROFILE_PATH := "res://../../minerva-plugins/pcb/library/service-profiles/jlcpcb-economic.json"
const PanelTools := preload("res://../../minerva-plugins/pcb/ui/panel_tools.gd")
const PcbExport := preload("res://../../minerva-plugins/pcb/ui/pcb_export.gd")

const CHANNEL := "minerva_pcb_order_package"

var _pass := 0
var _fail := 0


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [desc, ("" if detail == "" else " — " + detail)])


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)],
		actual == expected)


class FakeEditor extends RefCounted:
	var tab_title: String = ""


## Capture-and-canned IPC, the shape test_export_yaml_verb.gd established:
## `reply` is the FULL envelope handed back to await_reply, so a refusal can be
## posed at the real nesting depth ({success, result:{ok, result}}). The depth
## is the point — a reply posed one level shallow passes a test the live
## envelope would fail.
class FakeIPC extends Node:
	var captured: Array = []
	var reply: Dictionary = {}
	var _reply_id := ""

	func bind(panel_node) -> void:
		name = "_MinervaIPC"
		panel_node.add_child(self)
		panel_node.request.connect(_on_request)

	func _on_request(channel: String, payload: Dictionary, reply_id: String) -> void:
		captured.append({"channel": channel, "payload": payload})
		_reply_id = reply_id

	func last_request() -> Dictionary:
		return captured[captured.size() - 1] if not captured.is_empty() else {}

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout",
				"error_message": "no captured request"}
		return reply.duplicate(true)


# ── The canned worker replies ───────────────────────────────────────────────

## A duplicate-designator refusal exactly as methods.py builds it: the STABLE
## gate code beside the family kind, the component and field named, and the
## BLOCKED preflight the worker attaches because no package was written.
static func _refusing_reply() -> Dictionary:
	return {"success": true, "result": {"ok": false, "error": {
		"kind": "assembly",
		"code": "assembly_duplicate_designator",
		"component": "U1S",
		"field": "assembly.placements",
		"refs": ["U1S_A", "u1s_a"],
		"message": "designator 'U1S_A' is used twice after case folding (U1S_A, u1s_a)",
		"preflight": {
			"preflight_version": 1,
			"status": "blocked",
			"blockers": [{
				"code": "assembly_duplicate_designator",
				"component": "U1S",
				"field": "assembly.placements",
				"refs": ["U1S_A", "u1s_a"],
				"message": "designator 'U1S_A' is used twice after case folding (U1S_A, u1s_a)",
			}],
			"advisories": [],
			"unchecked": [],
			"readiness": {"package_generated": false, "preflight_status": "blocked",
				"order_page_verified": null,
				"order_page_verified_note": "only a person who uploaded these files can record it"},
		},
	}}}


## A package that generated, with the two honest-outcome lists populated and —
## the carried-forward half — the compile diagnostics the worker has always
## sent and no surface used to draw.
func _passing_reply() -> Dictionary:
	return {"success": true, "result": {"ok": true, "result": {
		"directory": "parity-board-jlcpcb-economic",
		"outputs": [
			{"file": "bom.csv", "sha256": "a".repeat(64), "bytes": 412},
			{"file": "gerbers.zip", "sha256": "b".repeat(64), "bytes": 91_204},
		],
		"readiness": {"package_generated": true, "preflight_status": "advisories",
			"order_page_verified": null,
			"order_page_verified_note": "only a person who uploaded these files can record it"},
		"preflight": {"status": "advisories", "blockers": []},
		"source": {"git": {"available": false,
			"reason": "the board source was supplied inline, not as a file in a repository"}},
		"written": [{"path": "/tmp/parity-board-jlcpcb-economic"}],
		"advisories": [{"code": "assembly_anchor_unmeasured", "component": "J2",
			"field": "assembly anchor", "refs": ["J2"],
			"message": "could not measure the body of component 'J2'"}],
		"unchecked_rules": _profile_unchecked(),
		"ip_questions": [{"code": "licence_undeclared", "component": "U1",
			"message": "no library lock in the tree declares a licence"}],
		"warnings": [{"severity": "WARNING", "code": "captured_geometry_not_emitted",
			"message": "captured silk on U1 was not emitted",
			"source_ref": {"entity_kind": "component", "entity_id": "U1",
				"detail": "silk"}}],
	}}}


## The shipped profile's own unchecked_rules, verbatim. A read that fails is a
## FAILURE, never a skip: a fixture that quietly fell back to a literal would be
## the exact defect this reads the file to prevent.
func _profile_unchecked() -> Array:
	var text := FileAccess.get_file_as_string(PROFILE_PATH)
	if text.is_empty():
		return []
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return []
	var rules = (parsed as Dictionary).get("unchecked_rules", [])
	return (rules as Array) if rules is Array else []


func _tiny_board() -> Dictionary:
	return {"version": 1, "name": "parity-board", "width_mm": 20.0, "height_mm": 20.0,
		"layers": ["top", "bottom"],
		"components": [{"ref": "R1", "footprint": "", "x_mm": 5.0, "y_mm": 5.0,
			"rotation_deg": 0, "layer": "top",
			"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]}],
		"nets": [{"name": "GND", "pins": ["R1.1"]}]}


## A board whose export payload exceeds panel_tools' by-reference cap, so the
## package exporter takes the arm a real board takes. Grown until it is over the
## cap rather than to a hard-coded count: the threshold is read from the file
## that declares it, so this cannot drift into testing the inline arm by
## accident. The extra bulk is silk lines along an empty strip.
func _over_cap_board() -> Dictionary:
	var board := _tiny_board()
	var graphics: Array = []
	board["board_graphics"] = graphics
	var payload := {"board": board, "profile": "jlcpcb-economic",
		"out_dir": "/tmp/order-packages", "overwrite": false}
	while JSON.stringify(payload).length() <= PanelTools._SNAPSHOT_LIMIT:
		var n := graphics.size()
		var x := 1.0 + float(n % 30) * 0.5
		graphics.append({"layer": "F.SilkS", "kind": "line",
			"start": {"x_mm": x, "y_mm": 2.0},
			"end": {"x_mm": x + 0.25, "y_mm": 2.5}})
	return board


## A panel with a board, an adopted canonical source (so the package exporters
## have an implicit destination) and a canned IPC bound.
func _rig(reply: Dictionary) -> Dictionary:
	var panel: Variant = load(PANEL_PATH).new()
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_tiny_board())
	panel._canonical_source_path = _scratch_dir().path_join("parity-board.yaml")
	var ipc := FakeIPC.new()
	ipc.bind(panel)
	ipc.reply = reply
	return {"panel": panel, "host": panel.get_annotation_host(), "ipc": ipc}


func _scratch_dir() -> String:
	var abs := ProjectSettings.globalize_path("user://test_export_surfaces_parity")
	DirAccess.make_dir_recursive_absolute(abs)
	return abs


## The View menu's export rows, as {label: id} read off the live popup — never
## off the id constant, so this measures the wiring rather than the arithmetic.
func _view_menu_export_rows(panel) -> Dictionary:
	var popup: PopupMenu = panel._view_menu_button.get_popup()
	var rows := {}
	for i in popup.item_count:
		var text := str(popup.get_item_text(i))
		if text.begins_with("Export: "):
			rows[text.trim_prefix("Export: ").trim_suffix("…")] = popup.get_item_id(i)
	return rows


## The toolbar Export menu's rows, same shape, read the same way.
func _export_menu_rows(panel) -> Dictionary:
	var popup: PopupMenu = panel._export_menu_button.get_popup()
	var rows := {}
	for i in popup.item_count:
		rows[str(popup.get_item_text(i))] = popup.get_item_id(i)
	return rows


## Which row the toolbar Export menu marks as the current exporter. A radio
## check is the only place the selection is visible without opening a verb.
func _export_menu_checked(panel) -> String:
	var popup: PopupMenu = panel._export_menu_button.get_popup()
	for i in popup.item_count:
		if popup.is_item_checked(i):
			return str(popup.get_item_text(i))
	return ""


func _init() -> void:
	print("=== B4: export surfaces + tool parity ===\n")
	await process_frame
	_run_both_surfaces_carry_every_exporter()
	await _run_one_refusal_one_name()
	await _run_one_success_one_package()
	await _run_the_choice_reaches_the_worker()
	await _run_an_oversized_board_still_asserts_nothing()
	await _run_destination_refusal_parity()
	await _run_named_per_component_report()
	await _run_yaml_exporter_unchanged()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1: BOTH surfaces carry EVERY exporter ───────────────────────────────────
#
# The review amendment's finding. The inline chooser hides at narrow widths, so
# the View menu is the export surface at those widths; an exporter in one and
# not the other is reachable by some users and not others, silently.

func _run_both_surfaces_carry_every_exporter() -> void:
	print("-- 1: both surfaces carry every exporter --")
	var rig := _rig({})
	var panel = rig["panel"]

	check("1a: there is more than one exporter to choose between",
		PcbExport.EXPORTERS.size() >= 2, str(PcbExport.EXPORTERS.size()))
	check("1a: …and at least one of them builds an order package",
		PcbExport.index_of("jlcpcb-economic") >= 0, str(PcbExport.ids()))

	var toolbar: Variant = panel.find_child("ExportMenuButton", true, false)
	check("1b: the toolbar carries an Export menu, not a fixed action",
		toolbar != null)
	var inline_rows := _export_menu_rows(panel)
	check_eq("1b: …with one row per exporter",
		inline_rows.size(), PcbExport.EXPORTERS.size())
	for i in PcbExport.EXPORTERS.size():
		check("1b: the toolbar offers %s" % PcbExport.label_at(i),
			inline_rows.has(PcbExport.label_at(i)), str(inline_rows.keys()))
	check_eq("1b: …and marks the current exporter with a radio check",
		_export_menu_checked(panel), PcbExport.label_at(PcbExport.YAML_INDEX))

	var rows := _view_menu_export_rows(panel)
	check_eq("1c: the View menu carries one export row per exporter",
		rows.size(), PcbExport.EXPORTERS.size())
	for i in PcbExport.EXPORTERS.size():
		check("1c: the View menu offers %s" % PcbExport.label_at(i),
			rows.has(PcbExport.label_at(i)), str(rows.keys()))

	# 1d: the two surfaces agree on WHICH exporter each row means. A menu whose
	# rows map to the wrong indices is a menu that runs the wrong exporter, and
	# it would still pass a count check. Section 7c drives the mapping; this
	# pins that the ids run in exporter order with no gaps for one to slip into.
	var base: int = int(rows.get(PcbExport.label_at(0), -1))
	for i in PcbExport.EXPORTERS.size():
		check_eq("1d: the View menu row for %s sits at base + %d"
			% [PcbExport.label_at(i), i],
			int(rows.get(PcbExport.label_at(i), -1)), base + i)
		check_eq("1d: the toolbar row for %s IS exporter index %d"
			% [PcbExport.label_at(i), i],
			int(inline_rows.get(PcbExport.label_at(i), -1)), i)

	# 1e: every advertised id resolves to a row of the one list — the chooser,
	# the menu and the verb cannot be reading parallel vocabularies.
	for exporter_id in PcbExport.ids():
		check("1e: %s resolves to an exporter" % exporter_id,
			not PcbExport.find(str(exporter_id)).is_empty(), str(exporter_id))
		check_eq("1e: …and round-trips through its index",
			PcbExport.id_at(PcbExport.index_of(str(exporter_id))), str(exporter_id))


# ── 2: ONE refusal, ONE name, on every doorway ──────────────────────────────

func _run_one_refusal_one_name() -> void:
	print("\n-- 2: one refusal, one name --")
	var rig := _rig(_refusing_reply())
	var panel = rig["panel"]
	var package_index := PcbExport.index_of("jlcpcb-economic")

	# 2a: the toolbar Export menu's row for the package exporter.
	await panel._on_export_menu_id_pressed(
		int(_export_menu_rows(panel)[PcbExport.label_at(package_index)]))
	var button_status := str(panel._status_label.text)

	# 2b: the View menu row for the SAME exporter.
	var rows := _view_menu_export_rows(panel)
	await panel._on_view_menu_id_pressed(
		int(rows[PcbExport.label_at(package_index)]))
	var menu_status := str(panel._status_label.text)

	# 2c: the verb.
	var verb: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_board_export", {"exporter": "jlcpcb-economic"})

	# 2d: the module's own run, which is what all three call.
	var direct: Dictionary = await PcbExport.run(panel, "jlcpcb-economic")

	check_eq("2a: the verb refused", bool(verb.get("success", true)), false)
	check_eq("2a: …under the worker's own gate code",
		str(verb.get("error", "")), "assembly_duplicate_designator")
	check_eq("2b: the module refused under the same name",
		str(direct.get("error", "")), str(verb.get("error", "")))
	check("2c: the button's status line carries that same name",
		button_status.contains("assembly_duplicate_designator"), button_status)
	check("2c: …and so does the View menu's",
		menu_status.contains("assembly_duplicate_designator"), menu_status)
	check_eq("2d: the two GUI surfaces say the SAME sentence",
		button_status, menu_status)

	# 2e: the code wins over the family kind. Matching on "assembly" cannot tell
	# a duplicate designator from an unsupported side, so a surface that reported
	# the kind would name every gate identically.
	check("2e: the refusal is not reported as the bare family kind",
		str(verb.get("error", "")) != "assembly", str(verb.get("error", "")))
	check_eq("2e: the component is named", str(verb.get("component", "")), "U1S")
	check_eq("2e: …and the field", str(verb.get("field", "")), "assembly.placements")

	# 2f: the BLOCKED preflight the worker built rides through, so the report a
	# person would have read out of preflight.json is on screen even though no
	# package exists to read it from.
	var blockers: Array = verb.get("blockers", [])
	check_eq("2f: the blocked preflight rides the refusal", blockers.size(), 1)
	if blockers.size() == 1:
		check_eq("2f: …naming the same code",
			str((blockers[0] as Dictionary).get("code", "")),
			"assembly_duplicate_designator")
	check_eq("2f: readiness reports the package was NOT generated",
		bool((verb.get("readiness", {}) as Dictionary).get("package_generated", true)),
		false)

	# 2g: a refusal writes nothing, on every doorway — the worker was asked, and
	# nothing here invented a file.
	check("2g: no package directory appeared",
		not DirAccess.dir_exists_absolute(
			_scratch_dir().path_join("parity-board-jlcpcb-economic")))


# ── 3: ONE success, ONE package ─────────────────────────────────────────────

func _run_one_success_one_package() -> void:
	print("\n-- 3: one success, one package --")
	var rig := _rig(_passing_reply())
	var panel = rig["panel"]
	var package_index := PcbExport.index_of("jlcpcb-economic")

	await panel._on_export_menu_id_pressed(
		int(_export_menu_rows(panel)[PcbExport.label_at(package_index)]))
	var button_status := str(panel._status_label.text)
	var verb: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_board_export", {})

	check_eq("3a: the verb succeeded", bool(verb.get("success", false)), true)
	check_eq("3a: …naming the package directory the worker named",
		str(verb.get("directory", "")), "parity-board-jlcpcb-economic")
	check("3a: the button's status line names the same directory",
		button_status.contains("parity-board-jlcpcb-economic"), button_status)

	# 3b: with no `exporter` argument the verb runs what the Export menu names —
	# what pressing it right now would do, which is the whole point of the
	# default. The selection moved to the package exporter above.
	check_eq("3b: an omitted exporter follows the menu's selection",
		str(verb.get("exporter", "")), "jlcpcb-economic")
	check_eq("3b: …and the toolbar shows that selection without being opened",
		_export_menu_checked(panel), PcbExport.label_at(package_index))
	check_eq("3b: …and reports it as layout data, for an agent with no screenshot",
		str(panel.get_layout_state().get("selected_exporter", "")), "jlcpcb-economic")

	# 3c: readiness is reported as three claims and only two are made here.
	var readiness: Dictionary = verb.get("readiness", {})
	check_eq("3c: package_generated is claimed",
		bool(readiness.get("package_generated", false)), true)
	check_eq("3c: preflight_status is reported",
		str(readiness.get("preflight_status", "")), "advisories")
	check("3c: order_page_verified is NOT claimed",
		readiness.get("order_page_verified", "unset") == null,
		str(readiness.get("order_page_verified", "unset")))

	# 3d: the honest-outcome lists reach the agent, not just the human.
	check_eq("3d: advisories reach the verb", (verb.get("advisories", []) as Array).size(), 1)
	var profile_unchecked := _profile_unchecked()
	check("3d: the shipped profile publishes rules nothing looks at",
		not profile_unchecked.is_empty(), PROFILE_PATH)
	check_eq("3d: unchecked rules reach the verb",
		(verb.get("unchecked_rules", []) as Array).size(), profile_unchecked.size())
	check_eq("3d: ip questions reach the verb",
		(verb.get("ip_questions", []) as Array).size(), 1)

	# 3e: the exporters are discoverable from any reply, so an agent never has
	# to guess an id or call a second verb to learn them.
	check_eq("3e: the reply lists the exporters",
		str(verb.get("exporters", PackedStringArray())), str(PcbExport.ids()))


# ── 4: the CHOICE reaches the worker ────────────────────────────────────────

func _run_the_choice_reaches_the_worker() -> void:
	print("\n-- 4: the chosen exporter reaches the worker --")
	var rig := _rig(_passing_reply())
	var panel = rig["panel"]
	var ipc: FakeIPC = rig["ipc"]

	for exporter_id in ["jlc", "jlcpcb-economic"]:
		ipc.captured.clear()
		var _out: Dictionary = await PcbExport.run(panel, str(exporter_id))
		var last: Dictionary = ipc.last_request()
		check_eq("4a: %s rides the one order-package channel" % exporter_id,
			str(last.get("channel", "")), CHANNEL)
		check_eq("4a: …carrying its own service profile",
			str((last.get("payload", {}) as Dictionary).get("profile", "")),
			str(exporter_id))

	# 4b: an exporter nobody offers refuses by name and says what IS offered,
	# rather than falling back to a default the caller did not ask for.
	var unknown: Dictionary = await PcbExport.run(panel, "oshpark-economic")
	check_eq("4b: an unknown exporter refuses",
		bool(unknown.get("ok", true)), false)
	check_eq("4b: …by name", str(unknown.get("error", "")), "unknown_exporter")
	check("4b: …listing the known exporters",
		str(unknown.get("message", "")).contains("jlcpcb-economic"),
		str(unknown.get("message", "")))

	# 4c: the YAML exporter does NOT ride the package channel — it is the
	# serializer, and a chooser that quietly sent everything one way would make
	# the choice cosmetic.
	ipc.captured.clear()
	var _yaml: Dictionary = await PcbExport.run(panel, "yaml")
	check_eq("4c: the YAML exporter rides pcb.serialize",
		str(ipc.last_request().get("channel", "")), "pcb.serialize")


# ── 4b: an oversized board changes the TRANSPORT and nothing else ───────────
#
# The panel means to send the live board inline and sends no source_path, and
# the manifest is supposed to record that no repository speaks for it. But
# worker_check routes any payload over panel_tools' cap through the
# by-reference wrapper, which deletes the board key and substitutes a path to an
# ephemeral snapshot under the user data directory. A worker that read the basis
# off the presence of a path would therefore stamp evidence on every real-sized
# board — and if that directory sat inside any repository, lend its HEAD to this
# design. This is the size at which that happens; sections 2-4 run under the cap
# and cannot see it.

func _run_an_oversized_board_still_asserts_nothing() -> void:
	print("\n-- 4b: an oversized board changes the transport, not the claim --")
	var rig := _rig(_passing_reply())
	var panel = rig["panel"]
	var ipc: FakeIPC = rig["ipc"]
	panel.get_data().from_board_dict(_over_cap_board())

	ipc.captured.clear()
	var _out: Dictionary = await PcbExport.run(panel, "jlcpcb-economic")
	var sent: Dictionary = ipc.last_request().get("payload", {})

	check("4b-i: the board is big enough to take the by-reference arm",
		not sent.has("board") and sent.has("board_path"), str(sent.keys()))
	check("4b-ii: …the snapshot is digest-bound",
		str(sent.get("board_digest", "")).length() == 64,
		str(sent.get("board_digest", "")))
	# THE ASSERTION THAT MATTERS. The exporter declares no source of record, and
	# the transport is not a party that can declare one on its behalf.
	check("4b-iii: …and no source of record is declared for it",
		not sent.has("source_path"), str(sent.keys()))


# ── 5: the destination refusal, identical on both paths ─────────────────────

func _run_destination_refusal_parity() -> void:
	print("\n-- 5: no destination refuses the same way on both paths --")
	var rig := _rig(_passing_reply())
	var panel = rig["panel"]
	var ipc: FakeIPC = rig["ipc"]
	# A board that was never adopted from a canonical file has no implicit
	# destination — the same state promote() refuses no_target_path for.
	panel._canonical_source_path = ""
	ipc.captured.clear()

	var direct: Dictionary = await PcbExport.run(panel, "jlcpcb-economic")
	var verb: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_board_export", {"exporter": "jlcpcb-economic"})

	check_eq("5a: the panel path refuses by name",
		str(direct.get("error", "")), "no_output_directory")
	check_eq("5b: the tool path refuses under the SAME name",
		str(verb.get("error", "")), str(direct.get("error", "")))
	check_eq("5c: neither reached the worker", ipc.captured.size(), 0)

	# 5d: an explicit out_dir clears it — the refusal is about an ABSENT
	# destination, not about the exporter.
	ipc.captured.clear()
	var named: Dictionary = await PanelTools.handle(rig["host"],
		"minerva_pcb_board_export",
		{"exporter": "jlcpcb-economic", "out_dir": _scratch_dir()})
	check_eq("5d: an explicit out_dir exports", bool(named.get("success", false)), true)
	var sent: Dictionary = ipc.last_request().get("payload", {})
	check_eq("5d: …and it is the directory that was asked for",
		str(sent.get("out_dir", "")), _scratch_dir())


# ── 6: the report names findings PER COMPONENT ──────────────────────────────
#
# Including the compile warnings. The worker has carried them on every assembly
# reply since the single-compilation cutover and nothing drew them, which made
# a warning about the very board in the envelope invisible to the only person
# who could act on it.

func _run_named_per_component_report() -> void:  # coroutine: awaits a refusal
	print("\n-- 6: findings are named, per component --")
	var passing: Dictionary = _passing_reply()["result"]["result"]
	var result := {
		"ok": true, "exporter": "jlcpcb-economic",
		"exporter_label": PcbExport.label_at(PcbExport.index_of("jlcpcb-economic")),
		"kind": "package", "directory": str(passing["directory"]),
		"out_dir": "/tmp", "blockers": [],
		"advisories": passing["advisories"], "warnings": passing["warnings"],
		"unchecked_rules": passing["unchecked_rules"],
		"ip_questions": passing["ip_questions"],
		"readiness": passing["readiness"], "outputs": passing["outputs"],
	}
	var report := "\n".join(PcbExport.report_lines(result))

	check("6a: an advisory names its component",
		report.contains("assembly_anchor_unmeasured") and report.contains("J2"), report)
	check("6b: a compile warning is RENDERED at all",
		report.contains("captured_geometry_not_emitted"), report)
	check("6b: …named to the component it is about",
		PcbExport.finding_line(passing["warnings"][0]).contains("U1"),
		PcbExport.finding_line(passing["warnings"][0]))
	check("6b: …and kept out of the advisories, which it is not",
		report.contains("WARNINGS — what the compiler and the emitter said"), report)
	# 6c: the unchecked section is where a shape mismatch hides. The entries are
	# {id, reason} — NOT the {code, message} every other finding carries — so a
	# renderer reading only code/message prints a bullet with both halves blank
	# and the section still has the right heading and the right count. Both
	# halves of the FIRST entry are asserted, off the shipped profile.
	var first_unchecked: Dictionary = _profile_unchecked()[0]
	check("6c: what nothing looked at is named",
		report.contains(str(first_unchecked["id"])), report)
	check("6c: …and says WHY nobody looked, not a blank bullet",
		report.contains(str(first_unchecked["reason"]).substr(0, 40)), report)
	check("6d: the IP question is stated",
		report.contains("licence_undeclared"), report)
	check("6e: order_page_verified is shown as unrecorded, not as a failed check",
		report.contains("order_page_verified: not recorded"), report)

	# 6f: a refusal report leads with the refusal and names the blocked
	# component, so the first line a person reads is what to fix.
	var refused: Dictionary = await PcbExport.run(null, "jlcpcb-economic")
	check_eq("6f: a panel-less run refuses", bool(refused.get("ok", true)), false)
	var refused_report := "\n".join(PcbExport.report_lines(refused))
	check("6f: the refusal report leads with REFUSED",
		refused_report.contains("REFUSED: no_panel"), refused_report)

	# 6g: a clean package needs no dialog; a refusal always gets one.
	check_eq("6g: a clean package raises no report",
		PcbExport.has_report({"ok": true, "kind": "package"}), false)
	check_eq("6g: a package with advisories does",
		PcbExport.has_report(result), true)
	# 6g: and a package whose ONLY finding is the unchecked list does too. Every
	# package carries one — uploader acceptance and licence compatibility are
	# unconditional — so a predicate that ignored it suppressed the report on
	# exactly the exports a person is most likely to over-trust.
	check_eq("6g: unchecked rules alone raise a report",
		PcbExport.has_report({"ok": true, "kind": "package",
			"unchecked_rules": _profile_unchecked()}), true)
	check_eq("6g: a refusal always does", PcbExport.has_report(refused), true)


# ── 7: the YAML exporter is still itself ────────────────────────────────────
#
# It is now one row in a chooser rather than the whole affordance. Its
# behaviour must not have moved: it writes nothing, and it says what it has
# always said.

func _run_yaml_exporter_unchanged() -> void:
	print("\n-- 7: the YAML exporter is unchanged --")
	var rig := _rig({"success": true, "result": {"ok": true,
		"result": {"yaml": "name: parity-board\n"}}})
	var panel = rig["panel"]
	await panel._on_export_menu_id_pressed(
		int(_export_menu_rows(panel)[PcbExport.label_at(PcbExport.YAML_INDEX)]))
	check("7a: the Export menu's YAML row still reports the byte count",
		str(panel._status_label.text).contains("YAML exported ("),
		str(panel._status_label.text))

	var verb: Dictionary = await PanelTools.handle(
		rig["host"], "minerva_pcb_board_export", {"exporter": "yaml"})
	check_eq("7b: the verb reaches the same exporter",
		bool(verb.get("success", false)), true)
	check_eq("7b: …returning the document",
		str(verb.get("yaml", "")), "name: parity-board\n")
	check_eq("7b: …labelled a draft", bool(verb.get("draft", false)), true)

	# 7c: the View menu's YAML row runs the same exporter as the toolbar's.
	var rows := _view_menu_export_rows(panel)
	await panel._on_view_menu_id_pressed(
		int(rows[PcbExport.label_at(PcbExport.YAML_INDEX)]))
	check("7c: the View menu's YAML row exports YAML",
		str(panel._status_label.text).contains("YAML exported ("),
		str(panel._status_label.text))
	check_eq("7c: …and moved the toolbar's selection with it",
		str(panel.selected_exporter_id()), "yaml")
	check_eq("7c: …visibly, on the toolbar's own radio check",
		_export_menu_checked(panel), PcbExport.label_at(PcbExport.YAML_INDEX))
