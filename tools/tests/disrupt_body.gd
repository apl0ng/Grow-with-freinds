extends "res://tools/tests/qa_base.gd"
## M12 disrupt suite (disrupt agent): the three interruptions on a single headless host with fake workers
## (Net.players + World.server_spawn_player, no owning peer). Deterministic: time is advanced with Events.tick().
##   kinds / weights / picker, --first-event with the new kinds, the head count (the Boss walks to the line and stands
##   there, the absent worker is written up, the one at the line and the one in the back room are not, he walks back,
##   late-join replay), the water main (synced pressure, prompt, refills refused on both sides, restored), the
##   shortage (the most-planted strain, synced, purchases refused server-side, another strain sells, the card, cleared),
##   force end / shift end / game reset / menu.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/disrupt_body.gd --port=7959 --events --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const ROUTE_RAY_HEIGHT := 1.0

var _started: Array = []      # [kind, params]
var _ended: Array = []        # [kind]
var _written: Array = []      # [peer, reason, count]
var _spotted: Array = []      # [peer, reason]
var _world: World
var _room: Room
var _boss: ShopkeeperNPC
var _well: Well
var _counter: ShopCounter


func _run() -> void:
	_label = "disrupt"
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.worker_spotted.connect(func(p: int, r: String) -> void: _spotted.append([p, r]))
	GameState.worker_written_up.connect(func(p: int, r: String, c: int) -> void: _written.append([p, r, c]))
	var b: BalanceConfig = Config.balance

	step("kinds + weights")
	check(Config.has_arg("events") and Events.are_events_enabled(), "this suite runs with --events")
	check(Events.KINDS.size() == 14 and Events.KINDS.has(Events.EVENT_HEADCOUNT) and Events.KINDS.has(Events.EVENT_WATER_OFF) and Events.KINDS.has(Events.EVENT_SHORTAGE), "KINDS: the four M10 kinds + headcount, water_off, shortage (+ the two M14 mayhem kinds + the three M15 mayhem2 kinds + the two M17 mayhem3 kinds)")
	var total := 0
	for k in Events.KINDS:
		total += int(Events.WEIGHTS.get(k, 0))
	check(total == 100, "weights sum to 100 (%d)" % total)
	# M14 mayhem rebalanced the weights to make room for the leak and the drive-by (tools/tests/mayhem_body.gd); M15
	# mayhem2 did it again for the raid, the sprinklers and the collection, M17 mayhem3 for the scale and the phone
	# (tools/tests/mayhem3_body.gd pins all fourteen).
	var expected := {Events.EVENT_INSPECTION: 20, Events.EVENT_POWER_CUT: 12, Events.EVENT_AUDIT: 7, Events.EVENT_RAT: 6,
			Events.EVENT_HEADCOUNT: 9, Events.EVENT_WATER_OFF: 6, Events.EVENT_SHORTAGE: 5}
	var weights_ok := true
	for k in expected:
		if int(Events.WEIGHTS.get(k, -1)) != int(expected[k]):
			weights_ok = false
	check(weights_ok, "weights: inspection 20 / power_cut 12 / audit 7 / rat 6 / headcount 9 / water_off 6 / shortage 5")
	var kinds_seen: Dictionary = {}
	var repeats := 0
	for k in Events.KINDS:
		for i in 60:
			var pick := Events.pick_kind(k)
			kinds_seen[pick] = true
			if pick == k or not Events.KINDS.has(pick):
				repeats += 1
	check(repeats == 0, "pick_kind() never repeats the previous kind and stays in KINDS")
	check(kinds_seen.size() == Events.KINDS.size(), "pick_kind() reaches every kind (%d seen)" % kinds_seen.size())
	check(Story.line("headcount") == "Head count. The line. Now." and Story.line("water_off") == "Water main is off." and Story.line("shortage").contains("%s") and Story.line("absent").contains("%s"), "Story has the interruption lines")

	step("hosting")
	Game.start_host("Tester", port_arg(7959))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_boss = _room.get_station("ShopCounter").get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC
	_well = _room.get_station("Well") as Well
	_counter = _room.get_station("ShopCounter") as ShopCounter
	check(_boss != null and _well != null and _counter != null, "the Boss, the Well and the ShopCounter exist")
	for id in [2, 3, 4]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	check(_world.get_players().size() == 4, "host + 3 fake workers spawned")

	step("the line")
	check(_room.get_node_or_null(^"Decor/HeadcountSpot") is Marker3D, "Decor/HeadcountSpot is a Marker3D")
	var spot := _room.get_headcount_spot()
	var counter_pos := _counter.global_position
	check(_room.get_bounds().grow(0.01).has_point(Vector3(spot.x, 1.0, spot.z)) and absf(spot.y) < 0.01, "the spot is on the floor inside the room (%s)" % spot)
	check(spot.z > counter_pos.z + 1.0 and spot.z < counter_pos.z + 3.0 and absf(spot.x - counter_pos.x) < 1.5, "in front of the counter (counter %s)" % counter_pos)
	var route := _room.get_headcount_route()
	check(route.size() >= 2 and route[route.size() - 1].distance_to(spot) < 0.001, "the way to the line has %d points and ends on the spot" % route.size())
	var space := _world.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	var door := _room.get_backroom_door()
	if door != null:
		for c in door.find_children("*", "CollisionObject3D", true, false):
			exclude.append((c as CollisionObject3D).get_rid())
	var blocked: PackedStringArray = []
	for i in range(1, route.size()):
		var from := route[i - 1] + Vector3.UP * ROUTE_RAY_HEIGHT
		var to := route[i] + Vector3.UP * ROUTE_RAY_HEIGHT
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD, exclude))
		if not hit.is_empty():
			blocked.append("%d-%d hits %s" % [i, i + 1, (hit["collider"] as Node).get_path()])
	check(blocked.is_empty(), "every leg to the line is clear on LAYER_WORLD at 1 m (door excluded) %s" % [blocked])
	var home := _boss.global_position
	var from_home := home + Vector3.UP * ROUTE_RAY_HEIGHT
	var leg0 := space.intersect_ray(PhysicsRayQueryParameters3D.create(from_home, route[0] + Vector3.UP * ROUTE_RAY_HEIGHT, Const.LAYER_WORLD, exclude))
	check(leg0.is_empty(), "his first leg (home -> P1) is clear too")
	check(not Events.server_start_event(Events.EVENT_HEADCOUNT), "no event while WAITING")

	step("shift start")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(600)

	await _test_first_event()
	await _test_headcount(b)
	await _test_water_off(b)
	await _test_shortage(b)
	await _test_force_end_and_reset(b)
	finish()


# --- --first-event --------------------------------------------------------------------------------------------------

func _test_first_event() -> void:
	step("--first-event")
	for kind: StringName in [Events.EVENT_HEADCOUNT, Events.EVENT_WATER_OFF, Events.EVENT_SHORTAGE]:
		Config.user_args["first-event"] = String(kind)
		Events.set(&"_forced_first_used", false)
		Events.set(&"_next_in", 0.5)
		_started.clear()
		Events.tick(1.0)
		check(Events.active_event == kind and _started.size() == 1 and _started[0][0] == kind, "--first-event=%s starts a %s" % [kind, Events.active_event])
		Events.server_end_event()
		await wait_frames(2)
		if _boss.is_walking():
			await wait_until(func() -> bool: return not _boss.is_walking(), 3.0, "the Boss stopped")
	Config.user_args.erase("first-event")
	Config.user_args.erase("events")   # the scheduler stays quiet from here (server_start_event does not need it)
	Events.set(&"_next_in", -1.0)
	check(not Events.are_events_enabled() and not Events.is_event_active(), "scheduler off, nothing running")
	_started.clear()
	_ended.clear()


# --- head count -----------------------------------------------------------------------------------------------------

func _test_headcount(b: BalanceConfig) -> void:
	step("head count")
	_started.clear()
	_ended.clear()
	_written.clear()
	_spotted.clear()
	var spot := _room.get_headcount_spot()
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	var w4 := _world.get_player(4)
	var me: Player = Game.local_player
	_put(w2, spot + Vector3(0.6, 0.0, 0.4))         # at the line
	_put(w3, Vector3(6.0, 0.0, 2.0))                 # far side of the room (the grow area)
	_put(w4, Vector3(6.0, 0.0, -2.0))                # far too, but in the back room
	me.velocity = Vector3.ZERO
	me.global_position = spot + Vector3(-0.6, 0.05, 0.4)
	check(GameState.server_send_to_backroom(4, 60.0), "worker 4 sits in the back room")
	await wait_frames(2)
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.headcount_sec) and p.get("spot", null) is Vector3 and (p.get("spot") as Vector3).distance_to(spot) < 0.001 and p.has("speed"), "params {seconds: headcount_sec, spot, speed} (%s)" % [p])
	check(Events.is_event_active(Events.EVENT_HEADCOUNT) and _boss.is_walking() and not _boss.is_at_post(), "the Boss sets off")
	var speed := float(p.get("speed", 1.6))
	var there := _boss.get_walk_length()
	check(there > 1.0 and there / speed <= b.headcount_sec * Events.HEADCOUNT_ARRIVE_FRACTION + 0.01, "the walk (%.1f m at %.2f m/s) fits the first half of the count" % [there, speed])
	var clip := _boss.get_node_or_null(^"Clipboard") as Node3D
	check(clip != null and clip.visible, "clipboard in hand")
	await wait_until(func() -> bool: return _boss.is_at_post(), there / speed + 3.0, "he arrives at the line")
	check(_boss.global_position.distance_to(spot) < 0.15, "standing on the spot (%.2f m)" % _boss.global_position.distance_to(spot))
	check(_boss.get_facing().z > 0.7, "facing the room (%s)" % _boss.get_facing())
	await wait_sec(0.5)
	check(_boss.is_at_post() and not _boss.is_walking() and _boss.global_position.distance_to(spot) < 0.15, "and stays there")
	check(clip != null and clip.visible, "clipboard still in hand while he counts")
	check(Events.is_event_active(Events.EVENT_HEADCOUNT) and Events.get_event_time_left() > 0.0, "the count still runs (%.1f s)" % Events.get_event_time_left())
	check(not _room.is_backroom_door_open(), "the booth door shut behind him")
	var money0 := GameState.money
	Events.tick(b.headcount_sec + 0.1)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_HEADCOUNT, "event_ended(headcount) when the timer runs out")
	check(_count_written(3, Const.WRITE_UP_ABSENT) == 1, "the worker on the far side is written up: absent")
	check(_count_written(2, "") == 0, "the worker at the line is not")
	check(_count_written(4, "") == 0, "the worker in the back room is not")
	check(_count_written(1, "") == 0, "the host at the line is not")
	check(_spotted.size() == 1 and int(_spotted[0][0]) == 3 and String(_spotted[0][1]) == Const.WRITE_UP_ABSENT, "worker_spotted(3, absent) on this peer")
	check(GameState.money == money0 - b.write_up_fine, "one fine docked")
	check(GameState.get_stat(3, Const.STAT_WRITE_UPS) == 1 and GameState.get_write_ups(3) == 1, "his strike is on the books")
	check(_boss.is_walking() and not _boss.is_at_post(), "he walks back")
	await wait_until(func() -> bool: return not _boss.is_walking() and _boss.position.length() < 0.05, there / speed + 4.0, "back on his spot behind the window")
	check(clip != null and not clip.visible, "clipboard away")
	check(not _room.is_backroom_door_open(), "door shut")
	GameState.server_release_from_backroom(4)
	await wait_frames(2)

	step("head count: late-join replay")
	_started.clear()
	Events._rpc_event_started(Events.EVENT_HEADCOUNT, p, b.headcount_sec - 1.0)
	var along := _boss.get_walk_progress() * _boss.get_walk_length()
	check(Events.is_event_active(Events.EVENT_HEADCOUNT) and _boss.is_walking() and absf(along - speed) < 0.3, "replay 1 s in: %.2f m along the way (speed %.2f)" % [along, speed])
	Events._rpc_event_started(Events.EVENT_HEADCOUNT, p, 1.0)
	check(_boss.is_at_post() and _boss.global_position.distance_to(spot) < 0.15, "replay with 1 s left: already standing at the line")
	check(_started.size() == 2 and _started.back()[0] == Events.EVENT_HEADCOUNT and Events.get_event_time_left() <= 1.0, "event_started emitted on each replay, time left synced")
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _boss.is_walking(), "ended: he walks back from the line")
	await wait_until(func() -> bool: return not _boss.is_walking() and _boss.position.length() < 0.05, 12.0, "home again")
	_started.clear()
	_ended.clear()
	_written.clear()
	_spotted.clear()


# --- water main -----------------------------------------------------------------------------------------------------

func _test_water_off(b: BalanceConfig) -> void:
	step("water off")
	var me: Player = Game.local_player
	var water := _well.get_node_or_null(^"Visual/Water") as Node3D
	check(_well.has_pressure() and _well.get_prompt(me) == "Fill can", "pressure on: the usual prompt")
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, me.global_position, 1)
	await wait_frames(1)
	check(can != null and _world.items.get_held_by(1) == can, "the host holds a can with 1 charge")
	check(_well.can_interact(me), "a refill is allowed while the main is on")
	check(Events.server_start_event(Events.EVENT_WATER_OFF), "water off starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.water_off_sec) and p.size() == 1, "params {seconds: water_off_sec} (%s)" % [p])
	check(not _well.has_pressure() and not _well.pressure_on, "Well.pressure_on is false (synced setter)")
	check(_well.get_prompt(me) == "No pressure." and not _well.can_interact(me) and _well.get_denied_reason(me) == "No pressure.", "prompt 'No pressure', the refill is refused")
	check(not _well.server_fill_can(can) and int(can.get(&"charges")) == 1, "server_fill_can refuses: the can stays at 1")
	check(water != null and not water.visible, "the tank's water is gone")
	stand_near(_well, 1.3)
	await wait_frames(2)
	toasts.clear()
	_well._rpc_request_interact()
	await wait_frames(2)
	check(int(can.get(&"charges")) == 1 and toast_seen("No pressure"), "the interact request is refused server-side with the reason")
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() <= b.water_off_sec, "time left counts (%.1f)" % Events.get_event_time_left())
	Events.tick(b.water_off_sec + 0.1)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_WATER_OFF, "event_ended(water_off) when the timer runs out")
	check(_well.has_pressure() and _well.get_prompt(me).begins_with("Fill can") and _well.can_interact(me), "pressure restored, the prompt is back")
	check(water != null and water.visible, "the water is back in the tank")
	check(_well.server_fill_can(can) and int(can.get(&"charges")) == GrowPlot.get_can_capacity(can), "a refill works again")
	_world.items.server_despawn_item(can)
	await wait_frames(1)
	_started.clear()
	_ended.clear()


# --- supply shortage ------------------------------------------------------------------------------------------------

func _test_shortage(b: BalanceConfig) -> void:
	step("shortage")
	var seeds: Array[SeedDef] = b.seeds
	check(seeds.size() >= 2, "at least two strains (%d)" % seeds.size())
	var most: SeedDef = seeds[0]
	var other: SeedDef = seeds[1]
	for i in range(1, 7):
		var plot := _room.get_station("GrowPlot%d" % i) as GrowPlot
		if plot != null and plot.stage != GrowPlot.Stage.EMPTY:
			plot.server_reset()
	Events.tick(0.05)
	check(plot(1).server_plant(most.id) and plot(2).server_plant(most.id) and plot(3).server_plant(other.id), "planted %s twice and %s once" % [most.id, other.id])
	Events.tick(0.05)
	var counts := Events.get_planted_counts()
	check(int(counts.get(most.id, 0)) == 2 and int(counts.get(other.id, 0)) == 1, "plantings counted per strain this shift (%s)" % [counts])
	check(Events.pick_shortage_strain() == most.id, "the most-planted strain is picked")
	var me: Player = Game.local_player
	stand_near(_counter, 1.3)
	await wait_frames(2)
	check(_counter.get_shortage_strain() == &"" and _counter.get_prompt(me) == "Buy supplies", "nothing short before")
	var money0 := GameState.money
	check(Events.server_start_event(Events.EVENT_SHORTAGE), "shortage starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.shortage_sec) and StringName(str(p.get("strain", ""))) == most.id, "params {seconds: shortage_sec, strain: the most planted} (%s)" % [p])
	check(_counter.is_short(most.id) and not _counter.is_short(other.id) and _counter.get_shortage_strain() == most.id, "ShopCounter.shortage_strain synced")
	check(_counter.get_prompt(me).contains("out of stock") and _counter.get_prompt(me).contains(most.display_name), "the counter prompt names it (%s)" % _counter.get_prompt(me))
	var r := _counter.server_buy_seed(1, most.id)
	check(not bool(r["ok"]) and String(r["reason"]) == ShopCounter.REASON_OUT_OF_STOCK, "buying it is refused server-side: %s" % r["reason"])
	check(GameState.money == money0, "no cash taken")
	var r2 := _counter.server_buy_seed(1, other.id)
	check(bool(r2["ok"]), "another strain still sells (%s)" % r2["message"])
	var packet := _world.items.get_held_by(1)
	check(packet != null and packet.item_type == Const.ITEM_SEED_PACKET and StringName(str(packet.get(&"strain_id"))) == other.id, "its packet is in hand")
	if packet != null:
		_world.items.server_despawn_item(packet)
	await wait_frames(1)
	toasts.clear()
	_counter._rpc_request_buy_seed(most.id)
	await wait_frames(2)
	check(toast_seen("Out of stock"), "the request path answers 'Out of stock.'")
	_counter.open_shop_for(me)
	await wait_frames(2)
	var ui := _counter.get_shop_ui()
	check(ui != null and ui.is_open(), "the supply window opens")
	if ui != null:
		var card := ui.get_card(ShopCounter.KIND_SEED, most.id)
		var card2 := ui.get_card(ShopCounter.KIND_SEED, other.id)
		check(card != null and not card.is_buy_enabled() and card.get_buy_button().text == "OUT OF STOCK", "its card reads OUT OF STOCK and cannot buy")
		check(card2 != null and card2.is_buy_enabled(), "the other strain's card still buys")
		_counter.close_shop()
	await wait_frames(1)
	check(_barked(most.display_name), "the Boss named the strain (%s)" % Story.last_bark)

	step("shortage: late-join replay + end")
	_started.clear()
	Events._rpc_event_started(Events.EVENT_SHORTAGE, p, 5.0)
	check(Events.is_event_active(Events.EVENT_SHORTAGE) and Events.get_event_time_left() <= 5.0 and StringName(str(Events.get_event_params().get("strain", ""))) == most.id and _started.size() == 1, "replay: active, time left synced, strain in the params")
	Events.tick(5.1)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_SHORTAGE, "event_ended(shortage) when the timer runs out")
	check(_counter.get_shortage_strain() == &"" and not _counter.is_short(most.id) and _counter.get_prompt(me) == "Buy supplies", "cleared: nothing short")
	var r3 := _counter.server_buy_seed(1, most.id)
	check(bool(r3["ok"]), "it sells again (%s)" % r3["message"])
	var packet3 := _world.items.get_held_by(1)
	if packet3 != null:
		_world.items.server_despawn_item(packet3)
	await wait_frames(1)
	_started.clear()
	_ended.clear()


# --- force end / shift end / reset / menu ---------------------------------------------------------------------------

func _test_force_end_and_reset(b: BalanceConfig) -> void:
	step("force end")
	check(Events.server_start_event(Events.EVENT_WATER_OFF) and not _well.has_pressure(), "water off")
	check(not Events.server_start_event(Events.EVENT_SHORTAGE), "one at a time: a shortage is refused meanwhile")
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _well.has_pressure(), "a force-ended water_off restores the pressure")
	check(Events.server_start_event(Events.EVENT_SHORTAGE) and _counter.get_shortage_strain() != &"", "shortage")

	step("shift end")
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_frames(1)
	check(not Events.is_event_active() and _counter.get_shortage_strain() == &"" and _well.has_pressure(), "shift end ends the event and clears the shortage")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_SHORTAGE, "event_ended(shortage) at shift end")

	step("game reset")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	check(Events.get_planted_counts().is_empty(), "plantings reset with the shift")
	var dearest: SeedDef = null
	for s in b.seeds:
		if dearest == null or s.cost > dearest.cost:
			dearest = s
	check(dearest != null and Events.pick_shortage_strain() == dearest.id, "nothing planted: the dearest strain (%s)" % (dearest.id if dearest != null else &""))
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count")
	await wait_sec(0.4)
	check(_boss.is_walking(), "the Boss is on his way")
	check(not Events.server_start_event(Events.EVENT_WATER_OFF), "one at a time")
	_ended.clear()
	var written_before := _written.size()
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_HEADCOUNT, "game reset ends the head count")
	check(_well.has_pressure() and _counter.get_shortage_strain() == &"", "stations normal after the reset")
	await wait_until(func() -> bool: return not _boss.is_walking() and _boss.position.length() < 0.05, 5.0, "the Boss is home")
	check(_written.size() == written_before, "a cut-short head count writes nobody up")

	step("return to menu")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_WATER_OFF), "water off before leaving")
	_ended.clear()
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	check(not Events.is_event_active() and Events.get_event_time_left() == 0.0 and Events.get_planted_counts().is_empty(), "menu: events reset locally")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_WATER_OFF, "event_ended emitted on the way out")


# --- helpers --------------------------------------------------------------------------------------------------------

func _count_written(peer: int, reason: String) -> int:
	var n := 0
	for e in _written:
		if int(e[0]) == peer and (reason == "" or String(e[1]) == reason):
			n += 1
	return n


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


## True when a Story line containing `text` was shown (or queued as the last bark).
func _barked(text: String) -> bool:
	if Story.last_bark.contains(text) or Story.get_pending_text().contains(text):
		return true
	for t in Story.bark_log:
		if String(t).contains(text):
			return true
	return false
