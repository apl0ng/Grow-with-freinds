extends "res://tools/tests/smoke_base.gd"
## M14 in-game screenshots on the REAL renderer (lead tool, not a suite): the alley, the van, the pile-in countdown and
## the arrival on the floor. Needs a window (about 40 s) and the lobby on (the default in a windowed run):
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m14_shots_body.gd --out=<abs dir> \
##       --port=7971 --mute --no-mic
## Under --headless it prints a hint and exits 0. The mouse is never captured; a watchdog ends the run after 70 s.

var _out := "user://m14_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m14_shots"
	get_tree().create_timer(70.0).timeout.connect(func() -> void:
		print("m14_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m14_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame
	check(Config.lobby_enabled, "the lobby is on in a windowed run")
	Game.start_host("Zay", port_arg(7971))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var lobby: Lobby = Game.world.lobby
	if not check(lobby != null and lobby.get_van() != null, "the alley and the van exist"):
		finish()
		return
	var van: Van = lobby.get_van()
	await wait_sec(1.0)
	check(GameState.phase == GameState.Phase.WAITING and lobby.contains_point(_me.global_position), "waiting in the alley")

	step("the alley")
	var bounds := lobby.get_bounds()
	var van_pos := van.global_position
	# From the far end of the alley, looking at the van's open doors.
	var entry := van.get_entry_point()
	var away := (entry - van_pos)
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3.BACK
	_face(entry + away * 5.0 + Vector3(1.2, 0.0, 0.0), van_pos + Vector3.UP * 1.3)
	await wait_sec(0.8)
	await _shot("1_alley_van")
	# A wide look across the alley from a corner.
	var corner := bounds.position + Vector3(0.8, 0.0, 0.8)
	_face(Vector3(corner.x, 0.0, corner.z), bounds.get_center() + Vector3.UP * 1.2)
	await wait_sec(0.6)
	await _shot("2_alley_wide")

	step("in the van")
	var seat := van.get_seat_transform(0)
	_me.velocity = Vector3.ZERO
	_me.global_position = seat.origin + Vector3.UP * 0.05
	var out_dir := entry - seat.origin
	out_dir.y = 0.0
	_me.rotation = Vector3(0.0, atan2(-out_dir.x, -out_dir.z), 0.0)
	_me.head.rotation.x = 0.0
	await wait_sec(0.9)
	await _shot("3_in_the_van_countdown")
	await wait_until(func() -> bool: return GameState.is_playing(), 8.0, "the ride ends in a running shift")
	await wait_sec(1.6)
	await _shot("4_arrival")
	check(not lobby.contains_point(_me.global_position), "on the floor after the ride")

	step("the leak")
	var room := Game.world.room
	var well := room.get_station("Well") as Node3D
	check(Events.server_start_event(Events.EVENT_LEAK), "the tank leaks")
	_face(well.global_position + Vector3(3.6, 0.0, 2.4), well.global_position + Vector3(0.4, 0.7, 1.0))
	await wait_sec(5.0)
	await _shot("5_leak")
	Events.server_end_event()
	await wait_sec(0.4)

	step("the drive-by")
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "a drive-by")
	# In the main room, off the lanes, looking at the dock passage the rounds come through.
	_face(Vector3(0.6, 0.0, 0.4), Vector3(-5.0, 1.2, 10.5))
	await wait_sec(1.2)
	await _shot("6_driveby_warning")
	await wait_until(func() -> bool: return Events.is_driveby_firing(), 5.0, "the shooting starts")
	await wait_sec(1.0)
	await _shot("7_driveby_fire")
	await wait_sec(0.9)
	await _shot("7b_driveby_fire")
	await wait_until(func() -> bool: return not Events.is_event_active(), 9.0, "it ends")
	await wait_sec(0.6)
	await _shot("8_driveby_bill")
	finish()


## Puts the local player at `pos` (floor) looking at `target` (world space).
func _face(pos: Vector3, target: Vector3) -> void:
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
	print("m14_shots: ", ProjectSettings.globalize_path(path))
