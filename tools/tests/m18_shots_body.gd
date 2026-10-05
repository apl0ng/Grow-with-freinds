extends "res://tools/tests/smoke_base.gd"
## M18 in-game screenshots on the REAL renderer (lead tool, not a suite): the radio shelf, a radio carrying a
## transmission (the lit lamp, the RADIO tag), the four gestures on a second worker, the first-person point arm,
## Black Damp's tell, its cloud and the fog on the local screen.
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m18_shots_body.gd --out=<abs dir> \
##       --port=7976 --mute --no-mic --replay --run=B5VP --event-delay=900
## Under --headless it prints a hint and exits 0. The mouse is never captured; a watchdog ends the run after 120 s.

const FAKE_PEER := 2

var _out := "user://m18_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m18_shots"
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("m18_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m18_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	Config.lobby_enabled = false
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7976))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var world: World = Game.world
	Net.players[FAKE_PEER] = {"name": "Dale", "color": Net.PALETTE[1]}
	var dale: Player = world.server_spawn_player(FAKE_PEER)
	Net.players_changed.emit()
	await wait_sec(0.5)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "the shift runs")
	await wait_sec(1.0)

	step("the radios")
	var radios: Array[Item] = world.items.get_items_of_type(Const.ITEM_RADIO)
	check(radios.size() >= 2, "%d radios on the shelf" % radios.size())
	_look(Vector3(-8.2, 0.0, -5.4), Vector3(-9.0, 1.15, -7.4))
	await wait_sec(0.6)
	await _shot("1_radio_shelf")
	if radios.size() >= 2 and dale != null:
		dale.place_at(Transform3D(Basis(Vector3.UP, PI), Vector3(-4.0, 0.05, 2.0)))
		world.items.server_give_item(radios[0], FAKE_PEER)
		await wait_sec(0.3)
		var frame := PackedByteArray()
		frame.resize(Voice.FRAME_SAMPLES)
		for i in 60:
			Voice.debug_inject_frame(FAKE_PEER, frame)
			await get_tree().create_timer(0.02).timeout
			if i == 40:
				await _shot("2_radio_receiving")
		check(Voice.is_on_radio(FAKE_PEER), "Dale is on the radio")
		await wait_sec(0.8)
		world.items.server_give_item(radios[1], 1)
		await wait_sec(0.5)
		_me.head.rotation.x = -0.2
		await _shot("3_radio_held")

	step("gestures")
	if dale != null:
		var at := Vector3(-2.0, 0.05, 3.0)
		dale.place_at(Transform3D(Basis(Vector3.UP, PI), at))
		await wait_sec(0.5)
		var cam := at + Vector3(1.25, 0.0, 2.2)
		for entry: Array in [[Player.EMOTE_POINT, "4_point"], [Player.EMOTE_WAVE, "5_wave"], [Player.EMOTE_SHRUG, "6_shrug"], [Player.EMOTE_SLUMP, "7_slump"]]:
			if int(entry[0]) == Player.EMOTE_POINT:
				dale.set(&"net_pitch", 0.3)
			dale.server_emote(int(entry[0]))
			_look(cam, at + Vector3(0.0, 0.9, 0.0))
			await wait_sec(0.9)
			await _shot(String(entry[1]))
			dale.server_emote(Player.EMOTE_NONE)
			await wait_sec(0.4)
		_look(Vector3(-1.0, 0.0, 6.0), Vector3(-1.0, 1.4, 0.0))
		await wait_sec(0.3)
		_me.request_emote(Player.EMOTE_POINT)
		await wait_sec(0.5)
		await _shot("8_point_first_person")

	step("Black Damp")
	var plot := world.room.get_station("GrowPlot3") as GrowPlot
	if check(plot != null, "GrowPlot3"):
		plot.server_reset()
		plot.server_plant(&"damp")
		plot.stage = GrowPlot.Stage.READY
		_look(Vector3(3.4, 0.0, 1.5), Vector3(5.0, 1.0, 0.0))
		await wait_sec(1.0)
		await _shot("9_damp_tell")
		Spores.get_instance().server_puff(plot, Spores.CAUSE_HIT)
		await wait_sec(0.8)
		await _shot("10_damp_cloud")
		Spores.get_instance().server_catch(1, false)
		await wait_sec(1.2)
		await _shot("11_fogged")
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
	print("m18_shots: ", ProjectSettings.globalize_path(path))
