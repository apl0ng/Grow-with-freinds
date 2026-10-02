extends "res://tools/tests/smoke_base.gd"
## Audition tool for the synthesised sounds (M16 polish; a tool, not a suite): writes one WAV per sound name straight
## from the Sfx recipes, at the volume its SETTINGS row plays it at, so a person can judge them by ear in any player
## without launching the game. Headless is fine: nothing is played and no audio device is needed.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/sound_demo_body.gd \
##       --out=<directory> [--sounds=siren,ball,uproot] [--loop-sec=4] [--raw]
##   --out       where the files go (created when missing; default user://sound_demo). One file per sound: <name>.wav
##   --sounds    comma-separated Sfx names (default: DEFAULT_SOUNDS, the ones nobody has heard yet, plus the footsteps);
##               "all" = every name in Sfx.SOUNDS
##   --loop-sec  a looping sound (Sfx.LOOPING) is written as whole turns of its loop, at least this many seconds
##               (default 4), with a short fade at the end; a one-shot is written once, as it is
##   --raw       skip the table volume: every file at the recipe's own peak (0.89), for listening to a quiet sound
## Every file is read back from disk and measured (16-bit mono PCM at Sfx.MIX_RATE, peak, RMS, mean = DC); the table
## at the end is what the files hold. A name Sfx does not know is reported and fails the run, the others are written.
## step_demo_body.gd is the companion for footsteps at the game's cadence.

const DEFAULT_SOUNDS: PackedStringArray = ["siren", "sprinkler", "collector_knock", "ball", "uproot", "locker",
		"step", "step2", "step3", "land"]
const DEFAULT_OUT := "user://sound_demo"
const DEFAULT_LOOP_SEC: float = 4.0
const LOOP_FADE_SEC: float = 0.25
## A file quieter than this (RMS of full scale) counts as silent, one with a mean above DC_LIMIT as offset.
const SILENT_RMS: float = 0.001
const SILENT_PEAK: float = 0.01
const DC_LIMIT: float = 0.01


func _run() -> void:
	_label = "sound_demo"
	await get_tree().process_frame
	var out := DEFAULT_OUT
	var names: PackedStringArray = DEFAULT_SOUNDS
	var loop_sec := DEFAULT_LOOP_SEC
	var raw := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a.begins_with("--sounds="):
			names = _parse_names(a.trim_prefix("--sounds="))
		elif a.begins_with("--loop-sec="):
			loop_sec = clampf(float(a.trim_prefix("--loop-sec=")), 0.5, 60.0)
		elif a == "--raw":
			raw = true
	out = out.replace("\\", "/").trim_suffix("/")
	var dir := ProjectSettings.globalize_path(out) if out.begins_with("user://") or out.begins_with("res://") else out
	var made := DirAccess.make_dir_recursive_absolute(dir)
	if not check(made == OK and DirAccess.dir_exists_absolute(dir), "the directory %s exists" % dir):
		finish()
		return
	if not check(not names.is_empty(), "at least one sound name"):
		finish()
		return
	step("%d sound(s) into %s (%s, loops for %.1f s or more)" % [names.size(), dir, "recipe peak" if raw else "table volume", loop_sec])
	var rows: PackedStringArray = []
	for n in names:
		var sound := StringName(n)
		if not Sfx.has_sound(sound):
			check(false, "'%s' is not a sound (see Sfx.SOUNDS)" % n)
			continue
		var source: AudioStreamWAV = Sfx.get_stream(sound)
		if not check(source != null and source.format == AudioStreamWAV.FORMAT_16_BITS and not source.stereo, "%s: synthesised" % n):
			continue
		var looping: bool = Sfx.LOOPING.has(sound)
		var volume_db := 0.0 if raw else float((Sfx.SETTINGS.get(sound, [0.0]) as Array)[0])
		var wav := render(source, volume_db, loop_sec if looping else 0.0)
		var path := "%s/%s.wav" % [dir, n]
		var err := wav.save_to_wav(path)
		if not check(err == OK and FileAccess.file_exists(path), "%s: written" % path):
			continue
		var m := measure_file(path)
		var ok: bool = bool(m["valid"]) and float(m["peak"]) > SILENT_PEAK and float(m["rms"]) > SILENT_RMS and absf(float(m["dc"])) < DC_LIMIT \
				and int(m["clipped"]) == 0
		check(ok, "%s.wav: valid PCM, not silent, no offset, not clipped (%s)" % [n, m.get("why", "ok")])
		var kind := "one-shot"
		if looping:
			kind = "loop x%d" % int(round(float(int(m["samples"])) / maxf(float(source.data.size()) / 2.0, 1.0)))
		rows.append("  %-16s %5.2f  %6.3f  %6.3f  %+7.4f  %6.1f  %s" % [n, float(m["seconds"]), float(m["peak"]), float(m["rms"]), float(m["dc"]),
				volume_db, kind])
	print("  sound              sec    peak     rms       dc   vol dB  kind")
	for r in rows:
		print(r)
	finish()


## "a, b ,c" -> names; "all" -> every Sfx name.
func _parse_names(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if text.strip_edges().to_lower() == "all":
		for n in Sfx.get_sound_names():
			out.append(String(n))
		return out
	for part in text.split(",", false):
		var n := part.strip_edges()
		if n != "" and not out.has(n):
			out.append(n)
	return out


## A copy of `source` at `volume_db`. With `loop_sec` > 0 the buffer is repeated in whole turns until it is at least
## that long, and the last LOOP_FADE_SEC fade out.
static func render(source: AudioStreamWAV, volume_db: float, loop_sec: float) -> AudioStreamWAV:
	var data := source.data
	@warning_ignore("integer_division")
	var n := data.size() / 2
	var turns := 1
	if loop_sec > 0.0 and n > 0:
		turns = maxi(int(ceil(loop_sec * source.mix_rate / float(n))), 1)
	var gain := db_to_linear(volume_db)
	var total := n * turns
	var fade_n := mini(int(LOOP_FADE_SEC * source.mix_rate), total) if loop_sec > 0.0 else 0
	var bytes := PackedByteArray()
	bytes.resize(total * 2)
	for i in total:
		var v := float(data.decode_s16((i % n) * 2)) * gain
		if fade_n > 0 and i >= total - fade_n:
			v *= float(total - 1 - i) / float(fade_n)
		bytes.encode_s16(i * 2, clampi(int(round(v)), -32767, 32767))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = source.mix_rate
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	wav.data = bytes
	return wav


## Reads a WAV file back from disk: {"valid": bool, "why": String, "seconds", "peak", "rms", "dc" (of full scale),
## "samples": int, "clipped": int}. Valid = RIFF / WAVE, PCM, mono, 16 bit, Sfx.MIX_RATE, a data chunk with samples.
static func measure_file(path: String) -> Dictionary:
	var out := {"valid": false, "why": "", "seconds": 0.0, "peak": 0.0, "rms": 0.0, "dc": 0.0, "samples": 0, "clipped": 0}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		out["why"] = "cannot open"
		return out
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		out["why"] = "not a RIFF / WAVE file"
		return out
	var at := 12
	var format := -1
	var channels := 0
	var rate := 0
	var bits := 0
	var data_at := -1
	var data_size := 0
	while at + 8 <= bytes.size():
		var id := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := bytes.decode_u32(at + 4)
		if id == "fmt " and at + 24 <= bytes.size():
			format = bytes.decode_u16(at + 8)
			channels = bytes.decode_u16(at + 10)
			rate = bytes.decode_u32(at + 12)
			bits = bytes.decode_u16(at + 22)
		elif id == "data":
			data_at = at + 8
			data_size = mini(size, bytes.size() - data_at)
			break
		at += 8 + size + (size & 1)
	if format != 1 or channels != 1 or bits != 16 or rate != Sfx.MIX_RATE:
		out["why"] = "format %d, %d channel(s), %d bit, %d Hz" % [format, channels, bits, rate]
		return out
	@warning_ignore("integer_division")
	var n := data_size / 2
	if data_at < 0 or n <= 0:
		out["why"] = "no samples"
		return out
	var peak := 0
	var sum := 0.0
	var sum_sq := 0.0
	var clipped := 0
	for i in n:
		var s := bytes.decode_s16(data_at + i * 2)
		var a := absi(s)
		peak = maxi(peak, a)
		if a >= 32767:
			clipped += 1
		var v := s / 32767.0
		sum += v
		sum_sq += v * v
	out["valid"] = true
	out["why"] = "%d samples" % n
	out["samples"] = n
	out["seconds"] = float(n) / rate
	out["peak"] = peak / 32767.0
	out["rms"] = sqrt(sum_sq / n)
	out["dc"] = sum / n
	out["clipped"] = clipped
	return out
