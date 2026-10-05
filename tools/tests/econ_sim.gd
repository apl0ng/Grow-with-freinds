extends RefCounted
## A model of the shift (M15 economy agent, CONTRACTS.md "M15", "Economy"). Plain GDScript: no nodes, no physics, no
## dice. The same inputs always give the same numbers, so tools/tests/economy_body.gd can pin them.
##
##   const Sim := preload("res://tools/tests/econ_sim.gd")
##   Sim.run_shift(Config.balance, {"workers": 2, "skill": Sim.SKILL_AVERAGE, "shift": 3})   one shift
##   Sim.run_campaign(Config.balance, {"workers": 4, "skill": Sim.SKILL_CAREFUL})             shifts 1 to 6, carried over
##   Sim.run_crew(Config.balance, {"workers": 4, "skill": Sim.SKILL_CAREFUL})                 five campaigns, the means
##   Sim.format_table(Sim.baseline(Config.balance), "M14")                                    the printed table
##   Sim.run_team(Config.balance, {"workers": 2, "skill": Sim.SKILL_CAREFUL})   M18: the run that team plays (to its final notice)
##
## WHAT IS MODELLED
##   The floor: ten trays (six in the pen, four in the grow hall), the supply window, the tank, the chute, two racks of
##   three hooks in the hall, two cans. Positions are STATIONS below, copied from scenes/world/room.tscn (the economy
##   suite compares them with the scene); a worker stands ACCESS_* metres in front of a station. Walking distances are
##   straight lines where Room's WALK_BLOCKERS leave the line clear, otherwise the shortest way through Room's own
##   waypoint graph (ROUTE_POINTS / ROUTE_EDGES: the pen gate, the two hall doorways).
##   The numbers: everything in data/balance.tres (cash, strains, stage durations, water, cans, favors, cure time and
##   bonus, speeds, the payment formula), read from the BalanceConfig handed in.
##   The workers: greedy, one item in hand, one job at a time, never two on the same tray ("split up"). Empty hands
##   pick, in order: a plant that may turn, a can when trays are dry, a ready tray, a cured bundle, an empty tray
##   (window -> packet -> tray). A can in hand waters the nearest dry tray, is put down when other work waits and
##   nobody else is free, and is refilled when empty. A bundle goes to a hook when the cure policy says so and a hook
##   is free and the buzzer leaves time, otherwise to the chute.
##   The strain mix: "cheapest affordable ramp-up". The crew wants one main strain; a packet may cost at most the cash
##   on hand divided by the empty trays the crew tends, so the first cash is spread thin over cheap packets and the
##   main strain takes over as deposits come in. run_campaign tries every strain on sale as the main one each shift
##   and keeps the best. Favors (when used) are bought cheapest level first out of cash the trays do not need.
##   Carry-over: cash, favors, what stands in the trays and hangs on the hooks go to the next shift. A shift ends the
##   moment the payment is met (end_round_on_quota_met), so the carried state is the floor at that moment; the
##   deposit number reported is what the crew would have deposited by the buzzer.
##   A crew (run_crew): deposits come in whole bundles and the carried floor moves the next shift, so one campaign
##   is a jumpy number. A crew is played five times with its own timings stretched by 0.94 to 1.06 (JITTERS) and the
##   mean is what the table prints; "n/5" is how many of the five met the payment.
##
## SKILL (SKILLS below; every value is an assumption of this model, not a measurement)
##   careful  sprints most of the way, 0.6 s to line up each stop, waters before a tray runs dry, stands by a plant
##            that may turn, tends six trays a head, uses the hall and the racks
##   average  half walking, a second per stop, notices a dry or ready tray after six seconds, forgets every fourth dry
##            tray for fifteen more, five trays a head, uses the hall and the racks
##   sloppy   walks, two seconds per stop, fifteen seconds to notice, forgets every second dry tray for half a minute,
##            four trays a head, stays in the main room (no hall, no racks)
##   More heads see more: the noticing time is divided by the square root of the crew, the forgetting by the crew.
##
## EVENTS AND MUTATIONS (the tax; event_costs() lists every line)
##   Events: (round_length - event_first_delay) / (mean event length + mean gap) + 0.5 events a shift, the gap
##   shrinking by event_gap_shrink_per_round with replay on. Per event, weighted by the M17 scheduler weights:
##   seconds every worker loses (inspection, head count, drive-by, raid), seconds one worker loses (fuse box, rat,
##   leak, collector, the scale, the phone), seconds the whole floor stops growing (power cut, a dry tank), cash
##   (write-ups, the drive-by bill, the fee of the collector, a bundle lost to a raid, the phone's fine) and the raise
##   an audit puts on the payment (the light scale counts as a raise too: the deposits it shorts). The model
##   spreads the total evenly over the shift: every action takes 1 / (1 - share) as long, growth runs at (1 - share),
##   cash drains at a steady rate, the payment is raised by the expected audit (a shift is "made" against that
##   raised number).
##   Mutations: a ready plant of a strain with a mutation chance that is not harvested within mutation_warning_sec is
##   worth (1 - chance x late_turn_loss) of its bundle; the harvester then loses that share of hostile_sec (fetching
##   the flamethrower, burning it) and the floor that share of cabinet_deposit.
##   Creeper: every third harvest (spread_chance summed up) leaves a watered seedling. Night Shift: grows through
##   the expected power-cut seconds at dark_growth_multiplier. Floor Brick: carried at walk_speed x heavy_speed_factor.
##   Not modelled: the market (neutral on average), shift conditions, contracts, thrown bundles, chute shots, a crew
##   that holds back the last deposit to stock the floor for the next shift.

const DT := 0.25

const SKILL_CAREFUL := 0
const SKILL_AVERAGE := 1
const SKILL_SLOPPY := 2
const SKILL_NAMES: PackedStringArray = ["careful", "average", "sloppy"]
## sprint_share: 0 = walk_speed, 1 = sprint_speed. leg_sec: per walk (stop, turn, aim). press_sec: one E. buy_sec: the
## supply window (open, find the card, buy, close). think_sec: per job. notice_sec: until a dry or ready tray is seen.
## water_at: the water level a tray is topped up at. forget_every / forget_sec: every n-th dry tray waits that much
## longer. tend: trays a worker looks after. anticipate_sec: how early a worker walks to a plant that may turn.
## turn_react_sec: until a twitching plant is somebody's job. late_turn_loss: share of the turning plants that are
## lost when the model's worker is late (a real one drops what he holds and runs; the model's never does).
## hostile_sec: one worker's time per hostile plant. fixes: resets the fuse box, patches the leak, pays the collector.
## write_up_chance / headcount_miss: per worker per inspection / head count. raid_loss: chance a raid takes a bundle.
## mutation_miss: share of turning plants lost, as the shift model measures it over the whole table (0.08 / 0.58 /
## 1.00); only the closed-form strain_metrics reads it.
const SKILLS: Array[Dictionary] = [
	{"sprint_share": 0.8, "leg_sec": 0.6, "press_sec": 0.4, "buy_sec": 3.0, "think_sec": 0.4, "notice_sec": 2.5,
		"water_at": 0.2, "forget_every": 0, "forget_sec": 0.0, "tend": 6, "hall": true, "racks": true,
		"anticipate_sec": 4.0, "turn_react_sec": 1.0, "late_turn_loss": 1.0, "hostile_sec": 15.0, "fixes": true,
		"write_up_chance": 0.05, "headcount_miss": 0.0, "raid_loss": 0.0, "mutation_miss": 0.1},
	{"sprint_share": 0.4, "leg_sec": 1.0, "press_sec": 0.7, "buy_sec": 4.0, "think_sec": 0.8, "notice_sec": 6.0,
		"water_at": 0.1, "forget_every": 4, "forget_sec": 15.0, "tend": 5, "hall": true, "racks": true,
		"anticipate_sec": 0.0, "turn_react_sec": 2.0, "late_turn_loss": 0.65, "hostile_sec": 25.0, "fixes": true,
		"write_up_chance": 0.2, "headcount_miss": 0.1, "raid_loss": 0.3, "mutation_miss": 0.6},
	{"sprint_share": 0.0, "leg_sec": 2.0, "press_sec": 1.2, "buy_sec": 7.0, "think_sec": 1.5, "notice_sec": 15.0,
		"water_at": 0.05, "forget_every": 2, "forget_sec": 30.0, "tend": 4, "hall": false, "racks": false,
		"anticipate_sec": 0.0, "turn_react_sec": 6.0, "late_turn_loss": 1.0, "hostile_sec": 40.0, "fixes": false,
		"write_up_chance": 0.5, "headcount_miss": 0.3, "raid_loss": 0.7, "mutation_miss": 1.0},
]

const CURE_NONE := 0
## Only bundles whose cure is worth at least CURE_MIN_GAIN.
const CURE_DEAR := 1
const CURE_ALL := 2
## What the detour to a rack has to bring in before a worker bothers: about nine seconds of a careful solo worker
## (hang, come back, carry it to the chute) at about five dollars a second.
const CURE_MIN_GAIN := 45.0
## A bundle is only hung when it can be cured, fetched and deposited this many seconds before the buzzer.
const CURE_SLACK_SEC := 5.0
## One worker with a can keeps up with this many dry trays; more than that and a second can is fetched.
const NEEDS_PER_CAN := 3
const IDLE_SEC := 0.5
## Favors are bought when the cash covers a packet of the main strain for every tray that needs one, and this many more.
const FAVOR_SPARE_PACKETS := 2

# --- the floor (Room-local x, z) ---------------------------------------------------------------------------------------
const ACCESS_STATION := 1.3
const ACCESS_TRAY := 1.2
const TRAY_COUNT := 10
const PEN_TRAYS := 6
const RACK_COUNT := 2
const HOOKS_PER_RACK := 3
## name -> [position, front]. From scenes/world/room.tscn (Stations/<name>: origin and local +Z).
const STATIONS: Dictionary = {
	"ShopCounter": [Vector2(0.0, -5.0), Vector2(0.0, 1.0)],
	"Well": [Vector2(-6.8, 0.0), Vector2(1.0, 0.0)],
	"TurnInStation": [Vector2(0.0, 5.8), Vector2(0.0, -1.0)],
	"GrowPlot1": [Vector2(5.0, -3.0), Vector2(-1.0, 0.0)],
	"GrowPlot2": [Vector2(7.6, -3.0), Vector2(-1.0, 0.0)],
	"GrowPlot3": [Vector2(5.0, 0.0), Vector2(-1.0, 0.0)],
	"GrowPlot4": [Vector2(7.6, 0.0), Vector2(-1.0, 0.0)],
	"GrowPlot5": [Vector2(5.0, 3.0), Vector2(-1.0, 0.0)],
	"GrowPlot6": [Vector2(7.6, 3.0), Vector2(-1.0, 0.0)],
	"GrowPlot7": [Vector2(16.0, -1.5), Vector2(-1.0, 0.0)],
	"GrowPlot8": [Vector2(18.6, -1.5), Vector2(-1.0, 0.0)],
	"GrowPlot9": [Vector2(16.0, 1.5), Vector2(-1.0, 0.0)],
	"GrowPlot10": [Vector2(18.6, 1.5), Vector2(-1.0, 0.0)],
	"DryingRack1": [Vector2(14.0, -6.6), Vector2(0.0, 1.0)],
	"DryingRack2": [Vector2(16.5, -6.6), Vector2(0.0, 1.0)],
}
## Where the fuse box hangs (wall station, front +X), where the Boss counts heads (Decor/HeadcountSpot), where the
## van drops the crew (Arrivals/Arrival0) and the dock side of the passage (the collector's corner).
const FUSE_BOX := Vector2(-9.98, -4.0)
const HEADCOUNT_SPOT := Vector2(0.0, -3.2)
const ARRIVAL := Vector2(-1.3, 9.4)
const DOCK := Vector2(-5.0, 9.4)

const P_SHOP := 0
const P_WELL := 1
const P_CHUTE := 2
const P_TRAY0 := 3
const P_RACK0 := 13
const P_START := 15
const P_FUSE := 16
const P_LINE := 17
const P_DOCK := 18
const POINT_COUNT := 19

# --- events (weights: CONTRACTS.md "M17", "Mayhem 3", fourteen kinds, sum 100) --------------------------------------
const EVENT_WEIGHTS: Dictionary = {
	"inspection": 20, "power_cut": 12, "audit": 7, "rat": 6, "headcount": 9, "water_off": 6, "shortage": 5,
	"leak": 7, "driveby": 7, "raid": 6, "sprinklers": 5, "collection": 5, "scale": 3, "phone": 2,
}
## Seconds a worker loses keeping out of the Boss's sight and on the move during an inspection.
const INSPECTION_DODGE_SEC := 3.0
## Seconds a worker stands on the line before the count ends.
const HEADCOUNT_WAIT_SEC := 3.0
## Events.RAT_EAT_PER_SEC, Events.AUDIT_BANNER_SEC.
const RAT_EAT_PER_SEC := 0.06
const AUDIT_SEC := 3.0
## Share of the floor's growth that stops while the tank is off (the cans in hand still hold water) / empty after an
## unpatched leak; share of the trays a drive-by lane crosses.
const WATER_OFF_STALL_SHARE := 0.1
const LEAK_STALL_SHARE := 0.3
const DRIVEBY_TRAY_SHARE := 0.2
## Seconds a worker spends getting a bundle out of sight before a raid; what a lost bundle is worth.
const RAID_STASH_SEC := 4.0
const LOST_BUNDLE_VALUE := 150.0
## Share of a worker's time that is walking (the sprinklers take the sprint away); seconds a watering takes
## (the sprinklers water every tray for free).
const WALK_SHARE := 0.5
const WATERING_SEC := 2.0

## Every number the M15 retune changed, as it was in M14: format_table(baseline(cfg), ...) prints the "before" table.
## (cure_bonus was looked at and left alone; it is listed so a later change of it shows up against the baseline.)
const M14_NUMBERS: Dictionary = {
	"base_quota": 350, "quota_scale": 1.5, "quota_add": 150, "quota_per_extra_player": 0.2,
	"quota_team_by_shift": [], "quota_team_by_size": [],  # M18 economy2: M14 had a flat raise
	"cure_sec": 20.0, "cure_bonus": 0.4,
	"seeds": {"purple": {"sale_value_per_unit": 130}, "golden": {"sale_value_per_unit": 120}},
}

const HOLD_NONE := 0
const HOLD_CAN := 1
const HOLD_PACKET := 2
const HOLD_BUNDLE := 3

const A_NONE := 0
const A_HARVEST := 1
const A_DEPOSIT := 2
const A_HANG := 3
const A_TAKE := 4
const A_BUY := 5
const A_PLANT := 6
const A_PICK_CAN := 7
const A_WATER := 8
const A_REFILL := 9
const A_DROP_CAN := 10

const CAT_WATER := 0
const CAT_WORK := 1

static var _points: Array[Vector2] = []
static var _dist: PackedFloat32Array = PackedFloat32Array()


# --- geometry ----------------------------------------------------------------------------------------------------------

## Where a worker stands to use `station` (a STATIONS key).
static func access_point(station: String) -> Vector2:
	var entry: Array = STATIONS[station]
	var reach := ACCESS_TRAY if station.begins_with("GrowPlot") else ACCESS_STATION
	return (entry[0] as Vector2) + (entry[1] as Vector2) * reach


## The model's named points (P_*), Room-local (x, z).
static func points() -> Array[Vector2]:
	if _points.is_empty():
		var out: Array[Vector2] = [access_point("ShopCounter"), access_point("Well"), access_point("TurnInStation")]
		for i in TRAY_COUNT:
			out.append(access_point("GrowPlot%d" % (i + 1)))
		for i in RACK_COUNT:
			out.append(access_point("DryingRack%d" % (i + 1)))
		out.append(ARRIVAL)
		out.append(FUSE_BOX + Vector2(ACCESS_STATION, 0.0))
		out.append(HEADCOUNT_SPOT)
		out.append(DOCK)
		_points = out
	return _points


## Metres on foot between two named points (P_*).
static func distance(a: int, b: int) -> float:
	if _dist.is_empty():
		var pts := points()
		_dist.resize(POINT_COUNT * POINT_COUNT)
		for i in POINT_COUNT:
			for j in POINT_COUNT:
				_dist[i * POINT_COUNT + j] = 0.0 if i == j else walk_distance(pts[i], pts[j])
	return _dist[a * POINT_COUNT + b]


static func _in_areas(p: Vector2) -> bool:
	var half := Room.INTERIOR_SIZE * 0.5
	if absf(p.x) <= half.x and absf(p.y) <= half.z:
		return true
	for area: AABB in [Room.HALL_AREA, Room.DOCK_AREA]:
		if p.x >= area.position.x and p.x <= area.end.x and p.y >= area.position.z and p.y <= area.end.z:
			return true
	return false


## Room._walk_clear without a Room: nothing in WALK_BLOCKERS on the segment and every point of it in a play area.
static func walk_clear(a: Vector2, b: Vector2) -> bool:
	for r: Rect2 in Room.WALK_BLOCKERS:
		var grown := r.grow(Room.ROUTE_MARGIN)
		if grown.has_point(a) or grown.has_point(b):
			grown = r
		if Room._segment_hits_rect(a, b, grown):
			return false
	var steps := int(ceil(a.distance_to(b) / 0.25))
	for i in range(0, steps + 1):
		if not _in_areas(a.lerp(b, float(i) / float(maxi(steps, 1)))):
			return false
	return true


## Metres on foot from `a` to `b`: the straight line when it is clear, else the shortest way over Room's waypoints.
static func walk_distance(a: Vector2, b: Vector2) -> float:
	if walk_clear(a, b):
		return a.distance_to(b)
	var pts: Array[Vector2] = []
	pts.assign(Room.ROUTE_POINTS)
	var n := pts.size()
	pts.append(a)
	pts.append(b)
	var links: Array = []
	for i in n + 2:
		links.append([])
	for e: Vector2i in Room.ROUTE_EDGES:
		(links[e.x] as Array).append(e.y)
		(links[e.y] as Array).append(e.x)
	for i in n:
		if walk_clear(a, pts[i]):
			(links[n] as Array).append(i)
		if walk_clear(pts[i], b):
			(links[i] as Array).append(n + 1)
	var best: Array[float] = []
	var done: Array[bool] = []
	best.resize(n + 2)
	done.resize(n + 2)
	best.fill(INF)
	done.fill(false)
	best[n] = 0.0
	for _step in n + 2:
		var u := -1
		var low := INF
		for i in n + 2:
			if not done[i] and best[i] < low:
				low = best[i]
				u = i
		if u < 0 or u == n + 1:
			break
		done[u] = true
		for v: int in links[u]:
			var d := low + pts[u].distance_to(pts[v])
			if d < best[v]:
				best[v] = d
	return best[n + 1] if is_finite(best[n + 1]) else a.distance_to(b) * 1.5


# --- numbers -----------------------------------------------------------------------------------------------------------

## A copy of `cfg` (seeds and favors copied too) that can be changed without touching the live resource.
static func copy_config(cfg: BalanceConfig) -> BalanceConfig:
	var out := cfg.duplicate() as BalanceConfig
	var seeds: Array[SeedDef] = []
	for s: SeedDef in cfg.seeds:
		seeds.append(s.duplicate() as SeedDef)
	out.seeds = seeds
	var ups: Array[UpgradeDef] = []
	for u: UpgradeDef in cfg.upgrades:
		ups.append(u.duplicate() as UpgradeDef)
	out.upgrades = ups
	return out


## `cfg` with `numbers` applied: BalanceConfig properties, plus "seeds": {id: {property: value}}.
static func with_numbers(cfg: BalanceConfig, numbers: Dictionary) -> BalanceConfig:
	var out := copy_config(cfg)
	for key: String in numbers:
		if key == "seeds":
			var per_seed: Dictionary = numbers[key]
			for id: String in per_seed:
				var s := out.get_seed(StringName(id))
				if s != null:
					var fields: Dictionary = per_seed[id]
					for f: String in fields:
						s.set(f, fields[f])
		elif out.get(key) is Array:  # M18 economy2: a typed array field (the team tables) takes the values, typed
			var arr := (out.get(key) as Array).duplicate()
			arr.assign(numbers[key])
			out.set(key, arr)
		else:
			out.set(key, numbers[key])
	return out


## The live numbers with everything this retune touched put back to M14.
static func baseline(cfg: BalanceConfig) -> BalanceConfig:
	return with_numbers(cfg, M14_NUMBERS)


static func worker_speed(cfg: BalanceConfig, skill: int) -> float:
	return lerpf(cfg.walk_speed, cfg.sprint_speed, float(SKILLS[skill]["sprint_share"]))


static func base_grow_sec(cfg: BalanceConfig) -> float:
	var total := 0.0
	for d: float in cfg.stage_durations:
		total += d
	return total


## The quota formula's values: [shift 1..shifts][1..4 workers].
static func quota_table(cfg: BalanceConfig, shifts: int = 6) -> Array:
	var out: Array = []
	for n in range(1, shifts + 1):
		var row: Array[int] = []
		for p in range(1, 5):
			row.append(cfg.quota_for_round(n, p))
		out.append(row)
	return out


# --- the tax -------------------------------------------------------------------------------------------------------------

## One line per event kind: {kind, weight (0..1), length (s on the scheduler), each_sec (every worker), one_sec (one
## worker), stall_sec (the whole floor's growth), dark_sec (of that: power off), cash, quota_frac}.
static func event_costs(cfg: BalanceConfig, workers: int, skill: int) -> Array[Dictionary]:
	var sk: Dictionary = SKILLS[skill]
	var speed := worker_speed(cfg, skill)
	var leg: float = sk["leg_sec"]
	var react: float = float(sk["notice_sec"]) + float(sk["think_sec"])
	var fixes: bool = sk["fixes"]
	var from := P_TRAY0 + 2 # a worker is somewhere in the pen
	var mean_stage := base_grow_sec(cfg) / maxf(float(cfg.stage_durations.size()), 1.0)
	var out: Array[Dictionary] = []
	var add := func(kind: String, length: float, each_sec: float, one_sec: float, stall_sec: float, dark_sec: float,
			cash: float, quota_frac: float) -> void:
		out.append({"kind": kind, "weight": float(EVENT_WEIGHTS[kind]) / 100.0, "length": length, "each_sec": each_sec,
				"one_sec": one_sec, "stall_sec": stall_sec, "dark_sec": dark_sec, "cash": cash, "quota_frac": quota_frac})
	# Inspection: keep moving; a write-up now and then.
	add.call("inspection", cfg.inspection_sec, INSPECTION_DODGE_SEC, 0.0, 0.0, 0.0,
			float(workers) * float(sk["write_up_chance"]) * float(cfg.write_up_fine), 0.0)
	# Power cut: nothing grows until someone holds the fuse box (or it comes back by itself).
	var fuse_trip := distance(from, P_FUSE) / speed + leg
	var cut := cfg.power_cut_max_sec
	var cut_work := 0.0
	if fixes:
		cut = minf(react + fuse_trip + cfg.fuse_reset_sec, cfg.power_cut_max_sec)
		cut_work = 2.0 * fuse_trip + cfg.fuse_reset_sec
	add.call("power_cut", cut, 0.0, cut_work, cut, cut, 0.0, 0.0)
	add.call("audit", AUDIT_SEC, 0.0, 0.0, 0.0, 0.0, 0.0, cfg.audit_raise_fraction)
	# Rat: eats one tray's stage progress until a worker walks up.
	var rat := minf(react + distance(from, P_TRAY0 + 5) / speed + leg, 30.0)
	add.call("rat", rat, 0.0, rat - float(sk["notice_sec"]), RAT_EAT_PER_SEC * rat * mean_stage / float(TRAY_COUNT), 0.0, 0.0, 0.0)
	# Head count: to the line and back, a moment standing there; a write-up for whoever is not there.
	add.call("headcount", cfg.headcount_sec, 2.0 * (distance(from, P_LINE) / speed + leg) + HEADCOUNT_WAIT_SEC, 0.0, 0.0, 0.0,
			float(workers) * float(sk["headcount_miss"]) * float(cfg.write_up_fine), 0.0)
	add.call("water_off", cfg.water_off_sec, 0.0, 0.0, WATER_OFF_STALL_SHARE * cfg.water_off_sec, 0.0, 0.0, 0.0)
	add.call("shortage", cfg.shortage_sec, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
	# Leak: patched by one worker, or the tank is empty for a minute.
	var tank_trip := distance(from, P_WELL) / speed + leg
	if fixes:
		add.call("leak", minf(react + tank_trip + cfg.leak_patch_sec, cfg.leak_sec), 0.0, 2.0 * tank_trip + cfg.leak_patch_sec, 0.0, 0.0, 0.0, 0.0)
	else:
		add.call("leak", cfg.leak_sec, 0.0, 0.0, LEAK_STALL_SHARE * cfg.leak_empty_sec, 0.0, 0.0, 0.0)
	# Drive-by: everyone is down for the length of it, the trays in the lane lose stage progress, the Boss bills the glass.
	var driveby := cfg.driveby_warning_sec + cfg.driveby_sec
	add.call("driveby", driveby, driveby, 0.0, DRIVEBY_TRAY_SHARE * cfg.driveby_tray_loss * mean_stage, 0.0, float(cfg.driveby_fine), 0.0)
	add.call("raid", cfg.raid_warning_sec + cfg.raid_sec, RAID_STASH_SEC, 0.0, 0.0, 0.0, float(sk["raid_loss"]) * LOST_BUNDLE_VALUE, 0.0)
	# Sprinklers: no sprinting on a wet floor, but every tray is watered for nothing.
	var wet := cfg.sprinkler_sec + cfg.sprinkler_wet_sec
	var slowed := wet * WALK_SHARE * (1.0 - cfg.walk_speed / speed)
	var saved := float(TRAY_COUNT) * WATERING_SEC / float(maxi(workers, 1))
	add.call("sprinklers", cfg.sprinkler_sec, maxf(slowed - saved, 0.0), 0.0, 0.0, 0.0, 0.0, 0.0)
	# The collector: paid at the dock, or he takes the dearest bundle.
	if fixes:
		var dock_trip := distance(from, P_DOCK) / speed + leg
		add.call("collection", minf(react + dock_trip + cfg.collector_hold_sec, cfg.collector_sec), 0.0,
				2.0 * dock_trip + cfg.collector_hold_sec, 0.0, 0.0, float(cfg.collector_fee), 0.0)
	else:
		add.call("collection", cfg.collector_sec, 0.0, 0.0, 0.0, 0.0, LOST_BUNDLE_VALUE, 0.0)
	# M17 mayhem3. The scale: what is deposited before somebody hits the chute pays scale_cut less, the same as a
	# payment that much higher for that share of the shift. A crew that fixes things notices it and walks over (the
	# chute is on its way anyway); one that does not lets it run out.
	var scale_open := cfg.scale_sec
	var scale_work := 0.0
	if fixes:
		var chute_trip := distance(from, P_CHUTE) / speed + leg
		scale_open = minf(react + chute_trip, cfg.scale_sec)
		scale_work = chute_trip
	add.call("scale", scale_open, 0.0, scale_work, 0.0, 0.0, 0.0, cfg.scale_cut * scale_open / maxf(cfg.round_length_sec, 1.0))
	# The phone: one worker's walk to it and the hold, or nobody answers and the floor pays phone_fine. The phone hangs
	# in the fuse box's corner of the main room (4 m from it), so the walk is the fuse box's. What an answered call
	# brings (a tip, a minute of cheap seeds) is not counted: the line errs on the dear side.
	if fixes:
		var phone_trip := distance(from, P_FUSE) / speed + leg
		add.call("phone", minf(react + phone_trip + cfg.phone_hold_sec, cfg.phone_sec), 0.0,
				2.0 * phone_trip + cfg.phone_hold_sec, 0.0, 0.0, 0.0, 0.0)
	else:
		add.call("phone", cfg.phone_sec, 0.0, 0.0, 0.0, 0.0, float(cfg.phone_fine), 0.0)
	return out


## The expected cost of a shift's events: {events, worker_share (of every worker's time), stall_share (of the floor's
## growth), dark_share (of the shift with the power off), cash, quota_factor, per_event: {...}}.
static func event_tax(cfg: BalanceConfig, workers: int, skill: int, shift: int, replay: bool = true) -> Dictionary:
	var each := 0.0
	var one := 0.0
	var stall := 0.0
	var dark := 0.0
	var cash := 0.0
	var quota_frac := 0.0
	var length := 0.0
	for e: Dictionary in event_costs(cfg, workers, skill):
		var w: float = e["weight"]
		each += w * float(e["each_sec"])
		one += w * float(e["one_sec"])
		stall += w * float(e["stall_sec"])
		dark += w * float(e["dark_sec"])
		cash += w * float(e["cash"])
		quota_frac += w * float(e["quota_frac"])
		length += w * float(e["length"])
	var gap := (cfg.event_gap_min_sec + cfg.event_gap_max_sec) * 0.5
	if replay:
		gap *= maxf(1.0 - cfg.event_gap_shrink_per_round * float(maxi(shift, 1) - 1), 0.5)
	var shift_sec := cfg.round_length_sec
	var events := 0.0
	if cfg.events_enabled and shift_sec > cfg.event_first_delay_sec:
		events = (shift_sec - cfg.event_first_delay_sec) / maxf(length + gap, 1.0) + 0.5
	return {
		"events": events,
		"worker_share": minf(events * (each + one / float(maxi(workers, 1))) / shift_sec, 0.5),
		"stall_share": minf(events * stall / shift_sec, 0.5),
		"dark_share": events * dark / shift_sec,
		"cash": events * cash,
		"quota_factor": 1.0 + events * quota_frac,
		"per_event": {"each_sec": each, "one_sec": one, "stall_sec": stall, "cash": cash, "length": length, "gap": gap},
	}


# --- one shift -----------------------------------------------------------------------------------------------------------

## Seed indices on sale in `shift` (every strain with replay off).
static func strains_on_sale(cfg: BalanceConfig, shift: int, replay: bool) -> Array[int]:
	var out: Array[int] = []
	for i in cfg.seeds.size():
		if not replay or cfg.seeds[i].unlock_round <= shift:
			out.append(i)
	return out


## Simulates one shift. `opt`: workers (1..4), skill (SKILL_*), shift (1..), replay (unlocks by shift and shrinking
## event gaps; default true), events (the tax; default true), favors (default true), cure (CURE_*; default CURE_DEAR
## when the skill uses the racks), hall / racks (default: the skill's), main (strain id; default: the best per
## tray-second on sale), jitter (factor on the worker's own timings; default 1), and the what-ifs market
## ({strain id: factor}), contract_cash / contract_at. `carry`: the "carry" of the previous shift's result, null for a
## fresh floor with starting_money.
## Returns {shift, workers, skill, quota, quota_taxed (with the expected audit), deposits (by the buzzer), met_at (s,
## -1 = missed), made, main, by_strain {id: {bundles, cash}}, cured, wet_no_hook (a cure was wanted, every hook was
## taken), cure_wanted, turned (expected plants lost to a mutation), mutable, exposure (plants expected to turn),
## time {walk, water, handle, idle, events} (worker-seconds), trays {empty, growing, dry, ready} (tray-seconds),
## bottleneck ("water trips" / "walking" / "handling" when the workers are busy; "trays" / "hooks" / "cash" when a
## quarter of their time is idle), favors {id: level}, cash, timeline (PackedVector2Array of (second, deposits so
## far)), carry}.
static func run_shift(cfg: BalanceConfig, opt: Dictionary, carry: Variant = null) -> Dictionary:
	var workers := clampi(int(opt.get("workers", 1)), 1, 4)
	var skill := clampi(int(opt.get("skill", SKILL_AVERAGE)), 0, SKILLS.size() - 1)
	var shift := maxi(int(opt.get("shift", 1)), 1)
	var replay := bool(opt.get("replay", true))
	distance(0, 0)
	# What the inner class cannot reach by itself (an inner class does not see the outer script's static functions).
	var ctx := {
		"workers": workers, "skill": skill, "shift": shift,
		"speed": worker_speed(cfg, skill),
		"tax": event_tax(cfg, workers, skill, shift, replay) if bool(opt.get("events", true)) else {},
		"allowed": strains_on_sale(cfg, shift, replay),
		"base_grow": base_grow_sec(cfg),
		"dist": _dist,
	}
	var run := Run.new()
	run.setup(cfg, opt, carry, ctx)
	return run.play()


## Shifts 1..`shifts` in a row with the state carried over, trying every strain on sale as the main one each shift
## and keeping the one that deposits most. `alive` in each result: every earlier shift was made.
static func run_campaign(cfg: BalanceConfig, opt: Dictionary, shifts: int = 6) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var carry: Variant = null
	var alive := true
	var replay := bool(opt.get("replay", true))
	for shift in range(1, shifts + 1):
		var best: Dictionary = {}
		for seed_index: int in strains_on_sale(cfg, shift, replay):
			var o := opt.duplicate()
			o["shift"] = shift
			o["main"] = cfg.seeds[seed_index].id
			o["final"] = shift == int(opt.get("final_shift", 0)) and bool(opt.get("final_look", true))  # M18 economy2
			var r := run_shift(cfg, o, carry)
			if best.is_empty() or float(r["deposits"]) > float(best["deposits"]):
				best = r
		best["alive"] = alive
		alive = alive and bool(best["made"])
		carry = best["carry"]
		out.append(best)
	return out


## The last shift a campaign paid in a row (0 = not even the first).
static func shifts_made(campaign: Array[Dictionary]) -> int:
	var n := 0
	for r: Dictionary in campaign:
		if not bool(r["made"]):
			break
		n += 1
	return n


class Run:
	extends RefCounted

	var cfg: BalanceConfig
	var sk: Dictionary
	var skill: int
	var workers: int
	var shift: int
	var length: float
	var quota_plain: int
	var quota: float
	var cure_policy: int
	var use_favors: bool
	var use_racks: bool
	var tray_limit: int
	var allowed: Array[int] = []
	var rank: Array[int] = []
	var main: int = 0
	var min_cost: float = 0.0
	var speed: float
	var heavy_speed: float
	var slow: float = 1.0
	var growth_floor: float = 1.0
	var dark_share: float = 0.0
	var cash_drain: float = 0.0
	var leg: float
	var press: float
	var buy_sec: float
	var think: float
	var notice: float
	var water_at: float
	var dry: float
	# per strain
	var grow_sec: Array[float] = []
	var drain: Array[float] = []
	var rates: Array[float] = []
	var cost: Array[float] = []
	var gross: Array[float] = []
	var mutation: Array[float] = []
	var spread: Array[float] = []
	var heavy: Array[bool] = []
	var dist: PackedFloat32Array
	# favors (live)
	var up: Array[int] = []
	var growth_mult: float = 1.0
	var sale_mult: float = 1.0
	var can_capacity: int = 4
	# state
	var clock: float = 0.0
	var t: float = 0.0
	var cash: float = 0.0
	var reserved: float = 0.0
	var sales: float = 0.0
	var spread_acc: float = 0.0
	var need_count: int = 0
	var tr_strain: Array[int] = []
	var tr_water: Array[float] = []
	var tr_grown: Array[float] = []
	var tr_ready: Array[bool] = []
	var tr_ready_at: Array[float] = []
	var tr_need: Array[float] = []
	var tr_need_delay: Array[float] = []
	var tr_res: Array[int] = []
	var can_charges: Array[int] = []
	var can_at: Array[int] = []
	var can_holder: Array[int] = []
	var can_res: Array[int] = []
	var hk_strain: Array[int] = []
	var hk_left: Array[float] = []
	var hk_factor: Array[float] = []
	var hk_res: Array[int] = []
	var w_at: Array[int] = []
	var w_busy: Array[float] = []
	var w_hold: Array[int] = []
	var w_item: Array[int] = []
	var w_cured: Array[bool] = []
	var w_factor: Array[float] = []
	var w_act: Array[int] = []
	var w_arg: Array[int] = []
	var w_idle: Array[bool] = []
	# results
	var met_at: float = -1.0
	var carry_state: Dictionary = {}
	var by_strain: Dictionary = {}
	var cured_count: int = 0
	var wet_no_hook: int = 0
	var cure_wanted: int = 0
	var turned: float = 0.0
	var mutable: int = 0
	var exposure: float = 0.0
	var time_walk: float = 0.0
	var time_water: float = 0.0
	var time_handle: float = 0.0
	var time_idle: float = 0.0
	var time_events: float = 0.0
	var tray_empty: float = 0.0
	var tray_growing: float = 0.0
	var tray_dry: float = 0.0
	var tray_ready: float = 0.0
	var cash_short: float = 0.0
	var timeline: PackedVector2Array = PackedVector2Array()
	var contract_cash: float = 0.0
	var contract_at: float = 0.0
	# --- M18 economy2: the final notice's half-time look (see run_team) ---
	var final_look: bool = false
	var final_looked: bool = false
	var final_raised: bool = false
	# --- end M18 economy2 ---

	func setup(config: BalanceConfig, opt: Dictionary, carry: Variant, ctx: Dictionary) -> void:
		cfg = config
		workers = ctx["workers"]
		skill = ctx["skill"]
		sk = SKILLS[skill]
		shift = ctx["shift"]
		length = cfg.round_length_sec
		quota_plain = cfg.quota_for_round(shift, workers)
		if opt.has("team_factor"): quota_plain = roundi(float(cfg.quota_for_round(shift, 1)) * float((opt["team_factor"] as Callable).call(shift, workers)))  # M18 economy2 what-if
		quota = float(quota_plain)
		use_favors = bool(opt.get("favors", true))
		use_racks = bool(opt.get("racks", sk["racks"]))
		cure_policy = int(opt.get("cure", CURE_DEAR)) if use_racks else CURE_NONE
		var hall := bool(opt.get("hall", sk["hall"]))
		tray_limit = mini(TRAY_COUNT if hall else PEN_TRAYS, workers * int(sk["tend"]))
		speed = ctx["speed"]
		heavy_speed = minf(cfg.walk_speed * cfg.heavy_speed_factor, speed)
		# "jitter" stretches the worker's own timings (run_crew plays the same crew a little faster and a little slower).
		var jitter := maxf(float(opt.get("jitter", 1.0)), 0.1)
		leg = float(sk["leg_sec"]) * jitter
		press = float(sk["press_sec"]) * jitter
		buy_sec = float(sk["buy_sec"]) * jitter
		think = float(sk["think_sec"]) * jitter
		# More eyes see a dry tray sooner.
		notice = float(sk["notice_sec"]) * jitter / sqrt(float(workers))
		dry = cfg.dry_threshold
		water_at = maxf(float(sk["water_at"]), dry)
		var tax: Dictionary = ctx["tax"]
		if not tax.is_empty():
			slow = 1.0 / (1.0 - float(tax["worker_share"]))
			growth_floor = 1.0 - float(tax["stall_share"])
			dark_share = tax["dark_share"]
			cash_drain = float(tax["cash"]) / length
			quota *= float(tax["quota_factor"])
		dist = ctx["dist"]
		allowed.assign(ctx["allowed"])
		var base: float = ctx["base_grow"]
		min_cost = INF
		for s: SeedDef in cfg.seeds:
			grow_sec.append(base * s.grow_time_multiplier)
			drain.append(cfg.water_drain_per_sec * maxf(s.thirst_multiplier, 0.0))
			cost.append(float(s.cost))
			gross.append(float(s.yield_amount * s.sale_value_per_unit))
			mutation.append(clampf(s.mutation_chance, 0.0, 1.0))
			spread.append(clampf(s.spread_chance, 0.0, 1.0))
			heavy.append(s.heavy)
			rates.append(1.0)
		for i: int in allowed:
			min_cost = minf(min_cost, cost[i])
		# What-ifs for the report: "market" {strain id: factor on its deposit value}, "contract_cash" paid into cash on
		# hand (not deposits) at "contract_at" seconds (default: half way through the shift).
		var market: Dictionary = opt.get("market", {})
		for i in cfg.seeds.size():
			gross[i] *= float(market.get(String(cfg.seeds[i].id), 1.0))
		contract_cash = float(opt.get("contract_cash", 0.0))
		contract_at = float(opt.get("contract_at", length * 0.5))
		final_look = bool(opt.get("final", false))  # M18 economy2
		# The fallback order when the main strain costs more than the spread budget: profit per tray-second, best first.
		rank = allowed.duplicate()
		rank.sort_custom(func(a: int, b: int) -> bool:
			return (gross[a] - cost[a] * (1.0 - spread[a])) / grow_sec[a] > (gross[b] - cost[b] * (1.0 - spread[b])) / grow_sec[b])
		main = rank[0] if not rank.is_empty() else 0
		var want := StringName(str(opt.get("main", "")))
		for i: int in allowed:
			if cfg.seeds[i].id == want:
				main = i
		if carry is Dictionary and not (carry as Dictionary).is_empty():
			_restore(carry as Dictionary)
		else:
			_fresh()
		_refresh_effects()

	func _fresh() -> void:
		cash = float(cfg.starting_money)
		for i in TRAY_COUNT:
			tr_strain.append(-1)
			tr_water.append(0.0)
			tr_grown.append(0.0)
			tr_ready.append(false)
			tr_ready_at.append(0.0)
			tr_need.append(-1.0)
			tr_need_delay.append(0.0)
			tr_res.append(-1)
		for i in cfg.starting_watering_cans:
			can_charges.append(cfg.can_capacity)
			can_at.append(P_WELL)
			can_holder.append(-1)
			can_res.append(-1)
		for i in RACK_COUNT * HOOKS_PER_RACK:
			hk_strain.append(-1)
			hk_left.append(0.0)
			hk_factor.append(1.0)
			hk_res.append(-1)
		for i in workers:
			w_at.append(P_START)
			w_busy.append(0.0)
			w_hold.append(HOLD_NONE)
			w_item.append(-1)
			w_cured.append(false)
			w_factor.append(1.0)
			w_act.append(A_NONE)
			w_arg.append(-1)
			w_idle.append(false)
		for i in cfg.upgrades.size():
			up.append(0)

	func _snapshot() -> Dictionary:
		return {
			"clock": clock, "cash": cash, "reserved": reserved, "spread_acc": spread_acc, "need_count": need_count,
			"up": up.duplicate(),
			"tr_strain": tr_strain.duplicate(), "tr_water": tr_water.duplicate(), "tr_grown": tr_grown.duplicate(),
			"tr_ready": tr_ready.duplicate(), "tr_ready_at": tr_ready_at.duplicate(), "tr_need": tr_need.duplicate(),
			"tr_need_delay": tr_need_delay.duplicate(), "tr_res": tr_res.duplicate(),
			"can_charges": can_charges.duplicate(), "can_at": can_at.duplicate(), "can_holder": can_holder.duplicate(),
			"can_res": can_res.duplicate(),
			"hk_strain": hk_strain.duplicate(), "hk_left": hk_left.duplicate(), "hk_factor": hk_factor.duplicate(),
			"hk_res": hk_res.duplicate(),
			"w_at": w_at.duplicate(), "w_busy": w_busy.duplicate(), "w_hold": w_hold.duplicate(), "w_item": w_item.duplicate(),
			"w_cured": w_cured.duplicate(), "w_factor": w_factor.duplicate(), "w_act": w_act.duplicate(),
			"w_arg": w_arg.duplicate(), "w_idle": w_idle.duplicate(),
		}

	func _restore(s: Dictionary) -> void:
		clock = s["clock"]
		cash = s["cash"]
		reserved = s["reserved"]
		spread_acc = s["spread_acc"]
		need_count = s["need_count"]
		up.assign(s["up"])
		tr_strain.assign(s["tr_strain"])
		tr_water.assign(s["tr_water"])
		tr_grown.assign(s["tr_grown"])
		tr_ready.assign(s["tr_ready"])
		tr_ready_at.assign(s["tr_ready_at"])
		tr_need.assign(s["tr_need"])
		tr_need_delay.assign(s["tr_need_delay"])
		tr_res.assign(s["tr_res"])
		can_charges.assign(s["can_charges"])
		can_at.assign(s["can_at"])
		can_holder.assign(s["can_holder"])
		can_res.assign(s["can_res"])
		hk_strain.assign(s["hk_strain"])
		hk_left.assign(s["hk_left"])
		hk_factor.assign(s["hk_factor"])
		hk_res.assign(s["hk_res"])
		w_at.assign(s["w_at"])
		w_busy.assign(s["w_busy"])
		w_hold.assign(s["w_hold"])
		w_item.assign(s["w_item"])
		w_cured.assign(s["w_cured"])
		w_factor.assign(s["w_factor"])
		w_act.assign(s["w_act"])
		w_arg.assign(s["w_arg"])
		w_idle.assign(s["w_idle"])

	func _refresh_effects() -> void:
		var growth := 0.0
		var sale := 0.0
		var cans := 0.0
		for i in cfg.upgrades.size():
			var def := cfg.upgrades[i]
			var total := def.effect_per_level * float(up[i])
			match def.effect_key:
				Const.EFFECT_GROWTH_SPEED:
					growth += total
				Const.EFFECT_SALE_BONUS:
					sale += total
				Const.EFFECT_CAN_CAPACITY:
					cans += total
		growth_mult = 1.0 + growth
		sale_mult = 1.0 + sale
		can_capacity = cfg.can_capacity + int(cans)
		for i in cfg.seeds.size():
			# Growth-seconds per second: the floor's stall share off, the dark seconds back on for a strain that grows in them.
			rates[i] = (growth_floor + dark_share * maxf(cfg.seeds[i].dark_growth_multiplier, 0.0)) * growth_mult

	func play() -> Dictionary:
		var steps := int(round(length / DT))
		for _i in steps:
			_tick()
		if met_at < 0.0:
			carry_state = _snapshot()
		var favors: Dictionary = {}
		for i in cfg.upgrades.size():
			favors[String(cfg.upgrades[i].id)] = up[i]
		return {
			"shift": shift, "workers": workers, "skill": skill, "quota": quota_plain, "quota_taxed": quota,
			"deposits": sales, "met_at": met_at, "made": met_at >= 0.0, "main": String(cfg.seeds[main].id),
			"by_strain": by_strain, "cured": cured_count, "wet_no_hook": wet_no_hook, "cure_wanted": cure_wanted,
			"turned": turned, "mutable": mutable, "exposure": exposure,
			"time": {"walk": time_walk, "water": time_water, "handle": time_handle, "idle": time_idle, "events": time_events},
			"trays": {"empty": tray_empty, "growing": tray_growing, "dry": tray_dry, "ready": tray_ready},
			"bottleneck": _bottleneck(), "favors": favors, "cash": cash, "timeline": timeline, "carry": carry_state,
			"final_raised": final_raised,  # M18 economy2
		}

	func _bottleneck() -> String:
		var total := float(workers) * length
		if time_idle / total >= 0.25:
			if cure_wanted > 0 and float(wet_no_hook) / float(cure_wanted) >= 0.25:
				return "hooks"
			if cash_short / (float(tray_limit) * length) >= 0.15:
				return "cash"
			return "trays"
		if time_water >= time_walk and time_water >= time_handle:
			return "water trips"
		return "walking" if time_walk >= time_handle else "handling"

	# --- M18 economy2 ---
	## The final notice's half-time look (GameState._final_on_time): under final_interim_share of the payment
	## deposited, the payment rises by final_interim_raise of itself (the audit's raise; `quota` already carries the
	## expected audit).
	func _final_look() -> void:
		final_looked = true
		if sales < quota * clampf(cfg.final_interim_share, 0.0, 1.0):
			quota *= 1.0 + maxf(cfg.final_interim_raise, 0.0)
			final_raised = true
	# --- end M18 economy2 ---

	func _tick() -> void:
		clock += DT
		t += DT
		if cash_drain > 0.0:
			cash = maxf(cash - cash_drain * DT, minf(cash, reserved))
		if contract_cash > 0.0 and t >= contract_at:
			cash += contract_cash
			contract_cash = 0.0
		_tick_trays()
		for h in hk_strain.size():
			if hk_strain[h] >= 0 and hk_left[h] > 0.0:
				hk_left[h] -= DT
		for w in workers:
			w_busy[w] -= DT
			if w_busy[w] > 0.0:
				continue
			if w_act[w] != A_NONE:
				_complete(w)
			if w_busy[w] <= 0.0:
				_decide(w)
		if final_look and not final_looked and met_at < 0.0 and t >= length * FINAL_LOOK_AT: _final_look()  # M18 economy2
		if met_at < 0.0 and sales >= quota:
			met_at = t
			carry_state = _snapshot()

	func _tick_trays() -> void:
		var short := cash - reserved < min_cost
		for i in tray_limit:
			var st := tr_strain[i]
			if st < 0:
				tray_empty += DT
				if short:
					cash_short += DT
				continue
			if tr_ready[i]:
				tray_ready += DT
				continue
			var water := tr_water[i]
			var rate := rates[st]
			if water >= dry:
				tr_grown[i] += DT * rate
				tray_growing += DT
			else:
				tray_dry += DT
			water = maxf(0.0, water - DT * drain[st])
			tr_water[i] = water
			if tr_grown[i] >= grow_sec[st]:
				tr_ready[i] = true
				tr_ready_at[i] = clock
				tr_need[i] = -1.0
				continue
			# Dry before it is ready? Then it is a job, once somebody notices.
			if water < water_at and (water - dry) / drain[st] < (grow_sec[st] - tr_grown[i]) / rate:
				if tr_need[i] < 0.0:
					tr_need[i] = clock
					need_count += 1
					var forget := int(sk["forget_every"]) * workers # more heads, fewer trays forgotten
					tr_need_delay[i] = notice + (float(sk["forget_sec"]) if forget > 0 and need_count % forget == 0 else 0.0)
					if tr_grown[i] <= 0.0:
						tr_need_delay[i] = 0.0 # whoever planted it knows the soil is dry
			else:
				tr_need[i] = -1.0

	# --- jobs ---------------------------------------------------------------------------------------------------------

	func _go(w: int, to: int, act_sec: float, act: int, arg: int, cat: int) -> void:
		var d := dist[w_at[w] * POINT_COUNT + to]
		var travel := 0.0
		if d > 0.3:
			var v := heavy_speed if w_hold[w] == HOLD_BUNDLE and heavy[w_item[w]] else speed
			travel = d / v + leg
		var plain := travel + act_sec + think
		w_busy[w] += plain * slow
		w_at[w] = to
		w_act[w] = act
		w_arg[w] = arg
		w_idle[w] = false
		if cat == CAT_WATER:
			time_water += plain
		else:
			time_walk += travel
			time_handle += act_sec + think
		time_events += plain * (slow - 1.0)

	func _wait(w: int) -> void:
		w_busy[w] += IDLE_SEC
		w_act[w] = A_NONE
		w_idle[w] = true
		time_idle += IDLE_SEC

	func _need_visible(i: int) -> bool:
		return tr_res[i] < 0 and tr_strain[i] >= 0 and not tr_ready[i] and tr_need[i] >= 0.0 and clock - tr_need[i] >= tr_need_delay[i]

	func _ready_visible(i: int) -> bool:
		return tr_res[i] < 0 and tr_ready[i] and clock - tr_ready_at[i] >= notice

	## A plant that may turn: ready (seen at once, it twitches), or about to be ready for a worker who stands by.
	func _turning(i: int) -> bool:
		if tr_res[i] >= 0 or tr_strain[i] < 0 or mutation[tr_strain[i]] <= 0.0:
			return false
		if tr_ready[i]:
			return clock - tr_ready_at[i] >= float(sk["turn_react_sec"])
		var ahead := float(sk["anticipate_sec"])
		return ahead > 0.0 and tr_water[i] >= dry and (grow_sec[tr_strain[i]] - tr_grown[i]) / rates[tr_strain[i]] <= ahead

	func _nearest_tray(w: int, kind: int) -> int:
		var best := -1
		var best_d := INF
		for i in tray_limit:
			var hit := false
			match kind:
				0:
					hit = _need_visible(i)
				1:
					hit = _ready_visible(i)
				2:
					hit = _turning(i)
				3:
					hit = tr_res[i] < 0 and tr_strain[i] < 0
			if not hit:
				continue
			var d := dist[w_at[w] * POINT_COUNT + P_TRAY0 + i]
			if d < best_d:
				best_d = d
				best = i
		return best

	func _needs_visible() -> int:
		var n := 0
		for i in tray_limit:
			if _need_visible(i):
				n += 1
		return n

	func _collectable_hook() -> int:
		for h in hk_strain.size():
			if hk_strain[h] < 0 or hk_res[h] >= 0:
				continue
			if hk_left[h] <= 0.0:
				return h
			# It will not be cured in time to reach the chute: take it now and deposit it wet.
			var rack := P_RACK0 + h / HOOKS_PER_RACK
			if length - t - dist[rack * POINT_COUNT + P_CHUTE] / speed - leg - 2.0 * press - CURE_SLACK_SEC < hk_left[h]:
				return h
		return -1

	func _others_idle(w: int) -> bool:
		for o in workers:
			if o != w and w_idle[o] and w_hold[o] == HOLD_NONE:
				return true
		return false

	func _can_buy() -> bool:
		return cash - reserved >= min_cost

	func _other_job(w: int) -> bool:
		if _others_idle(w):
			return false
		for i in tray_limit:
			if _ready_visible(i) or _turning(i):
				return true
			if tr_res[i] < 0 and tr_strain[i] < 0 and _can_buy():
				return true
		return _collectable_hook() >= 0

	func _growing() -> int:
		var n := 0
		for i in tray_limit:
			if tr_strain[i] >= 0 and not tr_ready[i]:
				n += 1
		return n

	func _bundle_value(strain: int, factor: float, cured: bool) -> float:
		return gross[strain] * sale_mult * factor * (1.0 + maxf(cfg.cure_bonus, 0.0) if cured else 1.0)

	## The hook to hang the bundle in hand on, -1 = straight to the chute.
	func _cure_hook(w: int) -> int:
		if cure_policy == CURE_NONE or w_cured[w]:
			return -1
		var strain := w_item[w]
		var gain := _bundle_value(strain, w_factor[w], true) - _bundle_value(strain, w_factor[w], false)
		if cure_policy == CURE_DEAR and gain < CURE_MIN_GAIN:
			return -1
		var v := heavy_speed if heavy[strain] else speed
		var best := -1
		for h in hk_strain.size():
			if hk_strain[h] < 0 and hk_res[h] < 0:
				best = h
				break
		var rack := P_RACK0 + (maxi(best, 0) / HOOKS_PER_RACK)
		var needed := dist[w_at[w] * POINT_COUNT + rack] / v + cfg.cure_sec + dist[rack * POINT_COUNT + P_CHUTE] / v \
				+ 2.0 * leg + 3.0 * press + 2.0 * think + CURE_SLACK_SEC
		if t + needed * slow > length:
			return -1
		cure_wanted += 1
		if best < 0:
			wet_no_hook += 1
		return best

	func _choose_seed() -> int:
		var avail := cash - reserved
		var empties := 0
		for i in tray_limit:
			if tr_strain[i] < 0 and tr_res[i] < 0:
				empties += 1
		var budget := avail / float(maxi(empties, 1))
		if cost[main] <= budget:
			return main
		for i: int in rank:
			if cost[i] <= budget and cost[i] <= cost[main]:
				return i
		var cheapest := -1
		for i: int in allowed:
			if cost[i] <= avail and (cheapest < 0 or cost[i] < cost[cheapest]):
				cheapest = i
		return cheapest

	## Buys the cheapest next favor level when the cash covers it on top of the packets the floor needs. Returns the
	## seconds it takes at the window.
	func _buy_favors(seed_cost: float) -> float:
		var spent := 0.0
		while true:
			var pick := -1
			var price := INF
			for i in cfg.upgrades.size():
				var def := cfg.upgrades[i]
				if up[i] >= def.max_level:
					continue
				var c := float(def.cost_for_level(up[i] + 1))
				if c < price:
					price = c
					pick = i
			if pick < 0:
				break
			var need := FAVOR_SPARE_PACKETS
			for i in tray_limit:
				if tr_strain[i] < 0 or tr_ready[i]:
					need += 1
			if cash - reserved - seed_cost < price + float(need) * cost[main]:
				break
			cash -= price
			up[pick] += 1
			spent += buy_sec
			_refresh_effects()
		return spent

	func _plan_buy(w: int) -> bool:
		if not _can_buy():
			return false
		# The empty tray nearest to the window.
		var tray := -1
		var best_d := INF
		for i in tray_limit:
			if tr_res[i] < 0 and tr_strain[i] < 0:
				var d := dist[P_SHOP * POINT_COUNT + P_TRAY0 + i]
				if d < best_d:
					best_d = d
					tray = i
		if tray < 0:
			return false
		var strain := _choose_seed()
		if strain < 0:
			return false
		var extra := _buy_favors(cost[strain]) if use_favors else 0.0
		reserved += cost[strain]
		tr_res[tray] = w
		w_item[w] = strain
		_go(w, P_SHOP, buy_sec + extra, A_BUY, tray, CAT_WORK)
		return true

	func _plan_harvest(w: int, tray: int) -> void:
		tr_res[tray] = w
		_go(w, P_TRAY0 + tray, press, A_HARVEST, tray, CAT_WORK)

	func _decide(w: int) -> void:
		match w_hold[w]:
			HOLD_BUNDLE:
				var hook := _cure_hook(w)
				if hook >= 0:
					hk_res[hook] = w
					_go(w, P_RACK0 + hook / HOOKS_PER_RACK, press, A_HANG, hook, CAT_WORK)
				else:
					_go(w, P_CHUTE, press, A_DEPOSIT, 0, CAT_WORK)
			HOLD_PACKET:
				_go(w, P_TRAY0 + w_arg[w], press, A_PLANT, w_arg[w], CAT_WORK)
			HOLD_CAN:
				_decide_can(w)
			_:
				_decide_free(w)

	func _decide_can(w: int) -> void:
		var can := w_item[w]
		if can_charges[can] > 0:
			var tray := _nearest_tray(w, 0)
			if tray >= 0:
				tr_res[tray] = w
				_go(w, P_TRAY0 + tray, press, A_WATER, tray, CAT_WATER)
				return
			if _other_job(w):
				_go(w, w_at[w], press * 0.5, A_DROP_CAN, can, CAT_WATER)
				return
			if can_charges[can] * 2 <= can_capacity and _growing() > 0:
				_go(w, P_WELL, press, A_REFILL, can, CAT_WATER)
				return
			_wait(w)
			return
		if _needs_visible() > 0:
			_go(w, P_WELL, press, A_REFILL, can, CAT_WATER)
		elif _other_job(w):
			_go(w, w_at[w], press * 0.5, A_DROP_CAN, can, CAT_WATER)
		elif _growing() > 0:
			_go(w, P_WELL, press, A_REFILL, can, CAT_WATER)
		else:
			_wait(w)

	func _decide_free(w: int) -> void:
		var tray := _nearest_tray(w, 2)
		if tray >= 0:
			_plan_harvest(w, tray)
			return
		var needs := _needs_visible()
		if needs > 0:
			var holders := 0
			for c in can_charges.size():
				if can_holder[c] >= 0 or can_res[c] >= 0:
					holders += 1
			if needs > holders * NEEDS_PER_CAN:
				var pick := -1
				var best_d := INF
				for c in can_charges.size():
					if can_holder[c] < 0 and can_res[c] < 0:
						var d := dist[w_at[w] * POINT_COUNT + can_at[c]]
						if d < best_d:
							best_d = d
							pick = c
				if pick >= 0:
					can_res[pick] = w
					_go(w, can_at[pick], press, A_PICK_CAN, pick, CAT_WATER)
					return
		tray = _nearest_tray(w, 1)
		if tray >= 0:
			_plan_harvest(w, tray)
			return
		var hook := _collectable_hook()
		if hook >= 0:
			hk_res[hook] = w
			_go(w, P_RACK0 + hook / HOOKS_PER_RACK, press, A_TAKE, hook, CAT_WORK)
			return
		if _plan_buy(w):
			return
		_wait(w)

	func _complete(w: int) -> void:
		var arg := w_arg[w]
		var act := w_act[w]
		w_act[w] = A_NONE
		match act:
			A_HARVEST:
				if not tr_ready[arg]:
					if tr_strain[arg] < 0 or tr_water[arg] < dry:
						tr_res[arg] = -1 # it ran dry while the worker stood by: let go, it is a watering job now
						return
					# Standing by a plant that is about to be ready.
					w_act[w] = A_HARVEST
					w_busy[w] += DT
					time_idle += DT
					return
				_harvest(w, arg)
			A_DEPOSIT:
				var strain := w_item[w]
				var value := _bundle_value(strain, w_factor[w], w_cured[w])
				cash += value
				sales += value
				timeline.append(Vector2(t, sales))
				var id := String(cfg.seeds[strain].id)
				var row: Dictionary = by_strain.get(id, {"bundles": 0, "cash": 0.0})
				row["bundles"] = int(row["bundles"]) + 1
				row["cash"] = float(row["cash"]) + value
				by_strain[id] = row
				if w_cured[w]:
					cured_count += 1
				w_hold[w] = HOLD_NONE
			A_HANG:
				hk_strain[arg] = w_item[w]
				hk_left[arg] = maxf(cfg.cure_sec, 0.0)
				hk_factor[arg] = w_factor[w]
				hk_res[arg] = -1
				w_hold[w] = HOLD_NONE
			A_TAKE:
				w_hold[w] = HOLD_BUNDLE
				w_item[w] = hk_strain[arg]
				w_factor[w] = hk_factor[arg]
				w_cured[w] = hk_left[arg] <= 0.0
				hk_strain[arg] = -1
				hk_res[arg] = -1
			A_BUY:
				var strain := w_item[w]
				reserved -= cost[strain]
				cash -= cost[strain]
				w_hold[w] = HOLD_PACKET
				w_arg[w] = arg
			A_PLANT:
				tr_strain[arg] = w_item[w]
				tr_grown[arg] = 0.0
				tr_ready[arg] = false
				tr_need[arg] = -1.0
				tr_res[arg] = -1
				w_hold[w] = HOLD_NONE
			A_PICK_CAN:
				can_holder[arg] = w
				can_res[arg] = -1
				w_hold[w] = HOLD_CAN
				w_item[w] = arg
			A_WATER:
				var can := w_item[w]
				if tr_strain[arg] >= 0 and not tr_ready[arg] and can_charges[can] > 0:
					tr_water[arg] = minf(1.0, tr_water[arg] + cfg.water_per_charge)
					can_charges[can] -= 1
				tr_need[arg] = -1.0
				tr_res[arg] = -1
			A_REFILL:
				can_charges[arg] = can_capacity
			A_DROP_CAN:
				can_holder[arg] = -1
				can_at[arg] = w_at[w]
				w_hold[w] = HOLD_NONE

	func _harvest(w: int, tray: int) -> void:
		var strain := tr_strain[tray]
		var factor := 1.0
		var chance := mutation[strain]
		if chance > 0.0:
			mutable += 1
			exposure += chance
			if clock - tr_ready_at[tray] > cfg.mutation_warning_sec:
				# Too late for the share that turned (less the times a real worker drops everything and runs, which the
				# model's worker never does): the bundle, a worker's time with the flamethrower, the deposit on it.
				var gone := chance * float(sk["late_turn_loss"])
				factor = 1.0 - gone
				turned += gone
				var lost := gone * float(sk["hostile_sec"])
				w_busy[w] += lost
				time_events += lost
				cash = maxf(cash - gone * float(cfg.cabinet_deposit), minf(cash, reserved))
		tr_res[tray] = -1
		tr_ready[tray] = false
		tr_grown[tray] = 0.0
		tr_need[tray] = -1.0
		spread_acc += spread[strain]
		if spread[strain] > 0.0 and spread_acc >= 1.0:
			spread_acc -= 1.0
			tr_water[tray] = maxf(tr_water[tray], 1.0)
		else:
			tr_strain[tray] = -1
		w_hold[w] = HOLD_BUNDLE
		w_item[w] = strain
		w_factor[w] = factor
		w_cured[w] = false


# --- closed-form strain numbers -------------------------------------------------------------------------------------

## What one plant of each strain on sale in `shift` costs and brings, from the same distances and timings as the
## shift model, for a worker of `skill` on the pen's trays. Per strain: {id, cost, profit (expected, sold wet),
## labour_sec, tray_sec, waterings, per_labour ($ per worker-second), per_tray ($ per tray-second), roi (profit per
## dollar of seed), cured_gain ($ the cure adds), cure_sec (extra worker-seconds a cure takes)}.
static func strain_metrics(cfg: BalanceConfig, skill: int, shift: int = 99, replay: bool = true) -> Array[Dictionary]:
	var sk: Dictionary = SKILLS[skill]
	var speed := worker_speed(cfg, skill)
	var leg: float = sk["leg_sec"]
	var press: float = sk["press_sec"]
	var think: float = sk["think_sec"]
	var miss: float = sk["mutation_miss"]
	var water_at := maxf(float(sk["water_at"]), cfg.dry_threshold)
	var to_shop := 0.0
	var to_well := 0.0
	var to_chute := 0.0
	var to_rack := 0.0
	for i in PEN_TRAYS:
		to_shop += distance(P_SHOP, P_TRAY0 + i) / float(PEN_TRAYS)
		to_well += distance(P_WELL, P_TRAY0 + i) / float(PEN_TRAYS)
		to_chute += distance(P_CHUTE, P_TRAY0 + i) / float(PEN_TRAYS)
		to_rack += distance(P_RACK0, P_TRAY0 + i) / float(PEN_TRAYS)
	var hop := distance(P_TRAY0, P_TRAY0 + 2)
	var seed_sec := 2.0 * (to_shop / speed + leg + think) + float(sk["buy_sec"]) + press
	var watering_sec := hop / speed + leg + press + think \
			+ (2.0 * (to_well / speed + leg) + press + think) / float(cfg.can_capacity)
	var out: Array[Dictionary] = []
	for index: int in strains_on_sale(cfg, shift, replay):
		var s := cfg.seeds[index]
		var grow := base_grow_sec(cfg) * s.grow_time_multiplier
		var carry_speed := minf(cfg.walk_speed * cfg.heavy_speed_factor, speed) if s.heavy else speed
		var haul_sec := to_chute / carry_speed + to_chute / speed + 2.0 * (leg + press + think)
		var waterings := grow * cfg.water_drain_per_sec * s.thirst_multiplier / (1.0 - water_at)
		var lost := s.mutation_chance * miss
		var seed_cost := float(s.cost) * (1.0 - s.spread_chance) + lost * float(cfg.cabinet_deposit)
		var gross := float(s.yield_amount * s.sale_value_per_unit) * (1.0 - lost)
		var labour := seed_sec * (1.0 - s.spread_chance) + watering_sec * maxf(waterings - s.spread_chance, 0.0) + haul_sec \
				+ lost * float(sk["hostile_sec"])
		var tray_sec := grow + float(sk["notice_sec"]) + think + hop / speed + leg + press
		var profit := gross - seed_cost
		# A cure: tray -> rack -> (later) rack -> chute in place of tray -> chute, with a second trip out to the rack.
		var rack_to_chute := distance(P_RACK0, P_CHUTE)
		var cure_extra := (to_rack + rack_to_chute - to_chute) / carry_speed + rack_to_chute / speed + 2.0 * (leg + press + think)
		out.append({
			"id": String(s.id), "cost": s.cost, "profit": profit, "labour_sec": labour, "tray_sec": tray_sec,
			"waterings": waterings, "per_labour": profit / labour, "per_tray": profit / tray_sec, "roi": profit / maxf(seed_cost, 1.0),
			"cured_gain": gross * maxf(cfg.cure_bonus, 0.0), "cure_sec": cure_extra,
		})
	return out


## The ids of the strains on sale in `shift` that another strain on sale beats or equals on every one of profit per
## worker-second, profit per tray-second and profit per dollar of seed (and beats on at least one).
static func dominated_strains(cfg: BalanceConfig, skill: int, shift: int, replay: bool = true) -> PackedStringArray:
	var rows := strain_metrics(cfg, skill, shift, replay)
	var out: PackedStringArray = []
	for a: Dictionary in rows:
		for b: Dictionary in rows:
			if a == b:
				continue
			var ge := float(b["per_labour"]) >= float(a["per_labour"]) and float(b["per_tray"]) >= float(a["per_tray"]) \
					and float(b["roi"]) >= float(a["roi"])
			var gt := float(b["per_labour"]) > float(a["per_labour"]) or float(b["per_tray"]) > float(a["per_tray"]) \
					or float(b["roi"]) > float(a["roi"])
			if ge and gt:
				out.append(String(a["id"]))
				break
	return out


# --- a crew: the same campaign played five times -------------------------------------------------------------------

## A campaign is a chain of discrete bundles: one bundle more or less at a buzzer moves a shift by several per cent and
## the carried floor moves the next one. So a crew is played JITTERS.size() times, each with the worker's own timings
## (per stop, per press, the window, thinking, noticing) stretched by one of these factors, and the mean is reported.
const JITTERS: Array[float] = [0.94, 0.97, 1.0, 1.03, 1.06]


## Plays the crew in `opt` (workers, skill, favors, racks, cure, ...) through `shifts` shifts once per JITTERS entry.
## Returns {"campaigns": [run_campaign result per jitter], "made": [shifts paid in a row per jitter, sorted],
## "shifts": [per shift {shift, quota, deposits (mean), low, high, made (campaigns that met it), alive (campaigns
## that had paid every earlier shift), met_at (mean second of those that met it, -1 = none), main, bottleneck
## (the most common ones), cured, wet_no_hook, cure_wanted, turned, exposure (sums)}]}.
static func run_crew(cfg: BalanceConfig, opt: Dictionary, shifts: int = 6) -> Dictionary:
	var campaigns: Array = []
	var made: Array[int] = []
	for jitter: float in JITTERS:
		var o := opt.duplicate()
		o["jitter"] = jitter * float(opt.get("jitter", 1.0))
		var campaign := run_campaign(cfg, o, shifts)
		campaigns.append(campaign)
		made.append(shifts_made(campaign))
	made.sort()
	var rows: Array[Dictionary] = []
	for index in shifts:
		var deposits := 0.0
		var low := INF
		var high := 0.0
		var met := 0
		var alive := 0
		var met_at := 0.0
		var mains: Dictionary = {}
		var necks: Dictionary = {}
		var sums := {"cured": 0.0, "wet_no_hook": 0.0, "cure_wanted": 0.0, "turned": 0.0, "exposure": 0.0}
		var quota := 0
		for campaign: Array in campaigns:
			var r: Dictionary = campaign[index]
			var d := float(r["deposits"])
			quota = int(r["quota"])
			deposits += d
			low = minf(low, d)
			high = maxf(high, d)
			if bool(r["made"]):
				met += 1
				met_at += float(r["met_at"])
			if bool(r["alive"]):
				alive += 1
			mains[r["main"]] = int(mains.get(r["main"], 0)) + 1
			necks[r["bottleneck"]] = int(necks.get(r["bottleneck"], 0)) + 1
			for key: String in sums:
				sums[key] = float(sums[key]) + float(r[key])
		var row := {
			"shift": index + 1, "quota": quota, "deposits": deposits / float(campaigns.size()), "low": low, "high": high,
			"made": met, "alive": alive, "met_at": met_at / float(met) if met > 0 else -1.0,
			"main": _most_common(mains), "bottleneck": _most_common(necks),
		}
		row.merge(sums)
		rows.append(row)
	return {"campaigns": campaigns, "made": made, "shifts": rows}


static func _most_common(counts: Dictionary) -> String:
	var best := ""
	var best_n := -1
	for key: Variant in counts:
		if int(counts[key]) > best_n:
			best_n = int(counts[key])
			best = str(key)
	return best


## The shifts a crew pays in a row: the median over its campaigns.
static func crew_shifts_made(crew: Dictionary) -> int:
	var made: Array = crew["made"]
	return int(made[made.size() / 2])


## True when at least `at_least` of the crew's campaigns met the payment of `shift` (1-based).
static func crew_makes(crew: Dictionary, shift: int, at_least: int = 3) -> bool:
	return int((crew["shifts"] as Array)[shift - 1]["made"]) >= at_least


# --- M18 economy2: the run a team plays, to its final notice -----------------------------------------------------------
## Since M17 a run ends at a final notice: shift final_shift_by_team[workers - 1] (4 for one worker, 5 for two, 6 for
## three or four). Paying it clears the run; a missed shift before it ends the run. run_team plays a crew through
## exactly those shifts, once per JITTERS entry, with the final notice's half-time look on the last one (Run._final_look:
## at FINAL_LOOK_AT of the clock, under final_interim_share of the payment deposited, the payment rises by
## final_interim_raise). Not modelled: the final notice's two conditions (no condition is modelled), a worker who
## joins in the alley (the team is the same size all run). Nothing here knows the strains: run_campaign tries every
## strain the config has on sale.
## What-if for a payment formula BalanceConfig does not have: opt "team_factor" (Callable(shift, workers) -> float)
## replaces the team factor of quota_for_round in every shift (the solo payment stays the formula's).

## GameState.FINAL_LOOK_AT: the share of the final notice's clock that has run when the host looks at the payment.
const FINAL_LOOK_AT := 0.5
## The payment as M15 to M17 shipped it (350, x1.82 + 688 a shift; a flat +10% a worker beyond the first): the
## "before" of the M18 retune.
const M17_NUMBERS: Dictionary = {
	"base_quota": 350, "quota_scale": 1.82, "quota_add": 688, "quota_per_extra_player": 0.1,
	"quota_team_by_shift": [], "quota_team_by_size": [],
}


## The run's last shift for a team of `workers` (BalanceConfig.final_shift_by_team; 6 when the table is empty).
static func final_shift(cfg: BalanceConfig, workers: int) -> int:
	var table := cfg.final_shift_by_team
	if table.is_empty():
		return 6
	return maxi(int(table[clampi(workers, 1, table.size()) - 1]), 1)


## run_crew through the team's run. `opt` as run_crew, plus final_look (default true: the half-time look on the last
## shift) and shifts (default final_shift(cfg, workers)). Returns run_crew's result plus {final (the last shift),
## cleared (campaigns that paid every shift of the run), reached (campaigns that paid every shift before the last),
## raised (campaigns whose final notice went up at half time), raised_lost (of those, campaigns that deposited the
## payment as it was before the look and missed it after)}.
static func run_team(cfg: BalanceConfig, opt: Dictionary) -> Dictionary:
	var workers := clampi(int(opt.get("workers", 1)), 1, 4)
	var last := maxi(int(opt.get("shifts", final_shift(cfg, workers))), 1)
	var o := opt.duplicate()
	o["final_shift"] = last
	var crew := run_crew(cfg, o, last)
	var cleared := 0
	var raised := 0
	var raised_lost := 0
	for n: int in crew["made"]:
		if n >= last:
			cleared += 1
	for campaign: Array in crew["campaigns"]:
		var r: Dictionary = campaign[last - 1]
		if bool(r.get("final_raised", false)):
			raised += 1
			var before := float(r["quota_taxed"]) / (1.0 + maxf(cfg.final_interim_raise, 0.0))
			if not bool(r["made"]) and float(r["deposits"]) >= before:
				raised_lost += 1
	crew["final"] = last
	crew["cleared"] = cleared
	crew["reached"] = int((crew["shifts"] as Array)[last - 1]["alive"])
	crew["raised"] = raised
	crew["raised_lost"] = raised_lost
	return crew


## Every team of the table, each through its own run: [skill][workers - 1] -> run_team result.
static func all_teams(cfg: BalanceConfig, opt: Dictionary = {}) -> Array:
	var out: Array = []
	for skill in SKILLS.size():
		var row: Array = []
		for workers in range(1, 5):
			var o := opt.duplicate()
			o["workers"] = workers
			o["skill"] = skill
			row.append(run_team(cfg, o))
		out.append(row)
	return out


## The payment's team factor in `shift` for `workers`: quota_for_round(shift, workers) / quota_for_round(shift, 1).
static func team_factor(cfg: BalanceConfig, shift: int, workers: int) -> float:
	return cfg.quota_team_factor(shift, workers)


## One line for a config's payment: the solo curve and the team numbers.
static func describe_payment(cfg: BalanceConfig) -> String:
	var team := "+%d%% a worker beyond the first" % roundi(cfg.quota_per_extra_player * 100.0)
	if not cfg.quota_team_by_shift.is_empty():
		team = "team table %s by shift x %s for 2 / 3 / 4 workers" % [cfg.quota_team_by_shift, str(cfg.quota_team_by_size) if not cfg.quota_team_by_size.is_empty() else "1 / 2 / 3"]
	return "base %d, x%.2f + %d a shift, %s" % [cfg.base_quota, cfg.quota_scale, cfg.quota_add, team]


## The printed run table: per team, per shift of its run, mean deposits by the buzzer / payment due and how many of the
## five campaigns met it; then campaigns that reached the final notice, cleared it, and had it raised at half time.
static func format_runs(cfg: BalanceConfig, title: String, opt: Dictionary = {}, teams: Array = []) -> String:
	if teams.is_empty():
		teams = all_teams(cfg, opt)
	var lines: PackedStringArray = []
	lines.append("== %s: %s; final notice at shift %s by team size" % [title, describe_payment(cfg), cfg.final_shift_by_team])
	lines.append("   deposits by the buzzer / payment due, campaigns of %d that met it; reached / cleared the final notice, raised at half time" % JITTERS.size())
	for skill in teams.size():
		for wi in (teams[skill] as Array).size():
			var team: Dictionary = teams[skill][wi]
			var line := "   %-7s x%d" % [SKILL_NAMES[skill], wi + 1]
			for r: Dictionary in team["shifts"]:
				line += " | %5.0f /%5d %d/%d" % [float(r["deposits"]), int(r["quota"]), int(r["made"]), JITTERS.size()]
			for _pad in range(int(team["final"]), 6):
				line += " |                 "
			line += " || reached %d, cleared %d, raised %d" % [int(team["reached"]), int(team["cleared"]), int(team["raised"])]
			if int(team["raised_lost"]) > 0:
				line += " (%d lost to it)" % int(team["raised_lost"])
			lines.append(line)
	return "\n".join(lines)
# --- end M18 economy2 ---------------------------------------------------------------------------------------------------


# --- printing ----------------------------------------------------------------------------------------------------------

## Every crew of the table: [skill][workers - 1] -> run_crew result.
static func all_crews(cfg: BalanceConfig, opt: Dictionary = {}, shifts: int = 6) -> Array:
	var out: Array = []
	for skill in SKILLS.size():
		var row: Array = []
		for workers in range(1, 5):
			var o := opt.duplicate()
			o["workers"] = workers
			o["skill"] = skill
			row.append(run_crew(cfg, o, shifts))
		out.append(row)
	return out


## The printed table. Per skill and crew size, per shift: mean deposits by the buzzer / payment due, how many of the
## five campaigns met the payment, the mean second it was met; under it the usual main strain and bottleneck.
static func format_table(cfg: BalanceConfig, title: String, opt: Dictionary = {}, crews: Array = []) -> String:
	if crews.is_empty():
		crews = all_crews(cfg, opt)
	var lines: PackedStringArray = []
	lines.append("== %s: %s, cure %.0f s for +%d%%" % [title, describe_payment(cfg), cfg.cure_sec, roundi(cfg.cure_bonus * 100.0)])  # M18 economy2: describe_payment
	lines.append("   deposits by the buzzer / payment due, campaigns of %d that met it, mean second it was met; main strain, bottleneck" % JITTERS.size())
	for skill in crews.size():
		for wi in (crews[skill] as Array).size():
			var crew: Dictionary = crews[skill][wi]
			var top := "   %-7s x%d (%d)" % [SKILL_NAMES[skill], wi + 1, crew_shifts_made(crew)]
			var low := "                 "
			for r: Dictionary in crew["shifts"]:
				var met := "%3.0fs" % float(r["met_at"]) if int(r["made"]) > 0 else " -- "
				top += " | %5.0f /%5d %d/%d %s" % [float(r["deposits"]), int(r["quota"]), int(r["made"]), JITTERS.size(), met]
				low += " | %-10s %-11s  " % [String(r["main"]), String(r["bottleneck"])]
			lines.append(top)
			lines.append(low)
	lines.append("   (n) after the crew = shifts paid in a row (median of the campaigns)")
	return "\n".join(lines)


static func format_strains(cfg: BalanceConfig, skill: int) -> String:
	var lines: PackedStringArray = []
	lines.append("   %-11s %5s %7s %8s %8s %6s %8s %8s %5s %7s %7s" % ["strain (%s)" % SKILL_NAMES[skill].left(4), "cost", "profit",
			"labour s", "tray s", "water", "$/work s", "$/tray s", "roi", "cure +$", "cure s"])
	for m: Dictionary in strain_metrics(cfg, skill, 99, false):
		lines.append("   %-11s %5d %7.1f %8.1f %8.1f %6.2f %8.2f %8.2f %5.2f %7.1f %7.1f" % [m["id"], m["cost"], m["profit"],
				m["labour_sec"], m["tray_sec"], m["waterings"], m["per_labour"], m["per_tray"], m["roi"], m["cured_gain"], m["cure_sec"]])
	return "\n".join(lines)
