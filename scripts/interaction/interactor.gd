class_name Interactor
extends Node3D
## Child of the Player scene (%Interactor). Raycasts from the player's camera, tracks the current
## Interactable, emits prompt text for the HUD and handles the interact/drop inputs.
## (STUB - owned by the interaction/carry agent. Contract below must be kept.)

## Emitted whenever the prompt text should change. "" means hide the prompt.
signal prompt_changed(text: String, enabled: bool)
## Emitted when the looked-at interactable changes (may be null).
signal target_changed(target: Interactable)

var player: Player
var current_target: Interactable = null

func _ready() -> void:
	player = get_parent() as Player

## Called by input (interact action) on the local player only.
func try_interact() -> void:
	pass

## Called by input (drop action) on the local player only.
func try_drop() -> void:
	pass
