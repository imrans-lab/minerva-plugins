extends MinervaPluginPanel
## PCB editor panel — walking-skeleton vertical slice.
##
## The smallest slice that touches every plugin↔substrate seam so unknown gaps
## surface before the ~7 KLOC PCBEditor port. THROWAWAY quality is acceptable;
## durable geometry, tools, and worker land in later rounds.
##
## What this panel does:
##   * Renders a crude 2D board: component rectangles with reference designators.
##   * Owns a PcbAnnotationHost (get_annotation_host() → the platform dock/overlay
##     mounts around us) so ONE pcb_route_hint can be authored via the dock.
##   * Persists the board via host_owned save (_on_panel_save_request/_load) and
##     the annotations to the platform sidecar (<file>.annotations.json).
##
## Off-tree class_name gotcha: this plugin lives OUTSIDE Minerva's res:// tree,
## so plugin-local class_names are unresolvable. This script declares NO
## class_name and preloads its siblings by relative path. It extends the CORE
## base MinervaPluginPanel (in res://, resolvable).

const _PcbAnnotationHostScript: Script = preload("PcbAnnotationHost.gd")

## Board mm → screen px scale, and board origin offset, for the crude renderer.
const _SCALE: float = 4.0
const _ORIGIN := Vector2(40.0, 40.0)

## Default skeleton board handed to a fresh (anonymous) editor.
const _DEFAULT_BOARD := {
	"width_mm": 60.0,
	"height_mm": 40.0,
}
const _DEFAULT_COMPONENTS := [
	{"ref": "U1", "x": 8.0,  "y": 8.0,  "w": 16.0, "h": 16.0},
	{"ref": "R1", "x": 34.0, "y": 6.0,  "w": 8.0,  "h": 4.0},
	{"ref": "C1", "x": 34.0, "y": 16.0, "w": 6.0,  "h": 6.0},
	{"ref": "J1", "x": 6.0,  "y": 30.0, "w": 20.0, "h": 6.0},
]

var _annotation_host: AnnotationHost = null

## Editor tab name under which we registered the host (for symmetric teardown).
var _registered_editor_name: String = ""

## Absolute board file path (host_owned). Empty for anonymous editors.
var _file_path: String = ""

## Board state, round-tripped by save/load.
var _board: Dictionary = {}
var _components: Array = []

## The crude board renderer (custom-drawn Control child).
var _board_canvas: Control = null

## True while restoring persisted state (load_sidecar re-emits
## annotations_changed); suppresses the content_changed dirty relay.
var _restoring := false


func _init() -> void:
	# Build the host eagerly so get_annotation_host() is valid the instant the
	# platform queries it during mount (before _on_panel_loaded fires).
	_annotation_host = _PcbAnnotationHostScript.new()
	# Annotations are unsaved panel state until the sidecar is written on save
	# request, so mutations must flip the tab's unsaved glyph via the
	# MinervaPluginPanel.content_changed contract (gap register W-14).
	# Gated by _restoring: load_sidecar emits the same signal (the dock/overlay
	# refresh off it), and restoring saved state must not mark the tab dirty.
	_annotation_host.annotations_changed.connect(func() -> void:
		if not _restoring:
			content_changed.emit())
	_board = _DEFAULT_BOARD.duplicate(true)
	_components = _DEFAULT_COMPONENTS.duplicate(true)


func get_annotation_host() -> RefCounted:
	return _annotation_host


func _on_panel_loaded(ctx: Dictionary) -> void:
	# Build the crude board canvas.
	_board_canvas = Control.new()
	_board_canvas.name = "BoardCanvas"
	_board_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	_board_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_board_canvas.draw.connect(_on_board_canvas_draw)
	add_child(_board_canvas)
	_board_canvas.queue_redraw()

	# Register the host under the editor tab title so MCP annotation tools
	# (minerva_annotations_query / _render_overlay) can reach it by editor_name.
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name

	# Capture the file path (for sidecar resolution).
	_file_path = str(ctx.get("file_path", ""))
	if not _file_path.is_empty() and _annotation_host != null:
		_annotation_host.set_document_path(_file_path)


func _on_panel_unload() -> void:
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""


# ── host_owned save/load (board doc + annotation sidecar) ─────────────────────

## Return the board's save state. Ctrl+S writes this Dict to the .pcbskel file as
## JSON (Editor.gd host_owned path). We ALSO flush annotations to the sidecar
## here — the platform does not auto-persist plugin-panel annotation sidecars
## (gap register C-15), so the panel owns that write.
func _on_panel_save_request() -> Dictionary:
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.save_sidecar(_file_path)
	return {
		"version": 1,
		"kind": "pcbskel_board",
		"board": _board.duplicate(true),
		"components": _components.duplicate(true),
	}


## Restore board state previously returned by _on_panel_save_request.
##
## Load shapes (Editor.gd:1108 JSON-parses host_owned files). The host ALWAYS
## includes `file_path` (Editor.gd:1117) — in BOTH shapes:
##   1. JSON doc merged as a dict → {file_path, version, kind, board, components}.
##   2. Non-JSON → {file_path, raw_text}. We parse the body ourselves
##      (defensive; the skeleton board file is always JSON).
func _on_panel_load_request(document: Dictionary) -> void:
	var doc := document
	# Capture file_path regardless of shape — the JSON branch previously
	# dropped it, so live saves never knew where to write the sidecar (W-15).
	var doc_path := str(document.get("file_path", ""))
	if not doc_path.is_empty():
		_file_path = doc_path
	# Raw-text shape: parse the body ourselves.
	if document.has("raw_text") and not document.has("board"):
		var parsed: Variant = JSON.parse_string(str(document.get("raw_text", "")))
		if parsed is Dictionary:
			doc = parsed as Dictionary
		else:
			doc = {}

	if doc.has("board") and doc["board"] is Dictionary:
		_board = (doc["board"] as Dictionary).duplicate(true)
	if doc.has("components") and doc["components"] is Array:
		_components = (doc["components"] as Array).duplicate(true)

	# Load the annotation sidecar for this board file. Restored annotations are
	# saved state, not edits — suppress the dirty relay while loading.
	if _annotation_host != null and not _file_path.is_empty():
		_annotation_host.set_document_path(_file_path)
		_restoring = true
		_annotation_host.load_sidecar(_file_path)
		_restoring = false

	if _board_canvas != null:
		_board_canvas.queue_redraw()


# ── Crude board renderer ──────────────────────────────────────────────────────

func _on_board_canvas_draw() -> void:
	if _board_canvas == null:
		return
	var font: Font = ThemeDB.fallback_font

	# Board outline.
	var bw := float(_board.get("width_mm", 60.0)) * _SCALE
	var bh := float(_board.get("height_mm", 40.0)) * _SCALE
	var board_rect := Rect2(_ORIGIN, Vector2(bw, bh))
	_board_canvas.draw_rect(board_rect, Color(0.10, 0.22, 0.14, 1.0), true)
	_board_canvas.draw_rect(board_rect, Color(0.30, 0.70, 0.45, 1.0), false, 2.0)

	# Components: rectangle + reference designator.
	for comp in _components:
		if not comp is Dictionary:
			continue
		var c: Dictionary = comp
		var pos := _ORIGIN + Vector2(float(c.get("x", 0.0)), float(c.get("y", 0.0))) * _SCALE
		var size := Vector2(float(c.get("w", 4.0)), float(c.get("h", 4.0))) * _SCALE
		var rect := Rect2(pos, size)
		_board_canvas.draw_rect(rect, Color(0.18, 0.20, 0.26, 1.0), true)
		_board_canvas.draw_rect(rect, Color(0.70, 0.75, 0.85, 1.0), false, 1.0)
		if font != null:
			var ref := str(c.get("ref", "?"))
			_board_canvas.draw_string(
				font, pos + Vector2(3.0, 13.0), ref,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.92, 0.95, 0.98, 1.0))
