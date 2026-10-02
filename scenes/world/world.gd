class_name World
extends Node3D
## Root of the in-game scene (instantiated manually under the root by Game). Owns player spawning (server)
## and lookups. Players are spawned through $PlayerSpawner with a custom spawn_function, so the same
## spawn data produces the same node (name == peer id, authority == peer id, spawn transform) on every peer,
## including late joiners (the spawner re-sends every tracked node when a peer connects).
##
## World
## ├─ Room            (room.tscn instance)
## ├─ Players         (Player nodes named by peer id)
## ├─ PlayerSpawner   (MultiplayerSpawner, spawn_path ../Players, spawn_function = _spawn_player)
## ├─ Items           (ItemManager)
## ├─ ItemSpawner     (MultiplayerSpawner, spawn_path ../Items, spawn_function set by ItemManager)
## ├─ HUD             (hud.tscn instance)
## └─ OverviewCamera  (Camera3D shown until the local player's camera takes over, e.g. while connecting)

const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"

@onready var room: Room = $Room
@onready var players_root: Node3D = $Players
@onready var items: ItemManager = $Items
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var item_spawner: MultiplayerSpawner = $ItemSpawner
@onready var overview_camera: Camera3D = $OverviewCamera

var _player_scene: PackedScene = null

func _ready() -> void:
	_player_scene = load(PLAYER_SCENE_PATH) as PackedScene
	player_spawner.spawn_function = _spawn_player

func get_player(peer_id: int) -> Player:
	if players_root == null:
		return null
	var p := players_root.get_node_or_null(str(peer_id)) as Player
	if p != null and p.is_queued_for_deletion():
		return null
	return p

## All live players, sorted by peer id (host first).
func get_players() -> Array[Player]:
	var out: Array[Player] = []
	if players_root == null:
		return out
	for c in players_root.get_children():
		var p := c as Player
		if p != null and not p.is_queued_for_deletion():
			out.append(p)
	out.sort_custom(func(a: Player, b: Player) -> bool: return a.peer_id < b.peer_id)
	return out

## SERVER ONLY. Spawns (and replicates) the Player for `peer_id`. Returns the existing one if already spawned.
func server_spawn_player(peer_id: int) -> Player:
	if not multiplayer.is_server():
		push_error("World.server_spawn_player called on a client")
		return null
	var existing := get_player(peer_id)
	if existing != null:
		return existing
	var data := {
		"peer_id": peer_id,
		"name": Net.get_player_name(peer_id),
		"color": Net.get_player_color(peer_id),
		"spawn_index": _free_spawn_index(),
	}
	_lobby_tag_spawn(data) # M14 lobby
	return player_spawner.spawn(data) as Player

## SERVER ONLY. Removes the player everywhere (the spawner replicates the despawn).
func server_despawn_player(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var p := get_player(peer_id)
	if p == null:
		return
	players_root.remove_child(p)
	p.queue_free()

## SERVER ONLY. Sends every player back to its spawn point (e.g. on a game reset).
func server_reset_player_positions() -> void:
	if not multiplayer.is_server():
		return
	for p in get_players():
		p.server_teleport(get_spawn_transform(p.spawn_index))

## Spawn transform for a spawn index, in Players-local space (== global while Players sits at the origin).
func get_spawn_transform(spawn_index: int) -> Transform3D:
	var xf := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	if room != null and room.has_method("get_spawn_transform"):
		xf = room.get_spawn_transform(spawn_index)
	if players_root != null and players_root.is_inside_tree():
		xf = players_root.global_transform.affine_inverse() * xf
	return xf

## Runs on EVERY peer with the same data (server: via spawn(); clients: from the spawn packet).
## Everything that must match across peers is set here, before the node enters the tree.
func _spawn_player(data: Variant) -> Node:
	var d: Dictionary = data if data is Dictionary else {}
	var pid := int(d.get("peer_id", Const.SERVER_PEER_ID))
	var player := _player_scene.instantiate() as Player
	player.name = str(pid)
	player.peer_id = pid
	player.display_name = String(d.get("name", Net.get_player_name(pid)))
	var color: Variant = d.get("color", null)
	player.player_color = color if color is Color else Net.get_player_color(pid)
	player.spawn_index = int(d.get("spawn_index", 0))
	player.set_multiplayer_authority(pid, true)
	player.place_at(_lobby_spawn_transform(d, player.spawn_index)) # M14 lobby (get_spawn_transform unless the data names a place)
	return player

# --- M14 lobby ---------------------------------------------------------------------------------------------------
# The alley and the van (scenes/world/lobby.tscn, one `Lobby` node at (0, 0, 80)). With Config.lobby_enabled the host
# tags every spawn with the place the worker starts at: the alley while the phase is MENU / WAITING, the loading dock
# (Room.get_arrival_transform) when they join during a shift. The tag travels in the spawn data, so every peer builds
# the same body at the same spot. Without the tag (lobby off) nothing changes: the room's spawn points.

const SPAWN_AT_KEY := "at"
const SPAWN_AT_LOBBY := "lobby"
const SPAWN_AT_ARRIVAL := "arrival"

## The alley (null in a world without one).
var lobby: Lobby:
	get:
		return get_node_or_null(^"Lobby") as Lobby

## Where the spawn_index-th worker waits in the alley, in Players-local space (the room spawn without a lobby).
func get_lobby_transform(spawn_index: int) -> Transform3D:
	var alley := lobby
	if alley == null:
		return get_spawn_transform(spawn_index)
	return _to_players_space(alley.get_spawn_transform(spawn_index))

## Where the spawn_index-th worker stands after the van ride (the loading dock), in Players-local space.
func get_arrival_transform(spawn_index: int) -> Transform3D:
	if room == null or not room.has_method(&"get_arrival_transform"):
		return get_spawn_transform(spawn_index)
	return _to_players_space(room.get_arrival_transform(spawn_index))

## SERVER ONLY. Every worker to the dock (the van arrived).
func server_move_players_to_floor() -> void:
	if not multiplayer.is_server():
		return
	for p in get_players():
		_lobby_move(p, get_arrival_transform(p.spawn_index))

## SERVER ONLY. Every worker back to the alley. What they carry stays on the floor where they stood.
func server_move_players_to_lobby() -> void:
	if not multiplayer.is_server():
		return
	for p in get_players():
		if items != null:
			items.server_release_holder(p.peer_id)
		_lobby_move(p, get_lobby_transform(p.spawn_index))

## Owned bodies go through Player.server_teleport (owner-authoritative movement); a body nobody owns (a fake worker in
## a headless test) is placed directly.
func _lobby_move(player: Player, xf: Transform3D) -> void:
	if player.is_local() or multiplayer.get_peers().has(player.peer_id):
		player.server_teleport(xf)
	else:
		player.place_at(xf)

func _lobby_tag_spawn(data: Dictionary) -> void:
	if not Config.lobby_enabled or lobby == null:
		return
	var waiting: bool = GameState.phase == GameState.Phase.MENU or GameState.phase == GameState.Phase.WAITING
	data[SPAWN_AT_KEY] = SPAWN_AT_LOBBY if waiting else SPAWN_AT_ARRIVAL

func _lobby_spawn_transform(data: Dictionary, spawn_index: int) -> Transform3D:
	match String(data.get(SPAWN_AT_KEY, "")):
		SPAWN_AT_LOBBY:
			return get_lobby_transform(spawn_index)
		SPAWN_AT_ARRIVAL:
			return get_arrival_transform(spawn_index)
	return get_spawn_transform(spawn_index)

func _to_players_space(xf: Transform3D) -> Transform3D:
	if players_root != null and players_root.is_inside_tree():
		return players_root.global_transform.affine_inverse() * xf
	return xf

# --- end M14 lobby -------------------------------------------------------------------------------------------------

func _free_spawn_index() -> int:
	var used: Dictionary = {}
	for p in get_players():
		used[p.spawn_index] = true
	var i := 0
	while used.has(i):
		i += 1
	return i
