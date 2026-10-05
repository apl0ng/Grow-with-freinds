extends "res://tools/tests/qa_base.gd"
## M17 mayhem3 suite (mayhem3 agent): the scale and the phone on a single headless host with fake workers
## (Net.players + World.server_spawn_player, no owning peer). Deterministic apart from real flights and the real hold:
## event time is advanced with Events.tick().
##   kinds / weights / picker for fourteen kinds, the copy, the sounds, the economy model's two new lines, the wall
##   phone in the room (node, model, collider, wall, height, clear of all four cover layouts and every route), and
##   --first-event=scale|phone;
##   the scale: params, banner, the factor and every price the chute shows or pays (prompt, deposit, the collector's
##   pick), the F request refused (too far, back room, stunned, nothing aimed, a worker in the way), the real key (an
##   InputEventAction through Events._input) fixes it, a thrown can that misses does nothing, a thrown can and a
##   thrown bundle that strike the chute fix it (the bundle is sold at the full price), unfixed it runs out;
##   the phone: prompt states silent and ringing, params, banner, the ring loop and the rattling handset, the request
##   refused (too far, back room, quiet), the real hold answers, the three calls (a tip tells the kind the scheduler
##   starts next; a favor: the seed price, the counter's charge, the jar tags, it runs out; a wrong number), nobody
##   answers (the fine in full, short, broke), the card (the same seed gives the same call, next kind and gap whether
##   anybody answers or not), a decided kind that cannot start (told: kept; untold: rolled again);
##   late-join replay by direct RPC call; force end / shift end / game reset / menu.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/mayhem3_body.gd --port=7933 --events --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const Sim := preload("res://tools/tests/econ_sim.gd")

## Where the host stands out of every reach (the corridor south of the pen).
const SPOT_AWAY := Vector3(8.0, 0.0, 6.2)

var _started: Array = []      # [kind, params]
var _ended: Array = []        # [kind]
var _fixed: Array = []        # peer
var _answered: Array = []     # [peer, outcome]
var _missed: Array = []       # fine
var _discount: Array = []     # factor
var _bought: Array = []       # [cost, buyer, what]
var _world: World
var _room: Room
var _hud: HUD
var _chute: TurnInStation
var _phone: WallPhone
var _counter: ShopCounter


func _run() -> void:
	_label = "mayhem3"
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	Events.scale_fixed.connect(func(p: int) -> void: _fixed.append(p))
	Events.phone_answered.connect(func(p: int, o: StringName) -> void: _answered.append([p, o]))
	Events.phone_missed.connect(func(f: int) -> void: _missed.append(f))
	Events.phone_discount_changed.connect(func(f: float) -> void: _discount.append(f))
	GameState.purchase_made.connect(func(c: int, p: int, w: String) -> void: _bought.append([c, p, w]))
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false   # the deposits below must not end the shift

	_test_kinds(b)

	step("hosting")
	Game.start_host("Tester", port_arg(7933))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_hud = _world.get_node_or_null(^"HUD") as HUD
	_chute = _room.get_station("TurnInStation") as TurnInStation
	_counter = _room.get_station("ShopCounter") as ShopCounter
	_phone = Events.get_wall_phone()
	check(_hud != null and _chute != null and _counter != null, "the HUD, the chute and the supply window exist")
	for id in [2, 3]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	await get_tree().physics_frame
	check(_world.get_players().size() == 3, "host + 2 fake workers spawned")
	check(not Events.server_start_event(Events.EVENT_SCALE) and not Events.server_start_event(Events.EVENT_PHONE), "no event while WAITING")

	await _test_wall_phone()

	step("shift start")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(600 - GameState.money)

	await _test_first_event()
	await _test_scale(b)
	await _test_scale_throws(b)
	await _test_phone(b)
	await _test_phone_calls(b)
	await _test_phone_missed(b)
	await _test_phone_card(b)
	await _test_replay(b)
	await _test_resets(b)
	finish()


# --- kinds, weights, copy, sounds, the model ----------------------------------------------------------------------------

func _test_kinds(b: BalanceConfig) -> void:
	step("kinds + weights")
	check(Config.has_arg("events") and Events.are_events_enabled(), "this suite runs with --events")
	check(Events.EVENT_SCALE == &"scale" and Events.EVENT_PHONE == &"phone", "the two kind names")
	check(Events.KINDS.size() == 14 and Events.KINDS.has(Events.EVENT_SCALE) and Events.KINDS.has(Events.EVENT_PHONE), "KINDS: the twelve earlier kinds + scale, phone")
	var total := 0
	for k in Events.KINDS:
		total += int(Events.WEIGHTS.get(k, 0))
	check(total == 100 and Events.WEIGHTS.size() == Events.KINDS.size(), "weights sum to 100 over %d kinds (%d)" % [Events.KINDS.size(), total])
	var expected := {Events.EVENT_INSPECTION: 20, Events.EVENT_POWER_CUT: 12, Events.EVENT_AUDIT: 7, Events.EVENT_RAT: 6,
			Events.EVENT_HEADCOUNT: 9, Events.EVENT_WATER_OFF: 6, Events.EVENT_SHORTAGE: 5, Events.EVENT_LEAK: 7, Events.EVENT_DRIVEBY: 7,
			Events.EVENT_RAID: 6, Events.EVENT_SPRINKLERS: 5, Events.EVENT_COLLECTION: 5, Events.EVENT_SCALE: 3, Events.EVENT_PHONE: 2}
	var weights_ok := true
	for k in expected:
		if int(Events.WEIGHTS.get(k, -1)) != int(expected[k]):
			weights_ok = false
	check(weights_ok, "weights: inspection 20 / power_cut 12 / audit 7 / rat 6 / headcount 9 / water_off 6 / shortage 5 / leak 7 / driveby 7 / raid 6 / sprinklers 5 / collection 5 / scale 3 / phone 2")
	var kinds_seen: Dictionary = {}
	var repeats := 0
	for k in Events.KINDS:
		for i in 150:
			var pick := Events.pick_kind(k)
			kinds_seen[pick] = true
			if pick == k or not Events.KINDS.has(pick):
				repeats += 1
	check(repeats == 0, "pick_kind() never repeats the previous kind and stays in KINDS")
	check(kinds_seen.size() == 14, "pick_kind() reaches every kind (%d seen)" % kinds_seen.size())
	check(Events.PHONE_OUTCOMES.size() == 3 and Events.PHONE_OUTCOMES[0] == Events.PHONE_TIP and Events.PHONE_OUTCOMES[1] == Events.PHONE_FAVOR and Events.PHONE_OUTCOMES[2] == Events.PHONE_WRONG, "three calls: tip, favor, wrong number")

	step("copy, sounds, the model's lines")
	check(Story.line("scale") == "The scale reads light. Somebody hit it." and Story.line("phone") == "That's the phone. Pick it up.", "Story has the scale and phone lines")
	check(Story.mayhem3_missed_line(30, 30) == "He called. Nobody picked up. Thirty.", "the missed call: '%s'" % Story.mayhem3_missed_line(30, 30))
	check(Story.mayhem3_missed_line(30, 12) == "He called. Nobody picked up. Thirty. I took twelve." and Story.mayhem3_missed_line(30, 0) == "He called. Nobody picked up. Thirty. Nothing to take." and Story.mayhem3_missed_line(0, 0) == "", "short, broke, nothing billed")  # M19 readability: the short line is two-second copy now
	check(Story.mayhem3_tip_line(&"raid") == "Next: a raid." and Story.mayhem3_tip_line(&"power_cut") == "Next: a power cut." and Story.mayhem3_tip_line(&"nonsense") == "Next: trouble.", "the tip names the kind (%s)" % Story.mayhem3_tip_line(&"raid"))
	var named := 0
	for k in Events.KINDS:
		if Story.MAYHEM3_TIP_WORDS.has(String(k)):
			named += 1
	check(named == Events.KINDS.size(), "a tip has words for every kind (%d of %d)" % [named, Events.KINDS.size()])
	var copy_ok := true
	for k: String in Story.MAYHEM3_LINES:
		var text := String(Story.MAYHEM3_LINES[k])
		if text.contains("!") or Story.line(k) != text:
			copy_ok = false
	check(copy_ok, "every mayhem3 line is installed and has no exclamation mark")
	check(HUD.TEXT_EVENT_SCALE == "SCALE IS OFF" and HUD.TEXT_EVENT_SCALE_HINT == "It reads light. Hit it." and HUD.TEXT_EVENT_PHONE == "PHONE" and HUD.TEXT_EVENT_PHONE_HINT == "Somebody pick that up.", "the banner texts")
	for n: StringName in [&"phone_ring", &"phone_pickup", &"scale_hit"]:
		check(Sfx.has_sound(n), "Sfx has %s" % n)
	check(Sfx.LOOPING.has(&"phone_ring") and not Sfx.LOOPING.has(&"phone_pickup") and not Sfx.LOOPING.has(&"scale_hit"), "the ring loops, the pickup and the hit do not")
	check(b.scale_sec > 0.0 and b.scale_cut > 0.0 and b.scale_cut < 1.0 and b.phone_sec > 0.0 and b.phone_hold_sec > 0.0 and b.phone_fine > 0 and b.phone_discount > 0.0 and b.phone_discount_sec > 0.0,
			"balance: scale %.0f s / %.0f%%, phone %.0f s / hold %.1f s / fine $%d / favor %.0f%% for %.0f s" % [b.scale_sec, b.scale_cut * 100.0, b.phone_sec, b.phone_hold_sec, b.phone_fine, b.phone_discount * 100.0, b.phone_discount_sec])
	var model_ok := Sim.EVENT_WEIGHTS.size() == 14
	for k in Events.KINDS:
		if int(Sim.EVENT_WEIGHTS.get(String(k), -1)) != int(Events.WEIGHTS[k]):
			model_ok = false
	check(model_ok, "tools/tests/econ_sim.gd carries the same fourteen weights")
	var careful := _cost_line(Sim.event_costs(b, 1, Sim.SKILL_CAREFUL))
	var sloppy := _cost_line(Sim.event_costs(b, 4, Sim.SKILL_SLOPPY))
	check(careful.has("scale") and careful.has("phone") and sloppy.has("scale") and sloppy.has("phone"), "the model has a cost line for each")
	if careful.has("scale") and sloppy.has("phone"):
		check(float(careful["scale"]["quota_frac"]) > 0.0 and float(careful["scale"]["quota_frac"]) < float(sloppy["scale"]["quota_frac"]) and float(sloppy["scale"]["quota_frac"]) <= b.scale_cut * b.scale_sec / b.round_length_sec + 0.0001,
				"the scale: a careful crew lets %.2f%% of a shift's deposits through light, a sloppy one %.2f%%" % [float(careful["scale"]["quota_frac"]) * 100.0, float(sloppy["scale"]["quota_frac"]) * 100.0])
		check(float(careful["phone"]["cash"]) == 0.0 and float(careful["phone"]["one_sec"]) > b.phone_hold_sec and float(careful["phone"]["length"]) <= b.phone_sec and int(sloppy["phone"]["cash"]) == b.phone_fine,
				"the phone: a careful crew walks over (%.1f s), a sloppy one pays $%d" % [float(careful["phone"]["one_sec"]), int(sloppy["phone"]["cash"])])


func _cost_line(lines: Array[Dictionary]) -> Dictionary:
	var out: Dictionary = {}
	for e: Dictionary in lines:
		out[String(e["kind"])] = e
	return out


# --- the wall phone in the room -----------------------------------------------------------------------------------------

func _test_wall_phone() -> void:
	step("the wall phone in the room")
	check(_phone != null and _room.get_wall_phone() == _phone and _room.get_node_or_null(Room.WALL_PHONE_PATH) == _phone, "Room.get_wall_phone(): Decor/WallPhone, a WallPhone (Events.get_wall_phone() finds it)")
	if _phone == null:
		return
	check(_phone.get_parent() == _room.get_node(^"Decor") and _phone is Interactable, "under Decor, an Interactable")
	var visual := _phone.get_node_or_null(^"Visual") as Node3D
	check(visual is Toonify and visual.scene_file_path == "res://art/models/wall_phone.glb", "Visual is an instance of art/models/wall_phone.glb (Toonify)")
	check(_phone.get_handset() != null and _phone.get_handset().get_parent() == visual and _phone.get_handset().transform.is_equal_approx(Transform3D(Basis.IDENTITY, _phone.get_handset().position)), "Visual/Handset hangs on its hook at rest")
	var body := _phone.get_node_or_null(^"Body") as StaticBody3D
	check(body != null and body.collision_layer == Const.LAYER_INTERACTABLE and body.collision_mask == 0, "a collider on the interactable layer only (nobody walks into it, the crosshair finds it)")
	var p := _phone.global_position
	check(_room.get_area_index(p) == 0 and absf(p.z - (-7.5)) < 0.01 and absf(p.y - 1.15) < 0.01, "on the main room's north wall, 1.15 m up (%s)" % p)
	check(_phone.global_basis.z.dot(Vector3(0.0, 0.0, 1.0)) > 0.99, "facing into the room")
	var board := _room.get_node_or_null(Room.DEBT_BOARD_PATH) as Node3D
	check(board != null and absf(board.global_position.x - p.x) > 2.5, "clear of the debt board (%.1f m apart)" % absf(board.global_position.x - p.x))
	# Where a worker stands to answer it: 0.9 m out from the wall.
	var stand := Vector3(p.x, 0.0, p.z + 0.9)
	var layouts_ok := true
	var closest := INF
	for i in Room.COVER_LAYOUTS.size():
		_room.apply_cover_layout(i)
		if _room.is_in_cover(stand, Room.COVER_BODY_MARGIN + 0.5) or _room.is_in_cover(p, 0.6):
			layouts_ok = false
		for rect in _room.get_cover_footprints():
			var near := Vector2(clampf(p.x, rect.position.x, rect.end.x), clampf(p.z, rect.position.y, rect.end.y))
			closest = minf(closest, near.distance_to(Vector2(p.x, p.z)))
	_room.apply_cover_layout(0)
	check(layouts_ok and closest > 0.9, "no cover layout of %d puts anything in front of it (the nearest piece %.2f m away)" % [Room.COVER_LAYOUTS.size(), closest])
	var routes_ok := true
	var nearest_route := INF
	for e: Vector2i in Room.ROUTE_EDGES:
		var a: Vector2 = Room.ROUTE_POINTS[e.x]
		var c: Vector2 = Room.ROUTE_POINTS[e.y]
		nearest_route = minf(nearest_route, Geometry2D.get_closest_point_to_segment(Vector2(p.x, p.z), a, c).distance_to(Vector2(p.x, p.z)))
	var walks: Array[PackedVector3Array] = [_room.get_inspection_route(), _room.get_headcount_route()]
	for route in walks:
		for i in route.size() - 1:
			var near3 := Geometry3D.get_closest_point_to_segment(Vector3(p.x, 0.0, p.z), Vector3(route[i].x, 0.0, route[i].z), Vector3(route[i + 1].x, 0.0, route[i + 1].z))
			nearest_route = minf(nearest_route, near3.distance_to(Vector3(p.x, 0.0, p.z)))
	for lane: Variant in _room.get_gunfire_lanes():
		var l := lane as Dictionary
		var f: Vector3 = l["from"]
		var t: Vector3 = l["to"]
		var near_lane := Geometry2D.get_closest_point_to_segment(Vector2(p.x, p.z), Vector2(f.x, f.z), Vector2(t.x, t.z))
		if near_lane.distance_to(Vector2(p.x, p.z)) < 1.0:
			routes_ok = false
	check(nearest_route > 2.5 and routes_ok, "no route, walk of the Boss or drive-by lane passes it (the nearest %.1f m away)" % nearest_route)
	var space := _world.get_world_3d().direct_space_state
	var line := space.intersect_ray(PhysicsRayQueryParameters3D.create(stand + Vector3.UP * 1.5, p + Vector3(0.0, 0.25, 0.06), Const.LAYER_WORLD))
	check(line.is_empty(), "nothing solid between the answering spot and the phone")
	check(not _phone.is_ringing() and _phone.get_prompt(Game.local_player) == "Phone" and not _phone.can_interact(Game.local_player) and _phone.get_denied_reason(Game.local_player) == "", "silent: 'Phone', greyed out")
	toasts.clear()
	_phone.interact(Game.local_player)
	check(not _phone.is_answering() and toasts.is_empty(), "E on a silent phone does nothing at all")


# --- --first-event ------------------------------------------------------------------------------------------------------

func _test_first_event() -> void:
	step("--first-event")
	for kind: StringName in [Events.EVENT_SCALE, Events.EVENT_PHONE]:
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
	Events.call(&"_mayhem3_server_reset")
	Events.set(&"_next_in", -1.0)
	check(not Events.are_events_enabled() and not Events.is_event_active(), "scheduler off, nothing running")
	check(_fixed.is_empty() and _answered.is_empty() and _missed.is_empty() and GameState.money == 600, "a force-ended scale was fixed by nobody, a force-ended phone bills nobody")
	_clear_log()


# --- the scale ----------------------------------------------------------------------------------------------------------

func _test_scale(b: BalanceConfig) -> void:
	step("scale: start")
	var me: Player = Game.local_player
	_put_me(SPOT_AWAY)
	var seed0: SeedDef = b.seeds[0]
	var dear: SeedDef = b.get_seed(&"golden") if b.get_seed(&"golden") != null else seed0
	var held := _bundle(dear, me.global_position, 1)
	await _settle()
	check(me.get_held_item() == held, "the host holds a bundle of %s" % dear.display_name)
	var mult := GameState.get_sale_multiplier()
	var full := TurnInStation.compute_sale_value(dear, 1, mult)
	check(_chute.get_sale_value(held) == full and Events.get_scale_factor() == 1.0 and not Events.is_scale_off(), "the scale reads right: $%d" % full)
	check(Events.server_start_event(Events.EVENT_SCALE), "the scale goes off")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.scale_sec) and is_equal_approx(float(p.get("cut", -1.0)), b.scale_cut) and p.size() == 2, "params {seconds: scale_sec, cut: scale_cut} (%s)" % [p])
	check(Events.is_scale_off() and is_equal_approx(Events.get_scale_factor(), 1.0 - b.scale_cut), "is_scale_off(), get_scale_factor() = %.2f" % Events.get_scale_factor())
	check(_hud.get_event_text().begins_with("SCALE IS OFF") and _hud.event_hint.visible and _hud.event_hint.text == "It reads light. Hit it.", "HUD banner SCALE IS OFF with the hint (%s / %s)" % [_hud.get_event_text(), _hud.event_hint.text])
	var toast := "The scale reads light: %d%% less. Hit the chute (%s)." % [roundi(b.scale_cut * 100.0), HUD.action_key_text(&"shove", "F")]  # M19 readability: two-second copy
	check(toast_seen(toast) and _barked("The scale reads light. Somebody hit it."), "the floor is told: toast + the Boss (%s)" % Story.last_bark)
	check(not Events.server_start_event(Events.EVENT_PHONE), "one at a time: the phone is refused meanwhile")

	step("scale: what the chute pays")
	var light := TurnInStation.compute_sale_value(dear, 1, mult * (1.0 - b.scale_cut))
	var by_hand := int(round(dear.sale_value_per_unit * mult * (1.0 - b.scale_cut) * GameState.get_deposit_factor(dear.id)))
	check(light < full and light == by_hand, "rounded like the other factors, once: $%d light against $%d" % [light, full])
	check(_chute.get_sale_value(held) == light and _chute.get_prompt(me).ends_with("(+$%d)" % light), "the chute's prompt shows the light value (%s)" % _chute.get_prompt(me))
	var cured := _bundle(seed0, Vector3(-3.0, 0.0, 3.0), 0, 2)
	await _settle()
	cured.set(&"cured", true)
	var cured_light := TurnInStation.compute_sale_value(seed0, 2, mult * (1.0 - b.scale_cut), true)
	check(_chute.get_sale_value(cured) == cured_light and cured_light < TurnInStation.compute_sale_value(seed0, 2, mult, true), "a cured pair pays the cut too ($%d)" % cured_light)
	var sales0 := GameState.round_sales
	check(_chute.server_sell_item(cured, 2), "worker 2 deposits it while the scale reads light")
	check(GameState.round_sales == sales0 + cured_light, "the deposit paid $%d, not $%d" % [GameState.round_sales - sales0, TurnInStation.compute_sale_value(seed0, 2, mult, true)])

	step("scale: the key, refused")
	toasts.clear()
	Events._rpc_request_hit_scale()
	check(Events.is_scale_off() and toast_seen("Too far.") and _fixed.is_empty(), "from the corridor: 'Too far.'")
	check(Events.get_scale_reach(me) > b.shove_range + Events.SCALE_REACH_SLACK and not Events.is_aiming_at_scale(me) and not Events.try_hit_scale(), "the local key does not even ask from there")
	await _aim_at_chute(me, 1.0)
	check(Events.get_scale_reach(me) <= b.shove_range and Events.is_aiming_at_scale(me), "in front of the chute, looking at it: in reach (%.2f m), aimed" % Events.get_scale_reach(me))
	check(GameState.server_send_to_backroom(1, 60.0), "the host sits in the back room")
	await wait_frames(2)
	toasts.clear()
	Events._rpc_request_hit_scale()
	check(Events.is_scale_off() and toast_seen("back room") and _fixed.is_empty(), "refused from the back room")
	GameState.server_release_from_backroom(1)
	await wait_frames(3)
	check(_world.items.server_give_item(held, 1), "let out; the bundle the back room put down is back in hand")
	await _aim_at_chute(me, 1.0)
	me.set(&"_stun_until_msec", Time.get_ticks_msec() + 3000)
	check(me.is_stunned(), "the host is stunned")
	toasts.clear()
	Events._rpc_request_hit_scale()
	check(Events.is_scale_off() and _fixed.is_empty() and not Events.try_hit_scale(), "a stunned worker hits nothing")
	me.set(&"_stun_until_msec", 0)
	var w2 := _world.get_player(2)
	me.look_at(Vector3(-6.0, me.global_position.y, me.global_position.z + 0.5), Vector3.UP)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not Events.is_aiming_at_scale(me) and not Events.try_hit_scale(), "turned away from it: F is not for the chute")
	await _aim_at_chute(me, 1.7)
	var ahead := -me.global_basis.z
	_put(w2, me.global_position + Vector3(ahead.x, 0.0, ahead.z).normalized() * 0.85)
	for i in 4:
		await get_tree().physics_frame
	check(is_instance_valid(me.get_interactor().shove_target) and not Events.try_hit_scale() and Events.is_scale_off(), "a worker in the way: F shoves him, not the chute")
	_put(w2, Vector3(-3.0, 0.0, 0.0))
	await _aim_at_chute(me, 1.0)

	step("scale: F fixes it")
	_ended.clear()
	toasts.clear()
	var ev := InputEventAction.new()
	ev.action = &"shove"
	ev.pressed = true
	Input.parse_input_event(ev)
	await wait_frames(2)
	var up := InputEventAction.new()
	up.action = &"shove"
	up.pressed = false
	Input.parse_input_event(up)
	await wait_until(func() -> bool: return not Events.is_scale_off(), 2.0, "the shove key at the chute ends the event")
	check(_fixed == [1] and _ended.size() == 1 and _ended[0][0] == Events.EVENT_SCALE, "scale_fixed(the host), event_ended(scale) (%s)" % [_fixed])
	check(Events.get_scale_factor() == 1.0 and _chute.get_sale_value(held) == full and _chute.get_prompt(me).ends_with("(+$%d)" % full), "the chute pays in full again ($%d)" % _chute.get_sale_value(held))
	check(toast_seen("Tester hit the scale. It reads right.") and _barked("Scale reads right. Back to work."), "the floor hears who hit it")
	check(_hud.get_event_text() == "", "the banner is gone")
	check(not Events.server_hit_scale(1) and _fixed.size() == 1, "server_hit_scale() is false when the scale reads right")
	toasts.clear()
	Events._rpc_request_hit_scale()
	check(toasts.is_empty() and _fixed.size() == 1, "a late request is dropped without a word")

	step("scale: server_hit_scale, then unfixed")
	check(Events.server_start_event(Events.EVENT_SCALE) and Events.server_hit_scale(3), "server_hit_scale(worker 3)")
	check(_fixed == [1, 3] and not Events.is_scale_off() and toast_seen("Worker 3 hit the scale."), "scale_fixed(3)")
	_clear_log()
	check(Events.server_start_event(Events.EVENT_SCALE), "the scale goes off again")
	Events.tick(b.scale_sec - 0.5)
	check(Events.is_scale_off(), "still light half a second before scale_sec")
	Events.tick(0.6)
	check(not Events.is_scale_off() and _ended.size() == 1 and _fixed.is_empty(), "unfixed, it ends with the timer")
	check(toast_seen("The scale reads right again.") and _barked("Scale came back by itself. You paid for the wait."), "the floor is told it came back")
	_world.items.server_despawn_item(held)
	await _settle()
	_clear_log()


func _test_scale_throws(b: BalanceConfig) -> void:
	step("scale: a thrown can that misses")
	var me: Player = Game.local_player
	_put_me(SPOT_AWAY)
	var seed0: SeedDef = b.seeds[0]
	check(Events.server_start_event(Events.EVENT_SCALE), "the scale goes off")
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(-4.0, 0.0, 2.0))
	await _settle()
	check(_world.items.server_throw_item(can, Vector3(-4.0, 1.0, 2.0), Vector3(-5.0, 1.0, 0.0), 2), "worker 2 throws a can at the west wall")
	await wait_until(func() -> bool: return not can.is_flying(), 3.0, "it lands")
	check(Events.is_scale_off() and _fixed.is_empty(), "a can that never came near the chute fixes nothing")

	step("scale: a thrown can that strikes the chute")
	var front := _chute_front()
	var fwd := _chute.global_basis.z.normalized()
	var from := front + Vector3.UP * 1.0 + fwd * 0.9
	check(_world.items.server_throw_item(can, from, -fwd * 6.0, 2), "worker 2 throws the can at the chute's face")
	await wait_until(func() -> bool: return not Events.is_scale_off(), 3.0, "the can strikes it")
	check(_fixed == [2] and not can.is_queued_for_deletion(), "scale_fixed(the thrower) (%s); the can is not sold" % [_fixed])
	await wait_until(func() -> bool: return not can.is_flying(), 3.0, "and lands")
	check(_room.contains_point(can.global_position + Vector3.UP * 0.2), "on the floor plan (%s)" % can.global_position)
	check(toast_seen("Worker 2 hit the scale."), "the floor hears who threw it")
	_world.items.server_despawn_item(can)
	_clear_log()

	step("scale: a thrown bundle that strikes the chute")
	var mult := GameState.get_sale_multiplier()
	var full := TurnInStation.compute_sale_value(seed0, 1, mult)
	check(Events.server_start_event(Events.EVENT_SCALE), "the scale goes off")
	var bundle := _bundle(seed0, Vector3(0.0, 0.0, 3.0))
	await _settle()
	var sales0 := GameState.round_sales
	check(_world.items.server_throw_item(bundle, from, -fwd * 6.0, 3), "worker 3 throws a bundle at the chute")
	await wait_until(func() -> bool: return not Events.is_scale_off(), 3.0, "the bundle strikes it")
	await wait_frames(3)
	check(_fixed == [3], "scale_fixed(worker 3)")
	check(not is_instance_valid(bundle) or bundle.is_queued_for_deletion(), "the chute took the bundle (a chute shot)")
	check(GameState.round_sales == sales0 + full, "at the full price: the hit came first ($%d, full $%d)" % [GameState.round_sales - sales0, full])
	_clear_log()


## The point on the floor in front of the chute's face (global; its local +Z is the front).
func _chute_front() -> Vector3:
	var box := _chute.get_collider_aabb()
	var fwd := _chute.global_basis.z.normalized()
	var c := box.get_center()
	return Vector3(c.x, 0.0, c.z) + Vector3(fwd.x, 0.0, fwd.z) * (box.size.z * 0.5)


# --- the phone ----------------------------------------------------------------------------------------------------------

func _test_phone(b: BalanceConfig) -> void:
	step("phone: it rings")
	var me: Player = Game.local_player
	_put_me(SPOT_AWAY)
	var loops0: int = Sfx.get_active_loop_count()
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	var p: Dictionary = _started.back()[1] if not _started.is_empty() else {}
	check(is_equal_approx(float(p.get("seconds", 0.0)), b.phone_sec) and p.size() == 1, "params {seconds: phone_sec} (%s): the call itself is not broadcast" % [p])
	check(_hud.get_event_text().begins_with("PHONE") and _hud.event_hint.visible and _hud.event_hint.text == "Somebody pick that up.", "HUD banner PHONE with the hint (%s / %s)" % [_hud.get_event_text(), _hud.event_hint.text])
	check(toast_seen("The phone is ringing. Somebody pick that up.") and _barked("That's the phone. Pick it up."), "the floor is told: toast + the Boss")
	check(Sfx.get_active_loop_count() == loops0 + 1 and int(Events.get(&"_phone_ring")) != 0 and Sfx.is_loop_playing(int(Events.get(&"_phone_ring"))), "the ring loop plays")
	var loop_player := Sfx.get_loop_player(int(Events.get(&"_phone_ring"))) as Node3D
	check(loop_player != null and loop_player.global_position.distance_to(_phone.global_position) < 0.5, "at the phone")
	check(_phone.is_ringing(), "the phone rings on this peer")
	var outcome: StringName = Events.get(&"_phone_outcome")
	var next := Events.get_phone_next_kind()
	check(Events.PHONE_OUTCOMES.has(outcome) and Events.KINDS.has(next) and next != Events.EVENT_PHONE and not Events.is_phone_next_told(), "the call (%s) and the next kind (%s) were rolled as it started" % [outcome, next])
	var turned := false
	var still := false
	var watch_from := Time.get_ticks_msec()
	while Time.get_ticks_msec() - watch_from < 500:
		await get_tree().process_frame
		var z := absf(_phone.get_handset().rotation.z)
		if z > 0.005:
			turned = true
		if z > deg_to_rad(WallPhone.RATTLE_DEG) + 0.001:
			still = true   # beyond the rattle: wrong
	check(turned and not still, "the handset rattles in its cradle, at most %.0f degrees" % WallPhone.RATTLE_DEG)
	check(_phone.get_prompt(me).begins_with("Hold ") and _phone.get_prompt(me).ends_with("Answer the phone") and _phone.can_interact(me), "ringing: '%s'" % _phone.get_prompt(me))

	step("phone: the request, refused")
	toasts.clear()
	Events._rpc_request_answer_phone()
	check(Events.is_event_active(Events.EVENT_PHONE) and toast_seen("Too far.") and _answered.is_empty(), "from the corridor: 'Too far.'")
	check(GameState.server_send_to_backroom(1, 60.0), "the host sits in the back room")
	await wait_frames(2)
	toasts.clear()
	Events._rpc_request_answer_phone()
	check(Events.is_event_active(Events.EVENT_PHONE) and toast_seen("back room") and _answered.is_empty(), "refused from the back room")
	GameState.server_release_from_backroom(1)
	await wait_frames(3)

	step("phone: the hold answers (a tip)")
	var hold0 := b.phone_hold_sec
	b.phone_hold_sec = 0.6
	Events.set(&"_phone_outcome", Events.PHONE_TIP)
	await _aim_at_phone(me)
	var interactor := me.get_interactor()
	check(interactor.current_target == _phone, "looking at the phone (target %s)" % [interactor.current_target])
	_ended.clear()
	toasts.clear()
	var loops1: int = Sfx.get_active_loop_count()
	Input.action_press(&"interact")
	interactor.try_interact()
	check(_phone.is_answering(), "holding the answer (through the Interactor)")
	await wait_sec(0.3)
	check(_phone.get_answer_progress() > 0.2 and _phone.get_answer_progress() < 0.95 and _phone.get_prompt(me).contains(" s") and Events.is_event_active(Events.EVENT_PHONE), "hold progress %.2f, the prompt counts down (%s)" % [_phone.get_answer_progress(), _phone.get_prompt(me)])
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "the finished hold takes the call")
	Input.action_release(&"interact")
	await wait_sec(0.15)
	check(_answered.size() == 1 and int(_answered[0][0]) == 1 and _answered[0][1] == Events.PHONE_TIP, "phone_answered(the host, tip) (%s)" % [_answered])
	check(Events.get_phone_tip() == next and Events.get_phone_next_kind() == next and Events.is_phone_next_told(), "the tip names the kind rolled at the start (%s), and it is told" % Events.get_phone_tip())
	var tip_text := Story.mayhem3_tip_line(next)
	check(toast_seen("Tester took the call. %s" % tip_text) and _barked(tip_text), "the floor hears it: '%s'" % tip_text)
	check(_ended.size() == 1 and _ended[0][0] == Events.EVENT_PHONE and _missed.is_empty() and Sfx.get_active_loop_count() == loops1 - 1 and int(Events.get(&"_phone_ring")) == 0, "event over, the bell stops, nothing billed")
	check(not _phone.is_ringing() and _phone.get_handset().position.y > _phone.get(&"_handset_rest").origin.y + 0.02, "the handset is off the hook")
	await wait_sec(WallPhone.PICKUP_SEC + 0.5)
	check(_phone.get_handset().transform.is_equal_approx(_phone.get(&"_handset_rest")), "and back on it")
	check(_phone.get_prompt(me) == "Phone" and not _phone.can_interact(me), "silent again")
	b.phone_hold_sec = hold0

	step("phone: the tip comes true")
	_reset_plots()
	check(plot(1).server_plant(Config.balance.seeds[0].id), "a tray grows (a rat would need one)")
	await _settle()
	Config.user_args["events"] = ""
	Events.set(&"_next_in", 0.5)
	_started.clear()
	Events.tick(1.0)
	check(Events.active_event == next and _started.size() == 1 and Events.get_phone_next_kind() == &"", "the scheduler starts the told kind next (%s)" % Events.active_event)
	Events.server_end_event()
	Config.user_args.erase("events")
	Events.call(&"_mayhem2_server_reset")
	Events.set(&"_next_in", -1.0)
	await wait_sec(1.0)
	_reset_plots()
	_clear_log()


func _test_phone_calls(b: BalanceConfig) -> void:
	step("phone: a favor")
	var me: Player = Game.local_player
	var cheap: SeedDef = b.seeds[0]
	var list_price := cheap.cost
	check(GameState.get_seed_cost(cheap) == list_price and Events.get_phone_discount() == 1.0, "the plain price: $%d" % list_price)
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	Events.set(&"_phone_outcome", Events.PHONE_FAVOR)
	toasts.clear()
	check(Events.server_answer_phone(2) == Events.PHONE_FAVOR, "worker 2 takes it: a favor")
	var factor := 1.0 - b.phone_discount
	check(_answered.size() == 1 and int(_answered[0][0]) == 2 and _answered[0][1] == Events.PHONE_FAVOR and Events.get_phone_tip() == &"", "phone_answered(2, favor)")
	check(_discount == [factor] and is_equal_approx(Events.get_phone_discount(), factor) and is_equal_approx(Events.get_phone_discount_left(), b.phone_discount_sec), "phone_discount_changed(%.2f), %.0f s left" % [Events.get_phone_discount(), Events.get_phone_discount_left()])
	var cheaper := maxi(int(round(list_price * factor)), 1)
	check(GameState.get_seed_cost(cheap) == cheaper and cheaper < list_price, "GameState.get_seed_cost: $%d instead of $%d" % [GameState.get_seed_cost(cheap), list_price])
	var tag := _counter.get_node_or_null(^"Visual/Jars").get_child(0).get_node_or_null(^"PriceTag") as Label3D if _counter.get_node_or_null(^"Visual/Jars") != null else null
	check(tag == null or tag.text == "$%d" % cheaper, "the jar's price tag follows (%s)" % (tag.text if tag != null else "no jar"))
	var favor_toast := "Worker 2 took the call. Seeds %d%% off for %d seconds." % [roundi(b.phone_discount * 100.0), roundi(b.phone_discount_sec)]
	check(toast_seen(favor_toast) and _barked("A favor. Seeds are cheap. Not for long."), "the floor hears it: '%s'" % favor_toast)
	stand_near(_counter, 1.3)
	await wait_frames(2)
	var held := _world.items.get_held_by(1)
	if held != null:
		_world.items.server_despawn_item(held)
	await _settle()
	var money0 := GameState.money
	_bought.clear()
	var bought := _counter.server_buy_seed(1, cheap.id)
	check(bool(bought.get("ok", false)) and GameState.money == money0 - cheaper and _bought.size() == 1 and int(_bought[0][0]) == cheaper, "the counter charges the favor's price ($%d) (%s)" % [money0 - GameState.money, bought])
	var packet := _world.items.get_held_by(1)
	if packet != null:
		_world.items.server_despawn_item(packet)
	Events.tick(b.phone_discount_sec - 0.5)
	check(is_equal_approx(Events.get_phone_discount(), factor) and Events.get_phone_discount_left() > 0.4, "still on half a second before phone_discount_sec")
	toasts.clear()
	Events.tick(0.6)
	check(Events.get_phone_discount() == 1.0 and Events.get_phone_discount_left() == 0.0 and _discount == [factor, 1.0], "then it runs out: phone_discount_changed(1.0) (%s)" % [_discount])
	check(GameState.get_seed_cost(cheap) == list_price and (tag == null or tag.text == "$%d" % list_price), "the plain price again, on the jar too")
	check(toast_seen("Seeds are back to full price."), "and the floor is told")
	_put_me(SPOT_AWAY)
	_clear_log()

	step("phone: a wrong number")
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	Events.set(&"_phone_outcome", Events.PHONE_WRONG)
	var money1 := GameState.money
	check(Events.server_answer_phone(1) == Events.PHONE_WRONG, "the host takes it: a wrong number")
	check(_answered.size() == 1 and _answered[0][1] == Events.PHONE_WRONG and Events.get_phone_tip() == &"" and _discount.is_empty() and GameState.money == money1, "phone_answered(1, wrong_number): nothing else happens")
	check(toast_seen("Tester took the call. Wrong number.") and _barked("Wrong number."), "the floor hears it")
	check(not Events.is_phone_next_told() and Events.get_phone_next_kind() != &"", "the next kind stays decided, untold")
	check(Events.server_answer_phone(1) == &"" and _answered.size() == 1, "server_answer_phone() with no phone ringing does nothing")
	toasts.clear()
	Events._rpc_request_answer_phone()
	check(toast_seen("It stopped ringing.") and _answered.size() == 1, "a late request: 'It stopped ringing.'")
	Events.call(&"_mayhem3_server_reset")
	_clear_log()


func _test_phone_missed(b: BalanceConfig) -> void:
	step("phone: nobody picks up")
	GameState.server_add_money(600 - GameState.money)
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	Events.tick(b.phone_sec - 0.5)
	check(Events.is_event_active(Events.EVENT_PHONE) and _missed.is_empty(), "still ringing half a second before phone_sec")
	Events.tick(0.6)
	await wait_frames(1)
	check(not Events.is_event_active() and _ended.size() == 1 and _missed == [b.phone_fine] and Events.get_phone_fine_taken() == b.phone_fine, "phone_missed(phone_fine): $%d" % b.phone_fine)
	check(GameState.money == 600 - b.phone_fine and _bought.size() == 1 and int(_bought[0][0]) == b.phone_fine and _bought[0][2] == "phone", "out of cash on hand through the spend path (%s)" % [_bought])
	var said := Story.mayhem3_missed_line(b.phone_fine, b.phone_fine)
	check(_barked(said) and toast_seen("Nobody picked up. $%d out of cash on hand." % b.phone_fine), "the Boss: '%s'" % said)
	check(_answered.is_empty() and int(Events.get(&"_phone_ring")) == 0 and not _phone.is_ringing(), "the bell stopped, nobody answered")
	Events.call(&"_mayhem3_server_reset")
	_clear_log()

	step("phone: short of cash, broke")
	GameState.server_add_money(12 - GameState.money)
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings, $12 on hand")
	Events.tick(b.phone_sec + 0.1)
	check(_missed == [b.phone_fine] and Events.get_phone_fine_taken() == 12 and GameState.money == 0, "phone_missed(%d): the $12 there was" % b.phone_fine)
	check(_barked(Story.mayhem3_missed_line(b.phone_fine, 12)) and toast_seen("Nobody picked up. $12 out of cash on hand."), "the Boss counts what he got (%s)" % Story.last_bark)
	Events.call(&"_mayhem3_server_reset")
	_clear_log()
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings, nothing on hand")
	Events.tick(b.phone_sec + 0.1)
	check(_missed == [b.phone_fine] and Events.get_phone_fine_taken() == 0 and GameState.money == 0 and _bought.is_empty(), "phone_missed(%d): nothing to take" % b.phone_fine)
	check(_barked(Story.mayhem3_missed_line(b.phone_fine, 0)) and toast_seen("Nobody picked up. Nothing left to take."), "the Boss: nothing to take")

	step("phone: a decided kind that cannot start")
	_reset_plots()
	await _settle()
	Events.set(&"_phone_next_kind", Events.EVENT_RAT)
	Events.set(&"_phone_next_told", true)
	Events.set(&"_phone_next_tries", 0)
	Config.user_args["events"] = ""
	for i in 3:
		Events.set(&"_next_in", 0.1)
		Events.tick(0.2)
	check(not Events.is_event_active() and Events.get_phone_next_kind() == Events.EVENT_RAT and int(Events.get(&"_phone_next_tries")) == 3, "a told rat with nothing growing: tried three times, still the next kind")
	Events.set(&"_phone_next_told", false)
	Events.set(&"_phone_next_tries", 0)
	var first: StringName = Events.call(&"_mayhem3_pick_next")
	check(first == Events.EVENT_RAT and Events.get_phone_next_kind() == Events.EVENT_RAT, "untold: offered once")
	var second: StringName = Events.call(&"_mayhem3_pick_next")
	check(Events.get_phone_next_kind() == &"" and Events.KINDS.has(second), "then rolled again, as any failed start (%s)" % second)
	Config.user_args.erase("events")
	Events.set(&"_next_in", -1.0)
	Events.call(&"_mayhem3_server_reset")
	GameState.server_add_money(600 - GameState.money)
	_clear_log()


func _test_phone_card(b: BalanceConfig) -> void:
	step("phone: the card does not care who answers")
	var runs: Array = []
	for answer in [false, true]:
		Events.server_seed(4242)
		check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings (seeded, %s)" % ("answered" if answer else "missed"))
		var outcome: StringName = Events.get(&"_phone_outcome")
		var next := Events.get_phone_next_kind()
		if answer:
			Events.server_answer_phone(1)
		else:
			Events.tick(b.phone_sec + 0.1)
		runs.append([outcome, next, Events.get_next_event_in()])
		Events.call(&"_mayhem3_server_reset")
		GameState.server_add_money(600 - GameState.money)
	check(runs[0][0] == runs[1][0] and runs[0][1] == runs[1][1] and is_equal_approx(float(runs[0][2]), float(runs[1][2])), "the same seed: the same call (%s), the same next kind (%s), the same gap (%.2f s), answered or not" % [runs[0][0], runs[0][1], float(runs[0][2])])
	var spread: Dictionary = {}
	for s in 60:
		Events.server_seed(1000 + s)
		Events.server_start_event(Events.EVENT_PHONE)
		spread[Events.get(&"_phone_outcome")] = true
		Events.server_end_event()
		Events.call(&"_mayhem3_server_reset")
	check(spread.size() == 3, "over sixty seeds every call comes up (%s)" % [spread.keys()])
	Events.set(&"_next_in", -1.0)
	_clear_log()


# --- late-join replay ---------------------------------------------------------------------------------------------------

func _test_replay(b: BalanceConfig) -> void:
	step("late-join replay")
	var loops0: int = Sfx.get_active_loop_count()
	Events._rpc_event_started(Events.EVENT_PHONE, {"seconds": b.phone_sec}, b.phone_sec - 5.0)
	check(Events.is_event_active(Events.EVENT_PHONE) and Events.get_event_time_left() <= b.phone_sec - 5.0 and _phone.is_ringing(), "phone replay: it rings, time left synced")
	check(Sfx.get_active_loop_count() == loops0 + 1 and _hud.get_event_text().begins_with("PHONE") and _hud.event_hint.text == "Somebody pick that up.", "the bell and the banner")
	Events._rpc_event_started(Events.EVENT_PHONE, {"seconds": b.phone_sec}, b.phone_sec - 6.0)
	check(Sfx.get_active_loop_count() == loops0 + 1, "the same packet twice: one bell")
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active() and Sfx.get_active_loop_count() == loops0 and not _phone.is_ringing(), "ended: quiet")
	Events._rpc_event_started(Events.EVENT_SCALE, {"seconds": b.scale_sec, "cut": 0.3}, 10.0)
	check(Events.is_scale_off() and is_equal_approx(Events.get_scale_factor(), 0.7) and _hud.get_event_text().begins_with("SCALE IS OFF"), "scale replay: the broadcast cut (0.3) is the one that counts")
	Events.server_end_event()
	_clear_log()
	Events._rpc_phone_discount(0.75, 30.0)
	check(is_equal_approx(Events.get_phone_discount(), 0.75) and is_equal_approx(Events.get_phone_discount_left(), 30.0) and _discount == [0.75], "a joiner during a favor: _rpc_phone_discount(0.75, 30) alone discounts the seeds")
	check(GameState.get_seed_cost(b.seeds[0]) == maxi(int(round(b.seeds[0].cost * 0.75)), 1), "the price follows ($%d)" % GameState.get_seed_cost(b.seeds[0]))
	Events._rpc_phone_discount(0.75, 29.0)
	check(_discount == [0.75], "the same favor twice: one signal")
	Events._rpc_phone_discount(1.0, 0.0)
	check(Events.get_phone_discount() == 1.0 and _discount == [0.75, 1.0], "and it ends")
	_clear_log()


# --- force end / shift end / reset / menu -------------------------------------------------------------------------------

func _test_resets(b: BalanceConfig) -> void:
	step("shift end")
	var loops0: int = Sfx.get_active_loop_count()
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	Events.set(&"_phone_outcome", Events.PHONE_FAVOR)
	Events.server_answer_phone(1)
	check(Events.get_phone_discount() < 1.0, "a favor runs")
	check(Events.server_start_event(Events.EVENT_PHONE), "and the phone rings again")
	var money0 := GameState.money
	_clear_log()
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_frames(2)
	check(not Events.is_event_active() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_PHONE and _missed.is_empty() and GameState.money == money0, "the shift end hangs up: no fine")
	check(Events.get_phone_discount() == 1.0 and _discount == [1.0] and Sfx.get_active_loop_count() == loops0 and not _phone.is_ringing(), "the favor is over, the bell quiet")
	check(Events.get_phone_next_kind() == &"", "no kind decided for a shift that is over")

	step("game reset")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	_clear_log()
	check(Events.server_start_event(Events.EVENT_SCALE) and Events.is_scale_off(), "the scale goes off")
	Events.tick(3.0)
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after the reset")
	await wait_frames(2)
	check(not Events.is_scale_off() and Events.get_scale_factor() == 1.0 and _fixed.is_empty() and _ended.size() >= 1 and _ended.back()[0] == Events.EVENT_SCALE, "game reset ends the scale event")
	check(not toast_seen("The scale reads right again."), "and says nothing about it")

	step("return to menu")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	Events.set(&"_phone_outcome", Events.PHONE_FAVOR)
	Events.server_answer_phone(1)
	check(Events.server_start_event(Events.EVENT_PHONE) and Events.get_phone_discount() < 1.0, "it rings again, a favor runs")
	_ended.clear()
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	check(not Events.is_event_active() and Events.get_event_time_left() == 0.0 and _ended.size() >= 1, "menu: events reset locally")
	check(int(Events.get(&"_phone_ring")) == 0 and Events.get_phone_discount() == 1.0 and Events.get_phone_next_kind() == &"" and Events.get_phone_tip() == &"", "menu: the mayhem3 state is forgotten")


# --- helpers --------------------------------------------------------------------------------------------------------

## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3, height: float = 0.05) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, height, pos.z)))


func _put_me(pos: Vector3) -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.05, pos.z)


## Stands the host `distance` m in front of the chute's face, looking at the middle of it.
func _aim_at_chute(me: Player, distance: float) -> void:
	var fwd := _chute.global_basis.z.normalized()
	var stand := _chute_front() + Vector3(fwd.x, 0.0, fwd.z) * distance
	await _aim(me, stand, _chute.get_collider_aabb().get_center())


## Stands the host 0.9 m out from the wall in front of the phone, looking at its housing.
func _aim_at_phone(me: Player) -> void:
	var p := _phone.global_position
	await _aim(me, Vector3(p.x, 0.0, p.z + 0.9), p + Vector3(0.03, 0.25, 0.06))


func _aim(me: Player, stand: Vector3, target: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(stand.x, 0.05, stand.z)
	me.look_at(Vector3(target.x, me.global_position.y, target.z), Vector3.UP)
	var cam := me.get_interactor().get_camera()
	var eye: Vector3 = cam.global_position if cam != null else me.global_position + Vector3.UP * 1.6
	me.head.rotation.x = atan2(target.y - eye.y, Vector2(target.x - eye.x, target.z - eye.z).length())
	# physics_frame fires before the frame's callbacks: three of them let the Interactor's ray run twice on the new pose.
	for i in 3:
		await get_tree().physics_frame
	await wait_frames(1)


## A product bundle of `seed_def` at `pos` (in `holder`'s hands when > 0).
func _bundle(seed_def: SeedDef, pos: Vector3, holder: int = 0, amount: int = 1) -> Item:
	return _world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": seed_def.id, "amount": amount}, pos, holder)


func _reset_plots() -> void:
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		var pl := plot(i)
		if pl != null:
			pl.server_reset()


## Lets spawned items land in the tree and in the physics space.
func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	await wait_frames(1)


func _clear_log() -> void:
	_started.clear()
	_ended.clear()
	_fixed.clear()
	_answered.clear()
	_missed.clear()
	_discount.clear()
	_bought.clear()
	toasts.clear()


## True when a Story line containing `text` was shown (or queued as the last bark).
func _barked(text: String) -> bool:
	if Story.last_bark.contains(text) or Story.get_pending_text().contains(text):
		return true
	for t in Story.bark_log:
		if String(t).contains(text):
			return true
	return false
