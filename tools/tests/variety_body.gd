extends "res://tools/tests/qa_base.gd"
## M16 variety suite (variety agent): the run code, the dice it seeds, the cover it moves, the menu's run row and the
## alley board's last line, on a single headless host (the lobby on, replay on, events on, one fake worker).
##   RunSeed: the alphabet, codes there and back, junk, the fold, the week, the streams (pinned values);
##   replay off: no seed, no code, layout 0, nothing seeded, no run line, the menu row hidden;
##   three whole runs: two with one code deal the same card shift by shift (conditions, market, payment due, job,
##   the order of the events and the gaps between them, the cover), a third with another code does not;
##   the state: the entry in the snapshot, the signal, garbage over the wire checked and clamped;
##   server_set_run_seed: WAITING only, the fold, the refusals; the dice each shift (every consumer's sub-seed, the
##   same kinds and lanes after the same seed); START OVER rolls a new run or keeps the asked-for code; a die a test
##   seeded stays the test's;
##   the cover: layout 0 is the scene to the bit, the nodes are moved and nothing else; for EVERY layout, from the
##   geometry: no piece in another or in a wall, raised pieces rest on something, the route graph and the doorways
##   clear, a worker's width at every spawn, arrival, marker, station front and along the Boss's and the collector's
##   walks, a spot behind cover for every drive-by lane (and the game's own round agrees with the measured cut), a
##   spot on the dock no raid eye sees (and the game's own raid leaves a bundle there and takes one in the open); the
##   layouts differ in which lanes the crates stop and in where the dock's safe corner is; a worker a crate lands on
##   is put back on their spawn;
##   the alley board's NEXT column ends with "Run 7K2M." after the job; the menu: the row, the hint, THIS WEEK, the
##   keyboard path as it was, hosting with a typed code.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/variety_body.gd
##       --port=7989 --replay --lobby --events --run=7K2M --round-sec=900 [--maps]
## --maps prints every layout's dock from above (what the raid sees). Every engine/script error fails the run unless
## announced (qa_base.gd).

const Geo := preload("res://tools/tests/variety_geo.gd")
const MENU_SCENE := "res://scenes/main_menu/main_menu.tscn"
const ROOM_SCENE := "res://scenes/world/room.tscn"
const CODE_A := "7K2M"
const CODE_B := "QX4T"
const SHIFTS := 4
const EVENTS_PER_SHIFT := 4
const BOB := 2
## The open dock in front of the roller door: every raid layout sees it.
const SPOT_DOCK_OPEN := Vector3(-1.6, 0.0, 14.2)

var _port: int = 7989
var _world: World
var _room: Room
var _board: AlleyBoard
var _geo: RefCounted
var _run_signals: int = 0
var _started: Array = []
var _ended: Array = []
var _maps: bool = false


func _run() -> void:
	_label = "variety"
	_port = port_arg(7989)
	_maps = Config.has_arg("maps")
	await get_tree().process_frame
	GameState.run_changed.connect(func() -> void: _run_signals += 1)
	Events.event_started.connect(func(k: StringName, _p: Dictionary) -> void: _started.append(k))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append(k))
	var b: BalanceConfig = Config.balance
	b.transition_fade_sec = 0.0
	b.end_round_on_quota_met = true
	Config.growth_speed_override = 0.0

	step("the launch")
	check(Config.replay_enabled and Config.lobby_enabled and Events.are_events_enabled(), "this suite runs with --replay --lobby --events")
	check(Config.run_code == CODE_A, "--run=%s reaches Config.run_code ('%s')" % [CODE_A, Config.run_code])

	_test_codes()
	_test_week()
	_test_streams()

	Config.replay_enabled = false
	if await _host("replay off"):
		await _test_off()
		await _leave()
	Config.replay_enabled = true

	var first := await _play_run(CODE_A, "run one")
	var second := await _play_run(CODE_A, "the same code again")
	var other := await _play_run(CODE_B, "another code")
	_test_runs(first, second, other)

	Config.run_code = CODE_A
	if await _host("the run"):
		await _test_state()
		await _test_board()
		await _test_set_seed()
		await _test_dice()
		await _test_wire()
		await _test_layouts()
		await _test_rescue()
		await _test_start_over()
		await _test_takeover()
		await _leave()
	await _test_menu()
	finish()


# --- RunSeed -----------------------------------------------------------------------------------------------------------

func _test_codes() -> void:
	step("RunSeed: codes")
	var alphabet := RunSeed.ALPHABET
	var unique: Dictionary = {}
	for i in alphabet.length():
		unique[alphabet[i]] = true
	var no_twins := true
	for twin in ["0", "O", "1", "I", "L"]:
		if alphabet.contains(twin):
			no_twins = false
	check(alphabet.length() == 31 and unique.size() == 31 and no_twins and alphabet == alphabet.to_upper(), "31 different characters, none of 0 O 1 I L (%s)" % alphabet)
	check(RunSeed.SEED_COUNT == 31 * 31 * 31 * 31 and RunSeed.CODE_LENGTH == 4, "four characters: %d codes" % RunSeed.SEED_COUNT)
	check(RunSeed.SCATTER_MUL * RunSeed.SCATTER_INV % RunSeed.SEED_COUNT == 1 and RunSeed.SCATTER_MUL % 31 != 0, "the scatter is undone by its inverse: every seed has one code")
	var round_trip := true
	var shape := true
	var seen: Dictionary = {}
	var samples: Array[int] = [1, 2, 3, 31, 32, 961, 12345, 500000, RunSeed.SEED_COUNT - 1, RunSeed.SEED_COUNT]
	for i in 6000:
		samples.append(1 + (i * 157) % RunSeed.SEED_COUNT)
	for s in samples:
		var code := RunSeed.to_code(s)
		if RunSeed.from_code(code) != s:
			round_trip = false
		if code.length() != 4:
			shape = false
		for i in code.length():
			if not alphabet.contains(code[i]):
				shape = false
		seen[code] = s
	var distinct: Dictionary = {}
	for s in samples:
		distinct[s] = true
	check(round_trip, "from_code(to_code(seed)) is the seed for %d seeds, the first and the last among them" % samples.size())
	check(shape and seen.size() == distinct.size(), "every code is four characters of the alphabet, and no two seeds share one")
	check(RunSeed.to_code(1) != RunSeed.to_code(2) and RunSeed.to_code(1).left(3) != RunSeed.to_code(2).left(3), "neighbouring seeds do not read as a counter (%s, %s)" % [RunSeed.to_code(1), RunSeed.to_code(2)])
	check(RunSeed.from_code(CODE_A) > 0 and RunSeed.to_code(RunSeed.from_code(CODE_A)) == CODE_A and RunSeed.from_code(CODE_B) > 0 and RunSeed.from_code(CODE_A) != RunSeed.from_code(CODE_B),
			"%s and %s are codes of two different seeds (%d, %d)" % [CODE_A, CODE_B, RunSeed.from_code(CODE_A), RunSeed.from_code(CODE_B)])
	check(RunSeed.from_code("7k2m") == RunSeed.from_code(CODE_A) and RunSeed.from_code("  7K 2m ") == RunSeed.from_code(CODE_A) and RunSeed.from_code("7k-2m") == RunSeed.from_code(CODE_A),
			"case, spaces and a dash are ignored")
	var junk_ok := true
	for junk in ["", " ", "7K2", "7K2MM", "0000", "7K2O", "7K21", "IIII", "7K2!", "seven", "7K2\n"]:
		if RunSeed.from_code(junk) != 0 or RunSeed.is_code(junk):
			junk_ok = false
			print("      junk read as a code: '%s'" % junk)
	check(junk_ok and RunSeed.is_code(CODE_A), "junk is 0: too short, too long, an O, a 1, a sign")
	check(RunSeed.to_code(0) == "" and RunSeed.to_code(-5) == "" and RunSeed.normalize(0) == 0 and RunSeed.normalize(-1) == 0, "no seed, no code")
	check(RunSeed.normalize(RunSeed.SEED_COUNT) == RunSeed.SEED_COUNT and RunSeed.normalize(RunSeed.SEED_COUNT + 1) == 1 and RunSeed.to_code(RunSeed.SEED_COUNT + 7) == RunSeed.to_code(7)
			and RunSeed.normalize(0x7FFFFFFFFFFFFFFF) >= 1, "a seed out of range folds into it")
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var rolls_ok := true
	for i in 500:
		var r := RunSeed.roll(rng)
		if r < 1 or r > RunSeed.SEED_COUNT:
			rolls_ok = false
	check(rolls_ok, "roll(): always a seed in range")
	# Pinned: a code has to mean the same run in every later build.
	check(RunSeed.from_code("7K2M") == 599610 and RunSeed.to_code(1) == "B5VP" and RunSeed.to_code(923521) == "W5R9", "pinned: 7K2M is seed %d, seed 1 is %s, the last seed is %s"
			% [RunSeed.from_code("7K2M"), RunSeed.to_code(1), RunSeed.to_code(923521)])


func _test_week() -> void:
	step("RunSeed: this week")
	var monday := int(Time.get_unix_time_from_datetime_string("2026-09-28T00:00:00"))
	var friday := int(Time.get_unix_time_from_datetime_string("2026-10-02T15:30:00"))
	var sunday_night := int(Time.get_unix_time_from_datetime_string("2026-10-04T23:59:59"))
	var week := RunSeed.weekly(friday)
	check(week >= 1 and week <= RunSeed.SEED_COUNT and RunSeed.to_code(week).length() == 4, "the week of 2 October 2026: seed %d, run %s" % [week, RunSeed.to_code(week)])
	check(RunSeed.weekly(monday) == week and RunSeed.weekly(sunday_night) == week, "Monday 00:00 to Sunday 23:59:59 UTC is one week")
	check(RunSeed.weekly(monday - 1) != week and RunSeed.weekly(sunday_night + 1) != week and RunSeed.weekly(monday - 1) != RunSeed.weekly(sunday_night + 1), "the second before and the second after are other weeks")
	var weeks: Dictionary = {}
	for i in 1040:
		weeks[RunSeed.weekly(monday + i * RunSeed.WEEK_SEC)] = true
	check(weeks.size() == 1040, "twenty years of weeks, no seed twice")
	check(RunSeed.weekly(0) == RunSeed.weekly(3 * 86400) and RunSeed.weekly(0) != RunSeed.weekly(4 * 86400) and RunSeed.weekly(-1) >= 1, "1 January 1970 was a Thursday: its week ends on the 4th")
	check(week == 729042, "pinned: that week is seed %d" % week)


func _test_streams() -> void:
	step("RunSeed: streams")
	var a := RunSeed.stream(599610, &"cover")
	check(a == RunSeed.stream(599610, &"cover") and a > 0, "the same seed and name give the same sub-seed (%d)" % a)
	var names: Array[StringName] = [&"cover", &"replay:1", &"replay:2", &"job:1", &"events:1", &"hostiles:1", &"spread:1", &"card", &"picks", &"spawn"]
	var subs: Dictionary = {}
	var positive := true
	for s in [1, 2, 599610, RunSeed.SEED_COUNT]:
		for n in names:
			var v := RunSeed.stream(s, n)
			subs[v] = true
			if v <= 0:
				positive = false
	check(subs.size() == 4 * names.size() and positive, "%d seed and name pairs, %d different positive sub-seeds" % [4 * names.size(), subs.size()])
	var counts: Array[int] = []
	counts.resize(Room.COVER_LAYOUTS.size())
	counts.fill(0)
	for s in range(1, 4001):
		counts[RunSeed.stream(s, &"cover") % Room.COVER_LAYOUTS.size()] += 1
	var even := true
	for c in counts:
		if c < 4000.0 / Room.COVER_LAYOUTS.size() * 0.8 or c > 4000.0 / Room.COVER_LAYOUTS.size() * 1.2:
			even = false
	check(even, "4000 seeds spread over the %d cover layouts evenly (%s)" % [Room.COVER_LAYOUTS.size(), counts])
	var x := RandomNumberGenerator.new()
	var y := RandomNumberGenerator.new()
	x.seed = RunSeed.stream(7, &"replay:1")
	y.seed = RunSeed.stream(7, &"replay:2")
	var same := 0
	for i in 64:
		if x.randi() == y.randi():
			same += 1
	check(same == 0, "two streams of one seed roll unrelated numbers")
	check(RunSeed.stream(599610, &"cover") == 5531166379566525558 and RunSeed.stream(1, &"replay:1") == 1242281881771903721, "pinned: two sub-seeds (%d, %d)"
			% [RunSeed.stream(599610, &"cover"), RunSeed.stream(1, &"replay:1")])


# --- replay off ------------------------------------------------------------------------------------------------------------

func _test_off() -> void:
	step("replay off: nothing")
	check(not GameState.is_replay_on() and GameState.phase == GameState.Phase.WAITING, "WAITING, replay off")
	check(GameState.get_run_seed() == 0 and GameState.get_run_code() == "" and GameState.get_run_cover() == 0 and _room.get_cover_layout() == 0, "no seed, no code, the scene's cover")
	var snap: Dictionary = GameState.call(&"_snapshot")
	check(snap.get("run") == {"seed": 0, "cover": 0}, "the state carries an empty run entry (%s)" % [snap.get("run")])
	check(Events.get(&"_card_rng") == null and Events.call(&"_card") == Events.get(&"_rng"), "the events roll with the dice they always had")
	var replay_seed := GameState.replay_rng.seed
	var spread_seed := GrowPlot.spread_rng.seed
	var signals0 := _run_signals
	GameState.server_set_run_seed(5)
	GameState.server_start_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.get_run_seed() == 0 and _run_signals == signals0, "server_set_run_seed does nothing; the shift starts without a run")
	check(GameState.replay_rng.seed == replay_seed and GrowPlot.spread_rng.seed == spread_seed and Events.get(&"_card_rng") == null, "nothing was seeded")
	check(_board.get_run_line() == "" and not "\n".join(_board.get_next_lines()).contains("Run "), "the board has no run line (%s)" % [_board.get_next_lines()])
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.get_run_seed() == 0 and _room.get_cover_layout() == 0, "START OVER: still nothing")


# --- whole runs ----------------------------------------------------------------------------------------------------------------

## Hosts with `code`, plays SHIFTS shifts the way the lobby does (the card is rolled in the alley, the shift is paid,
## the way back rolls the next) and writes down what each was dealt. Events are walked with Events.tick().
func _play_run(code: String, tag: String) -> Dictionary:
	var rec := {"code": "", "seed": 0, "cover": -1, "transforms": "", "shifts": []}
	Config.run_code = code
	if not await _host(tag):
		return rec
	rec["code"] = GameState.get_run_code()
	rec["seed"] = GameState.get_run_seed()
	rec["cover"] = GameState.get_run_cover()
	rec["transforms"] = _cover_text()
	var shifts: Array = rec["shifts"]
	for n in range(1, SHIFTS + 1):
		await wait_frames(3)   # the job is rolled a frame after the game starts waiting
		if not check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == n, "%s: waiting for shift %d" % [tag, n]):
			break
		var job := GameState.get_contract()
		var shift := {"conditions": str(GameState.get_conditions()), "market": _market_text(), "due": GameState.quota,
				"job": "%s / %s" % [job.get("id", ""), job.get("text", "")], "kinds": [], "gaps": []}
		GameState.server_start_round()
		var started0 := _started.size()
		var ended0 := _ended.size()
		var sim := 0.0
		while _started.size() - started0 < EVENTS_PER_SHIFT and sim < 900.0 and GameState.is_playing():
			Events.tick(0.25)
			sim += 0.25
			if _ended.size() > ended0:
				ended0 = _ended.size()
				(shift["gaps"] as Array).append(snappedf(Events.get_next_event_in(), 0.001))
		shift["kinds"] = _started.slice(started0)
		shifts.append(shift)
		print("      %s shift %d: %s" % [GameState.get_run_code(), n, shift])
		if not GameState.is_playing():
			check(false, "%s: shift %d ended by itself" % [tag, n])
			break
		GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
		await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "%s: shift %d paid" % [tag, n])
		if n < SHIFTS:
			GameState.server_return_to_lobby(false)
			await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "%s: back in the alley" % tag)
	await _leave()
	return rec


func _test_runs(first: Dictionary, second: Dictionary, other: Dictionary) -> void:
	step("one code, one run")
	var a: Array = first["shifts"]
	var b: Array = second["shifts"]
	var c: Array = other["shifts"]
	if not check(a.size() == SHIFTS and b.size() == SHIFTS and c.size() == SHIFTS, "three runs of %d shifts were played" % SHIFTS):
		return
	check(first["code"] == CODE_A and second["code"] == CODE_A and first["seed"] == RunSeed.from_code(CODE_A) and second["seed"] == first["seed"], "both runs were %s (seed %d)" % [CODE_A, first["seed"]])
	check(first["cover"] == second["cover"] and first["transforms"] == second["transforms"] and first["transforms"] != "", "the same cover layout (%d), piece for piece" % first["cover"])
	var events := 0
	var gaps := 0
	for n in SHIFTS:
		var x: Dictionary = a[n]
		var y: Dictionary = b[n]
		check(x["conditions"] == y["conditions"] and x["market"] == y["market"] and x["due"] == y["due"], "shift %d: the same conditions, market and payment due (%s, $%d)" % [n + 1, x["conditions"], x["due"]])
		check(x["job"] == y["job"] and String(x["job"]) != " / ", "shift %d: the same job (%s)" % [n + 1, x["job"]])
		check(x["kinds"] == y["kinds"] and (x["kinds"] as Array).size() == EVENTS_PER_SHIFT, "shift %d: the same events in the same order (%s)" % [n + 1, x["kinds"]])
		check(x["gaps"] == y["gaps"] and (x["gaps"] as Array).size() >= EVENTS_PER_SHIFT - 1, "shift %d: the same gaps between them (%s)" % [n + 1, x["gaps"]])
		events += (x["kinds"] as Array).size()
		gaps += (x["gaps"] as Array).size()
	check(a[0]["kinds"] != a[1]["kinds"] or a[0]["gaps"] != a[1]["gaps"], "a run's shifts are not copies of each other")
	check(other["code"] == CODE_B and other["seed"] != first["seed"], "the third run was %s" % CODE_B)
	var differing := 0
	var cards := 0
	for n in SHIFTS:
		for key in ["conditions", "market", "job", "kinds", "gaps"]:
			if n == 0 and (key == "conditions" or key == "market"):
				continue   # shift 1 is plain whatever the code
			cards += 1
			if a[n][key] != c[n][key]:
				differing += 1
	check(differing >= cards / 2 and a != c, "another code deals another run (%d of %d things differ)" % [differing, cards])
	var gaps_differ := false
	for n in SHIFTS:
		if a[n]["gaps"] != c[n]["gaps"]:
			gaps_differ = true
	check(gaps_differ, "and other gaps between its events")


# --- the state -------------------------------------------------------------------------------------------------------------

func _test_state() -> void:
	step("the run in the state")
	var want := RunSeed.from_code(CODE_A)
	check(GameState.is_replay_on() and GameState.get_run_seed() == want and GameState.get_run_code() == CODE_A, "hosted with %s: seed %d" % [CODE_A, GameState.get_run_seed()])
	var cover := int(RunSeed.stream(want, &"cover") % Room.COVER_LAYOUTS.size())
	check(GameState.get_run_cover() == cover and _room.get_cover_layout() == cover, "the cover is stream(seed, cover) of the layouts: %d, and the Room stands in it" % cover)
	var snap: Dictionary = GameState.call(&"_snapshot")
	check(snap.get("run") == {"seed": want, "cover": cover}, "the state dictionary carries it under 'run' (%s)" % [snap.get("run")])
	check(_run_signals >= 1, "run_changed was heard")
	var signals0 := _run_signals
	GameState.server_send_full_state(1)
	check(_run_signals == signals0 + 1 and GameState.get_run_seed() == want, "a full state re-emits the signal and changes nothing")


func _test_board() -> void:
	step("the alley board")
	await wait_frames(3)
	var lines := _board.get_next_lines()
	check(_board.get_run_line() == "Run %s." % CODE_A, "get_run_line(): '%s'" % _board.get_run_line())
	check(_board.get_job_line() != "" and lines.size() >= 4 and lines[lines.size() - 1] == "Run %s." % CODE_A and lines[lines.size() - 2] == _board.get_job_line(),
			"NEXT ends with the run after the job: %s" % [lines])
	_board.refresh()
	check(_board.get_shown_text(1).ends_with("Run %s." % CODE_A) and not _board.get_shown_text(1).contains("!"), "the column shows it last")
	check(_board.get_font_size() >= AlleyBoard.MIN_FONT_SIZE, "the type still fits (%d)" % _board.get_font_size())


func _test_set_seed() -> void:
	step("server_set_run_seed")
	var before := GameState.get_run_seed()
	var cover0 := GameState.get_run_cover()
	var target := _seed_for_cover((cover0 + 1) % Room.COVER_LAYOUTS.size(), 1000)
	var signals0 := _run_signals
	GameState.server_set_run_seed(target)
	check(GameState.get_run_seed() == target and GameState.get_run_code() == RunSeed.to_code(target) and _run_signals == signals0 + 1, "WAITING: the seed is %d, the code %s, one signal" % [target, GameState.get_run_code()])
	check(GameState.get_run_cover() == (cover0 + 1) % Room.COVER_LAYOUTS.size() and _room.get_cover_layout() == GameState.get_run_cover(), "the cover moved to layout %d in the same breath" % GameState.get_run_cover())
	check(_board.get_next_lines()[_board.get_next_lines().size() - 1] == "Run %s." % RunSeed.to_code(target), "the board follows")
	GameState.server_set_run_seed(RunSeed.SEED_COUNT + 5)
	check(GameState.get_run_seed() == 5, "a seed out of range is folded (%d)" % GameState.get_run_seed())
	signals0 = _run_signals
	GameState.server_set_run_seed(0)
	GameState.server_set_run_seed(-3)
	check(GameState.get_run_seed() == 5 and _run_signals == signals0, "0 and a negative seed are refused")
	GameState.server_set_run_seed(target)
	var layout := _room.get_cover_layout()
	GameState.server_start_round()
	GameState.server_set_run_seed(before)
	check(GameState.is_playing() and GameState.get_run_seed() == target and _room.get_cover_layout() == layout, "PLAYING: refused, the cover stays where it is")
	GameState.server_add_sale(GameState.quota, 1)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift is paid")
	GameState.server_set_run_seed(before)
	check(GameState.get_run_seed() == target, "after the shift: refused too")
	GameState.server_return_to_lobby(false)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "back in the alley")
	check(GameState.get_run_seed() == target and _room.get_cover_layout() == layout and GameState.round_number == 2, "a new shift keeps the run and its cover")


func _test_dice() -> void:
	step("the dice")
	var s := 4242
	GameState.server_set_run_seed(s)
	var r := GameState.round_number
	check(_dice_are(s, r), "WAITING for shift %d: every die has its sub-seed of %d" % [r, s])
	GameState.server_start_round()
	check(_dice_are(s, r), "the start does not seed the same shift twice")
	var previous := GameState.get_conditions()
	GameState.server_add_sale(GameState.quota, 1)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift is paid")
	GameState.server_return_to_lobby(false)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "back in the alley")
	check(GameState.round_number == r + 1 and _dice_seeds_are(s, r + 1), "the way back seeds shift %d's dice" % (r + 1))
	# The way back rolled the conditions and the market: the dice were seeded BEFORE that roll, so a fresh generator on
	# the same stream rolls the same card.
	var probe := RandomNumberGenerator.new()
	probe.seed = RunSeed.stream(s, StringName("replay:%d" % (r + 1)))
	var every: Array[StringName] = []
	var on_sale: Array[StringName] = []
	var mutating := false
	for def: SeedDef in Config.balance.seeds:
		every.append(def.id)
		if def.unlock_round <= r + 1:
			on_sale.append(def.id)
			if def.mutation_chance > 0.0:
				mutating = true
	var bal: BalanceConfig = Config.balance
	var want_conditions := ShiftConditions.roll(ShiftConditions.count_for_round(r + 1, bal.conditions_from_round, bal.conditions_per_shift), previous, probe, Events.are_events_enabled(), on_sale, mutating)
	var want_market := ShiftConditions.roll_market(probe, bal.market_swing, every, on_sale)
	check(GameState.get_conditions().size() >= 1 and want_conditions == GameState.get_conditions(), "shift %d's conditions are what stream(seed, replay:%d) rolls (%s)" % [r + 1, r + 1, GameState.get_conditions()])
	check(want_market.size() == every.size() and str(want_market) == str(GameState.get_market()), "and so is its market")

	step("Events.server_seed / Hostiles.server_seed")
	Events.server_seed(123)
	var kinds_a := _pick_kinds(40)
	var lanes_a := _fire_lanes(12)
	Events.server_seed(123)
	var kinds_b := _pick_kinds(40)
	var lanes_b := _fire_lanes(12)
	Events.server_seed(124)
	var kinds_c := _pick_kinds(40)
	var lanes_c := _fire_lanes(12)
	check(kinds_a == kinds_b and kinds_a != kinds_c, "the same seed picks the same forty kinds, another seed others")
	check(lanes_a == lanes_b and lanes_a != lanes_c, "and fires down the same twelve lanes")
	Events.server_seed(123)
	_fire_lanes(5)
	check(_pick_kinds(40) == kinds_a, "the picks do not move the card: five rounds fired, the same forty kinds")
	check(Events.call(&"_card") != Events.get(&"_rng"), "two dice: the card, the picks")
	Hostiles.server_seed(77)
	var hostile_rng: RandomNumberGenerator = Hostiles.get(&"_rng")
	var turn := hostile_rng.randf()
	Hostiles.server_seed(77)
	check(hostile_rng.seed == RunSeed.stream(77, &"spawn") and hostile_rng.randf() == turn, "Hostiles: the same seed, the same roll")


func _test_wire() -> void:
	step("what arrives over the wire")
	GameState.server_set_run_seed(4242)
	var seed0 := GameState.get_run_seed()
	var cover0 := GameState.get_run_cover()
	var last := Room.COVER_LAYOUTS.size() - 1
	var cases := [
		[{"seed": "abc", "cover": 99}, 0, last, "a string for a seed, a layout that does not exist"],
		[{"seed": -7, "cover": -3}, 0, 0, "negative numbers"],
		[{"seed": RunSeed.SEED_COUNT + 9, "cover": 1.5}, RunSeed.SEED_COUNT, 0, "a seed too large, a fraction for a layout"],
		[{}, 0, 0, "an empty entry"],
		[{"seed": 77, "cover": 1}, 77, 1, "a good entry"],
	]
	for case: Array in cases:
		var s: Dictionary = GameState.call(&"_snapshot")
		s["run"] = case[0]
		GameState._rpc_state(s)
		GameState.set(&"_authoritative", true)   # a direct call looks like a remote sender; this peer is still the host
		check(GameState.get_run_seed() == int(case[1]) and GameState.get_run_cover() == int(case[2]) and _room.get_cover_layout() == int(case[2]),
				"%s: seed %d, layout %d" % [case[3], GameState.get_run_seed(), GameState.get_run_cover()])
	for odd: Variant in ["junk", 5, null]:
		var s: Dictionary = GameState.call(&"_snapshot")
		s["run"] = odd
		GameState._rpc_state(s)
		GameState.set(&"_authoritative", true)
	var none: Dictionary = GameState.call(&"_snapshot")
	none.erase("run")
	GameState._rpc_state(none)
	GameState.set(&"_authoritative", true)
	check(GameState.get_run_seed() == 77 and GameState.get_run_cover() == 1, "an entry that is no dictionary, or none at all (an older host): things stay as they are")
	GameState.server_set_run_seed(seed0)
	check(GameState.get_run_seed() == seed0 and GameState.get_run_cover() == cover0, "the host's own state puts it right")
	await wait_frames(1)


# --- the cover ---------------------------------------------------------------------------------------------------------------------

func _test_layouts() -> void:
	step("cover: the layouts")
	var count := Room.COVER_LAYOUTS.size()
	check(count >= 4 and (Room.COVER_LAYOUTS[0] as Dictionary).is_empty(), "%d layouts; layout 0 names no piece: it is the scene" % count)
	var known: Dictionary = {}
	for path in Room.COVER_NODES:
		known[String(path)] = true
	var nodes := _room.get_cover_nodes()
	check(nodes.size() == Room.COVER_NODES.size() and nodes.size() == 19, "every one of the %d cover nodes exists" % Room.COVER_NODES.size())
	var tables_ok := true
	for i in count:
		var table: Dictionary = Room.COVER_LAYOUTS[i]
		for key: Variant in table:
			var value: Variant = table[key]
			if not known.has(String(key)) or not (value is Array) or (value as Array).size() != 2 or not ((value as Array)[0] is Vector3) or not ((value as Array)[1] is float):
				tables_ok = false
				print("      layout %d: bad entry %s" % [i, key])
	check(tables_ok, "every entry names a cover node and gives it a place and a yaw")
	var identity := _identity_text()
	var colliders := _count(_room, "CollisionShape3D")
	var total := _count(_room.get_node(^"Decor"), "") + _count(_room.get_node(^"Hall"), "") + _count(_room.get_node(^"Dock"), "")

	# The floor with no loose cover at all: what the van and the walls hide by themselves.
	for node in nodes:
		node.position.y += 100.0
	await _settle()
	_geo = Geo.new(_room)
	var bare: Dictionary = _geo.dock_hidden()
	_room.apply_cover_layout(_room.get_cover_layout())

	var scene_room := (load(ROOM_SCENE) as PackedScene).instantiate() as Room
	var cuts: Array = []
	var hidden_sets: Array = []
	var moved_counts: Array = []
	for i in count:
		step("cover: layout %d" % i)
		GameState.server_set_run_seed(_seed_for_cover(i, 1))
		await _settle()
		if not check(GameState.get_run_cover() == i and _room.get_cover_layout() == i, "a seed of layout %d: the Room stands in it (run %s is one)" % [i, GameState.get_run_code()]):
			continue
		var moved := 0
		var exact := true
		for path in Room.COVER_NODES:
			var here := _room.get_node(path) as Node3D
			var there := scene_room.get_node(path) as Node3D
			if here.transform != there.transform:
				exact = false
			if here.position.distance_to(there.position) > 1.0:
				moved += 1
		moved_counts.append(moved)
		if i == 0:
			check(exact, "layout 0 is the scene's transforms, to the bit")
		else:
			check(moved >= 6, "%d pieces stand more than a metre from where the scene has them" % moved)
		check(_identity_text() == identity and _count(_room, "CollisionShape3D") == colliders and _count(_room.get_node(^"Decor"), "") + _count(_room.get_node(^"Hall"), "") + _count(_room.get_node(^"Dock"), "") == total,
				"the same nodes under the same parents; no node and no collider added or freed")
		_expect_none("no piece sits in another, in a wall or in a prop", _geo.solid_overlaps())
		_expect_none("every raised piece rests on one below it", _geo.unsupported())
		_expect_none("the route graph is clear by ROUTE_MARGIN and by a body's width", _geo.blocked_route_edges())
		_expect_none("the three doorways are clear", _geo.blocked_doorways())
		_expect_none("a worker's width at every spawn, arrival, marker and station front, along the Boss's walks and the collector's", _geo.blocked_spots())
		var lanes: Array = _geo.lanes()
		var cut_text := PackedStringArray()
		var by_cover := 0
		var open_into_main := 0
		var spots := 0
		var agrees := true
		var standing_safe := true
		var bob := _world.get_player(BOB)
		var all_lanes: Array = _room.get_gunfire_lanes()
		for lane: Dictionary in lanes:
			var index: int = lane["index"]
			var cut: Dictionary = lane["cut"]
			if bool(lane["by_cover"]):
				by_cover += 1
				cut_text.append(str(index))
			var from: Vector3 = all_lanes[index]["from"]
			var to: Vector3 = all_lanes[index]["to"]
			if not bool(cut["blocked"]) and _room.get_area_index(from) == 2 and _room.get_area_index(to) == 0:
				open_into_main += 1
			var spot: Vector3 = lane["spot"]
			if spot.is_finite():
				spots += 1
				bob.place_at(Transform3D(Basis.IDENTITY, Vector3(spot.x, 0.05, spot.z)))
				for other: Dictionary in all_lanes:
					if (Events.server_fire_lane(other).get("workers", []) as Array).has(BOB):
						standing_safe = false
			var fired := Events.server_fire_lane(all_lanes[index])
			if (fired["end"] as Vector3).distance_to(cut["end"]) > 0.01 or bool(fired["blocked"]) != bool(cut["blocked"]):
				agrees = false
			print("      lane %d: %s; the spot behind cover %s, %.2f m off the line, behind %s" % [index,
					("stopped by %s %.1f m in" % [(cut["collider"] as Node).name, from.distance_to(cut["end"])]) if bool(cut["blocked"]) else "open to its end",
					spot, lane["spot_distance"], lane["spot_cover"]])
		bob.place_at(_world.get_lobby_transform(bob.spawn_index))
		check(spots == lanes.size() and lanes.size() == 6, "each of the %d drive-by lanes has a spot behind cover within %.0f m of its line" % [lanes.size(), Geo.LANE_REACH])
		check(standing_safe, "a worker standing on any of those spots is hit by no round of any lane (Events.server_fire_lane)")
		check(agrees, "the game's own rounds stop where the measurement says")
		check(by_cover >= 2 and open_into_main >= 1, "the crates stop %d lanes (%s); %d cross into the main room with nothing in the way" % [by_cover, ",".join(cut_text), open_into_main])
		cuts.append(",".join(cut_text))
		var hidden: Dictionary = _geo.dock_hidden()
		var made: Dictionary = {}
		for cell: Vector2i in hidden:
			if not bare.has(cell):
				made[cell] = true
		hidden_sets.append(made)
		check(hidden.size() >= 1 and made.size() >= 1, "the dock has %d floor cells no raid eye sees, %d of them made by the cover (around %s)" % [hidden.size(), made.size(), _geo.cells_centre(made)])
		if _maps:
			print(_geo.dock_map(hidden))
		if not made.is_empty():
			var safe: Vector3 = _geo.dock_cell_position(_middle_cell(made))
			var seed_def: SeedDef = Config.balance.get_seed(&"budget")
			var kept := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed_def.id, "amount": 1}, safe, 0)
			var lost := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed_def.id, "amount": 1}, SPOT_DOCK_OPEN, 0)
			await wait_frames(2)
			var kept_name := String(kept.name)
			var lost_name := String(lost.name)
			var taken: Array = []
			for eye in 3:
				taken.append_array(Events.server_raid_sweep(eye)["taken"])
			check(taken.has(lost_name) and not taken.has(kept_name) and is_instance_valid(kept) and kept.is_inside_tree(), "the game's own raid: three looks take the bundle in front of the roller door and leave the one at %s" % safe)
			for item in items_of(Const.ITEM_PRODUCT):
				_world.items.server_despawn_item(item)
			await wait_frames(1)
	scene_room.free()

	step("cover: the layouts differ")
	var cut_sets: Dictionary = {}
	for c: String in cuts:
		cut_sets[c] = true
	check(cuts.size() == count and cut_sets.size() == count, "no two layouts stop the same lanes (%s)" % [cuts])
	var corners_ok := hidden_sets.size() == count
	for i in hidden_sets.size():
		for j in range(i + 1, hidden_sets.size()):
			var shared := 0
			for cell: Vector2i in hidden_sets[i]:
				if (hidden_sets[j] as Dictionary).has(cell):
					shared += 1
			var smaller := mini((hidden_sets[i] as Dictionary).size(), (hidden_sets[j] as Dictionary).size())
			var apart := (_geo.cells_centre(hidden_sets[i]) as Vector3).distance_to(_geo.cells_centre(hidden_sets[j]))
			if shared * 2 > smaller or apart < 2.0:
				corners_ok = false
				print("      layouts %d and %d: %d of %d hidden cells shared, centres %.1f m apart" % [i, j, shared, smaller, apart])
	check(corners_ok, "the dock's safe corner is somewhere else in every layout: no two share half their hidden cells, the middles are 2 m apart or more")

	step("cover: the Room's own API")
	GameState.server_set_run_seed(_seed_for_cover(0, 1))
	await _settle()
	var layout := _room.get_cover_layout()
	_room.apply_cover_layout(99)
	_room.apply_cover_layout(-1)
	check(_room.get_cover_layout() == layout and layout == 0, "a layout that does not exist is refused")
	var crate := _room.get_node(^"Dock/CrateMidA") as Node3D
	check(_room.is_in_cover(crate.global_position) and _room.is_in_cover(crate.global_position + Vector3(0.8, 0.0, 0.0), 0.5) and not _room.is_in_cover(crate.global_position + Vector3(0.0, 0.0, -1.4), 0.3)
			and not _room.is_in_cover(Vector3.INF), "is_in_cover(): on a crate, within the margin of one, on the open floor")
	check(_room.get_cover_footprints().size() == 19, "get_cover_footprints(): one rectangle a piece")


## A worker a crate lands on is put back on their spawn point; everybody else stays.
func _test_rescue() -> void:
	step("cover: a crate lands where a worker stands")
	var bob := _world.get_player(BOB)
	var me: Player = Game.local_player
	var target := 1
	var table: Dictionary = Room.COVER_LAYOUTS[target]
	var landing: Vector3 = (table["Dock/CrateMidA"] as Array)[0]
	bob.place_at(Transform3D(Basis.IDENTITY, Vector3(landing.x, 0.05, landing.z)))
	var mine := me.global_position
	check(not _room.is_in_cover(bob.global_position, Room.COVER_BODY_MARGIN), "layout 0: Bob stands on open floor at %s" % landing)
	GameState.server_set_run_seed(_seed_for_cover(target, 1))
	await _settle()
	var home := _world.get_spawn_transform(bob.spawn_index).origin
	check(_room.get_cover_layout() == target and bob.global_position.distance_to(home) < 0.2 and not _room.is_in_cover(bob.global_position, Room.COVER_BODY_MARGIN),
			"layout %d puts a crate there: Bob is on his spawn point (%s)" % [target, bob.global_position])
	check(me.global_position.distance_to(mine) < 0.5, "the host, in the alley, was not moved")
	bob.place_at(_world.get_lobby_transform(bob.spawn_index))


func _test_start_over() -> void:
	step("START OVER")
	Config.run_code = ""
	var old := GameState.get_run_seed()
	var signals0 := _run_signals
	GameState.server_return_to_lobby(true)
	await wait_until(func() -> bool: return GameState.get_run_seed() != old and GameState.phase == GameState.Phase.WAITING, 5.0, "no code asked for: the reset rolls another run")
	var rolled := GameState.get_run_seed()
	check(rolled >= 1 and rolled <= RunSeed.SEED_COUNT and GameState.get_run_code() == RunSeed.to_code(rolled) and GameState.get_run_code().length() == 4, "a seed in range (%d, %s)" % [rolled, GameState.get_run_code()])
	check(GameState.get_run_cover() == int(RunSeed.stream(rolled, &"cover") % Room.COVER_LAYOUTS.size()) and _room.get_cover_layout() == GameState.get_run_cover() and _run_signals > signals0, "its cover, and the signal")
	check(GameState.round_number == 1 and _dice_are(rolled, 1), "shift 1's dice are the new run's")
	Config.run_code = CODE_B
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.get_run_code() == CODE_B and _dice_are(RunSeed.from_code(CODE_B), 1), "with a code asked for, START OVER deals that run again (%s)" % GameState.get_run_code())
	Config.run_code = "0O1I"
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.get_run_seed() >= 1 and GameState.get_run_code() != "" and GameState.get_run_code() != CODE_B, "junk for a code is ignored: a random run (%s)" % GameState.get_run_code())
	Config.run_code = CODE_A


## Run last: from here on replay_rng is the test's.
func _test_takeover() -> void:
	step("a die a test seeded stays the test's")
	GameState.server_reset_game()
	await wait_frames(2)
	check(_dice_are(RunSeed.from_code(CODE_A), 1), "before: the run seeds all five")
	GameState.replay_rng.seed = 7
	GrowPlot.spread_rng.seed = 9
	GameState.server_start_round()
	GameState.server_add_sale(GameState.quota, 1)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift is paid")
	GameState.server_return_to_lobby(false)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == 2, 5.0, "shift 2 is set up")
	check(GameState.replay_rng.seed == 7 and GrowPlot.spread_rng.seed == 9, "replay_rng and spread_rng were left alone")
	check(int(GameState.get(&"_career_rng").seed) == RunSeed.stream(RunSeed.from_code(CODE_A), &"job:2"), "the others were seeded for shift 2")


# --- the menu -------------------------------------------------------------------------------------------------------------------

func _test_menu() -> void:
	step("the menu: the run row")
	Config.run_code = "7k 2m"
	var menu: Control = (load(MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await wait_frames(3)
	var row: Control = menu.get_node_or_null("%RunRow")
	var edit: LineEdit = menu.get_node_or_null("%RunEdit")
	var hint: Label = menu.get_node_or_null("%RunHint")
	var week: Button = menu.get_node_or_null("%WeekButton")
	var host_button: Button = menu.get_node("%HostButton")
	var join_button: Button = menu.get_node("%JoinButton")
	var port_spin: SpinBox = menu.get_node("%PortSpin")
	(menu.get_node("%NameEdit") as LineEdit).text = "Tester"
	if not check(row != null and edit != null and hint != null and week != null, "the host panel has %RunRow, %RunEdit, %RunHint, %WeekButton"):
		menu.queue_free()
		return
	check(row.visible and week.text == "THIS WEEK" and edit.placeholder_text == "Blank: random", "the row shows: a field ('%s') and '%s'" % [edit.placeholder_text, week.text])
	check(edit.text == "7k 2m" and String(menu.call(&"get_run_code")) == CODE_A and hint.text == "Run %s." % CODE_A, "it starts with the run that was asked for; '%s' reads as %s" % [edit.text, String(menu.call(&"get_run_code"))])
	edit.text = ""
	edit.text_changed.emit("")
	check(String(menu.call(&"get_run_code")) == "" and hint.text == "", "blank: no code, no hint")
	edit.text = "hello"
	edit.text_changed.emit("hello")
	check(String(menu.call(&"get_run_code")) == "" and hint.text == "Not a code. Random run." and not hint.text.contains("!"), "junk: ignored, with a flat hint ('%s')" % hint.text)
	var before := RunSeed.to_code(RunSeed.weekly(int(Time.get_unix_time_from_system())))
	week.pressed.emit()
	var after := RunSeed.to_code(RunSeed.weekly(int(Time.get_unix_time_from_system())))
	check((edit.text == before or edit.text == after) and String(menu.call(&"get_run_code")) == edit.text and hint.text == "Run %s." % edit.text, "THIS WEEK fills in the week's code (%s)" % edit.text)
	check(get_viewport().gui_get_focus_owner() == host_button, "the keyboard starts on Open the floor, as before")
	var port_line := port_spin.get_line_edit()
	check(port_line.find_next_valid_focus() == host_button and host_button.find_next_valid_focus() == join_button, "Tab: Port, Open the floor, Report for shift, as before")
	check(join_button.find_next_valid_focus() == edit and edit.find_next_valid_focus() == week and week.find_prev_valid_focus() == edit and edit.find_prev_valid_focus() == join_button,
			"the run field and THIS WEEK come after them")
	var texts := "%s %s %s %s" % [edit.placeholder_text, week.text, "Run code", hint.text]
	check(not texts.contains("!"), "no exclamation marks")

	step("the menu: hosting with a typed code")
	edit.text = "qx4t"
	edit.text_changed.emit("qx4t")
	menu.call(&"_begin_host", false)
	check(Config.run_code == CODE_B and not edit.editable and week.disabled, "Open the floor hands %s to Config.run_code and locks the row" % Config.run_code)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null and GameState.phase == GameState.Phase.WAITING, 8.0, "the floor is open")
	check(GameState.get_run_code() == CODE_B and GameState.get_run_seed() == RunSeed.from_code(CODE_B), "the run is %s" % GameState.get_run_code())
	await _leave(true)
	var back: Control = get_tree().get_first_node_in_group(Game.MENU_GROUP)
	check(back != null and (back.get_node("%RunEdit") as LineEdit).text == CODE_B, "back in the menu the field still holds the run")
	if back != null:
		back.queue_free()
	await wait_frames(2)
	Config.replay_enabled = false
	var plain: Control = (load(MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(plain)
	await wait_frames(2)
	check(not (plain.get_node("%RunRow") as Control).visible, "replay off: the row is hidden")
	plain.queue_free()
	Config.replay_enabled = true
	await wait_frames(2)


# --- helpers ---------------------------------------------------------------------------------------------------------------------

func _host(tag: String) -> bool:
	step("hosting (%s)" % tag)
	Game.start_host("Tester", _port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "%s: world + local player exist" % tag)
	if Game.world == null or Game.local_player == null:
		return false
	_world = Game.world
	_room = _world.room
	_board = _world.lobby.get_board() if _world.lobby != null else null
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[1]}
	_world.server_spawn_player(BOB)
	await wait_frames(3)
	return check(_board != null and _world.get_player(BOB) != null and GameState.phase == GameState.Phase.WAITING, "%s: WAITING in the alley, the board and a fake worker exist" % tag)


func _leave(keep_menu: bool = false) -> void:
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and Game.world == null, 5.0, "back in the menu")
	check(GameState.get_run_seed() == 0 and GameState.get_run_code() == "" and GameState.get_run_cover() == 0, "the menu has no run")
	if not keep_menu:
		for menu in get_tree().get_nodes_in_group(Game.MENU_GROUP):
			menu.queue_free()
	await wait_frames(2)


func _settle() -> void:
	for i in 3:
		await get_tree().physics_frame


## The first seed from `from` up whose cover is layout `index`.
func _seed_for_cover(index: int, from: int) -> int:
	var s := from
	while int(RunSeed.stream(s, &"cover") % Room.COVER_LAYOUTS.size()) != index:
		s += 1
	return s


## The dice's seeds only (after a roll the generators have moved on, their seeds have not).
func _dice_seeds_are(run_seed: int, round_n: int) -> bool:
	return _dice_are(run_seed, round_n)


func _dice_are(run_seed: int, round_n: int) -> bool:
	var events_seed := RunSeed.stream(run_seed, StringName("events:%d" % round_n))
	var card: RandomNumberGenerator = Events.get(&"_card_rng")
	var picks: RandomNumberGenerator = Events.get(&"_rng")
	var hostile: RandomNumberGenerator = Hostiles.get(&"_rng")
	var job: RandomNumberGenerator = GameState.get(&"_career_rng")
	var want := {
		"replay": [GameState.replay_rng.seed, RunSeed.stream(run_seed, StringName("replay:%d" % round_n))],
		"spread": [GrowPlot.spread_rng.seed, RunSeed.stream(run_seed, StringName("spread:%d" % round_n))],
		"job": [job.seed, RunSeed.stream(run_seed, StringName("job:%d" % round_n))],
		"card": [card.seed if card != null else 0, RunSeed.stream(events_seed, &"card")],
		"picks": [picks.seed, RunSeed.stream(events_seed, &"picks")],
		"hostiles": [hostile.seed, RunSeed.stream(RunSeed.stream(run_seed, StringName("hostiles:%d" % round_n)), &"spawn")],
	}
	var ok := true
	for key: String in want:
		if int(want[key][0]) != int(want[key][1]):
			ok = false
			print("      %s dice: seed %d, expected %d" % [key, want[key][0], want[key][1]])
	return ok


func _pick_kinds(n: int) -> Array:
	var out: Array = []
	var previous: StringName = &""
	for i in n:
		previous = Events.pick_kind(previous)
		out.append(previous)
	return out


func _fire_lanes(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Events.server_fire_random_lane().get("end", Vector3.ZERO))
	return out


func _market_text() -> String:
	var market := GameState.get_market()
	var keys: Array = market.keys()
	keys.sort_custom(func(x: Variant, y: Variant) -> bool: return String(x) < String(y))
	var parts := PackedStringArray()
	for k: Variant in keys:
		parts.append("%s=%.2f" % [k, float(market[k])])
	return ",".join(parts)


## Every cover piece's place, as one line.
func _cover_text() -> String:
	var parts := PackedStringArray()
	for node in _room.get_cover_nodes():
		parts.append("%s %s %.1f" % [node.name, node.global_position, rad_to_deg(node.global_rotation.y)])
	return "; ".join(parts)


## Which object each cover node is and whose child.
func _identity_text() -> String:
	var parts := PackedStringArray()
	for node in _room.get_cover_nodes():
		parts.append("%s#%d<%s#%d" % [node.name, node.get_instance_id(), node.get_parent().name, node.get_parent().get_instance_id()])
	return ",".join(parts)


func _count(node: Node, type_name: String) -> int:
	var n := 1 if type_name == "" or node.is_class(type_name) else 0
	for child in node.get_children():
		n += _count(child, type_name)
	return n


func _middle_cell(cells: Dictionary) -> Vector2i:
	var centre: Vector3 = _geo.cells_centre(cells)
	var best := Vector2i.ZERO
	var best_d := INF
	for cell: Vector2i in cells:
		var d := (_geo.dock_cell_position(cell) as Vector3).distance_to(centre)
		if d < best_d:
			best_d = d
			best = cell
	return best


func _expect_none(what: String, found: PackedStringArray) -> void:
	check(found.is_empty(), what)
	for line in found:
		print("      " + line)
