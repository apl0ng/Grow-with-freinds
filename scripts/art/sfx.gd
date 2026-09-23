extends Node
## Autoload "Sfx": procedurally synthesised placeholder sounds (no audio assets). Owned by the art agent.
##
##   Sfx.play(&"harvest", plot.global_position)   # 3D, attenuated, panned (world events)
##   Sfx.play(&"ui_click")                          # 2D (UI, your own actions, round jingles)
##
## Every sound is generated once into a 16-bit mono AudioStreamWAV (22.05 kHz) from the recipes below, on a
## WorkerThreadPool task started in _ready (~0.3 s of CPU off the main thread); a sound requested before the
## worker reached it is synthesised on the spot and cached. Playback uses small pools of players (max MAX_2D + MAX_3D voices; the oldest voice is stolen),
## a little random pitch variation, and a per-sound retrigger guard so ten plots finishing on the same
## frame do not stack into one deafening sound. Unknown names warn once and are ignored (never crash).
## Works headless (dummy audio driver). Sounds are local only: call play() from code that runs on every
## peer (synced setters, call_local RPCs, GameState signals). See STYLE.md "Sound".
## Do NOT add a class_name (autoload).

const MIX_RATE := 22050
const MAX_2D := 8
const MAX_3D := 16
const BUS_NAME := &"SFX"
## A sound re-triggered sooner than this after itself is skipped (prevents stacking / phasing).
const MIN_RETRIGGER_MSEC := 40

## Every sound name, in the order they are synthesised. First 15 are the CONTRACTS.md set.
const SOUNDS: Array[StringName] = [
	&"buy", &"plant", &"water", &"harvest", &"sell", &"pickup", &"drop", &"error", &"grow",
	&"round_win", &"round_lose", &"tick", &"ui_click", &"ui_open", &"ui_close",
	# extras (art pass 1)
	&"ready", &"refill", &"ui_hover", &"coin", &"pop", &"whoosh", &"countdown", &"round_start",
]

## Per-sound playback settings: [volume_db, pitch_variation (+-fraction), 3D unit_size].
const SETTINGS := {
	&"buy": [-4.0, 0.03, 6.0],
	&"plant": [-2.0, 0.08, 6.0],
	&"water": [-4.0, 0.08, 6.0],
	&"harvest": [-3.0, 0.06, 6.0],
	&"sell": [-3.0, 0.02, 8.0],
	&"pickup": [-5.0, 0.10, 5.0],
	&"drop": [-3.0, 0.10, 5.0],
	&"error": [-9.0, 0.0, 5.0],
	&"grow": [-5.0, 0.07, 6.0],
	&"round_win": [-3.0, 0.0, 10.0],
	&"round_lose": [-4.0, 0.0, 10.0],
	&"tick": [-9.0, 0.0, 5.0],
	&"ui_click": [-8.0, 0.05, 5.0],
	&"ui_open": [-8.0, 0.03, 5.0],
	&"ui_close": [-8.0, 0.03, 5.0],
	&"ready": [-7.0, 0.04, 7.0],
	&"refill": [-4.0, 0.06, 6.0],
	&"ui_hover": [-16.0, 0.08, 5.0],
	&"coin": [-6.0, 0.06, 6.0],
	&"pop": [-6.0, 0.12, 5.0],
	&"whoosh": [-8.0, 0.08, 5.0],
	&"countdown": [-6.0, 0.0, 5.0],
	&"round_start": [-4.0, 0.0, 10.0],
}

enum Wave { SINE, TRIANGLE, SQUARE, SAW, CHIP }

## Master volume of every Sfx sound (dB, applied to the SFX bus when it exists, else to each player).
var volume_db: float = 0.0:
	set(v):
		volume_db = v
		_apply_bus_volume()
## Set false to silence all Sfx (e.g. automated tests, a settings toggle).
var enabled: bool = true

var _streams: Dictionary = {}          # StringName -> AudioStreamWAV
var _players_2d: Array[AudioStreamPlayer] = []
var _players_3d: Array[AudioStreamPlayer3D] = []
var _started_2d: PackedInt64Array = []
var _started_3d: PackedInt64Array = []
var _last_play: Dictionary = {}        # StringName -> msec
var _warned: Dictionary = {}
var _bus: StringName = &"Master"
var _rng := RandomNumberGenerator.new()
var _mutex := Mutex.new()
var _task_id: int = -1
var _abort_synth: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # UI sounds keep working while the tree is paused
	_setup_bus()
	for i in MAX_2D:
		var p := AudioStreamPlayer.new()
		p.name = "Voice2D_%d" % i
		p.bus = _bus
		add_child(p)
		_players_2d.append(p)
		_started_2d.append(0)
	for i in MAX_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.name = "Voice3D_%d" % i
		p3.bus = _bus
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3.max_distance = 45.0
		p3.max_db = 3.0
		p3.panning_strength = 0.7
		p3.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		add_child(p3)
		_players_3d.append(p3)
		_started_3d.append(0)
	_task_id = WorkerThreadPool.add_task(_synth_all, false, "Sfx synth")

func _exit_tree() -> void:
	_abort_synth = true
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	# Stop + release every voice. (Quitting in the middle of a sound can still print a harmless
	# "ObjectDB instances leaked" WARNING: the AudioServer frees retired playbacks on a later main-loop
	# iteration that never comes. Tests: call stop_all() and let ~5 frames pass before quit().)
	for p in _players_2d:
		p.stop()
		p.stream = null
	for p3 in _players_3d:
		p3.stop()
		p3.stream = null

## True once every sound has been synthesised (play() works before that too).
func is_ready() -> bool:
	_mutex.lock()
	var n := _streams.size()
	_mutex.unlock()
	return n >= SOUNDS.size()

## Blocks until every sound exists (tests). Normally never needed.
func wait_until_ready() -> void:
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1

func _synth_all() -> void:
	var t0 := Time.get_ticks_usec()
	for n in SOUNDS:
		if _abort_synth:
			return
		_mutex.lock()
		var have := _streams.has(n)
		_mutex.unlock()
		if have:
			continue
		var w := _synth(n)
		_mutex.lock()
		if not _streams.has(n):
			_streams[n] = w
		_mutex.unlock()
	print_verbose("Sfx: synthesised %d sounds in %.1f ms (worker thread)" % [SOUNDS.size(), (Time.get_ticks_usec() - t0) / 1000.0])

func _get_or_synth(sound: StringName) -> AudioStreamWAV:
	_mutex.lock()
	var w: AudioStreamWAV = _streams.get(sound)
	_mutex.unlock()
	if w == null and SOUNDS.has(sound):
		w = _synth(sound)   # not reached by the worker yet: make it now (deterministic, same result)
		_mutex.lock()
		if _streams.has(sound):
			w = _streams[sound]
		else:
			_streams[sound] = w
		_mutex.unlock()
	return w

## Plays a sound. No position (Vector3.INF) = 2D/non-positional; otherwise a 3D voice at that world point.
func play(sound: StringName, position: Vector3 = Vector3.INF) -> void:
	if not enabled or not is_inside_tree() or _players_2d.is_empty():
		return
	var stream := _get_or_synth(sound)
	if stream == null:
		if not _warned.has(sound):
			_warned[sound] = true
			push_warning("Sfx.play: unknown sound '%s' (see Sfx.SOUNDS / STYLE.md)" % sound)
		return
	var now := Time.get_ticks_msec()
	var positional := position.is_finite()
	# Retrigger guard is per sound and per mode (a 2D UI click never blocks a 3D one).
	var key := StringName(String(sound) + ("@3d" if positional else ""))
	if now - int(_last_play.get(key, -100000)) < MIN_RETRIGGER_MSEC:
		return
	_last_play[key] = now
	var s: Array = SETTINGS.get(sound, [-6.0, 0.05, 6.0])
	var pitch := 1.0 + _rng.randf_range(-s[1], s[1])
	var vol: float = s[0]
	if _bus == &"Master":
		vol += volume_db
	if positional:
		var i := _pick(_players_3d.size(), _started_3d, func(idx: int) -> bool: return _players_3d[idx].playing)
		var p3 := _players_3d[i]
		p3.stop()
		p3.stream = stream
		p3.global_position = position
		p3.unit_size = s[2]
		p3.volume_db = vol
		p3.pitch_scale = pitch
		p3.play()
		_started_3d[i] = now
	else:
		var j := _pick(_players_2d.size(), _started_2d, func(idx: int) -> bool: return _players_2d[idx].playing)
		var p := _players_2d[j]
		p.stop()
		p.stream = stream
		p.volume_db = vol
		p.pitch_scale = pitch
		p.play()
		_started_2d[j] = now

## Plays at a node's current position (convenience for Node3D stations/items).
func play_at(sound: StringName, node: Node3D) -> void:
	if node != null and is_instance_valid(node) and node.is_inside_tree():
		play(sound, node.global_position)
	else:
		play(sound)

func has_sound(sound: StringName) -> bool:
	return SOUNDS.has(sound)

## The synthesised stream, e.g. for a looping/attached AudioStreamPlayer3D of your own.
func get_stream(sound: StringName) -> AudioStreamWAV:
	return _get_or_synth(sound)

func get_sound_names() -> Array[StringName]:
	return SOUNDS.duplicate()

## Number of voices currently playing (tests / debugging).
func get_active_voice_count() -> int:
	var c := 0
	for p in _players_2d:
		if p.playing:
			c += 1
	for p3 in _players_3d:
		if p3.playing:
			c += 1
	return c

func stop_all() -> void:
	for p in _players_2d:
		p.stop()
	for p3 in _players_3d:
		p3.stop()

# ------------------------------------------------------------------------------------------ internals
func _pick(count: int, started: PackedInt64Array, is_busy: Callable) -> int:
	var oldest := 0
	for i in count:
		if not is_busy.call(i):
			return i
		if started[i] < started[oldest]:
			oldest = i
	return oldest   # voice stealing: all busy -> restart the oldest

func _setup_bus() -> void:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS_NAME)
		AudioServer.set_bus_send(idx, &"Master")
	_bus = BUS_NAME if AudioServer.get_bus_index(BUS_NAME) != -1 else &"Master"
	_apply_bus_volume()

func _apply_bus_volume() -> void:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, volume_db)

# ---------------------------------------------------------------------------------------- synthesis
# Tiny additive synth. Each recipe mixes layers into a float buffer; _to_wav() peak-normalises it and
# converts to 16-bit PCM. Noise uses a fixed seed per sound so every peer/run hears the same thing.

const C5 := 523.25
const E5 := 659.25
const G5 := 783.99
const C6 := 1046.5

func _synth(sound: StringName) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(sound))
	var b: PackedFloat32Array
	match sound:
		&"buy":
			b = _buf(0.42)
			_tone(b, 0.0, 0.08, 987.77, 987.77, 0.7, Wave.CHIP, 0.002, 1.5)
			_tone(b, 0.07, 0.35, 1318.5, 1318.5, 0.8, Wave.CHIP, 0.002, 4.0)
			_tone(b, 0.07, 0.3, 2637.0, 2637.0, 0.12, Wave.SINE, 0.002, 6.0)
		&"coin":
			b = _buf(0.3)
			_tone(b, 0.0, 0.05, 1567.98, 1567.98, 0.6, Wave.CHIP, 0.002, 1.0)
			_tone(b, 0.045, 0.25, 2093.0, 2093.0, 0.7, Wave.CHIP, 0.002, 5.0)
		&"plant":
			b = _buf(0.26)
			_tone(b, 0.0, 0.2, 230.0, 65.0, 1.0, Wave.SINE, 0.003, 5.0)
			_noise(b, rng, 0.0, 0.07, 0.35, 0.12, 0.0, 0.002, 7.0)
			_tone(b, 0.0, 0.035, 650.0, 300.0, 0.25, Wave.SINE, 0.001, 3.0)
		&"water":
			b = _buf(0.6)
			_noise(b, rng, 0.0, 0.42, 0.3, 0.45, 0.06, 0.03, 5.0)
			for i in 7:
				var t := rng.randf_range(0.02, 0.42)
				var f := rng.randf_range(380.0, 760.0)
				_tone(b, t, 0.05, f, f * 2.3, rng.randf_range(0.25, 0.4), Wave.SINE, 0.004, 2.5)
		&"refill":
			b = _buf(0.62)
			_noise(b, rng, 0.0, 0.5, 0.18, 0.3, 0.04, 0.05, 3.0)
			for i in 5:
				var f := 180.0 + i * 45.0
				_tone(b, 0.03 + i * 0.1, 0.08, f, f * 2.0, 0.45, Wave.SINE, 0.004, 2.0)
		&"harvest":
			b = _buf(0.36)
			_noise(b, rng, 0.0, 0.02, 0.6, 1.0, 0.55, 0.0005, 9.0)
			_tone(b, 0.0, 0.02, 3200.0, 3000.0, 0.18, Wave.SINE, 0.0005, 6.0)
			_noise(b, rng, 0.07, 0.02, 0.6, 1.0, 0.55, 0.0005, 9.0)
			_tone(b, 0.07, 0.02, 3400.0, 3100.0, 0.18, Wave.SINE, 0.0005, 6.0)
			_tone(b, 0.13, 0.12, 280.0, 950.0, 0.85, Wave.SINE, 0.004, 3.0)
			_tone(b, 0.13, 0.12, 560.0, 1900.0, 0.2, Wave.SINE, 0.004, 4.0)
		&"sell":
			b = _buf(0.95)
			_noise(b, rng, 0.0, 0.03, 0.45, 0.6, 0.15, 0.001, 6.0)
			_tone(b, 0.0, 0.06, 160.0, 90.0, 0.45, Wave.SINE, 0.002, 4.0)
			_bell(b, 0.06, 0.85, 1760.0, 0.8)
			_bell(b, 0.11, 0.7, 2349.3, 0.45)
		&"pickup":
			b = _buf(0.12)
			_tone(b, 0.0, 0.1, 360.0, 980.0, 1.0, Wave.SINE, 0.002, 3.5)
			_tone(b, 0.0, 0.1, 720.0, 1960.0, 0.18, Wave.SINE, 0.002, 4.0)
		&"pop":
			b = _buf(0.1)
			_tone(b, 0.0, 0.08, 500.0, 1300.0, 1.0, Wave.SINE, 0.001, 4.0)
		&"drop":
			b = _buf(0.26)
			_tone(b, 0.0, 0.22, 150.0, 45.0, 1.0, Wave.SINE, 0.002, 6.0)
			_noise(b, rng, 0.0, 0.08, 0.5, 0.08, 0.0, 0.001, 6.0)
			_tone(b, 0.0, 0.04, 440.0, 380.0, 0.25, Wave.TRIANGLE, 0.001, 5.0)
		&"error":
			b = _buf(0.3)
			_tone(b, 0.0, 0.11, 185.0, 180.0, 0.55, Wave.SQUARE, 0.004, 0.6)
			_tone(b, 0.0, 0.11, 192.0, 187.0, 0.35, Wave.SQUARE, 0.004, 0.6)
			_tone(b, 0.15, 0.13, 140.0, 132.0, 0.55, Wave.SQUARE, 0.004, 0.8)
			_tone(b, 0.15, 0.13, 146.0, 138.0, 0.35, Wave.SQUARE, 0.004, 0.8)
			_lowpass(b, 0.35)
		&"grow":
			b = _buf(0.4)
			_tone(b, 0.0, 0.3, 260.0, 780.0, 0.9, Wave.SINE, 0.02, 2.5, 18.0, 0.03)
			_tone(b, 0.0, 0.3, 520.0, 1560.0, 0.25, Wave.SINE, 0.02, 3.0, 18.0, 0.03)
			_tone(b, 0.26, 0.1, 1568.0, 1568.0, 0.15, Wave.SINE, 0.002, 5.0)
		&"ready":
			b = _buf(0.7)
			var notes := [1318.5, 1661.2, 1975.5, 2637.0]
			for i in notes.size():
				_bell(b, i * 0.055, 0.4, notes[i], 0.45)
		&"round_win":
			b = _buf(1.25)
			_tone(b, 0.0, 0.12, C5, C5, 0.7, Wave.CHIP, 0.004, 1.5)
			_tone(b, 0.12, 0.12, E5, E5, 0.7, Wave.CHIP, 0.004, 1.5)
			_tone(b, 0.24, 0.12, G5, G5, 0.7, Wave.CHIP, 0.004, 1.5)
			_tone(b, 0.36, 0.85, C6, C6, 0.75, Wave.CHIP, 0.004, 2.2, 6.0, 0.008)
			_tone(b, 0.36, 0.85, G5, G5, 0.35, Wave.CHIP, 0.004, 2.5)
			_tone(b, 0.36, 0.85, E5, E5, 0.3, Wave.CHIP, 0.004, 2.5)
			_bell(b, 0.38, 0.6, 2093.0, 0.25)
			_bell(b, 0.46, 0.6, 2637.0, 0.2)
		&"round_start":
			b = _buf(0.7)
			_tone(b, 0.0, 0.1, G5, G5, 0.6, Wave.CHIP, 0.004, 1.5)
			_tone(b, 0.1, 0.5, C6, C6, 0.7, Wave.CHIP, 0.004, 2.5, 6.0, 0.006)
			_bell(b, 0.1, 0.5, 2093.0, 0.2)
		&"round_lose":
			b = _buf(2.0)
			var lose := [392.0, 369.99, 349.23]
			for i in lose.size():
				_tone(b, i * 0.32, 0.3, lose[i], lose[i] * 0.985, 0.7, Wave.SAW, 0.03, 1.2)
			_tone(b, 0.96, 1.0, 329.63, 311.0, 0.75, Wave.SAW, 0.03, 1.4, 5.0, 0.025)
			_lowpass(b, 0.12)
		&"tick":
			b = _buf(0.05)
			_tone(b, 0.0, 0.04, 1900.0, 1700.0, 0.8, Wave.SINE, 0.0005, 10.0)
			_noise(b, rng, 0.0, 0.006, 0.3, 1.0, 0.5, 0.0003, 8.0)
		&"countdown":
			b = _buf(0.22)
			_tone(b, 0.0, 0.2, 880.0, 880.0, 0.7, Wave.CHIP, 0.003, 4.0)
		&"ui_click":
			b = _buf(0.06)
			_tone(b, 0.0, 0.05, 1050.0, 700.0, 0.9, Wave.SINE, 0.0008, 7.0)
			_noise(b, rng, 0.0, 0.005, 0.2, 1.0, 0.5, 0.0003, 8.0)
		&"ui_hover":
			b = _buf(0.03)
			_tone(b, 0.0, 0.025, 2200.0, 2000.0, 0.6, Wave.SINE, 0.0005, 8.0)
		&"ui_open":
			b = _buf(0.16)
			_tone(b, 0.0, 0.14, 480.0, 1000.0, 0.9, Wave.SINE, 0.004, 3.0)
			_tone(b, 0.0, 0.14, 960.0, 2000.0, 0.15, Wave.SINE, 0.004, 3.0)
		&"ui_close":
			b = _buf(0.16)
			_tone(b, 0.0, 0.14, 950.0, 450.0, 0.9, Wave.SINE, 0.004, 3.0)
			_tone(b, 0.0, 0.14, 1900.0, 900.0, 0.12, Wave.SINE, 0.004, 3.0)
		&"whoosh":
			b = _buf(0.35)
			_noise(b, rng, 0.0, 0.32, 0.6, 0.25, 0.03, 0.12, 2.0)
		_:
			b = _buf(0.1)
			_tone(b, 0.0, 0.08, 600.0, 600.0, 0.5, Wave.SINE, 0.002, 4.0)
	return _to_wav(b)

func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * MIX_RATE))
	b.fill(0.0)
	return b

## Adds an oscillator with an exponential pitch glide f0 -> f1, linear attack, exponential decay
## (decay = e-folds over the whole duration), optional vibrato (hz, depth as a fraction of pitch).
## Hot loop: per-sample multipliers instead of pow()/exp(), no per-sample match.
func _tone(b: PackedFloat32Array, start: float, dur: float, f0: float, f1: float, amp: float, wave: int,
		attack: float, decay: float, vib_hz: float = 0.0, vib_depth: float = 0.0) -> void:
	var s0 := int(start * MIX_RATE)
	var n := mini(int(dur * MIX_RATE), b.size() - s0)
	if n <= 0 or maxf(f0, f1) >= MIX_RATE * 0.48:
		return
	var inv_rate := 1.0 / MIX_RATE
	var f_step := pow(f1 / f0, 1.0 / n)
	var d_step := exp(-decay / n)
	var att_n := maxf(attack * MIX_RATE, 1.0)
	var fade_n := maxf(minf(0.004 * MIX_RATE, n * 0.5), 1.0)
	# Harmonic weights (fundamental, 2nd, 3rd, 4th); harmonics above Nyquist are dropped.
	var w := [1.0, 0.0, 0.0, 0.0]
	match wave:
		Wave.SAW:
			w = [0.55, 0.275, 0.18, 0.14]
		Wave.CHIP:
			w = [0.7, 0.245, 0.126, 0.0]
	var top := maxf(f0, f1)
	for h in range(1, 4):
		if top * (h + 1) >= MIX_RATE * 0.48:
			w[h] = 0.0
	var w1: float = w[0]
	var w2: float = w[1]
	var w3: float = w[2]
	var w4: float = w[3]
	var multi := w2 != 0.0 or w3 != 0.0 or w4 != 0.0
	var phase := 0.0
	var f := f0
	var decay_env := 1.0
	var vib_k := TAU * vib_hz * inv_rate
	for i in n:
		var fi := f
		if vib_hz > 0.0:
			fi *= 1.0 + vib_depth * sin(vib_k * i)
		phase += fi * inv_rate
		if phase >= 1.0:
			phase -= 1.0
		var x := TAU * phase
		var v: float
		if wave == Wave.TRIANGLE:
			v = 1.0 - 4.0 * absf(phase - 0.5)
		elif wave == Wave.SQUARE:
			v = tanh(3.0 * sin(x))
		elif multi:
			v = w1 * sin(x) + w2 * sin(2.0 * x) + w3 * sin(3.0 * x) + w4 * sin(4.0 * x)
		else:
			v = w1 * sin(x)
		var env := decay_env
		if i < att_n:
			env *= i / att_n
		if i > n - fade_n:
			env *= (n - i) / fade_n
		b[s0 + i] += v * amp * env
		f *= f_step
		decay_env *= d_step

## Adds noise through a one-pole low-pass (lp 0..1, 1 = unfiltered) minus a slower low-pass (hp 0..1) =
## a cheap band-pass. Linear attack, exponential decay.
func _noise(b: PackedFloat32Array, rng: RandomNumberGenerator, start: float, dur: float, amp: float,
		lp: float, hp: float, attack: float, decay: float) -> void:
	var s0 := int(start * MIX_RATE)
	var n := mini(int(dur * MIX_RATE), b.size() - s0)
	if n <= 0:
		return
	var low := 0.0
	var lower := 0.0
	var att_n := maxf(attack * MIX_RATE, 1.0)
	var d_step := exp(-decay / n)
	var env := 1.0
	for i in n:
		var x := rng.randf() * 2.0 - 1.0
		low += (x - low) * lp
		lower += (low - lower) * hp
		var e := env
		if i < att_n:
			e *= i / att_n
		b[s0 + i] += (low - lower) * amp * e
		env *= d_step

## Inharmonic bell partials (1, 2, 2.76, 5.4) with faster decay on the higher ones.
func _bell(b: PackedFloat32Array, start: float, dur: float, f: float, amp: float) -> void:
	_tone(b, start, dur, f, f, amp, Wave.SINE, 0.001, 4.0)
	_tone(b, start, dur * 0.8, f * 2.0, f * 2.0, amp * 0.3, Wave.SINE, 0.001, 5.0)
	_tone(b, start, dur * 0.6, f * 2.76, f * 2.76, amp * 0.22, Wave.SINE, 0.001, 6.0)
	_tone(b, start, dur * 0.35, f * 5.4, f * 5.4, amp * 0.1, Wave.SINE, 0.001, 8.0)

func _lowpass(b: PackedFloat32Array, k: float) -> void:
	var y := 0.0
	for i in b.size():
		y += (b[i] - y) * k
		b[i] = y

func _to_wav(b: PackedFloat32Array) -> AudioStreamWAV:
	var peak := 0.0001
	for v in b:
		peak = maxf(peak, absf(v))
	var gain := 0.89 / peak
	var bytes := PackedByteArray()
	bytes.resize(b.size() * 2)
	for i in b.size():
		bytes.encode_s16(i * 2, int(clampf(b[i] * gain, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MIX_RATE
	w.stereo = false
	w.loop_mode = AudioStreamWAV.LOOP_DISABLED
	w.data = bytes
	return w
