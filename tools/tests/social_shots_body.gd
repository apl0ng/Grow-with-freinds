extends "res://tools/tests/smoke_base.gd"
## M23 social in-game screenshots on the REAL renderer (lead tool, not a suite): the talk mark over a worker near and at
## 10 m, over a radio carrying a voice, the "[E] Help Dale up" prompt over Dale slumped, the helper's own view (the camera
## dip) right after E, Dale down seen from the side and, 0.08 s after Carl's help, Carl's reach with Dale coming up.
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/social_shots_body.gd --out=<abs dir> \
##       --port=7977 --mute --no-mic --replay --run=B5VP --career-file=user://social_shots.cfg \
##       --settings-file=user://social_shots_settings.cfg
## Under --headless it prints a hint and exits 0. The mouse is never captured; a watchdog ends the run after 120 s.

const DALE := 2
const CARL := 3

var _out := "user://social_shots"
var _me: Player
var _talking: Array[int] = []   # fake peers whose voice frames are injected every frame
var _phase: int = 0


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_phase += 1
	for peer in _talking:
		Voice.debug_inject_frame(peer, _frame(_phase))


func _run() -> void:
	_label = "social_shots"
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("social_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("social_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	Config.lobby_enabled = false
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7977))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var world: World = Game.world
	Net.players[DALE] = {"name": "Dale", "color": Net.PALETTE[1]}
	Net.players[CARL] = {"name": "Carl", "color": Net.PALETTE[2]}
	var dale: Player = world.server_spawn_player(DALE)
	var carl: Player = world.server_spawn_player(CARL)
	Net.players_changed.emit()
	await wait_sec(0.5)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "the shift runs")
	await wait_sec(1.0)
	if dale == null or carl == null:
		finish()
		return
	carl.place_at(Transform3D(Basis.IDENTITY, Vector3(-8.0, 0.05, 6.0)))

	step("the talk mark")
	dale.place_at(Transform3D(Basis(Vector3.UP, PI), Vector3(-3.0, 0.05, 1.0)))
	_talking = [DALE]
	_look(Vector3(-3.0, 0.0, 4.0), Vector3(-3.0, 2.2, 1.0))
	await wait_sec(0.6)
	check(dale.is_talk_mark_shown(), "Dale's mark is up")
	await _shot("1_talk_mark_3m")
	_look(Vector3(-3.0, 0.0, 11.0), Vector3(-3.0, 1.8, 1.0))
	await wait_sec(0.4)
	await _shot("2_talk_mark_10m")

	step("a radio carrying a voice")
	var radios: Array[Item] = world.items.get_items_of_type(Const.ITEM_RADIO)
	if radios.size() >= 2:
		world.items.server_give_item(radios[0], DALE)
		world.items.server_drop_item(radios[1], Vector3(-1.5, 0.0, 3.5))
		_look(Vector3(-1.0, 0.0, 6.0), Vector3(-2.2, 1.0, 2.0))
		await wait_sec(0.8)
		check((radios[1] as Radio).is_talk_mark_shown(), "the mark over the radio on the floor")
		await _shot("3_radio_mark")
		world.items.server_drop_item(radios[0], Vector3(-6.0, 0.0, 4.0))
	_talking = []
	await wait_sec(0.8)

	step("help a friend up")
	dale.place_at(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-3.0, 0.05, 1.8)))  # side-on: the slump in profile
	_look(Vector3(-3.0, 0.0, 3.4), Vector3(-3.0, 0.75, 1.8))
	await wait_sec(0.3)
	Player.server_stagger(dale, Vector3.FORWARD, false, 0, 6.0)
	await wait_sec(0.6)
	await _shot("4_help_prompt")
	_me.request_help_up(DALE)
	await wait_sec(0.1)
	await _shot("5_help_first_person")
	await wait_until(func() -> bool: return dale.can_be_staggered(), 8.0, "Dale can go down again")
	carl.place_at(Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-1.8, 0.05, 1.8)))
	dale.place_at(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-3.0, 0.05, 1.8)))
	_look(Vector3(-2.4, 0.0, 5.2), Vector3(-2.4, 1.1, 1.8))
	await wait_sec(0.4)
	Player.server_stagger(dale, Vector3.LEFT, false, 0, 6.0)
	await wait_sec(0.6)
	check(dale.get_slump() >= 1.0, "Dale is down")
	await _shot("6_down_side")
	check(carl.server_help_up(dale), "Carl helps Dale up")
	await wait_sec(0.08)
	await _shot("7_help_reach_side")
	finish()


func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(Voice.FRAME_SAMPLES)
	for i in Voice.FRAME_SAMPLES:
		s[i] = 0.2 * sin(TAU * 180.0 * float(i + phase * Voice.FRAME_SAMPLES) / float(Voice.SAMPLE_RATE))
	return Voice.encode_mulaw(s)


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
	print("social_shots: ", ProjectSettings.globalize_path(path))
