extends "res://tools/tests/qa_net_base.gd"
## Multi-process robustness test (QA milestone 7): host + clients Alpha, Bravo + "Ghost" (a peer that connects but
## never registers, so it has no Player node). Driven by tools/tests/qa_mp_robust.sh; all processes run this body:
##   --role=host | --role=client --who=a|b|u   --port=N
## Checks (host asserts server state, clients assert what they saw):
##   M3  Ghost (no Player): buy / interact / drop requests are refused without errors or state changes
##   M1  malformed RPCs from Alpha (wrong types, wrong arg count, authority-only RPC, teleporting another player):
##       the engine rejects them before game code runs (expected ERROR lines on the host), nothing changes
##   M2  requests from far away: interact + buy -> "Too far.", nothing changes
##   M4  double requests in one frame from a real client: pickup (no "Someone's carrying that."), buy (bypassing
##       the UI), ShopUI double click inside the round trip, plant, harvest, sell -> every effect exactly once
##   M7  a client's GameState.request_* calls are ignored
##   M5  Alpha and Bravo disconnect in the same frame while holding items: both Player nodes despawn, both items
##       drop, registry shrinks; game code logs nothing (the engine's own relay notice to an already-reset ENet
##       peer is tolerated, engine-only); both re-join with the same names
##   M6  the host leaves while Alpha has the shop open and Bravo the pause menu: both return to the menu with
##       "Host disconnected", no UI lock, no stray UI

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo", "u": "Ghost"}

var role: String = "host"
var who: String = ""
var port: int = 7980
var _ids: Dictionary = {}
var _connected: Array[int] = []
var _host_left_seen: bool = false
var _sync_log: Array = []   # host: msec timestamps of Alpha's Player $Sync "synchronized" signal

func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7980))
	_label = "mp_robust:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	elif who == "u":
		await _ghost_main()
	else:
		await _client_main()

# =================================================================================================== HOST

func _host_main() -> void:
	multiplayer.peer_connected.connect(func(id: int) -> void: _connected.append(id))
	Config.growth_speed_override = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func(): return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 10.0, "host world ready")
	print("QAMP_HOST_READY")
	await wait_until(func(): return _peer_named("a") > 0 and _peer_named("b") > 0, 40.0, "Alpha and Bravo registered")
	await wait_until(func(): return _ghost_id() > 0, 20.0, "Ghost connected (unregistered)")
	_ids["a"] = _peer_named("a")
	_ids["b"] = _peer_named("b")
	_ids["u"] = _ghost_id()
	if _ids["a"] <= 0 or _ids["b"] <= 0 or _ids["u"] <= 0:
		finish(); return
	await wait_until(func(): return Game.world.get_player(_ids["a"]) != null and Game.world.get_player(_ids["b"]) != null, 10.0, "their Player nodes exist")
	(Game.world.get_player(_ids["a"]).get_node("Sync") as MultiplayerSynchronizer).synchronized.connect(func() -> void: _sync_log.append(Time.get_ticks_msec()))
	GameState.request_start_round()
	var money := GameState.money
	var n_items := Game.world.items.get_items().size()

	step("M3: Ghost (connected, never registered, no Player node) sends requests")
	check(not Net.players.has(_ids["u"]) and Game.world.get_player(_ids["u"]) == null, "Ghost has no registry entry / Player node")
	var r := await run_cmd(_ids["u"], "ghost_requests", {"can": String(items_of(Const.ITEM_WATERING_CAN)[0].name)})
	check(GameState.money == money and Game.world.items.get_items().size() == n_items, "no money spent, no item created")
	check(Game.world.items.get_held_by(_ids["u"]) == null, "Ghost holds nothing")
	check((r.get("toasts", []) as Array).has(ShopCounter.REASON_NO_PLAYER), "Ghost's purchase refused: %s" % [r.get("toasts", [])])
	cmd(_ids["u"], "finish")
	await wait_until(func(): return not _ids["u"] in multiplayer.get_peers(), 10.0, "Ghost left")

	step("M1: malformed RPCs from Alpha are rejected by the engine")
	var b_player := Game.world.get_player(_ids["b"])
	for s in ["_rpc_request_buy_seed': Cannot convert argument 1 from int to StringName",
			"_rpc_request_buy_upgrade': Cannot convert argument 1 from Dictionary to StringName",
			"_rpc_register': Cannot convert argument 1 from int to String",
			"_rpc_request_buy_seed': Method expected 1 argument(s), but called with 2",
			"RPC '_rpc_state' is not allowed on node /root/GameState"]:
		expect_error(s)
	r = await run_cmd(_ids["a"], "garbage_rpcs", {"victim": _ids["b"]})
	await wait_until(func(): return expected_errors_seen(), 10.0, "every malformed RPC was rejected (logged by the engine)")
	check(GameState.money == money and Game.world.items.get_items().size() == n_items, "state unchanged")
	check(Net.get_player_name(_ids["a"]) == NAMES["a"] and Net.players.size() == 3, "registry unchanged (no re-register / rename)")
	_where("a", r, station("ShopCounter"))
	check((r.get("toasts", []) as Array).has(ShopCounter.REASON_UNKNOWN_SEED), "valid-typed unknown seed -> 'Unknown seed' %s" % [r.get("toasts", [])])
	check((r.get("toasts", []) as Array).has(ShopCounter.REASON_UNKNOWN_UPGRADE), "valid-typed unknown upgrade -> 'Unknown upgrade'")
	r = await run_cmd(_ids["b"], "position")
	check(Vector3(r.get("pos", Vector3.ZERO)).distance_to(Vector3(50, 0, 50)) > 10.0, "Bravo ignored a teleport RPC sent by Alpha (only the server may)")

	step("M2: requests from far away")
	r = await run_cmd(_ids["a"], "far_requests")
	var far_toasts: Array = r.get("toasts", [])
	check(far_toasts.count("Too far.") >= 2, "interact + buy from across the room -> 'Too far away' %s" % [far_toasts])
	check(GameState.money == money and Game.world.items.get_held_by(_ids["a"]) == null, "nothing bought, nothing held")

	step("M4: double requests in one frame from a client")
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	r = await run_cmd(_ids["a"], "double_pickup", {"item": String(can.name)})
	_where("a", r, can)
	check(can.holder_id == _ids["a"], "Alpha holds the can")
	check((r.get("toasts", []) as Array).is_empty(), "no error toast for the second pickup request %s" % [r.get("toasts", [])])
	r = await run_cmd(_ids["a"], "drop")
	r = await run_cmd(_ids["a"], "double_buy")
	check(GameState.money == money - 20 and items_of(Const.ITEM_SEED_PACKET).size() == 1, "raw buy x2: one packet, $20 once")
	check((r.get("toasts", []) as Array).has(ShopCounter.REASON_HANDS_FULL), "second raw buy refused (hands full)")
	r = await run_cmd(_ids["a"], "drop")
	var loose := items_of(Const.ITEM_SEED_PACKET)[0]
	Game.world.items.server_despawn_item(loose)
	money = GameState.money
	r = await run_cmd(_ids["a"], "ui_double_click")
	check(GameState.money == money - 20 and items_of(Const.ITEM_SEED_PACKET).size() == 1, "ShopUI double click inside the round trip: one purchase")
	check(not (r.get("toasts", []) as Array).has(ShopCounter.REASON_HANDS_FULL), "the UI swallowed the second click %s" % [r.get("toasts", [])])
	var p1 := plot(1)
	r = await run_cmd(_ids["a"], "double_interact", {"station": "GrowPlot1"})
	check(p1.stage == GrowPlot.Stage.SEEDLING and items_of(Const.ITEM_SEED_PACKET).is_empty(), "plant x2: planted once")
	p1.stage = GrowPlot.Stage.READY
	await wait_frames(2)
	r = await run_cmd(_ids["a"], "double_interact", {"station": "GrowPlot1"})
	check(items_of(Const.ITEM_PRODUCT).size() == 1 and p1.is_empty(), "harvest x2: one product")
	money = GameState.money
	var sales := GameState.round_sales
	r = await run_cmd(_ids["a"], "double_interact", {"station": "TurnInStation"})
	check(GameState.money == money + 60 and GameState.round_sales == sales + 60 and items_of(Const.ITEM_PRODUCT).is_empty(), "sell x2: paid once")
	await checkpoint_peers("after double presses", [_ids["a"], _ids["b"]], _names())

	step("M7: a client's host-only requests are ignored")
	r = await run_cmd(_ids["b"], "client_requests")
	await wait_sec(0.3)
	check(GameState.is_playing() and GameState.round_number == 1, "phase/round untouched by Bravo's requests")

	step("M5: Alpha and Bravo disconnect in the same frame while holding items")
	can = items_of(Const.ITEM_WATERING_CAN)[0]
	var can2: Item = items_of(Const.ITEM_WATERING_CAN)[1]
	Game.world.items.server_give_item(can, _ids["a"])
	Game.world.items.server_give_item(can2, _ids["b"])
	await checkpoint_peers("both holding", [_ids["a"], _ids["b"]], _names())
	# The engine relays a "peer left" notice to every other connected peer; one that dropped in the same ENet
	# batch is already reset -> "Unable to send packet on channel 0" from SceneMultiplayer itself (no game code).
	allow_error("Unable to send packet on channel 0", 2, true)
	var old_a: int = _ids["a"]
	var old_b: int = _ids["b"]
	cmd(old_a, "leave_now_and_rejoin", {"delay": 3.0})
	cmd(old_b, "leave_now_and_rejoin", {"delay": 3.0})
	await wait_until(func(): return Net.players.size() == 1, 10.0, "registry back to the host only")
	await wait_until(func(): return Game.world.get_players().size() == 1, 10.0, "both Player nodes despawned")
	check(can.holder_id == 0 and can2.holder_id == 0, "both cans dropped")
	check(absf(can.global_position.y) < 0.15 and absf(can2.global_position.y) < 0.15, "both on the floor")
	await wait_sec(0.5)
	clear_allowed_errors()
	await wait_until(func(): return _peer_named("a") > 0 and _peer_named("b") > 0 and _peer_named("a") != old_a and _peer_named("b") != old_b,
			20.0, "both re-joined with their own names")
	_ids["a"] = _peer_named("a")
	_ids["b"] = _peer_named("b")
	await wait_until(func(): return Game.world.get_players().size() == 3, 10.0, "3 Player nodes again")
	await checkpoint_peers("after re-join", [_ids["a"], _ids["b"]], _names())

	step("M6: host leaves while Alpha has the shop open and Bravo the pause menu")
	r = await run_cmd(_ids["a"], "open_shop")
	check(bool(r.get("ok", false)), "Alpha's shop is open")
	r = await run_cmd(_ids["b"], "open_pause")
	check(bool(r.get("ok", false)), "Bravo's pause menu is open")
	cmd(_ids["a"], "expect_host_leave")
	cmd(_ids["b"], "expect_host_leave")
	await wait_sec(0.5)
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Net.is_online(), "host back in the menu")
	finish()

## Diagnostics: where the client says it is vs where the host sees it (server range checks use the host view).
func _where(key: String, r: Dictionary, target: Node3D) -> void:
	var p := Game.world.get_player(_ids[key])
	if p == null or target == null:
		return
	var now := Time.get_ticks_msec()
	var recent := _sync_log.filter(func(t): return now - int(t) < 3000)
	var gaps := []
	for i in range(1, recent.size()):
		if int(recent[i]) - int(recent[i - 1]) > 150:
			gaps.append("%d ms gap ending %d ms ago" % [int(recent[i]) - int(recent[i - 1]), now - int(recent[i])])
	print("  (Alpha syncs applied in the last 3 s: %d, last one %d ms ago, gaps > 150 ms: %s)" % [recent.size(), now - int(_sync_log.back()) if not _sync_log.is_empty() else -1, gaps])
	print("  (%s: client says %s, host sees %s / net %s, target %s at %.2f m from the host view)" % [NAMES[key],
			r.get("pos", "?"), p.global_position, p.net_position, target.global_position, p.global_position.distance_to(target.global_position)])

func _names() -> Dictionary:
	var out := {}
	for k in _ids:
		out[_ids[k]] = NAMES[k]
	return out

func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0

func _ghost_id() -> int:
	for id in _connected:
		if id in multiplayer.get_peers() and not Net.players.has(id):
			return id
	return 0

# =================================================================================================== CLIENTS

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		finish(); return
	if not await wait_until(func(): return Game.local_player != null, 30.0, "%s joined" % my_name):
		finish(); return
	multiplayer.server_disconnected.connect(func() -> void: _host_left_seen = true)
	await client_loop()
	finish()

## The Ghost: connects but never sends its name (the registration handler is unhooked).
func _ghost_main() -> void:
	multiplayer.connected_to_server.disconnect(Net._on_connected_to_server)
	check(Game.start_join("127.0.0.1", port, NAMES["u"]) == OK, "ghost: start_join")
	await wait_until(func(): return Net.is_online() and Game.world != null, 10.0, "ghost: connected (world exists, not registered)")
	await client_loop()
	finish()

func _immediate(seq: int, action: String, args: Dictionary) -> bool:
	if action == "leave_now_and_rejoin":
		# Leave inside the poll that delivered the command: both clients drop within the same host frame.
		left_on_purpose = true
		Game.return_to_menu()
		_queue.append([seq, "rejoin_after", args])
		return true
	return false

func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	var shop: ShopCounter = station("ShopCounter")
	match action:
		"ghost_requests":
			shop._rpc_request_buy_seed.rpc_id(1, &"budget")
			shop._rpc_request_buy_upgrade.rpc_id(1, &"fertilizer")
			var can := item_named(String(args.get("can", "")))
			if can != null:
				can._rpc_request_interact.rpc_id(1)
			(station("TurnInStation") as Interactable)._rpc_request_interact.rpc_id(1)
			plot(1)._rpc_request_interact.rpc_id(1)
			Game.world.items._rpc_request_drop.rpc_id(1)
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"garbage_rpcs":
			stand_near(shop, 1.2)
			await server_sees_me()
			shop._rpc_request_buy_seed.rpc_id(1, 12345)
			shop._rpc_request_buy_upgrade.rpc_id(1, {"a": 1})
			Net._rpc_register.rpc_id(1, 42, "red")
			shop._rpc_request_buy_seed.rpc_id(1, &"budget", 5)
			GameState._rpc_state.rpc_id(1, {"money": 999999})
			Net._rpc_register.rpc_id(1, "Imposter", Color.RED)     # duplicate registration: ignored
			shop._rpc_request_buy_seed.rpc_id(1, &"no_such_seed")
			shop._rpc_request_buy_upgrade.rpc_id(1, &"no_such_upgrade")
			var victim := Game.world.get_player(int(args.get("victim", 0)))
			if victim != null:
				victim._rpc_teleport.rpc_id(victim.peer_id, Transform3D(Basis.IDENTITY, Vector3(50, 0, 50)))
			await sync_with_host()
			check(GameState.money == Config.balance.starting_money, "Alpha: money unchanged ($%d)" % GameState.money)
			check(Net.get_player_name(multiplayer.get_unique_id()) == NAMES["a"], "Alpha: still called Alpha")
			ack(seq, {"toasts": toasts_since(t), "pos": me.global_position})
		"position":
			await wait_sec(0.3)
			ack(seq, {"pos": me.global_position})
		"far_requests":
			stand_near(station("Well"), 1.4)
			await server_sees_me()
			(station("TurnInStation") as Interactable)._rpc_request_interact.rpc_id(1)
			shop.request_buy_seed(&"budget")
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"double_pickup":
			var it := item_named(String(args.get("item", "")))
			stand_near(it, 0.7)
			await server_sees_me()
			it.interact(me)
			it.interact(me)
			await wait_until_quiet(func(): return it.holder_id == multiplayer.get_unique_id(), 8.0)
			await sync_with_host()
			check(it.holder_id == multiplayer.get_unique_id(), "Alpha: holding the can after a double press")
			ack(seq, {"toasts": toasts_since(t), "pos": me.global_position, "item_pos": it.global_position})
		"drop":
			Game.world.items.request_drop()
			await wait_until_quiet(func(): return me.get_held_item() == null, 8.0)
			await wait_sec(0.2)
			ack(seq, {})
		"double_buy":
			stand_near(shop, 1.2)
			await server_sees_me()
			shop.request_buy_seed(&"budget")
			shop.request_buy_seed(&"budget")
			await wait_until_quiet(func(): return me.get_held_item() is SeedPacket, 8.0)
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"ui_double_click":
			stand_near(shop, 1.2)
			await server_sees_me()
			shop.open_shop_for(me)
			await wait_frames(2)
			var card := shop.get_shop_ui().get_card(ShopCounter.KIND_SEED, &"budget")
			check(card.is_buy_enabled(), "Alpha: BUY enabled")
			card.get_buy_button().pressed.emit()
			check(card.is_buy_enabled(), "Alpha: BUY still enabled until the server answers (round trip)")
			card.get_buy_button().pressed.emit()
			await wait_until_quiet(func(): return me.get_held_item() is SeedPacket, 8.0)
			await sync_with_host()
			shop.close_shop()
			ack(seq, {"toasts": toasts_since(t)})
		"double_interact":
			var st: Interactable = station(String(args.get("station", "")))
			stand_near(st, 1.2)
			await server_sees_me()
			st.interact(me)
			st.interact(me)
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"client_requests":
			GameState.request_start_round()
			GameState.request_next_round()
			GameState.request_retry()
			check(not GameState.is_local_host(), "Bravo: not the host")
			ack(seq, {})
		"rejoin_after":
			await wait_frames(3)
			check_menu_clean("after the same-frame leave")
			await wait_sec(float(args.get("delay", 3.0)))
			left_on_purpose = false
			check(Game.start_join("127.0.0.1", port, NAMES.get(who, "Client")) == OK, "re-join started")
			await wait_until(func(): return Game.local_player != null, 20.0, "re-joined")
			check(Net.get_player_name(multiplayer.get_unique_id()) == NAMES.get(who, ""), "kept my name")
		"open_shop":
			stand_near(shop, 1.2)
			await server_sees_me()
			shop.open_shop_for(me)
			await wait_frames(2)
			ack(seq, {"ok": shop.is_shop_open() and Game.is_ui_locked_by(&"shop")})
		"open_pause":
			var hud := Game.world.get_node("HUD") as HUD
			hud.pause_menu.open()
			await wait_frames(2)
			ack(seq, {"ok": hud.pause_menu.is_open() and Game.is_ui_locked_by(&"pause")})
		"expect_host_leave":
			left_on_purpose = true
			await wait_until(func(): return Game.world == null, 10.0, "%s: back in the menu after the host left" % NAMES.get(who, ""))
			await wait_frames(3)
			check(_host_left_seen, "server_disconnected received")
			var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
			var status := String(menu.call("get_status")) if menu != null else ""
			check(status.contains("Host disconnected"), "menu says 'Host disconnected' ('%s')" % status)
			check_menu_clean("after the host left")
			_stop = true
		_:
			await super(seq, action, args)
