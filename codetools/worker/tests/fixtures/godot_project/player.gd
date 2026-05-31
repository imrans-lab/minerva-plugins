class_name Player extends CharacterBody2D

signal health_changed(new_health: int)
signal died

@export var max_health: int = 100
@export var move_speed: float = 200.0

var current_health: int

func _ready() -> void:
	current_health = max_health

func _physics_process(delta: float) -> void:
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * move_speed
	move_and_slide()

func take_damage(amount: int) -> void:
	current_health = max(0, current_health - amount)
	health_changed.emit(current_health)
	if current_health == 0:
		died.emit()

func heal(amount: int) -> void:
	current_health = min(max_health, current_health + amount)
	health_changed.emit(current_health)

func is_alive() -> bool:
	return current_health > 0
