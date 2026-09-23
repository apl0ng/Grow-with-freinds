class_name ShopkeeperNPC
extends Node3D
## Bubbly shopkeeper. Pure visual: no collision, no networking (every peer animates it locally).
## Origin at the feet, faces -Z (Godot forward), ~1.9 m tall to the top of the hat.
## Meant to stand behind the shop counter: instance it there and rotate it so -Z faces the customers.
##
## Idle: looping breathe bob + squash-and-stretch (Tween), random blinks, the head turns toward the nearest
## player (group Const.GROUP_PLAYERS; null-safe when there are none) and a little wave when someone walks up.
## Optional hooks for the shop: wave(), cheer().

## Master switch for all animation (the pose stays as authored when false).
@export var animate: bool = true
## Seconds for one full breathe (stretch + squash) cycle.
@export_range(0.5, 5.0, 0.1) var idle_period: float = 1.8
## Turn the head toward the nearest player within look_radius.
@export var look_at_players: bool = true
@export var look_radius: float = 7.0
@export_range(0.0, 90.0, 1.0) var max_head_yaw_deg: float = 70.0
## Wave "hello" when a player comes within this distance (re-arms once they walk away again).
@export var wave_radius: float = 3.2

const _SCAN_INTERVAL := 0.25          # seconds between nearest-player scans
const _STRETCH := Vector3(0.975, 1.035, 0.975)
const _SQUASH := Vector3(1.03, 0.965, 1.03)
const _BOB_HEIGHT := 0.035
const _ARM_REST_DEG := 30.0           # authored rotation.z of ArmRight in the scene
const _ARM_WAVE_DEG := 145.0
const _HEAD_CENTER_Y := 0.26          # head centre above the HeadPivot (neck)
const _TARGET_EYE_HEIGHT := 1.6       # look at this height above the target's origin (feet)
const _MAX_PITCH_DEG := 15.0
const _IDLE_GLANCE_DEG := 14.0

@onready var _visual: Node3D = $Visual
@onready var _torso: Node3D = $Visual/Torso
@onready var _head: Node3D = $Visual/Torso/HeadPivot
@onready var _arm_right: Node3D = $Visual/Torso/ArmRight
@onready var _eye_left: Node3D = $Visual/Torso/HeadPivot/EyeLeft
@onready var _eye_right: Node3D = $Visual/Torso/HeadPivot/EyeRight

var _target: Node3D = null
var _scan_left: float = 0.0
var _time: float = 0.0
var _blink_left: float = 3.0
var _player_near: bool = false
var _eye_scale: Vector3 = Vector3.ONE
var _idle_tween: Tween
var _wave_tween: Tween
var _blink_tween: Tween
var _cheer_tween: Tween


func _ready() -> void:
	_eye_scale = _eye_left.scale
	_time = randf() * 10.0
	_blink_left = randf_range(1.5, 4.0)
	set_process(animate)
	if animate:
		_start_idle()


func _process(delta: float) -> void:
	_time += delta
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = _SCAN_INTERVAL
		_target = _find_nearest_player() if look_at_players else null
		_update_wave_trigger()
	_update_head(delta)
	_blink_left -= delta
	if _blink_left <= 0.0:
		_blink_left = randf_range(2.2, 5.0)
		_blink()


## Quick "hello" wave with the right arm. Safe to call any time (e.g. when the shop UI opens).
func wave() -> void:
	if not is_inside_tree():
		return
	if _wave_tween != null and _wave_tween.is_valid():
		_wave_tween.kill()
	var up := deg_to_rad(_ARM_WAVE_DEG)
	_wave_tween = create_tween()
	_wave_tween.tween_property(_arm_right, ^"rotation:z", up, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for i in 2:
		_wave_tween.tween_property(_arm_right, ^"rotation:z", up - 0.45, 0.14) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_wave_tween.tween_property(_arm_right, ^"rotation:z", up, 0.14) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_wave_tween.tween_property(_arm_right, ^"rotation:z", deg_to_rad(_ARM_REST_DEG), 0.3) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


## Happy little hop + wave (e.g. after a purchase).
func cheer() -> void:
	if not is_inside_tree():
		return
	if _cheer_tween != null and _cheer_tween.is_valid():
		_cheer_tween.kill()
	_visual.position.y = 0.0
	_cheer_tween = create_tween()
	_cheer_tween.tween_property(_visual, ^"position:y", 0.18, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_cheer_tween.tween_property(_visual, ^"position:y", 0.0, 0.2).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	wave()


# --- internals ------------------------------------------------------------------------------------

func _start_idle() -> void:
	if _idle_tween != null and _idle_tween.is_valid():
		_idle_tween.kill()
	var half := maxf(idle_period, 0.2) * 0.5
	_idle_tween = create_tween().set_loops()
	_idle_tween.tween_property(_visual, ^"scale", _STRETCH, half) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tween.parallel().tween_property(_torso, ^"position:y", _BOB_HEIGHT, half) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tween.tween_property(_visual, ^"scale", _SQUASH, half) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tween.parallel().tween_property(_torso, ^"position:y", 0.0, half) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _find_nearest_player() -> Node3D:
	if not is_inside_tree():
		return null
	var best: Node3D = null
	var best_d2 := look_radius * look_radius
	for n in get_tree().get_nodes_in_group(Const.GROUP_PLAYERS):
		var p := n as Node3D
		if p == null or not p.is_inside_tree():
			continue
		var d2 := global_position.distance_squared_to(p.global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = p
	return best


func _has_target() -> bool:
	return _target != null and is_instance_valid(_target) and _target.is_inside_tree()


func _update_wave_trigger() -> void:
	var d := INF
	if _has_target():
		var off := _target.global_position - global_position
		d = Vector2(off.x, off.z).length()
	if not _player_near and d <= wave_radius:
		_player_near = true
		wave()
	elif _player_near and d > wave_radius + 1.5:
		_player_near = false


func _update_head(delta: float) -> void:
	var yaw := sin(_time * 0.5) * deg_to_rad(_IDLE_GLANCE_DEG)
	var pitch := 0.0
	if _has_target():
		# Target relative to the neck, in the torso's (unrotated) space.
		var rel := _torso.to_local(_target.global_position) - _head.position
		var flat := Vector2(rel.x, rel.z).length()
		if flat > 0.1:
			var max_yaw := deg_to_rad(max_head_yaw_deg)
			yaw = clampf(atan2(-rel.x, -rel.z), -max_yaw, max_yaw)
			var dy := rel.y + _TARGET_EYE_HEIGHT - _HEAD_CENTER_Y
			var max_pitch := deg_to_rad(_MAX_PITCH_DEG)
			pitch = clampf(atan2(dy, flat), -max_pitch, max_pitch)
	var w := 1.0 - exp(-delta * 5.0)
	_head.rotation.y = lerp_angle(_head.rotation.y, yaw, w)
	_head.rotation.x = lerp_angle(_head.rotation.x, pitch, w)


func _blink() -> void:
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	var shut := Vector3(_eye_scale.x, _eye_scale.y * 0.1, _eye_scale.z)
	_blink_tween = create_tween().set_parallel(true)
	_blink_tween.tween_property(_eye_left, ^"scale", shut, 0.06)
	_blink_tween.tween_property(_eye_right, ^"scale", shut, 0.06)
	_blink_tween.chain().tween_property(_eye_left, ^"scale", _eye_scale, 0.09)
	_blink_tween.tween_property(_eye_right, ^"scale", _eye_scale, 0.09)
