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
## The per-leg staleness gate: a part that has not started measuring yet is
## refused when the document has moved past the evaluation.
const _Freshness: Script = preload("eval_freshness.gd")

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
## EVALUATED ONCE PER DOCUMENT. Every leg of every check asks for the same
## bindings, and a binding of a source that has not changed is the same shape
## every time, so the answer is kept in part_cache.gd against the document's
## source digest and only the first asking reaches the worker. The moment the
## document evaluates to something else the digest moves and the whole slot
## goes with it, so no leg can ever be handed the previous document's part.
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
	# A binding the worker REFUSED is kept: that is the same refusal for every
	# leg of the same document, and re-asking three times to be told the same
	# thing is what this cache exists to stop. A TRANSIENT failure is not —
	# a timeout, a cancellation or a request that never reached the worker
	# says nothing about the binding, and caching it makes one slow evaluation
	# read as "part did not evaluate" for the life of the document.
	if result.has("error"):
		var refused := {"error": ("part '%s' did not evaluate: %s — a `parts` "
			+ "entry must name a binding the document assigns a 3D shape to")
			% [part, str(result["error"])]}
		if not bool(result.get("transient", false)):
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


## Run a check once per part and say which part each answer is about.
##
## `fresh` is panel_tools' own re-pose wrapper, handed in rather than reached
## for: this script is preloaded BY the verb layer, and preloading it back
## would be a cycle.
##
## With no `parts` the check runs once, against the shape the document
## evaluates to, and the reply NAMES that shape, which is the answer to "which
## half did you just check". With `parts`, each named binding is evaluated on its own (part_scope appends it
## as the trailing expression, the DSL's own render-target rule) and checked
## against its own mesh, and the replies come back together under `parts` with
## `pass` true only when every one of them passed. The parts run one after
## another because they share the panel's single solid collider.
static func per_part(panel, args: Dictionary, verb: Callable,
		fresh: Callable) -> Dictionary:
	var wanted: Array = names(args)
	if wanted.is_empty():
		var single: Dictionary = await fresh.call(panel, args, verb)
		var target: String = render_target(panel)
		if not target.is_empty():
			single["part"] = target
		return single

	var rows: Array = []
	var failed := 0
	# The legs that answered without measuring anything, named for pass_reason.
	var unmeasured: Array[String] = []
	# The legs that measured but carry no verdict of their own. A material row
	# reports what is there and grades nothing, so there is no pass to fold —
	# and reading the missing key as true made every parts= material call
	# answer pass:true whatever it found.
	var ungraded: Array[String] = []
	for entry in wanted:
		var part := str(entry)
		# RE-GATED PER LEG. A part evaluates in the worker and its check stands
		# in the collider's wait line, and the document can be edited across
		# either; the gate in handle() ran before the first leg only. A leg
		# that has already measured cannot be un-measured, so the reply it
		# produced keeps its stale stamp — this refuses the legs that have not
		# started yet rather than adding one more answer about geometry the
		# document has moved past.
		var standing: Dictionary = _Freshness.read(panel)
		if bool(standing.get("stale", false)) and bool(standing.get("known", false)):
			var refused := {"part": part, "checked": false,
				"reason": str(standing.get("stale_reason", "")), "stale": true}
			rows.append(refused)
			unmeasured.append(_unmeasured_leg(part, refused))
			failed += 1
			continue
		var resolved: Dictionary = await resolve(panel, part)
		if resolved.has("error"):
			var unresolved := {"part": part, "checked": false,
				"reason": str(resolved["error"])}
			rows.append(unresolved)
			unmeasured.append(_unmeasured_leg(part, unresolved))
			failed += 1
			continue
		var scoped: Dictionary = args.duplicate(true)
		scoped.erase("parts")
		# What the check measures instead of the document's own render target:
		# this part's tessellation for the colliders, and the source that
		# produced it for anything the worker re-evaluates.
		scoped["mesh"] = resolved["mesh"]
		scoped["source"] = resolved["source"]
		var one: Dictionary = await fresh.call(panel, scoped, verb)
		one["part"] = part
		rows.append(one)
		# A LEG THAT MEASURED NOTHING IS NOT A PASS. A check that hands back a
		# ticket answers `checked: false` and carries no verdict at all, so
		# reading its missing `pass` as true let the aggregate say the design
		# cleared before a single number existed. Absent `checked` still
		# defaults to true — only a leg that SAYS it measured nothing counts.
		if not bool(one.get("checked", true)):
			unmeasured.append(_unmeasured_leg(part, one))
			failed += 1
		elif not bool(one.get("success", true)):
			failed += 1
		elif not one.has("pass"):
			ungraded.append(part)
		elif not bool(one.get("pass", true)):
			failed += 1
	# NO VERDICT IS NOT A PASS. A verb whose legs grade nothing aggregates to
	# null rather than true: absent evidence and cleared evidence are
	# different answers, and only one of them may be acted on.
	var verdict: Variant = null
	if ungraded.is_empty():
		verdict = failed == 0 and not rows.is_empty()
	var reply := {
		"parts": rows,
		"count": rows.size(),
		"failed": failed,
		"pass": verdict,
		"parts_note": "each part is the document evaluated with that binding "
			+ "as its trailing expression, which is the DSL\'s own "
			+ "render-target rule; a part that does not evaluate is reported "
			+ "as checked:false with the reason and does not silently drop "
			+ "out of the count",
	}
	if not ungraded.is_empty():
		reply["pass_reason"] = ("%s report what was measured and grade "
			% ", ".join(ungraded)) + "nothing, so there is no verdict to "\
			+ "aggregate — read the rows"
	if not unmeasured.is_empty():
		reply["pass_reason"] = "nothing was measured for %s — this verdict is "\
			% ", ".join(unmeasured) \
			+ "not a pass, it is the absence of an answer"
	reply["success"] = true
	return reply


## How an unmeasured leg is named in `pass_reason`: the ticket it can be
## collected with when it has one, and its own reason otherwise.
static func _unmeasured_leg(part: String, row: Dictionary) -> String:
	var ticket := str(row.get("ticket", ""))
	if not ticket.is_empty():
		return "%s (ticket %s, still %s)" % [part, ticket,
			str(row.get("status", "running"))]
	return "%s (%s)" % [part, str(row.get("reason", "no reason given"))]
