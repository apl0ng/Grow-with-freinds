class_name Van
extends Node3D
## The crew's van in the alley (scenes/world/van.tscn, M14 lobby agent): the shift starts when every worker in the
## session stands in the back. FRIENDSLOP 8.1, CONTRACTS "Lobby + van".
##
## Server-authoritative. While the lobby is on (`Config.lobby_enabled` on the host) and the phase is WAITING, the host
## counts every COUNT_INTERVAL the registered workers (Net.players) whose body stands inside the cargo volume
## (`$CargoVolume/Shape`, a box; the test is plain maths on the feet position, so bodies nobody owns count too).
## When ALL of them are in (at least one) a countdown of `Config.balance.van_countdown_sec` runs; it stops the moment
## the count says someone stepped out and starts from the top when they are back. A worker who leaves the session is
## simply no longer counted. At zero the host calls `GameState.server_begin_shift_from_lobby()`.
##
## Synced state (host -> everyone, reliable, on every change and to a late joiner on Net.peer_registered):
##   occupants       workers standing in the back
##   total           workers in the session; 0 = the lobby is off on the host (clients read "is the lobby on" from it)
##   countdown_left  seconds until the doors close: -1 idle, > 0 counting (every peer ticks it down locally between
##                   syncs), 0 = doors closed (the ride has begun; back to -1 when the alley is open again)
## Clients only display. `changed` fires on every peer when what the HUD shows changed.
##
## Cosmetics (every peer on its own): the rear doors swing shut when a to_floor transition starts
## (GameState.transition_started) and stand open again whenever the phase is back to WAITING. The model's doors rest
## OPEN (van.glb); `rotation.y = +-DOOR_SHUT_DEG` shuts a leaf.
##
## Frame of the scene: origin on the ground under the rear axle, the rear opening faces +Z (the nose is at -Z).

## Every peer: occupants, total or the whole second of countdown_left changed.
signal changed

## Seconds between two head counts on the host.
const COUNT_INTERVAL: float = 0.25
## van.glb: a leaf is shut at this yaw (left +, right -); 0 = open (the model's rest pose).
const DOOR_SHUT_DEG: float = 105.0
const DOOR_LEFT_PATH := ^"Model/DoorLeft"
const DOOR_RIGHT_PATH := ^"Model/DoorRight"
const CARGO_SHAPE_PATH := ^"CargoVolume/Shape"

## Workers standing in the back (synced).
var occupants: int = 0
## Workers in the session as the host counts them (synced). 0 = the lobby is off on the host.
var total: int = 0
## Seconds until the doors close: -1 idle, > 0 counting, 0 = doors closed (synced; ticked locally in between).
var countdown_left: float = -1.0

var _count_accum: float = 0.0
var _recount: bool = true
var _shown_second: int = -1
var _door_tween: Tween
var _doors_shut: bool = false


func _ready() -> void:
	Net.peer_registered.connect(_on_peer_registered)
	Net.peer_left.connect(_on_peer_changed)
	Net.players_changed.connect(_on_players_changed)
	GameState.transition_started.connect(_on_transition_started)
	GameState.phase_changed.connect(_on_phase_changed)
	Story.onboarding_watch_van(self)  # M19 onboarding: a first-timer's hint line says what the van is, once, near its doors


func _process(delta: float) -> void:
	if _is_host():
		_server_tick(delta)
	elif countdown_left > 0.0:
		# Clients tick between syncs; only the host's sync ever says 0 (doors closed).
		countdown_left = maxf(countdown_left - delta, 0.01)
		_emit_if_second_changed()


# --- queries (any peer) ---------------------------------------------------------------------------------------

## True while the countdown runs (the doors are about to close).
func is_counting() -> bool:
	return countdown_left > 0.0


## True once the doors are closed (the ride has begun), until the alley is open again.
func is_departing() -> bool:
	return countdown_left == 0.0


## True when the host runs the lobby (clients know it from the synced head count).
func is_lobby_on() -> bool:
	return total > 0


## True when every worker in the session stands in the back (and there is at least one).
func is_everyone_in() -> bool:
	return total >= 1 and occupants >= total


## The whole seconds the HUD shows while counting ("Doors closing 2"); 0 when not counting.
func get_countdown_seconds() -> int:
	return ceili(countdown_left) if countdown_left > 0.0 else 0


## The cargo volume as a box in THIS node's space.
func get_cargo_aabb() -> AABB:
	var node := get_node_or_null(CARGO_SHAPE_PATH) as CollisionShape3D
	var box := node.shape as BoxShape3D if node != null else null
	if box == null:
		return AABB(Vector3(-0.9, 0.3, -2.05), Vector3(1.8, 2.2, 2.8))
	var centre := _local_transform_of(node).origin
	return AABB(centre - box.size * 0.5, box.size)


## True when `point` (global; a worker's feet) lies inside the cargo volume.
func is_in_cargo(point: Vector3) -> bool:
	if not point.is_finite():
		return false
	var local := global_transform.affine_inverse() * point if is_inside_tree() else point
	return get_cargo_aabb().has_point(local)


## A standing spot on the cargo floor for worker `index` (global feet transform, facing the bulkhead): tests and
## bots use it to "get in".
func get_seat_transform(index: int) -> Transform3D:
	var box := get_cargo_aabb()
	var col := posmod(index, 2)
	@warning_ignore("integer_division")
	var row := posmod(index, 6) / 2
	var local := Vector3(box.position.x + box.size.x * (0.27 + 0.46 * col), box.position.y + 0.2,
			box.end.z - 0.5 - 0.85 * row)
	var xf := Transform3D(Basis.IDENTITY, local)
	return global_transform * xf if is_inside_tree() else xf


## Global point on the ground behind the open doors (where a worker starts walking in).
func get_entry_point() -> Vector3:
	var local := Vector3(0.0, 0.0, get_cargo_aabb().end.z + 1.4)
	return global_transform * local if is_inside_tree() else local


func are_doors_shut() -> bool:
	return _doors_shut


# --- host ---------------------------------------------------------------------------------------------------------

func _is_host() -> bool:
	return Net.is_host and is_inside_tree() and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func _server_tick(delta: float) -> void:
	if not Config.lobby_enabled:
		return
	if GameState.phase != GameState.Phase.WAITING:
		# Nobody rides while a shift runs or its report is read.
		if occupants != 0 or countdown_left != -1.0:
			_server_set(0, total, -1.0)
		_recount = true
		return
	if GameState.is_transitioning():
		if countdown_left != 0.0:
			_server_set(occupants, total, 0.0) # doors closed (the host's Enter gets here without a countdown)
		return
	if countdown_left == 0.0:
		_server_set(occupants, total, -1.0) # the alley is open again
	_count_accum += delta
	if _recount or _count_accum >= COUNT_INTERVAL:
		_count_accum = 0.0
		_recount = false
		server_count()
	if not is_everyone_in():
		if countdown_left >= 0.0:
			_server_set(occupants, total, -1.0)
		return
	if countdown_left < 0.0:
		var full := maxf(Config.balance.van_countdown_sec, 0.0)
		if full > 0.0:
			_server_set(occupants, total, full)
			return
		countdown_left = 0.0
	else:
		countdown_left -= delta
	if countdown_left > 0.0:
		_emit_if_second_changed()
		return
	_server_set(occupants, total, 0.0)
	GameState.server_begin_shift_from_lobby()


## HOST: counts the workers in the back now and broadcasts the result when it changed. Returns the count.
func server_count() -> int:
	if not _is_host():
		return occupants
	var world: World = Game.world
	var n_total := 0
	var n_in := 0
	for id in Net.get_peer_ids():
		n_total += 1
		var p: Player = world.get_player(id) if world != null and is_instance_valid(world) else null
		if p != null and p.is_inside_tree() and is_in_cargo(p.global_position):
			n_in += 1
	if n_in != occupants or n_total != total:
		_server_set(n_in, n_total, countdown_left)
	return n_in


func _server_set(new_occupants: int, new_total: int, new_countdown: float) -> void:
	_rpc_sync.rpc(new_occupants, new_total, new_countdown)


## Host -> every peer (the host through call_local): the head count and the countdown.
@rpc("authority", "call_local", "reliable")
func _rpc_sync(new_occupants: int, new_total: int, new_countdown: float) -> void:
	occupants = maxi(new_occupants, 0)
	total = maxi(new_total, 0)
	countdown_left = new_countdown if is_finite(new_countdown) else -1.0
	_shown_second = get_countdown_seconds()
	changed.emit()


func _emit_if_second_changed() -> void:
	var second := get_countdown_seconds()
	if second != _shown_second:
		_shown_second = second
		changed.emit()


## HOST: a late joiner gets the current count (reliable, after its world exists: clients build it before joining).
func _on_peer_registered(peer_id: int) -> void:
	_recount = true
	if not _is_host() or not Config.lobby_enabled:
		return
	if peer_id == multiplayer.get_unique_id() or peer_id not in multiplayer.get_peers():
		return
	_rpc_sync.rpc_id(peer_id, occupants, total, countdown_left)


func _on_peer_changed(_peer_id: int) -> void:
	_recount = true


func _on_players_changed() -> void:
	_recount = true


# --- doors (cosmetic, every peer) -----------------------------------------------------------------------------

func _on_transition_started(kind: StringName, seconds: float) -> void:
	if kind == GameState.TRANSITION_TO_FLOOR:
		set_doors_shut(true, seconds)


func _on_phase_changed(phase: int) -> void:
	_recount = true
	if phase == GameState.Phase.WAITING or phase == GameState.Phase.MENU:
		set_doors_shut(false, 0.0)


## Swings both rear leaves shut / open over `seconds` (0 = at once). Cosmetic and idempotent.
func set_doors_shut(shut: bool, seconds: float = 0.0) -> void:
	_doors_shut = shut
	if _door_tween != null and _door_tween.is_valid():
		_door_tween.kill()
	var left := get_node_or_null(DOOR_LEFT_PATH) as Node3D
	var right := get_node_or_null(DOOR_RIGHT_PATH) as Node3D
	var yaw := deg_to_rad(DOOR_SHUT_DEG) if shut else 0.0
	if seconds <= 0.0 or not is_inside_tree():
		if left != null:
			left.rotation.y = yaw
		if right != null:
			right.rotation.y = -yaw
		return
	_door_tween = create_tween().set_parallel(true)
	if left != null:
		_door_tween.tween_property(left, ^"rotation:y", yaw, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if right != null:
		_door_tween.tween_property(right, ^"rotation:y", -yaw, seconds * 0.85).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


# --- helpers ------------------------------------------------------------------------------------------------------

## Transform of a descendant relative to this node (works in and out of the tree).
func _local_transform_of(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != self:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t
