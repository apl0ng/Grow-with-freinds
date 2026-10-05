extends "res://tools/tests/smoke_base.gd"
## M15 economy suite (CONTRACTS.md "M15", "Economy"). Pure: no host, no world; it reads data/balance.tres through
## Config and runs the shift model in tools/tests/econ_sim.gd.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/economy_body.gd
##   ... --body=res://tools/tests/economy_body.gd --report     adds the strain tables, the event tax line by line, the
##                                                             cure policies shift by shift and the market / contract
##                                                             what-ifs (printed, not checked)
## What it pins:
##   numbers   the values the M15 retune shipped, and the payment formula's table for shifts 1 to 6 and 1 to 4 workers
##   floor     the model's station positions against scenes/world/room.tscn
##   targets   a careful solo worker makes shift 1 with about a quarter to spare; four average workers make shift 3;
##             nobody makes shift 6 without favors and cured bundles (and three or four careful workers with both
##             do); no strain is strictly dominated at the shift it unlocks
##   shape     more workers never deposit less; curing is a choice (not for cheap bundles, not for a solo worker,
##             not for every dear bundle: six hooks)
## It prints the model's table for the M14 numbers and for the shipped ones. A later change of a number that breaks
## a target fails here; the model's assumptions are in the header of econ_sim.gd.
## M18 (economy2): the payment for a team and each team's own run (to its final notice, Sim.run_team, with the
## half-time look). Pinned: the payment table and its shrinking raise; four average workers reach the final notice
## and do not clear it without favors or without the racks; three or four careful workers clear it with both and not
## without either; nobody of one, three or four clears without cured bundles; the middle of the run is tighter for
## full crews than in M17. Targets the model shows out of reach are printed as GAP lines, not checked.

const Sim := preload("res://tools/tests/econ_sim.gd")

## quota_for_round(shift, workers): rows = shifts 1 to 6, columns = 1 to 4 workers.
## M18 economy2: +35% a worker beyond the first in shift 1, five points less each shift, +10% in shift 6 (the M17
## number: M15 to M17 had +10% in every shift, so the last row did not move).
const QUOTA_TABLE: Array = [
	[350, 473, 595, 717],
	[1325, 1723, 2120, 2518],
	[2535, 3169, 3803, 4437],
	[4174, 5009, 5844, 6678],
	[6592, 7581, 8570, 9559],
	[10429, 11472, 12515, 13558],
]
const CAREFUL := 0
const AVERAGE := 1
const SLOPPY := 2

var _b: BalanceConfig
var _crews: Array = []
# M18 economy2: each team through its own run, [skill][workers - 1] (shipped numbers); variant runs by name.
var _teams: Array = []
var _variants: Dictionary = {}


func _run() -> void:
	_label = "economy"
	await get_tree().process_frame
	_b = Config.balance
	var t0 := Time.get_ticks_msec()

	step("the shipped numbers")
	_test_numbers()
	step("the payment due, shifts 1 to 6, 1 to 4 workers")
	_test_quota_table()
	step("the model's floor is the room")
	_test_floor()
	step("the tax: events and mutations")
	_test_tax()

	step("the model, M14 numbers (before)")
	var before := Sim.baseline(_b)
	var before_crews := Sim.all_crews(before)
	print(Sim.format_table(before, "M14 numbers", {}, before_crews))
	_test_before(before_crews)
	await get_tree().process_frame

	step("the model, shipped numbers (after)")
	_crews = Sim.all_crews(_b)
	print(Sim.format_table(_b, "shipped numbers", {}, _crews))
	await get_tree().process_frame

	step("target: a careful solo worker makes shift 1 with about a quarter to spare")
	_test_solo_first_shift()
	step("target: four average workers who split up make shift 3")
	_test_four_average()
	step("target: nobody makes shift 6 without favors and cured bundles")
	_test_sixth_shift()
	await get_tree().process_frame
	step("target: no strain is strictly dominated at the shift it unlocks")
	_test_strains()
	step("more workers never deposit less")
	_test_monotonic()
	step("curing is a choice")
	_test_cure()
	await get_tree().process_frame
	await _run_m18()
	if Config.has_arg("report"):
		await get_tree().process_frame
		_report()
	print("[economy] model time %.1f s" % (float(Time.get_ticks_msec() - t0) / 1000.0))
	finish()


func _row(skill: int, workers: int, shift: int) -> Dictionary:
	return _crews[skill][workers - 1]["shifts"][shift - 1]


func _crew(skill: int, workers: int) -> Dictionary:
	return _crews[skill][workers - 1]


func _total(crew: Dictionary, from_shift: int = 1, to_shift: int = 6) -> float:
	var sum := 0.0
	for r: Dictionary in crew["shifts"]:
		if int(r["shift"]) >= from_shift and int(r["shift"]) <= to_shift:
			sum += float(r["deposits"])
	return sum


# --- numbers ---------------------------------------------------------------------------------------------------------

func _test_numbers() -> void:
	check(_b.base_quota == 350 and is_equal_approx(_b.quota_scale, 1.82) and _b.quota_add == 688,
			"payment due: %d, x%.2f + %d a shift (M14: 350, x1.5 + 150)" % [_b.base_quota, _b.quota_scale, _b.quota_add])
	# M18 economy2: the raise for a worker beyond the first shrinks by the shift (M15 to M17: +10% flat).
	check(is_equal_approx(_b.quota_per_extra_player, 0.35) and is_equal_approx(_b.quota_team_growth, -0.05),
			"+%d%% a worker beyond the first in shift 1, %+d points a shift (M17: +10%% flat; M14: +20%% flat)" % [
			roundi(_b.quota_per_extra_player * 100.0), roundi(_b.quota_team_growth * 100.0)])
	check(is_equal_approx(_b.cure_sec, 45.0) and is_equal_approx(_b.cure_bonus, 0.4),
			"a cure takes %.0f s for +%d%% (M14: 20 s, +40%%)" % [_b.cure_sec, roundi(_b.cure_bonus * 100.0)])
	var purple := _b.get_seed(&"purple")
	var golden := _b.get_seed(&"golden")
	check(purple.sale_value_per_unit == 140 and purple.cost == 45 and is_equal_approx(purple.grow_time_multiplier, 1.3),
			"Purple Haze pays $%d a unit (M14: $130); cost and grow time untouched" % purple.sale_value_per_unit)
	check(golden.sale_value_per_unit == 125 and golden.cost == 90 and golden.yield_amount == 2 and golden.counted,
			"Golden Kush pays $%d a unit, $%d a plant (M14: $120, $240); still counted" % [golden.sale_value_per_unit, golden.sale_value_per_unit * golden.yield_amount])
	check(_b.starting_money == 150 and is_equal_approx(_b.round_length_sec, 300.0) and _b.stage_durations == [20.0, 25.0, 30.0]
			and is_equal_approx(_b.walk_speed, 4.5) and is_equal_approx(_b.sprint_speed, 7.0),
			"untouched: $150 to start, a 300 s shift, stages 20 / 25 / 30 s, walk 4.5 and sprint 7 m/s")
	var unlocks: Dictionary = {}
	for s: SeedDef in _b.seeds:
		unlocks[String(s.id)] = s.unlock_round
	check(unlocks == {"budget": 1, "purple": 1, "creeper": 1, "golden": 2, "nightshift": 3, "brick": 4}, "strains unlock by shift: %s" % [unlocks])
	# The baseline is the shipped config with exactly the retuned numbers put back.
	var before := Sim.baseline(_b)
	check(before.base_quota == 350 and is_equal_approx(before.quota_scale, 1.5) and before.quota_add == 150
			and is_equal_approx(before.quota_per_extra_player, 0.2) and is_equal_approx(before.quota_team_growth, 0.0) and is_equal_approx(before.cure_sec, 20.0)
			and before.get_seed(&"purple").sale_value_per_unit == 130 and before.get_seed(&"golden").sale_value_per_unit == 120,
			"Sim.baseline() is the M14 economy")
	check(is_equal_approx(_b.quota_scale, 1.82) and purple.sale_value_per_unit == 140, "and it is a copy: the live resource is untouched")


func _test_quota_table() -> void:
	var table := Sim.quota_table(_b)
	var lines: PackedStringArray = []
	for n in table.size():
		lines.append("      shift %d: %s" % [n + 1, table[n]])
	print("\n".join(lines))
	check(table.size() == QUOTA_TABLE.size(), "six shifts")
	for n in mini(table.size(), QUOTA_TABLE.size()):
		var want: Array = QUOTA_TABLE[n]
		var got: Array = table[n]
		var same := got.size() == want.size()
		for p in mini(got.size(), want.size()):
			same = same and int(got[p]) == int(want[p])
		check(same, "shift %d: $%d solo, $%d / $%d / $%d for two / three / four" % [n + 1, want[0], want[1], want[2], want[3]])
	check(_b.quota_for_round(1, 0) == 350 and _b.quota_for_round(0, 1) == 350, "no workers / shift 0 read as one worker, shift 1")
	for n in range(1, 7):
		check(_b.quota_for_round(n + 1, 1) > _b.quota_for_round(n, 1) and _b.quota_for_round(n, 4) > _b.quota_for_round(n, 3),
				"shift %d: the next shift asks for more, and four workers for more than three" % n)


func _test_floor() -> void:
	var room := (load("res://scenes/world/room.tscn") as PackedScene).instantiate() as Room
	if not check(room != null, "room.tscn instantiates"):
		return
	var stations := room.get_node_or_null(^"Stations") as Node3D
	var wrong: PackedStringArray = []
	for station: String in Sim.STATIONS:
		var node := stations.get_node_or_null(NodePath(station)) as Node3D if stations != null else null
		if node == null:
			wrong.append(station + " (missing)")
			continue
		var t := stations.transform * node.transform
		var at := Vector2(t.origin.x, t.origin.z)
		var front := Vector2(t.basis.z.x, t.basis.z.z)
		var entry: Array = Sim.STATIONS[station]
		if at.distance_to(entry[0]) > 0.01 or front.distance_to(entry[1]) > 0.01:
			wrong.append("%s at %s front %s" % [station, at, front])
	check(wrong.is_empty(), "the %d stations of the model stand where the room has them %s" % [Sim.STATIONS.size(), wrong])
	check(Sim.TRAY_COUNT == Room.GROW_PLOT_COUNT and Sim.RACK_COUNT * Sim.HOOKS_PER_RACK == 2 * DryingRack.HOOK_COUNT,
			"ten trays, two racks of three hooks")
	var fuse := stations.get_node_or_null(^"FuseBox") as Node3D if stations != null else null
	var line := room.get_node_or_null(^"Decor/HeadcountSpot") as Node3D
	var arrival := room.get_node_or_null(^"Arrivals/Arrival0") as Node3D
	check(fuse != null and Vector2(fuse.position.x, fuse.position.z).distance_to(Sim.FUSE_BOX) < 0.01
			and line != null and Vector2(line.position.x, line.position.z).distance_to(Sim.HEADCOUNT_SPOT) < 0.01
			and arrival != null and Vector2(arrival.position.x, arrival.position.z).distance_to(Sim.ARRIVAL) < 0.01,
			"the fuse box, the head-count line and the first arrival point too")
	room.free()
	# Distances: straight where the line is clear, through the gate and the doorways where it is not.
	var shop_tray := Sim.distance(Sim.P_SHOP, Sim.P_TRAY0 + 2)
	check(absf(shop_tray - Sim.points()[Sim.P_SHOP].distance_to(Sim.points()[Sim.P_TRAY0 + 2])) < 0.01 and absf(shop_tray - 5.3) < 0.1,
			"window -> tray 3 is a straight %.1f m through the gate" % shop_tray)
	var shop_corner := Sim.distance(Sim.P_SHOP, Sim.P_TRAY0)
	check(shop_corner > Sim.points()[Sim.P_SHOP].distance_to(Sim.points()[Sim.P_TRAY0]) + 0.5,
			"window -> tray 1 goes round the fence (%.1f m on foot)" % shop_corner)
	var rack_chute := Sim.distance(Sim.P_RACK0, Sim.P_CHUTE)
	var tank_hall := Sim.distance(Sim.P_WELL, Sim.P_TRAY0 + 6)
	check(rack_chute > 18.0 and rack_chute < 24.0 and tank_hall > 20.0 and tank_hall < 26.0,
			"rack -> chute %.1f m, tank -> hall tray %.1f m: the hall is a walk" % [rack_chute, tank_hall])
	var symmetric := true
	for a in Sim.POINT_COUNT:
		for c in Sim.POINT_COUNT:
			symmetric = symmetric and absf(Sim.distance(a, c) - Sim.distance(c, a)) < 0.01 and is_finite(Sim.distance(a, c))
	check(symmetric, "every distance is finite and the same both ways")


func _test_tax() -> void:
	var weights := 0
	for kind: String in Sim.EVENT_WEIGHTS:
		weights += int(Sim.EVENT_WEIGHTS[kind])
	# M17 mayhem3: fourteen kinds (the scale and the phone), the weights of CONTRACTS "M17", "Mayhem 3".
	check(Sim.EVENT_WEIGHTS.size() == 14 and weights == 100, "fourteen event kinds, weights sum to 100")
	var same_weights := true
	for kind: String in Sim.EVENT_WEIGHTS:
		if int(Events.WEIGHTS.get(StringName(kind), -1)) != int(Sim.EVENT_WEIGHTS[kind]):
			same_weights = false
	check(same_weights and Events.WEIGHTS.size() == Sim.EVENT_WEIGHTS.size(), "the model's weights are the scheduler's")
	check(Sim.event_costs(_b, 1, CAREFUL).size() == 14, "one cost line per kind")
	var first := Sim.event_tax(_b, 1, CAREFUL, 1)
	var sixth := Sim.event_tax(_b, 4, CAREFUL, 6)
	check(float(first["events"]) > 3.0 and float(first["events"]) < 4.0 and float(sixth["events"]) > float(first["events"]) + 0.5,
			"%.1f events in shift 1, %.1f in shift 6 (the gaps shrink)" % [first["events"], sixth["events"]])
	check(float(first["worker_share"]) > 0.02 and float(first["worker_share"]) < 0.08 and float(first["stall_share"]) < 0.03,
			"a careful solo worker loses %.1f%% of the shift to them, the trays %.1f%% of their growth" % [
			float(first["worker_share"]) * 100.0, float(first["stall_share"]) * 100.0])
	var sloppy := Sim.event_tax(_b, 4, SLOPPY, 6)
	check(float(sloppy["stall_share"]) > float(sixth["stall_share"]) * 2.0 and float(sloppy["cash"]) > float(sixth["cash"]) * 2.0,
			"a sloppy crew pays more: %.1f%% of the growth and $%.0f a shift against %.1f%% and $%.0f" % [
			float(sloppy["stall_share"]) * 100.0, sloppy["cash"], float(sixth["stall_share"]) * 100.0, sixth["cash"]])
	check(float(first["quota_factor"]) > 1.01 and float(first["quota_factor"]) < 1.05, "the expected audit raises the payment by %.1f%%" % ((float(first["quota_factor"]) - 1.0) * 100.0))
	var off := Sim.run_shift(_b, {"workers": 1, "skill": CAREFUL, "shift": 1, "events": false})
	var on := Sim.run_shift(_b, {"workers": 1, "skill": CAREFUL, "shift": 1})
	check(float(off["deposits"]) >= float(on["deposits"]) and is_equal_approx(float(off["quota_taxed"]), float(off["quota"])),
			"without the tax a shift is never worse ($%.0f against $%.0f)" % [off["deposits"], on["deposits"]])
	var again := Sim.run_shift(_b, {"workers": 1, "skill": CAREFUL, "shift": 1})
	check(is_equal_approx(float(again["deposits"]), float(on["deposits"])) and is_equal_approx(float(again["met_at"]), float(on["met_at"])),
			"the model is deterministic: the same shift twice is the same number")


# --- before ------------------------------------------------------------------------------------------------------------

func _test_before(crews: Array) -> void:
	# What the retune answers: with the M14 payment every careful crew and every average team walked through six shifts.
	var all_six := true
	for skill in [CAREFUL, AVERAGE]:
		for workers in range(1, 5):
			if skill == AVERAGE and workers == 1:
				continue
			all_six = all_six and Sim.crew_shifts_made(crews[skill][workers - 1]) == 6
	check(all_six, "M14: every careful crew and every average team of two to four pays all six shifts")
	var solo: Dictionary = crews[CAREFUL][0]["shifts"][0]
	check(float(solo["deposits"]) > 1.6 * float(solo["quota"]), "M14: a careful solo worker deposits $%.0f against $%d in shift 1" % [solo["deposits"], solo["quota"]])
	var four: Dictionary = crews[CAREFUL][3]["shifts"][5]
	check(float(four["deposits"]) > 2.5 * float(four["quota"]), "M14: four careful workers deposit $%.0f against $%d in shift 6" % [four["deposits"], four["quota"]])


# --- targets -----------------------------------------------------------------------------------------------------------

func _test_solo_first_shift() -> void:
	var r := _row(CAREFUL, 1, 1)
	var spare := float(r["deposits"]) / float(r["quota"]) - 1.0
	check(int(r["made"]) == Sim.JITTERS.size(), "all %d campaigns meet $%d (at %.0f s on average)" % [Sim.JITTERS.size(), r["quota"], r["met_at"]])
	# M15 lead: shift 1 is the shift a new crew has to get through to see anything else (conditions, the market and
	# the first unlock start at shift 2), so it is the M14 payment again: a careful worker has a lot to spare and an
	# average one alone just makes it. The curve catches up at shift 2.
	check(spare >= 0.5, "$%.0f by the buzzer: %.0f%% over the payment (shift 1 is the easy one: at least half again)" % [r["deposits"], spare * 100.0])
	var plain := _row(AVERAGE, 1, 1)
	check(float(plain["deposits"]) > float(plain["quota"]) and float(plain["deposits"]) < float(plain["quota"]) * 1.3,
			"an average worker alone deposits $%.0f against $%d: over it, with under a third to spare" % [plain["deposits"], plain["quota"]])
	var second := _row(AVERAGE, 1, 2)
	check(float(second["deposits"]) < float(second["quota"]), "and misses shift 2 alone ($%.0f against $%d): the curve catches up" % [second["deposits"], second["quota"]])
	check(float(r["low"]) > float(r["quota"]) * 1.1, "the slowest of the five still has a tenth to spare ($%.0f)" % r["low"])
	var average := _row(AVERAGE, 1, 1)
	print("      for the record: an average solo worker deposits $%.0f against $%d (%d/%d make it); a sloppy one $%.0f" % [
			average["deposits"], average["quota"], average["made"], Sim.JITTERS.size(), _row(SLOPPY, 1, 1)["deposits"]])


func _test_four_average() -> void:
	for shift in [1, 2, 3]:
		var r := _row(AVERAGE, 4, shift)
		check(int(r["made"]) == Sim.JITTERS.size() and float(r["low"]) > float(r["quota"]) * 1.1,
				"shift %d: $%.0f against $%d, all %d campaigns, the slowest with a tenth to spare ($%.0f)" % [
				shift, r["deposits"], r["quota"], Sim.JITTERS.size(), r["low"]])
	check(Sim.crew_shifts_made(_crew(AVERAGE, 4)) >= 3 and Sim.crew_shifts_made(_crew(AVERAGE, 4)) < 6,
			"four average workers pay %d shifts in a row, not six" % Sim.crew_shifts_made(_crew(AVERAGE, 4)))
	check(Sim.crew_shifts_made(_crew(AVERAGE, 3)) >= 3, "three average workers make shift 3 as well (%d in a row)" % Sim.crew_shifts_made(_crew(AVERAGE, 3)))
	check(Sim.crew_shifts_made(_crew(SLOPPY, 4)) < 3, "four sloppy workers who stay in the main room do not (%d in a row)" % Sim.crew_shifts_made(_crew(SLOPPY, 4)))


func _test_sixth_shift() -> void:
	# With both: the best crews get there, late in the shift.
	for workers in [3, 4]:
		var r := _row(CAREFUL, workers, 6)
		check(Sim.crew_shifts_made(_crew(CAREFUL, workers)) == 6 and int(r["made"]) >= 3,
				"%d careful workers with favors and racks: $%.0f against $%d, %d/%d campaigns, met at %.0f s" % [
				workers, r["deposits"], r["quota"], r["made"], Sim.JITTERS.size(), r["met_at"]])
		check(int(r["cured"]) > 0 and float(r["low"]) > float(r["quota"]), "they cure (%d bundles over the five) and the slowest still deposits more than is due" % int(r["cured"]))
	# Nobody else does, with or without.
	for skill in [CAREFUL, AVERAGE, SLOPPY]:
		for workers in range(1, 5):
			if skill == CAREFUL and workers >= 3:
				continue
			var r := _row(skill, workers, 6)
			check(int(r["made"]) == 0 and Sim.crew_shifts_made(_crew(skill, workers)) < 6,
					"%s x%d: $%.0f against $%d, no campaign meets shift 6" % [Sim.SKILL_NAMES[skill], workers, r["deposits"], r["quota"]])
	# Without favors, or without the racks: no careful crew, and not the best average one.
	var crews: Array = [[CAREFUL, 1], [CAREFUL, 2], [CAREFUL, 3], [CAREFUL, 4], [AVERAGE, 4]]
	for variant: Array in [["no favors", {"favors": false}], ["no racks", {"racks": false}]]:
		for c: Array in crews:
			var opt: Dictionary = (variant[1] as Dictionary).duplicate()
			opt["skill"] = c[0]
			opt["workers"] = c[1]
			var crew := Sim.run_crew(_b, opt)
			var r: Dictionary = crew["shifts"][5]
			# M18 economy2: against the payment the model plays (with the expected audit), not the bare formula: the
			# tighter middle carries more cash into shift 6 and three careful workers without the racks now end $78 over
			# the bare number and still short of the payment.
			var due := float(r["quota"]) * float(Sim.event_tax(_b, c[1], c[0], 6)["quota_factor"])
			check(int(r["made"]) == 0 and float(r["high"]) < due and Sim.crew_shifts_made(crew) < 6,
					"%s, %s x%d: at best $%.0f against $%.0f in shift 6 ($%d and the expected audit; %d shifts in a row)" % [
					variant[0], Sim.SKILL_NAMES[c[0]], c[1], r["high"], due, r["quota"], Sim.crew_shifts_made(crew)])


func _test_strains() -> void:
	# Closed form, per plant: dollars per worker-second, per tray-second and per dollar of seed.
	for s: SeedDef in _b.seeds:
		var free_at: PackedStringArray = []
		for skill in Sim.SKILLS.size():
			if not Sim.dominated_strains(_b, skill, s.unlock_round).has(String(s.id)):
				free_at.append(Sim.SKILL_NAMES[skill])
		check(not free_at.is_empty(), "%s at shift %d: no strain on sale beats it on all three for a %s worker" % [
				s.display_name, s.unlock_round, " / ".join(free_at)])
	var careful: Dictionary = {}
	for m: Dictionary in Sim.strain_metrics(_b, CAREFUL, 99, false):
		careful[m["id"]] = m
	var before: Dictionary = {}
	for m: Dictionary in Sim.strain_metrics(Sim.baseline(_b), CAREFUL, 99, false):
		before[m["id"]] = m
	# Purple Haze: the weakest strain with a trait per worker-second in M14 (five waterings for $130).
	check(float(before["purple"]["per_labour"]) < float(before["creeper"]["per_labour"]),
			"M14: Purple Haze earned less per worker-second than Creeper ($%.2f against $%.2f)" % [before["purple"]["per_labour"], before["creeper"]["per_labour"]])
	check(float(careful["purple"]["per_labour"]) > float(careful["creeper"]["per_labour"]) and float(careful["purple"]["per_labour"]) > float(careful["budget"]["per_labour"]),
			"now it beats Creeper and Budget Bud ($%.2f against $%.2f and $%.2f)" % [careful["purple"]["per_labour"], careful["creeper"]["per_labour"], careful["budget"]["per_labour"]])
	check(float(careful["purple"]["per_labour"]) < float(careful["golden"]["per_labour"]) and float(careful["purple"]["waterings"]) > float(careful["golden"]["waterings"]),
			"and stays the thirsty one, well under Golden Kush (%.1f waterings a plant against %.1f)" % [careful["purple"]["waterings"], careful["golden"]["waterings"]])
	# Golden Kush: counted was a pure penalty, and from shift 4 Floor Brick beat it on everything.
	check(Sim.dominated_strains(Sim.baseline(_b), CAREFUL, 4).has("golden"), "M14: Floor Brick beat Golden Kush on all three from shift 4")
	check(not Sim.dominated_strains(_b, CAREFUL, 4).has("golden") and not Sim.dominated_strains(_b, CAREFUL, 3).has("golden"),
			"now nothing does: the counted strain pays for being counted")
	check(float(careful["golden"]["per_tray"]) < float(careful["nightshift"]["per_tray"]) and float(careful["golden"]["roi"]) < float(careful["nightshift"]["roi"])
			and float(careful["golden"]["per_labour"]) < float(careful["brick"]["per_labour"]) and float(careful["golden"]["per_tray"]) < float(careful["brick"]["per_tray"]),
			"without being the best: Night Shift beats it per tray-second and per seed dollar, Floor Brick per worker- and tray-second")
	for id: String in ["nightshift", "brick"]:
		check(not Sim.dominated_strains(_b, CAREFUL, 4).has(id), "%s is not dominated at shift 4 either" % id)
	# The closed form's share of turning plants lost is the shift model's own.
	for skill in Sim.SKILLS.size():
		var turned := 0.0
		var exposure := 0.0
		for crew: Dictionary in _crews[skill]:
			for r: Dictionary in crew["shifts"]:
				turned += float(r["turned"])
				exposure += float(r["exposure"])
		var miss := turned / maxf(exposure, 0.001)
		check(absf(miss - float(Sim.SKILLS[skill]["mutation_miss"])) <= 0.1, "%s: the shift model loses %.0f%% of the plants that turn, the strain table assumes %.0f%%" % [
				Sim.SKILL_NAMES[skill], miss * 100.0, float(Sim.SKILLS[skill]["mutation_miss"]) * 100.0])
	# And in the shift model every strain is some crew's best main strain at some shift.
	var mains: Dictionary = {}
	for skill in _crews.size():
		for crew: Dictionary in _crews[skill]:
			for campaign: Array in crew["campaigns"]:
				for r: Dictionary in campaign:
					mains[r["main"]] = int(mains.get(r["main"], 0)) + 1
	for s: SeedDef in _b.seeds:
		check(int(mains.get(String(s.id), 0)) > 0, "%s is the best main strain in %d of the table's shifts" % [s.display_name, int(mains.get(String(s.id), 0))])


# --- shape ---------------------------------------------------------------------------------------------------------------

func _test_monotonic() -> void:
	for skill in Sim.SKILLS.size():
		var first: Array[float] = []
		var totals: Array[float] = []
		var worst := INF
		for workers in range(1, 5):
			first.append(float(_row(skill, workers, 1)["deposits"]))
			totals.append(_total(_crew(skill, workers)))
			if workers > 1:
				for shift in range(1, 7):
					worst = minf(worst, float(_row(skill, workers, shift)["deposits"]) / maxf(float(_row(skill, workers - 1, shift)["deposits"]), 1.0))
		check(first[0] < first[1] and first[1] < first[2] and first[2] < first[3],
				"%s, shift 1 (a fresh floor): $%.0f < $%.0f < $%.0f < $%.0f for one to four workers" % [Sim.SKILL_NAMES[skill], first[0], first[1], first[2], first[3]])
		check(totals[0] < totals[1] and totals[1] < totals[2] and totals[2] < totals[3],
				"%s, six shifts: $%.0f < $%.0f < $%.0f < $%.0f" % [Sim.SKILL_NAMES[skill], totals[0], totals[1], totals[2], totals[3]])
		check(worst >= 0.85, "%s: in no shift does one more worker deposit under 85%% of the smaller crew (worst %.0f%%)" % [Sim.SKILL_NAMES[skill], worst * 100.0])
	for workers in range(1, 5):
		var c := _total(_crew(CAREFUL, workers))
		var a := _total(_crew(AVERAGE, workers))
		var s := _total(_crew(SLOPPY, workers))
		check(c > a and a > s, "x%d: careful $%.0f > average $%.0f > sloppy $%.0f over six shifts" % [workers, c, a, s])


func _test_cure() -> void:
	# 1. Not for everything: on a fresh floor with the cheap strains, a crew that hangs every bundle deposits less.
	for skill in [CAREFUL, AVERAGE]:
		var none: Dictionary = Sim.run_crew(_b, {"workers": 4, "skill": skill, "cure": Sim.CURE_NONE}, 1)["shifts"][0]
		var every: Dictionary = Sim.run_crew(_b, {"workers": 4, "skill": skill, "cure": Sim.CURE_ALL}, 1)["shifts"][0]
		check(float(every["deposits"]) < float(none["deposits"]) * 0.95 and int(every["cured"]) > 0,
				"shift 1, four %s workers: hanging everything deposits $%.0f, hanging nothing $%.0f" % [Sim.SKILL_NAMES[skill], every["deposits"], none["deposits"]])
		check(is_equal_approx(float(_row(skill, 4, 1)["deposits"]), float(none["deposits"])) or int(_row(skill, 4, 1)["cured"]) == 0,
				"the dear-bundles-only crew hangs none of them there (worth under $%.0f each)" % Sim.CURE_MIN_GAIN)
	# With the M14 cure time the same crew lost next to nothing: hang everything was simply right.
	var short := Sim.with_numbers(_b, {"cure_sec": 20.0})
	var short_none: Dictionary = Sim.run_crew(short, {"workers": 4, "skill": CAREFUL, "cure": Sim.CURE_NONE}, 1)["shifts"][0]
	var short_every: Dictionary = Sim.run_crew(short, {"workers": 4, "skill": CAREFUL, "cure": Sim.CURE_ALL}, 1)["shifts"][0]
	check(float(short_every["deposits"]) > float(short_none["deposits"]) * 0.95,
			"with a 20 s cure it cost them next to nothing ($%.0f against $%.0f)" % [short_every["deposits"], short_none["deposits"]])
	# 2. Worth it for dear strains when there are hands to spare: four workers, shifts 3 to 6.
	var four_none := Sim.run_crew(_b, {"workers": 4, "skill": CAREFUL, "cure": Sim.CURE_NONE})
	var with_cure := _total(_crew(CAREFUL, 4), 3, 6)
	var without := _total(four_none, 3, 6)
	check(with_cure > without * 1.15, "four careful workers, shifts 3 to 6: $%.0f curing the dear bundles, $%.0f curing none (+%.0f%%)" % [
			with_cure, without, (with_cure / without - 1.0) * 100.0])
	# 3. Not for every dear bundle: six hooks, 45 s each.
	var wanted := 0.0
	var refused := 0.0
	for shift in range(3, 7):
		wanted += float(_row(CAREFUL, 4, shift)["cure_wanted"])
		refused += float(_row(CAREFUL, 4, shift)["wet_no_hook"])
	check(refused / maxf(wanted, 1.0) >= 0.15 and refused / maxf(wanted, 1.0) <= 0.6,
			"the six hooks turn away %.0f%% of the bundles they want to hang (%d of %d)" % [refused / maxf(wanted, 1.0) * 100.0, int(refused), int(wanted)])
	var short_four := Sim.run_crew(short, {"workers": 4, "skill": CAREFUL})
	var short_wanted := 0.0
	var short_refused := 0.0
	for r: Dictionary in short_four["shifts"]:
		if int(r["shift"]) >= 3:
			short_wanted += float(r["cure_wanted"])
			short_refused += float(r["wet_no_hook"])
	check(short_refused / maxf(short_wanted, 1.0) < 0.1, "with a 20 s cure they turned away %.0f%%: there was always a hook" % (short_refused / maxf(short_wanted, 1.0) * 100.0))
	# 4. Not for a worker alone: the racks are a walk away and nobody else keeps the trays going.
	var solo_none := Sim.run_crew(_b, {"workers": 1, "skill": CAREFUL, "cure": Sim.CURE_NONE})
	var solo_cure := _total(_crew(CAREFUL, 1))
	var solo_without := _total(solo_none)
	check(solo_cure < solo_without * 1.05, "a careful worker alone gains nothing from the racks ($%.0f with, $%.0f without, six shifts)" % [solo_cure, solo_without])


# --- M18 economy2: the payment for a team, each team through its own run -----------------------------------------------
## CONTRACTS.md "M18", "Economy 2". A run ends at the team's final notice (Sim.final_shift: 4 / 5 / 6 / 6); Sim.run_team
## plays each crew through exactly that run, five times, with the half-time look on the last shift. Nothing here counts
## the strains: a seventh one changes the numbers, not the shape of the checks.

func _run_m18() -> void:
	step("M18: the payment for a team shrinks by the shift")
	_test_team_raise()
	var m17 := Sim.with_numbers(_b, Sim.M17_NUMBERS)
	step("M18: the model, M17 team numbers, each team through its own run (before)")
	var before := Sim.all_teams(m17)
	print(Sim.format_runs(m17, "M17 numbers", {}, before))
	_test_runs_before(before)
	await get_tree().process_frame
	step("M18: the model, shipped numbers, each team through its own run (after)")
	_teams = Sim.all_teams(_b)
	print(Sim.format_runs(_b, "shipped numbers", {}, _teams))
	await get_tree().process_frame
	_variants = {}
	var lines: PackedStringArray = ["   the same runs without favors / without the racks (shipped numbers):"]
	for v: Array in [["no favors", {"favors": false}], ["no racks", {"racks": false}]]:
		for c: Array in [[CAREFUL, 1], [CAREFUL, 2], [CAREFUL, 3], [CAREFUL, 4], [AVERAGE, 3], [AVERAGE, 4]]:
			var opt: Dictionary = (v[1] as Dictionary).duplicate()
			opt["skill"] = c[0]
			opt["workers"] = c[1]
			var team := Sim.run_team(_b, opt)
			_variants[_variant_key(v[0], c[0], c[1])] = team
			var line := "   %-20s" % _variant_key(v[0], c[0], c[1])
			for r: Dictionary in team["shifts"]:
				line += " | %5.0f /%5d %d/%d" % [float(r["deposits"]), int(r["quota"]), int(r["made"]), Sim.JITTERS.size()]
			lines.append(line + " || reached %d, cleared %d" % [int(team["reached"]), int(team["cleared"])])
		await get_tree().process_frame
	print("\n".join(lines))
	step("target: four average workers who split up reach the final notice, and do not clear it without favors and the racks")
	_test_runs_average()
	step("target: three or four careful workers clear the final notice with favors and the racks, not without either")
	_test_runs_careful()
	step("target: nobody clears without cured bundles")
	_test_runs_no_cure()
	step("the middle of the run is tighter for full crews than in M17")
	_test_middle(before, m17)
	step("the final notice's half-time look is in the model")
	_test_look()
	step("gaps: targets the model shows out of reach (printed, not checked)")
	_print_gaps()


func _variant_key(name: String, skill: int, workers: int) -> String:
	return "%s, %s x%d" % [name, Sim.SKILL_NAMES[skill], workers]


func _variant(name: String, skill: int, workers: int) -> Dictionary:
	return _variants.get(_variant_key(name, skill, workers), {"cleared": -1, "reached": -1, "shifts": []})


## The last row of a team's run (its final notice).
func _final_row(team: Dictionary) -> Dictionary:
	var rows: Array = team["shifts"]
	return rows[rows.size() - 1] if not rows.is_empty() else {"deposits": 0.0, "high": 0.0, "quota": 0, "made": 0, "cured": 0}


func _test_team_raise() -> void:
	var m17 := Sim.with_numbers(_b, Sim.M17_NUMBERS)
	var solo_same := true
	var shrinks := true
	var last_same := true
	for n in range(1, 7):
		solo_same = solo_same and _b.quota_for_round(n, 1) == m17.quota_for_round(n, 1)
		for p in range(2, 5):
			if n < 6:
				shrinks = shrinks and Sim.team_factor(_b, n + 1, p) < Sim.team_factor(_b, n, p)
			else:
				last_same = last_same and _b.quota_for_round(n, p) == m17.quota_for_round(n, p)
	check(solo_same, "a worker alone pays what he paid in M17 in every shift (the team fields do not touch one worker)")
	check(shrinks, "for two, three and four workers the team's part of the payment shrinks shift by shift")
	check(absf(Sim.team_factor(_b, 1, 4) - 2.05) < 0.01 and absf(Sim.team_factor(_b, 6, 4) - 1.3) < 0.01,
			"four workers pay x%.2f the solo payment in shift 1, x%.2f in shift 6 (M17: x1.30 in both)" % [
			Sim.team_factor(_b, 1, 4), Sim.team_factor(_b, 6, 4)])
	check(last_same, "shift 6 is the M17 payment for every team: the end of a full crew's run did not move")
	# The raise runs out after shift 7; no run gets that far (the final notice comes first).
	var gone_at := 0
	for n in range(1, 40):
		if _b.quota_for_round(n, 2) <= _b.quota_for_round(n, 1):
			gone_at = n
			break
	var longest := 0
	for p in range(1, 5):
		longest = maxi(longest, Sim.final_shift(_b, p))
	check(gone_at > longest, "the raise for a team is gone at shift %d; the longest run ends at shift %d" % [gone_at, longest])


func _test_runs_before(teams: Array) -> void:
	var a4: Dictionary = teams[AVERAGE][3]["shifts"][2]
	check(float(a4["deposits"]) > 2.4 * float(a4["quota"]),
			"M17: four average workers deposit $%.0f against $%d in shift 3 (the slack this answers)" % [a4["deposits"], a4["quota"]])
	var c2: Dictionary = teams[CAREFUL][1]
	check(int(c2["cleared"]) == Sim.JITTERS.size(), "M17: two careful workers clear their five shifts in every campaign")
	var c4: Dictionary = teams[CAREFUL][3]
	check(int(c4["cleared"]) >= 3, "M17: four careful workers clear the final notice (%d of %d)" % [int(c4["cleared"]), Sim.JITTERS.size()])


func _test_runs_average() -> void:
	var team: Dictionary = _teams[AVERAGE][3]
	var r := _final_row(team)
	check(int(team["final"]) == 6 and int(team["reached"]) >= 3, "four average workers reach the final notice (shift %d) in %d of %d campaigns" % [
			int(team["final"]), int(team["reached"]), Sim.JITTERS.size()])
	for name: String in ["no favors", "no racks"]:
		var v := _variant(name, AVERAGE, 4)
		check(int(v["cleared"]) == 0, "%s, four average workers: no campaign clears (%d reach the final notice)" % [name, int(v["reached"])])
	print("      for the record: with favors and the racks they clear %d of %d ($%.0f against $%d at the final notice); three average workers reach it in %d, clear it in %d" % [
			int(team["cleared"]), Sim.JITTERS.size(), r["deposits"], r["quota"], int(_teams[AVERAGE][2]["reached"]), int(_teams[AVERAGE][2]["cleared"])])


func _test_runs_careful() -> void:
	for workers in [3, 4]:
		var team: Dictionary = _teams[CAREFUL][workers - 1]
		var r := _final_row(team)
		check(int(team["final"]) == 6 and int(team["cleared"]) >= 3, "%d careful workers clear the final notice in %d of %d campaigns ($%.0f against $%d)" % [
				workers, int(team["cleared"]), Sim.JITTERS.size(), r["deposits"], r["quota"]])
		check(int(r["cured"]) > 0, "they cure on the way (%d cured bundles at the final notice over the five)" % int(r["cured"]))
		for name: String in ["no favors", "no racks"]:
			var v := _variant(name, CAREFUL, workers)
			var vr := _final_row(v)
			check(int(v["cleared"]) == 0, "%s, %d careful workers: no campaign clears (at best $%.0f by the buzzer; $%d due before the audit and the look)" % [
					name, workers, vr["high"], vr["quota"]])
	var two: Dictionary = _teams[CAREFUL][1]
	check(int(two["final"]) == 5 and int(two["cleared"]) >= 2, "two careful workers can clear their five shifts (%d of %d; the target is about half: see the gaps)" % [
			int(two["cleared"]), Sim.JITTERS.size()])


func _test_runs_no_cure() -> void:
	for workers in [1, 3, 4]:
		var v := _variant("no racks", CAREFUL, workers)
		check(int(v["cleared"]) == 0, "careful x%d without the racks: no campaign clears its run (%d reach the final notice)" % [workers, int(v["reached"])])
	for workers in [3, 4]:
		var v := _variant("no racks", AVERAGE, workers)
		check(int(v["cleared"]) == 0, "average x%d without the racks: none (%d reach the final notice)" % [workers, int(v["reached"])])
	var sloppy := 0
	for team: Dictionary in _teams[SLOPPY]:
		sloppy += int(team["cleared"])
	check(not bool(Sim.SKILLS[SLOPPY]["racks"]) and sloppy == 0, "sloppy crews (no racks by habit): none, of any size")
	var uncured: PackedStringArray = []
	for skill in _teams.size():
		for wi in (_teams[skill] as Array).size():
			var team: Dictionary = _teams[skill][wi]
			if int(team["cleared"]) == 0:
				continue
			var cured := 0
			for r: Dictionary in team["shifts"]:
				cured += int(r["cured"])
			if cured == 0:
				uncured.append("%s x%d" % [Sim.SKILL_NAMES[skill], wi + 1])
	check(uncured.is_empty(), "every team that clears deposited cured bundles on the way %s" % [uncured])


func _test_middle(before: Array, m17: BalanceConfig) -> void:
	for workers in [3, 4]:
		var higher := true
		for n in range(1, 6):
			higher = higher and _b.quota_for_round(n, workers) > m17.quota_for_round(n, workers)
		check(higher, "%d workers pay more than in M17 in shifts 1 to 5 (shift 3: $%d against $%d)" % [
				workers, _b.quota_for_round(3, workers), m17.quota_for_round(3, workers)])
	var now: Dictionary = _teams[AVERAGE][3]["shifts"][2]
	var then: Dictionary = before[AVERAGE][3]["shifts"][2]
	var ratio_now := float(now["deposits"]) / float(now["quota"])
	var ratio_then := float(then["deposits"]) / float(then["quota"])
	check(ratio_now < ratio_then * 0.8 and int(now["made"]) == Sim.JITTERS.size() and float(now["low"]) > float(now["quota"]) * 1.1,
			"four average workers in shift 3: $%.0f against $%d (x%.2f; M17 $%.0f against $%d, x%.2f), all five make it, the slowest with a tenth to spare" % [
			now["deposits"], now["quota"], ratio_now, then["deposits"], then["quota"], ratio_then])
	var later := true
	var said: PackedStringArray = []
	for c: Array in [[CAREFUL, 4], [AVERAGE, 4], [CAREFUL, 3], [AVERAGE, 3]]:
		var a := float(_teams[c[0]][c[1] - 1]["shifts"][2]["met_at"])
		var b := float(before[c[0]][c[1] - 1]["shifts"][2]["met_at"])
		later = later and a > b
		said.append("%s x%d at %.0f s (M17 %.0f s)" % [Sim.SKILL_NAMES[c[0]], c[1], a, b])
	check(later, "shift 3 is paid later in the shift: %s" % ", ".join(said))


func _test_look() -> void:
	check(is_equal_approx(_b.final_interim_share, 0.4) and is_equal_approx(_b.final_interim_raise, 0.1) and _b.final_shift_by_team == [4, 5, 6, 6]
			and is_equal_approx(Sim.FINAL_LOOK_AT, GameState.FINAL_LOOK_AT),
			"the final notice the model plays: shift 4 / 5 / 6 / 6 by team size; at half time, under 40% deposited, it rises by a tenth")
	var raised := 0
	var lost := 0
	var where: PackedStringArray = []
	for skill in _teams.size():
		for wi in (_teams[skill] as Array).size():
			var team: Dictionary = _teams[skill][wi]
			raised += int(team["raised"])
			lost += int(team["raised_lost"])
			if int(team["raised_lost"]) > 0:
				where.append("%s x%d" % [Sim.SKILL_NAMES[skill], wi + 1])
	check(raised > 0, "the look raised the final notice in %d campaigns of the table; %d of them would have paid it as it was %s" % [raised, lost, where])
	var plain := Sim.run_team(_b, {"workers": 1, "skill": CAREFUL, "final_look": false})
	print("      for the record: a careful solo worker meets shift 4 in %d of %d with the look, %d without it" % [
			int(_final_row(_teams[CAREFUL][0])["made"]), Sim.JITTERS.size(), int(_final_row(plain)["made"])])


func _print_gaps() -> void:
	var solo: Dictionary = _teams[CAREFUL][0]
	var s2: Dictionary = solo["shifts"][1]
	print("   GAP  a careful solo worker clears %d of %d runs (target: about half). The run ends at shift 2: $%.0f against $%d, %d of %d meet it. The solo payment is not moved by the team fields." % [
			int(solo["cleared"]), Sim.JITTERS.size(), s2["deposits"], s2["quota"], int(s2["made"]), Sim.JITTERS.size()])
	var two: Dictionary = _teams[CAREFUL][1]
	var t5: Dictionary = two["shifts"][4]
	var f5: Dictionary = _teams[CAREFUL][3]["shifts"][4]
	var need := float(t5["deposits"]) / float(_b.quota_for_round(5, 1))
	print("   GAP  two careful workers clear %d of %d runs (target: about half), %d of %d without the racks (target: none). About half at shift 5 is about x%.2f the solo payment ($%.0f deposited); the same raise for each worker beyond the first asks four workers x%.2f ($%.0f) where four careful workers deposit $%.0f. A raise linear in the workers beyond the first cannot hold both." % [
			int(two["cleared"]), Sim.JITTERS.size(), int(_variant("no racks", CAREFUL, 2)["cleared"]), Sim.JITTERS.size(), need, t5["deposits"],
			1.0 + 3.0 * (need - 1.0), float(_b.quota_for_round(5, 1)) * (1.0 + 3.0 * (need - 1.0)), f5["deposits"]])
	var avg := _final_row(_teams[AVERAGE][3])
	var dry := _final_row(_variant("no racks", CAREFUL, 4))
	print("   GAP  four average workers clear %d of %d with favors and the racks: at the final notice they deposit $%.0f, four careful workers without the racks $%.0f (at best $%.0f). One payment cannot let the first through and stop the second." % [
			int(_teams[AVERAGE][3]["cleared"]), Sim.JITTERS.size(), avg["deposits"], dry["deposits"], dry["high"]])
# --- end M18 economy2 ---------------------------------------------------------------------------------------------------


# --- report (printed, not checked) --------------------------------------------------------------------------------------

func _report() -> void:
	step("report: one plant of each strain (closed form)")
	print("   M14 numbers")
	print(Sim.format_strains(Sim.baseline(_b), CAREFUL))
	print("   shipped numbers")
	for skill in Sim.SKILLS.size():
		print(Sim.format_strains(_b, skill))
		for shift in range(1, 5):
			print("      dominated at shift %d: %s" % [shift, Sim.dominated_strains(_b, skill, shift)])
	step("report: the event tax, per event (careful, four workers)")
	for e: Dictionary in Sim.event_costs(_b, 4, CAREFUL):
		print("   %-11s weight %.2f  length %4.1f s  every worker %4.1f s  one worker %4.1f s  floor stall %4.1f s  cash $%5.1f  payment +%.0f%%" % [
				e["kind"], e["weight"], e["length"], e["each_sec"], e["one_sec"], e["stall_sec"], e["cash"], float(e["quota_frac"]) * 100.0])
	for c: Array in [[1, CAREFUL, 1], [4, CAREFUL, 6], [4, AVERAGE, 3], [4, SLOPPY, 6]]:
		var tax := Sim.event_tax(_b, c[0], c[1], c[2])
		print("   %s x%d, shift %d: %.2f events, %.1f%% of every worker, %.1f%% of the growth, $%.0f, payment x%.3f" % [
				Sim.SKILL_NAMES[c[1]], c[0], c[2], tax["events"], float(tax["worker_share"]) * 100.0, float(tax["stall_share"]) * 100.0, tax["cash"], tax["quota_factor"]])
	step("report: cure policies, mean deposits per shift (cured / turned away over the five campaigns)")
	for numbers: Array in [["45 s (shipped)", _b], ["20 s (M14 cure time, shipped payment)", Sim.with_numbers(_b, {"cure_sec": 20.0})]]:
		print("   cure %s" % numbers[0])
		for c: Array in [[1, CAREFUL], [2, CAREFUL], [4, CAREFUL], [1, AVERAGE], [2, AVERAGE], [4, AVERAGE]]:
			for policy in 3:
				var line := "      %s x%d %s:" % [Sim.SKILL_NAMES[c[1]], c[0], ["none", "dear", "all "][policy]]
				var total := 0.0
				for r: Dictionary in Sim.run_crew(numbers[1], {"workers": c[0], "skill": c[1], "cure": policy})["shifts"]:
					line += " %6.0f (%3.0f/%3.0f)" % [r["deposits"], r["cured"], r["wet_no_hook"]]
					total += float(r["deposits"])
				print(line + "  sum %.0f" % total)
	step("report: replay off (every strain on sale from shift 1, event gaps do not shrink: the headless suites' game)")
	print(Sim.format_table(_b, "shipped numbers, replay off", {"replay": false}))
	step("report: the market and a contract on top (same factor every shift; the crews re-pick their main strain)")
	var down: Dictionary = {}
	var up: Dictionary = {}
	for s: SeedDef in _b.seeds:
		down[String(s.id)] = 0.75
		up[String(s.id)] = 1.25
	var swing_a := {"budget": 1.0, "purple": 0.75, "creeper": 1.25, "golden": 0.75, "nightshift": 1.25, "brick": 1.0}
	var swing_b := {"budget": 1.0, "purple": 1.25, "creeper": 0.75, "golden": 1.25, "nightshift": 0.75, "brick": 1.0}
	var scenarios: Array = [
		["as shipped", {}], ["every strain -25%", {"market": down}], ["every strain +25%", {"market": up}],
		["purple / golden -25%, creeper / night shift +25%", {"market": swing_a}],
		["purple / golden +25%, creeper / night shift -25%", {"market": swing_b}],
		["a $60 contract met half way through every shift", {"contract_cash": float(_b.contract_reward)}],
		["a $60 contract met 60 s into every shift", {"contract_cash": float(_b.contract_reward), "contract_at": 60.0}],
	]
	for sc: Array in scenarios:
		print("   %s" % sc[0])
		for c: Array in [["careful x1", {"workers": 1, "skill": CAREFUL}], ["average x4", {"workers": 4, "skill": AVERAGE}],
				["careful x4", {"workers": 4, "skill": CAREFUL}], ["careful x4, no racks", {"workers": 4, "skill": CAREFUL, "racks": false}]]:
			var opt: Dictionary = (c[1] as Dictionary).duplicate()
			opt.merge(sc[1], true)
			var crew := Sim.run_crew(_b, opt)
			var line := "      %-20s (%d)" % [c[0], Sim.crew_shifts_made(crew)]
			for r: Dictionary in crew["shifts"]:
				line += " | %6.0f /%5d %d/%d" % [r["deposits"], r["quota"], r["made"], Sim.JITTERS.size()]
			print(line)
