extends "res://tools/tests/smoke_base.gd"
## M10 physics replication test (physics agent), ONE process over a real ENet connection: /root/Server, /root/Client1
## and a LATE /root/Client2 each with their own SceneMultiplayer and a minimal World (Players + Items + ItemSpawner),
## like items_net_test. Checks that a throw is one synced delta (flight values + release), that every peer integrates
## the same arc, that a peer joining MID-FLIGHT gets the flight through the spawn state (flying, collision off) and
## that everyone snaps to the same rest position when the server ends the flight; a manual placement mid-flight
## (server_drop_item) ends it everywhere too.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/physics_net_body.gd

const PORT_MIN := 27900

var _port := 0
var server: Dictionary
var client1: Dictionary
var client2: Dictionary


func _run() -> void:
	_label = "physics_net"
	await get_tree().process_frame
	_port = PORT_MIN + randi() % 90
	server = _make_branch("Server")
	var speer := ENetMultiplayerPeer.new()
	var err := speer.create_server(_port, 4)
	check(err == OK, "ENet server listening on %d" % _port)
	if err != OK:
		_finish_net(); return
	(server.mp as SceneMultiplayer).multiplayer_peer = speer
	var s_items: ItemManager = server.items
	# A floor under the flights (the branches share the root's physics world).
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = Const.LAYER_WORLD
	floor_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 0.2, 40.0)
	shape.shape = box
	floor_body.add_child(shape)
	(server.world as Node3D).add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -0.1, 0.0)

	var can := s_items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, Vector3(1.0, 0.0, 1.0)) as WateringCan
	check(can != null, "server spawned a can at rest")
	if can == null:
		_finish_net(); return

	step("client1 joins, sees the can at rest")
	client1 = await _connect_client("Client1")
	var c1_items: ItemManager = client1.items
	await wait_until(func() -> bool: return c1_items.get_node_or_null(NodePath(String(can.name))) != null, 5.0, "client1 received the can")
	var c1_can := c1_items.get_node_or_null(NodePath(String(can.name))) as WateringCan
	if c1_can == null:
		_finish_net(); return
	check(not c1_can.is_flying() and c1_can.position == Vector3(1.0, 0.0, 1.0) and c1_can.get_collider().collision_layer == Const.LAYER_ITEM,
			"client1: at rest, collidable, serial 0")
	var deltas := {"n": 0}
	(c1_can.get_node("Sync") as MultiplayerSynchronizer).delta_synchronized.connect(func() -> void: deltas.n += 1)
	var c1_flights: Array = []
	c1_can.flight_changed.connect(func(f: bool) -> void: c1_flights.append(f))

	step("server throws (high arc), client1 flies the same arc")
	var origin := Vector3(0.0, 1.2, 0.0)
	var vel := Vector3(0.0, 9.0, 1.5)
	check(s_items.server_throw_item(can, origin, vel, 0), "server_throw_item (thrower 0: nobody)")
	var serial := can.flight_serial
	await wait_until(func() -> bool: return c1_can.is_flying(), 5.0, "client1 sees the flight")
	check(c1_can.flight_serial == serial and c1_can.flight_origin == origin and c1_can.flight_velocity == vel, "client1: same serial, origin, velocity")
	check(c1_can.holder_id == 0 and c1_can.get_collider().collision_layer == 0 and c1_can.visible, "client1: released, collision off, visible")
	await wait_frames(6)
	var s_p := can.global_position
	var c_p := c1_can.global_position
	check(c_p.is_finite() and c_p.y > origin.y and c_p.z > origin.z, "client1: the can rises along the arc %s" % c_p)
	check(s_p.distance_to(c_p) < 0.6, "server and client1 within 0.6 m of each other mid-flight (%.2f m: independent clocks)" % s_p.distance_to(c_p))

	step("client2 joins mid-flight")
	client2 = await _connect_client("Client2")
	var c2_items: ItemManager = client2.items
	await wait_until(func() -> bool: return c2_items.get_node_or_null(NodePath(String(can.name))) != null, 5.0, "client2 received the can")
	var c2_can := c2_items.get_node_or_null(NodePath(String(can.name))) as WateringCan
	if c2_can == null:
		_finish_net(); return
	check(can.is_flying(), "the can is still in the air on the server when client2 got it (t=%.2f s)" % can.get_flight_time())
	check(c2_can.is_flying() and c2_can.flight_serial == serial, "late joiner: flying from the spawn state (serial %d)" % c2_can.flight_serial)
	check(c2_can.holder_id == 0 and c2_can.get_collider().collision_layer == 0 and c2_can.position.is_finite(), "late joiner: released, collision off, finite position")
	check(c2_can.can_interact(null) == false and c2_can.get_denied_reason(null) == Item.REASON_IN_THE_AIR, "late joiner: pickup refused ('%s')" % c2_can.get_denied_reason(null))

	step("landing snaps everyone to the same rest position")
	await wait_until(func() -> bool: return not can.is_flying(), 4.0, "server ended the flight")
	await wait_until(func() -> bool: return not c1_can.is_flying() and not c2_can.is_flying(), 5.0, "both clients landed")
	check(can.position.is_finite() and absf(can.position.y) < 0.05 and can.position.z > 2.0, "server rest on the floor down the arc %s" % can.position)
	check(c1_can.position == can.position and c2_can.position == can.position, "identical rest positions on every peer")
	check(c1_can.rest_position == can.rest_position and c2_can.rest_position == can.rest_position, "identical synced rest_position")
	check(c1_can.get_collider().collision_layer == Const.LAYER_ITEM and c2_can.get_collider().collision_layer == Const.LAYER_ITEM, "collision back on both clients")
	check(c1_can.rotation == Vector3.ZERO and c2_can.rotation == Vector3.ZERO, "tumble reset on landing")
	check(c1_flights == [true, false], "client1 flight_changed(true), (false) %s" % [c1_flights])
	check(deltas.n >= 2 and deltas.n <= 3, "the whole flight cost %d deltas (throw + landing), no per-frame positions" % deltas.n)

	step("a manual placement mid-flight ends the flight everywhere")
	check(s_items.server_throw_item(can, origin, vel, 0), "throw again")
	await wait_until(func() -> bool: return c1_can.is_flying(), 5.0, "client1 flying again")
	s_items.server_drop_item(can, Vector3(3.0, 0.0, 3.0))
	check(not can.is_flying() and can.position == Vector3(3.0, 0.0, 3.0), "server: placed, flight over")
	await wait_until(func() -> bool: return not c1_can.is_flying() and not c2_can.is_flying(), 5.0, "clients see the flight end")
	check(c1_can.position == Vector3(3.0, 0.0, 3.0) and c2_can.position == Vector3(3.0, 0.0, 3.0), "clients at the placed spot")

	step("a bad throw is refused")
	check(not s_items.server_throw_item(can, Vector3(NAN, 1.0, 0.0), vel, 0), "NaN origin refused")
	check(not s_items.server_throw_item(can, origin, Vector3(INF, 0.0, 0.0), 0), "infinite velocity refused")
	check(not can.is_flying(), "can still at rest")
	print("(expected error next: server_throw_item called on a client)")
	check(not c1_items.server_throw_item(c1_can, origin, vel, 0) and not c1_can.is_flying(), "server_throw_item refuses on a client")
	_finish_net()


func _finish_net() -> void:
	Sfx.stop_all()
	# Same order as Net.leave(): offline peer first (no traffic through a closed ENet peer), then close, then free.
	for b: Dictionary in [client2, client1, server]:
		if b != null and b.has("mp"):
			var mp := b.mp as SceneMultiplayer
			var peer := mp.multiplayer_peer
			mp.multiplayer_peer = OfflineMultiplayerPeer.new()
			if peer is ENetMultiplayerPeer:
				(peer as ENetMultiplayerPeer).close()
			(b.root as Node).queue_free()
	await wait_frames(5)
	finish()


func _connect_client(branch_name: String) -> Dictionary:
	var b := _make_branch(branch_name)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client("127.0.0.1", _port)
	if err != OK:
		check(false, "create_client error %s" % error_string(err))
		return b
	var mp := b.mp as SceneMultiplayer
	mp.multiplayer_peer = peer
	await wait_until(func() -> bool: return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, 10.0, "%s connected" % branch_name)
	await wait_frames(3)
	b["id"] = mp.get_unique_id()
	return b


## /root/<name> with its own SceneMultiplayer and a minimal World (Players, Items + ItemManager, ItemSpawner).
func _make_branch(branch_name: String) -> Dictionary:
	var branch := Node.new()
	branch.name = branch_name
	get_tree().root.add_child(branch)
	var mp := SceneMultiplayer.new()
	get_tree().set_multiplayer(mp, branch.get_path())
	var world := Node3D.new()
	world.name = "World"
	var players := Node3D.new()
	players.name = "Players"
	world.add_child(players)
	var items := Node3D.new()
	items.name = "Items"
	items.set_script(load("res://scripts/items/item_manager.gd"))
	world.add_child(items)
	var spawner := MultiplayerSpawner.new()
	spawner.name = "ItemSpawner"
	world.add_child(spawner)
	spawner.spawn_path = NodePath("../Items")
	branch.add_child(world)
	return {"root": branch, "mp": mp, "world": world, "items": items as ItemManager, "id": 0}
