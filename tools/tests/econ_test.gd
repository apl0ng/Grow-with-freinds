extends SceneTree
## Economy tests (shop counter, shop UI, turn-in station). Headless:
##   godot --headless --path . -s res://tools/tests/econ_test.gd            (all parts)
##   godot --headless --path . -s res://tools/tests/econ_test.gd -- --econ-part1-only
## Prints PASS / FAIL / SKIP lines and exits 0 when nothing failed, 1 on failures, 2 on timeout / crash.
##
## Scripts given with -s are compiled BEFORE the autoloads exist, so this file only bootstraps: on the first
## frame it loads the typed runner (econ_test_cases.gd), which can use Game / GameState / class names freely.

const RUNNER_PATH := "res://tools/tests/econ_test_cases.gd"
const TIMEOUT_SEC := 120.0

var _done := false


func _initialize() -> void:
	process_frame.connect(_start, CONNECT_ONE_SHOT)


func _start() -> void:
	create_timer(TIMEOUT_SEC, true, false, true).timeout.connect(_on_timeout)
	var script := load(RUNNER_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL  econ_test: could not load %s" % RUNNER_PATH)
		_finish(2)
		return
	var runner: Node = script.new()
	runner.name = "EconTestRunner"
	root.add_child(runner)
	runner.connect(&"finished", _on_finished)
	runner.call(&"run")


func _on_finished(failures: int) -> void:
	_finish(1 if failures > 0 else 0)


func _on_timeout() -> void:
	if not _done:
		print("FAIL  econ_test: timed out after %d s" % int(TIMEOUT_SEC))
		_finish(2)


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	quit(code)
