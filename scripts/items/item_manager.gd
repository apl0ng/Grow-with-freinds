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
##
## M10 throw (physics agent): request_throw() -> _rpc_request_throw (server): the sender must hold an item and be
## neither stunned nor in the back room. Origin = the holder's hand socket + THROW_ORIGIN_FORWARD along the look
## direction (pulled back to the chest if that is inside a wall), velocity = look direction * throw_speed + up *
## THROW_UP. server_throw_item() writes the item's synced flight values (a new serial), releases the holder and counts
## STAT_THROWS; the "throw" sound plays on every peer from the item's flight setter. While an item flies the SERVER
## steps its arc in _physics_process along the item's own flight clock (the same integration every peer renders):
## per step a hit check against every other worker's chest (throw_hit_radius from the segment; the thrower cannot hit
## themselves), a raycast on LAYER_WORLD | LAYER_INTERACTABLE, a time cap (FLIGHT_MAX_SEC) and a floor limit. The
## flight ends by placing the item with the drop rules (a free floor spot, never inside geometry or on a station;
## walked back along the arc when blocked) and clearing flight_serial. A PRODUCT whose flight ends inside the
## TurnInStation's collider (or within CHUTE_MOUTH_RADIUS of its mouth) is sold as if deposited by the thrower. A hit
## staggers the target (Player.server_stagger with hit_stun_sec; their held item drops), counts STAT_HITS and plays
## "bonk" on every peer through the target's cosmetic stagger RPC.

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
## M10 throw: a flight ends after this many seconds at the latest ...
const FLIGHT_MAX_SEC: float = 3.0
## ... or once the item is this far below the room floor (fell out of the world).
const FLIGHT_FLOOR_MARGIN: float = 1.0
## Launch point: this far from the hand socket along the look direction (clears the body).
const THROW_ORIGIN_FORWARD: float = 0.3
## Extra upward speed on every throw (m/s).
const THROW_UP: float = 1.5
## A blocked landing spot is walked back along the arc in steps of this many seconds, this many times.
const FLIGHT_BACKOFF_SEC: float = 0.04
const FLIGHT_BACKOFF_STEPS: int = 24
## A product ending its flight this close to the deposit chute's mouth is a chute shot.
const CHUTE_MOUTH_RADIUS: float = 0.6
## Landing probes look this far below a flight point for the floor.
const FLIGHT_FLOOR_PROBE_DOWN: float = 8.0

var spawner: MultiplayerSpawner = null

var _next_id: int = 1
var _next_flight_serial: int = 0
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

## SERVER: steps every flying item along its arc (hits, walls, the chute, the time cap). Clients do nothing here.
func _physics_process(_delta: float) -> void:
	for c in get_children():
		var item := c as Item
		if item == null or not item.is_flying() or item.is_queued_for_deletion():
			continue
		if not item._is_authority:
			return # not the server (cached per item: no multiplayer query per frame)
		_server_step_flight(item)

## Scene path for an item type ("" if unknown).
static func get_scene_path(item_type: StringName) -> String:
	if item_type == Const.ITEM_WATERING_CAN:
		return "res://scenes/items/watering_can.tscn"
	if item_type == Const.ITEM_SEED_PACKET:
		return "res://scenes/items/seed_packet.tscn"
	if item_type == Const.ITEM_PRODUCT:
		return "res://scenes/items/product.tscn"
	if item_type == Const.ITEM_FLAMETHROWER: # M12: {"fuel": float}
		return "res://scenes/items/flamethrower.tscn"
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
	if item.is_held() or item.is_flying():
		return false
	if get_held_by(peer_id) != null:
		return false
	item.holder_id = peer_id
	return true

## SERVER ONLY. Throws `item` from `origin` (world space) at `velocity` on behalf of `thrower` (peer id, 0 = nobody).
## Releases the holder, starts the synced flight (see the header) and counts STAT_THROWS. False if the item is not
## managed, already flying, or the numbers are not finite.
func server_throw_item(item: Item, origin: Vector3, velocity: Vector3, thrower: int) -> bool:
	if not multiplayer.is_server():
		push_error("ItemManager.server_throw_item called on a client")
		return false
	if not _is_live(item) or item.is_flying():
		return false
	if not origin.is_finite() or not velocity.is_finite():
		return false
	_next_flight_serial += 1
	item.thrower_id = maxi(thrower, 0)
	item.flight_origin = _to_items_space(origin)
	item.flight_velocity = velocity
	item.flight_serial = _next_flight_serial # takes off: collision off, world layers, "throw" on every peer
	item.holder_id = 0                        # released (the flight keeps it from snapping to its old rest spot)
	if thrower > 0:
		GameState.server_add_stat(thrower, Const.STAT_THROWS)
	return true

## Where a throw by `player` starts: the hand socket this peer sees for them (+ THROW_ORIGIN_FORWARD along the look
## direction), pulled back towards the chest when that point sits inside a wall or a station.
func compute_throw_origin(player: Player) -> Vector3:
	var chest := player.global_position + Vector3.UP * DROP_CHEST_HEIGHT
	if not chest.is_finite():
		return _safe_drop_spot(null) + Vector3.UP * DROP_CHEST_HEIGHT
	var socket := player.get_item_socket()
	var origin := socket.global_position if socket != null and socket.is_inside_tree() else chest
	origin += _look_direction(player) * THROW_ORIGIN_FORWARD
	if not origin.is_finite():
		return chest
	var space := _get_space()
	if space != null and origin.distance_squared_to(chest) > 0.0001:
		var query := PhysicsRayQueryParameters3D.create(chest, origin, Const.LAYER_WORLD | Const.LAYER_INTERACTABLE,
				[player.get_rid()])
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var wall: Vector3 = hit["position"]
			origin = wall.move_toward(chest, 0.1)
	return origin

## Launch velocity of a throw by `player`: look direction * throw_speed + THROW_UP up.
func compute_throw_velocity(player: Player) -> Vector3:
	return _look_direction(player) * Config.balance.throw_speed + Vector3.UP * THROW_UP

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
	if GameState.is_in_backroom(peer_id):
		# M11 review: the back room is closed off behind the booth. An item let go of there (its worker dropped out
		# of the session mid-stay) would be stranded for the rest of the shift, so it goes back to the floor at the
		# worker's spawn point instead.
		_server_place(item, _spawn_drop_spot(player), Vector3.ZERO)
	elif player != null and player.is_inside_tree():
		_server_place(item, compute_drop_position(player), Vector3(0.0, compute_drop_yaw(player), 0.0))
	else:
		# The item stopped following when the player vanished: put it on the floor below where it is.
		var here := item.global_position if item.is_inside_tree() else item.position
		_server_place(item, _project_to_floor(here, null) if here.is_finite() else _safe_drop_spot(null), Vector3.ZERO)

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
	if get_held_by(sender) == null or GameState.is_in_backroom(sender):
		return # nothing to drop, or the back room (M11: nothing is done from there; the item stays in hand)
	server_release_holder(sender)

## Any peer: asks the server to throw whatever the local player holds (Interactor, "throw" action).
func request_throw() -> void:
	_rpc_request_throw.rpc_id(Const.SERVER_PEER_ID)

@rpc("any_peer", "call_local", "reliable")
func _rpc_request_throw() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	var item := get_held_by(sender)
	var player := get_player(sender)
	if item == null or player == null or not player.is_inside_tree():
		return
	if player.is_stunned() or GameState.is_in_backroom(sender):
		return
	server_throw_item(item, compute_throw_origin(player), compute_throw_velocity(player), sender)

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
	if not feet.is_finite():
		return _safe_drop_spot(null) # a holder transform gone bad: never feed NaN / inf into physics queries
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
	var yaw := atan2(-forward.x, -forward.z)
	return yaw if is_finite(yaw) else 0.0

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
	if not at_position.is_finite():
		at_position = _safe_drop_spot(get_player(item.holder_id))
	if not rotation_euler.is_finite():
		rotation_euler = Vector3.ZERO
	# Rest first, then release: the release snaps the node to the new rest transform on every peer.
	item.server_set_rest(_to_items_space(at_position), rotation_euler)
	if item.is_flying():
		item.flight_serial = 0 # placed by hand (a reset, a re-homed can): the flight is over
	item.holder_id = 0

# --- M10 flight (server) ----------------------------------------------------------------------------------------

## One server step of a flying item: checks the arc segment since the last step against workers, the room and the
## limits, and ends the flight when something was hit (see the header).
func _server_step_flight(item: Item) -> void:
	var t0 := item._flight_checked_t
	var t1 := item.get_flight_time()
	if t1 <= t0:
		return
	item._flight_checked_t = t1
	var a := _from_items_space(item.get_flight_point(t0))
	var b := _from_items_space(item.get_flight_point(t1))
	if not a.is_finite() or not b.is_finite():
		_server_end_flight(item, _from_items_space(item.flight_origin), t1)
		return
	# 1. A worker in the way (chest within throw_hit_radius of the segment).
	var hit := _server_find_hit(a, b, item.thrower_id)
	if not hit.is_empty():
		var target: Player = hit["player"]
		var point: Vector3 = hit["point"]
		if target.can_be_staggered():
			var push := Vector3(item.flight_velocity.x, 0.0, item.flight_velocity.z)
			Player.server_stagger(target, push, true, item.thrower_id, Config.balance.hit_stun_sec, true)
			if item.thrower_id > 0:
				GameState.server_add_stat(item.thrower_id, Const.STAT_HITS)
		# else (M11): still stumbling / immune after the last stagger: a dud. The bundle drops at their feet, no
		# stagger, no bonk, no hit counted.
		_server_end_flight(item, point, t1)
		return
	# 2. The room (walls, floor, ceiling, props) and station colliders.
	var space := _get_space()
	if space != null:
		var exclude: Array[RID] = []
		var collider := item.get_collider()
		if collider != null:
			exclude.append(collider.get_rid())
		var query := PhysicsRayQueryParameters3D.create(a, b, Const.LAYER_WORLD | Const.LAYER_INTERACTABLE, exclude)
		query.hit_from_inside = true
		var wall := space.intersect_ray(query)
		if not wall.is_empty():
			_server_end_flight(item, wall["position"], t1)
			return
	# 3. Flew too long, or fell out of the world.
	if t1 >= FLIGHT_MAX_SEC or b.y < _flight_floor_limit():
		_server_end_flight(item, b, t1)

## The first OTHER worker whose chest lies within throw_hit_radius of segment a-b: {"player", "point"} or {}.
func _server_find_hit(a: Vector3, b: Vector3, thrower: int) -> Dictionary:
	var radius: float = Config.balance.throw_hit_radius
	var best := {}
	var best_s := INF
	var ab := b - a
	var len2 := ab.length_squared()
	for p in _get_players():
		if p.peer_id == thrower or not p.is_inside_tree() or GameState.is_in_backroom(p.peer_id):
			continue
		var chest := p.get_chest_position()
		if not chest.is_finite():
			continue
		var s := 0.0 if len2 < 0.000001 else clampf((chest - a).dot(ab) / len2, 0.0, 1.0)
		var closest := a + ab * s
		if closest.distance_to(chest) <= radius and s < best_s:
			best_s = s
			best = {"player": p, "point": closest}
	return best

## Ends a flight at `point` (world space; `t_end` = arc time there): a chute shot sells a product, anything else is
## placed on a free floor spot walked back along the arc from `point`, then flight_serial is cleared.
func _server_end_flight(item: Item, point: Vector3, t_end: float) -> void:
	if not _is_live(item):
		return
	if item.item_type == Const.ITEM_PRODUCT and point.is_finite():
		var chute := _find_chute_at(point)
		if chute != null and chute.server_sell_item(item, item.thrower_id):
			return # sold and despawned
	var rest := _find_flight_landing(item, point, t_end)
	item.server_set_rest(_to_items_space(rest), Vector3.ZERO)
	item.flight_serial = 0

## A free floor spot for an item whose flight ended at `point`: below the point, else below earlier arc samples
## (walking back FLIGHT_BACKOFF_SEC at a time), else below the launch point, else the safe drop spot.
func _find_flight_landing(item: Item, point: Vector3, t_end: float) -> Vector3:
	var bounds := _room_bounds()
	for i in range(0, FLIGHT_BACKOFF_STEPS + 1):
		var p := point if i == 0 else _from_items_space(item.get_flight_point(maxf(t_end - FLIGHT_BACKOFF_SEC * float(i), 0.0)))
		if not p.is_finite():
			continue
		var landing := _probe_floor_below(p)
		var spot: Vector3 = landing["position"]
		if not _inside_play(spot, bounds): # M14 level: any play area (main room, grow hall, loading dock)
			continue
		# M13 review: never inside the Boss's booth. The pay window has no collider above the 1 m counter, so a
		# thrown can / flamethrower sailed in (or was lobbed over the partition) and was lost for the shift: the
		# floor cannot get in there. The walk back along the arc finds the last spot on the workers' side.
		if _in_booth(spot):
			continue
		if _is_drop_spot_free(landing, null):
			return spot
	var origin := _from_items_space(item.flight_origin)
	if origin.is_finite():
		var below := _probe_floor_below(origin)
		if _inside_play(below["position"], bounds) and not _in_booth(below["position"]) and _is_drop_spot_free(below, null): # M14 level
			return below["position"]
	return _safe_drop_spot(get_player(item.thrower_id))


## M13 review: true when `spot` lies inside the Boss's booth (Room.is_in_booth; false without a room).
func _in_booth(spot: Vector3) -> bool:
	var world := get_parent() as World
	if world == null or not world.is_node_ready() or world.room == null or not world.room.has_method(&"is_in_booth"):
		return false
	return bool(world.room.call(&"is_in_booth", spot))

## The TurnInStation whose collider (or mouth) contains `point`, or null.
func _find_chute_at(point: Vector3) -> TurnInStation:
	if not is_inside_tree():
		return null
	for n in get_tree().get_nodes_in_group(Const.GROUP_INTERACTABLES):
		var chute := n as TurnInStation
		if chute != null and chute.is_inside_tree() and chute.accepts_flight_point(point, CHUTE_MOUTH_RADIUS):
			return chute
	return null

## Like _probe_floor() but for a point in the air: the floor (layer 1) up to FLIGHT_FLOOR_PROBE_DOWN below it. Without a
## hit the point's own height is used and "collider" is null (an item that fell out of the world; rejected by bounds).
func _probe_floor_below(point: Vector3) -> Dictionary:
	var space := _get_space()
	if space != null:
		var from := point + Vector3.UP * 0.05
		var to := point + Vector3.DOWN * FLIGHT_FLOOR_PROBE_DOWN
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD))
		if not hit.is_empty():
			var floor_hit: Vector3 = hit["position"]
			return {"position": Vector3(point.x, floor_hit.y, point.z), "collider": hit.get("collider")}
		return {"position": point, "collider": null, "no_floor": true}
	return {"position": point, "collider": null}

## The room's interior bounds (global), or an empty AABB when there is no room (minimal test trees).
func _room_bounds() -> AABB:
	var world := get_parent() as World
	if world != null and world.is_node_ready() and world.room != null and world.room.has_method(&"get_bounds"):
		return world.room.get_bounds()
	return AABB()

## True if `spot` is a plausible landing: inside the room (a little margin) when there is a room; when there is no
## room the spot must at least rest on something (a floor probe hit).
func _inside_bounds(spot: Vector3, bounds: AABB) -> bool:
	if not spot.is_finite():
		return false
	if bounds.size == Vector3.ZERO:
		return true
	var inner := bounds.grow(-0.1)
	inner.position.y = bounds.position.y - 0.5
	inner.size.y = bounds.size.y + 1.0
	return inner.has_point(spot)

# --- M14 level: the play areas (main room, grow hall, loading dock) --------------------------------------------------

## True if `spot` is a plausible landing in ANY play area of the room (Room.contains_point with the 0.1 m margin
## _inside_bounds keeps from the outer walls; a doorway between two areas counts as inside). A room without the M14
## API, or no room at all, falls back to _inside_bounds(spot, bounds).
func _inside_play(spot: Vector3, bounds: AABB) -> bool:
	var world := get_parent() as World
	var room: Node = world.room if world != null and world.is_node_ready() else null
	if room == null or not room.has_method(&"contains_point") or not room.has_method(&"get_play_bounds"):
		return _inside_bounds(spot, bounds)
	if not spot.is_finite():
		return false
	var play: AABB = room.call(&"get_play_bounds")
	if spot.y >= play.position.y - 0.5 and spot.y <= play.end.y + 0.5 \
			and bool(room.call(&"contains_point", Vector3(spot.x, play.position.y + 1.0, spot.z), 0.1)):
		return true
	# The alley (M14 lobby: World/Lobby with get_bounds() in global space) is a place to throw things as well.
	var lobby := world.get_node_or_null(^"Lobby")
	if lobby != null and lobby.has_method(&"get_bounds"):
		var alley: AABB = lobby.call(&"get_bounds")
		return alley.size != Vector3.ZERO and _inside_bounds(spot, alley)
	return false

# --- end M14 level ------------------------------------------------------------------------------------------------------

func _flight_floor_limit() -> float:
	var bounds := _room_bounds()
	var floor_y := bounds.position.y if bounds.size != Vector3.ZERO else 0.0
	return floor_y - FLIGHT_FLOOR_MARGIN

## Every live Player in this world (World/Players), or the players group without a world.
func _get_players() -> Array[Player]:
	var out: Array[Player] = []
	var world := get_parent()
	var players := world.get_node_or_null(^"Players") if world != null else null
	if players != null:
		for c in players.get_children():
			var p := c as Player
			if p != null and not p.is_queued_for_deletion():
				out.append(p)
	elif is_inside_tree():
		for n in get_tree().get_nodes_in_group(Const.GROUP_PLAYERS):
			var p := n as Player
			if p != null and not p.is_queued_for_deletion():
				out.append(p)
	return out

## Look direction of a player (camera forward; unit length; the flat forward when the camera transform is broken).
func _look_direction(player: Player) -> Vector3:
	var look := player.get_look_direction()
	if not look.is_finite() or look.length_squared() < 0.0001:
		return _flat_forward(player)
	return look.normalized()

## This node's local space -> world (identical while World/Items sit at the origin, as they do).
func _from_items_space(local_position: Vector3) -> Vector3:
	return to_global(local_position) if is_inside_tree() else local_position

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
	if not forward.is_finite():
		return Vector3.FORWARD
	var looking_down := forward.y < 0.0
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		# Looking straight down (up): the camera's up (down) vector points where the player faces.
		forward = look.y if looking_down else -look.y
		forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	return forward.normalized()

## A finite floor spot for an item whose computed drop / release position is not finite (NaN / inf from a bad holder
## transform): below the holder if its position is finite, else below the room's first spawn point (the room centre
## without a room).
func _safe_drop_spot(player: Player) -> Vector3:
	if player != null and player.is_inside_tree() and player.global_position.is_finite():
		return _project_to_floor(player.global_position, player)
	var world := get_parent() as World
	var spot := Vector3.ZERO
	if world != null and world.is_node_ready() and world.room != null:
		spot = world.room.get_spawn_transform(0).origin
	elif world != null and world.is_inside_tree():
		spot = world.global_position
	return _project_to_floor(spot, null) if spot.is_finite() else Vector3.ZERO

## The floor at `player`'s spawn point (the room's first spawn without a player / room): where an item goes when its
## holder cannot drop it where they stand (the back room).
func _spawn_drop_spot(player: Player) -> Vector3:
	var world := get_parent() as World
	if world != null and world.is_node_ready() and world.room != null:
		var index := player.spawn_index if player != null else 0
		var spot: Vector3 = world.room.get_spawn_transform(index).origin
		if spot.is_finite():
			return _project_to_floor(spot, null)
	return _safe_drop_spot(null)

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
