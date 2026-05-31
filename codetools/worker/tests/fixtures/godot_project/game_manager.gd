class_name GameManager extends Node

signal score_changed(new_score: int)
signal game_over

var score: int = 0
var _player: Player
var _enemies: Array[Enemy] = []

func _ready() -> void:
	_player = $Player
	_player.died.connect(_on_player_died)
	for child in $Enemies.get_children():
		if child is Enemy:
			register_enemy(child)

func register_enemy(enemy: Enemy) -> void:
	_enemies.append(enemy)
	enemy.set_target(_player)
	enemy.defeated.connect(_on_enemy_defeated)

func _on_enemy_defeated() -> void:
	score += 10
	score_changed.emit(score)

func _on_player_died() -> void:
	game_over.emit()

# An intentional dead-code candidate (no incoming edges, not a lifecycle method)
# so the analyze:dead_code tool has something to surface in tests.
func unused_debug_helper() -> void:
	print("debug")

# A second function with the same signature shape as unused_debug_helper to give
# analyze:dry_candidates non-empty output (both: no params, void return).
func unused_log_helper() -> void:
	print("log")
