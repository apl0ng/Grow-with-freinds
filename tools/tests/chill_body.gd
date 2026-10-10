extends "res://tools/tests/smoke_base.gd"
## M20 chill: the simpler, calmer game a windowed run plays by default (scripts/core/chill.gd), on a solo host with
## `--chill --replay --run=B5VP`: the preset's values on Config.balance, the event mix (only the chill kinds ever come
## up), the payment, at most one shift condition, no market, plants that walk off half as often; then the economy
## model with the preset: careful crews of every size clear their run, four average workers clear most of the time.

const Sim := preload("res://tools/tests/econ_sim.gd")
const FULL_PATH := "res://data/balance.tres"


func _run() -> void:
	_label = "chill"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance

	step("the preset")
	check(Config.chill_enabled, "--chill: Config.chill_enabled")
	var wrong: PackedStringArray = []
	for key: StringName in Chill.VALUES:
		if not is_equal_approx(float(b.get(key)), float(Chill.VALUES[key])):
			wrong.append("%s=%s" % [key, b.get(key)])
	check(wrong.is_empty(), "every chill value is on Config.balance %s" % [wrong])
	# A fresh load: the cached resource is the one the preset changed.
	var full := ResourceLoader.load(FULL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as BalanceConfig
	var halved := true
	for i in b.seeds.size():
		var want := full.seeds[i].mutation_chance * Chill.MUTATION_SCALE
		if not is_equal_approx(b.seeds[i].mutation_chance, want):
			halved = false
	check(halved, "every strain walks off half as often")

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

	step("the payment and the card")
	var off: PackedStringArray = []
	for n in range(1, 7):
		for w in range(1, 5):
			if absi(b.quota_for_round(n, w) - roundi(full.quota_for_round(n, w) * 0.85)) > 1:
				off.append("shift %d x%d: $%d, full $%d" % [n, w, b.quota_for_round(n, w), full.quota_for_round(n, w)])
	check(off.is_empty(), "every payment (shifts 1-6, 1-4 workers) is 85%% of the full game's %s" % [off])
	check(b.quota_for_round(1, 1) == roundi(full.quota_for_round(1, 1) * 0.85), "shift 1 alone: $%d (the full game $%d)" % [b.quota_for_round(1, 1), full.quota_for_round(1, 1)])
	var counts := []
	for n in range(1, 8):
		counts.append(ShiftConditions.count_for_round(n, b.conditions_from_round, b.conditions_per_shift, b.conditions_extra_from_round))
	check(counts == [0, 0, 1, 1, 1, 1, 1], "conditions: none before shift 3, never two at once (%s)" % [counts])

	step("hosting")
	Game.start_host("Tester", port_arg(7905))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "a shift runs")
	var flat := true
	for id: Variant in GameState.get_market():
		if not is_equal_approx(float(GameState.get_market()[id]), 1.0):
			flat = false
	check(flat, "no market: every strain deposits at its own price (%s)" % [GameState.get_market()])
	check(GameState.quota == b.quota_for_round(1, 1), "the shift's payment is the chill one ($%d)" % GameState.quota)

	step("the economy model with the preset")
	var teams := Sim.all_teams(b)
	for w in range(4):
		var careful: Dictionary = teams[0][w]
		check(int(careful["cleared"]) >= 4, "careful x%d clears its run (%d of 5)" % [w + 1, int(careful["cleared"])])
	check(int(teams[1][3]["cleared"]) >= 3, "four average workers clear most of the time (%d of 5)" % int(teams[1][3]["cleared"]))
	check(int(teams[1][3]["reached"]) >= 4 and int(teams[1][2]["reached"]) >= 4, "three and four average workers reach the final notice (%d, %d of 5)" % [int(teams[1][2]["reached"]), int(teams[1][3]["reached"])])
	finish()
