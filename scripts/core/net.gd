extends Node
## Autoload "Net": ENet peer management + player registry. (STUB - owned by the networking agent; see CONTRACTS.md)
signal players_changed
signal connection_failed(reason: String)
signal server_disconnected
signal peer_registered(peer_id: int)
signal peer_left(peer_id: int)
var players: Dictionary = {}
var is_host: bool = false
var local_name: String = "Player"
var local_color: Color = Color.WHITE
func host(_port: int = 7777) -> Error: return ERR_UNAVAILABLE
func join(_ip: String, _port: int = 7777) -> Error: return ERR_UNAVAILABLE
func leave() -> void: pass
func is_online() -> bool: return false
func get_player_name(peer_id: int) -> String: return str(peer_id)
func get_player_color(_peer_id: int) -> Color: return Color.WHITE
