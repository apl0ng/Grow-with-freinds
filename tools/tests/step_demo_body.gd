extends "res://tools/tests/smoke_base.gd"
## Audition clip for the footsteps (lead tool, not a suite): mixes the synthesized step sounds at the game's cadence
## into one WAV so a person can judge them by ear without launching the game. Headless is fine (nothing is played).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/step_demo_body.gd \
##       --out=<abs path to a .wav>
## The clip: 3 s of walking, 2.5 s of sprinting, a jump landing, 2 s crouched. The same per-sound volumes and the same
## strides as scripts/player/player.gd (STEP_STRIDE_*), no pitch variation.

const RATE := 22050


func _run() -> void:
	_label = "step_demo"
	await get_tree().process_frame
	var out := "user://step_demo.wav"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	var b: BalanceConfig = Config.balance
	var mix := PackedFloat32Array()
	mix.resize(int(9.5 * RATE))
	mix.fill(0.0)
	var t := 0.3
	var last := -1
	# Walking.
	var walk_gap := Player.STEP_STRIDE_WALK / b.walk_speed
	while t < 3.3:
		last = _add_step(mix, t, last, 0.0)
		t += walk_gap
	# Sprinting.
	var sprint_gap := Player.STEP_STRIDE_SPRINT / b.sprint_speed
	while t < 5.8:
		last = _add_step(mix, t, last, Player.STEP_SPRINT_DB)
		t += sprint_gap
	# A jump: silence in the air, then the landing.
	t += 0.55
	_add(mix, t, &"land", 0.0)
	t += 0.6
	# Crouched.
	var crouch_gap := Player.STEP_STRIDE_CROUCH / b.crouch_speed
	while t < 9.2:
		last = _add_step(mix, t, last, Player.STEP_CROUCH_DB)
		t += crouch_gap
	var peak := 0.0001
	for v in mix:
		peak = maxf(peak, absf(v))
	var bytes := PackedByteArray()
	bytes.resize(mix.size() * 2)
	for i in mix.size():
		bytes.encode_s16(i * 2, int(clampf(mix[i] / maxf(peak, 1.0), -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	var err := wav.save_to_wav(out)
	check(err == OK, "saved %s (walk every %.2f s, sprint every %.2f s, crouch every %.2f s)" % [ProjectSettings.globalize_path(out), walk_gap, sprint_gap, crouch_gap])
	finish()


func _add_step(mix: PackedFloat32Array, at: float, last: int, offset_db: float) -> int:
	var i := (last + 1 + (randi() % 2)) % Player.STEP_SOUNDS.size()
	_add(mix, at, Player.STEP_SOUNDS[i], offset_db)
	return i


## Mixes sound `sound` into `mix` at `at` seconds with its SETTINGS volume plus `offset_db`.
func _add(mix: PackedFloat32Array, at: float, sound: StringName, offset_db: float) -> void:
	var stream: AudioStreamWAV = Sfx.get_stream(sound)
	if stream == null:
		return
	var gain := db_to_linear(float(Sfx.SETTINGS[sound][0]) + offset_db + 10.0)   # +10 dB so the quiet steps fill the file
	var data := stream.data
	var n := data.size() / 2
	var s0 := int(at * RATE)
	for k in n:
		if s0 + k >= mix.size():
			break
		mix[s0 + k] += float(data.decode_s16(k * 2)) / 32767.0 * gain
