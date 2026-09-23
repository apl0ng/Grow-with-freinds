class_name ItemManager
extends Node3D
## World/Items container. Server-only spawn/despawn/give/drop API used by stations and shop.
## Uses the sibling MultiplayerSpawner (World/ItemSpawner, spawn_path = this node, spawn_function set here).
## (STUB - owned by the interaction/carry agent. Contract below must be kept.)

## SERVER ONLY. Spawns an item and returns it. `props` are type-specific initial values
## (watering_can: {"charges": int}; seed_packet: {"strain_id": StringName}; product: {"strain_id", "amount", "value"}).
## If holder_id != 0 the item spawns directly in that player's hands.
func server_spawn_item(item_type: StringName, props: Dictionary = {}, position: Vector3 = Vector3.ZERO, holder_id: int = 0) -> Item:
	return null

## SERVER ONLY. Removes an item everywhere.
func server_despawn_item(item: Item) -> void:
	pass

## SERVER ONLY. Puts `item` into `peer_id`'s hands. Returns false if that player already holds something.
func server_give_item(item: Item, peer_id: int) -> bool:
	return false

## SERVER ONLY. Drops `item` at a world position (holder cleared).
func server_drop_item(item: Item, position: Vector3) -> void:
	pass

## SERVER ONLY. Drops whatever `peer_id` holds (used on disconnect and on demand).
func server_release_holder(peer_id: int) -> void:
	pass

## Any peer. The item held by that player, or null.
func get_held_by(peer_id: int) -> Item:
	return null

## Any peer. All live items.
func get_items() -> Array[Item]:
	return []
