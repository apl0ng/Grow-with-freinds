extends "res://tools/tests/smoke_base.gd"
## Voice suite (M10, voice agent): codec, downsampler, routing table, receive validation (rate / size / order),
## speaking transitions, emitters under the world, back-room routes and the settings file. Headless, one host.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/voice_test.gd --port=7843

const VoiceScript := preload("res://scripts/core/voice.gd")

## Per-process scratch files (parallel runs share user://), never the player's real user://voice.cfg.
var TEST_CFG := "user://voice_test_%d.cfg" % OS.get_process_id()
var MISSING_CFG := "user://voice_test_missing_%d.cfg" % OS.get_process_id()
var _events: Array = []   # [peer, speaking] per speaking_changed


func _run() -> void:
	_label = "voice"
	await get_tree().process_frame
	# Never touch the player's real settings file from a test.
	Voice.settings_path = TEST_CFG
	Voice.speaking_changed.connect(func(p: int, s: bool) -> void: _events.append([p, s]))

	_test_codec()
	_test_downsampler()
	_test_routes()
	_test_headless()
	await _test_receive_path()
	await _test_settings()
	finish()

# --- codec -------------------------------------------------------------------------------------------------------

func _test_codec() -> void:
	step("codec")
	var n := 1600
	var sine := PackedFloat32Array()
	sine.resize(n)
	for i in n:
		sine[i] = 0.5 * sin(TAU * 440.0 * float(i) / float(Voice.SAMPLE_RATE))
	var bytes: PackedByteArray = VoiceScript.encode_mulaw(sine)
	check(bytes.size() == n, "encode: one byte per sample (%d)" % bytes.size())
	var back: PackedFloat32Array = VoiceScript.decode_mulaw(bytes)
	check(back.size() == n, "decode: one sample per byte")
	var sig := 0.0
	var noise := 0.0
	var max_abs := 0.0
	for i in n:
		sig += sine[i] * sine[i]
		var e := back[i] - sine[i]
		noise += e * e
		max_abs = maxf(max_abs, absf(back[i]))
	var snr := 10.0 * log(sig / maxf(noise, 1e-12)) / log(10.0)
	check(snr > 25.0, "440 Hz sine round trip SNR %.1f dB > 25 dB" % snr)
	check(max_abs <= 1.0, "decoded samples stay within [-1, 1]")
	var silence := PackedFloat32Array()
	silence.resize(Voice.FRAME_SAMPLES)
	var silent_bytes: PackedByteArray = VoiceScript.encode_mulaw(silence)
	var silent_back: PackedFloat32Array = VoiceScript.decode_mulaw(silent_bytes)
	var quiet := true
	for v in silent_back:
		if absf(v) > 1e-4:
			quiet = false
	check(silent_bytes.size() == Voice.FRAME_SAMPLES and quiet, "silence stays silence")
	var extremes := PackedFloat32Array([1.0, -1.0, 2.0, -2.0, 0.0])
	var ext_back: PackedFloat32Array = VoiceScript.decode_mulaw(VoiceScript.encode_mulaw(extremes))
	check(ext_back[0] > 0.95 and ext_back[1] < -0.95 and ext_back[2] > 0.95 and ext_back[3] < -0.95 \
		and absf(ext_back[4]) < 1e-4, "full scale and clipped inputs decode near +-1, zero to zero")
	var all_bytes := PackedByteArray()
	all_bytes.resize(256)
	for b in 256:
		all_bytes[b] = b
	var table: PackedFloat32Array = VoiceScript.decode_mulaw(all_bytes)
	var monotone := true
	for b in range(1, 128):
		if table[b] < table[b - 1]:
			monotone = false
	check(monotone and table[0xFF] == 0.0 and table[0x00] < -0.9 and table[0x80] > 0.9, "decode table: 0xFF is zero, 0x00 most negative, 0x80 most positive, negative half monotone")

# --- downsampler ---------------------------------------------------------------------------------------------------

func _test_downsampler() -> void:
	step("downsampler")
	for rate: float in [44100.0, 48000.0]:
		var ds: RefCounted = VoiceScript.Downsampler.new(rate, float(Voice.SAMPLE_RATE))
		var total := int(rate)
		var chunks: Array[int] = [441, 1000, 7, 2048, 1, 3, 512]
		var out := PackedFloat32Array()
		var fed := 0
		var ci := 0
		while fed < total:
			var size: int = mini(chunks[ci % chunks.size()], total - fed)
			ci += 1
			var chunk := PackedFloat32Array()
			chunk.resize(size)
			for i in size:
				chunk[i] = float(fed + i) * 0.001
			fed += size
			out.append_array(ds.process(chunk))
		check(absi(out.size() - Voice.SAMPLE_RATE) <= 1, "%d -> 16000 Hz: one second gives %d samples" % [int(rate), out.size()])
		var expected_step := 0.001 * rate / float(Voice.SAMPLE_RATE)
		var worst := 0.0
		for k in range(2, out.size()):
			worst = maxf(worst, absf((out[k] - out[k - 1]) - expected_step))
		check(worst < 1e-4, "%d Hz ramp stays linear across %d chunks (worst step error %.7f)" % [int(rate), ci, worst])
		var empty: PackedFloat32Array = ds.process(PackedFloat32Array())
		check(empty.is_empty(), "%d Hz: an empty chunk yields nothing" % int(rate))

# --- routing -------------------------------------------------------------------------------------------------------

func _test_routes() -> void:
	step("routing table")
	check(VoiceScript.get_route(false, false) == &"3d", "floor hears floor in 3D")
	check(VoiceScript.get_route(true, true) == &"full", "back room hears back room at full volume")
	check(VoiceScript.get_route(true, false) == &"faint", "back room hears the floor faintly")
	check(VoiceScript.get_route(false, true) == &"mute", "floor never hears the back room")

func _test_headless() -> void:
	step("headless")
	check(not Voice.is_mic_available(), "no microphone headless")
	check(not Voice.is_transmitting() and not Voice.transmitting, "not transmitting")
	check(Voice.get_input_level() == 0.0, "input level 0")
	check(Voice.get_speaking_peers().is_empty(), "nobody speaks before a session")
	check(AudioServer.get_bus_index(&"Voice") != -1, "Voice bus exists")
	check(AudioServer.get_bus_index(&"Mic") == -1, "no Mic bus headless")

# --- receive path (solo host) ------------------------------------------------------------------------------------

func _frame(phase: int = 0) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(Voice.FRAME_SAMPLES)
	for i in Voice.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 300.0 * float(i + phase * Voice.FRAME_SAMPLES) / float(Voice.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)

func _dropped(reason: String) -> int:
	return int(Voice.get_stats()["dropped"].get(reason, 0))

func _test_receive_path() -> void:
	step("hosting")
	Game.start_host("Tester", port_arg(7843))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		return
	await wait_frames(2)
	check(Game.world.get_node_or_null("VoiceOut") != null, "VoiceOut root created on world_ready")

	step("validation")
	var s0: Dictionary = Voice.get_stats()
	_events.clear()
	Voice.debug_inject_frame(77, _frame())
	check(_dropped("not_player") == 1 and not Voice.is_speaking(77), "unknown peer dropped (not_player), not speaking")
	Voice.debug_inject_frame(1, PackedByteArray())
	check(_dropped("empty") == 1, "empty frame dropped")
	var big := PackedByteArray()
	big.resize(Voice.MAX_FRAME_BYTES + 1)
	Voice.debug_inject_frame(1, big)
	check(_dropped("too_big") == 1, "frame over %d bytes dropped" % Voice.MAX_FRAME_BYTES)
	check(_events.is_empty() and Voice.get_speaking_peers().is_empty(), "dropped frames never change the speaking state")
	check(int(Voice.get_stats()["received"]) == int(s0["received"]), "nothing counted as received")

	step("rate limit")
	var recv0 := int(Voice.get_stats()["received"])
	for i in 100:
		Voice.debug_inject_frame(1, _frame(i))
	var accepted := int(Voice.get_stats()["received"]) - recv0
	check(accepted == Voice.MAX_FRAMES_PER_SEC, "100 frames in one call: %d accepted (limit %d)" % [accepted, Voice.MAX_FRAMES_PER_SEC])
	check(_dropped("rate") == 100 - Voice.MAX_FRAMES_PER_SEC, "the rest dropped as rate")
	check(_events == [[1, true]] and Voice.is_speaking(1) and Voice.get_speaking_peers() == [1], "speaking_changed(1, true) once")

	step("emitter")
	var out := Game.world.get_node_or_null("VoiceOut/1") as AudioStreamPlayer3D
	check(out != null, "VoiceOut/1 exists under the world")
	if out != null:
		check(out == Voice.get_output_node(1), "get_output_node(1) is that node")
		check(out.bus == &"Voice", "emitter on the Voice bus")
		var gen := out.stream as AudioStreamGenerator
		check(gen != null and is_equal_approx(gen.mix_rate, 16000.0) and is_equal_approx(gen.buffer_length, 0.15), "generator 16 kHz, 0.15 s")
		check(is_equal_approx(out.max_distance, Config.balance.voice_range) and is_equal_approx(out.unit_size, Config.balance.voice_range * 0.5), "range %.1f m, unit size half of it" % Config.balance.voice_range)
		check(out.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE and out.volume_db == 0.0, "3d route: inverse distance at 0 dB")
		var head: Vector3 = Game.local_player.global_position + Vector3.UP * 1.6
		check(out.global_position.distance_to(head) < 0.05, "emitter at the speaker's head (standing)")
		check(out.playing, "emitter playing")
	await wait_frames(3)
	check(int(Voice.get_stats()["played"]) >= 2, "frames reached the generator (%d)" % int(Voice.get_stats()["played"]))
	check(int(Voice.get_stats()["peers"]) == 1, "one output")

	step("speaking hold")
	await wait_sec(1.1)
	check(_events == [[1, true], [1, false]] and not Voice.is_speaking(1), "speaking_changed(1, false) after %d ms of silence" % Voice.SPEAK_HOLD_MS)
	check(Voice.get_speaking_peers().is_empty(), "no speaking peers")
	_events.clear()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 150:
		Voice.debug_inject_frame(1, _frame())
		await wait_sec(0.02)
	check(_events == [[1, true]], "continuous frames: one transition to speaking")
	await wait_sec(0.5)
	check(_events == [[1, true], [1, false]], "then one transition back")

	step("sequence order")
	await wait_sec(0.6) # over SEQ_RESYNC_MS since the last frame: any seq is accepted again
	var recv1 := int(Voice.get_stats()["received"])
	var reorder0 := _dropped("reorder")
	var lost_before := int(Voice.get_stats()["lost"])
	Voice.debug_inject_frame(1, _frame(), 65530)
	Voice.debug_inject_frame(1, _frame(), 65531)
	Voice.debug_inject_frame(1, _frame(), 65529)  # older
	Voice.debug_inject_frame(1, _frame(), 65531)  # duplicate
	Voice.debug_inject_frame(1, _frame(), 65535)
	Voice.debug_inject_frame(1, _frame(), 0)      # wraparound
	Voice.debug_inject_frame(1, _frame(), 1)
	Voice.debug_inject_frame(1, _frame(), 65535)  # older, across the wrap
	Voice.debug_inject_frame(1, _frame(), 3)
	check(int(Voice.get_stats()["received"]) - recv1 == 6, "6 of 9 frames accepted in order (with wraparound)")
	check(_dropped("reorder") - reorder0 == 3, "3 dropped as reorder")
	check(int(Voice.get_stats()["lost"]) - lost_before == 4, "seq gaps counted as lost (65531 -> 65535 skips 3, 1 -> 3 skips 1)")

	step("loss concealment")
	var lost0 := int(Voice.get_stats()["lost"])
	var conc0 := int(Voice.get_stats()["concealed"])
	var out_queue_before := 0
	Voice.debug_inject_frame(1, _frame(), 4)    # continues the order step (last accepted: 3)
	Voice.debug_inject_frame(1, _frame(), 5)
	Voice.debug_inject_frame(1, _frame(), 8)    # 6 and 7 never arrived
	check(int(Voice.get_stats()["lost"]) - lost0 == 2 and int(Voice.get_stats()["concealed"]) - conc0 == 2, "a gap of 2 is concealed with 2 filler frames")
	Voice.debug_inject_frame(1, _frame(), 14)   # 9..13: too long a gap to fill
	check(int(Voice.get_stats()["lost"]) - lost0 == 7 and int(Voice.get_stats()["concealed"]) - conc0 == 2, "a gap of 5 counts as lost but is not concealed")
	out_queue_before = int(Voice.get_stats()["played"])
	await wait_frames(3)
	check(int(Voice.get_stats()["played"]) > out_queue_before, "filler and real frames were played")

	step("back room routes")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "PLAYING")
	check(GameState.server_send_to_backroom(1), "host sent to the back room")
	await wait_frames(2)
	if out != null and is_instance_valid(out):
		check(out.attenuation_model == AudioStreamPlayer3D.ATTENUATION_DISABLED and out.max_distance == 0.0, "both in the back room: full route (no attenuation)")
		await wait_sec(1.1)
		Voice.debug_inject_frame(1, _frame())
		Voice.debug_inject_frame(1, _frame())
		check(Voice.is_speaking(1), "still heard in the back room")
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	if out != null and is_instance_valid(out):
		check(out.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE and is_equal_approx(out.max_distance, Config.balance.voice_range), "released: back to the 3d route")

	step("return to menu")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null, "world freed")
	check(int(Voice.get_stats()["peers"]) == 0, "no outputs left")
	check(Voice.get_speaking_peers().is_empty() and not Voice.is_speaking(1), "nobody speaks in the menu")
	var np0 := _dropped("not_player")
	Voice.debug_inject_frame(1, _frame())
	check(_dropped("not_player") == np0 + 1, "frames in the menu are dropped (no players)")
	check(not is_instance_valid(out), "emitter freed with the world")

# --- settings ---------------------------------------------------------------------------------------------------

func _test_settings() -> void:
	step("settings")
	var cfg_abs := ProjectSettings.globalize_path(TEST_CFG)
	if FileAccess.file_exists(TEST_CFG):
		DirAccess.remove_absolute(cfg_abs)
	Voice.settings_path = MISSING_CFG
	Voice.load_settings()
	check(Voice.enabled and Voice.push_to_talk == Config.balance.voice_push_to_talk and Voice.output_volume_db == 0.0 \
		and Voice.input_gain == 1.0, "defaults when the file is missing")
	Voice.settings_path = TEST_CFG
	Voice.output_volume_db = -6.5
	Voice.input_gain = 1.5
	Voice.push_to_talk = not Config.balance.voice_push_to_talk
	Voice.enabled = false
	check(FileAccess.file_exists(TEST_CFG), "setters wrote %s" % TEST_CFG)
	var idx := AudioServer.get_bus_index(&"Voice")
	check(idx != -1 and is_equal_approx(AudioServer.get_bus_volume_db(idx), -6.5), "Voice bus follows output_volume_db")
	var raw := ConfigFile.new()
	check(raw.load(TEST_CFG) == OK and is_equal_approx(float(raw.get_value("voice", "output_volume_db", 0.0)), -6.5) \
		and is_equal_approx(float(raw.get_value("voice", "input_gain", 0.0)), 1.5) \
		and bool(raw.get_value("voice", "push_to_talk", true)) == (not Config.balance.voice_push_to_talk) \
		and bool(raw.get_value("voice", "enabled", true)) == false, "the file holds the four values")
	# Loading never writes: point at a missing file (defaults), then back at the saved one (restored).
	Voice.settings_path = MISSING_CFG
	Voice.load_settings()
	check(Voice.enabled and is_equal_approx(Voice.output_volume_db, 0.0) and is_equal_approx(Voice.input_gain, 1.0), "defaults again from the missing file")
	Voice.settings_path = TEST_CFG
	Voice.load_settings()
	check(is_equal_approx(Voice.output_volume_db, -6.5) and is_equal_approx(Voice.input_gain, 1.5) \
		and Voice.push_to_talk == (not Config.balance.voice_push_to_talk) and not Voice.enabled, "load_settings restores the saved values")
	check(is_equal_approx(AudioServer.get_bus_volume_db(idx), -6.5), "Voice bus follows the loaded volume")
	Voice.output_volume_db = -100.0
	check(Voice.output_volume_db == -60.0, "output volume clamped to -60 dB")
	Voice.input_gain = 9.0
	check(Voice.input_gain == 4.0, "input gain clamped to 4")
	Voice.settings_path = MISSING_CFG
	Voice.load_settings()
	DirAccess.remove_absolute(cfg_abs)
	check(not FileAccess.file_exists(TEST_CFG) and Voice.enabled and Voice.output_volume_db == 0.0, "test file removed, defaults back")
