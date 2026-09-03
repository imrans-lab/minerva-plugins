extends RefCounted
## The PCB panel's EXPORT surface — the exporter list, the one run, and the
## report a person reads before they pay for boards.
##
## ── WHY THIS IS A MODULE AND NOT PANEL CODE ─────────────────────────────────
## Export reaches the human through TWO controls (the toolbar's Export menu, and
## the View menu's export rows, which exist because that button hides at narrow
## widths) and the agent through ONE verb (minerva_pcb_board_export). Three
## doorways onto one behaviour is exactly the shape that drifts: the historical
## Export YAML button and its View-menu twin already diverged into two call
## sites for one action, and any exporter added to one would have been
## unreachable from the other. Everything below is static and takes the panel,
## so all three doorways run this file and cannot disagree by construction —
## the same reason pcb_options_menu.gd owns read_state/apply.
##
## ── WHAT AN EXPORTER IS ─────────────────────────────────────────────────────
## A row in EXPORTERS. Two kinds:
##   yaml    — the canonical document, serialized through pcb.serialize and
##             WRITTEN NOWHERE. minerva_pcb_promote stays the only verb in this
##             plugin that puts bytes in a .yaml file.
##   package — the whole order package for one service profile (gerbers.zip,
##             bom.csv, cpl.csv, assembly-preview.svg, ORDER-CHECKLIST.md,
##             preflight.json, order-manifest.json), built from ONE strict
##             compilation by the worker's order_package method and published as
##             a directory in a single move.
##   model   — the board as ONE .glb: the textured slab, its holes cut, and
##             every ordered part seated at the position file's own transform.
##             Written by the worker, OFFLINE — it reads vendor models already
##             cached and never fetches.
##   prefetch— not an export at all, and here on purpose. It WARMS the vendor
##             model cache the model exporter reads, and it is the row directly
##             above the one that needs it, so the person who sees six magenta
##             prisms finds the fix without leaving the menu. It writes no
##             artifact; its whole output is the report.
##
## THE 3D EXPORT IS TWO ROWS BECAUSE IT IS TWO VERBS (T7, docket
## 01a0653468a9). Everything here runs synchronously and there is no progress
## channel, so a single row that fetched ~86 vendor documents and then wrote a
## file would freeze the window for minutes with nothing on screen. The network
## half is its own row, its own verb and its own report; the file write reads
## the cache and cannot stall.
## Adding a service profile adds a row here and nothing else: the worker's
## profile loader is fail-closed, so an id it does not know refuses by name
## rather than emitting a best-guess dialect.
##
## ── REFUSAL NAMES ARE THE CONTRACT ──────────────────────────────────────────
## `run` returns ONE shape for every exporter and every outcome, and a refusal
## always carries `error` — the STABLE code (assembly_duplicate_designator,
## assembly_service_side_unsupported, assembly_not_compilable, …) that the
## worker named, never a sentence this file invented. The panel renders that
## dictionary and the MCP verb returns it, so the human and the agent are told
## the same name for the same fault.
##
## Off-tree plugin: NO class_name; reached by relative preload.

## The panel-IPC channel the package exporters ride. It is the SAME registry
## entry minerva_pcb_order_package dispatches through (main.go registers one
## handler under both names), so the GUI and an agent holding a document reach
## one implementation rather than two that agree today.
const CHANNEL_ORDER_PACKAGE := "minerva_pcb_order_package"

## The 3D export's two channels, on the same one-entry-two-callers arrangement:
## each is the MCP tool's own name, so the Export menu and an agent calling the
## verb reach one worker method and are told the same name for one fault.
const CHANNEL_FETCH_PART_MODELS := "minerva_pcb_fetch_part_models"
const CHANNEL_EXPORT_3D := "minerva_pcb_export_3d"

const KIND_YAML := "yaml"
const KIND_PACKAGE := "package"
const KIND_MODEL := "model"
const KIND_PREFETCH := "prefetch"

## THE exporter list. Index order is menu order on both surfaces: the Export
## menu's item ids ARE these indices, and the View menu's are them offset by its
## own base.
const EXPORTERS := [
	{
		"id": "yaml",
		"label": "Canonical YAML",
		"kind": KIND_YAML,
		"profile": "",
		"summary": "the board as canonical YAML text — read out, never written",
	},
	{
		"id": "jlc",
		"label": "Order package — JLCPCB dialect",
		"kind": KIND_PACKAGE,
		"profile": "jlc",
		"summary": "the whole order package in JLCPCB's CSV dialect, claiming no assembly tier — the honest shape for a mid-layout quote",
	},
	{
		"id": "jlcpcb-economic",
		"label": "Order package — JLCPCB Economic",
		"kind": KIND_PACKAGE,
		"profile": "jlcpcb-economic",
		"summary": "the whole order package checked against JLCPCB's Economic assembly tier (single-sided placement, its size range, its fabrication rule profile)",
	},
	{
		"id": "fetch-part-models",
		"label": "Fetch 3D part models (warms the cache)",
		"kind": KIND_PREFETCH,
		"profile": "",
		"summary": "downloads the vendor 3D model for every part this board orders, into the per-user cache — the slow, network half of the 3D export, run on its own so the export itself never stalls. Writes no file",
	},
	{
		"id": "glb",
		"label": "3D model — GLB (textured slab, seated parts)",
		"kind": KIND_MODEL,
		"profile": "",
		"summary": "the whole board as one .glb for Blender or any glTF viewer — textured slab, holes cut, parts seated at the position file's own transform. Reads the cache and NEVER fetches: warm it first or parts arrive as placeholder prisms",
	},
]

## The default row, and the exporter _on_export_yaml_pressed drives.
const YAML_INDEX := 0

## How many findings one report section prints before it stops and says how
## many it did not. A dialog taller than the screen is a dialog nobody reads;
## preflight.json in the package carries every one of them.
const _REPORT_SECTION_CAP := 12


# ── The list ────────────────────────────────────────────────────────────────

static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for row in EXPORTERS:
		out.append(str((row as Dictionary)["id"]))
	return out


static func labels() -> PackedStringArray:
	var out := PackedStringArray()
	for row in EXPORTERS:
		out.append(str((row as Dictionary)["label"]))
	return out


static func id_at(index: int) -> String:
	if index < 0 or index >= EXPORTERS.size():
		return ""
	return str((EXPORTERS[index] as Dictionary)["id"])


static func label_at(index: int) -> String:
	if index < 0 or index >= EXPORTERS.size():
		return ""
	return str((EXPORTERS[index] as Dictionary)["label"])


## The one sentence saying what this exporter emits — the Export menu's tooltip,
## so what the button would do is readable without opening it.
static func summary_at(index: int) -> String:
	if index < 0 or index >= EXPORTERS.size():
		return ""
	return str((EXPORTERS[index] as Dictionary)["summary"])


static func index_of(exporter_id: String) -> int:
	for i in EXPORTERS.size():
		if str((EXPORTERS[i] as Dictionary)["id"]) == exporter_id:
			return i
	return -1


static func find(exporter_id: String) -> Dictionary:
	var i := index_of(exporter_id)
	return {} if i < 0 else (EXPORTERS[i] as Dictionary).duplicate(true)


# ── The run ─────────────────────────────────────────────────────────────────

## Run one exporter over the panel's LIVE board. `out_dir` is the package
## exporters' destination; empty means "beside the canonical source file the
## board was adopted from", which is the same implicit-target rule promote()
## uses, and no adopted file refuses by name rather than inventing a path.
##
## Returns, for every exporter and every outcome:
##   {ok, exporter, exporter_label, kind, error?, message?, component?, field?,
##    refs?, blocked_by?, blockers, advisories, warnings, unchecked_rules,
##    ip_questions, readiness?, preflight?, directory?, out_dir?, outputs?,
##    written?, source?, yaml?, bytes?}
## `error` is the worker's own stable code wherever the worker had one.
static func run(panel, exporter_id: String, out_dir: String = "",
		overwrite: bool = false) -> Dictionary:
	var exporter := find(exporter_id)
	if exporter.is_empty():
		return _refusal("unknown_exporter", exporter_id, "",
			"no exporter is named '%s' — known exporters: %s"
			% [exporter_id, ", ".join(ids())])
	var label := str(exporter["label"])
	if panel == null or not panel.has_method("get_data"):
		return _refusal("no_panel", exporter_id, label,
			"export reads the board open in an editor; no live panel is mounted")
	match str(exporter["kind"]):
		KIND_YAML:
			return await _run_yaml(panel, exporter)
		KIND_PREFETCH:
			return await _run_prefetch(panel, exporter)
		KIND_MODEL:
			return await _run_model(panel, exporter, out_dir, overwrite)
	return await _run_package(panel, exporter, out_dir, overwrite)


## The YAML exporter: PCBPanel.export_yaml_text owns the round trip (by-ref over
## the broker cap, digest-verified read-back), and this only reshapes its reply
## into the one export result shape.
static func _run_yaml(panel, exporter: Dictionary) -> Dictionary:
	if not panel.has_method("export_yaml_text"):
		return _refusal("no_panel", str(exporter["id"]), str(exporter["label"]),
			"this panel cannot serialize a board")
	var reply: Dictionary = await panel.export_yaml_text()
	if not bool(reply.get("success", false)):
		return _refusal(str(reply.get("error", "serialize_failed")),
			str(exporter["id"]), str(exporter["label"]),
			str(reply.get("note", "")))
	var out := _base(exporter, true)
	out["yaml"] = str(reply.get("yaml", ""))
	out["bytes"] = int(reply.get("bytes", 0))
	out["draft"] = true
	return out


## The package exporters: one worker call, which compiles once and publishes the
## whole directory in a single move, so a caller sees a complete package or
## none. The board goes over as to_board_dict() — the same snapshot the DRC
## verbs send, which is the form the compiler reads, and it carries
## board_graphics so the provenance projection has the silk to hash.
##
## `source_path` is DELIBERATELY NOT SENT. The manifest's git block is evidence
## about a file, and the board in this panel may hold edits that file does not:
## naming the canonical path would stamp a revision onto bytes it does not
## describe. Absent, the worker records no repository, which is exactly true of
## a live editor board — and stays true even though worker_check may spill an
## oversized payload to a snapshot file, because the worker reads the basis off
## what the caller declared and not off the presence of a path.
static func _run_package(panel, exporter: Dictionary, out_dir: String,
		overwrite: bool) -> Dictionary:
	var exporter_id := str(exporter["id"])
	var label := str(exporter["label"])
	var data = panel.get_data()
	if data == null:
		return _refusal("no_board", exporter_id, label, "this panel holds no board")
	if not panel.has_method("worker_check"):
		return _refusal("no_panel", exporter_id, label,
			"this panel cannot reach the pcb backend")
	var resolved := _resolve_out_dir(panel, exporter_id, label, out_dir)
	if resolved.has("refusal"):
		return resolved["refusal"]
	var target := str(resolved["dir"])
	var payload := {
		"board": data.to_board_dict(),
		"profile": str(exporter["profile"]),
		"out_dir": target,
		"overwrite": overwrite,
	}
	var reply: Dictionary = await panel.worker_check(CHANNEL_ORDER_PACKAGE, payload)
	if not bool(reply.get("success", false)):
		return _package_refusal(reply, exporter)
	var result: Dictionary = reply.get("result", {}) if reply.get("result", {}) is Dictionary else {}
	var out := _base(exporter, true)
	out["directory"] = str(result.get("directory", ""))
	out["out_dir"] = target
	out["outputs"] = _as_array(result.get("outputs", []))
	out["written"] = _as_array(result.get("written", []))
	out["readiness"] = _as_dict(result.get("readiness", {}))
	out["preflight"] = _as_dict(result.get("preflight", {}))
	out["blockers"] = _as_array(result.get("blockers",
		out["preflight"].get("blockers", [])))
	out["source"] = _as_dict(result.get("source", {}))
	out["advisories"] = _as_array(result.get("advisories", []))
	out["unchecked_rules"] = _as_array(result.get("unchecked_rules", []))
	out["ip_questions"] = _as_array(result.get("ip_questions", []))
	out["warnings"] = _as_array(result.get("warnings", []))
	return out


## WHERE A WRITTEN ARTIFACT GOES when the caller named no directory: beside the
## canonical source file the board was adopted from, which is the same implicit
## target promote() uses. A board that was never loaded from one refuses by
## name rather than inventing a path — the owner works only through the GUI and
## a file written somewhere they cannot predict is a file they have lost.
##
## Returns {"dir": <path>} or {"refusal": <the one export result shape>}.
static func _resolve_out_dir(panel, exporter_id: String, label: String,
		out_dir: String) -> Dictionary:
	var target := out_dir.strip_edges()
	if not target.is_empty():
		return {"dir": target}
	var source := ""
	if panel.has_method("canonical_source_path"):
		source = str(panel.canonical_source_path()).strip_edges()
	if source.is_empty():
		return {"refusal": _refusal("no_output_directory", exporter_id, label,
			"no out_dir was given and this board was not loaded from a canonical YAML file (only minerva_pcb_load_board's path form adopts one) — promote the board first, or name a directory")}
	return {"dir": source.get_base_dir()}


## The board this panel holds, as the snapshot the worker's compilers read, or
## a refusal saying why there is none. The package, model and prefetch runs all
## send the SAME shape, so a board that exports cannot fail to fetch for a
## reason about how it travelled.
static func _board_payload(panel, exporter_id: String, label: String) -> Dictionary:
	var data = panel.get_data()
	if data == null:
		return {"refusal": _refusal("no_board", exporter_id, label,
			"this panel holds no board")}
	if not panel.has_method("worker_check"):
		return {"refusal": _refusal("no_panel", exporter_id, label,
			"this panel cannot reach the pcb backend")}
	return {"board": data.to_board_dict()}


## THE PREFETCH ROW: warm the vendor model cache, write nothing else.
##
## This is the row that reaches the network, and the only one. It can take
## minutes on a cold board — that is precisely why it is not folded into the
## model exporter, which must stay fast enough to run behind a menu click.
static func _run_prefetch(panel, exporter: Dictionary) -> Dictionary:
	var exporter_id := str(exporter["id"])
	var label := str(exporter["label"])
	var payload := _board_payload(panel, exporter_id, label)
	if payload.has("refusal"):
		return payload["refusal"]
	var reply: Dictionary = await panel.worker_check(CHANNEL_FETCH_PART_MODELS, payload)
	if not bool(reply.get("success", false)):
		return _package_refusal(reply, exporter)
	var result := _as_dict(reply.get("result", {}))
	var out := _base(exporter, true)
	out["counts"] = _as_dict(result.get("counts", {}))
	out["cache_dir"] = str(result.get("cache_dir", ""))
	out["requested"] = _as_array(result.get("requested", []))
	out["ready"] = _as_array(result.get("ready", []))
	out["missing"] = _as_array(result.get("missing", []))
	out["refs_without_part"] = _as_array(result.get("refs_without_part", []))
	out["summary"] = str(result.get("summary", ""))
	return out


## THE MODEL ROW: one .glb, written by the worker from the cache alone.
##
## The reports come back HOISTED (missing_models, unverified, tallest,
## unknown_height_refs) rather than buried in the file, because the person who
## needs to know six parts have no model is looking at this screen and will
## never open asset.extras with a parser.
static func _run_model(panel, exporter: Dictionary, out_dir: String,
		overwrite: bool) -> Dictionary:
	var exporter_id := str(exporter["id"])
	var label := str(exporter["label"])
	var payload := _board_payload(panel, exporter_id, label)
	if payload.has("refusal"):
		return payload["refusal"]
	var resolved := _resolve_out_dir(panel, exporter_id, label, out_dir)
	if resolved.has("refusal"):
		return resolved["refusal"]
	payload["out_dir"] = str(resolved["dir"])
	payload["overwrite"] = overwrite
	var reply: Dictionary = await panel.worker_check(CHANNEL_EXPORT_3D, payload)
	if not bool(reply.get("success", false)):
		return _package_refusal(reply, exporter)
	var result := _as_dict(reply.get("result", {}))
	var out := _base(exporter, true)
	out["path"] = str(result.get("path", ""))
	out["filename"] = str(result.get("filename", ""))
	# The worker will build the model and write NOTHING when it is given no
	# destination (the same optional-out_dir rule the order package has). This
	# panel always names one, so `written` is always true here — it is carried
	# because written_file() is what decides whether to offer the desktop
	# handler, and that decision must rest on the worker's own statement rather
	# than on this surface's belief about what it asked for.
	out["written"] = bool(result.get("written", true))
	out["out_dir"] = str(result.get("out_dir", payload["out_dir"]))
	out["bytes"] = int(result.get("bytes", 0))
	out["sha256"] = str(result.get("sha256", ""))
	out["missing_models"] = _as_array(result.get("missing_models", []))
	out["unverified"] = _as_array(result.get("unverified", []))
	out["tallest"] = _as_array(result.get("tallest", []))
	out["unknown_height_refs"] = _as_array(result.get("unknown_height_refs", []))
	out["excluded"] = _as_array(result.get("excluded", []))
	out["cache_cold"] = _as_array(result.get("cache_cold", []))
	out["cache_cold_hint"] = str(result.get("cache_cold_hint", ""))
	out["advisories"] = _as_array(result.get("advisories", []))
	out["notes"] = _as_array(result.get("notes", []))
	out["viewer_note"] = str(result.get("viewer_note", ""))
	out["summary"] = str(result.get("summary", ""))
	return out


## A package refusal, unwrapped to the name the worker gave it.
##
## worker_check hands a method-level refusal back as {error:<kind>, detail:<the
## error payload>}. The payload's `code` is the STABLE gate name and its `kind`
## is the family; the code wins where there is one, because a caller matching on
## "assembly" cannot tell a duplicate designator from an unsupported side. The
## BLOCKED preflight the worker built for exactly this moment rides through, so
## the report a person would have read out of preflight.json is on screen even
## though no package was written.
static func _package_refusal(reply: Dictionary, exporter: Dictionary) -> Dictionary:
	var detail := _as_dict(reply.get("detail", {}))
	var code := str(detail.get("code", ""))
	if code.is_empty():
		code = str(detail.get("kind", ""))
	if code.is_empty():
		code = str(reply.get("error", "export_failed"))
	var message := str(detail.get("message", ""))
	if message.is_empty():
		message = str(reply.get("note", ""))
	var out := _refusal(code, str(exporter["id"]), str(exporter["label"]), message)
	for key in ["component", "field"]:
		if str(detail.get(key, "")) != "":
			out[key] = str(detail[key])
	if detail.has("refs"):
		out["refs"] = _as_array(detail["refs"])
	if detail.has("blocked_by"):
		out["blocked_by"] = _as_array(detail["blocked_by"])
	var preflight := _as_dict(detail.get("preflight", {}))
	if not preflight.is_empty():
		out["preflight"] = preflight
		out["blockers"] = _as_array(preflight.get("blockers", []))
		out["readiness"] = _as_dict(preflight.get("readiness", {}))
	if out["blockers"].is_empty():
		# No structured preflight came back (a broker-level fault, a panel
		# guard). The refusal is still ONE blocker so the report has the same
		# shape whatever refused.
		var blocker := {"code": code, "message": message}
		for key in ["component", "field", "refs"]:
			if out.has(key):
				blocker[key] = out[key]
		out["blockers"] = [blocker]
	return out


static func _base(exporter: Dictionary, ok: bool) -> Dictionary:
	return {
		"ok": ok,
		"exporter": str(exporter["id"]),
		"exporter_label": str(exporter["label"]),
		"kind": str(exporter["kind"]),
		"blockers": [],
		"advisories": [],
		"warnings": [],
		"unchecked_rules": [],
		"ip_questions": [],
	}


static func _refusal(code: String, exporter_id: String, label: String,
		message: String) -> Dictionary:
	var out := {
		"ok": false,
		"exporter": exporter_id,
		"exporter_label": label,
		"kind": "",
		"error": code,
		"message": message,
		"blockers": [],
		"advisories": [],
		"warnings": [],
		"unchecked_rules": [],
		"ip_questions": [],
	}
	var i := index_of(exporter_id)
	if i >= 0:
		out["kind"] = str((EXPORTERS[i] as Dictionary)["kind"])
	return out


static func _as_dict(value) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


static func _as_array(value) -> Array:
	return (value as Array).duplicate(true) if value is Array else []


# ── The report ──────────────────────────────────────────────────────────────

## What the status bar says while a row is RUNNING. The prefetch row is the only
## one here that reaches the network and the only one that can take minutes, so
## it says so — a window that looks hung is a window somebody kills.
static func running_line(index: int) -> String:
	var kind := ""
	if index >= 0 and index < EXPORTERS.size():
		kind = str((EXPORTERS[index] as Dictionary)["kind"])
	if kind == KIND_PREFETCH:
		return "Fetching vendor 3D models — this reaches the network and may take minutes…"
	return "Exporting — %s…" % label_at(index)


## The status line for one export result. The YAML exporter's sentences are the
## ones the Export YAML button has always written — the strings are pinned by
## the SR2FAB S1 suite, and a person who has read this line for a year should
## not have to learn a new one because the button grew a chooser beside it.
static func status_line(result: Dictionary) -> String:
	var kind := str(result.get("kind", ""))
	var yaml := kind == KIND_YAML
	if not bool(result.get("ok", false)):
		var code := str(result.get("error", ""))
		var message := str(result.get("message", ""))
		var why := message if message != "" else code
		if yaml:
			if code == "worker_unavailable":
				return "YAML export unavailable — plugin IPC not ready."
			return "YAML export failed: %s" % why
		return "Export refused (%s): %s%s" % [code, why,
			"  •  see the export report." if has_report(result) else ""]
	if yaml:
		var bytes := int(result.get("bytes", 0))
		return ("YAML exported (%d bytes)." % bytes) if bytes > 0 else "YAML export complete."
	# The worker wrote the sentence for these two, so the status bar and the MCP
	# reply cannot describe one run differently.
	if kind == KIND_MODEL or kind == KIND_PREFETCH:
		var summary := str(result.get("summary", ""))
		if summary.is_empty():
			summary = "%s complete." % str(result.get("exporter_label", ""))
		return "%s  •  see the export report." % summary
	var status := str(_as_dict(result.get("readiness", {})).get("preflight_status", "unknown"))
	var counts := "%d advisory(ies), %d compile warning(s)" % [
		_as_array(result.get("advisories", [])).size(),
		_as_array(result.get("warnings", [])).size()]
	return "Order package written → %s  •  preflight: %s  •  %s  •  see the export report." % [
		str(result.get("directory", "")), status, counts]


## Whether there is anything worth opening a dialog for: a refusal always is,
## and a package that generated with something to say about itself is too. A
## clean package needs no dialog — the status line already said where it went.
##
## unchecked_rules IS ONE OF THE KEYS. A package that found nothing still names
## what nothing looked at — uploader acceptance and licence compatibility are on
## every package, and the selected service adds its own — so leaving that list
## out of this predicate let a "clean" export suppress the whole report, which is
## the report's single most load-bearing section.
static func has_report(result: Dictionary) -> bool:
	if not bool(result.get("ok", false)):
		return true
	var kind := str(result.get("kind", ""))
	# ALWAYS for these two. The model export's report is not optional
	# decoration: it says where the file went and which parts are placeholders,
	# and the panel cannot show the file itself — the CAD surface has no mesh
	# loader. The prefetch has no other output at all.
	if kind == KIND_MODEL or kind == KIND_PREFETCH:
		return true
	if kind != KIND_PACKAGE:
		return false
	for key in ["advisories", "warnings", "ip_questions", "unchecked_rules", "blockers"]:
		if not _as_array(result.get(key, [])).is_empty():
			return true
	return false


## One finding as a line, NAMED and PER-COMPONENT. FOUR differently shaped
## records go through here — preflight blockers and advisories
## ({code, component?, field?, refs?, message}), compile diagnostics
## ({severity, code, message, source_ref:{entity_kind, entity_id, detail}}) and
## unchecked rules ({id, reason}, the shape a service profile authors and the
## worker forwards verbatim) — because a reader does not care which producer a
## finding came from, only what it is about. A finding that names no entity says
## so rather than printing an empty bullet that reads like a whole-board claim.
##
## The unchecked shape is read here rather than reshaped at the wire, because
## `id` and `reason` are what the profile file says and a rename in transit
## would put two vocabularies on one list.
static func finding_line(entry: Dictionary) -> String:
	var code := str(entry.get("code", ""))
	if code.is_empty():
		code = str(entry.get("id", ""))
	var severity := str(entry.get("severity", ""))
	var subject := str(entry.get("component", ""))
	var field := str(entry.get("field", ""))
	if subject.is_empty():
		var ref := _as_dict(entry.get("source_ref", {}))
		subject = str(ref.get("entity_id", ""))
		if field.is_empty():
			field = str(ref.get("entity_kind", ""))
	var refs := _as_array(entry.get("refs", []))
	var head := code if severity.is_empty() else "%s %s" % [severity, code]
	var about := "board-wide"
	if not subject.is_empty():
		about = subject
		if not field.is_empty():
			about = "%s (%s)" % [subject, field]
	if not refs.is_empty():
		about = "%s → %s" % [about, ", ".join(PackedStringArray(
			Array(refs.map(func(r): return str(r)))))]
	var message := str(entry.get("message", ""))
	if message.is_empty():
		message = str(entry.get("reason", ""))
	return "• %s — %s: %s" % [head, about, message]


## Findings stay bounded on screen, but the cap must not let repetitive
## documentation-only notes hide a fabrication-affecting warning that happened
## to arrive later in component order.  This is display ordering only; the
## complete original-order list remains in preflight.json and the manifest.
static func _finding_salience(entry: Dictionary) -> int:
	var severity := str(entry.get("severity", "")).to_lower()
	var score := 300 if severity == "error" else 200 if severity == "warning" else 100
	var impact := str(entry.get("impact", "")).to_lower()
	if impact == "fabrication":
		score += 200
	elif impact == "documentation":
		score -= 100
	return score


## One titled section, or nothing at all when there is nothing to say. Returns
## its lines rather than appending into the caller's, so the section list stays
## a value the caller composes.
static func _section(title: String, entries: Array) -> PackedStringArray:
	var lines := PackedStringArray()
	if entries.is_empty():
		return lines
	lines.append("")
	lines.append("%s (%d)" % [title, entries.size()])
	# Array.sort_custom is not stable. Decorate each row with its original index
	# and use that as an explicit tiebreak so equal-salience findings retain the
	# producer's deterministic order on every platform.
	var ranked: Array = []
	for i in entries.size():
		ranked.append({"entry": entries[i], "index": i,
			"salience": _finding_salience(_as_dict(entries[i]))})
	ranked.sort_custom(func(a, b):
		var left := _as_dict(a)
		var right := _as_dict(b)
		var left_score := int(left.get("salience", 0))
		var right_score := int(right.get("salience", 0))
		return (left_score > right_score) if left_score != right_score else \
			int(left.get("index", 0)) < int(right.get("index", 0)))
	var ordered: Array = ranked.map(func(row): return _as_dict(row).get("entry", {}))
	for i in ordered.size():
		if i >= _REPORT_SECTION_CAP:
			lines.append("  … and %d more — every one of them is in preflight.json"
				% (ordered.size() - _REPORT_SECTION_CAP))
			break
		lines.append("  %s" % finding_line(_as_dict(ordered[i])))
	return lines


## The whole report as text: what ran, what it refused over, what it could not
## measure, and what it never looked at. Every section is absent when empty.
static func report_lines(result: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("Exporter: %s" % str(result.get("exporter_label", result.get("exporter", ""))))
	var kind := str(result.get("kind", ""))
	if bool(result.get("ok", false)) and (kind == KIND_MODEL or kind == KIND_PREFETCH):
		return _model_report_lines(result, lines)
	if bool(result.get("ok", false)):
		var directory := str(result.get("directory", ""))
		if directory != "":
			lines.append("Package: %s" % directory)
			lines.append("Written under: %s" % str(result.get("out_dir", "")))
	else:
		lines.append("REFUSED: %s" % str(result.get("error", "")))
		var message := str(result.get("message", ""))
		if message != "":
			lines.append(message)

	var readiness := _as_dict(result.get("readiness", {}))
	if not readiness.is_empty():
		lines.append("")
		lines.append("Readiness")
		lines.append("  package_generated: %s" % str(readiness.get("package_generated", false)))
		lines.append("  preflight_status: %s" % str(readiness.get("preflight_status", "")))
		# The third state is never set here and the note says why. Printing it
		# as "null" alone would read as a check that failed rather than one
		# only a person at a quote page can record.
		lines.append("  order_page_verified: not recorded — %s"
			% str(readiness.get("order_page_verified_note", "")))

	var package_generated := bool(readiness.get("package_generated", false))
	lines.append_array(_section(
		"BLOCKERS — package is quote/reference only" if package_generated
		else "BLOCKERS — nothing was written",
		_as_array(result.get("blockers", []))))
	var blocked_by := _as_array(result.get("blocked_by", []))
	if not blocked_by.is_empty():
		lines.append("")
		lines.append("WHAT STOPPED THE COMPILE (%d)" % blocked_by.size())
		for entry in blocked_by:
			lines.append("  %s" % (finding_line(entry as Dictionary) if entry is Dictionary
				else "• %s" % str(entry)))
	lines.append_array(_section("ADVISORIES — shown, never refused",
		_as_array(result.get("advisories", []))))
	# WARNINGS are rendered here deliberately. The worker has carried them on
	# every assembly reply since the single-compilation cutover and no surface
	# drew them, which made a warning about the very board in the envelope
	# (captured geometry that was not emitted, say) invisible to the only
	# person who could act on it. The list is BOTH channels — the compilation's
	# own diagnostics and the gerber emitter's — because a fab feature the
	# emitter dropped is exactly the thing this section exists to show. They
	# stay out of the advisories: they are the compiler and the emitter talking
	# about the board, not the service talking about the order, so they get
	# their own section. They DO move preflight_status off `pass`, because a
	# dropped feature means these files are not a complete rendering of the
	# board.
	lines.append_array(_section(
		"WARNINGS — what the compiler and the emitter said about this board",
		_as_array(result.get("warnings", []))))
	lines.append_array(_section(
		"IP QUESTIONS — for a human to answer before ordering",
		_as_array(result.get("ip_questions", []))))
	lines.append_array(_section("NOTHING LOOKED AT THESE",
		_as_array(result.get("unchecked_rules", []))))

	var outputs := _as_array(result.get("outputs", []))
	if not outputs.is_empty():
		lines.append("")
		lines.append("OUTPUTS (%d)" % outputs.size())
		for entry in outputs:
			var row := _as_dict(entry)
			var sha := str(row.get("sha256", ""))
			lines.append("  • %s  %d bytes  %s" % [str(row.get("file", "")),
				int(row.get("bytes", 0)),
				("sha256 %s" % sha.substr(0, 16)) if sha != "" else "(digest recorded externally)"])
	return lines


## One row about ONE COMPONENT, for the reports whose findings are keyed by ref
## rather than by a rule code — the placement fallbacks ({ref, reason, detail})
## and the prefetch's misses ({part, refs, reason, detail}). finding_line's four
## shapes all name a RULE and then a subject; these name a subject and then a
## reason, and forcing them through it prints "• — board-wide:" on every line.
static func _subject_line(entry: Dictionary) -> String:
	var subject := str(entry.get("ref", ""))
	if subject.is_empty():
		subject = str(entry.get("part", ""))
	var refs := _as_array(entry.get("refs", []))
	if not refs.is_empty():
		subject = "%s → %s" % [subject, ", ".join(PackedStringArray(
			Array(refs.map(func(r): return str(r)))))]
	var reason := str(entry.get("reason", ""))
	var detail := str(entry.get("detail", ""))
	if detail.is_empty():
		detail = str(entry.get("prism_basis", ""))
	var why := reason
	if not detail.is_empty():
		why = "%s — %s" % [reason, detail] if not reason.is_empty() else detail
	return "• %s: %s" % [subject, why] if not why.is_empty() else "• %s" % subject


## A titled section of subject-keyed rows, or nothing when there are none.
static func _subject_section(title: String, entries: Array) -> PackedStringArray:
	var lines := PackedStringArray()
	if entries.is_empty():
		return lines
	lines.append("")
	lines.append("%s (%d)" % [title, entries.size()])
	for i in entries.size():
		if i >= _REPORT_SECTION_CAP:
			lines.append("  … and %d more — the complete list is on the reply, and on the file when one was written"
				% (entries.size() - _REPORT_SECTION_CAP))
			break
		lines.append("  %s" % _subject_line(_as_dict(entries[i])))
	return lines


## THE 3D REPORTS, on screen. Both rows share this because both answer the same
## question — which parts of this board the vendor could not supply a model for
## — and the person reading it should not have to learn two layouts.
##
## WHERE THE FILE WENT IS THE FIRST LINE. The application cannot open a .glb, so
## the path is the entire handoff: a report that buried it under four sections
## of advisories would leave a GUI-only owner with "it worked" and no file.
static func _model_report_lines(result: Dictionary,
		lines: PackedStringArray) -> PackedStringArray:
	var path := str(result.get("path", ""))
	if not path.is_empty():
		lines.append("")
		lines.append("FILE: %s" % path)
		lines.append("  %d bytes  •  sha256 %s" % [int(result.get("bytes", 0)),
			str(result.get("sha256", "")).substr(0, 16)])
		var viewer := str(result.get("viewer_note", ""))
		if not viewer.is_empty():
			lines.append("  %s" % viewer)
	var summary := str(result.get("summary", ""))
	if not summary.is_empty():
		lines.append("")
		lines.append(summary)
	var hint := str(result.get("cache_cold_hint", ""))
	if not hint.is_empty():
		lines.append("")
		lines.append("THE CACHE IS COLD: %s" % hint)
		lines.append("  Run \"%s\" from this same Export menu, then export again."
			% label_at(index_of("fetch-part-models")))

	var counts := _as_dict(result.get("counts", {}))
	if not counts.is_empty():
		lines.append("")
		lines.append("Vendor models")
		lines.append("  requested: %d  •  ready: %d  •  newly fetched: %d  •  already cached: %d  •  missing: %d" % [
			int(counts.get("requested", 0)), int(counts.get("ready", 0)),
			int(counts.get("fetched", 0)), int(counts.get("already_cached", 0)),
			int(counts.get("missing", 0))])
		var cache_dir := str(result.get("cache_dir", ""))
		lines.append("  cache: %s" % (cache_dir if not cache_dir.is_empty()
			else "NONE on this host — nothing was kept, and an export will still find it cold"))

	lines.append_array(_subject_section(
		"NO MODEL — drawn as a placeholder prism",
		_as_array(result.get("missing_models", []))))
	lines.append_array(_subject_section(
		"NO MODEL — the supplier had none to give",
		_as_array(result.get("missing", []))))
	lines.append_array(_subject_section(
		"ORIENTATION UNVERIFIED — a guess, marked in the file with a post",
		_as_array(result.get("unverified", []))))

	var tallest := _as_array(result.get("tallest", []))
	if not tallest.is_empty():
		lines.append("")
		lines.append("TALLEST MEASURED PART PER SIDE (%d)" % tallest.size())
		for entry in tallest:
			var row := _as_dict(entry)
			lines.append("  • %s: %s at %.2f mm" % [str(row.get("side", "")),
				str(row.get("ref", "")), float(row.get("height_mm", 0.0))])
	var unknown := _as_array(result.get("unknown_height_refs", []))
	if not unknown.is_empty():
		lines.append("")
		lines.append("HEIGHT UNKNOWN (%d) — these are nominal prisms, not measurements" % unknown.size())
		lines.append("  %s" % ", ".join(PackedStringArray(
			Array(unknown.map(func(r): return str(r))))))
	var without := _as_array(result.get("refs_without_part", []))
	if not without.is_empty():
		lines.append("")
		lines.append("NO CATALOGUE NUMBER (%d) — the board never named one, so nothing could be asked for" % without.size())
		lines.append("  %s" % ", ".join(PackedStringArray(
			Array(without.map(func(r): return str(r))))))

	lines.append_array(_section("ADVISORIES — shown, never refused",
		_as_array(result.get("advisories", []))))
	var notes := _as_array(result.get("notes", []))
	if not notes.is_empty():
		lines.append("")
		lines.append("NOTES (%d)" % notes.size())
		for note in notes:
			lines.append("  • %s" % str(note))
	return lines


## The file this run wrote, or "" when it wrote none. The panel's "open it"
## offer reads this rather than the kind, so a model export that refused after
## naming a path cannot be offered as if it had landed.
static func written_file(result: Dictionary) -> String:
	if not bool(result.get("ok", false)):
		return ""
	if result.has("written") and not bool(result["written"]):
		return ""
	return str(result.get("path", ""))


## The report as a dialog the panel pops. AcceptDialog is the panel's existing
## convention for a verdict too long for the status line (PromotionGateDialog),
## and the caller owns add_child/popup/free exactly as it does there.
static func build_report_dialog(result: Dictionary) -> AcceptDialog:
	var path := written_file(result)
	# A run that WROTE A FILE gets a confirm, not an acknowledge. The
	# application's own CAD surface has no mesh loader (in-app viewing is DCR
	# 01a0656b0494), so a .glb that only exists at a path the owner has to
	# retype is a deliverable they cannot open. The desktop handler can — .glb
	# is on the host's os-open allowlist — and this is the one click that gets
	# them there. ConfirmationDialog IS an AcceptDialog, so every caller that
	# adds, pops and frees the report dialog keeps working unchanged.
	var dialog: AcceptDialog = ConfirmationDialog.new() if not path.is_empty() \
		else AcceptDialog.new()
	dialog.name = "ExportReportDialog"
	dialog.title = "Export refused" if not bool(result.get("ok", false)) else "Export report"
	dialog.dialog_text = "\n".join(report_lines(result))
	dialog.dialog_autowrap = true
	if not path.is_empty():
		dialog.ok_button_text = "Open in the system 3D viewer"
		dialog.get_cancel_button().text = "Close"
		# OS.shell_open is the panel-side twin of the host's minerva_os_open,
		# which allowlists .glb (OSOpenPolicy.DEFAULT_EXTENSIONS); the scansort
		# panel opens vault documents the same way. The lambda captures the path
		# by value, so a second export cannot redirect a dialog already on
		# screen at a file it does not describe.
		dialog.confirmed.connect(func() -> void: OS.shell_open(path))
	return dialog
