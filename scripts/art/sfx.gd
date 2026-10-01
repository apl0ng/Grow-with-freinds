extends Node
## Autoload "Sfx": procedurally synthesised sounds (no audio assets). Owned by the audio agent.
##
##   Sfx.play(&"harvest", plot.global_position)        # 3D, attenuated, panned (world events)
##   Sfx.play(&"ui_click")                               # 2D (UI, your own actions, round sounds)
##   Sfx.play(&"step", Vector3.INF, -8.0)                # 2D, 8 dB quieter than its SETTINGS row (own footsteps)
##   var h := Sfx.play_loop(&"keys", boss_node)          # loop follows a Node3D (or a Vector3, or 2D with no target)
##   Sfx.stop_loop(h)                                    # 0.15 s fade, then the loop player is freed
##
## Every sound is generated once into a 16-bit mono AudioStreamWAV (22.05 kHz) from the recipes below, on a
## WorkerThreadPool task started in _ready (~0.4 s of CPU off the main thread); a sound requested before the
## worker reached it is synthesised on the spot and cached. One-shots use small pools of players (MAX_2D + MAX_3D
## voices; the oldest voice is stolen), a little random pitch variation, and a per-sound retrigger guard so ten
## plots finishing on the same frame do not stack into one deafening sound. Loops (play_loop) get their own
## players outside the pools (never stolen, at most MAX_LOOPS), process_mode ALWAYS, on the SFX bus.
## Unknown names warn once and are ignored (never crash).
## MOOD (nobody is happy): everything is duller and lower than a party game. round_win is a muffled end-of-shift
## bell (relief, not joy), round_start a flat factory buzzer, buy/sell/ready single low dings. The M10 factory
## set is concrete, steel, paper and mains hum: nothing rings bright, nothing stings.
## Works headless (dummy audio driver). Sounds are local only: call play() from code that runs on every peer
## (synced setters, call_local RPCs, GameState signals). See STYLE.md "Sound".
## Do NOT add a class_name (autoload).
##
## SOUNDS (name: what it is / use)
##   buy: dull coin clink / purchase.  plant: soft thump + pop / seed planted.  water: bubbly splash / watered.
##   harvest: snip-snip + rising pop.  sell: register drawer clunk + one tired ding.  pickup: quick rising pop.
##   drop: low thud.  error: short uh-uh buzz / denied action.  grow: small low bloop / stage change.
##   round_win: clunk + muffled two-tone bell going down / quota met.  round_lose: sad trombone / time's up.
##   tick: click / last 10 s.  ui_click, ui_open, ui_close: tock, rising blip, falling blip.
##   extras: ready (low break-room ding), refill (glugs), ui_hover (tiny tick), coin, pop, whoosh,
##   countdown (3-2-1 beep), round_start (flat shift buzzer).
##   M10 (friendslop pass):
##   step: soft scuff on concrete, a little grit / one per stride (remote players 3D, the local one 2D and quieter).
##   throw: a short heave of air + sleeve / an item leaves the hand.
##   bonk: dull thud with a small clonk / a bundle hits a head.
##   shove: cloth and a low grunt-like tone / a worker is pushed.
##   ping: two dull toks, the second lower / an intercom "you" (Comms ping).
##   chat: a paper flick / a chat line arrives.
##   alarm: flat two-tone factory buzzer, twice / an event starts (harsh but quiet).
##   power_down: relay click, then the mains hum sags into nothing / power cut.
##   power_up: breaker thunk, a fluoro stutters three times, then holds / power back.
##   keys: keys on a belt for one stride (0.5 s, seamless loop) / the Boss walking.
##   write_up: pen scratching, then a rubber stamp / a write-up is issued.
##   door_slam: a steel door far too heavy, lowpassed ring and frame rattle / back room.
##   confiscate: cloth and a short falling tone / snatched out of your hands.
##   hum: 60 Hz mains hum with harmonics, seamless 1.0 s loop / room ambience (very quiet).
##   rat: two thin squeaks / the rat.
##
## dB LADDER (SETTINGS volume). art_test prints every sound's whole-buffer RMS and "loud" = 20*log10(rms) + volume
## (dB, loudest first); the intended order, top to bottom:
##   impacts    door_slam -1, bonk -2, plant -2, drop -3            loud ~ -19..-20  (strong, never painful: peaks 0.89, 3D max_db 3)
##   events     alarm -13 (sustained), power_down -6, power_up -5,  loud ~ -20..-24  (room-wide, unit_size 12)
##              round_start -8, round_win -6
##   feedback   confiscate -5, shove -5, write_up -4, throw -8,     loud ~ -19..-26  (things done to you or by you)
##              ping -7, buy -6, coin -6, ui_* -8, error -9
##   texture    step -12, rat -14, chat -14, keys -10 (loop),       loud ~ -28..-32  (one per stride, per line, per squeak)
##              ui_hover -16, tick -9
##   ambience   hum -22                                            loud ~ -29       (60 Hz reads far quieter than its RMS;
##                                                                                   noticed when it stops)
## Sustained sounds (alarm, hum, buzzers) have a much higher RMS than transients at the same peak, so their rows sit
## 4-8 dB lower than their felt level; short impacts with long tails (door_slam, write_up) read low in RMS and are
## judged by their peak instead.

const MIX_RATE := 22050
const MAX_2D := 8
const MAX_3D := 16
## Loop players alive at once (play_loop refuses the ninth).
const MAX_LOOPS := 8
const BUS_NAME := &"SFX"
## A sound re-triggered sooner than this after itself is skipped (prevents stacking / phasing).
const MIN_RETRIGGER_MSEC := 40
## The volume a stopped loop fades to before its player is freed.
const LOOP_FADE_FLOOR_DB := -60.0

## Every sound name, in the order they are synthesised. First 15 are the CONTRACTS.md set.
const SOUNDS: Array[StringName] = [
	&"buy", &"plant", &"water", &"harvest", &"sell", &"pickup", &"drop", &"error", &"grow",
	&"round_win", &"round_lose", &"tick", &"ui_click", &"ui_open", &"ui_close",
	# extras (art pass 1)
	&"ready", &"refill", &"ui_hover", &"coin", &"pop", &"whoosh", &"countdown", &"round_start",
	# M10 friendslop pass (audio agent)
	&"step", &"throw", &"bonk", &"shove", &"ping", &"chat", &"alarm", &"power_down", &"power_up", &"keys",
	&"write_up", &"door_slam", &"confiscate", &"hum", &"rat",
	# M12 (lead placeholders: hostile plant, flamethrower, disruptions; the audio pass refines them)
	&"hostile_rise", &"hostile_bite", &"hostile_eat", &"hostile_die", &"flame", &"ignite", &"glass_break", &"scorch",
	&"headcount", &"water_off", &"shortage",
]

## Sounds synthesised as seamless loops (loop_mode FORWARD over the whole buffer): ambience and walking keys.
## Only these can be started with play_loop().
const LOOPING: Array[StringName] = [&"hum", &"keys", &"hostile_eat", &"flame"]

## Per-sound playback settings: [volume_db, pitch_variation (+-fraction), 3D unit_size].
const SETTINGS := {
	&"buy": [-6.0, 0.04, 6.0],
	&"plant": [-2.0, 0.08, 6.0],
	&"water": [-4.0, 0.08, 6.0],
	&"harvest": [-3.0, 0.06, 6.0],
	&"sell": [-3.0, 0.02, 8.0],
	&"pickup": [-5.0, 0.10, 5.0],
	&"drop": [-3.0, 0.10, 5.0],
	&"error": [-9.0, 0.0, 5.0],
	&"grow": [-5.0, 0.07, 6.0],
	&"round_win": [-6.0, 0.0, 10.0],
	&"round_lose": [-4.0, 0.0, 10.0],
	&"tick": [-9.0, 0.0, 5.0],
	&"ui_click": [-8.0, 0.05, 5.0],
	&"ui_open": [-8.0, 0.03, 5.0],
	&"ui_close": [-8.0, 0.03, 5.0],
	&"ready": [-9.0, 0.03, 7.0],
	&"refill": [-4.0, 0.06, 6.0],
	&"ui_hover": [-16.0, 0.08, 5.0],
	&"coin": [-6.0, 0.06, 6.0],
	&"pop": [-6.0, 0.12, 5.0],
	&"whoosh": [-8.0, 0.08, 5.0],
	&"countdown": [-6.0, 0.0, 5.0],
	&"round_start": [-8.0, 0.0, 10.0],
	# M10: see the dB ladder in the header.
	&"step": [-12.0, 0.12, 4.0],
	&"throw": [-8.0, 0.08, 5.0],
	&"bonk": [-2.0, 0.08, 6.0],
	&"shove": [-5.0, 0.10, 5.0],
	&"ping": [-7.0, 0.0, 8.0],
	&"chat": [-14.0, 0.05, 5.0],
	&"alarm": [-13.0, 0.0, 12.0],
	&"power_down": [-6.0, 0.0, 12.0],
	&"power_up": [-5.0, 0.0, 12.0],
	&"keys": [-10.0, 0.0, 5.0],
	&"write_up": [-4.0, 0.03, 6.0],
	&"door_slam": [-1.0, 0.03, 10.0],
	&"confiscate": [-5.0, 0.05, 6.0],
	&"hum": [-22.0, 0.0, 12.0],
	&"rat": [-14.0, 0.10, 4.0],
	&"hostile_rise": [-6.0, 0.05, 7.0],
	&"hostile_bite": [-4.0, 0.08, 6.0],
	&"hostile_eat": [-16.0, 0.0, 5.0],
	&"hostile_die": [-5.0, 0.05, 8.0],
	&"flame": [-9.0, 0.0, 7.0],
	&"ignite": [-6.0, 0.06, 6.0],
	&"glass_break": [-3.0, 0.04, 9.0],
	&"scorch": [-8.0, 0.08, 6.0],
	&"headcount": [-10.0, 0.0, 12.0],
	&"water_off": [-8.0, 0.0, 12.0],
	&"shortage": [-10.0, 0.0, 12.0],
}

enum Wave { SINE, TRIANGLE, SQUARE, SAW, CHIP }

## Master volume of every Sfx sound (dB, applied to the SFX bus when it exists, else to each player).
var volume_db: float = 0.0:
	set(v):
		volume_db = v
		_apply_bus_volume()
## Set false to silence all Sfx (e.g. automated tests, a settings toggle). Running loops keep going; stop them.
var enabled: bool = true

var _streams: Dictionary = {}          # StringName -> AudioStreamWAV
var _players_2d: Array[AudioStreamPlayer] = []
var _players_3d: Array[AudioStreamPlayer3D] = []
var _started_2d: PackedInt64Array = []
var _started_3d: PackedInt64Array = []
var _last_play: Dictionary = {}        # StringName -> msec
var _last_voice: Node = null           # the player used by the most recent play() (tests)
var _warned: Dictionary = {}
var _bus: StringName = &"Master"
var _rng := RandomNumberGenerator.new()
var _mutex := Mutex.new()
var _task_id: int = -1
var _abort_synth: bool = false
# Loops: handle -> {player: Node, node: Node3D or null, follows: bool, sound: StringName}. Handles start at 1,
# never reused. A followed node that gets freed ends its loop in _process.
var _loops: Dictionary = {}
var _fading: Array[Node] = []          # loop players on their way out (fade tween running)
var _next_handle: int = 1

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # UI sounds keep working while the tree is paused
	set_process(false)                        # only while a loop follows a node
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
		_setup_3d(p3)
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
	stop_all_loops()

func _process(_delta: float) -> void:
	# Loops attached to a Node3D follow it; a freed node ends its loop.
	var dead: Array[int] = []
	for h: int in _loops:
		var e: Dictionary = _loops[h]
		if not e.follows:
			continue
		# Untyped on purpose: a freed instance cannot be assigned to a Node3D var, and it compares equal to null.
		var n: Variant = e.node
		if not is_instance_valid(n):
			dead.append(h)
		elif (n as Node3D).is_inside_tree():
			(e.player as AudioStreamPlayer3D).global_position = (n as Node3D).global_position
	for h in dead:
		_end_loop(h, 0.0)
	if _loops.is_empty():
		set_process(false)

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

## Plays a sound once. No position (Vector3.INF) = 2D/non-positional; otherwise a 3D voice at that world point.
## volume_offset_db is added to the sound's SETTINGS volume (e.g. -8.0 for the local player's own footsteps).
func play(sound: StringName, position: Vector3 = Vector3.INF, volume_offset_db: float = 0.0) -> void:
	if not enabled or not is_inside_tree() or _players_2d.is_empty():
		return
	var stream := _get_or_synth(sound)
	if stream == null:
		_warn_once(sound, "Sfx.play: unknown sound '%s' (see Sfx.SOUNDS / STYLE.md)" % sound)
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
	var vol: float = s[0] + volume_offset_db
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
		_last_voice = p3
	else:
		var j := _pick(_players_2d.size(), _started_2d, func(idx: int) -> bool: return _players_2d[idx].playing)
		var p := _players_2d[j]
		p.stop()
		p.stream = stream
		p.volume_db = vol
		p.pitch_scale = pitch
		p.play()
		_started_2d[j] = now
		_last_voice = p

## Plays at a node's current position (convenience for Node3D stations/items).
func play_at(sound: StringName, node: Node3D, volume_offset_db: float = 0.0) -> void:
	if node != null and is_instance_valid(node) and node.is_inside_tree():
		play(sound, node.global_position, volume_offset_db)
	else:
		play(sound, Vector3.INF, volume_offset_db)

# ------------------------------------------------------------------------------------------------ loops
## Starts a looping sound (one of LOOPING). target: Vector3.INF or null = 2D; a Vector3 = fixed 3D point;
## a Node3D = the emitter follows the node every frame while it is valid and inside the tree, and the loop stops
## itself when the node is freed. Returns a handle > 0, or 0 when refused (unknown or non-looping sound, Sfx
## disabled, MAX_LOOPS loops already running, freed node). Handles are never reused within a session.
func play_loop(sound: StringName, target: Variant = Vector3.INF) -> int:
	if not enabled or not is_inside_tree():
		return 0
	if not LOOPING.has(sound):
		if SOUNDS.has(sound):
			_warn_once(sound, "Sfx.play_loop: '%s' is not a looping sound (see Sfx.LOOPING)" % sound)
		else:
			_warn_once(sound, "Sfx.play_loop: unknown sound '%s' (see Sfx.SOUNDS / STYLE.md)" % sound)
		return 0
	if _loops.size() >= MAX_LOOPS:
		return 0
	var node: Node3D = null
	var position := Vector3.INF
	if target is Node3D:
		node = target
		if not is_instance_valid(node):
			return 0
		position = node.global_position if node.is_inside_tree() else Vector3.ZERO
	elif target is Vector3:
		position = target
	elif target != null:
		_warn_once(StringName("loop_target_" + type_string(typeof(target))),
			"Sfx.play_loop: target must be Vector3.INF, a Vector3 or a Node3D (got %s)" % type_string(typeof(target)))
		return 0
	var stream := _get_or_synth(sound)
	if stream == null:
		return 0
	var s: Array = SETTINGS.get(sound, [-6.0, 0.0, 6.0])
	var vol: float = s[0]
	if _bus == &"Master":
		vol += volume_db
	var pitch := 1.0 + _rng.randf_range(-s[1], s[1])
	var handle := _next_handle
	_next_handle += 1
	var player: Node
	if position.is_finite():
		var p3 := AudioStreamPlayer3D.new()
		p3.name = "Loop3D_%d" % handle
		_setup_3d(p3)
		p3.unit_size = s[2]
		add_child(p3)
		p3.global_position = position
		p3.stream = stream
		p3.volume_db = vol
		p3.pitch_scale = pitch
		p3.play()
		player = p3
	else:
		var p := AudioStreamPlayer.new()
		p.name = "Loop2D_%d" % handle
		p.bus = _bus
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(p)
		p.stream = stream
		p.volume_db = vol
		p.pitch_scale = pitch
		p.play()
		player = p
	_loops[handle] = {"player": player, "node": node, "follows": node != null, "sound": sound}
	if node != null:
		set_process(true)
	return handle

## Stops a loop: fades over fade_sec (0 = at once), then frees its player. Unknown / stopped handles: no-op.
## The handle counts as stopped immediately (is_loop_playing false, a slot is free for play_loop).
func stop_loop(handle: int, fade_sec: float = 0.15) -> void:
	if _loops.has(handle):
		_end_loop(handle, fade_sec)

## Stops every loop at once (no fade).
func stop_all_loops() -> void:
	for h: int in _loops.keys():
		_end_loop(h, 0.0)
	for p in _fading:
		if is_instance_valid(p):
			p.queue_free()
	_fading.clear()

func is_loop_playing(handle: int) -> bool:
	return _loops.has(handle)

## Absolute volume (dB) for one running loop, replacing its SETTINGS volume. No-op for stopped handles.
func set_loop_volume(handle: int, db: float) -> void:
	var e: Dictionary = _loops.get(handle, {})
	if e.is_empty():
		return
	var vol := db
	if _bus == &"Master":
		vol += volume_db
	e.player.volume_db = vol

## Running loops (fading ones no longer count).
func get_active_loop_count() -> int:
	return _loops.size()

## The AudioStreamPlayer / AudioStreamPlayer3D behind a running loop, or null (tests, debugging).
func get_loop_player(handle: int) -> Node:
	var e: Dictionary = _loops.get(handle, {})
	return e.get("player") if not e.is_empty() else null

## The voice used by the most recent successful play() (tests, debugging). May be null.
func get_last_voice() -> Node:
	return _last_voice if _last_voice != null and is_instance_valid(_last_voice) else null

func has_sound(sound: StringName) -> bool:
	return SOUNDS.has(sound)

## The synthesised stream, e.g. for a looping/attached AudioStreamPlayer3D of your own.
func get_stream(sound: StringName) -> AudioStreamWAV:
	return _get_or_synth(sound)

func get_sound_names() -> Array[StringName]:
	return SOUNDS.duplicate()

## Number of one-shot voices currently playing (tests / debugging). Loops are not counted.
func get_active_voice_count() -> int:
	var c := 0
	for p in _players_2d:
		if p.playing:
			c += 1
	for p3 in _players_3d:
		if p3.playing:
			c += 1
	return c

## Stops every one-shot voice and every loop.
func stop_all() -> void:
	for p in _players_2d:
		p.stop()
	for p3 in _players_3d:
		p3.stop()
	stop_all_loops()

## Numbers about a synthesised stream (tests, loudness table): peak and rms in 0..1 of full scale, dc = mean
## sample (offset), seconds, samples, clipped = samples at full scale. Only 16-bit mono streams are measured.
static func measure(stream: AudioStreamWAV) -> Dictionary:
	var out := {"peak": 0.0, "rms": 0.0, "seconds": 0.0, "dc": 0.0, "samples": 0, "clipped": 0}
	if stream == null or stream.format != AudioStreamWAV.FORMAT_16_BITS or stream.stereo:
		return out
	var data := stream.data
	var n := data.size() / 2
	if n == 0:
		return out
	var peak := 0
	var sum := 0.0
	var sum_sq := 0.0
	var clipped := 0
	for i in n:
		var s := data.decode_s16(i * 2)
		var a := absi(s)
		if a > peak:
			peak = a
		if a >= 32767:
			clipped += 1
		var v := s / 32767.0
		sum += v
		sum_sq += v * v
	out.peak = peak / 32767.0
	out.rms = sqrt(sum_sq / n)
	out.dc = sum / n
	out.seconds = float(n) / stream.mix_rate
	out.samples = n
	out.clipped = clipped
	return out

# ------------------------------------------------------------------------------------------ internals
func _pick(count: int, started: PackedInt64Array, is_busy: Callable) -> int:
	var oldest := 0
	for i in count:
		if not is_busy.call(i):
			return i
		if started[i] < started[oldest]:
			oldest = i
	return oldest   # voice stealing: all busy -> restart the oldest

func _setup_3d(p3: AudioStreamPlayer3D) -> void:
	p3.bus = _bus
	p3.process_mode = Node.PROCESS_MODE_ALWAYS
	p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p3.max_distance = 45.0
	p3.max_db = 3.0
	p3.panning_strength = 0.7
	p3.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED

func _warn_once(key: StringName, text: String) -> void:
	if not _warned.has(key):
		_warned[key] = true
		push_warning(text)

## Removes a loop from the table now; its player fades (or stops) and frees itself.
func _end_loop(handle: int, fade_sec: float) -> void:
	var e: Dictionary = _loops[handle]
	_loops.erase(handle)
	var maybe: Variant = e.player   # untyped: never assign a possibly freed instance to a typed var
	if not is_instance_valid(maybe):
		return
	var player: Node = maybe
	if fade_sec <= 0.0 or not player.is_inside_tree():
		player.stop()
		player.queue_free()
		return
	_fading.append(player)
	var tw := player.create_tween()
	tw.tween_property(player, "volume_db", LOOP_FADE_FLOOR_DB, fade_sec)
	tw.finished.connect(func() -> void:
		_fading.erase(player)
		if is_instance_valid(player):
			player.stop()
			player.queue_free())

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
# Tiny additive synth. Each recipe mixes layers into a float buffer; _to_wav() peak-normalises it (0.89) and
# converts to 16-bit PCM. Noise uses a fixed seed per sound so every peer/run hears the same thing.
# Cheat sheet: _noise lp 0.2 ~ 800 Hz, 0.5 ~ 2.4 kHz, 0.8 ~ 5.6 kHz one-pole cutoff; hp removes the rumble
# below ~ hp * 3.5 kHz. _lowpass(b, k) over the whole buffer with the same scale dulls everything.

func _synth(sound: StringName) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(sound))
	var b: PackedFloat32Array
	match sound:
		&"buy":   # dull coin clink: money leaves, nobody cheers
			b = _buf(0.34)
			_noise(b, rng, 0.0, 0.015, 0.3, 0.9, 0.4, 0.0005, 8.0)
			_tone(b, 0.0, 0.07, 740.0, 740.0, 0.6, Wave.SINE, 0.002, 2.5)
			_tone(b, 0.06, 0.26, 587.3, 587.3, 0.7, Wave.SINE, 0.002, 4.5)
			_lowpass(b, 0.5)
		&"coin":
			b = _buf(0.25)
			_tone(b, 0.0, 0.2, 880.0, 870.0, 0.7, Wave.SINE, 0.002, 5.0)
			_noise(b, rng, 0.0, 0.01, 0.25, 0.9, 0.4, 0.0005, 8.0)
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
		&"sell":   # old register drawer: a clunk and one tired ding
			b = _buf(0.8)
			_noise(b, rng, 0.0, 0.05, 0.5, 0.4, 0.1, 0.001, 5.0)
			_tone(b, 0.0, 0.09, 130.0, 70.0, 0.6, Wave.SINE, 0.002, 4.0)
			_bell(b, 0.07, 0.7, 880.0, 0.55)
			_lowpass(b, 0.45)
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
		&"grow":   # a small, low bloop (it grew. that's all.)
			b = _buf(0.3)
			_tone(b, 0.0, 0.24, 200.0, 420.0, 0.9, Wave.SINE, 0.02, 3.0)
			_tone(b, 0.0, 0.24, 400.0, 840.0, 0.15, Wave.SINE, 0.02, 3.5)
		&"ready":   # one soft low ding, like a microwave in the break room
			b = _buf(0.6)
			_bell(b, 0.0, 0.55, 659.25, 0.6)
			_lowpass(b, 0.5)
		&"round_win":   # "shift over": a clunk, then a muffled two-tone bell going DOWN. Relief, not joy.
			b = _buf(1.5)
			_noise(b, rng, 0.0, 0.06, 0.4, 0.3, 0.05, 0.001, 5.0)
			_tone(b, 0.0, 0.1, 110.0, 70.0, 0.5, Wave.SINE, 0.002, 4.0)
			_bell(b, 0.08, 0.9, 392.0, 0.7)      # G4
			_bell(b, 0.5, 1.0, 329.63, 0.6)      # E4
			_lowpass(b, 0.3)
		&"round_start":   # flat factory shift buzzer
			b = _buf(0.75)
			_tone(b, 0.0, 0.7, 98.0, 98.0, 0.6, Wave.SQUARE, 0.03, 0.5)
			_tone(b, 0.0, 0.7, 147.0, 146.0, 0.3, Wave.SQUARE, 0.03, 0.5)
			_lowpass(b, 0.12)
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
		# --- M10 friendslop pass. Dull, low, factory. Concrete, steel, paper, mains. ---
		&"step":   # a soft scuff on concrete: heel thump, a scuff, a little grit; pitch varies at play time
			b = _buf(0.11)
			_tone(b, 0.0, 0.06, 120.0, 68.0, 0.5, Wave.SINE, 0.002, 6.0)          # heel
			_noise(b, rng, 0.0, 0.1, 0.6, 0.25, 0.04, 0.004, 6.0)                 # the scuff
			_noise(b, rng, 0.01, 0.04, 0.25, 0.7, 0.3, 0.001, 8.0)                # grit
			_noise(b, rng, 0.05, 0.05, 0.3, 0.3, 0.05, 0.003, 5.0)                # toe drags
			_lowpass(b, 0.6)
			_fade_out(b, 0.01)
		&"throw":  # a short heave of air and a sleeve
			b = _buf(0.3)
			_noise(b, rng, 0.0, 0.28, 0.7, 0.3, 0.05, 0.07, 3.5)                  # air
			_noise(b, rng, 0.0, 0.1, 0.3, 0.65, 0.25, 0.02, 4.0)                  # sleeve
			_tone(b, 0.0, 0.16, 170.0, 95.0, 0.3, Wave.SINE, 0.02, 4.0)           # the heave itself
			_lowpass(b, 0.5)
			_fade_out(b, 0.03)
		&"bonk":   # a bundle to the head: dull thud with a small clonk, no cartoon sting
			b = _buf(0.26)
			_tone(b, 0.0, 0.2, 170.0, 50.0, 1.0, Wave.SINE, 0.001, 7.0)           # the head
			_noise(b, rng, 0.0, 0.03, 0.6, 0.45, 0.08, 0.0005, 6.0)               # impact
			_tone(b, 0.0, 0.07, 640.0, 560.0, 0.35, Wave.TRIANGLE, 0.001, 8.0)    # clonk
			_tone(b, 0.0, 0.05, 1100.0, 950.0, 0.12, Wave.SINE, 0.001, 9.0)
			_lowpass(b, 0.45)
			_fade_out(b, 0.02)
		&"shove":  # cloth against cloth and a low grunt-like tone
			b = _buf(0.22)
			_noise(b, rng, 0.0, 0.15, 0.55, 0.35, 0.08, 0.004, 5.0)               # cloth
			_tone(b, 0.01, 0.17, 128.0, 80.0, 0.6, Wave.SAW, 0.012, 5.0, 28.0, 0.04)   # grunt
			_tone(b, 0.0, 0.05, 240.0, 180.0, 0.25, Wave.TRIANGLE, 0.002, 6.0)    # contact
			_lowpass(b, 0.3)
			_fade_out(b, 0.02)
		&"ping":   # two dull toks, the second lower: an intercom "you"
			b = _buf(0.3)
			_tone(b, 0.0, 0.08, 640.0, 610.0, 0.7, Wave.SINE, 0.001, 7.0)
			_tone(b, 0.0, 0.05, 180.0, 160.0, 0.4, Wave.SINE, 0.001, 6.0)
			_noise(b, rng, 0.0, 0.01, 0.3, 0.6, 0.2, 0.0005, 6.0)
			_tone(b, 0.13, 0.12, 470.0, 445.0, 0.7, Wave.SINE, 0.001, 6.0)
			_tone(b, 0.13, 0.06, 150.0, 130.0, 0.4, Wave.SINE, 0.001, 6.0)
			_noise(b, rng, 0.13, 0.01, 0.3, 0.6, 0.2, 0.0005, 6.0)
			_lowpass(b, 0.4)
			_fade_out(b, 0.02)
		&"chat":   # a paper flick
			b = _buf(0.09)
			_noise(b, rng, 0.0, 0.07, 0.6, 0.55, 0.2, 0.003, 5.0)
			_noise(b, rng, 0.012, 0.025, 0.5, 0.85, 0.45, 0.0005, 6.0)
			_tone(b, 0.01, 0.03, 850.0, 480.0, 0.2, Wave.SINE, 0.001, 8.0)
			_lowpass(b, 0.6)
			_fade_out(b, 0.015)
		&"alarm":  # a flat two-tone factory buzzer, twice; the rasp is 47 Hz FM on a soft square
			b = _buf(1.1)
			for i in 2:
				var t0 := i * 0.56
				_tone(b, t0, 0.25, 220.0, 220.0, 0.55, Wave.SQUARE, 0.012, 0.5, 47.0, 0.025)
				_tone(b, t0, 0.25, 110.0, 110.0, 0.25, Wave.SAW, 0.012, 0.5)
				_tone(b, t0 + 0.27, 0.25, 165.0, 165.0, 0.55, Wave.SQUARE, 0.012, 0.5, 47.0, 0.025)
				_tone(b, t0 + 0.27, 0.25, 82.5, 82.5, 0.25, Wave.SAW, 0.012, 0.5)
				_noise(b, rng, t0, 0.52, 0.12, 0.15, 0.02, 0.02, 0.3)
			_lowpass(b, 0.2)
			_fade_out(b, 0.02)
		&"power_down":  # a relay click, then the mains hum sags into nothing while the fans wind down
			b = _buf(1.1)
			_noise(b, rng, 0.0, 0.012, 0.7, 0.8, 0.3, 0.0005, 6.0)                # relay
			_tone(b, 0.0, 0.03, 1800.0, 1200.0, 0.3, Wave.SINE, 0.0005, 8.0)
			_tone(b, 0.02, 1.0, 60.0, 16.0, 0.7, Wave.SINE, 0.01, 3.0)            # the hum, sagging
			_tone(b, 0.02, 0.9, 120.0, 32.0, 0.45, Wave.SINE, 0.01, 3.5)
			_tone(b, 0.02, 0.8, 180.0, 48.0, 0.2, Wave.SINE, 0.01, 4.0)
			_tone(b, 0.02, 0.7, 240.0, 64.0, 0.1, Wave.SINE, 0.01, 4.5)
			_noise(b, rng, 0.03, 0.9, 0.18, 0.12, 0.01, 0.05, 4.0)                # fans
			_lowpass(b, 0.3)
			_fade_out(b, 0.03)
		&"power_up":  # a breaker thunk, then a fluoro stutters three times and holds
			b = _buf(1.0)
			_tone(b, 0.0, 0.12, 110.0, 48.0, 1.0, Wave.SINE, 0.001, 6.0)          # the breaker
			_noise(b, rng, 0.0, 0.04, 0.6, 0.5, 0.1, 0.0005, 6.0)
			_tone(b, 0.0, 0.05, 900.0, 700.0, 0.25, Wave.TRIANGLE, 0.001, 8.0)    # the lever's clack
			for t: float in [0.26, 0.40, 0.52]:                                    # three flickers
				_tone(b, t, 0.06, 120.0, 120.0, 0.3, Wave.SQUARE, 0.003, 1.5)
				_noise(b, rng, t, 0.06, 0.12, 0.6, 0.3, 0.002, 2.0)
				_tone(b, t, 0.012, 2600.0, 2400.0, 0.12, Wave.SINE, 0.0005, 6.0)  # starter tick
			_tone(b, 0.62, 0.38, 120.0, 120.0, 0.3, Wave.SQUARE, 0.02, 1.2)       # holds (the hum loop takes over)
			_tone(b, 0.62, 0.38, 60.0, 60.0, 0.18, Wave.SINE, 0.02, 1.2)
			_noise(b, rng, 0.62, 0.38, 0.08, 0.5, 0.3, 0.02, 1.5)
			_lowpass(b, 0.3)
			_fade_out(b, 0.06)
		&"keys":   # keys on a belt for one stride (0.5 s): a bounce at the footfall, a smaller one mid-stride.
			b = _buf(0.5)  # Seamless: every hit ends before 0.42 s, both ends fade to zero.
			for t: float in [0.05, 0.075, 0.1, 0.16, 0.27, 0.3, 0.35]:
				var tt := t + rng.randf_range(-0.008, 0.008)
				var f := rng.randf_range(2300.0, 4300.0)
				var a := rng.randf_range(0.2, 0.45) * (1.3 if t < 0.12 else 1.0)
				_tone(b, tt, 0.05, f, f * 0.985, a, Wave.SINE, 0.0005, 6.0)
				_tone(b, tt, 0.04, f * 1.47, f * 1.46, a * 0.5, Wave.SINE, 0.0005, 7.0)
				_tone(b, tt, 0.03, f * 2.31, f * 2.3, a * 0.25, Wave.SINE, 0.0005, 8.0)
				_noise(b, rng, tt, 0.012, 0.3, 0.8, 0.4, 0.0005, 6.0)
			_noise(b, rng, 0.03, 0.42, 0.05, 0.2, 0.03, 0.05, 1.0)                # the belt
			_lowpass(b, 0.7)
			_fade_in(b, 0.03)
			_fade_out(b, 0.05)
		&"write_up":  # a pen scratching four strokes, then the rubber stamp comes down
			b = _buf(0.62)
			for s: Array in [[0.0, 0.08], [0.1, 0.06], [0.19, 0.1], [0.31, 0.05]]:
				_noise(b, rng, s[0], s[1], 0.35, 0.45, 0.25, 0.015, 2.5)
			_tone(b, 0.42, 0.15, 150.0, 60.0, 1.0, Wave.SINE, 0.001, 6.0)         # stamp
			_noise(b, rng, 0.42, 0.04, 0.5, 0.5, 0.08, 0.0005, 5.0)               # the pad
			_tone(b, 0.42, 0.05, 520.0, 300.0, 0.2, Wave.TRIANGLE, 0.001, 7.0)
			_lowpass(b, 0.5)
			_fade_out(b, 0.02)
		&"door_slam":  # a steel door far too heavy: the mass, a dull ring, the frame rattling
			b = _buf(0.7)
			_tone(b, 0.0, 0.45, 75.0, 26.0, 1.0, Wave.SINE, 0.001, 5.0)           # the mass
			_noise(b, rng, 0.0, 0.1, 0.7, 0.45, 0.05, 0.001, 5.0)                 # impact
			_tone(b, 0.0, 0.5, 385.0, 380.0, 0.16, Wave.SINE, 0.001, 5.0)         # ring (inharmonic)
			_tone(b, 0.0, 0.45, 612.0, 605.0, 0.1, Wave.SINE, 0.001, 6.0)
			_tone(b, 0.0, 0.35, 947.0, 940.0, 0.06, Wave.SINE, 0.001, 7.0)
			for t: float in [0.07, 0.12, 0.19]:                                    # the frame
				_noise(b, rng, t, 0.025, 0.25, 0.4, 0.1, 0.001, 5.0)
				_tone(b, t, 0.03, 160.0, 120.0, 0.2, Wave.TRIANGLE, 0.001, 6.0)
			_lowpass(b, 0.3)
			_fade_out(b, 0.03)
		&"confiscate":  # snatched out of your hands: cloth, the snatch, a short falling tone
			b = _buf(0.32)
			_noise(b, rng, 0.0, 0.12, 0.55, 0.4, 0.08, 0.004, 4.0)                # cloth
			_noise(b, rng, 0.03, 0.05, 0.3, 0.7, 0.3, 0.002, 5.0)                 # the snatch
			_tone(b, 0.04, 0.24, 520.0, 170.0, 0.6, Wave.SINE, 0.004, 4.0)        # falling
			_tone(b, 0.04, 0.2, 1040.0, 340.0, 0.12, Wave.SINE, 0.004, 5.0)
			_lowpass(b, 0.45)
			_fade_out(b, 0.02)
		&"hum":    # 60 Hz mains with harmonics and a slow 3 Hz beat; whole cycles over 1.0 s = seamless
			b = _buf(1.0)
			_cycles(b, 60, 0.6, 3, 0.12)
			_cycles(b, 120, 0.42, 3, 0.2)
			_cycles(b, 180, 0.12, 5, 0.3)
			_cycles(b, 240, 0.06, 5, 0.3)
			_cycles(b, 300, 0.025)
		&"rat":    # two thin squeaks, the second trailing down
			b = _buf(0.26)
			_tone(b, 0.0, 0.07, 3100.0, 3700.0, 0.6, Wave.SINE, 0.003, 3.0, 60.0, 0.02)
			_tone(b, 0.12, 0.1, 3500.0, 2700.0, 0.5, Wave.SINE, 0.003, 3.5, 55.0, 0.02)
			_tone(b, 0.12, 0.06, 1750.0, 1350.0, 0.1, Wave.SINE, 0.003, 4.0)
			_fade_out(b, 0.02)
		# --- M12 hostile --- (placeholder recipes for the hostile plant; the audio pass refines them)
		&"hostile_rise":  # roots tearing out of the soil: a low rumble, three creaks, a wet pop at the end
			b = _buf(0.9)
			_noise(b, rng, 0.0, 0.6, 0.5, 0.15, 0.02, 0.05, 3.0)                  # soil
			for t: float in [0.1, 0.3, 0.5]:                                       # roots creaking
				_tone(b, t, 0.14, 190.0, 120.0, 0.35, Wave.TRIANGLE, 0.004, 5.0, 28.0, 0.08)
			_tone(b, 0.58, 0.16, 140.0, 55.0, 0.8, Wave.SINE, 0.002, 5.0)         # the pop
			_noise(b, rng, 0.58, 0.05, 0.3, 0.4, 0.1, 0.001, 6.0)
			_lowpass(b, 0.35)
			_fade_out(b, 0.03)
		&"hostile_bite":  # a wet snap: the clack of the mouth and a dull thud, no sting
			b = _buf(0.3)
			_noise(b, rng, 0.0, 0.03, 0.6, 0.8, 0.3, 0.0005, 7.0)                # snap
			_tone(b, 0.0, 0.04, 900.0, 480.0, 0.3, Wave.TRIANGLE, 0.001, 6.0)     # clack
			_tone(b, 0.02, 0.2, 150.0, 60.0, 0.9, Wave.SINE, 0.002, 5.0)          # thud
			_noise(b, rng, 0.03, 0.12, 0.2, 0.3, 0.05, 0.004, 4.0)                # wet
			_lowpass(b, 0.5)
			_fade_out(b, 0.02)
		&"hostile_eat":   # chewing: two soft chomps per 0.6 s loop, decayed to silence before the join
			b = _buf(0.6)
			for t: float in [0.0, 0.3]:
				_noise(b, rng, t, 0.1, 0.45, 0.35, 0.1, 0.004, 5.0)
				_tone(b, t, 0.11, 115.0, 70.0, 0.6, Wave.SINE, 0.003, 5.0)
				_noise(b, rng, t + 0.09, 0.07, 0.2, 0.25, 0.04, 0.004, 4.0)
			_lowpass(b, 0.4)
			_fade_in(b, 0.004)
			_fade_out(b, 0.04)
		&"hostile_die":   # a wheeze going down, then a dry crackle as it folds
			b = _buf(0.8)
			_noise(b, rng, 0.0, 0.45, 0.45, 0.3, 0.05, 0.02, 3.5)                 # the wheeze
			_tone(b, 0.0, 0.5, 260.0, 90.0, 0.5, Wave.TRIANGLE, 0.01, 4.0, 9.0, 0.05)
			for t: float in [0.48, 0.55, 0.61, 0.7]:                               # dry crackle
				_noise(b, rng, t, 0.02, 0.35, 0.7, 0.3, 0.0005, 7.0)
			_tone(b, 0.5, 0.25, 90.0, 40.0, 0.5, Wave.SINE, 0.004, 5.0)           # it folds
			_lowpass(b, 0.45)
			_fade_out(b, 0.03)
		# --- M12 disrupt: the head count, the water main, the supply shortage (dull, low; nobody cheers) -------
		&"headcount":  # two dry pen clicks on the clipboard, then one flat low note held a moment: line up
			b = _buf(0.9)
			_noise(b, rng, 0.0, 0.02, 0.5, 0.8, 0.3, 0.0005, 7.0)
			_tone(b, 0.0, 0.03, 2400.0, 1800.0, 0.25, Wave.SINE, 0.0005, 8.0)
			_noise(b, rng, 0.16, 0.02, 0.5, 0.8, 0.3, 0.0005, 7.0)
			_tone(b, 0.16, 0.03, 2400.0, 1800.0, 0.25, Wave.SINE, 0.0005, 8.0)
			_tone(b, 0.4, 0.45, 196.0, 196.0, 0.4, Wave.SQUARE, 0.02, 1.5)
			_tone(b, 0.4, 0.45, 98.0, 98.0, 0.2, Wave.SAW, 0.02, 1.5)
			_lowpass(b, 0.3)
			_fade_out(b, 0.03)
		&"water_off":  # a valve squealing shut, two knocks down the pipe, the trickle dying
			b = _buf(1.2)
			_tone(b, 0.0, 0.35, 900.0, 1400.0, 0.3, Wave.SAW, 0.02, 2.0, 30.0, 0.03)
			_noise(b, rng, 0.0, 0.35, 0.2, 0.5, 0.2, 0.02, 2.0)
			_noise(b, rng, 0.45, 0.03, 0.7, 0.4, 0.05, 0.001, 6.0)
			_tone(b, 0.45, 0.12, 140.0, 90.0, 0.5, Wave.SINE, 0.001, 5.0)
			_noise(b, rng, 0.68, 0.03, 0.6, 0.4, 0.05, 0.001, 6.0)
			_tone(b, 0.68, 0.12, 120.0, 80.0, 0.45, Wave.SINE, 0.001, 5.0)
			_noise(b, rng, 0.8, 0.4, 0.25, 0.3, 0.1, 0.01, 2.5)
			_lowpass(b, 0.35)
			_fade_out(b, 0.05)
		&"shortage":  # a rubber stamp coming down on the order, then two notes stepping down: no
			b = _buf(0.7)
			_noise(b, rng, 0.0, 0.04, 0.8, 0.6, 0.1, 0.001, 5.0)
			_tone(b, 0.0, 0.1, 160.0, 110.0, 0.6, Wave.SINE, 0.001, 4.0)
			_tone(b, 0.22, 0.18, 330.0, 330.0, 0.4, Wave.SQUARE, 0.01, 2.5)
			_tone(b, 0.42, 0.26, 247.0, 247.0, 0.4, Wave.SQUARE, 0.01, 2.5)
			_lowpass(b, 0.3)
			_fade_out(b, 0.03)
		# --- end M12 disrupt --------------------------------------------------------------------------------
		_:
			b = _buf(0.1)
			_tone(b, 0.0, 0.08, 600.0, 600.0, 0.5, Wave.SINE, 0.002, 4.0)
	var wav := _to_wav(b)
	if sound in LOOPING:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = b.size()
	return wav

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

## Adds a sine that completes exactly `cycles` periods over the whole buffer (so a FORWARD loop over the buffer
## is seamless), optionally amplitude-modulated by `am_cycles` whole periods at `am_depth`. No attack, no fade.
func _cycles(b: PackedFloat32Array, cycles: int, amp: float, am_cycles: int = 0, am_depth: float = 0.0) -> void:
	var n := b.size()
	if n == 0 or cycles <= 0:
		return
	var k := TAU * cycles / n
	var ka := TAU * am_cycles / n
	for i in n:
		var a := amp
		if am_cycles > 0:
			a *= 1.0 + am_depth * sin(ka * i)
		b[i] += a * sin(k * i)

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

## Linear fade over the first `seconds` of the buffer (loops that must start at zero).
func _fade_in(b: PackedFloat32Array, seconds: float) -> void:
	var n := mini(int(seconds * MIX_RATE), b.size())
	for i in n:
		b[i] *= float(i) / n

## Linear fade over the last `seconds` of the buffer: whatever the layers left there ends at zero (no click).
func _fade_out(b: PackedFloat32Array, seconds: float) -> void:
	var n := mini(int(seconds * MIX_RATE), b.size())
	var last := b.size() - 1
	for i in n:
		b[last - i] *= float(i) / n

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
