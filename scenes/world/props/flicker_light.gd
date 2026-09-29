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
var _powered: bool = true
var _stutter: Tween


func _ready() -> void:
	_light = get_node_or_null(^"Light") as Light3D
	_tubes = get_node_or_null(^"Visual/Tubes") as Node3D
	if _light != null:
		_energy = _light.light_energy
	_wait = randf_range(min_gap, max_gap)
	set_process(_powered and flicker and (_light != null or _tubes != null))


## M10 (power cut, called by Room.set_power): off = tubes dark, no stutters, the light's energy left alone
## (the Room fades every light itself); on = tubes back, stutters resume. Idempotent.
func set_powered(on: bool) -> void:
	if on == _powered:
		return
	_powered = on
	if _stutter != null and _stutter.is_valid():
		_stutter.kill()
	if _tubes != null:
		_tubes.visible = on
	if on:
		_wait = randf_range(min_gap, maxf(max_gap, min_gap))
	set_process(on and flicker and (_light != null or _tubes != null))


func is_powered() -> bool:
	return _powered


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = randf_range(min_gap, maxf(max_gap, min_gap))
	var tw := create_tween()
	_stutter = tw
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
