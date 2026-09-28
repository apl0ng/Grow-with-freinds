extends "res://tools/tests/smoke_base.gd"
## M10 lead suite: GameState stats / write-ups / fines / back room / audits on a single headless host.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/discipline_body.gd --port=7841

var _written: Array = []      # [peer, reason, count] per worker_written_up
var _backroom_events: Array = []  # [peer, active]
var _stats_signals: int = 0


func _run() -> void:
	_label = "discipline"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	GameState.worker_written_up.connect(func(p: int, r: String, c: int) -> void: _written.append([p, r, c]))
	GameState.backroom_changed.connect(func(p: int, a: bool) -> void: _backroom_events.append([p, a]))
	GameState.stats_changed.connect(func() -> void: _stats_signals += 1)

	step("hosting")
	Game.start_host("Tester", port_arg(7841))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	check(GameState.stats.is_empty() and GameState.write_ups.is_empty() and GameState.backroom.is_empty(), "fresh session: no stats, strikes or back room")
	check(GameState.get_stat(1, Const.STAT_PLANTED) == 0, "get_stat of an unknown worker is 0")
	check(not GameState.server_send_to_backroom(1), "back room refused while WAITING")
	check(GameState.server_write_up(1, Const.WRITE_UP_OTHER) == 1, "a write-up while WAITING counts a strike")
	check(GameState.get_write_ups(1) == 1 and not GameState.is_in_backroom(1), "strike stored, nobody in the back room while WAITING")

	step("start shift")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "phase PLAYING")
	check(GameState.write_ups.is_empty() and GameState.stats.is_empty(), "shift start clears strikes and the ledger")
	var money0 := GameState.money
	var signals0 := _stats_signals

	step("stats")
	GameState.server_add_stat(1, Const.STAT_PLANTED)
	GameState.server_add_stat(1, Const.STAT_WATERED, 3)
	await wait_frames(1)
	check(GameState.get_stat(1, Const.STAT_PLANTED) == 1 and GameState.get_stat(1, Const.STAT_WATERED) == 3, "stats add up")
	check(_stats_signals > signals0, "stats_changed emitted")
	GameState.server_add_sale(50, 1)
	await wait_frames(1)
	check(GameState.get_stat(1, Const.STAT_DEPOSITED) == 50, "deposits are counted by server_add_sale")
	check(GameState.get_worker_stats(1).get(Const.STAT_DEPOSITED, 0) == 50, "get_worker_stats returns the row")
	var row := GameState.get_worker_stats(1)
	row[Const.STAT_DEPOSITED] = 999
	check(GameState.get_stat(1, Const.STAT_DEPOSITED) == 50, "get_worker_stats returns a copy")
	money0 = GameState.money

	step("write-ups")
	_written.clear()
	var c1 := GameState.server_write_up(1, Const.WRITE_UP_SKIMMING)
	await wait_frames(1)
	check(c1 == 1 and GameState.get_write_ups(1) == 1, "first write-up: one strike")
	check(GameState.money == money0 - b.write_up_fine, "write-up docks the fine ($%d)" % b.write_up_fine)
	check(GameState.get_stat(1, Const.STAT_WRITE_UPS) == 1, "STAT_WRITE_UPS counts it")
	check(_written.size() == 1 and _written[0][0] == 1 and _written[0][1] == Const.WRITE_UP_SKIMMING and _written[0][2] == 1, "worker_written_up(1, skimming, 1)")
	var c2 := GameState.server_write_up(1, Const.WRITE_UP_LOITERING)
	check(c2 == 2, "second write-up: two strikes")
	_backroom_events.clear()
	var c3 := GameState.server_write_up(1, Const.WRITE_UP_SKIMMING)
	await wait_frames(1)
	check(c3 == 0, "third write-up returns 0 (sent to the back room)")
	check(GameState.is_in_backroom(1), "worker is in the back room")
	check(GameState.get_write_ups(1) == 0, "strikes cleared by the back room")
	check(GameState.get_stat(1, Const.STAT_WRITE_UPS) == 3, "STAT_WRITE_UPS keeps counting (3)")
	check(_backroom_events.size() == 1 and _backroom_events[0][0] == 1 and _backroom_events[0][1] == true, "backroom_changed(1, true)")
	var left := GameState.get_backroom_time_left(1)
	check(absf(left - b.backroom_sec) < 1.0, "back room time left ~ backroom_sec (%.1f)" % left)
	check(GameState.get_backroom_peers() == [1], "get_backroom_peers lists the worker")
	check(_written.size() == 3 and _written[2][2] == 0, "third worker_written_up carries count 0")

	step("release by the shift timer")
	_backroom_events.clear()
	GameState.time_left = float(GameState.backroom[1]) + 0.01
	await wait_until(func() -> bool: return not GameState.is_in_backroom(1), 3.0, "released once the timer passes the release time")
	check(_backroom_events.size() >= 1 and _backroom_events.back()[1] == false, "backroom_changed(1, false)")
	check(GameState.get_backroom_time_left(1) == 0.0, "time left is 0 after release")

	step("explicit back room + release")
	check(GameState.server_send_to_backroom(1, 5.0), "server_send_to_backroom while PLAYING")
	await wait_frames(1)
	check(GameState.is_in_backroom(1), "in the back room again")
	GameState.server_release_from_backroom(1)
	await wait_frames(1)
	check(not GameState.is_in_backroom(1), "server_release_from_backroom lets them out")

	step("audit")
	var q0 := GameState.quota
	var q1 := GameState.server_raise_quota(b.audit_raise_fraction)
	await wait_frames(1)
	check(q1 == q0 + maxi(int(round(float(q0) * b.audit_raise_fraction)), 1) and GameState.quota == q1, "audit raises the quota by %.0f%%" % (b.audit_raise_fraction * 100.0))

	step("shift end clears the back room but keeps the ledger")
	check(GameState.server_send_to_backroom(1, 60.0), "back in the back room before the shift ends")
	await wait_frames(1)
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift ended (timer)")
	check(not GameState.is_in_backroom(1) and GameState.backroom.is_empty(), "shift end releases everyone")
	check(GameState.get_stat(1, Const.STAT_PLANTED) == 1 and GameState.get_stat(1, Const.STAT_WRITE_UPS) == 3, "ledger survives the end screen")
	check(GameState.server_write_up(1, Const.WRITE_UP_OTHER) == 1 and not GameState.is_in_backroom(1), "a write-up on the end screen is a strike, never the back room")

	step("reset clears everything")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	check(GameState.stats.is_empty() and GameState.write_ups.is_empty() and GameState.backroom.is_empty(), "reset clears the ledger, strikes and back room")

	step("back to menu")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	check(GameState.stats.is_empty(), "menu: no stats")
	finish()
