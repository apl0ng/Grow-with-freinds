extends SceneTree
## End-to-end farming test on the real game stack (Game.start_host + World + items). Owner: farming agent.
##   godot --headless --path . -s res://tools/tests/farm_world_test.gd
## Prints PASS/FAIL lines and a summary; exit code 0 = all passed, 1 = failures, 2 = timeout/load error.
## The checks live in farm_world_suite.gd, loaded at runtime so the autoloads exist when it compiles.

const SUITE_PATH := "res://tools/tests/farm_world_suite.gd"
const TIMEOUT_SEC := 120.0

func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(SUITE_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + SUITE_PATH)
		quit(2)
		return
	var suite: Node = script.new()
	suite.name = "FarmWorldSuite"
	suite.connect(&"finished", _on_finished)
	root.add_child(suite)
	_start(suite)

func _start(suite: Node) -> void:
	await process_frame   # the root only enters the tree after _initialize returns
	suite.call(&"run")

func _on_finished(failures: int) -> void:
	quit(0 if failures == 0 else 1)

func _on_timeout() -> void:
	print("FAIL: farm_world_test timed out after %d s" % int(TIMEOUT_SEC))
	quit(2)
