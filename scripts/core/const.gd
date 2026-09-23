extends Node
## Autoload "Const": shared constants (collision layers, groups, item types).
## Do NOT add a class_name here (autoload names must not collide with class names).

# --- Collision layers (bit values, use with collision_layer / collision_mask) ---
const LAYER_WORLD: int = 1        # layer 1: static room geometry
const LAYER_PLAYER: int = 2       # layer 2: player bodies
const LAYER_INTERACTABLE: int = 4 # layer 3: station colliders that the interaction ray hits
const LAYER_ITEM: int = 8         # layer 4: carryable item colliders (also hit by the interaction ray)

# --- Node groups ---
const GROUP_PLAYERS: StringName = &"players"
const GROUP_INTERACTABLES: StringName = &"interactables"
const GROUP_ITEMS: StringName = &"items"
const GROUP_GROW_PLOTS: StringName = &"grow_plots"

# --- Item types (Item.item_type) ---
const ITEM_WATERING_CAN: StringName = &"watering_can"
const ITEM_SEED_PACKET: StringName = &"seed_packet"
const ITEM_PRODUCT: StringName = &"product"

# --- Upgrade effect keys (UpgradeDef.effect_key) ---
const EFFECT_GROWTH_SPEED: StringName = &"growth_speed"   # multiplier bonus: growth rate *= 1 + total
const EFFECT_CAN_CAPACITY: StringName = &"can_capacity"   # flat bonus charges on watering cans
const EFFECT_SALE_BONUS: StringName = &"sale_bonus"       # multiplier bonus on sale value
const EFFECT_WATER_RETENTION: StringName = &"water_retention" # multiplier bonus: drain rate /= 1 + total

# --- Networking ---
const SERVER_PEER_ID: int = 1
