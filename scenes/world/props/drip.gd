extends Node3D
## Leaking pipe (world/level agent): a drop swells at the joint, falls into the puddle and the puddle wobbles.
## Uses `Visual/Drop` and `Visual/Puddle` (looked up null-safely). Local cosmetic only.

## Seconds between drops.
@export var interval: float = 1.7
## Seconds a drop takes to swell before it falls.
@export var swell_time: float = 0.8

const _GRAVITY := 9.8

var _drop: Node3D
var _puddle: Node3D
var _start: Vector3
var _drop_scale: Vector3 = Vector3.ONE
var _puddle_scale: Vector3 = Vector3.ONE
var _t: float = 0.0
var _landed: bool = false


func _ready() -> void:
	_drop = get_node_or_null(^"Visual/Drop") as Node3D
	_puddle = get_node_or_null(^"Visual/Puddle") as Node3D
	if _drop != null:
		_start = _drop.position
		_drop_scale = _drop.scale
	if _puddle != null:
		_puddle_scale = _puddle.scale
	_t = randf() * interval
	set_process(_drop != null)


func _process(delta: float) -> void:
	_t = fmod(_t + delta, maxf(interval, swell_time + 0.1))
	if _t < swell_time:
		_landed = false
		_drop.visible = true
		_drop.position = _start
		_drop.scale = _drop_scale * lerpf(0.2, 1.0, _t / swell_time)
		return
	var k := _t - swell_time
	var y := _start.y - 0.5 * _GRAVITY * k * k
	var floor_y := _puddle.position.y if _puddle != null else 0.0
	if y <= floor_y:
		_drop.visible = false
		if not _landed:
			_landed = true
			_splash()
		return
	_drop.position = Vector3(_start.x, y, _start.z)


func _splash() -> void:
	if _puddle == null:
		return
	var tw := create_tween()
	tw.tween_property(_puddle, ^"scale", _puddle_scale * Vector3(1.08, 1.0, 1.08), 0.08)
	tw.tween_property(_puddle, ^"scale", _puddle_scale, 0.25).set_trans(Tween.TRANS_SINE)
