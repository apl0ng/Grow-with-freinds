extends "res://tools/tests/qa_base.gd"
## M14 mayhem multi-process suite (mayhem agent), driven by tools/tests/mayhem_mp.sh: a host, client A (joins at the
## start) and client B (joins DURING the drive-by).
##   host: shift, LEAK (marker MAYHEM_LEAK); waits until A's hold patched it and until A slipped in the puddle; puts a
##         can in A's hands and starts a long DRIVE-BY (marker MAYHEM_DRIVEBY starts B); waits until B is in, until a
##         round knocked A down, until B has crouched in a lane for three seconds unharmed; lets the timer run out
##         (the bill); waits for the clients to leave.
##   a:    sees the leak (the Well's state + the event: two reliable packets), the banner, the prompt; waits for the
##         puddle to spread on its own clock; patches the hole through the real hold (Interactor.try_interact + the
##         held key); sees who patched; sprints through the puddle with real input and goes down on its own process;
##         in the drive-by stands in a lane, is knocked down on its own process and drops the can; sees the bill.
##   b:    joins during the drive-by: the event, the banner and the hint, the rounds, the Well's plate and puddle from
##         the replay; crouches in a lane and is not hit; sees the bill and the end. Leaves.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0
## A wants the puddle this wide before patching, so its run through it is long enough to be judged.
const PUDDLE_WANTED := 1.6

var role: String = "host"
var port: int = 7970
var _started: Array = []
var _ended: Array = []
var _resolved: Array = []
var _slipped: Array = []
var _shots: int = 0
var _shot_workers: Array = []
var _billed: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7970))
	_label = "mayhem_mp:" + role
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.leak_resolved.connect(func(patched: bool, by: int) -> void: _resolved.append([patched, by]))
	Events.worker_slipped.connect(func(p: int) -> void: _slipped.append(p))
	Events.shot_fired.connect(func(_from: Vector3, _to: Vector3) -> void: _shots += 1)
	Events.worker_shot.connect(func(p: int) -> void: _shot_workers.append(p))
	Events.driveby_billed.connect(func(fine: int, taken: int) -> void: _billed.append([fine, taken]))
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
	print("MAYHEM_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	var a_id := _other_peer(0)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(600 - GameState.money)
	var b: BalanceConfig = Config.balance
	var well := _well()
	var lanes: Array = Game.world.room.get_gunfire_lanes()
	var safe := _safe_spots(lanes, 3)
	check(safe.size() == 3, "host: three spots clear of every lane")
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = safe[0] + Vector3.UP * 0.05
	await wait_sec(0.5)

	step("leak")
	Config.balance.puddle_sec = 300.0   # the puddle is still there when B joins
	check(Events.server_start_event(Events.EVENT_LEAK), "leak started")
	check(well != null and well.is_leaking() and well.has_puddle(), "host: the tank leaks")
	print("MAYHEM_LEAK")
	await wait_until(func() -> bool: return not well.is_leaking(), STEP_TIMEOUT, "client A's hold patched the leak")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_LEAK, "host: event over")
	check(_resolved.size() == 1 and _resolved[0][0] == true and int(_resolved[0][1]) == a_id, "host: patched by A (%s)" % [_resolved])
	check(well.is_patched() and well.has_pressure() and well.has_puddle(), "host: the plate is on, nothing lost, the puddle stays (%.2f m)" % well.get_puddle_radius())
	check(Events.get_event_time_left() == 0.0 and well.get_puddle_radius() >= PUDDLE_WANTED - 0.2, "host: A let it spread first")
	await wait_until(func() -> bool: return GameState.get_stat(a_id, Const.STAT_SLIPS) >= 1, STEP_TIMEOUT, "A slipped in the puddle (judged from its synced position)")
	check(_slipped.has(a_id), "host: worker_slipped(A)")
	await wait_sec(2.0)   # A gets up
	check(GameState.get_stat(1, Const.STAT_SLIPS) == 0, "host: the host standing by did not slip")

	step("drive-by")
	var can := Game.world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, safe[1], a_id)
	check(can != null and Game.world.items.get_held_by(a_id) == can, "host: A carries a can")
	Config.balance.driveby_sec = 120.0   # long enough for B to join in the middle of it; the host cuts it short below
	var shot_a0 := GameState.get_stat(a_id, Const.STAT_SHOT)
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "drive-by started")
	print("MAYHEM_DRIVEBY")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and Game.world.get_players().size() >= 3, JOIN_TIMEOUT, "client B joined during the drive-by")
	var b_id := _other_peer(a_id)
	check(Events.is_event_active(Events.EVENT_DRIVEBY), "host: the drive-by runs while B joins (%.1f s left)" % Events.get_event_time_left())
	await wait_until(func() -> bool: return GameState.get_stat(a_id, Const.STAT_SHOT) > shot_a0, STEP_TIMEOUT, "a round knocked A down")
	check(_shot_workers.has(a_id) and Game.world.items.get_held_by(a_id) == null, "host: worker_shot(A), the can left its hands")
	var lane: Dictionary = lanes[_open_lane(lanes)]
	var b_player := Game.world.get_player(b_id)
	await wait_until(func() -> bool: return b_player != null and b_player.crouching and _in_lane(lane, b_player.global_position), STEP_TIMEOUT, "B crouches in the lane (synced crouch + position)")
	var shot_b0 := GameState.get_stat(b_id, Const.STAT_SHOT)
	var rounds0 := Events.get_driveby_shots()
	await wait_sec(3.0)
	check(Events.get_driveby_shots() >= rounds0 + 12, "host: %d more rounds in three seconds" % (Events.get_driveby_shots() - rounds0))
	check(b_player.crouching and _in_lane(lane, b_player.global_position) and GameState.get_stat(b_id, Const.STAT_SHOT) == shot_b0, "host: B, crouched in the lane, was not hit")
	check(GameState.get_stat(1, Const.STAT_SHOT) == 0, "host: the host, clear of the lanes, was not hit")
	var money0 := GameState.money
	Events.set(&"_time_left", 0.3)   # the timer runs out: the bill
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "the drive-by ran out")
	check(_billed.size() == 1 and int(_billed[0][0]) == b.driveby_fine and int(_billed[0][1]) == b.driveby_fine and GameState.money == money0 - b.driveby_fine, "host: billed %d, cash on hand %d" % [b.driveby_fine, GameState.money])
	print("MAYHEM_DONE")
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
	var well := _well()
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	check(well != null and not well.is_leaking() and not Events.is_event_active(), "A: joined with a dry tank, no event")
	# The Well's leak state and event_started are two reliable packets: the second may land a poll later.
	await wait_until(func() -> bool: return well.is_leaking() and Events.is_event_active(Events.EVENT_LEAK), STEP_TIMEOUT, "A: the leak state + event_started(leak) arrived")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_LEAK and _started.back()[1].has("seconds"), "A: event_started(leak, {seconds})")
	check(well.has_puddle() and well.get_prompt(me).contains("Patch the leak") and well.can_interact(me), "A: a puddle, the prompt 'Patch the leak'")
	var jet := well.get_node_or_null(^"Leak/Jet") as CPUParticles3D
	check(jet != null and jet.emitting, "A: the jet runs here too")
	check(hud != null and hud.get_event_text().begins_with("LEAK") and toast_seen("The tank is leaking"), "A: banner LEAK and the toast")
	await wait_until(func() -> bool: return well.get_puddle_radius() >= PUDDLE_WANTED, 15.0, "A: the puddle spreads on this peer's own clock")

	step("A patches the leak")
	var attempts := 0
	while well.is_leaking() and attempts < 3:
		attempts += 1
		stand_near(well, 1.3)
		me.head.rotation.x = -0.7
		await wait_sec(1.0)
		var interactor := me.get_interactor()
		if interactor.current_target != well:
			print("  (A: not looking at the tank yet: %s)" % [interactor.current_target])
			continue
		Input.action_press(&"interact")
		interactor.try_interact()
		if attempts == 1:
			check(well.is_patching(), "A: the hold started through the Interactor")
			await wait_sec(0.5)
			check(well.is_leaking() and well.get_patch_progress() > 0.05 and well.get_patch_progress() < 0.6 and well.get_prompt(me).contains(" s"), "A: holding (%.2f), still leaking" % well.get_patch_progress())
		var t0 := Time.get_ticks_msec()
		while well.is_leaking() and Time.get_ticks_msec() - t0 < 5000:
			await get_tree().process_frame
		Input.action_release(&"interact")
	check(not well.is_leaking(), "A: the finished hold patched the leak on the host (attempts %d)" % attempts)
	# The leak state, leak_resolved and event_ended are separate reliable packets.
	await wait_until(func() -> bool: return not Events.is_event_active() and _resolved.size() >= 1, 3.0, "A: leak_resolved + event_ended arrived")
	check(_resolved.size() == 1 and _resolved[0][0] == true and int(_resolved[0][1]) == my_id, "A: leak_resolved(patched, by me) (%s)" % [_resolved])
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_LEAK, "A: event_ended(leak)")
	check(well.is_patched() and well.has_pressure() and well.has_puddle() and well.get_puddle_radius() >= PUDDLE_WANTED - 0.2, "A: the plate is on, the puddle stays (%.2f m)" % well.get_puddle_radius())
	check(toast_seen("Alpha patched the tank."), "A: the toast names the worker")
	check(not well.is_patching() and jet != null and not jet.emitting, "A: hold cleared, the jet stopped")

	step("A runs through the puddle")
	var c := well.get_puddle_center()
	var r := well.get_puddle_radius()
	var slips := 0
	var runs := 0
	while slips == 0 and runs < 3:
		runs += 1
		me.velocity = Vector3.ZERO
		me.global_position = Vector3(c.x, 0.05, c.z - r - 1.5)
		me.look_at(Vector3(c.x, 0.05, c.z), Vector3.UP)
		me.head.rotation.x = 0.0
		await wait_sec(1.0)   # the host sees it standing there
		Input.action_press(&"sprint")
		Input.action_press(&"move_forward")
		var t1 := Time.get_ticks_msec()
		while not me.is_stunned() and Time.get_ticks_msec() - t1 < 1500:
			await get_tree().process_frame
		Input.action_release(&"move_forward")
		Input.action_release(&"sprint")
		if me.is_stunned():
			slips += 1
	check(slips == 1, "A: sprinting through the puddle, the host's stagger arrived on this process (runs %d)" % runs)
	check(Vector2(me.global_position.x - c.x, me.global_position.z - c.z).length() < r + 4.0, "A: it went down by the puddle")
	await wait_until(func() -> bool: return _slipped.has(my_id) and GameState.get_stat(my_id, Const.STAT_SLIPS) >= 1, 3.0, "A: worker_slipped(me) and STAT_SLIPS synced")
	await wait_until(func() -> bool: return not me.is_stunned(), 3.0, "A: back on its feet")

	step("A in the drive-by")
	var lanes: Array = Game.world.room.get_gunfire_lanes()
	var lane: Dictionary = lanes[_open_lane(lanes)]
	var safe := _safe_spots(lanes, 3)
	me.velocity = Vector3.ZERO
	me.global_position = _at(lane, 3.5) + Vector3.UP * 0.05   # standing in the lane before the cars come
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_DRIVEBY), STEP_TIMEOUT, "A: event_started(driveby) arrived")
	check(_started.back()[0] == Events.EVENT_DRIVEBY and _started.back()[1].has("warning"), "A: params {seconds, warning}")
	check(hud != null and hud.get_event_text().begins_with("DRIVE-BY") and hud.event_hint.text == "Get down." and toast_seen("Drive-by. Get down."), "A: banner DRIVE-BY, the hint and the toast")
	check(not Events.is_driveby_firing() and _shots == 0, "A: the warning first")
	await wait_until(func() -> bool: return me.get_held_item() != null, 3.0, "A: the can the host handed over is in hand")
	await wait_until(func() -> bool: return me.is_stunned(), STEP_TIMEOUT, "A: standing in a lane, knocked down on this process")
	# The knock-down is a reliable packet and the rounds are unreliable ones: under load the stun can be read first.
	await wait_until(func() -> bool: return _shots >= 1, 3.0, "A: the first round is drawn here")
	check(Events.is_driveby_firing() and _shots >= 1, "A: the rounds arrive here (%d so far)" % _shots)
	await wait_until(func() -> bool: return _shot_workers.has(my_id) and GameState.get_stat(my_id, Const.STAT_SHOT) >= 1 and me.get_held_item() == null, 3.0, "A: worker_shot(me), STAT_SHOT synced, the can dropped")
	await wait_until(func() -> bool: return not me.is_stunned(), 3.0, "A: up again")
	me.velocity = Vector3.ZERO
	me.global_position = safe[1] + Vector3.UP * 0.05   # out of the lanes
	await wait_until(func() -> bool: return not Events.is_event_active(), STEP_TIMEOUT, "A: the drive-by is over")
	await wait_until(func() -> bool: return _billed.size() >= 1 and GameState.money == 600 - Config.balance.driveby_fine, 3.0, "A: driveby_billed + cash on hand synced")
	check(int(_billed[0][0]) == Config.balance.driveby_fine and int(_billed[0][1]) == Config.balance.driveby_fine and toast_seen("out of cash on hand"), "A: the bill (%s)" % [_billed])
	await _leave("A")


# --- client B (late joiner) ---------------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	var me: Player = Game.local_player
	var my_id := multiplayer.get_unique_id()
	var well := _well()
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_DRIVEBY), 6.0, "B: joined during the drive-by: the event replay arrived")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_DRIVEBY and _started.back()[1].has("seconds") and _started.back()[1].has("warning"), "B: event_started(driveby, {seconds, warning}) from the late-join replay")
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() <= float(_started.back()[1]["seconds"]), "B: time left synced (%.1f)" % Events.get_event_time_left())
	await wait_until(func() -> bool: return Events.is_driveby_firing(), 4.0, "B: the guns are going")
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	check(hud != null and hud.get_event_text().begins_with("DRIVE-BY"), "B: the HUD banner reads DRIVE-BY (%s)" % (hud.get_event_text() if hud != null else "no HUD"))
	check(hud != null and hud.event_hint.visible and hud.event_hint.text == "Get down.", "B: its hint says 'Get down.'")
	# The Well's leak state is its own reliable packet.
	await wait_until(func() -> bool: return well != null and well.is_patched() and well.has_puddle(), 4.0, "B: the Well's replay: the plate and the puddle")
	check(not well.is_leaking() and well.has_pressure() and well.get_puddle_radius() >= PUDDLE_WANTED - 0.2, "B: no jet, pressure on, the puddle at the host's size (%.2f m)" % well.get_puddle_radius())
	var plate := well.get_node_or_null(^"Leak/Plate") as Node3D
	check(plate != null and plate.visible and well.get_prompt(me).begins_with("Fill can"), "B: the plate is on the tank, the prompt is plain")
	await wait_until(func() -> bool: return _shots >= 3, 5.0, "B: rounds are seen and heard here")
	await wait_until(func() -> bool: return Game.world.room.find_children("*Tracer*", "MeshInstance3D", false, false).size() >= 1, 3.0, "B: a tracer is drawn in the room")

	step("B gets down in a lane")
	var lanes: Array = Game.world.room.get_gunfire_lanes()
	var lane: Dictionary = lanes[_open_lane(lanes)]
	Input.action_press(&"crouch")
	await wait_until(func() -> bool: return me.crouching, 2.0, "B: crouched")
	me.velocity = Vector3.ZERO
	me.global_position = _at(lane, 1.2) + Vector3.UP * 0.05
	await wait_sec(0.6)
	await wait_until(func() -> bool: return not me.is_stunned(), 3.0, "B: steady")
	var hits0 := _shot_workers.count(my_id)
	var shots0 := _shots
	await wait_sec(3.5)
	check(_shots >= shots0 + 10, "B: %d rounds went by" % (_shots - shots0))
	check(me.crouching and not me.is_stunned() and _shot_workers.count(my_id) == hits0, "B: crouched in the lane, not hit")
	await wait_until(func() -> bool: return not Events.is_event_active(), STEP_TIMEOUT, "B: the drive-by is over")
	Input.action_release(&"crouch")
	await wait_until(func() -> bool: return _billed.size() >= 1 and GameState.money == 600 - Config.balance.driveby_fine, 3.0, "B: driveby_billed + cash on hand synced")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_DRIVEBY and (hud == null or hud.get_event_text() == ""), "B: event_ended(driveby), the banner is gone")
	await _leave("B")


# --- shared ---------------------------------------------------------------------------------------------------------

func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	await wait_sec(0.5)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(not Events.is_event_active() and Events.is_power_on(), "%s: events reset locally" % tag)


func _well() -> Well:
	if Game.world == null:
		return null
	return Game.world.room.get_station("Well") as Well


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Where a lane stops: its first LAYER_WORLD hit, or its end.
func _lane_end(lane: Dictionary) -> Vector3:
	var space := Game.world.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(lane["from"], lane["to"], Const.LAYER_WORLD))
	return hit["position"] if not hit.is_empty() else lane["to"]


## The index of the lane with the longest open stretch (the same on every peer: the room is the same).
func _open_lane(lanes: Array) -> int:
	var best := 0
	var open := -1.0
	for i in lanes.size():
		var l: Dictionary = lanes[i]
		var d := _flat(l["from"], _lane_end(l))
		if d > open:
			open = d
			best = i
	return best


## The floor point `metres` down the lane.
func _at(lane: Dictionary, metres: float) -> Vector3:
	var from: Vector3 = lane["from"]
	var end := _lane_end(lane)
	var d := Vector3(end.x - from.x, 0.0, end.z - from.z).normalized()
	return Vector3(from.x, 0.0, from.z) + d * metres


## True when `point` stands inside the lane's worker radius.
func _in_lane(lane: Dictionary, point: Vector3) -> bool:
	var near := Events._lane_closest(lane["from"], _lane_end(lane), point)
	return _flat(near, point) <= Events.DRIVEBY_WORKER_RADIUS


## Up to `count` floor points inside the room at least 2 m (flat) from every lane and 1.5 m from each other.
func _safe_spots(lanes: Array, count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var bounds := Game.world.room.get_bounds()
	var x := bounds.position.x + 1.0
	while x < bounds.end.x - 0.9 and out.size() < count:
		var z := bounds.position.z + 3.5
		while z < bounds.end.z - 0.9 and out.size() < count:
			var p := Vector3(x, 0.0, z)
			var ok := true
			for l: Dictionary in lanes:
				var near := Events._lane_closest(l["from"], l["to"], p)
				if _flat(near, p) < 2.0:
					ok = false
			for o in out:
				if _flat(o, p) < 1.5:
					ok = false
			if ok:
				out.append(p)
			z += 0.5
		x += 0.5
	return out
