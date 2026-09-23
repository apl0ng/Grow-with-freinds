extends "res://tools/tests/smoke_base.gd"
## Host side of the two-process smoke test (see tools/smoke.sh). Pairs with smoke_client.gd.
##   godot --headless --path . -s res://tools/tests/smoke_host.gd -- --port=7802

func _run() -> void:
	_label = "host"
	await process_frame
	Config.growth_speed_override = 40.0
	var b: BalanceConfig = Config.balance
	var port := port_arg(7802)

	step("hosting on %d" % port)
	Game.start_host("Host", port)
	await wait_until(func(): return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		finish(); return
	var world: World = Game.world
	var player: Player = Game.local_player

	step("waiting for client")
	await wait_until(func(): return Net.players.size() == 2, 40.0, "client registered")
	var client_id: int = 0
	for id in Net.players:
		if id != 1:
			client_id = id
	check(client_id != 0, "client id known (%d)" % client_id)
	await wait_until(func(): return world.get_player(client_id) != null, 10.0, "client Player node spawned on host")
	check(Net.get_player_name(client_id) == "Client", "client name synced")

	step("start round")
	GameState.request_start_round()
	await wait_until(func(): return GameState.is_playing(), 2.0, "PLAYING")

	step("waiting for client purchase (purple seed via RPC)")
	var purple: SeedDef = b.get_seed(&"purple")
	await wait_until(func():
		var it := find_item(Const.ITEM_SEED_PACKET, client_id)
		return it != null and it.strain_id == &"purple", 30.0, "client holds a purple seed packet")
	check(GameState.money == b.starting_money - purple.cost, "money deducted for the client's purchase")
	await wait_until(func():
		var it := find_item(Const.ITEM_SEED_PACKET)
		return it != null and it.holder_id == 0, 20.0, "client dropped the packet")

	step("host runs the farm loop")
	var shop: ShopCounter = station("ShopCounter")
	var well: Well = station("Well")
	var turnin: TurnInStation = station("TurnInStation")
	var plot: GrowPlot = station("GrowPlot1")
	var seed: SeedDef = b.get_seed(&"budget")
	teleport(player, shop); await wait_frames(2)
	var res: Dictionary = shop.server_buy_seed(1, &"budget")
	check(bool(res.get("ok", false)), "host bought budget seed")
	await wait_frames(2)
	teleport(player, plot); await wait_frames(2)
	plot.interact(player); await wait_frames(2)
	check(plot.stage == GrowPlot.Stage.SEEDLING, "planted")
	var can: WateringCan = find_item(Const.ITEM_WATERING_CAN, 0)
	check(can != null, "free can")
	if can == null:
		finish(); return
	teleport(player, can, 0.5); await wait_frames(2)
	can.interact(player); await wait_frames(2)
	check(can.holder_id == 1, "host holds can")
	teleport(player, plot); await wait_frames(2)
	plot.interact(player); await wait_frames(2)
	check(plot.water >= 0.99, "watered")
	await wait_until(func(): return plot.stage == GrowPlot.Stage.READY, 90.0, "READY")
	world.items.request_drop(); await wait_frames(3)
	plot.interact(player); await wait_frames(2)
	check(player.get_held_item() is Product, "harvested")
	teleport(player, turnin); await wait_frames(2)
	var expected: int = int(round(seed.yield_amount * seed.sale_value_per_unit * GameState.get_sale_multiplier()))
	var money_before: int = GameState.money
	turnin.interact(player); await wait_frames(3)
	check(GameState.money == money_before + expected, "sold (+%d)" % expected)

	step("waiting for client to leave")
	await wait_until(func(): return Net.players.size() == 1, 60.0, "client left")
	await wait_until(func(): return world.get_player(client_id) == null, 5.0, "client Player despawned")
	check(find_item(Const.ITEM_SEED_PACKET, client_id) == null, "nothing still held by the client")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null, "world freed")
	finish()
