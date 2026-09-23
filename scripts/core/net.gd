extends Node
## Autoload "Net": ENet peer management + the synced player registry (see CONTRACTS.md).
##
## Host:   Net.host(port)      -> ENet server, players[1] registered immediately (solo play works the same).
## Client: Net.join(ip, port)  -> ENet client; on connect it sends name (+ optional preferred color) to the
##         server, the server validates, assigns a palette color and broadcasts the whole `players` dict.
## Scene flow (world creation, spawning, menu) lives in the Game autoload; Net only calls into Game/World
## for disconnect cleanup and for returning to the menu when the connection is lost.
##
## Player colors are assigned by the server from PALETTE by join order (first free slot), taken from the
## art palette (scripts/art/toon.gd): 1 bubblegum #FF7EB6 · 2 sky #4DA8F7 · 3 sunshine #FFD23F · 4 mint #33D1B0
## (spares, only if max_players > 4: 5 grape #9A6BFF · 6 tangerine #FF9A3C).

signal players_changed                      ## players dict changed (any peer)
signal connection_failed(reason: String)    ## client only: could not connect
signal server_disconnected                  ## client only: lost the host
signal peer_registered(peer_id: int)        ## SERVER: peer sent name/color, players[peer_id] now exists
signal peer_left(peer_id: int)              ## SERVER (and clients after sync): peer gone
signal peer_joined(peer_id: int)            ## any peer: a new player appeared in the registry (not emitted
											## for the initial list a joining client receives, nor for yourself)
signal peer_rejected(reason: String)        ## client only: the server refused us (e.g. "Server is full")

const PALETTE: Array[Color] = [
	Color(1.0, 0.494118, 0.713726),       # bubblegum pink  #FF7EB6
	Color(0.301961, 0.658824, 0.968627),  # sky blue        #4DA8F7
	Color(1.0, 0.823529, 0.247059),       # sunshine yellow #FFD23F
	Color(0.2, 0.819608, 0.690196),       # mint            #33D1B0
	Color(0.603922, 0.419608, 1.0),       # grape           #9A6BFF
	Color(1.0, 0.603922, 0.235294),       # tangerine       #FF9A3C
]
const MAX_NAME_LENGTH: int = 16
## Seconds a connected peer has to register (send its name) before the server drops it.
const REGISTER_TIMEOUT_SEC: float = 10.0
## Seconds between telling a peer it was rejected and forcibly disconnecting it (lets the reason RPC arrive).
const REJECT_DISCONNECT_DELAY_SEC: float = 1.0

## peer_id -> {"name": String, "color": Color}. Authoritative on the host, replicated to every client.
var players: Dictionary = {}
## True only on the host; valid immediately after host().
var is_host: bool = false
var local_name: String = "Player"
## Preferred color sent when registering (used if it is a free PALETTE color). Updated to the assigned color.
var local_color: Color = Color.WHITE

var _peer: ENetMultiplayerPeer = null
var _reject_reason: String = ""
## Names of peers that left this session, so get_player_name() still works for "X left" messages.
var _departed_names: Dictionary = {}
## Peers that were rejected and are waiting for their forced disconnect (server).
var _rejected_peers: Dictionary = {}

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# --- Public API -------------------------------------------------------------------------------------------

## Starts an ENet server and registers the host as peer 1. Returns OK or the ENet error.
func host(port: int = Config.balance.default_port) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	# One spare ENet slot beyond (max_players - 1) clients so an extra joiner can be told "Server is full"
	# instead of timing out silently; the gameplay cap is enforced in _rpc_register.
	var err := peer.create_server(port, maxi(1, Config.balance.max_players))
	if err != OK:
		_log("could not host on port %d: %s" % [port, error_string(err)])
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	is_host = true
	_reset_session_state()
	local_name = sanitize_name(local_name)
	var color := _pick_color(local_color, {})
	var next: Dictionary = {Const.SERVER_PEER_ID: {"name": local_name, "color": color}}
	_apply_players(next)
	_log("hosting on port %d as \"%s\"" % [port, local_name])
	return OK

## Starts connecting to a host. Registration happens automatically once connected.
## Returns OK when the attempt started (the result arrives via Game / connection_failed).
func join(ip: String, port: int = Config.balance.default_port) -> Error:
	leave()
	var address := ip.strip_edges()
	if address == "":
		return ERR_INVALID_PARAMETER
	if not address.is_valid_ip_address():
		# Resolve hostnames up front: gives a clean error instead of an engine error spam from ENet.
		var resolved := IP.resolve_hostname(address, IP.TYPE_IPV4)
		if resolved == "":
			return ERR_CANT_RESOLVE
		address = resolved
	if port < 1 or port > 65535:
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		_log("could not start connecting to %s:%d: %s" % [address, port, error_string(err)])
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	is_host = false
	_reset_session_state()
	local_name = sanitize_name(local_name)
	_log("connecting to %s:%d as \"%s\" (peer id %d)" % [address, port, local_name, peer.get_unique_id()])
	return OK

## Disconnects (host or client) and clears all session state. Safe to call at any time.
func leave() -> void:
	var old_peer := multiplayer.multiplayer_peer
	if old_peer is ENetMultiplayerPeer:
		_log("leaving session")
	# Swap in the offline peer first so no disconnect signals from the old peer reach SceneMultiplayer.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if old_peer is ENetMultiplayerPeer:
		(old_peer as ENetMultiplayerPeer).close()
	if _peer != null and _peer != old_peer:
		_peer.close()
	_peer = null
	is_host = false
	var had_players := not players.is_empty()
	_reset_session_state()
	if had_players:
		players_changed.emit()

## True while hosting or connected to a host.
func is_online() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func get_player_name(peer_id: int) -> String:
	if players.has(peer_id):
		return String(players[peer_id].get("name", "Player"))
	if _departed_names.has(peer_id):
		return String(_departed_names[peer_id])
	return "Player %d" % peer_id if peer_id != Const.SERVER_PEER_ID else "Host"

func get_player_color(peer_id: int) -> Color:
	if players.has(peer_id):
		var c: Variant = players[peer_id].get("color", Color.WHITE)
		if c is Color:
			return c
	# Deterministic fallback so an unknown peer still gets a stable bright color.
	return PALETTE[absi(peer_id) % PALETTE.size()]

## Peer ids in the registry, sorted (host first).
func get_peer_ids() -> Array[int]:
	var out: Array[int] = []
	for k in players.keys():
		out.append(int(k))
	out.sort()
	return out

## Trims, strips control characters and clamps a display name. Never returns "".
static func sanitize_name(raw: String) -> String:
	var clean := ""
	for ch in raw.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			clean += ch
	clean = clean.strip_edges().left(MAX_NAME_LENGTH).strip_edges()
	return clean if clean != "" else "Farmer"

# --- Server side -------------------------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if not is_host:
		return
	# Drop peers that never register (stray connections, incompatible builds...).
	get_tree().create_timer(REGISTER_TIMEOUT_SEC).timeout.connect(_on_register_timeout.bind(peer_id))

func _on_register_timeout(peer_id: int) -> void:
	if not is_host or players.has(peer_id) or not _is_peer_connected(peer_id):
		return
	_reject(peer_id, "Did not register in time")

func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host:
		return # clients learn about departures through _rpc_players_sync
	_rejected_peers.erase(peer_id)
	var world: World = Game.world
	if world != null and is_instance_valid(world):
		if world.items != null:
			world.items.server_release_holder(peer_id)
		world.server_despawn_player(peer_id)
	if players.has(peer_id):
		_log("peer %d (%s) disconnected" % [peer_id, get_player_name(peer_id)])
		var next := players.duplicate(true)
		next.erase(peer_id)
		_rpc_players_sync.rpc(next)

## Client -> server: "here is my name (and preferred color)". Sent automatically on connected_to_server.
@rpc("any_peer", "call_local", "reliable")
func _rpc_register(player_name: String, preferred_color: Color) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	if players.has(sender) or _rejected_peers.has(sender):
		return # duplicate registration
	if players.size() >= Config.balance.max_players:
		_reject(sender, "Server is full (%d/%d players)" % [players.size(), Config.balance.max_players])
		return
	var next := players.duplicate(true)
	next[sender] = {
		"name": _unique_name(sanitize_name(player_name), next),
		"color": _pick_color(preferred_color, next),
	}
	_rpc_players_sync.rpc(next)
	_log("peer %d registered as \"%s\"" % [sender, get_player_name(sender)])
	peer_registered.emit(sender)

func _reject(peer_id: int, reason: String) -> void:
	_log("rejecting peer %d: %s" % [peer_id, reason])
	_rejected_peers[peer_id] = true
	_rpc_rejected.rpc_id(peer_id, reason)
	# The client leaves on its own when it gets the reason; force it after a short delay regardless.
	get_tree().create_timer(REJECT_DISCONNECT_DELAY_SEC).timeout.connect(_force_disconnect.bind(peer_id))

func _force_disconnect(peer_id: int) -> void:
	if not is_host or _peer == null or not _is_peer_connected(peer_id):
		return
	_peer.disconnect_peer(peer_id)

func _is_peer_connected(peer_id: int) -> bool:
	return multiplayer.multiplayer_peer is ENetMultiplayerPeer and peer_id in multiplayer.get_peers()

## Lowest palette color not used by anyone else (preferred color wins if it is a free palette color).
func _pick_color(preferred: Color, taken_by: Dictionary) -> Color:
	var used: Array[Color] = []
	for v in taken_by.values():
		used.append(v.get("color", Color.WHITE))
	if preferred in PALETTE and not preferred in used:
		return preferred
	for c in PALETTE:
		if not c in used:
			return c
	return PALETTE[taken_by.size() % PALETTE.size()]

## "Bob" -> "Bob 2" if another player already uses that name.
func _unique_name(wanted: String, taken_by: Dictionary) -> String:
	var names: Array[String] = []
	for v in taken_by.values():
		names.append(String(v.get("name", "")))
	if not wanted in names:
		return wanted
	var n := 2
	while ("%s %d" % [wanted.left(MAX_NAME_LENGTH - 2), n]) in names:
		n += 1
	return "%s %d" % [wanted.left(MAX_NAME_LENGTH - 2), n]

# --- Client side -------------------------------------------------------------------------------------------

func _on_connected_to_server() -> void:
	_log("connected, registering")
	_rpc_register.rpc_id(Const.SERVER_PEER_ID, local_name, local_color)

func _on_connection_failed() -> void:
	var reason := "Could not connect to host"
	_log(reason)
	_peer = null
	connection_failed.emit(reason)
	Game.return_to_menu.call_deferred(reason)

func _on_server_disconnected() -> void:
	_peer = null
	var reason := _reject_reason if _reject_reason != "" else "Host disconnected"
	_log("server connection closed: " + reason)
	server_disconnected.emit()
	Game.return_to_menu.call_deferred(reason)

## Server -> one client: you were refused. The client leaves and shows the reason in the menu.
@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(reason: String) -> void:
	_reject_reason = reason
	peer_rejected.emit(reason)
	Game.return_to_menu.call_deferred(reason)

## Server -> everyone: the full registry. Runs locally on the server too (call_local).
@rpc("authority", "call_local", "reliable")
func _rpc_players_sync(new_players: Dictionary) -> void:
	var next: Dictionary = {}
	for k in new_players.keys():
		var entry: Variant = new_players[k]
		if not entry is Dictionary:
			continue
		var color: Variant = entry.get("color", Color.WHITE)
		next[int(k)] = {
			"name": String(entry.get("name", "Player")),
			"color": color if color is Color else Color.WHITE,
		}
	_apply_players(next)

## Replaces the registry, emitting peer_joined / peer_left / players_changed for the differences.
func _apply_players(next: Dictionary) -> void:
	var initial := players.is_empty()
	var my_id := multiplayer.get_unique_id()
	var joined: Array[int] = []
	var left: Array[int] = []
	for id in next.keys():
		if not players.has(id):
			joined.append(int(id))
	for id in players.keys():
		if not next.has(id):
			left.append(int(id))
			_departed_names[int(id)] = String(players[id].get("name", ""))
	players = next
	if players.has(my_id):
		local_name = String(players[my_id]["name"])
		local_color = players[my_id]["color"]
	players_changed.emit()
	for id in left:
		peer_left.emit(id)
	if not initial:
		for id in joined:
			if id != my_id:
				peer_joined.emit(id)

func _log(text: String) -> void:
	print("[Net] " + text)

func _reset_session_state() -> void:
	players = {}
	_departed_names.clear()
	_rejected_peers.clear()
	_reject_reason = ""
