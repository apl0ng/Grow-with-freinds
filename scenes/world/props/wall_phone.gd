class_name WallPhone
extends Interactable
## The wall phone (M17 mayhem3; CONTRACTS "M17", "Mayhem 3"): an old wall set, cracked, its handset held together with
## tape, on the main room's north wall west of the debt board (room.tscn Decor/WallPhone, Room.get_wall_phone()). The
## model is art/models/wall_phone.glb (tools/blender/models/wall_phone.py), instanced AS `Visual`; `Visual/Handset`
## hangs on the hook (pivot on the hook, rest identity).
## It only matters while Events.EVENT_PHONE runs. Events rings it on every peer (set_ringing: the handset rattles in its
## cradle in step with the `phone_ring` loop Events plays at it) and tells it when somebody took the call (pick_up).
## No spawner, no sync of its own: everything it shows follows the Events packets.
##
## Answering: hold E on it for Config.balance.phone_hold_sec. The hold is the collector's: tracked locally (interact()
## is overridden WITHOUT a server round trip per press; _process counts it while the key is down and the phone is under
## the crosshair) and ONE request goes out when it completes: Events.request_answer_phone(). The request RPC lives on the
## Events autoload, which validates it on the host (the back room, the range, still ringing).
## Prompt while it rings: "Hold E · Answer the phone" (with the seconds left while holding). Silent it reads "Phone",
## greyed out, and E on it does nothing at all: no refusal, no sound.

const PROMPT_IDLE := "Phone"
const PROMPT_ANSWER := "Hold %s · Answer the phone"
const PROMPT_ANSWERING := "Hold %s · Answer the phone · %.1f s"
## The bell's cadence (Sfx `phone_ring`: a RING_CYCLE_SEC loop that rings for its first RING_ON_SEC): the handset
## rattles in step with it.
const RING_CYCLE_SEC := 3.0
const RING_ON_SEC := 1.4
## How far and how fast the handset rattles in its cradle while the bell rings (degrees about Z, hertz).
const RATTLE_DEG := 4.0
const RATTLE_HZ := 18.0
## The handset lifts off the hook this far when the call is taken and drops back after PICKUP_SEC.
const PICKUP_LIFT := 0.07
const PICKUP_SEC := 1.4
## After a request the hold cannot send again for this long (a refusal is a toast).
const RESEND_GUARD_SEC := 1.0

var _ringing: bool = false
var _ring_clock: float = 0.0
var _hold: float = 0.0
var _holding: bool = false
var _sent_left: float = 0.0
var _lift_tween: Tween = null
var _handset_rest: Transform3D = Transform3D.IDENTITY

@onready var _handset: Node3D = get_node_or_null(^"Visual/Handset") as Node3D


func _ready() -> void:
	if _handset != null:
		_handset_rest = _handset.transform
	set_process(false)


# --- Events drives it (every peer) -----------------------------------------------------------------------------------

## Every peer, from Events: the bell rings (`on`) or stops. A local hold stops with it.
func set_ringing(on: bool) -> void:
	if on == _ringing:
		return
	_ringing = on
	_ring_clock = 0.0
	if not on:
		_stop_hold()
		if _handset != null and (_lift_tween == null or not _lift_tween.is_valid()):
			_handset.transform = _handset_rest
	_update_processing()


func is_ringing() -> bool:
	return _ringing


## Every peer, from Events: somebody took the call. The bell stops and the handset comes off the hook for a moment.
func pick_up() -> void:
	set_ringing(false)
	if _handset == null or not is_inside_tree():
		return
	if _lift_tween != null and _lift_tween.is_valid():
		_lift_tween.kill()
	_handset.transform = _handset_rest
	var up := _handset_rest.origin + Vector3(0.0, PICKUP_LIFT, 0.03)
	_lift_tween = create_tween()
	_lift_tween.tween_property(_handset, ^"position", up, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_lift_tween.tween_interval(PICKUP_SEC)
	_lift_tween.tween_property(_handset, ^"position", _handset_rest.origin, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


## The handset node (null when the model has none). Tests read its rotation and position.
func get_handset() -> Node3D:
	return _handset


# --- Interactable (pure) ---------------------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	if not _is_live():
		return PROMPT_IDLE
	var key := HUD.action_key_text(&"interact", "E")
	if _holding:
		return PROMPT_ANSWERING % [key, maxf(_hold_sec() - _hold, 0.0)]
	return PROMPT_ANSWER % key


func can_interact(_player: Player) -> bool:
	return _is_live()


func get_denied_reason(_player: Player) -> String:
	return ""


## Local only: E on it starts the answer hold while it rings (does NOT call super: the request goes out when the hold
## completes). Silent, it does nothing.
func interact(player: Player) -> void:
	if player == null or not player.is_local() or not can_interact(player):
		return
	if _holding or _sent_left > 0.0:
		return
	_holding = true
	_hold = 0.0
	_update_processing()


## 0..1 of the local worker's answer hold (0 when nobody holds here).
func get_answer_progress() -> float:
	return clampf(_hold / _hold_sec(), 0.0, 1.0)


## True while the local worker holds the answer.
func is_answering() -> bool:
	return _holding


func _process(delta: float) -> void:
	if _ringing:
		_ring_clock += delta
		_rattle()
	if _sent_left > 0.0:
		_sent_left = maxf(_sent_left - delta, 0.0)
	if _holding:
		var player: Player = Game.local_player
		if player == null or not is_instance_valid(player) or not _still_answering(player):
			_stop_hold()
		else:
			_hold += delta
			if _hold >= _hold_sec():
				_stop_hold()
				_sent_left = RESEND_GUARD_SEC
				Events.request_answer_phone()
	_update_processing()


## The handset shakes on its hook while the bell rings, and hangs still in the gaps of the cadence.
func _rattle() -> void:
	if _handset == null or (_lift_tween != null and _lift_tween.is_valid()):
		return
	var angle := 0.0
	if fmod(_ring_clock, RING_CYCLE_SEC) < RING_ON_SEC:
		angle = deg_to_rad(RATTLE_DEG) * sin(TAU * RATTLE_HZ * _ring_clock)
	_handset.transform = _handset_rest * Transform3D(Basis(Vector3.BACK, angle), Vector3.ZERO)


func _is_live() -> bool:
	return Events.is_event_active(Events.EVENT_PHONE)


func _hold_sec() -> float:
	return maxf(Config.balance.phone_hold_sec, 0.05)


func _still_answering(player: Player) -> bool:
	if not can_interact(player) or not Input.is_action_pressed(&"interact"):
		return false
	var interactor := player.get_interactor()
	return interactor != null and interactor.current_target == self


func _stop_hold() -> void:
	_holding = false
	_hold = 0.0


func _update_processing() -> void:
	set_process(_ringing or _holding or _sent_left > 0.0)
