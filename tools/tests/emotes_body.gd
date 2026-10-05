extends "res://tools/tests/qa_base.gd"
## M18 emotes suite (emotes agent): the four gestures on a single headless host with one fake worker (Bob: a host-side
## body without an owning peer, so the SERVER side runs directly on him and his body is posed like any remote worker's).
## Plain game (no --replay).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/emotes_body.gd --port=7940 --round-sec=900
## Pins:
##   contract     the keys 1 to 4 (emote_1..4), emote_sec / emote_cooldown_sec, the `emote` cloth recipe of its own
##   point        plays on Bob for emote_sec with the sound at his chest; the arm comes up and follows his look (pitch
##                up and down, and the glove really points where he looks); the other arm stays down; it ends and the
##                body is as it was; the face keeps its mood
##   wave / shrug the arm comes up halfway and rocks; both hands out, the shoulders up and sagging; each ends
##   slump        Bob sits down (squashed low) hunched in the open, leaning back with his back to a wall; holds past
##                emote_sec; a stagger and the back room end it. Me: the camera goes down to sitting height and back up,
##                movement input ends it, a gesture key stands me up instead of starting one, a teleport ends it
##   cooldown     the host refuses a second gesture inside emote_cooldown_sec (Bob) and so does my own key (me)
##   refused      stunned, a Floor Brick bundle, the hand truck (with the toast), the flamethrower burning, my trigger held
##   normal item  with a watering can in the right glove the LEFT arm points (the right keeps holding), slumping keeps it
##   first person my point arm under the camera on the view-model layer (registered, in view, gone after), on the left
##                with an item in hand; none while another camera is current (the back room)
##   back room    I can still gesture under the back-room lock (decision), the A / D keys do not cancel it there, being
##                let out ends it
##   copy         the pause menu's controls line and the main menu's how-to list "1-4 gestures"
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const OPEN := Vector3(-2.0, 0.0, 3.0)
const ME_AT := Vector3(4.0, 0.0, 3.0)

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var _started: Array = []       # [peer, kind]
var _ended: Array = []         # [peer, kind]
var _voice_at_start: Array = [] # [peer, kind, voice node]


func _run() -> void:
	_label = "emotes"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false

	step("hosting")
	Game.start_host("Tester", port_arg(7940))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	await wait_frames(3)
	if not check(bob != null and world.get_players().size() == 2, "host + Bob spawned"):
		finish(); return
	for p: Player in [me, bob]:
		var pid := p.peer_id
		p.emote_started.connect(func(kind: int) -> void:
			_started.append([pid, kind])
			_voice_at_start.append([pid, kind, Sfx.get_last_voice()]))
		p.emote_ended.connect(func(kind: int) -> void: _ended.append([pid, kind]))
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	await wait_frames(3)

	_test_contract(b)
	await _test_point(b)
	await _test_wave_shrug(b)
	await _test_cooldown(b)
	await _test_slump_bob(b)
	await _test_slump_me(b)
	await _test_refused(b)
	await _test_normal_item(b)
	await _test_first_person(b)
	await _test_back_room(b)
	_test_copy()
	finish()


# --- contract ----------------------------------------------------------------------------------------------------------

func _test_contract(b: BalanceConfig) -> void:
	step("contract")
	var keys_ok := true
	for i in 4:
		var action: StringName = Player.EMOTE_ACTIONS[i]
		var found := false
		if InputMap.has_action(action):
			for e in InputMap.action_get_events(action):
				var k := e as InputEventKey
				if k != null and k.physical_keycode == KEY_1 + i:
					found = true
		keys_ok = keys_ok and found
	check(keys_ok and Player.EMOTE_ACTIONS.size() == 4, "emote_1..emote_4 are the number keys 1 to 4")
	check(is_equal_approx(b.emote_sec, 2.4) and is_equal_approx(b.emote_cooldown_sec, 1.0), "emote_sec %.1f, emote_cooldown_sec %.1f" % [b.emote_sec, b.emote_cooldown_sec])
	check(Player.emote_name(Player.EMOTE_POINT) == "point" and Player.emote_name(Player.EMOTE_SLUMP) == "slump" and Player.emote_name(9) == "",
			"point / wave / shrug / slump")
	var m := Sfx.measure(Sfx.get_stream(&"emote"))
	check(Sfx.has_sound(&"emote") and m.seconds > 0.3 and m.seconds < 0.6, "the emote cloth rustle has a recipe of its own (%.2f s, not the 0.1 s blip)" % m.seconds)
	check(absf(m.dc) < 0.01 and m.peak >= 0.85 and m.peak <= 0.9 and m.clipped == 0, "emote: normalised, no DC, no clipping (peak %.3f, dc %.4f)" % [m.peak, m.dc])
	check(bob.get_emote() == Player.EMOTE_NONE and me.get_emote() == Player.EMOTE_NONE and bob.get_emote_arm() == null, "nobody gestures at the start")


# --- point -------------------------------------------------------------------------------------------------------------

func _test_point(b: BalanceConfig) -> void:
	step("point: Bob points, the arm follows his look")
	_put_bob(OPEN, 0.0, 0.0)
	await wait_sec(0.6) # the jump there reads as a step: let the walk swing settle
	var mood0: StringName = _mood(bob)
	var arm_l0 := bob.arm_l.rotation
	_started.clear()
	_voice_at_start.clear()
	check(bob.server_emote(Player.EMOTE_POINT), "the host starts Bob's point")
	check(bob.get_emote() == Player.EMOTE_POINT and _started == [[BOB, Player.EMOTE_POINT]], "it plays on Bob (emote_started %s)" % [_started])
	var voice := _voice_at_start[0][2] as AudioStreamPlayer3D if not _voice_at_start.is_empty() else null
	check(voice != null and voice.stream == Sfx.get_stream(&"emote") and voice.global_position.distance_to(bob.get_chest_position()) < 0.01,
			"the emote sound plays at his chest (3D)")
	await wait_sec(0.4)
	check(is_equal_approx(bob.get_emote_weight(), 1.0) and bob.get_emote_arm() == bob.arm_r, "eased in, the right arm gestures")
	var want := PI * 0.5 - Player.ARM_REST_FORWARD
	check(absf(bob.arm_r.rotation.x - want) < 0.03, "looking ahead the arm is up level (rotation.x %.2f, want %.2f)" % [bob.arm_r.rotation.x, want])
	check(_points_at_look(bob), "the glove points where he looks (%s vs %s)" % [bob.get_emote_arm_direction(), bob.get_look_direction()])
	check(bob.arm_l.rotation.distance_to(arm_l0) < 0.05, "the other arm stays down")
	bob.net_pitch = 0.6
	await wait_sec(0.45)
	check(absf(bob.arm_r.rotation.x - (0.6 + want)) < 0.04 and _points_at_look(bob), "he looks up: the arm follows (%.2f, want %.2f)" % [bob.arm_r.rotation.x, 0.6 + want])
	bob.net_pitch = -0.5
	await wait_sec(0.45)
	check(absf(bob.arm_r.rotation.x - (-0.5 + want)) < 0.04 and _points_at_look(bob), "he looks down: it follows (%.2f, want %.2f)" % [bob.arm_r.rotation.x, -0.5 + want])
	check(_mood(bob) == mood0, "the face keeps its mood (%s)" % _mood(bob))
	await wait_until(func() -> bool: return bob.get_emote() == Player.EMOTE_NONE, b.emote_sec, "it ends by itself")
	check(bob.get_emote_time() >= b.emote_sec - 0.05 and _ended.has([BOB, Player.EMOTE_POINT]), "after emote_sec (%.2f s), emote_ended" % bob.get_emote_time())
	await wait_sec(0.15)
	bob.net_pitch = 0.0
	await wait_frames(3)
	check(bob.get_emote_weight() == 0.0 and bob.get_emote_arm() == null and bob.arm_r.rotation.length() < 0.01
			and bob.body_model.transform.is_equal_approx(Transform3D.IDENTITY), "the body is as it was (arms down, model at rest)")


func _points_at_look(p: Player) -> bool:
	return p.get_emote_arm_direction().dot(p.get_look_direction()) > cos(0.25)


func _mood(p: Player) -> StringName:
	var f := p.get_node_or_null(^"Visual/Face/ToonFace")
	return f.get(&"mood") if f != null else &""


# --- wave / shrug ------------------------------------------------------------------------------------------------------

func _test_wave_shrug(b: BalanceConfig) -> void:
	step("wave: halfway up, two slow rocks")
	await wait_sec(0.3)
	check(bob.server_emote(Player.EMOTE_WAVE), "the host starts Bob's wave")
	await wait_sec(0.35)
	check(bob.arm_r.rotation.x > 1.8 and bob.arm_r.rotation.z > 0.2, "the arm is up and out (%s)" % bob.arm_r.rotation)
	var lo := INF
	var hi := -INF
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1100:
		await get_tree().process_frame
		lo = minf(lo, bob.arm_r.rotation.z)
		hi = maxf(hi, bob.arm_r.rotation.z)
	check(hi - lo > 0.25 and hi - lo < 0.5, "it rocks, not much (%.2f..%.2f)" % [lo, hi])
	await wait_until(func() -> bool: return bob.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the wave ends")

	step("shrug: the shoulders come up, both hands out")
	await wait_sec(0.5)
	check(bob.server_emote(Player.EMOTE_SHRUG), "the host starts Bob's shrug")
	await wait_sec(0.4)
	var rest_y := bob.get(&"_emote_arm_r_rest").y as float
	check(bob.arm_r.position.y > rest_y + 0.04 and bob.arm_l.position.y > rest_y + 0.04, "the shoulders are up (%.3f over %.3f)" % [bob.arm_r.position.y, rest_y])
	check(bob.arm_r.rotation.z > 0.4 and bob.arm_l.rotation.z < -0.4 and bob.arm_r.rotation.x > 0.3, "both hands out (%s / %s)" % [bob.arm_l.rotation, bob.arm_r.rotation])
	var up_early := bob.arm_r.position.y
	await wait_sec(1.2)
	check(bob.arm_r.position.y < up_early - 0.01 and bob.get_emote() == Player.EMOTE_SHRUG, "the shoulders sag while it holds")
	await wait_until(func() -> bool: return bob.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the shrug ends")
	await wait_sec(0.2)
	check(bob.arm_r.position.is_equal_approx(bob.get(&"_emote_arm_r_rest")) and bob.arm_l.position.is_equal_approx(bob.get(&"_emote_arm_l_rest")),
			"the shoulders are back where they were")


# --- cooldown ----------------------------------------------------------------------------------------------------------

func _test_cooldown(b: BalanceConfig) -> void:
	step("cooldown: one gesture per emote_cooldown_sec")
	await wait_sec(b.emote_cooldown_sec + 0.1)
	_started.clear()
	check(bob.server_emote(Player.EMOTE_POINT), "a point")
	check(not bob.server_emote(Player.EMOTE_WAVE) and bob.get_emote() == Player.EMOTE_POINT, "a wave right after is refused by the host")
	await wait_sec(0.5)
	check(not bob.server_emote(Player.EMOTE_WAVE), "still refused half a second in")
	await wait_sec(0.6)
	check(bob.server_emote(Player.EMOTE_WAVE) and bob.get_emote() == Player.EMOTE_WAVE, "after the cooldown the wave replaces the point")
	check(_started == [[BOB, Player.EMOTE_POINT], [BOB, Player.EMOTE_WAVE]] and _ended.has([BOB, Player.EMOTE_POINT]), "two starts, the point ended (%s)" % [_started])
	check(not bob.server_emote(99) and not bob.server_emote(-1), "a gesture that does not exist is refused")
	await wait_until(func() -> bool: return bob.get_emote() == Player.EMOTE_NONE, b.emote_sec + 0.3, "the wave ends")
	# Me: my own key keeps the same clock.
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	await _press(&"emote_1")
	check(me.get_emote() == Player.EMOTE_POINT, "my key 1: I point (the real input, through the host)")
	await _press(&"emote_2")
	check(me.get_emote() == Player.EMOTE_POINT and me.get_emote_refusal() == Player.EMOTE_REFUSED_COOLDOWN, "key 2 right after does nothing (cooldown)")
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_2")
	check(me.get_emote() == Player.EMOTE_WAVE, "after the cooldown key 2 waves")
	await wait_until(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, b.emote_sec + 0.2, "my wave ends")


# --- slump -------------------------------------------------------------------------------------------------------------

func _test_slump_bob(b: BalanceConfig) -> void:
	step("slump: Bob sits down in the open, then against a wall")
	await wait_sec(b.emote_cooldown_sec)
	_put_bob(OPEN, 0.0, 0.0)
	await wait_frames(2)
	var label_y := bob.name_label.position.y
	check(bob.server_emote(Player.EMOTE_SLUMP) and bob.is_slumped(), "the host starts Bob's slump")
	await wait_sec(0.7)
	var sy := bob.body_model.scale.y
	check(sy > Player.SIT_SQUASH - 0.03 and sy < Player.SIT_SQUASH + 0.03, "he sits: squashed to %.2f of his height" % sy)
	check(bob.get_slump_wall() == INF and bob.body_model.rotation.x < -0.05, "nothing behind him: he hunches forward (lean %.2f)" % bob.body_model.rotation.x)
	check(bob.name_label.position.y < label_y * 0.7 and bob.arm_r.rotation.z > 0.2 and bob.arm_l.rotation.z < -0.2,
			"his name comes down with him, the arms hang limp")
	await wait_sec(b.emote_sec)
	check(bob.is_slumped() and bob.get_emote_time() > b.emote_sec, "still sitting after emote_sec (%.1f s)" % bob.get_emote_time())
	# Against a wall: Bob's back 0.8 m from one.
	var wall := _find_wall(OPEN + Vector3.UP * 0.6, Vector3.LEFT)
	check(wall.size() == 2, "a wall west of the open spot")
	if wall.size() == 2:
		var normal: Vector3 = wall[1]
		var at: Vector3 = wall[0] + normal * 0.8
		at.y = 0.0
		check(bob.server_emote(Player.EMOTE_NONE) and not bob.is_slumped(), "the host ends it (EMOTE_NONE)")
		await wait_sec(b.emote_cooldown_sec)
		_put_bob(at, atan2(-normal.x, -normal.z), 0.0)
		await wait_frames(2)
		check(bob.server_emote(Player.EMOTE_SLUMP), "Bob slumps with his back to the wall")
		await wait_sec(0.8)
		check(absf(bob.get_slump_wall() - 0.8) < 0.1, "the wall is %.2f m behind him" % bob.get_slump_wall())
		check(bob.body_model.rotation.x > 0.15 and bob.body_model.position.z > 0.15, "he leans back against it (lean %.2f, slid back %.2f m)" % [bob.body_model.rotation.x, bob.body_model.position.z])
	step("slump: a stagger and the back room end it")
	_ended.clear()
	Player.server_stagger(bob, Vector3.RIGHT, false, 1)
	await wait_frames(2)
	check(not bob.is_slumped() and _ended == [[BOB, Player.EMOTE_SLUMP]], "a shove ends Bob's slump")
	await wait_sec(0.5)
	check(bob.body_model.transform.is_equal_approx(Transform3D.IDENTITY) and is_equal_approx(bob.name_label.position.y, label_y), "he is back up")
	await wait_until(func() -> bool: return bob.get_emote_block() == "", 4.0, "the stun passes")
	await wait_sec(b.emote_cooldown_sec)
	check(bob.server_emote(Player.EMOTE_SLUMP), "Bob slumps again")
	GameState.server_send_to_backroom(BOB, 30.0)
	await wait_frames(2)
	check(not bob.is_slumped(), "sent to the back room: the slump ends")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(3)


func _test_slump_me(b: BalanceConfig) -> void:
	step("slump: me, the camera, movement, the key again, a teleport")
	await wait_sec(b.emote_cooldown_sec)
	_put_me(ME_AT, 0.0)
	await wait_physics(3)
	await _press(&"emote_4")
	check(me.is_slumped(), "key 4: I sit down")
	await wait_sec(0.7)
	check(absf(me.head.position.y - Player.SIT_CAMERA_Y) < 0.01, "my camera is at sitting height (%.2f)" % me.head.position.y)
	await wait_sec(b.emote_sec)
	check(me.is_slumped(), "still sitting after emote_sec")
	var at := me.global_position
	Input.action_press(&"move_forward")
	await wait_physics(2)
	var ended := not me.is_slumped()
	await wait_physics(10)
	Input.action_release(&"move_forward")
	check(ended, "W: the slump ends at once")
	await wait_sec(0.5)
	check(absf(me.head.position.y - Player.STAND_CAMERA_Y) < 0.01 and me.global_position.distance_to(at) > 0.2,
			"I walk off, the camera back at standing height (%.2f)" % me.head.position.y)
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_4")
	check(me.is_slumped(), "sitting again")
	await wait_sec(b.emote_cooldown_sec)
	_started.clear()
	await _press(&"emote_2")
	check(not me.is_slumped() and me.get_emote() == Player.EMOTE_NONE and _started.is_empty(), "any gesture key stands me up instead of waving")
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_4")
	check(me.is_slumped(), "sitting once more")
	me.server_teleport(Transform3D(Basis.IDENTITY, ME_AT + Vector3(0.0, 0.05, 0.5)))
	await wait_frames(2)
	check(not me.is_slumped(), "a teleport ends it")
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_4")
	check(me.is_slumped(), "and again")
	Input.action_press(&"crouch")
	await wait_physics(2)
	check(not me.is_slumped(), "crouch ends it too")
	Input.action_release(&"crouch")
	await wait_physics(12)
	await wait_sec(b.emote_cooldown_sec)
	_put_me(ME_AT, 0.0)
	await wait_physics(3)
	Input.action_press(&"move_back")
	await wait_physics(4)
	await _press(&"emote_4")
	Input.action_release(&"move_back")
	check(me.get_emote() == Player.EMOTE_NONE, "walking: the key does nothing (it would end at once)")
	await wait_physics(20)
	Input.action_press(&"jump")
	await wait_physics(4)
	Input.action_release(&"jump")
	var airborne := not me.is_on_floor()
	await _press(&"emote_4")
	check(airborne and me.get_emote() == Player.EMOTE_NONE, "in the air: nothing either")
	await wait_sec(1.0)


# --- refused -----------------------------------------------------------------------------------------------------------

func _test_refused(b: BalanceConfig) -> void:
	step("refused: stunned, heavy, the flamethrower")
	await wait_sec(b.emote_cooldown_sec)
	_started.clear()
	_put_bob(OPEN, 0.0, 0.0)
	await wait_frames(2)
	Player.server_stagger(bob, Vector3.RIGHT, false, 1)
	await wait_frames(1)
	check(bob.get_emote_block() == Player.EMOTE_REFUSED_STUNNED and not bob.server_emote(Player.EMOTE_POINT), "stunned: refused")
	await wait_until(func() -> bool: return bob.get_emote_block() == "", 4.0, "the stun passes")
	_put_bob(OPEN, 0.0, 0.0)
	var brick := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "brick", "amount": 1}, OPEN + Vector3(0.0, 0.0, 1.0))
	await wait_frames(1)
	check(items.server_give_item(brick, BOB), "Bob takes a Floor Brick bundle")
	await wait_frames(2)
	check(bob.get_emote_block() == Player.EMOTE_REFUSED_HEAVY and not bob.server_emote(Player.EMOTE_WAVE), "a heavy bundle: refused")
	items.server_despawn_item(brick)
	await wait_frames(2)
	var trucks := items.get_items_of_type(Const.ITEM_HAND_TRUCK)
	check(trucks.size() == 1, "the hand truck is on the dock")
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	if trucks.size() == 1:
		check(items.server_give_item(trucks[0], 1), "I take the hand truck")
		await wait_frames(2)
		toasts.clear()
		await _press(&"emote_3")
		check(me.get_emote() == Player.EMOTE_NONE and me.get_emote_refusal() == Player.EMOTE_REFUSED_HEAVY, "the hand truck: my key does nothing")
		check(toast_seen(Player.TEXT_HANDS_BUSY), "and says '%s'" % Player.TEXT_HANDS_BUSY)
		items.server_release_holder(1)
		await wait_frames(2)
	var flame := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": 6.0}, OPEN + Vector3(0.0, 0.0, 1.0)) as Flamethrower
	await wait_frames(1)
	check(flame != null and items.server_give_item(flame, BOB), "Bob takes a flamethrower")
	await wait_frames(2)
	check(bob.get_emote_block() == "", "holding it cold is a normal item")
	check(flame.server_request_fire(BOB, true) and flame.is_firing(), "Bob fires it (at the open floor)")
	await wait_frames(1)
	check(bob.get_emote_block() == Player.EMOTE_REFUSED_TRIGGER and not bob.server_emote(Player.EMOTE_SHRUG), "the flame on: refused")
	flame.server_request_fire(BOB, false)
	items.server_despawn_item(flame)
	await wait_frames(2)
	var mine := items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": 0.0}, ME_AT + Vector3(0.0, 0.0, 1.0))
	await wait_frames(1)
	items.server_give_item(mine, 1)
	await wait_frames(2)
	Input.action_press(&"use_item")
	var held_trigger := me.get_emote_block()
	Input.action_release(&"use_item")
	check(held_trigger == Player.EMOTE_REFUSED_TRIGGER and me.get_emote_block() == "", "my finger on the trigger refuses it (an empty one too), off it is fine")
	items.server_despawn_item(mine)
	await wait_frames(2)
	check(_count_started(BOB) == 0 and _count_started(1) == 0, "nothing started while refused (%s)" % [_started])


func _count_started(peer: int) -> int:
	var n := 0
	for s: Array in _started:
		if int(s[0]) == peer:
			n += 1
	return n


# --- a normal item -------------------------------------------------------------------------------------------------------

func _test_normal_item(b: BalanceConfig) -> void:
	step("a normal item in the right glove: the left arm gestures")
	await wait_sec(b.emote_cooldown_sec)
	var cans := items.get_items_of_type(Const.ITEM_WATERING_CAN)
	if not check(cans.size() >= 1, "a watering can"):
		return
	var can := cans[0]
	_put_bob(OPEN, 0.0, 0.0)
	check(items.server_give_item(can, BOB), "Bob holds a watering can")
	await wait_sec(0.6)
	var hold := bob.arm_r.rotation
	check(hold.distance_to(Player.HOLD_ARM_ROTATION) < 0.05, "his right arm holds it up (%s)" % hold)
	check(bob.server_emote(Player.EMOTE_POINT) and bob.get_emote_arm() == bob.arm_l, "he points with the left arm")
	await wait_sec(0.4)
	check(absf(bob.arm_l.rotation.x - (PI * 0.5 - Player.ARM_REST_FORWARD)) < 0.04 and _points_at_look(bob), "the left arm is up, pointing where he looks")
	check(bob.arm_r.rotation.distance_to(Player.HOLD_ARM_ROTATION) < 0.05 and can.holder_id == BOB, "the right keeps holding the can")
	await wait_until(func() -> bool: return bob.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the point ends")
	await wait_sec(b.emote_cooldown_sec)
	var socket_y := bob.body_hand_socket.position.y
	check(bob.server_emote(Player.EMOTE_SLUMP), "he slumps with it")
	await wait_sec(0.7)
	check(can.holder_id == BOB and bob.body_hand_socket.position.y < socket_y * 0.7 and bob.arm_r.rotation.distance_to(Player.HOLD_ARM_ROTATION) < 0.05,
			"the can comes down into his lap, still in the right glove")
	bob.server_emote(Player.EMOTE_NONE)
	await wait_sec(0.5)
	check(is_equal_approx(bob.body_hand_socket.position.y, socket_y), "the socket is back up")
	items.server_release_holder(BOB)
	await wait_frames(2)


# --- first person --------------------------------------------------------------------------------------------------------

func _test_first_person(b: BalanceConfig) -> void:
	step("first person: my point arm in the view model")
	await wait_sec(b.emote_cooldown_sec)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	check(not me.is_view_model_active() and me.get_first_person_arm() == null, "nothing in the view model, no arm")
	await _press(&"emote_1")
	await wait_sec(0.4)
	var arm := me.get_first_person_arm()
	if not check(arm != null, "pointing: the first-person arm is shown"):
		return
	check(arm.name == Player.FP_ARM_NAME and arm.get_parent() == me.camera, "it hangs under %%Camera (%s)" % arm.get_path())
	var on_vm := true
	var parts := arm.find_children("*", "GeometryInstance3D", true, false)
	for n in parts:
		on_vm = on_vm and (n as GeometryInstance3D).layers == Player.VIEW_MODEL_LAYER
	check(parts.size() >= 4 and on_vm and (me.camera.cull_mask & Player.VIEW_MODEL_LAYER) == 0, "every part on the view-model layer only (%d parts), which the world camera skips" % parts.size())
	check(me.is_view_model_active() and me.get_view_model_users().has(arm), "the view-model pass renders it")
	var mitt := arm.get_node(^"Mitt") as Node3D
	var finger := arm.get_node(^"Finger") as Node3D
	var local_mitt := me.camera.global_transform.affine_inverse() * mitt.global_position
	check(me.camera.is_position_in_frustum(mitt.global_position) and me.camera.is_position_in_frustum(finger.global_position)
			and local_mitt.x > 0.05 and local_mitt.y < -0.1, "the glove is in view, lower right (%s)" % local_mitt)
	var sleeve := arm.get_node(^"Sleeve") as MeshInstance3D
	check(sleeve.material_override == Toon.tint(me.player_color), "the sleeve is the worker's colour")
	me.head.rotation.x = 0.7
	await wait_frames(2)
	check(me.camera.is_position_in_frustum(mitt.global_position), "looking up it stays in view (it points where I look)")
	me.head.rotation.x = 0.0
	await wait_until(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the point ends")
	await wait_sec(0.1)
	check(me.get_first_person_arm() == null and not arm.visible and not me.is_view_model_active() and not me.get_view_model_users().has(arm),
			"the arm is gone and the view-model pass stops")
	var other_gestures := true
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_3")
	await wait_sec(0.4)
	other_gestures = me.get_emote() == Player.EMOTE_SHRUG and me.get_first_person_arm() == null
	check(other_gestures, "a shrug shows nothing in first person")
	await wait_until(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the shrug ends")
	step("first person: with a can in hand the arm is the left one")
	var cans := items.get_items_of_type(Const.ITEM_WATERING_CAN)
	if cans.is_empty():
		return
	items.server_give_item(cans[0], 1)
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_1")
	await wait_sec(0.4)
	arm = me.get_first_person_arm()
	var local_arm := Vector3.ZERO
	if arm != null:
		local_arm = me.camera.global_transform.affine_inverse() * (arm.get_node(^"Mitt") as Node3D).global_position
	check(arm != null and local_arm.x < -0.05 and me.get_view_model_users().has(arm) and me.get_view_model_users().has(cans[0]),
			"on the left (%s), drawn with the can" % local_arm)
	me.view_model_enabled = false
	await wait_frames(2)
	var world_layers := true
	if arm != null:
		for n in arm.find_children("*", "GeometryInstance3D", true, false):
			world_layers = world_layers and (n as GeometryInstance3D).layers == Player.WORLD_RENDER_LAYER
	check(arm != null and arm.visible and world_layers and not me.get_view_model_users().has(arm), "view model off: the arm draws in the world")
	me.view_model_enabled = true
	await wait_until(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the point ends")
	items.server_release_holder(1)
	await wait_frames(2)


# --- the back room -------------------------------------------------------------------------------------------------------

func _test_back_room(b: BalanceConfig) -> void:
	step("the back room: gestures still work (decision)")
	await wait_sec(b.emote_cooldown_sec)
	check(GameState.server_send_to_backroom(1, 60.0), "the host sends me to the back room")
	await wait_until(func() -> bool: return Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM), 3.0, "the back-room lock is on")
	await wait_frames(3)
	await _press(&"emote_3")
	check(me.get_emote() == Player.EMOTE_SHRUG, "key 3 under the back-room lock: I shrug in there")
	await _press(&"move_left")
	check(me.get_emote() == Player.EMOTE_SHRUG, "A (spectate) does not count as moving in there")
	await wait_until(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, b.emote_sec, "the shrug ends")
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_1")
	await wait_sec(0.4)
	check(me.get_emote() == Player.EMOTE_POINT and me.get_first_person_arm() == null and not me.is_view_model_active(),
			"pointing in there: no first-person arm (the spectator camera is current)")
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_4")
	check(me.is_slumped(), "I sit down in the back room")
	GameState.server_release_from_backroom(1)
	await wait_frames(3)
	check(not me.is_slumped(), "let out: the slump ends")
	await wait_until(func() -> bool: return not Game.is_ui_locked(), 3.0, "the lock is off")
	Game.set_ui_lock(&"test", true)
	await wait_sec(b.emote_cooldown_sec)
	await _press(&"emote_1")
	check(me.get_emote() == Player.EMOTE_NONE, "under any other UI lock the keys do nothing")
	Game.set_ui_lock(&"test", false)


# --- copy ----------------------------------------------------------------------------------------------------------------

func _test_copy() -> void:
	step("copy: the keys are listed")
	var hud := world.get_node_or_null(^"HUD") as HUD
	var line := hud.pause_menu.controls_label_2.text if hud != null else ""
	check(line.ends_with(" · 1-4 gestures") and line.begins_with(PauseMenu.TEXT_CONTROLS_M10), "pause menu: '%s'" % line)
	var menu := (load("res://scenes/main_menu/main_menu.tscn") as PackedScene).instantiate()
	var how := menu.get_node_or_null(^"Center/Column/HowTo/HowToText") as Label
	check(how != null and how.text.contains(" - 1-4 gestures - "), "main menu how-to lists '1-4 gestures'")
	menu.free()
	check(not Player.TEXT_HANDS_BUSY.contains("!") and not line.contains("!"), "no exclamation marks")


# --- helpers -------------------------------------------------------------------------------------------------------------

func _put_bob(pos: Vector3, yaw: float, pitch: float) -> void:
	bob.net_position = pos
	bob.net_yaw = yaw
	bob.net_pitch = pitch
	bob.position = pos
	bob.rotation = Vector3(0.0, yaw, 0.0)
	bob.head.rotation.x = pitch


func _put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


## Taps an input action for the local simulation (seen by one physics frame as just pressed).
func _press(action: StringName) -> void:
	Input.action_press(action)
	await wait_physics(2)
	Input.action_release(action)
	await wait_physics(1)


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## [hit point, normal] of the first wall along `dir` from `from` (world layer), or [] within 20 m.
func _find_wall(from: Vector3, dir: Vector3) -> Array:
	var space := world.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 20.0, Const.LAYER_WORLD)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return []
	return [hit["position"], hit["normal"]]
