extends "res://tools/tests/qa_base.gd"
## M17 cart suite (cart agent): the hand truck on a single headless host with one fake worker (Bob: a host-side body
## without an owning peer, so the SERVER side runs directly on him). Plain game (no --replay).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/cart_body.gd --port=7998 --round-sec=900
## Pins:
##   the spot     Dock/HandTruckSpot on the dock, clear of the loose cover in all four COVER_LAYOUTS, of anything solid,
##                of the route graph, the doorways, the arrivals and the collector's walk; no truck before the first
##                shift, exactly one (empty, upright, at the spot) once it starts
##   the item     registered with the item system, model and nodes, label, sound recipe, props round trip
##   carrying     heavy: walking speed x heavy_speed_factor, no sprint (the real local simulation), loaded or empty;
##                stands on its wheels in front of the body, tipped back; never thrown (host refusal + the local toast),
##                dropped with Q, upright; Bob's arms (both hands)
##   loading      E on a floor bundle with the truck in hand (the real request), E on a standing truck with a bundle in
##                hand, from a rack (the exact drying kept), "Truck's full." at four; despawned through the item system
##   unloading    E on the bags of a standing truck (the real request: aim decides "Take one" / "Pick up"), the top
##                bundle in hand with exactly its data (strain, amount, cured, dry_left); refusals
##   the chute    every bundle, one sale each, the exact money, STAT_DEPOSITED / STAT_CURED, the job hook, "Truck's
##                empty."; a sale that meets the payment ends the shift and the rest stay on the truck
##   the raid     a truck in sight loses its whole load (raid_took per bundle, the sweep's count, the holder written up
##                once); out of sight (a wall, the grow hall) or empty: nothing; a floor bundle is still taken as before;
##                the collector's unpaid take never touches the load
##   shift start  NEXT SHIFT puts the truck back at the spot out of the holder's hands with its load; START OVER
##                despawns it and the next shift's start spawns a fresh, empty one
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const FLOOR_A := Vector3(-3.0, 0.0, 3.0)
const FAR_B := Vector3(-8.0, 0.0, 3.0)

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var chute: TurnInStation
var rack1: DryingRack
var truck: HandTruck
var _load_events: int = 0
var _sales: Array = []        # amounts, in order
var _notes: Array = []        # [strain, amount, cured, value, seller]
var _took: Array = []         # [item_name, holder]
var _swept: Array = []        # [index, taken]
var _write_ups: Array = []    # [peer, reason]


func _run() -> void:
	_label = "cart"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false

	step("hosting")
	Game.start_host("Tester", port_arg(7998))
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
	chute = room.get_station("TurnInStation") as TurnInStation
	rack1 = room.get_station("DryingRack1") as DryingRack
	GameState.sale_made.connect(func(amount: int, _seller: int) -> void: _sales.append(amount))
	GameState.deposit_noted.connect(func(strain: StringName, amount: int, cured: bool, value: int, seller: int) -> void:
		_notes.append([strain, amount, cured, value, seller]))
	Events.raid_took.connect(func(item_name: String, holder: int) -> void: _took.append([item_name, holder]))
	Events.raid_swept.connect(func(index: int, taken: int) -> void: _swept.append([index, taken]))
	GameState.worker_written_up.connect(func(p: int, reason: String, _c: int) -> void: _write_ups.append([p, reason]))

	await _test_spot_geometry()
	step("no truck before the first shift")
	check(GameState.phase == GameState.Phase.WAITING and items.get_items_of_type(Const.ITEM_HAND_TRUCK).is_empty(), "WAITING: no hand truck yet")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(1000)
	await wait_frames(2)
	await _test_truck_at_spot("the first shift")
	if truck == null:
		finish(); return
	truck.load_changed.connect(func() -> void: _load_events += 1)
	await _test_item()
	await _test_carry(b)
	await _test_load()
	await _test_unload()
	await _test_chute(b)
	await _test_raid()
	await _test_chute_quota(b)
	await _test_shift_start()
	finish()


# --- the spot ----------------------------------------------------------------------------------------------------------

func _test_spot_geometry() -> void:
	step("the spot: Dock/HandTruckSpot")
	var marker := room.get_node_or_null(^"Dock/HandTruckSpot") as Marker3D
	check(marker != null, "Dock/HandTruckSpot is a Marker3D")
	var spot := room.get_hand_truck_spot()
	check(spot.origin.is_equal_approx(Vector3(-8.0, 0.0, 8.6)) and marker != null and spot.is_equal_approx(marker.global_transform),
			"at (-8, 0, 8.6) (%s)" % spot.origin)
	var front := -spot.basis.z
	check(front.is_equal_approx(Vector3.BACK), "the truck's plate faces into the dock (+Z) (%s)" % front)
	check(room.get_area_index(spot.origin) == 2 and room.contains_point(spot.origin, 0.45), "on the loading dock, 0.45 m clear of its walls")
	var spot2 := Vector2(spot.origin.x, spot.origin.z)
	var clear_route := true
	for e: Vector2i in Room.ROUTE_EDGES:
		var a: Vector2 = Room.ROUTE_POINTS[e.x]
		var c: Vector2 = Room.ROUTE_POINTS[e.y]
		var closest := Geometry2D.get_closest_point_to_segment(spot2, a, c)
		if closest.distance_to(spot2) < Room.ROUTE_MARGIN + 0.8:
			clear_route = false
			print("      route edge %s passes %.2f m from the spot" % [e, closest.distance_to(spot2)])
	check(clear_route, "off every route graph edge by ROUTE_MARGIN + 0.8 m")
	var doors_clear := true
	for d: Dictionary in room.get_doorways():
		var c: Vector3 = d["center"]
		if Vector2(c.x, c.z).distance_to(spot2) < float(d["width"]) * 0.5 + 0.6:
			doors_clear = false
	check(doors_clear, "out of every doorway")
	var arrivals_clear := true
	for i in 8:
		var p := room.get_arrival_transform(i).origin
		if Vector2(p.x, p.z).distance_to(spot2) < 1.5:
			arrivals_clear = false
	var collector := room.get_collector_spot().origin
	var door := room.get_roller_door_position()
	var walk_d := Geometry2D.get_closest_point_to_segment(spot2, Vector2(door.x, door.z), Vector2(collector.x, collector.z)).distance_to(spot2)
	check(arrivals_clear and walk_d > 2.0, "clear of the arrivals and the collector's walk (%.1f m)" % walk_d)
	var footprint := BoxShape3D.new()
	footprint.size = Vector3(0.66, 1.2, 0.72)
	var space := world.get_world_3d().direct_space_state
	var layout0 := room.get_cover_layout()
	for layout in Room.COVER_LAYOUTS.size():
		room.apply_cover_layout(layout)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var in_cover := room.is_in_cover(spot.origin, 0.5)
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = footprint
		q.transform = Transform3D(spot.basis, spot.origin + spot.basis * Vector3(0.0, 0.65, -0.04))
		q.collision_mask = Const.LAYER_WORLD | Const.LAYER_INTERACTABLE
		var hits := space.intersect_shape(q, 4)
		var names: PackedStringArray = []
		for hit in hits:
			names.append(str((hit["collider"] as Node).get_path()))
		check(not in_cover and hits.is_empty(), "cover layout %d: the truck's footprint is clear of cover (0.5 m) and of anything solid %s" % [layout, names])
	room.apply_cover_layout(layout0)
	await get_tree().physics_frame


func _test_truck_at_spot(tag: String) -> void:
	var trucks := items.get_items_of_type(Const.ITEM_HAND_TRUCK)
	truck = trucks[0] as HandTruck if trucks.size() == 1 else null
	if not check(trucks.size() == 1 and truck != null, "%s: exactly one hand truck (%d)" % [tag, trucks.size()]):
		return
	var spot := room.get_hand_truck_spot()
	check(truck.global_position.distance_to(spot.origin) < 0.001 and truck.rest_position.distance_to(spot.origin) < 0.001,
			"%s: it stands at the spot (%s)" % [tag, truck.global_position])
	check(not truck.is_held() and not truck.is_flying() and absf(angle_difference(truck.rotation.y, PI)) < 0.001
			and absf(truck.rotation.x) < 0.001 and absf(truck.rotation.z) < 0.001, "%s: upright, nobody holds it, turned like the marker (%s)" % [tag, truck.rotation])


# --- the item ----------------------------------------------------------------------------------------------------------

func _test_item() -> void:
	step("the item")
	check(ItemManager.get_scene_path(Const.ITEM_HAND_TRUCK) == "res://scenes/items/hand_truck.tscn" and truck.item_type == Const.ITEM_HAND_TRUCK,
			"Const.ITEM_HAND_TRUCK maps to scenes/items/hand_truck.tscn")
	check(truck.get_node_or_null(^"Visual/Model") is Toonify and truck.get_node_or_null(^"Visual/Load") is Node3D
			and truck.get_node_or_null(^"LoadLabel") is Label3D, "Visual/Model (hand_truck.glb), Visual/Load, LoadLabel")
	var col := truck.get_collider()
	check(col != null and col.collision_layer == Const.LAYER_ITEM, "an item collider on LAYER_ITEM")
	check(truck.get_load().is_empty() and truck.get_load_count() == 0 and HandTruck.get_capacity() == 4 and not truck.is_full(), "empty, takes 4")
	check(truck.get_display_name() == "Hand truck" and truck.get_label_text() == "Hand truck (0/4)" and truck.get_props().is_empty(),
			"label '%s', props %s" % [truck.get_label_text(), truck.get_props()])
	var label := truck.get_node(^"LoadLabel") as Label3D
	check(label.visible and label.text == "0/4", "the floating label reads '%s'" % label.text)
	check(truck.is_heavy(), "it is heavy")
	check(Sfx.has_sound(&"truck_load") and Sfx.measure(Sfx.get_stream(&"truck_load")).seconds > 0.3, "the truck_load sound has a recipe of its own (%.2f s)" % Sfx.measure(Sfx.get_stream(&"truck_load")).seconds)
	# The props round trip (a spawn with a load, plain types only).
	var entries := [{"strain_id": "purple", "amount": 2, "cured": true, "dry_left": 0.0}, {"strain_id": &"budget", "amount": 1, "cured": false, "dry_left": 6.5}]
	var text := HandTruck.encode_cargo(entries)
	check(text == "purple|2|1|0.00;budget|1|0|6.50", "encoded '%s'" % text)
	check(HandTruck.decode_cargo(text) == [{"strain_id": "purple", "amount": 2, "cured": true, "dry_left": 0.0},
			{"strain_id": "budget", "amount": 1, "cured": false, "dry_left": 6.5}], "decoded back")
	check(HandTruck.clean_entry({"strain_id": 5}).is_empty() and HandTruck.clean_entry("x").is_empty() and HandTruck.clean_entry({"strain_id": ""}).is_empty()
			and HandTruck.clean_entry({"strain_id": "budget", "amount": NAN}).is_empty() and HandTruck.clean_entry({"strain_id": "budget", "amount": -3})["amount"] == 1,
			"junk entries are refused or clamped")
	var other := items.server_spawn_item(Const.ITEM_HAND_TRUCK, {"cargo": text}, FAR_B) as HandTruck
	await wait_frames(1)
	check(other != null and other.get_load_count() == 2 and other.get_props() == {"cargo": text}
			and other.get_node(^"Visual/Load").get_child_count() == 2, "a truck spawned with props carries them (%s)" % [other.get_props() if other != null else {}])
	items.server_despawn_item(other)
	await wait_frames(1)
	check(items.get_items_of_type(Const.ITEM_HAND_TRUCK).size() == 1, "back to the one truck")


# --- carrying ------------------------------------------------------------------------------------------------------------

func _test_carry(b: BalanceConfig) -> void:
	step("carrying: heavy, on its wheels in front of the body")
	var heavy_speed: float = b.walk_speed * b.heavy_speed_factor
	_put_me(FLOOR_A, 0.0)
	await wait_physics(3)
	check(not me.is_carrying_heavy() and is_equal_approx(me.get_move_speed(), b.walk_speed), "empty hands: walking speed")
	check(items.server_give_item(truck, 1) and truck.holder_id == 1, "I take the truck")
	await wait_frames(2)
	check(me.is_carrying_heavy() and is_equal_approx(me.get_move_speed(), heavy_speed), "holding it: heavy (aims for %.2f m/s)" % heavy_speed)
	var walked: float = await _measure_speed(false)
	check(is_equal_approx(walked, heavy_speed), "the body walks at %.2f m/s (x%.1f)" % [walked, b.heavy_speed_factor])
	var sprinted: float = await _measure_speed(true)
	check(is_equal_approx(sprinted, heavy_speed), "holding sprint changes nothing (%.2f m/s)" % sprinted)
	await wait_frames(1)
	var want := HandTruck.get_held_transform(me)
	check(truck.global_transform.is_equal_approx(want), "it follows the body: %s (want %s)" % [truck.global_position, want.origin])
	var axle := truck.global_transform * HandTruck.AXLE
	var fwd := -me.global_basis.z
	var flat := Vector2(axle.x - me.global_position.x, axle.z - me.global_position.z)
	check(is_equal_approx(axle.y, me.global_position.y + HandTruck.AXLE.y) and absf(flat.length() - HandTruck.HELD_REACH) < 0.01
			and flat.normalized().dot(Vector2(fwd.x, fwd.z).normalized()) > 0.999, "the axle rides at wheel height, %.2f m straight ahead" % flat.length())
	var nose := truck.global_transform * Vector3(0.0, 0.0, -0.38)
	var grip := truck.global_transform * Vector3(0.0, 1.245, 0.18)
	check(nose.y > me.global_position.y + 0.15 and grip.y > me.global_position.y + 0.9 and grip.y < me.global_position.y + 1.2,
			"tipped back: the plate's nose off the floor (%.2f), the grip at hand height (%.2f)" % [nose.y - me.global_position.y, grip.y - me.global_position.y])
	var grip_flat := Vector2(grip.x - me.global_position.x, grip.z - me.global_position.z).length()
	check(grip_flat > 0.4 and grip_flat < 0.8, "the grip is %.2f m in front of the body" % grip_flat)
	var top := truck.global_transform * Vector3(0.0, 0.95, -0.1)
	check(me.camera.is_position_in_frustum(grip) and me.camera.is_position_in_frustum(top)
			and not me.camera.is_position_in_frustum(me.global_position + fwd * 0.3),
			"looking straight ahead, the grip and the top of a full load are at the bottom of the view (my own feet are not)")
	# Turning the body turns the truck; looking down does not tip it.
	me.rotation.y = 1.0
	me.head.rotation.x = -0.6
	await wait_frames(2)
	check(truck.global_transform.is_equal_approx(HandTruck.get_held_transform(me)) and absf(angle_difference(truck.global_rotation.y, 1.0)) < 0.01,
			"it turns with the body, not with the look pitch")
	me.head.rotation.x = 0.0
	check(not (truck.get_node(^"LoadLabel") as Label3D).visible, "the label is hidden while it is held")

	step("carrying: never thrown, dropped with Q")
	toasts.clear()
	var at := truck.global_position
	me.get_interactor().try_throw()
	await wait_frames(2)
	check(toast_seen(HandTruck.REASON_THROW) and truck.holder_id == 1 and not truck.is_flying(), "RMB: 'Too heavy to throw.', still in my hands")
	items._rpc_request_throw()
	await wait_frames(2)
	check(truck.holder_id == 1 and not truck.is_flying(), "a throw request reaching the host is refused")
	check(not items.server_throw_item(truck, at + Vector3.UP, Vector3(0.0, 2.0, -6.0), 1) and not truck.is_flying(), "server_throw_item refuses the truck")
	check(GameState.get_stat(1, Const.STAT_THROWS) == 0, "no throw counted")
	items.request_drop()
	await wait_frames(2)
	check(truck.holder_id == 0 and not truck.is_flying(), "Q: dropped")
	check(absf(truck.rotation.x) < 0.001 and absf(truck.rotation.z) < 0.001 and absf(truck.global_position.y) < 0.05
			and (truck.get_node(^"LoadLabel") as Label3D).visible, "it stands upright on the floor, label shown (%s)" % truck.global_position)
	var to_me := Vector2(me.global_position.x - truck.global_position.x, me.global_position.z - truck.global_position.z).normalized()
	var handle_side := Vector2(truck.global_basis.z.x, truck.global_basis.z.z).normalized()
	check(to_me.dot(handle_side) > 0.9, "its handle side faces whoever dropped it")
	check(not me.is_carrying_heavy() and is_equal_approx(me.get_move_speed(), b.walk_speed), "walking speed again at once")

	step("carrying: Bob holds it with both hands")
	_put(bob, truck.global_position + Vector3(0.0, 0.0, 1.2))
	await wait_frames(2)
	truck._server_interact(bob)
	check(truck.holder_id == BOB and bob.is_carrying_heavy(), "Bob picks it up (the host's interaction): heavy for him too")
	await wait_sec(0.6)
	check(bob.arm_l != null and bob.arm_l.rotation.distance_to(Player.CART_ARM_ROTATION) < 0.15 and bob.arm_r.rotation.distance_to(Player.HOLD_ARM_ROTATION) < 0.15,
			"both arms come up on his body (left %s)" % [bob.arm_l.rotation if bob.arm_l != null else Vector3.INF])
	items.server_release_holder(BOB)
	await wait_sec(0.6)
	check(truck.holder_id == 0 and bob.arm_l.rotation.distance_to(Player.CART_ARM_ROTATION) > 0.5, "let go: the left arm comes down")
	_put(bob, FAR_B)


## Walks the local body forward for a moment (the real input actions, the real _physics_process) and returns the
## horizontal speed it settled at.
func _measure_speed(sprint: bool) -> float:
	_put_me(FLOOR_A, 0.0)
	await wait_physics(3)
	Input.action_press(&"move_forward")
	if sprint:
		Input.action_press(&"sprint")
	await wait_physics(24)
	var v := Vector2(me.velocity.x, me.velocity.z).length()
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")
	await wait_physics(12)
	return v


# --- loading -----------------------------------------------------------------------------------------------------------

func _test_load() -> void:
	step("loading: E on a bundle on the floor with the truck in hand (the real request)")
	_put_me(FLOOR_A, 0.0)
	check(items.server_give_item(truck, 1), "I hold the truck")
	await wait_frames(2)
	var events0 := _load_events
	var first := _bundle(&"purple", 2, me.global_position + Vector3(0.6, 0.0, 0.4))
	await wait_frames(1)
	check(first.can_interact(me) and first.get_prompt(me) == "Load Purple Haze x2 (0/4)", "the bundle's prompt: '%s'" % first.get_prompt(me))
	first.interact(me)
	await wait_frames(2)
	check(not is_instance_valid(first) or first.is_queued_for_deletion() or not first.is_inside_tree(), "the bundle is gone (despawned by the item system)")
	check(truck.get_load() == [{"strain_id": &"purple", "amount": 2, "cured": false, "dry_left": 0.0}], "the load holds its data %s" % [truck.get_load()])
	check(truck.holder_id == 1 and truck.get_label_text() == "Hand truck (1/4)" and _load_events == events0 + 1, "still in my hands, 1/4, load_changed once")
	var bags := truck.get_node(^"Visual/Load")
	check(bags.get_child_count() == 1 and (bags.get_child(0) as Toonify).tint.is_equal_approx(HandTruck.bag_color({"strain_id": "purple", "cured": false})),
			"one bag on the plate, in Purple Haze's colour")
	var cured := _bundle(&"golden", 2, me.global_position + Vector3(-0.6, 0.0, 0.4), {"cured": true})
	await wait_frames(1)
	check(cured.get_prompt(me) == "Load Golden Kush x2 (1/4)", "'%s'" % cured.get_prompt(me))
	cured._server_interact(me)
	await wait_frames(1)
	check(truck.get_load_count() == 2 and truck.get_load()[1] == {"strain_id": &"golden", "amount": 2, "cured": true, "dry_left": 0.0}, "a cured bundle goes on top, cured %s" % [truck.get_load()])
	check((bags.get_child(1) as Toonify).tint.is_equal_approx(HandTruck.bag_color({"strain_id": "golden", "cured": true}))
			and HandTruck.bag_color({"strain_id": "golden", "cured": true}).v < HandTruck.bag_color({"strain_id": "golden", "cured": false}).v,
			"its bag is the darker cured shade")
	check(bags.get_child(1).position.y > bags.get_child(0).position.y + 0.2, "stacked on the first")
	# Somebody else's bundle is not loaded.
	var bobs := _bundle(&"budget", 1, Vector3.ZERO, {}, BOB)
	await wait_frames(1)
	check(not bobs.can_interact(me) and bobs.get_denied_reason(me) == HandTruck.REASON_CARRIED and not truck.server_load(bobs, 1),
			"a bundle in Bob's hands: '%s'" % bobs.get_denied_reason(me))

	step("loading: E on the standing truck with a bundle in hand")
	items.request_drop()
	await wait_frames(2)
	_put(bob, truck.global_position + truck.global_basis.z * 1.2)
	await wait_frames(2)
	check(truck.holder_id == 0 and truck.can_interact(bob) and truck.get_prompt(bob) == "Load Budget Bud x1 (2/4)", "Bob's prompt on the truck: '%s'" % truck.get_prompt(bob))
	truck._server_interact(bob)
	await wait_frames(1)
	check(items.get_held_by(BOB) == null and truck.get_load_count() == 3 and truck.get_load()[2]["strain_id"] == &"budget", "his bundle is on the truck, his hands are empty")
	# Holding something else: hands full.
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, bob.global_position, BOB)
	await wait_frames(1)
	check(not truck.can_interact(bob) and truck.get_denied_reason(bob) == HandTruck.REASON_HANDS_FULL, "with a can in hand: '%s'" % truck.get_denied_reason(bob))
	items.server_despawn_item(can)
	await wait_frames(1)

	step("loading: off a rack, keeping the exact drying it still needs")
	var wet := _bundle(&"purple", 1, Vector3.ZERO, {}, BOB)
	_put(bob, rack1.global_position + Vector3(0.0, 0.0, 1.4))
	await wait_frames(1)
	rack1.set_process(false)
	check(rack1.server_hang(bob), "Bob hangs a bundle on rack 1")
	rack1.tick(5.2)
	var exact := rack1.get_exact_left(wet)
	check(wet.rack and wet.dry_left > exact + 0.05, "on the hook: exact %.2f s left, synced %.2f" % [exact, wet.dry_left])
	_put_me(rack1.global_position + Vector3(0.0, 0.0, 2.3), PI)
	check(items.server_give_item(truck, 1), "I take the truck to the rack")
	await wait_frames(2)
	check(wet.can_interact(me) and wet.get_prompt(me) == "Load Purple Haze x1 (3/4)", "a hanging bundle with the truck in hand: '%s'" % wet.get_prompt(me))
	wet.interact(me)
	await wait_frames(2)
	rack1.tick(0.016)
	check(truck.get_load_count() == 4 and is_equal_approx(float(truck.get_load()[3]["dry_left"]), exact)
			and not bool(truck.get_load()[3]["cured"]), "on the truck with %.2f s still to dry (%s)" % [exact, truck.get_load()[3]])
	check(rack1.get_hung_count() == 0, "the hook is free")
	rack1.set_process(true)
	check(truck.is_full() and truck.get_status_text() == "4/4", "four bundles: full")

	step("loading: full at four")
	var fifth := _bundle(&"budget", 1, me.global_position + Vector3(0.5, 0.0, -0.5))
	await wait_frames(1)
	check(not fifth.can_interact(me) and fifth.get_denied_reason(me) == HandTruck.REASON_FULL, "a fifth bundle: '%s'" % fifth.get_denied_reason(me))
	toasts.clear()
	fifth.interact(me)
	await wait_frames(2)
	check(toast_seen(HandTruck.REASON_FULL) and is_instance_valid(fifth) and fifth.holder_id == 0 and truck.get_load_count() == 4, "pressing E anyway: the toast, the bundle stays on the floor")
	check(not truck.server_load(fifth, 1) and truck.get_load_count() == 4, "the host refuses it too")
	items.server_despawn_item(fifth)
	await wait_frames(1)
	check(truck.get_props() == {"cargo": "purple|2|0|0.00;golden|2|1|0.00;budget|1|0|0.00;purple|1|0|%.2f" % exact}, "props %s" % [truck.get_props()])


# --- unloading -----------------------------------------------------------------------------------------------------------

func _test_unload() -> void:
	step("unloading: E on the bags of the standing truck takes the top one")
	items.request_drop()
	await wait_frames(2)
	check(truck.holder_id == 0, "the truck stands")
	var bags_mid := truck.get_load_center()
	var handle := truck.global_transform * Vector3(0.0, 1.245, 0.18)
	# Rays from 1.4 m in front of the plate, at eye height.
	var eye := truck.global_position - truck.global_basis.z * 1.4 + Vector3.UP * 1.6
	check(truck.is_ray_on_load(eye, bags_mid - eye), "a ray at the bags is on the load (passes it at %.2f m)" % truck.get_aim_height(eye, bags_mid - eye))
	check(not truck.is_ray_on_load(eye, handle - eye), "a ray at the handle is not (passes it at %.2f m)" % truck.get_aim_height(eye, handle - eye))
	var behind := truck.global_position + truck.global_basis.z * 1.4 + Vector3.UP * 1.6
	check(truck.is_ray_on_load(behind, bags_mid - behind) and not truck.is_ray_on_load(behind, handle - behind),
			"from the handle side too: the bags take one, the handle picks up (%.2f / %.2f m)" % [truck.get_aim_height(behind, bags_mid - behind), truck.get_aim_height(behind, handle - behind)])
	check(not is_finite(truck.get_aim_height(eye, Vector3.UP)), "a ray into the air misses")
	await _aim_me_at(truck, bags_mid)
	check(truck.is_aimed_at_load(me) and truck.can_interact(me) and truck.get_prompt(me) == "Take one (4/4)", "aiming at the bags: '%s'" % truck.get_prompt(me))
	var top: Dictionary = truck.get_load()[3]
	truck.interact(me)
	await wait_frames(2)
	var got := items.get_held_by(1) as Product
	check(got != null and got.strain_id == &"purple" and got.amount == 1 and not got.cured and is_equal_approx(got.dry_left, float(top["dry_left"])),
			"the top bundle is in my hands with its data (%s)" % [got.get_props() if got != null else {}])
	check(truck.get_load_count() == 3 and truck.get_node(^"Visual/Load").get_child_count() == 3 and truck.get_status_text() == "3/4", "three left on the truck")
	check(got != null and got.get_status_text() == "%d s to dry" % ceili(float(top["dry_left"])), "it still has to dry ('%s')" % (got.get_status_text() if got != null else ""))
	toasts.clear()
	check(truck.get_take_denial(me) == HandTruck.REASON_HANDS_FULL and truck.server_unload(1) == null, "with full hands nothing comes off")
	items.server_despawn_item(got)
	await wait_frames(1)

	step("unloading: the frame above the bags picks the truck up")
	await _aim_me_at(truck, handle)
	check(not truck.is_aimed_at_load(me) and truck.get_prompt(me) == "Pick up Hand truck (3/4)", "aiming at the handle: '%s'" % truck.get_prompt(me))
	truck.interact(me)
	await wait_frames(2)
	check(truck.holder_id == 1 and truck.get_load_count() == 3, "picked up, load and all")
	items.request_drop()
	await wait_frames(2)

	step("unloading: the data round trip, cured")
	var top2: Dictionary = truck.get_load()[2]
	check(top2["strain_id"] == &"budget", "Budget Bud is on top now")
	var budget := truck.server_unload(1) as Product
	check(budget != null and budget.holder_id == 1 and budget.get_props() == {"strain_id": "budget", "amount": 1}, "server_unload(1): in my hands, %s" % [budget.get_props() if budget != null else {}])
	# Back on: the standing truck takes it from my hands (the real request).
	await _aim_me_at(truck, truck.get_load_center())
	check(truck.get_prompt(me) == "Load Budget Bud x1 (2/4)", "with it in hand the truck says '%s'" % truck.get_prompt(me))
	truck.interact(me)
	await wait_frames(2)
	check(truck.get_load_count() == 3 and items.get_held_by(1) == null, "back on the truck")
	items.server_give_item(truck, 1)
	await wait_frames(1)
	check(truck.server_unload(BOB) == null, "nothing comes off a truck somebody holds")
	items.request_drop()
	await wait_frames(2)
	var cured_entry: Dictionary = truck.get_load()[1]
	var popped: Array = []
	for i in 2:
		var p := truck.server_unload(0) as Product
		popped.append(p)
	var golden := popped[1] as Product
	check(golden != null and golden.holder_id == 0 and golden.cured and golden.amount == 2 and golden.strain_id == &"golden"
			and golden.get_props() == {"strain_id": "golden", "amount": 2, "cured": true}, "peer 0: on the floor in front of the plate, cured kept (%s)" % [golden.get_props() if golden != null else {}])
	check(cured_entry["cured"] == true and golden != null and chute.get_sale_value(golden) == TurnInStation.compute_sale_value(Config.balance.get_seed(&"golden"), 2, GameState.get_sale_multiplier(), true),
			"it prices as a cured bundle ($%d)" % (chute.get_sale_value(golden) if golden != null else -1))
	check(golden != null and golden.global_position.distance_to(truck.global_position - truck.global_basis.z * 0.75) < 0.01, "it lies 0.75 m in front of the plate")
	# Reload them for the chute (bottom: purple x2; then golden cured, budget).
	_put_me(truck.global_position + truck.global_basis.z * 1.0, 0.0)
	for p in [golden, popped[0]]:
		check(truck.server_load(p, 0), "%s back on" % (p as Product).strain_id)
	await wait_frames(1)
	check(truck.get_load_count() == 3 and truck.server_unload(0) != null and truck.get_load_count() == 2, "peer 0 unload works on a standing truck")
	_clear_products()
	await wait_frames(1)


# --- the chute --------------------------------------------------------------------------------------------------------------

func _test_chute(b: BalanceConfig) -> void:
	step("the chute: every bundle, one sale each, the exact money")
	# Load: purple x2 (already on), golden x2 cured, budget x1, brick x3 cured.
	check(truck.get_load() == [{"strain_id": &"purple", "amount": 2, "cured": false, "dry_left": 0.0}, {"strain_id": &"golden", "amount": 2, "cured": true, "dry_left": 0.0}],
			"on the truck: Purple Haze x2, Golden Kush x2 cured %s" % [truck.get_load()])
	for spec: Array in [[&"budget", 1, false], [&"brick", 3, true]]:
		var p := _bundle(spec[0], spec[1], truck.global_position + Vector3(0.7, 0.0, 0.0), {"cured": spec[2]})
		check(truck.server_load(p, 0), "%s x%d on" % [spec[0], spec[1]])
	_put_me(chute.global_position + chute.global_basis.z * 1.3, 0.0)
	me.look_at(Vector3(chute.global_position.x, me.global_position.y, chute.global_position.z), Vector3.UP)
	check(items.server_give_item(truck, 1), "I bring the truck to the chute")
	await wait_frames(2)
	var mult := GameState.get_sale_multiplier()
	var expected: Array = []
	var cured_n := 0
	for i in range(truck.get_load_count() - 1, -1, -1):
		var e: Dictionary = truck.get_load()[i]
		expected.append(TurnInStation.compute_sale_value(b.get_seed(e["strain_id"]), int(e["amount"]), mult, bool(e["cured"])))
		if bool(e["cured"]):
			cured_n += 1
	var total := 0
	for v: int in expected:
		total += v
	check(chute.get_load_value(truck) == total and chute.get_prompt(me) == "Deposit 4 bundles (+$%d)" % total, "the chute's prompt: '%s'" % chute.get_prompt(me))
	check(chute.can_interact(me) and chute.get_denied_reason(me) == "", "it takes the truck's load")
	var money0 := GameState.money
	var sales0 := GameState.round_sales
	var dep0 := GameState.get_stat(1, Const.STAT_DEPOSITED)
	var cured0 := GameState.get_stat(1, Const.STAT_CURED)
	_sales.clear()
	_notes.clear()
	chute.interact(me)
	await wait_frames(3)
	check(_sales == expected, "four sales, top first: %s (want %s)" % [_sales, expected])
	check(GameState.money == money0 + total and GameState.round_sales == sales0 + total, "paid $%d in all (cash %d -> %d)" % [total, money0, GameState.money])
	check(GameState.get_stat(1, Const.STAT_DEPOSITED) == dep0 + total and GameState.get_stat(1, Const.STAT_CURED) == cured0 + cured_n,
			"STAT_DEPOSITED +%d, STAT_CURED +%d for the holder" % [total, cured_n])
	check(_notes.size() == 4 and _notes[0] == [&"brick", 3, true, expected[0], 1] and _notes[3] == [&"purple", 2, false, expected[3], 1],
			"the job hook heard each deposit %s" % [_notes])
	check(truck.get_load_count() == 0 and truck.holder_id == 1 and items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "the truck is empty and still in my hands; no bundle is left anywhere")
	check(truck.get_node(^"Visual/Load").get_child_count() == 0 and truck.get_status_text() == "0/4", "nothing drawn on the plate")

	step("the chute: an empty truck")
	check(not chute.can_interact(me) and chute.get_denied_reason(me) == HandTruck.REASON_EMPTY, "'%s'" % chute.get_denied_reason(me))
	toasts.clear()
	money0 = GameState.money
	chute.interact(me)
	await wait_frames(2)
	check(toast_seen(HandTruck.REASON_EMPTY) and GameState.money == money0, "pressing E anyway: the toast, nothing paid")


func _test_chute_quota(b: BalanceConfig) -> void:
	step("the chute: a sale that meets the payment ends the shift; the rest stay on the truck")
	_put_me(chute.global_position + chute.global_basis.z * 1.3, 0.0)
	items.server_drop_item(truck, chute.global_position + chute.global_basis.z * 2.2)
	truck.server_clear_load()
	check(items.server_give_item(truck, 1), "I bring the empty truck back to the chute")
	await wait_frames(1)
	for spec: Array in [[&"budget", 1], [&"purple", 1], [&"budget", 2]]:
		check(truck.server_load(_bundle(spec[0], spec[1], FLOOR_A), 1), "%s x%d on" % spec)
	var mult := GameState.get_sale_multiplier()
	var v_top := TurnInStation.compute_sale_value(b.get_seed(&"budget"), 2, mult)
	var v_mid := TurnInStation.compute_sale_value(b.get_seed(&"purple"), 1, mult)
	# Raise the payment so that the second sale meets it.
	var want_quota := GameState.round_sales + v_top + v_mid - 5
	var fraction := float(want_quota - GameState.quota) / float(GameState.quota)
	GameState.server_raise_quota(fraction)
	check(GameState.quota > GameState.round_sales + v_top and GameState.quota <= GameState.round_sales + v_top + v_mid,
			"the payment due is %d: the top bundle does not meet it, the second does (sold %d, +%d, +%d)" % [GameState.quota, GameState.round_sales, v_top, v_mid])
	b.end_round_on_quota_met = true
	_sales.clear()
	chute._server_interact(me)
	await wait_frames(3)
	check(_sales == [v_top, v_mid], "two sales %s" % [_sales])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "the shift is over: paid (%s)" % GameState.get_phase_name())
	check(truck.get_load() == [{"strain_id": &"budget", "amount": 1, "cured": false, "dry_left": 0.0}], "the third bundle stays on the truck %s" % [truck.get_load()])
	b.end_round_on_quota_met = false


# --- the raid ----------------------------------------------------------------------------------------------------------------

func _test_raid() -> void:
	step("the raid: a truck in sight loses its whole load")
	items.server_release_holder(1)
	await wait_frames(1)
	var eye_door := 0
	var in_sight := Vector3(-1.0, 0.0, 12.5)
	items.server_drop_item(truck, in_sight)
	for spec: Array in [[&"purple", 1], [&"golden", 2], [&"budget", 1]]:
		truck.server_load(_bundle(spec[0], spec[1], FLOOR_A), 0)
	check(truck.get_load_count() == 3, "three bundles on the truck, standing on the dock in the door's view")
	var loose := _bundle(&"budget", 1, Vector3(0.0, 0.0, 12.0))
	var loose_name := String(loose.name)
	await wait_frames(2)
	_took.clear()
	_swept.clear()
	var taken0 := Events.get_raid_taken()
	var out := Events.server_raid_sweep(eye_door)
	await wait_frames(2)
	var names: Array = out["taken"]
	var tn := String(truck.name)
	check(names.size() == 4 and names.has(loose_name) and names.has("%s/load1" % tn) and names.has("%s/load2" % tn) and names.has("%s/load3" % tn),
			"the sweep took the loose bundle and the three on the truck %s" % [names])
	check(_took.size() == 4 and _took.count(["%s/load2" % tn, 0]) == 1, "raid_took once per bundle %s" % [_took])
	check(_swept == [[0, 4]] and Events.get_raid_taken() == taken0 + 4, "raid_swept(0, 4), the tally +4")
	check(truck.get_load_count() == 0 and is_instance_valid(truck) and not truck.is_queued_for_deletion() and truck.global_position.is_equal_approx(in_sight),
			"the truck stays, empty, where it stood")
	check(items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "no bundle left")

	step("the raid: an empty truck, a truck behind a wall, a truck in the grow hall")
	_took.clear()
	out = Events.server_raid_sweep(eye_door)
	check((out["taken"] as Array).is_empty() and _took.is_empty(), "an empty truck in sight: nothing taken")
	truck.server_load(_bundle(&"purple", 1, FLOOR_A), 0)
	items.server_drop_item(truck, Vector3(2.0, 0.0, 4.0))
	await wait_frames(2)
	out = Events.server_raid_sweep(eye_door)
	check((out["taken"] as Array).is_empty() and truck.get_load_count() == 1, "from the roller door, behind the dock's north wall: kept")
	items.server_drop_item(truck, Vector3(16.0, 0.0, 3.0))
	await wait_frames(2)
	for i in 3:
		out = Events.server_raid_sweep(i)
		check((out["taken"] as Array).is_empty() and truck.get_load_count() == 1, "eye %d: the grow hall is out of sight" % i)
	items.server_drop_item(truck, Vector3(2.0, 0.0, 4.0))
	await wait_frames(2)
	out = Events.server_raid_sweep(2)
	check((out["taken"] as Array).size() == 1 and truck.get_load_count() == 0, "the middle eye sees the main room: taken")

	step("the raid: a truck in Bob's hands; he is written up once")
	for spec: Array in [[&"budget", 1], [&"budget", 1]]:
		truck.server_load(_bundle(spec[0], spec[1], FLOOR_A), 0)
	_put(bob, Vector3(0.0, 0.0, 13.0))
	await wait_frames(2)
	check(items.server_give_item(truck, BOB), "Bob holds the loaded truck on the dock")
	await wait_frames(2)
	_took.clear()
	_write_ups.clear()
	out = Events.server_raid_sweep(eye_door)
	await wait_frames(2)
	check((out["taken"] as Array).size() == 2 and out["holders"] == [BOB, BOB], "both bundles taken, the holder named for each %s" % [out["holders"]])
	check(_took.size() == 2 and _took[0][1] == BOB, "raid_took names Bob")
	check(_write_ups == [[BOB, Const.WRITE_UP_RAID]], "one write-up %s" % [_write_ups])
	check(truck.holder_id == BOB and truck.get_load_count() == 0, "he still holds the empty truck")
	items.server_release_holder(BOB)
	_put(bob, FAR_B)
	await wait_frames(1)

	step("the collector's unpaid take never touches the load")
	truck.server_load(_bundle(&"golden", 2, FLOOR_A), 0)
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		var p := room.get_station("GrowPlot%d" % i) as GrowPlot
		if p != null:
			p.server_reset()
	var took := Events.server_collect_unpaid()
	await wait_frames(2)
	check(took["what"] == Events.COLLECT_NOTHING and truck.get_load_count() == 1, "with only the truck's load on the floor plan he takes nothing (%s)" % [took])
	truck.server_clear_load()


# --- shift start ---------------------------------------------------------------------------------------------------------------

func _test_shift_start() -> void:
	step("NEXT SHIFT: the truck goes back to the spot with its load, out of the holder's hands")
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "the shift was paid (%s)" % GameState.get_phase_name())
	_put_me(FLOOR_A, 0.0)
	check(truck.holder_id == 1, "I still hold it")
	check(truck.server_load(_bundle(&"purple", 1, FLOOR_A), 1) and truck.server_load(_bundle(&"budget", 2, FLOOR_A, {"cured": true}), 1)
			and truck.get_load_count() == 3, "two more bundles on it: three")
	var load0 := truck.get_load()
	var name0 := String(truck.name)
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	await wait_frames(2)
	await _test_truck_at_spot("shift 2")
	check(truck != null and String(truck.name) == name0 and truck.get_load() == load0, "the same truck, its load kept %s" % [truck.get_load() if truck != null else []])
	check(items.get_held_by(1) == null and not me.is_carrying_heavy(), "my hands are empty")

	step("START OVER: the truck is despawned; the next shift's start brings a fresh one")
	GameState.server_reset_game()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and items.get_items_of_type(Const.ITEM_HAND_TRUCK).is_empty(), "WAITING: no truck")
	check(items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "and no bundles (the item manager's own reset)")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	await wait_frames(2)
	await _test_truck_at_spot("after START OVER")
	check(truck != null and String(truck.name) != name0 and truck.get_load().is_empty(), "a fresh, empty truck (%s)" % (truck.name if truck != null else "-"))


# --- helpers ---------------------------------------------------------------------------------------------------------------

func _bundle(strain: StringName, amount: int, at: Vector3, extra: Dictionary = {}, holder: int = 0) -> Product:
	var props := {"strain_id": strain, "amount": amount}
	props.merge(extra, true)
	return items.server_spawn_item(Const.ITEM_PRODUCT, props, at, holder) as Product


func _clear_products() -> void:
	for it in items.get_items_of_type(Const.ITEM_PRODUCT):
		items.server_despawn_item(it)


## Points the local body and head so that the camera looks at `target` (the Interactor's ray goes there).
func _aim_me_at(target_item: Node3D, target: Vector3) -> void:
	var from := target_item.global_position - target_item.global_basis.z * 1.4
	_put_me(Vector3(from.x, 0.0, from.z), 0.0)
	await wait_physics(1)
	var cam := me.camera.global_position
	var d := target - cam
	me.rotation.y = atan2(-d.x, -d.z)
	await wait_physics(1)
	cam = me.camera.global_position
	d = target - cam
	me.head.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())
	await wait_physics(2)


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
