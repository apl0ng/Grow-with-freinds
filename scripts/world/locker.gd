class_name Locker
extends Interactable
## The locker in the alley (M16 hats agent; CONTRACTS "M16 / Hats", scenes/world/locker.tscn, placed in lobby.tscn).
## Where a worker changes the hat the record issued (scripts/core/hats.gd): E puts on the next issued hat, round to
## none. It is LOCAL to the worker who uses it: it changes that player's own Career hat (kept in the career file),
## and Career hands the change to the host (Net.send_hat), which is how everyone else gets to see it. There is no
## server state here and no RPC of its own: `interact()` is answered on the spot instead of going to the host.
##
## Prompt (the Interactor re-reads it every physics frame; the part after the dot is what the worker has on now,
## because nobody sees their own head):
##   "Locker · yellow hard hat"    wearing it; E moves on to the next issued one
##   "Locker · no hat"             something is issued, nothing is on (the worker as issued on day one)
##   "Locker · nothing issued"     the record has issued nothing yet (greyed out)
##   "Locker · jammed"             the host takes no more changes this session (Net.MAX_HAT_CHANGES; greyed out)
##   "Locker · locked"             replay off (Config.replay_enabled): no hat is sent or shown (greyed out)
## Feedback, on this peer only: the sound "locker" at the door, and the right-hand door (`Visual/Door` of
## art/models/locker.glb, pivot on its hinge) swings out and falls back to where it hangs ajar.

## A worker changed hats here (LOCAL; &"" = took it off).
signal used(hat: StringName)

const TEXT_PROMPT := "Locker · %s"
const TEXT_NO_HAT := "no hat"
const TEXT_NOTHING := "Locker · nothing issued"
const TEXT_JAMMED := "Locker · jammed"
const TEXT_LOCKED := "Locker · locked"
const DOOR_PATH := ^"Visual/Door"
## Where the door hangs at rest, and how far a pull swings it (degrees about its hinge; + = out of the locker).
const DOOR_AJAR_DEG: float = 6.0
const DOOR_OPEN_DEG: float = 40.0
const DOOR_OPEN_SEC: float = 0.12
const DOOR_FALL_SEC: float = 0.3
## Height of the door's middle above the locker's feet (where the sound comes from).
const SOUND_HEIGHT: float = 1.0

var _door_tween: Tween = null


func _ready() -> void:
	var door := get_door()
	if door != null:
		door.rotation.y = deg_to_rad(DOOR_AJAR_DEG)


## The swinging door of the model (null if the model lost it).
func get_door() -> Node3D:
	return get_node_or_null(DOOR_PATH) as Node3D


func get_prompt(_player: Player) -> String:
	if not Config.replay_enabled:
		return TEXT_LOCKED
	if Career.get_issued_hats().is_empty():
		return TEXT_NOTHING
	if not Career.can_change_hat():
		return TEXT_JAMMED
	var hat: StringName = Career.get_hat()
	return TEXT_PROMPT % (Hats.display_name(hat) if hat != &"" else TEXT_NO_HAT)


func can_interact(_player: Player) -> bool:
	return Config.replay_enabled and not Career.get_issued_hats().is_empty() and Career.can_change_hat()


## Local, not through the host: the locker holds this player's own kit (see the header).
func interact(player: Player) -> void:
	if player == null or not player.is_local():
		return
	if not can_interact(player):
		_on_denied_locally(player)
		return
	use()


## LOCAL: puts on the next issued hat (round to none) and returns what is on now. Nothing changes, and nothing
## plays, when Career refuses it.
func use() -> StringName:
	var before: StringName = Career.get_hat()
	var next := Hats.next_in(Career.get_issued_hats(), before)
	if next == before or not Config.replay_enabled or not Career.set_hat(next):
		return before
	Sfx.play(&"locker", global_position + Vector3.UP * SOUND_HEIGHT)
	_swing_door()
	used.emit(next)
	return next


## The door is pulled open and falls back to where it hangs.
func _swing_door() -> void:
	var door := get_door()
	if door == null or not is_inside_tree():
		return
	if _door_tween != null and _door_tween.is_valid():
		_door_tween.kill()
	_door_tween = create_tween()
	_door_tween.tween_property(door, ^"rotation:y", deg_to_rad(DOOR_OPEN_DEG), DOOR_OPEN_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_door_tween.tween_property(door, ^"rotation:y", deg_to_rad(DOOR_AJAR_DEG), DOOR_FALL_SEC).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
