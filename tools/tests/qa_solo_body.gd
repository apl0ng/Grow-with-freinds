extends "res://tools/tests/qa_base.gd"
## Solo play verification (QA milestone 7). One process, real input path wherever possible:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/qa_solo_body.gd --port=7972 --fast
## (--fast = growth 20x, 60 s rounds, exactly what a player gets with the CLI flag.)
##   Cycle 1: main menu Host -> Enter starts the round -> for every plot: E on the shop, BUY in the ShopUI, Esc,
##            E on the plot (plant) -> E on a can (pick up) -> E on plots (water) -> E on the well (refill) ->
##            Q (drop) -> E on READY plots (harvest) -> E on the bin (sell) ... until the round-1 quota is met by
##            real sales -> NEXT ROUND button -> pause menu LEAVE -> menu
##   Cycle 2: menu Host again -> fresh session (no leaked money/round/items/players) -> plant -> timer runs out ->
##            RETRY button -> fresh round 1 -> MAIN MENU button
##   Cycle 3: menu Host again -> fresh session -> menu
## Every interaction goes through the local Player's Interactor ray (so every station must be reachable from its
## front) and the E / Q / Enter / Esc key events; money only comes from real sales.

var me: Player
var hud: HUD
var interactor: Interactor
var sold_units: int = 0

func _run() -> void:
	_label = "solo"
	await get_tree().process_frame
	check(Config.has_arg("fast") and Config.growth_speed_override == 20.0 and Config.balance.round_length_sec == 60.0,
			"--fast active: growth x20, 60 s rounds")
	# A -s launcher does not load the main scene: boot the real main menu like the game does.
	get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
	await wait_frames(2)
	for cycle in [1, 2, 3]:
		step("cycle %d: host from the main menu" % cycle)
		if not await _host_from_menu():
			finish(); return
		_check_fresh_session("cycle %d" % cycle)
		match cycle:
			1: await _play_full_round()
			2: await _fail_and_retry()
			3: pass
		if cycle != 1:
			step("cycle %d: back to the menu" % cycle)
			if cycle == 2 and check(hud.round_end.is_open(), "round-end overlay open (MAIN MENU button)"):
				hud.round_end.menu_button.pressed.emit()
			else:
				Game.return_to_menu()
			await wait_frames(3)
			_check_menu("cycle %d" % cycle)
	finish()

# --- session helpers -----------------------------------------------------------------------------------------

func _host_from_menu() -> bool:
	var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	if not check(menu != null, "main menu present"):
		return false
	menu.get("port_spin").value = port_arg(7972)
	menu.get("name_edit").text = "Solo"
	menu.call("_begin_host", false) # the Host button's path, without saving user://settings.cfg
	if not await wait_until(func(): return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 5.0, "world + player + cans"):
		return false
	me = Game.local_player
	hud = Game.world.get_node("HUD") as HUD
	interactor = me.get_interactor()
	await wait_frames(3)
	return true

func _check_fresh_session(tag: String) -> void:
	var b := Config.balance
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "%s: WAITING, round 1" % tag)
	check(GameState.money == b.starting_money and GameState.round_sales == 0 and GameState.quota == b.quota_for_round(1),
			"%s: $%d, sold 0, quota %d" % [tag, b.starting_money, b.quota_for_round(1)])
	check(GameState.upgrades.is_empty(), "%s: no upgrades" % tag)
	check(Net.players.size() == 1 and Game.world.get_players().size() == 1, "%s: one player" % tag)
	check(Game.world.items.get_items().size() == 2 and items_of(Const.ITEM_WATERING_CAN).size() == 2, "%s: exactly the 2 starting cans" % tag)
	var empty := true
	for i in range(1, 7):
		empty = empty and plot(i).is_empty()
	check(empty, "%s: every plot empty" % tag)
	check(not Game.is_ui_locked(), "%s: no UI lock" % tag)
	check(hud.money_label.text == HUD.format_money(b.starting_money) and hud.round_label.text == "ROUND 1", "%s: HUD shows $%d / ROUND 1" % [tag, b.starting_money])

func _check_menu(tag: String) -> void:
	check(Game.world == null and GameState.phase == GameState.Phase.MENU and GameState.money == 0, "%s: menu, GameState reset" % tag)
	check(Net.players.is_empty() and not Net.is_online() and not Game.is_ui_locked(), "%s: offline, no locks" % tag)
	var stray := []
	for c in get_tree().root.get_children():
		if (c is ShopUI or c is CanvasLayer) and not c.is_queued_for_deletion():
			stray.append(str(c.name))
	check(stray.is_empty(), "%s: no stray UI %s" % [tag, stray])

# --- input helpers -------------------------------------------------------------------------------------------

func _key(code: Key) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		get_viewport().push_input(ev)

## Stands `distance` m in front of `spot_node` (its +Z side for stations), looks at `aim` and waits until the
## Interactor's ray targets `want`. Returns false (with a FAIL) if the ray does not reach it.
func _aim(want: Interactable, aim: Vector3, stand: Vector3) -> bool:
	me.velocity = Vector3.ZERO
	me.global_position = stand
	me.look_at(Vector3(aim.x, stand.y, aim.z), Vector3.UP)
	var cam := me.get_node("%Camera") as Camera3D
	await get_tree().physics_frame
	var eye := cam.global_position
	var flat := Vector2(aim.x - eye.x, aim.z - eye.z).length()
	me.head.rotation.x = atan2(aim.y - eye.y, flat)
	for i in 4:
		await get_tree().physics_frame
	interactor.refresh()
	if interactor.current_target != want:
		check(false, "ray reaches %s (got %s)" % [want.name, interactor.current_target.name if interactor.current_target else "nothing"])
		return false
	return true

## E on a station through the ray, standing at its access point.
func _use_station(st: Interactable, aim_height: float = 0.6, distance: float = 1.3) -> bool:
	var spot: Vector3 = Game.world.room.get_station_access_point(String(st.name), distance)
	if not await _aim(st, st.global_position + Vector3.UP * aim_height, spot):
		return false
	_key(KEY_E)
	await wait_frames(2)
	return true

func _use_item(it: Item) -> bool:
	var toward := Vector3(it.global_position.x, 0.0, it.global_position.z)
	var away := Vector3(0.0, 0.0, 0.0) - toward
	away.y = 0.0
	var stand := toward + (away.normalized() if away.length() > 0.1 else Vector3.BACK) * 0.9
	if not await _aim(it, it.global_position + Vector3.UP * 0.1, stand):
		return false
	_key(KEY_E)
	await wait_frames(2)
	return true

func _buy_via_ui(seed_id: StringName) -> bool:
	var shop: ShopCounter = station("ShopCounter")
	if not await _use_station(shop, 0.9, 1.5):
		return false
	var ui := shop.get_shop_ui()
	if not check(ui != null and ui.is_open(), "shop UI opened with E"):
		return false
	var card := ui.get_card(ShopCounter.KIND_SEED, seed_id)
	if not card.is_buy_enabled():
		check(false, "BUY %s enabled ($%d)" % [seed_id, GameState.money])
		_key(KEY_ESCAPE)
		return false
	card.get_buy_button().pressed.emit()
	await wait_frames(2)
	_key(KEY_ESCAPE)
	await wait_frames(2)
	return me.get_held_item() is SeedPacket and not ui.is_open()

# --- cycle 1: a full round by real play ------------------------------------------------------------------------

func _play_full_round() -> void:
	step("cycle 1: Enter starts the round")
	_key(KEY_ENTER)
	await wait_frames(2)
	check(GameState.is_playing(), "round 1 PLAYING (Enter)")
	var well: Well = station("Well")
	var turnin: TurnInStation = station("TurnInStation")
	var quota := GameState.quota
	var guard := 0
	while GameState.phase == GameState.Phase.PLAYING and guard < 4:
		guard += 1
		step("cycle 1: batch %d (money $%d, sold $%d / $%d)" % [guard, GameState.money, GameState.round_sales, quota])
		# Buy + plant as many Budget Bud as money and empty plots allow.
		var planted: Array[GrowPlot] = []
		for i in range(1, 7):
			var p := plot(i)
			if not p.is_empty() or GameState.money < 20:
				continue
			if not check(await _buy_via_ui(&"budget"), "bought a Budget Bud packet via the shop UI"):
				return
			if not await _use_station(p, 0.3, 1.3):
				return
			check(p.stage == GrowPlot.Stage.SEEDLING and me.get_held_item() == null, "planted plot %d" % i)
			planted.append(p)
		if planted.is_empty():
			check(false, "could plant something (money $%d)" % GameState.money)
			return
		# Water them with a can, refilling at the well when it runs dry.
		var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
		if not await _use_item(can) or not check(me.get_held_item() == can, "picked up the watering can (E)"):
			return
		for p in planted:
			if int(can.get(&"charges")) <= 0:
				await _use_station(well, 0.6, 1.4)
				check(int(can.get(&"charges")) == (can as WateringCan).get_capacity(), "refilled at the well (E)")
			await _use_station(p, 0.3, 1.3)
			check(p.water > 0.9, "watered plot %s" % p.name)
		_key(KEY_Q)
		await wait_frames(2)
		check(me.get_held_item() == null, "dropped the can (Q)")
		# Grow, harvest one at a time and sell.
		for p in planted:
			await wait_until(func(): return p.is_ready_to_harvest(), 15.0, "%s READY" % p.name)
			if not await _use_station(p, 0.3, 1.3):
				return
			if not check(me.get_held_item() is Product, "harvested %s (E)" % p.name):
				return
			var before := GameState.round_sales
			if not await _use_station(turnin, 0.8, 1.3):
				return
			check(GameState.round_sales == before + 60, "sold at the bin (+$60, sold $%d)" % GameState.round_sales)
			sold_units += 1
			if GameState.phase != GameState.Phase.PLAYING:
				break
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "quota $%d met solo by real sales ($%d from %d harvests, %.0f s left)" % [quota, GameState.round_sales, sold_units, GameState.time_left])
	check(hud.round_end.is_open() and hud.round_end.primary_button.visible and hud.round_end.primary_button.text == "NEXT ROUND", "round-end overlay offers NEXT ROUND to the solo host")
	hud.round_end.primary_button.pressed.emit()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 2 and GameState.quota == Config.balance.quota_for_round(2), "round 2 PLAYING, quota %d" % Config.balance.quota_for_round(2))
	check(not hud.round_end.is_open() and not Game.is_ui_locked(), "overlay closed, input unlocked")
	step("cycle 1: pause menu -> Leave")
	_key(KEY_ESCAPE)
	await wait_frames(2)
	check(hud.pause_menu.is_open(), "Esc opens the pause menu")
	hud.pause_menu.leave_button.pressed.emit()
	await wait_frames(3)
	_check_menu("cycle 1")

# --- cycle 2: plant, fail, retry -------------------------------------------------------------------------------

func _fail_and_retry() -> void:
	_key(KEY_ENTER)
	await wait_frames(2)
	check(GameState.is_playing(), "round started")
	check(await _buy_via_ui(&"purple"), "bought Purple Haze")
	await _use_station(plot(3), 0.3, 1.3)
	check(plot(3).stage == GrowPlot.Stage.SEEDLING, "planted plot 3")
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[1]
	await _use_item(can)
	check(me.get_held_item() == can, "holding a can when time runs out")
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "ROUND_FAILED at 0:00")
	check(hud.round_end.is_open() and hud.round_end.primary_button.text == "RETRY", "overlay offers RETRY")
	hud.round_end.primary_button.pressed.emit()
	await wait_frames(6)
	_check_fresh_session("after RETRY")
	var well: Well = station("Well")
	var home := true
	for c in items_of(Const.ITEM_WATERING_CAN):
		var near := false
		for k in 2:
			near = near or c.global_position.distance_to(well.get_can_spot_position(k)) < 0.05
		home = home and near and not c.is_held()
	check(home, "after RETRY: cans back at the well (the held one too)")
	GameState.request_start_round()
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "failed again (to leave via MAIN MENU)")
