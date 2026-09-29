extends "res://tools/tests/qa_base.gd"
## M10 events multi-process suite (events agent), driven by tools/tests/events_mp.sh: a host, client A (joins at
## the start) and client B (joins DURING the power cut).
##   host: shift, POWER_CUT (marker EVENTS_POWER_CUT in its log starts B), waits for A's fuse-box reset, then an
##         INSPECTION it ends itself, then waits for the clients to leave.
##   a:    sees event_started(power_cut) / power_changed(false) / Room power off; once B is in, stands at the fuse
##         box and requests the reset -> the host ends the cut (event_ended + power_changed(true) here); then sees
##         the inspection start (the Boss walks on this peer) and end; leaves clean.
##   b:    joins during the cut: power_on == false and the power_cut active right after joining (late-join sync),
##         then the same inspection checks; leaves clean.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0

var role: String = "host"
var port: int = 7844
var _started: Array = []
var _ended: Array = []
var _power: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7844))
	_label = "events_mp:" + role
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.power_changed.connect(func(on: bool) -> void: _power.append([on]))
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
	print("EVENTS_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	await wait_sec(0.5)
	step("power cut")
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut started")
	check(not Events.is_power_on() and not Game.world.room.is_power_on(), "host: power off")
	print("EVENTS_POWER_CUT")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and Game.world.get_players().size() >= 3, JOIN_TIMEOUT, "client B joined during the cut")
	await wait_until(func() -> bool: return Events.is_power_on(), STEP_TIMEOUT, "a client's fuse-box reset restored the power")
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_POWER_CUT, "host: event_ended(power_cut)")
	await wait_sec(0.5)
	step("inspection")
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection started")
	var boss := _boss()
	check(boss != null and boss.is_walking(), "host: the Boss walks")
	await wait_sec(2.5)
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.back()[0] == Events.EVENT_INSPECTION, "host: inspection ended")
	print("EVENTS_INSPECTION_DONE")
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT, "both clients left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")


# --- client A -------------------------------------------------------------------------------------------------------

func _client_a() -> void:
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "A: joined and spawned")
	if Game.local_player == null:
		return
	check(Events.is_power_on() and not Events.is_event_active(), "A: joined with the power on, no event")
	await wait_until(func() -> bool: return not Events.is_power_on(), STEP_TIMEOUT, "A: power_changed(false) arrived")
	check(Events.is_event_active(Events.EVENT_POWER_CUT), "A: power cut active")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_POWER_CUT and _started.back()[1].has("max_seconds"), "A: event_started(power_cut, {max_seconds})")
	check(_power.size() >= 1 and _power.back()[0] == false, "A: power_changed(false)")
	check(not Game.world.room.is_power_on(), "A: Room power off")
	check(Events.get_event_time_left() > 0.0, "A: time left counts down locally (%.1f)" % Events.get_event_time_left())
	var fuse := Game.world.room.get_station("FuseBox") as FuseBox
	check(fuse != null and fuse.is_tripped(), "A: the fuse box is tripped")
	await wait_until(func() -> bool: return Net.players.size() >= 3, STEP_TIMEOUT, "A: B is in")
	step("A resets the breaker")
	stand_near(fuse, 1.3)
	await wait_sec(1.2)
	var attempts := 0
	while not Events.is_power_on() and attempts < 6:
		attempts += 1
		fuse.request_reset()
		await wait_until_quiet(func() -> bool: return Events.is_power_on(), 2.5)
	check(Events.is_power_on(), "A: the reset request ended the cut on the host (attempts %d)" % attempts)
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_POWER_CUT, "A: event_ended(power_cut)")
	check(_power.size() >= 2 and _power.back()[0] == true, "A: power_changed(true)")
	check(Game.world.room.is_power_on() and not fuse.is_tripped(), "A: Room power on, breaker live")
	await _inspection_checks("A")
	await _leave("A")


# --- client B (late joiner) ---------------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	await wait_until(func() -> bool: return not Events.is_power_on(), 6.0, "B: joined during the cut: power_on == false")
	check(Events.is_event_active(Events.EVENT_POWER_CUT), "B: the running power cut was synced on join")
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() <= Config.balance.power_cut_max_sec, "B: time left synced (%.1f)" % Events.get_event_time_left())
	check(not Game.world.room.is_power_on(), "B: Room power off")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_POWER_CUT, "B: event_started(power_cut) emitted from the late-join sync")
	await wait_until(func() -> bool: return Events.is_power_on(), STEP_TIMEOUT, "B: power back after A's reset")
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_POWER_CUT, "B: event_ended(power_cut)")
	await _inspection_checks("B")
	await _leave("B")


# --- shared ---------------------------------------------------------------------------------------------------------

func _inspection_checks(tag: String) -> void:
	step("%s inspection" % tag)
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_INSPECTION), STEP_TIMEOUT, "%s: event_started(inspection)" % tag)
	var boss := _boss()
	check(boss != null, "%s: the Boss exists on this peer" % tag)
	if boss != null:
		await wait_until(func() -> bool: return boss.is_walking(), 2.0, "%s: the Boss walks on this peer" % tag)
		var p0 := boss.global_position
		await wait_sec(0.8)
		check(boss.global_position.distance_to(p0) > 0.3, "%s: he moves here too (%.2f m)" % [tag, boss.global_position.distance_to(p0)])
	check(_started.back()[1].has("seconds") and _started.back()[1].has("speed"), "%s: inspection params carry seconds + speed" % tag)
	await wait_until(func() -> bool: return not Events.is_event_active(), STEP_TIMEOUT, "%s: event_ended(inspection)" % tag)
	check(_ended.back()[0] == Events.EVENT_INSPECTION, "%s: last event_ended is the inspection" % tag)
	if boss != null:
		await wait_frames(2)
		check(not boss.is_walking(), "%s: the Boss stopped" % tag)


func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(not Events.is_event_active() and Events.is_power_on(), "%s: events reset locally" % tag)


func _boss() -> ShopkeeperNPC:
	if Game.world == null:
		return null
	var counter := Game.world.room.get_station("ShopCounter")
	return counter.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC if counter != null else null
