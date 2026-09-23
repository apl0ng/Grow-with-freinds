class_name ToonFace
extends Node3D
## Googly cartoon eyes + blush that blink on their own (art agent). Instance res://art/props/face.tscn and
## place it on the FRONT surface of a head/body (the face looks along -Z, Godot's forward).
## Built for a head radius of ~0.35-0.45 m at scale 1; scale the Face node for bigger characters.
## Purely local cosmetics (no networking). Optional calls: blink(), surprise(), look(Vector2), set_happy(bool).

## Random seconds between blinks.
@export var blink_interval := Vector2(2.2, 5.0)
@export var show_blush: bool = true:
	set(v):
		show_blush = v
		_update_blush()

@onready var _eyes: Array[Node3D] = [$EyeL as Node3D, $EyeR as Node3D]
@onready var _pupils: Array[Node3D] = [$EyeL/Pupil as Node3D, $EyeR/Pupil as Node3D]

var _next_blink: float = 1.0
var _pupil_rest: Array[Vector3] = []
var _eye_rest: Array[Vector3] = []
var _tween: Tween
var _happy: bool = false

func _ready() -> void:
	for p in _pupils:
		_pupil_rest.append(p.position)
	for e in _eyes:
		_eye_rest.append(e.scale)
	_next_blink = randf_range(0.5, blink_interval.y)
	_update_blush()

func _process(delta: float) -> void:
	_next_blink -= delta
	if _next_blink <= 0.0:
		_next_blink = randf_range(blink_interval.x, blink_interval.y)
		blink()

## Quick close/open (0.14 s). Double-blinks now and then.
func blink() -> void:
	if not is_inside_tree() or _happy:
		return
	_restart_tween()
	var closed: Array[Vector3] = []
	for r in _eye_rest:
		closed.append(Vector3(r.x * 1.1, r.y * 0.08, r.z))
	_eye_step(closed, 0.06, Tween.TRANS_LINEAR)
	_eye_step(_eye_rest, 0.08, Tween.TRANS_BACK)
	if randf() < 0.2:
		_tween.tween_interval(0.08)
		_tween.tween_callback(blink)

## Eyes pop wide for a moment (sale, round win, getting bumped).
func surprise() -> void:
	if not is_inside_tree():
		return
	_restart_tween()
	var wide: Array[Vector3] = []
	for r in _eye_rest:
		wide.append(r * 1.35)
	_eye_step(wide, 0.08, Tween.TRANS_QUAD)
	_eye_step(_eye_rest, 0.35, Tween.TRANS_ELASTIC)

## Move both pupils inside the eyes, in the face's local space: dir.x +1 = the character's right (+X),
## dir.y +1 = up. Vector2.ZERO recentres.
func look(dir: Vector2) -> void:
	var d := dir.limit_length(1.0)
	for i in _pupils.size():
		_pupils[i].position = _pupil_rest[i] + Vector3(d.x * 0.025, d.y * 0.025, 0.0)

## Happy "^ ^" squint (round win). Pass false to open the eyes again.
func set_happy(happy: bool) -> void:
	_happy = happy
	_restart_tween()
	var target: Array[Vector3] = []
	for r in _eye_rest:
		target.append(Vector3(r.x * 1.1, r.y * 0.35, r.z) if happy else r)
	_eye_step(target, 0.12, Tween.TRANS_BACK)

## One tween step: both eyes animate together to the given scales.
func _eye_step(scales: Array[Vector3], time: float, trans: Tween.TransitionType) -> void:
	for i in _eyes.size():
		var tweener := _tween.tween_property(_eyes[i], "scale", scales[i], time) if i == 0 \
				else _tween.parallel().tween_property(_eyes[i], "scale", scales[i], time)
		tweener.set_trans(trans).set_ease(Tween.EASE_OUT)

func _restart_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()

func _update_blush() -> void:
	for n in [get_node_or_null(^"BlushL"), get_node_or_null(^"BlushR")]:
		if n is Node3D:
			(n as Node3D).visible = show_blush
