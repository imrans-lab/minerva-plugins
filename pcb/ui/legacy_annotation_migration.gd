extends RefCounted
## One-shot migration of legacy .minpcb INLINE annotation / route-hint blobs into
## the v2 annotation substrate (sidecar envelopes).
##
## Input contract (the exact legacy shapes — see the in-tree serializers
## Minerva src/Scripts/UI/Controls/PCBEditor/PCBAnnotation.gd::to_dict and
## PCBRouteHint.gd::to_dict):
##
##   annotation dict: {
##       id: "ann_NNNNNN", type: "ARROW"|"TEXT"|"REGION"|"POLYLINE",
##       positions: [{x,y}, …], text, color: "#rrggbbaa", author: "human"|"ai",
##       created_at: float, associated_component: "U3", associated_net: "GND" }
##
##   route_hint dict: {
##       id: "rhint_NNNNNN", hint_type: "WAYPOINT"|"SINGLE_TRACE"|"BUS",
##       detail_level: "SPARSE"|"GUIDED"|"DETAILED", layer, width: float,
##       bus_spacing: float, source_pins: [...], dest_pins: [...],
##       net_names: [...], waypoints: [{x,y}, …], author, text,
##       color: "#rrggbbaa", created_at: float, client_id }
##
## Both the id→dict MAP shape (how PCBData.to_dict nests them under
## "annotations"/"route_hints") and a bare LIST shape are accepted.
##
## Target: conformant v2 envelopes that pass AnnotationV2Schema.validate_with_registry
## against PcbAnnotationHost's registry, stored via host.add_annotation_v2.
##
## ── PLATFORM CONSTRAINT (discovered + verified this round) ────────────────────
## The core generic kinds (2d_arrow/2d_text/2d_region/2d_polyline) return
## ["core/*"] from accepted_anchor_types(); the schema's kind↔anchor compat gate
## therefore REJECTS any pcb/* anchor on them (empirically confirmed: 2d_* + any
## pcb/* anchor → add_annotation_v2 returns "" with code kind_anchor_incompatible;
## only core/canvas.point is accepted). The migration doc §3 anchor-upgrade to
## pcb/component|pcb/net cannot be applied to generic kinds without editing the
## read-only core schema. Resolution (validator is the documented tiebreaker):
##   * generic annotations anchor at core/canvas.point (the annotation's primary
##     board-mm position); associated_component/associated_net are preserved
##     LOSSLESSLY in kind_payload (exactly the migration doc §3 field mapping).
##   * ROUTE HINTS keep the real semantic upgrade — pcb_route_hint DOES accept
##     pcb/pad + pcb/board.point, so a resolvable first source pin → pcb/pad,
##     else pcb/board.point at the first waypoint.
##
## Off-tree note: lives at C:/github/minerva-plugins/pcb/ui/, OUTSIDE Minerva's
## res:// tree. It MUST NOT declare a class_name (plugin-local class_names are
## unresolvable off-tree). Core class_names (AnnotationV2Schema) ARE resolvable.
## Loaded via preload() by PCBPanel.gd and the migration test.

# Legacy author-default colors, verbatim from PCBAnnotation._get_author_color /
# PCBRouteHint._get_author_color. A per-item color override is written ONLY when
# the stored color diverges from THIS legacy default (i.e. the user customised
# it) — comparing against the legacy default, not the substrate render default,
# is the correct "was this hand-tuned?" test.
const _ANN_HUMAN_DEFAULT := Color(0.95, 0.5, 0.9)
const _ANN_AI_DEFAULT := Color(0.3, 0.7, 0.9)
const _RHINT_HUMAN_DEFAULT := Color(0.2, 0.8, 0.6, 0.8)
const _RHINT_AI_DEFAULT := Color(0.6, 0.4, 0.9, 0.8)

## Known legacy keys per shape — anything else rides into kind_payload.legacy_extra
## (lossless) AND raises a warning (mirrors the Go importer's opaque-passthrough
## philosophy: never drop silently).
const _ANN_KNOWN_KEYS := [
	"id", "type", "positions", "text", "color", "author",
	"created_at", "associated_component", "associated_net",
]
const _RHINT_KNOWN_KEYS := [
	"id", "hint_type", "detail_level", "layer", "width", "bus_spacing",
	"source_pins", "dest_pins", "net_names", "waypoints", "author",
	"text", "color", "created_at", "client_id",
]

const _TYPE_TO_KIND := {
	"ARROW": "2d_arrow", "TEXT": "2d_text",
	"REGION": "2d_region", "POLYLINE": "2d_polyline",
}
const _KIND_LABEL := {
	"2d_arrow": "arrow", "2d_text": "text",
	"2d_region": "region", "2d_polyline": "polyline",
}


## Migrate legacy inline annotations + route hints into `host` (calls
## host.add_annotation_v2 per envelope). Accepts BOTH the id→dict map shape and a
## bare list shape for each argument. Never aborts the batch: a validation failure
## is collected into `warnings` (with the legacy id) and migration continues.
## Returns {migrated: int, warnings: Array[String]}.
static func migrate(legacy_annotations: Variant, legacy_route_hints: Variant, host) -> Dictionary:
	var warnings: Array = []
	var migrated := 0

	for legacy in _to_list(legacy_annotations):
		if _migrate_annotation(legacy, host, warnings):
			migrated += 1

	for legacy in _to_list(legacy_route_hints):
		if _migrate_route_hint(legacy, host, warnings):
			migrated += 1

	return {"migrated": migrated, "warnings": warnings}


# ── Annotation (ARROW/TEXT/REGION/POLYLINE → core 2d_* kinds) ─────────────────

static func _migrate_annotation(legacy: Dictionary, host, warnings: Array) -> bool:
	var legacy_id := str(legacy.get("id", ""))
	var type_str := str(legacy.get("type", "TEXT"))
	if not _TYPE_TO_KIND.has(type_str):
		warnings.append("annotation %s: unknown type '%s' — skipped" % [legacy_id, type_str])
		return false
	var kind := str(_TYPE_TO_KIND[type_str])

	var positions := _positions_to_arrays(legacy.get("positions", []))
	var text := str(legacy.get("text", ""))
	var author_kind := _author_kind(legacy.get("author", "human"))
	var primary := _primary_pos(positions)

	var kind_payload := {"legacy_id": legacy_id}
	var assoc_component := str(legacy.get("associated_component", ""))
	var assoc_net := str(legacy.get("associated_net", ""))
	# associated_component/net UPGRADE to a semantic pcb anchor is impossible on
	# the core 2d_* kinds (see the PLATFORM CONSTRAINT note above); preserve both
	# losslessly in kind_payload per migration doc §3.
	if not assoc_component.is_empty():
		kind_payload["associated_component"] = assoc_component
	if not assoc_net.is_empty():
		kind_payload["associated_net"] = assoc_net
	var extra := _collect_extra(legacy, _ANN_KNOWN_KEYS, legacy_id, "annotation", warnings)
	if not extra.is_empty():
		kind_payload["legacy_extra"] = extra

	var created := int(legacy.get("created_at", 0.0))
	var envelope := {
		"id": "",
		"kind": kind,
		"schema_version": 2,
		"anchor": _canvas_point_anchor(primary),
		"kind_payload": kind_payload,
		"primitives": _build_primitives(kind, positions, text),
		"lifecycle": "open",
		"author": {"kind": author_kind},
		"view_context": "pcb",
		"visible_in_views": ["all"],
		"summary": _ann_summary(kind, text, primary),
		"created_at": created,
		"updated_at": created,
	}

	# Color override rides in the TOP-LEVEL "payload" (the core 2d_* kinds read
	# payload.color, NOT kind_payload) so a customised color actually re-renders.
	var col_hex := _diverging_color_hex(legacy.get("color", ""), author_kind, _ANN_HUMAN_DEFAULT, _ANN_AI_DEFAULT)
	if not col_hex.is_empty():
		envelope["payload"] = {"color": col_hex}

	return _add(envelope, legacy_id, "annotation", host, warnings)


static func _build_primitives(kind: String, positions: Array, text: String) -> Array:
	match kind:
		"2d_arrow":
			var a := _at(positions, 0)
			var b := _at(positions, 1)
			var prims: Array = [{"kind": "arrow", "from": a, "to": b}]
			# The 2d_arrow renderer draws an optional trailing text primitive at
			# `at` (near the midpoint) — that's what renders, so put the label there.
			if not text.is_empty():
				prims.append({"kind": "text", "at": _midpoint(a, b), "content": text})
			return prims
		"2d_text":
			return [{"kind": "text", "at": _at(positions, 0), "content": text}]
		"2d_region":
			var prims: Array = [{"kind": "region", "points": _region_points(positions), "filled": false}]
			if not text.is_empty():
				prims.append({"kind": "text", "at": _at(positions, 0), "content": text})
			return prims
		"2d_polyline":
			var prims: Array = [{"kind": "polyline", "points": positions.duplicate(true)}]
			if not text.is_empty():
				prims.append({"kind": "text", "at": _at(positions, 0), "content": text})
			return prims
	return []


static func _ann_summary(kind: String, text: String, primary: Array) -> String:
	var label := str(_KIND_LABEL.get(kind, "annotation"))
	var s := "%s at (%.1f, %.1f)" % [label, float(primary[0]), float(primary[1])]
	if not text.is_empty():
		s = "%s: %s" % [s, text]
	return s


# ── Route hint (→ pcb_route_hint kind, real semantic anchor) ──────────────────

static func _migrate_route_hint(legacy: Dictionary, host, warnings: Array) -> bool:
	var legacy_id := str(legacy.get("id", ""))
	var hint_type := _lower_enum(legacy.get("hint_type", "SINGLE_TRACE"))
	var detail_level := _lower_enum(legacy.get("detail_level", ""))
	var layer := str(legacy.get("layer", ""))
	if layer.is_empty():
		layer = "F.Cu"
	var width_mm := float(legacy.get("width", 0.0))      # 0 = unspecified (lossless)
	var bus_spacing := float(legacy.get("bus_spacing", 0.0))
	var source_pins := _string_array(legacy.get("source_pins", []))
	var dest_pins := _string_array(legacy.get("dest_pins", []))
	var net_names := _string_array(legacy.get("net_names", []))
	var waypoints := _positions_to_arrays(legacy.get("waypoints", []))
	var text := str(legacy.get("text", ""))
	var author_kind := _author_kind(legacy.get("author", "human"))
	var client_id := str(legacy.get("client_id", ""))

	var wp0 := _at(waypoints, 0)

	# Reuse the host's conformant builder so the toolbar / MCP / migration paths
	# all share one route-hint envelope shape.
	var envelope: Dictionary = host.build_route_hint_envelope(
		float(wp0[0]), float(wp0[1]), text, layer, hint_type, waypoints,
		author_kind, detail_level, width_mm, source_pins, dest_pins)

	# Extend the payload with the fields the base builder doesn't carry (lossless).
	var kp: Dictionary = envelope.get("kind_payload", {})
	kp["bus_spacing"] = bus_spacing
	kp["net_names"] = net_names
	kp["client_id"] = client_id
	kp["legacy_id"] = legacy_id
	var extra := _collect_extra(legacy, _RHINT_KNOWN_KEYS, legacy_id, "route hint", warnings)
	if not extra.is_empty():
		kp["legacy_extra"] = extra
	# The pcb_route_hint kind is layer-tinted (ignores author/stored color), so a
	# custom color won't re-render — but preserve it in kind_payload for
	# losslessness when it diverges from the legacy route-hint default.
	var col_hex := _diverging_color_hex(legacy.get("color", ""), author_kind, _RHINT_HUMAN_DEFAULT, _RHINT_AI_DEFAULT)
	if not col_hex.is_empty():
		kp["color"] = col_hex
	envelope["kind_payload"] = kp

	# Anchor upgrade: resolvable first source pin → pcb/pad, else board.point.
	envelope["anchor"] = _route_hint_anchor(source_pins, wp0, host)
	envelope["created_at"] = int(legacy.get("created_at", envelope.get("created_at", 0)))
	envelope["updated_at"] = envelope["created_at"]

	return _add(envelope, legacy_id, "route hint", host, warnings)


## Resolve the route-hint anchor. First source pin ("U1.15") that resolves live
## against the board → pcb/pad {component, pin} with a snapshot at the live pad
## position; otherwise a pcb/board.point at the first waypoint. Snapshot.position
## is ALWAYS filled (resolver-fallback safety).
static func _route_hint_anchor(source_pins: Array, wp0: Array, host) -> Dictionary:
	var board_anchor := {
		"plugin": "pcb", "type": "board.point",
		"id": {"x": float(wp0[0]), "y": float(wp0[1])},
		"snapshot": {"position": [float(wp0[0]), float(wp0[1])]},
	}
	if source_pins.is_empty():
		return board_anchor
	var ref := str(source_pins[0])
	var dot := ref.rfind(".")
	if dot < 0:
		return board_anchor
	var comp := ref.left(dot)
	var pin := ref.substr(dot + 1)
	if comp.is_empty() or pin.is_empty():
		return board_anchor
	var candidate := {
		"plugin": "pcb", "type": "pad",
		"id": {"component": comp, "pin": pin},
		"snapshot": {"position": [float(wp0[0]), float(wp0[1])]},
	}
	if host != null and host.has_method("resolve_anchor"):
		var resolved: Dictionary = host.resolve_anchor(candidate)
		if not bool(resolved.get("stale", true)):
			var pos: Variant = resolved.get("position", null)
			if pos is Vector2:
				candidate["snapshot"]["position"] = [(pos as Vector2).x, (pos as Vector2).y]
				return candidate
	return board_anchor


# ── Shared add / validation-reason path ───────────────────────────────────────

static func _add(envelope: Dictionary, legacy_id: String, label: String, host, warnings: Array) -> bool:
	var new_id := str(host.add_annotation_v2(envelope))
	if new_id.is_empty():
		warnings.append("%s %s rejected by validation: %s" % [label, legacy_id, _validation_reason(envelope, host)])
		return false
	return true


## Re-derive the validation error message for a rejected envelope (add_annotation_v2
## only signals rejection via ""). A placeholder id is stamped so the "id required"
## error never masks the REAL reason.
static func _validation_reason(envelope: Dictionary, host) -> String:
	var registry = host.get_registry() if host != null and host.has_method("get_registry") else null
	var probe := envelope.duplicate(true)
	if str(probe.get("id", "")).is_empty():
		probe["id"] = "ann_probe"
	var result = AnnotationV2Schema.new().validate_with_registry(probe, registry)
	if not result.has_errors():
		return "unknown (host rejected a schema-valid envelope)"
	var msgs: Array = []
	for e in result.to_error_dicts():
		msgs.append(str(e.get("message", "")))
	return "; ".join(msgs)


# ── Small helpers ─────────────────────────────────────────────────────────────

## Normalise the id→dict MAP shape OR a bare LIST into an Array of Dictionaries.
static func _to_list(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for e in (v as Array):
			if e is Dictionary:
				out.append(e)
	elif v is Dictionary:
		for k in (v as Dictionary).keys():
			var e: Variant = (v as Dictionary)[k]
			if e is Dictionary:
				out.append(e)
	return out


## Legacy positions ([{x,y}] or [[x,y]]) → Array of [x, y] float pairs.
static func _positions_to_arrays(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for e in (v as Array):
			if e is Dictionary and (e as Dictionary).has("x") and (e as Dictionary).has("y"):
				out.append([float((e as Dictionary)["x"]), float((e as Dictionary)["y"])])
			elif e is Array and (e as Array).size() >= 2:
				out.append([float((e as Array)[0]), float((e as Array)[1])])
	return out


static func _string_array(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for e in (v as Array):
			out.append(str(e))
	return out


static func _primary_pos(positions: Array) -> Array:
	if positions.is_empty():
		return [0.0, 0.0]
	return positions[0]


static func _at(arr: Array, i: int) -> Array:
	if i >= 0 and i < arr.size():
		return arr[i]
	return [0.0, 0.0]


static func _midpoint(a: Array, b: Array) -> Array:
	return [(float(a[0]) + float(b[0])) * 0.5, (float(a[1]) + float(b[1])) * 0.5]


## Promote a legacy 2-corner region box to a 4-vertex polygon (substrate `region`
## needs ≥3 points). Fewer than 2 corners passes through unchanged (a malformed
## region then fails validation → warning, never crashes the batch).
static func _region_points(positions: Array) -> Array:
	if positions.size() >= 2:
		var c1: Array = positions[0]
		var c2: Array = positions[1]
		return [
			[float(c1[0]), float(c1[1])],
			[float(c2[0]), float(c1[1])],
			[float(c2[0]), float(c2[1])],
			[float(c1[0]), float(c2[1])],
		]
	return positions.duplicate(true)


static func _canvas_point_anchor(p: Array) -> Dictionary:
	return {
		"plugin": "core", "type": "canvas.point",
		"id": {"x": float(p[0]), "y": float(p[1])},
		"snapshot": {"position": [float(p[0]), float(p[1])]},
	}


static func _author_kind(raw: Variant) -> String:
	return "ai" if str(raw) == "ai" else "human"


static func _lower_enum(raw: Variant) -> String:
	return str(raw).to_lower()


## Hex of `raw` when it diverges from the author default, else "". Both sides go
## through Color→to_html so the 8-bit hex quantisation matches (a default-colored
## legacy item, stored as its own to_html(), compares equal and writes NO override).
static func _diverging_color_hex(raw: Variant, author_kind: String, human_def: Color, ai_def: Color) -> String:
	var s := str(raw)
	if s.is_empty():
		return ""
	var cur_hex := Color.from_string(s, Color(0, 0, 0, 0)).to_html()
	var def_hex := (ai_def if author_kind == "ai" else human_def).to_html()
	if cur_hex == def_hex:
		return ""
	return cur_hex


## Unknown legacy keys → a preserved dict, one warning per key (lossless-or-warn).
static func _collect_extra(legacy: Dictionary, known: Array, legacy_id: String, label: String, warnings: Array) -> Dictionary:
	var extra: Dictionary = {}
	for k in legacy.keys():
		if not (str(k) in known):
			extra[str(k)] = legacy[k]
			warnings.append("%s %s: unknown legacy field '%s' preserved in legacy_extra" % [label, legacy_id, str(k)])
	return extra
