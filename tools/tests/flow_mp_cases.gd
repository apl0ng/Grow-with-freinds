extends Node
## Step driver for tools/tests/flow_mp_test.gd (see there). Added as /root/GameState/FlowMpCases on
## both processes so its RPCs travel on GameState's multiplayer branch, ordered with GameState's own
## reliable RPCs: when the client receives step N, every GameState broadcast made before it has been
## applied. The host mutates GameState, then sends _rpc_step(N, host_snapshot); the client checks its
## replicated GameState + its HUD, then acks. Owned by the game-flow/UI agent.

const STEP_TIMEOUT_MSEC: int = 15000
const CONNECT_TIMEOUT_MSEC: int = 20000
## Max allowed |client time_left - host time_left| (sync interval 0.5 s + latency + frames).
const TIME_TOLERANCE_SEC: float = 0.75

var role: String = "host"
## ErrorCounter (Logger) from the runner; its `errors` go into the client report.
var error_logger: Object = null

var passed: int = 0
var failed: int = 0
var failures: PackedStringArray = []

var _balance: BalanceConfig
var _events: Array = []
var _client_id: int = 0
var _acked: Dictionary = {}
var _report: Dictionary = {}
var _client_done: bool = false
var _hud: HUD


## Coroutine: runs this side of the test and returns the number of failures (host: both sides).
func run() -> int:
	_balance = Config.balance
	_balance.end_round_on_quota_met = true
	_balance.carry_over_money = true
	_hook_signals()
	if role == "host":
		return await _run_host()
	return await _run_client()


# ---------------------------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------------------------

func _run_host() -> int:
	Net.set(&"is_host", true)
	GameState.reset_local()
	GameState.server_reset_game()
	multiplayer.peer_connected.connect(_on_peer_connected)
	var connected := await _wait(func() -> bool: return _client_id != 0, CONNECT_TIMEOUT_MSEC)
	_check(connected, "client connected (peer %d)" % _client_id)
	if not connected:
		return failed

	# Late join: what Net does when a peer registers.
	GameState.server_send_full_state(_client_id)
	await _step(1)

	GameState.request_start_round()
	await _step(2)

	_check(GameState.server_try_spend(10, _client_id, "Budget Bud seeds"), "spend 10 for the client")
	await _step(3)

	GameState.server_add_sale(5, _client_id)
	await _step(4)

	await get_tree().create_timer(1.6).timeout # let a few unreliable timer syncs go out
	await _step(5)

	GameState.server_add_sale(GameState.quota - GameState.round_sales, _client_id)
	_check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "host: quota met -> ROUND_SUCCESS")
	await _step(6)

	GameState.request_next_round()
	await _step(7)

	GameState.server_add_money(_balance.starting_money * 10)
	var fert: UpgradeDef = _balance.get_upgrade(&"fertilizer")
	if fert != null:
		_check(GameState.server_buy_upgrade(&"fertilizer", _client_id), "host: buy fertilizer for the team")
	await _step(8)

	GameState.time_left = 0.05
	await _wait(func() -> bool: return GameState.phase != GameState.Phase.PLAYING, 5000)
	_check(GameState.phase == GameState.Phase.ROUND_FAILED, "host: timer out below quota -> ROUND_FAILED")
	await _step(9)

	GameState.request_retry()
	await _step(10)

	await _step(11) # the client tries request_start_round()
	await get_tree().create_timer(0.3).timeout
	_check(GameState.phase == GameState.Phase.WAITING, "host: a client's request_start_round() is ignored")

	_rpc_done.rpc_id(_client_id)
	var got_report := await _wait(func() -> bool: return not _report.is_empty(), STEP_TIMEOUT_MSEC)
	_check(got_report, "client report received")
	var total := failed
	if got_report:
		var c_passed: int = _report["passed"]
		var c_failed: int = _report["failed"]
		var c_failures: PackedStringArray = _report["failures"]
		var c_errors: PackedStringArray = _report["errors"]
		print("flow_mp_test: client %d passed, %d failed, %d engine errors" % [c_passed, c_failed, c_errors.size()])
		for f in c_failures:
			print("   client FAIL: " + f)
		for e in c_errors:
			print("   client error: " + e)
		total += c_failed + (1 if not c_errors.is_empty() else 0)
	print("flow_mp_test: host %d passed, %d failed" % [passed, failed])
	return total


func _on_peer_connected(id: int) -> void:
	if _client_id == 0:
		_client_id = id


## Sends step `n` with the host's view of the state and waits for the client's ack.
func _step(n: int) -> void:
	var info := {
		"phase": GameState.phase,
		"money": GameState.money,
		"round": GameState.round_number,
		"quota": GameState.quota,
		"sales": GameState.round_sales,
		"time": GameState.time_left,
		"serial": int(GameState.get(&"_serial")),
		"growth": GameState.get_growth_speed_multiplier(),
		"fert": GameState.get_upgrade_level(&"fertilizer"),
	}
	_rpc_step.rpc_id(_client_id, n, info)
	var ok := await _wait(func() -> bool: return _acked.has(n), STEP_TIMEOUT_MSEC)
	_check(ok, "client acknowledged step %d" % n)


# ---------------------------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------------------------

func _run_client() -> int:
	Net.set(&"is_host", false)
	var hud_scene: PackedScene = load("res://scenes/ui/hud.tscn")
	_hud = hud_scene.instantiate() as HUD
	get_tree().root.add_child(_hud)
	await _wait(func() -> bool: return _client_done, 80000)
	var errors: PackedStringArray = []
	if error_logger != null:
		errors = error_logger.get(&"errors")
	_rpc_report.rpc_id(1, passed, failed, failures, errors)
	_hud.queue_free()
	return failed + errors.size()


func _client_step(n: int, host: Dictionary) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var P := GameState.Phase
	match n:
		1:
			_check(GameState.phase == P.WAITING, "full state on join: WAITING")
			_check(GameState.money == int(host["money"]) and GameState.money == _balance.starting_money, "money = starting_money (%d)" % GameState.money)
			_check(GameState.quota == _balance.quota_for_round(1) and GameState.round_number == 1, "round 1, quota %d" % GameState.quota)
			_check(GameState.round_sales == 0 and GameState.upgrades.is_empty(), "no sales, no upgrades")
			_check(is_equal_approx(GameState.time_left, _balance.round_length_sec), "timer at round length")
			_check(not GameState.is_local_host() and not bool(GameState.get(&"_authoritative")), "client is not the authority")
			_check(_has_event(["phase", P.WAITING]), "phase_changed(WAITING) emitted on the client")
			_check(_hud.banner.visible and _hud.banner_title.text == "HANG TIGHT!" and not _hud.start_button.visible, "client HUD: waiting banner, no START button")
			_check(_hud.money_label.text == HUD.format_money(GameState.money), "client HUD wallet %s" % _hud.money_label.text)
		2:
			_check(GameState.phase == P.PLAYING and GameState.is_playing(), "round started on the client")
			_check(_has_event(["round_started", 1]), "round_started(1) emitted on the client")
			_check(int(GameState.get(&"_serial")) == int(host["serial"]), "round serial in sync")
			_check(not _hud.banner.visible and _hud.go_banner.visible, "client HUD: banner hidden, GO banner shown")
		3:
			_check(GameState.money == int(host["money"]), "purchase: money in sync (%d)" % GameState.money)
			_check(_has_event(["purchase", 10, multiplayer.get_unique_id(), "Budget Bud seeds"]), "purchase_made(10, me, what) on the client")
			_check(_hud.money_label.text == HUD.format_money(GameState.money), "client HUD wallet after purchase")
		4:
			_check(GameState.round_sales == 5 and GameState.money == int(host["money"]), "sale: sales + money in sync")
			_check(_has_event(["sale", 5, multiplayer.get_unique_id()]), "sale_made(5, me) on the client")
			_check(_has_event(["sales", 5, GameState.quota]), "sales_changed on the client")
			_check(_hud.quota_label.text == "SOLD $5 / %s" % HUD.format_money(GameState.quota), "client HUD quota: %s" % _hud.quota_label.text)
		5:
			var diff := absf(GameState.time_left - float(host["time"]))
			_check(diff < TIME_TOLERANCE_SEC, "timer in sync: client %.2f vs host %.2f" % [GameState.time_left, float(host["time"])])
			_check(GameState.time_left < _balance.round_length_sec - 1.0, "client timer is counting down")
			_check(_hud.timer_label.text == GameState.get_time_string(), "client HUD timer %s" % _hud.timer_label.text)
		6:
			_check(GameState.phase == P.ROUND_SUCCESS, "quota met: ROUND_SUCCESS on the client")
			_check(_has_event(["round_ended", true, 1]), "round_ended(true, 1) on the client")
			_check(_event_index(["sale"]) >= 0 and _event_index(["sale"]) < _event_index(["round_ended"]), "sale_made before round_ended")
			var re := _hud.round_end
			_check(re.visible and re.title_label.text == "QUOTA MET!", "client overlay: QUOTA MET!")
			_check(not re.primary_button.visible and re.waiting_label.visible and re.menu_button.text == "LEAVE", "client overlay: waiting + LEAVE")
		7:
			_check(GameState.phase == P.PLAYING and GameState.round_number == 2, "next round: round 2 PLAYING")
			_check(GameState.quota == _balance.quota_for_round(2) and GameState.round_sales == 0, "round 2 quota %d, sales 0" % GameState.quota)
			_check(GameState.money == int(host["money"]), "money carried over (%d)" % GameState.money)
			_check(int(GameState.get(&"_serial")) == int(host["serial"]), "round serial in sync after next round")
			_check(not _hud.round_end.visible and _hud.round_label.text == "ROUND 2", "client HUD: overlay gone, ROUND 2")
		8:
			_check(GameState.get_upgrade_level(&"fertilizer") == int(host["fert"]), "upgrade level in sync (%d)" % GameState.get_upgrade_level(&"fertilizer"))
			_check(is_equal_approx(GameState.get_growth_speed_multiplier(), float(host["growth"])), "growth multiplier in sync")
			_check(GameState.money == int(host["money"]), "money after upgrade in sync")
			if int(host["fert"]) > 0:
				_check(_has_event(["upgrade", &"fertilizer", int(host["fert"])]), "upgrade_level_changed on the client")
		9:
			_check(GameState.phase == P.ROUND_FAILED, "timer out: ROUND_FAILED on the client")
			_check(_has_event(["round_ended", false, 2]), "round_ended(false, 2) on the client")
			_check(GameState.time_left == 0.0, "client time_left is 0")
			var re := _hud.round_end
			_check(re.visible and re.title_label.text == "GAME OVER" and re.waiting_label.visible, "client overlay: GAME OVER + waiting")
		10:
			_check(GameState.phase == P.WAITING and GameState.round_number == 1, "retry: WAITING round 1")
			_check(GameState.money == _balance.starting_money and GameState.upgrades.is_empty(), "retry: starting money, upgrades cleared")
			_check(GameState.get_upgrade_level(&"fertilizer") == 0 and is_equal_approx(GameState.get_growth_speed_multiplier(), Config.growth_speed_override), "retry: effects back to base")
			_check(_has_event(["game_reset"]), "game_reset emitted on the client")
			_check(not _hud.round_end.visible and _hud.banner.visible, "client HUD: overlay gone, waiting banner back")
		11:
			GameState.request_start_round()
			_check(GameState.phase == P.WAITING, "client request_start_round() does nothing locally")
	_events.clear()
	_rpc_ack.rpc_id(1, n)


# ---------------------------------------------------------------------------------------------
# RPCs (same node path on both processes)
# ---------------------------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_step(n: int, host_info: Dictionary) -> void:
	_client_step(n, host_info)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_ack(n: int) -> void:
	_acked[n] = true


@rpc("authority", "call_remote", "reliable")
func _rpc_done() -> void:
	_client_done = true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report(p: int, f: int, fails: PackedStringArray, errors: PackedStringArray) -> void:
	_report = {"passed": p, "failed": f, "failures": fails, "errors": errors}


# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

func _hook_signals() -> void:
	GameState.phase_changed.connect(func(p: int) -> void: _events.append(["phase", p]))
	GameState.money_changed.connect(func(m: int) -> void: _events.append(["money", m]))
	GameState.sales_changed.connect(func(s: int, q: int) -> void: _events.append(["sales", s, q]))
	GameState.round_started.connect(func(n: int) -> void: _events.append(["round_started", n]))
	GameState.round_ended.connect(func(ok: bool, n: int) -> void: _events.append(["round_ended", ok, n]))
	GameState.sale_made.connect(func(a: int, p: int) -> void: _events.append(["sale", a, p]))
	GameState.purchase_made.connect(func(c: int, p: int, w: String) -> void: _events.append(["purchase", c, p, w]))
	GameState.upgrade_level_changed.connect(func(id: StringName, l: int) -> void: _events.append(["upgrade", id, l]))
	GameState.game_reset.connect(func() -> void: _events.append(["game_reset"]))


func _event_index(prefix: Array) -> int:
	for i in _events.size():
		var ev: Array = _events[i]
		if ev.size() < prefix.size():
			continue
		var ok := true
		for j in prefix.size():
			if ev[j] != prefix[j]:
				ok = false
				break
		if ok:
			return i
	return -1


func _has_event(prefix: Array) -> bool:
	return _event_index(prefix) >= 0


func _check(cond: bool, what: String) -> void:
	var line := "[%s] %s" % [role, what]
	if cond:
		passed += 1
		print("PASS: " + line)
	else:
		failed += 1
		failures.append(what)
		print("FAIL: " + line)


func _wait(cond: Callable, timeout_msec: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > timeout_msec:
			return false
		await get_tree().process_frame
	return true
