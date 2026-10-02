extends "res://tools/tests/qa_net_base.gd"
## M17 cart multi-process body (cart agent). Driven by tools/tests/cart_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): hands out bundles, checks the server side
##   --role=client --who=a       Alpha: picks the truck up, loads, unloads and deposits through the real requests
##   --role=client --who=b       Bravo: joins late, sees the truck and its load, takes a bundle off it
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the truck at the dock spot on both peers; the client's pick-up (heavy on the client's own
## simulation, the truck in front of its body); loading floor bundles with the truck in hand, taking the top one off
## the standing truck (aim on the bags), loading it back from the hand; the client's deposit at the chute (one sale per
## bundle, the exact money, the cured stat, an empty truck after); the late joiner's copy of the load (data, bags,
## label, where it stands) and its own take; the canonical state on every peer at every checkpoint.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const PARK := Vector3(-4.0, 0.0, 2.0)

var role: String = "host"
var who: String = ""
var port: int = 7999
var _ids: Dictionary = {}
var _sales: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7999))
	_label = "cart_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	print("CART_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	GameState.sale_made.connect(func(amount: int, seller: int) -> void: _sales.append([amount, seller]))
	var items := Game.world.items
	var room := Game.world.room
	var chute: TurnInStation = station("TurnInStation")
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(6.0, 0.02, 5.0)
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_frames(2)
	var trucks := items_of(Const.ITEM_HAND_TRUCK)
	var truck: HandTruck = trucks[0] as HandTruck if trucks.size() == 1 else null
	if not check(truck != null and truck.global_position.distance_to(room.get_hand_truck_spot().origin) < 0.001, "host: one hand truck at the dock spot"):
		finish(); return
	await wait_sec(0.5)
	await checkpoint("the truck stands on the dock", ["a"])

	step("Alpha picks the truck up and walks it (heavy on his own simulation)")
	var r := await run_cmd(a, "pickup", {"truck": String(truck.name)}, 30.0)
	check(truck.holder_id == a, "host: Alpha holds the truck")
	check(bool(r.get("at_spot", false)), "Alpha saw it standing at the dock spot")
	check(String(r.get("prompt", "")) == "Pick up Hand truck (0/4)", "Alpha's prompt: '%s'" % r.get("prompt", ""))
	check(bool(r.get("heavy", false)) and is_equal_approx(float(r.get("walk", 0.0)), b.walk_speed * b.heavy_speed_factor)
			and is_equal_approx(float(r.get("sprint", 0.0)), b.walk_speed * b.heavy_speed_factor),
			"Alpha's body walks and 'sprints' at %.2f m/s (%s / %s)" % [b.walk_speed * b.heavy_speed_factor, r.get("walk"), r.get("sprint")])
	check(bool(r.get("follows", false)), "on Alpha's peer the truck stands in front of his body")
	await wait_sec(0.3)
	var alpha: Player = Game.world.get_player(a)
	check(alpha.is_carrying_heavy() and truck.global_transform.origin.distance_to(HandTruck.get_held_transform(alpha).origin) < 0.01,
			"host: the truck is in front of Alpha's body here too")

	step("Alpha loads two bundles from the floor (the truck in hand)")
	var p1 := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 2}, PARK + Vector3(1.5, 0.0, 0.0)) as Product
	var p2 := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1}, PARK + Vector3(1.5, 0.0, 1.2)) as Product
	r = await run_cmd(a, "load_floor", {"items": [String(p1.name), String(p2.name)]}, 30.0)
	check(String(r.get("prompt", "")) == "Load Purple Haze x2 (0/4)", "Alpha's prompt on the bundle: '%s'" % r.get("prompt", ""))
	check(truck.get_load() == [{"strain_id": &"purple", "amount": 2, "cured": false, "dry_left": 0.0}, {"strain_id": &"budget", "amount": 1, "cured": false, "dry_left": 0.0}],
			"host: the load %s" % [truck.get_load()])
	check(items_of(Const.ITEM_PRODUCT).is_empty(), "host: both bundles despawned")
	check(String(r.get("cargo", "")) == HandTruck.encode_cargo(truck.cargo) and int(r.get("bags", -1)) == 2, "Alpha's copy: '%s', %s bags" % [r.get("cargo", ""), r.get("bags")])
	check(int(r.get("events", 0)) == 2, "load_changed fired twice on Alpha's peer")
	await checkpoint("two bundles on the truck", ["a"])

	step("Alpha drops it, takes the top bundle off, and loads it back from his hands")
	r = await run_cmd(a, "drop", {}, 20.0)
	check(truck.holder_id == 0 and bool(r.get("dropped", false)), "host: the truck stands")
	r = await run_cmd(a, "take_one", {"truck": String(truck.name)}, 30.0)
	var held := items.get_held_by(a) as Product
	check(String(r.get("prompt", "")) == "Take one (2/4)", "Alpha aims at the bags: '%s'" % r.get("prompt", ""))
	check(held != null and held.get_props() == {"strain_id": "budget", "amount": 1} and truck.get_load_count() == 1, "host: the top bundle (Budget Bud x1) is in Alpha's hands, one left")
	check(r.get("props", {}) == {"strain_id": "budget", "amount": 1}, "Alpha holds it with that data %s" % [r.get("props", {})])
	r = await run_cmd(a, "load_standing", {"truck": String(truck.name)}, 30.0)
	check(String(r.get("prompt", "")) == "Load Budget Bud x1 (1/4)", "Alpha's prompt on the truck: '%s'" % r.get("prompt", ""))
	check(items.get_held_by(a) == null and truck.get_load_count() == 2 and truck.get_load()[1]["strain_id"] == &"budget", "host: back on the truck")
	await checkpoint("taken and loaded back", ["a"])

	step("a cured bundle, then Alpha deposits all three at the chute")
	var cured := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "golden", "amount": 2, "cured": true}, PARK + Vector3(1.5, 0.0, -1.2)) as Product
	r = await run_cmd(a, "pickup", {"truck": String(truck.name), "high": true}, 30.0)
	check(truck.holder_id == a and String(r.get("prompt", "")) == "Pick up Hand truck (2/4)", "Alpha picks it up by the handle: '%s'" % r.get("prompt", ""))
	r = await run_cmd(a, "load_floor", {"items": [String(cured.name)]}, 30.0)
	check(truck.get_load_count() == 3 and bool(truck.get_load()[2]["cured"]), "host: the cured bundle is on top")
	var mult := GameState.get_sale_multiplier()
	var expected: Array = []
	var total := 0
	for i in range(truck.get_load_count() - 1, -1, -1):
		var e: Dictionary = truck.get_load()[i]
		var v := TurnInStation.compute_sale_value(b.get_seed(e["strain_id"]), int(e["amount"]), mult, bool(e["cured"]))
		expected.append([v, a])
		total += v
	var money0 := GameState.money
	var dep0 := GameState.get_stat(a, Const.STAT_DEPOSITED)
	_sales.clear()
	r = await run_cmd(a, "deposit", {"truck": String(truck.name)}, 30.0)
	check(String(r.get("prompt", "")) == "Deposit 3 bundles (+$%d)" % total, "Alpha's chute prompt: '%s'" % r.get("prompt", ""))
	check(_sales == expected, "host: three sales for Alpha, top first %s" % [_sales])
	check(GameState.money == money0 + total and GameState.get_stat(a, Const.STAT_DEPOSITED) == dep0 + total and GameState.get_stat(a, Const.STAT_CURED) == 1,
			"host: +$%d, STAT_DEPOSITED +%d, STAT_CURED 1 for Alpha" % [total, total])
	check(truck.get_load_count() == 0 and truck.holder_id == a and items_of(Const.ITEM_PRODUCT).is_empty(), "host: the truck is empty, still in Alpha's hands")
	check(int(r.get("money", -1)) == GameState.money and bool(r.get("empty", false)) and int(r.get("bags", -1)) == 0, "Alpha saw the same cash and an empty truck")
	await checkpoint("after the deposit", ["a"])

	step("two more on it, parked; a late joiner")
	var q1 := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1, "cured": true}, PARK + Vector3(1.5, 0.0, 0.0)) as Product
	var q2 := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "golden", "amount": 3, "dry_left": 12.5}, PARK + Vector3(1.5, 0.0, 1.2)) as Product
	r = await run_cmd(a, "load_floor", {"items": [String(q1.name), String(q2.name)]}, 30.0)
	r = await run_cmd(a, "drop", {}, 20.0)
	check(truck.holder_id == 0 and truck.get_load_count() == 2, "host: parked with two bundles")
	await checkpoint("parked", ["a"])
	print("CART_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bb, "late_check", {"truck": String(truck.name), "cargo": HandTruck.encode_cargo(truck.cargo), "at": truck.rest_position, "yaw": truck.rest_rotation.y}, 30.0)
	check(bool(r.get("found", false)) and bool(r.get("cargo_ok", false)), "Bravo has the truck and its load ('%s')" % r.get("cargo", ""))
	check(int(r.get("bags", -1)) == 2 and String(r.get("label", "")) == "2/4" and bool(r.get("label_visible", false)), "Bravo sees two bags and the label '%s'" % r.get("label", ""))
	check(bool(r.get("at_ok", false)), "where it stands on Bravo's peer")
	await checkpoint("late joiner", ["a", "b"])
	r = await run_cmd(bb, "take_one", {"truck": String(truck.name)}, 30.0)
	var got := items.get_held_by(bb) as Product
	check(got != null and got.get_props() == {"strain_id": "golden", "amount": 3, "dry_left": 12.5} and truck.get_load_count() == 1,
			"host: Bravo took the top bundle with its data %s" % [got.get_props() if got != null else {}])
	await checkpoint("Bravo took one", ["a", "b"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(a, "finish")
	cmd(bb, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bb), 20.0, "both left")
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
	match action:
		"pickup":
			var truck := item_named(String(args.get("truck", ""))) as HandTruck
			var info := {"at_spot": false, "prompt": "", "heavy": false, "walk": 0.0, "sprint": 0.0, "follows": false}
			if truck != null:
				info["at_spot"] = truck.holder_id == 0 and truck.global_position.distance_to(Game.world.room.get_hand_truck_spot().origin) < 0.001
				# From the plate side (at the dock spot the handle side is against the wall), the crosshair on the handle.
				await _aim(truck, truck.global_transform * Vector3(0.0, 1.245, 0.18), -truck.global_basis.z)
				info["prompt"] = truck.get_prompt(me) if truck.can_interact(me) else "denied: " + truck.get_denied_reason(me)
				truck.interact(me)
				var got := await wait_until_quiet(func() -> bool: return truck.holder_id == me.peer_id, 8.0)
				check(got, "I hold the truck")
				await wait_frames(2)
				info["heavy"] = me.is_carrying_heavy()
				info["follows"] = truck.global_transform.is_equal_approx(HandTruck.get_held_transform(me))
				if not bool(args.get("high", false)):
					info["walk"] = await _measure_speed(false)
					info["sprint"] = await _measure_speed(true)
				await server_sees_me()
			ack(seq, info)
		"load_floor":
			var info := {"prompt": "", "cargo": "", "bags": -1, "events": 0}
			var truck := HandTruck.held_by(me)
			var events := [0]
			if truck != null:
				truck.load_changed.connect(func() -> void: events[0] += 1)
			var first := true
			for n in (args.get("items", []) as Array):
				var bundle := item_named(String(n))
				if bundle == null or truck == null:
					check(false, "bundle %s and the truck in hand" % n)
					continue
				_stand_by(bundle.global_position + Vector3(-1.2, 0.0, 0.0), bundle.global_position)
				await server_sees_me()
				if first:
					info["prompt"] = bundle.get_prompt(me)
					first = false
				var count := truck.get_load_count()
				bundle.interact(me)
				check(await wait_until_quiet(func() -> bool: return truck.get_load_count() == count + 1, 8.0), "%s is on the truck on my peer" % n)
			await sync_with_host()
			if truck != null:
				info["cargo"] = HandTruck.encode_cargo(truck.cargo)
				info["bags"] = truck.get_node(^"Visual/Load").get_child_count()
				info["events"] = events[0]
			ack(seq, info)
		"drop":
			var truck := HandTruck.held_by(me)
			Game.world.items.request_drop()
			var dropped := truck != null and await wait_until_quiet(func() -> bool: return truck.holder_id == 0, 8.0)
			await sync_with_host()
			ack(seq, {"dropped": dropped})
		"take_one":
			var truck := item_named(String(args.get("truck", ""))) as HandTruck
			var info := {"prompt": "", "props": {}}
			if truck != null:
				await _aim(truck, truck.get_load_center(), -truck.global_basis.z)
				info["prompt"] = truck.get_prompt(me)
				var count := truck.get_load_count()
				truck.interact(me)
				var got := await wait_until_quiet(func() -> bool: return me.get_held_item() is Product and truck.get_load_count() == count - 1, 8.0)
				check(got, "the top bundle is in my hands")
				if got:
					info["props"] = (me.get_held_item() as Product).get_props()
			await sync_with_host()
			ack(seq, info)
		"load_standing":
			var truck := item_named(String(args.get("truck", ""))) as HandTruck
			var info := {"prompt": ""}
			if truck != null:
				await _aim(truck, truck.global_position + Vector3.UP * 0.5, -truck.global_basis.z)
				info["prompt"] = truck.get_prompt(me)
				var count := truck.get_load_count()
				truck.interact(me)
				check(await wait_until_quiet(func() -> bool: return me.get_held_item() == null and truck.get_load_count() == count + 1, 8.0), "my bundle went on the truck")
			await sync_with_host()
			ack(seq, info)
		"deposit":
			var chute: TurnInStation = station("TurnInStation")
			var truck := HandTruck.held_by(me)
			var info := {"prompt": "", "money": -1, "empty": false, "bags": -1}
			if chute != null and truck != null:
				stand_near(chute, 1.3)
				await server_sees_me()
				info["prompt"] = chute.get_prompt(me)
				chute.interact(me)
				info["empty"] = await wait_until_quiet(func() -> bool: return truck.get_load_count() == 0, 8.0)
				await sync_with_host()
				await wait_frames(2)
				info["bags"] = truck.get_node(^"Visual/Load").get_child_count()
			info["money"] = GameState.money
			ack(seq, info)
		"late_check":
			var info := {"found": false, "cargo_ok": false, "cargo": "", "bags": -1, "label": "", "label_visible": false, "at_ok": false}
			var want := String(args.get("cargo", ""))
			var ok := await wait_until_quiet(func() -> bool:
				var t := item_named(String(args.get("truck", ""))) as HandTruck
				return t != null and HandTruck.encode_cargo(t.cargo) == want, 10.0)
			var truck := item_named(String(args.get("truck", ""))) as HandTruck
			if truck != null:
				info["found"] = true
				info["cargo_ok"] = ok
				info["cargo"] = HandTruck.encode_cargo(truck.cargo)
				info["bags"] = truck.get_node(^"Visual/Load").get_child_count()
				var label := truck.get_node(^"LoadLabel") as Label3D
				info["label"] = label.text
				info["label_visible"] = label.visible
				var at: Vector3 = args.get("at", Vector3.INF)
				info["at_ok"] = truck.global_position.distance_to(at) < 0.001 and absf(angle_difference(truck.rotation.y, float(args.get("yaw", 0.0)))) < 0.001 \
						and not truck.is_held()
			ack(seq, info)
		_:
			await super(seq, action, args)


## Client: stand 1.4 m from `truck` on the side `side` points to (a unit vector from the truck), looking at `target`;
## then wait until the host has the move.
func _aim(truck: HandTruck, target: Vector3, side: Vector3) -> void:
	var me: Player = Game.local_player
	var flat := Vector3(side.x, 0.0, side.z).normalized()
	var at := truck.global_position + flat * 1.4
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(at.x, 0.02, at.z)
	# Let the body settle first (a collider nearby pushes it out), then look from where the camera really is.
	for i in 3:
		await get_tree().physics_frame
	var d := target - me.camera.global_position
	me.rotation = Vector3(0.0, atan2(-d.x, -d.z), 0.0)
	await get_tree().physics_frame
	d = target - me.camera.global_position
	me.head.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())
	await get_tree().physics_frame
	await server_sees_me()
	check(me.global_position.distance_to(Vector3(at.x, me.global_position.y, at.z)) < 0.05, "standing where I meant to (%s)" % me.global_position)


## Client: stand at `pos` facing `look`.
func _stand_by(pos: Vector3, look: Vector3) -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, atan2(-(look.x - pos.x), -(look.z - pos.z)), 0.0)
	me.head.rotation.x = 0.0


## Client: walks the local body forward for a moment (the real input actions) and returns its settled speed.
func _measure_speed(sprint: bool) -> float:
	var me: Player = Game.local_player
	_stand_by(PARK, PARK + Vector3(0.0, 0.0, -1.0))
	for i in 3:
		await get_tree().physics_frame
	Input.action_press(&"move_forward")
	if sprint:
		Input.action_press(&"sprint")
	for i in 24:
		await get_tree().physics_frame
	var v := Vector2(me.velocity.x, me.velocity.z).length()
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")
	for i in 12:
		await get_tree().physics_frame
	return v
