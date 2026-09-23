extends Control
## Decorative soft bubbles drifting up behind the main menu (pure drawing, ignores the mouse).

const COUNT: int = 22
const COLORS: Array[Color] = [
	Color(1.0, 0.494118, 0.713726), Color(0.301961, 0.658824, 0.968627), Color(1.0, 0.823529, 0.247059),
	Color(0.2, 0.819608, 0.690196), Color(0.603922, 0.419608, 1.0), Color(1.0, 1.0, 1.0),
]

var _bubbles: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rng.randomize()
	for i in COUNT:
		_bubbles.append(_new_bubble(_rng.randf()))

func _process(delta: float) -> void:
	for b in _bubbles:
		b["y"] = float(b["y"]) - float(b["speed"]) * delta
		b["phase"] = float(b["phase"]) + delta * float(b["wobble_speed"])
		if float(b["y"]) < -0.15:
			b.merge(_new_bubble(1.15), true)
	queue_redraw()

func _draw() -> void:
	var s := size
	if s.x <= 0.0 or s.y <= 0.0:
		return
	for b in _bubbles:
		var r: float = float(b["radius"]) * minf(s.x, s.y)
		var pos := Vector2((float(b["x"]) + sin(float(b["phase"])) * 0.015) * s.x, float(b["y"]) * s.y)
		var c: Color = b["color"]
		draw_circle(pos, r, Color(c, 0.22))
		draw_circle(pos, r * 0.82, Color(c, 0.18))
		draw_circle(pos + Vector2(-r * 0.35, -r * 0.35), r * 0.2, Color(1.0, 1.0, 1.0, 0.45))

func _new_bubble(start_y: float) -> Dictionary:
	return {
		"x": _rng.randf(),
		"y": start_y,
		"radius": _rng.randf_range(0.015, 0.06),
		"speed": _rng.randf_range(0.03, 0.09),
		"phase": _rng.randf() * TAU,
		"wobble_speed": _rng.randf_range(0.6, 1.6),
		"color": COLORS[_rng.randi() % COLORS.size()],
	}
