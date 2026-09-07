extends RefCounted
## part_cache.gd — what a named part is, evaluated once.
##
## A part-scoped check (`parts: ["bottom", "top"]`) reaches its binding by
## evaluating the document with that binding as the trailing expression — see
## part_scope.gd. That evaluation is a full worker translate, minutes on a
## lofted shell, and it used to happen once per LEG: minerva_cad_check_design
## over four parts asked the worker for the same four shapes three times over,
## and the caller's window closed before the twelfth answer came back.
##
## Nothing about a binding changes between the legs of one call, so this is a
## cache and not a scheduler. It holds three things per document:
##
##   the resolved PART — the scoped source, the worker's tessellation of it
##   and the shape name — keyed by binding name, so every leg of every verb
##   evaluates a binding at most once;
##
##   the part's own INTERFERENCE report, keyed by the digest of the scoped
##   source that produced it, so the clearance check can join against the
##   report for THAT part. Joining the document's report instead cannot work:
##   the document's solid is the union, and a node buried in the union may be
##   nowhere near the half being measured.
##
## WHAT INVALIDATES IT. The document's own source digest. The moment the panel
## evaluates something else, every binding of the old source is a different
## shape and the whole slot is dropped — there is no per-entry expiry, because
## a part of a document that no longer exists is never right and a part of the
## document standing now is never wrong. Reference POSES are not covered here
## and must not be: an interference report is joined only after its stored
## records digest and gauge generation are compared against the state standing
## at join time, which is clearance_report.gd's job and stays there.
##
## ONE SLOT PER PANEL. Two CAD tabs are two documents, and a store with one
## slot would have each tab evicting the other's parts on every check. Slots
## are keyed by the panel's instance id, bounded, and a slot whose panel has
## been freed is dropped on the next touch.
##
## No class_name: off-tree plugin scripts cannot use class_name.
## Consumers: scripts/part_scope.gd (the parts), scripts/geometry_checks.gd
## (writes the per-part interference report), scripts/clearance_report.gd
## (joins it), ui/panel_tools.gd (asks whether a part has one yet).

## Panels kept at once. Two open CAD tabs is the case this exists for; past
## that the least recently touched slot goes, and its parts are evaluated
## again when that panel is next asked about.
const MAX_PANELS: int = 3

## Bindings kept per document. A part is a full tessellation and costs real
## memory, and a document with more distinct bindings than this in flight at
## once is not the acceptance loop this serves.
const MAX_PARTS: int = 8


## panel instance id -> {panel, document, parts: {name: resolved},
## interference: {scoped_digest: report}, order: [name]}. `order` is the
## insertion order the part bound evicts from.
static var _slots: Dictionary = {}
## Instance ids in least-recently-touched order; the front goes first.
static var _touched: Array[int] = []


## SHA-256 of a DSL source, hex — the same derivation the interference report
## is stamped with, so a digest computed here and one computed there name the
## same source or neither does.
static func digest(source: String) -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	# update() refuses an empty buffer with an engine error; finish() alone
	# still gives the digest of the empty string, which is what a document
	# with no source is.
	var bytes := source.to_utf8_buffer()
	if not bytes.is_empty():
		hasher.update(bytes)
	return hasher.finish().hex_encode()


## Point this panel's slot at `document_digest`, dropping everything it holds
## when that is not what it held before. Called before the first lookup of a
## part-scoped call, which is the only moment the document can have moved on
## without this store hearing about it.
static func retain(panel: Object, document_digest: String) -> void:
	var slot := _slot(panel)
	if slot.is_empty():
		return
	if str(slot["document"]) == document_digest:
		return
	slot["document"] = document_digest
	slot["parts"] = {}
	slot["interference"] = {}
	slot["order"] = []


## The resolved part — {source, mesh, shape_name} — or {} when this document
## has not evaluated that binding.
static func part(panel: Object, part_name: String) -> Dictionary:
	var slot := _slot(panel)
	if slot.is_empty():
		return {}
	return (slot["parts"] as Dictionary).get(part_name, {}) as Dictionary


## Keep a binding's evaluation. `resolved` is part_scope's own reply shape and
## is stored as handed over; the caller owns it afterwards.
static func put_part(panel: Object, part_name: String, resolved: Dictionary) -> void:
	var slot := _slot(panel)
	if slot.is_empty() or resolved.is_empty():
		return
	var parts: Dictionary = slot["parts"]
	var order: Array = slot["order"]
	if not parts.has(part_name):
		order.append(part_name)
	parts[part_name] = resolved
	while order.size() > MAX_PARTS:
		var evicted := str(order.pop_front())
		parts.erase(evicted)


## The interference report measured against the source whose digest is
## `scoped_digest`, or {} when no part-scoped check has produced one for this
## document. The freshness of what comes back — the poses and the colliders it
## was measured against — is the JOINER's question, not this store's.
static func interference(panel: Object, scoped_digest: String) -> Dictionary:
	var slot := _slot(panel)
	if slot.is_empty():
		return {}
	return (slot["interference"] as Dictionary).get(scoped_digest, {}) as Dictionary


## Keep the interference report for one part. Only an UNSCOPED report belongs
## here — one measured with no reference= or node= filter — because a joiner
## reads a missing pair as "no crossing there", and a report that only looked
## at one reference would excuse every node it never examined. The caller
## enforces that; this stores what it is given.
static func put_interference(panel: Object, scoped_digest: String,
		report: Dictionary) -> void:
	var slot := _slot(panel)
	if slot.is_empty() or scoped_digest.is_empty() or report.is_empty():
		return
	var reports: Dictionary = slot["interference"]
	reports[scoped_digest] = report
	# One report per part, and the parts are already bounded; trimming to the
	# same bound keeps a document that churns bindings from growing this half
	# without limit.
	while reports.size() > MAX_PARTS:
		reports.erase(reports.keys()[0])


## Drop this panel's slot. Called when the panel goes away: the sweep in
## _slot() only runs when some OTHER panel touches the store, so the last tab
## to close would otherwise leave its tessellations in a static var for the
## life of the process.
static func forget(panel: Object) -> void:
	if panel == null:
		return
	var id := int(panel.get_instance_id())
	_slots.erase(id)
	_touched.erase(id)


## Drop everything, for a suite that wants a cold store between cases.
static func clear() -> void:
	_slots = {}
	_touched = []


## How many bindings this panel has evaluated and kept. The count a suite
## reads to prove a second leg did not evaluate again.
static func part_count(panel: Object) -> int:
	var slot := _slot(panel)
	return 0 if slot.is_empty() else (slot["parts"] as Dictionary).size()


## This panel's slot, made if it has none, with dead panels swept and the
## panel bound honoured. {} for a panel that cannot own one.
static func _slot(panel: Object) -> Dictionary:
	if panel == null or not is_instance_valid(panel):
		return {}
	var id := int(panel.get_instance_id())
	for key in _slots.keys():
		var held: Dictionary = _slots[key]
		var owner: Object = held["panel"]
		if owner == null or not is_instance_valid(owner):
			_slots.erase(key)
			_touched.erase(int(key))
	if not _slots.has(id):
		_slots[id] = {"panel": panel, "document": "", "parts": {},
			"interference": {}, "order": []}
	_touched.erase(id)
	_touched.append(id)
	while _touched.size() > MAX_PANELS:
		_slots.erase(_touched.pop_front())
	return _slots[id] as Dictionary
