extends "res://tools/tests/qa_net_base.gd"
## M10 physics multi-process body (physics agent). Driven by tools/tests/physics_mp.sh; every process runs this script:
##   --role=host                       the director (real Game.start_host)
##   --role=client --who=a             Alpha: picks a can up through the real Interactable RPC, THROWS it through
##                                     ItemManager.request_throw(), shoves the host from behind
##   --role=client --who=late          joins late (on PHYS_LAUNCH_LATE): sees the thrown can at rest where the host
##                                     has it, then watches a flight the host starts
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).

const NAMES := {"host": "Hosty", "a": "Alpha", "late": "Latecomer"}

var role: String = "host"
var who: String = ""
var port: int = 7862
var _ids: Dictionary = {}
var _host_staggers: Array = []   # host: [by_peer, was_stunned, held_before]


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7862))
	_label = "physics_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans, 10.0, "host world ready")
	print("PHYS_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	await wait_until(func() -> bool: return Game.world.get_player(_ids["a"]) != null, 10.0, "Alpha's Player node exists")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	var me: Player = Game.local_player
	var items := Game.world.items
	me.staggered.connect(func(by: int) -> void: _host_staggers.append([by, me.is_stunned(), items.get_held_by(1) != null]))
	await wait_sec(0.5)
	await checkpoint("joined", ["a"])

	step("Alpha throws a can through the real RPC")
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, Vector3(-3.0, 0.0, 3.0)) as WateringCan
	check(can != null, "spawned a can in the clear lane")
	if can == null:
		finish(); return
	var host_flights: Array = []
	can.flight_changed.connect(func(f: bool) -> void: host_flights.append(f))
	var r := await run_cmd(_ids["a"], "grab", {"item": String(can.name)})
	check(bool(r.get("ok", false)) and can.holder_id == _ids["a"], "Alpha holds the can (host view: holder %d)" % can.holder_id)
	var throws0 := GameState.get_stat(_ids["a"], Const.STAT_THROWS)
	r = await run_cmd(_ids["a"], "throw", {"item": String(can.name), "dir": Vector3(0.0, 0.0, -1.0)}, 25.0)
	check(bool(r.get("flying_seen", false)), "Alpha saw the can fly")
	check(bool(r.get("landed", false)), "Alpha saw it land")
	check(can.holder_id == 0 and not can.is_flying(), "host: can released and landed")
	check(host_flights == [true, false], "host saw the flight start and end %s" % [host_flights])
	var rest: Vector3 = r.get("rest", Vector3.INF)
	check(rest.is_finite() and can.global_position.distance_to(rest) <= 0.05,
			"same rest position on both peers (host %s, Alpha %s)" % [can.global_position, rest])
	check(can.global_position.z < 2.0 and absf(can.global_position.y) < 0.05, "it flew the way Alpha looked (-Z) and lies on the floor")
	check(int(r.get("layer", -1)) == Const.LAYER_ITEM, "Alpha: collision back after landing")
	check(GameState.get_stat(_ids["a"], Const.STAT_THROWS) == throws0 + 1, "STAT_THROWS counted for Alpha")
	await checkpoint("after the throw", ["a"])

	step("Alpha shoves the host from behind while the host holds a can")
	var can2 := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(2.0, 0.0, 2.0), 1) as WateringCan
	check(can2 != null and can2.holder_id == 1, "host holds a can")
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(0.0, 0.02, 0.0)
	me.rotation = Vector3.ZERO # facing -Z
	me.head.rotation.x = 0.0
	await wait_sec(0.4)
	_host_staggers.clear()
	var shoves0 := GameState.get_stat(_ids["a"], Const.STAT_SHOVES)
	r = await run_cmd(_ids["a"], "shove_from_behind", {"target": 1}, 25.0)
	check(_host_staggers.size() == 1 and int(_host_staggers[0][0]) == _ids["a"], "host: staggered(Alpha) fired once %s" % [_host_staggers])
	check(_host_staggers.size() == 1 and bool(_host_staggers[0][1]), "host was stunned when the signal fired")
	check(can2 != null and can2.holder_id == 0, "host dropped the can (shoved from behind)")
	check(GameState.get_stat(_ids["a"], Const.STAT_SHOVES) == shoves0 + 1, "STAT_SHOVES counted for Alpha")
	check(bool(r.get("saw", false)) and int(r.get("by", -1)) == _ids["a"], "Alpha saw the host stagger (cosmetic RPC) %s" % [r])
	await wait_sec(0.6)
	check(me.global_position.z < -0.4, "the host stumbled forward (-Z) to z=%.2f" % me.global_position.z)
	check(not me.is_stunned(), "host stun over")
	await checkpoint("after the shove", ["a"])

	step("late joiner")
	print("PHYS_LAUNCH_LATE")
	if not await wait_until(func() -> bool: return _peer_named("late") > 0, 40.0, "Latecomer registered"):
		finish(); return
	_ids["late"] = _peer_named("late")
	await wait_until(func() -> bool: return Game.world.get_player(_ids["late"]) != null, 10.0, "Latecomer's Player node exists")
	await wait_sec(0.5)
	r = await run_cmd(_ids["late"], "report_item", {"item": String(can.name)})
	check(bool(r.get("exists", false)) and int(r.get("holder", -1)) == 0 and not bool(r.get("flying", true)), "late joiner has the thrown can at rest")
	var late_rest: Vector3 = r.get("rest", Vector3.INF)
	check(late_rest.is_finite() and late_rest.distance_to(can.global_position) <= 0.05, "late joiner: same rest position %s" % late_rest)
	await checkpoint("late joiner", ["a", "late"])
	var seq := cmd(_ids["late"], "watch_flight", {"item": String(can.name)})
	await wait_sec(0.3)
	check(items.server_throw_item(can, Vector3(-3.0, 1.2, -2.0), Vector3(0.0, 9.0, 1.0), 1), "host throws the can high")
	r = await await_ack(seq, 25.0)
	check(bool(r.get("flying_seen", false)) and bool(r.get("landed", false)), "late joiner saw the flight and the landing")
	var watched_rest: Vector3 = r.get("rest", Vector3.INF)
	check(not can.is_flying() and watched_rest.is_finite() and watched_rest.distance_to(can.global_position) <= 0.05,
			"late joiner landed it where the host did (%s vs %s)" % [watched_rest, can.global_position])
	await checkpoint("after the high throw", ["a", "late"])

	step("finish")
	# The engine may log its relay notice for a peer that reset its ENet channels while a packet was queued.
	allow_error("Unable to send packet on channel 0", 4, true)
	cmd(_ids["a"], "finish")
	await wait_until(func() -> bool: return not Net.players.has(_ids["a"]), 20.0, "Alpha left")
	cmd(_ids["late"], "finish")
	await wait_until(func() -> bool: return Net.players.size() == 1, 20.0, "Latecomer left")
	finish()


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


func checkpoint(tag: String, keys: Array) -> void:
	var peers := []
	var names := {}
	for k in keys:
		peers.append(_ids[k])
		names[_ids[k]] = NAMES[k]
	await checkpoint_peers(tag, peers, names)


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		finish(); return
	await client_loop()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var items := Game.world.items if Game.world != null else null
	match action:
		"grab":
			var it := item_named(String(args.get("item", "")))
			var ok := it != null and me != null
			if ok:
				stand_near(it, 0.7)
				await server_sees_me()
				it.interact(me)
				ok = await wait_until_quiet(func() -> bool: return it.holder_id == me.peer_id, 8.0)
			ack(seq, {"ok": ok})
		"throw":
			var it := item_named(String(args.get("item", "")))
			var dir: Vector3 = args.get("dir", Vector3.FORWARD)
			me.velocity = Vector3.ZERO
			me.look_at(me.global_position + Vector3(dir.x, 0.0, dir.z), Vector3.UP)
			me.head.rotation.x = 0.0
			await server_sees_me()
			await wait_sec(0.3) # let the yaw sync too
			items.request_throw()
			var flying_seen := await wait_until_quiet(func() -> bool: return it != null and it.is_flying(), 8.0)
			check(flying_seen, "saw the can take off")
			check(me.get_held_item() == null, "hands empty after the throw")
			var landed := await wait_until_quiet(func() -> bool: return it != null and not it.is_flying(), 6.0)
			check(landed, "saw it land")
			await wait_frames(3)
			ack(seq, {"flying_seen": flying_seen, "landed": landed, "rest": it.position if it != null else Vector3.INF,
					"layer": it.get_collider().collision_layer if it != null else -1})
		"shove_from_behind":
			var target: Player = Game.world.get_player(int(args.get("target", 1)))
			var saw := {"seen": false, "by": -1}
			if target != null:
				target.staggered.connect(func(by: int) -> void: saw.seen = true; saw.by = by)
				var behind := target.global_position - target.get_flat_forward() * 1.2
				me.velocity = Vector3.ZERO
				me.global_position = Vector3(behind.x, 0.05, behind.z)
				me.look_at(Vector3(target.global_position.x, 0.05, target.global_position.z), Vector3.UP)
				me.head.rotation.x = 0.0
				await server_sees_me()
				await wait_sec(0.3)
				me.request_shove(target.peer_id)
				await wait_until_quiet(func() -> bool: return saw.seen, 8.0)
				check(saw.seen, "saw the host stagger")
			else:
				check(false, "no target player")
			await sync_with_host()
			ack(seq, {"saw": saw.seen, "by": saw.by})
		"report_item":
			var item_name := String(args.get("item", ""))
			var exists := await wait_until_quiet(func() -> bool: return item_named(item_name) != null, 8.0)
			var it := item_named(item_name)
			ack(seq, {"exists": exists, "rest": it.position if it != null else Vector3.INF,
					"holder": it.holder_id if it != null else -1, "flying": it.is_flying() if it != null else true})
		"watch_flight":
			var it := item_named(String(args.get("item", "")))
			var flying_seen := await wait_until_quiet(func() -> bool: return it != null and it.is_flying(), 10.0)
			check(flying_seen, "saw the flight start")
			if flying_seen:
				var rose := await wait_until_quiet(func() -> bool: return it.is_flying() and it.position.y > 1.5, 2.0)
				check(rose and it.get_collider().collision_layer == 0, "mid-flight: up in the air, collision off (%s)" % it.position)
			var landed := await wait_until_quiet(func() -> bool: return it != null and not it.is_flying(), 6.0)
			check(landed, "saw the landing")
			await wait_frames(3)
			ack(seq, {"flying_seen": flying_seen, "landed": landed, "rest": it.position if it != null else Vector3.INF})
		_:
			await super(seq, action, args)
