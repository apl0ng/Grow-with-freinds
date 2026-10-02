extends "res://tools/tests/qa_net_base.gd"
## M14 loop multi-process body (loop agent). Driven by tools/tests/loop_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): hands out bundles, checks the server side
##   --role=client --who=a       Alpha: hangs a bundle through the real Interactable RPC, watches it dry, takes it off
##                               the hook and deposits it at the chute, reports what it saw
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the client's hang (the bundle rests on hook 1 on both peers, `rack` and `dry_left` synced, the
## client's own rack reads the hook as taken); both peers see `dry_left` fall and `cured` flip (label, darker tint);
## the client takes the cured bundle (`rack` clears) and sells it: both see the bonus ($196 for Purple Haze) and
## STAT_CURED; a bundle taken off early keeps its remainder on both peers and sells at the plain value; a rack the
## host filled reads "Rack is full." on the client, whose rack state is derived from the synced bundles alone.

const NAMES := {"host": "Hosty", "a": "Alpha"}
## The host shortens the cure so the countdown can be watched (the host alone runs that clock).
const TEST_CURE_SEC := 4.0

var role: String = "host"
var who: String = ""
var port: int = 7976
var _ids: Dictionary = {}


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7976))
	_label = "loop_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.cure_sec = TEST_CURE_SEC
	b.end_round_on_quota_met = false
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	print("LOOP_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	var items := Game.world.items
	var rack1: DryingRack = station("DryingRack1")
	var rack2: DryingRack = station("DryingRack2")
	var chute: TurnInStation = station("TurnInStation")
	if not check(rack1 != null and rack2 != null and chute != null, "both racks and the chute exist"):
		finish(); return
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(6.0, 0.02, 5.0)
	await wait_sec(0.5)
	await checkpoint("joined", ["a"])

	step("Alpha hangs a bundle through the real RPC; both peers watch it dry")
	var bundle := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, Vector3.ZERO, a) as Product
	check(bundle != null and bundle.holder_id == a, "host: a Purple Haze bundle in Alpha's hands")
	var seq := cmd(a, "hang_and_watch", {"station": "DryingRack1"})
	check(await wait_until_quiet(func() -> bool: return bundle.rack and bundle.holder_id == 0, 12.0), "host: the bundle hangs (rack = true, nobody holds it)")
	check(rack1.get_hook_item(0) == bundle and bundle.global_position.distance_to(rack1.get_hook_position(0)) < 0.001, "host: on hook 1 of rack 1")
	check(bundle.dry_left <= TEST_CURE_SEC and bundle.dry_left > 0.0 and not bundle.cured, "host: dry_left starts at the cure time (%.1f)" % bundle.dry_left)
	var first := bundle.dry_left
	check(await wait_until_quiet(func() -> bool: return bundle.dry_left < first, 4.0), "host: dry_left falls (%.1f -> %.1f)" % [first, bundle.dry_left])
	check(await wait_until_quiet(func() -> bool: return bundle.cured, TEST_CURE_SEC + 4.0), "host: cured")
	check(bundle.dry_left == 0.0 and bundle.rack, "host: dry_left 0, still on its hook")
	var r := await await_ack(seq, 30.0)
	check(bool(r.get("prompt_ok", false)), "Alpha saw the 'Hang to dry' prompt")
	check(bool(r.get("hung", false)) and bool(r.get("on_hook", false)), "Alpha saw the bundle on hook 1 (its own rack reads the hook as taken)")
	check(bool(r.get("rack_at_release", false)), "on Alpha's copy `rack` was set before the hand let go (the hang sound, not the floor thud)")
	var seen: Array = r.get("dry_seen", [])
	check(seen.size() >= 3, "Alpha saw dry_left change at least three times %s" % [seen])
	var falling := true
	for i in range(1, seen.size()):
		if float(seen[i]) >= float(seen[i - 1]):
			falling = false
	check(falling and float(seen[0]) <= TEST_CURE_SEC and float(seen[seen.size() - 1]) == 0.0, "always falling, from the cure time down to 0")
	check(bool(r.get("cured", false)) and String(r.get("tag", "")) == "Cured x1" and String(r.get("label", "")) == "Purple Haze x1 (Cured)",
			"Alpha saw it cured ('%s', '%s')" % [r.get("tag", ""), r.get("label", "")])
	check(bool(r.get("darker", false)), "Alpha's copy has the darker tint")
	check(String(r.get("countdown_tag", "")).begins_with("x1 · "), "Alpha's label counted down ('%s')" % r.get("countdown_tag", ""))
	await checkpoint("cured on the hook", ["a"])

	step("Alpha takes the cured bundle and deposits it")
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	check(GameState.get_stat(a, Const.STAT_CURED) == 0, "host: no cured deposits yet")
	r = await run_cmd(a, "take_and_sell", {"item": String(bundle.name)}, 30.0)
	check(bool(r.get("taken", false)) and bool(r.get("rack_cleared", false)), "Alpha took it off the hook and saw `rack` clear")
	check(String(r.get("prompt", "")) == "Deposit Purple Haze x1, cured (+$196)", "Alpha's chute prompt: '%s'" % r.get("prompt", ""))
	check(bool(r.get("sold", false)), "Alpha saw the bundle go")
	check(GameState.money == money0 + 196 and GameState.round_sales == sales0 + 196, "host: paid $196 (140 x 1.4), cash %d -> %d" % [money0, GameState.money])
	check(GameState.get_stat(a, Const.STAT_CURED) == 1, "host: STAT_CURED 1 for Alpha")
	check(int(r.get("money", -1)) == GameState.money and int(r.get("sales", -1)) == GameState.round_sales, "Alpha saw the same cash and deposits (%s, %s)" % [r.get("money"), r.get("sales")])
	check(int(r.get("stat_cured", -1)) == 1, "Alpha saw its STAT_CURED (%s)" % r.get("stat_cured"))
	check(rack1.get_hung_count() == 0, "host: rack 1 is empty")
	await checkpoint("after the cured deposit", ["a"])

	step("taken off early: the remainder is kept on both peers and it sells plain")
	b.cure_sec = 20.0
	var wet := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, Vector3.ZERO, a) as Product
	money0 = GameState.money
	r = await run_cmd(a, "hang_take_early", {"station": "DryingRack1"}, 30.0)
	check(bool(r.get("hung", false)) and bool(r.get("taken", false)), "Alpha hung it and took it back")
	check(wet.holder_id == a and not wet.rack and not wet.cured and wet.dry_left > 0.0 and wet.dry_left < 20.0, "host: not cured, %.2f s still to dry" % wet.dry_left)
	check(is_equal_approx(float(r.get("dry_left", -1.0)), wet.dry_left) and not bool(r.get("cured", true)) and not bool(r.get("rack", true)),
			"Alpha sees the same remainder (%s)" % r.get("dry_left"))
	check(String(r.get("status", "")) == "%d s to dry" % ceili(wet.dry_left), "Alpha's bundle says '%s'" % r.get("status", ""))
	r = await run_cmd(a, "sell", {}, 20.0)
	check(String(r.get("prompt", "")) == "Deposit Purple Haze x1 (+$140)" and bool(r.get("sold", false)), "Alpha deposits it: '%s'" % r.get("prompt", ""))
	check(GameState.money == money0 + 140 and GameState.get_stat(a, Const.STAT_CURED) == 1, "host: the plain $140, STAT_CURED unchanged")
	await checkpoint("after the plain deposit", ["a"])

	step("a rack the host filled reads full on the client")
	for i in 3:
		var filler := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1}, Vector3.ZERO, 1) as Product
		check(filler != null and rack2.server_hang(me), "host: bundle %d on rack 2" % (i + 1))
	# Dried at once (the host's clock): three drying bundles would keep changing `dry_left` under the state checkpoint.
	rack2.tick(21.0)
	check(rack2.is_full() and rack2.get_hook_item(2).get(&"cured") == true, "host: rack 2 is full (three cured bundles on its hooks)")
	var extra := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1}, Vector3.ZERO, a) as Product
	r = await run_cmd(a, "full_check", {"station": "DryingRack2", "other": "DryingRack1"}, 20.0)
	check(int(r.get("hung", -1)) == 3 and bool(r.get("full", false)), "Alpha counts three bundles on rack 2")
	check(not bool(r.get("can", true)) and String(r.get("denied", "")) == "Rack is full.", "Alpha's prompt: '%s'" % r.get("denied", ""))
	check(_has_toast(r.get("toasts", []), "Rack is full."), "pressing E anyway: the toast %s" % [r.get("toasts", [])])
	check(bool(r.get("other_can", false)), "rack 1 would still take it")
	check(extra.holder_id == a and not extra.rack, "host: the bundle stayed in Alpha's hands")
	await checkpoint("rack 2 full", ["a"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 4, true)
	cmd(a, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a), 20.0, "Alpha left")
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


static func _has_toast(list: Variant, substring: String) -> bool:
	if not (list is Array):
		return false
	for t in list:
		if String(t).to_lower().contains(substring.to_lower()):
			return true
	return false


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
		"hang_and_watch":
			var rack: DryingRack = station(String(args.get("station", "DryingRack1")))
			var info := {"prompt_ok": false, "hung": false, "on_hook": false, "dry_seen": [], "cured": false, "tag": "", "label": "",
					"darker": false, "countdown_tag": ""}
			await wait_until_quiet(func() -> bool: return me.get_held_item() is Product, 8.0)
			var bundle := me.get_held_item() as Product
			if rack != null and bundle != null:
				stand_near(rack, 1.3)
				await server_sees_me()
				info["prompt_ok"] = rack.can_interact(me) and rack.get_prompt(me) == "Hang to dry"
				check(bool(info["prompt_ok"]), "prompt 'Hang to dry' with the bundle in hand")
				var fresh: Color = (bundle.get(&"_tint") as StandardMaterial3D).albedo_color
				# What this peer knew at the instant the bundle left the hand: `rack` must already be set (it is synced
				# ahead of holder_id), or the release would sound like a drop on the floor.
				var at_release := {"seen": false, "rack": false}
				bundle.holder_changed.connect(func(_old: int, new_holder: int) -> void:
					if new_holder == 0 and not at_release["seen"]:
						at_release["seen"] = true
						at_release["rack"] = bundle.rack)
				rack.interact(me)
				info["hung"] = await wait_until_quiet(func() -> bool: return bundle.rack and bundle.holder_id == 0, 8.0)
				check(bool(info["hung"]), "the bundle hangs on my copy")
				info["rack_at_release"] = bool(at_release["seen"]) and bool(at_release["rack"])
				info["on_hook"] = rack.get_hook_item(0) == bundle and bundle.global_position.distance_to(rack.get_hook_position(0)) < 0.001 \
						and rack.get_free_hook() == 1
				var tag := bundle.get_node(^"AmountLabel") as Label3D
				info["countdown_tag"] = tag.text
				# Every value of dry_left this peer sees, until the bundle is cured.
				var seen: Array = [bundle.dry_left]
				var t0 := Time.get_ticks_msec()
				while not bundle.cured and Time.get_ticks_msec() - t0 < 20000:
					if bundle.dry_left != float(seen[seen.size() - 1]):
						seen.append(bundle.dry_left)
					await get_tree().process_frame
				if bundle.dry_left != float(seen[seen.size() - 1]):
					seen.append(bundle.dry_left)
				info["dry_seen"] = seen
				info["cured"] = bundle.cured
				check(bundle.cured, "saw it cured")
				info["tag"] = tag.text
				info["label"] = bundle.get_label_text()
				var now: Color = (bundle.get(&"_tint") as StandardMaterial3D).albedo_color
				info["darker"] = now.v < fresh.v - 0.05
				await sync_with_host()
			ack(seq, info)
		"take_and_sell":
			var bundle := item_named(String(args.get("item", ""))) as Product
			var info := {"taken": false, "rack_cleared": false, "prompt": "", "sold": false, "money": -1, "sales": -1, "stat_cured": -1}
			if bundle != null:
				stand_near(bundle, 1.2)
				await server_sees_me()
				bundle.interact(me)
				info["taken"] = await wait_until_quiet(func() -> bool: return bundle.holder_id == me.peer_id, 8.0)
				check(bool(info["taken"]), "took the bundle off the hook")
				info["rack_cleared"] = await wait_until_quiet(func() -> bool: return not bundle.rack, 8.0)
				check(bundle.cured, "it is still cured in my hands")
				var sold := await _sell(me)
				info["prompt"] = sold["prompt"]
				info["sold"] = sold["sold"]
			info["money"] = GameState.money
			info["sales"] = GameState.round_sales
			info["stat_cured"] = GameState.get_stat(me.peer_id, Const.STAT_CURED)
			ack(seq, info)
		"hang_take_early":
			var rack: DryingRack = station(String(args.get("station", "DryingRack1")))
			var info := {"hung": false, "taken": false, "dry_left": -1.0, "cured": true, "rack": true, "status": ""}
			await wait_until_quiet(func() -> bool: return me.get_held_item() is Product, 8.0)
			var bundle := me.get_held_item() as Product
			if rack != null and bundle != null:
				stand_near(rack, 1.3)
				await server_sees_me()
				rack.interact(me)
				info["hung"] = await wait_until_quiet(func() -> bool: return bundle.rack and bundle.holder_id == 0, 8.0)
				var first := bundle.dry_left
				await wait_until_quiet(func() -> bool: return bundle.dry_left < first - 0.9, 8.0)
				bundle.interact(me)
				info["taken"] = await wait_until_quiet(func() -> bool: return bundle.holder_id == me.peer_id and not bundle.rack, 8.0)
				await sync_with_host()
				info["dry_left"] = bundle.dry_left
				info["cured"] = bundle.cured
				info["rack"] = bundle.rack
				info["status"] = bundle.get_status_text()
			ack(seq, info)
		"sell":
			var sold := await _sell(me)
			ack(seq, sold)
		"full_check":
			var rack: DryingRack = station(String(args.get("station", "DryingRack2")))
			var other: DryingRack = station(String(args.get("other", "DryingRack1")))
			var t := toasts.size()
			await wait_until_quiet(func() -> bool: return me.get_held_item() is Product and rack.get_hung_count() == 3, 8.0)
			stand_near(rack, 1.3)
			await server_sees_me()
			var info := {"hung": rack.get_hung_count(), "full": rack.is_full(), "can": rack.can_interact(me),
					"denied": rack.get_denied_reason(me), "other_can": other != null and other.can_interact(me)}
			rack.interact(me)
			await sync_with_host()
			info["toasts"] = toasts_since(t)
			ack(seq, info)
		_:
			await super(seq, action, args)


## Client: walks to the chute with the bundle in hand, reads the prompt and deposits through the real interact RPC.
func _sell(me: Player) -> Dictionary:
	var chute: TurnInStation = station("TurnInStation")
	var bundle := me.get_held_item()
	var out := {"prompt": "", "sold": false}
	if chute == null or bundle == null:
		return out
	stand_near(chute, 1.3)
	await server_sees_me()
	out["prompt"] = chute.get_prompt(me)
	chute.interact(me)
	out["sold"] = await wait_until_quiet(func() -> bool: return not is_instance_valid(bundle) or bundle.is_queued_for_deletion() or not bundle.is_inside_tree(), 8.0)
	await sync_with_host()
	await wait_frames(2)
	return out
