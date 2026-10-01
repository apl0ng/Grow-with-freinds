class_name Well
extends Interactable
## Water source (scenes/stations/well.tscn). Owner: farming agent.
## - Interact while holding a watering can that is not full -> refills it to its capacity (server).
## - When the world is ready, the host spawns Config.balance.starting_watering_cans full cans at
##   $CanSpots/CanSpot1..N (cycled; extra cans are nudged sideways so they do not overlap).
## - On GameState.game_reset (RETRY) the host puts every watering can back at the CanSpots, full, and
##   respawns missing ones (ItemManager despawns seed packets/products but leaves the cans to the Well).
## Front of the station is local +Z (the can spots are there).

## Sideways spacing for cans that share a spot when there are more cans than spots.
const EXTRA_CAN_OFFSET := 0.35
const WATER_BURST_COLOR := Color(0.35, 0.75, 1.0)

@onready var _can_spots: Node3D = %CanSpots
@onready var _water: Node3D = %Water
@onready var _bucket: Node3D = %Bucket

## Frames left before the cans are restored after a game reset (0 = nothing pending).
const CAN_RESET_DELAY_FRAMES := 2

var _cans_spawned: bool = false
var _can_reset_frames: int = 0

func _ready() -> void:
	set_process(false)
	Game.world_ready.connect(_on_world_ready)
	# The world may already be fully ready if this well was added later (world_ready already fired).
	if Game.world != null and Game.world.is_node_ready() and Game.world.is_ancestor_of(self):
		_on_world_ready.call_deferred(Game.world)
	# Full game reset (RETRY after a game over): every can back to the well, full (ItemManager leaves cans to us).
	GameState.game_reset.connect(_on_game_reset)
	# M12 disrupt: a late joiner gets the water main's state (host only; the signal fires on the server).
	Net.peer_registered.connect(_on_peer_registered)

func get_can_spots() -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	for c in _can_spots.get_children():
		if c is Marker3D:
			out.append(c)
	return out

# --------------------------------------------------------------------------------------------------
# Interactable overrides (pure)

func get_prompt(player: Player) -> String:
	if not pressure_on:
		return PROMPT_NO_PRESSURE
	var held := GrowPlot.get_held_item_of(player)
	if GrowPlot.item_is(held, Const.ITEM_WATERING_CAN):
		return "Fill can (%d/%d)" % [GrowPlot.get_can_charges(held), GrowPlot.get_can_capacity(held)]
	return "Fill can"

func can_interact(player: Player) -> bool:
	if not pressure_on:
		return false
	var held := GrowPlot.get_held_item_of(player)
	return GrowPlot.item_is(held, Const.ITEM_WATERING_CAN) \
		and GrowPlot.get_can_charges(held) < GrowPlot.get_can_capacity(held)

func get_denied_reason(player: Player) -> String:
	if not pressure_on:
		return PROMPT_NO_PRESSURE
	var held := GrowPlot.get_held_item_of(player)
	if not GrowPlot.item_is(held, Const.ITEM_WATERING_CAN):
		return "Needs a can."
	if GrowPlot.get_can_charges(held) >= GrowPlot.get_can_capacity(held):
		return "Can's full."
	return ""

## SERVER ONLY.
func _server_interact(player: Player) -> void:
	var held := GrowPlot.get_held_item_of(player)
	if server_fill_can(held):
		_rpc_fill_fx.rpc()

## SERVER. Fills a watering can to its capacity. False if `item` is not a can or is already full.
func server_fill_can(item: Item) -> bool:
	if is_inside_tree() and not GrowPlot.is_server_peer(self):
		push_error("Well.server_fill_can called on a client")
		return false
	if not pressure_on or not GrowPlot.item_is(item, Const.ITEM_WATERING_CAN):
		return false
	var capacity := GrowPlot.get_can_capacity(item)
	if GrowPlot.get_can_charges(item) >= capacity:
		return false
	item.set(&"charges", capacity)
	return true

## SERVER. Spawns the starting watering cans through `items`. Returns how many spawned.
func server_spawn_starting_cans(items: ItemManager) -> int:
	if items == null:
		return 0
	var spawned := 0
	for i in Config.balance.starting_watering_cans:
		var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": GameState.get_can_capacity()}, get_can_spot_position(i))
		if can != null:
			spawned += 1
	return spawned

## SERVER. Puts every watering can back at the CanSpots (taken out of hands), full, and spawns missing ones
## so there are at least starting_watering_cans. Returns the number of cans afterwards.
func server_reset_cans(items: ItemManager) -> int:
	if items == null:
		return 0
	var i := 0
	for item in items.get_items():
		if not GrowPlot.item_is(item, Const.ITEM_WATERING_CAN) or item.is_queued_for_deletion():
			continue
		item.set(&"charges", GrowPlot.get_can_capacity(item))
		items.server_drop_item(item, get_can_spot_position(i))
		i += 1
	while i < Config.balance.starting_watering_cans:
		if items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": GameState.get_can_capacity()}, get_can_spot_position(i)) == null:
			break
		i += 1
	return i

## World position for the i-th can: CanSpots cycled, later laps nudged along the spot's local X.
func get_can_spot_position(index: int) -> Vector3:
	var spots := get_can_spots()
	if spots.is_empty():
		return global_position + global_basis.z * 1.4
	var spot := spots[index % spots.size()]
	@warning_ignore("integer_division")
	var lap: int = index / spots.size()
	return spot.global_position + spot.global_basis.x * EXTRA_CAN_OFFSET * lap

func _on_world_ready(world: World) -> void:
	if _cans_spawned or not is_inside_tree() or world == null or not is_instance_valid(world):
		return
	if not Net.is_host or not GrowPlot.is_server_peer(self):
		return
	_cans_spawned = true
	server_spawn_starting_cans(world.items)

func _on_game_reset() -> void:
	if not Net.is_host or not GrowPlot.is_server_peer(self):
		return
	# M12 disrupt: the water main is back on after a reset whatever turned it off.
	server_set_pressure(true)
	# Let any other reset handlers (e.g. despawning loose items) run first, then restore the cans.
	_can_reset_frames = CAN_RESET_DELAY_FRAMES
	set_process(true)

func _process(_delta: float) -> void:
	_can_reset_frames -= 1
	if _can_reset_frames > 0:
		return
	set_process(false)
	if Game.world != null and is_instance_valid(Game.world):
		server_reset_cans(Game.world.items)

## Every peer: splash + bucket wobble when a can is filled.
@rpc("authority", "call_local", "unreliable")
func _rpc_fill_fx() -> void:
	Sfx.play(&"water", _water.global_position)
	GrowPlot.juice_fx(&"splash", _water.global_position + Vector3.UP * 0.15, WATER_BURST_COLOR, 14)
	Juice.bounce(_bucket, 0.3)

# --- M12 disrupt: the water main --------------------------------------------------------------------------
# Events' water_off turns the pressure off on the host (server_set_pressure(false)); the state is synced by a
# reliable call_local RPC on this node (the same path on every peer), replayed to late joiners on registration,
# and back on when the event ends, is force-ended, or the game resets. While off: prompt "No pressure", refills
# refused on the client prediction and the server (can_interact + server_fill_can).

## Every peer: the water main went off / came back.
signal pressure_changed(on: bool)

## Prompt (and denial) while the main is off.
const PROMPT_NO_PRESSURE := "No pressure"

## False while the water main is off (synced).
var pressure_on: bool = true


func has_pressure() -> bool:
	return pressure_on


## SERVER ONLY. Turns the water main on / off on every peer (no-op when unchanged; a warning off the host).
func server_set_pressure(on: bool) -> void:
	if not is_inside_tree() or not multiplayer.is_server():
		push_warning("Well.server_set_pressure called on a client")
		return
	if on == pressure_on:
		return
	_rpc_set_pressure.rpc(on)


@rpc("authority", "call_local", "reliable")
func _rpc_set_pressure(on: bool) -> void:
	if on == pressure_on:
		return
	pressure_on = on
	# The tank drains visibly: the water disc is gone while the main is off.
	if _water != null:
		_water.visible = on
	pressure_changed.emit(on)


## Host: a late joiner gets the current state when it is not the default.
func _on_peer_registered(peer_id: int) -> void:
	if not is_inside_tree() or not multiplayer.is_server() or pressure_on:
		return
	_rpc_set_pressure.rpc_id(peer_id, false)
