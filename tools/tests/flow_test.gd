extends SceneTree
## Headless game-flow test: GameState phases/money/quota/timer/upgrades + HUD, round-end overlay,
## pause menu and toasts driven through their signals. Owned by the game-flow/UI agent.
##
##   godot --headless --path . -s res://tools/tests/flow_test.gd
##
## This process is peer 1 with the default OfflineMultiplayerPeer, so multiplayer.is_server() is true
## and call_local RPCs execute locally. Prints PASS/FAIL lines; exit code 0 only if every check
## passed AND no engine/script error was logged while the test ran.
## The cases live in flow_test_cases.gd, loaded at runtime: this -s script is compiled before the
## autoloads exist, so it cannot name GameState/Game/Net itself.

const CASES_PATH := "res://tools/tests/flow_test_cases.gd"
const MAX_FRAMES: int = 6000

class ErrorCounter extends Logger:
	var errors: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		errors.append("%s (%s:%d %s) %s" % [code, file, line, function, rationale])

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _frames: int = 0
var _logger: ErrorCounter
var _done: bool = false


func _initialize() -> void:
	_logger = ErrorCounter.new()
	OS.add_logger(_logger)
	await process_frame # the multiplayer API only works once the tree is running
	var script: Script = load(CASES_PATH)
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + CASES_PATH)
		_finish(0, 1)
		return
	var cases: Node = script.new()
	cases.name = "FlowTestCases"
	root.add_child(cases)
	await cases.call(&"run")
	var passed: int = cases.get(&"passed")
	var failed: int = cases.get(&"failed")
	cases.queue_free()
	# Let voices finish so the Sfx autoload does not report leaked playbacks at exit.
	var sfx: Node = root.get_node_or_null(^"Sfx")
	if sfx != null and sfx.has_method(&"stop_all"):
		sfx.call(&"stop_all")
	for i in 3:
		await process_frame
	_finish(passed, failed)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > MAX_FRAMES and not _done:
		print("FAIL: watchdog - test did not finish within %d frames" % MAX_FRAMES)
		_finish(0, 1)
		return true
	return false


func _finish(passed: int, failed: int) -> void:
	if _done:
		return
	_done = true
	OS.remove_logger(_logger)
	if _logger.errors.is_empty():
		passed += 1
		print("PASS: no engine/script errors logged during the test")
	else:
		failed += 1
		print("FAIL: %d engine/script errors logged during the test" % _logger.errors.size())
		for e in _logger.errors:
			print("   error: " + e)
	print("flow_test: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
