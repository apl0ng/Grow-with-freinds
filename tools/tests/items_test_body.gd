extends Node
## Body of the interaction/carry test (Interactor, Item, ItemManager, item scenes). Launched by
## tools/tests/items_test.gd (a SceneTree main script cannot reference autoloads at compile time, this can).
## Runs as peer 1 on the default OfflineMultiplayerPeer (== server), so MultiplayerSpawner.spawn() works.
## Prints PASS/FAIL lines and quits with 0 (all passed) or 1.
##
## World setup, in order of preference:
##   a) scenes/world/world.tscn + world.server_spawn_player(1)   (the real thing)
##   b) minimal tree (World/Players + Items + ItemSpawner) + scenes/player/player.tscn named "1"
##      (automatic if world.tscn does not load; force it with:  -s res://tools/tests/items_test.gd -- --minimal)
## Everything happens in a private test area far away from the room geometry.

const AREA := Vector3(100.0, 0.0, 100.0)

var _passes := 0
var _fails := 0
var _mode := ""
var world: Node3D
var mgr: ItemManager
var player: Player
var interactor: Interactor
var cam: Camera3D
var prompts: Array = []           # [text, enabled] pairs emitted by the interactor
var holder_events: Array = []     # [item, old, new] from ItemManager.holder_changed
var added: Array[Item] = []
var removed: Array[Item] = []

func _ready() -> void:
	_run()

func quit(code: int) -> void:
	get_tree().quit(code)

func check(cond: bool, what: String) -> void:
	if cond:
		_passes += 1
		print("PASS: " + what)
	else:
		_fails += 1
		print("FAIL: " + what)

func near(a: Vector3, b: Vector3, eps: float = 0.01) -> bool:
	return a.distance_to(b) <= eps

func frames(n: int = 1) -> void:
	for i in n:
		await get_tree().physics_frame
		await get_tree().process_frame

func _run() -> void:
	await get_tree().process_frame
	if not await _setup_world():
		print("FAIL: could not build a test world")
		quit(1)
		return
	print("-- world mode: " + _mode)
	_build_test_area()
	await frames(3)
	await _test_spawning()
	await _test_scenes_and_sync_configs()
	await _test_give_drop_release()
	await _test_client_side_spawn_function()
	await _test_interactor()
	await _test_despawn()
	await _test_game_reset()
	print("items_test: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)

# --- Setup -------------------------------------------------------------------------------------------------------

func _setup_world() -> bool:
	# `-- --minimal` forces the fallback tree (to exercise it on purpose).
	var scene := null if Config.has_arg("minimal") else load("res://scenes/world/world.tscn") as PackedScene
	if scene != null and scene.can_instantiate():
		var w := scene.instantiate()
		if w is World:
			world = w as World
			world.name = "World"
			get_tree().root.add_child(world)
			Game.world = world as World
			mgr = world.get_node("Items") as ItemManager
			await frames(1)
			player = (world as World).server_spawn_player(Const.SERVER_PEER_ID)
			_mode = "real world.tscn + World.server_spawn_player(1)"
		elif w != null:
			w.free()
	if player == null:
		# Fallback b) minimal tree.
		if world != null:
			world.queue_free()
			Game.world = null
		world = Node3D.new()
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
		get_tree().root.add_child(world)
		mgr = items as ItemManager
		var pscene := load("res://scenes/player/player.tscn") as PackedScene
		if pscene == null:
			return false
		player = pscene.instantiate() as Player
		player.name = "1"
		player.peer_id = 1
		players.add_child(player)
		_mode = "minimal tree + player.tscn (Game.world is null: interact RPC path not covered)"
	if player == null or mgr == null:
		return false
	await frames(2)
	mgr.item_added.connect(func(i: Item) -> void: added.append(i))
	mgr.item_removed.connect(func(i: Item) -> void: removed.append(i))
	mgr.holder_changed.connect(func(i: Item, o: int, n: int) -> void: holder_events.append([i, o, n]))
	interactor = player.get_interactor()
	cam = player.get_node("%Camera") as Camera3D
	interactor.prompt_changed.connect(func(t: String, e: bool) -> void: prompts.append([t, e]))
	return true

## A private floor far away from the room, the player standing on it facing -Z.
func _build_test_area() -> void:
	var floor_body := _static_box(Vector3(20, 0.2, 20), AREA + Vector3(0, -0.1, 0), Const.LAYER_WORLD)
	floor_body.name = "TestFloor"
	player.global_position = AREA + Vector3(0, 0.02, 0)
	player.rotation = Vector3.ZERO
	player.velocity = Vector3.ZERO

func _static_box(size: Vector3, pos: Vector3, layer: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	world.add_child(body)
	body.global_position = pos
	return body

# --- Tests -------------------------------------------------------------------------------------------------------

var can: WateringCan
var packet: SeedPacket
var product: Product

func _test_spawning() -> void:
	var spawner := world.get_node("ItemSpawner") as MultiplayerSpawner
	check(spawner.spawn_function.is_valid(), "ItemSpawner.spawn_function set by ItemManager")
	check(ItemManager.find(player) == mgr, "ItemManager.find(player) resolves this world's manager")
	var base := mgr.get_items().size()
	var added_before := added.size()
	can = mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 3}, AREA + Vector3(3, 0, 3)) as WateringCan
	packet = mgr.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"purple"}, AREA + Vector3(4, 0, 3)) as SeedPacket
	product = mgr.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 2}, AREA + Vector3(5, 0, 3)) as Product
	check(can != null and packet != null and product != null, "server_spawn_item returns WateringCan / SeedPacket / Product")
	if can == null or packet == null or product == null:
		return
	check(can.get_parent() == mgr and packet.get_parent() == mgr, "items live under World/Items")
	check(mgr.get_items().size() == base + 3, "get_items() grew by 3 (%d -> %d)" % [base, mgr.get_items().size()])
	check(added.size() == added_before + 3, "item_added emitted once per spawned item")
	check(String(can.name).begins_with("item_") and can.name != packet.name and packet.name != product.name,
			"unique item names (%s, %s, %s)" % [can.name, packet.name, product.name])
	check(can.item_type == Const.ITEM_WATERING_CAN and packet.item_type == Const.ITEM_SEED_PACKET
			and product.item_type == Const.ITEM_PRODUCT, "item_type values match Const.ITEM_*")
	check(can.charges == 3 and can.get_capacity() == GameState.get_can_capacity(), "WateringCan charges=3, capacity from GameState")
	check(packet.strain_id == &"purple" and typeof(packet.strain_id) == TYPE_STRING_NAME, "SeedPacket.strain_id is StringName &\"purple\"")
	check(packet.get_seed() != null and packet.get_seed() == Config.balance.get_seed(&"purple"), "SeedPacket.get_seed() returns the purple SeedDef")
	check(product.strain_id == &"golden" and product.amount == 2, "Product strain/amount props applied")
	check(product.get_seed() == Config.balance.get_seed(&"golden"), "Product.get_seed()")
	check(product.get_display_name() == "Golden Kush x2", "Product display name '%s'" % product.get_display_name())
	check(packet.get_display_name() == "Purple Haze Seeds", "SeedPacket display name '%s'" % packet.get_display_name())
	check(near(can.global_position, AREA + Vector3(3, 0, 3)) and near(can.rest_position, AREA + Vector3(3, 0, 3)),
			"spawn position applied (node + synced rest_position)")
	check(not can.is_held() and can.holder_id == 0 and can.get_holder() == null, "floor item: holder 0, get_holder() null")
	check(can.get_collider() != null and can.get_collider().collision_layer == Const.LAYER_ITEM
			and can.get_collider().collision_mask == 0, "floor item collider on layer 4, mask 0")
	var full := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {}, AREA + Vector3(6, 0, 3)) as WateringCan
	check(full != null and full.charges == full.get_capacity(), "watering can without props spawns full")
	if full != null:
		mgr.server_despawn_item(full)
	check(mgr.server_spawn_item(&"banana", {}, AREA) == null, "unknown item type -> null (error expected above)")
	await frames(1)

func _test_scenes_and_sync_configs() -> void:
	if can == null:
		return
	var expected := {
		can: [^".:rest_position", ^".:rest_rotation", ^".:holder_id", ^".:charges"],
		packet: [^".:rest_position", ^".:rest_rotation", ^".:holder_id", ^".:strain_id"],
		product: [^".:rest_position", ^".:rest_rotation", ^".:holder_id", ^".:strain_id", ^".:amount"],
	}
	for item: Item in expected:
		var sync := item.get_node_or_null(^"Sync") as MultiplayerSynchronizer
		var ok := sync != null and sync.replication_config != null and sync.root_path == ^".."
		if ok:
			var cfg := sync.replication_config
			var props: Array = expected[item]
			ok = cfg.get_properties().size() == props.size()
			for p: NodePath in props:
				ok = ok and cfg.has_property(p) and cfg.property_get_spawn(p) \
						and cfg.property_get_replication_mode(p) == SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE
		check(ok, "%s: Sync config = %s (spawn, ON_CHANGE)" % [item.item_type, expected[item]])
		check(item.get_multiplayer_authority() == Const.SERVER_PEER_ID, "%s: server authority" % item.item_type)
	# Visual refresh through setters.
	var label := can.get_node("ChargeLabel") as Label3D
	check(label.text == "3/%d" % can.get_capacity(), "can label shows charges ('%s')" % label.text)
	var fill := can.get_node("Visual/Gauge/Fill") as MeshInstance3D
	check(fill.visible and is_equal_approx(fill.scale.y, 3.0 / float(can.get_capacity())), "can gauge fill = charges/capacity")
	can.charges = 0
	check(not fill.visible and label.text == "0/%d" % can.get_capacity(), "empty can: gauge hidden, label 0/N")
	can.charges = 3
	check(can.get_prompt(player) == "Pick up Watering Can (3/%d)" % can.get_capacity(), "can prompt '%s'" % can.get_prompt(player))
	var name_label := packet.get_node("Visual/Packet/NameLabel") as Label3D
	check(name_label.text == "Purple Haze", "packet label shows the strain name")
	var body := packet.get_node("Visual/Packet/Body") as MeshInstance3D
	var tint := body.material_override as StandardMaterial3D
	check(tint != null and tint.albedo_color.is_equal_approx(packet.get_seed().color), "packet tinted with the seed color")
	var shared := load("res://art/materials/toon_white.tres") as StandardMaterial3D
	check(tint != shared and not shared.albedo_color.is_equal_approx(packet.get_seed().color),
			"packet tint is a per-instance duplicate (library material untouched)")
	packet.strain_id = &"budget"
	check(tint.albedo_color.is_equal_approx(Config.balance.get_seed(&"budget").color) and name_label.text == "Budget Bud",
			"packet re-tints when strain_id changes")
	packet.strain_id = &"purple"
	var amount_label := product.get_node("AmountLabel") as Label3D
	var cluster := product.get_node("Visual/Cluster") as Node3D
	check(amount_label.text == "x2" and cluster.scale.x > 1.0, "product label x2 and bigger cluster")
	var bud := product.get_node("Visual/Cluster/Buds/Bud0") as MeshInstance3D
	check((bud.material_override as StandardMaterial3D).albedo_color.is_equal_approx(product.get_seed().color),
			"product buds tinted with the seed color")
	await frames(1)

func _test_give_drop_release() -> void:
	if can == null:
		return
	holder_events.clear()
	check(mgr.get_held_by(1) == null, "hands start empty")
	check(can.can_interact(player) and can.get_denied_reason(player) == "", "can_interact on a floor item with empty hands")
	check(mgr.server_give_item(can, 1), "server_give_item(can, 1) succeeds")
	check(mgr.get_held_by(1) == can and can.is_held() and can.holder_id == 1, "get_held_by(1) == can, is_held()")
	check(can.get_holder() == player, "get_holder() is the Player node")
	check(can.get_collider().collision_layer == 0, "held item collision layer 0")
	check(holder_events.size() == 1 and holder_events[0][1] == 0 and holder_events[0][2] == 1, "holder_changed(can, 0, 1) emitted")
	check(not (can.get_node("ChargeLabel") as Label3D).visible, "floating label hidden while held")
	await frames(2)
	var socket := player.get_item_socket()
	var expected_xf := socket.global_transform * can._get_hold_transform()
	check(near(can.global_position, expected_xf.origin, 0.02), "held can follows the hand socket (%s vs %s)" % [can.global_position, expected_xf.origin])
	check(can.visible, "held item visible (holder found)")
	check(not mgr.server_give_item(packet, 1), "giving a second item to a full-handed player fails")
	check(not packet.is_held() and mgr.get_held_by(1) == can, "second item stays on the floor")
	check(not packet.can_interact(player) and packet.get_denied_reason(player) == "Hands full", "denied reason 'Hands full'")
	check(not mgr.server_give_item(can, 2), "cannot give an item someone else holds")
	var other := Player.new() # bare Player of another peer (only peer_id is read)
	other.peer_id = 2
	check(can.get_denied_reason(other) == "Someone is holding this" and not can.can_interact(other), "held item not interactable for others")
	other.free()
	check(can.can_interact(player) and can.get_denied_reason(player) == "", "holder's repeated pickup request is a silent no-op (double press)")
	check(mgr.server_give_item(can, 1), "giving the same item to its holder is a no-op success")
	# Drop at a position.
	var drop_at := AREA + Vector3(1, 0, 2)
	mgr.server_drop_item(can, drop_at)
	check(can.holder_id == 0 and not can.is_held() and mgr.get_held_by(1) == null, "server_drop_item clears the holder")
	check(can.get_collider().collision_layer == Const.LAYER_ITEM, "collision restored after drop")
	check(near(can.global_position, drop_at) and can.rotation == Vector3.ZERO, "dropped at the given position, rotation zero")
	check(near(can.rest_position, drop_at), "rest_position (synced) updated by the drop")
	check(holder_events.size() == 2 and holder_events[1][2] == 0, "holder_changed(can, 1, 0) emitted")
	await frames(2)
	check(near(can.global_position, drop_at), "dropped item stays put (no longer follows)")
	# Server-side direct move of a floor item is mirrored into the synced rest values.
	can.global_position = AREA + Vector3(2, 0, 2)
	await frames(1)
	check(near(can.rest_position, AREA + Vector3(2, 0, 2)), "direct server move of a floor item mirrored into rest_position")
	# Spawn directly into hands (empty) -> held, no holder_changed; (full) -> floor.
	holder_events.clear()
	var in_hand := mgr.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"golden"}, Vector3.ZERO, 1) as SeedPacket
	check(in_hand != null and in_hand.holder_id == 1 and mgr.get_held_by(1) == in_hand, "spawn with holder_id=1 lands in hands")
	check(holder_events.is_empty(), "no holder_changed for the initial spawn value (effects guarded)")
	check(in_hand != null and in_hand.get_collider().collision_layer == 0, "spawned-in-hand item has collision off")
	var overflow := mgr.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, 1) as Product
	check(overflow != null and overflow.holder_id == 0, "spawn into full hands falls back to the floor (warning expected above)")
	if overflow != null:
		check(overflow.global_position.distance_to(player.global_position) < 1.2, "overflow item placed near the player")
		mgr.server_despawn_item(overflow)
	# request_drop (the drop key path): lands ~0.8 m in front of the player on the floor.
	player.rotation = Vector3.ZERO
	cam.rotation = Vector3.ZERO
	await frames(1)
	mgr.request_drop()
	check(in_hand.holder_id == 0, "request_drop() drops the held item (call_local RPC on the host)")
	var feet := player.global_position
	var flat := Vector2(in_hand.global_position.x - feet.x, in_hand.global_position.z - feet.z)
	check(absf(flat.length() - ItemManager.DROP_FORWARD) < 0.05 and in_hand.global_position.z < feet.z,
			"dropped %.2f m in front of the player (facing -Z)" % flat.length())
	check(absf(in_hand.global_position.y - AREA.y) < 0.02, "dropped onto the floor (y=%.3f)" % in_hand.global_position.y)
	# Wall right in front: the item must stay on the player's side.
	check(mgr.server_give_item(in_hand, 1), "pick the packet up again")
	var wall := _static_box(Vector3(4, 3, 0.2), feet + Vector3(0, 1.5, -0.5), Const.LAYER_WORLD)
	await frames(2)
	mgr.request_drop()
	check(in_hand.holder_id == 0 and in_hand.global_position.z > wall.global_position.z + 0.1,
			"drop in front of a wall stays out of the wall (z=%.2f, wall face %.2f)" % [in_hand.global_position.z, wall.global_position.z + 0.1])
	wall.free()
	# Release (disconnect path).
	check(mgr.server_give_item(product, 1), "give product")
	mgr.server_release_holder(1)
	check(product.holder_id == 0 and product.global_position.distance_to(player.global_position) < 1.0,
			"server_release_holder drops the product next to the player")
	mgr.server_release_holder(1) # nothing held: no-op
	mgr.server_despawn_item(in_hand)
	await frames(1)

func _test_client_side_spawn_function() -> void:
	# What a client runs for a spawn packet: plain data in, detached Item out (the spawner adds it).
	var data := {"name": "item_999", "type": "product", "props": {"strain_id": "purple", "amount": 3},
			"position": Vector3(1, 2, 3), "rotation": Vector3(0, 1, 0), "holder_id": 7}
	var node := mgr._spawn_item(data)
	var p := node as Product
	check(p != null and not p.is_inside_tree(), "_spawn_item(data) returns a detached Product")
	if p != null:
		check(p.name == &"item_999" and p.strain_id == &"purple" and p.amount == 3 and p.holder_id == 7,
				"spawn data applied (name/props/holder)")
		check(p.rest_position == Vector3(1, 2, 3) and p.rest_rotation == Vector3(0, 1, 0), "spawn data transform applied")
		check(p.get_collider().collision_layer == 0, "collision already off for a held spawn")
		p.free()
	var sanitized := mgr._sanitize_props({"strain_id": &"golden", "amount": 2})
	check(typeof(sanitized["strain_id"]) == TYPE_STRING and sanitized["amount"] == 2, "props sanitized to plain types")
	check(var_to_bytes(data).size() > 0 and bytes_to_var(var_to_bytes(data)) == data, "spawn data round-trips through Variant encoding")

func _test_interactor() -> void:
	if packet == null:
		return
	check(interactor != null and interactor.player == player, "Interactor found its Player")
	check(player.is_local(), "test player is local (peer 1)")
	# Put the packet on the floor 1.5 m ahead and look at it.
	mgr.server_drop_item(packet, AREA + Vector3(0, 0, -1.5))
	mgr.server_drop_item(can, AREA + Vector3(6, 0, 6))
	mgr.server_drop_item(product, AREA + Vector3(-6, 0, 6))
	player.global_position = AREA + Vector3(0, 0.02, 0)
	player.rotation = Vector3.ZERO
	await frames(2)
	_look_at(packet.global_position + Vector3(0, 0.15, 0))
	prompts.clear()
	await frames(3)
	check(interactor.current_target == packet, "raycast finds the floor packet (target=%s)" % interactor.current_target)
	check(interactor.prompt_text == "Pick up Purple Haze Seeds" and interactor.prompt_enabled,
			"prompt '%s' enabled=%s" % [interactor.prompt_text, interactor.prompt_enabled])
	check(prompts.size() >= 1 and prompts[-1] == ["Pick up Purple Haze Seeds", true], "prompt_changed emitted with the pickup text")
	var emitted := prompts.size()
	await frames(3)
	check(prompts.size() == emitted, "prompt_changed not re-emitted while unchanged")
	# Hands full -> denied reason, greyed.
	check(mgr.server_give_item(can, 1), "hold the can")
	await frames(2)
	check(interactor.prompt_text == "Hands full" and not interactor.prompt_enabled, "hands full -> ('Hands full', false)")
	# UI lock hides the prompt.
	Game.set_ui_lock(&"items_test", true)
	await frames(2)
	check(interactor.prompt_text == "" and not interactor.prompt_enabled and prompts[-1] == ["", false], "UI lock -> ('', false)")
	Game.set_ui_lock(&"items_test", false)
	await frames(2)
	check(interactor.prompt_text == "Hands full", "prompt comes back after unlock")
	# try_drop -> request_drop RPC.
	interactor.try_drop()
	check(can.holder_id == 0, "try_drop() drops the held can")
	await frames(2)
	check(interactor.prompt_text == "Pick up Purple Haze Seeds" and interactor.prompt_enabled, "prompt re-enabled with empty hands")
	# Real input path: E / Q key events through the viewport (with the real HUD in the tree in world mode).
	_press_key(KEY_E)
	await frames(2)
	if Game.world != null:
		check(packet.holder_id == 1, "pressing E picks the packet up (_unhandled_input -> try_interact)")
	else:
		# Minimal tree: Interactable's server RPC resolves players through Game.world (null here).
		packet._server_interact(player)
	_press_key(KEY_Q)
	await frames(2)
	check(packet.holder_id == 0, "pressing Q drops it (_unhandled_input -> try_drop)")
	mgr.server_drop_item(packet, AREA + Vector3(0, 0, -1.5))
	await frames(2)
	Game.set_ui_lock(&"items_test", true)
	_press_key(KEY_E)
	await frames(2)
	check(packet.holder_id == 0, "E is ignored while the UI is locked")
	Game.set_ui_lock(&"items_test", false)
	await frames(2)
	# try_interact -> Interactable.interact -> server RPC -> pickup.
	if Game.world != null:
		interactor.try_interact()
		check(packet.holder_id == 1 and mgr.get_held_by(1) == packet, "try_interact() picks the packet up (full RPC path)")
	else:
		packet._server_interact(player)
		check(packet.holder_id == 1, "_server_interact picks the packet up (minimal-tree mode)")
	await frames(2)
	check(interactor.current_target != packet, "held packet is no longer a ray target (collision off)")
	# Wall between camera and item blocks the ray.
	mgr.server_drop_item(packet, AREA + Vector3(0, 0, -1.5))
	await frames(2)
	check(interactor.current_target == packet, "packet targeted again after dropping it back")
	var wall := _static_box(Vector3(3, 3, 0.1), AREA + Vector3(0, 1.5, -0.7), Const.LAYER_WORLD)
	await frames(3)
	check(interactor.current_target == null and interactor.prompt_text == "", "a wall in between blocks the ray")
	wall.free()
	await frames(2)
	# Look away -> no target, target_changed(null).
	var changes: Array = []
	interactor.target_changed.connect(func(t: Interactable) -> void: changes.append(t))
	_look_at(cam.global_position + Vector3(0, 1, -0.2))
	await frames(2)
	check(interactor.current_target == null and changes.size() == 1 and changes[0] == null, "looking away -> target_changed(null)")
	# A station-like Interactable: the ray hits a StaticBody child (layer 1|3) and walks up to it.
	var station := Interactable.new()
	station.name = "TestStation"
	station.prompt_verb = "Do the thing"
	world.add_child(station)
	station.global_position = AREA + Vector3(2, 0, -1)
	var body := StaticBody3D.new()
	body.collision_layer = Const.LAYER_WORLD | Const.LAYER_INTERACTABLE
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 1.0, 0.8)
	cs.shape = box
	cs.position = Vector3(0, 0.5, 0)
	body.add_child(cs)
	station.add_child(body)
	_look_at(station.global_position + Vector3(0, 0.6, 0))
	await frames(3)
	check(interactor.current_target == station and interactor.prompt_text == "Do the thing" and interactor.prompt_enabled,
			"station found by walking up from its collider (prompt '%s')" % interactor.prompt_text)
	# Target freed under the interactor.
	station.queue_free()
	await frames(2)
	check(interactor.current_target == null and interactor.prompt_text == "", "freed target cleared safely")
	interactor.try_interact() # must not crash with no target
	# Area3D colliders count too.
	var area_station := Interactable.new()
	world.add_child(area_station)
	area_station.global_position = AREA + Vector3(-2, 0, -1)
	var area := Area3D.new()
	area.collision_layer = Const.LAYER_INTERACTABLE
	area.collision_mask = 0
	var acs := CollisionShape3D.new()
	var abox := BoxShape3D.new()
	abox.size = Vector3(0.8, 1.0, 0.8)
	acs.shape = abox
	acs.position = Vector3(0, 0.5, 0)
	area.add_child(acs)
	area_station.add_child(area)
	_look_at(area_station.global_position + Vector3(0, 0.6, 0))
	await frames(3)
	check(interactor.current_target == area_station, "Area3D collider on layer 3 is hit (collide_with_areas)")
	area_station.queue_free()
	cam.rotation = Vector3.ZERO
	await frames(1)

func _test_despawn() -> void:
	if product == null:
		return
	var n := mgr.get_items().size()
	var removed_before := removed.size()
	mgr.server_give_item(product, 1) # held items can be despawned too (e.g. sold)
	mgr.server_despawn_item(product)
	check(mgr.get_items().size() == n - 1 and not mgr.get_items().has(product), "despawned item leaves get_items() immediately")
	check(mgr.get_held_by(1) == null, "despawned held item no longer counts as held")
	await frames(1)
	check(not is_instance_valid(product), "despawned item freed after a frame")
	check(removed.size() == removed_before + 1, "item_removed emitted")
	var n2 := mgr.get_items().size()
	mgr.server_despawn_all()
	check(mgr.get_items().is_empty(), "server_despawn_all() clears items (%d before)" % n2)
	await frames(1)

## GameState.game_reset (RETRY): the host despawns every seed packet + product (held or loose), cans stay.
func _test_game_reset() -> void:
	if not GameState.has_signal(&"game_reset"):
		print("SKIP: GameState has no game_reset signal")
		return
	var loose_can := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, AREA + Vector3(2, 0, -2))
	var held_can := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, AREA, 1)
	mgr.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"}, AREA + Vector3(3, 0, -2))
	mgr.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"purple", "amount": 2}, AREA + Vector3(4, 0, -2))
	var held_product := mgr.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 1}, AREA + Vector3(5, 0, -2))
	await frames(1)
	var was_host := Net.is_host
	# Not the host (e.g. a client receiving the reset): nothing happens.
	Net.is_host = false
	GameState.emit_signal(&"game_reset")
	await frames(1)
	check(mgr.get_items().size() == 5, "game_reset on a non-host peer leaves items alone")
	# Host: packets + products (held or loose) go, cans stay.
	mgr.server_drop_item(held_can, AREA + Vector3(1, 0, -2))
	check(mgr.server_give_item(held_product, 1), "player holds a product before the reset")
	Net.is_host = true
	GameState.emit_signal(&"game_reset")
	Net.is_host = was_host
	await frames(1)
	check(mgr.get_items_of_type(Const.ITEM_SEED_PACKET).is_empty() and mgr.get_items_of_type(Const.ITEM_PRODUCT).is_empty(),
			"game_reset (host): every seed packet and product despawned")
	check(not is_instance_valid(held_product) and mgr.get_held_by(1) == null, "game_reset: held product gone too")
	check(is_instance_valid(loose_can) and is_instance_valid(held_can) and mgr.get_items_of_type(Const.ITEM_WATERING_CAN).size() == 2,
			"game_reset: watering cans untouched by ItemManager")
	await frames(4) # the Well's own handler resets cans two frames later (world mode)
	check(is_instance_valid(loose_can) and is_instance_valid(held_can), "cans still alive after the Well's reset handler")
	mgr.server_despawn_all()
	await frames(1)

func _press_key(key: Key) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		ev.keycode = key
		ev.pressed = pressed
		Input.parse_input_event(ev)

func _look_at(target: Vector3) -> void:
	cam.look_at(target, Vector3.UP)
