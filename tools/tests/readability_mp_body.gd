extends "res://tools/tests/qa_base.gd"
## M19 readability multi-process suite (readability agent), driven by tools/tests/readability_mp.sh: a host, client A
## (joins at the start) and client B (joins in the middle of the shift, after the costs were booked). Every process runs
## with --events; the host stops its scheduler once the shift starts and starts the events itself.
##   host: a told power cut (the flicker on A, the mains go after the tell); a told audit (A's banner counts down to the
##         count, the hint names the answer, then the raise); a raid that takes two bundles, a paid collector, a phone
##         that rings out, a deposit on a light scale: the ledger (marker READ_COSTS starts B); with B in, a burst of
##         four toasts (READ_BURST); the shift ends (READ_END): the report.
##   a:    the flicker and the told power cut, the told audit on its banner, the ledger as it is booked, the burst's
##         newest three toasts, the report's lines.
##   b:    the ledger from the late-join replay, the burst's newest three toasts, the report's lines.
## Every process prints "READ_LINES|..." (the report's cost lines) and "READ_TOASTS|..." (the burst's live toasts);
## readability_mp.sh fails unless the three processes printed the same.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 30.0
const HOST_SPOT := Vector3(8.0, 0.05, 6.2)
## The burst: four toasts in one frame on every peer; the HUD keeps the newest three.
const BURST := ["The phone is ringing. Somebody pick that up.", "Raid. Get the product out of sight.",
		"Collection. He wants $40. He is on the dock.", "Host paid the collector $40."]

var role: String = "host"
var port: int = 7917
var _started: Array = []
var _tell_ended: Array = []
var _counted: Array = []
var _cost_changes: int = 0


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7917))
	_label = "readability_mp:" + role
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.tell_ended.connect(func(k: StringName) -> void: _tell_ended.append(k))
	Events.audit_counted.connect(func(r: int) -> void: _counted.append(r))
	Events.shift_costs_changed.connect(func() -> void: _cost_changes += 1)
	match role:
		"host": await _host()
		"a": await _client_a()
		"b": await _client_b()
	finish()


# --- host ------------------------------------------------------------------------------------------------------------

func _host() -> void:
	step("hosting on %d" % port)
	Game.start_host("Host", port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		return
	print("READ_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	Config.user_args.erase("events")   # this suite starts its own events
	Events.set(&"_next_in", -1.0)
	GameState.server_add_money(600 - GameState.money)
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = HOST_SPOT
	await wait_sec(1.0)

	step("a told power cut")
	check(Events.server_start_scheduled(Events.EVENT_POWER_CUT), "the power cut starts told")
	print("READ_POWER")
	await wait_sec(1.0)
	check(Events.is_power_on() and Events.is_in_tell(), "host: the mains are still on during the tell")
	await wait_until(func() -> bool: return not Events.is_power_on(), 5.0, "host: the mains go when the tell runs out")
	check(_tell_ended == [Events.EVENT_POWER_CUT], "host: tell_ended(power_cut)")
	await wait_sec(1.5)
	Events.server_end_event()
	await wait_sec(1.0)

	step("a told audit")
	var q0 := GameState.quota
	check(Events.server_start_scheduled(Events.EVENT_AUDIT), "the audit starts told")
	print("READ_AUDIT")
	await wait_sec(2.0)
	check(GameState.quota == q0, "host: nothing counted during the countdown")
	await wait_until(func() -> bool: return not _counted.is_empty(), 10.0, "host: he counts when the countdown runs out")
	check(GameState.quota == q0 + int(round(q0 * b.audit_raise_fraction)) and _counted == [GameState.quota - q0], "host: +$%d (10%% of what is owed)" % (GameState.quota - q0))
	await wait_sec(1.0)
	Events.server_end_event()

	step("the costs")
	var points := Game.world.room.get_raid_points()
	var mid: Vector3 = points[2] if points.size() > 2 else Vector3.ZERO
	for off: Vector3 in [Vector3(1.0, 0.3, 0.0), Vector3(-1.0, 0.3, 0.5)]:
		Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 1}, mid + Vector3(off.x, 0.0, off.z) + Vector3.UP * off.y, 0)
	for i in 3:
		await get_tree().physics_frame
	check(Events.server_start_event(Events.EVENT_RAID), "a raid")
	var r := Events.server_raid_sweep(2)
	check((r["taken"] as Array).size() == 2, "the middle look took both bundles")
	Events.server_end_event()
	check(Events.server_start_event(Events.EVENT_COLLECTION) and Events.server_pay_collector(1), "the collector is paid")
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	_tick(b.phone_sec + 0.1)
	check(not Events.is_event_active(), "nobody picked up")
	check(Events.server_start_scheduled(Events.EVENT_SCALE), "the scale goes off told")
	_tick(3.05)
	var chute := Game.world.room.get_station("TurnInStation") as TurnInStation
	var light := Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 1}, Vector3.ZERO, 1)
	check(chute.server_sell_item(light, 1), "a deposit on the light scale")
	Events.server_end_event()
	await wait_sec(0.5)
	var costs := Events.get_shift_costs()
	check(costs.size() == 5, "host: five sources booked (%s)" % [costs])
	print("READ_COSTS")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and Game.world.get_players().size() >= 3, JOIN_TIMEOUT, "client B joined in the middle of the shift")
	await wait_sec(4.0)   # the join's own toasts are gone

	step("the burst")
	await _burst_host(b)
	print("READ_BURST")
	await wait_sec(1.0)
	_print_toasts()
	await wait_sec(2.0)

	step("the end of the shift")
	GameState.time_left = 0.2
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 5.0, "the shift ends unpaid")
	await wait_sec(1.0)
	_check_report("host")
	print("READ_END")
	allow_error("Unable to send packet on channel 0", 2, true)
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT + 30.0, "both clients left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")
	check(Events.get_shift_costs().is_empty(), "host: the menu forgets the ledger")


## Four toasts in one frame on every peer (the phone, the raid cut short before it looked, the collector and who paid
## him).
func _burst_host(b: BalanceConfig) -> void:
	check(Events.server_start_event(Events.EVENT_PHONE), "burst: the phone")
	Events.server_end_event()
	check(Events.server_start_event(Events.EVENT_RAID), "burst: the raid")
	Events.server_end_event()
	check(Events.server_start_event(Events.EVENT_COLLECTION) and Events.server_pay_collector(1), "burst: the collector, paid")
	check(b.collector_fee == 40, "the burst's copy assumes $40")


# --- client A -------------------------------------------------------------------------------------------------------

func _client_a() -> void:
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "A: joined and spawned")
	if Game.local_player == null:
		return
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	Game.local_player.global_position = Vector3(2.5, 0.05, 2.5)

	step("A: the told power cut")
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_POWER_CUT), STEP_TIMEOUT, "A: event_started(power_cut)")
	var p: Dictionary = _started.back()[1]
	check(is_equal_approx(float(p.get("tell", 0.0)), 3.0) and p.has("total"), "A: params carry the tell (%s)" % [p])
	check(Events.is_power_on() and Events.is_in_tell() and Events.is_flickering(), "A: the mains are on, the lights flicker")
	check(hud.get_event_text().begins_with("POWER CUT") and hud.event_hint.text == "Find the breaker.", "A: the banner and its hint")
	await wait_until(func() -> bool: return not Events.is_power_on(), 6.0, "A: the mains go")
	await wait_until(func() -> bool: return _tell_ended.has(Events.EVENT_POWER_CUT), 3.0, "A: tell_ended(power_cut)")
	check(not Events.is_flickering() and not Game.world.room.is_power_on(), "A: no more flicker, the room is dark")
	await wait_until(func() -> bool: return Events.is_power_on() and not Events.is_event_active(), STEP_TIMEOUT, "A: power back, the cut over")
	check(Game.world.room.is_power_on(), "A: the room is lit")

	step("A: the told audit")
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_AUDIT), STEP_TIMEOUT, "A: event_started(audit)")
	await wait_frames(2)
	check(hud.get_event_text().begins_with("AUDIT 0:0") and hud.event_hint.text == HUD.TEXT_READ_AUDIT_HINT, "A: the banner counts down to the count: '%s' / '%s'" % [hud.get_event_text(), hud.event_hint.text])
	await wait_until(func() -> bool: return not _counted.is_empty(), 12.0, "A: audit_counted arrived")
	await wait_frames(2)
	var raise: int = _counted[0]
	check(raise > 0 and hud.event_hint.text == HUD.TEXT_READ_AUDIT_DONE % HUD.format_money(raise) and toast_seen("Audit: payment due up %s." % HUD.format_money(raise)),
			"A: the hint and the toast say the raise ($%d): '%s'" % [raise, hud.event_hint.text])

	step("A: the ledger")
	await wait_until(func() -> bool: return Events.get_shift_costs().size() == 5, STEP_TIMEOUT, "A: five sources booked (%s)" % [Events.get_shift_costs()])
	var costs := Events.get_shift_costs()
	check(int((costs.get(Events.COST_RAID, {}) as Dictionary).get("bundles", 0)) == 2 and int((costs.get(Events.COST_AUDIT, {}) as Dictionary).get("money", 0)) == raise,
			"A: the raid's two bundles, the audit's raise")
	await _burst_client("A")
	await _end_client("A")


# --- client B (late joiner) ---------------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	Game.local_player.global_position = Vector3(2.5, 0.05, -2.5)
	await wait_until(func() -> bool: return Events.get_shift_costs().size() == 5, 6.0, "B: the ledger came with the replay")
	var costs := Events.get_shift_costs()
	check(int((costs.get(Events.COST_RAID, {}) as Dictionary).get("bundles", 0)) == 2 and String((costs.get(Events.COST_RAID, {}) as Dictionary).get("strain", "")) == "golden"
			and int((costs.get(Events.COST_PHONE, {}) as Dictionary).get("money", 0)) == Config.balance.phone_fine, "B: the raid's two Golden Kush bundles, the phone's fine")
	check(Story.get_shift_cost_lines().size() == 3, "B: three lines to say already (%s)" % [Story.get_shift_cost_lines()])
	await _burst_client("B")
	await _end_client("B")


# --- shared ---------------------------------------------------------------------------------------------------------

func _burst_client(tag: String) -> void:
	step("%s: the burst" % tag)
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	await wait_until(func() -> bool: return _live_texts(hud).has(BURST[3]), STEP_TIMEOUT, "%s: the burst arrived" % tag)
	await wait_frames(3)
	var live := _live_texts(hud)
	check(hud.get_toast_count() == 3 and live == PackedStringArray([BURST[1], BURST[2], BURST[3]]), "%s: the newest three toasts, the oldest gone: %s" % [tag, live])
	_print_toasts()


func _end_client(tag: String) -> void:
	step("%s: the report" % tag)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, STEP_TIMEOUT, "%s: the shift ended" % tag)
	await wait_sec(1.5)
	_check_report(tag)
	step("%s leaves" % tag)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(Events.get_shift_costs().is_empty(), "%s: the menu forgets the ledger" % tag)


## The report's lines: three, the dearest first, the raid's and the collector's as expected; printed for the .sh.
func _check_report(tag: String) -> void:
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	var report := hud.round_end.report if hud != null else null
	var lines := report.get_cost_texts() if report != null else PackedStringArray()
	var golden := TurnInStation.compute_sale_value(Config.balance.get_seed(&"golden"), 1, GameState.get_sale_multiplier())
	check(hud != null and hud.round_end.visible and lines.size() == 3, "%s: the round-end card says what it cost (%s)" % [tag, lines])
	check(lines.size() == 3 and lines[0] == "The raid took two bundles of Golden Kush. %s." % HUD.format_money(2 * golden)
			and lines.has("The collector took %s." % HUD.format_money(2 * Config.balance.collector_fee)), "%s: the raid first, the collector's two fees" % tag)
	check(lines == Story.get_shift_cost_lines(), "%s: the card shows the ledger's lines" % tag)
	print("READ_LINES|%s" % "|".join(lines))


func _print_toasts() -> void:
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	print("READ_TOASTS|%s" % "|".join(_live_texts(hud)))


func _live_texts(hud: HUD) -> PackedStringArray:
	var out := PackedStringArray()
	if hud == null:
		return out
	for c in hud.toasts.get_children():
		var t := c as HudToast
		if t != null and not t.is_queued_for_deletion() and not t.is_dismissing():
			out.append(t.text)
	return out


func _tick(seconds: float) -> void:
	var t := 0.0
	while t < seconds - 0.0001:
		var d := minf(0.05, seconds - t)
		Events.tick(d)
		t += d
