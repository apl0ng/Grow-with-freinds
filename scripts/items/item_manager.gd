class_name ItemManager
extends Node3D
## World/Items container. Server-only spawn/despawn/give/drop API used by stations and the shop, plus
## read-only lookups for every peer. Uses the sibling MultiplayerSpawner (World/ItemSpawner, spawn_path = this
## node); its spawn_function is set here, so every peer builds items from the same plain spawn data:
##   {"name": "item_12", "type": "watering_can", "props": {"charges": 4}, "position": Vector3,
##    "rotation": Vector3, "holder_id": 0}
## The spawner re-sends the ORIGINAL data to late joiners; the current values then arrive through each item's
## MultiplayerSynchronizer spawn state (applied before _ready), so late joiners always see the live state.
##
## Spawned items are never reparented. Holding = Item.holder_id (synced); the item follows the hand itself.

## Every peer: an item entered World/Items and its synced spawn state is applied.
signal item_added(item: Item)
## Every peer: an item is leaving World/Items (despawned, or the world is being freed).
signal item_removed(item: Item)
## Every peer: an item changed hands after it spawned (0 = on the floor). Items spawned directly in a player's
## hands report their holder through item_added instead.
signal holder_changed(item: Item, old_holder: int, new_holder: int)

## Group this node joins so it can be found without Game.world (tests, tools).
const GROUP: StringName = &"item_manager"
## Distance in front of the player where a dropped item lands (metres).
const DROP_FORWARD: float = 0.8
## Minimum gap kept between a dropped item and a wall in front of the player (metres).
const DROP_WALL_MARGIN: float = 0.3
## Height above the feet used for the "is there a wall in front of me" check (metres).
const DROP_CHEST_HEIGHT: float = 1.0
## The floor probe starts this far above the feet (so drops can land on low props; station tops are refused) ...
const FLOOR_PROBE_UP: float = 0.6
## ... and searches this far below them.
const FLOOR_PROBE_DOWN: float = 3.0
## A dropped item needs a free sphere of this radius (metres) just above its landing point.
const DROP_CLEARANCE_RADIUS: float = 0.15
## A blocked drop spot is retried this many times, walking back towards the player's feet.
const DROP_BACKOFF_STEPS: int = 8

var spawner: MultiplayerSpawner = null

var _next_id: int = 1
var _scenes: Dictionary = {}   # StringName item type -> PackedScene (loaded lazily)

func _enter_tree() -> void:
	add_to_group(GROUP)

func _ready() -> void:
	# Full game reset (RETRY): GameState.game_reset is emitted on every peer; only the host acts on it.
	if GameState.has_signal(&"game_reset") and not GameState.is_connected(&"game_reset", _on_game_reset):
		GameState.connect(&"game_reset", _on_game_reset)
	spawner = _find_spawner()
	if spawner == null:
		push_error("ItemManager: no MultiplayerSpawner with spawn_path pointing at %s" % get_path())
		return
	spawner.spawn_function = _spawn_item

## Scene path for an item type ("" if unknown).
static func get_scene_path(item_type: StringName) -> String:
	if item_type == Const.ITEM_WATERING_CAN:
		return "res://scenes/items/watering_can.tscn"
	if item_type == Const.ITEM_SEED_PACKET:
		return "res://scenes/items/seed_packet.tscn"
	if item_type == Const.ITEM_PRODUCT:
		return "res://scenes/items/product.tscn"
	return ""

## The ItemManager for `from`'s world: the nearest ancestor with an "Items" ItemManager child, else
## Game.world.items, else the first node in GROUP. Returns null if there is no world.
static func find(from: Node) -> ItemManager:
	var n := from
	while n != null:
		var m := n.get_node_or_null(^"Items") as ItemManager
		if m != null:
			return m
		n = n.get_parent()
	if Game.world != null and is_instance_valid(Game.world) and Game.world.items != null:
		return Game.world.items
	if from != null and from.is_inside_tree():
		return from.get_tree().get_first_node_in_group(GROUP) as ItemManager
	return null

# --- Server API ------------------------------------------------------------------------------------------------

## SERVER ONLY. Spawns an item and returns it. `props` are type-specific initial values:
##   watering_can {"charges": int} (default: full)   seed_packet {"strain_id": StringName}
##   product {"strain_id": StringName, "amount": int}
## If holder_id != 0 the item spawns directly in that player's hands; if their hands are already full it is
## placed on the floor in front of them instead (with a warning) - stations should check first.
func server_spawn_item(item_type: StringName, props: Dictionary = {}, position: Vector3 = Vector3.ZERO, holder_id: int = 0) -> Item:
	if not multiplayer.is_server():
		push_error("ItemManager.server_spawn_item called on a client")
		return null
	if spawner == null or not spawner.is_inside_tree():
		push_error("ItemManager: no spawner, cannot spawn %s" % item_type)
		return null
	if get_scene_path(item_type) == "":
		push_error("ItemManager: unknown item type '%s'" % item_type)
		return null
	var rot := Vector3.ZERO
	if holder_id < 0:
		holder_id = 0
	if holder_id != 0 and get_held_by(holder_id) != null:
		push_warning("ItemManager: peer %d already holds an item; %s spawned on the floor" % [holder_id, item_type])
		var player := get_player(holder_id)
		if player != null:
			position = compute_drop_position(player)
			rot = Vector3(0.0, compute_drop_yaw(player), 0.0)
		holder_id = 0
	var data := {
		"name": _make_unique_name(),
		"type": String(item_type),
		"props": _sanitize_props(props),
		"position": _to_items_space(position),
		"rotation": rot,
		"holder_id": holder_id,
	}
	var node := spawner.spawn(data)
	return node as Item

## SERVER ONLY. Removes an item everywhere (the spawner replicates the despawn). It disappears from
## get_items()/get_held_by() immediately.
func server_despawn_item(item: Item) -> void:
	if not multiplayer.is_server():
		push_error("ItemManager.server_despawn_item called on a client")
		return
	if item == null or not is_instance_valid(item) or item.is_queued_for_deletion():
		return
	if item.get_parent() != self:
		push_warning("ItemManager: %s is not a managed item" % item.name)
		return
	item.queue_free()

## SERVER ONLY. Puts `item` into `peer_id`'s hands. Returns false if that player already holds something else
## or someone else holds the item.
func server_give_item(item: Item, peer_id: int) -> bool:
	if not multiplayer.is_server():
		push_error("ItemManager.server_give_item called on a client")
		return false
	if not _is_live(item) or peer_id <= 0:
		return false
	if item.holder_id == peer_id:
		return true
	if item.is_held():
		return false
	if get_held_by(peer_id) != null:
		return false
	item.holder_id = peer_id
	return true

## SERVER ONLY. Drops `item` at a position (World/Items space == world space; holder cleared, rotation reset).
func server_drop_item(item: Item, position: Vector3) -> void:
	_server_place(item, position, Vector3.ZERO)

## SERVER ONLY. Drops whatever `peer_id` holds in front of that player (at their feet if the player node is gone).
## Net calls this when a peer disconnects.
func server_release_holder(peer_id: int) -> void:
	if not multiplayer.is_server():
		push_error("ItemManager.server_release_holder called on a client")
		return
	var item := get_held_by(peer_id)
	if item == null:
		return
	var player := get_player(peer_id)
	if player != null and player.is_inside_tree():
		_server_place(item, compute_drop_position(player), Vector3(0.0, compute_drop_yaw(player), 0.0))
	else:
		# The item stopped following when the player vanished: put it on the floor below where it is.
		var here := item.global_position if item.is_inside_tree() else item.position
		_server_place(item, _project_to_floor(here, null), Vector3.ZERO)

## SERVER ONLY. Removes every item (e.g. full game reset).
func server_despawn_all() -> void:
	for item in get_items():
		server_despawn_item(item)

# --- Requests (any peer) ----------------------------------------------------------------------------------------

## Any peer: asks the server to drop whatever the local player holds (Interactor calls this on the drop key).
func request_drop() -> void:
	_rpc_request_drop.rpc_id(Const.SERVER_PEER_ID)

@rpc("any_peer", "call_local", "reliable")
func _rpc_request_drop() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	if get_held_by(sender) == null:
		return
	server_release_holder(sender)

# --- Lookups (any peer) -----------------------------------------------------------------------------------------

## The item held by that player, or null.
func get_held_by(peer_id: int) -> Item:
	if peer_id <= 0:
		return null
	for c in get_children():
		var item := c as Item
		if item != null and item.holder_id == peer_id and not item.is_queued_for_deletion():
			return item
	return null

## All live items (items queued for deletion are excluded).
func get_items() -> Array[Item]:
	var out: Array[Item] = []
	for c in get_children():
		var item := c as Item
		if item != null and not item.is_queued_for_deletion():
			out.append(item)
	return out

## Items of one type (Const.ITEM_*).
func get_items_of_type(item_type: StringName) -> Array[Item]:
	var out: Array[Item] = []
	for item in get_items():
		if item.item_type == item_type:
			out.append(item)
	return out

## The Player node for a peer in this world (World/Players/<id>), or null.
func get_player(peer_id: int) -> Player:
	if peer_id <= 0:
		return null
	var world := get_parent()
	if world != null:
		var players := world.get_node_or_null(^"Players")
		if players != null:
			return players.get_node_or_null(str(peer_id)) as Player
	return Game.get_player(peer_id)

## Where an item dropped by `player` lands: DROP_FORWARD in front of them (pulled back from walls), on the floor
## (raycast down; falls back to the player's feet height).
## The spot must be free: not inside static geometry the chest-high wall check cannot see (the well's 0.76 m
## ring, 0.9 m crates: the floor probe starts inside them and would put the item on the floor INSIDE the
## collider, where no interaction ray can reach it) and not on top of a station (an item resting on an empty
## grow plot ends up inside the plant's collider once something is planted). A blocked spot is walked back
## towards the player until it is free; the player's own feet are the last resort.
func compute_drop_position(player: Player) -> Vector3:
	var feet := player.global_position
	var forward := _flat_forward(player)
	var reach := DROP_FORWARD
	var space := _get_space()
	if space == null:
		return _project_to_floor(feet + forward * reach, player)
	var chest := feet + Vector3.UP * DROP_CHEST_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(chest, chest + forward * DROP_FORWARD, Const.LAYER_WORLD,
			[player.get_rid()])
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		var wall: Vector3 = hit["position"]
		var free_dist := maxf(0.0, Vector2(wall.x - feet.x, wall.z - feet.z).length() - DROP_WALL_MARGIN)
		reach = minf(free_dist, DROP_FORWARD)
	for i in range(DROP_BACKOFF_STEPS, 0, -1):
		var landing := _probe_floor(feet + forward * (reach * float(i) / float(DROP_BACKOFF_STEPS)), player)
		if _is_drop_spot_free(landing, player):
			return landing["position"]
	return _project_to_floor(feet, player)

## Yaw (radians) that turns a dropped item's front (+Z face, labels) towards the player who dropped it.
func compute_drop_yaw(player: Player) -> float:
	var forward := _flat_forward(player)
	return atan2(-forward.x, -forward.z)

# --- Spawning ---------------------------------------------------------------------------------------------------

## spawn_function: runs on the server (inside spawner.spawn) AND on every client for each spawn packet.
## Builds the item from plain data; the spawner adds it to this node.
func _spawn_item(data: Variant) -> Node:
	if not data is Dictionary:
		push_error("ItemManager: bad spawn data %s" % [data])
		return null
	var d: Dictionary = data
	var item_type := StringName(str(d.get("type", "")))
	var scene := _get_scene(item_type)
	if scene == null:
		push_error("ItemManager: cannot spawn unknown item type '%s'" % item_type)
		return null
	var node := scene.instantiate()
	var item := node as Item
	if item == null:
		push_error("ItemManager: scene for '%s' is not an Item" % item_type)
		if node != null:
			node.free()
		return null
	item.name = str(d.get("name", "item"))
	var props: Variant = d.get("props", {})
	item.apply_props(props if props is Dictionary else {})
	var pos: Variant = d.get("position", Vector3.ZERO)
	var rot: Variant = d.get("rotation", Vector3.ZERO)
	item.rest_position = pos if pos is Vector3 else Vector3.ZERO
	item.rest_rotation = rot if rot is Vector3 else Vector3.ZERO
	item.holder_id = int(d.get("holder_id", 0))
	return item

func _get_scene(item_type: StringName) -> PackedScene:
	if _scenes.has(item_type):
		return _scenes[item_type]
	var path := get_scene_path(item_type)
	if path == "":
		return null
	var scene := load(path) as PackedScene
	if scene != null:
		_scenes[item_type] = scene
	return scene

func _make_unique_name() -> String:
	var n := "item_%d" % _next_id
	_next_id += 1
	while has_node(n):
		n = "item_%d" % _next_id
		_next_id += 1
	return n

## Spawn data must be plain serializable values: String keys, StringName -> String, no Objects.
func _sanitize_props(props: Dictionary) -> Dictionary:
	var out := {}
	for key in props.keys():
		var value: Variant = props[key]
		match typeof(value):
			TYPE_STRING_NAME:
				value = String(value)
			TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_VECTOR3, TYPE_COLOR:
				pass
			_:
				push_warning("ItemManager: dropping non-plain prop '%s' (%s)" % [key, type_string(typeof(value))])
				continue
		out[str(key)] = value
	return out

func _find_spawner() -> MultiplayerSpawner:
	var parent := get_parent()
	if parent == null:
		return null
	var s := parent.get_node_or_null(^"ItemSpawner") as MultiplayerSpawner
	if s != null:
		return s
	for c in parent.get_children():
		var candidate := c as MultiplayerSpawner
		if candidate != null and candidate.get_node_or_null(candidate.spawn_path) == self:
			return candidate
	return null

# --- Internals --------------------------------------------------------------------------------------------------

func _server_place(item: Item, at_position: Vector3, rotation_euler: Vector3) -> void:
	if not multiplayer.is_server():
		push_error("ItemManager: placing items is server only")
		return
	if not _is_live(item):
		return
	# Rest first, then release: the release snaps the node to the new rest transform on every peer.
	item.server_set_rest(_to_items_space(at_position), rotation_euler)
	item.holder_id = 0

## World position -> this node's local space (identical while World/Items sit at the origin, as they do).
func _to_items_space(world_position: Vector3) -> Vector3:
	return to_local(world_position) if is_inside_tree() else world_position

func _is_live(item: Item) -> bool:
	return item != null and is_instance_valid(item) and not item.is_queued_for_deletion() and item.get_parent() == self

func _get_space() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree():
		return null
	var world_3d := get_world_3d()
	return world_3d.direct_space_state if world_3d != null else null

## Horizontal look direction of a player (camera yaw; body forward as fallback).
func _flat_forward(player: Player) -> Vector3:
	var cam := player.get_node_or_null(^"%Camera") as Node3D
	var look := cam.global_transform.basis if cam != null and cam.is_inside_tree() else player.global_transform.basis
	var forward := -look.z
	var looking_down := forward.y < 0.0
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		# Looking straight down (up): the camera's up (down) vector points where the player faces.
		forward = look.y if looking_down else -look.y
		forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	return forward.normalized()

## Raycasts down onto static geometry (layer 1: floor, station tops) below `point`.
## Falls back to the player's feet height (or the point's own height without a player).
func _project_to_floor(point: Vector3, player: Player) -> Vector3:
	return _probe_floor(point, player)["position"]

## Like _project_to_floor() but also returns what the item would rest on: {"position": Vector3, "collider": Object}
## (collider null when nothing was hit and the fallback height is used).
func _probe_floor(point: Vector3, player: Player) -> Dictionary:
	var base_y := player.global_position.y if player != null else point.y
	var space := _get_space()
	if space != null:
		var from := Vector3(point.x, base_y + FLOOR_PROBE_UP, point.z)
		var to := Vector3(point.x, base_y - FLOOR_PROBE_DOWN, point.z)
		var exclude: Array[RID] = []
		if player != null:
			exclude.append(player.get_rid())
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD, exclude))
		if not hit.is_empty():
			var floor_hit: Vector3 = hit["position"]
			return {"position": Vector3(point.x, floor_hit.y, point.z), "collider": hit.get("collider")}
	return {"position": Vector3(point.x, base_y, point.z), "collider": null}

## True if an item can rest at `landing` (from _probe_floor): not on a station (collision layer 3) and no static
## geometry inside the clearance sphere just above the landing point.
func _is_drop_spot_free(landing: Dictionary, player: Player) -> bool:
	var surface := landing.get("collider") as CollisionObject3D
	if surface != null and (surface.collision_layer & Const.LAYER_INTERACTABLE) != 0:
		return false
	var space := _get_space()
	if space == null:
		return true
	var sphere := SphereShape3D.new()
	sphere.radius = DROP_CLEARANCE_RADIUS
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	var pos: Vector3 = landing["position"]
	params.transform = Transform3D(Basis.IDENTITY, pos + Vector3.UP * (DROP_CLEARANCE_RADIUS + 0.03))
	params.collision_mask = Const.LAYER_WORLD
	if player != null:
		params.exclude = [player.get_rid()]
	return space.intersect_shape(params, 1).is_empty()

## GameState.game_reset (every peer, after a RETRY reset was applied). HOST ONLY: despawns every seed packet
## and product, held or loose. Watering cans are left alone: the Well's own reset handler (two frames later)
## puts them back at the well.
func _on_game_reset() -> void:
	if not is_inside_tree() or not Net.is_host or not multiplayer.is_server():
		return
	for item in get_items():
		if item.item_type == Const.ITEM_SEED_PACKET or item.item_type == Const.ITEM_PRODUCT:
			server_despawn_item(item)

## Called by Item._ready (every peer, synced spawn state already applied).
func _on_item_ready(item: Item) -> void:
	item_added.emit(item)

## Called by Item._exit_tree (every peer).
func _on_item_exiting(item: Item) -> void:
	item_removed.emit(item)

## Called by Item's holder_id setter after spawn (every peer).
func _on_item_holder_changed(item: Item, old_holder: int, new_holder: int) -> void:
	holder_changed.emit(item, old_holder, new_holder)
