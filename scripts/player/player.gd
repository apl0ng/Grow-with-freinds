class_name Player
extends CharacterBody3D
## Networked first-person player. Node name == peer id as string. Movement authority = owning client.
## (STUB - owned by the networking/player agent. Contract below must be kept.)
##
## Required unique-named children in player.tscn:
##   %Camera (Camera3D)          - first-person camera, current only for the local player
##   %HandSocket (Node3D)        - under %Camera; where the local player's held item is drawn
##   %BodyHandSocket (Node3D)    - on the body; where OTHER players see this player's held item
##   %Interactor (Interactor)    - script res://scripts/interaction/interactor.gd
##   %NameLabel (Label3D)        - hidden for the local player

var peer_id: int = 1
var display_name: String = "Player"
var player_color: Color = Color.WHITE

func is_local() -> bool:
	return peer_id == multiplayer.get_unique_id()

## The socket a held item should follow on THIS peer (first-person socket for the local player).
func get_item_socket() -> Node3D:
	return self

func get_held_item() -> Item:
	if Game.world == null:
		return null
	return Game.world.items.get_held_by(peer_id)

func get_interactor() -> Interactor:
	return get_node_or_null("%Interactor") as Interactor
