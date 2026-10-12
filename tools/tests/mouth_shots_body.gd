extends "res://tools/tests/smoke_base.gd"
## M25 mouth in-game screenshots on the REAL renderer (lead tool, not a suite): a worker (Bob, fake) talking at 2 m,
## his voice injected as frames of a known loudness on Voice's 20 ms clock, so his face is driven exactly as in play.
##   1_shut_2m          Bob silent, sad: the frown, nothing parted
##   2_quiet_2m         a quiet voice (amplitude 0.04: level about 0.31)
##   3_ordinary_2m      an ordinary voice (0.12: about 0.63)
##   4_loud_2m          a loud voice (0.5: 1, the full opening)
##   5_loud_1m          the full opening from 1 m (the opening against the head)
##   6_loud_side        the full opening from 1.4 m, 35 degrees off his front (its depth: not buried, not floating)
##   7_grim_loud_2m     grim, loud (the wider, flatter frown parted)
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/mouth_shots_body.gd --out=<abs dir> \
##       --port=7979 --mute --no-mic --replay --run=B5VP --career-file=user://mouth_shots.cfg \
##       --settings-file=user://mouth_shots_settings.cfg
## Under --headless it stages every shot and saves nothing (a dry run: the openings are checked). Blinks are held off
## for the shots. The mouse is never captured; a watchdog ends the run after 120 s.

const BOB := 2
const BOB_AT := Vector3(-3.0, 0.05, 1.0)
const FACE_Y := 1.25          # about the height of his face (m): the look-at point
const AMP_QUIET := 0.04
const AMP_ORDINARY := 0.12
const AMP_LOUD := 0.5

var _out := "user://mouth_shots"
var _shots := true
var _me: Player
var _bob: Player
var _face: ToonFace
var _amp: float = 0.0
var _t0: int = 0
var _sent: int = 0
var _frames: Dictionary = {}


func _process(_delta: float) -> void:
	if _shots and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _amp > 0.0 and _bob != null:
		var due := (Time.get_ticks_msec() - _t0) / Voice.FRAME_MS + 1
		while _sent < due:
			Voice.debug_inject_frame(BOB, _frame(_amp))
			_sent += 1
	if _face != null:
		_face.set(&"_next_blink", 60.0) # no blink in a shot


func _run() -> void:
	_label = "mouth_shots"
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("mouth_shots: watchdog, quitting")
		get_tree().quit(2))
	_shots = DisplayServer.get_name() != "headless"
	if not _shots:
		print("mouth_shots: headless: staging every shot, saving nothing (run it without --headless for the pictures)")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	if _shots:
		DirAccess.make_dir_recursive_absolute(_out)
	Config.lobby_enabled = false
	await get_tree().process_frame
	Game.start_host("Cara", port_arg(7979))   # a crew name, not the user's
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var world: World = Game.world
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	_bob = world.server_spawn_player(BOB)
	Net.players_changed.emit()
	await wait_sec(0.5)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "the shift runs")
	await wait_sec(1.0)
	if not check(_bob != null and _bob.get_talking_face() != null, "Bob and his talking face"):
		finish()
		return
	_face = _bob.get_talking_face()
	_bob.place_at(Transform3D(Basis(Vector3.UP, PI), BOB_AT))   # facing +Z, towards the camera
	var face_at := Vector3(BOB_AT.x, FACE_Y, BOB_AT.z)

	step("shut")
	_look(BOB_AT + Vector3(0.0, 0.0, 2.0), face_at)
	await wait_sec(0.5)
	check(_face.get_talk_opening() == 0.0 and not _face.is_talking(), "shut")
	await _shot("1_shut_2m")

	for row: Array in [[AMP_QUIET, "2_quiet_2m"], [AMP_ORDINARY, "3_ordinary_2m"], [AMP_LOUD, "4_loud_2m"]]:
		step(String(row[1]))
		await _talk_at(float(row[0]))
		await _shot(String(row[1]))

	step("the full opening, close and from the side")
	_look(BOB_AT + Vector3(0.0, 0.0, 1.0), face_at)
	await wait_sec(0.2)
	await _shot("5_loud_1m")
	var side := Vector3(sin(deg_to_rad(35.0)), 0.0, cos(deg_to_rad(35.0))) * 1.4
	_look(BOB_AT + Vector3(-side.x, 0.0, side.z), face_at)
	await wait_sec(0.2)
	await _shot("6_loud_side")

	step("grim, loud")
	_face.set_mood(&"grim", true)
	_look(BOB_AT + Vector3(0.0, 0.0, 2.0), face_at)
	await wait_sec(0.3)
	check(_face.get_talk_opening() > 0.95, "grim and loud: open (%.2f)" % _face.get_talk_opening())
	await _shot("7_grim_loud_2m")
	_amp = 0.0
	_face.set_mood(&"sad", true)
	await wait_sec(0.5)
	check(_face.get_talk_opening() == 0.0, "shut again after the voice")
	finish()


## Bob talks at `amp` until his mouth settles; checks the opening against the frame's level.
func _talk_at(amp: float) -> void:
	_amp = amp
	_t0 = Time.get_ticks_msec()
	_sent = 0
	await wait_sec(0.4)
	var want: float = Voice.mouth_level_of(_frame(amp))
	check(absf(_face.get_talk_opening() - want) < 0.05, "amplitude %.2f: opening %.2f (level %.2f)" % [amp, _face.get_talk_opening(), want])


func _frame(amp: float) -> PackedByteArray:
	if _frames.has(amp):
		return _frames[amp]
	var s := PackedFloat32Array()
	s.resize(Voice.FRAME_SAMPLES)
	for i in Voice.FRAME_SAMPLES:
		s[i] = amp * sin(TAU * 250.0 * float(i) / float(Voice.SAMPLE_RATE))
	var f := Voice.encode_mulaw(s)
	_frames[amp] = f
	return f


## Puts the local player at `pos` (x / z; the height stays) looking at `target` (world space).
func _look(pos: Vector3, target: Vector3) -> void:
	_me.velocity = Vector3.ZERO
	_me.global_position = Vector3(pos.x, _me.global_position.y, pos.z)
	var eye := _me.global_position + Vector3.UP * 1.6
	var dir := (target - eye).normalized()
	_me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	_me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


func _shot(shot: String) -> void:
	if not _shots:
		print("mouth_shots: (dry run) %s staged" % shot)
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("mouth_shots: ", ProjectSettings.globalize_path(path))
