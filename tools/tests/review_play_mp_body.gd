extends "res://tools/tests/qa_net_base.gd"
## Review 9.2 (items/interaction/stations): two-process regression test for team-favor purchases racing each other.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_play_mp_body.gd
## The host picks a random port and launches the client process itself (same body, --role=client); the client's
## output lands in the same log and its check / error counts are reported back to the host before it leaves.
##
## A favor BUY request used to name only the upgrade, so the host sold "the next level" to every request it got:
##   R1  two workers press BUY on the same favor card (both show level 0, $200) before either answer arrives:
##       the host bought level 1 AND level 2 ($200 + $340); the second worker paid a price nobody showed him.
##   R2  one worker on a slow link: the supply window's 1 s double-click guard runs out before the answer, the
##       card still shows the old price, a second press bought the next level too.
## Fixed by sending the level the card showed with the request; the host refuses it once the level moved on.

const PRICE_CHANGED_TEXT := "Price changed"   # ShopCounter.REASON_PRICE_CHANGED (literal: runs on old code too)

var role: String = "host"
var _pid: int = -1
var _client_id: int = 0
## Host: GameState level of the favor when the host's own (first) click ran, -1 = never ran.
var _host_click_level: int = -1

func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	_label = "review_mp:" + role
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()

# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var port := 0
	var err: Error = ERR_CANT_CREATE
	for attempt in 6:
		port = 30000 + randi() % 9000
		err = Game.start_host("Boss's Pet", port)
		if err == OK:
			break
	if not check(err == OK, "host on a random port (%d)" % port):
		finish(); return
	if not await wait_until(func(): return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 10.0, "host world ready"):
		finish(); return
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/tests/run_test.gd", "--", "--body=res://tools/tests/review_play_mp_body.gd",
			"--role=client", "--port=%d" % port, "--timeout=100"])
	_pid = OS.create_process(OS.get_executable_path(), args)
	if not check(_pid > 0, "launched the client process"):
		finish(); return
	if not await wait_until(func(): return Game.world.get_players().size() == 2, 30.0, "client joined (Player node on the host)"):
		_end(); return
	for p in Game.world.get_players():
		if p.peer_id != Const.SERVER_PEER_ID:
			_client_id = p.peer_id
	GameState.server_add_money(3000)

	var shop: ShopCounter = station("ShopCounter")
	stand_near(shop, 1.2)
	await wait_frames(2)
	shop.open_shop_for(Game.local_player)
	var ui := shop.get_shop_ui()
	ui.show_tab(ShopUI.TAB_UPGRADES, false)
	var r := await run_cmd(_client_id, "open_favors")
	check(bool(r.get("ok", false)), "client: supply window open on FAVORS, in range of the host")

	step("R1: two workers press BUY on the same favor (Better Cut, level 0 -> 1, $200) at the same moment")
	var talk := Config.balance.get_upgrade(&"sweet_talk")
	var money := GameState.money
	check(GameState.get_upgrade_level(talk.id) == 0, "Better Cut starts at level 0")
	r = await run_cmd(_client_id, "race_click", {"id": String(talk.id)})
	check(_host_click_level == 0, "the host's own click ran first, at level 0 (ordered ahead on channel 0): %d" % _host_click_level)
	check(bool(r.get("saw_level_0", false)), "client: its card showed level 0 / $%d when it pressed BUY" % talk.cost_for_level(1))
	check(GameState.get_upgrade_level(talk.id) == 1,
			"one press = one level: Better Cut is level 1, not %d" % GameState.get_upgrade_level(talk.id))
	check(GameState.money == money - talk.cost_for_level(1),
			"team charged once ($%d), not for a level nobody saw (spent $%d)" % [talk.cost_for_level(1), money - GameState.money])
	var race_toasts: Array = r.get("toasts", [])
	check(race_toasts.any(func(t): return String(t).contains(PRICE_CHANGED_TEXT)),
			"client told the price changed %s" % [race_toasts])
	check(not race_toasts.any(func(t): return String(t).contains("level 2")), "client did not buy level 2 %s" % [race_toasts])
	check(String(r.get("feedback", "")).contains(PRICE_CHANGED_TEXT), "client's supply window footer: '%s'" % r.get("feedback", ""))
	check(String(r.get("card_text", "")).contains("$%d" % talk.cost_for_level(2)),
			"client's card now offers level 2 at $%d ('%s')" % [talk.cost_for_level(2), r.get("card_text", "")])

	step("R2: one worker on a slow link presses again after the window's 1 s guard ran out (Cheap Fertilizer, $150)")
	var fert := Config.balance.get_upgrade(&"fertilizer")
	money = GameState.money
	r = await run_cmd(_client_id, "lag_double_click", {"id": String(fert.id), "stall_ms": 2200})
	check(bool(r.get("second_click_sent", false)), "client: second press sent while its card still showed level 0 (%s)" % r.get("why", ""))
	check(GameState.get_upgrade_level(fert.id) == 1,
			"slow link: Cheap Fertilizer is level 1, not %d" % GameState.get_upgrade_level(fert.id))
	check(GameState.money == money - fert.cost_for_level(1),
			"slow link: charged $%d once (spent $%d)" % [fert.cost_for_level(1), money - GameState.money])
	var lag_toasts: Array = r.get("toasts", [])
	check(lag_toasts.any(func(t): return String(t).contains(PRICE_CHANGED_TEXT)), "slow link: second press refused %s" % [lag_toasts])

	step("R3: a request that matches the current level still buys (no false refusals)")
	money = GameState.money
	r = await run_cmd(_client_id, "click", {"id": String(fert.id)})
	check(GameState.get_upgrade_level(fert.id) == 2 and GameState.money == money - fert.cost_for_level(2),
			"fresh press buys level 2 for $%d" % fert.cost_for_level(2))
	check(not (r.get("toasts", []) as Array).any(func(t): return String(t).contains(PRICE_CHANGED_TEXT)), "no refusal %s" % [r.get("toasts", [])])
	await checkpoint_peers("after the favor races", [_client_id], {_client_id: "client"})
	shop.close_shop()
	_end()

## Collects the client's own result, lets it leave, waits for its process, then finishes the host.
func _end() -> void:
	if _client_id > 0 and _client_id in multiplayer.get_peers():
		var rep := await run_cmd(_client_id, "report", {}, 10.0)
		check(int(rep.get("fails", -1)) == 0 and int(rep.get("errors", -1)) == 0,
				"client process: %s checks failed, %s unexpected errors" % [rep.get("fails", "?"), rep.get("errors", "?")])
		cmd(_client_id, "finish")
	if _pid > 0:
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(_pid) and Time.get_ticks_msec() - t0 < 15000:
			await get_tree().process_frame
		check(not OS.is_process_running(_pid), "client process exited")
		if OS.is_process_running(_pid):
			OS.kill(_pid)
	finish()

## Client -> host, sent in the same frame as the client's own BUY press (and ahead of it on channel 0): the host
## presses BUY on the same favor in its own open supply window first.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_host_click(upgrade_id: String) -> void:
	if not multiplayer.is_server():
		return
	var shop: ShopCounter = station("ShopCounter")
	var ui := shop.get_shop_ui() if shop != null else null
	var card := ui.get_card(ShopCounter.KIND_UPGRADE, StringName(upgrade_id)) if ui != null else null
	if card != null and card.is_buy_enabled():
		_host_click_level = GameState.get_upgrade_level(StringName(upgrade_id))
		card.get_buy_button().pressed.emit()

## Client -> host: freeze the host for `ms` (a lag spike: requests queue up unanswered).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_stall(ms: int) -> void:
	if multiplayer.is_server():
		OS.delay_msec(clampi(ms, 0, 4000))

# =================================================================================================== CLIENT

func _client_main() -> void:
	var port := port_arg(0)
	if not check(Game.start_join("127.0.0.1", port, "Rival") == OK, "start_join on port %d" % port):
		finish(); return
	if not await wait_until(func(): return Game.local_player != null, 30.0, "client joined"):
		finish(); return
	await client_loop()
	finish()

func _favor_card(id: StringName) -> ShopCard:
	var shop: ShopCounter = station("ShopCounter")
	var ui := shop.get_shop_ui() if shop != null else null
	return ui.get_card(ShopCounter.KIND_UPGRADE, id) if ui != null else null

func _wait_real_msec(msec: int) -> void:
	var until := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame

func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	var shop: ShopCounter = station("ShopCounter")
	match action:
		"open_favors":
			stand_near(shop, 1.4)
			var seen := await server_sees_me()
			shop.open_shop_for(me)
			await wait_frames(2)
			var ui := shop.get_shop_ui()
			if ui != null:
				ui.show_tab(ShopUI.TAB_UPGRADES, false)
			ack(seq, {"ok": seen and ui != null and ui.is_open()})
		"race_click":
			var id := StringName(String(args.get("id", "")))
			var card := _favor_card(id)
			var level_before := GameState.get_upgrade_level(id)
			var saw_0 := card != null and card.is_buy_enabled() and level_before == 0 \
					and card.get_buy_button().text.contains("$%d" % Config.balance.get_upgrade(id).cost_for_level(1))
			_rpc_host_click.rpc_id(1, String(id))   # the host presses first ...
			if card != null:
				card.get_buy_button().pressed.emit()  # ... and we press in the same frame, from a level-0 card
			await sync_with_host()
			await wait_frames(2)
			var ui := shop.get_shop_ui()
			ack(seq, {"toasts": toasts_since(t), "saw_level_0": saw_0,
					"feedback": ui.get_feedback_text() if ui != null else "",
					"card_text": card.get_buy_button().text if card != null else ""})
		"lag_double_click":
			var id := StringName(String(args.get("id", "")))
			var card := _favor_card(id)
			var why := ""
			_rpc_stall.rpc_id(1, int(args.get("stall_ms", 2200)))
			var sent_first := card != null and card.is_buy_enabled()
			if sent_first:
				card.get_buy_button().pressed.emit()
			# The window swallows presses for ShopUI.PENDING_TIMEOUT_MSEC while the answer is outstanding.
			await _wait_real_msec(ShopUI.PENDING_TIMEOUT_MSEC + 150)
			var still_level_0 := GameState.get_upgrade_level(id) == 0
			var sent_second := false
			if not sent_first:
				why = "first press impossible (card missing/disabled)"
			elif not still_level_0:
				why = "the answer arrived before the guard ran out (host stall too short on this machine)"
			else:
				card.get_buy_button().pressed.emit()
				sent_second = true
				why = "ok"
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"toasts": toasts_since(t), "second_click_sent": sent_second, "why": why})
		"click":
			var card := _favor_card(StringName(String(args.get("id", ""))))
			if card != null:
				card.get_buy_button().pressed.emit()
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"report":
			ack(seq, {"fails": _fails, "errors": errors.errors.size()})
		_:
			await super(seq, action, args)
