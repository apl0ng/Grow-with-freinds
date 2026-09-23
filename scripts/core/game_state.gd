extends Node
## Autoload "GameState": money, quota, timer, rounds. (STUB)
enum Phase { MENU, WAITING, PLAYING, ROUND_SUCCESS, ROUND_FAILED }
var phase: int = Phase.MENU
func is_playing() -> bool: return phase == Phase.PLAYING
func get_effect_total(effect_key: StringName) -> float: return 0.0
