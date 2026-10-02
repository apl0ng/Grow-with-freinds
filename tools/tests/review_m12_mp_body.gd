extends "res://tools/tests/qa_net_base.gd"
## M13 review of M12 (review agent): two-process regression test with a ROGUE client (a modified build) on the real
## ENet stack. The host launches the rogue process itself (same body, --role=rogue); the rogue's checks / error counts
## are reported back before it leaves. Driven by tools/tests/review_m12_mp.sh.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_m12_mp_body.gd --port=7964 --round-sec=900
## What it pins (every M12 request path and broadcast, over the wire):
##   S0  (on the way in) the rogue joins while a tray is turning, a hostile plant is mid-chase, the cabinet is
##       restocking, a flamethrower is firing and a head count runs: its copy of each matches the host's
##   S1  authority-only broadcasts sent by a client (Hostiles._rpc_spawn / _rpc_state / _rpc_poses / _rpc_bit /
##       _rpc_ate / _rpc_died / _rpc_despawn / _rpc_despawn_all / _rpc_replay, GrowPlot._rpc_scorched,
##       EmergencyCabinet._rpc_glass_break, Well._rpc_set_pressure, ShopCounter._rpc_set_shortage) are refused by the
##       engine on the host (expected ERROR lines), and Player._rpc_ignited (any_peer + a server-sender check) by the
##       handler: nothing changes on the host
##   S2  Flamethrower._rpc_request_fire: on an item the HOST holds (non-holder), a 300-request on/off burst on its own
##       (bounded, no fuel spent, sane end state), from the back room, after the shift ended
##   S3  the cabinet through the raw interact RPC: from across the room ("Too far."), cash short, hands full, five
##       requests in one frame (one flamethrower, one deposit)
##   S4  buying the short strain and refilling without pressure through the raw RPCs (the rogue's own copy of the
##       station state does not matter: the host decides)
## Every engine/script error fails the run unless announced (qa_base.gd).

var role: String = "host"
var _pid: int = -1
var _rogue: int = 0
var _spawned: Array = []
var _hostile_events: Array = []   # host: "bit" / "ate" / "died" signals after the join
var _scorched: Array = []
var _glass: Array = []
var _host_ignited: Array = []
var _fire_changes: int = 0


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	_label = "review_m12_mp:" + role
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _rogue_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.headcount_sec = 90.0 # the count must still run when the rogue process has started and joined
	var port := port_arg(7964)
	if not check(Game.start_host("Boss's Pet", port) == OK, "host on port %d" % port):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 10.0, "host world ready"):
		finish(); return
	var me: Player = Game.local_player
	var items := Game.world.items
	var cabinet := station("EmergencyCabinet") as EmergencyCabinet
	var well := station("Well") as Well
	var shop := station("ShopCounter") as ShopCounter
	# The host drives the plants by hand (Hostiles.tick), so the state the joiner must see holds still.
	Hostiles.set_physics_process(false)
	GameState.request_start_round()
	GameState.server_add_money(500 - GameState.money)

	step("S0 setup: a turning tray, a plant mid-chase, the cabinet restocking, a flame on, a head count")
	var ns: SeedDef = b.get_seed(&"nightshift")
	var ns_chance := ns.mutation_chance
	ns.mutation_chance = 1.0
	var p2 := plot(2)
	check(p2.server_plant(&"nightshift"), "GrowPlot 2 planted")
	p2.stage = GrowPlot.Stage.READY
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(-2.5, 0.02, 2.0)
	me.rotation = Vector3(0.0, PI * 0.5, 0.0) # facing -X: the flame goes at the west wall, away from everything
	await wait_frames(3)
	var hid := Hostiles.server_spawn(&"creeper", Vector3(0.2, 0.0, 2.0))
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.2)
	var h := Hostiles.get_hostile(hid) as HostilePlant
	check(h != null and h.state == HostilePlant.State.CHASE and h.get_target_index() == 1, "a plant chases the host's worker")
	check(p2.is_turning() and p2.turn_left > 1.0, "GrowPlot 2 is moving (%.1f s left)" % p2.turn_left)
	ns.mutation_chance = ns_chance
	check(cabinet.server_break(me) and cabinet.broken, "the host broke the glass (a plant is alive: no misuse)")
	var ft := items.get_held_by(1) as Flamethrower
	if not check(ft != null, "flamethrower in the host's hands"):
		finish(); return
	ft.server_set_fuel(300.0)
	check(ft.server_request_fire(1, true) and ft.firing, "the host fires at the wall")
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count running")

	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/tests/run_test.gd", "--", "--body=res://tools/tests/review_m12_mp_body.gd",
			"--role=rogue", "--port=%d" % port, "--timeout=120"])
	_pid = OS.create_process(OS.get_executable_path(), args)
	if not check(_pid > 0, "launched the rogue process"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.world.get_players().size() == 2, 40.0, "rogue joined (Player node on the host)"):
		_end(); return
	for p in Game.world.get_players():
		if p.peer_id != Const.SERVER_PEER_ID:
			_rogue = p.peer_id

	step("S0: what the late joiner sees")
	var r := await run_cmd(_rogue, "late_join_report")
	check(bool(r.get("turning", false)) and String(r.get("plot_status", "")) == "Moving" and int(r.get("plot_stage", -1)) == GrowPlot.Stage.READY, "rogue: GrowPlot 2 is READY and Moving (%s)" % r.get("plot_status", "?"))
	check(int(r.get("hostiles", 0)) == 1 and int(r.get("hostile_id", 0)) == hid and int(r.get("hostile_state", -1)) == h.state and StringName(r.get("hostile_strain", "")) == &"creeper",
			"rogue: one plant, same id / strain / state (%s)" % r.get("hostile_state_name", "?"))
	var rp: Vector3 = r.get("hostile_pos", Vector3.INF)
	check(rp.distance_to(h.global_position) < 0.3, "rogue: the plant stands where the host has it (%.2f m off)" % rp.distance_to(h.global_position))
	check(bool(r.get("cabinet_broken", false)) and int(r.get("restock_left", 0)) > 0 and int(r.get("restock_left", 0)) <= ceili(b.cabinet_restock_sec), "rogue: the cabinet is broken, restocking (%s s)" % r.get("restock_left", "?"))
	check(int(r.get("ft_holder", 0)) == 1 and bool(r.get("ft_firing", false)) and bool(r.get("ft_flame", false)), "rogue: the host's flamethrower is firing (flame particles on)")
	check(float(r.get("ft_fuel", 0.0)) > 200.0 and float(r.get("ft_fuel", 0.0)) < 300.0, "rogue: with the host's fuel, not a full fresh tank (%.1f s)" % float(r.get("ft_fuel", 0.0)))
	check(bool(r.get("headcount", false)) and float(r.get("event_left", 0.0)) > 1.0 and float(r.get("event_left", 99.0)) < b.headcount_sec - 1.0, "rogue: the head count runs, with the host's seconds left (%.1f)" % float(r.get("event_left", 0.0)))
	check(String(r.get("banner", "")).begins_with(HUD.TEXT_EVENT_HEADCOUNT), "rogue: banner '%s'" % r.get("banner", ""))
	check(bool(r.get("boss_out", false)), "rogue: the Boss is out of the booth (walking or at the line)")
	# The count ends while the joiner stands at its spawn: it was not on the floor when the count began.
	var strikes := GameState.get_write_ups(_rogue)
	Events.tick(b.headcount_sec + 1.0)
	await wait_frames(3)
	check(not Events.is_event_active(), "the head count ended on its timer")
	check(GameState.get_write_ups(_rogue) == strikes, "the joiner is not written up as absent for a count called before it joined")
	GameState.write_ups.clear()
	check(ft.server_request_fire(1, false) and not ft.firing, "the host stops the flame")
	ft.server_set_fuel(b.flamethrower_fuel_sec)

	step("S1: authority-only M12 broadcasts sent by a client")
	Hostiles.hostile_spawned.connect(func(id: int, _s: StringName, _p: Vector3) -> void: _spawned.append(id))
	Hostiles.hostile_bit.connect(func(id: int, peer: int) -> void: _hostile_events.append(["bit", id, peer]))
	Hostiles.hostile_ate.connect(func(id: int, idx: int) -> void: _hostile_events.append(["ate", id, idx]))
	Hostiles.hostile_died.connect(func(id: int, by: int) -> void: _hostile_events.append(["died", id, by]))
	p2.scorched.connect(func(by: int) -> void: _scorched.append(by))
	cabinet.glass_broken.connect(func(by: int) -> void: _glass.append(by))
	me.ignited.connect(func(by: int) -> void: _host_ignited.append(by))
	var pos0 := h.global_position
	var state0 := h.state
	var burns0 := GameState.get_stat(_rogue, Const.STAT_BURNS)
	var money0 := GameState.money
	var wu0 := GameState.get_stat(1, Const.STAT_WRITE_UPS) + GameState.get_stat(_rogue, Const.STAT_WRITE_UPS)
	# The engine refuses each of them on the host before any game code runs.
	for rpc_name: String in ["_rpc_spawn", "_rpc_state", "_rpc_poses", "_rpc_bit", "_rpc_ate", "_rpc_died", "_rpc_despawn", "_rpc_despawn_all", "_rpc_replay",
			"_rpc_scorched", "_rpc_glass_break", "_rpc_set_pressure", "_rpc_set_shortage"]:
		allow_error("RPC '%s' is not allowed on node" % rpc_name, 1, true)
	r = await run_cmd(_rogue, "spoof_authority", {"hostile": hid})
	await wait_frames(3)
	check(int(r.get("sent", 0)) == 14, "rogue sent 13 authority broadcasts and one _rpc_ignited on the host's Player node")
	check(errors.allowed_seen == 13, "the host's engine refused all 13 (%d error lines)" % errors.allowed_seen)
	clear_allowed_errors()
	check(Hostiles.count() == 1 and Hostiles.get_hostile(hid) == h and not h.is_dead() and h.state == state0 and h.global_position.distance_to(pos0) < 0.01,
			"host: the plant is where and what it was (state %s)" % h.get_state_name())
	check(_spawned.is_empty() and _hostile_events.is_empty() and Hostiles.get_hostile(99) == null, "host: no spawn, bite, eat or death signal %s %s" % [_spawned, _hostile_events])
	check(GameState.get_stat(_rogue, Const.STAT_BURNS) == burns0, "host: no STAT_BURNS for the rogue")
	check(_scorched.is_empty() and not p2.is_scorched() and p2.stage == GrowPlot.Stage.READY, "host: GrowPlot 2 not scorched")
	check(_glass.is_empty(), "host: no glass-break cosmetic")
	check(well.has_pressure() and shop.get_shortage_strain() == &"", "host: water main on, nothing out of stock")
	check(_host_ignited.is_empty() and not me.is_stunned(), "host: its worker was not set on fire by a client's _rpc_ignited")
	check(GameState.money == money0 and GameState.get_stat(1, Const.STAT_WRITE_UPS) + GameState.get_stat(_rogue, Const.STAT_WRITE_UPS) == wu0, "host: no cash moved, no write-up")
	Hostiles.server_despawn_all()
	p2.server_reset()
	Hostiles.tick(0.05)
	await wait_frames(2)

	step("S2: fire requests over the wire")
	ft.firing_changed.connect(func(_on: bool) -> void: _fire_changes += 1)
	r = await run_cmd(_rogue, "fire_raw", {"item": String(ft.name), "on": true})
	check(not ft.firing and _fire_changes == 0, "a fire request on the flamethrower the HOST holds does nothing")
	var rft := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": b.flamethrower_fuel_sec}, Vector3(1.0, 0.0, 3.0), _rogue) as Flamethrower
	if not check(rft != null and rft.holder_id == _rogue, "a flamethrower in the rogue's hands"):
		_end(); return
	var rogue_fire := [0]
	rft.firing_changed.connect(func(_on: bool) -> void: rogue_fire[0] = int(rogue_fire[0]) + 1)
	var t0 := Time.get_ticks_msec()
	r = await run_cmd(_rogue, "fire_burst", {"item": String(rft.name), "pairs": 150}, 30.0)
	var took := Time.get_ticks_msec() - t0
	await wait_physics(3)
	check(not rft.firing and rft.fuel >= b.flamethrower_fuel_sec - 0.3, "300 on/off requests in one frame: flame off, fuel %.1f s (nothing burnt for free)" % rft.fuel)
	check(int(rogue_fire[0]) <= 300 and took < 5000, "the host handled the burst in %d ms (%d state changes)" % [took, int(rogue_fire[0])])
	r = await run_cmd(_rogue, "fire_raw", {"item": String(rft.name), "on": true})
	check(rft.firing, "one honest request: the flame is on")
	check(GameState.server_send_to_backroom(_rogue, 60.0), "the rogue is sent to the back room while firing")
	await wait_physics(4)
	check(not rft.firing and rft.holder_id == 0, "the flame is out, the flamethrower is on the floor")
	check(items.server_give_item(rft, _rogue), "(the host puts it back in the rogue's hands, in the back room)")
	r = await run_cmd(_rogue, "fire_raw", {"item": String(rft.name), "on": true})
	await wait_physics(3)
	check(not rft.firing, "a fire request from the back room is refused")
	GameState.server_release_from_backroom(_rogue)
	await wait_frames(3)

	step("S3: the cabinet through the raw interact RPC")
	cabinet.server_restock()
	items.server_despawn_item(ft)
	await wait_frames(2)
	money0 = GameState.money
	r = await run_cmd(_rogue, "cabinet_raw", {"count": 1, "walk": false})
	check(not cabinet.broken and GameState.money == money0 and _has(r, "Too far."), "from across the room: refused, 'Too far.' %s" % [r.get("toasts", [])])
	r = await run_cmd(_rogue, "cabinet_raw", {"count": 1, "walk": true})
	check(not cabinet.broken and GameState.money == money0 and _has(r, EmergencyCabinet.REASON_HANDS_FULL), "at the cabinet, hands full: refused %s" % [r.get("toasts", [])])
	items.server_despawn_item(rft)
	await wait_frames(2)
	GameState.server_add_money(b.cabinet_deposit - 1 - GameState.money)
	r = await run_cmd(_rogue, "cabinet_raw", {"count": 1, "walk": true})
	check(not cabinet.broken and GameState.money == b.cabinet_deposit - 1 and _has(r, EmergencyCabinet.REASON_CASH_SHORT), "one dollar short: refused %s" % [r.get("toasts", [])])
	GameState.server_add_money(500 - GameState.money)
	Hostiles.server_spawn(&"budget", Vector3(8.6, 0.0, 6.0)) # something alive: no misuse write-up in the way
	_glass.clear()
	r = await run_cmd(_rogue, "cabinet_raw", {"count": 5, "walk": true})
	await wait_frames(2)
	check(items_of(Const.ITEM_FLAMETHROWER).size() == 1 and items.get_held_by(_rogue) is Flamethrower, "five requests in one frame: one flamethrower, in the rogue's hands")
	check(GameState.money == 500 - b.cabinet_deposit and _glass == [_rogue], "one deposit (%d), one glass break %s" % [GameState.money, _glass])
	check(GameState.get_write_ups(_rogue) == 0, "no write-up (a plant is alive)")
	Hostiles.server_despawn_all()

	step("S4: the short strain and the dry tank through the raw RPCs")
	items.server_despawn_item(items.get_held_by(_rogue))
	await wait_frames(2)
	shop.server_set_shortage(&"budget")
	money0 = GameState.money
	r = await run_cmd(_rogue, "buy_raw", {"seed": "budget"})
	check(GameState.money == money0 and items_of(Const.ITEM_SEED_PACKET).is_empty() and _has(r, ShopCounter.REASON_OUT_OF_STOCK), "the short strain is refused: 'Out of stock.' %s" % [r.get("toasts", [])])
	r = await run_cmd(_rogue, "buy_raw", {"seed": "purple"})
	check(GameState.money == money0 - b.get_seed(&"purple").cost and items.get_held_by(_rogue) is SeedPacket, "another strain sells")
	shop.server_set_shortage(&"")
	items.server_despawn_item(items.get_held_by(_rogue))
	await wait_frames(2)
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, Vector3(-4.0, 0.0, 0.0), _rogue) as Item
	well.server_set_pressure(false)
	r = await run_cmd(_rogue, "well_raw")
	check(int(can.get(&"charges")) == 1 and _has(r, Well.PROMPT_NO_PRESSURE), "no pressure: the refill is refused %s" % [r.get("toasts", [])])
	well.server_set_pressure(true)
	r = await run_cmd(_rogue, "well_raw")
	check(int(can.get(&"charges")) == GameState.get_can_capacity(), "pressure back: the same request fills the can")

	step("S5: after the shift ended")
	items.server_despawn_item(can)
	await wait_frames(2)
	rft = items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": b.flamethrower_fuel_sec}, Vector3(1.0, 0.0, 3.0), _rogue) as Flamethrower
	await wait_frames(2)
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	r = await run_cmd(_rogue, "fire_raw", {"item": String(rft.name), "on": true})
	await wait_physics(3)
	check(not rft.firing and rft.fuel == b.flamethrower_fuel_sec, "a fire request after the shift is refused")
	_end()


func _has(r: Dictionary, text: String) -> bool:
	for t in r.get("toasts", []):
		if String(t).contains(text):
			return true
	return false


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Collects the rogue's own result, lets it leave, waits for its process, then finishes the host.
func _end() -> void:
	if _rogue > 0 and _rogue in multiplayer.get_peers():
		var rep := await run_cmd(_rogue, "report", {}, 10.0)
		check(int(rep.get("fails", -1)) == 0 and int(rep.get("errors", -1)) == 0,
				"rogue process: %s checks failed, %s unexpected errors" % [rep.get("fails", "?"), rep.get("errors", "?")])
		cmd(_rogue, "finish")
	if _pid > 0:
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(_pid) and Time.get_ticks_msec() - t0 < 15000:
			await get_tree().process_frame
		check(not OS.is_process_running(_pid), "rogue process exited")
		if OS.is_process_running(_pid):
			OS.kill(_pid)
	finish()


# =================================================================================================== ROGUE

func _rogue_main() -> void:
	var port := port_arg(0)
	if not check(Game.start_join("127.0.0.1", port, "Rogue") == OK, "start_join on port %d" % port):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "rogue joined"):
		finish(); return
	await client_loop()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	match action:
		"late_join_report":
			await wait_until_quiet(func() -> bool: return Hostiles.count() >= 1 and Events.is_event_active(Events.EVENT_HEADCOUNT) and not items_of(Const.ITEM_FLAMETHROWER).is_empty(), 8.0)
			await wait_sec(0.5)
			var p2 := plot(2)
			var hs := Hostiles.get_hostiles()
			var h := hs[0] as HostilePlant if not hs.is_empty() else null
			var cab := station("EmergencyCabinet") as EmergencyCabinet
			var fts := items_of(Const.ITEM_FLAMETHROWER)
			var ft := fts[0] as Flamethrower if not fts.is_empty() else null
			var hud := Game.world.get_node_or_null("HUD") as HUD
			var counter := Game.world.room.get_station("ShopCounter")
			var boss := counter.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC if counter != null else null
			ack(seq, {
				"turning": p2.is_turning(), "plot_status": p2.get_status_text(), "plot_stage": int(p2.stage),
				"hostiles": hs.size(), "hostile_id": h.id if h != null else 0, "hostile_state": h.state if h != null else -1,
				"hostile_state_name": h.get_state_name() if h != null else "none", "hostile_strain": String(h.strain_id) if h != null else "",
				"hostile_pos": h.global_position if h != null else Vector3.INF,
				"cabinet_broken": cab.broken, "restock_left": cab.restock_left,
				"ft_holder": ft.holder_id if ft != null else 0, "ft_firing": ft != null and ft.firing, "ft_fuel": ft.fuel if ft != null else 0.0,
				"ft_flame": ft != null and ft._flame != null and ft._flame.emitting,
				"headcount": Events.is_event_active(Events.EVENT_HEADCOUNT), "event_left": Events.get_event_time_left(),
				"banner": hud.event_label.text if hud != null else "",
				"boss_out": boss != null and (boss.is_walking() or boss.is_at_post()),
			})
		"spoof_authority":
			# A modified client calling every authority-only M12 broadcast. call_local: they also run HERE (this
			# peer's own picture breaks); the host must refuse them all.
			var hid := int(args.get("hostile", 0))
			var p2 := plot(2)
			var cab := station("EmergencyCabinet") as EmergencyCabinet
			var well := station("Well") as Well
			var shop := station("ShopCounter") as ShopCounter
			var host_node: Player = Game.world.get_player(1)
			var sent := 0
			Hostiles._rpc_spawn.rpc(99, &"budget", Vector3(0.0, 0.0, 0.0), 0.0); sent += 1
			Hostiles._rpc_state.rpc(hid, HostilePlant.State.DEAD, Vector3(5.0, 0.0, 5.0), 0.0, 0); sent += 1
			Hostiles._rpc_poses.rpc([[hid, Vector3(5.0, 0.0, 5.0), 0.0]]); sent += 1
			Hostiles._rpc_bit.rpc(hid, 1); sent += 1
			Hostiles._rpc_ate.rpc(hid, 2); sent += 1
			Hostiles._rpc_died.rpc(hid, me.peer_id); sent += 1
			Hostiles._rpc_despawn.rpc(hid); sent += 1
			Hostiles._rpc_despawn_all.rpc(); sent += 1
			Hostiles._rpc_replay.rpc([]); sent += 1
			p2._rpc_scorched.rpc(me.peer_id); sent += 1
			cab._rpc_glass_break.rpc(me.peer_id); sent += 1
			well._rpc_set_pressure.rpc(false); sent += 1
			shop._rpc_set_shortage.rpc(&"budget"); sent += 1
			if host_node != null:
				host_node._rpc_ignited.rpc_id(1, me.peer_id); sent += 1   # any_peer: the handler's sender check refuses it
			await sync_with_host()
			check(Hostiles.count() == 0 and not well.has_pressure() and shop.get_shortage_strain() == &"budget", "rogue: its own copy took the spoofed state (call_local), as expected of a modified build")
			ack(seq, {"sent": sent})
		"fire_raw":
			var ft := item_named(String(args.get("item", ""))) as Flamethrower
			if ft != null:
				ft._rpc_request_fire.rpc_id(1, bool(args.get("on", true)))
			await sync_with_host()
			ack(seq, {"ok": ft != null})
		"fire_burst":
			var ft := item_named(String(args.get("item", ""))) as Flamethrower
			if ft != null:
				for i in int(args.get("pairs", 100)):
					ft._rpc_request_fire.rpc_id(1, true)
					ft._rpc_request_fire.rpc_id(1, false)
			await sync_with_host(20.0)
			ack(seq, {"ok": ft != null})
		"cabinet_raw":
			var cab := station("EmergencyCabinet") as EmergencyCabinet
			if bool(args.get("walk", false)):
				stand_near(cab, 1.2)
				await server_sees_me()
			for i in int(args.get("count", 1)):
				cab._rpc_request_interact.rpc_id(1)
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"toasts": toasts_since(t)})
		"buy_raw":
			var shop := station("ShopCounter") as ShopCounter
			stand_near(shop, 1.3)
			await server_sees_me()
			shop._rpc_request_buy_seed.rpc_id(1, StringName(String(args.get("seed", ""))))
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"toasts": toasts_since(t)})
		"well_raw":
			var well := station("Well") as Well
			stand_near(well, 1.4)
			await server_sees_me()
			well._rpc_request_interact.rpc_id(1)
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"toasts": toasts_since(t)})
		"report":
			ack(seq, {"fails": _fails, "errors": errors.errors.size()})
		_:
			await super(seq, action, args)
