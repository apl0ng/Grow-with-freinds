extends "res://tools/tests/qa_base.gd"
## M16 polish suite (polish agent): three more jobs, the cap on walking plants, the sound of a plant uprooting, and the
## empty flamethrower that no longer lies about for ever. A single headless host with one fake worker (Bob: a
## host-side body without an owning peer, so the SERVER side runs directly on him).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/polish_body.gd --replay --events --career-file=user://polish_test_7991.cfg --port=7991 --round-sec=900
## The run REFUSES to start without --career-file (replay is on: it must never touch a real record) and removes its
## files at the end. --events only makes this a session with events (the pool); the scheduler is kept quiet and every
## event here is started by hand.
## Pins:
##   catalog   twelve jobs; "variety", "keep" and "raid": copy, goals, judge, need, the pool (variety only with three
##             strains on sale, keep only when something can take a plant, raid only with events), the roll reaches
##             them and never repeats, HUD / report text
##   the cap   GrowPlot.get_mutation_chance: the strain's own chance on a plain day, twice that in a twitchy batch,
##             never past Config.balance.mutation_chance_cap (Night Shift 0.70 -> 0.50), a strain set above the cap
##             keeps its own; seeded rolls on a real tray
##   variety   distinct strains count once each, wet or cured, whoever deposits; met on the third; paid once
##   keep      a harvest and an empty tray are no loss; fire, eaten, collected, a counted strain and a plant that
##             walks off each fail it; judged at the end: paid with the payment made, failed without
##   raid      a raid cut short settles nothing; a raid that looks and takes nothing pays when it ends (and is not
##             swapped at half time while it runs); one that takes a bundle fails it; no raid by half time: swapped
##   uproot    the sound exists with a recipe of its own; a plant walking off plays `uproot`, not `harvest`; a harvest
##             still plays `harvest`
##   flame     an empty flamethrower lying on the floor is removed after empty_flamethrower_sec through the item
##             manager; fuel, hands and flight reset the wait; 0 turns the rule off; the cabinet's restock and the
##             Boss keeping a back-room worker's flamethrower are untouched
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const FAR_A := Vector3(-8.0, 0.0, 5.0)
const FAR_B := Vector3(-8.0, 0.0, 3.0)
const SPOT_OPEN := Vector3(-3.0, 0.0, 3.0)   # the open floor of the main room: in sight of the raid
const LANE := Vector3(-3.0, 0.0, 4.5)        # a clear lane facing -Z (the flame suite throws from here)

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var chute: TurnInStation
var cabinet: EmergencyCabinet
var hud: HUD
var _path: String = ""
var _met: Array = []
var _failed: Array = []
var _offered: Array = []
var _removed: Array = []     # item types, per ItemManager.item_removed
var _chances: Dictionary = {}


func _run() -> void:
	_label = "polish"
	await get_tree().process_frame
	get_tree().root.size = Vector2i(1280, 720)
	var b: BalanceConfig = Config.balance
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent,
			"this run has its own career file (%s)" % _path):
		finish(); return
	check(Config.replay_enabled and Events.are_events_enabled(), "this suite runs with --replay --events")
	_remove(_path)
	Career.clear_record()
	GameState.contract_met.connect(func(c: Dictionary) -> void: _met.append(c))
	GameState.contract_failed.connect(func(c: Dictionary) -> void: _failed.append(c))
	GameState.contract_offered.connect(func(c: Dictionary, swapped: bool) -> void: _offered.append([c, swapped]))

	_test_catalog(b)
	_test_sound()

	step("hosting")
	for s: SeedDef in b.seeds:
		_chances[s.id] = s.mutation_chance
	b.end_round_on_quota_met = false
	Game.start_host("Tester", port_arg(7991))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		_cleanup(); finish(); return
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	Net.players_changed.emit()
	await wait_frames(3)
	chute = room.get_station("TurnInStation") as TurnInStation
	cabinet = room.get_station("EmergencyCabinet") as EmergencyCabinet
	if not check(bob != null and chute != null and cabinet != null and hud != null, "Bob, the chute, the cabinet and the HUD exist"):
		_cleanup(); finish(); return
	items.item_removed.connect(func(item: Item) -> void: _removed.append(item.item_type))
	_put(bob, FAR_B)
	_put_me(FAR_A)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 running")
	await wait_frames(2)
	_quiet()
	GameState.server_add_money(500)
	await wait_frames(1)

	await _test_cap(b)
	# Nothing turns by itself from here: this run decides when a plant walks.
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	await _test_session_pool(b)
	await _test_variety(b)
	await _test_keep(b)
	await _test_uproot(b)
	await _test_raid(b)
	await _test_flamethrower(b)
	await _test_wire()
	await _test_keep_at_the_end(b)
	for s: SeedDef in b.seeds:
		s.mutation_chance = float(_chances[s.id])
	_cleanup()
	finish()


# --- the catalog ------------------------------------------------------------------------------------------------------

func _test_catalog(b: BalanceConfig) -> void:
	step("catalog: three more jobs")
	var ids := Contracts.ids()
	check(ids.size() == 12 and ids.has(&"variety") and ids.has(&"keep") and ids.has(&"raid"), "twelve jobs, with 'variety', 'keep' and 'raid' (%d)" % ids.size())
	check(Contracts.ID_VARIETY == &"variety" and Contracts.ID_KEEP == &"keep" and Contracts.ID_RAID == &"raid" and Contracts.NEED_RAID == &"raid" and Contracts.VARIETY_STRAINS == 3,
			"the ids, the need and the count are constants")
	var ctx := {"team": 1, "round": 1, "money": 150, "owed": 350, "reward": b.contract_reward}
	var variety := Contracts.build(&"variety", ctx)
	var keep := Contracts.build(&"keep", ctx)
	var raid := Contracts.build(&"raid", ctx)
	check(String(variety["text"]) == "one bundle each of three strains" and int(variety["goal"]) == 3 and int(variety["progress"]) == 0, "variety: '%s', 0 / 3" % variety["text"])
	check(String(keep["text"]) == "lose no plant this shift" and int(keep["goal"]) == 1, "keep: '%s'" % keep["text"])
	check(String(raid["text"]) == "a raid that takes nothing" and int(raid["goal"]) == 1, "raid: '%s'" % raid["text"])
	var flat := true
	for c: Dictionary in [variety, keep, raid]:
		var text := String(c["text"])
		if text.contains("!") or text.contains("%") or text != text.strip_edges() or int(c["reward"]) != b.contract_reward or bool(c["done"]) or bool(c["failed"]):
			flat = false
	check(flat, "flat copy, no exclamation mark, reward %d, open" % b.contract_reward)
	ctx["team"] = 4
	check(int(Contracts.build(&"variety", ctx)["goal"]) == 3 and String(Contracts.build(&"variety", ctx)["text"]) == "one bundle each of three strains",
			"four workers: still three strains (the trays, not the hands, are the limit)")
	check(Contracts.get_judge(&"variety") == Contracts.JUDGE_SPOT and Contracts.get_judge(&"keep") == Contracts.JUDGE_END and Contracts.get_judge(&"raid") == Contracts.JUDGE_SPOT,
			"'keep' is judged when the shift ends, 'variety' and 'raid' on the spot")
	check(Contracts.get_need(&"raid") == Contracts.NEED_RAID and Contracts.get_need(&"variety") == Contracts.NEED_NONE and Contracts.get_need(&"keep") == Contracts.NEED_NONE,
			"'raid' needs a raid to come; the other two need nothing")
	check(Contracts.is_counted(variety) and not Contracts.is_counted(keep) and not Contracts.is_counted(raid), "only 'variety' counts")

	step("catalog: the pool")
	var full := Contracts.pool({"events": true, "can_mutate": true, "strains": 3})
	check(full.size() == 12, "events on, a strain that walks, three strains on sale: every job (%d)" % full.size())
	check(Contracts.pool({"events": true, "can_mutate": true}).has(&"variety"), "no count given: 'variety' is offered (the default is three)")
	check(not Contracts.pool({"events": true, "can_mutate": true, "strains": 2}).has(&"variety") and Contracts.pool({"events": true, "can_mutate": true, "strains": 6}).has(&"variety"),
			"'variety' only with three strains on sale (not with two, yes with six)")
	check(not Contracts.pool({"events": false, "can_mutate": true}).has(&"raid") and Contracts.pool({"events": true, "can_mutate": false}).has(&"raid"), "'raid' only with events on")
	check(not Contracts.pool({"events": false, "can_mutate": false}).has(&"keep") and Contracts.pool({"events": true, "can_mutate": false}).has(&"keep")
			and Contracts.pool({"events": false, "can_mutate": true}).has(&"keep"), "'keep' only when something can take a plant (events, or a strain that walks)")
	var weight := 0
	var need_weight := 0
	for def: Dictionary in Contracts.CATALOG:
		weight += int(def["weight"])
		if def["need"] != Contracts.NEED_NONE:
			need_weight += int(def["weight"])
	check(weight == 28 and need_weight == 7, "weights: 28 in all, 7 of them on jobs that wait for something (%d, %d)" % [weight, need_weight])
	check(int(Contracts.get_def(&"variety")["weight"]) == 2 and int(Contracts.get_def(&"keep")["weight"]) == 2 and int(Contracts.get_def(&"raid")["weight"]) == 1, "variety 2, keep 2, raid 1")
	var rng := RandomNumberGenerator.new()
	rng.seed = 16
	var seen: Dictionary = {}
	var repeats := 0
	var previous: StringName = &""
	for i in 600:
		var pick := Contracts.roll({"events": true, "can_mutate": true, "strains": 3}, rng, previous)
		if pick == previous:
			repeats += 1
		seen[pick] = int(seen.get(pick, 0)) + 1
		previous = pick
	check(repeats == 0 and seen.size() == 12, "600 rolls: never the last shift's kind, every job comes up (%d kinds)" % seen.size())
	check(int(seen.get(&"raid", 0)) < int(seen.get(&"variety", 0)) and int(seen.get(&"raid", 0)) < int(seen.get(&"cured", 0)),
			"the raid job is the rarest of the three (raid %d, variety %d, keep %d, cured %d)" % [seen.get(&"raid", 0), seen.get(&"variety", 0), seen.get(&"keep", 0), seen.get(&"cured", 0)])
	check(Contracts.fallback_id(false) == &"clean" and Contracts.fallback_id(true) == &"cash", "the swap is what it was: 'clean', else 'cash'")

	step("catalog: copy")
	variety["progress"] = 1
	check(Contracts.hud_text(variety) == "Job: one bundle each of three strains 1 / 3", "HUD: '%s'" % Contracts.hud_text(variety))
	keep["failed"] = true
	check(Contracts.hud_text(keep) == "Job: lose no plant this shift · failed" and Contracts.report_text(keep) == "Job: lose no plant this shift. Failed.", "a failed 'keep': '%s'" % Contracts.report_text(keep))
	raid["done"] = true
	check(Contracts.hud_text(raid) == "Job: a raid that takes nothing · paid" and Contracts.report_text(raid) == "Job: a raid that takes nothing. Done. %s paid." % Contracts.format_money(b.contract_reward),
			"a met 'raid': '%s'" % Contracts.report_text(raid))
	var parsed := Contracts.parse(variety)
	check(String(parsed["id"]) == "variety" and int(parsed["progress"]) == 1 and int(parsed["goal"]) == 3, "the job survives the wire as it is")


# --- the sound ----------------------------------------------------------------------------------------------------------

func _test_sound() -> void:
	step("uproot: the sound")
	check(Sfx.has_sound(&"uproot") and Sfx.SETTINGS.has(&"uproot") and not Sfx.LOOPING.has(&"uproot"), "'uproot' is a one-shot in the tables")
	var stream: AudioStreamWAV = Sfx.get_stream(&"uproot")
	var m: Dictionary = Sfx.measure(stream)
	check(stream != null and float(m["seconds"]) > 0.3 and float(m["seconds"]) < 0.8, "a recipe of its own, short (%.2f s; the placeholder blip was 0.10 s)" % float(m["seconds"]))
	check(float(m["peak"]) >= 0.85 and float(m["peak"]) <= 0.9 and int(m["clipped"]) == 0, "peak %.3f, well under clipping" % float(m["peak"]))
	check(absf(float(m["dc"])) < 0.005 and float(m["rms"]) > 0.02, "no DC offset (%.4f), not silent (rms %.3f)" % [float(m["dc"]), float(m["rms"])])
	check(absi(stream.data.decode_s16(0)) < 1000 and absi(stream.data.decode_s16(stream.data.size() - 2)) < 1000, "starts and ends quietly (no click)")
	var harvest: Dictionary = Sfx.measure(Sfx.get_stream(&"harvest"))
	var loud := 20.0 * log(float(m["rms"])) / log(10.0) + float(Sfx.SETTINGS[&"uproot"][0])
	var loud_harvest := 20.0 * log(float(harvest["rms"])) / log(10.0) + float(Sfx.SETTINGS[&"harvest"][0])
	check(loud < loud_harvest + 3.0 and loud > -34.0, "about as loud as the harvest snip it replaces, never louder by much (%.1f dB against %.1f dB)" % [loud, loud_harvest])


# --- the cap ------------------------------------------------------------------------------------------------------------

func _test_cap(b: BalanceConfig) -> void:
	step("the cap: a plain day")
	var cap := b.mutation_chance_cap
	var night: SeedDef = b.get_seed(&"nightshift")
	var creeper: SeedDef = b.get_seed(&"creeper")
	check(is_equal_approx(cap, 0.5) and is_equal_approx(night.mutation_chance, 0.35), "the cap is %.2f; Night Shift turns %.2f of the time" % [cap, night.mutation_chance])
	var plain_ok := true
	for s: SeedDef in b.seeds:
		if not is_equal_approx(GrowPlot.get_mutation_chance(s), s.mutation_chance) or s.mutation_chance > cap:
			plain_ok = false
	check(plain_ok and GrowPlot.get_mutation_chance(null) == 0.0, "no conditions: every strain's chance is its own, all of them under the cap")

	step("the cap: a twitchy batch")
	_cond([&"twitchy"])
	check(is_equal_approx(GameState.condition_value(&"mutation_chance", 1.0), 2.0), "twitchy doubles the chance")
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), cap), "Night Shift stops at the cap: %.2f, not %.2f" % [GrowPlot.get_mutation_chance(night), night.mutation_chance * 2.0])
	check(is_equal_approx(GrowPlot.get_mutation_chance(creeper), creeper.mutation_chance * 2.0) and creeper.mutation_chance * 2.0 < cap,
			"Creeper is under the cap and simply doubles (%.2f)" % GrowPlot.get_mutation_chance(creeper))
	check(GrowPlot.get_mutation_chance(b.get_seed(&"budget")) == 0.0, "Budget Bud still never walks")
	var capped_ok := true
	for s: SeedDef in b.seeds:
		if GrowPlot.get_mutation_chance(s) > cap + 0.0001:
			capped_ok = false
	check(capped_ok, "no strain on the card is past the cap today")
	var over_seed := _seed_between(cap + 0.02, night.mutation_chance * 2.0 - 0.02)
	var under_seed := _seed_between(night.mutation_chance + 0.02, cap - 0.02)
	check(over_seed > 0 and under_seed > 0, "found a roll between the cap and the doubled chance (seed %d) and one between the plain chance and the cap (seed %d)" % [over_seed, under_seed])
	var p := _plot(5)
	p.server_plant(&"nightshift")
	p.server_water(1.0)
	p.stage = GrowPlot.Stage.READY
	seed(over_seed)
	var turned_over := p.server_roll_mutation()
	seed(under_seed)
	var turned_under := p.server_roll_mutation()
	p.turning = false
	p.server_reset()
	check(not turned_over and turned_under, "a real tray: the roll above the cap stays put (it walked before the cap), the one under it turns")
	night.mutation_chance = 0.8
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), 0.8), "the cap is on what a condition adds: a strain set above it keeps its own chance (%.2f)" % GrowPlot.get_mutation_chance(night))
	night.mutation_chance = 1.0
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), 1.0), "and a strain forced to 1.0 (the older suites) still always turns")
	b.mutation_chance_cap = 0.3
	night.mutation_chance = float(_chances[&"nightshift"])
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), night.mutation_chance) and is_equal_approx(GrowPlot.get_mutation_chance(creeper), creeper.mutation_chance * 2.0),
			"a cap of 0.30: it does not lower Night Shift's own 0.35, and Creeper's doubled 0.24 is under it")
	b.mutation_chance_cap = cap
	_cond([])
	check(is_equal_approx(GrowPlot.get_mutation_chance(night), night.mutation_chance), "the batch is over: the plain chance again")
	await wait_frames(1)


# --- what this session offers -------------------------------------------------------------------------------------------

func _test_session_pool(b: BalanceConfig) -> void:
	step("this session: the pool")
	var ctx: Dictionary = GameState._career_context()
	check(bool(ctx.get("events", false)) and int(ctx.get("strains", 0)) == 3, "events on, three strains on sale in shift 1 (%s)" % [ctx.get("strains", 0)])
	var pool := Contracts.pool(ctx)
	check(pool.has(&"variety") and pool.has(&"raid") and pool.has(&"keep"), "all three are offered here (nothing turns in this run, but events can take a plant)")
	var creeper: SeedDef = b.get_seed(&"creeper")
	var unlock := creeper.unlock_round
	creeper.unlock_round = 9
	ctx = GameState._career_context()
	check(int(ctx.get("strains", 0)) == 2 and not Contracts.pool(ctx).has(&"variety"), "with Creeper locked two strains are on sale: no 'variety'")
	creeper.unlock_round = unlock
	await wait_frames(1)


# --- variety ------------------------------------------------------------------------------------------------------------

func _test_variety(b: BalanceConfig) -> void:
	step("variety: one bundle each of three strains")
	_job(&"variety")
	var job := GameState.get_contract()
	check(String(job["id"]) == "variety" and String(job["text"]) == "one bundle each of three strains" and int(job["goal"]) == 3, "'%s', two workers: still three" % job["text"])
	check(hud.get_job_text() == "Job: one bundle each of three strains 0 / 3" and not hud.is_job_settled(), "HUD: '%s'" % hud.get_job_text())
	var met0 := _met.size()
	check(await _deposit(&"budget", false, BOB) and int(GameState.get_contract()["progress"]) == 1, "a wet Budget Bud bundle counts (1 / 3)")
	check(await _deposit(&"budget", true, BOB) and int(GameState.get_contract()["progress"]) == 1, "a second one, cured, does not: the strain is in already")
	check(await _deposit(&"purple", true, 1) and int(GameState.get_contract()["progress"]) == 2, "Purple Haze from another worker does (2 / 3)")
	check(hud.get_job_text() == "Job: one bundle each of three strains 2 / 3" and _met.size() == met0, "HUD: '%s', not paid yet" % hud.get_job_text())
	await _deposit(&"purple", false, BOB)
	check(int(GameState.get_contract()["progress"]) == 2, "more Purple Haze: still 2 / 3")
	Story.bark_log = PackedStringArray()
	toasts.clear()
	var before := GameState.money
	var value := TurnInStation.compute_sale_value(b.get_seed(&"creeper"), 1, GameState.get_sale_multiplier(), false)
	await _deposit(&"creeper", false, BOB)
	job = GameState.get_contract()
	check(bool(job["done"]) and int(job["progress"]) == 3 and _met.size() == met0 + 1, "the third strain: met, contract_met once")
	check(GameState.money == before + value + b.contract_reward, "the reward lands in cash on hand (+$%d on top of the $%d deposit)" % [b.contract_reward, value])
	check(GameState.get_stat(1, Const.STAT_CONTRACTS) == 1, "STAT_CONTRACTS +1 for the floor")
	check(toast_seen("Job done: one bundle each of three strains. $%d to cash on hand." % b.contract_reward), "toast: job done")
	var boss_line := Story.line("job_done") % Story.loop_amount_words(b.contract_reward)
	check(Array(Story.bark_log).has(boss_line) or Story.get_pending_text() == boss_line, "the Boss: '%s'" % boss_line)
	check(hud.get_job_text() == "Job: one bundle each of three strains 3 / 3 · paid" and hud.is_job_settled(), "HUD: '%s', dimmed" % hud.get_job_text())
	before = GameState.money
	await _deposit(&"creeper", false, BOB)
	check(_met.size() == met0 + 1 and GameState.money == before + value, "one more strain bundle: paid once only")

	step("variety: a new job counts from nothing")
	_job(&"variety")
	check(int(GameState.get_contract()["progress"]) == 0, "put up again: 0 / 3")
	check(await _deposit(&"budget", false, 1) and int(GameState.get_contract()["progress"]) == 1, "Budget Bud counts again for the new job")
	toasts.clear()
	_job(&"variety")
	check(toast_seen("Job: one bundle each of three strains. $%d." % b.contract_reward), "toast: the job and what it pays")


# --- keep ---------------------------------------------------------------------------------------------------------------

func _test_keep(b: BalanceConfig) -> void:
	step("keep: what is not a loss")
	_job(&"keep")
	var job := GameState.get_contract()
	check(String(job["text"]) == "lose no plant this shift" and hud.get_job_text() == "Job: lose no plant this shift", "'%s' (no counter)" % hud.get_job_text())
	var failed0 := _failed.size()
	check(await _harvest(1, bob) and not bool(GameState.get_contract()["failed"]), "a harvest is not a loss")
	var empty := _plot(2)
	empty.server_reset()
	check(empty.server_crop_lost(GrowPlot.LOSS_EATEN) == 0 and not bool(GameState.get_contract()["failed"]), "nothing is lost in an empty tray")
	check(_failed.size() == failed0, "the job stands")

	step("keep: fire")
	var money0 := GameState.money
	toasts.clear()
	check(_planted(2, &"budget", GrowPlot.Stage.VEGETATIVE).server_scorch(0), "the tray burns")
	await wait_frames(2)
	job = GameState.get_contract()
	check(bool(job["failed"]) and not bool(job["done"]) and _failed.size() == failed0 + 1, "a burnt plant fails it at once (contract_failed)")
	check(hud.get_job_text() == "Job: lose no plant this shift · failed" and hud.is_job_settled() and toast_seen("Job failed: lose no plant this shift."), "HUD and toast say so ('%s')" % hud.get_job_text())
	check(GameState.money == money0, "Budget Bud is not counted: no fine on top")
	check(_planted(2, &"budget", GrowPlot.Stage.SEEDLING).server_scorch(0), "another burns")
	await wait_frames(2)
	check(_failed.size() == failed0 + 1, "a second loss fails nothing twice")

	step("keep: eaten")
	_job(&"keep")
	failed0 = _failed.size()
	var eaten := _planted(3, &"purple", GrowPlot.Stage.FLOWERING)
	eaten.server_crop_lost(GrowPlot.LOSS_EATEN)   # what HostilePlant does when it has eaten a tray to nothing
	eaten.server_reset()
	await wait_frames(1)
	check(bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 + 1, "a plant eaten to nothing fails it")

	step("keep: the collector")
	_job(&"keep")
	failed0 = _failed.size()
	for item in items.get_items_of_type(Const.ITEM_PRODUCT):
		items.server_despawn_item(item)
	await wait_frames(2)
	_planted(4, &"budget", GrowPlot.Stage.VEGETATIVE)
	var took: Dictionary = Events.server_collect_unpaid()
	await wait_frames(1)
	check(took.get("what") == Events.COLLECT_TRAY and _plot(4).stage == GrowPlot.Stage.EMPTY, "nobody paid and no bundle lies about: he takes a tray (%s)" % [took])
	check(bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 + 1, "and the job with it")

	step("keep: a counted strain")
	_job(&"keep")
	failed0 = _failed.size()
	money0 = GameState.money
	var golden := _planted(5, &"golden", GrowPlot.Stage.VEGETATIVE)
	check(b.get_seed(&"golden").counted and golden.server_crop_lost(GrowPlot.LOSS_EATEN) == b.counted_fine and GameState.money == money0 - b.counted_fine,
			"Golden Kush is counted: the fine goes out as before ($%d)" % b.counted_fine)
	golden.server_reset()
	await wait_frames(1)
	check(bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 + 1, "and the job fails, once")

	step("keep: other jobs do not care")
	_job(&"cured")
	failed0 = _failed.size()
	check(_planted(2, &"budget", GrowPlot.Stage.SEEDLING).server_scorch(0), "a tray burns under another job")
	await wait_frames(2)
	check(not bool(GameState.get_contract()["failed"]) and _failed.size() == failed0, "'cured' is still open")
	GameState.server_set_contract(&"")
	_planted(3, &"budget", GrowPlot.Stage.SEEDLING).server_scorch(0)
	await wait_frames(2)
	check(GameState.get_contract().is_empty() and _failed.size() == failed0, "and with no job up a loss is just a loss")


# --- uprooting ----------------------------------------------------------------------------------------------------------

func _test_uproot(b: BalanceConfig) -> void:
	step("uproot: a harvest still snips")
	Hostiles.server_despawn_all()
	await wait_frames(2)
	var harvest0 := _played(&"harvest")
	var uproot0 := _played(&"uproot")
	await wait_sec(0.1)
	check(await _harvest(1, bob), "Bob harvests a tray")
	check(_played(&"harvest") > harvest0 and _played(&"uproot") == uproot0, "the harvest sound, not the uproot")

	step("uproot: a plant walks off")
	_job(&"keep")
	var failed0 := _failed.size()
	var night: SeedDef = b.get_seed(&"nightshift")
	await wait_sec(0.1)
	harvest0 = _played(&"harvest")
	uproot0 = _played(&"uproot")
	night.mutation_chance = 1.0
	var p := _planted(6, &"nightshift", GrowPlot.Stage.READY)   # no frame passes before the roll: Hostiles' own watch never sees it
	check(p.server_roll_mutation() and p.is_turning(), "a ready Night Shift plant turns")
	check(not p.server_tick_mutation(b.mutation_warning_sec - 0.5) and not bool(GameState.get_contract()["failed"]), "while it only twitches nothing is lost yet")
	check(p.server_tick_mutation(1.0) and p.stage == GrowPlot.Stage.EMPTY and Hostiles.count() == 1, "it uproots: the tray is empty, one walks the floor")
	night.mutation_chance = 0.0
	check(_played(&"uproot") > uproot0 and _played(&"harvest") == harvest0, "every peer hears `uproot` at the tray, and no harvest snip")
	Hostiles.server_despawn_all()
	await wait_frames(2)
	check(bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 + 1, "a plant that walks off is a plant lost: 'keep' fails")
	check(GrowPlot.LOSS_WALKED == &"walked", "the cause has a name (LOSS_WALKED)")

	step("uproot: the mark does not outlive its tray")
	await wait_sec(0.1)
	harvest0 = _played(&"harvest")
	uproot0 = _played(&"uproot")
	check(await _harvest(6, bob), "the same tray, planted again and harvested")
	check(_played(&"harvest") > harvest0 and _played(&"uproot") == uproot0, "snips like any harvest")
	p._rpc_uprooted()
	p.set(&"_uprooted_at_msec", Time.get_ticks_msec() - GrowPlot.UPROOT_MARK_MSEC - 50)
	await wait_sec(0.1)
	harvest0 = _played(&"harvest")
	check(await _harvest(6, bob) and _played(&"harvest") > harvest0 and _played(&"uproot") == uproot0, "a mark older than a second is ignored: the harvest snips")

	step("uproot: the floor is full")
	Hostiles.server_despawn_all()
	await wait_frames(2)
	_job(&"keep")
	failed0 = _failed.size()
	for i in b.hostile_max:
		Hostiles.server_spawn(&"budget", Vector3(6.0 + float(i) * 0.8, 0.0, 5.0))
	night.mutation_chance = 1.0
	var q := _planted(6, &"nightshift", GrowPlot.Stage.READY)
	uproot0 = _played(&"uproot")
	check(q.server_roll_mutation() and not q.server_tick_mutation(b.mutation_warning_sec + 1.0) and q.stage == GrowPlot.Stage.READY,
			"with %d on the floor the plant waits in its tray (M13)" % b.hostile_max)
	night.mutation_chance = 0.0
	check(not bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 and _played(&"uproot") == uproot0, "nothing lost, nothing heard: the job stands")
	q.turning = false
	q.server_reset()
	Hostiles.server_despawn_all()
	await wait_frames(2)
	GameState.server_set_contract(&"")


# --- the raid job -------------------------------------------------------------------------------------------------------

func _test_raid(b: BalanceConfig) -> void:
	step("raid: no raid by half time")
	for item in items.get_items_of_type(Const.ITEM_PRODUCT):
		items.server_despawn_item(item)
	await wait_frames(2)
	GameState.time_left = 890.0
	await wait_frames(1)
	_job(&"raid")
	var offers0 := _offered.size()
	await wait_frames(3)
	check(String(GameState.get_contract()["id"]) == "raid" and _offered.size() == offers0, "before half time the job waits for its raid")
	toasts.clear()
	GameState.time_left = 449.0
	await wait_frames(3)
	var job := GameState.get_contract()
	check(String(job["id"]) == "clean" and not bool(job["failed"]) and _offered.size() == offers0 + 1 and bool(_offered.back()[1]),
			"half the shift gone and nobody came: swapped for '%s' (nobody is written up)" % job["text"])
	check(toast_seen("Job changed: %s. $%d." % [job["text"], b.contract_reward]), "the floor is told")
	GameState.time_left = 890.0
	await wait_frames(1)

	step("raid: one that is cut short")
	_job(&"raid")
	var met0 := _met.size()
	var failed0 := _failed.size()
	check(Events.server_start_event(Events.EVENT_RAID), "a raid starts")
	Events.tick(b.raid_warning_sec * 0.5)
	check(not bool(GameState.get_contract()["done"]), "the sirens only: nothing judged")
	Events.server_end_event()
	_quiet()
	await wait_frames(2)
	job = GameState.get_contract()
	check(not bool(job["done"]) and not bool(job["failed"]) and _met.size() == met0, "it never looked in: nothing paid, the job stays open")

	step("raid: they look and take nothing")
	var before := GameState.money
	Story.bark_log = PackedStringArray()
	toasts.clear()
	check(Events.server_start_event(Events.EVENT_RAID), "another raid")
	Events.tick(b.raid_warning_sec + 0.1)
	check(Events.is_raid_looking() and not bool(GameState.get_contract()["done"]), "not judged while they look")
	GameState.time_left = 440.0
	await wait_frames(3)
	check(String(GameState.get_contract()["id"]) == "raid" and Events.is_event_active(Events.EVENT_RAID), "past half time with the raid on: the job stays")
	Events.tick(b.raid_sec + 1.0)
	_quiet()
	await wait_frames(2)
	job = GameState.get_contract()
	check(not Events.is_event_active() and Events.get_raid_taken() == 0, "it ran its course and found nothing")
	check(bool(job["done"]) and _met.size() == met0 + 1 and _failed.size() == failed0, "met when it ends")
	check(GameState.money == before + b.contract_reward, "the reward lands in cash on hand")
	check(toast_seen("Job done: a raid that takes nothing. $%d to cash on hand." % b.contract_reward), "toast: job done")
	var boss_line := Story.line("job_done") % Story.loop_amount_words(b.contract_reward)
	check(Array(Story.bark_log).has(boss_line) or Story.get_pending_text() == boss_line or Story.last_bark == boss_line, "the Boss: '%s'" % boss_line)
	check(hud.get_job_text() == "Job: a raid that takes nothing · paid", "HUD: '%s'" % hud.get_job_text())
	GameState.time_left = 890.0
	await wait_frames(1)

	step("raid: they take a bundle")
	_job(&"raid")
	met0 = _met.size()
	failed0 = _failed.size()
	var bundle := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1, "cured": false}, SPOT_OPEN, 0)
	await wait_frames(2)
	check(bundle != null, "a bundle on the open floor")
	toasts.clear()
	check(Events.server_start_event(Events.EVENT_RAID), "a raid")
	Events.tick(b.raid_warning_sec + b.raid_sec * 0.5)
	await wait_frames(1)
	if Events.get_raid_taken() == 0:
		Events.tick(b.raid_sec * 0.4)
		await wait_frames(1)
	job = GameState.get_contract()
	check(Events.get_raid_taken() == 1 and bool(job["failed"]) and not bool(job["done"]) and _failed.size() == failed0 + 1, "raid_took fails the job the moment the bundle goes")
	check(toast_seen("Job failed: a raid that takes nothing."), "toast: job failed")
	Events.tick(b.raid_sec + 1.0)
	_quiet()
	await wait_frames(2)
	check(not Events.is_event_active() and not bool(GameState.get_contract()["done"]) and _met.size() == met0 and _failed.size() == failed0 + 1, "and the end of that raid pays nothing")

	step("raid: other jobs do not care")
	_job(&"cured")
	met0 = _met.size()
	check(Events.server_start_event(Events.EVENT_RAID), "a raid under another job")
	Events.tick(b.raid_warning_sec + b.raid_sec + 1.0)
	_quiet()
	await wait_frames(2)
	check(not Events.is_event_active() and not bool(GameState.get_contract()["done"]) and _met.size() == met0, "'cured' is not met by a clean raid")
	GameState.server_set_contract(&"")


# --- the empty flamethrower ---------------------------------------------------------------------------------------------

func _test_flamethrower(b: BalanceConfig) -> void:
	step("flamethrower: with fuel it stays")
	var limit := b.empty_flamethrower_sec
	check(is_equal_approx(limit, 30.0), "an empty one is cleared after %.0f s" % limit)
	_removed.clear()
	var ft := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": 5.0}, SPOT_OPEN, 0) as Flamethrower
	await wait_frames(2)
	if not check(ft != null and not ft.is_empty() and not ft.is_held(), "a flamethrower with fuel on the floor"):
		return
	check(not ft.server_tick_empty(limit * 10.0) and ft.get_empty_idle_sec() == 0.0, "ten times the wait: it has fuel, nothing counts")

	step("flamethrower: empty on the floor")
	ft.server_set_fuel(0.0)
	check(ft.is_empty() and ft.get_label_text() == "Flamethrower (empty)", "'%s'" % ft.get_label_text())
	check(not ft.server_tick_empty(limit - 5.0) and ft.get_empty_idle_sec() >= limit - 5.0 and ft.get_empty_idle_sec() < limit - 3.0,
			"%.0f s on the floor: still there (%.1f s counted)" % [limit - 5.0, ft.get_empty_idle_sec()])
	_put(bob, LANE)
	await wait_frames(2)
	check(items.server_give_item(ft, BOB) and ft.holder_id == BOB, "Bob picks it up")
	check(not ft.server_tick_empty(limit * 10.0) and ft.get_empty_idle_sec() == 0.0, "in his hands the wait is over, however long he carries it")
	await wait_frames(2)
	check(is_instance_valid(ft) and not ft.is_queued_for_deletion(), "an empty flamethrower in hand is never taken")
	check(items.server_throw_item(ft, bob.global_position + Vector3(0.0, 1.2, -0.3), Vector3(0.0, 3.0, -4.0), BOB) and ft.is_flying(), "he throws it")
	check(not ft.server_tick_empty(limit * 10.0) and ft.get_empty_idle_sec() == 0.0, "in the air nothing counts")
	await wait_until(func() -> bool: return not ft.is_flying(), 3.0, "landed")
	check(not ft.server_tick_empty(limit - 5.0) and is_instance_valid(ft) and not ft.is_queued_for_deletion(), "back on the floor the wait starts again from nothing")
	ft.server_set_fuel(2.0)
	check(not ft.server_tick_empty(limit) and ft.get_empty_idle_sec() == 0.0, "refuelled: the wait is over")
	ft.server_set_fuel(0.0)
	check(not ft.server_tick_empty(limit - 5.0), "empty again: %.0f s" % (limit - 5.0))
	check(_removed.is_empty(), "nothing was removed so far")
	check(ft.server_tick_empty(5.5), "past %.0f s: the host removes it" % limit)
	await wait_frames(2)
	check(not is_instance_valid(ft) and items.get_items_of_type(Const.ITEM_FLAMETHROWER).is_empty(), "gone from the floor")
	check(_removed == [Const.ITEM_FLAMETHROWER], "through the item manager's own despawn (item_removed once) %s" % [_removed])

	step("flamethrower: the host's own clock")
	b.empty_flamethrower_sec = 0.4
	_removed.clear()
	var quick := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": 0.0}, SPOT_OPEN, 0) as Flamethrower
	check(quick != null and quick.is_empty() and items.get_items_of_type(Const.ITEM_FLAMETHROWER).size() == 1, "an empty one, left alone")
	quick = null
	await wait_until(func() -> bool: return items.get_items_of_type(Const.ITEM_FLAMETHROWER).is_empty(), 3.0, "it goes by itself (0.4 s for this check)")
	await wait_frames(2)
	check(_removed == [Const.ITEM_FLAMETHROWER], "removed once")
	b.empty_flamethrower_sec = 0.0
	var kept := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": 0.0}, SPOT_OPEN, 0) as Flamethrower
	await wait_frames(3)
	check(not kept.server_tick_empty(1000.0) and kept.get_empty_idle_sec() == 0.0 and is_instance_valid(kept), "a wait of 0 turns the rule off")
	b.empty_flamethrower_sec = limit
	items.server_despawn_item(kept)
	await wait_frames(2)

	step("flamethrower: the cabinet restocks as before")
	_removed.clear()
	var hostile_id := Hostiles.server_spawn(&"budget", Vector3(14.0, 0.0, -1.0))   # so breaking the glass is no misuse
	GameState.server_add_money(b.cabinet_deposit * 3)
	var write_ups0 := GameState.get_write_ups(1)
	check(hostile_id > 0 and not cabinet.broken and cabinet.server_break(me), "I break the glass")
	await wait_frames(2)
	var mine := items.get_held_by(1) as Flamethrower
	if not check(mine != null and mine.fuel == b.flamethrower_fuel_sec and cabinet.broken, "a full flamethrower in my hands, the cabinet is restocking"):
		return
	mine.server_set_fuel(0.0)
	items.server_drop_item(mine, SPOT_OPEN)
	await wait_frames(2)
	var restock0 := cabinet.restock_left
	check(mine.server_tick_empty(limit + 0.1), "empty and dropped: cleared after the wait")
	await wait_frames(2)
	check(not is_instance_valid(mine) and cabinet.broken and cabinet.restock_left > 0 and cabinet.restock_left <= restock0, "the cabinet's own countdown is not touched (%d s left)" % cabinet.restock_left)
	cabinet.server_restock()
	await wait_frames(1)
	check(not cabinet.broken and cabinet.can_interact(me) and cabinet.server_break(me), "restocked: the glass breaks again")
	await wait_frames(2)
	var second := items.get_held_by(1) as Flamethrower
	check(second != null and second.fuel == b.flamethrower_fuel_sec, "a fresh one, full")
	check(GameState.get_write_ups(1) == write_ups0, "(one was alive on the floor: no misuse write-up)")
	if second != null:
		items.server_despawn_item(second)
	cabinet.server_restock()
	Hostiles.server_despawn_all()
	await wait_frames(2)

	step("flamethrower: the Boss still keeps a back-room worker's")
	var bobs := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": 0.0}, bob.global_position, BOB) as Flamethrower
	await wait_frames(2)
	toasts.clear()
	check(bobs != null and bobs.holder_id == BOB and GameState.server_send_to_backroom(BOB, 30.0), "Bob, an empty one in his hands, is sent to the back room")
	await wait_frames(2)
	check((not is_instance_valid(bobs) or bobs.is_queued_for_deletion()) and items.get_items_of_type(Const.ITEM_FLAMETHROWER).is_empty() and toast_seen("The Boss keeps Bob's flamethrower."),
			"the Boss keeps it at once (M13), not after the wait")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(2)
	_put(bob, FAR_B)


# --- what travels -------------------------------------------------------------------------------------------------------

func _test_wire() -> void:
	step("late join: the job as a late joiner is sent it")
	var met0 := _met.size()
	var offers0 := _offered.size()
	var before := GameState.money
	toasts.clear()
	GameState._rpc_contract({"id": "variety", "text": "one bundle each of three strains", "goal": 3, "progress": 2, "reward": 60, "done": false, "round": 1}, GameState.CONTRACT_EVENT_NONE)
	await wait_frames(1)
	check(hud.get_job_text() == "Job: one bundle each of three strains 2 / 3" and not hud.is_job_settled(), "a half-done 'variety' arrives as state: '%s'" % hud.get_job_text())
	GameState._rpc_contract({"id": "keep", "text": "lose no plant this shift", "goal": 1, "progress": 0, "reward": 60, "done": false, "failed": true, "round": 1}, GameState.CONTRACT_EVENT_NONE)
	await wait_frames(1)
	check(hud.get_job_text() == "Job: lose no plant this shift · failed" and hud.is_job_settled(), "a failed 'keep': '%s'" % hud.get_job_text())
	check(_met.size() == met0 and _offered.size() == offers0 and GameState.money == before and not toast_seen("Job"), "no event rides on either: no toast, nothing paid")
	GameState._career_on_peer_registered(BOB)
	GameState.server_set_contract(&"")
	await wait_frames(1)


# --- keep, judged at the end --------------------------------------------------------------------------------------------

func _test_keep_at_the_end(b: BalanceConfig) -> void:
	step("keep: judged when the shift ends, payment made")
	GameState.time_left = 890.0
	GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 0) + 10, BOB)
	await wait_frames(1)
	_job(&"keep")
	var met0 := _met.size()
	await wait_frames(2)
	check(not bool(GameState.get_contract()["done"]), "not judged before the end")
	var before := GameState.money
	Story.bark_log = PackedStringArray()
	toasts.clear()
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift ends, payment made")
	await wait_frames(3)
	var job := GameState.get_contract()
	check(bool(job["done"]) and _met.size() == met0 + 1 and GameState.money == before + b.contract_reward, "no plant was lost: met and paid")
	check(toast_seen("Job done: lose no plant this shift. $%d to cash on hand." % b.contract_reward), "toast: job done")
	check(not Array(Story.bark_log).has(Story.line("job_done") % Story.loop_amount_words(b.contract_reward)), "the Boss is busy with the payment; the report has the job")
	var report: ShiftReport = hud.round_end.report
	check(report.get_job_text() == "Job: lose no plant this shift. Done. %s paid." % HUD.format_money(b.contract_reward), "shift report: '%s'" % report.get_job_text())

	step("keep: the payment is missed")
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	await wait_frames(2)
	_quiet()
	_cond([])
	check(not GameState.get_contract().is_empty() and int(GameState.get_contract()["round"]) == 2 and String(GameState.get_contract()["id"]) != "keep",
			"a job was rolled for shift 2, not the kind of the shift before ('%s')" % GameState.get_contract().get("id", ""))
	_job(&"keep")
	met0 = _met.size()
	var failed0 := _failed.size()
	before = GameState.money
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "the shift ends, payment missed")
	await wait_frames(3)
	job = GameState.get_contract()
	check(bool(job["failed"]) and not bool(job["done"]) and _met.size() == met0 and _failed.size() == failed0 + 1 and GameState.money == before,
			"a job judged at the end needs the payment: failed, nothing paid")
	check(hud.round_end.report.get_job_text() == "Job: lose no plant this shift. Failed.", "shift report: '%s'" % hud.round_end.report.get_job_text())


# --- helpers ------------------------------------------------------------------------------------------------------------

func _job(id: StringName, overrides: Dictionary = {}) -> void:
	GameState.server_set_contract(id, overrides)


func _cond(ids: Array) -> void:
	var typed: Array[StringName] = []
	for id: StringName in ids:
		typed.append(id)
	GameState.server_set_conditions(typed)


## The event scheduler stays out of this run: every event here is started by hand.
func _quiet() -> void:
	Events.set(&"_next_in", -1.0)


## The msec of the last 3D play of `sound` (-1 = never).
func _played(sound: StringName) -> int:
	var plays: Dictionary = Sfx.get(&"_last_play")
	return int(plays.get(StringName(String(sound) + "@3d"), -1))


## The first seed whose first randf() lands in [low, high) (-1 when none below 4000).
func _seed_between(low: float, high: float) -> int:
	for candidate in range(1, 4000):
		seed(candidate)
		var v := randf()
		if v >= low and v < high:
			return candidate
	return -1


## A bundle on the floor, sold through the chute's one sale path as if `seller` deposited it.
func _deposit(strain: StringName, cured: bool, seller: int) -> bool:
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": strain, "amount": 1, "cured": cured}, FAR_A + Vector3(1.0, 0.0, 0.0), 0)
	if product == null:
		return false
	var ok := chute.server_sell_item(product, seller)
	await wait_frames(1)
	return ok


## GrowPlot<i> with a watered `strain` plant at `stage`.
func _planted(i: int, strain: StringName, stage: GrowPlot.Stage) -> GrowPlot:
	var p := _plot(i)
	if p.stage != GrowPlot.Stage.EMPTY:
		p.turning = false
		p.server_reset()
	p.server_plant(strain)
	p.server_water(1.0)
	p.stage = stage
	return p


## GrowPlot<i> made ready and harvested by `who` through the tray's server interaction; the bundle is thrown away.
func _harvest(i: int, who: Player) -> bool:
	var p := _planted(i, &"budget", GrowPlot.Stage.READY)
	var before := GameState.get_stat(who.peer_id, Const.STAT_HARVESTED)
	p._server_interact(who)
	await wait_frames(1)
	var held := items.get_held_by(who.peer_id)
	if held != null:
		items.server_despawn_item(held)
	await wait_frames(1)
	return GameState.get_stat(who.peer_id, Const.STAT_HARVESTED) == before + 1


func _plot(i: int) -> GrowPlot:
	return room.get_station("GrowPlot%d" % i) as GrowPlot


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.05, pos.z)


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	_remove(_path)
	_remove(_path + ".tmp")
