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
	_mayhem_setup()  # M14 mayhem: the hole, the jet and the puddle (region at the end of the file)

func get_can_spots() -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	for c in _can_spots.get_children():
		if c is Marker3D:
			out.append(c)
	return out

# --------------------------------------------------------------------------------------------------
# Interactable overrides (pure)

func get_prompt(player: Player) -> String:
	if leaking:  # M14 mayhem: the hole comes first
		return _patch_prompt()
	if not pressure_on:
		return PROMPT_NO_PRESSURE
	var held := GrowPlot.get_held_item_of(player)
	if GrowPlot.item_is(held, Const.ITEM_WATERING_CAN):
		return "Fill can (%d/%d)" % [GrowPlot.get_can_charges(held), GrowPlot.get_can_capacity(held)]
	return "Fill can"

func can_interact(player: Player) -> bool:
	if leaking:  # M14 mayhem: anyone can hold it shut, hands full or not
		return true
	if not pressure_on:
		return false
	var held := GrowPlot.get_held_item_of(player)
	return GrowPlot.item_is(held, Const.ITEM_WATERING_CAN) \
		and GrowPlot.get_can_charges(held) < GrowPlot.get_can_capacity(held)

func get_denied_reason(player: Player) -> String:
	if leaking:  # M14 mayhem
		return ""
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
	if leaking:  # M14 mayhem: E on a leaking tank is the patch hold (interact() below), never a refill
		return
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

func _process(delta: float) -> void:
	# M14 mayhem: _process also runs for the leak (the hold, the puddle), so the can reset only counts while pending.
	_mayhem_process(delta)
	if _can_reset_frames <= 0:
		set_process(_mayhem_needs_process())
		return
	_can_reset_frames -= 1
	if _can_reset_frames > 0:
		return
	set_process(_mayhem_needs_process())
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
const PROMPT_NO_PRESSURE := "No pressure."

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
	_mayhem_replay(peer_id)  # M14 mayhem: the leak, the puddle and the patch for a late joiner
	if not is_inside_tree() or not multiplayer.is_server() or pressure_on:
		return
	_rpc_set_pressure.rpc_id(peer_id, false)


# --- M14 mayhem: the tank springs a leak ------------------------------------------------------------------------
# Events' leak (Events.EVENT_LEAK) opens a hole in the tank wall on the host: server_set_leaking(true). The whole
# state (leaking, puddle, puddle age, patched) travels in ONE reliable call_local RPC on this node, the same on every
# peer and replayed to late joiners, so the jet, the hole, the patch plate and the puddle are built from synced state
# only. While it leaks:
#   - a jet (CPUParticles3D) comes out of the hole and the `leak` loop plays there;
#   - a puddle spreads on the floor in front of the tank (PUDDLE_RADIUS_MIN -> PUDDLE_RADIUS_MAX over PUDDLE_SPREAD_SEC of
#     leaking; the age is advanced by Events.tick on the host and by _process elsewhere);
#   - the prompt is "Hold E · Patch the leak". The hold is the FuseBox pattern: tracked locally (interact() is
#     overridden WITHOUT a server round trip per press), one request when leak_patch_sec is reached, validated on the
#     host (range, not in the back room, still leaking) -> server_patch() -> Events.server_leak_patched().
# The puddle outlives the leak (Events clears it puddle_sec later: server_clear_puddle()); Events judges the slips.

## Every peer: the hole opened / closed.
signal leaking_changed(on: bool)
## Every peer: the puddle appeared / is gone.
signal puddle_changed(present: bool)

const PROMPT_PATCH := "Hold %s · Patch the leak"
const PROMPT_PATCHING := "Hold %s · Patch the leak · %.1f s"
const REASON_NO_LEAK := "Nothing to patch."
const REASON_PATCH_TOO_FAR := "Too far."
## The hole in the tank wall (local; the wall is a ring of radius 1 m, the front is +Z).
const LEAK_HOLE := Vector3(0.43, 0.42, 0.93)
## Centre of the puddle on the floor (local): where the jet lands, between the tank and the room.
const PUDDLE_CENTER := Vector3(0.6, 0.0, 1.7)
const PUDDLE_RADIUS_MIN := 0.5
const PUDDLE_RADIUS_MAX := 2.2
## Seconds of leaking until the puddle has its full radius.
const PUDDLE_SPREAD_SEC := 10.0
## The disc floats this far above the floor (no z-fight) and dries up over PUDDLE_DRY_SEC when cleared.
const PUDDLE_LIFT := 0.012
const PUDDLE_DRY_SEC := 1.2
## After a request the tank waits this long before another hold can send again (a refusal is a toast).
const PATCH_RESEND_GUARD_SEC := 1.0

## True while the tank leaks (synced).
var leaking: bool = false

var _puddle: bool = false          # a puddle lies on the floor (synced)
var _puddle_age: float = 0.0       # seconds it has been fed (synced at every state change, advanced locally between)
var _patched: bool = false         # a plate sits on the hole (synced)
var _patch_hold: float = 0.0
var _patch_holding: bool = false
var _patch_sent: bool = false
var _leak_root: Node3D = null
var _leak_hole: MeshInstance3D = null
var _leak_plate: MeshInstance3D = null
var _leak_jet: CPUParticles3D = null
var _puddle_mesh: MeshInstance3D = null
var _puddle_shown: float = 0.0     # the radius the disc is drawn at (eases towards the real one)
var _leak_loop: int = 0            # Sfx loop handle (0 = silent)


func is_leaking() -> bool:
	return leaking


func has_puddle() -> bool:
	return _puddle


## True once a worker patched the hole (the plate stays on until the shift ends).
func is_patched() -> bool:
	return _patched


## The puddle's radius right now in metres (0 without one).
func get_puddle_radius() -> float:
	if not _puddle:
		return 0.0
	return lerpf(PUDDLE_RADIUS_MIN, PUDDLE_RADIUS_MAX, clampf(_puddle_age / PUDDLE_SPREAD_SEC, 0.0, 1.0))


## Global centre of the puddle on the floor.
func get_puddle_center() -> Vector3:
	return global_transform * PUDDLE_CENTER if is_inside_tree() else transform * PUDDLE_CENTER


## True when `point` (global) stands in the puddle (flat distance; a non-finite point never does).
func is_in_puddle(point: Vector3) -> bool:
	if not _puddle:
		return false
	var c := get_puddle_center()
	return Vector2(point.x - c.x, point.z - c.z).length() <= get_puddle_radius()


## Global position of the hole (the jet, the loop, the patch).
func get_leak_position() -> Vector3:
	return global_transform * LEAK_HOLE if is_inside_tree() else transform * LEAK_HOLE


## 0..1 of the local worker's patch hold (0 when nobody holds here).
func get_patch_progress() -> float:
	return clampf(_patch_hold / _patch_sec(), 0.0, 1.0)


## True while the local worker holds the patch.
func is_patching() -> bool:
	return _patch_holding


## SERVER ONLY. Opens / closes the hole on every peer (no-op when unchanged). Opening starts (or keeps feeding) the
## puddle; closing leaves the puddle where it is (server_clear_puddle() removes it).
func server_set_leaking(on: bool) -> void:
	if not is_inside_tree() or not multiplayer.is_server():
		push_warning("Well.server_set_leaking called on a client")
		return
	if on == leaking:
		return
	if on:
		_rpc_leak_state.rpc(true, true, _puddle_age if _puddle else 0.0, false)
	else:
		_rpc_leak_state.rpc(false, _puddle, _puddle_age, _patched)


## SERVER ONLY. A worker patched the hole: the leak stops with the plate on, and Events is told (it ends the leak
## event and names the worker). False when nothing leaks.
func server_patch(by_peer: int) -> bool:
	if not is_inside_tree() or not multiplayer.is_server():
		push_warning("Well.server_patch called on a client")
		return false
	if not leaking:
		return false
	_rpc_leak_state.rpc(false, _puddle, _puddle_age, true)
	Events.server_leak_patched(by_peer)
	return true


## SERVER ONLY. The puddle dries up on every peer (no-op without one or while the tank still leaks).
func server_clear_puddle() -> void:
	if not is_inside_tree() or not multiplayer.is_server() or not _puddle or leaking:
		return
	_rpc_leak_state.rpc(false, false, 0.0, _patched)


## SERVER ONLY. No leak, no puddle, no plate (shift end, game reset). No-op when already so.
func server_reset_leak() -> void:
	if not is_inside_tree() or not multiplayer.is_server():
		return
	if leaking or _puddle or _patched:
		_rpc_leak_state.rpc(false, false, 0.0, false)


## Feeds the puddle for `delta` seconds while the tank leaks. Events.tick calls it on the host (so tests can skip
## time); the other peers advance it from _process.
func tick_puddle(delta: float) -> void:
	if leaking and _puddle and delta > 0.0:
		_puddle_age = minf(_puddle_age + delta, PUDDLE_SPREAD_SEC)


## Local only: E on a leaking tank starts the patch hold (does NOT call super: the request goes out when the hold
## completes). A tank that does not leak behaves as before.
func interact(player: Player) -> void:
	if not leaking:
		super.interact(player)
		return
	if player == null or not player.is_local():
		return
	if _patch_holding or _patch_sent:
		return
	_patch_holding = true
	_patch_hold = 0.0
	set_process(true)


## Any peer (local): asks the host to patch the hole for the local worker (validated there).
func request_patch() -> void:
	if not is_inside_tree():
		return
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_patch_sent = true
	_patch_hold = 0.0
	get_tree().create_timer(PATCH_RESEND_GUARD_SEC).timeout.connect(func() -> void: _patch_sent = false)
	_rpc_request_patch.rpc_id(Const.SERVER_PEER_ID)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_patch() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	var player: Player = Game.get_player(sender)
	if player == null or not player.is_inside_tree():
		return
	if GameState.is_in_backroom(sender):
		_rpc_denied.rpc_id(sender, REASON_BACKROOM)
		return
	var max_dist: float = Config.balance.interact_distance + server_range_slack
	# `not <=` rather than `>`: a non-finite synced position is never in range.
	if not (player.global_position.distance_to(global_position) <= max_dist):
		_rpc_denied.rpc_id(sender, REASON_PATCH_TOO_FAR)
		return
	if not leaking:
		_rpc_denied.rpc_id(sender, REASON_NO_LEAK)
		return
	server_patch(sender)


## Every peer: the whole leak state. Idempotent, so the late-join replay and a repeated call change nothing.
@rpc("authority", "call_local", "reliable")
func _rpc_leak_state(is_leaking: bool, puddle: bool, puddle_age: float, patched: bool) -> void:
	var was_leaking := leaking
	var had_puddle := _puddle
	var was_patched := _patched
	leaking = is_leaking
	_puddle = puddle
	_puddle_age = clampf(puddle_age, 0.0, PUDDLE_SPREAD_SEC) if is_finite(puddle_age) else 0.0
	_patched = patched
	_stop_patch_hold()
	_patch_sent = false
	_apply_leak_visuals()
	if patched and not was_patched and is_inside_tree():
		# The plate goes on: a dull thunk and a last spit of water.
		Sfx.play(&"drop", get_leak_position())
		GrowPlot.juice_fx(&"splash", get_leak_position(), WATER_BURST_COLOR, 8)
	if leaking != was_leaking:
		leaking_changed.emit(leaking)
	if _puddle != had_puddle:
		puddle_changed.emit(_puddle)
	if _mayhem_needs_process():
		set_process(true)


## Host: a late joiner gets the leak state when it is not the default.
func _mayhem_replay(peer_id: int) -> void:
	if not is_inside_tree() or not multiplayer.is_server():
		return
	if leaking or _puddle or _patched:
		_rpc_leak_state.rpc_id(peer_id, leaking, _puddle, _puddle_age, _patched)


## Builds the hole, the plate, the jet and the puddle disc (all hidden until the tank leaks). Plain children of the
## station: no sync, no RPCs of their own.
func _mayhem_setup() -> void:
	var out := Vector3(LEAK_HOLE.x, 0.0, LEAK_HOLE.z).normalized()
	_leak_root = Node3D.new()
	_leak_root.name = "Leak"
	# The holder's -Z points out of the tank wall.
	_leak_root.transform = Transform3D(Basis.looking_at(out, Vector3.UP), LEAK_HOLE)
	add_child(_leak_root)
	_leak_hole = MeshInstance3D.new()
	_leak_hole.name = "Hole"
	var hole_mesh := CylinderMesh.new()
	hole_mesh.top_radius = 0.045
	hole_mesh.bottom_radius = 0.045
	hole_mesh.height = 0.012
	hole_mesh.radial_segments = 12
	hole_mesh.rings = 1
	hole_mesh.material = Toon.material(Toon.INK, Toon.Finish.FLAT)
	_leak_hole.mesh = hole_mesh
	_leak_hole.rotation.x = PI * 0.5
	_leak_hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_leak_hole.visible = false
	_leak_root.add_child(_leak_hole)
	_leak_plate = MeshInstance3D.new()
	_leak_plate.name = "Plate"
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(0.24, 0.17, 0.02)
	plate_mesh.material = Toon.material(Toon.TIN, Toon.Finish.GLOSSY)
	_leak_plate.mesh = plate_mesh
	_leak_plate.position = Vector3(0.0, 0.0, -0.012)
	_leak_plate.rotation.z = 0.2   # put on in a hurry
	_leak_plate.visible = false
	_leak_root.add_child(_leak_plate)
	_leak_jet = CPUParticles3D.new()
	_leak_jet.name = "Jet"
	_leak_jet.emitting = false
	_leak_jet.amount = 40
	_leak_jet.lifetime = 0.4
	_leak_jet.randomness = 0.3
	_leak_jet.local_coords = false
	_leak_jet.direction = Vector3(0.0, 0.3, -1.0)
	_leak_jet.spread = 5.0
	_leak_jet.initial_velocity_min = 2.4
	_leak_jet.initial_velocity_max = 3.0
	_leak_jet.gravity = Vector3(0.0, -9.8, 0.0)
	_leak_jet.scale_amount_min = 0.6
	_leak_jet.scale_amount_max = 1.1
	_leak_jet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var drop := SphereMesh.new()
	drop.radius = 0.035
	drop.height = 0.07
	drop.radial_segments = 6
	drop.rings = 3
	drop.material = Toon.material(Toon.WATER, Toon.Finish.FLAT)
	_leak_jet.mesh = drop
	_leak_jet.position = Vector3(0.0, 0.0, -0.03)
	_leak_root.add_child(_leak_jet)
	_puddle_mesh = MeshInstance3D.new()
	_puddle_mesh.name = "Puddle"
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.01
	disc.radial_segments = 32
	disc.rings = 1
	disc.material = Toon.material(Color(Toon.WATER, 0.78), Toon.Finish.GLOSSY)
	_puddle_mesh.mesh = disc
	_puddle_mesh.position = PUDDLE_CENTER + Vector3.UP * PUDDLE_LIFT
	_puddle_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_puddle_mesh.visible = false
	add_child(_puddle_mesh)


## Every peer: the hole, the plate, the jet and the loop follow the synced state (the disc eases in _mayhem_process).
func _apply_leak_visuals() -> void:
	if _leak_hole != null:
		_leak_hole.visible = leaking
	if _leak_plate != null:
		_leak_plate.visible = _patched and not leaking
	if _leak_jet != null:
		_leak_jet.emitting = leaking
	if leaking:
		if _leak_loop == 0 and is_inside_tree() and _leak_root != null:
			_leak_loop = Sfx.play_loop(&"leak", _leak_root)
	elif _leak_loop != 0:
		Sfx.stop_loop(_leak_loop)
		_leak_loop = 0


## True while _process has mayhem work: a hold, a leak (the puddle spreads), a disc still easing to its radius.
func _mayhem_needs_process() -> bool:
	return _patch_holding or leaking or _puddle or _puddle_shown > 0.0


## Every peer, every frame while needed: the local worker's hold, the puddle's age off the host, the disc.
func _mayhem_process(delta: float) -> void:
	if _patch_holding:
		var player: Player = Game.local_player
		if player == null or not is_instance_valid(player) or not _still_patching(player):
			_stop_patch_hold()
		else:
			_patch_hold += delta
			if _patch_hold >= _patch_sec():
				_patch_holding = false
				_patch_hold = _patch_sec()
				request_patch()
	if leaking and is_inside_tree() and not multiplayer.is_server():
		tick_puddle(delta)   # the host's age is advanced by Events.tick
	if _puddle_mesh == null:
		return
	var target := get_puddle_radius()
	if is_equal_approx(_puddle_shown, target):
		return
	# Spreading follows the age closely; drying shrinks the disc to nothing over PUDDLE_DRY_SEC.
	var rate := PUDDLE_RADIUS_MAX / (PUDDLE_DRY_SEC if target < _puddle_shown else 0.5)
	_puddle_shown = move_toward(_puddle_shown, target, rate * delta)
	_puddle_mesh.visible = _puddle_shown > 0.01
	_puddle_mesh.scale = Vector3(maxf(_puddle_shown, 0.01), 1.0, maxf(_puddle_shown, 0.01))


func _patch_sec() -> float:
	return maxf(Config.balance.leak_patch_sec, 0.05)


func _patch_prompt() -> String:
	var key := HUD.action_key_text(&"interact", "E")
	if _patch_holding:
		return PROMPT_PATCHING % [key, maxf(_patch_sec() - _patch_hold, 0.0)]
	return PROMPT_PATCH % key


func _still_patching(player: Player) -> bool:
	if not leaking or not Input.is_action_pressed(&"interact"):
		return false
	var interactor := player.get_interactor()
	return interactor != null and interactor.current_target == self


func _stop_patch_hold() -> void:
	_patch_holding = false
	_patch_hold = 0.0


func _exit_tree() -> void:
	if _leak_loop != 0:
		Sfx.stop_loop(_leak_loop)
		_leak_loop = 0
