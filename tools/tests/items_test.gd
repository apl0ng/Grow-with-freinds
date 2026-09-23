extends SceneTree
## Headless test for the interaction/carry systems (Interactor, Item, ItemManager, item scenes).
##   godot --headless --path . -s res://tools/tests/items_test.gd              (real world.tscn)
##   godot --headless --path . -s res://tools/tests/items_test.gd -- --minimal  (fallback minimal tree)
## Launcher only: the checks live in items_test_body.gd (a Node script compiled after the autoloads exist;
## a SceneTree main script cannot reference Game/Const/Config... at compile time).
## Exit code: 0 all passed, 1 failures, 2 timeout (e.g. a script error aborted the test coroutine).

const BODY_PATH := "res://tools/tests/items_test_body.gd"
const TIMEOUT_SEC := 60.0

func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(BODY_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + BODY_PATH)
		quit(1)
		return
	var body: Node = script.new()
	body.name = "ItemsTest"
	root.add_child(body)

func _on_timeout() -> void:
	print("FAIL: test timed out after %d s (script error inside the test coroutine?)" % int(TIMEOUT_SEC))
	quit(2)
