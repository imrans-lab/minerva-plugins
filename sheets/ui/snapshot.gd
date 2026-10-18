extends RefCounted
## Snapshot acceptance follows the domain's real load/save contract.
const Roundtrip := preload("snapshot_roundtrip.gd")

static func validate(model: Dictionary) -> bool:
	return Roundtrip.validate(model)
