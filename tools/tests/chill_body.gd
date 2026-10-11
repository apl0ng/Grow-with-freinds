extends "res://tools/tests/qa_base.gd"
## M20 chill, M23 simpler: the simpler, calmer game a windowed run plays by default (scripts/core/chill.gd), on a solo
## host with `--chill --replay --run=B5VP` (two fake workers join, so the run's final notice is shift 6):
##   the preset     its values on Config.balance (disabled_strains a typed Array[StringName]), plants that walk off
##                  half as often, the event mix (only the chill kinds ever come up), the payment (85%), no shift
##                  conditions in any shift, no half-time raise
##   four strains   Budget Bud, Purple Haze, Golden Kush (shift 2), Night Shift (shift 3); Creeper, Floor Brick and
##                  Black Damp are known (get_seed) but never on sale, never bought, never on a supply card, a jar,
##                  the board, a briefing, a toast, a job, a shortage, a buyer or the market (the dice are rolled
##                  hundreds of times per shift, the buyer and the market with conditions forced on)
##   the window     the four cards in one row at 1280x720: the window fits, no scroll bar, the plain hint, every tag
##                  and name whole, the FAVORS tab the same size
##   the run        six shifts: no condition, no chip, the briefing exactly "New at the window: ..." on 2 and 3; the
##                  final notice's half-time look: short, nothing raised, the Boss says only "Half the clock."
##   the model      the economy model with the preset over the four strains: careful crews of every size clear
##                  their run (4 of 5), four average workers most of the time (3 of 5); the table is printed
## Every engine/script error fails the run unless announced (qa_base.gd).

const Sim := preload("res://tools/tests/econ_sim.gd")
const FULL_PATH := "res://data/balance.tres"
const FOUR: Array[StringName] = [&"budget", &"purple", &"golden", &"nightshift"]
const OFF: Array[StringName] = [&"creeper", &"brick", &"damp"]
const OFF_NAMES: PackedStringArray = ["Creeper", "Floor Brick", "Black Damp"]
const UNLOCKS: Dictionary = {&"budget": 1, &"purple": 1, &"golden": 2, &"nightshift": 3}
const TEXT_HALF := "Half the clock."
const TEXT_SHORT := "Half the clock. Not half the money."
## Shift -> the whole briefing of that shift (no condition, no market: only what is new at the window).
const BRIEFINGS: Dictionary = {
	1: [], 2: ["New at the window: Golden Kush."], 3: ["New at the window: Night Shift."], 4: [], 5: [], 6: [],
}
const DICE := 300

var world: World
var hud: HUD
var board: AlleyBoard
var me: Player
var _looks: Array = []            # [short, raised] per final_look
var _buyers: Dictionary = {}      # strain id -> times a buyer was rolled for it
var _named: Dictionary = {}       # every strain id a die named anywhere (jobs, shortages, buyers, the market)


func _run() -> void:
	_label = "chill"
	await get_tree().process_frame
	# Headless windows report 1280x1280; the supply window is checked at the reference logical size.
	get_tree().root.size = Vector2i(1280, 720)
	var b: BalanceConfig = Config.balance
	var full := ResourceLoader.load(FULL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as BalanceConfig

	_test_preset(b, full)
	_test_events()
	_test_payment(b, full)
	_test_four(b, full)

	step("hosting (two fake workers: the largest team is three, the final notice is shift 6)")
	GameState.final_look.connect(func(short: bool, raised: int) -> void: _looks.append([short, raised]))
	Game.start_host("Tester", port_arg(7905))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		finish(); return
	world = Game.world
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	board = world.get_node_or_null(^"Lobby/ReportBoard") as AlleyBoard
	if not check(hud != null and board != null, "the HUD and the alley's board exist"):
		finish(); return
	_add_worker(2, "Bob")
	_add_worker(3, "Cara")
	await wait_frames(2)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "a shift runs")
	check(GameState.get_final_shift() == 6, "three workers: the run's final notice is shift %d" % GameState.get_final_shift())
	var flat := true
	for id: Variant in GameState.get_market():
		if not is_equal_approx(float(GameState.get_market()[id]), 1.0):
			flat = false
	check(flat, "no market: every strain deposits at its own price (%s)" % [GameState.get_market()])
	check(GameState.quota == b.quota_for_round(1, 3), "the shift's payment is the chill one ($%d)" % GameState.quota)

	await _test_window(b)
	await _test_run(b)
	_test_economy(b)
	finish()


# --- the preset -------------------------------------------------------------------------------------------------------

func _test_preset(b: BalanceConfig, full: BalanceConfig) -> void:
	step("the preset")
	check(Config.chill_enabled, "--chill: Config.chill_enabled")
	var wrong: PackedStringArray = []
	for key: StringName in Chill.VALUES:
		var want: Variant = Chill.VALUES[key]
		var have: Variant = b.get(key)
		var same := str(have) == str(want) if want is Array else is_equal_approx(float(have), float(want))
		if not same:
			wrong.append("%s=%s" % [key, have])
	check(wrong.is_empty(), "every chill value is on Config.balance %s" % [wrong])
	var off: Array = b.disabled_strains
	check(off.is_typed() and off.get_typed_builtin() == TYPE_STRING_NAME and str(off) == str(OFF),
			"disabled_strains is a typed Array[StringName]: %s" % [off])
	check(b.conditions_from_round == 99 and is_equal_approx(b.final_interim_raise, 0.0),
			"no shift conditions (from shift %d), no half-time raise (%.2f)" % [b.conditions_from_round, b.final_interim_raise])
	var halved := true
	for i in b.seeds.size():
		var want := full.seeds[i].mutation_chance * Chill.MUTATION_SCALE
		if not is_equal_approx(b.seeds[i].mutation_chance, want):
			halved = false
	check(halved, "every strain walks off half as often")


func _test_events() -> void:
	step("the event mix")
	var kinds := {}
	for k: StringName in Events.KINDS:
		if Events.get_weight(k) > 0:
			kinds[k] = true
	check(kinds.size() == Chill.EVENT_WEIGHTS.size(), "%d kinds can come up (%s)" % [kinds.size(), kinds.keys()])
	for k: StringName in [&"audit", &"headcount", &"water_off", &"shortage", &"raid", &"collection", &"scale"]:
		check(Events.get_weight(k) == 0, "%s never comes up" % k)
	var seen := {}
	var prev: StringName = &""
	for i in 3000:
		var k := Events.pick_kind(prev)
		seen[k] = true
		prev = k
	check(seen.size() == Chill.EVENT_WEIGHTS.size() and seen.keys().all(func(k: Variant) -> bool: return Chill.EVENT_WEIGHTS.has(k)),
			"3000 rolls: only the chill kinds, every one of them (%s)" % [seen.keys()])


func _test_payment(b: BalanceConfig, full: BalanceConfig) -> void:
	step("the payment and the card")
	var off: PackedStringArray = []
	for n in range(1, 7):
		for w in range(1, 5):
			if absi(b.quota_for_round(n, w) - roundi(full.quota_for_round(n, w) * b.quota_multiplier)) > 1:
				off.append("shift %d x%d: $%d, full $%d" % [n, w, b.quota_for_round(n, w), full.quota_for_round(n, w)])
	check(off.is_empty(), "every payment (shifts 1-6, 1-4 workers) is %d%% of the full game's %s" % [roundi(b.quota_multiplier * 100.0), off])
	check(b.quota_for_round(1, 1) == roundi(full.quota_for_round(1, 1) * b.quota_multiplier), "shift 1 alone: $%d (the full game $%d)" % [b.quota_for_round(1, 1), full.quota_for_round(1, 1)])
	var counts := []
	for n in range(1, 10):
		counts.append(ShiftConditions.count_for_round(n, b.conditions_from_round, b.conditions_per_shift, b.conditions_extra_from_round))
	check(counts == [0, 0, 0, 0, 0, 0, 0, 0, 0], "no shift conditions in any shift (%s)" % [counts])


# --- four strains -----------------------------------------------------------------------------------------------------

func _test_four(b: BalanceConfig, full: BalanceConfig) -> void:
	step("four strains")
	var ids: Array[StringName] = []
	for s in b.get_enabled_seeds():
		ids.append(s.id)
	check(ids == FOUR, "the chill game sells %s" % [ids])
	for id in FOUR:
		var def := b.get_seed(id)
		check(b.is_strain_enabled(id) and def != null and maxi(def.unlock_round, 1) == int(UNLOCKS[id]),
				"%s is sold from shift %d" % [def.display_name if def != null else String(id), int(UNLOCKS[id])])
	for id in OFF:
		check(not b.is_strain_enabled(id) and b.get_seed(id) != null, "%s is off, and still known by its id (a bundle keeps its name)" % b.get_seed(id).display_name)
	check(full.disabled_strains.is_empty() and full.get_enabled_seeds().size() == 7 and full.get_enabled_seeds() == full.seeds,
			"the full game (data/balance.tres) keeps all seven")
	var sim_ids: Array = []
	for i in Sim.strains_on_sale(b, 6, true):
		sim_ids.append(b.seeds[i].id)
	check(sim_ids == Array(FOUR), "the economy model plants the four (%s)" % [sim_ids])
	var metric_ids: Array = []
	for m: Dictionary in Sim.strain_metrics(b, Sim.SKILL_CAREFUL, 6, true):
		metric_ids.append(StringName(String(m["id"])))
	check(metric_ids == Array(FOUR), "and measures the four (%s)" % [metric_ids])
	var job := Contracts.build(Contracts.ID_STRAIN, {"team": 1, "round": 3, "strain": &"creeper", "reward": 60})
	check(String(job.get("strain", "")) == "budget" and not _names_off(String(job.get("text", ""))),
			"a strain job handed Creeper names the first strain on sale instead: '%s'" % job.get("text", ""))


# --- the supply window ------------------------------------------------------------------------------------------------

func _test_window(b: BalanceConfig) -> void:
	step("the supply window at 1280x720")
	var counter := world.room.get_station("ShopCounter") as ShopCounter
	if not check(counter != null, "the counter"):
		return
	teleport(me, counter)
	counter.interact(me)
	await wait_frames(8)   # the scroll fit settles over a few deferred sorts
	var ui := counter.get_shop_ui()
	if not check(ui != null and ui.is_open(), "the counter opens the SUPPLY WINDOW"):
		return
	var vp := ui.get_viewport().get_visible_rect().size
	check(vp == Vector2(1280, 720), "the viewport is %s" % vp)
	var cards := ui.get_cards(ShopCounter.KIND_SEED)
	var card_ids: Array = []
	for id in FOUR:
		if ui.get_card(ShopCounter.KIND_SEED, id) != null:
			card_ids.append(id)
	check(cards.size() == 4 and card_ids.size() == 4, "four seed cards (%d): %s" % [cards.size(), card_ids])
	for id in OFF:
		check(ui.get_card(ShopCounter.KIND_SEED, id) == null, "no card for %s" % id)
	var grid := ui.find_child("SeedGrid", true, false) as GridContainer
	check(ui.is_one_row() and grid != null and grid.columns == 4, "one row of four (columns %d)" % (grid.columns if grid != null else -1))
	var panel := ui.find_child("Panel", true, false) as Control
	var scroll := ui.find_child("Scroll", true, false) as ScrollContainer
	var need := panel.get_combined_minimum_size()
	var rect := Rect2(panel.position, panel.size)
	check(need.x <= vp.x and need.y <= vp.y and Rect2(Vector2.ZERO, vp).encloses(rect),
			"the window fits the screen (needs %s, stands at %s)" % [need, rect])
	check(not scroll.get_v_scroll_bar().visible and not scroll.get_h_scroll_bar().visible, "no scroll bar")
	var inside := true
	for c in cards:
		var top := c.get_global_rect().position.y - scroll.get_global_rect().position.y
		if c.size.y <= 0.0 or (c.position.y + c.size.y) * 1.0 > scroll.size.y + 0.5 or top < -0.5:
			inside = false
	check(inside, "every card is inside the scroll area (%.0f px high, cards %.0f)" % [scroll.size.y, cards[0].size.y if not cards.is_empty() else 0.0])
	var hint := ui.get_node_or_null(^"Root/Panel/VBox/Footer/Hint") as Label
	check(hint != null and hint.text == ShopUI.HINT_DEFAULT, "the footer hint is the plain one ('%s')" % (hint.text if hint != null else "?"))
	for c in cards:
		var tag := c.find_child("TagLabel", true, false) as Label
		var title := c.find_child("NameLabel", true, false) as Label
		var desc := c.find_child("DescLabel", true, false) as Label
		check(_fits(tag) and _fits(title) and desc.get_line_count() <= 2,
				"%s: the name and '%s' are whole, the blurb is %d line(s)" % [c.item_id, tag.text, desc.get_line_count()])
	check(ui.get_card(ShopCounter.KIND_SEED, &"golden").get_buy_button().text == "FROM SHIFT 2"
			and ui.get_card(ShopCounter.KIND_SEED, &"nightshift").get_buy_button().text == "FROM SHIFT 3", "Golden Kush from shift 2, Night Shift from shift 3")
	var seeds_w := panel.size.x
	ui.show_tab(ShopUI.TAB_UPGRADES, false)
	await wait_frames(6)
	check(absf(panel.size.x - seeds_w) <= 2.0 and Rect2(Vector2.ZERO, vp).encloses(Rect2(panel.position, panel.size)) and not scroll.get_v_scroll_bar().visible,
			"FAVORS: the same window (%.0f px wide, seeds %.0f), no scroll bar" % [panel.size.x, seeds_w])
	ui.show_tab(ShopUI.TAB_SEEDS, false)
	ui.close(false)
	await wait_frames(1)

	step("nobody buys a strain that is off")
	var cash := GameState.money
	for id in OFF:
		var r := counter.server_buy_seed(me.peer_id, id)
		check(not bool(r["ok"]) and String(r["reason"]) == ShopCounter.REASON_UNKNOWN_SEED, "%s: refused ('%s')" % [id, r["reason"]])
	check(GameState.money == cash and me.get_held_item() == null, "nothing spent, nothing in hand")
	var jars := counter.get_node_or_null(^"Visual/Jars")
	var jar_ok := jars != null and jars.get_child_count() > 0
	if jars != null:
		for i in jars.get_child_count():
			var fill := jars.get_child(i).get_node_or_null(^"Fill") as MeshInstance3D
			var want := b.get_enabled_seeds()[i].color if i < 4 else Color.BLACK
			if fill == null or fill.material_override == null or not (fill.material_override as StandardMaterial3D).albedo_color.is_equal_approx(want):
				jar_ok = false
	check(jar_ok, "the jars on the counter hold strains on sale")


# --- the run ----------------------------------------------------------------------------------------------------------

func _test_run(b: BalanceConfig) -> void:
	for n in range(1, 7):
		step("shift %d" % n)
		if not check(GameState.is_playing() and GameState.round_number == n, "shift %d runs" % n):
			return
		var conditions := GameState.get_conditions()
		check(conditions.is_empty() and GameState.get_report_conditions().is_empty() and hud.get_condition_chip_texts().is_empty(),
				"no condition, no chip (%s)" % [conditions])
		var briefing := GameState.get_shift_briefing()
		check(Array(briefing) == BRIEFINGS[n], "the briefing: %s" % [briefing])
		var board_text := board.get_board_text()
		check(not _names_off(board_text) and not _names_off(String(GameState.contract.get("text", ""))),
				"the board and the job ('%s') name no strain that is off" % String(GameState.contract.get("text", "")))
		_roll_dice(b, n)
		if n == 6:
			await _test_half_time()
		GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
		await wait_frames(2)
		check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "shift %d paid" % n)
		if n < 6:
			GameState.request_next_round()
			await wait_frames(2)
	check(GameState.is_run_cleared(), "the run is cleared at shift 6")
	check(toast_seen("New at the window: Golden Kush.") and toast_seen("New at the window: Night Shift."), "the toasts: Golden Kush at 2, Night Shift at 3")
	var named_off := false
	for t in toasts:
		if _names_off(String(t[0])):
			named_off = true
	for line in Story.bark_log:
		if _names_off(line):
			named_off = true
	check(not named_off, "no toast and no line of the Boss names a strain that is off (%d toasts)" % toasts.size())
	var named: Array = _named.keys()
	named.sort()
	check(not named.is_empty() and named.all(func(id: Variant) -> bool: return FOUR.has(id)),
			"every die named only the four: %s" % [named])
	check(_buyers.has(&"nightshift") and _buyers.has(&"budget") and not OFF.any(func(id: StringName) -> bool: return _buyers.has(id)),
			"the buyer, forced on, wants the four and nothing else: %s" % [_buyers])


## Hundreds of rolls at shift `n`: the job's strain, the shortage's pick, and (conditions and the market forced on for
## the roll, then put back) the buyer and the market. Every strain named must be one of the four, on sale today.
func _roll_dice(b: BalanceConfig, n: int) -> void:
	var on_sale: Array[StringName] = []
	for id in FOUR:
		if int(UNLOCKS[id]) <= n:
			on_sale.append(id)
	var bad: PackedStringArray = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 2300 + n
	for i in DICE:
		var job_strain := StringName(str(GameState._career_context().get("strain", "")))
		_named[job_strain] = true
		if not on_sale.has(job_strain):
			bad.append("job:%s" % job_strain)
	var planted0: Dictionary = Events._planted.duplicate()
	var money0 := GameState.money
	for i in DICE:
		var planted := {}
		for s in b.seeds:
			if on_sale.has(s.id) or OFF.has(s.id): # a strain not sold yet is never planted; the three that are off get the most
				planted[s.id] = rng.randi_range(0, 3) + (5 if OFF.has(s.id) else 0)
		Events._planted = planted
		GameState.money = rng.randi_range(0, 400)
		var pick := Events.pick_shortage_strain()
		_named[pick] = true
		if not on_sale.has(pick):
			bad.append("shortage:%s" % pick)
	Events._planted = planted0
	GameState.money = money0
	var saved := [b.conditions_from_round, b.conditions_per_shift, b.market_swing]
	b.conditions_from_round = 1
	b.conditions_per_shift = 3
	b.market_swing = 0.15
	for i in DICE:
		var r := {}
		GameState._replay_roll(r, n, [])
		for id: StringName in r.get("conditions", []):
			if ShiftConditions.base_of(id) == ShiftConditions.ID_BUYER:
				var strain := ShiftConditions.param_of(id)
				_buyers[strain] = int(_buyers.get(strain, 0)) + 1
				_named[strain] = true
				if not on_sale.has(strain):
					bad.append("buyer:%s" % strain)
		for strain: StringName in (r.get("market", {}) as Dictionary):
			_named[strain] = true
			if not FOUR.has(strain):
				bad.append("market:%s" % strain)
	b.conditions_from_round = saved[0]
	b.conditions_per_shift = saved[1]
	b.market_swing = saved[2]
	check(bad.is_empty(), "%d jobs, %d shortages, %d rolls with the buyer and the market on: only %s (%s)" % [DICE, DICE, DICE, on_sale, bad.slice(0, 6)])


func _test_half_time() -> void:
	step("shift 6, the final notice: the half-time look raises nothing")
	check(GameState.is_final_shift() and hud.get_payment_title() == "FINAL NOTICE", "the final notice ('%s')" % hud.get_payment_title())
	var q0 := GameState.quota
	GameState.server_add_sale(int(q0 * 0.3), 1)
	var shift_len := float(GameState.get(&"_final_shift_len"))
	GameState.time_left = shift_len * 0.5 - 0.5
	await wait_frames(3)
	check(_looks == [[true, 0]] and GameState.quota == q0, "30%% deposited at half time: the look, nothing raised ($%d, %s)" % [GameState.quota, _looks])
	check(Story.bark_log.has(TEXT_HALF) and not Story.bark_log.has(TEXT_SHORT) and not toast_seen("Payment due up"),
			"the Boss says '%s' and nothing goes up" % TEXT_HALF)
	GameState.time_left = shift_len * 0.3
	await wait_frames(2)
	check(_looks.size() == 1, "the look happens once")


# --- the economy model ------------------------------------------------------------------------------------------------

func _test_economy(b: BalanceConfig) -> void:
	step("the economy model with the preset (four strains)")
	var teams := Sim.all_teams(b)
	print(Sim.format_runs(b, "M23 chill: four strains, no conditions, no half-time raise", {}, teams))
	for w in range(4):
		var careful: Dictionary = teams[0][w]
		check(int(careful["cleared"]) >= 4, "careful x%d clears its run (%d of 5; reached %d)" % [w + 1, int(careful["cleared"]), int(careful["reached"])])
	check(int(teams[1][3]["cleared"]) >= 3, "four average workers clear most of the time (%d of 5)" % int(teams[1][3]["cleared"]))
	check(int(teams[1][3]["reached"]) >= 4 and int(teams[1][2]["reached"]) >= 4, "three and four average workers reach the final notice (%d, %d of 5)" % [int(teams[1][2]["reached"]), int(teams[1][3]["reached"])])
	var raised := 0
	for row: Array in teams:
		for team: Dictionary in row:
			raised += int(team["raised"])
	check(raised == 0, "no final notice goes up at half time in the model (%d)" % raised)


# --- helpers ----------------------------------------------------------------------------------------------------------

static func _names_off(text: String) -> bool:
	for n in OFF_NAMES:
		if text.contains(n):
			return true
	return false


## A label's text needs no more than its width (no ellipsis).
static func _fits(label: Label) -> bool:
	if label == null:
		return false
	var need := label.get_theme_font(&"font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label.get_theme_font_size(&"font_size")).x
	return need <= label.size.x + 0.5


func _add_worker(id: int, worker_name: String) -> void:
	Net.players[id] = {"name": worker_name, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	world.server_spawn_player(id)
	Net.players_changed.emit()
