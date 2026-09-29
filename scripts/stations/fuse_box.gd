class_name FuseBox
extends Interactable
## The breaker box on the west wall (scenes/stations/fuse_box.tscn, owner: events agent, M10). Wall-mounted:
## the scene origin is the mount point on the wall, front = local +Z (faces into the room).
##
## Tripped while the mains are off (Events.is_power_on() false, normally the POWER_CUT event). A worker resets it
## by HOLDING interact for Config.balance.fuse_reset_sec while looking at it. Like the ShopCounter this overrides
## interact() WITHOUT calling super: the hold is tracked locally (no server round trip per press) and only the
## finished hold sends one request:
##   local   interact(player)        starts the hold; _process keeps it going while the interact action stays
##                                   pressed, the Interactor still targets this box and it is still tripped
##   client  request_reset()         -> _rpc_request_reset.rpc_id(1)
##   server  _rpc_request_reset      validates sender / player / range / tripped -> Events.server_end_event()
##                                   (which restores the power on every peer; Events plays "power_up")
## Prompt (Interactor re-reads it every physics frame): tripped "Hold E · Reset the breaker" plus the seconds
## still to hold while holding; not tripped: greyed "Nothing to reset." get_hold_progress() 0..1 feeds the HUD.
## Visual: `Visual/Lever` swings down while tripped (cosmetic, every peer from Events.power_changed).

const PROMPT_RESET := "Hold %s · Reset the breaker"
const PROMPT_HOLDING := "Hold %s · Reset the breaker · %.1f s"
const REASON_NOTHING := "Nothing to reset."
const REASON_TOO_FAR := "Too far."
const LEVER_TRIPPED_DEG := 55.0
const LEVER_SWING_SEC := 0.18
## After a request the box waits this long before another hold can send again (a "Too far." refusal is a toast).
const RESEND_GUARD_SEC := 1.0

var _hold: float = 0.0
var _holding: bool = false
var _sent: bool = false
var _lever_tween: Tween

@onready var _lever: Node3D = get_node_or_null(^"Visual/Lever") as Node3D


func _ready() -> void:
	Events.power_changed.connect(_on_power_changed)
	_apply_lever(Events.is_power_on(), false)


func _process(delta: float) -> void:
	if not _holding:
		return
	var player: Player = Game.local_player
	if player == null or not is_instance_valid(player) or not _still_holding(player):
		_stop_hold()
		return
	_hold += delta
	if _hold >= _reset_sec():
		_holding = false
		_hold = _reset_sec()
		request_reset()


# --- queries -------------------------------------------------------------------------------------------------------

## True while the mains are off (the breaker needs a reset).
func is_tripped() -> bool:
	return not Events.is_power_on()


## 0..1 of the current hold (0 when nobody holds).
func get_hold_progress() -> float:
	return clampf(_hold / _reset_sec(), 0.0, 1.0)


## True while the local worker is holding the reset.
func is_holding() -> bool:
	return _holding


# --- Interactable overrides ---------------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	if not is_tripped():
		return REASON_NOTHING
	var key := HUD.action_key_text(&"interact", "E")
	if _holding:
		return PROMPT_HOLDING % [key, maxf(_reset_sec() - _hold, 0.0)]
	return PROMPT_RESET % key


func can_interact(_player: Player) -> bool:
	return is_tripped()


func get_denied_reason(_player: Player) -> String:
	return "" if is_tripped() else REASON_NOTHING


## Local only: starts the hold (does NOT call super: the request goes out when the hold completes).
func interact(player: Player) -> void:
	if player == null or not player.is_local():
		return
	if not is_tripped():
		_on_denied_locally(player)
		return
	if _holding or _sent:
		return
	_holding = true
	_hold = 0.0


## Never reached through the base RPC (interact() does not send it); harmless if a stray request arrives.
func _server_interact(_player: Player) -> void:
	pass


# --- request / server -----------------------------------------------------------------------------------------------

## Any peer (local): asks the host to reset the breaker for the local worker (range-checked there).
func request_reset() -> void:
	if not is_inside_tree():
		return
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_sent = true
	_hold = 0.0
	get_tree().create_timer(RESEND_GUARD_SEC).timeout.connect(func() -> void: _sent = false)
	_rpc_request_reset.rpc_id(Const.SERVER_PEER_ID)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_reset() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	var player: Player = Game.get_player(sender)
	if player == null or not player.is_inside_tree():
		return
	var max_dist: float = Config.balance.interact_distance + server_range_slack
	# `not <=` rather than `>`: a non-finite synced position is never in range.
	if not (player.global_position.distance_to(global_position) <= max_dist):
		_rpc_denied.rpc_id(sender, REASON_TOO_FAR)
		return
	if not is_tripped():
		_rpc_denied.rpc_id(sender, REASON_NOTHING)
		return
	if Events.is_event_active(Events.EVENT_POWER_CUT):
		Events.server_end_event()
	else:
		Events.server_set_power(true)


# --- internals ----------------------------------------------------------------------------------------------------

func _reset_sec() -> float:
	return maxf(Config.balance.fuse_reset_sec, 0.05)


func _still_holding(player: Player) -> bool:
	if not is_tripped() or not Input.is_action_pressed(&"interact"):
		return false
	var interactor := player.get_interactor()
	return interactor != null and interactor.current_target == self


func _stop_hold() -> void:
	_holding = false
	_hold = 0.0


func _on_power_changed(on: bool) -> void:
	_stop_hold()
	_sent = false
	_apply_lever(on, true)


func _apply_lever(on: bool, animate: bool) -> void:
	if _lever == null:
		return
	var target := Vector3(0.0 if on else deg_to_rad(-LEVER_TRIPPED_DEG), 0.0, 0.0)
	if _lever_tween != null and _lever_tween.is_valid():
		_lever_tween.kill()
	if not animate or not is_inside_tree():
		_lever.rotation = target
		return
	_lever_tween = create_tween()
	_lever_tween.tween_property(_lever, ^"rotation", target, LEVER_SWING_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
