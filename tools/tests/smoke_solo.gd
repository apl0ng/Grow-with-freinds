extends "res://tools/tests/smoke_base.gd"
## Solo end-to-end loop on a single headless host: host -> start round -> buy -> plant -> can -> water ->
## refill -> grow -> drop -> harvest -> sell -> upgrade -> quota met -> next round -> fail -> retry -> menu.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/smoke_solo.gd --port=7801

func _run() -> void:
	_label = "solo"
	await get_tree().process_frame
	Config.growth_speed_override = 40.0
	var b: BalanceConfig = Config.balance

	step("hosting")
	Game.start_host("Tester", port_arg(7801))
	await wait_until(func(): return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null or Game.local_player == null:
		finish(); return
	check(Net.is_host, "Net.is_host")
	check(GameState.phase == GameState.Phase.WAITING, "phase WAITING after host")
	check(GameState.money == b.starting_money, "starting money = %d" % b.starting_money)
	check(GameState.quota == b.quota_for_round(1), "quota for round 1")
	var world: World = Game.world
	var player: Player = Game.local_player
	check(player.peer_id == 1 and player.is_local(), "local player is peer 1")
	check(world.get_players().size() == 1, "one player node")

	var shop: ShopCounter = station("ShopCounter")
	var well: Well = station("Well")
	var turnin: TurnInStation = station("TurnInStation")
	var plot: GrowPlot = station("GrowPlot1")
	check(shop != null and well != null and turnin != null and plot != null, "all stations found")
	if shop == null or well == null or turnin == null or plot == null:
		finish(); return

	await wait_until(func(): return world.items.get_items().size() >= b.starting_watering_cans, 3.0, "starting watering cans spawned")

	step("start round")
	GameState.request_start_round()
	await wait_until(func(): return GameState.is_playing(), 2.0, "phase PLAYING")

	step("buy seed")
	var seed: SeedDef = b.get_seed(&"budget")
	teleport(player, shop)
	await wait_frames(2)
	var res: Dictionary = shop.server_buy_seed(1, &"budget")
	check(bool(res.get("ok", false)), "server_buy_seed ok (%s)" % str(res))
	await wait_frames(2)
	var held: Item = player.get_held_item()
	check(held is SeedPacket and held.strain_id == &"budget", "holding budget seed packet")
	check(GameState.money == b.starting_money - seed.cost, "money deducted by seed cost")
	var res2: Dictionary = shop.server_buy_seed(1, &"budget")
	check(not bool(res2.get("ok", true)), "second purchase denied while hands full")

	step("plant")
	teleport(player, plot)
	await wait_frames(2)
	plot.interact(player)
	await wait_frames(2)
	check(plot.stage == GrowPlot.Stage.SEEDLING, "plot is SEEDLING")
	check(plot.strain_id == &"budget", "plot strain budget")
	check(player.get_held_item() == null, "seed packet consumed")

	step("pick up can")
	var can: WateringCan = find_item(Const.ITEM_WATERING_CAN, 0)
	check(can != null, "a free watering can exists")
	if can == null:
		finish(); return
	teleport(player, can, 0.5)
	await wait_frames(2)
	can.interact(player)
	await wait_frames(2)
	check(player.get_held_item() == can, "holding the can")
	check(can.holder_id == 1, "can.holder_id == 1")
	check(can.charges == can.get_capacity(), "can starts full")

	step("water")
	teleport(player, plot)
	await wait_frames(2)
	var charges_before: int = can.charges
	plot.interact(player)
	await wait_frames(2)
	check(plot.water >= 0.99, "plot watered (water=%.2f)" % plot.water)
	check(can.charges == charges_before - 1, "one charge used")
	plot.interact(player)
	await wait_frames(2)
	check(can.charges == charges_before - 1, "watering a full plot is denied (no charge used)")

	step("refill at well")
	teleport(player, well)
	await wait_frames(2)
	well.interact(player)
	await wait_frames(2)
	check(can.charges == can.get_capacity(), "can refilled")

	step("grow (override x%.0f)" % Config.growth_speed_override)
	var t0 := Time.get_ticks_msec()
	await wait_until(func(): return plot.stage >= GrowPlot.Stage.VEGETATIVE, 30.0, "reached VEGETATIVE")
	await wait_until(func(): return plot.stage == GrowPlot.Stage.READY, 60.0, "reached READY")
	var grow_sec := (Time.get_ticks_msec() - t0) / 1000.0
	var expected_sec := Config.balance.total_grow_time(seed) / GameState.get_growth_speed_multiplier()
	check(abs(grow_sec - expected_sec) < max(1.0, expected_sec * 0.5), "grow time %.2fs ~ expected %.2fs" % [grow_sec, expected_sec])

	step("drop can + harvest")
	teleport(player, plot)
	await wait_frames(2)
	world.items.request_drop()
	await wait_frames(3)
	check(player.get_held_item() == null, "can dropped")
	check(can.holder_id == 0, "can on the floor")
	plot.interact(player)
	await wait_frames(2)
	var product: Item = player.get_held_item()
	check(product is Product, "holding product")
	if product is Product:
		check(product.amount == seed.yield_amount and product.strain_id == &"budget", "product amount/strain")
	check(plot.stage == GrowPlot.Stage.EMPTY, "plot EMPTY after harvest")

	step("sell")
	teleport(player, turnin)
	await wait_frames(2)
	var money_before: int = GameState.money
	var expected: int = int(round(seed.yield_amount * seed.sale_value_per_unit * GameState.get_sale_multiplier()))
	turnin.interact(player)
	await wait_frames(3)
	check(GameState.money == money_before + expected, "money +%d (now %d)" % [expected, GameState.money])
	check(GameState.round_sales == expected, "round_sales == %d" % expected)
	check(player.get_held_item() == null, "hands empty after selling")
	check(find_item(Const.ITEM_PRODUCT) == null, "product despawned")

	step("upgrade")
	teleport(player, shop)
	await wait_frames(2)
	GameState.server_add_money(10000)
	var cap_before: int = GameState.get_can_capacity()
	var far: Dictionary = shop.server_buy_upgrade(1, &"big_can")
	check(bool(far.get("ok", false)), "upgrade purchase in range ok")
	if not bool(far.get("ok", false)):
		print("    -> ", far)
	var up: Dictionary = {"ok": bool(far.get("ok", false))}
	check(bool(up.get("ok", false)), "bought big_can (%s)" % str(up))
	check(GameState.get_upgrade_level(&"big_can") == 1, "big_can level 1")
	check(GameState.get_can_capacity() == cap_before + 2, "can capacity +2")

	step("quota met -> next round")
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "ROUND_SUCCESS when sales reach quota")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.round_number == 2 and GameState.is_playing(), "round 2 PLAYING")
	check(GameState.quota == b.quota_for_round(2), "quota scaled for round 2")
	check(GameState.round_sales == 0, "round sales reset")

	step("timer runs out -> fail -> retry")
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "ROUND_FAILED at 0:00")
	GameState.request_retry()
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "retry -> WAITING round 1")
	check(GameState.money == b.starting_money, "money reset on retry")

	step("return to menu")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null, "world freed")
	check(GameState.phase == GameState.Phase.MENU, "phase MENU")
	check(not Net.is_online(), "offline")
	finish()
