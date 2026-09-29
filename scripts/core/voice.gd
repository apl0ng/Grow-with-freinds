extends Node
## Autoload "Voice": proximity voice chat (PLAN.md M10, voice agent). Do NOT add a class_name (autoload).
##
## The surface (signals, vars, the public funcs) is the contract in CONTRACTS.md "Voice"; the HUD reads the
## speaking marks, the pause menu the settings, nothing else calls in here.
##
##   Capture   Only with a real window (never headless), `audio/driver/enable_input` on, `enabled` true and no
##             `--no-mic` user arg: an AudioStreamMicrophone plays on a muted runtime bus "Mic" that carries an
##             AudioEffectCapture (0.25 s). _process drains it: stereo -> mono, mix rate -> 16 kHz (linear
##             interpolation with a fractional accumulator, continuous across chunks), 20 ms frames of 320
##             samples, `input_gain`, an RMS level for `input_level_changed` (at most ~20 Hz).
##   Codec     G.711 mu-law, 8 bit per sample: encode_mulaw / decode_mulaw (static). A frame is 320 bytes.
##   Send      Push-to-talk: `push_to_talk` action held (works under a UI lock, except while the chat box holds
##             the lock `&"chat"`: typing never transmits). Open mic: an energy gate with 300 ms hang time.
##             Needs Net.is_online(), the local peer registered and at least one other registered peer.
##   Transport @rpc("any_peer", "call_remote", "unreliable") _rpc_voice(seq, frame) sent with rpc(): the server
##             relays it to every other peer. Receivers drop: sender not in Net.players, frame empty or over
##             400 bytes, more than 60 frames per second from one peer, and reordered / duplicate frames
##             (16-bit seq with wraparound; a peer silent for over a second resyncs on its next frame).
##   Playback  Per remote peer one AudioStreamPlayer3D + AudioStreamGenerator (16 kHz, 0.15 s) under
##             Game.world/VoiceOut/<peer>, moved to the speaker's head (Player position + 1.6 m, 1.05 m
##             crouched) every frame, on a runtime bus "Voice" (volume = `output_volume_db`). Inverse-distance
##             attenuation, unit_size = voice_range / 2, max_distance = voice_range. Jitter buffer: playback
##             starts once two frames are queued; an underrun pads one frame of silence and re-arms. A seq
##             gap of up to 3 frames (ENet drops unreliable packets when the RTT jitters) is concealed with
##             fading copies of the last frame so the stream keeps time.
##   Back room get_route(listener_in_backroom, speaker_in_backroom): &"3d" (floor to floor), &"full" (both in
##             the back room: no attenuation, emitter at the listener), &"faint" (listener in the back room,
##             speaker on the floor: 3D at -14 dB), &"mute" (listener on the floor, speaker in the back room:
##             not heard, frames discarded). GameState.is_in_backroom decides.
##   Speaking  A remote peer speaks while a frame arrived in the last 250 ms; the local peer while transmitting.
##             speaking_changed fires on transitions only; a departed peer stops at once.
##   Settings  user://voice.cfg (`settings_path`): enabled, push_to_talk, output_volume_db, input_gain. Loaded
##             in _ready, saved whenever a setter changes a value. load_settings() resets to the defaults first.
##   Headless  is_mic_available() is false, nothing is captured, no errors are printed; the receive path,
##             playback nodes and speaking state fully work (the Dummy audio driver still mixes).
##
## Test hooks (tools/tests/voice_test.gd, voice_mp_*.gd):
##   debug_inject_frame(peer_id, frame, seq := -1)  runs the receive path as if `peer_id` had sent it
##                                                   (seq -1 = the next number after the last injected one)
##   debug_send_frame(frame)                         sends one frame through the real send path (no mic needed)
##   get_stats() -> {sent, received, played, lost, concealed, dropped: {reason: count}, peers}
##   get_output_node(peer_id) -> AudioStreamPlayer3D or null

## Every peer: `peer_id` started / stopped being heard (remote) or transmitting (local).
signal speaking_changed(peer_id: int, speaking: bool)
## Local mic level 0..1 for a meter (emitted at most ~20 times per second while capturing).
signal input_level_changed(level: float)

## Sample rate of the transported audio (Hz) and the frame length (20 ms).
const SAMPLE_RATE: int = 16000
const FRAME_SAMPLES: int = 320
const FRAME_MS: int = 20
## Receive limits (per sender).
const MAX_FRAME_BYTES: int = 400
const MAX_FRAMES_PER_SEC: int = 60
## A remote peer keeps "speaking" this long after its last frame.
const SPEAK_HOLD_MS: int = 250
## After this much silence from a peer, any seq is accepted again (sender restarted / long pause).
const SEQ_RESYNC_MS: int = 1000
const SEQ_MODULO: int = 65536
## Open mic: RMS (after gain) that opens the gate, and how long it stays open after the last loud frame.
const OPEN_MIC_THRESHOLD: float = 0.02
const OPEN_MIC_HANG_MS: int = 300
## Jitter buffer: frames queued before playback starts; frames kept at most (older ones are dropped).
const JITTER_START_FRAMES: int = 2
const JITTER_MAX_FRAMES: int = 25
## A seq gap of up to this many frames is filled with fading copies of the last frame (packet loss concealment).
const MAX_CONCEAL_FRAMES: int = 3
## The back room hears the floor at this level.
const FAINT_DB: float = -14.0
const MIC_BUS: StringName = &"Mic"
const VOICE_BUS: StringName = &"Voice"
const OUT_ROOT_NAME: StringName = &"VoiceOut"
const ROUTE_3D: StringName = &"3d"
const ROUTE_FULL: StringName = &"full"
const ROUTE_FAINT: StringName = &"faint"
const ROUTE_MUTE: StringName = &"mute"
const HEAD_STANDING: float = 1.6
const HEAD_CROUCHED: float = 1.05
const MULAW_BIAS: int = 0x84
const MULAW_CLIP: int = 32635

## Master switch for capturing the local microphone (settings).
var enabled: bool = true:
	set = _set_enabled
## true = hold `push_to_talk` to transmit; false = open mic with an energy gate.
var push_to_talk: bool = true:
	set = _set_push_to_talk
## Volume of every remote voice (dB, applied to the Voice bus).
var output_volume_db: float = 0.0:
	set = _set_output_volume_db
## Multiplier on the captured signal before encoding.
var input_gain: float = 1.0:
	set = _set_input_gain
## True while the local microphone is being sent.
var transmitting: bool = false
## Where the settings live (tests point this at a scratch file before touching the setters).
var settings_path: String = "user://voice.cfg"

# --- capture ---
var _mic_possible: bool = false
var _capture: AudioEffectCapture = null
var _mic_player: AudioStreamPlayer = null
var _downsampler: Downsampler = null
var _pending: PackedFloat32Array = PackedFloat32Array()
var _input_level: float = 0.0
var _level_peak: float = 0.0            # highest level since the last input_level_changed
var _last_level_emit_ms: int = 0
var _gate_open_until_ms: int = 0
var _send_seq: int = 0
# --- receive ---
var _last_seq: Dictionary = {}          # peer -> last accepted seq
var _last_heard_ms: Dictionary = {}     # peer -> ticks of the last accepted frame
var _rate_window_ms: Dictionary = {}    # peer -> start of the current 1 s window
var _rate_count: Dictionary = {}        # peer -> frames accepted in that window
var _speaking: Dictionary = {}          # peer -> true while speaking (remote heard or local transmitting)
var _debug_seq: Dictionary = {}         # peer -> last seq used by debug_inject_frame
# --- playback ---
var _out_root: Node3D = null
var _outputs: Dictionary = {}           # peer -> Output
# --- stats / settings ---
var _stats_sent: int = 0
var _stats_received: int = 0
var _stats_played: int = 0
var _stats_lost: int = 0                # frames a seq gap says never arrived
var _stats_concealed: int = 0           # filler frames queued for them
var _stats_dropped: Dictionary = {}
var _loading_settings: bool = false
var _save_warned: bool = false


## Linear-interpolating downsampler with a fractional accumulator: chunks of any size come out continuous.
class Downsampler:
	var ratio: float = 1.0      # input samples per output sample
	var _frac: float = 0.0      # position of the next output sample, in input samples, relative to _prev
	var _prev: float = 0.0      # last input sample of the previous chunk
	var _primed: bool = false

	func _init(in_rate: float, out_rate: float) -> void:
		ratio = maxf(in_rate, 1.0) / maxf(out_rate, 1.0)

	func reset() -> void:
		_frac = 0.0
		_prev = 0.0
		_primed = false

	## Feeds `input` (mono) and returns the output samples it produces.
	func process(input: PackedFloat32Array) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		var n := input.size()
		if n == 0:
			return out
		if not _primed:
			_prev = input[0]
			_primed = true
		# Virtual stream: index 0 = _prev, index k (1..n) = input[k - 1].
		var t := _frac
		while true:
			var i := int(floor(t))
			if i + 1 > n:
				break
			var f := t - float(i)
			var a := _prev if i == 0 else input[i - 1]
			var b := input[i]
			out.append(a + (b - a) * f)
			t += ratio
		_frac = t - float(n)
		_prev = input[n - 1]
		return out


## Playback state of one remote peer.
class Output:
	var peer_id: int = 0
	var player: AudioStreamPlayer3D = null
	var playback: AudioStreamGeneratorPlayback = null
	var capacity: int = 0                   # generator ring buffer size in frames (learnt after play())
	var queue: Array[PackedVector2Array] = []
	var last_frame: PackedVector2Array = PackedVector2Array()   # last decoded frame (concealment source)
	var primed: bool = false
	var route: StringName = &""
	var last_pos: Vector3 = Vector3.ZERO
	var has_pos: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_voice_bus()
	load_settings()
	_mic_possible = _detect_mic()
	Game.world_ready.connect(_on_world_ready)
	Net.players_changed.connect(_on_players_changed)
	_refresh_capture()

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	_process_capture(now)
	_process_outputs()
	_expire_speaking(now)

# --- Public API (contract) --------------------------------------------------------------------------------------

## True while `peer_id` is heard on this peer (or, for the local id, while transmitting).
func is_speaking(peer_id: int) -> bool:
	return _speaking.has(peer_id)

func is_transmitting() -> bool:
	return transmitting

## Last measured local input level 0..1.
func get_input_level() -> float:
	return _input_level

## True when a microphone could be opened on this machine (false headless / no input device).
func is_mic_available() -> bool:
	return _mic_possible

## Peers currently heard, sorted.
func get_speaking_peers() -> Array[int]:
	var out: Array[int] = []
	for k in _speaking.keys():
		out.append(int(k))
	out.sort()
	return out

# --- Public additions -------------------------------------------------------------------------------------------

## Listener L on this peer, speaker S: how S is heard. See the header.
static func get_route(listener_in_backroom: bool, speaker_in_backroom: bool) -> StringName:
	if listener_in_backroom and speaker_in_backroom:
		return ROUTE_FULL
	if listener_in_backroom:
		return ROUTE_FAINT
	if speaker_in_backroom:
		return ROUTE_MUTE
	return ROUTE_3D

## G.711 mu-law: one byte per sample (samples clamped to [-1, 1]).
static func encode_mulaw(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	var n := samples.size()
	out.resize(n)
	for i in n:
		var s := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		var sign := 0
		if s < 0:
			s = -s
			sign = 0x80
		if s > MULAW_CLIP:
			s = MULAW_CLIP
		s += MULAW_BIAS
		var exponent := 7
		var mask := 0x4000
		while exponent > 0 and (s & mask) == 0:
			exponent -= 1
			mask >>= 1
		var mantissa := (s >> (exponent + 3)) & 0x0F
		out[i] = (~(sign | (exponent << 4) | mantissa)) & 0xFF
	return out

## G.711 mu-law: bytes back to samples in [-1, 1].
static func decode_mulaw(bytes: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := bytes.size()
	out.resize(n)
	for i in n:
		out[i] = _decode_mulaw_byte(bytes[i])
	return out

static func _decode_mulaw_byte(b: int) -> float:
	var u := (~b) & 0xFF
	var sign := u & 0x80
	var exponent := (u >> 4) & 0x07
	var mantissa := u & 0x0F
	var sample := (((mantissa << 3) + MULAW_BIAS) << exponent) - MULAW_BIAS
	if sign != 0:
		sample = -sample
	return float(sample) / 32768.0

## Reads the settings file (`settings_path`); values missing from it fall back to the defaults.
func load_settings() -> void:
	_loading_settings = true
	enabled = true
	push_to_talk = Config.balance.voice_push_to_talk
	output_volume_db = 0.0
	input_gain = 1.0
	var cfg := ConfigFile.new()
	if cfg.load(settings_path) == OK:
		enabled = bool(cfg.get_value("voice", "enabled", enabled))
		push_to_talk = bool(cfg.get_value("voice", "push_to_talk", push_to_talk))
		output_volume_db = float(cfg.get_value("voice", "output_volume_db", output_volume_db))
		input_gain = float(cfg.get_value("voice", "input_gain", input_gain))
	_loading_settings = false
	_apply_output_volume()
	_refresh_capture()

## Writes the settings file. Returns the ConfigFile error.
func save_settings() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("voice", "enabled", enabled)
	cfg.set_value("voice", "push_to_talk", push_to_talk)
	cfg.set_value("voice", "output_volume_db", output_volume_db)
	cfg.set_value("voice", "input_gain", input_gain)
	var err := cfg.save(settings_path)
	if err != OK and not _save_warned:
		_save_warned = true
		push_warning("Voice: could not save %s (%s)" % [settings_path, error_string(err)])
	return err

## Frames sent / received / played, frames lost on the way (seq gaps) and concealed, dropped per reason.
func get_stats() -> Dictionary:
	return {
		"sent": _stats_sent,
		"received": _stats_received,
		"played": _stats_played,
		"lost": _stats_lost,
		"concealed": _stats_concealed,
		"dropped": _stats_dropped.duplicate(),
		"peers": _outputs.size(),
	}

## The playback node of `peer_id` (null when none exists).
func get_output_node(peer_id: int) -> AudioStreamPlayer3D:
	var o: Output = _outputs.get(peer_id)
	if o == null or not is_instance_valid(o.player):
		return null
	return o.player

## Test hook: the receive path, as if `peer_id` had sent `frame`. seq -1 continues that peer's injected numbering.
func debug_inject_frame(peer_id: int, frame: PackedByteArray, seq: int = -1) -> void:
	if seq < 0:
		seq = (int(_debug_seq.get(peer_id, -1)) + 1) % SEQ_MODULO
	_debug_seq[peer_id] = seq
	_receive(peer_id, seq, frame, Time.get_ticks_msec())

## Test hook: one frame through the real send path (no microphone involved).
func debug_send_frame(frame: PackedByteArray) -> void:
	_send_frame(frame)

# --- Settings setters -------------------------------------------------------------------------------------------

func _set_enabled(value: bool) -> void:
	var changed := enabled != value
	enabled = value
	if changed:
		_refresh_capture()
		_settings_changed()

func _set_push_to_talk(value: bool) -> void:
	var changed := push_to_talk != value
	push_to_talk = value
	if changed:
		_gate_open_until_ms = 0
		_settings_changed()

func _set_output_volume_db(value: float) -> void:
	value = clampf(value, -60.0, 12.0)
	var changed := not is_equal_approx(output_volume_db, value)
	output_volume_db = value
	_apply_output_volume()
	if changed:
		_settings_changed()

func _set_input_gain(value: float) -> void:
	value = clampf(value, 0.0, 4.0)
	var changed := not is_equal_approx(input_gain, value)
	input_gain = value
	if changed:
		_settings_changed()

func _settings_changed() -> void:
	if _loading_settings or not is_node_ready():
		return
	save_settings()

# --- Buses ------------------------------------------------------------------------------------------------------

func _ensure_voice_bus() -> void:
	if AudioServer.get_bus_index(VOICE_BUS) == -1:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, VOICE_BUS)
		AudioServer.set_bus_send(idx, &"Master")
	_apply_output_volume()

func _apply_output_volume() -> void:
	var idx := AudioServer.get_bus_index(VOICE_BUS)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, output_volume_db)

# --- Capture ----------------------------------------------------------------------------------------------------

## A microphone can be used: a real window, audio input enabled in the project, an input device, no --no-mic.
func _detect_mic() -> bool:
	if DisplayServer.get_name() == "headless" or OS.has_feature("headless"):
		return false
	if not bool(ProjectSettings.get_setting("audio/driver/enable_input", false)):
		return false
	if Config.has_arg("no-mic"):
		return false
	return AudioServer.get_input_device_list().size() > 0

## Starts or stops the microphone according to `enabled` and the machine.
func _refresh_capture() -> void:
	if not is_node_ready():
		return
	var want := enabled and _mic_possible
	if want and _capture == null:
		_start_capture()
	elif not want and _capture != null:
		_stop_capture()

func _start_capture() -> void:
	var idx := AudioServer.get_bus_index(MIC_BUS)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, MIC_BUS)
		AudioServer.set_bus_send(idx, &"Master")
	AudioServer.set_bus_mute(idx, true)
	var effect: AudioEffectCapture = null
	for i in AudioServer.get_bus_effect_count(idx):
		var e := AudioServer.get_bus_effect(idx, i) as AudioEffectCapture
		if e != null:
			effect = e
			break
	if effect == null:
		effect = AudioEffectCapture.new()
		effect.buffer_length = 0.25
		AudioServer.add_bus_effect(idx, effect)
	_capture = effect
	_capture.clear_buffer()
	_downsampler = Downsampler.new(AudioServer.get_mix_rate(), float(SAMPLE_RATE))
	_pending = PackedFloat32Array()
	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "MicIn"
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = MIC_BUS
	add_child(_mic_player)
	_mic_player.play()

func _stop_capture() -> void:
	if _mic_player != null and is_instance_valid(_mic_player):
		_mic_player.stop()
		_mic_player.queue_free()
	_mic_player = null
	_capture = null
	_downsampler = null
	_pending = PackedFloat32Array()
	_set_input_level(0.0, Time.get_ticks_msec(), true)
	_set_transmitting(false)

func _process_capture(now: int) -> void:
	if _capture == null:
		if transmitting:
			_set_transmitting(false)
		return
	var available := _capture.get_frames_available()
	if available > 0:
		var stereo := _capture.get_buffer(available)
		var mono := PackedFloat32Array()
		mono.resize(stereo.size())
		for i in stereo.size():
			var v := stereo[i]
			mono[i] = (v.x + v.y) * 0.5
		_pending.append_array(_downsampler.process(mono))
	var can_send := _can_transmit()
	var ptt_want := can_send and push_to_talk and _ptt_held()
	while _pending.size() >= FRAME_SAMPLES:
		var frame := _pending.slice(0, FRAME_SAMPLES)
		_pending = _pending.slice(FRAME_SAMPLES)
		var energy := 0.0
		for i in FRAME_SAMPLES:
			var s := clampf(frame[i] * input_gain, -1.0, 1.0)
			frame[i] = s
			energy += s * s
		var rms := sqrt(energy / float(FRAME_SAMPLES))
		_set_input_level(clampf(rms * 4.0, 0.0, 1.0), now, false)
		if can_send and not push_to_talk and rms >= OPEN_MIC_THRESHOLD:
			_gate_open_until_ms = now + OPEN_MIC_HANG_MS
		var send := ptt_want if push_to_talk else (can_send and now < _gate_open_until_ms)
		if send:
			_send_frame(encode_mulaw(frame))
	_set_transmitting(ptt_want if push_to_talk else (can_send and now < _gate_open_until_ms))
	# Guard against an ever-growing backlog when the capture delivers faster than frames are cut.
	if _pending.size() > FRAME_SAMPLES * 25:
		_pending = _pending.slice(_pending.size() - FRAME_SAMPLES * 5)

func _can_transmit() -> bool:
	if not enabled or _capture == null or not Net.is_online():
		return false
	var my_id := multiplayer.get_unique_id()
	return Net.players.has(my_id) and Net.players.size() > 1

## The talk key counts while any UI is up, except the chat line: typing never transmits.
func _ptt_held() -> bool:
	if Game.is_ui_locked_by(&"chat"):
		return false
	return Input.is_action_pressed(&"push_to_talk")

## Stores the level and emits the peak since the last emit, at most every 50 ms (force: right away).
func _set_input_level(level: float, now: int, force: bool) -> void:
	_input_level = level
	_level_peak = maxf(_level_peak, level)
	if force or now - _last_level_emit_ms >= 50:
		_last_level_emit_ms = now
		var peak := level if force else _level_peak
		_level_peak = 0.0
		input_level_changed.emit(peak)

func _set_transmitting(value: bool) -> void:
	if transmitting == value:
		return
	transmitting = value
	_refresh_speaking(multiplayer.get_unique_id(), Time.get_ticks_msec())

func _send_frame(frame: PackedByteArray) -> void:
	if frame.is_empty() or not Net.is_online():
		return
	_send_seq = (_send_seq + 1) % SEQ_MODULO
	_stats_sent += 1
	_rpc_voice.rpc(_send_seq, frame)

# --- Transport --------------------------------------------------------------------------------------------------

## Any peer -> everyone else (server relay). Validated per sender on every receiver.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(seq: int, frame: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	_receive(sender, seq, frame, Time.get_ticks_msec())

func _receive(sender: int, seq: int, frame: PackedByteArray, now: int) -> void:
	if not Net.players.has(sender):
		_drop("not_player")
		return
	if frame.is_empty():
		_drop("empty")
		return
	if frame.size() > MAX_FRAME_BYTES:
		_drop("too_big")
		return
	# Rate: at most MAX_FRAMES_PER_SEC accepted per 1 s window per sender.
	var window_start := int(_rate_window_ms.get(sender, -SEQ_RESYNC_MS))
	if now - window_start >= 1000:
		_rate_window_ms[sender] = now
		_rate_count[sender] = 0
	if int(_rate_count[sender]) >= MAX_FRAMES_PER_SEC:
		_drop("rate")
		return
	# Order: 16-bit sequence with wraparound; older or duplicate frames are ignored, a gap means loss.
	seq = seq % SEQ_MODULO
	if seq < 0:
		seq += SEQ_MODULO
	var gap := 0
	if _last_seq.has(sender) and now - int(_last_heard_ms.get(sender, 0)) < SEQ_RESYNC_MS:
		var diff := (seq - int(_last_seq[sender])) % SEQ_MODULO
		if diff < 0:
			diff += SEQ_MODULO
		if diff == 0 or diff > SEQ_MODULO / 2:
			_drop("reorder")
			return
		gap = diff - 1
	_last_seq[sender] = seq
	_last_heard_ms[sender] = now
	_rate_count[sender] = int(_rate_count[sender]) + 1
	_stats_received += 1
	_stats_lost += gap
	_refresh_speaking(sender, now)
	_queue_playback(sender, frame, gap)

func _drop(reason: String) -> void:
	_stats_dropped[reason] = int(_stats_dropped.get(reason, 0)) + 1

# --- Speaking state ---------------------------------------------------------------------------------------------

func _refresh_speaking(peer_id: int, now: int) -> void:
	var heard := _last_heard_ms.has(peer_id) and now - int(_last_heard_ms[peer_id]) < SPEAK_HOLD_MS
	var local := peer_id == multiplayer.get_unique_id() and transmitting
	var speaking := heard or local
	if speaking == _speaking.has(peer_id):
		return
	if speaking:
		_speaking[peer_id] = true
	else:
		_speaking.erase(peer_id)
	speaking_changed.emit(peer_id, speaking)

func _expire_speaking(now: int) -> void:
	if _speaking.is_empty():
		return
	for k in _speaking.keys():
		_refresh_speaking(int(k), now)

# --- Playback ---------------------------------------------------------------------------------------------------

func _on_world_ready(_world: Node) -> void:
	_clear_outputs()
	_ensure_out_root()

func _on_players_changed() -> void:
	var now := Time.get_ticks_msec()
	if Net.players.is_empty() or not Net.is_online():
		_clear_peer_state()
		return
	for k in _last_heard_ms.keys().duplicate():
		if not Net.players.has(k):
			_forget_peer(int(k), now)
	for k in _outputs.keys().duplicate():
		if not Net.players.has(k):
			_forget_peer(int(k), now)
	if not Net.players.has(multiplayer.get_unique_id()):
		_set_transmitting(false)

## A peer left: no more speaking mark, no more emitter, fresh seq / rate state.
func _forget_peer(peer_id: int, now: int) -> void:
	_last_heard_ms.erase(peer_id)
	_last_seq.erase(peer_id)
	_rate_window_ms.erase(peer_id)
	_rate_count.erase(peer_id)
	_debug_seq.erase(peer_id)
	var o: Output = _outputs.get(peer_id)
	if o != null:
		_outputs.erase(peer_id)
		_release_output(o)
	_refresh_speaking(peer_id, now)

## Stops and frees an emitter, letting go of its generator playback first.
func _release_output(o: Output) -> void:
	o.playback = null
	o.queue.clear()
	if is_instance_valid(o.player) and not o.player.is_queued_for_deletion():
		if o.player.is_inside_tree():
			o.player.stop()
		o.player.queue_free()
	o.player = null

## Offline / back in the menu: everything goes.
func _clear_peer_state() -> void:
	var now := Time.get_ticks_msec()
	_set_transmitting(false)
	_last_heard_ms.clear()
	_last_seq.clear()
	_rate_window_ms.clear()
	_rate_count.clear()
	_debug_seq.clear()
	_gate_open_until_ms = 0
	_clear_outputs()
	for k in _speaking.keys().duplicate():
		_last_heard_ms.erase(k)
		_refresh_speaking(int(k), now)

func _clear_outputs() -> void:
	for k in _outputs.keys():
		_release_output(_outputs[k])
	_outputs.clear()
	if _out_root != null and is_instance_valid(_out_root):
		if _out_root.tree_exiting.is_connected(_on_out_root_exiting):
			_out_root.tree_exiting.disconnect(_on_out_root_exiting)
		if not _out_root.is_queued_for_deletion():
			_out_root.queue_free()
	_out_root = null

## The VoiceOut node under the current world (null when there is no world).
func _ensure_out_root() -> Node3D:
	var world: Node = Game.world
	if world == null or not is_instance_valid(world) or not world.is_inside_tree():
		return null
	if _out_root != null and is_instance_valid(_out_root) and _out_root.get_parent() == world \
			and not _out_root.is_queued_for_deletion():
		return _out_root
	_clear_outputs()
	var existing := world.get_node_or_null(NodePath(OUT_ROOT_NAME))
	if existing is Node3D:
		_out_root = existing
	else:
		_out_root = Node3D.new()
		_out_root.name = OUT_ROOT_NAME
		world.add_child(_out_root)
	_out_root.tree_exiting.connect(_on_out_root_exiting)
	return _out_root

## The world is going away: its children (our emitters) go with it.
func _on_out_root_exiting() -> void:
	for k in _outputs.keys():
		var o: Output = _outputs[k]
		o.playback = null
		o.queue.clear()
		o.player = null
	_outputs.clear()
	_out_root = null

func _ensure_output(peer_id: int) -> Output:
	var o: Output = _outputs.get(peer_id)
	if o != null and is_instance_valid(o.player) and o.player.is_inside_tree():
		return o
	var root := _ensure_out_root()
	if root == null:
		return null
	if o != null:
		_outputs.erase(peer_id)
	o = Output.new()
	o.peer_id = peer_id
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(SAMPLE_RATE)
	gen.buffer_length = 0.15
	var p := AudioStreamPlayer3D.new()
	p.name = str(peer_id)
	p.stream = gen
	p.bus = VOICE_BUS
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = maxf(Config.balance.voice_range * 0.5, 0.1)
	p.max_distance = Config.balance.voice_range
	p.max_db = 0.0
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	root.add_child(p)
	p.play()
	o.player = p
	o.playback = p.get_stream_playback() as AudioStreamGeneratorPlayback
	if o.playback != null:
		o.capacity = o.playback.get_frames_available()
	_outputs[peer_id] = o
	_apply_route(o, _route_for(peer_id))
	_update_position(o)
	return o

## Decodes `frame` into the peer's jitter queue; `gap` frames before it never arrived and are concealed.
func _queue_playback(peer_id: int, frame: PackedByteArray, gap: int = 0) -> void:
	var o := _ensure_output(peer_id)
	if o == null:
		_drop("no_world")
		return
	var route := _route_for(peer_id)
	if route != o.route:
		_apply_route(o, route)
	if route == ROUTE_MUTE:
		o.queue.clear()
		o.primed = false
		o.last_frame = PackedVector2Array()
		_drop("mute")
		return
	if gap > 0 and gap <= MAX_CONCEAL_FRAMES and o.last_frame.size() == FRAME_SAMPLES:
		var level := 0.5
		for g in gap:
			var fill := PackedVector2Array()
			fill.resize(FRAME_SAMPLES)
			for i in FRAME_SAMPLES:
				fill[i] = o.last_frame[i] * level
			o.queue.append(fill)
			_stats_concealed += 1
			level *= 0.5
	var mono := decode_mulaw(frame)
	var stereo := PackedVector2Array()
	stereo.resize(mono.size())
	for i in mono.size():
		stereo[i] = Vector2(mono[i], mono[i])
	o.queue.append(stereo)
	o.last_frame = stereo if stereo.size() == FRAME_SAMPLES else PackedVector2Array()
	while o.queue.size() > JITTER_MAX_FRAMES:
		o.queue.pop_front()
		_drop("queue_full")

func _process_outputs() -> void:
	if _outputs.is_empty():
		return
	for k in _outputs.keys().duplicate():
		var o: Output = _outputs[k]
		if not is_instance_valid(o.player) or not o.player.is_inside_tree():
			_outputs.erase(k)
			continue
		var route := _route_for(o.peer_id)
		if route != o.route:
			_apply_route(o, route)
		_update_position(o)
		_pump(o)

## Jitter buffer -> generator. Starts after JITTER_START_FRAMES are queued; an underrun pads silence and re-arms.
func _pump(o: Output) -> void:
	if o.playback == null:
		if is_instance_valid(o.player) and o.player.playing:
			o.playback = o.player.get_stream_playback() as AudioStreamGeneratorPlayback
			if o.playback != null:
				o.capacity = o.playback.get_frames_available()
		if o.playback == null:
			return
	if not o.primed:
		if o.queue.size() < JITTER_START_FRAMES:
			return
		o.primed = true
	while not o.queue.is_empty():
		var frame: PackedVector2Array = o.queue[0]
		if o.playback.get_frames_available() < frame.size():
			break
		o.queue.pop_front()
		o.playback.push_buffer(frame)
		_stats_played += 1
	if o.queue.is_empty() and o.capacity > 0 and o.playback.get_frames_available() >= o.capacity - FRAME_SAMPLES:
		# Ran dry: one frame of silence, then wait for the buffer to build up again.
		var silence := PackedVector2Array()
		silence.resize(FRAME_SAMPLES)
		o.playback.push_buffer(silence)
		o.primed = false

func _route_for(speaker: int) -> StringName:
	var listener := multiplayer.get_unique_id()
	return get_route(GameState.is_in_backroom(listener), GameState.is_in_backroom(speaker))

func _apply_route(o: Output, route: StringName) -> void:
	o.route = route
	if not is_instance_valid(o.player):
		return
	var range_m := Config.balance.voice_range
	match route:
		ROUTE_FULL:
			o.player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
			o.player.max_distance = 0.0
			o.player.volume_db = 0.0
		ROUTE_FAINT:
			o.player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			o.player.max_distance = range_m
			o.player.volume_db = FAINT_DB
		_:
			o.player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			o.player.max_distance = range_m
			o.player.volume_db = 0.0
	if route == ROUTE_MUTE:
		o.queue.clear()
		o.primed = false

## Emitter at the speaker's head (last known spot when its Player is gone); at the listener for ROUTE_FULL.
func _update_position(o: Output) -> void:
	if not is_instance_valid(o.player) or not o.player.is_inside_tree():
		return
	var pos: Vector3
	var found := false
	if o.route == ROUTE_FULL:
		pos = _listener_position()
		found = true
	else:
		var p: Node3D = Game.get_player(o.peer_id)
		if p != null and is_instance_valid(p) and p.is_inside_tree():
			pos = _head_of(p)
			found = true
	if found:
		o.last_pos = pos
		o.has_pos = true
	if o.has_pos:
		o.player.global_position = o.last_pos

## A worker's mouth: the Player node plus the standing / crouched camera height.
func _head_of(p: Node3D) -> Vector3:
	var c: Variant = p.get("crouching")
	var crouched: bool = c is bool and c
	return p.global_position + Vector3.UP * (HEAD_CROUCHED if crouched else HEAD_STANDING)

## Where this peer listens from: the current camera (spectating counts), else its own head.
func _listener_position() -> Vector3:
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null and is_instance_valid(cam) and cam.is_inside_tree():
			return cam.global_position
	var me: Node3D = Game.local_player
	if me != null and is_instance_valid(me) and me.is_inside_tree():
		return _head_of(me)
	return Vector3.ZERO
