class_name UpgradeDef
extends Resource
## One purchasable team upgrade. Instances live inside res://data/balance.tres.
## Effects are applied through GameState.get_effect_total(effect_key).

@export var id: StringName = &"upgrade"
@export var display_name: String = "Upgrade"
@export_multiline var description: String = ""
@export var base_cost: int = 100
## Cost of level n = round(base_cost * cost_scale ^ (n - 1))
@export var cost_scale: float = 1.6
@export var max_level: int = 3
## One of the Const.EFFECT_* keys.
@export var effect_key: StringName = &"growth_speed"
## Added to the effect total per level owned.
@export var effect_per_level: float = 0.25

func cost_for_level(level: int) -> int:
	return int(round(base_cost * pow(cost_scale, max(level - 1, 0))))
