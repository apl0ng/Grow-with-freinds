extends "res://tools/tests/qa_base.gd"
## M15 mayhem2 suite (mayhem2 agent): the raid, the sprinklers and the collector on a single headless host with fake
## workers (Net.players + World.server_spawn_player, no owning peer). Deterministic: time is advanced with
## Events.tick().
##   kinds / weights / picker for twelve kinds, the Room API (raid points, the collector's spot), --first-event;
##   the raid: params, banner, lights and siren, the warning, the looks (order, timing, signals), what is taken (a
##   bundle on the open floor, one in a worker's hands in sight) and what is not (behind a crate stack, in the hall
##   on the floor / on a rack / in hands, deposited), the write-up, trays untouched, single looks against the real
##   crate stack on the dock, the range;
##   the sprinklers: params, every tray watered, particles per play area, the wet floor (a sprinting worker slips in
##   the main room, in the hall and on the dock; a walking, crouched, airborne or back-room one does not), the wet
##   tail, dry again;
##   the collection: params, banner, the collector node (appears, stands on the dock, leaves), prompt states, the pay
##   request (refused from afar, from the back room, cash short, with nobody there), the real hold pays, unpaid takes
##   the dearest bundle (out of a worker's hands too), with no bundle the most advanced tray (a counted strain is
##   fined), with nothing he leaves empty-handed;
##   late-join replay by direct RPC call; force end / shift end / game reset / menu.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/mayhem2_body.gd --port=7977 --events --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const STEP := 0.05
## Bundles for the raid (Room-local = global: the Room sits at the origin).
const SPOT_OPEN := Vector3(-3.0, 0.0, 3.0)        # the open floor of the main room
const SPOT_DOCK_OPEN := Vector3(-2.5, 0.0, 12.0)  # the open dock, in front of the roller door
const SPOT_BEHIND_CRATE := Vector3(2.3, 0.0, 7.15)   # behind Decor/CrateA on its pallets, against the south wall
const SPOT_HALL := Vector3(14.0, 0.0, -1.25)      # the hall floor, in line with the pen door (a clear line from the middle)
const SPOT_STACK_NORTH := Vector3(-5.0, 0.0, 11.0)   # north of the dock's crate stack: hidden from the roller door
const SPOT_STACK_SOUTH := Vector3(-4.5, 0.0, 12.6)   # south of it: hidden from the passage
const SPOT_FAR := Vector3(-4.0, 0.0, -1.5)        # a clear line from the roller door, but further than RAID_RANGE

var _started: Array = []      # [kind, params]
var _ended: Array = []        # [kind]
var _swept: Array = []        # [point_index, taken]
var _took: Array = []         # [item_name, holder_peer]
var _wet: Array = []          # bool
var _paid: Array = []         # [peer, fee]
var _collected: Array = []    # [what, strain, where]
var _written: Array = []      # [peer, reason, count]
var _world: World
var _room: Room
var _hud: HUD
var _chute: TurnInStation


func _run() -> void:
	_label = "mayhem2"
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.raid_swept.connect(func(i: int, n: int) -> void: _swept.append([i, n]))
	Events.raid_took.connect(func(n: String, h: int) -> void: _took.append([n, h]))
	Events.floor_wet_changed.connect(func(w: bool) -> void: _wet.append(w))
	Events.collector_paid.connect(func(p: int, fee: int) -> void: _paid.append([p, fee]))
	Events.collector_took.connect(func(what: StringName, strain: StringName, where: String) -> void: _collected.append([what, strain, where]))
	GameState.worker_written_up.connect(func(p: int, reason: String, count: int) -> void: _written.append([p, reason, count]))
	var b: BalanceConfig = Config.balance

	step("kinds + weights")
	check(Config.has_arg("events") and Events.are_events_enabled(), "this suite runs with --events")
	check(Events.KINDS.size() == 12 and Events.KINDS.has(Events.EVENT_RAID) and Events.KINDS.has(Events.EVENT_SPRINKLERS) and Events.KINDS.has(Events.EVENT_COLLECTION), "KINDS: the nine earlier kinds + raid, sprinklers, collection")
	check(Events.EVENT_RAID == &"raid" and Events.EVENT_SPRINKLERS == &"sprinklers" and Events.EVENT_COLLECTION == &"collection", "the three kind names")
	var total := 0
	for k in Events.KINDS:
		total += int(Events.WEIGHTS.get(k, 0))
	check(total == 100 and Events.WEIGHTS.size() == Events.KINDS.size(), "weights sum to 100 over %d kinds (%d)" % [Events.KINDS.size(), total])
	var expected := {Events.EVENT_INSPECTION: 22, Events.EVENT_POWER_CUT: 13, Events.EVENT_AUDIT: 7, Events.EVENT_RAT: 7,
			Events.EVENT_HEADCOUNT: 10, Events.EVENT_WATER_OFF: 6, Events.EVENT_SHORTAGE: 5, Events.EVENT_LEAK: 7, Events.EVENT_DRIVEBY: 7,
			Events.EVENT_RAID: 6, Events.EVENT_SPRINKLERS: 5, Events.EVENT_COLLECTION: 5}
	var weights_ok := true
	for k in expected:
		if int(Events.WEIGHTS.get(k, -1)) != int(expected[k]):
			weights_ok = false
	check(weights_ok, "weights: inspection 22 / power_cut 13 / audit 7 / rat 7 / headcount 10 / water_off 6 / shortage 5 / leak 7 / driveby 7 / raid 6 / sprinklers 5 / collection 5")
	var kinds_seen: Dictionary = {}
	var repeats := 0
	for k in Events.KINDS:
		for i in 120:
			var pick := Events.pick_kind(k)
			kinds_seen[pick] = true
			if pick == k or not Events.KINDS.has(pick):
				repeats += 1
	check(repeats == 0, "pick_kind() never repeats the previous kind and stays in KINDS")
	check(kinds_seen.size() == 12, "pick_kind() reaches every kind (%d seen)" % kinds_seen.size())
	check(Story.line("raid") == "They are outside. Get it out of sight." and Story.line("sprinklers") == "Sprinklers. Everything is watered. Do not run." and Story.line("collector_paid") == "Paid. He left.", "Story has the raid, sprinkler and collector lines")
	check(Story.line("collection") % Story.mayhem_amount_words(40) == "He wants forty. He is on the dock.", "the Boss names the fee in words")
	check(Story.mayhem2_raid_line(3, PackedStringArray(["Dale"])) == "They took three. Dale was holding one.", "raid line: three taken, one holder (%s)" % Story.mayhem2_raid_line(3, PackedStringArray(["Dale"])))
	check(Story.mayhem2_raid_line(2, PackedStringArray(["Dale", "Kim"])) == "They took two. Dale and Kim were holding." and Story.mayhem2_raid_line(4, PackedStringArray(["Dale", "Kim", "Bo"])) == "They took four. Dale, Kim and Bo were holding.", "raid line: several holders")
	check(Story.mayhem2_raid_line(1, PackedStringArray()) == "They took one." and Story.mayhem2_raid_line(0, PackedStringArray()) == "They looked. They found nothing.", "raid line: nobody holding, nothing taken")
	var golden: SeedDef = null
	var plain: SeedDef = null
	for s in b.seeds:
		if s != null and s.counted and golden == null:
			golden = s
		if s != null and not s.counted and plain == null:
			plain = s
	check(golden != null and plain != null, "balance has a counted strain and a plain one")
	check(Story.mayhem2_collector_line(Events.COLLECT_BUNDLE, golden.id, "x") == "Not paid. He took the %s." % golden.display_name, "collector line: a bundle (%s)" % Story.mayhem2_collector_line(Events.COLLECT_BUNDLE, golden.id, "x"))
	check(Story.mayhem2_collector_line(Events.COLLECT_TRAY, golden.id, "GrowPlot3") == "Not paid. He took the plant in GrowPlot 3." and Story.mayhem2_collector_line(Events.COLLECT_NOTHING, &"", "") == "Not paid. Nothing to take. He will be back.", "collector line: a tray, nothing")
	var copy_ok := true
	for k: String in Story.MAYHEM2_LINES:
		var text := String(Story.MAYHEM2_LINES[k])
		if text.contains("!") or Story.line(k) != text:
			copy_ok = false
	check(copy_ok, "every mayhem2 line is installed and has no exclamation mark")
	for n: StringName in [&"siren", &"sprinkler", &"collector_knock"]:
		check(Sfx.has_sound(n), "Sfx has %s" % n)
	check(Sfx.LOOPING.has(&"siren") and Sfx.LOOPING.has(&"sprinkler") and not Sfx.LOOPING.has(&"collector_knock"), "siren and sprinkler loop, the knock does not")
	check(GrowPlot.LOSS_COLLECTED == &"collected" and Const.WRITE_UP_RAID == "raid", "LOSS_COLLECTED and WRITE_UP_RAID exist")

	step("hosting")
	Game.start_host("Tester", port_arg(7977))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_hud = _world.get_node_or_null(^"HUD") as HUD
	_chute = _room.get_station("TurnInStation") as TurnInStation
	check(_hud != null and _chute != null, "the HUD and the chute exist")
	for id in [2, 3, 4]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	await get_tree().physics_frame
	check(_world.get_players().size() == 4, "host + 3 fake workers spawned")
	check(not Events.server_start_event(Events.EVENT_RAID) and not Events.server_start_event(Events.EVENT_SPRINKLERS) and not Events.server_start_event(Events.EVENT_COLLECTION), "no event while WAITING")

	step("the Room API")
	var points := _room.get_raid_points()
	var door := _room.get_roller_door_position()
	check(points.size() == 3, "Room.get_raid_points(): three eye points (%s)" % [points])
	if points.size() == 3:
		check(_flat(points[0], door) < 1.0 and _room.get_area_index(points[0]) == 2, "the first looks in at the roller door, on the dock (%s)" % points[0])
		var passage := Vector3.INF
		for d: Dictionary in _room.get_doorways():
			if String(d["name"]) == "dock_passage":
				passage = d["center"]
		check(_flat(points[1], passage) < 0.01, "the second stands in the dock passage (%s)" % points[1])
		check(_room.get_area_index(points[2]) == 0 and _flat(points[2], _room.get_bounds().get_center()) < 3.0, "the third stands in the middle of the main room (%s)" % points[2])
		check(is_equal_approx(points[0].y, Room.RAID_EYE_HEIGHT) and is_equal_approx(points[1].y, Room.RAID_EYE_HEIGHT) and is_equal_approx(points[2].y, Room.RAID_EYE_HEIGHT), "all at eye height")
	var spot := _room.get_collector_spot()
	check(_room.get_area_index(spot.origin) == 2 and absf(spot.origin.y) < 0.01 and _flat(spot.origin, door) < 3.0, "Room.get_collector_spot(): on the dock floor, by the roller door (%s)" % spot.origin)
	check(_room.get_node_or_null(^"Dock/RaidEye") is Marker3D and _room.get_node_or_null(^"Dock/CollectorSpot") is Marker3D, "two markers under Dock")
	check(_room.is_in_hall(SPOT_HALL) and not _room.is_in_hall(SPOT_OPEN) and not _room.is_in_hall(SPOT_DOCK_OPEN), "Room.is_in_hall()")

	step("shift start")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(600 - GameState.money)

	await _test_first_event()
	await _test_raid(b, plain)
	await _test_sprinklers(b, plain)
	await _test_collection(b, plain, golden)
	await _test_replay(b)
	await _test_resets(b, plain)
	finish()


# --- --first-event --------------------------------------------------------------------------------------------------

func _test_first_event() -> void:
	step("--first-event")
	for kind: StringName in [Events.EVENT_RAID, Events.EVENT_SPRINKLERS, Events.EVENT_COLLECTION]:
		Config.user_args["first-event"] = String(kind)
		Events.set(&"_forced_first_used", false)
		Events.set(&"_next_in", 0.5)
		_started.clear()
		Events.tick(1.0)
		check(Events.active_event == kind and _started.size() == 1 and _started[0][0] == kind, "--first-event=%s starts a %s" % [kind, Events.active_event])
		Events.server_end_event()
		await wait_frames(2)
		check(not Events.is_event_active(), "%s force-ended" % kind)
	Config.user_args.erase("first-event")
	Config.user_args.erase("events")   # the scheduler stays quiet from here (server_start_event does not need it)
	Events.set(&"_next_in", -1.0)
	check(not Events.are_events_enabled() and not Events.is_event_active(), "scheduler off, nothing running")
	check(_swept.is_empty() and _took.is_empty() and _collected.is_empty() and _paid.is_empty(), "the force-ended raid looked at nothing, the force-ended collection took nothing")
	check(Events.is_floor_wet() and Events.get_wet_left() > 0.0, "force-ended sprinklers: the floor stays wet for its tail")
	Events.call(&"_mayhem2_server_reset")
	await wait_sec(Collector.LEAVE_SEC + Collector.TURN_SEC + 0.4)
	check(not Events.is_floor_wet() and Events.get_wet_left() == 0.0, "reset: the floor is dry")
	check(_leftovers() == 0, "no lights, water or collector left on the floor (%d)" % _leftovers())
	_clear_log()


# --- the raid ------------------------------------------------------------------------------------------------------------

func _test_raid(b: BalanceConfig, seed0: SeedDef) -> void:
	step("raid: the floor before")
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	var w4 := _world.get_player(4)
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(8.0, 0.05, 6.2)   # the corridor south of the pen: out of the way
	_put(w2, Vector3(-3.0, 0.0, 0.0))    # in sight, a bundle in his hands
	_put(w3, Vector3(16.0, 0.0, 3.0))    # in the hall, a bundle in his hands
	_put(w4, Vector3(-1.0, 0.0, 2.0))    # in sight, empty hands
	_reset_plots()
	var p1 := plot(1)
	var p2 := plot(2)
	check(p1.server_plant(seed0.id) and p2.server_plant(seed0.id), "two trays planted")
	p2.stage = GrowPlot.Stage.READY
	p1.stage_progress = 0.4
	var rack := _room.get_station("DryingRack1") as DryingRack
	check(rack != null and _room.is_in_hall(rack.global_position), "a drying rack stands in the hall")
	var open := _bundle(seed0, SPOT_OPEN)
	var dock := _bundle(seed0, SPOT_DOCK_OPEN)
	var hidden := _bundle(seed0, SPOT_BEHIND_CRATE)
	var hall := _bundle(seed0, SPOT_HALL)
	var sold := _bundle(seed0, Vector3(0.0, 0.0, 3.5))
	var racked := _bundle(seed0, w3.global_position, 3)
	await _settle()
	check(rack != null and rack.server_hang(w3), "worker 3 hangs a bundle on the rack")
	var held := _bundle(seed0, w2.global_position, 2)
	var held_hall := _bundle(seed0, w3.global_position, 3)
	await _settle()
	check(_world.items.get_held_by(2) == held and _world.items.get_held_by(3) == held_hall and racked.get(&"rack") == true, "worker 2 and worker 3 carry a bundle each, one hangs on the rack")
	check(items_of(Const.ITEM_PRODUCT).size() == 8, "eight bundles on the floor plan (%d)" % items_of(Const.ITEM_PRODUCT).size())
	var points := _room.get_raid_points()
	var space := _world.get_world_3d().direct_space_state
	var hall_line := space.intersect_ray(PhysicsRayQueryParameters3D.create(points[2], SPOT_HALL + Vector3.UP * Events.RAID_ITEM_LIFT, Const.LAYER_WORLD))
	check(hall_line.is_empty() and points[2].distance_to(SPOT_HALL) < Events.RAID_RANGE, "the hall bundle lies in a clear line from the middle of the main room, %.1f m away: only the hall rule hides it" % points[2].distance_to(SPOT_HALL))
	var names := {"open": String(open.name), "dock": String(dock.name), "held": String(held.name)}
	var loops0: int = Sfx.get_active_loop_count()
	var money0 := GameState.money
	var strikes0 := GameState.get_write_ups(2)
	_clear_log()

	step("raid: the warning")
	check(Events.server_start_event(Events.EVENT_RAID), "raid starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	var total := b.raid_warning_sec + b.raid_sec
	check(is_equal_approx(float(p.get("seconds", 0.0)), total) and is_equal_approx(float(p.get("warning", -1.0)), b.raid_warning_sec) and p.size() == 2, "params {seconds: warning + looking, warning} (%s)" % [p])
	check(_hud.get_event_text().begins_with("RAID") and _hud.event_hint.visible and _hud.event_hint.text == "Get the product out of sight.", "HUD banner RAID with the hint (%s / %s)" % [_hud.get_event_text(), _hud.event_hint.text])
	check(toast_seen("Raid. Get the product out of sight.") and _barked("They are outside. Get it out of sight."), "the floor is told: toast + the Boss")
	var lights := _room.get_node_or_null(^"RaidLights") as Node3D
	check(lights != null and lights.get_node_or_null(^"Pivot/Red") is SpotLight3D and lights.get_node_or_null(^"Pivot/Blue") is SpotLight3D and lights.get_node_or_null(^"Glow") is OmniLight3D and lights.get_node_or_null(^"Strip") is MeshInstance3D, "RaidLights: a red and a blue beam on a pivot, a glow, a strip under the door")
	check(lights != null and _flat(lights.global_position, _room.get_roller_door_position()) < 1.5, "at the roller door")
	check(Sfx.get_active_loop_count() == loops0 + 1, "the siren loop plays (%d loops, %d before)" % [Sfx.get_active_loop_count(), loops0])
	check(not Events.is_raid_looking() and Events.get_raid_sweeps() == 0, "the warning: nobody looks yet")
	check(not Events.server_start_event(Events.EVENT_SPRINKLERS), "one at a time: the sprinklers are refused meanwhile")
	Events.tick(b.raid_warning_sec - 0.2)
	check(not Events.is_raid_looking() and _swept.is_empty() and items_of(Const.ITEM_PRODUCT).size() == 8, "still only sirens 0.2 s before the warning ends")
	var sales0 := GameState.round_sales
	check(_chute.server_sell_item(sold, 1) and GameState.round_sales > sales0, "one bundle is deposited during the warning")
	money0 = GameState.money

	step("raid: the looks")
	Events.tick(0.25)
	check(Events.is_raid_looking() and _swept.size() == 1 and int(_swept[0][0]) == 0, "the first look comes the moment the warning ends, from the roller door (%s)" % [_swept])
	check(int(_swept[0][1]) == 1 and _took.size() == 1 and _took[0][0] == names["dock"] and int(_took[0][1]) == 0, "it takes the bundle on the open dock (%s)" % [_took])
	check(_world.items.get_held_by(2) == held and not open.is_queued_for_deletion(), "the main room is out of its sight")
	Events.tick(1.4)
	check(_swept.size() == 1, "no second look 1.45 s in")
	Events.tick(0.1)
	check(_swept.size() == 2 and int(_swept[1][0]) == 1 and int(_swept[1][1]) == 2, "the second look 1.5 s after the first, from the dock passage: two taken (%s)" % [_swept])
	check(_took.size() == 3 and _has_took(names["open"], 0) and _has_took(names["held"], 2), "the bundle on the open floor and the one in worker 2's hands (%s)" % [_took])
	check(_world.items.get_held_by(2) == null, "worker 2's hands are empty")
	check(_written.size() == 1 and int(_written[0][0]) == 2 and _written[0][1] == Const.WRITE_UP_RAID and GameState.get_write_ups(2) == strikes0 + 1, "he is written up with WRITE_UP_RAID (%s)" % [_written])
	check(GameState.money == money0 - b.write_up_fine, "the write-up fine comes out of cash on hand")
	Events.tick(1.5)
	check(_swept.size() == 3 and int(_swept[2][0]) == 2 and int(_swept[2][1]) == 0, "the third look from the middle of the main room: nothing left in sight (%s)" % [_swept])
	Events.tick(1.5)
	check(_swept.size() == 4 and int(_swept[3][0]) == 0 and int(_swept[3][1]) == 0, "the fourth from the roller door again (%s)" % [_swept])
	Events.tick(1.0)
	check(_swept.size() == 4 and Events.is_event_active(Events.EVENT_RAID), "four looks in raid_sec, still running at 5.55 s")
	check(toast_seen("They are looking in."), "the floor is told when they look in")
	Events.tick(0.5)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_RAID, "event_ended(raid) when the timer runs out")
	check(Events.get_raid_sweeps() == 4 and Events.get_raid_taken() == 3, "four looks, three bundles taken")

	step("raid: what is left")
	check(not hidden.is_queued_for_deletion() and is_instance_valid(hidden), "the bundle behind the crate stack is still there")
	check(is_instance_valid(hall) and not hall.is_queued_for_deletion(), "the bundle on the hall floor is still there")
	check(is_instance_valid(racked) and racked.get(&"rack") == true, "the bundle on the rack in the hall still hangs")
	check(_world.items.get_held_by(3) == held_hall, "worker 3 in the hall still carries his")
	check(items_of(Const.ITEM_PRODUCT).size() == 4, "four bundles survive (%d)" % items_of(Const.ITEM_PRODUCT).size())
	check(GameState.get_write_ups(3) == 0 and GameState.get_write_ups(4) == 0 and GameState.get_write_ups(1) == 0, "nobody else is written up")
	check(p1.is_growing() and is_equal_approx(p1.stage_progress, 0.4) and p2.is_ready_to_harvest(), "trays are not touched")
	check(_room.get_node_or_null(^"RaidLights") == null and Sfx.get_active_loop_count() == loops0, "the lights are gone, the siren stopped")
	check(_hud.get_event_text() == "", "the banner is gone")
	var line := "They took three. Worker 2 was holding one."
	check(_barked(line) and toast_seen(line), "the floor hears the count (%s)" % Story.last_bark)
	check(_barked("Worker 2 was holding. Written up."), "and the write-up")

	step("raid: one look at a time")
	var north := _bundle(seed0, SPOT_STACK_NORTH)
	var south := _bundle(seed0, SPOT_STACK_SOUTH)
	var far := _bundle(seed0, SPOT_FAR)
	await _settle()
	var north_name := String(north.name)
	var south_name := String(south.name)
	var far_name := String(far.name)
	var far_line := space.intersect_ray(PhysicsRayQueryParameters3D.create(points[0], SPOT_FAR + Vector3.UP * Events.RAID_ITEM_LIFT, Const.LAYER_WORLD))
	check(far_line.is_empty() and points[0].distance_to(SPOT_FAR) > Events.RAID_RANGE, "a bundle in a clear line from the roller door, %.1f m away" % points[0].distance_to(SPOT_FAR))
	_swept.clear()
	_took.clear()
	var look := Events.server_raid_sweep(0)
	check(look.get("taken") == [south_name] and int(look.get("index", -1)) == 0, "from the roller door: the bundle south of the dock's crate stack goes, the one north of it and the far one stay (%s)" % [look.get("taken")])
	check((look.get("point", Vector3.ZERO) as Vector3).distance_to(points[0]) < 0.001 and (look.get("holders", [0]) as Array).is_empty(), "the look reports its eye point and no holder")
	check(is_instance_valid(far) and not far.is_queued_for_deletion() and is_instance_valid(north) and not north.is_queued_for_deletion(), "RAID_RANGE: the far bundle is out of the roller door's reach")
	look = Events.server_raid_sweep(1)
	var from_passage: Array = look.get("taken", [])
	check(from_passage.size() == 2 and from_passage.has(north_name) and from_passage.has(far_name), "from the passage: the one north of the stack goes, and the far one, which is near enough from here (%s)" % [from_passage])
	look = Events.server_raid_sweep(5)
	check(int(look.get("index", -1)) == 2 and (look.get("taken", [0]) as Array).is_empty(), "index 5 wraps to the middle of the main room: nothing left in sight")
	check(_swept == [[0, 1], [1, 2], [2, 0]] and _took.size() == 3, "raid_swept and raid_took fire for single looks (%s)" % [_swept])
	check(items_of(Const.ITEM_PRODUCT).size() == 4, "the four hidden bundles survive every eye point")
	_despawn_products()
	_reset_plots()
	await _settle()
	_clear_log()


# --- the sprinklers ------------------------------------------------------------------------------------------------------

func _test_sprinklers(b: BalanceConfig, seed0: SeedDef) -> void:
	step("sprinklers: start")
	var me: Player = Game.local_player
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	var w4 := _world.get_player(4)
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(8.0, 0.05, 6.2)
	await wait_until(func() -> bool: return w2.can_be_staggered() and w3.can_be_staggered() and w4.can_be_staggered(), 4.0, "nobody is stagger-immune")
	check(plot(1).server_plant(seed0.id) and plot(8).server_plant(seed0.id), "a tray in the pen and one in the hall planted")
	var dry := true
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		plot(i).water = 0.0
		dry = dry and plot(i).water == 0.0
	check(dry and not Events.is_floor_wet() and not Events.is_wet_at(SPOT_OPEN), "every tray dry, the floor dry")
	var loops0: int = Sfx.get_active_loop_count()
	_clear_log()
	check(Events.server_start_event(Events.EVENT_SPRINKLERS), "sprinklers start")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.sprinkler_sec) and p.size() == 1, "params {seconds: sprinkler_sec} (%s)" % [p])
	var watered := 0
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		if is_equal_approx(plot(i).water, 1.0):
			watered += 1
	check(watered == Room.GROW_PLOT_COUNT, "every tray's water is at 1.0 (%d of %d)" % [watered, Room.GROW_PLOT_COUNT])
	check(_hud.get_event_text().begins_with("SPRINKLERS") and _hud.event_hint.visible and _hud.event_hint.text == "Wet floor. Do not run.", "HUD banner SPRINKLERS with the hint (%s / %s)" % [_hud.get_event_text(), _hud.event_hint.text])
	check(toast_seen("Sprinklers. Everything is watered. Do not run.") and _barked("Sprinklers. Everything is watered. Do not run."), "the floor is told: toast + the Boss")
	check(Events.is_floor_wet() and _wet == [true], "floor_wet_changed(true) (%s)" % [_wet])
	var water := _room.get_node_or_null(^"Sprinklers") as Node3D
	var areas := _room.get_play_areas()
	var emitters := 0
	var placed := true
	if water != null:
		for c in water.get_children():
			var rain := c as CPUParticles3D
			if rain == null:
				continue
			var area: AABB = areas[emitters] if emitters < areas.size() else AABB()
			if not rain.emitting or _room.get_area_index(Vector3(rain.global_position.x, 1.0, rain.global_position.z)) != emitters or rain.global_position.y < area.end.y - 1.0:
				placed = false
			emitters += 1
	check(water != null and emitters == areas.size() and placed, "one emitter per play area, under its ceiling, emitting (%d for %d areas)" % [emitters, areas.size()])
	check(Sfx.get_active_loop_count() == loops0 + 1, "the sprinkler loop plays")
	check(Events.is_wet_at(SPOT_OPEN) and Events.is_wet_at(SPOT_HALL) and Events.is_wet_at(SPOT_DOCK_OPEN) and not Events.is_wet_at(Vector3(0.0, 0.0, 80.0)) and not Events.is_wet_at(Vector3(0.0, 0.0, 30.0)), "wet in the main room, the hall and on the dock; not outside the floor plan")

	step("sprinklers: slips")
	var slipped: Array = []
	var on_slip := func(pid: int) -> void: slipped.append(pid)
	Events.worker_slipped.connect(on_slip)
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, Vector3(-4.0, 0.0, 4.0), 2)
	await wait_frames(1)
	_dash(w2, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.sprint_speed)
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 1 and slipped == [2], "a sprinting worker slips in the middle of the main room, far from the tank (%s)" % [slipped])
	check(_world.items.get_held_by(2) == null and can != null and not can.is_held(), "and drops what he carried")
	_dash(w3, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.walk_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "a walking worker does not slip")
	w4.crouching = true
	_dash(w4, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.sprint_speed)
	check(GameState.get_stat(4, Const.STAT_SLIPS) == 0, "a crouched worker does not slip, whatever his speed")
	w4.crouching = false
	_dash(w3, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.sprint_speed, 0.9)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 0, "a worker in the air does not slip")
	_dash(w3, Vector3(12.5, 0.0, 4.5), Vector3(18.5, 0.0, 4.5), b.sprint_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 1 and slipped == [2, 3], "sprinting in the grow hall: a slip (%s)" % [slipped])
	_dash(w4, Vector3(-8.0, 0.0, 9.2), Vector3(-2.0, 0.0, 9.2), b.sprint_speed)
	check(GameState.get_stat(4, Const.STAT_SLIPS) == 1 and slipped == [2, 3, 4], "sprinting on the loading dock: a slip (%s)" % [slipped])
	# One slip per worker per 3 s, as in the puddle: worker 2 runs again at once with his stagger immunity taken away.
	w2.set(&"_stagger_immune_until_msec", 0)
	w2.set(&"_stun_until_msec", 0)
	var slip_at := float((Events.get(&"_last_slip") as Dictionary).get(2, -1.0))
	Events.set(&"_last_slip", {2: float(Events.get(&"_mayhem_clock"))})
	_dash(w2, Vector3(-4.0, 0.0, 4.0), Vector3(-1.5, 0.0, 4.0), b.sprint_speed, 0.05, 5)
	check(slip_at >= 0.0 and GameState.get_stat(2, Const.STAT_SLIPS) == 1, "one slip per worker per 3 s holds on the wet floor too")
	check(GameState.server_send_to_backroom(2, 60.0), "worker 2 sits in the back room")
	await wait_frames(2)
	w2.set(&"_stagger_immune_until_msec", 0)
	w2.set(&"_stun_until_msec", 0)
	Events.set(&"_last_slip", {})
	_dash(w2, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.sprint_speed)
	check(GameState.get_stat(2, Const.STAT_SLIPS) == 1, "a back-room worker is left alone")
	GameState.server_release_from_backroom(2)
	await wait_frames(2)
	_world.items.server_despawn_item(can)

	step("sprinklers: the end and the wet tail")
	check(Events.is_event_active(Events.EVENT_SPRINKLERS) and Events.get_event_time_left() > 1.0, "still running after the slips (%.1f s left)" % Events.get_event_time_left())
	toasts.clear()
	Events.tick(Events.get_event_time_left() - 0.5)
	check(Events.is_event_active(Events.EVENT_SPRINKLERS), "still running half a second before sprinkler_sec")
	Events.tick(0.6)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_SPRINKLERS, "event_ended(sprinklers) when the timer runs out")
	check(Events.is_floor_wet() and absf(Events.get_wet_left() - b.sprinkler_wet_sec) < 0.2 and _wet == [true], "the floor stays wet for sprinkler_wet_sec (%.1f left), no signal yet" % Events.get_wet_left())
	check(_room.get_node_or_null(^"Sprinklers") == null and Sfx.get_active_loop_count() == loops0, "the water stops falling, the loop stops")
	check(toast_seen("Sprinklers are off. The floor is still wet.") and _barked("Sprinklers are off. The floor is still wet."), "the floor is told")
	check(_hud.get_event_text() == "", "the banner is gone")
	w3.set(&"_stagger_immune_until_msec", 0)
	w3.set(&"_stun_until_msec", 0)
	Events.set(&"_last_slip", {})
	_dash(w3, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.sprint_speed)
	check(GameState.get_stat(3, Const.STAT_SLIPS) == 2, "a sprinting worker still slips in the wet tail")
	check(Events.get_wet_left() > 2.0, "the tail's clock ran through the run (%.1f s left)" % Events.get_wet_left())
	toasts.clear()
	Events.tick(Events.get_wet_left() - 0.5)
	check(Events.is_floor_wet(), "still wet half a second before the tail ends")
	Events.tick(0.6)
	check(not Events.is_floor_wet() and Events.get_wet_left() == 0.0 and _wet == [true, false], "dry sprinkler_wet_sec after the water stopped: floor_wet_changed(false) (%s)" % [_wet])
	check(toast_seen("The floor is dry."), "and the floor is told")
	w4.set(&"_stagger_immune_until_msec", 0)
	w4.set(&"_stun_until_msec", 0)
	Events.set(&"_last_slip", {})
	_dash(w4, Vector3(-4.0, 0.0, 4.0), Vector3(2.0, 0.0, 4.0), b.sprint_speed)
	check(GameState.get_stat(4, Const.STAT_SLIPS) == 1, "restored: sprinting on the dry floor is fine")
	Events.worker_slipped.disconnect(on_slip)
	await wait_sec(Events.SPRINKLER_FALL_SEC + 0.6)
	check(_leftovers() == 0, "the emitters are freed after the last drops")
	_reset_plots()
	await _settle()
	_clear_log()


# --- the collection ------------------------------------------------------------------------------------------------------

func _test_collection(b: BalanceConfig, seed0: SeedDef, golden: SeedDef) -> void:
	step("collection: start")
	var me: Player = Game.local_player
	var w2 := _world.get_player(2)
	_put(w2, Vector3(-3.0, 0.0, 0.0))
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(2.5, 0.05, 2.5)
	await wait_until(func() -> bool: return not me.is_stunned(), 4.0, "the host is on his feet")
	GameState.server_add_money(600 - GameState.money)
	var cheap := _bundle(seed0, SPOT_OPEN)
	var dear := _bundle(golden, w2.global_position, 2, 3)
	var middle := _bundle(golden, SPOT_HALL)
	await _settle()
	check(_chute.get_sale_value(dear) > _chute.get_sale_value(middle) and _chute.get_sale_value(middle) > _chute.get_sale_value(cheap), "three bundles: $%d in worker 2's hands, $%d in the hall, $%d on the floor" % [_chute.get_sale_value(dear), _chute.get_sale_value(middle), _chute.get_sale_value(cheap)])
	_clear_log()
	check(Events.get_collector() == null, "nobody on the dock before")
	check(Events.server_start_event(Events.EVENT_COLLECTION), "collection starts")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	var fee := b.collector_fee
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.collector_sec) and int(p.get("fee", -1)) == fee and p.size() == 2, "params {seconds: collector_sec, fee: collector_fee} (%s)" % [p])
	check(_hud.get_event_text().begins_with("COLLECTION") and _hud.event_hint.visible and _hud.event_hint.text == "He wants $%d. Dock." % fee, "HUD banner COLLECTION with the hint (%s / %s)" % [_hud.get_event_text(), _hud.event_hint.text])
	check(toast_seen("Collection. He wants $%d. He is on the dock." % fee) and _barked("He wants %s. He is on the dock." % Story.mayhem_amount_words(fee)), "the floor is told: toast + the Boss (%s)" % Story.last_bark)
	var man := Events.get_collector()
	check(man != null and man.get_parent() == _room and String(man.name) == "Collector" and man is Interactable, "a Collector stands in the Room (a plain child, an Interactable)")
	if man == null:
		return
	var body := man.get_node_or_null(^"Body") as ShopkeeperNPC
	var hit := man.get_node_or_null(^"Hit") as CollisionObject3D
	check(body != null and hit != null and hit.collision_layer == Const.LAYER_INTERACTABLE, "the Boss's body, a collider on the interactable layer")
	check(man.fee == fee and man.get_current_bark() == "%s. Now." % Story.loop_amount_words(fee), "he says what he wants (%s)" % man.get_current_bark())
	var spot := _room.get_collector_spot()
	check(_flat(man.global_position, _room.get_roller_door_position()) < 1.0, "he comes in at the roller door (%s)" % man.global_position)
	await wait_sec(Collector.ARRIVE_SEC + 0.3)
	check(_flat(man.global_position, spot.origin) < 0.05 and _room.get_area_index(man.global_position) == 2, "and stands at Room.get_collector_spot() on the dock (%s)" % man.global_position)
	var recoloured := 0
	for node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		for s in mesh_node.get_surface_override_material_count():
			if mesh_node.get_surface_override_material(s) != null:
				recoloured += 1
	check(recoloured >= 2, "another tint: %d surfaces of the suit are recoloured" % recoloured)

	step("collection: prompt states")
	check(man.get_prompt(me).begins_with("Hold ") and man.get_prompt(me).ends_with("Pay $%d" % fee) and man.can_interact(me) and man.get_denied_reason(me) == "", "with the cash on hand: prompt '%s'" % man.get_prompt(me))
	GameState.server_add_money(10 - GameState.money)
	check(GameState.money == 10 and not man.can_interact(me) and man.get_denied_reason(me) == "Cash short.", "with $10 on hand: 'Cash short.'")

	step("collection: the pay request")
	toasts.clear()
	Events._rpc_request_pay_collector()
	check(Events.is_event_active(Events.EVENT_COLLECTION) and toast_seen("Too far") and GameState.money == 10, "refused from afar: 'Too far.'")
	_face(me, man)
	await wait_frames(2)
	toasts.clear()
	Events._rpc_request_pay_collector()
	check(Events.is_event_active(Events.EVENT_COLLECTION) and toast_seen("Cash short.") and GameState.money == 10 and _paid.is_empty(), "refused with too little cash: 'Cash short.'")
	check(not Events.server_pay_collector(1) and GameState.money == 10, "server_pay_collector() is false without the cash")
	GameState.server_add_money(600 - GameState.money)
	check(GameState.server_send_to_backroom(1, 60.0), "the host sits in the back room")
	await wait_frames(2)
	toasts.clear()
	Events._rpc_request_pay_collector()
	check(Events.is_event_active(Events.EVENT_COLLECTION) and toast_seen("back room") and GameState.money == 600, "refused from the back room")
	GameState.server_release_from_backroom(1)
	await wait_frames(3)
	check(not GameState.is_in_backroom(1) and Events.is_event_active(Events.EVENT_COLLECTION), "let out; he still waits")

	step("collection: the hold")
	var hold0 := b.collector_hold_sec
	Config.balance.collector_hold_sec = 0.6
	_face(me, man)
	await wait_sec(0.25)
	var interactor := me.get_interactor()
	check(interactor.current_target == man, "looking at the collector (target %s)" % [interactor.current_target])
	_ended.clear()
	toasts.clear()
	var money0 := GameState.money
	Input.action_press(&"interact")
	man.interact(me)
	check(man.is_paying(), "holding the payment")
	await wait_sec(0.3)
	check(man.get_pay_progress() > 0.2 and man.get_pay_progress() < 0.9 and man.get_prompt(me).contains(" s") and man.get_prompt(me).contains("Pay $%d" % fee), "hold progress %.2f, the prompt shows the seconds (%s)" % [man.get_pay_progress(), man.get_prompt(me)])
	check(Events.is_event_active(Events.EVENT_COLLECTION) and GameState.money == money0, "nothing paid half-way")
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "the finished hold pays him")
	Input.action_release(&"interact")
	await wait_frames(2)
	check(_paid.size() == 1 and int(_paid[0][0]) == 1 and int(_paid[0][1]) == fee, "collector_paid(the host, fee) (%s)" % [_paid])
	check(GameState.money == money0 - fee, "cash on hand is down by the fee (%d)" % GameState.money)
	check(_ended.size() == 1 and _ended[0][0] == Events.EVENT_COLLECTION and _collected.is_empty(), "event_ended(collection), nothing taken")
	check(toast_seen("Tester paid the collector $%d." % fee) and _barked("Paid. He left."), "the floor hears who paid")
	check(items_of(Const.ITEM_PRODUCT).size() == 3 and _world.items.get_held_by(2) == dear, "every bundle is still there")
	check(Events.get_collector() == null and is_instance_valid(man) and man.is_leaving() and not man.can_interact(me) and man.get_prompt(me) == "", "he is leaving: nobody can pay him twice")
	await wait_sec(Collector.LEAVE_SEC + Collector.TURN_SEC + 0.4)
	check(not is_instance_valid(man) and _leftovers() == 0, "and he is gone")
	toasts.clear()
	Events._rpc_request_pay_collector()
	check(toast_seen("Nobody to pay.") and not Events.server_pay_collector(1), "a pay request with nobody on the dock is refused")
	Config.balance.collector_hold_sec = hold0

	step("collection: unpaid, the dearest bundle")
	var dear_name := String(dear.name)
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(2.5, 0.05, 2.5)
	_clear_log()
	money0 = GameState.money
	check(Events.server_start_event(Events.EVENT_COLLECTION), "a second collection")
	Events.tick(b.collector_sec - 0.5)
	check(Events.is_event_active(Events.EVENT_COLLECTION) and _collected.is_empty(), "he still waits half a second before collector_sec")
	Events.tick(0.6)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_COLLECTION, "event_ended(collection) when the timer runs out")
	check(_collected.size() == 1 and _collected[0][0] == Events.COLLECT_BUNDLE and _collected[0][1] == golden.id and _collected[0][2] == dear_name, "collector_took(bundle, the strain, the dearest bundle) (%s)" % [_collected])
	check(_world.items.get_held_by(2) == null and items_of(Const.ITEM_PRODUCT).size() == 2 and is_instance_valid(cheap) and is_instance_valid(middle), "it left worker 2's hands; the two cheaper ones stay")
	check(GameState.money == money0 and _paid.is_empty() and GameState.get_write_ups(2) <= 1, "no cash taken, nobody written up for it")
	var bundle_line := "Not paid. He took the %s." % golden.display_name
	check(_barked(bundle_line) and toast_seen(bundle_line), "the floor is told (%s)" % Story.last_bark)

	step("collection: unpaid, no bundle")
	_despawn_products()
	_reset_plots()
	var p1 := plot(1)
	var p2 := plot(2)
	var p4 := plot(4)
	var p9 := plot(9)
	check(p1.server_plant(seed0.id) and p2.server_plant(golden.id) and p4.server_plant(seed0.id) and p9.server_plant(seed0.id), "four trays planted")
	p1.stage_progress = 0.9                      # a seedling, nearly through its stage
	p2.stage = GrowPlot.Stage.FLOWERING          # the most advanced, a counted strain
	p2.stage_progress = 0.2
	p4.stage = GrowPlot.Stage.VEGETATIVE
	p4.stage_progress = 0.8
	p9.stage = GrowPlot.Stage.FLOWERING          # the same stage in the hall, less far along
	p9.stage_progress = 0.1
	await _settle()
	var lost: Array = []
	var on_lost := func(cause: StringName, strain: StringName, fine: int) -> void: lost.append([cause, strain, fine])
	p2.crop_lost.connect(on_lost)
	_clear_log()
	GameState.server_add_money(600 - GameState.money)
	check(Events.server_start_event(Events.EVENT_COLLECTION), "a third collection, no bundle on the floor plan")
	Events.tick(b.collector_sec + 0.1)
	await wait_frames(2)
	check(_collected.size() == 1 and _collected[0][0] == Events.COLLECT_TRAY and _collected[0][1] == golden.id and _collected[0][2] == "GrowPlot2", "collector_took(tray, the strain, GrowPlot2): the most advanced tray (%s)" % [_collected])
	check(p2.is_empty() and p1.is_growing() and p4.is_growing() and p9.is_growing() and is_equal_approx(p9.stage_progress, 0.1), "that tray is empty, the others are not touched")
	check(lost.size() == 1 and lost[0][0] == GrowPlot.LOSS_COLLECTED and lost[0][1] == golden.id and int(lost[0][2]) == b.counted_fine, "the counted strain is fined through server_crop_lost(LOSS_COLLECTED) (%s)" % [lost])
	check(GameState.money == 600 - b.counted_fine, "counted_fine comes out of cash on hand (%d)" % GameState.money)
	check(_barked("Not paid. He took the plant in GrowPlot 2.") and toast_seen("Not paid. He took the plant in GrowPlot 2."), "the floor is told (%s)" % Story.last_bark)
	p2.crop_lost.disconnect(on_lost)
	p1.stage = GrowPlot.Stage.READY
	_clear_log()
	check(Events.server_start_event(Events.EVENT_COLLECTION), "a fourth: a READY tray among growing ones")
	Events.tick(b.collector_sec + 0.1)
	await wait_frames(2)
	check(_collected.size() == 1 and _collected[0][0] == Events.COLLECT_TRAY and _collected[0][2] == "GrowPlot1" and p1.is_empty() and p9.is_growing(), "a READY plant is the most advanced of all (%s)" % [_collected])
	check(GameState.money == 600 - b.counted_fine, "a plain strain costs no fine")

	step("collection: unpaid, nothing to take")
	_reset_plots()
	await _settle()
	_clear_log()
	check(Events.server_start_event(Events.EVENT_COLLECTION), "a fifth: no bundle, no plant")
	Events.tick(b.collector_sec + 0.1)
	await wait_frames(2)
	check(_collected.size() == 1 and _collected[0][0] == Events.COLLECT_NOTHING and _collected[0][1] == &"" and _collected[0][2] == "", "collector_took(nothing) (%s)" % [_collected])
	check(_barked("Not paid. Nothing to take. He will be back.") and GameState.money == 600 - b.counted_fine, "he leaves with nothing")
	await wait_sec(Collector.LEAVE_SEC + Collector.TURN_SEC + 0.4)
	check(_leftovers() == 0, "nobody left on the dock")
	_clear_log()


# --- late-join replay ---------------------------------------------------------------------------------------------------

func _test_replay(b: BalanceConfig) -> void:
	step("late-join replay")
	var loops0: int = Sfx.get_active_loop_count()
	var total := b.raid_warning_sec + b.raid_sec
	var p := {"seconds": total, "warning": b.raid_warning_sec}
	Events._rpc_event_started(Events.EVENT_RAID, p, total - 1.0)
	check(Events.is_event_active(Events.EVENT_RAID) and not Events.is_raid_looking() and _started.size() == 1, "raid replay 1 s in: active, still the warning")
	check(_room.get_node_or_null(^"RaidLights") != null and Sfx.get_active_loop_count() == loops0 + 1, "the lights and the siren are on")
	Events._rpc_event_started(Events.EVENT_RAID, p, 3.0)
	check(Events.is_raid_looking() and Events.get_event_time_left() <= 3.0 and _started.size() == 2, "replay with 3 s left: they are looking, time left synced")
	check(_hud.get_event_text().begins_with("RAID") and _hud.event_hint.text == "Get the product out of sight.", "the banner follows the replay")
	check(_room.get_node_or_null(^"RaidLights") != null and Sfx.get_active_loop_count() == loops0 + 1, "one set of lights, one siren after the same packet twice")
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _room.find_children("RaidLights*", "", false, false).is_empty() and Sfx.get_active_loop_count() == loops0, "ended: no lights, no siren")
	_clear_log()
	Events._rpc_event_started(Events.EVENT_SPRINKLERS, {"seconds": b.sprinkler_sec}, 10.0)
	check(Events.is_event_active(Events.EVENT_SPRINKLERS) and Events.is_floor_wet() and _wet == [true] and Events.get_event_time_left() <= 10.0, "sprinkler replay: the floor is wet, time left synced")
	check(_room.get_node_or_null(^"Sprinklers") != null and _hud.get_event_text().begins_with("SPRINKLERS") and Sfx.get_active_loop_count() == loops0 + 1, "water falls, banner SPRINKLERS")
	Events.server_end_event()
	check(not Events.is_event_active() and Events.is_floor_wet() and _wet == [true], "ended: the tail")
	Events.call(&"_mayhem2_server_reset")
	check(not Events.is_floor_wet() and _wet == [true, false], "reset: dry")
	Events._rpc_floor_wet(true)
	check(Events.is_floor_wet() and Events.is_wet_at(SPOT_OPEN) and _wet == [true, false, true] and not Events.is_event_active(), "a joiner in the wet tail: _rpc_floor_wet(true) alone wets the floor")
	Events._rpc_floor_wet(true)
	check(_wet == [true, false, true], "the same packet twice changes nothing")
	Events._rpc_floor_wet(false)
	check(not Events.is_floor_wet() and _wet == [true, false, true, false], "and it dries")
	_clear_log()
	Events._rpc_event_started(Events.EVENT_COLLECTION, {"seconds": b.collector_sec, "fee": 55}, b.collector_sec - 10.0)
	var man := Events.get_collector()
	check(Events.is_event_active(Events.EVENT_COLLECTION) and man != null and man.fee == 55, "collection replay: the collector is there with the broadcast fee")
	check(man != null and _flat(man.global_position, _room.get_collector_spot().origin) < 0.05, "ten seconds in he already stands at his spot")
	check(man != null and man.get_prompt(Game.local_player).ends_with("Pay $55") and _hud.event_hint.text == "He wants $55. Dock.", "prompt and hint name the broadcast fee")
	Events._rpc_event_started(Events.EVENT_COLLECTION, {"seconds": b.collector_sec, "fee": 55}, b.collector_sec - 10.0)
	await wait_frames(2)
	check(_room.find_children("Collector*", "", false, false).size() == 1 and Events.get_collector() != null, "the same packet twice: one collector")
	Events.server_end_event()
	await wait_sec(Collector.LEAVE_SEC + Collector.TURN_SEC + 0.4)
	check(not Events.is_event_active() and _collected.is_empty() and _leftovers() == 0, "force-ended: he takes nothing and leaves")
	_clear_log()


# --- force end / shift end / reset / menu -------------------------------------------------------------------------------

func _test_resets(b: BalanceConfig, seed0: SeedDef) -> void:
	step("force end")
	var loops0: int = Sfx.get_active_loop_count()
	var open := _bundle(seed0, SPOT_OPEN)
	await _settle()
	check(Events.server_start_event(Events.EVENT_RAID), "raid")
	Events.tick(b.raid_warning_sec + 0.1)
	check(Events.is_raid_looking() and Events.get_raid_sweeps() == 1, "the first look happened")
	Events.server_end_event()
	var sweeps := Events.get_raid_sweeps()
	Events.tick(3.0)
	await wait_frames(2)
	check(not Events.is_event_active() and Events.get_raid_sweeps() == sweeps and is_instance_valid(open) and not open.is_queued_for_deletion(), "a force-ended raid looks no more: the bundle on the open floor is still there")
	check(_room.get_node_or_null(^"RaidLights") == null and Sfx.get_active_loop_count() == loops0, "no lights, no siren")
	check(Events.server_start_event(Events.EVENT_COLLECTION), "collection")
	Events.tick(3.0)
	Events.server_end_event()
	await wait_frames(2)
	check(_collected.is_empty() and is_instance_valid(open) and not open.is_queued_for_deletion() and Events.get_collector() == null, "a force-ended collection takes nothing; he leaves")

	step("shift end")
	check(Events.server_start_event(Events.EVENT_SPRINKLERS) and Events.is_floor_wet(), "sprinklers")
	_ended.clear()
	_wet.clear()
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_SPRINKLERS, "shift end ends the sprinklers")
	check(not Events.is_floor_wet() and Events.get_wet_left() == 0.0 and _wet == [false], "and the floor is dry at once (%s)" % [_wet])
	check(_room.get_node_or_null(^"Sprinklers") == null and Sfx.get_active_loop_count() == loops0, "no water, no loop")

	step("game reset")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	_bundle(seed0, SPOT_OPEN)   # something he could take if he stayed (the reset removes it with every other bundle)
	await _settle()
	_clear_log()
	check(Events.server_start_event(Events.EVENT_COLLECTION) and Events.get_collector() != null, "collection")
	Events.tick(b.collector_sec - 1.0)
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_COLLECTION and _collected.is_empty() and Events.get_collector() == null, "game reset ends the collection: nothing taken, he leaves")
	Events.tick(2.0)
	check(_collected.is_empty(), "and nothing is taken late")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_SPRINKLERS), "sprinklers")
	Events.tick(b.sprinkler_sec + 0.1)
	check(not Events.is_event_active() and Events.is_floor_wet() and Events.get_wet_left() > 0.0, "they ran out: the wet tail")
	_wet.clear()
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(not Events.is_floor_wet() and Events.get_wet_left() == 0.0 and _wet == [false], "game reset dries the floor")
	Events.tick(b.sprinkler_wet_sec + 1.0)
	check(_wet == [false], "and no late 'dry' after the reset")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_RAID), "raid")
	Events.tick(1.0)
	_ended.clear()
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_RAID and _room.get_node_or_null(^"RaidLights") == null and Sfx.get_active_loop_count() == loops0, "game reset ends the raid: no lights, no siren")
	await wait_sec(Collector.LEAVE_SEC + Collector.TURN_SEC + 0.4)
	check(_leftovers() == 0, "nothing of the three events is left on the floor")

	step("return to menu")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_SPRINKLERS), "sprinklers before leaving")
	Events.tick(1.0)
	_ended.clear()
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	check(not Events.is_event_active() and Events.get_event_time_left() == 0.0, "menu: events reset locally")
	check(not Events.is_floor_wet() and Events.get_wet_left() == 0.0 and int(Events.get(&"_raid_siren")) == 0 and int(Events.get(&"_sprinkler_loop")) == 0 and Events.get_raid_sweeps() == 0, "menu: the mayhem2 state is forgotten")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_SPRINKLERS, "event_ended emitted on the way out")


# --- helpers --------------------------------------------------------------------------------------------------------

## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3, height: float = 0.05) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, height, pos.z)))


## Moves a fake worker from `from` to `to` at `speed` in STEP ticks of simulated time (no frames pass meanwhile).
## He first stands at `from` for a few ticks so the jump there is not part of the measured run.
func _dash(p: Player, from: Vector3, to: Vector3, speed: float, height: float = 0.05, settle: int = 10) -> void:
	_put(p, from, height)
	for i in settle:
		Events.tick(STEP)
	var dist := from.distance_to(to)
	var steps := int(ceil(dist / (speed * STEP)))
	for i in steps:
		_put(p, from.move_toward(to, speed * STEP * (i + 1)), height)
		Events.tick(STEP)


## Puts the host 1.5 m in front of the collector, looking at him.
func _face(me: Player, man: Node3D) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = man.global_position + Vector3(0.0, 0.05, -1.5)
	me.look_at(Vector3(man.global_position.x, me.global_position.y, man.global_position.z), Vector3.UP)
	me.head.rotation.x = 0.0


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## A product bundle of `seed_def` at `pos` (in `holder`'s hands when > 0).
func _bundle(seed_def: SeedDef, pos: Vector3, holder: int = 0, amount: int = 1) -> Item:
	return _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed_def.id, "amount": amount}, pos, holder)


func _despawn_products() -> void:
	for item in items_of(Const.ITEM_PRODUCT):
		_world.items.server_despawn_item(item)


func _reset_plots() -> void:
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		var pl := plot(i)
		if pl != null:
			pl.server_reset()


## Lets spawned items and trays land in the tree and in the physics space.
func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	await wait_frames(1)


func _has_took(item_name: String, holder: int) -> bool:
	for t in _took:
		if t[0] == item_name and int(t[1]) == holder:
			return true
	return false


## How many lights, emitters and collectors (leaving ones included) are still children of the Room.
func _leftovers() -> int:
	return _room.find_children("RaidLights*", "", false, false).size() + _room.find_children("Sprinklers*", "", false, false).size() \
			+ _room.find_children("Collector*", "", false, false).size()


func _clear_log() -> void:
	_started.clear()
	_ended.clear()
	_swept.clear()
	_took.clear()
	_wet.clear()
	_paid.clear()
	_collected.clear()
	_written.clear()
	toasts.clear()


## True when a Story line containing `text` was shown (or queued as the last bark).
func _barked(text: String) -> bool:
	if Story.last_bark.contains(text) or Story.get_pending_text().contains(text):
		return true
	for t in Story.bark_log:
		if String(t).contains(text):
			return true
	return false
