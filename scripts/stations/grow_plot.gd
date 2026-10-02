class_name GrowPlot
extends Interactable
## One planting spot (scenes/stations/grow_plot.tscn). Owner: farming agent.
##
## State machine (server-authoritative, synced to clients by the $Sync MultiplayerSynchronizer):
##   EMPTY --plant (seed packet)--> SEEDLING --grow--> VEGETATIVE --grow--> FLOWERING --grow--> READY
##   READY --harvest (empty hands)--> EMPTY          watering (can) works on SEEDLING/VEGETATIVE/FLOWERING
##
## Tick (host only, while GameState.is_playing(), growing stages only):
##   if water >= dry_threshold:
##       stage_progress += delta * GameState.get_growth_speed_multiplier()
##                         / (stage_durations[stage - 1] * seed.grow_time_multiplier)
##   water -= delta * water_drain_per_sec * GameState.get_water_drain_multiplier()   (clamped at 0)
##   stage_progress >= 1 -> next stage, progress 0.   EMPTY and READY neither grow nor drain.
## The soil keeps its water through a harvest (it only drains while something grows).
##
## Sync ($Sync, server authority): strain_id + stage ON_CHANGE (reliable, instant),
## water + stage_progress ALWAYS every 0.1 s (unreliable, bandwidth-limited). Every property has a
## setter that refreshes visuals, so the host and clients run the same idempotent presentation code.
## One-shot effects (sounds, bursts, pops, the wilt crossfade) only fire for natural transitions and are muted
## on a client until its first sync has settled, so a late joiner does not hear six plots "grow" at once and
## sees every plant in its synced state straight away.
## Strain colour: the plant grades SeedDef.color (Toon.grade) for its buds and the tag card shares that exact
## material (PlantVisual.get_tint_material()); Juice bursts get the raw colour because Juice mutes it itself.
##
## Items are accessed duck-typed (item_type + "charges"/"strain_id"/get_capacity()) so this file does
## not depend on the WateringCan / SeedPacket class names. See the static item helpers at the bottom.

enum Stage { EMPTY, SEEDLING, VEGETATIVE, FLOWERING, READY }

const STAGE_NAMES: Array[String] = ["Empty", "Seedling", "Growing", "Flowering", "Ready"]
## Water at or above this counts as full ("Already watered").
const WATER_FULL := 0.999
## Any water increase bigger than this is a watering (drain only ever lowers it).
const WATER_FX_MIN_INCREASE := 0.02
## Clients mute one-shot effects until this long after their first received sync.
const FX_SETTLE_MSEC := 600
const DIRT_COLOR := Color(0.55, 0.36, 0.2)
const LEAF_BURST_COLOR := Color(0.35, 0.8, 0.35)
const WATER_BURST_COLOR := Color(0.35, 0.75, 1.0)
## READY: a small grey puff and one low ding (STYLE.md "Mood & tone": no sparkles, no "Ready" text).
const READY_PUFF_COUNT := 4
const HARVEST_BURST_COUNT := 10
const SOIL_MATERIAL: Material = preload("res://art/materials/toon_soil.tres")
const SOIL_WET_MATERIAL: Material = preload("res://art/materials/toon_soil_wet.tres")

## Synced (server authority). Growth stage.
var stage: Stage = Stage.EMPTY:
	set(value):
		if value == stage:
			return
		var old: Stage = stage
		stage = value
		_on_stage_changed(old)
## Synced (server authority). SeedDef.id of the planted strain, &"" when empty.
var strain_id: StringName = &"":
	set(value):
		if value == strain_id:
			return
		strain_id = value
		_on_strain_changed()
## Synced (server authority). 0..1 water level. Growth pauses below Config.balance.dry_threshold.
var water: float = 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if value == water:
			return
		var old := water
		water = value
		_on_water_changed(old)
## Synced (server authority). 0..1 progress through the current stage.
var stage_progress: float = 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if value == stage_progress:
			return
		stage_progress = value
		if is_node_ready():
			_plant.set_growth(stage_progress)

@onready var _plant: PlantVisual = %Plant
@onready var _soil_meshes: Array[MeshInstance3D] = [%SoilBed, %SoilMound]
@onready var _gauge_pivot: Node3D = %FillPivot
@onready var _gauge_fill: Node3D = %Fill
@onready var _tag: Node3D = %Tag
@onready var _tag_card: MeshInstance3D = %Card
@onready var _plant_shape: CollisionShape3D = %PlantShape
@onready var _sync: MultiplayerSynchronizer = %Sync

var _soil_material: Material
var _soil_dry_color: Color
var _soil_wet_color: Color
var _soil_wetness: float = -1.0
var _first_sync_msec: int = -1

func _enter_tree() -> void:
	super()
	add_to_group(Const.GROUP_GROW_PLOTS)

func _ready() -> void:
	_setup_soil_material()
	_sync.synchronized.connect(_on_synced)
	_sync.delta_synchronized.connect(_on_synced)
	# Full game reset (RETRY after a game over): clear the plot.
	GameState.game_reset.connect(_on_game_reset)
	_refresh_visuals()

func _process(delta: float) -> void:
	# multiplayer.is_server() alone is true on a client that has not connected yet: pair it with Net.is_host.
	if Net.is_host and is_server_peer(self):
		tick(delta)

# --------------------------------------------------------------------------------------------------
# Queries (any peer)

func is_empty() -> bool: return stage == Stage.EMPTY
func is_ready_to_harvest() -> bool: return stage == Stage.READY
func is_dry() -> bool: return water < Config.balance.dry_threshold
## True in SEEDLING, VEGETATIVE and FLOWERING (the stages that grow and drink).
func is_growing() -> bool: return stage != Stage.EMPTY and stage != Stage.READY
## Growing and too dry to grow.
func needs_water() -> bool: return is_growing() and is_dry()

func get_seed() -> SeedDef:
	return Config.balance.get_seed(strain_id) if strain_id != &"" else null

func get_strain_name() -> String:
	var s := get_seed()
	return s.display_name if s != null else "Plant"

func get_stage_name() -> String:
	return STAGE_NAMES[stage]

## Seconds a growing stage lasts at 1x speed for the planted strain (0 for EMPTY/READY).
func get_stage_duration(for_stage: int) -> float:
	if for_stage <= Stage.EMPTY or for_stage >= Stage.READY:
		return 0.0
	var durations: Array[float] = Config.balance.stage_durations
	if durations.is_empty():
		return 0.0
	var base: float = durations[mini(for_stage - 1, durations.size() - 1)]
	var s := get_seed()
	return base * (s.grow_time_multiplier if s != null else 1.0)

## 0..1 overall progress from planting to READY.
func get_growth_fraction() -> float:
	if stage == Stage.EMPTY:
		return 0.0
	if stage == Stage.READY:
		return 1.0
	var total := 0.0
	var done := 0.0
	for s in range(Stage.SEEDLING, Stage.READY):
		var d := get_stage_duration(s)
		total += d
		if s < stage:
			done += d
		elif s == stage:
			done += d * stage_progress
	return done / total if total > 0.0 else 0.0

## Short human status, e.g. "Seedling 12%", "Flowering 80%, dry", "Ready".
func get_status_text() -> String:
	match stage:
		Stage.EMPTY:
			return "Empty"
		Stage.READY:
			return "Moving" if turning else "Ready" # --- M12 hostile --- (the twitch before it uproots)
	var text := "%s %d%%" % [get_stage_name(), int(get_growth_fraction() * 100.0)]
	if is_dry():
		text += ", dry"
	return text

# --------------------------------------------------------------------------------------------------
# Interactable overrides (pure; run on the client for prediction and on the server for validation)

func get_prompt(player: Player) -> String:
	var held := get_held_item_of(player)
	match stage:
		Stage.EMPTY:
			if item_is(held, Const.ITEM_SEED_PACKET):
				var s := Config.balance.get_seed(get_packet_strain(held))
				return "Plant %s" % (s.display_name if s != null else "seed")
			return "Empty tray"
		Stage.READY:
			var s := get_seed()
			var harvest := "Harvest %s x%d" % [get_strain_name(), s.yield_amount if s != null else 1]
			return harvest + " · Moving" if turning else harvest # --- M12 hostile --- (harvest it now or step back)
	if item_is(held, Const.ITEM_WATERING_CAN):
		return "Water plant (%s)" % _water_status()
	return "%s · %s" % [get_strain_name(), get_status_text()]

func can_interact(player: Player) -> bool:
	if player == null:
		return false
	var held := get_held_item_of(player)
	match stage:
		Stage.EMPTY:
			return item_is(held, Const.ITEM_SEED_PACKET) and Config.balance.get_seed(get_packet_strain(held)) != null
		Stage.READY:
			return held == null
	return item_is(held, Const.ITEM_WATERING_CAN) and get_can_charges(held) > 0 and water < WATER_FULL

func get_denied_reason(player: Player) -> String:
	if player == null:
		return ""
	var held := get_held_item_of(player)
	match stage:
		Stage.EMPTY:
			if item_is(held, Const.ITEM_SEED_PACKET):
				return "" if Config.balance.get_seed(get_packet_strain(held)) != null else "Unknown seed."
			return "Needs seeds."
		Stage.READY:
			return "Hands full." if held != null else ""
	if item_is(held, Const.ITEM_WATERING_CAN):
		if get_can_charges(held) <= 0:
			return "Can's empty."
		if water >= WATER_FULL:
			return "Already watered."
		return ""
	if item_is(held, Const.ITEM_SEED_PACKET):
		return "Already planted."
	# The Interactor shows this (greyed) instead of the prompt, so it carries the growth status too.
	return "Dry. Needs water." if is_dry() else "Not ready. %d%%" % int(get_growth_fraction() * 100.0)

## SERVER ONLY (called by Interactable after distance + can_interact validation).
func _server_interact(player: Player) -> void:
	var held := get_held_item_of(player)
	match stage:
		Stage.EMPTY:
			if not item_is(held, Const.ITEM_SEED_PACKET):
				return
			if server_plant(get_packet_strain(held)):
				var items := _item_manager()
				if items != null:
					items.server_despawn_item(held)
				GameState.server_add_stat(player.peer_id, Const.STAT_PLANTED)
		Stage.READY:
			if server_harvest(player):
				GameState.server_add_stat(player.peer_id, Const.STAT_HARVESTED)
		_:
			if item_is(held, Const.ITEM_WATERING_CAN) and get_can_charges(held) > 0 and server_water(1.0):
				held.set(&"charges", get_can_charges(held) - 1)
				GameState.server_add_stat(player.peer_id, Const.STAT_WATERED)

# --------------------------------------------------------------------------------------------------
# Server API (host only; also used by tests and other systems)

## SERVER. Plants `new_strain_id` in an EMPTY plot. False if not empty or the strain is unknown.
func server_plant(new_strain_id: StringName) -> bool:
	if not _check_server(&"server_plant"):
		return false
	if stage != Stage.EMPTY or Config.balance.get_seed(new_strain_id) == null:
		return false
	strain_id = new_strain_id
	stage_progress = 0.0
	stage = Stage.SEEDLING
	return true

## SERVER. Adds `charges_worth` watering-can charges of water (Config.balance.water_per_charge each),
## clamped to 1. False if nothing is growing or the plot is already full.
func server_water(charges_worth: float = 1.0) -> bool:
	if not _check_server(&"server_water"):
		return false
	if not is_growing() or water >= WATER_FULL or charges_worth <= 0.0:
		return false
	water = minf(1.0, water + Config.balance.water_per_charge * charges_worth)
	return true

## SERVER. Harvests a READY plant: spawns the product in `player`'s hands (or on the floor in front of
## the plot when `player` is null) and resets the plot to EMPTY. False (plot untouched) if not READY,
## the player's hands are full, or the ItemManager is unavailable / refused to spawn.
func server_harvest(player: Player) -> bool:
	if not _check_server(&"server_harvest"):
		return false
	if stage != Stage.READY:
		return false
	if player != null and player.get_held_item() != null:
		return false
	var items := _item_manager()
	if items == null:
		push_warning("GrowPlot.server_harvest: no ItemManager (Game.world is not set); harvest skipped")
		return false
	var s := get_seed()
	var props := {"strain_id": strain_id, "amount": s.yield_amount if s != null else 1}
	var holder := player.peer_id if player != null else 0
	# In hands: the position is irrelevant. On the floor (no player): just in front of the plot (items rest at their origin).
	var spawn_pos := global_position + global_basis.z * 1.1 if holder == 0 else global_position + Vector3.UP * 0.9
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, props, spawn_pos, holder)
	if product == null:
		push_warning("GrowPlot.server_harvest: ItemManager did not spawn the product; harvest skipped")
		return false
	stage_progress = 0.0
	stage = Stage.EMPTY
	strain_id = &""
	return true

## SERVER. Clears the plot completely (plant, water, progress). For full game resets.
func server_reset() -> void:
	if not _check_server(&"server_reset"):
		return
	stage_progress = 0.0
	stage = Stage.EMPTY
	strain_id = &""
	water = 0.0

## Growth / drain step. Called every frame on the host by _process; public so tests can drive it.
## M10: nothing grows or drinks while the mains are off (Events power cut).
func tick(delta: float) -> void:
	if delta <= 0.0 or not GameState.is_playing() or not is_growing():
		return
	if not Events.is_power_on():
		return
	var b := Config.balance
	if water >= b.dry_threshold:
		var duration := get_stage_duration(stage)
		if duration <= 0.0:
			stage_progress = 1.0
		else:
			stage_progress += delta * GameState.get_growth_speed_multiplier() / duration
	water = maxf(0.0, water - delta * b.water_drain_per_sec * GameState.get_water_drain_multiplier())
	if stage_progress >= 1.0:
		stage_progress = 0.0
		stage = _next_stage(stage)

static func _next_stage(s: Stage) -> Stage:
	match s:
		Stage.SEEDLING:
			return Stage.VEGETATIVE
		Stage.VEGETATIVE:
			return Stage.FLOWERING
		_:
			return Stage.READY

func _on_game_reset() -> void:
	if Net.is_host and is_server_peer(self):
		server_reset()

func _check_server(what: StringName) -> bool:
	if is_inside_tree() and not is_server_peer(self):
		push_error("GrowPlot.%s called on a client" % what)
		return false
	return true

# --------------------------------------------------------------------------------------------------
# Presentation (every peer; driven by the property setters)

func _refresh_visuals() -> void:
	_refresh_tint()
	_update_dry(false)
	_plant.set_stage(stage, false)
	_plant.set_growth(stage_progress)
	_tag.visible = stage != Stage.EMPTY
	_update_collision()
	_update_water_visuals()

func _on_stage_changed(old: Stage) -> void:
	if not is_node_ready():
		return
	var fx := _fx_allowed()
	var natural_growth := old >= Stage.SEEDLING and old < Stage.READY and stage == old + 1
	var planted := old == Stage.EMPTY and stage == Stage.SEEDLING
	var harvested := old == Stage.READY and stage == Stage.EMPTY
	# Wilt state first: while no plant is on screen (planting) PlantVisual snaps it, so a seedling planted in
	# dry soil pops in already wilted instead of crossfading; a live change on a shown plant crossfades.
	_update_dry(fx)
	_plant.set_stage(stage, fx and (planted or natural_growth))
	# A new stage always starts at progress 0. Clients get `stage` (reliable) before the next 0.1 s
	# progress update, so do not size the new model with the previous stage's ~1.0 progress.
	_plant.set_growth(0.0 if planted or natural_growth else stage_progress)
	_tag.visible = stage != Stage.EMPTY
	if fx and planted:
		Juice.pop_in(_tag)
	_update_collision()
	if not fx:
		return
	var sound_pos := global_position + Vector3.UP * 0.6
	if planted:
		Sfx.play(&"plant", sound_pos)
		juice_fx(&"puff", _soil_top(), DIRT_COLOR, 10)
	elif natural_growth:
		_plant.bounce(0.15)
		if stage == Stage.READY:
			Sfx.play(&"ready", sound_pos)
			juice_fx(&"puff", _plant.get_top_global_position(), Juice.GLOOM, READY_PUFF_COUNT)
		else:
			Sfx.play(&"grow", sound_pos)
			Juice.burst(_plant.get_top_global_position(), LEAF_BURST_COLOR, 8)
	elif harvested:
		Sfx.play(&"harvest", sound_pos)
		Juice.burst(_soil_top() + Vector3.UP * 0.4, _tint_color(), HARVEST_BURST_COUNT)

func _on_strain_changed() -> void:
	if is_node_ready():
		_refresh_tint()

## Plant tint + the tag card, which shares the buds' graded strain material (a new tint is a new material).
func _refresh_tint() -> void:
	_plant.set_tint(_tint_color())
	_tag_card.material_override = _plant.get_tint_material()

func _on_water_changed(old: float) -> void:
	if not is_node_ready():
		return
	_update_water_visuals()
	var fx := _fx_allowed()
	_update_dry(fx)
	if fx and water - old > WATER_FX_MIN_INCREASE:
		Sfx.play(&"water", global_position + Vector3.UP * 0.6)
		juice_fx(&"splash", _soil_top() + Vector3.UP * 0.1, WATER_BURST_COLOR, 12)
		_plant.bounce(0.2)

func _update_dry(animate: bool) -> void:
	_plant.set_dry(needs_water(), animate)

func _update_collision() -> void:
	# Deferred: setters can run while physics queries are flushing (network sync, physics callbacks).
	_plant_shape.set_deferred(&"disabled", stage == Stage.EMPTY)

func _update_water_visuals() -> void:
	# Gauge: the fill pivot scales along X (anchored at the left end).
	var w := maxf(water, 0.001)
	_gauge_pivot.scale = Vector3(w, 1.0, 1.0)
	_gauge_fill.visible = water > 0.005
	# Soil: dry colour until water > 2 * dry_threshold, then noticeably wet, fully wet from 50 %.
	var th := Config.balance.dry_threshold
	var wet := 0.0
	if water > th * 2.0:
		wet = lerpf(0.55, 1.0, clampf((water - th * 2.0) / maxf(0.5 - th * 2.0, 0.01), 0.0, 1.0))
	wet = snappedf(wet, 0.05)
	if wet == _soil_wetness:
		return
	_soil_wetness = wet
	if _soil_material is BaseMaterial3D:
		(_soil_material as BaseMaterial3D).albedo_color = _soil_dry_color.lerp(_soil_wet_color, wet)
	else:
		var m: Material = SOIL_WET_MATERIAL if wet > 0.0 else SOIL_MATERIAL
		for mi in _soil_meshes:
			mi.material_override = m

func _setup_soil_material() -> void:
	# One material per plot, blended between the dry and wet soil colours of the shared toon materials.
	# (Locals keep the `is` checks at runtime, so the art agent may swap the material types freely.)
	var dry_mat: Material = SOIL_MATERIAL
	var wet_mat: Material = SOIL_WET_MATERIAL
	if dry_mat is BaseMaterial3D and wet_mat is BaseMaterial3D:
		_soil_material = dry_mat.duplicate() as Material
		_soil_dry_color = (dry_mat as BaseMaterial3D).albedo_color
		_soil_wet_color = (wet_mat as BaseMaterial3D).albedo_color
		for mi in _soil_meshes:
			mi.material_override = _soil_material
	else:
		_soil_material = null

func _soil_top() -> Vector3:
	return global_position + Vector3.UP * 0.52

## Raw strain colour (PlantVisual grades it; Juice mutes it).
func _tint_color() -> Color:
	# Keep the last strain's colour when the strain is cleared so the harvest burst still matches it.
	var s := get_seed()
	return s.color if s != null else _plant.get_tint()

func _water_status() -> String:
	if is_dry():
		return "dry"
	if water >= WATER_FULL:
		return "full"
	return "water %d%%" % int(water * 100.0)

func _fx_allowed() -> bool:
	if not is_inside_tree():
		return false
	if is_server_peer(self):
		return true
	return _first_sync_msec >= 0 and Time.get_ticks_msec() - _first_sync_msec >= FX_SETTLE_MSEC

func _on_synced() -> void:
	if _first_sync_msec < 0:
		_first_sync_msec = Time.get_ticks_msec()

# --------------------------------------------------------------------------------------------------
# Shared helpers (also used by Well)

## True if `node`'s multiplayer API is the server (host, or offline). False with no peer at all (never
## calls is_server() on a null peer, which would spam errors).
static func is_server_peer(node: Node) -> bool:
	var mp := node.multiplayer if node.is_inside_tree() else null
	return mp != null and mp.has_multiplayer_peer() and mp.is_server()

## One-shot particle effect. splash / sparkle / puff are optional Juice extras (not in CONTRACTS.md):
## used when the art agent's Juice has them, otherwise falls back to the contract's Juice.burst().
static func juice_fx(kind: StringName, pos: Vector3, color: Color, count: int) -> void:
	if Juice.has_method(kind):
		match kind:
			&"splash":
				Juice.call(kind, pos, count)
				return
			&"sparkle", &"puff":
				Juice.call(kind, pos, color, count)
				return
	Juice.burst(pos, color, count)

# Item helpers (duck-typed)

## The item `player` holds (null if none or no world).
static func get_held_item_of(player: Player) -> Item:
	if player == null or Game.world == null:
		return null
	return player.get_held_item()

static func _item_manager() -> ItemManager:
	if Game.world == null or not is_instance_valid(Game.world):
		return null
	return Game.world.items

## True if `item` is a live item of `item_type` (Const.ITEM_*).
static func item_is(item: Item, item_type: StringName) -> bool:
	return item != null and is_instance_valid(item) and item.item_type == item_type

## WateringCan.charges (0 for anything else).
static func get_can_charges(item: Item) -> int:
	if item == null:
		return 0
	var v: Variant = item.get(&"charges")
	return int(v) if v != null else 0

## WateringCan.get_capacity() (falls back to GameState.get_can_capacity()).
static func get_can_capacity(item: Item) -> int:
	if item != null and item.has_method(&"get_capacity"):
		return int(item.call(&"get_capacity"))
	return GameState.get_can_capacity()

## SeedPacket.strain_id (&"" for anything else).
static func get_packet_strain(item: Item) -> StringName:
	if item == null:
		return &""
	var v: Variant = item.get(&"strain_id")
	return StringName(v) if v != null else &""


# --- M12 stubs (lead): the flame agent fills server_scorch; the hostile agent adds the mutation roll ---------------

## SERVER. The flamethrower held the cone on this plot long enough: the crop is lost (plot reset, scorched soil for a
## while). Returns true when something burnt. `by_peer` is the shooter (stats / write-ups).
## Flame agent: the shooter gets Const.STAT_SCORCHED, and Const.WRITE_UP_ARSON unless a hostile plant stands within
## ARSON_HOSTILE_RADIUS of the plot (Hostiles.nearest_to). The cosmetic (_rpc_scorched: ash on the soil for
## SCORCH_SOIL_SEC, "scorch", the Story line) lands on every peer. A READY crop steps through FLOWERING for one
## network frame before the reset, because READY -> EMPTY is the harvest transition (snip + a burst in the strain
## colour) on every peer and a burnt crop must not sound harvested.
func server_scorch(by_peer: int) -> bool:
	if not _check_server(&"server_scorch"):
		return false
	if stage == Stage.EMPTY or _scorch_pending:
		return false
	# M13 review: a plant burnt while it is turning ("GrowPlot 3 is moving.") is not arson: the floor was told to deal
	# with it, and burning it in its tray is dealing with it. Read before the stage changes below.
	var arson := not is_turning()
	var nearest: Node3D = Hostiles.nearest_to(global_position)
	if arson and nearest != null and is_instance_valid(nearest) and nearest.is_inside_tree():
		arson = not (nearest.global_position.distance_to(global_position) <= ARSON_HOSTILE_RADIUS)
	# Stat and write-up first (the write-up's MAJOR Story line goes out before the PROGRESS "burnt" line, which then
	# waits its turn in Story's queue), then the cosmetic, then the crop.
	if by_peer > 0:
		GameState.server_add_stat(by_peer, Const.STAT_SCORCHED)
		if arson:
			GameState.server_write_up(by_peer, Const.WRITE_UP_ARSON)
	_rpc_scorched.rpc(by_peer)
	if stage == Stage.READY:
		_scorch_pending = true
		stage_progress = 0.0
		stage = Stage.FLOWERING
		get_tree().process_frame.connect(_finish_scorch, CONNECT_ONE_SHOT)
	else:
		server_reset()
	return true


# --- M12 flame (flame agent): scorched soil ------------------------------------------------------------------------

## Every peer: the crop burnt (the scorch cosmetic landed). `by_peer` = the shooter (0 = unknown).
signal scorched(by_peer: int)

## How long the soil stays black after a scorch (every peer).
const SCORCH_SOIL_SEC: float = 20.0
## Ash colour on the soil (near-black, a touch of the palette's ink).
const SCORCH_COLOR := Color("23202a")
const SCORCH_ASH_COUNT: int = 10
## No hostile plant within this many metres of the plot = arson.
const ARSON_HOSTILE_RADIUS: float = 4.0

var _ash: Node3D = null
var _scorched_until_msec: int = -1
var _scorch_pending: bool = false


## True while the soil shows the scorch (SCORCH_SOIL_SEC after the last one), any peer.
func is_scorched() -> bool:
	return _scorched_until_msec >= 0 and Time.get_ticks_msec() < _scorched_until_msec


## "GrowPlot 2" for the node "GrowPlot2" (Story lines).
func get_scorch_label() -> String:
	var n := String(name)
	var stem := n.rstrip("0123456789")
	if stem.length() == n.length() or stem.is_empty():
		return n
	return "%s %s" % [stem, n.substr(stem.length())]


func _finish_scorch() -> void:
	_scorch_pending = false
	if is_inside_tree() and is_server_peer(self):
		server_reset()


@rpc("authority", "call_local", "reliable")
func _rpc_scorched(by_peer: int) -> void:
	if not is_inside_tree():
		return
	_scorched_until_msec = Time.get_ticks_msec() + int(SCORCH_SOIL_SEC * 1000.0)
	_show_ash()
	Sfx.play(&"scorch", global_position + Vector3.UP * 0.6)
	juice_fx(&"puff", _soil_top() + Vector3.UP * 0.3, Juice.GLOOM, SCORCH_ASH_COUNT)
	var story: Node = Story
	if story != null and story.has_method(&"flame_plot_burnt"):
		story.call(&"flame_plot_burnt", get_scorch_label())
	scorched.emit(by_peer)


## A layer of ash over the soil bed and the mound (built once, shown for SCORCH_SOIL_SEC). It sits on top of the soil
## meshes so the water tint underneath can keep doing its own thing.
func _show_ash() -> void:
	if _ash == null:
		var mat := Toon.material(SCORCH_COLOR, Toon.Finish.MATTE)
		_ash = Node3D.new()
		_ash.name = "Ash"
		var bed := MeshInstance3D.new()
		var bed_mesh := BoxMesh.new()
		bed_mesh.size = Vector3(1.31, 0.02, 1.31)
		bed_mesh.material = mat
		bed.mesh = bed_mesh
		bed.position = Vector3(0.0, 0.455, 0.0)
		_ash.add_child(bed)
		var mound := MeshInstance3D.new()
		var mound_mesh := SphereMesh.new()
		mound_mesh.radius = 0.615
		mound_mesh.height = 0.215
		mound_mesh.radial_segments = 24
		mound_mesh.rings = 8
		mound_mesh.material = mat
		mound.mesh = mound_mesh
		mound.position = Vector3(0.0, 0.412, 0.0)
		_ash.add_child(mound)
		var visual := get_node_or_null(^"Visual")
		(visual if visual != null else self).add_child(_ash)
	_ash.visible = true
	Juice.pop_in(_ash, 0.3)
	get_tree().create_timer(SCORCH_SOIL_SEC).timeout.connect(_on_ash_timeout)


func _on_ash_timeout() -> void:
	if is_scorched() or _ash == null or not is_inside_tree():
		return # scorched again meanwhile: that timer hides it
	Juice.pop_out(_ash, 0.4)


# --- M12 hostile --------------------------------------------------------------------------------------------------
## Mutation (hostile agent, CONTRACTS.md "M12"). A READY plant of a strain with SeedDef.mutation_chance may turn: the
## host rolls once per READY (Hostiles polls the plots and calls server_roll_mutation), then the synced `turning` /
## `turn_left` count Config.balance.mutation_warning_sec down (server_tick_mutation, driven by Hostiles.tick while
## PLAYING). On every peer the `turning` setter starts a jitter tween on %Plant (the plant visibly twitches) and the
## status / prompt read "Moving". At zero the crop is lost (server_reset) and Hostiles.server_spawn(strain_id,
## global_position) puts the hostile plant on the floor. Harvesting a turning plant still works: the stage leaves
## READY, Hostiles clears `turning` on its next tick and the twitch stops everywhere.
## Sync: `turning` ON_CHANGE (reliable) and `turn_left` ALWAYS, in grow_plot.tscn's replication config (4 and 5).

## Seconds between jerks and how far the plant jerks (degrees) while turning.
const TWITCH_INTERVAL := 0.11
const TWITCH_DEG := 7.0

## Synced (server authority). True while a READY plant twitches before it uproots.
var turning: bool = false:
	set(value):
		if value == turning:
			return
		turning = value
		if is_node_ready():
			_update_twitch()
			if value and is_inside_tree():
				# Every peer (the setter runs from the sync too): the floor gets six seconds of warning.
				var story: Node = get_node_or_null(^"/root/Story")
				if story != null and story.has_method(&"hostile_plot_turning"):
					story.call(&"hostile_plot_turning", get_scorch_label())
## Synced (server authority). Seconds left of the twitch (the host counts down, clients only show it).
var turn_left: float = 0.0:
	set(value):
		turn_left = maxf(value, 0.0) if is_finite(value) else 0.0

var _twitch_tween: Tween = null


## True while the READY plant twitches (about to uproot).
func is_turning() -> bool:
	return turning and stage == Stage.READY


## SERVER. Rolls the strain's mutation_chance once for the READY plant. True when it turns: `turning` is set and the
## warning countdown armed. False for a non-READY plot, a plant already turning, or a roll that came up safe.
func server_roll_mutation() -> bool:
	if not _check_server(&"server_roll_mutation"):
		return false
	if stage != Stage.READY or turning:
		return false
	var s := get_seed()
	var chance := clampf(s.mutation_chance, 0.0, 1.0) if s != null else 0.0
	if chance <= 0.0 or randf() >= chance:
		return false
	turn_left = maxf(Config.balance.mutation_warning_sec, 0.0)
	turning = true
	return true


## SERVER. Counts the twitch down by `delta`; at zero the crop is lost (server_reset) and the hostile plant spawns
## where the tray is. Returns true when it uprooted. A plant that left READY meanwhile just stops turning.
func server_tick_mutation(delta: float) -> bool:
	if not _check_server(&"server_tick_mutation"):
		return false
	if not turning or delta <= 0.0:
		return false
	if stage != Stage.READY:
		turning = false
		return false
	turn_left -= delta
	if turn_left > 0.0:
		return false
	# M13 review: with hostile_max plants already on the floor the spawn below was refused AFTER the reset: the crop
	# vanished and nothing came out. The plant waits in its tray instead (still "Moving", still harvestable) until
	# one of them is burnt.
	if not Hostiles.has_room():
		return false
	var strain := strain_id
	var where := global_position
	turning = false
	server_reset()
	Hostiles.server_spawn(strain, where)
	return true


## Every peer: the jitter tween runs exactly while the plant turns (and is READY); otherwise the plant stands still.
func _update_twitch() -> void:
	if is_turning() and is_inside_tree():
		if _twitch_tween == null or not _twitch_tween.is_valid():
			_twitch_tween = create_tween().set_loops()
			_twitch_tween.tween_callback(_twitch_step).set_delay(TWITCH_INTERVAL)
		return
	if _twitch_tween != null and _twitch_tween.is_valid():
		_twitch_tween.kill()
	_twitch_tween = null
	_plant.rotation = Vector3.ZERO


func _twitch_step() -> void:
	if not is_turning():
		_update_twitch()
		return
	var a := deg_to_rad(TWITCH_DEG)
	_plant.rotation = Vector3(randf_range(-a, a), randf_range(-a * 0.5, a * 0.5), randf_range(-a, a))
