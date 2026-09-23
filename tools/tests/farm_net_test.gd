extends SceneTree
## Two-process ENet replication test for GrowPlot (owner: farming agent).
##   godot --headless --path . -s res://tools/tests/farm_net_test.gd
## The host process spawns a client process of this same script (--role=client) on a random local port,
## drives the plots step by step and prints PASS/FAIL lines for what the client observed through the
## plots' MultiplayerSynchronizer. Exit code 0 = all passed, 1 = failures, 2 = timeout / setup error.
## The logic lives in farm_net_suite.gd (loaded at runtime so the autoloads exist when it compiles).

const SUITE_PATH := "res://tools/tests/farm_net_suite.gd"
const TIMEOUT_SEC := 60.0

func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(SUITE_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + SUITE_PATH)
		quit(2)
		return
	var suite: Node = script.new()
	suite.name = "FarmNet"   # same path (/root/FarmNet) in both processes
	suite.connect(&"finished", _on_finished)
	root.add_child(suite)
	_start(suite)

func _start(suite: Node) -> void:
	await process_frame   # the root only enters the tree after _initialize returns
	suite.call(&"run")

func _on_finished(failures: int) -> void:
	quit(0 if failures == 0 else 1)

func _on_timeout() -> void:
	print("FAIL: farm_net_test timed out after %d s" % int(TIMEOUT_SEC))
	quit(2)
