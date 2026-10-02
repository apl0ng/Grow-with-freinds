extends "res://tools/tests/qa_base.gd"
## M14 loop suite (loop agent): the strain traits and the drying rack on a single headless host with one fake worker
## (Bob: a host-side body without an owning peer, so the SERVER side runs directly on him).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/loop_body.gd --port=7975
## Pins:
##   thirsty    Purple Haze drains 1.6 times the water Budget Bud does over the same tick; the status line says so
##   dark       power cut: Night Shift advances at twice its lit rate and drinks at its usual rate, Budget Bud keeps
##              its progress and its water; power back: both grow at their lit rate again
##   spreads    forced hit: the harvester holds the full yield and the tray holds a watered Creeper seedling; forced
##              miss: an empty tray; seeded dice land near one in three; a strain without the trait never spreads
##   heavy      the LOCAL worker's own simulation: walking speed x heavy_speed_factor with a Floor Brick bundle, sprint
##              makes no difference; walk and sprint are back the moment the bundle is gone or of another strain
##   counted    a scorched and an eaten Golden Kush plant fine the floor counted_fine (toast, Boss line, crop_lost),
##              capped by the cash on hand, on top of an arson write-up; other strains cost nothing
##   the rack   two racks in the north-west corner; prompts and denials; a hang through the real interact request;
##              the countdown (exact on the host, synced in 0.5 s steps); an early pick-up keeps the remainder and
##              never cures in the hand; the re-hang (on the other rack) finishes it; cured props, label, tint; three
##              hooks then "Rack is full."; a freed hook is reused; the chute pays 1 + cure_bonus and counts
##              STAT_CURED; an uncured bundle sells at the plain value
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const FAR_A := Vector3(-8.0, 0.0, 5.0)
const FAR_B := Vector3(-8.0, 0.0, 3.0)

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var chute: TurnInStation
var rack1: DryingRack
var rack2: DryingRack
var _lost: Array = []      # [cause, strain, fine] per GrowPlot.crop_lost on this peer
var _write_ups: Array = [] # [peer, reason]
var _hung: Array = []      # [rack name, hook, peer]
var _cured: Array = []     # [rack name, hook]


func _run() -> void:
	_label = "loop"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	# This run is about the traits: nothing turns hostile by itself, and a paid quota does not end the shift.
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false

	step("hosting")
	Game.start_host("Tester", port_arg(7975))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	await wait_frames(3)
	if not check(bob != null and world.get_players().size() == 2, "host + Bob spawned"):
		finish(); return
	chute = room.get_station("TurnInStation") as TurnInStation
	rack1 = room.get_station("DryingRack1") as DryingRack
	rack2 = room.get_station("DryingRack2") as DryingRack
	if not check(chute != null and rack1 != null and rack2 != null, "the chute and both drying racks exist"):
		finish(); return
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(1000)
	GameState.worker_written_up.connect(func(p: int, reason: String, _c: int) -> void: _write_ups.append([p, reason]))
	for i in range(1, 7):
		var p := _plot(i)
		p.crop_lost.connect(func(cause: StringName, strain: StringName, fine: int) -> void: _lost.append([cause, strain, fine]))
	for r: DryingRack in [rack1, rack2]:
		r.bundle_hung.connect(func(hook: int, peer: int) -> void: _hung.append([String(r.name), hook, peer]))
		r.bundle_cured.connect(func(hook: int) -> void: _cured.append([String(r.name), hook]))
	_put(bob, FAR_B)
	_put_me(FAR_A, 0.0)
	await wait_frames(2)

	await _test_thirst(b)
	await _test_dark(b)
	await _test_spread(b)
	await _test_heavy(b)
	await _test_counted(b)
	await _test_rack_layout(b)
	await _test_rack(b)
	await _test_sale(b)
	finish()


# --- thirsty ----------------------------------------------------------------------------------------------------------

func _test_thirst(b: BalanceConfig) -> void:
	step("thirsty: Purple Haze drains faster")
	var budget := _plot(1)
	var purple := _plot(2)
	check(budget.server_plant(&"budget") and purple.server_plant(&"purple"), "Budget Bud in GrowPlot1, Purple Haze in GrowPlot2")
	check(is_equal_approx(budget.get_thirst_factor(), 1.0) and is_equal_approx(purple.get_thirst_factor(), 1.6),
			"thirst factors 1.0 and 1.6 (%.2f, %.2f)" % [budget.get_thirst_factor(), purple.get_thirst_factor()])
	budget.water = 1.0
	purple.water = 1.0
	budget.tick(10.0)
	purple.tick(10.0)
	var plain := 1.0 - budget.water
	var thirsty := 1.0 - purple.water
	check(is_equal_approx(plain, 10.0 * b.water_drain_per_sec), "Budget Bud lost %.3f of its water in 10 s (the plain drain)" % plain)
	check(absf(thirsty / plain - 1.6) < 0.001, "Purple Haze lost %.3f: 1.6 times as much (x%.3f)" % [thirsty, thirsty / plain])
	# Dry-out time: a full tray lasts 38 s under Budget Bud and under 24 s under Purple Haze.
	budget.water = 1.0
	purple.water = 1.0
	var t_plain := _seconds_until_dry(budget)
	var t_thirsty := _seconds_until_dry(purple)
	check(absf(t_plain / t_thirsty - 1.6) < 0.05, "a full tray goes dry in %.1f s instead of %.1f s" % [t_thirsty, t_plain])
	# The trait rides on the status line.
	purple.water = 1.0
	budget.water = 1.0
	check(purple.get_trait_text() == "Thirsty." and budget.get_trait_text() == "", "the tray knows its strain's trait")
	check(purple.get_prompt(me).ends_with(" · Thirsty.") and purple.get_denied_reason(me).ends_with(" · Thirsty."),
			"Purple Haze status line names it ('%s' / '%s')" % [purple.get_prompt(me), purple.get_denied_reason(me)])
	check(purple.get_denied_reason(me).begins_with("Not ready. "), "the growth status still leads the line")
	check(not budget.get_prompt(me).contains("Thirsty") and budget.get_denied_reason(me).ends_with("%"),
			"Budget Bud's status line is unchanged ('%s')" % budget.get_denied_reason(me))
	purple.water = 0.0
	check(purple.get_denied_reason(me) == "Dry. Needs water. · Thirsty.", "dry: '%s'" % purple.get_denied_reason(me))
	budget.server_reset()
	purple.server_reset()
	await wait_frames(1)


## Ticks `plot` in 0.25 s steps until it is dry; returns the seconds that took (growth does not matter here).
func _seconds_until_dry(plot: GrowPlot) -> float:
	var t := 0.0
	while not plot.is_dry() and t < 120.0:
		plot.tick(0.25)
		t += 0.25
		if not plot.is_growing():
			break
	return t


# --- grows in the dark ------------------------------------------------------------------------------------------------

func _test_dark(b: BalanceConfig) -> void:
	step("grows in the dark: Night Shift during a power cut")
	var budget := _plot(1)
	var night := _plot(3)
	check(budget.server_plant(&"budget") and night.server_plant(&"nightshift"), "Budget Bud in GrowPlot1, Night Shift in GrowPlot3")
	budget.water = 1.0
	night.water = 1.0
	check(is_equal_approx(night.get_dark_growth_factor(), 2.0) and budget.get_dark_growth_factor() == 0.0, "dark growth factors 2.0 and 0")
	# Lit: both grow at their own rate.
	budget.tick(2.0)
	night.tick(2.0)
	var lit_budget := budget.stage_progress
	var lit_night := night.stage_progress
	check(is_equal_approx(lit_budget, 2.0 / b.stage_durations[0]), "lit: Budget Bud +%.4f in 2 s" % lit_budget)
	check(is_equal_approx(lit_night, 2.0 / (b.stage_durations[0] * 1.2)), "lit: Night Shift +%.4f in 2 s" % lit_night)
	# Dark.
	Events.server_set_power(false)
	check(not Events.is_power_on(), "the mains are off")
	var w_budget := budget.water
	var w_night := night.water
	budget.tick(2.0)
	night.tick(2.0)
	check(budget.stage_progress == lit_budget and budget.water == w_budget, "dark: Budget Bud is frozen (progress and water unchanged)")
	var dark_gain := night.stage_progress - lit_night
	check(absf(dark_gain / lit_night - 2.0) < 0.001, "dark: Night Shift +%.4f in 2 s, twice its lit rate (x%.3f)" % [dark_gain, dark_gain / lit_night])
	check(is_equal_approx(w_night - night.water, 2.0 * b.water_drain_per_sec), "dark: it drinks at its usual rate (%.3f)" % (w_night - night.water))
	# A dry Night Shift does not grow in the dark either.
	var p0 := night.stage_progress
	night.water = 0.0
	night.tick(2.0)
	check(night.stage_progress == p0, "dark and dry: no growth")
	night.water = 1.0
	# It still goes through its stages in the dark.
	var stage0 := night.stage
	night.tick(night.get_stage_duration(night.stage) / 2.0 + 0.1)
	check(night.stage == stage0 + 1, "dark: a stage that takes %.0f s lit is done in half of it" % night.get_stage_duration(stage0))
	# Power back: lit rates again.
	Events.server_set_power(true)
	check(Events.is_power_on(), "the mains are back")
	var b0 := budget.stage_progress
	var n0 := night.stage_progress
	night.water = 1.0
	budget.tick(2.0)
	night.tick(2.0)
	check(is_equal_approx(budget.stage_progress - b0, lit_budget), "power back: Budget Bud grows again (+%.4f)" % (budget.stage_progress - b0))
	check(is_equal_approx(night.stage_progress - n0, 2.0 / night.get_stage_duration(night.stage)), "power back: Night Shift is back to its lit rate (+%.4f)" % (night.stage_progress - n0))
	budget.server_reset()
	night.server_reset()
	await wait_frames(1)


# --- spreads ----------------------------------------------------------------------------------------------------------

func _test_spread(b: BalanceConfig) -> void:
	step("spreads: a Creeper harvest may leave a seedling")
	var plot := _plot(4)
	var creeper := b.get_seed(&"creeper")
	_put(bob, plot.global_position + Vector3(0.0, 0.0, 1.5))
	# Forced hit, through the tray's own interaction.
	_make_ready(plot, &"creeper")
	plot.water = 0.3
	GrowPlot.spread_force = GrowPlot.SPREAD_ALWAYS
	var harvested0 := GameState.get_stat(BOB, Const.STAT_HARVESTED)
	plot._server_interact(bob)
	check(plot.stage == GrowPlot.Stage.SEEDLING and plot.strain_id == &"creeper" and plot.stage_progress == 0.0,
			"forced hit: the tray holds a Creeper seedling (stage %s, strain %s)" % [plot.get_stage_name(), plot.strain_id])
	check(plot.water >= GrowPlot.SPREAD_WATER - 0.001, "the seedling is watered (%.2f)" % plot.water)
	await wait_frames(2)
	var bundle := items.get_held_by(BOB) as Product
	check(bundle != null and bundle.strain_id == &"creeper" and bundle.amount == creeper.yield_amount,
			"Bob holds the full yield (%d x Creeper)" % creeper.yield_amount)
	check(GameState.get_stat(BOB, Const.STAT_HARVESTED) == harvested0 + 1, "the harvest counts as one harvest")
	check(not plot.can_interact(bob), "nothing to harvest from the seedling yet")
	plot.tick(1.0)
	check(plot.stage_progress > 0.0, "the seedling grows on its own water")
	items.server_despawn_item(bundle)
	await wait_frames(1)
	# Forced miss on the seedling that was left, once it is ready.
	plot.stage = GrowPlot.Stage.READY
	GrowPlot.spread_force = GrowPlot.SPREAD_NEVER
	check(plot.server_harvest(bob), "forced miss: harvested")
	await wait_frames(1)
	bundle = items.get_held_by(BOB) as Product
	check(bundle != null and bundle.amount == creeper.yield_amount, "the yield is the same")
	check(plot.stage == GrowPlot.Stage.EMPTY and plot.strain_id == &"", "the tray is empty")
	items.server_despawn_item(bundle)
	await wait_frames(1)
	# A strain without the trait never spreads, even with the dice held.
	GrowPlot.spread_force = GrowPlot.SPREAD_ALWAYS
	_make_ready(plot, &"budget")
	check(plot.server_harvest(null) and plot.stage == GrowPlot.Stage.EMPTY, "Budget Bud never spreads")
	_clear_products()
	# Seeded dice: about one harvest in three.
	GrowPlot.spread_force = GrowPlot.SPREAD_ROLL
	GrowPlot.spread_rng.seed = 20261002
	var runs := 150
	var hits := 0
	for i in runs:
		if plot.stage == GrowPlot.Stage.EMPTY:
			plot.server_plant(&"creeper")
		plot.stage = GrowPlot.Stage.READY
		if not plot.server_harvest(null):
			break
		if plot.stage == GrowPlot.Stage.SEEDLING:
			hits += 1
		_clear_products()
	var rate := float(hits) / float(runs)
	check(absf(rate - creeper.spread_chance) < 0.1, "seeded dice: %d of %d harvests spread (%.2f, chance %.2f)" % [hits, runs, rate, creeper.spread_chance])
	GrowPlot.spread_rng.seed = 20261002
	var first := GrowPlot.spread_rng.randf()
	GrowPlot.spread_rng.seed = 20261002
	check(GrowPlot.spread_rng.randf() == first, "the same seed gives the same roll (tests can seed the dice)")
	plot.server_reset()
	_put(bob, FAR_B)
	await wait_frames(2)
	check(items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "no bundles left over")


# --- heavy ------------------------------------------------------------------------------------------------------------

func _test_heavy(b: BalanceConfig) -> void:
	step("heavy: a Floor Brick bundle slows its carrier")
	var heavy_speed: float = b.walk_speed * b.heavy_speed_factor
	check(is_equal_approx(me.get_heavy_walk_speed(), heavy_speed) and heavy_speed < b.walk_speed, "heavy walk speed %.2f m/s (walk %.2f)" % [heavy_speed, b.walk_speed])
	_put_me(Vector3(-3.0, 0.0, 3.0), 0.0)
	await wait_physics(4)
	check(not me.is_carrying_heavy() and is_equal_approx(me.get_move_speed(), b.walk_speed), "empty hands: walking speed")
	check(is_equal_approx(await _measure_speed(false), b.walk_speed), "empty hands: the body walks at %.2f m/s" % b.walk_speed)
	check(is_equal_approx(await _measure_speed(true), b.sprint_speed), "empty hands: it sprints at %.2f m/s" % b.sprint_speed)
	# A bundle of a strain that is not heavy changes nothing.
	var light := _bundle(&"budget", 1, 1)
	await wait_frames(1)
	check(not me.is_carrying_heavy() and not light.is_heavy(), "a Budget Bud bundle is not heavy")
	check(is_equal_approx(await _measure_speed(true), b.sprint_speed), "with it the worker still sprints")
	items.server_despawn_item(light)
	await wait_frames(1)
	# The brick.
	var brick := _bundle(&"brick", 3, 1)
	await wait_frames(1)
	check(brick.is_heavy() and me.is_carrying_heavy(), "a Floor Brick bundle is heavy, and I carry it")
	check(brick.get_label_text() == "Floor Brick x3 (Heavy)", "the bundle says so: '%s'" % brick.get_label_text())
	check(is_equal_approx(me.get_move_speed(), heavy_speed), "the simulation aims for %.2f m/s" % heavy_speed)
	var walked: float = await _measure_speed(false)
	check(is_equal_approx(walked, heavy_speed), "the body walks at %.2f m/s (x%.1f)" % [walked, b.heavy_speed_factor])
	var sprinted: float = await _measure_speed(true)
	check(is_equal_approx(sprinted, heavy_speed), "holding sprint changes nothing (%.2f m/s)" % sprinted)
	# Any peer can tell who is weighed down (the held item is synced).
	items.server_release_holder(1)
	await wait_frames(1)
	check(not me.is_carrying_heavy() and is_equal_approx(me.get_move_speed(), b.walk_speed), "dropped: walking speed at once")
	check(items.server_give_item(brick, BOB) and bob.is_carrying_heavy(), "Bob picks it up: is_carrying_heavy() for him")
	check(is_equal_approx(await _measure_speed(true), b.sprint_speed), "and I sprint again")
	items.server_despawn_item(brick)
	_put_me(FAR_A, 0.0)
	await wait_frames(2)


## Walks the local body forward for a moment (the real input actions, the real _physics_process) and returns the
## horizontal speed it settled at.
func _measure_speed(sprint: bool) -> float:
	_put_me(Vector3(-3.0, 0.0, 3.0), 0.0)
	await wait_physics(3)
	Input.action_press(&"move_forward")
	if sprint:
		Input.action_press(&"sprint")
	await wait_physics(24)
	var v := Vector2(me.velocity.x, me.velocity.z).length()
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")
	await wait_physics(12)
	return v


# --- counted ----------------------------------------------------------------------------------------------------------

func _test_counted(b: BalanceConfig) -> void:
	step("counted: a lost Golden Kush plant is fined")
	var fine: int = b.counted_fine
	check(Story.line("counted_fine") == "He counted those. %s." and Story.loop_amount_words(25) == "Twenty-five" and Story.loop_amount_words(10) == "Ten"
			and Story.loop_amount_words(140) == "$140", "Story knows the line and says the amount in words")
	var golden := _plot(5)
	var budget := _plot(6)
	# Fire, nobody to blame (by_peer 0): the fine alone.
	check(golden.server_plant(&"golden") and budget.server_plant(&"budget"), "Golden Kush in GrowPlot5, Budget Bud in GrowPlot6")
	Story.tick(10.0)
	toasts.clear()
	_lost.clear()
	var money0 := GameState.money
	check(golden.server_scorch(0), "the Golden Kush plant burns")
	check(GameState.money == money0 - fine, "the floor pays $%d (cash %d -> %d)" % [fine, money0, GameState.money])
	check(toast_seen("Golden Kush lost. Fined $%d." % fine), "toast: 'Golden Kush lost. Fined $%d.' %s" % [fine, toasts])
	check(Story.last_bark == "He counted those. Twenty-five.", "the Boss: '%s'" % Story.last_bark)
	check(_lost == [[GrowPlot.LOSS_FIRE, &"golden", fine]], "crop_lost(fire, golden, %d) %s" % [fine, _lost])
	await wait_frames(2)
	check(golden.stage == GrowPlot.Stage.EMPTY, "the tray is empty")
	# Another strain burns for free.
	toasts.clear()
	_lost.clear()
	money0 = GameState.money
	check(budget.server_crop_lost(GrowPlot.LOSS_GUNFIRE) == 0 and golden.server_crop_lost(GrowPlot.LOSS_GUNFIRE) == 0,
			"server_crop_lost is 0 for a strain nobody counts and for an empty tray")
	check(budget.server_scorch(0), "the Budget Bud plant burns")
	check(GameState.money == money0 and _lost.is_empty() and not toast_seen("lost."), "no fine for it")
	await wait_frames(2)
	# Arson on top: the write-up fine and the counted fine both come out of the cash.
	check(golden.server_plant(&"golden"), "replanted")
	_write_ups.clear()
	_lost.clear()
	money0 = GameState.money
	check(golden.server_scorch(BOB), "Bob burns it with nothing on the floor")
	check(_write_ups == [[BOB, Const.WRITE_UP_ARSON]], "arson write-up %s" % [_write_ups])
	check(GameState.money == money0 - b.write_up_fine - fine, "cash: the write-up fine and the counted fine (%d -> %d)" % [money0, GameState.money])
	check(Story.last_bark == "He counted those. Twenty-five.", "the Boss ends on the count ('%s')" % Story.last_bark)
	await wait_frames(2)
	# The gunfire cause, for the caller that will need it (a READY plant is counted too).
	_make_ready(golden, &"golden")
	_lost.clear()
	money0 = GameState.money
	check(golden.server_crop_lost(GrowPlot.LOSS_GUNFIRE) == fine and GameState.money == money0 - fine and _lost == [[GrowPlot.LOSS_GUNFIRE, &"golden", fine]],
			"server_crop_lost(gunfire) on a ready plant: fined %s" % [_lost])
	check(golden.stage == GrowPlot.Stage.READY, "the caller resets the tray itself (still there)")
	golden.server_reset()
	# Capped by the cash on hand.
	var keep := GameState.money
	check(GameState.server_try_spend(keep - 10, 1, "test drain") and GameState.money == 10, "cash drained to $10")
	check(golden.server_plant(&"golden"), "replanted")
	toasts.clear()
	_lost.clear()
	check(golden.server_scorch(0) and GameState.money == 0, "the fine takes what is there (cash %d)" % GameState.money)
	check(_lost == [[GrowPlot.LOSS_FIRE, &"golden", 10]] and toast_seen("Fined $10.") and Story.last_bark == "He counted those. Ten.",
			"fined $10: %s, '%s'" % [_lost, Story.last_bark])
	await wait_frames(2)
	check(golden.server_plant(&"golden"), "replanted")
	toasts.clear()
	_lost.clear()
	check(golden.server_scorch(0) and GameState.money == 0, "no cash: still zero")
	check(_lost == [[GrowPlot.LOSS_FIRE, &"golden", 0]] and toast_seen("Golden Kush lost. No cash left to fine.") and Story.last_bark == Story.line("counted_broke"),
			"announced without a fine: %s, '%s'" % [toasts, Story.last_bark])
	GameState.server_add_money(keep)
	await wait_frames(2)

	step("counted: eaten by the hostile plant")
	# One growing tray on the floor, nobody near it: the plant roots at GrowPlot1, walks over and eats.
	for i in range(1, 7):
		_plot(i).server_reset()
	var target := _plot(2)
	check(target.server_plant(&"golden") and target.server_water(1.0), "Golden Kush seedling in GrowPlot2")
	_put(bob, FAR_B)
	_put_me(FAR_A, 0.0)
	var id := Hostiles.server_spawn(&"budget", _plot(1).global_position)
	await wait_frames(1)
	var h := Hostiles.get_hostile(id) as HostilePlant
	if not check(h != null, "a hostile plant stands on the floor"):
		return
	toasts.clear()
	_lost.clear()
	money0 = GameState.money
	var waited := 0.0
	while target.stage != GrowPlot.Stage.EMPTY and waited < 30.0:
		Hostiles.tick(0.2)
		waited += 0.2
	check(target.stage == GrowPlot.Stage.EMPTY, "it ate the seedling (after %.1f s)" % waited)
	check(GameState.money == money0 - fine and _lost == [[GrowPlot.LOSS_EATEN, &"golden", fine]], "fined $%d for it %s" % [fine, _lost])
	check(toast_seen("Golden Kush lost. Fined $%d." % fine) and Story.bark_log.has("He counted those. Twenty-five."), "toast and the Boss's line")
	# A Budget Bud seedling eaten the same way costs nothing.
	check(target.server_plant(&"budget") and target.server_water(1.0), "Budget Bud seedling in GrowPlot2")
	_lost.clear()
	money0 = GameState.money
	waited = 0.0
	while target.stage != GrowPlot.Stage.EMPTY and waited < 30.0:
		Hostiles.tick(0.2)
		waited += 0.2
	check(target.stage == GrowPlot.Stage.EMPTY and GameState.money == money0 and _lost.is_empty(), "eaten Budget Bud: no fine (after %.1f s)" % waited)
	Hostiles.server_despawn_all()
	await wait_frames(2)
	check(Hostiles.count() == 0, "the floor is clear again")


# --- the rack: where it stands ------------------------------------------------------------------------------------------

func _test_rack_layout(b: BalanceConfig) -> void:
	step("drying racks: two in the north-west corner")
	var racks := get_tree().get_nodes_in_group(Const.GROUP_DRYING_RACKS)
	check(racks.size() == 2 and racks.has(rack1) and racks.has(rack2), "group '%s' holds exactly the two racks (%d)" % [Const.GROUP_DRYING_RACKS, racks.size()])
	check(rack1.global_position.is_equal_approx(Vector3(-7.5, 0.0, -6.6)) and rack2.global_position.is_equal_approx(Vector3(-5.0, 0.0, -6.6)),
			"at (-7.5, 0, -6.6) and (-5, 0, -6.6) (%s, %s)" % [rack1.global_position, rack2.global_position])
	var stations := room.get_node(^"Stations")
	var cabinet := stations.get_node_or_null(^"EmergencyCabinet")
	check(cabinet != null and rack1.get_index() == cabinet.get_index() + 1 and rack2.get_index() == cabinet.get_index() + 2,
			"they follow the EmergencyCabinet node under Stations")
	var bounds := room.get_bounds()
	for r: DryingRack in [rack1, rack2]:
		var tag := String(r.name) + ": "
		check(r is Interactable and r.is_in_group(Const.GROUP_INTERACTABLES), tag + "an Interactable")
		check(r.global_basis.z.is_equal_approx(Vector3.BACK), tag + "faces into the room (+Z)")
		check(r.get_node_or_null(^"Visual") is Node3D and r.get_node(^"Visual").get_child_count() >= 6, tag + "placeholder meshes under Visual")
		var body := r.get_node_or_null(^"Body") as StaticBody3D
		check(body != null and body.collision_layer == (Const.LAYER_WORLD | Const.LAYER_INTERACTABLE) and body.collision_mask == 0,
				tag + "a station collider on world + interactable")
		var seen: Array[Vector3] = []
		for hook in DryingRack.HOOK_COUNT:
			var at := r.get_hook_position(hook)
			check(bounds.has_point(at) and at.y > 0.8 and at.y < 1.6, tag + "hook %d hangs at a reachable height inside the room (%s)" % [hook + 1, at])
			check(at.z > r.global_position.z, tag + "hook %d is on the front side" % (hook + 1))
			for other in seen:
				check(at.distance_to(other) > 0.4, tag + "hook %d is clear of the others" % (hook + 1))
			seen.append(at)
		check(r.get_hung_count() == 0 and r.get_free_hook() == 0 and not r.is_full(), tag + "empty at the start")
		for mesh in r.get_node(^"Visual").find_children("*", "MeshInstance3D", true, false):
			var mi := mesh as MeshInstance3D
			var mat := mi.mesh.surface_get_material(0) if mi.mesh != null else null
			if not check(mat != null and mat.resource_path.begins_with("res://art/materials/toon_"), tag + "%s uses a library toon material" % mi.name):
				break
	check(absf(rack1.global_position.x - rack2.global_position.x) > 1.76 + 0.5, "the two frames do not touch (a gap a worker fits through)")
	# Nothing else stands there: every other station and every prop collider keeps clear of the frames.
	var space := world.get_world_3d().direct_space_state
	for r: DryingRack in [rack1, rack2]:
		var box := BoxShape3D.new()
		box.size = Vector3(1.8, 1.7, 0.8)
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = box
		q.transform = Transform3D(Basis.IDENTITY, r.global_position + Vector3(0.0, 0.95, 0.0))
		q.collision_mask = Const.LAYER_WORLD | Const.LAYER_INTERACTABLE
		q.exclude = [(r.get_node(^"Body") as StaticBody3D).get_rid(), me.get_rid(), bob.get_rid()]
		var hits := space.intersect_shape(q, 4)
		var names: PackedStringArray = []
		for hit in hits:
			names.append(str((hit["collider"] as Node).get_path()))
		check(hits.is_empty(), "%s: nothing overlaps the frame %s" % [r.name, names])
	check(Sfx.has_sound(&"rack_hang") and Sfx.has_sound(&"cured"), "the rack's sounds are registered")
	check(Sfx.measure(Sfx.get_stream(&"rack_hang")).seconds > 0.25 and Sfx.measure(Sfx.get_stream(&"cured")).seconds > 0.25,
			"with recipes of their own (not the default blip)")
	check(is_equal_approx(b.cure_sec, 20.0) and is_equal_approx(b.cure_bonus, 0.4), "20 s on a hook for +40%")
	await wait_frames(1)


# --- the rack: hang, dry, cure -------------------------------------------------------------------------------------------

func _test_rack(b: BalanceConfig) -> void:
	step("drying rack: prompts")
	# The test drives the racks' clocks itself (tick), so the frames between the awaits do not move them.
	rack1.set_process(false)
	rack2.set_process(false)
	_stand_at(rack1)
	await wait_physics(2)
	check(not rack1.can_interact(me) and rack1.get_denied_reason(me) == DryingRack.REASON_EMPTY_HANDS, "empty hands: '%s'" % rack1.get_denied_reason(me))
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, me.global_position, 1)
	await wait_frames(1)
	check(not rack1.can_interact(me) and rack1.get_denied_reason(me) == DryingRack.REASON_NOT_PRODUCT, "a watering can: '%s'" % rack1.get_denied_reason(me))
	items.server_despawn_item(can)
	await wait_frames(1)
	var bundle := _bundle(&"purple", 1, 1)
	await wait_frames(1)
	check(rack1.can_interact(me) and rack1.get_prompt(me) == "Hang to dry" and rack1.get_denied_reason(me) == "", "a bundle in hand: '%s'" % rack1.get_prompt(me))
	check(bundle.get_props() == {"strain_id": "purple", "amount": 1} and not bundle.rack and not bundle.cured and bundle.dry_left == 0.0,
			"a fresh bundle has no drying state %s" % [bundle.get_props()])
	check(bundle.get_label_text() == "Purple Haze x1", "its label is the plain one ('%s')" % bundle.get_label_text())

	step("drying rack: hang through the interact request")
	rack1.interact(me)
	await wait_until(func() -> bool: return bundle.holder_id == 0, 2.0, "the bundle left my hands")
	await wait_frames(1)
	var hook0 := rack1.get_hook_position(0)
	check(bundle.rack and is_equal_approx(bundle.dry_left, b.cure_sec) and not bundle.cured, "rack = true, dry_left = %.1f" % bundle.dry_left)
	check(bundle.global_position.distance_to(hook0) < 0.001 and bundle.rest_position.distance_to(hook0) < 0.001, "it rests exactly at hook 1 (%s)" % bundle.global_position)
	check(absf(bundle.rotation.x) < 0.001 and absf(bundle.rotation.z) < 0.001 and absf(angle_difference(bundle.rotation.y, rack1.global_rotation.y)) < 0.001,
			"upright, turned to the rack's front (%s)" % bundle.rotation)
	check(rack1.get_hook_item(0) == bundle and rack1.get_hung_count() == 1 and rack1.get_free_hook() == 1, "the rack sees it on hook 1; hook 2 is next")
	check(rack2.get_hung_count() == 0, "the other rack is still empty")
	check(_hung == [["DryingRack1", 0, 1]], "bundle_hung(0, 1) %s" % [_hung])
	check(bundle.get_props() == {"strain_id": "purple", "amount": 1, "rack": true, "dry_left": b.cure_sec}, "props %s" % [bundle.get_props()])
	var tag := bundle.get_node(^"AmountLabel") as Label3D
	check(tag.visible and tag.text == "x1 · 20 s" and bundle.get_status_text() == "Drying 20 s", "the label counts: '%s' / '%s'" % [tag.text, bundle.get_status_text()])
	check(bundle.is_drying() and bundle.can_interact(bob) and bundle.get_collider().collision_layer == Const.LAYER_ITEM, "a hanging bundle is an ordinary item: anyone can take it")
	check(not rack1.can_interact(me) and rack1.get_denied_reason(me) == DryingRack.REASON_EMPTY_HANDS, "my hands are empty again")

	step("drying rack: the countdown")
	rack1.tick(5.0)
	check(is_equal_approx(rack1.get_exact_left(bundle), 15.0) and is_equal_approx(bundle.dry_left, 15.0), "5 s later: 15 s left (%.2f)" % bundle.dry_left)
	rack1.tick(0.2)
	check(is_equal_approx(rack1.get_exact_left(bundle), 14.8) and is_equal_approx(bundle.dry_left, 15.0), "the synced value moves in %.1f s steps, rounded up (exact %.1f, synced %.1f)" % [DryingRack.SYNC_STEP, rack1.get_exact_left(bundle), bundle.dry_left])
	rack1.tick(0.4)
	check(is_equal_approx(rack1.get_exact_left(bundle), 14.4) and is_equal_approx(bundle.dry_left, 14.5), "exact 14.4, synced 14.5")
	check(tag.text == "x1 · 15 s", "label '%s'" % tag.text)
	# By itself, in real time (the rack's own _process).
	rack1.set_process(true)
	await wait_sec(1.2)
	rack1.set_process(false)
	check(bundle.dry_left <= 13.5 and bundle.dry_left >= 12.5 and not bundle.cured, "left alone for 1.2 s it keeps drying (%.1f s left)" % bundle.dry_left)

	step("drying rack: taken off early")
	var exact := rack1.get_exact_left(bundle)
	_put(bob, rack1.global_position + Vector3(0.0, 0.0, 1.4))
	bundle._server_interact(bob)
	check(bundle.holder_id == BOB, "Bob takes it off the hook (an ordinary pick-up)")
	rack1.tick(0.016)
	check(not bundle.rack and not bundle.cured and is_equal_approx(bundle.dry_left, exact), "rack = false, and it keeps what it had left (%.2f s)" % bundle.dry_left)
	check(rack1.get_hung_count() == 0 and rack1.get_free_hook() == 0, "the hook is free")
	check(bundle.get_status_text() == "%d s to dry" % ceili(exact) and not bundle.is_drying(), "status '%s'" % bundle.get_status_text())
	rack1.tick(30.0)
	rack2.tick(30.0)
	check(is_equal_approx(bundle.dry_left, exact) and not bundle.cured, "it never cures in the hand, however long (%.2f)" % bundle.dry_left)
	var plain := chute.get_sale_value(bundle)
	check(plain == 130, "half dry it is still worth the plain $%d" % plain)

	step("drying rack: hung again for the remainder (on the other rack)")
	_put(bob, rack2.global_position + Vector3(0.0, 0.0, 1.4))
	check(rack2.can_interact(bob), "Bob can hang it on rack 2")
	rack2._server_interact(bob)
	await wait_frames(1)
	check(bundle.holder_id == 0 and bundle.rack and rack2.get_hook_item(0) == bundle and rack1.get_hung_count() == 0, "it hangs on rack 2, hook 1")
	check(is_equal_approx(rack2.get_exact_left(bundle), exact) and bundle.dry_left >= exact and bundle.dry_left < exact + DryingRack.SYNC_STEP + 0.001,
			"for the remainder, not the whole time again (exact %.2f, synced %.1f)" % [rack2.get_exact_left(bundle), bundle.dry_left])
	rack1.tick(0.016)
	check(bundle.rack, "rack 1 leaves it alone")
	rack2.tick(exact - 0.4)
	check(not bundle.cured and is_equal_approx(bundle.dry_left, 0.5), "0.4 s short: not cured yet (%.1f)" % bundle.dry_left)
	_cured.clear()
	rack2.tick(0.5)
	check(bundle.cured and bundle.dry_left == 0.0 and bundle.rack, "cured = true, dry_left = 0 (still on its hook)")
	check(_cured == [["DryingRack2", 0]], "bundle_cured(0) %s" % [_cured])
	check(tag.text == "Cured x1" and bundle.get_status_text() == "Cured" and bundle.get_label_text() == "Purple Haze x1 (Cured)",
			"its label reads Cured ('%s', '%s')" % [tag.text, bundle.get_label_text()])
	var fresh := Toon.grade(b.get_seed(&"purple").color)
	var tint := bundle.get(&"_tint") as StandardMaterial3D
	check(tint != null and tint.albedo_color.is_equal_approx(fresh.darkened(Product.CURED_DARKEN)) and tint.albedo_color.v < fresh.v,
			"a darker tint on the buds (%s, fresh %s)" % [tint.albedo_color.to_html(false) if tint != null else "-", fresh.to_html(false)])
	check(bundle.get_props() == {"strain_id": "purple", "amount": 1, "rack": true, "cured": true}, "props %s" % [bundle.get_props()])
	check(not bundle.is_drying() and rack2.get_hung_count() == 1, "a cured bundle keeps its hook until someone takes it")
	rack2.tick(5.0)
	check(bundle.cured and bundle.dry_left == 0.0 and _cured.size() == 1, "nothing more happens to it there")
	bundle._server_interact(bob)
	rack2.tick(0.016)
	check(bundle.holder_id == BOB and not bundle.rack and bundle.cured, "taken: cured stays, rack clears")
	check(not rack1.can_interact(bob) and rack1.get_denied_reason(bob) == DryingRack.REASON_CURED and not rack1.server_hang(bob),
			"a cured bundle is not hung again: '%s'" % rack1.get_denied_reason(bob))

	step("drying rack: three hooks, then full")
	var cured_bundle := bundle
	items.server_drop_item(cured_bundle, FAR_B)
	_put(bob, rack1.global_position + Vector3(0.0, 0.0, 1.4))
	_hung.clear()
	var hung: Array[Product] = []
	for i in 3:
		var p := _bundle(&"golden", 2, BOB)
		check(rack1.server_hang(bob), "bundle %d hangs" % (i + 1))
		hung.append(p)
	await wait_frames(1)
	check(_hung == [["DryingRack1", 0, BOB], ["DryingRack1", 1, BOB], ["DryingRack1", 2, BOB]], "hooks 1, 2, 3 in order %s" % [_hung])
	for i in 3:
		check(rack1.get_hook_item(i) == hung[i] and hung[i].global_position.distance_to(rack1.get_hook_position(i)) < 0.001, "hook %d holds bundle %d" % [i + 1, i + 1])
	check(rack1.is_full() and rack1.get_free_hook() == -1 and rack1.get_hung_count() == 3, "the rack is full")
	var fourth := _bundle(&"golden", 2, BOB)
	await wait_frames(1)
	check(not rack1.can_interact(bob) and rack1.get_denied_reason(bob) == "Rack is full.", "a fourth bundle: '%s'" % rack1.get_denied_reason(bob))
	check(not rack1.server_hang(bob) and fourth.holder_id == BOB and not fourth.rack, "the host refuses it; it stays in Bob's hands")
	check(rack2.can_interact(bob), "the other rack would take it")
	# The local denial path (the prompt's greyed line is also the toast).
	var mine := _bundle(&"budget", 1, 1)
	_stand_at(rack1)
	await wait_physics(2)
	toasts.clear()
	rack1.interact(me)
	await wait_frames(2)
	check(toast_seen("Rack is full.") and mine.holder_id == 1, "pressing E anyway: the 'Rack is full.' toast %s" % [toasts])
	items.server_despawn_item(mine)
	# All three dry on their own clocks; the middle one is taken and its hook is used again.
	rack1.tick(4.0)
	check(is_equal_approx(hung[0].dry_left, 16.0) and is_equal_approx(hung[1].dry_left, 16.0) and is_equal_approx(hung[2].dry_left, 16.0), "three bundles dry side by side (16 s left each)")
	items.server_drop_item(fourth, FAR_A)
	hung[1]._server_interact(bob)
	rack1.tick(0.016)
	check(hung[1].holder_id == BOB and not hung[1].rack and rack1.get_free_hook() == 1 and not rack1.is_full(), "the middle bundle is taken: hook 2 is free")
	items.server_drop_item(hung[1], FAR_A + Vector3(0.5, 0.0, 0.0))
	check(items.server_give_item(fourth, BOB) and rack1.server_hang(bob), "the fourth bundle hangs now")
	await wait_frames(1)
	check(rack1.get_hook_item(1) == fourth and is_equal_approx(fourth.dry_left, b.cure_sec) and rack1.is_full(), "on hook 2, with the whole %.0f s ahead of it" % b.cure_sec)
	rack1.tick(16.0)
	check(hung[0].cured and hung[2].cured and not fourth.cured and is_equal_approx(fourth.dry_left, 4.0), "the two that stayed are cured; the late one has 4 s left")
	# A despawned bundle (sold from the hook by a chute shot, a reset) just frees its hook.
	items.server_despawn_item(hung[0])
	await wait_frames(1)
	rack1.tick(0.016)
	check(rack1.get_hook_item(0) == null and rack1.get_hung_count() == 2, "a bundle that is gone frees its hook")
	# A bundle that only lies near the rack is not hanging.
	var loose := _bundle(&"budget", 1, 0)
	loose.server_set_rest(rack1.get_hook_position(0))
	await wait_frames(1)
	check(rack1.get_hook_item(0) == null and not loose.rack, "a bundle without `rack` at a hook is not counted as hung")
	rack1.tick(25.0)
	check(not loose.cured and loose.dry_left == 0.0, "and never dries")
	# Spawn props carry the drying state (late joiners get the live values through the synchronizer).
	var born := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1, "cured": true}, FAR_A) as Product
	check(born != null and born.cured and born.get_props().get("cured") == true, "a bundle can spawn cured (props)")
	for it in [loose, born, hung[1], hung[2], fourth]:
		items.server_despawn_item(it)
	await wait_frames(1)
	rack1.tick(0.016)
	rack2.tick(0.016)
	check(rack1.get_hung_count() == 0 and rack2.get_hung_count() == 0, "both racks are empty")
	check(items.server_give_item(cured_bundle, BOB), "Bob holds the cured Purple Haze bundle again")
	rack1.set_process(true)
	rack2.set_process(true)


# --- the chute ----------------------------------------------------------------------------------------------------------

func _test_sale(b: BalanceConfig) -> void:
	step("the chute: a cured bundle pays more")
	var purple := b.get_seed(&"purple")
	var golden := b.get_seed(&"golden")
	check(TurnInStation.compute_sale_value(purple, 1, 1.0) == 130 and TurnInStation.compute_sale_value(purple, 1, 1.0, true) == 182,
			"Purple Haze x1: $130 wet, $182 cured (x%.1f)" % (1.0 + b.cure_bonus))
	check(TurnInStation.compute_sale_value(golden, 2, 1.0, true) == 336 and TurnInStation.compute_sale_value(golden, 2, 1.1, true) == int(round(240 * 1.1 * 1.4)),
			"Golden Kush x2 cured: $336; the Better Cut multiplies on top")
	var cured_bundle := items.get_held_by(BOB) as Product
	if not check(cured_bundle != null and cured_bundle.cured, "Bob holds the cured bundle"):
		return
	_put(bob, chute.global_position + chute.global_basis.z * 1.3)
	check(TurnInStation.is_cured(cured_bundle) and chute.get_sale_value(cured_bundle) == 182, "the chute prices it at $%d" % chute.get_sale_value(cured_bundle))
	check(chute.get_prompt(bob) == "Deposit Purple Haze x1, cured (+$182)", "prompt '%s'" % chute.get_prompt(bob))
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	var deposited0 := GameState.get_stat(BOB, Const.STAT_DEPOSITED)
	check(GameState.get_stat(BOB, Const.STAT_CURED) == 0, "no cured deposits yet")
	chute._server_interact(bob)
	await wait_frames(2)
	check(GameState.money == money0 + 182 and GameState.round_sales == sales0 + 182, "paid $182 (yield x value x 1.4)")
	check(GameState.get_stat(BOB, Const.STAT_CURED) == 1 and GameState.get_stat(BOB, Const.STAT_DEPOSITED) == deposited0 + 182, "STAT_CURED 1 for the seller, deposited +182")
	check(items.get_held_by(BOB) == null, "the bundle is gone")
	# An uncured bundle (even one that hung for a while) sells at the plain value and counts nothing.
	var wet := _bundle(&"purple", 1, BOB)
	_put(bob, rack1.global_position + Vector3(0.0, 0.0, 1.4))
	check(rack1.server_hang(bob), "another bundle hangs")
	rack1.tick(12.0)
	wet._server_interact(bob)
	rack1.tick(0.016)
	check(wet.holder_id == BOB and not wet.cured and not wet.rack and is_equal_approx(wet.dry_left, 8.0), "taken 8 s early")
	_put(bob, chute.global_position + chute.global_basis.z * 1.3)
	check(chute.get_sale_value(wet) == 130 and chute.get_prompt(bob) == "Deposit Purple Haze x1 (+$130)", "prompt '%s'" % chute.get_prompt(bob))
	money0 = GameState.money
	check(chute.server_sell_item(wet, BOB), "sold")
	await wait_frames(2)
	check(GameState.money == money0 + 130, "paid the plain $130")
	check(GameState.get_stat(BOB, Const.STAT_CURED) == 1, "STAT_CURED unchanged")
	# A cured bundle thrown into the chute pays the same (the one sale path).
	var shot := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "golden", "amount": 2, "cured": true}, FAR_A) as Product
	money0 = GameState.money
	check(chute.server_sell_item(shot, 1), "a cured bundle sold for the host")
	await wait_frames(2)
	check(GameState.money == money0 + 336 and GameState.get_stat(1, Const.STAT_CURED) == 1, "$336, STAT_CURED for that seller")
	check(GameState.is_playing(), "the shift is still running")


# --- helpers ------------------------------------------------------------------------------------------------------------

func _plot(i: int) -> GrowPlot:
	return room.get_station("GrowPlot%d" % i) as GrowPlot


## Plants `strain` and jumps the plot to READY (the host sets synced state directly, like the farm tests).
func _make_ready(p: GrowPlot, strain: StringName) -> void:
	if p.stage != GrowPlot.Stage.EMPTY:
		p.server_reset()
	p.server_plant(strain)
	p.server_water(1.0)
	p.stage = GrowPlot.Stage.READY


func _bundle(strain: StringName, amount: int, holder: int) -> Product:
	return items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": strain, "amount": amount}, FAR_A + Vector3(1.0, 0.0, 0.0), holder) as Product


func _clear_products() -> void:
	for it in items.get_items_of_type(Const.ITEM_PRODUCT):
		items.server_despawn_item(it)


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


## My body 1.3 m in front of a station, facing it.
func _stand_at(target: Node3D) -> void:
	var pos := target.global_position + target.global_basis.z.normalized() * 1.3
	pos.y = 0.02
	me.velocity = Vector3.ZERO
	me.global_position = pos
	me.look_at(Vector3(target.global_position.x, pos.y, target.global_position.z), Vector3.UP)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
