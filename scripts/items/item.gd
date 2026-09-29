class_name Item
extends Interactable
## Base class for carryable items (watering can, seed packet, product).
##
## Items are spawned ONLY by the server through ItemManager (World/ItemSpawner, custom spawn_function).
## They always live under World/Items and are never reparented (reparenting a spawned node despawns it on
## clients). While held (holder_id != 0) an item copies its holder's hand-socket transform every frame on
## every peer and its collider is switched off; on the floor it rests at the synced rest transform.
##
## Replication (MultiplayerSynchronizer "Sync" in each item scene, server authority, all spawn=true + ON_CHANGE):
##   .:holder_id  .:rest_position  .:rest_rotation  + the subclass props (charges / strain_id / amount).
## rest_position / rest_rotation are the item's resting transform in World/Items space. They are synced instead of
## .:position / .:rotation so a held item following a hand does not stream its transform every frame: every peer
## computes the hand pose locally. On the server any direct write to position/rotation of a floor item (e.g. a
## station placing a spawned can) is mirrored into the rest values the next frame, so it still replicates.
## Remote values arrive through the property setters (before _ready for the spawn state), so every setter here is
## idempotent, never calls rpc() and only plays effects once the node is ready (not for the initial spawn values).
##
## First-person view model: while the LOCAL player (on this peer) holds the item, every GeometryInstance3D under it
## (meshes, Toonify outline hulls, Label3Ds) is moved to render layer Player.VIEW_MODEL_LAYER, which only that
## player's view-model pass draws (see Player), so the item never clips into walls or stations. The world layers
## are stored per node (meta META_WORLD_LAYERS) and restored when the item is dropped, handed to a remote player,
## loses its holder or leaves the tree. Re-evaluated every frame while held (_follow_holder), so an item that
## arrives before its local holder spawned (late join) or a view model switched off/on is handled too.
##
## M10 flight (thrown items, physics agent): the server sets the synced flight_origin / flight_velocity /
## flight_serial ONCE (ItemManager.server_throw_item; serial 0 = not flying, every throw gets a new serial) and clears
## the holder. Every peer then integrates the same arc locally from the moment it saw the serial:
##   p(t) = flight_origin + flight_velocity * t + 0.5 * FLIGHT_GRAVITY * t^2      (no wall clock over the wire)
## with a slow tumble, collision off and world render layers. The SERVER steps the same arc in
## ItemManager._physics_process (raycasts, hits, the chute) and ends the flight by writing rest_position /
## rest_rotation and then flight_serial = 0: every peer snaps to the rest transform and plays the landing.
## The config order (rest_*, flight_*, holder_id, props) matters: on a client the release (holder 0) arrives after the
## flight started, so the item never snaps back to its old resting spot for a frame.

## Emitted on every peer when the holder changes after the item spawned (0 = on the floor).
signal holder_changed(old_holder: int, new_holder: int)
## Emitted on every peer when a type-specific synced value (charges, strain, amount) changes after spawn.
signal props_changed
## M10, every peer: the item was thrown (started flying) / landed (stopped flying) after it spawned.
signal flight_changed(flying: bool)

## Meta on each GeometryInstance3D moved into the view model: its world render layers (restored on the way out).
const META_WORLD_LAYERS: StringName = &"item_world_layers"
## M10: gravity of a thrown item (m/s^2), identical on every peer.
const FLIGHT_GRAVITY := Vector3(0.0, -9.8, 0.0)
## M10: tumble of a flying item (radians per second about its local X, plus a little yaw).
const FLIGHT_SPIN: float = 5.0
const REASON_IN_THE_AIR := "It's in the air."

## One of Const.ITEM_* values. Set by the item scene.
@export var item_type: StringName = &"item"
## Collider child (StaticBody3D, layer Const.LAYER_ITEM, mask 0). Its layer is 0 while the item is held.
@export var collider_path: NodePath = ^"Collider"
@export_group("Held pose")
## Offset from the holder's hand socket, in socket space (metres), so the item sits nicely in hand.
@export var hold_offset: Vector3 = Vector3.ZERO
## Extra rotation applied in socket space while held (degrees).
@export var hold_rotation_degrees: Vector3 = Vector3.ZERO

## Peer id of the player holding this item, 0 when lying in the world. Synced (server authority).
var holder_id: int = 0:
	set = _set_holder_id
## Resting position (World/Items space). Synced; applied to the node whenever the item is not held.
var rest_position: Vector3 = Vector3.ZERO:
	set = _set_rest_position
## Resting rotation (euler radians, World/Items space). Synced; applied whenever the item is not held.
var rest_rotation: Vector3 = Vector3.ZERO:
	set = _set_rest_rotation
## M10 flight (synced, server authority): launch point (World/Items space), launch velocity (m/s) and the serial of
## the current throw (0 = not flying). See the header.
var flight_origin: Vector3 = Vector3.ZERO:
	set = _set_flight_origin
var flight_velocity: Vector3 = Vector3.ZERO:
	set = _set_flight_velocity
var flight_serial: int = 0:
	set = _set_flight_serial
## SERVER: who threw the item currently (or last) in flight (hits, chute shots, stats). Not synced.
var thrower_id: int = 0

var _holder: Player = null
var _flight_time: float = 0.0          # seconds since THIS peer saw the current flight_serial
var _flight_checked_t: float = 0.0     # SERVER: arc time up to which hits / walls were checked
var _hidden_without_holder: bool = false
## Cached in _ready: items always belong to the server and never change authority. Caching avoids querying the
## multiplayer peer every frame (errors spam if the ENet peer is already closed, e.g. the host just quit).
var _is_authority: bool = false
## Instance id of the local Player whose view model draws this item (0 = drawn in the world like any node).
var _view_model_owner_id: int = 0

func _enter_tree() -> void:
	super()
	add_to_group(Const.GROUP_ITEMS)

func _ready() -> void:
	# Held items are placed after the players moved this frame (players process at priority -10).
	process_priority = 10
	_is_authority = is_multiplayer_authority()
	_update_collision()
	if is_flying():
		# Spawned mid-flight (late joiner): start the arc from its origin now; the server ends it for everyone.
		_flight_time = 0.0
		position = flight_origin
	elif is_held():
		_follow_holder()
	else:
		_apply_rest_transform()
	_refresh_visuals()
	Juice.pop_in(get_visual())
	var mgr := get_manager()
	if mgr != null:
		mgr._on_item_ready(self)

func _exit_tree() -> void:
	_update_view_model(null)
	var mgr := get_parent() as ItemManager
	if mgr != null:
		mgr._on_item_exiting(self)

func _process(delta: float) -> void:
	if is_flying():
		_flight_time += delta
		position = get_flight_point(_flight_time)
		rotate_object_local(Vector3.RIGHT, FLIGHT_SPIN * delta)
		rotate_y(FLIGHT_SPIN * 0.3 * delta)
	elif holder_id != 0:
		_follow_holder()
	elif _is_authority:
		# Server: mirror direct transform writes on a floor item into the synced rest values.
		if position != rest_position:
			rest_position = position
		if rotation != rest_rotation:
			rest_rotation = rotation

# --- Public API ----------------------------------------------------------------------------------------------

func get_display_name() -> String:
	return String(item_type).capitalize()

## Short status shown after the name, e.g. "3/4" for a watering can. "" when there is nothing to add.
func get_status_text() -> String:
	return ""

## Display name plus status, e.g. "Watering Can (3/4)". Handy for the HUD's held-item line.
func get_label_text() -> String:
	var status := get_status_text()
	return get_display_name() if status == "" else "%s (%s)" % [get_display_name(), status]

func is_held() -> bool:
	return holder_id != 0

## M10: true while the item is in the air (thrown; flight_serial != 0). Nobody holds it and it cannot be picked up.
func is_flying() -> bool:
	return flight_serial != 0

## M10: point of the current arc `t` seconds after launch (World/Items space).
func get_flight_point(t: float) -> Vector3:
	return flight_origin + flight_velocity * t + FLIGHT_GRAVITY * (0.5 * t * t)

## M10: seconds since this peer saw the current throw.
func get_flight_time() -> float:
	return _flight_time

## True while this item is drawn in the local player's first-person view model (render layer
## Player.VIEW_MODEL_LAYER) instead of the world.
func is_in_view_model() -> bool:
	return _view_model_owner_id != 0

## Re-evaluates the view-model state right away (it is re-evaluated every frame while held anyway). The Player calls
## this when its view model is switched off or goes away.
func refresh_view_model() -> void:
	_update_view_model(get_holder() if holder_id != 0 and is_inside_tree() else null)

## The holding Player node on this peer, or null (on the floor, or the Player has not replicated here yet).
func get_holder() -> Player:
	if holder_id == 0:
		return null
	if is_instance_valid(_holder) and _holder.is_inside_tree() and not _holder.is_queued_for_deletion():
		return _holder
	_holder = null
	var mgr := get_manager()
	var p: Player = mgr.get_player(holder_id) if mgr != null else Game.get_player(holder_id)
	if p != null and p.is_inside_tree() and not p.is_queued_for_deletion():
		_holder = p
	return _holder

## The ItemManager this item lives under (World/Items), or null.
func get_manager() -> ItemManager:
	var mgr := get_parent() as ItemManager
	if mgr == null and Game.world != null and is_instance_valid(Game.world):
		mgr = Game.world.items
	return mgr

## The collider (StaticBody3D / Area3D on layer 4), or null.
func get_collider() -> CollisionObject3D:
	return get_node_or_null(collider_path) as CollisionObject3D

## The purely visual child ($Visual) that Juice effects animate (never the Interactable root, per the Juice rules).
func get_visual() -> Node3D:
	var v := get_node_or_null(^"Visual") as Node3D
	return v if v != null else self

## Applies type-specific values from spawn data (see ItemManager). Unknown keys are ignored. Subclasses override.
func apply_props(_props: Dictionary) -> void:
	pass

## Current type-specific values in spawn-data form (plain types only). Subclasses override.
func get_props() -> Dictionary:
	return {}

## SERVER ONLY. Sets the resting transform (the node moves right away unless the item is held).
## ItemManager.server_drop_item() uses this; prefer that API from stations.
func server_set_rest(new_position: Vector3, new_rotation: Vector3 = Vector3.ZERO) -> void:
	rest_position = new_position
	rest_rotation = new_rotation

# --- Interactable overrides -----------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	return "Pick up %s" % get_label_text()

func can_interact(player: Player) -> bool:
	if player == null:
		return false
	if is_flying():
		return false
	if holder_id == player.peer_id:
		# A repeated pickup request from the current holder (double press / LMB spam while the first request is
		# still in flight) is a harmless no-op (server_give_item returns true), never "Someone's carrying that.".
		return true
	if is_held():
		return false
	return _get_held_item_of(player) == null

func get_denied_reason(player: Player) -> String:
	if is_flying():
		return REASON_IN_THE_AIR
	if player != null and holder_id == player.peer_id:
		return ""
	if is_held():
		return "Someone's carrying that."
	if player != null and _get_held_item_of(player) != null:
		return "Hands full."
	return ""

func _server_interact(player: Player) -> void:
	var mgr := get_manager()
	if mgr != null:
		mgr.server_give_item(self, player.peer_id)

# --- Hooks for subclasses ----------------------------------------------------------------------------------------

## Refresh meshes/labels from the synced state. Called in _ready and whenever a synced value changes afterwards.
## Only called once the node is ready, so @onready references are valid.
func _refresh_visuals() -> void:
	pass

## Subclasses call this from their prop setters (after assigning) to refresh visuals + notify listeners.
func _notify_props_changed() -> void:
	if not is_node_ready():
		return
	_refresh_visuals()
	props_changed.emit()

# --- Internals ---------------------------------------------------------------------------------------------------

func _set_holder_id(value: int) -> void:
	value = maxi(value, 0)
	if value == holder_id:
		return
	var old := holder_id
	holder_id = value
	_holder = null
	_update_collision()
	if value == 0:
		_update_view_model(null)
		if not is_flying():
			_apply_rest_transform() # a thrown item keeps flying from where it was released
		_set_hidden_without_holder(false)
	elif is_inside_tree():
		_follow_holder()
	if not is_node_ready():
		return # initial spawn value: no effects
	_refresh_visuals()
	_play_holder_effects(old, value)
	holder_changed.emit(old, value)
	var mgr := get_parent() as ItemManager
	if mgr != null:
		mgr._on_item_holder_changed(self, old, value)

func _set_rest_position(value: Vector3) -> void:
	rest_position = value
	if holder_id == 0 and position != value:
		position = value

func _set_rest_rotation(value: Vector3) -> void:
	rest_rotation = value
	if holder_id == 0 and rotation != value:
		rotation = value

func _apply_rest_transform() -> void:
	if position != rest_position:
		position = rest_position
	if rotation != rest_rotation:
		rotation = rest_rotation

# --- M10 flight setters (idempotent, no rpc, effects only once ready; see the header) ---

func _set_flight_origin(value: Vector3) -> void:
	if value.is_finite():
		flight_origin = value

func _set_flight_velocity(value: Vector3) -> void:
	if value.is_finite():
		flight_velocity = value

func _set_flight_serial(value: int) -> void:
	value = maxi(value, 0)
	if value == flight_serial:
		return
	var was_flying := flight_serial != 0
	flight_serial = value
	_flight_time = 0.0
	_flight_checked_t = 0.0
	_update_collision()
	if value != 0:
		# Take off: out of any hand / view model, onto the arc from its origin.
		_update_view_model(null)
		_set_hidden_without_holder(false)
		position = flight_origin
		if is_node_ready() and is_inside_tree():
			Sfx.play(&"throw", global_position)
	else:
		if holder_id == 0:
			_apply_rest_transform()
		if is_node_ready() and is_inside_tree() and was_flying:
			# Landing (STYLE.md: drop / land): thud, bounce, a little dust.
			Sfx.play(&"drop", global_position)
			Juice.bounce(get_visual(), 0.3)
			Juice.puff(global_position, Juice.DUST, 5)
	if is_node_ready():
		flight_changed.emit(value != 0)

func _update_collision() -> void:
	var body := get_collider()
	if body == null:
		return
	body.collision_layer = 0 if (holder_id != 0 or flight_serial != 0) else Const.LAYER_ITEM
	body.collision_mask = 0

## Copies the holder's hand-socket transform (plus the per-item hold pose). Keeps the node's own scale
## (always 1 unless someone scales the root on purpose; Juice animates $Visual, not the root).
func _follow_holder() -> void:
	var holder := get_holder()
	if holder == null:
		# The holder's Player has not replicated to this peer yet (or just left): hide instead of floating.
		_set_hidden_without_holder(true)
		_update_view_model(null)
		return
	_set_hidden_without_holder(false)
	_update_view_model(holder)
	var socket := holder.get_item_socket()
	if socket == null or not socket.is_inside_tree():
		socket = holder
	var own_scale := scale
	global_transform = socket.global_transform * _get_hold_transform()
	scale = own_scale
	if _view_model_owner_id != 0:
		# Same instant, same camera state: the view-model camera copies %Camera right after the item snapped to it.
		holder.sync_view_model()

## Moves the item into `holder`'s view model if that is the local player with a view model, else back into the
## world. Cheap when nothing changes (called every frame while held).
func _update_view_model(holder: Player) -> void:
	var target: Player = holder if holder != null and holder.uses_view_model() else null
	var target_id := target.get_instance_id() if target != null else 0
	if target_id == _view_model_owner_id:
		return
	var previous: Player = null
	if _view_model_owner_id != 0:
		previous = instance_from_id(_view_model_owner_id) as Player
	_view_model_owner_id = target_id
	_apply_view_model_layers(target != null)
	if previous != null and is_instance_valid(previous):
		previous.remove_view_model_user(self)
	if target != null:
		target.add_view_model_user(self)

## on: every GeometryInstance3D below (internal Toonify outline hulls and Label3Ds included) renders on
## Player.VIEW_MODEL_LAYER only; off: back to the stored world layers. A node created while in the view model (a
## rebuilt outline hull copies its mesh's layers) has no stored value and gets the view-model bit stripped.
func _apply_view_model_layers(on: bool) -> void:
	for n in find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if on:
			if not gi.has_meta(META_WORLD_LAYERS):
				gi.set_meta(META_WORLD_LAYERS, gi.layers)
			gi.layers = Player.VIEW_MODEL_LAYER
		elif gi.has_meta(META_WORLD_LAYERS):
			gi.layers = int(gi.get_meta(META_WORLD_LAYERS))
			gi.remove_meta(META_WORLD_LAYERS)
		elif (gi.layers & Player.VIEW_MODEL_LAYER) != 0:
			var rest := gi.layers & ~Player.VIEW_MODEL_LAYER
			gi.layers = rest if rest != 0 else Player.WORLD_RENDER_LAYER

func _get_hold_transform() -> Transform3D:
	var euler := Vector3(deg_to_rad(hold_rotation_degrees.x), deg_to_rad(hold_rotation_degrees.y),
			deg_to_rad(hold_rotation_degrees.z))
	return Transform3D(Basis.from_euler(euler), hold_offset)

func _set_hidden_without_holder(hidden: bool) -> void:
	if hidden == _hidden_without_holder:
		return
	_hidden_without_holder = hidden
	visible = not hidden

func _play_holder_effects(old_holder: int, new_holder: int) -> void:
	if not is_inside_tree():
		return
	if new_holder != 0:
		if new_holder == multiplayer.get_unique_id():
			Sfx.play(&"pickup")
		else:
			Sfx.play(&"pickup", global_position)
	elif old_holder != 0 and is_flying():
		return # thrown: the "throw" sound came from the flight setter, the thud comes when it lands
	elif old_holder != 0:
		Sfx.play(&"drop", global_position)
	Juice.bounce(get_visual())

func _get_held_item_of(player: Player) -> Item:
	var mgr := get_manager()
	if mgr != null:
		return mgr.get_held_by(player.peer_id)
	return player.get_held_item()
