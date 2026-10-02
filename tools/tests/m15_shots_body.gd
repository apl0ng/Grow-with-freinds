extends "res://tools/tests/smoke_base.gd"
## M15 in-game screenshots on the REAL renderer (lead tool, not a suite): the alley's ball, hoop and notice board, then
## (when those branches are merged) the shift conditions, the contract line and the three M15 events on the floor.
## Needs a window (about 45 s) and the lobby on (the default in a windowed run):
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m15_shots_body.gd --out=<abs dir> \
##       --port=7972 --mute --no-mic --career-file=user://career_shots.cfg
## Under --headless it prints a hint and exits 0. The mouse is never captured; a watchdog ends the run after 80 s.

var _out := "user://m15_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m15_shots"
	get_tree().create_timer(80.0).timeout.connect(func() -> void:
		print("m15_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m15_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7972))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var lobby: Lobby = Game.world.lobby
	if not check(lobby != null, "the alley exists"):
		finish()
		return
	await wait_sec(1.0)

	step("the alley: ball, hoop, board")
	var board: Object = lobby.get_board() if lobby.has_method(&"get_board") else null
	if board != null and board.has_method(&"server_record_shift"):
		board.call(&"server_record_shift", true, 3, 420, 400,
				["Zay did the least.", "Dale was noticed. He deposited the most.", "Chloe was written up the most."])
	await wait_sec(0.8)
	_look(Vector3(-2.2, 0.0, 82.0), Vector3(1.2, 2.3, 87.2))
	await wait_sec(0.6)
	await _shot("1_alley_corner")
	_look(Vector3(0.9, 0.0, 85.3), Vector3(4.94, 2.05, 85.3))
	await wait_sec(0.6)
	await _shot("2_alley_board")
	_look(Vector3(0.3, 0.0, 84.6), Vector3(-0.9, 2.6, 87.3))
	await wait_sec(0.6)
	await _shot("3_alley_hoop")
	_look(Vector3(-1.2, 0.0, 78.9), Vector3(-1.6, 0.3, 80.4))
	await wait_sec(0.6)
	await _shot("4_alley_ball")
	finish()


## Puts the local player at `pos` (x / z; the height stays) looking at `target` (world space).
func _look(pos: Vector3, target: Vector3) -> void:
	_me.velocity = Vector3.ZERO
	_me.global_position = Vector3(pos.x, _me.global_position.y, pos.z)
	var eye := _me.global_position + Vector3.UP * 1.6
	var dir := (target - eye).normalized()
	_me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	_me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


func _shot(shot: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("m15_shots: ", ProjectSettings.globalize_path(path))
