extends Node
## Test cases for tools/tests/flow_test.gd (loaded at runtime so autoload names resolve).
## Owned by the game-flow/UI agent. See flow_test.gd for how to run.

class FakeInteractor extends Node:
	signal prompt_changed(text: String, enabled: bool)


## Stands in for the ShopkeeperNPC: records every bark(text).
class FakeBoss extends Node:
	var said: PackedStringArray = []

	func bark(text: String, _duration: float = -1.0) -> void:
		said.append(text)

	func last() -> String:
		return said[said.size() - 1] if not said.is_empty() else ""


## Stands in for the Room's DEBT BOARD.
class FakeBoard extends RefCounted:
	var text: String = ""

	func set_debt_board_text(value: String) -> void:
		text = value


var passed: int = 0
var failed: int = 0
var _events: Array = []
var _balance: BalanceConfig


## Runs every case (coroutine). Results in `passed` / `failed`.
func run() -> void:
	_balance = Config.balance
	_test_balance_numbers()
	await _test_game_state()
	await _test_ui()
	_test_team_payment()
	await _test_story()


# ---------------------------------------------------------------------------------------------
# GameState
# ---------------------------------------------------------------------------------------------

func _test_game_state() -> void:
	print("== GameState")
	_hook_signals()
	_balance.end_round_on_quota_met = true
	_balance.carry_over_money = true
	Net.set(&"is_host", true)
	var start_money: int = _balance.starting_money
	var round_len: float = _balance.round_length_sec

	GameState.reset_local()
	_check(GameState.phase == GameState.Phase.MENU, "reset_local -> MENU")
	_check(multiplayer.is_server(), "test process is the server (offline peer)")

	# --- reset -> WAITING
	_events.clear()
	GameState.server_reset_game()
	_check(GameState.phase == GameState.Phase.WAITING, "server_reset_game -> WAITING")
	_check(GameState.round_number == 1, "reset: round 1")
	_check(GameState.money == start_money, "reset: money = starting_money (%d)" % start_money)
	_check(GameState.quota == _balance.quota_for_round(1), "reset: quota = quota_for_round(1) (%d)" % GameState.quota)
	_check(GameState.round_sales == 0, "reset: round_sales 0")
	_check(is_equal_approx(GameState.time_left, round_len), "reset: time_left = round_length_sec")
	_check(GameState.upgrades.is_empty(), "reset: upgrades cleared")
	_check(not GameState.is_playing(), "WAITING: is_playing() false (growth paused)")
	_check(_has_event(["phase", GameState.Phase.WAITING]), "reset emits phase_changed(WAITING)")
	_check(not _has_event(["game_reset"]), "first reset (from MENU) does not emit game_reset")
	_check(GameState.is_local_host(), "is_local_host() on the host")
	_check(GameState.get_time_string() == _mmss(round_len), "get_time_string() = %s" % _mmss(round_len))

	# --- start round 1
	_events.clear()
	GameState.request_start_round()
	_check(GameState.phase == GameState.Phase.PLAYING, "request_start_round -> PLAYING")
	_check(GameState.is_playing(), "PLAYING: is_playing() true")
	_check(GameState.round_number == 1, "start from WAITING keeps round 1")
	_check(_has_event(["round_started", 1]), "round_started(1) emitted")
	_check(GameState.get_phase_name() == "PLAYING", "get_phase_name() = PLAYING")
	GameState.request_start_round()
	_check(GameState.phase == GameState.Phase.PLAYING and GameState.round_number == 1, "start while PLAYING is ignored")

	# --- spending
	var money_before := GameState.money
	_check(not GameState.server_try_spend(money_before + 1, 1, "too much"), "try_spend more than money -> false")
	_check(GameState.money == money_before, "failed spend leaves money unchanged")
	_check(not GameState.server_try_spend(-5, 1, "negative"), "try_spend negative -> false")
	var spend: int = maxi(1, money_before / 4)
	_events.clear()
	_check(GameState.server_try_spend(spend, 1, "Budget Bud seeds"), "try_spend %d -> true" % spend)
	_check(GameState.money == money_before - spend, "spend decreases money by %d" % spend)
	_check(_has_event(["purchase", spend, 1, "Budget Bud seeds"]), "purchase_made emitted")
	_check(_has_event(["money", money_before - spend]), "money_changed emitted")
	_check(GameState.round_sales == 0, "spending does not touch round_sales")

	# --- sales below quota
	var quota1 := GameState.quota
	money_before = GameState.money
	_events.clear()
	GameState.server_add_sale(1, 1)
	_check(GameState.round_sales == 1, "add_sale(1): round_sales 1")
	_check(GameState.money == money_before + 1, "add_sale adds to money")
	_check(GameState.phase == GameState.Phase.PLAYING, "below quota: still PLAYING")
	_check(_has_event(["sale", 1, 1]), "sale_made emitted")
	_check(_has_event(["sales", 1, quota1]), "sales_changed(1, quota) emitted")

	# --- reaching the quota ends the round immediately
	_events.clear()
	GameState.server_add_sale(quota1 - GameState.round_sales, 1)
	_check(GameState.round_sales == quota1, "sales reached quota")
	_check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "quota met -> ROUND_SUCCESS immediately")
	_check(_has_event(["round_ended", true, 1]), "round_ended(true, 1) emitted")
	_check(_event_index(["sale"]) < _event_index(["round_ended"]), "sale_made emitted before round_ended")
	_check(GameState.time_left > 0.0, "time left is kept on early success")
	_check(not GameState.is_playing(), "ROUND_SUCCESS: is_playing() false")

	# --- next round: round 2, new quota, sales reset, money carried over
	money_before = GameState.money
	_events.clear()
	GameState.request_next_round()
	_check(GameState.phase == GameState.Phase.PLAYING, "request_next_round -> PLAYING")
	_check(GameState.round_number == 2, "next round: round 2")
	_check(GameState.quota == _balance.quota_for_round(2), "round 2 quota = quota_for_round(2) (%d)" % GameState.quota)
	_check(GameState.round_sales == 0, "next round: round_sales reset to 0")
	_check(GameState.money == money_before, "money carried over (%d)" % money_before)
	_check(is_equal_approx(GameState.time_left, round_len), "next round: timer reset")
	_check(_has_event(["round_started", 2]), "round_started(2) emitted")

	# --- the timer runs out below quota -> ROUND_FAILED
	GameState.server_add_sale(1, 1)
	var t_before := GameState.time_left
	await _frames_wait(3)
	_check(GameState.time_left < t_before, "timer counts down while PLAYING")
	_events.clear()
	GameState.time_left = 0.01
	await _wait_until(func() -> bool: return GameState.phase != GameState.Phase.PLAYING, 120)
	_check(GameState.phase == GameState.Phase.ROUND_FAILED, "timer hit 0 below quota -> ROUND_FAILED")
	_check(_has_event(["round_ended", false, 2]), "round_ended(false, 2) emitted")
	_check(GameState.time_left == 0.0, "time_left clamped to 0")
	_check(GameState.get_time_string() == "00:00", "get_time_string() = 00:00")
	GameState.request_next_round()
	_check(GameState.phase == GameState.Phase.ROUND_FAILED, "next_round ignored after a failure")

	# --- retry = full reset + game_reset
	_events.clear()
	GameState.request_retry()
	_check(GameState.phase == GameState.Phase.WAITING, "request_retry -> WAITING")
	_check(GameState.round_number == 1 and GameState.money == start_money and GameState.round_sales == 0, "retry: round 1, starting money, no sales")
	_check(_has_event(["game_reset"]), "retry emits game_reset")
	_check(_event_index(["phase", GameState.Phase.WAITING]) < _event_index(["game_reset"]), "game_reset after the fresh state is applied")

	# --- upgrades
	var fert: UpgradeDef = _balance.get_upgrade(&"fertilizer")
	_check(fert != null, "balance has the fertilizer upgrade")
	if fert != null:
		GameState.server_add_money(_total_upgrade_cost())
		money_before = GameState.money
		_events.clear()
		_check(GameState.server_buy_upgrade(&"fertilizer", 1), "buy fertilizer level 1 -> true")
		_check(GameState.money == money_before - fert.cost_for_level(1), "fertilizer costs cost_for_level(1) = %d" % fert.cost_for_level(1))
		_check(GameState.get_upgrade_level(&"fertilizer") == 1, "fertilizer level 1")
		var expected_growth := (1.0 + fert.effect_per_level) * Config.growth_speed_override
		_check(is_equal_approx(GameState.get_growth_speed_multiplier(), expected_growth),
			"growth multiplier = %.3f (1 + %.2f) * growth_speed_override" % [GameState.get_growth_speed_multiplier(), fert.effect_per_level])
		_check(_has_event(["upgrade", &"fertilizer", 1]), "upgrade_level_changed(fertilizer, 1) emitted")
		_check(_has_event(["purchase", fert.cost_for_level(1), 1, "%s Lv 1" % fert.display_name]), "upgrade emits purchase_made")
		for lvl in range(2, fert.max_level + 1):
			_check(GameState.server_buy_upgrade(&"fertilizer", 1), "buy fertilizer level %d" % lvl)
		_check(GameState.get_upgrade_level(&"fertilizer") == fert.max_level, "fertilizer at max level %d" % fert.max_level)
		money_before = GameState.money
		_check(not GameState.server_buy_upgrade(&"fertilizer", 1), "buying beyond max_level -> false")
		_check(GameState.money == money_before and GameState.get_upgrade_level(&"fertilizer") == fert.max_level, "failed upgrade changes nothing")
		_check(GameState.get_upgrade_next_cost(&"fertilizer") == -1, "get_upgrade_next_cost() = -1 when maxed")
	_check(not GameState.server_buy_upgrade(&"no_such_upgrade", 1), "unknown upgrade -> false")

	var can_def := _upgrade_with_effect(Const.EFFECT_CAN_CAPACITY)
	_check(can_def != null, "balance has a can_capacity upgrade")
	if can_def != null:
		_check(GameState.get_can_capacity() == _balance.can_capacity, "base can capacity = %d" % _balance.can_capacity)
		_check(GameState.server_buy_upgrade(can_def.id, 1), "buy %s level 1" % can_def.id)
		_check(GameState.get_can_capacity() == _balance.can_capacity + int(can_def.effect_per_level),
			"can capacity = %d after %s" % [GameState.get_can_capacity(), can_def.id])
	var sale_def := _upgrade_with_effect(Const.EFFECT_SALE_BONUS)
	if sale_def != null:
		_check(GameState.server_buy_upgrade(sale_def.id, 1), "buy %s level 1" % sale_def.id)
		_check(is_equal_approx(GameState.get_sale_multiplier(), 1.0 + sale_def.effect_per_level), "sale multiplier = %.2f" % GameState.get_sale_multiplier())
	if _upgrade_with_effect(Const.EFFECT_WATER_RETENTION) == null:
		_check(is_equal_approx(GameState.get_water_drain_multiplier(), 1.0), "water drain multiplier 1.0 without a retention upgrade")
	# not enough money
	GameState.server_try_spend(GameState.money, 1, "drain")
	var cheap := _cheapest_available_upgrade()
	if cheap != null:
		_check(not GameState.server_buy_upgrade(cheap.id, 1), "upgrade with $0 -> false")
	# a retry clears upgrades
	GameState.request_retry()
	_check(GameState.upgrades.is_empty() and GameState.get_can_capacity() == _balance.can_capacity, "retry clears upgrades")

	# --- end_round_on_quota_met = false: the round runs to the timer, then succeeds
	_balance.end_round_on_quota_met = false
	GameState.request_start_round()
	GameState.server_add_sale(GameState.quota, 2)
	_check(GameState.phase == GameState.Phase.PLAYING, "end_round_on_quota_met=false: keeps PLAYING after quota")
	GameState.time_left = 0.01
	await _wait_until(func() -> bool: return GameState.phase != GameState.Phase.PLAYING, 120)
	_check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "timer end with sales >= quota -> ROUND_SUCCESS")
	_balance.end_round_on_quota_met = true

	# --- carry_over_money = false: next round starts from starting_money
	_balance.carry_over_money = false
	GameState.server_add_money(123)
	GameState.request_next_round()
	_check(GameState.money == start_money, "carry_over_money=false: money reset to starting_money")
	_balance.carry_over_money = true

	# --- misc: timer sync, full state, time strings
	var serial: int = GameState.get(&"_serial")
	var t_now := GameState.time_left
	GameState.call(&"_rpc_time", 3.0, serial - 1)
	_check(is_equal_approx(GameState.time_left, t_now), "stale timer sync (old serial) ignored")
	GameState.call(&"_rpc_time", 42.0, serial)
	_check(is_equal_approx(GameState.time_left, 42.0), "timer sync applied")
	GameState.time_left = 65.2
	_check(GameState.get_time_string() == "01:06", "get_time_string(65.2) = 01:06")
	_events.clear()
	GameState.server_send_full_state(1)
	_check(_has_event(["phase", GameState.Phase.PLAYING]), "server_send_full_state(self) re-emits state")

	# --- MENU start = implicit reset
	GameState.reset_local()
	_check(GameState.phase == GameState.Phase.MENU and GameState.money == 0, "reset_local -> MENU defaults")
	GameState.server_start_round()
	_check(GameState.phase == GameState.Phase.PLAYING and GameState.round_number == 1 and GameState.money == start_money,
		"server_start_round from MENU resets then starts")

	# --- non-host requests are ignored
	GameState.reset_local()
	Net.set(&"is_host", false)
	GameState.request_start_round()
	_check(GameState.phase == GameState.Phase.MENU, "request_start_round ignored when not host")
	Net.set(&"is_host", true)
	GameState.reset_local()
	_check(GameState.phase == GameState.Phase.MENU, "reset_local -> MENU")


# ---------------------------------------------------------------------------------------------
# HUD / overlays
# ---------------------------------------------------------------------------------------------

func _test_ui() -> void:
	print("== HUD / overlays")
	var hud_scene: PackedScene = load("res://scenes/ui/hud.tscn")
	var hud := hud_scene.instantiate() as HUD
	_check(hud != null, "hud.tscn instantiates as HUD (CanvasLayer)")
	if hud == null:
		return
	add_child(hud)
	await _frames_wait(2)
	_check(Game.local_player == null, "no local player yet (HUD must cope)")
	_check(hud.banner.visible and hud.banner_title.text.begins_with("CLOCKING IN"), "MENU: clocking-in banner")
	_check(not hud.stats.visible, "MENU: stats hidden")

	# WAITING as host
	GameState.server_reset_game()
	await _frames_wait(2)
	_check(hud.stats.visible, "WAITING: stats visible")
	_check(hud.banner.visible and hud.banner_title.text == "CLOCK IN", "WAITING host: 'CLOCK IN' banner")
	_check(hud.start_button.visible and hud.start_button.text == "START SHIFT", "WAITING host: START SHIFT button")
	_check(hud.banner_text.text == "Shift starts when you press ENTER.\nNobody leaves until it's paid.",
		"WAITING host: ENTER + nobody leaves (%s)" % hud.banner_text.text.c_escape())
	_check(hud.money_label.text == HUD.format_money(_balance.starting_money), "wallet shows %s" % hud.money_label.text)
	_check(hud.quota_label.text == "PAYMENT DUE $0 / %s" % HUD.format_money(GameState.quota), "quota label: %s" % hud.quota_label.text)
	_check(hud.round_label.text == "SHIFT 1", "round label: SHIFT 1")
	_check(hud.timer_label.text == GameState.get_time_string(), "timer label: %s" % hud.timer_label.text)
	_check(not hud.round_end.visible and not hud.pause_menu.visible, "no overlays in WAITING")

	# WAITING as a client
	_set_host(false)
	hud.refresh_all()
	_check(hud.banner_title.text == "STAND BY" and hud.banner_text.text == "Waiting for the shift to start." \
		and not hud.start_button.visible, "WAITING client: 'Waiting for the shift to start.', no button")
	_set_host(true)
	hud.refresh_all()

	# ENTER (start_round action) starts the round
	_push_action(&"start_round")
	await _frames_wait(2)
	_check(GameState.phase == GameState.Phase.PLAYING, "start_round action (ENTER) starts the round")
	_check(not hud.banner.visible, "PLAYING: banner hidden")
	_check(hud.go_banner.visible and hud.go_banner.text == "SHIFT 1 — GET TO WORK", "GO banner: %s" % hud.go_banner.text)

	# toasts: max 4, repeats bump
	for i in 6:
		Game.toast_requested.emit("Toast number %d" % i, &"info")
	await _frames_wait(1)
	_check(hud.get_toast_count() == 4, "toast stack capped at 4 (got %d)" % hud.get_toast_count())
	hud.show_toast("Hands full.", &"error")
	hud.show_toast("Hands full.", &"error")
	await _frames_wait(1)
	var newest := hud.toasts.get_child(hud.toasts.get_child_count() - 1) as HudToast
	_check(newest != null and newest.repeat_count == 2 and newest.theme_type_variation == &"ToastError", "repeat toast bumps (x2) with ToastError style")
	_check(hud.get_toast_count() == 4, "still 4 toasts after repeats")
	Game.toast("Seeds. Don't waste them.", &"success")
	await _frames_wait(1)
	var success_toast := hud.toasts.get_child(hud.toasts.get_child_count() - 1) as HudToast
	_check(success_toast != null and success_toast.theme_type_variation == &"ToastSuccess", "success toast uses ToastSuccess")

	# prompt from a fake interactor
	var fake := FakeInteractor.new()
	add_child(fake)
	hud.set_prompt_source(fake)
	fake.prompt_changed.emit("Plant Budget Bud", true)
	_check(hud.prompt_panel.visible and hud.prompt_label.text == "[E] Plant Budget Bud", "prompt enabled: %s" % hud.prompt_label.text)
	fake.prompt_changed.emit("Hands full.", false)
	_check(hud.prompt_panel.visible and hud.prompt_label.text == "Hands full." and hud.prompt_label.theme_type_variation == &"SubtleLabel", "prompt disabled: greyed reason")
	fake.prompt_changed.emit("", false)
	_check(not hud.prompt_panel.visible, "empty prompt hides the panel")
	hud.set_prompt_source(null)
	fake.queue_free()

	# real Player + Interactor scripts via Game.local_player_spawned (loaded dynamically: owned by others)
	await _test_local_player_path(hud)

	# sales / wallet juice
	var floats_before := hud.float_layer.get_child_count()
	GameState.server_add_sale(10, 1)
	await _frames_wait(1)
	_check(hud.quota_label.text == "PAYMENT DUE $10 / %s" % HUD.format_money(GameState.quota), "quota label after sale: %s" % hud.quota_label.text)
	_check(hud.money_label.text == HUD.format_money(GameState.money), "wallet after sale: %s" % hud.money_label.text)
	_check(hud.float_layer.get_child_count() > floats_before, "sale spawns a +$ float")
	GameState.server_try_spend(5, 1, "seeds")
	await _frames_wait(1)
	_check(hud.money_label.text == HUD.format_money(GameState.money), "wallet after purchase: %s" % hud.money_label.text)

	# timer turns red under the warning threshold
	GameState.time_left = HUD.TIMER_WARN_SEC - 5.5
	await _frames_wait(2)
	_check(hud.timer_label.has_theme_color_override(&"font_color"), "timer turns red under %d s" % int(HUD.TIMER_WARN_SEC))
	_check(hud.timer_label.text == GameState.get_time_string(), "timer label follows time_left (%s)" % hud.timer_label.text)

	# run a while in PLAYING
	await _frames_wait(60)

	# round success overlay (host)
	GameState.server_add_sale(GameState.quota - GameState.round_sales, 1)
	await _frames_wait(2)
	var re := hud.round_end
	_check(GameState.phase == GameState.Phase.ROUND_SUCCESS and re.visible, "ROUND_SUCCESS shows the round-end overlay")
	_check(re.title_label.text == "PAYMENT ACCEPTED…\nfor now" and re.title_label.theme_type_variation == &"TitleLabel",
		"success title: %s (no gold banner)" % re.title_label.text.c_escape())
	_check(re.subtitle_label.text == "Shift 1 paid. The Boss raises the number.", "success subline: %s" % re.subtitle_label.text)
	_check(re.primary_button.visible and re.primary_button.text == "NEXT SHIFT", "host: NEXT SHIFT button")
	_check(re.menu_button.text == "MAIN MENU" and not re.waiting_label.visible, "host: MAIN MENU, no waiting text")
	_check(re.next_value.text == HUD.format_money(_balance.quota_for_round(2)), "next payment preview %s" % re.next_value.text)
	_check(not hud.timer_label.has_theme_color_override(&"font_color"), "timer back to normal colour after the round")
	_set_host(false)
	re.refresh()
	_check(not re.primary_button.visible and re.waiting_label.visible and re.menu_button.text == "LEAVE", "client: waiting + LEAVE")
	_check(re.waiting_label.text == "Waiting for the Boss's decision…", "client: %s" % re.waiting_label.text)
	_set_host(true)
	re.refresh()
	re.primary_button.pressed.emit()
	await _frames_wait(2)
	_check(GameState.phase == GameState.Phase.PLAYING and GameState.round_number == 2, "NEXT ROUND button -> round 2 PLAYING")
	_check(not re.visible, "overlay hidden while PLAYING")
	_check(hud.round_label.text == "SHIFT 2", "round label: SHIFT 2")

	# failure overlay + retry
	GameState.time_left = 0.01
	await _wait_until(func() -> bool: return GameState.phase != GameState.Phase.PLAYING, 120)
	await _frames_wait(1)
	_check(GameState.phase == GameState.Phase.ROUND_FAILED and re.visible, "ROUND_FAILED shows the overlay")
	_check(re.title_label.text == "YOU MISSED THE PAYMENT" and re.primary_button.text == "START OVER",
		"failure: YOU MISSED THE PAYMENT + START OVER")
	_check(re.subtitle_label.text == "Nobody leaves. Start over.", "failure subline: %s" % re.subtitle_label.text)
	re.primary_button.pressed.emit()
	await _frames_wait(2)
	_check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "RETRY -> WAITING round 1")
	_check(not re.visible and hud.banner.visible, "overlay hidden, WAITING banner back")

	# pause menu
	var pm := hud.pause_menu
	_push_action(&"pause")
	await _frames_wait(1)
	_check(pm.visible, "pause action opens the pause menu")
	_push_action(&"pause")
	await _frames_wait(1)
	_check(not pm.visible, "pause action again closes it")
	Game.set_ui_lock(&"flow_test_shop", true)
	if Game.is_ui_locked():
		_push_action(&"pause")
		await _frames_wait(1)
		_check(not pm.visible, "pause does not open while another UI holds the lock")
		Game.set_ui_lock(&"flow_test_shop", false)
		await _frames_wait(1)
	else:
		print("SKIP: Game.set_ui_lock is still a stub (lock-aware pause check skipped)")
		Game.set_ui_lock(&"flow_test_shop", false)
	_push_action(&"pause")
	await _frames_wait(1)
	_check(pm.visible, "pause opens again")
	pm.resume_button.pressed.emit()
	await _frames_wait(1)
	_check(not pm.visible, "RESUME closes the pause menu")

	# back to MENU with the HUD alive, then free it
	GameState.reset_local()
	await _frames_wait(2)
	_check(not hud.stats.visible and not re.visible, "MENU after reset_local: stats + overlay hidden")
	hud.queue_free()
	await _frames_wait(3)
	_check(true, "HUD freed cleanly")


# ---------------------------------------------------------------------------------------------
# Balance numbers the copy / tests assume, team payment scaling
# ---------------------------------------------------------------------------------------------

func _test_balance_numbers() -> void:
	print("== Balance (payment numbers)")
	_check(_balance.starting_money == 150, "starting cash $150 (%d)" % _balance.starting_money)
	_check(_balance.quota_for_round(1) == 350, "shift 1 payment $350 solo (%d)" % _balance.quota_for_round(1))
	_check(_balance.quota_for_round(2) == 675, "shift 2 payment $675 solo = 350*1.5+150 (%d)" % _balance.quota_for_round(2))
	_check(is_equal_approx(_balance.quota_per_extra_player, 0.2), "+20%% per extra worker (%.2f)" % _balance.quota_per_extra_player)
	_check(_balance.quota_for_round(1, 4) == roundi(_balance.quota_for_round(1) * 1.6),
		"4 workers pay 1.6x the solo number (%d)" % _balance.quota_for_round(1, 4))
	_check(_balance.quota_for_round(1, 1) == _balance.quota_for_round(1) and _balance.quota_for_round(1, 0) == _balance.quota_for_round(1),
		"1 (or 0) workers = the solo number")


func _test_team_payment() -> void:
	print("== GameState team payment")
	var saved_players: Dictionary = Net.players.duplicate(true)
	var team := {}
	for id in [1, 2, 3, 4]:
		team[id] = {"name": "Worker %d" % id, "color": Color.WHITE}
	Net.players = team
	_check(GameState.get_team_size() == 4, "get_team_size() = 4")
	GameState.reset_local()
	GameState.server_reset_game()
	var solo := _balance.quota_for_round(1)
	_check(GameState.quota == _balance.quota_for_round(1, 4) and GameState.quota == roundi(solo * 1.6),
		"WAITING with 4 workers: payment %d = 1.6 x %d" % [GameState.quota, solo])
	Net.players.erase(4)
	Net.players_changed.emit()
	_check(GameState.quota == _balance.quota_for_round(1, 3), "WAITING: a worker leaves -> payment re-priced (%d)" % GameState.quota)
	GameState.request_start_round()
	_check(GameState.is_playing() and GameState.quota == _balance.quota_for_round(1, 3), "shift starts with the 3-worker payment (%d)" % GameState.quota)
	Net.players.erase(3)
	Net.players_changed.emit()
	_check(GameState.quota == _balance.quota_for_round(1, 3), "PLAYING: the running shift keeps its number")
	GameState.server_add_sale(GameState.quota, 1)
	_check(GameState.get_quota_for(2) == _balance.quota_for_round(2, 2), "next payment preview uses the current team (%d)" % GameState.get_quota_for(2))
	GameState.request_next_round()
	_check(GameState.round_number == 2 and GameState.quota == _balance.quota_for_round(2, 2), "shift 2 priced for 2 workers (%d)" % GameState.quota)
	Net.players = {}
	_check(GameState.get_team_size() == 1, "empty registry counts as 1 worker")
	GameState.reset_local()
	GameState.server_reset_game()
	_check(GameState.quota == solo, "solo payment unchanged ($%d)" % GameState.quota)
	Net.players = saved_players
	GameState.reset_local()


# ---------------------------------------------------------------------------------------------
# Story: debt board + Boss barks
# ---------------------------------------------------------------------------------------------

func _test_story() -> void:
	print("== Story")
	var lines: Dictionary = Story.lines
	for key in ["shift_start", "first_sale", "halfway", "paid", "missed", "purchase", "joined", "left", "last_call"]:
		var text := String(lines.get(key, ""))
		_check(text != "" and not text.contains("!"), "line '%s' exists, no '!' (%s)" % [key, text])
	_check(lines["shift_start"] == "Shift's on. Don't waste my time." and lines["last_call"] == "Tick tock.",
		"Boss lines match the script")
	var gap := Story.MIN_BARK_GAP_SEC
	var ttl := Story.PENDING_TTL_SEC
	var boss := FakeBoss.new()
	add_child(boss)
	var board := FakeBoard.new()
	Story.boss_override = boss
	Story.board_override = board
	Story.reset_state()
	_check(Story.get_board_text() == "PAY UP", "MENU: board shows the room default 'PAY UP'")

	# WAITING -> the payment on the board
	GameState.server_reset_game()
	_check(board.text == "OWED $350 / SHIFT 1", "WAITING board: %s" % board.text)
	_check(boss.said.is_empty(), "nothing barked before the shift")

	# shift start: MAJOR, immediate
	GameState.request_start_round()
	_check(boss.last() == lines["shift_start"], "shift start bark: %s" % boss.last())
	_check(board.text == "OWED $350 / SHIFT 1", "PLAYING board: %s" % board.text)

	# first deposit: queued behind the shift line (min gap), then shown
	GameState.server_add_sale(1, 1)
	_check(board.text == "OWED $349 / SHIFT 1", "board counts down on a deposit: %s" % board.text)
	_check(boss.last() == lines["shift_start"] and Story.get_pending_text() == lines["first_sale"],
		"first deposit within %.0f s of the last line waits in the queue" % gap)
	Story.tick(gap + 0.1)
	_check(boss.last() == lines["first_sale"] and Story.get_pending_text() == "", "after the gap: '%s'" % boss.last())

	# purchase right after: rate-limited
	GameState.server_try_spend(5, 1, "seeds")
	_check(boss.last() == lines["first_sale"] and Story.get_pending_text() == lines["purchase"], "purchase within the gap is queued")
	# halfway: a heavier line cuts through the gap and replaces the queued chatter
	GameState.server_add_sale(ceili(GameState.quota * 0.5), 1)
	_check(boss.last() == lines["halfway"], "passing 50%% barks at once: %s" % boss.last())
	_check(Story.get_pending_text() == "", "the queued purchase line was dropped")
	# stale queue entries expire
	GameState.server_try_spend(5, 1, "seeds")
	_check(Story.get_pending_text() == lines["purchase"], "chatter after a heavier line waits")
	Story.tick(ttl + 0.5)
	_check(Story.get_pending_text() == "" and boss.last() == lines["halfway"], "a line older than %.0f s is dropped" % ttl)
	GameState.server_try_spend(5, 1, "seeds")
	_check(boss.last() == lines["purchase"], "after the gap a purchase barks at once: %s" % boss.last())

	# last 30 s: MAJOR, once per shift
	GameState.time_left = Story.LAST_CALL_SEC - 0.5
	await _frames_wait(3)
	_check(boss.last() == lines["last_call"], "last 30 s: %s" % boss.last())
	await _frames_wait(3)
	_check(boss.said.count(lines["last_call"]) == 1, "'Tick tock.' only once per shift")

	# payment met: the final deposit says nothing itself, the verdict does
	var before := boss.said.size()
	GameState.server_add_sale(GameState.quota - GameState.round_sales, 1)
	_check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "payment met -> ROUND_SUCCESS")
	_check(boss.said.size() == before + 1 and boss.last() == lines["paid"], "one bark on payment met: %s" % boss.last())
	_check(board.text == "PAID… FOR NOW", "success board: %s" % board.text)

	# next shift: MAJOR cuts through the gap
	GameState.request_next_round()
	_check(boss.last() == lines["shift_start"], "shift 2 start bark right after the verdict")
	_check(board.text == "OWED $675 / SHIFT 2", "shift 2 board: %s" % board.text)

	# workers come and go (Net signals, every peer)
	Net.peer_joined.emit(4242)
	_check(Story.get_pending_text() == lines["joined"], "join within the gap is queued")
	Story.tick(gap + 0.1)
	_check(boss.last() == lines["joined"], "join bark: %s" % boss.last())
	Net.peer_left.emit(multiplayer.get_unique_id())
	_check(Story.get_pending_text() == "", "my own leave is not barked")
	Net.peer_left.emit(4242)
	Story.tick(gap + 0.1)
	_check(boss.last() == lines["left"], "leave bark: %s" % boss.last())

	# missed payment
	GameState.time_left = 0.01
	await _wait_until(func() -> bool: return GameState.phase != GameState.Phase.PLAYING, 120)
	_check(GameState.phase == GameState.Phase.ROUND_FAILED and boss.last() == lines["missed"], "missed payment bark: %s" % boss.last())
	_check(board.text == "YOU'RE DONE", "failure board: %s" % board.text)
	GameState.request_retry()
	_check(board.text == "OWED $350 / SHIFT 1", "START OVER: board back to %s" % board.text)

	# bark_now + fallbacks
	Story.bark_now("Back to work.")
	_check(boss.last() == "Back to work." and Story.last_bark == "Back to work.", "bark_now() skips the queue")
	var toasts: Array = []
	var on_toast := func(text: String, _kind: StringName) -> void: toasts.append(text)
	Game.toast_requested.connect(on_toast)
	var old_npc := Node.new()
	add_child(old_npc)
	Story.boss_override = old_npc
	Story.bark_now("No breaks.")
	_check(toasts.has("Boss: No breaks."), "NPC without bark(): the line becomes a toast %s" % [toasts])
	Story.boss_override = null
	Story.board_override = null
	toasts.clear()
	Story.bark_now("Nobody hears this.")
	Story.refresh_board()
	_check(toasts.is_empty() and Story.last_bark == "Nobody hears this." and Story.bark_log.has("Nobody hears this."),
		"no world: nothing shown, the line is still logged")
	_check(Story.board_text == "OWED $350 / SHIFT 1", "no world: board text still tracked, no crash")
	Game.toast_requested.disconnect(on_toast)
	GameState.reset_local()
	_check(Story.last_bark == "" and Story.get_pending_text() == "", "MENU clears Story's state")
	old_npc.queue_free()
	boss.queue_free()
	await _frames_wait(1)


func _test_local_player_path(hud: HUD) -> void:
	var player_script: Script = load("res://scripts/player/player.gd")
	var interactor_script: Script = load("res://scripts/interaction/interactor.gd")
	if player_script == null or interactor_script == null or not player_script.can_instantiate() or not interactor_script.can_instantiate():
		print("SKIP: player.gd / interactor.gd not instantiable right now (owned by other agents)")
		return
	var player: Node = player_script.new()
	var interactor: Node = interactor_script.new()
	interactor.name = "Interactor"
	player.add_child(interactor)
	interactor.owner = player
	interactor.unique_name_in_owner = true
	if not interactor.has_signal(&"prompt_changed") or not player.has_method(&"get_interactor"):
		print("SKIP: Player/Interactor contract not present")
		player.free()
		return
	Game.set(&"local_player", player)
	Game.local_player_spawned.emit(player)
	interactor.emit_signal(&"prompt_changed", "Water plant", true)
	_check(hud.prompt_panel.visible and hud.prompt_label.text == "[E] Water plant", "local_player_spawned -> interactor prompt wired (%s)" % hud.prompt_label.text)
	await _frames_wait(3) # held-item polling with an off-tree player must be harmless
	_check(not hud.held_panel.visible, "no held item shown for an off-tree player")
	Game.set(&"local_player", null)
	player.free()
	await _seconds_wait(HUD.HELD_POLL_SEC * 3.0) # an off-tree player has no tree_exiting: the poll notices
	_check(not hud.prompt_panel.visible, "prompt cleared after the local player is gone")


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


## Index of the first recorded event whose leading values equal `prefix`, or -1.
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
	if cond:
		passed += 1
		print("PASS: " + what)
	else:
		failed += 1
		print("FAIL: " + what)


func _frames_wait(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _seconds_wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_until(cond: Callable, max_frames: int) -> void:
	for i in max_frames:
		if cond.call():
			return
		await get_tree().process_frame


func _push_action(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	get_viewport().push_input(ev)
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	get_viewport().push_input(release)


func _set_host(host: bool) -> void:
	Net.set(&"is_host", host)
	GameState.set(&"_authoritative", host)


func _mmss(seconds: float) -> String:
	var total := ceili(seconds)
	return "%02d:%02d" % [int(total / 60.0), total % 60]


func _total_upgrade_cost() -> int:
	var total := 0
	for def: UpgradeDef in _balance.upgrades:
		for lvl in range(1, def.max_level + 1):
			total += def.cost_for_level(lvl)
	return total


func _upgrade_with_effect(effect_key: StringName) -> UpgradeDef:
	for def: UpgradeDef in _balance.upgrades:
		if def.effect_key == effect_key:
			return def
	return null


func _cheapest_available_upgrade() -> UpgradeDef:
	var best: UpgradeDef = null
	for def: UpgradeDef in _balance.upgrades:
		if GameState.get_upgrade_level(def.id) < def.max_level:
			if best == null or def.cost_for_level(1) < best.cost_for_level(1):
				best = def
	return best
