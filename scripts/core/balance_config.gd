class_name BalanceConfig
extends Resource
## All tunable gameplay numbers in one place. The live instance is res://data/balance.tres,
## accessed everywhere through the Config autoload (Config.balance).

@export_group("Economy")
@export var starting_money: int = 150
@export var seeds: Array[SeedDef] = []
@export var upgrades: Array[UpgradeDef] = []

@export_group("Rounds & quota")
## Seconds per round.
@export var round_length_sec: float = 300.0
## Quota for round 1.
@export var base_quota: int = 350
## quota(n) = round(base_quota * quota_scale^(n-1) + quota_add * (n-1))
@export var quota_scale: float = 1.5
@export var quota_add: int = 150
## Quota multiplier per player beyond the first: quota *= 1 + quota_per_extra_player * (players - 1).
## Applied by GameState when a round starts (co-op scaling; 0 = same quota for any team size).
@export var quota_per_extra_player: float = 0.2
## If true the round ends (success) the moment sales reach the quota; otherwise it runs to the timer.
@export var end_round_on_quota_met: bool = true
## If true unspent money carries over to the next round.
@export var carry_over_money: bool = true

@export_group("Growth")
## Base seconds spent in each growing stage: [seedling, vegetative, flowering]. Multiplied by SeedDef.grow_time_multiplier.
@export var stage_durations: Array[float] = [20.0, 25.0, 30.0]
## Plot water level is 0..1. Drained per second while a plant is growing.
@export var water_drain_per_sec: float = 1.0 / 40.0
## Water level below which growth pauses (plant is "dry").
@export var dry_threshold: float = 0.05
## Water added to a plot per watering-can charge used.
@export var water_per_charge: float = 1.0

@export_group("Watering can")
@export var can_capacity: int = 4
## Number of watering cans spawned at the well when the game starts.
@export var starting_watering_cans: int = 2

@export_group("Player")
@export var walk_speed: float = 4.5
@export var sprint_speed: float = 7.0
@export var crouch_speed: float = 2.5
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.0025
@export var interact_distance: float = 3.0

@export_group("Discipline (M10)")
## Write-ups a worker can take in one shift before the Boss sends them to the back room.
@export var write_ups_to_backroom: int = 3
## Seconds a worker spends in the back room (input off, spectating).
@export var backroom_sec: float = 30.0
## Cash docked from the team on every write-up.
@export var write_up_fine: int = 25

@export_group("Events (M10)")
## Master switch for random shift events (inspections, power cuts, audits, rats).
@export var events_enabled: bool = true
## Seconds into a shift before the first event may start.
@export var event_first_delay_sec: float = 40.0
## Gap between the end of one event and the start of the next (random in this range).
@export var event_gap_min_sec: float = 45.0
@export var event_gap_max_sec: float = 90.0
## How long the Boss walks the floor.
@export var inspection_sec: float = 35.0
## Seconds in the Boss's sight before a standing worker is written up for loitering.
@export var loiter_sec: float = 3.0
## A power cut ends by itself after this long if nobody resets the fuse box.
@export var power_cut_max_sec: float = 40.0
## Seconds of holding E at the fuse box to reset it.
@export var fuse_reset_sec: float = 2.5
## An audit raises the payment due by this fraction.
@export var audit_raise_fraction: float = 0.1

@export_group("Physical (M10)")
## Launch speed of a thrown item (m/s).
@export var throw_speed: float = 9.0
## A thrown item within this distance of a worker's chest hits them.
@export var throw_hit_radius: float = 0.6
## Seconds a hit worker cannot move.
@export var hit_stun_sec: float = 0.5
## Shove: reach (m), horizontal impulse (m/s), stun (s) and per-shover cooldown (s).
@export var shove_range: float = 1.8
@export var shove_impulse: float = 5.5
@export var shove_stun_sec: float = 0.35
@export var shove_cooldown_sec: float = 0.8

@export_group("Voice (M10)")
## Distance at which a voice fades out (m).
@export var voice_range: float = 14.0
## Push-to-talk by default; false = open mic with an energy gate.
@export var voice_push_to_talk: bool = true

@export_group("Hostile plant (M12)")
## Seconds a ready plant twitches ("GrowPlot 3 is moving") before it uproots into a hostile plant.
@export var mutation_warning_sec: float = 6.0
## Hostile plant: walk speed (m/s), how far it senses a worker (m), bite stun (s) and per-bite cooldown (s).
@export var hostile_speed: float = 2.2
@export var hostile_sense_range: float = 5.0
@export var hostile_bite_stun_sec: float = 1.0
@export var hostile_bite_cooldown_sec: float = 1.5
## Stage progress a hostile plant eats from a growing plot per second.
@export var hostile_eat_per_sec: float = 0.08
## Seconds of flame that kill a hostile plant.
@export var hostile_burn_sec: float = 3.0
## At most this many hostile plants on the floor at once.
@export var hostile_max: int = 2

@export_group("Emergency cabinet (M12)")
## Cash taken as the equipment deposit when the glass is broken.
@export var cabinet_deposit: int = 40
## Seconds until the cabinet holds a new flamethrower after the glass was broken.
@export var cabinet_restock_sec: float = 90.0
## Flamethrower: seconds of fuel, reach (m), half-angle of the cone (degrees), seconds of flame that scorch a crop.
@export var flamethrower_fuel_sec: float = 8.0
@export var flamethrower_range: float = 3.5
@export var flamethrower_half_angle_deg: float = 25.0
@export var scorch_sec: float = 0.5

@export_group("Disruptions (M12)")
## Head count: seconds to reach the line and how close (m) counts as present.
@export var headcount_sec: float = 15.0
@export var headcount_radius: float = 2.5
## Water main off: seconds the well has no pressure.
@export var water_off_sec: float = 30.0
## Supply shortage: seconds one strain is out of stock at the counter.
@export var shortage_sec: float = 45.0

@export_group("Networking")
@export var default_port: int = 7777
@export var max_players: int = 4

func get_seed(id: StringName) -> SeedDef:
	for s in seeds:
		if s.id == id:
			return s
	return null

func get_upgrade(id: StringName) -> UpgradeDef:
	for u in upgrades:
		if u.id == id:
			return u
	return null

func quota_for_round(round_number: int, player_count: int = 1) -> int:
	var n: int = max(round_number, 1)
	var base := base_quota * pow(quota_scale, n - 1) + quota_add * (n - 1)
	var team: float = 1.0 + quota_per_extra_player * float(maxi(player_count - 1, 0))
	return int(round(base * team))

func total_grow_time(seed: SeedDef) -> float:
	var t := 0.0
	for d in stage_durations:
		t += d
	return t * (seed.grow_time_multiplier if seed else 1.0)
