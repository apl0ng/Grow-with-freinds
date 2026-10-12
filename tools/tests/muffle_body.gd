extends "res://tools/tests/qa_base.gd"
## M25 muffle suite (muffle agent): voices through walls, on a single headless host with fake workers (Bob and Carl:
## host-side bodies without an owning peer; their voice frames go straight into Voice's receive path through
## Voice.debug_inject_frame, 50 a second like a real talker). The listener is the host's camera. Replay on with a fixed
## card (--replay --run=B5VP), temp career and settings files.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/muffle_body.gd --port=9319
##       --replay --run=B5VP --career-file=user://muffle_test_9319.cfg --settings-file=user://muffle_settings_9319.cfg
##       --round-sec=900 --timeout=220
## Pins:
##   clear values   MUFFLE_CLEAR_HZ is AudioStreamPlayer3D's default cutoff, attenuation_filter_db is never touched,
##                  0 dB and max_db 0: a clear voice is the voice as it was
##   silence        nobody talking, nothing cast (before the first frame, and once a speaker falls silent)
##   in the open    Bob 4 m away on the open floor: clear (amount 0, the clear filter, 0 dB, max_db 0); the first
##                  rays cast; at most one ray per MUFFLE_CAST_MS per talking speaker (two speakers counted)
##   a wall         Bob in the grow hall, me in the pen, the wall between: muffled within MUFFLE_CAST_MS +
##                  MUFFLE_EASE_SEC (plus the frames), eased (values in between on the way, not a snap), then
##                  700 Hz, the filter depth untouched, -4 dB, max_db -4
##   a doorway      the same 3 m through the pen door: clear; Bob stepping from behind the wall into the doorway's
##                  line eases back to clear the same way
##   a talk spell   a speaker who starts talking behind a wall is muffled from his first frame (nothing plays yet)
##   the fence      the pen's chain-link fence is on the world layer (a bare ray stops on it) but a voice through it
##                  stays clear; so do the trays, crates and the van (excluded); walls are only the room's architecture
##   a newcomer     a world-layer body added later (a hostile plant, a rack): the ray stops on it once, goes again,
##                  ignores it from then on; the voice stays clear
##   a closed door  the booth door's leaf (solid either way): Bob inside the booth, me outside it: muffled
##   the roller     Bob outside the dock's chained roller door, me on the dock: muffled
##   radio          Bob behind the wall holding radio A: his proximity voice muffled, every RadioVoice output (radio B
##                  behind the wall, then next to me) keeps the radio's own values; nothing touches it
##   back room      Bob in the back room (mute), me too (full), me alone (faint, a wall between): each route's values
##                  exactly as before M25, the filter clear, no ray cast; released, the 3D route muffles again
##   the sound      measured on the Voice bus (an AudioEffectCapture, this suite only): a voice of three tones (300 Hz,
##                  1 kHz, 3 kHz) at 3 m through the doorway vs through the wall: the wall leaves 300 Hz a little
##                  quieter (-1.5 to -8 dB), takes 1 kHz down 12 dB or more and 3 kHz 18 dB or more
## Opt-in for a human: --muffle-wav=user://muffle_walk.wav also records a voice-like buzz off the Voice bus while Bob
## stands in the pen door's line, behind the wall, and in the line again (2 s each) into that WAV (see _record_walk).
## Every engine/script error fails the run unless announced (qa_base.gd).

const VoiceScript := preload("res://scripts/core/voice.gd")
const BOB := 2
const CARL := 3
const FRAME_MS := 20
# Room-local floor spots (Room-local == global while the room sits at the origin; converted anyway).
const OPEN_ME := Vector3(-3.0, 0.0, 3.0)
const OPEN_BOB := Vector3(-3.0, 0.0, -1.0)
const OPEN_CARL := Vector3(-5.0, 0.0, 0.0)
const DOOR_ME := Vector3(9.0, 0.0, -1.25)     # the pen's east aisle, facing the pen door
const DOOR_BOB := Vector3(12.0, 0.0, -1.25)   # the hall, through the pen door: 3 m, clear
const WALL_ME := Vector3(9.0, 0.0, 2.5)       # the pen, against the shared wall
const WALL_BOB := Vector3(12.0, 0.0, 2.5)     # the hall: 3 m, the wall between (EastShapeMid)
const FENCE_ME := Vector3(1.0, 0.0, 4.0)      # outside the pen's west fence
const FENCE_BOB := Vector3(4.0, 0.0, 4.0)     # inside it (Fence8 between)
const BOOTH_ME := Vector3(-3.5, 0.0, -6.9)    # west of the booth door
const BOOTH_BOB := Vector3(-1.2, 0.0, -6.9)   # inside the booth, behind its door
const DOCK_ME := Vector3(-2.5, 0.0, 14.0)     # on the dock, facing the roller door
const OUTSIDE_BOB := Vector3(-2.5, 0.0, 17.5) # outside it
const HALL_RADIO := Vector3(12.5, 0.0, 3.5)
const NEXT_TO_ME := Vector3(8.4, 0.0, 1.6)
const TONE_LOW := 300.0
const TONE_MID := 1000.0
const TONE_HIGH := 3000.0
## AudioStreamPlayer3D's default attenuation_filter_db: the muffle never touches it.
const FILTER_DB := -24.0

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var carl: Player
var _talkers: Array[int] = []
var _talk_t0: int = 0
var _talk_sent: Dictionary = {}   # peer -> frames injected this spell
var _cap: AudioEffectCapture = null
var _worst_frame_ms: int = 0
var _buzz: bool = false           # _frame makes the voice-like buzz of _record_walk instead of the three tones


func _run() -> void:
	_label = "muffle"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	_test_constants()
	if not await _host():
		finish(); return
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "the shift runs")
	await wait_sec(0.5) # the shift start puts everybody on their spawn: let it settle before placing anybody
	await wait_frames(3)
	await _test_silence()
	await _test_open()
	await _test_wall()
	await _test_doorway()
	await _test_spell()
	await _test_fence()
	await _test_newcomer()
	await _test_booth()
	await _test_roller()
	await _test_radio()
	await _test_backroom()
	await _test_sound()
	var wav_path := String(Config.get_arg("muffle-wav", ""))
	if not wav_path.is_empty():
		await _record_walk(wav_path)
	finish()


# --- setup ---------------------------------------------------------------------------------------------------------------

func _test_constants() -> void:
	step("the clear values are the voice as it was")
	var p := AudioStreamPlayer3D.new()
	check(is_equal_approx(p.attenuation_filter_cutoff_hz, VoiceScript.MUFFLE_CLEAR_HZ) and is_equal_approx(p.attenuation_filter_db, FILTER_DB),
			"AudioStreamPlayer3D's default filter: %.0f Hz (MUFFLE_CLEAR_HZ), %.0f dB (never changed)" % [p.attenuation_filter_cutoff_hz, p.attenuation_filter_db])
	p.free()
	check(VoiceScript.MUFFLE_CAST_MS <= 100 and VoiceScript.MUFFLE_EASE_SEC > 0.05 and VoiceScript.MUFFLE_EASE_SEC <= 0.2,
			"at most 10 rays a second per speaker (%d ms), eased over %.2f s" % [VoiceScript.MUFFLE_CAST_MS, VoiceScript.MUFFLE_EASE_SEC])
	check(VoiceScript.MUFFLE_HZ >= 500.0 and VoiceScript.MUFFLE_HZ <= 900.0 and VoiceScript.MUFFLE_DB < 0.0 and VoiceScript.MUFFLE_DB >= -6.0,
			"muffled: about 700 Hz (%.0f), a little quieter (%.0f dB)" % [VoiceScript.MUFFLE_HZ, VoiceScript.MUFFLE_DB])


func _host() -> bool:
	step("hosting")
	Game.start_host("Tester", port_arg(9319))
	if not await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player"):
		return false
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	Net.players[CARL] = {"name": "Carl", "color": Net.PALETTE[CARL - 1]}
	bob = world.server_spawn_player(BOB)
	carl = world.server_spawn_player(CARL)
	Net.players_changed.emit()
	await wait_frames(3)
	return check(bob != null and carl != null and world.get_players().size() == 3, "host + Bob + Carl")


# --- silence -------------------------------------------------------------------------------------------------------------

func _test_silence() -> void:
	step("silence casts nothing")
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	_put(carl, OPEN_CARL)
	await wait_sec(0.6)
	check(get_viewport().get_camera_3d() == me.camera, "the listener is my camera")
	check(_casts() == 0 and Voice.get_speaking_peers().is_empty(), "nobody has talked: no ray (%d)" % _casts())


# --- in the open ---------------------------------------------------------------------------------------------------------

func _test_open() -> void:
	step("in the open")
	_put_me(OPEN_ME)
	_put(bob, OPEN_BOB)
	await wait_physics(2)
	var c0 := _casts()
	_start_talk([BOB])
	await _talk_sec(0.5)
	var out := Voice.get_output_node(BOB)
	if not check(out != null and Voice.is_speaking(BOB), "Bob talks: his output exists"):
		return
	check(_casts() > c0, "rays cast while he talks (%d)" % (_casts() - c0))
	check(Voice.get_muffle_amount(BOB) == 0.0 and _is_clear(out), "4 m on the open floor: clear (%s)" % _describe(out))
	step("the ray rate")
	var c1 := _casts()
	var t1 := Time.get_ticks_msec()
	_talkers.append(CARL)
	_talk_sent[CARL] = int(_talk_sent.get(BOB, 0))
	await _talk_sec(1.0)
	var ms := Time.get_ticks_msec() - t1
	var limit := 2 * (ms / VoiceScript.MUFFLE_CAST_MS + 1)
	check(_casts() - c1 <= limit and _casts() - c1 >= 2, "two speakers for %d ms: %d rays (at most %d)" % [ms, _casts() - c1, limit])
	check(Voice.get_muffle_amount(CARL) == 0.0, "Carl in the open: clear")
	_stop_talk()
	await wait_sec(0.4)
	var c2 := _casts()
	await wait_sec(1.0)
	check(_casts() == c2 and not Voice.is_speaking(BOB) and not Voice.is_speaking(CARL), "both silent: no ray for a second (%d)" % (_casts() - c2))


# --- a wall --------------------------------------------------------------------------------------------------------------

func _test_wall() -> void:
	step("behind a wall")
	_put_me(DOOR_ME)
	_put(bob, DOOR_BOB)
	await wait_physics(2)
	_start_talk([BOB])
	await _talk_sec(0.4)
	var out := Voice.get_output_node(BOB)
	check(Voice.get_muffle_amount(BOB) == 0.0 and out != null and _is_clear(out), "through the pen door first: clear")
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	var r := await _watch_amount(1.0, 1.5)
	var bound := VoiceScript.MUFFLE_CAST_MS + int(VoiceScript.MUFFLE_EASE_SEC * 1000.0) + 3 * maxi(_worst_frame_ms, 17)
	check(bool(r["reached"]), "the wall between: muffled")
	check(int(r["ms"]) <= bound, "within %d ms (%d ms: one ray interval + the ease + frames)" % [bound, int(r["ms"])])
	# One frame's step is at most that frame's time / MUFFLE_EASE_SEC (a frame is capped at 0.1 s): never a snap.
	var step_cap := minf(float(_worst_frame_ms) / 1000.0, 0.1) / VoiceScript.MUFFLE_EASE_SEC + 0.02
	check(int(r["between"]) >= 1 and float(r["max_step"]) <= step_cap and float(r["max_step"]) < 0.99,
			"eased: %d frames between clear and muffled, the biggest step %.2f (at most %.2f)" % [int(r["between"]), float(r["max_step"]), step_cap])
	check(int(r["ease_ms"]) + _worst_frame_ms >= int(VoiceScript.MUFFLE_EASE_SEC * 1000.0),
			"the ease took %d ms (%.0f ms, give or take a frame of %d ms)" % [int(r["ease_ms"]), VoiceScript.MUFFLE_EASE_SEC * 1000.0, _worst_frame_ms])
	await _talk_sec(0.2)
	check(out != null and _is_muffled(out), "muffled values (%s)" % _describe(out))


func _test_doorway() -> void:
	step("through an open doorway")
	_put_me(DOOR_ME)
	_put(bob, WALL_BOB)
	await _talk_sec(0.4)
	check(Voice.get_muffle_amount(BOB) == 1.0, "from the pen door, Bob behind the wall beside it: still muffled")
	_put(bob, DOOR_BOB)
	var r := await _watch_amount(0.0, 1.5)
	var bound := VoiceScript.MUFFLE_CAST_MS + int(VoiceScript.MUFFLE_EASE_SEC * 1000.0) + 3 * maxi(_worst_frame_ms, 17)
	check(bool(r["reached"]) and int(r["ms"]) <= bound, "he steps into the doorway's line: clear again in %d ms (at most %d)" % [int(r["ms"]), bound])
	var step_cap := minf(float(_worst_frame_ms) / 1000.0, 0.1) / VoiceScript.MUFFLE_EASE_SEC + 0.02
	check(int(r["between"]) >= 1 and float(r["max_step"]) <= step_cap and float(r["max_step"]) < 0.99,
			"eased back: %d frames in between, the biggest step %.2f (at most %.2f)" % [int(r["between"]), float(r["max_step"]), step_cap])
	var out := Voice.get_output_node(BOB)
	check(out != null and _is_clear(out), "3 m through the doorway: the clear values (%s)" % _describe(out))
	_stop_talk()
	await wait_sec(0.5)


func _test_spell() -> void:
	step("a talk spell that starts behind a wall")
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	await wait_sec(0.3)
	check(not Voice.is_speaking(BOB) and Voice.get_muffle_amount(BOB) == 0.0, "silent behind the wall: nothing changed (no ray)")
	var played0 := int(Voice.get_stats()["played"])
	_start_talk([BOB])
	_drive()
	await get_tree().process_frame
	await get_tree().process_frame
	check(Voice.get_muffle_amount(BOB) == 1.0, "muffled from his first frame")
	check(int(Voice.get_stats()["played"]) - played0 <= 1, "before the jitter buffer played more than a frame")
	await _talk_sec(0.3)
	_stop_talk()
	await wait_sec(0.5)


# --- what counts as a wall -----------------------------------------------------------------------------------------------

func _test_fence() -> void:
	step("the pen's chain-link fence")
	_put_me(FENCE_ME)
	_put(bob, FENCE_BOB)
	await wait_physics(2)
	var hit := _bare_hit(_head(me), _head(bob))
	var fence := room.get_node_or_null(^"Decor/Fence8")
	check(hit != null and hit == fence, "a bare world-layer ray stops on the fence (%s)" % _name_of(hit))
	_start_talk([BOB])
	await _talk_sec(0.5)
	check(Voice.get_muffle_amount(BOB) == 0.0, "the voice through it: clear")
	var stats := Voice.get_muffle_stats()
	check(int(stats["walls"]) >= 5 and int(stats["excluded"]) >= 10, "walls are the architecture (%d bodies); %d world-layer bodies ignored" % [int(stats["walls"]), int(stats["excluded"])])
	var van := room.get_node_or_null(^"Dock/DockVan") as CollisionObject3D
	var plot := room.get_node_or_null(^"Stations/GrowPlot1")
	check(van != null and _excluded(van), "the van is ignored")
	check(plot != null and _excluded_under(plot), "a tray is ignored")
	_stop_talk()
	await wait_sec(0.5)


## A body that turns up on the world layer after the list was made (a hostile plant, a rack bought mid-run).
func _test_newcomer() -> void:
	step("a world-layer body that turns up later")
	_put_me(OPEN_ME)
	_put(bob, OPEN_BOB)
	var block := StaticBody3D.new()
	block.name = "MuffleTestBlock"
	block.collision_layer = Const.LAYER_WORLD
	block.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 3.0, 0.3)
	shape.shape = box
	block.add_child(shape)
	world.add_child(block)
	block.global_position = _g((OPEN_ME + OPEN_BOB) * 0.5 + Vector3(0.0, 1.5, 0.0))
	await wait_physics(3)
	check(_bare_hit(_head(me), _head(bob)) == block, "a bare ray stops on it")
	var s0 := Voice.get_muffle_stats()
	_start_talk([BOB])
	await _talk_sec(0.6)
	var s1 := Voice.get_muffle_stats()
	check(Voice.get_muffle_amount(BOB) == 0.0, "it is not a wall: clear")
	check(int(s1["recasts"]) - int(s0["recasts"]) == 1 and int(s1["excluded"]) - int(s0["excluded"]) == 1 and _excluded(block),
			"the first ray stopped on it once, went again, and it is ignored from then on")
	check(int(s1["casts"]) - int(s0["casts"]) >= 3, "later rays pass it (%d rays)" % (int(s1["casts"]) - int(s0["casts"])))
	_stop_talk()
	block.queue_free()
	await wait_sec(0.5)


func _test_booth() -> void:
	step("a closed door: the booth door")
	_put_me(BOOTH_ME)
	_put(bob, BOOTH_BOB)
	await wait_physics(3)
	var hit := _bare_hit(_head(me), _head(bob))
	var door := room.get_node_or_null(^"Decor/BackRoomDoor/Body")
	check(hit != null and hit == door, "the bare ray stops on the door's leaf (%s)" % _name_of(hit))
	check(not GameState.is_in_backroom(BOB), "Bob is in the booth, not in the back room: the 3D route")
	_start_talk([BOB])
	await _talk_sec(0.5)
	check(Voice.get_muffle_amount(BOB) == 1.0, "behind the closed door: muffled")
	_stop_talk()
	await wait_sec(0.5)


func _test_roller() -> void:
	step("the chained roller door")
	_put_me(DOCK_ME)
	_put(bob, OUTSIDE_BOB)
	await wait_physics(3)
	var hit := _bare_hit(_head(me), _head(bob))
	check(hit != null and hit == room.get_node_or_null(^"Walls"), "the bare ray stops on the dock's south wall (%s)" % _name_of(hit))
	_start_talk([BOB])
	await _talk_sec(0.5)
	check(Voice.get_muffle_amount(BOB) == 1.0, "outside the roller door: muffled")
	_stop_talk()
	await wait_sec(0.5)


# --- radio ---------------------------------------------------------------------------------------------------------------

func _test_radio() -> void:
	step("radio voices are never muffled")
	var radios: Array[Item] = items.get_items_of_type(Const.ITEM_RADIO)
	if not check(radios.size() >= 2, "two radios on the floor (%d)" % radios.size()):
		return
	var a := radios[0]
	var rb := radios[1]
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	check(items.server_give_item(a, BOB), "Bob holds radio A")
	items.server_drop_item(rb, _g(HALL_RADIO))
	await wait_frames(3)
	_start_talk([BOB])
	await _talk_sec(0.6)
	var ro := Voice.get_radio_output_node(BOB, rb)
	check(Voice.is_on_radio(BOB) and ro != null, "Bob is on the radio: radio B behind the wall plays him")
	check(Voice.get_muffle_amount(BOB) == 1.0, "his own voice through the wall: muffled")
	check(ro != null and _is_radio_clear(ro), "radio B's voice: the radio's own values (%s)" % _describe(ro))
	items.server_drop_item(rb, _g(NEXT_TO_ME))
	await _talk_sec(0.4)
	ro = Voice.get_radio_output_node(BOB, rb)
	check(ro != null and _is_radio_clear(ro), "radio B next to me: the same (%s)" % _describe(ro))
	var all_clear := true
	var n := 0
	for r: Item in items.get_items_of_type(Const.ITEM_RADIO):
		for c in r.get_children():
			if c is AudioStreamPlayer3D and String(c.name).begins_with("RadioVoice"):
				n += 1
				all_clear = all_clear and _is_radio_clear(c)
	check(n >= 1 and all_clear, "every RadioVoice output (%d) untouched" % n)
	_stop_talk()
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "the transmission ends")
	items.server_drop_item(a, _g(Vector3(-6.0, 0.0, 4.0)))
	items.server_drop_item(rb, _g(Vector3(-6.5, 0.0, 4.5)))
	await wait_frames(2)


# --- back room -----------------------------------------------------------------------------------------------------------

func _test_backroom() -> void:
	step("the back room keeps its routes")
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	_start_talk([BOB])
	await _talk_sec(0.5)
	var out := Voice.get_output_node(BOB)
	check(Voice.get_muffle_amount(BOB) == 1.0, "Bob behind the wall: muffled")
	check(GameState.server_send_to_backroom(BOB, 30.0), "Bob goes to the back room")
	for i in 2:
		_drive()
		await get_tree().process_frame
	check(Voice.get_muffle_amount(BOB) == 0.0 and out != null and _filter_clear(out), "mute route (him inside): the filter clear at once (two frames)")
	await _talk_sec(0.1)
	_put(bob, WALL_BOB)
	var c0 := _casts()
	await _talk_sec(0.5)
	check(Voice.get_muffle_amount(BOB) == 0.0 and out != null and _filter_clear(out), "and it stays clear")
	check(_casts() == c0, "no ray while he is in the back room (%d)" % (_casts() - c0))

	check(GameState.server_send_to_backroom(1, 30.0), "I go too")
	await _talk_sec(0.2)
	c0 = _casts()
	await _talk_sec(0.5)
	out = Voice.get_output_node(BOB)
	check(out != null and out.attenuation_model == AudioStreamPlayer3D.ATTENUATION_DISABLED and out.max_distance == 0.0
			and out.volume_db == 0.0 and _filter_clear(out), "full route (both inside): no attenuation, 0 dB, the filter clear")
	check(_casts() == c0, "no ray (%d)" % (_casts() - c0))

	GameState.server_release_from_backroom(BOB)
	await _talk_sec(0.1)
	_put(bob, WALL_BOB)
	c0 = _casts()
	await _talk_sec(0.5)
	check(Voice._route_for(BOB) == &"faint", "faint route (me inside, Bob on the floor behind the wall)")
	check(out != null and out.attenuation_model == AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			and is_equal_approx(out.volume_db, VoiceScript.FAINT_DB) and _filter_clear(out) and Voice.get_muffle_amount(BOB) == 0.0,
			"faint: %.0f dB as before, the filter clear (%s)" % [VoiceScript.FAINT_DB, _describe(out)])
	check(_casts() == c0, "no ray (%d)" % (_casts() - c0))

	GameState.server_release_from_backroom(1)
	await _talk_sec(0.1)
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	var r := await _watch_amount(1.0, 1.5)
	out = Voice.get_output_node(BOB)
	check(bool(r["reached"]) and out != null and _is_muffled(out), "both released: the 3D route, muffled again (%s)" % _describe(out))
	_stop_talk()
	await wait_sec(0.5)


# --- the sound itself ----------------------------------------------------------------------------------------------------

func _test_sound() -> void:
	step("the sound: a three-tone voice at 3 m, doorway vs wall, measured on the Voice bus")
	var idx := AudioServer.get_bus_index(&"Voice")
	if not check(idx != -1, "the Voice bus"):
		return
	_cap = AudioEffectCapture.new()
	_cap.buffer_length = 1.0
	AudioServer.add_bus_effect(idx, _cap)
	var fx := AudioServer.get_bus_effect_count(idx) - 1
	_put_me(DOOR_ME)
	_put(bob, DOOR_BOB)
	await wait_physics(2)
	_start_talk([BOB])
	await _talk_sec(0.6)
	var clear := await _measure(0.6)
	_put_me(WALL_ME)
	_put(bob, WALL_BOB)
	await _talk_sec(0.6)
	var muffled := await _measure(0.6)
	_stop_talk()
	print("  muffle sound (dB re full scale, 300 Hz / 1 kHz / 3 kHz, frames): doorway %.1f / %.1f / %.1f (%d), wall %.1f / %.1f / %.1f (%d)"
			% [clear.x, clear.y, clear.z, int(clear.w), muffled.x, muffled.y, muffled.z, int(muffled.w)])
	var got := int(clear.w) > 4000 and int(muffled.w) > 4000 and clear.x > -60.0
	if check(got, "the mix reached the capture (%d / %d frames)" % [int(clear.w), int(muffled.w)]):
		var low := muffled.x - clear.x
		var mid := muffled.y - clear.y
		var high := muffled.z - clear.z
		check(absf(clear.x - clear.z) < 3.0, "through the doorway the three tones are level (as sent): %.1f / %.1f / %.1f dB" % [clear.x, clear.y, clear.z])
		check(low < -1.5 and low > -8.0, "the wall: 300 Hz a little quieter (%.1f dB)" % low)
		check(mid <= -12.0 and high <= -18.0 and high - low <= -10.0, "the wall: 1 kHz %.1f dB, 3 kHz %.1f dB (low-passed)" % [mid, high])
	AudioServer.remove_bus_effect(idx, fx)
	_cap = null
	await wait_sec(0.5)


## Opt-in (--muffle-wav=<path>, e.g. user://muffle_walk.wav): for a human to listen to. A voice-like buzz (a 120 Hz
## sawtooth with vibrato, in syllables) while Bob stands in the pen door's line (3 m), behind the wall beside it (3.9 m),
## and in the doorway's line again, 2 s each, me at the pen door: recorded off the Voice bus into one 16-bit WAV.
func _record_walk(path: String) -> void:
	step("recording the walk to %s" % path)
	var idx := AudioServer.get_bus_index(&"Voice")
	var rec := AudioEffectRecord.new()
	rec.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(idx, rec)
	var fx := AudioServer.get_bus_effect_count(idx) - 1
	_buzz = true
	_put_me(DOOR_ME)
	_put(bob, DOOR_BOB)
	await wait_physics(2)
	_start_talk([BOB])
	await _talk_sec(0.4)
	rec.set_recording_active(true)
	await _talk_sec(2.0)
	_put(bob, WALL_BOB)
	await _talk_sec(2.0)
	_put(bob, DOOR_BOB)
	await _talk_sec(2.0)
	rec.set_recording_active(false)
	_stop_talk()
	_buzz = false
	var wav := rec.get_recording()
	var err := wav.save_to_wav(path) if wav != null else ERR_CANT_CREATE
	check(err == OK, "written: %s (%.1f s, clear / behind the wall / clear)" % [ProjectSettings.globalize_path(path), wav.get_length() if wav != null else 0.0])
	AudioServer.remove_bus_effect(idx, fx)
	await wait_sec(0.3)


## Goertzel levels of the three tones in what the Voice bus mixed over `sec` while Bob talks: (300 Hz, 1 kHz, 3 kHz in
## dB, frames).
func _measure(sec: float) -> Vector4:
	_cap.clear_buffer()
	await _talk_sec(sec)
	var n := _cap.get_frames_available()
	if n <= 0:
		return Vector4(-200.0, -200.0, -200.0, 0.0)
	var buf := _cap.get_buffer(n)
	var rate := AudioServer.get_mix_rate()
	return Vector4(_tone_db(buf, TONE_LOW, rate), _tone_db(buf, TONE_MID, rate), _tone_db(buf, TONE_HIGH, rate), float(n))


func _tone_db(buf: PackedVector2Array, freq: float, rate: float) -> float:
	var c := 2.0 * cos(TAU * freq / rate)
	var s1 := 0.0
	var s2 := 0.0
	for v in buf:
		var s := (v.x + v.y) * 0.5 + c * s1 - s2
		s2 = s1
		s1 = s
	var n := float(buf.size())
	var power := (s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n)
	return 10.0 * log(maxf(power, 1e-20)) / log(10.0)


# --- talking -------------------------------------------------------------------------------------------------------------

func _start_talk(peers: Array) -> void:
	_talkers.clear()
	for p in peers:
		_talkers.append(int(p))
	_talk_sent.clear()
	_talk_t0 = Time.get_ticks_msec()


func _stop_talk() -> void:
	_talkers.clear()
	_talk_sent.clear()


## Injects the frames due by now for every talker (50 a second from the spell's start).
func _drive() -> void:
	if _talkers.is_empty():
		return
	var due := int((Time.get_ticks_msec() - _talk_t0) / FRAME_MS) + 1
	for peer in _talkers:
		var sent := int(_talk_sent.get(peer, 0))
		while sent < due:
			Voice.debug_inject_frame(peer, _frame(sent))
			sent += 1
		_talk_sent[peer] = sent


## Frames pass for `sec` while the talkers talk.
func _talk_sec(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	var last := t0
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		_drive()
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		_worst_frame_ms = maxi(_worst_frame_ms, now - last)
		last = now
	_drive()


## Talks until Bob's muffle amount reaches `goal` (or `timeout`): {reached, ms (from the call), ease_ms (the last frame
## still at the start value to the goal), between (frames with the amount strictly between 0 and 1), max_step (biggest
## change in one frame)}.
func _watch_amount(goal: float, timeout: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var prev := Voice.get_muffle_amount(BOB)
	var start := prev
	var last_at_start := t0
	var between := 0
	var max_step := 0.0
	var last := t0
	while Time.get_ticks_msec() - t0 < int(timeout * 1000.0):
		_drive()
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		_worst_frame_ms = maxi(_worst_frame_ms, now - last)
		last = now
		var a := Voice.get_muffle_amount(BOB)
		if a == start:
			last_at_start = now
		max_step = maxf(max_step, absf(a - prev))
		if a > 0.0 and a < 1.0:
			between += 1
		prev = a
		if a == goal:
			return {"reached": true, "ms": now - t0, "ease_ms": now - last_at_start, "between": between, "max_step": max_step}
	return {"reached": false, "ms": Time.get_ticks_msec() - t0, "ease_ms": 0, "between": between, "max_step": max_step}


func _frame(n: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(VoiceScript.FRAME_SAMPLES)
	var rate := float(VoiceScript.SAMPLE_RATE)
	for i in VoiceScript.FRAME_SAMPLES:
		var t := float(i + n * VoiceScript.FRAME_SAMPLES) / rate
		if _buzz:
			var phase := 120.0 * t - 120.0 * 0.03 * cos(TAU * 5.0 * t) / (TAU * 5.0)
			var syllable := pow(0.5 + 0.5 * sin(TAU * 3.0 * t), 2.0)
			s[i] = 0.3 * syllable * (2.0 * fposmod(phase, 1.0) - 1.0)
			continue
		s[i] = 0.2 * (sin(TAU * TONE_LOW * t) + sin(TAU * TONE_MID * t) + sin(TAU * TONE_HIGH * t))
	return VoiceScript.encode_mulaw(s)


# --- checks --------------------------------------------------------------------------------------------------------------

func _casts() -> int:
	return int(Voice.get_muffle_stats()["casts"])


## The cutoff, the filter depth and the cap as every voice had them before M25 (the voice code sets max_db 0).
func _filter_clear(p: AudioStreamPlayer3D) -> bool:
	return is_equal_approx(p.attenuation_filter_cutoff_hz, VoiceScript.MUFFLE_CLEAR_HZ) \
			and is_equal_approx(p.attenuation_filter_db, FILTER_DB) and p.max_db == 0.0


func _is_clear(p: AudioStreamPlayer3D) -> bool:
	return _filter_clear(p) and p.volume_db == 0.0


func _is_muffled(p: AudioStreamPlayer3D) -> bool:
	return is_equal_approx(p.attenuation_filter_cutoff_hz, VoiceScript.MUFFLE_HZ) and is_equal_approx(p.attenuation_filter_db, FILTER_DB) \
			and is_equal_approx(p.volume_db, VoiceScript.MUFFLE_DB) and is_equal_approx(p.max_db, VoiceScript.MUFFLE_DB)


## A radio output as the radio code made it: the engine's filter defaults, radio_volume_db, max_db 0.
func _is_radio_clear(p: AudioStreamPlayer3D) -> bool:
	return _filter_clear(p) and is_equal_approx(p.volume_db, Config.balance.radio_volume_db)


func _describe(p: AudioStreamPlayer3D) -> String:
	if p == null:
		return "no output"
	return "%.0f Hz, %.1f dB filter, %.1f dB, max %.1f dB" % [p.attenuation_filter_cutoff_hz, p.attenuation_filter_db, p.volume_db, p.max_db]


func _excluded(body: CollisionObject3D) -> bool:
	return Voice._muffle_exclude.has(body.get_rid())


func _excluded_under(n: Node) -> bool:
	var body := n as CollisionObject3D
	if body != null and (body.collision_layer & Const.LAYER_WORLD) != 0:
		return _excluded(body)
	for c in n.get_children():
		if _excluded_under(c):
			return true
	return false


## The first world-layer body on the line, nothing excluded (what a plain ray would answer).
func _bare_hit(from: Vector3, to: Vector3) -> Node:
	var q := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD)
	var hit := me.get_world_3d().direct_space_state.intersect_ray(q)
	return hit.get("collider") as Node if not hit.is_empty() else null


func _name_of(n: Node) -> String:
	return "nothing" if n == null else String(room.get_path_to(n)) if room.is_ancestor_of(n) else String(n.name)


# --- placing -------------------------------------------------------------------------------------------------------------

func _g(local: Vector3) -> Vector3:
	return room.global_transform * local


func _head(p: Player) -> Vector3:
	if p == me:
		return me.camera.global_position
	return p.global_position + Vector3.UP * VoiceScript.HEAD_STANDING


## A fake (unowned) worker at `local` (Room-local floor), facing -Z: place_at writes net_position too.
func _put(p: Player, local: Vector3) -> void:
	var at := _g(local)
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(at.x, at.y + 0.05, at.z)))


## My own body at `local`, facing +X (east), level look.
func _put_me(local: Vector3) -> void:
	var at := _g(local)
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(at.x, at.y + 0.02, at.z)
	me.rotation = Vector3(0.0, -PI * 0.5, 0.0)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
