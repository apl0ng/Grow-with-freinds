extends Marker3D
## Room `Decor/RadioShelf/Spot` (M18 radio): the middle of the radio shelf's top, its -Z towards the room (a radio
## stood here with the marker's yaw shows its face, Godot -Z, to the room). Room.get_radio_spot() /
## get_radio_slot() read it. This script keeps the run's radios on the shelf; it only acts on the host:
##   GameState.round_started  every shift, the first included: Radio.server_stock() with Config.balance.radio_count
##                            slots: the first shift spawns them on the shelf; later shifts put back a radio left
##                            outside the building (the alley) and replace a missing one; the rest stay where they are
##   GameState.game_reset     START OVER: every radio is despawned (like the hand truck and the loose bundles); the
##                            next shift's start stocks the shelf again
## Nothing here is synced: radios are ordinary items (the spawner brings them to every peer and to late joiners).


func _ready() -> void:
	GameState.round_started.connect(_on_round_started)
	GameState.game_reset.connect(_on_game_reset)


func _on_round_started(_round_number: int) -> void:
	var items := _host_items()
	if items == null:
		return
	var room := _room()
	var count := maxi(Config.balance.radio_count, 0)
	var slots: Array[Transform3D] = []
	for i in count:
		slots.append(room.get_radio_slot(i, count) if room != null else global_transform)
	Radio.server_stock(items, slots, room)


func _on_game_reset() -> void:
	var items := _host_items()
	if items != null:
		Radio.server_despawn_all(items)


## The Room this marker belongs to (null when it is not under one).
func _room() -> Room:
	var n: Node = get_parent()
	while n != null:
		if n is Room:
			return n as Room
		n = n.get_parent()
	return null


## The ItemManager of this world on the host (null on a client, or without a world).
func _host_items() -> ItemManager:
	if not is_inside_tree() or not Net.is_host or not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return null
	var items := ItemManager.find(self)
	return items if items != null and items.spawner != null and items.is_inside_tree() else null
