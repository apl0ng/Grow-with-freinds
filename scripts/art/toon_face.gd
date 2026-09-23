class_name ToonFace
extends Node3D
## Cartoon face (art agent). Instance res://art/props/face.tscn and place it on the FRONT surface of a
## head/body (the face looks along -Z, Godot's forward). Built for a head radius of ~0.35-0.45 m at
## scale 1; scale the Face node for bigger characters. Purely local cosmetics (no networking).
##
## MOOD: nobody in this game is happy. Default mood is &"sad" (heavy drooping lids, eye bags, frown).
##   face.set_mood(&"sad" | &"tired" | &"grim" | &"neutral")   # animated, 0.25 s
##   face.set_happy(true)   # the best it gets: &"neutral". set_happy(false) -> back to default_mood
##   face.blink() / face.surprise() / face.look(Vector2)
## Blinks on its own (slow, tired blinks). There is no blush and no smile, on purpose.

## lid_y: height of the eyelid's cut edge relative to the eye centre (eye spans -0.104..0.104; lower =
## more covered). tilt: degrees, + = outer corners droop (sad), - = inner corners drop (grim scowl).
## mouth: frown angle in degrees (0 = flat line), mouth_w: half-width scale. bags: eye bag visibility.
## pupil_y: pupil gaze offset (-1 = looking down).
const MOODS := {
	&"neutral": {"lid_y": 0.05, "tilt": 3.0, "mouth": 0.0, "mouth_w": 0.8, "bags": false, "pupil_y": 0.0},
	&"sad": {"lid_y": 0.01, "tilt": 16.0, "mouth": 22.0, "mouth_w": 1.0, "bags": true, "pupil_y": -0.5},
	&"tired": {"lid_y": -0.028, "tilt": 5.0, "mouth": 4.0, "mouth_w": 0.75, "bags": true, "pupil_y": -0.7},
	&"grim": {"lid_y": 0.02, "tilt": -14.0, "mouth": 6.0, "mouth_w": 1.25, "bags": true, "pupil_y": -0.2},
}
const MOUTH_HALF := 0.035   # half length of one mouth segment

## Mood used on spawn and by set_happy(false).
@export var default_mood: StringName = &"sad"
## Random seconds between (slow) blinks.
@export var blink_interval := Vector2(2.5, 5.5)
## Deprecated (mood pass: nobody blushes). Kept so old callers do not break; it does nothing.
@export var show_blush: bool = false

var mood: StringName = &"sad"

@onready var _eyes: Array[Node3D] = [$EyeL as Node3D, $EyeR as Node3D]
@onready var _pupils: Array[Node3D] = [$EyeL/Pupil as Node3D, $EyeR/Pupil as Node3D]
@onready var _lids: Array[Node3D] = [$EyeL/Lid as Node3D, $EyeR/Lid as Node3D]
@onready var _bags: Array[Node3D] = [$EyeBagL as Node3D, $EyeBagR as Node3D]
@onready var _mouth: Array[Node3D] = [$Mouth/MouthL as Node3D, $Mouth/MouthR as Node3D]

var _next_blink: float = 1.0
var _pupil_rest: Array[Vector3] = []
var _eye_rest: Array[Vector3] = []
var _look := Vector2.ZERO
var _tween: Tween          # blink / surprise (eye scale)
var _mood_tween: Tween     # lids, mouth, pupils

func _ready() -> void:
	for p in _pupils:
		_pupil_rest.append(p.position)
	for e in _eyes:
		_eye_rest.append(e.scale)
	_next_blink = randf_range(0.5, blink_interval.y)
	set_mood(default_mood, true)

func _process(delta: float) -> void:
	_next_blink -= delta
	if _next_blink <= 0.0:
		_next_blink = randf_range(blink_interval.x, blink_interval.y)
		blink()

## Change expression. Unknown moods fall back to &"sad". instant = no animation.
func set_mood(new_mood: StringName, instant: bool = false) -> void:
	if not MOODS.has(new_mood):
		push_warning("ToonFace.set_mood: unknown mood '%s' (sad, tired, grim, neutral)" % new_mood)
		new_mood = &"sad"
	mood = new_mood
	if not is_node_ready():
		default_mood = new_mood
		return
	var m: Dictionary = MOODS[new_mood]
	if _mood_tween != null and _mood_tween.is_valid():
		_mood_tween.kill()
	_mood_tween = null if instant else create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		_prop(_lids[i], "position", Vector3(0.0, m["lid_y"], 0.0))
		_prop(_lids[i], "rotation", Vector3(0.0, 0.0, deg_to_rad(-side * float(m["tilt"]))))
		_bags[i].visible = m["bags"]
		var a := deg_to_rad(float(m["mouth"]))
		var half := MOUTH_HALF * float(m["mouth_w"])
		_prop(_mouth[i], "position", Vector3(side * half * cos(a), -half * sin(a), 0.0))
		_prop(_mouth[i], "rotation", Vector3(0.0, 0.0, deg_to_rad(90.0) - side * a))
		_prop(_mouth[i], "scale", Vector3(1.0, float(m["mouth_w"]), 1.0))
	_apply_look()

## Best it gets is neutral: set_happy(true) -> &"neutral"; set_happy(false) -> default_mood.
func set_happy(happy: bool) -> void:
	set_mood(&"neutral" if happy else default_mood)

## Slow, heavy blink (~0.35 s). Occasionally a second one.
func blink() -> void:
	if not is_inside_tree():
		return
	_restart_tween()
	var closed: Array[Vector3] = []
	for r in _eye_rest:
		closed.append(Vector3(r.x * 1.05, r.y * 0.06, r.z))
	_eye_step(closed, 0.11, Tween.TRANS_SINE)
	_tween.tween_interval(0.07)
	_eye_step(_eye_rest, 0.18, Tween.TRANS_SINE)
	if randf() < 0.15:
		_tween.tween_interval(0.12)
		_tween.tween_callback(blink)

## A tired startle: eyes widen a little and the lids lift for a moment, then sink back to the mood.
func surprise() -> void:
	if not is_inside_tree():
		return
	var back := mood
	_restart_tween()
	var wide: Array[Vector3] = []
	for r in _eye_rest:
		wide.append(r * 1.15)
	_eye_step(wide, 0.08, Tween.TRANS_QUAD)
	_eye_step(_eye_rest, 0.4, Tween.TRANS_SINE)
	set_mood(&"neutral")
	mood = back
	_tween.tween_callback(func() -> void: set_mood(back))

## Move both pupils inside the eyes, in the face's local space: dir.x +1 = the character's right (+X),
## dir.y +1 = up. Vector2.ZERO recentres (moods still add their downcast gaze).
func look(dir: Vector2) -> void:
	_look = dir.limit_length(1.0)
	_apply_look()

func _apply_look() -> void:
	if _pupil_rest.is_empty():
		return
	var down: float = MOODS.get(mood, MOODS[&"sad"])["pupil_y"]
	var d := Vector2(_look.x, clampf(_look.y + down, -1.0, 1.0))
	for i in _pupils.size():
		_pupils[i].position = _pupil_rest[i] + Vector3(d.x * 0.022, d.y * 0.022, 0.0)

func _prop(node: Node3D, prop: String, value: Variant) -> void:
	if _mood_tween == null:
		node.set(prop, value)
	else:
		_mood_tween.tween_property(node, prop, value, 0.25)

## One tween step: both eyes animate together to the given scales.
func _eye_step(scales: Array[Vector3], time: float, trans: Tween.TransitionType) -> void:
	for i in _eyes.size():
		var tweener := _tween.tween_property(_eyes[i], "scale", scales[i], time) if i == 0 \
				else _tween.parallel().tween_property(_eyes[i], "scale", scales[i], time)
		tweener.set_trans(trans).set_ease(Tween.EASE_IN_OUT)

func _restart_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
