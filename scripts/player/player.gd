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
##
## First-person view model (LOCAL player only, built at runtime in _ready as the child "ViewModel"):
##   ViewModel (CanvasLayer, layer VIEW_MODEL_CANVAS_LAYER = -1: above the 3D world, below the HUD on layer 1)
##   ├─ Viewport (SubViewport: same World3D, transparent, sized/antialiased like the main viewport)
##   │  └─ Camera (Camera3D, cull mask = VIEW_MODEL_LAYER only, copies %Camera every frame)
##   └─ Screen (full-screen TextureRect, MOUSE_FILTER_IGNORE, premultiplied-alpha composite of Viewport)
## An item held by the local player moves every GeometryInstance3D under it to render layer 10 (VIEW_MODEL_LAYER,
## see Item._update_view_model), which %Camera's cull mask excludes: the world pass never draws it, the view-model
## pass draws nothing else, so it can never clip into walls or stations. Remote players' items stay on their world
## layers at %BodyHandSocket. Engine facts this relies on (checked in GL Compatibility and Forward+):
##   * a camera's cull mask also culls LIGHTS whose `layers` miss it, so every light %Camera sees gets the
##     view-model bit too (at spawn and for lights added later; removed again when this player leaves);
##   * shadow casters are culled by the rendering camera's mask as well, so the held item casts no shadow into the
##     world and receives none from it (only its own self-shadowing, in the tiny view-model pass): no double shadow
##     rendering, and the view-model pass is cheap (positional shadow atlas 0, far plane VIEW_MODEL_FAR);
##   * `transparent_bg` keeps the environment's background RGB, so the view-model camera uses a copy of the world
##     Environment with a black background (and without per-viewport screen-space effects).
## The SubViewport only renders while an item is registered (add_view_model_user); otherwise it is UPDATE_DISABLED
## and the Screen is hidden. The held item calls sync_view_model() right after snapping to %HandSocket
## (process priority 10), so camera and item always come from the same camera state within a frame.

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
## Remote players' tiny arms (model nodes Visual/Model/ArmL|ArmR, pivot at the shoulder): the right glove comes
## up to the item held at %BodyHandSocket, and both swing a little while walking.
const HOLD_ARM_ROTATION := Vector3(0.86, 0.11, 0.0)
const ARM_SWING: float = 0.3
## Render layer 10 ("view model", bit value 512): the LOCAL player's held item is drawn only on this layer, by the
## view-model pass. %Camera's cull mask excludes it (player.tscn + enforced in _ready).
const VIEW_MODEL_LAYER: int = 1 << 9
## Render layer an item's meshes use in the world (VisualInstance3D default); lights that light it light the view model.
const WORLD_RENDER_LAYER: int = 1
## Canvas layer of the view-model composite: above the 3D world, below the HUD (1), the ShopUI (5) and overlays.
const VIEW_MODEL_CANVAS_LAYER: int = -1
## View-model camera clip planes (metres). Held items sit about 0.4-1.3 m from the eye.
const VIEW_MODEL_NEAR: float = 0.01
const VIEW_MODEL_FAR: float = 4.0
## Meta on a Light3D this player shared with the view model: [original layers, original light_cull_mask].
const META_VIEW_MODEL_LIGHT: StringName = &"view_model_light"

## LOCAL player only: draw the held item in the first-person view model so it never clips into walls or stations.
## false puts held items back into the world pass (the old, clipping behaviour; e.g. for before/after captures).
var view_model_enabled: bool = true:
	set = set_view_model_enabled

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
@onready var arm_l: Node3D = get_node_or_null(^"Visual/Model/ArmL") as Node3D
@onready var arm_r: Node3D = get_node_or_null(^"Visual/Model/ArmR") as Node3D
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
var _hold_blend: float = 0.0
var _holding: bool = false
var _hold_check_left: float = 0.0
# First-person view model (local player only; see the header).
var _view_model: CanvasLayer = null
var _view_model_viewport: SubViewport = null
var _view_model_camera: Camera3D = null
var _view_model_screen: TextureRect = null
var _view_model_users: Dictionary = {}          # instance id -> WeakRef (items drawn in the view model)
var _view_model_active: bool = false            # the SubViewport renders (someone is registered)
var _view_model_closing: bool = false           # leaving the tree: uses_view_model() is false from now on
var _view_model_env_source: Environment = null  # the Environment the view-model copy was made from
var _view_model_env_ready: bool = false
var _view_model_lights: Array[WeakRef] = []     # lights this player added the view-model bit to

func _enter_tree() -> void:
	var id := str(name).to_int()
	if id > 0:
		peer_id = id
		set_multiplayer_authority(id, true)
	_is_local_cache = 1 if peer_id == multiplayer.get_unique_id() else 0
	add_to_group(Const.GROUP_PLAYERS)
	if _view_model != null:
		# Re-entering the tree (never done by the game, but keep the view model consistent if it happens).
		_view_model_closing = false
		_share_lights_with_view_model()

func _exit_tree() -> void:
	if _view_model == null:
		return
	# Held items leave the view model (their layers go back to the world ones) before this player is gone, and the
	# lights lose the view-model bit again. The ViewModel nodes themselves are children: freed with the player.
	_view_model_closing = true
	for item in _get_view_model_users():
		if item.has_method(&"refresh_view_model"):
			item.call(&"refresh_view_model")
	_view_model_users.clear()
	_set_view_model_active(false)
	_unshare_lights_with_view_model()

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
		_build_view_model()
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

## True if items held by this player should draw in the first-person view model: local player, view model built
## and enabled, player in the tree, and %Camera is the camera its viewport renders (while another camera is current,
## e.g. an overview camera, held items draw in the world like everything else). Items poll this every frame while
## held (Item._update_view_model).
func uses_view_model() -> bool:
	return view_model_enabled and _view_model != null and not _view_model_closing and is_inside_tree() \
			and not is_queued_for_deletion() and camera.is_current()

## The view-model SubViewport (ViewModel/Viewport), or null (remote players have none).
func get_view_model_viewport() -> SubViewport:
	return _view_model_viewport

## The view-model camera (ViewModel/Viewport/Camera), or null.
func get_view_model_camera() -> Camera3D:
	return _view_model_camera

## True while the view-model pass renders (an item is registered and the view model is enabled).
func is_view_model_active() -> bool:
	return _view_model_active

## Nodes currently drawn in this player's view model (normally the one held item).
func get_view_model_users() -> Array[Node]:
	return _get_view_model_users()

## Called by an item when it moved its meshes to VIEW_MODEL_LAYER for this player: the view-model pass renders.
func add_view_model_user(user: Node) -> void:
	if user == null or _view_model == null:
		return
	_view_model_users[user.get_instance_id()] = weakref(user)
	_refresh_view_model_active()
	sync_view_model()

## Called by an item when it went back to its world layers (dropped, handed over, freed).
func remove_view_model_user(user: Node) -> void:
	if user == null:
		return
	_view_model_users.erase(user.get_instance_id())
	_refresh_view_model_active()

## Copies %Camera (transform + projection) into the view-model camera and keeps the view-model Environment current.
## Held items call this right after they snapped to %HandSocket, so both come from the same camera state.
func sync_view_model() -> void:
	if _view_model_camera == null or not is_instance_valid(_view_model_camera):
		return
	var vm := _view_model_camera
	if camera.is_inside_tree() and vm.is_inside_tree():
		vm.global_transform = camera.global_transform
	if vm.projection != camera.projection:
		vm.projection = camera.projection
	if vm.fov != camera.fov:
		vm.fov = camera.fov
	if vm.size != camera.size:
		vm.size = camera.size
	if vm.keep_aspect != camera.keep_aspect:
		vm.keep_aspect = camera.keep_aspect
	if vm.h_offset != camera.h_offset:
		vm.h_offset = camera.h_offset
	if vm.v_offset != camera.v_offset:
		vm.v_offset = camera.v_offset
	if vm.frustum_offset != camera.frustum_offset:
		vm.frustum_offset = camera.frustum_offset
	if vm.attributes != camera.attributes:
		vm.attributes = camera.attributes
	var src := _view_model_environment_source()
	if not _view_model_env_ready or src != _view_model_env_source:
		_view_model_env_source = src
		_view_model_env_ready = true
		vm.environment = make_view_model_environment(src)

## Rebuilds the view-model Environment from the world's (call after changing the world Environment's properties
## at runtime; swapping the Environment resource itself is picked up automatically).
func refresh_view_model_environment() -> void:
	_view_model_env_ready = false
	sync_view_model()

func set_view_model_enabled(value: bool) -> void:
	if view_model_enabled == value:
		return
	view_model_enabled = value
	if _view_model == null:
		return
	if not value:
		for item in _get_view_model_users():
			if item.has_method(&"refresh_view_model"):
				item.call(&"refresh_view_model")
		_view_model_users.clear()
	_refresh_view_model_active()

## The view-model camera's Environment: a copy of `source` (the world's) with a black background, so the
## transparent SubViewport clears to (0, 0, 0, 0) and composites as premultiplied alpha, and without the effects
## that are per viewport and pointless (or wrong) on a transparent overlay: SSAO, SSIL, SSR, SDFGI, glow,
## volumetric fog. Ambient light taken from the background is converted so the item stays lit the same way.
static func make_view_model_environment(source: Environment) -> Environment:
	var env: Environment = source.duplicate() as Environment if source != null else Environment.new()
	if source != null and source.ambient_light_source == Environment.AMBIENT_SOURCE_BG:
		match source.background_mode:
			Environment.BG_SKY:
				env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			Environment.BG_COLOR:
				env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
				env.ambient_light_color = source.background_color
			Environment.BG_CLEAR_COLOR:
				env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
				env.ambient_light_color = RenderingServer.get_default_clear_color()
	if source != null and source.reflected_light_source == Environment.REFLECTION_SOURCE_BG \
			and source.background_mode == Environment.BG_SKY:
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.ssr_enabled = false
	env.sdfgi_enabled = false
	env.glow_enabled = false
	env.volumetric_fog_enabled = false
	return env

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
	elif _view_model != null:
		_refresh_view_model_active()
		if _view_model_active:
			_match_view_model_viewport()
			sync_view_model()

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
	_animate_arms(delta, amount)

func _animate_arms(delta: float, walk: float) -> void:
	if arm_l == null or arm_r == null:
		return
	_hold_check_left -= delta
	if _hold_check_left <= 0.0:
		_hold_check_left = 0.15
		_holding = get_held_item() != null
	_hold_blend = move_toward(_hold_blend, 1.0 if _holding else 0.0, delta * 5.0)
	var hold := _hold_blend * _hold_blend * (3.0 - 2.0 * _hold_blend)
	var swing := sin(_walk_phase) * ARM_SWING * walk
	arm_l.rotation = Vector3(swing, 0.0, 0.0)
	arm_r.rotation = Vector3(-swing, 0.0, 0.0).lerp(HOLD_ARM_ROTATION, hold)

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

# --- First-person view model (local player only) ----------------------------------------------------------------

func _build_view_model() -> void:
	if _view_model != null:
		return
	camera.cull_mask &= ~VIEW_MODEL_LAYER
	_view_model = CanvasLayer.new()
	_view_model.name = "ViewModel"
	_view_model.layer = VIEW_MODEL_CANVAS_LAYER
	_view_model_viewport = SubViewport.new()
	_view_model_viewport.name = "Viewport"
	_view_model_viewport.own_world_3d = false # render THIS world (lights, environment, items)
	_view_model_viewport.transparent_bg = true
	_view_model_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_view_model_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_view_model_viewport.positional_shadow_atlas_size = 0 # no omni/spot shadow atlas for a hand-held item
	_view_model_viewport.audio_listener_enable_3d = false
	_view_model_viewport.gui_disable_input = true
	_view_model_camera = Camera3D.new()
	_view_model_camera.name = "Camera"
	_view_model_camera.cull_mask = VIEW_MODEL_LAYER
	_view_model_camera.near = VIEW_MODEL_NEAR
	_view_model_camera.far = VIEW_MODEL_FAR
	_view_model_camera.fov = camera.fov
	_view_model_viewport.add_child(_view_model_camera)
	_view_model.add_child(_view_model_viewport)
	_view_model_screen = TextureRect.new()
	_view_model_screen.name = "Screen"
	_view_model_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view_model_screen.focus_mode = Control.FOCUS_NONE
	_view_model_screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view_model_screen.stretch_mode = TextureRect.STRETCH_SCALE
	_view_model_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var composite := CanvasItemMaterial.new()
	composite.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	_view_model_screen.material = composite
	_view_model_screen.visible = false
	_view_model.add_child(_view_model_screen)
	add_child(_view_model)
	_view_model_camera.current = true # current in the SubViewport only; %Camera stays current in the main one
	_view_model_screen.texture = _view_model_viewport.get_texture()
	_match_view_model_viewport()
	sync_view_model()
	_share_lights_with_view_model()

func _get_view_model_users() -> Array[Node]:
	var out: Array[Node] = []
	for id: int in _view_model_users.keys():
		var node := (_view_model_users[id] as WeakRef).get_ref() as Node
		if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
			_view_model_users.erase(id)
		else:
			out.append(node)
	return out

func _refresh_view_model_active() -> void:
	var active := uses_view_model() and not _get_view_model_users().is_empty()
	_set_view_model_active(active)

func _set_view_model_active(active: bool) -> void:
	if _view_model_viewport == null or not is_instance_valid(_view_model_viewport):
		_view_model_active = false
		return
	if active == _view_model_active:
		return
	_view_model_active = active
	if active:
		_match_view_model_viewport()
	_view_model_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	_view_model_screen.visible = active

## The view-model SubViewport renders at the main viewport's 3D resolution with its antialiasing / scaling
## settings (checked every frame while active: window resizes, graphics option changes).
func _match_view_model_viewport() -> void:
	var sv := _view_model_viewport
	var main := get_viewport()
	if sv == null or main == null or main == sv:
		return
	var want := _main_render_size(main)
	if sv.size != want:
		sv.size = want
	if sv.msaa_3d != main.msaa_3d:
		sv.msaa_3d = main.msaa_3d
	if sv.screen_space_aa != main.screen_space_aa:
		sv.screen_space_aa = main.screen_space_aa
	if sv.scaling_3d_mode != main.scaling_3d_mode:
		sv.scaling_3d_mode = main.scaling_3d_mode
	if sv.scaling_3d_scale != main.scaling_3d_scale:
		sv.scaling_3d_scale = main.scaling_3d_scale
	if sv.fsr_sharpness != main.fsr_sharpness:
		sv.fsr_sharpness = main.fsr_sharpness
	if sv.texture_mipmap_bias != main.texture_mipmap_bias:
		sv.texture_mipmap_bias = main.texture_mipmap_bias
	if sv.anisotropic_filtering_level != main.anisotropic_filtering_level:
		sv.anisotropic_filtering_level = main.anisotropic_filtering_level
	if sv.mesh_lod_threshold != main.mesh_lod_threshold:
		sv.mesh_lod_threshold = main.mesh_lod_threshold
	if sv.use_debanding != main.use_debanding:
		sv.use_debanding = main.use_debanding

## Pixel size the main viewport renders 3D at: the window size (stretch mode canvas_items / disabled), the base
## size (stretch mode viewport), or a parent SubViewport's size.
static func _main_render_size(main: Viewport) -> Vector2i:
	var size := Vector2i.ONE
	var window := main as Window
	if window != null:
		if window.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT:
			size = Vector2i(main.get_visible_rect().size)
		else:
			size = window.size
	elif main is SubViewport:
		size = (main as SubViewport).size
	else:
		size = Vector2i(main.get_visible_rect().size)
	return size.max(Vector2i.ONE)

func _view_model_environment_source() -> Environment:
	if camera.environment != null:
		return camera.environment
	var w := get_world_3d() if is_inside_tree() else null
	if w == null:
		return null
	return w.environment if w.environment != null else w.fallback_environment

## Every light %Camera sees also lights the view model (a camera's cull mask culls lights by their `layers`).
func _share_lights_with_view_model() -> void:
	if not is_inside_tree():
		return
	for n in get_tree().root.find_children("*", "Light3D", true, false):
		_share_light(n as Light3D)
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)

func _share_light(light: Light3D) -> void:
	if light == null or light.has_meta(META_VIEW_MODEL_LIGHT) or not light.is_inside_tree():
		return
	if light.get_world_3d() != get_world_3d() or (light.layers & camera.cull_mask) == 0:
		return # another world, or a light the player's camera does not see anyway
	light.set_meta(META_VIEW_MODEL_LIGHT, [light.layers, light.light_cull_mask])
	light.layers |= VIEW_MODEL_LAYER
	if (light.light_cull_mask & WORLD_RENDER_LAYER) != 0:
		light.light_cull_mask |= VIEW_MODEL_LAYER
	_view_model_lights.append(weakref(light))

func _unshare_lights_with_view_model() -> void:
	if is_inside_tree() and get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)
	for ref in _view_model_lights:
		var light := ref.get_ref() as Light3D
		if light == null or not is_instance_valid(light) or not light.has_meta(META_VIEW_MODEL_LIGHT):
			continue
		var original: Array = light.get_meta(META_VIEW_MODEL_LIGHT)
		light.remove_meta(META_VIEW_MODEL_LIGHT)
		if (int(original[0]) & VIEW_MODEL_LAYER) == 0:
			light.layers &= ~VIEW_MODEL_LAYER
		if (int(original[1]) & VIEW_MODEL_LAYER) == 0:
			light.light_cull_mask &= ~VIEW_MODEL_LAYER
	_view_model_lights.clear()

func _on_tree_node_added(node: Node) -> void:
	if node is Light3D and not _view_model_closing:
		_share_light(node as Light3D)
