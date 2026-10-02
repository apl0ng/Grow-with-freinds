extends Marker3D
## Room `Dock/HandTruckSpot` (M17 cart): where the hand truck stands, a marker on the loading dock's floor (the truck's
## plate faces the marker's -Z). Room.get_hand_truck_spot() reads it. This script keeps the run's one truck there; it
## only acts on the host:
##   GameState.round_started  every shift, the first included: HandTruck.server_stand() puts the truck back here, out
##                            of anyone's hands, upright, its load kept; spawns it here, empty, when there is none
##   GameState.game_reset     START OVER: every truck is despawned (ItemManager despawns the loose bundles the same
##                            way); the next shift's start spawns a fresh one
## Nothing here is synced: the truck is an ordinary item (the spawner brings it to every peer and to late joiners, its
## MultiplayerSynchronizer its load and resting place).


func _ready() -> void:
	GameState.round_started.connect(_on_round_started)
	GameState.game_reset.connect(_on_game_reset)


func _on_round_started(_round_number: int) -> void:
	var items := _host_items()
	if items == null:
		return
	HandTruck.server_stand(items, global_transform)


func _on_game_reset() -> void:
	var items := _host_items()
	if items != null:
		HandTruck.server_despawn_all(items)


## The ItemManager of this world on the host (null on a client, or without a world).
func _host_items() -> ItemManager:
	if not is_inside_tree() or not Net.is_host or not multiplayer.has_multiplayer_peer() or not multiplayer.is_server():
		return null
	var items := ItemManager.find(self)
	return items if items != null and items.spawner != null and items.is_inside_tree() else null
