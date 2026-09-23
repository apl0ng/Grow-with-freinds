extends SceneTree
## Two-process economy test over real ENet (host + client). Run both, host first:
##   godot --headless --path . -s res://tools/tests/econ_mp_test.gd -- --econ-role=host --econ-port=27411 &
##   godot --headless --path . -s res://tools/tests/econ_mp_test.gd -- --econ-role=client --econ-port=27411
## Each process prints PASS / FAIL lines and exits 0 (all passed), 1 (failures) or 2 (timeout / setup error).
## Bootstrap only (autoloads do not exist yet when -s scripts compile); the logic is in econ_mp_cases.gd.

const RUNNER_PATH := "res://tools/tests/econ_mp_cases.gd"
const TIMEOUT_SEC := 90.0

var _done := false


func _initialize() -> void:
	process_frame.connect(_start, CONNECT_ONE_SHOT)


func _start() -> void:
	create_timer(TIMEOUT_SEC, true, false, true).timeout.connect(_on_timeout)
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--econ-") and a.contains("="):
			args[a.substr(7, a.find("=") - 7)] = a.substr(a.find("=") + 1)
	var role := String(args.get("role", ""))
	var port := int(args.get("port", "27411"))
	if role != "host" and role != "client":
		print("FAIL  econ_mp_test: pass --econ-role=host|client")
		_finish(2)
		return
	var script := load(RUNNER_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL  econ_mp_test: could not load %s" % RUNNER_PATH)
		_finish(2)
		return
	var runner: Node = script.new()
	runner.name = "EconMpRunner"
	root.add_child(runner)
	runner.connect(&"finished", _on_finished)
	runner.call(&"run", role, port)


func _on_finished(failures: int) -> void:
	_finish(1 if failures > 0 else 0)


func _on_timeout() -> void:
	if not _done:
		print("FAIL  econ_mp_test: timed out after %d s" % int(TIMEOUT_SEC))
		_finish(2)


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	quit(code)
