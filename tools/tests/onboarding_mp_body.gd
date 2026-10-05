extends "res://tools/tests/qa_net_base.gd"
## M19 onboarding multi-process body (onboarding agent). Driven by tools/tests/onboarding_mp.sh; every process runs
## this script with --guide (the plain game otherwise) and its own temp career file:
##   --role=host                 Hosty: a record with three shifts and guidance off; does every step of the loop himself
##   --role=client --who=a       Alpha: no record, guidance on; her guide follows the host's actions
##   --role=client --who=b       Bravo: no record, guidance on; joins in the middle of the guide
## Common args: --port=N --round-sec=900 --run=B5VP --career-file=user://onboarding_mp_<port>_<name>.cfg --timeout=S.
## Every process stands a fake Settings object in for the autoload (nothing is ever saved). Every process prints
## "ok   -" / "FAIL -" lines and a final "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: only the peer without a record gets the guide (the host's Story log, the HUD hint and the
## guide stay empty on the host the whole shift); Alpha's steps advance on the HOST's actions (buy, plant, water, the
## tray ripening, harvest, deposit) read from the synced state, each said once at her Boss; Bravo, joining while the
## crew is at the water step, gets the water line first and never the buy or plant line; both get the payment line
## after the host's deposit; at the end of the shift both clients switch guidance off and have the shift on file,
## the host writes nothing.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}

## Stands in for the Settings autoload: every write is recorded, nothing is saved.
class FakeSettings:
	extends RefCounted
	signal changed(key: StringName)
	var values: Dictionary = {&"guidance": true}
	var writes: Array = []

	func get_value(key: StringName, default: Variant = null) -> Variant:
		return values.get(key, default)

	func set_value(key: StringName, value: Variant) -> void:
		values[key] = value
		writes.append([key, value])
		changed.emit(key)


var role: String = "host"
var who: String = ""
var port: int = 9113
var guide: Guide
var fake := FakeSettings.new()
var _path: String = ""
var _ids: Dictionary = {}


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 9113))
	_label = "onboarding_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent and Config.has_arg("guide"),
			"its own career file (%s), --guide" % _path):
		finish(); return
	_remove(_path)
	guide = Story.guide
	guide.settings_override = fake
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
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string("[career]\nshifts=3\nbest_round=2\n")
	f.close()
	Career.load_file(_path)
	fake.set_value(&"guidance", false)
	fake.writes.clear()
	check(Career.get_record("shifts") == 3 and not guide.is_wanted(), "host: three shifts on file, guidance off: no guide")
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		_cleanup(); finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and Game.world != null, 10.0, "host world ready")
	print("ONB_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		_cleanup(); finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var room := Game.world.room
	var items := Game.world.items
	var me: Player = Game.local_player
	var hud := Game.world.get_node(^"HUD") as HUD
	var shop := room.get_station("ShopCounter") as ShopCounter
	var well := room.get_station("Well") as Well
	var chute := room.get_station("TurnInStation") as TurnInStation
	var tray := room.get_station("GrowPlot1") as GrowPlot

	step("shift 1: only Alpha gets the guide")
	var r := await run_cmd(a, "alley", {}, 20.0)
	check(String(r.get("line", "")) == Guide.ALLEY_LINE and bool(r.get("board", false)), "Alpha's board starts with the alley line ('%s')" % r.get("line", ""))
	check(guide.get_alley_line() == "", "the host's board has none")
	GameState.request_start_round()
	check(GameState.is_playing() and GameState.round_number == 1, "shift 1 runs")
	r = await _client_step(a, Guide.STEP_BUY, "Alpha")
	check(r.get("hint", "") == "E · buy seeds at the window", "Alpha's hint: '%s'" % r.get("hint", ""))
	check(not guide.is_active() and guide.said_log.is_empty() and hud.get_guide_hint_text() == "", "host: no guide, no line, no hint")

	step("the host buys")
	me.velocity = Vector3.ZERO
	me.global_position = room.get_station_access_point("ShopCounter") + Vector3(0.0, 0.05, 0.0)
	var bought := shop.server_buy_seed(1, &"budget")
	check(bool(bought.get("ok", false)), "the host bought seeds")
	await _client_step(a, Guide.STEP_PLANT, "Alpha")

	step("the host plants")
	tray._server_interact(me)
	check(tray.stage == GrowPlot.Stage.SEEDLING, "GrowPlot1 planted")
	await _client_step(a, Guide.STEP_WATER, "Alpha")

	step("Bravo joins in the middle of the guide")
	print("ONB_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		_cleanup(); finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	r = await _client_step(bb, Guide.STEP_WATER, "Bravo")
	var bravo_said: Array = r.get("said", [])
	check(bravo_said.size() == 1 and String(bravo_said[0]) == Guide.get_line(Guide.STEP_WATER), "Bravo's first line is the water line %s" % [bravo_said])
	check(not bool(r.get("heard_buy", true)) and not bool(r.get("heard_plant", true)), "Bravo never hears the buy or plant line")

	step("the host waters")
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	items.server_give_item(can, 1)
	can.set(&"charges", 0)
	well._server_interact(me)
	tray._server_interact(me)
	check(GameState.get_stat(1, Const.STAT_WATERED) == 1, "the host watered GrowPlot1")
	await _client_step(a, Guide.STEP_WAIT, "Alpha")
	await _client_step(bb, Guide.STEP_WAIT, "Bravo")

	step("the tray ripens")
	tray.stage = GrowPlot.Stage.READY
	await _client_step(a, Guide.STEP_HARVEST, "Alpha")
	await _client_step(bb, Guide.STEP_HARVEST, "Bravo")

	step("the host harvests")
	items.server_despawn_item(can)
	await wait_frames(1)
	tray._server_interact(me)
	check(items.get_held_by(1) != null and items.get_held_by(1).item_type == Const.ITEM_PRODUCT, "the host holds the bundle")
	await _client_step(a, Guide.STEP_DEPOSIT, "Alpha")
	await _client_step(bb, Guide.STEP_DEPOSIT, "Bravo")

	step("the host deposits: the payment line, the end of the guide")
	chute._server_interact(me)
	check(GameState.round_sales > 0, "deposited ($%d)" % GameState.round_sales)
	r = await _client_step(a, Guide.STEP_PAYMENT, "Alpha")
	var alpha_said: Array = r.get("said", [])
	var expect := [Guide.STEP_BUY, Guide.STEP_PLANT, Guide.STEP_WATER, Guide.STEP_WAIT, Guide.STEP_HARVEST, Guide.STEP_DEPOSIT, Guide.STEP_PAYMENT]
	var lines: Array = []
	for s: StringName in expect:
		lines.append(Guide.get_line(s))
	check(_dedupe(alpha_said) == lines and _at_most_twice(alpha_said), "Alpha heard every step in order, each at most twice %s" % [alpha_said])
	check(bool(r.get("finished", false)) and String(r.get("step", "x")) == "", "Alpha's guide is over")
	r = await _client_step(bb, Guide.STEP_PAYMENT, "Bravo")
	check(_dedupe(r.get("said", [])) == lines.slice(2), "Bravo heard water to the payment, in order %s" % [r.get("said", [])])

	step("the end of the shift")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.is_round_over(), 5.0, "the shift ends")
	for k in ["a", "b"]:
		r = await run_cmd(_ids[k], "after_shift", {}, 20.0)
		check(r.get("writes", []) == [["guidance", false]] and int(r.get("shifts", -1)) == 1 and not bool(r.get("wanted", true)),
				"%s: guidance switched off, one shift on file, not wanted (%s)" % [NAMES[k], r])
	await wait_frames(2)
	check(fake.writes.is_empty() and guide.said_log.is_empty() and not _guide_lines_in(Story.bark_log), "host: nothing written, nothing said the whole shift")
	check(Career.get_record("shifts") == 4, "host: the shift on file (4)")

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(a, "finish")
	cmd(bb, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bb), 20.0, "both left")
	_cleanup()
	finish()


## Waits until the client's guide is at `step` with its line said (for STEP_PAYMENT: the last line said and the guide
## over); records a check and returns the client's answer.
func _client_step(peer: int, step: StringName, who_name: String) -> Dictionary:
	var r := await run_cmd(peer, "wait_step", {"step": String(step)}, 30.0)
	check(bool(r.get("ok", false)), "%s: the %s line is said at her Boss ('%s')" % [who_name, step, Guide.get_line(step)])
	check(bool(r.get("at_boss", false)), "%s: in Story's log, the Boss's line" % who_name)
	return r


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


# =================================================================================================== CLIENT

func _client_main() -> void:
	Career.clear_record()
	fake.set_value(&"guidance", true)
	fake.writes.clear()
	check(Career.get_record("shifts") == 0 and guide.is_wanted(), "%s: no record: wanted" % NAMES.get(who, "?"))
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		_cleanup(); finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		_cleanup(); finish(); return
	await client_loop()
	_cleanup()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	match action:
		"alley":
			var board := Game.world.get_node_or_null(^"Lobby/ReportBoard") as AlleyBoard
			var next := board.get_next_lines() if board != null else PackedStringArray()
			ack(seq, {"line": guide.get_alley_line(), "board": not next.is_empty() and next[0] == Guide.ALLEY_LINE})
		"wait_step":
			var step := StringName(String(args.get("step", "")))
			var text := Guide.get_line(step)
			var t0 := Time.get_ticks_msec()
			var ok := false
			while Time.get_ticks_msec() - t0 < 20000:
				if step == Guide.STEP_PAYMENT:
					ok = guide.said_log.has(text) and guide.is_finished()
				else:
					ok = guide.get_step() == step and not guide.said_log.is_empty() and guide.said_log[-1] == text
				if ok:
					break
				Story.tick(0.25) # the Boss's quiet gap passes quicker; every line still waits for it
				await get_tree().process_frame
			if not ok:
				check(false, "%s: waited for the %s line; step '%s', said %s" % [who, step, guide.get_step(), guide.said_log])
			await wait_frames(2)
			var hud := Game.world.get_node_or_null(^"HUD") as HUD
			ack(seq, {
				"ok": ok, "step": String(guide.get_step()), "said": Array(guide.said_log), "finished": guide.is_finished(),
				"hint": hud.get_guide_hint_text() if hud != null else "", "at_boss": Story.bark_log.has(text),
				"heard_buy": guide.said_log.has(Guide.get_line(Guide.STEP_BUY)), "heard_plant": guide.said_log.has(Guide.get_line(Guide.STEP_PLANT)),
			})
		"after_shift":
			await wait_until_quiet(func() -> bool: return GameState.is_round_over(), 10.0)
			await wait_frames(3)
			var writes: Array = []
			for w: Array in fake.writes:
				writes.append([String(w[0]), w[1]])
			ack(seq, {"writes": writes, "shifts": Career.get_record("shifts"), "wanted": guide.is_wanted(), "finished": guide.is_finished()})
		_:
			await super(seq, action, args)


# =================================================================================================== helpers

static func _dedupe(said: Array) -> Array:
	var out: Array = []
	for s: Variant in said:
		if out.is_empty() or String(out[-1]) != String(s):
			out.append(String(s))
	return out


static func _at_most_twice(said: Array) -> bool:
	for s: Variant in said:
		if said.count(s) > 2:
			return false
	return true


func _guide_lines_in(log: PackedStringArray) -> bool:
	for s: StringName in Guide.LINES:
		if log.has(String(Guide.LINES[s])):
			return true
	return false


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	_remove(_path)
	_remove(_path + ".tmp")
