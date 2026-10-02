class_name Ball
extends Item
## The alley ball (M15 alley agent; scenes/items/ball.tscn, model art/models/ball.glb): a scuffed, half-flat rubber
## ball, 0.24 m across. An ordinary item: picked up, dropped and thrown like any other; a thrown ball that hits a
## worker staggers them (ItemManager's flight step, nothing special here). It has no props.
##
## It lives in the alley only: the host's Lobby spawns one when the alley comes into use and despawns it when the
## shift starts (scripts/world/lobby.gd, "M15 alley"). The hoop on the alley wall counts it (scripts/world/
## alley_hoop.gd).
##
## Sound (every peer, from the synced setters): `ball` wherever it comes to rest after a throw or a drop, on top of
## the base item's `drop` thud.

const SOUND: StringName = &"ball"


func _ready() -> void:
	super()
	flight_changed.connect(_on_flight_changed)
	holder_changed.connect(_on_holder_changed)


func get_display_name() -> String:
	return "Ball"


## Landed after a throw.
func _on_flight_changed(flying: bool) -> void:
	if not flying and holder_id == 0 and is_inside_tree():
		Sfx.play(SOUND, global_position)


## Let go of by hand (a throw is announced by the flight instead).
func _on_holder_changed(old_holder: int, new_holder: int) -> void:
	if old_holder != 0 and new_holder == 0 and not is_flying() and is_inside_tree():
		Sfx.play(SOUND, global_position)
