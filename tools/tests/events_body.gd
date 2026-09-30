extends "res://tools/tests/qa_base.gd"
## M10 events suite (events agent): scheduler + sync payloads, the inspection walk and sight checks, the back-room
## teleport, the power cut + fuse box, the audit, shift end / menu resets, on a single headless host with fake
## workers (Net.players + World.server_spawn_player, no owning peer). Deterministic: time is advanced with
## Events.tick(), the Boss is frozen for the sight checks.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/events_body.gd --port=7843 --events --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const ROUTE_RAY_HEIGHT := 1.0

var _started: Array = []      # [kind, params]
var _ended: Array = []        # [kind]
var _power: Array = []        # [on]
var _written: Array = []      # [peer, reason, count]
var _spotted: Array = []      # [peer, reason]
var _world: World
var _room: Room
var _boss: ShopkeeperNPC


func _run() -> void:
	_label = "events"
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.power_changed.connect(func(on: bool) -> void: _power.append([on]))
	Events.worker_spotted.connect(func(p: int, r: String) -> void: _spotted.append([p, r]))
	GameState.worker_written_up.connect(func(p: int, r: String, c: int) -> void: _written.append([p, r, c]))
	var b: BalanceConfig = Config.balance

	step("enable rule")
	check(Config.has_arg("events"), "this suite runs with --events")
	check(Events.are_events_enabled(), "are_events_enabled() with --events")
	Config.user_args.erase("events")
	check(not Events.are_events_enabled(), "headless without --events: events disabled")
	Config.user_args["no-events"] = true
	Config.user_args["events"] = true
	check(not Events.are_events_enabled(), "--no-events wins over --events")
	Config.user_args.erase("no-events")
	check(Events.are_events_enabled(), "enabled again")
	check(not Events.is_event_active() and Events.is_power_on() and Events.get_event_time_left() == 0.0, "idle: no event, power on, time left 0")
	check(not Events.server_start_event(Events.EVENT_AUDIT), "server_start_event refused in the menu")

	step("pick")
	var kinds_seen: Dictionary = {}
	var repeats := 0
	for k in Events.KINDS:
		for i in 40:
			var pick := Events.pick_kind(k)
			kinds_seen[pick] = true
			if pick == k or not Events.KINDS.has(pick):
				repeats += 1
	check(repeats == 0, "pick_kind() never repeats the previous kind and stays in KINDS")
	check(kinds_seen.size() >= 3, "pick_kind() covers the kinds (%d seen)" % kinds_seen.size())

	step("hosting")
	Game.start_host("Tester", port_arg(7843))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_boss = _room.get_station("ShopCounter").get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC
	check(_boss != null and _boss.is_in_group(Const.GROUP_NPCS), "the Boss exists and is in GROUP_NPCS")
	check(_room.get_station("FuseBox") is FuseBox, "Stations/FuseBox is a FuseBox station")
	for id in [2, 3, 4, 5]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	check(_world.get_players().size() == 5, "host + 4 fake workers spawned")
	check(not Events.server_start_event(Events.EVENT_POWER_CUT), "no event while WAITING")
	check(Events.get_next_event_in() < 0.0, "nothing scheduled while WAITING")

	step("shift start")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(absf(Events.get_next_event_in() - b.event_first_delay_sec) < 0.5, "first event scheduled %.0f s into the shift (%.1f)" % [b.event_first_delay_sec, Events.get_next_event_in()])
	var plot1 := _room.get_station("GrowPlot1") as GrowPlot
	var seed_id: StringName = b.seeds[0].id
	check(plot1.server_plant(seed_id) and plot1.server_water(1.0), "a plant grows in GrowPlot1 (a rat has somewhere to go)")

	await _test_scheduler(b)
	await _test_inspection(b)
	await _test_backroom()
	await _test_power_cut(b)
	await _test_audit(b)
	await _test_rat(b)
	await _test_shift_end()
	await _test_menu_reset()
	finish()


# --- rat (stretch) --------------------------------------------------------------------------------------------------

func _test_rat(b: BalanceConfig) -> void:
	step("rat")
	if not Events.RAT_ENABLED:
		check(not Events.server_start_event(Events.EVENT_RAT), "rat disabled: refused")
		return
	# A fresh seedling half-way through its stage, so the drain is visible; any other growing plot is cleared.
	for i in range(1, 7):
		var p := _room.get_station("GrowPlot%d" % i) as GrowPlot
		if p != null and p.is_growing():
			p.server_reset()
	var plot2 := _room.get_station("GrowPlot2") as GrowPlot
	check(plot2.server_plant(b.seeds[0].id) and plot2.server_water(1.0), "GrowPlot2 grows")
	plot2.stage_progress = 0.5
	_started.clear()
	_ended.clear()
	check(Events.server_start_event(Events.EVENT_RAT), "rat starts")
	var params: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(int(params.get("plot", 0)) == 2 and params.get("from", null) is Vector3, "params {plot: 2, from: Vector3} (%s)" % [params])
	var rat := _room.get_node_or_null(^"Rat") as Rat
	check(rat != null and rat.is_running() and rat.is_in_group(Const.GROUP_NPCS), "a Rat prop runs from the wall gap (a plain child of the Room)")
	if rat == null:
		Events.server_end_event()
		return
	var from: Vector3 = params.get("from", Vector3.ZERO)
	check(rat.global_position.distance_to(from) < 0.2, "he starts at the gap")
	await wait_until(func() -> bool: return rat.is_eating(), 12.0, "he reaches the tray and eats")
	check(rat.global_position.distance_to(plot2.global_position) < 1.2, "eating next to GrowPlot2 (%.2f m)" % rat.global_position.distance_to(plot2.global_position))
	var progress0 := plot2.stage_progress
	Events.tick(2.0)
	check(plot2.stage_progress < progress0 - 0.08, "he eats stage progress (%.2f -> %.2f)" % [progress0, plot2.stage_progress])
	check(Events.is_event_active(Events.EVENT_RAT), "still eating: event runs")
	var w2 := _world.get_player(2)
	_put(w2, rat.global_position + Vector3(0.6, 0.0, 0.0))
	Events.tick(0.1)
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_RAT, "a worker within 1.5 m scares him off: event_ended(rat)")
	check(not is_instance_valid(rat) or rat.is_fleeing() or rat.is_queued_for_deletion(), "he flees")
	await wait_until(func() -> bool: return _room.get_node_or_null(^"Rat") == null, 10.0, "he is gone again")
	_put(w2, _room.get_spawn_transform(w2.spawn_index).origin)
	# A late joiner replays the event with the seconds left: he must be where he is by now, not rerun from the gap.
	var target := plot2.global_position + plot2.global_basis.z.normalized() * 0.55
	var run_len := Vector2(target.x - from.x, target.z - from.z).length()
	Events._rpc_event_started(Events.EVENT_RAT, {"plot": 2, "from": from}, Events.RAT_MAX_SEC - 1.0)
	var late := _room.get_node_or_null(^"Rat") as Rat
	var d_from := late.global_position.distance_to(from) if late != null else -1.0
	check(late != null and late.is_running() and absf(d_from - minf(late.run_speed, run_len)) < 0.3, "late-join replay 1 s in: part-way along his run (%.2f m from the gap, run %.2f m)" % [d_from, run_len])
	Events._rpc_event_started(Events.EVENT_RAT, {"plot": 2, "from": from}, Events.RAT_MAX_SEC - 20.0)
	late = _room.get_node_or_null(^"Rat") as Rat
	check(late != null and late.global_position.distance_to(target) < 0.1, "replay 20 s in: already at the tray (the old prop is gone: %s)" % [_room.get_node_or_null(^"Rat_gone") == null or _room.get_node_or_null(^"Rat_gone").is_queued_for_deletion()])
	await wait_frames(2)
	check(late != null and is_instance_valid(late) and late.is_eating() and _room.get_node_or_null(^"Rat_gone") == null, "and eating next frame; the replaced prop was freed")
	Events.server_end_event()
	await wait_until(func() -> bool: return _room.get_node_or_null(^"Rat") == null, 10.0, "cleared after the replay")
	_started.clear()
	_ended.clear()


# --- scheduler ------------------------------------------------------------------------------------------------------

func _test_scheduler(b: BalanceConfig) -> void:
	step("scheduler")
	Events.tick(b.event_first_delay_sec - 2.0)
	check(not Events.is_event_active(), "no event %.0f s before the first delay" % 2.0)
	Events.tick(3.0)
	check(Events.is_event_active(), "the scheduler started an event after the first delay (%s)" % Events.active_event)
	check(_started.size() == 1 and _started[0][0] == Events.active_event, "event_started emitted once, kind matches")
	var kind: StringName = Events.active_event
	var params: Dictionary = _started[0][1] if not _started.is_empty() else {}
	match kind:
		Events.EVENT_INSPECTION:
			check(params.has("seconds") and params.has("speed"), "inspection params carry seconds + speed")
		Events.EVENT_POWER_CUT:
			check(params.has("max_seconds") and not Events.is_power_on(), "power cut params carry max_seconds, power off")
		Events.EVENT_AUDIT:
			check(params.has("raise"), "audit params carry raise")
		Events.EVENT_RAT:
			check(params.has("plot") and params.has("from"), "rat params carry plot + from")
	check(Events.get_event_time_left() > 0.0, "time left counts (%.1f s)" % Events.get_event_time_left())
	var other: StringName = Events.EVENT_AUDIT if kind != Events.EVENT_AUDIT else Events.EVENT_POWER_CUT
	check(not Events.server_start_event(other), "one at a time: a second start is refused")
	check(Events.get_next_event_in() < 0.0, "nothing scheduled while an event runs")
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == kind, "server_end_event ends it (event_ended %s)" % kind)
	check(Events.is_power_on(), "power on after the event")
	var gap := Events.get_next_event_in()
	check(gap >= b.event_gap_min_sec - 0.01 and gap <= b.event_gap_max_sec + 0.01, "next event in [%.0f, %.0f] s (%.1f)" % [b.event_gap_min_sec, b.event_gap_max_sec, gap])
	Config.user_args.erase("events")
	Events.tick(1000.0)
	check(not Events.is_event_active(), "disabled (no --events): the scheduler stays quiet")
	Config.user_args["events"] = true
	if _boss != null and _boss.is_walking():
		await wait_until(func() -> bool: return not _boss.is_walking(), 3.0, "the Boss stopped after the scheduler's event")
	await wait_sec(1.0)
	_started.clear()
	_ended.clear()
	_power.clear()


# --- inspection ----------------------------------------------------------------------------------------------------

func _test_inspection(b: BalanceConfig) -> void:
	step("inspection route")
	var route := _room.get_inspection_route()
	check(route.size() >= 8, "inspection route has %d points" % route.size())
	var bounds := _room.get_bounds()
	var inside := true
	for p in route:
		if not bounds.grow(0.01).has_point(Vector3(p.x, 1.0, p.z)) or absf(p.y) > 0.01:
			inside = false
	check(inside, "every route point is on the floor inside the room")
	var space := _world.get_world_3d().direct_space_state
	var exclude: Array[RID] = []
	var door := _room.get_backroom_door()
	if door != null:
		for c in door.find_children("*", "CollisionObject3D", true, false):
			exclude.append((c as CollisionObject3D).get_rid())
	var blocked: PackedStringArray = []
	for i in range(1, route.size()):
		var from := route[i - 1] + Vector3.UP * ROUTE_RAY_HEIGHT
		var to := route[i] + Vector3.UP * ROUTE_RAY_HEIGHT
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD, exclude))
		if not hit.is_empty():
			blocked.append("P%d-P%d hits %s" % [i, i + 1, (hit["collider"] as Node).get_path()])
	check(blocked.is_empty(), "every route leg is clear on LAYER_WORLD at 1 m (door excluded) %s" % [blocked])
	check(door != null and not _room.is_backroom_door_open(), "the booth door exists and starts shut")
	var door_pos := _room.get_backroom_door_position()
	var near_door := false
	for p in route:
		if Vector2(p.x - door_pos.x, p.z - door_pos.z).length() < 1.2:
			near_door = true
	check(near_door, "the route passes the booth door (%s)" % door_pos)

	step("inspection walk")
	if _boss == null:
		return
	var home := _boss.global_position
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection starts")
	check(Events.is_event_active(Events.EVENT_INSPECTION) and _boss.is_walking(), "the Boss walks")
	check(_started.size() == 1 and _started[0][1].get("seconds", 0.0) == b.inspection_sec, "params.seconds == inspection_sec")
	var clip := _boss.get_node_or_null(^"Clipboard") as Node3D
	check(clip != null and clip.visible, "he carries the clipboard while walking")
	await wait_sec(1.0)
	check(_boss.global_position.distance_to(home) > 0.5, "the walk moves him (%.2f m in 1 s)" % _boss.global_position.distance_to(home))
	check(_boss.get_walk_progress() > 0.0 and _boss.get_walk_progress() < 0.5, "walk progress %.2f" % _boss.get_walk_progress())
	# Fast-forward him onto the floor (deterministic: the walk is a function of the elapsed time) and freeze.
	var speed: float = _started[0][1].get("speed", 1.6)
	_boss.walk_route(route, speed, 6.0)
	_boss.set_process(false)
	await wait_frames(2)  # Events' cosmetic tick (door state) sees the frozen position
	check(clip != null and clip.visible and clip.global_position.distance_to(_boss.global_position) < 1.2, "the clipboard follows him (%.2f m from his feet)" % clip.global_position.distance_to(_boss.global_position))
	var eye := _boss.get_eye_position()
	var facing := _boss.get_facing()
	check(eye.y > 1.4 and eye.y < 2.0, "eyes at %.2f m" % eye.y)
	check(absf(facing.y) < 0.001 and absf(facing.length() - 1.0) < 0.001, "facing is a flat unit vector")
	check(_room.is_backroom_door_open() == (_boss.global_position.distance_to(door_pos) < Events.DOOR_RANGE), "door open state follows his distance to it")
	var floor_eye := Vector3(eye.x, 0.0, eye.z)
	var side := facing.cross(Vector3.UP).normalized()

	step("skimming")
	var w2 := _world.get_player(2)
	_put(w2, floor_eye + facing * 2.5)
	var product := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": b.seeds[0].id, "amount": 1}, w2.global_position, 2)
	await wait_frames(1)
	check(product != null and _world.items.get_held_by(2) == product, "worker 2 holds a product in his cone")
	_written.clear()
	_spotted.clear()
	var money0 := GameState.money
	Events.server_sight_check()
	await wait_frames(1)
	check(_written.size() == 1 and _written[0][0] == 2 and _written[0][1] == Const.WRITE_UP_SKIMMING, "worker 2 written up for skimming")
	check(_world.items.get_held_by(2) == null, "the product is confiscated (despawned)")
	check(_spotted.size() == 1 and _spotted[0][0] == 2 and _spotted[0][1] == Const.WRITE_UP_SKIMMING, "worker_spotted(2, skimming) on this peer")
	check(GameState.money == money0 - b.write_up_fine, "the fine was docked")
	_put(w2, floor_eye - facing * 3.0)  # behind him, out of the cone

	step("line of sight")
	var w3 := _world.get_player(3)
	_put(w3, floor_eye + facing * 3.0 + side * 0.4)
	w3.crouching = true
	var crate := StaticBody3D.new()
	crate.collision_layer = Const.LAYER_WORLD
	crate.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.4, 1.0, 0.3)
	shape.shape = box
	crate.add_child(shape)
	_world.add_child(crate)
	crate.global_position = floor_eye + facing * 2.2 + Vector3.UP * 0.5
	crate.look_at(crate.global_position + facing, Vector3.UP)
	var product3 := _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": b.seeds[0].id, "amount": 1}, w3.global_position, 3)
	await wait_frames(2)
	_written.clear()
	Events.server_sight_check()
	await wait_frames(1)
	check(_written.is_empty() and product3 != null and _world.items.get_held_by(3) == product3, "a crouched worker behind a crate is not seen (keeps the product)")
	w3.crouching = false
	Events.server_sight_check()
	await wait_frames(1)
	check(_written.size() == 1 and _written[0][0] == 3 and _world.items.get_held_by(3) == null, "standing up behind the same crate: seen and confiscated")
	crate.queue_free()
	_put(w3, floor_eye - facing * 3.0 + side * 1.0)

	step("loitering")
	var w4 := _world.get_player(4)
	_put(w4, floor_eye + facing * 3.5 - side * 0.8)
	var w5 := _world.get_player(5)
	var w5_base := floor_eye + facing * 3.5 + side * 1.2
	_put(w5, w5_base)
	_written.clear()
	Events.tick(b.loiter_sec - 0.6)
	await wait_frames(1)
	check(_count_written(4, "") == 0 and _count_written(5, "") == 0, "nothing before loiter_sec")
	Events.tick(1.2)
	await wait_frames(1)
	check(_count_written(4, Const.WRITE_UP_LOITERING) == 1, "a still worker is written up for loitering after loiter_sec")
	check(_count_written(5, Const.WRITE_UP_LOITERING) == 1, "the other still worker too (each on his own window)")
	check(_spotted.size() >= 2 and _spotted.back()[1] == Const.WRITE_UP_LOITERING, "worker_spotted(loitering) on this peer")
	Events.tick(b.loiter_sec + 0.6)
	await wait_frames(1)
	check(_count_written(4, Const.WRITE_UP_LOITERING) == 1, "no second write-up within 5 s of the first")
	Events.tick(2.0)
	await wait_frames(1)
	check(_count_written(4, Const.WRITE_UP_LOITERING) == 2, "after the 5 s cooldown the still worker is written up again")
	var w5_before := _count_written(5, Const.WRITE_UP_LOITERING)
	_put(w4, floor_eye - facing * 3.0 - side * 1.0)
	for i in 12:
		Events.tick(0.5)
		_put(w5, w5_base + side * (0.5 if i % 2 == 0 else -0.5))
	await wait_frames(1)
	check(_count_written(5, Const.WRITE_UP_LOITERING) == w5_before, "a worker who keeps moving (0.5 m every 0.5 s) is never loitering (6 s)")
	check(GameState.get_stat(4, Const.STAT_WRITE_UPS) >= 2, "STAT_WRITE_UPS counts the inspection write-ups")
	_put(w5, floor_eye - facing * 3.0 + side * 2.0)

	step("inspection end")
	_ended.clear()
	Events.server_end_event()
	_boss.set_process(true)
	await wait_frames(2)
	check(_ended.size() == 1 and _ended[0][0] == Events.EVENT_INSPECTION and not Events.is_event_active(), "event_ended(inspection)")
	check(not _boss.is_walking(), "he stops walking")
	await wait_until(func() -> bool: return _boss.position.length() < 0.05 and not _room.is_backroom_door_open(), 3.0, "he is back on his spot and the door is shut")
	check(clip != null and not clip.visible, "the clipboard is away")
	_started.clear()
	_ended.clear()


func _count_written(peer: int, reason: String) -> int:
	var n := 0
	for e in _written:
		if int(e[0]) == peer and (reason == "" or String(e[1]) == reason):
			n += 1
	return n


# --- back room ------------------------------------------------------------------------------------------------------

func _test_backroom() -> void:
	step("back room teleport")
	var w2 := _world.get_player(2)
	var spot := _room.get_backroom_transform(0).origin
	var spawn := _room.get_spawn_transform(w2.spawn_index).origin
	check(_room.get_backroom_spot() != null and spot.z < -5.6 and absf(spot.x) < 2.0, "BackRoomSpot sits inside the booth (%s)" % spot)
	check(_room.get_backroom_transform(1).origin.distance_to(spot) > 1.0, "a second back-room slot is apart from the first")
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, spawn, 2)
	await wait_frames(1)
	check(can != null and _world.items.get_held_by(2) == can, "worker 2 holds a can before the back room")
	check(GameState.server_send_to_backroom(2, 20.0), "worker 2 sent to the back room")
	await wait_frames(2)
	check(w2.global_position.distance_to(spot) < 0.3, "his body is at the BackRoomSpot (%.2f m)" % w2.global_position.distance_to(spot))
	check(_world.items.get_held_by(2) == null and can != null and is_instance_valid(can) and can.holder_id == 0, "his can left his hands on entry")
	check(can != null and is_instance_valid(can) and Vector2(can.global_position.x - spawn.x, can.global_position.z - spawn.z).length() < 0.8, "the can waits at his spawn, not in the booth (%.2f m from the spawn)" % (Vector2(can.global_position.x - spawn.x, can.global_position.z - spawn.z).length() if can != null else -1.0))
	GameState.server_release_from_backroom(2)
	await wait_frames(2)
	check(w2.global_position.distance_to(spawn) < 0.3, "released: back at his spawn (%.2f m)" % w2.global_position.distance_to(spawn))


# --- power cut ------------------------------------------------------------------------------------------------------

func _test_power_cut(b: BalanceConfig) -> void:
	step("power cut")
	var plot1 := _room.get_station("GrowPlot1") as GrowPlot
	var sun := _room.get_node(^"Sun") as DirectionalLight3D
	var lamp := _room.get_node(^"Decor/CenterLamp/Light") as Light3D
	var tubes := _room.get_node_or_null(^"Decor/FluoroSouthWest/Visual/Tubes") as Node3D
	var grow_tube := _room.get_node_or_null(^"Decor/GrowLightWest/Visual/Tube") as Node3D
	var led := _room.get_node_or_null(^"Decor/CameraNorthWest/Visual/Pan/Tilt/Led") as Node3D
	var sun0 := sun.light_energy
	var lamp0 := lamp.light_energy
	var fuse := _room.get_station("FuseBox") as FuseBox
	check(not fuse.is_tripped() and fuse.get_denied_reason(Game.local_player) == FuseBox.REASON_NOTHING and not fuse.can_interact(Game.local_player), "fuse box idle: nothing to reset (greyed)")
	_power.clear()
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut starts")
	check(not Events.is_power_on() and not _room.is_power_on(), "power off on Events and Room")
	check(_power.size() == 1 and _power[0][0] == false, "power_changed(false)")
	check(_started.size() == 1 and _started[0][1].get("max_seconds", 0.0) == b.power_cut_max_sec, "params.max_seconds == power_cut_max_sec")
	check(fuse.is_tripped() and fuse.can_interact(Game.local_player) and fuse.get_prompt(Game.local_player).contains("Reset the breaker"), "fuse box tripped: hold prompt")
	await wait_sec(0.7)
	check(absf(sun.light_energy - sun0 * Room.POWER_OFF_FRACTION) < 0.01, "the Sun dropped to 6 %% (%.3f)" % sun.light_energy)
	check(absf(lamp.light_energy - lamp0 * Room.POWER_OFF_FRACTION) < 0.02, "a pendant lamp dropped to 6 %% (%.3f)" % lamp.light_energy)
	check(tubes != null and not tubes.visible, "fluoro tubes are dark")
	check(grow_tube != null and not grow_tube.visible, "grow-light tubes are dark")
	check(led != null and not led.visible, "camera LED is off")
	var progress0 := plot1.stage_progress
	var water0 := plot1.water
	plot1.tick(1.0)
	check(plot1.stage_progress == progress0 and plot1.water == water0, "growth and water drain pause while the power is off")

	step("fuse box hold")
	Config.balance.fuse_reset_sec = 0.6
	var me: Player = Game.local_player
	var fuse_pos := fuse.global_position
	var front := fuse.global_basis.z.normalized()
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(fuse_pos.x, 0.05, fuse_pos.z) + front * 1.3
	me.look_at(Vector3(fuse_pos.x, 0.05, fuse_pos.z), Vector3.UP)
	me.head.rotation.x = -0.35
	await wait_frames(3)
	var interactor := me.get_interactor()
	check(interactor.current_target == fuse, "looking at the fuse box (target %s)" % [interactor.current_target])
	Input.action_press(&"interact")
	fuse.interact(me)
	check(fuse.is_holding(), "holding the reset")
	await wait_sec(0.3)
	check(fuse.get_hold_progress() > 0.2 and fuse.get_hold_progress() < 0.9 and fuse.get_prompt(me).contains(" s"), "hold progress %.2f, prompt shows the seconds" % fuse.get_hold_progress())
	_ended.clear()
	await wait_until(func() -> bool: return Events.is_power_on(), 3.0, "the hold resets the breaker: power back")
	Input.action_release(&"interact")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_POWER_CUT, "event_ended(power_cut)")
	check(_power.size() == 2 and _power[1][0] == true, "power_changed(true)")
	check(not fuse.is_holding() and fuse.get_hold_progress() == 0.0, "hold cleared")
	await wait_sec(0.6)
	check(absf(sun.light_energy - sun0) < 0.01 and absf(lamp.light_energy - lamp0) < 0.02, "lights back to their energies")
	check(tubes != null and tubes.visible and grow_tube != null and grow_tube.visible, "tubes back on")
	var released_hold := true
	Input.action_press(&"interact")
	fuse.interact(me)
	released_hold = not fuse.is_holding()
	Input.action_release(&"interact")
	check(released_hold, "interact on a live breaker does not start a hold")
	Config.balance.fuse_reset_sec = b.fuse_reset_sec if b.fuse_reset_sec != 0.6 else 2.5

	step("power cut auto-end")
	_started.clear()
	_ended.clear()
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "second power cut")
	Events.tick(b.power_cut_max_sec + 0.1)
	await wait_frames(2)
	check(not Events.is_event_active() and Events.is_power_on() and _room.is_power_on(), "ends by itself after power_cut_max_sec, power back")
	_started.clear()
	_ended.clear()
	_power.clear()


# --- audit ----------------------------------------------------------------------------------------------------------

func _test_audit(b: BalanceConfig) -> void:
	step("audit")
	var q0 := GameState.quota
	check(Events.server_start_event(Events.EVENT_AUDIT), "audit starts")
	await wait_frames(1)
	var expected := q0 + maxi(int(round(float(q0) * b.audit_raise_fraction)), 1)
	check(GameState.quota == expected, "quota raised %d -> %d" % [q0, GameState.quota])
	check(_started.size() == 1 and is_equal_approx(float(_started[0][1].get("raise", 0.0)), b.audit_raise_fraction), "params.raise == audit_raise_fraction")
	check(Events.is_event_active(Events.EVENT_AUDIT) and Events.get_event_time_left() > 2.0, "the audit banner stays up ~3 s")
	Events.tick(3.1)
	await wait_frames(1)
	check(not Events.is_event_active() and _ended.size() == 1 and _ended[0][0] == Events.EVENT_AUDIT, "audit ends after 3 s")
	_started.clear()
	_ended.clear()


# --- shift end / menu -----------------------------------------------------------------------------------------------

func _test_shift_end() -> void:
	step("shift end")
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut during the last seconds")
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_frames(1)
	check(not Events.is_event_active() and Events.is_power_on() and _room.is_power_on(), "shift end ends the event and restores the power")
	check(_ended.size() == 1 and _ended[0][0] == Events.EVENT_POWER_CUT, "event_ended(power_cut) at shift end")
	check(Events.get_next_event_in() < 0.0, "nothing scheduled between shifts")
	_started.clear()
	_ended.clear()
	_power.clear()


func _test_menu_reset() -> void:
	step("return to menu")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut before leaving")
	_ended.clear()
	_power.clear()
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	check(not Events.is_event_active() and Events.is_power_on() and Events.get_event_time_left() == 0.0, "menu: events reset locally")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_POWER_CUT, "event_ended emitted on the way out")
	check(_power.size() >= 1 and _power.back()[0] == true, "power_changed(true) emitted on the way out")


# --- helpers --------------------------------------------------------------------------------------------------------

## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))
