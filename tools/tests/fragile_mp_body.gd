extends "res://tools/tests/qa_net_base.gd"
## M23 fragile multi-process body (fragile agent). Driven by tools/tests/fragile_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): hands out bundles, checks the server side
##   --role=client --who=a       Alpha: picks a bundle up and throws it through the real requests
##   --role=client --who=b       Bravo: joins late, sees the bruises, deposits the bruised bundle at the chute
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: a client's throw bruises the bundle on the host (bundle_bruised names the client) and on the
## client (the synced count, the name, the tag, the dent, the grubby bag, the thud at the moment it arrives); the toast
## reaches the thrower only and only once a shift; the value is the same on every peer (host, thrower, late joiner,
## and what the chute pays the late joiner); the late joiner gets the bruises with the spawn state, and a bruised
## bundle's entry in the hand truck's load; the canonical state agrees on every peer at every checkpoint.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const LANE := Vector3(-3.0, 0.0, 3.0)

var role: String = "host"
var who: String = ""
var port: int = 7904
var _ids: Dictionary = {}
var _sales: Array = []
var _bruised: Array = []
var _knocks: Array = []        # client: [bruises, the last voice was the bruise thud]


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7904))
	_label = "fragile_mp:" + (role if role == "host" else who)
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
	print("FRAGILE_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var items := Game.world.items
	var chute: TurnInStation = station("TurnInStation")
	GameState.sale_made.connect(func(amount: int, seller: int) -> void: _sales.append([amount, seller]))
	items.bundle_bruised.connect(func(it: Item, n: int, thrower: int) -> void: _bruised.append([String(it.name), n, thrower]))
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(6.0, 0.02, 5.0)
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_sec(0.5)
	await checkpoint("joined", ["a"])

	step("Alpha throws a bundle at the floor (the real request): bruised on every peer")
	var p := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, LANE) as Product
	var r := await run_cmd(a, "grab", {"item": String(p.name)})
	check(bool(r.get("ok", false)) and p.holder_id == a, "Alpha holds the bundle (host view: holder %d)" % p.holder_id)
	r = await run_cmd(a, "throw", {"item": String(p.name), "dir": Vector3(0.0, 0.0, -1.0), "pitch": -1.1, "want": 1}, 25.0)
	check(p.bruises == 1 and not p.is_flying() and p.holder_id == 0, "host: it landed with one bruise")
	check(_bruised == [[String(p.name), 1, a]], "host: bundle_bruised names Alpha as the thrower %s" % [_bruised])
	check(items.was_told_bruise(a) and not items.was_told_bruise(1), "host: Alpha was told, the host was not")
	check(not toast_seen(Product.TOAST_BRUISED), "host: no bruise toast on the host's screen")
	var value := chute.get_sale_value(p)
	check(value == TurnInStation.compute_sale_value(b.get_seed(&"purple"), 1, GameState.get_sale_multiplier(), false, 1) and value == 112,
			"host: it is worth $%d now (x0.8)" % value)
	check(int(r.get("bruises", -1)) == 1 and bool(r.get("landed", false)), "Alpha: one bruise on his copy")
	check(String(r.get("name", "")) == "Purple Haze x1, bruised" and String(r.get("tag", "")) == "x1, bruised",
			"Alpha: '%s', tag '%s'" % [r.get("name", ""), r.get("tag", "")])
	check(bool(r.get("dented", false)) and bool(r.get("grimy", false)), "Alpha: dented and grubby")
	check(r.get("knocks", []) == [[1, true]], "Alpha: the landing played the bruise thud (the bruise was there first) %s" % [r.get("knocks", [])])
	check(int(r.get("toasts", -1)) == 1, "Alpha: 'Bruised. It pays less.' once (%s)" % r.get("toasts", -1))
	check(int(r.get("value", -1)) == value, "Alpha: the same value ($%s)" % r.get("value", -1))
	await checkpoint("after the first bruise", ["a"])

	step("Alpha throws it again: two bruises, no second toast")
	r = await run_cmd(a, "grab", {"item": String(p.name)})
	check(bool(r.get("ok", false)) and p.holder_id == a, "Alpha picks it up again")
	r = await run_cmd(a, "throw", {"item": String(p.name), "dir": Vector3(-1.0, 0.0, 0.0), "pitch": -0.6, "want": 2}, 25.0)
	value = chute.get_sale_value(p)
	check(p.bruises == 2 and _bruised.size() == 2 and value == 84, "host: two bruises, worth $%d (x0.6)" % value)
	check(int(r.get("bruises", -1)) == 2 and String(r.get("name", "")) == "Purple Haze x1, badly bruised" and int(r.get("value", -1)) == value,
			"Alpha: two, '%s', $%s" % [r.get("name", ""), r.get("value", -1)])
	check(int(r.get("toasts", -1)) == 1, "Alpha: still only the one toast (%s)" % r.get("toasts", -1))
	check(r.get("knocks", []) == [[1, true], [2, true]], "Alpha: the second landing thudded the same way %s" % [r.get("knocks", [])])
	await checkpoint("after the second bruise", ["a"])

	step("a bruised bundle on the hand truck")
	var trucks := items_of(Const.ITEM_HAND_TRUCK)
	var truck: HandTruck = trucks[0] as HandTruck if trucks.size() == 1 else null
	if not check(truck != null, "the dock's hand truck"):
		finish(); return
	var q := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 2, "bruises": 1}, truck.global_position + Vector3(1.2, 0.0, 0.0)) as Product
	await wait_frames(2)
	check(q != null and q.bruises == 1 and truck.server_load(q, 0), "host: a bundle spawned with a bruise goes on the truck")
	var cargo := HandTruck.encode_cargo(truck.cargo)
	check(cargo == "budget|2|0|0.00|1", "host: the load '%s'" % cargo)
	var load_value := chute.get_load_value(truck)
	r = await run_cmd(a, "report", {"item": String(p.name), "truck": String(truck.name), "cargo": cargo}, 20.0)
	check(bool(r.get("cargo_ok", false)) and int(r.get("load_value", -1)) == load_value, "Alpha: the same load ('%s', $%s)" % [r.get("cargo", ""), r.get("load_value", -1)])
	await checkpoint("the truck loaded", ["a"])

	step("a late joiner")
	print("FRAGILE_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bb, "report", {"item": String(p.name), "truck": String(truck.name), "cargo": cargo}, 30.0)
	check(int(r.get("bruises", -1)) == 2 and String(r.get("name", "")) == "Purple Haze x1, badly bruised" and String(r.get("tag", "")) == "x1, badly bruised",
			"Bravo: two bruises, '%s', tag '%s'" % [r.get("name", ""), r.get("tag", "")])
	check(bool(r.get("dented", false)) and bool(r.get("grimy", false)), "Bravo: dented and grubby from the spawn state")
	check(int(r.get("value", -1)) == value, "Bravo: the same value ($%s)" % r.get("value", -1))
	check(not bool(r.get("last_is_bruise", true)), "Bravo: no thud for bruises that were already there")
	check(bool(r.get("cargo_ok", false)) and int(r.get("load_value", -1)) == load_value, "Bravo: the truck's load with its bruise ('%s', $%s)" % [r.get("cargo", ""), r.get("load_value", -1)])
	await checkpoint("late joiner", ["a", "b"])

	step("Bravo deposits the badly bruised bundle at the chute")
	r = await run_cmd(bb, "grab", {"item": String(p.name)})
	check(bool(r.get("ok", false)) and p.holder_id == bb, "Bravo holds it")
	var money0 := GameState.money
	_sales.clear()
	r = await run_cmd(bb, "deposit", {}, 25.0)
	check(String(r.get("prompt", "")) == "Deposit Purple Haze x1, badly bruised (+$%d)" % value, "Bravo's chute prompt: '%s'" % r.get("prompt", ""))
	check(_sales == [[value, bb]] and GameState.money == money0 + value, "host: paid $%d to Bravo's name %s" % [value, _sales])
	check(int(r.get("money", -1)) == GameState.money, "Bravo saw the same cash on hand")
	check(int(r.get("toasts", -1)) == 0, "Bravo never had a bruise toast (he bruised nothing)")
	await checkpoint("after the deposit", ["a", "b"])

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
			var it := item_named(String(args.get("item", ""))) as Product
			var info := {"landed": false}
			if it != null:
				_watch(it)
				var dir: Vector3 = args.get("dir", Vector3.FORWARD)
				me.velocity = Vector3.ZERO
				me.look_at(me.global_position + Vector3(dir.x, 0.0, dir.z), Vector3.UP)
				me.head.rotation.x = float(args.get("pitch", 0.0))
				await server_sees_me()
				await wait_sec(0.3) # let the yaw and the pitch sync too
				Game.world.items.request_throw()
				check(await wait_until_quiet(func() -> bool: return it.is_flying(), 8.0), "saw it take off")
				info["landed"] = await wait_until_quiet(func() -> bool: return not it.is_flying(), 6.0)
				check(await wait_until_quiet(func() -> bool: return it.bruises >= int(args.get("want", 1)), 6.0), "the bruise arrived")
				await sync_with_host()
				info.merge(_describe(it), true)
			ack(seq, info)
		"report":
			var item_name := String(args.get("item", ""))
			await wait_until_quiet(func() -> bool: return item_named(item_name) != null, 10.0)
			var it := item_named(item_name) as Product
			var info := {}
			if it != null:
				info = _describe(it)
			var last := Sfx.get_last_voice()
			info["last_is_bruise"] = last != null and last.get(&"stream") == Sfx.get_stream(&"bruise")
			var want := String(args.get("cargo", ""))
			var truck_name := String(args.get("truck", ""))
			info["cargo_ok"] = await wait_until_quiet(func() -> bool:
				var t := item_named(truck_name) as HandTruck
				return t != null and HandTruck.encode_cargo(t.cargo) == want, 10.0)
			var truck := item_named(truck_name) as HandTruck
			var chute: TurnInStation = station("TurnInStation")
			if truck != null:
				info["cargo"] = HandTruck.encode_cargo(truck.cargo)
				info["load_value"] = chute.get_load_value(truck) if chute != null else -1
			ack(seq, info)
		"deposit":
			var chute: TurnInStation = station("TurnInStation")
			var held := me.get_held_item()
			var info := {"prompt": "", "money": -1, "toasts": _toast_count()}
			if chute != null and held != null:
				var id := held.get_instance_id()
				stand_near(chute, 1.3)
				await server_sees_me()
				info["prompt"] = chute.get_prompt(me)
				chute.interact(me)
				check(await wait_until_quiet(func() -> bool:
					var o := instance_from_id(id) as Item
					return o == null or o.is_queued_for_deletion(), 8.0), "the bundle went down the chute")
				await sync_with_host()
			info["money"] = GameState.money
			ack(seq, info)
		_:
			await super(seq, action, args)


## Client: what this peer has for `it`.
func _describe(it: Product) -> Dictionary:
	var cluster := it.get_node(^"Visual/Cluster") as Node3D
	var grimy := not it._get_bag_meshes().is_empty()
	for mesh in it._get_bag_meshes():
		if mesh.material_overlay != Product._get_grime():
			grimy = false
	var chute: TurnInStation = station("TurnInStation")
	return {"bruises": it.bruises, "name": it.get_display_name(), "tag": (it.get_node(^"AmountLabel") as Label3D).text,
			"dented": cluster.scale.y < cluster.scale.x - 0.05 and cluster.rotation.z > 0.05, "grimy": grimy,
			"value": chute.get_sale_value(it) if chute != null else -1, "toasts": _toast_count(), "knocks": _knocks.duplicate()}


## Client: records [bruises, the landing's voice was the bruise thud] at every landing of `it` on this peer
## (flight_changed(false) comes right after the landing's effects; the bruise arrives first, while it is in the air).
func _watch(it: Product) -> void:
	if it.has_meta(&"fragile_watched"):
		return
	it.set_meta(&"fragile_watched", true)
	it.flight_changed.connect(func(flying: bool) -> void:
		if flying or not is_instance_valid(it):
			return
		var v := Sfx.get_last_voice()
		_knocks.append([it.bruises, v != null and v.get(&"stream") == Sfx.get_stream(&"bruise")]))


func _toast_count() -> int:
	var n := 0
	for t in toasts:
		if String(t[0]) == Product.TOAST_BRUISED:
			n += 1
	return n
