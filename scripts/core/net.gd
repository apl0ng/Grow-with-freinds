extends Node
## Autoload "Net": ENet peer management + player registry. (STUB - owned by the networking agent)
signal players_changed
signal connection_failed(reason: String)
signal server_disconnected
const DEFAULT_PORT := 7777
var players: Dictionary = {}
var is_host: bool = false
func is_online() -> bool: return false
func get_player_name(peer_id: int) -> String: return str(peer_id)
