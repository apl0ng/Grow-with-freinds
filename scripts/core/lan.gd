extends Node
## Autoload "Lan": finds open floors on the local network, so friends never type an IP (M11, lead).
## Do NOT add a class_name (autoload).
##
## Host side: while Net.is_host and a world is up, a small UDP beacon goes out every BEACON_SEC to the broadcast
## address (and to 127.0.0.1, for several windows on one PC) on the discovery port DISCOVERY_PORT (7778):
##   {"gwf": 1, "name": host name, "port": game port, "players": n, "max": max_players}
## Menu side: listen() binds the discovery port and collects beacons keyed by "ip:port"; an entry not refreshed for
## EXPIRE_SEC disappears; games_changed fires on every change. A second menu on the same PC cannot bind the port
## (listen() returns the error, the list simply stays empty) unless the platform allows address reuse.
## Payloads are validated (size, magic, types, ranges) and names sanitized like player names; nothing here ever
## reaches game state.

## Every listener: the set of nearby games changed (added, refreshed with new numbers, or expired).
signal games_changed

const DISCOVERY_PORT: int = 7778
const BEACON_SEC: float = 1.0
const EXPIRE_SEC: float = 3.5
const MAGIC: String = "gwf"
const MAX_PACKET_BYTES: int = 512
const MAX_PEERS_LISTED: int = 32

var _beacon: PacketPeerUDP = null
var _listener: PacketPeerUDP = null
var _games: Dictionary = {}       # "ip:port" -> {"ip", "port", "name", "players", "max", "seen"}
var _beacon_accum: float = BEACON_SEC
var _clock: float = 0.0
## Test hook: beacons are also written here (host side) so a test can read what went out.
var last_beacon: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	stop_listening()
	_stop_beacon()


func _process(delta: float) -> void:
	_clock += delta
	_tick_beacon(delta)
	_poll_listener()
	_expire()


# --- Menu side -------------------------------------------------------------------------------------------------

## Starts collecting beacons. OK, or the bind error (port taken by another menu on this machine, no network).
func listen() -> Error:
	if _listener != null:
		return OK
	var udp := PacketPeerUDP.new()
	var err := udp.bind(DISCOVERY_PORT, "0.0.0.0")
	if err != OK:
		return err
	_listener = udp
	return OK


func stop_listening() -> void:
	if _listener != null:
		_listener.close()
		_listener = null
	if not _games.is_empty():
		_games.clear()
		games_changed.emit()


func is_listening() -> bool:
	return _listener != null


## Nearby games, newest first: [{"ip", "port", "name", "players", "max", "seen"}].
func get_games() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in _games:
		out.append((_games[key] as Dictionary).duplicate())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["seen"]) > float(b["seen"]))
	return out


## Test hook: handles `payload` as if it had arrived from `ip` (same validation as the real path).
func debug_inject_beacon(ip: String, payload: Variant) -> bool:
	var text := JSON.stringify(payload) if not payload is String else String(payload)
	return _accept(ip, text.to_utf8_buffer())


# --- Host side (automatic) ----------------------------------------------------------------------------------------

func _tick_beacon(delta: float) -> void:
	var hosting := Net.is_host and Game.world != null and is_instance_valid(Game.world) and multiplayer.has_multiplayer_peer()
	if not hosting:
		_stop_beacon()
		return
	_beacon_accum += delta
	if _beacon_accum < BEACON_SEC:
		return
	_beacon_accum = 0.0
	if _beacon == null:
		_beacon = PacketPeerUDP.new()
		_beacon.set_broadcast_enabled(true)
	var port := Config.balance.default_port
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer != null and peer.host != null:
		port = peer.host.get_local_port()
	last_beacon = {
		"gwf": 1,
		"name": Net.get_player_name(Const.SERVER_PEER_ID),
		"port": port,
		"players": Net.players.size(),
		"max": Config.balance.max_players,
	}
	var bytes := JSON.stringify(last_beacon).to_utf8_buffer()
	for address in ["255.255.255.255", "127.0.0.1"]:
		if _beacon.set_dest_address(address, DISCOVERY_PORT) == OK:
			_beacon.put_packet(bytes)


func _stop_beacon() -> void:
	if _beacon != null:
		_beacon.close()
		_beacon = null
	_beacon_accum = BEACON_SEC


# --- Internals -----------------------------------------------------------------------------------------------------

func _poll_listener() -> void:
	if _listener == null:
		return
	var budget := 32 # packets per frame at most (a flood cannot stall the menu)
	while _listener.get_available_packet_count() > 0 and budget > 0:
		budget -= 1
		var bytes := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		_accept(ip, bytes)


## Validates one beacon and records it. False when dropped.
func _accept(ip: String, bytes: PackedByteArray) -> bool:
	if bytes.is_empty() or bytes.size() > MAX_PACKET_BYTES or ip == "" or not ip.is_valid_ip_address():
		return false
	var json := JSON.new() # the instance API stays silent on garbage (parse_string logs an engine error)
	if json.parse(bytes.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return false
	var d: Dictionary = json.data
	if int(d.get("gwf", 0)) != 1:
		return false
	var port_v: Variant = d.get("port", 0)
	if not (port_v is float or port_v is int):
		return false
	var port := int(port_v)
	if port < 1024 or port > 65535:
		return false
	var players := clampi(int(d.get("players", 0)) if (d.get("players", 0) is float or d.get("players", 0) is int) else 0, 0, 99)
	var max_players := clampi(int(d.get("max", 0)) if (d.get("max", 0) is float or d.get("max", 0) is int) else 0, 0, 99)
	var raw_name: Variant = d.get("name", "")
	var host_name := Net.sanitize_name(String(raw_name) if raw_name is String else "")
	var key := "%s:%d" % [ip, port]
	if not _games.has(key) and _games.size() >= MAX_PEERS_LISTED:
		return false
	var before: Variant = _games.get(key)
	_games[key] = {"ip": ip, "port": port, "name": host_name, "players": players, "max": max_players, "seen": _clock}
	if before == null or before["name"] != host_name or before["players"] != players or before["max"] != max_players:
		games_changed.emit()
	return true


func _expire() -> void:
	if _games.is_empty():
		return
	var gone: Array = []
	for key in _games:
		if _clock - float(_games[key]["seen"]) > EXPIRE_SEC:
			gone.append(key)
	if gone.is_empty():
		return
	for key in gone:
		_games.erase(key)
	games_changed.emit()
