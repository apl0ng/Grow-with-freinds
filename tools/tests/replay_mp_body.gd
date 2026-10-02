extends "res://tools/tests/qa_net_base.gd"
## M15 replay multi-process body (replay agent). Driven by tools/tests/replay_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host, --replay): sets conditions and a market, starts
##                               the shift, lets shift 2 roll, checks the server side
##   --role=client --who=a       Alpha: joins at once; reports what it sees, deposits, asks for a locked strain, buys
##   --role=client --who=b       Bravo: joins while the shift runs (the late joiner); reports what it sees
## Common args: --port=N --replay --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a
## final "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the replay signature (replay on, shift, payment due, conditions, market, HUD chips, briefing,
## strains on sale, the report's conditions) is the same text on the host and on every client, in WAITING, in the
## running shift, for the late joiner, after a change mid-shift and after shift 2's own roll; the flat lines are
## toasted on the clients when a shift starts; a client's deposit pays the market value on every peer; a client's
## request for a locked strain is refused by the host ("From shift 2.") whatever its card showed; a seed on clearance
## is charged at the day's price.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}

var role: String = "host"
var who: String = ""
var port: int = 7984
var _ids: Dictionary = {}


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7984))
	_label = "replay_mp:" + (role if role == "host" else who)
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
	check(Config.replay_enabled, "the host runs with --replay")
	GameState.replay_rng.seed = 84
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	print("REPLAY_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(6.0, 0.02, 5.0)
	await wait_sec(0.5)
	await checkpoint("joined", ["a"])
	var purple: SeedDef = b.get_seed(&"purple")
	var budget: SeedDef = b.get_seed(&"budget")
	var golden: SeedDef = b.get_seed(&"golden")

	step("WAITING: the host sets the coming shift")
	var r := await run_cmd(a, "replay_state", {"expect": _sig()})
	check(bool(r.get("ok", false)) and GameState.get_conditions().is_empty(), "Alpha sees the plain shift 1 (%s)" % r.get("sig", ""))
	var plain := GameState.get_quota_for(1)
	_cond([&"short_clock", &"buyer:purple"])
	GameState.server_set_market({&"purple": 1.2, &"budget": 0.8})
	check(GameState.quota == int(round(plain * 0.85)) and is_equal_approx(GameState.time_left, b.round_length_sec - 40.0), "host: $%d due, %.0f s (a short clock)" % [GameState.quota, GameState.time_left])
	r = await run_cmd(a, "replay_state", {"expect": _sig()})
	_same_sig("Alpha, WAITING", r)
	check(is_equal_approx(float(r.get("time", -1.0)), b.round_length_sec - 40.0), "Alpha's clock already shows the short shift (%s s)" % r.get("time"))
	check(r.get("chips", []) == ["Short clock", "%s buyer" % purple.display_name], "Alpha's chips: %s" % [r.get("chips", [])])

	step("the shift starts")
	GameState.request_start_round()
	check(GameState.is_playing() and GameState.quota == int(round(plain * 0.85)), "host: PLAYING, 15% less due")
	r = await run_cmd(a, "replay_state", {"expect": _sig()})
	_same_sig("Alpha, PLAYING", r)
	check(_has_toast(r.get("toasts", []), "A short clock. Forty seconds less. 15% less due.") and _has_toast(r.get("toasts", []), "A buyer wants %s." % purple.display_name),
			"Alpha was told both flat lines when the shift started %s" % [r.get("toasts", [])])
	check(float(r.get("time", 9999.0)) < b.round_length_sec - 39.0, "Alpha's clock runs from 40 s less (%.0f)" % float(r.get("time", -1.0)))
	print("REPLAY_SHIFT_RUNNING")

	step("the late joiner")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		finish(); return
	_ids["b"] = _peer_named("b")
	var bravo: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bravo) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bravo, "replay_state", {"expect": _sig()})
	_same_sig("Bravo, joined mid-shift", r)
	check(r.get("chips", []) == ["Short clock", "%s buyer" % purple.display_name], "Bravo's chips: %s" % [r.get("chips", [])])
	check(float(r.get("time", 9999.0)) < b.round_length_sec - 39.0 and int(r.get("quota", -1)) == GameState.quota, "Bravo's clock and payment due are the short shift's")
	await checkpoint("late joiner in", ["a", "b"])

	step("a client's deposit pays the market value")
	var pay := int(round(1 * purple.sale_value_per_unit * 1.0 * 1.0 * (1.2 * 1.5)))
	var bundle := Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, Vector3.ZERO, a)
	check(bundle != null and bundle.holder_id == a, "host: a %s bundle in Alpha's hands" % purple.display_name)
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	r = await run_cmd(a, "sell", {}, 30.0)
	check(String(r.get("prompt", "")) == "Deposit %s x1 (+$%d)" % [purple.display_name, pay], "Alpha's chute prompt shows the day's value: '%s'" % r.get("prompt", ""))
	check(bool(r.get("sold", false)) and GameState.money == money0 + pay and GameState.round_sales == sales0 + pay,
			"host: paid $%d (%d x 1.2 x 1.5), cash %d -> %d" % [pay, purple.sale_value_per_unit, money0, GameState.money])
	check(int(r.get("money", -1)) == GameState.money and int(r.get("sales", -1)) == GameState.round_sales, "Alpha saw the same cash and deposits")
	check(GameState.get_stat(a, Const.STAT_DEPOSITED) == pay, "host: Alpha's ledger says $%d" % pay)
	await checkpoint("after the deposit", ["a", "b"])
	r = await run_cmd(bravo, "card", {"seed": "purple"})
	check(String(r.get("stats", "")).contains("Deposits for $%d" % pay) and int(r.get("mark", 0)) == 1, "Bravo's supply card: $%d with the up mark (%s)" % [pay, r.get("stats", "")])
	r = await run_cmd(bravo, "card", {"seed": "budget"})
	check(int(r.get("mark", 0)) == -1 and not bool(r.get("locked", true)), "Bravo's %s card: the down mark" % budget.display_name)

	step("a locked strain asked for by a client")
	GameState.server_add_money(500)
	money0 = GameState.money
	r = await run_cmd(a, "buy_locked", {"seed": "golden"})
	check(bool(r.get("locked", false)) and not bool(r.get("enabled", true)) and String(r.get("button", "")) == "FROM SHIFT %d" % golden.unlock_round and String(r.get("lock_text", "")) == "From shift %d" % golden.unlock_round,
			"Alpha's %s card: '%s', disabled" % [golden.display_name, r.get("button", "")])
	check(_has_toast(r.get("toasts", []), "From shift %d." % golden.unlock_round), "the host refused the request: %s" % [r.get("toasts", [])])
	check(not bool(r.get("held", true)) and GameState.money == money0 and Game.world.items.get_held_by(a) == null, "nothing charged, nothing in Alpha's hands")

	step("a change mid-shift reaches everyone; clearance is charged")
	_cond([&"clearance"])
	GameState.server_set_market({})
	var seqs := {a: cmd(a, "replay_state", {"expect": _sig()}), bravo: cmd(bravo, "replay_state", {"expect": _sig()})}
	for p: int in seqs:
		r = await await_ack(seqs[p])
		_same_sig("%s, clearance" % Net.get_player_name(p), r)
	var cheap := maxi(int(round(budget.cost * 0.7)), 1)
	r = await run_cmd(a, "card", {"seed": "budget"})
	check(String(r.get("button", "")) == "BUY  $%d" % cheap and int(r.get("mark", 9)) == 0, "Alpha's %s card: '%s', no mark" % [budget.display_name, r.get("button", "")])
	money0 = GameState.money
	r = await run_cmd(a, "buy", {"seed": "budget"})
	check(bool(r.get("ok", false)) and GameState.money == money0 - cheap, "Alpha bought %s: the host charged $%d, not $%d" % [budget.display_name, cheap, budget.cost])
	await checkpoint("after the purchase", ["a", "b"])

	step("shift 2 rolls its own")
	b.end_round_on_quota_met = true
	GameState.server_add_sale(GameState.quota, 1)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "shift 1 paid")
	GameState.request_next_round()
	check(GameState.is_playing() and GameState.round_number == 2 and GameState.get_conditions().size() == 1 and GameState.get_market().size() == b.seeds.size(),
			"host: shift 2 with one rolled condition (%s) and a market" % [GameState.get_conditions()])
	check(GameState.is_strain_unlocked(&"golden"), "host: %s is sold now" % golden.display_name)
	seqs = {a: cmd(a, "replay_state", {"expect": _sig()}), bravo: cmd(bravo, "replay_state", {"expect": _sig()})}
	var line := ShiftConditions.get_line(GameState.get_conditions()[0])
	for p: int in seqs:
		r = await await_ack(seqs[p])
		var worker := Net.get_player_name(p)
		_same_sig("%s, shift 2" % worker, r)
		check(_has_toast(r.get("toasts", []), line) and _has_toast(r.get("toasts", []), "New at the window: %s." % golden.display_name), "%s was told the condition and what is new" % worker)
		check((r.get("on_sale", []) as Array).has("golden"), "%s can buy %s now" % [worker, golden.display_name])
	await checkpoint("shift 2", ["a", "b"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(a, "finish")
	cmd(bravo, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bravo), 20.0, "both clients left")
	finish()


func _same_sig(tag: String, r: Dictionary) -> void:
	var ok := bool(r.get("ok", false))
	check(ok, "[%s] the same conditions, market, chips, briefing, payment due and unlocks as the host" % tag)
	if not ok:
		print("      host : " + _sig())
		print("      peer : " + String(r.get("sig", "<no answer>")))


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


func _cond(ids: Array) -> void:
	var typed: Array[StringName] = []
	for id: Variant in ids:
		typed.append(StringName(str(id)))
	GameState.server_set_conditions(typed)


static func _has_toast(list: Variant, substring: String) -> bool:
	if not (list is Array):
		return false
	for t in list:
		if String(t).to_lower().contains(substring.to_lower()):
			return true
	return false


# =================================================================================================== EVERY PEER

## Everything replay shows on this peer, as one line: it must read the same on the host and on every client.
func _sig() -> String:
	var ids := PackedStringArray()
	for id in GameState.get_conditions():
		ids.append(String(id))
	var market := GameState.get_market()
	var keys: Array = market.keys()
	keys.sort_custom(func(x: Variant, y: Variant) -> bool: return String(x) < String(y))
	var prices := PackedStringArray()
	for k: Variant in keys:
		prices.append("%s=%.2f" % [k, float(market[k])])
	var report := PackedStringArray()
	for id in GameState.get_report_conditions():
		report.append(String(id))
	var factors := PackedStringArray()
	for def: SeedDef in Config.balance.seeds:
		factors.append("%.4f/%d" % [GameState.get_deposit_factor(def.id), GameState.get_seed_cost(def)])
	var hud: HUD = Game.world.get_node_or_null(^"HUD") as HUD if Game.world != null else null
	return "on=%s r%d q%d cond[%s] market{%s} chips[%s] brief[%s] sale[%s] report[%s] pay/cost[%s] gap=%.3f" % [GameState.is_replay_on(), GameState.round_number, GameState.quota,
			",".join(ids), ",".join(prices), ",".join(_chips(hud)), " | ".join(PackedStringArray(GameState.get_shift_briefing())), ",".join(PackedStringArray(_on_sale())),
			",".join(report), ",".join(factors), GameState.get_event_gap_factor()]


func _chips(hud: HUD) -> PackedStringArray:
	return hud.get_condition_chip_texts() if hud != null else PackedStringArray()


func _on_sale() -> Array:
	var out: Array = []
	for def: SeedDef in Config.balance.seeds:
		if GameState.is_strain_unlocked(def.id):
			out.append(String(def.id))
	return out


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
		"replay_state":
			var expect := String(args.get("expect", ""))
			var ok := await wait_until_quiet(func() -> bool: return _sig() == expect, float(args.get("timeout", CHECK_TIMEOUT)))
			check(ok, "the replay state matches the host's")
			if not ok:
				print("      host : " + expect)
				print("      here : " + _sig())
			var hud: HUD = Game.world.get_node_or_null(^"HUD") as HUD
			ack(seq, {"ok": ok, "sig": _sig(), "toasts": toasts_since(0), "time": GameState.time_left, "quota": GameState.quota, "chips": Array(_chips(hud)), "on_sale": _on_sale()})
		"sell":
			var chute: TurnInStation = station("TurnInStation")
			var info := {"prompt": "", "sold": false, "money": -1, "sales": -1}
			await wait_until_quiet(func() -> bool: return me.get_held_item() is Product, 8.0)
			var bundle := me.get_held_item()
			if chute != null and bundle != null:
				stand_near(chute, 1.3)
				await server_sees_me()
				info["prompt"] = chute.get_prompt(me)
				chute.interact(me)
				info["sold"] = await wait_until_quiet(func() -> bool: return not is_instance_valid(bundle) or bundle.is_queued_for_deletion() or not bundle.is_inside_tree(), 8.0)
				await sync_with_host()
				await wait_frames(2)
			check(bool(info["sold"]), "deposited the bundle")
			info["money"] = GameState.money
			info["sales"] = GameState.round_sales
			ack(seq, info)
		"card":
			ack(seq, await _card_info(me, StringName(String(args.get("seed", "")))))
		"buy_locked":
			var seed_id := StringName(String(args.get("seed", "")))
			var info := await _card_info(me, seed_id)
			var shop: ShopCounter = station("ShopCounter")
			var t := toasts.size()
			# The card's button is disabled; a client that sends the request anyway must be refused by the host.
			shop.request_buy_seed(seed_id)
			await sync_with_host()
			info["toasts"] = toasts_since(t)
			info["held"] = me.get_held_item() != null
			check(not bool(info["held"]), "no packet arrived")
			ack(seq, info)
		_:
			await super(seq, action, args)


## Client: walks to the counter, opens the supply window, reads one seed card and closes it again.
func _card_info(me: Player, seed_id: StringName) -> Dictionary:
	var info := {"button": "", "stats": "", "mark": 0, "locked": false, "enabled": false, "lock_text": ""}
	var shop: ShopCounter = station("ShopCounter")
	if shop == null:
		return info
	stand_near(shop, 1.3)
	await server_sees_me()
	shop.open_shop_for(me)
	await wait_frames(2)
	var ui := shop.get_shop_ui()
	var card := ui.get_card(ShopCounter.KIND_SEED, seed_id) if ui != null else null
	if card != null:
		info["button"] = card.get_buy_button().text
		info["stats"] = card.get_stats_text()
		info["mark"] = card.get_value_mark()
		info["locked"] = card.is_locked()
		info["enabled"] = card.is_buy_enabled()
		info["lock_text"] = card.get_lock_text()
	shop.close_shop()
	await wait_frames(1)
	return info
