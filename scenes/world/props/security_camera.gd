extends Node3D
## Wall-mounted security camera (world/level agent). Slowly pans left/right and blinks its red LED.
## Looks up `Visual/Pan` and `Visual/Pan/Tilt/Led` null-safely (a modelled camera can replace `Visual`).

@export var pan_degrees: float = 35.0
@export var pan_period: float = 10.0

var _pan: Node3D
var _led: Node3D
var _t: float = 0.0


func _ready() -> void:
	_pan = get_node_or_null(^"Visual/Pan") as Node3D
	_led = get_node_or_null(^"Visual/Pan/Tilt/Led") as Node3D
	_t = randf() * maxf(pan_period, 0.1)
	set_process(_pan != null or _led != null)


func _process(delta: float) -> void:
	_t += delta
	if _pan != null and pan_period > 0.0:
		_pan.rotation.y = deg_to_rad(pan_degrees) * sin(_t * TAU / pan_period)
	if _led != null:
		_led.visible = fmod(_t, 1.4) < 0.7
