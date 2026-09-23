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
