extends RefCounted
## Scope resolution and lifetime for queries that must not move the visible model.
const Context := preload("query_context.gd")
const Reply := preload("worker_reply.gd")
const Freshness := preload("eval_freshness.gd")
const META := "cad_query_contexts"
const MAX_CONTEXTS := 4
const KEEP_MS := 900000
const TOOLS := ["minerva_cad_references", "minerva_cad_find_holes", "minerva_cad_find_cylinders",
	"minerva_cad_reference_profile", "minerva_cad_probe", "minerva_cad_snapshot_fit", "minerva_cad_snapshot_posed"]

static func applies(tool: String, args: Dictionary) -> bool:
	return str(args.get("ticket", "")).begins_with("context:") or ((tool in TOOLS or tool in Freshness.MEASURING_VERBS)
		and (args.has("selection") or args.has("configuration")))

static func run(panel: Node, tool: String, args: Dictionary, dispatch: Callable) -> Dictionary:
	var contexts: Dictionary = panel.get_meta(META, {})
	panel.set_meta(META, contexts)
	for id in contexts.keys():
		var old: Node = contexts[id]
		if not old.busy and Time.get_ticks_msec() - old.last_used > KEEP_MS:
			old.queue_free()
			contexts.erase(id)
	var ticket := str(args.get("ticket", ""))
	var context: Node
	var context_id := ""
	var scoped := args.duplicate(true)
	if ticket.begins_with("context:"):
		var pieces := ticket.split(":", true, 2)
		context_id = pieces[1]
		context = contexts.get(context_id)
		if context == null:
			return _error("Query context expired or belongs to another document", "unknown_context")
		if context.busy:
			return _error("Query context is handling another request", "context_busy")
		scoped["ticket"] = pieces[2] if pieces.size() == 3 else ""
	else:
		var document: Dictionary = args.get("_evaluated_document", {})
		var model: Dictionary = document.get("model", {})
		var selection := str(args.get("selection", model.get("selection", "")))
		var configuration := str(args.get("configuration", model.get("configuration", "")))
		if selection == str(model.get("selection", "")) and configuration == str(model.get("configuration", "")):
			return await dispatch.call(panel, tool, args)
		if contexts.size() >= MAX_CONTEXTS:
			return _error("Four scoped query jobs are retained; collect their tickets before starting another", "context_capacity")
		context = Context.new()
		context_id = str(context.get_instance_id())
		context.busy = true
		contexts[context_id] = context
		panel.add_child(context)
		var requested := {"source": str(document.get("source", "")), "selection": selection, "configuration": configuration}
		var result := Reply.unwrap(await panel.call_backend("cad.evaluate", requested, 600000), "scoped model")
		if result.has("error"):
			contexts.erase(context_id)
			context.queue_free()
			return _error(str(result.error), "selection_failed")
		if tool.begins_with("minerva_cad_check_") and not bool(result.get("model", {}).get("physical", true)):
			contexts.erase(context_id)
			context.queue_free()
			return _error("Presentation-only configuration cannot pass physical validation", "configuration_context")
		var references: Array = result.get("references", [])
		# A selected solid is checked against the configuration's references;
		# a capture/inspection shows only its explicitly selected geometry.
		if tool in Freshness.MEASURING_VERBS and not selection.is_empty():
			requested.selection = ""
			var whole := Reply.unwrap(await panel.call_backend("cad.evaluate", requested, 600000), "configuration references")
			if whole.has("error"):
				contexts.erase(context_id)
				context.queue_free()
				return _error(str(whole.error), "selection_failed")
			references = whole.get("references", [])
		context.setup(panel, document, result, references)
		scoped["selection"] = selection
		scoped["configuration"] = configuration
	var freshness: Dictionary = context.evaluation_freshness()
	if not args.has("ticket") and not Freshness.accepts_stale(args) and freshness.get("stale", false):
		contexts.erase(context_id)
		context.queue_free()
		return Freshness.refusal(freshness)
	context.busy = true
	context.last_used = Time.get_ticks_msec()
	scoped["_evaluated_document"] = context.document
	scoped["source"] = context.document.get("source", "")
	scoped["mesh"] = context.document.get("mesh", {})
	if tool.begins_with("minerva_cad_snapshot") and not scoped.has("fit") and scoped.mesh.get("faces", []).is_empty():
		var bounds: AABB = context.report.get("world_aabb", AABB())
		if bounds.size.length() > 0:
			scoped["fit"] = [[bounds.position.x,bounds.position.y,bounds.position.z], [bounds.end.x,bounds.end.y,bounds.end.z]]
	var result: Dictionary = await dispatch.call(context, tool, scoped)
	result["model_scope"] = context.document.get("model", {})
	result["provenance"] = context.document.get("provenance", {})
	result = Freshness.stamp(result, context.evaluation_freshness())
	context.busy = false
	context.last_used = Time.get_ticks_msec()
	var pending := _wrap_tickets(result, context_id)
	if not pending and context.checks._jobs.is_empty():
		contexts.erase(context_id)
		context.queue_free()
	return result

static func _wrap_tickets(value: Variant, id: String) -> bool:
	var pending := false
	if value is Dictionary:
		if value.has("ticket") and not str(value.ticket).is_empty():
			value.ticket = "context:" + id + ":" + str(value.ticket)
			pending = str(value.get("status", "")) in ["running", "pending"]
		if value.has("tickets"):
			value.tickets = _ticket_values(value.tickets, id)
			pending = pending or (not value.tickets.is_empty() and str(value.get("status", "")) in ["running", "pending"])
		for child in value.values():
			pending = _wrap_tickets(child, id) or pending
	elif value is Array:
		for child in value:
			pending = _wrap_tickets(child, id) or pending
	return pending

## Design checks expose per-part continuation handles as a dictionary of strings.
static func _ticket_values(value: Variant, id: String) -> Variant:
	if value is String:
		return "context:" + id + ":" + value if not value.is_empty() and not value.begins_with("context:") else value
	if value is Dictionary:
		for key in value:
			value[key] = _ticket_values(value[key], id)
	return value

static func _error(message: String, code: String) -> Dictionary:
	return {"success": false, "checked": false, "pass": null, "reason": message, "error_code": code}
