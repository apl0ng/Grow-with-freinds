extends "res://tools/tests/qa_base.gd"
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
##         other is told "Someone is holding this", no duplicate items; a server-side "Hands full" denial
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
const CHECK_TIMEOUT := 4.0
const ACK_TIMEOUT := 12.0
## Late joiner must converge within this many ms after its Player spawned (task requirement: 2 s).
const LATE_JOIN_LIMIT_MS := 2000

var role: String = "host"
var who: String = ""
var port: int = 7950

# --- host ---
var _seq: int = 0
var _acks: Dictionary = {}          # seq -> Dictionary
var _ids: Dictionary = {}           # "a"/"b"/"c" -> peer id
var _connects: Array[int] = []      # every peer_connected seen by the host
var _disconnects: Array[int] = []

# --- client ---
var _queue: Array = []              # [seq, action, args]
var _stop: bool = false
var _spawn_msec: int = -1
var _timeline: Array = []           # [msec since spawn, canonical]
var _left_on_purpose: bool = false


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
	await wait_until(func(): return Game.local_player != null, 5.0, "host player spawned")
	await wait_until(func(): return items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans, 3.0, "starting cans spawned")
	print("QA4P_HOST_READY")

	step("waiting for Alpha + Bravo")
	if not await wait_until(func(): return _peer_named("a") > 0 and _peer_named("b") > 0, 40.0, "Alpha and Bravo registered"):
		await _abort(); return
	_ids["a"] = _peer_named("a")
	_ids["b"] = _peer_named("b")
	await wait_until(func(): return Game.world.get_player(_ids["a"]) != null and Game.world.get_player(_ids["b"]) != null, 5.0, "their Player nodes exist on the host")
	await wait_sec(0.5)
	await checkpoint("joined", ["a", "b"])

	step("start round")
	GameState.request_start_round()
	check(GameState.is_playing() and GameState.round_number == 1, "round 1 PLAYING")
	await checkpoint("round started", ["a", "b"])

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
	check(loser_toasts.has("Someone is holding this") or loser_toasts.has("Hands full"),
			"loser (%s) was told why: %s" % [NAMES[l], loser_toasts])
	check(Game.world.items.get_held_by(_ids[l]) == null, "loser holds nothing on the host")
	check(items_of(Const.ITEM_WATERING_CAN).size() == 2 and Game.world.items.get_items().size() == 2, "still exactly 2 items (no duplicates)")
	await checkpoint("after the race", ["a", "b"])

	step("(a2) server-side denial: winner asks for the second can with full hands (prediction bypassed)")
	r = await run_cmd(_ids[w], "raw_pickup_request", {"item": String(can_b.name)})
	check(can_b.holder_id == 0, "second can stays on the floor")
	check((r.get("toasts", []) as Array).has("Hands full"), "winner got 'Hands full' from the server: %s" % [r.get("toasts", [])])

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
		check((ack_water.get("toasts", []) as Array).has("Needs a seed"), "water-before-plant refused with 'Needs a seed' %s" % [ack_water.get("toasts", [])])
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
	await checkpoint("mid-growth, 3 items held", ["a", "b"])

	# ---------------------------------------------------------------- (d) late joiner
	step("(d) Charlie joins late (items held, plot mid-growth)")
	print("QA4P_LAUNCH_LATE")
	if not await wait_until(func(): return _peer_named("c") > 0, 40.0, "Charlie registered"):
		await _abort(); return
	_ids["c"] = _peer_named("c")
	await wait_until(func(): return Game.world.get_player(_ids["c"]) != null, 5.0, "Charlie's Player node exists on the host")
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

	step("grow to READY; Charlie harvests and sells")
	Config.growth_speed_override = 25.0
	await wait_until(func(): return p1.stage == GrowPlot.Stage.READY, 15.0, "plot 1 READY")
	Config.growth_speed_override = 0.0
	await checkpoint("ready", ["a", "b", "c"])
	r = await run_cmd(_ids["c"], "goto_station", {"station": "GrowPlot1"})
	r = await run_cmd(_ids["c"], "interact", {"station": "GrowPlot1"})
	var product := Game.world.items.get_held_by(_ids["c"])
	check(product is Product and product.get(&"strain_id") == &"budget", "Charlie harvested a Budget Bud product")
	check(p1.stage == GrowPlot.Stage.EMPTY, "plot 1 EMPTY after the harvest")
	await checkpoint("harvested", ["a", "b", "c"])
	var money_before := GameState.money
	r = await run_cmd(_ids["c"], "goto_station", {"station": "TurnInStation"})
	r = await run_cmd(_ids["c"], "interact", {"station": "TurnInStation"})
	check(GameState.money == money_before + 60 and GameState.round_sales == 60, "sale +$60 (money %d, sold %d)" % [GameState.money, GameState.round_sales])
	check(items_of(Const.ITEM_PRODUCT).is_empty(), "product gone")
	await checkpoint("sold", ["a", "b", "c"])

	# ---------------------------------------------------------------- (e) + (h) leave holding a packet, re-join
	step("(e) %s leaves (return_to_menu) while holding the purple packet" % NAMES[l])
	var leaver: int = _ids[l]
	var leaver_player := Game.world.get_player(leaver)
	var leaver_feet := leaver_player.global_position if leaver_player != null else Vector3.INF
	var packet := Game.world.items.get_held_by(leaver)
	check(packet is SeedPacket, "%s holds the packet before leaving" % NAMES[l])
	cmd(leaver, "leave_rejoin", {"delay": 4.0})
	await wait_until(func(): return not Net.players.has(leaver), 5.0, "players dict shrank (leaver gone)")
	await wait_until(func(): return Game.world.get_player(leaver) == null, 3.0, "leaver's Player node despawned on the host")
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
	await wait_until(func(): return Game.world.get_player(_ids[l]) != null, 5.0, "re-joined Player node exists")
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
	r = await run_cmd(_ids["a"], "goto_station", {"station": "TurnInStation"})
	r = await run_cmd(_ids["a"], "interact", {"station": "TurnInStation"})
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "Alpha's sale met the quota -> ROUND_SUCCESS")
	await checkpoint("round success", ["a", "b", "c"], true)
	GameState.request_next_round()
	check(GameState.round_number == 2 and GameState.is_playing() and GameState.quota == Config.balance.quota_for_round(2),
			"host: round 2 PLAYING, quota %d" % Config.balance.quota_for_round(2))
	await checkpoint("round 2", ["a", "b", "c"], true)

	# ---------------------------------------------------------------- wrap up
	step("clients leave one by one (simultaneous drops are covered by qa_mp_robust)")
	for k in ["a", "b", "c"]:
		var id: int = _ids[k]
		cmd(id, "finish", {})
		await wait_until(func(): return not Net.players.has(id), 8.0, "%s left" % NAMES[k])
	await wait_until(func(): return Net.players.size() == 1, 5.0, "every client left")
	await wait_until(func(): return Game.world.get_players().size() == 1, 3.0, "only the host's Player node remains")
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

func cmd(peer: int, action: String, args: Dictionary = {}) -> int:
	_seq += 1
	_rpc_cmd.rpc_id(peer, _seq, action, args)
	return _seq

func await_ack(seq: int, timeout: float = ACK_TIMEOUT) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while not _acks.has(seq) and Time.get_ticks_msec() - t0 < timeout * 1000.0:
		await get_tree().process_frame
	if not _acks.has(seq):
		check(false, "no answer to command #%d within %.0f s" % [seq, timeout])
		return {}
	return _acks[seq]

func run_cmd(peer: int, action: String, args: Dictionary = {}, timeout: float = ACK_TIMEOUT) -> Dictionary:
	return await await_ack(cmd(peer, action, args), timeout)

## Sends two commands in the same frame and waits for both.
func run_both(k1: String, a1: String, args1: Dictionary, k2: String, a2: String, args2: Dictionary) -> Array:
	var s1 := cmd(_ids[k1], a1, args1)
	var s2 := cmd(_ids[k2], a2, args2)
	return [await await_ack(s1), await await_ack(s2)]

## Every listed client must converge to the host's canonical state (and, with ui=true, show consistent UI).
func checkpoint(tag: String, keys: Array, ui: bool = false) -> void:
	var expect := canonical_state()
	var seqs := {}
	for k in keys:
		seqs[k] = cmd(_ids[k], "state", {"expect": expect, "timeout": CHECK_TIMEOUT, "ui": ui})
	for k in keys:
		var r := await await_ack(seqs[k], CHECK_TIMEOUT + 4.0)
		var ok := bool(r.get("ok", false))
		check(ok, "[%s] %s sees the host state (%d ms)%s" % [tag, NAMES[k], int(r.get("ms", -1)),
				"" if not ui else ", UI ok" if bool(r.get("ui_ok", true)) else ", UI MISMATCH: " + str(r.get("ui", ""))])
		if ui and ok:
			check(bool(r.get("ui_ok", true)), "[%s] %s UI consistent with GameState %s" % [tag, NAMES[k], r.get("ui", "")])
		if not ok:
			print("      host : " + expect)
			print("      %-5s: %s" % [k, str(r.get("state", "<no answer>"))])

@rpc("any_peer", "call_remote", "reliable")
func _rpc_ack(seq: int, info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	_acks[seq] = info


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
	# Command loop until "finish" (or the host goes away).
	while not _stop:
		if _queue.is_empty():
			if Game.world == null and not _left_on_purpose:
				check(false, "lost the session unexpectedly")
				break
			await get_tree().process_frame
			continue
		var c: Array = _queue.pop_front()
		await _execute(int(c[0]), String(c[1]), c[2])
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

@rpc("authority", "call_remote", "reliable")
func _rpc_cmd(seq: int, action: String, args: Dictionary) -> void:
	# Race actions run right here, inside the network poll that delivered them, so both clients' requests
	# leave in the same frame as the host's command.
	if action == "grab_now":
		var it := _item(String(args.get("item", "")))
		var t := toasts.size()
		if it != null:
			it.interact(Game.local_player)
		_queue.append([seq, "grab_wait", {"item": String(args.get("item", "")), "t": t}])
		return
	if action == "interact_now":
		var st: Interactable = station(String(args.get("station", "")))
		var t2 := toasts.size()
		if st != null:
			st.interact(Game.local_player)
		_queue.append([seq, "settle", {"t": t2}])
		return
	_queue.append([seq, action, args])

func _ack(seq: int, info: Dictionary) -> void:
	if Net.is_online():
		_rpc_ack.rpc_id(1, seq, info)

func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	match action:
		"state":
			var expect := String(args.get("expect", ""))
			var t0 := Time.get_ticks_msec()
			var ok := await _wait_state(expect, float(args.get("timeout", CHECK_TIMEOUT)))
			var info := {"ok": ok, "state": canonical_state(), "ms": Time.get_ticks_msec() - t0}
			if bool(args.get("ui", false)):
				var ui := _ui_report()
				info["ui_ok"] = ui == ""
				info["ui"] = ui
			if not ok:
				check(false, "state mismatch with the host")
			_ack(seq, info)
		"goto_item":
			var it := _item(String(args.get("item", "")))
			if it != null:
				stand_near(it, 0.7)
			await wait_sec(0.45)
			_ack(seq, {"ok": it != null})
		"goto_station":
			stand_near(station(String(args.get("station", ""))), 1.2)
			await wait_sec(0.45)
			_ack(seq, {"ok": true})
		"grab_wait":
			var it := _item(String(args.get("item", "")))
			# Wait until the holder is known here and any denial had time to arrive.
			await wait_until_quiet(func(): return it != null and it.holder_id != 0, 3.0)
			await wait_sec(0.3)
			var mine := it != null and it.holder_id == multiplayer.get_unique_id()
			_ack(seq, {"mine": mine, "holder": it.holder_id if it != null else -1, "toasts": _toasts_since(int(args.get("t", 0)))})
		"raw_pickup_request":
			# Bypass the local can_interact() prediction: the server must refuse (hands full).
			var it := _item(String(args.get("item", "")))
			if it != null:
				stand_near(it, 0.7)
				await wait_sec(0.45)
				it._rpc_request_interact.rpc_id(1)
			await wait_sec(0.5)
			_ack(seq, {"toasts": _toasts_since(t)})
		"settle":
			await wait_sec(0.5)
			_ack(seq, {"toasts": _toasts_since(int(args.get("t", 0)))})
		"interact":
			var st: Interactable = station(String(args.get("station", "")))
			if st != null:
				st.interact(me)
			await wait_sec(0.5)
			_ack(seq, {"toasts": _toasts_since(t)})
		"buy":
			var shop: ShopCounter = station("ShopCounter")
			stand_near(shop, 1.3)
			await wait_sec(0.45)
			shop.request_buy_seed(StringName(String(args.get("seed", ""))))
			var got := await wait_until_quiet(func():
				var h := me.get_held_item()
				return h is SeedPacket and String(h.strain_id) == String(args.get("seed", "")), 3.0)
			_ack(seq, {"ok": got, "toasts": _toasts_since(t)})
		"late_check":
			await _late_check(seq, String(args.get("expect", "")))
		"leave_rejoin":
			await _leave_and_rejoin(float(args.get("delay", 4.0)))
		"finish":
			_left_on_purpose = true
			Game.return_to_menu()
			await wait_frames(3)
			_check_menu_clean("after finish")
			_stop = true
		_:
			_ack(seq, {"ok": false, "error": "unknown action " + action})

func _wait_state(expect: String, timeout: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout * 1000.0:
		if canonical_state() == expect:
			return true
		await get_tree().process_frame
	return canonical_state() == expect

## Like wait_until() but records no check.
func wait_until_quiet(pred: Callable, timeout_sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_sec * 1000.0:
		if bool(pred.call()):
			return true
		await get_tree().process_frame
	return bool(pred.call())

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
	_ack(seq, {"ok": ok, "ms": first_ok, "state": canonical_state(), "visual_ok": visual == "", "visual": visual})

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
	for i in range(1, 7):
		var p := plot(i)
		var pv: Node = p.get_node("%Plant")
		if int(pv.get(&"_stage")) != int(p.stage):
			bad.append("plot %d visual stage %d != %d" % [i, int(pv.get(&"_stage")), p.stage])
	return "" if bad.is_empty() else "; ".join(bad)

## "" when the HUD / overlays agree with GameState on this peer.
func _ui_report() -> String:
	var bad: PackedStringArray = []
	var hud: HUD = Game.world.get_node_or_null("HUD") as HUD
	if hud == null:
		return "no HUD"
	if hud.money_label.text != HUD.format_money(GameState.money):
		bad.append("money label '%s'" % hud.money_label.text)
	if hud.round_label.text != "ROUND %d" % GameState.round_number:
		bad.append("round label '%s'" % hud.round_label.text)
	var want_quota := "SOLD %s / %s" % [HUD.format_money(GameState.round_sales), HUD.format_money(GameState.quota)]
	if hud.quota_label.text != want_quota:
		bad.append("quota label '%s' != '%s'" % [hud.quota_label.text, want_quota])
	var over := GameState.is_round_over()
	if hud.round_end.visible != over:
		bad.append("round-end overlay visible=%s in %s" % [hud.round_end.visible, GameState.get_phase_name()])
	if Game.is_ui_locked_by(&"round_end") != over:
		bad.append("round_end ui lock=%s" % Game.is_ui_locked_by(&"round_end"))
	if over and hud.round_end.primary_button.visible:
		bad.append("client sees the host-only button")
	return "; ".join(bad)

func _leave_and_rejoin(delay: float) -> void:
	var my_name: String = NAMES.get(who, "Client")
	var old_id := multiplayer.get_unique_id()
	_left_on_purpose = true
	Game.return_to_menu()
	await wait_frames(3)
	_check_menu_clean("after leaving")
	await wait_sec(delay)
	_left_on_purpose = false
	_spawn_msec = -1
	var err := Game.start_join("127.0.0.1", port, my_name)
	check(err == OK, "re-join started")
	if await wait_until(func(): return Game.local_player != null, 20.0, "re-joined (local Player spawned)"):
		check(multiplayer.get_unique_id() != old_id, "new peer id %d" % multiplayer.get_unique_id())
		await wait_until(func(): return Net.players.size() == 4, 5.0, "re-joined registry has 4 players")
		check(Net.get_player_name(multiplayer.get_unique_id()) == my_name, "kept my name '%s'" % my_name)

func _check_menu_clean(tag: String) -> void:
	check(Game.world == null and Game.local_player == null, "%s: world freed" % tag)
	check(GameState.phase == GameState.Phase.MENU and GameState.money == 0, "%s: GameState back to MENU" % tag)
	check(Net.players.is_empty() and not Net.is_online(), "%s: offline, registry empty" % tag)
	check(not Game.is_ui_locked(), "%s: no UI lock left" % tag)
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "%s: mouse visible" % tag)
	check(get_tree().get_first_node_in_group(Game.MENU_GROUP) != null, "%s: main menu shown" % tag)

func _item(item_name: String) -> Item:
	if Game.world == null or item_name == "":
		return null
	return Game.world.items.get_node_or_null(NodePath(item_name)) as Item

func _toasts_since(t: int) -> Array:
	var out := []
	for i in range(t, toasts.size()):
		out.append(String(toasts[i][0]))
	return out


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
