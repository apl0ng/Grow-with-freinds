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

## Emitted on every peer when the holder changes after the item spawned (0 = on the floor).
signal holder_changed(old_holder: int, new_holder: int)
## Emitted on every peer when a type-specific synced value (charges, strain, amount) changes after spawn.
signal props_changed

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

var _holder: Player = null
var _hidden_without_holder: bool = false
## Cached in _ready: items always belong to the server and never change authority. Caching avoids querying the
## multiplayer peer every frame (errors spam if the ENet peer is already closed, e.g. the host just quit).
var _is_authority: bool = false

func _enter_tree() -> void:
	super()
	add_to_group(Const.GROUP_ITEMS)

func _ready() -> void:
	# Held items are placed after the players moved this frame (players process at priority -10).
	process_priority = 10
	_is_authority = is_multiplayer_authority()
	_update_collision()
	if is_held():
		_follow_holder()
	else:
		_apply_rest_transform()
	_refresh_visuals()
	Juice.pop_in(get_visual())
	var mgr := get_manager()
	if mgr != null:
		mgr._on_item_ready(self)

func _exit_tree() -> void:
	var mgr := get_parent() as ItemManager
	if mgr != null:
		mgr._on_item_exiting(self)

func _process(_delta: float) -> void:
	if holder_id != 0:
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
	if holder_id == player.peer_id:
		# A repeated pickup request from the current holder (double press / LMB spam while the first request is
		# still in flight) is a harmless no-op (server_give_item returns true), never "Someone is holding this".
		return true
	if is_held():
		return false
	return _get_held_item_of(player) == null

func get_denied_reason(player: Player) -> String:
	if player != null and holder_id == player.peer_id:
		return ""
	if is_held():
		return "Someone is holding this"
	if player != null and _get_held_item_of(player) != null:
		return "Hands full"
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
		_apply_rest_transform()
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

func _update_collision() -> void:
	var body := get_collider()
	if body == null:
		return
	body.collision_layer = 0 if holder_id != 0 else Const.LAYER_ITEM
	body.collision_mask = 0

## Copies the holder's hand-socket transform (plus the per-item hold pose). Keeps the node's own scale
## (always 1 unless someone scales the root on purpose; Juice animates $Visual, not the root).
func _follow_holder() -> void:
	var holder := get_holder()
	if holder == null:
		# The holder's Player has not replicated to this peer yet (or just left): hide instead of floating.
		_set_hidden_without_holder(true)
		return
	_set_hidden_without_holder(false)
	var socket := holder.get_item_socket()
	if socket == null or not socket.is_inside_tree():
		socket = holder
	var own_scale := scale
	global_transform = socket.global_transform * _get_hold_transform()
	scale = own_scale

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
	elif old_holder != 0:
		Sfx.play(&"drop", global_position)
	Juice.bounce(get_visual())

func _get_held_item_of(player: Player) -> Item:
	var mgr := get_manager()
	if mgr != null:
		return mgr.get_held_by(player.peer_id)
	return player.get_held_item()
