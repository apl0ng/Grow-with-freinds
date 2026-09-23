extends "res://tools/tests/smoke_base.gd"
## Client side of the two-process smoke test (see tools/smoke.sh). Pairs with smoke_host.gd.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/smoke_client.gd --port=7802

func _run() -> void:
	_label = "client"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	var port := port_arg(7802)

	step("joining 127.0.0.1:%d" % port)
	Game.start_join("127.0.0.1", port, "Client")
	await wait_until(func(): return Game.world != null and Game.local_player != null, 30.0, "world + local player")
	if Game.world == null or Game.local_player == null:
		finish(); return
	var world: World = Game.world
	var player: Player = Game.local_player
	var my_id: int = multiplayer.get_unique_id()
	check(not Net.is_host and my_id != 1, "not host (id %d)" % my_id)
	check(player.is_multiplayer_authority(), "authority over own player")
	await wait_until(func(): return Net.players.size() == 2, 10.0, "players dict has 2 entries")
	await wait_until(func(): return world.get_player(1) != null, 10.0, "host Player node visible")
	check(GameState.money == b.starting_money, "money synced (%d)" % GameState.money)
	await wait_until(func(): return world.items.get_items().size() >= b.starting_watering_cans, 10.0, "starting cans replicated")

	await wait_until(func(): return GameState.is_playing(), 20.0, "PLAYING synced")

	step("buy purple seed via RPC")
	var shop: ShopCounter = station("ShopCounter")
	var purple: SeedDef = b.get_seed(&"purple")
	teleport(player, shop)
	await wait_sec(0.4) # let the position replicate before the server distance check
	shop._rpc_request_buy_seed.rpc_id(1, &"purple")
	await wait_until(func():
		var it := player.get_held_item()
		return it is SeedPacket and it.strain_id == &"purple", 10.0, "holding purple seed packet")
	await wait_until(func(): return GameState.money == b.starting_money - purple.cost, 5.0, "money synced after purchase")

	step("drop it")
	world.items.request_drop()
	await wait_until(func(): return player.get_held_item() == null, 5.0, "hands empty after drop")

	step("observe host farming")
	var plot: GrowPlot = station("GrowPlot1")
	await wait_until(func(): return plot.stage == GrowPlot.Stage.SEEDLING, 30.0, "saw SEEDLING")
	await wait_until(func(): return find_item(Const.ITEM_WATERING_CAN, 1) != null, 30.0, "saw host holding a can")
	await wait_until(func(): return plot.water >= 0.9, 30.0, "saw plot watered")
	await wait_until(func(): return plot.stage == GrowPlot.Stage.READY, 90.0, "saw READY")
	await wait_until(func(): return plot.stage == GrowPlot.Stage.EMPTY, 30.0, "saw harvest (EMPTY)")
	await wait_until(func(): return GameState.round_sales > 0, 30.0, "saw round_sales > 0 (%d)" % GameState.round_sales)
	var host_p: Player = world.get_player(1)
	check(host_p != null and host_p.global_position.distance_to(Vector3.ZERO) > 0.5, "host position replicated (not at origin)")

	step("leave")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null, "world freed")
	finish()
