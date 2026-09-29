extends Node
## Autoload "Comms": pings and text chat (PLAN.md M10, ui agent). Do NOT add a class_name (autoload).
##
## Surface = CONTRACTS.md "Comms". Both features are peer-to-peer cosmetics relayed by the server with
## @rpc("any_peer", "call_local", ...): a ping is a world position everyone marks for a few seconds; chat is a short
## sanitized line. Nothing here mutates game state except the host counting STAT_PINGS (GameState.server_add_stat).
##
## Sender side (local player):  ping(pos) / say(text) validate + rate-limit locally, then rpc().
## Receiver side (every peer, the sender included through call_local): the sender must be a registered worker
## (Net.players), the payload must be sane (finite position within PING_MAX_RANGE of the sender's player when that
## player exists here; chat sanitized again and non-empty), and per-sender gaps (PING_MIN_GAP_SEC / CHAT_MIN_GAP_SEC)
## are enforced with the receiver's own clock, so a flooding or hostile peer is dropped silently on every machine.
## Inside a handler `multiplayer.get_remote_sender_id()` is the sender; 0 (a direct local call, e.g. from a test)
## counts as this peer.

## Every peer: `peer_id` pinged `position` (world space).
signal ping_received(peer_id: int, position: Vector3)
## Every peer: `peer_id` said `text` (already sanitized, at most CHAT_MAX_CHARS).
signal chat_received(peer_id: int, text: String)

const CHAT_MAX_CHARS: int = 120
const PING_MIN_GAP_SEC: float = 0.8
const CHAT_MIN_GAP_SEC: float = 0.5
## Pings further than this from the sender's player are refused (garbage / cheating).
const PING_MAX_RANGE: float = 40.0
## A chat payload longer than this is dropped before it is even sanitized (bounded cost per packet).
const CHAT_MAX_RAW_CHARS: int = CHAT_MAX_CHARS * 4

## Pings / lines this peer sent this session (tests, debug).
var pings_sent: int = 0
var lines_sent: int = 0

## Local send throttles (msec of the last accepted local send).
var _last_ping_sent_msec: int = -1000000
var _last_chat_sent_msec: int = -1000000
## Receiver throttles: sender peer id -> msec of the last accepted packet.
var _last_ping_from: Dictionary = {}
var _last_chat_from: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Net.players_changed.connect(_on_players_changed)


# ---------------------------------------------------------------------------------------------
# Public API (local player)
# ---------------------------------------------------------------------------------------------

## Local player: mark `world_position` for everyone (bound to the "ping" action; the HUD picks the point).
## Silently ignored offline, with a non-finite position, or within PING_MIN_GAP_SEC of the previous ping.
func ping(world_position: Vector3) -> void:
	if not world_position.is_finite() or not _can_send():
		return
	var now := Time.get_ticks_msec()
	if now - _last_ping_sent_msec < int(PING_MIN_GAP_SEC * 1000.0):
		return
	_last_ping_sent_msec = now
	pings_sent += 1
	_rpc_ping.rpc(world_position)


## Local player: send a chat line (the HUD's chat box calls this). Sanitized first; empty lines are dropped, and
## a line within CHAT_MIN_GAP_SEC of the previous one is dropped too.
func say(text: String) -> void:
	if not _can_send():
		return
	var clean := sanitize_chat(text)
	if clean == "":
		return
	var now := Time.get_ticks_msec()
	if now - _last_chat_sent_msec < int(CHAT_MIN_GAP_SEC * 1000.0):
		return
	_last_chat_sent_msec = now
	lines_sent += 1
	_rpc_chat.rpc(clean)


## Strips control / invisible characters, collapses whitespace and clamps to CHAT_MAX_CHARS ("" if nothing left).
## Only the first CHAT_MAX_RAW_CHARS characters are looked at (constant cost for any input size).
static func sanitize_chat(text: String) -> String:
	var clean := ""
	for i in mini(text.length(), CHAT_MAX_RAW_CHARS):
		var code := text.unicode_at(i)
		if code == 0x20 or code == 0x09 or code == 0x0A or code == 0x0D or code == 0xA0 or code == 0x1680 \
				or (code >= 0x2000 and code <= 0x200A) or code == 0x202F or code == 0x205F or code == 0x3000:
			clean += " "
		elif code >= 0x20 and not (code >= 0x7F and code <= 0x9F) and not (code >= 0x200B and code <= 0x200F) \
				and not (code >= 0x2028 and code <= 0x202E) and not (code >= 0x2060 and code <= 0x206F) \
				and code != 0xFEFF and code != 0xAD and code != 0x034F and code != 0x061C and code != 0x180E \
				and not (code >= 0xFFF9 and code <= 0xFFFB) and not (code >= 0xE0000 and code <= 0xE007F):
			clean += String.chr(code)
	while clean.contains("  "):
		clean = clean.replace("  ", " ")
	return clean.strip_edges().left(CHAT_MAX_CHARS).strip_edges()


## Forgets every throttle (tests; also on a new session).
func reset_limits() -> void:
	_last_ping_sent_msec = -1000000
	_last_chat_sent_msec = -1000000
	_last_ping_from.clear()
	_last_chat_from.clear()


# ---------------------------------------------------------------------------------------------
# RPC receivers (every peer, the sender included)
# ---------------------------------------------------------------------------------------------

@rpc("any_peer", "call_local", "unreliable")
func _rpc_ping(position: Vector3) -> void:
	var sender := _sender_id()
	if sender <= 0 or not Net.players.has(sender):
		return
	if not position.is_finite():
		return
	var player: Node3D = Game.get_player(sender)
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		var d := position.distance_to(player.global_position)
		if not (d <= PING_MAX_RANGE): # written so NaN cannot pass
			return
	var now := Time.get_ticks_msec()
	if now - int(_last_ping_from.get(sender, -1000000)) < int(PING_MIN_GAP_SEC * 1000.0):
		return
	_last_ping_from[sender] = now
	ping_received.emit(sender, position)
	if multiplayer.is_server() and GameState.phase != GameState.Phase.MENU:
		GameState.server_add_stat(sender, Const.STAT_PINGS)


@rpc("any_peer", "call_local", "reliable")
func _rpc_chat(text: String) -> void:
	var sender := _sender_id()
	if sender <= 0 or not Net.players.has(sender):
		return
	if text.length() > CHAT_MAX_RAW_CHARS:
		return
	var clean := sanitize_chat(text)
	if clean == "":
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_chat_from.get(sender, -1000000)) < int(CHAT_MIN_GAP_SEC * 1000.0):
		return
	_last_chat_from[sender] = now
	chat_received.emit(sender, clean)


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

## The peer an RPC came from; 0 (a direct call outside any RPC) means this peer.
func _sender_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


## Sending needs a session (a world) and a live multiplayer peer; solo hosts count (call_local reaches them).
func _can_send() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	if Game.world == null or not is_instance_valid(Game.world):
		return false
	return Net.players.has(multiplayer.get_unique_id())


## A peer that left may re-join with a new id; its throttle entries are garbage. Keep the maps tidy.
func _on_players_changed() -> void:
	for id in _last_ping_from.keys():
		if not Net.players.has(id):
			_last_ping_from.erase(id)
	for id in _last_chat_from.keys():
		if not Net.players.has(id):
			_last_chat_from.erase(id)
	if Net.players.is_empty():
		reset_limits()
