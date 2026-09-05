extends SceneTree
## The two things every cad MCP call goes through: WHICH panel, and HOW BIG.
##
## ADDRESSING. minerva_create_plugin_editor hands its caller an editor_name and
## the skill tells the caller to use it. The scene-panel broker, though, keys
## its registry on the manifest's panel name — one entry for the whole plugin —
## so a tab opened under its own title is not in it, and a second CAD editor
## would answer for the first. The dispatcher's other resolution path is the
## AnnotationHostRegistry, which IS keyed on the tab title and holds one host
## per panel; it asks that host for its panel. This suite drives the host's
## own dispatcher against two real CADPanel scenes under two titles.
##
## SIZE. The interference report carries a records digest — one line per
## reference NODE, naming the mesh and the pose the rays were cast against. The
## panel needs it whole: the clearance join refuses a report about references
## that have since moved by comparing it. A reader never compares it with
## anything but another reply's copy, and on a populated board it is five
## kilobytes on every doc_write. So the wire carries a hash of it.
##
## ORACLE for the size half: the reply's own bytes, measured against a
## reference set the size of the board the HITL session used (45 nodes). The
## suite asserts the premise first — that the full digest really is thousands
## of characters — so a fixture that quietly shrank could not pass it.
##
## Run:
##   scripts/run-gd-tests.sh --plugin cad <path-to-minerva-checkout>

const PANEL_SCENE_PATH := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const ToolRegistryScript := preload("res://Scripts/Services/Plugins/PluginToolRegistry.gd")
const EvalReply := preload("res://../../minerva-plugins/cad/ui/scripts/eval_reply.gd")
const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")

## Two anonymous editors, named as a user would name them.
const FIRST_TITLE := "HITL enclosure"
const SECOND_TITLE := "Second enclosure"

## Nodes in the reference the size assertion is made against — the board the
## HITL session mounted.
const BOARD_NODES := 45
## What a doc_write reply may cost, in bytes. Roughly the DSL source it is
## answering about; anything larger is the reply talking about itself.
const REPLY_BUDGET_BYTES := 2048

var _pass: int = 0
var _fail: int = 0


class _EditorStub extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== CAD MCP Boundary Test (which panel, and how big) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s — %s" % [label, detail])


func _run() -> void:
	await _check_addressing()
	_check_reply_size()


# ---------------------------------------------------------------------------
# Which panel
# ---------------------------------------------------------------------------

func _check_addressing() -> void:
	var first := _panel_titled(FIRST_TITLE)
	var second := _panel_titled(SECOND_TITLE)
	check("setup: two CAD panels instantiate and load",
			first != null and second != null,
			"could not instantiate %s twice" % PANEL_SCENE_PATH)
	if first == null or second == null:
		return
	await process_frame

	var first_host = AnnotationHostRegistry.get_host(FIRST_TITLE)
	var second_host = AnnotationHostRegistry.get_host(SECOND_TITLE)
	check("each panel registers its own host under its OWN tab title",
			first_host != null and second_host != null and first_host != second_host,
			"hosts = %s / %s" % [str(first_host), str(second_host)])

	# Exactly what PluginToolRegistry's fallback does with the name.
	check("and that host answers with the panel behind it, so a tab title "
			+ "addresses ONE editor — the two titles are not the same panel",
			first_host != null and second_host != null
				and first_host.has_method("get_panel")
				and first_host.get_panel() == first
				and second_host.get_panel() == second,
			"resolved %s / %s" % [
				str(first_host.get_panel()) if first_host != null else "<none>",
				str(second_host.get_panel()) if second_host != null else "<none>"])

	# The dispatcher itself, not a stand-in for it: the same call the MCP verb
	# makes, addressed by the name minerva_create_plugin_editor returned.
	var registry = ToolRegistryScript.new()
	var reply: Dictionary = await registry._handle_panel_tool_call(
		"cad", "minerva_cad_references", {"editor_name": FIRST_TITLE})
	check("the panel-tool dispatcher answers a cad verb addressed by the tab "
			+ "title, rather than refusing a name it lists as known",
			not str(reply.get("error_code", "")) == "editor_not_found"
				and not reply.is_empty(),
			"reply = %s" % str(reply))

	first.free()
	second.free()


## A real CADPanel, loaded as the host loads it, under `title`.
func _panel_titled(title: String) -> Node:
	var packed: PackedScene = load(PANEL_SCENE_PATH)
	if packed == null:
		return null
	var panel: Node = packed.instantiate()
	if panel == null:
		return null
	root.add_child(panel)
	var editor := _EditorStub.new()
	editor.tab_title = title
	panel._on_panel_loaded({
		"plugin_id": "cad",
		"panel_name": "cad_panel",
		"host_api_version": "1",
		"editor": editor,
	})
	return panel


# ---------------------------------------------------------------------------
# How big
# ---------------------------------------------------------------------------

func _check_reply_size() -> void:
	var digest := _board_digest()
	check(("fixture: the full records digest of a %d-node board really is "
			+ "thousands of characters — the cost being measured") % BOARD_NODES,
			digest.length() > 2000, "digest is %d characters" % digest.length())

	var last_eval := _clean_eval(digest)
	var rendered: Dictionary = EvalReply.last_eval_for_mcp(last_eval)
	var bytes := JSON.stringify(rendered).to_utf8_buffer().size()
	check(("a doc_write reply about a %d-node reference with no interference "
			+ "fits %d bytes") % [BOARD_NODES, REPLY_BUDGET_BYTES],
			bytes < REPLY_BUDGET_BYTES, "reply is %d bytes" % bytes)

	var short := str((rendered["interference"] as Dictionary).get("records_digest", ""))
	check("what it carries instead is 16 hex characters",
			short.length() == EvalReply.SHORT_DIGEST_CHARS
				and short.is_valid_hex_number(),
			"rendered digest = '%s'" % short)
	check("and it still tells one reference set from another, which is the "
			+ "only thing a reader asks it",
			EvalReply.short_digest(digest) != EvalReply.short_digest(digest + "x"),
			"two digests hashed alike")
	check("the panel keeps the whole digest: the clearance join compares it "
			+ "against the poses it is about to measure",
			str((last_eval["interference"] as Dictionary)
				.get("records_digest", "")) == digest,
			"the panel's own report was rewritten")


## The records digest of a board with BOARD_NODES nodes, built the way the
## panel builds it so the fixture measures the real string.
func _board_digest() -> String:
	var box := BoxMesh.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	var parts: Array = []
	for index in range(BOARD_NODES):
		parts.append({
			"mesh": mesh,
			"transform": Transform3D(Basis.IDENTITY, Vector3(index, 0.0, 0.0)),
			"node_path": "board_mm/C%d" % index,
			"node": "board_mm/C%d" % index,
		})
	var records := [{
		"name": "board",
		"pose": Transform3D.IDENTITY,
		"parts": parts,
	}]
	return MeshGauge.bodies_digest(MeshGauge.bodies_from_records(records))


## The panel's own last_eval after a clean evaluation: the real report shape,
## stamped as the check stamps it.
func _clean_eval(digest: String) -> Dictionary:
	var checks: RefCounted = GeometryChecks.new()
	var report: Dictionary = checks._report({})
	report["source_digest"] = digest
	report["records_digest"] = digest
	report["gauge_generation"] = 3
	return {
		"status": "ok",
		"shape_name": "enclosure",
		"body_count": 1,
		"vertex_count": 4212,
		"edge_count": 318,
		"reference_count": 1,
		"references": [{"name": "board", "state": "mounted", "nodes": BOARD_NODES}],
		"request_id": "eval_sync_1",
		"ts": 1757000000.0,
		"interference": report,
	}
