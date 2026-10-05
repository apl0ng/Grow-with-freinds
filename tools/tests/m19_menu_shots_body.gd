extends "res://tools/tests/smoke_base.gd"
## M19 lead capture (real renderer, not a suite): the main menu with its version line, the OPTIONS card from the main
## menu and from the break card, and the guided first shift (the Boss's line and the hint line at the buy and the
## water steps). The readability capture (m19_shots_body.gd) covers the busiest moments.
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m19_menu_shots_body.gd --out=<abs dir> \
##       --port=7977 --mute --no-mic --replay --run=B5VP --guide --no-lobby --event-delay=900 \
##       --career-file=<abs path of an EMPTY temp file> --settings-file=<abs path of a temp file>
## Under --headless it prints a hint and exits 0. The mouse is never captured; a watchdog ends the run after 90 s.

var _out := "user://m19_menu_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m19_menu_shots"
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("m19_menu_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m19_menu_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	Config.lobby_enabled = false
	await get_tree().process_frame

	step("the main menu")
	var menu := (load("res://scenes/main_menu/main_menu.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await wait_sec(1.0)
	await _shot("1_main_menu")
	if menu.has_method(&"open_options"):
		menu.call(&"open_options")
		await wait_sec(0.6)
		await _shot("2_options_from_menu")
	menu.queue_free()
	await wait_sec(0.3)

	step("the break card")
	Game.start_host("Zay", port_arg(7977))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var pm: Node = Game.world.get_node("HUD").get(&"pause_menu")
	pm.call(&"open")
	await wait_sec(0.6)
	await _shot("3_break_card")
	if pm.has_method(&"open_options"):
		pm.call(&"open_options")
		await wait_sec(0.6)
		await _shot("4_options_from_break")
	pm.call(&"close")
	await wait_sec(0.4)

	step("the guided first shift")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "shift 1 runs")
	_look(Vector3(0.0, 0.0, -2.4), Vector3(-0.3, 1.9, -5.6))
	Story.tick(3.1)
	if Story.get(&"guide") != null:
		Story.guide.tick(1.2)
	await wait_sec(1.0)
	await _shot("5_guide_buy")
	var room: Room = Game.world.room
	var counter := room.get_station("ShopCounter") as ShopCounter
	counter.call(&"server_buy_seed", 1, &"budget")
	await wait_sec(0.4)
	var tray := room.get_station("GrowPlot1") as GrowPlot
	tray._server_interact(_me)
	await wait_sec(0.4)
	_look(Vector3(-4.5, 0.0, -1.5), Vector3(-7.0, 1.0, -3.0))
	Story.tick(3.1)
	if Story.get(&"guide") != null:
		Story.guide.tick(1.2)
	await wait_sec(1.0)
	await _shot("6_guide_water")
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
	print("m19_menu_shots: ", ProjectSettings.globalize_path(path))
