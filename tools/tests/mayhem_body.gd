extends "res://tools/tests/qa_base.gd"
## M14 mayhem suite (mayhem agent): the leak and the drive-by on a single headless host with fake workers
## (Net.players + World.server_spawn_player, no owning peer). Deterministic: time is advanced with Events.tick().
##   kinds / weights / picker, --first-event with the two kinds;
##   the leak: params, the Well's synced state and its visuals, the patch request (refused from afar and from the back
##   room, granted after the real hold), unpatched: the tank is empty and fills again, the puddle slips a sprinting
##   worker and not a walking, crouching or jumping one, one slip per 3 s, the puddle dries;
##   the drive-by: lanes from the Room API, one round (a standing worker goes down and drops his item, a crouched one,
##   one behind a LAYER_WORLD box and one in the back room do not; the 0.45 m radius), trays (a growing one loses
##   progress once, never below 0, a READY one is not harmed, the plant in front shields the tray behind), the event
##   (warning, rounds every 0.15 s down API lanes, the bill with enough cash, with too little and with none);
##   late-join replay by direct RPC call; force end / shift end / game reset / menu.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/mayhem_body.gd --port=7969 --events --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const STEP := 0.05

var _started: Array = []      # [kind, params]
var _ended: Array = []        # [kind]
var _resolved: Array = []     # [patched, by_peer]
var _refilled: int = 0
var _slipped: Array = []      # peer ids
var _shots: Array = []        # [from, to]
var _shot_workers: Array = [] # peer ids
var _shot_trays: Array = []   # plot names
var _billed: Array = []       # [fine, taken]
var _world: World
var _room: Room
var _well: Well
var _hud: HUD


func _run() -> void:
	_label = "mayhem"
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.leak_resolved.connect(func(patched: bool, by: int) -> void: _resolved.append([patched, by]))
	Events.tank_refilled.connect(func() -> void: _refilled += 1)
	Events.worker_slipped.connect(func(p: int) -> void: _slipped.append(p))
	Events.shot_fired.connect(func(from: Vector3, to: Vector3) -> void: _shots.append([from, to]))
	Events.worker_shot.connect(func(p: int) -> void: _shot_workers.append(p))
	Events.tray_shot.connect(func(n: String) -> void: _shot_trays.append(n))
	Events.driveby_billed.connect(func(fine: int, taken: int) -> void: _billed.append([fine, taken]))
	var b: BalanceConfig = Config.balance

	step("kinds + weights")
	check(Config.has_arg("events") and Events.are_events_enabled(), "this suite runs with --events")
	check(Events.KINDS.size() == 14 and Events.KINDS.has(Events.EVENT_LEAK) and Events.KINDS.has(Events.EVENT_DRIVEBY), "KINDS: the seven earlier kinds + leak, driveby (+ the three M15 mayhem2 kinds + the two M17 mayhem3 kinds)")
	var total := 0
	for k in Events.KINDS:
		total += int(Events.WEIGHTS.get(k, 0))
	check(total == 100 and Events.WEIGHTS.size() == Events.KINDS.size(), "weights sum to 100 over %d kinds (%d)" % [Events.KINDS.size(), total])
	# M15 mayhem2 rebalanced the weights for twelve kinds, M17 mayhem3 for fourteen (tools/tests/mayhem3_body.gd pins all
	# fourteen).
	var expected := {Events.EVENT_INSPECTION: 20, Events.EVENT_POWER_CUT: 12, Events.EVENT_AUDIT: 7, Events.EVENT_RAT: 6,
			Events.EVENT_HEADCOUNT: 9, Events.EVENT_WATER_OFF: 6, Events.EVENT_SHORTAGE: 5, Events.EVENT_LEAK: 7, Events.EVENT_DRIVEBY: 7}
	var weights_ok := true
	for k in expected:
		if int(Events.WEIGHTS.get(k, -1)) != int(expected[k]):
			weights_ok = false
	check(weights_ok, "weights: inspection 20 / power_cut 12 / audit 7 / rat 6 / headcount 9 / water_off 6 / shortage 5 / leak 7 / driveby 7")
	var kinds_seen: Dictionary = {}
	var repeats := 0
	for k in Events.KINDS:
		for i in 80:
			var pick := Events.pick_kind(k)
			kinds_seen[pick] = true
			if pick == k or not Events.KINDS.has(pick):
				repeats += 1
	check(repeats == 0, "pick_kind() never repeats the previous kind and stays in KINDS")
	check(kinds_seen.size() == Events.KINDS.size(), "pick_kind() reaches every kind (%d seen)" % kinds_seen.size())
	check(Story.line("leak") == "The tank is leaking. Somebody hold it shut." and Story.line("leak_empty") == "Tank's empty. That one is on the floor." and Story.line("driveby") == "Get down.", "Story has the leak and drive-by lines")
	check(Story.mayhem_amount_words(30) == "thirty" and Story.mayhem_amount_words(12) == "twelve" and Story.mayhem_amount_words(25) == "twenty-five" and Story.mayhem_amount_words(0) == "nothing" and Story.mayhem_amount_words(140) == "$140", "the Boss says amounts in words up to ninety-nine")
	var copy_ok := true
	for k: String in Story.MAYHEM_LINES:
		var text := String(Story.MAYHEM_LINES[k])
		if text.contains("!") or Story.line(k) != text:
			copy_ok = false
	check(copy_ok, "every mayhem line is installed and has no exclamation mark")
	for n: StringName in [&"leak", &"slip", &"tires", &"gunshot", &"ricochet", &"glass_shot"]:
		check(Sfx.has_sound(n), "Sfx has %s" % n)
	check(is_equal_approx(Events.get_slip_speed(), lerpf(b.walk_speed, b.sprint_speed, 0.4)) and Events.get_slip_speed() > b.walk_speed and Events.get_slip_speed() < b.sprint_speed, "the slip speed sits between walking and sprinting (%.2f)" % Events.get_slip_speed())

	step("hosting")
	Game.start_host("Tester", port_arg(7969))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_well = _room.get_station("Well") as Well
	_hud = _world.get_node_or_null(^"HUD") as HUD
	check(_well != null and _hud != null, "the Well and the HUD exist")
	for id in [2, 3, 4]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	check(_world.get_players().size() == 4, "host + 3 fake workers spawned")
	check(not Events.server_start_event(Events.EVENT_LEAK) and not Events.server_start_event(Events.EVENT_DRIVEBY), "no event while WAITING")

	step("shift start")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(600)

	await _test_first_event()
	await _test_leak_patched(b)
	await _test_leak_unpatched(b)
	await _test_one_round(b)
	await _test_trays(b)
	await _test_driveby_event(b)
	await _test_replay(b)
	await _test_resets(b)
	finish()


# --- --first-event --------------------------------------------------------------------------------------------------

func _test_first_event() -> void:
	step("--first-event")
	for kind: StringName in [Events.EVENT_LEAK, Events.EVENT_DRIVEBY]:
		Config.user_args["first-event"] = String(kind)
		Events.set(&"_forced_first_used", false)
		Events.set(&"_next_in", 0.5)
		_started.clear()
		Events.tick(1.0)
		check(Events.active_event == kind and _started.size() == 1 and _started[0][0] == kind, "--first-event=%s starts a %s" % [kind, Events.active_event])
		Events.server_end_event()
		await wait_frames(2)
		check(not Events.is_event_active(), "%s force-ended" % kind)
	Config.user_args.erase("first-event")
	Config.user_args.erase("events")   # the scheduler stays quiet from here (server_start_event does not need it)
	Events.set(&"_next_in", -1.0)
	check(not Events.are_events_enabled() and not Events.is_event_active(), "scheduler off, nothing running")
	check(_billed.is_empty(), "a force-ended drive-by bills nobody")
	check(not _well.is_leaking() and _well.has_puddle() and _well.has_pressure(), "a force-ended leak: the hole is shut, the puddle stays, nothing lost")
	Events.call(&"_mayhem_server_reset")
	await wait_frames(2)
	check(not _well.has_puddle() and Events.get_puddle_left() == 0.0, "reset: no puddle")
	_started.clear()
	_ended.clear()
	_resolved.clear()
	toasts.clear()


# --- the leak, patched ----------------------------------------------------------------------------------------------

func _test_leak_patched(b: BalanceConfig) -> void:
	step("leak: start")
	var me: Player = Game.local_player
	var jet := _well.get_node_or_null(^"Leak/Jet") as CPUParticles3D
	var hole := _well.get_node_or_null(^"Leak/Hole") as Node3D
	var plate := _well.get_node_or_null(^"Leak/Plate") as Node3D
	var disc := _well.get_node_or_null(^"Puddle") as Node3D
	check(jet != null and hole != null and plate != null and disc != null, "the Well has its Leak/Jet, Leak/Hole, Leak/Plate and Puddle nodes")
	check(not _well.is_leaking() and not _well.has_puddle() and not _well.is_patched() and _well.get_puddle_radius() == 0.0, "dry before: no leak, no puddle, no plate")
	await wait_until(func() -> bool: return disc != null and not disc.visible, 3.0, "the disc of the --first-event leak dried up")
	check(jet != null and not jet.emitting and hole != null and not hole.visible and disc != null and not disc.visible, "nothing to see before")
	check(_well.get_prompt(me) == "Fill can", "the usual prompt before")
	var loops0: int = Sfx.get_active_loop_count()
	var leaks: Array = []
	var puddles: Array = []
	_well.leaking_changed.connect(func(on: bool) -> void: leaks.append(on))
	_well.puddle_changed.connect(func(on: bool) -> void: puddles.append(on))
	check(Events.server_start_event(Events.EVENT_LEAK), "leak starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.leak_sec) and p.size() == 1, "params {seconds: leak_sec} (%s)" % [p])
	check(_well.leaking and _well.is_leaking() and _well.has_puddle() and leaks == [true] and puddles == [true], "Well.leaking is true, a puddle exists (signals %s %s)" % [leaks, puddles])
	check(is_equal_approx(_well.get_puddle_radius(), Well.PUDDLE_RADIUS_MIN), "the puddle starts at %.1f m" % Well.PUDDLE_RADIUS_MIN)
	check(jet.emitting and hole.visible and not plate.visible, "the jet runs out of the hole")
	check(Sfx.get_active_loop_count() == loops0 + 1, "the leak loop plays (%d loops, %d before)" % [Sfx.get_active_loop_count(), loops0])
	check(_well.get_prompt(me).contains("Patch the leak") and _well.can_interact(me) and _well.get_denied_reason(me) == "", "prompt 'Patch the leak', empty hands are enough")
	check(_well.has_pressure(), "the tank still has pressure while it leaks")
	check(_hud.get_event_text().begins_with("LEAK") and _hud.event_hint.visible and _hud.event_hint.text.begins_with("Hold ") and _hud.event_hint.text.ends_with("on the tank."), "HUD banner LEAK with the hint (%s / %s)" % [_hud.get_event_text(), _hud.event_hint.text])
	check(toast_seen("The tank is leaking") and _barked("The tank is leaking. Somebody hold it shut."), "the floor is told: toast + the Boss")
	check(not Events.server_start_event(Events.EVENT_DRIVEBY), "one at a time: a drive-by is refused meanwhile")
	await wait_sec(0.3)
	check(disc.visible and disc.scale.x > 0.3, "the disc is on the floor (scale %.2f)" % disc.scale.x)
	check(_flat(disc.global_position, _well.get_puddle_center()) < 0.01 and _well.get_puddle_center().distance_to(_well.global_position) > 1.0, "in front of the tank (%s)" % _well.get_puddle_center())
	var age0 := _well.get_puddle_radius()
	Events.tick(Well.PUDDLE_SPREAD_SEC * 0.5)
	var half := lerpf(Well.PUDDLE_RADIUS_MIN, Well.PUDDLE_RADIUS_MAX, 0.5)
	check(_well.get_puddle_radius() > age0 and absf(_well.get_puddle_radius() - half) < 0.15, "it spreads: %.2f m after %.0f s" % [_well.get_puddle_radius(), Well.PUDDLE_SPREAD_SEC * 0.5])
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() < b.leak_sec, "time left counts (%.1f)" % Events.get_event_time_left())

	step("leak: the patch request")
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(2.5, 0.05, 2.5)
	await wait_frames(2)
	toasts.clear()
	_well._rpc_request_patch()
	await wait_frames(2)
	check(_well.is_leaking() and toast_seen("Too far"), "refused from afar: 'Too far.'")
	stand_near(_well, 1.3)
	await wait_frames(2)
	check(GameState.server_send_to_backroom(1, 60.0), "the host sits in the back room")
	await wait_frames(2)
	toasts.clear()
	_well._rpc_request_patch()
	await wait_frames(2)
	check(_well.is_leaking() and toast_seen("back room"), "refused from the back room")
	GameState.server_release_from_backroom(1)
	await wait_frames(3)
	check(not GameState.is_in_backroom(1) and Events.is_event_active(Events.EVENT_LEAK), "let out; the leak still runs")

	step("leak: the hold")
	var patch_sec0 := b.leak_patch_sec
	Config.balance.leak_patch_sec = 0.6
	stand_near(_well, 1.3)
	me.head.rotation.x = -0.7
	await wait_sec(0.25)
	var interactor := me.get_interactor()
	check(interactor.current_target == _well, "looking at the tank (target %s)" % [interactor.current_target])
	_ended.clear()
	_resolved.clear()
	toasts.clear()
	Input.action_press(&"interact")
	_well.interact(me)
	check(_well.is_patching(), "holding the patch")
	await wait_sec(0.3)
	check(_well.get_patch_progress() > 0.2 and _well.get_patch_progress() < 0.9 and _well.get_prompt(me).contains(" s"), "hold progress %.2f, the prompt shows the seconds" % _well.get_patch_progress())
	check(_well.is_leaking(), "still leaking half-way")
	await wait_until(func() -> bool: return not _well.is_leaking(), 3.0, "the finished hold patches the leak")
	Input.action_release(&"interact")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_LEAK, "event_ended(leak)")
	check(_resolved.size() == 1 and _resolved[0][0] == true and int(_resolved[0][1]) == 1, "leak_resolved(patched, by the host) (%s)" % [_resolved])
	check(_well.is_patched() and plate.visible and not hole.visible and not jet.emitting, "the plate is on, the jet stopped")
	check(Sfx.get_active_loop_count() == loops0, "the leak loop stopped")
	check(_well.has_pressure() and _well.get_prompt(me) == "Fill can", "nothing lost: pressure on, the usual prompt")
	check(_well.has_puddle() and absf(Events.get_puddle_left() - b.puddle_sec) < 1.0, "the puddle stays: %.1f s to dry" % Events.get_puddle_left())
	check(toast_seen("Tester patched the tank.") and _barked("Patched."), "the floor hears who patched it")
	check(not _well.is_patching() and _well.get_patch_progress() == 0.0, "hold cleared")
	Input.action_press(&"interact")
	_well.interact(me)
	var held_dry := _well.is_patching()
	Input.action_release(&"interact")
	check(not held_dry, "interact on a tank that does not leak starts no hold")
	toasts.clear()
	_well._rpc_request_patch()
	await wait_frames(2)
	check(toast_seen("Nothing to patch"), "a patch request with no leak is refused")
	Config.balance.leak_patch_sec = patch_sec0

	step("leak: the puddle dries")
	var radius := _well.get_puddle_radius()
	Events.tick(5.0)
	check(is_equal_approx(_well.get_puddle_radius(), radius), "a patched tank feeds the puddle no more (%.2f m)" % radius)
	puddles.clear()
	Events.tick(Events.get_puddle_left() - 0.5)
	check(_well.has_puddle(), "still there half a second before puddle_sec")
	Events.tick(0.6)
	check(not _well.has_puddle() and puddles == [false] and _well.get_puddle_radius() == 0.0 and Events.get_puddle_left() == 0.0, "gone puddle_sec after the event")
	await wait_until(func() -> bool: return not disc.visible, 3.0, "the disc dries up")
	check(_well.is_patched() and plate.visible, "the plate stays on")
	_started.clear()
	_ended.clear()
	_resolved.clear()


# --- the leak, unpatched: the empty tank and the slips ----------------------------------------------------------------

func _test_leak_unpatched(b: BalanceConfig) -> void:
	step("leak: unpatched")
	var me: Player = Game.local_player
	var plate := _well.get_node_or_null(^"Leak/Plate") as Node3D
	var water := _well.get_node_or_null(^"Visual/Water") as Node3D
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(2.5, 0.05, 2.5)
	var puddle_sec0 := b.puddle_sec
	Config.balance.puddle_sec = 200.0   # the slips below take simulated time
	toasts.clear()
	check(Events.server_start_event(Events.EVENT_LEAK), "a second leak")
	check(_well.is_leaking() and not _well.is_patched() and plate != null and not plate.visible, "the plate came off")
	Events.tick(b.leak_sec - 0.5)
	check(Events.is_event_active(Events.EVENT_LEAK) and _well.is_leaking() and _well.has_pressure(), "still leaking half a second before leak_sec")
	check(is_equal_approx(_well.get_puddle_radius(), Well.PUDDLE_RADIUS_MAX), "the puddle is at its full %.1f m" % Well.PUDDLE_RADIUS_MAX)
	Events.tick(0.6)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_LEAK, "event_ended(leak) when leak_sec runs out")
	check(_resolved.size() == 1 and _resolved[0][0] == false, "leak_resolved(not patched)")
	check(not _well.is_leaking() and not _well.is_patched() and not _well.has_pressure(), "the tank is empty: no leak, no pressure")
	check(_well.get_prompt(me) == "No pressure." and water != null and not water.visible, "prompt 'No pressure.', the water is gone")
	check(absf(Events.get_leak_empty_left() - b.leak_empty_sec) < 0.5, "empty for leak_empty_sec (%.1f)" % Events.get_leak_empty_left())
	check(toast_seen("The tank is empty.") and _barked("Tank's empty. That one is on the floor."), "the floor is told: toast + the Boss")
	check(not Events.server_start_event(Events.EVENT_WATER_OFF) and not Events.server_start_event(Events.EVENT_LEAK), "an empty tank: no water_off, no second leak")
	check(_well.has_puddle() and absf(Events.get_puddle_left() - 200.0) < 0.5, "the puddle stays")

	step("slips")
	var c := _well.get_puddle_center()
	var r := _well.get_puddle_radius()
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	var w4 := _world.get_player(4)
	var a := Vector3(c.x, 0.0, c.z - r - 1.2)   # the run: straight through the middle of the puddle
	var z := Vector3(c.x, 0.0, c.z + r + 1.2)
	check(_well.is_in_puddle(c) and not _well.is_in_puddle(a) and not _well.is_in_puddle(z), "the run starts and ends outside the puddle and crosses its centre")
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, a, 2)
	await wait_frames(1)
	check(can != null and _world.items.get_held_by(2) == can, "worker 2 carries a can")
	var empty0 := Events.get_leak_empty_left()
	_dash(w2, a, z, b.sprint_speed)
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 1 and _slipped == [2], "a sprinting worker slips once on the way through (%s)" % [_slipped])
	check(w2.is_stunned() or not w2.can_be_staggered(), "he is down")
	check(_world.items.get_held_by(2) == null and not can.is_held(), "the can left his hands")
	check(_flat(can.rest_position, c) < r + 1.5, "and lies by the puddle")
	var slip_at := float((Events.get(&"_last_slip") as Dictionary).get(2, -1.0))
	# The 3 s rule on its own: the stagger immunity (real time) is taken away, then he runs again inside the 3 s.
	w2.set(&"_stagger_immune_until_msec", 0)
	w2.set(&"_stun_until_msec", 0)
	check(w2.can_be_staggered() and not w2.is_stunned(), "worker 2's stagger immunity is taken away")
	var near_a := Vector3(c.x, 0.0, c.z - r - 0.3)
	var clock := float(Events.get(&"_mayhem_clock"))
	check(clock - slip_at < Events.SLIP_COOLDOWN_SEC - 1.2, "his slip is %.2f s old: only the 3 s rule protects him now" % (clock - slip_at))
	_dash(w2, near_a, c, b.sprint_speed, 0.05, 5)
	clock = float(Events.get(&"_mayhem_clock"))
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 1 and clock - slip_at < Events.SLIP_COOLDOWN_SEC, "one slip per worker per 3 s: a second run %.2f s after the first is free" % (clock - slip_at))
	Events.tick(Events.SLIP_COOLDOWN_SEC)
	_dash(w2, a, z, b.sprint_speed)
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 2 and _slipped == [2, 2], "after 3 s he slips again")
	_dash(w3, a, z, b.walk_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "a walking worker does not slip")
	w4.crouching = true
	_dash(w4, a, z, b.sprint_speed)
	check(GameState.get_stat(4, Const.STAT_SLIPS) == 0, "a crouched worker does not slip, whatever his speed")
	w4.crouching = false
	_dash(w3, a, z, b.sprint_speed, 0.9)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "a worker in the air over the puddle does not slip")
	var beside := Vector3(r + 1.0, 0.0, 0.0)
	_dash(w3, a + beside, z + beside, b.sprint_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "sprinting past the puddle is fine")
	check(GameState.server_send_to_backroom(4, 60.0), "worker 4 sits in the back room")
	await wait_frames(2)
	_dash(w4, a, z, b.sprint_speed)
	check(GameState.get_stat(4, Const.STAT_SLIPS) == 0, "a back-room worker is left alone")
	GameState.server_release_from_backroom(4)
	await wait_frames(2)
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(c.x, 0.05, c.z)
	for i in 20:
		Events.tick(STEP)
	check(GameState.get_stat(1, Const.STAT_SLIPS) == 0, "standing in the puddle is fine (and arriving there by teleport is not a run)")
	me.global_position = Vector3(2.5, 0.05, 2.5)
	_world.items.server_despawn_item(can)
	await wait_frames(1)

	step("the tank fills again")
	var spent := empty0 - Events.get_leak_empty_left()
	check(spent > 1.0 and Events.get_leak_empty_left() > 2.0, "the empty tank's clock ran through the slips (%.1f s spent, %.1f left)" % [spent, Events.get_leak_empty_left()])
	toasts.clear()
	Events.tick(Events.get_leak_empty_left() - 0.5)
	check(not _well.has_pressure() and _refilled == 0, "still empty half a second before leak_empty_sec")
	Events.tick(0.6)
	await wait_frames(2)
	check(_well.has_pressure() and _refilled == 1 and Events.get_leak_empty_left() == 0.0, "the pressure returns by itself")
	check(_well.get_prompt(me).begins_with("Fill can") and water != null and water.visible, "the tank is back to normal")
	check(toast_seen("The tank has water again."), "and the floor is told")
	check(_well.has_puddle(), "the puddle is still there")
	Events.tick(Events.get_puddle_left() + 0.1)
	check(not _well.has_puddle(), "until its time is up")
	Config.balance.puddle_sec = puddle_sec0
	_started.clear()
	_ended.clear()
	_resolved.clear()
	_slipped.clear()


# --- one round down a lane ----------------------------------------------------------------------------------------------

func _test_one_round(b: BalanceConfig) -> void:
	step("drive-by: the lanes")
	var lanes: Array = _room.get_gunfire_lanes()
	var lanes_ok := lanes.size() >= 1
	for lane: Variant in lanes:
		if not (lane is Dictionary) or not ((lane as Dictionary).get("from") is Vector3) or not ((lane as Dictionary).get("to") is Vector3):
			lanes_ok = false
	check(lanes_ok, "Room.get_gunfire_lanes(): %d lanes of {from, to}" % lanes.size())
	if not lanes_ok:
		return
	# The lane with the longest open stretch carries this test's workers.
	var lane: Dictionary = lanes[_open_lane(lanes)]
	var open := _flat(lane["from"], _lane_end(lane))
	var from: Vector3 = lane["from"]
	var end := _lane_end(lane)
	check(open >= 6.0, "a lane with %.1f m of open floor (from %s)" % [open, from])
	var me: Player = Game.local_player
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	var w4 := _world.get_player(4)
	var safe := _safe_spots(lanes, 4)
	check(safe.size() == 4, "four spots clear of every lane")
	if safe.size() < 4:
		return
	me.velocity = Vector3.ZERO
	me.global_position = safe[0] + Vector3.UP * 0.05
	await wait_until(func() -> bool: return w2.can_be_staggered() and w3.can_be_staggered() and w4.can_be_staggered(), 4.0, "nobody is stagger-immune")

	step("drive-by: one round")
	var box := StaticBody3D.new()
	box.name = "TestCrate"
	box.collision_layer = Const.LAYER_WORLD
	box.collision_mask = 0
	var shape := CollisionShape3D.new()
	var cube := BoxShape3D.new()
	cube.size = Vector3(1.0, 2.4, 1.0)
	shape.shape = cube
	box.add_child(shape)
	_world.add_child(box)
	box.global_position = _at(from, end, 3.7) + Vector3.UP * 1.2
	_put(w2, _at(from, end, 1.5))             # standing in the lane
	_put(w3, _at(from, end, 2.5))             # crouched in the lane
	w3.crouching = true
	_put(w4, _at(from, end, 5.0))             # standing in the lane, behind the crate
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, w2.global_position, 2)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await wait_frames(1)
	check(can != null and _world.items.get_held_by(2) == can, "worker 2 carries a can")
	_shots.clear()
	_shot_workers.clear()
	var hit := Events.server_fire_lane(lane)
	check(hit.get("workers") == [2] and _shot_workers == [2], "the standing worker goes down (%s)" % [hit.get("workers")])
	check(w2.is_stunned() and not w2.can_be_staggered(), "he is stunned")
	check(_world.items.get_held_by(2) == null and not can.is_held(), "and dropped his can")
	check(GameState.get_stat(2, Const.STAT_SHOT) == 1, "STAT_SHOT counts it")
	check(GameState.get_stat(3, Const.STAT_SHOT) == 0 and not w3.is_stunned(), "the crouched worker is not hit")
	check(GameState.get_stat(4, Const.STAT_SHOT) == 0 and not w4.is_stunned(), "the worker behind the crate is not hit")
	var stop: Vector3 = hit.get("end", Vector3.ZERO)
	check(bool(hit.get("blocked", false)) and absf(_flat(from, stop) - 3.2) < 0.1, "the round stopped at the crate (%.2f m down the lane)" % _flat(from, stop))
	check(_shots.size() == 1 and (_shots[0][0] as Vector3).distance_to(from) < 0.001 and (_shots[0][1] as Vector3).distance_to(stop) < 0.001, "one cosmetic shot: from the lane start to where it stopped")
	var tracer := _room.get_node_or_null(^"Tracer") as MeshInstance3D
	check(tracer != null and absf((tracer.mesh as BoxMesh).size.z - from.distance_to(stop)) < 0.01, "a tracer line of that length")
	Events.server_fire_lane(lane)
	check(GameState.get_stat(2, Const.STAT_SHOT) == 1, "a second round right away: he is already down, nothing more happens")
	await wait_until(func() -> bool: return _room.get_node_or_null(^"Tracer") == null, 2.0, "the tracers fade and go")
	box.queue_free()
	_world.items.server_despawn_item(can)
	w3.crouching = false
	await get_tree().physics_frame
	await get_tree().physics_frame
	await wait_frames(1)

	step("drive-by: who is in the lane")
	_put(w2, safe[1])
	check(GameState.server_send_to_backroom(3, 60.0), "worker 3 sits in the back room")
	await wait_frames(2)
	_put(w3, _at(from, end, 2.5))             # his body stands in the lane all the same
	_put(w4, _at(from, end, 5.0, 0.4))        # 0.4 m beside the lane
	me.global_position = _at(from, end, 1.5) + Vector3.UP * 0.05
	await wait_frames(2)
	_shot_workers.clear()
	hit = Events.server_fire_lane(lane)
	var got: Array = hit.get("workers", [])
	got.sort()
	check(got == [1, 4], "the host in the lane and the worker 0.4 m beside it go down (%s)" % [got])
	check(GameState.get_stat(3, Const.STAT_SHOT) == 0, "the back-room worker is left alone")
	check(not bool(hit.get("blocked", true)) or _flat(from, hit.get("end", from)) > 5.5, "with the crate gone the round flies on (%.1f m)" % _flat(from, hit.get("end", from)))
	check(me.is_stunned() and GameState.get_stat(1, Const.STAT_SHOT) == 1 and GameState.get_stat(4, Const.STAT_SHOT) == 1, "both are stunned and counted")
	GameState.server_release_from_backroom(3)
	await wait_frames(2)
	_put(w3, _at(from, end, 2.5, 0.6))        # 0.6 m beside the lane
	hit = Events.server_fire_lane(lane)
	check((hit.get("workers", [0]) as Array).is_empty() and GameState.get_stat(3, Const.STAT_SHOT) == 0, "0.6 m beside the lane is out of it")
	var over := {"from": from + Vector3.UP * 2.0, "to": end + Vector3.UP * 2.0}
	_put(w3, _at(from, end, 2.5))
	hit = Events.server_fire_lane(over)
	check((hit.get("workers", [0]) as Array).is_empty(), "a round that passes over his head does not count")
	# A pane of glass on LAYER_WORLD between the lane's start and him: the round goes through it.
	var pane := StaticBody3D.new()
	pane.name = "GlassPane"
	pane.collision_layer = Const.LAYER_WORLD
	pane.collision_mask = 0
	var pane_shape := CollisionShape3D.new()
	var pane_box := BoxShape3D.new()
	pane_box.size = Vector3(0.6, 2.4, 0.6)
	pane_shape.shape = pane_box
	pane.add_child(pane_shape)
	_world.add_child(pane)
	pane.global_position = _at(from, end, 1.0) + Vector3.UP * 1.2
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(_flat(from, _lane_end(lane)) < 1.0, "a pane stands in the lane, 1 m in")
	hit = Events.server_fire_lane(lane)
	check(hit.get("workers") == [3] and GameState.get_stat(3, Const.STAT_SHOT) == 1, "the same spot at chest height does, through a pane of glass")
	check(bool(hit.get("glass", false)) and _flat(from, hit.get("end", from)) > 5.5, "glass does not stop a round (it went %.1f m)" % _flat(from, hit.get("end", from)))
	pane.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	check((Events.server_fire_lane({"from": from}).get("workers", [0]) as Array).is_empty() and (Events.server_fire_lane({}).get("workers", [0]) as Array).is_empty(), "a broken lane fires nothing")
	me.velocity = Vector3.ZERO
	me.global_position = safe[0] + Vector3.UP * 0.05
	_put(w2, safe[1])
	_put(w3, safe[2])
	_put(w4, safe[3])
	_shots.clear()
	_shot_workers.clear()


# --- trays --------------------------------------------------------------------------------------------------------------

func _test_trays(b: BalanceConfig) -> void:
	step("drive-by: trays")
	for i in range(1, 7):
		var pl := plot(i)
		if pl != null and pl.stage != GrowPlot.Stage.EMPTY:
			pl.server_reset()
	var seed0: SeedDef = b.seeds[0]
	var p1 := plot(1)   # growing, 0.5 into its stage
	var p2 := plot(2)   # growing, in the row behind plot 1
	var p3 := plot(3)   # READY
	var p5 := plot(5)   # growing, only 0.2 into its stage
	check(p1.server_plant(seed0.id) and p2.server_plant(seed0.id) and p3.server_plant(seed0.id) and p5.server_plant(seed0.id), "four trays planted")
	p3.stage = GrowPlot.Stage.READY
	await get_tree().physics_frame
	await get_tree().physics_frame
	await wait_frames(1)
	p1.stage_progress = 0.5
	p2.stage_progress = 0.5
	p3.stage_progress = 0.0
	p5.stage_progress = 0.2
	check(p1.is_growing() and p2.is_growing() and p5.is_growing() and p3.is_ready_to_harvest(), "three growing, one READY")
	Events.set(&"_driveby_trays_hit", {})
	_shot_trays.clear()
	# Along the row of plot 1 and plot 2, coming from the aisle side of plot 1.
	var dir := (p2.global_position - p1.global_position).normalized()
	var lane12 := {"from": p1.global_position - dir * 1.2 + Vector3.UP * 1.3, "to": p2.global_position + dir * 1.2 + Vector3.UP * 1.3}
	var hit := Events.server_fire_lane(lane12)
	check(hit.get("trays") == ["GrowPlot1"] and _shot_trays == ["GrowPlot1"], "the first tray in the lane takes the round (%s)" % [hit.get("trays")])
	check(absf(p1.stage_progress - (0.5 - b.driveby_tray_loss)) < 0.02, "it loses driveby_tray_loss of stage progress (%.2f)" % p1.stage_progress)
	check(bool(hit.get("blocked", false)) and absf(p2.stage_progress - 0.5) < 0.02, "its plant stops the round: the tray behind is untouched (%.2f)" % p2.stage_progress)
	Events.server_fire_lane(lane12)
	check(absf(p1.stage_progress - (0.5 - b.driveby_tray_loss)) < 0.02, "a tray takes one round per drive-by (%.2f)" % p1.stage_progress)
	var lane5 := {"from": p5.global_position - dir * 1.2 + Vector3.UP * 1.3, "to": p5.global_position + dir * 1.2 + Vector3.UP * 1.3}
	hit = Events.server_fire_lane(lane5)
	check(hit.get("trays") == ["GrowPlot5"] and p5.stage_progress == 0.0 and p5.is_growing(), "never below 0: 0.2 goes to 0, the stage stays")
	var lane3 := {"from": p3.global_position - dir * 1.2 + Vector3.UP * 1.3, "to": p3.global_position + dir * 1.2 + Vector3.UP * 1.3}
	hit = Events.server_fire_lane(lane3)
	check((hit.get("trays", [0]) as Array).is_empty() and p3.is_ready_to_harvest(), "a READY plant is not harmed")
	var miss := {"from": p2.global_position - dir * 1.2 + Vector3(0.0, 1.3, 1.4), "to": p2.global_position + dir * 1.2 + Vector3(0.0, 1.3, 1.4)}
	hit = Events.server_fire_lane(miss)
	check((hit.get("trays", [0]) as Array).is_empty() and absf(p2.stage_progress - 0.5) < 0.02, "a lane 1.4 m beside a tray misses it")
	check(_shot_trays == ["GrowPlot1", "GrowPlot5"], "tray_shot fired for the two that were hit (%s)" % [_shot_trays])
	for i in range(1, 7):
		var pl := plot(i)
		if pl != null and pl.stage != GrowPlot.Stage.EMPTY:
			pl.server_reset()
	await get_tree().physics_frame
	await wait_frames(1)
	_shots.clear()
	_shot_trays.clear()


# --- the event ----------------------------------------------------------------------------------------------------------

func _test_driveby_event(b: BalanceConfig) -> void:
	step("drive-by: the warning")
	var lanes: Array = _room.get_gunfire_lanes()
	var w2 := _world.get_player(2)
	await wait_until(func() -> bool: return w2.can_be_staggered(), 4.0, "worker 2 can be staggered again")
	GameState.server_add_money(600 - GameState.money)
	var shot0 := GameState.get_stat(2, Const.STAT_SHOT)
	_started.clear()
	_ended.clear()
	_billed.clear()
	_shots.clear()
	toasts.clear()
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "drive-by starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	var total := b.driveby_warning_sec + b.driveby_sec
	check(is_equal_approx(float(p.get("seconds", 0.0)), total) and is_equal_approx(float(p.get("warning", -1.0)), b.driveby_warning_sec) and p.size() == 2, "params {seconds: warning + gunfire, warning} (%s)" % [p])
	check(_hud.get_event_text().begins_with("DRIVE-BY") and _hud.event_hint.visible and _hud.event_hint.text == "Get down.", "HUD banner DRIVE-BY with the hint 'Get down.' (%s)" % _hud.get_event_text())
	check(toast_seen("Drive-by. Get down.") and _barked("Get down."), "the floor is told: toast + the Boss")
	check(not Events.is_driveby_firing() and Events.get_driveby_shots() == 0, "the warning: no shots yet")
	Events.tick(b.driveby_warning_sec - 0.1)
	check(not Events.is_driveby_firing() and _shots.is_empty(), "still quiet 0.1 s before the warning ends")
	# Worker 2 stands in the lane with the longest open stretch: a round finds him only when the picker takes that lane.
	var his := _open_lane(lanes)
	var his_lane: Dictionary = lanes[his]
	_put(w2, _at(his_lane["from"], _lane_end(his_lane), 1.2))

	step("drive-by: the gunfire")
	Events.tick(0.1 + Events.DRIVEBY_SHOT_INTERVAL + 0.01)
	check(Events.is_driveby_firing() and _shots.size() == 1 and Events.get_driveby_shots() == 1, "the first round comes one interval into the gunfire (%d)" % _shots.size())
	Events.tick(Events.DRIVEBY_SHOT_INTERVAL * 4.0)
	check(_shots.size() == 5, "one round every %.2f s (%d after four more intervals)" % [Events.DRIVEBY_SHOT_INTERVAL, _shots.size()])
	check(Events.is_event_active(Events.EVENT_DRIVEBY) and _billed.is_empty(), "no bill while the guns go")
	Events.tick(b.driveby_sec)
	await wait_frames(2)
	var rounds := int(floor(b.driveby_sec / Events.DRIVEBY_SHOT_INTERVAL + 0.001))
	check(absi(_shots.size() - rounds) <= 1 and Events.get_driveby_shots() == _shots.size(), "%d rounds in driveby_sec (%d expected)" % [_shots.size(), rounds])
	var from_api := true
	var used: Dictionary = {}
	for s in _shots:
		var index := _lane_index(lanes, s[0], s[1])
		if index < 0:
			from_api = false
		used[index] = true
	check(from_api, "every round went down a Room.get_gunfire_lanes() lane, cut at or before its end")
	check(used.size() >= mini(lanes.size(), 2), "the picker spreads the rounds over the lanes (%d of %d used)" % [used.size(), lanes.size()])
	var downs := 1 if used.has(his) else 0
	check(GameState.get_stat(2, Const.STAT_SHOT) == shot0 + downs, "the worker standing in lane %d went down %d time(s): once when a round came down it, immune after" % [his, downs])
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_DRIVEBY, "event_ended(driveby) when the timer runs out")

	step("drive-by: the bill")
	check(_billed.size() == 1 and int(_billed[0][0]) == b.driveby_fine and int(_billed[0][1]) == b.driveby_fine, "driveby_billed(fine, all of it) (%s)" % [_billed])
	check(GameState.money == 600 - b.driveby_fine, "cash on hand is down by driveby_fine (%d)" % GameState.money)
	check(_barked("Glass and holes: %s. Out of cash on hand." % Story.mayhem_amount_words(b.driveby_fine)), "the Boss says so (%s)" % Story.last_bark)  # M19 readability: two-second copy
	check(toast_seen("Drive-by: $%d out of cash on hand." % b.driveby_fine), "and so does a toast")
	_put(w2, _safe_spots(lanes, 2)[1])
	GameState.server_add_money(12 - GameState.money)
	_billed.clear()
	toasts.clear()
	check(GameState.money == 12 and Events.server_start_event(Events.EVENT_DRIVEBY), "a second drive-by with $12 on hand")
	Events.tick(total + 0.1)
	await wait_frames(2)
	check(_billed.size() == 1 and int(_billed[0][0]) == b.driveby_fine and int(_billed[0][1]) == 12 and GameState.money == 0, "too little cash: all twelve are taken, never below 0 (%s)" % [_billed])
	check(_barked("You had twelve. I took it.") and toast_seen("Drive-by: $12 out of cash on hand."), "the Boss counts what he got (%s)" % Story.last_bark)
	_billed.clear()
	toasts.clear()
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "a third with nothing on hand")
	Events.tick(total + 0.1)
	await wait_frames(2)
	check(_billed.size() == 1 and int(_billed[0][1]) == 0 and GameState.money == 0, "nothing to take")
	check(_barked("Nothing to take. Noted.") and toast_seen("nothing left to take"), "and he notes it (%s)" % Story.last_bark)
	var most_shot := 0
	var most_shots := 0
	for id: int in [1, 2, 3, 4]:
		if GameState.get_stat(id, Const.STAT_SHOT) > most_shots:
			most_shot = id
			most_shots = GameState.get_stat(id, Const.STAT_SHOT)
	var verdicts := Story.get_report_verdicts()
	check(verdicts.has(Story.line("verdict_shot") % Net.get_player_name(most_shot)) and verdicts.has(Story.line("verdict_slips") % Net.get_player_name(2)), "the shift report notes who was shot most and who slipped most (%s)" % [verdicts])
	GameState.server_add_money(600)
	_started.clear()
	_ended.clear()
	_billed.clear()
	_shots.clear()


# --- late-join replay ---------------------------------------------------------------------------------------------------

func _test_replay(b: BalanceConfig) -> void:
	step("late-join replay")
	var total := b.driveby_warning_sec + b.driveby_sec
	var p := {"seconds": total, "warning": b.driveby_warning_sec}
	_started.clear()
	Events._rpc_event_started(Events.EVENT_DRIVEBY, p, total - 1.0)
	check(Events.is_event_active(Events.EVENT_DRIVEBY) and not Events.is_driveby_firing() and _started.size() == 1, "replay 1 s in: active, still the warning")
	Events._rpc_event_started(Events.EVENT_DRIVEBY, p, 3.0)
	check(Events.is_driveby_firing() and Events.get_event_time_left() <= 3.0 and _started.size() == 2, "replay with 3 s left: in the gunfire, time left synced")
	check(_hud.get_event_text().begins_with("DRIVE-BY") and _hud.event_hint.text == "Get down.", "the banner follows the replay")
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _billed.is_empty(), "force-ended: no bill")
	_started.clear()
	Events._rpc_event_started(Events.EVENT_LEAK, {"seconds": b.leak_sec}, 10.0)
	_well._rpc_leak_state(true, true, Well.PUDDLE_SPREAD_SEC * 0.5, false)
	var half := lerpf(Well.PUDDLE_RADIUS_MIN, Well.PUDDLE_RADIUS_MAX, 0.5)
	check(Events.is_event_active(Events.EVENT_LEAK) and Events.get_event_time_left() <= 10.0 and _started.size() == 1, "leak replay: active, time left synced")
	check(_well.is_leaking() and _well.has_puddle() and absf(_well.get_puddle_radius() - half) < 0.05, "the Well's replay: leaking, the puddle at its age (%.2f m)" % _well.get_puddle_radius())
	check(_hud.get_event_text().begins_with("LEAK"), "banner LEAK")
	_well._rpc_leak_state(true, true, Well.PUDDLE_SPREAD_SEC * 0.5, false)
	check(_well.is_leaking() and absf(_well.get_puddle_radius() - half) < 0.05, "the same state twice changes nothing")
	_well._rpc_leak_state(false, true, Well.PUDDLE_SPREAD_SEC * 0.5, true)
	var plate := _well.get_node_or_null(^"Leak/Plate") as Node3D
	check(not _well.is_leaking() and _well.is_patched() and _well.has_puddle() and plate != null and plate.visible, "a joiner after the patch: the plate and the puddle, no jet")
	Events.server_end_event()
	Events.call(&"_mayhem_server_reset")
	await wait_frames(2)
	check(not Events.is_event_active() and not _well.has_puddle() and not _well.is_patched(), "cleaned up")
	_started.clear()
	_ended.clear()
	_resolved.clear()


# --- force end / shift end / reset / menu -------------------------------------------------------------------------------

func _test_resets(b: BalanceConfig) -> void:
	step("force end")
	_resolved.clear()
	check(Events.server_start_event(Events.EVENT_LEAK) and _well.is_leaking(), "leak")
	Events.tick(3.0)
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and not _well.is_leaking() and _well.has_pressure() and not _well.is_patched(), "a force-ended leak: the hole is shut, the pressure stays")
	check(_well.has_puddle() and Events.get_puddle_left() > 0.0 and _resolved.is_empty(), "the puddle dries on its own clock; nobody patched, nothing ran out")
	check(Events.server_start_event(Events.EVENT_LEAK) and _well.is_leaking(), "leak again")

	step("shift end")
	_ended.clear()
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_LEAK, "shift end ends the leak")
	check(not _well.is_leaking() and not _well.has_puddle() and _well.has_pressure() and Events.get_puddle_left() == 0.0, "no leak, no puddle, pressure on")

	step("game reset")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	check(Events.server_start_event(Events.EVENT_LEAK), "leak")
	Events.tick(b.leak_sec + 0.1)
	await wait_frames(2)
	check(not _well.has_pressure() and Events.get_leak_empty_left() > 0.0 and _well.has_puddle(), "it ran out: the tank is empty, the puddle lies there")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(_well.has_pressure() and Events.get_leak_empty_left() == 0.0 and not _well.has_puddle() and not _well.is_leaking(), "game reset: pressure on, no empty-tank clock, no puddle")
	Events.tick(b.leak_empty_sec + 1.0)
	check(_refilled == 1, "and no late 'refilled' after the reset")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "drive-by")
	Events.tick(b.driveby_warning_sec + 1.0)
	check(Events.is_driveby_firing() and Events.get_driveby_shots() >= 5, "the guns go (%d rounds)" % Events.get_driveby_shots())
	_ended.clear()
	_billed.clear()
	var money0 := GameState.money
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_DRIVEBY and _billed.is_empty(), "game reset ends the drive-by without a bill")
	var shots := Events.get_driveby_shots()
	Events.tick(2.0)
	check(Events.get_driveby_shots() == shots, "no more rounds after it")
	check(GameState.money <= money0, "no cash appeared")

	step("return to menu")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_LEAK), "a leak before leaving")
	Events.tick(1.0)
	_ended.clear()
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	check(not Events.is_event_active() and Events.get_event_time_left() == 0.0, "menu: events reset locally")
	check(Events.get_puddle_left() == 0.0 and Events.get_leak_empty_left() == 0.0 and (Events.get(&"_slip_track") as Dictionary).is_empty() and (Events.get(&"_tracers") as Array).is_empty(), "menu: the mayhem state is forgotten")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_LEAK, "event_ended emitted on the way out")


# --- helpers --------------------------------------------------------------------------------------------------------

## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3, height: float = 0.05) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, height, pos.z)))


## Moves a fake worker from `from` to `to` at `speed` in STEP ticks of simulated time (no frames pass meanwhile).
## He first stands at `from` for a few ticks so the jump there is not part of the measured run.
func _dash(p: Player, from: Vector3, to: Vector3, speed: float, height: float = 0.05, settle: int = 10) -> void:
	_put(p, from, height)
	for i in settle:
		Events.tick(STEP)
	var dist := from.distance_to(to)
	var steps := int(ceil(dist / (speed * STEP)))
	for i in steps:
		_put(p, from.move_toward(to, speed * STEP * (i + 1)), height)
		Events.tick(STEP)


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Where a lane stops: its first LAYER_WORLD hit, or its end.
func _lane_end(lane: Dictionary) -> Vector3:
	var space := _world.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(lane["from"], lane["to"], Const.LAYER_WORLD))
	return hit["position"] if not hit.is_empty() else lane["to"]


## The index of the lane with the longest open stretch (flat metres from its start to where it stops).
func _open_lane(lanes: Array) -> int:
	var best := 0
	var open := -1.0
	for i in lanes.size():
		var l: Dictionary = lanes[i]
		var d := _flat(l["from"], _lane_end(l))
		if d > open:
			open = d
			best = i
	return best


## The floor point `metres` down the lane, `side` metres to its right.
func _at(from: Vector3, end: Vector3, metres: float, side: float = 0.0) -> Vector3:
	var d := Vector3(end.x - from.x, 0.0, end.z - from.z).normalized()
	var p := Vector3(from.x, 0.0, from.z) + d * metres + Vector3(-d.z, 0.0, d.x) * side
	return p


## Up to `count` floor points inside the room at least 2 m (flat) from every lane and 1.5 m from each other.
func _safe_spots(lanes: Array, count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var bounds := _room.get_bounds()
	var x := bounds.position.x + 1.0
	while x < bounds.end.x - 0.9 and out.size() < count:
		var z := bounds.position.z + 3.5
		while z < bounds.end.z - 0.9 and out.size() < count:
			var p := Vector3(x, 0.0, z)
			var ok := true
			for l: Dictionary in lanes:
				var near := Events._lane_closest(l["from"], l["to"], p)
				if _flat(near, p) < 2.0:
					ok = false
			for o in out:
				if _flat(o, p) < 1.5:
					ok = false
			if ok:
				out.append(p)
			z += 0.5
		x += 0.5
	return out


## The index of the API lane a shot went down (same start, its end on the lane), -1 when none.
func _lane_index(lanes: Array, from: Vector3, to: Vector3) -> int:
	for i in lanes.size():
		var l: Dictionary = lanes[i]
		var a: Vector3 = l["from"]
		var z: Vector3 = l["to"]
		if a.distance_to(from) > 0.001:
			continue
		var along := (z - a).normalized()
		var off := (to - a) - along * (to - a).dot(along)
		if off.length() < 0.01 and (to - a).dot(along) <= a.distance_to(z) + 0.01:
			return i
	return -1


## True when a Story line containing `text` was shown (or queued as the last bark).
func _barked(text: String) -> bool:
	if Story.last_bark.contains(text) or Story.get_pending_text().contains(text):
		return true
	for t in Story.bark_log:
		if String(t).contains(text):
			return true
	return false
