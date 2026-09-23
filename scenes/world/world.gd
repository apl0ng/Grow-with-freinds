class_name World
extends Node3D
## Root of the in-game scene. Owns player spawning (server) and lookups.
## (STUB - owned by the networking/player agent. Contract below must be kept.)

@onready var room: Node3D = $Room
@onready var players_root: Node3D = $Players
@onready var items: ItemManager = $Items
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var item_spawner: MultiplayerSpawner = $ItemSpawner

func get_player(peer_id: int) -> Player:
	return players_root.get_node_or_null(str(peer_id)) as Player

func get_players() -> Array[Player]:
	var out: Array[Player] = []
	for c in players_root.get_children():
		if c is Player:
			out.append(c)
	return out

## SERVER ONLY.
func server_spawn_player(peer_id: int) -> Player:
	return null

## SERVER ONLY.
func server_despawn_player(peer_id: int) -> void:
	pass
