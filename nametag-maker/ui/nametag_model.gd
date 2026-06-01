extends RefCounted
## .mtags document model — the canonical state the Nametag editor panel owns.
##
## A .mtags file is a thin, host-owned JSON envelope around the SAME arguments the
## `nametag_generate` MCP tool already accepts (the generic "faces" model), plus
## embedded image blobs and annotations. Keeping it 1:1 with the backend tool
## means the editor → backend → PDF path needs no translation layer: build the
## generate args straight from the document.
##
## Off-tree plugin script: NO class_name (Godot only registers res:// global
## classes; see memory project_off_tree_plugin_class_names). The panel preloads
## this relatively: `const Model = preload("nametag_model.gd")` and calls the
## static helpers.
##
## Shape (all fields optional on load — defensive .get() everywhere):
##   {
##     "version": 1,
##     "title": "",                      # document display title (for the tab / chooser)
##     "generate": {                     # verbatim nametag_generate args (minus images)
##        "layout": "detailed",          # "classic" | "detailed"
##        "image_side": "left",          # "left" | "right"
##        "back_mode": "blank",          # "blank" | "same" | "shared"
##        "icon_width_in": 0.9,
##        "full_guides": false,          # true = visible boxes, false = corner-cut marks
##        "back_offset_x": 0.0,
##        "back_offset_y": 0.0,
##        "rows": [ {face row}… ],       # each row: {title, subtitle, front, back, …}
##        "back": { face } | absent      # shared back (when back_mode == "shared")
##     },
##     "images": [                       # embedded blobs the rows/back reference by id
##        {"id": "icon", "blob": {"__blob__": true, "content_type": "image/png", "bytes": "<base64>"}}
##     ],
##     "annotations": [ … ]              # AI/human marks; sidecar wins on load (see panel)
##   }
##
## JSON gotcha (project_godot_json_int_to_float): round-tripped numbers come back
## as float, so `x is int` fails. Coerce with _to_int / treat whole-number floats
## as ints in validators.

const SCHEMA_VERSION := 1

const VALID_LAYOUTS := ["classic", "detailed"]
const VALID_IMAGE_SIDES := ["left", "right"]
const VALID_BACK_MODES := ["blank", "same", "shared"]


## A fresh, empty document — one blank detailed row so the editor opens on
## something editable rather than a void.
static func make_empty() -> Dictionary:
	return {
		"version": SCHEMA_VERSION,
		"title": "",
		"sheet_ref": "",
		"preview_pdf_path": "",
		"generate": {
			"layout": "detailed",
			"image_side": "left",
			"back_mode": "blank",
			"icon_width_in": 0.9,
			"full_guides": false,
			"back_offset_x": 0.0,
			"back_offset_y": 0.0,
			"rows": [
				{"title": "", "subtitle": "", "lines": []},
			],
		},
		"images": [],
		"annotations": [],
	}


## Normalize an arbitrary loaded Variant into a well-formed document dict, filling
## defaults for anything missing/wrong-typed. Never throws — a garbage file
## degrades to a fresh-ish doc rather than crashing the editor. Pair with
## validate() when you want to surface (non-fatal) problems to the user.
static func normalize(doc: Variant) -> Dictionary:
	var src: Dictionary = doc if doc is Dictionary else {}
	var base := make_empty()

	var out := {
		"version": SCHEMA_VERSION,
		"title": str(src.get("title", "")),
		"sheet_ref": str(src.get("sheet_ref", "")),
		"preview_pdf_path": str(src.get("preview_pdf_path", "")),
		"generate": _normalize_generate(src.get("generate", {}), base["generate"]),
		"images": _normalize_images(src.get("images", [])),
		"annotations": (src.get("annotations", []) if (src.get("annotations", []) is Array) else []),
	}
	return out


static func _normalize_generate(g: Variant, defaults: Dictionary) -> Dictionary:
	var src: Dictionary = g if g is Dictionary else {}
	var out := {
		"layout": _one_of(src.get("layout", ""), VALID_LAYOUTS, defaults["layout"]),
		"image_side": _one_of(src.get("image_side", ""), VALID_IMAGE_SIDES, defaults["image_side"]),
		"back_mode": _one_of(src.get("back_mode", ""), VALID_BACK_MODES, defaults["back_mode"]),
		"icon_width_in": _to_float(src.get("icon_width_in", defaults["icon_width_in"]), defaults["icon_width_in"]),
		"full_guides": bool(src.get("full_guides", defaults["full_guides"])),
		"back_offset_x": _to_float(src.get("back_offset_x", 0.0), 0.0),
		"back_offset_y": _to_float(src.get("back_offset_y", 0.0), 0.0),
		"rows": (src.get("rows", []) if (src.get("rows", []) is Array) else []),
	}
	# Shared back is only meaningful when back_mode == "shared"; preserve it if present.
	if src.get("back", null) is Dictionary:
		out["back"] = src["back"]
	if (out["rows"] as Array).is_empty():
		out["rows"] = [{"title": "", "subtitle": "", "lines": []}]
	return out


static func _normalize_images(imgs: Variant) -> Array:
	if not (imgs is Array):
		return []
	var out: Array = []
	for entry in imgs:
		if not (entry is Dictionary):
			continue
		var id := str((entry as Dictionary).get("id", "")).strip_edges()
		if id.is_empty():
			continue
		var blob: Variant = (entry as Dictionary).get("blob", null)
		if blob is Dictionary and bool((blob as Dictionary).get("__blob__", false)):
			out.append({"id": id, "blob": blob})
	return out


## Validate a (normalized or raw) document. Returns an Array of human-readable
## problem strings; empty == clean. Non-fatal — the editor saves/loads anyway and
## just warns, matching the presentation plugin's behavior.
static func validate(doc: Variant) -> Array:
	var problems: Array = []
	if not (doc is Dictionary):
		return ["document is not a dictionary"]
	var d: Dictionary = doc

	var ver := _to_int(d.get("version", -1), -1)
	if ver != SCHEMA_VERSION:
		problems.append("version %s != expected %d" % [str(d.get("version", "missing")), SCHEMA_VERSION])

	var g: Variant = d.get("generate", null)
	if not (g is Dictionary):
		problems.append("'generate' missing or not a dictionary")
		return problems
	var gen: Dictionary = g

	if not VALID_LAYOUTS.has(str(gen.get("layout", ""))):
		problems.append("generate.layout '%s' not one of %s" % [str(gen.get("layout", "")), str(VALID_LAYOUTS)])
	if not VALID_IMAGE_SIDES.has(str(gen.get("image_side", ""))):
		problems.append("generate.image_side '%s' invalid" % str(gen.get("image_side", "")))
	if not VALID_BACK_MODES.has(str(gen.get("back_mode", ""))):
		problems.append("generate.back_mode '%s' invalid" % str(gen.get("back_mode", "")))

	var rows: Variant = gen.get("rows", null)
	if not (rows is Array):
		problems.append("generate.rows missing or not an array")
	elif (rows as Array).is_empty():
		problems.append("generate.rows is empty (nothing to print)")

	if str(gen.get("back_mode", "")) == "shared" and not (gen.get("back", null) is Dictionary):
		problems.append("back_mode is 'shared' but no shared 'back' face is defined")

	# Every image id referenced must resolve; and every embedded image must be a blob.
	var imgs: Variant = d.get("images", [])
	if imgs is Array:
		for entry in (imgs as Array):
			if not (entry is Dictionary):
				problems.append("images[] entry is not a dictionary")
				continue
			var blob: Variant = (entry as Dictionary).get("blob", null)
			if not (blob is Dictionary and bool((blob as Dictionary).get("__blob__", false))):
				problems.append("image '%s' has no valid blob envelope" % str((entry as Dictionary).get("id", "?")))

	return problems


## Build the argument dict for the `nametag_generate` backend tool from the
## document. Images are emitted as {id, png_base64} (decoding the blob envelope);
## everything else is the `generate` sub-dict verbatim. This is what the panel
## hands to the backend to render the live preview (N3).
static func to_generate_args(doc: Variant) -> Dictionary:
	var d: Dictionary = normalize(doc)
	var args: Dictionary = (d["generate"] as Dictionary).duplicate(true)
	var images_out: Array = []
	for entry in (d["images"] as Array):
		var id := str((entry as Dictionary).get("id", ""))
		var blob: Dictionary = (entry as Dictionary).get("blob", {})
		var bytes_b64 := str(blob.get("bytes", ""))
		if id.is_empty() or bytes_b64.is_empty():
			continue
		images_out.append({"id": id, "png_base64": bytes_b64})
	if not images_out.is_empty():
		args["images"] = images_out
	return args


# ── Coercion helpers (JSON ints arrive as floats) ────────────────────────────

static func _to_int(v: Variant, fallback: int) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String and (v as String).is_valid_int():
		return (v as String).to_int()
	return fallback


static func _to_float(v: Variant, fallback: float) -> float:
	if v is float:
		return v
	if v is int:
		return float(v)
	if v is String and (v as String).is_valid_float():
		return (v as String).to_float()
	return fallback


static func _one_of(v: Variant, allowed: Array, fallback: String) -> String:
	var s := str(v)
	return s if allowed.has(s) else fallback
