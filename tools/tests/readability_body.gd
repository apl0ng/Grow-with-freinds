extends "res://tools/tests/qa_base.gd"
## M19 readability suite (readability agent; CONTRACTS "M19", "Readability"; RELEASE.md D1) on a single headless host
## with two fake workers (Net.players + World.server_spawn_player, no owning peer). Event time is advanced with
## Events.tick() in fixed steps; the Boss's walk and the rat's run need real frames, so those two are timed in real time.
##   telegraphs  every one of the fourteen kinds, started as the scheduler starts it (server_start_scheduled: with its
##               tell) and bare (server_start_event: as before M19), with a worker doing the worst thing, timed from the
##               first sign (the event packet: sound + banner) to the first cost. Told: at least 3 s, each pinned. The
##               hostile plant (the twitch to the crop lost, to the first bite), Black Damp (the motes before it ripens),
##               the flamethrower (who broke the glass, a toast). The table is printed as "AUDIT|" lines
##               (tools/tests/readability_audit.md).
##   scheduler   the scheduler and request_event start kinds with their tell.
##   copy        every banner title, hint, toast and Boss line of every disruption: short (two seconds), flat, no "!";
##               every hint names its answer.
##   toasts      three at most, the oldest goes.
##   layout      at 1280x720, a running event + a job + two chips + the centre banner + the GO banner + the final-notice
##               title + three toasts + a prompt + the held item: no two visible blocks overlap, all on screen.
##   report      the shift's ledger (raid, collector, phone, audit, scale), its three dearest lines, on the round-end card,
##               which still fits the screen.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/readability_body.gd --port=7916 --events --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const STEP := 0.05
## RELEASE.md D1.
const MIN_TELL := 3.0
## Where the workers wait out of every reach (the corridor south of the pen, the dock's far corner).
const PARK_ME := Vector3(8.0, 0.05, 6.2)
const PARK_BOB := Vector3(-8.5, 0.05, 14.5)
const PARK_CARA := Vector3(3.5, 0.05, 14.5)
const BOB := 2
const CARA := 3
## Copy limits (two seconds of reading): a banner title, a hint, a toast or a Boss line.
const TITLE_MAX_CHARS := 14
const HINT_MAX_WORDS := 7
const HINT_MAX_CHARS := 34
const LINE_MAX_WORDS := 10
const LINE_MAX_CHARS := 60
## Every hint names the answer: one of these (lower case) is in it.
const ANSWERS: Dictionary = {
	&"inspection": ["hands empty", "keep moving"], &"power_cut": ["breaker"], &"audit": ["deposit"], &"rat": ["chase"],
	&"headcount": ["line", "window"], &"water_off": ["cans"], &"shortage": ["buy"], &"leak": ["hold"],
	&"driveby": ["get down"], &"raid": ["out of sight"], &"sprinklers": ["do not run"], &"collection": ["dock"],
	&"scale": ["hit"], &"phone": ["pick"],
}

var _world: World
var _room: Room
var _hud: HUD
var _me: Player
var _bob: Player
var _cara: Player
var _chute: TurnInStation
var _well: Well
var _started: Array = []
var _bits: Array = []
var _slips: Array = []
var _took: Array = []
var _missed: Array = []
var _audit_rows: Array = []   # [name, before, after, note]


func _run() -> void:
	_label = "readability"
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.worker_slipped.connect(func(p: int) -> void: _slips.append(p))
	Events.collector_took.connect(func(w: StringName, _s: StringName, _where: String) -> void: _took.append(w))
	Events.phone_missed.connect(func(f: int) -> void: _missed.append(f))
	Hostiles.hostile_bit.connect(func(_id: int, p: int) -> void: _bits.append(p))
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	b.write_ups_to_backroom = 99   # every telegraph run writes somebody up

	_test_tables(b)

	step("hosting")
	Game.start_host("Tester", port_arg(7916))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	get_tree().root.size = Vector2i(1280, 720)   # headless windows report 1280x1280
	_world = Game.world
	_room = _world.room
	_hud = _world.get_node_or_null(^"HUD") as HUD
	_me = Game.local_player
	_chute = _room.get_station("TurnInStation") as TurnInStation
	_well = _room.get_station("Well") as Well
	for id in [BOB, CARA]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	await get_tree().physics_frame
	_bob = _world.get_player(BOB)
	_cara = _world.get_player(CARA)
	check(_hud != null and _chute != null and _well != null and _bob != null and _cara != null, "the HUD, the chute, the tank and two fake workers")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	_quiet()
	_park()

	await _test_scheduler(b)
	await _test_telegraphs(b)
	await _test_hostile(b)
	await _test_spores(b)
	await _test_flamethrower(b)
	await _test_copy(b)
	await _test_toasts()
	await _test_layout()
	await _test_report(b)
	_print_audit()
	finish()


# --- tables ---------------------------------------------------------------------------------------------------------

func _test_tables(b: BalanceConfig) -> void:
	step("the tells")
	check(Config.has_arg("events") and Events.are_events_enabled(), "this suite runs with --events")
	var natural := {Events.EVENT_HEADCOUNT: b.headcount_sec, Events.EVENT_RAID: b.raid_warning_sec,
			Events.EVENT_COLLECTION: b.collector_sec, Events.EVENT_PHONE: b.phone_sec}
	var all_ok := true
	for k in Events.KINDS:
		var tell := Events.get_tell_sec(k)
		var warn := float(natural.get(k, 0.0))
		var ok := tell >= MIN_TELL or warn >= MIN_TELL or k == Events.EVENT_SHORTAGE
		if not ok:
			all_ok = false
			print("  (no tell: %s)" % k)
	check(all_ok, "every kind warns %.0f s at least: a tell, its own warning, or (the shortage) it costs nothing" % MIN_TELL)
	var expected := {Events.EVENT_INSPECTION: 3.0, Events.EVENT_POWER_CUT: 3.0, Events.EVENT_AUDIT: 8.0, Events.EVENT_RAT: 3.0,
			Events.EVENT_WATER_OFF: 5.0, Events.EVENT_LEAK: 3.0, Events.EVENT_DRIVEBY: 3.5, Events.EVENT_SPRINKLERS: 3.0,
			Events.EVENT_SCALE: 3.0}
	var table_ok := Events.READ_TELL_SEC.size() == expected.size()
	for k in expected:
		if not is_equal_approx(Events.get_tell_sec(k), float(expected[k])):
			table_ok = false
	check(table_ok, "the tells: inspection 3 / power cut 3 / audit 8 / rat 3 / water off 5 / leak 3 / drive-by 3.5 / sprinklers 3 / scale 3")
	check(Events.get_tell_params(Events.EVENT_PHONE).is_empty() and is_equal_approx(float(Events.get_tell_params(Events.EVENT_AUDIT).get("tell", 0.0)), 8.0),
			"get_tell_params: {} without a tell, {tell} with one")
	check(maxf(b.driveby_warning_sec, Events.get_tell_sec(Events.EVENT_DRIVEBY)) >= 3.5, "a scheduled drive-by warns 3.5 s at least (driveby_warning_sec %.1f, the tell pins 3.5 until the lead raises it)" % b.driveby_warning_sec)


# --- the scheduler ----------------------------------------------------------------------------------------------------

func _test_scheduler(_b: BalanceConfig) -> void:
	step("the scheduler starts kinds with their tell")
	var told := 0
	var bare := 0
	for i in 12:
		_started.clear()
		Events.set(&"_next_in", 0.01)
		Events.tick(STEP)
		if Events.is_event_active() and not _started.is_empty():
			var kind: StringName = _started.back()[0]
			var p: Dictionary = _started.back()[1]
			var want := Events.get_tell_sec(kind)
			if want > 0.0:
				if p.has("tell") and p.has("total") and float(p["tell"]) >= want - 0.001:
					told += 1
				else:
					print("  (scheduled %s without its tell: %s)" % [kind, p])
			elif not p.has("tell"):
				bare += 1
		_end()
	check(told + bare >= 6 and told >= 3, "scheduled kinds carry their tell (%d told, %d with their own warning)" % [told, bare])
	_started.clear()
	Events.request_event(Events.EVENT_SCALE)
	check(Events.is_event_active(Events.EVENT_SCALE) and is_equal_approx(Events.get_event_tell(), 3.0) and Events.is_in_tell(), "request_event starts the scale told (%.1f s)" % Events.get_event_tell())
	_end()
	check(Events.server_start_event(Events.EVENT_SCALE) and Events.get_event_tell() == 0.0 and not _started.back()[1].has("tell") and not _started.back()[1].has("total"),
			"a bare server_start_event has no tell (params %s)" % [_started.back()[1]])
	_end()


# --- telegraphs -------------------------------------------------------------------------------------------------------

func _test_telegraphs(b: BalanceConfig) -> void:
	step("telegraphs: inspection (the Boss walks out at real speed; a worker with a bundle waits at his door, then walks in front of him)")
	var wait_at := Vector3.ZERO
	for point: Vector3 in _room.get_inspection_route():
		if not _room.is_in_booth(point):
			wait_at = point   # the first point of his walk outside the booth
			break
	for told: bool in [false, true]:
		await _boss_home()
		var bundle := _bundle(&"golden", Vector3.ZERO, BOB)
		_put(_bob, wait_at)
		var ups0 := GameState.get_stat(BOB, Const.STAT_WRITE_UPS)
		var boss := Events.call(&"_boss") as ShopkeeperNPC
		# The worst a worker can do: wait outside the booth with a bundle, then walk along two metres in front of him.
		var t := await _real(Events.EVENT_INSPECTION, told, func() -> bool:
			if boss != null and not _room.is_in_booth(boss.global_position):
				_put(_bob, boss.global_position + boss.get_facing() * 2.0)
			return GameState.get_stat(BOB, Const.STAT_WRITE_UPS) > ups0, 12.0)
		_row_pair("inspection", told, t)
		if told:
			check(t >= MIN_TELL - 0.001 and t <= MIN_TELL + 0.6, "told: the first write-up %.2f s after the alarm (3.0 .. 3.6)" % t)
		else:
			check(t >= 0.0, "bare: written up %.2f s after the alarm (before M19)" % t)
		if is_instance_valid(bundle):
			_world.items.server_despawn_item(bundle)
		_end()
		_park()
		await wait_frames(2)

	step("telegraphs: power cut (the lights flicker, then the mains go)")
	for told: bool in [false, true]:
		var flicker_seen := [false]
		var t := _sim(Events.EVENT_POWER_CUT, told, func() -> bool:
			if Events.is_flickering():
				flicker_seen[0] = true
			return not Events.is_power_on(), 10.0)
		_row_pair("power_cut", told, t)
		if told:
			check(is_equal_approx(t, 3.0) and flicker_seen[0], "told: the mains go %.2f s after the alarm; the lights flickered first" % t)
			var fuse := _room.get_station("FuseBox") as FuseBox
			check(fuse != null and fuse.is_tripped() and Events.is_event_active(Events.EVENT_POWER_CUT), "the breaker is tripped now: the answer works")
		else:
			check(t == 0.0, "bare: the mains go at once (before M19)")
		_end()

	step("telegraphs: audit (he counts what is still owed after the countdown)")
	GameState.server_add_money(1000 - GameState.money)
	for told: bool in [false, true]:
		var q0 := GameState.quota
		var t := _sim(Events.EVENT_AUDIT, told, func() -> bool: return GameState.quota > q0, 12.0)
		_row_pair("audit", told, t)
		if told:
			var owed := q0 - GameState.round_sales
			check(is_equal_approx(t, 8.0) and GameState.quota == q0 + int(round(owed * b.audit_raise_fraction)), "told: counted %.2f s after the alarm, +$%d (10%% of $%d owed)" % [t, GameState.quota - q0, owed])
		else:
			check(t == 0.0, "bare: the payment goes up at once (before M19)")
		_end()
	# The answer: a deposit during the countdown lowers what he puts on.
	var q1 := GameState.quota
	check(Events.server_start_scheduled(Events.EVENT_AUDIT), "a told audit again")
	_hud_sync()
	check(_hud.get_event_text().begins_with("AUDIT 0:08") and _hud.event_hint.text == HUD.TEXT_READ_AUDIT_HINT, "the banner counts down to the count: '%s' / '%s'" % [_hud.get_event_text(), _hud.event_hint.text])
	GameState.server_add_sale(200, 1)
	_tick(8.1)
	var owed_after := q1 - GameState.round_sales
	check(GameState.quota == q1 + int(round(owed_after * b.audit_raise_fraction)) and GameState.quota - q1 < int(round(q1 * b.audit_raise_fraction)),
			"a deposit during the countdown: +$%d instead of +$%d" % [GameState.quota - q1, int(round(q1 * b.audit_raise_fraction))])
	_hud_sync()
	check(_hud.event_hint.text == HUD.TEXT_READ_AUDIT_DONE % HUD.format_money(GameState.quota - q1) and _hud.get_event_text() == "AUDIT", "after the count: '%s' / '%s'" % [_hud.get_event_text(), _hud.event_hint.text])
	_end()

	step("telegraphs: rat (it runs to the nearest tray at real speed)")
	var nearest := _nearest_rat_plot()
	var run := _rat_run_sec(nearest)
	for told: bool in [false, true]:
		_reset_plots()
		nearest.server_plant(&"purple")
		nearest.stage = GrowPlot.Stage.VEGETATIVE
		nearest.stage_progress = 0.6
		nearest.water = 0.0   # dry: it does not grow, only the rat moves the number
		var t := await _real(Events.EVENT_RAT, told, func() -> bool: return nearest.stage_progress < 0.6 - 0.0001, 8.0)
		_row_pair("rat", told, t)
		if told:
			check(t >= MIN_TELL - 0.001 and t <= MIN_TELL + 0.3, "told: it starts eating %.2f s after the alarm (it was there after %.2f s)" % [t, run])
		else:
			check(t >= 0.0 and t < MIN_TELL, "bare: it ate %.2f s after the alarm (its run takes %.2f s; before M19)" % [t, run])
		_end()
		await wait_frames(2)
	nearest.server_reset()

	step("telegraphs: head count (the count at the end)")
	var spot := _room.get_headcount_spot()
	_put(_cara, spot)
	_me.global_position = Vector3(spot.x, 0.05, spot.z + 0.5)
	_put(_bob, PARK_BOB)
	var absent0 := GameState.get_stat(BOB, Const.STAT_WRITE_UPS)
	var th := _sim(Events.EVENT_HEADCOUNT, true, func() -> bool: return GameState.get_stat(BOB, Const.STAT_WRITE_UPS) > absent0, 20.0)
	_audit_rows.append(["headcount", th, th, "no tell needed"])
	check(_near(th, b.headcount_sec), "the absent worker is written up %.2f s after the call (headcount_sec)" % th)
	_end()
	_park()

	step("telegraphs: water off (the pipes knock; the tank still fills cans)")
	for told: bool in [false, true]:
		var t := _sim(Events.EVENT_WATER_OFF, told, func() -> bool: return not _well.has_pressure(), 10.0)
		_row_pair("water_off", told, t)
		if told:
			check(is_equal_approx(t, 5.0), "told: no pressure %.2f s after the alarm" % t)
		else:
			check(t == 0.0, "bare: no pressure at once (before M19)")
		_end()
	check(Events.server_start_scheduled(Events.EVENT_WATER_OFF), "told water off again")
	_hud_sync()
	check(_well.has_pressure() and _hud.event_hint.text == HUD.TEXT_READ_WATER_TELL_HINT, "during the tell the tank fills cans and the hint says so ('%s')" % _hud.event_hint.text)
	_tick(5.1)
	_hud_sync()
	check(not _well.has_pressure() and _hud.event_hint.text == HUD.TEXT_EVENT_WATER_OFF_HINT, "then no pressure: '%s'" % _hud.event_hint.text)
	_end()

	step("telegraphs: shortage (a refusal; nothing is lost)")
	var money0 := GameState.money
	check(Events.server_start_scheduled(Events.EVENT_SHORTAGE), "a shortage")
	_tick(b.shortage_sec + 0.5)
	check(GameState.money == money0 and not Events.is_event_active(Events.EVENT_SHORTAGE), "it ran its course; cash on hand untouched")
	_audit_rows.append(["shortage", -1.0, -1.0, "costs nothing"])
	_end()

	step("telegraphs: leak (a worker sprints through the fresh puddle; the tank runs empty)")
	for told: bool in [false, true]:
		await _unstun(_bob)
		_slips.clear()
		var c := _well.get_puddle_center()
		var flip := [1.0]
		var t := _sim(Events.EVENT_LEAK, told, func() -> bool:
			flip[0] = -flip[0]
			_put(_bob, c + Vector3(0.175 * flip[0], 0.0, 0.0))
			return _slips.has(BOB), 8.0)
		_row_pair("leak (a slip)", told, t)
		if told:
			check(t >= MIN_TELL - 0.001 and t <= MIN_TELL + 0.35, "told: the first slip %.2f s after the alarm" % t)
		else:
			check(t >= 0.0 and t < 1.0, "bare: the first slip %.2f s after the alarm (before M19)" % t)
		_put(_bob, PARK_BOB)
		_end()
		_tick(Config.balance.puddle_sec + 1.0)
	var tl := _sim(Events.EVENT_LEAK, true, func() -> bool: return not _well.has_pressure(), b.leak_sec + 5.0)
	_audit_rows.append(["leak (the tank)", tl, tl, "unpatched"])
	check(_near(tl, b.leak_sec), "unpatched, the tank is empty %.2f s after the alarm (leak_sec)" % tl)
	_end()
	_tick(b.leak_empty_sec + b.puddle_sec + 1.0)

	step("telegraphs: drive-by (the first round)")
	for told: bool in [false, true]:
		var t := _sim(Events.EVENT_DRIVEBY, told, func() -> bool: return Events.get_driveby_shots() > 0, 10.0)
		_row_pair("driveby", told, t)
		var warn := maxf(3.5, b.driveby_warning_sec) if told else b.driveby_warning_sec
		check(t >= warn - 0.001 and t <= warn + Events.DRIVEBY_SHOT_INTERVAL + STEP + 0.001, "%s: the first round %.2f s after the tyres (the warning %.1f s, then a round every %.2f s)" % ["told" if told else "bare (before M19)", t, warn, Events.DRIVEBY_SHOT_INTERVAL])
		_end()
	_reset_plots()

	step("telegraphs: raid (the first look)")
	var door_eye: Vector3 = _room.get_raid_points()[0]
	for told: bool in [false, true]:
		var seen := _bundle(&"golden", Vector3(door_eye.x, 0.3, door_eye.z - 1.5))   # in plain sight of the first look
		await _settle()
		var t := _sim(Events.EVENT_RAID, told, func() -> bool: return not is_instance_valid(seen) or seen.is_queued_for_deletion(), 30.0)
		_row_pair("raid", told, t)
		check(_near(t, b.raid_warning_sec), "%s: the first bundle goes %.2f s after the sirens (raid_warning_sec)" % ["told" if told else "bare", t])
		_end()
		_despawn_products()

	step("telegraphs: sprinklers (a worker sprints on the wet floor)")
	for told: bool in [false, true]:
		await _unstun(_bob)
		_slips.clear()
		var flip := [1.0]
		var t := _sim(Events.EVENT_SPRINKLERS, told, func() -> bool:
			flip[0] = -flip[0]
			_put(_bob, Vector3(2.0 + 0.175 * flip[0], 0.0, 2.0))
			return _slips.has(BOB), 8.0)
		_row_pair("sprinklers", told, t)
		if told:
			check(t >= MIN_TELL - 0.001 and t <= MIN_TELL + 0.35, "told: the first slip %.2f s after the alarm" % t)
		else:
			check(t >= 0.0 and t < 1.0, "bare: the first slip %.2f s after the alarm (before M19)" % t)
		_put(_bob, PARK_BOB)
		_end()
		_tick(b.sprinkler_wet_sec + 1.0)

	step("telegraphs: collection (unpaid, he takes a bundle)")
	for told: bool in [false, true]:
		_took.clear()
		var lying := _bundle(&"budget", Vector3(-3.0, 0.3, 3.0))
		await _settle()
		var t := _sim(Events.EVENT_COLLECTION, told, func() -> bool: return not _took.is_empty(), 30.0)
		_row_pair("collection", told, t)
		check(_near(t, b.collector_sec), "%s: he takes it %.2f s after the knock (collector_sec)" % ["told" if told else "bare", t])
		if is_instance_valid(lying):
			_world.items.server_despawn_item(lying)
		_end()

	step("telegraphs: scale (deposits pay less)")
	for told: bool in [false, true]:
		var t := _sim(Events.EVENT_SCALE, told, func() -> bool: return Events.get_scale_factor() < 1.0, 10.0)
		_row_pair("scale", told, t)
		if told:
			check(is_equal_approx(t, 3.0), "told: it reads light %.2f s after the alarm" % t)
		else:
			check(t == 0.0, "bare: light at once (before M19)")
		_end()
	var full_bundle := _bundle(&"golden", Vector3.ZERO, 1)
	check(Events.server_start_scheduled(Events.EVENT_SCALE), "told scale again")
	check(_chute.get_sale_value(full_bundle) == TurnInStation.compute_sale_value(Config.balance.get_seed(&"golden"), 1, GameState.get_sale_multiplier()), "during the tell a deposit pays in full")
	_end()
	_world.items.server_despawn_item(full_bundle)

	step("telegraphs: phone (nobody answers)")
	GameState.server_add_money(1000 - GameState.money)
	for told: bool in [false, true]:
		_missed.clear()
		var t := _sim(Events.EVENT_PHONE, told, func() -> bool: return not _missed.is_empty(), 20.0)
		_row_pair("phone", told, t)
		check(_near(t, b.phone_sec), "%s: the fine %.2f s after the first ring (phone_sec)" % ["told" if told else "bare", t])
		_end()


## The hostile plant: the twitch (sign) to the crop lost and to the first bite.
func _test_hostile(b: BalanceConfig) -> void:
	step("the hostile plant: the twitch, the uproot, the first bite")
	await _unstun(_bob)
	_reset_plots()
	var ns: SeedDef = b.get_seed(&"nightshift")
	var chance := ns.mutation_chance
	ns.mutation_chance = 1.0
	var p := _plot(1)
	p.server_plant(&"nightshift")
	p.server_water(1.0)
	p.stage = GrowPlot.Stage.READY
	_put(_bob, p.global_position + Vector3(0.0, 0.0, 1.5))
	toasts.clear()
	_bits.clear()
	Hostiles.tick(STEP)
	check(p.is_turning(), "a ready Night Shift turns: it twitches from now on (the sign)")
	check(toast_seen("GrowPlot 1 is moving. Harvest it."), "the toast names the answer: 'GrowPlot 1 is moving. Harvest it.'")
	var t := 0.0
	var lost := -1.0
	var bite := -1.0
	while t < 30.0 and bite < 0.0:
		Hostiles.tick(STEP)
		t += STEP
		if lost < 0.0 and p.stage == GrowPlot.Stage.EMPTY:
			lost = t
		if bite < 0.0 and not _bits.is_empty():
			bite = t
	ns.mutation_chance = chance
	check(absf(lost - b.mutation_warning_sec) <= STEP + 0.001, "the crop is lost %.2f s after the twitch began (mutation_warning_sec)" % lost)
	check(bite >= b.mutation_warning_sec + 2.0 - 0.001, "the first bite %.2f s after the twitch began (it roots first)" % bite)
	check(toast_seen("Something came out of GrowPlot 1. Burn it."), "the spawn toast names the answer")
	_audit_rows.append(["hostile (the crop)", lost, lost, "harvest it while it twitches"])
	_audit_rows.append(["hostile (a bite)", bite, bite, "keep clear / burn it"])
	Hostiles.server_despawn_all()
	_put(_bob, PARK_BOB)
	await wait_frames(2)
	_reset_plots()


## Black Damp: the motes show before the tray can puff.
func _test_spores(b: BalanceConfig) -> void:
	step("Black Damp: the motes start before it is ripe")
	var p := _plot(3)
	p.server_reset()
	p.server_plant(&"damp")
	p.water = 1.0
	p.stage = GrowPlot.Stage.FLOWERING
	var duration := p.get_stage_duration(GrowPlot.Stage.FLOWERING)
	p.stage_progress = 1.0 - 6.0 / duration * GameState.get_growth_speed_multiplier()
	toasts.clear()
	check(p.get_spore_tell() == null or not p.get_spore_tell().visible, "six seconds out: no motes yet")
	var t := 0.0
	var told_at := -1.0
	var ripe_at := -1.0
	while t < 12.0 and ripe_at < 0.0:
		p.water = 1.0
		p.tick(STEP)
		t += STEP
		if told_at < 0.0 and p.get_spore_tell() != null and p.get_spore_tell().visible:
			told_at = t
		if p.stage == GrowPlot.Stage.READY:
			ripe_at = t
	var lead := ripe_at - told_at
	check(told_at >= 0.0 and ripe_at > 0.0 and lead >= MIN_TELL and absf(lead - GrowPlot.READ_SPORE_PRE_TELL_SEC) <= STEP + 0.001,
			"the motes drift %.2f s before it ripens (nothing puffs before READY)" % lead)
	check(p.is_spore_ripe() and p.get_spore_tell().visible, "ripe: the motes stay")
	check(toast_seen("Black Damp is ripening. Crouch near it."), "the toast names the answer, once a shift")
	_audit_rows.append(["spores", 0.0, lead, "the motes before it ripens"])
	p.server_reset()
	p.server_plant(&"damp")
	p.water = 1.0
	p.stage = GrowPlot.Stage.FLOWERING
	p.stage_progress = 0.5
	toasts.clear()
	p.stage_progress = 0.9995
	check(p.read_is_spore_ripening() and p.get_spore_tell().visible and not toast_seen("ripening"), "a second tray this shift: its motes, no second toast")
	p.server_reset()


## The flamethrower: who broke the glass, on every peer's screen.
func _test_flamethrower(b: BalanceConfig) -> void:
	step("the flamethrower: the glass toast")
	var cabinet := _room.get_node_or_null(^"Stations/EmergencyCabinet") as EmergencyCabinet
	GameState.server_add_money(1000 - GameState.money)
	toasts.clear()
	_me.global_position = cabinet.global_position + cabinet.global_basis.z * 1.2 - Vector3.UP * cabinet.global_position.y + Vector3.UP * 0.05
	check(cabinet != null and cabinet.server_break(_me), "the glass breaks")
	await wait_frames(2)
	check(toast_seen("Tester broke the glass. Flamethrower out."), "the floor is told who has it (%s)" % [toasts])
	var ft := _world.items.get_held_by(1)
	if ft != null:
		_world.items.server_despawn_item(ft)
	cabinet.server_restock()
	_audit_rows.append(["flamethrower", 0.0, 0.0, "player-made (D3): the glass, the toast, the item in hand"])
	_me.global_position = PARK_ME
	await wait_frames(2)


# --- copy -------------------------------------------------------------------------------------------------------------

func _test_copy(b: BalanceConfig) -> void:
	step("copy: titles and hints (every kind, as the HUD shows them)")
	var hints_ok := true
	var titles_ok := true
	for k in Events.KINDS:
		_started.clear()
		var ok := Events.server_start_scheduled(k)
		if not ok and k == Events.EVENT_RAT:
			_plot(5).server_plant(&"budget")
			_plot(5).stage = GrowPlot.Stage.SEEDLING
			ok = Events.server_start_scheduled(k)
		if not ok:
			check(false, "%s could not start" % k)
			continue
		_hud_sync()
		var title := _hud.event_label.text.get_slice(" 0:", 0).get_slice(" 1:", 0)
		var hint := _hud.event_hint.text if _hud.event_hint.visible else ""
		if title.length() > TITLE_MAX_CHARS or title.contains("!"):
			titles_ok = false
			print("  (title too long: %s '%s')" % [k, title])
		var named := false
		for word: String in ANSWERS.get(k, []):
			if hint.to_lower().contains(word):
				named = true
		if not named or _words(hint) > HINT_MAX_WORDS or hint.length() > HINT_MAX_CHARS or hint.contains("!"):
			hints_ok = false
			print("  (hint: %s '%s' words %d chars %d named %s)" % [k, hint, _words(hint), hint.length(), named])
		print("  COPY| %s | %s | %s" % [k, title, hint])
		_end()
	_reset_plots()
	check(titles_ok, "every banner title is %d characters at most, no '!'" % TITLE_MAX_CHARS)
	check(hints_ok, "every hint names its answer in %d words / %d characters at most" % [HINT_MAX_WORDS, HINT_MAX_CHARS])

	step("copy: toasts and Boss lines (two seconds each)")
	var texts := PackedStringArray()
	var keys := ["inspection_start", "inspection_end", "skimming", "loitering", "power_cut", "power_back",
		"read_audit_start", "audit", "read_toast_audit", "read_audit_none", "read_toast_audit_none", "rat",
		"headcount", "headcount_end", "absent", "read_water_warn", "water_off", "water_back", "shortage", "shortage_end",
		"leak", "leak_patched", "leak_empty", "tank_refilled", "slipped", "toast_leak", "toast_leak_patched",
		"toast_leak_empty", "toast_tank_refilled", "driveby", "driveby_hit", "toast_driveby", "toast_driveby_bill",
		"toast_driveby_bill_broke", "raid", "raid_caught", "raid_clean", "toast_raid", "toast_raid_look", "sprinklers",
		"sprinklers_end", "toast_sprinklers", "toast_sprinklers_end", "toast_floor_dry", "collection", "collector_ask",
		"collector_paid", "toast_collection", "toast_collector_paid", "scale", "scale_fixed", "scale_back", "toast_scale",
		"toast_scale_fixed", "toast_scale_fixed_nobody", "toast_scale_back", "phone", "phone_favor", "phone_wrong",
		"toast_phone", "toast_phone_favor", "toast_favor_over", "toast_phone_missed", "toast_phone_missed_broke",
		"plot_turning", "hostile_spawned", "hostile_eating", "hostile_ate", "hostile_bit", "hostile_died",
		"spores_first", "read_toast_ripening", "glass_broke", "on_fire", "plot_burnt", "read_toast_glass",
		"counted_fine", "counted_broke"]
	var missing := PackedStringArray()
	for key: String in keys:
		var raw := Story.line(key)
		if raw == "":
			missing.append(key)
			continue
		texts.append(_fill(raw, String(FILLERS.get(key, "Dale"))))
	check(missing.is_empty(), "every listed line exists (%s)" % ", ".join(missing))
	texts.append(Story.read_with_answer("plot_turning", Story.line("plot_turning") % "GrowPlot 10"))
	texts.append(Story.read_with_answer("hostile_spawned", Story.line("hostile_spawned") % "GrowPlot 10"))
	texts.append(Story.line("toast_phone_taken") % ["Dale", Story.line("toast_phone_favor") % [20, 60]])
	texts.append(Story.line("toast_phone_taken") % ["Dale", Story.mayhem3_tip_line(&"sprinklers")])
	for pair: Array in [[30, 30], [30, 12], [30, 0]]:
		texts.append(Story.mayhem_bill_line(pair[0], pair[1]))
		texts.append(Story.mayhem3_missed_line(pair[0], pair[1]))
	texts.append(Story.mayhem2_raid_line(3, PackedStringArray(["Dale"])))
	texts.append(Story.mayhem2_raid_line(2, PackedStringArray(["Dale", "Kim"])))
	texts.append(Story.mayhem2_collector_line(Events.COLLECT_BUNDLE, &"golden", ""))
	texts.append(Story.mayhem2_collector_line(Events.COLLECT_TRAY, &"golden", "GrowPlot10"))
	texts.append(Story.mayhem2_collector_line(Events.COLLECT_NOTHING, &"", ""))
	texts.append(GrowPlot.get_counted_toast("Golden Kush", 25))
	var long := PackedStringArray()
	for text in texts:
		if _words(text) > LINE_MAX_WORDS or text.length() > LINE_MAX_CHARS or text.contains("!"):
			long.append("'%s' (%d words, %d chars)" % [text, _words(text), text.length()])
	check(long.is_empty(), "%d toasts and Boss lines: %d words / %d characters at most, no '!' %s" % [texts.size(), LINE_MAX_WORDS, LINE_MAX_CHARS, long])
	check(Story.mayhem_bill_line(30, 30) == "Glass and holes: thirty. Out of cash on hand." and Story.mayhem3_missed_line(30, 12) == "He called. Nobody picked up. Thirty. I took twelve."
			and Story.line("toast_scale") % [15, "F"] == "The scale reads light: 15% less. Hit the chute (F).", "the three lines that were too long are short now")

	step("copy: the report's lines")
	var all_sources := {}
	for s: String in Events.COST_SOURCES:
		all_sources[s] = {"money": 40, "bundles": 2, "plants": 2, "setback": 2, "value": 100, "strain": "nightshift"}
	var lines := Story.get_cost_lines(all_sources, 99)
	var report_ok := lines.size() == Events.COST_SOURCES.size()
	for text in lines:
		if _words(text) > LINE_MAX_WORDS or text.length() > LINE_MAX_CHARS or text.contains("!"):
			report_ok = false
			print("  (report line too long: '%s')" % text)
	check(report_ok, "a line per source, each %d words at most (%d)" % [LINE_MAX_WORDS, lines.size()])
	var one := {"money": 0, "bundles": 1, "plants": 0, "setback": 0, "value": 125, "strain": "golden"}
	check(Story.read_cost_line(Events.COST_RAID, one) == "The raid took a bundle of Golden Kush. $125.", "one bundle: '%s'" % Story.read_cost_line(Events.COST_RAID, one))
	check(Story.read_cost_line(Events.COST_RAID, {"bundles": 2, "value": 360, "strain": Events.COST_MIXED}) == "The raid took two bundles. $360.", "two of mixed strains: '%s'" % Story.read_cost_line(Events.COST_RAID, {"bundles": 2, "value": 360, "strain": Events.COST_MIXED}))
	check(Story.read_cost_line(Events.COST_COLLECTION, {"money": 40, "value": 40}) == "The collector took $40.", "the collector paid")
	check(Story.read_cost_line(Events.COST_RAT, {"setback": 1, "value": 9, "strain": "purple"}) == "The rat ate into a tray of Purple Haze.", "the rat: '%s'" % Story.read_cost_line(Events.COST_RAT, {"setback": 1, "value": 9, "strain": "purple"}))
	check(Story.read_cost_line(Events.COST_WALKED, {"plants": 2, "value": 400, "strain": "nightshift"}) == "Two trays of Night Shift walked off.", "walked off: '%s'" % Story.read_cost_line(Events.COST_WALKED, {"plants": 2, "value": 400, "strain": "nightshift"}))
	check(Story.read_cost_line(Events.COST_DRIVEBY, {"money": 30, "setback": 2, "value": 60}) == "The drive-by cost $30. Two trays set back.", "the drive-by")
	check(Story.read_cost_line(Events.COST_PHONE, {}) == "", "nothing booked, nothing said")
	var ranked := Story.get_cost_lines({"phone": {"money": 30, "value": 30}, "raid": {"bundles": 1, "value": 125, "strain": "golden"},
			"audit": {"money": 35, "value": 35}, "collection": {"money": 40, "value": 40}})
	check(ranked == PackedStringArray(["The raid took a bundle of Golden Kush. $125.", "The collector took $40.", "The audit put $35 on the payment."]),
			"three at most, the dearest first: %s" % [ranked])


# --- toasts and layout ------------------------------------------------------------------------------------------------

func _test_toasts() -> void:
	step("toasts: three at most, the oldest goes")
	await _clear_toasts()
	check(HUD.MAX_TOASTS == 3, "MAX_TOASTS is 3")
	for i in 5:
		_hud.show_toast("Toast number %d." % i, &"info")
	await wait_frames(1)
	var live := _live_texts()
	check(_hud.get_toast_count() == 3 and live == PackedStringArray(["Toast number 2.", "Toast number 3.", "Toast number 4."]), "the newest three stay: %s" % [live])
	await _clear_toasts()


func _test_layout() -> void:
	step("layout at 1280x720: the busiest moments")
	check(get_viewport().get_visible_rect().size == Vector2(1280, 720), "logical viewport 1280x720 (%s)" % get_viewport().get_visible_rect().size)
	GameState.server_set_contract(&"cured")
	await wait_frames(2)
	var chips := _hud.get_condition_chips() as HBoxContainer
	for title: String in ["Mandatory overtime", "Inspection week"]:
		chips.add_child(_hud._replay_make_chip(title))
	chips.visible = true
	var final_title := _hud.quota_panel.get_node_or_null(^"VBox/QuotaTitle") as Label
	final_title.text = HUD.TEXT_FINAL_TITLE
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, _me.global_position, 1)
	var fake := FakePrompt.new()
	add_child(fake)
	_hud.set_prompt_source(fake)
	fake.prompt_changed.emit("Deposit Golden Kush x3 (+$360)", true)
	# The centre banner only shows between shifts (no event then) and the GO banner only in a shift's first seconds:
	# each is measured with everything else that can be up at the same time.
	await _measure_blocks("between shifts: the centre banner, a job, two chips, the final notice, three toasts",
			false, ["Banner", "ConditionChips", "QuotaPanel/CareerBox", "QuotaPanel/QuotaTitle", "Toast2", "PromptPanel", "HeldPanel"])
	check(Events.server_start_scheduled(Events.EVENT_RAID), "a raid runs")
	await _measure_blocks("a shift: a running raid, the GO banner, a job, two chips, the final notice, three toasts",
			true, ["EventPanel", "GoBanner", "ConditionChips", "QuotaPanel/CareerBox", "QuotaPanel/QuotaTitle", "Toast2", "PromptPanel", "HeldPanel"])
	var go := _hud.go_banner.get_global_rect()
	var column := _hud.get_node(^"%QuotaColumn") as Control
	check(go.position.y >= column.get_global_rect().end.y, "the GO banner sits under the payment column (%s / column bottom %.0f)" % [go, column.get_global_rect().end.y])
	# Back to normal.
	_end()
	_hud.set_prompt_source(null)
	fake.queue_free()
	_world.items.server_despawn_item(can)
	_hud.go_banner.visible = false
	_hud.banner.visible = false
	final_title.text = HUD.TEXT_PAYMENT_TITLE
	_hud._replay_refresh_chips()
	GameState.server_set_contract(&"")
	await _clear_toasts()


## Shows the centre banner (`playing` false) or the GO banner (true) with three long toasts, then checks that no two
## visible blocks overlap and that every one is on screen.
func _measure_blocks(what: String, playing: bool, want: Array) -> void:
	await _clear_toasts()
	_hud.banner.visible = not playing
	_hud.go_banner.text = HUD.TEXT_GO % 6
	_hud.go_banner.modulate.a = 1.0
	_hud.go_banner.visible = playing
	for t: String in ["Collection. He wants $40. He is on the dock.", "Sprinklers. Everything is watered. Do not run.",
			"The scale reads light: 15% less. Hit the chute (F).", "Worker 2 took the call. Seeds 20% off for 60 seconds."]:
		_hud.show_toast(t, &"error")
	for i in 6:
		await get_tree().process_frame
	await wait_sec(0.4)   # pop-ins done
	var blocks := _hud.get_read_blocks()
	var names := PackedStringArray()
	for blk: Array in blocks:
		names.append(String(blk[0]))
	print("  blocks (%s): %s" % ["shift" if playing else "between shifts", ", ".join(names)])
	var missing := PackedStringArray()
	for w: String in want:
		if not names.has(w):
			missing.append(w)
	check(missing.is_empty(), "%s: all measured (missing %s)" % [what, missing])
	var vp := get_viewport().get_visible_rect()
	var overlaps := PackedStringArray()
	var off := PackedStringArray()
	for i in blocks.size():
		var a: Array = blocks[i]
		if not vp.encloses(a[1] as Rect2):
			off.append("%s %s" % [a[0], a[1]])
		for j in range(i + 1, blocks.size()):
			var c: Array = blocks[j]
			var na: Node = a[2]
			var nc: Node = c[2]
			if na.is_ancestor_of(nc) or nc.is_ancestor_of(na):
				continue
			if (a[1] as Rect2).intersects(c[1] as Rect2):
				overlaps.append("%s %s x %s %s" % [a[0], a[1], c[0], c[1]])
	check(overlaps.is_empty(), "%s: no two of the %d visible blocks overlap %s" % [what, blocks.size(), overlaps])
	check(off.is_empty(), "%s: every block on screen %s" % [what, off])
	check(_hud.get_toast_count() == 3, "three toasts (%d)" % _hud.get_toast_count())


# --- the report -------------------------------------------------------------------------------------------------------

func _test_report(b: BalanceConfig) -> void:
	step("the ledger: a fresh shift")
	GameState.server_reset_game()
	await wait_frames(2)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	_quiet()
	_park()
	check(Events.get_shift_costs().is_empty() and Story.get_shift_cost_lines().is_empty(), "a new shift: the ledger is empty")
	GameState.server_add_money(1000 - GameState.money)
	var golden: SeedDef = b.get_seed(&"golden")
	var one := TurnInStation.compute_sale_value(golden, 1, GameState.get_sale_multiplier())

	step("the ledger: a raid takes two bundles")
	var points := _room.get_raid_points()
	var mid: Vector3 = points[2] if points.size() > 2 else Vector3.ZERO
	_bundle(&"golden", Vector3(mid.x + 1.0, 0.3, mid.z))
	_bundle(&"golden", Vector3(mid.x - 1.0, 0.3, mid.z + 0.5))
	await _settle()
	check(Events.server_start_event(Events.EVENT_RAID), "a raid")
	var r := Events.server_raid_sweep(2)
	check((r["taken"] as Array).size() == 2, "the middle look took both (%s)" % [r])
	_end()
	var raid: Dictionary = Events.get_shift_costs().get(Events.COST_RAID, {})
	check(int(raid.get("bundles", 0)) == 2 and int(raid.get("value", 0)) == 2 * one and String(raid.get("strain", "")) == "golden", "booked: two bundles of Golden Kush, $%d (%s)" % [2 * one, raid])

	step("the ledger: the collector is paid, the phone rings out, the audit counts, the scale shaves a deposit")
	check(Events.server_start_event(Events.EVENT_COLLECTION) and Events.server_pay_collector(1), "the collector is paid")
	_end()
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	_tick(b.phone_sec + 0.1)
	_end()
	var q := GameState.quota
	var owed := q - GameState.round_sales
	check(Events.server_start_scheduled(Events.EVENT_AUDIT), "a told audit")
	_tick(8.05)
	var raise := GameState.quota - q
	check(raise == int(round(owed * b.audit_raise_fraction)), "the audit put $%d on" % raise)
	_end()
	check(Events.server_start_scheduled(Events.EVENT_SCALE), "a told scale")
	_tick(3.05)
	var light := _bundle(&"golden", Vector3.ZERO, 1)
	var paid := _chute.get_sale_value(light)
	check(_chute.server_sell_item(light, 1), "a deposit on the light scale ($%d)" % paid)
	_end()
	var costs := Events.get_shift_costs()
	var shaved := int((costs.get(Events.COST_SCALE, {}) as Dictionary).get("money", 0))
	check(shaved == int(round(float(paid) / (1.0 - b.scale_cut))) - paid and shaved > 0, "the scale shaved $%d" % shaved)
	check(int((costs.get(Events.COST_COLLECTION, {}) as Dictionary).get("money", 0)) == b.collector_fee
			and int((costs.get(Events.COST_PHONE, {}) as Dictionary).get("money", 0)) == b.phone_fine
			and int((costs.get(Events.COST_AUDIT, {}) as Dictionary).get("money", 0)) == raise, "booked: the fee, the fine, the raise (%s)" % [costs])
	var want := Story.get_cost_lines(costs)
	var ranked: Array = [[2 * one, 0, "The raid took two bundles of Golden Kush. %s." % HUD.format_money(2 * one)],
			[b.collector_fee, 1, "The collector took %s." % HUD.format_money(b.collector_fee)],
			[raise, 3, "The audit put %s on the payment." % HUD.format_money(raise)],
			[shaved, 4, "The scale shaved %s off deposits." % HUD.format_money(shaved)],
			[b.phone_fine, 6, "Nobody took the call. %s." % HUD.format_money(b.phone_fine)]]
	ranked.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0] or (x[0] == y[0] and x[1] < y[1]))
	var expect_lines := PackedStringArray([ranked[0][2], ranked[1][2], ranked[2][2]])
	check(want == expect_lines, "the three dearest lines: %s" % [want])
	print("  LEDGER| %s" % [costs])

	step("the ledger: write-ups, a lost plant")
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "a head count")
	_put(_bob, PARK_BOB)
	_tick(b.headcount_sec + 0.1)
	_end()
	var hc: Dictionary = Events.get_shift_costs().get(Events.COST_HEADCOUNT, {})
	check(int(hc.get("money", 0)) >= b.write_up_fine, "the head count's fine is booked (%s)" % [hc])
	var p := _plot(2)
	p.server_plant(&"golden")
	p.stage = GrowPlot.Stage.FLOWERING
	p.server_crop_lost(GrowPlot.LOSS_EATEN)
	p.server_reset()
	var plant: Dictionary = Events.get_shift_costs().get(Events.COST_PLANT, {})
	check(int(plant.get("plants", 0)) == 1 and String(plant.get("strain", "")) == "golden" and int(plant.get("money", 0)) == b.counted_fine,
			"a Golden Kush eaten: the plant and its counted fine (%s)" % [plant])
	check(Story.read_cost_line(Events.COST_PLANT, plant) == "The plant ate a tray of Golden Kush.", "'%s'" % Story.read_cost_line(Events.COST_PLANT, plant))
	_despawn_products()

	step("the report: the shift ends, the card says what it cost")
	var lines_now := Story.get_shift_cost_lines()
	GameState.time_left = 0.2
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED or GameState.phase == GameState.Phase.ROUND_SUCCESS, 5.0, "the shift ends")
	await wait_frames(3)
	var report := _hud.round_end.report
	check(_hud.round_end.visible and report != null, "the round-end card is up")
	check(report.get_cost_texts() == lines_now and lines_now.size() == 3, "the report shows the three lines: %s" % [report.get_cost_texts()])
	var box := report.get_node_or_null(^"CostLines") as Control
	check(box != null and box.get_index() == report.grid.get_index() + 1, "right under the table")
	await wait_sec(0.6)
	var card := _hud.round_end.get_node_or_null(^"Center/Card") as Control
	check(card != null and get_viewport().get_visible_rect().encloses(card.get_global_rect()), "the card still fits 1280x720 (%s)" % (card.get_global_rect() if card != null else Rect2()))
	print("  REPORT| %s" % " / ".join(report.get_cost_texts()))


# --- the audit table --------------------------------------------------------------------------------------------------

func _row_pair(name: String, told: bool, t: float) -> void:
	for row: Array in _audit_rows:
		if String(row[0]) == name:
			if told:
				row[2] = t
			else:
				row[1] = t
			return
	_audit_rows.append([name, -1.0 if told else t, t if told else -1.0, ""])


func _print_audit() -> void:
	step("the audit table (first sign to first cost, seconds; bare = before M19, told = the scheduler now)")
	for row: Array in _audit_rows:
		print("  AUDIT| %-20s | bare %6.2f | told %6.2f | %s" % [row[0], float(row[1]), float(row[2]), row[3]])


# --- helpers ----------------------------------------------------------------------------------------------------------

## Starts `kind` told or bare and ticks STEP until `cost` says so; returns the seconds since the event packet (-1 if
## it never came within `max_sec`). Everything happens inside one frame.
func _sim(kind: StringName, told: bool, cost: Callable, max_sec: float) -> float:
	_quiet()
	var ok := Events.server_start_scheduled(kind) if told else Events.server_start_event(kind)
	if not check(ok, "%s starts (%s)" % [kind, "told" if told else "bare"]):
		return -1.0
	var left0 := Events.get_event_time_left()
	if bool(cost.call()):
		return 0.0
	var t := 0.0
	while t < max_sec:
		Events.tick(STEP)
		t += STEP
		if bool(cost.call()):
			return snappedf(left0 - Events.get_event_time_left() if Events.is_event_active(kind) else t, 0.001)
	return -1.0


## The same in real time (the Boss's walk and the rat's run are animated on their own nodes); the event's own clock
## measures it.
func _real(kind: StringName, told: bool, cost: Callable, max_sec: float) -> float:
	_quiet()
	var ok := Events.server_start_scheduled(kind) if told else Events.server_start_event(kind)
	if not check(ok, "%s starts (%s)" % [kind, "told" if told else "bare"]):
		return -1.0
	var left0 := Events.get_event_time_left()
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < max_sec * 1000.0:
		if bool(cost.call()):
			return snappedf(left0 - Events.get_event_time_left(), 0.001)
		await get_tree().process_frame
	return -1.0


## Real frames until `p` can be knocked over again (a stagger runs on the body's own clock, not on Events.tick).
func _unstun(p: Player) -> void:
	var start := Time.get_ticks_msec()
	while not p.can_be_staggered() and Time.get_ticks_msec() - start < 5000:
		await get_tree().process_frame


## Real frames until the Boss is back at his window (the inspection starts his walk from there).
func _boss_home() -> void:
	var boss := Events.call(&"_boss") as ShopkeeperNPC
	var start := Time.get_ticks_msec()
	while boss != null and (boss.is_walking() or boss.is_at_post()) and Time.get_ticks_msec() - start < 20000:
		await get_tree().process_frame
	await wait_sec(1.0)   # the glide back behind the counter


func _tick(seconds: float) -> void:
	var t := 0.0
	while t < seconds - 0.0001:
		var d := minf(STEP, seconds - t)
		Events.tick(d)
		t += d


func _end() -> void:
	if Events.is_event_active():
		Events.server_end_event()
	_quiet()


## No event from the scheduler while the suite drives them.
func _quiet() -> void:
	Events.set(&"_next_in", -1.0)


func _hud_sync() -> void:
	_hud.call(&"_show_event_banner", false)


func _park() -> void:
	_put(_bob, PARK_BOB)
	_put(_cara, PARK_CARA)
	_me.velocity = Vector3.ZERO
	_me.global_position = PARK_ME


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _plot(i: int) -> GrowPlot:
	return _room.get_station("GrowPlot%d" % i) as GrowPlot


func _reset_plots() -> void:
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		var pl := _plot(i)
		if pl != null:
			pl.server_reset()


func _bundle(strain: StringName, pos: Vector3, holder: int = 0) -> Item:
	return _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": strain, "amount": 1}, pos, holder)


func _despawn_products() -> void:
	for item in _world.items.get_items_of_type(Const.ITEM_PRODUCT):
		_world.items.server_despawn_item(item)


func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	await wait_frames(1)


## The tray the rat reaches soonest from its gap, and how long its run takes.
func _nearest_rat_plot() -> GrowPlot:
	var best: GrowPlot = null
	var best_t := INF
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		var t := _rat_run_sec(_plot(i))
		if t < best_t:
			best_t = t
			best = _plot(i)
	return best


func _rat_run_sec(p: GrowPlot) -> float:
	var target: Vector3 = p.global_position + p.global_basis.z.normalized() * 0.55
	var from := Events.RAT_GAP
	return Vector2(target.x - from.x, target.z - from.z).length() / 2.6


func _words(text: String) -> int:
	var n := 0
	for w in text.split(" ", false):
		if w.strip_edges() != "":
			n += 1
	return n


## A line with its blanks filled: a worker's name (one word), or the strain / the tray / the amount the key names.
func _fill(raw: String, s: String = "Dale") -> String:
	var out := raw.replace("%%", "\u0001").replace("%d", "40").replace("%s", s)
	return out.replace("\u0001", "%")


## The longest thing a key's "%s" stands for (a worker's name for the rest).
const FILLERS: Dictionary = {
	"shortage": "Night Shift", "shortage_end": "Night Shift", "hostile_eating": "GrowPlot 10", "hostile_ate": "GrowPlot 10",
	"plot_burnt": "GrowPlot 10", "collection": "forty", "collector_ask": "Forty", "counted_fine": "Twenty-five",
	"read_toast_audit": "$1,240",
}


## Within one step of `want` (a timer that runs out on a sum of float steps lands on it or one step after).
func _near(t: float, want: float) -> bool:
	return t >= want - 0.001 and t <= want + STEP + 0.001


func _live_texts() -> PackedStringArray:
	var out := PackedStringArray()
	for c in _hud.toasts.get_children():
		var t := c as HudToast
		if t != null and not t.is_queued_for_deletion() and not t.is_dismissing():
			out.append(t.text)
	return out


func _clear_toasts() -> void:
	for c in _hud.toasts.get_children():
		_hud.toasts.remove_child(c)
		c.queue_free()
	await wait_frames(1)


class FakePrompt extends Node:
	signal prompt_changed(text: String, enabled: bool)
