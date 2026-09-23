extends SceneTree
## Regenerates res://data/balance.tres from code. Run:
##   godot --headless --path . -s res://tools/gen_balance.gd
## Only needed if you want to reset the balance file; normally edit the .tres in the editor.

func _init() -> void:
	var b := BalanceConfig.new()
	b.seeds = [
		_seed(&"budget", "Budget Bud", "Cheap. Grows fast. Pays little.", 20, 1.0, 1, 60, Color(0.55, 0.85, 0.35)),
		_seed(&"purple", "Purple Haze", "Slower. Pays better. The Boss prefers it.", 45, 1.3, 1, 130, Color(0.7, 0.45, 0.9)),
		_seed(&"golden", "Golden Kush", "Long grow. Double yield. He counts these.", 90, 1.6, 2, 120, Color(1.0, 0.8, 0.25)),
	]
	b.upgrades = [
		_upgrade(&"fertilizer", "Cheap Fertilizer", "Plants grow 25% faster per level. Don't ask what's in it.", 150, 1.6, 3, Const.EFFECT_GROWTH_SPEED, 0.25),
		_upgrade(&"big_can", "Dented Cans", "+2 charges on every can per level. They leak a little.", 80, 1.5, 2, Const.EFFECT_CAN_CAPACITY, 2.0),
		_upgrade(&"sweet_talk", "Better Cut", "Deposits pay 10% more per level. He keeps the rest.", 200, 1.7, 3, Const.EFFECT_SALE_BONUS, 0.10),
	]
	var err := ResourceSaver.save(b, "res://data/balance.tres")
	print("balance.tres saved: ", error_string(err))
	quit(0 if err == OK else 1)

func _seed(id: StringName, name: String, desc: String, cost: int, mult: float, yield_amount: int, value: int, color: Color) -> SeedDef:
	var s := SeedDef.new()
	s.id = id
	s.display_name = name
	s.description = desc
	s.cost = cost
	s.grow_time_multiplier = mult
	s.yield_amount = yield_amount
	s.sale_value_per_unit = value
	s.color = color
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
