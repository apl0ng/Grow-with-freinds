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
##
## M10 physical comedy (physics agent):
##   * Workers collide with each other: collision_mask = world | player (enforced in _ready). Remote bodies are
##     kinematic and moved by their synced pose, so only the LOCAL body slides / depenetrates. _can_stand_up() probes
##     static geometry only, so a crouched worker under another one never stays stuck.
##   * Stagger: apply_stagger(impulse, stun_sec) on the OWNER adds the impulse (plus a small hop), ignores movement
##     input until the stun passes (is_stunned()), kicks the camera (roll +-CAMERA_KICK_ROLL_DEG, a pitch nudge) and
##     bounces the body. The server never moves a player itself: server_shove() sends _rpc_staggered to the target's
##     owner (any_peer + "sender is the server" check, because players have owner authority). The owner then broadcasts
##     the cosmetic _rpc_stagger_fx (any_peer, call_local, reliable; accepted from the server or the node's owner
##     only), which plays "shove" / "bonk", bounces the body and emits `staggered(by_peer)` on EVERY peer.
##   * Shove: request_shove(target_peer) -> _rpc_request_shove on the server (sender must own this node): validates
##     back room, stun, range (shove_range + 1 m slack, NaN-safe), per-shover cooldown; from behind (target facing .
##     push direction > 0.5) the target's held item is released first.
##   * Footsteps: remote bodies play "step" at the feet when the walk phase crosses 0 / PI while moving; the local body
##     plays a quiet 2D "step" per stride walked on the floor. Never while airborne, stunned or in the back room.
##     `footstep(position)` is emitted for every step this peer played (test hook).

## M10: every peer, after a stagger (shove or a thrown item) landed on this worker. by_peer = who did it.
signal staggered(by_peer: int)
## M10: this peer played a footstep for this worker (position = the feet). Test hook.
signal footstep(position: Vector3)

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
## M10 stagger: small upward hop added to every stagger impulse (m/s).
const STAGGER_HOP: float = 1.5
## M10 stagger: horizontal deceleration while stunned (m/s^2); the stumble carries instead of braking at GROUND_ACCEL.
const STAGGER_FRICTION: float = 6.0
## M10 stagger camera kick: roll (degrees, sign = away from the push), pitch nudge (degrees), total duration (s).
const CAMERA_KICK_ROLL_DEG: float = 6.0
const CAMERA_KICK_PITCH_DEG: float = 2.5
const CAMERA_KICK_SEC: float = 0.35
## Footsteps (M14): metres on the floor per step. At 4.5 m/s walking that is about 2.8 steps a second, 3 sprinting and
## 2 crouched: a human cadence (M10 played six a second walking and almost twelve sprinting). Remote bodies use the
## same strides on their smoothed movement.
const STEP_STRIDE_WALK: float = 1.6
const STEP_STRIDE_SPRINT: float = 2.3
const STEP_STRIDE_CROUCH: float = 1.2
## Step variants (never the same twice in a row) and volume offsets in dB for a crouched and a sprinting step.
const STEP_SOUNDS: Array[StringName] = [&"step", &"step2", &"step3"]
const STEP_CROUCH_DB: float = -7.0
const STEP_SPRINT_DB: float = 2.0
## A fall faster than this (m/s) ends with a thud.
const LAND_MIN_SPEED: float = 2.5
## Remote bodies below this smoothed speed (m/s) are standing: no walk cycle, no steps (same threshold as the bob).
const WALK_ANIM_MIN_SPEED: float = 0.4
## Chest height above the feet (m), standing / crouched: where thrown items hit and where the Boss looks.
const CHEST_HEIGHT_STANDING: float = 1.0
const CHEST_HEIGHT_CROUCHED: float = 0.6
## Another body closer than this (horizontally) counts as sitting on the same spot; the local body steps this far
## aside first so the collision recovery separates the two sideways instead of stacking them.
const COINCIDENT_DISTANCE: float = 0.03
const COINCIDENT_NUDGE: float = 0.08
## M11 review: after a stagger's stun ends the worker cannot be staggered again for this long (server rule, see
## can_be_staggered()). Without it a bundle re-thrown from 1.5 m, or two shovers taking turns, kept a worker stunned
## 100 % of the time with no counter; with it the uptime is at most stun / (stun + immunity), about a third.
const STAGGER_IMMUNITY_SEC: float = 1.0

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
# Non-finite values (NaN / inf from a buggy or hostile owner) are ignored: every peer keeps the last valid pose.
var net_position: Vector3 = Vector3.ZERO:
	set(value):
		if not value.is_finite():
			return
		net_position = value
		_has_net_state = true
var net_yaw: float = 0.0:
	set(value):
		if is_finite(value):
			net_yaw = value
var net_pitch: float = 0.0:
	set(value):
		if is_finite(value):
			net_pitch = clampf(value, -MAX_PITCH, MAX_PITCH)
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
# M10 physical (see the header). The stun clock is set by apply_stagger (owner), by the cosmetic fx RPC (every peer,
# so remote bodies skip footsteps while stumbling) and by the server when it staggers this player.
var _stun_until_msec: int = 0
var _stagger_immune_until_msec: int = 0         # SERVER: until when this worker cannot be staggered again (M11)
var _shove_ready_msec: int = 0                  # SERVER: when this worker may shove again (per-shover cooldown)
var _stride_accum: float = 0.0                  # local: metres walked on the floor since the last step
var _kick_tween: Tween = null                   # local camera kick

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
	# M10: workers collide with the room AND with each other (the scene says so too; enforced here).
	collision_layer = Const.LAYER_PLAYER
	collision_mask = Const.LAYER_WORLD | Const.LAYER_PLAYER
	# Only the room is a moving platform. Remote bodies are kinematic colliders that jump to their synced position in
	# one physics tick (a back-room send / release, a reset): a worker standing on one must not inherit that jump as
	# platform velocity (QA 10.8 saw the host carried 6-8 m across the floor); it simply drops where it stood.
	platform_floor_layers = Const.LAYER_WORLD
	platform_wall_layers = 0
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
	_emotes_ready() # M18 emotes
	_hats_ready() # M16 hats

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

# --- M10: stagger / shove -----------------------------------------------------------------------------------------

## True while this worker is stumbling: movement input is ignored, no footsteps, no shoving or throwing. Set on the
## owner by apply_stagger(); other peers (and the server) mirror it from the stagger they saw.
func is_stunned() -> bool:
	return Time.get_ticks_msec() < _stun_until_msec

## SERVER view (M11): false while this worker is stunned and for STAGGER_IMMUNITY_SEC after; a shove or a thrown item
## that reaches them meanwhile does nothing (the item still drops at their feet).
func can_be_staggered() -> bool:
	return Time.get_ticks_msec() >= _stagger_immune_until_msec

## OWNER (or an unowned body on the host): a stumble. `impulse` is added to the velocity (its horizontal part, plus
## a STAGGER_HOP hop), movement input is ignored for `stun_sec`, the camera gets a kick and the body bounces.
## Non-finite values are ignored.
func apply_stagger(impulse: Vector3, stun_sec: float) -> void:
	if not impulse.is_finite() or not is_finite(stun_sec):
		return
	var push := Vector3(impulse.x, 0.0, impulse.z)
	velocity += push + Vector3.UP * STAGGER_HOP
	_stun_until_msec = maxi(_stun_until_msec, Time.get_ticks_msec() + int(maxf(stun_sec, 0.0) * 1000.0))
	if is_local():
		_camera_kick(push)
	if visual != null:
		Juice.bounce(visual, 0.25)

## LOCAL player: asks the server to shove `target_peer` (the Interactor calls this on the "shove" action).
func request_shove(target_peer: int) -> void:
	if not is_local() or target_peer <= 0 or target_peer == peer_id:
		return
	_rpc_request_shove.rpc_id(Const.SERVER_PEER_ID, target_peer)

## SERVER ONLY. This worker shoves `target`: `direction` (horizontal) * shove_impulse, shove_stun_sec (or `stun_sec`
## when >= 0, e.g. hit_stun_sec for a thrown item); from behind the target's held item is released first. The
## target's owner receives _rpc_staggered and does the actual stumble (movement is owner-authoritative); the
## cosmetic broadcast then fires `staggered` on every peer. `hit` = a thrown item (bonk) rather than a shove.
func server_shove(target: Player, direction: Vector3, from_behind: bool, stun_sec: float = -1.0, hit: bool = false) -> void:
	Player.server_stagger(target, direction, from_behind, peer_id, stun_sec, hit)

## SERVER ONLY. Staggers `target` on behalf of `by_peer` (0 = nobody, e.g. an item thrown by a worker who left).
## See server_shove(). Works for the host's own player and for bodies without a connected owner (tests).
static func server_stagger(target: Player, direction: Vector3, from_behind: bool, by_peer: int,
		stun_sec: float = -1.0, hit: bool = false) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree() or target.is_queued_for_deletion():
		return
	if not target.multiplayer.is_server():
		push_error("Player.server_stagger called on a client")
		return
	if not target.can_be_staggered():
		return # M11: still stunned, or inside the immunity window after the last stagger
	var flat := Vector3(direction.x, 0.0, direction.z)
	if not flat.is_finite() or flat.length_squared() < 0.000001:
		flat = target.get_flat_forward() * -1.0 # straight at them from the front
	flat = flat.normalized()
	var stun := stun_sec if stun_sec >= 0.0 else Config.balance.shove_stun_sec
	var impulse := flat * Config.balance.shove_impulse
	if from_behind:
		var mgr := ItemManager.find(target)
		if mgr != null and mgr.get_held_by(target.peer_id) != null:
			mgr.server_release_holder(target.peer_id)
	# The server's own view of the stun (shove / throw validation, remote footsteps) and of the immunity that follows.
	var now := Time.get_ticks_msec()
	target._stun_until_msec = maxi(target._stun_until_msec, now + int(stun * 1000.0))
	target._stagger_immune_until_msec = maxi(target._stagger_immune_until_msec, now + int((stun + STAGGER_IMMUNITY_SEC) * 1000.0))
	if target.is_local():
		target._stagger_locally(impulse, stun, by_peer, hit)
	elif target.multiplayer.get_peers().has(target.peer_id):
		target._rpc_staggered.rpc_id(target.peer_id, impulse, stun, by_peer, hit)
	else:
		# A body without a connected owner (host-side fake worker in tests): nobody else can stumble it.
		target._stagger_locally(impulse, stun, by_peer, hit)

## Horizontal facing (body yaw), unit length; Vector3.FORWARD if the transform is broken.
func get_flat_forward() -> Vector3:
	var f := -global_basis.z
	f.y = 0.0
	if not f.is_finite() or f.length_squared() < 0.000001:
		return Vector3.FORWARD
	return f.normalized()

## Where a thrown item hits this worker (and where the Boss looks): feet + chest height, crouch-aware.
func get_chest_position() -> Vector3:
	return global_position + Vector3.UP * (CHEST_HEIGHT_CROUCHED if crouching else CHEST_HEIGHT_STANDING)

@rpc("any_peer", "call_local", "reliable")
func _rpc_request_shove(target_peer: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	if sender != peer_id or not is_inside_tree():
		return # a shove request is only valid on the shover's own node
	var b: BalanceConfig = Config.balance
	if is_stunned() or GameState.is_in_backroom(peer_id):
		return
	var target: Player = Game.get_player(target_peer)
	if target == null or target == self or not target.is_inside_tree() or GameState.is_in_backroom(target_peer):
		return
	var d := global_position.distance_to(target.global_position)
	# `not <=`: a NaN position (broken sync) is never in range.
	if not (d <= b.shove_range + 1.0):
		return
	if not target.can_be_staggered():
		return # M11: the target is still stumbling / immune; the shove is not spent (no cooldown)
	# M11: the line between the two chests must be clear on LAYER_WORLD (the client's own ray stops at walls and
	# fences; a modified client used to shove through the grow-area fence and the booth partitions).
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(get_chest_position(), target.get_chest_position(), Const.LAYER_WORLD)
		if not space.intersect_ray(query).is_empty():
			return
	var now := Time.get_ticks_msec()
	if now < _shove_ready_msec:
		return
	_shove_ready_msec = now + int(maxf(b.shove_cooldown_sec, 0.0) * 1000.0)
	var direction := target.global_position - global_position
	direction.y = 0.0
	if not direction.is_finite() or direction.length_squared() < 0.000001:
		direction = get_flat_forward()
	direction = direction.normalized()
	var from_behind := target.get_flat_forward().dot(direction) > 0.5
	server_shove(target, direction, from_behind)
	GameState.server_add_stat(peer_id, Const.STAT_SHOVES)

## Server -> the owner of this player: stumble. Players have owner authority, so this is any_peer + a sender check.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_staggered(impulse: Vector3, stun_sec: float, by_peer: int, hit: bool) -> void:
	if multiplayer.get_remote_sender_id() != Const.SERVER_PEER_ID or not is_local():
		return
	_stagger_locally(impulse, stun_sec, by_peer, hit)

func _stagger_locally(impulse: Vector3, stun_sec: float, by_peer: int, hit: bool) -> void:
	apply_stagger(impulse, stun_sec)
	_rpc_stagger_fx.rpc(by_peer, stun_sec, hit)

## Cosmetic, every peer: the sound at the body, a bounce, the `staggered` signal. Only the server or this node's
## owner may trigger it. Reliable on purpose (one small packet per stagger): a lost one would mean no bonk, no
## `staggered` for faces / HUD marks and a remote body that keeps taking footsteps while it stumbles.
@rpc("any_peer", "call_local", "reliable")
func _rpc_stagger_fx(by_peer: int, stun_sec: float, hit: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != Const.SERVER_PEER_ID and sender != peer_id:
		return
	if not is_inside_tree():
		return
	if is_finite(stun_sec):
		_stun_until_msec = maxi(_stun_until_msec, Time.get_ticks_msec() + int(clampf(stun_sec, 0.0, 5.0) * 1000.0))
	var sound: StringName = &"bonk" if hit else &"shove"
	if is_local():
		Sfx.play(sound)
	else:
		Sfx.play(sound, get_chest_position())
		if visual != null:
			Juice.bounce(visual, 0.25)
	staggered.emit(by_peer)

## Local camera kick: roll away from the push and a small pitch nudge on %Camera (not on $Head: the head pitch is the
## synced look), tweened back to rest over CAMERA_KICK_SEC.
func _camera_kick(push: Vector3) -> void:
	if camera == null or not camera.is_inside_tree():
		return
	var side := global_basis.x.dot(push)
	var roll := -signf(side) * CAMERA_KICK_ROLL_DEG if absf(side) > 0.05 else CAMERA_KICK_ROLL_DEG
	var pitch := -CAMERA_KICK_PITCH_DEG if global_basis.z.dot(push) < 0.0 else CAMERA_KICK_PITCH_DEG
	if _kick_tween != null and _kick_tween.is_valid():
		_kick_tween.kill()
	camera.rotation = Vector3.ZERO
	_kick_tween = create_tween()
	_kick_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_kick_tween.tween_property(camera, ^"rotation", Vector3(deg_to_rad(pitch), 0.0, deg_to_rad(roll)), CAMERA_KICK_SEC * 0.35)
	_kick_tween.tween_property(camera, ^"rotation", Vector3.ZERO, CAMERA_KICK_SEC * 0.65)

# --- M10: footsteps -------------------------------------------------------------------------------------------------

var _last_step_sound: int = -1
var _remote_stride_accum: float = 0.0           # remote: metres of smoothed movement since the last step
var _was_airborne: bool = false
var _fall_speed: float = 0.0

## One of STEP_SOUNDS, never the one played last.
func _next_step_sound() -> StringName:
	var i := randi() % STEP_SOUNDS.size()
	if i == _last_step_sound:
		i = (i + 1) % STEP_SOUNDS.size()
	_last_step_sound = i
	return STEP_SOUNDS[i]

## Local body: one quiet 2D step per stride walked on the floor (never airborne, stunned or in the back room), quieter
## when crouched, and a thud when a fall ends.
func _update_local_footsteps(moved: Vector3, can_move: bool) -> void:
	if not is_on_floor():
		_was_airborne = true
		_fall_speed = maxf(_fall_speed, -velocity.y)
		_stride_accum = 0.0
		return
	if _was_airborne:
		_was_airborne = false
		if _fall_speed >= LAND_MIN_SPEED and not GameState.is_in_backroom(peer_id):
			Sfx.play(&"land")
		_fall_speed = 0.0
	if is_stunned() or GameState.is_in_backroom(peer_id):
		_stride_accum = 0.0
		return
	moved.y = 0.0
	var d := moved.length()
	if d < 0.0005:
		return
	_stride_accum += d
	var sprinting := can_move and not crouching and Input.is_action_pressed(&"sprint")
	var stride := STEP_STRIDE_CROUCH if crouching else (STEP_STRIDE_SPRINT if sprinting else STEP_STRIDE_WALK)
	if _stride_accum >= stride:
		_stride_accum = fmod(_stride_accum, stride)
		Sfx.play(_next_step_sound(), Vector3.INF, STEP_CROUCH_DB if crouching else (STEP_SPRINT_DB if sprinting else 0.0))
		footstep.emit(global_position)

## Remote body: the same strides, counted on its smoothed movement.
func _update_remote_footsteps(delta: float) -> void:
	if _visual_speed <= WALK_ANIM_MIN_SPEED or is_stunned() or GameState.is_in_backroom(peer_id):
		_remote_stride_accum = 0.0
		return
	_remote_stride_accum += _visual_speed * delta
	var fast := _visual_speed > (Config.balance.walk_speed + Config.balance.sprint_speed) * 0.5
	var stride := STEP_STRIDE_CROUCH if crouching else (STEP_STRIDE_SPRINT if fast else STEP_STRIDE_WALK)
	if _remote_stride_accum >= stride:
		_remote_stride_accum = fmod(_remote_stride_accum, stride)
		Sfx.play(_next_step_sound(), global_position, STEP_CROUCH_DB if crouching else 0.0)
		footstep.emit(global_position)

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
	var stunned := is_stunned()
	var can_move := _input_enabled() and not stunned
	_emotes_physics(can_move) # M18 emotes
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
	if stunned:
		accel = minf(accel, STAGGER_FRICTION) # the stumble carries; the worker cannot brake it
	var horizontal := Vector2(velocity.x, velocity.z).move_toward(Vector2(target.x, target.z), accel * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.y
	_unstick_from_coincident_bodies()
	var before := global_position
	move_and_slide()
	_update_local_footsteps(global_position - before, can_move)

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
	elif _view_model != null and (_view_model_active or not _view_model_users.is_empty()):
		_refresh_view_model_active() # prunes users freed without telling us; off when %Camera is not current
		if _view_model_active:
			_match_view_model_viewport()
			sync_view_model()
	_emotes_process(delta) # M18 emotes

func _input_enabled() -> bool:
	return not Game.is_ui_locked()

func _current_speed(can_move: bool) -> float:
	if crouching:
		return Config.balance.crouch_speed
	if is_carrying_heavy(): # M14 loop: a heavy bundle slows the walk and rules out the sprint
		return get_heavy_walk_speed() # M14 loop
	if can_move and Input.is_action_pressed(&"sprint"):
		return Config.balance.sprint_speed
	return Config.balance.walk_speed

func _write_net_state() -> void:
	net_position = position
	net_yaw = rotation.y
	net_pitch = head.rotation.x

func _teleport_local(xform: Transform3D) -> void:
	_emotes_cancel_owner() # M18 emotes
	place_at(xform)
	_write_net_state()

func _get_spawn_transform() -> Transform3D:
	var w: World = Game.world
	if w != null and is_instance_valid(w) and w.room != null:
		var xf: Transform3D = w.room.get_spawn_transform(spawn_index)
		var parent_3d := get_parent() as Node3D
		return parent_3d.global_transform.affine_inverse() * xf if parent_3d != null else xf
	return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))

## Two capsules on exactly the same spot (a teleport onto another worker: the same back-room marker, a reset) have no
## horizontal separating axis, so the physics recovery would stack them vertically. A deterministic sideways nudge
## (direction from the peer id, so two peers pick different sides) turns that into an ordinary horizontal push.
func _unstick_from_coincident_bodies() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		var other := c as Player
		if other == null or other == self or other.is_queued_for_deletion():
			continue
		var d := other.global_position - global_position
		if not d.is_finite() or absf(d.y) > CROUCH_HEIGHT or Vector2(d.x, d.z).length_squared() > COINCIDENT_DISTANCE * COINCIDENT_DISTANCE:
			continue
		var angle := float(peer_id) * 2.399963 # golden angle: consecutive peers step off in different directions
		global_position += Vector3(cos(angle), 0.0, sin(angle)) * COINCIDENT_NUDGE
		return

func _can_stand_up() -> bool:
	if not is_inside_tree():
		return true
	var probe := CapsuleShape3D.new()
	probe.radius = _shape.radius * 0.9
	probe.height = STAND_HEIGHT - 0.1
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = probe
	params.transform = Transform3D(Basis.IDENTITY, global_position + Vector3(0.0, STAND_HEIGHT * 0.5 + 0.05, 0.0))
	# Static geometry only: another worker standing on top of a crouched one must never pin them down for good
	# (move_and_slide pushes the bodies apart once this one stands up).
	params.collision_mask = Const.LAYER_WORLD
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
	if not position.is_finite() or not is_finite(rotation.y) or not is_finite(head.rotation.x):
		snap = true # never lerp from a broken pose (the net_* values are always finite)
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
	if _visual_speed > WALK_ANIM_MIN_SPEED:
		_walk_phase = fmod(_walk_phase + delta * (6.0 + _visual_speed * 1.6), TAU)
	else:
		_walk_phase = move_toward(_walk_phase, 0.0 if _walk_phase < PI else TAU, delta * 8.0)
		if _walk_phase >= TAU:
			_walk_phase = 0.0 # at rest again (TAU and 0 are the same pose; keeps the step counter honest)
	_update_remote_footsteps(delta)
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
	_cart_arms(delta, hold) # M17 cart: both hands on the hand truck

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
	name_label.position.y = (STAND_LABEL_Y + _hat_label_lift) * squash # M16 hats: the name clears a tall hat
	body_hand_socket.position.y = STAND_BODY_SOCKET_Y * squash

func _apply_appearance() -> void:
	name_label.text = display_name
	name_label.modulate = player_color.lightened(0.2)
	if body_model != null:
		body_model.tint = Toon.grade(player_color) # recolours the model's TINT_* parts (shared, cached)

func _on_players_changed() -> void:
	_refresh_hat() # M16 hats
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

# --- M18 emotes: four gestures on the number keys ---------------------------------------------------------------------
## Point, a tired half-wave, a shrug and slump (CONTRACTS "M18 / Emotes"), built from the body's procedural pieces: the
## arm pivots (Visual/Model/ArmL|ArmR, rest rotation 0), the body model's own transform (Visual/Model: the crouch squash
## and Juice own $Visual, nothing else moves the model) and the face pivot riding along with it. Nobody smiles, nothing
## is a dance, the face keeps its mood.
##   1 point   the gesture arm comes up and follows where the worker looks (the head pitch every peer already has from
##             net_pitch; the yaw is the body's own) for the whole gesture
##   2 wave    the arm comes up halfway and rocks twice, slowly
##   3 shrug   the shoulders come up, both hands go out low, the head cocks; the shoulders sag back while it holds
##   4 slump   the worker sits down where they stand: squashed low, leaning back against whatever is behind (a ray on
##             the world layer, re-probed while sitting) or hunched forward in the open, arms limp, breathing slowly;
##             it lasts until they move or press any gesture key again
## Timed gestures last Config.balance.emote_sec; at most one starts per emote_cooldown_sec (the host's rule, with
## EMOTE_COOLDOWN_SLACK_SEC for jitter; the owner keeps its own clock so it does not ask in vain). The `emote` cloth
## sound plays at the body on every peer (2D for the worker themself).
## Refused while stunned, while carrying something heavy (a Floor Brick bundle, the hand truck: "Both hands are busy.")
## and while the flamethrower burns or its trigger is held. With a normal item in the right glove the LEFT arm points /
## waves / shrugs (the item stays in hand; a slumped worker keeps it in the lap). Allowed in the back room: the keys
## work under the back-room lock (like push to talk) and the body there plays them for anyone who can see in; being
## sent there or let out ends a gesture.
## The owner does not ask while walking or in the air (it would end at once).
## Ends early: any movement input, a jump or a crouch change, the body drifting EMOTE_DRIFT_M from where it started, a
## teleport (all seen by the owner, who tells the host); a stagger (shove, thrown item, fire) or a back-room change
## (every peer on its own, from the signals it already gets).
## Network (owner-driven like movement; one small reliable RPC each way, nothing per frame):
##   owner -> host  _rpc_request_emote(kind)   1..4 starts, 0 ends; taken only from the node's own registered peer,
##                                             the rules checked again (server_emote)
##   host -> all    _rpc_emote(kind, elapsed)  call_local; only the server's is accepted. A late joiner gets the running
##                                             gesture (a slump, or the rest of a timed one) on Net.peer_registered.
## First person (local worker): pointing shows a first-person arm under %Camera (FP_ARM_NAME: a sleeve in the worker's
## colour, a work glove with one finger out) on the view-model layer like a held item (add_view_model_user; the world
## layer while the view model is off; hidden while another camera is current); slump lowers the camera to
## SIT_CAMERA_Y. The other gestures show nothing in first person.

## Every peer: a gesture started on this body (after its sound).
signal emote_started(kind: int)
## Every peer: the gesture `kind` ended on this body (ran out, cancelled or replaced); the pose still eases out.
signal emote_ended(kind: int)

const EMOTE_NONE: int = 0
const EMOTE_POINT: int = 1
const EMOTE_WAVE: int = 2
const EMOTE_SHRUG: int = 3
const EMOTE_SLUMP: int = 4
## Input action per gesture (the number keys 1 to 4, project.godot): EMOTE_ACTIONS[kind - 1].
const EMOTE_ACTIONS: Array[StringName] = [&"emote_1", &"emote_2", &"emote_3", &"emote_4"]
const EMOTE_NAMES: Array[String] = ["", "point", "wave", "shrug", "slump"]
## Why a gesture is refused (get_emote_block / get_emote_refusal).
const EMOTE_REFUSED_STUNNED := "stunned"
const EMOTE_REFUSED_HEAVY := "heavy"
const EMOTE_REFUSED_TRIGGER := "trigger"
const EMOTE_REFUSED_COOLDOWN := "cooldown"
const EMOTE_REFUSED_MOVING := "moving"
const TEXT_HANDS_BUSY := "Both hands are busy."
## Pose easing (seconds): in, in for the slump (sitting down takes longer), out (also how early a timed gesture starts
## to lower so it is down when it ends).
const EMOTE_IN_SEC: float = 0.25
const EMOTE_SLUMP_IN_SEC: float = 0.5
const EMOTE_OUT_SEC: float = 0.35
## The host accepts a gesture this much before the cooldown is over (the request rode the network; jitter).
const EMOTE_COOLDOWN_SLACK_SEC: float = 0.15
## Owner: the body moved this far (horizontally) from where the gesture started -> it ends (bumped, carried along).
const EMOTE_DRIFT_M: float = 0.5
## A gesture replayed this far in (a late joiner) starts silently.
const EMOTE_SOUND_LATE_SEC: float = 0.25
## Where the glove hangs from the shoulder at rest (ArmR, model space: player.py puts the mitt about 0.42 m below and
## 0.18 m in front of the shoulder, a little out), and so how far forward of straight down the hanging arm already is.
const ARM_REST_GLOVE := Vector3(0.061, -0.415, -0.178)
const ARM_REST_FORWARD: float = 0.4
## Point: the arm turns in towards the middle a little (rad, ArmR; mirrored for ArmL).
const POINT_INWARD: float = 0.08
const POINT_LEAN: float = -0.05
## Wave: how high the arm comes up (rotation.x), how far out, the rock (rad) and its rate (Hz).
const WAVE_RAISE: float = 2.05
const WAVE_OUT: float = 0.45
const WAVE_SWAY: float = 0.2
const WAVE_HZ: float = 1.1
const WAVE_TILT: float = 0.035
## Shrug: ArmR's pose (z mirrored for ArmL), the shoulder lift (m) and the head cock (rad, the whole body model).
const SHRUG_ARM := Vector3(0.5, 0.0, 0.62)
const SHRUG_LIFT: float = 0.06
const SHRUG_TILT: float = 0.05
## Slump: ArmR's limp pose (z mirrored for ArmL), the body's total height / width (whatever the crouch was), the eye
## height of a worker sitting on the floor, the lean back against a wall / the hunch in the open (rad).
const SLUMP_ARM := Vector3(0.22, 0.0, 0.32)
const SIT_SQUASH: float = 0.58
const SIT_WIDEN: float = 1.08
const SIT_CAMERA_Y: float = 0.85
const SIT_LEAN_BACK: float = 0.24
const SIT_HUNCH: float = -0.12
## Slump: a wall closer behind than SIT_WALL_REACH (from the middle of the body) is leant on; the body slides back
## towards it by up to SIT_BACK_MAX, leaving SIT_BACK_CLEAR. Re-probed every SIT_PROBE_SEC (the worker can turn).
const SIT_WALL_REACH: float = 1.0
const SIT_BACK_CLEAR: float = 0.55
const SIT_BACK_MAX: float = 0.35
const SIT_PROBE_SEC: float = 0.25
const SIT_BREATH_HZ: float = 0.22
const SIT_BREATH: float = 0.012
## First-person point arm (camera space): the shoulder (x mirrored for the left arm), the point it aims at (the
## crosshair, a few metres out), how far below it starts while it comes up.
const FP_ARM_NAME := "PointArm"
const FP_ARM_SHOULDER := Vector3(0.3, -0.3, 0.08)
const FP_ARM_AIM := Vector3(0.0, 0.0, -4.0)
const FP_ARM_DROP: float = 0.35

var _emote_kind: int = EMOTE_NONE          # the gesture running on this peer (0 = none)
var _emote_time: float = 0.0               # seconds since it started
var _emote_pose: int = EMOTE_NONE          # the pose drawn (stays while it eases out)
var _emote_weight: float = 0.0             # 0..1 ease of the pose
var _emote_left: bool = false              # the left arm gestures (a normal item in the right glove)
var _emote_posed: bool = false             # overrides applied (restored once at the end)
var _emote_snap: bool = false              # next pose frame: take the targets as they are (a fresh start)
var _emote_tgt_l := Vector3.ZERO           # smoothed arm targets and arm weights (a switch glides)
var _emote_tgt_r := Vector3.ZERO
var _emote_tw_l: float = 0.0
var _emote_tw_r: float = 0.0
var _emote_wall: float = INF               # slump: distance to the wall behind (INF = none within reach)
var _emote_probe_left: float = 0.0
var _emote_lean: float = 0.0               # slump: smoothed lean / slide back
var _emote_back: float = 0.0
var _emote_sent_msec: int = -1000000       # owner: last gesture asked for
var _emote_anchor := Vector3.ZERO          # owner: where the body stood when it started
var _emote_crouch0: bool = false           # owner: the crouch when it started
var _emote_ready_msec: int = 0             # SERVER: when this worker may start the next one
var _emote_arm_l_rest := Vector3.ZERO
var _emote_arm_r_rest := Vector3.ZERO
var _emote_model_rest := Transform3D.IDENTITY
var _emote_face_rest := Vector3.ZERO
var _emote_socket_rest := Vector3.ZERO
var _emote_fp_arm: Node3D = null           # local: the first-person point arm (built on the first point)
var _emote_fp_registered: bool = false
var _emote_fp_on_vm: int = -1              # its layers: -1 unknown, 0 world, 1 view model
var _emote_fp_color := Color(0.0, 0.0, 0.0, 0.0)


static func emote_name(kind: int) -> String:
	return EMOTE_NAMES[kind] if kind > 0 and kind < EMOTE_NAMES.size() else ""


## The gesture running on this body on this peer (EMOTE_NONE = none). A slump runs until cancelled.
func get_emote() -> int:
	return _emote_kind


func is_emoting() -> bool:
	return _emote_kind != EMOTE_NONE


func is_slumped() -> bool:
	return _emote_kind == EMOTE_SLUMP


## Seconds since the running gesture started.
func get_emote_time() -> float:
	return _emote_time


## How far the pose is eased in (0..1; it eases out after the gesture ended).
func get_emote_weight() -> float:
	return _emote_weight


## The arm doing the gesture while a pose is drawn (ArmL with a normal item in hand, else ArmR), or null.
func get_emote_arm() -> Node3D:
	if _emote_pose == EMOTE_NONE:
		return null
	return arm_l if _emote_left else arm_r


## Where the gesture arm's glove points from the shoulder (world space, unit length; ZERO without a pose).
func get_emote_arm_direction() -> Vector3:
	var arm := get_emote_arm()
	if arm == null or not arm.is_inside_tree():
		return Vector3.ZERO
	var rest := ARM_REST_GLOVE * Vector3(-1.0 if _emote_left else 1.0, 1.0, 1.0)
	return (arm.global_basis * rest).normalized()


## Slump: the distance to the wall behind the body from its middle (INF = nothing within SIT_WALL_REACH).
func get_slump_wall() -> float:
	return _emote_wall


## Local worker: the first-person point arm while it is shown, else null.
func get_first_person_arm() -> Node3D:
	if _emote_fp_arm == null or not is_instance_valid(_emote_fp_arm) or not _emote_fp_arm.visible:
		return null
	return _emote_fp_arm


## The state rule, any peer (the host checks it again): "" or EMOTE_REFUSED_STUNNED / _HEAVY / _TRIGGER.
func get_emote_block() -> String:
	if is_stunned():
		return EMOTE_REFUSED_STUNNED
	var item := get_held_item()
	if item == null or not is_instance_valid(item):
		return ""
	if item.has_method(&"is_heavy") and bool(item.call(&"is_heavy")):
		return EMOTE_REFUSED_HEAVY
	if item.item_type == Const.ITEM_FLAMETHROWER and ((item.has_method(&"is_firing") and bool(item.call(&"is_firing"))) \
			or (is_local() and Input.is_action_pressed(&"use_item"))):
		return EMOTE_REFUSED_TRIGGER
	return ""


## Local worker: why a gesture key would do nothing right now ("" = it would ask the host).
func get_emote_refusal() -> String:
	var block := get_emote_block()
	if block != "":
		return block
	if Time.get_ticks_msec() - _emote_sent_msec < int(Config.balance.emote_cooldown_sec * 1000.0):
		return EMOTE_REFUSED_COOLDOWN
	if (_input_enabled() and _emote_walking()) or (is_local() and not is_on_floor()):
		return EMOTE_REFUSED_MOVING # walking (it would end at once) or in the air
	return ""


## LOCAL worker: asks the host for gesture `kind` (EMOTE_POINT..EMOTE_SLUMP; the gesture keys call this). A slumped
## worker stands up instead. False when it was refused here (a heavy carry also says so in a toast).
func request_emote(kind: int) -> bool:
	if not is_local() or kind < EMOTE_POINT or kind > EMOTE_SLUMP:
		return false
	if _emote_kind == EMOTE_SLUMP:
		_emote_stop_owner()
		return true
	var why := get_emote_refusal()
	if why != "":
		if why == EMOTE_REFUSED_HEAVY:
			Game.toast(TEXT_HANDS_BUSY, &"error")
		return false
	_emote_sent_msec = Time.get_ticks_msec()
	_rpc_request_emote.rpc_id(Const.SERVER_PEER_ID, kind)
	return true


## SERVER ONLY. Starts gesture `kind` on this worker for every peer when the rules allow it (get_emote_block, the
## cooldown); EMOTE_NONE ends the running one. True when it was relayed. Works for bodies without an owner (tests).
func server_emote(kind: int) -> bool:
	if not multiplayer.is_server() or not is_inside_tree() or is_queued_for_deletion():
		return false
	if kind == EMOTE_NONE:
		if _emote_kind == EMOTE_NONE:
			return false
		_rpc_emote.rpc(EMOTE_NONE, 0.0)
		return true
	if kind < EMOTE_POINT or kind > EMOTE_SLUMP or get_emote_block() != "":
		return false
	var now := Time.get_ticks_msec()
	if now < _emote_ready_msec:
		return false
	_emote_ready_msec = now + int(maxf(Config.balance.emote_cooldown_sec - EMOTE_COOLDOWN_SLACK_SEC, 0.0) * 1000.0)
	_rpc_emote.rpc(kind, 0.0)
	return true


## Owner -> host: "start gesture `kind`" (0 = "I stopped"). Only the node's own registered peer is heard.
@rpc("any_peer", "call_local", "reliable")
func _rpc_request_emote(kind: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	if sender != peer_id or not Net.players.has(sender):
		return # a gesture request is only valid on the sender's own body
	server_emote(kind)


## Host -> every peer: gesture `kind` starts on this body, `elapsed` seconds in (a late joiner); 0 ends it.
@rpc("any_peer", "call_local", "reliable")
func _rpc_emote(kind: int, elapsed: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != Const.SERVER_PEER_ID:
		return # only the host relays gestures
	if not is_inside_tree():
		return
	if kind == EMOTE_NONE:
		_emote_end_local()
		return
	if kind < EMOTE_POINT or kind > EMOTE_SLUMP or not is_finite(elapsed):
		return
	_emote_begin_local(kind, clampf(elapsed, 0.0, 86400.0))


func _emotes_ready() -> void:
	if arm_l != null:
		_emote_arm_l_rest = arm_l.position
	if arm_r != null:
		_emote_arm_r_rest = arm_r.position
	if body_model != null:
		_emote_model_rest = body_model.transform
	_emote_face_rest = face.position
	_emote_socket_rest = body_hand_socket.position
	staggered.connect(_emotes_on_staggered)
	GameState.backroom_changed.connect(_emotes_on_backroom_changed)
	if Net.is_host:
		Net.peer_registered.connect(_emotes_on_peer_registered)


## Owner, every physics frame (from _physics_process): the gesture keys and what cancels a running gesture.
func _emotes_physics(_can_move: bool) -> void:
	if _emote_kind != EMOTE_NONE and _emote_should_cancel():
		_emote_stop_owner()
		return
	if not _emote_input_enabled():
		return
	for i in EMOTE_ACTIONS.size():
		if Input.is_action_just_pressed(EMOTE_ACTIONS[i]):
			request_emote(i + 1)
			return


## Every peer, every frame (end of _process, after the remote walk / arm animation): the clock and the pose.
func _emotes_process(delta: float) -> void:
	if _emote_kind != EMOTE_NONE:
		_emote_time += delta
		if _emote_kind != EMOTE_SLUMP and _emote_time >= Config.balance.emote_sec:
			_emote_end_local()
	if _emote_pose == EMOTE_NONE:
		return
	var want := 0.0
	if _emote_kind != EMOTE_NONE and (_emote_kind == EMOTE_SLUMP or _emote_time < Config.balance.emote_sec - EMOTE_OUT_SEC):
		want = 1.0
	var ease_sec := _emote_in_sec(_emote_pose) if want > _emote_weight else EMOTE_OUT_SEC
	_emote_weight = move_toward(_emote_weight, want, delta / maxf(ease_sec, 0.01))
	if _emote_weight <= 0.0 and _emote_kind == EMOTE_NONE:
		if _emote_posed:
			_emote_restore()
		_emote_pose = EMOTE_NONE
		_emote_update_fp_arm(0.0)
		return
	var w := smoothstep(0.0, 1.0, _emote_weight)
	_emote_apply_pose(delta, w)
	_emote_update_fp_arm(w)


## Owner: the body was moved without walking (a teleport, from _teleport_local).
func _emotes_cancel_owner() -> void:
	if is_local():
		_emote_stop_owner()


func _emote_in_sec(kind: int) -> float:
	return EMOTE_SLUMP_IN_SEC if kind == EMOTE_SLUMP else EMOTE_IN_SEC


## Keys work with no UI lock, or under the back-room lock alone (the worker in there can still gesture).
func _emote_input_enabled() -> bool:
	if not is_local():
		return false
	if not Game.is_ui_locked():
		return true
	return Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM) and Game.get_ui_lock_sources().size() == 1


func _emote_walking() -> bool:
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back").length_squared() > 0.01


## Owner: anything that ends a running gesture (see the header).
func _emote_should_cancel() -> bool:
	if get_emote_block() != "" or crouching != _emote_crouch0:
		return true
	var drift := global_position - _emote_anchor
	drift.y = 0.0
	if not drift.is_finite() or drift.length() > EMOTE_DRIFT_M:
		return true
	return _input_enabled() and (_emote_walking() or Input.is_action_just_pressed(&"jump") \
			or Input.is_action_just_pressed(&"crouch"))


## Owner: ends the running gesture and tells the host (the request first: on the host's own body it is relayed at
## once, before the local state is gone).
func _emote_stop_owner() -> void:
	if _emote_kind == EMOTE_NONE:
		return
	_rpc_request_emote.rpc_id(Const.SERVER_PEER_ID, EMOTE_NONE)
	_emote_end_local()


func _emotes_on_staggered(_by_peer: int) -> void:
	_emote_end_local()


func _emotes_on_backroom_changed(changed_peer: int, _active: bool) -> void:
	if changed_peer == peer_id:
		_emote_end_local()


## HOST: a late joiner gets this body's running gesture.
func _emotes_on_peer_registered(new_peer: int) -> void:
	if _emote_kind == EMOTE_NONE or new_peer == peer_id or not is_inside_tree() or not multiplayer.is_server():
		return
	if multiplayer.get_peers().has(new_peer):
		_rpc_emote.rpc_id(new_peer, _emote_kind, _emote_time)


func _emote_begin_local(kind: int, elapsed: float) -> void:
	var previous := _emote_kind
	if _emote_pose == EMOTE_NONE or _emote_weight <= 0.0:
		_emote_snap = true
	_emote_kind = kind
	_emote_time = elapsed
	_emote_pose = kind
	_emote_left = get_held_item() != null
	_emote_anchor = global_position
	_emote_crouch0 = crouching
	if kind == EMOTE_SLUMP:
		_emote_probe_wall()
		_emote_probe_left = SIT_PROBE_SEC
		if previous != EMOTE_SLUMP:
			_emote_snap = true
	if elapsed >= _emote_in_sec(kind):
		_emote_weight = 1.0
	if elapsed < EMOTE_SOUND_LATE_SEC:
		if is_local():
			Sfx.play(&"emote")
		else:
			Sfx.play(&"emote", get_chest_position())
	if previous != EMOTE_NONE:
		emote_ended.emit(previous)
	emote_started.emit(kind)


func _emote_end_local() -> void:
	if _emote_kind == EMOTE_NONE:
		return
	var kind := _emote_kind
	_emote_kind = EMOTE_NONE
	emote_ended.emit(kind)


func _crouch_camera_y() -> float:
	return lerpf(STAND_CAMERA_Y, CROUCH_CAMERA_Y, _crouch_blend)


func _emote_apply_pose(delta: float, w: float) -> void:
	_emote_posed = true
	var t := _emote_time
	var out_sign := -1.0 if _emote_left else 1.0 # +z swings ArmR out, -z swings ArmL out
	var tl := Vector3.ZERO
	var tr := Vector3.ZERO
	var wl := 0.0
	var wr := 0.0
	var lift := 0.0
	var lean := 0.0
	var tilt := 0.0
	var back := 0.0
	var squash := 1.0
	var widen := 1.0
	var sitting := _emote_pose == EMOTE_SLUMP
	match _emote_pose:
		EMOTE_POINT:
			var aim := Vector3(clampf(head.rotation.x + PI * 0.5 - ARM_REST_FORWARD, -0.2, 2.9), POINT_INWARD * out_sign, 0.0)
			if _emote_left:
				tl = aim
				wl = 1.0
			else:
				tr = aim
				wr = 1.0
			lean = POINT_LEAN
		EMOTE_WAVE:
			var rock := sin(TAU * WAVE_HZ * maxf(t - 0.3, 0.0)) * WAVE_SWAY * clampf((t - 0.3) / 0.3, 0.0, 1.0)
			var raised := Vector3(WAVE_RAISE, 0.0, out_sign * (WAVE_OUT + rock))
			if _emote_left:
				tl = raised
				wl = 1.0
			else:
				tr = raised
				wr = 1.0
			tilt = -out_sign * WAVE_TILT
		EMOTE_SHRUG:
			var up := smoothstep(0.0, 0.3, t) * lerpf(1.0, 0.45, smoothstep(0.7, 1.6, t))
			lift = SHRUG_LIFT * up
			tilt = SHRUG_TILT * up
			tl = Vector3(SHRUG_ARM.x, 0.0, -SHRUG_ARM.z)
			wl = 1.0
			if not _emote_left:
				tr = SHRUG_ARM
				wr = 1.0
		EMOTE_SLUMP:
			tl = Vector3(SLUMP_ARM.x, 0.0, -SLUMP_ARM.z)
			wl = 1.0
			if not _emote_left:
				tr = SLUMP_ARM
				wr = 1.0
			_emote_probe_left -= delta
			if _emote_probe_left <= 0.0:
				_emote_probe_left = SIT_PROBE_SEC
				_emote_probe_wall()
			var lean_to := SIT_HUNCH
			var back_to := 0.0
			if _emote_wall < SIT_WALL_REACH:
				lean_to = SIT_LEAN_BACK
				back_to = clampf(_emote_wall - SIT_BACK_CLEAR, 0.0, SIT_BACK_MAX)
			if _emote_snap:
				_emote_lean = lean_to
				_emote_back = back_to
			else:
				var k_sit := 1.0 - exp(-6.0 * delta)
				_emote_lean = lerpf(_emote_lean, lean_to, k_sit)
				_emote_back = lerpf(_emote_back, back_to, k_sit)
			lean = _emote_lean
			back = _emote_back
			squash = SIT_SQUASH * (1.0 + SIT_BREATH * sin(TAU * SIT_BREATH_HZ * t))
			widen = SIT_WIDEN
	if _emote_snap:
		_emote_snap = false
		_emote_tgt_l = tl
		_emote_tgt_r = tr
		_emote_tw_l = wl
		_emote_tw_r = wr
	else:
		var k := 1.0 - exp(-14.0 * delta)
		_emote_tgt_l = _emote_tgt_l.lerp(tl, k)
		_emote_tgt_r = _emote_tgt_r.lerp(tr, k)
		_emote_tw_l = move_toward(_emote_tw_l, wl, 6.0 * delta)
		_emote_tw_r = move_toward(_emote_tw_r, wr, 6.0 * delta)
	if arm_l != null and arm_r != null:
		if is_local(): # nobody else poses the local body's arms (its owner only sees their shadow)
			arm_l.rotation = Vector3.ZERO
			arm_r.rotation = Vector3.ZERO
		arm_l.rotation = arm_l.rotation.lerp(_emote_tgt_l, w * _emote_tw_l)
		arm_r.rotation = arm_r.rotation.lerp(_emote_tgt_r, w * _emote_tw_r)
		arm_l.position = _emote_arm_l_rest + Vector3.UP * lift * w
		arm_r.position = _emote_arm_r_rest + Vector3.UP * lift * w
	# The body model: total height / width while sitting whatever the crouch is ($Visual carries the crouch squash).
	var crouch_sq := lerpf(1.0, CROUCH_HEIGHT / STAND_HEIGHT, _crouch_blend)
	var crouch_wide := lerpf(1.0, 1.08, _crouch_blend)
	var sy := lerpf(1.0, squash / crouch_sq, w) if sitting else 1.0
	var sxz := lerpf(1.0, widen / crouch_wide, w) if sitting else 1.0
	var bend := Basis.from_euler(Vector3(lean * w, 0.0, tilt * w))
	var change := Transform3D(bend * Basis.from_scale(Vector3(sxz, sy, sxz)), Vector3(0.0, 0.0, back * w))
	if body_model != null:
		body_model.transform = _emote_model_rest * change
	# The face rides on the head (position and lean) but keeps its size: the mood does not change.
	var follow := head.rotation.x * FACE_PITCH_FACTOR if not is_local() else 0.0
	var head_at := (_emote_model_rest * change * _emote_model_rest.affine_inverse()) * _emote_face_rest
	face.transform = Transform3D(Basis.from_euler(Vector3(lean * w + follow, 0.0, tilt * w)), head_at)
	_emote_write_heights(crouch_sq * sy, lerpf(_crouch_camera_y(), SIT_CAMERA_Y, w) if sitting else _crouch_camera_y(), back * w)


## The name label, the body's item socket and the head (the camera, for the local worker) at a total body height.
func _emote_write_heights(total_squash: float, head_y: float, back: float) -> void:
	name_label.position.y = (STAND_LABEL_Y + _hat_label_lift) * total_squash
	body_hand_socket.position = Vector3(_emote_socket_rest.x, STAND_BODY_SOCKET_Y * total_squash, _emote_socket_rest.z + back)
	head.position.y = head_y


func _emote_restore() -> void:
	_emote_posed = false
	_emote_tw_l = 0.0
	_emote_tw_r = 0.0
	if arm_l != null and arm_r != null:
		if is_local():
			arm_l.rotation = Vector3.ZERO
			arm_r.rotation = Vector3.ZERO
		arm_l.position = _emote_arm_l_rest
		arm_r.position = _emote_arm_r_rest
	if body_model != null:
		body_model.transform = _emote_model_rest
	var follow := head.rotation.x * FACE_PITCH_FACTOR if not is_local() else 0.0
	face.transform = Transform3D(Basis(Vector3.RIGHT, follow), _emote_face_rest)
	_emote_write_heights(lerpf(1.0, CROUCH_HEIGHT / STAND_HEIGHT, _crouch_blend), _crouch_camera_y(), 0.0)


## Slump: the distance to the wall straight behind the body (chest height, world layer), INF when none within reach.
func _emote_probe_wall() -> void:
	_emote_wall = INF
	if not is_inside_tree():
		return
	var behind := global_basis.z
	behind.y = 0.0
	if not behind.is_finite() or behind.length_squared() < 0.000001:
		return
	behind = behind.normalized()
	var from := global_position + Vector3.UP * CHEST_HEIGHT_CROUCHED
	var query := PhysicsRayQueryParameters3D.create(from, from + behind * SIT_WALL_REACH, Const.LAYER_WORLD)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_emote_wall = from.distance_to(hit["position"])


## Local worker: shows / hides the first-person point arm (`w` = the pose ease) and keeps it on the right layer.
func _emote_update_fp_arm(w: float) -> void:
	var show := w > 0.0 and _emote_pose == EMOTE_POINT and is_local() and camera != null and camera.is_current()
	if not show:
		if _emote_fp_arm != null and is_instance_valid(_emote_fp_arm):
			_emote_fp_arm.visible = false
			if _emote_fp_registered:
				remove_view_model_user(_emote_fp_arm)
		_emote_fp_registered = false
		return
	if _emote_fp_arm == null or not is_instance_valid(_emote_fp_arm):
		_emote_fp_arm = _emote_build_fp_arm()
		_emote_fp_on_vm = -1
	var vm := uses_view_model()
	if (1 if vm else 0) != _emote_fp_on_vm:
		_emote_fp_on_vm = 1 if vm else 0
		for n in _emote_fp_arm.find_children("*", "GeometryInstance3D", true, false):
			(n as GeometryInstance3D).layers = VIEW_MODEL_LAYER if vm else WORLD_RENDER_LAYER
	if vm and not _emote_fp_registered:
		add_view_model_user(_emote_fp_arm)
		_emote_fp_registered = true
	elif not vm and _emote_fp_registered:
		remove_view_model_user(_emote_fp_arm)
		_emote_fp_registered = false
	if player_color != _emote_fp_color:
		_emote_fp_color = player_color
		var sleeve := _emote_fp_arm.get_node_or_null(^"Sleeve") as MeshInstance3D
		if sleeve != null:
			sleeve.material_override = Toon.tint(player_color)
	_emote_fp_arm.visible = true
	var side := -1.0 if _emote_left else 1.0
	var shoulder := Vector3(FP_ARM_SHOULDER.x * side, FP_ARM_SHOULDER.y - (1.0 - w) * FP_ARM_DROP, FP_ARM_SHOULDER.z)
	_emote_fp_arm.transform = Transform3D(Basis.looking_at(FP_ARM_AIM - shoulder, Vector3.UP), shoulder)


## The first-person arm, built along -Z from the shoulder: sleeve, glove cuff, mitt, one finger out, the thumb on top.
func _emote_build_fp_arm() -> Node3D:
	var arm := Node3D.new()
	arm.name = FP_ARM_NAME
	var glove: Material = Toon.lib(&"brown")
	var along := Basis(Vector3.RIGHT, PI * 0.5) # a capsule / cylinder's Y axis turned onto -Z
	var sleeve := CapsuleMesh.new()
	sleeve.radius = 0.062
	sleeve.height = 0.46
	sleeve.radial_segments = 16
	sleeve.rings = 4
	_emote_fp_part(arm, "Sleeve", sleeve, Toon.tint(player_color), Transform3D(along, Vector3(0.0, 0.0, -0.23)), true)
	var cuff := CylinderMesh.new()
	cuff.top_radius = 0.071
	cuff.bottom_radius = 0.071
	cuff.height = 0.05
	cuff.radial_segments = 16
	cuff.rings = 1
	_emote_fp_part(arm, "Cuff", cuff, glove, Transform3D(along, Vector3(0.0, 0.0, -0.44)), false)
	var mitt := SphereMesh.new()
	mitt.radius = 0.08
	mitt.height = 0.16
	mitt.radial_segments = 16
	mitt.rings = 8
	_emote_fp_part(arm, "Mitt", mitt, glove, Transform3D(Basis.from_scale(Vector3(1.0, 0.85, 1.15)), Vector3(0.0, 0.0, -0.51)), true)
	var finger := CapsuleMesh.new()
	finger.radius = 0.024
	finger.height = 0.14
	finger.radial_segments = 12
	finger.rings = 2
	_emote_fp_part(arm, "Finger", finger, glove, Transform3D(along, Vector3(0.0, 0.02, -0.6)), true)
	var thumb := SphereMesh.new()
	thumb.radius = 0.028
	thumb.height = 0.056
	thumb.radial_segments = 10
	thumb.rings = 5
	_emote_fp_part(arm, "Thumb", thumb, glove, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.055, -0.49)), true)
	_emote_fp_color = player_color
	camera.add_child(arm)
	return arm


func _emote_fp_part(parent: Node3D, part_name: String, mesh: Mesh, mat: Material, xf: Transform3D, outline: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	if outline:
		mi.material_overlay = Toon.outline(true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = xf
	parent.add_child(mi)

# --- end M18 emotes ----------------------------------------------------------------------------------------------------

# --- M12 flame (flame agent): set on fire by the flamethrower -----------------------------------------------------

## Every peer, after the flamethrower's cone reached this worker (cosmetic RPC). by_peer = the shooter.
signal ignited(by_peer: int)

## How long the flame cosmetic burns on the body (seconds).
const IGNITE_FX_SEC: float = 2.0
## Flame colours (dull orange to tomato to the grey everything drifts towards; nothing bright).
const IGNITE_COLORS: Array[Color] = [Color("ce8d52"), Color("ce6469"), Color("8d93a0")]

## SERVER ONLY. The flamethrower set this worker on fire on behalf of `by_peer` (the shooter, 0 = nobody): the held
## item drops, they stumble away from the shooter for hit_stun_sec (Player.server_stagger; the owner does the actual
## stumble), every peer sees IGNITE_FX_SEC of flame on the body and hears "ignite" (_rpc_ignited), and the shooter is
## written up for arson. A worker in the back room is left alone. Nobody dies of it.
func server_ignite(by_peer: int) -> void:
	if not multiplayer.is_server():
		push_error("Player.server_ignite called on a client")
		return
	if not is_inside_tree() or is_queued_for_deletion() or GameState.is_in_backroom(peer_id):
		return
	var shooter: Player = Game.get_player(by_peer) if by_peer > 0 else null
	var away := Vector3.ZERO
	if shooter != null and is_instance_valid(shooter) and shooter.is_inside_tree():
		away = global_position - shooter.global_position
	away.y = 0.0
	if not away.is_finite() or away.length_squared() < 0.000001:
		away = get_flat_forward() * -1.0
	var mgr := ItemManager.find(self)
	if mgr != null and mgr.get_held_by(peer_id) != null:
		mgr.server_release_holder(peer_id)
	Player.server_stagger(self, away.normalized(), false, by_peer, Config.balance.hit_stun_sec, false)
	# The write-up (MAJOR Story line) first, so the PROGRESS "on fire" line waits in Story's queue behind it.
	if by_peer > 0:
		GameState.server_write_up(by_peer, Const.WRITE_UP_ARSON)
	_rpc_ignited.rpc(by_peer)

## Cosmetic, every peer (only the server may send it: players have owner authority, so any_peer + a sender check):
## "ignite", IGNITE_FX_SEC of flame on a remote body (the local worker sees their own stumble instead: the body is
## hidden from its camera), the Story line, the `ignited` signal.
@rpc("any_peer", "call_local", "reliable")
func _rpc_ignited(by_peer: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != Const.SERVER_PEER_ID:
		return
	if not is_inside_tree():
		return
	if is_local():
		Sfx.play(&"ignite")
	else:
		Sfx.play(&"ignite", get_chest_position())
		_show_ignite_fx()
	var story: Node = Story
	if story != null and story.has_method(&"flame_worker_ignited"):
		story.call(&"flame_worker_ignited", peer_id)
	ignited.emit(by_peer)

## Flame particles around the body for IGNITE_FX_SEC (local cosmetic; a plain child of $Visual, no sync, no RPCs).
func _show_ignite_fx() -> void:
	var parent: Node3D = visual if visual != null else self
	var fx := CPUParticles3D.new()
	fx.name = "IgniteFx"
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.amount = 28
	fx.lifetime = 0.6
	fx.randomness = 0.4
	fx.local_coords = false
	fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fx.emission_sphere_radius = 0.35
	fx.direction = Vector3.UP
	fx.spread = 30.0
	fx.gravity = Vector3(0.0, 1.5, 0.0)
	fx.initial_velocity_min = 0.6
	fx.initial_velocity_max = 1.4
	fx.scale_amount_min = 0.6
	fx.scale_amount_max = 1.2
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	ramp.colors = PackedColorArray([IGNITE_COLORS[0], IGNITE_COLORS[1], Color(IGNITE_COLORS[2], 0.0)])
	fx.color_ramp = ramp
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	var mesh := SphereMesh.new()
	mesh.radius = 0.06
	mesh.height = 0.12
	mesh.radial_segments = 8
	mesh.rings = 4
	mesh.material = mat
	fx.mesh = mesh
	fx.position = Vector3(0.0, CHEST_HEIGHT_STANDING, 0.0)
	fx.emitting = true
	parent.add_child(fx)
	var tw := fx.create_tween()
	tw.tween_interval(IGNITE_FX_SEC)
	tw.tween_callback(func() -> void: fx.emitting = false)
	tw.tween_interval(fx.lifetime + 0.1)
	tw.tween_callback(fx.queue_free)


# --- M14 loop: the heavy carry (Floor Brick) ----------------------------------------------------------------------
## A bundle of a strain with SeedDef.heavy slows its carrier: walking speed times Config.balance.heavy_speed_factor
## and no sprint (the hook is in _current_speed). Movement is the owner's own simulation in this game, so the rule
## runs where the carrier moves; every other peer just sees the body follow. Crouching keeps the crouch speed (it is
## slower still). Dropping or throwing the bundle lifts it at once: the held item is read every physics frame.

## True while this worker holds a bundle of a heavy strain (any peer: the held item is synced).
func is_carrying_heavy() -> bool:
	var item := get_held_item()
	return item != null and is_instance_valid(item) and item.has_method(&"is_heavy") and bool(item.call(&"is_heavy"))


## Walking speed under a heavy bundle (m/s).
func get_heavy_walk_speed() -> float:
	return Config.balance.walk_speed * clampf(Config.balance.heavy_speed_factor, 0.05, 1.0)


## The speed this worker's own simulation aims for right now (crouch / heavy / sprint / walk). For the HUD and tests;
## it reads the local input, so it only means something for the local worker.
func get_move_speed() -> float:
	return _current_speed(_input_enabled() and not is_stunned())


# --- M16 hats: issued kit on the head ---------------------------------------------------------------------------------
## The hat this worker wears (CONTRACTS "M16 / Hats"): every peer shows Net.get_player_hat(peer_id) on the body model.
## The model (art/models/player.glb) carries the stock hard hat as its own mesh `Hat` and an empty `HatSocket` on the
## hat's seat (it leans as the hat leans); an issued hat (Hats.make: a Toonify root authored in that socket's space) is
## instanced under the socket and the stock one is hidden for as long. Purely local and cosmetic: nothing is synced
## here, the player is never reparented, the old hat is freed when it changes. The socket is part of the body model,
## under $Visual, so the hat takes the crouch squash, the walk bounce and a stumble's bounce with the head.
## The local worker's own hat is shadow-only like the rest of its body: the first-person camera sits inside it.
## With replay off (Config.replay_enabled) nobody wears one.

const HAT_SOCKET_PATH := ^"Visual/Model/HatSocket"
const STOCK_HAT_PATH := ^"Visual/Model/Hat"
## Clear space between the top of a hat and the middle of the name label (the label is 0.22 m tall).
const HAT_LABEL_GAP: float = 0.2
## The socket when the body model has none of its own (what tools/blender/models/player.py prints).
const HAT_SOCKET_FALLBACK := Transform3D(Basis(Vector3(0.98484, 0.13917, 0.10351), Vector3(-0.12689, 0.98499, -0.11706),
		Vector3(-0.11825, 0.10215, 0.98772)), Vector3(-0.01, 1.5311, -0.0895))

## The hat shown on this body right now (&"" = the stock hard hat).
var hat_id: StringName = &""
var _hat_node: Node3D = null
var _hat_socket: Node3D = null
## How far the name label is raised so it clears the hat (0 for the stock hat and every hat lower than the label).
var _hat_label_lift: float = 0.0


## The hat shown on this body (&"" = none: the stock hard hat).
func get_hat() -> StringName:
	return hat_id


## The instanced hat model under the head socket, or null without one.
func get_hat_node() -> Node3D:
	return _hat_node if is_instance_valid(_hat_node) else null


## The socket on the head of the body model that hats hang from.
func get_hat_socket() -> Node3D:
	if is_instance_valid(_hat_socket):
		return _hat_socket
	_hat_socket = get_node_or_null(HAT_SOCKET_PATH) as Node3D
	if _hat_socket == null:
		_hat_socket = Node3D.new()
		_hat_socket.name = "HatSocket"
		_hat_socket.transform = HAT_SOCKET_FALLBACK
		(visual if visual != null else self).add_child(_hat_socket)
	return _hat_socket


## Shows the hat `id` on this body (&"" or an id the catalog does not have: the stock hard hat). Cosmetic, this peer
## only: what a worker wears is decided by Net.hats (see _refresh_hat).
func set_hat(id: StringName) -> void:
	if not Hats.has(id):
		id = &""
	if id == hat_id and (id == &"" or get_hat_node() != null):
		return
	var old := get_hat_node()
	if old != null:
		old.get_parent().remove_child(old)
		old.queue_free()
	_hat_node = null
	hat_id = &""
	if id != &"":
		var node := Hats.make(id)
		if node != null:
			get_hat_socket().add_child(node)
			_hat_node = node
			hat_id = id
			if is_local():
				for gi in node.find_children("*", "GeometryInstance3D", true, false):
					(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var stock := get_node_or_null(STOCK_HAT_PATH) as Node3D
	if stock != null:
		stock.visible = hat_id == &""
	_hat_label_lift = maxf(_hat_top() + HAT_LABEL_GAP - STAND_LABEL_Y, 0.0)
	if is_node_ready():
		_apply_crouch_visuals()


## How high the worn hat reaches above the feet of the standing body (0 without one): its meshes in $Visual's own
## space, so a crouch or a bounce in progress does not count.
func _hat_top() -> float:
	var hat := get_hat_node()
	if hat == null or visual == null or not is_inside_tree():
		return 0.0
	var top := 0.0
	var to_visual := visual.global_transform.affine_inverse()
	for n in hat.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh != null and not mi.has_meta(&"toonify_outline"):
			top = maxf(top, (to_visual * mi.global_transform * mi.get_aabb()).end.y)
	return top


func _hats_ready() -> void:
	Net.hats_changed.connect(_refresh_hat)
	_refresh_hat()


## The hat the session says this worker wears (none with replay off).
func _refresh_hat() -> void:
	set_hat(Net.get_player_hat(peer_id) if Config.replay_enabled else &"")

# --- end M16 hats -----------------------------------------------------------------------------------------------------

# --- M17 cart: the hand truck -----------------------------------------------------------------------------------------
## The hand truck (scripts/items/hand_truck.gd) is a heavy carry through its is_heavy(): is_carrying_heavy() above is
## true while this worker holds it, loaded or empty, so _current_speed gives walk_speed x heavy_speed_factor and no
## sprint, enforced where the owner simulates the body like the Floor Brick bundle. It is dropped (Q) and never thrown
## (ItemManager / Interactor hooks). The truck places itself in front of the body (HandTruck._follow_holder), so on
## other peers this worker holds it with both hands: the left arm comes up the way the right one does for any item.

## Remote bodies: the left arm's pose while both hands are on the truck (the right arm's HOLD_ARM_ROTATION, mirrored).
const CART_ARM_ROTATION := Vector3(0.86, -0.11, 0.0)

var _cart_both_hands: bool = false
var _cart_check_left: float = 0.0


## Remote bodies, from _animate_arms: blends the left arm up while the held item is the hand truck (checked every
## 0.15 s, like the hold itself).
func _cart_arms(delta: float, hold: float) -> void:
	_cart_check_left -= delta
	if _cart_check_left <= 0.0:
		_cart_check_left = 0.15
		var item := get_held_item()
		_cart_both_hands = item != null and is_instance_valid(item) and item.item_type == Const.ITEM_HAND_TRUCK
	if _cart_both_hands and arm_l != null:
		arm_l.rotation = arm_l.rotation.lerp(CART_ARM_ROTATION, hold)

# --- end M17 cart -----------------------------------------------------------------------------------------------------
