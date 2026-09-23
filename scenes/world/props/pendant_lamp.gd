extends Node3D
## Industrial pendant lamp (world/level agent). Origin = ceiling mount; the chain, shade, bulb (under `Visual`)
## and the SpotLight child hang below it. Optional slow pendulum swing (local cosmetic, every peer on its own).

## Peak swing angle in degrees (0 = hangs still).
@export var swing_degrees: float = 0.0
## Seconds per full swing.
@export var swing_period: float = 7.0

var _rest: Vector3
var _t: float = 0.0


func _ready() -> void:
	_rest = rotation
	_t = randf() * maxf(swing_period, 0.1)
	set_process(swing_degrees > 0.0 and swing_period > 0.0)


func _process(delta: float) -> void:
	_t += delta
	var a := deg_to_rad(swing_degrees) * sin(_t * TAU / swing_period)
	rotation = _rest + Vector3(a * 0.3, 0.0, a)
