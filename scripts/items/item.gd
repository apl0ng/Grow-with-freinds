class_name Item
extends Interactable
## Base class for carryable items (watering can, seed packet, product).
## Items are spawned ONLY by the server through ItemManager (MultiplayerSpawner with spawn_function).
## They always live under World/Items; when held they follow the holder's hand socket every frame
## (never reparented - reparenting a spawned node despawns it on clients).
## (STUB - owned by the interaction/carry agent. Contract below must be kept.)

## One of Const.ITEM_* values. Set by the item scene.
@export var item_type: StringName = &"item"
## Peer id of the player holding this item, 0 when lying in the world. Synced (server authority).
var holder_id: int = 0

func get_display_name() -> String:
	return String(item_type).capitalize()

func is_held() -> bool:
	return holder_id != 0

func get_holder() -> Player:
	return Game.get_player(holder_id) if holder_id != 0 else null
