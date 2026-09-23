extends Node
## End-to-end farming test on the real game stack (owner: farming agent). Run through farm_world_test.gd.
## Hosts a real session (Game.start_host -> World/Room/ItemManager/items/Player) and plays the farming loop
## through the public Interactable.interact() path (local check -> RPC to the server -> distance +
## can_interact validation -> _server_interact): starting cans, plant, water, refill, grow, harvest, reset.

## Emitted once with the number of failed checks.
signal finished(failures: int)

const GROWTH_OVERRIDE := 40.0

var _passed := 0
var _failed := 0

func run() -> void:
	Config.growth_speed_override = GROWTH_OVERRIDE
	var port := 22000 + randi() % 20000
	var err: Error = Game.start_host("FarmTester", port)
	_check(err == OK, "Game.start_host", error_string(err))
	if err != OK:
		return _finish()
	var world: World = await Game.world_ready
	await _frames(5)
	var items := world.items
	var room := world.room
	var well := room.get_node("Stations/Well") as Well
	var plot := room.get_node("Stations/GrowPlot1") as GrowPlot
	var plot2 := room.get_node("Stations/GrowPlot2") as GrowPlot
	var player := Game.get_player(Const.SERVER_PEER_ID)
	_check(well != null and plot != null and plot2 != null and player != null, "room has Well + GrowPlots, host player spawned")
	if well == null or plot == null or player == null:
		return _finish()
	var cap := GameState.get_can_capacity()

	# --- starting cans
	var cans := _cans(items)
	var at_spots := true
	var spots := well.get_can_spots()
	for c in cans:
		var near := false
		for s in spots:
			near = near or c.global_position.distance_to(s.global_position) < 0.05
		at_spots = at_spots and near and int(c.get(&"charges")) == cap and not c.is_held()
	_check(cans.size() == Config.balance.starting_watering_cans and at_spots,
		"%d full watering cans spawned at the well's CanSpots" % Config.balance.starting_watering_cans, "%d cans" % cans.size())
	if cans.is_empty():
		return _finish()
	var can: Item = cans[0]

	# --- plant (real SeedPacket in hands)
	var packet := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"}, player.global_position, player.peer_id)
	await _frames(2)
	_stand_at(player, plot)
	_check(player.get_held_item() == packet and plot.get_prompt(player) == "Plant Budget Bud" and plot.can_interact(player),
		"holding a real seed packet: prompt 'Plant Budget Bud'", plot.get_prompt(player))
	plot.interact(player)
	await _frames(3)
	_check(plot.stage == GrowPlot.Stage.SEEDLING and plot.strain_id == &"budget", "interact() plants the seed (server validated)")
	_check(player.get_held_item() == null and not is_instance_valid(packet), "the seed packet is consumed")

	# --- water with a real WateringCan
	items.server_give_item(can, player.peer_id)
	await _frames(2)
	_check(plot.get_prompt(player) == "Water plant (dry)", "holding a can at a dry plant: 'Water plant (dry)'", plot.get_prompt(player))
	plot.interact(player)
	await _frames(3)
	_check(is_equal_approx(plot.water, minf(1.0, Config.balance.water_per_charge)) and int(can.get(&"charges")) == cap - 1,
		"interact() waters the plant and spends one charge", "water %.3f charges %d" % [plot.water, int(can.get(&"charges"))])
	plot.interact(player)   # already full -> denied locally, nothing changes
	await _frames(3)
	_check(int(can.get(&"charges")) == cap - 1 and plot.get_denied_reason(player) == "Already watered.", "watering a full plot is denied")

	# --- refill at the well
	_stand_at(player, well)
	_check(well.get_prompt(player) == "Fill can (%d/%d)" % [cap - 1, cap] and well.can_interact(player),
		"well prompt with a part-empty can", well.get_prompt(player))
	well.interact(player)
	await _frames(3)
	_check(int(can.get(&"charges")) == cap and well.get_denied_reason(player) == "Can's full.", "interact() at the well refills the can")

	# --- grow during a round
	GameState.server_start_round()
	await _frames(2)
	_check(GameState.is_playing(), "round started (PLAYING)")
	var deadline := Time.get_ticks_msec() + 15000
	while plot.stage != GrowPlot.Stage.READY and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(plot.stage == GrowPlot.Stage.READY, "plant grows to READY on the host's tick (growth x%d)" % int(GROWTH_OVERRIDE))
	var water_at_ready := plot.water
	await _frames(20)
	_check(plot.water == water_at_ready and plot.stage == GrowPlot.Stage.READY, "READY plant stops drinking")

	# --- harvest
	_stand_at(player, plot)
	_check(not plot.can_interact(player) and plot.get_denied_reason(player) == "Hands full.", "harvest denied while holding the can")
	items.server_drop_item(can, player.global_position + Vector3(0.0, 0.0, 0.8))
	await _frames(2)
	_check(plot.get_prompt(player) == "Harvest Budget Bud x1", "empty hands at READY: 'Harvest Budget Bud x1'", plot.get_prompt(player))
	plot.interact(player)
	await _frames(3)
	var product := player.get_held_item()
	_check(product != null and product.item_type == Const.ITEM_PRODUCT and StringName(product.get(&"strain_id")) == &"budget"
		and int(product.get(&"amount")) == Config.balance.get_seed(&"budget").yield_amount,
		"harvest puts a Budget Bud product (amount = yield) in the player's hands")
	_check(plot.stage == GrowPlot.Stage.EMPTY and plot.strain_id == &"", "plot is EMPTY after the harvest")

	# --- full game reset: plots cleared, cans back at the well
	plot2.server_plant(&"purple")
	plot2.water = 0.7
	items.server_despawn_item(product)
	await _frames(2)
	items.server_give_item(can, player.peer_id)
	can.set(&"charges", 1)
	await _frames(2)
	GameState.server_reset_game()
	await _frames(6)
	_check(plot2.stage == GrowPlot.Stage.EMPTY and plot2.water == 0.0 and plot2.strain_id == &"", "GameState.game_reset clears the grow plots")
	cans = _cans(items)
	var reset_ok := cans.size() == Config.balance.starting_watering_cans
	for c in cans:
		var near := false
		for s in spots:
			near = near or c.global_position.distance_to(s.global_position) < 0.05
		reset_ok = reset_ok and near and not c.is_held() and int(c.get(&"charges")) == GameState.get_can_capacity()
	_check(reset_ok, "GameState.game_reset puts every watering can back at the well, full", "%d cans" % cans.size())
	_finish()

func _cans(items: ItemManager) -> Array[Item]:
	var out: Array[Item] = []
	for it in items.get_items():
		if it.item_type == Const.ITEM_WATERING_CAN and not it.is_queued_for_deletion():
			out.append(it)
	return out

## Puts the player 1.6 m in front of a station (fronts face local +Z).
func _stand_at(player: Player, station: Node3D) -> void:
	player.global_position = station.global_position + station.global_basis.z * 1.6 + Vector3.UP * 0.05
	player.velocity = Vector3.ZERO

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _finish() -> void:
	print("farm_world_test: %d passed, %d failed" % [_passed, _failed])
	print("FARM WORLD TEST " + ("OK" if _failed == 0 else "FAILED"))
	Config.growth_speed_override = 1.0
	# Tear the session down the normal way before quitting (quitting with a live world is noisier).
	if Game.world != null:
		Game.return_to_menu()
	await get_tree().create_timer(1.0).timeout
	finished.emit(_failed)

func _check(cond: bool, what: String, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: " + what)
	else:
		_failed += 1
		print("FAIL: " + what + ("   [" + detail + "]" if detail != "" else ""))
