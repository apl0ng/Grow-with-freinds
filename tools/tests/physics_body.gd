extends "res://tools/tests/smoke_base.gd"
## M10 physics suite (physics agent): throw arcs, hits, chute shots, shove validation, stagger / stun, worker collision
## and footsteps on a single headless host with two extra fake workers (Bob, Chloe: spawned on the host without an
## owning peer, so the SERVER side is exercised directly on them and the OWNER side on the host's own player).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/physics_body.gd --port=7861

const BOB := 2
const CHLOE := 3

var world: World
var items: ItemManager
var me: Player
var bob: Player
var chloe: Player
var _staggers: Array = []          # [target peer, by_peer]
var _steps: Dictionary = {}        # peer -> footsteps this peer played for that worker
var _sales: Array = []             # [amount, seller]


func _run() -> void:
	_label = "physics"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance

	step("hosting")
	Game.start_host("Tester", port_arg(7861))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	world = Game.world
	items = world.items
	me = Game.local_player
	await wait_until(func() -> bool: return items.get_items().size() >= b.starting_watering_cans, 3.0, "starting cans spawned")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "shift running (chute sales count)")
	GameState.sale_made.connect(func(a: int, s: int) -> void: _sales.append([a, s]))

	step("two fake workers on the host")
	for entry in [[BOB, "Bob"], [CHLOE, "Chloe"]]:
		Net.players[entry[0]] = {"name": entry[1], "color": Net.PALETTE[entry[0] - 1]}
		world.server_spawn_player(entry[0])
	await wait_frames(3)
	bob = world.get_player(BOB)
	chloe = world.get_player(CHLOE)
	check(bob != null and chloe != null and world.get_players().size() == 3, "Bob and Chloe spawned (3 workers)")
	if bob == null or chloe == null:
		finish(); return
	check(bob.display_name == "Bob" and not bob.is_local() and bob.get_multiplayer_authority() == BOB, "Bob is a remote body owned by peer 2")
	for p in [me, bob, chloe]:
		p.staggered.connect(func(by: int) -> void: _staggers.append([p.peer_id, by]))
		p.footstep.connect(func(_pos: Vector3) -> void: _steps[p.peer_id] = int(_steps.get(p.peer_id, 0)) + 1)

	step("worker collision")
	check(me.collision_mask == (Const.LAYER_WORLD | Const.LAYER_PLAYER) and bob.collision_mask == me.collision_mask,
			"collision_mask = world | player on every body")
	check(me.collision_layer == Const.LAYER_PLAYER and (me.collision_mask & Const.LAYER_PLAYER) != 0, "bodies are on the player layer and collide with it")
	var spawn_gap := world.get_player(1).global_position.distance_to(bob.global_position)
	check(spawn_gap > 0.9, "spawn points keep bodies apart (%.2f m)" % spawn_gap)
	# The local body slides off a remote body it overlaps (kinematic vs kinematic; a slight offset picks the side,
	# exactly coincident capsules would separate vertically instead).
	_place(bob, Vector3(-3.0, 0.0, 3.0), 0.0)
	_place_me(Vector3(-2.85, 0.0, 3.0), 0.0)
	await wait_physics(8)
	var pushed := Vector2(me.global_position.x - bob.global_position.x, me.global_position.z - bob.global_position.z).length()
	check(pushed > 0.7 and me.global_position.y < 0.5, "overlapping bodies get pushed apart (%.2f m, y=%.2f)" % [pushed, me.global_position.y])
	# Exactly the same spot (a teleport onto another worker): still a sideways separation, never a stack.
	_place_me(Vector3(-3.0, 0.0, 3.0), 0.0)
	await wait_physics(8)
	pushed = Vector2(me.global_position.x - bob.global_position.x, me.global_position.z - bob.global_position.z).length()
	check(pushed > 0.7 and me.global_position.y < 0.5, "coincident bodies separate sideways too (%.2f m, y=%.2f)" % [pushed, me.global_position.y])
	_place(bob, Vector3(6.0, 0.0, -5.5), 0.0)
	_place(chloe, Vector3(-6.0, 0.0, -5.5), 0.0)
	_place_me(Vector3(0.0, 0.0, 0.0), 0.0)
	await wait_physics(2)

	# ---------------------------------------------------------------- throw: arc, lifecycle, pickup refused
	step("throw: arc lands where the maths says")
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, Vector3(-3.0, 0.0, 4.0)) as WateringCan
	check(can != null, "spawned a can")
	if can == null:
		finish(); return
	var origin := Vector3(-3.0, 1.2, 3.5)
	var vel := Vector3(0.0, 3.0, -5.0)
	var flights: Array = []
	can.flight_changed.connect(func(f: bool) -> void: flights.append(f))
	check(items.server_throw_item(can, origin, vel, 1), "server_throw_item accepted")
	check(can.is_flying() and can.flight_serial != 0 and can.holder_id == 0, "flying: serial %d, nobody holds it" % can.flight_serial)
	check(can.flight_origin == origin and can.flight_velocity == vel, "synced flight values written once")
	check(can.get_collider().collision_layer == 0, "collision off while flying")
	check(not can.can_interact(me) and can.get_denied_reason(me) == Item.REASON_IN_THE_AIR, "pickup refused mid-flight: '%s'" % can.get_denied_reason(me))
	check(not items.server_give_item(can, 1), "server_give_item refuses a flying item")
	check(GameState.get_stat(1, Const.STAT_THROWS) == 1, "STAT_THROWS counted for the thrower")
	check(not items.server_throw_item(can, origin, vel, 1), "a second throw of a flying item is refused")
	await wait_frames(3)
	check(can.is_flying() and can.position.z < origin.z and can.position.distance_to(origin) > 0.05, "item moves along the arc on this peer")
	var serial := can.flight_serial
	await wait_until(func() -> bool: return not can.is_flying(), 3.0, "flight ended within 3 s")
	# y(t) = 1.2 + 3t - 4.9t^2 = 0 -> t = 0.888 s -> z = 3.5 - 4.44
	var t_land := (vel.y + sqrt(vel.y * vel.y + 2.0 * 9.8 * origin.y)) / 9.8
	var predicted := Vector3(origin.x, 0.0, origin.z + vel.z * t_land)
	var err := Vector2(can.global_position.x - predicted.x, can.global_position.z - predicted.z).length()
	check(err < 0.2 and absf(can.global_position.y) < 0.05, "landed %.2f m from the predicted spot %s (at %s)" % [err, predicted, can.global_position])
	check(can.rest_position == can.position and can.flight_serial == 0, "rest_position synced, serial back to 0")
	check(can.get_collider().collision_layer == Const.LAYER_ITEM and can.can_interact(me), "collision and pickup restored after landing")
	check(flights == [true, false], "flight_changed(true) then (false) %s" % [flights])
	check(serial != 0 and items._next_flight_serial == serial, "serials come from the manager (%d)" % serial)
	check(can.rotation == Vector3.ZERO, "tumble reset to the rest rotation")

	step("throw: into a wall, never inside geometry, inside the room")
	check(items.server_throw_item(can, Vector3(-4.0, 1.2, 3.0), Vector3(-9.0, 1.5, 0.0), 1), "throw west at the wall")
	await wait_until(func() -> bool: return not can.is_flying(), 3.0, "wall throw ended")
	var landing := items._probe_floor_below(can.global_position + Vector3.UP * 0.02)
	check(items._inside_bounds(can.global_position, world.room.get_bounds()), "landed inside the room %s" % can.global_position)
	check(items._is_drop_spot_free(landing, null), "landing spot is free (not inside geometry, not on a station)")
	check(can.global_position.x < -4.0 and can.global_position.x > -10.0, "it went west and stopped at the wall (x=%.2f)" % can.global_position.x)

	step("throw: straight up hits the ceiling and comes down clean")
	check(items.server_throw_item(can, Vector3(-2.0, 1.2, 2.0), Vector3(0.0, 14.0, 0.0), 1), "throw at the ceiling")
	await wait_until(func() -> bool: return not can.is_flying(), 3.5, "ceiling throw ended")
	check(absf(can.global_position.y) < 0.05 and Vector2(can.global_position.x + 2.0, can.global_position.z - 2.0).length() < 0.3,
			"back on the floor below the launch point %s" % can.global_position)

	# ---------------------------------------------------------------- hits
	step("hit: a product to Bob's chest")
	_place(bob, Vector3(-3.0, 0.0, 0.0), 0.0)
	var bob_can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(-4.0, 0.0, 0.0), BOB) as WateringCan
	check(bob_can != null and bob_can.holder_id == BOB, "Bob holds a can")
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 2}, Vector3(-3.0, 0.0, 4.5)) as Product
	await wait_frames(2)
	_staggers.clear()
	var hits0 := GameState.get_stat(1, Const.STAT_HITS)
	check(items.server_throw_item(product, Vector3(-3.0, 1.0, 3.0), Vector3(0.0, 1.8, -8.0), 1), "throw at Bob")
	await wait_until(func() -> bool: return not product.is_flying(), 3.0, "flight ended")
	check(GameState.get_stat(1, Const.STAT_HITS) == hits0 + 1, "STAT_HITS +1 for the thrower")
	check(_staggers.has([BOB, 1]), "Bob.staggered(1) fired %s" % [_staggers])
	check(bob.is_stunned(), "Bob is stunned")
	check(bob_can.holder_id == 0 and not bob_can.is_flying(), "Bob's can knocked loose")
	check(bob_can.global_position.distance_to(bob.global_position) < 1.5, "the can dropped next to Bob")
	check(product.holder_id == 0 and product.global_position.distance_to(bob.global_position) < 1.5 and absf(product.global_position.y) < 0.05,
			"the product landed at Bob's feet %s" % product.global_position)
	check(items._is_drop_spot_free(items._probe_floor_below(product.global_position + Vector3.UP * 0.02), null), "hit landing spot is free")
	await wait_until(func() -> bool: return not bob.is_stunned(), 2.0, "Bob's stun passes (hit_stun_sec %.2f)" % b.hit_stun_sec)

	step("hit: the thrower cannot hit themselves; a worker far off is not hit")
	_place_me(Vector3(1.0, 0.0, 0.0), 0.0)
	await wait_physics(2)
	hits0 = GameState.get_stat(1, Const.STAT_HITS)
	_staggers.clear()
	# From just in front of my own chest, up and back through my own body.
	check(items.server_throw_item(product, me.global_position + Vector3(0.0, 1.0, -0.25), Vector3(0.0, 2.0, 3.0), 1), "throw through myself")
	await wait_until(func() -> bool: return not product.is_flying(), 3.0, "flight ended")
	check(GameState.get_stat(1, Const.STAT_HITS) == hits0 and _staggers.is_empty(), "no self hit, nobody else hit")
	check(not me.is_stunned(), "thrower not stunned")

	step("hit: a crouched worker is hit lower")
	_place(bob, Vector3(6.0, 0.0, -5.5), 0.0)
	_place(chloe, Vector3(-3.0, 0.0, 0.0), 0.0) # the x = -3 lane is clear (x = 3 has the grow-area fence)
	chloe.crouching = true
	await wait_frames(2)
	_staggers.clear()
	# Chest at 0.6 m: an arc passing 1.4 m high misses, one passing 0.7 m high hits.
	check(items.server_throw_item(product, Vector3(-3.0, 1.35, 2.5), Vector3(0.0, 1.7, -8.0), 1), "high throw at crouched Chloe")
	await wait_until(func() -> bool: return not product.is_flying(), 3.0, "flight ended")
	check(_staggers.is_empty(), "high arc misses the crouched worker")
	check(items.server_throw_item(product, Vector3(-3.0, 0.75, 2.5), Vector3(0.0, 1.4, -8.0), 1), "low throw at crouched Chloe")
	await wait_until(func() -> bool: return not product.is_flying(), 3.0, "flight ended")
	check(_staggers.has([CHLOE, 1]), "low arc hits the crouched worker %s" % [_staggers])
	chloe.crouching = false
	_place(chloe, Vector3(-6.0, 0.0, -5.5), 0.0)
	await wait_until(func() -> bool: return not chloe.is_stunned(), 2.0, "Chloe recovers")

	# ---------------------------------------------------------------- chute shots
	step("chute shot: a product into the deposit chute sells for the thrower")
	var turnin: TurnInStation = station("TurnInStation")
	var mouth := turnin.get_mouth_position()
	check(mouth.distance_to(Vector3(0.0, 0.92, 5.93)) < 0.05, "mouth at the slot on top %s" % mouth)
	check(turnin.get_collider_aabb().has_point(turnin.global_position + Vector3(0.0, 0.5, 0.0)), "collider AABB covers the box")
	check(turnin.accepts_flight_point(mouth + Vector3(0.0, 0.3, 0.0), 0.6) and not turnin.accepts_flight_point(mouth + Vector3(3.0, 0.0, 0.0), 0.6),
			"accepts_flight_point: near the mouth yes, 3 m off no")
	var value := turnin.get_sale_value(product)
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	var deposited0 := GameState.get_stat(1, Const.STAT_DEPOSITED)
	_sales.clear()
	check(items.server_throw_item(product, Vector3(0.0, 1.3, 3.0), Vector3(0.0, 2.0, 6.0), 1), "lob at the chute")
	await wait_until(func() -> bool: return items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), 3.0, "product gone (sold)")
	check(GameState.money == money0 + value and GameState.round_sales == sales0 + value, "money and round sales +$%d" % value)
	check(GameState.get_stat(1, Const.STAT_DEPOSITED) == deposited0 + value, "STAT_DEPOSITED credited to the thrower")
	check(_sales.size() == 1 and _sales[0] == [value, 1], "sale_made(%d, 1)" % value)
	check(items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "no product left")

	step("chute shot: a thrown can just lands")
	var n_items := items.get_items().size()
	money0 = GameState.money
	check(items.server_throw_item(can, Vector3(0.0, 1.3, 3.0), Vector3(0.0, 2.0, 6.0), 1), "lob the can at the chute")
	await wait_until(func() -> bool: return not can.is_flying(), 3.0, "can flight ended")
	check(is_instance_valid(can) and items.get_items().size() == n_items and GameState.money == money0, "the can is still there, nothing sold")
	var can_landing := items._probe_floor_below(can.global_position + Vector3.UP * 0.02)
	var on_station := (can_landing.get("collider") as CollisionObject3D) != null \
			and ((can_landing["collider"] as CollisionObject3D).collision_layer & Const.LAYER_INTERACTABLE) != 0
	check(not on_station and items._is_drop_spot_free(can_landing, null), "the can rests on the floor, not on the chute (%s)" % can.global_position)
	check(can.global_position.z < 5.1 and absf(can.global_position.y) < 0.05, "walked back off the station along the arc (z=%.2f)" % can.global_position.z)

	step("chute shot: refused between shifts (product lands instead)")
	var product2 := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3(0.0, 0.0, 2.0)) as Product
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	money0 = GameState.money
	check(items.server_throw_item(product2, Vector3(0.0, 1.3, 3.0), Vector3(0.0, 2.0, 6.0), 1), "lob between shifts")
	await wait_until(func() -> bool: return not product2.is_flying(), 3.0, "flight ended")
	check(is_instance_valid(product2) and GameState.money == money0, "not sold between shifts, product on the floor")
	items.server_despawn_item(product2)
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "retry -> WAITING")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "new shift")
	await wait_frames(4) # the Well re-homes the cans two frames after the reset

	# ---------------------------------------------------------------- shove
	step("shove: from behind drops the item, counts, cooldown, range")
	_place_me(Vector3(0.0, 0.0, 0.0), 0.0)                      # facing -Z
	_place(bob, Vector3(0.0, 0.0, -1.2), 0.0)                    # 1.2 m ahead, facing away (-Z): from behind
	var bob_can2 := items.get_held_by(BOB)
	if bob_can2 == null:
		bob_can2 = items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(0.0, 0.0, -3.0), BOB)
	await wait_physics(2)
	check(bob_can2 != null and bob_can2.holder_id == BOB, "Bob holds a can again")
	_staggers.clear()
	var shoves0 := GameState.get_stat(1, Const.STAT_SHOVES)
	me.request_shove(BOB)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 1, "STAT_SHOVES +1")
	check(_staggers.has([BOB, 1]) and bob.is_stunned(), "Bob staggered by 1 %s" % [_staggers])
	check(bob_can2.holder_id == 0, "shoved from behind: the can drops")
	# Cooldown: a second shove right away is ignored.
	_place(chloe, Vector3(1.0, 0.0, -1.0), PI)                   # facing +Z, i.e. towards me: from the front
	var chloe_can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(2.0, 0.0, -2.0), CHLOE)
	await wait_physics(2)
	_staggers.clear()
	me.request_shove(CHLOE)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 1 and _staggers.is_empty(), "second shove inside the cooldown is refused")
	await wait_sec(b.shove_cooldown_sec + 0.1)
	me.request_shove(CHLOE)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 2 and _staggers.has([CHLOE, 1]), "after the cooldown the shove lands")
	check(chloe_can != null and chloe_can.holder_id == CHLOE, "shoved from the front: Chloe keeps her can")
	await wait_sec(b.shove_cooldown_sec + 0.1)
	_place(bob, Vector3(0.0, 0.0, -4.0), 0.0)
	await wait_physics(2)
	_staggers.clear()
	me.request_shove(BOB)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 2 and _staggers.is_empty(), "out of range (4 m > %.1f + 1): refused" % b.shove_range)
	me.request_shove(1)
	me.request_shove(99)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 2, "shoving yourself or a ghost is refused")

	step("shove: refused while stunned or in the back room")
	_place(bob, Vector3(0.0, 0.0, -1.2), 0.0)
	await wait_physics(2)
	await wait_until(func() -> bool: return not bob.is_stunned() and not chloe.is_stunned(), 2.0, "targets recovered")
	me.apply_stagger(Vector3.ZERO, 0.6)
	check(me.is_stunned(), "I am stunned")
	_staggers.clear()
	me.request_shove(BOB)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 2 and _staggers.is_empty(), "a stunned worker cannot shove")
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "my stun passes")
	check(GameState.server_send_to_backroom(BOB, 20.0), "Bob sent to the back room")
	await wait_frames(1)
	me.request_shove(BOB)
	await wait_frames(2)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 2 and _staggers.is_empty(), "a worker in the back room cannot be shoved")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(1)

	step("shove: the server staggers the host's own player (owner path, item released)")
	var my_can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(1.0, 0.0, 1.0), 1)
	check(my_can != null and my_can.holder_id == 1, "I hold a can")
	_staggers.clear()
	me.velocity = Vector3.ZERO
	bob.server_shove(me, Vector3(0.0, 0.0, -1.0), true)
	await wait_frames(1)
	check(_staggers.has([1, BOB]), "my staggered(2) fired %s" % [_staggers])
	check(me.is_stunned() and me.velocity.z < -3.0 and me.velocity.y > 0.5, "impulse applied to my velocity %s" % me.velocity)
	check(my_can.holder_id == 0, "from behind: my can dropped")
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "stun passes")
	me.velocity = Vector3.ZERO

	step("throw: refused while stunned or in the back room, then allowed")
	check(items.server_give_item(my_can, 1), "pick the can up again")
	me.apply_stagger(Vector3.ZERO, 0.6)
	items.request_throw()
	await wait_frames(2)
	check(my_can.holder_id == 1 and not my_can.is_flying(), "no throw while stunned")
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "stun passes")
	check(GameState.server_send_to_backroom(1, 20.0), "I am sent to the back room")
	await wait_frames(1)
	items.request_throw()
	await wait_frames(2)
	check(my_can.holder_id == 0 and not my_can.is_flying(), "back room: the can left my hands on entry and nothing flies")
	GameState.server_release_from_backroom(1)
	await wait_frames(1)
	_place_me(Vector3(0.0, 0.0, 2.0), 0.0)
	await wait_physics(2)
	check(items.server_give_item(my_can, 1), "pick the can up again after the back room")
	await wait_frames(1)
	var throws0 := GameState.get_stat(1, Const.STAT_THROWS)
	items.request_throw()
	await wait_frames(2)
	check(my_can.is_flying() and my_can.holder_id == 0 and me.get_held_item() == null, "request_throw() throws what I hold; hands empty")
	check(GameState.get_stat(1, Const.STAT_THROWS) == throws0 + 1, "STAT_THROWS counted")
	check(my_can.flight_velocity.z < -5.0 and my_can.flight_velocity.y > 1.0, "thrown the way I look (-Z), with the lift %s" % my_can.flight_velocity)
	await wait_until(func() -> bool: return not my_can.is_flying(), 3.0, "landed")
	check(my_can.global_position.z < 1.0 and absf(my_can.global_position.y) < 0.05, "landed ahead of me on the floor %s" % my_can.global_position)

	# ---------------------------------------------------------------- stun blocks movement input
	step("stun: movement input is ignored, the stumble carries, the camera kicks")
	_place_me(Vector3(-3.0, 0.0, 3.0), 0.0)
	await wait_physics(3)
	me.velocity = Vector3.ZERO
	me.apply_stagger(Vector3(3.0, 0.0, 0.0), 0.5)
	check(me.is_stunned() and absf(me.velocity.x - 3.0) < 0.01 and absf(me.velocity.y - Player.STAGGER_HOP) < 0.01, "velocity += impulse + hop %s" % me.velocity)
	await wait_until(func() -> bool: return absf(me.camera.rotation.z) > deg_to_rad(3.0), 0.5, "camera rolls past 3 degrees (now %.1f)" % rad_to_deg(me.camera.rotation.z))
	Input.action_press(&"move_forward")
	await wait_physics(8)
	check(absf(me.velocity.z) < 0.3 and me.velocity.x > 1.5, "forward input ignored while stunned; the push carries %s" % me.velocity)
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "stun over")
	await wait_physics(20)
	check(me.velocity.z < -1.0, "input works again after the stun %s" % me.velocity)
	Input.action_release(&"move_forward")
	await wait_physics(10)
	check(absf(me.camera.rotation.z) < deg_to_rad(0.5) and absf(me.camera.rotation.x) < deg_to_rad(0.5), "camera back to rest")
	me.apply_stagger(Vector3(NAN, 0.0, 0.0), 0.5)
	check(not me.is_stunned() and me.velocity.is_finite(), "a non-finite impulse is ignored")

	# ---------------------------------------------------------------- footsteps
	step("footsteps: local cadence")
	_place_me(Vector3(-3.0, 0.0, 3.5), 0.0)
	await wait_physics(3)
	me.velocity = Vector3.ZERO
	_steps.clear()
	var start := me.global_position
	Input.action_press(&"move_forward")
	await wait_sec(1.0)
	Input.action_release(&"move_forward")
	var walked := Vector2(me.global_position.x - start.x, me.global_position.z - start.z).length()
	var local_steps := int(_steps.get(1, 0))
	var expected_steps := int(walked / Player.STEP_STRIDE_WALK)
	check(walked > 2.5, "walked %.2f m in a second" % walked)
	check(absi(local_steps - expected_steps) <= 1 and local_steps >= 1, "%d local steps for %.2f m (~one per %.2f m)" % [local_steps, walked, Player.STEP_STRIDE_WALK])
	await wait_physics(10)
	me.velocity = Vector3.ZERO
	_steps.clear()
	me.apply_stagger(Vector3(0.0, 0.0, -4.0), 0.5)
	await wait_sec(0.45)
	check(int(_steps.get(1, 0)) == 0, "no steps while stumbling")
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "stun over")
	_steps.clear()
	me.velocity = Vector3.ZERO
	me.velocity.y = 6.0
	Input.action_press(&"move_forward")
	await wait_physics(6)
	Input.action_release(&"move_forward")
	check(not me.is_on_floor() and int(_steps.get(1, 0)) == 0, "no steps while airborne")
	await wait_physics(80)

	step("footsteps: remote cadence follows the walk phase")
	_place(bob, Vector3(3.0, 0.0, 3.0), 0.0)
	await wait_frames(20) # settle: _visual_speed back to 0
	_steps.clear()
	var t0 := Time.get_ticks_msec()
	var bob_speed := 3.6
	while Time.get_ticks_msec() - t0 < 1000:
		var dt := get_process_delta_time()
		bob.net_position += Vector3(bob_speed * dt, 0.0, 0.0)
		await get_tree().process_frame
	var remote_steps := int(_steps.get(BOB, 0))
	# M14: one step per STEP_STRIDE_WALK of smoothed movement: about 2.2 steps in a second at 3.6 m/s
	var predicted_steps := bob_speed / Player.STEP_STRIDE_WALK
	check(remote_steps >= 1 and remote_steps <= 4 and absf(float(remote_steps) - predicted_steps) <= 1.5,
			"%d remote steps in 1 s at %.1f m/s (predicted %.1f)" % [remote_steps, bob_speed, predicted_steps])
	await wait_sec(0.4) # the smoothed speed decays: the last footfall may land in this window
	_steps.clear()
	await wait_sec(0.5)
	check(int(_steps.get(BOB, 0)) == 0, "a standing remote body takes no steps")
	Player.server_stagger(bob, Vector3(1.0, 0.0, 0.0), false, 1)
	_steps.clear()
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		bob.net_position += Vector3(bob_speed * get_process_delta_time(), 0.0, 0.0)
		await get_tree().process_frame
	check(int(_steps.get(BOB, 0)) == 0, "a stumbling remote body takes no steps")

	# ---------------------------------------------------------------- interactor prompt
	step("interactor: shove prompt")
	_place_me(Vector3(0.0, 0.0, 0.0), 0.0)
	_place(bob, Vector3(0.0, 0.0, -1.2), 0.0)
	_place(chloe, Vector3(-6.0, 0.0, -5.5), 0.0)
	me.camera.rotation = Vector3.ZERO
	me.head.rotation.x = 0.0
	await wait_physics(4)
	var interactor := me.get_interactor()
	me.camera.look_at(bob.get_chest_position(), Vector3.UP)
	await wait_physics(3)
	check(interactor.shove_target == bob, "Bob under the crosshair is the shove target")
	check(interactor.prompt_text == "[F] Shove Bob" and interactor.prompt_enabled, "prompt '%s' (enabled=%s)" % [interactor.prompt_text, interactor.prompt_enabled])
	me.apply_stagger(Vector3.ZERO, 0.4)
	await wait_physics(2)
	check(interactor.prompt_text == "[F] Shove Bob" and not interactor.prompt_enabled, "greyed while I am stunned")
	await wait_until(func() -> bool: return not me.is_stunned(), 2.0, "stun over")
	await wait_sec(b.shove_cooldown_sec)
	_staggers.clear()
	var shoves_before := GameState.get_stat(1, Const.STAT_SHOVES)
	_press_key(KEY_F)
	await wait_frames(3)
	check(_staggers.has([BOB, 1]) and GameState.get_stat(1, Const.STAT_SHOVES) == shoves_before + 1, "pressing F shoves Bob (input -> Interactor -> RPC)")
	_place(bob, Vector3(0.0, 0.0, -3.0), 0.0)
	await wait_physics(3)
	check(interactor.shove_target == null and interactor.prompt_text == "", "out of shove range: no target, no prompt")
	_place(bob, Vector3(6.0, 0.0, -5.5), 0.0)
	me.camera.rotation = Vector3.ZERO

	step("interactor: throw key")
	var key_can := items.get_items_of_type(Const.ITEM_WATERING_CAN)[0]
	items.server_drop_item(key_can, Vector3(1.0, 0.0, 1.0))
	check(items.server_give_item(key_can, 1), "hold a can")
	await wait_frames(2)
	_press_key(KEY_R)
	await wait_frames(3)
	check(key_can.is_flying() and key_can.holder_id == 0, "pressing R throws it (input -> Interactor -> ItemManager RPC)")
	await wait_until(func() -> bool: return not key_can.is_flying(), 3.0, "landed")
	Game.set_ui_lock(&"physics_test", true)
	check(items.server_give_item(key_can, 1), "hold it again")
	await wait_frames(2)
	_press_key(KEY_R)
	await wait_frames(3)
	check(not key_can.is_flying() and key_can.holder_id == 1, "R is ignored while the UI is locked")
	Game.set_ui_lock(&"physics_test", false)
	items.server_release_holder(1)

	step("back to menu")
	Sfx.stop_all()
	await wait_frames(5)
	Game.return_to_menu()
	await wait_until(func() -> bool: return Game.world == null, 3.0, "world freed")
	finish()


## Puts a remote (fake) body exactly at `pos` (synced pose + node) with yaw `yaw`.
func _place(p: Player, pos: Vector3, yaw: float) -> void:
	p.net_position = pos
	p.net_yaw = yaw
	p.net_pitch = 0.0
	p.position = pos
	p.rotation = Vector3(0.0, yaw, 0.0)
	p.velocity = Vector3.ZERO


## Puts my own body at `pos` facing `yaw`.
func _place_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = pos + Vector3.UP * 0.02
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _press_key(key: Key) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		ev.keycode = key
		ev.pressed = pressed
		Input.parse_input_event(ev)
