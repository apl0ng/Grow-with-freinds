class_name Chill
extends RefCounted
## The chill preset (2026-10-10). The user asked for the game to be "simpler and chill": fewer kinds of trouble, less
## often and gentler, fewer things to keep track of, a payment a crew can make. Config applies it once at start-up
## to Config.balance when Config.chill_enabled (on in a windowed run, off under --headless so the suites keep testing
## the full game; `--chill` / `--no-chill` force it). Every number here is a BalanceConfig field: the full game's
## values stay in data/balance.tres, this file only overrides them. The `chill` suite pins it.
## M23 (the user, twice: "make the game more simple"): four strains instead of seven, no shift conditions, and the
## final notice's half-time look raises nothing.
## M24 (the curve): the payment due is a share of the full game's that depends on the shift (QUOTA_SHIFT_SCALE)
## instead of a flat 85%, so average crews of one and two reach their final notice too.

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

## M23: the strains the chill game does not sell (BalanceConfig.disabled_strains): Creeper (it spreads and walks),
## Floor Brick (heavy, slow to carry) and Black Damp (spores). Four are left to learn: Budget Bud, Purple Haze, Golden
## Kush (from shift 2) and Night Shift (from shift 3: the plant that gets up and walks stays in the chill game).
const DISABLED_STRAINS: Array[StringName] = [&"creeper", &"brick", &"damp"]

## M24: the payment due by shift, as a share of the full game's (BalanceConfig.quota_shift_scale; shifts past the end
## use the last value). Chosen with the economy model (tools/tests/econ_sim.gd; the chill suite pins the payments and
## the outcome): the first shift is small enough for a sloppy crew to make (a heavier one bought nothing in the model);
## the second is the gentlest, because a first shift paid early leaves little growing for it; from the third the floor
## is full. Average crews of every size clear their run in the model with room to spare (a crew 12% quicker or 6%
## slower still clears 5 of 5), and every payment is still higher than the one before it.
const QUOTA_SHIFT_SCALE: Array[float] = [0.48, 0.45, 0.56, 0.52, 0.52, 0.69]

## BalanceConfig field -> the chill value. A typed array field takes its value element by element (apply()).
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
	# M23 social: the angry plant's bite keeps a worker down long enough for a friend to help them up (E). It cannot bite
	# a worker who is down: its next bite waits for the stagger immunity (the stun + 1 s), and after two it calms down.
	&"hostile_bite_stun_sec": 2.0,
	&"spore_fog_sec": 6.0,
	# Fewer things to keep track of: no market, no shift conditions (M23: none at all, so no chips and no board lines
	# for them; the two below only matter if conditions come back), four strains.
	&"market_swing": 0.0,
	&"conditions_from_round": 99,
	&"conditions_extra_from_round": 99,
	&"final_conditions": 1,
	&"disabled_strains": DISABLED_STRAINS,
	# The final notice: the Boss still looks in at half time, but nothing goes up (the line is "Half the clock.").
	&"final_interim_raise": 0.0,
	# A payment a crew can make (M24: shaped by shift; the multiplier stays 1, the whole curve is the shift scale).
	&"quota_multiplier": 1.0,
	&"quota_shift_scale": QUOTA_SHIFT_SCALE,
}

## Every strain's chance to get up and walk is multiplied by this.
const MUTATION_SCALE := 0.5


## Overrides `b`'s fields with the chill values (in place; the loaded resource is shared, as --fast does).
static func apply(b: BalanceConfig) -> void:
	if b == null:
		return
	for key: StringName in VALUES:
		if not key in b:
			push_warning("Chill: BalanceConfig has no field '%s'" % key)
			continue
		var current: Variant = b.get(key)
		if current is Array:
			# A typed array field (disabled_strains: Array[StringName]) refuses a plain Array: a copy of the field
			# keeps its element type, assign() converts the preset's elements into it.
			var typed: Array = (current as Array).duplicate()
			typed.assign(VALUES[key])
			b.set(key, typed)
		else:
			b.set(key, VALUES[key])
	for s: SeedDef in b.seeds:
		if s != null:
			s.mutation_chance *= MUTATION_SCALE


## The scheduler's base weight of `kind` in the chill mix (0 = never).
static func get_event_weight(kind: StringName) -> int:
	return int(EVENT_WEIGHTS.get(kind, 0))
