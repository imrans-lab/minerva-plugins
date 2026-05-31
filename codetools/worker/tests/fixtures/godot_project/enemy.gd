class_name Enemy extends CharacterBody2D

signal defeated

@export var damage: int = 10
@export var attack_cooldown: float = 1.0

var _cooldown_timer: float = 0.0
var _target: Player

func _ready() -> void:
	pass

func _physics_process(delta: float) -> void:
	_cooldown_timer = max(0.0, _cooldown_timer - delta)
	if _target != null and _cooldown_timer == 0.0:
		_attack(_target)
		_cooldown_timer = attack_cooldown

func set_target(target: Player) -> void:
	_target = target

func _attack(target: Player) -> void:
	target.take_damage(damage)

func die() -> void:
	defeated.emit()
	queue_free()
