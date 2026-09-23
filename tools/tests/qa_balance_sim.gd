extends Node
## Balance estimate (QA milestone 7, report tool, not a pass/fail test). Simulates round N with the LIVE numbers
## (Config.balance: money, quota, round length, seeds, stage durations, water drain/threshold, cans) and the real room
## geometry (station access points from room.tscn) for 1..4 greedy players. Re-run after balance tweaks:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/qa_balance_sim.gd
## Optional: --sim-round=2 --sim-money=400 (wallet at round start) --sim-growth=1.25 (fertilizer multiplier)
##           --sim-quota=350 (what-if quota)
## Model (deliberately human-ish, not optimal): sprint speed + 0.25 s per leg, 0.5 s per E press, 2.5 s per shop
## purchase (open UI, click, close), one item in hand, cans start at the well; a player waters a growing plot as
## soon as it shows "dry!" (water < dry_threshold) or was never watered, drops the can to do anything else, and
## buys the seed chosen by the strategy. Plants persist, growth/drain only while PLAYING. Prints when the quota is
## met (or the sales at the buzzer) per strategy and team size.

const LEG_OVERHEAD := 0.25
const PRESS := 0.5
const BUY := 2.5
const DT := 0.1

var b: BalanceConfig
var points: Dictionary = {}   # "shop"/"well"/"bin"/"plot1".. -> Vector2 (x, z) access points

class Plot:
	var seed: SeedDef = null
	var water: float = 0.0
	var grown: float = 0.0        # seconds of growth accumulated
	var ready: bool = false
	var reserved: int = -1        # agent id working on it

class Can:
	var charges: int = 4
	var pos: Vector2
	var holder: int = -1
	var reserved: int = -1

class Agent:
	var id: int
	var pos: Vector2
	var busy: float = 0.0         # seconds until the current step finishes
	var holding: String = ""      # "" | "can" | "packet" | "product"
	var can: Can = null
	var packet: SeedDef = null
	var product_value: int = 0
	var plan: Array = []          # queued Callables executed when busy reaches 0

func _ready() -> void:
	b = Config.balance
	var room := (load("res://scenes/world/room.tscn") as PackedScene).instantiate() as Room
	for n in ["ShopCounter", "Well", "TurnInStation"]:
		var p: Vector3 = room.get_station_access_point(n, 1.3)
		points[{"ShopCounter": "shop", "Well": "well", "TurnInStation": "bin"}[n]] = Vector2(p.x, p.z)
	for i in range(1, 7):
		var p: Vector3 = room.get_station_access_point("GrowPlot%d" % i, 1.2)
		points["plot%d" % i] = Vector2(p.x, p.z)
	room.free()
	var round_n := int(Config.get_arg("sim-round", 1))
	var money := int(Config.get_arg("sim-money", b.starting_money))
	var growth := float(Config.get_arg("sim-growth", 1.0))
	var quota := int(Config.get_arg("sim-quota", b.quota_for_round(round_n)))
	print("balance sim: round %d, quota $%d, %d s, wallet $%d, growth x%.2f, %d plots, %d cans x %d charges, drain 1/%.0f s" % [
		round_n, quota, int(b.round_length_sec), money, growth, 6, b.starting_watering_cans, b.can_capacity, 1.0 / b.water_drain_per_sec])
	for s in b.seeds:
		print("  seed %-12s $%3d  grows %5.1f s  sells $%3d  profit $%3d  waterings %d" % [s.display_name, s.cost,
			b.total_grow_time(s) / growth, s.sale_value_per_unit * s.yield_amount, s.sale_value_per_unit * s.yield_amount - s.cost,
			ceili(b.total_grow_time(s) / growth / ((1.0 - b.dry_threshold) / b.water_drain_per_sec))])
	print("  %-24s %8s %8s %8s %8s" % ["strategy \\ players", "1", "2", "3", "4"])
	for strat in ["budget", "best_affordable", "purple_first", "golden_first"]:
		var cells: PackedStringArray = []
		for n in [1, 2, 3, 4]:
			var r := _simulate(n, strat, money, quota, growth)
			cells.append(("%5.0f s" % r[0]) if r[0] >= 0.0 else ("$%d" % r[1]))
		print("  %-24s %8s %8s %8s %8s" % [strat, cells[0], cells[1], cells[2], cells[3]])
	print("  (seconds = quota met at that time; $N = sales at 0:00, quota missed)")
	get_tree().quit.call_deferred(0)

func _choose_seed(strat: String, money: int) -> SeedDef:
	var budget := b.get_seed(&"budget")
	var purple := b.get_seed(&"purple")
	var golden := b.get_seed(&"golden")
	match strat:
		"budget":
			return budget if money >= budget.cost else null
		"purple_first":
			if money >= purple.cost: return purple
			return budget if money >= budget.cost else null
		"golden_first":
			if money >= golden.cost: return golden
			return budget if money >= budget.cost else null
		_:
			var best: SeedDef = null
			for s in b.seeds:
				if money >= s.cost and (best == null or s.sale_value_per_unit * s.yield_amount - s.cost > best.sale_value_per_unit * best.yield_amount - best.cost):
					best = s
			return best
	return null

## Returns [time quota met or -1, sales].
func _simulate(n_agents: int, strat: String, money: int, quota: int, growth: float) -> Array:
	var plots: Array[Plot] = []
	for i in 6:
		plots.append(Plot.new())
	var cans: Array[Can] = []
	for i in b.starting_watering_cans:
		var c := Can.new()
		c.charges = b.can_capacity
		c.pos = points["well"]
		cans.append(c)
	var agents: Array[Agent] = []
	for i in n_agents:
		var a := Agent.new()
		a.id = i
		a.pos = Vector2(0.0, 1.0)
		agents.append(a)
	# Shared mutable state (GDScript lambdas capture locals by value; a Dictionary is shared by reference).
	var st := {"money": money, "sales": 0, "reserved": 0}
	var t := 0.0
	var grow_s := func(s: SeedDef) -> float: return b.total_grow_time(s) / growth
	while t < b.round_length_sec:
		# World tick.
		for p in plots:
			if p.seed != null and not p.ready:
				if p.water >= b.dry_threshold:
					p.grown += DT
				p.water = maxf(0.0, p.water - DT * b.water_drain_per_sec)
				if p.grown >= grow_s.call(p.seed):
					p.ready = true
		# Agents.
		for a in agents:
			if a.busy > 0.0:
				a.busy -= DT
				continue
			if not a.plan.is_empty():
				var step: Callable = a.plan.pop_front()
				step.call()
				continue
			# Decide (an idle agent holds no reservations: its plan is empty).
			for p in plots:
				if p.reserved == a.id:
					p.reserved = -1
			for c in cans:
				if c.reserved == a.id:
					c.reserved = -1
			if a.holding == "product":
				_go(a, "bin", PRESS, func():
					st["sales"] += a.product_value
					st["money"] += a.product_value
					a.holding = "")
				continue
			if a.holding == "packet":
				var target := _find_plot(plots, a, func(p: Plot) -> bool: return p.seed == null)
				if target < 0:
					continue
				_go(a, "plot%d" % (target + 1), PRESS, func():
					plots[target].seed = a.packet   # the soil keeps its water from the previous plant
					plots[target].grown = 0.0
					plots[target].reserved = -1
					a.holding = "")
				continue
			var thirsty := _find_plot(plots, a, func(p: Plot) -> bool: return p.seed != null and not p.ready and p.water < b.dry_threshold)
			if a.holding == "can":
				if thirsty >= 0 and a.can.charges > 0:
					_go(a, "plot%d" % (thirsty + 1), PRESS, func():
						plots[thirsty].water = 1.0
						plots[thirsty].reserved = -1
						a.can.charges -= 1)
					continue
				if a.can.charges <= 0:
					_go(a, "well", PRESS, func(): a.can.charges = b.can_capacity)
					continue
				# Nothing to water: put the can down where we stand and do something else.
				a.can.holder = -1
				a.can.pos = a.pos
				a.can.reserved = -1
				a.can = null
				a.holding = ""
				a.busy = PRESS
				continue
			var ready := _find_plot(plots, a, func(p: Plot) -> bool: return p.ready)
			if ready >= 0:
				_go(a, "plot%d" % (ready + 1), PRESS, func():
					var s: SeedDef = plots[ready].seed
					a.product_value = s.sale_value_per_unit * s.yield_amount
					plots[ready].seed = null
					plots[ready].ready = false
					plots[ready].reserved = -1
					a.holding = "product")
				continue
			if thirsty >= 0:
				var can := _free_can(cans, a)
				if can != null:
					plots[thirsty].reserved = -1 # re-picked once the can is in hand
					can.reserved = a.id
					_walk_to(a, can.pos, PRESS, func():
						can.holder = a.id
						can.reserved = -1
						a.can = can
						a.holding = "can")
					continue
			var empty := _find_plot(plots, a, func(p: Plot) -> bool: return p.seed == null)
			var seed := _choose_seed(strat, int(st["money"]) - int(st["reserved"]))
			if empty >= 0 and seed != null:
				st["reserved"] += seed.cost
				_go(a, "shop", BUY, func():
					st["reserved"] -= seed.cost
					st["money"] -= seed.cost
					a.packet = seed
					a.holding = "packet"
					plots[empty].reserved = -1)
				continue
			if empty >= 0:
				plots[empty].reserved = -1
		t += DT
		if int(st["sales"]) >= quota:
			break
	var result := [t if int(st["sales"]) >= quota else -1.0, int(st["sales"])]
	for a in agents:
		a.plan.clear() # break Agent <-> lambda reference cycles
		a.can = null
	return result

## Nearest unreserved plot matching `pred`, reserved for `a` (-1 if none).
func _find_plot(plots: Array[Plot], a: Agent, pred: Callable) -> int:
	var best := -1
	var best_d := INF
	for i in plots.size():
		var p := plots[i]
		if (p.reserved != -1 and p.reserved != a.id) or not bool(pred.call(p)):
			continue
		var d := a.pos.distance_to(points["plot%d" % (i + 1)])
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		plots[best].reserved = a.id
	return best

func _free_can(cans: Array[Can], a: Agent) -> Can:
	var best: Can = null
	for c in cans:
		if c.holder == -1 and c.reserved == -1 and (best == null or a.pos.distance_to(c.pos) < a.pos.distance_to(best.pos)):
			best = c
	return best

func _go(a: Agent, point: String, action_time: float, done: Callable) -> void:
	_walk_to(a, points[point], action_time, done)

func _walk_to(a: Agent, to: Vector2, action_time: float, done: Callable) -> void:
	var d := a.pos.distance_to(to)
	a.busy = (d / b.sprint_speed + LEG_OVERHEAD if d > 0.3 else 0.0) + action_time
	a.pos = to
	a.plan.append(done)
