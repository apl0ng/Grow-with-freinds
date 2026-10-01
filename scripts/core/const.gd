extends Node
## Autoload "Const": shared constants (collision layers, groups, item types).
## Do NOT add a class_name here (autoload names must not collide with class names).

# --- Collision layers (bit values, use with collision_layer / collision_mask) ---
const LAYER_WORLD: int = 1        # layer 1: static room geometry
const LAYER_PLAYER: int = 2       # layer 2: player bodies (M10: players also collide with each other)
const LAYER_INTERACTABLE: int = 4 # layer 3: station colliders that the interaction ray hits
const LAYER_ITEM: int = 8         # layer 4: carryable item colliders (also hit by the interaction ray)

# --- Node groups ---
const GROUP_PLAYERS: StringName = &"players"
const GROUP_INTERACTABLES: StringName = &"interactables"
const GROUP_ITEMS: StringName = &"items"
const GROUP_GROW_PLOTS: StringName = &"grow_plots"
const GROUP_NPCS: StringName = &"npcs"            # M10: the Boss, the rat (things that walk the floor)
const GROUP_HOSTILES: StringName = &"hostiles"    # M12: hostile plants (children of World/Hostiles; also in GROUP_NPCS)

# --- Item types (Item.item_type) ---
const ITEM_WATERING_CAN: StringName = &"watering_can"
const ITEM_SEED_PACKET: StringName = &"seed_packet"
const ITEM_PRODUCT: StringName = &"product"
const ITEM_FLAMETHROWER: StringName = &"flamethrower"   # M12: the emergency cabinet's weapon, props {"fuel": float, "firing": bool}

# --- Upgrade effect keys (UpgradeDef.effect_key) ---
const EFFECT_GROWTH_SPEED: StringName = &"growth_speed"   # multiplier bonus: growth rate *= 1 + total
const EFFECT_CAN_CAPACITY: StringName = &"can_capacity"   # flat bonus charges on watering cans
const EFFECT_SALE_BONUS: StringName = &"sale_bonus"       # multiplier bonus on sale value
const EFFECT_WATER_RETENTION: StringName = &"water_retention" # multiplier bonus: drain rate /= 1 + total

# --- M10: per-worker shift stat keys (GameState.stats) ---
const STAT_DEPOSITED: StringName = &"deposited"   # $ deposited this shift (GameState counts it on every sale)
const STAT_PLANTED: StringName = &"planted"
const STAT_WATERED: StringName = &"watered"
const STAT_HARVESTED: StringName = &"harvested"
const STAT_WRITE_UPS: StringName = &"write_ups"   # write-ups received this shift (never cleared by the back room)
const STAT_THROWS: StringName = &"throws"
const STAT_HITS: StringName = &"hits"             # thrown items that hit a worker
const STAT_SHOVES: StringName = &"shoves"
const STAT_PINGS: StringName = &"pings"
const STAT_BITTEN: StringName = &"bitten"         # M12: bites taken from a hostile plant
const STAT_SCORCHED: StringName = &"scorched"     # M12: crops this worker burnt with the flamethrower
const STAT_BURNS: StringName = &"burns"           # M12: hostile plants this worker burnt down

# --- M10: write-up reasons (GameState.server_write_up) ---
const WRITE_UP_SKIMMING: String = "skimming"     # carrying product in the Boss's sight
const WRITE_UP_LOITERING: String = "loitering"   # standing still in the Boss's sight
const WRITE_UP_OTHER: String = "other"
const WRITE_UP_ARSON: String = "arson"           # M12: burnt a crop or a worker with no hostile plant near
const WRITE_UP_MISUSE: String = "misuse"         # M12: broke the emergency cabinet with nothing on the floor
const WRITE_UP_ABSENT: String = "absent"         # M12: missed the head count

# --- M10: UI lock source used while a worker sits in the back room (Game.set_ui_lock) ---
const UI_LOCK_BACKROOM: StringName = &"backroom"

# --- Networking ---
const SERVER_PEER_ID: int = 1
