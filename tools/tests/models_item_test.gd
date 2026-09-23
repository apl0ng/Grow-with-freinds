extends SceneTree
## Headless test for the modelled held items (item modeler): the Blender models hooked into
## scenes/items/{watering_can,seed_packet,product}.tscn keep every node the item scripts drive, the runtime tint
## path gives Toon.grade(seed.color) on the model (Toonify tint + per-instance overrides), labels / the gauge /
## the product scale still update, and the hold poses keep the crosshair and the camera near plane clear.
##   godot --headless --path . -s res://tools/tests/models_item_test.gd
## Launcher only: the checks live in models_item_test_body.gd (a Node script compiled after the autoloads exist).
## Exit code: 0 all passed, 1 failures, 2 timeout.

const BODY_PATH := "res://tools/tests/models_item_test_body.gd"
const TIMEOUT_SEC := 60.0


func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(BODY_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + BODY_PATH)
		quit(1)
		return
	var body: Node = script.new()
	body.name = "ModelsItemTest"
	root.add_child(body)


func _on_timeout() -> void:
	print("FAIL: test timed out after %d s (script error inside the test coroutine?)" % int(TIMEOUT_SEC))
	quit(2)
