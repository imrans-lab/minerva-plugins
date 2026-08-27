extends RefCounted
## PcbEntityId — THE identity policy for board entities (trace, via, zone,
## cutout, hole, placement, group). One file, so every mint site and every
## "is this a real id?" test reads the same rule, and the next surfaces that
## need it (propose_via listing under a route hint, graphics delete-by-id, the
## routing sidecar's ownership records) reuse it instead of re-deriving it.
##
## ── THE POLICY ────────────────────────────────────────────────────────────────
## An entity id is a MINTED OPAQUE TOKEN: "<entity_type>:<32 lowercase hex>",
## 128 bits from Godot's CSPRNG. It is minted ONCE, written into the board YAML,
## and never recomputed. Ids are unique WITHIN an entity domain, so
## "trace:<hex>" and "via:<hex>" sharing a tail are two distinct ids.
##
## ── MINTED, NOT CONTENT-HASHED (the decision, and why) ────────────────────────
## The alternative considered was a content hash over net + geometry. Rejected:
##   * it is stable only while the copper does not move, and moving copper is
##     the commonest edit there is — every drag would silently retire the id an
##     agent, an annotation, or a route candidate's ownership record is holding;
##   * it COLLIDES BY CONSTRUCTION — two identical vias on one net are two
##     entities with one hash, so neither is individually addressable;
##   * it cannot be the identity the routing sidecar records ownership against,
##     because the sidecar outlives the geometry it was written for.
## A minted token survives moves, edits, reorders and reloads, and 128 bits makes
## a collision across independently authored boards negligible — which is what
## lets a persistent id subsume board-namespacing.
##
## ── THE SHAPE IS NOT OURS TO CHOOSE ───────────────────────────────────────────
## internal/board/migrate.go's isMintedID() DEFINES it, internal/board/validate.go
## enforces it on every v2 board, and pcb.deserialize RE-MINTS any id that does
## not match it (MigrateV1toV2 runs on every v1 board load). That re-mint is
## exactly how the ordinal handles used to evaporate: a via minted "via_7" in the
## panel came back from load_board as "via:<fresh hex>", so an agent holding
## "via_7" got `missing_via_ids`, and the routing sidecar's committed_via_ids
## went dangling on every reload. Minting the Go shape UI-side is what makes an
## id round-trip export_yaml → load_board unchanged.
##
## ── ORDINAL IDS ARE LEGACY: ACCEPTED, NEVER MINTED ────────────────────────────
## "via_7" / "trace_3" still load, still delete, still round-trip through the
## panel (PCBData honours a supplied id and high-waters its counter off
## ordinal_suffix). Nothing MINTS one any more, so nothing new can be minted onto
## an id somebody else is holding.
##
## Off-tree plugin: NO class_name; reached by relative preload.

## Entropy width of a minted id: 16 bytes → 32 hex chars. MIRRORS
## internal/board/migrate.go's mintedIDBytes; isMintedID() checks EXACTLY this
## width, so the two must not drift.
const MINTED_ID_BYTES := 16


## Mint a fresh persistent id for `entity_type` ("trace", "via", "zone", …).
##
## Entropy comes from Crypto (Godot's CSPRNG), not randi(), matching Go's
## crypto/rand for the same reason it does: a mint is a one-time write and the
## id must stay globally unique across independently edited boards.
static func mint(entity_type: String) -> String:
	# hex_encode() emits LOWERCASE hex, which is_minted/isMintedID require.
	return "%s:%s" % [entity_type,
		Crypto.new().generate_random_bytes(MINTED_ID_BYTES).hex_encode()]


## True iff `id` is exactly "<entity_type>:<32 lowercase hex>" — the GDScript
## twin of Go's isMintedID(). Anything else (empty, ordinal, uppercase hex, a
## short tail, a foreign shape) is UNMINTED, and an unminted id on a v2 board is
## re-minted by the deserialize migration.
static func is_minted(entity_type: String, id: String) -> bool:
	var prefix := entity_type + ":"
	if id.length() != prefix.length() + 2 * MINTED_ID_BYTES:
		return false
	if not id.begins_with(prefix):
		return false
	for i in range(prefix.length(), id.length()):
		var c := id.unicode_at(i)
		var digit := c >= 48 and c <= 57          # 0-9
		var lower_hex := c >= 97 and c <= 102     # a-f
		if not (digit or lower_hex):
			return false
	return true


## Trailing integer of a LEGACY ordinal id ("via_12" → 12, "trace_7" → 7); 0 for
## anything else — a minted id included, since it carries no "_". Feeds PCBData's
## id-counter high-water so a supplied ordinal can never be reproduced later.
static func ordinal_suffix(id: String) -> int:
	var idx := id.rfind("_")
	if idx < 0 or idx + 1 >= id.length():
		return 0
	var tail := id.substr(idx + 1)
	return int(tail) if tail.is_valid_int() else 0
