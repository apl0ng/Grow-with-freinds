extends SceneTree
## Headless test for the first-person view-model layer (task 9.6): Player view model (SubViewport + camera +
## composite) and Item render-layer switching, single process + a real host/client pair over ENet.
##   godot --headless --path . -s res://tools/tests/review_viewmodel_test.gd          (host; launches the client)
## Launcher only: the checks live in review_viewmodel_body.gd (a Node script compiled after the autoloads exist).
## Exit code: 0 all passed, 1 failures, 2 timeout.

const BODY_PATH := "res://tools/tests/review_viewmodel_body.gd"
const TIMEOUT_SEC := 100.0

func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(BODY_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + BODY_PATH)
		quit(1)
		return
	var body: Node = script.new()
	body.name = "ViewModelTest" # same path in both processes: host and client talk over RPC
	root.add_child(body)

func _on_timeout() -> void:
	print("FAIL: review_viewmodel_test timed out after %d s (script error inside the test coroutine?)" % int(TIMEOUT_SEC))
	quit(2)
