extends MinervaPluginPanel
## Nametag editor — a PREVIEW + ANNOTATE surface for the .mtags project (N2).
##
## NOT a data-entry form (feedback_generated_artifact_editors_are_preview_annotate):
## data entry is the LLM's job (it fills a Minerva spreadsheet). This panel shows
## the RENDERED tag(s) — the generated PDF, rasterized with pdftoppm — and lets
## the user annotate drafts on top via the annotation substrate, then iterate.
##
## Render path (rasterize, not CEF — N1 findings): a generated PDF path →
## pdftoppm page N → ImageTexture in a TextureRect. The same rasterized Image is
## handed to the AnnotationHost so render_overlay/AI-vision composites annotations
## over the real tag (closes the N1 vision gap).
##
## Preview source:
##   - PULL: "Refresh" → request.emit("nametag.render", {args_path}, reply_id) →
##     Go backend renders to a temp PDF, returns {path} (N3 adds the handler).
##   - PUSH: an MCP tool renders + sets _doc.preview_pdf_path, then the panel
##     re-renders (N3).
## Until N3's backend handler exists, the panel still displays any PDF named in
## _doc.preview_pdf_path (so a draft can be shown immediately).
##
## Off-tree plugin script: NO class_name; model preloaded relatively.

const Model = preload("nametag_model.gd")

const PREVIEW_DPI := 150
const TMP_DIR := "user://nametag_tmp"

var _doc: Dictionary = {}
var _ctx: Dictionary = {}
var _page: int = 1
var _page_count: int = 1
var _page_native: Vector2 = Vector2.ZERO  # rasterized page pixel size (doc space)
var _reply_counter: int = 0

# Annotation substrate.
var _annotation_registry: AnnotationRegistry = null
var _annotation_host: RefCounted = null
var _registered_editor_name: String = ""

# UI.
var _preview_tex: TextureRect
var _page_label: Label
var _status: Label
var _data_label: Label
var _prev_btn: Button
var _next_btn: Button


func _ready() -> void:
	_doc = Model.make_empty()
	_build_ui()
	_annotation_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_annotation_registry)
	_annotation_host = _NametagAnnotationHost.new()
	_annotation_host._registry = _annotation_registry


func get_annotation_host() -> RefCounted:
	return _annotation_host


# ── Plugin lifecycle ──────────────────────────────────────────────────────────

func _on_panel_loaded(ctx: Dictionary) -> void:
	_ctx = ctx
	var ed: Variant = ctx.get("editor", null)
	if ed != null and "tab_title" in ed and _annotation_host != null:
		var ed_name: String = str(ed.tab_title)
		if not ed_name.is_empty():
			AnnotationHostRegistry.register(ed_name, _annotation_host)
			_registered_editor_name = ed_name
	_render_current_preview()


func _on_panel_unload() -> void:
	_deregister()


func _exit_tree() -> void:
	_deregister()


func _deregister() -> void:
	if _registered_editor_name != "":
		AnnotationHostRegistry.deregister(_registered_editor_name)
		_registered_editor_name = ""


# ── Save / load (host_owned) ──────────────────────────────────────────────────

func _on_panel_save_request() -> Dictionary:
	var annotations: Array = _annotation_host.get_annotations() if _annotation_host != null else []
	var file_path: String = str(_ctx.get("file_path", ""))
	if not file_path.is_empty():
		var sidecar_data := {
			"substrate_version": 1,
			"document": {"path": file_path, "kind": "nametag_maker"},
			"annotations": annotations,
			"unknown_kinds": [],
		}
		var err := AnnotationSidecar.write_sidecar(file_path, sidecar_data)
		if err != OK:
			push_warning("[nametag] sidecar write failed for '%s': %d" % [file_path, err])
	var out: Dictionary = _doc.duplicate(true)
	out["annotations"] = annotations
	return out


func _on_panel_load_request(document: Dictionary) -> void:
	_doc = Model.normalize(document)
	var annotations_to_restore: Array = []
	var file_path: String = str(_ctx.get("file_path", ""))
	if not file_path.is_empty():
		var sidecar: Dictionary = AnnotationSidecar.read_sidecar(file_path)
		if not sidecar.is_empty() and sidecar.has("annotations") and sidecar.get("annotations") is Array:
			annotations_to_restore = sidecar.get("annotations")
	if annotations_to_restore.is_empty():
		var doc_anns: Variant = document.get("annotations", [])
		if doc_anns is Array:
			annotations_to_restore = doc_anns
	_page = 1
	_update_data_label()
	# Render FIRST so the host gets page context (_page_native + rows via
	# set_page_context); only THEN restore annotations, so their semantic anchor
	# (describe_point → "tag: <name>") re-stamps against a valid page instead of
	# being wiped to "" (the re-stamp in set_annotations needs the page context).
	_render_current_preview()
	if _annotation_host != null:
		_annotation_host.set_annotations(annotations_to_restore)


# ── UI ────────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bar := HBoxContainer.new()
	root.add_child(bar)

	var refresh := Button.new()
	refresh.text = "⟳ Refresh"
	refresh.tooltip_text = "Re-render the preview from the current data (asks the backend)."
	refresh.pressed.connect(_on_refresh)
	bar.add_child(refresh)

	bar.add_child(VSeparator.new())

	_prev_btn = Button.new()
	_prev_btn.text = "◀"
	_prev_btn.pressed.connect(func(): _go_page(_page - 1))
	bar.add_child(_prev_btn)

	_page_label = Label.new()
	_page_label.text = "—"
	_page_label.custom_minimum_size = Vector2(90, 0)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_page_label)

	_next_btn = Button.new()
	_next_btn.text = "▶"
	_next_btn.pressed.connect(func(): _go_page(_page + 1))
	bar.add_child(_next_btn)

	bar.add_child(VSeparator.new())

	_data_label = Label.new()
	_data_label.text = "Data: (none)"
	bar.add_child(_data_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_status = Label.new()
	_status.text = ""
	_status.modulate = Color(1, 1, 1, 0.7)
	bar.add_child(_status)

	# Fit-to-pane preview: the page scales to fit the (variable-size) pane,
	# centered, no free scroll — so annotations bind 1:1 and never drift. The
	# annotation transform is derived from this rect live (resize-aware).
	_preview_tex = TextureRect.new()
	_preview_tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_preview_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_tex.size_flags_horizontal = SIZE_EXPAND_FILL
	_preview_tex.size_flags_vertical = SIZE_EXPAND_FILL
	_preview_tex.resized.connect(_update_view_geometry)
	root.add_child(_preview_tex)


func _update_data_label() -> void:
	var sheet := str(_doc.get("sheet_ref", "")).strip_edges()
	_data_label.text = "Data: %s" % (sheet if not sheet.is_empty() else "(none)")


func _set_status(msg: String) -> void:
	_status.text = msg


func _go_page(p: int) -> void:
	var clamped := clampi(p, 1, max(1, _page_count))
	if clamped == _page:
		return
	_page = clamped
	_render_current_preview()


func _update_page_controls() -> void:
	_page_label.text = "Page %d / %d" % [_page, _page_count]
	_prev_btn.disabled = _page <= 1
	_next_btn.disabled = _page >= _page_count


# ── Preview rasterization ─────────────────────────────────────────────────────

func _render_current_preview() -> void:
	var pdf_abs := _resolve_preview_pdf()
	if pdf_abs.is_empty():
		_preview_tex.texture = null
		if _annotation_host != null:
			_annotation_host.content_image = null
		_page_count = 1
		_page = 1
		_update_page_controls()
		_set_status("No preview yet — ask the LLM to render a draft, or click Refresh.")
		return
	_page_count = _pdf_page_count(pdf_abs)
	_page = clampi(_page, 1, max(1, _page_count))
	var img := _rasterize_page(pdf_abs, _page)
	if img == null:
		_set_status("Could not rasterize preview (pdftoppm).")
		_update_page_controls()
		return
	_preview_tex.texture = ImageTexture.create_from_image(img)
	_page_native = Vector2(img.get_width(), img.get_height())
	if _annotation_host != null:
		_annotation_host.content_image = img  # feeds render_content_to_image (AI vision)
		var gen_v: Variant = _doc.get("generate", {})
		var rows_ctx: Array = ((gen_v as Dictionary).get("rows", []) if gen_v is Dictionary else [])
		_annotation_host.set_page_context(_page_native, rows_ctx)
	call_deferred("_update_view_geometry")
	_update_page_controls()
	_set_status("")


## Recompute where the page is drawn on-screen (fit-to-pane, centered) and push
## the doc→screen transform to the annotation host so marks track the page at
## ANY pane size. Called after render and whenever the preview rect resizes
## (pane layout change). Layout-agnostic: everything derives from the live rect.
func _update_view_geometry() -> void:
	if _annotation_host == null or _preview_tex == null or not is_instance_valid(_preview_tex):
		return
	if _page_native.x <= 0.0 or _page_native.y <= 0.0:
		return
	var avail := _preview_tex.get_global_rect()
	if avail.size.x <= 0.0 or avail.size.y <= 0.0:
		return
	var fit := minf(avail.size.x / _page_native.x, avail.size.y / _page_native.y)
	var disp := _page_native * fit
	var letterbox := (avail.size - disp) * 0.5
	# The overlay shares the panel root's coordinate space (PRESET_FULL_RECT
	# child), so express the page origin in panel-local coords.
	var origin_panel := (avail.position + letterbox) - get_global_rect().position
	_annotation_host.set_view(origin_panel, fit)


## The preview PDF: an absolute path stored on the doc (set by Refresh/MCP).
func _resolve_preview_pdf() -> String:
	var p := str(_doc.get("preview_pdf_path", "")).strip_edges()
	if not p.is_empty() and FileAccess.file_exists(p):
		return p
	return ""


func _pdf_page_count(pdf_abs: String) -> int:
	var out: Array = []
	var code := OS.execute("pdfinfo", [pdf_abs], out, true)
	if code == 0 and out.size() > 0:
		for line in str(out[0]).split("\n"):
			if (line as String).begins_with("Pages:"):
				var n := (line as String).substr(6).strip_edges().to_int()
				if n > 0:
					return n
	return 1


## Render one page to PNG via pdftoppm -singlefile (no zero-pad suffix), load it.
func _rasterize_page(pdf_abs: String, page: int) -> Image:
	var dir := _ensure_tmp_dir()
	if dir.is_empty():
		return null
	var prefix := dir.path_join("preview")
	var out: Array = []
	var args := [
		"-png", "-r", str(PREVIEW_DPI),
		"-f", str(page), "-l", str(page), "-singlefile",
		pdf_abs, prefix,
	]
	var code := OS.execute("pdftoppm", args, out, true)
	var png := prefix + ".png"
	if code != 0 or not FileAccess.file_exists(png):
		push_warning("[nametag] pdftoppm failed (code %d): %s" % [code, str(out)])
		return null
	var img := Image.load_from_file(png)
	return img  # null on load failure → caller handles


func _ensure_tmp_dir() -> String:
	var d := DirAccess.open("user://")
	if d == null:
		return ""
	if not d.dir_exists("nametag_tmp"):
		d.make_dir("nametag_tmp")
	return ProjectSettings.globalize_path(TMP_DIR)


# ── Generation request (pull) ─────────────────────────────────────────────────

func _on_refresh() -> void:
	_set_status("Rendering…")
	await _request_render()


## Ask the backend to render the current doc to a temp PDF and hand back its
## path. Path-driven + small payloads (64 KB IPC cap). The Go "nametag.render"
## handler is added in N3; until then this surfaces a clear status.
func _request_render() -> void:
	if not has_node("_MinervaIPC"):
		_set_status("Backend bridge unavailable.")
		return
	var args := Model.to_generate_args(_doc)
	var dir := _ensure_tmp_dir()
	if dir.is_empty():
		_set_status("No temp dir for render args.")
		return
	var args_path := dir.path_join("render_args.json")
	var f := FileAccess.open(args_path, FileAccess.WRITE)
	if f == null:
		_set_status("Could not write render args.")
		return
	f.store_string(JSON.stringify(args))
	f.close()

	_reply_counter += 1
	var reply_id := "nametag_render_%d" % _reply_counter
	request.emit("nametag.render", {"args_path": args_path}, reply_id)
	var result: Dictionary = await $_MinervaIPC.await_reply(reply_id)
	if not (result is Dictionary) or not bool(result.get("success", false)):
		_set_status("Render unavailable (backend handler lands in N3).")
		return
	var path := str(result.get("result", {}).get("path", "")) if result.get("result") is Dictionary else str(result.get("path", ""))
	if path.is_empty() or not FileAccess.file_exists(path):
		_set_status("Backend returned no PDF path.")
		return
	_doc["preview_pdf_path"] = path
	_page = 1
	_render_current_preview()


# ── Inner AnnotationHost — in-memory store + rasterized-page passthrough ───────
class _NametagAnnotationHost extends AnnotationHost:
	signal annotations_changed()

	var _registry: AnnotationRegistry = null
	var _annotations: Array = []
	var _selected_id: String = ""
	var _display_index_counter: int = 0
	var content_image: Image = null  # the rasterized preview page; feeds AI vision

	# View transform: page-pixel (doc) → overlay-local pixels. Pushed by the
	# panel from the live fit-to-pane geometry (set_view), so annotations track
	# the page at any pane size.
	var _view_origin: Vector2 = Vector2.ZERO
	var _view_scale: float = 1.0
	var _page_native: Vector2 = Vector2.ZERO
	var _rows: Array = []

	func get_registry() -> AnnotationRegistry:
		return _registry

	func set_view(origin: Vector2, scale: float) -> void:
		_view_origin = origin
		_view_scale = maxf(scale, 0.0001)
		# Emit by string, not `view_changed.emit()`: a hard identifier reference
		# would PARSE-ERROR (and crash the host) if loaded against an older core
		# AnnotationHost that lacks this signal. String emit degrades gracefully.
		emit_signal("view_changed")

	func set_page_context(native_size: Vector2, rows: Array) -> void:
		_page_native = native_size
		_rows = rows if rows is Array else []

	func get_annotation_view_transform() -> Transform2D:
		return Transform2D(Vector2(_view_scale, 0.0), Vector2(0.0, _view_scale), _view_origin)

	func get_annotation_zoom() -> float:
		return _view_scale

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return _view_origin + p * _view_scale

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return (p - _view_origin) / _view_scale

	## Map a page-pixel point to its Avery 5395 8-up cell (2 cols × 4 rows,
	## row-major) → the row's title, so an annotation's anchored_to names the TAG
	## ("tag: Ada Lovelace"), not a pixel. Approximate (ignores tag margins) but
	## enough for the LLM to know which tag. The page tag-grid is fixed in page
	## space, independent of the variable pane layout.
	func describe_point(doc_pos: Vector2) -> String:
		if _page_native.x <= 0.0 or _page_native.y <= 0.0:
			return ""
		var col := clampi(int(doc_pos.x / (_page_native.x / 2.0)), 0, 1)
		var row := clampi(int(doc_pos.y / (_page_native.y / 4.0)), 0, 3)
		var idx := row * 2 + col
		if idx >= 0 and idx < _rows.size() and _rows[idx] is Dictionary:
			var title := str((_rows[idx] as Dictionary).get("title", "")).strip_edges()
			if not title.is_empty():
				return "tag: %s" % title
		return "tag cell %d" % idx

	func get_capabilities() -> Dictionary:
		return {
			"kinds": ["callout", "2d_arrow", "2d_text"],
			"tools": ["select"],
			"anchor_types": ["core/canvas.point"],
			"lifecycle": {"resolve": true, "reopen": true, "delete": true, "repair": false, "apply": true},
			"authoring": {"add": true, "domain_pickers": false},
			"panes": false,
			"body_views": false,
			"filters": ["all", "open", "applied", "resolved", "broken"],
		}

	func get_view_context() -> String:
		return "nametag"

	func render_content_to_image(_viewport_rect: Rect2) -> Image:
		return content_image

	func add_annotation(annotation: Dictionary) -> String:
		var id: String = str(annotation.get("id", ""))
		if id.is_empty():
			id = "ann_%x" % randi()
		var stored: Dictionary = annotation.duplicate(true)
		stored["id"] = id
		_ensure_display_index(stored)
		AnnotationHost._stamp_anchor(stored, self)
		_annotations.append(stored)
		annotations_changed.emit()
		return id

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		for i in range(_annotations.size()):
			var entry: Dictionary = _annotations[i] as Dictionary
			if str(entry.get("id", "")) == annotation_id:
				var stored: Dictionary = new_annotation.duplicate(true)
				stored["id"] = annotation_id
				if int(stored.get("display_index", 0)) <= 0:
					stored["display_index"] = int(entry.get("display_index", 0))
				_ensure_display_index(stored)
				AnnotationHost._stamp_anchor(stored, self)
				_annotations[i] = stored
				annotations_changed.emit()
				return true
		return false

	func remove_annotation(annotation_id: String) -> bool:
		for i in range(_annotations.size()):
			var entry: Dictionary = _annotations[i] as Dictionary
			if str(entry.get("id", "")) == annotation_id:
				_annotations.remove_at(i)
				if _selected_id == annotation_id:
					_selected_id = ""
					selection_changed.emit("")
				annotations_changed.emit()
				return true
		return false

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(_selected_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func set_annotations(list: Array) -> void:
		_annotations = []
		_display_index_counter = 0
		for ann in list:
			if ann is Dictionary:
				var stored := (ann as Dictionary).duplicate(true)
				_ensure_display_index(stored)
				_annotations.append(stored)
		AnnotationHost.refresh_all_anchors(_annotations, self)
		annotations_changed.emit()

	func _ensure_display_index(annotation: Dictionary) -> void:
		var existing := int(annotation.get("display_index", 0))
		if existing > 0:
			if existing > _display_index_counter:
				_display_index_counter = existing
			return
		_display_index_counter += 1
		annotation["display_index"] = _display_index_counter
