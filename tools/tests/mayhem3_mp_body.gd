extends "res://tools/tests/qa_base.gd"
## M17 mayhem3 multi-process suite (mayhem3 agent), driven by tools/tests/mayhem3_mp.sh: a host, client A (joins at the
## start) and client B (joins while the phone rings a second time and a favor runs). Every process runs with --events;
## the host stops its scheduler once the shift starts and starts the events itself.
##   host: shift; puts a bundle in A's hands and takes the SCALE off (waits until A's shove key at the chute fixed it);
##         rings the PHONE with a favor on the line (waits until A's hold took the call: the seeds are cheaper);
##         rings it AGAIN (marker MAYHEM3_PHONE2 starts B) and lets it ring out: the fine; ends the favor; waits for the
##         clients to leave.
##   a:    sees the scale go off (the event, the banner, the toast, the chute's light price for the bundle in its own
##         hands), walks up and presses the shove key (Input.parse_input_event: Events._input on its own process), sees
##         who hit it and the full price again; hears the phone (the loop, the ringing handset, the banner), answers it
##         through the real hold (Interactor.try_interact + the held key), sees the favor (the signal, the discount, the
##         seed price) and the toast; lets the second call ring out: the fine, the Boss, cash on hand; the favor ends.
##   b:    joins during the second ring: the event replay (the bell, the ringing phone, the banner), the running favor
##         (the discount and its time left, before the event packet), then the fine and the end of the favor. Leaves.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0
## Where the host waits: the corridor south of the pen, out of everybody's way.
const HOST_SPOT := Vector3(8.0, 0.05, 6.2)

var role: String = "host"
var port: int = 7934
var _started: Array = []
var _ended: Array = []
var _fixed: Array = []
var _answered: Array = []
var _missed: Array = []
var _discount: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7934))
	_label = "mayhem3_mp:" + role
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.scale_fixed.connect(func(p: int) -> void: _fixed.append(p))
	Events.phone_answered.connect(func(p: int, o: StringName) -> void: _answered.append([p, o]))
	Events.phone_missed.connect(func(f: int) -> void: _missed.append(f))
	Events.phone_discount_changed.connect(func(f: float) -> void: _discount.append(f))
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
	print("MAYHEM3_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	var a_id := _other_peer(0)
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.are_events_enabled() and Events.get_next_event_in() > 0.0, "--events: the scheduler is armed (%.0f s)" % Events.get_next_event_in())
	Config.user_args.erase("events")   # this suite starts its own events
	Events.set(&"_next_in", -1.0)
	GameState.server_add_money(600 - GameState.money)
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = HOST_SPOT
	await wait_sec(0.5)

	step("the scale")
	var seed0: SeedDef = b.seeds[0]
	var held := Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed0.id, "amount": 1}, Vector3.ZERO, a_id)
	check(held != null and Game.world.items.get_held_by(a_id) == held, "host: A carries a bundle")
	await wait_sec(0.5)
	b.scale_sec = 120.0   # A fixes it long before
	check(Events.server_start_event(Events.EVENT_SCALE), "the scale goes off")
	print("MAYHEM3_SCALE")
	await wait_until(func() -> bool: return not _fixed.is_empty(), STEP_TIMEOUT, "A's shove key at the chute fixed the scale")
	check(_fixed == [a_id] and not Events.is_scale_off() and Events.get_scale_factor() == 1.0, "host: scale_fixed(A), the scale reads right (%s)" % [_fixed])
	var chute := Game.world.room.get_station("TurnInStation") as TurnInStation
	check(chute.get_sale_value(held) == TurnInStation.compute_sale_value(seed0, 1, GameState.get_sale_multiplier()), "host: the chute pays A's bundle in full")
	await wait_sec(1.0)
	Game.world.items.server_despawn_item(held)

	step("the phone: a favor")
	b.phone_sec = 120.0   # A answers long before
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	Events.set(&"_phone_outcome", Events.PHONE_FAVOR)
	print("MAYHEM3_PHONE1")
	await wait_until(func() -> bool: return not _answered.is_empty(), STEP_TIMEOUT, "A's hold took the call")
	check(_answered.size() == 1 and int(_answered[0][0]) == a_id and _answered[0][1] == Events.PHONE_FAVOR and not Events.is_event_active(), "host: phone_answered(A, favor) (%s)" % [_answered])
	var factor := 1.0 - b.phone_discount
	check(is_equal_approx(Events.get_phone_discount(), factor) and GameState.get_seed_cost(seed0) == maxi(int(round(seed0.cost * factor)), 1), "host: the seeds cost %.0f%% (%d)" % [factor * 100.0, GameState.get_seed_cost(seed0)])
	await wait_sec(1.5)

	step("the phone again: nobody answers, B joins")
	b.phone_sec = 25.0   # B joins while it rings
	var money0 := GameState.money
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings again")
	print("MAYHEM3_PHONE2")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and Game.world.get_players().size() >= 3, JOIN_TIMEOUT, "client B joined while it rang")
	check(Events.is_event_active(Events.EVENT_PHONE) and Events.get_phone_discount() < 1.0, "host: still ringing (%.1f s left), the favor still runs" % Events.get_event_time_left())
	await wait_until(func() -> bool: return not _missed.is_empty(), STEP_TIMEOUT, "the call rang out")
	check(_missed == [b.phone_fine] and GameState.money == money0 - b.phone_fine and _answered.size() == 1, "host: phone_missed(%d), $%d out of cash on hand" % [b.phone_fine, money0 - GameState.money])
	await wait_sec(1.0)
	Events.set(&"_phone_discount_left", 0.3)   # the favor runs out now
	await wait_until(func() -> bool: return Events.get_phone_discount() == 1.0, 3.0, "host: the favor ran out")
	check(_discount == [factor, 1.0] and GameState.get_seed_cost(seed0) == seed0.cost, "host: the plain price again (%s)" % [_discount])
	print("MAYHEM3_DONE")
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
	var chute := room.get_station("TurnInStation") as TurnInStation
	var phone := Events.get_wall_phone()
	check(chute != null and phone != null, "A: the chute and the wall phone exist on this peer")
	var b: BalanceConfig = Config.balance

	step("A and the scale")
	await wait_until(func() -> bool: return Events.is_scale_off(), STEP_TIMEOUT, "A: event_started(scale) arrived")
	var p: Dictionary = _started.back()[1]
	check(p.has("seconds") and is_equal_approx(float(p.get("cut", -1.0)), b.scale_cut) and is_equal_approx(Events.get_scale_factor(), 1.0 - b.scale_cut), "A: params {seconds, cut}, the factor %.2f here too" % Events.get_scale_factor())
	check(hud != null and hud.get_event_text().begins_with("SCALE IS OFF") and hud.event_hint.text == "It reads light. Hit it." and toast_seen("The scale reads light"), "A: banner SCALE IS OFF, the hint and the toast")
	await wait_until(func() -> bool: return me.get_held_item() != null, 3.0, "A: the bundle the host handed over is in hand")
	var held := me.get_held_item()
	var seed0: SeedDef = b.get_seed(StringName(str(held.get(&"strain_id")))) if held != null else b.seeds[0]
	var light := TurnInStation.compute_sale_value(seed0, 1, GameState.get_sale_multiplier() * (1.0 - b.scale_cut))
	var full := TurnInStation.compute_sale_value(seed0, 1, GameState.get_sale_multiplier())
	check(held != null and chute.get_sale_value(held) == light and chute.get_prompt(me).ends_with("(+$%d)" % light), "A: the chute's prompt shows the light price ($%d, full $%d)" % [light, full])
	var attempts := 0
	while Events.is_scale_off() and attempts < 3:
		attempts += 1
		await _aim(me, _chute_stand(chute, 1.0), chute.get_collider_aabb().get_center())
		await wait_sec(1.0)   # the host sees it standing there
		if not Events.is_aiming_at_scale(me):
			print("  (A: not aimed at the chute yet: reach %.2f)" % Events.get_scale_reach(me))
			continue
		_press(&"shove", true)
		await wait_frames(2)
		_press(&"shove", false)
		var t0 := Time.get_ticks_msec()
		while Events.is_scale_off() and Time.get_ticks_msec() - t0 < 3000:
			await get_tree().process_frame
	check(not Events.is_scale_off(), "A: the shove key at the chute fixed the scale on the host (attempts %d)" % attempts)
	await wait_until(func() -> bool: return not _fixed.is_empty(), 3.0, "A: scale_fixed arrived")
	check(_fixed == [my_id] and toast_seen("Alpha hit the scale. It reads right."), "A: scale_fixed(me), the toast names me (%s)" % [_fixed])
	check(held != null and is_instance_valid(held) and chute.get_sale_value(held) == full and (hud == null or hud.get_event_text() == ""), "A: the full price again, the banner gone")

	step("A takes the call")
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_PHONE), STEP_TIMEOUT, "A: event_started(phone) arrived")
	check(_started.back()[1].has("seconds") and _started.back()[1].size() == 1, "A: params {seconds}")
	check(int(Events.get(&"_phone_ring")) != 0 and phone.is_ringing(), "A: the bell rings at the phone on this peer, the handset rattles")
	check(hud != null and hud.get_event_text().begins_with("PHONE") and hud.event_hint.text == "Somebody pick that up." and toast_seen("The phone is ringing."), "A: banner PHONE, the hint and the toast")
	var hold_attempts := 0
	while Events.is_event_active(Events.EVENT_PHONE) and hold_attempts < 3:
		hold_attempts += 1
		var pp := phone.global_position
		await _aim(me, Vector3(pp.x, 0.0, pp.z + 0.9), pp + Vector3(0.03, 0.25, 0.06))
		await wait_sec(1.0)
		var interactor := me.get_interactor()
		if interactor.current_target != phone:
			print("  (A: not looking at the phone yet: %s)" % [interactor.current_target])
			continue
		Input.action_press(&"interact")
		interactor.try_interact()
		if hold_attempts == 1:
			check(phone.is_answering(), "A: the hold started through the Interactor")
		var t1 := Time.get_ticks_msec()
		while Events.is_event_active(Events.EVENT_PHONE) and Time.get_ticks_msec() - t1 < 5000:
			await get_tree().process_frame
		Input.action_release(&"interact")
	check(not Events.is_event_active(), "A: the finished hold took the call on the host (attempts %d)" % hold_attempts)
	await wait_until(func() -> bool: return not _answered.is_empty() and Events.get_phone_discount() < 1.0, 3.0, "A: phone_answered + the favor arrived")
	var factor := 1.0 - b.phone_discount
	check(_answered.size() == 1 and int(_answered[0][0]) == my_id and _answered[0][1] == Events.PHONE_FAVOR, "A: phone_answered(me, favor) (%s)" % [_answered])
	check(_discount == [factor] and GameState.get_seed_cost(seed0) == maxi(int(round(seed0.cost * factor)), 1) and Events.get_phone_discount_left() > b.phone_discount_sec - 5.0, "A: the seeds are cheaper here too ($%d), %.0f s of it" % [GameState.get_seed_cost(seed0), Events.get_phone_discount_left()])
	check(toast_seen("Alpha took the call. Seeds %d%% off for %d seconds." % [roundi(b.phone_discount * 100.0), roundi(b.phone_discount_sec)]) and int(Events.get(&"_phone_ring")) == 0 and not phone.is_ringing(), "A: the toast; the bell stopped")

	step("A lets it ring")
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(2.5, 0.05, 2.5)
	await wait_until(func() -> bool: return _started.size() >= 3 and Events.is_event_active(Events.EVENT_PHONE), STEP_TIMEOUT, "A: the phone rings again")
	await wait_until(func() -> bool: return not _missed.is_empty(), STEP_TIMEOUT, "A: nobody picked up")
	await wait_until(func() -> bool: return GameState.money == 600 - b.phone_fine, 3.0, "A: cash on hand synced (%d)" % (600 - b.phone_fine))
	check(_missed == [b.phone_fine] and Events.get_phone_fine_taken() == b.phone_fine and toast_seen("Nobody picked up. $%d out of cash on hand." % b.phone_fine), "A: phone_missed(%d), the toast" % b.phone_fine)
	check(_barked("He called. Nobody picked up."), "A: the Boss says it (%s)" % Story.last_bark)
	await wait_until(func() -> bool: return Events.get_phone_discount() == 1.0, STEP_TIMEOUT, "A: the favor ran out")
	check(_discount == [factor, 1.0] and GameState.get_seed_cost(seed0) == seed0.cost and toast_seen("Seeds are back to full price."), "A: the plain price again, the toast")
	await _leave("A")


# --- client B (late joiner) ---------------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	var b: BalanceConfig = Config.balance
	var factor := 1.0 - b.phone_discount
	await wait_until(func() -> bool: return Events.is_event_active(Events.EVENT_PHONE), 6.0, "B: joined while it rang: the event replay arrived")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_PHONE and _started.back()[1].has("seconds"), "B: event_started(phone, {seconds}) from the late-join replay")
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() <= float(_started.back()[1]["seconds"]), "B: time left synced (%.1f)" % Events.get_event_time_left())
	var phone := Events.get_wall_phone()
	check(phone != null and phone.is_ringing() and int(Events.get(&"_phone_ring")) != 0, "B: the bell rings at this peer's phone")
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	check(hud != null and hud.get_event_text().begins_with("PHONE") and hud.event_hint.text == "Somebody pick that up.", "B: the HUD banner reads PHONE with its hint")
	check(_discount == [factor] and is_equal_approx(Events.get_phone_discount(), factor) and Events.get_phone_discount_left() > 1.0, "B: the running favor came with the replay (%.2f, %.0f s left)" % [Events.get_phone_discount(), Events.get_phone_discount_left()])
	var seed0: SeedDef = b.seeds[0]
	check(GameState.get_seed_cost(seed0) == maxi(int(round(seed0.cost * factor)), 1), "B: the seed price follows ($%d)" % GameState.get_seed_cost(seed0))
	await wait_until(func() -> bool: return not _missed.is_empty(), STEP_TIMEOUT, "B: nobody picked up")
	check(_missed == [b.phone_fine] and not phone.is_ringing() and int(Events.get(&"_phone_ring")) == 0 and toast_seen("Nobody picked up."), "B: phone_missed(%d), the bell stopped" % b.phone_fine)
	await wait_until(func() -> bool: return Events.get_phone_discount() == 1.0, STEP_TIMEOUT, "B: the favor ran out")
	check(_discount == [factor, 1.0] and GameState.get_seed_cost(seed0) == seed0.cost, "B: the plain price again")
	await _leave("B")


# --- shared ---------------------------------------------------------------------------------------------------------

func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	await wait_sec(0.5)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(not Events.is_event_active() and Events.get_phone_discount() == 1.0 and int(Events.get(&"_phone_ring")) == 0, "%s: events reset locally" % tag)


## Where to stand `distance` m in front of the chute's face (global floor point).
func _chute_stand(chute: TurnInStation, distance: float) -> Vector3:
	var box := chute.get_collider_aabb()
	var fwd := chute.global_basis.z.normalized()
	var c := box.get_center()
	return Vector3(c.x, 0.0, c.z) + Vector3(fwd.x, 0.0, fwd.z) * (box.size.z * 0.5 + distance)


func _aim(me: Player, stand: Vector3, target: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(stand.x, 0.05, stand.z)
	me.look_at(Vector3(target.x, me.global_position.y, target.z), Vector3.UP)
	var cam := me.get_interactor().get_camera()
	var eye: Vector3 = cam.global_position if cam != null else me.global_position + Vector3.UP * 1.6
	me.head.rotation.x = atan2(target.y - eye.y, Vector2(target.x - eye.x, target.z - eye.z).length())
	for i in 3:
		await get_tree().physics_frame
	await wait_frames(1)


## A key event through the real input path (Events._input sees it like the game does).
func _press(action: StringName, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _barked(text: String) -> bool:
	if Story.last_bark.contains(text) or Story.get_pending_text().contains(text):
		return true
	for t in Story.bark_log:
		if String(t).contains(text):
			return true
	return false
