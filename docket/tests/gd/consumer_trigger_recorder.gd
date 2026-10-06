extends "res://Scripts/Services/Agents/TriggerManager.gd"
## Keep the real event consumer, recording delivery instead of starting an AI turn.
var delivered: Array[Dictionary] = []

func _fire_trigger(id: String, _context: Dictionary = {}, _chain: Dictionary = {}, _force: bool = false) -> bool:
	delivered.append({"text": get_trigger(id).initial_message})
	return true
