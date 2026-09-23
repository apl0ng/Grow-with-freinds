extends SceneTree
## Two-process GameState sync test over real ENet (localhost). Owned by the game-flow/UI agent.
##
##   godot --headless --path . -s res://tools/tests/flow_mp_test.gd
##
## The host process spawns a headless client process (same script, "-- --role=client --port=N").
## GameState gets its own SceneMultiplayer branch rooted at /root/GameState (SceneTree.set_multiplayer),
## so the Net autoload is never involved: this tests GameState's RPC sync on its own. The step driver
## (flow_mp_cases.gd) is added as /root/GameState/FlowMpCases so its RPCs share that branch/connection
## and stay ordered with GameState's reliable RPCs.
## The host prints its own PASS/FAIL lines plus the client's report; exit code 0 only if both sides
## passed every check and logged no engine/script errors.

const CASES_PATH := "res://tools/tests/flow_mp_cases.gd"
const TIMEOUT_MSEC: int = 90000

class ErrorCounter extends Logger:
	var errors: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		errors.append("%s (%s:%d %s) %s" % [code, file, line, function, rationale])

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _role: String = "host"
var _port: int = 0
var _client_pid: int = -1
var _logger: ErrorCounter
var _start_msec: int = 0
var _done: bool = false


func _initialize() -> void:
	_start_msec = Time.get_ticks_msec()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.get_slice("=", 1)
		elif arg.begins_with("--port="):
			_port = int(arg.get_slice("=", 1))
	_logger = ErrorCounter.new()
	OS.add_logger(_logger)
	await process_frame # autoloads + multiplayer API usable from here

	var game_state: Node = root.get_node_or_null(^"GameState")
	var script: Script = load(CASES_PATH)
	if game_state == null or script == null or not script.can_instantiate():
		print("FAIL: [%s] GameState autoload or %s missing" % [_role, CASES_PATH])
		_finish(1)
		return

	var mp := SceneMultiplayer.new()
	set_multiplayer(mp, game_state.get_path())
	var peer := ENetMultiplayerPeer.new()
	var err: Error = ERR_CANT_CREATE
	if _role == "host":
		for attempt in 5:
			_port = 20000 + randi() % 20000
			err = peer.create_server(_port, 4)
			if err == OK:
				break
	else:
		err = peer.create_client("127.0.0.1", _port)
	if err != OK:
		print("FAIL: [%s] ENet setup failed on port %d: %s" % [_role, _port, error_string(err)])
		_finish(1)
		return
	mp.multiplayer_peer = peer

	var cases: Node = script.new()
	cases.name = "FlowMpCases"
	cases.set(&"role", _role)
	cases.set(&"error_logger", _logger)
	game_state.add_child(cases)

	if _role == "host":
		var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/tests/flow_mp_test.gd", "--", "--role=client", "--port=%d" % _port])
		_client_pid = OS.create_process(OS.get_executable_path(), args)
		if _client_pid <= 0:
			print("FAIL: could not spawn the client process")
			_finish(1)
			return
		print("flow_mp_test: host on port %d, client pid %d" % [_port, _client_pid])

	var failures: int = await cases.call(&"run")

	if _role == "host":
		# Give the client a moment to exit on its own.
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(_client_pid) and Time.get_ticks_msec() - t0 < 5000:
			await process_frame
		if OS.is_process_running(_client_pid):
			OS.kill(_client_pid)
	else:
		for i in 20: # flush the report packet before closing
			await process_frame
	cases.queue_free()
	var sfx: Node = root.get_node_or_null(^"Sfx")
	if sfx != null and sfx.has_method(&"stop_all"):
		sfx.call(&"stop_all")
	for i in 3:
		await process_frame
	peer.close()
	_finish(failures)


func _process(_delta: float) -> bool:
	if not _done and Time.get_ticks_msec() - _start_msec > TIMEOUT_MSEC:
		print("FAIL: [%s] watchdog timeout (%d ms)" % [_role, TIMEOUT_MSEC])
		if _client_pid > 0 and OS.is_process_running(_client_pid):
			OS.kill(_client_pid)
		_finish(1)
		return true
	return false


func _finish(failures: int) -> void:
	if _done:
		return
	_done = true
	OS.remove_logger(_logger)
	if _role == "host":
		if not _logger.errors.is_empty():
			failures += 1
			print("FAIL: [host] %d engine/script errors logged" % _logger.errors.size())
			for e in _logger.errors:
				print("   error: " + e)
		else:
			print("PASS: [host] no engine/script errors logged")
		print("flow_mp_test: %s" % ("ALL PASSED" if failures == 0 else "%d FAILURES" % failures))
	quit(0 if failures == 0 else 1)
