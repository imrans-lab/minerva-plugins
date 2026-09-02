extends SceneTree
## Epoch UX4 station 2 (docket 019fe0818bba; DCR 019fe07523ca S1/S5/F8):
## the staged-entity store, the create-verb build/add split with id
## passthrough, and the bucket-9 history participant.
##
## Run (via a Minerva scaffold as the Godot host — NEVER the live checkout):
##   godot --headless --path <minerva-scaffold>/src \
##     --script res://../../minerva-plugins/pcb/tests/gd/test_staged_entities.gd

const PcbDataScript := preload("res://../../minerva-plugins/pcb/ui/model/pcb_data.gd")
const StagedEntities := preload("res://../../minerva-plugins/pcb/ui/model/pcb_staged_entities.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Staged entities: store, build/add split, bucket-9 history ===\n")
	_run_build_add_split()
	_run_id_passthrough()
	_run_store_lifecycle()
	_run_store_serialisation()
	_run_bucket9_history()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func _board():
	var d = PcbDataScript.new()
	d.from_board_dict({
		"version": 1, "name": "staged", "width_mm": 30.0, "height_mm": 30.0,
		"design_rules": {"clearance_mm": 0.2},
		"layers": ["top", "bottom"],
		"components": [], "nets": [{"name": "GND", "pins": []}],
		"traces": [], "vias": [],
	})
	return d


const TRI := [Vector2(2, 2), Vector2(8, 2), Vector2(8, 8)]


# ── 1. the split: create == build + add, byte-compatible ──────────────────────

func _run_build_add_split() -> void:
	print("-- 1. build/add split: byte-compatible create, no-write build --")
	var d = _board()

	# BUILD alone touches nothing.
	var built: Dictionary = d.build_zone_payload("", "top", TRI, "keepout")
	check("build_zone_payload ok", bool(built.get("ok", false)))
	var payload: Dictionary = built.get("payload", {})
	check("…payload carries a MINTED zone id", str(payload.get("id", "")).begins_with("zone:"))
	check("…netless keepout has NO net key (canonical omitempty shape)", not payload.has("net"))
	check_eq("…and the board is untouched (no write, no journal)", d.zones.size(), 0)

	# BUILD refusal is the author refusal, verbatim shape.
	var refused: Dictionary = d.build_zone_payload("NOPE", "top", TRI, "copper_pour")
	check("build refuses an undeclared pour net", not bool(refused.get("ok", true)))
	check("…with the author refusal text", str(refused.get("error", "")).contains("not declared"))

	# CREATE still behaves exactly as shipped: dict on success, {} + warning on refusal.
	var created: Dictionary = d.create_zone("GND", "top", TRI, "copper_pour")
	check("create_zone (post-split) returns the zone dict", not created.is_empty())
	check_eq("…and the board holds it", d.zones.size(), 1)
	check("create_zone refusal still returns {}", d.create_zone("NOPE", "top", TRI).is_empty())
	check_eq("…writing nothing", d.zones.size(), 1)

	# Cutout twin.
	var cbuilt: Dictionary = d.build_cutout_payload(TRI)
	check("build_cutout_payload ok", bool(cbuilt.get("ok", false)))
	check("…minted cutout id", str((cbuilt.get("payload", {}) as Dictionary).get("id", "")).begins_with("cutout:"))
	check_eq("…no write", d.cutouts.size(), 0)
	check("create_cutout (post-split) still lands", not d.create_cutout(TRI).is_empty())
	check_eq("…on the board", d.cutouts.size(), 1)


# ── 2. id passthrough on the ADD half (DCR F3) ────────────────────────────────

func _run_id_passthrough() -> void:
	print("-- 2. add_*_payload: id preserved, format + uniqueness enforced --")
	var d = _board()
	var built: Dictionary = d.build_zone_payload("", "top", TRI, "keepout")
	var payload: Dictionary = built.get("payload", {})
	var minted := str(payload.get("id", ""))

	var added: Dictionary = d.add_zone_payload(payload)
	check_eq("the id rode THROUGH the add (accept keeps identity)",
		str(added.get("id", "")), minted)
	check("the landed dict is byte-identical to the built payload (A1's model half)",
		str(added) == str(payload))

	# Duplicate id refuses (the passthrough's own guard).
	check("re-adding the same payload refuses (duplicate id)",
		d.add_zone_payload(payload).is_empty())
	check_eq("…and wrote nothing", d.zones.size(), 1)

	# Non-minted id refuses.
	var fake: Dictionary = payload.duplicate(true)
	fake["id"] = "staged_1"
	check("a non-minted id refuses (staged_N is the STORE's key, never the payload id)",
		d.add_zone_payload(fake).is_empty())

	# Re-validation against the CURRENT board is the load-bearing gate (A5's
	# model half): stage-shaped drift — the layer leaves the stack — refuses.
	var drifted: Dictionary = d.build_zone_payload("GND", "top", TRI, "copper_pour").get("payload", {})
	d.layers.assign(["bottom"])
	check("add refuses a payload whose layer left the board (drift surfaces at accept)",
		d.add_zone_payload(drifted).is_empty())


# ── 3. store lifecycle ────────────────────────────────────────────────────────

func _run_store_lifecycle() -> void:
	print("-- 3. store: stage, terminal stamps, resolver reads --")
	var d = _board()
	var store = StagedEntities.new()
	var payload: Dictionary = d.build_zone_payload("", "top", TRI, "keepout").get("payload", {})

	var sid := str(store.stage("zone", payload, "ai", 3, "keep the antenna clear"))
	check("stage returns a store key", sid.begins_with("staged_"))
	check_eq("one live entry", store.staged_entries().size(), 1)
	check_eq("payload readable by kind", store.staged_payloads("zone").size(), 1)
	check_eq("…and none of the other kind", store.staged_payloads("cutout").size(), 0)
	check_eq("canonical-id → store-key resolver works",
		str(store.staged_id_for_entity(str(payload.get("id", "")))), sid)

	# Refusals by name.
	check("unknown kind refuses", str(store.stage("via", payload)).is_empty())
	check_eq("…named", str(store.last_error.get("error", "")), StagedEntities.ERR_BAD_KIND)
	check("id-less payload refuses", str(store.stage("zone", {"x": 1})).is_empty())
	check("re-staging a LIVE canonical id refuses (resolver stays unambiguous)",
		str(store.stage("zone", payload)).is_empty())
	check_eq("…named", str(store.last_error.get("error", "")), StagedEntities.ERR_DUPLICATE_ENTITY)
	check("a non-terminal stamp refuses by the DISPOSITION code",
		not store.stamp(sid, "staged", "reopen"))
	check_eq("…named", str(store.last_error.get("error", "")), StagedEntities.ERR_BAD_DISPOSITION)
	# get_entry hands out a COPY — in-place mutation must not reach the store.
	var leaked: Dictionary = store.get_entry(sid)
	leaked["disposition"] = "accepted"
	check_eq("get_entry is a copy (terminal guard not bypassable in place)",
		str(store.get_entry(sid).get("disposition", "")), "staged")

	# Terminal pair.
	check("reject stamps", store.reject(sid))
	check_eq("…terminal", str(store.get_entry(sid).get("disposition", "")), "rejected")
	check("a second stamp refuses (terminal)", not store.reject(sid))
	check_eq("…named", str(store.last_error.get("error", "")), StagedEntities.ERR_TERMINAL)
	check_eq("rejected entries leave the LIVE set", store.staged_entries().size(), 0)
	check("…and the resolver no longer finds them",
		str(store.staged_id_for_entity(str(payload.get("id", "")))).is_empty())
	check("stamping an unknown entry refuses", not store.reject("staged_99"))


# ── 4. serialisation: round trip, tolerance, high-water ───────────────────────

func _run_store_serialisation() -> void:
	print("-- 4. store serialisation: round trip, tolerant load, high-water counter --")
	var d = _board()
	var store = StagedEntities.new()
	var p1: Dictionary = d.build_zone_payload("", "top", TRI, "keepout").get("payload", {})
	var p2: Dictionary = d.build_cutout_payload(TRI).get("payload", {})
	var s1 := str(store.stage("zone", p1, "human", 1))
	var s2 := str(store.stage("cutout", p2, "ai", 2))
	store.reject(s2)

	var out: Dictionary = store.to_dict()
	var restored = StagedEntities.from_dict(out)
	check_eq("round trip keeps both entries", restored.entries.size(), 2)
	check_eq("…the live one live", str(restored.get_entry(s1).get("disposition", "")), "staged")
	check_eq("…the rejected one terminal (audit survives)",
		str(restored.get_entry(s2).get("disposition", "")), "rejected")
	check("…payload byte-identical through the trip",
		str(restored.get_entry(s1).get("payload", {})) == str(p1))
	var p3: Dictionary = d.build_zone_payload("GND", "top", TRI, "copper_pour").get("payload", {})
	check("post-load stage cannot collide (high-water counter)",
		str(restored.stage("zone", p3)) == "staged_3")

	# Tolerant load: unknown kind dropped with a warning, bad disposition reset.
	# The dirty dict ALSO drops the stored counter and renumbers the surviving
	# key to staged_7, so the high-water restore is exercised on the KEY path
	# alone (a hand-edited sidecar is exactly this shape — cold review F6c;
	# with both halves equal the check was degenerate).
	var dirty: Dictionary = out.duplicate(true)
	dirty.erase("counter")
	var entries_d: Dictionary = dirty["entries"]
	entries_d["staged_7"] = entries_d[s1]
	entries_d.erase(s1)
	entries_d.erase(s2)
	entries_d["staged_9"] = {"kind": "via", "payload": {"id": "x"}}
	(entries_d["staged_7"] as Dictionary)["disposition"] = "banana"
	# Codex UX4 F4: the load path enforces stage()'s own invariants — an
	# id-less payload and a second LIVE twin of one canonical id both drop.
	entries_d["staged_11"] = {"kind": "zone", "payload": {"kind": "keepout"}, "disposition": "staged"}
	entries_d["staged_12"] = {"kind": "zone",
		"payload": (entries_d["staged_7"] as Dictionary).get("payload", {}).duplicate(true),
		"disposition": "staged"}
	var tolerant = StagedEntities.from_dict(dirty)
	check("unknown-kind entry quarantined (dropped), store survives",
		tolerant.get_entry("staged_9").is_empty())
	check_eq("garbled disposition resets to staged",
		str(tolerant.get_entry("staged_7").get("disposition", "")), "staged")
	check("an id-less payload is dropped at load (stage()'s own refusal, F4)",
		tolerant.get_entry("staged_11").is_empty())
	check("a second LIVE twin of one canonical id is dropped (first wins, F4)",
		tolerant.get_entry("staged_12").is_empty())
	check_eq("…so the resolver stays unambiguous",
		str(tolerant.staged_id_for_entity(
			str((tolerant.get_entry("staged_7") as Dictionary).get("payload", {}).get("id", "")))),
		"staged_7")
	var fresh_payload: Dictionary = d.build_zone_payload("GND", "top", TRI, "copper_pour").get("payload", {})
	check_eq("high-water restores from KEYS when the counter field is absent",
		str(tolerant.stage("zone", fresh_payload)), "staged_8")


# ── 5. bucket-9 history (DCR F8) ──────────────────────────────────────────────

func _run_bucket9_history() -> void:
	print("-- 5. bucket 9: bound-only snapshots, attach idiom, undo restores staged --")
	var d = _board()

	# UNBOUND: snapshots stay byte-identical to the nine-bucket-less shape.
	d.save_to_history("seed")
	check("unbound board's snapshot carries NO staged key",
		not (d.history[d.history_index] as Dictionary).has("staged"))

	var store = StagedEntities.new()
	d.bind_staged_store(store)
	var payload: Dictionary = d.build_zone_payload("", "top", TRI, "keepout").get("payload", {})
	var sid := str(store.stage("zone", payload))

	# THE ACCEPT IDIOM (station 5 will wrap this; the codec is what's pinned
	# here): attach the PRE-accept staged layer onto the top entry, mutate the
	# board, STAMP, then snapshot — the stamp precedes save_to_history so the
	# accept entry records "accepted" and redo restores it (cold review F1:
	# snapshot-before-stamp records "staged" and redo would revive the ghost
	# over the landed zone).
	check("attach_staged_snapshot stamps the top entry", d.attach_staged_snapshot())
	check_eq("…recording the pre-accept disposition",
		str(((d.history[d.history_index] as Dictionary).get("staged", {}) as Dictionary).get(sid, "")),
		"staged")
	var landed: Dictionary = d.add_zone_payload(payload)
	check("the accept's board write lands", not landed.is_empty())
	check("…the store stamps accepted BEFORE the snapshot",
		store.stamp(sid, "accepted", "accept"))
	d.save_to_history("accept staged zone")
	check_eq("post-accept snapshot carries the accepted layer",
		str(((d.history[d.history_index] as Dictionary).get("staged", {}) as Dictionary).get(sid, "")),
		"accepted")

	# UNDO: the board loses the zone AND the entry returns to staged — one act,
	# two halves, reverted together (the bucket-8 rationale, second store).
	check("undo", d.undo())
	check_eq("the zone left the board", d.zones.size(), 0)
	check_eq("…and the entry is STAGED again (its ghost returns)",
		str(store.get_entry(sid).get("disposition", "")), "staged")
	check("redo", d.redo())
	check_eq("redo restores the board write", d.zones.size(), 1)
	check_eq("…and the accepted stamp", str(store.get_entry(sid).get("disposition", "")), "accepted")

	# THE REJECT IDIOM (cold review F3): a terminal stamp is only durable when
	# PAIRED with its own history entry — attach, stamp, save — because every
	# later snapshot carries the full disposition map. Pin that a paired reject
	# survives undo of an UNRELATED edit, and that undoing the reject itself
	# revives the ghost.
	var p2: Dictionary = d.build_cutout_payload(TRI).get("payload", {})
	var sid2 := str(store.stage("cutout", p2))
	check("attach before the reject stamp", d.attach_staged_snapshot())
	check("paired reject stamps", store.reject(sid2))
	d.save_to_history("reject staged cutout")
	d.create_cutout([Vector2(20, 20), Vector2(25, 20), Vector2(25, 25)])
	d.save_to_history("unrelated cutout")
	check("undo of the UNRELATED edit", d.undo())
	check_eq("…leaves the reject standing (no silent un-reject)",
		str(store.get_entry(sid2).get("disposition", "")), "rejected")
	check("undo of the reject entry itself", d.undo())
	check_eq("…revives the ghost (back to staged)",
		str(store.get_entry(sid2).get("disposition", "")), "staged")

	# UNDO-PAST-STAGE (cold review F6a): an entry staged AFTER a snapshot has
	# no key in it — absent-sid ⇒ untouched, the draft SURVIVES undoing board
	# work that predates it (staging is not a board mutation; accept
	# re-validates, so a stale base is safe).
	var p3: Dictionary = d.build_zone_payload("", "bottom", TRI, "keepout").get("payload", {})
	var sid3 := str(store.stage("zone", p3))
	check("undo to a snapshot that predates the stage", d.undo())
	check_eq("…leaves the newborn draft untouched (absent key ⇒ untouched)",
		str(store.get_entry(sid3).get("disposition", "")), "staged")
