extends "res://tools/tests/qa_net_base.gd"
## 4-player stress / desync test (QA, milestone 7). One HOST + three CLIENTS as separate headless processes on
## the real game stack (Game.start_host / Game.start_join, World, spawners, stations, items, GameState), plus a
## 5th "overflow" process that must be refused. Driven by tools/tests/qa_4p.sh; every process runs THIS script
## (identical RPC config on /root/TestBody) with a different role:
##   --role=host                          the director: sends commands to clients, compares states
##   --role=client --who=a|b|c            Alpha / Bravo / Charlie (Charlie joins late, when the host prints
##                                        QA4P_LAUNCH_LATE)
##   --role=client --who=x                the 5th joiner (launched on QA4P_LAUNCH_FIFTH): must get "Server is full"
## Common args: --port=N --round-sec=900 --timeout=S
##
## Scenario (host side, every step asserted with PASS/FAIL lines; clients assert their own view too):
##   join  -> checkpoint (every peer's canonical_state() must equal the host's)
##   (a)   Alpha and Bravo grab the SAME watering can in the same host frame: exactly one holds it, the
##         other is told "Someone's carrying that.", no duplicate items; a server-side "Hands full." denial
##   (b)   the loser buys a seed, then plants plot 1 while the winner waters plot 1 (same frame);
##         growth to READY; Charlie (a third player) harvests and sells
##   (c)   checkpoints after every step
##   (d)   Charlie joins late while items are held and plot 1 is frozen mid-growth: sees everything within 2 s
##   (5th) a 5th player is refused with "Server is full" while 4 are in
##   (e)   the seed-packet holder leaves (Game.return_to_menu): packet drops to the floor on every peer,
##         its Player despawns everywhere, Net.players shrinks
##   (h)   the same client re-joins with the same name and sees the live state
##   (f)   timer runs out -> ROUND_FAILED -> host RETRY with clients present: plots empty, packets/products
##         gone, cans back at the well (full), money reset - on every peer, overlays/UI locks consistent
##   (g)   quota met by a real client sale -> ROUND_SUCCESS -> next round: round 2 + new quota everywhere

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo", "c": "Charlie", "x": "Xtra"}
## Late joiner must converge within this many ms after its Player spawned (task requirement: 2 s).
const LATE_JOIN_LIMIT_MS := 2000

var role: String = "host"
var who: String = ""
var port: int = 7950

# --- host ---
var _ids: Dictionary = {}           # "a"/"b"/"c" -> peer id
var _connects: Array[int] = []      # every peer_connected seen by the host
var _disconnects: Array[int] = []

# --- client ---
var _spawn_msec: int = -1
var _timeline: Array = []           # [msec since spawn, canonical]


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7950))
	_label = "4p:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	elif who == "x":
		await _overflow_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	multiplayer.peer_connected.connect(func(id: int) -> void: _connects.append(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: _disconnects.append(id))
	Config.growth_speed_override = 0.0 # growth frozen unless a step wants it: checkpoints stay deterministic
	var err := Game.start_host(NAMES["host"], port)
	if not check(err == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func(): return Game.local_player != null, 10.0, "host player spawned")
	await wait_until(func(): return items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans, 10.0, "starting cans spawned")
	print("QA4P_HOST_READY")

	step("waiting for Alpha + Bravo")
	if not await wait_until(func(): return _peer_named("a") > 0 and _peer_named("b") > 0, 40.0, "Alpha and Bravo registered"):
		await _abort(); return
	_ids["a"] = _peer_named("a")
	_ids["b"] = _peer_named("b")
	await wait_until(func(): return Game.world.get_player(_ids["a"]) != null and Game.world.get_player(_ids["b"]) != null, 10.0, "their Player nodes exist on the host")
	await wait_sec(0.5)
	await checkpoint("joined", ["a", "b"])

	step("start round")
	GameState.request_start_round()
	check(GameState.is_playing() and GameState.round_number == 1, "round 1 PLAYING")
	await checkpoint("round started", ["a", "b"])

	# ---------------------------------------------------------------- (a0) money race
	step("(a0) Alpha and Bravo buy the last affordable seed in the same frame")
	GameState.server_add_money(20 - GameState.money)   # exactly one Budget Bud left in the wallet
	await run_both("a", "goto_station", {"station": "ShopCounter", "distance": 1.3}, "b", "goto_station", {"station": "ShopCounter", "distance": 1.3})
	var s_buy_a := cmd(_ids["a"], "buy_now", {"seed": "budget"})
	var s_buy_b := cmd(_ids["b"], "buy_now", {"seed": "budget"})
	var buy_a := await await_ack(s_buy_a)
	var buy_b := await await_ack(s_buy_b)
	check(GameState.money == 0, "money spent exactly once ($%d left, never negative)" % GameState.money)
	check(items_of(Const.ITEM_SEED_PACKET).size() == 1, "exactly one packet exists")
	var buyers := int(Game.world.items.get_held_by(_ids["a"]) != null) + int(Game.world.items.get_held_by(_ids["b"]) != null)
	check(buyers == 1, "exactly one of them holds it")
	var buy_toasts: Array = (buy_a.get("toasts", []) as Array) + (buy_b.get("toasts", []) as Array)
	check(buy_toasts.has(ShopCounter.REASON_NO_MONEY), "the other was told 'Not enough cash.' %s" % [buy_toasts])
	await checkpoint("after the money race", ["a", "b"])
	for it in items_of(Const.ITEM_SEED_PACKET):
		Game.world.items.server_despawn_item(it)
	GameState.server_add_money(Config.balance.starting_money - GameState.money)
	await wait_frames(2)
	await checkpoint("money restored", ["a", "b"])

	# ---------------------------------------------------------------- (a) same-frame pickup race
	step("(a) Alpha and Bravo grab the same watering can in the same frame")
	var cans := items_of(Const.ITEM_WATERING_CAN)
	var can_a: Item = cans[0]
	var can_b: Item = cans[1]
	var r: Dictionary = {}
	await run_both("a", "goto_item", {"item": String(can_a.name)}, "b", "goto_item", {"item": String(can_a.name)})
	var s_a := cmd(_ids["a"], "grab_now", {"item": String(can_a.name)})
	var s_b := cmd(_ids["b"], "grab_now", {"item": String(can_a.name)})
	var ack_a := await await_ack(s_a)
	var ack_b := await await_ack(s_b)
	var holder := can_a.holder_id
	check(holder == _ids["a"] or holder == _ids["b"], "the can is held by exactly one of them (holder %d)" % holder)
	check(bool(ack_a.get("mine", false)) != bool(ack_b.get("mine", false)), "exactly one client reports holding it (a=%s b=%s)" % [ack_a.get("mine"), ack_b.get("mine")])
	var w := "a" if holder == _ids["a"] else "b"   # winner
	var l := "b" if w == "a" else "a"                # loser
	var loser_ack := ack_b if l == "b" else ack_a
	var loser_toasts: Array = loser_ack.get("toasts", [])
	check(loser_toasts.has("Someone's carrying that.") or loser_toasts.has("Hands full."),
			"loser (%s) was told why: %s" % [NAMES[l], loser_toasts])
	check(Game.world.items.get_held_by(_ids[l]) == null, "loser holds nothing on the host")
	check(items_of(Const.ITEM_WATERING_CAN).size() == 2 and Game.world.items.get_items().size() == 2, "still exactly 2 items (no duplicates)")
	await checkpoint("after the race", ["a", "b"])

	step("(a2) server-side denial: winner asks for the second can with full hands (prediction bypassed)")
	r = await run_cmd(_ids[w], "raw_pickup_request", {"item": String(can_b.name)})
	check(can_b.holder_id == 0, "second can stays on the floor")
	check((r.get("toasts", []) as Array).has("Hands full."), "winner got 'Hands full.' from the server: %s" % [r.get("toasts", [])])

	# ---------------------------------------------------------------- (b) plant + water same frame
	step("(b) %s buys a seed, then plants plot 1 while %s waters it in the same frame" % [NAMES[l], NAMES[w]])
	r = await run_cmd(_ids[l], "buy", {"seed": "budget"})
	check(bool(r.get("ok", false)), "%s bought a Budget Bud packet (%s)" % [NAMES[l], r.get("toasts", [])])
	check(GameState.money == Config.balance.starting_money - 20, "money 120 -> 100")
	await run_both(l, "goto_station", {"station": "GrowPlot1"}, w, "goto_station", {"station": "GrowPlot1"})
	var charges_before := int(can_a.get(&"charges"))
	var s_plant := cmd(_ids[l], "interact_now", {"station": "GrowPlot1"})
	var s_water := cmd(_ids[w], "interact_now", {"station": "GrowPlot1"})
	var ack_plant := await await_ack(s_plant)
	var ack_water := await await_ack(s_water)
	var p1 := plot(1)
	check(p1.stage == GrowPlot.Stage.SEEDLING and p1.strain_id == &"budget", "plot 1 planted (stage %d, %s)" % [p1.stage, p1.strain_id])
	check(items_of(Const.ITEM_SEED_PACKET).is_empty(), "the packet was consumed exactly once")
	if p1.water < 0.99:
		# The water request reached the server before the plant request: it must have been refused cleanly.
		check((ack_water.get("toasts", []) as Array).has("Needs seeds."), "water-before-plant refused with 'Needs seeds.' %s" % [ack_water.get("toasts", [])])
		check(int(can_a.get(&"charges")) == charges_before, "no charge spent by the refused watering")
		r = await run_cmd(_ids[w], "interact", {"station": "GrowPlot1"})
	else:
		print("  (plant was processed first)")
	check(p1.water >= 0.95, "plot 1 watered (%.2f)" % p1.water)
	check(int(can_a.get(&"charges")) == charges_before - 1, "exactly one charge spent (%d -> %d)" % [charges_before, int(can_a.get(&"charges"))])
	check((ack_plant.get("toasts", []) as Array).is_empty(), "planter saw no error toast: %s" % [ack_plant.get("toasts", [])])
	await checkpoint("planted + watered", ["a", "b"])

	step("grow plot 1 to mid-VEGETATIVE, then freeze")
	Config.growth_speed_override = 25.0
	await wait_until(func(): return p1.stage == GrowPlot.Stage.VEGETATIVE and p1.stage_progress >= 0.3, 10.0, "plot 1 VEGETATIVE >= 30%")
	Config.growth_speed_override = 0.0
	# Items held for the late joiner: loser holds a purple packet, winner the can, host the second can.
	r = await run_cmd(_ids[l], "buy", {"seed": "purple"})
	check(bool(r.get("ok", false)), "%s holds a Purple Haze packet" % NAMES[l])
	var me: Player = Game.local_player
	stand_near(can_b, 0.6)
	await wait_frames(2)
	can_b.interact(me)
	await wait_frames(2)
	check(can_b.holder_id == 1, "host holds the second can")
	# An upgrade changes derived values (can capacity) that a late joiner must also get right.
	GameState.server_add_money(100)
	check(GameState.server_buy_upgrade(&"big_can", 1), "team bought Bigger Cans (capacity %d)" % GameState.get_can_capacity())
	await checkpoint("mid-growth, 3 items held", ["a", "b"])

	# ---------------------------------------------------------------- (d) late joiner
	step("(d) Charlie joins late (items held, plot mid-growth)")
	print("QA4P_LAUNCH_LATE")
	if not await wait_until(func(): return _peer_named("c") > 0, 40.0, "Charlie registered"):
		await _abort(); return
	_ids["c"] = _peer_named("c")
	await wait_until(func(): return Game.world.get_player(_ids["c"]) != null, 10.0, "Charlie's Player node exists on the host")
	check(Net.players.size() == 4 and Game.world.get_players().size() == 4, "4 players")
	r = await run_cmd(_ids["c"], "late_check", {"expect": canonical_state()}, 10.0)
	check(bool(r.get("ok", false)), "Charlie saw the exact host state %d ms after spawning (limit %d ms)" % [int(r.get("ms", -1)), LATE_JOIN_LIMIT_MS])
	check(bool(r.get("visual_ok", false)), "Charlie's held items follow their holders + plot visuals match: %s" % r.get("visual", ""))
	if not bool(r.get("ok", false)):
		print("      host: " + canonical_state())
		print("      late: " + str(r.get("state", "")))
	await checkpoint("after late join", ["a", "b", "c"])

	step("5th player must be refused while 4 are in")
	var connects_before := _connects.size()
	print("QA4P_LAUNCH_FIFTH")
	if await wait_until(func(): return _connects.size() > connects_before, 30.0, "5th peer connected at ENet level"):
		var fifth: int = _connects[_connects.size() - 1]
		await wait_until(func(): return fifth in _disconnects, 10.0, "5th peer was disconnected by the server")
		check(not Net.players.has(fifth) and Game.world.get_player(fifth) == null, "5th peer never got a player / registry entry")
	check(Net.players.size() == 4, "still 4 players")
	await checkpoint("after the refused 5th", ["a", "b", "c"])

	step("grow to READY; %s and Charlie harvest plot 1 in the same frame" % NAMES[w])
	Config.growth_speed_override = 25.0
	await wait_until(func(): return p1.stage == GrowPlot.Stage.READY, 15.0, "plot 1 READY")
	Config.growth_speed_override = 0.0
	r = await run_cmd(_ids[w], "drop")
	check(can_a.holder_id == 0, "%s put the can down" % NAMES[w])
	await checkpoint("ready", ["a", "b", "c"])
	await run_both(w, "goto_station", {"station": "GrowPlot1"}, "c", "goto_station", {"station": "GrowPlot1"})
	var s_h1 := cmd(_ids[w], "interact_now", {"station": "GrowPlot1"})
	var s_h2 := cmd(_ids["c"], "interact_now", {"station": "GrowPlot1"})
	await await_ack(s_h1)
	await await_ack(s_h2)
	check(items_of(Const.ITEM_PRODUCT).size() == 1, "exactly one product from one plant")
	check(p1.stage == GrowPlot.Stage.EMPTY, "plot 1 EMPTY after the harvest")
	var harvester := ""
	for k in [w, "c"]:
		if Game.world.items.get_held_by(_ids[k]) is Product:
			harvester = k
	check(harvester != "", "one of them holds the Budget Bud product")
	if harvester == "":
		await _abort(); return
	await checkpoint("harvested", ["a", "b", "c"])
	var money_before := GameState.money
	r = await run_cmd(_ids[harvester], "goto_station", {"station": "TurnInStation"})
	r = await run_cmd(_ids[harvester], "interact", {"station": "TurnInStation"})
	check(GameState.money == money_before + 60 and GameState.round_sales == 60, "%s sold it: +$60 (money %d, sold %d)" % [NAMES[harvester], GameState.money, GameState.round_sales])
	check(items_of(Const.ITEM_PRODUCT).is_empty(), "product gone")
	await checkpoint("sold", ["a", "b", "c"])
	# The winner takes can A back (the RETRY step below must take a HELD can out of someone's hands).
	var cmd_seq := cmd(_ids[w], "goto_item", {"item": String(can_a.name)})
	await await_ack(cmd_seq)
	r = await run_cmd(_ids[w], "grab", {"item": String(can_a.name)})
	check(can_a.holder_id == _ids[w], "%s holds can A again" % NAMES[w])

	# ---------------------------------------------------------------- (e) + (h) leave holding a packet, re-join
	step("(e) %s leaves (return_to_menu) while holding the purple packet" % NAMES[l])
	var leaver: int = _ids[l]
	var leaver_player := Game.world.get_player(leaver)
	var leaver_feet := leaver_player.global_position if leaver_player != null else Vector3.INF
	var packet := Game.world.items.get_held_by(leaver)
	check(packet is SeedPacket, "%s holds the packet before leaving" % NAMES[l])
	cmd(leaver, "leave_rejoin", {"delay": 4.0})
	await wait_until(func(): return not Net.players.has(leaver), 10.0, "players dict shrank (leaver gone)")
	await wait_until(func(): return Game.world.get_player(leaver) == null, 10.0, "leaver's Player node despawned on the host")
	check(Net.players.size() == 3, "3 players left")
	if is_instance_valid(packet):
		check(packet.holder_id == 0, "packet dropped (holder 0)")
		var d := Vector2(packet.global_position.x - leaver_feet.x, packet.global_position.z - leaver_feet.z).length()
		check(d < 1.2 and absf(packet.global_position.y) < 0.15, "packet on the floor near where the leaver stood (%.2f m, y %.2f)" % [d, packet.global_position.y])
	else:
		check(false, "packet still exists after its holder left")
	check(items_of(Const.ITEM_SEED_PACKET).size() == 1, "exactly one seed packet")
	await checkpoint("leaver gone", [w, "c"])

	step("(h) %s re-joins with the same name" % NAMES[l])
	if not await wait_until(func(): return _peer_named(l) > 0 and _peer_named(l) != leaver, 20.0, "%s is back (new peer id)" % NAMES[l]):
		await _abort(); return
	_ids[l] = _peer_named(l)
	check(Net.get_player_name(_ids[l]) == NAMES[l], "same name, not a duplicate-suffixed one ('%s')" % Net.get_player_name(_ids[l]))
	await wait_until(func(): return Game.world.get_player(_ids[l]) != null, 10.0, "re-joined Player node exists")
	check(Net.players.size() == 4 and Game.world.get_players().size() == 4, "4 players again")
	await checkpoint("after re-join", ["a", "b", "c"])

	# ---------------------------------------------------------------- (f) failed round + RETRY with clients
	step("(f) fill the world, run the timer out, host RETRY")
	# Winner still holds can A (reset must take it out of their hands); Charlie gets a product in hand.
	Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 2}, Vector3.ZERO, _ids["c"])
	p1.server_plant(&"purple")
	plot(4).server_plant(&"golden")
	await wait_frames(2)
	await checkpoint("before failing", ["a", "b", "c"])
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "ROUND_FAILED on the host")
	await checkpoint("round failed", ["a", "b", "c"], true)
	GameState.request_retry()
	await wait_frames(6) # the Well re-homes the cans two frames after game_reset
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.money == Config.balance.starting_money,
			"host: WAITING, round 1, $%d" % Config.balance.starting_money)
	var all_empty := true
	for i in range(1, 7):
		all_empty = all_empty and plot(i).stage == GrowPlot.Stage.EMPTY and plot(i).strain_id == &""
	check(all_empty, "host: every plot empty")
	check(items_of(Const.ITEM_SEED_PACKET).is_empty() and items_of(Const.ITEM_PRODUCT).is_empty(), "host: no packets / products")
	var well: Well = station("Well")
	var cans_ok := items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans
	var i_can := 0
	for can in items_of(Const.ITEM_WATERING_CAN):
		var near := false
		for k in Config.balance.starting_watering_cans:
			near = near or can.global_position.distance_to(well.get_can_spot_position(k)) < 0.05
		cans_ok = cans_ok and can.holder_id == 0 and near and int(can.get(&"charges")) == GameState.get_can_capacity()
		i_can += 1
	check(cans_ok, "host: %d cans back at the well, on the floor, full" % i_can)
	await checkpoint("after retry", ["a", "b", "c"], true)

	# ---------------------------------------------------------------- (g) success -> next round
	step("(g) quota met by a real client sale -> next round")
	GameState.request_start_round()
	GameState.server_add_sale(GameState.quota - 60, 1)
	check(GameState.is_playing(), "still PLAYING just below the quota")
	Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, _ids["a"])
	Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, _ids["c"])
	await run_both("a", "goto_station", {"station": "TurnInStation"}, "c", "goto_station", {"station": "TurnInStation"})
	var money_g := GameState.money
	var quota_g := GameState.quota
	var s_sell_a := cmd(_ids["a"], "interact_now", {"station": "TurnInStation"})
	var s_sell_c := cmd(_ids["c"], "interact_now", {"station": "TurnInStation"})
	var sell_a := await await_ack(s_sell_a)
	var sell_c := await await_ack(s_sell_c)
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_SUCCESS, 10.0, "a real client sale met the quota -> ROUND_SUCCESS")
	check(GameState.round_sales == quota_g and GameState.money == money_g + 60, "exactly one of the two same-frame sales counted (sold %d / %d)" % [GameState.round_sales, quota_g])
	var leftover := items_of(Const.ITEM_PRODUCT)
	check(leftover.size() == 1 and leftover[0].is_held(), "the late seller keeps the product (not lost, not paid)")
	var sell_toasts: Array = (sell_a.get("toasts", []) as Array) + (sell_c.get("toasts", []) as Array)
	check(sell_toasts.has(TurnInStation.REASON_NOT_PLAYING), "the late seller was told selling reopens next round %s" % [sell_toasts])
	await checkpoint("round success", ["a", "b", "c"], true)
	GameState.request_next_round()
	check(GameState.round_number == 2 and GameState.is_playing() and GameState.quota == Config.balance.quota_for_round(2, Net.players.size()),
			"host: round 2 PLAYING, payment %d for %d workers" % [Config.balance.quota_for_round(2, Net.players.size()), Net.players.size()])
	check(Net.players.size() < 2 or GameState.quota > Config.balance.quota_for_round(2), "host: a team pays more than a solo worker")
	await checkpoint("round 2", ["a", "b", "c"], true)
	if leftover.size() == 1:
		var keeper := "a" if leftover[0].holder_id == _ids["a"] else "c"
		r = await run_cmd(_ids[keeper], "interact", {"station": "TurnInStation"})
		check(GameState.round_sales == 60, "the kept product sells in round 2 (sold %d)" % GameState.round_sales)
		await checkpoint("round 2 first sale", ["a", "b", "c"], true)

	# ---------------------------------------------------------------- wrap up
	step("clients leave one by one (simultaneous drops are covered by qa_mp_robust)")
	for k in ["a", "b", "c"]:
		var id: int = _ids[k]
		cmd(id, "finish", {})
		await wait_until(func(): return not Net.players.has(id), 8.0, "%s left" % NAMES[k])
	await wait_until(func(): return Net.players.size() == 1, 10.0, "every client left")
	await wait_until(func(): return Game.world.get_players().size() == 1, 10.0, "only the host's Player node remains")
	check(Game.world.items.get_held_by(_ids["a"]) == null and Game.world.items.get_held_by(_ids["b"]) == null
			and Game.world.items.get_held_by(_ids["c"]) == null, "nothing held by departed peers")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and GameState.phase == GameState.Phase.MENU, "host back in the menu")
	finish()

func _abort() -> void:
	for k in _ids:
		if Net.players.has(_ids[k]):
			cmd(_ids[k], "finish", {})
	await wait_sec(1.0)
	finish()

func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0

## Sends two commands in the same frame and waits for both.
func run_both(k1: String, a1: String, args1: Dictionary, k2: String, a2: String, args2: Dictionary) -> Array:
	var s1 := cmd(_ids[k1], a1, args1)
	var s2 := cmd(_ids[k2], a2, args2)
	return [await await_ack(s1), await await_ack(s2)]

## Every listed client (by key) must converge to the host's canonical state.
func checkpoint(tag: String, keys: Array, ui: bool = false) -> void:
	var peers := []
	var names := {}
	for k in keys:
		peers.append(_ids[k])
		names[_ids[k]] = NAMES[k]
	await checkpoint_peers(tag, peers, names, ui)


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	Game.local_player_spawned.connect(_on_local_spawned)
	var err := Game.start_join("127.0.0.1", port, my_name)
	if not check(err == OK, "start_join 127.0.0.1:%d" % port):
		finish(); return
	if not await wait_until(func(): return Game.local_player != null, 30.0, "%s joined (local Player spawned)" % my_name):
		finish(); return
	check(Net.get_player_name(multiplayer.get_unique_id()) == my_name, "registered as %s" % my_name)
	await client_loop()
	finish()

func _on_local_spawned(_p: Player) -> void:
	_spawn_msec = Time.get_ticks_msec()
	_timeline.clear()

func _physics_process(_delta: float) -> void:
	_sample_timeline()

## Late-join timeline: records every change of the canonical state since our Player spawned.
func _sample_timeline() -> void:
	if role != "client" or _spawn_msec < 0 or Game.world == null:
		return
	var now := Time.get_ticks_msec() - _spawn_msec
	if now > 10000:
		return
	var s := canonical_state()
	if _timeline.is_empty() or _timeline.back()[1] != s:
		_timeline.append([now, s])

## Race actions run inside the network poll that delivered them, so both clients' requests leave in the same
## frame as the host's command.
func _immediate(seq: int, action: String, args: Dictionary) -> bool:
	if action == "grab_now":
		var it := item_named(String(args.get("item", "")))
		var t := toasts.size()
		if it != null:
			it.interact(Game.local_player)
		_queue.append([seq, "grab_wait", {"item": String(args.get("item", "")), "t": t}])
		return true
	if action == "buy_now":
		var shop: ShopCounter = station("ShopCounter")
		var tb := toasts.size()
		shop.request_buy_seed(StringName(String(args.get("seed", ""))))
		_queue.append([seq, "settle", {"t": tb}])
		return true
	if action == "interact_now":
		var st: Interactable = station(String(args.get("station", "")))
		var t2 := toasts.size()
		if st != null:
			st.interact(Game.local_player)
		_queue.append([seq, "settle", {"t": t2}])
		return true
	return false

func _execute(seq: int, action: String, args: Dictionary) -> void:
	var t := toasts.size()
	match action:
		"grab_wait":
			var it := item_named(String(args.get("item", "")))
			# Wait until the holder is known here and any denial had time to arrive.
			await wait_until_quiet(func(): return it != null and it.holder_id != 0, 8.0)
			await sync_with_host()
			var mine := it != null and it.holder_id == multiplayer.get_unique_id()
			ack(seq, {"mine": mine, "holder": it.holder_id if it != null else -1, "toasts": toasts_since(int(args.get("t", 0)))})
		"raw_pickup_request":
			# Bypass the local can_interact() prediction: the server must refuse (hands full).
			var it := item_named(String(args.get("item", "")))
			if it != null:
				stand_near(it, 0.7)
				await server_sees_me()
				it._rpc_request_interact.rpc_id(1)
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"settle":
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(int(args.get("t", 0)))})
		"drop":
			Game.world.items.request_drop()
			await wait_until_quiet(func(): return Game.local_player.get_held_item() == null, 8.0)
			await wait_sec(0.2)
			ack(seq, {})
		"grab":
			var it := item_named(String(args.get("item", "")))
			if it != null:
				it.interact(Game.local_player)
			await wait_until_quiet(func(): return it != null and it.holder_id == multiplayer.get_unique_id(), 8.0)
			await wait_sec(0.2)
			ack(seq, {"toasts": toasts_since(t)})
		"late_check":
			await _late_check(seq, String(args.get("expect", "")))
		"leave_rejoin":
			await _leave_and_rejoin(float(args.get("delay", 4.0)))
		_:
			await super(seq, action, args)

func _late_check(seq: int, expect: String) -> void:
	# The command can arrive in the very frame our Player spawned, before Game's deferred local_player_spawned.
	await wait_until_quiet(func(): return _spawn_msec >= 0, 5.0)
	# Wait until the limit has passed since our spawn (or we already match), then inspect the timeline.
	while Time.get_ticks_msec() - _spawn_msec < LATE_JOIN_LIMIT_MS and canonical_state() != expect:
		await get_tree().process_frame
	_sample_timeline()
	var first_ok := -1
	for i in range(_timeline.size() - 1, -1, -1):
		if _timeline[i][1] == expect:
			first_ok = int(_timeline[i][0])
		else:
			break
	var ok := canonical_state() == expect and first_ok >= 0 and first_ok <= LATE_JOIN_LIMIT_MS
	check(ok, "late join: matched the host state %d ms after spawning" % first_ok)
	if not ok:
		print("      timeline (%d entries, spawn at %d):" % [_timeline.size(), _spawn_msec])
		for e in _timeline:
			print("        %5d ms %s" % [int(e[0]), e[1]])
	var visual := _visual_report()
	check(visual == "", "late join: visuals consistent %s" % visual)
	ack(seq, {"ok": ok, "ms": first_ok, "state": canonical_state(), "visual_ok": visual == "", "visual": visual})

## "" when every held item is visible at its holder's socket and every plot shows its synced stage.
func _visual_report() -> String:
	var bad: PackedStringArray = []
	for it in Game.world.items.get_items():
		if it.is_held():
			var h := it.get_holder()
			if h == null:
				bad.append("%s holder %d has no Player node" % [it.name, it.holder_id])
				continue
			var want := (h.get_item_socket().global_transform * it._get_hold_transform()).origin
			if not it.visible or it.global_position.distance_to(want) > 0.1:
				bad.append("%s not at %s's hand (visible=%s, %.2f m off)" % [it.name, h.name, it.visible, it.global_position.distance_to(want)])
		elif not it.visible or it.global_position.distance_to(it.rest_position) > 0.01:
			bad.append("%s floor item misplaced/hidden" % it.name)
		if it is WateringCan:
			# Derived from synced charges + the synced upgrade levels: "3/6" with Bigger Cans.
			var want_label := "%d/%d" % [(it as WateringCan).charges, GameState.get_can_capacity()]
			var label := it.get_node("ChargeLabel") as Label3D
			if label.text != want_label or it.get_label_text() != "Watering Can (%s)" % want_label:
				bad.append("%s label '%s' != '%s'" % [it.name, label.text, want_label])
	for i in range(1, 7):
		var p := plot(i)
		var pv: Node = p.get_node("%Plant")
		if int(pv.get(&"_stage")) != int(p.stage):
			bad.append("plot %d visual stage %d != %d" % [i, int(pv.get(&"_stage")), p.stage])
	return "" if bad.is_empty() else "; ".join(bad)

func _leave_and_rejoin(delay: float) -> void:
	var my_name: String = NAMES.get(who, "Client")
	var old_id := multiplayer.get_unique_id()
	left_on_purpose = true
	Game.return_to_menu()
	await wait_frames(3)
	check_menu_clean("after leaving")
	await wait_sec(delay)
	left_on_purpose = false
	_spawn_msec = -1
	var err := Game.start_join("127.0.0.1", port, my_name)
	check(err == OK, "re-join started")
	if await wait_until(func(): return Game.local_player != null, 20.0, "re-joined (local Player spawned)"):
		check(multiplayer.get_unique_id() != old_id, "new peer id %d" % multiplayer.get_unique_id())
		await wait_until(func(): return Net.players.size() == 4, 10.0, "re-joined registry has 4 players")
		check(Net.get_player_name(multiplayer.get_unique_id()) == my_name, "kept my name '%s'" % my_name)


# =================================================================================================== 5TH PLAYER

func _overflow_main() -> void:
	var err := Game.start_join("127.0.0.1", port, NAMES["x"])
	check(err == OK, "5th player: start_join")
	await wait_until(func(): return Game.world == null, 20.0, "5th player sent back to the menu")
	await wait_frames(2)
	var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	var status := String(menu.call("get_status")) if menu != null else ""
	check(status.contains("Server is full"), "menu says why: '%s'" % status)
	check(Game.local_player == null and not Net.is_online(), "5th player never got a Player, offline")
	check(not Game.is_ui_locked(), "no UI lock left (connecting overlay gone)")
	finish()
