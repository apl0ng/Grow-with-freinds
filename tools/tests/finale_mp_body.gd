extends "res://tools/tests/qa_net_base.gd"
## M17 finale multi-process body (finale agent). Driven by tools/tests/finale_mp.sh; every process runs this script
## with --replay --run=B5VP and its OWN --career-file (a temp file under user://, removed at the end):
##   --role=host                 the director (real Game.start_host): pays the shifts, looks at half time, NEW RUN
##   --role=client --who=a       Alpha: joins at once (a team of two: the last shift is 5)
##   --role=client --who=b       Bravo: joins in the middle of shift 2 (the late joiner; three: the last shift moves to 6)
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: every peer agrees on the last shift (5 with two, 6 once the late joiner makes three, and the
## late joiner reads it from his first state); shift 5 is plain and shift 6 is the final notice on every peer (the
## title, the same two conditions); the half-time look reaches every peer (the raise, the toast, the Boss); paid: every
## peer sees PAID IN FULL, run_cleared once, the clients the waiting line and no button; each peer's own temp career
## file counts the clear and issues the eyeshade; NEW RUN puts every peer on shift 1 of a new run (still three: 6).

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const CAREER_SCRIPT := "res://scripts/core/career.gd"
const TEXT_SHORT := "Half the clock. Not half the money."

var role: String = "host"
var who: String = ""
var port: int = 7994
var _ids: Dictionary = {}
var _path: String = ""
var _looks: Array = []
var _cleared_signals: int = 0
var _issued: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7994))
	_label = "finale_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent and Config.replay_enabled,
			"own career file (%s), replay on" % _path):
		finish(); return
	_remove(_path)
	Career.clear_record()
	GameState.final_look.connect(func(short: bool, raised: int) -> void: _looks.append([short, raised]))
	GameState.run_cleared.connect(func() -> void: _cleared_signals += 1)
	Career.hat_issued.connect(func(id: StringName) -> void: _issued.append(id))
	if role == "host":
		await _host_main()
	else:
		await _client_main()
	_remove(_path)
	_remove(_path + ".tmp")
	finish()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = true
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null and Game.world != null, 10.0, "host world ready")
	print("FINALE_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var hud := Game.world.get_node_or_null(^"HUD") as HUD

	step("two workers: the last shift is 5 everywhere")
	check(GameState.get_final_shift() == 5 and GameState.get_largest_team() == 2, "host: 5 (%d)" % GameState.get_final_shift())
	var r := await run_cmd(a, "report", {"final": 5})
	check(bool(r.get("ok", false)) and not bool(r.get("is_final", true)) and String(r.get("title", "")) == "THIS SHIFT", "Alpha: 5, not final yet, THIS SHIFT")

	step("shift 1, then the late joiner in shift 2")
	GameState.request_start_round()
	await wait_frames(2)
	await _pay()
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	print("FINALE_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered (mid-shift)"):
		return
	_ids["b"] = _peer_named("b")
	var bp: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bp) != null, 10.0, "Bravo's Player node exists")
	check(await wait_until_quiet(func() -> bool: return GameState.get_final_shift() == 6, 5.0) and GameState.get_largest_team() == 3, "host: three workers, the last shift is 6")
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"final": 6, "round": 2})
		check(bool(r.get("ok", false)) and not bool(r.get("is_final", true)), "%s: 6, shift 2 is not final" % NAMES[key])

	step("shifts 2 to 5")
	for n in range(2, 6):
		await _pay()
		GameState.request_next_round()
		await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == n + 1, 3.0, "shift %d running" % (n + 1))
	check(GameState.round_number == 6 and GameState.is_final_shift() and hud.get_payment_title() == "FINAL NOTICE" and GameState.get_conditions().size() == 2,
			"host: shift 6 is the final notice, two conditions %s" % [GameState.get_conditions()])
	var conditions: Array = []
	for id in GameState.get_conditions():
		conditions.append(String(id))
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"round": 6, "final": 6})
		check(bool(r.get("ok", false)) and bool(r.get("is_final", false)) and String(r.get("title", "")) == "FINAL NOTICE" and r.get("conditions") == conditions,
				"%s: shift 6, FINAL NOTICE, the same two conditions %s" % [NAMES[key], r.get("conditions")])
		check(_has(r.get("toasts", []), "Final notice. Pay it and the debt is cleared."), "%s: the toast" % NAMES[key])

	step("half time, under the share: every peer hears it")
	var q0 := GameState.quota
	GameState.server_add_sale(int(q0 * 0.3), 1)
	var shift_len := float(GameState.get(&"_final_shift_len"))
	GameState.time_left = shift_len * 0.5 - 0.5
	await wait_until(func() -> bool: return _looks.size() == 1, 3.0, "host: the look")
	var raised := maxi(int(round(float(q0) * b.final_interim_raise)), 1)
	check(_looks == [[true, raised]] and GameState.quota == q0 + raised, "host: the payment due rose $%d" % raised)
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"looks": 1, "quota": GameState.quota})
		check(bool(r.get("ok", false)) and r.get("looks") == [[true, raised]], "%s: final_look(true, %d) once, the same payment due" % [NAMES[key], raised])
		check(_has(r.get("toasts", []), "Payment due up %s." % Story.format_money(raised)) and bool(r.get("short_line", false)), "%s: the toast and the Boss" % NAMES[key])

	step("paid in full, on every peer")
	await _pay()
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.is_run_cleared() and _cleared_signals == 1 and hud.round_end.is_showing_cleared()
			and hud.round_end.primary_button.visible and hud.round_end.primary_button.text == "NEW RUN", "host: PAID IN FULL, NEW RUN")
	await wait_frames(3)
	_check_own_record()
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"cleared": true, "record_cleared": 1})
		check(bool(r.get("ok", false)) and int(r.get("cleared_signals", 0)) == 1, "%s: the run is cleared, run_cleared once" % NAMES[key])
		check(String(r.get("overlay_title", "")) == "PAID IN FULL" and String(r.get("overlay_sub", "")) == "The debt is cleared. He will find another."
				and not bool(r.get("primary", true)) and bool(r.get("waiting", false)) and String(r.get("waiting_text", "")) == RoundEndOverlay.TEXT_WAITING
				and String(r.get("menu", "")) == "LEAVE", "%s: PAID IN FULL, the waiting line, LEAVE, no button" % NAMES[key])
		check(int(r.get("record", -1)) == 1 and int(r.get("file", -1)) == 1 and String(r.get("last_line", "")) == "Debts cleared: 1",
				"%s: its own file counts the clear (memory %s, file %s, '%s')" % [NAMES[key], r.get("record"), r.get("file"), r.get("last_line")])
		var issued: Variant = r.get("issued", [])
		check(issued is Array and (issued as Array).count("eyeshade") == 1, "%s: the eyeshade is issued once (%s)" % [NAMES[key], issued])

	step("NEW RUN, on every peer")
	var code := GameState.get_run_code()
	hud.round_end.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and not GameState.is_run_cleared() and GameState.get_final_shift() == 6,
			"host: shift 1 of a new run, three workers: 6 (code %s, typed: %s)" % [GameState.get_run_code(), code])
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"round": 1, "cleared": false, "final": 6, "phase": GameState.Phase.WAITING})
		check(bool(r.get("ok", false)) and not bool(r.get("overlay", true)) and String(r.get("title", "")) == "THIS SHIFT", "%s: WAITING, shift 1, nothing cleared, the overlay gone" % NAMES[key])

	step("finish")
	allow_error("Unable to send packet on channel 0", 6, true)
	cmd(a, "finish")
	cmd(bp, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bp), 20.0, "both clients left")


func _pay() -> void:
	GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
	await wait_frames(2)


func _check_own_record() -> void:
	var reader: Node = (load(CAREER_SCRIPT) as GDScript).new()
	var file_ok: bool = reader.load_file(_path)
	check(Career.get_record("cleared") == 1 and file_ok and reader.get_record("cleared") == 1 and _issued.count(&"eyeshade") == 1,
			"host: its own file counts the clear, the eyeshade issued (%s)" % [_issued])
	reader.free()


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


static func _has(list: Variant, substring: String) -> bool:
	if not (list is Array):
		return false
	for t in list:
		if String(t).contains(substring):
			return true
	return false


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		return
	await client_loop()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	match action:
		"report":
			var ok := await wait_until_quiet(func() -> bool: return _report_ready(args), float(args.get("timeout", 8.0)))
			ack(seq, _report(ok))
		"finish":
			_remove(_path)
			_remove(_path + ".tmp")
			await super(seq, action, args)
		_:
			await super(seq, action, args)


## The conditions a "report" waits for (all optional): final, round, phase, cleared, looks, quota, record_cleared.
func _report_ready(args: Dictionary) -> bool:
	if args.has("final") and GameState.get_final_shift() != int(args["final"]):
		return false
	if args.has("round") and GameState.round_number != int(args["round"]):
		return false
	if args.has("phase") and GameState.phase != int(args["phase"]):
		return false
	if args.has("cleared") and GameState.is_run_cleared() != bool(args["cleared"]):
		return false
	if args.has("looks") and _looks.size() != int(args["looks"]):
		return false
	if args.has("quota") and GameState.quota != int(args["quota"]):
		return false
	if args.has("record_cleared") and Career.get_record("cleared") != int(args["record_cleared"]):
		return false
	return true


func _report(ok: bool) -> Dictionary:
	var hud: HUD = Game.world.get_node_or_null(^"HUD") as HUD if Game.world != null else null
	var re: RoundEndOverlay = hud.round_end if hud != null else null
	var reader: Node = (load(CAREER_SCRIPT) as GDScript).new()
	reader.load_file(_path)
	var file_cleared: int = reader.get_record("cleared")
	reader.free()
	var conditions: Array = []
	for id in GameState.get_conditions():
		conditions.append(String(id))
	var issued: Array = []
	for id in _issued:
		issued.append(String(id))
	var shown: Array = []
	for t in toasts:
		shown.append(String(t[0]))
	var lines := Career.get_summary_lines()
	return {
		"ok": ok, "final": GameState.get_final_shift(), "is_final": GameState.is_final_shift(), "cleared": GameState.is_run_cleared(),
		"title": hud.get_payment_title() if hud != null else "", "conditions": conditions, "looks": _looks.duplicate(true),
		"cleared_signals": _cleared_signals, "toasts": shown, "short_line": Story.bark_log.has(TEXT_SHORT),
		"overlay": re != null and re.visible, "overlay_title": re.title_label.text if re != null else "", "overlay_sub": re.subtitle_label.text if re != null else "",
		"primary": re != null and re.primary_button.visible, "waiting": re != null and re.waiting_label.visible,
		"waiting_text": re.waiting_label.text if re != null else "", "menu": re.menu_button.text if re != null else "",
		"record": Career.get_record("cleared"), "file": file_cleared, "last_line": lines[lines.size() - 1] if not lines.is_empty() else "",
		"issued": issued,
	}


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
