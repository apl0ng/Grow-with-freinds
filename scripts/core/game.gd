extends Node
## Autoload "Game": scene flow (menu <-> world), local player, UI lock, toasts. (STUB - owned by the networking agent; see CONTRACTS.md)
signal world_ready(world: World)
signal local_player_spawned(player: Player)
signal toast_requested(text: String, kind: StringName)
signal ui_lock_changed(locked: bool)
var world: World = null
var local_player: Player = null
func start_host(_player_name: String, _port: int) -> void: pass
func start_join(_ip: String, _port: int, _player_name: String) -> void: pass
func return_to_menu(_message: String = "") -> void: pass
func get_player(peer_id: int) -> Player: return world.get_player(peer_id) if world else null
func get_local_peer_id() -> int: return multiplayer.get_unique_id()
func toast(text: String, kind: StringName = &"info") -> void: toast_requested.emit(text, kind)
func set_ui_lock(_source: StringName, _locked: bool) -> void: pass
func is_ui_locked() -> bool: return false
