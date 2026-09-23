class_name Interactor
extends Node3D
## Child of the Player scene (%Interactor). On the LOCAL player only: raycasts from the camera every physics
## frame, tracks the Interactable being looked at, emits the HUD prompt and handles the interact / drop inputs.
##
## Ray: camera position along -camera.basis.z for Config.balance.interact_distance, mask world|interactable|item
## (walls block), bodies + areas, own body excluded. The hit collider's nearest Interactable ancestor is the target.
## Prompt (re-evaluated every physics frame, emitted only when it changes):
##   can_interact  -> (get_prompt(), true)
##   otherwise     -> (get_denied_reason() or get_prompt(), false)   greyed out by the HUD
##   no target / UI locked -> ("", false)                              hidden
## The HUD connects to Game.local_player.get_interactor().prompt_changed; prompt_text / prompt_enabled hold the
## current state for listeners that connect late.

## Emitted whenever the prompt text should change. "" means hide the prompt.
signal prompt_changed(text: String, enabled: bool)
## Emitted when the looked-at interactable changes (may be null).
signal target_changed(target: Interactable)

var player: Player
var current_target: Interactable = null
## Last emitted prompt (read-only for other scripts).
var prompt_text: String = ""
var prompt_enabled: bool = false

var _camera: Camera3D = null
var _target_id: int = 0

func _ready() -> void:
	player = _find_player()
	if player == null:
		push_warning("Interactor: not under a Player (%s)" % get_path())

# --- Public API ------------------------------------------------------------------------------------------------

## Interacts with the current target (bound to the "interact" action: E / LMB). Local player only.
func try_interact() -> void:
	if not _is_local_player():
		return
	if not _is_valid_target(current_target):
		_set_target(null)
		return
	current_target.interact(player)

## Asks the server to drop the held item (bound to the "drop" action: Q / G). Local player only.
func try_drop() -> void:
	if not _is_local_player():
		return
	var items := ItemManager.find(player)
	if items == null or items.get_held_by(player.peer_id) == null:
		return
	items.request_drop()

## Raycasts now and refreshes target + prompt (normally done every physics frame).
func refresh() -> void:
	if not _is_local_player():
		return
	if Game.is_ui_locked():
		_set_prompt("", false)
		return
	_set_target(_raycast_target())
	_update_prompt()

## The camera the ray starts from (the player's %Camera).
func get_camera() -> Camera3D:
	if not is_instance_valid(_camera) and player != null:
		_camera = player.get_node_or_null(^"%Camera") as Camera3D
	return _camera

# --- Engine callbacks ----------------------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	refresh()

func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player() or Game.is_ui_locked():
		return
	if event.is_action_pressed(&"interact"):
		# A click that (re)captures the mouse should not also interact.
		if event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		try_interact()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"drop"):
		try_drop()
		get_viewport().set_input_as_handled()

# --- Internals ---------------------------------------------------------------------------------------------------

func _find_player() -> Player:
	var n := get_parent()
	while n != null:
		if n is Player:
			return n as Player
		n = n.get_parent()
	return null

func _is_local_player() -> bool:
	return player != null and is_instance_valid(player) and player.is_inside_tree() and player.is_local()

func _raycast_target() -> Interactable:
	var cam := get_camera()
	if cam == null or not cam.is_inside_tree():
		return null
	var from := cam.global_position
	var to := from - cam.global_transform.basis.z.normalized() * Config.balance.interact_distance
	var exclude: Array[RID] = [player.get_rid()]
	var query := PhysicsRayQueryParameters3D.create(from, to,
			Const.LAYER_WORLD | Const.LAYER_INTERACTABLE | Const.LAYER_ITEM, exclude)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var node := hit.get("collider") as Node
	while node != null:
		if node is Interactable:
			var target := node as Interactable
			return target if _is_valid_target(target) else null
		node = node.get_parent()
	return null

## Variant parameter on purpose: passing a freed object to a typed parameter is a script error.
func _is_valid_target(target: Variant) -> bool:
	if not is_instance_valid(target):
		return false
	var t := target as Interactable
	return t != null and t.is_inside_tree() and not t.is_queued_for_deletion()

func _set_target(target: Interactable) -> void:
	if not _is_valid_target(target):
		target = null
	# Compare instance ids: the previous target may have been freed (despawned item) since last frame.
	var id := target.get_instance_id() if target != null else 0
	if id == _target_id:
		return
	_target_id = id
	current_target = target
	target_changed.emit(target)

func _update_prompt() -> void:
	if current_target == null:
		_set_prompt("", false)
		return
	if current_target.can_interact(player):
		_set_prompt(current_target.get_prompt(player), true)
		return
	var reason := current_target.get_denied_reason(player)
	_set_prompt(reason if reason != "" else current_target.get_prompt(player), false)

func _set_prompt(text: String, enabled: bool) -> void:
	if text == "":
		enabled = false
	if text == prompt_text and enabled == prompt_enabled:
		return
	prompt_text = text
	prompt_enabled = enabled
	prompt_changed.emit(text, enabled)
