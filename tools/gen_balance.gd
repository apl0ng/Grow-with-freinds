extends SceneTree
## Regenerates res://data/balance.tres from code. Run:
##   godot --headless --path . -s res://tools/gen_balance.gd
## Only needed if you want to reset the balance file; normally edit the .tres in the editor.

func _init() -> void:
	var b := BalanceConfig.new()
	b.seeds = [
		# M14 loop: one trait per strain (CONTRACTS "M14", Loop), passed as SeedDef property values; Budget Bud has none.
		# M15: the last argument is the shift the strain is first sold in (SeedDef.unlock_round, read with replay on).
		# M15 economy (tools/tests/econ_sim.gd): Purple Haze 130 -> 140 a unit, Golden Kush 120 -> 125 a unit.
		_seed(&"budget", "Budget Bud", "Cheap. Grows fast. Pays little.", 20, 1.0, 1, 60, Color(0.55, 0.85, 0.35), 0.0),
		_seed(&"purple", "Purple Haze", "Slower. Pays better. The Boss prefers it.", 45, 1.3, 1, 140, Color(0.7, 0.45, 0.9), 0.05,
				{"thirst_multiplier": 1.6, "trait_text": "Thirsty."}),
		_seed(&"golden", "Golden Kush", "Long grow. Double yield. He counts these.", 90, 1.6, 2, 125, Color(1.0, 0.8, 0.25), 0.1,
				{"counted": true, "trait_text": "Counted."}, 2),
		# M12 strains: the mutation chance is rolled once when the plant becomes READY (CONTRACTS "M12").
		_seed(&"nightshift", "Night Shift", "Dark. Pays the most. One in three gets up and leaves the tray.", 70, 1.2, 1, 210, Color(0.36, 0.2, 0.56), 0.35,
				{"dark_growth_multiplier": 2.0, "trait_text": "Grows in the dark."}, 3),
		_seed(&"creeper", "Creeper", "Cheap. Quick. It twitches. Some of them walk.", 30, 0.8, 1, 70, Color(0.2, 0.72, 0.64), 0.12,
				{"spread_chance": 0.33, "trait_text": "Spreads."}),
		_seed(&"brick", "Floor Brick", "Slow. Heavy. Three units a plant. One in five walks off with them.", 120, 2.0, 3, 110, Color(0.72, 0.36, 0.2), 0.2,
				{"heavy": true, "trait_text": "Heavy."}, 4),
		# M18 spores: a READY tray puffs a spore cloud when it is disturbed (scripts/core/spores.gd); a small mutation chance.
		_seed(&"damp", "Black Damp", "Slow. Pays well. Disturb a ripe tray and you breathe it.", 80, 1.8, 1, 245, Color(0.26, 0.29, 0.22), 0.05,
				{"spores": true, "trait_text": "Spores."}, 3),
	]
	b.upgrades = [
		_upgrade(&"fertilizer", "Cheap Fertilizer", "Plants grow 25% faster per level. Don't ask what's in it.", 150, 1.6, 3, Const.EFFECT_GROWTH_SPEED, 0.25),
		_upgrade(&"big_can", "Dented Cans", "+2 charges on every can per level. They leak a little.", 80, 1.5, 2, Const.EFFECT_CAN_CAPACITY, 2.0),
		_upgrade(&"sweet_talk", "Better Cut", "Deposits pay 10% more per level. He keeps the rest.", 200, 1.7, 3, Const.EFFECT_SALE_BONUS, 0.10),
	]
	# M15 economy: the payment due for ten trays and cured bundles, and a cure that takes long enough for the six hooks
	# to be a choice. Numbers from tools/tests/econ_sim.gd, pinned by tools/tests/economy_body.gd.
	# M18 economy2: the solo curve is 350, x1.82 + 500 a shift (350 / 1137 / 2159 / 3610 / 5840 / 9489; M15 to M17 had
	# + 688): a careful worker alone clears the four-shift run about half the time. A team pays 1 + a(shift) x m(size):
	# a by shift rises to shift 3 and falls after it (a full crew is strongest against the payment in the middle of a
	# run), m for two / three / four workers grows slower than the team (ten trays saturate at about three workers).
	b.base_quota = 350
	b.quota_scale = 1.82
	b.quota_add = 500
	b.quota_per_extra_player = 0.1
	b.quota_team_by_shift = [0.4, 0.75, 1.1, 0.85, 0.6, 0.35]
	b.quota_team_by_size = [1.0, 1.05, 1.15]
	b.cure_sec = 45.0
	var err := ResourceSaver.save(b, "res://data/balance.tres")
	print("balance.tres saved: ", error_string(err))
	quit(0 if err == OK else 1)

func _seed(id: StringName, name: String, desc: String, cost: int, mult: float, yield_amount: int, value: int, color: Color,
		mutation: float = 0.0, traits: Dictionary = {}, unlock_round: int = 1) -> SeedDef:
	var s := SeedDef.new()
	s.id = id
	s.display_name = name
	s.description = desc
	s.cost = cost
	s.grow_time_multiplier = mult
	s.yield_amount = yield_amount
	s.sale_value_per_unit = value
	s.color = color
	s.mutation_chance = mutation
	for key: String in traits: # M14 loop: thirst_multiplier, dark_growth_multiplier, spread_chance, heavy, counted, trait_text
		s.set(key, traits[key])
	s.unlock_round = unlock_round
	s.resource_name = name
	return s

func _upgrade(id: StringName, name: String, desc: String, cost: int, scale: float, max_level: int, key: StringName, per_level: float) -> UpgradeDef:
	var u := UpgradeDef.new()
	u.id = id
	u.display_name = name
	u.description = desc
	u.base_cost = cost
	u.cost_scale = scale
	u.max_level = max_level
	u.effect_key = key
	u.effect_per_level = per_level
	u.resource_name = name
	return u
