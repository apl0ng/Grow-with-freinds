extends Node3D
## Wall clock (world/level agent). The second hand ticks once a second and the minute hand creeps along.
## Hands: `Visual/SecondHand`, `Visual/MinuteHand` (rotation.z, clockwise = negative), looked up null-safely.

var _second_hand: Node3D
var _minute_hand: Node3D
var _seconds: int = 0
var _minute_rest: float = 0.0
var _acc: float = 0.0


func _ready() -> void:
	_second_hand = get_node_or_null(^"Visual/SecondHand") as Node3D
	_minute_hand = get_node_or_null(^"Visual/MinuteHand") as Node3D
	if _minute_hand != null:
		_minute_rest = _minute_hand.rotation.z
	_seconds = randi() % 60
	_apply()
	set_process(_second_hand != null or _minute_hand != null)


func _process(delta: float) -> void:
	_acc += delta
	if _acc < 1.0:
		return
	_acc -= 1.0
	_seconds += 1
	_apply()


func _apply() -> void:
	if _second_hand != null:
		_second_hand.rotation.z = -TAU * float(_seconds % 60) / 60.0
	if _minute_hand != null:
		_minute_hand.rotation.z = _minute_rest - TAU * float(_seconds) / 3600.0
