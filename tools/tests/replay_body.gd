extends "res://tools/tests/qa_base.gd"
## M15 replay suite (replay agent): shift conditions, the market and strain unlocks on a single headless host with fake
## workers (Net.players + World.server_spawn_player, no owning peer). Time is advanced with GrowPlot.tick / Events.tick.
##   the catalog (ids, copy, keys, the incompatible pairs), ShiftConditions.combine / roll / roll_market;
##   unlocks on shift 1 (a locked purchase refused by the host, the card reads FROM SHIFT N);
##   GameState.condition_value products and sums, server_set_conditions, the signals;
##   the terms of a shift (a short clock: 40 s less, 15% less due, in the alley's WAITING state and at the start);
##   every condition through its real consumer (a tray dries faster, grows faster, a seeded mutation roll, growth in
##   the dark, the power cut's length, the picker's weights, the gap, a cheaper seed bought, a deposit at the market's
##   value, the buyer, the cured order, a sprinting worker slips on the slick floor);
##   seven real shifts: the rolling rules, the market's range and that it moves, unlocks, the briefing, the chips, the
##   toasts, the report's line; the lobby's way back rolls before the shift and the start keeps the roll;
##   late-join state by direct RPC, reset, and the whole thing inert with replay off.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/replay_body.gd --replay --port=7983
## Launched with --no-replay it runs the catalog checks and the inert part only.
## Every engine/script error fails the run unless announced (qa_base.gd).

const STEP := 0.05
const SEED := 20261002

var _world: World
var _room: Room
var _hud: HUD
var _shop: ShopCounter
var _chute: TurnInStation
var _conditions_signals: int = 0
var _market_signals: int = 0


func _run() -> void:
	_label = "replay"
	await get_tree().process_frame
	GameState.conditions_changed.connect(func() -> void: _conditions_signals += 1)
	GameState.market_changed.connect(func() -> void: _market_signals += 1)
	var b: BalanceConfig = Config.balance
	var replay_run := Config.replay_enabled

	_test_catalog()
	_test_dice(b)

	step("hosting")
	# M16 lead: the shift's job is rolled from an unseeded dice and pays on the spot; this suite counts money to the
	# dollar (a deposit that happened to finish the job failed "a quiet night" once), so its jobs pay nothing.
	b.contract_reward = 0
	# M17 finale: this suite plays nine shifts of one run; with the run's end in place shift 4 would be the final notice
	# (two conditions, the run cleared when paid). The final notice has its own suite (finale_body.gd): no end here.
	b.final_shift_by_team.clear()
	check(replay_run == Config.has_arg("replay") or Config.has_arg("no-replay"), "Config.replay_enabled follows --replay / --no-replay (%s)" % replay_run)
	Game.start_host("Tester", port_arg(7983))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_hud = _world.get_node_or_null(^"HUD") as HUD
	_shop = _room.get_station("ShopCounter") as ShopCounter
	_chute = _room.get_station("TurnInStation") as TurnInStation
	check(_hud != null and _shop != null and _chute != null, "the HUD, the counter and the chute exist")
	for id in [2, 3, 4]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	check(_world.get_players().size() == 4, "host + 3 fake workers spawned")
	GameState.replay_rng.seed = SEED

	if replay_run:
		await _test_shift_one(b)
		await _test_values()
		await _test_terms(b)
		await _test_trays(b)
		await _test_events(b)
		await _test_money(b)
		await _test_slick_floor(b)
		await _test_shifts(b)
		await _test_lobby_roll(b)
		await _test_late_join()
		await _test_reset(b)
	await _test_inert(b)
	finish()


# --- the catalog ----------------------------------------------------------------------------------------------------

func _test_catalog() -> void:
	step("catalog")
	var ids := ShiftConditions.get_ids()
	var unique: Dictionary = {}
	var titles: Dictionary = {}
	for id in ids:
		unique[id] = true
	check(ids.size() >= 10 and unique.size() == ids.size(), "%d conditions, every id once" % ids.size())
	for id: StringName in [&"dry_air", &"twitchy", &"buyer", &"clearance", &"inspection_week", &"bad_wiring", &"short_clock", &"overtime", &"slick_floor", &"thin_walls"]:
		check(ids.has(id), "the contract's %s is in the catalog" % id)
	check(ids.size() >= 12, "two or three more of the agent's own (%d in all)" % ids.size())
	var copy_ok := true
	var words_ok := true
	var keys_ok := true
	var effects_ok := true
	for base in ids:
		var id := ShiftConditions.make_id(base, &"purple") if ShiftConditions.takes_strain(base) else base
		if not ShiftConditions.has(id):
			copy_ok = false
		var title := ShiftConditions.get_title(id)
		var text := ShiftConditions.get_line(id)
		titles[title] = true
		if title == "" or text == "" or title.contains("!") or text.contains("!") or not text.ends_with(".") or title.contains("%") or text.contains("%s"):
			copy_ok = false
			print("      copy: %s '%s' '%s'" % [id, title, text])
		var words := title.split(" ", false).size()
		if words < 2 or words > 3:
			words_ok = false
			print("      title words: %s '%s'" % [id, title])
		var effects := ShiftConditions.get_effects(id)
		if effects.is_empty():
			effects_ok = false
		for key: StringName in effects:
			if not ShiftConditions.is_known_key(key) or not is_finite(float(effects[key])):
				keys_ok = false
				print("      key: %s %s" % [id, key])
		var boss := Story.line("cond_%s" % base)
		if boss == "" or boss.contains("!"):
			copy_ok = false
			print("      Boss line: %s '%s'" % [base, boss])
	check(copy_ok, "every condition has a title, a flat line ending in a full stop and a Boss line, none with '!'")
	check(words_ok, "every chip title is two or three words")
	check(titles.size() == ids.size(), "the titles are all different")
	check(effects_ok and keys_ok, "every condition changes something, through keys the consumers know")
	check(ShiftConditions.is_known_key(&"water_drain") and ShiftConditions.is_known_key(&"sale_value:purple") and ShiftConditions.is_known_key(&"event_weight:raid")
			and not ShiftConditions.is_known_key(&"water_drain:purple") and not ShiftConditions.is_known_key(&"nonsense") and not ShiftConditions.is_known_key(&"event_weight:"),
			"known keys: plain ones, and sale_value: / event_weight: with any name behind")
	check(ShiftConditions.is_additive(&"round_sec_add") and ShiftConditions.is_additive(&"floor_wet") and not ShiftConditions.is_additive(&"water_drain")
			and not ShiftConditions.is_additive(&"sale_value:purple"), "round_sec_add and floor_wet are sums, the rest products")
	check(ShiftConditions.has(&"buyer:purple") and not ShiftConditions.has(&"buyer") and not ShiftConditions.has(&"dry_air:purple") and not ShiftConditions.has(&"nonsense"),
			"the buyer needs its strain, the others take none")
	check(ShiftConditions.get_title(&"buyer:purple") == "Purple Haze buyer" and ShiftConditions.get_line(&"buyer:purple") == "A buyer wants Purple Haze. It deposits for half again.",
			"the buyer names its strain ('%s')" % ShiftConditions.get_title(&"buyer:purple"))
	var buyer := ShiftConditions.get_effects(&"buyer:golden")
	check(buyer.size() == 1 and is_equal_approx(float(buyer.get(&"sale_value:golden", 0.0)), 1.5), "buyer:golden -> sale_value:golden x1.5 (%s)" % [buyer])
	var pairs_ok := true
	for pair: Array in ShiftConditions.INCOMPATIBLE:
		if not ids.has(pair[0]) or not ids.has(pair[1]) or ShiftConditions.are_compatible(pair[0], pair[1]) or ShiftConditions.are_compatible(pair[1], pair[0]):
			pairs_ok = false
	check(pairs_ok and not ShiftConditions.are_compatible(&"short_clock", &"overtime") and ShiftConditions.are_compatible(&"dry_air", &"overtime")
			and not ShiftConditions.are_compatible(&"buyer:purple", &"buyer:golden"), "incompatible pairs: the two clocks and the rest of the list, both ways; never the same one twice")

	step("combine")
	var c := ShiftConditions.combine([&"dry_air", &"heat_wave"])
	check(is_equal_approx(float(c[&"water_drain"]), 1.5 * 1.75) and is_equal_approx(float(c[&"growth_speed"]), 1.25), "multipliers multiply: water_drain 1.5 x 1.75 = %.3f" % float(c[&"water_drain"]))
	c = ShiftConditions.combine([&"short_clock", &"overtime"])
	check(is_zero_approx(float(c[&"round_sec_add"])) and is_equal_approx(float(c[&"quota"]), 0.85 * 1.15), "additive keys add: -40 + 40 = %.0f s; quota 0.85 x 1.15" % float(c[&"round_sec_add"]))
	c = ShiftConditions.combine([&"slick_floor", &"buyer:purple", &"quiet_night"])
	check(is_equal_approx(float(c[&"floor_wet"]), 1.0) and is_equal_approx(float(c[&"sale_value:purple"]), 1.5) and is_equal_approx(float(c[&"sale_value"]), 0.9) and not c.has(&"water_drain"),
			"three at once keep their own keys (%s)" % [c])
	check(ShiftConditions.combine([]).is_empty(), "no conditions, no keys")


func _test_dice(b: BalanceConfig) -> void:
	step("the dice")
	check(b.conditions_from_round == 2 and b.conditions_per_shift == 1 and is_equal_approx(b.market_swing, 0.15) and is_equal_approx(b.event_gap_shrink_per_round, 0.08),
			"balance: from shift 2, one per shift, swing 0.15, gaps shrink 0.08")
	var counts: Array = []
	for n in range(1, 8):
		counts.append(ShiftConditions.count_for_round(n, b.conditions_from_round, b.conditions_per_shift))
	check(counts == [0, 1, 1, 1, 2, 2, 2], "none on shift 1, one from shift 2, two from shift 5 (%s)" % [counts])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var strains: Array = [&"budget", &"purple", &"creeper"]
	var seen: Dictionary = {}
	var bad := 0
	var previous: Array = []
	for i in 600:
		var got := ShiftConditions.roll(2, previous, rng, true, strains, true)
		if got.size() != 2 or not ShiftConditions.are_compatible(got[0], got[1]):
			bad += 1
		for id in got:
			seen[ShiftConditions.base_of(id)] = true
			if not ShiftConditions.has(id):
				bad += 1
			for old: StringName in previous:
				if ShiftConditions.base_of(old) == ShiftConditions.base_of(id):
					bad += 1
			if ShiftConditions.takes_strain(id) and not strains.has(ShiftConditions.param_of(id)):
				bad += 1
		previous = got
	check(bad == 0, "600 rolls of two: always two, compatible, never one of the shift before, the buyer's strain is on sale")
	check(seen.size() == ShiftConditions.get_ids().size(), "every condition comes up (%d of %d)" % [seen.size(), ShiftConditions.get_ids().size()])
	var quiet := 0
	var no_buyer := 0
	var no_twitch := 0
	for i in 300:
		for id in ShiftConditions.roll(2, [], rng, false, strains, true):
			if ShiftConditions.needs_events(id):
				quiet += 1
		for id in ShiftConditions.roll(2, [], rng, true, [], true):
			if ShiftConditions.takes_strain(id):
				no_buyer += 1
		for id in ShiftConditions.roll(2, [], rng, true, strains, false):
			if ShiftConditions.base_of(id) == ShiftConditions.ID_TWITCHY:
				no_twitch += 1
	check(quiet == 0 and no_buyer == 0 and no_twitch == 0, "never one that would do nothing: no event conditions without events, no buyer without strains, no twitchy batch without a strain that walks")
	check(ShiftConditions.roll(0, [], rng, true, strains, true).is_empty() and ShiftConditions.roll(99, [], rng, true, strains, true).size() < ShiftConditions.get_ids().size(),
			"zero asked, zero rolled; a pool that runs dry returns what it has")

	step("the market's dice")
	var every: Array = []
	for def: SeedDef in b.seeds:
		every.append(def.id)
	var grid_ok := true
	var fair_ok := true
	var lows := 0
	var highs := 0
	var values: Dictionary = {}
	for i in 400:
		var m := ShiftConditions.roll_market(rng, b.market_swing, every, strains)
		if m.size() != every.size():
			grid_ok = false
		var best := 0.0
		for id: StringName in m:
			var v := float(m[id])
			values[v] = true
			if v < 1.0 - b.market_swing - 0.0001 or v > 1.0 + b.market_swing + 0.0001 or absf(v * 20.0 - roundf(v * 20.0)) > 0.0001:
				grid_ok = false
			if strains.has(id):
				best = maxf(best, v)
			lows += 1 if is_equal_approx(v, 1.0 - b.market_swing) else 0
			highs += 1 if is_equal_approx(v, 1.0 + b.market_swing) else 0
		if best < 1.0:
			fair_ok = false
	check(grid_ok, "400 markets: every strain, always within the swing, always on the 5% grid")
	check(values.size() == roundi(b.market_swing * 40.0) + 1 and lows > 0 and highs > 0, "every 5%% step of the swing comes up, both ends included (%d values)" % values.size())
	check(fair_ok, "never every strain on sale below par")
	check(ShiftConditions.snap_market(1.1499999) == 1.15 and ShiftConditions.snap_market(0.874) == 0.85 and ShiftConditions.snap_market(1.0) == 1.0, "snap_market gives the literal's own double")


# --- shift 1: plain, and the locked strains ---------------------------------------------------------------------------

func _test_shift_one(b: BalanceConfig) -> void:
	step("shift 1 is plain")
	var me: Player = Game.local_player
	check(GameState.is_replay_on() and GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "replay on, WAITING, shift 1")
	check(GameState.get_conditions().is_empty() and GameState.get_market().is_empty() and GameState.get_shift_briefing().is_empty(), "nothing rolled for shift 1: no conditions, no market, an empty briefing")
	check(GameState.condition_value(&"water_drain", 1.0) == 1.0 and GameState.condition_value(&"round_sec_add", 0.0) == 0.0 and GameState.get_market_multiplier(&"purple") == 1.0
			and GameState.get_deposit_factor(&"purple") == 1.0 and GameState.get_event_gap_factor() == 1.0, "every query at its default")
	check(_hud.get_condition_chips() != null and not _hud.get_condition_chips().visible and _hud.get_condition_chip_texts().is_empty(), "no chips")
	var chips := _hud.get_condition_chips()
	check(chips != null and chips.get_parent() == _hud.quota_panel.get_parent() and chips.get_index() == _hud.quota_panel.get_index() + 1 and chips.name == "ConditionChips",
			"the chip row sits right under the payment panel, in its own container")

	step("unlocks")
	var expected := {&"budget": 1, &"purple": 1, &"creeper": 1, &"golden": 2, &"nightshift": 3, &"brick": 4, &"damp": 3}  # M18 spores: Black Damp from shift 3
	var unlock_ok := true
	for id: StringName in expected:
		if GameState.get_unlock_round(id) != int(expected[id]) or GameState.is_strain_unlocked(id) != (int(expected[id]) <= 1):
			unlock_ok = false
	check(unlock_ok, "Budget, Purple, Creeper from shift 1; Golden 2, Night Shift and Black Damp 3, Floor Brick 4")
	check(GameState.is_strain_unlocked(&"nonsense") and GameState.get_new_strains(1).is_empty() and _same(GameState.get_new_strains(3), [&"nightshift", &"damp"]), "an unknown strain is never locked; shift 3 brings Night Shift and Black Damp")
	GameState.server_add_money(1000)
	await wait_frames(1)
	stand_near(_shop, 1.3)
	var money0 := GameState.money
	var r := _shop.server_buy_seed(1, &"golden")
	check(not bool(r["ok"]) and String(r["reason"]) == "From shift 2." and GameState.money == money0 and _world.items.get_held_by(1) == null,
			"a locked strain is refused by the host: '%s', nothing charged, nothing in hand" % r["reason"])
	r = _shop.server_buy_seed(1, &"brick")
	check(not bool(r["ok"]) and String(r["reason"]) == "From shift 4.", "Floor Brick: '%s'" % r["reason"])
	toasts.clear()
	_shop._rpc_request_buy_seed(&"nightshift")
	await wait_frames(2)
	check(toast_seen("From shift 3.") and GameState.money == money0, "the request path answers 'From shift 3.'")
	r = _shop.server_buy_seed(1, &"purple")
	var purple_def: SeedDef = b.get_seed(&"purple")
	check(bool(r["ok"]) and GameState.money == money0 - purple_def.cost, "Purple Haze sells as always ($%d)" % purple_def.cost)
	_drop_held()
	await wait_frames(1)
	_shop.open_shop_for(me)
	await wait_frames(2)
	var ui := _shop.get_shop_ui()
	check(ui != null and ui.is_open(), "the supply window opens")
	if ui != null:
		var golden := ui.get_card(ShopCounter.KIND_SEED, &"golden")
		var brick := ui.get_card(ShopCounter.KIND_SEED, &"brick")
		var purple := ui.get_card(ShopCounter.KIND_SEED, &"purple")
		check(golden != null and golden.is_locked() and not golden.is_buy_enabled() and golden.get_buy_button().text == "FROM SHIFT 2" and golden.get_lock_text() == "From shift 2",
				"Golden Kush's card: '%s', disabled ('%s')" % [golden.get_buy_button().text, golden.get_lock_text()])
		check(brick != null and brick.is_locked() and brick.get_buy_button().text == "FROM SHIFT 4" and brick.modulate.a < 0.9, "Floor Brick's card: FROM SHIFT 4, dimmed")
		check(purple != null and not purple.is_locked() and purple.is_buy_enabled() and purple.get_buy_button().text == "BUY  $%d" % purple_def.cost and purple.get_lock_text() == "" and purple.modulate.a == 1.0,
				"Purple Haze's card buys as always")
		check(purple.get_value_mark() == 0 and (purple.get_value_mark_node() == null or not purple.get_value_mark_node().visible) and purple.get_stats_text().contains("Deposits for $%d" % _pay(purple_def, purple_def.yield_amount, 1.0)),
				"no value mark on a plain day")
		_shop.close_shop()
	await wait_frames(1)


# --- condition_value ---------------------------------------------------------------------------------------------------

func _test_values() -> void:
	step("condition_value")
	var signals0 := _conditions_signals
	_cond([&"dry_air"])
	check(_same(GameState.get_conditions(), [&"dry_air"]) and _conditions_signals == signals0 + 1, "server_set_conditions: one condition, conditions_changed once")
	check(is_equal_approx(GameState.condition_value(&"water_drain", 1.0), 1.5) and GameState.condition_value(&"seed_cost", 7.0) == 7.0, "its key x1.5; a key nobody has returns the default")
	_cond([&"dry_air"])
	check(_conditions_signals == signals0 + 1, "the same set again: no signal")
	_cond([&"dry_air", &"heat_wave"])
	check(is_equal_approx(GameState.condition_value(&"water_drain", 1.0), 1.5 * 1.75), "two with the same key: the product (%.3f)" % GameState.condition_value(&"water_drain", 1.0))
	_cond([&"short_clock", &"overtime", &"slick_floor"])
	check(is_zero_approx(GameState.condition_value(&"round_sec_add", 99.0)) and is_equal_approx(GameState.condition_value(&"quota", 1.0), 0.85 * 1.15) and GameState.condition_value(&"floor_wet", 0.0) == 1.0,
			"additive keys: the sum (-40 + 40 = 0, not the default); floor_wet 1")
	_cond([&"dry_air", &"nonsense", &"dry_air", &"buyer"])
	check(_same(GameState.get_conditions(), [&"dry_air"]), "unknown ids, doubles and a buyer without a strain are dropped")
	var mine := GameState.get_conditions()
	mine.append(&"overtime")
	check(GameState.get_conditions().size() == 1, "get_conditions hands out a copy")
	_cond([])
	check(GameState.get_conditions().is_empty() and GameState.condition_value(&"water_drain", 1.0) == 1.0 and not _hud.get_condition_chips().visible, "cleared: defaults again, no chips")
	await wait_frames(1)


# --- the terms of a shift: a short clock ------------------------------------------------------------------------------

func _test_terms(b: BalanceConfig) -> void:
	step("a short clock")
	var plain := GameState.get_quota_for(1)
	var length := b.round_length_sec
	check(GameState.quota == plain and is_equal_approx(GameState.time_left, length), "WAITING, plain: $%d due, %.0f s" % [plain, length])
	_cond([&"short_clock"])
	check(GameState.quota == int(round(plain * 0.85)) and is_equal_approx(GameState.time_left, length - 40.0), "set while WAITING: $%d due, %.0f s on the clock" % [GameState.quota, GameState.time_left])
	check(_hud.get_condition_chip_texts() == PackedStringArray(["Short clock"]) and _hud.get_condition_chips().visible, "the chip reads 'Short clock' already in WAITING")
	check(_hud.quota_label.text.ends_with(HUD.format_money(int(round(plain * 0.85)))), "the payment bar shows it (%s)" % _hud.quota_label.text)
	await wait_frames(2)
	var row := _hud.get_condition_chips().get_global_rect()
	var panel := _hud.quota_panel.get_global_rect()
	check(row.position.y >= panel.end.y - 0.5 and row.size.y > 10.0 and row.size.y < 40.0 and absf(row.get_center().x - panel.get_center().x) < 1.0,
			"the row is laid out under the payment panel, centred, one line high (y %.0f, %.0f px high)" % [row.position.y, row.size.y])
	var chip := _hud.get_condition_chips().get_child(0) as Control
	check(chip != null and chip.size.x > 60.0 and chip.size.x < 200.0, "one pill, as wide as its two words (%.0f px)" % (chip.size.x if chip != null else 0.0))
	# The team grows while they wait: the re-price keeps the condition's share.
	Net.players[9] = {"name": "Late", "color": Net.PALETTE[0]}
	Net.players_changed.emit()
	var plain5 := GameState.get_quota_for(1)
	check(plain5 > plain and GameState.quota == int(round(plain5 * 0.85)), "a fifth worker: $%d due (85%% of $%d)" % [GameState.quota, plain5])
	Net.players.erase(9)
	Net.players_changed.emit()
	check(GameState.quota == int(round(plain * 0.85)), "and back")
	toasts.clear()
	Story.reset_state()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(GameState.quota == int(round(plain * 0.85)), "15%% less due: $%d instead of $%d" % [GameState.quota, plain])
	check(absf(GameState.time_left - (length - 40.0)) < 1.0, "40 s shorter: %.1f s instead of %.0f" % [GameState.time_left, length])
	check(_same(GameState.get_conditions(), [&"short_clock"]) and GameState.get_market().is_empty(), "a set condition is not rolled over; shift 1 has no market")
	check(toast_seen("A short clock. Forty seconds less. 15% less due."), "the flat line is toasted when the shift starts")
	check(_barked("Shift's on.") and _barked("Short shift. Smaller number. Same door."), "the Boss: the shift line, then one line for the condition (queued: '%s')" % Story.get_pending_text())
	check(_same(GameState.get_report_conditions(), [&"short_clock"]), "the report remembers what ran")
	_cond([])
	check(GameState.quota == int(round(plain * 0.85)), "clearing them mid-shift leaves the payment due alone (terms are set at the start)")
	b.end_round_on_quota_met = false   # the deposits below must not end the shift
	await wait_frames(1)


# --- trays ------------------------------------------------------------------------------------------------------------

func _test_trays(b: BalanceConfig) -> void:
	step("trays: dry air, heat wave")
	var p := plot(1)
	check(p != null and p.server_plant(&"budget") and p.server_water(1.0), "a Budget Bud seedling, watered")
	var plain := _tray_step(p)
	_cond([&"dry_air"])
	var dry := _tray_step(p)
	check(_ratio(dry[0], plain[0], 1.5) and _ratio(dry[1], plain[1], 1.0), "dry air: the tray dries 1.5 times as fast (%.4f vs %.4f per s), growth unchanged" % [dry[0], plain[0]])
	var seconds_plain := (1.0 - b.dry_threshold) / plain[0]
	check(_ratio(seconds_plain / 1.5, (1.0 - b.dry_threshold) / dry[0], 1.0), "a full tray lasts %.0f s instead of %.0f" % [(1.0 - b.dry_threshold) / dry[0], seconds_plain])
	_cond([&"heat_wave"])
	var hot := _tray_step(p)
	check(_ratio(hot[0], plain[0], 1.75) and _ratio(hot[1], plain[1], 1.25), "heat wave: drinks 1.75 times as much, grows 1.25 times as fast")
	check(_ratio(GameState.get_growth_speed_multiplier(), 1.25 * Config.growth_speed_override, 1.0), "get_growth_speed_multiplier carries it (the card's 'Grows in' too)")
	_cond([])
	var again := _tray_step(p)
	check(_ratio(again[0], plain[0], 1.0) and _ratio(again[1], plain[1], 1.0), "cleared: the plain rates again")

	step("trays: a twitchy batch (a seeded roll)")
	var creeper: SeedDef = b.get_seed(&"creeper")
	var chance := creeper.mutation_chance
	check(chance > 0.0 and chance * 2.0 < 1.0, "Creeper turns %.0f%% of the time" % (chance * 100.0))
	# A seed whose first randf() lands between the plain chance and twice the chance: safe on a plain day, turns today.
	var roll_seed := -1
	for candidate in range(1, 4000):
		seed(candidate)
		var v := randf()
		if v >= chance and v < chance * 2.0:
			roll_seed = candidate
			break
	check(roll_seed > 0, "found a roll between %.2f and %.2f (seed %d)" % [chance, chance * 2.0, roll_seed])
	var q := plot(2)
	q.server_plant(&"creeper")
	q.server_water(1.0)
	q.stage = GrowPlot.Stage.READY
	seed(roll_seed)
	var turned_plain := q.server_roll_mutation()
	_cond([&"twitchy"])
	seed(roll_seed)
	var turned_twitchy := q.server_roll_mutation()
	q.turning = false
	q.server_reset()
	check(not turned_plain and turned_twitchy, "the same roll: safe on a plain day, it turns in a twitchy batch")
	# --- M16 polish: the cap on walking plants (still under the twitchy batch) ---
	var cap := b.mutation_chance_cap
	var night: SeedDef = b.get_seed(&"nightshift")
	check(is_equal_approx(cap, 0.5) and night.mutation_chance * 2.0 > cap and night.mutation_chance < cap,
			"Night Shift turns %.0f%% of the time: doubled it would pass the cap of %.0f%%" % [night.mutation_chance * 100.0, cap * 100.0])
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), cap), "twitchy: Night Shift stops at the cap (%.2f, not %.2f)" % [GrowPlot.get_mutation_chance(night), night.mutation_chance * 2.0])
	check(is_equal_approx(GrowPlot.get_mutation_chance(creeper), chance * 2.0), "twitchy: Creeper is under the cap and simply doubles (%.2f)" % GrowPlot.get_mutation_chance(creeper))
	check(GrowPlot.get_mutation_chance(b.get_seed(&"budget")) == 0.0 and GrowPlot.get_mutation_chance(null) == 0.0, "twitchy: 0 stays 0")
	var over_seed := -1
	for candidate in range(1, 4000):
		seed(candidate)
		var v := randf()
		if v >= cap + 0.02 and v < night.mutation_chance * 2.0 - 0.02:
			over_seed = candidate
			break
	var under_seed := -1
	for candidate in range(1, 4000):
		seed(candidate)
		var v := randf()
		if v >= night.mutation_chance + 0.02 and v < cap - 0.02:
			under_seed = candidate
			break
	check(over_seed > 0 and under_seed > 0, "found a roll between the cap and the doubled chance (seed %d) and one under the cap (seed %d)" % [over_seed, under_seed])
	var r := plot(5)
	r.server_plant(&"nightshift")
	r.server_water(1.0)
	r.stage = GrowPlot.Stage.READY
	seed(over_seed)
	var turned_over := r.server_roll_mutation()
	seed(under_seed)
	var turned_under := r.server_roll_mutation()
	r.turning = false
	r.server_reset()
	check(not turned_over and turned_under, "twitchy Night Shift: a roll above the cap stays put (it turned before the cap), one under it turns")
	var own := night.mutation_chance
	night.mutation_chance = 0.8
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), 0.8), "the cap is on what a condition adds: a strain set above it keeps its own chance (%.2f)" % GrowPlot.get_mutation_chance(night))
	night.mutation_chance = own
	# --- end M16 polish ---
	var budget_plot := plot(3)
	budget_plot.server_plant(&"budget")
	budget_plot.stage = GrowPlot.Stage.READY
	var never := false
	for i in 200:
		never = never or budget_plot.server_roll_mutation()
	budget_plot.server_reset()
	check(not never, "a strain that never walks still never walks (0 x 2)")
	_cond([])

	step("trays: bad wiring in the dark")
	var n := plot(4)
	check(n.server_plant(&"nightshift") and n.server_water(1.0), "a Night Shift seedling")
	Events.server_set_power(false)
	await wait_frames(1)
	check(not Events.is_power_on(), "the mains are off")
	var dark := _tray_step(n)
	var frozen := _tray_step(p)
	check(dark[1] > 0.0 and frozen[1] == 0.0 and frozen[0] == 0.0, "Night Shift grows in the dark, Budget Bud is frozen")
	_cond([&"bad_wiring"])
	var wired := _tray_step(n)
	var still_frozen := _tray_step(p)
	check(_ratio(wired[1], dark[1], 1.5) and _ratio(wired[0], dark[0], 1.0), "bad wiring: it grows 1.5 times as fast in the dark, drinks the same")
	check(still_frozen[1] == 0.0, "everything else stays frozen (0 x 1.5)")
	Events.server_set_power(true)
	_cond([])
	await wait_frames(1)
	for tray in [p, q, budget_plot, n]:
		tray.server_reset()


# --- events: the length of a power cut, the picker, the gap ------------------------------------------------------------

func _test_events(b: BalanceConfig) -> void:
	step("events: the picker's weights")
	var weights_ok := true
	var total := 0
	for k in Events.KINDS:
		total += int(Events.WEIGHTS.get(k, 0))
		if Events.get_weight(k) != int(Events.WEIGHTS.get(k, 0)):
			weights_ok = false
	check(weights_ok and Events.get_weight(&"nonsense") == 0, "plain day: get_weight is WEIGHTS for every kind, 0 for an unknown one")
	var w_inspection := int(Events.WEIGHTS[Events.EVENT_INSPECTION])
	var rng := Events.get(&"_rng") as RandomNumberGenerator
	rng.seed = 99
	var plain_share := _inspection_share(4000)
	_cond([&"inspection_week"])
	check(Events.get_weight(Events.EVENT_INSPECTION) == w_inspection * 2 and Events.get_weight(Events.EVENT_POWER_CUT) == int(Events.WEIGHTS[Events.EVENT_POWER_CUT]),
			"inspection week: the inspection's weight doubles (%d -> %d), the others stay" % [w_inspection, Events.get_weight(Events.EVENT_INSPECTION)])
	var week_share := _inspection_share(4000)
	var want_plain := float(w_inspection) / float(total)
	var want_week := float(w_inspection * 2) / float(total + w_inspection)
	check(absf(plain_share - want_plain) < 0.03 and absf(week_share - want_week) < 0.03 and week_share > plain_share * 1.3,
			"the Boss walks more often: %.0f%% of 4000 picks instead of %.0f%% (expected %.0f%% / %.0f%%)" % [week_share * 100.0, plain_share * 100.0, want_week * 100.0, want_plain * 100.0])
	_cond([&"thin_walls"])
	check(Events.get_weight(Events.EVENT_DRIVEBY) == int(Events.WEIGHTS[Events.EVENT_DRIVEBY]) * 3, "thin walls: the drive-by's weight x3")
	check(is_equal_approx(GameState.condition_value(&"event_weight:some_kind_added_later", 1.0), 1.0), "a kind nobody names keeps its weight")

	step("events: bad wiring, the power cut")
	_cond([])
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "a power cut on a plain day")
	var plain_sec := float(Events.get_event_params().get("max_seconds", 0.0))
	Events.server_end_event()
	await wait_frames(2)
	_cond([&"bad_wiring"])
	check(Events.get_weight(Events.EVENT_POWER_CUT) == int(Events.WEIGHTS[Events.EVENT_POWER_CUT]) * 2, "bad wiring: power cuts weigh double")
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "a power cut with bad wiring")
	var wired_sec := float(Events.get_event_params().get("max_seconds", 0.0))
	check(is_equal_approx(plain_sec, b.power_cut_max_sec) and is_equal_approx(wired_sec, b.power_cut_max_sec * 2.0) and absf(Events.get_event_time_left() - wired_sec) < 1.0,
			"it lasts twice as long: %.0f s instead of %.0f (%.0f left)" % [wired_sec, plain_sec, Events.get_event_time_left()])
	Events.tick(plain_sec + 1.0)
	check(Events.is_event_active(Events.EVENT_POWER_CUT) and not Events.is_power_on(), "still dark after the plain length")
	Events.tick(plain_sec)
	await wait_frames(2)
	check(not Events.is_event_active() and Events.is_power_on(), "back on by itself after the long one")

	step("events: the gap")
	_cond([])
	var min0 := b.event_gap_min_sec
	var max0 := b.event_gap_max_sec
	b.event_gap_min_sec = 60.0
	b.event_gap_max_sec = 60.0
	check(GameState.get_event_gap_factor() == 1.0, "shift 1, plain: factor 1")
	check(Events.server_start_event(Events.EVENT_AUDIT), "an audit")
	Events.server_end_event()
	check(is_equal_approx(Events.get_next_event_in(), 60.0), "the next event in 60 s")
	_cond([&"quiet_night"])
	check(is_equal_approx(GameState.get_event_gap_factor(), 1.8), "a quiet night: factor 1.8")
	check(Events.server_start_event(Events.EVENT_AUDIT), "another audit")
	Events.server_end_event()
	check(is_equal_approx(Events.get_next_event_in(), 108.0), "the next event in 108 s")
	b.event_gap_min_sec = min0
	b.event_gap_max_sec = max0
	Events.set(&"_next_in", -1.0)
	_cond([])
	await wait_frames(2)


# --- money: clearance, the market, the buyer, the cured order -------------------------------------------------------------

func _test_money(b: BalanceConfig) -> void:
	step("clearance")
	var me: Player = Game.local_player
	var budget: SeedDef = b.get_seed(&"budget")
	var purple: SeedDef = b.get_seed(&"purple")
	var creeper: SeedDef = b.get_seed(&"creeper")
	var golden: SeedDef = b.get_seed(&"golden")
	var cheap_budget := maxi(int(round(budget.cost * 0.7)), 1)
	var cheap_purple := maxi(int(round(purple.cost * 0.7)), 1)
	stand_near(_shop, 1.3)
	_cond([&"clearance"])
	check(GameState.get_seed_cost(budget) == cheap_budget and GameState.get_seed_cost(purple) == cheap_purple and cheap_budget < budget.cost,
			"seeds 30%% off: %s $%d (the data still says $%d), %s $%d" % [budget.display_name, cheap_budget, budget.cost, purple.display_name, cheap_purple])
	var money0 := GameState.money
	var r := _shop.server_buy_seed(1, &"budget")
	check(bool(r["ok"]) and GameState.money == money0 - cheap_budget, "the purchase charges $%d (cash %d -> %d)" % [cheap_budget, money0, GameState.money])
	_drop_held()
	await wait_frames(1)
	var tag := _shop.get_node_or_null(^"Visual/Jars").get_child(0).get_node_or_null(^"PriceTag") as Label3D
	check(tag != null and tag.text == "$%d" % cheap_budget, "the jar's tag says $%d" % cheap_budget)
	_shop.open_shop_for(me)
	await wait_frames(2)
	var ui := _shop.get_shop_ui()
	var card := ui.get_card(ShopCounter.KIND_SEED, &"budget")
	var margin := _pay(budget, budget.yield_amount, 1.0) - cheap_budget
	check(card.get_buy_button().text == "BUY  $%d" % cheap_budget and card.get_stats_text().contains("Margin +$%d" % margin), "the card: BUY $%d, margin +$%d (%s)" % [cheap_budget, margin, card.get_buy_button().text])
	GameState.server_add_money(-(GameState.money - (cheap_budget - 1)))
	await wait_frames(1)
	ui.call(&"_refresh")
	check(GameState.money == cheap_budget - 1 and not card.is_buy_enabled(), "one dollar short of today's price the card cannot buy")
	r = _shop.server_buy_seed(1, &"budget")
	check(not bool(r["ok"]) and String(r["reason"]) == ShopCounter.REASON_NO_MONEY and GameState.money == cheap_budget - 1, "and the host refuses: not enough cash")
	GameState.server_add_money(1000)
	_cond([])
	await wait_frames(1)
	check(tag.text == "$%d" % budget.cost and GameState.get_seed_cost(budget) == budget.cost, "cleared: the plain price again, on the jar too")

	step("the market")
	var signals0 := _market_signals
	GameState.server_set_market({&"purple": 1.2, &"budget": 0.8, "creeper": 1.0499})
	check(_market_signals == signals0 + 1 and GameState.get_market_multiplier(&"purple") == 1.2 and GameState.get_market_multiplier(&"budget") == 0.8
			and GameState.get_market_multiplier(&"creeper") == 1.05 and GameState.get_market_multiplier(&"golden") == 1.0,
			"server_set_market: market_changed once; values snapped to 5%; a strain left out pays 1.0")
	var copy := GameState.get_market()
	copy[&"purple"] = 9.0
	check(GameState.get_market_multiplier(&"purple") == 1.2, "get_market hands out a copy")
	var up := _pay(purple, 1, 1.2)
	var bundle := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, Vector3.ZERO, 1)
	await wait_frames(1)
	stand_near(_chute, 1.3)
	check(up > _pay(purple, 1, 1.0) and _chute.get_prompt(me) == "Deposit %s x1 (+$%d)" % [purple.display_name, up], "the chute's prompt shows the real number: '%s'" % _chute.get_prompt(me))
	money0 = GameState.money
	var sales0 := GameState.round_sales
	check(_chute.server_sell_item(bundle, 1) and GameState.money == money0 + up and GameState.round_sales == sales0 + up, "a deposit pays the market value: $%d (%d x 1.2)" % [up, purple.sale_value_per_unit])
	var cheap := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 2}, Vector3.ZERO, 1)
	money0 = GameState.money
	check(_chute.server_sell_item(cheap, 1) and GameState.money == money0 + _pay(budget, 2, 0.8), "%s x2 pays $%d (2 x %d x 0.8)" % [budget.display_name, _pay(budget, 2, 0.8), budget.sale_value_per_unit])
	await wait_frames(1)
	stand_near(_shop, 1.3)
	_shop.open_shop_for(me)
	await wait_frames(2)
	var c_purple := ui.get_card(ShopCounter.KIND_SEED, &"purple")
	var c_budget := ui.get_card(ShopCounter.KIND_SEED, &"budget")
	var c_golden := ui.get_card(ShopCounter.KIND_SEED, &"golden")
	var up_card := _pay(purple, purple.yield_amount, 1.2)
	check(c_purple.get_stats_text().contains("Deposits for $%d" % up_card) and c_purple.get_stats_text().contains("Margin +$%d" % (up_card - purple.cost)) and c_purple.get_value_mark() == 1
			and c_purple.get_value_mark_node() != null and c_purple.get_value_mark_node().visible, "%s's card: $%d with an up mark" % [purple.display_name, up_card])
	check(c_budget.get_stats_text().contains("Deposits for $%d" % _pay(budget, budget.yield_amount, 0.8)) and c_budget.get_value_mark() == -1 and c_budget.get_value_mark_node().visible,
			"%s's card: $%d with a down mark" % [budget.display_name, _pay(budget, budget.yield_amount, 0.8)])
	check(c_golden.get_stats_text().contains("Deposits for $%d" % _pay(golden, golden.yield_amount, 1.0)) and c_golden.get_value_mark() == 0
			and (c_golden.get_value_mark_node() == null or not c_golden.get_value_mark_node().visible), "%s's card: par, no mark" % golden.display_name)
	var mark := c_purple.get_value_mark_node()
	check(mark.get_parent().name == "Stat2" and mark.position.x > 60.0 and mark.size == Vector2(12, 12), "the mark sits after the deposit line (x %.0f)" % mark.position.x)
	var lines := GameState.get_shift_briefing()
	check(_same(lines, ["Paying well: %s. Paying badly: %s." % [purple.display_name, budget.display_name]]), "the briefing names the best and the worst strain on sale (%s)" % [lines])
	GameState.server_set_market({&"golden": 1.25, &"brick": 0.75, &"creeper": 1.1})
	check(_same(GameState.get_shift_briefing(), ["Paying well: %s." % creeper.display_name]), "strains that are not sold yet do not count; no 'badly' half when nothing on sale is below par (%s)" % [GameState.get_shift_briefing()])

	step("the buyer, the quiet night, the cured order")
	GameState.server_set_market({&"purple": 1.2})
	_cond([&"buyer:purple"])
	check(is_equal_approx(GameState.get_deposit_factor(&"purple"), 1.2 * 1.5) and GameState.get_deposit_factor(&"budget") == 1.0, "a buyer for Purple Haze on top of the market: x1.8, nobody else")
	bundle = _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, Vector3.ZERO, 1)
	money0 = GameState.money
	check(_chute.server_sell_item(bundle, 1) and GameState.money == money0 + _pay(purple, 1, 1.2 * 1.5), "the deposit pays $%d (%d x 1.2 x 1.5)" % [_pay(purple, 1, 1.2 * 1.5), purple.sale_value_per_unit])
	check(_hud.get_condition_chip_texts() == PackedStringArray(["%s buyer" % purple.display_name]), "the chip names the strain")
	check(_same(GameState.get_shift_briefing(), ["A buyer wants %s. It deposits for half again." % purple.display_name, "Paying well: %s." % purple.display_name]),
			"the briefing: the buyer's line, then the market line (%s)" % [GameState.get_shift_briefing()])
	GameState.server_set_market({&"purple": 0.8, &"creeper": 1.1})
	check(_same(GameState.get_market_extremes(), [&"purple", &""]) and is_equal_approx(GameState.get_deposit_factor(&"purple"), 0.8 * 1.5),
			"a strain with a buyer is never called bad: a weak market x the buyer still pays best (%s)" % [GameState.get_shift_briefing()])
	GameState.server_set_market({&"purple": 1.2})
	ui.call(&"_refresh")
	check(c_purple.get_stats_text().contains("Deposits for $%d" % _pay(purple, purple.yield_amount, 1.2 * 1.5)) and c_purple.get_value_mark() == 1, "the card follows")
	GameState.server_set_market({})
	_cond([&"quiet_night"])
	check(_same(GameState.get_shift_briefing(), [ShiftConditions.get_line(&"quiet_night")]) and _same(GameState.get_market_extremes(), [&"", &""]),
			"what lowers every strain alike names no strain 'bad' (%s)" % [GameState.get_shift_briefing()])
	bundle = _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "creeper", "amount": 1}, Vector3.ZERO, 1)
	money0 = GameState.money
	check(_chute.server_sell_item(bundle, 1) and GameState.money == money0 + _pay(creeper, 1, 0.9) and _pay(creeper, 1, 0.9) < _pay(creeper, 1, 1.0),
			"a quiet night: everything deposits for 10%% less (%s $%d)" % [creeper.display_name, _pay(creeper, 1, 0.9)])
	_cond([&"cured_order"])
	var bonus := maxf(b.cure_bonus, 0.0)
	var doubled := TurnInStation.compute_sale_value(purple, 1, 1.0, true)
	var wet := TurnInStation.compute_sale_value(purple, 1, 1.0, false)
	check(wet == _pay(purple, 1, 1.0) and absi(doubled - int(round(purple.sale_value_per_unit * (1.0 + 2.0 * bonus)))) <= 1 and doubled > _pay(purple, 1, 1.0 + bonus),
			"the cured order: an uncured bundle pays the plain $%d, a cured one $%d (the bonus doubled; $%d on a plain day)" % [wet, doubled, _pay(purple, 1, 1.0 + bonus)])
	bundle = _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1, "cured": true}, Vector3.ZERO, 1)
	money0 = GameState.money
	check(_chute.server_sell_item(bundle, 1) and GameState.money == money0 + doubled, "the chute pays it")
	_cond([])
	check(TurnInStation.compute_sale_value(purple, 1, 1.0, true) == _pay(purple, 1, 1.0 + bonus), "cleared: the plain cure bonus")
	_shop.close_shop()
	await wait_frames(2)


# --- the slick floor ------------------------------------------------------------------------------------------------------

func _test_slick_floor(b: BalanceConfig) -> void:
	step("the slick floor")
	var well := _room.get_station("Well") as Well
	var a := Vector3(-3.0, 0.0, 3.0)
	var z := Vector3(3.0, 0.0, 3.0)
	check(well != null and not well.has_puddle() and _room.contains_point(a) and _room.contains_point(z), "no puddle anywhere; the run is on the floor plan")
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	var w4 := _world.get_player(4)
	var slipped: Array = []
	Events.worker_slipped.connect(func(pid: int) -> void: slipped.append(pid))
	check(not Events.is_floor_slick(), "a plain day: the floor is dry")
	_dash(w2, a, z, b.sprint_speed)
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 0 and slipped.is_empty(), "sprinting on a dry floor is fine")
	_cond([&"slick_floor"])
	check(Events.is_floor_slick() and Events.is_floor_slick_at(a) and not Events.is_floor_slick_at(_world.get_lobby_transform(0).origin), "slick floor: every point of the floor plan is wet, the alley is not")
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, a, 2)
	await wait_frames(1)
	_dash(w2, a, z, b.sprint_speed)
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 1 and slipped == [2], "a sprinting worker slips, far from the tank (%s)" % [slipped])
	check(can != null and _world.items.get_held_by(2) == null, "what he carried left his hands")
	_dash(w3, a, z, b.walk_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "a walking worker does not slip")
	w4.crouching = true
	_dash(w4, a, z, b.sprint_speed)
	w4.crouching = false
	check(GameState.get_stat(4, Const.STAT_SLIPS) == 0, "a crouched worker does not slip")
	var alley := _world.get_lobby_transform(0).origin
	_dash(w3, alley, alley + Vector3(4.0, 0.0, 0.0), b.sprint_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "sprinting in the alley is nobody's business")
	_cond([])
	Events.tick(Events.SLIP_COOLDOWN_SEC + 1.0)
	_dash(w3, a, z, b.sprint_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0 and not Events.is_floor_slick() and (Events.get(&"_slip_track") as Dictionary).is_empty(), "cleared: the floor is dry again, the judge rests")
	if can != null and is_instance_valid(can):
		_world.items.server_despawn_item(can)
	await wait_frames(2)


# --- seven real shifts ----------------------------------------------------------------------------------------------------

func _test_shifts(b: BalanceConfig) -> void:
	step("shift 1 ends")
	b.end_round_on_quota_met = true
	_cond([&"short_clock"])
	check(Story.get_report_verdicts().has("Conditions: Short clock."), "the report's line while the shift runs (%s)" % [Story.get_report_verdicts()])
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "shift 1 paid")
	check(_hud.round_end.report.get_verdict_texts().has("Conditions: Short clock."), "the shift report says which conditions ran")
	var previous: Array[StringName] = GameState.get_conditions()
	var previous_market: Dictionary = GameState.get_market()
	var names := {2: "Golden Kush", 3: "Night Shift, Black Damp", 4: "Floor Brick"}  # M18 spores: Black Damp comes with Night Shift
	var everything: Dictionary = {}
	for n in range(2, 9):
		step("shift %d" % n)
		toasts.clear()
		var signals0 := _conditions_signals
		GameState.request_next_round()
		await wait_frames(1)
		if not check(GameState.is_playing() and GameState.round_number == n, "PLAYING, shift %d" % n):
			return
		var ids := GameState.get_conditions()
		var want := 1 if n < 5 else 2
		var titles := PackedStringArray()
		var rules_ok := ids.size() == want
		for i in ids.size():
			titles.append(ShiftConditions.get_title(ids[i]))
			everything[ShiftConditions.base_of(ids[i])] = true
			if ShiftConditions.needs_events(ids[i]):
				rules_ok = false
			for old in previous:
				if ShiftConditions.base_of(old) == ShiftConditions.base_of(ids[i]):
					rules_ok = false
			for j in range(i + 1, ids.size()):
				if not ShiftConditions.are_compatible(ids[i], ids[j]):
					rules_ok = false
			if ShiftConditions.takes_strain(ids[i]) and not GameState.is_strain_unlocked(ShiftConditions.param_of(ids[i])):
				rules_ok = false
		check(rules_ok, "%d rolled, none of the shift before (%s), compatible, none that needs events: %s" % [want, previous, ids])
		check(_conditions_signals == signals0 + 1, "conditions_changed once")
		var market := GameState.get_market()
		var market_ok := market.size() == b.seeds.size()
		var best_on_sale := 0.0
		for def: SeedDef in b.seeds:
			var v := GameState.get_market_multiplier(def.id)
			if v < 0.75 - 0.0001 or v > 1.25 + 0.0001 or absf(v * 20.0 - roundf(v * 20.0)) > 0.0001:
				market_ok = false
			if GameState.is_strain_unlocked(def.id):
				best_on_sale = maxf(best_on_sale, v)
		check(market_ok and best_on_sale >= 1.0, "the market: every strain within 0.75 .. 1.25 on the 5%% grid, something on sale at par or better (%s)" % [market])
		check(market != previous_market, "it moved since the shift before")
		var plain := GameState.get_quota_for(n)
		var values := ShiftConditions.combine(ids)
		check(GameState.quota == int(round(plain * float(values.get(&"quota", 1.0)))) and absf(GameState.time_left - (b.round_length_sec + float(values.get(&"round_sec_add", 0.0)))) < 1.0,
				"the terms: $%d due (plain $%d), %.0f s" % [GameState.quota, plain, GameState.time_left])
		check(_hud.get_condition_chip_texts() == titles, "the chips: %s" % [titles])
		var toasted := true
		for id in ids:
			if not toast_seen(ShiftConditions.get_line(id)):
				toasted = false
		check(toasted, "each condition's line is toasted at the start")
		var lines := GameState.get_shift_briefing()
		var brief_ok := lines.size() >= ids.size()
		for i in ids.size():
			if brief_ok and lines[i] != ShiftConditions.get_line(ids[i]):
				brief_ok = false
		var extremes := GameState.get_market_extremes()
		var market_line := ""
		if extremes[0] != &"":
			market_line = "Paying well: %s." % b.get_seed(extremes[0]).display_name
		if extremes[1] != &"":
			market_line += ("" if market_line == "" else " ") + "Paying badly: %s." % b.get_seed(extremes[1]).display_name
		var rest := lines.slice(ids.size())
		var want_rest: Array[String] = []
		if market_line != "":
			want_rest.append(market_line)
		if names.has(n):
			want_rest.append("New at the window: %s." % names[n])
		check(brief_ok and _same(rest, want_rest), "the briefing: one line per condition, the market, what is new (%s)" % [lines])
		for id: StringName in extremes:
			if id != &"" and not GameState.is_strain_unlocked(id):
				check(false, "the briefing names %s, which is not sold yet" % id)
		if names.has(n):
			check(toast_seen("New at the window: %s." % names[n]), "toast: New at the window: %s." % names[n])
		else:
			check(not toast_seen("New at the window"), "nothing new at the window")
		check(is_equal_approx(GameState.get_event_gap_factor(), maxf(1.0 - 0.08 * (n - 1), 0.5) * float(values.get(&"event_gap", 1.0))), "event gaps x%.2f" % GameState.get_event_gap_factor())
		check(is_equal_approx(Events.get_next_event_in(), b.event_first_delay_sec * GameState.get_event_gap_factor()), "the first delay shrinks with them (%.1f s)" % Events.get_next_event_in())
		if n == 2:
			check(GameState.is_strain_unlocked(&"golden") and not GameState.is_strain_unlocked(&"nightshift"), "Golden Kush is sold now, Night Shift not yet")
		if n == 4:
			GameState.server_add_money(1000)
			stand_near(_shop, 1.3)
			var r := _shop.server_buy_seed(1, &"brick")
			check(bool(r["ok"]) and GameState.is_strain_unlocked(&"brick"), "Floor Brick sells from shift 4 (%s)" % r["message"])
			_drop_held()
			var short := Events.pick_shortage_strain()
			check(short != &"" and GameState.is_strain_unlocked(short), "a shortage would hit a strain on sale (%s)" % short)
		check(Story.get_report_verdicts().has("Conditions: %s." % ", ".join(titles)), "the report's line: Conditions: %s." % ", ".join(titles))
		GameState.server_add_sale(GameState.quota, 1)
		await wait_frames(1)
		check(GameState.phase == GameState.Phase.ROUND_SUCCESS and _same(GameState.get_conditions(), ids), "paid; the conditions stay up through the end screen")
		previous = ids
		previous_market = market
	check(everything.size() >= 4, "seven shifts brought %d different conditions" % everything.size())
	var floor_ok := is_equal_approx(GameState.get_event_gap_factor() / GameState.condition_value(&"event_gap", 1.0), 0.5)
	check(GameState.round_number == 8 and floor_ok, "by shift 8 the gaps are at half and stay there")


# --- the lobby's way back rolls before the shift ------------------------------------------------------------------------------

func _test_lobby_roll(b: BalanceConfig) -> void:
	step("the way back to the alley rolls the next shift")
	var previous := GameState.get_conditions()
	var previous_market := GameState.get_market()
	var signals0 := _conditions_signals
	GameState.server_return_to_lobby(false)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 2.0, "WAITING in the alley")
	var ids := GameState.get_conditions()
	var market := GameState.get_market()
	var fresh := ids.size() == 2
	for id in ids:
		for old in previous:
			if ShiftConditions.base_of(old) == ShiftConditions.base_of(id):
				fresh = false
	check(GameState.round_number == 9 and fresh and market != previous_market and _conditions_signals == signals0 + 1, "shift 9's two conditions and its market are up before anyone boards (%s)" % [ids])
	check(_same(GameState.get_report_conditions(), previous), "the report still names the shift that ended")
	var values := ShiftConditions.combine(ids)
	var plain := GameState.get_quota_for(9)
	check(GameState.quota == int(round(plain * float(values.get(&"quota", 1.0)))) and is_equal_approx(GameState.time_left, b.round_length_sec + float(values.get(&"round_sec_add", 0.0))),
			"the alley already shows the real payment due and the real clock ($%d, %.0f s)" % [GameState.quota, GameState.time_left])
	var lines := GameState.get_shift_briefing()
	check(lines.size() >= 2 and lines[0] == ShiftConditions.get_line(ids[0]) and lines[1] == ShiftConditions.get_line(ids[1]), "the briefing for the board: %s" % [lines])
	check(_hud.get_condition_chip_texts().size() == 2, "the chips show the coming shift")
	await wait_until(func() -> bool: return not GameState.is_transitioning(), 2.0, "the ride is over")
	GameState.server_start_round()
	await wait_frames(1)
	check(GameState.is_playing() and _same(GameState.get_conditions(), ids) and GameState.get_market() == market and _conditions_signals == signals0 + 1,
			"the shift starts with exactly that roll (no second roll, no second signal)")
	check(GameState.quota == int(round(plain * float(values.get(&"quota", 1.0)))), "and the same payment due")
	_world.server_move_players_to_floor()
	await wait_frames(2)


# --- late join, reset ----------------------------------------------------------------------------------------------------------

func _test_late_join() -> void:
	step("late-join state by direct RPC")
	var s: Dictionary = GameState.call(&"_snapshot")
	check(s.has("replay") and bool((s["replay"] as Dictionary).get("on", false)), "the snapshot carries the replay entry")
	# What arrives over the wire: plain strings for the ids and the strain keys, and whatever else a host might send.
	s["replay"] = {"on": true, "conditions": ["dry_air", "buyer:purple", "nonsense", "dry_air"], "market": {"purple": 1.2, "budget": 0.8, "golden": "x", "brick": 99.0}}
	var c0 := _conditions_signals
	var m0 := _market_signals
	GameState._rpc_full_state(s)
	GameState.set(&"_authoritative", true)   # a direct call looks like a remote sender; this peer is still the host
	check(_same(GameState.get_conditions(), [&"dry_air", &"buyer:purple"]) and _conditions_signals == c0 + 1, "the joiner's conditions: typed ids, junk dropped, the signal")
	check(GameState.get_market_multiplier(&"purple") == 1.2 and GameState.get_market_multiplier(&"budget") == 0.8 and GameState.get_market_multiplier(&"golden") == 1.0
			and GameState.get_market_multiplier(&"brick") == 5.0 and _market_signals == m0 + 1, "the joiner's market: typed keys, junk dropped, a wild value clamped")
	check(is_equal_approx(GameState.condition_value(&"water_drain", 1.0), 1.5) and is_equal_approx(GameState.get_deposit_factor(&"purple"), 1.8), "the consumers read it at once")
	check(_hud.get_condition_chip_texts() == PackedStringArray(["Dry air", "Purple Haze buyer"]), "the chips follow")
	GameState.server_send_full_state(1)
	check(_conditions_signals == c0 + 2 and _market_signals == m0 + 2 and GameState.get_conditions().size() == 2, "a full state re-emits both signals and changes nothing")
	var no_entry: Dictionary = GameState.call(&"_snapshot")
	no_entry.erase("replay")
	GameState._rpc_state(no_entry)
	GameState.set(&"_authoritative", true)
	check(GameState.get_conditions().size() == 2 and GameState.is_replay_on(), "a state without the entry (an older host) leaves things as they are")
	await wait_frames(1)


func _test_reset(b: BalanceConfig) -> void:
	step("reset")
	check(GameState.round_number == 9 and not GameState.get_conditions().is_empty(), "before: shift 9 with conditions")
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "WAITING, shift 1")
	check(GameState.get_conditions().is_empty() and GameState.get_market().is_empty() and GameState.get_shift_briefing().is_empty() and GameState.get_report_conditions().is_empty(),
			"no conditions, no market, no briefing, nothing for the report")
	check(GameState.quota == GameState.get_quota_for(1) and is_equal_approx(GameState.time_left, b.round_length_sec), "the plain payment due and clock")
	check(not GameState.is_strain_unlocked(&"golden") and not GameState.is_strain_unlocked(&"brick") and GameState.is_strain_unlocked(&"budget"), "the late strains are locked again")
	check(not _hud.get_condition_chips().visible and GameState.get_event_gap_factor() == 1.0 and not _report_names_conditions(), "no chips, gaps at full length")
	GameState.request_start_round()
	await wait_frames(1)
	check(GameState.is_playing() and GameState.get_conditions().is_empty() and GameState.get_market().is_empty(), "shift 1 again: plain")
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(1)
	GameState.request_next_round()
	await wait_frames(1)
	check(GameState.round_number == 2 and GameState.get_conditions().size() == 1 and not GameState.get_market().is_empty(), "shift 2 rolls again after a reset")


# --- replay off: all of it inert -----------------------------------------------------------------------------------------------

func _test_inert(b: BalanceConfig) -> void:
	step("replay off")
	Config.replay_enabled = false
	b.end_round_on_quota_met = true
	var c0 := _conditions_signals
	GameState.server_reset_game()
	await wait_frames(2)
	check(not GameState.is_replay_on() and GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "the host runs without replay: WAITING, shift 1")
	var s: Dictionary = GameState.call(&"_snapshot")
	check(s["replay"] == {"on": false, "conditions": [], "market": {}}, "the state says so and carries nothing (%s)" % [s["replay"]])
	var all_sold := true
	for def: SeedDef in b.seeds:
		if not GameState.is_strain_unlocked(def.id) or GameState.get_unlock_round(def.id) != 1 or GameState.get_seed_cost(def) != def.cost or GameState.get_deposit_factor(def.id, true) != 1.0:
			all_sold = false
	check(all_sold, "every strain is sold from shift 1 at its plain price and value")
	GameState.server_add_money(1000)
	await wait_frames(1)
	stand_near(_shop, 1.3)
	var money0 := GameState.money
	var r := _shop.server_buy_seed(1, &"brick")
	var brick_def: SeedDef = b.get_seed(&"brick")
	check(bool(r["ok"]) and GameState.money == money0 - brick_def.cost, "Floor Brick is bought on shift 1 for its plain $%d" % brick_def.cost)
	_drop_held()
	var before := _conditions_signals
	_cond([&"dry_air", &"short_clock", &"slick_floor"])
	GameState.server_set_market({&"purple": 1.25})
	check(GameState.get_conditions().is_empty() and GameState.get_market().is_empty() and _conditions_signals == before, "server_set_conditions and server_set_market do nothing")
	check(GameState.condition_value(&"water_drain", 1.0) == 1.0 and GameState.condition_value(&"floor_wet", 0.0) == 0.0 and GameState.condition_value(&"quota", 1.0) == 1.0
			and GameState.get_market_multiplier(&"purple") == 1.0 and GameState.get_event_gap_factor() == 1.0, "values 1.0 (and 0 for the flag)")
	check(GameState.get_shift_briefing().is_empty() and GameState.get_new_strains(3).is_empty() and not _hud.get_condition_chips().visible and not Events.is_floor_slick(), "no briefing, nothing new, no chips, a dry floor")
	var plain_ok := true
	for n in range(1, 7):
		if n == 1:
			GameState.request_start_round()
		else:
			GameState.request_next_round()
		await wait_frames(1)
		if not (GameState.is_playing() and GameState.round_number == n and GameState.get_conditions().is_empty() and GameState.get_market().is_empty()
				and GameState.quota == GameState.get_quota_for(n) and absf(GameState.time_left - b.round_length_sec) < 1.0
				and is_equal_approx(Events.get_next_event_in(), b.event_first_delay_sec) and not _report_names_conditions()):
			plain_ok = false
			print("      shift %d: %s %s q%d t%.1f next %.1f" % [n, GameState.get_conditions(), GameState.get_market(), GameState.quota, GameState.time_left, Events.get_next_event_in()])
		var bundle := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1}, Vector3.ZERO, 1)
		var money1 := GameState.money
		if not _chute.server_sell_item(bundle, 1) or GameState.money != money1 + _pay(b.get_seed(&"purple"), 1, 1.0):
			plain_ok = false
		GameState.server_add_sale(GameState.quota, 1)
		await wait_frames(1)
	check(plain_ok, "six shifts: nothing rolled, the plain payment due, clock, first delay and deposit value every time")
	check(_conditions_signals == c0 + 1, "conditions_changed fired for the reset's full state and never again")
	var me: Player = Game.local_player
	GameState.server_reset_game()
	await wait_frames(2)
	stand_near(_shop, 1.3)
	_shop.open_shop_for(me)
	await wait_frames(2)
	var ui := _shop.get_shop_ui()
	if check(ui != null and ui.is_open(), "the supply window opens"):
		var brick := ui.get_card(ShopCounter.KIND_SEED, &"brick")
		check(not brick.is_locked() and brick.get_buy_button().text == "BUY  $%d" % brick_def.cost and brick.get_value_mark() == 0 and brick.modulate.a == 1.0, "Floor Brick's card: BUY, no lock, no mark")
		_shop.close_shop()
	await wait_frames(1)


# --- helpers --------------------------------------------------------------------------------------------------------------------

func _cond(ids: Array) -> void:
	var typed: Array[StringName] = []
	for id: Variant in ids:
		typed.append(StringName(str(id)))
	GameState.server_set_conditions(typed)


## One second of a tray: [water lost, stage progress gained] from a full tray at progress 0.
func _tray_step(p: GrowPlot) -> Array[float]:
	p.water = 1.0
	p.stage_progress = 0.0
	p.tick(1.0)
	return [1.0 - p.water, p.stage_progress]


func _ratio(a: float, b: float, want: float) -> bool:
	return b != 0.0 and absf(a / b - want) < 0.001


func _inspection_share(picks: int) -> float:
	var hits := 0
	for i in picks:
		if Events.pick_kind(&"") == Events.EVENT_INSPECTION:
			hits += 1
	return float(hits) / float(picks)


func _drop_held() -> void:
	var held := _world.items.get_held_by(1)
	if held != null:
		_world.items.server_despawn_item(held)


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


## Moves a fake worker from `from` to `to` at `speed` in STEP ticks of simulated time (no frames pass meanwhile). He
## first stands at `from` for a few ticks so the jump there is not part of the measured run.
func _dash(p: Player, from: Vector3, to: Vector3, speed: float) -> void:
	_put(p, from)
	for i in 10:
		Events.tick(STEP)
	var steps := int(ceil(from.distance_to(to) / (speed * STEP)))
	for i in steps:
		_put(p, from.move_toward(to, speed * STEP * (i + 1)))
		Events.tick(STEP)


## What a deposit of `amount` units pays at `factor` (the chute's own order of operations, with no favors bought).
func _pay(def: SeedDef, amount: int, factor: float) -> int:
	return int(round(amount * def.sale_value_per_unit * 1.0 * 1.0 * factor))


## Two lists with the same texts in the same order (typed or not, StringName or String).
func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if String(a[i]) != String(b[i]):
			return false
	return true


func _report_names_conditions() -> bool:
	for text in Story.get_report_verdicts():
		if text.begins_with("Conditions"):
			return true
	return false


func _barked(text: String) -> bool:
	if Story.last_bark.contains(text) or Story.get_pending_text().contains(text):
		return true
	for t in Story.bark_log:
		if String(t).contains(text):
			return true
	return false
