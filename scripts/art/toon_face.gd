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
##   face.set_talk_source(Callable) / face.stop_talking()   # M25 mouth: the mouth moves with a voice level, see below
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
const MOUTH_HALF := 0.037   # half length of one mouth segment (CapsuleMesh height 0.075 in face.tscn)

## Mood used on spawn and by set_happy(false).
@export var default_mood: StringName = &"sad"
## Random seconds between (slow) blinks.
@export var blink_interval := Vector2(2.5, 5.5)
## Deprecated (mood pass: nobody blushes). Kept so old callers do not break; it does nothing.
@export var show_blush: bool = false

var mood: StringName = &"sad"

# Parts are looked up BY NAME anywhere below this node (e.g. under a Blender-imported "Visual" child),
# so the script also drives modelled faces. Any part may be missing: every use is null-safe.
# Names: EyeL, EyeR (blink pivots), Pupil + Lid (below each eye), EyeBagL, EyeBagR, MouthL, MouthR.
var _eyes: Array[Node3D] = []
var _pupils: Array[Node3D] = []
var _lids: Array[Node3D] = []
var _bags: Array[Node3D] = []
var _mouth: Array[Node3D] = []

var _next_blink: float = 1.0
var _pupil_rest: Array[Vector3] = []
var _eye_rest: Array[Vector3] = []
var _look := Vector2.ZERO
var _tween: Tween          # blink / surprise (eye scale)
var _mood_tween: Tween     # lids, mouth, pupils
var _mood_steps: int = 0

func _ready() -> void:
	refresh_parts()
	_next_blink = randf_range(0.5, blink_interval.y)
	set_mood(default_mood, true)

## Re-finds the face parts (call after swapping the model under this node). Null-safe.
func refresh_parts() -> void:
	_eyes = [_part(self, "EyeL"), _part(self, "EyeR")]
	_pupils = [_part(_eyes[0], "Pupil"), _part(_eyes[1], "Pupil")]
	_lids = [_part(_eyes[0], "Lid"), _part(_eyes[1], "Lid")]
	_bags = [_part(self, "EyeBagL"), _part(self, "EyeBagR")]
	_mouth = [_part(self, "MouthL"), _part(self, "MouthR")]
	_talk_find_parts() # M25 mouth
	_pupil_rest.clear()
	_eye_rest.clear()
	for p in _pupils:
		_pupil_rest.append(p.position if p else Vector3.ZERO)
	for e in _eyes:
		_eye_rest.append(e.scale if e else Vector3.ONE)

func _part(root: Node, part_name: String) -> Node3D:
	if root == null:
		return null
	return root.find_child(part_name, true, false) as Node3D

func _process(delta: float) -> void:
	_next_blink -= delta
	if _next_blink <= 0.0:
		_next_blink = randf_range(blink_interval.x, blink_interval.y)
		blink()
	if _talk_active:
		_talk_process(delta) # M25 mouth: only while a voice is heard or the mouth is still closing

## Change expression. Unknown moods fall back to &"sad". instant = no animation.
func set_mood(new_mood: StringName, instant: bool = false) -> void:
	if not MOODS.has(new_mood):
		push_warning("ToonFace.set_mood: unknown mood '%s' (sad, tired, grim, neutral)" % new_mood)
		new_mood = &"sad"
	mood = new_mood
	if not is_node_ready():
		default_mood = new_mood
		return
	_pose(new_mood, instant)

## Shows a mood's pose without changing the requested `mood` (surprise() uses this).
func _pose(pose_mood: StringName, instant: bool = false) -> void:
	var m: Dictionary = MOODS[pose_mood]
	if _mood_tween != null and _mood_tween.is_valid():
		_mood_tween.kill()
	_mood_tween = null if instant else create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_mood_steps = 0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		_prop(_lids[i], "position", Vector3(0.0, m["lid_y"], 0.0))
		_prop(_lids[i], "rotation", Vector3(0.0, 0.0, deg_to_rad(-side * float(m["tilt"]))))
		if _bags[i]:
			_bags[i].visible = m["bags"]
		var a := deg_to_rad(float(m["mouth"]))
		var half := MOUTH_HALF * float(m["mouth_w"])
		_prop(_mouth[i], "position", Vector3(side * half * cos(a), -half * sin(a), 0.0))
		_prop(_mouth[i], "rotation", Vector3(0.0, 0.0, deg_to_rad(90.0) - side * a))
		_prop(_mouth[i], "scale", Vector3(1.0, float(m["mouth_w"]), 1.0))
	if _mood_tween != null and _mood_steps == 0:
		_mood_tween.kill()   # nothing to animate (partial face): an empty Tween would error
		_mood_tween = null
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
	_restart_tween()
	var wide: Array[Vector3] = []
	for r in _eye_rest:
		wide.append(r * 1.15)
	_eye_step(wide, 0.08, Tween.TRANS_QUAD)
	_eye_step(_eye_rest, 0.4, Tween.TRANS_SINE)
	_pose(&"neutral")
	# Back to whatever mood is requested by then (a set_mood() during the startle wins).
	_tween.tween_callback(func() -> void: _pose(mood))

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
		if _pupils[i]:
			_pupils[i].position = _pupil_rest[i] + Vector3(d.x * 0.022, d.y * 0.022, 0.0)

func _prop(node: Node3D, prop: String, value: Variant) -> void:
	if node == null:
		return
	if _mood_tween == null:
		node.set(prop, value)
	else:
		_mood_tween.tween_property(node, prop, value, 0.25)
		_mood_steps += 1

## One tween step: both eyes animate together to the given scales.
func _eye_step(scales: Array[Vector3], time: float, trans: Tween.TransitionType) -> void:
	var first := true
	for i in _eyes.size():
		if _eyes[i] == null:
			continue
		var tweener := _tween.tween_property(_eyes[i], "scale", scales[i], time) if first \
				else _tween.parallel().tween_property(_eyes[i], "scale", scales[i], time)
		tweener.set_trans(trans).set_ease(Tween.EASE_IN_OUT)
		first = false
	if first:
		_tween.tween_interval(time)   # no eyes found: keep the tween valid (a Tween with no steps errors)

func _restart_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()

# --- M25 mouth ---
# The mouth moves with a voice (CONTRACTS "M25", "Mouth"). set_talk_source(source) hands the face a level source: a
# Callable returning 0..1 (Player's "M25 mouth" passes Voice.get_level bound to a remote worker's peer while Voice hears
# them). While a source is set, and after stop_talking() until the mouth is shut again, _process moves the drawn opening
# towards the level (at most TALK_SPEED per second: shut to open in about 0.07 s; the voice envelope already carries the
# release) and draws it:
#   the parting  the two frown segments slide apart, TALK_PART each at a full opening. They move through their pivots
#                MouthPartL / MouthPartR (face.tscn: Mouth/MouthPartL/MouthL), so the mood tween (MouthL / MouthR) and
#                the talk never write the same node: moods, blinks and surprise pose as before, talking or not
#   the opening  MouthOpen (face.tscn, under Mouth; the ink of the pupils and the segments) hangs from the frown's apex
#                (the segments' inner ends meet at Mouth's origin in every mood): wider than tall, its height and width
#                grow with the level, hidden while shut. The corners keep the mood's droop: never a smile
# A face with no source costs one bool test a frame; a talking face reads the source, writes three transforms and
# allocates nothing. Faces without the pivots or the opening (a Blender-modelled face) skip them: null-safe.

## Opening units per second the drawn mouth moves (both ways).
const TALK_SPEED: float = 14.0
## How far each frown segment slides out at a full opening (m, Mouth space).
const TALK_PART: float = 0.012
## The opening at a full level: half width beyond the parting, half height, half depth (m); at a sliver it is
## TALK_OPEN_W_MIN wide and nearly flat.
const TALK_OPEN_W: float = 0.018
const TALK_OPEN_W_MIN: float = 0.006
const TALK_OPEN_H: float = 0.022
const TALK_OPEN_D: float = 0.010
## Its top sits this far above the apex (inside the segments' round inner ends). Its centre sits at this z in Mouth
## space (-Z is the front: a little ahead of the segments' centre line, clear of the head, which comes up close behind
## the segments; same ink, so the overlap does not show).
const TALK_OPEN_TOP: float = 0.002
const TALK_OPEN_Z: float = -0.006
## Below this opening the mouth counts as shut (the opening is hidden, the segments are home).
const TALK_SHUT: float = 0.001

var _talk_source: Callable = Callable()
var _talk_active: bool = false          # _process draws the mouth (a source is set or the mouth is still closing)
var _talk_open: float = 0.0             # drawn opening 0..1
var _talk_updates: int = 0              # _talk_process calls (tests: a silent face never runs it)
var _talk_parts: Array[Node3D] = [null, null]
var _talk_hole: Node3D = null


## Starts the mouth following `source` (a Callable returning a level 0..1). An invalid Callable is stop_talking().
func set_talk_source(source: Callable) -> void:
	if not source.is_valid():
		stop_talking()
		return
	_talk_source = source
	_talk_active = true


## The voice stopped: the mouth closes at TALK_SPEED, then the face stops drawing it.
func stop_talking() -> void:
	_talk_source = Callable()


## The opening drawn now (0 shut .. 1 a full level).
func get_talk_opening() -> float:
	return _talk_open


## True while the face draws its mouth every frame (a voice is heard, or the mouth is still closing).
func is_talking() -> bool:
	return _talk_active


## How many frames this face has drawn its mouth (tests: a silent worker's stays 0).
func get_talk_updates() -> int:
	return _talk_updates


## Draws a fixed opening now, with no source (capture tools). Talking faces overwrite it on their next frame.
func pose_talk(opening: float) -> void:
	_talk_open = clampf(opening, 0.0, 1.0)
	_talk_draw()


## From refresh_parts (one line): the pivots and the opening, found by name like every part.
func _talk_find_parts() -> void:
	_talk_parts = [_part(self, "MouthPartL"), _part(self, "MouthPartR")]
	_talk_hole = _part(self, "MouthOpen")
	_talk_draw()


## From _process (one line) while _talk_active.
func _talk_process(delta: float) -> void:
	_talk_updates += 1
	var want := 0.0
	if _talk_source.is_valid():
		var v: Variant = _talk_source.call()
		if v is float or v is int:
			want = clampf(float(v), 0.0, 1.0)
	_talk_open = move_toward(_talk_open, want, TALK_SPEED * delta)
	_talk_draw()
	if _talk_open <= 0.0 and not _talk_source.is_valid():
		_talk_active = false


func _talk_draw() -> void:
	var o := _talk_open if _talk_open > TALK_SHUT else 0.0
	var gap := TALK_PART * o
	if _talk_parts[0] != null:
		_talk_parts[0].position = Vector3(-gap, 0.0, 0.0)
	if _talk_parts[1] != null:
		_talk_parts[1].position = Vector3(gap, 0.0, 0.0)
	if _talk_hole == null:
		return
	_talk_hole.visible = o > 0.0
	if o <= 0.0:
		return
	var half_w := gap + lerpf(TALK_OPEN_W_MIN, TALK_OPEN_W, o)
	var half_h := maxf(TALK_OPEN_H * o, 0.0005)
	_talk_hole.position = Vector3(0.0, TALK_OPEN_TOP - half_h, TALK_OPEN_Z)
	_talk_hole.scale = Vector3(half_w * 2.0, half_h * 2.0, TALK_OPEN_D * 2.0)
# --- end M25 mouth ---
