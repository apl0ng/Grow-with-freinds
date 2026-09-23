class_name Interactable
extends Node3D
## Base class for anything a player can look at and press E on (stations AND carryable items).
##
## Flow (server-authoritative):
##   1. Interactor (local client) raycasts, finds an Interactable, shows get_prompt().
##   2. On E: interact(player) -> checks can_interact() locally -> RPC to server.
##   3. Server re-validates (distance + can_interact) and calls _server_interact(player).
##   4. Server mutates synced state (MultiplayerSynchronizer / ItemManager / GameState) -> everyone sees it.
##
## Subclasses override: get_prompt(), can_interact(), _server_interact(). Optionally get_denied_reason().
## Physical setup: put a StaticBody3D or Area3D child with collision_layer = Const.LAYER_INTERACTABLE
## (or LAYER_ITEM for items). The Interactor walks up from the hit collider to find this node.

## Extra slack (metres) added to Config.balance.interact_distance for the server-side distance check.
@export var server_range_slack: float = 2.0
## Default verb shown in the prompt when a subclass does not override get_prompt().
@export var prompt_verb: String = "Interact"

func _enter_tree() -> void:
	add_to_group(Const.GROUP_INTERACTABLES)

## Text shown in the HUD prompt, e.g. "Plant Budget Bud", "Water plant", "Buy seeds". Return "" to hide.
func get_prompt(_player: Player) -> String:
	return prompt_verb

## Client-side prediction AND server-side validation. Keep it pure (no side effects).
func can_interact(_player: Player) -> bool:
	return true

## Optional short reason shown greyed-out in the prompt when can_interact() is false ("Hands full", "Needs water").
func get_denied_reason(_player: Player) -> String:
	return ""

## Called on the local client by the Interactor. Do not override; override _server_interact instead.
func interact(player: Player) -> void:
	if player == null or not player.is_local():
		return
	if not can_interact(player):
		_on_denied_locally(player)
		return
	_rpc_request_interact.rpc_id(Const.SERVER_PEER_ID)

@rpc("any_peer", "call_local", "reliable")
func _rpc_request_interact() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	var player: Player = Game.get_player(sender)
	if player == null:
		return
	var max_dist: float = Config.balance.interact_distance + server_range_slack
	if player.global_position.distance_to(global_position) > max_dist:
		_rpc_denied.rpc_id(sender, "Too far away")
		return
	if not can_interact(player):
		_rpc_denied.rpc_id(sender, get_denied_reason(player))
		return
	_server_interact(player)

## SERVER ONLY. Perform the interaction and mutate synced state. `player` is the requesting player's node.
func _server_interact(_player: Player) -> void:
	pass

@rpc("authority", "call_local", "reliable")
func _rpc_denied(reason: String) -> void:
	if reason != "":
		Game.toast(reason, &"error")
	Sfx.play(&"error")

func _on_denied_locally(player: Player) -> void:
	var reason := get_denied_reason(player)
	if reason != "":
		Game.toast(reason, &"error")
	Sfx.play(&"error")
