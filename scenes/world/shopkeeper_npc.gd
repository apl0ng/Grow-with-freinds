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
##
## M10 (events agent) - the INSPECTION walk. Pure visual and DETERMINISTIC: every peer calls walk_route() with the
## same points / speed / start offset when Events broadcasts the event, and the position is a function of the
## elapsed walk time (not of frame deltas), so peers agree up to network skew; the host is the reference for the
## sight checks. The route is walked as home -> points -> home (global floor points); he faces the direction of
## travel, carries the placeholder clipboard (`Clipboard` under the root, shown only while walking and glued to
## the right hand every frame - it stays outside the Toonify model so its primitives get no outline pass; the
## modeling agent's clipboard.glb replaces `Clipboard/Visual`), arms in a carry pose, drumming paused, no beckoning.
## API: walk_route(points, speed, start_offset_sec), return_home(), is_walking(), get_eye_position(),
## get_facing(), get_walk_progress(), get_route_length(points). Group Const.GROUP_NPCS.

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
## Walk: eye height above the feet when the head pivot is missing, yaw turn rate, bob, the carry pose.
const _EYE_HEIGHT := 1.65
const _EYE_ABOVE_NECK := 0.22
const _WALK_TURN_RATE := 9.0
const _WALK_BOB := 0.025
const _WALK_BOB_HZ := 1.9
const _CARRY_RIGHT_X_DEG := 38.0
const _CARRY_LEFT_X_DEG := 22.0
const _HOME_TWEEN_SEC := 0.9
const _ARRIVE_TURN_SEC := 0.35

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

# --- inspection walk (M10) ---
## Clipboard pose relative to the right hand (hand-local: under the palm, along the fingers).
const _CLIP_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.062, -0.07))
var _clipboard: Node3D
var _hand: Node3D
var _arm_left_rest: Vector3
## Global floor points: home, the route, home again.
var _route: PackedVector3Array = PackedVector3Array()
var _cum: PackedFloat32Array = PackedFloat32Array()
var _walk_len: float = 0.0
var _walk_speed: float = 1.6
var _walk_t: float = 0.0
var _walking: bool = false
## Local transform (relative to the anchor) he returns to; captured on the first walk.
var _home_local: Transform3D
var _has_home: bool = false
var _home_tween: Tween
var _pose_tween: Tween
# --- M12 disrupt: walk_to() posts ---
## walk_to(): stop at the route's last point and stay there (carry pose kept) instead of walking back home.
var _hold_at_end: bool = false
## True while he stands at a walk_to() post (arrived, not walking, not yet sent home).
var _at_post: bool = false
## Global point he turns to on arriving at the post (INF = keep the last leg's direction).
var _post_face: Vector3 = Vector3.INF


func _enter_tree() -> void:
	add_to_group(Const.GROUP_NPCS)


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
	if _arm_left != null:
		_arm_left_rest = _arm_left.rotation
	_clipboard = get_node_or_null(^"Clipboard") as Node3D
	_hand = get_node_or_null(^"Visual/Torso/ArmRight/Hand") as Node3D
	if _clipboard != null:
		_clipboard.visible = false
	_time = randf() * 10.0
	_blink_left = randf_range(2.0, 5.0)
	_reset_bark_timer()
	set_process(animate)
	if animate:
		_start_breathing()
		_start_drumming()


func _process(delta: float) -> void:
	_time += delta
	if _walking:
		_update_walk(delta)
	_scan_left -= delta
	if _scan_left <= 0.0:
		_scan_left = _SCAN_INTERVAL
		_target = _find_nearest_player() if look_at_players else null
		if not _walking:
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

## Curt "get over here" beckon with the right hand. Safe to call any time (ignored while he walks the floor).
func wave() -> void:
	if not is_inside_tree() or _arm_right == null or _walking:
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


# --- inspection walk (M10, events agent) -----------------------------------------------------------------

## Walks home -> `points` (global floor positions) -> home at `speed` m/s, starting `start_offset_sec` into the
## walk (late joiners). Deterministic: the position only depends on the elapsed walk time. Every peer calls this
## with the same arguments. Ignored when not in the tree or with no points.
func walk_route(points: PackedVector3Array, speed: float = 1.6, start_offset_sec: float = 0.0) -> void:
	if not is_inside_tree() or points.is_empty():
		return
	_kill(_home_tween)
	_hold_at_end = false
	_at_post = false
	_post_face = Vector3.INF
	if not _has_home:
		_home_local = transform
		_has_home = true
	var home := _home_global_position()
	_route = PackedVector3Array([home])
	_route.append_array(points)
	_route.append(home)
	_cum = PackedFloat32Array([0.0])
	var total := 0.0
	for i in range(1, _route.size()):
		total += _route[i - 1].distance_to(_route[i])
		_cum.append(total)
	_walk_len = total
	_walk_speed = maxf(speed, 0.05)
	_walk_t = maxf(start_offset_sec, 0.0)
	_walking = true
	_set_walk_pose(true)
	_update_walk(0.0)


## Stops the walk and brings him back to his spot behind the counter (a short glide when he is out on the
## floor: the route already ends at home, so this is the fallback when the time runs out mid-walk).
func return_home() -> void:
	if not _has_home:
		return
	var was_walking := _walking or _at_post
	_walking = false
	_hold_at_end = false
	_at_post = false
	_post_face = Vector3.INF
	_set_walk_pose(false)
	_kill(_home_tween)
	if not is_inside_tree():
		transform = _home_local
		return
	var far := transform.origin.distance_to(_home_local.origin) > 0.05
	if was_walking or far:
		_home_tween = create_tween()
		_home_tween.tween_property(self, ^"transform", _home_local, _HOME_TWEEN_SEC if far else _ARRIVE_TURN_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		transform = _home_local


func is_walking() -> bool:
	return _walking


## Where he sees from (global): just above the head pivot, or _EYE_HEIGHT above the feet.
func get_eye_position() -> Vector3:
	if _head != null and _head.is_inside_tree():
		return _head.global_position + Vector3.UP * _EYE_ABOVE_NECK
	return global_position + Vector3.UP * _EYE_HEIGHT


## Flat unit vector he faces (he is modelled facing -Z).
func get_facing() -> Vector3:
	var f := -global_basis.z
	f.y = 0.0
	return f.normalized() if f.length_squared() > 0.000001 else Vector3.FORWARD


## 0..1 along the current (or last) route; 0 with no route.
func get_walk_progress() -> float:
	if _walk_len <= 0.0:
		return 0.0
	return clampf(_walk_t * _walk_speed / _walk_len, 0.0, 1.0)


## Length in metres of home -> `points` -> home (what walk_route() will walk).
func get_route_length(points: PackedVector3Array) -> float:
	if points.is_empty():
		return 0.0
	var home := _home_global_position() if _has_home or is_inside_tree() else Vector3.ZERO
	var total := home.distance_to(points[0])
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total + points[points.size() - 1].distance_to(home)


# --- M12 disrupt: a post on the floor (head count) ------------------------------------------------------

## Walks home -> `points` (global floor positions) at `speed` and STAYS at the last point, clipboard in hand, until
## return_home() or another walk. Deterministic like walk_route(): `start_offset_sec` resumes a late joiner, and past
## the route's length he is placed at the post at once. `face` is a global point he turns to on arrival (INF keeps
## the direction of the last leg). Ignored when not in the tree or with no points.
func walk_to(points: PackedVector3Array, speed: float = 1.6, start_offset_sec: float = 0.0, face: Vector3 = Vector3.INF) -> void:
	if not is_inside_tree() or points.is_empty():
		return
	walk_route(points, speed, 0.0)  # home -> points -> home; the way back is trimmed off below
	if not _walking:
		return
	_route.resize(_route.size() - 1)
	_cum.resize(_cum.size() - 1)
	_walk_len = _cum[_cum.size() - 1]
	_hold_at_end = true
	_post_face = face
	_walk_t = maxf(start_offset_sec, 0.0)
	_update_walk(0.0)


## True while he stands at a walk_to() post (arrived, not walking, not yet sent home).
func is_at_post() -> bool:
	return _at_post


## Length in metres of the current (or last) walk: home -> points -> home for walk_route(), home -> post for walk_to().
func get_walk_length() -> float:
	return _walk_len


## Arrived at the post: feet still (no bob), carry pose kept, turned to the face point.
func _arrive_at_post() -> void:
	_at_post = true
	if _visual != null:
		_visual.position.y = 0.0
	if _post_face.is_finite():
		var dir := _post_face - global_position
		dir.y = 0.0
		if dir.length_squared() > 0.000001:
			global_rotation.y = atan2(-dir.x, -dir.z)
	_follow_hand()


func _home_global_position() -> Vector3:
	var local := _home_local if _has_home else transform
	var parent_3d := get_parent() as Node3D
	if parent_3d != null and parent_3d.is_inside_tree():
		return parent_3d.global_transform * local.origin
	return local.origin


func _update_walk(delta: float) -> void:
	_walk_t += delta
	var d := _walk_t * _walk_speed
	if d >= _walk_len or _route.size() < 2:
		_walking = false
		global_position = _route[_route.size() - 1] if not _route.is_empty() else global_position
		if _hold_at_end:
			_arrive_at_post()
		else:
			return_home()
		return
	var i := 0
	while i < _cum.size() - 2 and _cum[i + 1] <= d:
		i += 1
	var seg_len := _cum[i + 1] - _cum[i]
	var t := 0.0 if seg_len <= 0.000001 else (d - _cum[i]) / seg_len
	var pos := _route[i].lerp(_route[i + 1], t)
	var dir := _route[i + 1] - _route[i]
	dir.y = 0.0
	global_position = pos
	if _visual != null:
		_visual.position.y = absf(sin(_walk_t * TAU * _WALK_BOB_HZ)) * _WALK_BOB
	if dir.length_squared() > 0.000001:
		dir = dir.normalized()
		var target_yaw := atan2(-dir.x, -dir.z)
		var w := 1.0 if delta <= 0.0 else 1.0 - exp(-delta * _WALK_TURN_RATE)
		global_rotation.y = lerp_angle(global_rotation.y, target_yaw, w)
	_follow_hand()


## Glues the clipboard to the right hand (it lives outside the model subtree).
func _follow_hand() -> void:
	if _clipboard == null or _hand == null or not _clipboard.visible or not _hand.is_inside_tree():
		return
	_clipboard.global_transform = _hand.global_transform * _CLIP_OFFSET


## Carry pose (clipboard in the right hand, drumming paused) on, or back to the counter pose.
func _set_walk_pose(on: bool) -> void:
	if _clipboard != null:
		_clipboard.visible = on
		_follow_hand()
	if _visual != null and not on:
		_visual.position.y = 0.0
	_kill(_gesture_tween)
	_kill(_pose_tween)
	if _drum_tween != null and _drum_tween.is_valid():
		if on:
			_drum_tween.pause()
		else:
			_drum_tween.play()
	if not is_inside_tree():
		return
	_pose_tween = create_tween().set_parallel(true)
	if _arm_right != null:
		var right := _arm_right_rest
		if on:
			right.x = deg_to_rad(_CARRY_RIGHT_X_DEG)
		_pose_tween.tween_property(_arm_right, ^"rotation", right, 0.4).set_trans(Tween.TRANS_SINE)
		for f in _fingers:
			_pose_tween.tween_property(f, ^"rotation:x", 0.6 if on else 0.0, 0.3)
	if _arm_left != null:
		var left := _arm_left_rest
		if on:
			left.x = deg_to_rad(_CARRY_LEFT_X_DEG)
		_pose_tween.tween_property(_arm_left, ^"rotation", left, 0.4).set_trans(Tween.TRANS_SINE)


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
