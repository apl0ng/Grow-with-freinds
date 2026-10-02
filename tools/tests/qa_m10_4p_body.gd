extends "res://tools/tests/qa_m10_4p_base.gd"
## M10 4-player stress + robustness sweep (QA, task 10.8). One HOST + three CLIENTS as separate headless processes
## on the real game stack; driven by tools/tests/qa_m10_4p.sh; every process runs THIS script with a role:
##   --role=host                  the director: sends commands, compares every peer's view with its own
##   --role=client --who=a|b|c    Alpha / Bravo / Charlie (Charlie joins LATE, during the inspection, on QAM10_LAUNCH_LATE)
## Common args: --port=N --round-sec=900 --events --timeout=S. Cases (host side, asserted with ok/FAIL lines):
##   (4)  inspection: Alpha skims (written up, bundle confiscated everywhere), Bravo crouches behind a crate (spared),
##        the host loiters (written up after loiter_sec); Alpha to the back room; Charlie joins late (sees the walk,
##        the banner, the back-room dict); Alpha disconnects from the back room (released cleanly) and re-joins
##   (1)  four bundles thrown in one frame: rest within 4 s, same rest positions everywhere, none lost, hits == staggers
##   (2)  three chute shots at once: exactly one sale per bundle, money / stats identical everywhere
##   (3)  shove chains: from behind drops the item, a stunned worker's shove is refused, a double press shoves once
##   (5)  back room: lock + spectator camera + body at the spot on every peer, released by the shift timer; the host
##        in the back room while Alpha throws through its spot (no hit)
##   (6)  power cut: growth frozen, dark everywhere, Charlie re-joins dark, Alpha resets the breaker, a cut nobody
##        resets ends by itself
##   (rat) a rat eats a tray until Charlie walks up to it
##   (7)  voice under load: three talkers at 50 frames/s for 4 s while cans fly; back-room routing
##   (8)  chat / ping floods with hostile payloads: one accepted per sender, sanitized
##   (9)  churn: the shift ends + RETRY with cans in flight, a worker in the back room, the power out and a rat;
##        Charlie leaves from the back room; the host leaves during an inspection (last)
##   (10) a full 60 s --fast shift with the scheduler on, four bots working: stats + report identical everywhere

const PRODUCT := Const.ITEM_PRODUCT
const CAN := Const.ITEM_WATERING_CAN
const BUDGET_VALUE := 60

var _ids: Dictionary = {}
var _connects: Array[int] = []
var _disconnects: Array[int] = []
var _park := {"a": Vector3(-5.5, 0.05, 3.0), "b": Vector3(-5.5, 0.05, 4.2), "c": Vector3(-4.3, 0.05, 4.2), "host": Vector3(-4.3, 0.05, 3.0)}


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7960))
	_label = "m10_4p:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	multiplayer.peer_connected.connect(func(id: int) -> void: _connects.append(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: _disconnects.append(id))
	var b: BalanceConfig = Config.balance
	check(Config.has_arg("events") and Events.are_events_enabled(), "events allowed (--events)")
	# The scheduler stays quiet until the scheduled shift (case 10); every event below is started by hand.
	b.event_first_delay_sec = FAR_AWAY
	b.event_gap_min_sec = FAR_AWAY
	b.event_gap_max_sec = FAR_AWAY
	Config.growth_speed_override = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null, 10.0, "host player spawned")
	await wait_until(func() -> bool: return items_of(CAN).size() == b.starting_watering_cans, 10.0, "starting cans spawned")
	print("QAM10_HOST_READY")
	step("waiting for Alpha + Bravo")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0 and _peer_named("b") > 0, 40.0, "Alpha and Bravo registered"):
		await _abort(); return
	_ids["a"] = _peer_named("a")
	_ids["b"] = _peer_named("b")
	await wait_until(func() -> bool: return _player("a") != null and _player("b") != null, 10.0, "their Player nodes exist")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift 1 running")
	check(Events.get_next_event_in() > 1000.0, "scheduler parked (next event in %.0f s)" % Events.get_next_event_in())
	await wait_sec(0.5)
	await checkpoint("joined", ["a", "b"])

	await _case_inspection()
	if _ids.get("c", 0) <= 0:
		await _abort(); return
	await _case_throws()
	await _case_chute()
	await _case_shoves()
	await _case_backroom()
	await _case_power_cut()
	await _case_rat()
	await _case_voice()
	await _case_floods()
	await _case_churn_retry()
	await _case_churn_backroom_leave()
	await _case_full_shift()
	await _case_host_leaves()
	finish()


# ---------------------------------------------------------------- (4) inspection, late joiner, disconnect from the back room

func _case_inspection() -> void:
	step("(4) inspection: Alpha skims, Bravo crouches behind a crate, the host loiters")
	var b: BalanceConfig = Config.balance
	var room: Room = Game.world.room
	var items := Game.world.items
	var boss := _boss()
	if not check(boss != null, "the Boss exists"):
		return
	await run_both("a", "goto", {"pos": _park["a"]}, "b", "goto", {"pos": _park["b"]})
	_put_me(_park["host"], Vector3(0.0, 0.05, 0.0))
	_written.clear()
	_ev_started.clear()
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection started")
	check(Events.is_event_active(Events.EVENT_INSPECTION) and boss.is_walking(), "host: the Boss walks")
	var speed := float(Events.get_event_params().get("speed", 1.6))
	var route := room.get_inspection_route()
	# Freeze the host's copy 6 s into the route: deterministic sight checks (clients keep walking him for real).
	boss.walk_route(route, speed, 6.0)
	boss.set_process(false)
	await wait_frames(2)
	var eye := boss.get_eye_position()
	var facing := boss.get_facing()
	var floor_eye := Vector3(eye.x, 0.05, eye.z)
	var side := facing.cross(Vector3.UP).normalized()
	print("  (Boss frozen at %s facing %s)" % [floor_eye, facing])

	step("skimming: Alpha carries a bundle into his sight")
	var product := items.server_spawn_item(PRODUCT, {"strain_id": "budget", "amount": 1}, Vector3.ZERO, _ids["a"])
	check(product != null and product.holder_id == _ids["a"], "Alpha holds a bundle")
	var pname := String(product.name) if product != null else ""
	var money0 := GameState.money
	var r := await run_cmd(_ids["a"], "goto", {"pos": floor_eye + facing * 2.5, "look": floor_eye})
	await wait_until(func() -> bool: return _count_written(_ids["a"], Const.WRITE_UP_SKIMMING) >= 1, 4.0, "Alpha written up for skimming by the sight pass")
	await wait_until(func() -> bool: return item_named(pname) == null, 2.0, "the bundle is confiscated on the host")
	check(GameState.money == money0 - b.write_up_fine, "the fine was docked ($%d)" % b.write_up_fine)
	check(GameState.get_write_ups(_ids["a"]) == 1 and GameState.get_stat(_ids["a"], Const.STAT_WRITE_UPS) == 1, "one strike, STAT_WRITE_UPS 1")
	r = await run_cmd(_ids["a"], "goto", {"pos": floor_eye - facing * 3.0 + side * 1.0})
	check(_count_written(_ids["a"], "") == 1, "no second write-up on the way out")
	for k in ["a", "b"]:
		r = await run_cmd(_ids[k], "report_items", {"names": [pname]})
		var by_name: Dictionary = r.get("items_by_name", {})
		check(not bool(by_name.get(pname, {}).get("exists", true)), "%s: the bundle is gone" % NAMES[k])
		check(_written_in(r, _ids["a"], Const.WRITE_UP_SKIMMING) == 1, "%s saw worker_written_up(Alpha, skimming)" % NAMES[k])
		check(String(r.get("banner", "")).begins_with(HUD.TEXT_EVENT_INSPECTION), "%s: banner INSPECTION" % NAMES[k])

	step("line of sight: Bravo crouches behind a crate")
	var crate := StaticBody3D.new()
	crate.collision_layer = Const.LAYER_WORLD
	crate.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.4, 1.0, 0.3)
	shape.shape = box
	crate.add_child(shape)
	Game.world.add_child(crate)
	crate.global_position = floor_eye + facing * 2.2 + Vector3.UP * 0.5
	crate.look_at(crate.global_position + facing, Vector3.UP)
	await wait_frames(1)
	r = await run_cmd(_ids["b"], "goto", {"pos": floor_eye + facing * 3.0 + side * 0.4, "look": floor_eye, "crouch": true})
	check(bool(r.get("crouching", false)), "Bravo crouches")
	await wait_until(func() -> bool: return _player("b") != null and _player("b").crouching, 3.0, "host sees Bravo crouched")

	step("loitering: the host stands in his sight")
	_put_me(floor_eye + facing * 3.5 - side * 0.8, floor_eye)
	var t0 := Time.get_ticks_msec()
	await wait_until(func() -> bool: return _count_written(1, Const.WRITE_UP_LOITERING) >= 1, b.loiter_sec + 3.0, "the host is written up for loitering")
	var dt := float(Time.get_ticks_msec() - t0) / 1000.0
	check(dt >= b.loiter_sec - 0.6, "not before loiter_sec (%.1f s)" % dt)
	_put_me(floor_eye - facing * 3.0 - side * 1.0, floor_eye)
	check(_count_written(_ids["b"], "") == 0, "Bravo (crouched behind the crate, %.1f s in the cone) was never written up" % (dt + 1.0))

	step("Alpha is written up twice more: the back room, mid-inspection")
	_backroom_ev.clear()
	check(GameState.server_write_up(_ids["a"], Const.WRITE_UP_OTHER) == 2, "second strike")
	check(GameState.server_write_up(_ids["a"], Const.WRITE_UP_OTHER) == 0, "third strike: the back room")
	check(GameState.is_in_backroom(_ids["a"]) and GameState.get_write_ups(_ids["a"]) == 0, "Alpha in the back room, strikes cleared")
	var spot := room.get_backroom_transform(0).origin
	await wait_until(func() -> bool: return _player("a") != null and _player("a").global_position.distance_to(spot) < 0.5, 5.0, "host: Alpha's body at the BackRoomSpot")
	r = await run_cmd(_ids["a"], "backroom_check")
	check(bool(r.get("locked", false)) and bool(r.get("overlay", false)), "Alpha: UI lock + overlay")
	check(String(r.get("camera", "")) == SPECTATOR_NAME, "Alpha: spectator camera current (%s)" % r.get("camera", ""))

	step("Charlie joins late, during the inspection")
	print("QAM10_LAUNCH_LATE")
	if not await wait_until(func() -> bool: return _peer_named("c") > 0, 40.0, "Charlie registered"):
		return
	_ids["c"] = _peer_named("c")
	await wait_until(func() -> bool: return _player("c") != null, 10.0, "Charlie's Player node exists on the host")
	r = await run_cmd(_ids["c"], "late_inspection", {}, 15.0)
	check(bool(r.get("walking", false)), "Charlie: the Boss walks on his peer")
	check(String(r.get("active", "")) == String(Events.EVENT_INSPECTION), "Charlie: inspection active (banner state)")
	var params: Dictionary = r.get("params", {})
	check(params.has("seconds") and params.has("speed"), "Charlie: params carry seconds + speed")
	check(float(r.get("time_left", 0.0)) > 0.0 and float(r.get("time_left", 0.0)) <= Events.get_event_time_left() + 1.0, "Charlie: time left synced (%.1f vs host %.1f)" % [float(r.get("time_left", 0.0)), Events.get_event_time_left()])
	check(String(r.get("banner", "")).begins_with(HUD.TEXT_EVENT_INSPECTION), "Charlie: banner INSPECTION")
	check(String(r.get("backroom", "?")) == _backroom_sig(), "Charlie: back-room dict matches the host (%s)" % _backroom_sig())
	check(int(r.get("ms", 99999)) <= LATE_JOIN_LIMIT_MS, "Charlie saw the inspection %d ms after spawning" % int(r.get("ms", -1)))
	r = await run_cmd(_ids["c"], "goto", {"pos": _park["c"]})

	step("Alpha disconnects while in the back room")
	var old_a: int = _ids["a"]
	cmd(old_a, "leave_rejoin", {"delay": 3.0})
	await wait_until(func() -> bool: return not Net.players.has(old_a), 10.0, "Alpha gone from the registry")
	await wait_until(func() -> bool: return Game.world.get_player(old_a) == null, 5.0, "Alpha's Player despawned")
	check(not GameState.backroom.has(old_a) and not GameState.write_ups.has(old_a), "host: released from the back room, no strikes left")
	check(Events.is_event_active(Events.EVENT_INSPECTION), "the inspection is still running")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0 and _peer_named("a") != old_a, 20.0, "Alpha re-joined (new peer id)"):
		return
	_ids["a"] = _peer_named("a")
	await wait_until(func() -> bool: return _player("a") != null, 10.0, "the new Alpha's Player node exists")
	check(not GameState.is_in_backroom(_ids["a"]), "the new Alpha is on the floor")
	r = await run_cmd(_ids["a"], "goto", {"pos": _park["a"]})

	step("inspection ends")
	_ev_ended.clear()
	boss.set_process(true)
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _ev_ended.size() == 1 and _ev_ended[0][0] == Events.EVENT_INSPECTION, "host: event_ended(inspection)")
	crate.queue_free()
	r = await run_cmd(_ids["b"], "goto", {"pos": _park["b"], "crouch": false})
	await wait_sec(1.0)
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(String(r.get("active", "?")) == "" and not bool(r.get("walking", true)), "%s: no event, the Boss stopped" % NAMES[k])
		check(String(r.get("banner", "?")) == "", "%s: banner gone" % NAMES[k])
	r = await run_cmd(_ids["b"], "report")
	check(_written_in(r, 1, Const.WRITE_UP_LOITERING) == 1 and _written_in(r, _ids["b"], "") == 0, "Bravo saw the host's loitering write-up and none of his own")
	await checkpoint("after the inspection", ["a", "b", "c"])
	await _stats_everywhere("after the inspection")


# ---------------------------------------------------------------- (1) same-frame throws

func _case_throws() -> void:
	step("(1) same-frame throws: four bundles thrown at each other in one frame")
	var items := Game.world.items
	var lanes := {
		"a": [Vector3(-3.0, 0.05, -2.0), Vector3(-0.5, 0.05, -2.0)],
		"b": [Vector3(-0.5, 0.05, -2.0), Vector3(-3.0, 0.05, -2.0)],
		"c": [Vector3(-3.0, 0.05, 2.0), Vector3(-0.5, 0.05, 2.0)],
		"host": [Vector3(-0.5, 0.05, 2.0), Vector3(-3.0, 0.05, 2.0)],
	}
	var seqs := {}
	for k in ["a", "b", "c"]:
		seqs[k] = cmd(_ids[k], "goto", {"pos": lanes[k][0], "look": lanes[k][1]})
	for k in ["a", "b", "c"]:
		await await_ack(seqs[k])
	_put_me(lanes["host"][0], lanes["host"][1])
	var names := []
	for k in ["a", "b", "c", "host"]:
		var pid: int = 1 if k == "host" else _ids[k]
		var it := items.server_spawn_item(PRODUCT, {"strain_id": "budget", "amount": 1}, Vector3.ZERO, pid)
		check(it != null and it.holder_id == pid, "%s holds a bundle" % NAMES[k])
		if it != null:
			names.append(String(it.name))
	await wait_sec(0.4)
	var before := await _reports(["a", "b", "c"])
	_staggers.clear()
	var hits0 := _stat_total(Const.STAT_HITS)
	var throws0 := {}
	for k in ["a", "b", "c", "host"]:
		throws0[k] = GameState.get_stat(_pid(k), Const.STAT_THROWS)
	var s := {}
	for k in ["a", "b", "c"]:
		s[k] = cmd(_ids[k], "throw_now")
	items.request_throw()
	for k in ["a", "b", "c"]:
		await await_ack(s[k])
	await wait_until(func() -> bool: return _none_flying(), 4.0, "every bundle at rest within 4 s on the host")
	check(items_of(PRODUCT).size() == 4, "still exactly 4 bundles (%d)" % items_of(PRODUCT).size())
	for n in names:
		var it := item_named(n)
		check(it != null and it.holder_id == 0 and not it.is_flying(), "%s on the floor, not flying" % n)
	for k in ["a", "b", "c", "host"]:
		check(GameState.get_stat(_pid(k), Const.STAT_THROWS) == int(throws0[k]) + 1, "STAT_THROWS +1 for %s" % NAMES[k])
	await wait_sec(0.6) # cosmetic stagger RPCs land
	var hits := _stat_total(Const.STAT_HITS) - hits0
	check(hits >= 2, "at least two bundles hit a worker (%d)" % hits)
	check(_staggers.size() == hits, "host: %d hit(s) == %d stagger(s) observed" % [hits, _staggers.size()])
	for k in ["a", "b", "c"]:
		var r := await run_cmd(_ids[k], "report_items", {"names": names})
		check(int(r.get("items", -1)) == items_of(CAN).size() + items_of(Const.ITEM_HAND_TRUCK).size() + 4, "%s: same item count" % NAMES[k]) # M17 cart: and the dock's hand truck
		var by_name: Dictionary = r.get("items_by_name", {})
		var same := true
		for n in names:
			var it := item_named(n)
			var v: Dictionary = by_name.get(n, {})
			if it == null or not bool(v.get("exists", false)) or int(v.get("holder", -1)) != 0 or bool(v.get("flying", true)):
				same = false
			elif Vector3(v.get("rest", Vector3.INF)).distance_to(it.rest_position) > 0.05:
				same = false
				print("      %s: %s rests at %s, host %s" % [NAMES[k], n, v.get("rest"), it.rest_position])
		check(same, "%s: every bundle at rest at the host's position (within 0.05 m)" % NAMES[k])
		check(int(r.get("staggers", -1)) - int(before[k].get("staggers", 0)) == hits, "%s observed %d stagger(s)" % [NAMES[k], hits])
	await checkpoint("after the throws", ["a", "b", "c"])
	await _stats_everywhere("after the throws")
	for it in items_of(PRODUCT):
		items.server_despawn_item(it)
	await wait_frames(2)


# ---------------------------------------------------------------- (2) chute shots

func _case_chute() -> void:
	step("(2) chute shots: three workers throw bundles into the chute at once")
	var items := Game.world.items
	var chute: TurnInStation = station("TurnInStation") as TurnInStation
	var mouth := chute.get_mouth_position()
	var spots := {"a": Vector3(-1.0, 0.05, 3.9), "b": Vector3(0.0, 0.05, 3.7), "c": Vector3(1.0, 0.05, 3.9)}
	var seqs := {}
	for k in ["a", "b", "c"]:
		seqs[k] = cmd(_ids[k], "goto", {"pos": spots[k], "aim": mouth})
	for k in ["a", "b", "c"]:
		await await_ack(seqs[k])
	for k in ["a", "b", "c"]:
		var it := items.server_spawn_item(PRODUCT, {"strain_id": "budget", "amount": 1}, Vector3.ZERO, _ids[k])
		check(it != null and it.holder_id == _ids[k], "%s holds a bundle" % NAMES[k])
	await wait_sec(0.4)
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	var dep0 := {}
	for k in ["a", "b", "c"]:
		dep0[k] = GameState.get_stat(_ids[k], Const.STAT_DEPOSITED)
	var s := {}
	for k in ["a", "b", "c"]:
		s[k] = cmd(_ids[k], "throw_now")
	for k in ["a", "b", "c"]:
		await await_ack(s[k])
	await wait_until(func() -> bool: return items_of(PRODUCT).is_empty(), 4.0, "every bundle sold (despawned) within 4 s")
	for it in items_of(PRODUCT):
		print("      leftover %s at %s (flying %s)" % [it.name, it.global_position, it.is_flying()])
	check(GameState.round_sales == sales0 + 3 * BUDGET_VALUE, "exactly three sales: +$%d (sold %d -> %d)" % [3 * BUDGET_VALUE, sales0, GameState.round_sales])
	check(GameState.money == money0 + 3 * BUDGET_VALUE, "cash +$%d" % (3 * BUDGET_VALUE))
	for k in ["a", "b", "c"]:
		check(GameState.get_stat(_ids[k], Const.STAT_DEPOSITED) == int(dep0[k]) + BUDGET_VALUE, "%s: STAT_DEPOSITED +%d" % [NAMES[k], BUDGET_VALUE])
	await checkpoint("after the chute shots", ["a", "b", "c"], true)
	await _stats_everywhere("after the chute shots")


# ---------------------------------------------------------------- (3) shoves

func _case_shoves() -> void:
	step("(3) shove chains and cooldowns")
	var b: BalanceConfig = Config.balance
	var items := Game.world.items
	var can := items.server_spawn_item(CAN, {"charges": 2}, Vector3.ZERO, _ids["b"])
	check(can != null and can.holder_id == _ids["b"], "Bravo holds a can")
	var r := await run_cmd(_ids["b"], "goto", {"pos": Vector3(-1.0, 0.05, 0.0), "look": Vector3(2.0, 0.05, 0.0)})
	r = await run_cmd(_ids["c"], "goto", {"pos": _park["c"]})
	var before := await _reports(["a", "b", "c"])
	_staggers.clear()
	var shoves0 := {}
	for k in ["a", "b", "c"]:
		shoves0[k] = GameState.get_stat(_ids[k], Const.STAT_SHOVES)
	var default_stun := b.shove_stun_sec
	b.shove_stun_sec = 1.5 # a long stun: Bravo's shove-back below is provably inside it
	r = await run_cmd(_ids["a"], "shove_from_behind", {"target": _ids["b"]}, 20.0)
	check(int(r.get("saw", 0)) == 1 and int(r.get("by", -1)) == _ids["a"], "Alpha saw Bravo stagger once %s" % [r])
	check(can != null and can.holder_id == 0, "Bravo dropped the can (shoved from behind)")
	check(GameState.get_stat(_ids["a"], Const.STAT_SHOVES) == int(shoves0["a"]) + 1, "STAT_SHOVES +1 for Alpha")
	r = await run_cmd(_ids["b"], "shove_now", {"target": _ids["a"]})
	await wait_sec(0.4)
	check(GameState.get_stat(_ids["b"], Const.STAT_SHOVES) == int(shoves0["b"]) and _stagger_count(_ids["a"]) == 0, "a stunned worker's shove is refused")
	b.shove_stun_sec = default_stun
	await wait_sec(1.2)
	r = await run_cmd(_ids["b"], "double_shove", {"target": _ids["a"]}, 20.0)
	check(int(r.get("saw", 0)) == 1, "Bravo saw Alpha stagger exactly once after a double press (%d)" % int(r.get("saw", 0)))
	check(GameState.get_stat(_ids["b"], Const.STAT_SHOVES) == int(shoves0["b"]) + 1, "STAT_SHOVES +1 for Bravo (the second press hit the cooldown)")
	_put_me(Vector3(1.0, 0.05, 0.0), Vector3(1.0, 0.05, 3.0))
	await wait_sec(0.3)
	var me: Player = Game.local_player
	r = await run_cmd(_ids["c"], "shove_from_front", {"target": 1}, 20.0)
	check(int(r.get("saw", 0)) == 1 and int(r.get("by", -1)) == _ids["c"], "Charlie saw the host stagger")
	check(_stagger_count(1) == 1 and GameState.get_stat(_ids["c"], Const.STAT_SHOVES) == int(shoves0["c"]) + 1, "the host staggered once, STAT_SHOVES +1 for Charlie")
	check(me.global_position.z < -0.2, "the host stumbled backwards (z %.2f)" % me.global_position.z)
	await wait_sec(0.6)
	check(_staggers.size() == 3, "host observed 3 staggers in all (%d)" % _staggers.size())
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(int(r.get("staggers", -1)) - int(before[k].get("staggers", 0)) == 3, "%s observed 3 staggers" % NAMES[k])
	step("mutual shoves in the same frame: the first one lands, the second shover is already stunned")
	await run_both("a", "goto", {"pos": Vector3(-2.0, 0.05, 0.0), "look": Vector3(-0.8, 0.05, 0.0)},
			"b", "goto", {"pos": Vector3(-0.8, 0.05, 0.0), "look": Vector3(-2.0, 0.05, 0.0)})
	_staggers.clear()
	var shoves_ab := GameState.get_stat(_ids["a"], Const.STAT_SHOVES) + GameState.get_stat(_ids["b"], Const.STAT_SHOVES)
	var s1 := cmd(_ids["a"], "shove_now", {"target": _ids["b"]})
	var s2 := cmd(_ids["b"], "shove_now", {"target": _ids["a"]})
	await await_ack(s1)
	await await_ack(s2)
	await wait_sec(0.6)
	check(_staggers.size() == 1, "exactly one stagger (%d)" % _staggers.size())
	check(GameState.get_stat(_ids["a"], Const.STAT_SHOVES) + GameState.get_stat(_ids["b"], Const.STAT_SHOVES) == shoves_ab + 1, "one shove counted between the two")
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(int(r.get("staggers", -1)) - int(before[k].get("staggers", 0)) == 4, "%s observed 4 staggers in all" % NAMES[k])
	items.server_despawn_item(can)
	await checkpoint("after the shoves", ["a", "b", "c"])
	await _stats_everywhere("after the shoves")


# ---------------------------------------------------------------- (5) back room

func _case_backroom() -> void:
	step("(5) back room: Bravo written up three times")
	var b: BalanceConfig = Config.balance
	var room: Room = Game.world.room
	var items := Game.world.items
	_backroom_ev.clear()
	for i in 3:
		GameState.server_write_up(_ids["b"], Const.WRITE_UP_OTHER)
	check(GameState.is_in_backroom(_ids["b"]) and GameState.get_write_ups(_ids["b"]) == 0, "Bravo: in the back room, strikes cleared")
	check(_backroom_ev.has([_ids["b"], true]), "backroom_changed(Bravo, true) on the host")
	var release := float(GameState.backroom.get(_ids["b"], -1.0))
	check(absf(GameState.time_left - release - b.backroom_sec) < 1.0, "the release rides the shift timer (%.0f s stay)" % (GameState.time_left - release))
	var spot := room.get_backroom_transform(0).origin
	print("  (physics mismatch before Bravo enters: %s)" % [_phys_mismatch()])
	await wait_until(func() -> bool: return _player("b") != null and _player("b").global_position.distance_to(spot) < 0.4, 5.0, "host: Bravo's body at the BackRoomSpot")
	await wait_frames(2)
	print("  (physics mismatch with Bravo inside: %s)" % [_phys_mismatch()])
	var r := await run_cmd(_ids["b"], "backroom_check")
	check(bool(r.get("locked", false)), "Bravo: UI locked by the back room")
	check(bool(r.get("overlay", false)), "Bravo: overlay open")
	check(String(r.get("camera", "")) == SPECTATOR_NAME and int(r.get("cameras", 0)) == 1, "Bravo: one spectator camera, current")
	check(Vector3(r.get("pos", Vector3.INF)).distance_to(spot) < 0.4, "Bravo: his own body at the spot")
	var watching := int(r.get("watching", -1))
	check(watching > 0 and watching != _ids["b"] and not GameState.is_in_backroom(watching), "Bravo watches a floor worker (%d)" % watching)
	for k in ["a", "c"]:
		r = await run_cmd(_ids[k], "report_player", {"peer": _ids["b"]})
		check(Vector3(r.get("pos", Vector3.INF)).distance_to(spot) < 0.4, "%s: Bravo's body at the spot" % NAMES[k])
		check(bool(r.get("tag", false)), "%s: WORKERS list tags Bravo (back room)" % NAMES[k])
	step("released by the shift timer")
	GameState.time_left = release + 0.2
	await wait_until(func() -> bool: return not GameState.is_in_backroom(_ids["b"]), 3.0, "the shift timer released Bravo")
	var spawn := room.get_spawn_transform(_player("b").spawn_index).origin
	await wait_until(func() -> bool: return _player("b").global_position.distance_to(spawn) < 0.6, 5.0, "host: Bravo's body back at his spawn")
	await wait_sec(0.3)
	print("  (physics mismatch after the timer release: %s)" % [_phys_mismatch()])
	r = await run_cmd(_ids["b"], "backroom_check")
	check(not bool(r.get("locked", true)) and not bool(r.get("overlay", true)), "Bravo: lock + overlay gone")
	check(bool(r.get("own_camera", false)) and int(r.get("cameras", 1)) == 0, "Bravo: own camera current, no SpectatorCamera node left")

	step("two workers in the back room at once sit on different spots (the lower peer id enters second)")
	var pair: Array = [_ids["b"], _ids["c"]]
	pair.sort()
	var first: int = pair[1]
	var second: int = pair[0]
	check(GameState.server_send_to_backroom(first, 20.0) and GameState.server_send_to_backroom(second, 20.0), "both sent")
	var p_first := Game.world.get_player(first)
	var p_second := Game.world.get_player(second)
	await wait_until(func() -> bool: return _at_a_backroom_slot(p_first) and _at_a_backroom_slot(p_second), 5.0, "both bodies at back-room markers")
	await wait_frames(2)
	print("  (physics mismatch with the pair inside: %s)" % [_phys_mismatch()])
	var apart := p_first.global_position.distance_to(p_second.global_position)
	check(apart > 1.0, "they sit %.2f m apart (different slots)" % apart)
	r = await run_cmd(_ids["a"], "report_player", {"peer": first})
	var r2 := await run_cmd(_ids["a"], "report_player", {"peer": second})
	check(Vector3(r.get("pos", Vector3.INF)).distance_to(Vector3(r2.get("pos", Vector3.INF))) > 1.0, "Alpha sees them apart too")
	GameState.server_release_from_backroom(first)
	GameState.server_release_from_backroom(second)
	await wait_frames(3)
	check(GameState.backroom.is_empty(), "both released")
	# Their bodies must have synced back to their spawns before the host is put on the marker (a body still
	# standing there would push the host off it).
	await wait_until(func() -> bool: return not _at_a_backroom_slot(p_first) and not _at_a_backroom_slot(p_second), 5.0, "both bodies left the markers")
	await wait_frames(2)
	print("  (physics mismatch after the pair left: %s)" % [_phys_mismatch()])

	step("a worker standing on another worker is not flung when that worker is teleported away")
	# Remote bodies are kinematic colliders that jump to a synced position in one physics tick. A worker standing on
	# one must not inherit that jump as a moving-platform velocity (observed: the host carried 8 m across the room).
	var me: Player = Game.local_player
	var pb := _player("b")
	var under := pb.global_position
	_put_me(under + Vector3.UP * Player.STAND_HEIGHT, under + Vector3(0.0, 0.0, 1.0))
	await wait_sec(0.5)
	var on_head := me.global_position.y > 1.2 and Vector2(me.global_position.x - under.x, me.global_position.z - under.z).length() < 0.5
	check(on_head, "the host stands on Bravo (%s over %s)" % [me.global_position, under])
	var here := me.global_position
	check(GameState.server_send_to_backroom(_ids["b"], 20.0), "Bravo is sent to the back room from under the host")
	await wait_sec(0.8)
	var carried := Vector2(me.global_position.x - here.x, me.global_position.z - here.z).length()
	check(carried < 1.0 and me.global_position.y < 0.3, "the host dropped to the floor where it stood (moved %.2f m, now %s)" % [carried, me.global_position])
	GameState.server_release_from_backroom(_ids["b"])
	await wait_until(func() -> bool: return not _at_a_backroom_slot(pb), 5.0, "Bravo back out")
	await wait_frames(2)
	_put_me(Vector3(1.0, 0.05, -1.6), Vector3(1.0, 0.05, 1.0))
	await wait_sec(0.3)

	step("the host in the back room; Alpha throws through its spot: no hit")
	_backroom_ev.clear()
	var host_before := me.global_position
	var others := []
	for p in Game.world.get_players():
		var phys: Transform3D = PhysicsServer3D.body_get_state(p.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		others.append("%d node %s physics %s shape h%.1f%s" % [p.peer_id, p.global_position, phys.origin, p._shape.height, " crouched" if p.crouching else ""])
	print("  (bodies before: %s; host spawn index %d)" % [others, me.spawn_index])
	check(GameState.server_send_to_backroom(1, 20.0), "host sent to the back room")
	var trace := [me.global_position]
	print("  (overlapping the marker right after the teleport: %s)" % [_bodies_at(spot, me)])
	for i in 3:
		await get_tree().process_frame
		trace.append(me.global_position)
		var hits := []
		for c in me.get_slide_collision_count():
			var col := me.get_slide_collision(c).get_collider()
			hits.append(String(col.name) if col != null else "?")
		print("  (frame %d: host at %s, slide collisions %s, floor %s)" % [i + 1, me.global_position, hits, me.is_on_floor()])
	print("  (host body trace: %s)" % [trace])
	check(_backroom_ev.has([1, true]), "backroom_changed(host, true) fired %s" % [_backroom_ev])
	check(me.global_position.distance_to(spot) < 0.4, "host body at the spot (%s vs %s, was %s, slots %s)" % [me.global_position, spot, host_before, Events._backroom_slots])
	check(Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM), "host UI locked")
	var hud := _hud()
	check(hud.back_room.is_open() and get_viewport().get_camera_3d() == hud.back_room.get_spectator_camera(), "host: overlay + spectator camera")
	var can2 := items.server_spawn_item(CAN, {"charges": 1}, Vector3.ZERO, _ids["a"])
	var flights: Array = []
	can2.flight_changed.connect(func(f: bool) -> void: flights.append(f))
	r = await run_cmd(_ids["a"], "goto", {"pos": Vector3(spot.x - 2.0, 0.05, spot.z), "aim": me.get_chest_position()})
	_staggers.clear()
	var hits0 := GameState.get_stat(_ids["a"], Const.STAT_HITS)
	r = await run_cmd(_ids["a"], "throw_now")
	await wait_until(func() -> bool: return flights.size() >= 2 and can2.holder_id == 0 and not can2.is_flying(), 5.0, "the can flew and landed %s" % [flights])
	check(_stagger_count(1) == 0 and GameState.get_stat(_ids["a"], Const.STAT_HITS) == hits0, "no hit on a back-room worker")
	check(room.get_bounds().grow(0.5).has_point(can2.global_position), "the can landed inside the room (%s)" % can2.global_position)
	GameState.server_release_from_backroom(1)
	await wait_frames(3)
	check(not Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM) and not hud.back_room.is_open(), "host released: lock + overlay gone")
	check(me.camera.current and _count_named(Game.world, SPECTATOR_NAME) == 0, "host: own camera current, no SpectatorCamera left")
	items.server_despawn_item(can2)
	r = await run_cmd(_ids["a"], "goto", {"pos": _park["a"]})
	await checkpoint("after the back room", ["a", "b", "c"], true)


# ---------------------------------------------------------------- (6) power cut

func _case_power_cut() -> void:
	step("(6) power cut: growth pauses, everyone dark, Charlie re-joins dark, Alpha resets the breaker")
	var b: BalanceConfig = Config.balance
	var room: Room = Game.world.room
	var p1 := plot(1)
	if not p1.is_empty():
		p1.server_reset()
	check(p1.server_plant(&"budget") and p1.server_water(1.0), "plot 1 planted + watered")
	Config.growth_speed_override = 5.0
	await wait_sec(0.4)
	check(p1.stage_progress > 0.0, "it grows (%.3f)" % p1.stage_progress)
	_power_ev.clear()
	_ev_ended.clear()
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut started")
	check(not Events.is_power_on() and not room.is_power_on(), "host: power off")
	var prog0 := p1.stage_progress
	var water0 := p1.water
	await wait_sec(0.8)
	check(p1.stage_progress == prog0 and p1.water == water0, "growth and water frozen while the power is off")
	var r: Dictionary
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(not bool(r.get("power", true)) and not bool(r.get("room_power", true)) and String(r.get("active", "")) == String(Events.EVENT_POWER_CUT), "%s: power off, room dark, cut active" % NAMES[k])
		check(String(r.get("banner", "")).begins_with(HUD.TEXT_EVENT_POWER_CUT) and bool(r.get("fuse_tripped", false)), "%s: banner POWER CUT, breaker tripped" % NAMES[k])
	step("Charlie leaves and re-joins during the cut, with Bravo's can in the air towards him")
	var old_c: int = _ids["c"]
	var items := Game.world.items
	var can := items.server_spawn_item(CAN, {"charges": 1}, Vector3.ZERO, _ids["b"])
	r = await run_cmd(_ids["b"], "goto", {"pos": Vector3(_park["c"].x, 0.05, _park["c"].z - 2.5), "look": _park["c"]})
	var s_throw := cmd(_ids["b"], "throw_now")
	cmd(old_c, "leave_rejoin", {"delay": 2.0})
	await await_ack(s_throw)
	await wait_until(func() -> bool: return not Net.players.has(old_c), 10.0, "Charlie left")
	await wait_until(func() -> bool: return can != null and can.holder_id == 0 and not can.is_flying(), 4.0, "the can landed although its target vanished")
	check(items_of(CAN).has(can), "the can still exists")
	items.server_despawn_item(can)
	if not await wait_until(func() -> bool: return _peer_named("c") > 0 and _peer_named("c") != old_c, 20.0, "Charlie re-joined during the cut"):
		return
	_ids["c"] = _peer_named("c")
	await wait_until(func() -> bool: return _player("c") != null, 10.0, "Charlie's Player node exists")
	check(Events.is_event_active(Events.EVENT_POWER_CUT), "the cut is still running")
	r = await run_cmd(_ids["c"], "late_power", {}, 10.0)
	check(not bool(r.get("power", true)) and not bool(r.get("room_power", true)) and String(r.get("active", "")) == String(Events.EVENT_POWER_CUT), "Charlie started dark with the cut active")
	check(int(r.get("ms", 99999)) <= LATE_JOIN_LIMIT_MS, "Charlie was dark %d ms after spawning" % int(r.get("ms", -1)))
	check(bool(r.get("fuse_tripped", false)) and String(r.get("banner", "")).begins_with(HUD.TEXT_EVENT_POWER_CUT), "Charlie: breaker tripped, banner POWER CUT")
	step("Alpha resets the breaker")
	r = await run_cmd(_ids["a"], "fuse_reset", {}, 25.0)
	check(bool(r.get("power", false)) and bool(r.get("room_power", false)) and bool(r.get("ended", false)), "Alpha's reset restored the power (%d attempt(s), toasts %s)" % [int(r.get("attempts", 0)), r.get("toasts", [])])
	check(Events.is_power_on() and room.is_power_on() and not Events.is_event_active(), "host: power on, event over")
	check(_ev_ended.size() >= 1 and _ev_ended.back()[0] == Events.EVENT_POWER_CUT, "host: event_ended(power_cut)")
	await wait_sec(0.5)
	check(p1.stage_progress > prog0, "growth resumed (%.3f -> %.3f)" % [prog0, p1.stage_progress])
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(bool(r.get("power", false)) and bool(r.get("room_power", false)) and String(r.get("active", "?")) == "" and String(r.get("banner", "?")) == "", "%s: power on, no event, banner gone" % NAMES[k])
	step("a cut nobody resets ends by itself; meanwhile Alpha sends forged M10 requests (11)")
	var default_max := b.power_cut_max_sec
	b.power_cut_max_sec = 6.0
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "second cut")
	check(absf(Events.get_event_time_left() - 6.0) < 0.1, "runs for power_cut_max_sec (%.1f)" % Events.get_event_time_left())
	await _case_hostile()
	await wait_until(func() -> bool: return Events.is_power_on() and not Events.is_event_active(), 7.5, "ended by itself, power back")
	b.power_cut_max_sec = default_max
	await wait_sec(0.4)
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(bool(r.get("power", false)) and bool(r.get("room_power", false)) and String(r.get("active", "?")) == "", "%s: lights back after the auto-end" % NAMES[k])
	Config.growth_speed_override = 0.0
	p1.server_reset()
	await checkpoint("after the power cuts", ["a", "b", "c"])


## (11) Forged / misdirected M10 requests from Alpha while the power is out: nothing changes anywhere, the engine
## rejects the authority-only calls on the host (announced), no other error line.
func _case_hostile() -> void:
	step("(11) hostile M10 RPCs from Alpha")
	var items := Game.world.items
	var can := items.server_spawn_item(CAN, {"charges": 1}, Vector3.ZERO, _ids["b"])
	var r := await run_cmd(_ids["b"], "goto", {"pos": Vector3(0.0, 0.05, -1.0), "look": Vector3(0.0, 0.05, -4.0)})
	r = await run_cmd(_ids["a"], "goto", {"pos": _park["a"]})
	await wait_sec(0.3)
	var before := await _reports(["b", "c"])
	_staggers.clear()
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	var stats0 := _stats_sig()
	var st0: Dictionary = Voice.get_stats()
	for s in ["RPC '_rpc_power' is not allowed on node /root/Events",
			"RPC '_rpc_event_ended' is not allowed on node /root/Events",
			"RPC '_rpc_written_up' is not allowed on node /root/GameState"]:
		expect_error(s)
	r = await run_cmd(_ids["a"], "hostile_rpcs", {"victim": _ids["b"]}, 20.0)
	await wait_until(func() -> bool: return expected_errors_seen(), 5.0, "the engine rejected every authority-only RPC")
	check(not Events.is_power_on() and Events.is_event_active(Events.EVENT_POWER_CUT), "the power stays off, the cut runs on")
	check(_staggers.is_empty(), "no stagger from a shove request on someone else's node or a forged stagger")
	check(can != null and can.holder_id == _ids["b"], "Bravo keeps the can")
	check(GameState.money == money0 and GameState.round_sales == sales0 and _stats_sig() == stats0, "cash, sales and stats untouched")
	var d1: Dictionary = Voice.get_stats()["dropped"]
	var d0: Dictionary = st0["dropped"]
	check(int(d1.get("too_big", 0)) - int(d0.get("too_big", 0)) == 1 and int(d1.get("empty", 0)) - int(d0.get("empty", 0)) == 1, "oversized + empty voice frames dropped for their reasons")
	var toasts_a: Array = r.get("toasts", [])
	check(toasts_a.has(FuseBox.REASON_TOO_FAR), "the fuse reset from across the room got 'Too far.' %s" % [toasts_a])
	check(int(r.get("local_staggers", -1)) == 0, "the forged cosmetic stagger ran nowhere, not even on Alpha's own screen (%d)" % int(r.get("local_staggers", -1)))
	for k in ["b", "c"]:
		var rep := await run_cmd(_ids[k], "report")
		check(int(rep.get("staggers", -1)) == int(before[k].get("staggers", 0)), "%s saw no stagger" % NAMES[k])
		check(not bool(rep.get("power", true)) and String(rep.get("active", "")) == String(Events.EVENT_POWER_CUT), "%s: still dark" % NAMES[k])
	items.server_despawn_item(can)


# ---------------------------------------------------------------- rat

func _case_rat() -> void:
	step("rat: four peers see him eat a tray until Charlie walks up")
	if not Events.RAT_ENABLED:
		check(not Events.server_start_event(Events.EVENT_RAT), "rat disabled: refused")
		return
	var room: Room = Game.world.room
	var p2 := plot(2)
	p2.server_reset()
	check(p2.server_plant(&"budget") and p2.server_water(1.0), "plot 2 grows")
	p2.stage_progress = 0.5
	_ev_ended.clear()
	check(Events.server_start_event(Events.EVENT_RAT), "rat started")
	check(int(Events.get_event_params().get("plot", 0)) == 2, "he heads for plot 2")
	var rat := room.get_node_or_null(^"Rat") as Rat
	check(rat != null and rat.is_running(), "host: a Rat runs")
	if rat == null:
		Events.server_end_event()
		return
	await wait_until(func() -> bool: return rat.is_eating(), 12.0, "he reaches the tray")
	var prog0 := p2.stage_progress
	await wait_sec(1.0)
	check(p2.stage_progress < prog0, "he eats stage progress (%.2f -> %.2f)" % [prog0, p2.stage_progress])
	var r: Dictionary
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "report")
		check(bool(r.get("rat", false)) and String(r.get("active", "")) == String(Events.EVENT_RAT), "%s: a Rat prop, event active" % NAMES[k])
		check(String(r.get("banner", "")).begins_with(HUD.TEXT_EVENT_RAT), "%s: banner RAT" % NAMES[k])
	var rat_pos := rat.global_position
	r = await run_cmd(_ids["c"], "goto", {"pos": Vector3(rat_pos.x - 0.6, 0.05, rat_pos.z)})
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "Charlie within 1.5 m scares him off: event over")
	check(_ev_ended.size() == 1 and _ev_ended[0][0] == Events.EVENT_RAT, "event_ended(rat)")
	await wait_until(func() -> bool: return room.get_node_or_null(^"Rat") == null, 8.0, "host: he is gone")
	for k in ["a", "b", "c"]:
		r = await run_cmd(_ids[k], "wait_no_rat")
		check(not bool(r.get("rat", true)) and String(r.get("active", "?")) == "", "%s: rat gone, no event" % NAMES[k])
	p2.server_reset()
	r = await run_cmd(_ids["c"], "goto", {"pos": _park["c"]})


# ---------------------------------------------------------------- (7) voice

func _case_voice() -> void:
	step("(7) voice under load: three clients talk at 50 frames/s for 4 s while cans fly")
	var items := Game.world.items
	var hud := _hud()
	_speak_ev.clear()
	var st0: Dictionary = Voice.get_stats()
	var before := await _reports(["a", "b", "c"])
	for k in ["a", "b", "c"]:
		cmd(_ids[k], "voice_burst", {"seconds": 4.0, "rate": 50.0})
	var can := items.server_spawn_item(CAN, {"charges": 1}, Vector3(-3.0, 0.0, 3.0))
	for i in 4:
		await wait_sec(0.5)
		if can != null and not can.is_flying():
			items.server_throw_item(can, can.global_position + Vector3(0.0, 1.2, 0.0), Vector3(0.4, 6.0, -3.0), 1)
	var all_speaking := Voice.is_speaking(_ids["a"]) and Voice.is_speaking(_ids["b"]) and Voice.is_speaking(_ids["c"])
	check(all_speaking, "host hears all three at once %s" % [Voice.get_speaking_peers()])
	check(hud.is_speaking_mark_shown(_ids["a"]) and hud.is_speaking_mark_shown(_ids["b"]) and hud.is_speaking_mark_shown(_ids["c"]), "host HUD shows three speaking marks")
	for k in ["a", "b", "c"]:
		var out := Voice.get_output_node(_ids[k])
		var p := _player(k)
		check(out != null and p != null and out.global_position.distance_to(p.global_position + Vector3.UP * Voice.HEAD_STANDING) < 0.5, "%s's emitter sits at their head" % NAMES[k])
	var r := await run_cmd(_ids["a"], "report_voice")
	var heard: Array = r.get("speaking", [])
	check(heard.has(_ids["b"]) and heard.has(_ids["c"]) and not heard.has(1), "Alpha hears Bravo and Charlie mid-burst (%s)" % [heard])
	var marks: Dictionary = r.get("marks", {})
	check(bool(marks.get(_ids["b"], false)) and bool(marks.get(_ids["c"], false)), "Alpha's HUD marks Bravo and Charlie")
	await wait_sec(2.6)
	await wait_until(func() -> bool: return Voice.get_speaking_peers().is_empty(), 3.0, "silence: no speaking marks left on the host")
	var st: Dictionary = Voice.get_stats()
	var after := await _reports(["a", "b", "c"])
	var sent_total := 0
	for k in ["a", "b", "c"]:
		sent_total += int(after[k]["voice"]["sent"]) - int(before[k]["voice"]["sent"])
	var received := int(st["received"]) - int(st0["received"])
	var lost := int(st["lost"]) - int(st0["lost"])
	var d0: Dictionary = st0["dropped"]
	var d1: Dictionary = st["dropped"]
	var rate_drops := int(d1.get("rate", 0)) - int(d0.get("rate", 0))
	check(sent_total >= 450, "the clients sent %d frames (about 600)" % sent_total)
	check(received >= sent_total * 6 / 10, "the host received %d of %d (%d lost on the way)" % [received, sent_total, lost])
	check(received + lost >= sent_total * 9 / 10, "every frame received or accounted lost (%d + %d of %d)" % [received, lost, sent_total])
	var bad := 0
	for reason in ["not_player", "too_big", "reorder", "empty", "no_world", "no_position"]:
		bad += int(d1.get(reason, 0)) - int(d0.get(reason, 0))
	check(bad == 0, "nothing dropped for a bad reason (%s)" % [d1])
	check(rate_drops <= received / 10, "rate drops within the limit's slack (%d)" % rate_drops)
	for k in ["a", "b", "c"]:
		check(_speak_ev.has([_ids[k], true]) and _speak_ev.has([_ids[k], false]), "host: speaking_changed(%s) came and went" % NAMES[k])
		var rec := int(after[k]["voice"]["received"]) - int(before[k]["voice"]["received"])
		check(rec >= 200, "%s heard the other two through the relay (%d frames)" % [NAMES[k], rec])
		var sp: Array = after[k].get("speaking", [])
		check(sp.is_empty(), "%s: silence again" % NAMES[k])

	step("back-room routing: Bravo talks from the back room, Alpha listens from the back room")
	GameState.server_send_to_backroom(_ids["b"], 20.0)
	GameState.server_send_to_backroom(_ids["a"], 20.0)
	await wait_frames(3)
	var sb0: Dictionary = Voice.get_stats()
	cmd(_ids["b"], "voice_burst", {"seconds": 1.6, "rate": 40.0})
	_host_talk(1.6, 40.0)
	await wait_sec(1.0)
	check(Voice.is_speaking(_ids["b"]), "host (floor): Bravo's mark still shows (arrival-based)")
	var sb: Dictionary = Voice.get_stats()
	check(int(sb["dropped"].get("mute", 0)) - int(sb0["dropped"].get("mute", 0)) > 10, "host (floor): Bravo's frames are routed mute")
	r = await run_cmd(_ids["a"], "report_voice")
	var routes: Dictionary = r.get("routes", {})
	var rb: Array = routes.get(_ids["b"], [])
	var rh: Array = routes.get(1, [])
	check(rb.size() == 2 and int(rb[0]) == AudioStreamPlayer3D.ATTENUATION_DISABLED and is_zero_approx(float(rb[1])), "Alpha (back room) hears Bravo full %s" % [rb])
	check(rh.size() == 2 and int(rh[0]) == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE and is_equal_approx(float(rh[1]), Voice.FAINT_DB), "Alpha (back room) hears the host faint %s" % [rh])
	heard = r.get("speaking", [])
	check(heard.has(_ids["b"]) and heard.has(1), "Alpha hears both (%s)" % [heard])
	r = await run_cmd(_ids["c"], "report_voice")
	var dc: Dictionary = r["voice"]["dropped"]
	check(int(dc.get("mute", 0)) > 0, "Charlie (floor): Bravo muted (%d frames)" % int(dc.get("mute", 0)))
	routes = r.get("routes", {})
	rh = routes.get(1, [])
	check(rh.size() == 2 and int(rh[0]) == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE and is_zero_approx(float(rh[1])), "Charlie (floor) hears the host in 3D %s" % [rh])
	await wait_sec(1.0)
	GameState.server_release_from_backroom(_ids["a"])
	GameState.server_release_from_backroom(_ids["b"])
	await wait_frames(3)
	if can != null:
		items.server_despawn_item(can)
	await checkpoint("after voice", ["a", "b", "c"])


func _host_talk(seconds: float, rate: float) -> void:
	await _voice_burst(seconds, rate)


# ---------------------------------------------------------------- (8) floods

func _case_floods() -> void:
	step("(8) chat and ping floods: 30 lines + 30 pings per client in one frame, hostile payloads first")
	var hud := _hud()
	var before := await _reports(["a", "b", "c"])
	_chat.clear()
	_pings.clear()
	var lines0 := hud.chat.get_line_count()
	var pings0 := {}
	for k in ["a", "b", "c"]:
		pings0[k] = GameState.get_stat(_ids[k], Const.STAT_PINGS)
	var seqs := {}
	for k in ["a", "b", "c"]:
		seqs[k] = cmd(_ids[k], "flood")
	for k in ["a", "b", "c"]:
		await await_ack(seqs[k])
	await wait_sec(0.6)
	for k in ["a", "b", "c"]:
		var lines: Array = _chat.get(_ids[k], [])
		check(lines == ["hello there"], "host accepted exactly one sanitized line from %s %s" % [NAMES[k], lines])
		check(int(_pings.get(_ids[k], 0)) == 1, "host accepted exactly one ping from %s (%d)" % [NAMES[k], int(_pings.get(_ids[k], 0))])
		check(GameState.get_stat(_ids[k], Const.STAT_PINGS) == int(pings0[k]) + 1, "STAT_PINGS +1 for %s" % NAMES[k])
		check(hud.get_ping_marker(_ids[k]) != null, "host shows %s's marker" % NAMES[k])
	check(hud.chat.get_line_count() - lines0 == 3, "host chat log grew by 3 lines (%d)" % (hud.chat.get_line_count() - lines0))
	for k in ["a", "b", "c"]:
		var r := await run_cmd(_ids[k], "report_comms")
		var chat: Dictionary = r.get("chat", {})
		var pings: Dictionary = r.get("pings", {})
		var ok := true
		for j in ["a", "b", "c"]:
			if (chat.get(_ids[j], []) as Array) != ["hello there"] or int(pings.get(_ids[j], 0)) != 1:
				ok = false
		check(ok, "%s accepted one line + one ping per sender %s %s" % [NAMES[k], chat, pings])
		var markers: Array = r.get("markers", [])
		check(markers.has(_ids["a"]) and markers.has(_ids["b"]) and markers.has(_ids["c"]), "%s shows three markers %s" % [NAMES[k], markers])
	await wait_sec(0.4)
	for k in ["a", "b", "c"]:
		cmd(_ids[k], "say", {"text": "line two from %s" % NAMES[k]})
	await wait_sec(0.8)
	for k in ["a", "b", "c"]:
		var lines: Array = _chat.get(_ids[k], [])
		check(lines.size() == 2 and String(lines[1]) == "line two from %s" % NAMES[k], "a line after the gap is accepted from %s %s" % [NAMES[k], lines])
	before.clear()
	await _stats_everywhere("after the floods")


# ---------------------------------------------------------------- (9a) shift end + RETRY under churn

func _case_churn_retry() -> void:
	step("(9a) the shift ends and RETRY with cans in flight, Alpha in the back room, the power out and a rat")
	var room: Room = Game.world.room
	var items := Game.world.items
	var b: BalanceConfig = Config.balance
	var p3 := plot(3)
	p3.server_reset()
	check(p3.server_plant(&"budget") and p3.server_water(1.0), "plot 3 grows (the rat needs a tray)")
	check(Events.server_start_event(Events.EVENT_RAT), "rat running")
	Events.server_set_power(false)
	check(not Events.is_power_on() and not room.is_power_on(), "power out (outside an event)")
	check(GameState.server_send_to_backroom(_ids["a"], 25.0), "Alpha in the back room")
	Comms.ping(Vector3(0.0, 0.0, 0.0))
	var cans := items_of(CAN)
	for can in cans:
		check(items.server_throw_item(can, Vector3(-3.0, 1.2, 2.0), Vector3(1.0, 8.0, 0.5), 1), "%s lobbed high" % can.name)
	await wait_sec(0.4)
	var pre := await _reports(["a", "b", "c"])
	check(cans.size() == 2 and cans[0].is_flying() and cans[1].is_flying(), "two cans mid-flight")
	check(bool(pre["a"].get("locked", false)) and int(pre["a"].get("spectator", 0)) == 1, "Alpha: locked, spectator camera up")
	check(bool(pre["b"].get("rat", false)) and not bool(pre["b"].get("power", true)), "Bravo: rat on the floor, power out")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "ROUND_FAILED on the host")
	await wait_frames(2)
	check(not Events.is_event_active() and Events.is_power_on() and room.is_power_on(), "shift end: no event, power back")
	check(GameState.backroom.is_empty(), "shift end: everyone out of the back room")
	check(not GameState.stats.is_empty(), "the ledger survives for the report")
	await checkpoint("shift failed", ["a", "b", "c"], true)
	GameState.request_retry()
	await wait_frames(6)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.money == b.starting_money, "RETRY: WAITING, shift 1, $%d" % b.starting_money)
	check(GameState.stats.is_empty() and GameState.backroom.is_empty() and GameState.write_ups.is_empty(), "RETRY: ledger, back room, strikes cleared")
	var well: Well = station("Well") as Well
	var cans_ok := items_of(CAN).size() == b.starting_watering_cans
	for can in items_of(CAN):
		var near := false
		for k in b.starting_watering_cans:
			near = near or can.global_position.distance_to(well.get_can_spot_position(k)) < 0.05
		cans_ok = cans_ok and not can.is_flying() and can.holder_id == 0 and near
	check(cans_ok, "the flying cans are back at the well, at rest")
	check(items_of(PRODUCT).is_empty() and items_of(Const.ITEM_SEED_PACKET).is_empty(), "no bundles / packets")
	var all_empty := true
	for i in range(1, 7):
		all_empty = all_empty and plot(i).is_empty()
	check(all_empty, "every plot empty")
	await wait_until(func() -> bool: return room.get_node_or_null(^"Rat") == null, 8.0, "host: the rat is gone")
	var spawn_a := room.get_spawn_transform(_player("a").spawn_index).origin
	await wait_until(func() -> bool: return _player("a").global_position.distance_to(spawn_a) < 0.6, 5.0, "host: Alpha's body back at his spawn")
	await wait_sec(4.2) # ping markers live 4 s
	check(_count_named(Game.world, SPECTATOR_NAME) == 0 and _count_class(Game.world, "PingMarker") == 0, "host: no SpectatorCamera, no ping marker left")
	check(_voice_out_count() <= 3, "host: %d voice emitters (one per remote peer at most)" % _voice_out_count())
	var post := await _reports(["a", "b", "c"])
	for k in ["a", "b", "c"]:
		var r: Dictionary = post[k]
		check(int(r.get("spectator", 1)) == 0 and not bool(r.get("locked", true)) and not bool(r.get("overlay", true)), "%s: no SpectatorCamera, no lock, no overlay" % NAMES[k])
		check(not bool(r.get("rat", true)) and int(r.get("pings", 1)) == 0, "%s: rat gone, no ping markers" % NAMES[k])
		check(int(r.get("voice_out", 9)) <= 3 and int(r.get("voice_out", 9)) <= int(pre[k].get("voice_out", 0)), "%s: voice emitters not duplicated (%d)" % [NAMES[k], int(r.get("voice_out", -1))])
		check(bool(r.get("power", false)) and bool(r.get("room_power", false)) and String(r.get("active", "?")) == "" and not bool(r.get("round_end", true)), "%s: power on, no event, round-end overlay gone" % NAMES[k])
	await checkpoint("after RETRY", ["a", "b", "c"], true)
	GameState.request_start_round()
	check(GameState.is_playing(), "shift restarted")
	await checkpoint("shift restarted", ["a", "b", "c"], true)


# ---------------------------------------------------------------- (9b) a client leaves from the back room

func _case_churn_backroom_leave() -> void:
	step("(9b) Charlie returns to the menu while in the back room")
	check(GameState.server_send_to_backroom(_ids["c"], 25.0), "Charlie in the back room")
	await wait_frames(3)
	var r := await run_cmd(_ids["c"], "backroom_check")
	check(bool(r.get("locked", false)) and String(r.get("camera", "")) == SPECTATOR_NAME, "Charlie: locked, spectating")
	var old_c: int = _ids["c"]
	cmd(old_c, "leave_rejoin", {"delay": 2.0})
	await wait_until(func() -> bool: return not Net.players.has(old_c), 10.0, "Charlie left")
	check(not GameState.backroom.has(old_c), "host: the departed worker is out of the back room")
	if not await wait_until(func() -> bool: return _peer_named("c") > 0 and _peer_named("c") != old_c, 20.0, "Charlie re-joined"):
		return
	_ids["c"] = _peer_named("c")
	await wait_until(func() -> bool: return _player("c") != null, 10.0, "Charlie's Player node exists")
	check(not GameState.is_in_backroom(_ids["c"]), "the new Charlie is on the floor")
	await checkpoint("after Charlie's return", ["a", "b", "c"], true)


# ---------------------------------------------------------------- (10) a full --fast shift with the scheduler on

func _case_full_shift() -> void:
	step("(10) a full 60 s --fast shift with the scheduler on, four workers working")
	var b: BalanceConfig = Config.balance
	GameState.request_retry()
	await wait_frames(6)
	b.round_length_sec = 60.0
	Config.growth_speed_override = 20.0
	Config.user_args["event-delay"] = "5"
	b.event_gap_min_sec = 4.0
	b.event_gap_max_sec = 6.0
	b.inspection_sec = 12.0
	b.power_cut_max_sec = 8.0
	var default_quota := b.base_quota
	b.base_quota = 3000 # out of reach: the shift runs its full 60 s under the timer
	_ev_started.clear()
	await checkpoint("before the fast shift", ["a", "b", "c"], true)
	GameState.request_start_round()
	check(GameState.is_playing() and absf(GameState.time_left - 60.0) < 1.0, "60 s shift running (payment due $%d)" % GameState.quota)
	check(absf(Events.get_next_event_in() - 5.0) < 0.5, "first event in %.1f s" % Events.get_next_event_in())
	var shift_t0 := Time.get_ticks_msec()
	Events.event_started.connect(func(k: StringName, _p: Dictionary) -> void: print("  (event %s at %.1f s)" % [k, float(Time.get_ticks_msec() - shift_t0) / 1000.0]))
	Events.event_ended.connect(func(k: StringName) -> void: print("  (event %s over at %.1f s)" % [k, float(Time.get_ticks_msec() - shift_t0) / 1000.0]))
	var seqs := {}
	var plots := {"a": 1, "b": 2, "c": 3}
	for k in ["a", "b", "c"]:
		seqs[k] = cmd(_ids[k], "work_loop", {"plot": plots[k], "max_sec": 80.0})
	_host_bot(4)
	await wait_until(func() -> bool: return GameState.is_round_over(), 75.0, "the shift ended (%s)" % GameState.get_phase_name())
	var acked := 0
	for k in ["a", "b", "c"]:
		var r := await await_ack(seqs[k], 15.0)
		if not r.is_empty():
			acked += 1
			print("  (%s: %s)" % [NAMES[k], r])
	check(acked == 3, "every bot reported back")
	print("  (host bot: %s)" % [_bot_done])
	var kinds := []
	for e in _ev_started:
		kinds.append(String(e[0]))
	check(_ev_started.size() >= 2, "the scheduler fired %d events %s" % [_ev_started.size(), kinds])
	check(not Events.is_event_active() and Events.is_power_on() and GameState.backroom.is_empty(), "shift end: no event, power on, back room empty")
	check(Events.get_next_event_in() < 0.0, "nothing scheduled between shifts")
	var planted := _stat_total(Const.STAT_PLANTED)
	var deposited := _stat_total(Const.STAT_DEPOSITED)
	check(planted >= 2, "the team planted %d time(s)" % planted)
	check(deposited > 0 or planted >= 4, "the team deposited $%d" % deposited)
	await wait_sec(0.6)
	var hud := _hud()
	var sig := _stats_sig()
	var rows := hud.round_end.report.get_row_peers()
	check(hud.round_end.visible and rows == Story.get_report_peers(), "host: shift report rows %s" % [rows])
	for k in ["a", "b", "c"]:
		var r := await run_cmd(_ids[k], "report_end")
		check(String(r.get("stats", "?")) == sig, "%s: GameState.stats identical to the host" % NAMES[k])
		check(int(r.get("phase", -1)) == GameState.phase and bool(r.get("round_end", false)), "%s: same phase, round-end overlay up" % NAMES[k])
		var crow: Array = r.get("rows", [])
		var same_rows := crow.size() == rows.size()
		for i in mini(crow.size(), rows.size()):
			same_rows = same_rows and int(crow[i]) == int(rows[i])
		check(same_rows and bool(r.get("cells_ok", false)), "%s: shift report rows %s match, cells match its GameState" % [NAMES[k], crow])
		check(String(r.get("active", "?")) == "" and bool(r.get("power", false)) and not bool(r.get("locked", true)), "%s: no event, power on, no back-room lock" % NAMES[k])
	await checkpoint("fast shift over", ["a", "b", "c"], true)
	Config.user_args.erase("event-delay")
	b.event_first_delay_sec = FAR_AWAY
	b.event_gap_min_sec = FAR_AWAY
	b.event_gap_max_sec = FAR_AWAY
	b.round_length_sec = 900.0
	b.base_quota = default_quota
	Config.growth_speed_override = 0.0


func _host_bot(plot_index: int) -> void:
	_bot_done = await _work_loop(plot_index, 80.0)


# ---------------------------------------------------------------- (9c) the host leaves during an inspection

func _case_host_leaves() -> void:
	step("(9c) the host leaves during an inspection with Alpha in the back room")
	GameState.request_retry()
	await wait_frames(6)
	GameState.request_start_round()
	check(GameState.is_playing(), "a fresh shift")
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection running")
	check(GameState.server_send_to_backroom(_ids["a"], 25.0), "Alpha in the back room")
	await wait_frames(3)
	var r := await run_cmd(_ids["a"], "backroom_check")
	check(bool(r.get("locked", false)), "Alpha locked in the back room")
	for k in ["a", "b", "c"]:
		cmd(_ids[k], "expect_host_leave")
	await wait_sec(0.6)
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Net.is_online() and GameState.phase == GameState.Phase.MENU, "host in the menu")
	check(not Events.is_event_active() and Events.is_power_on(), "host: events reset")
	check(not Game.is_ui_locked(), "host: no UI lock left")
	await wait_sec(1.5) # the clients finish their menu checks before the runner collects


# ---------------------------------------------------------------- helpers

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


func _pid(key: String) -> int:
	return 1 if key == "host" else int(_ids.get(key, 0))


func _player(key: String) -> Player:
	return Game.world.get_player(_pid(key)) if Game.world != null else null


func _put_me(pos: Vector3, look: Vector3) -> void:
	_place_local(pos, look, null, null)


## Diagnostics: every Player whose physics body sits away from its node ("peer: node -> physics").
func _phys_mismatch() -> Array:
	var out := []
	if Game.world == null:
		return out
	for p in Game.world.get_players():
		var phys: Transform3D = PhysicsServer3D.body_get_state(p.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		if phys.origin.distance_to(p.global_position) > 0.1:
			out.append("%d: node %s physics %s" % [p.peer_id, p.global_position, phys.origin])
	return out


## Names of the colliders (world | players) a standing capsule at `at` overlaps, `me` excluded (diagnostics).
func _bodies_at(at: Vector3, me: Player) -> Array:
	var out := []
	var space := Game.world.get_world_3d().direct_space_state
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = Player.STAND_HEIGHT
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = capsule
	params.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * Player.STAND_HEIGHT * 0.5)
	params.collision_mask = Const.LAYER_WORLD | Const.LAYER_PLAYER
	params.exclude = [me.get_rid()]
	for hit in space.intersect_shape(params, 8):
		var col: Object = hit.get("collider")
		out.append("%s@%s" % [col.name if col is Node else str(col), (col as Node3D).global_position if col is Node3D else "?"])
	return out


## True when `p` stands within 0.4 m of one of the room's back-room slots.
func _at_a_backroom_slot(p: Player) -> bool:
	if p == null or not is_instance_valid(p) or Game.world == null:
		return false
	for slot in Room.BACKROOM_SLOTS.size():
		if p.global_position.distance_to(Game.world.room.get_backroom_transform(slot).origin) < 0.4:
			return true
	return false


func _none_flying() -> bool:
	for it in Game.world.items.get_items():
		if it.is_flying():
			return false
	return true


func _stat_total(key: StringName) -> int:
	var n := 0
	for id in Net.players:
		n += GameState.get_stat(int(id), key)
	return n


static func _written_in(r: Dictionary, peer: int, reason: String) -> int:
	var n := 0
	for e in (r.get("written", []) as Array):
		if int(e[0]) == peer and (reason == "" or String(e[1]) == reason):
			n += 1
	return n


func run_both(k1: String, a1: String, args1: Dictionary, k2: String, a2: String, args2: Dictionary) -> Array:
	var s1 := cmd(_ids[k1], a1, args1)
	var s2 := cmd(_ids[k2], a2, args2)
	return [await await_ack(s1), await await_ack(s2)]


func _reports(keys: Array) -> Dictionary:
	var seqs := {}
	for k in keys:
		seqs[k] = cmd(_ids[k], "report")
	var out := {}
	for k in keys:
		out[k] = await await_ack(seqs[k])
	return out


func checkpoint(tag: String, keys: Array, ui: bool = false) -> void:
	var peers := []
	var names := {}
	for k in keys:
		peers.append(_ids[k])
		names[_ids[k]] = NAMES[k]
	await checkpoint_peers(tag, peers, names, ui)


## GameState.stats must be bit-identical on every peer.
func _stats_everywhere(tag: String) -> void:
	var sig := _stats_sig()
	var reps := await _reports(["a", "b", "c"])
	for k in reps:
		check(String(reps[k].get("stats", "?")) == sig, "[%s] %s: stats identical to the host" % [tag, NAMES[k]])
		if String(reps[k].get("stats", "?")) != sig:
			print("      host : " + sig)
			print("      %s: %s" % [NAMES[k], reps[k].get("stats", "?")])
