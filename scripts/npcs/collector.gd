class_name Collector
extends Interactable
## The collector (M15 mayhem2): a man on the loading dock who wants a payment now. A reskin of the Boss: the
## ShopkeeperNPC scene as `Body` with the suit and the tie recoloured, no booth, no clipboard. A plain child of the
## Room that Events creates on every peer when EVENT_COLLECTION starts (like the rat): no spawner, no sync of its own.
## He comes in from the roller door, stands at Room.get_collector_spot() and goes back the way he came when the event
## ends (paid, unpaid or cut short), then frees himself.
##
## Paying: hold E on him for Config.balance.collector_hold_sec. The hold is the Well's patch pattern: tracked locally
## (interact() is overridden WITHOUT a server round trip per press; _process counts it while the key is down and he is
## under the crosshair) and ONE request goes out when it completes: Events.request_pay_collector(). The request RPC
## lives on the Events autoload, not on this node, so a request that crosses his leaving never addresses a freed
## node; the host validates it there (range, back room, the event still running, cash on hand).
## Prompt "Hold E · Pay $40" (with the seconds left while holding); "Cash short." when the floor cannot cover the fee.

const PROMPT_PAY := "Hold %s · Pay $%d"
const PROMPT_PAYING := "Hold %s · Pay $%d · %.1f s"
const REASON_CASH_SHORT := "Cash short."
## Seconds he takes from the roller door to his spot, and back again.
const ARRIVE_SEC := 1.4
const LEAVE_SEC := 1.6
const TURN_SEC := 0.35
## After a request the hold cannot send again for this long (a refusal is a toast).
const RESEND_GUARD_SEC := 1.0
## The Boss's suit and tie, recoloured: another man in the same cut of coat.
const SUIT_MATERIAL_NAME := "toon_brown"
const TIE_MATERIAL_NAME := "tie_toon"

## What he wants (dollars). Set by setup() from the event's params.
var fee: int = 0

var _leaving: bool = false
var _hold: float = 0.0
var _holding: bool = false
var _sent_left: float = 0.0
var _move_tween: Tween = null

@onready var _body: Node3D = get_node_or_null(^"Body") as Node3D
@onready var _hit: CollisionObject3D = get_node_or_null(^"Hit") as CollisionObject3D


func _ready() -> void:
	_recolour()
	set_process(false)


# --- Events drives him (every peer) ---------------------------------------------------------------------------------

## Every peer, from Events: he wants `amount`, comes in at `from` (global floor point at the roller door) and stands
## at `spot`. `elapsed` is how long the event has been running (a late joiner finds him where he is by now).
func setup(amount: int, from: Vector3, spot: Transform3D, elapsed: float = 0.0) -> void:
	fee = maxi(amount, 0)
	_leaving = false
	_kill_move()
	global_transform = spot
	if elapsed >= ARRIVE_SEC or not is_inside_tree() or not from.is_finite():
		return
	var t := clampf(elapsed / ARRIVE_SEC, 0.0, 1.0)
	global_position = from.lerp(spot.origin, t)
	_move_tween = create_tween()
	_move_tween.tween_property(self, ^"global_position", spot.origin, ARRIVE_SEC * (1.0 - t)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Every peer: he was paid. A cold nod, the money counted; he leaves when the event ends a moment later.
func set_paid() -> void:
	_stop_hold()
	if _body != null and _body.has_method(&"cheer"):
		_body.call(&"cheer")


## Every peer: the event is over. He turns, walks back to `to` (the roller door) and is gone. Nobody can pay him now.
func leave(to: Vector3) -> void:
	if _leaving:
		return
	_leaving = true
	_stop_hold()
	if _hit != null:
		_hit.collision_layer = 0
	_kill_move()
	if not is_inside_tree() or not to.is_finite():
		queue_free()
		return
	var away := to - global_position
	away.y = 0.0
	_move_tween = create_tween()
	if away.length_squared() > 0.0001:
		_move_tween.tween_property(self, ^"global_rotation:y", atan2(-away.x, -away.z), TURN_SEC)
	_move_tween.tween_property(self, ^"global_position", to, LEAVE_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_move_tween.tween_callback(queue_free)


func is_leaving() -> bool:
	return _leaving


## Shows a short line above him (the Body's bark label). Story owns the words.
func bark(text: String, duration: float = -1.0) -> void:
	if _body != null and _body.has_method(&"bark"):
		_body.call(&"bark", text, duration)


## The line shown above him right now ("" when he is quiet).
func get_current_bark() -> String:
	if _body != null and _body.has_method(&"get_current_bark"):
		return String(_body.call(&"get_current_bark"))
	return ""


# --- Interactable (pure) ---------------------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	if _leaving:
		return ""
	var key := HUD.action_key_text(&"interact", "E")
	if _holding:
		return PROMPT_PAYING % [key, fee, maxf(_hold_sec() - _hold, 0.0)]
	return PROMPT_PAY % [key, fee]


func can_interact(_player: Player) -> bool:
	return not _leaving and Events.is_event_active(Events.EVENT_COLLECTION) and GameState.money >= fee


func get_denied_reason(_player: Player) -> String:
	if _leaving or not Events.is_event_active(Events.EVENT_COLLECTION):
		return ""
	return REASON_CASH_SHORT if GameState.money < fee else ""


## Local only: E on him starts the pay hold (does NOT call super: the request goes out when the hold completes).
func interact(player: Player) -> void:
	if player == null or not player.is_local():
		return
	if not can_interact(player):
		_on_denied_locally(player)
		return
	if _holding or _sent_left > 0.0:
		return
	_holding = true
	_hold = 0.0
	set_process(true)


## 0..1 of the local worker's pay hold (0 when nobody holds here).
func get_pay_progress() -> float:
	return clampf(_hold / _hold_sec(), 0.0, 1.0)


## True while the local worker holds the payment.
func is_paying() -> bool:
	return _holding


func _process(delta: float) -> void:
	if _sent_left > 0.0:
		_sent_left = maxf(_sent_left - delta, 0.0)
	if _holding:
		var player: Player = Game.local_player
		if player == null or not is_instance_valid(player) or not _still_paying(player):
			_stop_hold()
		else:
			_hold += delta
			if _hold >= _hold_sec():
				_stop_hold()
				_sent_left = RESEND_GUARD_SEC
				Events.request_pay_collector()
	if not _holding and _sent_left <= 0.0:
		set_process(false)


func _hold_sec() -> float:
	return maxf(Config.balance.collector_hold_sec, 0.05)


func _still_paying(player: Player) -> bool:
	if _leaving or not can_interact(player) or not Input.is_action_pressed(&"interact"):
		return false
	var interactor := player.get_interactor()
	return interactor != null and interactor.current_target == self


func _stop_hold() -> void:
	_holding = false
	_hold = 0.0


func _kill_move() -> void:
	if _move_tween != null and _move_tween.is_valid():
		_move_tween.kill()
	_move_tween = null


## The same model in another coat: every surface that wears the Boss's brown gets a cold slate, the tie a dull red.
## Overrides on this instance's meshes only (the Boss keeps his own).
func _recolour() -> void:
	if _body == null:
		return
	var suit := Toon.material(Toon.darker(Toon.COOL_GRAY, 0.3), Toon.Finish.SOFT)
	var tie := Toon.material(Toon.darker(Toon.TOMATO, 0.2), Toon.Finish.SOFT)
	for node in _body.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		for s in mesh_node.mesh.get_surface_count():
			var current := mesh_node.get_active_material(s)
			if current == null:
				continue
			if current.resource_name == SUIT_MATERIAL_NAME:
				mesh_node.set_surface_override_material(s, suit)
			elif current.resource_name == TIE_MATERIAL_NAME:
				mesh_node.set_surface_override_material(s, tie)
