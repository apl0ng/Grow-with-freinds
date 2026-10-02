extends "res://tools/tests/qa_base.gd"
## M15 mayhem2 multi-process suite (mayhem2 agent), driven by tools/tests/mayhem2_mp.sh: a host, client A (joins at
## the start) and client B (joins DURING the raid).
##   host: shift; SPRINKLERS (waits until A slipped, judged from its synced position; ends them with a short wet
##         tail); COLLECTION (waits until A's hold paid the collector); puts a bundle in A's hands and starts a long
##         RAID (marker MAYHEM2_RAID starts B); waits until the look took A's bundle and wrote A up, until B is in,
##         then drops one more bundle on the open floor and waits until a look takes it; lets the timer run out; waits
##         for the clients to leave.
##   a:    sees the sprinklers (the event, the wet floor, the falling water, the trays' synced water), sprints with
##         real input and goes down on its own process, sees the floor dry; sees the collector on its own dock, pays
##         him through the real hold (Interactor.try_interact + the held key), sees who paid and the cash on hand; in
##         the raid stands in sight with the bundle: it is taken out of its hands, it is written up, it hears the count.
##   b:    joins during the raid: the event replay, the banner and the hint, the lights at the roller door and the
##         siren, time left; sees a bundle taken by a look it witnessed, the end, the lights gone. Leaves.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0
## A stands here during the raid: the open floor of the main room, in sight of the dock passage.
const RAID_STAND := Vector3(-3.0, 0.0, 0.0)
## The bundle the host drops once B is in: the open floor of the main room.
const RAID_DROP := Vector3(-3.0, 0.0, 3.0)
## A's run under the sprinklers: the middle of the main room, far from the tank, west to east.
const RUN_FROM := Vector3(-4.0, 0.0, 4.0)
const RUN_TO := Vector3(2.0, 0.0, 4.0)

var role: String = "host"
var port: int = 7978
var _started: Array = []
var _ended: Array = []
var _swept: Array = []
var _took: Array = []
var _wet: Array = []
var _paid: Array = []
var _collected: Array = []
var _slipped: Array = []
var _written: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7978))
	_label = "mayhem2_mp:" + role
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.raid_swept.connect(func(i: int, n: int) -> void: _swept.append([i, n]))
	Events.raid_took.connect(func(n: String, h: int) -> void: _took.append([n, h]))
	Events.floor_wet_changed.connect(func(w: bool) -> void: _wet.append(w))
	Events.collector_paid.connect(func(p: int, fee: int) -> void: _paid.append([p, fee]))
	Events.collector_took.connect(func(what: StringName, strain: StringName, where: String) -> void: _collected.append([what, strain, where]))
	Events.worker_slipped.connect(func(p: int) -> void: _slipped.append(p))
	GameState.worker_written_up.connect(func(p: int, reason: String, count: int) -> void: _written.append([p, reason, count]))
	match role:
		"host": await _host()
		"a": await _client_a()
		"b": await _client_b()
	finish()


# --- host ------------------------------------------------------------------------------------------------------------

func _host() -> void:
	step("hosting on %d" % port)
	Game.start_host("Host", port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		return
	print("MAYHEM2_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	var a_id := _other_peer(0)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(600 - GameState.money)
	var b: BalanceConfig = Config.balance
	var room: Room = Game.world.room
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(8.0, 0.05, 6.2)   # the corridor south of the pen: out of every eye's sight
	await wait_sec(0.5)

	step("sprinklers")
	Config.balance.sprinkler_sec = 120.0   # the host ends them once A went down
	check(Events.server_start_event(Events.EVENT_SPRINKLERS), "sprinklers started")
	check(Events.is_floor_wet() and is_equal_approx(plot(1).water, 1.0) and is_equal_approx(plot(8).water, 1.0), "host: the floor is wet, the trays are full")
	await wait_until(func() -> bool: return GameState.get_stat(a_id, Const.STAT_SLIPS) >= 1, STEP_TIMEOUT, "A slipped under the sprinklers (judged from its synced position)")
	check(_slipped.has(a_id) and GameState.get_stat(1, Const.STAT_SLIPS) == 0, "host: worker_slipped(A); the host standing by did not slip")
	Config.balance.sprinkler_wet_sec = 1.5
	Events.server_end_event()
	check(not Events.is_event_active() and Events.is_floor_wet(), "host: the water is off, the floor still wet")
	await wait_until(func() -> bool: return not Events.is_floor_wet(), 4.0, "host: dry after the short tail")
	await wait_sec(2.0)   # A gets up

	step("collection")
	Config.balance.collector_sec = 120.0   # A pays long before it runs out
	var money0 := GameState.money
	_ended.clear()
	check(Events.server_start_event(Events.EVENT_COLLECTION) and Events.get_collector() != null, "collection started, the collector stands on the host's dock")
	await wait_until(func() -> bool: return not Events.is_event_active(), STEP_TIMEOUT, "client A's hold paid the collector")
	await wait_frames(2)
	check(_paid.size() == 1 and int(_paid[0][0]) == a_id and int(_paid[0][1]) == b.collector_fee, "host: collector_paid(A, fee) (%s)" % [_paid])
	check(GameState.money == money0 - b.collector_fee and _collected.is_empty(), "host: cash on hand is down by the fee (%d), nothing taken" % GameState.money)
	check(_ended.size() == 1 and _ended[0][0] == Events.EVENT_COLLECTION and Events.get_collector() == null, "host: event over, he is leaving")
	await wait_sec(2.5)

	step("raid")
	var seed0: SeedDef = b.seeds[0]
	var held := Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed0.id, "amount": 1}, RAID_STAND, a_id)
	check(held != null and Game.world.items.get_held_by(a_id) == held, "host: A carries a bundle")
	var held_name := String(held.name)
	Config.balance.raid_warning_sec = 10.0
	Config.balance.raid_sec = 120.0   # long enough for B to join in the middle of it; the host cuts it short below
	_written.clear()
	check(Events.server_start_event(Events.EVENT_RAID), "raid started")
	print("MAYHEM2_RAID")
	await wait_until(func() -> bool: return Game.world.items.get_held_by(a_id) == null and not _took.is_empty(), STEP_TIMEOUT, "a look took the bundle out of A's hands")
	check(_took[0][0] == held_name and int(_took[0][1]) == a_id, "host: raid_took(A's bundle, A) (%s)" % [_took])
	check(_written.size() == 1 and int(_written[0][0]) == a_id and _written[0][1] == Const.WRITE_UP_RAID, "host: A is written up with WRITE_UP_RAID (%s)" % [_written])
	await wait_until(func() -> bool: return Net.players.size() >= 3 and Game.world.get_players().size() >= 3, JOIN_TIMEOUT, "client B joined during the raid")
	check(Events.is_event_active(Events.EVENT_RAID), "host: the raid runs while B joins (%.1f s left)" % Events.get_event_time_left())
	await wait_sec(1.5)   # B's replay lands, its lights are up
	var dropped := Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed0.id, "amount": 1}, RAID_DROP)
	var dropped_name := String(dropped.name) if dropped != null else ""
	var looks0 := Events.get_raid_sweeps()
	await wait_until(func() -> bool: return _took.size() >= 2, 8.0, "a later look took the bundle dropped on the open floor")
	check(_took.back()[0] == dropped_name and int(_took.back()[1]) == 0 and Events.get_raid_sweeps() > looks0, "host: raid_took(the dropped bundle, nobody) (%s)" % [_took])
	check(GameState.get_stat(1, Const.STAT_WRITE_UPS) == 0 and room.get_node_or_null(^"RaidLights") != null, "host: the host was not written up; the lights are still on")
	Events.set(&"_time_left", 0.3)   # the timer runs out
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "the raid ran out")
	check(room.get_node_or_null(^"RaidLights") == null and Events.get_raid_taken() == 2, "host: lights gone, two bundles taken in all")
	print("MAYHEM2_DONE")
	# Both clients leave at the same moment: SceneMultiplayer may still flush a packet to a peer ENet has already
	# reset ("Unable to send packet on channel 0", no game code on the stack; see qa_mp_robust_body.gd).
	allow_error("Unable to send packet on channel 0", 2, true)
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT, "both clients left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")


## The first registered peer that is neither the host nor `skip`.
func _other_peer(skip: int) -> int:
	var ids: Array = Net.players.keys()
	ids.sort()
	for id: int in ids:
		if id != Const.SERVER_PEER_ID and id != skip:
			return id
	return 0


# --- client A -------------------------------------------------------------------------------------------------------

func _client_a() -> void:
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "A: joined and spawned")
	if Game.local_player == null:
		return
	var me: Player = Game.local_player
	var my_id := multiplayer.get_unique_id()
	var room: Room = Game.world.room
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	check(not Events.is_event_active() and not Events.is_floor_wet(), "A: joined with a dry floor, no event")

	step("A under the sprinklers")
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_SPRINKLERS), STEP_TIMEOUT, "A: event_started(sprinklers) arrived")
	check(_started.back()[0] == Events.EVENT_SPRINKLERS and _started.back()[1].has("seconds") and _started.back()[1].size() == 1, "A: params {seconds}")
	check(Events.is_floor_wet() and _wet == [true] and Events.is_wet_at(RUN_FROM), "A: the floor is wet here too (floor_wet_changed)")
	var water := room.get_node_or_null(^"Sprinklers") as Node3D
	check(water != null and water.get_child_count() == room.get_play_areas().size() and (water.get_child(0) as CPUParticles3D).emitting, "A: water falls in every play area on this peer")
	check(hud != null and hud.get_event_text().begins_with("SPRINKLERS") and hud.event_hint.text == "Wet floor. Do not run." and toast_seen("Sprinklers. Everything is watered."), "A: banner SPRINKLERS, the hint and the toast")
	await wait_until(func() -> bool: return plot(1).water > 0.9 and plot(10).water > 0.9, 3.0, "A: the trays' water is synced to the top")
	var slips := 0
	var runs := 0
	while slips == 0 and runs < 3:
		runs += 1
		me.velocity = Vector3.ZERO
		me.global_position = RUN_FROM + Vector3.UP * 0.05
		me.look_at(RUN_TO + Vector3.UP * 0.05, Vector3.UP)
		me.head.rotation.x = 0.0
		await wait_sec(1.0)   # the host sees it standing there
		Input.action_press(&"sprint")
		Input.action_press(&"move_forward")
		var t1 := Time.get_ticks_msec()
		while not me.is_stunned() and Time.get_ticks_msec() - t1 < 1200:
			await get_tree().process_frame
		Input.action_release(&"move_forward")
		Input.action_release(&"sprint")
		if me.is_stunned():
			slips += 1
	check(slips == 1, "A: sprinting on the wet floor, the host's stagger arrived on this process (runs %d)" % runs)
	check(room.get_area_index(me.global_position) == 0 and me.global_position.distance_to(room.get_station("Well").global_position) > 3.0, "A: it went down in the middle of the main room, nowhere near the tank")
	await wait_until(func() -> bool: return _slipped.has(my_id) and GameState.get_stat(my_id, Const.STAT_SLIPS) >= 1, 3.0, "A: worker_slipped(me) and STAT_SLIPS synced")
	await wait_until(func() -> bool: return not Events.is_event_active() and _ended.size() >= 1, STEP_TIMEOUT, "A: the sprinklers are over")
	check(_ended.back()[0] == Events.EVENT_SPRINKLERS and room.get_node_or_null(^"Sprinklers") == null, "A: event_ended(sprinklers), the water stopped")
	await wait_until(func() -> bool: return not Events.is_floor_wet() and _wet == [true, false], 5.0, "A: the floor dried: floor_wet_changed(false) after the tail")
	check(toast_seen("Sprinklers are off. The floor is still wet.") and toast_seen("The floor is dry."), "A: both toasts")
	await wait_until(func() -> bool: return not me.is_stunned(), 3.0, "A: back on its feet")

	step("A pays the collector")
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_COLLECTION), STEP_TIMEOUT, "A: event_started(collection) arrived")
	var fee := int(_started.back()[1].get("fee", -1))
	check(fee == Config.balance.collector_fee and _started.back()[1].has("seconds"), "A: params {seconds, fee}")
	var man := Events.get_collector()
	check(man != null and man.get_parent() == room and man.fee == fee, "A: the collector stands in this peer's Room")
	if man == null:
		return
	check(hud != null and hud.get_event_text().begins_with("COLLECTION") and hud.event_hint.text == "He wants $%d. Dock." % fee and toast_seen("Collection. He wants $%d." % fee), "A: banner COLLECTION, the hint and the toast")
	await wait_sec(Collector.ARRIVE_SEC + 0.3)
	check(_flat(man.global_position, room.get_collector_spot().origin) < 0.05, "A: he reached his spot on the dock")
	await wait_until(func() -> bool: return GameState.money == 600, 3.0, "A: cash on hand synced (600)")
	check(man.get_prompt(me).contains("Pay $%d" % fee) and man.can_interact(me), "A: prompt '%s'" % man.get_prompt(me))
	var attempts := 0
	while Events.is_event_active(Events.EVENT_COLLECTION) and attempts < 3:
		attempts += 1
		me.velocity = Vector3.ZERO
		me.global_position = man.global_position + Vector3(0.0, 0.05, -1.5)
		me.look_at(Vector3(man.global_position.x, me.global_position.y, man.global_position.z), Vector3.UP)
		me.head.rotation.x = 0.0
		await wait_sec(1.0)
		var interactor := me.get_interactor()
		if interactor.current_target != man:
			print("  (A: not looking at the collector yet: %s)" % [interactor.current_target])
			continue
		Input.action_press(&"interact")
		interactor.try_interact()
		if attempts == 1:
			check(man.is_paying(), "A: the hold started through the Interactor")
			await wait_sec(0.5)
			check(Events.is_event_active(Events.EVENT_COLLECTION) and man.get_pay_progress() > 0.05 and man.get_pay_progress() < 0.8 and man.get_prompt(me).contains(" s"), "A: holding (%.2f), not paid yet" % man.get_pay_progress())
		var t0 := Time.get_ticks_msec()
		while Events.is_event_active(Events.EVENT_COLLECTION) and Time.get_ticks_msec() - t0 < 5000:
			await get_tree().process_frame
		Input.action_release(&"interact")
	check(not Events.is_event_active(), "A: the finished hold paid him on the host (attempts %d)" % attempts)
	# The purchase, collector_paid and event_ended are separate reliable packets.
	await wait_until(func() -> bool: return _paid.size() >= 1 and GameState.money == 600 - fee, 3.0, "A: collector_paid + cash on hand synced")
	check(_paid.size() == 1 and int(_paid[0][0]) == my_id and int(_paid[0][1]) == fee and _collected.is_empty(), "A: collector_paid(me, fee) (%s)" % [_paid])
	check(toast_seen("Alpha paid the collector $%d." % fee) and Events.get_collector() == null, "A: the toast names the worker; he is leaving")
	await wait_sec(Collector.LEAVE_SEC + Collector.TURN_SEC + 0.5)
	check(room.find_children("Collector*", "", false, false).is_empty(), "A: and he is gone from this peer's dock")

	step("A in the raid")
	me.velocity = Vector3.ZERO
	me.global_position = RAID_STAND + Vector3.UP * 0.05
	_written.clear()
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_RAID), STEP_TIMEOUT, "A: event_started(raid) arrived")
	check(_started.back()[0] == Events.EVENT_RAID and _started.back()[1].has("warning") and _started.back()[1].has("seconds"), "A: params {seconds, warning}")
	check(hud != null and hud.get_event_text().begins_with("RAID") and hud.event_hint.text == "Get the product out of sight." and toast_seen("Raid. Get the product out of sight."), "A: banner RAID, the hint and the toast")
	var lights := room.get_node_or_null(^"RaidLights") as Node3D
	check(lights != null and lights.get_node_or_null(^"Pivot/Red") is SpotLight3D and lights.get_node_or_null(^"Pivot/Blue") is SpotLight3D and int(Events.get(&"_raid_siren")) != 0, "A: the lights turn at the roller door, the siren plays")
	check(not Events.is_raid_looking() and _swept.is_empty(), "A: the warning first")
	await wait_until(func() -> bool: return me.get_held_item() != null, 3.0, "A: the bundle the host handed over is in hand")
	# raid_took, raid_swept and the item's despawn are separate reliable packets.
	await wait_until(func() -> bool: return me.get_held_item() == null and not _took.is_empty() and _swept.size() >= 2, STEP_TIMEOUT, "A: standing in sight, the bundle is taken out of its hands")
	check(Events.is_raid_looking() and int(_took[0][1]) == my_id and int(_swept[0][0]) == 0 and int(_swept[0][1]) == 0 and int(_swept[1][0]) == 1 and int(_swept[1][1]) == 1, "A: raid_took(the bundle, me): not by the look from the door, by the one from the passage (%s)" % [_swept])
	await wait_until(func() -> bool: return _written.size() >= 1 and GameState.get_write_ups(my_id) >= 1, 3.0, "A: written up, strikes synced")
	check(int(_written[0][0]) == my_id and _written[0][1] == Const.WRITE_UP_RAID and toast_seen("They are looking in."), "A: worker_written_up(me, raid); the toast when they look in")
	await wait_until(func() -> bool: return not Events.is_event_active(), STEP_TIMEOUT, "A: the raid is over")
	check(room.get_node_or_null(^"RaidLights") == null and int(Events.get(&"_raid_siren")) == 0 and (hud == null or hud.get_event_text() == ""), "A: lights gone, siren stopped, banner gone")
	check(_took.size() == 2 and toast_seen("They took two. Alpha was holding one."), "A: the floor hears the count (%s)" % Story.last_bark)
	await _leave("A")


# --- client B (late joiner) ---------------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	var room: Room = Game.world.room
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_RAID), 6.0, "B: joined during the raid: the event replay arrived")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_RAID and _started.back()[1].has("seconds") and _started.back()[1].has("warning"), "B: event_started(raid, {seconds, warning}) from the late-join replay")
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() <= float(_started.back()[1]["seconds"]), "B: time left synced (%.1f)" % Events.get_event_time_left())
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	check(hud != null and hud.get_event_text().begins_with("RAID"), "B: the HUD banner reads RAID (%s)" % (hud.get_event_text() if hud != null else "no HUD"))
	check(hud != null and hud.event_hint.visible and hud.event_hint.text == "Get the product out of sight.", "B: its hint says to hide the product")
	var lights := room.get_node_or_null(^"RaidLights") as Node3D
	check(lights != null and lights.get_node_or_null(^"Pivot/Red") is SpotLight3D and lights.get_node_or_null(^"Pivot/Blue") is SpotLight3D and lights.get_node_or_null(^"Glow") is OmniLight3D, "B: the lights at the roller door are built from the replay")
	check(lights != null and _flat(lights.global_position, room.get_roller_door_position()) < 1.5 and int(Events.get(&"_raid_siren")) != 0, "B: at the door, with the siren")
	var pivot := lights.get_node_or_null(^"Pivot") as Node3D if lights != null else null
	var yaw0 := pivot.rotation.y if pivot != null else 0.0
	await wait_sec(0.4)
	check(pivot != null and not is_equal_approx(pivot.rotation.y, yaw0), "B: the beams turn")
	print("  (B: joined %s)" % ("while they look" if Events.is_raid_looking() else "during the sirens"))
	await wait_until(func() -> bool: return Events.is_raid_looking(), STEP_TIMEOUT, "B: they are looking in")
	await wait_until(func() -> bool: return _swept.size() >= 1, 4.0, "B: raid_swept arrives here")
	await wait_until(func() -> bool: return _took.size() >= 1 and int(_took.back()[1]) == 0, STEP_TIMEOUT, "B: raid_took for the bundle dropped after it joined")
	await wait_until(func() -> bool: return items_of(Const.ITEM_PRODUCT).is_empty(), 3.0, "B: no bundle left on this peer's floor (the despawn is its own packet)")
	await wait_until(func() -> bool: return not Events.is_event_active(), STEP_TIMEOUT, "B: the raid is over")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_RAID and (hud == null or hud.get_event_text() == ""), "B: event_ended(raid), the banner is gone")
	check(room.get_node_or_null(^"RaidLights") == null and int(Events.get(&"_raid_siren")) == 0 and toast_seen("They took"), "B: lights gone, siren stopped, the count is told")
	check(not Events.is_floor_wet() and room.find_children("Collector*", "", false, false).is_empty(), "B: nothing of the earlier events on this peer")
	await _leave("B")


# --- shared ---------------------------------------------------------------------------------------------------------

func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	await wait_sec(0.5)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(not Events.is_event_active() and Events.is_power_on() and not Events.is_floor_wet(), "%s: events reset locally" % tag)


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
