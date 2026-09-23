extends Node
## Body of the items replication test (see items_net_test.gd). Verifies over ENet:
## spawn data + synchronizer spawn state (initial sync and late join), ON_CHANGE deltas through the setters
## (holder, charges, strain, rest transform), client -> server drop request, despawn replication.

const PORT_MIN := 27100
const WAIT_FRAMES := 240

var _passes := 0
var _fails := 0
var _port := 0
var server: Dictionary
var client1: Dictionary
var client2: Dictionary

func _ready() -> void:
	_run()

func check(cond: bool, what: String) -> void:
	if cond:
		_passes += 1
		print("PASS: " + what)
	else:
		_fails += 1
		print("FAIL: " + what)

func frames(n: int = 1) -> void:
	for i in n:
		await get_tree().process_frame

## Waits (up to WAIT_FRAMES) until cond.call() is true. Returns the final value.
func wait_until(cond: Callable) -> bool:
	for i in WAIT_FRAMES:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()

func _run() -> void:
	await get_tree().process_frame
	_port = PORT_MIN + randi() % 800
	server = _make_branch("Server")
	var speer := ENetMultiplayerPeer.new()
	var err := speer.create_server(_port, 4)
	check(err == OK, "ENet server listening on %d" % _port)
	if err != OK:
		_finish()
		return
	(server.mp as SceneMultiplayer).multiplayer_peer = speer
	var s_items: ItemManager = server.items

	# Items that exist before anyone joins (like the well's starting cans).
	var can := s_items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, Vector3(1, 0, 1)) as WateringCan
	var packet := s_items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"purple"}, Vector3(2, 0, 2)) as SeedPacket
	check(can != null and packet != null, "server spawned a can and a packet before any client joined")

	client1 = await _connect_client("Client1")
	var cid1: int = client1.id
	check(cid1 > 1, "client1 connected (peer %d)" % cid1)
	var c1_items: ItemManager = client1.items
	var holder_events: Array = []
	c1_items.holder_changed.connect(func(i: Item, o: int, n: int) -> void: holder_events.append([String(i.name), o, n]))

	check(await wait_until(func() -> bool: return c1_items.get_items().size() == 2), "client1 received both existing items")
	var c1_can := c1_items.get_node_or_null(NodePath(String(can.name))) as WateringCan
	var c1_packet := c1_items.get_node_or_null(NodePath(String(packet.name))) as SeedPacket
	check(c1_can != null and c1_packet != null, "client items have the server's names and classes")
	if c1_can == null or c1_packet == null:
		_finish()
		return
	check(c1_can.charges == 2 and c1_can.position == Vector3(1, 0, 1), "client can: charges 2 at (1,0,1)")
	check(c1_packet.strain_id == &"purple" and typeof(c1_packet.strain_id) == TYPE_STRING_NAME, "client packet strain &\"purple\"")
	check(not c1_can.is_multiplayer_authority() and can.is_multiplayer_authority(), "server owns items, client does not")

	# Spawn while connected, directly into client1's hands.
	var product := s_items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 3}, Vector3(3, 0, 3), cid1) as Product
	check(product != null and product.holder_id == cid1, "server spawned a product in client1's hands")
	check(await wait_until(func() -> bool: return c1_items.get_node_or_null(NodePath(String(product.name))) != null),
			"client1 received the new product")
	var c1_product := c1_items.get_node(NodePath(String(product.name))) as Product
	check(c1_product.amount == 3 and c1_product.strain_id == &"golden" and c1_product.holder_id == cid1,
			"client product: golden x3 held by client1")
	check(c1_items.get_held_by(cid1) == c1_product and c1_product.get_collider().collision_layer == 0,
			"client sees its own held item (collision off)")
	check(holder_events.is_empty(), "no holder_changed on the client for the initial spawn value")

	# ON_CHANGE deltas through setters.
	can.charges = 0
	packet.strain_id = &"golden"
	check(await wait_until(func() -> bool: return c1_can.charges == 0 and c1_packet.strain_id == &"golden"),
			"charges / strain_id changes replicate")
	check((c1_can.get_node("ChargeLabel") as Label3D).text == "0/%d" % c1_can.get_capacity(), "client can label refreshed by the setter")
	check((c1_packet.get_node("Visual/Packet/NameLabel") as Label3D).text == "Golden Kush", "client packet label refreshed")
	s_items.server_drop_item(can, Vector3(4, 0, 4))
	check(await wait_until(func() -> bool: return c1_can.position == Vector3(4, 0, 4)), "server_drop_item position replicates")
	packet.global_position = Vector3(5, 0, 5) # direct write on the server, mirrored into rest_position
	check(await wait_until(func() -> bool: return c1_packet.position == Vector3(5, 0, 5)), "direct server move of a floor item replicates")
	check(s_items.server_give_item(can, cid1) == false, "server refuses a second item for client1")

	# Bandwidth: idle floor items and a held item following a MOVING hand send no deltas (rest_* design).
	var deltas := {"can": 0, "product": 0}
	(c1_can.get_node("Sync") as MultiplayerSynchronizer).delta_synchronized.connect(func() -> void: deltas.can += 1)
	(c1_product.get_node("Sync") as MultiplayerSynchronizer).delta_synchronized.connect(func() -> void: deltas.product += 1)
	var holder := _add_server_player(cid1, Vector3(8, 0, 8))
	check(holder != null and product.get_holder() == holder, "server-side Player for client1 found as the product's holder")
	for i in 30:
		holder.net_position = Vector3(8 + i * 0.1, 0, 8) # remote player smoothing moves the node (and its hand socket)
		await frames(1)
	check(product.visible and product.global_position.distance_to(holder.get_item_socket().global_position) < 0.5,
			"server: held product follows the moving holder's hand")
	check(product.rest_position == Vector3(3, 0, 3), "held item's synced rest_position untouched while following")
	check(deltas.can == 0 and deltas.product == 0, "no deltas for an idle floor item or a held item following a hand (%s)" % deltas)

	# Client -> server drop request (server now has the Player: dropped in front of it, on its floor height).
	c1_items.request_drop()
	check(await wait_until(func() -> bool: return product.holder_id == 0), "client1 request_drop() reached the server")
	check(product.global_position.distance_to(holder.global_position) < 1.0, "dropped next to the holder on the server")
	check(await wait_until(func() -> bool: return c1_product.holder_id == 0 and c1_product.position == product.position),
			"client1 sees the product dropped where the server put it")
	check(deltas.product >= 1, "the drop itself arrived as a delta")
	check(await wait_until(func() -> bool: return holder_events.size() >= 1), "client holder_changed fired for the drop")
	if holder_events.size() >= 1:
		check(holder_events[-1] == [String(product.name), cid1, 0], "holder_changed args %s" % [holder_events[-1]])
	check(c1_product.get_collider().collision_layer == Const.LAYER_ITEM, "client collision restored after drop")

	# Client-side server API refuses to run.
	print("(expected error next: server_give_item on a client)")
	check(c1_items.server_give_item(c1_packet, cid1) == false and c1_packet.holder_id == 0, "server_* API refuses on clients")

	# Pick-up by client1 (server gives), then a late joiner must see the CURRENT state, not the spawn data.
	check(s_items.server_give_item(packet, cid1), "server gives the packet to client1")
	check(await wait_until(func() -> bool: return c1_packet.holder_id == cid1), "client1 sees itself holding the packet")
	client2 = await _connect_client("Client2")
	var cid2: int = client2.id
	check(cid2 > 1 and cid2 != cid1, "client2 connected late (peer %d)" % cid2)
	var c2_items: ItemManager = client2.items
	check(await wait_until(func() -> bool: return c2_items.get_items().size() == 3), "late joiner received all 3 items")
	var c2_can := c2_items.get_node_or_null(NodePath(String(can.name))) as WateringCan
	var c2_packet := c2_items.get_node_or_null(NodePath(String(packet.name))) as SeedPacket
	var c2_product := c2_items.get_node_or_null(NodePath(String(product.name))) as Product
	check(c2_can != null and c2_packet != null and c2_product != null, "late joiner has the same item names")
	if c2_can != null and c2_packet != null and c2_product != null:
		check(c2_can.charges == 0 and c2_can.position == Vector3(4, 0, 4), "late joiner: can has CURRENT charges 0 at (4,0,4) (spawn data said 2 at (1,0,1))")
		check(c2_packet.holder_id == cid1 and c2_packet.strain_id == &"golden", "late joiner: packet held by client1, strain golden")
		check(c2_packet.get_collider().collision_layer == 0, "late joiner: held packet has collision off")
		check(c2_product.holder_id == 0 and c2_product.position == product.position, "late joiner: product on the floor (spawn data said held)")
		check(c2_product.get_collider().collision_layer == Const.LAYER_ITEM, "late joiner: floor product collidable")
		check(not c2_packet.visible, "held item hidden while its holder's Player is not on this peer")

	# Release (disconnect path) and despawn.
	s_items.server_release_holder(cid1)
	check(await wait_until(func() -> bool: return c1_packet.holder_id == 0 and c2_packet != null and c2_packet.holder_id == 0),
			"server_release_holder replicates to both clients")
	var can_path := NodePath(String(can.name))
	s_items.server_despawn_item(can)
	check(await wait_until(func() -> bool: return c1_items.get_node_or_null(can_path) == null and c2_items.get_node_or_null(can_path) == null),
			"despawn replicates to both clients")
	check(c1_items.get_items().size() == 2 and c2_items.get_items().size() == 2, "both clients left with 2 items")
	_finish()

func _finish() -> void:
	# Same order as Net.leave(): offline peer first (no traffic through a closed ENet peer), then close, then free.
	for b: Dictionary in [client2, client1, server]:
		if b.has("mp"):
			var mp := b.mp as SceneMultiplayer
			var peer := mp.multiplayer_peer
			mp.multiplayer_peer = OfflineMultiplayerPeer.new()
			if peer is ENetMultiplayerPeer:
				(peer as ENetMultiplayerPeer).close()
			(b.root as Node).queue_free()
	print("items_net_test: %d passed, %d failed" % [_passes, _fails])
	await get_tree().process_frame
	get_tree().quit(1 if _fails > 0 else 0)

func _connect_client(branch_name: String) -> Dictionary:
	var b := _make_branch(branch_name)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client("127.0.0.1", _port)
	if err != OK:
		print("FAIL: create_client error %s" % error_string(err))
		return b
	var mp := b.mp as SceneMultiplayer
	mp.multiplayer_peer = peer
	await wait_until(func() -> bool: return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	await frames(5)
	b["id"] = mp.get_unique_id()
	return b

## A Player for `peer_id` in the SERVER branch only (remote from the server's point of view). The client
## branches have no players, so items held by this peer stay hidden there (tested below).
func _add_server_player(peer_id: int, pos: Vector3) -> Player:
	var scene := load("res://scenes/player/player.tscn") as PackedScene
	if scene == null:
		return null
	var p := scene.instantiate() as Player
	p.name = str(peer_id)
	p.peer_id = peer_id
	p.position = pos
	p.net_position = pos
	(server.world as Node).get_node("Players").add_child(p)
	return p

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
