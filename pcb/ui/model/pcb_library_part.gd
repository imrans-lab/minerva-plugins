extends RefCounted
## WHAT KIND OF GEOMETRY A PART HAS, and how a part gets built.
##
## Off-tree module — NO class_name, reached by relative preload. Every function
## is STATIC.
##
## TWO KINDS OF PART, and the panel must never blur them.
##
##   FABRICABLE. Its footprint is a library ref ("Lib:Part") that RESOLVED
##   through the worker's seed/wip/user chain, so its lands and its silk are
##   the library's own and the hermetic compiler will compile it. `pads` is the
##   board's own geometry authority from that moment on (pads_authored — see
##   pcb_component's own note on the FULL/PARTIAL rule).
##
##   SKETCH. Its footprint is one of the generic enums (HEADER, RESISTOR, …).
##   Its pads are ESTIMATED defaults with no library behind them, its footprint
##   name is not a ref anything can resolve, and the worker refuses it by name
##   — which takes the geometric DRC and every pour fill on the board with it,
##   because a plane whose fill cannot be computed credits no joins.
##
## The enums are KEPT: placing a part before its exact footprint is known is a
## real design act, and boards, fixtures and habits already depend on them. What
## a sketch part may not do is land SILENTLY — it says so in the add reply,
## wears the canvas's unresolved badge, and is named in the panel's held status
## lead until it is resolved or removed, so "the board went indeterminate" is
## never the first news of it.
##
## `build` below is the WHOLE construction an add runs. A part reaches the board
## only through minerva_pcb_add_component — the panel offers no add affordance,
## because choosing a part and its footprint is authoring, not layout — so this
## module is the single place deciding what lands and what is refused.

const _PcbComponent := preload("pcb_component.gd")


## SKETCH footprint names `build` accepts (mirrors the legacy schema enum; the
## plugin component enum carries extra values but is set by NAME, off-tree
## safe). Anything with a colon in it is a library ref instead.
const VALID_SKETCH_FOOTPRINTS: Array[String] = [
	"RESISTOR", "CAPACITOR", "IC_DIP", "IC_QFP", "SWITCH", "CONNECTOR",
	"LED", "DIODE", "TRANSISTOR", "HEADER", "MOUNTING_HOLE", "MODULE",
]

## Args a LIBRARY-REF add cannot honour, because the footprint already answers
## them: the pad layout, the pad kind, the pitches and the body box are the
## library's. Named back to the caller rather than silently dropped — an agent
## that asked for a 2-pin header and got a 40-pin one has to be told which of
## its words the part did not come from.
const LIBRARY_REF_IGNORED_ARGS: Array[String] = [
	"pin_count", "pin_names", "pad_type", "pad_spacing", "row_spacing",
	"width", "height",
]

## What a sketch part costs, said once so the reply, the tooltip and the docs
## cannot drift. Names the way OUT, not just the problem.
const SKETCH_NOTE := "this part has SKETCH geometry (estimated defaults, no library footprint behind it) — the hermetic worker refuses it by name, which makes the WHOLE board's geometric DRC and every pour fill indeterminate. Re-add it with a library ref (footprint: \"LibNick:PartName\", e.g. \"Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical\") to get real lands and silk; minerva_pcb_footprint_report names the refs the library has, and minerva_pcb_acquire_footprint fetches one it does not."


## Is this footprint string a LIBRARY REF rather than a generic enum? The
## canonical form is "LibNick:PartName"; both halves must be non-empty, so a
## stray colon is not mistaken for one.
static func is_library_ref(footprint: String) -> bool:
	var colon := footprint.find(":")
	return colon > 0 and colon < footprint.length() - 1


## The refdes prefix a library ref suggests, for an add that did not name one.
##
## Read off the library NICKNAME, which is how KiCad's own libraries are
## organised ("Connector_PinHeader_2.54mm:…" is a connector), because the part
## NAME is free-form and guessing from it is guessing. An unrecognised nickname
## gets "U" — the generic active-part prefix, and the same answer the sketch
## path already gives for anything it does not know.
const _NICK_PREFIXES: Array = [
	["Connector", "J"], ["TestPoint", "TP"], ["MountingHole", "H"],
	["Resistor", "R"], ["Capacitor", "C"], ["Inductor", "L"],
	["Diode", "D"], ["LED", "D"], ["Crystal", "Y"], ["Button", "SW"],
	["Switch", "SW"], ["Fuse", "F"], ["Jumper", "JP"], ["Varistor", "RV"],
	["Transistor", "Q"], ["Package", "U"], ["Module", "U"],
]


static func designator_prefix(ref: String) -> String:
	var nick := ref.substr(0, maxi(ref.find(":"), 0))
	for entry in _NICK_PREFIXES:
		if nick.begins_with(str(entry[0])):
			return str(entry[1])
	return "U"


## BUILD ONE COMPONENT from an add_component argument dict, without touching
## the board: `{ok:true, component, by_ref, geometry, ignored}` or
## `{ok:false, error:<a sentence naming what went wrong>}`. The caller adds it
## and journals it.
##
## Nothing is constructed until the LIBRARY GEOMETRY IS IN HAND. A ref the
## library cannot supply refuses by name and leaves the board untouched —
## adding it anyway would place exactly the estimated-geometry part the
## hermetic worker refuses by name.
static func build(host, data, args: Dictionary) -> Dictionary:
	var footprint: String = str(args.get("footprint", ""))
	if footprint.is_empty():
		return {"ok": false, "error": "footprint is required"}
	var by_ref := is_library_ref(footprint)
	if not by_ref and not VALID_SKETCH_FOOTPRINTS.has(footprint.to_upper()):
		return {"ok": false, "error": "Invalid footprint type: %s — pass a library ref \"LibNick:PartName\" for a fabricable part, or one of the sketch types %s" % [
			footprint, ", ".join(PackedStringArray(VALID_SKETCH_FOOTPRINTS))]}

	var component_id: String = str(args.get("id", ""))
	if component_id.is_empty():
		var prefix: String = designator_prefix(footprint) if by_ref \
			else (footprint[0] if footprint.length() > 0 else "U")
		component_id = data.generate_component_id(prefix)

	var geometry: Dictionary = {}
	if by_ref:
		var fetched: Dictionary = await _fetch_geometry(host, footprint)
		if not bool(fetched.get("ok", false)):
			return fetched
		geometry = fetched["geometry"]

	var comp = data.new_component()
	comp.id = component_id
	var asked := Vector2(float(args.get("x", 50.0)), float(args.get("y", 50.0)))
	comp.position = data.snap_to_grid(asked) if bool(args.get("snap_to_grid", true)) else asked
	comp.rotation = float(args.get("rotation", 0.0))

	var ignored: Array = []
	if by_ref:
		apply_geometry(comp, footprint, geometry)
		for key in LIBRARY_REF_IGNORED_ARGS:
			if args.has(key):
				ignored.append(key)
	else:
		_apply_sketch(comp, footprint, args)
	if args.has("value"):
		comp.properties["value"] = args.get("value")

	return {"ok": true, "component": comp, "by_ref": by_ref,
		"geometry": geometry, "ignored": ignored}


## The estimated-geometry half: the generic enums' own pin layouts, plus the
## explicit size override only a sketch part can honour.
static func _apply_sketch(comp, footprint: String, args: Dictionary) -> void:
	comp.set_footprint_by_name(footprint.to_upper())
	var pin_count: int = int(args.get("pin_count", 0))
	if pin_count > 0:
		match footprint.to_upper():
			"HEADER", "CONNECTOR":
				comp.setup_header_pins(pin_count, args.get("pin_names", []))
			"IC_DIP":
				comp.setup_dip_pins(pin_count)
			"MODULE":
				comp.setup_module_pins(pin_count)
			_:
				comp.setup_generic_pins(pin_count, str(args.get("pad_type", "tht")),
					float(args.get("pad_spacing", 2.54)), float(args.get("row_spacing", 7.62)))
	else:
		comp.setup_standard_pins()
	if args.has("width") or args.has("height"):
		comp.set_size(float(args.get("width", comp.width)),
			float(args.get("height", comp.height)))


## Resolve ONE library ref through the host's pcb.footprint_geometry channel.
## {ok:true, geometry:{…}} or {ok:false, error:<a sentence naming the ref>}.
##
## A host with no channel (headless model fixtures, or the panel before mount)
## is a REFUSAL, not a degrade: the alternative is placing a part with no lands
## under a name that promises them.
static func _fetch_geometry(host, ref: String) -> Dictionary:
	if host == null or not host.has_method("footprint_geometry"):
		return {"ok": false, "error": "cannot add '%s' by library ref — the pcb backend is not reachable from this panel, so the footprint could not be resolved. Start the plugin (minerva_plugin_start) and retry." % ref}
	var reply: Dictionary = await host.footprint_geometry(ref)
	if bool(reply.get("ok", false)):
		var result: Variant = reply.get("result")
		if not (result is Dictionary) or (result as Dictionary).is_empty():
			return {"ok": false, "error": "the library returned no geometry for '%s'" % ref}
		return {"ok": true, "geometry": result}
	var cause: Variant = reply.get("error")
	var message := str((cause as Dictionary).get("message", "")) if cause is Dictionary else str(cause)
	if message.is_empty():
		message = "the footprint could not be resolved"
	return {"ok": false, "error": "cannot add '%s': %s — minerva_pcb_footprint_report shows what the library has; minerva_pcb_acquire_footprint fetches an official KiCad part it does not." % [ref, message]}


## Write a worker `footprint_geometry` reply onto a component, making it
## FABRICABLE: real lands, real silk, the library's own body box, and the
## anchor the fab strokes its printed designator at.
##
## `pads_authored` is set because the geometry came from a resolve THIS host
## performed: the board now carries the lands outright (a `pads` key = the
## board is the authority), which is what keeps the part compiling on a machine
## whose library does not have the ref.
##
## `footprint_resolved` is the WORKER's fact, relayed — `build` reaches this
## only after `_fetch_geometry` got real geometry back over the
## pcb.footprint_geometry channel, so the flag records a resolve success rather
## than asserting one. It is the same fact a worker-deserialized board arrives
## carrying, which is what lets the badge, the status lead and
## panel_tools.canonical_wire_board read one flag whichever way the board got
## here. Both ways are THIS session's resolve: the flag is never restored from
## a document, and never written into one.
static func apply_geometry(comp, ref: String, geometry: Dictionary) -> void:
	comp.set_footprint_by_name("CUSTOM")
	comp.footprint_id = ref
	# load_pad_geometry owns the pads/pins/body-box half through the ONE pad
	# deserializer, so an added land keeps the same fab-affecting optionals a
	# loaded one keeps (corner_rratio above all).
	comp.load_pad_geometry({
		"footprint_id": ref,
		"has_pad_geometry": bool(geometry.get("has_pad_geometry", false)),
		"bounding_box": geometry.get("bounding_box", {}),
		"pads": geometry.get("pads", []),
	})
	comp.pads_authored = true
	comp.footprint_resolved = true
	var anchor: Variant = geometry.get("refdes_anchor")
	comp.load_footprint_graphics(
		geometry.get("graphics", []), anchor if anchor is Dictionary else {})


## The add verb's reply body for a built component — its identity, where it
## landed, and the geometry state a caller must read.
static func add_reply(comp, built: Dictionary) -> Dictionary:
	var reply: Dictionary = {
		"component_id": str(comp.id),
		"x": snapped(comp.position.x, 0.0001),
		"y": snapped(comp.position.y, 0.0001),
		"pin_count": comp.pins.size(),
		"geometry": geometry_state(comp),
	}
	if bool(built.get("by_ref", false)):
		var geometry: Dictionary = built.get("geometry", {})
		reply["footprint_layer"] = str(geometry.get("layer", ""))
		reply["footprint_sha256"] = str(geometry.get("sha256", ""))
	var ignored: Array = built.get("ignored", [])
	if not ignored.is_empty():
		reply["ignored"] = ignored
		reply["ignored_note"] = "the library footprint decides pad layout, pad kind, pitch and body size — these arguments were not applied"
	return reply


## Does this component carry geometry a fab could build from? The ONE
## definition, shared by the canvas badge, the status lead and every MCP reply
## that reports a part's geometry state, so they cannot disagree.
##
## The rule mirrors the worker's own (pad_source.has_resolved_pads plus the
## component-level footprint_resolved fact): real lands, or a footprint that
## legitimately has none — resolved this session, or with the board itself
## stating the empty land set (a silk-only logo) — or a mounting hole, which
## carries no copper by definition.
static func is_fabricable(comp) -> bool:
	if comp == null:
		return false
	if comp.footprint == _PcbComponent.FootprintType.MOUNTING_HOLE:
		return true
	if comp.has_pad_geometry and not comp.pads.is_empty():
		return true
	if comp.footprint_resolved and comp.pads.is_empty():
		return true
	# The board STATING an empty `pads` list owns this component's geometry
	# outright and says it has zero lands — the silk-only pseudo-component the
	# clause above catches while a resolve is still in memory. That statement
	# is authored board data, so it is the half that survives a reload on a
	# machine that has not resolved the ref this session (footprint_resolved is
	# session state and does not).
	#
	# `pins.is_empty()` is what makes this match the WORKER rather than merely
	# agree with it in the silk-only case. compile_board takes the FULL branch
	# on the `pads` KEY (inline_footprint.carries_full_geometry) and builds a
	# zero-pad definition without consulting the library — so a pin-less part
	# fabricates as zero lands. A component that states zero lands AND carries
	# positioned pins is a `pin_without_pad` ERROR there, and calling it
	# fabricable here would promise a board the worker refuses.
	if comp.pads_authored and comp.pads.is_empty() and comp.pins.is_empty():
		return true
	return false


## THE GEOMETRY BLOCK every add reply carries for one component — the MCP
## mirror of the badge and the lead, so an agent is told at ADD TIME what a
## human sees on the canvas.
##
## `source` is where the lands came from: "library" (a resolved ref),
## "authored" (the board carries them outright with no ref behind them), or
## "sketch" (the generic enums' estimated defaults). Only the last is
## unfabricable, and it says so in words rather than by an absent key.
static func geometry_state(comp) -> Dictionary:
	var fabricable := is_fabricable(comp)
	var source := "sketch"
	if comp.footprint_resolved:
		source = "library"
	elif comp.has_pad_geometry and not comp.pads.is_empty():
		source = "authored"
	elif comp.pads_authored and comp.pads.is_empty() and comp.pins.is_empty():
		# Same case as is_fabricable's authored-empty clause, pin guard and all:
		# the board states zero lands, which is a geometry statement, not an
		# absent one.
		source = "authored"
	elif comp.footprint == _PcbComponent.FootprintType.MOUNTING_HOLE:
		source = "mechanical"
	var out: Dictionary = {
		"fabricable": fabricable,
		"source": source,
		"footprint": comp.get_canonical_footprint_name(),
		"pad_count": comp.pads.size(),
	}
	if not fabricable:
		out["note"] = SKETCH_NOTE
	return out


## Every component on the board whose geometry cannot fabricate, by id, sorted
## so two reads of an unchanged board are byte-identical.
static func unresolved_ids(data) -> Array:
	if data == null:
		return []
	var out: Array = []
	for comp_id in data.components:
		if not is_fabricable(data.components[comp_id]):
			out.append(str(comp_id))
	out.sort()
	return out


## The held status lead naming the parts a fab cannot build, or "" when every
## part resolves — read straight off the live board by the panel's _status_lead.
##
## It LEADS the status line for the same reason the load checks do: it is a
## standing condition of the BOARD, true of everything done to the board
## afterwards, not a message about the gesture in hand. The words say what it
## costs — the compile refuses the whole board, so the geometric DRC and every
## pour fill are unavailable, not merely this part.
static func board_lead(data) -> String:
	return status_lead(unresolved_ids(data))


static func status_lead(ids: Array) -> String:
	if ids.is_empty():
		return ""
	var named: Array = ids.slice(0, mini(4, ids.size()))
	var rest := ids.size() - named.size()
	var who := ", ".join(PackedStringArray(named))
	if rest > 0:
		who += " +%d more" % rest
	return "%d part%s have no fabricable geometry (%s) — the compile refuses the board, so geometric DRC and pour fills are unavailable until they resolve or go  •  " % [
		ids.size(), "" if ids.size() == 1 else "s", who]
