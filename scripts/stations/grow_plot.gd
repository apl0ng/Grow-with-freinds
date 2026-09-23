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
			return "Ready"
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
			return "Harvest %s x%d" % [get_strain_name(), s.yield_amount if s != null else 1]
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
		Stage.READY:
			server_harvest(player)
		_:
			if item_is(held, Const.ITEM_WATERING_CAN) and get_can_charges(held) > 0 and server_water(1.0):
				held.set(&"charges", get_can_charges(held) - 1)

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
func tick(delta: float) -> void:
	if delta <= 0.0 or not GameState.is_playing() or not is_growing():
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
