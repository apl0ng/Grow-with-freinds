extends "res://tools/tests/qa_net_base.gd"
## M12 flame multi-process body (flame agent). Driven by tools/tests/flame_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): plants a crop, checks the server side
##   --role=client --who=a       Alpha: breaks the cabinet glass through the real Interactable RPC, fires the
##                               flamethrower through Flamethrower.request_fire (the real RPC), reports what it saw
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the client breaks the glass (deposit, misuse write-up toast, `broken` + the restock countdown
## seen on the client, the flamethrower in its hands); the client fires: the server drains fuel and scorches the plot
## in its cone; the client sees `firing` flip on and off, the fuel drop, the plot empty and the arson write-up toast.

const NAMES := {"host": "Hosty", "a": "Alpha"}
const ITEM_FLAMETHROWER: StringName = &"flamethrower"

var role: String = "host"
var who: String = ""
var port: int = 7958
var _ids: Dictionary = {}
var _write_ups: Array = []   # host: [peer, reason]
var _purchases: Array = []   # host: [cost, buyer, what]


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7958))
	_label = "flame_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	print("FLAME_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	GameState.worker_written_up.connect(func(p: int, reason: String, _c: int) -> void: _write_ups.append([p, reason]))
	GameState.purchase_made.connect(func(cost: int, buyer: int, what: String) -> void: _purchases.append([cost, buyer, what]))
	var items := Game.world.items
	var cabinet: EmergencyCabinet = station("EmergencyCabinet")
	if not check(cabinet != null and not cabinet.broken, "cabinet stocked"):
		finish(); return
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(6.0, 0.02, 5.0) # out of every cone
	await wait_sec(0.5)
	await checkpoint("joined", ["a"])

	step("Alpha breaks the glass through the real RPC")
	var money0 := GameState.money
	var strikes0 := GameState.get_write_ups(a)
	var r := await run_cmd(a, "break_glass", {}, 25.0)
	check(bool(r.get("ok", false)), "Alpha: the flamethrower landed in its hands")
	var ft := items.get_held_by(a) as Flamethrower
	check(ft != null and ft.fuel == b.flamethrower_fuel_sec and not ft.firing, "host: Alpha holds a full flamethrower")
	check(cabinet.broken and cabinet.restock_left > 0, "host: cabinet broken, restock in %d s" % cabinet.restock_left)
	check(GameState.money == money0 - b.cabinet_deposit - b.write_up_fine, "host: deposit + misuse fine taken (%d)" % GameState.money)
	check(_purchases.has([b.cabinet_deposit, a, EmergencyCabinet.DEPOSIT_WHAT]), "host: purchase_made(deposit, Alpha, '%s') %s" % [EmergencyCabinet.DEPOSIT_WHAT, _purchases])
	check(_write_ups.has([a, Const.WRITE_UP_MISUSE]) and GameState.get_write_ups(a) == strikes0 + 1, "host: misuse write-up for Alpha %s" % [_write_ups])
	check(int(r.get("money", -1)) == GameState.money and int(r.get("money_before", -1)) == money0, "Alpha saw the deposit land (%s -> %s)" % [r.get("money_before"), r.get("money")])
	check(bool(r.get("broken", false)) and int(r.get("restock_left", 0)) > 0 and String(r.get("prompt", "")).begins_with("Restocking ("), "Alpha sees the cabinet broken: '%s'" % r.get("prompt", ""))
	check(is_equal_approx(float(r.get("fuel", -1.0)), b.flamethrower_fuel_sec), "Alpha sees the full tank (%s)" % r.get("fuel"))
	check(_has_toast(r.get("toasts", []), "written up"), "Alpha saw the write-up toast %s" % [r.get("toasts", [])])
	check(int(r.get("write_ups", -1)) == strikes0 + 1, "Alpha's strike count synced")
	await checkpoint("after the break", ["a"])

	step("Alpha fires at GrowPlot 1; the server drains fuel and scorches it")
	var plot1 := plot(1)
	check(plot1.server_plant(&"budget") and plot1.server_water(2.0), "plot 1 planted and watered")
	await wait_sec(0.3)
	var scorched0 := GameState.get_stat(a, Const.STAT_SCORCHED)
	_write_ups.clear()
	var fuel0 := ft.fuel
	var seq := cmd(a, "fire_at", {"station": "GrowPlot1"})
	check(await wait_until_quiet(func() -> bool: return ft.firing, 12.0), "host: firing on")
	check(await wait_until_quiet(func() -> bool: return plot1.stage == GrowPlot.Stage.EMPTY, 6.0), "host: plot 1 scorched")
	check(GameState.get_stat(a, Const.STAT_SCORCHED) == scorched0 + 1, "host: STAT_SCORCHED for Alpha")
	check(_write_ups.has([a, Const.WRITE_UP_ARSON]), "host: arson write-up for Alpha %s" % [_write_ups])
	r = await await_ack(seq, 25.0)
	check(bool(r.get("firing_seen", false)), "Alpha saw `firing` go on")
	check(bool(r.get("plot_empty", false)) and bool(r.get("scorched_seen", false)), "Alpha saw the plot burn (ash on its copy)")
	check(float(r.get("fuel_after", INF)) < fuel0 - 0.3, "Alpha saw the fuel drop (%.1f -> %s)" % [fuel0, r.get("fuel_after")])
	check(bool(r.get("firing_off", false)) and not ft.firing, "firing off on both peers")
	check(ft.fuel < fuel0 - 0.3 and is_equal_approx(ft.fuel, float(r.get("fuel_after", INF))), "same fuel on both peers (%.1f)" % ft.fuel)
	check(_has_toast(r.get("toasts", []), "written up"), "Alpha saw the arson write-up toast %s" % [r.get("toasts", [])])
	await checkpoint("after the fire", ["a"])

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
		"break_glass":
			var cab: EmergencyCabinet = station("EmergencyCabinet")
			var t := toasts.size()
			var money_before := GameState.money
			var ok := cab != null and me != null
			if ok:
				stand_near(cab, 1.2)
				await server_sees_me()
				check(cab.get_prompt(me) == EmergencyCabinet.PROMPT_BREAK and cab.can_interact(me), "prompt 'Break glass' before the break")
				cab.interact(me)
				ok = await wait_until_quiet(func() -> bool: return me.get_held_item() is Flamethrower, 8.0)
				check(ok, "the flamethrower arrived in my hands")
				await sync_with_host()
				await wait_frames(2)
			var ft := me.get_held_item() as Flamethrower if me != null else null
			ack(seq, {"ok": ok, "money": GameState.money, "money_before": money_before,
					"broken": cab.broken if cab != null else false, "restock_left": cab.restock_left if cab != null else 0,
					"prompt": cab.get_prompt(me) if cab != null else "", "fuel": ft.fuel if ft != null else -1.0,
					"toasts": toasts_since(t), "write_ups": GameState.get_write_ups(me.peer_id) if me != null else -1})
		"fire_at":
			var st: GrowPlot = station(String(args.get("station", "GrowPlot1")))
			var ft := me.get_held_item() as Flamethrower
			var t := toasts.size()
			var info := {"firing_seen": false, "plot_empty": false, "scorched_seen": false, "fuel_after": INF, "firing_off": false}
			if st != null and ft != null:
				stand_near(st, 1.5)
				me.head.rotation.x = -0.35 # look down at the plant
				await server_sees_me()
				await wait_sec(0.3) # let the yaw / pitch sync too
				ft.request_fire(true)
				info["firing_seen"] = await wait_until_quiet(func() -> bool: return ft.firing, 8.0)
				check(bool(info["firing_seen"]), "saw firing go on")
				info["plot_empty"] = await wait_until_quiet(func() -> bool: return st.stage == GrowPlot.Stage.EMPTY, 6.0)
				check(bool(info["plot_empty"]), "saw the plot empty")
				info["scorched_seen"] = st.is_scorched()
				await wait_sec(0.4)
				ft.request_fire(false)
				info["firing_off"] = await wait_until_quiet(func() -> bool: return not ft.firing, 8.0)
				check(bool(info["firing_off"]), "saw firing go off")
				await sync_with_host()
				await wait_frames(2)
				info["fuel_after"] = ft.fuel
			info["toasts"] = toasts_since(t)
			ack(seq, info)
		_:
			await super(seq, action, args)
