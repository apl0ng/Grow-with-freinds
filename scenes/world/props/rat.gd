class_name Rat
extends Node3D
## The rat (M10 stretch, events agent): thin and sad. Pure visual, no collision, no networking: Events adds one as
## a plain child of the Room on every peer when the RAT event starts (params {"plot", "from"}) and drives it with
## run_to() / flee(); the HOST drains the plot while is_eating(). Origin at the feet, faces -Z (nose forward).
## Meshes live under `Visual` so the modeling agent's rat.glb can replace it (placeholder: a dark capsule body,
## a bead head, a wire tail). Group Const.GROUP_NPCS.

@export var run_speed: float = 2.6
@export var flee_speed: float = 3.4
## Seconds after reaching the wall gap on a flee before the node frees itself.
@export var vanish_delay: float = 0.4

const _TURN_RATE := 12.0
const _ARRIVE := 0.05
const _NIBBLE_HZ := 5.0

var _target: Vector3
var _has_target: bool = false
var _from: Vector3
var _has_from: bool = false
var _eating: bool = false
var _fleeing: bool = false
var _t: float = 0.0
var _visual: Node3D


func _enter_tree() -> void:
	add_to_group(Const.GROUP_NPCS)


func _ready() -> void:
	_visual = get_node_or_null(^"Visual") as Node3D


func _process(delta: float) -> void:
	_t += delta
	if _has_target:
		var to := _target - global_position
		to.y = 0.0
		var dist := to.length()
		var speed := flee_speed if _fleeing else run_speed
		if dist <= maxf(_ARRIVE, speed * delta):
			global_position = Vector3(_target.x, global_position.y, _target.z)
			_has_target = false
			if _fleeing:
				_fleeing = false
				get_tree().create_timer(vanish_delay).timeout.connect(queue_free)
				visible = false
			else:
				_eating = true
		else:
			var dir := to / dist
			global_position += dir * speed * delta
			var target_yaw := atan2(-dir.x, -dir.z)
			global_rotation.y = lerp_angle(global_rotation.y, target_yaw, 1.0 - exp(-delta * _TURN_RATE))
	if _visual != null:
		if _eating:
			_visual.scale = Vector3(1.0, 1.0 + 0.08 * absf(sin(_t * TAU * _NIBBLE_HZ)), 1.0 - 0.04 * absf(sin(_t * TAU * _NIBBLE_HZ)))
		elif _has_target:
			_visual.scale = Vector3(1.0, 1.0 + 0.05 * absf(sin(_t * TAU * 7.0)), 1.0)
		else:
			_visual.scale = Vector3.ONE


# --- API (Events, every peer) -------------------------------------------------------------------------------------

## Runs to `point` (global, floor) and starts eating there. The first call also records where he came from.
func run_to(point: Vector3) -> void:
	if not _has_from:
		_from = global_position
		_has_from = true
	_target = point
	_has_target = true
	_eating = false
	_fleeing = false


## Runs back to where he came from and frees himself there (a rat with nowhere to go just vanishes).
func flee() -> void:
	_eating = false
	if not _has_from:
		queue_free()
		return
	_fleeing = true
	_target = _from
	_has_target = true


func is_eating() -> bool:
	return _eating


func is_fleeing() -> bool:
	return _fleeing


func is_running() -> bool:
	return _has_target
