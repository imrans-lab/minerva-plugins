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
## The dispatcher is loaded at RUN time, not preloaded. `godot --script` loads
## a suite twice, the first time before the host's autoloads register, and a
## const preload of a host script that names SingletonObject compiles — and
## fails — in that first pass. The failure is cached, so the host's own
## PluginManager.new() then fails as it starts up, which is host state this
## suite has no business breaking.
const TOOL_REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"
const EvalReply := preload("res://../../minerva-plugins/cad/ui/scripts/eval_reply.gd")
const PanelTools := preload("res://../../minerva-plugins/cad/ui/panel_tools.gd")
const ReplyShape := preload("res://../../minerva-plugins/cad/ui/scripts/reply_shape.gd")
const FastenerChecks := preload("res://../../minerva-plugins/cad/ui/scripts/fastener_checks.gd")
const GeometryChecks := preload("res://../../minerva-plugins/cad/ui/scripts/geometry_checks.gd")
const MeshGauge := preload("res://../../minerva-plugins/cad/ui/scripts/mesh_gauge.gd")

## Two anonymous editors, named as a user would name them.
const FIRST_TITLE := "HITL enclosure"
const SECOND_TITLE := "Second enclosure"
## A third, for the edge-listing size question.
const EDGE_TITLE := "Edge listing"

## The edge registry the size assertion is made against: an enclosure's edge
## count, each edge sampled the way a curved one is.
const REGISTRY_EDGES := 700
const REGISTRY_POLYLINE_POINTS := 24

## Nodes in the reference the size assertion is made against — the board the
## HITL session mounted.
const BOARD_NODES := 45
## What a doc_write reply may cost, in bytes. Roughly the DSL source it is
## answering about; anything larger is the reply talking about itself.
const REPLY_BUDGET_BYTES := 2048
## What a LEAN reply may cost on that same board, in bytes: the reference
## listing an agent reads five times while sizing one part, and a clearance
## report narrowed to the pairs it is about to act on.
const REFERENCES_LEAN_BUDGET_BYTES := 768
const CLEARANCE_LIMITED_BUDGET_BYTES := 3072
## Pairs in the clearance fixture — the report shape measured on the real board.
const BOARD_PAIRS := 50

## Stands in for the document the report is about. Its digest is a fixed
## sixty-four characters, so the reply's size is the reference set's cost.
const SOURCE := "box(40, 30, 10)"

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
	_check_interference_is_a_status_line()
	await _check_references_are_lean_by_default()
	await _check_clearance_can_be_narrowed()
	_check_obstructions_collapse()
	_check_reference_holes_are_indexed_as_paired()
	_check_a_hole_census_becomes_dsl()
	await _check_await_eval_reports_what_the_panel_painted()
	await _check_the_edge_listing_carries_no_drawing()


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
	var registry = (load(TOOL_REGISTRY_PATH) as GDScript).new()
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
# How big — the edge listing
# ---------------------------------------------------------------------------

## Every registry edge carries its own sampled polyline so the panel can draw
## it. The host copy is read by cad_list_edges_live / cad_get_edge, which the
## modeling skill has an agent call before an authoring turn, so those points
## would be paid for on every one of those calls.
##
## ORACLE: the fixture's own size. The listing a reader gets is asserted
## against the registry the panel was handed — an implementation that passed
## the array through cannot be within a fraction of it — while the caller's own
## array is asserted to still have the points, so stripping in place (which
## would blank the outline) fails too.
func _check_the_edge_listing_carries_no_drawing() -> void:
	var panel := _panel_titled(EDGE_TITLE)
	check("setup: a panel for the edge-listing question",
			panel != null, "could not instantiate %s" % PANEL_SCENE_PATH)
	if panel == null:
		return
	await process_frame
	var host = AnnotationHostRegistry.get_host(EDGE_TITLE)
	check("setup: it registered a host", host != null)
	if host == null:
		panel.free()
		return

	var registry := _sampled_registry()
	var drawable_bytes := JSON.stringify(registry).to_utf8_buffer().size()
	check(("fixture: a %d-edge registry sampled for drawing really is the "
			+ "cost being measured — over a hundred kilobytes")
			% REGISTRY_EDGES,
			drawable_bytes > 100000, "registry is %d bytes" % drawable_bytes)

	host.set_edge_registry(registry)
	var listed: Array = host.get_edge_registry()
	var listed_bytes := JSON.stringify(listed).to_utf8_buffer().size()
	var with_points: int = 0
	for entry in listed:
		if (entry as Dictionary).has("polyline"):
			with_points += 1
	check("what a reader gets back is the same edges without the points",
			listed.size() == registry.size() and with_points == 0,
			"%d of %d entries still carry points" % [with_points, listed.size()])
	check("which costs a fraction of the drawable registry",
			listed_bytes * 5 < drawable_bytes,
			"listing is %d bytes against %d" % [listed_bytes, drawable_bytes])
	check("and still answers what an edge IS: its id, kind and both ends, "
			+ "which is what an anchor and a fillet call read",
			(listed[0] as Dictionary).has("id")
				and (listed[0] as Dictionary).has("kind")
				and (listed[0] as Dictionary).has("start")
				and (listed[0] as Dictionary).has("end"),
			"first entry = %s" % str(listed[0]))
	var caller_points: Array = (registry[0] as Dictionary).get("polyline", [])
	check("the panel's own copy keeps the points: they are the outline it "
			+ "draws, and stripping them in place would empty the panes",
			caller_points.size() == REGISTRY_POLYLINE_POINTS,
			"caller's first entry has %d points" % caller_points.size())

	panel.free()


## An edge registry the shape the worker returns one, every edge sampled.
func _sampled_registry() -> Array:
	var edges: Array = []
	for id in range(REGISTRY_EDGES):
		var polyline: Array = []
		for step in range(REGISTRY_POLYLINE_POINTS):
			var angle := TAU * float(step) / float(REGISTRY_POLYLINE_POINTS)
			polyline.append([cos(angle) * 12.5, sin(angle) * 12.5, float(id)])
		edges.append({
			"id": id,
			"kind": "circle",
			"start": polyline[0],
			"end": polyline[-1],
			"radius": 12.5,
			"center": [0.0, 0.0, float(id)],
			"polyline": polyline,
		})
	return edges


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
	# WHICH SOLID, not which references: the panel stamps this one with the
	# SHA-256 of the DSL source, sixty-four characters whatever the board is.
	# The per-node list is the records digest below, and it is the only field
	# whose size grows with the assembly.
	report["source_digest"] = _source_digest(SOURCE)
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


## The panel's own source stamp: the SHA-256 of the DSL text, hex.
func _source_digest(source: String) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(source.to_utf8_buffer())
	return hasher.finish().hex_encode()


# ---------------------------------------------------------------------------
# How big, verb by verb
#
# Each case below is the same shape: build the reply a real board produces,
# assert the FULL form really is the cost measured on the real board (a fixture
# that quietly shrank could not pass), then assert the shaped form fits its
# budget AND still carries the answer. Leanness that dropped the answer would
# pass a size assertion on its own, so no case is only a size assertion.
# ---------------------------------------------------------------------------

## The interference report rides in every last_eval. On a board where the
## shell crosses several nodes it is the whole size of the reply, and an
## agent polling "did my edit land" reads the status and nothing else.
func _check_interference_is_a_status_line() -> void:
	var report := _crossing_report(12, 8)
	var full_bytes := JSON.stringify(report).to_utf8_buffer().size()
	check("fixture: an interference report naming 12 crossed nodes really is "
			+ "kilobytes — the cost being measured",
			full_bytes > 6000, "report is %d bytes" % full_bytes)

	var last_eval := {"status": "ok", "ts": 1757000000.0, "interference": report}
	var wire: Dictionary = EvalReply.last_eval_for_mcp(last_eval)
	var lean: Dictionary = wire["interference"]
	var lean_bytes := JSON.stringify(wire).to_utf8_buffer().size()
	check("last_eval carries it as a status line inside the doc_write budget",
			lean_bytes < REPLY_BUDGET_BYTES,
			"wire last_eval is %d bytes (full report %d)" % [lean_bytes, full_bytes])
	check("and the status line still answers the question: the check ran, how "
			+ "many nodes were met, how many points, and which nodes",
			bool(lean["checked"]) and int(lean["count"]) == 12
				and int(lean["point_count"]) == 96
				and (lean["nodes"] as Array).size() == 12
				and str((lean["nodes"] as Array)[0]).contains("board"),
			"lean = %s" % str(lean))
	check("the crossing points are NOT in it — they come from "
			+ "minerva_cad_check_interference, which says so",
			not lean.has("pairs") and str(lean.get("detail", "")).contains(
				"minerva_cad_check_interference"),
			"lean = %s" % str(lean))
	var clean: Dictionary = EvalReply.last_eval_for_mcp({"references": [
		{"name": "board", "status": "ok", "warning": ""},
	]})
	var one_missing: Dictionary = EvalReply.last_eval_for_mcp({"references": [
		{"name": "board", "status": "ok", "warning": ""},
		{"name": "lid", "status": "missing", "reason": "no such file"},
	]})
	var kept: Array = one_missing.get("references", []) as Array
	check("a reference that loaded cleanly is not listed at all, and one that "
			+ "failed still is — nothing else in the reply says the board is missing",
			not clean.has("references") and kept.size() == 1
				and str((kept[0] as Dictionary)["name"]) == "lid",
			"clean = %s, missing = %s" % [str(clean), str(one_missing)])


## minerva_cad_references was called five times to size one part. The lean row
## is what makes that affordable, and its size must not grow with the board.
func _check_references_are_lean_by_default() -> void:
	var panel := _ReferenceStandIn.new()
	panel.records = [_board_record(BOARD_NODES)]
	root.add_child(panel)

	var full: Dictionary = await PanelTools.handle(
			panel, "minerva_cad_references", {"detail": "full"})
	var full_bytes := JSON.stringify(full).to_utf8_buffer().size()
	check(("fixture: the full listing of a %d-node board really is the "
			+ "sixteen kilobytes the session measured") % BOARD_NODES,
			full_bytes > 6000, "full listing is %d bytes" % full_bytes)

	var lean: Dictionary = await PanelTools.handle(panel, "minerva_cad_references", {})
	var lean_bytes := JSON.stringify(lean).to_utf8_buffer().size()
	check("the default listing fits %d bytes" % REFERENCES_LEAN_BUDGET_BYTES,
			lean_bytes < REFERENCES_LEAN_BUDGET_BYTES,
			"lean listing is %d bytes (full %d)" % [lean_bytes, full_bytes])

	var lean_row: Dictionary = (lean["references"] as Array)[0]
	check("and it still names the reference, its status, where it is in the "
			+ "world and how many nodes it holds",
			str(lean_row["name"]) == "board" and str(lean_row["status"]) == "ok"
				and int(lean_row["node_count"]) == BOARD_NODES
				and (lean_row["bbox_mm"] as Dictionary).has("world"),
			"lean row = %s" % str(lean_row))

	panel.records = [_board_record(BOARD_NODES * 2)]
	var bigger: Dictionary = await PanelTools.handle(panel, "minerva_cad_references", {})
	var bigger_bytes := JSON.stringify(bigger).to_utf8_buffer().size()
	check("doubling the node count leaves the lean listing the same size — "
			+ "the per-node boxes are what the full form is for",
			absi(bigger_bytes - lean_bytes) <= 4,
			"%d nodes cost %d bytes, %d nodes cost %d"
				% [BOARD_NODES, lean_bytes, BOARD_NODES * 2, bigger_bytes])

	var full_row: Dictionary = (full["references"] as Array)[0]
	check("nothing is lost: detail=\"full\" carries the pose, both frames and "
			+ "every node box",
			(full_row["pose"] as Array).size() == 16
				and (full_row["nodes"] as Array).size() == BOARD_NODES
				and (full_row["bbox_mm"] as Dictionary).has("local"),
			"full row keys = %s" % str(full_row.keys()))

	var missed: Dictionary = await PanelTools.handle(
			panel, "minerva_cad_references", {"reference": "lid"})
	check("a reference= naming nothing is an error listing the ones there are, "
			+ "not an empty scene",
			not bool(missed.get("success", true))
				and str(missed.get("error", "")).contains("board"),
			"reply = %s" % str(missed))
	panel.free()


## Fifty pairs is twenty kilobytes, and an agent acting on the tightest gap
## reads five rows. The filters must not touch the verdict.
func _check_clearance_can_be_narrowed() -> void:
	var panel := _ClearanceStandIn.new()
	panel.report = _clearance_report(BOARD_PAIRS)
	root.add_child(panel)

	var full: Dictionary = await PanelTools.handle(
			panel, "minerva_cad_check_clearance", {"required_mm": 1.0})
	var full_bytes := JSON.stringify(full).to_utf8_buffer().size()
	check(("fixture: a %d-pair clearance report really is kilobytes")
			% BOARD_PAIRS,
			full_bytes > 8000 and (full["pairs"] as Array).size() == BOARD_PAIRS,
			"report is %d bytes, %d pairs"
				% [full_bytes, (full["pairs"] as Array).size()])

	var closest: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_clearance", {"required_mm": 1.0, "limit": 5})
	var closest_bytes := JSON.stringify(closest).to_utf8_buffer().size()
	var kept: Array = closest["pairs"]
	check("limit=5 fits %d bytes" % CLEARANCE_LIMITED_BUDGET_BYTES,
			closest_bytes < CLEARANCE_LIMITED_BUDGET_BYTES,
			"limited report is %d bytes (full %d)" % [closest_bytes, full_bytes])
	check("and keeps the FIVE CLOSEST pairs — the ones an edit is about",
			kept.size() == 5
				and absf(float((kept[0] as Dictionary)["min_mm"]) - 0.1) < 1e-4
				and float((kept[4] as Dictionary)["min_mm"])
					< float((full["pairs"] as Array)[5]["min_mm"]),
			"kept = %s" % str(kept))
	check("the verdict is still graded over every pair, and the reply says how "
			+ "many it did not show",
			bool(closest["pass"]) == bool(full["pass"])
				and int(closest["pairs_total"]) == BOARD_PAIRS
				and int(closest["pairs_shown"]) == 5
				and str(closest.get("pairs_filter", "")).contains("50"),
			"closest = %s" % str(closest.get("pairs_filter", "")))

	var failing: Dictionary = await PanelTools.handle(panel,
			"minerva_cad_check_clearance", {"required_mm": 1.0, "failing_only": true})
	var only_failures := true
	for entry in failing["pairs"]:
		if bool((entry as Dictionary)["pass"]):
			only_failures = false
	check("failing_only drops the pairs that cleared and keeps the ones that "
			+ "did not",
			only_failures and (failing["pairs"] as Array).size() > 0
				and (failing["pairs"] as Array).size() < BOARD_PAIRS,
			"failing = %d of %d"
				% [(failing["pairs"] as Array).size(), BOARD_PAIRS])
	panel.free()


## One rib across a bore is met by every ray of the fan. The reply used to
## carry one row per ray.
func _check_obstructions_collapse() -> void:
	var raw: Array = []
	for index in range(120):
		raw.append({
			"node": "board/rib" if index % 2 == 0 else "board/cap",
			"reference": "board",
			"span": "bore",
			"axial_mm": 2.0 + float(index) * 0.01,
			"point_mm": {"world": [1.0, 2.0, 3.0], "local": [1.0, 2.0, 3.0]},
			"ray_radius_mm": 0.1 * float(index),
			"fan_radius_mm": 1.5,
		})
	var collapsed: Array = ReplyShape.collapse_obstructions(raw)
	check("120 crossings of two nodes collapse to two rows",
			collapsed.size() == 2, "collapsed to %d rows" % collapsed.size())
	var first: Dictionary = collapsed[0]
	check("each row counts the rays that met it and states the axial range "
			+ "they met it over, keeping the NEAREST crossing",
			int(first["count"]) == 60
				and absf(float(first["axial_mm"]) - 2.0) < 1e-6
				and absf(float((first["axial_range_mm"] as Dictionary)["max"])
					- 3.18) < 1e-6,
			"first row = %s" % str(first))


## `pairs` overrides address the check's own hole numbering. A hole with no
## usable axis never enters it, so a list built from the caller's own array
## would name the wrong holes from the first bad one onwards.
func _check_reference_holes_are_indexed_as_paired() -> void:
	var checks: RefCounted = FastenerChecks.new()
	var holes := [
		_hole("board/A", [10.0, 0.0, 0.0], [0.0, 0.0, 1.0]),
		_hole("board/degenerate", [20.0, 0.0, 0.0], [0.0, 0.0, 0.0]),
		_hole("board/B", [30.0, 0.0, 0.0], [0.0, 0.0, 1.0]),
	]
	var pairing: Dictionary = checks._pair([], holes, {})
	var index: Array = pairing["reference_hole_index"]
	check("the index lists only the holes the pairing can address",
			index.size() == 2, "indexed %d of 3 holes" % index.size())
	check("and numbers them the way `pairs` does — index 1 is the hole AFTER "
			+ "the unusable one, with its centre",
			int((index[1] as Dictionary)["index"]) == 1
				and str((index[1] as Dictionary)["node"]) == "board/B"
				and absf(float(((index[1] as Dictionary)["center_mm"]
					as Dictionary)["world"][0]) - 30.0) < 1e-6,
			"index = %s" % str(index))


## Four measured centres, retyped into the DSL, is where a digit gets dropped.
func _check_a_hole_census_becomes_dsl() -> void:
	var holes := [
		_hole("board/A", [10.5, 4.0, 1.0], [0.0, 0.0, 1.0]),
		_hole("board/B", [-3.25, 4.0, 1.0], [0.0, 0.0, 1.0]),
		_hole("board/C", [0.0, 0.0, 0.0], [0.3, 0.4, 0.866]),
	]
	var emitted: Dictionary = ReplyShape.holes_as_dsl(holes, "hole", 0.2, 8.0)
	var dsl := str(emitted["dsl"])
	check("the emitted DSL places one slug at each measured WORLD centre, at "
			+ "the measured radius plus the clearance asked for",
			dsl.contains("cylinder(h = 8.0, r = 1.8, center = true)")
				and dsl.contains("translate([10.5, 4.0, 1.0], slug_1)")
				and dsl.contains("translate([-3.25, 4.0, 1.0], slug_1)")
				and dsl.contains("holes = holes + translate("),
			"dsl:\n%s" % dsl)
	check("a hole whose axis is not square to a world axis is left out and "
			+ "NAMED, rather than written with a guessed rotate()",
			(emitted["skipped"] as Array).size() == 1
				and str((emitted["skipped"] as Array)[0]).contains("board/C")
				and not dsl.contains("board/C"),
			"skipped = %s" % str(emitted["skipped"]))
	var posts: Dictionary = ReplyShape.holes_as_dsl(holes, "post", 0.0, 0.0)
	check("dsl_kind=\"post\" builds cylinders to ADD at the same centres, and "
			+ "the default length comes off the hole's own extent",
			str(posts["dsl"]).contains("posts = translate([10.5, 4.0, 1.0]")
				and str(posts["dsl"]).contains("part = part + posts")
				and str(posts["dsl"]).contains("cylinder(h = 9.0, r = 1.6"),
			"dsl:\n%s" % str(posts["dsl"]))


## A doc_edit on the text tab returns before the debounce has even fired.
func _check_await_eval_reports_what_the_panel_painted() -> void:
	var panel := _AwaitStandIn.new()
	root.add_child(panel)

	panel.settle_after_ms = 250
	panel.status = "pending"
	var settled: Dictionary = await PanelTools.handle(
			panel, "minerva_cad_await_eval", {"timeout_ms": 5000})
	check("the verb waits for the evaluation and returns the status the panel "
			+ "painted, with the time it waited",
			bool(settled.get("success", false))
				and not bool(settled["timed_out"])
				and str((settled["last_eval"] as Dictionary)["status"]) == "ok"
				and int(settled["waited_ms"]) >= 200,
			"reply = %s" % str(settled))

	panel.settle_after_ms = 100000
	panel.status = "pending"
	var gave_up: Dictionary = await PanelTools.handle(
			panel, "minerva_cad_await_eval", {"timeout_ms": 150})
	check("a timeout is not an error: it reports the status the panel is "
			+ "showing now, and says nothing was cancelled",
			bool(gave_up.get("success", false))
				and bool(gave_up["timed_out"])
				and str((gave_up["last_eval"] as Dictionary)["status"]) == "pending"
				and str(gave_up.get("note", "")).contains("cancelled"),
			"reply = %s" % str(gave_up))
	panel.free()


# ---------------------------------------------------------------------------
# Fixtures for the verb-by-verb cases
# ---------------------------------------------------------------------------

## One reference with `nodes` nodes, shaped the way the panel's reference
## report shapes a record.
func _board_record(nodes: int) -> Dictionary:
	var bounds: Array = []
	for index in range(nodes):
		bounds.append({
			"name": "C%d" % index,
			"path": "board_mm/C%d" % index,
			"aabb": AABB(Vector3(index, 0.0, 0.0), Vector3(2.0, 1.0, 0.5)),
		})
	return {
		"name": "board",
		"path": "boards/smart-remote-v2.glb",
		"resolved_path": "/home/owner/boards/smart-remote-v2.glb",
		"status": "ok",
		"reason": "",
		"warning": "",
		"triangle_count": 214000,
		"bytes": 8400000,
		"load_ms": 640,
		"outlines_skipped": true,
		"pose": Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0)),
		"local_aabb": AABB(Vector3.ZERO, Vector3(60.0, 40.0, 1.6)),
		"node_bounds": bounds,
	}


## An interference report crossing `nodes` nodes at `points` points each.
func _crossing_report(nodes: int, points: int) -> Dictionary:
	var checks: RefCounted = GeometryChecks.new()
	var report: Dictionary = checks._report({})
	var pairs: Array = []
	for index in range(nodes):
		var crossing: Array = []
		for point in range(points):
			crossing.append({
				"world": [float(index), float(point), 1.25],
				"local": [float(index), float(point), 0.25],
			})
		pairs.append({
			"reference": "board",
			"node": "board_mm/C%d" % index,
			"points_mm": crossing,
			"point_count": points,
			"penetration_mm": 0.42,
		})
	report["pairs"] = pairs
	report["count"] = nodes
	report["point_count"] = nodes * points
	return report


## A clearance report of `count` pairs, the tightest at 0.1 mm and every
## tenth one failing the 1 mm the fixture asks for.
func _clearance_report(count: int) -> Dictionary:
	var pairs: Array = []
	for index in range(count):
		var gap := 0.1 + float(index) * 0.1
		pairs.append({
			"reference": "board",
			"node": "board_mm/C%d" % index,
			"min_mm": gap,
			"bound_mm": gap - 0.01,
			"pass": gap >= 1.0,
			"solid_point_mm": [float(index), 1.0, 2.0],
			"reference_point_mm": {
				"world": [float(index), 1.0, 2.0 + gap],
				"local": [float(index), 1.0, gap],
			},
		})
	return {
		"checked": true,
		"units": "mm",
		"pass": false,
		"advisory": false,
		"required_mm": 1.0,
		"tessellation_tolerance_mm": 0.01,
		"pairs": pairs,
	}


## A hole row as minerva_cad_find_holes reports one.
func _hole(node: String, centre: Array, axis: Array) -> Dictionary:
	return {
		"reference": "board",
		"node": node,
		"dia_mm": 3.2,
		"extent_mm": 3.0,
		"through": true,
		"center_mm": {"world": centre, "local": centre},
		"axis": {"world": axis, "local": axis},
	}


## Answers minerva_cad_references and nothing else.
class _ReferenceStandIn extends Node:
	var records: Array = []

	func get_reference_status() -> Array:
		return records

	func get_reference_state() -> Array:
		return records

	func get_reference_digest() -> String:
		return "boundary|v1"


## Answers minerva_cad_check_clearance with a canned report: the filters are
## the verb layer's, and this is what they filter.
class _ClearanceStandIn extends Node:
	var report: Dictionary = {}

	func get_reference_digest() -> String:
		return "boundary|v1"

	func check_clearance(_args: Dictionary) -> Dictionary:
		return report.duplicate(true)


## A panel whose evaluation lands after a chosen delay.
class _AwaitStandIn extends Node:
	var status: String = "pending"
	var settle_after_ms: int = 0

	func await_evaluation(timeout_ms: int) -> Dictionary:
		var started := Time.get_ticks_msec()
		var timed_out := false
		while status == "pending":
			if Time.get_ticks_msec() - started >= settle_after_ms:
				status = "ok"
				break
			if Time.get_ticks_msec() - started >= timeout_ms:
				timed_out = true
				break
			await get_tree().create_timer(0.02).timeout
		return {
			"last_eval": {"status": status, "ts": 1757000000.0},
			"timed_out": timed_out,
			"waited_ms": Time.get_ticks_msec() - started,
		}
