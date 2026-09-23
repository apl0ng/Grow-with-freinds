extends Node3D
## Hanging fluorescent fixture (world/level agent). Origin = ceiling mount. With `flicker` on, the tubes stutter
## off and on every few seconds (subtle, local cosmetic). Looks up `Light` (Light3D) and `Visual/Tubes`
## null-safely, so a modelled fixture can replace `Visual`.

@export var flicker: bool = false
## Seconds between stutters (random in this range).
@export var min_gap: float = 2.5
@export var max_gap: float = 8.0
## Light energy while "off", as a fraction of the normal energy.
@export_range(0.0, 1.0) var off_fraction: float = 0.2

var _light: Light3D
var _tubes: Node3D
var _energy: float = 1.0
var _wait: float = 0.0


func _ready() -> void:
	_light = get_node_or_null(^"Light") as Light3D
	_tubes = get_node_or_null(^"Visual/Tubes") as Node3D
	if _light != null:
		_energy = _light.light_energy
	_wait = randf_range(min_gap, max_gap)
	set_process(flicker and (_light != null or _tubes != null))


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = randf_range(min_gap, maxf(max_gap, min_gap))
	var tw := create_tween()
	for i in randi_range(2, 4):
		tw.tween_callback(_set_on.bind(false))
		tw.tween_interval(randf_range(0.03, 0.09))
		tw.tween_callback(_set_on.bind(true))
		tw.tween_interval(randf_range(0.05, 0.18))


func _set_on(on: bool) -> void:
	if _light != null:
		_light.light_energy = _energy if on else _energy * off_fraction
	if _tubes != null:
		_tubes.visible = on
