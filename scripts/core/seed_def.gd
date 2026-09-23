class_name SeedDef
extends Resource
## One purchasable seed strain. Instances live inside res://data/balance.tres.

@export var id: StringName = &"seed"
@export var display_name: String = "Seed"
@export_multiline var description: String = ""
@export var cost: int = 20
## Multiplies every growth stage duration (1.0 = base stage_durations from BalanceConfig).
@export var grow_time_multiplier: float = 1.0
## Units of product one plant yields at harvest.
@export var yield_amount: int = 1
## Sale value per unit of product (before upgrades).
@export var sale_value_per_unit: int = 60
## Tint used for the seed packet, plant buds and product visuals.
@export var color: Color = Color(0.4, 0.8, 0.3)
