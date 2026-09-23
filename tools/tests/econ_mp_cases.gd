extends Node
## Two-process economy test runner (loaded by tools/tests/econ_mp_test.gd). Verifies the shop / turn-in RPCs
## across a real ENet connection: a remote CLIENT buys, gets rejected with the right reasons, uses the ShopUI,
## drops, buys an upgrade and sells; the HOST checks it saw the same thing and that UIs stay local.
##
## Choreography (each side polls replicated state, no extra channel):
##   client: too far -> unknown seed -> buy Budget Bud -> hands full -> UI BUY while holding -> drop
##           -> buy Bigger Cans (signals the host) -> waits for PLAYING + a product in hands -> sells it -> leaves
##   host:   waits for the client, then for Bigger Cans level 1 -> starts the round and spawns Golden Kush x2 in the
##           client's hands -> waits for the sale -> waits for the client to leave -> back to menu

signal finished(failures: int)

const SYNC_WAIT_MSEC := 800

var _passes := 0
var _failures := 0
var _toasts: Array[Array] = []
var _role := ""


func run(role: String, port: int) -> void:
	_role = role
	Game.toast_requested.connect(func(text: String, kind: StringName) -> void: _toasts.append([text, kind]))
	if role == "host":
		await _run_host(port)
	else:
		await _run_client(port)
	print("econ_mp_test[%s]: %d passed, %d failed" % [role, _passes, _failures])
	finished.emit(_failures)


# ---------------------------------------------------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------------------------------------------------

func _run_host(port: int) -> void:
	var err: Error = Game.start_host("EconHost", port)
	if err != OK:
		_check(false, "host on port %d" % port, error_string(err))
		return
	var is_up := await _until(func() -> bool: return Game.world != null and Game.local_player != null, 10.0)
	_check(is_up, "host world + player up")
	if not is_up:
		return
	var world := Game.world
	var counter := world.get_node(^"Room/Stations/ShopCounter") as ShopCounter
	var turn_in := world.get_node(^"Room/Stations/TurnInStation") as TurnInStation
	var joined := await _until(func() -> bool: return world.get_players().size() >= 2, 30.0)
	_check(joined, "client joined")
	if not joined:
		return
	var client_id := 0
	for p in world.get_players():
		if p.peer_id != Const.SERVER_PEER_ID:
			client_id = p.peer_id
	var money_start := GameState.money
	var got_upgrade := await _until(func() -> bool: return GameState.get_upgrade_level(&"big_can") >= 1, 45.0)
	_check(got_upgrade, "host: client bought Bigger Cans through the RPC")
	if not got_upgrade:
		return
	var budget := Config.balance.get_seed(&"budget")
	var cans := Config.balance.get_upgrade(&"big_can")
	_check(GameState.money == money_start - budget.cost - cans.cost_for_level(1),
			"host: wallet charged exactly seed + upgrade ($%d)" % (budget.cost + cans.cost_for_level(1)),
			"money %d (start %d)" % [GameState.money, money_start])
	_check(counter.get_shop_ui() == null, "host: the client's shop UI never opened on the host")

	GameState.server_start_round()
	var golden := Config.balance.get_seed(&"golden")
	var product := world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": golden.id, "amount": 2},
			turn_in.global_position + Vector3.UP, client_id)
	_check(product != null and product.holder_id == client_id, "host: product spawned in the client's hands")
	var expected := TurnInStation.compute_sale_value(golden, 2, GameState.get_sale_multiplier())
	var sold := await _until(func() -> bool: return GameState.round_sales > 0, 30.0)
	_check(sold and GameState.round_sales == expected, "host: client's sale registered ($%d)" % expected,
			"round_sales %d" % GameState.round_sales)
	_check(world.items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "host: sold product despawned")
	var left := await _until(func() -> bool: return world.get_players().size() == 1, 30.0)
	_check(left, "client left cleanly")
	Game.return_to_menu()
	await _until(func() -> bool: return Game.world == null, 5.0)


# ---------------------------------------------------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------------------------------------------------

func _run_client(port: int) -> void:
	# The host may still be starting: retry the join a few times.
	var is_up := false
	for attempt in 5:
		Game.start_join("127.0.0.1", port, "EconClient")
		is_up = await _until(func() -> bool:
			return Game.local_player != null and GameState.phase == GameState.Phase.WAITING, 8.0)
		if is_up:
			break
		Game.return_to_menu()
		await _wait_real(500)
	_check(is_up, "client joined, got its player and the full state")
	if not is_up:
		return
	var me := Game.local_player
	var world := Game.world
	var counter := world.get_node(^"Room/Stations/ShopCounter") as ShopCounter
	var turn_in := world.get_node(^"Room/Stations/TurnInStation") as TurnInStation
	var budget := Config.balance.get_seed(&"budget")
	var money_start := GameState.money

	# Too far (server-side range check uses the synced position)
	await _move(me, counter.to_global(Vector3(6.5, 0.0, 1.5)))
	counter.request_buy_seed(&"budget")
	_expect_toast(await _next_toast(), false, "Too far away", "client: buying from 6 m away")

	await _move(me, counter.to_global(Vector3(0.0, 0.0, 1.9)))
	counter.request_buy_seed(&"no_such_seed")
	_expect_toast(await _next_toast(), false, "Unknown seed", "client: unknown seed")

	counter.request_buy_seed(budget.id)
	_expect_toast(await _next_toast(), true, "Bought %s seeds!" % budget.display_name, "client: buy Budget Bud")
	var holding := await _until(func() -> bool:
		var it := me.get_held_item()
		return it != null and it.item_type == Const.ITEM_SEED_PACKET and it.get(&"strain_id") == budget.id, 5.0)
	_check(holding, "client: replicated seed packet is in my hands")
	var paid := await _until(func() -> bool: return GameState.money == money_start - budget.cost, 5.0)
	_check(paid, "client: replicated wallet dropped by $%d" % budget.cost, "money %d" % GameState.money)

	counter.request_buy_seed(budget.id)
	_expect_toast(await _next_toast(), false, "Hands full — drop your item first", "client: hands full")

	# Through the UI on the client
	counter.interact(me)
	var ui := counter.get_shop_ui()
	_check(ui != null and ui.is_open() and Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE), "client: shop UI opens locally")
	var card := ui.get_card(ShopCounter.KIND_SEED, &"purple") if ui != null else null
	if card != null:
		card.buy_pressed.emit(card)   # BUY while holding: the server must refuse
		_expect_toast(await _next_toast(), false, "Hands full — drop your item first", "client: UI BUY while holding")
		_check(ui.get_feedback_text() == "Hands full — drop your item first", "client: refusal shown in the shop footer")
	if ui != null:
		ui.close()

	# Drop, then buy an upgrade (this also tells the host to continue)
	world.items.request_drop()
	var dropped := await _until(func() -> bool: return me.get_held_item() == null, 5.0)
	_check(dropped, "client: drop request emptied my hands")
	counter.request_buy_upgrade(&"big_can")
	_expect_toast(await _next_toast(), true, "Bigger Cans upgraded to level 1!", "client: buy Bigger Cans")
	var leveled := await _until(func() -> bool: return GameState.get_upgrade_level(&"big_can") == 1, 5.0)
	_check(leveled, "client: replicated upgrade level 1")

	# The host starts the round and hands me Golden Kush x2
	var got_product := await _until(func() -> bool:
		var it := me.get_held_item()
		return GameState.is_playing() and it != null and it.item_type == Const.ITEM_PRODUCT, 20.0)
	_check(got_product, "client: round started and product arrived in my hands")
	if not got_product:
		return
	await _move(me, turn_in.to_global(Vector3(0.0, 0.0, 1.9)))
	var product := me.get_held_item()
	var value := turn_in.get_sale_value(product)
	_check(turn_in.can_interact(me) and turn_in.get_prompt(me).ends_with("(+$%d)" % value),
			"client: sell prompt predicts +$%d" % value, turn_in.get_prompt(me))
	turn_in.interact(me)
	var sold := await _until(func() -> bool: return GameState.round_sales == value, 5.0)
	_check(sold, "client: replicated round sales = $%d" % value, "round_sales %d" % GameState.round_sales)
	var gone := await _until(func() -> bool: return me.get_held_item() == null, 5.0)
	_check(gone, "client: product left my hands")
	var label := turn_in.get_node_or_null(^"SoldLabel") as Label3D
	_check(label != null and label.text == TurnInStation.get_sold_text(value, GameState.quota),
			"client: floating label shows the sale", label.text if label != null else "missing")
	Game.return_to_menu()
	await _until(func() -> bool: return Game.world == null, 5.0)


# ---------------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------------

## Moves the local player (owner-authoritative) and waits so the host sees the new position.
func _move(player: Player, pos: Vector3) -> void:
	player.place_at(Transform3D(Basis.IDENTITY, pos + Vector3.UP * 0.05))
	await _wait_real(SYNC_WAIT_MSEC)


## Next purchase-result toast (success / error; join/leave "info" toasts are skipped). [] on timeout.
func _next_toast(timeout_sec: float = 5.0) -> Array:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		while not _toasts.is_empty():
			var t: Array = _toasts.pop_front()
			if t[1] != &"info":
				return t
		await get_tree().process_frame
	return []


func _expect_toast(toast: Array, ok: bool, text: String, label: String) -> void:
	var want_kind := &"success" if ok else &"error"
	_check(toast.size() == 2 and toast[0] == text and toast[1] == want_kind, "%s -> %s '%s'" % [label, want_kind, text],
			"got %s" % str(toast))


func _until(cond: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _wait_real(msec: int) -> void:
	var until := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _check(cond: bool, label: String, detail: String = "") -> void:
	if cond:
		_passes += 1
		print("PASS  [%s] %s" % [_role, label])
	else:
		_failures += 1
		print("FAIL  [%s] %s%s" % [_role, label, ("  -- " + detail) if detail != "" else ""])
