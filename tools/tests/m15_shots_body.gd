extends "res://tools/tests/smoke_base.gd"
## M15 in-game screenshots on the REAL renderer (lead tool, not a suite): the alley's ball, hoop and notice board with a
## briefing and a record on it, the condition chips and the job line on the HUD, the supply window with the market and
## the locked strains, the raid, the sprinklers, the collector, the Record card and the shift report's job line.
## Needs a window (about 80 s) and the lobby and replay on (the defaults in a windowed run):
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m15_shots_body.gd --out=<abs dir> \
##       --port=7972 --mute --no-mic --career-file=<abs path of a seeded temp file>
## Without --career-file the record is empty and nothing is written (Career keeps a scripted run in memory); NEVER
## point it at the real user://career.cfg. Under --headless it prints a hint and exits 0. The mouse is never
## captured; a watchdog ends the run after 150 s.

var _out := "user://m15_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m15_shots"
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
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
	if not check(lobby != null and lobby.get_van() != null, "the alley and the van exist"):
		finish()
		return
	var hud := Game.world.get_node("HUD") as HUD
	await wait_sec(1.0)

	step("the alley: ball, hoop, board")
	var board: Object = lobby.get_board() if lobby.has_method(&"get_board") else null
	if board != null and board.has_method(&"server_record_shift"):
		board.call(&"server_record_shift", true, 3, 420, 400,
				["Zay did the least.", "Dale was noticed. He deposited the most.", "Chloe was written up the most."])
	# What a later shift looks like before boarding: two conditions, a market, a job.
	GameState.server_set_conditions([ShiftConditions.ID_DRY_AIR, ShiftConditions.make_id(ShiftConditions.ID_BUYER, &"purple")])
	GameState.server_set_market({&"budget": 0.8, &"purple": 1.2, &"creeper": 1.1, &"golden": 0.9})
	GameState.server_set_contract(&"cured")
	await wait_sec(1.0)
	_look(Vector3(-2.2, 0.0, 82.0), Vector3(1.2, 2.3, 87.2))
	await wait_sec(0.6)
	await _shot("1_alley_corner")
	_look(Vector3(1.9, 0.0, 85.3), Vector3(4.94, 2.05, 85.3))
	await wait_sec(0.6)
	await _shot("2_alley_board")
	_look(Vector3(0.3, 0.0, 84.6), Vector3(-0.9, 2.6, 87.3))
	await wait_sec(0.6)
	await _shot("3_alley_hoop")
	_look(Vector3(-1.2, 0.0, 78.9), Vector3(-1.6, 0.3, 80.4))
	await wait_sec(0.6)
	await _shot("4_alley_ball")

	step("the ride")
	var van: Van = lobby.get_van()
	var seat := van.get_seat_transform(0)
	_me.velocity = Vector3.ZERO
	_me.global_position = seat.origin + Vector3.UP * 0.05
	await wait_until(func() -> bool: return GameState.is_playing(), 10.0, "the ride ends in a running shift")
	if not GameState.is_playing():
		finish()
		return
	await wait_sec(2.2)

	step("the floor: chips, the job line, the supply window")
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(3.0, 1.2, -3.0))
	await wait_sec(0.8)
	await _shot("5_hud_chips_job")
	var room := Game.world.room
	var counter := room.get_station("ShopCounter") as ShopCounter
	teleport(_me, counter)
	await wait_sec(0.3)
	counter.interact(_me)
	await wait_sec(1.0)
	await _shot("6_supply_window_market")
	var ui := counter.get_shop_ui()
	if ui != null and ui.is_open():
		ui.close()
	await wait_sec(0.3)

	step("the raid")
	Config.balance.raid_warning_sec = 5.0
	check(Events.server_start_event(Events.EVENT_RAID), "a raid")
	_look(Vector3(-2.5, 0.0, 9.5), Vector3(-2.5, 1.5, 15.6))
	await wait_sec(1.6)
	await _shot("7_raid_dock")
	_look(Vector3(-5.0, 0.0, 3.0), Vector3(-5.0, 1.4, 12.0))
	await wait_sec(1.0)
	await _shot("7b_raid_passage")
	_look(Vector3(-2.5, 0.0, 9.5), Vector3(-2.5, 1.5, 15.6))
	await wait_until(func() -> bool: return Events.is_raid_looking(), 6.0, "they look in")
	await wait_sec(0.15)
	await _shot("7c_raid_look")
	Events.server_end_event()
	await wait_sec(0.5)

	step("the sprinklers")
	check(Events.server_start_event(Events.EVENT_SPRINKLERS), "the sprinklers")
	_look(Vector3(-8.0, 0.0, 6.0), Vector3(4.0, 1.5, -3.0))
	await wait_sec(2.5)
	await _shot("8_sprinklers_main")
	_look(Vector3(12.0, 0.0, 6.0), Vector3(20.0, 1.5, -4.0))
	await wait_sec(1.0)
	await _shot("8b_sprinklers_hall")
	Events.server_end_event()
	await wait_sec(0.5)

	step("the collector")
	check(Events.server_start_event(Events.EVENT_COLLECTION), "the collector")
	_look(Vector3(-2.5, 0.0, 10.8), Vector3(-2.5, 1.3, 13.6))
	await wait_sec(2.6)
	await _shot("9_collector")
	_look(Vector3(-1.6, 0.0, 12.0), Vector3(-2.5, 1.45, 13.6))
	await wait_sec(0.5)
	await _shot("9b_collector_prompt")
	Events.server_end_event()
	await wait_sec(0.5)

	step("the Record card and the report")
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(3.0, 1.2, -3.0))
	hud.pause_menu.open()
	await wait_sec(0.8)
	await _shot("10_pause_record")
	hud.pause_menu.close()
	await wait_sec(0.3)
	GameState.call(&"_server_end_round", false)
	await wait_sec(2.0)
	await _shot("11_report_job")
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
