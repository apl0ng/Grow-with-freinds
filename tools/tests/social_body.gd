extends "res://tools/tests/qa_base.gd"
## M23 social suite (social agent): help a friend up, the talk mark, today's run, on a single headless host with fake
## workers (Bob, Carl, later Dave: host-side bodies without an owning peer, so the SERVER side runs directly on them
## and their voice frames go straight into Voice's receive path through Voice.debug_inject_frame). Replay on with a
## fixed card (--replay --run=B5VP), temp career and settings files.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/social_body.gd --port=9201
##       --replay --run=B5VP --career-file=user://social_test_9201.cfg --settings-file=user://social_settings_9201.cfg
##       --round-sec=900 --timeout=220
## Pins:
##   today's run   RunSeed.daily: one seed from 00:00:00 to 23:59:59 UTC, another the next day and the day before,
##                 no repeat in 3000 days, any int folds in range, a pinned day; is_daily; weekly() as it was
##   the menu      the run row's button reads TODAY (node %WeekButton kept) and fills in today's code, the hint "Run
##                 XXXX."; no exclamation marks
##   the board     the run line is "Run B5VP." for another run and "Run XXXX. Today's run." for today's
##   help up       every kind of knockdown (a shove through the real request, a thrown item, a slip, a drive-by round,
##                 a bite from a hostile plant): the prompt "[E] Help Bob up" over him while he is down, E (a real
##                 input event) stands him up at once (the host's view and the body's), helped_up(1), STAT_HELPED for
##                 the helper, the help_up sound at his chest, the helper's reach and camera dip; a fake worker helps
##                 the host up (the host's own body: its camera lifts; Bob's arm reaches)
##   down          a stunned body slumps ($Visual sunk, tipped forward and to the side) within SLUMP_IN_SEC, the capsule,
##                 the label and the body's place untouched; it eases back up after the stun, and after a help-up long
##                 before the stun would have ended; my own body too, with my camera dropped (the head and the capsule
##                 stay); a 0.35 s shove is a quick dip
##   refusals      not down, out of reach, a wall between, the helper down, either one in the back room, helping
##                 yourself, a request for another worker's body, an unknown target, the cooldown (and after it)
##   the report    "Tester helped people up the most." in the verdicts, flat
##   talk mark     none on the local worker; one under each remote worker's %NameLabel, above it, hidden, billboard,
##                 unshaded, one shared texture, readable at 10 m; shown while Voice hears the worker, gone after the
##                 hold; two at once; a worker whose body spawns while he talks starts with it shown (the late join);
##                 a child mark never processes (signal driven)
##   radio mark    over a radio carrying a voice (exactly Voice.get_radio_listeners()), upright over a radio lying on
##                 its side, none over the sender's own radio, hidden while it is in my hands, gone after the gap
## Every engine/script error fails the run unless announced (qa_base.gd).

const VoiceScript := preload("res://scripts/core/voice.gd")
const MENU_SCENE := "res://scenes/main_menu/main_menu.tscn"
const BOB := 2
const CARL := 3
const DAVE := 4
const ME_AT := Vector3(-3.0, 0.0, 3.0)
const BOB_AT := Vector3(-3.0, 0.0, 1.8)
const CARL_AT := Vector3(-1.4, 0.0, 3.6)
const FAR_AT := Vector3(-8.0, 0.0, 5.0)

var world: World
var items: ItemManager
var me: Player
var bob: Player
var carl: Player
var interactor: Interactor
var _helped: Array = []       # [peer helped, by_peer] in order, on this peer
var _helped_voice: Node = null # the last sound player when helped_up fired
var _saved: Dictionary = {}   # balance values this suite changes, restored at the end


func _run() -> void:
	_label = "social"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	_test_daily()
	await _test_menu()
	if not await _host():
		finish(); return
	await _test_board()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "the shift runs")
	await wait_sec(0.5) # the shift start puts everybody on their spawn: let it settle before placing anybody
	await wait_frames(3)
	_lengthen_stuns(b)
	await _test_help_kinds(b)
	await _test_fake_helper(b)
	await _test_slump()
	await _test_refusals(b)
	await _test_cooldown(b)
	_test_report()
	_restore(b)
	await _test_talk_mark()
	await _test_radio_mark()
	finish()


# --- today's run -------------------------------------------------------------------------------------------------------

func _test_daily() -> void:
	step("RunSeed.daily: today's run")
	var morning := int(Time.get_unix_time_from_datetime_string("2026-10-11T00:00:00"))
	var noon := int(Time.get_unix_time_from_datetime_string("2026-10-11T12:30:00"))
	var night := int(Time.get_unix_time_from_datetime_string("2026-10-11T23:59:59"))
	var day := RunSeed.daily(noon)
	check(day >= 1 and day <= RunSeed.SEED_COUNT and RunSeed.to_code(day).length() == 4, "11 October 2026: seed %d, run %s" % [day, RunSeed.to_code(day)])
	check(RunSeed.daily(morning) == day and RunSeed.daily(night) == day, "00:00:00 to 23:59:59 UTC is one day")
	check(RunSeed.daily(morning - 1) != day and RunSeed.daily(night + 1) != day and RunSeed.daily(morning - 1) != RunSeed.daily(night + 1), "the second before and the second after are other days")
	var days: Dictionary = {}
	for i in 3000:
		days[RunSeed.daily(morning + i * RunSeed.DAY_SEC)] = true
	check(days.size() == 3000, "eight years of days, no seed twice")
	check(RunSeed.daily(0) == RunSeed.daily(RunSeed.DAY_SEC - 1) and RunSeed.daily(-1) != RunSeed.daily(0) and RunSeed.daily(-1) >= 1, "1 January 1970 is one day; the second before it another, still in range")
	var big := RunSeed.daily(9223372036854775807)
	check(big >= 1 and big <= RunSeed.SEED_COUNT, "the largest time folds into range (%d)" % big)
	check(RunSeed.to_code(day) == "WXRK", "pinned: that day is run %s" % RunSeed.to_code(day))
	check(RunSeed.is_daily(day, noon) and RunSeed.is_daily(day + RunSeed.SEED_COUNT, noon) and not RunSeed.is_daily(day, night + 1) and not RunSeed.is_daily(0, noon),
			"is_daily: today's seed (folded too), not tomorrow, never 0")
	check(RunSeed.weekly(int(Time.get_unix_time_from_datetime_string("2026-10-02T15:30:00"))) == 729042, "weekly() is kept as it was")


func _test_menu() -> void:
	step("the menu: TODAY")
	var menu: Control = (load(MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await wait_frames(3)
	var edit: LineEdit = menu.get_node_or_null("%RunEdit")
	var hint: Label = menu.get_node_or_null("%RunHint")
	var today: Button = menu.get_node_or_null("%WeekButton")
	if not check(edit != null and hint != null and today != null, "the run row: %RunEdit, %RunHint, %WeekButton"):
		menu.queue_free()
		return
	check(today.text == "TODAY" and (menu.get_node("%RunRow") as Control).visible, "the button reads TODAY ('%s'), the row is shown" % today.text)
	edit.text = ""
	edit.text_changed.emit("")
	var before := RunSeed.to_code(RunSeed.daily(int(Time.get_unix_time_from_system())))
	today.pressed.emit()
	var after := RunSeed.to_code(RunSeed.daily(int(Time.get_unix_time_from_system())))
	check((edit.text == before or edit.text == after) and String(menu.call(&"get_run_code")) == edit.text, "it fills in today's code (%s)" % edit.text)
	check(hint.text == "Run %s." % edit.text and not hint.text.contains("!") and not today.text.contains("!"), "the hint reads '%s'" % hint.text)
	check(edit.text != RunSeed.to_code(RunSeed.weekly(int(Time.get_unix_time_from_system()))) or before != after, "not the week's code")
	menu.queue_free()
	await wait_frames(2)


func _test_board() -> void:
	step("the alley board: today's run")
	var board := AlleyBoard.new()
	add_child(board)
	await wait_frames(1)
	check(GameState.get_run_code() == "B5VP" and board.get_run_line() == "Run B5VP.", "another day's run: '%s'" % board.get_run_line())
	var now := int(Time.get_unix_time_from_system())
	GameState.server_set_run_seed(RunSeed.daily(now))
	await wait_frames(1)
	var code := GameState.get_run_code()
	var line := board.get_run_line()
	check(code == RunSeed.to_code(RunSeed.daily(now)) and line == "Run %s. Today's run." % code, "today's: '%s'" % line)
	var next := board.get_next_lines()
	check(next.size() > 0 and next[next.size() - 1] == line and not line.contains("!"), "it closes the NEXT column, flat")
	board.refresh()
	check(board.get_shown_text(1).ends_with(line), "and the board shows it")
	GameState.server_set_run_seed(RunSeed.from_code("B5VP"))
	await wait_frames(1)
	check(board.get_run_line() == "Run B5VP.", "back to B5VP: no suffix")
	board.queue_free()
	await wait_frames(1)


# --- help up -----------------------------------------------------------------------------------------------------------

func _host() -> bool:
	step("hosting")
	Game.start_host("Tester", port_arg(9201))
	if not await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player"):
		return false
	world = Game.world
	items = world.items
	me = Game.local_player
	interactor = me.get_interactor()
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	Net.players[CARL] = {"name": "Carl", "color": Net.PALETTE[CARL - 1]}
	bob = world.server_spawn_player(BOB)
	carl = world.server_spawn_player(CARL)
	Net.players_changed.emit()
	await wait_frames(3)
	for p: Player in [me, bob, carl]:
		var pid := p.peer_id
		p.helped_up.connect(func(by: int) -> void:
			_helped.append([pid, by])
			_helped_voice = Sfx.get_last_voice())
	return check(bob != null and carl != null and interactor != null and world.get_players().size() == 3, "host + Bob + Carl")


## Longer stuns for the suite (the game's are 0.35 to 1 s): every step gets to look at a worker who is down.
func _lengthen_stuns(b: BalanceConfig) -> void:
	for key: StringName in [&"shove_stun_sec", &"hit_stun_sec", &"slip_stun_sec", &"hostile_bite_stun_sec", &"help_up_cooldown_sec"]:
		_saved[key] = b.get(key)
	b.shove_stun_sec = 3.0
	b.hit_stun_sec = 1.5
	b.slip_stun_sec = 3.0
	b.hostile_bite_stun_sec = 3.0
	b.help_up_cooldown_sec = 0.4


func _restore(b: BalanceConfig) -> void:
	for key: StringName in _saved:
		b.set(key, _saved[key])


func _test_help_kinds(b: BalanceConfig) -> void:
	for kind in ["a shove", "a thrown item", "a slip", "a drive-by round", "a bite"]:
		step("help up after %s" % kind)
		_put(bob, BOB_AT)
		_put(carl, FAR_AT)
		_put_me(ME_AT, 0.0)
		await wait_until(func() -> bool: return bob.can_be_staggered() and not bob.is_stunned(), 6.0, "Bob is up and can go down again")
		await wait_physics(2)
		interactor.refresh() # a body just placed reaches the ray queries after a physics step: look again
		check(interactor.get_help_target() == null and interactor.prompt_text.begins_with("[F] Shove Bob"), "standing: '%s'" % interactor.prompt_text)
		await _knock_down(kind, b)
		if not check(bob.is_stunned(), "%s puts Bob down" % kind):
			continue
		await wait_physics(2)
		interactor.refresh()
		check(interactor.get_help_target() == bob and interactor.prompt_text == "[E] Help Bob up" and interactor.prompt_enabled,
				"the prompt over him: '%s' (%s)" % [interactor.prompt_text, interactor.prompt_enabled])
		var stat0 := GameState.get_stat(1, Const.STAT_HELPED)
		_helped.clear()
		await _press_interact()
		check(not bob.is_stunned(), "E: he is up at once")
		check(_helped == [[BOB, 1]], "helped_up(1) on his body %s" % [_helped])
		check(GameState.get_stat(1, Const.STAT_HELPED) == stat0 + 1, "STAT_HELPED +1 for me (%d)" % GameState.get_stat(1, Const.STAT_HELPED))
		if kind == "a shove":
			var v := _helped_voice as AudioStreamPlayer3D
			check(v != null and v.stream == Sfx.get_stream(&"help_up") and v.global_position.distance_to(bob.get_chest_position()) < 0.3, "help_up plays at his chest")
			check(me.is_helping(), "my reach plays")
			await wait_sec(0.15)
			check(me.camera.rotation.x < -0.02, "my camera dips (%.3f)" % me.camera.rotation.x)
			check(not bob.is_helping(), "he does not reach")
		await wait_physics(2)
		check(interactor.get_help_target() == null and not interactor.prompt_text.contains("Help"), "the prompt is gone ('%s')" % interactor.prompt_text)
		Hostiles.server_despawn_all()
		await wait_sec(b.help_up_cooldown_sec + 0.1)


func _knock_down(kind: String, b: BalanceConfig) -> void:
	match kind:
		"a shove":
			me.request_shove(BOB)
		"a thrown item":
			var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, BOB_AT + Vector3(0.0, 0.0, -2.0))
			await wait_frames(1)
			items.server_throw_item(product, BOB_AT + Vector3(0.0, 1.0, -1.2), Vector3(0.0, 1.6, 8.0), 1)
			await wait_until(func() -> bool: return not product.is_flying(), 3.0, "the bundle lands")
			items.server_despawn_item(product)
		"a slip":
			Events.call(&"_server_slip", bob, Vector3.FORWARD)
		"a drive-by round":
			var hit := Events.server_fire_lane({"from": BOB_AT + Vector3(-3.0, 1.0, 0.0), "to": BOB_AT + Vector3(3.0, 1.0, 0.0)})
			check((hit.get("workers", []) as Array) == [BOB], "the round takes Bob only (%s)" % [hit.get("workers")])
		"a bite":
			var id := Hostiles.server_spawn(&"budget", BOB_AT + Vector3(-1.2, 0.0, 0.0))
			var h := Hostiles.get_hostile(id) as HostilePlant
			if check(h != null, "a hostile plant next to Bob"):
				h.call(&"_bite", bob, Vector3.RIGHT, b)
				check(GameState.get_stat(BOB, Const.STAT_BITTEN) >= 1, "it bit him")


func _test_fake_helper(b: BalanceConfig) -> void:
	step("a fake worker helps the host up")
	_put(bob, BOB_AT)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	Player.server_stagger(me, Vector3.BACK, false, CARL, 3.0)
	check(me.is_stunned(), "I am down")
	_helped.clear()
	var stat0 := GameState.get_stat(BOB, Const.STAT_HELPED)
	check(bob.server_help_up(me), "Bob helps me up (server_help_up)")
	check(not me.is_stunned() and _helped == [[1, BOB]], "I am up: helped_up(%d) %s" % [BOB, _helped])
	check(GameState.get_stat(BOB, Const.STAT_HELPED) == stat0 + 1, "STAT_HELPED for Bob")
	check(bob.is_helping(), "his reach plays on his body")
	await wait_sec(Player.HELP_REACH_SEC * 0.5)
	check(bob.arm_r.rotation.x > 0.8, "his right arm comes forward (%.2f)" % bob.arm_r.rotation.x)
	check(me.camera.rotation.x > 0.02, "my camera lifts (%.3f)" % me.camera.rotation.x)
	await wait_sec(Player.HELP_REACH_SEC)
	check(not bob.is_helping() and absf(bob.arm_r.rotation.x) < 0.2, "and back down (%.2f)" % bob.arm_r.rotation.x)
	await wait_sec(b.help_up_cooldown_sec)


func _test_slump() -> void:
	step("down: the body slumps (Bob, a remote body here)")
	_put(bob, BOB_AT)
	_put(carl, FAR_AT)
	_put_me(ME_AT, 0.0)
	await wait_until(func() -> bool: return bob.can_be_staggered() and me.can_be_staggered(), 8.0, "Bob and I can go down")
	await wait_physics(2)
	var shape := bob.collision.shape as CapsuleShape3D
	var shape_h := shape.height
	var shape_at := bob.collision.position
	var label_at := bob.name_label.position
	var feet := bob.global_position
	check(is_zero_approx(bob.get_slump()) and absf(bob.visual.position.y) < 0.02 and is_zero_approx(bob.visual.rotation.x), "standing: no slump")
	Player.server_stagger(bob, Vector3.FORWARD, false, 0, 1.0)
	await wait_sec(Player.SLUMP_IN_SEC + 0.08)
	check(bob.get_slump() >= 1.0 and bob.visual.position.y < -0.35 and bob.visual.rotation.x < -0.25 and absf(bob.visual.rotation.z) > 0.1,
			"down: sunk %.2f m, tipped forward %.2f, to the side %.2f" % [-bob.visual.position.y, -bob.visual.rotation.x, bob.visual.rotation.z])
	check(is_equal_approx(shape.height, shape_h) and bob.collision.position.is_equal_approx(shape_at) and bob.collision.shape == shape,
			"the capsule is untouched (%.2f m)" % shape.height)
	check(bob.name_label.position.is_equal_approx(label_at) and bob.global_position.is_equal_approx(feet), "the name label and the body's own place stay")
	await wait_until(func() -> bool: return not bob.is_stunned(), 2.0, "the stun runs out")
	var up := await _watch_getting_up(bob)
	check(bool(up[0]), "getting up eases over %d ms" % int(up[1]))
	check(is_zero_approx(bob.get_slump()) and absf(bob.visual.position.y) < 0.02 and is_zero_approx(bob.visual.rotation.x), "back up after the stun")

	step("down, then helped up")
	await wait_until(func() -> bool: return bob.can_be_staggered(), 4.0, "Bob can go down again")
	Player.server_stagger(bob, Vector3.FORWARD, false, 0, 5.0)
	await wait_sec(0.3)
	check(bob.get_slump() >= 1.0 and bob.visual.position.y < -0.35, "down for a long stun")
	check(me.server_help_up(bob), "I help him up")
	up = await _watch_getting_up(bob)
	check(bool(up[0]), "pulled up: it eases over %d ms" % int(up[1]))
	check(is_zero_approx(bob.get_slump()) and absf(bob.visual.position.y) < 0.02 and is_zero_approx(bob.visual.rotation.x), "standing long before the stun would have ended")

	step("my own body down: the camera drops too")
	var cam_at := me.camera.position
	var head_at := me.head.position
	var my_shape_h := (me.collision.shape as CapsuleShape3D).height
	Player.server_stagger(me, Vector3.BACK, false, 0, 1.0)
	me.velocity = Vector3.ZERO
	await wait_sec(Player.SLUMP_IN_SEC + 0.08)
	check(me.get_slump() >= 1.0 and me.visual.position.y < -0.35 and me.visual.rotation.x < -0.25, "my body (its shadow) slumps")
	check(me.camera.position.y < cam_at.y - 0.2 and me.head.position.is_equal_approx(head_at) and is_equal_approx((me.collision.shape as CapsuleShape3D).height, my_shape_h),
			"my camera drops %.2f m; the head and the capsule stay" % (cam_at.y - me.camera.position.y))
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "my stun runs out")
	await wait_sec(Player.SLUMP_OUT_SEC + 0.08)
	check(me.camera.position.is_equal_approx(cam_at) and absf(me.visual.position.y) < 0.001 and is_zero_approx(me.visual.rotation.z), "and everything is back where it was")

	step("a shove: a quick dip")
	await wait_until(func() -> bool: return bob.can_be_staggered(), 8.0, "Bob can go down again")
	Player.server_stagger(bob, Vector3.FORWARD, false, 0, 0.35)
	var deepest := 0.0
	var t0 := Time.get_ticks_msec()
	while (bob.is_stunned() or bob.get_slump() > 0.0) and Time.get_ticks_msec() - t0 < 2000:
		deepest = maxf(deepest, bob.get_slump())
		await get_tree().process_frame
	check(deepest >= 1.0 and is_zero_approx(bob.get_slump()), "all the way down and up again in %d ms" % (Time.get_ticks_msec() - t0))


## Frame by frame until `p` stands again (at most 1 s): [eased (a frame between down and up was drawn), ms].
func _watch_getting_up(p: Player) -> Array:
	var t0 := Time.get_ticks_msec()
	var eased := false
	while p.get_slump() > 0.0 and Time.get_ticks_msec() - t0 < 1000:
		await get_tree().process_frame
		eased = eased or (p.get_slump() > 0.0 and p.get_slump() < 1.0)
	return [eased and is_zero_approx(p.get_slump()), Time.get_ticks_msec() - t0]

func _test_refusals(b: BalanceConfig) -> void:
	step("refusals")
	_put(bob, BOB_AT)
	_put(carl, CARL_AT)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	var stat0 := GameState.get_stat(1, Const.STAT_HELPED)
	_helped.clear()
	check(not me.server_help_up(bob), "Bob is not down: nothing")
	await wait_until(func() -> bool: return bob.can_be_staggered(), 6.0, "Bob can go down")
	Player.server_stagger(bob, Vector3.FORWARD, false, 0, 6.0)
	check(not me.server_help_up(me), "helping myself: nothing")
	bob._rpc_request_help_up(BOB)
	check(bob.is_stunned(), "a request on Bob's body from the host's peer (not his): nothing")
	me._rpc_request_help_up(77)
	me._rpc_request_help_up(CARL)
	check(bob.is_stunned() and _helped.is_empty(), "an unknown worker and one who is not down: nothing")
	_put(bob, ME_AT + Vector3(0.0, 0.0, -(b.shove_range + Player.HELP_RANGE_SLACK + 0.3)))
	await wait_physics(1)
	check(not me.server_help_up(bob), "out of reach (%.1f m): nothing" % me.global_position.distance_to(bob.global_position))
	_put(bob, BOB_AT)
	await wait_physics(1)
	check(GameState.server_send_to_backroom(BOB, 20.0), "Bob goes to the back room")
	await wait_frames(2)
	_put(bob, BOB_AT)
	await wait_physics(1)
	check(not me.server_help_up(bob), "the target in the back room: nothing")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(2)
	_put(bob, BOB_AT)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	check(GameState.server_send_to_backroom(1, 20.0), "I go to the back room")
	await wait_frames(2)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	check(not me.server_help_up(bob) and not me.can_request_help_up(), "the helper in the back room: nothing, and my prompt is greyed")
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	await wait_until(func() -> bool: return me.can_be_staggered(), 6.0, "I can go down")
	Player.server_stagger(me, Vector3.BACK, false, 0, 1.0)
	check(not me.can_request_help_up() and not me.request_help_up(BOB) and not me.server_help_up(bob), "the helper down: nothing (asked or not)")
	await wait_physics(2)
	check(interactor.prompt_text == "[E] Help Bob up" and not interactor.prompt_enabled, "the prompt is greyed meanwhile")
	await wait_until(func() -> bool: return not me.is_stunned(), 3.0, "I am up again")
	# A wall between: the nearest wall north of me, one of us each side of it.
	var space := me.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(-3.0, 1.0, 0.0), Vector3(-3.0, 1.0, -30.0), Const.LAYER_WORLD))
	if check(not hit.is_empty(), "a wall north of the floor"):
		var wall: Vector3 = hit["position"]
		_put_me(Vector3(wall.x, 0.0, wall.z + 0.7), 0.0)
		_put(bob, Vector3(wall.x, 0.0, wall.z - 0.8))
		await wait_physics(2)
		check(me.global_position.distance_to(bob.global_position) <= b.shove_range + Player.HELP_RANGE_SLACK, "within reach (%.1f m)" % me.global_position.distance_to(bob.global_position))
		check(not me.server_help_up(bob), "a wall between: nothing")
	check(bob.is_stunned() and _helped.is_empty() and GameState.get_stat(1, Const.STAT_HELPED) == stat0, "nobody stood up, nothing counted")
	_put(bob, BOB_AT)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	check(me.server_help_up(bob) and not bob.is_stunned(), "in the open, close: he is up")


func _test_cooldown(b: BalanceConfig) -> void:
	step("the cooldown")
	b.help_up_cooldown_sec = 2.0
	_put(bob, BOB_AT)
	_put(carl, CARL_AT)
	_put_me(ME_AT, 0.0)
	await wait_physics(2)
	await wait_until(func() -> bool: return bob.can_be_staggered() and carl.can_be_staggered(), 10.0, "both can go down (a worker helped up keeps the immunity of the stun he had)")
	await wait_sec(0.5)
	Player.server_stagger(bob, Vector3.FORWARD, false, 0, 4.0)
	Player.server_stagger(carl, Vector3.FORWARD, false, 0, 4.0)
	var t0 := Time.get_ticks_msec()
	check(me.server_help_up(bob), "Bob first")
	check(not me.server_help_up(carl) and carl.is_stunned(), "Carl right after: not yet (help_up_cooldown_sec %.1f)" % b.help_up_cooldown_sec)
	await wait_physics(1)
	check(not me.can_request_help_up(), "my own peer knows: the prompt is greyed")
	await wait_until(func() -> bool: return me.server_help_up(carl), 3.0, "after the cooldown Carl is helped up")
	var waited := Time.get_ticks_msec() - t0
	check(waited >= 1950 and waited < 2600 and not carl.is_stunned(), "about help_up_cooldown_sec later (%d ms)" % waited)


func _test_report() -> void:
	step("the report")
	var verdicts := Story.get_report_verdicts()
	check(verdicts.has("Tester helped people up the most."), "a verdict line names the worker who helped most %s" % [verdicts])
	for v in verdicts:
		check(not v.contains("!"), "flat: '%s'" % v)
	check(GameState.get_stat(1, Const.STAT_HELPED) > GameState.get_stat(BOB, Const.STAT_HELPED), "I helped more than Bob (%d / %d)" % [GameState.get_stat(1, Const.STAT_HELPED), GameState.get_stat(BOB, Const.STAT_HELPED)])


# --- the talk mark -----------------------------------------------------------------------------------------------------

func _test_talk_mark() -> void:
	step("the talk mark over a worker")
	await wait_sec(0.4)
	check(me.get_talk_mark() == null and me.name_label.get_node_or_null(^"TalkMark") == null, "none on the local worker")
	var mb := bob.get_talk_mark()
	var mc := carl.get_talk_mark()
	if not check(mb != null and mc != null, "one on Bob, one on Carl"):
		return
	check(mb.get_parent() == bob.name_label and not mb.visible and not mc.visible, "under %NameLabel, hidden while nobody talks")
	check(mb.billboard == BaseMaterial3D.BILLBOARD_ENABLED and not mb.shaded and mb.texture != null and mb.texture == mc.texture
			and not mb.is_processing(), "a billboard, unshaded, one texture for every mark, no processing")
	var label_h := bob.name_label.font_size * bob.name_label.pixel_size
	var bottom := mb.global_position.y - TalkMark.MARK_HEIGHT * 0.5
	check(bottom > bob.name_label.global_position.y + label_h * 0.5, "above the label (its foot %.2f m over the label's middle, the label %.2f m tall)" % [bottom - bob.name_label.global_position.y, label_h])
	var px := TalkMark.MARK_HEIGHT / (2.0 * 10.0 * tan(deg_to_rad(me.camera.fov) * 0.5)) * 720.0
	check(px >= 12.0, "readable at 10 m: %.1f px tall at 720p, FOV %.0f" % [px, me.camera.fov])
	Voice.debug_inject_frame(BOB, _frame(0))
	check(Voice.is_speaking(BOB) and mb.visible and not mc.visible, "Bob talks: his mark shows at once, Carl's does not")
	for i in range(1, 10):
		await wait_sec(0.02)
		Voice.debug_inject_frame(BOB, _frame(i))
		Voice.debug_inject_frame(CARL, _frame(i))
	check(mb.visible and mc.visible, "both talk: both marks")
	await wait_until(func() -> bool: return not mb.visible and not mc.visible, 2.0, "silence: both gone after the hold")
	check(not Voice.is_speaking(BOB) and mb.show_count == 1 and mc.show_count == 1, "shown once each")
	Voice.speaking_changed.emit(1, true)
	check(me.get_talk_mark() == null and not mb.visible, "my own speaking changes nothing on any body")
	Voice.speaking_changed.emit(1, false)

	step("a worker whose body spawns while he talks (the late join)")
	Net.players[DAVE] = {"name": "Dave", "color": Net.PALETTE[DAVE - 1]}
	Net.players_changed.emit()
	Voice.debug_inject_frame(DAVE, _frame(0))
	check(Voice.is_speaking(DAVE), "Voice hears Dave before his body exists")
	var dave := world.server_spawn_player(DAVE)
	await wait_frames(1)
	check(dave != null and dave.is_talk_mark_shown(), "his body starts with the mark shown")
	await wait_until(func() -> bool: return dave != null and not dave.is_talk_mark_shown(), 2.0, "and drops it with the silence")


func _test_radio_mark() -> void:
	step("the talk mark over a radio")
	var radios: Array[Item] = items.get_items_of_type(Const.ITEM_RADIO)
	if not check(radios.size() >= 2, "two radios on the floor (%d)" % radios.size()):
		return
	var a := radios[0] as Radio
	var rb := radios[1] as Radio
	_put(bob, BOB_AT)
	check(items.server_give_item(a, BOB), "Bob holds radio A")
	items.server_drop_item(rb, Vector3(-1.0, 0.0, 1.0))
	rb.server_set_rest(rb.rest_position, Vector3(0.0, 0.0, PI * 0.5))
	await wait_frames(3)
	check(a.get_talk_mark() == null and rb.get_talk_mark() == null, "no mark before a radio ever carried a voice")
	Voice.debug_inject_frame(BOB, _frame(0))
	var ls := Voice.get_radio_listeners()
	var mark := rb.get_talk_mark()
	check(Voice.is_on_radio(BOB) and ls.size() == 1 and ls[0] == rb, "Bob is on the radio: radio B carries him")
	check(mark != null and mark.visible and rb.is_talk_mark_shown() and not a.is_talk_mark_shown(), "the mark over radio B, none over Bob's own")
	check(mark != null and mark.top_level and mark.is_processing(), "it follows the radio while shown")
	if mark != null:
		var lift := mark.global_position - rb.global_position
		check(lift.is_equal_approx(Radio.TALK_MARK_LIFT), "straight above it although it lies on its side (%s)" % lift)
	for i in range(1, 8):
		await wait_sec(0.02)
		Voice.debug_inject_frame(BOB, _frame(i))
	check(rb.is_talk_mark_shown() == (rb in Voice.get_radio_listeners()), "shown exactly while it is a listener")
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "the transmission ends after the gap")
	await wait_frames(1)
	check(mark != null and not mark.visible and not mark.is_processing(), "the mark goes with it and stops following")

	step("a radio carrying a voice in my own hands")
	_put_me(Vector3(-1.0, 0.0, 2.0), 0.0)
	check(items.server_give_item(rb, 1), "I pick radio B up")
	await wait_frames(2)
	for i in 8:
		Voice.debug_inject_frame(BOB, _frame(20 + i))
		await wait_sec(0.02)
	check(rb.is_receiving() and mark != null and mark.is_talking() and not mark.visible, "it receives, but no mark in front of my camera")
	items.request_drop()
	for i in 6:
		Voice.debug_inject_frame(BOB, _frame(40 + i))
		await wait_sec(0.02)
	check(rb.holder_id == 0 and mark != null and mark.visible, "put down: the mark is back over it")
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB) and not rb.is_talk_mark_shown(), 2.0, "and gone with the transmission")
	items.server_drop_item(a, Vector3(-6.0, 0.0, 4.0))
	await wait_frames(2)


# --- helpers -----------------------------------------------------------------------------------------------------------

## E through the input pipeline (the Interactor's _unhandled_input), after a fresh look under the crosshair.
func _press_interact() -> void:
	interactor.refresh()
	for pressed: bool in [true, false]:
		var ev := InputEventAction.new()
		ev.action = &"interact"
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await get_tree().process_frame
	await get_tree().process_frame


func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(VoiceScript.FRAME_SAMPLES)
	for i in VoiceScript.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 220.0 * float(i + phase * VoiceScript.FRAME_SAMPLES) / float(VoiceScript.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)


## A fake (unowned) worker at `pos`, facing +Z (towards me): place_at writes net_position too.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, PI), Vector3(pos.x, 0.05, pos.z)))


## My own body at `pos` facing `yaw` (0 = -Z), level look.
func _put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
