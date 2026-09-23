class_name Player
extends CharacterBody3D
## Networked first-person player. Node name == peer id as string. Movement authority = owning peer.
##
## Required unique-named children in player.tscn:
##   %Camera (Camera3D)          - first-person camera (under $Head), current only for the local player
##   %HandSocket (Node3D)        - under %Camera; where the local player's held item is drawn
##   %BodyHandSocket (Node3D)    - in front of the chest; where OTHER players see this player's held item
##   %Interactor (Interactor)    - script res://scripts/interaction/interactor.gd (direct child of Player)
##   %NameLabel (Label3D)        - hidden for the local player
##
## Sync design: the owning peer simulates movement and writes net_position / net_yaw / net_pitch every physics
## tick; $Sync (MultiplayerSynchronizer, authority = owner) sends them unreliably at ~30 Hz (ALWAYS mode, so
## late joiners get them too) and `crouching` reliably on change. Every other peer smooths the node itself
## toward those values in _process (snaps if more than SNAP_DISTANCE away), so global_position of a remote
## player is always a smooth, current-ish value (used by server-side range checks and held items).
## Players process before items (process priority -10) so held items read up-to-date socket transforms.

const STAND_HEIGHT: float = 1.8
const CROUCH_HEIGHT: float = 1.2
const STAND_CAMERA_Y: float = 1.6
const CROUCH_CAMERA_Y: float = 1.05
const STAND_LABEL_Y: float = 2.2
const STAND_BODY_SOCKET_Y: float = 1.0
const MAX_PITCH: float = PI * 89.0 / 180.0
const FALL_LIMIT_Y: float = -20.0
const GROUND_ACCEL: float = 45.0
const AIR_ACCEL: float = 12.0
const CROUCH_BLEND_SPEED: float = 9.0
## Remote smoothing rate (1/s). Higher = snappier, lower = smoother.
const REMOTE_SMOOTHING: float = 16.0
## Remote players further than this from their synced position teleport instead of sliding.
const SNAP_DISTANCE: float = 3.0
## How much of the head pitch the cartoon face follows on remote players.
const FACE_PITCH_FACTOR: float = 0.35


var peer_id: int = 1
var display_name: String = "Player"
var player_color: Color = Color.WHITE
## Which room spawn point this player uses (set by World when spawning, used for respawns).
var spawn_index: int = 0

# --- Synced by $Sync (authority = owning peer) ---
var net_position: Vector3 = Vector3.ZERO:
	set(value):
		net_position = value
		_has_net_state = true
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var crouching: bool = false:
	set = _set_crouching

@onready var camera: Camera3D = %Camera
@onready var head: Node3D = $Head
@onready var collision: CollisionShape3D = $Collision
@onready var visual: Node3D = $Visual
# Visual (walk bounce/sway + crouch squash) holds the Blender body Visual/Model (art/models/player.glb, a
# Toonify root: its TINT parts take the player colour) and Visual/Face, a pivot at the head centre that tilts
# with the look pitch and carries the ToonFace prop (Visual/Face/ToonFace, art/props/face.tscn, sad mood).
@onready var face: Node3D = $Visual/Face
@onready var body_model: Toonify = get_node_or_null(^"Visual/Model") as Toonify
@onready var name_label: Label3D = %NameLabel
@onready var hand_socket: Node3D = %HandSocket
@onready var body_hand_socket: Node3D = %BodyHandSocket
@onready var sync: MultiplayerSynchronizer = $Sync

var _is_local_cache: int = -1 # -1 unknown, 0 remote, 1 local (fixed once the node is in the tree)
var _has_net_state: bool = false # net_* were set (spawn function, spawn state or a sync packet)
var _awaiting_first_sync: bool = false # remote: snap (not slide) to the first synced position
var _spawn_net_position: Vector3 = Vector3.ZERO
var _gravity: float = 9.8
var _shape: CapsuleShape3D = null
var _crouch_blend: float = 0.0
var _walk_phase: float = 0.0
var _visual_speed: float = 0.0
var _last_visual_pos: Vector3 = Vector3.ZERO

func _enter_tree() -> void:
	var id := str(name).to_int()
	if id > 0:
		peer_id = id
		set_multiplayer_authority(id, true)
	_is_local_cache = 1 if peer_id == multiplayer.get_unique_id() else 0
	add_to_group(Const.GROUP_PLAYERS)

func _ready() -> void:
	process_priority = -10
	process_physics_priority = -10
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	# Per-instance collision shape (the scene's sub-resource is shared between all players).
	var base_shape := collision.shape as CapsuleShape3D
	_shape = base_shape.duplicate() as CapsuleShape3D if base_shape != null else CapsuleShape3D.new()
	collision.shape = _shape
	_apply_shape()
	_crouch_blend = 1.0 if crouching else 0.0
	_apply_crouch_visuals()
	_last_visual_pos = position
	_apply_appearance()
	if is_local():
		camera.current = true
		name_label.visible = false
		# Hide our own body from our camera but keep its shadow.
		for gi in visual.find_children("*", "GeometryInstance3D", true, false):
			(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	else:
		camera.current = false
		if _has_net_state:
			# Start exactly where the owner is (spawn function / spawn state set net_*).
			position = net_position
			rotation.y = net_yaw
			head.rotation.x = net_pitch
		else:
			_write_net_state()
		# A late joiner spawns other clients' players at their ORIGINAL spawn point (spawn data); the owner's
		# first sync packet then carries the real position: jump there instead of sliding across the room.
		_awaiting_first_sync = true
		_spawn_net_position = net_position
	Net.players_changed.connect(_on_players_changed)

# --- Public API ---------------------------------------------------------------------------------------------

func is_local() -> bool:
	if _is_local_cache < 0:
		if not is_inside_tree():
			return false
		_is_local_cache = 1 if peer_id == multiplayer.get_unique_id() else 0
	return _is_local_cache == 1

## The socket a held item should follow on THIS peer: %HandSocket (camera child) for the local player,
## %BodyHandSocket for everyone else. Its global_transform is current every frame.
func get_item_socket() -> Node3D:
	if is_local():
		return hand_socket if hand_socket != null else get_node("%HandSocket") as Node3D
	return body_hand_socket if body_hand_socket != null else get_node("%BodyHandSocket") as Node3D

func get_held_item() -> Item:
	if Game.world == null or not is_instance_valid(Game.world) or Game.world.items == null:
		return null
	return Game.world.items.get_held_by(peer_id)

func get_interactor() -> Interactor:
	return get_node_or_null("%Interactor") as Interactor

## Where this player is looking (camera forward), any peer.
func get_look_direction() -> Vector3:
	var cam: Camera3D = camera if camera != null else get_node("%Camera") as Camera3D
	return -cam.global_basis.z

## Places the player (position + yaw) without physics. Works before entering the tree (spawn function).
func place_at(xform: Transform3D) -> void:
	position = xform.origin
	rotation = Vector3(0.0, xform.basis.orthonormalized().get_euler().y, 0.0)
	velocity = Vector3.ZERO
	net_position = position
	net_yaw = rotation.y
	net_pitch = 0.0
	if head != null:
		head.rotation.x = 0.0

## SERVER (or owner): moves this player to `xform` on its owning peer (movement is owner-authoritative,
## so the server must ask the owner to teleport; setting position on the server would be overwritten).
func server_teleport(xform: Transform3D) -> void:
	if is_local():
		_teleport_local(xform)
	elif multiplayer.is_server():
		_rpc_teleport.rpc_id(peer_id, xform)

## Owner only: applies a mouse-look delta in screen pixels (yaw on the body, pitch on the head, +-89 deg).
func apply_look_input(relative: Vector2) -> void:
	var sens: float = Config.balance.mouse_sensitivity
	rotate_y(-relative.x * sens)
	head.rotation.x = clampf(head.rotation.x - relative.y * sens, -MAX_PITCH, MAX_PITCH)

## Owner only: back to this player's spawn point.
func respawn() -> void:
	if is_local():
		_teleport_local(_get_spawn_transform())

# --- Local simulation ---------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# _input (not _unhandled_input) so full-screen HUD controls can never swallow mouse look.
	if not is_local() or not _input_enabled():
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			apply_look_input(motion.screen_relative)
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# Clicking back into the game window recaptures the mouse (e.g. after alt-tab).
		Game.refresh_mouse_mode()

func _physics_process(delta: float) -> void:
	if not is_local():
		return
	var can_move := _input_enabled()
	if not is_on_floor():
		velocity.y -= _gravity * delta

	var want_crouch := can_move and Input.is_action_pressed(&"crouch")
	if want_crouch and not crouching:
		crouching = true
	elif not want_crouch and crouching and _can_stand_up():
		crouching = false

	if can_move and Input.is_action_just_pressed(&"jump") and is_on_floor() and not crouching:
		velocity.y = Config.balance.jump_velocity

	var input_dir := Vector2.ZERO
	if can_move:
		input_dir = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var wish := global_basis * Vector3(input_dir.x, 0.0, input_dir.y)
	wish.y = 0.0
	wish = wish.normalized() * minf(input_dir.length(), 1.0)
	var target := wish * _current_speed(can_move)
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL
	var horizontal := Vector2(velocity.x, velocity.z).move_toward(Vector2(target.x, target.z), accel * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.y
	move_and_slide()

	if global_position.y < FALL_LIMIT_Y:
		_teleport_local(_get_spawn_transform())
	_write_net_state()

func _process(delta: float) -> void:
	if not is_local():
		_smooth_remote(delta)
	var target_blend := 1.0 if crouching else 0.0
	if not is_equal_approx(_crouch_blend, target_blend):
		_crouch_blend = move_toward(_crouch_blend, target_blend, CROUCH_BLEND_SPEED * delta)
		_apply_crouch_visuals()
	if not is_local():
		_animate_body(delta)

func _input_enabled() -> bool:
	return not Game.is_ui_locked()

func _current_speed(can_move: bool) -> float:
	if crouching:
		return Config.balance.crouch_speed
	if can_move and Input.is_action_pressed(&"sprint"):
		return Config.balance.sprint_speed
	return Config.balance.walk_speed

func _write_net_state() -> void:
	net_position = position
	net_yaw = rotation.y
	net_pitch = head.rotation.x

func _teleport_local(xform: Transform3D) -> void:
	place_at(xform)
	_write_net_state()

func _get_spawn_transform() -> Transform3D:
	var w: World = Game.world
	if w != null and is_instance_valid(w) and w.room != null:
		var xf: Transform3D = w.room.get_spawn_transform(spawn_index)
		var parent_3d := get_parent() as Node3D
		return parent_3d.global_transform.affine_inverse() * xf if parent_3d != null else xf
	return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))

func _can_stand_up() -> bool:
	if not is_inside_tree():
		return true
	var probe := CapsuleShape3D.new()
	probe.radius = _shape.radius * 0.9
	probe.height = STAND_HEIGHT - 0.1
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = probe
	params.transform = Transform3D(Basis.IDENTITY, global_position + Vector3(0.0, STAND_HEIGHT * 0.5 + 0.05, 0.0))
	params.collision_mask = collision_mask
	params.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(params, 1).is_empty()

@rpc("any_peer", "call_remote", "reliable")
func _rpc_teleport(xform: Transform3D) -> void:
	# The node's authority is its owner, so server->owner calls are any_peer + sender check.
	if multiplayer.get_remote_sender_id() != Const.SERVER_PEER_ID or not is_local():
		return
	_teleport_local(xform)

# --- Remote smoothing / visuals ---------------------------------------------------------------------------------

func _smooth_remote(delta: float) -> void:
	var snap := position.distance_to(net_position) > SNAP_DISTANCE
	if _awaiting_first_sync and not net_position.is_equal_approx(_spawn_net_position):
		_awaiting_first_sync = false
		snap = true
	if snap:
		position = net_position
		rotation.y = net_yaw
		head.rotation.x = net_pitch
	else:
		var t := 1.0 - exp(-REMOTE_SMOOTHING * delta)
		position = position.lerp(net_position, t)
		rotation.y = lerp_angle(rotation.y, net_yaw, t)
		head.rotation.x = lerp_angle(head.rotation.x, net_pitch, t)
	face.rotation.x = head.rotation.x * FACE_PITCH_FACTOR

## Bouncy walk for remote players (the local body is not visible to its owner).
func _animate_body(delta: float) -> void:
	var moved := position - _last_visual_pos
	_last_visual_pos = position
	moved.y = 0.0
	var speed := moved.length() / maxf(delta, 0.0001)
	_visual_speed = lerpf(_visual_speed, speed, 1.0 - exp(-10.0 * delta))
	if _visual_speed > 0.4:
		_walk_phase = fmod(_walk_phase + delta * (6.0 + _visual_speed * 1.6), TAU)
	else:
		_walk_phase = move_toward(_walk_phase, 0.0 if _walk_phase < PI else TAU, delta * 8.0)
	var amount := clampf(_visual_speed / Config.balance.walk_speed, 0.0, 1.0)
	visual.position.y = absf(sin(_walk_phase)) * 0.08 * amount
	visual.rotation.z = sin(_walk_phase) * 0.06 * amount

func _set_crouching(value: bool) -> void:
	if crouching == value:
		return
	crouching = value
	if is_node_ready():
		_apply_shape()

func _apply_shape() -> void:
	if _shape == null:
		return
	_shape.height = CROUCH_HEIGHT if crouching else STAND_HEIGHT
	collision.position.y = _shape.height * 0.5

func _apply_crouch_visuals() -> void:
	var squash := lerpf(1.0, CROUCH_HEIGHT / STAND_HEIGHT, _crouch_blend)
	visual.scale = Vector3(lerpf(1.0, 1.08, _crouch_blend), squash, lerpf(1.0, 1.08, _crouch_blend))
	head.position.y = lerpf(STAND_CAMERA_Y, CROUCH_CAMERA_Y, _crouch_blend)
	name_label.position.y = STAND_LABEL_Y * squash
	body_hand_socket.position.y = STAND_BODY_SOCKET_Y * squash

func _apply_appearance() -> void:
	name_label.text = display_name
	name_label.modulate = player_color.lightened(0.2)
	if body_model != null:
		body_model.tint = Toon.grade(player_color) # recolours the model's TINT_* parts (shared, cached)

func _on_players_changed() -> void:
	if not Net.players.has(peer_id):
		return
	var new_name := Net.get_player_name(peer_id)
	var new_color := Net.get_player_color(peer_id)
	if new_name != display_name or new_color != player_color:
		display_name = new_name
		player_color = new_color
		_apply_appearance()
