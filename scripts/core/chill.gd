class_name Chill
extends RefCounted
## The chill preset (2026-10-10). The user asked for the game to be "simpler and chill": fewer kinds of trouble, less
## often and gentler, fewer things to keep track of, a payment a crew can make. Config applies it once at start-up
## to Config.balance when Config.chill_enabled (on in a windowed run, off under --headless so the suites keep testing
## the full game; `--chill` / `--no-chill` force it). Every number here is a BalanceConfig field: the full game's
## values stay in data/balance.tres, this file only overrides them. The `chill` suite pins it.

## The event mix: the trouble the user asked for (the power going out, the leak, the rival crew shooting), the silly
## kind (the rat, the phone, the sprinklers) and the Boss walking the floor. Every other kind is off (weight 0).
const EVENT_WEIGHTS: Dictionary = {
	&"inspection": 15,
	&"power_cut": 20,
	&"leak": 15,
	&"driveby": 10,
	&"rat": 15,
	&"phone": 10,
	&"sprinklers": 15,
}

## BalanceConfig field -> the chill value.
const VALUES: Dictionary = {
	# Trouble comes less often and does not speed up through a run.
	&"event_first_delay_sec": 60.0,
	&"event_gap_min_sec": 75.0,
	&"event_gap_max_sec": 140.0,
	&"event_gap_shrink_per_round": 0.0,
	# Gentler when it goes wrong.
	&"backroom_sec": 15.0,
	&"write_up_fine": 10,
	&"driveby_fine": 0,
	&"hostile_max": 1,
	&"spore_fog_sec": 6.0,
	# Fewer things to keep track of: no market, conditions from the third shift and never two at once.
	&"market_swing": 0.0,
	&"conditions_from_round": 3,
	&"conditions_extra_from_round": 99,
	# A payment a crew can make.
	&"quota_multiplier": 0.85,
}

## Every strain's chance to get up and walk is multiplied by this.
const MUTATION_SCALE := 0.5


## Overrides `b`'s fields with the chill values (in place; the loaded resource is shared, as --fast does).
static func apply(b: BalanceConfig) -> void:
	if b == null:
		return
	for key: StringName in VALUES:
		if key in b:
			b.set(key, VALUES[key])
		else:
			push_warning("Chill: BalanceConfig has no field '%s'" % key)
	for s: SeedDef in b.seeds:
		if s != null:
			s.mutation_chance *= MUTATION_SCALE


## The scheduler's base weight of `kind` in the chill mix (0 = never).
static func get_event_weight(kind: StringName) -> int:
	return int(EVENT_WEIGHTS.get(kind, 0))
