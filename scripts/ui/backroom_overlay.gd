class_name BackRoomOverlay
extends Control
## The back room (scenes/ui/backroom_overlay.tscn, instanced by the HUD as %BackRoom).
## Shown while the LOCAL worker sits in the back room (GameState.is_in_backroom(local) during PLAYING; late joiners
## get it from the forced backroom_changed of their first state): a dark full-rect panel (~88 % ink), "BACK ROOM",
## one flat line, a countdown from GameState.get_backroom_time_left(local) and "Watching: <name>   [A] / [D]".
## While shown it holds Game.set_ui_lock(Const.UI_LOCK_BACKROOM) (input off, mouse free) and a spectator camera
## ("SpectatorCamera", a Camera3D created under Game.world) is current: it follows the watched worker's head from
## behind (FOLLOW_BACK m back, FOLLOW_UP m up, exp-smoothed, snapping on a target change). Targets are the workers
## on the floor (not in the back room), cycled with spectate_prev / spectate_next (the lock stops movement, so A / D
## are free); with nobody to watch it sits at the World's OverviewCamera transform. Push-to-talk keeps working (voice
## agent). Hidden again on backroom_changed(local, false), when the phase leaves PLAYING or when the world goes:
## the camera is freed, the player's own camera is current again and the lock is released. Never touches the lock
## once the local player is gone.

const CAMERA_NAME: String = "SpectatorCamera"
const FOLLOW_BACK: float = 2.2
const FOLLOW_UP: float = 0.9
const FOLLOW_SMOOTHING: float = 6.0
const HEAD_HEIGHT_FALLBACK: float = 1.6
const DIM_ALPHA: float = 0.88

const TEXT_TITLE := "BACK ROOM"
const TEXT_BODY := "He's talking at you. Don't answer."
const TEXT_WATCHING := "Watching: %s   [%s] / [%s]"
const TEXT_NOBODY := "the floor"

var _shown: bool = false
var _locked: bool = false
var _camera: Camera3D = null
var _target_peer: int = 0
var _snap: bool = true

@onready var dim: Panel = %Dim
@onready var column: Control = %Column
@onready var title_label: Label = %Title
@onready var body_label: Label = %Body
@onready var timer_label: Label = %Timer
@onready var watching_label: Label = %Watching


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	title_label.text = TEXT_TITLE
	body_label.text = TEXT_BODY
	_darken_dim()
	GameState.backroom_changed.connect(_on_backroom_changed)
	GameState.phase_changed.connect(_on_phase_changed)
	Game.local_player_spawned.connect(_on_local_player_spawned)
	Net.players_changed.connect(_on_players_changed)
	sync()


func _exit_tree() -> void:
	_release_camera(false)
	_set_locked(false)


func _process(delta: float) -> void:
	if not _shown:
		return
	_refresh_timer()
	_follow(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not _shown or not event.is_pressed() or event.is_echo():
		return
	if event.is_action_pressed(&"spectate_next"):
		cycle(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"spectate_prev"):
		cycle(-1)
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## True while the overlay is up (the local worker is in the back room).
func is_open() -> bool:
	return _shown


## Peer id of the worker the spectator camera follows (0 = nobody: the overview shot).
func get_watched_peer() -> int:
	return _target_peer


## The spectator camera while shown, else null.
func get_spectator_camera() -> Camera3D:
	return _camera if is_instance_valid(_camera) else null


## Watch the next (+1) / previous (-1) worker on the floor.
func cycle(step: int) -> void:
	var candidates := get_candidates()
	if candidates.size() <= 1:
		_refresh_texts()
		return
	var i := candidates.find(_target_peer)
	i = posmod(i + step, candidates.size())
	_target_peer = candidates[i]
	_snap = true
	_refresh_texts()
	Sfx.play(&"ui_click")


## Workers the camera may follow: on the floor (not in the back room), never ourselves, sorted by peer id.
func get_candidates() -> Array[int]:
	var out: Array[int] = []
	var world: Node = Game.world
	if world == null or not is_instance_valid(world) or not world.has_method(&"get_players"):
		return out
	var local := _local_peer_id()
	for p: Node in world.call(&"get_players"):
		var id: int = int(p.get(&"peer_id"))
		if id == local or GameState.is_in_backroom(id):
			continue
		out.append(id)
	out.sort()
	return out


## Shows / hides according to GameState (PLAYING and the local worker in the back room, with a live local player).
func sync() -> void:
	var local := _local_peer_id()
	var player: Node = Game.local_player
	var world: Node = Game.world
	var want := GameState.phase == GameState.Phase.PLAYING and local > 0 and GameState.is_in_backroom(local) \
			and is_instance_valid(player) and player.is_inside_tree() \
			and world != null and is_instance_valid(world) and world.is_inside_tree()
	if want and not _shown:
		_show()
	elif not want and _shown:
		_hide()


# ---------------------------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------------------------

func _on_backroom_changed(_peer_id: int, _active: bool) -> void:
	sync()
	if _shown:
		_refresh_texts()


func _on_phase_changed(_new_phase: int) -> void:
	sync()


func _on_local_player_spawned(_player: Node) -> void:
	sync()


func _on_players_changed() -> void:
	if _shown:
		_refresh_texts()


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

func _show() -> void:
	_shown = true
	visible = true
	_set_locked(true)
	_target_peer = 0
	_snap = true
	var candidates := get_candidates()
	if not candidates.is_empty():
		_target_peer = candidates[0]
	_ensure_camera()
	_refresh_texts()
	_refresh_timer()
	Sfx.play(&"door_slam")
	if is_inside_tree():
		Juice.pop_in(column, 0.3)


func _hide() -> void:
	_shown = false
	visible = false
	_release_camera(true)
	_set_locked(false)


func _ensure_camera() -> void:
	if is_instance_valid(_camera):
		return
	var world: Node = Game.world
	if world == null or not is_instance_valid(world) or not world.is_inside_tree():
		return
	_camera = Camera3D.new()
	_camera.name = CAMERA_NAME
	_camera.fov = 70.0
	world.add_child(_camera)
	_snap = true
	_follow(0.0)
	_camera.current = true


## Frees the spectator camera; `restore_player` hands the view back to the local player's own camera.
func _release_camera(restore_player: bool) -> void:
	if is_instance_valid(_camera):
		if _camera.is_inside_tree():
			_camera.current = false
		_camera.queue_free()
	_camera = null
	if not restore_player:
		return
	var player: Node = Game.local_player
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return
	var cam := player.get(&"camera") as Camera3D
	if cam != null and is_instance_valid(cam) and cam.is_inside_tree():
		cam.current = true


func _follow(delta: float) -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree():
		_ensure_camera()
		if not is_instance_valid(_camera):
			return
	var target := _target_node()
	var desired: Transform3D
	if target == null:
		desired = _overview_transform()
	else:
		var head := _head_position(target)
		var behind: Vector3 = target.global_basis.z
		behind.y = 0.0
		behind = behind.normalized() if behind.length_squared() > 0.0001 else Vector3.BACK
		var origin := head + behind * FOLLOW_BACK + Vector3.UP * FOLLOW_UP
		desired = Transform3D(Basis.looking_at(head - origin, Vector3.UP), origin)
	if _snap or delta <= 0.0:
		_camera.global_transform = desired
		_snap = false
		return
	var t := 1.0 - exp(-FOLLOW_SMOOTHING * delta)
	var cur := _camera.global_transform
	var q := cur.basis.get_rotation_quaternion().slerp(desired.basis.get_rotation_quaternion(), t)
	_camera.global_transform = Transform3D(Basis(q), cur.origin.lerp(desired.origin, t))


## The player node being watched, or null (the target is re-picked when it left the floor).
func _target_node() -> Node3D:
	var candidates := get_candidates()
	if candidates.is_empty():
		if _target_peer != 0:
			_target_peer = 0
			_snap = true
			_refresh_texts()
		return null
	if not candidates.has(_target_peer):
		_target_peer = candidates[0]
		_snap = true
		_refresh_texts()
	var node := Game.get_player(_target_peer) as Node3D
	return node if node != null and is_instance_valid(node) and node.is_inside_tree() else null


static func _head_position(target: Node3D) -> Vector3:
	var head := target.get_node_or_null(^"Head") as Node3D
	if head != null:
		return head.global_position
	return target.global_position + Vector3.UP * HEAD_HEIGHT_FALLBACK


func _overview_transform() -> Transform3D:
	var world: Node = Game.world
	if world != null and is_instance_valid(world):
		var overview := world.get_node_or_null(^"OverviewCamera") as Camera3D
		if overview != null and overview.is_inside_tree():
			return overview.global_transform
	var origin := Vector3(0.0, 7.5, 10.0)
	return Transform3D(Basis.looking_at(-origin, Vector3.UP), origin)


func _refresh_texts() -> void:
	var who := Net.get_player_name(_target_peer) if _target_peer > 0 else TEXT_NOBODY
	watching_label.text = TEXT_WATCHING % [who, HUD.action_key_text(&"spectate_prev", "A"), HUD.action_key_text(&"spectate_next", "D")]


func _refresh_timer() -> void:
	timer_label.text = format_seconds(GameState.get_backroom_time_left(_local_peer_id()))


## "0:28" (rounded up, so 0:00 shows only when the time is up).
static func format_seconds(seconds: float) -> String:
	var total := ceili(maxf(seconds, 0.0))
	@warning_ignore("integer_division")
	return "%d:%02d" % [total / 60, total % 60]


## ~88 % ink instead of the OverlayPanel's 60 %: the same theme stylebox, darker (derived, not hand-made).
func _darken_dim() -> void:
	var base := dim.get_theme_stylebox(&"panel")
	if base is StyleBoxFlat:
		var style := (base as StyleBoxFlat).duplicate() as StyleBoxFlat
		style.bg_color.a = DIM_ALPHA
		dim.add_theme_stylebox_override(&"panel", style)


func _set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	if locked:
		Game.set_ui_lock(Const.UI_LOCK_BACKROOM, true)
	elif Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM):
		Game.set_ui_lock(Const.UI_LOCK_BACKROOM, false)


func _local_peer_id() -> int:
	var mp: MultiplayerAPI = multiplayer if is_inside_tree() else null
	if mp == null or not mp.has_multiplayer_peer():
		return 0
	return mp.get_unique_id()
