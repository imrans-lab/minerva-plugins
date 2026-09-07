extends RefCounted
## Which PART of the document a check is about.
##
## A .mcad program evaluates to exactly one render target — the last 3D binding
## it assigns, or the shape a trailing bare expression names — and every check
## measures that one shape. A two-shell enclosure is usually written as several
## bindings (`bottom`, `top`, `door`) that are unioned at the end, and while the
## author is iterating on one half the document evaluates to that half. Asking
## "does it interfere" then silently answered about whichever half was current,
## and the reply never said which.
##
## Two things fix that, and they are the whole module:
##
##   every check names the part it measured, so an answer can never be read as
##   being about a part it is not about; and
##
##   a check can be asked about NAMED bindings instead, `parts: ["bottom",
##   "top"]`, and reports one result per part.
##
## HOW A NAMED BINDING IS REACHED. Not by a second evaluator: the DSL already
## has a documented rule for choosing the render target — a trailing bare
## expression selects the shape it names — so the source for part `bottom` is
## the document's own source with `bottom` appended on its own line. That is
## the same program the author would run to look at that half, evaluated by the
## same worker, so no part of this module can disagree with what the panel
## would show. It costs one translate per part, which is what looking at that
## half costs anyway.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: preload("scripts/part_scope.gd") from panel_tools.gd.

const _WorkerReply: Script = preload("worker_reply.gd")
## Evaluated once per (document, binding) and read by every leg after the
## first. Without it a three-legged verb pays for each binding three times.
const _PartCache: Script = preload("part_cache.gd")

## Channel name = MCP tool name; the worker method behind it is "evaluate".
const EVALUATE_CHANNEL: String = "cad.evaluate"
## A named part is translated from scratch, which on a lofted shell is the same
## cost as evaluating it in the panel.
const EVALUATE_TIMEOUT_MS: int = 600000

## A binding name the DSL could actually have bound. Refusing anything else
## keeps the appended line from being an arbitrary expression evaluated in the
## document's own scope.
const NAME_PATTERN: String = "^[A-Za-z_][A-Za-z0-9_]*$"


## The parts the caller asked about, in order and without repeats. Empty means
## "the part the document evaluates to", which is the default and what every
## check did before this argument existed.
static func names(args: Dictionary) -> Array:
	var raw: Array = args.get("parts", []) as Array
	var out: Array = []
	for entry in raw:
		var name := str(entry).strip_edges()
		if name.is_empty() or out.has(name):
			continue
		out.append(name)
	return out


## Is `name` a bare DSL binding name? A `parts` entry is appended to the
## source as a statement, so anything else is refused rather than run.
static func is_binding_name(name: String) -> bool:
	var expression := RegEx.new()
	expression.compile(NAME_PATTERN)
	return expression.search(name) != null


## The source that evaluates to `part`: the document's own source with the
## binding named on the last line, which is the DSL's render-target rule.
static func source_for(source: String, part: String) -> String:
	return source.rstrip("\n \t") + "\n" + part + "\n"


## The name the document itself evaluates to, or "" when nothing has evaluated
## yet. Reported on every single-part check so the reply says what it is about.
static func render_target(panel: Object) -> String:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("get_document_state"):
		return ""
	var document: Dictionary = panel.get_document_state()
	var last: Dictionary = document.get("last_eval", {}) as Dictionary
	return str(last.get("shape_name", ""))


## The source and the mesh for one named part, or {error}. The mesh is the
## worker's own tessellation of that binding — the same one the panel would
## render — so a collider built from it is the part, not an approximation of
## it.
##
## EVALUATED ONCE PER DOCUMENT. Every check leg asks for the same bindings —
## minerva_cad_check_design asks three times over — and a binding of a source
## that has not changed is the same shape every time, so the answer is kept in
## part_cache.gd against the document's source digest and only the first
## asking reaches the worker. The moment the document evaluates to something
## else the digest moves and the whole slot goes with it, so no leg can ever
## be handed the previous document's part.
static func resolve(panel: Object, part: String) -> Dictionary:
	if panel == null or not is_instance_valid(panel) \
			or not panel.has_method("get_document_state") \
			or not panel.has_method("call_backend"):
		return {"error": "this panel cannot evaluate a named part"}
	if not is_binding_name(part):
		return {"error": ("'%s' is not a DSL binding name; `parts` names "
			+ "bindings the document assigns (bottom, top, door), one per "
			+ "entry") % part}
	var document: Dictionary = panel.get_document_state()
	var source := str(document.get("source", ""))
	if source.strip_edges().is_empty():
		return {"error": "there is no DSL source to evaluate a part from"}
	_PartCache.retain(panel, _PartCache.digest(source))
	var kept: Dictionary = _PartCache.part(panel, part)
	if not kept.is_empty():
		return kept
	var scoped := source_for(source, part)
	var envelope: Variant = await panel.call_backend(EVALUATE_CHANNEL,
		{"source": scoped}, EVALUATE_TIMEOUT_MS)
	var result: Dictionary = _WorkerReply.unwrap(envelope, "part '%s'" % part)
	# A binding that will not evaluate is kept too: it is the same refusal for
	# every leg of the same document, and re-asking the worker three times to
	# be told the same thing is what this cache exists to stop.
	if result.has("error"):
		var refused := {"error": ("part '%s' did not evaluate: %s — a `parts` "
			+ "entry must name a binding the document assigns a 3D shape to")
			% [part, str(result["error"])]}
		_PartCache.put_part(panel, part, refused)
		return refused
	var mesh: Dictionary = result.get("mesh", {}) as Dictionary
	if (mesh.get("faces", []) as Array).is_empty():
		var empty := {"error": "part '%s' produced no solid geometry" % part}
		_PartCache.put_part(panel, part, empty)
		return empty
	var resolved := {
		"source": scoped,
		"mesh": mesh,
		"shape_name": str(result.get("shape_name", part)),
	}
	_PartCache.put_part(panel, part, resolved)
	return resolved
