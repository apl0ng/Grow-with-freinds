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
## M12: chance (0..1) that this strain turns hostile when it becomes ready (rolled once per plant).
@export_range(0.0, 1.0) var mutation_chance: float = 0.0

@export_group("Traits (M14)")
## Water drains this many times faster (Purple Haze: thirsty).
@export var thirst_multiplier: float = 1.0
## Growth speed factor while the power is off; 0 = frozen like every other strain (Night Shift: grows in the dark).
@export var dark_growth_multiplier: float = 0.0
## Chance (0..1) that a harvest leaves a watered seedling of this strain in the tray (Creeper: spreads).
@export_range(0.0, 1.0) var spread_chance: float = 0.0
## The bundle is heavy: its carrier walks slower and cannot sprint (Floor Brick).
@export var heavy: bool = false
## The Boss counts these: a plant lost to the hostile plant, fire or gunfire costs the floor a fine (Golden Kush).
@export var counted: bool = false
## One or two words for the supply card ("Thirsty.", "Heavy."); "" = no trait.
@export var trait_text: String = ""
## M15: the first shift this strain is sold in (1 = always; a locked card reads "From shift N"). Only with replay on.
@export var unlock_round: int = 1

# --- M18 spores ---
@export_group("Spores (M18)")
## A READY tray puffs a spore cloud when it is harvested, uprooted, burnt, shot or hit by a thrown item; whoever breathes
## it is fogged for a while (Black Damp; scripts/core/spores.gd).
@export var spores: bool = false
# --- end M18 spores ---
