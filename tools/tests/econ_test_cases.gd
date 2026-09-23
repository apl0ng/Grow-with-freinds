extends Node
## Economy test runner, loaded at runtime by tools/tests/econ_test.gd (so autoloads exist when this compiles).
##
## Part 1 - standalone (no world, offline peer):
##   scene structure + colliders, data-driven decorations, prompts / denial reasons, the sell formula for every
##   seed at multiplier 1.0 (computed from data/balance.tres), server validation without a world
##   ("Player not found"), ShopUI open / close (Esc, E after a grace period, Close button, walking away,
##   counter freed), UI lock via Game.is_ui_locked_by(&"shop"), Tab switching, remote players never get a UI,
##   and the client -> server -> client result round trip (toast + feedback line).
## Part 2 - solo host session (Game.start_host on a random port, real World / ItemManager / GameState):
##   unknown seed, too far, successful purchase (packet in hands, money spent), hands full, not enough money,
##   upgrades (unknown, level ups, max level), purchases through the ShopUI buttons, Escape closing the shop
##   without opening the pause menu, selling (denials, WAITING gate, value with Sweet Talk, sales/money/label),
##   the double-sell guard, and the shop closing when the quota ends the round.

signal finished(failures: int)

const COUNTER_SCENE := "res://scenes/stations/shop_counter.tscn"
const TURN_IN_SCENE := "res://scenes/stations/turn_in_station.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const BALANCE_PATH := "res://data/balance.tres"

var _passes := 0
var _failures := 0
var _skips := 0
var _toasts: Array[Array] = []   # [text, kind]


func run() -> void:
	Game.toast_requested.connect(_on_toast)
	await _part1_standalone()
	if "--econ-part1-only" in OS.get_cmdline_user_args():
		_skip("part 2 (solo host session)", "--econ-part1-only")
	else:
		await _part2_solo_host()
	print("econ_test: %d passed, %d failed, %d skipped" % [_passes, _failures, _skips])
	finished.emit(_failures)


# =====================================================================================================================
# Part 1: standalone
# =====================================================================================================================

func _part1_standalone() -> void:
	print("== Part 1: standalone scenes (no world, offline peer)")
	_check(Game.world == null, "part 1 runs without a world")
	var counter := (load(COUNTER_SCENE) as PackedScene).instantiate() as ShopCounter
	var turn_in := (load(TURN_IN_SCENE) as PackedScene).instantiate() as TurnInStation
	_check(counter != null, "shop_counter.tscn root is a ShopCounter")
	_check(turn_in != null, "turn_in_station.tscn root is a TurnInStation")
	if counter == null or turn_in == null:
		return
	add_child(counter)
	add_child(turn_in)
	turn_in.position = Vector3(10.0, 0.0, 0.0)
	await _frames(1)

	_check_structure(counter, turn_in)
	_check_sell_formula()
	_check_turn_in_standalone(turn_in)
	_check_validation_without_world(counter)
	await _check_shop_ui(counter)

	turn_in.queue_free()
	await _frames(2)


func _check_structure(counter: ShopCounter, turn_in: TurnInStation) -> void:
	for station: Node3D in [counter, turn_in]:
		var body := station.get_node_or_null(^"Body") as StaticBody3D
		_check(body != null, "%s has a StaticBody3D 'Body'" % station.name)
		if body == null:
			continue
		_check(body.collision_layer == (Const.LAYER_WORLD | Const.LAYER_INTERACTABLE) and body.collision_mask == 0,
				"%s collider layer 5 / mask 0" % station.name, "layer %d mask %d" % [body.collision_layer, body.collision_mask])
		var shapes := body.find_children("*", "CollisionShape3D", false, false)
		_check(not shapes.is_empty(), "%s collider has shapes" % station.name)
	_check(counter.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") != null, "shopkeeper NPC instanced behind the counter")
	var anchor := counter.get_node_or_null(^"ShopkeeperAnchor") as Node3D
	if anchor != null:
		var facing := anchor.global_basis * Vector3.FORWARD   # NPC scene faces -Z
		_check(facing.z > 0.99 and anchor.position.z < -0.5, "shopkeeper stands behind the counter facing +Z (customer)")
	# Jars / badges are tinted and priced from balance.tres
	var seeds: Array[SeedDef] = Config.balance.seeds
	for i in mini(seeds.size(), 3):
		var fill := counter.get_node_or_null("Visual/Jars/Jar%d/Fill" % (i + 1)) as MeshInstance3D
		var tag := counter.get_node_or_null("Visual/Jars/Jar%d/PriceTag" % (i + 1)) as Label3D
		var mat := fill.material_override as StandardMaterial3D if fill != null else null
		_check(mat != null and mat.albedo_color.is_equal_approx(seeds[i].color), "jar %d tinted %s" % [i + 1, seeds[i].id])
		_check(tag != null and tag.text == "$%d" % seeds[i].cost, "jar %d price tag $%d" % [i + 1, seeds[i].cost],
				tag.text if tag != null else "missing")
	# Interaction contract
	_check(counter.can_interact(null) and counter.get_prompt(null) == "Browse seeds & upgrades",
			"counter prompt 'Browse seeds & upgrades', always interactable")


func _check_sell_formula() -> void:
	var data := ResourceLoader.load(BALANCE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as BalanceConfig
	_check(data != null and not data.seeds.is_empty(), "data/balance.tres loads with seeds")
	if data == null:
		return
	_check(is_equal_approx(GameState.get_sale_multiplier(), 1.0), "sale multiplier is 1.0 without upgrades")
	for seed_def: SeedDef in data.seeds:
		var expected := int(round(seed_def.yield_amount * seed_def.sale_value_per_unit * 1.0))
		var live := Config.balance.get_seed(seed_def.id)
		var got := TurnInStation.compute_sale_value(live, seed_def.yield_amount, 1.0)
		_check(got == expected, "sell value %s x%d at 1.0 = $%d" % [seed_def.id, seed_def.yield_amount, expected],
				"got $%d" % got)
	var purple := Config.balance.get_seed(&"purple")
	if purple != null:
		_check(TurnInStation.compute_sale_value(purple, 1, 1.1) == int(round(purple.sale_value_per_unit * 1.1)),
				"sell value applies the multiplier (purple x1 at 1.1)")
	_check(TurnInStation.compute_sale_value(null, 3, 1.0) == 0, "unknown strain sells for $0")
	if purple != null:
		_check(TurnInStation.compute_sale_value(purple, 0, 1.0) == 0, "empty stack sells for $0")


func _check_turn_in_standalone(turn_in: TurnInStation) -> void:
	_check(not turn_in.can_interact(null) and turn_in.get_denied_reason(null) == "Nothing to sell",
			"turn-in with empty hands: 'Nothing to sell'")
	_check(turn_in.get_prompt(null) == "Sell product", "turn-in generic prompt")
	_check(TurnInStation.get_sold_text(120, 400) == "Sold: $120 / $400", "sold label text")
	_check(TurnInStation.get_sold_text(0, 0) == "Sold: $0", "sold label text without quota")
	_check(TurnInStation.get_sold_text(450, 400).contains("QUOTA MET"), "sold label shows QUOTA MET")
	var label := turn_in.get_node_or_null(^"SoldLabel") as Label3D
	_check(label != null and label.text == TurnInStation.get_sold_text(GameState.round_sales, GameState.quota),
			"floating sold label initialised from GameState")


func _check_validation_without_world(counter: ShopCounter) -> void:
	var money_before := GameState.money
	_expect(counter.server_buy_seed(1, &"budget"), false, "Player not found", "buy seed without a player")
	_expect(counter.server_buy_seed(1, &"no_such_seed"), false, "Player not found", "player check comes first")
	_expect(counter.server_buy_seed(42, &"budget"), false, "Player not found", "buy seed for unknown peer")
	_expect(counter.server_buy_upgrade(1, &"fertilizer"), false, "Player not found", "buy upgrade without a player")
	_check(GameState.money == money_before, "failed purchases do not touch money")


func _check_shop_ui(counter: ShopCounter) -> void:
	var local := _make_player(1)
	var remote := _make_player(2)
	if local == null or remote == null:
		_skip("shop UI (standalone)", "player.tscn could not be instantiated")
		return
	local.global_position = counter.to_global(Vector3(0.0, 0.0, 1.6))
	remote.global_position = counter.to_global(Vector3(1.0, 0.0, 1.6))
	_check(local.is_local() and not remote.is_local(), "test players: 1 local, 2 remote")

	counter.open_shop_for(remote)
	counter.interact(remote)
	_check(not counter.is_shop_open(), "shop UI never opens for a remote player")

	counter.interact(local)   # what the Interactor calls on E
	var ui := counter.get_shop_ui()
	_check(ui != null and ui.is_open() and ui.visible, "interact() opens the shop UI locally (no server needed)")
	if ui == null:
		return
	_check(ui.get_parent() == get_tree().root, "shop UI lives under the viewport root")
	_check(Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE) and Game.is_ui_locked(), "opening sets Game ui lock 'shop'")
	_check(ui.get_cards(ShopCounter.KIND_SEED).size() == Config.balance.seeds.size(), "one card per seed")
	_check(ui.get_cards(ShopCounter.KIND_UPGRADE).size() == Config.balance.upgrades.size(), "one card per upgrade")
	_check(ui.get_money_text() == "$%d" % GameState.money, "wallet shows $money", ui.get_money_text())
	for seed_def: SeedDef in Config.balance.seeds:
		var card := ui.get_card(ShopCounter.KIND_SEED, seed_def.id)
		if card == null:
			_check(false, "card for seed %s" % seed_def.id)
			continue
		var grow := roundi(Config.balance.total_grow_time(seed_def) / GameState.get_growth_speed_multiplier())
		var sells := int(round(seed_def.yield_amount * seed_def.sale_value_per_unit * GameState.get_sale_multiplier()))
		var stats := card.get_stats_text()
		_check(stats.contains("~%d s" % grow) and stats.contains("Sells for $%d" % sells),
				"seed card %s: grows in ~%d s, sells for $%d" % [seed_def.id, grow, sells], stats)
		_check(card.is_buy_enabled() == (GameState.money >= seed_def.cost),
				"seed card %s BUY enabled only when affordable" % seed_def.id)
	for up_def: UpgradeDef in Config.balance.upgrades:
		var card := ui.get_card(ShopCounter.KIND_UPGRADE, up_def.id)
		var cost := up_def.cost_for_level(GameState.get_upgrade_level(up_def.id) + 1)
		_check(card != null and card.get_buy_button().text.contains("$%d" % cost)
				and card.is_buy_enabled() == (GameState.money >= cost),
				"upgrade card %s shows next cost $%d" % [up_def.id, cost])

	# Tab switching (Tab key)
	_check(ui.get_current_tab() == ShopUI.TAB_SEEDS, "shop opens on the SEEDS tab")
	_push_key(KEY_TAB)
	_check(ui.get_current_tab() == ShopUI.TAB_UPGRADES and ui.is_open(), "Tab switches to UPGRADES")
	_push_key(KEY_TAB)
	_check(ui.get_current_tab() == ShopUI.TAB_SEEDS, "Tab switches back to SEEDS")

	# E closes only after the grace period
	_push_key(KEY_E)
	_check(ui.is_open(), "E right after opening does not close the shop")
	await _wait_real_msec(ShopUI.E_CLOSE_GRACE_MSEC + 100)
	_push_key(KEY_E)
	_check(not ui.is_open() and not ui.visible, "E closes the shop")
	_check(not Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE), "closing releases the ui lock")

	# Esc (ui_cancel)
	counter.interact(local)
	var esc := InputEventAction.new()
	esc.action = &"ui_cancel"
	esc.pressed = true
	get_viewport().push_input(esc)
	_check(not ui.is_open() and not Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE), "Esc (ui_cancel) closes the shop")

	# Close button
	counter.interact(local)
	var close_button := ui.find_child("CloseButton", true, false) as Button
	_check(close_button != null, "close button exists")
	if close_button != null:
		close_button.pressed.emit()
		_check(not ui.is_open(), "Close button closes the shop")

	# Client -> server -> client round trip (no world: the server answers "Player not found")
	counter.interact(local)
	_toasts.clear()
	var budget := ui.get_card(ShopCounter.KIND_SEED, &"budget")
	if budget != null:
		budget.buy_pressed.emit(budget)
		_check(_toasts.size() == 1 and _toasts[0][0] == "Player not found" and _toasts[0][1] == &"error",
				"BUY -> RPC -> server reason comes back as an error toast", str(_toasts))
		_check(ui.get_feedback_text() == "Player not found", "server reason shown in the shop footer")
	_check(ui.is_open(), "failed purchase keeps the shop open")

	# Walking away closes it
	local.global_position = counter.to_global(Vector3(0.0, 0.0, 20.0))
	await _frames(2)
	_check(not ui.is_open() and not Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE), "walking away closes the shop")

	# Freeing the counter while open frees the UI and releases the lock
	local.global_position = counter.to_global(Vector3(0.0, 0.0, 1.6))
	counter.interact(local)
	_check(ui.is_open(), "shop re-opens")
	counter.queue_free()
	await _frames(2)
	_check(not is_instance_valid(ui), "shop UI is freed together with its counter")
	_check(not Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE), "ui lock released when the counter goes away")
	local.queue_free()
	remote.queue_free()
	await _frames(1)


# =====================================================================================================================
# Part 2: solo host session
# =====================================================================================================================

func _part2_solo_host() -> void:
	print("== Part 2: solo host session (Game.start_host)")
	var port := 21000 + randi() % 20000
	var err: Error = Game.start_host("EconTest", port)
	if err != OK:
		_check(false, "Game.start_host on port %d" % port, error_string(err))
		return
	for i in 180:
		if Game.world != null and Game.local_player != null and Game.local_player.is_node_ready():
			break
		await _frames(1)
	await _frames(3)
	var world := Game.world
	var player := Game.local_player
	_check(world != null and player != null, "solo host: world + local player spawned")
	if world == null or player == null:
		return
	var counter := world.get_node_or_null(^"Room/Stations/ShopCounter") as ShopCounter
	var turn_in := world.get_node_or_null(^"Room/Stations/TurnInStation") as TurnInStation
	var items := world.items
	_check(counter != null and turn_in != null and items != null, "room has ShopCounter + TurnInStation, world has items")
	if counter == null or turn_in == null or items == null:
		return
	_check(GameState.phase == GameState.Phase.WAITING and GameState.money == Config.balance.starting_money,
			"fresh session: WAITING with starting money $%d" % Config.balance.starting_money,
			"phase %s money %d" % [GameState.get_phase_name(), GameState.money])
	_clear_hands(player, items)

	await _part2_purchases(player, counter, items)
	await _part2_shop_ui(player, counter, items)
	await _part2_selling(player, counter, turn_in, items)

	var ui := counter.get_shop_ui()
	Game.return_to_menu()
	for i in 10:
		await _frames(1)
	_check(Game.world == null, "back to menu frees the world")
	_check(ui == null or not is_instance_valid(ui), "shop UI freed with the world")
	_check(not Game.is_ui_locked(), "no ui lock left after returning to the menu")


func _part2_purchases(player: Player, counter: ShopCounter, items: ItemManager) -> void:
	_place_near(player, counter)
	var golden := Config.balance.get_seed(&"golden")
	var budget := Config.balance.get_seed(&"budget")
	if golden == null or budget == null:
		_skip("purchase checks", "balance.tres has no golden/budget seed")
		return

	_expect(counter.server_buy_seed(1, &"no_such_seed"), false, "Unknown seed", "unknown seed is rejected")

	_place_at(player, counter.to_global(Vector3(0.0, 0.0, 30.0)))
	_expect(counter.server_buy_seed(1, &"budget"), false, "Too far away", "buying from far away is rejected")
	_place_near(player, counter)

	var money := GameState.money
	var result := counter.server_buy_seed(1, golden.id)
	_expect(result, true, "", "buy Golden Kush with $%d" % money)
	_check(GameState.money == money - golden.cost, "seed cost $%d was spent" % golden.cost, "money %d" % GameState.money)
	var held := player.get_held_item()
	_check(held != null and held.item_type == Const.ITEM_SEED_PACKET and held.get(&"strain_id") == golden.id,
			"seed packet spawned in the buyer's hands", str(held))

	money = GameState.money
	_expect(counter.server_buy_seed(1, budget.id), false, "Hands full — drop your item first", "hands full is rejected")
	_check(GameState.money == money, "rejected purchase costs nothing")

	_clear_hands(player, items)
	if GameState.money < golden.cost:
		_expect(counter.server_buy_seed(1, golden.id), false, "Not enough money", "not enough money is rejected")
		_check(GameState.money == money, "money unchanged after 'Not enough money'")
	else:
		_skip("not enough money", "wallet $%d still covers $%d" % [GameState.money, golden.cost])

	# Upgrades
	GameState.server_add_money(1000)
	_expect(counter.server_buy_upgrade(1, &"no_such_upgrade"), false, "Unknown upgrade", "unknown upgrade is rejected")
	var cans := Config.balance.get_upgrade(&"big_can")
	if cans == null:
		_skip("upgrade level-ups", "balance.tres has no big_can upgrade")
		return
	for level in range(1, cans.max_level + 1):
		money = GameState.money
		var cost := cans.cost_for_level(level)
		_expect(counter.server_buy_upgrade(1, cans.id), true, "", "buy %s level %d" % [cans.id, level])
		_check(GameState.get_upgrade_level(cans.id) == level and GameState.money == money - cost,
				"%s is level %d and cost $%d" % [cans.id, level, cost],
				"level %d money %d" % [GameState.get_upgrade_level(cans.id), GameState.money])
	money = GameState.money
	_expect(counter.server_buy_upgrade(1, cans.id), false, "Already at max level", "maxed upgrade is rejected")
	_check(GameState.money == money, "maxed upgrade costs nothing")
	_place_at(player, counter.to_global(Vector3(0.0, 0.0, 30.0)))
	_expect(counter.server_buy_upgrade(1, &"fertilizer"), false, "Too far away", "upgrade from far away is rejected")
	_place_near(player, counter)
	await _frames(1)


func _part2_shop_ui(player: Player, counter: ShopCounter, items: ItemManager) -> void:
	_clear_hands(player, items)
	_place_near(player, counter)
	counter.interact(player)
	var ui := counter.get_shop_ui()
	_check(ui != null and ui.is_open() and Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE),
			"session: E on the counter opens the shop + ui lock")
	if ui == null:
		return
	var purple := Config.balance.get_seed(&"purple")
	var card := ui.get_card(ShopCounter.KIND_SEED, &"purple")
	if purple != null and card != null:
		var money := GameState.money
		_toasts.clear()
		_check(card.is_buy_enabled(), "Purple Haze BUY enabled (money $%d, empty hands)" % money)
		card.get_buy_button().pressed.emit()
		var held := player.get_held_item()
		_check(held != null and held.get(&"strain_id") == &"purple", "UI BUY -> RPC -> packet in hands", str(held))
		_check(GameState.money == money - purple.cost, "UI purchase spent $%d" % purple.cost)
		_check(_toasts.size() >= 1 and String(_toasts[-1][0]).contains("Purple Haze") and _toasts[-1][1] == &"success",
				"buyer gets a success toast", str(_toasts))
		_check(ui.get_feedback_text().contains("Purple Haze"), "success shown in the shop footer", ui.get_feedback_text())
		await _frames(1)
		ui.call(&"_refresh")
		_check(card.get_buy_button().text == "HANDS FULL" and not card.is_buy_enabled(),
				"seed BUY shows HANDS FULL while holding something", card.get_buy_button().text)
	var talk := Config.balance.get_upgrade(&"sweet_talk")
	var talk_card := ui.get_card(ShopCounter.KIND_UPGRADE, &"sweet_talk")
	if talk != null and talk_card != null:
		ui.show_tab(ShopUI.TAB_UPGRADES, false)
		var money := GameState.money
		talk_card.get_buy_button().pressed.emit()
		_check(GameState.get_upgrade_level(talk.id) == 1 and GameState.money == money - talk.cost_for_level(1),
				"UI buys Sweet Talk level 1 for $%d" % talk.cost_for_level(1))
		_check(talk_card.get_buy_button().text.contains("$%d" % talk.cost_for_level(2)),
				"upgrade card now shows the level 2 price", talk_card.get_buy_button().text)
	# Escape with the real HUD present: closes the shop and must not open the pause menu.
	_push_key(KEY_ESCAPE)
	await _frames(1)
	_check(not ui.is_open(), "Esc closes the shop in a live session")
	_check(not Game.is_ui_locked(), "Esc did not open the pause menu on top (no ui lock left)")
	_clear_hands(player, items)


func _part2_selling(player: Player, counter: ShopCounter, turn_in: TurnInStation, items: ItemManager) -> void:
	_place_near(player, turn_in)
	_clear_hands(player, items)
	_check(turn_in.get_denied_reason(player) == "Nothing to sell", "session: empty hands -> 'Nothing to sell'")
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, turn_in.global_position, 1)
	_check(can != null and turn_in.get_denied_reason(player) == "Only product can be sold here",
			"watering can -> 'Only product can be sold here'")
	_clear_hands(player, items)

	var golden := Config.balance.get_seed(&"golden")
	var purple := Config.balance.get_seed(&"purple")
	if golden == null or purple == null:
		_skip("selling", "balance.tres has no golden/purple seed")
		return
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": golden.id, "amount": 2}, turn_in.global_position, 1)
	if GameState.phase == GameState.Phase.WAITING:
		_check(turn_in.get_denied_reason(player) == "Selling opens when the round starts",
				"product before the round starts -> 'Selling opens when the round starts'")
	GameState.server_start_round()
	_check(GameState.is_playing() and GameState.round_sales == 0, "round started (PLAYING, sales 0)")

	var mult := GameState.get_sale_multiplier()
	var value := int(round(2 * golden.sale_value_per_unit * mult))
	_check(turn_in.can_interact(player), "holding product during the round -> can sell")
	_check(turn_in.get_prompt(player) == "Sell %s x2 (+$%d)" % [golden.display_name, value],
			"sell prompt shows strain, amount and value (multiplier %.2f)" % mult, turn_in.get_prompt(player))
	var money := GameState.money
	turn_in.interact(player)   # full base flow: prediction -> RPC -> range check -> _server_interact
	_check(GameState.round_sales == value and GameState.money == money + value,
			"sale adds $%d to round sales and money" % value,
			"sales %d money %d (was %d)" % [GameState.round_sales, GameState.money, money])
	_check(player.get_held_item() == null, "sold product left the player's hands")
	var label := turn_in.get_node_or_null(^"SoldLabel") as Label3D
	_check(label != null and label.text == TurnInStation.get_sold_text(GameState.round_sales, GameState.quota),
			"floating label follows sales_changed", label.text if label != null else "missing")

	# Double-sell guard + quota round end closing an open shop (all in one frame, like two packets in one poll)
	counter.open_shop_for(player)
	var ui := counter.get_shop_ui()
	var sales_before := GameState.round_sales
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": purple.id, "amount": 1}, turn_in.global_position, 1)
	var purple_value := int(round(purple.sale_value_per_unit * GameState.get_sale_multiplier()))
	turn_in._server_interact(player)
	turn_in._server_interact(player)
	_check(GameState.round_sales == sales_before + purple_value, "two sell requests in one frame pay only once",
			"sales %d expected %d" % [GameState.round_sales, sales_before + purple_value])
	if GameState.round_sales >= GameState.quota and Config.balance.end_round_on_quota_met:
		_check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "quota met ends the round")
		_check(ui != null and not ui.is_open(), "round end closes an open shop")
	else:
		_skip("round end closes the shop", "sales $%d below quota $%d" % [GameState.round_sales, GameState.quota])
		counter.close_shop()
	await _frames(2)


# =====================================================================================================================
# Helpers
# =====================================================================================================================

func _make_player(peer_id: int) -> Player:
	var scene := load(PLAYER_SCENE) as PackedScene
	if scene == null:
		return null
	var p := scene.instantiate() as Player
	if p == null:
		return null
	p.name = str(peer_id)
	p.process_mode = Node.PROCESS_MODE_DISABLED   # no gravity / input: stays where the test puts it
	add_child(p)
	return p


func _place_near(player: Player, station: Node3D) -> void:
	_place_at(player, station.to_global(Vector3(0.0, 0.0, 1.9)))


func _place_at(player: Player, pos: Vector3) -> void:
	player.place_at(Transform3D(Basis.IDENTITY, pos + Vector3.UP * 0.05))


func _clear_hands(player: Player, items: ItemManager) -> void:
	var held := items.get_held_by(player.peer_id)
	if held != null:
		items.server_despawn_item(held)


func _push_key(keycode: Key) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.pressed = pressed
		get_viewport().push_input(ev)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Wall-clock wait (headless frames can run faster than real time, so SceneTree timers are not enough here).
func _wait_real_msec(msec: int) -> void:
	var until := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _on_toast(text: String, kind: StringName) -> void:
	_toasts.append([text, kind])


func _expect(result: Dictionary, ok: bool, reason: String, label: String) -> void:
	var got_ok := bool(result.get("ok", not ok))
	var got_reason := String(result.get("reason", "<none>"))
	_check(got_ok == ok and got_reason == reason, "%s -> %s" % [label, "ok" if ok else "'%s'" % reason],
			"got ok=%s reason='%s'" % [got_ok, got_reason])


func _check(cond: bool, label: String, detail: String = "") -> void:
	if cond:
		_passes += 1
		print("PASS  " + label)
	else:
		_failures += 1
		print("FAIL  " + label + ("  -- " + detail if detail != "" else ""))


func _skip(label: String, why: String) -> void:
	_skips += 1
	print("SKIP  %s  -- %s" % [label, why])
