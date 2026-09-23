extends Node
## Autoload "Game": scene flow (menu <-> world), local player, UI lock, toasts. (STUB)
signal toast_requested(text: String, kind: StringName)
var world: Node = null
var local_player: Node = null
func get_player(peer_id: int) -> Node: return null
func toast(text: String, kind: StringName = &"info") -> void: toast_requested.emit(text, kind)
func is_ui_locked() -> bool: return false
