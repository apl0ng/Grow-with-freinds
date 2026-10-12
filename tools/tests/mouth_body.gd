extends "res://tools/tests/qa_base.gd"
## M25 mouth suite (mouth agent): a remote worker's mouth moves with their voice, on a single headless host with fake
## workers (Bob talks, Carl never does, Dave's body spawns while he talks: host-side bodies without an owning peer whose
## voice frames go straight into Voice's receive path through Voice.debug_inject_frame). Frames are sine waves of a
## known amplitude (RMS = amplitude / sqrt 2), streamed on Voice's 20 ms clock by a background loop (late frames come
## in a burst, as they do off the network).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/mouth_body.gd --port=9422
##       --round-sec=900 --timeout=200
## Pins:
##   loudness   Voice.mouth_level_of: silence, an empty frame and a frame under MOUTH_RMS_FLOOR give 0; MOUTH_RMS_FULL
##              and louder give 1; in between sqrt((rms - floor) / (full - floor)), strictly rising with the amplitude;
##              its cost per frame
##   level      Voice.get_level: 0 for an unknown peer, a worker who never spoke and my own id; a frame sets it at once
##              (attack); a quieter frame lowers it by FRAME_MS / MOUTH_RELEASE_MS at most; after the last frame it
##              holds MOUTH_HOLD_MS and falls to 0 over MOUTH_RELEASE_MS; a steady voice holds a steady level between
##              frames; it follows three loudnesses; a worker who left reads 0 at once; a worker in the back room heard
##              from the floor (the muted route) reads 0
##   the face   three loudnesses open Bob's mouth in proportion (the frown segments part by TALK_PART x the opening, the
##              dark MouthOpen grows, wider than tall, hanging from the apex); silence shuts it within about 0.2 s and
##              the face stops drawing it once Voice stops hearing him; the segments' frown never changes (never a smile)
##   moods      sad / tired / grim / neutral pose the segments exactly as before with the mouth shut and while it moves;
##              an animated mood change during talk lands; a blink and a surprise during talk play and the talk goes on
##   silent     Carl never talks: his face never draws its mouth (no _talk_process call), nothing parted, nothing shown
##   my body    frames from my own id give Voice a level, but my body (only its shadow is seen) has no talking face and
##              never moves its mouth
##   late join  Dave talks before his body exists: it starts talking at once
##   cheap      a thousand mouth frames and a thousand get_level calls create no Object
## Every engine/script error fails the run unless announced (qa_base.gd).

const VoiceScript := preload("res://scripts/core/voice.gd")
const BOB := 2
const CARL := 3
const DAVE := 4
const ME_AT := Vector3(-3.0, 0.0, 3.0)
const BOB_AT := Vector3(-3.0, 0.0, 1.0)
const CARL_AT := Vector3(-1.6, 0.0, 1.4)
const DAVE_AT := Vector3(-4.4, 0.0, 1.4)
## Amplitudes of the test voices (RMS = amplitude / sqrt 2): quiet, ordinary, loud (over MOUTH_RMS_FULL).
const AMP_LO := 0.04
const AMP_MID := 0.12
const AMP_HI := 0.5

var world: World
var me: Player
var bob: Player
var carl: Player
var bob_face: ToonFace
var carl_face: ToonFace
var my_face: ToonFace

var _talk_peer: int = 0
var _talk_amp: float = 0.0
var _talk_t0: int = 0
var _talk_sent: int = 0
var _talk_last_ms: int = 0
var _talk_loop_on: bool = false
var _frames: Dictionary = {}        # amplitude -> one mu-law frame


func _run() -> void:
	_label = "mouth"
	await get_tree().process_frame
	_test_loudness()
	if not await _host():
		finish(); return
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "the shift runs")
	await wait_sec(0.5) # the shift start puts everybody on their spawn: let it settle before placing anybody
	_place()
	await wait_frames(3)
	_test_shut_at_rest()
	await _test_envelope()
	await wait_sec(1.1) # a fresh one-second rate window for Bob before he streams
	await _test_face_follows()
	await _test_silence_closes()
	await _test_moods_talking()
	_test_moods_shut()
	await _test_my_body()
	await _test_backroom()
	await _test_late_join()
	_test_cheap()
	_test_carl_silent()
	_talk(0, 0.0)
	finish()


# --- loudness ----------------------------------------------------------------------------------------------------------

func _test_loudness() -> void:
	step("Voice.mouth_level_of: the loudness of a frame")
	var floor_rms := VoiceScript.MOUTH_RMS_FLOOR
	var full_rms := VoiceScript.MOUTH_RMS_FULL
	check(VoiceScript.mouth_level_of(_frame(0.0)) == 0.0 and VoiceScript.mouth_level_of(PackedByteArray()) == 0.0, "silence and an empty frame: 0")
	check(VoiceScript.mouth_level_of(_frame(floor_rms)) == 0.0, "under the floor (RMS %.3f < %.3f): 0" % [floor_rms / sqrt(2.0), floor_rms])
	check(is_equal_approx(VoiceScript.mouth_level_of(_frame(full_rms * sqrt(2.0) * 1.02)), 1.0) and VoiceScript.mouth_level_of(_frame(0.95)) == 1.0,
			"at MOUTH_RMS_FULL (%.2f) and louder: 1" % full_rms)
	var last := -1.0
	var rising := true
	var worst := 0.0
	var text := PackedStringArray()
	for amp: float in [0.02, 0.04, 0.08, 0.12, 0.18, 0.24]:
		var got := VoiceScript.mouth_level_of(_frame(amp))
		var rms := amp / sqrt(2.0)
		var want := sqrt(clampf((rms - floor_rms) / (full_rms - floor_rms), 0.0, 1.0))
		worst = maxf(worst, absf(got - want))
		rising = rising and got > last
		last = got
		text.append("%.2f->%.2f" % [amp, got])
	check(rising, "strictly rising with the amplitude (%s)" % ", ".join(text))
	check(worst < 0.03, "sqrt((rms - floor) / (full - floor)) within 0.03 (worst %.3f; mu-law steps)" % worst)
	var f := _frame(AMP_MID)
	var t0 := Time.get_ticks_usec()
	for i in 2000:
		VoiceScript.mouth_level_of(f)
	var us := float(Time.get_ticks_usec() - t0) / 2000.0
	check(us < 150.0, "cost: %.1f us a frame (every %d-th sample; 50 frames a second per talking worker)" % [us, VoiceScript.MOUTH_STRIDE])


# --- setup -------------------------------------------------------------------------------------------------------------

func _host() -> bool:
	step("hosting")
	Game.start_host("Tester", port_arg(9422))
	if not await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player"):
		return false
	world = Game.world
	me = Game.local_player
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	Net.players[CARL] = {"name": "Carl", "color": Net.PALETTE[CARL - 1]}
	bob = world.server_spawn_player(BOB)
	carl = world.server_spawn_player(CARL)
	Net.players_changed.emit()
	await wait_frames(3)
	if not check(bob != null and carl != null and world.get_players().size() == 3, "host + Bob + Carl"):
		return false
	bob_face = bob.get_node_or_null(^"Visual/Face/ToonFace") as ToonFace
	carl_face = carl.get_node_or_null(^"Visual/Face/ToonFace") as ToonFace
	my_face = me.get_node_or_null(^"Visual/Face/ToonFace") as ToonFace
	return check(bob_face != null and carl_face != null and my_face != null and bob.get_talking_face() == bob_face
			and carl.get_talking_face() == carl_face, "every body has its ToonFace; Bob's and Carl's are their talking faces")


func _place() -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(ME_AT.x, 0.02, ME_AT.z)
	me.rotation = Vector3.ZERO
	for pair: Array in [[bob, BOB_AT], [carl, CARL_AT]]:
		var p: Player = pair[0]
		var at: Vector3 = pair[1]
		p.place_at(Transform3D(Basis(Vector3.UP, PI), Vector3(at.x, 0.05, at.z)))


func _test_shut_at_rest() -> void:
	step("at rest: every mouth shut, nothing drawn")
	for face: ToonFace in [bob_face, carl_face, my_face]:
		check(_shut(face) and not face.is_talking() and face.get_talk_updates() == 0, "%s: shut, not drawn" % face.get_parent().get_parent().get_parent().name)
	var hole := _hole(bob_face)
	check(hole != null and hole.get_parent().name == &"Mouth" and hole.material_override == _part(bob_face, "MouthL").material_override
			and hole.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "MouthOpen under Mouth, the segments' ink, no shadow")
	check(_part(bob_face, "MouthL").get_parent() == _part(bob_face, "MouthPartL") and _part(bob_face, "MouthR").get_parent() == _part(bob_face, "MouthPartR"),
			"MouthL / MouthR ride the pivots MouthPartL / MouthPartR")
	check(Voice.get_level(99) == 0.0 and Voice.get_level(BOB) == 0.0 and Voice.get_level(CARL) == 0.0 and Voice.get_level(1) == 0.0,
			"get_level: 0 for an unknown peer, workers who never spoke and my own id")


# --- the level ---------------------------------------------------------------------------------------------------------

func _test_envelope() -> void:
	step("get_level: attack, release per frame, hold and fall")
	var mid := VoiceScript.mouth_level_of(_frame(AMP_MID))
	var hi := VoiceScript.mouth_level_of(_frame(AMP_HI))
	var lo := VoiceScript.mouth_level_of(_frame(AMP_LO))
	Voice.debug_inject_frame(BOB, _frame(AMP_MID))
	check(is_equal_approx(Voice.get_level(BOB), mid), "the first frame sets it at once (%.3f = the frame's %.3f)" % [Voice.get_level(BOB), mid])
	Voice.debug_inject_frame(BOB, _frame(AMP_HI))
	check(is_equal_approx(Voice.get_level(BOB), hi), "a louder frame: at once (%.3f)" % Voice.get_level(BOB))
	var step_down := float(VoiceScript.FRAME_MS) / float(VoiceScript.MOUTH_RELEASE_MS)
	Voice.debug_inject_frame(BOB, _frame(AMP_LO))
	var after_one := Voice.get_level(BOB)
	check(absf(after_one - maxf(lo, hi - step_down)) < 0.002, "a quieter frame: down by FRAME_MS / RELEASE at most (%.3f -> %.3f)" % [hi, after_one])
	for i in 9:
		Voice.debug_inject_frame(BOB, _frame(AMP_LO))
	check(absf(Voice.get_level(BOB) - lo) < 0.002, "ten quiet frames later: the quiet level (%.3f)" % Voice.get_level(BOB))
	Voice.debug_inject_frame(BOB, _frame(AMP_HI))
	var t0: int = int(Voice._mouth_ms[BOB])
	var e: float = Voice._mouth_env[BOB]
	var hold := VoiceScript.MOUTH_HOLD_MS
	var rel := VoiceScript.MOUTH_RELEASE_MS
	check(is_equal_approx(e, 1.0), "a loud frame: 1")
	check(Voice._mouth_at(BOB, t0 + hold) == 1.0 and Voice._mouth_at(BOB, t0 + 20) == 1.0, "it holds %d ms after the last frame" % hold)
	check(absf(Voice._mouth_at(BOB, t0 + hold + rel / 2) - 0.5) < 0.001, "half way down %d ms later" % (rel / 2))
	check(Voice._mouth_at(BOB, t0 + hold + rel) == 0.0 and Voice._mouth_at(BOB, t0 + 5000) == 0.0, "0 at %d ms (and after)" % (hold + rel))
	# Real time: the level reaches 0 about hold + release after the last frame.
	var start := Time.get_ticks_msec()
	var held := true
	while Voice.get_level(BOB) > 0.0 and Time.get_ticks_msec() - start < 1000:
		if Time.get_ticks_msec() - t0 < hold - 5 and Voice.get_level(BOB) < 1.0:
			held = false
		await get_tree().process_frame
	var zero_at := Time.get_ticks_msec() - t0
	check(held and zero_at >= hold + rel - 20 and zero_at <= hold + rel + 60, "in real time: held, then 0 after %d ms (want ~%d)" % [zero_at, hold + rel])


func _test_face_follows() -> void:
	step("three loudnesses open Bob's mouth in proportion")
	var openings: Array[float] = []
	var levels: Array[float] = []
	for amp: float in [AMP_LO, AMP_MID, AMP_HI]:
		_talk(BOB, amp)
		await wait_sec(0.25)
		var lv_min := INF
		var lv_max := -INF
		var sum_open := 0.0
		var sum_lv := 0.0
		var n := 0
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 150:
			await get_tree().process_frame
			var lv := Voice.get_level(BOB)
			lv_min = minf(lv_min, lv)
			lv_max = maxf(lv_max, lv)
			sum_lv += lv
			sum_open += bob_face.get_talk_opening()
			n += 1
		var want := VoiceScript.mouth_level_of(_frame(amp))
		var mean_lv := sum_lv / float(maxi(n, 1))
		var mean_open := sum_open / float(maxi(n, 1))
		openings.append(mean_open)
		levels.append(mean_lv)
		check(absf(mean_lv - want) < 0.03 and lv_max - lv_min < 0.2, "amplitude %.2f: a steady level %.3f (the frame's %.3f; %.3f..%.3f over %d frames)" % [amp, mean_lv, want, lv_min, lv_max, n])
		check(absf(mean_open - mean_lv) < 0.05, "the face follows it: opening %.3f" % mean_open)
		var o := bob_face.get_talk_opening()
		var hole := _hole(bob_face)
		var pl := _part(bob_face, "MouthPartL")
		var pr := _part(bob_face, "MouthPartR")
		check(bob_face.is_talking() and hole.visible and absf(pl.position.x + ToonFace.TALK_PART * o) < 1e-5 and absf(pr.position.x - ToonFace.TALK_PART * o) < 1e-5
				and pl.position.y == 0.0 and pr.position.y == 0.0, "the segments part by TALK_PART x %.2f (%.4f m each), the opening shows" % [o, pr.position.x])
		var half_h := ToonFace.TALK_OPEN_H * o
		check(absf(hole.scale.y - half_h * 2.0) < 1e-5 and hole.scale.x > hole.scale.y and absf(hole.position.y - (ToonFace.TALK_OPEN_TOP - half_h)) < 1e-5,
				"the opening %.3f wide, %.3f tall, hanging from the apex" % [hole.scale.x, hole.scale.y])
		check(pl.rotation == Vector3.ZERO and pr.rotation == Vector3.ZERO and _segments_match(bob_face, bob_face.mood), "the frown itself is the mood's (never a smile)")
	check(openings[0] < openings[1] and openings[1] < openings[2] and openings[2] > 0.95, "louder opens wider: %.2f < %.2f < %.2f" % [openings[0], openings[1], openings[2]])
	check(absf(openings[0] / openings[2] - levels[0] / levels[2]) < 0.06 and absf(openings[1] / openings[2] - levels[1] / levels[2]) < 0.06,
			"in proportion to the level (%.2f / %.2f of the loud one, the level's %.2f / %.2f)" % [openings[0] / openings[2], openings[1] / openings[2], levels[0] / levels[2], levels[1] / levels[2]])
	check(carl_face.get_talk_updates() == 0 and not carl_face.is_talking() and _shut(carl_face), "Carl (silent) next to him: never drawn, shut")


func _test_silence_closes() -> void:
	step("silence: shut within about 0.2 s, then the face stops drawing")
	_talk(BOB, AMP_HI)
	await wait_sec(0.3)
	check(bob_face.get_talk_opening() > 0.95, "loud: open (%.2f)" % bob_face.get_talk_opening())
	_talk(BOB, 0.0)
	var last := _talk_last_ms
	await wait_until(func() -> bool: return _shut(bob_face), 1.0, "Bob's mouth shuts")
	var shut_ms := Time.get_ticks_msec() - last
	check(shut_ms <= 260, "shut %d ms after his last frame (the hold %d ms + the release %d ms)" % [shut_ms, VoiceScript.MOUTH_HOLD_MS, VoiceScript.MOUTH_RELEASE_MS])
	check(not _hole(bob_face).visible and _part(bob_face, "MouthPartL").position == Vector3.ZERO and _part(bob_face, "MouthPartR").position == Vector3.ZERO,
			"the opening hidden, the segments home")
	await wait_until(func() -> bool: return not bob_face.is_talking(), 1.0, "the face stops drawing once Voice stops hearing him")
	check(not Voice.is_speaking(BOB), "(Voice: Bob is silent)")
	var n := bob_face.get_talk_updates()
	await wait_sec(0.3)
	check(bob_face.get_talk_updates() == n and n > 0, "nothing drawn while he is silent (%d frames drawn while he talked)" % n)


# --- moods -------------------------------------------------------------------------------------------------------------

func _test_moods_talking() -> void:
	step("moods, blink and surprise while Bob talks")
	_talk(BOB, AMP_MID)
	await wait_sec(0.25)
	for m: StringName in [&"tired", &"grim", &"neutral", &"sad"]:
		bob_face.set_mood(m, true)
		await wait_frames(2)
		check(bob_face.mood == m and _segments_match(bob_face, m) and _parted(bob_face), "%s while talking: the mood's frown, still parted (%.2f)" % [m, bob_face.get_talk_opening()])
	bob_face.set_mood(&"grim")
	await wait_sec(0.35)
	check(_segments_match(bob_face, &"grim") and _parted(bob_face), "an animated change to grim lands while the mouth moves")
	var eye := _part(bob_face, "EyeL")
	var rest_y := eye.scale.y
	# No blink of its own for a while: one landing inside the surprise would kill the surprise's way back to the mood
	# (ToonFace: blink() and surprise() share one tween; nothing in the game calls surprise(), so it never shows in play).
	bob_face.set(&"_next_blink", 30.0)
	bob_face.blink()
	var lowest := rest_y
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 250:
		await get_tree().process_frame
		lowest = minf(lowest, eye.scale.y)
	check(lowest < rest_y * 0.3 and _parted(bob_face), "a blink plays (eye %.2f of its height at the lowest), the talk goes on" % (lowest / rest_y))
	bob_face.surprise()
	await wait_sec(0.2)
	check(bob_face.mood == &"grim" and _parted(bob_face), "a surprise: the mood is kept, the talk goes on")
	await wait_sec(0.75)
	check(_segments_match(bob_face, &"grim") and _parted(bob_face), "after it: the grim frown again")
	bob_face.set(&"_next_blink", 3.0) # its own blinks again
	bob_face.set_mood(&"sad", true)
	_talk(BOB, 0.0)
	await wait_until(func() -> bool: return not bob_face.is_talking(), 1.5, "silence again: Bob's face stops drawing")


func _test_moods_shut() -> void:
	step("moods with the mouth shut")
	for m: StringName in [&"tired", &"grim", &"neutral", &"sad"]:
		bob_face.set_mood(m, true)
		check(_segments_match(bob_face, m) and _shut(bob_face), "%s: the mood's frown, shut" % m)
	carl_face.set_mood(&"grim", true)
	check(_segments_match(carl_face, &"grim") and _shut(carl_face) and carl_face.get_talk_updates() == 0, "Carl's grim: posed, never drawn")
	carl_face.set_mood(&"sad", true)


# --- my body, the back room, the late join ------------------------------------------------------------------------------

func _test_my_body() -> void:
	step("my own body never moves its mouth")
	check(me.get_talking_face() == null, "no talking face on my body")
	_talk(1, AMP_HI)
	await wait_sec(0.3)
	check(Voice.get_level(1) > 0.9 and Voice.is_speaking(1), "frames from my own id give Voice a level (%.2f)" % Voice.get_level(1))
	check(my_face.get_talk_updates() == 0 and not my_face.is_talking() and _shut(my_face), "my face: never drawn, shut")
	check(bob_face.get_talk_opening() == 0.0 and carl_face.get_talk_opening() == 0.0, "nobody else's mouth moves for my voice")
	_talk(0, 0.0)
	await wait_sec(0.4)


func _test_backroom() -> void:
	step("Bob in the back room, heard from the floor: not heard, mouth shut")
	if not check(GameState.server_send_to_backroom(BOB, 30.0) and GameState.is_in_backroom(BOB), "Bob is sent to the back room"):
		return
	await wait_frames(2)
	_talk(BOB, AMP_HI)
	var most := 0.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		await get_tree().process_frame
		most = maxf(most, maxf(Voice.get_level(BOB), bob_face.get_talk_opening()))
	check(Voice.is_speaking(BOB) and most == 0.0 and _shut(bob_face), "the muted route decodes nothing: level and mouth stay at 0 (talk mark aside)")
	_talk(0, 0.0)
	GameState.server_release_from_backroom(BOB)
	await wait_sec(0.4)
	_place()
	await wait_frames(2)


func _test_late_join() -> void:
	step("a worker whose body spawns while he talks")
	Net.players[DAVE] = {"name": "Dave", "color": Net.PALETTE[DAVE - 1]}
	Net.players_changed.emit()
	_talk(DAVE, AMP_HI)
	await wait_sec(0.1)
	check(Voice.is_speaking(DAVE) and Voice.get_level(DAVE) == 0.0, "Voice hears Dave before his body exists (no body: nothing decoded yet)")
	var dave := world.server_spawn_player(DAVE)
	await wait_frames(1)
	if not check(dave != null and dave.get_talking_face() != null, "his body spawns with a talking face"):
		_talk(0, 0.0)
		return
	dave.place_at(Transform3D(Basis(Vector3.UP, PI), Vector3(DAVE_AT.x, 0.05, DAVE_AT.z)))
	var face := dave.get_talking_face()
	check(face.is_talking(), "it starts talking at once")
	await wait_sec(0.3)
	check(face.get_talk_opening() > 0.9 and _hole(face).visible, "and opens with his voice (%.2f)" % face.get_talk_opening())
	step("a worker who leaves")
	_talk(0, 0.0)
	check(Voice.get_level(DAVE) > 0.9, "(Dave's level before he goes: %.2f)" % Voice.get_level(DAVE))
	world.server_despawn_player(DAVE) # what Net does for a departed peer: the body, then the registry
	Net.players.erase(DAVE)
	Net.players_changed.emit()
	check(Voice.get_level(DAVE) == 0.0, "get_level: 0 at once")
	await wait_frames(2)


# --- cost, Carl ----------------------------------------------------------------------------------------------------------

func _test_cheap() -> void:
	step("cheap: nothing allocated")
	var f := _frame(AMP_MID)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var t0 := Time.get_ticks_usec()
	for i in 1000:
		Voice._mouth_frame(BOB, f)
	var frame_us := float(Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var lv := 0.0
	for i in 1000:
		lv += Voice.get_level(BOB)
	var get_us := float(Time.get_ticks_usec() - t0) / 1000.0
	bob_face.set_talk_source(Voice.get_level.bind(BOB))
	t0 = Time.get_ticks_usec()
	for i in 1000:
		bob_face._talk_process(0.016)
	var face_us := float(Time.get_ticks_usec() - t0) / 1000.0
	bob_face.stop_talking()
	check(Performance.get_monitor(Performance.OBJECT_COUNT) == objects, "no Object created by 1000 mouth frames, get_level calls and face updates")
	check(frame_us < 150.0 and get_us < 20.0 and face_us < 40.0, "a frame's level %.1f us, get_level %.2f us, a face update %.2f us" % [frame_us, get_us, face_us])
	bob_face.pose_talk(0.0) # shut again at once (the face stops drawing on its next frame: no source)


func _test_carl_silent() -> void:
	step("Carl never talked: his face never ran the mouth")
	check(carl_face.get_talk_updates() == 0 and not carl_face.is_talking() and _shut(carl_face) and Voice.get_level(CARL) == 0.0,
			"no _talk_process call in the whole run, shut, level 0")


# --- helpers -----------------------------------------------------------------------------------------------------------

## Starts / changes / stops (amp 0) the background voice: frames of `amp` from `peer` on Voice's 20 ms clock.
func _talk(peer: int, amp: float) -> void:
	_talk_peer = peer
	_talk_amp = amp
	_talk_t0 = Time.get_ticks_msec()
	_talk_sent = 0
	if amp > 0.0 and not _talk_loop_on:
		_talk_loop()


func _talk_loop() -> void:
	_talk_loop_on = true
	while not _finished and _talk_amp > 0.0:
		var due := (Time.get_ticks_msec() - _talk_t0) / VoiceScript.FRAME_MS + 1
		while _talk_sent < due:
			Voice.debug_inject_frame(_talk_peer, _frame(_talk_amp))
			_talk_sent += 1
			_talk_last_ms = Time.get_ticks_msec()
		await get_tree().process_frame
	_talk_loop_on = false


## A 250 Hz sine of amplitude `amp`, as one mu-law frame (cached per amplitude).
func _frame(amp: float) -> PackedByteArray:
	if _frames.has(amp):
		return _frames[amp]
	var s := PackedFloat32Array()
	s.resize(VoiceScript.FRAME_SAMPLES)
	for i in VoiceScript.FRAME_SAMPLES:
		s[i] = amp * sin(TAU * 250.0 * float(i) / float(VoiceScript.SAMPLE_RATE))
	var f := VoiceScript.encode_mulaw(s)
	_frames[amp] = f
	return f


func _part(face: ToonFace, part_name: String) -> Node3D:
	return face.find_child(part_name, true, false) as Node3D


func _hole(face: ToonFace) -> MeshInstance3D:
	return _part(face, "MouthOpen") as MeshInstance3D


func _shut(face: ToonFace) -> bool:
	return face.get_talk_opening() == 0.0 and not _hole(face).visible and _part(face, "MouthPartL").position == Vector3.ZERO \
			and _part(face, "MouthPartR").position == Vector3.ZERO


func _parted(face: ToonFace) -> bool:
	var o := face.get_talk_opening()
	return o > 0.2 and _hole(face).visible and absf(_part(face, "MouthPartR").position.x - ToonFace.TALK_PART * o) < 1e-5


## MouthL / MouthR posed exactly as ToonFace._pose poses mood `m` (the segments' own transforms, under the pivots).
func _segments_match(face: ToonFace, m: StringName) -> bool:
	var d: Dictionary = ToonFace.MOODS[m]
	var a := deg_to_rad(float(d["mouth"]))
	var half := ToonFace.MOUTH_HALF * float(d["mouth_w"])
	var ok := true
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var seg := _part(face, "MouthL" if i == 0 else "MouthR")
		ok = ok and seg.position.distance_to(Vector3(side * half * cos(a), -half * sin(a), 0.0)) < 1e-4
		ok = ok and absf(seg.rotation.z - (deg_to_rad(90.0) - side * a)) < 1e-3 and absf(seg.scale.y - float(d["mouth_w"])) < 1e-4
	return ok
