extends "res://tools/tests/smoke_base.gd"
## M12 in-game screenshots on the REAL renderer (lead tool, not a suite): hosts a solo floor, stages the M12
## situations (a tray that turns, the hostile plant, the flamethrower in first person, the new banners, the supply
## window during a shortage) and saves one PNG per situation. Needs a window (it stays up for about 25 s):
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m12_shots_body.gd --out=<abs dir> \
##       --port=7970 --mute --no-mic
## Under --headless it prints a hint and exits 0. The mouse is never captured (see _process), so the run does not
## take the cursor away from whoever is at the PC.

var _out := "user://m12_shots"
var _world: World
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m12_shots"
	# Nothing else ends this run if a step errors out: never leave a window on the screen.
	get_tree().create_timer(45.0).timeout.connect(func() -> void:
		print("m12_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m12_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	var b: BalanceConfig = Config.balance
	await get_tree().process_frame   # _ready is still adding children: the world cannot be created in this frame
	Game.start_host("Zay", port_arg(7970))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_me = Game.local_player
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift running")
	await wait_sec(0.6)

	step("a tray turns")
	var plot1 := _world.room.get_station("GrowPlot1") as GrowPlot
	var night: SeedDef = b.get_seed(&"nightshift")
	night.mutation_chance = 1.0
	check(plot1.server_plant(&"nightshift") and plot1.server_water(1.0), "Night Shift in GrowPlot1")
	plot1.stage = GrowPlot.Stage.READY
	Hostiles.tick(0.05)
	check(plot1.is_turning(), "it turns")
	_face(plot1.global_position + Vector3(-1.9, 0.0, 0.0), plot1.global_position + Vector3.UP * 0.7)
	await wait_sec(1.4)
	await _shot("1_tray_moving")

	step("it comes out")
	Hostiles.tick(b.mutation_warning_sec)
	await wait_sec(0.3)
	check(Hostiles.is_any_alive(), "a hostile plant stands at the tray")
	_face(Vector3(6.4, 0.0, -0.4), plot1.global_position + Vector3.UP * 1.1)   # inside the pen, between the rows
	await wait_sec(0.9)
	await _shot("2_hostile_rises")

	step("break glass, first person")
	GameState.server_add_money(200)
	var cabinet := _world.room.get_station("EmergencyCabinet") as EmergencyCabinet
	check(cabinet != null and cabinet.server_break(_me), "glass broken")
	await wait_frames(4)
	var ft := _world.items.get_held_by(1) as Flamethrower
	check(ft != null, "flamethrower in hand")
	_face(Vector3(6.4, 0.0, -0.4), plot1.global_position + Vector3.UP * 1.0)
	await wait_sec(0.7)
	await _shot("3_fp_flamethrower")
	if ft != null:
		ft.server_request_fire(1, true)
		await wait_sec(0.8)
		await _shot("4_fp_firing")
		var cam := _world.overview_camera
		if cam != null:
			cam.global_position = Vector3(8.6, 2.4, 1.6)
			cam.look_at(Vector3(5.6, 0.9, -2.2), Vector3.UP)
			cam.make_current()
			await wait_sec(0.5)
			await _shot("5_third_person_burning")
			_me.camera.make_current()
		await wait_until(func() -> bool: return not Hostiles.is_any_alive(), 6.0, "it burns down")
		ft.server_request_fire(1, false)
	Hostiles.server_despawn_all()

	step("banners")
	_face(Vector3(0.0, 0.0, 1.5), Vector3(0.0, 1.4, -6.0))
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count")
	await wait_sec(3.0)
	await _shot("6_banner_headcount")
	Events.server_end_event()
	await wait_sec(0.4)
	check(Events.server_start_event(Events.EVENT_WATER_OFF), "water off")
	_face(Vector3(-4.6, 0.0, 0.6), Vector3(-7.5, 1.0, 0.0))
	await wait_sec(1.2)
	await _shot("7_banner_water_off")
	Events.server_end_event()
	await wait_sec(0.4)

	step("the supply window during a shortage")
	check(Events.server_start_event(Events.EVENT_SHORTAGE), "shortage")
	var counter := _world.room.get_station("ShopCounter") as ShopCounter
	teleport(_me, counter)
	await wait_sec(0.3)
	counter.interact(_me)
	await wait_sec(1.0)
	await _shot("8_supply_window_shortage")
	var ui := counter.get_shop_ui()
	if ui != null and ui.is_open():
		ui.close()
	Events.server_end_event()
	finish()


## Puts the local player at `pos` (floor) looking at `target` (world space).
func _face(pos: Vector3, target: Vector3) -> void:
	_me.velocity = Vector3.ZERO
	_me.global_position = pos + Vector3.UP * 0.02
	var eye := pos + Vector3.UP * 1.6
	var dir := (target - eye).normalized()
	_me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	_me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


func _shot(shot: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("m12_shots: ", ProjectSettings.globalize_path(path))
