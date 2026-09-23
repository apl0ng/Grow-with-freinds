class_name ShopkeeperNPC
extends Node3D
## The Boss: the shady owner behind the barred pay window. Pure visual: no collision and no networking
## (every peer animates him locally). Origin at the feet, faces -Z, ~2 m to the top of the fedora.
## Nobody is happy here: no smiles, no bounces. He breathes heavily, drums his fingers, watches you.
##
## All meshes live under `Visual` so a modelled body can replace them. Every part is looked up with
## get_node_or_null and each behaviour silently skips what is missing:
##   Visual                                    slow heavy breathing (scale)
##   Visual/Torso                              breathing bob
##   Visual/Torso/HeadPivot                    turns toward the nearest player, cold nod (cheer)
##   Visual/Torso/HeadPivot/Eye*/Lid*          heavy-lidded slow blink
##   Visual/Torso/ArmRight[/Hand/Fingers/*]    drumming fingers, "get over here" beckon (wave)
##   Visual/Torso/ArmLeft/Hand/Cash[/TopBill]  counting money (cheer)
##   BarkLabel (Label3D)                       bark() speech line
## Hooks used by the shop counter: wave(), cheer(). bark(text) shows a short flat line above him.

## Master switch for all animation.
@export var animate: bool = true
## Turn the head toward the nearest player (group Const.GROUP_PLAYERS) within look_radius.
@export var look_at_players: bool = true
@export var look_radius: float = 7.0
@export_range(0.0, 90.0, 1.0) var max_head_yaw_deg: float = 60.0
## Beckon ("get over here") when a player comes within this distance; re-arms once they walk away.
@export var wave_radius: float = 3.2
## Lines barked at random while idle. Flat and joyless.
@export var idle_lines: PackedStringArray = PackedStringArray([
	"Tick tock.", "Back to work.", "You still owe me.", "No breaks.", "Deposit more. Talk less.",
])
@export var auto_bark: bool = true
## Seconds between idle barks (random in this range).
@export var bark_interval_min: float = 20.0
@export var bark_interval_max: float = 40.0
## Default seconds a bark stays up.
@export var bark_duration: float = 2.8
## Seconds per breath.
@export_range(1.0, 8.0, 0.1) var breath_period: float = 3.4

const _SCAN_INTERVAL := 0.25
const _INHALE := Vector3(0.99, 1.028, 0.99)
const _BOB := 0.015
const _TARGET_EYE_HEIGHT := 1.6
const _HEAD_CENTER_Y := 0.28
const _MAX_PITCH_DEG := 12.0
const _LOOK_RATE := 3.0
const _LID_BLINK_DEG := -88.0
const _FINGER_TAP := 0.45
const _BECKON_RAISE_DEG := 145.0
const _BECKON_CURL := 1.15

var _visual: Node3D
var _torso: Node3D
var _head: Node3D
var _arm_right: Node3D
var _arm_left: Node3D
var _fingers: Array[Node3D] = []
var _lids: Array[Node3D] = []
var _lid_rest: Array[float] = []
var _cash: Node3D
var _top_bill: Node3D
var _bark_label: Label3D

var _arm_right_rest: Vector3
var _target: Node3D = null
var _scan_left: float = 0.0
var _time: float = 0.0
var _blink_left: float = 4.0
var _bark_left: float = 30.0
var _player_near: bool = false
## Extra head pitch added by the nod (tweened).
var _nod_offset: float = 0.0
var _look_yaw: float = 0.0
var _look_pitch: float = 0.0

var _breath_tween: Tween
var _drum_tween: Tween
var _gesture_tween: Tween
var _cash_tween: Tween
var _bark_tween: Tween
var _blink_tween: Tween


func _ready() -> void:
	_visual = get_node_or_null(^"Visual") as Node3D
	_torso = get_node_or_null(^"Visual/Torso") as Node3D
	_head = get_node_or_null(^"Visual/Torso/HeadPivot") as Node3D
	_arm_right = get_node_or_null(^"Visual/Torso/ArmRight") as Node3D
	_arm_left = get_node_or_null(^"Visual/Torso/ArmLeft") as Node3D
	var fingers := get_node_or_null(^"Visual/Torso/ArmRight/Hand/Fingers")
	if fingers != null:
		for c in fingers.get_children():
			if c is Node3D:
				_fingers.append(c)
	for side in ["Left", "Right"]:
		var lid := get_node_or_null("Visual/Torso/HeadPivot/Eye%s/Lid%s" % [side, side]) as Node3D
		if lid != null:
			_lids.append(lid)
			_lid_rest.append(lid.rotation.x)
	_cash = get_node_or_null(^"Visual/Torso/ArmLeft/Hand/Cash") as Node3D
	_top_bill = get_node_or_null(^"Visual/Torso/ArmLeft/Hand/Cash/TopBill") as Node3D
	_bark_label = get_node_or_null(^"BarkLabel") as Label3D
	if _bark_label != null:
		_bark_label.visible = false
	if _cash != null:
		_cash.visible = false
	if _arm_right != null:
		_arm_right_rest = _arm_right.rotation
	_time = randf() * 10.0
	_blink_left = randf_range(2.0, 5.0)
	_reset_bark_timer()
	set_process(animate)
	if animate:
		_start_breathing()
		_start_drumming()


func _process(delta: float) -> void:
	_time += delta
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = _SCAN_INTERVAL
		_target = _find_nearest_player() if look_at_players else null
		_update_beckon_trigger()
	_update_head(delta)
	_blink_left -= delta
	if _blink_left <= 0.0:
		_blink_left = randf_range(3.0, 6.5)
		_blink()
	if auto_bark and not idle_lines.is_empty():
		_bark_left -= delta
		if _bark_left <= 0.0:
			bark(idle_lines[randi() % idle_lines.size()])


# --- public hooks -------------------------------------------------------------------------------------

## Curt "get over here" beckon with the right hand. Safe to call any time.
func wave() -> void:
	if not is_inside_tree() or _arm_right == null:
		return
	_kill(_gesture_tween)
	if _drum_tween != null and _drum_tween.is_valid():
		_drum_tween.pause()
	var raised := _arm_right_rest
	raised.x = deg_to_rad(_BECKON_RAISE_DEG)
	_gesture_tween = create_tween()
	_gesture_tween.tween_property(_arm_right, ^"rotation", raised, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	for i in 2:
		_tween_fingers(_gesture_tween, _BECKON_CURL, 0.16)
		_tween_fingers(_gesture_tween, 0.0, 0.16)
	_gesture_tween.tween_interval(0.25)
	_gesture_tween.tween_property(_arm_right, ^"rotation", _arm_right_rest, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_gesture_tween.tween_callback(_resume_drumming)


## Cold, unimpressed nod + counting the money. No smile.
func cheer() -> void:
	if not is_inside_tree():
		return
	_kill(_gesture_tween)
	_gesture_tween = create_tween()
	_gesture_tween.tween_property(self, ^"_nod_offset", -deg_to_rad(16.0), 0.35).set_trans(Tween.TRANS_SINE)
	_gesture_tween.tween_property(self, ^"_nod_offset", 0.0, 0.5).set_trans(Tween.TRANS_SINE)
	if _cash == null:
		return
	_kill(_cash_tween)
	_cash.visible = true
	_cash.scale = Vector3.ONE * 0.6
	_cash_tween = create_tween()
	_cash_tween.tween_property(_cash, ^"scale", Vector3.ONE, 0.18)
	if _top_bill != null:
		for i in 3:
			_cash_tween.tween_property(_top_bill, ^"rotation:z", 0.9, 0.1)
			_cash_tween.tween_property(_top_bill, ^"rotation:z", 0.0, 0.12)
	_cash_tween.tween_interval(0.45)
	_cash_tween.tween_callback(func() -> void: _cash.visible = false)


## Shows a short line above the Boss for `duration` seconds (bark_duration when negative).
func bark(text: String, duration: float = -1.0) -> void:
	_reset_bark_timer()
	if _bark_label == null or text.is_empty():
		return
	_kill(_bark_tween)
	_bark_label.text = text
	_bark_label.visible = true
	_bark_label.modulate.a = 0.0
	_bark_label.outline_modulate.a = 0.0
	var hold := bark_duration if duration < 0.0 else duration
	if not is_inside_tree():
		_bark_label.modulate.a = 1.0
		_bark_label.outline_modulate.a = 1.0
		return
	_bark_tween = create_tween()
	_bark_tween.tween_property(_bark_label, ^"modulate:a", 1.0, 0.15)
	_bark_tween.parallel().tween_property(_bark_label, ^"outline_modulate:a", 1.0, 0.15)
	_bark_tween.tween_interval(maxf(hold, 0.1))
	_bark_tween.tween_property(_bark_label, ^"modulate:a", 0.0, 0.4)
	_bark_tween.parallel().tween_property(_bark_label, ^"outline_modulate:a", 0.0, 0.4)
	_bark_tween.tween_callback(func() -> void: _bark_label.visible = false)


## The line currently shown above the Boss, or "" when he is quiet.
func get_current_bark() -> String:
	if _bark_label == null or not _bark_label.visible:
		return ""
	return _bark_label.text


# --- idle loops ---------------------------------------------------------------------------------------

func _start_breathing() -> void:
	if _visual == null:
		return
	_kill(_breath_tween)
	var half := maxf(breath_period, 1.0) * 0.5
	_breath_tween = create_tween().set_loops()
	_breath_tween.tween_property(_visual, ^"scale", _INHALE, half).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _torso != null:
		_breath_tween.parallel().tween_property(_torso, ^"position:y", _BOB, half).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath_tween.tween_property(_visual, ^"scale", Vector3.ONE, half).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _torso != null:
		_breath_tween.parallel().tween_property(_torso, ^"position:y", 0.0, half).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Impatient finger drumming on the counter: pinky to index, then a pause.
func _start_drumming() -> void:
	if _fingers.is_empty():
		return
	_kill(_drum_tween)
	_drum_tween = create_tween().set_loops()
	for i in range(_fingers.size() - 1, -1, -1):
		var f := _fingers[i]
		_drum_tween.tween_property(f, ^"rotation:x", _FINGER_TAP, 0.07).set_trans(Tween.TRANS_QUAD)
		_drum_tween.tween_property(f, ^"rotation:x", 0.0, 0.06)
	_drum_tween.tween_interval(0.9)


func _resume_drumming() -> void:
	if _drum_tween != null and _drum_tween.is_valid():
		_drum_tween.play()
	else:
		_start_drumming()


func _blink() -> void:
	if _lids.is_empty():
		return
	_kill(_blink_tween)
	_blink_tween = create_tween().set_parallel(true)
	for lid in _lids:
		_blink_tween.tween_property(lid, ^"rotation:x", deg_to_rad(_LID_BLINK_DEG), 0.12)
	_blink_tween.chain().tween_interval(0.08)
	for i in _lids.size():
		var back := _blink_tween.chain() if i == 0 else _blink_tween
		back.tween_property(_lids[i], ^"rotation:x", _lid_rest[i], 0.22)


func _reset_bark_timer() -> void:
	_bark_left = randf_range(bark_interval_min, maxf(bark_interval_max, bark_interval_min))


# --- looking at players ---------------------------------------------------------------------------------

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


func _update_beckon_trigger() -> void:
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
	if _head == null:
		return
	var yaw := sin(_time * 0.3) * deg_to_rad(8.0)
	var pitch := 0.0
	if _has_target() and _torso != null:
		var rel := _torso.to_local(_target.global_position) - _head.position
		var flat := Vector2(rel.x, rel.z).length()
		if flat > 0.1:
			var max_yaw := deg_to_rad(max_head_yaw_deg)
			yaw = clampf(atan2(-rel.x, -rel.z), -max_yaw, max_yaw)
			var max_pitch := deg_to_rad(_MAX_PITCH_DEG)
			pitch = clampf(atan2(rel.y + _TARGET_EYE_HEIGHT - _HEAD_CENTER_Y, flat), -max_pitch, max_pitch)
	var w := 1.0 - exp(-delta * _LOOK_RATE)
	_look_yaw = lerp_angle(_look_yaw, yaw, w)
	_look_pitch = lerp_angle(_look_pitch, pitch, w)
	_head.rotation.y = _look_yaw
	_head.rotation.x = _look_pitch + _nod_offset


## Appends one step that moves every finger to `value` together (a plain wait when there are no fingers).
func _tween_fingers(tw: Tween, value: float, duration: float) -> void:
	if _fingers.is_empty():
		tw.tween_interval(duration)
		return
	for j in _fingers.size():
		if j == 0:
			tw.tween_property(_fingers[j], ^"rotation:x", value, duration)
		else:
			tw.parallel().tween_property(_fingers[j], ^"rotation:x", value, duration)


func _kill(t: Tween) -> void:
	if t != null and t.is_valid():
		t.kill()
