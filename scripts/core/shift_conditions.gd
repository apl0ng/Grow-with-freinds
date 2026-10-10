class_name ShiftConditions
extends RefCounted
## Shift conditions (M15 replay agent; FRIENDSLOP.md 9.1, CONTRACTS.md "M15", "Replay"): the catalog of what can be
## different today, and the dice. Data and pure functions only: GameState owns the state (which conditions run, the
## market), rolls on the host, syncs, and answers `GameState.condition_value(key, default)` for the consumers.
##
## A condition has an id, a short title for the HUD chip (two or three words), one flat line for the alley board and
## the toast at shift start, and effect keys with values. An id may carry a parameter after a colon: `buyer:purple`
## is the buyer condition for Purple Haze (the strain is rolled among those sold that shift).
##
## EFFECT KEYS. Every key is a multiplier (the active conditions' values are MULTIPLIED) unless marked additive (the
## values are SUMMED). A consumer reads `GameState.condition_value(key, default)` and gets `default` when no active
## condition has the key.
##   water_drain            x  tray water drain per second                         (GrowPlot.tick)
##   growth_speed           x  growth speed of every tray                          (GameState.get_growth_speed_multiplier)
##   mutation_chance        x  a ready plant's chance to turn hostile, capped at mutation_chance_cap (GrowPlot.get_mutation_chance) # M16 polish
##   dark_growth            x  growth of a grows-in-the-dark strain in a power cut (GrowPlot.tick)
##   seed_cost              x  the price of every seed packet, shown and charged   (GameState.get_seed_cost)
##   sale_value             x  the deposit value of every strain                   (GameState.get_deposit_factor)
##   sale_value:<strain_id> x  the deposit value of one strain                     (GameState.get_deposit_factor)
##   cure_bonus             x  the cure bonus itself (2 = a cured bundle's extra is doubled) (GameState.get_deposit_factor)
##   event_weight:<kind>    x  the scheduler's weight of one event kind, by name   (Events.get_weight)
##   event_gap              x  seconds between events and before the first one     (GameState.get_event_gap_factor)
##   power_cut_sec          x  how long a power cut lasts when nobody resets it    (Events.server_start_event)
##   quota                  x  the payment due, applied when the shift starts      (GameState._replay_begin_shift)
##   round_sec_add          +  seconds added to the shift's length (additive)      (GameState._replay_begin_shift)
##   floor_wet              +  a flag: above 0 the whole floor is wet (additive)   (Events, the slip judge)
## Keys with a suffix (`sale_value:`, `event_weight:`) are looked up by name, so they work for strains and event kinds
## this file has never heard of.

## Keys without a suffix -> true when additive.
const KEYS: Dictionary = {
	&"water_drain": false,
	&"growth_speed": false,
	&"mutation_chance": false,
	&"dark_growth": false,
	&"seed_cost": false,
	&"sale_value": false,
	&"cure_bonus": false,
	&"event_gap": false,
	&"power_cut_sec": false,
	&"quota": false,
	&"round_sec_add": true,
	&"floor_wet": true,
}
## Keys that take a `:<name>` suffix (all multipliers).
const SUFFIX_KEYS: Array[StringName] = [&"sale_value", &"event_weight"]

## From this shift on one more condition is rolled than BalanceConfig.conditions_per_shift ("two from shift five").
const EXTRA_FROM_ROUND: int = 5
## The market moves in steps of 1 / MARKET_STEPS_PER_UNIT (5%).
const MARKET_STEPS_PER_UNIT: int = 20
const MARKET_STEP: float = 1.0 / MARKET_STEPS_PER_UNIT

const ID_DRY_AIR: StringName = &"dry_air"
const ID_TWITCHY: StringName = &"twitchy"
const ID_BUYER: StringName = &"buyer"
const ID_CLEARANCE: StringName = &"clearance"
const ID_INSPECTION_WEEK: StringName = &"inspection_week"
const ID_BAD_WIRING: StringName = &"bad_wiring"
const ID_SHORT_CLOCK: StringName = &"short_clock"
const ID_OVERTIME: StringName = &"overtime"
const ID_SLICK_FLOOR: StringName = &"slick_floor"
const ID_THIN_WALLS: StringName = &"thin_walls"
const ID_HEAT_WAVE: StringName = &"heat_wave"
const ID_QUIET_NIGHT: StringName = &"quiet_night"
const ID_CURED_ORDER: StringName = &"cured_order"

## The catalog. "title": the chip. "line": the board and the toast. "effects": key -> value. "strain_effects": key ->
## value applied to the id's strain parameter as `key:<strain>` ("title" and "line" then take the strain's name as %s).
## "events": true when the condition only matters while random events are scheduled (it is not rolled otherwise).
## "mutating": true when it needs a strain on sale that can turn hostile.
const CATALOG: Dictionary = {
	ID_DRY_AIR: {
		"title": "Dry air",
		"line": "Dry air. Trays dry half again as fast.",
		"effects": {&"water_drain": 1.5},
	},
	ID_TWITCHY: {
		"title": "Twitchy batch",
		"line": "A twitchy batch. More of them get up and walk.",
		"effects": {&"mutation_chance": 2.0},
		"mutating": true,
	},
	ID_BUYER: {
		"title": "%s buyer",
		"line": "A buyer wants %s. It deposits for half again.",
		"effects": {},
		"strain_effects": {&"sale_value": 1.5},
	},
	ID_CLEARANCE: {
		"title": "Seed clearance",
		"line": "Clearance at the window. Seeds are 30% off.",
		"effects": {&"seed_cost": 0.7},
	},
	ID_INSPECTION_WEEK: {
		"title": "Inspection week",
		"line": "Inspection week. The Boss walks the floor twice as often.",
		"effects": {&"event_weight:inspection": 2.0},
		"events": true,
	},
	ID_BAD_WIRING: {
		"title": "Bad wiring",
		"line": "Bad wiring. Power cuts come twice as often and last twice as long. Night Shift likes it.",
		"effects": {&"power_cut_sec": 2.0, &"event_weight:power_cut": 2.0, &"dark_growth": 1.5},
		"events": true,
	},
	ID_SHORT_CLOCK: {
		"title": "Short clock",
		"line": "A short clock. Forty seconds less. 15% less due.",
		"effects": {&"round_sec_add": -40.0, &"quota": 0.85},
	},
	ID_OVERTIME: {
		"title": "Mandatory overtime",
		"line": "Overtime. Forty seconds more. 15% more due.",
		"effects": {&"round_sec_add": 40.0, &"quota": 1.15},
	},
	ID_SLICK_FLOOR: {
		"title": "Slick floor",
		"line": "The floor is wet all shift. Run and you fall.",
		"effects": {&"floor_wet": 1.0},
	},
	ID_THIN_WALLS: {
		"title": "Thin walls",
		"line": "Thin walls. Drive-bys are three times as likely.",
		"effects": {&"event_weight:driveby": 3.0},
		"events": true,
	},
	# The replay agent's own three.
	ID_HEAT_WAVE: {
		"title": "Heat wave",
		"line": "Heat wave. Everything grows a quarter faster and dries out 75% faster.",
		"effects": {&"growth_speed": 1.25, &"water_drain": 1.75},
	},
	ID_QUIET_NIGHT: {
		"title": "Quiet night",
		"line": "A quiet night. Less goes wrong. Everything deposits for 10% less.",
		"effects": {&"event_gap": 1.8, &"sale_value": 0.9},
		"events": true,
	},
	ID_CURED_ORDER: {
		"title": "Cured order",
		"line": "An order for cured. The bonus for a cured bundle is doubled.",
		"effects": {&"cure_bonus": 2.0},
	},
}

## Pairs never rolled together: they cancel out (the two clocks), stack on one number until it is unfair (two kinds of
## thirst), or say opposite things on the board (a quiet night with more trouble).
const INCOMPATIBLE: Array = [
	[ID_SHORT_CLOCK, ID_OVERTIME],
	[ID_DRY_AIR, ID_HEAT_WAVE],
	[ID_QUIET_NIGHT, ID_INSPECTION_WEEK],
	[ID_QUIET_NIGHT, ID_THIN_WALLS],
	[ID_QUIET_NIGHT, ID_BAD_WIRING],
]


# --- ids ----------------------------------------------------------------------------------------------------------

## The catalog's ids (without parameters), in catalog order.
static func get_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in CATALOG:
		out.append(id)
	return out


## `buyer:purple` -> `buyer`; an id without a parameter is its own base.
static func base_of(id: StringName) -> StringName:
	var text := String(id)
	var colon := text.find(":")
	return id if colon < 0 else StringName(text.substr(0, colon))


## `buyer:purple` -> `purple`; &"" without a parameter.
static func param_of(id: StringName) -> StringName:
	var text := String(id)
	var colon := text.find(":")
	return &"" if colon < 0 else StringName(text.substr(colon + 1))


static func make_id(base: StringName, param: StringName = &"") -> StringName:
	return base if param == &"" else StringName("%s:%s" % [base, param])


## True when `id` names a condition of the catalog. A condition with strain effects needs its parameter; one without
## must not carry any.
static func has(id: StringName) -> bool:
	var entry: Variant = CATALOG.get(base_of(id))
	if not entry is Dictionary:
		return false
	return (param_of(id) != &"") == (entry as Dictionary).has("strain_effects")


static func needs_events(id: StringName) -> bool:
	return bool(_entry(id).get("events", false))


static func needs_mutating(id: StringName) -> bool:
	return bool(_entry(id).get("mutating", false))


static func takes_strain(id: StringName) -> bool:
	return _entry(id).has("strain_effects")


# --- copy ---------------------------------------------------------------------------------------------------------

## The chip: two or three words ("Dry air", "Purple Haze buyer").
static func get_title(id: StringName) -> String:
	return _with_param(String(_entry(id).get("title", "")), id)


## One flat line for the board and the toast.
static func get_line(id: StringName) -> String:
	return _with_param(String(_entry(id).get("line", "")), id)


# --- effects ------------------------------------------------------------------------------------------------------

## The effect keys of one condition -> value (`buyer:purple` -> {sale_value:purple: 1.5}).
static func get_effects(id: StringName) -> Dictionary:
	var entry := _entry(id)
	var out: Dictionary = {}
	var plain: Dictionary = entry.get("effects", {})
	for key: StringName in plain:
		out[key] = float(plain[key])
	var param := param_of(id)
	if param != &"" and entry.has("strain_effects"):
		var per_strain: Dictionary = entry["strain_effects"]
		for key: StringName in per_strain:
			out[StringName("%s:%s" % [key, param])] = float(per_strain[key])
	return out


## True for a key whose values are summed (`round_sec_add`, `floor_wet`); every other key is a multiplier.
static func is_additive(key: StringName) -> bool:
	return bool(KEYS.get(_key_base(key), false))


## True for a key a consumer reads: a plain key of KEYS, or a suffix key with a name after the colon.
static func is_known_key(key: StringName) -> bool:
	var text := String(key)
	var colon := text.find(":")
	if colon < 0:
		return KEYS.has(key)
	return SUFFIX_KEYS.has(StringName(text.substr(0, colon))) and colon < text.length() - 1


## Every key of the conditions `ids` -> the product of its values (the sum for an additive key).
static func combine(ids: Array) -> Dictionary:
	var out: Dictionary = {}
	for raw: Variant in ids:
		var effects := get_effects(StringName(str(raw)))
		for key: StringName in effects:
			var value := float(effects[key])
			if not out.has(key):
				out[key] = value
			elif is_additive(key):
				out[key] = float(out[key]) + value
			else:
				out[key] = float(out[key]) * value
	return out


# --- the dice -----------------------------------------------------------------------------------------------------

static func are_compatible(a: StringName, b: StringName) -> bool:
	var base_a := base_of(a)
	var base_b := base_of(b)
	if base_a == base_b:
		return false
	for pair: Array in INCOMPATIBLE:
		if (pair[0] == base_a and pair[1] == base_b) or (pair[0] == base_b and pair[1] == base_a):
			return false
	return true


## How many conditions shift `round_n` gets: none before `from_round`, `per_shift` from there, one more from
## EXTRA_FROM_ROUND.
static func count_for_round(round_n: int, from_round: int, per_shift: int, extra_from: int = EXTRA_FROM_ROUND) -> int:
	if round_n < maxi(from_round, 1) or per_shift <= 0:
		return 0
	return per_shift + (1 if round_n >= extra_from else 0)  # M20 chill: extra_from (BalanceConfig.conditions_extra_from_round)


## Rolls `count` conditions. Never one of `previous` (the shift before: compared without parameters), never an
## incompatible pair, never one that would do nothing today: `events_on` false leaves out the conditions that only
## change events, an empty `strains` (the ids on sale this shift) leaves out the buyer, `mutating` false leaves out
## the twitchy batch. Fewer than `count` come back when the pool runs dry.
static func roll(count: int, previous: Array, rng: RandomNumberGenerator, events_on: bool, strains: Array,
		mutating: bool) -> Array[StringName]:
	var out: Array[StringName] = []
	var blocked: Dictionary = {}
	for raw: Variant in previous:
		blocked[base_of(StringName(str(raw)))] = true
	var pool: Array[StringName] = []
	for id: StringName in CATALOG:
		if blocked.has(id):
			continue
		if needs_events(id) and not events_on:
			continue
		if needs_mutating(id) and not mutating:
			continue
		if takes_strain(id) and strains.is_empty():
			continue
		pool.append(id)
	while out.size() < count and not pool.is_empty():
		var pick: StringName = pool[rng.randi_range(0, pool.size() - 1)]
		var kept: Array[StringName] = []
		for other in pool:
			if are_compatible(pick, other):
				kept.append(other)
		pool = kept
		if takes_strain(pick):
			pick = make_id(pick, StringName(str(strains[rng.randi_range(0, strains.size() - 1)])))
		out.append(pick)
	return out


## One market: every strain of `strain_ids` -> a factor in 1 - swing .. 1 + swing in steps of MARKET_STEP. When every
## strain of `on_sale` came out below 1, the best of them is put back to 1: there is always something worth planting.
static func roll_market(rng: RandomNumberGenerator, swing: float, strain_ids: Array, on_sale: Array) -> Dictionary:
	var out: Dictionary = {}
	var steps := int(floor(maxf(swing, 0.0) * MARKET_STEPS_PER_UNIT + 0.0001))
	for raw: Variant in strain_ids:
		out[StringName(str(raw))] = float(MARKET_STEPS_PER_UNIT + rng.randi_range(-steps, steps)) / MARKET_STEPS_PER_UNIT
	var best: StringName = &""
	var best_value := -1.0
	for raw: Variant in on_sale:
		var id := StringName(str(raw))
		var value := float(out.get(id, 1.0))
		if value > best_value:
			best = id
			best_value = value
	if best != &"" and best_value < 1.0:
		out[best] = 1.0
	return out


## A market factor on the 5% grid, as the same double the literal has (1.15, not 1.1500000000000001), so what a peer
## computes from it rounds to the same dollar everywhere.
static func snap_market(value: float) -> float:
	return roundf(value * MARKET_STEPS_PER_UNIT) / MARKET_STEPS_PER_UNIT if is_finite(value) else 1.0


# --- internals ----------------------------------------------------------------------------------------------------

static func _entry(id: StringName) -> Dictionary:
	var entry: Variant = CATALOG.get(base_of(id))
	return entry if entry is Dictionary else {}


static func _key_base(key: StringName) -> StringName:
	var text := String(key)
	var colon := text.find(":")
	return key if colon < 0 else StringName(text.substr(0, colon))


## Fills a "%s" in a title or a line with the display name of the id's strain parameter.
static func _with_param(text: String, id: StringName) -> String:
	if not text.contains("%s"):
		return text
	var param := param_of(id)
	var def: SeedDef = Config.balance.get_seed(param) if param != &"" else null
	var shown := def.display_name if def != null else (String(param).capitalize() if param != &"" else "one strain")
	return text % shown
