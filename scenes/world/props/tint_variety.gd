extends Node3D
## Per-instance paint colour for a modelled prop (MODELING.md section 5C; props modeler). Attach to the
## prop's `Visual`: every copy of the same prop scene (oil drums, crates) picks one of `tints` for its
## Toonify model from where it stands, so the room gets faded blue / olive / red drums without per-instance
## overrides in room.tscn. Deterministic (it only depends on the position, rounded to 10 cm): the same
## colour on every peer and every run. Local cosmetic, no sync needed.

## Paint colours to choose from (palette / graded colours: Toonify multiplies the TINT greys by them).
@export var tints: PackedColorArray = PackedColorArray()
## The instanced .glb (a Toonify root) to recolour.
@export var model_path: NodePath = ^"Model"
## Reshuffles which position gets which colour, without moving anything.
@export var salt: int = 0


func _ready() -> void:
	var model := get_node_or_null(model_path) as Toonify
	if model == null or tints.is_empty():
		return
	model.tint = tints[pick(global_position, tints.size(), salt)]


## Index into `count` colours for a prop standing at `pos`.
static func pick(pos: Vector3, count: int, salt_value: int = 0) -> int:
	var key := Vector3i(roundi(pos.x * 10.0), roundi(pos.y * 10.0), roundi(pos.z * 10.0))
	return posmod(hash([key.x, key.y, key.z, salt_value]), maxi(count, 1))
